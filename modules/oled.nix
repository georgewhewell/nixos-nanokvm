# OLED panel mixin. When `nanokvm.oled.enable = true`:
#
# - hardware/DT side comes from the kexec-time overlay (see
#   `dtb/sg2002-licheerv-nano-oled.dtso` and `oled = true` on
#   mkUsbKexec / mkUsbKexecPayload). That brings up the
#   SSD1306-compatible i²c panel and creates /dev/fb0 + tty1.
# - stage-2 userspace side, here: a tiny systemd service running a
#   stdlib-only Python status app at `apps/oled/main.py`. The app
#   writes plain text to /dev/tty1; the kernel's fbcon renders it
#   to /dev/fb0 over i²c.
#
# Iteration loop:
# - slow path: edit apps/oled/main.py, `nix build .#...-oled`, kexec.
# - fast path: `scp apps/oled/main.py root@10.55.0.1:/run/oled/main.py
#              && ssh root@10.55.0.1 systemctl restart oled-app`.
#   The systemd-tmpfiles rule below seeds /run/oled/main.py at boot
#   from the in-store copy; scp'ing a new file to that path
#   overrides it until next reboot. Service ExecStart points at
#   that mutable /run path, not at the nix store, so the override
#   takes effect on `systemctl restart oled-app`.
#
# Composes with any stage-2 nixosConfiguration. For initrd-only
# targets (kernel-test, nbd-debug) only the kexec-time overlay is
# meaningful — this module's services never run because those
# targets stay in initrd and never reach multi-user.target.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.nanokvm.oled;
  defaultScript = ../apps/oled/main.py;
  unblankFb0 = pkgs.writeShellScript "oled-unblank-fb0" ''
    # SSD1306 driver starts in FB_BLANK_POWERDOWN. Without unblank,
    # fbcon receives tty1 writes but doesn't drive i²c.
    echo 0 > /sys/class/graphics/fb0/blank
  '';
in {
  options.nanokvm.oled = with lib; {
    enable =
      mkEnableOption "OLED panel via fbcon + tty1 + an app"
      // {
        description = ''
          Run `nanokvm.oled.command` against /dev/tty1, which fbcon
          renders to the SSD1306-backed /dev/fb0 over i²c.
        '';
      };

    script = mkOption {
      type = types.path;
      default = defaultScript;
      description = ''
        Path to the Python script that drives the panel. Seeded into
        /run/oled/main.py at boot via systemd-tmpfiles; overridable
        at runtime by writing to that /run path and restarting the
        service.
      '';
    };

    command = mkOption {
      type = types.str;
      default = "${pkgs.python3Minimal}/bin/python3 /run/oled/main.py";
      description = ''
        ExecStart for the panel service. Default invokes
        python3Minimal on the script seeded at /run/oled/main.py.
        Override e.g. to a getty for an interactive shell:
          ${pkgs.busybox}/bin/getty -n -l ${pkgs.busybox}/bin/sh 38400 tty1 linux
        or to stream top:
          ${pkgs.busybox}/bin/sh -c 'exec top -b -d 1 > /dev/tty1 2>&1'
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # NixOS enables `getty@tty1` by default — it grabs /dev/tty1 and
    # paints "<host> login:" via fbcon onto fb0. Our oled-app wants
    # tty1 too. Disable the default so the app's writes aren't
    # overwritten by getty's prompt-redraw on every keystroke.
    systemd.services."getty@tty1".enable = false;

    # Seed /run/oled/main.py from the repo copy on every boot.
    # `C` (copy) does NOT overwrite an existing file, so a scp'd
    # override survives until the next boot. Use `C+` if you want
    # the in-store copy to always win at activation time.
    systemd.tmpfiles.rules = [
      "d /run/oled 0755 root root - -"
      "C /run/oled/main.py 0644 root root - ${cfg.script}"
    ];

    systemd.services.oled-app = {
      description = "NanoKVM OLED status app on tty1";
      wantedBy = ["multi-user.target"];
      after = [
        "systemd-tmpfiles-setup.service"
        "systemd-vconsole-setup.service"
      ];
      # Skip cleanly when the kexec DT overlay isn't applied (fb0
      # only exists for the OLED variant). Without this the unit
      # crash-loops with "no such file" on non-OLED builds.
      unitConfig.ConditionPathExists = "/sys/class/graphics/fb0/blank";
      serviceConfig = {
        # Type=simple, not "idle" — idle just delays dispatch behind
        # other interleaved-with-console units in the early-boot batch,
        # which we don't care about. The app waits on /dev/tty1 via
        # StandardInput=tty, so it'll block correctly until the
        # console device exists.
        Type = "simple";
        # The SSD1306 driver starts in FB_BLANK_POWERDOWN — fbcon
        # then receives our tty1 writes but doesn't push them to
        # i²c, so the OLED stays dark. Unblank explicitly before the
        # app runs. Without this everything LOOKS right (fb0 in
        # /dev, fbcon bound, app running) but nothing reaches the
        # panel.
        ExecStartPre = unblankFb0;
        ExecStart = cfg.command;
        Restart = "always";
        RestartSec = "1s";
        StandardInput = "tty";
        StandardOutput = "tty";
        StandardError = "tty";
        TTYPath = "/dev/tty1";
        TTYReset = "yes";
        TTYVHangup = "yes";
        TTYVTDisallocate = "no";
        KillMode = "process";
      };
    };

    # Make sure python3Minimal lands in the system closure so the
    # ExecStart path actually resolves.
    environment.systemPackages = [pkgs.python3Minimal];
  };
}
