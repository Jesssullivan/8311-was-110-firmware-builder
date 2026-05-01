#!/usr/bin/env bash
# Materialize the public PRX126/OpenWrt source candidates into an ignored
# local directory for reconstruction and diff work.
set -euo pipefail

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
LOCK="$BASE_DIR/pins/source-stack-candidates.json"
OUT_DIR="$BASE_DIR/vendor-blobs/source-stack-candidates"
FORCE=false
PACK_ARCHIVES=false
VERIFY_FIRST=true
ONLY_NAMES=()

usage() {
  cat <<'EOF'
usage: pins/fetch-source-stack-candidates.sh [options]

Options:
  --lock <file>       source candidate JSON (default: pins/source-stack-candidates.json)
  --out-dir <dir>     output directory (default: vendor-blobs/source-stack-candidates)
  --force             remove and recreate existing checkouts
  --only <name>       materialize only this git source; repeatable
  --pack-archives     also write deterministic-ish source tarballs under archives/
  --skip-verify       skip public ref verification before checkout

This materializes only the public Git source candidates. Large adjacent AVM
OSP tarballs are intentionally opt-in and documented in the lock; they are not
downloaded by this script.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --lock)
      LOCK="${2:?--lock requires a path}"
      shift
      ;;
    --out-dir)
      OUT_DIR="${2:?--out-dir requires a path}"
      shift
      ;;
    --force)
      FORCE=true
      ;;
    --only)
      ONLY_NAMES+=("${2:?--only requires a source name}")
      shift
      ;;
    --pack-archives)
      PACK_ARCHIVES=true
      ;;
    --skip-verify)
      VERIFY_FIRST=false
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

if $VERIFY_FIRST; then
  "$BASE_DIR/pins/verify-source-stack-candidates.sh" --lock "$LOCK" >/dev/null
fi

OUT_DIR_ABS=$(mkdir -p "$OUT_DIR" && cd "$OUT_DIR" && pwd)
CHECKOUT_DIR="$OUT_DIR_ABS/git"
ARCHIVE_DIR="$OUT_DIR_ABS/archives"
mkdir -p "$CHECKOUT_DIR"
$PACK_ARCHIVES && mkdir -p "$ARCHIVE_DIR"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ENTRIES="$TMP/source-stack.entries.jsonl"

sha256() { sha256sum "$1" | awk '{print $1}'; }
sz() { stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1"; }

count=$(jq '.materialization.git_sources | length' "$LOCK")
[ "$count" -gt 0 ] || { echo "no materialization.git_sources in $LOCK" >&2; exit 1; }

selected_source() {
  candidate="$1"
  [ "${#ONLY_NAMES[@]}" -eq 0 ] && return 0
  for only in "${ONLY_NAMES[@]}"; do
    [ "$candidate" = "$only" ] && return 0
  done
  return 1
}

i=0
selected_count=0
while [ "$i" -lt "$count" ]; do
  source_json=$(jq -c ".materialization.git_sources[$i]" "$LOCK")
  name=$(jq -r '.name' <<<"$source_json")
  if ! selected_source "$name"; then
    i=$((i + 1))
    continue
  fi
  selected_count=$((selected_count + 1))
  repo=$(jq -r '.repo' <<<"$source_json")
  ref=$(jq -r '.ref' <<<"$source_json")
  commit=$(jq -r '.commit' <<<"$source_json")
  evidence_paths=$(jq -c '.evidence_paths // []' <<<"$source_json")
  target="$CHECKOUT_DIR/$name"

  if [ -e "$target" ]; then
    if $FORCE; then
      rm -rf "$target"
    else
      echo "$target already exists; pass --force to recreate" >&2
      exit 2
    fi
  fi

  mkdir -p "$target"
  git -C "$target" init -q
  git -C "$target" remote add origin "$repo"
  git -C "$target" fetch --depth 1 --filter=blob:none origin "$ref"
  git -C "$target" checkout -q --detach "$commit"
  actual_commit=$(git -C "$target" rev-parse HEAD)
  [ "$actual_commit" = "$commit" ] || {
    echo "$name checked out $actual_commit, expected $commit" >&2
    exit 1
  }
  tree=$(git -C "$target" rev-parse 'HEAD^{tree}')

  missing_evidence="$TMP/$name.missing"
  : > "$missing_evidence"
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    [ -e "$target/$path" ] || printf '%s\n' "$path" >> "$missing_evidence"
  done < <(jq -r '.[]' <<<"$evidence_paths")
  if [ -s "$missing_evidence" ]; then
    echo "$name missing expected evidence path(s):" >&2
    sed 's/^/  /' "$missing_evidence" >&2
    exit 1
  fi

  archive_json=null
  if $PACK_ARCHIVES; then
    archive="$ARCHIVE_DIR/$name.tar.gz"
    git -C "$target" archive --format=tar --prefix="$name/" HEAD | gzip -n > "$archive"
    archive_json=$(jq -n \
      --arg path "archives/$name.tar.gz" \
      --arg sha "$(sha256 "$archive")" \
      --argjson size "$(sz "$archive")" \
      '{path: $path, sha256: $sha, size_bytes: $size}')
  fi

  jq -n \
    --arg name "$name" \
    --arg repo "$repo" \
    --arg ref "$ref" \
    --arg commit "$commit" \
    --arg tree "$tree" \
    --arg checkout "git/$name" \
    --argjson evidence_paths "$evidence_paths" \
    --argjson archive "$archive_json" \
    '{
      name: $name,
      repo: $repo,
      ref: $ref,
      commit: $commit,
      tree: $tree,
      checkout: $checkout,
      evidence_paths: $evidence_paths,
      archive: $archive
    }' >> "$ENTRIES"

  echo "ok     $name  $commit"
  i=$((i + 1))
done

[ "$selected_count" -gt 0 ] || {
  {
    printf 'no source candidates matched'
    printf ' %s' "${ONLY_NAMES[@]}"
    printf '\n'
  } >&2
  exit 1
}

jq -s \
  --arg generated_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --arg lock "$(cd "$(dirname "$LOCK")" && pwd)/$(basename "$LOCK")" \
  '{
    schema_version: 1,
    kind: "8311-was-110-source-stack-materialization",
    generated_at: $generated_at,
    source_lock: $lock,
    git_sources: .
  }' "$ENTRIES" > "$OUT_DIR_ABS/source-stack.manifest.json"

echo "wrote $OUT_DIR_ABS/source-stack.manifest.json"
