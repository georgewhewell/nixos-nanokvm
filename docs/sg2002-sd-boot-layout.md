# SG2002 SD boot layout

The persistent SD images currently use MBR, a small FAT16 firmware partition
containing `fip.bin`, and a Btrfs root. Mainline U-Boot loads the kernel,
device tree and initrd through `/boot/extlinux/extlinux.conf` on the root
partition.

The firmware partition's LBA 1 start follows the vendor image. It is not a
demonstrated requirement of the ROM.

## Booting without an initrd

`sg2002.sdImage.initrd.enable = false` drops the initrd from an SD image. The
kernel has MMC and Btrfs built in, so it mounts `root=/dev/mmcblk0p2` itself
and runs the NixOS stage-2 `init` directly; `extlinux.conf` then has no
`INITRD` line for that generation. Generations with and without an initrd can
share a card.

Without stage 1, the USB gadget and the watchdog keeper start in stage 2, the
root file system is grown by `sg2002-grow-root.service`, and
`systemd-modules-load` in stage 2 loads every module. The PicoClaw C906L image
sets this option; the other SD images keep their initrd until they have been
tested without one.

On a PicoClaw (single 1 GHz core, Linux 7.2.8) the root is mounted 0.8 s after
kernel start and sshd listens at 39 s instead of 63-67 s; the DHCP lease on
Wi-Fi arrives at 67 s instead of 78 s.

## NanoKVM-PCIe hardware test, 2026-09-18

One SG2002 NanoKVM-PCIe was tested with the same firmware and root filesystem:

| Partition table | Firmware start | Result |
| --- | --- | --- |
| Original MBR | LBA 1 | Boots NixOS |
| MBR | LBA 2048 | Boots NixOS; Ethernet and Wi-Fi SSH verified |
| GPT with a protective MBR | LBA 2048 | Returned to USB ROM-download mode |

The aligned MBR and GPT tests used the same FAT16 filesystem, firmware file,
and partition offsets. The GPT firmware partition used the EFI System
Partition type. The root partition was neither moved nor reformatted.
Primary and backup GPT metadata passed read-back hashes and `sfdisk --verify`
before reboot.

The hardware watchdog was active during the experiment. Recovery through USB
loaded U-Boot, restored the original partition metadata and firmware area,
and compared the restored bytes before reboot. Raw layout writes did not
touch the root partition.

This establishes that moving the firmware partition alone works on this
board, but does **not** establish native GPT SD boot support. The result
points to an early boot partition-reader limitation; it does not identify
the exact ROM code path or establish behaviour on every SG2002 board.

## Hybrid GPT/MBR follow-up

Two hybrid layouts were then tested with the same deployed firmware, kernel
and root filesystem. Both placed the firmware at LBA 2048 and retained the
root partition at its existing offset. Only their MBR entries differed:

| Entries mirrored into MBR | Result |
| --- | --- |
| Firmware only; protective `0xee` entry second | ROM loaded U-Boot, which fell back to fastboot without booting Linux |
| Firmware and root; protective `0xee` entry third | Booted NixOS; Linux reported the GPT partition names and UUIDs |

The working MBR has an active type `0x0c` firmware entry and a type `0x83`
root entry, matching GPT's offsets and lengths. The GPT firmware partition
uses the EFI System Partition type. Ethernet and Wi-Fi SSH, the mounted filesystems
and the active hardware watchdog were verified after boot. No USB recovery
upload was needed for the successful boot. The firmware-only attempt was
automatically restored from verified backups before testing the second layout.

The U-Boot build used for those two tests inherited `CONFIG_EFI_PARTITION`
disabled from `sipeed_licheerv_nano_defconfig` in U-Boot 2026.07. This explains
why its root partition also needs an MBR entry: U-Boot uses MBR, while Linux
uses GPT.

### Standard U-Boot GPT reader

The package now enables `CONFIG_EFI_PARTITION=y` and checks that it survives
Kconfig resolution. This is upstream's GPT reader, not a new partition parser
or a switch to UEFI boot; the existing extlinux boot command is unchanged.

With the rebuilt FIP, the firmware-only hybrid layout boots NixOS on the
NanoKVM-PCIe. Wi-Fi SSH verified the new firmware hash, GPT root partition
name/UUID and active hardware watchdog. The root partition has no MBR entry,
so U-Boot must use GPT to find it. The vendor FSBL, DDR parameters and U-Boot
device tree are byte-identical to the previous build. Root geometry and the
installed NixOS system were unchanged.

The earlier SD loader is separate. In the pinned vendor SDK,
`fsbl/plat/cv181x/bl2/bl2_opt.c` delegates image reads to `p_rom_api_load_image`.
The supplied `fsbl/test/cv181x/cv181x_c906b_bl1.bin` reference binary's FAT mount
routine scans four MBR entries for a FAT volume; it does not follow GPT in
that path. This corroborates the observed early-boot limitation, but the SDK
reference binary is not a dump of this board's ROM. Enabling GPT in U-Boot
cannot change that preceding code.

A final comparison retained the new GPT-aware firmware and replaced only
sector 0 with a standard protective MBR: one `0xee` entry covering the disk
from LBA 1, with no mirrored partitions. Both GPTs and all partition data
were unchanged. This still returned to USB ROM-download mode. Recovery
loaded a known-good U-Boot into RAM, armed and verified the watchdog, restored
the firmware-only hybrid's sector 0, compared its read-back bytes and rebooted.
Ethernet SSH then verified the restored entry, new firmware hash and active
watchdog. That recovery boot is not evidence of native plain-GPT SD boot support.

No ROM/FSBL patches, nonstandard GPT headers or alternative on-disk loaders
were introduced. The standard U-Boot GPT reader works, but a supported
plain-GPT path through the preceding SD loader has not been established.

After testing, the card's pre-test firmware and two-entry hybrid layout were
restored from verified backups; Ethernet and Wi-Fi SSH and the active watchdog
were checked again. Keeping the firmware-only hybrid on a system
that still installs the older, MBR-only U-Boot would make the next bootloader
update unsafe. The GPT-reader package change is retained; shipped images
continue to use their original MBR layout.

### First-boot growth still needs integration

Do not switch the shipped images to hybrid GPT on boot evidence alone. An
off-board sparse-image test with cloud-utils 0.33 showed that the default
`growpart` backend replaces the hybrid MBR with a protective-only MBR. That
would remove the firmware entry needed by the ROM on the next boot. The
physical test card has automatic partition growth disabled.

On a second off-board test, `GROWPART_RESIZER=sgdisk` with GPT fdisk 1.0.10
preserved the firmware-only hybrid MBR while growing GPT's root partition.
That provides a standard-tool route to investigate alongside disko's existing
hybrid options. It has not yet been validated as a complete image/first-boot-growth
workflow on hardware. The default
images therefore retain their existing MBR layout.

## GPT and UEFI are separate

GPT describes a partition table; UEFI describes firmware services and an OS
loader interface. Changing the former does not enable the latter. U-Boot
can provide [UEFI services](https://docs.u-boot.org/en/latest/develop/uefi/uefi.html),
but the SoC still needs to load U-Boot first. These images currently use
extlinux; this experiment did not test a UEFI boot path.
