# SG2002 vector application experiment

Adding the compiler flag did not measurably improve SSH throughput or reduce
CPU time. Rebuilding OpenSSL with it made WPA passphrase derivation slower.
These results support keeping the existing scalar package baseline.

These are package-local compiler experiments, not a change to the system ISA.
Tested on the LicheeRV Nano's main C906 at 1 GHz (`performance` governor),
Linux 7.2.8, with the vector PR at `9ba12b8` and its pinned nixpkgs.
The toolchain was GCC 15.3.0; applications were OpenSSH 10.5p1,
OpenSSL 3.6.4 and wpa_supplicant 2.12.

The baseline uses the configuration's normal `rv64gc` ISA and C906 tuning.
The experimental builds add `-march=rv64gc_xtheadvector`; the optimization
level and libc remain unchanged. An additional variant rebuilds OpenSSL
with the same flag, separating application changes from library changes.
`-fopt-info-vec-optimized` records compiler diagnostics without changing code.

The temporary package definitions were removed after testing; the system
continues to use scalar OpenSSH, OpenSSL and WPA packages. Tests ran with
working XTheadVector support and vector access enabled, as described in
[the vector notes](sg2002-vector.md).
Disassembly confirms T-Head vector instructions in the experimental SSH,
WPA and OpenSSL binaries and `libcrypto`, and none in their scalar counterparts.
The emitted vector instructions are predominantly memory/string operations;
this flag does not provide a new vector AES or ChaCha implementation.

## SSH method

The client runs on the USB host and connects directly over USB Ethernet.
Each server variant uses a separate port with the same host key and settings.
Compression is disabled. A ControlMaster connection completes authentication
before timing; a 1 MiB download warms the connection. Each measured transfer
sends 32 MiB, using `busybox dd` from `/dev/zero` for downloads and a host-side
zero buffer to `busybox wc -c` for uploads. Both directions verify byte counts.
There are three repetitions per variant/cipher/direction, with variant order
reversed in the middle repetition. Results exclude storage, WiFi, WAN and
authentication time.

CPU measurements use the change in the board's `/proc/stat` around each remote
transfer. Busy ticks exclude idle and I/O wait; RISC-V reports these counters
in 100 Hz units. CPU seconds per MiB measures work even when throughput is
unchanged. This is whole-board CPU time, including SSH and kernel networking.

## SSH results

Medians of three 32 MiB transfers. Each cell is **MiB/s (CPU seconds/MiB)**;
download means board to host. All runs kept the board CPU 100% busy.

| Cipher/direction | Scalar | Vector OpenSSH | Vector OpenSSH + OpenSSL |
| --- | ---: | ---: | ---: |
| AES-128-GCM download | 4.81 (0.207) | 4.79 (0.208) | 4.80 (0.207) |
| AES-128-GCM upload | 3.13 (0.317) | 3.11 (0.320) | 3.12 (0.318) |
| ChaCha20-Poly1305 download | 8.08 (0.122) | 8.06 (0.122) | 8.06 (0.123) |
| ChaCha20-Poly1305 upload | 4.14 (0.239) | 4.13 (0.239) | 4.13 (0.240) |

For example, AES download CPU time ranged from 6.60–6.76 seconds for scalar
and 6.61–6.77 seconds for vector OpenSSH. ChaCha20 download ranged from
3.90–4.06 and 3.90–4.09 seconds respectively. A separate three-repetition
throughput run without CPU sampling also found no consistent speedup.
These compiler-flag experiments do not demonstrate an SSH benefit.

### Kernel vector paths enabled versus disabled

The same scalar OpenSSH was also tested after booting the same kernel/FIT
with the normal mitigation policy, which disables both vector usercopy and
kernel memcpy. CPU frequency, cipher, transfer size and repetition count
were unchanged. Medians, again **MiB/s (CPU seconds/MiB)**:

| Cipher/direction | Vector paths disabled | Vector paths enabled |
| --- | ---: | ---: |
| AES-128-GCM download | 4.80 (0.207) | 4.81 (0.207) |
| AES-128-GCM upload | 3.11 (0.319) | 3.13 (0.317) |
| ChaCha20-Poly1305 download | 8.06 (0.123) | 8.08 (0.122) |
| ChaCha20-Poly1305 upload | 4.03 (0.245) | 4.14 (0.239) |

Only ChaCha20 upload shows more than a 1% difference: about 3% throughput
and CPU cost. Its CPU times for 32 MiB were 7.78–8.23 seconds disabled and
7.59–7.69 enabled. This is one boot per policy and changes both copy paths
together; it does not isolate patch 0084 or establish a repeatable gain
across boots. **An application benefit from the custom kernel memcpy alone
remains unproven.** Both application-test boots completed without kernel
warnings or data-count failures.

## WPA and crypto method

WPA key derivation uses three batches of 50 `wpa_passphrase` invocations per
variant, reversing order in the middle batch. All variants produce the same
key for the public test SSID `SG2002-vector-benchmark` and passphrase
`benchmark-public-password`. Timings include process startup. This measures
WPA2 passphrase derivation, not association time, WPA3 SAE or EAP.

Local crypto measurements run three repetitions of:

```sh
openssl speed -seconds 3 -elapsed -bytes 16384 -evp aes-128-gcm
openssl speed -seconds 3 -elapsed -bytes 16384 -evp chacha20-poly1305
openssl speed -seconds 3 -elapsed -bytes 16384 -evp sha256
```

Median WPA timings per invocation, including startup:

| Build | Wall time | User + system CPU time |
| --- | ---: | ---: |
| Scalar | 106.2 ms | 105.8 ms |
| Vector WPA tools | 106.4 ms | 106.2 ms |
| Vector WPA tools + OpenSSL | 132.2 ms | 131.8 ms |

WPA-only compilation has no useful effect here. Rebuilding OpenSSL too
increases both elapsed and CPU time by about 25%.

Median OpenSSL throughput, converted from its decimal kB/s output to MiB/s:

| Operation, 16 KiB blocks | Scalar | Vector |
| --- | ---: | ---: |
| AES-128-GCM | 9.30 | 9.31 |
| ChaCha20-Poly1305 | 26.56 | 26.58 |
| SHA-256 | 15.52 | 15.51 |

These bulk operations show no material improvement. They are crypto
microbenchmarks, not HTTPS or TLS connection measurements.

The AIC8800 driver implements `cfg80211` key installation by sending the key
and cipher to its firmware with `MM_KEY_ADD_REQ`, then retaining the returned
hardware key index. See the pinned [key installation callback](https://github.com/radxa-pkg/aic8800/blob/bd11969265809a0fc948f1107c8256bbb2c1aa60/src/SDIO/driver_fw/driver/aic8800/aic8800_fdrv/rwnx_main.c#L2283-L2387)
and [firmware request](https://github.com/radxa-pkg/aic8800/blob/bd11969265809a0fc948f1107c8256bbb2c1aa60/src/SDIO/driver_fw/driver/aic8800/aic8800_fdrv/rwnx_msg_tx.c#L641-L679).
`wpa_supplicant` is not the ordinary WiFi packet-encryption path, so its compiler
flags do not directly accelerate that work. No radio-throughput improvement
is established by these experiments.
