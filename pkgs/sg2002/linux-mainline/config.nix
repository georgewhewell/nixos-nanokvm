# Structured kernel-config overrides on top of the RISC-V defconfig.
# Consumed via buildLinux's structuredExtraConfig — each attr becomes a
# CONFIG_* line (or "# CONFIG_* is not set" for `no`) merged on top of
# `make defconfig`; the result is reconciled by `make olddefconfig`.
{ lib }:
with lib.kernel; {
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

  # Wireless stack — needed for out-of-tree aic8800 driver
  # (exposes `struct net_device.ieee80211_ptr` etc.)
  WIRELESS = yes;
  CFG80211 = yes;
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

  # dw_wdt binds to the DesignWare WDT at 0x03010000; systemd then
  # pets /dev/watchdog0 via RuntimeWatchdogSec. Replaces the old
  # /dev/mem userspace petter.
  WATCHDOG_CORE = yes;
  DW_WATCHDOG = yes;
  # sysrq for forcing kernel panics to test that the HW WDT actually
  # bites. `echo c > /proc/sysrq-trigger` panics the kernel; with no
  # one petting the WDT, the SoC should reset within ~42 s.
  MAGIC_SYSRQ = yes;

  # CV1800 RTC + parent RTCSYS subsystem. `rtc@5025000` is in upstream
  # cv180x.dtsi already, so no DT change needed; just flip the configs.
  # Driver: drivers/rtc/rtc-cv1800.c. RTCSYS parent: drivers/soc/sophgo/.
  SOPHGO_CV1800_RTCSYS = yes;
  RTC_DRV_CV1800 = yes;

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
  # as in1_input..in3_input millivolts (so `sensors` etc. work).
  IIO = yes;
  SOPHGO_CV1800B_ADC = yes;
  SENSORS_IIO_HWMON = yes;

  # I2C bus 0 — the only I2C with a dedicated pin pair on the SG2002
  # pad set (PIN_IIC0_SCL/SDA). Built-in + the chardev so userspace
  # gets /dev/i2c-0 for i2cdetect / i2cget directly. dwc-i2c is the
  # snps,designware-i2c driver.
  I2C = yes;
  I2C_CHARDEV = yes;
  I2C_DESIGNWARE_PLATFORM = yes;

  # PWM controller (driver in patches/0008). Built-in so /sys/class/
  # pwm/pwmchip0..3 are present in the USB-recovery initrd without
  # extra module-loading. Each IP instance handles 4 channels.
  PWM = yes;
  PWM_SOPHGO_CV1800 = yes;

  # On-chip audio: I2S/TDM controller + internal RXADC (mic) +
  # internal TXDAC (speaker amp). LicheeRV Nano B-W has the analog
  # mic and ~1 W speaker amp wired straight to those internal blocks
  # — no external i2c codec. simple-audio-card glues them via the
  # nodes added in pkgs/dtb-mainline/sg2002-licheerv-nano-bw.dtsi.
  SOUND = yes;
  SND = yes;
  SND_SOC = yes;
  SND_SOC_GENERIC_DMAENGINE_PCM = yes;
  SND_SOC_CV1800B_TDM = module;
  SND_SOC_CV1800B_ADC_CODEC = module;
  SND_SOC_CV1800B_DAC_CODEC = module;
  SND_SOC_SIMPLE_CARD = module;
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

  # No PCIe, no discrete GPU — kill the DRM stack. Nouveau alone is
  # ~30 .ko files of dead weight. The legacy FB subsystem stays on for
  # ssd1307fb (above); it's independent of DRM.
  DRM = no;
  DRM_NOUVEAU = no;
  DRM_RADEON = no;
  DRM_VIRTIO_GPU = no;
  DRM_AMDGPU = no;
  DRM_I915 = no;

  # No virt here.
  KVM = no;
  VIRTIO = no;
  VIRTIO_PCI = no;
  VIRTIO_BALLOON = no;
  VIRTIO_BLK = no;
  VIRTIO_NET = no;
  XEN = no;
  HYPERV = no;

  # No PCIe on SG2002 — kills NVMe, SCSI, ATA, most of the net vendor
  # spam below.
  PCI = no;
  NVME_CORE = no;
  SCSI = no;
  ATA = no;
  MTD = no; # no raw flash, only SD + USB
  # NO FC/IB/RDMA on defconfig — leaving these as safety belt if a
  # future defconfig ever flips them.
  INFINIBAND = no;
  RDMA = no;
  FUSION = no;
  # No USB host keyboard / mice / touchscreen — gadgets only.
  HID = no;
  INPUT_KEYBOARD = no;
  INPUT_MOUSE = no;
  INPUT_TOUCHSCREEN = no;
  INPUT_JOYSTICK = no;
  INPUT_TABLET = no;
  # No cameras / TV tuners / DVB.
  MEDIA_SUPPORT = no;
  VIDEO_DEV = no;
  DVB_CORE = no;
  # NFC, WWAN, IrDA, legacy PPS. (IIO is wanted on this SoC for the
  # SAR-ADC driver — see SOPHGO_CV1800B_ADC above.)
  NFC = no;
  WWAN = no;
  CAN = no;
  # mainline Bluetooth stack — aic8800 uses aic8800_btlpm, not BT.
  BT = no;

  # Kill the NET_VENDOR_* menu spam. SG2002 has *no* built-in Ethernet;
  # the only NIC that exists is the aic8800 SDIO WiFi handled via an
  # out-of-tree module. Every one of these just expands a Kconfig
  # recursion into driver code we'll never link.
  NET_VENDOR_3COM = no;
  NET_VENDOR_ADAPTEC = no;
  NET_VENDOR_AGERE = no;
  NET_VENDOR_ALACRITECH = no;
  NET_VENDOR_ALLWINNER = no;
  NET_VENDOR_ALTEON = no;
  NET_VENDOR_AMAZON = no;
  NET_VENDOR_AMD = no;
  NET_VENDOR_AQUANTIA = no;
  NET_VENDOR_ARC = no;
  NET_VENDOR_ASIX = no;
  NET_VENDOR_ATHEROS = no;
  NET_VENDOR_BROADCOM = no;
  NET_VENDOR_CADENCE = no;
  NET_VENDOR_CAVIUM = no;
  NET_VENDOR_CHELSIO = no;
  NET_VENDOR_CISCO = no;
  NET_VENDOR_CORTINA = no;
  NET_VENDOR_DAVICOM = no;
  NET_VENDOR_DEC = no;
  NET_VENDOR_DLINK = no;
  NET_VENDOR_EMULEX = no;
  NET_VENDOR_ENGLEDER = no;
  NET_VENDOR_EZCHIP = no;
  NET_VENDOR_FUNGIBLE = no;
  NET_VENDOR_GOOGLE = no;
  NET_VENDOR_HUAWEI = no;
  NET_VENDOR_I825XX = no;
  NET_VENDOR_INTEL = no;
  NET_VENDOR_WANGXUN = no;
  NET_VENDOR_ADI = no;
  NET_VENDOR_LITEX = no;
  NET_VENDOR_MARVELL = no;
  NET_VENDOR_MELLANOX = no;
  NET_VENDOR_MICREL = no;
  NET_VENDOR_MICROCHIP = no;
  NET_VENDOR_MICROSEMI = no;
  NET_VENDOR_MICROSOFT = no;
  NET_VENDOR_MYRI = no;
  NET_VENDOR_NATSEMI = no;
  NET_VENDOR_NETERION = no;
  NET_VENDOR_NETRONOME = no;
  NET_VENDOR_NI = no;
  NET_VENDOR_NVIDIA = no;
  NET_VENDOR_OKI = no;
  NET_VENDOR_PACKET_ENGINES = no;
  NET_VENDOR_PENSANDO = no;
  NET_VENDOR_QLOGIC = no;
  NET_VENDOR_QUALCOMM = no;
  NET_VENDOR_RDC = no;
  NET_VENDOR_REALTEK = no;
  NET_VENDOR_RENESAS = no;
  NET_VENDOR_ROCKER = no;
  NET_VENDOR_SAMSUNG = no;
  NET_VENDOR_SEEQ = no;
  NET_VENDOR_SILAN = no;
  NET_VENDOR_SIS = no;
  NET_VENDOR_SOLARFLARE = no;
  NET_VENDOR_SMSC = no;
  NET_VENDOR_SOCIONEXT = no;
  NET_VENDOR_STMICRO = no;
  NET_VENDOR_SUN = no;
  NET_VENDOR_SYNOPSYS = no;
  NET_VENDOR_TEHUTI = no;
  NET_VENDOR_TI = no;
  NET_VENDOR_VERTEXCOM = no;
  NET_VENDOR_VIA = no;
  NET_VENDOR_WIZNET = no;
  NET_VENDOR_XILINX = no;

  # Foreign RISC-V SoC support. RISC-V defconfig targets everything
  # with a single image — StarFive JH7110, Spacemit K1, SiFive HiFive,
  # Allwinner D1, Microchip Polarfire — each of which pulls pinctrl,
  # clock, reset, PHY, GPIO, watchdog drivers that are useless on
  # Sophgo SG2002. Turning the ARCH_ gates off cascades through
  # olddefconfig and disables all of those.
  ARCH_STARFIVE = no;
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

  # Other USB host controllers — SG2002's only USB is DWC2 OTG; XHCI/
  # EHCI/OHCI only exist for discrete host controllers we don't have.
  # DWC2 dual-role covers both device (our gadget) and host modes.
  USB_XHCI_HCD = no;
  USB_EHCI_HCD = no;
  USB_OHCI_HCD = no;
  USB_CDNS_SUPPORT = no;
  USB_CDNS3 = no;
  USB_MUSB_HDRC = no;

  # Not using any of these on this board.
  NFS_FS = no;
  NFSD = no;
  IP_VS = no;
  SECURITY_APPARMOR = no;
  SECURITY_SELINUX = no;

  # Kill WLAN_VENDOR_* — aic8800 is OOT, upstream stubs are compile
  # weight with no runtime value.
  WLAN_VENDOR_ADMTEK = no;
  WLAN_VENDOR_ATH = no;
  WLAN_VENDOR_ATMEL = no;
  WLAN_VENDOR_BROADCOM = no;
  WLAN_VENDOR_CISCO = no;
  WLAN_VENDOR_INTEL = no;
  WLAN_VENDOR_INTERSIL = no;
  WLAN_VENDOR_MARVELL = no;
  WLAN_VENDOR_MEDIATEK = no;
  WLAN_VENDOR_MICROCHIP = no;
  WLAN_VENDOR_PURELIFI = no;
  WLAN_VENDOR_RALINK = no;
  WLAN_VENDOR_REALTEK = no;
  WLAN_VENDOR_RSI = no;
  WLAN_VENDOR_SILABS = no;
  WLAN_VENDOR_ST = no;
  WLAN_VENDOR_TI = no;
  WLAN_VENDOR_ZYDAS = no;
  WLAN_VENDOR_QUANTENNA = no;
}
