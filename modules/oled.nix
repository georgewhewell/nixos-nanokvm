# OLED panel mixin. When `nanokvm.oled.enable = true`:
#
# - hardware/DT side: the panel nodes have to be in the booted DTB.
#   Two cases:
#     * LicheeRV-Nano (SH1107 128x128 on IIC1): the default DTB lacks
#       the panel, so this module swaps `sg2002.fdt` to the oled
#       variant DTB (and the kexec path applies the matching overlay,
#       see `dtb/sg2002-licheerv-nano-oled.dtso` + `oled = true` on
#       mkUsbKexec / mkUsbKexecPayload).
#     * NanoKVM-PCIe (SSD1306 128x64 on a bit-banged i2c-gpio bus):
#       the board's own DTB already carries the panel nodes — the
#       board sets `useOledFdt = false` to keep it.
#   Either way ssd1307fb binds the panel and creates /dev/fb0 + fbcon.
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
          fbcon to render on the ssd1307fb-backed /dev/fb0.
        '';
      };

    useOledFdt = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Swap `sg2002.fdt` to the LicheeRV oled-variant DTB (mainline
        kernel only). That variant trades the WiFi pads for the SH1107
        panel, so it is right for the LicheeRV-Nano but wrong for
        boards whose primary DTB already carries their own panel nodes
        — the NanoKVM-PCIe sets this to false and keeps its pcie DTB
        (SSD1306 on i2c-gpio, no pad conflicts).
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
    # LicheeRV OLED uses the variant DTB that disables SDIO1 and wires
    # those pads to IIC1 + the SH1107 panel (mainline only; vendor
    # handles it in its own DTS). Boards with the panel in their own
    # DTB opt out via useOledFdt = false.
    sg2002.fdt = lib.mkIf (cfg.useOledFdt && config.sg2002.kernel == "mainline") (
      lib.mkDefault pkgs.sg2002-dtb-mainline-oled
    );

    # 4x6 micro-font: the default 8x16 fits only 16x4 chars on a
    # 128x64 panel (16x8 on 128x128) — too cramped for `top`. Only
    # boots that read boot.kernelParams (extlinux SD images) pick this
    # up; the USB/kexec artifact paths add the same flag themselves in
    # lib/artifacts.nix (mkFeatureBootargs), so at worst the argument
    # is duplicated, which the kernel handles fine.
    boot.kernelParams = [ "fbcon=font:MINI4x6" ];

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
