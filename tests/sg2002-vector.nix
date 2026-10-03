{ pkgs, configurations }:
let
  inherit (pkgs) lib;
  cc = pkgs.pkgsCross.riscv64.pkgsStatic.stdenv.cc;
  check = config:
    assert !(builtins.elem "mitigations=off" config.boot.kernelParams);
    ''
      kernel=${config.boot.kernelPackages.kernel.configfile}
      grep -qx CONFIG_RISCV_ISA_V=y "$kernel"
      grep -qx CONFIG_RISCV_ISA_XTHEADVECTOR=y "$kernel"
      grep -qx CONFIG_ERRATA_THEAD_GHOSTWRITE=y "$kernel"
      grep -qx CONFIG_RISCV_ALTERNATIVE_EARLY=y "$kernel"
      dtb=${config.sg2002.fdt}
      fdtget -t s "$dtb" /cpus/cpu@0 riscv,isa-extensions | tr ' ' '\n' > extensions
      grep -qx xtheadvector extensions
      if grep -qx v extensions; then
        echo "SG2002 implements XTheadVector, not ratified V" >&2
        exit 1
      fi
      test "$(fdtget -t u "$dtb" /cpus/cpu@0 thead,vlenb)" = 16
      test "$(fdtget -t s "$dtb" /cpus/cpu@0 riscv,isa)" = rv64imafdc
    '';
in
pkgs.runCommand "sg2002-vector-tests" {
  nativeBuildInputs = [ pkgs.dtc pkgs.gnugrep cc ];
} ''
  ${lib.concatMapStringsSep "\n" check configurations}
  # The binary runs on hardware; building it does not claim a hardware pass.
  mkdir -p "$out/bin"
  ${cc.targetPrefix}gcc -O2 -Wall -Wextra -Werror -static -march=rv64gc \
    ${./sg2002-vector.c} ${./sg2002-vector-context.S} \
    -o "$out/bin/sg2002-vector-test"
''
