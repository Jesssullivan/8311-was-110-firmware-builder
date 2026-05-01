#!/usr/bin/env bash
# Verify pins/inputs.json matches pins/public-source-lock.json.
set -euo pipefail

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
LOCK="$BASE_DIR/pins/public-source-lock.json"
PINS="$BASE_DIR/pins/inputs.json"

usage() {
  cat >&2 <<'EOF'
usage: pins/verify-public-source-lock.sh [--lock public-source-lock.json] [--pins inputs.json]

Checks that the committed BFW/basic pins match the locked public community
source trace. This does not download blobs.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --lock)
      LOCK="${2:?--lock requires a file}"
      shift
    ;;
    --pins)
      PINS="${2:?--pins requires a file}"
      shift
    ;;
    -h|--help)
      usage
      exit 0
    ;;
    *)
      echo "unexpected argument: $1" >&2
      usage
      exit 2
    ;;
  esac
  shift
done

[ -f "$LOCK" ] || { echo "missing source lock: $LOCK" >&2; exit 2; }
[ -f "$PINS" ] || { echo "missing pins manifest: $PINS" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 2; }

fail=0

check() {
  local label="$1" actual_expr="$2" expected_expr="$3" actual expected
  actual=$(jq -r "$actual_expr" "$PINS")
  expected=$(jq -r "$expected_expr" "$LOCK")
  if [ "$actual" = "$expected" ]; then
    echo "ok     $label  $actual"
  else
    echo "FAIL   $label  expected=$expected actual=$actual"
    fail=$((fail+1))
  fi
}

check \
  bfw_image.sha256 \
  '.inputs.bfw_image.sha256' \
  '.sources.bfw_image.extract.sha256'
check \
  bfw_image.size_bytes \
  '.inputs.bfw_image.size_bytes | tostring' \
  '.sources.bfw_image.extract.size_bytes | tostring'

for f in bootcore.bin kernel.bin rootfs.img; do
  check \
    "basic/$f.sha256" \
    ".inputs.basic_image_dir.files.\"$f\".sha256" \
    ".sources.basic_image_dir.extract.files.\"$f\".sha256"
  check \
    "basic/$f.size_bytes" \
    ".inputs.basic_image_dir.files.\"$f\".size_bytes | tostring" \
    ".sources.basic_image_dir.extract.files.\"$f\".size_bytes | tostring"
done

label=$(jq -r '.version_label' "$LOCK")
for path in '.inputs.bfw_image.vendor_version' '.inputs.basic_image_dir.vendor_version'; do
  actual=$(jq -r "$path" "$PINS")
  if [ "$actual" = "$label" ]; then
    echo "ok     $path  $actual"
  else
    echo "FAIL   $path  expected=$label actual=$actual"
    fail=$((fail+1))
  fi
done

if jq -e '.source_dependencies["8311-xgspon-bypass"].rev' "$LOCK" >/dev/null; then
  expected=$(jq -r '.source_dependencies["8311-xgspon-bypass"].rev' "$LOCK")
  if command -v git >/dev/null && git -C "$BASE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    actual=$(git -C "$BASE_DIR" ls-tree HEAD 8311-xgspon-bypass | awk '{print $3}')
    if [ "$actual" = "$expected" ]; then
      echo "ok     source_dependency.8311-xgspon-bypass.rev  $actual"
    else
      echo "FAIL   source_dependency.8311-xgspon-bypass.rev  expected=$expected actual=$actual"
      fail=$((fail+1))
    fi
  else
    echo "warn   source_dependency.8311-xgspon-bypass.rev not checked outside a git worktree"
  fi
fi

echo
echo "summary: $fail failures"
exit "$fail"
