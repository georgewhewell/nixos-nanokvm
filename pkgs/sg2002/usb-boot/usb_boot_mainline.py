#!/usr/bin/env python3
"""USB bring-up for SG2002 / LicheeRV Nano using mainline U-Boot.

Mainline U-Boot has no cvi_utask (that's a Cvitek vendor command). We use
its built-in `fastboot` gadget instead, and rely on the fact that the
U-Boot we build (see flake.nix: `uboot-mainline.extraConfig`) has:

    CONFIG_BOOTCOMMAND="run distro_bootcmd; fastboot usb 0"

So once U-Boot starts and distro_bootcmd finds no bootable SD partition
(or we're running from ROM USB download and there's no SD at all), it
falls straight into the fastboot gadget — no UART required. Flow:

  1. Push FIP via cv181x-rom-dl (no UART interaction — ROM USB download
     only uses the CVITEK USB Com Port, not the board's debug UART).
  2. FSBL → OpenSBI → U-Boot runs; distro_bootcmd fails; fastboot usb 0
     enumerates on the host as VID 18d1:d00d.
  3. Host: `fastboot stage <FIT>` pushes the image to $fastboot_buf_addr.
  4. Host: `fastboot oem run "bootm <addr>"` — U-Boot bootms the staged
     FIT. If bootm hands off to the kernel, the oem-run reply never
     comes back and the host-side fastboot call returns a timeout
     error — that's expected and harmless.

Requires `fastboot` on PATH (android-tools).
"""
import argparse
import os
import subprocess
import sys
import time


FASTBOOT_BUF_ADDR = 0x82000000

# U-Boot's built-in fastboot gadget uses Google's reference VID:PID.
# Same IDs as Android phones in bootloader mode — without a filter,
# `fastboot devices` would happily pick a connected phone and we'd
# stage a NanoKVM FIT into its boot partition. Bad day.
FASTBOOT_VENDOR_ID = 0x18d1
FASTBOOT_PRODUCT_ID = 0xd00d


_SERIAL_AUTO = "<auto>"  # sentinel: device present but iSerial empty


def find_nanokvm_fastboot_serial():
    """Walk /sys/bus/usb/devices for the NanoKVM's 18d1:d00d gadget and
    return its iSerial. Returns None when not found. Returns the
    `_SERIAL_AUTO` sentinel when the gadget exists but has no
    iSerial — U-Boot's default fastboot gadget leaves it blank, so
    that's the common case. Callers should pass `_SERIAL_AUTO` through
    `fastboot_cmd` to mean ``no -s flag, let android-tools pick the
    sole connected device''.
    """
    base = "/sys/bus/usb/devices"
    if not os.path.isdir(base):
        return None
    for entry in os.listdir(base):
        try:
            with open(os.path.join(base, entry, "idVendor")) as f:
                vid = int(f.read().strip(), 16)
            with open(os.path.join(base, entry, "idProduct")) as f:
                pid = int(f.read().strip(), 16)
        except (FileNotFoundError, OSError, ValueError):
            continue
        if vid == FASTBOOT_VENDOR_ID and pid == FASTBOOT_PRODUCT_ID:
            try:
                with open(os.path.join(base, entry, "serial")) as f:
                    serial = f.read().strip()
                return serial if serial else _SERIAL_AUTO
            except (FileNotFoundError, OSError):
                return _SERIAL_AUTO
    return None


def main():
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument('fit', help='path to FIT image to push and boot')
    p.add_argument('--skip-fip', action='store_true',
                   help='skip ROM FIP push; assume U-Boot already in fastboot')
    p.add_argument('--fip', help='path to directory containing fip.bin')
    p.add_argument('--rom-dl', help='path to cv181x-rom-dl')
    p.add_argument('--fastboot', default='fastboot',
                   help='path to fastboot binary (android-tools)')
    p.add_argument('--wait', type=float, default=40.0,
                   help='seconds to wait for fastboot gadget to enumerate')
    p.add_argument('--rom-dl-timeout', type=float, default=480.0,
                   help='total seconds to spend on rom-dl across all '
                        'attempts. The CV181x ROM only stays live ~1s per '
                        '8s cycle in USB-DL mode; one rom-dl attempt may '
                        'miss the window. Behind a USB hub the cdc_acm bind '
                        'is slower so the window is missed more often — just '
                        'retry more (see --attempts).')
    p.add_argument('--attempts', type=int, default=60,
                   help='how many rom-dl invocations to make before '
                        'giving up. Per-attempt timeout = rom-dl-timeout / '
                        'attempts, floored at 15s. After each attempt we '
                        'poll fastboot for 6s; if found, stop retrying. '
                        '15s/attempt gives FSBL enough room for the '
                        'cvi_utask 2nd-stage push. Generous default so flaky '
                        'hub paths still converge.')
    p.add_argument('--rom-dl-verbose', action='store_true',
                   help='let cv181x-rom-dl write to our stderr instead of '
                        'discarding (useful for debugging which stage hung)')
    p.add_argument('--bootargs',
                   help='kernel command line; when set, sent to U-Boot via '
                        '`setenv bootargs "<str>"` before bootm. Overrides '
                        'whatever /chosen/bootargs the FIT fdt carries.')
    p.add_argument('--fastboot-serial',
                   help='fastboot SERIAL or device path to target. If '
                        'omitted, auto-detect from /sys/bus/usb by '
                        f'VID:PID {FASTBOOT_VENDOR_ID:04x}:{FASTBOOT_PRODUCT_ID:04x} '
                        '(U-Boot fastboot gadget). Set this if multiple '
                        'fastboot devices are co-attached or you want to '
                        'be explicit.')
    a = p.parse_args()

    fit_size = os.path.getsize(a.fit)

    def log(m):
        print(f"[{time.strftime('%H:%M:%S')}] {m}", flush=True)

    def fastboot_cmd(*args):
        cmd = [a.fastboot]
        # `_SERIAL_AUTO` means: gadget is present but iSerial is empty
        # (U-Boot default). Skip the `-s` flag and rely on the fact
        # that we already verified exactly one fastboot device is
        # attached. A real serial gets passed through verbatim.
        if a.fastboot_serial and a.fastboot_serial != _SERIAL_AUTO:
            cmd += ['-s', a.fastboot_serial]
        return cmd + list(args)

    def find_fastboot_target():
        """Return our fastboot serial (or `_SERIAL_AUTO` for an empty-
        iSerial gadget), populating a.fastboot_serial as a side-effect
        on first detection. None when no NanoKVM gadget is attached yet
        — caller polls."""
        if a.fastboot_serial:
            return a.fastboot_serial
        serial = find_nanokvm_fastboot_serial()
        if serial:
            a.fastboot_serial = serial
            if serial == _SERIAL_AUTO:
                log(f"  NanoKVM fastboot gadget detected "
                    f"(empty iSerial — passing fastboot without -s)")
            else:
                log(f"  found NanoKVM fastboot serial: {serial}")
        return serial

    if not a.skip_fip:
        if not a.fip or not a.rom_dl:
            log("ERROR: --fip and --rom-dl are required unless --skip-fip")
            sys.exit(2)

        # cv181x-rom-dl exits non-zero (often 255) even on success when
        # the SoC ROM transitions between 1st-stage and 2nd-stage USB
        # modes — particularly under deeper hub paths. The push itself
        # may have completed; the subsequent fastboot enumeration check
        # is the source of truth, so we don't `check_call` here.
        #
        # rom-dl ALSO has a bug where after pushing FIP it enters an
        # infinite "Waiting for USB connect 2nd stage" loop polling for
        # the vendor `cvi_utask` USB gadget — which never appears with
        # mainline U-Boot. We have to kill it externally; the FIP push
        # has already happened by then. Without a timeout `subprocess`
        # would block forever.
        #
        # And — the deeper unreliability — the CV181x ROM only holds
        # the USB device live for ~1s per cycle; if pyserial's poll +
        # cdc_acm bind + open() doesn't align with that window, the FIP
        # push silently fails. We retry: each pass is one short rom-dl
        # invocation, then a fastboot probe. If fastboot enumerates,
        # we move on. If not, try rom-dl again. Stop after a.attempts.
        outsink = None if a.rom_dl_verbose else subprocess.DEVNULL
        # Per-attempt timeout floored high (45s): a *successful* push is
        # multi-stage (1st-stage FSBL → cvi_utask 2nd-stage → OpenSBI+
        # U-Boot), which over a hub takes 15-25s; a 15s ceiling killed it
        # mid-2nd-stage so U-Boot never came up. EIO attempts (device
        # cycled mid-send) still return in ~2s, so the high ceiling only
        # bites on a real push — exactly when we want to let it finish.
        per_attempt = max(45.0, a.rom_dl_timeout / max(a.attempts, 1))
        for attempt in range(1, a.attempts + 1):
            log(f"attempt {attempt}/{a.attempts}: "
                f"rom-dl push (per-attempt timeout {per_attempt:.0f}s)...")
            try:
                rc = subprocess.call(
                    [a.rom_dl, '--image_dir', a.fip],
                    stdout=outsink,
                    stderr=outsink,
                    timeout=per_attempt,
                )
                log(f"  rom-dl exited {rc}")
            except subprocess.TimeoutExpired:
                log(f"  rom-dl still running at {per_attempt:.0f}s — killing "
                    f"(FIP push has either happened or it's stuck polling)")

            # Quick fastboot probe — if the device transitioned, exit
            # the retry loop and proceed to staging. We look directly
            # for the U-Boot fastboot gadget at 18d1:d00d so a phone
            # plugged in for unrelated reasons doesn't get treated as
            # "the device".
            probe_deadline = time.time() + 6.0
            seen = None
            while time.time() < probe_deadline:
                seen = find_fastboot_target()
                if seen:
                    break
                time.sleep(0.2)
            if seen:
                log(f"  fastboot live: {seen}")
                break
            else:
                log(f"  no fastboot yet — retrying rom-dl")
        else:
            log("rom-dl never produced a fastboot gadget after "
                f"{a.attempts} attempts — giving up")

    # Wait for the fastboot gadget to appear. We look directly for our
    # VID:PID rather than trusting `fastboot devices` output, which
    # would also list any phone in bootloader mode.
    deadline = time.time() + a.wait
    target_serial = None
    while time.time() < deadline:
        target_serial = find_fastboot_target()
        if target_serial:
            log(f"fastboot device online: {target_serial}")
            break
        time.sleep(0.3)
    else:
        log("ERROR: NanoKVM fastboot gadget didn't enumerate; check the "
            "USB-C connection and that the FIP actually boots U-Boot. "
            "(Looking for VID:PID "
            f"{FASTBOOT_VENDOR_ID:04x}:{FASTBOOT_PRODUCT_ID:04x}.)")
        sys.exit(1)

    log(f"staging {a.fit} ({fit_size} bytes)...")
    t0 = time.time()
    r = subprocess.run(fastboot_cmd('stage', a.fit),
                       capture_output=True, text=True)
    if r.returncode != 0:
        log(f"fastboot stage FAILED: {r.stderr}")
        sys.exit(1)
    log(f"staged in {time.time()-t0:.2f}s")

    # Tell U-Boot to bootm the staged image via FASTBOOT_OEM_RUN. Note
    # the `run:<cmd>` form: U-Boot's fastboot command table uses `:` as
    # the name/param separator (strsep on cmd_string), so we must send
    # a single `oem run:<cmd>` argument, not `oem run <cmd>` — the
    # latter hits the "unrecognized command" path because "oem run
    # <cmd>" doesn't strcmp-match "oem run".
    #
    # If bootm succeeds and hands off to the kernel, U-Boot never sends
    # the OKAY response, so host-side `fastboot` returns an error /
    # times out — that's expected and harmless.
    bootargs_cmd = (
        f'setenv bootargs "{a.bootargs}"; ' if a.bootargs else ''
    )
    bootm_cmd = (
        f'{bootargs_cmd}'
        f'setenv fdt_high 0xffffffff; '
        f'setenv initrd_high 0xffffffff; '
        f'bootm 0x{FASTBOOT_BUF_ADDR:x}'
    )
    log(f"issuing: oem run:{bootm_cmd}")
    # Three normal outcomes:
    #   1. Kernel boots cleanly → U-Boot's USB gadget tears down →
    #      fastboot sees a disconnect → returncode != 0, harmless.
    #   2. bootm fails fast and returns → returncode == 0 with output —
    #      rare but useful (means the FIT is broken).
    #   3. Kernel panics → hardware watchdog resets the board → U-Boot
    #      comes back up and re-enumerates → host fastboot session is
    #      now stuck on the original `oem run`, which never gets an
    #      OKAY → subprocess timeout fires. We swallow the timeout and
    #      let the caller (mkUsbBoot wrapper) attach picocom to the
    #      ACM gadget that comes up post-reset, so the panic trace is
    #      capturable.
    try:
        r = subprocess.run(fastboot_cmd('oem', f'run:{bootm_cmd}'),
                           capture_output=True, text=True, timeout=60)
        if r.returncode == 0:
            log(f"bootm returned (unexpected — kernel may not have started):"
                f"\n{r.stdout}\n{r.stderr}")
        else:
            log("bootm handed off (fastboot disconnected — kernel is running)")
    except subprocess.TimeoutExpired:
        log("oem-run timed out — kernel likely panicked and watchdog "
            "reset the board (fastboot session never got an OKAY). "
            "Continuing so picocom can attach to the post-reset ACM gadget.")


if __name__ == '__main__':
    main()
