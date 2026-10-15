#!/usr/bin/env python3
"""Compile and execute production framebuffer ownership paths with fake I/O."""

from __future__ import annotations

import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile


def declaration(source: str, pattern: str) -> str:
    match = re.search(pattern, source, re.MULTILINE)
    if match is None:
        raise AssertionError(f"missing production declaration: {pattern}")
    start = match.start()
    brace = source.index("{", match.end())
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    if source[end : end + 1] == ";":
        end += 1
    return source[start:end]


def macro(source: str, name: str) -> str:
    """Return a production #define verbatim, so the tests cannot drift from it."""
    match = re.search(rf"^#define {name} .*$", source, re.MULTILINE)
    if match is None:
        raise AssertionError(f"missing production macro: {name}")
    return match.group(0)


def main() -> None:
    source = Path(sys.argv[1]).read_text()
    macros = ("POLL_US", "POLL_MAX_US", "WIRE_TIME_MAX_US")
    functions = (
        "manifest_valid",
        "slot_record",
        "read_record",
        "frame_completed",
        "check_generation",
        "wire_time_us",
        "wait_slot",
        "lock_until",
        "lcd_cancel_events",
    )
    production = "".join(macro(source, name) + "\n" for name in macros)
    production += declaration(source, r"^struct frame_record\s*") + "\n"
    for name in functions:
        production += declaration(source, rf"^static [^;\n]*\b{name}\([^;{{]*\)") + "\n"
    scanout = declaration(source, r"^static int lcd_scanout\([^;{]*\)")
    assert scanout.index("lock_until(") < scanout.rindex("READ_ONCE(fb->fault)")
    assert (
        scanout.index("unlock:")
        < scanout.index("WRITE_ONCE(fb->fault")
        < scanout.index("mutex_unlock(")
    )
    assert (
        scanout.index("writel(0,")
        < scanout.index("drm_fb_memcpy(")
        < scanout.index("memcpy_toio(request,")
        < scanout.index("writel(sequence,")
    )
    # Slots and buffers share DRM_FORMAT_RGB565, so no pixel is ever converted.
    conversions = re.findall(r"\bdrm_fb_(?!memcpy\b)\w+\(|fmtcnv|conv_state", source)
    assert not conversions, conversions
    assert scanout.count("wmb();") >= 3
    harness = Path(__file__).with_name("test_ownership.c").read_text()
    with tempfile.TemporaryDirectory(prefix="c906l-framebuffer-test-") as directory:
        root = Path(directory)
        generated = root / "test.c"
        executable = root / "test"
        generated.write_text(harness.replace("/* @PRODUCTION@ */", production))
        subprocess.run(
            [
                os.environ.get("HOST_CC", "cc"),
                "-std=gnu11",
                # -Warray-bounds only runs under optimisation, and the harness
                # indexes fixed-size contract fields by hand.
                "-O2",
                "-Wall",
                "-Wextra",
                "-Werror",
                "-Wno-unused-parameter",
                "-I",
                sys.argv[2],
                str(generated),
                "-o",
                str(executable),
            ],
            check=True,
        )
        subprocess.run([str(executable)], check=True, timeout=10)
    print("Production framebuffer ownership tests passed")


if __name__ == "__main__":
    main()
