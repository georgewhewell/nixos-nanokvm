# Sophgo CV181x platform module. Imported by every board profile that
# targets this SoC family (LicheeRV-Nano-W dev board, Sipeed
# NanoKVM-PCIe). Pins the cross-compile target and registers our
# overlay (which includes all the sg2002-* package definitions).
#
# Board-specific facts (which DTB to use, whether ethernet is wired,
# what value `services.nanokvm.hardwareVersion` should be) live in
# `boards/<board>.nix`, not here.
{
  lib,
  allowUnfreePredicate,
  selfOverlay,
  ...
}: {
  imports = [
    ./sg2002-board-support.nix
  ];

  nixpkgs.hostPlatform = "riscv64-linux";
  nixpkgs.buildPlatform = "x86_64-linux";
  nixpkgs.config.allowUnfreePredicate = allowUnfreePredicate;
  nixpkgs.overlays = lib.mkAfter [selfOverlay];

  sg2002 = {
    enable = true;
    # Default to mainline U-Boot — its fastboot gadget is what every
    # USB-recovery / kernel-test profile relies on. The SD-image
    # profile overrides this to "vendor" so the on-disk image matches
    # the stock NanoKVM boot path.
    uboot = lib.mkDefault "mainline";
    tuning.enable = lib.mkDefault false;
    # Upstream sg2002 defaults `wifi.enable = true` (which pulls in
    # the aic8800 vendor driver build). We treat wifi as an opt-in
    # mixin (`modules/wifi-aic8800.nix`) so the default profile is
    # cable-only. Importing the mixin flips this back to true.
    wifi.enable = lib.mkDefault false;
  };

  system.stateVersion = lib.mkDefault "25.11";
}
