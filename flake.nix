{
  description = "NixOS image and packages for Sipeed NanoKVM on SG2002";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Sipeed's megarepo — vendor 5.10 kernel, vendor DTS/defconfig,
    # vendor AIC8800 osdrv tree, Cvitek's fiptool.py. (Was forwarded
    # via the nixos-sg2002 flake input; now a direct input so this
    # flake stands on its own.)
    licheerv-nano-build = {
      url = "git+https://github.com/sipeed/LicheeRV-Nano-Build?submodules=1";
      flake = false;
    };

    # radxa-pkg/aic8800: modern-kernel-compatible rewrite of the
    # vendor AIC8800 driver.
    aic8800-radxa = {
      url = "github:radxa-pkg/aic8800/9472567f729ef9f477098ebcd0751e0d65326b72";
      flake = false;
    };

    # AIC8800DC firmware blobs (pinned by Sipeed's Buildroot recipe).
    aic8800-firmware-src = {
      url = "github:lxowalle/aic8800-sdio-firmware/c56f910044cc854d6c553bcb9a644f3bca5a4c38";
      flake = false;
    };

    # Sophgo's fiptool — LZMA B3MA blob format. Bundles FSBL + DDR
    # params under data/ so we don't have to reverse engineer them.
    sophgo-fiptool = {
      url = "github:sophgo/fiptool/7f59889c91f7d5d440d6a09aad0209f0aca3d09d";
      flake = false;
    };

    nanokvm-src = {
      url = "git+file:///home/grw/src/NanoKVM";
      flake = false;
    };
  };

  outputs = {
    self,
    nixpkgs,
    ...
  } @ inputs: let
    lib = nixpkgs.lib;
    protocol = import ./lib/protocol.nix;
    mkBoardFn = import ./lib/mkBoard.nix nixpkgs;
    hostShellPrelude = import ./lib/host-prelude.nix protocol;

    # Host-build platforms.
    #
    # - x86_64-linux: full output set, including the riscv64-cross
    #   board matrix (boards.licheerv.* and boards.pcie.* via
    #   pkgsCross.riscv64). This is the developer-workstation path.
    # - aarch64-linux: only the userspace nanokvm-* packages. The
    #   board matrix is gated off on aarch64 because:
    #     1. platform/cv181x.nix pins `nixpkgs.buildPlatform =
    #        "x86_64-linux"` (cross-from-aarch64 isn't supported),
    #     2. nobody builds the cv181x SD image from an aarch64 host.
    #   This lets a Rock-5B (aarch64-linux NixOS) consume just
    #   `packages.aarch64-linux.nanokvm-server` and friends to run
    #   the web UI natively.
    systems = [
      "x86_64-linux"
      "aarch64-linux"
    ];

    forAllSystems = f:
      lib.genAttrs systems (system:
        f (import nixpkgs {
          inherit system;
          config.allowUnfreePredicate = allowUnfreePredicate;
          overlays = [self.overlays.default];
        }));

    patchDir = ./patches/nanokvm;
    patchNames =
      lib.sort builtins.lessThan
      (builtins.filter
        (name: lib.hasSuffix ".patch" name || lib.hasSuffix ".diff" name)
        (builtins.attrNames (builtins.readDir patchDir)));
    nanokvmPatches = map (name: patchDir + "/${name}") patchNames;

    rootAuthorizedKeys =
      lib.optionals (builtins.pathExists ./authorized_keys)
      (lib.filter (key: key != "") (lib.splitString "\n" (builtins.readFile ./authorized_keys)));

    rootWifiConf =
      if builtins.pathExists ./wifi.conf
      then builtins.readFile ./wifi.conf
      else null;

    allowUnfreePredicate = pkg:
      builtins.elem (lib.getName pkg) [
        "nanokvm-factory-runtime"
        "sophgo-host-tools"
      ];

    # Extra args threaded into every NixOS module via `specialArgs`.
    # Lets module files reference flake-level facts (the nixpkgs
    # input, the wifi conf) without importing flake.nix.
    boardExtraArgs = {
      inherit nixpkgs rootAuthorizedKeys allowUnfreePredicate;
      rootWifiConf = rootWifiConf;
      selfOverlay = self.overlays.default;
    };

    # Compose a NixOS system from board / kernel / profile [+ mixins].
    # See lib/mkBoard.nix.
    mkBoard = {
      board,
      kernel,
      profile,
      mixins ? [],
      extraModules ? [],
    }:
      mkBoardFn {
        board = ./boards + "/${board}.nix";
        kernel = ./profiles/kernel + "/${kernel}.nix";
        profile = ./profiles + "/${profile}.nix";
        mixins = mixins ++ [self.nixosModules.default];
        inherit extraModules;
        extraArgs = boardExtraArgs;
      };

    # Catalog of every {board, kernel, profile, variant} we publish.
    # One record per shipped configuration; both nixosConfigurations
    # and packages.boards.* are derived from this single source via
    # mkBoardSystems / mkBoardsArtifacts below.
    catalog = import ./lib/catalog.nix {inherit lib;};

    # Walk the catalog and produce the nested nixosConfigurations.boards
    # attrset.  Each leaf is a `mkBoard {...}` call.
    mkBoardSystemsFromCatalog = entries:
      lib.foldl'
      (acc: entry:
        lib.recursiveUpdate acc (lib.setAttrByPath entry.path (mkBoard {
          board = entry.boardName;
          inherit (entry) kernel profile;
          mixins = entry.mixins or [];
          extraModules =
            (entry.modules or [])
            ++ lib.optional (
              entry.boardName == "nanokvm-pcie" && rootWifiConf != null
            ) ./modules/wifi-aic8800.nix;
        })))
      {} entries;

    # =============================================================
    # The catalog of NixOS systems we publish, organised as
    #   boards.<board>.<kernel>.<profile>[.<variant>]
    #
    # Variants are encoded by which mixin modules get layered on top.
    # `<variant>` names use dashes to combine mixin tags
    # (e.g. `usb-oled` = USB transport + OLED panel mixin).
    # =============================================================
    # NixOS systems for every catalog entry, attrpath = entry.path.
    boardSystems = mkBoardSystemsFromCatalog catalog;

    # =============================================================
    # Helpers that build the host-side artifacts (FIT, kexec payload,
    # rootfs, and the runner shell scripts). Body lives in
    # lib/artifacts.nix so this file doesn't carry ~450 lines of bash.
    # =============================================================
    mkArtifacts = import ./lib/artifacts.nix {
      inherit lib hostShellPrelude;
    };
  in {
    overlays.default = import ./pkgs {
      inherit inputs nanokvmPatches;
    };

    nixosModules.nanokvm = import ./modules/nanokvm.nix;
    nixosModules.default = {
      imports = [self.nixosModules.nanokvm];
      nixpkgs.overlays = [self.overlays.default];
    };

    nixosConfigurations.boards = boardSystems;

    packages = forAllSystems (pkgs: let
      hostSys = pkgs.stdenv.hostPlatform.system;
      # The board matrix evaluates the riscv64 cross set + cv181x
      # platform module, both of which pin nixpkgs.buildPlatform =
      # "x86_64-linux". Don't try to construct it on aarch64.
      withBoardMatrix = hostSys == "x86_64-linux";

      art = mkArtifacts pkgs;

      # Specialise the three artifact builders so the catalog-walker
      # below can just call them with a catalog entry.
      board = "licheerv"; # for mkBoardFdt — only `licheerv` (cv1800/SG2002)
                           # produces these artifacts; nanokvm-pcie is its
                           # own sdImage-only beast.
      liveArtifacts = entry: let
        cfg = lib.getAttrFromPath entry.path boardSystems;
        tag = entry.tag;
        variant = entry.variant or null;
        oled = entry.artifactArgs.oled or false;
        rootfsBindIp = entry.artifactArgs.rootfsBindIp or null;
        extraBootargs = entry.artifactArgs.extraBootargs or [];
        includeKexec = entry.artifactArgs.includeKexec or true;
        rootfs = art.mkLiveRootfs cfg;
        payload = art.mkKexecPayload {
          name = "nanokvm-kexec-${tag}.erofs";
          inherit board cfg variant oled;
          inherit (entry) kernel;
          extraBootargs =
            [
              "init=${cfg.config.system.build.toplevel}/init"
              "nanokvm.kexec_target=${tag}"
            ]
            ++ extraBootargs;
        };
        kexec = art.mkKexecRunner {
          name = "kexec";
          inherit payload rootfs oled rootfsBindIp;
          useRunningDtb = !oled && rootfsBindIp == null;
        };
        usb-boot = art.mkUsbBootRunner {
          name = "usb-boot";
          fit = art.mkBootFit {
            inherit board cfg;
            inherit (entry) kernel;
            profile = "live";
            description = "NanoKVM SG2002 USB NBD live boot (${tag})";
          };
          inherit rootfs;
          bootargs = art.mkLiveBootargs {
            inherit cfg;
            extra = extraBootargs;
          };
          waitForSsh = true;
        };
      in
        {
          inherit rootfs usb-boot;
        }
        // lib.optionalAttrs includeKexec {
          inherit payload kexec;
        };

      kernelTestArtifacts = entry: let
        cfg = lib.getAttrFromPath entry.path boardSystems;
        tag = entry.tag;
        oled = entry.artifactArgs.oled or false;
        payload = art.mkKexecPayload {
          name = "nanokvm-kexec-${tag}.erofs";
          inherit board cfg oled;
          inherit (entry) kernel;
        };
        kexec = art.mkKexecRunner {
          name = "kexec";
          inherit payload oled;
          useRunningDtb = !oled;
        };
        usb-boot = art.mkUsbBootRunner {
          name = "usb-boot";
          fit = art.mkBootFit {
            inherit board cfg;
            inherit (entry) kernel;
            profile = "kernel-test";
            description = "NanoKVM SG2002 USB kernel test (${tag})";
          };
          bootargs = art.kernelTestBootargs;
          attachPicocom = true;
        };
      in {
        inherit payload kexec usb-boot;
      };

      debugArtifacts = entry: let
        cfg = lib.getAttrFromPath entry.path boardSystems;
        liveCfg = lib.getAttrFromPath entry.liveCfgPath boardSystems;
        tag = entry.tag;
        rootfs = art.mkLiveRootfs liveCfg;
        payload = art.mkKexecPayload {
          name = "nanokvm-kexec-${tag}.erofs";
          inherit board cfg;
          inherit (entry) kernel;
          extraBootargs = ["nanokvm.kexec_target=${tag}"];
        };
        kexec = art.mkKexecRunner {
          name = "kexec";
          inherit payload rootfs;
          useRunningDtb = true;
        };
        usb-boot = art.mkUsbBootRunner {
          name = "usb-boot";
          fit = art.mkBootFit {
            inherit board cfg;
            inherit (entry) kernel;
            profile = "debug";
            description = "NanoKVM SG2002 USB NBD debug boot (${tag})";
          };
          inherit rootfs;
          bootargs = art.kernelTestBootargs;
        };
      in {
        inherit rootfs payload kexec usb-boot;
      };

      sdImageArtifact = entry:
        (lib.getAttrFromPath entry.path boardSystems).config.system.build.sdImage;

      # Dispatch table indexed by entry.artifact.
      artifactBuilder = {
        "kernel-test" = kernelTestArtifacts;
        "live" = liveArtifacts;
        "debug" = debugArtifacts;
        "sd" = sdImageArtifact;
      };

      # Walk the catalog and produce the nested packages.boards attrset.
      boardsTree = lib.foldl'
        (acc: entry:
          if entry.artifact == null
          then acc
          else lib.recursiveUpdate acc (lib.setAttrByPath entry.path
            (artifactBuilder.${entry.artifact} entry)))
        {} catalog;
    in (lib.optionalAttrs withBoardMatrix {
      boards = boardsTree;
    }) // {
      # Convenience: surface the underlying packages so callers can
      # `nix build .#nanokvm-server` etc without reaching into the
      # boards/ tree.
      inherit
        (pkgs)
        nanokvm-bench-usb-transport
        nanokvm-patched-src
        nanokvm-factory-runtime
        nanokvm-server
        nanokvm-server-nocamera
        nanokvm-web
        nbd-client-minimal
        sg2002-usb-boot
        sophgo-host-tools
        ;
      default = pkgs.nanokvm-server;
    } // lib.optionalAttrs withBoardMatrix {
      sg2002-licheerv-nano-oled-dtbo = art.sg2002OledOverlayDtbo;
    });

    # `apps.<system>` is reserved for flat `nix run` shortcuts. The
    # boards.* tree lives under `packages.<system>.boards.…` instead;
    # the runner derivations there have `bin/kexec` and `bin/usb-boot`
    # so `nix run .#boards.licheerv.mainline.live.usb.kexec` finds the
    # right binary directly.
    apps = forAllSystems (pkgs:
      lib.optionalAttrs pkgs.stdenv.isLinux {
        usb-boot-mainline = {
          type = "app";
          program = "${pkgs.sg2002-usb-boot}/bin/usb-boot-mainline";
        };
      });

    devShells = forAllSystems (pkgs: {
      default = pkgs.mkShell {
        packages = with pkgs;
          [
            go_1_25
            nodejs_24
            pnpm_10
            patchelf
            dtc
            erofs-utils
            nbd
            sg2002-cv181x-usb-dl
            usbutils
            pkgsCross.riscv64-musl.stdenv.cc
          ]
          ++ lib.optionals pkgs.stdenv.isLinux [
            android-tools
            picocom
          ];

        shellHook = ''
          export GOOS=linux
          export GOARCH=riscv64
          export CGO_ENABLED=1
          export CC=${pkgs.pkgsCross.riscv64-musl.stdenv.cc}/bin/riscv64-unknown-linux-musl-gcc
          export CGO_CFLAGS="-mcpu=thead-c906 -march=rv64gc_xtheadba_xtheadbb_xtheadbs_xtheadcmo_xtheadcondmov_xtheadfmemidx_xtheadmac_xtheadmemidx_xtheadmempair_xtheadsync -mcmodel=medany -mabi=lp64d"
        '';
      };
    });
  };
}
