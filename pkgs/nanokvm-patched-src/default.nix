{
  lib,
  stdenvNoCC,
  src,
  patches ? [],
}:

stdenvNoCC.mkDerivation {
  pname = "nanokvm-src";
  version = "unstable";

  inherit src patches;

  postUnpack = ''
    chmod -R u+w "$sourceRoot"
  '';

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    cp -a . "$out/"

    runHook postInstall
  '';

  meta = {
    description = "NanoKVM source with local flake patches applied";
    homepage = "https://github.com/sipeed/NanoKVM";
    license = lib.licenses.gpl3Only;
  };
}

