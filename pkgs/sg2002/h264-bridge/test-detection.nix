{ runCommand, stdenv, sg2002-cviruntime }:
runCommand "sg2002-h264-detection-tests" {
  nativeBuildInputs = [ stdenv.cc ];
} ''
  $CC -std=c11 -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer \
    -Wall -Wextra -Wconversion -Wshadow -Wformat=2 -Werror \
    -I${sg2002-cviruntime}/include -I${./.} \
    ${./test-detection.c} -pthread -lm -o test-detection
  ./test-detection
  touch "$out"
''
