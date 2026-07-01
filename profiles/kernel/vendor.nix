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
    # libkvm.so for HDMI capture), forced to riscv64. Do NOT use
    # `pkgs.buildPackages.nanokvm-server` here: buildPackages is the
    # *build host* set, so its hostPlatform is x86_64 — the derivation
    # then force-falls-back to noCamera AND emits an x86_64 binary
    # that dies 203/EXEC on the device. (Same trap the mainline
    # profile documents for nanokvm-server-nocamera.)
    package = lib.mkDefault pkgs.nanokvm-server-device-camera;
  };
}
