# Host-side artifact + runner builders. Pure function of:
#   - `lib`              — nixpkgs lib.
#   - `hostShellPrelude` — the bash glue shared by every runner
#                          (see lib/host-prelude.nix).
#
# Returns a function `pkgs -> { mkBootFit, mkKexecPayload, mkLiveRootfs,
# mkKexecRunner, mkUsbBootRunner, sg2002OledOverlayDtbo,
# kernelTestBootargs, mkLiveBootargs }`.
#
# Split out of flake.nix so flake.nix stays roughly the size of an
# actual flake.nix and these heavy bash bodies live in a named file.
{ lib
, hostShellPrelude
,
}: pkgs:
let
  # Select the board DTB for direct FIT boot and kexec payloads. The
  # NB: the DTB is no longer chosen here — every board's
  # `config.sg2002.fdt` is the single source of truth (set by the
  # platform default + the WiFi/OLED/ethernet modules). mkBootFit and
  # mkKexecPayload read it straight off the resolved NixOS config.
  mkFeatureBootargs = { oled ? false }:
    lib.optionals oled [
      "fbcon=font:MINI4x6"
      "fbcon=rotate:1"
    ];

  mkKexecFeatureBootargs = { oled ? false }:
    lib.optionals oled [ "nanokvm.kexec_target_overlay=oled" ]
    ++ mkFeatureBootargs { inherit oled; };


  sg2002OledOverlayDtbo =
    pkgs.runCommand "sg2002-licheerv-nano-oled.dtbo"
      {
        nativeBuildInputs = [ pkgs.dtc ];
      } ''
      dtc -@ -I dts -O dtb -o "$out" ${../dtb/sg2002-licheerv-nano-oled.dtso}
    '';

  mkBootFit =
    { profile
    , cfg
    , description
    ,
    }:
    pkgs.sg2002-boot-fit {
      kernel = cfg.config.system.build.kernel;
      # Single source of truth — the board config already resolved which
      # DTB to boot (platform default + WiFi/OLED/ethernet modules).
      fdt = cfg.config.sg2002.fdt;
      initrd = "${cfg.config.system.build.initialRamdisk}/initrd";
      loadAddrs = {
        kernel = "0x80200000";
        initrd = "0x85000000";
      };
      configName = "config-sg2002_licheervnano_sd";
      inherit description;
    };

  mkKexecBootargs =
    { prefix ? [ ]
    , extra ? [ ]
    ,
    }:
    lib.concatStringsSep " " (prefix
      ++ [
      "console=ttyGS0,115200"
      "console=ttyS0,115200"
      "earlycon=sbi"
      "ignore_loglevel"
      "panic=10"
      "oops=panic"
      "riscv.fwsz=0x80000"
    ]
      ++ extra);

  oledBootargs = mkFeatureBootargs { oled = true; };

  mkKexecPayload =
    { name
    , cfg
    , rootfsCfg ? cfg
    , oled ? false
    , extraBootargs ? [ ]
    ,
    }:
    let
      # The OLED DTs deliberately don't set /chosen/bootargs because the
      # direct FIT and kexec paths both provide cmdline params here.
      featureBootargs = mkKexecFeatureBootargs { inherit oled; };
    in
    pkgs.nanokvm-kexec-payload-erofs {
      inherit name;
      kernel = "${cfg.config.system.build.kernel}/Image";
      initrd = "${cfg.config.system.build.initialRamdisk}/initrd";
      dtb = cfg.config.sg2002.fdt;
      dtbo =
        if oled
        then sg2002OledOverlayDtbo
        else null;
      cmdline = mkKexecBootargs {
        extra = extraBootargs ++ featureBootargs;
      };
    };

  mkLiveRootfs = cfg: pkgs.nanokvm-erofs-rootfs-for cfg.config.system.build.toplevel;

  mkRootfsRuntimeSetup =
    { label
    , rootfsBindIp ? null
    , requireRootfsHostOverride ? false
    ,
    }:
    let
      rootfsHostDefault =
        if rootfsBindIp == null
        then "$nanokvm_host_ip"
        else rootfsBindIp;
      rootfsBindDefault =
        if rootfsBindIp == null
        then ""
        else rootfsBindIp;
    in
    ''
      ${lib.optionalString requireRootfsHostOverride ''
        if [ -z "''${NANOKVM_NBD_ROOTFS_HOST:-}" ]; then
          echo "[${label}] NANOKVM_NBD_ROOTFS_HOST is required for this variant; set it to the host address reachable from the target network" >&2
          echo "[${label}] optionally set NANOKVM_NBD_ROOTFS_BIND to the local address nbd-server should bind" >&2
          exit 1
        fi
      ''}
      rootfs_host="''${NANOKVM_NBD_ROOTFS_HOST:-${rootfsHostDefault}}"
      rootfs_bind="''${NANOKVM_NBD_ROOTFS_BIND:-${rootfsBindDefault}}"
      rootfs_port_request="''${NANOKVM_NBD_ROOTFS_PORT:-auto}"
      rootfs_port="$(choose_tcp_port "$rootfs_port_request")" || exit 1
      nanokvm_port_nbd_rootfs="$rootfs_port"
      rootfs_endpoint="$(nbd_endpoint "$rootfs_bind" "$rootfs_port")"
      echo "[${label}] selected rootfs NBD endpoint candidate: $rootfs_endpoint; target will connect to $rootfs_host:$rootfs_port"
    '';

  mkKexecRunner =
    { name
    , payload
    , rootfs ? null
    , rootfsBindIp ? null
    , requireRootfsHostOverride ? false
    , useRunningDtb ? false
    , applyDtbOverlay ? false
    , loadOnly ? false
    , oled ? false
    ,
    }:
    let
      applyDtbOverlay' = applyDtbOverlay || oled;
      boolFlag = b:
        if b
        then "1"
        else "0";
      # Serve the rootfs nbd-server, killing any orphan bound to the
      # port first. Two flows want different timing:
      #
      #   - First boot from initrd: the rootfs has to be live BEFORE
      #     we send the kexec request because the new kernel's
      #     initrd is the first user. Use `preInject=1`.
      #   - Stage2→stage2 kexec with a NEW rootfs: an OLD nbd-server
      #     is already serving the running rootfs; killing/replacing
      #     it before the source userspace has finished kexec()ing
      #     poisons the running erofs cache. Defer the swap until
      #     after the request is ACK'd and the agent has had time
      #     to load its payload. Use `preInject=0`.
      rootfsService = preInject:
        lib.optionalString (rootfs != null) ''
          start_rootfs_nbd() {
            local rootfs_nbd_config rootfs_nbd_log
            free_tcp_listener usb-kexec "$nanokvm_port_nbd_rootfs" || return 1
            echo "[usb-kexec] serving rootfs ${rootfs} on $rootfs_endpoint"
            rootfs_nbd_config="$(write_nbd_config erofs-rootfs "$rootfs_bind" "$nanokvm_port_nbd_rootfs" rootfs ${rootfs})"
            rootfs_nbd_log="$(mktemp -t nanokvm-rootfs-nbd-XXXXXX.log)"
            nbd-server -C "$rootfs_nbd_config" -d >"$rootfs_nbd_log" 2>&1 &
            rootfs_nbd_pid=$!
            sleep 0.5
            if ! kill -0 "$rootfs_nbd_pid" 2>/dev/null; then
              echo "[usb-kexec] rootfs nbd-server exited early" >&2
              sed -u 's/^/[nbd-rootfs] /' "$rootfs_nbd_log" >&2 || true
              wait "$rootfs_nbd_pid" || true
              return 1
            fi
          }
          ${lib.optionalString preInject "start_rootfs_nbd"}
        '';
      postInjectSwap =
        if rootfs != null
        then ''
          # Give the agent time to: connect /dev/nbd1, mount payload
          # erofs, kexec -c -l (reads ~40 MB of kernel+initrd from NBD
          # at ~20 MB/s), disconnect payload, report, kexec -e. 8 s is
          # generous on a cv1800; the agent typically finishes in 2-4 s
          # but under memory pressure (when prepare-kexec-stage's
          # vmtouch primes got evicted) the bash/glibc reads from
          # /dev/nbd0 cost an extra 0.5-2 s.
          sleep 8
          start_rootfs_nbd || exit 1
          echo "[usb-kexec] rootfs nbd handed off; new kernel's initrd will connect here"
          case "''${NANOKVM_ATTACH:-shell}" in
            shell|"")
              attach_debug_shell_after_reconnect usb-kexec 45 240 || true
              echo "[usb-kexec] shell detached; rootfs NBD is still running. Ctrl-C stops it."
              ;;
            none)
              echo "[usb-kexec] not attaching to target shell; rootfs NBD is running"
              ;;
            *)
              echo "[usb-kexec] invalid NANOKVM_ATTACH=''${NANOKVM_ATTACH}; expected shell or none" >&2
              exit 1
              ;;
          esac
          wait "$rootfs_nbd_pid"
        ''
        else ''
          echo "[usb-kexec] command sent"
          case "''${NANOKVM_ATTACH:-shell}" in
            shell|"") attach_debug_shell_after_reconnect usb-kexec 45 180 || true ;;
            none) sleep 90 ;;
            *)
              echo "[usb-kexec] invalid NANOKVM_ATTACH=''${NANOKVM_ATTACH}; expected shell or none" >&2
              exit 1
              ;;
          esac
        '';
    in
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = with pkgs; [
        bash
        coreutils
        gnugrep
        gnused
        inetutils # telnet client for the target busybox telnetd
        iproute2 # ip + ss (latter is used to find orphan nbd-server)
        nbd
        netcat-openbsd
        systemd # networkctl for host-side networkd runtime overrides
      ];
      text = ''
        ${hostShellPrelude}

        payload_nbd_pid=
        rootfs_nbd_pid=
        status_pid=

        cleanup() {
          for pid in "$status_pid" "$payload_nbd_pid" "$rootfs_nbd_pid"; do
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
              kill_process_tree "$pid"
            fi
          done
        }
        trap cleanup EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM

        ${lib.optionalString (rootfs != null) (mkRootfsRuntimeSetup {
          label = "usb-kexec";
          inherit rootfsBindIp requireRootfsHostOverride;
        })}

        configure_host_iface usb-kexec >/dev/null || exit 1

        start_status_sink usb-kexec

        ${rootfsService false}

        payload_nbd_log="$(mktemp -t nanokvm-payload-nbd-XXXXXX.log)"
        echo "[usb-kexec] serving kexec payload ${payload} on $nanokvm_host_ip:$nanokvm_port_nbd_payload"
        nbd-server "$nanokvm_host_ip:$nanokvm_port_nbd_payload" ${payload} -r -n >"$payload_nbd_log" 2>&1 &
        payload_nbd_pid=$!
        sleep 0.5
        if ! kill -0 "$payload_nbd_pid" 2>/dev/null; then
          echo "[usb-kexec] payload nbd-server exited early" >&2
          sed -u 's/^/[nbd-payload] /' "$payload_nbd_log" >&2 || true
          wait "$payload_nbd_pid"
        fi

        target_request="payload_host=$nanokvm_host_ip payload_port=$nanokvm_port_nbd_payload use_running_dtb=${boolFlag useRunningDtb} apply_dtb_overlay=${boolFlag applyDtbOverlay'} load_only=${boolFlag loadOnly}"
        ${lib.optionalString (rootfs != null) ''
          target_request="$target_request rootfs_host=$rootfs_host rootfs_port=$rootfs_port"
        ''}

        echo "[usb-kexec] sending request to $nanokvm_target_ip:$nanokvm_port_kexec"
        kexec_send_request "$target_request" || {
          echo "[usb-kexec] failed to start target kexec agent" >&2
          exit 1
        }

        ${postInjectSwap}
      '';
    };

  mkUsbBootRunner =
    { name
    , fit
    , rootfs ? null
    , bootargs
    , rootfsBindIp ? null
    , requireRootfsHostOverride ? false
    , attachPicocom ? false
    , waitForSsh ? false
    , onShellDetachCommand ? null
    ,
    }:
    let
      rootfsService = lib.optionalString (rootfs != null) ''
        start_rootfs_nbd() {
          local attempt max_attempts rootfs_nbd_config rootfs_nbd_log

          cleanup_nanokvm_rootfs_nbd usb-boot || true
          case "$rootfs_port_request" in
            ""|auto|0) max_attempts=20 ;;
            *) max_attempts=1 ;;
          esac

          for attempt in $(seq 1 "$max_attempts"); do
            if [ "$attempt" != 1 ]; then
              rootfs_port="$(choose_tcp_port "$rootfs_port_request")" || return 1
              nanokvm_port_nbd_rootfs="$rootfs_port"
              rootfs_endpoint="$(nbd_endpoint "$rootfs_bind" "$rootfs_port")"
            fi

            if [ "$max_attempts" = 1 ]; then
              free_tcp_listener usb-boot "$rootfs_port" || return 1
              echo "[usb-boot] serving ${rootfs} on $rootfs_endpoint"
            else
              echo "[usb-boot] serving ${rootfs} on $rootfs_endpoint (attempt $attempt/$max_attempts)"
            fi

            rootfs_nbd_config="$(write_nbd_config erofs-rootfs "$rootfs_bind" "$rootfs_port" rootfs ${rootfs})"
            rootfs_nbd_log="$(mktemp -t nanokvm-rootfs-nbd-XXXXXX.log)"
            nbd-server -C "$rootfs_nbd_config" -d >"$rootfs_nbd_log" 2>&1 &
            nbd_pid=$!
            sleep 0.5
            if kill -0 "$nbd_pid" 2>/dev/null; then
              echo "[usb-boot] rootfs NBD endpoint: $rootfs_endpoint; target connects to $rootfs_host:$rootfs_port"
              return 0
            fi

            echo "[usb-boot] nbd-server exited early on $rootfs_endpoint" >&2
            sed -u 's/^/[nbd-rootfs] /' "$rootfs_nbd_log" >&2 || true
            wait "$nbd_pid" 2>/dev/null || true
            nbd_pid=
            [ "$max_attempts" != 1 ] || return 1
            sleep 0.1
          done

          echo "[usb-boot] unable to start rootfs nbd-server after $max_attempts attempts" >&2
          return 1
        }

        start_rootfs_nbd || exit 1
      '';
      sshWait = lib.optionalString waitForSsh ''
        echo "[usb-boot] waiting for SSH on root@$nanokvm_target_ip..."
        ssh_ready=0
        for _ in $(seq 1 180); do
          if timeout 1 bash -c ":</dev/tcp/$nanokvm_target_ip/22" 2>/dev/null; then
            ssh_ready=1
            break
          fi
          if [ -n "''${nbd_pid:-}" ] && ! kill -0 "$nbd_pid" 2>/dev/null; then
            echo "[usb-boot] nbd-server exited while the device was booting" >&2
            wait "$nbd_pid"
          fi
          sleep 1
        done
        if [ "$ssh_ready" = 1 ]; then
          echo "[usb-boot] SSH is up: ssh root@$nanokvm_target_ip (password: nixos)"
          echo "[usb-boot] NanoKVM web app target: http://$nanokvm_target_ip/"
        else
          echo "[usb-boot] SSH did not answer yet; keeping NBD server running for inspection"
        fi
      '';
      picocomTail = lib.optionalString attachPicocom ''
        before_acm="$(list_acm | sort)"
        acm="$(wait_acm "$before_acm")" || {
          echo "[usb-boot] timed out waiting for /dev/ttyACM*" >&2
          exit 1
        }
        log="$(mktemp -t nanokvm-usb-boot-XXXXXX.log)"
        echo "[usb-boot] attaching picocom to $acm"
        echo "[usb-boot] full session is also being written to $log"
        picocom --baud 115200 --noinit --logfile "$log" "$acm"
      '';
      wait = lib.optionalString (rootfs != null) ''
        echo "[usb-boot] leave this process running; Ctrl-C stops the NBD backing store"
        wait "$nbd_pid"
      '';
      shellTail = ''
        attach_debug_shell usb-boot 240 || true
        ${lib.optionalString (rootfs != null) ''
          case "''${NANOKVM_ON_DETACH:-hold}" in
            hold|"")
              echo "[usb-boot] shell detached; rootfs NBD is still running. Ctrl-C stops it."
              wait "$nbd_pid"
              ;;
            kexec)
              ${if onShellDetachCommand != null then ''
                echo "[usb-boot] shell detached; kexecing target to the next image..."
                ${onShellDetachCommand}
              '' else ''
                echo "[usb-boot] NANOKVM_ON_DETACH=kexec is not available for this runner" >&2
                wait "$nbd_pid"
              ''}
              ;;
            exit)
              echo "[usb-boot] shell detached; stopping rootfs NBD"
              exit 0
              ;;
            *)
              echo "[usb-boot] invalid NANOKVM_ON_DETACH=''${NANOKVM_ON_DETACH}; expected hold, kexec, or exit" >&2
              exit 1
              ;;
          esac
        ''}
      '';
      attachTail = ''
        case "''${NANOKVM_ATTACH:-shell}" in
          shell|"")
            ${shellTail}
            ;;
          picocom)
            ${if attachPicocom
              then ''
                ${picocomTail}
                ${wait}
              ''
              else ''
                echo "[usb-boot] NANOKVM_ATTACH=picocom is only available for ACM/debug variants" >&2
                exit 1
              ''}
            ;;
          none)
            ${wait}
            ;;
          *)
            echo "[usb-boot] invalid NANOKVM_ATTACH=''${NANOKVM_ATTACH}; expected shell, picocom, or none" >&2
            exit 1
            ;;
        esac
      '';
    in
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = with pkgs; [
        android-tools
        bash
        coreutils
        gnugrep
        inetutils # telnet client for the target busybox telnetd
        iproute2
        nbd
        netcat-openbsd
        picocom
        systemd # networkctl for host-side networkd runtime overrides
      ];
      text = ''
        ${hostShellPrelude}

        nbd_pid=
        status_pid=

        cleanup() {
          for pid in "$status_pid" "$nbd_pid"; do
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
              kill_process_tree "$pid"
            fi
          done
        }
        trap cleanup EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM

        bootargs=${lib.escapeShellArg bootargs}
        case "''${1:-}" in
          -h|--help)
            exec ${pkgs.sg2002-usb-boot}/bin/usb-boot-mainline \
              --bootargs "$bootargs" \
              ${fit} "$@"
            ;;
        esac

        ${lib.optionalString (rootfs != null) ''
          ${mkRootfsRuntimeSetup {
            label = "usb-boot";
            inherit rootfsBindIp requireRootfsHostOverride;
          }}
          ${rootfsService}

          bootargs="$bootargs nanokvm.nbd_rootfs_host=$rootfs_host nanokvm.nbd_rootfs_port=$rootfs_port"
        ''}

        ${pkgs.sg2002-usb-boot}/bin/usb-boot-mainline \
          --bootargs "$bootargs" \
          ${fit} "$@"

        configure_host_iface usb-boot >/dev/null || exit 1

        start_status_sink usb-boot

        ${sshWait}

        ${attachTail}

      '';
    };

  kernelTestBootargs = mkKexecBootargs { };

  mkLiveBootargs =
    { cfg
    , extra ? [ ]
    , oled ? false
    ,
    }:
    mkKexecBootargs {
      extra =
        [ "init=${cfg.config.system.build.toplevel}/init" ]
        ++ extra
        ++ mkFeatureBootargs { inherit oled; };
    };
in
{
  inherit
    mkBootFit
    mkKexecPayload
    mkLiveRootfs
    mkKexecRunner
    mkUsbBootRunner
    sg2002OledOverlayDtbo
    mkFeatureBootargs
    oledBootargs
    kernelTestBootargs
    mkLiveBootargs
    ;
}
