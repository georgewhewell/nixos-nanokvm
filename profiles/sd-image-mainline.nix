# Mainline-kernel SD-card image.
#
# Unlike profiles/sd-image.nix (vendor 5.10 + vendor-FIT), this boots
# the mainline kernel via mainline U-Boot + extlinux: U-Boot's
# distro_bootcmd scans the ext4 root partition for
# /boot/extlinux/extlinux.conf and loads kernel + dtb + initrd from
# there. fip.bin (mainline U-Boot) lives on the FAT firmware partition.
#
# Reachability: the NanoKVM-PCIe board module brings up wired Ethernet
# in the initrd and stage 2. The USB gadget keeps only ACM serial in the
# initrd; stage 2 recreates ECM + ACM and lets networkd assign usb0.
{
  config,
  lib,
  pkgs,
  rootAuthorizedKeys ? [],
  ...
}: {
  imports = [
    ../modules/sg2002-sd-image.nix
    ../modules/sg2002-usb-gadget-initrd.nix
  ];

  # Mainline U-Boot + extlinux, NOT the vendor FIT. (platform default
  # is already "mainline"; be explicit so this profile is self-evident.)
  sg2002.uboot = lib.mkForce "mainline";
  sg2002.usbGadget.network.enable = true;
  sg2002.usbGadget.initrd.network.enable = false;
  sg2002.usbGadget.stage2.enable = true;

  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;
  hardware.deviceTree.enable = true;
  # Same single source of truth as the FIT path: wrap config.sg2002.fdt
  # (set by the platform default + WiFi/OLED/ethernet modules) into the
  # dtbs dir extlinux expects, so the SD image and the USB boot-fit
  # always agree on the DTB.
  hardware.deviceTree.name = "sg2002.dtb";
  hardware.deviceTree.package = lib.mkForce (
    pkgs.runCommand "sg2002-fdt-dir" {} ''
      mkdir -p "$out"
      cp ${config.sg2002.fdt} "$out/sg2002.dtb"
    ''
  );

  # Mirror the kernel console onto the USB gadget serial so the router
  # sees boot output on its ttyACM. (sg2002-sd-image.nix already adds
  # console=ttyS0; kernelParams is a merged list.)
  boot.kernelParams = ["console=ttyGS0,115200"];

  # Interactive login over the USB serial console.
  systemd.services."serial-getty@ttyGS0".enable = true;

  sg2002.authorizedKeys = rootAuthorizedKeys;
  networking.hostName = lib.mkDefault "nanokvm";

  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "yes";
    settings.PasswordAuthentication = true;
  };

  users.users.root.initialPassword = "nixos";

  services.nanokvm = {
    enable = false;
    openFirewall = false;
  };
}
