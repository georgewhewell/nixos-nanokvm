# Host-side artifact + runner builders. Pure function of:
#   - `lib`              — nixpkgs lib.
#   - `hostShellPrelude` — the bash glue shared by every runner
#                          (see lib/host-prelude.nix).
#
# Returns a function `pkgs -> { mkBootFit, mkKexecPayload, mkLiveRootfs,
# mkKexecRunner, mkUsbBootRunner, mkBoardFdt, sg2002OledOverlayDtbo,
# kernelTestBootargs, mkLiveBootargs }`.
#
# Split out of flake.nix (PLAN.md → T4) so flake.nix stays roughly the
# size of an actual flake.nix and these heavy bash bodies live in a
# named file.
{
  lib,
  hostShellPrelude,
}: pkgs: let
  mkBoardFdt = {
    board,
    kernel,
    variant ? null,
  }:
    # The wifi variant needs sdhci1 wired up (AIC8800 lives on it).
    # The OLED-only variant still uses the no-wifi DT.
    if board == "licheerv" && variant == "wifi"
    then pkgs.sg2002-dtb-mainline
    else if kernel == "vendor"
    then pkgs.sg2002-dtb-vendor-gadget
    else pkgs.sg2002-dtb-mainline-nowifi;

  sg2002OledOverlayDtbo = pkgs.runCommand "sg2002-licheerv-nano-oled.dtbo" {
    nativeBuildInputs = [pkgs.dtc];
  } ''
    dtc -@ -I dts -O dtb -o "$out" ${../dtb/sg2002-licheerv-nano-oled.dtso}
  '';

  mkBootFit = {
    board,
    kernel,
    profile,
    cfg,
    description,
  }:
    pkgs.sg2002-boot-fit {
      kernel = cfg.config.system.build.kernel;
      fdt = mkBoardFdt {inherit board kernel;};
      initrd = "${cfg.config.system.build.initialRamdisk}/initrd";
      loadAddrs = {
        kernel = "0x80200000";
        initrd = "0x85000000";
      };
      configName = "config-sg2002_licheervnano_sd";
      inherit description;
    };

  mkKexecBootargs = {
    prefix ? [],
    extra ? [],
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

  mkKexecPayload = {
    name,
    board,
    kernel,
    cfg,
    rootfsCfg ? cfg,
    variant ? null,
    oled ? false,
    extraBootargs ? [],
  }: let
    # The OLED DT overlay (dtb-mainline/sg2002-licheerv-nano-bw-oled.dtsi)
    # deliberately doesn't set /chosen/bootargs because it expects these
    # cmdline params from kexec/FIT. fbcon=font:MINI4x6 picks a 4x6 font
    # that fits the 64-row SSD1306; console=tty0 wires the kernel's
    # virtual console to fbcon so dmesg+getty paint via i²c.
    oledTag = lib.optionals oled [
      "nanokvm.kexec_target_overlay=oled"
      "fbcon=font:MINI4x6"
      "console=tty0"
    ];
  in
    pkgs.nanokvm-kexec-payload-erofs {
      inherit name;
      kernel = "${cfg.config.system.build.kernel}/Image";
      initrd = "${cfg.config.system.build.initialRamdisk}/initrd";
      dtb = mkBoardFdt {inherit board kernel variant;};
      dtbo =
        if oled
        then sg2002OledOverlayDtbo
        else null;
      cmdline = mkKexecBootargs {
        extra = extraBootargs ++ oledTag;
      };
    };

  mkLiveRootfs = cfg: pkgs.nanokvm-erofs-rootfs-for cfg.config.system.build.toplevel;

  mkKexecRunner = {
    name,
    payload,
    rootfs ? null,
    rootfsBindIp ? null,
    useRunningDtb ? false,
    applyDtbOverlay ? false,
    loadOnly ? false,
    oled ? false,
  }: let
    applyDtbOverlay' = applyDtbOverlay || oled;
    boolFlag = b:
      if b
      then "1"
      else "0";
    rootfsHost =
      if rootfsBindIp == null
      then "$nanokvm_host_ip"
      else rootfsBindIp;
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
          local existing
          # ss -tlnp's $4 is "<addr>:<port>", no trailing whitespace
          # — match against `:<port>$` so we get exact-port hits.
          existing=$(ss -tlnp -H 2>/dev/null \
            | awk -v p=":$nanokvm_port_nbd_rootfs\$" '$4 ~ p' \
            | grep -oP 'pid=\K[0-9]+' || true)
          if [ -n "''${existing:-}" ]; then
            echo "[usb-kexec] killing orphan nbd-server on :$nanokvm_port_nbd_rootfs (pids: $existing)"
            # shellcheck disable=SC2086
            kill $existing 2>/dev/null || true
            sleep 0.3
          fi
          echo "[usb-kexec] serving rootfs ${rootfs} on ${rootfsHost}:$nanokvm_port_nbd_rootfs"
          ( exec nbd-server "${rootfsHost}:$nanokvm_port_nbd_rootfs" ${rootfs} -r -d \
              2>&1 | sed -u 's/^/[nbd-rootfs] /' ) &
          rootfs_nbd_pid=$!
          sleep 0.5
          if ! kill -0 "$rootfs_nbd_pid" 2>/dev/null; then
            echo "[usb-kexec] rootfs nbd-server exited early" >&2
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
        # /dev/nbd0 cost an extra 0.5-2 s. PLAN.md → T7 is the proper
        # fix (static-linked kexec micro-env).
        sleep 8
        start_rootfs_nbd || exit 1
        echo "[usb-kexec] rootfs nbd handed off; new kernel's initrd will connect here"
        wait "$rootfs_nbd_pid"
      ''
      else ''
        echo "[usb-kexec] command sent; watching for target status"
        sleep 90
      '';
  in
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = with pkgs; [
        bash
        coreutils
        gnugrep
        gnused
        iproute2 # ip + ss (latter is used to find orphan nbd-server)
        nbd
        netcat-openbsd
      ];
      text = ''
        ${hostShellPrelude}

        payload_nbd_pid=
        rootfs_nbd_pid=
        status_pid=

        cleanup() {
          for pid in "$status_pid" "$payload_nbd_pid" "$rootfs_nbd_pid"; do
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
              kill "$pid" 2>/dev/null || true
              wait "$pid" 2>/dev/null || true
            fi
          done
        }
        trap cleanup EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM

        configure_host_iface usb-kexec >/dev/null || exit 1

        echo "[usb-kexec] listening for target status on $nanokvm_host_ip:$nanokvm_port_status"
        nc -lk -s "$nanokvm_host_ip" -p "$nanokvm_port_status" &
        status_pid=$!

        ${rootfsService false}

        echo "[usb-kexec] serving kexec payload ${payload} on $nanokvm_host_ip:$nanokvm_port_nbd_payload"
        nbd-server "$nanokvm_host_ip:$nanokvm_port_nbd_payload" ${payload} -r -n &
        payload_nbd_pid=$!
        sleep 0.5
        if ! kill -0 "$payload_nbd_pid" 2>/dev/null; then
          echo "[usb-kexec] payload nbd-server exited early" >&2
          wait "$payload_nbd_pid"
        fi

        target_request="payload_host=$nanokvm_host_ip payload_port=$nanokvm_port_nbd_payload use_running_dtb=${boolFlag useRunningDtb} apply_dtb_overlay=${boolFlag applyDtbOverlay'} load_only=${boolFlag loadOnly}"

        echo "[usb-kexec] sending request to $nanokvm_target_ip:$nanokvm_port_kexec"
        kexec_send_request "$target_request" || {
          echo "[usb-kexec] failed to start target kexec agent" >&2
          exit 1
        }

        ${postInjectSwap}
      '';
    };

  mkUsbBootRunner = {
    name,
    fit,
    rootfs ? null,
    bootargs,
    attachPicocom ? false,
    waitForSsh ? false,
  }: let
    rootfsService = lib.optionalString (rootfs != null) ''
      echo "[usb-boot] serving ${rootfs} on $nanokvm_host_ip:$nanokvm_port_nbd_rootfs"
      nbd-server "$nanokvm_host_ip:$nanokvm_port_nbd_rootfs" ${rootfs} -r -n &
      nbd_pid=$!
      sleep 0.5
      if ! kill -0 "$nbd_pid" 2>/dev/null; then
        echo "[usb-boot] nbd-server exited early" >&2
        wait "$nbd_pid"
      fi
    '';
    # Host-side host-key handling. Only relevant when the variant
    # actually runs stage 2 sshd (waitForSsh path). Keeps personal
    # pubkeys out of the nix store AND skips the SG2002's ~60 s
    # wall-clock sshd-keygen by pre-installing keys into the
    # initrd's /etc-overlay upperdir.
    #
    # Storage: $PWD/.ssh_host_{ed25519,rsa}_key (gitignored).
    # Reuses on subsequent boots so SSH known_hosts stays stable.
    # Env knobs:
    #   NANOKVM_HOST_KEY_DIR — override default ($PWD)
    #   NANOKVM_HOST_KEY_GENERATE=0 — skip the whole step
    #   NANOKVM_HOST_KEY_PERSIST=0 — generated keys not written back
    hostKeysInject = lib.optionalString waitForSsh ''
      if [ "''${NANOKVM_HOST_KEY_GENERATE:-1}" = 0 ]; then
        echo "[usb-boot] NANOKVM_HOST_KEY_GENERATE=0, skipping host-key push"
      else
        host_key_dir="''${NANOKVM_HOST_KEY_DIR:-$PWD}"
        host_key_ed="$host_key_dir/.ssh_host_ed25519_key"
        host_key_rsa="$host_key_dir/.ssh_host_rsa_key"
        generated_any=0
        for kt in ed25519 rsa; do
          kf="$host_key_dir/.ssh_host_''${kt}_key"
          if [ ! -s "$kf" ] || [ ! -s "$kf.pub" ]; then
            echo "[usb-boot] generating new host-$kt key at $kf"
            generated_any=1
            # ssh-keygen exits before printing newline on -q sometimes;
            # force file create and capture errors.
            rm -f "$kf" "$kf.pub"
            ssh-keygen -t "$kt" -N "" -C "nanokvm-host-key" -f "$kf" -q
            # The runner is usually invoked via `sudo` (for fastboot
            # USB access), so newly created files end up owned by
            # root. If $SUDO_USER is set, hand them back so the dev
            # can manage them normally.
            if [ -n "''${SUDO_USER:-}" ] && [ "$(id -u)" = 0 ]; then
              chown "$SUDO_USER" "$kf" "$kf.pub" 2>/dev/null || true
            fi
          fi
        done
        host_key_cleanup=()
        if [ "$generated_any" = 1 ] \
            && [ "''${NANOKVM_HOST_KEY_PERSIST:-1}" = 0 ]; then
          echo "[usb-boot] NANOKVM_HOST_KEY_PERSIST=0; cleaning up generated keys"
          # Defer cleanup until end of script. Use a bash array (not a
          # space-joined string) so paths containing spaces don't get
          # word-split into something like `rm -f /home/grw/my src/...`.
          host_key_cleanup=("$host_key_ed" "$host_key_ed.pub" "$host_key_rsa" "$host_key_rsa.pub")
        fi

        echo "[usb-boot] waiting for initrd debug shell on :$nanokvm_port_shell..."
        shell_ready=0
        for _ in $(seq 1 120); do
          if timeout 1 bash -c ":</dev/tcp/$nanokvm_target_ip/$nanokvm_port_shell" 2>/dev/null; then
            shell_ready=1
            break
          fi
          sleep 0.5
        done
        if [ "$shell_ready" != 1 ]; then
          echo "[usb-boot] WARN: debug shell never opened; skipping host-key push (sshd will keygen on device, ~60 s)"
        else
          echo "[usb-boot] pushing host keys via telnet :$nanokvm_port_shell"
          # The receiver runs as busybox sh in initrd, scripted to wait
          # for /sysroot/.rw-etc/upper (created by nixos rw-etc.service
          # before initrd-fs.target) and then drop the keys there. Uses
          # heredocs with unique markers since keys are multi-line.
          {
            printf '%s\n' "for i in \$(seq 1 120); do [ -d /sysroot/.rw-etc/upper ] && break; sleep 0.5; done"
            printf '%s\n' "if [ ! -d /sysroot/.rw-etc/upper ]; then echo HOSTKEY_NO_UPPER; exit 1; fi"
            printf '%s\n' "mkdir -p /sysroot/.rw-etc/upper/ssh"
            printf '%s\n' "umask 077"
            for spec in "ed25519:$host_key_ed:__NANOKVM_KEY_ED__" \
                        "ed25519.pub:$host_key_ed.pub:__NANOKVM_KEY_EDPUB__" \
                        "rsa:$host_key_rsa:__NANOKVM_KEY_RSA__" \
                        "rsa.pub:$host_key_rsa.pub:__NANOKVM_KEY_RSAPUB__"; do
              IFS=: read -r suffix src tag <<<"$spec"
              base="ssh_host_$(echo "$suffix" | sed 's/\.pub/_key.pub/; t; s/$/_key/')"
              printf '%s\n' "cat > /sysroot/.rw-etc/upper/ssh/$base <<'$tag'"
              cat "$src"
              printf '%s\n' "$tag"
            done
            printf '%s\n' "chmod 600 /sysroot/.rw-etc/upper/ssh/ssh_host_ed25519_key /sysroot/.rw-etc/upper/ssh/ssh_host_rsa_key"
            printf '%s\n' "chmod 644 /sysroot/.rw-etc/upper/ssh/ssh_host_ed25519_key.pub /sysroot/.rw-etc/upper/ssh/ssh_host_rsa_key.pub"
            printf '%s\n' "echo HOSTKEYS_INSTALLED"
            printf '%s\n' "exit"
          } | nc -w 20 "$nanokvm_target_ip" "$nanokvm_port_shell" 2>&1 \
            | sed -u 's/^/[host-keys] /' \
            | tee /tmp/nanokvm-hostkeys.log >/dev/null
          if grep -q HOSTKEYS_INSTALLED /tmp/nanokvm-hostkeys.log; then
            echo "[usb-boot] host keys installed; sshd-keygen will skip on device"
          else
            echo "[usb-boot] WARN: host-key push didn't confirm; check /tmp/nanokvm-hostkeys.log"
          fi
        fi
      fi
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
      exec picocom --baud 115200 --noinit --logfile "$log" "$acm"
    '';
    wait = lib.optionalString (rootfs != null) ''
      echo "[usb-boot] leave this process running; Ctrl-C stops the NBD backing store"
      wait "$nbd_pid"
    '';
  in
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = with pkgs; [
        android-tools
        bash
        coreutils
        gnugrep
        iproute2
        nbd
        netcat-openbsd
        openssh # ssh-keygen for the host-key generation step
        picocom
      ];
      text = ''
        ${hostShellPrelude}

        nbd_pid=
        status_pid=

        cleanup() {
          for pid in "$status_pid" "$nbd_pid"; do
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
              kill "$pid" 2>/dev/null || true
              wait "$pid" 2>/dev/null || true
            fi
          done
        }
        trap cleanup EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM

        ${pkgs.sg2002-usb-boot}/bin/usb-boot-mainline \
          --bootargs ${lib.escapeShellArg bootargs} \
          ${fit} "$@"

        configure_host_iface usb-boot >/dev/null || exit 1

        echo "[usb-boot] listening for target status on $nanokvm_host_ip:$nanokvm_port_status"
        nc -lk -s "$nanokvm_host_ip" -p "$nanokvm_port_status" &
        status_pid=$!

        ${rootfsService}

        ${hostKeysInject}

        ${sshWait}

        ${picocomTail}

        ${wait}

        ${lib.optionalString waitForSsh ''
          if [ "''${#host_key_cleanup[@]}" -gt 0 ]; then
            rm -f "''${host_key_cleanup[@]}"
          fi
        ''}
      '';
    };

  kernelTestBootargs = mkKexecBootargs {};

  mkLiveBootargs = {
    cfg,
    extra ? [],
  }:
    mkKexecBootargs {
      extra = ["init=${cfg.config.system.build.toplevel}/init"] ++ extra;
    };
in {
  inherit
    mkBootFit
    mkKexecPayload
    mkLiveRootfs
    mkKexecRunner
    mkUsbBootRunner
    mkBoardFdt
    sg2002OledOverlayDtbo
    kernelTestBootargs
    mkLiveBootargs
    ;
}
