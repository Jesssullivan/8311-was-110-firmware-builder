#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

command -v git >/dev/null || {
  echo "skipping source stack candidate test (git unavailable)"
  exit 0
}

git config --global --add safe.directory "$TMP/work" >/dev/null 2>&1 || true

WORK="$TMP/work"
REMOTE="$TMP/remote.git"
mkdir -p "$WORK"
git -C "$WORK" init -q
git -C "$WORK" config user.email test@example.invalid
git -C "$WORK" config user.name "Test User"
git -C "$WORK" config commit.gpgsign false
git -C "$WORK" config tag.gpgsign false
mkdir -p "$WORK/dts" "$WORK/image"
printf 'fixture dts\n' > "$WORK/dts/prx126-sfp-pon.dts"
printf 'fixture prx300\n' > "$WORK/image/prx300.mk"
printf 'fixture packages\n' > "$WORK/image/packages.mk"
git -C "$WORK" add .
git -C "$WORK" commit -q -m initial
commit=$(git -C "$WORK" rev-parse HEAD)
git -C "$WORK" branch ugw-8.5.2
git -C "$WORK" -c tag.gpgSign=false tag -a v19.07.8 -m v19.07.8
tag_object=$(git -C "$WORK" rev-parse 'v19.07.8^{tag}')
git clone -q --bare "$WORK" "$REMOTE"

LOCK="$TMP/source-stack-candidates.json"
jq -n \
  --arg repo "$REMOTE" \
  --arg commit "$commit" \
  --arg tag_object "$tag_object" \
  '{
    schema_version: 1,
    kind: "8311-was-110-source-stack-candidates",
    materialization: {
      git_sources: [
        {
          name: "fixture-branch",
          repo: $repo,
          ref: "refs/heads/ugw-8.5.2",
          ref_kind: "branch",
          commit: $commit,
          evidence_paths: [
            "dts/prx126-sfp-pon.dts",
            "image/prx300.mk",
            "image/packages.mk"
          ]
        },
        {
          name: "fixture-tag",
          repo: $repo,
          ref: "refs/tags/v19.07.8",
          ref_kind: "annotated_tag",
          commit: $commit,
          tag_object: $tag_object,
          evidence_paths: []
        }
      ]
    }
  }' > "$LOCK"

"$BASE_DIR/pins/verify-source-stack-candidates.sh" --lock "$LOCK" >/dev/null

OUT="$TMP/out"
"$BASE_DIR/pins/fetch-source-stack-candidates.sh" \
  --lock "$LOCK" \
  --out-dir "$OUT" \
  --only fixture-branch \
  --pack-archives >/dev/null

test -f "$OUT/source-stack.manifest.json"
test -f "$OUT/archives/fixture-branch.tar.gz"
test ! -e "$OUT/archives/fixture-tag.tar.gz"
test -f "$OUT/git/fixture-branch/dts/prx126-sfp-pon.dts"
jq -e '
  .kind == "8311-was-110-source-stack-materialization"
  and (.git_sources | length) == 1
  and .git_sources[0].tree
  and .git_sources[0].archive.sha256
' "$OUT/source-stack.manifest.json" >/dev/null
"$BASE_DIR/pins/verify-source-stack-materialization.sh" \
  --dir "$OUT" \
  --require fixture-branch >/dev/null
if "$BASE_DIR/pins/verify-source-stack-materialization.sh" \
  --dir "$OUT" \
  --require fixture-tag >/dev/null 2>&1; then
  echo "missing required source unexpectedly passed materialization verification" >&2
  exit 1
fi
printf 'dirty\n' >> "$OUT/git/fixture-branch/dts/prx126-sfp-pon.dts"
if "$BASE_DIR/pins/verify-source-stack-materialization.sh" --dir "$OUT" >/dev/null 2>&1; then
  echo "dirty materialized source unexpectedly passed" >&2
  exit 1
fi

jq '.materialization.git_sources[0].commit = "0000000000000000000000000000000000000000"' \
  "$LOCK" > "$TMP/bad-lock.json"
if "$BASE_DIR/pins/verify-source-stack-candidates.sh" --lock "$TMP/bad-lock.json" >/dev/null 2>&1; then
  echo "bad source-stack lock unexpectedly passed" >&2
  exit 1
fi

echo "source stack candidate test passed"
