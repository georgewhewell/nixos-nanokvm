{ buildPackages, lib, stdenv, kernel, contract }:
assert lib.assertMsg (contract.profileName == "picoclaw-lcd")
  "C906L framebuffer requires the exact PicoClaw LCD contract";
stdenv.mkDerivation {
  pname = "sg2002-c906l-framebuffer";
  version = "0.1.0-${kernel.modDirVersion}";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Makefile
      ./sg2002-c906l-framebuffer.c
      ./test_source.py
      ./test_ownership.c
    ];
  };
  postPatch = ''
    cp ${contract}/include/sg2002-c906l-kernel-contract.h .
  '';
  nativeBuildInputs = kernel.moduleBuildDependencies ++ [ buildPackages.python3 ];
  hardeningDisable = [ "pic" "format" ];
  makeFlags = [
    "KDIR=${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
    "ARCH=riscv"
    "CROSS_COMPILE=${stdenv.cc.targetPrefix}"
  ];
  postBuild = ''
    HOST_CC=${buildPackages.stdenv.cc}/bin/cc \
      python3 test_source.py sg2002-c906l-framebuffer.c ${contract}/include
  '';
  installPhase = ''
    runHook preInstall
    install -Dm0644 sg2002-c906l-framebuffer.ko \
      "$out/lib/modules/${kernel.modDirVersion}/kernel/drivers/misc/sg2002-c906l-framebuffer.ko"
    runHook postInstall
  '';

  # nixpkgs merges external-module certificates into modules.cer. Generate
  # the signatures after fixup so stripping cannot invalidate them.
  postFixup = lib.optionalString (buildPackages ? kmodigest) ''
    while IFS= read -r -d "" module; do
      ${lib.getExe buildPackages.kmodigest} "$module"
    done < <(find "$out/lib/modules" -type f -name '*.ko' -print0)
  '';
  passthru.contractPackage = contract;
  passthru.tests.ownership = buildPackages.runCommand "sg2002-c906l-framebuffer-ownership-tests"
    {
      nativeBuildInputs = [ buildPackages.python3 buildPackages.stdenv.cc ];
      testSource = lib.fileset.toSource {
        root = ./.;
        fileset = lib.fileset.unions [
          ./sg2002-c906l-framebuffer.c
          ./test_source.py
          ./test_ownership.c
        ];
      };
    } ''
    python3 "$testSource/test_source.py" \
      "$testSource/sg2002-c906l-framebuffer.c" ${contract}/include
    touch "$out"
  '';
  meta = {
    description = "Bounded double-buffered shared-memory LCD submission for SG2002 C906L";
    license = lib.licenses.gpl2Only;
    platforms = [ "riscv64-linux" ];
  };
}
