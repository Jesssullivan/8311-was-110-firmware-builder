#!/usr/bin/env bash
# Validate and package a kernel bundle as a deterministic tar for Bazel/RBE.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: pack-kernel-bundle.sh <kernel-bundle-dir> <out.tar>

The bundle must contain:
  kernel.bin
  lib/modules/<kernel-release>/...
  lib/firmware/...              optional
  kernel-build.json             optional, strongly recommended
EOF
  exit 2
}

[ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] && usage
[ "$#" -eq 2 ] || usage

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BUNDLE="${1:?kernel bundle dir required}"
OUT_TAR="${2:?out tar required}"

[ -d "$BUNDLE" ] || { echo "no such bundle directory: $BUNDLE" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 2; }

TAR_BIN="${TAR:-tar}"
if ! command -v "$TAR_BIN" >/dev/null; then
  if [ "$TAR_BIN" = "tar" ] && command -v gtar >/dev/null; then
    TAR_BIN=gtar
  else
    echo "GNU tar required" >&2
    exit 2
  fi
fi

if ! "$TAR_BIN" --version 2>/dev/null | grep -qi 'gnu tar'; then
  if [ "$TAR_BIN" = "tar" ] && command -v gtar >/dev/null && gtar --version 2>/dev/null | grep -qi 'gnu tar'; then
    TAR_BIN=gtar
  else
    echo "GNU tar is required for reproducible --sort/--mtime packaging" >&2
    exit 2
  fi
fi

if ! "$TAR_BIN" --version 2>/dev/null | grep -qi 'gnu tar'; then
  echo "GNU tar is required for reproducible --sort/--mtime packaging" >&2
  exit 2
fi

"$BASE_DIR/audit/verify-kernel-bundle.sh" "$BUNDLE" >/dev/null

sha256_file() { sha256sum "$1" | awk '{print $1}'; }
size_bytes() { stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1"; }

tree_sha256() {
  dir="$1"
  [ -d "$dir" ] || { echo ""; return; }
  (
    cd "$dir"
    find . \( -type f -o -type l \) -print | LC_ALL=C sort | while IFS= read -r rel; do
      clean=${rel#./}
      if [ -L "$rel" ]; then
        printf 'L  %s  %s\n' "$clean" "$(readlink "$rel")"
      else
        printf 'F  %s  %s\n' "$clean" "$(sha256_file "$rel")"
      fi
    done
  ) | sha256sum | awk '{print $1}'
}

check_json_hash() {
  jq_filter="$1"
  label="$2"
  actual="$3"
  json_value=$(jq -r "$jq_filter // empty" "$BUNDLE/kernel-build.json")
  case "$json_value" in
    ""|"TBD"|"null")
      return
      ;;
  esac
  if [ "$json_value" != "$actual" ]; then
    echo "kernel-build.json $label mismatch: expected $actual, found $json_value" >&2
    exit 1
  fi
}

kernel_sha=$(sha256_file "$BUNDLE/kernel.bin")
modules_sha=$(tree_sha256 "$BUNDLE/lib/modules")
firmware_sha=""
[ -d "$BUNDLE/lib/firmware" ] && firmware_sha=$(tree_sha256 "$BUNDLE/lib/firmware")

if [ -f "$BUNDLE/kernel-build.json" ]; then
  check_json_hash '.outputs.kernel_bin_sha256' 'outputs.kernel_bin_sha256' "$kernel_sha"
  check_json_hash '.outputs.modules_tree_sha256' 'outputs.modules_tree_sha256' "$modules_sha"
  [ -n "$firmware_sha" ] && check_json_hash '.outputs.firmware_tree_sha256' 'outputs.firmware_tree_sha256' "$firmware_sha"
fi

mkdir -p "$(dirname -- "$OUT_TAR")"
out_dir=$(cd -- "$(dirname -- "$OUT_TAR")" && pwd)
out_base=$(basename -- "$OUT_TAR")
tmp_tar="$out_dir/.$out_base.tmp.$$"
rm -f "$tmp_tar"

(
  cd "$BUNDLE"
  LC_ALL=C "$TAR_BIN" \
    --sort=name \
    --mtime='UTC 1970-01-01' \
    --owner=0 \
    --group=0 \
    --numeric-owner \
    --mode='u+rwX,go+rX,go-w' \
    -cf "$tmp_tar" .
)

mv "$tmp_tar" "$out_dir/$out_base"

echo "kernel bundle tar: $out_dir/$out_base"
echo "tar sha256:        $(sha256_file "$out_dir/$out_base")"
echo "tar size:          $(size_bytes "$out_dir/$out_base") bytes"
echo "kernel.bin:        $kernel_sha"
echo "modules tree:      $modules_sha"
if [ -n "$firmware_sha" ]; then
  echo "firmware tree:     $firmware_sha"
else
  echo "firmware tree:     absent"
fi
