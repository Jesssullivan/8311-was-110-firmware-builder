#!/usr/bin/env bash
# Update pins/inputs.json from reviewed vendor files on disk.
set -euo pipefail

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PINS="$BASE_DIR/pins/inputs.json"
VENDOR_VERSION=""
SOURCE_URL=""

usage() {
  cat >&2 <<'EOF'
usage: pins/update-from-files.sh [options] <bfw-local-upgrade.img> <basic-image-dir>

Options:
  --pins <file>              update an alternate pins manifest (for tests/review)
  --vendor-version <value>   record the reviewed vendor version for both inputs
  --source-url <value>       record the reviewed source URL/path for both inputs
  -h, --help                 show this help

The basic image dir must contain bootcore.bin, kernel.bin, and rootfs.img.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --pins)
      PINS="${2:?--pins requires a file}"
      shift
    ;;
    --vendor-version)
      VENDOR_VERSION="${2:?--vendor-version requires a value}"
      shift
    ;;
    --source-url)
      SOURCE_URL="${2:?--source-url requires a value}"
      shift
    ;;
    -h|--help)
      usage
      exit 0
    ;;
    --)
      shift
      break
    ;;
    -*)
      echo "unexpected option: $1" >&2
      usage
      exit 2
    ;;
    *)
      break
    ;;
  esac
  shift
done

BFW_IMAGE="${1:-}"
BASIC_DIR="${2:-}"

[ -n "$BFW_IMAGE" ] && [ -f "$BFW_IMAGE" ] || { echo "missing BFW image: $BFW_IMAGE" >&2; exit 2; }
[ -n "$BASIC_DIR" ] && [ -d "$BASIC_DIR" ] || { echo "missing basic image dir: $BASIC_DIR" >&2; exit 2; }
[ -f "$PINS" ] || { echo "missing pins manifest: $PINS" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 2; }

for f in bootcore.bin kernel.bin rootfs.img; do
  [ -f "$BASIC_DIR/$f" ] || { echo "missing $BASIC_DIR/$f" >&2; exit 2; }
done

sha256() { sha256sum "$1" | awk '{print $1}'; }
sz() { stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1"; }

FETCHED_ON=$(date -u +%F)

BFW_SHA=$(sha256 "$BFW_IMAGE")
BFW_SIZE=$(sz "$BFW_IMAGE")
BOOTCORE_SHA=$(sha256 "$BASIC_DIR/bootcore.bin")
BOOTCORE_SIZE=$(sz "$BASIC_DIR/bootcore.bin")
KERNEL_SHA=$(sha256 "$BASIC_DIR/kernel.bin")
KERNEL_SIZE=$(sz "$BASIC_DIR/kernel.bin")
ROOTFS_SHA=$(sha256 "$BASIC_DIR/rootfs.img")
ROOTFS_SIZE=$(sz "$BASIC_DIR/rootfs.img")

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

jq \
  --arg fetched_on "$FETCHED_ON" \
  --arg vendor_version "$VENDOR_VERSION" \
  --arg source_url "$SOURCE_URL" \
  --arg bfw_sha "$BFW_SHA" \
  --argjson bfw_size "$BFW_SIZE" \
  --arg bootcore_sha "$BOOTCORE_SHA" \
  --argjson bootcore_size "$BOOTCORE_SIZE" \
  --arg kernel_sha "$KERNEL_SHA" \
  --argjson kernel_size "$KERNEL_SIZE" \
  --arg rootfs_sha "$ROOTFS_SHA" \
  --argjson rootfs_size "$ROOTFS_SIZE" \
  '
  .inputs.bfw_image.sha256 = $bfw_sha
  | .inputs.bfw_image.size_bytes = $bfw_size
  | .inputs.bfw_image.fetched_on = $fetched_on
  | .inputs.basic_image_dir.fetched_on = $fetched_on
  | .inputs.basic_image_dir.files["bootcore.bin"].sha256 = $bootcore_sha
  | .inputs.basic_image_dir.files["bootcore.bin"].size_bytes = $bootcore_size
  | .inputs.basic_image_dir.files["kernel.bin"].sha256 = $kernel_sha
  | .inputs.basic_image_dir.files["kernel.bin"].size_bytes = $kernel_size
  | .inputs.basic_image_dir.files["rootfs.img"].sha256 = $rootfs_sha
  | .inputs.basic_image_dir.files["rootfs.img"].size_bytes = $rootfs_size
  | if $vendor_version != "" then
      .inputs.bfw_image.vendor_version = $vendor_version
      | .inputs.basic_image_dir.vendor_version = $vendor_version
    else . end
  | if $source_url != "" then
      .inputs.bfw_image.source_url = $source_url
      | .inputs.basic_image_dir.source_url = $source_url
    else . end
  ' "$PINS" > "$TMP"

jq -e . "$TMP" >/dev/null
mv "$TMP" "$PINS"
trap - EXIT

echo "updated $PINS"
echo "bfw_image      $BFW_SHA  $BFW_SIZE bytes"
echo "bootcore.bin   $BOOTCORE_SHA  $BOOTCORE_SIZE bytes"
echo "kernel.bin     $KERNEL_SHA  $KERNEL_SIZE bytes"
echo "rootfs.img     $ROOTFS_SHA  $ROOTFS_SIZE bytes"
