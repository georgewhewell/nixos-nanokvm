# Mainline SG2002 hardware ISP

The mainline capture driver offers an explicit `NV21` format for RAW Bayer
sources, alongside the existing repacked RAW12 format. Selecting NV21 routes
the sensor through FE0, BE, the RAW demosaic block (CFA), RGB colour conversion
(CSC), and the YUV output engines (DMA46 for Y, DMA47 for VU). Linux owns all
registers, frame grants, interrupts and buffers. No C906L program or vendor
kernel module is needed by this implementation.

This is a first fixed-settings implementation. It disables statistics DMA,
lens shading, HDR, gamma and temporal processing; it does not implement AE,
AWB, sensor tuning or factory image quality. CFA uses reset tuning parameters;
CSC is explicitly programmed with the SDK's neutral full-range BT.601 matrix
(signed Q10 coefficients and offsets 0,512,512). Register readback is verified;
image validation with a lit, coloured scene is still required to establish
image quality. The dark-scene hardware results below establish frame transport and
are consistent with the sensor's measured black pedestal.

The existing RAW and HDMI formats remain the defaults. `VIDIOC_S_FMT` selects
the ISP only for Bayer inputs with even dimensions. Format changes are refused
while buffers exist. Both output addresses point into one vb2 allocation; a
buffer is completed at POST frame-done, rather than FE frame-done. Streamoff
waits for the pipeline and both write engines, then resets the ISP before
releasing DMA memory. Frame/DMA errors stop and error the queue.

The camera DT enables VPSS as a separate V4L2 mem2mem device, with its own
fabric-clock references. The bridge's `--isp` option requests NV21 capture and
imports that allocation into VPSS, which scales it into an NV12 DMA-BUF shared
with Coda. Demosaic, scaling and encoding run in hardware without a CPU frame
copy. All three DMA engines live under `/soc` to inherit `dma-noncoherent`;
placing them at the DT root incorrectly gives Coda a cached userspace output
mapping, which can return stale H.264 bytes when a buffer is reused. The default
is quarter resolution (640×360 for GC4653). `--size half` requests 1280×720,
but capture STREAMON runs out of the camera profile's 32 MiB media pool at
that size.

The bridge passes the capture colour tuple to VPSS and Coda, including the
extended V4L2 fields. VPSS reports this tuple on both queues because its YUV
matrix is identity. This fixes V4L2 metadata, not H.264 bitstream signalling:
Coda's current SPS crop rewrite omits VUI. Until VUI support is implemented,
image comparisons must explicitly decode as full-range BT.601 with a linear
transfer function; decoder defaults do not establish correct colour rendering.

## Reversible laboratory boot

Build the dedicated profile:

```sh
nix build .#boards.licheerv.mainline.live.usb-cam-isp.usb-boot
```

The runner serves the read-only NBD root and RAM-boots the mainline image. It
does not flash storage. The profile disables the NanoKVM application and does
not start capture automatically. Its independent initrd and stage-2 watchdog
keepers check reachability of `10.55.0.2`; losing the host releases the hardware
watchdog for recovery. Arm a ROM catcher on the host before experiments which
may stall MMIO, and stop any fastboot keepalive before staging an image.

Identify nodes by driver, rather than relying on probe order:

```sh
v4l2-ctl --list-devices
v4l2-ctl -d /dev/videoX --list-formats-ext
```

First request a bounded ISP-only capture, then run the integrated encoder:

```sh
timeout 30 v4l2-ctl -d /dev/videoX \
  --set-fmt-video=width=2560,height=1440,pixelformat=NV21 \
  --stream-mmap=2 --stream-count=30 --stream-to=/dev/null

sg2002-h264-bridge /dev/videoX /dev/videoY \
  --scaler-node /dev/videoZ --isp --capture-buffers 2 --mid-buffers 2 \
  --frames 300 --output /tmp/isp-300.h264
```

The encoder retains one synthetic priming/reference picture at the beginning
of the stream. `--frames 300` excludes it from the live-frame limit: the file
contains 301 decoded pictures, of which 300 must come from the sensor. Exclude
the first picture from camera image comparisons.

The acceptance evidence must include actual completed capture frames, a
decodable H.264 stream with 300 live pictures and VCL/IDR content, geometry and colour
checks, CPU/RSS measurements, clean streamoff and a subsequent successful
stream restart. A successful cross-build alone does not establish these.

Register references are the pinned CV181x SDK's `vi_reg_fields.h`,
`vi_reg_blocks.h`, `isp_reg.h`, and the `vi/chip/mars/vip/vi_*_ip_ctrl.c`
implementations. The mainline patch uses explicit offsets/masks and the
kernel's own DMA/V4L2 APIs, without the factory module ABI.

## Board evidence: 2026-10-03

The LicheeRV camera on strix-3 was tested with a RAM-only Linux 7.2.8 image and
the sensor clock assignment moved onto the GC4653 node. This prevents the
CPUFreq overlay from replacing the camera's assignment: CAM_MCLK1 now reports
23.76 MHz (the rounded 24 MHz request), with MPLL still at 1 GHz. Five
full-resolution RAW frames and repeated 30-frame NV21 captures completed.

The original root-level media nodes incorrectly inherited the architecture's
coherent DMA default. Coda's kernel mapping was uncached, but its userspace
capture mapping was cached. Encoded output contained stale 64-byte cache lines
from earlier uses of the buffer. Saved, immutable inputs reproduced this with
both mmap and DMA-BUF NV12 input, without CSI or VPSS running. Changing only
the output mapping to uncached made a live 300-frame stream pass strict
software decoding; the cached A/B run failed. The NV21 staging copy had masked
this bug.

Moving Coda, VPSS and CSI under `/soc` restores the inherited
`dma-noncoherent` setting. A fresh RAM boot with this DT and stock drivers
passed two 300-live-frame direct NV12 runs at about 29.6 fps. Both complete
streams passed `ffmpeg -v error -xerror`; `ffprobe` counted 301 pictures at
640×360, including the priming picture. Offline alternating black/scene replay
also passed 60 frames each with mmap and DMA-BUF input. A separate
30-live-frame restart passed strict decoding, followed by a successful
30-frame ISP-only capture. No staging copy, diagnostic sleep or modified
kernel module was used for these final tests. DT regression checks require the
media nodes to inherit the SoC's noncoherent setting.

The 1280×720 request still failed at capture STREAMON with `ENOMEM` in the
32 MiB media pool; the default 640×360 path restarted successfully afterwards.
Stream restarts can still log CSI ECC/CRC/word-count indications, and ISP
streamoff still reports its partial-frame reset. ISP image tuning and H.264
VUI remain incomplete. No storage was flashed.

The NanoKVM-PCIe attached to router had the same root-level CSI and VPSS
nodes; its Coda node already inherited the correct setting. With its stock
Linux 7.2.7 system and a 1080p60 HDMI source, a userspace probe filled the
first 4 KiB of each mmap capture buffer before queuing it. Across 60 completed
frames, 2,993 whole 64-byte lines still contained that pattern. A temporary
module changed only the idle CSI and VPSS devices' DMA coherency flags to the
noncoherent values supplied by the corrected DT. The same test then found
zero stale lines. Restoring the original flags reproduced 1,986 stale lines.
The probe was unloaded afterwards.

With the corrected flags, two HDMI-to-NV12 runs produced 301 strictly
decodable pictures each at 960×540 and approximately 58–60 fps. The original
hardware-to-hardware stream also decoded successfully: the demonstrated
PCIe failure concerns CPU access to captured frames, unlike the camera's
cached Coda output. PCIe validation used the runtime probe; an attempted
warm boot into the corrected DT failed and the watchdog recovered the
original SD system. The camera validation above used the final DT at boot.

## Board evidence: 2026-09-13

The LicheeRV camera attached to the test host RAM-booted Linux 7.2.0-rc5 from commit
`7edcc3b` with runner
`/nix/store/dcsvm3hz9d05ibm66f14jn0pfk2fhd03-usb-boot`. The final bridge was
cross-built from `c4656b6` and copied into target `/tmp`; its store package was
`5qszy48vy8w6c1f1v0ghqbdy8agj6zz9-sg2002-h264-bridge-riscv64-unknown-linux-gnu-0.2`.
Patch 0068 (format enumeration only) was subsequently cross-built but was not
part of this booted kernel.

- `/dev/video0`: CSI/ISP; `/dev/video1`: VPSS; `/dev/video2`: Coda980.
- Five RAW frames completed before ISP testing. Thirty full-resolution NV21
  frames completed, followed by a separate one-frame capture (5,529,600 bytes).
- The integrated `--isp --frames 300` test completed 300 scaled sensor frames
  and 301 encoded pictures: 300 live frames plus the explicitly identified
  initial black priming picture. The priming picture remains in the bitstream
  because later pictures can reference it; it is excluded from the live limit.
- `ffprobe` counted 301 H.264 pictures at 640x360; complete software decoding
  succeeded. The earlier equivalent run contained 290 non-IDR and 11 IDR VCL
  NAL units. No empty or error-flagged encoder buffers were counted.
- The measured final run took 10.37 seconds: 0.67 seconds user CPU, 4.19 seconds
  system CPU (46% of the single core), and maximum RSS 1,904 KiB. Runtime reports
  were approximately 29.5 frames/second. This is a dark-scene measurement,
  not a representative high-detail bitrate or encoder-load benchmark.
- After the integrated test, another 30-frame NV21 stream completed and
  stopped successfully. There were no failed systemd units.
- Live register reads matched scenario `0x26`, CFA control `0x33`, CSC control
  `0x3`, and all six explicitly programmed CSC coefficient/offset words.
- The independent watchdog reported active, timeout 85 seconds. Withdrawing
  host connectivity recovered the first laboratory image to ROM, then RAM
  U-Boot, without a physical reset or host reboot (about 116 seconds including
  the health-failure window). No nonvolatile image was flashed.

The scene was nearly dark: a separate RAW capture measured min/max 228/304,
mean 255.1873 at the sensor's black pedestal of 256. ISP luma measured min/max
14/19, mean 16.00035; chroma was 128 +/- 1. This is consistent with the fixed
linear, unsubtracted RAW12-to-eight-bit path, not evidence of calibrated colour
or useful low-light image quality. Lit-scene colour, demosaic detail, AE/AWB,
black-level correction and gamma remain unvalidated or unimplemented as noted
above. H.264 VUI colour signalling remains absent; use the documented explicit
decoder interpretation when comparing pixels.

Streamoff reports `ISP stop: resetting partial frame, idle=0x386`: both output
write engines are idle, but stopping the sensor leaves upstream stages partial.
The driver resets these stages before freeing buffers; repeated capture and
encode restarts succeeded. One transient CSI ECC indication occurred at a
stream restart; it did not prevent the bounded run completing. Neither warning
should be silently represented as a completely warning-free production path.

Host regression tests exercise the real VPSS queue/format functions with
ASan/UBSan and the bridge format/frame-accounting helpers. Both pass. Full
cross-builds and `nix flake check --no-build` also pass. Large binary captures and transient logs are not included in this repository.
