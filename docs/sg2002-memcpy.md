# SG2002 kernel memcpy

Patch 0084 uses the assembler-visible vendor extension keys from patch
0082. Hardware measurements support vector use for buffers with different
offsets within an eight-byte word; matching alignments retain the scalar
implementation. The conservative 1,024-byte threshold amortizes vector
entry overhead.

The ordinary scalar routine is unchanged. An XTheadVector alternative
selects a byte-vector loop for copies of at least 1,024 bytes when
`(src XOR dst) & 7` is nonzero, in preemptible task context.
Its `e8,m8` setting copies up to 128 bytes per iteration on
C906, accepts arbitrary alignment, and accesses only the requested range.
The return value remains the original destination. The normal memcpy
contract still applies: disjoint ordinary kernel memory, not MMIO.

The dispatch remains scalar during early boot, with Ghostwrite mitigation
active, without preemption accounting, in interrupt/atomic contexts, and
inside either kind of kernel vector context. Both `__pi_` aliases bypass
the dispatch, and the standalone kexec purgatory uses only the scalar
routine. Uninstrumented preemption guards cover vector entry and
exit, including the interval before ownership flags are established;
recursive memcpy calls there take the scalar path. Preemptible vector
contexts retain preemption during the actual copy. No global compiler ISA
setting changes and no new exported kernel API are needed.

## Hardware measurements

Module results on the LicheeRV Nano C906 at 1 GHz, Linux 7.2.8, with
patches 0082–0085 applied and vector access enabled for the diagnostic
RAM boot (2026-10-04). Times include dispatch and vector context overhead.

| Copy | Offsets src/dst | Scalar ns | Selected routine ns |
| --- | --- | ---: | ---: |
| 1 KiB hot | 0 / 0 | 315 | 321 |
| 4 KiB hot | 0 / 0 | 1,170 | 1,175 |
| 4 KiB stream | 0 / 0 | 3,379 | 3,442 |
| 1 KiB hot | 1 / 3 | 5,189 | 582 |
| 4 KiB hot | 1 / 3 | 20,636 | 1,404 |
| 4 KiB stream | 1 / 3 | 22,295 | 4,231 |

The first three cases use scalar copies; the final three use vectors.
The 4 KiB misaligned cases improve by about 14.7× hot and 5.3× streaming.
These are focused copy measurements, not application throughput claims.

The first long-copy test exposed a trap-entry bug: the standard status
mask left half of T-Head VS enabled, triggering scheduler warnings during
IRQ preemption. Patch 0082 now clears the complete T-Head field. The
combined kernel passed the repeated copy test without these warnings. The
final module also passed through the real kernel `memcpy` entry, both with
vectors enabled and on the normal mitigated boot. A concurrent vector
register/signal stress run passed without warnings or data mismatches.

## Focused module test

`tests/sg2002-memcpy` compiles the exact candidate under private symbol
names and also checks the running kernel’s `memcpy` entry. It can run
before changing the kernel's global memcpy. Its scalar reference is the unchanged scalar body from the same assembly file.
Use a Linux 7.2.8 source tree **before applying 0084**, plus build headers
for the running kernel with patches 0082 and 0083:

```sh
bash tests/sg2002-memcpy/prepare.sh "$linuxSource" /tmp/sg2002-memcpy-test
make -C "$kernelDev/lib/modules/7.2.8/build" \
  M=/tmp/sg2002-memcpy-test ARCH=riscv \
  CROSS_COMPILE=riscv64-unknown-linux-gnu- \
  KCFLAGS=-mtune=thead-c906 modules
```

On the board, load `sg2002_memcpy_test.ko` with `insmod ... mib=4`, collect the
full kernel journal (including warnings), then unload it. For example,
use `journalctl -k -b --no-pager`; the dmesg ring may wrap during a long
run. The module uses about 8 MiB of temporary buffers. `mib` controls bytes copied per timing
sample, from 1 to 256 MiB; each result is the best of five elapsed-time
samples, including vector context overhead. Fix the CPU at 1 GHz and stop
unrelated workloads for performance measurements.

The checks cover zero and small sizes, threshold and page boundaries,
copies through 1 MiB, all 256 source/destination offset combinations from
0 through 15, return values, destination canaries, and unmapped trailing
guard pages. Context checks disable preemption, IRQs and bottom halves,
then verify that a copy inside a vector region preserves live vector
registers. A failed check rejects module loading.

Timing compares scalar, selected candidate and explicitly entered vector
paths. Sizes run from 64 bytes through 1 MiB, both aligned and with
`src+1/dst+3`. “hot” repeatedly uses the same buffer; large buffers still
exceed cache capacity. “stream” rotates through a 4 MiB working set.
The explicit vector result is emitted only when XTheadVector is enabled.

## Reproduce the validation

1. Run the module on a normal mitigated boot, then on the diagnostic RAM
   boot with vector access enabled. Require every correctness check to pass.
2. Repeat aligned and misaligned measurements after the alignment gate;
   verify that aligned copies retain scalar performance and the misaligned
   gains remain. Keep the conservative threshold unless data justify a change.
3. Boot a kernel applying 0084 globally. Repeat the module tests, usercopy
   fault tests and competing userspace vector/signal preservation tests.
   Run the vector stress concurrently with the module for the context soak,
   separately from performance measurements. Inspect dmesg for warnings.
4. Confirm the ordinary mitigated boot still reports XTheadVector disabled,
   and review the final C object for scalar-only code and no generated
   memcpy calls. Preserve the default boot mitigation policy.

The module cannot prove the early-boot path; the full-kernel RAM boot is
required. It also cannot establish that the SG2002 is immune to Ghostwrite.
