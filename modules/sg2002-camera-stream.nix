{ config, lib, pkgs, ... }:
let
  cfg = config.services.sg2002-camera;
  bridge = if cfg.detection.enable then pkgs.sg2002-h264-bridge-detection
    else pkgs.sg2002-h264-bridge;
  nodes = [
    "/dev/v4l/by-path/platform-a0c2000.video-capture-video-index0"
    "/dev/v4l/by-path/platform-a080000.vpss-video-index0"
    "/dev/v4l/by-path/platform-b030000.video-codec-video-index0"
  ];
  command = [
    "${bridge}/bin/sg2002-h264-bridge"
    "--isp" "--capture-buffers" "2" "--mid-buffers" "2"
    "--max-fps" (toString cfg.framesPerSecond)
    "--bitrate" (toString cfg.bitrate) "--gop" "30"
    "--rtsp" cfg.rtspUrl
  ] ++ lib.optionals cfg.autoAdjust [ "--auto-camera" "--mains-frequency" (toString cfg.powerLineFrequency) ]
    ++ lib.optionals (cfg.size == "half") [ "--size" "half" ]
    ++ lib.optionals (cfg.rotation == 180) [ "--rotate" "180" ]
    ++ lib.optionals cfg.detection.enable [
      "--detect-model" (toString cfg.detection.model)
      "--detect-fps" (toString cfg.detection.framesPerSecond)
    ];
in {
  options.services.sg2002-camera = {
    enable = lib.mkEnableOption "SG2002 GC4653 camera streaming over RTSP";
    rtspUrl = lib.mkOption {
      type = lib.types.str;
      example = "rtsp://video-server:8554/licheerv";
      description = "RTSP publisher destination, for example a MediaMTX server.";
    };
    size = lib.mkOption {
      type = lib.types.enum [ "quarter" "half" ];
      default = "quarter";
      description = "GC4653 output size: 640x360 or 1280x720.";
    };
    framesPerSecond = lib.mkOption {
      type = lib.types.ints.between 1 60;
      default = 30;
      description = "Maximum video frame rate.";
    };
    autoAdjust = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Adjust GC4653 exposure and ISP white balance from sampled frames.";
    };
    powerLineFrequency = lib.mkOption {
      type = lib.types.enum [ 0 50 60 ];
      default = 50;
      description = "Lighting mains frequency for exposure flicker reduction; 0 disables quantisation.";
    };
    rotation = lib.mkOption {
      type = lib.types.enum [ 0 180 ];
      default = 0;
      description = "Rotate the image in hardware before detection and encoding.";
    };
    bitrate = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2000000;
      description = "H.264 bitrate in bits per second.";
    };
    detection = {
      enable = lib.mkEnableOption "TPU object detection with boxes and labels in the video";
      framesPerSecond = lib.mkOption {
        type = lib.types.ints.between 1 10;
        default = 2;
        description = "Maximum inference rate; video continues between inference results.";
      };
      model = lib.mkOption {
        type = lib.types.path;
        default = "${pkgs.sg2002-tpu-yolov5n}/yolov5n.cvimodel";
        defaultText = lib.literalExpression ''"''${pkgs.sg2002-tpu-yolov5n}/yolov5n.cvimodel"'';
        description = "Trusted YOLOv5 model with 640x640 fused RGB input and three FP32 heads.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      { assertion = config.sg2002.kernel == "mainline";
        message = "services.sg2002-camera requires the SG2002 mainline kernel."; }
      { assertion = lib.hasPrefix "rtsp://" cfg.rtspUrl;
        message = "services.sg2002-camera.rtspUrl must be an rtsp:// publisher URL."; }
    ];
    hardware.firmware = [ pkgs.sg2002-coda980-firmware ];
    boot.kernelModules = [ "gc4653" "sg2002-vpss" "coda-vpu" ];
    systemd.tmpfiles.rules = [ "L+ /lib/firmware - - - - /run/current-system/firmware" ];
    systemd.services.sg2002-camera = {
      description = "GC4653 hardware camera stream${lib.optionalString cfg.detection.enable " with TPU detection"}";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      unitConfig.StartLimitIntervalSec = 0;
      preStart = ''
        for attempt in {1..180}; do
          ready=1
          for node in ${lib.escapeShellArgs (nodes ++ lib.optional cfg.autoAdjust "/dev/v4l-subdev0" ++ lib.optional cfg.detection.enable "/dev/sg2002-tpu")}; do
            [[ -c "$node" ]] || ready=0
          done
          [[ "$ready" == 1 ]] && exit 0
          ${pkgs.coreutils}/bin/sleep 1
        done
        echo "timed out waiting for camera devices" >&2
        exit 1
      '';
      script = "exec ${lib.escapeShellArgs command}";
      serviceConfig = {
        Restart = "always";
        RestartSec = "5s";
        TimeoutStartSec = "210s";
        SupplementaryGroups = [ "video" ];
        DeviceAllow = [
          "char-video4linux rw"
          "/dev/dma_heap/default_cma_region rw"
          "/dev/dma_heap/reserved rw"
        ] ++ lib.optional cfg.detection.enable "/dev/sg2002-tpu rw";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
      };
    };
  };
}
