# nixos-nanokvm

Reusable NixOS board support for Sipeed NanoKVM / SG2002 hardware
(Sophgo CV1800 family, RISC-V C906).

This repository owns the hardware layer:

- SG2002/NanoKVM board modules and profiles
- mainline and vendor kernel packaging
- mainline U-Boot/FIP/DTB plumbing
- AIC8800 SDIO WiFi driver and firmware packaging
- NanoKVM userspace packaging
- USB boot, kexec, and NBD live-image tooling

It intentionally does not own personal deployment policy. Keep hostnames,
LAN addresses, routes, DNS, WiFi credentials, SSH users/keys, secrets, and
Colmena topology in the downstream flake that consumes this one.

## Current Target

The primary NanoKVM-PCIe path is mainline:

- `boards.pcie.mainline.sd`: SD image using mainline U-Boot/extlinux and
  Linux 7.2-rc1
- Ethernet via `stmmac`
- AIC8800 SDIO WiFi via the Radxa driver plus local SDIO compatibility
  patching
- USB gadget networking for recovery/control
- OLED and NanoKVM userspace support

Vendor-kernel outputs remain available for recovery and regression testing,
but new reusable work should prefer the mainline profile unless there is a
specific vendor-only dependency.

## Build

From this repository on an x86_64 Linux host:

```sh
nix build .#boards.pcie.mainline.sd
nix build .#nanokvm-server
```

Useful development artifacts:

```sh
nix run .#boards.licheerv.mainline.kernel-test.usb-boot
nix run .#boards.licheerv.mainline.live.usb.usb-boot
nix run .#boards.licheerv.mainline.live.usb.kexec
```

The USB live runner configures the host side of the ECM link as
`10.55.0.2/24`, serves the root filesystem over NBD, and passes the selected
endpoint on the kernel command line. The target comes up at `10.55.0.1/24`.

For a WiFi-backed live rootfs, provide both a target-side WiFi configuration
through a consuming NixOS config and the site-specific host address at runtime:

```sh
NANOKVM_NBD_ROOTFS_HOST=192.0.2.10 \
NANOKVM_NBD_ROOTFS_BIND=192.0.2.10 \
  nix run .#boards.licheerv.mainline.live.wifi.usb-boot
```

`NANOKVM_NBD_ROOTFS_HOST` is the address the target can reach over WiFi.
`NANOKVM_NBD_ROOTFS_BIND` is optional; omit it to let `nbd-server` bind all
local interfaces.

## Downstream Use

Import the reusable board module, then add deployment-specific policy in your
own NixOS configuration:

```nix
{
  inputs.nanokvm.url = "github:georgewhewell/nixos-nanokvm";

  outputs = { nixpkgs, nanokvm, ... }: {
    nixosConfigurations.nanokvm = nixpkgs.lib.nixosSystem {
      system = "riscv64-linux";
      modules = [
        nanokvm.nixosModules.boards.pcie.mainline.sd
        ({ ... }: {
          networking.hostName = "nanokvm";
          services.openssh.enable = true;

          # Deployment-specific choices belong here, not in this repo.
          sg2002.wifi.enable = true;
        })
      ];
    };
  };
}
```

For non-SG2002 development hosts, `nanokvm.nixosModules.default` exposes the
portable NanoKVM service and package overlay. Disable cv181x-only hardware
features in the consuming configuration:

```nix
{
  imports = [ nanokvm.nixosModules.default ];

  services.nanokvm = {
    enable = true;
    kmods.enable = false;
    usbGadget.enable = false;
    hdmi.enable = false;
    httpPort = 8080;
    httpsPort = 8443;
    openFirewall = true;
    hardwareVersion = "pcie";
  };
}
```

## Local Files

These files are intentionally ignored and only affect local standalone builds:

- `authorized_keys`: root SSH public keys baked into local images
- `.ssh_host_*_key`: cached per-developer SSH host keys injected by USB boot
- `.nanokvm-*.log` / `.nanokvm-*.pid`: host runner state
- `media/captures/`: local terminal recordings and rendered GIFs

Use a downstream secrets system for WiFi credentials.

## Patch Workflow

For local fixes to upstream NanoKVM userspace:

```sh
git -C ../NanoKVM diff > patches/nanokvm/0001-my-change.patch
nix build .#nanokvm-server
```

Kernel and bootloader patches live under `pkgs/sg2002/linux-mainline/` and
`pkgs/sg2002/uboot-mainline/`. Keep reusable hardware fixes here; keep
machine-specific configuration in the consuming NixOS flake.

## Layout

| Path | Purpose |
| --- | --- |
| `boards/` | Per-board NixOS modules |
| `platform/` | Shared CV1800/SG2002 platform module |
| `profiles/` | SD, live, debug, and kernel-test profiles |
| `modules/` | Reusable NixOS modules for services and boot plumbing |
| `lib/catalog.nix` | Single source of truth for shipped board outputs |
| `lib/artifacts.nix` | Host-side artifact and runner builders |
| `lib/protocol.nix` | USB-ECM MACs, IPs, and ports |
| `pkgs/` | Overlay packages, kernels, firmware, U-Boot, FIP, DTBs |
| `scripts/` | Host-side development utilities |
