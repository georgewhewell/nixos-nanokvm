{
  config,
  lib,
  ...
}: {
  options.sg2002.usbGadget = {
    product = lib.mkOption {
      type = lib.types.str;
      default = "Sipeed SG2002 (NixOS)";
      description = "USB gadget iProduct string (board-specific; e.g. \"Sipeed NanoKVM-PCIe (NixOS)\").";
    };
    manufacturer = lib.mkOption {
      type = lib.types.str;
      default = "Sipeed";
      description = "USB gadget iManufacturer string.";
    };
    serial = lib.mkOption {
      type = lib.types.str;
      default = "sg2002-0001";
      description = "USB gadget iSerialNumber string.";
    };
    console.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Route the kernel console to the ACM function when CONFIG_U_SERIAL_CONSOLE is available.";
    };
  };

  options.sg2002.usbGadget.network = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Include a network function in the gadget. When disabled, only the ACM serial function is exposed -- useful for bare-console diagnostic boots.";
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
          Microsoft-style message framing; needed for Windows hosts
          without a CDC driver.
        - "ncm": CDC-NCM (Network Control Model). Linux host binds
          `cdc_ncm`. Aggregates multiple Ethernet frames per 16 KiB
          USB transfer.

        Measured on a LicheeRV Nano W at high-speed with the shipped
        kernel and FIFO layout, 20 s iperf3 TCP runs, single samples,
        board CPU saturated in every case: host->board ECM 222,
        NCM 231 Mbit/s; board->host ECM 188, NCM 261 Mbit/s. RNDIS was
        only measured before the RX-buffer patch and FIFO change (191
        and 134 Mbit/s). ECM remains the default; pick NCM when traffic
        is mostly out of the board.
      '';
    };
    controlFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional stage-2 runtime flag file. When set, the stage-2
        gadget includes the network function only while this file
        exists. This is intended for compatibility with user-space UI
        toggles; initrd gadgets remain fully declarative.
      '';
    };
  };

  options.sg2002.usbGadget.initrd.network.enable = lib.mkOption {
    type = lib.types.bool;
    default = config.sg2002.usbGadget.network.enable;
    defaultText = lib.literalExpression "config.sg2002.usbGadget.network.enable";
    description = "Include the network function in the initrd gadget. Disable this for normal SD boots where stage 2 owns USB networking.";
  };

  options.sg2002.usbGadget.initrd.resetController = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      Unbind and rebind the dwc2 platform driver before the initrd claims
      the UDC. Unlike a configfs detach or the core's own soft reset, a
      driver rebind pulses the RST_USB reset line and re-initialises the
      PHY, which is what recovers a controller inherited from U-Boot's
      fastboot gadget with a dead bulk-OUT path. Only disable this for
      handoff experiments.
    '';
  };

  options.sg2002.usbGadget.stage2.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Bring up the SG2002 debug USB gadget again in stage 2.";
  };

  options.sg2002.usbGadget.stage2.preserveInitrd = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Keep an identical initrd gadget bound across switch-root instead of
      detaching and recreating it. This avoids dropping an active ACM kernel
      console and requires the initrd and stage 2 to expose the same function
      set without a runtime network control file.
    '';
  };

  options.sg2002.usbGadget.stage2.rxGuard.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Safety net: probe the USB host and re-probe the dwc2 controller
      after two transmitted probes make no receive progress (the
      signature of a dead bulk-OUT path). The guard stays idle while
      USB has no carrier. The 2026-09-19 validation did not reproduce
      the wedge at runtime on a LicheeRV Nano W with the current kernel
      and DT; the guard is kept for carriers and hosts that have not
      been soaked.
    '';
  };

  options.sg2002.usbGadget.stage2.reenumerateAfterBoot = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Restart the stage-2 gadget once after boot. Some SG2002 dwc2
        hosts enumerate the initial stage-2 ECM function but leave the
        link without carrier until the gadget is rebound.
      '';
    };
    delaySec = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
      description = "Seconds after boot before the one-shot stage-2 gadget re-enumeration.";
    };
  };
}
