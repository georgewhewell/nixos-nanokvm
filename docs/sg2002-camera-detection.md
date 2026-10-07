# Camera streaming and object detection

The optional detector samples NV12 frames from the hardware camera/VPSS path,
runs YOLOv5n on the TPU, and draws boxes, COCO labels and confidence scores into
the buffer before Coda encodes it. RTSP clients receive ordinary H.264 with the
overlay already present.

Import `nixosModules.sg2002CameraStream` alongside the board module and select
the camera device tree:

```nix
{ pkgs, ... }: {
  sg2002.fdt = pkgs.sg2002-dtb-mainline-cam;
  services.sg2002-camera = {
    enable = true;
    rtspUrl = "rtsp://video-server:8554/licheerv";
    framesPerSecond = 30;
    rotation = 180; # For an upside-down mounting; default is 0.
    detection.enable = true;
    detection.framesPerSecond = 2;
  };
}
```

The module replaces a hand-written camera publisher service; do not run two
publishers against the same capture node. The service needs root's
`CAP_SYS_RAWIO` for the TPU and grants its device access explicitly. Models are
trusted code for this accelerator, as described in [the TPU documentation](sg2002-tpu.md).

For a manual run on a compatible camera image:

```sh
nix build .#sg2002-h264-bridge-detection -o result-bridge
nix build .#sg2002-tpu-yolov5n -o result-model
# On the board, after copying both closures:
sudo ./result-bridge/bin/sg2002-h264-bridge \
  --isp --auto-camera --capture-buffers 2 --mid-buffers 2 --max-fps 30 \
  --detect-model ./result-model/yolov5n.cvimodel --detect-fps 2 \
  --rtsp rtsp://video-server:8554/licheerv
```

Detection runs in one worker with one owned snapshot, without retaining camera
or encoder buffers. While that worker is busy, new inference samples are skipped.
The capture thread draws the latest completed result; boxes expire after one
second (two seconds at a requested inference rate of 1 fps). Boxes describe a
recent sampled frame, not a tracked object position in every video frame.

The worker converts the sample using its V4L2 BT.601/BT.709 and full/limited-range
metadata, scales it with bilinear sampling and adds black letterboxing. A lookup
table maps linear/Rec.709 RGB to the model's sRGB input; sRGB input is unchanged. Samples
are copied before overlays are drawn, preventing feedback into the detector.
CPU accesses to the shared DMA-BUF are bracketed by `DMA_BUF_IOCTL_SYNC` while
the buffer is owned by the application between VPSS completion and encoder QBUF.
The video scaler and encoder remain hardware paths. CPU conversion is only for
sampled model inputs; CPU drawing only touches the overlay regions.

YOLOv5 confidence/NMS defaults are 0.25/0.45. Scores are shown because a visible
box is not an accuracy guarantee. Inference failures fail the publisher rather
than leaving stale boxes or silently substituting CPU inference.

The camera module enables automatic exposure and white balance by default.
The bridge meters a 32×24 grid from the clean VPSS output five times per second,
undoes the sRGB transfer for its calculations, and controls GC4653 shutter/gain
and the ISP's standard V4L2 red/blue balance controls. It does not copy or convert
the entire video frame for metering. Exposure stays within the configured frame
interval; a very dark scene reaches the gain limit rather than slowing the video.

`powerLineFrequency` defaults to 50 Hz; use 60 for 60 Hz lighting, or 0 to disable
shutter quantisation. Long exposures use complete lighting periods, with gain
covering the gaps between shutter steps. `autoAdjust = false` leaves sensor and
white-balance controls available for manual adjustment. Do not run another
exposure controller against the same devices while automatic adjustment is on.

The kernel removes the GC4653's fixed black pedestal in the BE ISP stage, applies
adjustable white balance and a hardware sRGB gamma table, then converts to
full-range BT.601 NV21. VPSS scales/rotates it into NV12. Coda now writes the
negotiated range, transfer and colour matrix into the H.264 SPS, so players do
not have to guess the colour interpretation. The Coda980 firmware uses a
different bitrate register from Coda960; programming that register enables
its CBR mode instead of silently encoding at a fixed quantiser. Firmware CBR
currently undershoots the requested target: the tested 720p scene produced
0.61 Mbit/s at a 2 Mbit/s setting, and 2.23 Mbit/s at 8 Mbit/s. Do not treat the
setting as an exact achieved rate.

This is a basic automatic camera pipeline, not the vendor's complete calibrated
image-quality stack. Black-level correction uses the fixed 256/4096 calibration;
the vendor's gain-dependent calibration differs slightly at high gain. White
balance needs sufficiently neutral pixels and holds its gains when none are
available. Lens-shading correction, a calibrated colour matrix, noise reduction,
HDR and sharpening remain disabled. The GC4653 module has a manually adjustable
lens and no supported autofocus actuator; exposure and gamma cannot correct
optical blur.

Hardware validation on the GC4653 board connected to strix-4 (2026-10-07):

- With AE/AWB and a 2 Hz detection limit (measured 1.94 samples/s), a 60-second 1280x720 RTSP
  recording decoded 1,755 frames without errors. The running publisher reported
  about 29.6 fps; service CPU averaged 65.1%, RSS stayed at 20,244 KiB, and there
  were no restarts. A separate 30-second test at the higher bitrate decoded
  868 frames without errors.
- The final 640x360 smoke test encoded and decoded 300 live frames plus
  the priming picture, with full-range sRGB tags and no decode errors.
- Before correcting rate control, the same 720p scene produced 26.7 Mbit/s,
  decoded only 1,221 frames in 60 seconds and consumed 91% CPU.
- At minimum shutter and 1× gain, encoded black luma measured 0–2 (mean
  0.047/255), compared with a solid 73 when correction was in the FE stage.
- Controlled bright/dim steps using the living-room lights exercised automatic
  gain changes without extending the 30 fps sensor frame interval. The original
  lamp settings and Adaptive Lighting control were restored after testing.
- The live image is visibly brighter and has corrected blacks, but remains
  soft. The model sometimes labels most of this scene as a person at low
  confidence; reliable live recognition is still unverified.
- An injected NV12 fixture of the vendor dog/bicycle/car photo exercised the
  actual TPU, overlay writes and Coda encoder. Decoded boxes showed dog 0.70,
  bicycle 0.48 and car 0.55. This establishes pipeline operation, not live-scene
  detection accuracy.
- A 640x360 fixture in a 640x368 surface verified exact luma reversal for all
  four VPSS flip modes and untouched padding. Uniform Y/U/V values were exact;
  image chroma differed slightly from a software flip (maximum 10 code values,
  mean absolute difference below 0.085), without a plane swap.
- Repeated stop/start and the service's device restrictions worked. The existing
  ISP partial-frame reset message still appears during streamoff.

Host tests run under AddressSanitizer and UndefinedBehaviorSanitizer. They check
AE/AWB convergence and bounds, neutral-sample rejection, metering of padded DMA
surfaces, gamma LUT programming, black-level/WB registers, NV12 colour conversion,
letterboxing, confidence/NMS, sampling before overlays, snapshot ownership and
stale/failing inference handling.
