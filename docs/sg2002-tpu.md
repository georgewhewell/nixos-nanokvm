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

## Vendor model examples

`sg2002-cviruntime` builds the vendor `.cvimodel` loader and CPU operators from
[pinned source](https://github.com/sophgo/cviruntime/tree/ef8044988c2b4a5d491125d13e6f048b5f8a1389).
Its SG2002 backend uses owned DMA allocations, explicit copies and atomic TPU
batches. Encrypted models requiring vendor trusted firmware and PMU capture are
unsupported. Kernel errors propagate through `CVI_NN_Forward`; there is no
simulator fallback. Applications can use the installed `cviruntime.h` API.

`sg2002-tpu-examples` builds the vendor MobileNet classifier and YOLOv5 detector
with a small OpenCV configuration. Both take JPEG images, reject incompatible
model layouts, check inference errors and optionally compare repeated outputs.
Image decoding, output conversion and detection postprocessing run on the CPU.
The upstream runtime, schema generator and samples have no repository license
grant at these revisions; their Nix packages are marked unfree.

Build the examples and models on an x86_64 Linux build host:

```sh
nix build .#sg2002-tpu-examples -o result-examples
nix build .#sg2002-tpu-mobilenet-v2 -o result-mobilenet
nix build .#sg2002-tpu-yolov5n -o result-yolo
```

Run on the SG2002 after installing those closures:

```sh
sudo ./result-examples/bin/sg2002-tpu-classify \
  ./result-mobilenet/mobilenet_v2.cvimodel ./result-mobilenet/cat.jpg \
  ./result-examples/share/sg2002-tpu-examples/synset_words.txt 100
sudo ./result-examples/bin/sg2002-tpu-detect \
  ./result-yolo/yolov5n.cvimodel ./result-yolo/dog.jpg detected.jpg 20
sudo ./result-examples/bin/sg2002-tpu-model-check \
  ./result-yolo/yolov5n.cvimodel ./result-yolo/input.bin ./result-yolo/reference.bin 10
```

The reference checker accepts a raw input tensor and concatenated little-endian
FP32 reference outputs in model order. It fails if any output differs beyond
`1e-6 * max(1, abs(reference))`, or if repeated inference changes a byte. The
model packages include these inputs and references from the vendor CModel.

`sg2002-tpu-mlir` packages the pinned Sophgo 1.11 **binary release** as an
x86_64 host compiler, with pinned Python 3.10 dependencies. The target runtime,
instruction generator and sample executables are built from source. The model
derivations compile and calibrate pinned Caffe/ONNX weights and 100-image vendor
datasets, and run the compiler's reference comparisons. Only model artifacts,
images and compact reference tensors belong on the board; compiler dependencies
stay on the build host. Both model derivations passed a byte-identical Nix rebuild. Recipes follow the official
[MobileNet](https://milkv.io/docs/duo/application-development/tpu/tpu-mobilenetv2)
and [YOLOv5](https://milkv.io/docs/duo/application-development/tpu/tpu-yolov5)
tutorials, using YOLOv5n to fit the board's memory.

On the same RAM-booted Linux 7.2.8 board, the Nix-installed model checker passed
100 MobileNet and 20 YOLOv5n inferences. Every FP32 value matched CModel exactly:
1,000 classification values and 2,142,000 detection values, with zero maximum
absolute error. IRQ 76 increased by exactly 120. MobileNet averaged 9.76 ms wall /
3.79 ms process CPU per forward; YOLOv5n averaged 194.27 / 167.85 ms. These forward
measurements include runtime data copies and output conversion, and exclude JPEG
decoding, NMS and drawing. The detector's FP32 output conversion is substantial CPU
work; these numbers are not TPU-only latency.

The JPEG examples identified the cat as Egyptian cat and drew dog/car boxes on
`dog.jpg`. Concurrent classifier, detector and matrix workloads also passed.
Injecting a failed submission made `CVI_NN_Forward` and the sample fail, with no
result image and no hardware interrupt.
