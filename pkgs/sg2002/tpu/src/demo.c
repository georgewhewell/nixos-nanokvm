/* SPDX-License-Identifier: MIT */
#include "sg2002-tpu-runtime.h"
#include <cvikernel/cvikernel.h>
#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static double now(clockid_t clock)
{
    struct timespec t;
    clock_gettime(clock, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

static int8_t saturate(int value)
{
    return value < -128 ? -128 : value > 127 ? 127 : value;
}

static int run_context(int fd, cvk_context_t *ctx, const uint32_t bases[8])
{
    uint32_t bytes;
    uint8_t *commands = ctx->ops->acquire_cmdbuf(ctx, &bytes);
    return sg2002_tpu_run(fd, commands, bytes, bases, 0);
}

static int matrix(int fd, unsigned m, unsigned k, unsigned n, unsigned iterations,
                  unsigned seed, bool split)
{
    int ret = -1;
    unsigned input_bytes = m * k + k * n, output_bytes = m * n;
    int8_t *input = malloc(input_bytes), *output = malloc(output_bytes);
    int8_t *reference = malloc(output_bytes);
    uint8_t commands[65536];
    cvk_reg_info_t config = {
        .chip_ver_str = "cv181x", .cmdbuf_size = sizeof(commands), .cmdbuf = commands,
    };
    cvk_context_t *ctx = cvikernel_register(&config);
    struct sg2002_tpu_buffer buffer = {0};
    cvk_ml_t *a = NULL, *b = NULL, *c = NULL;
    if (!input || !output || !reference || !ctx)
        goto done;
    /* Includes both INT8 extrema, and non-power-of-two shapes below. */
    for (unsigned i = 0; i < input_bytes; i++)
        input[i] = seed == 0 ? (int8_t)(i * 37) :
                   seed == 1 ? (int8_t)((i + 1) % 5 - 2) :
                   seed == 2 ? -128 : 127;
    double cpu_start = now(CLOCK_PROCESS_CPUTIME_ID);
    for (unsigned row = 0; row < m; row++)
        for (unsigned col = 0; col < n; col++) {
            int sum = 0;
            for (unsigned j = 0; j < k; j++)
                sum += input[row * k + j] * input[m * k + j * n + col];
            reference[row * n + col] = saturate(sum);
        }
    double reference_cpu = now(CLOCK_PROCESS_CPUTIME_ID) - cpu_start;
    if (sg2002_tpu_alloc(fd, input_bytes + output_bytes + 128, &buffer))
        goto done;
    if (sg2002_tpu_write(fd, &buffer, 0, input, input_bytes))
        goto done;
    a = ctx->ops->lmem_alloc_matrix(ctx,
        ctx->ops->ml_default_shape(ctx, m, k, CVK_FMT_I8), CVK_FMT_I8, 1);
    b = ctx->ops->lmem_alloc_matrix(ctx,
        ctx->ops->ml_default_shape(ctx, k, n, CVK_FMT_I8), CVK_FMT_I8, 1);
    c = ctx->ops->lmem_alloc_matrix(ctx,
        ctx->ops->ml_default_shape(ctx, m, n, CVK_FMT_I8), CVK_FMT_I8, 1);
    if (!a || !b || !c) {
        errno = ENOMEM;
        goto done;
    }
    uint32_t bases[8] = {0};
    uint8_t base_index = seed & 1 ? 7 : 0;
    uint64_t address = seed & 1 ? 0 : buffer.dma_address;
    if (seed & 1) bases[7] = buffer.handle;
    cvk_mg_t ga = {
        .base_reg_index = base_index, .start_address = address, .fmt = CVK_FMT_I8,
        .shape = { .row = m, .col = k }, .stride = { .row = k },
    };
    cvk_mg_t gb = {
        .base_reg_index = base_index, .start_address = address + m * k, .fmt = CVK_FMT_I8,
        .shape = { .row = k, .col = n }, .stride = { .row = n },
    };
    unsigned out_offset = input_bytes;
    cvk_mg_t gc = {
        .base_reg_index = base_index, .start_address = address + out_offset, .fmt = CVK_FMT_I8,
        .shape = { .row = m, .col = n }, .stride = { .row = n },
    };
    cvk_tdma_g2l_matrix_copy_param_t load_a = { .src = &ga, .dst = a };
    cvk_tdma_g2l_matrix_copy_param_t load_b = { .src = &gb, .dst = b };
    cvk_tiu_matrix_multiplication_param_t multiply = {
        .left = a, .right = b, .res = c, .res_is_int8 = 1,
    };
    cvk_tdma_l2g_matrix_copy_param_t store = { .src = c, .dst = &gc };
    ctx->ops->tdma_g2l_matrix_copy(ctx, &load_a);
    ctx->ops->tdma_g2l_matrix_copy(ctx, &load_b);
    ctx->ops->tiu_matrix_multiplication(ctx, &multiply);
    ctx->ops->tdma_l2g_matrix_copy(ctx, &store);
    uint32_t command_bytes;
    uint8_t *raw = ctx->ops->acquire_cmdbuf(ctx, &command_bytes);
    double start = now(CLOCK_MONOTONIC), cpu = now(CLOCK_PROCESS_CPUTIME_ID);
    for (unsigned iteration = 0; iteration < iterations; iteration++) {
        memset(output, 0x5a, output_bytes);
        if (sg2002_tpu_write(fd, &buffer, out_offset, output, output_bytes) ||
            sg2002_tpu_run(fd, raw, command_bytes, bases, 0) ||
            sg2002_tpu_read(fd, &buffer, out_offset, output, output_bytes))
            goto done;
        for (unsigned i = 0; i < output_bytes; i++)
            if (output[i] != reference[i]) {
                fprintf(stderr, "%ux%ux%u seed %u run %u output[%u]: got %d expected %d\n",
                        m, k, n, seed, iteration, i, output[i], reference[i]);
                errno = EILSEQ;
                goto done;
            }
    }
    cpu = now(CLOCK_PROCESS_CPUTIME_ID) - cpu;
    double elapsed = now(CLOCK_MONOTONIC) - start;
    if (split) {
        /* Independently exercise TDMA-only and TIU-only submissions. ID reset
         * must preserve local tensor SRAM between these three jobs. */
        ctx->ops->reset(ctx);
        ctx->ops->tdma_g2l_matrix_copy(ctx, &load_a);
        ctx->ops->tdma_g2l_matrix_copy(ctx, &load_b);
        if (run_context(fd, ctx, bases))
            goto done;
        ctx->ops->reset(ctx);
        ctx->ops->tiu_matrix_multiplication(ctx, &multiply);
        if (run_context(fd, ctx, bases))
            goto done;
        ctx->ops->reset(ctx);
        ctx->ops->tdma_l2g_matrix_copy(ctx, &store);
        if (run_context(fd, ctx, bases) ||
            sg2002_tpu_read(fd, &buffer, out_offset, output, output_bytes))
            goto done;
        if (memcmp(output, reference, output_bytes)) {
            errno = EILSEQ;
            fprintf(stderr, "isolated TIU/TDMA output differs\n");
            goto done;
        }
    }
    printf("PASS INT8 %ux%ux%u seed=%u runs=%u wall=%.3f ms/job cpu=%.3f ms/job CPU-reference=%.3f ms\n",
           m, k, n, seed, iterations, elapsed * 1000 / iterations,
           cpu * 1000 / iterations, reference_cpu * 1000);
    ret = 0;
done:
    if (ret)
        perror("TPU matrix");
    if (buffer.handle && sg2002_tpu_free(fd, &buffer)) {
        perror("TPU free");
        ret = -1;
    }
    if (ctx) {
        if (c) ctx->ops->lmem_free_matrix(ctx, c);
        if (b) ctx->ops->lmem_free_matrix(ctx, b);
        if (a) ctx->ops->lmem_free_matrix(ctx, a);
        ctx->ops->cleanup(ctx);
        free(ctx->priv_data);
        free(ctx);
    }
    free(input);
    free(output);
    free(reference);
    return ret;
}

static int negative_tests(int fd)
{
    struct sg2002_tpu_buffer b;
    char data = 0;
    if (sg2002_tpu_alloc(fd, 0, &b) != -1 || errno != EINVAL)
        return -1;
    if (sg2002_tpu_alloc(fd, 1, &b))
        return -1;
    if (sg2002_tpu_write(fd, &b, b.size, &data, 1) != -1 || errno != EINVAL)
        return -1;
    struct sg2002_tpu_submit empty = {0};
    if (ioctl(fd, SG2002_TPU_SUBMIT, &empty) != -1 || errno != EINVAL)
        return -1;
    if (sg2002_tpu_run(fd, &data, 1, NULL, 0) != -1 || errno != EINVAL)
        return -1;
    int other = sg2002_tpu_open();
    if (other < 0)
        return -1;
    int private_result = sg2002_tpu_read(other, &b, 0, &data, 1);
    int private_errno = errno;
    close(other);
    if (private_result != -1 || private_errno != ENOENT)
        return -1;
    if (sg2002_tpu_free(fd, &b))
        return -1;
    if (geteuid() == 0) {
        pid_t child = fork();
        if (child < 0)
            return -1;
        if (!child) {
            struct sg2002_tpu_info info;
            if (setuid(65534))
                _exit(1);
            _exit(ioctl(fd, SG2002_TPU_INFO, &info) == -1 && errno == EPERM ? 0 : 1);
        }
        int status;
        if (waitpid(child, &status, 0) != child || !WIFEXITED(status) || WEXITSTATUS(status))
            return -1;
    }
    printf("PASS invalid allocation, buffer range, empty job, malformed stream and dropped-privilege fd checks\n");
    return 0;
}

int main(int argc, char **argv)
{
    unsigned iterations = 10;
    bool split = argc == 3 && !strcmp(argv[2], "--split");
    if (argc > 3 || (argc == 3 && !split) ||
        (argc >= 2 && (!sscanf(argv[1], "%u", &iterations) ||
                       !iterations || iterations > 10000))) {
        fprintf(stderr, "usage: sg2002-tpu-demo [iterations:1..10000] [--split]\n");
        return 2;
    }
    int fd = sg2002_tpu_open();
    if (fd < 0) {
        perror("open /dev/sg2002-tpu (requires CAP_SYS_RAWIO)");
        return 1;
    }
    struct sg2002_tpu_info info;
    if (ioctl(fd, SG2002_TPU_INFO, &info)) {
        perror("TPU info");
        return 1;
    }
    printf("SG2002 TPU ABI %u clock %llu Hz; real hardware only\n",
           info.abi_version, (unsigned long long)info.clock_hz);
    if (negative_tests(fd)) {
        fprintf(stderr, "TPU negative tests failed\n");
        return 1;
    }
    const unsigned shapes[][3] = {{1, 1, 1}, {3, 5, 7}, {8, 16, 9},
                                  {16, 31, 17}, {32, 64, 32}, {64, 128, 64}};
    for (unsigned shape = 0; shape < sizeof(shapes) / sizeof(shapes[0]); shape++)
        for (unsigned seed = 0; seed < 4; seed++)
            if (matrix(fd, shapes[shape][0], shapes[shape][1], shapes[shape][2],
                       iterations, seed, split))
                return 1;
    close(fd);
    return 0;
}
