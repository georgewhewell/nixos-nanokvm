# The sg2002 common module: hardware-level options (kernel choice,
# wifi chip, ssh keys, tuning) and their unconditional config. Boot
# style is NOT an option here — it's expressed by importing a file
# from modules/includes/ (extlinux.nix, vendor-fit.nix, usb-recovery.nix,
# usb-live.nix, sd-image.nix, stage2-wifi.nix).
#
# Expected overlay state: `pkgs.sg2002-kernel-*`, `pkgs.sg2002-dtb-*`,
# `pkgs.sg2002-fip-*`, `pkgs.sg2002-boot-fit`, and
# `pkgs.sg2002-aic8800-*-for` exist. Use `nixosModules.default` to
# get both the module and the overlay.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.sg2002;

  kernelPkg = pkgs."sg2002-kernel-${cfg.kernel}";

  aic8800Pkg =
    if !cfg.wifi.enable
    then null
    else if cfg.kernel == "vendor"
    then pkgs.sg2002-aic8800-vendor-for kernelPkg
    else pkgs.sg2002-aic8800-mainline-for kernelPkg;
in {
  options.sg2002 = with lib; {
    enable = mkEnableOption "SG2002 / LicheeRV Nano board support";

    board = {
      name = mkOption {
        type = types.str;
        default = "sg2002_licheervnano_sd";
        description = "Board identifier used for vendor defconfig / DTS lookup.";
      };
      chip = mkOption {
        type = types.str;
        default = "cv181x";
        description = "Chip family; only `cv181x` is supported today.";
      };
    };

    kernel = mkOption {
      type = types.enum ["mainline" "vendor"];
      default = "mainline";
      description = ''
        Which Linux kernel to build and boot:
          - mainline: nixpkgs `linux_latest` (7.x) + 9 SG2002 patches.
          - vendor:   Sipeed's 5.10 tree. Requires vendor-fit boot;
            incompatible with extlinux / usb-live / zram / erofs.

        (A `sophgo` option for the sophgo/linux for-next branch used
        to be listed here but was never packaged; reintroduce only
        alongside an `sg2002-kernel-sophgo` overlay attribute.)
      '';
    };

    uboot = mkOption {
      type = types.enum ["mainline" "vendor"];
      default = "mainline";
      description = "Which U-Boot/FIP to install on the firmware partition.";
    };

    wifi = {
      enable =
        mkEnableOption "AIC8800DC onboard WiFi (Nano-W variant)"
        // {default = true;};
      wpaConf = mkOption {
        type = types.nullOr types.lines;
        default = null;
        description = "wpa_supplicant.conf body; null disables the supplicant.";
      };
    };

    authorizedKeys = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "SSH public keys baked into root's ~/.ssh/authorized_keys.";
    };

    recoveryHostKey = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Operator-supplied ed25519 SSH host private key for the USB-
        recovery initrd. Required when importing
        `modules/includes/usb-recovery.nix`. Generate once with:

            ssh-keygen -t ed25519 -N "" -f ./recovery_host_ed25519_key

        flake.nix picks the file up from the repo root if present.
        Same gitignore caveat as ./authorized_keys: pure flake builds
        skip untracked files — either `git add -f` it or build with
        `--impure` for the recovery FIT targets.

        Note: the key is baked into the initrd at build time and
        therefore lands in /nix/store on the build host. Secrecy from
        store readers isn't achievable for this artifact (the initrd
        is shipped to the device anyway); the point of using an
        operator-supplied key — instead of build-time `ssh-keygen` —
        is a stable fingerprint across rebuilds and shared caches.
      '';
    };

    tuning.enable =
      mkEnableOption "SD-longevity and low-RAM defaults (noatime, zram in stage-2, journald volatile, no disk swap, docs off)"
      // {default = true;};
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = pkgs ? "sg2002-kernel-${cfg.kernel}";
          message = ''
            sg2002.kernel = "${cfg.kernel}" requires the overlay from this
            flake. Either use nixosModules.default (auto-applies the overlay)
            or add `nixpkgs.overlays = [ inputs.sg2002.overlays.default ];`.
          '';
        }
      ];

      # sd-image pulls a grab-bag of modules; board doesn't need
      # most, and vendor kernel ships no module tree (modules-shrunk
      # would error out).
      hardware.enableAllHardware = lib.mkForce false;

      boot.kernelPackages = pkgs.linuxPackagesFor kernelPkg;

      boot.extraModulePackages = lib.optional (aic8800Pkg != null) aic8800Pkg;
      boot.kernelModules = lib.optionals (aic8800Pkg != null) [
        "aic8800_bsp"
        "aic8800_fdrv"
        "aic8800_btlpm"
      ];
      hardware.firmware = lib.optional cfg.wifi.enable pkgs.sg2002-aic8800-firmware;

      # The aicbsp driver opens /lib/firmware/... directly via
      # filp_open instead of going through request_firmware, so
      # NixOS's normal firmware_class.path indirection (which routes
      # to /run/current-system/firmware) doesn't help. Materialise
      # the literal /lib/firmware path the driver expects.
      systemd.tmpfiles.rules = lib.optional cfg.wifi.enable
        "L+ /lib/firmware - - - - /run/current-system/firmware";

      users.users.root.openssh.authorizedKeys.keys = cfg.authorizedKeys;

      # Board sits on trusted links only (USB-gadget dev tether +
      # user's private WiFi). Mainline kernel also doesn't compile
      # in nf_tables, so iptables-nft would crash.
      networking.useNetworkd = true;
      networking.useDHCP = false;
      networking.firewall.enable = false;
    }

    (lib.mkIf cfg.tuning.enable {
      # noatime kills per-read timestamp writes; commit=600 extends
      # ext4 journal commits from 5 s → 10 min. Trade-off: 10-min-
      # window data loss on hard reset, acceptable on a dev board.
      fileSystems."/".options = ["noatime" "commit=600"];
      boot.tmp.useTmpfs = true;

      # journald to tmpfs — no rotation storms hitting SD.
      services.journald.extraConfig = ''
        Storage=volatile
        RuntimeMaxUse=32M
      '';

      # No disk-backed swap on a 256 MB / SD board — zram in stage-2.
      swapDevices = lib.mkForce [];
      zramSwap = {
        enable = true;
        algorithm = "zstd";
        memoryPercent = 50;
      };

      documentation.enable = false;
      documentation.nixos.enable = false;
      documentation.man.enable = false;
      documentation.info.enable = false;
    })
  ]);
}
