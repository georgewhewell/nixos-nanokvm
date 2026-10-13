# Mainline Linux for the SG2002.
#
# This uses nixpkgs' 7.2 source/build machinery with the RISC-V
# defconfig as its small base.  NixOS's generic common config is deliberately
# disabled: it enables thousands of unrelated modules on this 256 MiB SoC.
# Two SG2002-specific pieces are layered on via `.override`:
#
#   - kernelPatches  — the SG2002 SoC-support queue (see ./patches.nix).
#   - structuredExtraConfig — our add/remove deltas (see ./config.nix):
#     turn ON the SoC drivers + gadget stack + AIC8800 OOT bits, turn
#     OFF anything from defconfig that the 256 MB board doesn't want.
#
# This retains nixpkgs' cross-build, patch, config-check, module and output
# handling without inheriting the workstation/server-oriented common config.
# buildLinux applies the patches before generating the config, so
# patch-introduced Kconfig symbols referenced in config.nix resolve
# correctly (the reason the old path needed make-config.nix).
{
  lib,
  stdenv,
  linux_7_2,
  bluetooth ? false,
  # Temperature injection is a diagnostic control, independent of profiling.
  thermalEmulation ? false,
  # nixpkgs re-.override's kernels with `features` / friends; tolerate
  # any extra args callPackage / linuxPackagesFor threads through.
  ...
}:
# Standard nixpkgs riscv64 kernel: buildLinux installs the uncompressed
# `Image` (kernelFile default) into $out on its own — no compress/install
# dance needed. We only layer on the SG2002 patch queue + config delta.
(linux_7_2.override {
  defconfig = "defconfig";
  enableCommonConfig = false;
  autoModules = false;
  argsOverride = {
    extraMeta.branch = "7.2";
  };
  structuredExtraConfig = (import ./config.nix {inherit lib;})
    // lib.optionalAttrs thermalEmulation {
      # Test the thermal cooling map without physically overheating a board.
      # Normal images do not expose the temperature-emulation interface.
      THERMAL_EMULATION = lib.kernel.yes;
    }
    // lib.optionalAttrs bluetooth {
    # AIC8800 FDRV provides HCI_SDIO itself; the kernel needs only the
    # Bluetooth core and the BR/EDR + LE protocols for BlueZ discovery.
    # BNEP is the kernel data path for BlueZ's Bluetooth PAN profile.
    BT = lib.kernel.module;
    BT_BREDR = lib.kernel.yes;
    BT_LE = lib.kernel.yes;
    # BlueZ's native HSP/HFP roles register RFCOMM service records.  Keep the
    # transport modular and omit RFCOMM_TTY: bluetoothd needs the socket
    # protocol, not serial tty emulation.
    BT_RFCOMM = lib.kernel.module;
    BT_BNEP = lib.kernel.module;
    BT_BNEP_MC_FILTER = lib.kernel.yes;
    BT_BNEP_PROTO_FILTER = lib.kernel.yes;
  };
  kernelPatches = (import ./patches.nix).patches;
  # nixpkgs deliberately invokes the unwrapped kernel compiler, so the
  # target cc-wrapper's scheduling defaults do not reach Kbuild. KCFLAGS
  # applies to built-in C code and modules, without affecting host tools.
  extraMakeFlags = lib.optionals
    (stdenv.cc.isGNU && stdenv.hostPlatform.gcc ? tune)
    [ "KCFLAGS=-mtune=${stdenv.hostPlatform.gcc.tune}" ];
  # Let olddefconfig drop options whose dependencies are unavailable.
  ignoreConfigErrors = true;
})
