#!/usr/bin/env bash
# Extract the linux_banner from a vendor kernel.bin.
# kernel.bin is a u-boot legacy uImage (64-byte mkimage header) wrapping a
# compressed (typically LZMA) Linux kernel image. We try direct strings
# first (catches uncompressed builds and some embedded copies), then
# strip the uImage header and walk known compression formats.
set -euo pipefail

KFILE="${1:?usage: $0 <kernel.bin>}"
[ -f "$KFILE" ] || { echo "no such file: $KFILE" >&2; exit 2; }

# Direct pass - works for uncompressed kernels.
DIRECT=$(strings -a -n 16 "$KFILE" | grep -m1 '^Linux version ' || true)
if [ -n "$DIRECT" ]; then
  printf '%s\n' "$DIRECT"
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Strip the 64-byte legacy uImage header.
dd if="$KFILE" bs=64 skip=1 of="$TMP/payload" status=none

try_decompress() {
  local tool="$1"; shift
  command -v "$tool" >/dev/null 2>&1 || return 1
  "$tool" "$@" < "$TMP/payload" > "$TMP/decomp" 2>/dev/null && [ -s "$TMP/decomp" ]
}

if   try_decompress lzma -d -c \
  || try_decompress xz   -d -c -F lzma --single-stream \
  || try_decompress xz   -d -c \
  || try_decompress gzip -d -c \
  || try_decompress lz4  -d -c; then
  BANNER=$(strings -a -n 16 "$TMP/decomp" | grep -m1 '^Linux version ' || true)
  if [ -n "$BANNER" ]; then
    printf '%s\n' "$BANNER"
    exit 0
  fi
fi

echo "(banner not extractable - install lzma/xz/gzip/lz4 and try again, or use binwalk)" >&2
exit 1
