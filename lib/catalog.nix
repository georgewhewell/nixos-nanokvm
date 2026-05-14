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
{lib}: [
  # ===== licheerv-nano-w / mainline =====
  {
    path = ["licheerv" "mainline" "kernel-test"];
    boardName = "licheerv-nano-w";
    kernel = "mainline";
    profile = "usb-kernel-test";
    artifact = "kernel-test";
    tag = "kernel-test-mainline";
  }
  {
    path = ["licheerv" "mainline" "debug"];
    boardName = "licheerv-nano-w";
    kernel = "mainline";
    profile = "usb-debug";
    artifact = "debug";
    tag = "debug-mainline";
    liveCfgPath = ["licheerv" "mainline" "live" "usb"];
  }
  {
    path = ["licheerv" "mainline" "live" "usb"];
    boardName = "licheerv-nano-w";
    kernel = "mainline";
    profile = "usb-nbd-live";
    artifact = "live";
    tag = "live-mainline";
  }
  {
    path = ["licheerv" "mainline" "live" "usb-rndis"];
    boardName = "licheerv-nano-w";
    kernel = "mainline";
    profile = "usb-nbd-live";
    modules = [({...}: {sg2002.usbGadget.network.transport = "rndis";})];
    artifact = "live";
    tag = "live-mainline-rndis";
  }
  {
    path = ["licheerv" "mainline" "live" "usb-ncm"];
    boardName = "licheerv-nano-w";
    kernel = "mainline";
    profile = "usb-nbd-live";
    modules = [({...}: {sg2002.usbGadget.network.transport = "ncm";})];
    artifact = "live";
    tag = "live-mainline-ncm";
  }
  {
    path = ["licheerv" "mainline" "live" "usb-g-multi"];
    boardName = "licheerv-nano-w";
    kernel = "mainline";
    profile = "usb-nbd-live";
    modules = [
      ({lib, ...}: {
        boot.initrd.systemd.services.usb-gadget.enable = lib.mkForce false;
      })
    ];
    artifact = "live";
    tag = "live-mainline-g-multi";
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
  }
  {
    path = ["licheerv" "mainline" "live" "usb-oled"];
    boardName = "licheerv-nano-w";
    kernel = "mainline";
    profile = "usb-nbd-live";
    mixins = [../modules/oled.nix];
    modules = [({...}: {nanokvm.oled.enable = true;})];
    artifact = "live";
    tag = "live-mainline-oled";
    artifactArgs.oled = true;
  }
  {
    path = ["licheerv" "mainline" "live" "wifi"];
    boardName = "licheerv-nano-w";
    kernel = "mainline";
    profile = "usb-nbd-live";
    variant = "wifi";
    mixins = [
      ../modules/sg2002-initrd-wifi.nix
      ../modules/wifi-aic8800.nix
    ];
    modules = [
      ({...}: {
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
    artifact = "live";
    # Historical kink: tag is "live-wifi-<kernel>" not "live-<kernel>-wifi".
    # Kept stable so kexec_target diagnostics don't change.
    tag = "live-wifi-mainline";
    artifactArgs.rootfsBindIp = "192.168.23.136";
  }

  # ===== licheerv-nano-w / vendor =====
  {
    path = ["licheerv" "vendor" "kernel-test"];
    boardName = "licheerv-nano-w";
    kernel = "vendor";
    profile = "usb-kernel-test";
    artifact = "kernel-test";
    tag = "kernel-test-vendor";
  }
  {
    path = ["licheerv" "vendor" "debug"];
    boardName = "licheerv-nano-w";
    kernel = "vendor";
    profile = "usb-debug";
    artifact = "debug";
    tag = "debug-vendor";
    liveCfgPath = ["licheerv" "vendor" "live" "usb"];
  }
  {
    path = ["licheerv" "vendor" "live" "usb"];
    boardName = "licheerv-nano-w";
    kernel = "vendor";
    profile = "usb-nbd-live";
    artifact = "live";
    tag = "live-vendor";
    # Vendor 5.10 lacks kexec-tools/nbd-client + our nbd patch — drop
    # the kexec runner from the output set. usb-boot still publishes.
    artifactArgs.includeKexec = false;
  }

  # ===== nanokvm-pcie / vendor (production SD image) =====
  {
    path = ["pcie" "vendor" "sd"];
    boardName = "nanokvm-pcie";
    kernel = "vendor";
    profile = "sd-image";
    # Wifi mixin appended by flake.nix only when wifi.conf exists.
    artifact = "sd";
  }
]
