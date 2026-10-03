{ pkgs }:
let
  uboot = pkgs.pkgsCross.riscv64.sg2002-uboot-mainline;
  kernel = (pkgs.pkgsCross.riscv64.sg2002-kernel-mainline.override {
    profiling = true;
  }).configfile;
in
pkgs.runCommand "sg2002-pmu-tests"
{
  nativeBuildInputs = [ pkgs.python3 pkgs.dtc pkgs.gnugrep ];
} ''
  # OpenSBI reads U-Boot's DTB, not the carrier DTB Linux gets.
  python3 ${./verify-pmu-dtb.py} ${uboot}/u-boot.dtb

  # The counters are useless without a kernel that can ask for them. These
  # live in the profiling kernel, not the default one, so check that build.
  grep -qx CONFIG_PERF_EVENTS=y ${kernel}
  grep -qx CONFIG_RISCV_PMU=y ${kernel}
  grep -qx CONFIG_RISCV_PMU_SBI=y ${kernel}
  # The C906 signals counter overflow through T-Head CSRs, not Sscofpmf.
  grep -qx CONFIG_ERRATA_THEAD_PMU=y ${kernel}

  touch "$out"
''
