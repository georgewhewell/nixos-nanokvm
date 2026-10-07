{ runCommand, stdenv }:
runCommand "sg2002-h264-bridge-colour-tests" {
  nativeBuildInputs = [ stdenv.cc ];
} ''
  $CC -std=c11 -O2 -Wall -Wextra -Wconversion -Wshadow -Wformat=2 -Werror \
    -I${./.} ${./test-colour.c} ${./camera-auto.c} -lm -o test-colour
  ./test-colour
  touch "$out"
''
