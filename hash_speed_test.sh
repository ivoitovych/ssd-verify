#!/usr/bin/env bash
# Profile available OpenSSL hash/digest algorithms.
#
# Usage:
#   ./hash-profile.sh [seconds]
#
# Example:
#   ./hash-profile.sh 3
#
# Notes:
# - This is NOT destructive.
# - It benchmarks CPU/hash throughput, not SSD throughput.
# - For your SSD script, the most relevant number is large-block throughput.

set -Eeuo pipefail

SECONDS_PER_TEST="${1:-2}"

[[ "$SECONDS_PER_TEST" =~ ^[1-9][0-9]*$ ]] || {
    echo "Usage: $0 [seconds_per_hash]"
    exit 1
}

command -v openssl >/dev/null || {
    echo "ERROR: openssl not found"
    exit 1
}

# Practical digest candidates. Some systems may not support all of them.
CANDIDATES=(
    md5
    sha1
    sha224
    sha256
    sha384
    sha512
    sha512-224
    sha512-256
    sha3-224
    sha3-256
    sha3-384
    sha3-512
    shake128
    shake256
    blake2s256
    blake2b512
    ripemd160
)

printf 'OpenSSL: %s\n' "$(openssl version)"
printf 'Seconds per test: %s\n\n' "$SECONDS_PER_TEST"

printf '%-14s %14s %14s %14s %14s\n' \
    "HASH" "1024 B" "8192 B" "16384 B" "BEST"
printf '%-14s %14s %14s %14s %14s\n' \
    "----" "------" "------" "-------" "----"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

for alg in "${CANDIDATES[@]}"; do
    if ! openssl dgst "-$alg" </dev/null >/dev/null 2>&1; then
        continue
    fi

    if ! openssl speed -elapsed -seconds "$SECONDS_PER_TEST" -evp "$alg" >"$tmp" 2>/dev/null; then
        continue
    fi

    # Find the final result line. Usually it starts with the algorithm name.
    line="$(awk -v alg="$alg" '$1 == alg { last=$0 } END { print last }' "$tmp")"

    # Some OpenSSL versions normalize names differently, so fallback to last
    # numeric-looking result row.
    if [[ -z "$line" ]]; then
        line="$(awk 'NF >= 7 && $2 ~ /^[0-9.]+k?$/ { last=$0 } END { print last }' "$tmp")"
    fi

    [[ -n "$line" ]] || continue

    # Standard OpenSSL speed columns:
    # alg 16B 64B 256B 1024B 8192B 16384B
    v1024="$(awk '{print $(NF-2)}' <<< "$line")"
    v8192="$(awk '{print $(NF-1)}' <<< "$line")"
    v16384="$(awk '{print $NF}' <<< "$line")"

    # Usually the last column is best for streaming.
    best="$v16384"

    printf '%-14s %14s %14s %14s %14s\n' \
        "$alg" "$v1024" "$v8192" "$v16384" "$best"
done

