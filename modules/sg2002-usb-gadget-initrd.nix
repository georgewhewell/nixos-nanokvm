# CDC-ECM (or RNDIS) + CDC-ACM composite USB gadget, brought up from
# the systemd initrd. Pair with includes/usb-recovery.nix or
# includes/usb-live.nix (anything that keeps the gadget service alive
# in stage-1).
#
# net/usb0 gets a static IP on 10.55.0.1/24; ACM exposes /dev/ttyGS0.
# When `sg2002.usbGadget.network.enable = false`, the net function is
# dropped and ACM is left alone — lets the kernel route console output
# to the ACM port when combined with `console=ttyGS0,…` on the cmdline.
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
  transport = gadgetCfg.network.transport;
  netFn = "${transport}.usb0"; # configfs path component
  addOtgFlip = cfg.kernel == "vendor";

  setup = pkgs.writeShellScript "usb-gadget-setup-initrd" ''
    set -eu
    G=/sys/kernel/config/usb_gadget/sg2002
    mkdir -p $G

    echo 0x1d6b > $G/idVendor
    echo 0x0104 > $G/idProduct
    echo 0x0100 > $G/bcdDevice
    echo 0x0200 > $G/bcdUSB

    mkdir -p $G/strings/0x409
    echo "LicheeRV Nano (NixOS)" > $G/strings/0x409/product
    echo "Sipeed"                > $G/strings/0x409/manufacturer
    echo "sg2002-0001"           > $G/strings/0x409/serialnumber

    ${lib.optionalString networkEnable ''
      mkdir -p "$G/functions/${netFn}"
      echo ${protocol.targetMac} > "$G/functions/${netFn}/dev_addr"
      echo ${protocol.hostMac}   > "$G/functions/${netFn}/host_addr"
    ''}

    mkdir -p $G/functions/acm.GS0
    ${lib.optionalString (!networkEnable) ''
      # Diagnostic mode: route the kernel console to this ACM port.
      # Requires CONFIG_U_SERIAL_CONSOLE=y and `console=ttyGS0,…` on
      # the kernel cmdline.
      echo 1 > $G/functions/acm.GS0/console
    ''}

    mkdir -p $G/configs/c.1/strings/0x409
    echo "${
      if networkEnable
      then "${lib.toUpper transport} + ACM"
      else "ACM"
    }" \
      > $G/configs/c.1/strings/0x409/configuration
    echo 250 > $G/configs/c.1/MaxPower

    ${lib.optionalString networkEnable ''ln -s "$G/functions/${netFn}" "$G/configs/c.1/"''}
    ln -s $G/functions/acm.GS0 $G/configs/c.1/

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

  teardown = pkgs.writeShellScript "usb-gadget-teardown-initrd" ''
    set -eu
    G=/sys/kernel/config/usb_gadget/sg2002
    [ -d $G ] || exit 0
    echo "" > $G/UDC || true
    ${lib.optionalString networkEnable ''rm -f "$G/configs/c.1/${netFn}"''}
    rm -f $G/configs/c.1/acm.GS0
    rmdir $G/configs/c.1/strings/0x409 || true
    rmdir $G/configs/c.1               || true
    ${lib.optionalString networkEnable ''rmdir "$G/functions/${netFn}" || true''}
    rmdir $G/functions/acm.GS0         || true
    rmdir $G/strings/0x409             || true
    rmdir $G                           || true
  '';

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

  serviceDef = {
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

  networksDef = lib.optionalAttrs networkEnable {
    "40-usb0" = {
      matchConfig.Name = "usb0";
      address = ["${protocol.targetIp}/${protocol.prefix}"];
      networkConfig.LinkLocalAddressing = "no";
    };
  };
in {
  options.sg2002.usbGadget.network = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Include a network function in the gadget. When disabled, only the ACM serial function is exposed — useful for bare-console diagnostic boots.";
    };
    transport = lib.mkOption {
      type = lib.types.enum ["ecm" "rndis" "ncm"];
      default = "ecm";
      description = ''
        USB framing protocol for the gadget's network function. All
        three use the same `dev_addr`/`host_addr` configfs surface;
        only the function-driver and frame format differ.

        - "ecm": CDC-ECM (vendor-neutral, vanilla). Linux host binds
          `cdc_ether`. One Ethernet frame per USB bulk transfer.
        - "rndis": Microsoft RNDIS. Linux host binds `rndis_host`.
          Microsoft-style message framing; different f_*-driver code
          path in dwc2 than ECM.
        - "ncm": CDC-NCM (Network Control Model). Linux host binds
          `cdc_ncm`. Aggregates multiple Ethernet frames per USB
          transfer (NDP — Network Datagram Pointer block). Lowest
          per-frame overhead of the three for high-throughput
          traffic.

        Try all three under NBD load; the answer's empirical.
      '';
    };
  };

  config = lib.mkMerge [
    {
      boot.initrd.availableKernelModules = lib.mkForce [
        "libcomposite"
        "usb_f_${transport}"
        "usb_f_acm"
        "configfs"
      ];
      boot.initrd.kernelModules = lib.mkForce ["libcomposite"];

      boot.initrd.systemd = {
        services.usb-gadget = serviceDef;
        network.networks = networksDef;
        storePaths = [setup teardown];
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
