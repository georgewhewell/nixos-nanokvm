# WiFi hardware mixin for the AIC8800 SDIO chip used on both the
# LicheeRV-Nano-W dev board and the NanoKVM-PCIe carrier.
#
# Importing this module enables the driver and firmware. Association is
# deliberately left to the consuming config: use normal NixOS
# `networking.wireless`, or set `sg2002.wifi.wpaConf` when a standalone
# image really needs a baked wpa_supplicant.conf.
{
  config,
  lib,
  pkgs,
  ...
}: let
  manageStage2 = config.sg2002.wifi.wpaConf != null && !config.networking.wireless.enable;
in {
  # The actual driver/firmware are pulled in by the upstream sg2002
  # module — we just opt-in here.
  sg2002.wifi.enable = true;

  # On mainline, WiFi needs SDIO1 wired (the WiFi-variant DTB). The
  # vendor DTS already enables it, so only override there. A carrier
  # board with its own combined DTB (PCIe = ethernet+WiFi) wins over
  # this via a higher-priority definition.
  sg2002.fdt = lib.mkIf (config.sg2002.kernel == "mainline") (
    lib.mkDefault pkgs.sg2002-dtb-mainline
  );

  # Stage-2 wpa_supplicant on wlan0. sg2002-initrd-wifi.nix only runs the
  # supplicant in the initrd (before switch-root); a persistent / SD boot
  # that goes straight to stage 2 needs it here too, or wlan0 never
  # associates. Gated on a wpa config being present.
  environment.etc = lib.mkIf manageStage2 {
    "wpa_supplicant/wpa_supplicant-wlan0.conf".text = config.sg2002.wifi.wpaConf;
  };
  systemd.services.wpa_supplicant-wlan0 = lib.mkIf manageStage2 {
    description = "wpa_supplicant on wlan0 (stage 2)";
    wantedBy = [ "multi-user.target" ];
    after = [ "sys-subsystem-net-devices-wlan0.device" ];
    wants = [ "sys-subsystem-net-devices-wlan0.device" ];
    serviceConfig = {
      ExecStart = "${pkgs.wpa_supplicant}/bin/wpa_supplicant -i wlan0 -c /etc/wpa_supplicant/wpa_supplicant-wlan0.conf -D nl80211";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
  systemd.network = lib.mkIf manageStage2 {
    enable = true;
    networks."40-wlan0" = {
      matchConfig.Name = "wlan0";
      networkConfig.DHCP = "yes";
      linkConfig.RequiredForOnline = "no";
    };
  };
}
