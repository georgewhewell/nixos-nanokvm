# SG2002 C906 vector support

The SG2002's main C906 implements **XTheadVector with 128-bit registers**.
It is based on vector draft 0.7.1 and is not compatible with ratified RVV
1.0. These results concern the Linux C906, not the auxiliary C906L.

## Hardware evidence

On a LicheeRV Nano running Linux 7.2.8, tested 2026-10-04:

- With vector support compiled out, userspace `vsetvli` raises `SIGILL`.
  This establishes that userspace cannot use vector instructions; it does
  not establish whether the hardware exists.
- A temporary kernel probe enabled T-Head's `sstatus.VS[24:23]`, with
  interrupts/preemption disabled and exception fixups for illegal
  instructions. `vsetvli` succeeded, returning 16 elements for `e8,m1`;
  `vl=16`, `vtype=0`, and `vlenb=16` were readable.
- With VS off, or only standard RVV's VS bits requested, the same
  instruction trapped. The probe restored the original status register.
- Vector byte loads, addition and stores matched scalar results for
  4,096 elements, with intact destination canaries.

The old “no vector unit” assertion in the PMU check came from the first,
userspace-only test. The old early-boot comment also attributed a hang to
vector support without isolating that cause. Neither claim should be
used to describe the hardware. Linux 7.2's unaligned vector probe is gated
on standard vector support, which this device tree does not advertise.

## Kernel support and policy

Kernel patch 0085 describes `xtheadvector` and `thead,vlenb = <16>` in
`sg2002.dtsi`, so the capability belongs to the SoC. The standalone DTB
builder applies the same patch to its kernel source. It does not infer
CPU capabilities from a carrier or from the shared CV180x CPU description.
The kernel includes upstream vector context handling and its Ghostwrite
mitigation. **Normal boots still disable XTheadVector access** and report:

```
/sys/devices/system/cpu/vulnerabilities/ghostwrite:
Mitigation: xtheadvector disabled
```

The [Ghostwrite researchers](https://ghostwriteattack.com/) identify C910
and C920 as affected. Linux applies its mitigation to the shared T-Head
CPU ID also used here.
These tests do not establish that SG2002 is exploitable or unaffected.
To enable vector access in a mainline NixOS configuration:

```nix
sg2002.mitigations = false;
```

The option defaults to `true`. Setting it to `false` adds `mitigations=off`
to both SD and USB RAM boot command lines. This disables all CPU mitigations
controlled by that argument, not just Ghostwrite. With it, `riscv_hwprobe`
reports XTheadVector and the guarded kernel copy paths become available;
the standard V hardware capability remains clear. An image built with this
option was booted without a command-line override: its generated command line
contained `mitigations=off`, and the vector, usercopy and kernel-copy checks
passed. Ordinary scalar binaries retain their ISA.

Three C906 details require a local context-handling fix:

1. VXRM/VXSAT alias FCSR bits 10:8. Restoring another task's FCSR before
   saving the outgoing vector controls loses its rounding/saturation state.
2. Writes to VXRM/VXSAT dirty FS but leave VS clean. The vector controls
   therefore need saving even when the vector register file is clean.
3. Trap entry must clear both T-Head VS bits. The standard mask left VS
   partly enabled during interrupts, confusing preemptible vector ownership.

Patch 0082 fixes the save order and dirty-state handling, and checks the
T-Head VS bits at trap entry and when managing preemptible kernel contexts.

## Reproduce the userspace checks

Build the configuration checks and static hardware test:

```sh
nix build .#checks.x86_64-linux.sg2002-vector
```

Copy `result/bin/sg2002-vector-test` to the board. On a normal boot:

```sh
./sg2002-vector-test --expect-disabled
```

On a diagnostic boot with vector access enabled:

```sh
./sg2002-vector-test
```

The latter runs four competing processes. Each fills all 32 vector
registers with a distinct pattern and checks VL, VTYPE, VXRM and VXSAT
across timer preemption. Asynchronous signal handlers overwrite the
vector registers and controls before returning. Each worker must observe
both signals and involuntary context switches; there are 4,000 checks in
total. Guard bytes detect stores outside the expected 512-byte context.
An explicit syscall is not a valid preservation test: Linux is allowed
to discard vector state at syscall entry. The combined kernel passed nine
runs (36,000 checks), including concurrent usercopy and kernel-copy tests,
without kernel warnings. The normal mitigated boot passed
`--expect-disabled`, all 4,864 usercopy cases and the kernel-copy module.

## NanoKVM-PCIe deployment

On 2026-10-04, the same patch series was deployed as a full NixOS SD
generation on a NanoKVM-PCIe, with `sg2002.mitigations = false`. Linux
7.2.8 booted and passed the existing extlinux try-boot health check.
Ethernet SSH remained available, and the HDMI bridge and MediaMTX ran
without service restarts or failed units.

With HDMI capture and H.264 encoding active, the board passed another
4,000 vector register/control checks, all 4,864 usercopy cases and fault
tests, and the kernel-copy module's data, return-value, canary, guard-page,
atomic and nested-context checks. The module checks both the private
candidate and the running kernel's `memcpy`. The kernel journal contained
no copy-test failures, kernel warnings or oopses.

Thirty-second RTSP samples at 960×540 decoded without errors before the
upgrade, during the tests and afterwards. Frame counts divided by sample
duration were 55.2, 56.3 and 59.0 fps respectively. These are continuity
checks under different loads, not evidence of a vector-induced video
speedup. The HDMI pipeline uses hardware scaling and encoding; this
deployment establishes compatibility, not an isolated application benefit
from kernel `memcpy`.

## Compiler use

The system keeps its scalar `rv64gc` compilation baseline and C906 tuning.
XTheadVector-aware routines can be compiled with
`-march=rv64gc_xtheadvector -mtune=thead-c906`; GCC 15.3's vector intrinsics
produced working T-Head load/add/store instructions on this board.
Existing binaries do not acquire vector instructions when kernel support
is enabled, and ordinary RVV 1.0 routines cannot substitute for this ISA.
Do not globally change `nixpkgs.hostPlatform.gcc.arch` while shipped boots
keep vector access disabled.

See the [OpenSSH, OpenSSL and WPA compiler experiment](sg2002-vector-apps.md)
for package-local builds and application measurements.

References: [XuanTie ISA specification](https://github.com/XUANTIE-RV/thead-extension-spec/blob/master/xtheadvector.adoc),
[Linux vector context handling](https://github.com/torvalds/linux/blob/master/arch/riscv/include/asm/vector.h),
[Linux Ghostwrite policy](https://github.com/torvalds/linux/blob/master/arch/riscv/kernel/bugs.c).

## Device-tree composition

Nano variants start from the upstream LicheeRV Nano B DTS. NanoKVM-PCIe
starts from its own board DTS and directly includes `sg2002.dtsi`.
Both compositions explicitly include the common peripheral enablement,
Sipeed USB/IIC0 settings and shared AIC8800 wiring. The B-W overlay now
contains only the Nano B-W identity; PCIe no longer inherits that model
or its compatible strings. Camera, display and auxiliary-core overlays
remain specific to their selected carrier/profile.

## Kernel copies

Patches 0083/0084 use an `e8,m8` byte-vector loop for large copies whose
source and destination have different offsets modulo eight. Copies with
matching alignment retain the faster scalar word loop. User copies keep
the existing fault recovery and SIMD-context checks, with a minimum of
1,024 bytes as well as the normal tunable vector threshold.

`sg2002-usercopy-test` (built by the same check above) exercises pipe
read/write copies over size/alignment combinations, guard-page faults and
demand paging. `--bench` times aligned and offset pipe round trips.
See [kernel memcpy measurements and reproduction](sg2002-memcpy.md) for
the kernel-only test. Both optimizations obey the existing mitigation
policy and leave ordinary kernel C compilation scalar.
