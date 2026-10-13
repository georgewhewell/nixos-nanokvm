# SG2002 SD-card boot media, defined with disko.
#
# Retain the vendor-compatible MBR layout, with fip.bin on a small FAT
# firmware partition. LBA 1 is the vendor convention, not a demonstrated
# ROM requirement: an aligned FAT partition at LBA 2048 also boots on
# NanoKVM-PCIe. Keep the layout declarative through disko's table backend.
{
  config,
  lib,
  pkgs,
  ...
}: let
  firmwareLabel = "FIRMWARE";
  rootLabel = "NIXOS_SD";
  imageName = "${config.networking.hostName}-sg2002-sd";
  partitionDevice = device: index:
    if builtins.match "/dev/(disk|zvol)/.+" device != null
    then "${device}-part${toString index}"
    else if builtins.match "/dev/((nvme|mmcblk).+|md/.*[[:digit:]])" device != null
    then "${device}p${toString index}"
    else "${device}${toString index}";
  nativePkgs = import pkgs.path {
    system = pkgs.buildPackages.stdenv.hostPlatform.system;
    config = pkgs.config;
  };
  imageBuilderPkgs = nativePkgs.extend (final: prev: {
    aggregateModules = modules:
      (prev.aggregateModules modules).overrideAttrs (old: {
        passthru =
          (old.passthru or {})
          // {
            target = (builtins.head modules).target;
          };
      });
  });
  diskDevice = config.disko.devices.disk.sg2002-sd.device;
  firmwarePart = partitionDevice diskDevice 1;
  rootPart = partitionDevice diskDevice 2;
  upstreamExtlinuxBuilder = import (pkgs.path + "/nixos/modules/system/boot/loader/generic-extlinux-compatible/extlinux-conf-builder.nix") {
    inherit lib pkgs;
  };
  # The generic builder's plain `cp` may use Btrfs copy_file_range and retain
  # a Nix-store file's shared, fragmented extent map. U-Boot's Btrfs reader is
  # much less exercised than Linux's; make boot payloads independent copies.
  targetExtlinuxBuilder = pkgs.runCommand "sg2002-extlinux-conf-builder" {} ''
    cp ${upstreamExtlinuxBuilder} "$out"
    substituteInPlace "$out" \
      --replace-fail 'cp -r $src $dstTmp' 'cp --reflink=never -r $src $dstTmp'
    chmod +x "$out"
  '';
  targetExtlinuxBuilderArgs =
    "-g ${toString config.boot.loader.generic-extlinux-compatible.configurationLimit} "
    + "-t ${if config.boot.loader.timeout == null then "-1" else toString config.boot.loader.timeout}"
    + lib.optionalString (config.hardware.deviceTree.name != null) " -n ${config.hardware.deviceTree.name}"
    + lib.optionalString (!config.boot.loader.generic-extlinux-compatible.useGenerationDeviceTree) " -r";
  # Sipeed's BootROM-known-good images use FAT16 for this small boot
  # volume. Forcing FAT32 on 16 MiB creates only ~32k clusters, below
  # FAT32's specified 65525 minimum and unsafe for strict readers.
  formatSg2002Filesystems = pkgs.writeShellApplication {
    name = "format-sg2002-sd-filesystems";
    text = ''
      set -euo pipefail

      for part in "${firmwarePart}" "${rootPart}"; do
        for attempt in $(${imageBuilderPkgs.coreutils}/bin/seq 1 120); do
          if [ -b "$part" ]; then
            break
          fi
          if [ "$attempt" -eq 120 ]; then
            echo "partition $part did not appear" >&2
            exit 1
          fi
          ${imageBuilderPkgs.coreutils}/bin/sleep 1
        done
      done

      ${imageBuilderPkgs.dosfstools}/bin/mkfs.vfat -F 16 -n ${firmwareLabel} "${firmwarePart}"
      ${imageBuilderPkgs.btrfs-progs}/bin/mkfs.btrfs -f -L ${rootLabel} "${rootPart}"

      ${imageBuilderPkgs.systemdMinimal}/bin/udevadm trigger --subsystem-match=block || true
      ${imageBuilderPkgs.systemdMinimal}/bin/udevadm settle --timeout=120 || true
    '';
  };
  formatMount = pkgs.writeShellApplication {
    name = "sg2002-disko-format-mount";
    text = ''
      set -euo pipefail
      ${lib.getExe config.system.build.format}
      ${lib.getExe formatSg2002Filesystems}
      ${lib.getExe config.system.build.mount}
    '';
  };
  destroyFormatMount = pkgs.writeShellApplication {
    name = "sg2002-disko-destroy-format-mount";
    text = ''
      set -euo pipefail
      ${lib.getExe config.system.build.destroy} "$@"
      ${lib.getExe config.system.build.format}
      ${lib.getExe formatSg2002Filesystems}
      ${lib.getExe config.system.build.mount}
    '';
  };
  installBootLoader = pkgs.writeShellScript "install-sg2002-extlinux-boot" ''
    set -euo pipefail

    ${pkgs.coreutils}/bin/mkdir -p /boot/nixos /boot/extlinux
    # Keep the rest of the small root compressed, but give U-Boot plain,
    # compact extents. This directory property is inherited by new payloads;
    # --reflink=never above ensures each installed generation is newly laid out.
    # The object type is known: these are directory inodes. Specifying it
    # avoids the FS_INFO autodetection ioctl unsupported by qemu-user during
    # cross-image creation; btrfs still checks the filesystem before setting
    # the compression xattr.
    ${pkgs.btrfs-progs}/bin/btrfs property set -t inode /boot/nixos compression none
    # extlinux.conf is also read by U-Boot, and its temporary replacement
    # must inherit the same policy before the builder creates it.
    ${pkgs.btrfs-progs}/bin/btrfs property set -t inode /boot/extlinux compression none
    ${targetExtlinuxBuilder} ${targetExtlinuxBuilderArgs} -c "$@" -d /boot

    if [ -d /firmware ]; then
      ${pkgs.coreutils}/bin/install -D -m 0644 ${config.system.build.fip}/fip.bin /firmware/fip.bin
      ${pkgs.coreutils}/bin/sync -f /firmware/fip.bin 2>/dev/null || ${pkgs.coreutils}/bin/sync
    else
      echo "warning: /firmware is not mounted; fip.bin was not installed" >&2
    fi
  '';
  rootPartitionNeedsGrowth = pkgs.writeShellScript "sg2002-root-partition-needs-growth" ''
    set -eu

    disk_sectors="$(${pkgs.coreutils}/bin/cat /sys/class/block/mmcblk0/size)"
    part_start="$(${pkgs.coreutils}/bin/cat /sys/class/block/mmcblk0p2/start)"
    part_sectors="$(${pkgs.coreutils}/bin/cat /sys/class/block/mmcblk0p2/size)"

    # ExecCondition succeeds only while more than 1 MiB remains after p2.
    # Once the image has consumed the card, skip cloud-utils growpart before
    # it takes an exclusive whole-device lock and waits for udev on every boot.
    # Skip with 2, not 1: nixpkgs lists 1 in the unit's SuccessExitStatus,
    # and systemd applies that list to ExecCondition as well.
    if [ "$((part_start + part_sectors + 2048))" -lt "$disk_sectors" ]; then
      exit 0
    fi
    exit 2
  '';
  sdImage = pkgs.runCommand "${imageName}-${config.system.nixos.label}" {} ''
    mkdir -p "$out/sd-image" "$out/nix-support"
    ln -s ${config.system.build.diskoImages}/${imageName}.raw \
      "$out/sd-image/${imageName}-${config.system.nixos.label}-${pkgs.stdenv.hostPlatform.system}.img"
    echo "file sd-image $out/sd-image/${imageName}-${config.system.nixos.label}-${pkgs.stdenv.hostPlatform.system}.img" \
      > "$out/nix-support/hydra-build-products"
    echo "${pkgs.stdenv.hostPlatform.system}" > "$out/nix-support/system"
  '';
in {
  config = {
    # The SG2002 does not need nixpkgs' generic SD-card initrd module set.
    sg2002.initrd.pruneKernelModules = true;
    # The board-support module force-prunes the generic initrd module set, so
    # supportedFilesystems alone cannot retain modular filesystem drivers.
    # Retain mmc_block for modular kernels on every carrier as well (the
    # current mainline kernel builds it in), not only in the PCIe board module.
    sg2002.initrd.availableKernelModules = [ "btrfs" "mmc_block" ];
    sg2002.initrd.kernelModules = [ "mmc_block" ];

    # These deployed SD images are not self-reconfiguring systems. Besides
    # shrinking the target, disabling the installer tools avoids pulling
    # cross-built helper payloads (notably bcachefs-tools) into the closure.
    system.disableInstallerTools = true;

    boot = {
      growPartition = lib.mkDefault true;
      supportedFilesystems = lib.mkDefault [
        "btrfs"
        "vfat"
      ];
      initrd.supportedFilesystems = lib.mkDefault [
        "btrfs"
      ];
      kernelParams = [
        "root=/dev/disk/by-label/${rootLabel}"
        "rootwait"
        "rw"
        "rootfstype=btrfs"
        # NBD is built in for the USB live boots; an SD boot has no use for
        # its sixteen preallocated devices.
        "nbd.nbds_max=0"
        (if config.sg2002.consoleDevice == "tty0" then
          "console=tty0"
        else
          "console=${config.sg2002.consoleDevice},115200")
        "earlycon=sbi"
        # No ignore_loglevel: it overrides loglevel and floods the LCD
        # console with driver debug output (AIC8800 "get tx power").
      ];
    };

    systemd.services.growpart.serviceConfig.ExecCondition = [
      rootPartitionNeedsGrowth
    ];

    disko = {
      # The legacy `table` backend preserves the vendor-compatible MBR
      # layout. Its generated NixOS fileSystems config is not reliable for
      # this table type, so fileSystems are declared explicitly below.
      enableConfig = false;

      imageBuilder = {
        enableBinfmt = true;
        imageFormat = "raw";
        name = imageName;
        copyNixStoreThreads = 4;
        pkgs = imageBuilderPkgs;
        kernelPackages = imageBuilderPkgs.linuxPackages_latest;
      };

      devices.disk.sg2002-sd = {
        type = "disk";
        device = "/dev/mmcblk0";
        imageName = imageName;
        imageSize = lib.mkDefault "4G";
        content = {
          type = "table";
          format = "msdos";
          partitions = [
            {
              name = "firmware";
              part-type = "primary";
              # Keep the vendor image's MBR type 0x0c even though the volume
              # itself is FAT16; the BootROM-known-good image uses this exact
              # combination.
              fs-type = "fat32";
              start = "1s";
              end = "32768s";
              bootable = true;
            }
            {
              name = "root";
              part-type = "primary";
              fs-type = "btrfs";
              start = "49152s";
              end = "100%";
            }
          ];
        };
      };

      devices.nodev = {
        "/" = {
          fsType = "btrfs";
          device = "/dev/disk/by-label/${rootLabel}";
          mountOptions = [
            "noatime"
            "compress=zstd:3"
          ];
        };
        "/firmware" = {
          fsType = "vfat";
          device = "/dev/disk/by-label/${firmwareLabel}";
          mountOptions = [
            "umask=0022"
          ];
        };
      };
    };

    fileSystems = {
      "/" = {
        device = "/dev/disk/by-label/${rootLabel}";
        fsType = "btrfs";
        options = [
          "noatime"
          "compress=zstd:3"
        ];
        neededForBoot = true;
        autoResize = true;
      };
      "/firmware" = {
        device = "/dev/disk/by-label/${firmwareLabel}";
        fsType = "vfat";
        options = [
          "umask=0022"
          "nofail"
        ];
        neededForBoot = true;
      };
    };

    system.build = {
      formatMount = lib.mkForce formatMount;
      destroyFormatMount = lib.mkForce destroyFormatMount;
      installBootLoader = lib.mkForce installBootLoader;
      sdImage = sdImage;
      sdImageRaw = config.system.build.diskoImages;
      sdImageScript = config.system.build.diskoImagesScript;
    };
    system.boot.loader.id = lib.mkForce "sg2002-extlinux";
  };
}
