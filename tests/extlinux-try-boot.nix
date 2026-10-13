{ pkgs }:
let
  builder = import ../lib/extlinux-conf-builder.nix { inherit pkgs; inherit (pkgs) lib; };
  oldBuilder = import (pkgs.path + "/nixos/modules/system/boot/loader/generic-extlinux-compatible/extlinux-conf-builder.nix") {
    inherit pkgs; inherit (pkgs) lib;
  };
  systemFixture = name: withInitrd: pkgs.runCommand "${name}-system" {} ''
    mkdir -p "$out/specialisation"
    echo ${name} > "$out/kernel"
    echo test > "$out/nixos-version"
    echo 'root=/dev/mmcblk0p2 rootfstype=btrfs' > "$out/kernel-params"
    touch "$out/init"
    ${pkgs.lib.optionalString withInitrd ''echo initrd > "$out/initrd"''}
  '';
  withInitrd = systemFixture "with-initrd" true;
  withoutInitrd = systemFixture "without-initrd" false;
  configuration = pkgs.writeText "extlinux-test.conf" ''
    DEFAULT old
    LABEL old
      APPEND init=/nix/store/old-system/init
    LABEL candidate
      APPEND init=/nix/store/candidate-system/init
  '';
in
pkgs.testers.runNixOSTest {
  name = "extlinux-try-boot";
  nodes.machine = { ... }: {
    imports = [ ../modules/extlinux-try-boot.nix ];
    boot.extlinuxTryBoot = {
      enable = true;
      autoArmOnSwitch = false;
      configPath = "/var/lib/tryboot/extlinux.conf";
      statePath = "/var/lib/tryboot/state";
      timeoutSec = 2;
      successCommand = ''
        touch /run/health-checked
        test ! -e /run/fail-health
      '';
    };
    systemd.services.extlinux-try-boot-bless.environment.EXTLINUX_TRY_BOOT_CMDLINE =
      "/run/test-cmdline";
  };
  testScript = ''
    import time

    start_all()
    machine.wait_for_unit("multi-user.target")
    unit = "extlinux-try-boot-bless.service"
    cli = "env EXTLINUX_TRY_BOOT_CMDLINE=/run/test-cmdline extlinux-try-boot"

    def booted(label):
        machine.succeed(f"printf 'init=/nix/store/{label}-system/init\\n' > /run/test-cmdline")

    def restart_bless():
        # These independent boot scenarios reuse one VM rather than waiting
        # for systemd's normal start-rate window between simulated boots.
        machine.succeed(f"systemctl reset-failed {unit}")
        machine.succeed(f"systemctl restart {unit}")

    with subtest("ordinary boot skips the timer and health command"):
        machine.succeed("install -Dm644 ${configuration} /var/lib/tryboot/extlinux.conf")
        booted("old")
        machine.fail(f"{cli} is-candidate")
        restart_bless()
        machine.succeed("test ! -e /run/health-checked")
        assert machine.succeed(f"systemctl show {unit} -p ExecMainStartTimestampMonotonic --value").strip() == "0"

    with subtest("an armed candidate does not delay the running old generation"):
        machine.succeed(f"{cli} arm candidate old")
        restart_bless()
        machine.succeed("test ! -e /run/health-checked")
        machine.succeed("grep -Fx 'DEFAULT candidate' /var/lib/tryboot/extlinux.conf")

    with subtest("candidate failure retains the fallback and trial state"):
        booted("candidate")
        machine.succeed(f"{cli} early-rollback")
        machine.succeed("touch /run/fail-health")
        machine.fail(f"systemctl restart {unit}")
        machine.succeed("test -e /run/health-checked; test -s /var/lib/tryboot/state")
        machine.succeed("grep -Fx 'DEFAULT old' /var/lib/tryboot/extlinux.conf")

    with subtest("candidate must survive the full health window before blessing"):
        machine.succeed("rm /run/fail-health /run/health-checked")
        started = time.monotonic()
        restart_bless()
        assert time.monotonic() - started >= 2
        machine.succeed("test -e /run/health-checked; test ! -e /var/lib/tryboot/state")
        machine.succeed("grep -Fx 'DEFAULT candidate' /var/lib/tryboot/extlinux.conf")

    with subtest("fallback boot skips a stale trial without modifying it"):
        machine.succeed(f"{cli} set-default old; {cli} arm candidate old")
        booted("old")
        machine.succeed("rm /run/health-checked")
        restart_bless()
        machine.succeed("test ! -e /run/health-checked; test -s /var/lib/tryboot/state")

    with subtest("a reused label with a different init is not the candidate"):
        machine.succeed("sed -i s,candidate-system/init,replaced-system/init, /var/lib/tryboot/extlinux.conf")
        booted("replaced")
        restart_bless()
        machine.succeed("test ! -e /run/health-checked; test -s /var/lib/tryboot/state")

    with subtest("malformed state fails closed without running health commands"):
        machine.succeed("printf 'candidate=broken\\n' > /var/lib/tryboot/state")
        machine.succeed(f"status=0; {cli} is-candidate || status=$?; test $status = 255")
        machine.succeed(f"systemctl reset-failed {unit}")
        machine.fail(f"systemctl restart {unit}")
        machine.succeed("test ! -e /run/health-checked; test -s /var/lib/tryboot/state")

    bootdir = "/var/lib/mixed-boot"
    conf = f"{bootdir}/extlinux/extlinux.conf"
    mixed_cli = f"env EXTLINUX_TRY_BOOT_CONF={conf} EXTLINUX_TRY_BOOT_STATE=/run/mixed-state {cli}"

    def write_menu(builder, default):
        machine.succeed(f"{builder} -t 1 -g 2 -r -c {default} -d {bootdir}")

    def entries():
        result = {}
        label = None
        for line in machine.succeed(f"cat {conf}").splitlines():
            fields = line.split()
            if not fields:
                continue
            if fields[0] == "LABEL":
                label = fields[1]
                result[label] = {}
            elif label and fields[0] in ("LINUX", "INITRD", "APPEND"):
                result[label][fields[0]] = " ".join(fields[1:])
        return result

    def running(system):
        machine.succeed(f"echo init={system}/init > /run/test-cmdline")

    with subtest("the real installer retains both kinds of generation and their payloads"):
        machine.succeed("ln -s ${withInitrd} /nix/var/nix/profiles/system-9001-link")
        machine.succeed("ln -s ${withoutInitrd} /nix/var/nix/profiles/system-9002-link")
        write_menu("${builder}", "${withoutInitrd}")
        menu = entries()
        assert set(menu) == {"nixos-default", "nixos-9001-default", "nixos-9002-default"}
        assert "INITRD" in menu["nixos-9001-default"]
        assert "INITRD" not in menu["nixos-default"]
        assert "INITRD" not in menu["nixos-9002-default"]
        for entry in menu.values():
            for key in ("LINUX", "INITRD"):
                if key in entry:
                    machine.succeed(f"test -s {bootdir}/extlinux/{entry[key]}")
        no_initrd_kernel = menu["nixos-9002-default"]["LINUX"]

    with subtest("mixed-menu trial boots roll back and bless without requiring an initrd"):
        running("${withInitrd}")
        machine.succeed(f"{mixed_cli} arm nixos-9002-default nixos-9001-default")
        running("${withoutInitrd}")
        machine.succeed(f"cp {conf} /run/mixed-menu-saved")
        machine.succeed(f"sed -i 's/^LABEL nixos-9002-default$/LABEL missing-candidate/' {conf}")
        machine.fail(f"{mixed_cli} is-candidate")
        machine.succeed(f"cp /run/mixed-menu-saved {conf}")
        machine.succeed(f"sed -i '/^LABEL nixos-9002-default/,/^$/s@${withoutInitrd}/init@${withInitrd}/init@' {conf}")
        machine.fail(f"{mixed_cli} is-candidate")
        machine.succeed(f"cp /run/mixed-menu-saved {conf}")
        machine.succeed(f"{mixed_cli} is-candidate")
        machine.succeed(f"{mixed_cli} early-rollback")
        machine.succeed(f"grep -Fx 'DEFAULT nixos-9001-default' {conf}")
        machine.succeed(f"{mixed_cli} bless")
        machine.succeed(f"grep -Fx 'DEFAULT nixos-9002-default' {conf}; test ! -e /run/mixed-state")

    with subtest("an older installer removes no-initrd entries and try-boot refuses the missing fallback"):
        write_menu("${oldBuilder}", "${withInitrd}")
        assert set(entries()) == {"nixos-default", "nixos-9001-default"}
        machine.fail(f"test -e {bootdir}/extlinux/{no_initrd_kernel}")
        machine.fail(f"{mixed_cli} arm nixos-default nixos-9002-default")
        machine.succeed("test ! -e /run/mixed-state")

    with subtest("using the compatible installer restores a safe downgrade menu"):
        write_menu("${builder}", "${withInitrd}")
        machine.succeed(f"test -s {bootdir}/extlinux/{no_initrd_kernel}")
        machine.succeed(f"{mixed_cli} arm nixos-9001-default nixos-9002-default")
        running("${withInitrd}")
        machine.succeed(f"{mixed_cli} early-rollback")
        machine.succeed(f"grep -Fx 'DEFAULT nixos-9002-default' {conf}")
        machine.succeed(f"{mixed_cli} bless")
        machine.succeed(f"grep -Fx 'DEFAULT nixos-9001-default' {conf}; test ! -e /run/mixed-state")
  '';
}
