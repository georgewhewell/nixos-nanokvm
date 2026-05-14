# Vendor SG2002 5.10 kernel, with NanoKVM-specific config layered on
# top of nixos-sg2002's baseline vendor defconfig.
{
  lib,
  stdenv,
  linuxManualConfig,
  runCommand,
  writeText,
  licheerv-nano-build,
  baseExtraConfig,
  boardName ? "sg2002_licheervnano_sd",
  features ? {},
  kernelExtraConfig ? "",
  kernelPatches ? [],
  # Empty (not null) because recent nixpkgs interpolates
  # `${randstructSeed}` directly into the kernel's `postPatch`
  # (sha256sum input for the NIXOS_RANDSTRUCT_SEED replacement). A
  # `null` there trips "cannot coerce null to string" at Nix eval —
  # this kernel doesn't enable RANDSTRUCT anyway, so the value
  # doesn't have to be a real seed.
  randstructSeed ? "",
  modDirVersion ? "5.10.4",
  ...
}: let
  version = "5.10.4";
  src = "${licheerv-nano-build}/linux_5.10";
  vendorDefconfig =
    "${licheerv-nano-build}/build/boards/sg200x/${boardName}/linux/${boardName}_defconfig";
  extraConfigFile = writeText "nanokvm-kernel-extra-config" kernelExtraConfig;

  configfile = runCommand "kernel-config" {} ''
    cp ${vendorDefconfig} "$out"

    # Vendor defconfig sets the RISC-V vector extension (expects Glibc
    # with vector support we don't have) and explicitly disables
    # cgroups / fhandle (NixOS activation needs them); strip those.
    substituteInPlace "$out" \
      --replace "CONFIG_VECTOR=y" "" \
      --replace "CONFIG_VECTOR_0_7=y" "" \
      --replace "# CONFIG_CGROUPS is not set" "" \
      --replace "# CONFIG_FHANDLE is not set" ""

    cat ${baseExtraConfig} >> "$out"
    cat ${extraConfigFile} >> "$out"
  '';
in
  (linuxManualConfig {
    inherit
      version
      src
      configfile
      kernelPatches
      modDirVersion
      randstructSeed
      features
      ;
    allowImportFromDerivation = true;
  })
  .overrideAttrs (old: {
    passthru = (old.passthru or {}) // {features = {};};

    preConfigure = ''
      substituteInPlace arch/riscv/Makefile \
        --replace-quiet '-mno-ldd' "" \
        --replace-quiet 'KBUILD_CFLAGS += -march=$(riscv-march-cflags-y)' \
                'KBUILD_CFLAGS += -march=$(riscv-march-cflags-y)_zicsr_zifencei' \
        --replace-quiet 'KBUILD_AFLAGS += -march=$(riscv-march-aflags-y)' \
                'KBUILD_AFLAGS += -march=$(riscv-march-aflags-y)_zicsr_zifencei'

      substituteInPlace arch/riscv/mm/context.c \
        --replace-quiet sptbr CSR_SATP
    '';

    postInstall =
      (old.postInstall or "")
      + ''
        for path in arch/riscv/kernel/vdso lib/vdso; do
          DST=$dev/lib/modules/${modDirVersion}/source/$path
          mkdir -p $DST
          cp -r ${src}/$path/. $DST/
        done
      '';
  })
