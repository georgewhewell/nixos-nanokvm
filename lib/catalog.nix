# Reusable RAM-only USB and persistent SD images. Host services stay separate.
{ lib }:
let
  wifi = [
    ../modules/wifi-aic8800.nix
    ../modules/sg2002-initrd-wifi.nix
  ];
  entry = name: boardName: variant: mixins: modules: {
    path = [ name "mainline" "initrd" variant ];
    kernel = "mainline";
    profile = "usb-initrd";
    artifact = "initrd";
    tag = "${name}-${variant}";
    inherit boardName mixins modules;
  };
  sd = name: boardName: pathTail: profile: mixins: modules: {
    path = [ name "mainline" "sd" ] ++ pathTail;
    kernel = "mainline";
    artifact = "sd";
    tag = "${name}-sd";
    inherit boardName profile mixins modules;
  };
in [
  (entry "licheerv" "licheerv-nano-w" "default" wifi [ ])
  (entry "pcie" "nanokvm-pcie" "default" wifi [ ])
  (entry "picoclaw" "licheerv-nano-picoclaw" "default"
    (wifi ++ [ ../modules/picoclaw-c906l-lcd.nix ]) [ ])
  (entry "licheerv" "licheerv-nano-w" "c906l-all-timers" [ ] [
    ({ ... }: {
      sg2002.auxCore = {
        enable = true;
        peripherals = [ "timer4" "timer5" "timer6" "timer7" ];
      };
    })
  ])
  (sd "picoclaw" "licheerv-nano-picoclaw" [ "c906l-lcd" ]
    "sd-image-picoclaw-c906l" [ ] [ ])
  (sd "pcie" "nanokvm-pcie" [ ] "sd-image-mainline" [ ] [ ])
  (sd "cube" "nanokvm-cube" [ ] "sd-image-mainline" [ ] [ ])
  (sd "licheerv" "licheerv-nano-w" [ ] "sd-image-mainline"
    [ ] [ ({ pkgs, ... }: {
      sg2002.fdt = pkgs.sg2002-dtb-mainline-eth;
      systemd.network = {
        enable = true;
        networks."20-eth0" = {
          matchConfig.Name = "eth0";
          networkConfig = { DHCP = "yes"; IPv6AcceptRA = true; };
          linkConfig.RequiredForOnline = "no";
        };
      };
    }) ])
]
