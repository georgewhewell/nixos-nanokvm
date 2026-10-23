{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  flatbuffers,
}:
stdenvNoCC.mkDerivation {
  pname = "sophgo-cvibuilder";
  version = "0-unstable-2024-05-13";
  src = fetchFromGitHub {
    owner = "sophgo";
    repo = "cvibuilder";
    rev = "4309f2a649fc7cfe7160389d52a81c469dbdd7bc";
    sha256 = "1h0yx3gd9qyvvpfy0hyhl0sglpp6a78vsgcklrwd9papa2r3f0r1";
  };
  nativeBuildInputs = [ flatbuffers ];
  buildPhase = ''
    mkdir -p include/cvibuilder
    flatc --cpp -o include/cvibuilder proto/cvimodel.fbs proto/parameter.fbs
  '';
  installPhase = ''
    mkdir -p $out/include $out/share/cvibuilder
    cp -r include/cvibuilder $out/include/
    cp proto/*.fbs $out/share/cvibuilder/
  '';
  meta = {
    description = "Sophgo CVI model schema headers";
    homepage = "https://github.com/sophgo/cvibuilder";
    license = lib.licenses.unfree;
  };
}
