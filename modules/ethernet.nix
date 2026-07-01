# Wired ethernet for the NanoKVM-PCIe carrier: brings up `eth0` (DHCP
# via networkd). The SG2002 GMAC sits at ethernet@4070000; how it's
# driven depends on the kernel:
#
#   - vendor 5.10: the GMAC glue is built into the kernel image
#     (CONFIG_STMMAC_ETH=y, dwmac-cvitek in modules.builtin) and the
#     vendor DTS enables the node — nothing to load.
#   - mainline: the upstream stmmac stack + `dwmac-sophgo` glue, bound
#     via the PCIe DTB which flips ethernet@4070000 (and its internal-
#     EPHY mdio-mux) to `okay`. Select that DTB here.
#
# To use:  imports = [ ./modules/ethernet.nix ];
# To not:  simply don't import (e.g. the LicheeRV-Nano-W dev board).
{
  config,
  lib,
  pkgs,
  ...
}: let
  mainline = config.sg2002.kernel == "mainline";
  # Only mainline drives the GMAC with modules; the vendor kernel's glue
  # is built-in. The internal EPHY's MMIO MDIO mux is built into the
  # mainline kernel config, so dwmac-sophgo cannot race a missing mux
  # module during the first networkd open.
  kernelModules = lib.optionals mainline [
    "dwmac-sophgo"
  ];
  eth0Network = {
    matchConfig.Name = "eth0";
    networkConfig = {
      DHCP = "yes";
      IPv6AcceptRA = true;
    };
    linkConfig.RequiredForOnline = "no";
  };
in {
  # mainline: our patch 0013 teaches dwmac-sophgo the
  # "sophgo,cv1800b-dwmac" binding (and the internal-EPHY power-up the
  # mainline bootloader skips), so load dwmac-sophgo. It claims the node
  # via its first compatible before the generic glue would via the second
  # ("snps,dwmac-3.70a"). (modprobe pulls stmmac/stmmac-platform as deps.)
  boot.kernelModules = kernelModules;

  # Mainline needs the GMAC's DT node enabled — switch the board to the
  # combined ethernet+WiFi DTB. Normal priority beats the WiFi mixin's
  # mkDefault, so a NanoKVM-PCIe that also pulls in WiFi lands on the
  # one DTB that carries both. (Vendor's DTS already enables ethernet,
  # so leave its fdt at the platform default.)
  sg2002.fdt = lib.mkIf mainline pkgs.sg2002-dtb-mainline-pcie;

  systemd.network = {
    enable = true;
    networks."20-eth0" = eth0Network;
  };

}
