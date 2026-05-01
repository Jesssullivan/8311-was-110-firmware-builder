#!/usr/bin/env bash
# Validate the external kernel artifact contract consumed by build.sh.
set -euo pipefail

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BUNDLE="${1:?usage: $0 <kernel-bundle-dir>}"

[ -d "$BUNDLE" ] || { echo "no such bundle directory: $BUNDLE" >&2; exit 2; }

KERNEL="$BUNDLE/kernel.bin"
MODULES="$BUNDLE/lib/modules"
FIRMWARE="$BUNDLE/lib/firmware"
BUILD_JSON="$BUNDLE/kernel-build.json"

command -v mkimage >/dev/null || { echo "mkimage required" >&2; exit 2; }

sha256() { sha256sum "$1" | awk '{print $1}'; }
sz() { stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1"; }
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
        printf 'F  %s  %s\n' "$clean" "$(sha256 "$rel")"
      fi
    done
  ) | sha256sum | awk '{print $1}'
}

is_placeholder() {
  case "${1:-}" in
    ""|"TBD"|"null")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

check_json_hash() {
  jq_filter="$1"
  label="$2"
  actual="$3"
  json_value=$(jq -r "$jq_filter // empty" "$BUILD_JSON")
  is_placeholder "$json_value" && return
  if [ "$json_value" != "$actual" ]; then
    echo "$BUILD_JSON $label mismatch: expected $actual, found $json_value" >&2
    exit 1
  fi
}

[ -f "$KERNEL" ] || { echo "missing $KERNEL" >&2; exit 1; }
mkimage -l "$KERNEL" >/dev/null || {
  echo "$KERNEL is not a U-Boot image mkimage can read" >&2
  exit 1
}

[ -d "$MODULES" ] || { echo "missing $MODULES" >&2; exit 1; }
module_count=$(find "$MODULES" -type f \( -name '*.ko' -o -name '*.ko.*' \) | wc -l | awk '{print $1}')
[ "$module_count" -gt 0 ] || {
  echo "$MODULES contains no kernel modules" >&2
  exit 1
}

declared_release=""
if [ -f "$BUILD_JSON" ]; then
  command -v jq >/dev/null || { echo "jq required to validate $BUILD_JSON" >&2; exit 2; }
  jq -e . "$BUILD_JSON" >/dev/null
  declared_release=$(jq -r '.kernel.release // empty' "$BUILD_JSON")
  is_placeholder "$declared_release" && declared_release=""
fi

kernel_sha=$(sha256 "$KERNEL")
modules_sha=$(tree_sha256 "$MODULES")
firmware_sha=""
[ -d "$FIRMWARE" ] && firmware_sha=$(tree_sha256 "$FIRMWARE")

kernel_banner=$("$BASE_DIR/audit/kernel-banner.sh" "$KERNEL" 2>/dev/null || true)
banner_release=$(printf '%s\n' "$kernel_banner" | sed -n 's/^Linux version \([^ ]*\).*/\1/p')
if [ -n "$banner_release" ] && [ -n "$declared_release" ] && [ "$banner_release" != "$declared_release" ]; then
  echo "$BUILD_JSON kernel.release mismatch: banner has $banner_release, json has $declared_release" >&2
  exit 1
fi
kernel_release="$banner_release"
[ -z "$kernel_release" ] && kernel_release="$declared_release"
release_lines=$(find "$MODULES" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | LC_ALL=C sort)
releases=$(printf '%s\n' "$release_lines" | sed '/^$/d' | tr '\n' ' ')
if [ -n "$kernel_release" ] && [ -n "$release_lines" ]; then
  if ! printf '%s\n' "$release_lines" | grep -Fxq "$kernel_release"; then
    echo "module release dirs do not include kernel release $kernel_release: $releases" >&2
    exit 1
  fi
  mismatched_release_dirs=$(printf '%s\n' "$release_lines" | awk -v rel="$kernel_release" '$0 != rel')
  if [ -n "$mismatched_release_dirs" ]; then
    echo "module release dirs contain non-matching releases for kernel $kernel_release: $releases" >&2
    exit 1
  fi
fi

module_vermagic_lines=$(
  while IFS= read -r ko; do
    LC_ALL=C grep -aoh 'vermagic=[^[:space:]]*' "$ko" 2>/dev/null | head -n1 | sed 's/^vermagic=//'
  done < <(find "$MODULES" -type f \( -name '*.ko' -o -name '*.ko.*' \) | LC_ALL=C sort)
  true
)
module_vermagic_lines=$(printf '%s\n' "$module_vermagic_lines" | sed '/^$/d' | LC_ALL=C sort -u)
module_vermagic_releases=$(printf '%s\n' "$module_vermagic_lines" | tr '\n' ' ')
if [ -n "$kernel_release" ] && [ -n "$module_vermagic_lines" ]; then
  mismatched_vermagic=$(printf '%s\n' "$module_vermagic_lines" | awk -v rel="$kernel_release" '$0 != rel')
  if [ -n "$mismatched_vermagic" ]; then
    echo "module vermagic contains non-matching releases for kernel $kernel_release: $module_vermagic_releases" >&2
    exit 1
  fi
fi

if [ -f "$BUILD_JSON" ]; then
  check_json_hash '.outputs.kernel_bin_sha256' 'outputs.kernel_bin_sha256' "$kernel_sha"
  check_json_hash '.outputs.modules_tree_sha256' 'outputs.modules_tree_sha256' "$modules_sha"
  check_json_hash '.outputs.firmware_tree_sha256' 'outputs.firmware_tree_sha256' "$firmware_sha"
fi

echo "kernel bundle: $BUNDLE"
echo "kernel.bin:    $kernel_sha  $(sz "$KERNEL") bytes"
echo "modules:       $module_count files"

[ -n "$releases" ] && echo "module dirs:   $releases"
[ -n "$kernel_release" ] && echo "kernel release: $kernel_release"
[ -n "$module_vermagic_releases" ] && echo "module vermagic releases: $module_vermagic_releases"
echo "modules tree:  $modules_sha"

if [ -d "$FIRMWARE" ]; then
  firmware_count=$(find "$FIRMWARE" -type f | wc -l | awk '{print $1}')
  echo "firmware:      $firmware_count files"
  echo "firmware tree: $firmware_sha"
else
  echo "firmware:      absent"
fi

if [ -f "$BUILD_JSON" ]; then
  echo "build json:    $BUILD_JSON"
fi
