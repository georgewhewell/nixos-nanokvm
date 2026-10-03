# A complete, volatile appliance in stage 1. No root disk or stage 2 is built
# into the USB payload, and no service on the uploading host is required.
{ config, lib, pkgs, rootAuthorizedKeys ? [ ], rootWpaConf ? null, ... }:
let
  aux = config.sg2002.auxCore;
  lcd = builtins.elem "picoclawLcd" aux.peripherals;
  ctl = pkgs.sg2002-c906l-ctl-for (pkgs.sg2002-c906l-contract-for aux.peripherals);
in {
  imports = [
    ../modules/sg2002-usb-gadget-initrd.nix
    ../modules/sg2002-watchdog-keeper.nix
  ];

  networking.hostName = lib.mkDefault "nanokvm";
  fileSystems = lib.mkForce { };
  boot.loader.grub.enable = false;
  hardware.deviceTree.enable = lib.mkForce false;
  services.nanokvm.enable = lib.mkForce false;

  sg2002 = {
    audio.enable = lib.mkDefault true;
    wifi = {
      wpaConf = lib.mkDefault rootWpaConf;
      # Credentials can also be installed over authenticated USB SSH.
      wpaConfRuntimePath = lib.mkDefault "/run/wpa_supplicant.conf";
    };
    usbGadget = {
      network.enable = true;
      stage2.enable = false;
      # Keep ACM as a device, but don't let an unopened serial console stall
      # the kernel or PID 1. UART remains the physical recovery console.
      console.enable = false;
    };
    watchdogKeeper = {
      initrd.enable = true;
      stage2.enable = false;
      healthHost = null;
    };
    initrd = {
      pruneKernelModules = true;
      # The DT alias lets udev probe this optional display as soon as it can.
      # Keep panel initialization out of systemd-modules-load's sysinit path;
      # the driver already defers until the C906L lease is validated/active.
      availableKernelModules = lib.optional lcd "sg2002-c906l-framebuffer";
      kernelModules = [ "af_packet" ] ++ lib.optionals aux.enable [
        "sg2002-c906l-control" "sg2002-c906l-remoteproc"
      ] ++ lib.optionals lcd [
        "sg2002-c906l-wifi-power"
      ];
    };
  };

  # tty0 buffers kernel output even before fbdev registers. UART stays last
  # so /dev/console and PID 1's output retain the physical recovery console.
  boot.kernelParams = lib.mkForce (lib.optional lcd "console=tty0" ++ [
    "console=${if config.sg2002.uart1Rescue.enable then "ttyS1" else "ttyS0"},115200"
    "earlycon=sbi" "panic=10" "oops=panic" "riscv.fwsz=0x80000"
    # This profile replaces kernelParams, so retain the platform's watchdog
    # and RNG policies explicitly as well as its recovery console.
    "watchdog.stop_on_reboot=0"
    "rng_core.default_quality=0"
    "systemd.getty_auto=no" "udev.children_max=2"
  ] ++ lib.optionals lcd [
    # Standard fbcon takeover; the built-in 4x6 font gives 60x40 characters.
    # Stage 1 remains key-only SSH with a read-only local boot console.
    "fbcon=nodefer" "fbcon=font:MINI4x6" "consoleblank=0" "loglevel=7"
  ]);
  system.build.fipFastboot = lib.mkDefault pkgs.sg2002-fip-mainline-fastboot;
  boot.initrd = {
    compressor = "zstd";
    services.resolved.enable = true;
    services.lvm.enable = false;
    network.ssh = {
      enable = true;
      authorizedKeys = rootAuthorizedKeys;
      hostKeys = [ ];
      ignoreEmptyHostKeys = true;
      extraConfig = ''
        HostKey /run/ssh/ssh_host_ed25519_key
        PermitRootLogin prohibit-password
        PermitEmptyPasswords no
        AllowUsers root
        Subsystem sftp internal-sftp
      '';
    };
    systemd = {
      enable = true;
      # Keep the RAM appliance's networking, diagnostics, console and
      # sandboxing without pulling in stage-2 managers and their libraries.
      package = lib.mkDefault (pkgs.systemdMinimal.override {
        withAnalyze = true;
        withNetworkd = true;
        withResolved = true;
        withNss = true;
        withOpenSSL = true;
        withLibseccomp = true;
        withVConsole = true;
        withAcl = true;
        withCompression = true;
        withHwdb = true;
        # systemd-bsod is part of the initrd's boot-failure console.
        withQrencode = true;
      });
      tpm2.enable = false;
      root = null;
      emergencyAccess = false;
      # Do not copy every systemd administration program (homectl, repart,
      # cryptsetup, etc.) into a 256 MiB board's rootfs. Keep only the tools
      # needed here; the initrd module adds PID 1 and its service helpers.
      initrdBin = lib.mkForce [ pkgs.coreutils pkgs.bashInteractive pkgs.kmod ];
      # initrd.target still starts the usual udev/network/peripheral units;
      # its transition out of RAM is deliberately absent, not a failed mount.
      services = lib.genAttrs [
        "initrd-find-nixos-closure" "initrd-nixos-activation"
        "initrd-switch-root" "initrd-cleanup" "initrd-parse-etc"
        "systemd-tmpfiles-setup-sysroot"
      ] (_: { enable = false; }) // {
        wpa_supplicant-wlan0 = lib.mkIf config.sg2002.wifi.enable {
          # Start association when the interface appears. An optional WLAN
          # that is absent or fails to probe must not add a 90-second device
          # job to the RAM appliance's startup (conditions alone do not
          # prevent systemd from queuing a service's device dependencies).
          wantedBy = lib.mkForce [ "sys-subsystem-net-devices-wlan0.device" ];
          wants = lib.mkForce [ ];
          # An unprovisioned RAM image is valid. Copying credentials over SSH
          # and explicitly restarting this unit enables association later.
          unitConfig.ConditionPathExists = lib.mkIf
            (config.sg2002.wifi.wpaConf == null
              && config.sg2002.wifi.wpaConfRuntimePath != null)
            config.sg2002.wifi.wpaConfRuntimePath;
        };
        sshd = {
          preStart = lib.mkBefore ''
            mkdir -p /run/ssh /run/sshd /var/empty /root
            chmod 0700 /run/ssh /root
            if ! test -e /run/ssh/ssh_host_ed25519_key; then
              ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -f /run/ssh/ssh_host_ed25519_key
            fi
          '';
        };
      };
      targets.initrd-switch-root.enable = false;
      storePaths = [
        # glibc dlopens the unwinder for pthread_cancel; it is not an ELF
        # DT_NEEDED dependency that makeInitrdNG can discover. Use glibc's
        # own trusted runtime, without adding the full compiler closure.
        "${pkgs.glibc.libgcc}/lib/libgcc_s.so.1"
      ] ++ lib.optional config.sg2002.audio.enable "${pkgs.alsa-lib}/share/alsa";
      network = {
        enable = true;
        wait-online.enable = false;
        # First-match networkd policy, including USB, Ethernet and WLAN.
        # Link-local access works even without a DHCP server on the USB host.
        networks = lib.mkForce {
          "10-all-links" = {
            matchConfig.Name = [ "eth*" "en*" "wl*" "usb*" ];
            linkConfig.RequiredForOnline = "no";
            networkConfig = {
              DHCP = "yes";
              IPv6AcceptRA = true;
              LinkLocalAddressing = "yes";
              MulticastDNS = true;
            };
          };
        };
      };
      extraBin = {
        systemctl = "${config.boot.initrd.systemd.package}/bin/systemctl";
        systemd-analyze = "${config.boot.initrd.systemd.package}/bin/systemd-analyze";
        journalctl = "${config.boot.initrd.systemd.package}/bin/journalctl";
        networkctl = "${config.boot.initrd.systemd.package}/bin/networkctl";
        resolvectl = "${config.boot.initrd.systemd.package}/bin/resolvectl";
        udevadm = "${config.boot.initrd.systemd.package}/bin/udevadm";
        systemd-tmpfiles = "${config.boot.initrd.systemd.package}/bin/systemd-tmpfiles";
        ip = "${pkgs.iproute2}/bin/ip";
        ping = "${pkgs.iputils}/bin/ping";
        ssh-keygen = "${pkgs.openssh}/bin/ssh-keygen";
      } // lib.optionalAttrs config.sg2002.wifi.enable {
        iw = "${pkgs.iw}/bin/iw";
        wpa_cli = "${pkgs.wpa_supplicant}/bin/wpa_cli";
      } // lib.optionalAttrs config.sg2002.audio.enable {
        aplay = "${config.sg2002.audio.package}/bin/aplay";
        arecord = "${config.sg2002.audio.package}/bin/arecord";
        amixer = "${config.sg2002.audio.package}/bin/amixer";
      } // lib.optionalAttrs aux.enable {
        sg2002-c906l-ctl = "${ctl}/bin/sg2002-c906l-ctl";
      } // lib.optionalAttrs lcd {
        sg2002-c906l-drm-test = "${pkgs.sg2002-c906l-drm-test}/bin/sg2002-c906l-drm-test";
      };
    };
  };
}
