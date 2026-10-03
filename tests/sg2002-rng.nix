{ pkgs, configurations }:
let
  inherit (pkgs) lib;
  check = config:
    assert lib.elem "rng_core.default_quality=0" config.boot.kernelParams;
    ''
      test "$(fdtget -t s ${config.sg2002.fdt} /soc/rng@2070000 compatible)" = sophgo,sg2002-trng
      test "$(fdtget -t s ${config.sg2002.fdt} /soc/rng@2070000 clock-names)" = "core apb"
      grep -qx CONFIG_HW_RANDOM_SG2002=y ${config.boot.kernelPackages.kernel.configfile}
    '';
in
pkgs.runCommand "sg2002-rng-tests" {
  nativeBuildInputs = [ pkgs.dtc pkgs.gnugrep ];
} ''
  ${lib.concatMapStringsSep "\n" check configurations}
  touch "$out"
''
