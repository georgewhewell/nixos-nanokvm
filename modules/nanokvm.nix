{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.nanokvm;
  compatUnit = "nanokvm-compat.service";
  yaml = pkgs.formats.yaml {};
  kmodsUnit = "nanokvm-kmods.service";
  usbGadgetUnit = "nanokvm-usb-gadget.service";
  serverDependencyUnits =
    [compatUnit]
    ++ lib.optional cfg.kmods.enable kmodsUnit
    ++ lib.optional cfg.usbGadget.enable usbGadgetUnit;

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
    mkdir -p /etc/kvm /etc/init.d /boot /data /kvmapp/kvm

    if [ ! -e /etc/kvm/server.yaml ]; then
      cp ${serverConfig} /etc/kvm/server.yaml
      chmod 0644 /etc/kvm/server.yaml
    fi

    printf '%s\n' ${lib.escapeShellArg cfg.hardwareVersion} > /etc/kvm/hw
    printf '%s\n' ${lib.escapeShellArg cfg.hdmiVersion} > /etc/kvm/hdmi_version

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
in {
  options.services.nanokvm = with lib; {
    enable = mkEnableOption "Sipeed NanoKVM server";

    package = mkOption {
      type = types.package;
      default = pkgs.buildPackages.nanokvm-server or pkgs.nanokvm-server;
      defaultText = literalExpression "pkgs.buildPackages.nanokvm-server";
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
      type = types.enum ["enable" "disable"];
      default = "enable";
      description = "NanoKVM application authentication setting.";
    };

    logLevel = mkOption {
      type = types.enum ["debug" "info" "warn" "error"];
      default = "info";
      description = "NanoKVM server log level.";
    };

    hardwareVersion = mkOption {
      type = types.enum ["alpha" "beta" "pcie"];
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
        for explicit allow rules. Tracked in PLAN.md as t7.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      boot.kernelModules = lib.mkIf cfg.usbGadget.enable ["libcomposite"];

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
        wantedBy = ["multi-user.target"];
        before = ["nanokvm-server.service"] ++ lib.optional cfg.usbGadget.enable usbGadgetUnit;
        after = ["systemd-tmpfiles-setup.service"];

        path = with pkgs; [
          coreutils
        ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };

        script = activation;
      };

      systemd.services.nanokvm-kmods = lib.mkIf cfg.kmods.enable {
        description = "NanoKVM Sophgo multimedia kernel modules";
        wantedBy = ["multi-user.target"];
        before = [
          "nanokvm-server.service"
        ] ++ lib.optional cfg.usbGadget.enable usbGadgetUnit;
        after = ["systemd-modules-load.service"];

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

      systemd.services.nanokvm-usb-gadget = lib.mkIf cfg.usbGadget.enable {
        description = "NanoKVM USB composite gadget";
        wantedBy = ["multi-user.target"];
        before = ["nanokvm-server.service"];
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

      systemd.services.nanokvm-server = {
        description = "NanoKVM web server";
        wantedBy = ["multi-user.target"];
        wants = ["network-online.target"];
        after = ["network-online.target"] ++ serverDependencyUnits;
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
    }

    (lib.mkIf cfg.openFirewall {
      networking.firewall.allowedTCPPorts = [
        cfg.httpPort
        cfg.httpsPort
      ];
    })
  ]);
}
