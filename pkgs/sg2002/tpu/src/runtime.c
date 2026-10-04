/* SPDX-License-Identifier: MIT */
#include "sg2002-tpu-runtime.h"
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

int sg2002_tpu_open(void)
{
    struct sg2002_tpu_info info;
    int fd = open("/dev/sg2002-tpu", O_RDWR | O_CLOEXEC);
    if (fd < 0)
        return -1;
    if (ioctl(fd, SG2002_TPU_INFO, &info) < 0) {
        int saved = errno;
        close(fd);
        errno = saved;
        return -1;
    }
    if (info.abi_version != SG2002_TPU_ABI_VERSION) {
        close(fd);
        errno = EPROTONOSUPPORT;
        return -1;
    }
    return fd;
}

int sg2002_tpu_alloc(int fd, uint32_t bytes, struct sg2002_tpu_buffer *b)
{
    *b = (struct sg2002_tpu_buffer){ .size = bytes };
    return ioctl(fd, SG2002_TPU_ALLOC, b);
}

int sg2002_tpu_free(int fd, struct sg2002_tpu_buffer *b)
{
    struct sg2002_tpu_buffer req = { .handle = b->handle };
    int ret = ioctl(fd, SG2002_TPU_FREE, &req);
    if (!ret)
        memset(b, 0, sizeof(*b));
    return ret;
}

static int transfer(int fd, const struct sg2002_tpu_buffer *b, uint32_t offset,
                    void *data, uint32_t bytes, unsigned long command)
{
    struct sg2002_tpu_transfer req = {
        .handle = b->handle, .offset = offset, .size = bytes,
        .data = (uintptr_t)data,
    };
    return ioctl(fd, command, &req);
}

int sg2002_tpu_write(int fd, const struct sg2002_tpu_buffer *b, uint32_t offset,
                     const void *data, uint32_t bytes)
{
    return transfer(fd, b, offset, (void *)data, bytes, SG2002_TPU_WRITE);
}

int sg2002_tpu_read(int fd, const struct sg2002_tpu_buffer *b, uint32_t offset,
                    void *data, uint32_t bytes)
{
    return transfer(fd, b, offset, data, bytes, SG2002_TPU_READ);
}

int sg2002_tpu_run(int fd, const void *commands, size_t bytes,
                   const uint32_t bases[8], uint32_t timeout_ms)
{
    const uint8_t *src = commands;
    struct sg2002_tpu_submit job = { .timeout_ms = timeout_ms };
    uint8_t *tiu = NULL, *tdma = NULL;
    size_t offset = 0;
    int ret = -1, saved;

    if (!bytes || bytes > 4096 * (120 + 72) || !commands) {
        errno = EINVAL;
        return -1;
    }
    /* First pass validates the entire stream before allocating or submitting. */
    while (offset < bytes) {
        if (bytes - offset < 8 || src[offset] != 0xa7)
            goto invalid;
        unsigned length = src[offset + 1], engine = src[offset + 2] & 15;
        if ((engine == 0 && length != 112) ||
            (engine == 2 && length != 64) || (engine != 0 && engine != 2) ||
            bytes - offset - 8 < length)
            goto invalid;
        if (engine == 0)
            job.tiu_count++;
        else
            job.tdma_count++;
        if (job.tiu_count > 4096 || job.tdma_count > 4096)
            goto invalid;
        offset += 8 + length;
    }
    tiu = calloc(job.tiu_count ?: 1, 112);
    tdma = calloc(job.tdma_count ?: 1, 64);
    if (!tiu || !tdma)
        goto done;
    unsigned nt = 0, nd = 0;
    for (offset = 0; offset < bytes; offset += 8 + src[offset + 1]) {
        const uint8_t *body = src + offset + 8;
        if ((src[offset + 2] & 15) == 0) {
            uint8_t *dest = tiu + nt++ * 112;
            memcpy(dest, body, 112);
            if (nt == job.tiu_count)
                dest[0] |= (1 << 1) | (1 << 4); /* end and interrupt */
            /* TIU fetch order: seven 128-bit words, with register IDs in the
             * high nibble; the last word is transferred first. */
            for (unsigned i = 0; i < 7; i++)
                dest[i * 16 + 15] |= i << 4;
            uint8_t first[16];
            memcpy(first, dest, 16);
            memcpy(dest, dest + 96, 16);
            memcpy(dest + 96, first, 16);
        } else {
            uint8_t *dest = tdma + nd++ * 64;
            memcpy(dest, body, 64);
            dest[0] |= 1 << 4; /* barrier */
            if (nd == job.tdma_count)
                dest[0] |= (1 << 2) | (1 << 3); /* end and interrupt */
        }
    }
    job.tiu = (uintptr_t)tiu;
    job.tdma = (uintptr_t)tdma;
    if (bases)
        memcpy(job.base_handles, bases, sizeof(job.base_handles));
    ret = ioctl(fd, SG2002_TPU_SUBMIT, &job);
    goto done;
invalid:
    errno = EINVAL;
done:
    saved = errno;
    free(tiu);
    free(tdma);
    errno = saved;
    return ret;
}
