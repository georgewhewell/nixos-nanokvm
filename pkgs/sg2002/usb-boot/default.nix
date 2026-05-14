# USB bring-up helpers. Two binaries:
#   usb-boot          — push a FIP through the ROM, enter Sipeed
#                        vendor U-Boot's cvi_utask gadget, stage a FIT,
#                        bootm. Requires vendor FIP.
#   usb-boot-mainline — push a FIP through the ROM, wait for mainline
#                        U-Boot's fastboot gadget (18d1:d00d), stage a
#                        FIT via `fastboot stage` + `fastboot oem run`.
#                        Requires mainline FIP + android-tools.
{
  python3,
  writeShellApplication,
  symlinkJoin,
  android-tools,
  sg2002-cv181x-usb-dl,
  sg2002-fip,
  sg2002-fip-mainline-uboot,
}: let
  pythonEnv = python3.withPackages (ps: [ps.pyserial ps.pyusb]);

  # Path to the upstream cv181x-rom-dl's lib dir — contains the
  # `cv_usb_util` package + `cv_dl_magic.bin`.
  cvUsbLib = "${sg2002-cv181x-usb-dl}/lib/cv181x-usb-dl/rom_usb_dl";

  # fast-rom-dl used to live here as a libusb-only replacement for
  # the FIP-push phase. Dropped (PLAN.md → P10) because it only
  # handled the 1st-stage push (magic + first 4 KB + BREAK); the
  # vendor FSBL we still link against needs a 2nd-stage cvi_utask
  # transfer to receive the rest of FIP. Without a libusb impl of
  # 2nd-stage it was an incomplete shortcut that just clutters the
  # output. See ./fast_rom_dl.py history for the partial impl if
  # someone wants to finish it; meanwhile, both `usb-boot` runners
  # below shell out to upstream `cv181x-rom-dl` (with our pyserial
  # timeout / fast-open patches; see pkgs/sg2002-cv181x-rom-dl-…).

  usb-boot-vendor = writeShellApplication {
    name = "usb-boot";
    text = ''
      exec ${pythonEnv}/bin/python3 ${./usb_boot.py} \
        --rom-dl ${sg2002-cv181x-usb-dl}/bin/cv181x-rom-dl \
        --cv-usb-lib ${cvUsbLib} \
        --fip ${sg2002-fip} \
        "$@"
    '';
  };

  usb-boot-mainline = writeShellApplication {
    name = "usb-boot-mainline";
    runtimeInputs = [android-tools];
    text = ''
      exec ${pythonEnv}/bin/python3 ${./usb_boot_mainline.py} \
        --rom-dl ${sg2002-cv181x-usb-dl}/bin/cv181x-rom-dl \
        --fip ${sg2002-fip-mainline-uboot} \
        "$@"
    '';
  };
in
  symlinkJoin {
    name = "sg2002-usb-boot";
    paths = [usb-boot-vendor usb-boot-mainline];
  }
