{ lib, stdenv, linux_7_3, python3, bc, bison, flex, perl, openssl, elfutils, qemu, jq }:
let
  source = import ../source.nix { inherit linux_7_3; };
  clockPatches = builtins.filter
    (patch: lib.hasPrefix "clk-cv18xx-" patch.name)
    (import ../patches.nix).patches;
in
stdenv.mkDerivation {
  pname = "sg2002-clock-kunit";
  inherit (source) src version;
  patches = map (patch: patch.patch) clockPatches;
  nativeBuildInputs = [ python3 bc bison flex perl openssl elfutils qemu jq ];
  hardeningDisable = [ "all" ];
  dontConfigure = true;

  postPatch = ''
    # Link the tests only into this QEMU test kernel, not the board kernels.
    cp ${./clk-cv18xx-kunit.c} drivers/clk/sophgo/clk-cv18xx-kunit.c
    substituteInPlace drivers/clk/sophgo/Makefile \
      --replace-fail 'clk-cv18xx-ip.o' 'clk-cv18xx-ip.o clk-cv18xx-kunit.o'
    patchShebangs scripts tools/testing/kunit
  '';

  buildPhase = ''
    runHook preBuild
    # Kbuild also uses "src"; do not pass stdenv's archive path as a directory.
    env -u src python3 tools/testing/kunit/kunit.py run --arch=x86_64 \
      --kunitconfig=${./clock.kunitconfig} --build_dir=.kunit \
      --jobs="$NIX_BUILD_CORES" --timeout=120 --json=results.json 'cv18xx-clock*'
    jq -e '
      [.sub_groups[] | select(.name == "cv18xx-clock") | .test_cases[]]
      | length == 11 and all(.status == "PASS")
    ' results.json
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir "$out"
    cp results.json .kunit/test.log .kunit/.config "$out/"
    runHook postInstall
  '';
}
