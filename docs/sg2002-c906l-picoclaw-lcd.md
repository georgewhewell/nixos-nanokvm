# PicoClaw LCD through C906L and DRM

This is a dedicated, reversible PicoClaw experiment. It is not a camera-board
profile and must not be deployed on a NanoKVM carrier with Ethernet in use.

## Architecture

Linux applications use standard DRM/KMS dumb buffers and page flips. The only
pixel format is `DRM_FORMAT_RGB565`, which is also the slot format, so Linux
copies the damaged rectangle of a GEM shared-memory object unchanged into one
of two reserved DDR slots, packed from the start of the slot. C906L's Rust
service reads that immutable slot and drives the ST7789 through SPI1. Pixel
data does not travel in RPMsg messages.

```text
Linux application -> DRM/KMS GEM buffer -> reserved RGB565 slot
                                              |
                                   C906L Rust -> SPI1 -> LCD
                                              |
                                completion -> DRM flip event
```

The current design intentionally copies into reserved DDR. It does not expose
those physical slots through a custom mmap or device-file ABI. This prevents
applications from overwriting a buffer while firmware is scanning it out.
DRM's fbdev compatibility layer is used rather than an independent fbdev
driver. The existing mailbox and byte-exact RPMsg echo remain available.

This is a display controller, not a GPU: rendering is software on Linux, while
C906L performs panel initialization and SPI transfers. Scanout completion means
the SPI transfer has finished; without the panel's tearing-effect signal this
does not establish tear-free presentation or a physical vertical-blank event.
The nominal DRM mode must not be interpreted as a guaranteed refresh rate.

Frame data leaves the C906L as one transmit-only 16-bit SPI stream per frame
at 187.5 MHz / 16 = 11.71875 MHz. The
[ST7789V v1.3 datasheet, section 7.4.3](https://newhavendisplay.com/content/datasheets/ST7789V.pdf)
requires a write clock period of at least 66 ns, with high and low phases of
at least 15 ns. This divider gives an 85.33 ns period and 42.67 ns phases.
The previous divider of 4 violated these limits and produced intermittent
green and pink regions on the physical panel despite successful completions
and correct pixels in shared DDR. Sipeed's 45 MHz application setting was not
evidence that our transfer path was reliable at that speed.

Full-frame wire time is now 78.64 ms. The driver's initial completion wait
covers this transfer before falling back to short polls; its previous 32 ms
prediction cap would wake needlessly during a full frame at the corrected
clock. On the USB-booted PicoClaw, 1,000
acknowledged full-frame commits averaged 87.199 ms; 2,000 partial updates with
varying sizes and origins averaged 22.443 ms. These measurements include
Linux copy and handoff overhead and are not display refresh rates. Damage
tracking is retained, and byte-sized control transactions keep the
preloaded-FIFO path.

The standalone USB initrd uses this same DRM fbdev layer for a best-effort
kernel console. `console=tty0` records boot text in the foreground virtual
terminal, and `fbcon=nodefer` requests takeover as soon as the framebuffer is
ready. The existing built-in `MINI4x6` font gives 60x40 characters. UART stays
the last console, so `/dev/console` remains serial. The optional framebuffer
module uses normal DT/udev discovery rather than blocking the initrd's
synchronous module-loading service. No earlier lease activation, new peripheral
access or framebuffer ownership path is introduced. Logs become visible only
after the validated transport and panel are ready; older text may already have
scrolled out of the virtual terminal. Stage 1 keeps the LCD as a read-only log
console and retains key-only SSH, without adding an unauthenticated getty.

## Shared-memory ownership

The generated `picoclaw-lcd` contract retains ABI 1.1 and assigns lease bit 4,
profile ID 17, and final capabilities `0x8b`. Its immutable digest covers the
physical resources, panel geometry, pin preconditions and framebuffer protocol.
It also covers the firmware-mediated Wi-Fi power protocol. The combined
configuration has digest
`53470c33b715731019865a658dd8a7affdb69a80b414a5195428f2fb16dab355`.
The clock correction changes the digest from the previous
`3e5de4f393d18b9ec03f0ffb173bb863547c1d0d93cdcf0905f8a60a9b1fe9b2`;
firmware, DT and Linux modules must therefore be rebuilt together. The
framebuffer wire protocol remains version 3.

Framebuffer protocol version 3 changed the slot pixel format from big-endian
RGB565 to `DRM_FORMAT_RGB565` (little-endian): Linux now copies pixels without
converting them, and C906L reads each pixel as one little-endian 16-bit word
that its 16-bit SPI frames already send high byte first.

| Resource | Address | Size |
| --- | --- | --- |
| Slot 0 ownership pair | `0x8ff50000` | 128 bytes |
| Slot 1 ownership pair | `0x8ff50080` | 128 bytes |
| Wi-Fi power request/completion pair | `0x8ff50100` | 128 bytes |
| Slot 0 pixels | `0x8ff51000` | 115,200 bytes |
| Slot 1 pixels | `0x8ff6e000` | 115,200 bytes |

Each pair has a Linux-written request cacheline and a C906L-written completion
cacheline. Requests contain the boot generation, a nonzero per-slot sequence,
the damaged rectangle, exactly that rectangle's byte count, reserved zero bytes
and a commit word written last. Completions match that generation and sequence,
include an error result, and carry a zero rectangle.

Framebuffer protocol version 2 replaced the whole-frame request with that
rectangle. Linux converts only the region DRM reports as damaged, packed from
the start of the slot with the rectangle's own pitch, and the firmware
addresses the panel with the same rectangle. A full-screen update is simply
the rectangle 0,0,240,240; there is no separate whole-frame form, and a
request whose byte count is not exactly `width * height * 2`, or whose
rectangle leaves the panel, is rejected. Because the panel retains its own
GRAM, an unchanged region is not retransmitted: a console line costs a few
percent of a full frame on both the SPI link and the auxiliary core.

Linux publishes pixels before the request commit using its write-combined
mapping and write barriers. C906L accepts two identical, explicitly invalidated
request snapshots, invalidates exactly the rectangle's pixel range, and reads
it only while it owns the slot. It cleans its completion cacheline and publishes
the completion commit last. Linux cannot reuse the slot until matching success.
Errors retain ownership and fail closed rather than replaying partial transfers.

## Peripheral ownership and recovery

Linux retains clock/reset/pin-routing management, applies the PicoClaw-specific
EPHY-to-SPI pad handoff only after the firmware manifest matches, and authorizes
the static lease. Firmware checks the generated read-only pad prerequisites.
SPI1 and the whole GPIOA register bank then belong exclusively to C906L.

The dedicated DT disables Linux SPI1/spidev, GPIOA, I2C0 and Ethernet. Both
the SD-card controller and SDIO/Wi-Fi remain enabled. LCD D/C shares I2C0's
clock pad; Wi-Fi power uses GPIOA26. C906L owns A26 alongside the LCD's A27
and A28 in one Rust `OutputGroup`, serviced by one task. Linux never
maps the GPIOA bank or takes a separate GPIO handle. The normal U-Boot splash
and Linux LCD service are not used.

## Wi-Fi and LCD together

Linux SDIO uses a standard `vmmc-supply` regulator named
`picoclaw-wifi-power`. Its provider is `sg2002-c906l-wifi-power`, which maps
only the contract's shared DDR. MMC defers probe until the provider has
validated the immutable firmware identity, observed the active generation,
and received an acknowledged power-off command. SDIO's pinctrl state owns
only its bus pads; GPIOA26's pinmux belongs to the validated C906L handoff.

Each 64-byte request contains a fixed magic, generation, strictly increasing
sequence, enable value (0 or 1), 44 reserved zero bytes and a commit sequence
written last. Firmware requires two identical invalidated snapshots. The
same task that advances LCD scanout updates A26, verifies the output latch,
and publishes a separate completion cacheline with the matching generation,
sequence and enable value. This acknowledges the GPIO latch, not RF link
readiness. Duplicate, stale, malformed and uncommitted commands do not change
GPIOs. Wi-Fi commands run before each bounded LCD service step and do not
depend on RPMsg attachment or a userspace process.

An MMC power-on performs acknowledged off, at least 60 ms off time,
acknowledged on, then at least 10 ms settling. Linux performs the delays so
C906L can continue LCD and IPC work. Each acknowledgement has a 2-second
deadline. A timeout, wrong generation or invalid completion latches an error
and retains the request; later calls cannot overwrite uncertain ownership.
Runtime provider unbind/unload and same-generation rebind are disabled.
Recovery is a whole-board reset. Kernel patch 0069 uses the existing SDHCI
combined regulator/bus-voltage helper so the controller's voltage bits are
still programmed when an external `vmmc` provider is present.

The common board module enables the Wi-Fi driver and firmware. Association
and credentials remain the image's policy (`wifi-aic8800.nix`,
`networking.wireless` or the existing `sg2002.wifi` configuration options).
This standard supply relationship follows the Linux
[regulator framework](https://docs.kernel.org/power/regulator/overview.html).

The Rust panel driver sends panel commands as complete eight-byte SPI
transactions, at most 32 per service step, and each frame as one transmit-only
stream, with scheduler-backed initialization deadlines. Mailbox and heartbeat
processing stay independent. A terminal panel fault retains the lease until
whole-board reset. Runtime unbind, module unload, suspend and C906L reset are
not validated recovery paths.

The backlight is not part of the lease. Pad JTAG_CPU_TMS is muxed to PWM_7
(`&pwm1` channel 3) and driven by `pwm-backlight`, so brightness is an
ordinary `/sys/class/backlight` device and DPMS blanking works normally. Its
`backlight` phandle on the framebuffer node makes `pwm-backlight` boot dark
and wait for a driver to enable it: the DRM driver lights the panel only
after a frame has actually reached it, and blanks it when it latches a
scanout fault, so a torn frame is never left lit.

The standalone initrd feeds the Linux watchdog independently of the USB host,
and its ROM runner arms the reset-only U-Boot watchdog. Use RAM boot only; no
flash operation is needed.

## Build and test

```console
NANOKVM_AUTHORIZED_KEYS="$HOME/.ssh/id_ed25519.pub" \
  nix build --impure --builders '' --no-link --print-out-paths \
  .#boards.picoclaw.mainline.initrd.default.usb-boot
```

On the board, verify `sg2002-c906l-ctl check` before display testing. The
`sg2002-c906l-drm-test /dev/dri/card0 4` tool verifies the DRM driver identity,
allocates two standard RGB565 dumb buffers, draws changing checkerboards,
waits for page-flip events, prints how long each commit took, holds the final
pattern briefly, and restores the previous display mode. It refuses unrelated graphics devices.

For the physical colour-integrity regression, stop the display application
and run both commands below, then restore the application:

```console
sg2002-c906l-drm-test /dev/dri/card0 1000 --integrity
sg2002-c906l-drm-test /dev/dri/card0 1000 240x240 --integrity
```

The expected image is a stationary dark-blue checkerboard with a white
border. With `--integrity`, the rectangle argument supplies maximum dimensions;
successive partial updates exercise changing origins, odd widths and packed
rows. Green or pink patches are failures even when every commit succeeds.
Inspect the physical panel with a camera: a framebuffer PNG cannot detect
corruption after the shared-memory handoff.

## Colour-integrity validation: 2026-10-15

At divider 4, a run of 1,000 partial commits reproduced large green and pink
patches in the dark-blue checkerboard. At divider 16, the same test and a
further 1,000 full-frame plus 2,000 partial commits completed without those
artifacts. There were no green or pink outliers in the fixed central screen
region of 290 webcam samples across the longer run; the failing reference
contained thousands. This is sampled physical evidence, not a claim that each
transmitted pixel was measured. Display and Wi-Fi transport faults stayed zero.

To test without rebooting this RAM-only board, a one-shot lab helper held DRM
master, selected `KD_GRAPHICS`, and required unchanged acknowledged slot
counters plus a disabled, deselected, empty SPI controller for 100 ms. It then
changed only BAUDR from 4 to 16 and verified the readback before resuming
display work. This was a controlled exception to normal exclusive peripheral
ownership, not a production runtime control interface. The helper is not part
of the shipped firmware or application. The boot ID and watchdog process did
not change; the live firmware still reports its original contract digest.

The persistent correction is in the generated contract and rebuilt firmware.
The new matched boot bundle has not been cold-boot tested in this session;
deploy the complete bundle on the next normal boot rather than mixing old
Linux modules with new firmware.

Host tests cover the exact contract, invalid ownership records, frame bounds,
cacheline layout, panel command sequencing, bounded SPI work, terminal errors,
and production Linux transport functions. Wi-Fi power tests execute the
production C transport against a simulated firmware peer, covering power
timings, torn/stale acknowledgements, rejected completions, sequence wrap and
timeout ownership retention. Rust tests cover command validation, duplicate
and stale suppression, latch failures and GPIO mask isolation. Passing these
tests alone does not establish visible LCD output or Wi-Fi association.

For a combined hardware test, inspect
`/sys/bus/platform/devices/c906l-wifi-power/transport_status`, verify `wlan0`
has associated, and run `sg2002-c906l-drm-test /dev/dri/card0 32` while carrying
traffic over Wi-Fi. Check both the regulator and framebuffer
`transport_status` files and `sg2002-c906l-ctl check` before and after.

## Hardware validation: 2026-09-16

These measurements cover the earlier LCD-only contract, before the Wi-Fi
power provider was added. They are not evidence of simultaneous Wi-Fi/LCD
operation with the new contract.

The PicoClaw RAM-booted the dedicated
Linux 7.2-rc5 image. No flash operation or workstation reboot was performed.
The tested runner was
`/nix/store/8zk8qq4vydy5k8ilmd82a6pm78c0ph73-usb-boot`, built from the implementation
through commit `9e60f77`. The exact LCD contract digest was
`0c2d81d5523800863533be8dc1424b8b8ff5a5665a258674a06bd70a1bdebbb0`.

Observed results:

- Activation completed in one attempt, generation 2, capabilities `0x8b`,
  firmware flags zero. The mailbox identity/ping check passed before and after
  the first display test.
- `/dev/dri/card0` and `/dev/fb0` registered as `sg2002-c906l` /
  `sg2002-c906ldrm`. The normal fbdev console also submitted acknowledged frames.
- Standard dumb-buffer/modeset/page-flip tests passed for 4 frames and then
  32 frames, both exiting zero and restoring the previous display mode.
- Concurrent 496-byte RPMsg tests passed for 1,000 and 10,000 messages. The
  latter measured median 2,497.240 us, p99 2,680.520 us, maximum 5,168.600 us.
  These are observations under this workload, not real-time latency guarantees.
- A direct `LCQ1` diagnostic query returned 101 completed frames, per-slot
  completed sequences 51 and 50, panel state BUSY, zero fault and zero malformed
  request status. The busy state and one outstanding Linux sequence reflect
  continuing fbdev updates, not a lost acknowledgement.
- U-Boot's reset-only watchdog was armed and read back; Linux reported an
  active 85-second watchdog in both initrd and stage 2.
- Recovery was fault-injected by administratively disabling only the host's
  USB network interface at 19:29:10 UTC. Without a software reboot command,
  the board disconnected at 19:31:06 and re-enumerated as `3346:1000` ROM at
  19:31:08. The 116-second reset interval is consistent with six failed
  five-second health probes followed by the hardware watchdog countdown.
  The workstation's normal loader caught the reset.

The first restoration attempt stalled waiting for Wi-Fi and reset again. The
normal loader retried, and the original `claw` image recovered Wi-Fi and SSH at
19:38:34 UTC; its host boot service then exited successfully. The temporary boot
inhibition was removed, and all test-owned NBD/boot processes and the port 12502
listener were absent at final cleanup. The workstation was not rebooted. SSH
authentication was unavailable to this session, so the original image's stage-2
LCD service was not independently rechecked after restoration.

These measurements establish acknowledged SPI transfers, shared-memory reuse,
and simultaneous IPC on the real board. They do not independently establish
correct visible colours/orientation or tear-free presentation. The user was
not near the board, so visual confirmation remains pending.

Two cold-boot findings were fixed before the successful test: the over-strict
EPHY comparison described below, and the NBD initramfs accidentally depending
on optional kexec packaging for its real client. The no-kexec image now includes
that executable and its runtime libraries explicitly and calls it by absolute
path, preventing fallback to BusyBox's incompatible applet.


## EPHY handoff register validation

The primary register-field reference is SOPHGO's
[SG2002 PINOUT workbook at commit `12d2bc6976400e6d40389f3faaff40f4326b63c2`](https://github.com/sophgo/sophgo-hardware/blob/12d2bc6976400e6d40389f3faaff40f4326b63c2/SG200X/04_SG2002/04_SG2002_PINOUT.xlsx),
worksheet `6. 如何把 MIPI Audio ETH 切入GPIO`, cell `B27`.
The downloaded workbook's SHA-256 is
`a20e1d2f02b0350a333ff16538cc59c13372b88c8a96f9737a3ef4f5ff57c148`.

That cell identifies bits `[10:9]` and `[2:1]` at both `0x03009074` and
`0x03009070` as the EPHY pad input/output enables and specifies `0x606`.
Their enable-field readback condition is therefore `(value & 0x606) == 0x606`,
not full-register equality to `0x606`. Linux retains the existing full vendor
write of `0x606`; Linux's readback check and the firmware's activation contract
check the documented enable fields. Page selection, top-level GPIO routing,
power/reset prerequisites and pinmux checks remain separate and unchanged.

The first RAM-boot activation attempt observed `0x1606` at `0x03009074` and
`0x1616` at `0x03009070`, which satisfy those enable fields but failed the
original full-register check. This is not a whitelist of observed values:
clearing any of the four documented enable bits must still reject activation.
The inspected primary sources do not classify bits 4 and 12 as read-only,
status, or writable fields. Their differing values do not establish their
meaning, and no fixed expected value is asserted for them.
