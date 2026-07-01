# The mainline kernel patch list, factored out so make-config.nix can
# apply the same set before `make olddefconfig` (otherwise patches
# that introduce new Kconfig options have those options silently
# dropped from the produced .config — there's no error, the option
# just doesn't exist in the unpatched tree olddefconfig sees).
#
# Returns `{ patches, meta }`. `patches` is the list of `{name, patch}`
# kernelPatches entries that gets fed to linuxManualConfig. `meta` is
# a per-patch metadata attrset (origin, upstreamStatus, dropWhen,
# notes) — keyed by `name` — that we keep out of the kernel-build API
# so consumers can introspect it without sneaking metadata into the
# kernel derivation.
#
# Per-patch metadata fields:
#   origin          where the patch came from. Options:
#                   - "local"   — written in this repo
#                   - "linux-next" / "linux-pm" / "<mailing-list>"
#                                — backport of a posted-upstream patch
#                   - "<upstream commit hash>" — clean cherry-pick
#   upstreamStatus  "merged" | "posted" | "stalled" | "draft" | "local-only"
#   dropWhen        free-form: condition under which we can remove it
#   notes           free-form rationale beyond what the patch header says
let
  patch =
    { name
    , patch
    ,
    }: {
      inherit name patch;
    };

  patches = [
    (patch {
      name = "usb-dwc2-cv1800-let-dt-drive-g_dma-host_dma";
      patch = ./patches/0001-usb-dwc2-cv1800-let-DT-drive-g_dma-host_dma.patch;
    })
    (patch {
      name = "mmc-sdhci-of-dwcmshc-sg2002-sdio1-init";
      patch = ./patches/0002-mmc-sdhci-of-dwcmshc-SG2002-SDIO1-init-pinmux-readba.patch;
    })
    (patch {
      name = "dmaengine-cv1800b-dmamux-fix-channel-allocation-order";
      patch = ./patches/0003-dmaengine-cv1800b-dmamux-fix-channel-allocation-order.patch;
    })
    (patch {
      name = "asoc-cv1800b-sound-adc-init-analog-stage";
      patch = ./patches/0005-ASoC-cv1800b-sound-adc-init-analog-stage.patch;
    })
    (patch {
      name = "thermal-cv1800-Add-cv1800-thermal-driver-support";
      patch = ./patches/0006-thermal-cv1800-Add-cv1800-thermal-driver-support.patch;
    })
    (patch {
      name = "thermal-cv1800-bridge-thermal-zone-into-hwmon";
      patch = ./patches/0007-thermal-cv1800-bridge-thermal-zone-into-hwmon.patch;
    })
    (patch {
      name = "pwm-cv1800-add-Sophgo-CV1800-SG2002-PWM-driver";
      patch = ./patches/0008-pwm-cv1800-add-Sophgo-CV1800-SG2002-PWM-driver.patch;
    })
    (patch {
      name = "nbd-survive-SIGSTOP-during-NBD_DO_IT";
      patch = ./patches/0009-nbd-survive-SIGSTOP-during-NBD_DO_IT.patch;
    })
    (patch {
      name = "fbdev-ssd1307fb-add-sh1107-page-mode-support";
      patch = ./patches/0010-fbdev-ssd1307fb-add-sh1107-page-mode-support.patch;
    })
    (patch {
      name = "fbdev-ssd1307fb-finish-sh1107-bindings";
      patch = ./patches/0011-fbdev-ssd1307fb-finish-sh1107-bindings.patch;
    })
    (patch {
      name = "fbdev-ssd1307fb-mark-buffer-as-virtual-framebuffer";
      patch = ./patches/0012-fbdev-ssd1307fb-mark-buffer-as-virtual-framebuffer.patch;
    })
    (patch {
      name = "net-stmmac-dwmac-sophgo-add-cv1800b-internal-ephy";
      patch = ./patches/0013-net-stmmac-dwmac-sophgo-add-cv1800b-internal-EPHY.patch;
    })
  ];

  meta = {
    "usb-dwc2-cv1800-let-dt-drive-g_dma-host_dma" = {
      origin = "local";
      upstreamStatus = "local-only";
      dropWhen = "DWC2 cv1800/SG2002 DMA quirks land upstream";
      notes = ''
        Without this, dwc2 forces DMA off on cv1800 because the IP
        cap register reports HW_DMA_DESC=0 even though descriptor DMA
        works fine after a g_dma+host_dma override.
      '';
    };
    "mmc-sdhci-of-dwcmshc-sg2002-sdio1-init" = {
      origin = "local";
      upstreamStatus = "local-only";
      dropWhen = "SDIO1 pinmux + readback fix lands in dwcmshc";
      notes = ''
        SDIO1 init sequence for AIC8800 — pinmux + readback retry.
        Board-specific; probably never lands upstream as-is, but the
        pinmux part might split out cleanly.
      '';
    };
    "dmaengine-cv1800b-dmamux-fix-channel-allocation-order" = {
      origin = "linux-next";
      upstreamStatus = "merged";
      dropWhen = "nixpkgs linux >= the kernel that includes this";
      notes = ''
        Backport from linux-next for v7.1 — fixes channel allocation
        order so dmamux's I2S handshake gets the channel ID that
        dw_axi_dmac actually programs.
      '';
    };
    "dmaengine-dw-axi-dmac-add-cv1800b-support" = {
      origin = "linux-next";
      upstreamStatus = "merged";
      dropWhen = "already present in nixpkgs linux 7.1";
      notes = "Pair with 0003 — required for I2S capture to function. Kept as metadata only because Linux 7.1 already contains this patch.";
    };
    "asoc-cv1800b-sound-adc-init-analog-stage" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "ALSA cv1800b-sound-adc upstream gains analog-stage init";
      notes = ''
        Mainline cv1800b-sound-adc only inits CTRL0/CTRL1/CLK/ANA0 —
        we add SDM CTUNE (ANA3) + a cross-block DAC ANA0 ECO bit the
        vendor cv181xadc clears in hw_params. Without these the RXADC
        enables but produces no samples.
      '';
    };
    "thermal-cv1800-Add-cv1800-thermal-driver-support" = {
      origin = "linux-pm";
      upstreamStatus = "stalled";
      dropWhen = "Haylen Chu's PATCH v5 2/3 (Oct 2024) lands upstream";
      notes = ''
        SoC on-die temp sensor at 0x030E0000. ADDS a Kconfig entry —
        make-config.nix must apply it before olddefconfig.
        Compatible: sophgo,cv1800-thermal.
      '';
    };
    "thermal-cv1800-bridge-thermal-zone-into-hwmon" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "cv1800-thermal upstream registers via devm_thermal_add_hwmon_sysfs";
      notes = ''
        Adds /sys/class/hwmon entry for the cv1800 thermal zone so
        lm-sensors / glances / node_exporter pick up SoC die temp
        alongside the iio-hwmon-bridged SAR-ADC voltages.
      '';
    };
    "pwm-cv1800-add-Sophgo-CV1800-SG2002-PWM-driver" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "a cv1800-pwm driver lands upstream";
      notes = ''
        Mainline 7.0 has no PWM driver for the cv1800/SG2002 PWM IP
        at 0x03060000..0x03063000. Vendor 5.10 only ships a U-Boot
        driver. Fresh mainline driver, ~170 lines, modern pwm_chip /
        .apply() API. Adds Kconfig, so make-config.nix needs the
        patch list for olddefconfig — same reason as the cv1800
        thermal patch.
      '';
    };
    "nbd-survive-SIGSTOP-during-NBD_DO_IT" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = ''
        upstream nbd uses wait_event_killable in nbd_start_device_ioctl,
        OR systemd's switch-root stops broadcast-SIGSTOPing every
        process before SIGTERM.
      '';
      notes = ''
        systemd's MANAGER_SWITCH_ROOT does `kill(-1, SIGSTOP)` →
        SIGTERM → SIGCONT in broadcast_signal(). The SIGSTOP wakes
        wait_event_interruptible() in nbd_start_device_ioctl with
        -ERESTARTSYS and the kernel tears down the socket, killing
        any nbd-backed rootfs just before /sbin/init can exec.
        wait_event_killable keeps the wait alive across SIGSTOP/
        SIGCONT/SIGTERM-with-handler; SIGKILL still breaks out.
      '';
    };
    "fbdev-ssd1307fb-add-sh1107-page-mode-support" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "mainline ssd1307fb or a DRM tiny driver gains SH1107 support";
      notes = ''
        GME128128/SG1107 128x128 OLED panels ACK at the SSD1306-style
        0x3c address but need SH1107 page addressing and DC-DC command
        0xad 0x8b before the display lights. This keeps fbcon and
        /dev/fb0 working without a userspace I2C daemon.
      '';
    };
    "fbdev-ssd1307fb-finish-sh1107-bindings" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "fold into fbdev-ssd1307fb-add-sh1107-page-mode-support";
      notes = ''
        Follow-up while iterating on hardware: adds the OF/I2C match
        table entries and avoids registering SH1107 contrast as a
        system backlight, which systemd-backlight can otherwise poke
        during boot.
      '';
    };
    "fbdev-ssd1307fb-mark-buffer-as-virtual-framebuffer" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "mainline ssd1307fb marks its RAM backing store with FBINFO_VIRTFB";
      notes = ''
        Linux 7.0's sys_imageblit/sys_fillrect helpers warn when a
        RAM-backed framebuffer does not set FBINFO_VIRTFB. ssd1307fb
        allocates normal memory and flushes it via deferred I/O, so mark
        it as virtual to avoid alarming boot-time fbcon warnings.
      '';
    };
    "net-stmmac-dwmac-sophgo-add-cv1800b-internal-ephy" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "dwmac-sophgo (or an EPHY power-up in mainline U-Boot) supports the cv1800b/SG2002 internal EPHY";
      notes = ''
        Mainline 7.0's dwmac-sophgo only binds sg2042/sg2044. The
        CV1800B/SG2002 internal 10/100 EPHY needs two things mainline
        doesn't do: (1) power-up — the vendor U-Boot
        (board/cvitek/mars/board.c::cv181x_ephy_id_init) releases it from
        shutdown before Linux; without it PHY attach fails -EINVAL.
        (2) analog calibration — the vendor PHY driver
        (drivers/net/phy/cvitek.c::cv182xa_phy_config_init) programs the
        MLT3/link-pulse/TP-idle/10-100BaseT/AGC/LPF-HPF tables; without
        it the PHY attaches but never links (carrier 0 with a cable). We
        do both via MMIO at 0x03009000 from the cv1800b init hook, using
        non-efuse default trims and the CV181X "mars" LPF/HPF. (Per-chip
        efuse trimming is skipped — it only tightens signal margins.)
      '';
    };
  };
in
{
  inherit patches meta;
}
