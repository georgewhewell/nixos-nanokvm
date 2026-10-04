# Structured kernel-config choices on top of the RISC-V defconfig.
# Consumed via buildLinux's structuredExtraConfig — each attr becomes a
# CONFIG_* line (or "# CONFIG_* is not set" for `no`) merged on top of
# `make defconfig`; the result is reconciled by `make olddefconfig`.
{ lib }:
with lib.kernel; {
  # =====================================================================
  # Early-boot compatibility for the T-Head C906 (SG2002).
  #
  # Keep the known-good non-relocatable, non-KASLR layout on the T-Head C906.
  RANDOMIZE_BASE = no;
  RELOCATABLE = no;

  # buildLinux installs arch/riscv/boot/Image.  RISC-V defconfig otherwise
  # selects KERNEL_GZIP, which makes nixpkgs look for Image.gz even though our
  # FIT builder deliberately compresses Image itself.
  KERNEL_GZIP = no;
  KERNEL_UNCOMPRESSED = yes;

  # THE early-hang cause. The NixOS base enables the RISC-V vector stack
  # including RISCV_ISA_XTHEADVECTOR (mainline support for the C906's
  # *non-standard* T-Head vector, detected via the T-Head vendor id — not
  # the DT `riscv,isa` string, which is only "rv64imafdc"). Worse,
  # RISCV_PROBE_VECTOR_UNALIGNED_ACCESS makes the kernel *execute vector
  # instructions at boot* to probe unaligned-access support — before any
  # console. On the SG2002's C906 that probe hangs silently. The riscv
  # defconfig (which booted) has no vector support at all. Rip the whole
  # vector stack out to match it.
  RISCV_ISA_V = no;
  RISCV_ISA_V_DEFAULT_ENABLE = no;
  RISCV_ISA_XTHEADVECTOR = no;
  RISCV_VECTOR_MISALIGNED = no;
  RISCV_PROBE_VECTOR_UNALIGNED_ACCESS = no;

  # More NixOS-base-only options that *do work during early boot* and that
  # the booting defconfig lacks. Vector/KASLR/RELOCATABLE off didn't fix
  # the hang, so batch-disable the next tier of boot-active machinery:
  #   - FTRACE: DYNAMIC_FTRACE + patchable-function-entry + CALL_OPS patches
  #     every kernel function's entry at early boot — RISC-V's newer
  #     code-patching path is a prime silent-hang suspect on the C906.
  #   - NUMA: single C906, no NUMA topology; OF_NUMA/arch-numa init runs
  #     early and defconfig never enables it.
  #   - KFENCE / PAGE_POISONING: set up guard pools / poison pages at boot.
  # If this boots, binary-search which one mattered.
  FTRACE = no;
  NUMA = no;
  KFENCE = no;
  PAGE_POISONING = no;

  # The RISC-V defconfig creates 256 BSD-style legacy PTYs.  Each one becomes
  # a separate udev coldplug event, while sshd/getty use Unix98 devpts.  On the
  # C906 this otherwise keeps initrd udev busy for roughly 35 seconds.
  LEGACY_PTYS = no;

  # =====================================================================
  # Live-boot infrastructure: NBD root (usb0-served erofs) + kexec for
  # the stage2 -> stage2 dev loop.
  # =====================================================================
  BLK_DEV_NBD = yes;
  KEXEC = yes;
  KEXEC_FILE = yes;

  # SD card (sdhci0 / sophgo,cv1800b-dwcmshc) and MMC_BLOCK are selected
  # by RISC-V defconfig; autoModules is disabled, so they stay built in.

  # =====================================================================
  # Enables — SoC + gadget + aic8800 OOT driver
  # =====================================================================

  # USB DWC2 (the SG2002 OTG controller) + CONFIGFS gadget stack.
  # CDC-ECM + CDC-ACM + CDC-SERIAL give us usb0 + ttyACM over the
  # single USB-C port; no UART required.
  USB_DWC2 = yes;
  USB_DWC2_DUAL_ROLE = yes;
  USB_CONFIGFS = yes;
  USB_CONFIGFS_ECM = yes;
  USB_CONFIGFS_ACM = yes;
  USB_CONFIGFS_SERIAL = yes;
  USB_CONFIGFS_RNDIS = yes;
  USB_CONFIGFS_NCM = yes; # for boards.<...>.live.usb-ncm
  USB_F_ECM = yes;
  USB_F_ACM = yes;
  USB_F_SERIAL = yes;
  USB_F_RNDIS = yes;
  USB_F_NCM = yes;
  USB_F_MASS_STORAGE = yes; # available to configfs

  # Gadget driver coexistence:
  #
  #   - USB_ETH (g_ether) is OFF. It used to auto-bind to dwc2 at
  #     kernel init in EEM mode with a random MAC, before the
  #     userspace configfs gadget setup could claim the UDC. Bad
  #     interaction with our br0.lan auto-bridging too. Verified
  #     2026-05-13.
  #
  #   - USB_G_MULTI (g_multi) is ON. It auto-bind-attempts at kernel
  #     init too, but unlike g_ether it requires a mass_storage
  #     backing file. If no `g_multi.file=` / `g_multi.removable=1`
  #     is on the cmdline, gadget bind fails with -EINVAL and the
  #     UDC stays free for the userspace configfs gadget — i.e. the
  #     default cmdline preserves our existing configfs setup. The
  #     `boards.<...>.live.usb-g-multi` variant passes the required
  #     params to flip the switch in g_multi's favour, AND disables
  #     the configfs systemd service in its initrd so the two
  #     drivers don't both try to claim the UDC.
  USB_GADGET = yes;
  USB_LIBCOMPOSITE = yes;
  USB_ETH = no;
  USB_G_MULTI = yes;
  USB_G_MULTI_RNDIS = yes;
  USB_G_MULTI_CDC = no; # see comment below
  USB_MASS_STORAGE = no;
  # On the dev-board test 2026-05-13, building g_multi with BOTH the
  # RNDIS and CDC-ECM configs caused Linux on the host to prefer
  # config 2 (CDC-ECM) and then `cdc_ether` probe failed with
  # -EPIPE — no fallback to config 1. With CDC off there's only one
  # config (RNDIS), and `rndis_host` binds cleanly. The configfs
  # path retains the ECM choice via `nanokvm.usbGadget.network.
  # transport = "ecm"`, so this is only a constraint of the g_multi
  # variant.
  # Route kernel console (console=ttyGS0,115200) to the USB CDC-ACM
  # gadget — needed for bare-ACM diagnostic mode where there's no
  # UART and no USB network gadget, so serial-over-USB is the only
  # way to see kernel messages.
  U_SERIAL_CONSOLE = yes;
  # CV18xx-specific USB2 PHY — dwc2 defers forever without it.
  PHY_SOPHGO_CV1800_USB2 = yes;
  GENERIC_PHY = yes;
  MFD_SYSCON = yes;

  # Wireless stack — needed for the out-of-tree aic8800 driver and the
  # hardened NixOS wpa_supplicant unit. Keep both cfg80211 and rfkill as
  # modules: the driver loads against cfg80211.ko, while /dev/rfkill must
  # exist before wpa_supplicant can construct its private mount namespace.
  WIRELESS = yes;
  CFG80211 = module;
  RFKILL = module;
  CFG80211_WEXT = yes;
  WEXT_CORE = yes;
  WEXT_PROC = yes;
  WEXT_PRIV = yes;

  # Firmware-blob loader handles .zst on the fly — NixOS's
  # hardware.firmware path ships zst-compressed blobs by default
  # (aic8800-firmware-zstd on the rootfs).
  FW_LOADER_COMPRESS = yes;
  FW_LOADER_COMPRESS_ZSTD = yes;
  # cpio initrd zstd decompression (mkUsbInitrd uses `zstd -19`).
  RD_ZSTD = yes;

  # Dev ergonomics — let /dev/mem see driver-owned MMIO for debugging.
  # Default y policy blocks userspace reads/mmap of regions claimed by
  # drivers, which broke our sdhci1 poking earlier. Dev-board only.
  STRICT_DEVMEM = no;
  IO_STRICT_DEVMEM = no;

  # zram (RAM-only compressed block device used as swap). SD-backed
  # swap would thrash the card — zram keeps compressed pages in RAM so
  # we get ~2× effective memory without any SD writes.
  ZRAM = module;
  ZRAM_DEF_COMP_ZSTD = yes;
  ZRAM_DEF_COMP = freeform "zstd";
  ZRAM_BACKEND_ZSTD = yes;
  CRYPTO_ZSTD = yes;
  ZPOOL = yes;
  ZSMALLOC = yes;

  # usb-live boot: erofs-compressed rootfs loop-mounted at /sysroot,
  # overlayfs for writable /var /tmp /root, switch-root into it. All
  # three bits are =y so initrd doesn't need module loading to mount
  # the rootfs.
  EROFS_FS = yes;
  EROFS_FS_ZIP = yes;
  EROFS_FS_ZIP_ZSTD = yes;
  BLK_DEV_LOOP = yes;
  OVERLAY_FS = yes;

  # The SD image has a small FAT firmware partition. Stage-1 mounts it
  # before the normal rootfs module set is available, so FAT's default
  # CP437 codepage and iso8859-1 charset must be built in rather than
  # left as modules.
  NLS_CODEPAGE_437 = yes;
  NLS_ISO8859_1 = yes;
  NLS_UTF8 = yes;

  # dw_wdt binds to the DesignWare WDT at 0x03010000; systemd then
  # pets /dev/watchdog0 via RuntimeWatchdogSec. Replaces the old
  # /dev/mem userspace petter.
  WATCHDOG_CORE = yes;
  WATCHDOG_NOWAYOUT = yes;
  WATCHDOG_HANDLE_BOOT_ENABLED = yes;
  WATCHDOG_SYSFS = yes;
  WATCHDOG_HRTIMER_PRETIMEOUT = yes;
  WATCHDOG_PRETIMEOUT_GOV = yes;
  WATCHDOG_PRETIMEOUT_GOV_PANIC = yes;
  WATCHDOG_PRETIMEOUT_DEFAULT_GOV_PANIC = yes;
  DW_WATCHDOG = yes;
  PANIC_ON_OOPS = yes;
  PANIC_TIMEOUT = freeform "5";
  SOFTLOCKUP_DETECTOR = yes;
  BOOTPARAM_SOFTLOCKUP_PANIC = freeform "1";
  HARDLOCKUP_DETECTOR = option yes;
  BOOTPARAM_HARDLOCKUP_PANIC = option yes;
  DETECT_HUNG_TASK = yes;
  BOOTPARAM_HUNG_TASK_PANIC = freeform "1";
  WQ_WATCHDOG = yes;
  BOOTPARAM_WQ_STALL_PANIC = freeform "1";
  # sysrq for forcing kernel panics to test that the HW WDT actually
  # bites. `echo c > /proc/sysrq-trigger` panics the kernel; with no
  # one petting the WDT, the SoC should reset within ~42 s.
  MAGIC_SYSRQ = yes;

  # CV1800 RTC + parent RTCSYS subsystem. `rtc@5025000` is in upstream
  # cv180x.dtsi already, so no DT change needed; just flip the configs.
  # Driver: drivers/rtc/rtc-cv1800.c. RTCSYS parent: drivers/soc/sophgo/.
  SOPHGO_CV1800_RTCSYS = yes;
  RTC_DRV_CV1800 = yes;

  HW_RANDOM = yes;
  HW_RANDOM_SG2002 = yes;

  # On-die SoC temperature sensor (driver in patches/0006, backport
  # of Haylen Chu's stalled v5 LKML series). Built-in rather than =m
  # so it shows up in the USB-recovery initrd without an extra entry
  # in modules/initrd-audio.nix's kernelModules — driver is ~7 KB.
  CV1800_THERMAL = yes;
  THERMAL = yes;
  THERMAL_OF = yes;

  # SAR-ADC (auxiliary 12-bit ADC at 0x030F0000, distinct from the
  # audio RXADC). Three channels; PIN_ADC1 is the only one broken
  # out as a dedicated analog pad on the SG2002. Driver: drivers/iio/
  # adc/sophgo-cv1800b-adc.c. Channels appear as
  # /sys/bus/iio/devices/iio:device0/in_voltage{0,1,2}_raw,
  # plus — via the iio-hwmon shim and the matching DT node in
  # sg2002-licheerv-nano-bw.dtsi — under /sys/class/hwmon/hwmonN/
  # as in1_input..in3_input. The hard-coded 3.3 V reference is not
  # calibrated; these are not established board voltage measurements.
  IIO = yes;
  SOPHGO_CV1800B_ADC = yes;
  SENSORS_IIO_HWMON = yes;

  # DesignWare I2C controllers: IIC1..4 have alternate-function routes.
  # The existing IIC0 pad routing needs validation. Overlays select pins
  # and clients (including the IIC1 OLED and IIC4 camera). Built-in
  # with the chardev for userspace access to each enabled bus.
  I2C = yes;
  I2C_CHARDEV = yes;
  I2C_DESIGNWARE_PLATFORM = yes;
  # Bit-banged I2C for the NanoKVM-PCIe front-panel OLED (the panel
  # hangs off two plain GPIOs, not a hardware controller — see the
  # i2c-gpio node in dtb-mainline/sg2002-nanokvm-pcie.dtsi). Built-in
  # rather than modular so the bus exists as soon as the DT is parsed
  # and we dodge the initrd module-pruning machinery entirely;
  # ssd1307fb itself stays a stage-2 module (below).
  I2C_GPIO = yes;

  # PicoClaw's onboard ST7789 is connected to SPI1.  Keep the controller
  # and spidev modular so the proven headless images pay no runtime cost;
  # modules/picoclaw-lcd.nix loads them only in the dedicated LCD artifact.
  SPI = yes;
  SPI_DESIGNWARE = module;
  SPI_DW_MMIO = module;
  SPI_SPIDEV = module;

  # PWM controller (driver in patches/0008). Built-in so /sys/class/
  # pwm/pwmchip0..3 are present in the USB-recovery initrd without
  # extra module-loading. Each IP instance handles 4 channels.
  PWM = yes;
  PWM_SOPHGO_CV1800 = yes;

  # Audio OFF on the KVM: the SoC has I2S/TDM + internal mic/speaker,
  # but turning SND_SOC on against the full NixOS base drags ~400 codec
  # modules we'll never use, and a KVM doesn't need audio. Force the
  # whole sound subsystem off. (Re-enable SOUND/SND_SOC + the
  # SND_SOC_CV1800B_* drivers here if audio is ever wanted.)
  SOUND = no;
  # DMA engine + dmamux required for the I2S DMA paths to work.
  # dw_axi_dmac drives the 8-channel AXI DMA at 4330000; the dmamux
  # (drivers/dma/cv1800b-dmamux.c) routes the peripheral request
  # lines (i2s tx/rx, sdio, etc.) to those channels.
  DMADEVICES = yes;
  DW_AXI_DMAC = yes;
  SOPHGO_CV1800B_DMAMUX = yes;

  # Legacy framebuffer subsystem + ssd1307fb (drives SSD1305/06/07/09 and
  # our locally patched SH1107 path) + fbcon. Keep ssd1307fb modular so
  # USB/NBD initrd boot does not depend on OLED probe success; the OLED
  # module loads in stage 2 via modules/oled.nix.
  FB = yes;
  FB_SSD1307 = module;
  FRAMEBUFFER_CONSOLE = yes;
  FRAMEBUFFER_CONSOLE_ROTATION = yes;
  BACKLIGHT_CLASS_DEVICE = yes;
  # PicoClaw drives its panel backlight from PWM_7 rather than a GPIO, so
  # brightness is a standard /sys/class/backlight device.
  BACKLIGHT_PWM = yes;
  # Compile in the 4×6 micro-font for the 128×128 OLED. Default 8×16 gives
  # only 16 cols × 8 rows. MINI4x6 gives 32 columns and enough rows for
  # tools such as top. Selected at runtime via `fbcon=font:MINI4x6`; the
  # OLED variant also enables fbcon's software rotation.
  #
  # CONFIG_FONTS gates per-font selection; without it, only the
  # `default y if FRAMEBUFFER_CONSOLE` fonts (8x8, 8x16) get pulled in
  # and FONT_MINI_4x6 silently disappears at olddefconfig.
  FONTS = yes;
  FONT_MINI_4x6 = yes;

  # =====================================================================
  # Disables — prune defconfig bloat we can't use on SG2002
  # =====================================================================

  # The SG2002 boots from a device-tree-described SoC through vendor FSBL /
  # U-Boot. It has no ACPI firmware table, EFI runtime, or PC-style DMI
  # inventory; ACPI and DMI are broad RISC-V defconfig defaults and pull in
  # a surprising amount of laptop/server plumbing. The RISC-V Kconfig keeps
  # its EFI symbol default-y even when structuredExtraConfig says `no`, so we
  # do not pretend an ineffective EFI blacklist is a real size reduction.
  ACPI = no;
  DMI = no;

  # The board DT supplies divider-only operating points and CPU cooling.
  # Keep standard CPUFreq policy; suspend and CPU idle are not implemented.
  SUSPEND = no;
  CPU_IDLE = no;
  CPU_FREQ = yes;
  CPUFREQ_DT = yes;
  CPU_FREQ_STAT = yes;
  CPU_FREQ_DEFAULT_GOV_SCHEDUTIL = yes;
  CPU_FREQ_DEFAULT_GOV_PERFORMANCE = no;
  CPU_FREQ_GOV_PERFORMANCE = yes;
  CPU_FREQ_GOV_POWERSAVE = yes;
  CPU_FREQ_GOV_USERSPACE = yes;
  CPU_FREQ_GOV_SCHEDUTIL = yes;
  CPU_THERMAL = yes;

  # RISC-V defconfig enables these observability/large-memory
  # facilities even on this 256 MiB appliance. No board service uses eBPF,
  # perf, or hugetlbfs; disabling their user-facing gates lets Kconfig remove
  # dependent leaves transitively instead of maintaining a long blacklist.
  BPF_SYSCALL = no;
  CGROUP_BPF = no;
  PERF_EVENTS = no;
  HUGETLBFS = no;

  # The upstream controller is used as the low-latency doorbell to C906L.
  # Bulk messages belong in explicitly reserved shared DDR; do not enable
  # mailbox-test, whose generic buffer assumptions do not match this 8-byte
  # controller.
  MAILBOX = yes;
  CV1800_MBOX = yes;

  # C906L is started by the FSBL. The local platform driver uses remoteproc's
  # detached/attach-only state and exposes read-only lifecycle controls: it
  # cannot load, stop, reset, or auto-recover the core. Linux maps fixed
  # vrings uncached, allocates RPMsg buffers from their dedicated reserved
  # pool, and uses AP-mailbox channels 1/2 only as doorbells.
  REMOTEPROC = yes;
  REMOTEPROC_CDEV = no;
  RPMSG = yes;
  RPMSG_CHAR = yes;
  RPMSG_CTRL = yes;
  RPMSG_NS = yes;
  RPMSG_VIRTIO = yes;

  # =====================================================================
  # PCIe / virtio / DRM — dead on the SG2002, alive under QEMU
  #
  # None of this exists on the real silicon.  It is here so that the
  # *same* Image also boots `qemu-system-riscv64 -M virt -cpu thead-c906`
  # (boards/qemu-riscv-virt.nix) with a display, rather than forcing a
  # second cross-compile of a near-identical kernel. ARCH_VIRT below
  # also enables the virt machine's poweroff and RTC plumbing.
  #
  # The rule is: modular wherever Kconfig allows, so the board builds
  # the code but never loads it.  The initrds are module-pruned and no
  # board DT describes a PCI host bridge or a virtio transport, so the
  # runtime cost on the 256 MiB device is zero.  CONFIG_PCI is `bool`,
  # so it is the one piece that has to be built in.
  # =====================================================================
  PCI = yes;
  PCI_HOST_GENERIC = yes; # the virt machine's ECAM bridge
  # ...but not the SoC-specific host controllers the RISC-V defconfig
  # switches on once PCI is back. No SG2002 and no virt machine has a
  # Xilinx / FU740 / StarFive root port.
  PCIEPORTBUS = no;
  PCIE_XILINX = no;
  PCIE_FU740 = no;
  PCIE_STARFIVE_HOST = no;
  PHY_STARFIVE_JH7110_PCIE = no;
  # Still no NVMe/SCSI/ATA anywhere in this deployment; PCI coming back must
  # not drag the block-driver zoo in behind it.
  SCSI = no;
  ATA = no;
  BLK_DEV_NVME = no;
  # ...nor the PCIe NIC zoo. These two are `default y` behind their
  # NET_VENDOR_* gates and were the concrete "net vendor spam" the old
  # `PCI = no` comment meant: both are built *into* the Image, on a board
  # whose only MACs are the internal one and USB/SDIO gadgets, and on a
  # virt machine that uses virtio-net.
  E1000E = no;
  R8169 = no;
  # Same story for add-in-card UARTs: the SG2002's console is the SoC
  # 8250-DW, and virt's is the platform ns16550a. Neither is on PCI.
  # EXAR and PERICOM are `default SERIAL_8250` and do not hang off
  # SERIAL_8250_PCI, so all three need naming; SERIAL_8250_PCILIB is a
  # bare `select` and drops out once its two selectors are gone.
  SERIAL_8250_PCI = no;
  SERIAL_8250_EXAR = no;
  SERIAL_8250_PERICOM = no;
  # Note: CONFIG_PCIEASPM stays `y` and cannot be turned off from here.
  # Its prompt is `bool "..." if EXPERT` with `default y`, and this tree
  # builds from a plain defconfig with `# CONFIG_EXPERT is not set`, so
  # the symbol is invisible and olddefconfig restores the default. It is
  # ~15 KiB of link-state management for links neither target has.

  # No nested virt in either target.
  KVM = no;
  # VIRTIO itself is a hidden library symbol. RISC-V defconfig selects
  # these leaves independently, so drive the actual drivers. Modular:
  # only the QEMU guest's initrd ever asks for them.
  VIRTIO_BALLOON = module;
  VIRTIO_BLK = module;
  VIRTIO_NET = module;
  VIRTIO_PCI = module;

  # The DRM stack exists solely for virtio-gpu — that is the only
  # framebuffer QEMU's virt machine can offer, since it has no VGA, no
  # SPI (so no ST7789) and no I2C (so no SSD1307). With
  # DRM_FBDEV_EMULATION the FRAMEBUFFER_CONSOLE enabled above paints the
  # QEMU window directly, with no X and no userspace driver.
  # On hardware the panels keep using the legacy FB path (ssd1307fb),
  # which is independent of DRM, and drm.ko is never loaded.
  DRM = module;
  DRM_VIRTIO_GPU = module;
  DRM_FBDEV_EMULATION = yes;
  # Nouveau alone is ~30 .ko files of dead weight, and the RISC-V
  # defconfig turns these on the moment DRM is non-`no`. Keep them out
  # of the modules tree so the board's build time and closure don't pay
  # for a QEMU display.
  DRM_NOUVEAU = no;
  DRM_RADEON = no;
  DRM_AMDGPU = no;
  DRM_I915 = no;
  DRM_SUN4I = no;
  MTD = no; # no raw flash, only SD + USB
  INFINIBAND = no;
  # INPUT itself is default-y and not user-visible without CONFIG_EXPERT, so
  # close its hardware menus explicitly. HID injection is a gadget function.
  HID = no;
  INPUT_KEYBOARD = no;
  INPUT_MOUSE = no;
  INPUT_TOUCHSCREEN = no;
  INPUT_JOYSTICK = no;
  INPUT_TABLET = no;
  # NanoKVM HDMI capture path: LT6911 HDMI-to-MIPI bridge followed by the
  # SG2002 CSI MAC0 / VI DMA6 direct packed-YUV capture driver.
  MEDIA_SUPPORT = yes;
  MEDIA_CAMERA_SUPPORT = yes;
  MEDIA_CONTROLLER = yes;
  VIDEO_DEV = yes;
  VIDEO_V4L2_SUBDEV_API = yes;
  V4L2_FWNODE = yes;
  V4L2_CCI_I2C = yes;
  VIDEO_LT6911UXE = yes;
  VIDEO_SOPHGO_SG2002_CSI = yes;
  # LicheeRV Nano camera module (RAW10 Bayer sensor, see patch 0053).
  VIDEO_GC4653 = module;
  VIDEOBUF2_DMA_CONTIG = yes;
  # Coda980 is a stateful mem2mem H.264 encoder. The SG2002 path accepts
  # direct linear NV12 input (the corruption was the CODA_960 tiled GDI
  # map, not addressing or coherency) and stages NV21 through a coherent
  # buffer for chroma-order conversion.
  DMA_SHARED_BUFFER = yes;
  # System dma-heap: lets the userspace bridge CPU-convert into CACHED
  # memory and hand it to Coda as an imported DMA-BUF with explicit
  # DMA_BUF_IOCTL_SYNC coherency brackets, instead of writing uncached
  # vb2 dma-contig mappings (the dominant pipeline cost on this SoC).
  DMABUF_HEAPS = yes;
  DMABUF_HEAPS_SYSTEM = yes;
  # Guaranteed-contiguous heap: vb2-dma-contig rejects multi-segment
  # imports (EFAULT at QBUF), which the system heap can produce for a
  # 3 MiB frame. The CMA heap is the contiguous allocator.
  DMABUF_HEAPS_CMA = yes;
  V4L_MEM2MEM_DRIVERS = yes;
  VIDEO_CODA = module;
  VIDEO_SOPHGO_SG2002_VPSS = module;
  # The generic Cadence receiver is a separate IP block. SG2002 capture uses
  # the SoC-specific MAC0/VI driver above and never instantiates this module.
  VIDEO_CADENCE_CSI2RX = no;

  # Step 2 (current): the dtsi video-pool@86800000 (32 MiB no-map
  # shared-dma-pool) serves CSI capture + Coda980 — a carveout the page
  # allocator cannot colonize. VPSS is deliberately NOT pool-bound (0048):
  # rmem dma_ops cannot map imported dma-bufs. The default CMA serves the
  # VPSS<->encoder middle buffers at 1080p (4 x 3.13 MiB) — 24 MiB keeps
  # them out of the pool, and is only affordable once the deployment drops the
  # ~88 MiB preserved-initrd pin (usbGadget.stage2.preserveInitrd=false).
  CMA = yes;
  DMA_CMA = yes;
  CMA_SIZE_MBYTES = freeform "24";
  CMA_SIZE_SEL_MBYTES = yes;
  CMA_SIZE_SEL_PERCENTAGE = no;
  CMA_SYSFS = yes;

  # printk over UDP: the only console that survives the SoC bus-stall
  # wedges this board's media bring-up keeps hitting (journald lag +
  # btrfs loss ate every post-mortem before this).
  NETCONSOLE = module;

  MEDIA_SUBDRV_AUTOSELECT = no;
  MEDIA_ANALOG_TV_SUPPORT = no;
  MEDIA_DIGITAL_TV_SUPPORT = no;
  MEDIA_RADIO_SUPPORT = no;
  MEDIA_SDR_SUPPORT = no;
  MEDIA_PLATFORM_DRIVERS = yes;
  V4L_PLATFORM_DRIVERS = yes;
  MEDIA_TEST_SUPPORT = no;
  MEDIA_USB_SUPPORT = no;
  # NFC, WWAN, IrDA, legacy PPS. (IIO is wanted on this SoC for the
  # SAR-ADC driver — see SOPHGO_CV1800B_ADC above.)
  NFC = no;
  WWAN = no;
  CAN = no;
  # mainline Bluetooth stack — aic8800 uses aic8800_btlpm, not BT.
  BT = no;

  # SG2002 *does* have an on-die GMAC (sophgo,cv1800b-dwmac /
  # snps,dwmac-3.70a) at 0x4070000; the LicheeRV-Nano dev board leaves it
  # unwired, but the NanoKVM-PCIe carrier routes it to the RJ45. Mainline
  # 7.0's dwmac-sophgo only matches sg2042/sg2044 and never powers up the
  # cv1800b internal EPHY, so patch 0013 adds a "sophgo,cv1800b-dwmac"
  # binding that mirrors the vendor U-Boot EPHY power-up.
  #
  # Keep dwmac-sophgo and the internal EPHY's MMIO MDIO mux built in. This
  # prevents networkd from opening eth0 before the child MDIO bus exists.
  NET_VENDOR_STMICRO = yes;
  STMMAC_ETH = yes;
  STMMAC_PLATFORM = yes;
  DWMAC_SOPHGO = yes;
  DWMAC_GENERIC = no;
  DWMAC_THEAD = no;
  PHYLIB = yes;
  MDIO_BUS = yes;
  MDIO_DEVICE = yes;
  MDIO_BUS_MUX = yes;
  MDIO_BUS_MUX_MMIOREG = yes;
  # Generic RISC-V defconfig makes this Cadence Ethernet driver built-in even
  # after its foreign SoC users are disabled. Guard the driver itself; the
  # other default-y NET_VENDOR_* values are empty Kconfig menus, not objects.
  MACB = no;

  # Foreign RISC-V SoC support. RISC-V defconfig targets everything
  # with a single image — StarFive JH7110, Spacemit K1, SiFive HiFive,
  # Allwinner D1, Microchip Polarfire — each of which pulls pinctrl,
  # clock, reset, PHY, GPIO, watchdog drivers that are useless on
  # Sophgo SG2002. Turning the ARCH_ gates off cascades through
  # olddefconfig and disables all of those.
  ARCH_STARFIVE = no;
  # These default-y children otherwise select ARCH_STARFIVE back on.
  SOC_STARFIVE = no;
  ARCH_SPACEMIT = no;
  ARCH_SIFIVE = no;
  ERRATA_SIFIVE = no;
  SIFIVE_CCACHE = no;
  ARCH_SUNXI = no;
  ARCH_MICROCHIP = no;
  ARCH_MICROCHIP_POLARFIRE = no;
  ARCH_RENESAS = no;
  ARCH_CANAAN = no;
  ARCH_ANDES = no;
  ARCH_ANLOGIC = no;
  ARCH_ESWIN = no;
  ARCH_TENSTORRENT = no;
  ARCH_ULTRARISC = no;
  # ...except QEMU's, which boards/qemu-riscv-virt.nix boots this very
  # Image on. Unlike the foreign SoCs above, ARCH_VIRT pulls in no
  # pinctrl/clock/PHY zoo: it selects only POWER_RESET_SYSCON{,_POWEROFF}
  # and the goldfish RTC. Without it `poweroff` in the guest cannot stop
  # QEMU and the VM has no clock — for a couple of KB the SG2002 carries
  # but never probes, since no board DT has a syscon-poweroff node.
  ARCH_VIRT = yes;

  # Other USB host controllers — SG2002's only USB is DWC2 OTG; XHCI/
  # EHCI/OHCI only exist for discrete host controllers we don't have.
  # DWC2 dual-role covers both device (our gadget) and host modes.  Its DT
  # binding still consumes the generic nop transceiver, so keep that tiny PHY
  # driver: without it DWC2 never registers, NFS root cannot appear, and the
  # initrd watchdog resets the board.
  USB_XHCI_HCD = no;
  USB_EHCI_HCD = no;
  USB_OHCI_HCD = no;
  USB_CDNS_SUPPORT = no;
  USB_MUSB_HDRC = no;
  NOP_USB_XCEIV = module;

  # Not using any of these on this board.
  NFSD = no;
  # Both are default-y in RISC-V defconfig rather than children of a shared
  # security-suite gate, so retain these two explicit policy choices.
  SECURITY_APPARMOR = no;
  SECURITY_SELINUX = no;

  # NFS *client* — the PicoClaw netboot profile mounts /nix/store read-only
  # from the development host's kernel nfsd, replacing the NBD-served
  # erofs rootfs. Its writable overlay is local tmpfs, so the board remains
  # completely stateless. Built-in so the initrd mounts without module
  # loading. Server side stays off; the other network filesystems are dead
  # compile weight.
  NETWORK_FILESYSTEMS = yes;
  NFS_FS = yes;
  NFS_V4 = yes;
  NFS_V4_1 = yes;
  NFS_V4_2 = yes;
  # 9P defaults *built in* alongside generic Virtio support, which is dead
  # weight on a board whose only network filesystem is NFS. Demote rather
  # than delete: the QEMU guest (boards/qemu-riscv-virt.nix) mounts the
  # host store over 9p, and that is the whole reason a rebuild there costs
  # a closure copy instead of a disk image. Same bargain as the
  # PCIe/virtio/DRM block above — the board builds these .ko and, with no
  # 9p mount in any board fileSystems, never pulls them into an initrd.
  "9P_FS" = module;
  NET_9P = module;
  NET_9P_VIRTIO = module;

  # aic8800 is out-of-tree and only needs cfg80211/WEXT. Disable the single
  # upstream WLAN driver menu instead of blacklisting every vendor beneath it.
  WLAN = no;

  # =====================================================================
  # Broad subsystem gates — RISC-V defconfig supports many machines, while
  # this 256 MiB NanoKVM has a fixed, small hardware inventory. Keep this to
  # top-level facilities; proven Kconfig selector exceptions live beside
  # their parent gates above.
  # =====================================================================

  # No SCSI / ATA / NVMe / RAID / device-mapper / multipath — the only
  # storage is the SD/eMMC controller (cv-sd, kept above).
  MD = no;
  TARGET_CORE = no;
  # SD initrds include this module through supportedFilesystems. Keeping it
  # modular avoids adding an otherwise unused ~2 MiB filesystem to every
  # USB/NFS live kernel built from this shared configuration.
  BTRFS_FS = module;
  BTRFS_FS_POSIX_ACL = yes;
  # SG2002 has only generic integer RAID6 implementations. Benchmarking all
  # four at Btrfs module load costs roughly 37 seconds on the C906 and cannot
  # improve a single-device SD root; select the last implementation directly.
  RAID6_PQ_BENCHMARK = no;
  LIBNVDIMM = no;
  DAX = no;
  EFIVAR_FS = no;

  # No Cadence SDHCI/QSPI instances exist in the SG2002 DT. Storage uses the
  # Synopsys DWC MSHC and the optional display path uses DesignWare SPI.
  MMC_SDHCI_CADENCE = no;
  SPI_CADENCE_QUADSPI = no;

  # Gadget-only USB: keep dwc2 + the configfs functions (above); drop
  # host-class drivers, serial converters, USB-net, USB mass-storage
  # host, USB HID, and the host-side device zoo.
  USB_SERIAL = no;
  USB_NET_DRIVERS = no;
  USB_STORAGE = no;

  # The PicoClaw C906L owns GPIOA26 and exposes Wi-Fi power as a regulator.
  # MMC must defer until this provider exists and use its acknowledged power
  # sequence. No external PMIC drivers are required.
  REGULATOR = yes;
  POWER_SUPPLY = no;
  MFD_AXP20X_I2C = no;

  # Networking: no traffic shaping, software bridge, or VLANs. Netfilter
  # stays on — the RISC-V defconfig provides the whole iptables/conntrack
  # set as modules, so an unused firewall costs the board nothing loaded.
  NETFILTER = yes;
  # ...but defconfig predates nftables and carries no NFT_* at all, while
  # nixpkgs' `iptables` has been iptables-nft since 21.11. Without these
  # two, `networking.firewall` dies at boot with
  #   iptables: Failed to initialize nft: Protocol not supported
  # NFT_COMPAT is what lets the nft backend service classic `-m` matches.
  # The per-family tables are plain bools with no default, so NF_TABLES
  # alone still leaves `iptables -A INPUT` failing with
  #   TABLE_ADD failed (Operation not supported): table filter
  # because there is no `ip` family to add it to. The expression modules
  # are for the native backend (networking.nftables.enable).
  NF_TABLES = module;
  NFT_COMPAT = module;
  NF_TABLES_IPV4 = yes;
  NF_TABLES_IPV6 = yes;
  NF_TABLES_INET = yes;
  NFT_CT = module;
  NFT_LOG = module;
  NFT_LIMIT = module;
  NFT_REJECT = module;
  # The three xt extensions NixOS's own firewall-start actually uses
  # (`-m pkttype`, `-m rpfilter`, `-m conntrack`; the last is already in
  # defconfig). Missing pkttype is not a soft failure — iptables aborts
  # the whole ruleset with "Extension pkttype revision 0 not supported"
  # and firewall.service exits 4.
  NETFILTER_XT_MATCH_PKTTYPE = module;
  NETFILTER_XT_TARGET_LOG = module;
  IP_NF_MATCH_RPFILTER = module;
  IP6_NF_MATCH_RPFILTER = module;
  NFT_FIB_IPV4 = module;
  NFT_FIB_IPV6 = module;
  NET_SCHED = no;
  BRIDGE = no;
  VLAN_8021Q = no;
  XFRM = no;
  XFRM_ALGO = no;
  XFRM_USER = no;
  XFRM_ESP = no;
  INET_ESP = no;
  IPV6 = yes;
  DUMMY = no;
  MACVLAN = no;
  IPVLAN = no;
  VETH = no;
  VXLAN = no;

  # CryptoDMA serves kernel Crypto API consumers; AF_ALG remains disabled.
  CRYPTO_DEV_SG2002 = module;
  CRYPTO_USER_API = no;
  CRYPTO_USER_API_HASH = no;
  CRYPTO_USER_API_ENABLE_OBSOLETE = no;
  CRYPTO_DEV_VIRTIO = no;

  # No other remote/exotic filesystems beyond the NFS client (enabled
  # above for the netboot profile) — keep btrfs/vfat/erofs/overlay/tmpfs
  # /configfs/autofs (those stay on via the base / above).

  # =====================================================================
  # Size/RAM trim — 256 MB boards, cross-compiled, no debug sessions
  # that need DWARF. DEBUG_INFO alone is a large fraction of build time
  # and output size. THP on a single in-order C906 with 256 MB buys
  # nothing and costs reclaim churn.
  # =====================================================================
  DEBUG_INFO = no;
  TRANSPARENT_HUGEPAGE = no;
}
