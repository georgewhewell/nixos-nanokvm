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
  ...
}: let
  usingVendorFit = config ? system.build.boot-fit;
in {
  imports = [
    "${modulesPath}/installer/sd-card/sd-image.nix"
  ];

  config = {
    # sd-image would pull a grab-bag of initrd modules "just in
    # case"; the SG2002 doesn't need them and with our pruned kernel
    # those modules simply don't exist.
    sg2002.initrd.pruneKernelModules = true;

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
      # The SG2002 ROM follows Sipeed's unusual SD layout: the active FAT
      # firmware partition starts at LBA 1, immediately after the MBR.
      # Mainline only needs fip.bin there, so keep it at the same 16 MiB
      # size as the known-good Sipeed image. Vendor-FIT carries boot.sd too
      # and needs more space.
      firmwareSize = lib.mkDefault (if usingVendorFit then 256 else 16);

      populateFirmwareCommands =
        if usingVendorFit
        then ''
          cp ${config.system.build.fip}/fip.bin firmware/fip.bin
          cp ${config.system.build.boot-fit} firmware/boot.sd
          cp ${config.system.build.uenv}     firmware/uEnv.txt
        ''
        else ''
          cp ${config.system.build.fip}/fip.bin firmware/fip.bin
        '';

      populateRootCommands =
        if config.boot.loader.generic-extlinux-compatible.enable
        then ''
          mkdir -p ./files/boot
          ${config.boot.loader.generic-extlinux-compatible.populateCmd} \
            -c ${config.system.build.toplevel} -d ./files/boot
        ''
        else "";

      # Partition bootable-flag and ROM-layout setup.
      # nixpkgs' generic sd-image builder puts the FAT firmware partition
      # after an 8 MiB gap. SG2002's ROM does not find fip.bin there; Sipeed's
      # known-good images start the active FAT partition at sector 1. Reuse
      # the populated firmware_part.img that nixpkgs just created, copy it to
      # LBA 1, and rewrite only the MBR entries. The root partition stays at
      # the generic builder's aligned offset, and mainline U-Boot still finds
      # it because partition 2 is also marked bootable for distro_bootcmd.
      postBuildCommands =
        if config.boot.loader.generic-extlinux-compatible.enable
        then ''
          firmware_sectors=$(($(stat -c '%s' firmware_part.img) / 512))
          eval "$(partx $img -o START,SECTORS --nr 2 --pairs)"
          root_start=$START
          root_sectors=$SECTORS

          dd conv=notrunc if=firmware_part.img of=$img bs=512 seek=1 count=$firmware_sectors
          sfdisk --no-reread --no-tell-kernel $img <<EOF
              label: dos
              label-id: ${config.sdImage.firmwarePartitionID}

              start=1, size=$firmware_sectors, type=c, bootable
              start=$root_start, size=$root_sectors, type=83, bootable
          EOF
        ''
        else ''
          firmware_sectors=$(($(stat -c '%s' firmware_part.img) / 512))
          eval "$(partx $img -o START,SECTORS --nr 2 --pairs)"
          root_start=$START
          root_sectors=$SECTORS

          dd conv=notrunc if=firmware_part.img of=$img bs=512 seek=1 count=$firmware_sectors
          sfdisk --no-reread --no-tell-kernel $img <<EOF
              label: dos
              label-id: ${config.sdImage.firmwarePartitionID}

              start=1, size=$firmware_sectors, type=c, bootable
              start=$root_start, size=$root_sectors, type=83
          EOF
        '';
    };
  };
}
