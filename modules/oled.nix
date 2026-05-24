# OLED panel mixin. When `nanokvm.oled.enable = true`:
#
# - hardware/DT side comes from the kexec-time overlay (see
#   `dtb/sg2002-licheerv-nano-oled.dtso` and `oled = true` on
#   mkUsbKexec / mkUsbKexecPayload). It binds the SH1107 panel to the
#   patched ssd1307fb driver and creates /dev/fb0 + fbcon.
# - stage-2 userspace side, here: a tiny systemd service runs a normal
#   terminal program on /dev/tty1. fbcon renders that to the OLED
#   framebuffer; no userspace process talks to I2C.
#
# Iteration loop:
# - slow path: edit the kernel patch or this module, `nix build
#   .#...-oled`, reboot or kexec.
# - fast path for experiments: override `nanokvm.oled.command` with any
#   program that writes ANSI/tty text to stdout.
#
# Composes with any stage-2 nixosConfiguration. For initrd-only
# targets (kernel-test, nbd-debug) only the kexec-time overlay is
# meaningful — this module's services never run because those
# targets stay in initrd and never reach multi-user.target.
{ config
, lib
, pkgs
, ...
}:
let
  cfg = config.nanokvm.oled;
  topApp = pkgs.writeShellScript "nanokvm-oled-top" ''
    export TERM=linux
    exec ${pkgs.procps}/bin/top -d 2
  '';
  maybeUnblankFb0 = pkgs.writeShellScript "oled-maybe-unblank-fb0" ''
    if [ -e /sys/class/graphics/fb0/blank ]; then
      echo 0 > /sys/class/graphics/fb0/blank
    fi
  '';
  loadFb0 = pkgs.writeShellScript "nanokvm-oled-load-fb0" ''
    ${pkgs.kmod}/bin/modprobe ssd1307fb

    for _ in $(${pkgs.coreutils}/bin/seq 1 50); do
      if [ -e /dev/fb0 ]; then
        exit 0
      fi
      ${pkgs.coreutils}/bin/sleep 0.1
    done

    echo "ssd1307fb loaded, but /dev/fb0 did not appear" >&2
    exit 1
  '';
in
{
  options.nanokvm.oled = with lib; {
    enable =
      mkEnableOption "OLED panel via fbcon + tty1 + an app"
      // {
        description = ''
          Run `nanokvm.oled.command`, which writes text to tty1 for
          fbcon to render on the SH1107-backed /dev/fb0.
        '';
      };

    command = mkOption {
      type = types.str;
      default = "${topApp}";
      description = ''
        ExecStart for the panel service. Default runs procps top on
        tty1. Override e.g. to a getty for an interactive shell:
          ${pkgs.busybox}/bin/getty -n -l ${pkgs.busybox}/bin/sh 38400 tty1 linux
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # NixOS enables `getty@tty1` by default — it grabs /dev/tty1 and
    # paints "<host> login:" via fbcon onto fb0. Our oled-app wants
    # tty1 too. Disable the default so the app's writes aren't
    # overwritten by getty's prompt-redraw on every keystroke.
    systemd.services."getty@tty1".enable = false;
    systemd.services."autovt@tty1".enable = false;

    systemd.services.oled-app = {
      description = "NanoKVM OLED fbcon status app";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStartPre = [
          loadFb0
          maybeUnblankFb0
        ];
        ExecStart = cfg.command;
        Restart = "always";
        RestartSec = "1s";
        StandardInput = "tty";
        StandardOutput = "tty";
        StandardError = "journal";
        TTYPath = "/dev/tty1";
        TTYReset = "yes";
        TTYVHangup = "yes";
        TTYVTDisallocate = "no";
        KillMode = "process";
      };
    };
  };
}
