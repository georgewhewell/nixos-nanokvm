# System builder. Composes:
#
#   board   — boards/<board>.nix (hardware identity, e.g. nanokvm-pcie)
#   kernel  — profiles/kernel/<kernel>.nix (vendor or mainline)
#   profile — profiles/<profile>.nix (sd-image, usb-nbd-live, …)
#   mixins  — extra modules to import on top (e.g. modules/oled.nix)
#
# All four are plain NixOS modules — composition happens via `imports`,
# not predicate flags inside this function.
nixpkgs: rec {
  # The raw module list for a board composition. The flake-level extra
  # args (authorized keys, wifi conf, the overlay, the allowUnfree
  # predicate) ride along INSIDE the list as ordinary `_module.args`
  # rather than `specialArgs`: nothing consumes them at imports-time
  # (the one historical case, usb-nbd-live's image-based-appliance
  # import, uses the always-available `modulesPath` instead), and
  # keeping the list self-contained means downstream consumers that
  # re-instantiate from `_module.args.modules` — Colmena does exactly
  # this — lose nothing.
  #
  # Exported through the flake as `nixosModules.boards.<path>` so a
  # downstream fleet can graft a board onto its own `lib.nixosSystem`
  # (shared base modules, deployment options, …) instead of consuming
  # the finished nixosConfiguration.
  mkBoardModules =
    { board
    , kernel
    , profile
    , mixins ? []
    , extraModules ? []
    , extraArgs ? {}
    }:
    [
      { _module.args = extraArgs; }
      board
      kernel
      profile
    ]
    ++ mixins
    ++ extraModules;

  mkBoard = args:
    nixpkgs.lib.nixosSystem {
      modules = mkBoardModules args;
    };
}
