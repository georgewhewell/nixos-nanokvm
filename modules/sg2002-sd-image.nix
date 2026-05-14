# Include — populate an SD card image (via nixpkgs's sd-image-aarch64
# recipe, generalised). Works in combination with either the
# extlinux.nix or vendor-fit.nix include:
#   - extlinux: firmware partition holds fip.bin; root partition
#     holds the extlinux.conf tree.
#   - vendor-fit: firmware partition holds fip.bin + boot.sd + uEnv.txt
#     (via vendor-fit.nix's system.build.{boot-fit,uenv,fip}); root
#     partition is empty save for /etc (stage-2 system lives in
#     /nix/store on root).
{
  config,
  lib,
  modulesPath,
  pkgs,
  ...
}: let
  cfg = config.sg2002;
  usingVendorFit = config ? system.build.boot-fit;

  fipPkg =
    if cfg.uboot == "mainline"
    then pkgs.sg2002-fip-mainline-uboot
    else pkgs.sg2002-fip;
in {
  imports = [
    "${modulesPath}/installer/sd-card/sd-image.nix"
  ];

  config = {
    # sd-image would pull a grab-bag of initrd modules "just in
    # case"; the SG2002 doesn't need them and with our pruned kernel
    # those modules simply don't exist.
    boot.initrd.availableKernelModules = lib.mkForce [];
    boot.initrd.kernelModules = lib.mkForce [];

    boot.kernelParams = [
      "root=/dev/disk/by-label/${config.sdImage.rootVolumeLabel}"
      "rootwait"
      "rw"
      "console=ttyS0,115200"
      "earlycon=sbi"
      "ignore_loglevel"
    ];

    sdImage = {
      compressImage = lib.mkDefault false;
      # Vendor-FIT path overflows 30 MiB default; 256 gives headroom
      # for both extlinux and vendor-fit firmware payloads.
      firmwareSize = lib.mkDefault 256;

      populateFirmwareCommands =
        if usingVendorFit
        then ''
          cp ${fipPkg}/fip.bin             firmware/fip.bin
          cp ${config.system.build.boot-fit} firmware/boot.sd
          cp ${config.system.build.uenv}     firmware/uEnv.txt
        ''
        else ''
          cp ${fipPkg}/fip.bin firmware/fip.bin
        '';

      populateRootCommands =
        if config.boot.loader.generic-extlinux-compatible.enable
        then ''
          mkdir -p ./files/boot
          ${config.boot.loader.generic-extlinux-compatible.populateCmd} \
            -c ${config.system.build.toplevel} -d ./files/boot
        ''
        else "";

      # Partition bootable-flag setup.
      # - ROM loads fip.bin from the FAT firmware partition, picked
      #   by MBR bootable flag → partition 1 MUST be active.
      # - Mainline U-Boot's distro_bootcmd iterates partitions listed
      #   by `part list -bootable`; without activating partition 2 it
      #   never scans the ext4 root for extlinux.conf.
      # MBR allows the active bit on multiple entries (first match
      # wins for the ROM, which comes before U-Boot).
      postBuildCommands =
        if config.boot.loader.generic-extlinux-compatible.enable
        then ''
          sfdisk --activate $img 1 2
        ''
        else ''
          sfdisk --activate $img 1
        '';
    };
  };
}
