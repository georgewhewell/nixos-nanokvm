let
  inherit (import ./compiler.nix)
    pkgs
    compiler
    resources
    python
    ;
  exportReference = name: outputNames: ''
    model_runner.py --input ${name}_in_ori.npz \
      --model ${name}.cvimodel --output reference.npz
    ${python}/bin/python3 - <<'PY'
    import numpy as np
    inputs = np.load('${name}_in_ori.npz')
    outputs = np.load('reference.npz')
    assert len(inputs.files) == 1
    data = inputs[inputs.files[0]]
    assert data.dtype == np.uint8
    data.tofile('input.bin')
    with open('reference.bin', 'wb') as reference:
        for name in ${builtins.toJSON outputNames}:
            assert outputs[name].dtype == np.float32
            outputs[name].astype('<f4').tofile(reference)
    PY
  '';
  mobileNet = pkgs.stdenvNoCC.mkDerivation {
    pname = "sg2002-mobilenet-v2";
    version = "1.11";
    src = resources;
    nativeBuildInputs = [ compiler ];
    dontConfigure = true;
    buildPhase = ''
      runHook preBuild
      mkdir work
      cd work
      model_transform.py \
        --model_name mobilenet_v2 \
        --model_def ../model/mobilenet_v2_deploy.prototxt \
        --model_data ../model/mobilenet_v2.caffemodel \
        --input_shapes '[[1,3,224,224]]' \
        --resize_dims 256,256 \
        --mean 103.94,116.78,123.68 \
        --scale 0.017,0.017,0.017 --pixel_format bgr \
        --test_input ../image/cat.jpg \
        --test_result mobilenet_v2_top_outputs.npz \
        --mlir mobilenet_v2.mlir
      run_calibration.py mobilenet_v2.mlir \
        --dataset ../dataset/ILSVRC2012 --input_num 100 \
        -o mobilenet_v2_cali_table
      model_deploy.py --mlir mobilenet_v2.mlir \
        --chip cv181x --quantize INT8 \
        --calibration_table mobilenet_v2_cali_table \
        --fuse_preprocess --customization_format BGR_PLANAR \
        --test_input ../image/cat.jpg \
        --test_reference mobilenet_v2_top_outputs.npz \
        --tolerance 0.96,0.74 \
        --model mobilenet_v2.cvimodel
      runHook postBuild
    ''
    + exportReference "mobilenet_v2" [ "prob_f32" ];
    installPhase = ''
      mkdir -p $out
      cp mobilenet_v2.cvimodel $out/
      cp input.bin reference.bin $out/
      cp ../image/cat.jpg $out/
    '';
    meta = {
      description = "MobileNet V2 compiled and calibrated for SG2002's CV181x TPU";
      homepage = "https://milkv.io/docs/duo/application-development/tpu/tpu-mobilenetv2";
      license = pkgs.lib.licenses.unfree;
      platforms = [ "x86_64-linux" ];
    };
  };
  yolo = pkgs.stdenvNoCC.mkDerivation {
    pname = "sg2002-yolov5n";
    version = "6.0";
    src = resources;
    model = pkgs.fetchurl {
      url = "https://github.com/ultralytics/yolov5/releases/download/v6.0/yolov5n.onnx";
      hash = "sha256-bGhvXFbF2ofGRFove9LcLWtmQyU2jZ3h/XwFEAueRC4=";
    };
    nativeBuildInputs = [ compiler ];
    dontConfigure = true;
    buildPhase = ''
      runHook preBuild
      mkdir work
      cd work
      model_transform.py --model_name yolov5n --model_def "$model" \
        --input_shapes '[[1,3,640,640]]' \
        --mean 0,0,0 --scale 0.0039216,0.0039216,0.0039216 \
        --keep_aspect_ratio --pixel_format rgb \
        --output_names 326,474,622 \
        --test_input ../image/dog.jpg --test_result yolov5n_top_outputs.npz \
        --mlir yolov5n.mlir
      run_calibration.py yolov5n.mlir \
        --dataset ../dataset/COCO2017 --input_num 100 -o yolov5n_cali_table
      model_deploy.py --mlir yolov5n.mlir \
        --chip cv181x --quantize INT8 --calibration_table yolov5n_cali_table \
        --fuse_preprocess --customization_format RGB_PLANAR \
        --test_input ../image/dog.jpg --test_reference yolov5n_top_outputs.npz \
        --tolerance 0.95,0.68 --model yolov5n.cvimodel
      runHook postBuild
    ''
    + exportReference "yolov5n" [
      "326_Conv_f32"
      "474_Conv_f32"
      "622_Conv_f32"
    ];
    installPhase = ''
      mkdir -p $out
      cp yolov5n.cvimodel $out/
      cp input.bin reference.bin $out/
      cp ../image/dog.jpg $out/
    '';
    meta = {
      description = "YOLOv5n compiled and calibrated for SG2002's CV181x TPU";
      homepage = "https://milkv.io/docs/duo/application-development/tpu/tpu-yolov5";
      license = pkgs.lib.licenses.unfree;
      platforms = [ "x86_64-linux" ];
    };
  };
in
{
  inherit mobileNet yolo;
}
