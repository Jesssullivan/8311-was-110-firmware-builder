#!/usr/bin/env bash
# Verify that public PRX126/OpenWrt source-candidate refs still resolve to
# the commits pinned in pins/source-stack-candidates.json.
set -euo pipefail

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
LOCK="$BASE_DIR/pins/source-stack-candidates.json"

usage() {
  cat <<'EOF'
usage: pins/verify-source-stack-candidates.sh [--lock source-stack-candidates.json]

Checks only public Git refs. It does not download large source trees or AVM
OSP tarballs.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --lock)
      LOCK="${2:?--lock requires a path}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
  shift
done

command -v git >/dev/null || { echo "git required" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 2; }

[ -f "$LOCK" ] || { echo "missing source candidate lock: $LOCK" >&2; exit 2; }
jq -e '.kind == "8311-was-110-source-stack-candidates"' "$LOCK" >/dev/null

count=$(jq '.materialization.git_sources | length' "$LOCK")
[ "$count" -gt 0 ] || { echo "no materialization.git_sources in $LOCK" >&2; exit 1; }

failures=0

check_ref() {
  name="$1"
  repo="$2"
  ref="$3"
  ref_kind="$4"
  expected_commit="$5"
  expected_tag_object="$6"

  if [ "$ref_kind" = "annotated_tag" ]; then
    tag_object=$(git ls-remote "$repo" "$ref" | awk -v ref="$ref" '$2 == ref {print $1}')
    actual_commit=$(git ls-remote "$repo" "$ref^{}" | awk -v ref="$ref^{}" '$2 == ref {print $1}')
    if [ -n "$expected_tag_object" ] && [ "$expected_tag_object" != "null" ] && [ "$tag_object" != "$expected_tag_object" ]; then
      echo "FAIL   $name tag object expected=$expected_tag_object actual=${tag_object:-missing}"
      failures=$((failures + 1))
      return
    fi
  else
    actual_commit=$(git ls-remote "$repo" "$ref" | awk -v ref="$ref" '$2 == ref {print $1}')
  fi

  if [ "$actual_commit" = "$expected_commit" ]; then
    echo "ok     $name  $actual_commit"
  else
    echo "FAIL   $name  expected=$expected_commit actual=${actual_commit:-missing}"
    failures=$((failures + 1))
  fi
}

i=0
while [ "$i" -lt "$count" ]; do
  name=$(jq -r ".materialization.git_sources[$i].name" "$LOCK")
  repo=$(jq -r ".materialization.git_sources[$i].repo" "$LOCK")
  ref=$(jq -r ".materialization.git_sources[$i].ref" "$LOCK")
  ref_kind=$(jq -r ".materialization.git_sources[$i].ref_kind" "$LOCK")
  expected_commit=$(jq -r ".materialization.git_sources[$i].commit" "$LOCK")
  expected_tag_object=$(jq -r ".materialization.git_sources[$i].tag_object // empty" "$LOCK")
  check_ref "$name" "$repo" "$ref" "$ref_kind" "$expected_commit" "$expected_tag_object"
  i=$((i + 1))
done

if [ "$failures" -gt 0 ]; then
  echo "$failures source candidate ref(s) failed verification" >&2
  exit 1
fi
