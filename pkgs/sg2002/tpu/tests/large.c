/* SPDX-License-Identifier: MIT */
#include "sg2002-tpu-runtime.h"
#include <cvikernel/cvikernel.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    char *end = NULL;
    unsigned long count = argc == 2 ? strtoul(argv[1], &end, 10) : 5000;
    if (argc > 2 || !count || count > UINT16_MAX || (end && *end))
        return 2;
    int ret = 1, fd = sg2002_tpu_open();
    struct sg2002_tpu_buffer buffer = {0};
    /* cvikernel reserves its descriptor table using the larger TIU size. */
    cvk_reg_info_t config = {
        .chip_ver_str = "cv181x", .cmdbuf_size = count * 120 + 4096,
    };
    config.cmdbuf = malloc(config.cmdbuf_size);
    cvk_context_t *ctx = config.cmdbuf ? cvikernel_register(&config) : NULL;
    if (fd < 0 || !ctx || sg2002_tpu_alloc(fd, 64, &buffer))
        goto done;
    unsigned char data[64], output[64];
    for (unsigned i = 0; i < sizeof(data); i++) data[i] = i * 17;
    memset(data + 16, 0, 16);
    if (sg2002_tpu_write(fd, &buffer, 0, data, sizeof(data)))
        goto done;
    cvk_tg_t src = {
        .start_address = buffer.dma_address, .fmt = CVK_FMT_I8,
        .shape = { .n = 1, .c = 1, .h = 1, .w = 16 },
        .stride = { .n = 16, .c = 16, .h = 16 },
    };
    cvk_tg_t dst = src;
    dst.start_address += 16;
    cvk_tdma_g2g_tensor_copy_param_t copy = { .src = &src, .dst = &dst };
    for (unsigned i = 0; i < count; i++)
        ctx->ops->tdma_g2g_tensor_copy(ctx, &copy);
    uint32_t bytes;
    const void *raw = ctx->ops->acquire_cmdbuf(ctx, &bytes);
    if (sg2002_tpu_run(fd, raw, bytes, NULL, 10000) ||
        sg2002_tpu_read(fd, &buffer, 0, output, sizeof(output)))
        goto done;
    memcpy(data + 16, data, 16);
    if (memcmp(data, output, sizeof(data))) {
        errno = EILSEQ;
        goto done;
    }
    /* A bad middle segment must stop the batch before the last copy. */
    uint32_t descriptors[2][16];
    memcpy(descriptors[0], (const unsigned char *)raw + 8, 64);
    descriptors[0][0] |= 0x1c; /* barrier, end, interrupt */
    memcpy(descriptors[1], descriptors[0], 64);
    descriptors[1][11] += 16; /* third segment would overwrite the guard */
    struct sg2002_tpu_submit jobs[3] = {0};
    jobs[0].tdma = (uintptr_t)descriptors[0];
    jobs[0].tdma_count = 1;
    jobs[2].tdma = (uintptr_t)descriptors[1];
    jobs[2].tdma_count = 1;
    struct sg2002_tpu_batch batch = { .jobs = (uintptr_t)jobs, .count = 3 };
    memset(data + 16, 0, 16);
    if (sg2002_tpu_write(fd, &buffer, 0, data, sizeof(data)) ||
        ioctl(fd, SG2002_TPU_BATCH, &batch) != -1 || errno != EINVAL ||
        sg2002_tpu_read(fd, &buffer, 0, output, sizeof(output)))
        goto done;
    memcpy(data + 16, data, 16);
    if (memcmp(data, output, sizeof(data))) {
        errno = EILSEQ;
        goto done;
    }
    printf("PASS %lu TDMA descriptors, guards and stop-on-error batch\n", count);
    ret = 0;
done:
    if (ret) perror("large TPU job");
    if (buffer.handle && sg2002_tpu_free(fd, &buffer)) ret = 1;
    if (ctx) {
        ctx->ops->cleanup(ctx);
        free(ctx->priv_data);
        free(ctx);
    }
    free(config.cmdbuf);
    if (fd >= 0) close(fd);
    return ret;
}
