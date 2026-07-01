# Kernel choice: upstream Linux mainline.
#
# Trades working HDMI capture (vendor SDK only) for a clean upstream
# kernel that gets security updates and runs current userspace happily.
# Use this for development, USB-NBD live boots, anywhere capture isn't
# the priority.
#
# Two knock-on effects:
#   - The vendor `soph_*` kmods can't load against mainline; skip them.
#   - `nanokvm-server` must NOT link libkvm.so on mainline — its C++
#     static constructors SEGV in SAMPLE_COMM_VI_ParseIni before main().
#     Use the nocamera build instead — `nanokvm-server-device` is the
#     nocamera *and* riscv64-cross variant. (Do NOT use
#     `pkgs.buildPackages.nanokvm-server-nocamera`: buildPackages is the
#     build host, so that ships an x86_64 binary that dies 203/EXEC on
#     the device — it crash-loops and starves the 256 MB board.)
{
  pkgs,
  lib,
  ...
}: {
  sg2002.kernel = lib.mkDefault "mainline";

  services.nanokvm = {
    kmods.enable = lib.mkDefault false;
    hdmi.enable = lib.mkDefault false;
    package = lib.mkDefault pkgs.nanokvm-server-device;
  };
}
