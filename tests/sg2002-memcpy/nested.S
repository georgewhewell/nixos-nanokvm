/* SPDX-License-Identifier: GPL-2.0-only */
#include <linux/linkage.h>

	.option push
	.option arch, rv64gc_xtheadvector
SYM_FUNC_START(test_nested_load)
	li t0, 128
	th.vsetvli t0, t0, e8, m8
	th.vlb.v v0, (a0)
	ret
SYM_FUNC_END(test_nested_load)

SYM_FUNC_START(test_nested_store)
	li t0, 128
	th.vsetvli t0, t0, e8, m8
	th.vsb.v v0, (a0)
	ret
SYM_FUNC_END(test_nested_store)
	.option pop
