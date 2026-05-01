#!/usr/bin/env bash
# Enforce the lab release policy on top of checksum/provenance validation.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: verify-release-policy.sh [options] <out-dir-or-manifest.json>

Options:
  --allow-dirty              Do not fail if manifest.git.dirty is true.
  --allow-unpinned           Do not fail on TBD vendor pins. For bring-up only.
  --cve-baseline <csv>       Require an accompanying CVE baseline CSV.

This is the "is this releasable for the lab?" gate. It assumes
verify-release-pack.sh has already checked artifact hashes and provenance
subjects.
EOF
  exit 2
}

ALLOW_DIRTY=false
ALLOW_UNPINNED=false
CVE_BASELINE=""
TARGET=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --allow-dirty)
      ALLOW_DIRTY=true
      ;;
    --allow-unpinned)
      ALLOW_UNPINNED=true
      ;;
    --cve-baseline)
      CVE_BASELINE="${2:-}"
      [ -n "$CVE_BASELINE" ] || usage
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      [ -z "$TARGET" ] || usage
      TARGET="$1"
      ;;
  esac
  shift
done

[ -n "$TARGET" ] || usage
command -v jq >/dev/null || { echo "jq required" >&2; exit 2; }

if [ -d "$TARGET" ]; then
  OUT_DIR="$TARGET"
  MANIFEST="$OUT_DIR/manifest.json"
else
  MANIFEST="$TARGET"
  OUT_DIR=$(cd -- "$(dirname -- "$MANIFEST")" && pwd)
fi

[ -f "$MANIFEST" ] || { echo "missing manifest: $MANIFEST" >&2; exit 2; }

fail=0

ok() {
  printf 'ok     %s\n' "$1"
}

bad() {
  printf 'FAIL   %s\n' "$1"
  fail=$((fail+1))
}

check_jq() {
  label="$1"
  expr="$2"
  if jq -e "$expr" "$MANIFEST" >/dev/null; then
    ok "$label"
  else
    bad "$label"
  fi
}

check_artifact() {
  name="$1"
  if jq -e --arg name "$name" '.artifacts[$name].sha256 | type == "string" and test("^[0-9a-f]{64}$")' "$MANIFEST" >/dev/null; then
    ok "artifact present: $name"
  else
    bad "artifact present: $name"
  fi
}

check_pin() {
  label="$1"
  expr="$2"
  value=$(jq -r "$expr // empty" "$MANIFEST")
  if [ "$value" = "TBD" ] || [ -z "$value" ] || [ "$value" = "null" ]; then
    if $ALLOW_UNPINNED; then
      printf 'warn   %s unpinned\n' "$label"
    else
      bad "$label pinned"
    fi
    return
  fi
  case "$value" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
      ok "$label pinned"
      ;;
    *)
      bad "$label sha256 format"
      ;;
  esac
}

check_jq "manifest kind" '.kind == "8311-was-110-firmware-build-manifest"'
check_jq "known source revision" '.git.rev | type == "string" and . != "" and . != "unknown"'
if ! $ALLOW_DIRTY; then
  check_jq "clean source tree" '.git.dirty == false'
fi

check_pin "bfw image" '.pinned_inputs.bfw_image.sha256'
check_pin "basic bootcore" '.pinned_inputs.basic_image_dir.files["bootcore.bin"].sha256'
check_pin "basic kernel" '.pinned_inputs.basic_image_dir.files["kernel.bin"].sha256'
check_pin "basic rootfs" '.pinned_inputs.basic_image_dir.files["rootfs.img"].sha256'

for artifact in \
  kernel.bin \
  bootcore.bin \
  rootfs.img \
  local-upgrade.img \
  local-upgrade.tar \
  multicast_upgrade.img \
  multicast_reset.img \
  whole-image.img \
  whole-image-endian.img
do
  check_artifact "$artifact"
done

check_jq "module mismatch disabled" '.build_inputs.kernel.allow_module_mismatch != true'
check_jq "kernel banner captured" '.kernel.banner | type == "string" and length > 0 and . != "(unreadable)"'

if jq -e '.build_inputs.kernel.variant == "external"' "$MANIFEST" >/dev/null; then
  check_jq "external kernel provenance present" '.build_inputs.kernel.build_provenance.kind == "8311-was-110-kernel-build"'
  check_jq "external kernel provenance hash present" '.build_inputs.kernel.build_provenance_sha256 | type == "string" and test("^[0-9a-f]{64}$")'
  check_jq "external kernel source rev present" '.build_inputs.kernel.build_provenance.source.rev | type == "string" and . != "" and . != "TBD"'
  check_jq "external kernel module tree pinned" '.build_inputs.kernel.modules_tree_sha256 | type == "string" and test("^[0-9a-f]{64}$")'
  check_jq "external kernel installed modules match source" '.build_inputs.kernel.installed_modules_tree_sha256 == .build_inputs.kernel.modules_tree_sha256'
else
  check_jq "vendor kernel declared as not rebuilt" '.kernel.rebuilt_from_source == false'
fi

if [ -n "$CVE_BASELINE" ]; then
  BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
  if [ ! -f "$CVE_BASELINE" ]; then
    bad "cve baseline exists"
  elif "$BASE_DIR/audit/verify-cve-baseline.sh" "$CVE_BASELINE" "$MANIFEST" >/dev/null; then
    ok "cve baseline"
  else
    bad "cve baseline"
  fi
fi

exit "$fail"
