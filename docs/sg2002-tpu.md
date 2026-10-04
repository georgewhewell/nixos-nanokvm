# SG2002 TPU

The SG2002 mainline kernel provides `/dev/sg2002-tpu` for CV181x TIU/TDMA
command execution. `sg2002-tpu` supplies a C library, installed headers,
`pkg-config` metadata and an INT8 matrix multiplication demo. The demo compares
hardware output byte-for-byte with a CPU reference; it has no software fallback.

```sh
nix build .#sg2002-tpu
# On a board booted with this kernel:
sudo ./result/bin/sg2002-tpu-demo 100
# Check independent TIU/TDMA segments in one atomic batch:
sudo ./result/bin/sg2002-tpu-demo 1 --split
```

The optional argument is the repeat count per case. Cases include irregular
matrix dimensions, both INT8 extrema and saturation. Output reports wall time,
process CPU time and CPU-reference time. The measured job cost includes command
submission, input/output copies and verification; it is not a peak-TOPS claim.

`sg2002-cvikernel` builds Sophgo's CV181x instruction generator for the board;
`sg2002-cvikernel-host` builds the same generator for the build host. Both use
pinned source. The upstream revision has no repository license grant, so the
Nix derivation deliberately marks it **unfree**, rather than inventing a license.
The flake's allowlist includes it. The small submission library and demo are MIT;
the kernel driver is GPL-2.0-only.

Applications allocate owned DMA buffers with `sg2002_tpu_alloc`, copy data with
`sg2002_tpu_write/read`, generate operations using `cvikernel`, and pass the
resulting command stream to `sg2002_tpu_run`. The installed `demo.c` shows the
complete sequence. Each submission accepts up to 65535 descriptors per engine;
`sg2002_tpu_run_batch` executes up to 64 streams atomically at synchronization
boundaries, preserving local SRAM between segments. A batch stops at its first
error; earlier completed segments are not rolled back. The raw kernel interface
also accepts TIU-only and TDMA-only jobs. The library accepts CV181x command
streams, not `.cvimodel` files; it does not provide the vendor model loader or
CPU-layer implementation.

Command descriptors contain unrestricted bus addresses, and this SoC has no
configured IOMMU. Device permissions are `0600` and every operation checks
`CAP_SYS_RAWIO` in the initial user namespace. Do not delegate access to an
untrusted process. Buffer handles are per open file; all transfers, jobs and
frees are serialized. Command lists are copied before execution.
TPU/fabric clocks run from the first open until the last close; idle support
does not keep the accelerator clocked. Tensor SRAM is shared between clients,
so dependent segments must be submitted in one job or atomic batch. Coherent DMA
allocations use the Linux DMA API on the noncoherent C906; ION and `/dev/mem` are
not used. The driver reserves no static RAM carveout and shares the ordinary
contiguous allocator with other devices.

A job has a bounded timeout. Signals do not interrupt an active DMA transfer;
its completion or timeout is awaited before releasing memory. The available
hardware documentation does not guarantee that an IP reset drains outstanding
AXI transactions. A timed-out or failed job therefore disables further jobs and
retains its DMA memory and clocks. The driver pins itself against module unload
and requires a real board reset before memory can be reused, including during
shutdown/kexec. A normal successful job does not enter this path.

Register sequencing follows [Sophgo's CV181x driver](https://github.com/sophgo/osdrv/tree/1b3a49649d18488ecf54fb4fcb6c27599e433fdc/interdrv/tpu/hal/cv181x).
Instruction generation uses [cvikernel 0b37e466](https://github.com/sophgo/cvikernel/tree/0b37e46607be203bf9d4d29995f6fa4bbab69435).
The shared SoC device tree uses master-C906 TDMA interrupt 76, TPU/fabric clocks,
and TDMA/TIU/system resets; slave-C906L interrupt 52 is a different routing.

Tested on the Ethernet/camera LicheeRV Nano attached to `strix-3`, using a
RAM-booted Linux 7.2.8 image; storage was not written. Validation passed
48,000 checked jobs from two concurrent processes, 2,400 repeat jobs, isolated
TIU/TDMA jobs, buffer bounds, file-handle ownership, and dropped-privilege access.
An atomic-batch extension additionally passed 4,800 three-segment matrix
operations from two concurrent processes, and 5,000/65,535-descriptor TDMA jobs
with guard checks. SIGINT during a workload returned 130; a following demo passed. An injected
unreachable synchronization ID returned `ETIMEDOUT`, after which operations
returned `ENODEV` and DMA allocations remained quarantined. The final driver
showed clock counts 0/1/0 before open, while open and after close; following
a timeout both clock counts remained 1 until the board reset.

For the 64×128×64 INT8 case, the initial 100-repeat run measured approximately
0.26 ms wall and 0.24 ms process CPU per checked hardware job, versus 8.2 ms for
the demo's scalar CPU reference. Tiny cases are slower through the TPU interface.
This is a correctness demo with basic timing, not an optimized BLAS comparison.

The explicit fault helper is installed under `libexec/sg2002-tpu-timeout-test`.
Running it with `--require-board-reset` intentionally poisons the TPU until the
board is rebooted; it is excluded from the ordinary demo. Arm the board's RAM
boot recovery first when testing a diskless image.
