{ runCommand, stdenv, gitMinimal }:
runCommand "sg2002-isp-state-tests" {
  nativeBuildInputs = [ stdenv.cc gitMinimal ];
} ''
  git init -q
  git apply --include=drivers/media/platform/sophgo/sg2002-isp.h \
    ${../patches/0065-media-sophgo-add-SG2002-hardware-ISP-capture.patch}
  git apply --include=drivers/media/platform/sophgo/sg2002-isp.h \
    ${../patches/0093-media-sophgo-ISP-gamma-white-balance.patch}
  $CC -O1 -g -Wall -Wextra -Werror -Wno-unused-function \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    -Idrivers/media/platform/sophgo ${./isp-state.c} -lm -o test-isp
  ./test-isp
  touch "$out"
''
