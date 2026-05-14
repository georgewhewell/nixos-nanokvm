# Mainline DTBs for the Sipeed LicheeRV Nano B-W variant.
#
# Starts from the upstream `sg2002-licheerv-nano-b.dts` in the mainline
# kernel tree (passed in as `linuxSrc`) and concatenates one or more
# overlay dtsi files — dtc merges nodes, so later properties replace
# earlier ones. Two flavours:
#
#   .dtb     — bw.dtsi only (default: WiFi/SDIO1 enabled).
#   .dtbOled — bw.dtsi + bw-oled.dtsi (SDIO1 disabled, IIC1 + SSD1306
#              child on the freed-up SD1 pads). Pair with builds that
#              also turn sg2002.wifi.enable off.
#   .dtbs    — directory-shaped wrapper for NixOS's
#              `hardware.deviceTree.package` (covers the default DTB).
{
  lib,
  runCommand,
  dtc,
  gcc,
  linuxSrc,
}: let
  # Each overlay has to be interpolated into the script body individually
  # — `toString [path1 path2]` doesn't trigger Nix's path-to-store import,
  # it just stringifies the raw source paths, which are then missing from
  # the build's closure. `${p}` per element does the import.
  buildDtb = name: overlays:
    runCommand "${name}.dtb" {
      nativeBuildInputs = [dtc gcc];
    } ''
      tar -xf ${linuxSrc}
      SRC=$(echo linux-*/)
      DTS=$SRC/arch/riscv/boot/dts/sophgo/sg2002-licheerv-nano-b.dts

      cat "$DTS" ${lib.concatMapStringsSep " " (p: "${p}") overlays} > merged.dts

      cpp -nostdinc -undef -x assembler-with-cpp \
        -I "$SRC/include" \
        -I "$SRC/arch/riscv/boot/dts/sophgo" \
        -o merged.pre.dts merged.dts

      dtc -I dts -O dtb -o "$out" merged.pre.dts
    '';

  dtb = buildDtb "sg2002-licheerv-nano-bw" [
    ./sg2002-licheerv-nano-bw.dtsi
  ];

  dtbOled = buildDtb "sg2002-licheerv-nano-bw-oled" [
    ./sg2002-licheerv-nano-bw.dtsi
    ./sg2002-licheerv-nano-bw-oled.dtsi
  ];

  dtbNoWifi = buildDtb "sg2002-licheerv-nano-bw-nowifi" [
    ./sg2002-licheerv-nano-bw.dtsi
    ./sg2002-licheerv-nano-bw-nowifi.dtsi
  ];

  dtbs =
    runCommand "sg2002-dtbs" {} ''
      mkdir -p $out/sophgo
      cp ${dtb} $out/sophgo/sg2002-licheerv-nano-bw.dtb
    '';
in {
  inherit dtb dtbs;
  oled = dtbOled;
  nowifi = dtbNoWifi;
}
