/* SPDX-License-Identifier: MIT */
#ifndef SG2002_TPU_RUNTIME_H
#define SG2002_TPU_RUNTIME_H
#include <stddef.h>
#include <stdint.h>
#include "sg2002_tpu.h"

/* open returns a file descriptor; other functions return 0 on success.
 * All return -1 with errno on failure. There is no software fallback.
 */
int sg2002_tpu_open(void);
int sg2002_tpu_alloc(int fd, uint32_t bytes, struct sg2002_tpu_buffer *buffer);
int sg2002_tpu_free(int fd, struct sg2002_tpu_buffer *buffer);
int sg2002_tpu_write(int fd, const struct sg2002_tpu_buffer *buffer,
                     uint32_t offset, const void *data, uint32_t bytes);
int sg2002_tpu_read(int fd, const struct sg2002_tpu_buffer *buffer,
                    uint32_t offset, void *data, uint32_t bytes);
/* CV181x cvikernel raw command stream, at most 4096 descriptors per engine.
 * Addresses in commands use buffer.dma_address, or base_handles + offsets.
 * CPU descriptors and streams requiring ID wrap must be split by the caller.
 */
int sg2002_tpu_run(int fd, const void *commands, size_t bytes,
                   const uint32_t base_handles[8], uint32_t timeout_ms);
#endif
