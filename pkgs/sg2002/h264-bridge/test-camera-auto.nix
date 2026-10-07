{ runCommand, stdenv }:
runCommand "sg2002-camera-auto-tests" {
  nativeBuildInputs = [ stdenv.cc ];
} ''
  $CC -std=c11 -O1 -g -Wall -Wextra -Wconversion -Wshadow -Wformat=2 -Werror \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    -I${./.} ${./test-camera-auto.c} -lm -o test-camera-auto
  ./test-camera-auto
  touch "$out"
''
