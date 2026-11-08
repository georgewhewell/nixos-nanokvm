# Keep the SG2002 DesignWare watchdog alive independently of systemd PID 1.
# Slow remote-root boots can block the manager on page faults for longer than
# the watchdog's roughly 86-second hardware maximum.
{ config, lib, pkgs, ... }:
let
  cfg = config.sg2002.watchdogKeeper;
  busybox = pkgs.pkgsStatic.busybox;
  startupProbeCount = lib.max 1 (builtins.div
    (cfg.healthStartupGraceSec + cfg.healthCheckIntervalSec - 1)
    cfg.healthCheckIntervalSec);
  keeper = pkgs.writeShellScript "sg2002-watchdog-keeper" ''
    set -u
    BB=${lib.escapeShellArg "${busybox}/bin/busybox"}
    health_host=${lib.escapeShellArg (if cfg.healthHost == null then "" else cfg.healthHost)}

    if [ -z "$health_host" ]; then
      exec "$BB" watchdog -F -t 5 -T 85 /dev/watchdog0
    fi

    "$BB" watchdog -F -t 5 -T 85 /dev/watchdog0 &
    watchdog_pid=$!
    trap '"$BB" kill "$watchdog_pid" 2>/dev/null || true; wait "$watchdog_pid" 2>/dev/null || true' EXIT INT TERM

    armed=0
    failures=0
    startup_failures=0
    probe_seq=0
    while "$BB" kill -0 "$watchdog_pid" 2>/dev/null; do
      probe_seq=$((probe_seq + 1))
      probe_ok="/run/sg2002-watchdog-health-$$-$probe_seq"
      "$BB" rm -f "$probe_ok"
      # A USB-net send can itself sleep uninterruptibly. Keep it outside this
      # watchdog supervisor so a wedged ping cannot keep the petter alive.
      ( "$BB" ping -c 1 -W 1 "$health_host" >/dev/null 2>&1 && : > "$probe_ok" ) &
      probe_pid=$!
      "$BB" sleep 2
      "$BB" kill "$probe_pid" >/dev/null 2>&1 || true

      if [ -e "$probe_ok" ]; then
        "$BB" rm -f "$probe_ok"
        if [ "$armed" = 0 ]; then
          echo "sg2002-watchdog-keeper: health armed on $health_host" > /dev/kmsg
        fi
        armed=1
        failures=0
        "$BB" sleep ${toString (lib.max 1 (cfg.healthCheckIntervalSec - 2))}
        continue
      fi

      # Give a slow initrd a bounded grace period. A working route arms
      # health immediately above; a route which never works must eventually
      # arm too, otherwise keeping the watchdog alive preserves a corpse.
      if [ "$armed" != 1 ]; then
        startup_failures=$((startup_failures + 1))
        if [ "$startup_failures" -lt ${toString startupProbeCount} ]; then
          "$BB" sleep ${toString (lib.max 1 (cfg.healthCheckIntervalSec - 2))}
          continue
        fi
        echo "sg2002-watchdog-keeper: startup grace expired for $health_host; enforcing health" > /dev/kmsg
        armed=1
        failures=0
      fi
      failures=$((failures + 1))
      echo "sg2002-watchdog-keeper: health failed $failures/${toString cfg.healthFailureCount} for $health_host" > /dev/kmsg
      [ "$failures" -lt ${toString cfg.healthFailureCount} ] || break
      "$BB" sleep ${toString (lib.max 1 (cfg.healthCheckIntervalSec - 2))}
    done

    if "$BB" kill -0 "$watchdog_pid" 2>/dev/null; then
      echo "sg2002-watchdog-keeper: host unreachable; releasing watchdog for hardware reset" > /dev/kmsg
      "$BB" kill "$watchdog_pid" 2>/dev/null || true
      wait "$watchdog_pid" 2>/dev/null || true
      # WATCHDOG_NOWAYOUT keeps the hardware countdown running after close.
      # Stay alive so systemd's Restart=always cannot reopen and pet it.
      trap - EXIT INT TERM
      while :; do
        "$BB" sleep 60
      done
    fi

    wait "$watchdog_pid"
  '';
  keeperService = {
    description = "Keep the SG2002 hardware watchdog alive across switch-root";
    after = [ "systemd-udevd.service" ];
    unitConfig = {
      DefaultDependencies = false;
      IgnoreOnIsolate = true;
      RefuseManualStop = true;
      SurviveFinalKillSignal = true;
    };
    serviceConfig = {
      Type = "simple";
      ExecStart = keeper;
      Restart = "always";
      RestartSec = "250ms";
    };
  };
in
{
  options.sg2002.watchdogKeeper = {
    initrd.enable = lib.mkEnableOption "the independent SG2002 initrd watchdog keeper";
    stage2.enable = lib.mkEnableOption "the independent SG2002 stage-2 watchdog keeper";
    healthHost = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional host whose loss releases the nowayout watchdog. Health does
        not arm until the host has answered once or the bounded startup grace
        expires, so slow initrd networking is safe without preserving a route
        which never worked. USB/NFS live targets set this to their host.
      '';
    };
    healthStartupGraceSec = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 120;
      description = ''
        Maximum startup grace before failed probes begin enforcing health,
        even if the host has never answered.
      '';
    };
    healthCheckIntervalSec = lib.mkOption {
      type = lib.types.ints.positive;
      default = 5;
      description = "Seconds between watchdog host-health probes.";
    };
    healthFailureCount = lib.mkOption {
      type = lib.types.ints.positive;
      default = 6;
      description = "Consecutive failed probes before releasing the watchdog.";
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = !cfg.stage2.enable || cfg.initrd.enable;
          message = "sg2002.watchdogKeeper.stage2.enable requires initrd.enable";
        }
        # Scripted initrd was removed upstream; the initrd is always
        # systemd-based now, so the former
        # `boot.initrd.systemd.enable` precondition held unconditionally
        # and its assertion is gone.
      ];
    }

    (lib.mkIf cfg.initrd.enable {
      # The keeper, rather than a possibly blocked PID 1, owns watchdog0.
      boot.initrd.systemd.settings.Manager.RuntimeWatchdogSec = lib.mkForce "off";
      boot.initrd.systemd.storePaths = [ busybox keeper ];
      boot.initrd.systemd.services.sg2002-watchdog-keeper = keeperService // {
        wantedBy = [ "initrd.target" ];
      };
    })

    (lib.mkIf cfg.stage2.enable {
      # Keep the same unit definition after switch-root so systemd carries
      # the initrd process and its watchdog file descriptor forward.
      systemd.settings.Manager.RuntimeWatchdogSec = lib.mkForce "off";
      systemd.services.sg2002-watchdog-keeper = keeperService // {
        wantedBy = [ "multi-user.target" ];
      };
    })
  ];
}
