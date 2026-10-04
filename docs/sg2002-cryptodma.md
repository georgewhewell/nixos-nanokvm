# SG2002 CryptoDMA

Enable `sg2002.crypto.enable = true;` with the mainline kernel to load the
standard Linux Crypto API driver. It is off by default: DMA and request
scheduling help bulk operations, but make small requests slower. The module
is blacklisted from automatic loading when this option is off.

The driver exposes AES-128/192/256, SM4, DES and three-key 3DES in ECB/CBC/CTR
through `skcipher`, and incremental SHA-1/SHA-256 through `ahash`. These are
kernel-only algorithms, named `ecb-aes-sg2002`, `cbc-aes-sg2002`,
`ctr-aes-sg2002`, and likewise for `sm4`, `des`, `des3_ede`; hashes use
`sha1-sg2002` and `sha256-sg2002`. DES/3DES/SHA-1 provide compatibility,
not recommended new protocol choices. Enabling this does not change
OpenSSL/SSH, and supplies no AF_ALG or custom userspace interface.

Linux exclusively owns the engine. The master C906 completion is PLIC91;
the vendor PLIC59 number is for the auxiliary C906L. Both processors must
not independently program the accelerator. The driver shares security
clock references with the RNG/eFuse drivers, never resets that shared block,
and uses coherent private buffers rather than DMA into caller scatterlists.
A DMA timeout disables the engine and retains its buffers/clocks until a
whole-board reset; trying to unbind that failed instance also requires a
reset. The documentation does not establish a safe DMA drain/reset command.

## Validation

Tested on the LicheeRV Nano attached to `fuckup`, using a RAM-booted Linux
7.2.8 kernel with `EXPERT`, `CRYPTO_SELFTESTS`, `CRYPTO_SELFTESTS_FULL` and
software references enabled. The default kernel does not enable `EXPERT`
just for this driver. The separate hardware RNG remained active during tests.
RAM boots verified both the default blacklist and explicit initrd loading.

The standard tests passed with 100 fuzz iterations for all 14 registrations.
The [hardware comparison module](../pkgs/sg2002/linux-mainline/tests/crypto-api/crypto-api-test.c)
also compares all keys/modes against Linux software implementations, including
scattered/unaligned/in-place buffers, zero and partial requests, counter carry,
IV updates, messages larger than the 16 KiB DMA window, and multipart hash
export/import. Standard XTS (256/512-bit combined keys) and GCM templates
also pass, including ciphertext stealing and authentication failure. Their
tweak/GHASH work remains software. An allocated transform survived unbind
and rebind, returning `ENODEV` between them. A lab-only suppressed-start
fault exercised timeout quarantine, repeated request failure, module pinning
and reset on teardown; this is not a claim of testing a physically stalled
bus. The RNG continued operating during that fault.

The test module uses the kernel Crypto API directly. The test module's
`benchmark=1`, `only=ctr-aes-sg2002`, `keybits=128`, and `bench_ms=1000`
parameters run repeatable per-size measurements; `only=sha256-sg2002`
benchmarks the hash. CPU time includes the engine worker and interrupt handling
from whole-board CPU counters, not merely the submitting thread.

Build the test module with the test kernel's normal external-module command:
`make -C <kernel-build> M=$PWD/pkgs/sg2002/linux-mainline/tests/crypto-api ARCH=riscv CROSS_COMPILE=<cross-prefix> modules`.
The reference configuration needs `CRYPTO_AES`, `CRYPTO_DES`,
`CRYPTO_SM4_GENERIC`, `CRYPTO_SHA1`, `CRYPTO_SHA256`, `CRYPTO_ECB`,
`CRYPTO_CBC`, `CRYPTO_CTR`, `CRYPTO_XTS` and `CRYPTO_GCM`.

Measured AES-128-CTR at 64 KiB: **31.5 MiB/s**, versus **9.4 MiB/s** in
software. SHA-256: **75.7 MiB/s**, versus **14.1 MiB/s**. Whole-board CPU use
was approximately 90% and 71%, respectively, versus 100% for software.
At 16 bytes the
hardware paths delivered only **0.16/0.12 MiB/s**, versus **7.1/2.9 MiB/s**
respectively. These are single-board kernel API measurements, not application
speedup claims. The crossover in these runs was between 1 and 4 KiB.

Descriptor programming follows CVITEK's GPL-2.0 SPACC driver and OneKVM's
maintained implementation. Exact source references and register discrepancies
resolved by the hardware tests are recorded in the kernel patch's
`Documentation/crypto/sg2002.rst`.
