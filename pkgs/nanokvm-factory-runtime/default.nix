{
  lib,
  coreutils,
  e2fsprogs,
  fetchurl,
  stdenvNoCC,
  xz,
}:

stdenvNoCC.mkDerivation {
  pname = "nanokvm-factory-runtime";
  version = "1.4.2";

  src = fetchurl {
    url = "https://github.com/sipeed/NanoKVM/releases/download/v1.4.2/20260123_NanoKVM_Rev1_4_2.img.xz";
    hash = "sha256-7FuZD1wI079nu1P8PadtUCJDIAec+n2SH6ZXsdLFZ7o=";
  };

  dontUnpack = true;

  nativeBuildInputs = [
    coreutils
    e2fsprogs
    xz
  ];

  installPhase = ''
    runHook preInstall

    image="$TMPDIR/nanokvm.img"
    rootfs="$TMPDIR/rootfs.ext4"

    xz -dc "$src" > "$image"
    dd if="$image" of="$rootfs" bs=512 skip=32769 count=3145728 status=none

    usrLib="$TMPDIR/usr-lib"

    mkdir -p "$out/lib" "$usrLib"
    debugfs -R "rdump /usr/lib $usrLib" "$rootfs"
    find "$usrLib/lib" -maxdepth 1 \
      \( -name 'libopencv_*.so*' \
      -o -name 'libprotobuf*.so*' \
      -o -name 'libavcodec.so*' \
      -o -name 'libavformat.so*' \
      -o -name 'libavutil.so*' \
      -o -name 'libswresample.so*' \
      -o -name 'libswscale.so*' \
      -o -name 'libjpeg.so*' \
      -o -name 'libpng16.so*' \
      -o -name 'libtbb.so*' \
      -o -name 'libtiff.so*' \
      -o -name 'libwebp.so*' \
      -o -name 'libsharpyuv.so*' \
      -o -name 'libbz2.so*' \
      -o -name 'libssl.so*' \
      -o -name 'libcrypto.so*' \) \
      -exec cp -a -t "$out/lib" {} +

    debugfs -R "rdump /mnt/system/ko $out" "$rootfs"

    # kvm_system — the separate C++ side-binary (LT6911 HDMI-bridge
    # config over /dev/i2c-4, OLED status UI, ATX buttons/LEDs). The
    # NanoKVM repo only ships its *source* (MaixCDK build system, a
    # rabbit hole); the stock image carries the prebuilt binary at
    # /kvmapp/kvm_system/kvm_system. Lift it out as-is. The dir also
    # holds an (empty) dl_lib/ the binary's $ORIGIN/dl_lib rpath points
    # at, a zero-byte kvm_stream placeholder, and a stray .DS_Store —
    # only the binary matters, but keep dl_lib/ so the rpath entry stays
    # honest. ELF facts (riscv64 musl): NEEDED libstdc++.so.6,
    # libgcc_s.so.1, libc.so; interpreter
    # /lib/ld-musl-riscv64v0p7_xthead.so.1. Neither exists on a NixOS
    # rootfs — nanokvm-server's installPhase patchelfs interpreter and
    # rpath to the cross-musl toolchain when it ships this binary.
    mkdir -p "$out/kvm_system/dl_lib"
    debugfs -R "dump /kvmapp/kvm_system/kvm_system $out/kvm_system/kvm_system" "$rootfs"
    chmod 0755 "$out/kvm_system/kvm_system"

    # Sensor INI the vendor capture SDK hard-requires:
    # libkvm_mmf.so's SAMPLE_COMM_VI_ParseIni reads
    # /mnt/data/sensor_cfg.ini (fallback /mnt/system/usr/bin/) and
    # bails with "can not find sensor ini in /mnt/data/" otherwise —
    # no INI, no capture. The stock S95nanokvm copies the LT6911
    # variant (sensor_cfg.ini.LT → sensor_cfg.ini) on every boot; ship
    # all variants and let the NixOS module pick .LT the same way.
    mkdir -p "$out/data" "$TMPDIR/mnt-data"
    debugfs -R "rdump /mnt/data $TMPDIR/mnt-data" "$rootfs"
    cp -a "$TMPDIR/mnt-data/data/." "$out/data/"

    chmod -R u=rwX,go=rX "$out"

    runHook postInstall
  '';

  meta = {
    description = "Runtime libraries and kernel modules extracted from the official NanoKVM image";
    homepage = "https://github.com/sipeed/NanoKVM/releases/tag/v1.4.2";
    license = lib.licenses.unfreeRedistributable;
    platforms = lib.platforms.linux;
  };
}
