{ stdenv, lib, alsa-lib ? null, enablePcma ? false }:
stdenv.mkDerivation {
  pname = "sg2002-h264-bridge${lib.optionalString enablePcma "-pcma"}";
  version = "0.3";

  src = ./sg2002-h264-bridge.c;
  dontUnpack = true;
  dontConfigure = true;

  buildInputs = lib.optional enablePcma alsa-lib;

  buildPhase = ''
    runHook preBuild
    $CC -std=c11 -O2 -Wall -Wextra -Wconversion -Wshadow -Wformat=2 \
      -Werror ${lib.optionalString enablePcma "-DENABLE_PCMA=1"} \
      -o sg2002-h264-bridge $src ${lib.optionalString enablePcma "-pthread -lasound"}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 sg2002-h264-bridge "$out/bin/sg2002-h264-bridge${lib.optionalString enablePcma "-pcma"}"
    runHook postInstall
  '';
}
