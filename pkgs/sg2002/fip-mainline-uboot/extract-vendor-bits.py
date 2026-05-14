#!/usr/bin/env python3
"""Extract vendor FSBL + DDR params from a Cvitek SG2002 FIP blob.

The SG2002 ROM loads fip.bin as a FAT file from the firmware partition
and expects a specific layout: a CVBL01 PARAM1 header at offset 0,
a CVLD02 PARAM2 header at a PARAM2_LOADADDR referenced from PARAM1, and
a packed concatenation of FSBL, BLCP, DDR params, BLCP_2nd, monitor
(OpenSBI), and bootloader (U-Boot) binaries at various offsets described
by those headers.

We want to reuse Sipeed's known-good FSBL (their prebuilt sophgo/fiptool
cv181x.bin doesn't POST on the LicheeRV Nano — drops into an eMMC retry
loop) and DDR params (board-specific), but swap OpenSBI and U-Boot to
mainline versions. Rather than re-implement Sipeed's fiptool genfip, we
extract the two bits we want and hand them to sophgo-fiptool.

Usage: extract-vendor-bits.py <vendor-fip> <out-dir>
  Writes <out-dir>/vendor-fsbl.bin and <out-dir>/vendor-ddr.bin.
  If BLCP_2nd is non-empty, also writes <out-dir>/blcp2nd.bin.
"""
import struct
import sys
from pathlib import Path


# Sipeed's PARAM1/PARAM2 carry an 8-byte MAGIC1 that starts with
# "CVBL01" / "CVLD02" followed by two version-ish bytes that vary
# (e.g. "\n\0" in current production images). Match only the 6-byte
# ASCII prefix — that's the part that identifies the layout.
PARAM1_PREFIX = b"CVBL01"   # at offset 0
PARAM2_PREFIX = b"CVLD02"   # at PARAM2_LOADADDR


def _u32(buf: bytes, off: int, ctx: str) -> int:
    if off + 4 > len(buf):
        raise ValueError(
            f"{ctx}: tried to read u32 at {off:#x} but buffer is only "
            f"{len(buf)} bytes — vendor FIP layout has changed?"
        )
    return struct.unpack_from("<I", buf, off)[0]


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2

    fip_path = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)

    fip = fip_path.read_bytes()
    if len(fip) < 0x2000:
        print(f"FATAL: {fip_path} is only {len(fip)} bytes; FIP needs "
              f"≥ 8 KiB of headers", file=sys.stderr)
        return 1

    # Validate magic prefixes so a vendor image with a changed layout
    # fails loud rather than silently producing garbage FSBL/DDR.
    if not fip.startswith(PARAM1_PREFIX):
        print(f"FATAL: {fip_path}: PARAM1 prefix mismatch — got "
              f"{fip[:8]!r}, expected {PARAM1_PREFIX!r}+2 bytes. Sipeed "
              f"may have changed the FIP layout; revisit "
              f"extract-vendor-bits.py.",
              file=sys.stderr)
        return 1

    # PARAM1 layout from Sipeed fiptool (magic CVBL01):
    #   MAGIC1 8 + MAGIC2 4 + PARAM_CKSUM 4             = 16-byte prefix
    #   NAND_INFO 128 + NOR_INFO 36 + FIP_FLAGS 8
    #     + CHIP_CONF_SIZE 4
    #     + BLCP_IMG_CKSUM 4 + BLCP_IMG_SIZE 4 + BLCP_IMG_RUNADDR 4
    #     + BLCP_PARAM_LOADADDR 4 + BLCP_PARAM_SIZE 4
    #     + BL2_IMG_CKSUM 4 + BL2_IMG_SIZE 4 + BLD_IMG_SIZE 4
    #     + PARAM2_LOADADDR 4
    # Absolute offsets we need:
    #   BLCP_IMG_SIZE=180, BL2_IMG_SIZE=216, PARAM2_LOADADDR=224
    blcp_img_size = _u32(fip, 180, "PARAM1.BLCP_IMG_SIZE")
    bl2_size = _u32(fip, 216, "PARAM1.BL2_IMG_SIZE")
    p2_addr = _u32(fip, 224, "PARAM1.PARAM2_LOADADDR")

    # Sanity check sizes before they become slice arithmetic.
    if not (0 < bl2_size < len(fip)):
        print(f"FATAL: PARAM1.BL2_IMG_SIZE = {bl2_size} is implausible "
              f"for a {len(fip)}-byte FIP", file=sys.stderr)
        return 1
    if p2_addr >= len(fip) - 64:
        print(f"FATAL: PARAM1.PARAM2_LOADADDR = {p2_addr:#x} runs off "
              f"the end of the {len(fip)}-byte FIP", file=sys.stderr)
        return 1
    if not fip[p2_addr:p2_addr + 8].startswith(PARAM2_PREFIX):
        print(f"FATAL: PARAM2 prefix mismatch at offset {p2_addr:#x} — "
              f"got {fip[p2_addr:p2_addr + 8]!r}, expected "
              f"{PARAM2_PREFIX!r}+2 bytes",
              file=sys.stderr)
        return 1

    # PARAM2 layout (magic CVLD02) after 16-byte prefix:
    #   DDR_PARAM_LOADADDR @ 20, DDR_PARAM_SIZE @ 24
    #   BLCP_2ND_LOADADDR  @ 36, BLCP_2ND_SIZE  @ 40
    p2 = fip[p2_addr:]
    ddr_addr = _u32(p2, 20, "PARAM2.DDR_PARAM_LOADADDR")
    ddr_size = _u32(p2, 24, "PARAM2.DDR_PARAM_SIZE")
    blcp2nd_addr = _u32(p2, 36, "PARAM2.BLCP_2ND_LOADADDR")
    blcp2nd_size = _u32(p2, 40, "PARAM2.BLCP_2ND_SIZE")

    if not (0 < ddr_size < len(fip)):
        print(f"FATAL: PARAM2.DDR_PARAM_SIZE = {ddr_size} is implausible",
              file=sys.stderr)
        return 1
    if ddr_addr + ddr_size > len(fip):
        print(f"FATAL: DDR range [{ddr_addr:#x},{ddr_addr+ddr_size:#x}) "
              f"runs off the end of the {len(fip)}-byte FIP",
              file=sys.stderr)
        return 1

    # FSBL (BL2) body starts at 0x1000 — after the param1 prefix + BLCP
    # image area. Safest to use the known vendor layout.
    if 0x1000 + bl2_size > len(fip):
        print(f"FATAL: FSBL extent [0x1000,{0x1000+bl2_size:#x}) overruns "
              f"the {len(fip)}-byte FIP", file=sys.stderr)
        return 1
    fsbl = fip[0x1000:0x1000 + bl2_size]
    ddr = fip[ddr_addr:ddr_addr + ddr_size]

    (out_dir / "vendor-fsbl.bin").write_bytes(fsbl)
    (out_dir / "vendor-ddr.bin").write_bytes(ddr)
    print(f"FSBL:    {len(fsbl)} bytes")
    print(f"DDR:     {len(ddr)} bytes")

    # BLCP_2nd is empty on LicheeRV Nano (blcp2nd_size == 0). sophgo-
    # fiptool requires --rtos but accepts an empty file; we just let the
    # caller substitute sophgo-fiptool's cvirtos.bin default when absent.
    if blcp2nd_size > 0:
        if blcp2nd_addr + blcp2nd_size > len(fip):
            print(f"FATAL: BLCP_2nd extent runs off FIP",
                  file=sys.stderr)
            return 1
        blcp2nd = fip[blcp2nd_addr:blcp2nd_addr + blcp2nd_size]
        (out_dir / "blcp2nd.bin").write_bytes(blcp2nd)
        print(f"BLCP2ND: {blcp2nd_size} bytes")
    else:
        print("BLCP2ND: 0 bytes (empty)")

    _ = blcp_img_size  # silence unused — extracted for debugging hooks
    return 0


if __name__ == "__main__":
    sys.exit(main())
