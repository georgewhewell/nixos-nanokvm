# Vendor DTB builder for the SG2002 / LicheeRV Nano. Produces two
# outputs:
#   .boot    — DTS for SD-root boot; used by the vendor-FIT SD-image path.
#   .gadget  — DTS with dr_mode=peripheral + larger USB FIFOs; used by
#              the USB-initrd dev bring-up path.
#
# Vendor DTS pulls in a generated `cvi_board_memmap.h` from the board's
# memmap.py; hence the mmap_conv.py → cpp → dtc sequence.
{
  runCommand,
  replaceVars,
  dtc,
  gcc,
  python3,
  licheerv-nano-build,
}: let
  boardName = "sg2002_licheervnano_sd";
  vendorDts = "${licheerv-nano-build}/build/boards/sg200x/${boardName}/dts_riscv/${boardName}.dts";
  memmapPy = "${licheerv-nano-build}/build/boards/sg200x/${boardName}/memmap.py";
  mmapConv = "${licheerv-nano-build}/build/scripts/mmap_conv.py";
  includeDir = "${licheerv-nano-build}/build/boards/default/dts/sg200x";
  linuxHeaders = "${licheerv-nano-build}/linux_5.10/include";

  mkDtb = variant: wrapper:
    runCommand "sg2002-licheervnano-${variant}.dtb" {
      nativeBuildInputs = [dtc gcc python3];
    } ''
      mkdir -p gen
      python3 ${mmapConv} --type h ${memmapPy} gen/cvi_board_memmap.h

      cpp -nostdinc -undef -x assembler-with-cpp \
        -I gen \
        -I ${includeDir} \
        -I ${linuxHeaders} \
        -o sg2002.pre.dts \
        ${wrapper}

      dtc -I dts -O dtb -o "$out" sg2002.pre.dts
    '';

  bootWrapper = replaceVars ./boot-wrapper.dts {inherit vendorDts;};
  gadgetWrapper = replaceVars ./gadget-wrapper.dts {inherit vendorDts;};
in {
  boot = mkDtb "boot" bootWrapper;
  gadget = mkDtb "gadget" gadgetWrapper;
}
