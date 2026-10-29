{
  lib,
  stdenv,
  pkg-config,
  opencv4,
  libjpeg,
  libpng,
  zlib,
  sophgo-cviruntime,
}:
let
  opencv =
    (opencv4.override {
      enabledModules = [
        "core"
        "imgproc"
        "imgcodecs"
      ];
      runAccuracyTests = false;
      runPerformanceTests = false;
      enableContrib = false;
      enableFfmpeg = false;
      enableGStreamer = false;
      enableTIFF = false;
      enableWebP = false;
      enableJpegXL = false;
      enableEXR = false;
      enableJPEG2000 = false;
      enableEigen = false;
      enableBlas = false;
      enableVA = false;
      enableLto = false;
    }).overrideAttrs
      (old: {
        # These three modules only need the image codecs, not video/GUI/protobuf.
        buildInputs = [
          libjpeg
          libpng
          zlib
        ];
        cmakeFlags = old.cmakeFlags ++ [ "-DWITH_PROTOBUF=OFF" ];
      });
in
stdenv.mkDerivation {
  pname = "sophgo-tpu-examples";
  inherit (sophgo-cviruntime) version src;
  patches = [ ./examples.patch ];
  nativeBuildInputs = [ pkg-config ];
  buildInputs = [
    opencv
    sophgo-cviruntime
  ];
  buildPhase = ''
    runHook preBuild
    $CXX -std=c++17 -O2 samples/classifier_fused_preprocess/classifier_fused_preprocess.cpp \
      $($PKG_CONFIG --cflags --libs opencv4) -lcviruntime -o sg2002-tpu-classify
    $CXX -std=c++17 -O2 samples/samples_extra/detector_yolov5_fused_preprocess/detector_yolov5_fused_preprocess.cpp \
      $($PKG_CONFIG --cflags --libs opencv4) -lcviruntime -o sg2002-tpu-detect
    $CXX -std=c++17 -O2 -Wall -Wextra -Werror -Isamples ${./model-check.cpp} \
      -lcviruntime -o sg2002-tpu-model-check
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 sg2002-tpu-model-check $out/bin/sg2002-tpu-model-check
    install -Dm755 sg2002-tpu-classify $out/bin/sg2002-tpu-classify
    install -Dm755 sg2002-tpu-detect $out/bin/sg2002-tpu-detect
    install -Dm644 samples/data/cat.jpg $out/share/sg2002-tpu-examples/cat.jpg
    install -Dm644 samples/data/synset_words.txt $out/share/sg2002-tpu-examples/synset_words.txt
    install -Dm644 samples/samples_extra/data/dog.jpg $out/share/sg2002-tpu-examples/dog.jpg
    runHook postInstall
  '';
  meta = {
    description = "Source-built Sophgo image classification and YOLOv5 TPU examples";
    homepage = "https://github.com/sophgo/cviruntime/tree/master/samples";
    license = lib.licenses.unfree;
    platforms = [ "riscv64-linux" ];
  };
}
