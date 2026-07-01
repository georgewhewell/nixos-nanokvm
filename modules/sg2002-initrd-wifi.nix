# AIC8800 WiFi in the systemd initrd. When this module is imported,
# the aic8800 modules + wpa_supplicant bring up wlan0 before stage-2.
# Requires `sg2002.wifi.enable = true` and, for association,
# `sg2002.wifi.wpaConf`.
#
# Pair this with an initrd boot style (includes/usb-recovery.nix or
# similar). For stage-2 wifi use includes/stage2-wifi.nix instead.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.sg2002;

  kernelPkg = pkgs."sg2002-kernel-${cfg.kernel}";
  aic8800Pkg =
    if cfg.kernel == "vendor"
    then pkgs.sg2002-aic8800-vendor-for kernelPkg
    else pkgs.sg2002-aic8800-mainline-for kernelPkg;
in {
  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = cfg.wifi.enable;
          message = "initrd-wifi.nix requires sg2002.wifi.enable = true.";
        }
      ];

      boot.extraModulePackages = [aic8800Pkg];
      sg2002.initrd.pruneKernelModules = true;
      sg2002.initrd.availableKernelModules = [
        "aic8800_bsp"
        "aic8800_fdrv"
        "aic8800_btlpm"
      ];
      sg2002.initrd.kernelModules = [
        "aic8800_bsp"
        "aic8800_fdrv"
        "aic8800_btlpm"
      ];
      hardware.firmware = [pkgs.sg2002-aic8800-firmware];

      # NixOS's systemd initrd defaults /lib -> modulesClosure/lib
      # (modules only, empty firmware dir). aicbsp opens
      # /lib/firmware/... directly via filp_open — not
      # request_firmware — so the initrd must have those files at
      # the exact /lib/firmware path. Replace /lib with a merged
      # tree that carries both the module tree and our firmware
      # blobs at build time: systemd-modules-load runs before
      # systemd-tmpfiles-setup, so a runtime symlink would be too
      # late.
      boot.initrd.systemd.contents."/lib".source = lib.mkForce (
        pkgs.runCommand "sg2002-initrd-lib" {} ''
          mkdir -p $out
          ln -s ${config.system.build.modulesClosure}/lib/modules $out/modules
          ln -s ${config.hardware.firmware}/lib/firmware $out/firmware
        ''
      );
    }

    (lib.mkIf (cfg.wifi.wpaConf != null) {
      boot.initrd.systemd = {
        contents."/etc/wpa_supplicant.conf".text = cfg.wifi.wpaConf;

        services."wpa_supplicant-wlan0" = {
          description = "wpa_supplicant on wlan0";
          wantedBy = ["initrd.target"];
          after = [
            "systemd-modules-load.service"
            "sys-subsystem-net-devices-wlan0.device"
          ];
          wants = ["sys-subsystem-net-devices-wlan0.device"];
          serviceConfig = {
            ExecStart = "${pkgs.wpa_supplicant}/bin/wpa_supplicant -i wlan0 -c /etc/wpa_supplicant.conf -D nl80211";
            Restart = "on-failure";
            RestartSec = 5;
          };
        };

        storePaths = [
          "${pkgs.wpa_supplicant}/bin/wpa_supplicant"
        ];

        network.networks."40-wlan0" = {
          matchConfig.Name = "wlan0";
          networkConfig.DHCP = "yes";
        };
      };
    })
  ];
}
