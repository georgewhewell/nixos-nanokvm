# CDC-ECM (or RNDIS/NCM) + CDC-ACM composite USB gadget.
#
# The initrd can expose the network function for recovery/live images
# that need USB networking before root is mounted. Normal SD-card boots
# should leave initrd networking off and let stage 2 recreate the gadget;
# networkd then owns usb0 like every other stage-2 interface.
#
# `sg2002.usbGadget.network.transport` picks the framing. All three were
# measured on a LicheeRV Nano W at high-speed on 2026-09-19; none of them wedged.
#   - "ecm"   — vendor-neutral CDC-ECM, Linux `cdc_ether`. One frame per
#               bulk transfer. Default: simplest, and the fastest into
#               the board.
#   - "rndis" — Microsoft RNDIS, Linux `rndis_host`. No measured advantage
#               over ECM on Linux hosts; kept for Windows hosts.
#   - "ncm"   — CDC-NCM, Linux `cdc_ncm`. Several frames per 16 KiB bulk
#               transfer: fastest out of the board. (f_ncm's
#               max_segment_size knob was tried at 8000: ICMP of every
#               size crossed but TCP sessions stalled after ~10 KB, so it
#               is not exposed here.)
{
  config,
  lib,
  pkgs,
  ...
}: let
  protocol = import ../lib/protocol.nix;
  cfg = config.sg2002;
  gadgetCfg = cfg.usbGadget;
  networkEnable = gadgetCfg.network.enable;
  initrdNetworkEnable = gadgetCfg.initrd.network.enable;
  preserveInitrd = gadgetCfg.stage2.preserveInitrd;
  reenumerateCfg = gadgetCfg.stage2.reenumerateAfterBoot;
  rxGuardCfg = gadgetCfg.stage2.rxGuard;
  stage2NetworkControlFile = gadgetCfg.network.controlFile;
  stage2NetworkMayExist = networkEnable || stage2NetworkControlFile != null;
  reenumerateStage2 =
    gadgetCfg.stage2.enable
    && stage2NetworkMayExist
    && reenumerateCfg.enable;
  transport = gadgetCfg.network.transport;
  netFn = "${transport}.usb0"; # configfs path component
  addOtgFlip = cfg.kernel == "vendor";
  servicePath = with pkgs; [
    bash
    coreutils
    findutils
    gnugrep
  ];
  mkUsbRxGuard = import ../lib/sg2002-usb-rx-guard.nix { inherit lib; };
  rxGuardScript = pkgs.writeShellScript "sg2002-usb-rx-guard" (mkUsbRxGuard {
    busybox = "${pkgs.busybox}/bin/busybox";
    hostIp = protocol.hostIp;
    requireCarrier = true;
    initialDelaySec = 10;
  });

  mkSetup = setupNetwork: controlFile: resetController:
    let
      canSetupNetwork = setupNetwork || controlFile != null;
      initialWantNetwork =
        if setupNetwork
        then "1"
        else "0";
      controlFileCheck = lib.optionalString (controlFile != null) ''
        if [ -e ${lib.escapeShellArg controlFile} ]; then
          want_network=1
        else
          want_network=0
        fi
      '';
    in
    pkgs.writeShellScript "usb-gadget-setup-${if canSetupNetwork then transport else "acm"}" ''
    set -eu
    G=/sys/kernel/config/usb_gadget/sg2002
    want_network=${initialWantNetwork}
    ${controlFileCheck}

    for udc in /sys/kernel/config/usb_gadget/*/UDC; do
      [ -e "$udc" ] || continue
      printf '\n' > "$udc" 2>/dev/null || true
    done

    # Configfs detachment above is enough for normal function changes. Only
    # the initrd needs the heavier controller reset below.
    ${lib.optionalString resetController ''
    # Force a full dwc2 re-probe before the initrd claims the UDC. The kernel
    # inherits the USB controller from U-Boot's fastboot gadget, and on
    # SG2002 that handoff intermittently leaves the net function's data
    # path dead: enumeration and the ACM console keep working, but the
    # host sees `cdc_ether/cdc_ncm transmit queue 0 timed out` — zero
    # frames cross. A driver-level unbind/bind pulses the RST_USB reset
    # line and re-initialises the PHY (dwc2_lowlevel_hw_init); a
    # gadget-level "" > UDC only soft-resets the core and does not.
    # See sg2002.usbGadget.initrd.resetController.
    if [ -d /sys/bus/platform/drivers/dwc2 ]; then
      for udc0 in /sys/class/udc/*; do
        [ -e "$udc0" ] || continue
        n0="''${udc0##*/}"
        echo "$n0" > /sys/bus/platform/drivers/dwc2/unbind 2>/dev/null || true
        sleep 0.2
        echo "$n0" > /sys/bus/platform/drivers/dwc2/bind 2>/dev/null || true
      done
    fi
    ''}

    mkdir -p "$G"

    echo 0x1d6b > "$G/idVendor"
    echo 0x0104 > "$G/idProduct"
    echo 0x0100 > "$G/bcdDevice"
    echo 0x0200 > "$G/bcdUSB"

    mkdir -p "$G/strings/0x409"
    echo "${gadgetCfg.product}"      > "$G/strings/0x409/product"
    echo "${gadgetCfg.manufacturer}" > "$G/strings/0x409/manufacturer"
    echo "${gadgetCfg.serial}"       > "$G/strings/0x409/serialnumber"

    ${lib.optionalString canSetupNetwork ''
    if [ "$want_network" = 1 ]; then
      mkdir -p "$G/functions/${netFn}"
      echo ${protocol.targetMac} > "$G/functions/${netFn}/dev_addr"
      echo ${protocol.hostMac}   > "$G/functions/${netFn}/host_addr"
    fi
    ''}

    mkdir -p $G/functions/acm.GS0
    ${lib.optionalString gadgetCfg.console.enable ''
      # Route the kernel console to this ACM port when the kernel
      # exposes the configfs knob. Requires `console=ttyGS0,...`.
      if [ -e "$G/functions/acm.GS0/console" ]; then
        echo 1 > "$G/functions/acm.GS0/console"
      fi
    ''}

    mkdir -p $G/configs/c.1/strings/0x409
    if [ "$want_network" = 1 ]; then
      echo "${lib.toUpper transport} + ACM" > "$G/configs/c.1/strings/0x409/configuration"
    else
      echo "ACM" > "$G/configs/c.1/strings/0x409/configuration"
    fi
    echo 250 > "$G/configs/c.1/MaxPower"

    ${lib.optionalString canSetupNetwork ''
    if [ "$want_network" = 1 ]; then
      [ -e "$G/configs/c.1/${netFn}" ] || ln -s "$G/functions/${netFn}" "$G/configs/c.1/"
    fi
    ''}
    [ -e "$G/configs/c.1/acm.GS0" ] || ln -s $G/functions/acm.GS0 $G/configs/c.1/

    # Bind to the first available UDC (SG2002 has exactly one).
    # Poll for it — on the vendor kernel UDC registration is async
    # after the otg-flip service writes "device" to otg_role.
    for _ in $(seq 1 100); do
      udc=$(ls /sys/class/udc 2>/dev/null | head -n1)
      [ -n "$udc" ] && break
      sleep 0.05
    done
    if [ -z "$udc" ]; then
      echo "usb-gadget: no UDC under /sys/class/udc; dwc2 didn't register" >&2
      exit 1
    fi
    echo "$udc" > "$G/UDC"
  '';

  mkTeardown = canSetupNetwork:
    pkgs.writeShellScript "usb-gadget-teardown-${if canSetupNetwork then transport else "acm"}" ''
    set -eu
    G=/sys/kernel/config/usb_gadget/sg2002
    [ -d $G ] || exit 0
    echo "" > $G/UDC || true
    for fn in ecm.usb0 rndis.usb0 ncm.usb0 mass_storage.disk0; do
      rm -f "$G/configs/c.1/$fn"
    done
    rm -f $G/configs/c.1/acm.GS0
    rmdir $G/configs/c.1/strings/0x409 || true
    rmdir $G/configs/c.1               || true
    for fn in ecm.usb0 rndis.usb0 ncm.usb0 mass_storage.disk0; do
      rmdir "$G/functions/$fn" || true
    done
    ${lib.optionalString (!gadgetCfg.console.enable) ''
    rmdir $G/functions/acm.GS0         || true
    rmdir $G/strings/0x409             || true
    rmdir $G                           || true
    ''}
  '';

  reenumerateStage2Script = pkgs.writeShellScript "usb-gadget-reenumerate-stage2" ''
    set -eu
    G=/sys/kernel/config/usb_gadget/sg2002
    [ -d "$G" ] || exit 0

    udc="$(cat "$G/UDC" 2>/dev/null || true)"
    if [ -z "$udc" ]; then
      udc="$(ls /sys/class/udc 2>/dev/null | head -n1 || true)"
    fi
    [ -n "$udc" ] || exit 0

    printf '\n' > "$G/UDC" 2>/dev/null || true
    sleep 0.25
    echo "$udc" > "$G/UDC"
  '';

  setupInitrd = mkSetup initrdNetworkEnable null gadgetCfg.initrd.resetController;
  teardownInitrd = mkTeardown initrdNetworkEnable;
  # The initrd has already reset the controller. A second driver-level
  # unbind while ttyGS0 is the active console can wedge stage-2 sysinit and,
  # because this unit orders networkd, prevent both USB and Ethernet access.
  # A configfs UDC detach above is sufficient for changing the function set.
  setupStage2 = mkSetup networkEnable stage2NetworkControlFile false;
  teardownStage2 = mkTeardown stage2NetworkMayExist;

  otgFlip = pkgs.writeShellScript "usb-gadget-otg-flip" ''
    set -eu
    # Wait for the vendor cviusb otg_role node to appear, then flip
    # to device mode. This must finish BEFORE the gadget setup runs
    # because the dwc2 dual-role driver only registers a UDC node
    # under /sys/class/udc once it's actually in peripheral mode.
    for _ in $(seq 1 20); do
      if [ -e /proc/cviusb/otg_role ]; then
        echo device > /proc/cviusb/otg_role
        # UDC registration is asynchronous after the role flip; wait
        # for it so the gadget service that follows doesn't race.
        for _ in $(seq 1 50); do
          if [ -n "$(ls /sys/class/udc 2>/dev/null)" ]; then
            exit 0
          fi
          sleep 0.05
        done
        exit 0
      fi
      sleep 0.1
    done
    exit 1
  '';

  mkServiceDef = setup: teardown: {
    description = "Bring up CDC-ECM + CDC-ACM composite USB gadget";
    wantedBy = ["initrd.target"];
    before = ["network-pre.target"];
    wants = ["network-pre.target"]
      ++ lib.optional addOtgFlip "usb-gadget-otg-flip.service";
    after = ["sys-kernel-config.mount"]
      ++ lib.optional addOtgFlip "usb-gadget-otg-flip.service";
    # Don't `Requires=` otg-flip — that flip only matters on vendor
    # kernels where dwc2 starts in OTG mode. If it's skipped (mainline
    # kernel, or vendor kernel where dr_mode=peripheral was honored at
    # probe time), usb-gadget should still try: the setup script polls
    # /sys/class/udc and only fails if no UDC ever appears.
    #
    # Also no ConditionPathExists=/sys/class/udc here — on the vendor
    # kernel UDC appears after otg-flip, so the condition would be
    # racy at unit-evaluation time.
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = setup;
      ExecStop = teardown;
    };
    path = servicePath;
  };

  otgDef = {
    description = "Flip vendor dwc2 OTG role to device (must run before usb-gadget)";
    wantedBy = ["initrd.target"];
    after = ["sys-kernel-config.mount"];
    before = ["usb-gadget.service"];
    unitConfig.ConditionPathExists = "/proc/cviusb/otg_role";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = otgFlip;
    };
  };

  mkNetworks = enable:
    lib.optionalAttrs enable {
    "40-usb0" = {
      matchConfig.MACAddress = protocol.targetMac;
      address = ["${protocol.targetIp}/${protocol.prefix}"];
      networkConfig = {
        ConfigureWithoutCarrier = true;
        LinkLocalAddressing = "no";
      };
      linkConfig.RequiredForOnline = "no";
    };
  };

  initrdServiceDef = mkServiceDef setupInitrd teardownInitrd;
  stage2ServiceDef = mkServiceDef setupStage2 teardownStage2;
  preservedInitrdServiceDef = initrdServiceDef // {
    unitConfig = (initrdServiceDef.unitConfig or {}) // {
      IgnoreOnIsolate = true;
      RefuseManualStop = true;
      SurviveFinalKillSignal = true;
    };
    serviceConfig = initrdServiceDef.serviceConfig // {
      ExecStop = lib.mkForce [ "" ];
    };
  };
  preservedStage2ServiceDef = {
    description = "Preserve the initrd SG2002 USB gadget across switch-root";
    wantedBy = [ "sysinit.target" ];
    before = [
      "sysinit.target"
      "network-pre.target"
      "systemd-networkd.service"
    ];
    after = [ "sys-kernel-config.mount" ];
    requires = [ "sys-kernel-config.mount" ];
    unitConfig = {
      DefaultDependencies = false;
      IgnoreOnIsolate = true;
      RefuseManualStop = true;
      SurviveFinalKillSignal = true;
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.coreutils}/bin/true";
      ExecStop = lib.mkForce [ "" ];
    };
  };
  initrdNetworksDef = mkNetworks initrdNetworkEnable;
  stage2NetworksDef = mkNetworks stage2NetworkMayExist;
in {
  imports = [./sg2002-usb-gadget-options.nix];

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = !preserveInitrd || (
            gadgetCfg.stage2.enable
            && gadgetCfg.network.controlFile == null
            && initrdNetworkEnable == networkEnable
            && !reenumerateCfg.enable
          );
          message = ''
            sg2002.usbGadget.stage2.preserveInitrd requires stage 2,
            identical initrd/stage-2 network functions, no controlFile, and
            reenumerateAfterBoot disabled
          '';
        }
        {
          assertion = !rxGuardCfg.enable || (
            gadgetCfg.stage2.enable
            && stage2NetworkMayExist
          );
          message = ''
            sg2002.usbGadget.stage2.rxGuard requires a stage-2 USB gadget
            with a possible network function
          '';
        }
      ];

      sg2002.initrd.pruneKernelModules = true;
      sg2002.initrd.availableKernelModules = [
        "libcomposite"
        "usb_f_acm"
        "configfs"
      ] ++ lib.optional initrdNetworkEnable "usb_f_${transport}";
      sg2002.initrd.kernelModules = ["libcomposite"];

      boot.initrd.systemd = {
        services.usb-gadget =
          if preserveInitrd
          then preservedInitrdServiceDef
          else initrdServiceDef;
        network.networks = initrdNetworksDef;
        storePaths = [setupInitrd teardownInitrd];
      };

      systemd = lib.mkIf gadgetCfg.stage2.enable {
        services = {
          usb-gadget = if preserveInitrd then preservedStage2ServiceDef else stage2ServiceDef // {
            # Recreate the ACM console and optional usb0 before normal
            # stage-2 boot proceeds. If this waits until multi-user.target,
            # networkd has already passed network-pre.target and the USB
            # console is unavailable for early stage-2 failures.
            wantedBy = ["sysinit.target"];
            before = [
              "sysinit.target"
              "network-pre.target"
              "systemd-networkd.service"
            ];
            wants = lib.optional addOtgFlip "usb-gadget-otg-flip.service";
            after = ["sys-kernel-config.mount"];
            requires = ["sys-kernel-config.mount"];
            restartIfChanged = false;
            stopIfChanged = false;
            unitConfig.DefaultDependencies = false;
          };
          usb-rx-guard = lib.mkIf rxGuardCfg.enable {
            description = "Recover a stalled SG2002 USB gadget RX path";
            wantedBy = [ "multi-user.target" ];
            after = [ "usb-gadget.service" "systemd-networkd.service" ];
            wants = [ "usb-gadget.service" "systemd-networkd.service" ];
            serviceConfig = {
              Type = "simple";
              ExecStart = rxGuardScript;
              Restart = "always";
              RestartSec = "1s";
            };
          };
        } // lib.optionalAttrs reenumerateStage2 {
          usb-gadget-reenumerate = {
            description = "Re-enumerate SG2002 stage-2 USB gadget";
            after = ["usb-gadget.service"];
            wants = ["usb-gadget.service"];
            serviceConfig = {
              Type = "oneshot";
              ExecStart = reenumerateStage2Script;
            };
          };
        };
        timers = lib.mkIf reenumerateStage2 {
          usb-gadget-reenumerate = {
            description = "Delayed SG2002 USB gadget re-enumeration";
            wantedBy = ["timers.target"];
            timerConfig = {
              OnBootSec = "${toString reenumerateCfg.delaySec}s";
              AccuracySec = "5s";
              Unit = "usb-gadget-reenumerate.service";
            };
          };
        };
        network = {
          enable = lib.mkIf stage2NetworkMayExist true;
          networks = stage2NetworksDef;
        };
      };
    }

    (lib.mkIf addOtgFlip {
      boot.initrd.systemd = {
        services."usb-gadget-otg-flip" = otgDef;
        storePaths = [otgFlip];
      };
    })
  ];
}
