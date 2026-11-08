{ buildPackages, lib, stdenv, kernel, contract }:
assert lib.assertMsg (contract.profileName == "picoclaw-lcd")
  "C906L Wi-Fi power requires the exact PicoClaw contract";
stdenv.mkDerivation {
  pname = "sg2002-c906l-wifi-power";
  version = "0.1.0-${kernel.modDirVersion}";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Makefile ./sg2002-c906l-wifi-power.c ./test_source.py ./test_transport.c
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
      python3 test_source.py sg2002-c906l-wifi-power.c ${contract}/include
  '';
  installPhase = ''
    runHook preInstall
    install -Dm0644 sg2002-c906l-wifi-power.ko \
      "$out/lib/modules/${kernel.modDirVersion}/kernel/drivers/regulator/sg2002-c906l-wifi-power.ko"
    # New nixpkgs depmod merges per-module certificates into
    # modules.cer; emit one for this out-of-tree module too.
    ${buildPackages.kmodigest}/bin/kmodigest \
      "$out/lib/modules/${kernel.modDirVersion}/kernel/drivers/regulator/sg2002-c906l-wifi-power.ko"
    runHook postInstall
  '';
  passthru.contractPackage = contract;
  passthru.tests.transport = buildPackages.runCommand "sg2002-c906l-wifi-power-tests" {
    nativeBuildInputs = [ buildPackages.python3 buildPackages.stdenv.cc ];
  } ''
    python3 ${./test_source.py} ${./sg2002-c906l-wifi-power.c} \
      ${contract}/include ${./test_transport.c}
    touch "$out"
  '';
  meta = {
    description = "Acknowledged C906L Wi-Fi power regulator for the SG2002 PicoClaw";
    license = lib.licenses.gpl2Only;
    platforms = [ "riscv64-linux" ];
  };
}
