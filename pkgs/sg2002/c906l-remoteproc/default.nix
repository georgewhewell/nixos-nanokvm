{ buildPackages
, lib
, stdenv
, kernel
, contract
,
}:

assert lib.assertMsg (contract ? contractSha256 && contract ? profileName)
  "sg2002-c906l-remoteproc requires a generated C906L contract package";
stdenv.mkDerivation {
  pname = "sg2002-c906l-remoteproc";
  version = "0.2.0-${kernel.modDirVersion}";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Makefile
      ./sg2002-c906l-remoteproc.c
      ./test_source.py
      ./test_notify.c
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
      python3 test_source.py sg2002-c906l-remoteproc.c \
      ${contract}/share/sg2002-c906l/contract.json
  '';

  installPhase = ''
    runHook preInstall
    install -Dm0644 sg2002-c906l-remoteproc.ko \
      "$out/lib/modules/${kernel.modDirVersion}/kernel/drivers/remoteproc/sg2002-c906l-remoteproc.ko"
    runHook postInstall
  '';

  # nixpkgs merges external-module certificates into modules.cer. Generate
  # the signatures after fixup so stripping cannot invalidate them.
  postFixup = lib.optionalString (buildPackages ? kmodigest) ''
    while IFS= read -r -d "" module; do
      ${lib.getExe buildPackages.kmodigest} "$module"
    done < <(find "$out/lib/modules" -type f -name '*.ko' -print0)
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
    description = "Attach-only Linux remoteproc/RPMsg transport for SG2002 C906L";
    license = lib.licenses.gpl2Only;
    platforms = [ "riscv64-linux" ];
  };
}
