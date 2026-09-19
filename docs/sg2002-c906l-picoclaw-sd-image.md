# PicoClaw C906L LCD SD image

This persistent NixOS image is independent of the
[RAM-only USB initrd](usb-initrd.md). Both remain supported build targets;
neither requires a host NFS or NBD server.

`boards.picoclaw.mainline.sd.c906l-lcd` builds a persistent, mainline-kernel
SD image for the LicheeRV-Nano PicoClaw.  Linux renders through the standard
DRM/KMS and fbdev interfaces; the C906L firmware owns LCD SPI1 and GPIOA,
including the AIC8800's GPIOA26 Wi-Fi power line.  Linux receives an
acknowledged regulator interface for that one power rail rather than direct
access to GPIOA.

The image uses mainline U-Boot/extlinux, a FAT firmware partition beginning at
LBA 1, and a Btrfs root partition.  It is a 4 GiB raw image; use an 8 GiB or
larger card.  On first boot the root partition grows to fill the card.
See [SD boot layout validation](sg2002-sd-boot-layout.md) for the MBR choice
and the separate NanoKVM-PCIe GPT experiment.

This composition has build and contract validation.  Simultaneous LCD and
Wi-Fi behaviour still requires an on-hardware SD boot validation; do not treat
a successful build as that proof.

## Build with SSH access

The standalone image builds without a developer SSH key:

```sh
nix build .#boards.picoclaw.mainline.sd.c906l-lcd
```

To include authorized public SSH keys:

```sh
NANOKVM_AUTHORIZED_KEYS="$HOME/.ssh/id_ed25519.pub" \
  nix build --impure .#boards.picoclaw.mainline.sd.c906l-lcd
```

The image is under `result/sd-image/`. Log in as `root` with password
`nixos-nanokvm`, over SSH or the physical console. Only its salted password
hash is stored in the profile. This is a shared default for the public image;
change it with `passwd` after boot. Downstream configurations can override
`users.users.root.hashedPassword` and the OpenSSH authentication settings.
Adding public keys does not disable this initial password automatically. Keep
the default image on a trusted network until the password is changed.

The board generates a unique Ed25519 SSH host key on its writable SD card at
first boot; do not copy a host key from a USB live image.

Hydra builds the credential-free SD image as
`hydraJobs.x86_64-linux.images.picoclaw-sd`. It retains the same documented
initial password, but never includes local public keys or Wi-Fi credentials.

## Boot files and LCD console

The root filesystem uses Btrfs compression, but both `/boot/nixos` and
`/boot/extlinux` are marked uncompressed **before** boot files are created.
This includes the temporary file atomically renamed to `extlinux.conf`.
It avoids requiring U-Boot's Btrfs zstd reader for these files, addressing the
reported error while reading `/boot/extlinux/extlinux.conf`. Existing cards
need the updated boot installer or a newly built image; a USB upload does not
modify an old card.

The LCD uses standard fbcon when its validated firmware transport is ready,
with the 4x6 font and UART retained as the primary console. The display probes
through udev without blocking the forced-module boot path. Unlike the
RAM-only USB environment, stage 2 provides the usual authenticated getty.

## Wi-Fi credentials

The AIC8800 is enabled in this image.  Its power is requested by the SDIO
controller through the C906L-backed regulator, so Linux never writes GPIOA.
There are two intentional provisioning choices.

For a preconfigured card, create an ignored `wpa_supplicant.conf`-format file
with mode 0600, then build impurely:

```conf
ctrl_interface=DIR=/run/wpa_supplicant/control GROUP=wheel
network={
  ssid="example-ssid"
  psk="example-passphrase"
}
```

```sh
NANOKVM_WIFI_CONFIG="$PWD/wifi.conf" \
  nix build --impure .#boards.picoclaw.mainline.sd.c906l-lcd
```

This deliberately puts the Wi-Fi configuration into the Nix store and SD
image.  Treat that card and its build store as holding the credential; use a
dedicated installation SSID or prefer USB-first provisioning for a durable
credential.

For USB-first provisioning, omit `NANOKVM_WIFI_CONFIG`.  The image then waits
quietly for `/etc/wpa_supplicant/wpa_supplicant-wlan0.conf` instead of
restart-looping.  Connect via USB SSH as below, create that root-readable-only
file, and start the service:

```sh
install -d -m 0700 /etc/wpa_supplicant
umask 077
wpa_passphrase 'example-ssid' 'example-passphrase' \
  > /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
systemctl start wpa_supplicant-wlan0.service
networkctl status wlan0
```

`wpa_passphrase` writes a comment containing the original passphrase.  Remove
that comment if the file will be shared.  The file remains on the writable SD
root across reboots.

## Write and boot

Inspect the target device carefully; this command overwrites the selected SD
card.  Substitute the whole card device, not a partition.

```sh
lsblk -o NAME,SIZE,MODEL,TRAN,RM
sudo dd if=result/sd-image/*.img of=/dev/mmcblkX bs=16M conv=fsync status=progress
sync
```

Insert the card, connect the PicoClaw USB-C data port to the workstation, and
power the board.  The stage-2 USB gadget is CDC-ECM with static addresses:

```sh
sudo ip link set usb0 up
sudo ip address replace 10.55.0.2/24 dev usb0
ssh root@10.55.0.1
```

Use the interface name chosen by the host if it is not `usb0`.  The watchdog is
enabled but does not consider unplugging USB a failure on this persistent
image.

After login, check that the firmware contract and DRM device are present, then
exercise both display and networking:

```sh
sg2002-c906l-ctl check
sg2002-c906l-drm-test /dev/dri/card0 32
networkctl status wlan0
```

The DRM test draws changing checkerboards, waits for page-flip completion, and
restores the previous mode.  Its completion establishes the Linux-to-C906L
path; inspect the panel itself for colour/orientation confirmation.

## Build validation: 2026-09-18

The restored PicoClaw, LicheeRV and PCIe mainline SD images all completed their
full image builds. The module check covers persistent root, switch-root,
authenticated SSH/getty, the combined firmware contract and both watchdog
stages. The USB initrd checks continue to pass independently.

Read-only inspection of the PicoClaw image confirmed a 4 GiB MBR image, the
firmware partition starting at sector 1, and the Btrfs root at sector 49152.
Both boot directories reported `compression=none`; extent inspection found
all four boot files (including `extlinux.conf`) entirely uncompressed. The
installer uses the explicit Btrfs `inode` object type so its cross-architecture
execution does not depend on QEMU translating the filesystem autodetection
ioctl. The usual filesystem check and xattr operation remain in place.

This is image-build and filesystem validation, **not a physical SD boot**.
No card was overwritten.
