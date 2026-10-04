/* SPDX-License-Identifier: GPL-2.0 WITH Linux-syscall-note */
#ifndef _UAPI_SG2002_TPU_H
#define _UAPI_SG2002_TPU_H
#include <linux/ioctl.h>
#include <linux/types.h>

#define SG2002_TPU_ABI_VERSION 1
#define SG2002_TPU_TIU_BYTES 112
#define SG2002_TPU_TDMA_BYTES 64

struct sg2002_tpu_info {
	__u32 abi_version;
	__u32 max_commands;
	__u64 clock_hz;
};

/* Allocation is owned by the open file; closing it releases all buffers. */
struct sg2002_tpu_buffer {
	__u32 handle;
	__u32 size;
	__u64 dma_address;
};

struct sg2002_tpu_transfer {
	__u32 handle;
	__u32 offset;
	__u32 size;
	__u32 reserved;
	__u64 data;
};

/* Raw hardware descriptors, already reordered for descriptor mode. */
struct sg2002_tpu_submit {
	__u64 tiu;
	__u64 tdma;
	__u32 tiu_count;
	__u32 tdma_count;
	__u32 base_handles[8]; /* 0 means base address zero */
	__u32 timeout_ms;      /* 1..10000; 0 selects 2000 */
	__u32 reserved;
};

#define SG2002_TPU_INFO _IOR('T', 0x00, struct sg2002_tpu_info)
#define SG2002_TPU_ALLOC _IOWR('T', 0x01, struct sg2002_tpu_buffer)
#define SG2002_TPU_FREE _IOW('T', 0x02, struct sg2002_tpu_buffer)
#define SG2002_TPU_WRITE _IOW('T', 0x03, struct sg2002_tpu_transfer)
#define SG2002_TPU_READ _IOW('T', 0x04, struct sg2002_tpu_transfer)
#define SG2002_TPU_SUBMIT _IOW('T', 0x05, struct sg2002_tpu_submit)
#endif
