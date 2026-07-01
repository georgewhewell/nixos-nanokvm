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
          Microsoft-style message framing; different f_*-driver code
          path in dwc2 than ECM.
        - "ncm": CDC-NCM (Network Control Model). Linux host binds
          `cdc_ncm`. Aggregates multiple Ethernet frames per USB
          transfer (NDP -- Network Datagram Pointer block). Lowest
          per-frame overhead of the three for high-throughput
          traffic.

        Try all three under NBD load; the answer's empirical.
      '';
    };
  };

  options.sg2002.usbGadget.initrd.network.enable = lib.mkOption {
    type = lib.types.bool;
    default = config.sg2002.usbGadget.network.enable;
    defaultText = lib.literalExpression "config.sg2002.usbGadget.network.enable";
    description = "Include the network function in the initrd gadget. Disable this for normal SD boots where stage 2 owns USB networking.";
  };

  options.sg2002.usbGadget.stage2.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Bring up the SG2002 debug USB gadget again in stage 2.";
  };
}
