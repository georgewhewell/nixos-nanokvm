{
  lib,
  stdenv,
  buildGo125Module,
  nanokvm-factory-runtime,
  nanokvm-patched-src,
  nanokvm-web,
  patchelf,
  pkgsCross,
  # When true, build with `-tags nocamera` so the cgo binding in
  # server/common/kvm_vision.go is excluded and a no-op stub
  # (kvm_vision_stub.go, see patch 0002) is selected instead. This
  # keeps libkvm.so out of the link entirely — its ~20 C++ static
  # constructors fire from .init_array before main() on mainline
  # kernels and SEGV in SAMPLE_COMM_VI_ParseIni. Vendor 5.10 builds
  # leave this false to keep the working HDMI capture path.
  noCamera ? false,
  # Force the build target system regardless of stdenv.hostPlatform.
  # Needed because this Go package gets spliced to the *build* platform
  # in a cross NixOS config (so stdenv.hostPlatform.system reads
  # x86_64-linux even when the device is riscv64), which silently
  # produces a wrong-arch binary that dies 203/EXEC on the device. The
  # NixOS module passes "riscv64-linux" here. nocamera builds are pure
  # Go (CGO_ENABLED=0) so this is just a GOARCH cross-compile.
  targetSystem ? null,
}: let
  # Two build modes:
  #   - riscv64-cross: cross-compile from x86_64 host, link against
  #     pkgsCross.riscv64-musl and the C906-extension cgo flags.
  #     The riscv64-only path uses the Sipeed factory blobs
  #     (nanokvm-factory-runtime) at runtime for HDMI capture.
  #   - native: build for the build host (aarch64-linux on Rock-5B,
  #     x86_64-linux on a dev machine). No factory blobs, no
  #     C906-specific cgo flags. Forces `noCamera = true` because the
  #     libkvm.so / OpenCV runtime is riscv64-only.
  hostSys =
    if targetSystem != null
    then targetSystem
    else stdenv.hostPlatform.system;
  isRiscvCross = hostSys == "riscv64-linux";
  # Force noCamera on non-riscv64 — libkvm.so doesn't exist for the
  # target architecture and the cgo include path would fail anyway.
  effectiveNoCamera = noCamera || !isRiscvCross;

  # Toolchain selection.
  riscvMusl = pkgsCross.riscv64-musl;
  targetCc =
    if isRiscvCross
    then riscvMusl.stdenv.cc
    else null;
  targetRuntimeLibPath = lib.concatStringsSep ":" [
    "${riscvMusl.musl}/lib"
    "${riscvMusl.zlib}/lib"
    "${riscvMusl.stdenv.cc.cc.lib}/riscv64-unknown-linux-musl/lib"
  ];
  cgoCFlags = lib.concatStringsSep " " [
    "-mcpu=thead-c906"
    "-march=rv64gc_xtheadba_xtheadbb_xtheadbs_xtheadcmo_xtheadcondmov_xtheadfmemidx_xtheadmac_xtheadmemidx_xtheadmempair_xtheadsync"
    "-mcmodel=medany"
    "-mabi=lp64d"
  ];

  # System → GOARCH map for the native path. Add more as needed.
  goArchFor = system:
    {
      "x86_64-linux" = "amd64";
      "aarch64-linux" = "arm64";
      "riscv64-linux" = "riscv64";
    }
    .${system}
    or (throw "nanokvm-server: no GOARCH mapping for ${system}");
in
  buildGo125Module {
    pname = "nanokvm-server";
    version = "unstable";

    src = "${nanokvm-patched-src}/server";
    vendorHash = "sha256-feKyqcRKJ03WXWyRn2dGFBEjEGY5/Z5f2/BMFOO3Uvg=";

    nativeBuildInputs =
      lib.optionals isRiscvCross [
        patchelf
        targetCc
      ];

    dontPatchELF = true;

    env =
      {
        # With nocamera there is no `import "C"` left in the project,
        # so turn cgo off completely — that makes Go's internal linker
        # produce a fully static binary that doesn't go through musl
        # ld.so. Leaving CGO_ENABLED=1 with no cgo inputs makes the
        # internal linker lay DT_DEBUG inside the R-only LOAD segment;
        # musl's __dls3 then SEGVs trying to patch it at startup.
        CGO_ENABLED =
          if effectiveNoCamera
          then "0"
          else "1";
        GOOS = "linux";
        GOARCH = goArchFor hostSys;
        GOEXPERIMENT = "boringcrypto";
      }
      // lib.optionalAttrs isRiscvCross {
        CC = "${targetCc}/bin/riscv64-unknown-linux-musl-gcc";
        CGO_CFLAGS = cgoCFlags;
      };

    buildPhase =
      ''
        runHook preBuild

        export CGO_ENABLED=${
          if effectiveNoCamera
          then "0"
          else "1"
        }
        export GOOS=linux
        export GOARCH=${goArchFor hostSys}
        export GOEXPERIMENT=boringcrypto
      ''
      + lib.optionalString isRiscvCross ''
        export CC=${targetCc}/bin/riscv64-unknown-linux-musl-gcc
        export CGO_CFLAGS=${lib.escapeShellArg cgoCFlags}
        export CGO_LDFLAGS="-L$PWD/dl_lib -Wl,-rpath-link,$PWD/dl_lib -Wl,-rpath-link,${nanokvm-factory-runtime}/lib -Wl,-rpath-link,${riscvMusl.zlib}/lib -Wl,-rpath-link,${targetCc.cc.lib}/riscv64-unknown-linux-musl/lib"
      ''
      + ''

        go build -trimpath ${lib.optionalString effectiveNoCamera "-tags nocamera "}-o NanoKVM-Server .

        runHook postBuild
      '';

    installPhase = ''
      runHook preInstall

      serverDir="$out/lib/nanokvm/server"
      runtimeDir="$out/lib/nanokvm"

      install -Dm755 NanoKVM-Server "$serverDir/NanoKVM-Server"

      ${
        lib.optionalString (isRiscvCross && !effectiveNoCamera) ''
          # riscv64-only: ship the vendor C++ runtime blobs and
          # patchelf the rpath so libkvm.so can be dlopen'd.
          cp -a dl_lib "$serverDir/dl_lib"
          cp -a ${nanokvm-factory-runtime}/lib/*.so* "$serverDir/dl_lib/"
          chmod -R u+w "$serverDir/dl_lib"
        ''
      }

      cp -a ${nanokvm-web} "$serverDir/web"

      ${
        lib.optionalString isRiscvCross ''
          # Vendor runtime helpers — only meaningful for cv181x where
          # the factory userspace expects /kvmapp/system, ko modules,
          # kvm_system, etc. Aarch64/x86_64 deployments skip this.
          mkdir -p "$runtimeDir/system"
          cp -a ${nanokvm-patched-src}/kvmapp/system/. "$runtimeDir/system/"
          chmod u+w "$runtimeDir/system"
          chmod -R u+w "$runtimeDir/system/ko"
          rm -rf "$runtimeDir/system/ko"
          cp -a ${nanokvm-factory-runtime}/ko "$runtimeDir/system/ko"
          cp -a ${nanokvm-patched-src}/kvmapp/kvm_system "$runtimeDir/kvm_system"
          cp -a ${nanokvm-patched-src}/kvmapp/picoclaw "$runtimeDir/picoclaw"
        ''
      }

      ${
        lib.optionalString (isRiscvCross && !effectiveNoCamera) ''
          # Camera builds also carry the prebuilt kvm_system binary
          # (LT6911 bridge config / OLED UI / ATX buttons — capture
          # doesn't work without it; see nanokvm-factory-runtime for
          # provenance). The source kvm_system/ dir copied above only
          # holds a zero-byte kvm_stream placeholder — overlay the real
          # binary on top so the module's /kvmapp/kvm_system symlink
          # serves both. Its stock interpreter
          # (/lib/ld-musl-riscv64v0p7_xthead.so.1) and NEEDED libs
          # (libstdc++/libgcc_s/libc) don't exist on a NixOS rootfs;
          # point both at the same cross-musl runtime the server's
          # dl_lib rpath already uses. Keep $ORIGIN/dl_lib first for
          # fidelity with the stock rpath (the shipped dl_lib/ is
          # empty, but harmless).
          chmod -R u+w "$runtimeDir/kvm_system"
          cp -a ${nanokvm-factory-runtime}/kvm_system/. "$runtimeDir/kvm_system/"
          chmod u+w "$runtimeDir/kvm_system/kvm_system"
          patchelf \
            --set-interpreter "${riscvMusl.musl}/lib/ld-musl-riscv64.so.1" \
            --set-rpath "\$ORIGIN/dl_lib:${targetRuntimeLibPath}" \
            "$runtimeDir/kvm_system/kvm_system"

          # Sensor INI for the vendor capture SDK. libkvm_mmf.so's
          # SAMPLE_COMM_VI_ParseIni reads /mnt/data/sensor_cfg.ini at
          # kvmv_init time; the stock S95nanokvm refreshes it from the
          # .LT (Lontium LT6911) variant on every boot. Ship the
          # variants under lib/nanokvm/data so the NixOS compat unit
          # can install the .LT one the same way.
          mkdir -p "$runtimeDir/data"
          cp -a ${nanokvm-factory-runtime}/data/. "$runtimeDir/data/"
        ''
      }
      printf '%s\n' 'unstable' > "$runtimeDir/version"

      ${
        if isRiscvCross && !effectiveNoCamera
        then ''
          patchelf --set-rpath "\$ORIGIN/dl_lib:${targetRuntimeLibPath}" "$serverDir/NanoKVM-Server"
          while IFS= read -r so; do
            patchelf --set-rpath "\$ORIGIN:${targetRuntimeLibPath}" "$so" || true
          done < <(find "$serverDir/dl_lib" -type f -name '*.so*')
        ''
        else ''
          # nocamera (or native): fully static binary, no rpath work.
          :
        ''
      }

      mkdir -p "$out/bin"
      ln -s "$serverDir/NanoKVM-Server" "$out/bin/nanokvm-server"

      runHook postInstall
    '';

    doCheck = false;

    meta = {
      description =
        if isRiscvCross
        then "NanoKVM Go server cross-compiled for riscv64 musl"
        else "NanoKVM Go server (native ${hostSys}, no HDMI capture)";
      homepage = "https://github.com/sipeed/NanoKVM";
      license = lib.licenses.gpl3Only;
      mainProgram = "nanokvm-server";
      platforms = lib.platforms.linux;
    };
  }
