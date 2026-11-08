# Persistent SD image for the PicoClaw LCD owned by the SG2002 C906L.
#
# Linux owns SDIO while the C906L-owned regulator alone switches its GPIOA26
# power rail; see docs/sg2002-c906l-picoclaw-sd-image.md before changing that
# boundary.
{
  lib,
  rootWpaConf ? null,
  ...
}: {
  imports = [
    ./sd-image-mainline.nix
    ../modules/picoclaw-c906l-lcd.nix
    ../modules/sg2002-watchdog-keeper.nix
    ../modules/wifi-aic8800.nix
  ];

  sg2002 = {
    wifi = {
      # An explicitly supplied config is installed here at build time.  With
      # none, wpa_supplicant is conditionally skipped until the administrator
      # provisions this root-only path through the authenticated USB link.
      wpaConf = lib.mkDefault rootWpaConf;
      wpaConfRuntimePath = "/etc/wpa_supplicant/wpa_supplicant-wlan0.conf";
    };

    # Unlike a tethered live image, an SD card must continue to run while USB
    # is unplugged.  The keeper therefore supervises the hardware watchdog
    # without treating loss of the development host as a fault.
    watchdogKeeper = {
      initrd.enable = true;
      stage2.enable = true;
      healthHost = null;
    };

    # Nothing here needs stage 1: Linux reaches the card and the C906L
    # without it, and stage 2 starts the gadget and the watchdog keeper.
    sdImage.initrd.enable = lib.mkDefault false;

    # The Nano's onboard mic and speaker amplifier sit on the internal
    # RXADC/TXDAC. The amplifier has no enable GPIO on this carrier.
    audio.enable = true;

    # Keep the control/regulator transport in stage 1. The optional display
    # probes through udev and may defer until the firmware lease is ready.
    initrd.availableKernelModules = [
      "sg2002-c906l-control"
      "sg2002-c906l-remoteproc"
      "sg2002-c906l-wifi-power"
      "sg2002-c906l-framebuffer"
    ];
    initrd.kernelModules = [
      "sg2002-c906l-control"
      "sg2002-c906l-remoteproc"
      "sg2002-c906l-wifi-power"
    ];
  };

  # Standard fbcon takeover, with UART retained as /dev/console. Stage 2
  # supplies the ordinary authenticated virtual-terminal login.
  boot.kernelParams = lib.mkBefore [
    "console=tty0" "fbcon=nodefer" "fbcon=font:MINI4x6" "consoleblank=0"
  ];
  systemd.targets.getty.wants = [ "getty@tty1.service" ];

  networking.hostName = lib.mkOverride 900 "picoclaw-c906l-lcd";

  # Reproducible standalone/CI image: root / nixos-nanokvm, with no required
  # developer key. Store only the hash; downstream configurations can replace
  # it. Mutable users allow the administrator to change it after first boot.
  services.openssh.settings = {
    PermitRootLogin = "yes";
    PasswordAuthentication = true;
    KbdInteractiveAuthentication = false;
  };
  users.users.root = {
    initialPassword = lib.mkForce null;
    hashedPassword = lib.mkDefault "$6$6KbHgA9r1ooAGY8q$EcuILFYS4.8fMiVYxp9RMRfUizv8sCaPKMxj/NfP/Xf33SE5iyyThesB/4m/D26C2il4DeqEfTqswXa966W5j1";
  };
}
