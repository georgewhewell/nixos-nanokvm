#!/usr/bin/env python3
"""USB bring-up for SG2002 / LicheeRV Nano.

Full flow:
  1. Ctrl+C spam to UART while pushing FIP via cv181x-rom-dl (breaks
     U-Boot's bootcmd before showlogo/sdboot can stash the UART).
  2. Type `cvi_utask` on UART to start U-Boot's USB gadget.
  3. Push a FIT image via USB bulk (CVI_USB_TX_DATA_TO_RAM) — MB/s.
  4. Trigger `bootm` via a Hush-shell `;` chained into an allowed `setenv`,
     since cvi_utask's PRG_CMD handler only permits setenv/saveenv/efuser.
  5. Stream kernel output on UART until --watch timeout.

If the board is already in cvi_utask (e.g., after a previous run), pass
--skip-fip to skip phase 1-2 and just push the FIT.
"""
import argparse
import os
import subprocess
import sys
import threading
import time
from array import array


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('fit', help='path to FIT image to push and boot')
    p.add_argument('--uart', default='/dev/ttyUSB0')
    p.add_argument('--load-addr', default='0x82000000',
                   help=('where to load the FIT. Must be >= kernel-load + '
                         'kernel-uncompressed-size (kernel is loaded at '
                         '0x80200000; mainline NixOS kernels are ~29 MB).'))
    p.add_argument('--bootargs',
                   default=('console=ttyS0,115200 earlycon=sbi ignore_loglevel '
                            'panic=5 oops=panic'))
    p.add_argument('--skip-fip', action='store_true',
                   help='skip ROM FIP push; assume board already in cvi_utask')
    p.add_argument('--fip', help='path to directory containing fip.bin')
    p.add_argument('--rom-dl', help='path to cv181x-rom-dl')
    p.add_argument('--cv-usb-lib', required=True,
                   help='path to directory containing cv_usb_util/')
    p.add_argument('--watch', type=int, default=60,
                   help='seconds to stream UART after bootm')
    p.add_argument('--wait', type=float, default=20.0,
                   help='seconds to wait for the cvi_utask USB gadget')
    a = p.parse_args()

    sys.path.insert(0, a.cv_usb_lib)
    import serial
    import cv_usb_util.cv_usb_pkt as pkt
    from cv_usb_util.cv_usb_pyserial import cv_usb_pyserial

    load_addr = int(a.load_addr, 0)
    fit_size = os.path.getsize(a.fit)

    def log(m):
        print(f"[{time.strftime('%H:%M:%S')}] {m}", flush=True)

    # Only open UART if we actually need it — with a patched vendor
    # U-Boot that auto-enters cvi_utask, --skip-fip mode needs no UART.
    ser = None
    stop_reader = threading.Event()
    uart_log = bytearray()
    if not a.skip_fip:
        log(f"opening {a.uart}")
        ser = serial.Serial(a.uart, 115200, bytesize=8, parity='N', stopbits=1,
                            timeout=0.2, rtscts=False, dsrdtr=False)

        def reader():
            while not stop_reader.is_set():
                try:
                    d = ser.read(4096)
                except Exception:
                    break
                if d:
                    uart_log.extend(d)
                    try:
                        sys.stdout.write(d.decode('utf-8', 'replace'))
                        sys.stdout.flush()
                    except Exception:
                        pass
        rt = threading.Thread(target=reader, daemon=True)
        rt.start()

    if not a.skip_fip:
        if not a.fip or not a.rom_dl:
            log("ERROR: --fip and --rom-dl are required unless --skip-fip")
            sys.exit(2)

        # UART Ctrl+C spammer — arrives at U-Boot the instant its UART inits,
        # breaking bootcmd before showlogo/sdboot reshuffle the state.
        stop_spam = threading.Event()

        def spam():
            while not stop_spam.is_set():
                try:
                    ser.write(b'\x03')
                except Exception:
                    break
                time.sleep(0.04)
        st = threading.Thread(target=spam, daemon=True)
        st.start()

        log("pushing FIP via ROM USB...")
        subprocess.check_call([a.rom_dl, '--image_dir', a.fip],
                              stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL)
        log("FIP pushed; keeping Ctrl+C for 3s")
        time.sleep(3)
        stop_spam.set()
        st.join()
        time.sleep(0.3)

        log("sending: cvi_utask")
        ser.write(b'\r\ncvi_utask\r\n')
        deadline = time.time() + 6
        while time.time() < deadline and b'USB enumeration done' not in uart_log:
            time.sleep(0.1)
        if b'USB enumeration done' not in uart_log:
            log("WARN: didn't see 'USB enumeration done' — continuing anyway")

    time.sleep(0.5)
    usb = cv_usb_pyserial()
    log("finding cvi_utask gadget (3346:1000 or 3346:1001)...")
    r = usb.serial_query(["VID:PID=3346:1000", "VID:PID=3346:1001"],
                         timeout=a.wait)
    if r == pkt.TIMEOUT:
        log("ERROR: cvi_utask gadget didn't come up")
        stop_reader.set()
        sys.exit(1)
    log(f"cvi_utask gadget online: 3346:{r:04x}")

    def prg_cmd(text):
        c = array('B', [ord(x) for x in text])
        log(f"CMD> {text}")
        usb.usb_send_req_data(pkt.CV_USB_PRG_CMD, 0, len(c) + 8, c)
        time.sleep(0.4)

    prg_cmd(f"setenv bootargs {a.bootargs}")

    # Flush stale ACKs from prior PRG_CMD calls — otherwise send_file's
    # first-packet CRC check reads the prior ACK and livelocks retrying.
    usb.device.reset_input_buffer()
    time.sleep(0.2)

    log(f"pushing {a.fit} ({fit_size} bytes) → 0x{load_addr:x}...")
    t0 = time.time()
    usb.usb_send_file(a.fit, load_addr, 0)
    log(f"pushed in {time.time()-t0:.2f}s")
    time.sleep(0.5)

    # Hush injection: cvi_utask only allows setenv/saveenv/efuser/efusew as
    # PRG_CMD prefixes, but U-Boot's Hush parser splits the command on `;`,
    # so we can chain additional commands after a leading setenv.
    # fdt_high / initrd_high = 0xffffffff disables relocation — otherwise
    # bootm of a large FIT (e.g. 50 MB mainline) moves the FDT/initrd into
    # the FIT's own memory and dies with "new format image overwritten".
    prg_cmd(
        f"setenv fdt_high 0xffffffff; "
        f"setenv initrd_high 0xffffffff; "
        f"bootm 0x{load_addr:x}"
    )

    log(f"bootm issued — streaming UART for {a.watch}s")
    end = time.time() + a.watch
    while time.time() < end:
        time.sleep(1)
    stop_reader.set()


if __name__ == '__main__':
    main()
