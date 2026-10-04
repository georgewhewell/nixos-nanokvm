#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
test "$#" = 2 || { echo "usage: $0 LINUX_SOURCE EMPTY_BUILD_DIR" >&2; exit 2; }
tests=$(cd -- "$(dirname -- "$0")" && pwd)
repo=$(cd -- "$tests/../.." && pwd)
mkdir -p "$2"
build=$(cd -- "$2" && pwd)
test -z "$(ls -A "$build")" || { echo "build directory must be empty" >&2; exit 2; }
mkdir -p "$build/arch/riscv/"{lib,purgatory}
cp "$1/arch/riscv/lib/Makefile" "$1/arch/riscv/lib/memcpy.S" "$build/arch/riscv/lib/"
cp "$1/arch/riscv/purgatory/Makefile" "$build/arch/riscv/purgatory/"
patch -s -d "$build" -p1 < "$repo/pkgs/sg2002/linux-mainline/patches/0084-riscv-use-xtheadvector-for-large-kernel-copies.patch"
cp "$build/arch/riscv/lib/"{memcpy.S,memcpy_vector.c} "$build/"
cp "$tests/"{Makefile,test.c,nested.S} "$build/"
