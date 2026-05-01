#!/usr/bin/env bash
# Reach a live WAS-110 over SSH, capture the running kernel + image identity,
# and (if a manifest is supplied) compare against expected hashes.
# Usage: verify-device.sh [--fwenv-profile profile.json] <host> [user] [manifest.json]
set -euo pipefail

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
FWENV_PROFILE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --fwenv-profile)
      FWENV_PROFILE="${2:-}"
      [ -n "$FWENV_PROFILE" ] || { echo "--fwenv-profile requires a file" >&2; exit 2; }
      shift
      ;;
    -h|--help)
      sed -n '2,4p' "$0" >&2
      exit 2
      ;;
    *)
      break
      ;;
  esac
  shift
done

HOST="${1:?usage: $0 [--fwenv-profile profile.json] <host> [user] [manifest.json]}"
USER="${2:-root}"
MANIFEST="${3:-}"

if [ -n "$FWENV_PROFILE" ]; then
  "$BASE_DIR/audit/verify-fwenv-profile.sh" "$FWENV_PROFILE" >/dev/null
fi

SSH=(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "${USER}@${HOST}")
FAIL=0

echo "=== /proc/version"
PROC_VERSION=$("${SSH[@]}" 'cat /proc/version' || true)
printf '%s\n' "$PROC_VERSION"
echo

echo "=== /etc/8311_version"
"${SSH[@]}" 'cat /etc/8311_version 2>/dev/null || echo "(missing - stock or pre-mod build)"'
echo

echo "=== active rootfs slot"
"${SSH[@]}" 'cat /proc/mounts | grep -E "ubi[0-9]+_[0-9]+|rootfs" | head -5'
echo

echo "=== /proc/mtd"
"${SSH[@]}" 'cat /proc/mtd 2>/dev/null'
echo

echo "=== fwenv: 8311_* keys"
FWENV_REPORT=$("${SSH[@]}" 'fw_printenv 2>/dev/null | grep "^8311_" || true')
if [ -n "$FWENV_REPORT" ]; then
  printf '%s\n' "$FWENV_REPORT"
else
  echo "(none set)"
fi
echo

if [ -n "$FWENV_PROFILE" ]; then
  echo "=== fwenv profile ($FWENV_PROFILE)"
  if printf '%s\n' "$FWENV_REPORT" | "$BASE_DIR/audit/verify-fwenv-profile.sh" "$FWENV_PROFILE" -; then
    :
  else
    FAIL=1
  fi
  echo
fi

EXPECTED_KERNEL=""
EXPECTED_BOOTCORE=""
EXPECTED_ROOTFS=""
EXPECTED_KERNEL_SIZE=""
EXPECTED_BOOTCORE_SIZE=""
EXPECTED_ROOTFS_SIZE=""
if [ -n "$MANIFEST" ] && [ -f "$MANIFEST" ]; then
  EXPECTED_KERNEL=$(jq -r '.artifacts["kernel.bin"].sha256 // empty' "$MANIFEST")
  EXPECTED_BOOTCORE=$(jq -r '.artifacts["bootcore.bin"].sha256 // empty' "$MANIFEST")
  EXPECTED_ROOTFS=$(jq -r '.artifacts["rootfs.img"].sha256 // empty' "$MANIFEST")
  EXPECTED_KERNEL_SIZE=$(jq -r '.artifacts["kernel.bin"].size_bytes // empty' "$MANIFEST")
  EXPECTED_BOOTCORE_SIZE=$(jq -r '.artifacts["bootcore.bin"].size_bytes // empty' "$MANIFEST")
  EXPECTED_ROOTFS_SIZE=$(jq -r '.artifacts["rootfs.img"].size_bytes // empty' "$MANIFEST")
  EXPECTED_BANNER=$(jq -r '.kernel.banner // empty' "$MANIFEST")
  echo "=== manifest expected identity ($MANIFEST)"
  echo "kernel banner: $EXPECTED_BANNER"
  echo "kernel.bin:    $EXPECTED_KERNEL"
  echo "bootcore.bin:  $EXPECTED_BOOTCORE"
  echo "rootfs.img:    $EXPECTED_ROOTFS"
  echo
  if [ -n "$EXPECTED_BANNER" ]; then
    case "$PROC_VERSION" in
      *"$EXPECTED_BANNER"*)
        echo "kernel banner: MATCH"
        ;;
      *)
        echo "kernel banner: DIFF-ACTIVE"
        FAIL=1
        ;;
    esac
    echo
  fi
fi

echo "=== UBI volume hashes"
VOLUME_REPORT=$("${SSH[@]}" sh -s -- \
  "$EXPECTED_KERNEL" "$EXPECTED_BOOTCORE" "$EXPECTED_ROOTFS" \
  "$EXPECTED_KERNEL_SIZE" "$EXPECTED_BOOTCORE_SIZE" "$EXPECTED_ROOTFS_SIZE" <<'REMOTE'
EXPECTED_KERNEL="$1"
EXPECTED_BOOTCORE="$2"
EXPECTED_ROOTFS="$3"
EXPECTED_KERNEL_SIZE="$4"
EXPECTED_BOOTCORE_SIZE="$5"
EXPECTED_ROOTFS_SIZE="$6"
ACTIVE_BANK=$(grep -E -o '\brootfsname=rootfs[AB]\b' /proc/cmdline | grep -E -o '[AB]$' || true)
[ -n "$ACTIVE_BANK" ] && echo "active bank: $ACTIVE_BANK"

expected_for() {
  case "$1" in
    kernel*) printf '%s\n' "$EXPECTED_KERNEL" ;;
    bootcore*) printf '%s\n' "$EXPECTED_BOOTCORE" ;;
    rootfs*) printf '%s\n' "$EXPECTED_ROOTFS" ;;
    *) printf '\n' ;;
  esac
}

expected_size_for() {
  case "$1" in
    kernel*) printf '%s\n' "$EXPECTED_KERNEL_SIZE" ;;
    bootcore*) printf '%s\n' "$EXPECTED_BOOTCORE_SIZE" ;;
    rootfs*) printf '%s\n' "$EXPECTED_ROOTFS_SIZE" ;;
    *) printf '\n' ;;
  esac
}

bank_for() {
  printf '%s\n' "$1" | grep -E -o '[AB]$' || true
}

hash_ubi_volume() {
  local name="$1" info id bytes hash expected status bank
  info=$(ubinfo /dev/ubi0 -N "$name" 2>/dev/null) || return 0
  id=$(printf '%s\n' "$info" | awk '/Volume ID:/ {print $3; exit}')
  bytes=$(expected_size_for "$name")
  if [ -z "$bytes" ] || [ "$bytes" = "null" ]; then
    bytes=$(printf '%s\n' "$info" | awk -F'[()]' '/Size:/ {print $2; exit}' | awk '{print $1}')
  fi
  [ -n "$id" ] && [ -n "$bytes" ] || {
    printf '%-10s %-8s unable to determine volume id/size\n' "$name" "UNKNOWN"
    return 0
  }
  hash=$(head -c "$bytes" "/dev/ubi0_$id" | sha256sum | awk '{print $1}')
  expected=$(expected_for "$name")
  status="UNPINNED"
  if [ -n "$expected" ]; then
    if [ "$hash" = "$expected" ]; then
      status="MATCH"
    else
      bank=$(bank_for "$name")
      if [ -n "$ACTIVE_BANK" ] && [ "$bank" != "$ACTIVE_BANK" ]; then
        status="DIFF-INACTIVE"
      else
        status="DIFF-ACTIVE"
      fi
    fi
  fi
  printf '%-10s %-13s %s\n' "$name" "$status" "$hash"
}

if ! command -v ubinfo >/dev/null 2>&1; then
  echo "ubinfo not found on device; cannot hash UBI volumes"
  exit 0
fi

for n in kernelA bootcoreA rootfsA kernelB bootcoreB rootfsB; do
  hash_ubi_volume "$n"
done
REMOTE
)
printf '%s\n' "$VOLUME_REPORT"

if [ -n "$MANIFEST" ] && [ -f "$MANIFEST" ] && printf '%s\n' "$VOLUME_REPORT" | grep -q 'DIFF-ACTIVE'; then
  FAIL=1
fi

exit "$FAIL"
