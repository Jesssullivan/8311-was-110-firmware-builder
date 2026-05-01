#!/usr/bin/env bash
# Fetch locked public 8311 community release inputs and materialize build blobs.
set -euo pipefail

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
LOCK="$BASE_DIR/pins/public-source-lock.json"
OUT_DIR="$BASE_DIR/vendor-blobs/public-community-inputs"
VENDOR_REPO=""
PINS="$BASE_DIR/pins/inputs.json"
ARCHIVE_DIR=""
UPDATE_PINS=false
FORCE=false
OFFLINE=false

usage() {
  cat >&2 <<'EOF'
usage: pins/fetch-public-inputs.sh [options]

Options:
  --lock <file>          source lock JSON (default: pins/public-source-lock.json)
  --out-dir <dir>        extracted private input dir (default: vendor-blobs/public-community-inputs)
  --vendor-repo <dir>    also create a private Bazel vendor blob repo
  --pins <file>          pins manifest used with --vendor-repo (default: pins/inputs.json)
  --archive-dir <dir>    use pre-staged archives from this directory when present
  --offline              require archives to come from --archive-dir; do not download
  --update-pins          update pins manifest from extracted inputs before creating vendor repo
  --force                replace generated output directories
  -h, --help             show this help

This fetches public 8311 community release artifacts listed in the lock file.
It does not fetch original vendor stock firmware.

With --archive-dir, files are looked up by the asset names recorded in the
lock file. This is the preferred path for internal mirrors and Bazel/RBE
staging: mirror by SHA-256, then materialize from the mirror offline.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --lock)
      LOCK="${2:?--lock requires a file}"
      shift
    ;;
    --out-dir)
      OUT_DIR="${2:?--out-dir requires a directory}"
      shift
    ;;
    --vendor-repo)
      VENDOR_REPO="${2:?--vendor-repo requires a directory}"
      shift
    ;;
    --pins)
      PINS="${2:?--pins requires a file}"
      shift
    ;;
    --archive-dir)
      ARCHIVE_DIR="${2:?--archive-dir requires a directory}"
      shift
    ;;
    --offline)
      OFFLINE=true
    ;;
    --update-pins)
      UPDATE_PINS=true
    ;;
    --force)
      FORCE=true
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
command -v jq >/dev/null || { echo "jq required" >&2; exit 2; }
command -v sha256sum >/dev/null || { echo "sha256sum required" >&2; exit 2; }
command -v 7z >/dev/null || { echo "7z required (use nix develop or install p7zip)" >&2; exit 2; }

if [ -n "$ARCHIVE_DIR" ]; then
  [ -d "$ARCHIVE_DIR" ] || { echo "missing archive dir: $ARCHIVE_DIR" >&2; exit 2; }
  ARCHIVE_DIR=$(cd "$ARCHIVE_DIR" && pwd -P)
elif $OFFLINE; then
  echo "--offline requires --archive-dir" >&2
  exit 2
fi

if ! $OFFLINE; then
  command -v curl >/dev/null || { echo "curl required unless --offline is used" >&2; exit 2; }
fi

if [ -e "$OUT_DIR" ] && [ -n "$(find "$OUT_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
  if ! $FORCE; then
    echo "output dir is not empty: $OUT_DIR (use --force)" >&2
    exit 2
  fi
  rm -rf "$OUT_DIR"
fi

mkdir -p "$OUT_DIR/archives" "$OUT_DIR/bfw" "$OUT_DIR/basic"
OUT_DIR_ABS=$(cd "$OUT_DIR" && pwd -P)

sha256() { sha256sum "$1" | awk '{print $1}'; }
sz() { stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1"; }

fetch_archive() {
  local key="$1" dest="$2" url expected_sha expected_size actual_sha actual_size asset_name staged
  url=$(jq -r ".sources.$key.asset_url" "$LOCK")
  asset_name=$(jq -r ".sources.$key.asset_name" "$LOCK")
  expected_sha=$(jq -r ".sources.$key.asset_sha256" "$LOCK")
  expected_size=$(jq -r ".sources.$key.asset_size_bytes" "$LOCK")

  if [ -n "$ARCHIVE_DIR" ] && [ -f "$ARCHIVE_DIR/$asset_name" ]; then
    staged="$ARCHIVE_DIR/$asset_name"
    echo "use staged $key: $staged"
    if [ "$(cd "$(dirname "$staged")" && pwd -P)/$(basename "$staged")" != "$(cd "$(dirname "$dest")" && pwd -P)/$(basename "$dest")" ]; then
      cp -fL "$staged" "$dest"
    fi
  elif $OFFLINE; then
    echo "missing staged archive for $key: $ARCHIVE_DIR/$asset_name" >&2
    exit 1
  else
    echo "fetch $key: $url"
    curl -fL "$url" -o "$dest"
  fi

  actual_sha=$(sha256 "$dest")
  actual_size=$(sz "$dest")
  if [ "$actual_sha" != "$expected_sha" ]; then
    echo "$key archive sha256 mismatch: expected=$expected_sha actual=$actual_sha" >&2
    exit 1
  fi
  if [ "$actual_size" != "$expected_size" ]; then
    echo "$key archive size mismatch: expected=$expected_size actual=$actual_size" >&2
    exit 1
  fi
}

check_file() {
  local file="$1" expected_sha="$2" expected_size="$3" actual_sha actual_size
  [ -f "$file" ] || { echo "missing extracted file: $file" >&2; exit 1; }
  actual_sha=$(sha256 "$file")
  actual_size=$(sz "$file")
  if [ "$actual_sha" != "$expected_sha" ]; then
    echo "$file sha256 mismatch: expected=$expected_sha actual=$actual_sha" >&2
    exit 1
  fi
  if [ "$actual_size" != "$expected_size" ]; then
    echo "$file size mismatch: expected=$expected_size actual=$actual_size" >&2
    exit 1
  fi
}

BFW_ARCHIVE="$OUT_DIR_ABS/archives/$(jq -r '.sources.bfw_image.asset_name' "$LOCK")"
BASIC_ARCHIVE="$OUT_DIR_ABS/archives/$(jq -r '.sources.basic_image_dir.asset_name' "$LOCK")"

fetch_archive bfw_image "$BFW_ARCHIVE"
fetch_archive basic_image_dir "$BASIC_ARCHIVE"

7z e -y -o"$OUT_DIR_ABS/bfw" "$BFW_ARCHIVE" "$(jq -r '.sources.bfw_image.extract.archive_path' "$LOCK")" >/dev/null
7z e -y -o"$OUT_DIR_ABS/basic" "$BASIC_ARCHIVE" bootcore.bin kernel.bin rootfs.img >/dev/null

check_file \
  "$OUT_DIR_ABS/bfw/local-upgrade.img" \
  "$(jq -r '.sources.bfw_image.extract.sha256' "$LOCK")" \
  "$(jq -r '.sources.bfw_image.extract.size_bytes' "$LOCK")"

for f in bootcore.bin kernel.bin rootfs.img; do
  check_file \
    "$OUT_DIR_ABS/basic/$f" \
    "$(jq -r ".sources.basic_image_dir.extract.files.\"$f\".sha256" "$LOCK")" \
    "$(jq -r ".sources.basic_image_dir.extract.files.\"$f\".size_bytes" "$LOCK")"
done

cp "$LOCK" "$OUT_DIR_ABS/public-source-lock.json"

cat > "$OUT_DIR_ABS/README.md" <<'EOF'
# Public community WAS-110 inputs

Generated by `pins/fetch-public-inputs.sh` from `pins/public-source-lock.json`.
These are public 8311 community release artifacts, not original vendor stock
firmware. Do not commit extracted binaries.
EOF

jq -n \
  --slurpfile lock "$LOCK" \
  --arg bfw_sha "$(sha256 "$OUT_DIR_ABS/bfw/local-upgrade.img")" \
  --arg bootcore_sha "$(sha256 "$OUT_DIR_ABS/basic/bootcore.bin")" \
  --arg kernel_sha "$(sha256 "$OUT_DIR_ABS/basic/kernel.bin")" \
  --arg rootfs_sha "$(sha256 "$OUT_DIR_ABS/basic/rootfs.img")" \
  --argjson bfw_size "$(sz "$OUT_DIR_ABS/bfw/local-upgrade.img")" \
  --argjson bootcore_size "$(sz "$OUT_DIR_ABS/basic/bootcore.bin")" \
  --argjson kernel_size "$(sz "$OUT_DIR_ABS/basic/kernel.bin")" \
  --argjson rootfs_size "$(sz "$OUT_DIR_ABS/basic/rootfs.img")" \
  '{
    schema_version: 1,
    kind: "8311-was-110-public-community-inputs",
    source_lock: $lock[0],
    files: {
      "bfw/local-upgrade.img": {sha256: $bfw_sha, size_bytes: $bfw_size},
      "basic/bootcore.bin": {sha256: $bootcore_sha, size_bytes: $bootcore_size},
      "basic/kernel.bin": {sha256: $kernel_sha, size_bytes: $kernel_size},
      "basic/rootfs.img": {sha256: $rootfs_sha, size_bytes: $rootfs_size}
    }
  }' > "$OUT_DIR_ABS/public-inputs.manifest.json"

(
  cd "$OUT_DIR_ABS"
  sha256sum \
    README.md \
    public-source-lock.json \
    public-inputs.manifest.json \
    archives/"$(basename "$BFW_ARCHIVE")" \
    archives/"$(basename "$BASIC_ARCHIVE")" \
    bfw/local-upgrade.img \
    basic/bootcore.bin \
    basic/kernel.bin \
    basic/rootfs.img > SHA256SUMS
)

echo "created public community inputs: $OUT_DIR_ABS"
echo "  bfw image: $OUT_DIR_ABS/bfw/local-upgrade.img"
echo "  basic dir: $OUT_DIR_ABS/basic"

if [ -n "$VENDOR_REPO" ]; then
  import_args=(--pins "$PINS")
  if $UPDATE_PINS; then
    import_args+=(--update-pins)
    import_args+=(--vendor-version "$(jq -r '.version_label' "$LOCK")")
    import_args+=(--source-url "public-source-lock:$(basename "$LOCK")")
  fi
  $FORCE && import_args+=(--force)
  "$BASE_DIR/pins/import-vendor-blobs.sh" \
    "${import_args[@]}" \
    "$OUT_DIR_ABS/bfw/local-upgrade.img" \
    "$OUT_DIR_ABS/basic" \
    "$VENDOR_REPO"
fi
