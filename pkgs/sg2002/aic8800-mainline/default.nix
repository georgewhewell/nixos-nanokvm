# Mainline-kernel-compatible AIC8800DC SDIO wifi+BT driver.
#
# Sourced from radxa-pkg/aic8800, which tracks modern kernel API
# changes. The `debian/patches/series` covers everything needed to
# build against the current mainline tree (Linux 7.0 ≈ 6.19+ in the
# old numbering):
#   - fix-linux-6.{1,5,7,9,13,14,15,16,17,19}-build.patch (kernel API compat)
#   - fix-map-riscv64-subarch.patch (`uname -m` for cross-compile)
#   - fix-vmalloc-not-include.patch
#   - fix-sdio-fall-through.patch
#
# The firmware-path patch in-tree points at
# /lib/firmware/aic8800_fw/SDIO/aic8800D80/ which doesn't match our
# layout (lxowalle blobs land under /lib/firmware/aic8800_sdio/
# aic8800DC/...), so we skip that one and substitute our own path at
# build time via postPatch.
{
  stdenv,
  lib,
  buildPackages,
  kernel,
  firmware,
  src, # radxa-pkg/aic8800 tree, passed in from the flake input
}: let

  patchSeries = [
    "fix-sdio-fall-through.patch"
    "fix-debug-file-with-no-debug-symbols.patch"
    "fix-linux-6.1-build.patch"
    "fix-linux-6.7-build.patch"
    "fix-linux-6.5-build.patch"
    "fix-linux-6.9-build.patch"
    "fix-linux-6.13-build.patch"
    "fix-linux-6.14-build.patch"
    "fix-linux-6.15-build.patch"
    "fix-linux-6.16-build.patch"
    "fix-linux-6.17-build.patch"
    "fix-linux-6.19-build.patch"
    "fix-map-riscv64-subarch.patch"
    "fix-vmalloc-not-include.patch"
    "fix-build-on-low-memory-devices.patch"
    "fix-Lower-the-debugging-log-level.patch"
  ];
in
  stdenv.mkDerivation {
    pname = "aic8800-mainline-drv";
    version = "5.0-radxa-${kernel.modDirVersion}";

    inherit src;
    sourceRoot = "source/src/SDIO/driver_fw/driver/aic8800";

    nativeBuildInputs =
      kernel.moduleBuildDependencies
      ++ [buildPackages.patchutils]; # filterdiff for the SDIO-only patch slice

    hardeningDisable = ["pic" "format"];

    # Apply radxa's quilt series from the parent checkout. The patches
    # cover PCIe + USB + SDIO subtrees; we only build SDIO (see
    # `sourceRoot` above). Use filterdiff to slice each patch to just
    # the SDIO hunks before applying — that way real failures fail the
    # build instead of being silenced by a blanket `|| true`. Patches
    # with no SDIO hunks are skipped.
    postUnpack = ''
      (
        cd source
        chmod -R u+w .
        for p in ${lib.escapeShellArgs patchSeries}; do
          tmp=$(mktemp)
          filterdiff --include='*/src/SDIO/*' "debian/patches/$p" > "$tmp"
          if [ ! -s "$tmp" ]; then
            echo ">>> skipping debian/patches/$p (no SDIO hunks)"
            rm -f "$tmp"
            continue
          fi
          echo ">>> applying debian/patches/$p (SDIO-only slice)"
          # `-l` ignores whitespace/line-ending mismatches (some files
          # are CRLF).
          patch -p1 -l < "$tmp"
          rm -f "$tmp"
        done
        # Our own debug logging around the DBG_START_APP_REQ path so we
        # can see what fw_addr/boot_type the driver is handing to firmware
        # before the current cmd-1037 timeout.
        patch -p1 < ${./patches/aic8800-log-startapp.patch}
      )
    '';

    # Point the driver at our firmware layout. lxowalle ships aic8800DC
    # blobs under .../aic8800_sdio/aic8800DC/*.
    postPatch = ''
      for mk in aic8800_bsp/Makefile aic8800_fdrv/Makefile; do
        sed -i 's|"/vendor/etc/firmware"|"/lib/firmware/aic8800_sdio/aic8800DC"|' "$mk"
      done
    '';

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
      description = "AIC8800DC SDIO wifi+BT driver (radxa-pkg fork, mainline-kernel-compat)";
      homepage = "https://github.com/radxa-pkg/aic8800";
      license = lib.licenses.gpl2Plus;
      platforms = ["riscv64-linux"];
    };
  }
