# Standalone USB initrd

This image runs entirely in RAM: Linux, systemd, key-only SSH, DHCP on USB,
Ethernet and Wi-Fi, and board-specific peripheral drivers. No SD card, NixOS
stage 2, exported Nix store, NFS or NBD server is used. Uploading does not flash
anything. Power loss discards all changes.

## Build (x86_64 Linux with Nix)

Supply a file of **public** SSH keys, not a private key:

```sh
NANOKVM_AUTHORIZED_KEYS="$HOME/.ssh/id_ed25519.pub" \
  nix build --impure .#boards.picoclaw.mainline.initrd.default.bundle
```

For the bare LicheeRV Nano W or NanoKVM PCIe, replace `picoclaw` with `licheerv`
or `pcie`. PicoClaw includes the C906L-mediated DRM LCD and Wi-Fi power driver.
The `fit`, `kernel`, `initrd` and `usb-boot` outputs are also available at the
same attrpath. This is a hardware bring-up environment, not the NanoKVM web UI.

To provision Wi-Fi at build time, also set `NANOKVM_WIFI_CONFIG` to an absolute
path to a wpa_supplicant configuration, for example:

```conf
ctrl_interface=/run/wpa_supplicant/control
country=CH
network={
    ssid="your-network"
    psk="your-passphrase"
}
```

Use your country's code. This file becomes part of the image and Nix store:
both are readable by anyone with access. Do not publish a credential-bearing
bundle or upload it to a public cache. Alternatively, omit it and copy a config
over authenticated USB SSH to `/run/wpa_supplicant.conf`, then run
`systemctl restart wpa_supplicant-wlan0`.

## Upload from another machine (no Nix required)

Copy the **contents** of `result` to the USB host (e.g.
`tar -C result -czf nanokvm-usb.tar.gz .`). It contains no runtime references to
the builder's Nix store. Extract it, then verify `sha256sum -c SHA256SUMS`.

On Linux install Python 3, pyserial, PyUSB and Android platform-tools
(`fastboot`). Run `sudo python3 boot.py`, then put the board into ROM download
mode using its recovery/reset controls. The uploader has a bounded timeout;
rerun it if the board was not reset in time. Disconnect other fastboot devices.
The uploader exits after handing off to Linux; keep USB power connected.

Or, from the extracted bundle on a Linux Docker host:

```sh
docker build -t nanokvm-usb .
docker run --rm --privileged --network=host \
  -v /dev:/dev -v /sys:/sys:ro nanokvm-usb
```

The ROM changes USB identity while booting. Passing only one `/dev/ttyACM*`
node is insufficient. This container has broad device access; run only a
trusted bundle. Host networking shares the uploader's singleton lock, not a
root server. Docker Desktop on macOS/Windows does **not** automatically pass
physical USB through: use a Linux VM with working USB passthrough for both
ROM and fastboot identities. Native macOS/Windows uploading is not supported
by the current ROM tool. Building the image still needs Nix; uploading does not.

## Connect and inspect

All physical network interfaces use DHCP plus IPv4/IPv6 link-local fallback.
USB DHCP needs a DHCP server on the host (e.g. internet sharing), but is **not
required to boot**. Without one, use the board's IPv6 link-local address from
your host's neighbor discovery, including the USB interface scope:
`ssh root@fe80::ADDRESS%USB_INTERFACE`. On a LAN, find the board's DHCP lease.
No host networking is silently changed by the uploader.

SSH generates a new Ed25519 host key each boot. Use a separate known-hosts file
for this RAM-only device; verify host keys on a trusted USB link. Never disable
host-key checking globally. Password login and unauthenticated TCP shells are
disabled.

Useful commands after login:

```sh
ip address
networkctl
journalctl -b
systemd-analyze time
systemd-analyze critical-chain
iw dev
wpa_cli -i wlan0 status
aplay -l
arecord -l
ls /dev/dri /dev/fb* /dev/snd
sg2002-c906l-ctl --help
sg2002-c906l-drm-test --help
```

LCD commands apply to PicoClaw. Audio exposes the onboard ALSA ADC/DAC, not a
desktop sound server. Driver inclusion is not proof of speaker/microphone or
LCD operation on every carrier. A hardware watchdog is armed during U-Boot and
fed independently in Linux; it does not depend on the uploading host remaining
reachable. A reset loses this RAM image and requires another upload.

PicoClaw also requests a standard framebuffer boot console. Kernel text goes
to the LCD's virtual terminal and UART; the display takes over when the C906L
lease is validated and the DRM framebuffer registers. The built-in 4x6 font
fits 60 columns by 40 rows, and automatic console blanking is disabled. Earlier
text is limited to what remains in the virtual terminal; use `journalctl -k -b`
for the complete retained kernel log. The LCD driver loads through normal udev
device discovery, outside the synchronous boot module list. Display failure
does not create a service dependency for SSH, networking or the watchdog.

The LCD cannot show ROM/U-Boot or the very first Linux messages live: that
requires the validated firmware/display transport to be ready first. This
standalone stage-1 image leaves the LCD as a read-only log console; it has no
local getty/login authentication configured. Interactive access remains
authenticated SSH. These are standard Linux
[multiple-console](https://docs.kernel.org/admin-guide/serial-console.html) and
[fbcon](https://docs.kernel.org/fb/fbcon.html) settings, with UART retained as
`/dev/console`.

For a persistent system, use the separate [SD image](sg2002-c906l-picoclaw-sd-image.md).
Host-specific NFS/NBD deployment policy and root-serving services are outside
this repository and are not dependencies of either standalone workflow.

## Verification

`nix build .#checks.x86_64-linux.sg2002-initrd-boot` runs this kernel and initrd
userspace in a 256 MiB RISC-V VM, substituting virtio networking for the physical
devices. It checks DHCP, the DNS service, authorized-key login, rejection of an
unlisted key, no failed units, and remaining in stage 1. FIT builds also enforce
48 MiB compressed staging and 80 MiB unpacked-initrd limits.

The standalone PicoClaw image also passed a physical ROM-to-Linux upload from
a Debian container without Nix, followed by simultaneous Wi-Fi traffic, LCD
page flips, ALSA playback/capture and RPMsg checks.

Hydra builds every catalog image under `hydraJobs.x86_64-linux.images`, plus
the VM, uploader and hardware regression checks. USB CI bundles intentionally
have an empty authorized-keys file and no Wi-Fi credentials: **you cannot log
into them**. Build your own bundle with your public keys using the command
above. The expensive kernel, firmware and tools remain shared dependencies;
personalizing the initrd does not require recompiling them.
