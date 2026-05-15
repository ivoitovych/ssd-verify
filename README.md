# ssd-verify

Whole-device SSD integrity test: writes AES-CTR pseudorandom data, hashes in parallel, reads back and verifies — N runs. Wipes existing data.

> **WARNING:** This tool overwrites everything on the target device — partition tables, filesystems, all of it. There is no recovery. Read this README before running it.

## Quick start

```bash
sudo ./ssd-verify.sh /dev/disk/by-id/YOUR_DEVICE_ID
```

Runs 10 verification passes with 1 MiB blocks (defaults). The script prompts for explicit `yes/YES` confirmation before any writes. See [Usage](#usage) for arguments and [Recommended workflow](#recommended-workflow) for picking the device path safely.

## What it does

For each of N iterations:

1. Generate a fresh AES-256 key + IV.
2. Encrypt a stream of zeros with AES-256-CTR — producing a deterministic but unpredictable pseudorandom byte stream.
3. Write the stream to the entire raw block device via `dd`, while *in parallel* computing a hash of the same stream as it flows by (via `tee` into a FIFO).
4. Sync, flush kernel buffers, drop page cache.
5. Read the entire device back and hash the result.
6. Compare the two hashes. PASS only if identical.

After N runs, report the count and exit non-zero on any failure.

### Pipeline

Write path:

```
/dev/zero
  -> openssl AES-256-CTR pseudorandom stream
  -> tee
       -> FIFO -> dd -> block device
       -> hash (expected)
```

Read-back path:

```
block device
  -> dd
  -> hash (actual)
```

A run passes only if `expected == actual`.

## Why this design

**Why AES-CTR for the payload?** Modern flash controllers compress and dedupe internally. Writing zeros or constant patterns lets a fake or defective drive cheat — the controller may store one block and lie about the rest. AES-CTR output is statistically indistinguishable from random, so the controller can't compress or dedupe it; every byte has to be stored faithfully. The script does not need cryptographic secrecy — AES-CTR is just a fast pseudorandom stream generator.

**Why hash the source stream, not regenerate it for comparison?** The expected hash is computed from the bytes that *actually flowed through `tee`* on their way to the disk. If anything goes wrong in the generation pipeline (OOM, signal, partial pipe), the expected hash reflects what was really sent, not what should have been sent.

**Why rotating keys per iteration?** Marginal bits can fail probabilistically depending on the bit pattern written. Using a different key each run varies the pattern and improves coverage. Fake-capacity drives fail on run 1 with any data; defective cells may need several runs to surface.

**Why drop page cache before read-back?** Without it, the read pass can hit Linux's cache and return what was *intended* to be written, not what's actually on NAND. `conv=fsync` + `sync` + `blockdev --flushbufs` + `drop_caches` ensures the comparison reads from the device, not from memory.

**What this is NOT.** This is not a power-loss persistence test. A drive with a volatile internal write cache could still pass this script and lose data on sudden power-off. For that, run this script, power-cycle the drive cold, and then do a read-only hash pass.

## Requirements

- Linux (tested on Ubuntu 24.04)
- `bash`, `dd`, `openssl`, `lsblk`, `blockdev`, `awk`, `cut`
- Root
- A block device you are willing to overwrite completely

## Usage

```bash
sudo ./ssd-verify.sh /dev/sdX [runs] [blocksize_MiB]
```

Defaults: 10 runs, 1 MiB block size.

**Use a stable device path.** A suspicious or flaky drive may disconnect and reappear with a different letter (`sda` → `sdb`), and you do *not* want to clobber the wrong disk. Pick the path from `/dev/disk/by-id/`:

```bash
sudo ./ssd-verify.sh /dev/disk/by-id/ata-Vendor_Model_SerialNumber 10 1 2>&1 | tee ssd-verify.log
```

The log is useful for disputes — every run records its random key and IV, so the test is reproducible and inspectable after the fact.

## Example output

```
Device /dev/sda  Size 128035676160 bytes (122104 MiB)  Runs 10  Block 1024 KiB  Hash sha256

=== Run 1/10  key=...  iv=... ===
128035676160 bytes (128 GB, 119 GiB) copied, 598 s, 214 MB/s
128035676160 bytes (128 GB, 119 GiB) copied, 306 s, 418 MB/s
expect a3f1...
actual a3f1...  PASS

=== Run 2/10  key=...  iv=... ===
...

=== 10/10 runs passed ===
```

A failed run looks like:

```
expect 8e21...
actual 4c92...  FAIL
```

Exit code is `0` on a full pass, non-zero if any run failed.

## Safety features

Preflight checks run before any byte is written. The script aborts if any of them fail:

- Block-device validation (refuses to write to a regular file or non-existent path).
- Root check.
- Input validation on `runs` and `blocksize_MiB`.
- Hash algorithm validation — catches typos in the `HASH=` tunable.
- Mount detection — lists any mounted partitions on the target and prompts to unmount before proceeding.
- Swap detection — refuses to run if the target (or any of its partitions) is active swap. Comparison is by canonical device path (not substring), so `sda` will not false-match `sda1`.
- Two separate `yes/YES` confirmation prompts (one for unmounting, one before the writes start).
- Trap handler that kills the background writer on `Ctrl+C` or unexpected exit.

## Cache handling

After each write phase, before reading back:

```bash
sync
blockdev --flushbufs "$D"
echo 3 > /proc/sys/vm/drop_caches
```

This prevents a false PASS caused by Linux serving the read from page cache instead of from the device. See *Why this design* for the rationale.

## How many runs?

- **1–2 runs:** Catches all fake-capacity drives and most defective ones.
- **5 runs:** Solid for typical due-diligence on a used or suspicious drive.
- **10 runs (default):** Covers probabilistic bit failures with comfortable margin.
- **15–20 runs:** Paranoid / endurance burn-in. Note this is also 15–20× the drive's capacity in writes — a stress test in its own right.

## Recommended workflow

List devices:

```bash
lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL
```

Find stable device IDs:

```bash
ls -l /dev/disk/by-id/
```

Run a short pass first, logging output:

```bash
sudo ./ssd-verify.sh /dev/disk/by-id/YOUR_DEVICE_ID 1 1 2>&1 | tee ssd-verify-run1.log
```

If it passes and you want more confidence, run a longer pass:

```bash
sudo ./ssd-verify.sh /dev/disk/by-id/YOUR_DEVICE_ID 10 1 2>&1 | tee ssd-verify-run2.log
```

## Interpreting results

**All runs passed.** The device returned the same data it was told to store. Good sign, but not a full guarantee of long-term reliability.

**One or more runs failed.** Possible causes:

- fake-capacity SSD
- defective flash memory
- controller failure
- USB bridge instability
- cable / enclosure problems
- overheating
- power supply instability
- device disconnect during the test

**The device disappears mid-test.** Also a serious failure. Check the kernel log:

```bash
dmesg -T
```

Look for I/O errors, USB resets, disconnects, controller errors, or SATA/NVMe errors.

## Dispute / evidence notes

If you are testing a suspicious SSD for a seller dispute, keep the full terminal log:

```bash
sudo ./ssd-verify.sh /dev/disk/by-id/YOUR_DEVICE_ID 2 1 2>&1 | tee ssd-verify.log
```

Useful supporting evidence:

```bash
lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL
dmesg -T
smartctl -a /dev/sdX   # if smartmontools is available
```

## Tuning

The hash algorithm is a single tunable at the top of the script:

```bash
HASH=sha256
```

Measured throughput on SHA-NI-accelerated hardware (16 KiB blocks via `openssl speed`):

| Algorithm   | Throughput   | Notes                          |
| ----------- | ------------ | ------------------------------ |
| sha1        | ≈ 2.31 GB/s  | SHA-NI accelerated             |
| sha256      | ≈ 2.15 GB/s  | SHA-NI; default                |
| blake2b512  | ≈ 1.05 GB/s  | Software, modern               |
| sha512      | ≈ 1.00 GB/s  | No SHA-NI for SHA-512 family   |
| sha3-256    | ≈ 0.55 GB/s  | Software only                  |

SHA-256 is the default because the small cost over SHA-1 is trivial on accelerated hardware, and SHA-256 carries more weight if the log ends up in a dispute. On CPUs without SHA-NI the trade-off shifts — benchmark your own machine. The bundled helper script profiles every digest your `openssl` exposes and prints throughput per block size:

```bash
./hash_speed_test.sh 3
```

You can also benchmark the AES-CTR generation side:

```bash
openssl speed -elapsed -seconds 3 -evp aes-256-ctr
```

The script uses `openssl dgst -<alg> -r` rather than coreutils `sha{1,256}sum` because openssl reliably dispatches to SHA-NI; coreutils may or may not, depending on distro build, and can silently become the bottleneck instead of the disk.

## Limitations

`ssd-verify` tells you whether the device returned the same data after a full write/read cycle. It does **not** guarantee:

- long-term data retention
- power-loss safety
- wear endurance
- SMART health correctness
- filesystem-level behavior
- performance consistency
- authenticity of the hardware vendor

It is primarily useful for detecting:

- fake-capacity SSDs
- defective flash
- unstable controllers
- drives that disappear during sustained writes
- drives that silently corrupt data

For wear-endurance, use `fio` or vendor tooling. For SMART health, use `smartctl`. For bit-level diagnosis of failures, use `badblocks -wsv`.

## Related tools

- [`f3`](https://fight-flash-fraud.readthedocs.io/) — fake-flash detector; similar approach but operates on filesystems rather than raw block devices.
- [`h2testw`](https://www.heise.de/download/product/h2testw-50539) — Windows equivalent of `f3`.
- [`badblocks`](https://man7.org/linux/man-pages/man8/badblocks.8.html) — older, simpler four-pattern write-read test.
- [`fio`](https://fio.readthedocs.io/) — general-purpose I/O benchmark; can be configured for verification.

`ssd-verify` differs by writing AES-CTR pseudorandom data (uncompressible, undedupable) to the raw device, with parallel source hashing and rotating per-run keys.

## License

MIT — see [`LICENSE`](./LICENSE).

Use at your own risk. The author is not responsible for data loss, hardware damage, or accidental overwriting of the wrong device.
