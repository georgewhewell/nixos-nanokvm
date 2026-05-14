# Single FIT-image builder replacing the four ad-hoc inline FIT
# constructions in the old flake.nix (boot-sd, busybox-fit,
# usb-initrd-fit, usb-initrd-fit-vendor). Also consumed by
# modules/sg2002.nix for the NixOS boot-fit that lands on the FAT
# firmware partition in the vendor boot path.
#
# Parameters:
#   kernel         — path to uncompressed Image (or any file if
#                    compressKernel = false).
#   fdt            — path to .dtb.
#   initrd         — path to initrd (cpio.gz / cpio.zst / etc.), or null.
#   compressKernel — true (default) gzips the kernel into the FIT.
#                    bootm relocates a streaming gzip safely; bare
#                    Image can overlap the FIT buffer during bootm's
#                    copy to load_addr once Image > (FIT_base - load).
#   loadAddrs      — { kernel, initrd } physical load addresses.
#   configName     — name of the default `configurations` node; must
#                    match whatever U-Boot's `bootm <addr>#<name>`
#                    expects. Sipeed's vendor U-Boot hard-codes
#                    `config-sg2002_licheervnano_sd` for its sdboot.
#   description    — human-readable; also used as the FIT's top-level
#                    description.
{
  runCommand,
  ubootTools,
  dtc,
  gzip,
  lib,
}: {
  kernel,
  fdt,
  initrd ? null,
  compressKernel ? true,
  loadAddrs ? {
    kernel = "0x80200000";
    initrd = "0x85000000";
  },
  configName ? "config-1",
  description ? "SG2002 FIT",
}: let
  # Resolve the kernel image path. Caller may pass the whole kernel
  # derivation (directory with Image/Image.gz) or a direct file path;
  # handle both.
  rawImage =
    if lib.isDerivation kernel
    then "${kernel}/Image"
    else kernel;

  # Gzip the kernel first so bootm relocates via a streaming gzip path
  # (see comment above). If compressKernel=false, pass the kernel
  # straight through.
  kernelFile =
    if compressKernel
    then
      runCommand "Image.gz" {
        nativeBuildInputs = [gzip];
      } "gzip -9 -c ${rawImage} > $out"
    else rawImage;
  kernelCompression =
    if compressKernel
    then "gzip"
    else "none";

  initrdBlock =
    if initrd == null
    then ""
    else ''
      ramdisk-1 {
        description = "initrd";
        data = /incbin/("${initrd}");
        type = "ramdisk";
        arch = "riscv";
        os = "linux";
        compression = "none";
        load = <0x00 ${loadAddrs.initrd}>;
      };
    '';
  configRamdiskRef = lib.optionalString (initrd != null) ''ramdisk = "ramdisk-1";'';

  its = ''
    /dts-v1/;

    / {
      description = "${description}";

      images {
        kernel-1 {
          description = "Linux kernel";
          data = /incbin/("${kernelFile}");
          type = "kernel";
          arch = "riscv";
          os = "linux";
          compression = "${kernelCompression}";
          load = <0x00 ${loadAddrs.kernel}>;
          entry = <0x00 ${loadAddrs.kernel}>;
        };

        ${initrdBlock}

        fdt-1 {
          description = "Flattened device tree";
          data = /incbin/("${fdt}");
          type = "flat_dt";
          arch = "riscv";
          compression = "none";
        };
      };

      configurations {
        default = "${configName}";

        ${configName} {
          description = "Boot";
          kernel = "kernel-1";
          ${configRamdiskRef}
          fdt = "fdt-1";
        };
      };
    };
  '';
in
  runCommand "boot-fit.sd" {
    nativeBuildInputs = [ubootTools dtc];
    passAsFile = ["its"];
    inherit its;
  } ''
    mkimage -f $itsPath $out
  ''
