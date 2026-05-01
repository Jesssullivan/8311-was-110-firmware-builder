#!/usr/bin/env bash
# Generate a human-readable audit summary from a release output directory.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: release-summary.sh [out-dir] [summary.md]

Defaults:
  out-dir     out
  summary.md  <out-dir>/audit-summary.md

The summary is for human review. manifest.json, provenance.intoto.json,
and SHA256SUMS remain the machine-verifiable release records.
EOF
  exit 2
}

[ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] && usage

OUT_DIR="${1:-out}"
OUT="${2:-$OUT_DIR/audit-summary.md}"
MANIFEST="$OUT_DIR/manifest.json"
PROVENANCE="$OUT_DIR/provenance.intoto.json"
CVE_BASELINE="$OUT_DIR/cve-baseline.csv"

[ -d "$OUT_DIR" ] || { echo "missing output directory: $OUT_DIR" >&2; exit 2; }
[ -f "$MANIFEST" ] || { echo "missing manifest: $MANIFEST" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 2; }

jq_value() {
  jq -r "$1 // empty" "$MANIFEST"
}

kernel_variant=$(jq_value '.build_inputs.kernel.variant')
kernel_source=$(jq_value '.build_inputs.kernel.source')
kernel_banner=$(jq_value '.kernel.banner')
kernel_rebuilt=$(jq_value '.kernel.rebuilt_from_source')
firmware_version=$(jq_value '.build_inputs.firmware.version')
firmware_variant=$(jq_value '.build_inputs.firmware.variant')
git_rev=$(jq_value '.git.rev')
git_dirty=$(jq_value '.git.dirty')
built_on=$(jq_value '.build.built_on_utc')
source_date_epoch=$(jq_value '.build.source_date_epoch')
module_mismatch=$(jq_value '.build_inputs.kernel.allow_module_mismatch')
kernel_sha=$(jq_value '.artifacts["kernel.bin"].sha256')
bootcore_sha=$(jq_value '.artifacts["bootcore.bin"].sha256')
rootfs_sha=$(jq_value '.artifacts["rootfs.img"].sha256')
bfw_pin=$(jq_value '.pinned_inputs.bfw_image.sha256')
basic_bootcore_pin=$(jq_value '.pinned_inputs.basic_image_dir.files["bootcore.bin"].sha256')
basic_kernel_pin=$(jq_value '.pinned_inputs.basic_image_dir.files["kernel.bin"].sha256')
basic_rootfs_pin=$(jq_value '.pinned_inputs.basic_image_dir.files["rootfs.img"].sha256')

pin_status() {
  value="$1"
  case "$value" in
    ""|"TBD"|"null") printf 'unpinned' ;;
    *) printf 'pinned' ;;
  esac
}

short_hash() {
  value="$1"
  if [ -n "$value" ]; then
    printf '%s' "$value" | cut -c1-16
  fi
}

cve_rows=0
cve_unknown=0
cve_affected=0
cve_patched=0
cve_mitigated=0
if [ -f "$CVE_BASELINE" ]; then
  cve_rows=$(awk -F, 'NR > 1 && NF {rows++} END {print rows+0}' "$CVE_BASELINE")
  cve_unknown=$(awk -F, 'NR > 1 && $8 == "unknown" {rows++} END {print rows+0}' "$CVE_BASELINE")
  cve_affected=$(awk -F, 'NR > 1 && $8 == "affected" {rows++} END {print rows+0}' "$CVE_BASELINE")
  cve_patched=$(awk -F, 'NR > 1 && $8 == "patched" {rows++} END {print rows+0}' "$CVE_BASELINE")
  cve_mitigated=$(awk -F, 'NR > 1 && $8 == "mitigated" {rows++} END {print rows+0}' "$CVE_BASELINE")
fi

device_reports=()
while IFS= read -r report; do
  device_reports+=("$report")
done < <(find "$OUT_DIR" -maxdepth 1 -type f \( -name 'verify-*.txt' -o -name 'device-verify-*.txt' \) | sort)

mkdir -p "$(dirname -- "$OUT")"
{
  printf '# WAS-110 Release Audit Summary\n\n'
  printf '| field | value |\n'
  printf '| --- | --- |\n'
  printf '| firmware version | `%s` |\n' "${firmware_version:-unknown}"
  printf '| firmware variant | `%s` |\n' "${firmware_variant:-unknown}"
  printf '| built on UTC | `%s` |\n' "${built_on:-unknown}"
  printf '| source revision | `%s` |\n' "${git_rev:-unknown}"
  printf '| source dirty | `%s` |\n' "${git_dirty:-unknown}"
  printf '| source date epoch | `%s` |\n' "${source_date_epoch:-unknown}"
  printf '\n'

  printf '## Kernel\n\n'
  printf '| field | value |\n'
  printf '| --- | --- |\n'
  printf '| variant | `%s` |\n' "${kernel_variant:-unknown}"
  printf '| source | `%s` |\n' "${kernel_source:-unknown}"
  printf '| rebuilt from source | `%s` |\n' "${kernel_rebuilt:-unknown}"
  printf '| module mismatch allowed | `%s` |\n' "${module_mismatch:-unknown}"
  printf '| banner | `%s` |\n' "${kernel_banner:-unknown}"
  printf '| kernel.bin sha256 | `%s` |\n' "${kernel_sha:-unknown}"

  if [ "$kernel_variant" = "external" ]; then
    printf '| kernel provenance | `%s` |\n' "$(jq_value '.build_inputs.kernel.build_provenance.kind')"
    printf '| kernel source rev | `%s` |\n' "$(jq_value '.build_inputs.kernel.build_provenance.source.rev')"
    printf '| modules tree sha256 | `%s` |\n' "$(jq_value '.build_inputs.kernel.modules_tree_sha256')"
    printf '| installed modules tree sha256 | `%s` |\n' "$(jq_value '.build_inputs.kernel.installed_modules_tree_sha256')"
  fi
  printf '\n'

  printf '## Vendor Pins\n\n'
  printf '| input | status | sha256 |\n'
  printf '| --- | --- | --- |\n'
  printf '| bfw image | %s | `%s` |\n' "$(pin_status "$bfw_pin")" "${bfw_pin:-}"
  printf '| basic bootcore | %s | `%s` |\n' "$(pin_status "$basic_bootcore_pin")" "${basic_bootcore_pin:-}"
  printf '| basic kernel | %s | `%s` |\n' "$(pin_status "$basic_kernel_pin")" "${basic_kernel_pin:-}"
  printf '| basic rootfs | %s | `%s` |\n' "$(pin_status "$basic_rootfs_pin")" "${basic_rootfs_pin:-}"
  printf '\n'

  printf '## Core Artifacts\n\n'
  printf '| artifact | sha256 prefix |\n'
  printf '| --- | --- |\n'
  printf '| kernel.bin | `%s` |\n' "$(short_hash "$kernel_sha")"
  printf '| bootcore.bin | `%s` |\n' "$(short_hash "$bootcore_sha")"
  printf '| rootfs.img | `%s` |\n' "$(short_hash "$rootfs_sha")"
  jq -r '.artifacts | keys[]' "$MANIFEST" | sort | while IFS= read -r artifact; do
    case "$artifact" in
      kernel.bin|bootcore.bin|rootfs.img) continue ;;
    esac
    sha=$(jq -r --arg artifact "$artifact" '.artifacts[$artifact].sha256 // empty' "$MANIFEST")
    printf '| %s | `%s` |\n' "$artifact" "$(short_hash "$sha")"
  done
  printf '\n'

  printf '## CVE Baseline\n\n'
  if [ -f "$CVE_BASELINE" ]; then
    printf '| field | value |\n'
    printf '| --- | --- |\n'
    printf '| baseline file | `%s` |\n' "$(basename "$CVE_BASELINE")"
    printf '| rows | `%s` |\n' "$cve_rows"
    printf '| unknown | `%s` |\n' "$cve_unknown"
    printf '| affected | `%s` |\n' "$cve_affected"
    printf '| patched | `%s` |\n' "$cve_patched"
    printf '| mitigated | `%s` |\n' "$cve_mitigated"
  else
    printf 'No `cve-baseline.csv` was included in this release directory.\n'
  fi
  printf '\n'

  printf '## Device Evidence\n\n'
  if [ "${#device_reports[@]}" -gt 0 ]; then
    printf '| report | active diffs | matches |\n'
    printf '| --- | --- | --- |\n'
    for report in "${device_reports[@]}"; do
      active_diffs=$(grep -c 'DIFF-ACTIVE' "$report" || true)
      matches=$(grep -c 'MATCH' "$report" || true)
      printf '| `%s` | `%s` | `%s` |\n' "$(basename "$report")" "$active_diffs" "$matches"
    done
  else
    printf 'No post-flash verification reports were found in this release directory.\n'
  fi
  printf '\n'

  printf '## Machine Records\n\n'
  printf '%s\n' '- `manifest.json`: artifact hashes, pins, kernel banner, build inputs'
  if [ -f "$PROVENANCE" ]; then
    printf '%s\n' '- `provenance.intoto.json`: in-toto/SLSA-shaped provenance statement'
  fi
  printf '%s\n' '- `SHA256SUMS`: signed checksum set for release-pack contents'
} > "$OUT"

echo "wrote $OUT"
