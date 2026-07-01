# CDC-ECM (or RNDIS/NCM) + CDC-ACM composite USB gadget.
#
# The initrd can expose the network function for recovery/live images
# that need USB networking before root is mounted. Normal SD-card boots
# should leave initrd networking off and let stage 2 recreate the gadget;
# networkd then owns usb0 like every other stage-2 interface.
#
# `sg2002.usbGadget.network.transport` picks the framing:
#   - "ecm"   — vendor-neutral CDC-ECM. Linux `cdc_ether` driver. Vanilla
#               and simple; what we used historically.
#   - "rndis" — Microsoft RNDIS. Linux `rndis_host` driver. Different
#               code path in dwc2 + the f_*. Worth A/B-ing under NBD
#               throughput because vendor 5.10's `f_ecm` has known
#               transmit-queue stalls.
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
  transport = gadgetCfg.network.transport;
  netFn = "${transport}.usb0"; # configfs path component
  addOtgFlip = cfg.kernel == "vendor";
  servicePath = with pkgs; [
    bash
    coreutils
    findutils
    gnugrep
  ];

  mkSetup = setupNetwork:
    pkgs.writeShellScript "usb-gadget-setup-${if setupNetwork then transport else "acm"}" ''
    set -eu
    G=/sys/kernel/config/usb_gadget/sg2002

    for udc in /sys/kernel/config/usb_gadget/*/UDC; do
      [ -e "$udc" ] || continue
      printf '\n' > "$udc" 2>/dev/null || true
    done

    mkdir -p $G

    echo 0x1d6b > $G/idVendor
    echo 0x0104 > $G/idProduct
    echo 0x0100 > $G/bcdDevice
    echo 0x0200 > $G/bcdUSB

    mkdir -p $G/strings/0x409
    echo "${gadgetCfg.product}"      > $G/strings/0x409/product
    echo "${gadgetCfg.manufacturer}" > $G/strings/0x409/manufacturer
    echo "${gadgetCfg.serial}"       > $G/strings/0x409/serialnumber

    ${lib.optionalString setupNetwork ''
      mkdir -p "$G/functions/${netFn}"
      echo ${protocol.targetMac} > "$G/functions/${netFn}/dev_addr"
      echo ${protocol.hostMac}   > "$G/functions/${netFn}/host_addr"
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
    echo "${
      if setupNetwork
      then "${lib.toUpper transport} + ACM"
      else "ACM"
    }" \
      > $G/configs/c.1/strings/0x409/configuration
    echo 250 > $G/configs/c.1/MaxPower

    ${lib.optionalString setupNetwork ''[ -e "$G/configs/c.1/${netFn}" ] || ln -s "$G/functions/${netFn}" "$G/configs/c.1/"''}
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
    echo "$udc" > $G/UDC
  '';

  mkTeardown = setupNetwork:
    pkgs.writeShellScript "usb-gadget-teardown-${if setupNetwork then transport else "acm"}" ''
    set -eu
    G=/sys/kernel/config/usb_gadget/sg2002
    [ -d $G ] || exit 0
    echo "" > $G/UDC || true
    ${lib.optionalString setupNetwork ''rm -f "$G/configs/c.1/${netFn}"''}
    rm -f $G/configs/c.1/acm.GS0
    rmdir $G/configs/c.1/strings/0x409 || true
    rmdir $G/configs/c.1               || true
    ${lib.optionalString setupNetwork ''rmdir "$G/functions/${netFn}" || true''}
    rmdir $G/functions/acm.GS0         || true
    rmdir $G/strings/0x409             || true
    rmdir $G                           || true
  '';

  setupInitrd = mkSetup initrdNetworkEnable;
  teardownInitrd = mkTeardown initrdNetworkEnable;
  setupStage2 = mkSetup networkEnable;
  teardownStage2 = mkTeardown networkEnable;

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
  initrdNetworksDef = mkNetworks initrdNetworkEnable;
  stage2NetworksDef = mkNetworks networkEnable;
in {
  imports = [./sg2002-usb-gadget-options.nix];

  config = lib.mkMerge [
    {
      sg2002.initrd.pruneKernelModules = true;
      sg2002.initrd.availableKernelModules = [
        "libcomposite"
        "usb_f_acm"
        "configfs"
      ] ++ lib.optional initrdNetworkEnable "usb_f_${transport}";
      sg2002.initrd.kernelModules = ["libcomposite"];

      boot.initrd.systemd = {
        services.usb-gadget = initrdServiceDef;
        network.networks = initrdNetworksDef;
        storePaths = [setupInitrd teardownInitrd];
      };

      systemd = lib.mkIf gadgetCfg.stage2.enable {
        services = {
          usb-gadget = stage2ServiceDef // {
            wantedBy = ["multi-user.target"];
            before = ["network-pre.target"];
            wants = ["network-pre.target"];
            after = ["sys-kernel-config.mount"];
          };
        };
        network = {
          enable = lib.mkIf networkEnable true;
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
