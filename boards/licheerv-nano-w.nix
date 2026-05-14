# Sipeed LicheeRV-Nano-W dev board. Same SG2002 silicon as the
# NanoKVM-PCIe but without the carrier-board ethernet, ATX header, or
# OLED — i.e. just the bare SoM with WiFi. This is what we iterate on
# day-to-day via the USB-recovery boot path.
#
# Board-specific facts only. Anything CV181x-generic lives in
# `platform/cv181x.nix`; anything that varies per-profile (kernel
# choice, hostname, transport) lives in `profiles/`. Capabilities the
# board doesn't have (ethernet, OLED, …) are simply *not imported*
# rather than gated by predicates.
{lib, ...}: {
  imports = [
    ../platform/cv181x.nix
  ];

  # nanokvm-server's `hardwareVersion` selects between three carrier
  # boards (alpha/beta/pcie). The dev board isn't any of those, but
  # the GPIO map matches the pcie variant well enough — pick that so
  # the server doesn't crash on first GPIO export.
  services.nanokvm.hardwareVersion = lib.mkDefault "pcie";
  services.nanokvm.hdmiVersion = lib.mkDefault "ux";
}
