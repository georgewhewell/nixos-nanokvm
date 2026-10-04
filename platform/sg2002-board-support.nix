# The SG2002 common module: hardware-level options (kernel choice, WiFi,
# SSH keys, and tuning) and their unconditional config. Boot style is
# expressed by importing one of the modules/profiles rather than by an option
# here (for example profiles/usb-nfs-live.nix or profiles/sd-image-mainline.nix).
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

  kernelPkg =
    if cfg.kernel == "mainline" && cfg.audio.enable && cfg.bluetooth.enable
    then pkgs.sg2002-kernel-mainline-audio-bluetooth
    else if cfg.kernel == "mainline" && cfg.audio.enable
    then pkgs.sg2002-kernel-mainline-audio
    else if cfg.kernel == "mainline" && cfg.bluetooth.enable
    then pkgs.sg2002-kernel-mainline-bluetooth
    else pkgs."sg2002-kernel-${cfg.kernel}";
  fipPkg =
    if cfg.uboot == "mainline"
    then pkgs.sg2002-fip-mainline-uboot
    else pkgs.sg2002-fip;

  aic8800Pkg =
    if !cfg.wifi.enable
    then null
    else if cfg.kernel == "vendor"
    then pkgs.sg2002-aic8800-vendor-for config.boot.kernelPackages.kernel
    else if cfg.bluetooth.enable
    then pkgs.sg2002-aic8800-mainline-bluetooth-for config.boot.kernelPackages.kernel
    else pkgs.sg2002-aic8800-mainline-for config.boot.kernelPackages.kernel;

  # systemd's pivot_root success path used to detach the initrd root mount
  # without emptying its ramfs superblock.  The decompressed cpio then stayed
  # unevictable (~86 MiB on the SG2002 live image) even though /run/initramfs
  # disappeared.  Keep this generic systemd fix at the CV181x platform layer:
  # it covers every SG2002 systemd initrd while leaving other architectures
  # and non-initrd switch-root callers untouched.
  # The SG2002 cross build has no usable BPF target headers in systemd's
  # clang invocation (linux/types.h/errno.h are absent), and the board does
  # not use systemd's optional BPF framework. Disable it for a reproducible
  # riscv64 cross build while retaining the switch-root cleanup patch.
  systemdWithOldRootCleanup = pkgs.systemd.overrideAttrs (old: {
    # Nixpkgs' cross-spliced systemd can re-enable this Meson feature even
    # when withLibBPF is overridden; force the final flag off explicitly.
    mesonFlags =
      (lib.filter (flag: !lib.hasPrefix "-Dbpf-framework=" flag) (old.mesonFlags or []))
      ++ [ "-Dbpf-framework=disabled" ];
    patches = (old.patches or []) ++ [
      ../patches/systemd/0001-switch-root-clean-detached-initrd-ramfs.patch
    ];
  });
in {
  imports = [
    ../modules/bluetooth-aic8800.nix
    ../modules/sg2002-audio.nix
    ../modules/sg2002-c906l.nix
  ];

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
          - mainline: nixpkgs `linux_latest` (7.x) + the local SG2002 patch stack.
          - vendor:   Sipeed's 5.10 tree. Requires vendor-fit boot;
            incompatible with extlinux / usb-live / zram / erofs.

        (A `sophgo` option for the sophgo/linux for-next branch used
        to be listed here but was never packaged; reintroduce only
        alongside an `sg2002-kernel-sophgo` overlay attribute.)
      '';
    };

    mitigations = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to retain the kernel's default CPU vulnerability mitigations.
        Setting this to false adds `mitigations=off` to the kernel command line.
        On mainline this permits XTheadVector and its guarded copy paths.
        It disables all CPU mitigations controlled by that argument, not only
        Ghostwrite.
      '';
    };

    uboot = mkOption {
      type = types.enum ["mainline" "vendor"];
      default = "mainline";
      description = "Which U-Boot/FIP to install on the firmware partition.";
    };

    uart1Rescue.enable = mkOption {
      type = types.bool;
      default = false;
      description = "Whether this carrier exposes UART1 as a physical rescue console.";
    };

    consoleDevice = mkOption {
      type = types.enum ["ttyS0" "ttyS1" "ttyGS0" "tty0"];
      default = "ttyS0";
      description = "Final kernel console device used as /dev/console.";
    };

    fdt = mkOption {
      type = types.path;
      description = ''
        Device-tree blob this board boots. Single source of truth shared
        by the vendor-FIT SD path (modules/sg2002-vendor-fit.nix) and the
        USB boot-fit / kexec artifacts (lib/artifacts.nix) — neither
        re-derives the DTB itself anymore.

        The platform sets a sensible default per kernel; feature modules
        (WiFi, OLED) and carrier boards (NanoKVM-PCIe ethernet) override
        it, lowest-priority-wins so a carrier board beats a feature mixin.
      '';
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
      wpaConfRuntimePath = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "/run/sg2002-wpa_supplicant.conf";
        description = ''
          Optional /run path used by both the initrd and stage-2
          wpa_supplicant services.  When wpaConf is set, the initrd copies it
          there before association; when wpaConf is null, an earlier initrd
          service must create the file.  Because /run survives switch-root,
          a USB boot host can inject a runtime secret without placing it in
          the Nix store.
        '';
      };
    };

    authorizedKeys = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "SSH public keys baked into root's ~/.ssh/authorized_keys.";
    };

    tuning.enable =
      mkEnableOption "SD-longevity and low-RAM defaults (noatime, zram in stage-2, journald volatile, no disk swap, docs off)"
      // {default = true;};

    initrd = {
      pruneKernelModules =
        mkEnableOption "Use the SG2002-pruned initrd kernel module lists";
      availableKernelModules = mkOption {
        type = types.listOf types.str;
        default = [];
        description = ''
          Kernel modules to include in SG2002 initrds when
          sg2002.initrd.pruneKernelModules is enabled.
        '';
      };
      kernelModules = mkOption {
        type = types.listOf types.str;
        default = [];
        description = ''
          Kernel modules to load in SG2002 initrds when
          sg2002.initrd.pruneKernelModules is enabled.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      # SG2002 helper modules refer to pkgs.systemd directly (for example
      # extlinux health checks and USB activation scripts), not only through
      # the NixOS `systemd.package` option. Override the package set as well
      # so those helpers cannot pull an unbuildable BPF-enabled cross systemd
      # into the closure.
      nixpkgs.overlays = [
        (final: prev: {
          systemd = prev.systemd.overrideAttrs (old: {
            mesonFlags =
              (lib.filter (flag: !lib.hasPrefix "-Dbpf-framework=" flag) (old.mesonFlags or []))
              ++ [ "-Dbpf-framework=disabled" ];
          });
          # The board uses qemu-img only for the factory/runtime helpers;
          # retaining its enormous cross-debug source tree is unnecessary on
          # a 256-MB target and can stall the build during debug-copy.
          qemu-utils = prev.qemu-utils.overrideAttrs (_old: {
            separateDebugInfo = false;
          });
        })
      ];
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

      # Default DTB per kernel: vendor uses its gadget DTS; mainline
      # defaults to the cable-only (no-WiFi) DTB. Feature mixins / carrier
      # boards override at a higher priority. mkOptionDefault keeps this
      # below an mkDefault from a mixin.
      sg2002.fdt = lib.mkOptionDefault (
        if cfg.kernel == "vendor"
        then pkgs.sg2002-dtb-vendor-gadget
        else pkgs.sg2002-dtb-mainline-nowifi
      );

      # sd-image pulls a grab-bag of modules; board doesn't need
      # most, and vendor kernel ships no module tree (modules-shrunk
      # would error out).
      hardware.enableAllHardware = lib.mkForce false;

      boot.kernelPackages = pkgs.linuxPackagesFor kernelPkg;
      powerManagement.cpuFreqGovernor = lib.mkIf (cfg.kernel == "mainline")
        (lib.mkDefault "schedutil");
      # nowayout protects against closing /dev/watchdog, not the kernel's
      # reboot notifier. dw_wdt otherwise stops the counter before kexec,
      # leaving a failed handoff without a hardware reset. Use the standard
      # watchdog-core policy rather than a driver or register workaround.
      boot.kernelParams = lib.optional (cfg.kernel == "mainline")
        "watchdog.stop_on_reboot=0"
        ++ lib.optional (!cfg.mitigations) "mitigations=off";
      systemd.package = lib.mkDefault systemdWithOldRootCleanup;
      system.build.fip = fipPkg;

      boot.extraModulePackages = lib.optional (aic8800Pkg != null) aic8800Pkg;
      boot.kernelModules =
        lib.optional (cfg.kernel == "mainline" && cfg.wifi.enable) "rfkill"
        ++ lib.optionals cfg.bluetooth.enable [ "bluetooth" "bnep" "rfcomm" ]
        ++ lib.optionals (aic8800Pkg != null) [
          "aic8800_bsp"
          "aic8800_fdrv"
          "aic8800_btlpm"
        ];
      # systemd-modules-load remains active across switch-root and therefore
      # does not replay boot.kernelModules in stage 2.  A pruned SD initrd must
      # carry and load the WiFi stack itself; otherwise /dev/rfkill and wlan0
      # never appear and the hardened wpa_supplicant unit cannot start.
      sg2002.initrd.availableKernelModules = lib.optionals
        (cfg.kernel == "mainline" && cfg.wifi.enable) (
          # PKCS#7 verification requests SHA-256 through the crypto API at
          # runtime; it is not a static dependency of cfg80211. Preserve it
          # when pruning the initrd so signed regulatory.db is accepted.
          [ "rfkill" "sha256" ]
          ++ lib.optionals cfg.bluetooth.enable [ "bluetooth" "bnep" "rfcomm" ]
          ++ [
            "aic8800_bsp"
            "aic8800_fdrv"
            "aic8800_btlpm"
          ]
        );
      sg2002.initrd.kernelModules = lib.optionals
        (cfg.kernel == "mainline" && cfg.wifi.enable) (
          [ "rfkill" ]
          # RFCOMM is only consumed by BlueZ after switch-root.  Keep its
          # module in the pruned initrd closure, but do not perturb the
          # SDIO/WiFi bring-up order by loading it in stage 1.
          ++ lib.optionals cfg.bluetooth.enable [ "bluetooth" "bnep" ]
          ++ [
            "aic8800_bsp"
            "aic8800_fdrv"
            "aic8800_btlpm"
          ]
        );
      hardware.firmware = lib.optional cfg.wifi.enable pkgs.sg2002-aic8800-firmware;
      # These small images deliberately omit the all-firmware collection,
      # which normally enables the signed cfg80211 database in NixOS. Keep
      # the standard database available in both the initrd and stage 2,
      # independently of which service manages Wi-Fi association.
      hardware.wirelessRegulatoryDatabase = lib.mkIf cfg.wifi.enable (lib.mkDefault true);

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

    (lib.mkIf cfg.initrd.pruneKernelModules {
      boot.initrd.availableKernelModules =
        lib.mkForce (lib.unique cfg.initrd.availableKernelModules);
      boot.initrd.kernelModules =
        lib.mkForce (lib.unique cfg.initrd.kernelModules);
    })

    (lib.mkIf (cfg.kernel == "mainline" && cfg.wifi.enable) {
      # AIC8800 opens its blobs through literal /lib/firmware paths rather
      # than request_firmware().  systemd-modules-load runs before tmpfiles,
      # so the firmware must be part of the initrd's /lib tree at build time.
      boot.initrd.systemd.contents."/lib".source = lib.mkForce (
        pkgs.runCommand "sg2002-initrd-lib" {} ''
          mkdir -p $out
          ln -s ${config.system.build.modulesClosure}/lib/modules $out/modules
          ln -s ${config.hardware.firmware}/lib/firmware $out/firmware
        ''
      );
    })

    (lib.mkIf cfg.tuning.enable {
      # noatime kills per-read timestamp writes; commit=600 extends Btrfs
      # transaction commits to 10 min. Trade-off: a longer window of recent
      # data loss on hard reset, acceptable on a development SD card.
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
