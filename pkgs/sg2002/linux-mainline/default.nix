# Mainline Linux for the SG2002.
#
# This is the *normal* nixpkgs kernel (`linux_latest`, which already
# carries NixOS's standard structured kernel config) with two things
# layered on via `.override`:
#
#   - kernelPatches  — the SG2002 SoC-support queue (see ./patches.nix).
#   - structuredExtraConfig — our add/remove deltas (see ./config.nix):
#     turn ON the SoC drivers + gadget stack + AIC8800 OOT bits, turn
#     OFF the desktop/server bloat the 256 MB board doesn't want.
#
# Replaces the old `linuxManualConfig` + hand-rendered `make defconfig`
# approach: NixOS's own kernel requirements now come from the base for
# free, and config.nix only has to express what's SG2002-specific.
# buildLinux applies the patches before generating the config, so
# patch-introduced Kconfig symbols referenced in config.nix resolve
# correctly (the reason the old path needed make-config.nix).
{
  lib,
  fetchurl,
  linux_latest,
  # nixpkgs re-.override's kernels with `features` / friends; tolerate
  # any extra args callPackage / linuxPackagesFor threads through.
  ...
}:
let
  source = import ./source.nix {inherit fetchurl;};
in
# Standard nixpkgs riscv64 kernel: buildLinux installs the uncompressed
# `Image` (kernelFile default) into $out on its own — no compress/install
# dance needed. We only layer on the SG2002 patch queue + config delta.
(linux_latest.override {
  argsOverride = {
    inherit (source) src version modDirVersion;
    extraMeta.branch = "7.2-rc";
  };
  # config.nix is the authoritative SG2002 delta, so force every entry
  # over the generic NixOS base (otherwise our `turn off` of e.g. DRM
  # collides with common-config's `yes` at equal priority).
  structuredExtraConfig = lib.mapAttrs (_: lib.mkForce) (
    import ./config.nix {inherit lib;}
  );
  kernelPatches = (import ./patches.nix).patches;
  # We prune hard against the full NixOS config; let olddefconfig drop
  # options whose deps we turned off instead of failing the build.
  ignoreConfigErrors = true;
})
