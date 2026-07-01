{ config
, lib
, pkgs
, ...
}:
let
  cfg = config.services.nanokvm;
  compatUnit = "nanokvm-compat.service";
  yaml = pkgs.formats.yaml { };
  kmodsUnit = "nanokvm-kmods.service";
  usbGadgetUnit = "nanokvm-usb-gadget.service";
  hwInitUnit = "nanokvm-hwinit.service";
  kvmSystemUnit = "nanokvm-kvm-system.service";
  serverDependencyUnits =
    [ compatUnit ]
    ++ lib.optional cfg.kmods.enable kmodsUnit
    ++ lib.optional cfg.usbGadget.enable usbGadgetUnit
    ++ lib.optional cfg.hwInit.enable hwInitUnit;

  # kvm_system and the pcie pad-mux/GPIO init only make sense on the
  # actual cv181x device running the vendor 5.10 kernel: the binary is
  # riscv64-musl, the sysfs gpio numbers (451/502..505) are the vendor
  # kernel's numbering, and the soph_* capture stack it babysits is
  # vendor-only. `config.sg2002 or` so the module still evaluates on
  # deployments (Rock-5B, dev hosts) that don't import the sg2002
  # platform module at all.
  onVendorKernelDevice =
    ((config.sg2002.kernel or null) == "vendor")
    && pkgs.stdenv.hostPlatform.isRiscV64;

  serverConfig = yaml.generate "nanokvm-server.yaml" {
    proto = "http";
    host = "";
    port = {
      http = cfg.httpPort;
      https = cfg.httpsPort;
    };
    cert = {
      crt = "server.crt";
      key = "server.key";
    };
    logger = {
      level = cfg.logLevel;
      file = "stdout";
    };
    jwt = {
      secretKey = "";
      refreshTokenDuration = 2678400;
      revokeTokensOnLogout = true;
    };
    stun = "stun.l.google.com:19302";
    turn = {
      turnAddr = "";
      turnUser = "";
      turnCred = "";
    };
    authentication = cfg.authentication;
    security = {
      loginLockoutDuration = 0;
      loginMaxFailures = 5;
    };
  };

  teardownGadget = pkgs.writeShellScript "nanokvm-teardown-gadget" ''
    set -u
    gadget=/sys/kernel/config/usb_gadget/g0
    [ -d "$gadget" ] || exit 0

    # configfs enforces strict reverse-order teardown: symlinks in
    # configs/ before function dirs, function dirs before their
    # strings sub-dirs, strings before the function root. Anything
    # bound to the UDC has to go first or the rmdirs return EBUSY.

    # 1. Unbind from the UDC. The write succeeds immediately but the
    #    kernel may take a tick to clean up its end; small sleep lets
    #    rmdirs that follow not race against a still-live config.
    if [ -e "$gadget/UDC" ]; then
      printf '%s' "" > "$gadget/UDC" 2>/dev/null || true
      sleep 0.1
    fi

    # 2. Drop function references in each config (the symlinks named
    #    `<func>.<label>`), then rmdir the per-config strings subtree,
    #    then the config itself. `-depth -empty` makes find rmdir the
    #    leaves first.
    find "$gadget/configs" -type l -delete 2>/dev/null || true
    find "$gadget/configs" -depth -type d -empty -delete 2>/dev/null || true

    # 3. Rmdir each function. Try a few times — functions sometimes
    #    EBUSY briefly after UDC unbind on dwc2.
    for _ in 1 2 3 4 5; do
      find "$gadget/functions" -mindepth 1 -maxdepth 1 -type d \
        -exec rmdir {} + 2>/dev/null
      ls "$gadget/functions" 2>/dev/null | grep -q . || break
      sleep 0.1
    done

    # 4. Top-level strings + gadget itself.
    find "$gadget/strings" -depth -type d -empty -delete 2>/dev/null || true
    rmdir "$gadget" 2>/dev/null || true
  '';

  initRestartScript = pkgs.writeShellScript "S95nanokvm" ''
    set -eu
    case "''${1:-}" in
      start|restart)
        exec ${pkgs.systemd}/bin/systemctl restart nanokvm-server.service
        ;;
      stop)
        exec ${pkgs.systemd}/bin/systemctl stop nanokvm-server.service
        ;;
      *)
        echo "usage: $0 {start|stop|restart}" >&2
        exit 2
        ;;
    esac
  '';

  activation = ''
    mkdir -p /etc/kvm /etc/init.d /boot /data /kvmapp/kvm /mnt/data

    if [ ! -e /etc/kvm/server.yaml ]; then
      cp ${serverConfig} /etc/kvm/server.yaml
      chmod 0644 /etc/kvm/server.yaml
    fi

    printf '%s\n' ${lib.escapeShellArg cfg.hardwareVersion} > /etc/kvm/hw
    printf '%s\n' ${lib.escapeShellArg cfg.hdmiVersion} > /etc/kvm/hdmi_version

    # Sensor INI for the vendor capture SDK. libkvm_mmf.so's
    # SAMPLE_COMM_VI_ParseIni reads /mnt/data/sensor_cfg.ini during
    # kvmv_init and capture is dead without it. Only camera-enabled
    # riscv64 server builds ship lib/nanokvm/data (mainline/nocamera
    # builds never init the SDK). Refreshed unconditionally from the
    # LT6911 variant, same as the stock S95nanokvm does on every boot.
    if [ -e ${cfg.package}/lib/nanokvm/data/sensor_cfg.ini.LT ]; then
      cp ${cfg.package}/lib/nanokvm/data/sensor_cfg.ini.LT /mnt/data/sensor_cfg.ini
      chmod 0644 /mnt/data/sensor_cfg.ini
    fi

    # Mutable stream-state files shared between nanokvm-server (web
    # UI writes type/fps/qlty/res, streamer writes now_fps) and
    # kvm_system (reads them for the OLED status page). Stock image
    # ships them pre-seeded on the rootfs; seed the same defaults but
    # never clobber values the user changed via the web UI.
    seed_kvm_state() {
      [ -e "/kvmapp/kvm/$1" ] || printf '%s\n' "$2" > "/kvmapp/kvm/$1"
    }
    seed_kvm_state res 0
    seed_kvm_state width 1920
    seed_kvm_state height 1080
    seed_kvm_state state 1
    seed_kvm_state now_fps 0
    seed_kvm_state type mjpeg
    seed_kvm_state qlty 60
    seed_kvm_state fps 30

    ${
      if cfg.hdmi.enable
      then "rm -f /etc/kvm/hdmi_disabled"
      else ": > /etc/kvm/hdmi_disabled"
    }

    # cv181x vendor init.d compat shims. Only present in the
    # riscv64 cross build (the native aarch64/x86_64 server omits
    # /lib/nanokvm/system entirely). Skip cleanly when missing — the
    # Rock-5B / dev-host deployments don't run S03usb*/S00kmod at all
    # (services.nanokvm.kmods.enable + .usbGadget.enable should be
    # set to false on those targets).
    if [ -e ${cfg.package}/lib/nanokvm/system/init.d/S03usbdev ]; then
      if [ ! -e /etc/init.d/S03usbdev ]; then
        cp ${cfg.package}/lib/nanokvm/system/init.d/S03usbdev /etc/init.d/S03usbdev
        chmod 0755 /etc/init.d/S03usbdev
      fi
      cp ${cfg.package}/lib/nanokvm/system/init.d/S03usbhid /etc/init.d/S03usbhid
      chmod 0755 /etc/init.d/S03usbhid
    fi

    cp ${initRestartScript} /etc/init.d/S95nanokvm
    chmod 0755 /etc/init.d/S95nanokvm
  '';
in
{
  options.services.nanokvm = with lib; {
    enable = mkEnableOption "Sipeed NanoKVM server";

    package = mkOption {
      type = types.package;
      # The server RUNS ON THE DEVICE (riscv64). The package gets spliced
      # to the build host in a cross config, so we force targetSystem to
      # get a real riscv64 binary (otherwise it's x86_64 → 203/EXEC on the
      # device). Mainline kernels must use the nocamera variant — libkvm.so's
      # C++ static ctors SEGV under mainline; vendor keeps camera/HDMI.
      # nanokvm-server-device is instantiated in the overlay via
      # buildPackages.callPackage with targetSystem=riscv64 (see comment
      # there) — a real riscv64 binary. Referencing it directly (no
      # .override) avoids the cross-splice arg-dropping.
      default = pkgs.nanokvm-server-device;
      defaultText = literalExpression "pkgs.nanokvm-server-device";
      description = "NanoKVM server package to run on the device.";
    };

    httpPort = mkOption {
      type = types.port;
      default = 80;
      description = "HTTP port for the NanoKVM web application.";
    };

    httpsPort = mkOption {
      type = types.port;
      default = 443;
      description = "HTTPS port recorded in NanoKVM's mutable config.";
    };

    authentication = mkOption {
      type = types.enum [ "enable" "disable" ];
      default = "enable";
      description = "NanoKVM application authentication setting.";
    };

    logLevel = mkOption {
      type = types.enum [ "debug" "info" "warn" "error" ];
      default = "info";
      description = "NanoKVM server log level.";
    };

    server.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Run the NanoKVM web server.";
    };

    hardwareVersion = mkOption {
      type = types.enum [ "alpha" "beta" "pcie" ];
      default = "pcie";
      description = "Value written to /etc/kvm/hw.";
    };

    hdmiVersion = mkOption {
      type = types.str;
      default = "ux";
      description = "Value written to /etc/kvm/hdmi_version.";
    };

    hdmi.enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Initialise the HDMI capture pipeline at server startup. When
        false, drops an empty `/etc/kvm/hdmi_disabled` marker file
        which the patched server treats as "skip kvmv_init entirely".

        On mainline kernels the vendor's camera/IPS sample helpers
        SAMPLE_COMM_VI_ParseIni against a sensor INI that we don't
        ship, returns 0xffffffff, then dereferences NULL and SEGVs.
        The crash-loop keeps the web UI from ever binding port 80.
        Setting `hdmi.enable = false` is the workaround until mainline
        camera capture lands.
      '';
    };

    kmods.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Load the NanoKVM factory multimedia kernel modules before starting the server.";
    };

    usbGadget.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Let the NanoKVM factory USB gadget script own the stage-2 USB gadget.";
    };

    kvmSystem.enable = mkOption {
      type = types.bool;
      default = onVendorKernelDevice;
      defaultText = literalExpression ''config.sg2002.kernel == "vendor" && riscv64 device'';
      description = ''
        Run the prebuilt vendor `kvm_system` binary (extracted from the
        factory image via nanokvm-factory-runtime). It configures the
        LT6911 HDMI bridge over /dev/i2c-4 — resolution detection and
        EDID handling live there, so HDMI capture does not work without
        it — and additionally drives the OLED status UI and the ATX
        power/reset buttons and LEDs.

        Only meaningful on the vendor 5.10 kernel with a camera-enabled
        riscv64 server package (the binary ships inside the package's
        lib/nanokvm/kvm_system; nocamera builds carry only the empty
        source placeholder and the unit skips itself via a path
        condition).
      '';
    };

    hwInit.enable = mkOption {
      type = types.bool;
      default = onVendorKernelDevice && cfg.hardwareVersion == "pcie";
      defaultText = literalExpression ''vendor kernel && riscv64 device && hardwareVersion == "pcie"'';
      description = ''
        Reproduce the factory S15kvmhwd `init_beta_pcie_hw` hardware
        bring-up for the NanoKVM-PCIe carrier: devmem pad muxing
        (keys/LED GPIOs, SDIO, UART1/2), sysfs GPIO exports for the ATX
        header (gpio503/504/505) and OLED reset (gpio502), and — most
        importantly for capture — drives the LT6911 HDMI bridge reset
        line (gpio451) HIGH so the bridge comes out of reset. Also
        reloads i2c-algo-bit/i2c-gpio so the bit-banged OLED bus
        (i2c-5) re-probes after the pads are muxed.

        Skips the factory alpha/beta autodetect: this flake already
        pins /etc/kvm/hw and /etc/kvm/hdmi_version via
        services.nanokvm.hardwareVersion / hdmiVersion.

        The sysfs GPIO numbers are the vendor kernel's numbering —
        hence the vendor-kernel-only default.
      '';
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Open the configured NanoKVM HTTP and HTTPS ports.

        NOTE: currently a no-op — `platform/sg2002-board-support.nix`
        sets `networking.firewall.enable = false` for the whole SG2002
        target, and `profiles/usb-nbd-live.nix` `mkForce false`s it for
        live USB images. Setting `services.nanokvm.openFirewall = true`
        does nothing on those targets.

        Kept as an option (and honored verbatim when the firewall is
        on) so an opt-in firewall path remains discoverable; the real
        fix is to flip the platform default and audit every listener
        for explicit allow rules.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      environment.systemPackages = [
        cfg.package
        pkgs.i2c-tools
        pkgs.iproute2
        pkgs.usbutils
      ];

      systemd.tmpfiles.rules = [
        "d /etc/kvm 0755 root root -"
        "d /etc/init.d 0755 root root -"
        "d /boot 0755 root root -"
        "d /data 0755 root root -"
        "d /mnt 0755 root root -"
        "d /mnt/data 0755 root root -"
        "d /mnt/system 0755 root root -"
        "d /kvmapp 0755 root root -"
        "d /kvmapp/kvm 0755 root root -"
        "L+ /mnt/system/ko - - - - ${cfg.package}/lib/nanokvm/system/ko"
        "L+ /kvmapp/server - - - - ${cfg.package}/lib/nanokvm/server"
        "L+ /kvmapp/system - - - - ${cfg.package}/lib/nanokvm/system"
        "L+ /kvmapp/kvm_system - - - - ${cfg.package}/lib/nanokvm/kvm_system"
        "L+ /kvmapp/picoclaw - - - - ${cfg.package}/lib/nanokvm/picoclaw"
        "L+ /kvmapp/version - - - - ${cfg.package}/lib/nanokvm/version"
      ];

      system.activationScripts.nanokvmCompat = lib.mkIf (!config.system.nixos-init.enable) {
        text = activation;
      };

      systemd.services.nanokvm-compat = {
        description = "NanoKVM compatibility files";
        wantedBy = [ "multi-user.target" ];
        before = [ "nanokvm-server.service" ] ++ lib.optional cfg.usbGadget.enable usbGadgetUnit;
        after = [ "systemd-tmpfiles-setup.service" ];

        path = with pkgs; [
          coreutils
        ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };

        script = activation;
      };
    }

    (lib.mkIf cfg.kmods.enable {
      systemd.services.nanokvm-kmods = {
        description = "NanoKVM Sophgo multimedia kernel modules";
        wantedBy = [ "multi-user.target" ];
        before = [
          "nanokvm-server.service"
        ] ++ lib.optional cfg.usbGadget.enable usbGadgetUnit;
        after = [ "systemd-modules-load.service" ];

        path = with pkgs; [
          bash
          coreutils
          kmod
        ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${cfg.package}/lib/nanokvm/system/init.d/S00kmod start";
        };
      };
    })

    (lib.mkIf cfg.usbGadget.enable {
      boot.kernelModules = [ "libcomposite" ];

      systemd.services.nanokvm-usb-gadget = {
        description = "NanoKVM USB composite gadget";
        wantedBy = [ "multi-user.target" ];
        before = [ "nanokvm-server.service" ];
        after = [
          compatUnit
          "nanokvm-kmods.service"
          "sys-kernel-config.mount"
          "systemd-modules-load.service"
        ];
        requires = [
          compatUnit
          "sys-kernel-config.mount"
        ];

        path = with pkgs; [
          bash
          coreutils
          findutils
          gnugrep
          gnused
          util-linux
        ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStartPre = teardownGadget;
          ExecStart = "/etc/init.d/S03usbdev start";
          ExecStop = "/etc/init.d/S03usbdev stop";
        };
      };
    })

    (lib.mkIf cfg.hwInit.enable {
      # Faithful port of the factory S15kvmhwd `init_beta_pcie_hw`
      # (minus the alpha/beta autodetect — hardware identity is pinned
      # by services.nanokvm.hardwareVersion). Runs as root with
      # /dev/mem access (vendor kernel ships CONFIG_DEVMEM; the pinmux
      # block at 0x03001000 is MMIO, which STRICT_DEVMEM doesn't
      # restrict).
      systemd.services.nanokvm-hwinit = {
        description = "NanoKVM-PCIe pad mux, ATX GPIOs and HDMI bridge reset";
        wantedBy = [ "multi-user.target" ];
        # Stock runs S00kmod (kmods) before S15kvmhwd; keep that order.
        # Must complete before kvm_system pokes the LT6911 over i2c-4
        # and before the server's kvmv_init opens the capture pipeline.
        before =
          [ "nanokvm-server.service" ]
          ++ lib.optional cfg.kvmSystem.enable kvmSystemUnit;
        after =
          [
            "systemd-modules-load.service"
            "systemd-tmpfiles-setup.service"
          ]
          ++ lib.optional cfg.kmods.enable kmodsUnit;

        path = with pkgs; [
          busybox # devmem
          coreutils
          kmod
        ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };

        # Register-by-register copy of init_beta_pcie_hw. PINMUX base
        # 0x03001000; value 0x3 = GPIO function on these pads.
        script = ''
          devmem 0x0300103C 32 0x3  # GPIOA15
          devmem 0x03001050 32 0x3  # GPIOA22
          devmem 0x0300105C 32 0x3  # GPIOA23
          devmem 0x03001060 32 0x3  # GPIOA24
          devmem 0x03001054 32 0x3  # GPIOA25
          devmem 0x03001058 32 0x3  # GPIOA27

          devmem 0x030010E4 32 0x0  # SDIO CLK
          devmem 0x030010E0 32 0x0  # SDIO CMD
          devmem 0x030010DC 32 0x0  # SDIO D0
          devmem 0x030010D8 32 0x0  # SDIO D1
          devmem 0x030010D4 32 0x0  # SDIO D2
          devmem 0x030010D0 32 0x0  # SDIO D3

          devmem 0x03001068 32 0x6  # GPIOA 18 UART1 RX
          devmem 0x03001064 32 0x6  # GPIOA 19 UART1 TX
          devmem 0x03001070 32 0x2  # GPIOA 28 UART2 TX
          devmem 0x03001074 32 0x2  # GPIOA 29 UART2 RX

          # Sysfs GPIO setup. Export is not idempotent (EBUSY when the
          # pin is already exported, e.g. on unit restart) — guard each
          # one; direction/value writes are safe to repeat.
          gpio_export() {
            [ -d "/sys/class/gpio/gpio$1" ] || echo "$1" > /sys/class/gpio/export
          }

          gpio_export 502                                 # OLED_RST
          echo out > /sys/class/gpio/gpio502/direction
          echo 1   > /sys/class/gpio/gpio502/value

          gpio_export 504                                 # PWR_LED (sense)
          gpio_export 503                                 # PWR_KEY
          gpio_export 505                                 # RST_KEY
          gpio_export 451                                 # PCIe_HDMI_RST

          echo in  > /sys/class/gpio/gpio504/direction
          echo out > /sys/class/gpio/gpio503/direction
          echo out > /sys/class/gpio/gpio505/direction
          echo out > /sys/class/gpio/gpio451/direction

          # Hold the LT6911 HDMI bridge OUT of reset — without this the
          # bridge never answers on i2c-4 and capture is dead.
          echo 1 > /sys/class/gpio/gpio451/value

          # Reload the bit-banged i2c stack so the OLED bus (i2c-5)
          # re-probes now that the pads are muxed. Stock insmods the
          # factory .ko from /mnt/system/ko; our vendor kernel builds
          # the same 5.10 modules (CONFIG_I2C_GPIO=m), so modprobe from
          # the system module tree is equivalent and handles the
          # algo-bit dependency ordering itself.
          rmmod i2c_gpio 2>/dev/null || true
          rmmod i2c_algo_bit 2>/dev/null || true
          modprobe i2c-algo-bit
          modprobe i2c-gpio
        '';
      };
    })

    (lib.mkIf cfg.kvmSystem.enable {
      systemd.services.nanokvm-kvm-system = {
        description = "NanoKVM kvm_system (LT6911 bridge, OLED UI, ATX buttons)";
        wantedBy = [ "multi-user.target" ];
        # Stock S95nanokvm starts kvm_system before NanoKVM-Server;
        # mirror that (ordering only — the server must not be torn
        # down if kvm_system crash-loops, so no Requires from the
        # server side).
        before = [ "nanokvm-server.service" ];
        after =
          [ compatUnit ]
          ++ lib.optional cfg.kmods.enable kmodsUnit
          ++ lib.optional cfg.hwInit.enable hwInitUnit;
        requires =
          [ compatUnit ]
          ++ lib.optional cfg.kmods.enable kmodsUnit
          ++ lib.optional cfg.hwInit.enable hwInitUnit;

        # kvm_system shells out via system(3): touch/rm for
        # /etc/kvm/oled_exist (it maintains that marker itself),
        # sync, and `reboot` when its vision watchdog trips (armed
        # only if /etc/kvm/watchdog or /tmp/watchdog exists).
        path = with pkgs; [
          busybox
          coreutils
          systemd
        ];

        # Only camera-enabled riscv64 builds ship the real binary
        # (nocamera packages carry just the source placeholder dir);
        # skip cleanly instead of crash-looping if the package and
        # this option ever disagree.
        unitConfig.ConditionPathExists = "${cfg.package}/lib/nanokvm/kvm_system/kvm_system";

        serviceConfig = {
          ExecStart = "${cfg.package}/lib/nanokvm/kvm_system/kvm_system";
          Restart = "always";
          RestartSec = "2s";
          # Stock copies /kvmapp/kvm_system to /tmp and runs it from
          # there — that's an artifact of /kvmapp being squashfs on the
          # factory image (self-update replaces it at runtime). All of
          # the binary's file I/O is absolute-path (/etc/kvm, /tmp,
          # /kvmapp/kvm); it runs fine from the read-only store. Give
          # it a writable cwd anyway in case a library scribbles
          # relative to it.
          RuntimeDirectory = "nanokvm-kvm-system";
          WorkingDirectory = "%t/nanokvm-kvm-system";
        };
      };
    })

    (lib.mkIf cfg.server.enable {
      systemd.services.nanokvm-server = {
        description = "NanoKVM web server";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        # kvm_system is ordering-only (see its unit): a crash-looping
        # sidecar must not take the web server down with it.
        after =
          [ "network-online.target" ]
          ++ serverDependencyUnits
          ++ lib.optional cfg.kvmSystem.enable kvmSystemUnit;
        requires = serverDependencyUnits;

        path = with pkgs; [
          bash
          busybox
          coreutils
          findutils
          gnugrep
          gnused
          iproute2
          procps
          systemd
          util-linux
        ];

        environment = {
          HOME = "/root";
        };

        serviceConfig = {
          ExecStart = "${cfg.package}/bin/nanokvm-server";
          WorkingDirectory = "${cfg.package}/lib/nanokvm/server";
          Restart = "on-failure";
          RestartSec = "2s";
        };
      };
    })

    (lib.mkIf cfg.openFirewall {
      networking.firewall.allowedTCPPorts = [
        cfg.httpPort
        cfg.httpsPort
      ];
    })
  ]);
}
