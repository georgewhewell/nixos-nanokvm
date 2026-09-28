{ pkgs }:
let
  uboot = pkgs.pkgsCross.riscv64.sg2002-uboot-mainline;
  kernel = pkgs.pkgsCross.riscv64.sg2002-kernel-mainline.configfile;
in
pkgs.runCommand "sg2002-pmu-tests"
{
  nativeBuildInputs = [ pkgs.python3 pkgs.dtc pkgs.gnugrep ];
} ''
  # OpenSBI reads U-Boot's DTB, not the carrier DTB Linux gets.
  python3 ${./verify-pmu-dtb.py} ${uboot}/u-boot.dtb

  # Ordinary kernels must expose the counters without a diagnostic override.
  grep -qx CONFIG_PERF_EVENTS=y ${kernel}
  grep -qx CONFIG_RISCV_PMU=y ${kernel}
  grep -qx CONFIG_RISCV_PMU_SBI=y ${kernel}
  # The C906 signals counter overflow through T-Head CSRs, not Sscofpmf.
  grep -qx CONFIG_ERRATA_THEAD_PMU=y ${kernel}
  grep -qx CONFIG_PSI=y ${kernel}
  grep -qx '# CONFIG_PSI_DEFAULT_DISABLED is not set' ${kernel}
  grep -qx '# CONFIG_THERMAL_EMULATION is not set' ${kernel}

  # This core has no vector unit: an OP-V instruction traps with SIGILL on
  # real silicon, unlike the Allwinner D1's C906. Do not let a DT or config
  # change start advertising one.
  grep -qx 'CONFIG_RISCV_ISA_V is not set' ${kernel} \
    || grep -qx '# CONFIG_RISCV_ISA_V is not set' ${kernel}
  if dtc -I dtb -O dts ${uboot}/u-boot.dtb 2>/dev/null | grep -q xtheadvector; then
    echo "SG2002's C906 has no vector unit; do not advertise xtheadvector" >&2
    exit 1
  fi

  touch "$out"
''
