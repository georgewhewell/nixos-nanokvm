{ pkgs, configurations }:
let
  inherit (pkgs) lib;
  check = config:
    assert !(config.sg2002 ? cpuFreq);
    assert config.powerManagement.cpuFreqGovernor == "schedutil";
    assert lib.all (a: a.assertion) config.assertions;
    assert config.sg2002.auxCore.enable ->
      config.sg2002.fdt.contractSha256 == config.sg2002.auxCore.fdt.contractSha256;
    ''
      python3 ${./verify-cpufreq-dtb.py} ${config.sg2002.fdt}
      grep -qx CONFIG_CPU_FREQ=y ${config.boot.kernelPackages.kernel.configfile}
      grep -qx CONFIG_CPUFREQ_DT=y ${config.boot.kernelPackages.kernel.configfile}
      grep -qx CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL=y ${config.boot.kernelPackages.kernel.configfile}
      grep -qx CONFIG_CPU_THERMAL=y ${config.boot.kernelPackages.kernel.configfile}
    '';
in
pkgs.runCommand "sg2002-cpufreq-tests" {
  nativeBuildInputs = [ pkgs.python3 pkgs.dtc pkgs.gnugrep ];
} ''
  ${lib.concatMapStringsSep "\n" check configurations}
  python3 ${./verify-cpufreq-dtb.py} ${pkgs.sg2002-dtb-mainline-cam}
  touch "$out"
''
