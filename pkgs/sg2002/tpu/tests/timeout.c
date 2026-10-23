/* SPDX-License-Identifier: MIT */
/* Destructive to the current TPU session: a real board reset is required. */
#include "sg2002-tpu-runtime.h"
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    if (argc != 2 || strcmp(argv[1], "--require-board-reset")) {
        fprintf(stderr, "usage: sg2002-tpu-timeout-test --require-board-reset\n");
        return 2;
    }
    int fd = sg2002_tpu_open();
    struct sg2002_tpu_buffer buffer;
    if (fd < 0 || sg2002_tpu_alloc(fd, 4096, &buffer)) {
        perror("TPU allocation");
        return 1;
    }
    /* One common-mode G2G byte copy blocked on an unreachable TIU ID.
     * All actual DMA addresses belong to this open file. */
    uint32_t tdma[16] = {0};
    tdma[0] = 1 | (1 << 2) | (1 << 3) | (1 << 4) | (2 << 6) |
              (1 << 8) | (1 << 16);
    tdma[1] = 0xffff0000;
    tdma[7] = 16;
    tdma[11] = buffer.dma_address + 64;
    tdma[12] = buffer.dma_address;
    struct sg2002_tpu_submit job = {
        .tdma = (uintptr_t)tdma, .tdma_count = 1, .timeout_ms = 20,
    };
    if (ioctl(fd, SG2002_TPU_SUBMIT, &job) != -1 || errno != ETIMEDOUT) {
        perror("expected TPU timeout");
        return 1;
    }
    struct sg2002_tpu_info info;
    if (ioctl(fd, SG2002_TPU_INFO, &info) != -1 || errno != ENODEV) {
        perror("poisoned TPU accepted another operation");
        return 1;
    }
    close(fd);
    puts("PASS timeout returned ETIMEDOUT; subsequent operation returned ENODEV; board reset required");
    return 0;
}
