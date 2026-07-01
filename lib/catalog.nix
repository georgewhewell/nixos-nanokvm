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
#                  (oled, rootfsBindIp, requireRootfsHostOverride,
#                  extraBootargs, includeKexec).
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
        # In wifi mode the rootfs NBD lives on the caller's LAN:
        # networkd brings wlan0 up via DHCP and USB-ECM stays up only
        # for the control plane. The runner must provide
        # NANOKVM_NBD_ROOTFS_HOST so this catalog remains site-neutral.
        nanokvm.nbdLive = {
          staticIface = null;
        };
      })
    ];
    artifactArgs.requireRootfsHostOverride = true;
  };

  vendorUsb = {
    # Vendor 5.10 lacks kexec-tools/nbd-client + our nbd patch — drop
    # the kexec runner from the output set. usb-boot still publishes.
    artifactArgs.includeKexec = false;
  };

  # nanokvm-pcie carrier (ethernet + WiFi + OLED footprint), mirroring
  # the `lichee` helpers above so PCIe entries stay one-liners too.
  pcie =
    kernel: pathTail: attrs:
    {
      path = [ "pcie" kernel ] ++ pathTail;
      boardName = "nanokvm-pcie";
      inherit kernel;
    }
    // attrs;

  pcieLive =
    kernel: tag: attrs:
    pcie kernel [ "live" "usb" ] (
      {
        profile = "usb-nbd-live";
        artifact = "live";
        inherit tag;
      }
      // attrs
    );

  pcieKernelTest = kernel:
    pcie kernel [ "kernel-test" ] {
      profile = "usb-kernel-test";
      artifact = "kernel-test";
      tag = "kernel-test-pcie-${kernel}";
    };

  # PCIe-live bring-up extras:
  #   - WiFi driver only, so wlan0 enumerates and the radio is
  #     exercisable. Association remains downstream policy.
  #   - nanokvm-server (the web UI + ATX/GPIO control), which the live
  #     profile doesn't enable on its own.
  pcieLiveExtras = {
    modules = [
      ({ ... }: {
        sg2002.wifi.enable = true;
        services.nanokvm = {
          enable = true;
          openFirewall = true;
        };
      })
    ];
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

  # ===== nanokvm-pcie / vendor =====
  # Production SD image (vendor kernel + vendor-FIT). Network policy
  # belongs in the downstream config that imports the board module.
  (pcie "vendor" [ "sd" ] { profile = "sd-image"; artifact = "sd"; })
  # Initrd-only recovery target using the vendor SDHCI stack. Useful when
  # mainline can reach USB but cannot enumerate the card.
  (pcieKernelTest "vendor")
  # USB-NBD live for hardware bring-up: ethernet (bm-dwmac) + WiFi work
  # natively off the vendor DTS.
  (pcieLive "vendor" "live-pcie-vendor" (pcieLiveExtras // vendorUsb))

  # ===== nanokvm-pcie / mainline =====
  # Initrd-only recovery target for USB/kexec bring-up on the actual PCIe
  # carrier (same DTB as the SD image, but no stage-2 services).
  (pcieKernelTest "mainline")
  # extlinux SD image (mainline U-Boot). Ethernet via stmmac + the
  # ethernet-enabled DTB; reachable over the USB-ECM gadget too.
  (pcie "mainline" [ "sd" ] { profile = "sd-image-mainline"; artifact = "sd"; })
  # USB-NBD live exercising the full PCIe hardware — eth0 (stmmac) and
  # wlan0 (AIC8800) both come up.
  (pcieLive "mainline" "live-pcie-mainline" pcieLiveExtras)
]
