# Shared USB control plane for the NanoKVM USB-boot targets.
#
# Owns:
#   * networkd "40-usb0" matching the gadget MAC (initrd and stage-2)
#   * configureUsbNetwork — belt-and-suspenders address fixup
#   * acmStatus — one-shot initrd status block to /dev/ttyGS0
#   * debug shell on TCP/2323 (initrd BusyBox, stage-2 login shell)
#
# The kexec subsystem (request socket on TCP/2325, agent, payload mount,
# prepare-kexec-stage) used to live here too — now in
# ./control-plane/kexec.nix, imported via the `imports` list below.
{ config
, lib
, pkgs
, ...
}:
let
  cfg = config.nanokvm.usbControl;

  # Shared helpers: protocol, kernel-dependent target tool list,
  # shellLib bash prelude, mkTargetScript builder.
  targetLib = import ./control-plane/target-script-lib.nix {
    inherit lib pkgs config;
  };
  inherit (targetLib) targetTools kernelIsMainline mkTargetScript protocol;

  configureUsbNetwork = mkTargetScript "nanokvm-configure-usb-network" ''
    log() {
      printf 'nanokvm-usb-network: %s\n' "$*" >/dev/kmsg 2>/dev/null || true
      printf '%s\n' "$*"
    }

    iface="$(nanokvm_wait_iface "$nanokvm_target_mac" 30)" || {
      log "no non-loopback network interface appeared"
      ip addr show || true
      exit 1
    }

    ip link set "$iface" up || true
    ip addr replace "$nanokvm_target_ip/$nanokvm_prefix" dev "$iface" || true
    ip addr show "$iface" || true
    log "configured $iface as $nanokvm_target_ip/$nanokvm_prefix"
  '';

  acmStatus = mkTargetScript "nanokvm-acm-status" ''
    for _ in $(seq 1 50); do
      [ -e /dev/ttyGS0 ] && break
      sleep 0.1
    done
    [ -e /dev/ttyGS0 ] || exit 0

    sleep 2
    {
      echo
      echo "===== nanokvm initrd status ====="
      echo "--- cmdline"; cat /proc/cmdline 2>&1 || true
      echo "--- links"; ip link show 2>&1 || true
      echo "--- addresses"; ip addr show 2>&1 || true
      echo "--- routes"; ip route show 2>&1 || true
      echo "===== end nanokvm initrd status ====="
      echo
    } >/dev/ttyGS0 2>&1 || true
  '';

  # The 40-usb0 networkd config, identical for initrd and stage-2.
  usbNetwork = {
    matchConfig = {
      MACAddress = protocol.targetMac;
    };
    address = [ "${protocol.targetIp}/${protocol.prefix}" ];
    networkConfig = {
      KeepConfiguration = "static";
      LinkLocalAddressing = "no";
    };
  };

  initrdDebugShellExec = "${pkgs.busybox}/bin/telnetd -F -b ${protocol.targetIp}:${toString protocol.ports.debugShell} -l ${pkgs.busybox}/bin/sh";
  stage2DebugShell = pkgs.writeShellScript "nanokvm-stage2-debug-shell" ''
    export PATH=/run/current-system/sw/bin:/run/wrappers/bin:$PATH
    export TERM="''${TERM:-linux}"
    user=${lib.escapeShellArg cfg.stage2ShellUser}
    cd / 2>/dev/null || true

    if getent passwd "$user" >/dev/null 2>&1 && [ -x /run/wrappers/bin/su ]; then
      exec /run/wrappers/bin/su -l "$user"
    fi

    if [ -x /run/wrappers/bin/su ]; then
      exec /run/wrappers/bin/su -l root
    fi

    root_shell="$(getent passwd root 2>/dev/null | cut -d: -f7 || true)"
    [ -n "$root_shell" ] || root_shell=/run/current-system/sw/bin/sh
    exec "$root_shell" -l
  '';
  stage2DebugShellExec = "${pkgs.busybox}/bin/telnetd -F -b ${protocol.targetIp}:${toString protocol.ports.debugShell} -l ${stage2DebugShell}";
in
{
  imports = [
    ./control-plane/inert-initrd.nix
    ./control-plane/kexec.nix
  ];

  options.nanokvm.usbControl = with lib; {
    initrd.enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Expose the USB control plane (kexec, debug shell, networkd,
        ACM status) from the initrd. Pretty much every USB target
        wants this on; turn it off only for specialty configurations
        that bring up the gadget themselves.
      '';
    };

    stage2.enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Expose the USB control plane (kexec, debug shell, networkd)
        from stage 2 as well. Required for kexec-out-of-stage-2;
        the corresponding initrd flag handles the initrd side.
      '';
    };

    stage2ShellUser = mkOption {
      type = types.str;
      default = "root";
      description = ''
        User account entered by the stage-2 TCP debug shell. The initrd
        debug shell remains BusyBox root because it runs before the
        NixOS account database exists.
      '';
    };

    kexec.enable = mkOption {
      type = types.bool;
      default = kernelIsMainline;
      description = ''
        Wire up the kexec control socket, request parser, and agent.

        Off by default on the vendor kernel because the target closure
        omits kexec-tools and nbd-client-minimal there (the vendor
        kernel-test path doesn't support kexec at all). Leaving the
        socket up on vendor systems creates a false-positive control
        plane: the parser ACKs the request, then the agent immediately
        fails to find the kexec binary.

        When false, the debug shell, networkd, and ACM status path stay
        as before — only the kexec endpoint disappears.
      '';
    };

    # `inertSwitchRoot.enable` option is defined in
    # ./control-plane/inert-initrd.nix.
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.initrd.enable {
      sg2002.usbGadget.network.enable = true;

      # USB-booted variants are loaded by U-Boot from a FIT and have no
      # disk to install a bootloader on. Suppress both bootloader paths
      # so eval doesn't insist on a target device.
      boot.loader.grub.enable = lib.mkForce false;
      boot.loader.generic-extlinux-compatible.enable = lib.mkForce false;

      boot.initrd.compressor = "zstd";
      boot.initrd.compressorArgs = [ "-19" "-T0" ];
      boot.initrd.network.enable = lib.mkForce false;
      boot.initrd.services.bcache.enable = lib.mkForce false;
      boot.initrd.services.lvm.enable = lib.mkForce false;
      boot.initrd.services.resolved.enable = lib.mkForce false;

      boot.initrd.systemd = {
        enable = true;
        emergencyAccess = false;

        dbus.enable = lib.mkForce false;
        fido2.enable = lib.mkForce false;
        tpm2.enable = lib.mkForce false;

        network = {
          enable = true;
          networks."40-usb0" = {
            matchConfig = lib.mkForce usbNetwork.matchConfig;
            address = lib.mkForce usbNetwork.address;
            inherit (usbNetwork) networkConfig;
          };
        };

        settings.Manager = {
          RuntimeWatchdogSec = "30s";
          RebootWatchdogSec = "off";
          KExecWatchdogSec = "off";
          DefaultTimeoutStartSec = "infinity";
          DefaultTimeoutStopSec = "infinity";
          DefaultTimeoutAbortSec = "infinity";
          DefaultDeviceTimeoutSec = "infinity";
        };

        services = {
          "usb-debug-network" = {
            description = "Configure the USB debug network";
            wantedBy = [ "initrd.target" ];
            after = [ "usb-gadget.service" ];
            wants = [ "usb-gadget.service" ];
            unitConfig.DefaultDependencies = false;
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = configureUsbNetwork;
            };
          };

          "usb-debug-shell" = {
            description = "Root shell on the USB debug network";
            wantedBy = [ "initrd.target" ];
            after = [
              "usb-debug-network.service"
              "systemd-networkd.service"
              "usb-gadget.service"
            ];
            wants = [
              "usb-debug-network.service"
              "systemd-networkd.service"
              "usb-gadget.service"
            ];
            unitConfig.DefaultDependencies = false;
            serviceConfig = {
              ExecStart = initrdDebugShellExec;
              Restart = "always";
              RestartSec = "1s";
            };
          };

          "usb-debug-acm-status" = {
            description = "Print one NanoKVM initrd status block on USB ACM";
            wantedBy = [ "initrd.target" ];
            after = [
              "usb-debug-network.service"
              "usb-gadget.service"
            ];
            wants = [
              "usb-debug-network.service"
              "usb-gadget.service"
            ];
            unitConfig.DefaultDependencies = false;
            serviceConfig = {
              Type = "oneshot";
              ExecStart = acmStatus;
            };
          };
        };

        # kexec socket + agent live in modules/control-plane/kexec.nix
        # (imported above). It contributes its own services/sockets/
        # storePaths under the same `boot.initrd.systemd` namespace.

        storePaths = [
          configureUsbNetwork
          acmStatus
          pkgs.busybox
        ];
      };
    })

    (lib.mkIf cfg.stage2.enable {
      systemd.network = {
        enable = true;
        networks."40-usb0" = usbNetwork;
      };

      # Only allow the debug shell port on the USB iface. The kexec
      # module adds protocol.ports.kexecCtrl to the same list when it's
      # enabled.
      networking.firewall.interfaces.usb0.allowedTCPPorts = [
        protocol.ports.debugShell
      ];

      systemd.services."usb-debug-shell" = {
        description = "User shell on the USB debug network";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ]
          ++ lib.optional config.services.userborn.enable "userborn.service";
        wants = [ "network-online.target" ]
          ++ lib.optional config.services.userborn.enable "userborn.service";
        serviceConfig = {
          ExecStart = stage2DebugShellExec;
          Restart = "always";
          RestartSec = "1s";
        };
      };
    })
  ];
}
