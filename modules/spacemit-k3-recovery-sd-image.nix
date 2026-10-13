{
  config,
  lib,
  modulesPath,
  pkgs,
  ...
}:

let
  debugAuthorizedKeys = pkgs.writeText "k3-recovery-debug-authorized-keys" (
    lib.concatStringsSep "\n" config.users.users.root.openssh.authorizedKeys.keys + "\n"
  );
  debugSshdConfig = pkgs.writeText "k3-recovery-debug-sshd-config" ''
    Port 2022
    ListenAddress 0.0.0.0
    HostKey /run/k3-recovery-debug-sshd/ssh_host_ed25519_key
    AuthorizedKeysFile ${debugAuthorizedKeys}
    PermitRootLogin prohibit-password
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    UsePAM no
    StrictModes no
    PidFile /run/k3-recovery-debug-sshd/sshd.pid
    Subsystem sftp ${pkgs.openssh}/libexec/sftp-server
  '';
in
{
  imports = [
    "${modulesPath}/profiles/base.nix"
    "${modulesPath}/installer/sd-card/sd-image.nix"
    ../boards/spacemit-k3-pico-itx.nix
    ./spacemit-k3-usb-gadget.nix
  ];

  spacemit.k3.usbGadget.enable = true;

  networking = {
    hostName = lib.mkDefault "k3-recovery";
    firewall.enable = lib.mkDefault false;
    networkmanager.enable = lib.mkDefault false;
  };

  services.openssh = {
    enable = lib.mkDefault true;
    settings.PermitRootLogin = lib.mkDefault "prohibit-password";
  };

  environment.systemPackages = [
    pkgs."spacemit-k3-flash-uefi"
    pkgs."spacemit-k3-fsbl"
    pkgs."spacemit-k3-uefi-blobs"
  ];

  systemd.network.wait-online.enable = lib.mkDefault false;
  systemd.services.k3-recovery-debug-sshd = {
    description = "Early diagnostic SSH for SpacemiT K3 recovery";
    wantedBy = [
      "systemd-networkd.service"
      "network.target"
    ];
    after = [ "systemd-networkd.service" ];
    before = [ "shutdown.target" ];
    conflicts = [ "shutdown.target" ];
    unitConfig.DefaultDependencies = false;
    path = [
      pkgs.coreutils
      pkgs.openssh
    ];
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      RestartSec = "2s";
      ExecStart = pkgs.writeShellScript "k3-recovery-debug-sshd-start" ''
        set -euo pipefail

        install -d -m 0700 /run/k3-recovery-debug-sshd
        install -d -m 0755 /run/sshd
        install -d -m 0755 /var/empty
        if [ ! -s /run/k3-recovery-debug-sshd/ssh_host_ed25519_key ]; then
          ssh-keygen -q -t ed25519 -N "" -f /run/k3-recovery-debug-sshd/ssh_host_ed25519_key
        fi

        exec ${pkgs.openssh}/bin/sshd -D -e -f ${debugSshdConfig}
      '';
    };
  };

  fileSystems."/" = lib.mkForce {
    device = "/dev/disk/by-partlabel/nixos-rootfs";
    fsType = "btrfs";
    options = [
      "compress=zstd"
      "noatime"
    ];
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/ESP";
    fsType = "vfat";
    options = [
      "fmask=0077"
      "dmask=0077"
      "nofail"
    ];
  };

  boot = {
    kernelParams = [
      "root=PARTLABEL=nixos-rootfs"
    ];
    loader = {
      grub.enable = lib.mkDefault false;
      systemd-boot.enable = lib.mkDefault false;
      timeout = lib.mkDefault 3;
      efi.canTouchEfiVariables = lib.mkDefault false;
      efi.efiSysMountPoint = lib.mkDefault "/boot";
      generic-extlinux-compatible.enable = lib.mkDefault false;
    };
  };

  system = {
    stateVersion = lib.mkDefault "25.05";
    build = {
      spacemitK3UefiFlash = pkgs."spacemit-k3-uefi-blobs";
      spacemitK3Fsbl = pkgs."spacemit-k3-fsbl";
    };
  };

  image.fileName =
    "${config.image.baseName}-${config.system.nixos.label}-${pkgs.stdenv.hostPlatform.system}-k3-pico-itx.img";

  sdImage = {
    expandOnBoot = false;
    firmwarePartitionOffset = 12;
    firmwarePartitionName = "ESP";
    firmwareSize = 256;
    rootFilesystemCreator = pkgs.path + "/nixos/lib/make-btrfs-fs.nix";
    rootVolumeLabel = "rootfs";

    populateFirmwareCommands =
      let
        kernel = "${config.system.build.kernel}/${config.system.boot.loader.kernelFile}";
        initrd = "${config.system.build.initialRamdisk}/${config.system.boot.loader.initrdFile}";
        dtb = "${config.hardware.deviceTree.package}/${config.hardware.deviceTree.name}";
        kernelParams = lib.concatStringsSep " " config.boot.kernelParams;
        grubConfig = pkgs.writeText "spacemit-k3-recovery-grub.cfg" ''
          set timeout=0
          set default=0

          search --no-floppy --label ESP --set=root

          menuentry "NixOS" {
            devicetree /EFI/nixos/k3-pico-itx.dtb
            linux /EFI/nixos/kernel.efi init=${config.system.build.toplevel}/init ${kernelParams}
            initrd /EFI/nixos/initrd
          }
        '';
        grubEfi = pkgs.runCommand "spacemit-k3-recovery-bootriscv64.efi" { } ''
          ${pkgs.buildPackages.grub2}/bin/grub-mkstandalone \
            -O riscv64-efi \
            -d ${pkgs.grub2_efi}/lib/grub/riscv64-efi \
            --modules="part_gpt fat search search_label linux fdt normal configfile echo serial terminal efi_gop" \
            --locales="" \
            --fonts="" \
            -o $out \
            "boot/grub/grub.cfg=${grubConfig}"
        '';
      in
      ''
        mkdir -p firmware/EFI/BOOT firmware/EFI/nixos

        cp ${grubEfi} firmware/EFI/BOOT/BOOTRISCV64.EFI
        cp ${kernel} firmware/EFI/nixos/kernel.efi
        cp ${initrd} firmware/EFI/nixos/initrd
        cp ${dtb} firmware/EFI/nixos/k3-pico-itx.dtb
        cp ${grubConfig} firmware/EFI/nixos/grub.cfg

        cat > firmware/startup.nsh <<EOF
        @echo -off
        echo Booting NixOS...
        for %i in 0 1 2 3 4 5
          if exist FS%i:\EFI\BOOT\BOOTRISCV64.EFI then
            FS%i:\EFI\BOOT\BOOTRISCV64.EFI
          endif
        endfor
        EOF
      '';

    populateRootCommands = "";

    postBuildCommands = ''
      eval $(${pkgs.buildPackages.util-linux}/bin/partx $img -o START,SECTORS --nr 2 --pairs)
      rootfs_start=$START
      rootfs_sectors=$SECTORS

      truncate -s '+2M' $img

      ${pkgs.buildPackages.util-linux}/bin/sfdisk $img <<EOF
          label: gpt
          unit: sectors
          sector-size: 512
          first-lba: 256

          start=1280,          size=128,             name="env",           type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
          start=2048,          size=256,             name="bootinfo",      type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
          start=3072,          size=1024,            name="fsbl",          type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
          start=8192,          size=6144,            name="esos",          type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
          start=14336,         size=2048,            name="opensbi",       type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
          start=16384,         size=8192,            name="uboot",         type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
          start=24576,         size=524288,          name="ESP",           type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
          start=$rootfs_start, size=$rootfs_sectors, name="nixos-rootfs",  type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
      EOF

      dd if=${pkgs."spacemit-k3-fsbl"}/bootinfo_block.bin of=$img conv=notrunc bs=1M seek=1
      dd if=${pkgs."spacemit-k3-fsbl"}/FSBL.bin           of=$img conv=notrunc bs=1024 seek=1536
      dd if=${pkgs."spacemit-k3-uefi-blobs"}/share/spacemit-k3-uefi-flash/fw_dynamic.itb of=$img conv=notrunc bs=1M seek=7
      dd if=${pkgs."spacemit-k3-uefi-blobs"}/share/spacemit-k3-uefi-flash/edk2.itb       of=$img conv=notrunc bs=1M seek=8
    '';
  };
}
