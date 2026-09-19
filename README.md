# nixos-nanokvm

Reusable SG2002 / Sipeed NanoKVM hardware support, with persistent NixOS SD
images and a standalone USB-booted initrd. USB initrd images run entirely in
RAM: **no stage 2, SD card, NFS, NBD, or exported Nix store** is required.

## Persistent SD boot

The PicoClaw SD image boots a complete NixOS system with a writable Btrfs root,
SSH, Wi-Fi and the C906L-backed LCD:

```sh
nix build .#boards.picoclaw.mainline.sd.c906l-lcd
```

The raw image is under `result/sd-image/`. The initial login is `root` with
password `nixos-nanokvm`; change this shared development password immediately.
See [the SD guide](docs/sg2002-c906l-picoclaw-sd-image.md) for SSH keys, Wi-Fi
provisioning and writing the card. Mainline wired SD targets also remain
available as `boards.licheerv.mainline.sd` and `boards.pcie.mainline.sd`;
their initial password is `nixos`.

## USB boot

Build on x86_64 Linux with Nix, supplying an authorized **public** SSH key:

```sh
NANOKVM_AUTHORIZED_KEYS="$HOME/.ssh/id_ed25519.pub" \
  nix build --impure .#boards.picoclaw.mainline.initrd.default.bundle
tar -C result -czf nanokvm-usb.tar.gz .
```

Choose `picoclaw`, `licheerv` or `pcie` for the carrier. The bundle includes
FIP, kernel/initrd FIT, uploader and a Dockerfile. The upload machine needs
USB access, Python and fastboot, but **does not need Nix**. Uploading is
RAM-only, never flashing storage. The uploader exits after handoff.

The image includes key-only SSH, DHCP and link-local networking on USB,
Ethernet and Wi-Fi, DNS, ALSA audio tools, and a hardware watchdog. PicoClaw
also includes the C906L Rust firmware, DRM/`/dev/fb0` display path and
C906L-mediated Wi-Fi power control. Carrier wiring determines which devices
are usable; build checks do not substitute for live peripheral tests.

See [the standalone guide](docs/usb-initrd.md) for Wi-Fi credentials, Linux
and Docker upload instructions, ROM reset, USB SSH discovery and diagnostics.
Native Windows/macOS upload is not yet supported; a Linux VM needs explicit
USB passthrough. Docker Desktop does not supply that automatically.

Additional outputs at the same attrpath: `fit`, `kernel`, `initrd`,
`usb-boot`. No unauthenticated network shell or default password is provided.
Wi-Fi credentials, if embedded, are readable in the Nix store and bundle:
never publish those images to a public cache.

## Hardware development

This repo retains the mainline/vendor kernels, U-Boot/FIP/DTB builders,
AIC8800 Wi-Fi support, audio, camera/ISP/codec drivers, C906L toolchain and
firmware, and reusable board modules. The NanoKVM web application is packaged
separately; it is not run by the minimal initrd.

```sh
nix develop .#c906l
nix build .#checks.x86_64-linux.sg2002-c906l-rust-all-timers
nix build .#checks.x86_64-linux.sg2002-initrd-eval
nix build .#nanokvm-server
```

The `licheerv.mainline.initrd.c906l-all-timers` target provides the opt-in
Timer4–7 firmware. Camera/ISP blocks remain Linux-owned, not C906L firmware.
See [C906L architecture and hardware evidence](docs/sg2002-c906l.md) and
[mainline ISP support](docs/sg2002-mainline-isp.md). Commands in historical
network-root bring-up reports describe an older development workflow.

The separate `qemu-c906-virt` app runs a full development VM with the shared
kernel and a 256 MiB C906 model. QEMU has no SG2002 peripheral model: it cannot
validate LCD, SDIO Wi-Fi, USB gadget, audio or camera hardware.

## Downstream integration

Persistent SD images and RAM-only USB initrd images are both public outputs.
The former SG2002 network-root `live`, `debug` and `kernel-test` outputs are
retired; use the standalone initrd targets for USB boot. Host-specific
network-root profiles and NFS/NBD services belong to consuming projects.

Reusable `boards/`, `platform/` and hardware `modules/` remain here.
`nixosModules.boards.<board>.mainline.initrd.default` is the new importable
RAM-only composition. Persistent consumers can use the corresponding `sd`
module or compose the hardware modules with their own profile; do not layer a
root filesystem onto the initrd-only profile. `nixosModules.default` still exposes the
NanoKVM service and package overlay for other consuming configurations.
SpacemiT K3 outputs are unchanged by this SG2002 separation.

## Layout and checks

| Path | Purpose |
| --- | --- |
| `boards/`, `platform/` | Carrier and SoC hardware definitions |
| `profiles/usb-initrd.nix` | RAM-only SSH/network/peripheral environment |
| `profiles/sd-image-*.nix` | Persistent NixOS SD compositions |
| `lib/catalog.nix` | Public SG2002 USB and SD targets |
| `lib/initrd-artifacts.nix` | Bounded FIT, upload runner and portable bundle |
| `pkgs/` | Kernels, drivers, firmware, toolchains and application packages |
| `tests/` | Module, firmware, DT and uploader regression checks |

`hydraJobs.x86_64-linux` builds all catalog images, the uploader regression
tests, the 256 MiB boot test, and hardware checks. CI images are deliberately
free of personal SSH keys and Wi-Fi credentials. USB CI bundles are locked;
SD CI images use the documented initial development password. Build a keyed
USB bundle as above; its kernel, firmware and tools can reuse CI's cache.

For application patches, update `patches/nanokvm/`; kernel and bootloader
patches live under `pkgs/sg2002/`. Keep reusable hardware fixes here and
machine-specific policy in the consuming flake.

The mainline kernel follows nixpkgs' 7.2 series rather than a tarball
pinned in this repo, so stable 7.2.x updates arrive with a flake lock bump
instead of a hand-edited hash. `pkgs/sg2002/linux-mainline/source.nix` is
the single place the kernel package, the DTB build and the clock KUnit
suite agree on that version.

Every applied kernel patch carries `origin`, `upstreamStatus`, `dropWhen`
and `notes` in `patches.nix`, and the file refuses to evaluate if a patch
has no metadata or metadata outlives its patch. `dropWhen` is the condition
under which a patch can be deleted; check it when moving to a new kernel.
