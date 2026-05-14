#!/usr/bin/env python3
"""
NanoKVM OLED status display. stdlib only — no PIL, no luma.oled, no
ssd1306 lib. Writes ANSI-escape-clear + plain text to /dev/tty1; the
kernel's fbcon renders that to the SSD1306-backed /dev/fb0 over i²c.

Layout assumes default 8x16 font (16 cols × 4 rows on a 128×64 panel).
Each line is capped at 16 chars to avoid wrap.

Iterate on the host: scp this file to root@10.55.0.1:/run/oled/main.py
then `ssh root@10.55.0.1 systemctl restart oled-app` — no rebuild.
"""
import time

TTY = "/dev/tty1"
INTERVAL_SEC = 2.0


def read_uptime_seconds() -> float:
    with open("/proc/uptime") as f:
        return float(f.read().split()[0])


def read_loadavg_1m() -> str:
    with open("/proc/loadavg") as f:
        return f.read().split()[0]


def read_meminfo() -> dict[str, int]:
    out: dict[str, int] = {}
    with open("/proc/meminfo") as f:
        for line in f:
            key, _, rest = line.partition(":")
            out[key] = int(rest.strip().split()[0])  # kB
    return out


def fmt_uptime(secs: float) -> str:
    s = int(secs)
    h, s = divmod(s, 3600)
    m, s = divmod(s, 60)
    if h:
        return f"{h}h{m:02d}m"
    return f"{m}m{s:02d}s"


def render(tty) -> None:
    """Clear screen, redraw status."""
    mem = read_meminfo()
    free_pct = 100 * mem["MemAvailable"] // max(mem["MemTotal"], 1)

    tty.write("\x1b[H\x1b[2J")  # cursor home + clear screen
    tty.write("NanoKVM         \n")
    tty.write(f"up {fmt_uptime(read_uptime_seconds()):<13}\n")
    tty.write(f"load {read_loadavg_1m():<11}\n")
    tty.write(f"free {free_pct:>2d}%        \n")
    tty.flush()


def main() -> None:
    # Open once, write many. Closing/reopening tty1 on every frame
    # would flap the OLED at ~700ms per repaint.
    with open(TTY, "w") as tty:
        while True:
            render(tty)
            time.sleep(INTERVAL_SEC)


if __name__ == "__main__":
    main()
