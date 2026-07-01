# Mainline U-Boot 2026.04 for the Sipeed LicheeRV Nano (sg2002).
# Layered on top of the upstream `sipeed_licheerv_nano_defconfig`:
#   - extraConfig enables USB gadget + fastboot so distro_bootcmd can
#     fall through to "fastboot usb 0" as a recovery channel
#   - 4 local patches (see ./patches/) fix missing ramdisk_addr_r,
#     add an -u-boot.dtsi for the dwc2 gadget, and let the dwc2_udc_otg
#     driver build on RISC-V
{buildUBoot}:
buildUBoot {
  defconfig = "sipeed_licheerv_nano_defconfig";
  extraMeta.platforms = ["riscv64-linux"];
  filesToInstall = ["u-boot.bin" "u-boot.dtb"];

  extraConfig = ''
    CONFIG_USB=y
    CONFIG_DM_USB=y
    CONFIG_DM_USB_GADGET=y
    CONFIG_USB_GADGET=y
    CONFIG_USB_GADGET_MANUFACTURER="Sipeed"
    CONFIG_USB_GADGET_VENDOR_NUM=0x18d1
    CONFIG_USB_GADGET_PRODUCT_NUM=0xd00d
    CONFIG_USB_GADGET_DWC2_OTG=y
    CONFIG_USB_GADGET_DOWNLOAD=y
    CONFIG_FASTBOOT=y
    CONFIG_FASTBOOT_BUF_ADDR=0x82000000
    CONFIG_FASTBOOT_BUF_SIZE=0x4000000
    CONFIG_FASTBOOT_USB_DEV=0
    CONFIG_USB_FUNCTION_FASTBOOT=y
    CONFIG_CMD_FASTBOOT=y
    # `fastboot oem run "<cmd>"` executes arbitrary U-Boot commands and
    # returns output — our only debug channel once UART is unpopulated.
    CONFIG_FASTBOOT_OEM_RUN=y
    # Console ring buffer readable via `fastboot oem console`; captures
    # the pre-fastboot FSBL/OpenSBI/U-Boot output for post-mortem.
    CONFIG_CONSOLE_RECORD=y
    CONFIG_CONSOLE_RECORD_OUT_SIZE=0x2000
    CONFIG_CONSOLE_RECORD_IN_SIZE=0x800
    CONFIG_FASTBOOT_CMD_OEM_CONSOLE=y
    # SG2002/Sipeed SD images need partition 1 marked active for fip.bin,
    # while NixOS extlinux lives on the ext4 root partition. U-Boot's distro
    # scan can stop at the active firmware partition, so try the known NixOS
    # root partition explicitly before falling back to the generic scan and
    # then fastboot.
    CONFIG_BOOTCOMMAND="sysboot mmc 0:2 any 0x80c00000 /boot/extlinux/extlinux.conf; run distro_bootcmd; fastboot usb 0"
    # MMC command-level tracing into the console record; pr_info/pr_debug
    # on the mmc init failure paths only compile in at LOGLEVEL>=7, so
    # without these a failed `mmc dev 0` is completely silent.
    CONFIG_LOGLEVEL=8
    CONFIG_MMC_TRACE=y
  '';

  # buildUBoot's default is `cat extras >> .config`; olddefconfig then
  # resolves Kconfig dependencies for the gadget/fastboot tree.
  postConfigure = "make olddefconfig";

  extraPatches = [
    ./patches/0001-configs-licheerv_nano-define-ramdisk_addr_r-move-fdt.patch
    ./patches/0002-riscv-dts-sg2002-licheerv-nano-b-add-U-Boot-dtsi-wit.patch
    ./patches/0003-usb-gadget-dwc2_udc_otg-treat-ENOENT-as-no-clocks.patch
    ./patches/0004-usb-gadget-dwc2_udc_otg-lift-ARM-only-gate-drop-asm-.patch
    # cv1800b SD won't init under our vendor-FSBL FIP because the upstream
    # MMC driver never programs the cv18xx SD PHY at init (only during
    # tuning). Port the kernel's PHY setup so the card answers ACMD41.
    ./patches/0005-mmc-cv1800b_sdhci-program-cv18xx-sd-phy-at-probe.patch
  ];
}
