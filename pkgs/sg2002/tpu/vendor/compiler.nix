let
  # The vendor compiler's native Python modules require CPython 3.10.
  pkgs =
    import
      (builtins.fetchTarball {
        url = "https://github.com/NixOS/nixpkgs/archive/70bdadeb94ffc8806c0570eb5c2695ad29f0e421.tar.gz";
        sha256 = "05cbl1k193c9la9xhlz4y6y8ijpb2mkaqrab30zij6z4kqgclsrd";
      })
      {
        system = "x86_64-linux";
        config.allowUnfreePredicate =
          pkg:
          builtins.elem (pkgs.lib.getName pkg) [
            "sg2002-mobilenet-v2"
            "sg2002-yolov5n"
          ];
      };
  inherit (pkgs) lib;
  onnxsim = pkgs.python310Packages.buildPythonPackage {
    pname = "onnxsim";
    version = "0.4.17";
    format = "wheel";
    src = pkgs.fetchurl {
      url = "https://files.pythonhosted.org/packages/94/cc/4d746164cb7c3596c0f5d4df50437f1f854cb503928dc0a2fe9974987874/onnxsim-0.4.17-cp310-cp310-manylinux_2_17_x86_64.manylinux2014_x86_64.whl";
      sha256 = "7bdb1a5445131b2cfe8a251755e8612a05b4833a345dbe8b3559484bc6b8ed4e";
    };
    nativeBuildInputs = [ pkgs.autoPatchelfHook ];
    buildInputs = [
      pkgs.stdenv.cc.cc
      pkgs.zlib
    ];
    propagatedBuildInputs = with pkgs.python310Packages; [
      onnx
      onnxruntime
      rich
    ];
    pythonImportsCheck = [ "onnxsim" ];
  };
  python = pkgs.python310.withPackages (
    p: with p; [
      numpy
      scipy
      pillow
      tqdm
      plotly
      opencv4
      protobuf
      graphviz
      scikit-image
      pandas
      torch
      six
      onnx
      onnxruntime
      onnxsim
      flatbuffers
    ]
  );
  compiler = pkgs.stdenvNoCC.mkDerivation {
    pname = "sophgo-tpu-mlir-cv181x";
    version = "1.11";
    src = pkgs.fetchurl {
      url = "https://github.com/sophgo/tpu-mlir/releases/download/v1.11/tpu_mlir-1.11-py3-none-any.whl";
      hash = "sha256-AwR3Ts+kGV79hd3cdpwoQ+L5b/BVfX0vUNY4ERHeDmI=";
    };
    nativeBuildInputs = [
      pkgs.unzip
      pkgs.patchelf
      pkgs.makeWrapper
    ];
    dontUnpack = true;
    dontConfigure = true;
    dontBuild = true;
    dontStrip = true;
    installPhase = ''
      runHook preInstall
      mkdir -p $out/libexec $out/bin
      unzip -q "$src" 'tpu_mlir/*' -d $out/libexec
      root=$out/libexec/tpu_mlir
      # Use Nix's interpreter and C runtime throughout the host compiler.
      rm -f "$root"/lib/third_party/lib{c,m,pthread,rt,dl,stdc++,gcc_s,gomp}.so.* \
        "$root"/lib/third_party/ld-linux* "$root"/lib/third_party/libpython3.10.so*
      chmod -R u+w "$root"
      chmod +x "$root"/bin/* "$root"/python/tools/*.py
      while IFS= read -r -d "" candidate; do
        if patchelf --print-rpath "$candidate" >/dev/null 2>&1; then
          patchelf --add-rpath '${
            lib.makeLibraryPath [
              pkgs.stdenv.cc.cc
              pkgs.glibc
              pkgs.expat
              pkgs.ncurses
              pkgs.zlib
              pkgs.python310
            ]
          }' "$candidate"
          if patchelf --print-interpreter "$candidate" >/dev/null 2>&1; then
            patchelf --set-interpreter '${pkgs.stdenv.cc.bintools.dynamicLinker}' "$candidate"
          fi
        fi
      done < <(find "$root" -type f -print0)
      # The binary compiler embeds wall-clock time in each model header.
      # Freeze only its realtime clock; elapsed-time measurements stay real.
      makeWrapper "$root/bin/tpuc-opt" "$out/bin/tpuc-opt" \
        --set FAKETIME '2024-09-27 00:00:00' \
        --set FAKETIME_DONT_FAKE_MONOTONIC 1 \
        --prefix LD_PRELOAD : '${pkgs.libfaketime}/lib/libfaketime.so.1'
      for tool in model_transform model_deploy run_calibration model_runner npz_tool; do
        makeWrapper ${python}/bin/python3 "$out/bin/$tool.py" \
          --add-flags "$root/python/tools/$tool.py" \
          --set TPUC_ROOT "$root" \
          --set PYTHONPATH "$root/python" \
          --set PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION python \
          --set OMP_NUM_THREADS 4 \
          --prefix PATH : "$out/bin:$root/bin:${python}/bin" \
          --prefix LD_LIBRARY_PATH : "$root/lib:${
            lib.makeLibraryPath [
              pkgs.expat
              pkgs.ncurses
              pkgs.stdenv.cc.cc
              pkgs.python310
            ]
          }"
      done
      mkdir -p $out/share/licenses/sophgo-tpu-mlir
      unzip -p "$src" 'tpu_mlir-1.11.dist-info/LICENSE' \
        > $out/share/licenses/sophgo-tpu-mlir/LICENSE
      runHook postInstall
    '';
    meta = {
      description = "Pinned Sophgo CV181x model compiler";
      homepage = "https://github.com/sophgo/tpu-mlir";
      license = lib.licenses.bsd2;
      platforms = [ "x86_64-linux" ];
    };
  };
  resources = pkgs.fetchurl {
    url = "https://github.com/sophgo/tpu-mlir/releases/download/v1.11/tpu-mlir-resource.tar";
    hash = "sha256-7kooy6oV8trvd8kKaZSEAKKvM+rpWrQnU8rFV9AVrTk=";
  };
in
{
  inherit
    compiler
    python
    resources
    pkgs
    ;
}
