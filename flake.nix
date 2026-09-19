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
      url = "github:radxa-pkg/aic8800/bd11969265809a0fc948f1107c8256bbb2c1aa60";
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

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Optional stateless-root support: tmpfs / with
    # opt-in bind-mounted state. Nothing enables it on the NFS-live
    # boards (they're fully ephemeral), but the module is wired in so
    # boards that later gain a writable backing can just set
    # nanokvm.impermanence.enable.
    impermanence = {
      url = "github:nix-community/impermanence";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self
    , nixpkgs
    , disko
    , ...
    } @ inputs:
    let
      lib = nixpkgs.lib;
      protocol = import ./lib/protocol.nix;
      mkBoardFn = import ./lib/mkBoard.nix nixpkgs;

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

      # Public SSH keys for locally built standalone images.  An ignored file
      # remains convenient for path flakes, while the explicit environment
      # path also works for Git flakes, whose source filtering excludes it:
      #   NANOKVM_AUTHORIZED_KEYS=/absolute/path/authorized_keys \\
      #     nix build --impure ...
      localAuthorizedKeys = builtins.getEnv "NANOKVM_AUTHORIZED_KEYS";
      authorizedKeysFile =
        if localAuthorizedKeys != ""
        then localAuthorizedKeys
        else if builtins.pathExists ./authorized_keys
        then ./authorized_keys
        else null;
      rootAuthorizedKeys =
        lib.optionals (authorizedKeysFile != null)
          (lib.filter (key: key != "")
            (lib.splitString "\n" (builtins.readFile authorizedKeysFile)));

      # Local wpa_supplicant.conf for WiFi-booted live variants. Git flakes
      # exclude ignored files, so standalone secret injection is explicit:
      #   NANOKVM_WIFI_CONFIG=$PWD/wifi.conf nix build --impure ...
      # A path-flake invocation can still use the historical local file.
      localWifiConfig = builtins.getEnv "NANOKVM_WIFI_CONFIG";
      rootWpaConf =
        if localWifiConfig != ""
        then builtins.readFile localWifiConfig
        else if builtins.pathExists ./wifi.conf
        then builtins.readFile ./wifi.conf
        else null;

      allowUnfreePredicate = pkg:
        builtins.elem (lib.getName pkg) [
          "nanokvm-factory-runtime"
          "sg2002-coda980-firmware"
          "sg2002-c906l-firmware"
          "sophgo-host-tools"
        ];

      # Extra args threaded into every NixOS module via `_module.args`
      # (a module inside the list, not specialArgs — see lib/mkBoard.nix).
      # Lets module files reference flake-level facts (the wifi conf,
      # the overlay) without importing flake.nix.
      boardExtraArgs = {
        inherit rootAuthorizedKeys rootWpaConf allowUnfreePredicate;
        selfOverlay = self.overlays.default;
      };

      # Resolve a catalog-style {board, kernel, profile, …} record to
      # the arg set lib/mkBoard.nix expects. Shared by the two leaf
      # builders below so the nixosConfigurations and nixosModules
      # views of a board can never drift apart.
      resolveBoardArgs =
        { board
        , kernel
        , profile
        , mixins ? [ ]
        , extraModules ? [ ]
        ,
        }: {
          board = ./boards + "/${board}.nix";
          kernel = ./profiles/kernel + "/${kernel}.nix";
          profile = ./profiles + "/${profile}.nix";
          mixins = mixins ++ [
            self.nixosModules.default
            inputs.impermanence.nixosModules.impermanence
          ];
          extraModules = [ disko.nixosModules.disko ] ++ extraModules;
          extraArgs = boardExtraArgs;
        };

      # Compose a NixOS system from board / kernel / profile [+ mixins].
      mkBoard = args: mkBoardFn.mkBoard (resolveBoardArgs args);

      # The same composition as a plain importable module, for
      # downstream flakes that build their own nixosSystem around a
      # board (deployment base modules, Colmena deployment options, …).
      mkBoardModule = args: {
        imports = mkBoardFn.mkBoardModules (resolveBoardArgs args);
      };

      # Catalog of every {board, kernel, profile, variant} we publish.
      # One record per shipped configuration; both nixosConfigurations
      # and legacyPackages.boards.* are derived from this single source.
      catalog = import ./lib/catalog.nix { inherit lib; };

      # Walk the catalog and produce a nested attrset keyed by
      # entry.path, with each leaf built by `mkLeaf` from the entry's
      # mkBoard-style args. Instantiated twice: once with `mkBoard` (the source
      # of the flat nixosConfigurations output) and once with `mkBoardModule`
      # (nixosModules.boards).
      walkCatalog = mkLeaf: entries:
        lib.foldl'
          (acc: entry:
            lib.recursiveUpdate acc (lib.setAttrByPath entry.path (mkLeaf {
              board = entry.boardName;
              inherit (entry) kernel profile;
              mixins = entry.mixins or [ ];
              extraModules =
                entry.modules or [ ];
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
      boardSystems = walkCatalog mkBoard catalog;
      boardModules = walkCatalog mkBoardModule catalog;

      k3BoardModules = {
        k3."pico-itx" = {
          uefi = {
            imports = [
              self.nixosModules.overlay
              ./boards/spacemit-k3-pico-itx.nix
              ./modules/spacemit-k3-uefi-boot.nix
              ./modules/spacemit-k3-usb-gadget.nix
              ({ ... }: { spacemit.k3.usbGadget.enable = true; })
            ];
          };
          "recovery-sd" = {
            imports = [
              self.nixosModules.overlay
              ./modules/spacemit-k3-recovery-sd-image.nix
            ];
          };
          "kexec-installer" = {
            imports = [
              self.nixosModules.overlay
              ./modules/spacemit-k3-kexec-installer.nix
            ];
          };
          "initrd-rescue" = {
            imports = [
              self.nixosModules.overlay
              ./modules/spacemit-k3-initrd-rescue.nix
            ];
          };
        };
      };

      k3BoardSystems =
        let
          mkK3System = module:
            nixpkgs.lib.nixosSystem {
              modules = [
                module
                ({ ... }: { spacemit.k3.authorizedKeys = rootAuthorizedKeys; })
              ];
            };
        in
        {
          k3."pico-itx"."recovery-sd" =
            mkK3System k3BoardModules.k3."pico-itx"."recovery-sd";
          k3."pico-itx"."kexec-installer" =
            mkK3System k3BoardModules.k3."pico-itx"."kexec-installer";
          k3."pico-itx"."initrd-rescue" =
            mkK3System k3BoardModules.k3."pico-itx"."initrd-rescue";
        };

      # A T-Head C906 sandbox on `qemu-system-riscv64 -M virt`, booting
      # the *same* sg2002-kernel-mainline the boards boot. Deliberately
      # not a catalog entry: it imports no platform/cv181x.nix, sets no
      # `sg2002.enable`, and builds no FIP/FIT, so it has no
      # {board, kernel, profile} coordinates to sit at.
      qemuVirtSystem = nixpkgs.lib.nixosSystem {
        modules = [
          ./boards/qemu-riscv-virt.nix
          { _module.args = boardExtraArgs; }
        ];
      };

      # `nixosConfigurations` is a standard flake schema: every direct child
      # must be a standalone NixOS system. Publish the self-contained mainline
      # systems under stable dash-joined names. Vendor systems and the K3
      # initrd rescue require site inputs; they remain available as modules and
      # legacyPackages artifacts without pretending to be standalone configs.
      flatBoardSystems =
        builtins.listToAttrs
          (map
            (entry: {
              name = lib.concatStringsSep "-" entry.path;
              value = lib.getAttrFromPath entry.path boardSystems;
            })
            (builtins.filter (entry: entry.kernel == "mainline") catalog))
        // {
          k3-pico-itx-recovery-sd = k3BoardSystems.k3."pico-itx"."recovery-sd";
          k3-pico-itx-kexec-installer = k3BoardSystems.k3."pico-itx"."kexec-installer";
          qemu-c906-virt = qemuVirtSystem;
        };

      mkInitrdArtifacts = import ./lib/initrd-artifacts.nix { inherit lib; };
    in
    {
      overlays.default = import ./pkgs {
        inherit inputs nanokvmPatches;
      };

      nixosModules.overlay = {
        nixpkgs.overlays = [ self.overlays.default ];
      };
      nixosModules.extlinuxTryBoot = import ./modules/extlinux-try-boot.nix;
      nixosModules.nanokvm = import ./modules/nanokvm.nix;
      nixosModules.sg2002C906L = import ./modules/sg2002-c906l.nix;
      nixosModules.default = {
        imports = [
          self.nixosModules.nanokvm
          self.nixosModules.overlay
        ];
      };
      nixosModules.spacemitK3 = import ./platform/spacemit-k3.nix;
      nixosModules.spacemitK3UefiBoot = import ./modules/spacemit-k3-uefi-boot.nix;
      nixosModules.spacemitK3UsbGadget = import ./modules/spacemit-k3-usb-gadget.nix;
      nixosModules.spacemitK3UfsDisko = import ./modules/spacemit-k3-ufs-disko.nix;
      nixosModules.spacemitK3RecoverySdImage = import ./modules/spacemit-k3-recovery-sd-image.nix;
      nixosModules.spacemitK3KexecInstaller = import ./modules/spacemit-k3-kexec-installer.nix;
      nixosModules.spacemitK3InitrdRescue = import ./modules/spacemit-k3-initrd-rescue.nix;
      # Every catalog entry as a plain module. Consumers import e.g.
      # `nixosModules.boards.pcie.mainline.initrd.default` into their own
      # lib.nixosSystem to make the board a regular deployment member; the
      # module list is self-contained (no specialArgs required), so
      # Colmena-style re-instantiation from `_module.args.modules`
      # works without reconstructing anything.
      nixosModules.boards = lib.recursiveUpdate boardModules k3BoardModules;

      nixosConfigurations = flatBoardSystems;

      legacyPackages = forAllSystems (pkgs:
        let
          hostSys = pkgs.stdenv.hostPlatform.system;
          # The board matrix evaluates the riscv64 cross set + cv181x
          # platform module, both of which pin nixpkgs.buildPlatform =
          # "x86_64-linux". Don't try to construct it on aarch64.
          withBoardMatrix = hostSys == "x86_64-linux";

          artifactBuilder.initrd = entry:
            mkInitrdArtifacts pkgs
              (lib.getAttrFromPath entry.path boardSystems).config;
          artifactBuilder.sd = entry:
            (lib.getAttrFromPath entry.path boardSystems).config.system.build.sdImage;

          # Walk the catalog and produce the nested legacyPackages.boards tree.
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

          k3PackagesTree = {
            k3."pico-itx"."recovery-sd" =
              k3BoardSystems.k3."pico-itx"."recovery-sd".config.system.build.sdImage;
            k3."pico-itx"."kexec-installer" =
              k3BoardSystems.k3."pico-itx"."kexec-installer".config.system.build.kexecInstallerTarball;
          };
        in
        (lib.optionalAttrs withBoardMatrix {
          boards = lib.recursiveUpdate boardsTree k3PackagesTree;
        })
        // {
          # Convenience: surface the underlying packages so callers can
          # `nix build .#nanokvm-server` etc without reaching into the
          # boards/ tree.
          inherit
            (pkgs)
            nanokvm-patched-src
            nanokvm-factory-runtime
            nanokvm-server
            nanokvm-server-nocamera
            nanokvm-web
            sg2002-c906l-contract
            sg2002-c906l-contract-timer4
            sg2002-c906l-contract-timer5
            sg2002-c906l-contract-timer6
            sg2002-c906l-contract-timer7
            sg2002-c906l-contract-all-timers
            sg2002-dtb-mainline-nowifi-c906l
            sg2002-dtb-mainline-nowifi-c906l-timer4
            sg2002-dtb-mainline-nowifi-c906l-timer5
            sg2002-dtb-mainline-nowifi-c906l-timer6
            sg2002-dtb-mainline-nowifi-c906l-timer7
            sg2002-dtb-mainline-nowifi-c906l-all-timers
            sg2002-dtb-mainline-pcie-nowifi-c906l
            sg2002-dtb-mainline-pcie-nowifi-c906l-timer4
            sg2002-dtb-mainline-pcie-nowifi-c906l-timer5
            sg2002-dtb-mainline-pcie-nowifi-c906l-timer6
            sg2002-dtb-mainline-pcie-nowifi-c906l-timer7
            sg2002-dtb-mainline-pcie-nowifi-c906l-all-timers
            sg2002-fiptool
            sg2002-fip-mainline-fastboot
            sg2002-fip-mainline-fastboot-c906l
            sg2002-fip-mainline-uboot-c906l
            sg2002-fip-mainline-fastboot-c906l-timer4
            sg2002-fip-mainline-uboot-c906l-timer4
            sg2002-fip-mainline-fastboot-c906l-timer5
            sg2002-fip-mainline-uboot-c906l-timer5
            sg2002-fip-mainline-fastboot-c906l-timer6
            sg2002-fip-mainline-uboot-c906l-timer6
            sg2002-fip-mainline-fastboot-c906l-timer7
            sg2002-fip-mainline-uboot-c906l-timer7
            sg2002-fip-mainline-fastboot-c906l-all-timers
            sg2002-fip-mainline-uboot-c906l-all-timers
            sg2002-fip-mainline-picoclaw-splash
            sg2002-c906l-firmware
            sg2002-c906l-firmware-timer4
            sg2002-c906l-firmware-timer5
            sg2002-c906l-firmware-timer6
            sg2002-c906l-firmware-timer7
            sg2002-c906l-firmware-all-timers
            sg2002-c906l-control
            sg2002-c906l-control-timer4
            sg2002-c906l-control-timer5
            sg2002-c906l-control-timer6
            sg2002-c906l-control-timer7
            sg2002-c906l-control-all-timers
            sg2002-c906l-remoteproc
            sg2002-c906l-remoteproc-timer4
            sg2002-c906l-remoteproc-timer5
            sg2002-c906l-remoteproc-timer6
            sg2002-c906l-remoteproc-timer7
            sg2002-c906l-remoteproc-all-timers
            sg2002-c906l-ctl
            sg2002-c906l-ctl-timer4
            sg2002-c906l-ctl-timer5
            sg2002-c906l-ctl-timer6
            sg2002-c906l-ctl-timer7
            sg2002-c906l-ctl-all-timers
            sg2002-c906l-rust
            sg2002-c906l-rust-timer4
            sg2002-c906l-rust-timer5
            sg2002-c906l-rust-timer6
            sg2002-c906l-rust-timer7
            sg2002-c906l-rust-all-timers
            sg2002-h264-bridge
            sg2002-h264-bridge-pcma
            sg2002-kernel-mainline
            sg2002-usb-boot
            sg2002-usb-boot-c906l
            sg2002-usb-boot-c906l-timer4
            sg2002-usb-boot-c906l-timer5
            sg2002-usb-boot-c906l-timer6
            sg2002-usb-boot-c906l-timer7
            sg2002-usb-boot-c906l-all-timers
            sg2002-usb-boot-picoclaw-splash
            sg2002-uboot-mainline-c906l
            sg2002-uboot-mainline-fastboot
            sg2002-uboot-mainline-fastboot-c906l
            sg2002-uboot-mainline-picoclaw-splash
            spacemit-k3-fsbl
            spacemit-k3-linux
            spacemit-k3-raw-fastboot-boot
            spacemit-k3-uefi-blobs
            sophgo-host-tools
            ;
          default = pkgs.nanokvm-server;
        }
        // lib.optionalAttrs withBoardMatrix {
          # This helper executes on the K3 target; expose an actual riscv64
          # derivation instead of lying about the x86 host platform.
          spacemit-k3-flash-uefi = pkgs.pkgsCross.riscv64.spacemit-k3-flash-uefi;
        });

      # `packages` must contain flat derivations. Nix installable lookup falls
      # back to legacyPackages, preserving `.#boards.picoclaw...` commands.
      packages = lib.mapAttrs
        (_system: attrs: builtins.removeAttrs attrs [ "boards" ])
        self.legacyPackages;

      # Never let an impure evaluator's local credentials enter CI images.
      # USB bundles intentionally have no login keys; persistent SD images
      # retain their documented development password. Shared dependencies
      # (kernel, firmware, modules, tools) retain the same cached store paths.
      hydraJobs.x86_64-linux = let
        ciPkgs = import nixpkgs {
          system = "x86_64-linux";
          config.allowUnfreePredicate = allowUnfreePredicate;
          overlays = [ self.overlays.default ];
        };
        ciArtifacts = import ./lib/initrd-artifacts.nix {
          inherit lib;
          requireAuthorizedKeys = false;
        };
        imageJob = entry:
          let
            board = mkBoard {
              board = entry.boardName;
              inherit (entry) kernel profile mixins;
              extraModules = (entry.modules or [ ]) ++ [
                ({ lib, ... }: {
                  boot.initrd.network.ssh.authorizedKeys = lib.mkForce [ ];
                  # Use the normal key-file API to install an empty file:
                  # sshd is exercised, but no key can authenticate to CI images.
                  boot.initrd.network.ssh.authorizedKeyFiles = lib.mkForce [
                    ./tests/fixtures/empty-authorized-keys
                  ];
                  sg2002.authorizedKeys = lib.mkForce [ ];
                  users.users.root.openssh.authorizedKeys.keys = lib.mkForce [ ];
                  users.users.root.openssh.authorizedKeys.keyFiles = lib.mkForce [ ];
                  sg2002.wifi.wpaConf = lib.mkForce null;
                })
              ];
            };
          in
          assert board.config.sg2002.wifi.wpaConf == null;
          if entry.artifact == "sd" then
            board.config.system.build.sdImage
          else
            assert board.config.boot.initrd.systemd.contents."/etc/ssh/authorized_keys.d/root".text == "";
            (ciArtifacts ciPkgs board.config).bundle;

        # One link farm per job family, so that a single commit status can
        # stand for the whole family. Hydra's GitHub status plugin posts
        # one status per matching build, and if a context were pointed at
        # every image or check individually the last build to finish would
        # overwrite whatever came before it, including a failure.
        mkAggregate = name: jobs:
          ciPkgs.runCommandLocal "nixos-nanokvm-ci-${name}" { } ''
            mkdir -p "$out"
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList
              (job: drv: ''ln -s ${drv} "$out"/${lib.escapeShellArg job}'')
              jobs)}
          '';

        jobs = {
          images = builtins.listToAttrs (map (entry: {
            name = entry.tag;
            value = imageJob entry;
          }) catalog);
          packages = {
            nanokvm-server = self.packages.x86_64-linux.nanokvm-server;
          };
          checks = lib.getAttrs [
            "extlinux-try-boot"
            "sg2002-initrd-eval"
            "sg2002-initrd-boot"
            "sg2002-c906l-picoclaw-sd-module-eval"
            "sg2002-usb-boot-runner"
            "sg2002-h264-bridge-colour"
            "sg2002-h264-bridge-c906"
            "sg2002-c906-tuning"
            "sg2002-wifi-ack-filter"
            "sg2002-clock-kunit"
            "sg2002-cpufreq"
            "sg2002-pmu"
            "sg2002-vpss-state"
            "sg2002-c906l-module-eval"
            "sg2002-c906l-picoclaw-module-eval"
            "sg2002-c906l-picoclaw-dtb"
            "sg2002-c906l-picoclaw-control"
            "sg2002-c906l-picoclaw-framebuffer"
            "sg2002-c906l-contract-generator"
            "sg2002-c906l-rust"
          ] self.checks.x86_64-linux;
        };
      in
      jobs // {
        ci = lib.mapAttrs mkAggregate jobs;
      };

      checks = forAllSystems (pkgs:
        let
          testCredentials = { lib, ... }: {
            # Public upstream test fixture; used only in checks, never images.
            boot.initrd.network.ssh.authorizedKeys = lib.mkForce [
              (lib.fileContents (nixpkgs + "/nixos/tests/initrd-network-ssh/id_ed25519.pub"))
            ];
          };
          checkedConfig = entry: (mkBoard {
            board = entry.boardName;
            inherit (entry) kernel profile mixins;
            extraModules = (entry.modules or [ ]) ++ [ testCredentials ];
          }).config;
          allTimersEntry = lib.findFirst
            (entry: entry.path
              == [ "licheerv" "mainline" "initrd" "c906l-all-timers" ])
            (throw "C906L all-timers catalog entry is missing")
            catalog;
          allTimersConfig =
            checkedConfig allTimersEntry;
          picoclawLcdEntry = lib.findFirst
            (entry: entry.path
              == [ "picoclaw" "mainline" "initrd" "default" ])
            (throw "C906L PicoClaw LCD catalog entry is missing")
            catalog;
          picoclawLcdConfig =
            checkedConfig picoclawLcdEntry;
          picoclawSdConfig = checkedConfig (lib.findFirst
            (entry: entry.path == [ "picoclaw" "mainline" "sd" "c906l-lcd" ])
            (throw "PicoClaw SD catalog entry is missing") catalog);
          failedAuxCoreEval = module:
            builtins.tryEval ((mkBoard {
              board = "licheerv-nano-w";
              kernel = "mainline";
              profile = "usb-initrd";
              extraModules = [ module testCredentials ];
            }).config.system.build.toplevel.drvPath);
          firmwareMismatch = failedAuxCoreEval ({ lib, pkgs, ... }: {
            sg2002 = {
              auxCore = {
                enable = true;
                peripherals = [ "timer4" ];
                firmware = lib.mkForce pkgs.sg2002-c906l-firmware;
              };
              wifi.enable = false;
            };
          });
          fdtMismatch = failedAuxCoreEval ({ lib, pkgs, ... }: {
            sg2002 = {
              auxCore = {
                enable = true;
                peripherals = [ "timer4" ];
                fdt = lib.mkForce pkgs.sg2002-dtb-mainline-nowifi-c906l;
              };
              wifi.enable = false;
            };
          });
          duplicatePeripherals = failedAuxCoreEval ({ ... }: {
            sg2002 = {
              auxCore = {
                enable = true;
                peripherals = [ "timer4" "timer4" ];
              };
              wifi.enable = false;
            };
          });
          picoclawFdtMismatch = builtins.tryEval (
            (mkBoard {
              board = "licheerv-nano-picoclaw";
              kernel = "mainline";
              profile = "usb-initrd";
              extraModules = [
                testCredentials
                ({ lib, pkgs, ... }: {
                  sg2002 = {
                    auxCore = {
                      enable = true;
                      peripherals = [ "picoclawLcd" ];
                      fdt = lib.mkForce
                        (pkgs.sg2002-dtb-mainline-nowifi-c906l-for
                          (pkgs.sg2002-c906l-contract-for-profile
                            "picoclaw-lcd"));
                    };
                    wifi.enable = false;
                  };
                })
              ];
            }).config.system.build.toplevel.drvPath
          );
        in
        lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
          extlinux-try-boot = import ./tests/extlinux-try-boot.nix { inherit pkgs; };
          sg2002-initrd-eval = import ./tests/usb-initrd-eval.nix {
            inherit pkgs lib;
            configs = map checkedConfig (builtins.filter (entry: entry.artifact == "initrd") catalog);
            profilingConfig = (boardSystems.licheerv.mainline.initrd.default.extendModules {
              modules = [ ({ config, lib, pkgs, ... }: {
                boot.kernelPackages = lib.mkForce (pkgs.linuxPackagesFor
                  (pkgs.sg2002-kernel-mainline.override {
                    profiling = true;
                    audio = config.sg2002.audio.enable;
                  }));
              }) ];
            }).config;
          };
          sg2002-c906l-picoclaw-sd-module-eval =
            import ./tests/sg2002-c906l-picoclaw-sd-eval.nix {
              inherit pkgs;
              config = picoclawSdConfig;
              pcieConfig = checkedConfig (lib.findFirst
                (entry: entry.path == [ "pcie" "mainline" "sd" ])
                (throw "PCIe SD catalog entry is missing") catalog);
            };
          sg2002-initrd-boot = import ./tests/usb-initrd-boot.nix {
            inherit pkgs nixpkgs;
            board = boardSystems.picoclaw.mainline.initrd.default;
          };
          sg2002-usb-boot-runner = pkgs.sg2002-usb-boot.tests.mainlineRunner;
          sg2002-h264-bridge-colour =
            pkgs.callPackage ./pkgs/sg2002/h264-bridge/test-colour.nix { };
          sg2002-c906-tuning = import ./tests/sg2002-c906-tuning.nix {
            inherit pkgs;
            targetPkgs = boardSystems.pcie.mainline.sd.pkgs;
          };
          sg2002-wifi-ack-filter = import ./tests/sg2002-wifi-ack-filter.nix {
            inherit pkgs;
            targetPkgs = boardSystems.picoclaw.mainline.initrd.default.pkgs;
            kernel = picoclawLcdConfig.boot.kernelPackages.kernel;
          };
          sg2002-h264-bridge-c906 =
            let
              bridge = boardSystems.pcie.mainline.sd.pkgs.sg2002-h264-bridge;
              baseline = pkgs.pkgsCross.riscv64.sg2002-h264-bridge.benchmark;
            in pkgs.runCommand "sg2002-h264-bridge-c906-tests" {
              nativeBuildInputs = [ pkgs.qemu pkgs.gnugrep ];
            } ''
              # QEMU verifies baseline ISA compatibility and output, not
              # performance. Timing comparisons must run on the real C906.
              for bench in ${baseline} ${bridge.benchmark}; do
                qemu-riscv64 -cpu thead-c906 "$bench/bin/bench-convert" > result
                grep -Eq '^frames=100 cpu_seconds=[0-9.]+ checksum=60633ec7$' result
              done
              touch "$out"
            '';
          sg2002-vpss-state =
            pkgs.callPackage ./pkgs/sg2002/linux-mainline/tests/vpss-state.nix { };
          sg2002-clock-kunit =
            pkgs.callPackage ./pkgs/sg2002/linux-mainline/tests/clock-kunit.nix { };
          sg2002-cpufreq = import ./tests/sg2002-cpufreq.nix {
            inherit pkgs;
            configurations = map checkedConfig catalog;
          };
          sg2002-pmu = import ./tests/sg2002-pmu.nix { inherit pkgs; };
          sg2002-c906l-module-eval = import ./tests/sg2002-c906l-eval.nix {
            inherit
              pkgs
              lib
              firmwareMismatch
              fdtMismatch
              duplicatePeripherals
              ;
            config = allTimersConfig;
            artifactArgs = allTimersEntry.artifactArgs or { };
          };
          sg2002-c906l-picoclaw-module-eval =
            import ./tests/sg2002-c906l-picoclaw-eval.nix {
              inherit pkgs;
              inherit picoclawFdtMismatch;
              config = picoclawLcdConfig;
              artifactArgs = picoclawLcdEntry.artifactArgs or { };
            };
          sg2002-c906l-picoclaw-dtb = picoclawLcdConfig.sg2002.auxCore.fdt;
          sg2002-c906l-picoclaw-control =
            pkgs.sg2002-c906l-control-for
              picoclawLcdConfig.boot.kernelPackages.kernel
              (pkgs.sg2002-c906l-contract-for-profile "picoclaw-lcd");
          sg2002-c906l-picoclaw-framebuffer =
            pkgs.sg2002-c906l-framebuffer-for
              picoclawLcdConfig.boot.kernelPackages.kernel
              (pkgs.sg2002-c906l-contract-for-profile "picoclaw-lcd");
          sg2002-c906l-contract = pkgs.sg2002-c906l-contract;
          sg2002-c906l-contract-timer4 = pkgs.sg2002-c906l-contract-timer4;
          sg2002-c906l-contract-timer5 = pkgs.sg2002-c906l-contract-timer5;
          sg2002-c906l-contract-timer6 = pkgs.sg2002-c906l-contract-timer6;
          sg2002-c906l-contract-timer7 = pkgs.sg2002-c906l-contract-timer7;
          sg2002-c906l-contract-all-timers =
            pkgs.sg2002-c906l-contract-all-timers;
          sg2002-c906l-contract-generator =
            pkgs.sg2002-c906l-contract.tests.generator;
          sg2002-c906l-rust = pkgs.sg2002-c906l-rust-tests;
          sg2002-c906l-rust-timer4 = pkgs.sg2002-c906l-rust-tests-timer4;
          sg2002-c906l-rust-timer5 = pkgs.sg2002-c906l-rust-tests-timer5;
          sg2002-c906l-rust-timer6 = pkgs.sg2002-c906l-rust-tests-timer6;
          sg2002-c906l-rust-timer7 = pkgs.sg2002-c906l-rust-tests-timer7;
          sg2002-c906l-rust-all-timers =
            pkgs.sg2002-c906l-rust-tests-all-timers;
          sg2002-c906l-firmware = pkgs.sg2002-c906l-firmware;
          sg2002-c906l-firmware-timer4 = pkgs.sg2002-c906l-firmware-timer4;
          sg2002-c906l-firmware-timer5 = pkgs.sg2002-c906l-firmware-timer5;
          sg2002-c906l-firmware-timer6 = pkgs.sg2002-c906l-firmware-timer6;
          sg2002-c906l-firmware-timer7 = pkgs.sg2002-c906l-firmware-timer7;
          sg2002-c906l-firmware-all-timers =
            pkgs.sg2002-c906l-firmware-all-timers;
          sg2002-c906l-control = pkgs.sg2002-c906l-control;
          sg2002-c906l-control-timer4 = pkgs.sg2002-c906l-control-timer4;
          sg2002-c906l-control-timer5 = pkgs.sg2002-c906l-control-timer5;
          sg2002-c906l-control-timer6 = pkgs.sg2002-c906l-control-timer6;
          sg2002-c906l-control-timer7 = pkgs.sg2002-c906l-control-timer7;
          sg2002-c906l-control-all-timers =
            pkgs.sg2002-c906l-control-all-timers;
          sg2002-c906l-remoteproc = pkgs.sg2002-c906l-remoteproc;
          sg2002-c906l-remoteproc-timer4 = pkgs.sg2002-c906l-remoteproc-timer4;
          sg2002-c906l-remoteproc-timer5 = pkgs.sg2002-c906l-remoteproc-timer5;
          sg2002-c906l-remoteproc-timer6 = pkgs.sg2002-c906l-remoteproc-timer6;
          sg2002-c906l-remoteproc-timer7 = pkgs.sg2002-c906l-remoteproc-timer7;
          sg2002-c906l-remoteproc-all-timers =
            pkgs.sg2002-c906l-remoteproc-all-timers;
          sg2002-c906l-ctl = pkgs.sg2002-c906l-ctl;
          sg2002-c906l-ctl-timer4 = pkgs.sg2002-c906l-ctl-timer4;
          sg2002-c906l-ctl-timer5 = pkgs.sg2002-c906l-ctl-timer5;
          sg2002-c906l-ctl-timer6 = pkgs.sg2002-c906l-ctl-timer6;
          sg2002-c906l-ctl-timer7 = pkgs.sg2002-c906l-ctl-timer7;
          sg2002-c906l-ctl-all-timers = pkgs.sg2002-c906l-ctl-all-timers;
          sg2002-c906l-fip-disabled = pkgs.sg2002-fip-mainline-fastboot;
          sg2002-c906l-fip = pkgs.sg2002-fip-mainline-fastboot-c906l;
          sg2002-c906l-fip-timer4 = pkgs.sg2002-fip-mainline-fastboot-c906l-timer4;
          sg2002-c906l-fip-timer5 = pkgs.sg2002-fip-mainline-fastboot-c906l-timer5;
          sg2002-c906l-fip-timer6 = pkgs.sg2002-fip-mainline-fastboot-c906l-timer6;
          sg2002-c906l-fip-timer7 = pkgs.sg2002-fip-mainline-fastboot-c906l-timer7;
          sg2002-c906l-fip-all-timers =
            pkgs.sg2002-fip-mainline-fastboot-c906l-all-timers;
          sg2002-c906l-uboot = pkgs.sg2002-uboot-mainline-fastboot-c906l;
          sg2002-c906l-runner = pkgs.sg2002-usb-boot-c906l.tests.runner;
          sg2002-c906l-runner-timer4 =
            pkgs.sg2002-usb-boot-c906l-timer4.tests.runner;
          sg2002-c906l-runner-timer5 =
            pkgs.sg2002-usb-boot-c906l-timer5.tests.runner;
          sg2002-c906l-runner-timer6 =
            pkgs.sg2002-usb-boot-c906l-timer6.tests.runner;
          sg2002-c906l-runner-timer7 =
            pkgs.sg2002-usb-boot-c906l-timer7.tests.runner;
          sg2002-c906l-runner-all-timers =
            pkgs.sg2002-usb-boot-c906l-all-timers.tests.runner;
          sg2002-c906l-dtb = pkgs.sg2002-dtb-mainline-nowifi-c906l;
          sg2002-c906l-dtb-lease-guard =
            pkgs.sg2002-dtb-mainline-nowifi-c906l.tests.leaseGuard;
          sg2002-c906l-dtb-timer4 =
            pkgs.sg2002-dtb-mainline-nowifi-c906l-timer4;
          sg2002-c906l-dtb-timer5 =
            pkgs.sg2002-dtb-mainline-nowifi-c906l-timer5;
          sg2002-c906l-dtb-timer6 =
            pkgs.sg2002-dtb-mainline-nowifi-c906l-timer6;
          sg2002-c906l-dtb-timer7 =
            pkgs.sg2002-dtb-mainline-nowifi-c906l-timer7;
          sg2002-c906l-dtb-all-timers =
            pkgs.sg2002-dtb-mainline-nowifi-c906l-all-timers;
          sg2002-c906l-pcie-dtb = pkgs.sg2002-dtb-mainline-pcie-nowifi-c906l;
          sg2002-c906l-pcie-dtb-timer4 =
            pkgs.sg2002-dtb-mainline-pcie-nowifi-c906l-timer4;
          sg2002-c906l-pcie-dtb-timer5 =
            pkgs.sg2002-dtb-mainline-pcie-nowifi-c906l-timer5;
          sg2002-c906l-pcie-dtb-timer6 =
            pkgs.sg2002-dtb-mainline-pcie-nowifi-c906l-timer6;
          sg2002-c906l-pcie-dtb-timer7 =
            pkgs.sg2002-dtb-mainline-pcie-nowifi-c906l-timer7;
          sg2002-c906l-pcie-dtb-all-timers =
            pkgs.sg2002-dtb-mainline-pcie-nowifi-c906l-all-timers;
        });

      # `apps.<system>` is reserved for flat `nix run` shortcuts. The
      # boards.* tree lives under `legacyPackages.<system>.boards.…` instead;
      # the runner derivations there have `bin/kexec` and `bin/usb-boot`
      # so `nix run .#boards.licheerv.mainline.live.usb.kexec` finds the
      # right binary directly.
      apps = forAllSystems (pkgs:
        let
          system = pkgs.stdenv.hostPlatform.system;
        in
        lib.optionalAttrs pkgs.stdenv.isLinux
          {
            usb-boot-mainline = {
              type = "app";
              program = "${pkgs.sg2002-usb-boot}/bin/usb-boot-mainline";
            };
          }
        // lib.optionalAttrs (system == "x86_64-linux") {
          # `nix run .#qemu-c906-virt` — the board's own kernel on
          # `-M virt -cpu thead-c906 -m 256 -smp 1`, in a window.
          # Set QEMU_OPTS='-display vnc=:0' on a headless build host.
          qemu-c906-virt = {
            type = "app";
            program = "${qemuVirtSystem.config.system.build.vm}/bin/run-c906-virt-vm";
          };
        });

      devShells = forAllSystems (pkgs:
        {
          default = pkgs.mkShell {
            packages = with pkgs;
              [
                go
                nodejs_24
                pnpm_10
                patchelf
                dtc
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
        }
        // lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
          c906l = pkgs.mkShell {
            inputsFrom = [ pkgs.sg2002-c906l-rust ];
            packages = [
              pkgs.cargo
              pkgs.clippy
              pkgs.rust-analyzer
              pkgs.rustc
              pkgs.rustfmt
              pkgs.pkgsCross.riscv64-embedded.stdenv.cc
            ];
            shellHook = ''
              export CARGO_BUILD_TARGET=riscv64gc-unknown-none-elf
              export RUSTFLAGS="-C code-model=medium"
            '';
          };
        });
    };
}
