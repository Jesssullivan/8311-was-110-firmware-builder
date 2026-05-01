#!/usr/bin/env bash
# Bazel action runner for the WAS-110 firmware build.
set -euo pipefail

SRC_MANIFEST="${1:?src manifest required}"
BFW_IMAGE="${2:?bfw image required}"
BASIC_BOOTCORE="${3:?basic bootcore required}"
BASIC_KERNEL="${4:?basic kernel required}"
BASIC_ROOTFS="${5:?basic rootfs required}"
KERNEL_BUNDLE_TAR="${6:-}"
OUT_DIR="${7:?output dir required}"
RELEASE="${8:-1}"
STABLE_STATUS="${9:-}"
VOLATILE_STATUS="${10:-}"
PINS_MANIFEST="${11:-}"

realpath_m() {
  realpath -m "$1"
}

SRC_MANIFEST=$(realpath_m "$SRC_MANIFEST")
BFW_IMAGE=$(realpath_m "$BFW_IMAGE")
BASIC_BOOTCORE=$(realpath_m "$BASIC_BOOTCORE")
BASIC_KERNEL=$(realpath_m "$BASIC_KERNEL")
BASIC_ROOTFS=$(realpath_m "$BASIC_ROOTFS")
if [ -n "$KERNEL_BUNDLE_TAR" ]; then
  KERNEL_BUNDLE_TAR=$(realpath_m "$KERNEL_BUNDLE_TAR")
fi
if [ -n "$PINS_MANIFEST" ]; then
  PINS_MANIFEST=$(realpath_m "$PINS_MANIFEST")
fi
mkdir -p "$(dirname "$OUT_DIR")"
OUT_DIR=$(realpath_m "$OUT_DIR")

WORK=$(mktemp -d "${TMPDIR:-/tmp}/was110-bazel.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

status_value() {
  local key="$1" file
  for file in "$STABLE_STATUS" "$VOLATILE_STATUS"; do
    if [ -z "$file" ] || [ ! -f "$file" ]; then
      continue
    fi
    awk -v k="$key" '$1 == k { $1 = ""; sub(/^ /, ""); print; exit }' "$file"
  done | sed -n '1p'
}

status_any() {
  local key value
  for key in "$@"; do
    value=$(status_value "$key")
    if [ -n "$value" ]; then
      printf '%s\n' "$value"
      return 0
    fi
  done
  return 0
}

export SOURCE_BUILD_SYSTEM=bazel
SOURCE_GIT_REV=$(status_any WAS110_GIT_REV BUILD_SCM_REVISION STABLE_GIT_COMMIT GIT_COMMIT)
SOURCE_GIT_REV_SHORT=$(status_any WAS110_GIT_REV_SHORT BUILD_SCM_REVISION_SHORT STABLE_GIT_COMMIT_SHORT GIT_COMMIT_SHORT)
SOURCE_GIT_TAG=$(status_any WAS110_GIT_TAG BUILD_SCM_TAG GIT_TAG)
SOURCE_GIT_DIRTY=$(status_any WAS110_GIT_DIRTY BUILD_SCM_DIRTY GIT_DIRTY)
SOURCE_GIT_EPOCH=$(status_any WAS110_GIT_EPOCH BUILD_SCM_TIMESTAMP SOURCE_DATE_EPOCH)
SOURCE_GIT_DIFF_HASH=$(status_any WAS110_GIT_DIFF_HASH BUILD_SCM_DIFF_HASH GIT_DIFF_HASH)
export SOURCE_GIT_REV SOURCE_GIT_REV_SHORT SOURCE_GIT_TAG SOURCE_GIT_DIRTY SOURCE_GIT_EPOCH SOURCE_GIT_DIFF_HASH

SRC_DIR="$WORK/src"
BASIC_DIR="$WORK/basic"
KERNEL_BUNDLE_DIR="$WORK/kernel-bundle"
mkdir -p "$SRC_DIR" "$BASIC_DIR"

while IFS=$'\t' read -r input_path short_path; do
  [ -n "$input_path" ] || continue
  mkdir -p "$SRC_DIR/$(dirname "$short_path")"
  cp -L "$input_path" "$SRC_DIR/$short_path"
done < "$SRC_MANIFEST"

if [ -n "$PINS_MANIFEST" ]; then
  cp -L "$PINS_MANIFEST" "$SRC_DIR/pins/inputs.json"
fi

cp -L "$BASIC_BOOTCORE" "$BASIC_DIR/bootcore.bin"
cp -L "$BASIC_KERNEL" "$BASIC_DIR/kernel.bin"
cp -L "$BASIC_ROOTFS" "$BASIC_DIR/rootfs.img"

BUILD_ARGS=(
  -i "$BFW_IMAGE"
  -I "$BASIC_DIR"
  --work-dir "$WORK/rootfs-work"
  --out-dir "$OUT_DIR"
)

if [ "$RELEASE" = "1" ]; then
  BUILD_ARGS+=(-R)
fi

if [ -n "$KERNEL_BUNDLE_TAR" ]; then
  mkdir -p "$KERNEL_BUNDLE_DIR"
  tar -xf "$KERNEL_BUNDLE_TAR" -C "$KERNEL_BUNDLE_DIR"
  BUILD_ARGS+=(--kernel-bundle "$KERNEL_BUNDLE_DIR")
fi

cd "$SRC_DIR"
chmod +x build.sh create.sh extract.sh wholeImage.sh audit/*.sh pins/*.sh tools/*.sh tools/*.pl 2>/dev/null || true

for required in \
  8311-xgspon-bypass/8311-detect-config.sh \
  8311-xgspon-bypass/8311-fix-vlans.sh \
  8311-xgspon-bypass/8311-vlans-lib.sh
do
  [ -f "$required" ] || {
    echo "missing required submodule file: $required" >&2
    echo "run git submodule update --init before Bazel/RBE builds" >&2
    exit 2
  }
done

./pins/verify.sh --strict "$BFW_IMAGE" "$BASIC_DIR"
if command -v fakeroot >/dev/null; then
  fakeroot -- env SUDO= ./build.sh "${BUILD_ARGS[@]}"
else
  env SUDO= ./build.sh "${BUILD_ARGS[@]}"
fi
./audit/release-pack.sh "$OUT_DIR"
./audit/verify-release-pack.sh "$OUT_DIR"
