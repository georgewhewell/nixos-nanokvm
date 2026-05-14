# Include — vendor-FIT boot via Sipeed's vendor U-Boot. A single FIT
# image carrying kernel + dtb + initrd lands on the FAT firmware
# partition alongside fip.bin; vendor U-Boot's `sdboot` loads it.
# Required when sg2002.kernel = "vendor" for SD boots.
#
# Exposes `system.build.boot-fit` and `system.build.uenv` so the
# sd-image include (or an external image builder) can pick them up.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.sg2002;

  fipPkg =
    if cfg.uboot == "mainline"
    then pkgs.sg2002-fip-mainline-uboot
    else pkgs.sg2002-fip;

  # The plain `sg2002-dtb-vendor` leaves the dwc2 USB controller in
  # the vendor's default mode, which on this board comes up as host —
  # so the dev USB-C port enumerates nothing and we can't ssh in.
  # The `-gadget` variant overrides dr_mode=peripheral + bumped FIFOs.
  # uEnv.txt's bootargs= line takes precedence over chosen.bootargs in
  # the DTB, so the gadget wrapper's missing `root=` doesn't matter
  # here — we still get root=/dev/disk/by-label/NIXOS_SD from sd-image.
  dtbFile =
    if cfg.kernel == "vendor"
    then pkgs.sg2002-dtb-vendor-gadget
    else pkgs.sg2002-dtb-mainline;

  bootFit = pkgs.sg2002-boot-fit {
    kernel = config.system.build.kernel;
    fdt = dtbFile;
    initrd = "${config.system.build.initialRamdisk}/initrd";
    loadAddrs = {
      kernel = "0x80200000";
      initrd = "0x85000000";
    };
    configName = "config-${cfg.board.name}";
    description = "NixOS SG2002 boot image";
  };

  # uEnv.txt is auto-loaded by Sipeed's vendor U-Boot loadenvcmd. Its
  # stock `sdboot` rebuilds bootargs from fragments (including
  # `loglevel=0`, which silences the kernel) and hardcodes a specific
  # FIT config name — so we override both sdboot/sdbootauto AND bootargs.
  uenv = pkgs.writeText "uEnv.txt" ''
    bootargs=${lib.concatStringsSep " " config.boot.kernelParams}
    sdboot=mmc dev 0 && fatload mmc 0:1 ''${uImage_addr} boot.sd && bootm ''${uImage_addr}
    sdbootauto=run sdboot
  '';

  # `switch-to-configuration boot` invokes whatever this script
  # points at and passes the new toplevel as $1. We use it to mount
  # the FAT firmware partition and copy the new boot.sd / uEnv.txt
  # / fip.bin onto it — same role extlinux's populateCmd plays for
  # the mainline kernel path.
  installBootLoader = pkgs.writeShellScript "install-vendor-fit-boot" ''
    set -euo pipefail
    TOPLEVEL="$1"

    # The toplevel symlinks the three artefacts under bootfit/.
    BOOTFIT="$TOPLEVEL/bootfit"
    if [ ! -d "$BOOTFIT" ]; then
      echo "no bootfit/ dir under $TOPLEVEL — vendor-fit.nix didn't run?" >&2
      exit 1
    fi

    # Find and mount the FAT firmware partition. Label is FIRMWARE
    # for sd-image builds; fall back to /dev/mmcblk0p1 if needed.
    DEV=$(${pkgs.util-linux}/bin/blkid -L FIRMWARE 2>/dev/null || true)
    if [ -z "$DEV" ]; then
      DEV=/dev/mmcblk0p1
    fi
    MNT=$(${pkgs.coreutils}/bin/mktemp -d)
    ${pkgs.util-linux}/bin/mount -t vfat "$DEV" "$MNT"
    trap '${pkgs.util-linux}/bin/umount "$MNT" || true; ${pkgs.coreutils}/bin/rmdir "$MNT" || true' EXIT

    install -m 0644 "$BOOTFIT/fip.bin"   "$MNT/fip.bin"
    install -m 0644 "$BOOTFIT/boot.sd"   "$MNT/boot.sd"
    install -m 0644 "$BOOTFIT/uEnv.txt"  "$MNT/uEnv.txt"
    sync "$MNT/fip.bin" "$MNT/boot.sd" "$MNT/uEnv.txt"

    echo "vendor-fit: updated $DEV (fip.bin, boot.sd, uEnv.txt)"
  '';
in {
  config = {
    # FIT carries its own dtb; deviceTree append path not used.
    hardware.deviceTree.enable = lib.mkForce false;
    boot.loader.grub.enable = false;
    boot.loader.generic-extlinux-compatible.enable = false;

    system.build.boot-fit = bootFit;
    system.build.uenv = uenv;
    system.build.fip = fipPkg;

    # Symlink the three files into the toplevel under bootfit/ so the
    # installBootLoader script can find them. systemBuilderCommands
    # runs while the system derivation is being assembled.
    system.systemBuilderCommands = ''
      mkdir -p $out/bootfit
      ln -s ${bootFit} $out/bootfit/boot.sd
      ln -s ${uenv}    $out/bootfit/uEnv.txt
      ln -s ${fipPkg}/fip.bin $out/bootfit/fip.bin
    '';

    system.build.installBootLoader = installBootLoader;
    system.boot.loader.id = "vendor-fit";
  };
}
