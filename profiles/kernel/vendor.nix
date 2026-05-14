# Kernel choice: Sophgo vendor 5.10 tree.
#
# This is the kernel that ships with the vendor firmware. Its
# `soph_*` driver stack actually drives the camera/HDMI capture
# pipeline correctly. Use this kernel on hardware where you want
# HDMI capture to work (NanoKVM-PCIe with real HDMI source).
{
  pkgs,
  lib,
  ...
}: {
  sg2002.kernel = lib.mkDefault "vendor";

  services.nanokvm = {
    # The vendor `soph_*` kernel modules are what wire up
    # the camera SDK that nanokvm-server links against.
    kmods.enable = lib.mkDefault true;

    # HDMI init in nanokvm-server is safe with vendor kernel —
    # the SDK has the sensor INI parser working.
    hdmi.enable = lib.mkDefault true;

    # Use the cgo-linked server build (the one that talks to
    # libkvm.so for HDMI capture).
    package = lib.mkDefault pkgs.buildPackages.nanokvm-server;
  };
}
