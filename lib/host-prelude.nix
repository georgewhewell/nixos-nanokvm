# Bash prelude included verbatim in every host-side runner produced by
# lib/runners.nix. Defines the protocol constants (from lib/protocol.nix)
# and the helper functions every runner shares — interface lookup,
# `sudo` wrapper, NBD-server orphan handling, kexec request sender, ACM
# device discovery for picocom.
#
# Pure: takes the protocol attrset and returns the string. No
# dependencies on flake context. Consumers do:
#
#     hostShellPrelude = import ./lib/host-prelude.nix protocol;
#
# and interpolate `${hostShellPrelude}` at the top of a runner script.
protocol: ''
  export nanokvm_target_mac=${protocol.targetMac}
  export nanokvm_host_mac=${protocol.hostMac}
  export nanokvm_target_ip=${protocol.targetIp}
  export nanokvm_host_ip=${protocol.hostIp}
  export nanokvm_prefix=${protocol.prefix}
  export nanokvm_port_shell=${toString protocol.ports.debugShell}
  export nanokvm_port_status=${toString protocol.ports.statusSink}
  export nanokvm_port_kexec=${toString protocol.ports.kexecCtrl}
  export nanokvm_port_nbd_rootfs=${toString protocol.ports.nbdRootfs}
  export nanokvm_port_nbd_payload=${toString protocol.ports.nbdPayload}

  as_root() {
    if [ "$(id -u)" -eq 0 ]; then
      "$@"
    else
      sudo -n "$@"
    fi
  }

  find_usb_iface() {
    shopt -s nullglob
    local path mac
    for path in /sys/class/net/*; do
      [ -e "$path/address" ] || continue
      mac="$(cat "$path/address" 2>/dev/null || true)"
      if [ "$mac" = "$nanokvm_host_mac" ]; then
        basename "$path"
        return 0
      fi
    done
    return 1
  }

  wait_usb_iface() {
    local timeout="''${1:-40}" iface
    local attempts=$(( timeout * 4 ))
    for _ in $(seq 1 "$attempts"); do
      if [ -n "''${USB_IFACE:-}" ]; then
        if [ -d "/sys/class/net/$USB_IFACE" ]; then
          printf '%s\n' "$USB_IFACE"
          return 0
        fi
      else
        iface="$(find_usb_iface || true)"
        if [ -n "$iface" ]; then
          printf '%s\n' "$iface"
          return 0
        fi
      fi
      sleep 0.25
    done
    return 1
  }

  wait_tcp() {
    local host="$1" port="$2" timeout="''${3:-40}"
    local attempts=$(( timeout * 4 ))
    for _ in $(seq 1 "$attempts"); do
      if nc -z -w 1 "$host" "$port" >/dev/null 2>&1; then
        return 0
      fi
      sleep 0.25
    done
    return 1
  }

  configure_host_iface() {
    local label="''${1:-host}" iface
    iface="$(wait_usb_iface 40)" || {
      echo "[$label] timed out waiting for USB ECM interface; set USB_IFACE=name to override detection" >&2
      return 1
    }
    if ! as_root true 2>/dev/null; then
      echo "[$label] passwordless sudo/root is required to configure $iface" >&2
      return 1
    fi
    as_root ip link set "$iface" nomaster 2>/dev/null || true
    as_root ip addr replace "$nanokvm_host_ip/$nanokvm_prefix" dev "$iface"
    as_root ip link set "$iface" up
    echo "[$label] configured $iface as $nanokvm_host_ip/$nanokvm_prefix"
    printf '%s\n' "$iface"
  }

  list_acm() {
    shopt -s nullglob
    local d
    for d in /dev/ttyACM*; do
      [ -c "$d" ] && printf '%s\n' "$d"
    done
  }

  wait_acm() {
    local before="$1"
    local after new
    for _ in $(seq 1 160); do
      after="$(list_acm | sort)"
      new="$(
        comm -13 \
          <(printf '%s\n' "$before") \
          <(printf '%s\n' "$after") \
          | head -n1
      )"
      if [ -n "$new" ] && [ -c "$new" ]; then
        printf '%s\n' "$new"
        return 0
      fi
      new="$(printf '%s\n' "$after" | head -n1)"
      if [ -n "$new" ] && [ -c "$new" ]; then
        printf '%s\n' "$new"
        return 0
      fi
      sleep 0.25
    done
    return 1
  }

  kexec_send_request() {
    # Retry only if the connection itself failed. Once we get any
    # response, it's authoritative — `^OK ` means the agent
    # accepted the request, anything else is a real error.
    local request="$1" response
    local attempts="''${2:-120}"
    for _ in $(seq 1 "$attempts"); do
      response="$(printf '%s\n' "$request" | nc -N -w 5 "$nanokvm_target_ip" "$nanokvm_port_kexec" || true)"
      if [ -n "$response" ]; then
        printf '%s\n' "$response"
        printf '%s\n' "$response" | grep -q '^OK '
        return $?
      fi
      sleep 0.25
    done
    return 1
  }
''
