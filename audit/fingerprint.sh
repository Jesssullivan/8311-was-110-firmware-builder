#!/usr/bin/env bash
# Walk out/ after a build and emit out/manifest.json describing every
# artifact, every vendor input, and the kernel banner. The manifest is the
# document we sign and ship for audit.
set -euo pipefail

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
OUT_DIR="${1:-$BASE_DIR/out}"
[ -d "$OUT_DIR" ] || { echo "no $OUT_DIR - run build.sh first" >&2; exit 2; }

command -v jq >/dev/null || { echo "jq required" >&2; exit 2; }

sha256() { sha256sum "$1" | awk '{print $1}'; }
sz() { stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1"; }
git_cmd() { git -C "$BASE_DIR" "$@" 2>/dev/null; }

if git_cmd rev-parse --git-dir >/dev/null; then
  GIT_REV=$(git_cmd rev-parse HEAD)
  GIT_REV_SHORT=$(git_cmd rev-parse --short HEAD)
  GIT_TAG=$(git_cmd tag --points-at HEAD | head -n1)
  GIT_DIRTY_JSON=$([ -z "$(git_cmd status --porcelain)" ] && echo false || echo true)
  GIT_EPOCH=$(git_cmd log -1 --format='%at')
else
  GIT_REV="${SOURCE_GIT_REV:-unknown}"
  GIT_REV_SHORT="${SOURCE_GIT_REV_SHORT:-${GIT_REV:0:12}}"
  GIT_TAG="${SOURCE_GIT_TAG:-}"
  case "${SOURCE_GIT_DIRTY:-}" in
    true|false) GIT_DIRTY_JSON="$SOURCE_GIT_DIRTY" ;;
    *) GIT_DIRTY_JSON="null" ;;
  esac
  GIT_EPOCH="${SOURCE_GIT_EPOCH:-0}"
fi
BUILT_ON=$(date -u +%Y-%m-%dT%H:%M:%SZ)

KERNEL_BIN="$OUT_DIR/kernel.bin"
KERNEL_BANNER=""
if [ -f "$KERNEL_BIN" ]; then
  KERNEL_BANNER=$("$BASE_DIR/audit/kernel-banner.sh" "$KERNEL_BIN" 2>/dev/null || echo "(unreadable)")
fi

KERNEL_REBUILT_FROM_SOURCE=false
if [ -f "$OUT_DIR/build-inputs.json" ]; then
  KERNEL_REBUILT_FROM_SOURCE=$(jq -r 'if (.kernel.source == "external:kernel-bundle" and (.kernel.build_provenance != null)) then "true" else "false" end' "$OUT_DIR/build-inputs.json")
fi

artifacts_json() {
  local first=1
  echo "{"
  while IFS= read -r path; do
    local f; f=$(basename "$path")
    [ "$f" = "manifest.json" ] && continue
    [ $first -eq 1 ] || echo ","
    first=0
    printf '  "%s": {"sha256": "%s", "size_bytes": %s}' "$f" "$(sha256 "$path")" "$(sz "$path")"
  done < <(find "$OUT_DIR" -maxdepth 1 -type f -print | sort)
  echo
  echo "}"
}

inputs_json() {
  local pins="$BASE_DIR/pins/inputs.json"
  if [ -f "$pins" ]; then
    jq '.inputs' "$pins"
  else
    echo '{}'
  fi
}

build_inputs_json() {
  local build_inputs="$OUT_DIR/build-inputs.json"
  if [ -f "$build_inputs" ]; then
    jq '.' "$build_inputs"
  else
    echo 'null'
  fi
}

materials_json() {
  local first=1
  echo "{"
  for f in pins/inputs.json flake.nix flake.lock .gitmodules; do
    [ -f "$BASE_DIR/$f" ] || continue
    [ $first -eq 1 ] || echo ","
    first=0
    printf '  "%s": {"sha256": "%s"}' "$f" "$(sha256 "$BASE_DIR/$f")"
  done
  echo
  echo "}"
}

cat > "$OUT_DIR/manifest.json" <<EOF
{
  "schema_version": 1,
  "kind": "8311-was-110-firmware-build-manifest",
  "git": {
    "rev": "$GIT_REV",
    "rev_short": "$GIT_REV_SHORT",
    "tag": "$GIT_TAG",
    "dirty": $GIT_DIRTY_JSON,
    "commit_epoch": $GIT_EPOCH
  },
  "build": {
    "built_on_utc": "$BUILT_ON",
    "host_uname": "$(uname -mrs)",
    "source_date_epoch": $GIT_EPOCH
  },
  "materials": $(materials_json),
  "kernel": {
    "banner": $(printf '%s' "$KERNEL_BANNER" | jq -Rs .),
    "expected_substring": "Linux version 4.9.",
    "rebuilt_from_source": $KERNEL_REBUILT_FROM_SOURCE,
    "cve_baseline_doc": "docs/KERNEL-AUDIT.md"
  },
  "build_inputs": $(build_inputs_json),
  "pinned_inputs": $(inputs_json),
  "artifacts": $(artifacts_json)
}
EOF

echo "wrote $OUT_DIR/manifest.json"
jq -r '.artifacts | to_entries[] | "  \(.key)  \(.value.sha256)"' "$OUT_DIR/manifest.json"
