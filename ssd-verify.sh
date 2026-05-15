#!/bin/bash
# SSD destructive test: AES-CTR pseudorandom data, parallel hash of source,
# read-back hash, N iterations with rotating keys+IVs.
# Usage: sudo ./ssd-verify.sh /dev/sdX [runs] [blocksize_MiB]   (defaults: 10, 1)
set -Eeuo pipefail

# --- Tunables ----------------------------------------------------------------
# Hash algorithm. The hasher runs in parallel with disk I/O, so on fast devices
# it can become the bottleneck. Measured on this host (Intel/AMD with SHA-NI),
# 16 KiB blocks via `openssl speed`:
#   sha1        ≈ 2.31 GB/s   (SHA-NI accelerated)
#   sha256      ≈ 2.15 GB/s   (SHA-NI accelerated; ~7% slower than sha1)
#   blake2b512  ≈ 1.05 GB/s   (software, modern)
#   sha512      ≈ 1.00 GB/s   (no SHA-NI for SHA-512 family)
#   sha3-256    ≈ 0.55 GB/s   (software only)
# SHA-256 is the right default: trivial cost over SHA-1 on accelerated hardware,
# better for evidence/dispute logs, and comfortably faster than SATA/USB SSD
# workloads. On fast NVMe (3–7 GB/s) hashing or AES generation may become the
# bottleneck — this slows the test but does not invalidate it. To check the
# other stage, `openssl speed -evp aes-256-ctr`. On old CPUs without SHA-NI
# (pre-Ice Lake Intel, pre-Zen AMD), benchmark and reconsider.
# We use `openssl dgst -<alg> -r` rather than coreutils `sha{1,256}sum` because
# openssl reliably dispatches to SHA-NI; coreutils may or may not depending on
# distro build → can silently become the bottleneck instead of the disk.
# Cache bypass note (oflag=direct): rejected — (a) requires logical-block
# alignment, so the partial tail from iflag=count_bytes triggers EINVAL;
# (b) generally hurts streaming throughput by losing kernel write-coalescing.
# conv=fsync + blockdev --flushbufs + drop_caches prevents Linux page-cache
# false-PASS on read-back. This is NOT a power-loss persistence test — a drive
# with volatile internal write cache could still need a power-cycle test.
HASH=sha256
# -----------------------------------------------------------------------------

yes_or_die() { read -rp "$1 Type yes/YES: " r; [[ ${r,,} == yes ]] || { echo "Negative selection — aborting."; exit 1; }; }
H() { openssl dgst -"$HASH" -r | cut -d' ' -f1; }

RAW_D="${1:?device required, e.g. /dev/sda}"
D=$(readlink -f "$RAW_D" 2>/dev/null || true)
N="${2:-10}"; BM="${3:-1}"
[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
[[ -n $D && -b $D ]] || { echo "$RAW_D is not a block device"; exit 1; }
[[ $N  =~ ^[1-9][0-9]*$ ]] || { echo "runs must be positive integer"; exit 1; }
[[ $BM =~ ^[1-9][0-9]*$ ]] || { echo "blocksize_MiB must be positive integer"; exit 1; }
# Validate HASH before any destructive action (catches typos in the tunable).
echo test | H >/dev/null 2>&1 || { echo "ERROR: hash '$HASH' not supported by openssl dgst"; exit 1; }

B=$(( BM * 1048576 )); S=$(blockdev --getsize64 "$D")
printf 'Device %s  Size %s bytes (%s MiB)  Runs %s  Block %s KiB  Hash %s\n' \
    "$D" "$S" "$((S/1048576))" "$N" "$((B/1024))" "$HASH"

# Mount check (with mountpoints, reverse-sorted for nested mounts)
M=$(lsblk -nrpo NAME,MOUNTPOINT "$D" | awk '$2!=""{print $1" -> "$2}' | sort -r)
if [[ -n $M ]]; then
    printf '\nWARNING: the following are mounted:\n%s\n' "$M"
    yes_or_die "Unmount them now?"
    while read -r dev _; do umount "$dev" || { echo "umount $dev failed"; exit 1; }; done <<< "$M"
    echo "Unmounted."
fi

# Swap check: compare canonical device paths, NOT substrings/basenames.
# A `grep -qF "$(basename …)"` shortcut would false-match "sda" against the
# line for "sda1" (or vice versa). readlink -f + string equality avoids that.
# Captured separately so an unresolvable path doesn't kill the loop under set -e.
while read -r sw _; do
    [[ $sw == Filename ]] && continue
    sw_real=$(readlink -f "$sw" 2>/dev/null || true)
    [[ -n $sw_real ]] || continue
    for c in $(lsblk -nrpo NAME "$D"); do
        c_real=$(readlink -f "$c" 2>/dev/null || true)
        [[ -n $c_real && $sw_real == "$c_real" ]] && \
            { echo "ERROR: $c is active swap — swapoff first."; exit 1; }
    done
done < /proc/swaps

yes_or_die "DESTROY all data on $D?"

TMPD=$(mktemp -d); F="$TMPD/fifo"; mkfifo "$F"; W=""
cleanup() {
    rc=$?; trap - EXIT INT TERM
    [[ -n ${W:-} ]] && { kill "$W" 2>/dev/null || true; wait "$W" 2>/dev/null || true; }
    rm -rf "$TMPD"; exit "$rc"
}
trap cleanup EXIT INT TERM

ok=0
for i in $(seq 1 "$N"); do
    K=$(openssl rand -hex 32); IV=$(openssl rand -hex 16)
    printf '\n=== Run %d/%d  key=%s  iv=%s ===\n' "$i" "$N" "$K" "$IV"

    dd if="$F" of="$D" bs=$B iflag=fullblock conv=fsync status=progress &
    W=$!
    if ! E=$(dd if=/dev/zero bs=$B count=$S iflag=count_bytes status=none \
            | openssl enc -aes-256-ctr -K "$K" -iv "$IV" -nosalt \
            | tee "$F" | H); then
        echo "FAIL: source pipeline error"
        kill "$W" 2>/dev/null || true; wait "$W" 2>/dev/null || true; W=""; continue
    fi
    wait "$W" || { echo "FAIL: writer error"; W=""; continue; }
    W=""
    sync; blockdev --flushbufs "$D" 2>/dev/null || true
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

    if ! A=$(dd if="$D" bs=$B count=$S iflag=count_bytes,fullblock status=progress | H); then
        echo "FAIL: read-back error"; continue
    fi
    printf 'expect %s\nactual %s  ' "$E" "$A"
    if [[ $E == $A ]]; then echo PASS; ok=$((ok+1)); else echo FAIL; fi
done

printf '\n=== %d/%d runs passed ===\n' "$ok" "$N"
(( ok == N ))

