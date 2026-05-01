#!/usr/bin/env bash
# Run post-flash verification and save a timestamped evidence file.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: collect-device-evidence.sh [options] <host> [user]

Options:
  --out-dir <dir>              Release output directory (default: out).
  --manifest <manifest.json>   Manifest path (default: <out-dir>/manifest.json).
  --fwenv-profile <profile>    Expected 8311_* fwenv profile.

The evidence file is written as:
  <out-dir>/verify-<host>-<UTC timestamp>.txt
EOF
  exit 2
}

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
OUT_DIR="$BASE_DIR/out"
MANIFEST=""
FWENV_PROFILE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --out-dir)
      OUT_DIR="${2:-}"
      [ -n "$OUT_DIR" ] || usage
      shift
      ;;
    --manifest)
      MANIFEST="${2:-}"
      [ -n "$MANIFEST" ] || usage
      shift
      ;;
    --fwenv-profile)
      FWENV_PROFILE="${2:-}"
      [ -n "$FWENV_PROFILE" ] || usage
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      break
      ;;
  esac
  shift
done

HOST="${1:-}"
USER="${2:-root}"
[ -n "$HOST" ] || usage

OUT_DIR=$(mkdir -p "$OUT_DIR" && cd "$OUT_DIR" && pwd)
MANIFEST="${MANIFEST:-$OUT_DIR/manifest.json}"
[ -f "$MANIFEST" ] || { echo "missing manifest: $MANIFEST" >&2; exit 2; }

safe_host=$(printf '%s' "$HOST" | tr -c 'A-Za-z0-9_.-' '_')
stamp=$(date -u +%Y%m%dT%H%M%SZ)
evidence="$OUT_DIR/verify-$safe_host-$stamp.txt"

args=()
if [ -n "$FWENV_PROFILE" ]; then
  args+=(--fwenv-profile "$FWENV_PROFILE")
fi
args+=("$HOST" "$USER" "$MANIFEST")

set +e
"$BASE_DIR/audit/verify-device.sh" "${args[@]}" > "$evidence" 2>&1
status=$?
set -e

echo "wrote $evidence"
exit "$status"
