# Sipeed NanoKVM-PCIe — the actual product. Carrier board adds:
#   - Wired ethernet (CV-DWMAC on ethernet@4070000)
#   - ATX header wired to gpiochip0 lines 502..505
#   - OLED footprint (may or may not be populated per unit)
#   - HDMI input on the Lattice CrossLink (cvi-vi pipeline)
#
# Same CV181x silicon as the LicheeRV-Nano-W; everything that's not
# carrier-board specific stays in `platform/cv181x.nix`.
{lib, ...}: {
  imports = [
    ../platform/cv181x.nix
    # PCIe carrier wires RJ45 to ethernet@4070000 — pull in the
    # mixin that brings the controller up and routes link traffic.
    ../modules/ethernet-bm-dwmac.nix
  ];

  services.nanokvm.hardwareVersion = lib.mkDefault "pcie";
  services.nanokvm.hdmiVersion = lib.mkDefault "ux";
}
