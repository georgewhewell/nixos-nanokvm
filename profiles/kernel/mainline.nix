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
#     Use the `nocamera` build instead (see patch 0002 + the
#     `nanokvm-server-nocamera` overlay attr).
{
  pkgs,
  lib,
  ...
}: {
  sg2002.kernel = lib.mkDefault "mainline";

  services.nanokvm = {
    kmods.enable = lib.mkDefault false;
    hdmi.enable = lib.mkDefault false;
    package = lib.mkDefault pkgs.buildPackages.nanokvm-server-nocamera;
  };
}
