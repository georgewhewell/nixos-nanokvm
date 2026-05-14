{
  lib,
  fetchurl,
  file,
  patchelf,
  stdenv,
  zlib,
}:

stdenv.mkDerivation {
  pname = "sophgo-host-tools";
  version = "2023-03-07";

  src = fetchurl {
    url = "https://sophon-file.sophon.cn/sophon-prod-s3/drive/23/03/07/16/host-tools.tar.gz";
    hash = "sha256-/5pY6OGSsg6kLh1ynELSIZUjIJcGyz8M8TRYL2xw+AU=";
  };

  nativeBuildInputs = [
    file
    patchelf
  ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    cp -a host-tools/gcc/riscv64-linux-musl-x86_64/. "$out/"
    chmod -R u+w "$out"

    hostRpath="${lib.makeLibraryPath [stdenv.cc.cc.lib zlib]}"
    hostInterpreter="${stdenv.cc.bintools.dynamicLinker}"

    while IFS= read -r elf; do
      if file -b "$elf" | grep -q 'ELF 64-bit LSB.*x86-64'; then
        if patchelf --print-interpreter "$elf" >/dev/null 2>&1; then
          patchelf --set-interpreter "$hostInterpreter" "$elf" || true
        fi
        patchelf --set-rpath "$hostRpath" "$elf" || true
      fi
    done < <(find "$out" -type f \( -perm -0100 -o -name '*.so*' \))

    runHook postInstall
  '';

  passthru = {
    targetPrefix = "riscv64-unknown-linux-musl-";
    upstreamCgoCFlags = "-mcpu=c906fdv -march=rv64imafdcv0p7xthead -mcmodel=medany -mabi=lp64d";
  };

  meta = {
    description = "Sophgo/Sipeed riscv64 musl host toolchain";
    homepage = "https://developer.sophgo.com";
    license = lib.licenses.unfreeRedistributable;
    platforms = ["x86_64-linux"];
  };
}
