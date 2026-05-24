# Mainline Linux built from `pkgs.linux_latest.src` with SG2002
# SoC-support patches layered on top (see ./patches.nix for the queue
# and ./patches/ for the actual diffs). Each patch should have an
# `origin` and `upstreamStatus` field.
#
# linuxManualConfig + a pre-rendered configfile. The configfile is
# produced by the native side of the overlay via make-config.nix, so
# kconfig tooling runs under host gcc — not the cross one.
{ lib
, linuxManualConfig
, linux_latest
, configfile
, ...
}:
(linuxManualConfig {
  inherit (linux_latest) version src;
  inherit configfile;
  allowImportFromDerivation = true;
  # Single source of truth; same list also goes through make-config.nix
  # so olddefconfig sees Kconfig added by these patches.
  kernelPatches = (import ./patches.nix).patches;
}).overrideAttrs (old: {
  # Empty features flags this as an out-of-tree kernel so NixOS skips
  # config-option validation (see nixpkgs kernel.nix:505).
  passthru = (old.passthru or { }) // { features = { }; };

  # RISC-V `make install` hardcodes Image.gz; the build only produces
  # Image. Compress before install, then copy Image back into $out
  # (NixOS's kernelFile default is Image). No user-visible compression
  # happens — it's just a shuffle to satisfy arch/riscv/Makefile.
  postBuild =
    (old.postBuild or "")
    + ''
      gzip -9 --keep --no-name arch/riscv/boot/Image
    '';
  postInstall =
    (old.postInstall or "")
    + ''
      gunzip -c $out/Image.gz > $out/Image
    '';
})
