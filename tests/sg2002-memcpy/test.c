// SPDX-License-Identifier: GPL-2.0-only
#include <linux/interrupt.h>
#include <linux/ktime.h>
#include <linux/module.h>
#include <linux/preempt.h>
#include <linux/slab.h>
#include <linux/vmalloc.h>
#include <asm/simd.h>
#include <asm/vector.h>

asmlinkage void *test_memcpy(void *, const void *, size_t);
asmlinkage void *test_memcpy_scalar(void *, const void *, size_t);
asmlinkage void *test_memcpy_vector(void *, const void *, size_t);
asmlinkage void test_nested_load(const void *);
asmlinkage void test_nested_store(void *);

typedef void *(*copy_fn)(void *, const void *, size_t);
static unsigned int mib = 4;
module_param(mib, uint, 0400);
MODULE_PARM_DESC(mib, "MiB copied per timing sample (1..256)");

static int check_copy(u8 *dst, const u8 *src, size_t n)
{
	copy_fn copies[] = { test_memcpy, memcpy };
	unsigned int i;

	/* Check both the private candidate and the running kernel's entry. */
	for (i = 0; i < ARRAY_SIZE(copies); i++) {
		memset(dst - 32, 0xa5, n + 64);
		if (copies[i](dst, src, n) != dst || memcmp(dst, src, n) ||
		    memchr_inv(dst - 32, 0xa5, 32) ||
		    memchr_inv(dst + n, 0xa5, 32))
			return -EINVAL;
	}
	return 0;
}

static int correctness(u8 *dst, const u8 *src)
{
	static const size_t sizes[] = {
		511, 512, 513, 767, 768, 769, 1023, 1024, 1025,
		2047, 2048, 2049, 4095, 4096, 4097, 8191, 8192, 8193,
		65535, 65536, 65537, 1048576,
	};
	unsigned int s, d, n;

	for (s = 0; s < 16; s++) {
		for (d = 0; d < 16; d++) {
			for (n = 0; n <= 257; n++) {
				if (check_copy(dst + d, src + s, n))
					goto fail;
			}
			for (n = 0; n < ARRAY_SIZE(sizes); n++) {
				if (check_copy(dst + d, src + s, sizes[n]))
					goto fail;
			}
		}
		cond_resched();
	}
	return 0;
fail:
	pr_err("sg2002-memcpy: data/canary failure src+%u dst+%u case=%u\n", s, d, n);
	return -EINVAL;
}

/* vmalloc's unmapped trailing page catches reads and writes past the range. */
static int boundaries(u8 *other)
{
	u8 *page = vmalloc(PAGE_SIZE);
	unsigned int n;
	int ret = -EINVAL;

	if (!page)
		return -ENOMEM;
	memset(page, 0x69, PAGE_SIZE);
	for (n = 0; n <= PAGE_SIZE; n++) {
		if (test_memcpy(other, page + PAGE_SIZE - n, n) != other ||
		    memchr_inv(other, 0x69, n))
			goto out;
		if (test_memcpy(page + PAGE_SIZE - n, other, n) != page + PAGE_SIZE - n ||
		    memchr_inv(page + PAGE_SIZE - n, 0x69, n))
			goto out;
	}
	ret = 0;
out:
	vfree(page);
	return ret;
}

static int contexts(u8 *dst, const u8 *src)
{
	u8 before[128], after[128];
	unsigned long flags;
	int ret;

	preempt_disable();
	ret = check_copy(dst + 3, src + 1, 4096);
	preempt_enable();
	if (ret)
		return ret;
	local_irq_save(flags);
	ret = check_copy(dst + 3, src + 1, 4097);
	local_irq_restore(flags);
	if (ret)
		return ret;
	local_bh_disable();
	ret = check_copy(dst + 3, src + 1, 4096);
	local_bh_enable();
	if (ret || !has_xtheadvector())
		return ret;

	memset(before, 0x37, sizeof(before));
	memset(after, 0, sizeof(after));
	if (!may_use_simd())
		return -EBUSY;
	kernel_vector_begin();
	test_nested_load(before);
	ret = check_copy(dst + 3, src + 1, 4096);
	test_nested_store(after);
	kernel_vector_end();
	if (ret || memcmp(before, after, sizeof(before)))
		return -EINVAL;
	return 0;
}

static void bench_one(const char *name, copy_fn fn, u8 *dst, const u8 *src,
		      size_t n, bool streaming, unsigned int so, unsigned int doff)
{
	const size_t span = 4 * 1024 * 1024;
	u64 best = U64_MAX, start, elapsed;
	size_t off, i, iters = max_t(size_t, 128, (size_t)mib * 1024 * 1024 / n);
	unsigned int sample;

	for (sample = 0; sample < 5; sample++) {
		off = 0;
		start = ktime_get_ns();
		for (i = 0; i < iters; i++) {
			fn(dst + off + doff, src + off + so, n);
			if (streaming) {
				off += ALIGN(n + 16, 64);
				if (off + n + 16 > span)
					off = 0;
			}
		}
		elapsed = ktime_get_ns() - start;
		best = min(best, elapsed);
		cond_resched();
	}
	pr_info("sg2002-memcpy: %s %s n=%zu src+%u dst+%u ns/copy=%llu MiB/s=%llu\n",
		name, streaming ? "stream" : "hot", n, so, doff,
		div64_u64(best, iters),
		div64_u64((u64)n * iters * NSEC_PER_SEC, best * 1024 * 1024));
}

static int __init sg2002_memcpy_init(void)
{
	static const size_t sizes[] = {
		64, 128, 256, 512, 768, 1024, 1536, 2048, 4096, 8192,
		16384, 65536, 1048576,
	};
	u8 *src, *dst;
	unsigned int i, mode, align;
	int ret;

	if (!mib || mib > 256)
		return -EINVAL;
	src = vmalloc(4 * 1024 * 1024 + 128);
	dst = vmalloc(4 * 1024 * 1024 + 128);
	if (!src || !dst) {
		ret = -ENOMEM;
		goto out;
	}
	for (i = 0; i < 4 * 1024 * 1024 + 128; i++)
		src[i] = (i * 17 + (i >> 8)) & 255;
	pr_info("sg2002-memcpy: xtheadvector=%d preemptive=%d mib=%u\n",
		has_xtheadvector(), IS_ENABLED(CONFIG_RISCV_ISA_V_PREEMPTIVE), mib);
	ret = correctness(dst + 64, src + 64);
	if (!ret)
		ret = boundaries(dst + 64);
	if (!ret)
		ret = contexts(dst + 64, src + 64);
	if (ret)
		goto out;
	pr_info("sg2002-memcpy: PASS data, return value, canaries, guard page, atomic and nested contexts\n");
	for (mode = 0; mode < 2; mode++) {
		for (align = 0; align < 2; align++) {
			for (i = 0; i < ARRAY_SIZE(sizes); i++) {
				unsigned int so = align ? 1 : 0, doff = align ? 3 : 0;

				bench_one("scalar", test_memcpy_scalar, dst, src, sizes[i], mode, so, doff);
				bench_one("candidate", test_memcpy, dst, src, sizes[i], mode, so, doff);
				/* Measure entry cost below the provisional dispatch threshold. */
				if (has_xtheadvector() && sizes[i] <= 4096)
					bench_one("vector", test_memcpy_vector, dst, src, sizes[i], mode, so, doff);
			}
		}
	}
out:
	vfree(dst);
	vfree(src);
	if (ret)
		pr_err("sg2002-memcpy: FAIL %d\n", ret);
	return ret;
}

static void __exit sg2002_memcpy_exit(void) { }
module_init(sg2002_memcpy_init);
module_exit(sg2002_memcpy_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("SG2002 memcpy candidate correctness and scalar comparison");
