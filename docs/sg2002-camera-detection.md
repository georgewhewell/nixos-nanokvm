# Camera object detection

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
  --isp --capture-buffers 2 --mid-buffers 2 --max-fps 30 \
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

Hardware validation on the GC4653 board connected to strix-4 (2026-10-07):

- A 180-second RTSP recording contained 5,329 decodable 640x360 frames
  (29.6 fps), with no strict FFmpeg decode errors or service restarts.
- The TPU completed 358 samples in 181.3 seconds (1.98/s). Preprocessing,
  inference and postprocessing averaged about 326 ms per sample. Service CPU
  was 60% of the single core; process RSS stayed at 18,780 KiB. Approximately
  37 MiB remained available on the RAM-booted system.
- A separate 1280x720 test completed 300 live frames plus the priming picture,
  all decoded successfully, at 29.4–29.8 fps. This was a short smoke test.
- An injected NV12 fixture of the vendor dog/bicycle/car photo exercised the
  actual TPU, overlay writes and Coda encoder. The decoded output showed dog
  0.70, bicycle 0.48 and car 0.55 with correctly positioned boxes and labels.
  This is a controlled pipeline test, not a live-scene accuracy result.
- Repeated stop/start and the service's device restrictions worked. The
  existing ISP partial-frame reset message still appears during streamoff.

The polling fix avoids waiting on an empty VPSS queue, which returns POLLERR
immediately. Camera-only process CPU fell from 55% to 4% at approximately
30 fps. Detection remains substantial CPU work despite TPU acceleration,
including input conversion and the runtime's output conversion.

The fixed ISP does not implement automatic exposure or white balance. The
current live scene is dim, and live object accuracy still needs a suitable
scene. The fixture results do not remove that limitation.

Host tests run under AddressSanitizer and UndefinedBehaviorSanitizer. They check
NV12 colour/range/transfer conversion, letterboxing, padded chroma offsets and
stride guards, confidence/NMS, sampling before overlay, busy-snapshot ownership,
stale results and failure-state handling.
