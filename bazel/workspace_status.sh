#!/usr/bin/env bash
# Workspace status command for Bazel/RBE builds.
set -euo pipefail

if git rev-parse --git-dir >/dev/null 2>&1; then
  rev=$(git rev-parse HEAD)
  rev_short=$(git rev-parse --short HEAD)
  tag=$(git tag --points-at HEAD | head -n1 || true)
  epoch=$(git log -1 --format='%at')
  if [ -z "$(git status --porcelain)" ]; then
    dirty=false
    diff_hash=""
  else
    dirty=true
    diff_hash=$(git diff HEAD | sha256sum | awk '{print $1}')
  fi
else
  rev=unknown
  rev_short=unknown
  tag=
  epoch=0
  dirty=
  diff_hash=
fi

cat <<EOF
WAS110_GIT_REV $rev
WAS110_GIT_REV_SHORT $rev_short
WAS110_GIT_TAG $tag
WAS110_GIT_EPOCH $epoch
WAS110_GIT_DIRTY $dirty
WAS110_GIT_DIFF_HASH $diff_hash
EOF
