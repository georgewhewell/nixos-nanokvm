# Catalog of board × kernel × profile × variant combinations.
#
# One record per shipped configuration. lib/catalog.nix is the single
# source of truth for what `nixosConfigurations.boards.<...>` and
# `packages.<sys>.boards.<...>` expose; flake.nix doesn't repeat the
# matrix on the artifact side anymore.
#
# Record schema:
#   path         — list-of-string attrpath in `boards`:
#                  ["licheerv" "mainline" "live" "usb-rndis"]
#   boardName    — the module file under ./boards/ (e.g. "licheerv-nano-w")
#   kernel       — "mainline" | "vendor"
#   profile      — module name under ./profiles/ (no ".nix" suffix)
#   variant      — short variant name, used for DTB selection on the
#                  artifact side. Null when not applicable.
#   tag          — payload/runner identifier baked into filenames and
#                  the `nanokvm.kexec_target=` cmdline arg. Keep stable
#                  across refactors so on-device diagnostics don't drift.
#   mixins       — extra module file paths
#   modules      — extra inline module functions
#   artifact     — "kernel-test" | "live" | "debug" | "sd"
#                  drives which artifact-builder runs.
#   artifactArgs — key/value extras forwarded to the artifact builder
#                  (oled, rootfsBindIp, extraBootargs, includeKexec).
#   liveCfgPath  — `debug` artifacts only: the catalog path that
#                  supplies the rootfs the debug payload pivots into.
#
# Anything not listed here is intentionally absent — vendor variant
# transports, vendor.kexec runners, etc. — those don't work, so they
# don't exist.
{ lib }:
let
  lichee =
    kernel: pathTail: attrs:
    {
      path = [ "licheerv" kernel ] ++ pathTail;
      boardName = "licheerv-nano-w";
      inherit kernel;
    }
    // attrs;

  licheeProfile =
    kernel: pathTail: profile: artifact: tag: attrs:
    lichee kernel pathTail (
      {
        inherit profile artifact tag;
      }
      // attrs
    );

  kernelTest = kernel:
    licheeProfile
      kernel
      [ "kernel-test" ]
      "usb-kernel-test"
      "kernel-test"
      "kernel-test-${kernel}"
      { };

  debug = kernel:
    licheeProfile
      kernel
      [ "debug" ]
      "usb-debug"
      "debug"
      "debug-${kernel}"
      {
        liveCfgPath = [ "licheerv" kernel "live" "usb" ];
      };

  live =
    kernel: leaf: tag: attrs:
    licheeProfile
      kernel
      [ "live" leaf ]
      "usb-nbd-live"
      "live"
      tag
      attrs;

  usbTransport = transport: {
    modules = [ ({ ... }: { sg2002.usbGadget.network.transport = transport; }) ];
  };

  gMulti = {
    modules = [
      ({ lib, ... }: {
        boot.initrd.systemd.services.usb-gadget.enable = lib.mkForce false;
      })
    ];
    artifactArgs.extraBootargs = [
      "g_multi.use_rndis=1"
      # MACs match sg2002-usb-gadget-initrd.nix → protocol.nix.
      "g_multi.dev_addr=02:1a:11:00:01:01"
      "g_multi.host_addr=02:1a:11:00:01:02"
      "g_multi.removable=1"
      "g_multi.iManufacturer=Sipeed"
      "g_multi.iProduct=LicheeRV-Nano-NixOS"
      "g_multi.iSerialNumber=sg2002-g-multi"
    ];
  };

  oled = {
    mixins = [ ../modules/oled.nix ];
    modules = [ ({ ... }: { nanokvm.oled.enable = true; }) ];
    artifactArgs.oled = true;
  };

  wifi = {
    variant = "wifi";
    mixins = [
      ../modules/sg2002-initrd-wifi.nix
      ../modules/wifi-aic8800.nix
    ];
    modules = [
      ({ ... }: {
        # In wifi mode the rootfs NBD lives on the LAN — networkd
        # brings wlan0 up via DHCP and connects to the host's LAN
        # address. USB-ECM stays up purely for the control plane.
        # 192.168.23.136 is grw's site-specific LAN address; override
        # via the `wifiBindIp` field below if needed.
        nanokvm.nbdLive = {
          host = "192.168.23.136";
          staticIface = null;
        };
      })
    ];
    artifactArgs.rootfsBindIp = "192.168.23.136";
  };

  vendorUsb = {
    # Vendor 5.10 lacks kexec-tools/nbd-client + our nbd patch — drop
    # the kexec runner from the output set. usb-boot still publishes.
    artifactArgs.includeKexec = false;
  };
in
[
  # ===== licheerv-nano-w / mainline =====
  (kernelTest "mainline")
  (debug "mainline")
  (live "mainline" "usb" "live-mainline" { })
  (live "mainline" "usb-rndis" "live-mainline-rndis" (usbTransport "rndis"))
  (live "mainline" "usb-ncm" "live-mainline-ncm" (usbTransport "ncm"))
  (live "mainline" "usb-g-multi" "live-mainline-g-multi" gMulti)
  (live "mainline" "usb-oled" "live-mainline-oled" oled)
  # Historical kink: tag is "live-wifi-<kernel>" not "live-<kernel>-wifi".
  # Kept stable so kexec_target diagnostics don't change.
  (live "mainline" "wifi" "live-wifi-mainline" wifi)

  # ===== licheerv-nano-w / vendor =====
  (kernelTest "vendor")
  (debug "vendor")
  (live "vendor" "usb" "live-vendor" vendorUsb)

  # ===== nanokvm-pcie / vendor (production SD image) =====
  {
    path = [ "pcie" "vendor" "sd" ];
    boardName = "nanokvm-pcie";
    kernel = "vendor";
    profile = "sd-image";
    # Wifi mixin appended by flake.nix only when wifi.conf exists.
    artifact = "sd";
  }
]
