#!/usr/bin/env bash
# Verify on-disk vendor blobs against pins/inputs.json.
# Exits 0 if every pinned input matches; nonzero on any mismatch.
# Inputs not yet pinned (sha256 == "TBD") are reported as warnings by default.
# Use --strict in CI/release builds to fail on any unpinned input.
set -euo pipefail

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PINS="$BASE_DIR/pins/inputs.json"
STRICT=false
BFW_IMAGE=""
BASIC_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --strict)
      STRICT=true
    ;;
    --pins)
      PINS="${2:?--pins requires a file}"
      shift
    ;;
    -h|--help)
      echo "usage: $0 [--strict] [--pins inputs.json] [bfw-local-upgrade.img] [basic-image-dir]" >&2
      exit 0
    ;;
    *)
      if [ -z "$BFW_IMAGE" ]; then
        BFW_IMAGE="$1"
      elif [ -z "$BASIC_DIR" ]; then
        BASIC_DIR="$1"
      else
        echo "unexpected argument: $1" >&2
        exit 2
      fi
    ;;
  esac
  shift
done

command -v jq >/dev/null || { echo "jq required" >&2; exit 2; }
[ -f "$PINS" ] || { echo "missing $PINS" >&2; exit 2; }

fail=0
warn=0

sha256() { sha256sum "$1" | awk '{print $1}'; }

check() {
  local label="$1" file="$2" expected="$3"
  if [ -z "$file" ] || [ ! -f "$file" ]; then
    if $STRICT; then
      echo "FAIL   $label  (missing file in strict mode)"
      fail=$((fail+1))
    else
      echo "skip   $label  (no file passed)"
    fi
    return
  fi
  local actual; actual=$(sha256 "$file")
  if [ "$expected" = "TBD" ] || [ "$expected" = "null" ]; then
    if $STRICT; then
      echo "FAIL   $label  $actual  (pin is TBD; strict release mode requires a sha256 in pins/inputs.json)"
      fail=$((fail+1))
    else
      echo "warn   $label  $actual  (pin is TBD - record this hash in pins/inputs.json after vendor review)"
      warn=$((warn+1))
    fi
    return
  fi
  if [ "$actual" = "$expected" ]; then
    echo "ok     $label  $actual"
  else
    echo "FAIL   $label  expected=$expected  actual=$actual"
    fail=$((fail+1))
  fi
}

E_BFW=$(jq -r '.inputs.bfw_image.sha256' "$PINS")
check "bfw_image" "$BFW_IMAGE" "$E_BFW"

if [ -n "$BASIC_DIR" ] && [ -d "$BASIC_DIR" ]; then
  for f in bootcore.bin kernel.bin rootfs.img; do
    E=$(jq -r ".inputs.basic_image_dir.files.\"$f\".sha256" "$PINS")
    check "basic/$f" "$BASIC_DIR/$f" "$E"
  done
elif $STRICT; then
  echo "FAIL   basic_image_dir  (missing directory in strict mode)"
  fail=$((fail+1))
fi

# u-boot blobs are tracked in-tree
WI="$BASE_DIR/whole_image"
for f in uboot-azores-1.0.24.bin uboot-azores.bin uboot-8311.bin uboot-potron.bin uboot-potron-original.bin; do
  if [ -f "$WI/$f" ]; then
    E=$(jq -r ".inputs.uboot_blobs.files.\"$f\".sha256" "$PINS")
    check "uboot/$f" "$WI/$f" "$E"
  fi
done

echo
echo "summary: $fail failures, $warn unpinned inputs"
exit "$fail"
