# System builder. Composes:
#
#   board   — boards/<board>.nix (hardware identity, e.g. nanokvm-pcie)
#   kernel  — profiles/kernel/<kernel>.nix (vendor or mainline)
#   profile — profiles/<profile>.nix (sd-image, usb-nbd-live, …)
#   mixins  — extra modules to import on top (e.g. modules/oled.nix)
#
# All four are plain NixOS modules — composition happens via `imports`,
# not predicate flags inside this function. The function only exists to
# thread flake-level extra args (sg2002 input, the kernel overlay, the
# allowUnfree predicate, the wifi.conf contents, etc.) into the module
# system via `_module.args` so individual module files can stay
# self-contained.
nixpkgs: {
  board,
  kernel,
  profile,
  mixins ? [],
  extraModules ? [],
  extraArgs ? {},
}:
nixpkgs.lib.nixosSystem {
  # Pass flake-level facts (sg2002 input, overlay, wifi conf) via
  # `specialArgs` rather than `_module.args`. specialArgs is
  # available *before* module evaluation begins, so a module's
  # `imports` clause can reference one of these args without the
  # module system having to resolve `config` first (which would
  # cycle back through the imports).
  specialArgs = extraArgs;
  modules =
    [
      board
      kernel
      profile
    ]
    ++ mixins
    ++ extraModules;
}
