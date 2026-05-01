#!/usr/bin/env bash
# Verify a materialized source-stack candidate workspace produced by
# pins/fetch-source-stack-candidates.sh.
set -euo pipefail

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR="$BASE_DIR/vendor-blobs/source-stack-candidates"
MANIFEST=""
REQUIRE_NAMES=()

usage() {
  cat >&2 <<'EOF'
usage: verify-source-stack-materialization.sh [options]

Options:
  --dir <dir>         Materialization root (default: vendor-blobs/source-stack-candidates)
  --manifest <file>   Manifest path (default: <dir>/source-stack.manifest.json)
  --require <name>    Require this source name to be present; repeatable.
  -h, --help          Show this help.

Checks that each checkout recorded in source-stack.manifest.json exists,
that HEAD and tree hashes match the manifest, that expected evidence paths
exist, and that any packed source archive matches its recorded hash/size.
EOF
  exit "${1:-2}"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir)
      WORK_DIR="${2:-}"
      [ -n "$WORK_DIR" ] || usage
      shift
      ;;
    --manifest)
      MANIFEST="${2:-}"
      [ -n "$MANIFEST" ] || usage
      shift
      ;;
    --require)
      REQUIRE_NAMES+=("${2:-}")
      [ -n "${REQUIRE_NAMES[-1]}" ] || usage
      shift
      ;;
    -h|--help)
      usage 0
      ;;
    *)
      usage
      ;;
  esac
  shift
done

command -v git >/dev/null || { echo "git required" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 2; }
command -v sha256sum >/dev/null || { echo "sha256sum required" >&2; exit 2; }

WORK_DIR=$(cd "$WORK_DIR" && pwd)
MANIFEST="${MANIFEST:-$WORK_DIR/source-stack.manifest.json}"
[ -f "$MANIFEST" ] || { echo "missing source-stack manifest: $MANIFEST" >&2; exit 2; }

jq -e '
  .schema_version == 1
  and .kind == "8311-was-110-source-stack-materialization"
  and (.git_sources | type == "array")
' "$MANIFEST" >/dev/null || {
  echo "invalid source-stack materialization manifest: $MANIFEST" >&2
  exit 1
}

sha256() { sha256sum "$1" | awk '{print $1}'; }
sz() { stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1"; }

has_source() {
  local name="$1"
  jq -e --arg name "$name" '.git_sources[] | select(.name == $name)' "$MANIFEST" >/dev/null
}

for required in "${REQUIRE_NAMES[@]}"; do
  has_source "$required" || {
    echo "required source not materialized: $required" >&2
    exit 1
  }
done

count=$(jq '.git_sources | length' "$MANIFEST")
[ "$count" -gt 0 ] || { echo "manifest has no git_sources: $MANIFEST" >&2; exit 1; }

i=0
while [ "$i" -lt "$count" ]; do
  source_json=$(jq -c ".git_sources[$i]" "$MANIFEST")
  name=$(jq -r '.name' <<<"$source_json")
  checkout=$(jq -r '.checkout' <<<"$source_json")
  expected_commit=$(jq -r '.commit' <<<"$source_json")
  expected_tree=$(jq -r '.tree' <<<"$source_json")
  checkout_dir="$WORK_DIR/$checkout"

  [ -d "$checkout_dir/.git" ] || {
    echo "$name checkout missing or not a git checkout: $checkout" >&2
    exit 1
  }

  actual_commit=$(git -C "$checkout_dir" rev-parse HEAD)
  if [ "$actual_commit" != "$expected_commit" ]; then
    echo "$name commit mismatch: expected $expected_commit, got $actual_commit" >&2
    exit 1
  fi

  actual_tree=$(git -C "$checkout_dir" rev-parse 'HEAD^{tree}')
  if [ "$actual_tree" != "$expected_tree" ]; then
    echo "$name tree mismatch: expected $expected_tree, got $actual_tree" >&2
    exit 1
  fi

  if ! git -C "$checkout_dir" diff --quiet --ignore-submodules --; then
    echo "$name checkout has uncommitted changes" >&2
    exit 1
  fi
  untracked=$(git -C "$checkout_dir" ls-files --others --exclude-standard)
  if [ -n "$untracked" ]; then
    echo "$name checkout has untracked files:" >&2
    printf '%s\n' "$untracked" | sed 's/^/  /' >&2
    exit 1
  fi

  while IFS= read -r evidence_path; do
    [ -n "$evidence_path" ] || continue
    [ -e "$checkout_dir/$evidence_path" ] || {
      echo "$name missing evidence path: $evidence_path" >&2
      exit 1
    }
  done < <(jq -r '.evidence_paths[]?' <<<"$source_json")

  archive_path=$(jq -r '.archive.path // empty' <<<"$source_json")
  if [ -n "$archive_path" ]; then
    archive="$WORK_DIR/$archive_path"
    [ -f "$archive" ] || {
      echo "$name archive missing: $archive_path" >&2
      exit 1
    }
    expected_archive_sha=$(jq -r '.archive.sha256' <<<"$source_json")
    actual_archive_sha=$(sha256 "$archive")
    if [ "$actual_archive_sha" != "$expected_archive_sha" ]; then
      echo "$name archive hash mismatch: expected $expected_archive_sha, got $actual_archive_sha" >&2
      exit 1
    fi
    expected_archive_size=$(jq -r '.archive.size_bytes' <<<"$source_json")
    actual_archive_size=$(sz "$archive")
    if [ "$actual_archive_size" != "$expected_archive_size" ]; then
      echo "$name archive size mismatch: expected $expected_archive_size, got $actual_archive_size" >&2
      exit 1
    fi
  fi

  echo "ok     $name  $actual_commit  tree:$actual_tree"
  i=$((i + 1))
done

echo "source stack materialization verified: $WORK_DIR"
