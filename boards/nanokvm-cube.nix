# Sipeed NanoKVM cube (Lite/Full) with the "beta" carrier. Same pad map as
# the NanoKVM-PCIe: wired Ethernet, ATX header, HDMI bridge on I2C4 and the
# OLED on bit-banged GPIOA15/A27. The panel answers at 0x3d rather than 0x3c.
#
# "alpha" carriers wire the OLED to I2C1 on the SDIO1 pads and are not
# covered here.
{
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [
    ./nanokvm-pcie.nix
  ];

  # ethernet.nix selects the PCIe DTB at normal priority.
  sg2002.fdt = lib.mkIf (config.sg2002.kernel == "mainline") (
    lib.mkOverride 90 pkgs.sg2002-dtb-mainline-cube
  );

  sg2002.usbGadget.product = "Sipeed NanoKVM (NixOS)";
  sg2002.usbGadget.serial = "nanokvm-cube-0001";

  services.nanokvm.hardwareVersion = "beta";
}
