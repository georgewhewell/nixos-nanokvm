#!/usr/bin/env python3
"""postPatch for sg2002-cv181x-usb-dl.

Two fixes against the upstream Sipeed package:

1. `cv181x_rom_usb_download.py` enters an infinite poll loop
   ("Connecting to ROM 2nd stage...") after the FIP push, looking for
   the vendor `uboot_cvi_vidpid` (3346:1001) USB gadget. That gadget
   never appears with mainline U-Boot — mainline replaces cvi_utask
   with the standard fastboot gadget (18d1:d00d) which the *wrapper*
   `usb_boot_mainline.py` polls for separately. We short-circuit the
   2nd-stage loop to `sys.exit(0)` immediately after BREAK.

2. `cv_usb_pyserial.py` opens the serial device with `timeout=10000`
   (ten THOUSAND seconds). When the CV181x ROM disconnects mid-read
   (~1 s after each enumeration cycle in USB-DL mode), pyserial
   blocks for ~2.8 hours on the next read. We change it to
   `timeout=1.0` so each read fails fast and the script can be
   retried from the next ROM cycle.

Idempotent — both fixes are skipped if their marker text is present.
"""
import re
import sys


MARKER = "# patched by sg2002-cv181x-rom-dl-skip-2nd-stage.py"
TIMEOUT_MARKER = "# patched timeout: short read so disconnect doesn't deadlock"
FAST_OPEN_MARKER = "# patched fast-open: skip the 100ms pre-open sleep"


def main():
    if len(sys.argv) < 2:
        sys.exit(f"usage: {sys.argv[0]} <cv181x_rom_usb_download.py> [<cv_usb_pyserial.py>]")
    rom_dl_path = sys.argv[1]
    # The pyserial timeout patch lives next to cv_usb_pyserial.py.
    import os
    pyserial_path = os.path.join(
        os.path.dirname(rom_dl_path), "cv_usb_util", "cv_usb_pyserial.py"
    )
    patch_pyserial_timeout(pyserial_path)
    patch_pyserial_fast_open(pyserial_path)
    # NOTE: skip_2nd_stage is intentionally disabled. After BREAK the
    # chip transitions to FSBL which presents `cvi_utask` at 3346:1001
    # — FSBL uses that to pull the REST of FIP from the host (only
    # the first 4 KB went via ROM USB-DL). Skipping the 2nd-stage
    # push leaves FSBL with no rest-of-FIP, which is fatal.
    #
    # The wrapper relies on the per-attempt subprocess timeout to
    # bound rom-dl when 3346:1001 doesn't materialise (e.g. FSBL
    # crashes on DDR init). It will then proceed to poll fastboot
    # anyway in case U-Boot did make it up another way.
    # patch_skip_2nd_stage(rom_dl_path)
    _ = rom_dl_path  # keep arg used


def patch_pyserial_timeout(path):
    with open(path) as f:
        src = f.read()
    if TIMEOUT_MARKER in src:
        print(f"already patched (pyserial timeout): {path}")
        return
    pattern = re.compile(
        r'(self\.device\s*=\s*serial\.Serial\()timeout=10000(,\s*writeTimeout=[0-9.]+\))'
    )
    new_src, n = pattern.subn(
        lambda m: m.group(1) + "timeout=1.0" + m.group(2) +
                  f"  {TIMEOUT_MARKER}",
        src, count=1,
    )
    if n == 0:
        print(f"WARN: pyserial-timeout pattern not found in {path}; "
              f"continuing without that patch")
        return
    with open(path, "w") as f:
        f.write(new_src)
    print(f"patched (pyserial timeout): {path}")


def patch_pyserial_fast_open(path):
    """Upstream pyserial wrapper does:

        self.device = serial.Serial(timeout=..., writeTimeout=0.5)
        self.device.port = element.device
        ...
        time.sleep(0.1)
        self.device.close()
        connect = -1
        while connect == -1:
            try:
                self.device.open()
                ...

    The CV181x ROM holds /dev/ttyACM0 live for ~1 second per
    enumeration cycle. The pre-open `time.sleep(0.1)` plus the
    redundant `close()` of an unopened serial burns ~150ms of that
    window before we even try to open(). On a slow open() that's
    fatal. Skip both — Serial(...) is unopened by default, and we
    don't need the sleep.
    """
    with open(path) as f:
        src = f.read()
    if FAST_OPEN_MARKER in src:
        print(f"already patched (fast-open): {path}")
        return
    # Anchor on the two adjacent lines we want to drop.
    pattern = re.compile(
        r'(\n        time\.sleep\(0\.1\)\n        self\.device\.close\(\)\n)',
    )
    new_src, n = pattern.subn(
        f"\n        {FAST_OPEN_MARKER}\n",
        src, count=1,
    )
    if n == 0:
        print(f"WARN: fast-open pattern not found in {path}; skipping")
        return
    with open(path, "w") as f:
        f.write(new_src)
    print(f"patched (fast-open): {path}")


def patch_skip_2nd_stage(path):
    with open(path) as f:
        src = f.read()
    if MARKER in src:
        print(f"already patched (skip-2nd-stage): {path}")
        return

    # The structure after BREAK is something like:
    #     cv_usb_serial.usb_send_req_data(pkt.CV_USB_BREAK, ...)
    #     print("break")
    #
    #     is_uboot_sent = False
    #     while True:
    #         del cv_usb_serial
    #         ...
    #
    # Replace from the `is_uboot_sent` line through the end of `main()`
    # with a clean exit. Anchoring on the surrounding text rather than
    # whitespace so reformatting upstream doesn't break us.

    pattern = re.compile(
        r'(\s*print\("break"\)\n)'                # group 1: anchor
        r'(.*?)'                                  # group 2: body to drop
        r'(\nif __name__ == ["\']__main__["\']:)',  # group 3: module trailer
        re.DOTALL,
    )

    def replacement(m):
        anchor, _body, trailer = m.group(1), m.group(2), m.group(3)
        new = (
            anchor +
            f"\n    {MARKER}\n"
            "    # mainline U-Boot has no cvi_utask; rom-dl's 2nd-stage\n"
            "    # poll loop hangs forever waiting for it. Exit cleanly\n"
            "    # so the wrapper can proceed to fastboot enumeration.\n"
            "    sys.exit(0)\n"
            + trailer
        )
        return new

    new_src, n = pattern.subn(replacement, src, count=1)
    if n == 0:
        sys.exit(
            f"FAILED to locate `print(\"break\")` ... `if __name__ == \"__main__\":`\n"
            f"in {path}. Did upstream change shape? Update this patch."
        )

    with open(path, "w") as f:
        f.write(new_src)
    print(f"patched: {path}")


if __name__ == "__main__":
    main()
