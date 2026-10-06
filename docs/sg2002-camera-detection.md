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
metadata, scales it with bilinear sampling and adds black letterboxing. Samples
are copied before overlays are drawn, preventing feedback into the detector.
CPU accesses to the shared DMA-BUF are bracketed by `DMA_BUF_IOCTL_SYNC` while
the buffer is owned by the application between VPSS completion and encoder QBUF.
The video scaler and encoder remain hardware paths. CPU conversion is only for
sampled model inputs; CPU drawing only touches the overlay regions.

YOLOv5 confidence/NMS defaults are 0.25/0.45. Scores are shown because a visible
box is not an accuracy guarantee. Inference failures fail the publisher rather
than leaving stale boxes or silently substituting CPU inference.

The default two-inference-per-second cap is a starting point, not a measured
camera throughput guarantee. The standalone model previously took about 194 ms
per forward call, including considerable CPU output-conversion work. Live
camera/TPU contention, CPU use, memory use and sustained frame rate still need
hardware validation.

Host tests run under AddressSanitizer and UndefinedBehaviorSanitizer. They check
NV12 colour/range conversion, letterboxing, padded chroma offsets and stride
guards, confidence/NMS, sampling before overlay, busy-snapshot ownership, stale
results and failure-state handling. These do not substitute for a camera
test. No live camera acceptance result has been recorded for this change yet.
