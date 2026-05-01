#!/usr/bin/env bash
# Verify a built release pack against manifest.json and SHA256SUMS.
set -euo pipefail

OUT_DIR="${1:-out}"
MANIFEST="$OUT_DIR/manifest.json"
SUMS="$OUT_DIR/SHA256SUMS"

[ -d "$OUT_DIR" ] || { echo "missing output directory: $OUT_DIR" >&2; exit 2; }
[ -f "$MANIFEST" ] || { echo "missing manifest: $MANIFEST" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 2; }
command -v sha256sum >/dev/null || { echo "sha256sum required" >&2; exit 2; }

sha256() { sha256sum "$1" | awk '{print $1}'; }
sz() { stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1"; }

fail=0

while IFS=$'\t' read -r name expected_hash expected_size; do
  file="$OUT_DIR/$name"
  if [ ! -f "$file" ]; then
    echo "FAIL   $name missing"
    fail=$((fail+1))
    continue
  fi

  actual_hash=$(sha256 "$file")
  actual_size=$(sz "$file")
  status=ok

  if [ "$actual_hash" != "$expected_hash" ]; then
    echo "FAIL   $name sha256 expected=$expected_hash actual=$actual_hash"
    status=fail
    fail=$((fail+1))
  fi

  if [ "$actual_size" != "$expected_size" ]; then
    echo "FAIL   $name size expected=$expected_size actual=$actual_size"
    status=fail
    fail=$((fail+1))
  fi

  [ "$status" = ok ] && echo "ok     $name $actual_hash"
done < <(jq -r '.artifacts | to_entries[] | [.key, .value.sha256, (.value.size_bytes|tostring)] | @tsv' "$MANIFEST")

if [ -f "$SUMS" ]; then
  echo
  (cd "$OUT_DIR" && sha256sum -c SHA256SUMS)
else
  echo
  echo "warn   SHA256SUMS missing"
fi

if jq -e '.build_inputs.kernel.allow_module_mismatch == true' "$MANIFEST" >/dev/null; then
  echo "FAIL   release manifest allows external-kernel module mismatch"
  fail=$((fail+1))
fi

if jq -e '.build_inputs.kernel.variant == "external" and (.build_inputs.kernel.build_provenance == null)' "$MANIFEST" >/dev/null; then
  echo "FAIL   external-kernel release lacks kernel-build.json provenance"
  fail=$((fail+1))
fi

if [ -f "$OUT_DIR/provenance.intoto.json" ]; then
  echo
  jq -e --argjson artifacts "$(jq '.artifacts' "$MANIFEST")" '
    .predicateType == "https://slsa.dev/provenance/v1"
    and ([.subject[] | (($artifacts[.name].sha256 // "") == .digest.sha256)] | all)
  ' "$OUT_DIR/provenance.intoto.json" >/dev/null \
    && echo "ok     provenance subjects match manifest artifacts" \
    || { echo "FAIL   provenance subjects do not match manifest artifacts"; fail=$((fail+1)); }
fi

exit "$fail"
