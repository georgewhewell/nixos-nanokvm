# Fully-mainline FIP: vendor FSBL + vendor DDR params (both extracted
# from the known-working vendor fip.bin, since sophgo's own prebuilt
# `data/fsbl/cv181x.bin` won't POST on the LicheeRV Nano — it drops
# into an eMMC retry loop) + mainline OpenSBI 1.8.1 (with embedded
# U-Boot DTB so it has an FDT even if the FSBL doesn't pass one via
# fw_dynamic_info) + mainline U-Boot 2026.04, wrapped by sophgo/fiptool
# (LZMA-compressed B3MA blob; Sipeed's fiptool.py BL33-magic repack
# path produces a blob that doesn't decompress on-target).
{
  runCommand,
  python3,
  sg2002-fip,
  sg2002-sophgo-fiptool,
  sg2002-opensbi-mainline,
  sg2002-uboot-mainline,
}:
runCommand "fip-sg2002-mainline-uboot" {
  nativeBuildInputs = [python3];
} ''
  mkdir -p $out workdir

  python3 ${./extract-vendor-bits.py} ${sg2002-fip}/fip.bin workdir

  python3 ${sg2002-sophgo-fiptool}/fiptool \
    --fsbl      workdir/vendor-fsbl.bin \
    --ddr_param workdir/vendor-ddr.bin \
    --rtos      ${sg2002-sophgo-fiptool}/data/cvirtos.bin \
    --opensbi   ${sg2002-opensbi-mainline}/share/opensbi/lp64/generic/firmware/fw_dynamic.bin \
    --uboot     ${sg2002-uboot-mainline}/u-boot.bin \
    $out/fip.bin
''
