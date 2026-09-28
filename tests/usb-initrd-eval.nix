{ pkgs, lib, configs, overriddenKernelConfig }:
let
  overriddenKernelWifi = builtins.filter
    (p: lib.hasPrefix "aic8800-" (lib.getName p))
    overriddenKernelConfig.boot.extraModulePackages;
  check = config:
    let
      stage1 = config.boot.initrd;
      net = stage1.systemd.network.networks."10-all-links";
      services = stage1.systemd.services;
      lcd = builtins.elem "picoclawLcd" config.sg2002.auxCore.peripherals;
      consoles = builtins.filter (lib.hasPrefix "console=") config.boot.kernelParams;
      uploader = pkgs.sg2002-usb-boot-for config.system.build.fipFastboot;
    in
    assert lib.all (a: a.assertion) config.assertions;
    # Force native launcher evaluation for both plain and C906L FIPs; bundle
    # builds copy the runner source and do not exercise this package factory.
    assert builtins.isString uploader.drvPath;
    assert (uploader.c906lContract != null) == config.sg2002.auxCore.enable;
    assert stage1.systemd.enable;
    assert config.nixpkgs.hostPlatform.gcc.tune == "thead-c906";
    assert stage1.systemd.root == null;
    assert stage1.network.ssh.enable;
    assert !stage1.systemd.emergencyAccess;
    assert stage1.network.ssh.authorizedKeys != [ ];
    assert stage1.network.ssh.hostKeys == [ ];
    assert !services.initrd-switch-root.enable;
    assert !services.initrd-cleanup.enable;
    assert !stage1.systemd.targets.initrd-switch-root.enable;
    assert !builtins.hasAttr "usb-debug-shell" services;
    assert !builtins.hasAttr "nanokvm-root-nbd" services;
    assert !builtins.hasAttr "nanokvm-nfs-store" services;
    assert !builtins.hasAttr "kexec" stage1.systemd.sockets;
    assert !stage1.systemd.network.wait-online.enable;
    assert net.networkConfig.DHCP == "yes";
    assert net.networkConfig.LinkLocalAddressing == "yes";
    assert net.matchConfig.Name == [ "eth*" "en*" "wl*" "usb*" ];
    assert stage1.services.resolved.enable;
    assert config.sg2002.watchdogKeeper.initrd.enable;
    assert builtins.elem "watchdog.stop_on_reboot=0" config.boot.kernelParams;
    assert config.sg2002.watchdogKeeper.healthHost == null;
    assert config.sg2002.wifi.enable ->
      services.wpa_supplicant-wlan0.wantedBy
        == [ "sys-subsystem-net-devices-wlan0.device" ]
      && services.wpa_supplicant-wlan0.wants == [ ];
    assert config.sg2002.wifi.enable ->
      builtins.elem "wpa_supplicant/client"
        services.wpa_supplicant-wlan0.serviceConfig.RuntimeDirectory;
    assert config.sg2002.wifi.enable -> config.hardware.wirelessRegulatoryDatabase;
    assert config.sg2002.wifi.enable ->
      builtins.elem "sha256" config.sg2002.initrd.availableKernelModules;
    assert (config.sg2002.wifi.enable && config.sg2002.wifi.wpaConf == null
      && config.sg2002.wifi.wpaConfRuntimePath != null) ->
      services.wpa_supplicant-wlan0.unitConfig.ConditionPathExists
        == config.sg2002.wifi.wpaConfRuntimePath;
    assert !config.sg2002.watchdogKeeper.stage2.enable;
    assert !config.sg2002.usbGadget.stage2.enable;
    assert builtins.elem "console=tty0" consoles == lcd;
    assert lib.last consoles == "console=${if config.sg2002.uart1Rescue.enable then "ttyS1" else "ttyS0"},115200";
    assert !lib.any (p: lib.hasPrefix "init=" p || lib.hasPrefix "root=" p) config.boot.kernelParams;
    assert stage1.systemd.extraBin ? aplay;
    assert stage1.systemd.extraBin ? arecord;
    assert stage1.systemd.extraBin.systemd-analyze == "${stage1.systemd.package}/bin/systemd-analyze";
    true;
in
assert lib.all check configs;
assert builtins.length overriddenKernelWifi == 1;
assert lib.hasInfix (builtins.unsafeDiscardStringContext
  (toString overriddenKernelConfig.boot.kernelPackages.kernel.dev))
  (builtins.head overriddenKernelWifi).preBuild;
pkgs.runCommand "sg2002-initrd-eval" { } ''
  touch "$out"
''
