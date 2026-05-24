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

    # Sipeed's NanoKVM userspace. Pinned to the release commit so the
    # flake evaluates from anywhere — used to be a `git+file:` to a
    # local checkout which only resolved on the dev host. The commit
    # message says "release: nanokvm@2.4.1" but there's no matching
    # tag upstream, hence pinning by SHA.
    nanokvm-src = {
      url = "github:sipeed/NanoKVM/2ca5b19efe64266b5bcde7ef167b6961659154d6";
      flake = false;
    };
  };

  outputs =
    { self
    , nixpkgs
    , ...
    } @ inputs:
    let
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
            overlays = [ self.overlays.default ];
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
      mkBoard =
        { board
        , kernel
        , profile
        , mixins ? [ ]
        , extraModules ? [ ]
        ,
        }:
        mkBoardFn {
          board = ./boards + "/${board}.nix";
          kernel = ./profiles/kernel + "/${kernel}.nix";
          profile = ./profiles + "/${profile}.nix";
          mixins = mixins ++ [ self.nixosModules.default ];
          inherit extraModules;
          extraArgs = boardExtraArgs;
        };

      # Catalog of every {board, kernel, profile, variant} we publish.
      # One record per shipped configuration; both nixosConfigurations
      # and packages.boards.* are derived from this single source.
      catalog = import ./lib/catalog.nix { inherit lib; };

      # Walk the catalog and produce the nested nixosConfigurations.boards
      # attrset.  Each leaf is a `mkBoard {...}` call.
      mkBoardSystemsFromCatalog = entries:
        lib.foldl'
          (acc: entry:
            lib.recursiveUpdate acc (lib.setAttrByPath entry.path (mkBoard {
              board = entry.boardName;
              inherit (entry) kernel profile;
              mixins = entry.mixins or [ ];
              extraModules =
                (entry.modules or [ ])
                ++ lib.optional
                  (
                    entry.boardName == "nanokvm-pcie" && rootWifiConf != null
                  )
                  ./modules/wifi-aic8800.nix;
            })))
          { }
          entries;

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
    in
    {
      overlays.default = import ./pkgs {
        inherit inputs nanokvmPatches;
      };

      nixosModules.nanokvm = import ./modules/nanokvm.nix;
      nixosModules.default = {
        imports = [ self.nixosModules.nanokvm ];
        nixpkgs.overlays = [ self.overlays.default ];
      };

      nixosConfigurations.boards = boardSystems;

      packages = forAllSystems (pkgs:
        let
          hostSys = pkgs.stdenv.hostPlatform.system;
          # The board matrix evaluates the riscv64 cross set + cv181x
          # platform module, both of which pin nixpkgs.buildPlatform =
          # "x86_64-linux". Don't try to construct it on aarch64.
          withBoardMatrix = hostSys == "x86_64-linux";

          art = mkArtifacts pkgs;

          # Specialise the three artifact builders so the catalog-walker
          # below can just call them with a catalog entry.
          # For mkBoardFdt: only `licheerv` (cv1800/SG2002) produces these
          # artifacts; nanokvm-pcie is its own sdImage-only path.
          board = "licheerv";
          entryCfg = entry: lib.getAttrFromPath entry.path boardSystems;
          entryArtifactArgs = entry: entry.artifactArgs or { };
          entryArtifactArg = name: default: entry: (entryArtifactArgs entry).${name} or default;
          entryVariant = entry: entry.variant or null;
          entryOled = entryArtifactArg "oled" false;
          entryExtraBootargs = entryArtifactArg "extraBootargs" [ ];
          entryRootfsBindIp = entryArtifactArg "rootfsBindIp" null;
          entryIncludeKexec = entryArtifactArg "includeKexec" true;

          mkEntryPayload =
            { entry
            , cfg
            , extraBootargs ? [ ]
            ,
            }:
            art.mkKexecPayload {
              name = "nanokvm-kexec-${entry.tag}.erofs";
              inherit board cfg extraBootargs;
              inherit (entry) kernel;
              variant = entryVariant entry;
              oled = entryOled entry;
            };

          mkEntryBootFit =
            { entry
            , cfg
            , profile
            , description
            ,
            }:
            art.mkBootFit {
              inherit board cfg profile description;
              inherit (entry) kernel;
              variant = entryVariant entry;
              oled = entryOled entry;
            };

          liveArtifacts = entry:
            let
              cfg = entryCfg entry;
              tag = entry.tag;
              oled = entryOled entry;
              rootfsBindIp = entryRootfsBindIp entry;
              extraBootargs = entryExtraBootargs entry;
              includeKexec = entryIncludeKexec entry;
              rootfs = art.mkLiveRootfs cfg;
              payload = mkEntryPayload {
                inherit entry cfg;
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
              usb-boot = art.mkUsbBootRunner ({
                name = "usb-boot";
                inherit rootfsBindIp;
                fit = mkEntryBootFit {
                  inherit entry cfg;
                  profile = "live";
                  description = "NanoKVM SG2002 USB NBD live boot (${tag})";
                };
                inherit rootfs;
                bootargs = art.mkLiveBootargs {
                  inherit cfg oled;
                  extra = extraBootargs;
                };
                waitForSsh = true;
              } // lib.optionalAttrs includeKexec {
                onShellDetachCommand = "${kexec}/bin/kexec";
              });
            in
            {
              inherit rootfs usb-boot;
            }
            // lib.optionalAttrs includeKexec {
              inherit payload kexec;
            };

          kernelTestArtifacts = entry:
            let
              cfg = entryCfg entry;
              oled = entryOled entry;
              payload = mkEntryPayload {
                inherit entry cfg;
              };
              kexec = art.mkKexecRunner {
                name = "kexec";
                inherit payload oled;
                useRunningDtb = !oled;
              };
              usb-boot = art.mkUsbBootRunner {
                name = "usb-boot";
                fit = mkEntryBootFit {
                  inherit entry cfg;
                  profile = "kernel-test";
                  description = "NanoKVM SG2002 USB kernel test (${entry.tag})";
                };
                bootargs = art.kernelTestBootargs;
                attachPicocom = true;
              };
            in
            {
              inherit payload kexec usb-boot;
            };

          debugArtifacts = entry:
            let
              cfg = entryCfg entry;
              liveCfg = lib.getAttrFromPath entry.liveCfgPath boardSystems;
              tag = entry.tag;
              rootfs = art.mkLiveRootfs liveCfg;
              payload = mkEntryPayload {
                inherit entry cfg;
                extraBootargs = [ "nanokvm.kexec_target=${tag}" ];
              };
              kexec = art.mkKexecRunner {
                name = "kexec";
                inherit payload rootfs;
                useRunningDtb = true;
              };
              usb-boot = art.mkUsbBootRunner {
                name = "usb-boot";
                fit = mkEntryBootFit {
                  inherit entry cfg;
                  profile = "debug";
                  description = "NanoKVM SG2002 USB NBD debug boot (${tag})";
                };
                inherit rootfs;
                bootargs = art.kernelTestBootargs;
              };
            in
            {
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
          boardsTree =
            lib.foldl'
              (acc: entry:
                if entry.artifact == null
                then acc
                else
                  lib.recursiveUpdate acc (lib.setAttrByPath entry.path
                    (artifactBuilder.${entry.artifact} entry)))
              { }
              catalog;
        in
        (lib.optionalAttrs withBoardMatrix {
          boards = boardsTree;
        })
        // {
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
        }
        // lib.optionalAttrs withBoardMatrix {
          sg2002-licheerv-nano-oled-dtbo = art.sg2002OledOverlayDtbo;
        });

      # `apps.<system>` is reserved for flat `nix run` shortcuts. The
      # boards.* tree lives under `packages.<system>.boards.…` instead;
      # the runner derivations there have `bin/kexec` and `bin/usb-boot`
      # so `nix run .#boards.licheerv.mainline.live.usb.kexec` finds the
      # right binary directly.
      apps = forAllSystems (pkgs:
        let
          system = pkgs.stdenv.hostPlatform.system;
          usbOledTop = pkgs.writeShellApplication {
            name = "usb-oled-top";
            text = ''
                            case "''${1:-}" in
                              -h|--help)
                                cat <<'EOF'
              Usage: nix run .#usb-oled-top -- [usb-boot options]

              Boots or kexecs the LicheeRV-Nano-W OLED live image and runs top on
              the 128x128 framebuffer via fbcon.

              Defaults:
                --attempts 120
                --rom-dl-timeout 1800
                --wait 120

              Environment overrides:
                NANOKVM_USB_BOOT_ATTEMPTS
                NANOKVM_USB_BOOT_ROM_DL_TIMEOUT
                NANOKVM_USB_BOOT_WAIT
                NANOKVM_NBD_ROOTFS_PORT=auto|0|<port>
                NANOKVM_NBD_ROOTFS_HOST=<target-visible-host-ip>
                NANOKVM_NBD_ROOTFS_BIND=<host-bind-ip>
                NANOKVM_NBD_CLEANUP=0
                NANOKVM_ATTACH=shell|none
                NANOKVM_ON_DETACH=hold|kexec|exit
                NANOKVM_BOOT_MODE=auto|usb|kexec
                NANOKVM_STATUS_LISTEN=1
                USB_IFACE
              EOF
                                exit 0
                                ;;
                            esac

                            usb_iface_present() {
                              local path mac
                              if [ -n "''${USB_IFACE:-}" ]; then
                                [ -d "/sys/class/net/$USB_IFACE" ]
                                return
                              fi

                              for path in /sys/class/net/*; do
                                [ -r "$path/address" ] || continue
                                IFS= read -r mac < "$path/address" || true
                                if [ "$mac" = "${protocol.hostMac}" ]; then
                                  return 0
                                fi
                              done
                              return 1
                            }

                            case "''${NANOKVM_BOOT_MODE:-auto}" in
                              auto|"")
                                if usb_iface_present; then
                                  echo "[usb-oled-top] USB debug interface is present; using kexec"
                                  exec ${self.packages.${system}.boards.licheerv.mainline.live.usb-oled.kexec}/bin/kexec "$@"
                                fi
                                ;;
                              kexec)
                                exec ${self.packages.${system}.boards.licheerv.mainline.live.usb-oled.kexec}/bin/kexec "$@"
                                ;;
                              usb|usb-boot)
                                ;;
                              *)
                                echo "[usb-oled-top] invalid NANOKVM_BOOT_MODE=''${NANOKVM_BOOT_MODE}; expected auto, usb, or kexec" >&2
                                exit 1
                                ;;
                            esac

                            export NANOKVM_ON_DETACH="''${NANOKVM_ON_DETACH:-kexec}"
                            exec ${self.packages.${system}.boards.licheerv.mainline.live.usb-oled.usb-boot}/bin/usb-boot \
                              --attempts "''${NANOKVM_USB_BOOT_ATTEMPTS:-120}" \
                              --rom-dl-timeout "''${NANOKVM_USB_BOOT_ROM_DL_TIMEOUT:-1800}" \
                              --wait "''${NANOKVM_USB_BOOT_WAIT:-120}" \
                              "$@"
            '';
          };
        in
        lib.optionalAttrs pkgs.stdenv.isLinux
          {
            usb-boot-mainline = {
              type = "app";
              program = "${pkgs.sg2002-usb-boot}/bin/usb-boot-mainline";
            };
          }
        // lib.optionalAttrs (system == "x86_64-linux") {
          usb-oled-top = {
            type = "app";
            program = "${usbOledTop}/bin/usb-oled-top";
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
