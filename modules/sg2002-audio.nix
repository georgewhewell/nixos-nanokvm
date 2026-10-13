# Opt-in onboard audio for the common SG2002 Nano carrier device tree.
#
# The DTB already supplies an I2S0 -> RXADC capture link and an I2S3 -> TXDAC
# playback link as the `sg2002-onboard` simple card.  This module only selects
# the deliberately tiny in-kernel ALSA support needed to expose those links;
# PipeWire is a further, independent option so headless capture users do not
# inherit an audio daemon.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.sg2002.audio;
  # nixpkgs' normal PipeWire is deliberately a feature-complete desktop
  # build.  Its optional video, X11, discovery and compatibility modules drag
  # an unsuitable dependency graph onto a 256 MiB target even when disabled
  # in NixOS configuration.  Keep only native ALSA, BlueZ and the PipeWire
  # command-line/RTP path.  SBC is the one mandatory A2DP codec.
  minimalPipewire = (pkgs.pipewire.override {
    vulkanSupport = false;
    x11Support = false;
    zeroconfSupport = false;
    raopSupport = false;
    rocSupport = false;
    ffadoSupport = false;
  }).overrideAttrs (old: {
    # The upstream package declares documentation, installed-tests and JACK
    # compatibility outputs.  This profile deliberately does not build them.
    outputs = lib.filter (output: builtins.elem output [ "out" "dev" ]) old.outputs;
    separateDebugInfo = false;
    doCheck = false;
    doInstallCheck = false;
    buildInputs = lib.filter (p: !(builtins.elem (p.pname or "") [
      "ffmpeg-headless"
      "fftw"
      "gstreamer"
      "gst-plugins-base"
      "libebur128"
      "libjack2"
      "libmysofa"
      "libopus"
      "libpulseaudio"
      "libusb1"
      "lilv"
      "libfreeaptx"
      "liblc3"
      "fdk-aac"
      "spandsp"
      "libcamera"
      "libselinux"
      "modemmanager"
    ])) old.buildInputs;
    mesonFlags = old.mesonFlags ++ [
      "-Ddocs=disabled"
      "-Dman=disabled"
      "-Dexamples=disabled"
      "-Dtests=disabled"
      "-Dinstalled_tests=disabled"
      "-Dpipewire-alsa=disabled"
      "-Dpipewire-jack=disabled"
      "-Djack=disabled"
      "-Dpipewire-v4l2=disabled"
      "-Decho-cancel-webrtc=disabled"
      "-Dlibcamera=disabled"
      "-Dlibffado=disabled"
      "-Droc=disabled"
      "-Dlibpulse=disabled"
      "-Davahi=disabled"
      "-Dgstreamer=disabled"
      "-Dgstreamer-device-provider=disabled"
      "-Davb=disabled"
      "-Dv4l2=disabled"
      "-Dffmpeg=disabled"
      "-Dpw-cat-ffmpeg=disabled"
      "-Dbluez5-backend-native-mm=disabled"
      "-Dbluez5-backend-ofono=disabled"
      "-Dbluez5-backend-hsphfpd=disabled"
      "-Dbluez5-codec-aptx=disabled"
      "-Dbluez5-codec-aac=disabled"
      "-Dbluez5-codec-lc3=disabled"
      "-Dbluez5-codec-ldac=disabled"
      "-Dbluez5-codec-ldac-dec=disabled"
      "-Dbluez5-codec-opus=disabled"
      "-Dbluez5-codec-g722=disabled"
      "-Dbluez5-plc-spandsp=disabled"
      "-Dopus=disabled"
      "-Dlibmysofa=disabled"
      "-Dlv2=disabled"
      "-Debur128=disabled"
      "-Dlibusb=disabled"
      "-Dreadline=disabled"
      "-Dgsettings=disabled"
      "-Dgsettings-pulse-schema=disabled"
      "-Dflatpak=disabled"
      "-Daudiotestsrc=disabled"
      "-Dvideoconvert=disabled"
      "-Dvideotestsrc=disabled"
      "-Dselinux=disabled"
      "-Dcompress-offload=disabled"
    ];
  });
  minimalWireplumber = (pkgs.wireplumber.override {
    pipewire = minimalPipewire;
    enableDocs = false;
  }).overrideAttrs (_old: {
    separateDebugInfo = false;
  });
in {
  options.sg2002.audio = {
    enable = lib.mkEnableOption "ALSA tools for the SG2002 onboard RXADC/TXDAC card (the mainline kernel always includes it)";

    pipewire.enable = lib.mkEnableOption "a minimal system-wide PipeWire and WirePlumber audio service";

    package = lib.mkOption {
      type = lib.types.package;
      # Direct hw: ALSA access only. The desktop wrapper adds PulseAudio,
      # PipeWire and codec plugins (ffmpeg among them) to every executable's
      # runtime closure.
      default = (pkgs.alsa-utils.override { withPipewireLib = false; }).overrideAttrs (_: {
        postFixup = "";
      });
      defaultText = lib.literalMD "`alsa-utils` without its plugin wrapper";
      description = "aplay, arecord and amixer for the onboard card.";
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = !cfg.pipewire.enable || cfg.enable;
          message = "sg2002.audio.pipewire.enable requires sg2002.audio.enable.";
        }
        {
          assertion = !cfg.enable || config.sg2002.kernel == "mainline";
          message = "sg2002.audio.enable currently requires sg2002.kernel = \"mainline\".";
        }
      ];
    }

    (lib.mkIf cfg.enable {
      environment.systemPackages = [ cfg.package ];
    })

    (lib.mkIf cfg.pipewire.enable {
      # A system unit is intentional here: this target has no permanent login
      # session, and user-unit operation would require lingering a user manager
      # merely to own the ALSA devices.  The stock NixOS system-wide units run
      # as the dedicated pipewire user, own /run/pipewire, and let WirePlumber
      # use the system D-Bus for BlueZ.  Keep every desktop compatibility layer
      # off: ALSA device discovery is WirePlumber's native monitor.
      services.pipewire = {
        # Headless profiles deliberately force the desktop default off; an
        # explicit SG2002 audio opt-in is the narrow exception.
        enable = lib.mkForce true;
        systemWide = lib.mkForce true;
        package = minimalPipewire;
        audio.enable = true;
        alsa.enable = false;
        jack.enable = false;
        pulse.enable = false;
        wireplumber = {
          enable = true;
          package = minimalWireplumber;
          extraConfig."10-sg2002-bluez" = {
            # The generic ACP policy prefers the output-only fallback profile
            # (priority 5100).  This simple-card has independent DAC and ADC
            # PCMs, so select its `pro-audio` profile explicitly and expose
            # both at every boot without a desktop UCM database.
            "monitor.alsa.rules" = [
              {
                matches = [
                  { "device.name" = "alsa_card.platform-sound"; }
                ];
                actions."update-props"."device.profile" = "pro-audio";
              }
            ];
            "monitor.bluez.properties" = {
              # SBC is mandatory A2DP and avoids optional AAC/LDAC codec
              # closures.  A2DP source carries board mic media to a receiver;
              # HFP/HSP exposes telephony roles, but requires a controlled
              # peer for interoperability proof.
              "bluez5.roles" = [ "a2dp_sink" "a2dp_source" "hsp_hs" "hsp_ag" "hfp_hf" "hfp_ag" ];
              "bluez5.codecs" = [ "sbc" ];
              "bluez5.hfphsp-backend" = "native";
            };
          };
        };
      };

      # The upstream system-wide package units are socket-activated by
      # default.  That is fine for desktop clients, but leaves a headless
      # board with neither the ALSA monitor nor BlueZ endpoints registered
      # until an arbitrary client happens to connect.  Start the native
      # server at multi-user boot; WirePlumber is already wanted by it.
      systemd.services.pipewire.wantedBy = [ "multi-user.target" ];

      # Start BlueZ at multi-user boot as well as from the AIC HCI uevent.
      # Then make the session manager wait for it, so WirePlumber registers
      # audio endpoints against a running system BlueZ service rather than a
      # transient absent system bus. PipeWire itself stays independent.
      systemd.services.bluetooth.wantedBy = [ "multi-user.target" ];
      systemd.services.wireplumber = {
        after = [ "bluetooth.service" ];
        wants = [ "bluetooth.service" ];
      };
    })
  ];
}
