{ buildPackages
, lib
, stdenv
, kernel
, contract
,
}:

assert lib.assertMsg (contract ? contractSha256 && contract ? profileName)
  "sg2002-c906l-control requires a generated C906L contract package";
stdenv.mkDerivation {
  pname = "sg2002-c906l-control";
  version = "0.2.0-${kernel.modDirVersion}";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Makefile
      ./sg2002-c906l-control.c
      ./picoclaw-lcd-handoff.h
      ./test_source.py
      ./test_read.c
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
      python3 test_source.py sg2002-c906l-control.c \
      ${contract}/share/sg2002-c906l/contract.json \
      picoclaw-lcd-handoff.h
  '';

  installPhase = ''
    runHook preInstall
    install -Dm0644 sg2002-c906l-control.ko \
      "$out/lib/modules/${kernel.modDirVersion}/kernel/drivers/misc/sg2002-c906l-control.ko"
    # New nixpkgs depmod merges per-module certificates into
    # modules.cer; emit one for this out-of-tree module too.
    ${buildPackages.kmodigest}/bin/kmodigest \
      "$out/lib/modules/${kernel.modDirVersion}/kernel/drivers/misc/sg2002-c906l-control.ko"
    runHook postInstall
  '';

  passthru = {
    contractPackage = contract;
    inherit
      (contract)
      contractEpoch
      contractSha256
      dormantCapabilities
      leaseMask
      manifestFlags
      profileId
      profileName
      protocolVersion
      requiredCapabilities
      ;
  };

  meta = {
    description = "Linux mailbox control endpoint for the SG2002 C906L";
    license = lib.licenses.gpl2Only;
    platforms = [ "riscv64-linux" ];
  };
}
