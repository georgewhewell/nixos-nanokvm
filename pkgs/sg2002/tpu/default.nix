{
  lib,
  stdenv,
  sophgo-cvikernel,
}:
stdenv.mkDerivation {
  pname = "sg2002-tpu";
  version = "0.1";
  src = ./.;
  buildInputs = [ sophgo-cvikernel ];
  buildPhase = ''
    runHook preBuild
    $CC -std=gnu11 -O2 -Wall -Wextra -Werror -fPIC -Iinclude \
      -c src/runtime.c -o runtime.o
    $AR rcs libsg2002-tpu.a runtime.o
    $CC -shared -Wl,-soname,libsg2002-tpu.so.0 runtime.o -o libsg2002-tpu.so.0
    $CC -std=gnu11 -O2 -Wall -Wextra -Werror -Iinclude src/demo.c \
      libsg2002-tpu.a -lcvikernel -o sg2002-tpu-demo
    $CC -std=gnu11 -O2 -Wall -Wextra -Werror -Iinclude tests/timeout.c \
      libsg2002-tpu.a -o sg2002-tpu-timeout-test
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 sg2002-tpu-demo $out/bin/sg2002-tpu-demo
    install -Dm755 sg2002-tpu-timeout-test $out/libexec/sg2002-tpu-timeout-test
    install -Dm755 libsg2002-tpu.so.0 $out/lib/libsg2002-tpu.so.0
    ln -s libsg2002-tpu.so.0 $out/lib/libsg2002-tpu.so
    install -Dm644 libsg2002-tpu.a $out/lib/libsg2002-tpu.a
    install -Dm644 include/sg2002-tpu-runtime.h $out/include/sg2002-tpu-runtime.h
    install -Dm644 include/sg2002_tpu.h $out/include/sg2002_tpu.h
    install -Dm644 src/demo.c $out/share/doc/sg2002-tpu/demo.c
    mkdir -p $out/lib/pkgconfig
    cat > $out/lib/pkgconfig/sg2002-tpu.pc <<PC
    prefix=$out
    Name: sg2002-tpu
    Description: SG2002 TPU command submission
    Version: 0.1
    Libs: -L$out/lib -lsg2002-tpu
    Cflags: -I$out/include
    PC
    runHook postInstall
  '';
  meta = {
    description = "SG2002 TPU runtime and hardware-checked INT8 matrix demo";
    license = lib.licenses.mit;
    platforms = [ "riscv64-linux" ];
    mainProgram = "sg2002-tpu-demo";
  };
}
