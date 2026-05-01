#!/usr/bin/env bash
# Validate and optionally compare a WAS-110 fwenv profile.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: verify-fwenv-profile.sh <profile.json> [fwenv-dump.txt|-]

Profile shape:
{
  "schema_version": 1,
  "kind": "8311-was-110-fwenv-profile",
  "required": {
    "8311_fix_vlans": "1"
  },
  "forbidden": [
    "8311_persist_root"
  ]
}

When a fwenv dump is provided, it must contain KEY=value lines as emitted
by `fw_printenv`.
EOF
  exit 2
}

[ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] && usage
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage

PROFILE="$1"
DUMP="${2:-}"

[ -f "$PROFILE" ] || { echo "missing fwenv profile: $PROFILE" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 2; }

jq -e '
  .schema_version == 1
  and .kind == "8311-was-110-fwenv-profile"
  and ((.required // {}) | type == "object")
  and ((.forbidden // []) | type == "array")
  and ([((.required // {}) | to_entries[]) | (.key | startswith("8311_")) and (.value | type == "string")] | all)
  and ([((.forbidden // [])[]) | type == "string" and startswith("8311_")] | all)
' "$PROFILE" >/dev/null || {
  echo "invalid fwenv profile: $PROFILE" >&2
  exit 1
}

if [ -z "$DUMP" ]; then
  echo "ok     fwenv profile schema"
  exit 0
fi

TMP=""
if [ "$DUMP" = "-" ]; then
  TMP=$(mktemp)
  trap 'rm -f "$TMP"' EXIT
  cat > "$TMP"
  DUMP="$TMP"
fi

[ -f "$DUMP" ] || { echo "missing fwenv dump: $DUMP" >&2; exit 2; }

value_for() {
  key="$1"
  awk -v k="$key" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); found = 1; exit } END { if (!found) exit 1 }' "$DUMP"
}

fail=0

while IFS=$'\t' read -r key expected; do
  [ -n "$key" ] || continue
  if actual=$(value_for "$key"); then
    if [ "$actual" = "$expected" ]; then
      printf 'ok     %-28s %s\n' "$key" "$actual"
    else
      printf 'FAIL   %-28s expected=%s actual=%s\n' "$key" "$expected" "$actual"
      fail=$((fail+1))
    fi
  else
    printf 'FAIL   %-28s missing expected=%s\n' "$key" "$expected"
    fail=$((fail+1))
  fi
done < <(jq -r '(.required // {}) | to_entries[] | [.key, .value] | @tsv' "$PROFILE")

while IFS= read -r key; do
  [ -n "$key" ] || continue
  if actual=$(value_for "$key"); then
    printf 'FAIL   %-28s forbidden actual=%s\n' "$key" "$actual"
    fail=$((fail+1))
  else
    printf 'ok     %-28s absent\n' "$key"
  fi
done < <(jq -r '(.forbidden // [])[]' "$PROFILE")

exit "$fail"
