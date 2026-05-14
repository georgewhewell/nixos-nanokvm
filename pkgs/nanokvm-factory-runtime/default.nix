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
