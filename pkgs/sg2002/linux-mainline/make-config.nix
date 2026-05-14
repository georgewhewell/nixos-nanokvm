# Native-side helper that renders pkgs/linux-mainline/config.nix on top
# of the mainline RISC-V `defconfig` and runs `make olddefconfig` to
# reconcile dependencies.
#
# buildPackages.* pulls the native (build-host) versions of gcc/make
# even when this file is callPackage'd from a cross pkgs — kconfig is
# a host tool, not a target binary.
{
  lib,
  runCommand,
  buildPackages,
  src,
  config,
  # Kernel patches that add or remove Kconfig entries must be applied
  # here before `make olddefconfig` runs — otherwise olddefconfig sees
  # a config option it doesn't recognise and silently drops it from
  # the produced .config. Pass the same list as kernelPatches in the
  # linux-mainline derivation; duplicate-application is harmless since
  # the source tree we patch here is thrown away after olddefconfig.
  patches ? [],
}: let
  extraConfigText = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      name: value:
        if value ? freeform
        then "CONFIG_${name}=\"${value.freeform}\""
        else if value.tristate == "n"
        then "# CONFIG_${name} is not set"
        else "CONFIG_${name}=${value.tristate}"
    )
    config
  );
  applyPatches = lib.concatMapStringsSep "\n" (p: "patch -p1 < ${p}") patches;
in
  runCommand "linux-sg2002-config" {
    nativeBuildInputs = with buildPackages; [
      gnumake
      gcc
      flex
      bison
      bc
      perl
      pkg-config
      openssl
    ];
    # Kconfig tools sometimes dereference $HOME; point it at a writable
    # tmp dir to avoid `cd: /homeless-shelter` style failures.
    HOME = "/build/tmphome";
  } ''
    mkdir -p "$HOME" workdir
    cd workdir

    if [ -d "${src}" ]; then
      cp -r ${src}/. .
      chmod -R u+w .
    else
      tar -xf ${src}
      cd linux-*/
    fi

    ${applyPatches}

    make ARCH=riscv defconfig
    cat <<'EOF' >> .config
    ${extraConfigText}
    EOF
    make ARCH=riscv olddefconfig
    cp .config $out
  ''
