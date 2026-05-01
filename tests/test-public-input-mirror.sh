#!/usr/bin/env bash
set -euo pipefail

if ! command -v 7z >/dev/null; then
  echo "skipping public input mirror test (7z unavailable)"
  exit 0
fi

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

sha256() { sha256sum "$1" | awk '{print $1}'; }
sz() { stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1"; }

MIRROR="$TMP/mirror"
BFW_SRC="$TMP/bfw-src"
BASIC_SRC="$TMP/basic-src"
OUT="$TMP/out"
VENDOR_REPO="$TMP/vendor-repo"
PINS="$TMP/inputs.json"
LOCK="$TMP/public-source-lock.json"
mkdir -p "$MIRROR" "$BFW_SRC" "$BASIC_SRC"

printf 'fixture local upgrade image\n' > "$BFW_SRC/local-upgrade.img"
printf 'fixture bootcore\n' > "$BASIC_SRC/bootcore.bin"
printf 'fixture kernel\n' > "$BASIC_SRC/kernel.bin"
printf 'fixture rootfs\n' > "$BASIC_SRC/rootfs.img"

(
  cd "$BFW_SRC"
  7z a "$MIRROR/fixture-bfw.7z" local-upgrade.img >/dev/null
)
(
  cd "$BASIC_SRC"
  7z a "$MIRROR/fixture-basic.7z" bootcore.bin kernel.bin rootfs.img >/dev/null
)

jq -n \
  --arg bfw_asset_sha "$(sha256 "$MIRROR/fixture-bfw.7z")" \
  --argjson bfw_asset_size "$(sz "$MIRROR/fixture-bfw.7z")" \
  --arg bfw_sha "$(sha256 "$BFW_SRC/local-upgrade.img")" \
  --argjson bfw_size "$(sz "$BFW_SRC/local-upgrade.img")" \
  --arg basic_asset_sha "$(sha256 "$MIRROR/fixture-basic.7z")" \
  --argjson basic_asset_size "$(sz "$MIRROR/fixture-basic.7z")" \
  --arg bootcore_sha "$(sha256 "$BASIC_SRC/bootcore.bin")" \
  --argjson bootcore_size "$(sz "$BASIC_SRC/bootcore.bin")" \
  --arg kernel_sha "$(sha256 "$BASIC_SRC/kernel.bin")" \
  --argjson kernel_size "$(sz "$BASIC_SRC/kernel.bin")" \
  --arg rootfs_sha "$(sha256 "$BASIC_SRC/rootfs.img")" \
  --argjson rootfs_size "$(sz "$BASIC_SRC/rootfs.img")" \
  '{
    schema_version: 1,
    kind: "8311-was-110-public-community-source-lock",
    version_label: "fixture-public-mirror",
    sources: {
      bfw_image: {
        asset_name: "fixture-bfw.7z",
        asset_url: "https://example.invalid/fixture-bfw.7z",
        asset_sha256: $bfw_asset_sha,
        asset_size_bytes: $bfw_asset_size,
        extract: {
          archive_path: "local-upgrade.img",
          output_path: "bfw/local-upgrade.img",
          sha256: $bfw_sha,
          size_bytes: $bfw_size
        }
      },
      basic_image_dir: {
        asset_name: "fixture-basic.7z",
        asset_url: "https://example.invalid/fixture-basic.7z",
        asset_sha256: $basic_asset_sha,
        asset_size_bytes: $basic_asset_size,
        extract: {
          output_dir: "basic",
          files: {
            "bootcore.bin": {sha256: $bootcore_sha, size_bytes: $bootcore_size},
            "kernel.bin": {sha256: $kernel_sha, size_bytes: $kernel_size},
            "rootfs.img": {sha256: $rootfs_sha, size_bytes: $rootfs_size}
          }
        }
      }
    }
  }' > "$LOCK"

cp "$BASE_DIR/pins/inputs.json" "$PINS"

"$BASE_DIR/pins/fetch-public-inputs.sh" \
  --lock "$LOCK" \
  --out-dir "$OUT" \
  --archive-dir "$MIRROR" \
  --offline \
  --pins "$PINS" \
  --vendor-repo "$VENDOR_REPO" \
  --update-pins >/dev/null

cmp "$OUT/bfw/local-upgrade.img" "$BFW_SRC/local-upgrade.img"
cmp "$OUT/basic/bootcore.bin" "$BASIC_SRC/bootcore.bin"
cmp "$OUT/basic/kernel.bin" "$BASIC_SRC/kernel.bin"
cmp "$OUT/basic/rootfs.img" "$BASIC_SRC/rootfs.img"

(
  cd "$OUT"
  sha256sum -c SHA256SUMS >/dev/null
)

jq -e '
  .kind == "8311-was-110-public-community-inputs"
  and .source_lock.version_label == "fixture-public-mirror"
  and .files["basic/kernel.bin"].sha256
' "$OUT/public-inputs.manifest.json" >/dev/null

test "$(jq -r '.inputs.bfw_image.vendor_version' "$PINS")" = "fixture-public-mirror"
test "$(jq -r '.inputs.bfw_image.source_url' "$PINS")" = "public-source-lock:$(basename "$LOCK")"

"$BASE_DIR/pins/verify-vendor-repo.sh" "$VENDOR_REPO" >/dev/null
grep -q 'pins_inputs' "$VENDOR_REPO/BUILD.bazel"

if "$BASE_DIR/pins/fetch-public-inputs.sh" \
  --lock "$LOCK" \
  --out-dir "$TMP/missing-out" \
  --archive-dir "$TMP/missing-mirror" \
  --offline >/dev/null 2>&1; then
  echo "offline fetch unexpectedly passed without staged archives" >&2
  exit 1
fi

echo "public input mirror test passed"
