{ stdenv, lib, alsa-lib ? null, enablePcma ? false,
  sophgo-cviruntime ? null, enableDetection ? false }:
assert !enableDetection || sophgo-cviruntime != null;
stdenv.mkDerivation {
  pname = "sg2002-h264-bridge${lib.optionalString enablePcma "-pcma"}${lib.optionalString enableDetection "-detection"}";
  version = "0.4";

  src = ./sg2002-h264-bridge.c;
  dontUnpack = true;
  dontConfigure = true;

  buildInputs = lib.optional enablePcma alsa-lib
    ++ lib.optional enableDetection sophgo-cviruntime;

  buildPhase = ''
    runHook preBuild
    $CC -std=c11 -O2 -Wall -Wextra -Wconversion -Wshadow -Wformat=2 \
      -Werror ${lib.optionalString enablePcma "-DENABLE_PCMA=1"} \
      ${lib.optionalString enableDetection "-DENABLE_DETECTION=1 -I${./.} ${./detection.c}"} \
      -o sg2002-h264-bridge $src ${lib.optionalString enablePcma "-pthread -lasound"} \
      ${lib.optionalString enableDetection "-pthread -lcviruntime -lm"}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 sg2002-h264-bridge "$out/bin/sg2002-h264-bridge${lib.optionalString enablePcma "-pcma"}"
    runHook postInstall
  '';
}
