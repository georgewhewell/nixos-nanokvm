/* SPDX-License-Identifier: GPL-2.0-only */
.option arch, +xtheadvector
.text
.global vector_roundtrip
.type vector_roundtrip, @function
/* a0=input[512], a1=output[512], a2=spin count, a3=VXRM/VXSAT packed as VCSR. */
vector_roundtrip:
 addi sp, sp, -16
 sd s0, 0(sp)
 sd s1, 8(sp)
 mv s0, a1
 th.vsetvli t0, zero, e8, m8
 th.vlbu.v v0, (a0)
 add a0, a0, t0
 th.vlbu.v v8, (a0)
 add a0, a0, t0
 th.vlbu.v v16, (a0)
 add a0, a0, t0
 th.vlbu.v v24, (a0)
 li t0, 7
 th.vsetvli zero, t0, e16, m2
 srli t3, a3, 1
 andi t4, a3, 1
 csrw vxrm, t3
 csrw vxsat, t4
 /* Linux is allowed to discard vector state on an explicit syscall.
  * Keep registers live across involuntary preemption instead. */
1:
 addi a2, a2, -1
 bnez a2, 1b
 li s1, 0
 csrr t0, vl
 li t1, 7
 bne t0, t1, 21f
 csrr t0, vtype
 li t1, 5 /* e16,m2, draft 0.7.1 encoding */
 bne t0, t1, 22f
 csrr t0, vxrm
 bne t0, t3, 23f
 csrr t0, vxsat
 bne t0, t4, 24f
 j 3f
21:
 li s1, -1
 j 3f
22:
 li s1, -2
 j 3f
23:
 li s1, -3
 j 3f
24:
 li s1, -4
3:
 th.vsetvli t0, zero, e8, m8
 th.vsb.v v0, (s0)
 add s0, s0, t0
 th.vsb.v v8, (s0)
 add s0, s0, t0
 th.vsb.v v16, (s0)
 add s0, s0, t0
 th.vsb.v v24, (s0)
 mv a0, s1
 ld s0, 0(sp)
 ld s1, 8(sp)
 addi sp, sp, 16
 ret
.size vector_roundtrip, .-vector_roundtrip

.global vector_signal_clobber
.type vector_signal_clobber, @function
vector_signal_clobber:
 th.vsetvli t0, zero, e8, m8
 th.vmv.v.i v0, -1
 th.vmv.v.i v8, -1
 th.vmv.v.i v16, -1
 th.vmv.v.i v24, -1
 csrwi vxrm, 0
 csrwi vxsat, 0
 ret
.size vector_signal_clobber, .-vector_signal_clobber
.section .note.GNU-stack,"",@progbits
