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
  c906lContract = builtins.fromJSON (
    builtins.readFile ../c906l-contract/contract.json
  );
  c906lMailbox = c906lContract.soc.mailbox;
  c906lHwspin = c906lMailbox.hardwareSpinlock;
  cv1800MailboxPatch =
    ./patches/0064-mailbox-cv1800-serialize-shared-register-access.patch;
  cv1800MailboxPatchLines = builtins.filter builtins.isString (
    builtins.split "\n" (builtins.readFile cv1800MailboxPatch)
  );

  patch =
    { name
    , patch
    ,
    }: {
      inherit name patch;
    };

  patches = [
    (patch {
      name = "clk-cv18xx-check-pll-lock-status";
      patch = ./patches/0074-clk-cv18xx-check-pll-lock-status.patch;
    })
    (patch {
      name = "clk-cv18xx-fix-mmux-parent-and-rate-ops";
      patch = ./patches/0072-clk-cv18xx-fix-mmux-parent-and-rate-ops.patch;
    })
    (patch {
      name = "clk-cv18xx-switch-away-from-active-cpu-divider";
      patch = ./patches/0073-clk-cv18xx-switch-away-from-active-cpu-divider.patch;
    })
    (patch {
      name = "clk-cv18xx-program-bypass-mux-parent";
      patch = ./patches/0071-clk-cv18xx-program-bypass-mux-parent.patch;
    })
    (patch {
      name = "clk-cv18xx-park-cpu-during-pll-retune";
      patch = ./patches/0075-clk-cv18xx-park-cpu-during-pll-retune.patch;
    })
    (patch {
      name = "usb-dwc2-cv1800-let-dt-drive-g_dma-host_dma";
      patch = ./patches/0001-usb-dwc2-cv1800-let-DT-drive-g_dma-host_dma.patch;
    })
    (patch {
      name = "usb-dwc2-gadget-ask-u_ether-for-dma-friendly-rx-buffers";
      patch = ./patches/0076-usb-dwc2-gadget-ask-u_ether-for-DMA-friendly-RX-buffers.patch;
    })
    (patch {
      name = "mmc-sdhci-of-dwcmshc-sg2002-sdio1-init";
      patch = ./patches/0002-mmc-sdhci-of-dwcmshc-SG2002-SDIO1-init-pinmux-readba.patch;
    })
    (patch {
      name = "mmc-cv18xx-preserve-bus-voltage-with-vmmc";
      patch = ./patches/0069-mmc-cv18xx-preserve-bus-voltage-with-vmmc.patch;
    })
    (patch {
      name = "mmc-cv18xx-enable-sdio-reference-clock";
      patch = ./patches/0070-mmc-cv18xx-enable-sdio-reference-clock.patch;
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
    (patch {
      name = "media-i2c-lt6911uxe-add-devicetree-probe-support";
      patch = ./patches/0014-media-i2c-lt6911uxe-add-devicetree-probe-support.patch;
    })
    (patch {
      name = "media-platform-add-sg2002-csi-capture-bring-up";
      patch = ./patches/0015-media-platform-add-SG2002-CSI-capture-bring-up.patch;
    })
    (patch {
      name = "pinctrl-sophgo-allow-fixed-io-pin-power-source";
      patch = ./patches/0016-pinctrl-sophgo-allow-fixed-io-pin-power-source.patch;
    })
    (patch {
      name = "dt-bindings-media-coda-add-sg2002-coda980";
      patch = ./patches/0017-dt-bindings-media-coda-add-sg2002-coda980.patch;
    })
    (patch {
      name = "media-coda-add-sg2002-coda980-h264";
      patch = ./patches/0018-media-coda-add-sg2002-coda980-h264.patch;
    })
    (patch {
      name = "media-coda-keep-coda980-firmware-id-out-of-abi-enum";
      patch = ./patches/0019-media-coda-keep-coda980-firmware-id-out-of-abi-enum.patch;
    })
    (patch {
      name = "media-coda-constrain-sg2002-staging-and-contexts";
      patch = ./patches/0020-media-coda-constrain-sg2002-staging-and-contexts.patch;
    })
    (patch {
      name = "media-coda-boot-sg2002-firmware-from-common-arena";
      patch = ./patches/0021-media-coda-boot-sg2002-firmware-from-common-arena.patch;
    })
    (patch {
      name = "riscv-dts-sophgo-describe-sg2002-coda980";
      patch = ./patches/0022-riscv-dts-sophgo-describe-sg2002-coda980.patch;
    })
    (patch {
      name = "media-coda-support-sg2002-nv12-and-dma-buf-input";
      patch = ./patches/0023-media-coda-support-sg2002-nv12-and-dma-buf-input.patch;
    })
    (patch {
      name = "media-coda-handle-sg2002-h264-reset";
      patch = ./patches/0024-media-coda-handle-SG2002-H264-reset.patch;
    })
    (patch {
      name = "media-coda-download-sg2002-firmware-into-bit-sram";
      patch = ./patches/0025-media-coda-download-SG2002-firmware-into-BIT-SRAM.patch;
    })
    (patch {
      name = "media-coda-read-sg2002-product-code-from-gdi";
      patch = ./patches/0026-media-coda-read-SG2002-product-code-from-GDI.patch;
    })
    (patch {
      name = "media-coda-configure-sg2002-h264-headers";
      patch = ./patches/0027-media-coda-configure-SG2002-H264-headers.patch;
    })
    (patch {
      name = "media-coda-configure-sg2002-coda980-encoder-abi";
      patch = ./patches/0028-media-coda-configure-SG2002-Coda980-encoder-ABI.patch;
    })
    (patch {
      name = "media-coda-restore-coda980-frame-memory-default";
      patch = ./patches/0029-media-coda-restore-Coda980-frame-memory-default.patch;
    })
    (patch {
      name = "media-coda-preserve-coda980-sps-setup-with-crop";
      patch = ./patches/0030-media-coda-preserve-Coda980-SPS-setup-with-crop.patch;
    })
    (patch {
      name = "media-sophgo-tighten-sg2002-csi-interrupt-handling";
      patch = ./patches/0031-media-sophgo-tighten-SG2002-CSI-interrupt-handling.patch;
    })
    (patch {
      name = "media-i2c-refresh-lt6911uxc-state-on-timing-queries";
      patch = ./patches/0032-media-i2c-refresh-LT6911UXC-state-on-timing-queries.patch;
    })
    (patch {
      name = "media-sophgo-validate-sg2002-capture-source-format";
      patch = ./patches/0033-media-sophgo-validate-SG2002-capture-source-format.patch;
    })
    (patch {
      name = "media-sophgo-remove-sg2002-capture-bring-up-controls";
      patch = ./patches/0034-media-sophgo-remove-SG2002-capture-bring-up-controls.patch;
    })
    (patch {
      name = "dt-bindings-reset-add-sg2002-csi-phy-resets";
      patch = ./patches/0035-dt-bindings-reset-add-SG2002-CSI-PHY-resets.patch;
    })
    (patch {
      name = "dt-bindings-media-document-sg2002-csi-capture";
      patch = ./patches/0036-dt-bindings-media-document-SG2002-CSI-capture.patch;
    })
    (patch {
      name = "media-sophgo-harden-sg2002-csi-stream-teardown";
      patch = ./patches/0037-media-sophgo-harden-SG2002-CSI-stream-teardown.patch;
    })
    (patch {
      name = "media-i2c-lt6911uxe-poll-uxc-while-streaming";
      patch = ./patches/0038-media-i2c-lt6911uxe-poll-UXC-while-streaming.patch;
    })
    (patch {
      name = "media-coda-use-two-coda980-reconstruction-buffers";
      patch = ./patches/0039-media-coda-use-two-Coda980-reconstruction-buffers.patch;
    })
    (patch {
      name = "media-coda-use-linear-gdi-map-for-coda980-nv12";
      patch = ./patches/0041-media-coda-use-linear-GDI-map-for-Coda980-NV12.patch;
    })
    (patch {
      name = "dt-bindings-media-document-sg2002-vpss-scaler";
      patch = ./patches/0044-dt-bindings-media-document-SG2002-VPSS-scaler.patch;
    })
    (patch {
      name = "media-sophgo-add-sg2002-vpss-scaler-driver";
      patch = ./patches/0045-media-sophgo-add-SG2002-VPSS-scaler-driver.patch;
    })
    (patch {
      name = "riscv-dts-sophgo-add-sg2002-vpss-node";
      patch = ./patches/0046-riscv-dts-sophgo-add-SG2002-VPSS-node.patch;
    })
    (patch {
      name = "media-bind-reserved-memory-pools-to-sg2002-media-devices";
      patch = ./patches/0047-media-bind-reserved-memory-pools-to-SG2002-media-devices.patch;
    })
    (patch {
      name = "media-sophgo-unbind-sg2002-vpss-from-reserved-pool";
      patch = ./patches/0048-media-sophgo-unbind-SG2002-VPSS-from-reserved-pool.patch;
    })
    (patch {
      name = "media-coda-release-reserved-pool-after-teardown";
      patch = ./patches/0049-media-coda-release-reserved-pool-after-teardown.patch;
    })
    (patch {
      name = "media-sophgo-sg2002-vpss-capture-crop";
      patch = ./patches/0050-media-sophgo-SG2002-VPSS-capture-crop.patch;
    })
    (patch {
      name = "media-sophgo-sg2002-vpss-session-clocking";
      patch = ./patches/0051-media-sophgo-SG2002-VPSS-session-clocking.patch;
    })
    (patch {
      name = "media-sophgo-sg2002-vpss-fabric-clocks";
      patch = ./patches/0052-media-sophgo-SG2002-VPSS-fabric-clocks.patch;
    })
    (patch {
      name = "media-i2c-galaxycore-gc4653";
      patch = ./patches/0053-media-i2c-add-GalaxyCore-GC4653-sensor-driver.patch;
    })
    (patch {
      name = "media-sophgo-sg2002-csi-capture-raw-sources";
      patch = ./patches/0054-media-sophgo-SG2002-CSI-capture-RAW-sources.patch;
    })
    (patch {
      name = "media-sophgo-sg2002-csi-vendor-deskew-codes";
      patch = ./patches/0057-media-sophgo-SG2002-CSI-vendor-deskew-codes.patch;
    })
    (patch {
      name = "media-sophgo-sg2002-csi-complete-lane-permutation";
      patch = ./patches/0058-media-sophgo-SG2002-CSI-complete-lane-permutation.patch;
    })
    (patch {
      name = "media-sophgo-sg2002-csi-arm-sink-before-source";
      patch = ./patches/0059-media-sophgo-SG2002-CSI-arm-sink-before-source.patch;
    })
    (patch {
      name = "media-sophgo-sg2002-csi-advertise-repacked-raw";
      patch = ./patches/0060-media-sophgo-SG2002-CSI-advertise-repacked-RAW.patch;
    })
    (patch {
      name = "media-sophgo-allow-double-buffered-sg2002-csi-capture";
      patch = ./patches/0061-media-sophgo-allow-double-buffered-SG2002-CSI-capture.patch;
    })
    (patch {
      name = "media-sophgo-cap-sg2002-csi-capture-buffer-count";
      patch = ./patches/0062-media-sophgo-cap-SG2002-CSI-capture-buffer-count.patch;
    })
    (patch {
      name = "media-sophgo-recover-from-sg2002-csi-frame-errors";
      patch = ./patches/0063-media-sophgo-recover-from-SG2002-CSI-frame-errors.patch;
    })
    (patch {
      name = "mailbox-cv1800-serialize-shared-register-access";
      patch = cv1800MailboxPatch;
    })
    (patch {
      name = "media-sophgo-sg2002-hardware-isp-capture";
      patch = ./patches/0065-media-sophgo-add-SG2002-hardware-ISP-capture.patch;
    })
    (patch {
      name = "media-sophgo-fix-vpss-queue-state-bounds";
      patch = ./patches/0066-media-sophgo-fix-VPSS-queue-state-bounds.patch;
    })
    (patch {
      name = "media-sophgo-preserve-vpss-source-colourimetry";
      patch = ./patches/0067-media-sophgo-preserve-VPSS-source-colourimetry.patch;
    })
    (patch {
      name = "media-sophgo-align-vpss-format-enumeration";
      patch = ./patches/0068-media-sophgo-align-VPSS-format-enumeration.patch;
    })
  ];

  meta = {
    "clk-cv18xx-check-pll-lock-status" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "CV18xx PLL operations check update completion and lock, and return failures";
      notes = ''
        The low PLL status bits indicate updates, not lock. Require the
        corresponding high lock bit and return timeout/invalid-rate errors.
        CPU consumers still need a safe alternate clock before PLL retuning;
        this patch does not raise the default frequency.
      '';
    };
    "clk-cv18xx-park-cpu-during-pll-retune" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "CV18xx CPU muxes leave a PLL before it is retuned and return only on a verified lock";
      notes = ''
        A PLL cannot be retuned while a CPU executes from it. Park the CPU
        on the mux's other lane across the change and return only once the
        hardware reports a completed update and lock. clk_change_rate()
        discards set_rate() errors and skips POST_RATE_CHANGE on an
        unchanged rate, so the release also happens from set_rate().
        Enables a board-selected CPU PLL rate; changes no core voltage.
      '';
    };
    "clk-cv18xx-switch-away-from-active-cpu-divider" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "CV18xx MMUX changes active dividers through a safe intermediate clock";
      notes = ''
        Follow the SG200X TRM's inactive-lane CPU divider update sequence.
        C906_0 rate requests retain the firmware-selected PLL; this does
        not enable PLL retuning or claim a programmable board core supply.
      '';
    };
    "clk-cv18xx-fix-mmux-parent-and-rate-ops" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "CV18xx MMUX set_parent encodes lane-local selectors and bypassed set_rate returns success";
      notes = ''
        Invert the selector-to-parent map before programming a CPU clock mux;
        logical MPLL index 4 is hardware selector 3, not zero. KUnit exercises
        the actual driver operations with memory-backed registers. This does
        not enable CPUFreq or validate voltage/frequency transitions.
      '';
    };
    "clk-cv18xx-program-bypass-mux-parent" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "cv1800_clk_bypass_mux_ops.set_parent programs the PLL mux as well as the bypass bit";
      notes = ''
        Match get_parent's one-based PLL parent indexing. Without this,
        assigned-clock-parents changes the cached parent but not the hardware
        source, invalidating divider calculations for SD and other clocks.
      '';
    };
    "mmc-cv18xx-enable-sdio-reference-clock" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "CV18xx MMC consumes its optional timer clock upstream";
      notes = "Late SDIO probe requires the 100 kHz reference after unused firmware clocks are gated; verified with a CCF consumer on PicoClaw.";
    };
    "mmc-cv18xx-preserve-bus-voltage-with-vmmc" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "CV18xx uses sdhci_set_power_and_bus_voltage upstream";
      notes = "Preserve SDHCI voltage-selection bits when C906L mediates PicoClaw Wi-Fi power through vmmc.";
    };
    "media-sophgo-align-vpss-format-enumeration" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "Folded into the SG2002 VPSS driver before submission";
      notes = "ENUM_FMT must advertise the same packed/semiplanar source and semiplanar destination formats as S_FMT.";
    };
    "media-sophgo-preserve-vpss-source-colourimetry" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "Folded into the SG2002 VPSS driver before submission";
      notes = "YUV scaling preserves source matrix, transfer function and range; CAPTURE reports the OUTPUT colour tuple.";
    };
    "media-sophgo-fix-vpss-queue-state-bounds" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "Folded into the SG2002 VPSS driver before submission";
      notes = "V4L2 OUTPUT is index 2; reserve it instead of overwriting crop state.";
    };
    "media-sophgo-sg2002-hardware-isp-capture" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "mainline SG2002 media support provides the linear hardware ISP path";
      notes = ''
        Optional NV21 capture on Bayer sources routes FE0 through BE, CFA,
        CSC and the YUV output DMA pair. The existing RAW and HDMI formats
        keep their direct DMA6 path. Fixed settings precede future stats
        and userspace tuning controls; silicon validation is required.
      '';
    };
    "mailbox-cv1800-serialize-shared-register-access" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "the upstream CV1800 mailbox driver serializes register access with the field-4 cross-core hardware lock";
      notes = ''
        Protects the complete Linux TX and threaded-RX transactions with the
        SG2002 mailbox hardware spinlock at mailbox + 0xd0 (vendor bank +0xc0,
        field 4). Linux uses nonzero low-byte tokens while C906L uses the
        disjoint high-byte namespace. Receive payloads are copied before ACK,
        callbacks run unlocked, and bounded lock contention is retried without
        wedging mailbox-core queued requests.
      '';
    };
    "media-sophgo-recover-from-sg2002-csi-frame-errors" = {
      origin = "local";
      upstreamStatus = "local-only";
      dropWhen = "The upstream capture driver drops recoverable CSI-corrupt frames without failing the VB2 queue";
      notes = ''
        Drops a frame affected by recoverable CSI packet errors and retries
        the same capture buffer.  FIFO overflow remains fatal.  Hardware
        validation targets repeated GC4653 STREAMOFF/STREAMON transitions.
      '';
    };
    "usb-dwc2-cv1800-let-dt-drive-g_dma-host_dma" = {
      origin = "local";
      upstreamStatus = "local-only";
      dropWhen = "upstream dwc2_set_cv1800_params() stops forcing g_dma/host_dma off";
      notes = ''
        Upstream hard-codes g_dma = host_dma = false for cv1800, which
        leaves the gadget in slave/PIO mode. With the assignments gone the
        DT's g-use-dma property enables DMA and, because the SG2002 core
        (DWC_otg 4.20a, hw_params.dma_desc_enable = 1) reports descriptor
        DMA, dwc2 autoselects g_dma_desc = 1 -- the same buffer+descriptor
        DMA mode the vendor 5.10 kernel forces in dwc2_set_cv182x_params().
        Verified on hardware from debugfs hw_params/params, 2026-09-19.
      '';
    };
    "usb-dwc2-gadget-ask-u_ether-for-dma-friendly-rx-buffers" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "dwc2 sets quirk_avoids_skb_reserve/quirk_ep_out_aligned_size upstream";
      notes = ''
        dwc2 in DMA mode bounces every 4-byte-misaligned request through a
        GFP_ATOMIC kmalloc plus memcpy. u_ether's NET_IP_ALIGN skb_reserve
        made every RX frame take that path on the SG2002; the two gadget
        quirks (as set by dwc3, cdns3 and renesas_usbf) make u_ether hand
        over aligned, packet-multiple buffers instead. Generic dwc2 change,
        not SoC-specific; verified by hardware A/B.
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
    "media-i2c-lt6911uxe-add-devicetree-probe-support" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = ''
        lt6911uxe grows upstream OF bindings/probe support and NanoKVM's
        LT6911-family bridge ID / no-HPD wiring is handled upstream.
      '';
      notes = ''
        Lets the mainline LT6911UXE V4L2 subdev driver bind on NanoKVM-PCIe
        devicetree, tolerate the board's currently undocumented HPD line,
        and accept the LT6911 ID the vendor sensor driver reports.
      '';
    };
    "media-platform-add-sg2002-csi-capture-bring-up" = {
      origin = "local";
      upstreamStatus = "local-only";
      dropWhen = ''
        a complete upstream SG2002 CSI receiver and VI capture pipeline
        supports NanoKVM's four-lane LT6911UXC route.
      '';
      notes = ''
        Narrow NanoKVM bring-up driver for CSI MAC0 -> CSIBDG0 -> DMA6.
        It exposes the factory 1920x1080 UYVY path as a V4L2 capture node;
        the register recipe and physical lane mapping come from the vendor
        sensor configuration and VI/CIF drivers.
      '';
    };
    "pinctrl-sophgo-allow-fixed-io-pin-power-source" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "Sophgo CV18xx pinctrl accepts fixed-domain pin groups upstream";
      notes = ''
        The binding and DT parser require power-source on every group, but
        ETH/AUDIO pads have no configurable pinconf register and were rejected
        unconditionally. PicoClaw's LCD is wired to SPI1 on the fixed 1.8 V
        Ethernet pads, so accept a power-source-only group without touching a
        nonexistent configuration register.
      '';
    };
    "dt-bindings-media-coda-add-sg2002-coda980" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "SG2002 Coda980 support is accepted upstream";
      notes = "Binding for the SG2002 Coda980 H.264 core.";
    };
    "media-coda-add-sg2002-coda980-h264" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "SG2002 Coda980 support is accepted upstream";
      notes = "Coda980 platform resources, firmware bring-up, and H.264 encoder path.";
    };
    "media-coda-keep-coda980-firmware-id-out-of-abi-enum" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "Folded into the Coda980 support patch before submission";
      notes = "Keeps Coda9 command dispatch tied to the existing Coda960 ABI enum.";
    };
    "media-coda-constrain-sg2002-staging-and-contexts" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "Folded into the Coda980 support patch before submission";
      notes = "Limits the SG2002 encoder to one context and keeps its common-arena aliases out of per-context frees.";
    };
    "media-coda-boot-sg2002-firmware-from-common-arena" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "Folded into the Coda980 support patch before submission";
      notes = "Uses the SG2002 common-arena CODE/TEMP/PARA layout instead of the legacy code-download path.";
    };
    "riscv-dts-sophgo-describe-sg2002-coda980" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "SG2002 Coda980 support is accepted upstream";
      notes = "Adds the disabled SoC Coda980 node; board overlays enable it only where tested.";
    };
    "media-coda-support-sg2002-nv12-and-dma-buf-input" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "Folded into the Coda980 support patch before submission";
      notes = "Accepts direct NV12 DMA-BUF input and safely CPU-maps NV21 imports for staging.";
    };
    "media-coda-handle-sg2002-h264-reset" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "Folded into the Coda980 support patch before submission";
      notes = "Uses level assert/deassert with SG2002's simple-reset provider, which has no pulse duration.";
    };
    "media-coda-download-sg2002-firmware-into-bit-sram" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "Folded into the Coda980 support patch before submission";
      notes = "Retains the Coda9 BIT SRAM download in addition to SG2002's common-arena firmware copy.";
    };
    "media-coda-read-sg2002-product-code-from-gdi" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "Folded into the Coda980 support patch before submission";
      notes = "Reads Coda980's hardware product code separately from its customer-coded firmware version word.";
    };
    "media-coda-configure-sg2002-h264-headers" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "Folded into the Coda980 support patch before submission";
      notes = "Initializes the extended Coda9 SPS/PPS registers used by Coda980 firmware.";
    };
    "media-coda-configure-sg2002-coda980-encoder-abi" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "Folded into the Coda980 support patch before submission";
      notes = "Programs the Coda980 sequence, Maverick-II cache, and per-picture H.264 ABI without applying Coda960-only semantics.";
    };
    "media-coda-restore-coda980-frame-memory-default" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "Folded into the Coda980 support patch before submission";
      notes = "Keeps Coda980's interleaved-chroma, 128-bit little-endian frame-memory default across command-time rewrites.";
    };
    "media-coda-preserve-coda980-sps-setup-with-crop" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "Folded into the Coda980 support patch before submission";
      notes = "Keeps 1080p frame-crop flags from bypassing the Coda980 extended SPS register setup.";
    };
    "media-sophgo-tighten-sg2002-csi-interrupt-handling" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "Folded into the SG2002 CSI capture series before submission";
      notes = ''
        Enables only the VI completion interrupt consumed by the driver,
        exposes the five documented CSI MAC error causes, clears sticky CSI
        bridge status between streams, and names the direct-YUV route bits.
      '';
    };
    "media-i2c-refresh-lt6911uxc-state-on-timing-queries" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "Folded into the LT6911UXC support series before submission";
      notes = ''
        Polls the non-interrupt-driven LT6911UXC timing state when userspace
        queries it, updates the active media-bus format and pixel rate, and
        emits source-change events without holding the register/state mutex.
      '';
    };
    "media-sophgo-validate-sg2002-capture-source-format" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "Folded into the SG2002 CSI capture series before submission";
      notes = ''
        Validates the fixed 1080p UYVY source link before starting DMA and
        forwards source-change events to capture userspace, failing an active
        queue when the HDMI bridge changes mode underneath it.
      '';
    };
    "media-sophgo-remove-sg2002-capture-bring-up-controls" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "Folded into the SG2002 CSI capture series before submission";
      notes = ''
        Removes diagnostic partial-stage module parameters and the one-shot
        MMIO dump now that the full CSI-to-DMA6 path is hardware-tested.
      '';
    };
    "media-sophgo-harden-sg2002-csi-stream-teardown" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "Folded into the SG2002 CSI capture series before submission";
      notes = ''
        Quiesces DMA and wakes VB2 on fatal link errors or source changes,
        serializes async source lifetime against stream teardown, and releases
        active queues before notifier and device resources disappear.
      '';
    };
    "media-i2c-lt6911uxe-poll-uxc-while-streaming" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "Folded into the LT6911UXC support series before submission";
      notes = ''
        Polls the HPD-less UXC once per second only while streaming, emits one
        event for each detected transition, and preserves ENOLINK plus safe
        work, runtime-PM, active-state, and stream lifetime ordering.
      '';
    };
    "media-coda-use-two-coda980-reconstruction-buffers" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "Folded into the Coda980 support patch before submission";
      notes = ''
        Matches the two reconstruction buffers registered with Coda980
        firmware and avoids two unused 1080p coherent allocations.
      '';
    };
    "media-coda-use-linear-gdi-map-for-coda980-nv12" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "Folded into the Coda980 support patch before submission";
      notes = ''
        coda_s_fmt picks GDI_TILED_FRAME_MB_RASTER_MAP for NV12 on anything
        reporting CODA_960; the SG2002 Coda980 reports CODA_960 but is fed
        linear-raster buffers, so the tile walker scrambled the source fetch
        (12.6 dB PSNR, vertical stripes). Linear map measures 43.2 dB direct,
        matching the staged NV21 control. Replaces the 0040 NV12 withdrawal.
      '';
    };
    "media-bind-reserved-memory-pools-to-sg2002-media-devices" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "Folded into the respective driver submissions upstream";
      notes = ''
        of_dma_configure() only binds "restricted-dma-pool" on this path, so
        the board's shared-dma-pool was never assigned and all three media
        devices kept hitting the colonized default CMA. Probe/remove calls
        bind video-pool@86800000 to coda, sg2002-capture and sg2002-vpss.
      '';
    };
    "dt-bindings-media-document-sg2002-csi-capture" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "An SG2002 CSI capture binding is accepted upstream";
      notes = ''
        Documents the current monolithic CSI MAC, wrapper, VI and VIP system
        resource contract, including the NanoKVM four-lane D-PHY endpoint and
        named CSI PHY reset lines.
      '';
    };
    "dt-bindings-media-document-sg2002-vpss-scaler" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "An SG2002 VPSS scaler binding is accepted upstream";
      notes = ''
        Documents the mem2mem subset of the VIP scaler/CSC block: one
        register window, the shared PLIC interrupt, and the six clocks
        for IMG_IN_V + SC_TOP + SC_V1.
      '';
    };
    "media-sophgo-add-sg2002-vpss-scaler-driver" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "The SG2002 VPSS mem2mem driver is accepted upstream";
      notes = ''
        UYVY/YUYV/NV12/NV21 in, NV12/NV21 out, 1:1 or up to 4x downscale
        via IMG_IN_V + SC_V1. Programming sequence implemented from the
        vendor register map (see vpss-driver-20260810 archaeology); no
        vendor driver code reused. Bicubic coefficients generated from
        the standard Keys kernel (a=-0.5), identity set used at 1:1.
      '';
    };
    "riscv-dts-sophgo-add-sg2002-vpss-node" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "An SG2002 VPSS node is accepted upstream";
      notes = ''
        VPSS window 0x0a080000, PLIC 25 (SOC_PERIPHERAL_IRQ(9)), VIP sys
        muxes + IMG_IN_V/SC_TOP/SC_V1 gates. Disabled by default.
      '';
    };
    "media-sophgo-unbind-sg2002-vpss-from-reserved-pool" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "Folded into the SG2002 VPSS driver patch before submission";
      notes = ''
        rmem_dma_ops cannot map imported dma-bufs, which a zero-copy
        capture->VPSS->encoder chain needs in both directions; VPSS is
        import-only and gains nothing from the pool. Also takes 0047's
        of_reserved_mem_device_release() out of vpss_remove while the
        rmmod wedge is being chased on hardware.
      '';
    };
    "media-coda-release-reserved-pool-after-teardown" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "Folded into the Coda980 support patch before submission";
      notes = ''
        0047 released the rmem dma_ops first in coda_remove, while vb2
        queues and the firmware arena still free through them —
        "modprobe -r coda-vpu" faulted (rc=139) on hardware. Release
        now runs after the last coherent free.
      '';
    };
    "media-sophgo-sg2002-vpss-capture-crop" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "Folded into the SG2002 VPSS driver patch before submission";
      notes = ''
        CAPTURE-side V4L2_SEL_TGT_CROP marks the visible image inside a
        macroblock-padded CAPTURE surface (e.g. 1080 lines in a 1088-line
        buffer, chroma plane at the padded offset) so the scaler feeds
        Coda980's expected layout without a CPU padding pass. Hardware
        validated 2026-08-18 (one-shot + live bridge).
      '';
    };
    "media-sophgo-sg2002-vpss-session-clocking" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "Folded into the SG2002 VPSS driver patch before submission";
      notes = ''
        Hold the VPSS clocks for the whole streaming session instead of
        per-job pm_runtime get/put: gating right after frame-end, while
        the ODMA may still be draining AXI, wedges the bus silently on
        hardware (watchdog reset). Also clear the full raw interrupt
        status in the ISR, per the vendor sclr_intr_clr.
      '';
    };
    "media-sophgo-sg2002-vpss-fabric-clocks" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "Folded into the SG2002 VPSS driver patch before submission";
      notes = ''
        The VPSS register window needs the VIP fabric clocks, which the
        CSI capture driver gates at stream stop; a VPSS write with them
        off stalls the bus silently (hardware-verified). Claimed as
        optional DT clocks so the driver still probes against the older
        6-clock board description.
      '';
    };
    "dt-bindings-reset-add-sg2002-csi-phy-resets" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "The named SG2002 CSI PHY resets are accepted upstream";
      notes = ''
        Names the existing reset-controller ABI IDs used by CSI PHY0 and its
        APB interface, kept separate from the media binding for submission.
      '';
    };
    "media-sophgo-sg2002-csi-complete-lane-permutation" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "Folded into the SG2002 CSI capture series before submission";
      notes = ''
        Completes the PHY data-lane selector permutation for sensors with
        fewer than four active lanes, matching the vendor CIF driver's fill
        of unused logical slots and avoiding duplicate physical selectors.
      '';
    };
    "media-sophgo-sg2002-csi-arm-sink-before-source" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "Folded into the SG2002 CSI capture series before submission";
      notes = ''
        Arms CSI and VI before starting a sensor subdevice so the receiver
        observes the source's LP-to-HS transition, and reverses that ordering
        during teardown.
      '';
    };
    "media-sophgo-allow-double-buffered-sg2002-csi-capture" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "Folded into the SG2002 CSI capture series before submission";
      notes = ''
        Allows an explicit two-buffer RAW capture queue. The DMA engine uses
        one active buffer while the second remains queued, and the existing
        scratch buffer absorbs starvation. This keeps the LicheeRV camera's
        capture plus Coda980 state within the proven 32 MiB media pool.
      '';
    };
    "media-i2c-galaxycore-gc4653" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "A GC4653 driver lands in drivers/media/i2c";
      notes = ''
        Sensor driver for the GalaxyCore GC4653 on the LicheeRV camera
        carrier. Written here because no upstream driver exists.
      '';
    };
    "media-sophgo-sg2002-csi-capture-raw-sources" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "The upstream SG2002 CSI capture driver accepts RAW Bayer sources";
      notes = ''
        Teaches the CSI capture path to take RAW Bayer from a sensor rather
        than only the LT6911 YUV route. Folded into the SG2002 CSI capture
        series before submission.
      '';
    };
    "media-sophgo-sg2002-csi-vendor-deskew-codes" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "Upstream CSI lane setup covers two-lane RAW sensors";
      notes = ''
        The GC4653 uses two physical data lanes; match the vendor cif
        driver's deskew and lane configuration for that case.
      '';
    };
    "media-sophgo-sg2002-csi-advertise-repacked-raw" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "Upstream advertises the repacked RAW formats the VI produces";
      notes = ''
        Report the repacked RAW pixel formats the capture hardware actually
        emits, so userspace negotiates a format the VI can deliver.
      '';
    };
    "media-sophgo-cap-sg2002-csi-capture-buffer-count" = {
      origin = "local";
      upstreamStatus = "draft";
      dropWhen = "Folded into the SG2002 CSI capture series before submission";
      notes = ''
        Caps REQBUFS and incremental CREATE_BUFS at the proven two-buffer
        capture queue. Four 2560x1440 RAW10 buffers consume the complete
        32 MiB private media pool after allocation rounding, leaving no room
        for the STREAMON scratch buffer and causing a misleading -ENOMEM.
      '';
    };
  };
  # Every applied patch documents where it came from and when it can go,
  # and nothing keeps metadata for a patch that is no longer applied. Both
  # halves drifted once: a patch that Linux had already absorbed kept its
  # entry, and four CSI patches carried none at all.
  appliedNames = map (p: p.name) patches;
  undocumented = builtins.filter (n: !(meta ? ${n})) appliedNames;
  orphanedMeta = builtins.filter
    (n: !(builtins.elem n appliedNames))
    (builtins.attrNames meta);
in
assert undocumented == [ ] || throw
  "kernel patches without metadata: ${builtins.concatStringsSep ", " undocumented}";
assert orphanedMeta == [ ] || throw
  "metadata for patches that are not applied: ${builtins.concatStringsSep ", " orphanedMeta}";
assert c906lMailbox.processorCount == 4;
assert c906lMailbox.slotCount == 8;
assert c906lHwspin.registerOffset == "0x000000c0";
assert c906lHwspin.registerCount == 8;
assert c906lHwspin.registerStride == 4;
assert c906lHwspin.accessWidth == 2;
assert c906lHwspin.mailboxField == 4;
assert c906lHwspin.tokenWidth == 8;
assert c906lHwspin.linuxTokenShift == 0;
assert c906lHwspin.c906lTokenShift == 8;
assert c906lHwspin.taskAcquireAttempts == 1024;
assert c906lHwspin.irqAcquireAttempts == 64;
assert builtins.elem "+#define MAILBOX_MAX_CPU\t\t4" cv1800MailboxPatchLines;
assert builtins.elem " #define MAILBOX_MAX_CHAN\t8" cv1800MailboxPatchLines;
assert builtins.elem "+#define MBOX_HWLOCK_BANK_OFFSET\t0x00c0" cv1800MailboxPatchLines;
assert builtins.elem "+#define MBOX_HWLOCK_FIELD\t4" cv1800MailboxPatchLines;
assert builtins.elem "+#define MBOX_HWLOCK_TASK_ATTEMPTS\t1024" cv1800MailboxPatchLines;
assert builtins.elem "+#define MBOX_HWLOCK_IRQ_ATTEMPTS\t64" cv1800MailboxPatchLines;
assert builtins.elem "+#define MBOX_HWLOCK_LINUX_TOKEN_MASK\tGENMASK(7, 0)" cv1800MailboxPatchLines;
assert builtins.elem "+#define MBOX_HWLOCK_RTOS_TOKEN_MASK\tGENMASK(15, 8)" cv1800MailboxPatchLines;
assert builtins.elem "+static_assert(MBOX_HWLOCK_REG == 0x00d0);" cv1800MailboxPatchLines;
{
  inherit patches meta;
}
