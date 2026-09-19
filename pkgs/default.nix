# Overlay for everything this flake adds to nixpkgs.
#
# Three halves:
#   1. `spacemit-k3-*` — board-support for SpacemiT K3 systems.
#   2. `sg2002-*` — board-support for the Sophgo CV181x family
#      (kernel builds, FIP, OpenSBI, U-Boot, AIC8800 driver/firmware,
#      USB-recovery tool, DTBs). Inlined here from nixos-sg2002 so
#      this repo is self-contained.
#   3. `nanokvm-*` — the userspace bits (the Go server, the web
#      bundle, the erofs rootfs builder, the kexec payload format)
#      that turn a CV181x board into a working KVM.
{ inputs
, nanokvmPatches ? [ ]
,
}: final: prev:
let
  inherit (final) lib;

  # Cross-compile context. When the overlay is applied to riscv64
  # pkgs (NixOS hostPlatform=riscv64) `final` already is the cross
  # set; on x86_64 build-host evaluation `pkgsCross.riscv64` is the
  # equivalent.
  cross =
    if final.stdenv.hostPlatform.isRiscV64
    then final
    else final.pkgsCross.riscv64;

  mainlineLinuxSource = final.buildPackages.callPackage ./sg2002/linux-mainline/source.nix { };
  dtbMainline = final.buildPackages.callPackage ./sg2002/dtb-mainline {
    linuxSrc = mainlineLinuxSource.src;
  };
  dtbVendor = final.buildPackages.callPackage ./sg2002/dtb-vendor {
    licheerv-nano-build = inputs.licheerv-nano-build;
  };

  riscv64Embedded = final.buildPackages.pkgsCross.riscv64-embedded;
  c906lRustPlatform = final.buildPackages.callPackage ./sg2002/c906l-rust-platform.nix {
    inherit riscv64Embedded;
  };
  c906lContractFor = peripherals:
    final.buildPackages.callPackage ./sg2002/c906l-contract {
      inherit peripherals;
    };
  c906lContractLib = import ./sg2002/c906l-contract/lib.nix { inherit lib; };
  # Named profiles live in contract.json.  Consumers which need a complete
  # package family resolve through this manifest instead of copying lease
  # lists into every alias and check.
  c906lProfileManifest = lib.mapAttrs
    (name: profile: {
      inherit name;
      peripherals = profile.sortedPeripherals;
      contractSha256 = profile.sha256;
      inherit (profile) profileId leaseMask;
    })
    c906lContractLib.profiles;
  c906lPeripheralsForProfile = name:
    if builtins.hasAttr name c906lProfileManifest then
      c906lProfileManifest.${name}.peripherals
    else
      throw "unknown SG2002 C906L profile `${name}`";
  c906lMemoryMap = import ./sg2002/c906l-memory-map.nix { inherit lib; };

in
(import ./sg2002/c906-tuning.nix final prev) // {
  # -----------------------------------------------------------------
  # nixpkgs adjustments
  # -----------------------------------------------------------------

  kexec-tools =
    if final.stdenv.hostPlatform.system == "riscv64-linux"
    then
      prev.kexec-tools.overrideAttrs
        (old: {
          meta =
            (old.meta or { })
            // {
              # kexec-tools 2.0.32 builds for riscv64; nixpkgs still
              # carries a stale badPlatforms entry for this target.
              badPlatforms = lib.remove "riscv64-linux" (old.meta.badPlatforms or [ ]);
            };
        })
    else prev.kexec-tools;

  # vmtouch's Makefile invokes `pod2man` to render the manpage, but the
  # cross stdenv doesn't carry perl. Skip the manpage and only install
  # the binary — that's all `prepare-kexec-stage.service` needs.
  vmtouch =
    if final.stdenv.hostPlatform.system == "riscv64-linux"
    then
      prev.vmtouch.overrideAttrs
        (old: {
          buildPhase = ''
            runHook preBuild
            $CC -Wall -O2 -g -std=c99 -o vmtouch vmtouch.c
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            install -Dm755 vmtouch "$out/bin/vmtouch"
            runHook postInstall
          '';
        })
    else prev.vmtouch;

  # -----------------------------------------------------------------
  # spacemit-k3-* (board support)
  # -----------------------------------------------------------------

  "spacemit-k3-linux" = cross.callPackage ./spacemit-k3/linux {
    kernelPatches = [ ];
  };
  "linuxPackages_spacemit-k3" = cross.linuxPackagesFor final."spacemit-k3-linux";
  "spacemit-k3-fsbl" = cross.callPackage ./spacemit-k3/fsbl { };
  "spacemit-k3-rtw89-firmware" = final.callPackage ./spacemit-k3/rtw89-firmware { };
  "spacemit-k3-uefi-blobs" = final.callPackage ./spacemit-k3/uefi-blobs { };
  "spacemit-k3-raw-fastboot-boot" = final.callPackage ./spacemit-k3/raw-fastboot-boot { };
  "spacemit-k3-flash-uefi" = final.callPackage ./spacemit-k3/flash-uefi {
    uefiBlobs = final."spacemit-k3-uefi-blobs";
  };

  # -----------------------------------------------------------------
  # nanokvm-* (userspace KVM stack)
  # -----------------------------------------------------------------

  nanokvm-patched-src = final.callPackage ./nanokvm-patched-src {
    src = inputs.nanokvm-src;
    patches = nanokvmPatches;
  };

  # Static web assets are built on the build host and copied into the
  # target server package; do not cross-build Node/V8 for riscv64.
  nanokvm-web = final.buildPackages.callPackage ./nanokvm-web {
    nanokvm-patched-src = final.nanokvm-patched-src;
  };
  nanokvm-factory-runtime = final.callPackage ./nanokvm-factory-runtime { };
  sg2002-coda980-firmware = final.callPackage ./sg2002/coda980-firmware { };
  nanokvm-server = final.callPackage ./nanokvm-server { };

  # Build with -tags nocamera so libkvm.so isn't linked in at all —
  # its C++ static constructors SEGV in SAMPLE_COMM_VI_ParseIni when
  # run against a mainline kernel.
  nanokvm-server-nocamera = final.nanokvm-server.override { noCamera = true; };

  # Device server, forced to riscv64. Must be instantiated via
  # buildPackages.callPackage (build host) with an explicit targetSystem,
  # NOT `.override` on the cross-spliced pkgs.nanokvm-server — the splice
  # silently drops override args, so that path builds an x86_64 binary
  # that dies 203/EXEC on the device. nocamera = pure-Go cross-compile.
  nanokvm-server-device = final.callPackage ./nanokvm-server {
    noCamera = true;
    targetSystem = "riscv64-linux";
  };

  # Device server with the camera/HDMI capture path compiled in —
  # the build the vendor-kernel images run. Same forced-riscv64
  # instantiation rationale as nanokvm-server-device above; the only
  # difference is noCamera = false, which keeps the kvm_vision cgo
  # binding (libkvm.so) linked in and ships the vendor dl_lib blobs,
  # the prebuilt kvm_system binary, and the LT6911 sensor INI. Only
  # safe with sg2002.kernel = "vendor": libkvm.so's C++ static ctors
  # SEGV under mainline (see nanokvm-server-nocamera above).
  nanokvm-server-device-camera = final.callPackage ./nanokvm-server {
    noCamera = false;
    targetSystem = "riscv64-linux";
  };



  sophgo-host-tools = final.callPackage ./sophgo-host-tools { };

  # -----------------------------------------------------------------
  # sg2002-* (board support, inlined from nixos-sg2002)
  # -----------------------------------------------------------------

  # Mainline OpenSBI with our U-Boot DTB baked in so OpenSBI has an
  # FDT even when the FSBL doesn't pass one via fw_dynamic_info.
  sg2002-opensbi-mainline-for = uboot:
    cross.opensbi.override {
      withFDT = "${uboot}/u-boot.dtb";
    };
  sg2002-opensbi-mainline = final.sg2002-opensbi-mainline-for cross.sg2002-uboot-mainline;

  # Keep the pinned source visible for consumers that need its data blobs,
  # and package our fail-safe executable separately.  Upstream's script
  # otherwise starts its bundled RTOS at a hard-coded, board-wrong address.
  sg2002-sophgo-fiptool = inputs.sophgo-fiptool;
  sg2002-fiptool = final.buildPackages.callPackage ./sg2002/fiptool {
    src = inputs.sophgo-fiptool;
  };

  # The C906L is a bare-metal target, so it needs the newlib/ELF toolchain,
  # not the riscv64-linux cross compiler used by the kernel and userspace.
  sg2002-c906l-contract-for = c906lContractFor;
  sg2002-c906l-profile-manifest = c906lProfileManifest;
  sg2002-c906l-contract-for-profile = name:
    final.sg2002-c906l-contract-for (c906lPeripheralsForProfile name);
  sg2002-c906l-contract = final.sg2002-c906l-contract-for [ ];
  sg2002-c906l-contract-timer4 =
    final.sg2002-c906l-contract-for [ "timer4" ];
  sg2002-c906l-contract-timer5 =
    final.sg2002-c906l-contract-for [ "timer5" ];
  sg2002-c906l-contract-timer6 =
    final.sg2002-c906l-contract-for [ "timer6" ];
  sg2002-c906l-contract-timer7 =
    final.sg2002-c906l-contract-for [ "timer7" ];
  sg2002-c906l-contract-all-timers =
    final.sg2002-c906l-contract-for-profile "all-timers";
  sg2002-c906l-rust-for = peripherals:
    let
      contract = final.sg2002-c906l-contract-for peripherals;
    in
    (riscv64Embedded.callPackage ./sg2002/c906l-firmware/rust.nix {
      inherit contract;
      rustPlatform = c906lRustPlatform;
    }).overrideAttrs
      (old: {
        # rustPlatform intersects package platforms with rustc's hosted
        # platform list, which omits LLVM's supported riscv64-none target.
        meta = (old.meta or { }) // { platforms = [ "riscv64-none" ]; };
      });
  sg2002-c906l-rust = final.sg2002-c906l-rust-for [ ];
  sg2002-c906l-rust-timer4 = final.sg2002-c906l-rust-for [ "timer4" ];
  sg2002-c906l-rust-timer5 = final.sg2002-c906l-rust-for [ "timer5" ];
  sg2002-c906l-rust-timer6 = final.sg2002-c906l-rust-for [ "timer6" ];
  sg2002-c906l-rust-timer7 = final.sg2002-c906l-rust-for [ "timer7" ];
  sg2002-c906l-rust-all-timers =
    final.sg2002-c906l-rust-for
      (c906lPeripheralsForProfile "all-timers");
  sg2002-c906l-rust-tests-for = peripherals:
    final.buildPackages.callPackage ./sg2002/c906l-firmware/rust-tests.nix {
      contract = final.sg2002-c906l-contract-for peripherals;
    };
  sg2002-c906l-rust-tests = final.sg2002-c906l-rust-tests-for [ ];
  sg2002-c906l-rust-tests-timer4 =
    final.sg2002-c906l-rust-tests-for [ "timer4" ];
  sg2002-c906l-rust-tests-timer5 =
    final.sg2002-c906l-rust-tests-for [ "timer5" ];
  sg2002-c906l-rust-tests-timer6 =
    final.sg2002-c906l-rust-tests-for [ "timer6" ];
  sg2002-c906l-rust-tests-timer7 =
    final.sg2002-c906l-rust-tests-for [ "timer7" ];
  sg2002-c906l-rust-tests-all-timers =
    final.sg2002-c906l-rust-tests-for
      (c906lPeripheralsForProfile "all-timers");
  sg2002-c906l-control-for = kernel: contract:
    cross.callPackage ./sg2002/c906l-control { inherit contract kernel; };
  sg2002-c906l-framebuffer-for = kernel: contract:
    cross.callPackage ./sg2002/c906l-framebuffer { inherit contract kernel; };
  sg2002-c906l-wifi-power-for = kernel: contract:
    cross.callPackage ./sg2002/c906l-wifi-power { inherit contract kernel; };
  sg2002-c906l-remoteproc-for = kernel: contract:
    cross.callPackage ./sg2002/c906l-remoteproc { inherit contract kernel; };
  sg2002-c906l-ctl-for = contract:
    final.callPackage ./sg2002/c906l-cli {
      inherit contract;
    };
  sg2002-c906l-ctl =
    final.sg2002-c906l-ctl-for final.sg2002-c906l-contract;
  sg2002-c906l-ctl-timer4 =
    final.sg2002-c906l-ctl-for final.sg2002-c906l-contract-timer4;
  sg2002-c906l-ctl-timer5 =
    final.sg2002-c906l-ctl-for final.sg2002-c906l-contract-timer5;
  sg2002-c906l-ctl-timer6 =
    final.sg2002-c906l-ctl-for final.sg2002-c906l-contract-timer6;
  sg2002-c906l-ctl-timer7 =
    final.sg2002-c906l-ctl-for final.sg2002-c906l-contract-timer7;
  sg2002-c906l-ctl-all-timers =
    final.sg2002-c906l-ctl-for final.sg2002-c906l-contract-all-timers;
  sg2002-c906l-firmware-for = peripherals:
    let
      contract = final.sg2002-c906l-contract-for peripherals;
    in
    final.buildPackages.callPackage ./sg2002/c906l-firmware {
      inherit contract riscv64Embedded;
      sg2002-c906l-rust = final.sg2002-c906l-rust-for peripherals;
    };
  sg2002-c906l-firmware = final.sg2002-c906l-firmware-for [ ];
  sg2002-c906l-firmware-timer4 =
    final.sg2002-c906l-firmware-for [ "timer4" ];
  sg2002-c906l-firmware-timer5 =
    final.sg2002-c906l-firmware-for [ "timer5" ];
  sg2002-c906l-firmware-timer6 =
    final.sg2002-c906l-firmware-for [ "timer6" ];
  sg2002-c906l-firmware-timer7 =
    final.sg2002-c906l-firmware-for [ "timer7" ];
  sg2002-c906l-firmware-all-timers =
    final.sg2002-c906l-firmware-for
      (c906lPeripheralsForProfile "all-timers");

  # One resolver for every artifact which must carry the same immutable
  # contract.  Compatibility aliases above and below remain available, while
  # new profiles need only one contract.json entry plus any desired catalog
  # leaf.
  sg2002-c906l-package-set-for-profile = name:
    let
      profile = c906lProfileManifest.${name}
        or (throw "unknown SG2002 C906L profile `${name}`");
      inherit (profile) peripherals;
      contract = final.sg2002-c906l-contract-for-profile name;
      firmware = final.sg2002-c906l-firmware-for peripherals;
      fipUboot = final.sg2002-fip-mainline-uboot-for firmware;
      fipFastboot = final.sg2002-fip-mainline-fastboot-for firmware;
    in
    {
      inherit profile peripherals contract firmware fipUboot fipFastboot;
      rust = final.sg2002-c906l-rust-for peripherals;
      rustTests = final.sg2002-c906l-rust-tests-for peripherals;
      ctl = final.sg2002-c906l-ctl-for contract;
      controlFor = kernel: final.sg2002-c906l-control-for kernel contract;
      remoteprocFor = kernel:
        final.sg2002-c906l-remoteproc-for kernel contract;
      dtb = final.sg2002-dtb-mainline-nowifi-c906l-for contract;
      pcieDtb = final.sg2002-dtb-mainline-pcie-nowifi-c906l-for contract;
      usbBoot = final.sg2002-usb-boot-for fipFastboot;
    };

  # Vendor FIP (FSBL + vendor OpenSBI + vendor U-Boot) extracted from
  # a known-good Sipeed SD image. ROM loads fip.bin from FAT partition;
  # we lift it back out with mcopy so we have a working FSBL+DDR blob
  # baseline for the mainline-uboot rebuild below.
  sg2002-fip =
    let
      sipeedImage = final.fetchurl {
        url = "https://github.com/sipeed/LicheeRV-Nano-Build/releases/download/20251202/2025-12-02-16-54-27b96a.img.xz";
        hash = "sha256-D9jDObp9/luqVZ/907bt8WkQVMhj4+LsaV/cZA0y/No=";
      };
    in
    final.runCommand "fip-sg2002"
      {
        # buildPackages: these run on the build host, not the riscv64
        # target.
        nativeBuildInputs = with final.buildPackages; [ xz mtools ];
      } ''
      mkdir -p $out
      xz -dc ${sipeedImage} | dd bs=1M count=20 iflag=fullblock of=image.bin status=none
      dd if=image.bin of=fat.img bs=512 skip=1 count=32768 status=none
      mcopy -i fat.img -n ::fip.bin $out/fip.bin
    '';

  # Vendor FSBL/DDR + mainline OpenSBI + mainline U-Boot, repacked
  # via sophgo's fiptool. This is what the USB recovery flow loads.
  sg2002-fip-mainline-uboot = final.callPackage ./sg2002/fip-mainline-uboot {
    sg2002-fip = final.sg2002-fip;
    sg2002-opensbi-mainline = cross.sg2002-opensbi-mainline;
    sg2002-uboot-mainline = cross.sg2002-uboot-mainline;
  };
  sg2002-fip-mainline-uboot-for = rtosFirmware:
    let
      uboot = cross.sg2002-uboot-mainline-for rtosFirmware;
    in
    final.callPackage ./sg2002/fip-mainline-uboot {
      sg2002-fip = final.sg2002-fip;
      sg2002-opensbi-mainline = final.sg2002-opensbi-mainline-for uboot;
      sg2002-uboot-mainline = uboot;
      inherit rtosFirmware;
    };
  sg2002-fip-mainline-uboot-c906l =
    final.sg2002-fip-mainline-uboot-for final.sg2002-c906l-firmware;
  sg2002-fip-mainline-uboot-c906l-timer4 =
    final.sg2002-fip-mainline-uboot-for final.sg2002-c906l-firmware-timer4;
  sg2002-fip-mainline-uboot-c906l-timer5 =
    final.sg2002-fip-mainline-uboot-for final.sg2002-c906l-firmware-timer5;
  sg2002-fip-mainline-uboot-c906l-timer6 =
    final.sg2002-fip-mainline-uboot-for final.sg2002-c906l-firmware-timer6;
  sg2002-fip-mainline-uboot-c906l-timer7 =
    final.sg2002-fip-mainline-uboot-for final.sg2002-c906l-firmware-timer7;
  sg2002-fip-mainline-uboot-c906l-all-timers =
    final.sg2002-fip-mainline-uboot-for
      final.sg2002-c906l-firmware-all-timers;
  sg2002-fip-mainline-fastboot = final.callPackage ./sg2002/fip-mainline-uboot {
    sg2002-fip = final.sg2002-fip;
    sg2002-opensbi-mainline = cross.sg2002-opensbi-mainline;
    sg2002-uboot-mainline = cross.sg2002-uboot-mainline-fastboot;
  };
  sg2002-fip-mainline-fastboot-for = rtosFirmware:
    let
      uboot = cross.sg2002-uboot-mainline-fastboot-for rtosFirmware;
    in
    final.callPackage ./sg2002/fip-mainline-uboot {
      sg2002-fip = final.sg2002-fip;
      sg2002-opensbi-mainline = final.sg2002-opensbi-mainline-for uboot;
      sg2002-uboot-mainline = uboot;
      inherit rtosFirmware;
    };
  sg2002-fip-mainline-fastboot-c906l =
    final.sg2002-fip-mainline-fastboot-for final.sg2002-c906l-firmware;
  sg2002-fip-mainline-fastboot-c906l-timer4 =
    final.sg2002-fip-mainline-fastboot-for final.sg2002-c906l-firmware-timer4;
  sg2002-fip-mainline-fastboot-c906l-timer5 =
    final.sg2002-fip-mainline-fastboot-for final.sg2002-c906l-firmware-timer5;
  sg2002-fip-mainline-fastboot-c906l-timer6 =
    final.sg2002-fip-mainline-fastboot-for final.sg2002-c906l-firmware-timer6;
  sg2002-fip-mainline-fastboot-c906l-timer7 =
    final.sg2002-fip-mainline-fastboot-for final.sg2002-c906l-firmware-timer7;
  sg2002-fip-mainline-fastboot-c906l-all-timers =
    final.sg2002-fip-mainline-fastboot-for
      final.sg2002-c906l-firmware-all-timers;
  # PicoClaw's ST7789 needs the Ethernet-pad handoff before fastboot starts.
  # Keep this complete U-Boot/OpenSBI/FIP chain separate from every generic
  # SG2002 image so those images cannot write the panel's pins.
  sg2002-opensbi-mainline-picoclaw-splash = cross.opensbi.override {
    withFDT = "${cross.sg2002-uboot-mainline-picoclaw-splash}/u-boot.dtb";
  };
  sg2002-fip-mainline-picoclaw-splash = final.callPackage ./sg2002/fip-mainline-uboot {
    sg2002-fip = final.sg2002-fip;
    sg2002-opensbi-mainline = cross.sg2002-opensbi-mainline-picoclaw-splash;
    sg2002-uboot-mainline = cross.sg2002-uboot-mainline-picoclaw-splash;
  };

  # AIC8800DC firmware blobs (Nano-W onboard WiFi+BT). passthru
  # `compressFirmware=false` because aicbsp's rwnx_load_firmware uses
  # filp_open on the literal .bin filename — the .zst suffix nixpkgs
  # would add breaks the driver's open().
  sg2002-aic8800-firmware =
    final.runCommand "aic8800-firmware"
      {
        passthru.compressFirmware = false;
      } ''
      mkdir -p $out/lib/firmware/aic8800_sdio
      cp -rL ${inputs.aic8800-firmware-src}/* $out/lib/firmware/aic8800_sdio/
      chmod -R u+w $out/lib/firmware/aic8800_sdio

      cd $out/lib/firmware/aic8800_sdio/aic8800DC
      # The Nano-W radio identifies as AIC8800D80 (SDIO 0xc8a1:0x0082),
      # while the Radxa driver is deliberately built with this compatibility
      # directory as CONFIG_AIC_FW_PATH. Expose the complete D80 set here;
      # keep any DC-specific file that already exists under the same name.
      for blob in ../aic8800_and_aic8800D80/*; do
        name="''${blob##*/}"
        test -e "$name" || ln -s "$blob" "$name"
      done
      ln -sfn ../aic8800_and_aic8800D80/fw_adid_u03.bin         fw_adid_u03.bin
      ln -sfn ../aic8800_and_aic8800D80/fw_patch_u03.bin        fw_patch_u03.bin
      ln -sfn ../aic8800_and_aic8800D80/fw_patch_table_u03.bin  fw_patch_table_u03.bin
      ln -sfn ../aic8800_and_aic8800D80/fmacfw.bin              fmacfw.bin
      ln -sfn ../aic8800_and_aic8800D80/fmacfw_patch.bin        fmacfw_patch.bin
      ln -sfn aic_userconfig_8800dc.txt                         aic_userconfig.txt
    '';

  # Sophgo CV181x USB download tool (cv181x-dl + cv181x-rom-dl). Used
  # by the USB-recovery boot flow to FSBL-stream FIP+kernel+initrd.
  sg2002-cv181x-usb-dl =
    let
      pythonEnv = final.python3.withPackages (ps: [ ps.pyserial ps.pyusb ]);
    in
    final.stdenv.mkDerivation {
      pname = "cv181x-usb-dl";
      version = "0.1.0";
      src = "${inputs.licheerv-nano-build}/build/tools/cv181x/usb_dl";
      nativeBuildInputs = [ final.buildPackages.makeWrapper final.buildPackages.python3 ];

      # Upstream cv181x_rom_usb_download.py drops into an infinite
      # "Connecting to ROM 2nd stage..." loop after pushing the first
      # FIP chunk + TX_FLAG + BREAK, polling for vendor `cvi_utask`
      # which never appears with mainline U-Boot. The wrapper that
      # invokes this tool (`usb_boot_mainline.py`) wants the rom-dl
      # process to *exit* once the FIP push is done so it can move on
      # to fastboot enumeration. Patch: short-circuit the 2nd-stage
      # loop to `sys.exit(0)` immediately after BREAK. Bytes-for-bytes
      # of FIP go through unchanged; we just skip the dead polling.
      postPatch = ''
        # Applies the pyserial fast-open / short-timeout / flushOutput-EIO
        # fixes (and, if ever re-enabled, the 2nd-stage skip).
        python3 ${./sg2002-cv181x-rom-dl-skip-2nd-stage.py} \
          rom_usb_dl/cv181x_rom_usb_download.py
      '';

      installPhase = ''
        mkdir -p $out/lib/cv181x-usb-dl $out/bin
        cp -r rom_usb_dl     $out/lib/cv181x-usb-dl/
        cp cv181x_dl.py      $out/lib/cv181x-usb-dl/
        makeWrapper ${pythonEnv}/bin/python3 $out/bin/cv181x-dl \
          --add-flags "$out/lib/cv181x-usb-dl/cv181x_dl.py" \
          --prefix PYTHONPATH : "$out/lib/cv181x-usb-dl:$out/lib/cv181x-usb-dl/rom_usb_dl"
        makeWrapper ${pythonEnv}/bin/python3 $out/bin/cv181x-rom-dl \
          --add-flags "$out/lib/cv181x-usb-dl/rom_usb_dl/cv181x_rom_usb_download.py" \
          --prefix PYTHONPATH : "$out/lib/cv181x-usb-dl/rom_usb_dl"
        makeWrapper ${pythonEnv}/bin/python3 $out/bin/cv181x-uboot-dl \
          --add-flags "$out/lib/cv181x-usb-dl/rom_usb_dl/cv181x_uboot_usb_download.py" \
          --prefix PYTHONPATH : "$out/lib/cv181x-usb-dl/rom_usb_dl"
      '';
    };

  sg2002-uboot-mainline = cross.callPackage ./sg2002/uboot-mainline { };
  sg2002-uboot-mainline-for = rtosFirmware:
    cross.sg2002-uboot-mainline.override {
      memoryTopHide = c906lMemoryMap.dramEnd - rtosFirmware.firmwareAddress;
    };
  sg2002-uboot-mainline-c906l =
    final.sg2002-uboot-mainline-for final.sg2002-c906l-firmware;
  sg2002-uboot-mainline-fastboot = cross.sg2002-uboot-mainline.override {
    bootCommand = "fastboot usb 0";
  };
  sg2002-uboot-mainline-fastboot-for = rtosFirmware:
    cross.sg2002-uboot-mainline.override {
      bootCommand = "fastboot usb 0";
      memoryTopHide = c906lMemoryMap.dramEnd - rtosFirmware.firmwareAddress;
    };
  sg2002-uboot-mainline-fastboot-c906l =
    final.sg2002-uboot-mainline-fastboot-for final.sg2002-c906l-firmware;
  sg2002-uboot-mainline-picoclaw-splash = cross.sg2002-uboot-mainline.override {
    picoclawSplash = true;
    bootCommand = "picoclaw_splash; fastboot usb 0";
  };

  # Normal nixpkgs kernel + SG2002 patches + structured deltas (see
  # ./sg2002/linux-mainline/default.nix). No hand-rendered configfile.
  sg2002-kernel-mainline = cross.callPackage ./sg2002/linux-mainline { };
  sg2002-c906l-control =
    final.sg2002-c906l-control-for
      final.sg2002-kernel-mainline
      final.sg2002-c906l-contract;
  sg2002-c906l-remoteproc =
    final.sg2002-c906l-remoteproc-for
      final.sg2002-kernel-mainline
      final.sg2002-c906l-contract;
  sg2002-c906l-control-timer4 =
    final.sg2002-c906l-control-for
      final.sg2002-kernel-mainline
      final.sg2002-c906l-contract-timer4;
  sg2002-c906l-control-timer5 =
    final.sg2002-c906l-control-for
      final.sg2002-kernel-mainline
      final.sg2002-c906l-contract-timer5;
  sg2002-c906l-control-timer6 =
    final.sg2002-c906l-control-for
      final.sg2002-kernel-mainline
      final.sg2002-c906l-contract-timer6;
  sg2002-c906l-control-timer7 =
    final.sg2002-c906l-control-for
      final.sg2002-kernel-mainline
      final.sg2002-c906l-contract-timer7;
  sg2002-c906l-control-all-timers =
    final.sg2002-c906l-control-for
      final.sg2002-kernel-mainline
      final.sg2002-c906l-contract-all-timers;
  sg2002-c906l-remoteproc-timer4 =
    final.sg2002-c906l-remoteproc-for
      final.sg2002-kernel-mainline
      final.sg2002-c906l-contract-timer4;
  sg2002-c906l-remoteproc-timer5 =
    final.sg2002-c906l-remoteproc-for
      final.sg2002-kernel-mainline
      final.sg2002-c906l-contract-timer5;
  sg2002-c906l-remoteproc-timer6 =
    final.sg2002-c906l-remoteproc-for
      final.sg2002-kernel-mainline
      final.sg2002-c906l-contract-timer6;
  sg2002-c906l-remoteproc-timer7 =
    final.sg2002-c906l-remoteproc-for
      final.sg2002-kernel-mainline
      final.sg2002-c906l-contract-timer7;
  sg2002-c906l-remoteproc-all-timers =
    final.sg2002-c906l-remoteproc-for
      final.sg2002-kernel-mainline
      final.sg2002-c906l-contract-all-timers;
  # Keep the normal mainline kernel's Bluetooth stack disabled.  The AIC
  # HCI transport is experimental on this board, so only its explicit
  # consumer pays for bluetooth.ko and its protocol dependencies.
  sg2002-kernel-mainline-bluetooth = cross.callPackage ./sg2002/linux-mainline {
    bluetooth = true;
  };
  # The common carrier's onboard RXADC/TXDAC ALSA simple-card path is also
  # opt-in.  Keep separate variants so a Bluetooth-only consumer does not pay
  # for sound, while an audio+Bluetooth consumer gets one ABI-consistent tree.
  sg2002-kernel-mainline-audio = cross.callPackage ./sg2002/linux-mainline {
    audio = true;
  };
  sg2002-kernel-mainline-audio-bluetooth = cross.callPackage ./sg2002/linux-mainline {
    audio = true;
    bluetooth = true;
  };

  # Vendor 5.10 tree with NanoKVM extras (NBD, erofs). Built from
  # licheerv-nano-build's vendor kernel tarball; baseExtraConfig is
  # the upstream sg2002 vendor defconfig snippet, our kernelExtraConfig
  # appends NBD + erofs support and forces the same modDirVersion the
  # vendor userspace expects.
  sg2002-kernel-vendor = prev.callPackage ./sg2002-kernel-vendor-nanokvm {
    baseExtraConfig = ./sg2002/linux-vendor/extra-config.txt;
    licheerv-nano-build = inputs.licheerv-nano-build;
    kernelPatches = [ ];
    modDirVersion = "5.10.4-tag-";
    kernelExtraConfig = ''
      CONFIG_LOCALVERSION="-tag-"
      # CONFIG_LOCALVERSION_AUTO is not set
      CONFIG_BLK_DEV_NBD=y
      CONFIG_EROFS_FS=y
      CONFIG_EROFS_FS_XATTR=y
      CONFIG_EROFS_FS_POSIX_ACL=y
      CONFIG_EROFS_FS_SECURITY=y
      # CONFIG_EROFS_FS_ZIP is not set
    '';
  };

  # DTBs. dtbMainline / dtbVendor return attrsets; destructure into
  # one flat top-level attr per concrete output the overlay exposes.
  sg2002-dtb-mainline = dtbMainline.dtb;
  sg2002-dtbs-mainline = dtbMainline.dtbs;
  sg2002-dtb-mainline-full-speed = dtbMainline.full-speed;
  sg2002-dtb-mainline-eth = dtbMainline.eth;
  sg2002-dtb-mainline-nowifi = dtbMainline.nowifi;
  sg2002-dtb-mainline-nowifi-c906l-for = contract:
    dtbMainline.nowifi-c906l-for contract;
  sg2002-dtb-mainline-nowifi-c906l =
    final.sg2002-dtb-mainline-nowifi-c906l-for final.sg2002-c906l-contract;
  sg2002-dtb-mainline-nowifi-c906l-timer4 =
    final.sg2002-dtb-mainline-nowifi-c906l-for
      final.sg2002-c906l-contract-timer4;
  sg2002-dtb-mainline-nowifi-c906l-timer5 =
    final.sg2002-dtb-mainline-nowifi-c906l-for
      final.sg2002-c906l-contract-timer5;
  sg2002-dtb-mainline-nowifi-c906l-timer6 =
    final.sg2002-dtb-mainline-nowifi-c906l-for
      final.sg2002-c906l-contract-timer6;
  sg2002-dtb-mainline-nowifi-c906l-timer7 =
    final.sg2002-dtb-mainline-nowifi-c906l-for
      final.sg2002-c906l-contract-timer7;
  sg2002-dtb-mainline-nowifi-c906l-all-timers =
    final.sg2002-dtb-mainline-nowifi-c906l-for
      final.sg2002-c906l-contract-all-timers;
  sg2002-dtb-mainline-nowifi-full-speed = dtbMainline.nowifi-full-speed;
  sg2002-dtb-mainline-oled = dtbMainline.oled;
  sg2002-dtb-mainline-picoclaw-lcd = dtbMainline.picoclaw-lcd;
  sg2002-dtb-mainline-picoclaw-lcd-wifi = dtbMainline.picoclaw-lcd-wifi;
  sg2002-dtb-mainline-picoclaw-lcd-high-speed = dtbMainline.picoclaw-lcd-high-speed;
  sg2002-dtb-mainline-picoclaw-c906l-lcd-for = contract:
    dtbMainline.picoclaw-c906l-lcd-for contract;
  sg2002-dtb-mainline-pcie = dtbMainline.pcie;
  sg2002-dtb-mainline-pcie-nowifi = dtbMainline.pcie-nowifi;
  sg2002-dtb-mainline-pcie-nowifi-c906l-for = contract:
    dtbMainline.pcie-nowifi-c906l-for contract;
  sg2002-dtb-mainline-pcie-nowifi-c906l =
    final.sg2002-dtb-mainline-pcie-nowifi-c906l-for
      final.sg2002-c906l-contract;
  sg2002-dtb-mainline-pcie-nowifi-c906l-timer4 =
    final.sg2002-dtb-mainline-pcie-nowifi-c906l-for
      final.sg2002-c906l-contract-timer4;
  sg2002-dtb-mainline-pcie-nowifi-c906l-timer5 =
    final.sg2002-dtb-mainline-pcie-nowifi-c906l-for
      final.sg2002-c906l-contract-timer5;
  sg2002-dtb-mainline-pcie-nowifi-c906l-timer6 =
    final.sg2002-dtb-mainline-pcie-nowifi-c906l-for
      final.sg2002-c906l-contract-timer6;
  sg2002-dtb-mainline-pcie-nowifi-c906l-timer7 =
    final.sg2002-dtb-mainline-pcie-nowifi-c906l-for
      final.sg2002-c906l-contract-timer7;
  sg2002-dtb-mainline-pcie-nowifi-c906l-all-timers =
    final.sg2002-dtb-mainline-pcie-nowifi-c906l-for
      final.sg2002-c906l-contract-all-timers;
  sg2002-dtb-mainline-pcie-full-speed = dtbMainline.pcie-full-speed;
  sg2002-dtb-mainline-cam = dtbMainline.cam;
  sg2002-dtb-vendor = dtbVendor.boot;
  sg2002-dtb-vendor-gadget = dtbVendor.gadget;

  sg2002-boot-fit = final.callPackage ./sg2002/boot-fit { };

  picoclaw-lcd-test = final.callPackage ./sg2002/picoclaw-lcd-test { };
  sg2002-c906l-drm-test = final.callPackage ./sg2002/c906l-drm-test { };
  sg2002-h264-bridge = final.callPackage ./sg2002/h264-bridge { };
  # Separate test derivation: the shared source enables ALSA/PCMA only here;
  # the normal bridge has neither an ALSA header nor a library dependency.
  sg2002-h264-bridge-pcma = final.callPackage ./sg2002/h264-bridge {
    enablePcma = true;
  };

  sg2002-usb-boot-for = mainlineFip:
    final.callPackage ./sg2002/usb-boot {
      # The shared Python runner imports the ABI module even without C906L.
      # FIPs carrying firmware still require their exact contract below.
      c906lContract = mainlineFip.c906lContract or final.sg2002-c906l-contract;
      sg2002-cv181x-usb-dl = final.sg2002-cv181x-usb-dl;
      sg2002-fip = final.sg2002-fip;
      sg2002-fip-mainline-uboot = mainlineFip;
      mainlineOnly = true;
    };
  # Keep the historical combined vendor/mainline package for existing users.
  # Parameterised runners are mainline-only so their generic executable can
  # never silently select the unrelated vendor FIP.
  sg2002-usb-boot = final.callPackage ./sg2002/usb-boot {
    c906lContract = final.sg2002-c906l-contract;
    sg2002-cv181x-usb-dl = final.sg2002-cv181x-usb-dl;
    sg2002-fip = final.sg2002-fip;
    sg2002-fip-mainline-uboot = final.sg2002-fip-mainline-fastboot;
  };
  sg2002-usb-boot-c906l =
    final.sg2002-usb-boot-for final.sg2002-fip-mainline-fastboot-c906l;
  sg2002-usb-boot-c906l-timer4 =
    final.sg2002-usb-boot-for final.sg2002-fip-mainline-fastboot-c906l-timer4;
  sg2002-usb-boot-c906l-timer5 =
    final.sg2002-usb-boot-for final.sg2002-fip-mainline-fastboot-c906l-timer5;
  sg2002-usb-boot-c906l-timer6 =
    final.sg2002-usb-boot-for final.sg2002-fip-mainline-fastboot-c906l-timer6;
  sg2002-usb-boot-c906l-timer7 =
    final.sg2002-usb-boot-for final.sg2002-fip-mainline-fastboot-c906l-timer7;
  sg2002-usb-boot-c906l-all-timers =
    final.sg2002-usb-boot-for
      final.sg2002-fip-mainline-fastboot-c906l-all-timers;
  # This runner differs only in the FIP sent after ROM USB-DL.  It makes
  # PicoClaw's board-private U-Boot splash reachable without changing any
  # other SG2002 USB boot path.
  sg2002-usb-boot-picoclaw-splash = final.callPackage ./sg2002/usb-boot {
    c906lContract = final.sg2002-c906l-contract;
    sg2002-cv181x-usb-dl = final.sg2002-cv181x-usb-dl;
    sg2002-fip = final.sg2002-fip;
    sg2002-fip-mainline-uboot = final.sg2002-fip-mainline-picoclaw-splash;
  };

  # AIC8800 kernel module — vendor and mainline variants, parameterised
  # by the target kernel so callers can match the driver to whichever
  # kernel they're building.
  sg2002-aic8800-vendor-for = kernel:
    cross.callPackage ./sg2002/aic8800-vendor {
      inherit kernel;
      licheerv-nano-build = inputs.licheerv-nano-build;
    };
  sg2002-aic8800-mainline-for = kernel:
    cross.callPackage ./sg2002/aic8800-mainline {
      inherit kernel;
      src = inputs.aic8800-radxa;
      firmware = final.sg2002-aic8800-firmware;
    };
  # Separate derivation so WiFi-only consumers retain their byte-for-byte
  # existing module configuration.  This one turns on the vendor's shared
  # SDIO HCI transport in both BSP and FDRV.
  sg2002-aic8800-mainline-bluetooth-for = kernel:
    cross.callPackage ./sg2002/aic8800-mainline/bluetooth.nix {
      inherit kernel;
      src = inputs.aic8800-radxa;
      firmware = final.sg2002-aic8800-firmware;
    };
}
