#!/usr/bin/env bash
# Assemble the unsigned audit pack for a completed build output directory.
set -euo pipefail

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
OUT_DIR="${1:-$BASE_DIR/out}"

[ -d "$OUT_DIR" ] || { echo "missing output directory: $OUT_DIR" >&2; exit 2; }
command -v sha256sum >/dev/null || { echo "sha256sum required" >&2; exit 2; }

rm -f "$OUT_DIR/manifest.json" "$OUT_DIR/provenance.intoto.json" "$OUT_DIR/audit-summary.md" "$OUT_DIR/SHA256SUMS"
cp "$BASE_DIR/pins/inputs.json" "$OUT_DIR/inputs.json"

"$BASE_DIR/audit/fingerprint.sh" "$OUT_DIR"
"$BASE_DIR/audit/provenance.sh" "$OUT_DIR/manifest.json" "$OUT_DIR/provenance.intoto.json"
"$BASE_DIR/audit/release-summary.sh" "$OUT_DIR" "$OUT_DIR/audit-summary.md"

(
  cd "$OUT_DIR"
  find . -maxdepth 1 -type f ! -name SHA256SUMS -print0 \
    | sort -z \
    | xargs -0 sha256sum > SHA256SUMS
)

echo "wrote $OUT_DIR/SHA256SUMS"
