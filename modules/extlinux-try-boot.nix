{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.boot.extlinuxTryBoot;
  runtimePath = lib.makeBinPath [
    pkgs.coreutils
    pkgs.gawk
    pkgs.gnugrep
    pkgs.gnused
  ];
  tryBoot = pkgs.writeShellScriptBin "extlinux-try-boot" ''
    set -euo pipefail

    export PATH=${runtimePath}:$PATH

    conf=${lib.escapeShellArg cfg.configPath}
    state=${lib.escapeShellArg cfg.statePath}
    cmdline=/proc/cmdline
    if [ -n "''${EXTLINUX_TRY_BOOT_CONF:-}" ]; then
      conf="$EXTLINUX_TRY_BOOT_CONF"
    fi
    if [ -n "''${EXTLINUX_TRY_BOOT_STATE:-}" ]; then
      state="$EXTLINUX_TRY_BOOT_STATE"
    fi
    if [ -n "''${EXTLINUX_TRY_BOOT_CMDLINE:-}" ]; then
      cmdline="$EXTLINUX_TRY_BOOT_CMDLINE"
    fi

    log() {
      printf 'extlinux-try-boot: %s\n' "$*" >&2
      { printf 'extlinux-try-boot: %s\n' "$*" >/dev/kmsg; } 2>/dev/null || true
    }

    die() {
      log "$*"
      exit 1
    }

    usage() {
      cat >&2 <<'USAGE'
    usage: extlinux-try-boot <command> [args]

    commands:
      status
      current-default
      booted-label
      set-default <label>
      arm <candidate-label> [fallback-label]
      early-rollback
      is-candidate
      bless
      rollback-now
      cancel
    USAGE
      exit 2
    }

    valid_label() {
      case "$1" in
        "" | *[!A-Za-z0-9_.:+-]*) return 1 ;;
        *) return 0 ;;
      esac
    }

    require_conf() {
      [ -f "$conf" ] || die "$conf does not exist"
    }

    sync_path() {
      sync -f "$1" 2>/dev/null || sync
    }

    label_exists() {
      require_conf
      awk -v want="$1" '
        $1 == "LABEL" && $2 == want { found = 1 }
        END { exit found ? 0 : 1 }
      ' "$conf"
    }

    current_default() {
      require_conf
      awk '
        $1 == "DEFAULT" { print $2; found = 1; exit }
        END { exit found ? 0 : 1 }
      ' "$conf"
    }

    label_init() {
      require_conf
      awk -v want="$1" '
        $1 == "LABEL" { in_label = ($2 == want) }
        in_label && $1 == "APPEND" {
          for (i = 2; i <= NF; i++) {
            if ($i ~ /^init=/) {
              sub(/^init=/, "", $i)
              print $i
              found = 1
              exit
            }
          }
        }
        END { exit found ? 0 : 1 }
      ' "$conf"
    }

    booted_init() {
      [ -r "$cmdline" ] || return 1
      tr ' ' '\n' <"$cmdline" | sed -n 's/^init=//p' | head -n 1
    }

    booted_label() {
      local init
      init="$(booted_init)"
      [ -n "$init" ] || return 1
      require_conf
      awk -v want="init=$init" '
        $1 == "LABEL" { label = $2 }
        $1 == "APPEND" {
          for (i = 2; i <= NF; i++) {
            if ($i == want) {
              print label
              found = 1
              exit
            }
          }
        }
        END { exit found ? 0 : 1 }
      ' "$conf"
    }

    set_default() {
      local label="$1" dir tmp
      valid_label "$label" || die "invalid label: $label"
      label_exists "$label" || die "label not found in $conf: $label"
      [ -w "$conf" ] || die "$conf is not writable"

      dir="$(dirname "$conf")"
      tmp="$(mktemp "$dir/.extlinux.conf.XXXXXX")"
      if ! awk -v label="$label" '
        $1 == "DEFAULT" {
          print "DEFAULT " label
          done = 1
          next
        }
        { print }
        END { if (!done) exit 2 }
      ' "$conf" >"$tmp"; then
        rm -f "$tmp"
        die "failed to rewrite DEFAULT in $conf"
      fi
      chown --reference="$conf" "$tmp" 2>/dev/null || true
      chmod --reference="$conf" "$tmp" 2>/dev/null || chmod 0644 "$tmp"
      mv -f "$tmp" "$conf"
      sync_path "$conf"
      sync_path "$dir"
    }

    write_state() {
      local candidate="$1" fallback="$2" phase="$3" state_dir tmp candidate_init fallback_init
      valid_label "$candidate" || die "invalid candidate label: $candidate"
      valid_label "$fallback" || die "invalid fallback label: $fallback"
      label_exists "$candidate" || die "candidate label not found: $candidate"
      label_exists "$fallback" || die "fallback label not found: $fallback"
      candidate_init="$(label_init "$candidate")" || die "candidate has no init path: $candidate"
      fallback_init="$(label_init "$fallback")" || die "fallback has no init path: $fallback"

      state_dir="$(dirname "$state")"
      mkdir -p "$state_dir"
      tmp="$(mktemp "$state_dir/.try-boot-state.XXXXXX")"
      {
        printf 'candidate=%s\n' "$candidate"
        printf 'candidate_init=%s\n' "$candidate_init"
        printf 'fallback=%s\n' "$fallback"
        printf 'fallback_init=%s\n' "$fallback_init"
        printf 'phase=%s\n' "$phase"
        date -u '+updated_at=%Y-%m-%dT%H:%M:%SZ'
      } >"$tmp"
      chmod 0644 "$tmp"
      mv -f "$tmp" "$state"
      sync_path "$state"
      sync_path "$state_dir"
    }

    state_value() {
      [ -f "$state" ] || return 1
      awk -v key="$1" '
        index($0, key "=") == 1 {
          print substr($0, length(key) + 2)
          found = 1
          exit
        }
        END { exit found ? 0 : 1 }
      ' "$state"
    }

    read_state() {
      candidate="$(state_value candidate || true)"
      candidate_init="$(state_value candidate_init || true)"
      fallback="$(state_value fallback || true)"
      fallback_init="$(state_value fallback_init || true)"

      valid_label "$candidate" || return 1
      valid_label "$fallback" || return 1
      [ -n "$candidate_init" ] || return 1
      [ -n "$fallback_init" ] || return 1
    }

    init_matches_state() {
      local label="$1" init="$2" expected_label="$3" expected_init="$4"
      # The installer emits nixos-default and a numbered entry for the same
      # system. /proc/cmdline identifies its init, not which alias U-Boot
      # selected. Accept either alias, but require the recorded candidate
      # entry to still exist and refer to the exact recorded init.
      [ -n "$label" ] && [ "$init" = "$expected_init" ] || return 1
      [ "$(label_init "$expected_label" 2>/dev/null || true)" = "$expected_init" ]
    }

    cmd_status() {
      printf 'config=%s\n' "$conf"
      if default="$(current_default 2>/dev/null)"; then
        printf 'default=%s\n' "$default"
      else
        printf 'default=<unknown>\n'
      fi
      if label="$(booted_label 2>/dev/null)"; then
        printf 'booted=%s\n' "$label"
      else
        printf 'booted=<unknown>\n'
      fi
      printf 'state=%s\n' "$state"
      if [ -s "$state" ]; then
        cat "$state"
      else
        printf 'state_present=no\n'
      fi
    }

    cmd_arm() {
      local candidate fallback
      [ "$#" -ge 1 ] || usage
      candidate="$1"
      fallback="''${2:-}"
      valid_label "$candidate" || die "invalid candidate label: $candidate"
      if [ -z "$fallback" ]; then
        fallback="$(current_default)" || die "cannot find current DEFAULT"
      fi
      valid_label "$fallback" || die "invalid fallback label: $fallback"
      [ "$candidate" != "$fallback" ] || die "candidate and fallback are both $candidate"

      write_state "$candidate" "$fallback" "armed"
      set_default "$candidate"
      log "armed $candidate with fallback $fallback"
    }

    cmd_early_rollback() {
      local booted booted_init_path
      [ -s "$state" ] || exit 0
      if ! read_state; then
        log "ignoring invalid state in $state"
        exit 0
      fi

      booted="$(booted_label 2>/dev/null || true)"
      booted_init_path="$(booted_init 2>/dev/null || true)"
      if init_matches_state "$booted" "$booted_init_path" "$candidate" "$candidate_init"; then
        set_default "$fallback"
        write_state "$candidate" "$fallback" "rollback-armed"
        log "booted try label $candidate; next boot reset to fallback $fallback"
      else
        log "try state is for $candidate but booted ''${booted:-unknown}; leaving DEFAULT unchanged"
      fi
    }

    cmd_is_candidate() {
      local booted booted_init_path
      [ -s "$state" ] || return 1
      # ExecCondition distinguishes a non-candidate (1) from corrupt state
      # (255). Never turn malformed rollback metadata into a successful check.
      read_state || { log "invalid state in $state"; return 255; }
      booted="$(booted_label 2>/dev/null || true)"
      booted_init_path="$(booted_init 2>/dev/null || true)"
      init_matches_state "$booted" "$booted_init_path" "$candidate" "$candidate_init"
    }

    cmd_bless() {
      local booted booted_init_path state_dir
      [ -s "$state" ] || exit 0
      read_state || die "invalid state in $state"
      booted="$(booted_label 2>/dev/null || true)"
      booted_init_path="$(booted_init 2>/dev/null || true)"
      if ! init_matches_state "$booted" "$booted_init_path" "$candidate" "$candidate_init"; then
        log "not blessing: booted ''${booted:-unknown}, expected $candidate"
        exit 0
      fi

      set_default "$candidate"
      state_dir="$(dirname "$state")"
      rm -f "$state"
      sync_path "$state_dir"
      log "blessed $candidate"
    }

    cmd_rollback_now() {
      local state_dir
      read_state || die "no valid try-boot state in $state"
      set_default "$fallback"
      state_dir="$(dirname "$state")"
      rm -f "$state"
      sync_path "$state_dir"
      log "rolled back to $fallback"
    }

    cmd_cancel() {
      local state_dir
      state_dir="$(dirname "$state")"
      rm -f "$state"
      sync_path "$state_dir"
      log "cancelled try-boot state"
    }

    cmd="''${1:-}"
    [ -n "$cmd" ] || usage
    shift || true

    case "$cmd" in
      status) cmd_status "$@" ;;
      current-default) current_default ;;
      booted-label) booted_label ;;
      set-default)
        [ "$#" -eq 1 ] || usage
        set_default "$1"
        ;;
      arm) cmd_arm "$@" ;;
      early-rollback) cmd_early_rollback "$@" ;;
      is-candidate) cmd_is_candidate "$@" ;;
      bless) cmd_bless "$@" ;;
      rollback-now) cmd_rollback_now "$@" ;;
      cancel) cmd_cancel "$@" ;;
      *) usage ;;
    esac
  '';
in {
  options.boot.extlinuxTryBoot = {
    enable = lib.mkEnableOption ''
      extlinux try-boot rollback support
    '';

    autoArmOnSwitch = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Arm a try-boot automatically when activation sees that extlinux
        DEFAULT no longer matches the generation that booted this system.
      '';
    };

    configPath = lib.mkOption {
      type = lib.types.str;
      default = "/boot/extlinux/extlinux.conf";
      description = "Path to the extlinux configuration file.";
    };

    statePath = lib.mkOption {
      type = lib.types.str;
      default = "/boot/extlinux/.try-boot-state";
      description = "Mutable state file used while a generation is under test.";
    };

    timeoutSec = lib.mkOption {
      type = lib.types.ints.positive;
      default = 600;
      description = "Seconds the candidate boot must survive before it is blessed.";
    };

    successCommand = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = ''
        Shell commands that must succeed after timeoutSec before the candidate
        boot is blessed.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [tryBoot];
    system.build.extlinuxTryBoot = tryBoot;

    system.activationScripts.extlinuxTryBootAutoArm = lib.mkIf cfg.autoArmOnSwitch (lib.stringAfter ["specialfs"] ''
      if [ -e /proc/cmdline ] && [ -e ${lib.escapeShellArg cfg.configPath} ]; then
        booted="$(${tryBoot}/bin/extlinux-try-boot booted-label 2>/dev/null || true)"
        default="$(${tryBoot}/bin/extlinux-try-boot current-default 2>/dev/null || true)"
        if [ -n "$booted" ] && [ -n "$default" ] && [ "$default" != "$booted" ]; then
          ${tryBoot}/bin/extlinux-try-boot arm "$default" "$booted"
        fi
      fi
    '');

    systemd.services.extlinux-try-boot-rollback = {
      description = "Reset extlinux try-boot candidate to fallback until blessed";
      wantedBy = ["sysinit.target"];
      after = ["local-fs.target"];
      before = [
        "sysinit.target"
        "basic.target"
      ];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        ${tryBoot}/bin/extlinux-try-boot early-rollback
      '';
    };

    systemd.services.extlinux-try-boot-bless = {
      description = "Bless extlinux try-boot candidate after health window";
      wantedBy = ["multi-user.target"];
      after = [
        "multi-user.target"
        "extlinux-try-boot-rollback.service"
      ];
      path = [
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.iproute2
        pkgs.systemd
      ];
      serviceConfig = {
        Type = "oneshot";
        TimeoutStartSec = "0";
        # Normal boots and boots of the fallback have nothing to bless. Skip
        # the health window before spawning sleep or running health commands;
        # units ordered after this one can then start immediately.
        ExecCondition = "${tryBoot}/bin/extlinux-try-boot is-candidate";
      };
      script = ''
        sleep ${lib.escapeShellArg (toString cfg.timeoutSec)}
        ${cfg.successCommand}
        exec ${tryBoot}/bin/extlinux-try-boot bless
      '';
    };
  };
}
