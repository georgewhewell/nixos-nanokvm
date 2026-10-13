{ lib, pkgs }:
let
  upstream = import (pkgs.path + "/nixos/modules/system/boot/loader/generic-extlinux-compatible/extlinux-conf-builder.nix") {
    inherit lib pkgs;
  };
in pkgs.runCommand "sg2002-extlinux-conf-builder" {} ''
  cp ${upstream} "$out"
  substituteInPlace "$out" \
    --replace-fail 'cp -r $src $dstTmp' 'cp --reflink=never -r $src $dstTmp' \
    --replace-fail 'test -e $path/kernel -a -e $path/initrd' 'test -e $path/kernel' \
    --replace-fail 'copyToKernelsDir "$path/initrd"; initrd=$result' \
      'initrd=; if test -e $path/initrd; then copyToKernelsDir "$path/initrd"; initrd=$result; fi' \
    --replace-fail 'echo "  INITRD ../nixos/$(basename $initrd)"' \
      '[ -z "$initrd" ] || echo "  INITRD ../nixos/$(basename $initrd)"'
  chmod +x "$out"
''
