# Vendor AIC8800 SDIO WiFi+BT driver from Sipeed's osdrv tree.
# Three siblings: aic8800_bsp (bootloader), aic8800_fdrv (wifi),
# aic8800_btlpm (bluetooth low-power). Builds only against the vendor
# 5.10 kernel (or any kernel with 5.10-era API — the mainline tree
# needs the radxa-pkg variant below).
{
  stdenv,
  lib,
  kernel,
  licheerv-nano-build,
}:
stdenv.mkDerivation {
  pname = "aic8800-vendor-drv";
  version = "20260331-${kernel.modDirVersion}";

  src = "${licheerv-nano-build}/osdrv/extdrv/wireless/aic8800";
  # osdrv tree has aic8800_bsp/, aic8800_btlpm/, aic8800_fdrv/ as
  # top-level siblings with one umbrella Makefile — no sourceRoot.

  nativeBuildInputs = kernel.moduleBuildDependencies;

  # Vendor Makefile is an `obj-m` kbuild wrapper — doesn't respect
  # nixpkgs' hardening flags (CFLAGS come from the kernel build system).
  hardeningDisable = ["pic" "format"];

  # SDIO default (CONFIG_SDIO_SUPPORT=y, CONFIG_USB_SUPPORT=n) matches
  # AIC8800DC on the Nano-W. The CONFIG_PLATFORM_UBUNTU=y branch detects
  # ARCH from `uname -m` (the build host, x86_64); force ARCH=riscv.
  # KDIR=ktree is a writable copy of the kernel build tree (kbuild may
  # want to write into it).
  makeFlags = [
    "KDIR=ktree"
    "KVER=${kernel.modDirVersion}"
    "ARCH=riscv"
    "CROSS_COMPILE=${stdenv.cc.targetPrefix}"
  ];

  preBuild = ''
    cp -rp ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build ktree
    chmod -R u+w ktree
  '';

  installPhase = ''
    runHook preInstall
    D=$out/lib/modules/${kernel.modDirVersion}/kernel/drivers/net/wireless/aic8800
    mkdir -p $D
    for ko in aic8800_bsp aic8800_btlpm aic8800_fdrv; do
      path=$(find . -name "$ko.ko" -print -quit)
      [ -n "$path" ] || { echo "ERROR: $ko.ko not found" >&2; exit 1; }
      install -m 644 "$path" "$D/"
    done
    runHook postInstall
  '';

  meta = {
    description = "AIC8800 SDIO wifi+BT driver (Sipeed osdrv, 5.10-era APIs)";
    homepage = "https://github.com/sipeed/LicheeRV-Nano-Build";
    license = lib.licenses.gpl2Plus;
    platforms = ["riscv64-linux"];
  };
}
