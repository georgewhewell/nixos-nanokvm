# SG2002 datasheet audit

Review of the mainline port at `e99d3a1`, using the SG2002 Preliminary
Datasheet v1.0-alpha (2023-12-15, 60-page machine-translated English PDF)
and the pinned Linux 7.2.7 source. The clearest immediate fix is thermal:
the former 125 °C shutdown trip exceeded the packaged DRAM's 115 °C
operating limit. The best next investigations are ADC correctness and a
Linux hardware RNG driver. The datasheet establishes capabilities and
electrical limits; it does not supply complete driver programming sequences.

Page numbers below are the printed PDF pages. Register details come from
[Sophgo TRM v1.02](https://github.com/sophgo/sophgo-doc/releases/tag/sg2002-trm-v1.02),
commit `6da1ee8cad3ab730401cc8f775d690c57017f433`, which the existing
C906L documentation also uses. Pin routes were checked against
[Sophgo's SG2002 pin table](https://github.com/sophgo/sophgo-hardware/blob/12d2bc6976400e6d40389f3faaff40f4326b63c2/SG200X/04_SG2002/04_SG2002_PINOUT.xlsx).
Package pads and carrier/header availability are separate constraints.

## Fixes from this review

### Thermal shutdown before the DRAM limit

Section 2.5.2, table 2-5 note 3 (p. 27), limits the packaged DRAM to
115 °C; section 2.5.5 (p. 32) repeats this as the maximum junction
temperature. The 125 °C figure is the destructive silicon limit.

The shared board overlay now requests shutdown at 105 °C, leaving a
nominal 10 °C margin. This threshold is our board policy, not a vendor
mandated trip. Passive CPU cooling remains at 85 °C, with the existing
250/500/1000 MHz operating points. The CPUFreq check now verifies that
each composed catalog DTB places its critical trip above passive cooling
and at or below 105 °C.

This does not establish sensor calibration or guarantee shutdown latency.
Hardware acceptance should use the existing opt-in thermal emulation to
exercise throttling and shutdown, followed by normal-temperature sensor
comparison. It does not require heating the board to its limit.

### Correct peripheral descriptions

The common overlay incorrectly said IIC1–4 had no external routes. The
pin table provides these example pairs:

| Bus | SCL / SDA pads | Function | Existing conflict or use |
| --- | --- | --- | --- |
| IIC1 | SD1_D3 / SD1_D0 | 2 | OLED overlay; conflicts with SDIO Wi-Fi |
| IIC2 | PWR_GPIO1 / PWR_GPIO2 | 6 | RTC-domain functions; requires carrier review |
| IIC3 | SD1_CMD / SD1_CLK | 2 | Conflicts with SDIO Wi-Fi |
| IIC4 | PWR_WAKEUP0 / PWR_BUTTON1 | 5 | Existing camera and NanoKVM HDMI-control routes |

These are possible routes, not a request to enable every bus. IIC2 also
has routes on MIPI TX pads. Several alternatives consume camera, display,
Ethernet or boot-storage signals. The comments now reflect the existing
board-specific routing.

The ADC description also confused physical channel names with Linux's
zero-based numbering. The driver reads register `0x14` for IIO channel 0;
the TRM calls that `saradc_ch1_result`. Thus ADC1 corresponds to IIO
channel 0, not channel 1. The other active-domain channels are not
documented board voltage monitors. Comments are corrected; the IIO and
hwmon interfaces are retained pending measurement.

## Next fixes and enablement

### ADC reference, pin setup and binding

The upstream `drivers/iio/adc/sophgo-cv1800b-adc.c` returns a constant
`3300 / 4096` mV scale. It neither selects nor reads the reference or trim.
The TRM describes an internal reference and an external reference sourced
from VDD18A, plus an offline calibration procedure. Consequently the
current hwmon millivolts are not established as accurate. Replacing 3300
with 1800 without checking reference mode would also be unjustified.
[SARADC operation](https://github.com/sophgo/sophgo-doc/blob/6da1ee8cad3ab730401cc8f775d690c57017f433/SG200X/TRM/contents/en/peripherals/saradc.rst),
[register fields](https://github.com/sophgo/sophgo-doc/blob/6da1ee8cad3ab730401cc8f775d690c57017f433/SG200X/TRM/contents/cn/peripherals/saradc_registers_description.table.rst).

Next steps: establish the carrier's ADC1 connection and analog pin setup,
read reference/trim state, measure known input voltages within the pad's
limits, then model reference and channel availability in the driver/DT.
Also add `#io-channel-cells` to the ADC binding: the local overlay uses
it for hwmon, but the pinned upstream schema rejects that property.

There is a second ADC at `0x0502c000` in the RTC domain. Its register
layout is documented as identical, but enabling it still needs verified
clock, IRQ, power-domain and pin ownership. The datasheet's four exposed
ADC inputs do not mean four channels on the active-domain controller.

### Hardware random number generator

The datasheet advertises an RNG (p. 12), but its old address table marks
the security range reserved. The newer TRM identifies TRNG at
`0x02070000`, with a noise-seed, state-creation and random-generation
sequence yielding four 32-bit words. No SG2002 RNG binding/driver is
present in the inspected kernel or local patch queue.
[TRNG operation](https://github.com/sophgo/sophgo-doc/blob/6da1ee8cad3ab730401cc8f775d690c57017f433/SG200X/TRM/contents/en/security/trng.rst).

A Linux hwrng driver is a reasonably contained new peripheral project.
It needs clock/reset/access verification, bounded command waits, stale
completion handling, short-read handling, and failure/reseed policy.
Assess entropy quality before assigning an entropy credit; generating
changing bytes is not sufficient validation. Potential benefit: a local
entropy source for the RAM-only SSH boot, subject to measuring whether
entropy currently delays startup.

### CryptoDMA and read-only eFuse

The TRM documents CryptoDMA at `0x02060000` with AES/SM4/DES and SHA
operations. A Linux Crypto API driver could offload supported kernel
consumers, but must handle the C906's noncoherent DMA, scatterlists,
alignment, timeout/reset recovery and software fallbacks. Benchmark
real consumers before claiming a speedup: ordinary OpenSSH/OpenSSL
software encryption does not automatically use a kernel accelerator.
[CryptoDMA](https://github.com/sophgo/sophgo-doc/blob/6da1ee8cad3ab730401cc8f775d690c57017f433/SG200X/TRM/contents/en/security/cryptodma.rst).

A read-only NVMEM provider is another candidate at the eFuse controller
(`0x03050000`, p. 16). The TRM distinguishes 4 Kbit physical storage from
2 Kbit logical storage and separates public/system data from protected
security data. Start with documented nonsecure shadow fields and confirm
their layout; do not infer unique-ID, MAC or calibration cells merely
from the existence of the block. No fuse programming is part of this
proposal. [eFuse architecture](https://github.com/sophgo/sophgo-doc/blob/6da1ee8cad3ab730401cc8f775d690c57017f433/SG200X/TRM/contents/en/security/efuse.rst).

### Media beyond the current pipeline

The datasheet lists H.264 encode/decode, H.265 encode and JPEG/MJPEG
(p. 10), with separate JPEG, H.264 and H.265 windows at `0x0b000000`,
`0x0b010000` and `0x0b020000` (p. 19). The current Coda980 work implements
the H.264 encoder path; those adjacent capabilities require their own
firmware/register/driver investigation. They cannot be enabled by simply
advertising more formats on the working encoder.

For the existing camera path, black-level correction, gamma, statistics
and AE/AWB are more direct improvements. Section 1.2.6 (p. 11) lists ISP
capabilities, while [the current ISP report](sg2002-mainline-isp.md)
records fixed settings, disabled statistics and unvalidated lit-scene
colour. First establish lit colour-chart output; then add one processing
stage at a time. H.264 VUI colour signalling is a separate existing gap.

The 1 TOPS TPU (p. 10), IVE (pp. 11, 19), rotation/lens correction and
native display paths are larger projects. They need command formats,
firmware/compiler ABI where applicable, DMA isolation and ownership of
shared media clocks/resets. The capability list alone is insufficient.

## Constraints the datasheet confirms

| Area | Evidence | Consequence for this port |
| --- | --- | --- |
| CPU frequency | Main C906 1 GHz; auxiliary C906 700 MHz (p. 9); nominal core 0.9 V (pp. 14, 31) | Current 1 GHz ceiling is supported; this does not establish voltage scaling on carriers without a controllable regulator. |
| CPU topology | A53/C906 application CPU selection strap (p. 9) | The A53 is an alternative boot personality, not an additional Linux SMP CPU. |
| Vector support | Main C906 has a vector unit (p. 9) | Does not establish ratified RVV compatibility or resolve the recorded boot hang; retain the present vector exclusion pending a dedicated investigation. |
| SD/eMMC voltage | Shared SD0/eMMC IO supply (pp. 13–14, 31) | Keep the carrier's `no-1-8-v`; UHS/HS200 needs an actual compatible voltage-switching and pin arrangement. |
| SPI speed | General SPI SCK maximum 46.8 MHz (table 2-36, p. 50) | C906L LCD uses 187.5 MHz / 4 = 46.875 MHz. The small discrepancy may be rounding, but needs clarification; do not halve its divider based only on controller capability. |
| CSI rate | D-PHY RX 80 Mbit/s to 1.5 Gbit/s per lane (p. 51) | Check sensor link rates and PHY setup against this range; advertised dual input does not establish a working second capture pipeline. |
| Audio | Internal mic and output are mono (p. 12) | Supports the recent mono-capture correction; the AEC reference path needs separate routing investigation. |
| Low power | RTC-domain peripherals, power sequencer and 8-bit MCU (pp. 8, 18, 28–31) | Future suspend/wake work needs RTC firmware and carrier power-sequence ownership; an RTC driver alone does not implement suspend. |

The preliminary document has internal inconsistencies: three SPI ports
in the feature list but four register windows, fifteen PWM outputs but
four four-channel controllers, and security blocks omitted from the map.
Use newer TRM, pin table and board measurements to resolve them; do not
delete working IP instances solely to match the overview counts.

## Validation

`nix build .#checks.x86_64-linux.sg2002-cpufreq --no-link` passed: the
catalog device trees compile and their CPUFreq/thermal integration and
kernel configuration checks pass. `git diff --check` also passed. No
device was booted, flashed or measured in this review. The enablement
items above remain proposals.
