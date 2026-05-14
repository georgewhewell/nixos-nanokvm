# Wired ethernet mixin for the NanoKVM-PCIe carrier board. Brings up
# `eth0` on the CV-DWMAC controller (`ethernet@4070000`, driver
# `bm-dwmac`) and configures networkd to DHCP it. Vendor firmware
# defaults to a static `192.168.23.17/24`; we let networkd negotiate
# instead so the device fits any LAN.
#
# To use: imports = [ ./modules/ethernet-bm-dwmac.nix ];
# To not use: simply don't import (e.g. the LicheeRV-Nano-W dev board).
{lib, ...}: {
  # bm-dwmac is built into the vendor kernel; mainline support is TBD
  # (kernel patch will be needed before this works on mainline). The
  # PCIe board is normally booted with the vendor kernel anyway.
  boot.kernelModules = ["bm-dwmac"];

  systemd.network = {
    enable = true;
    networks."20-eth0" = {
      matchConfig.Name = "eth0";
      networkConfig = {
        DHCP = "yes";
        IPv6AcceptRA = true;
      };
      linkConfig.RequiredForOnline = "no";
    };
  };
}
