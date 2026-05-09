#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

required=(
  "$BASE_DIR/MODULE.bazel"
  "$BASE_DIR/BUILD.bazel"
  "$BASE_DIR/bazel/was110_firmware.bzl"
  "$BASE_DIR/bazel/vendor_blobs.bzl"
  "$BASE_DIR/bazel/BUILD.bazel"
  "$BASE_DIR/bazel/platforms/BUILD.bazel"
  "$BASE_DIR/bazel/build_action.sh"
  "$BASE_DIR/bazel/workspace_status.sh"
  "$BASE_DIR/containers/was110-rbe/Dockerfile"
  "$BASE_DIR/docs/BAZEL-RBE.md"
  "$BASE_DIR/docs/SOURCE-TRACE.md"
  "$BASE_DIR/docs/VENDOR-BLOBS.md"
  "$BASE_DIR/pins/fetch-source-stack-candidates.sh"
  "$BASE_DIR/pins/verify-source-stack-materialization.sh"
  "$BASE_DIR/pins/verify-source-stack-candidates.sh"
  "$BASE_DIR/pins/import-vendor-blobs.sh"
  "$BASE_DIR/pins/verify-vendor-repo.sh"
  "$BASE_DIR/tests/bazel/BUILD.bazel"
  "$BASE_DIR/tests/test-bazel-vendor-rule.sh"
  "$BASE_DIR/tests/test-public-input-mirror.sh"
  "$BASE_DIR/tests/test-source-stack-candidates.sh"
)

for f in "${required[@]}"; do
  [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }
done

grep -q 'was110_firmware = rule' "$BASE_DIR/bazel/was110_firmware.bzl"
grep -q 'was110_vendor_blobs_repository = repository_rule' "$BASE_DIR/bazel/vendor_blobs.bzl"
grep -q 'ctx.actions.declare_directory' "$BASE_DIR/bazel/was110_firmware.bzl"
grep -q 'pins_manifest' "$BASE_DIR/bazel/was110_firmware.bzl"
grep -q 'pins_inputs' "$BASE_DIR/bazel/vendor_blobs.bzl"
grep -q 'verify_pins' "$BASE_DIR/bazel/vendor_blobs.bzl"
grep -q 'verify-vendor-repo.sh' "$BASE_DIR/docs/VENDOR-BLOBS.md"
grep -q 'public-source-lock.json' "$BASE_DIR/docs/SOURCE-TRACE.md"
grep -q -- '--offline' "$BASE_DIR/pins/fetch-public-inputs.sh"
grep -q -- '--archive-dir' "$BASE_DIR/pins/fetch-public-inputs.sh"
jq -e '.materialization.git_sources | length > 0' "$BASE_DIR/pins/source-stack-candidates.json" >/dev/null
grep -q 'verify-source-stack-candidates.sh' "$BASE_DIR/docs/PUBLIC-SOURCES.md"
grep -q 'verify-source-stack-materialization.sh' "$BASE_DIR/docs/PUBLIC-SOURCES.md"
grep -q -- '--pack-archives' "$BASE_DIR/pins/fetch-source-stack-candidates.sh"
grep -q 'no-remote-exec' "$BASE_DIR/docs/BAZEL-RBE.md"
grep -q 'Public mirror / staging model' "$BASE_DIR/docs/BAZEL-RBE.md"
grep -q 'import-vendor-blobs.sh' "$BASE_DIR/docs/BAZEL-RBE.md"
grep -q 'GF_BAZEL_INJECT_REPOSITORIES' "$BASE_DIR/docs/BAZEL-RBE.md"
grep -q 'was110_vendor_blobs.env' "$BASE_DIR/docs/BAZEL-RBE.md"
grep -q 'was110_vendor_blobs.bazelrc' "$BASE_DIR/docs/BAZEL-RBE.md"
grep -q 'was110_vendor_blobs.handoff.json' "$BASE_DIR/docs/BAZEL-RBE.md"
grep -q 'BAZEL_DISTDIR' "$BASE_DIR/docs/BAZEL-RBE.md"
grep -q 'BAZEL_REPOSITORY_CACHE' "$BASE_DIR/docs/BAZEL-RBE.md"
grep -q 'private' "$BASE_DIR/docs/BAZEL-RBE.md"
grep -q 'was110_vendor_blobs.env' "$BASE_DIR/pins/import-vendor-blobs.sh"
grep -q 'was110_vendor_blobs.handoff.json' "$BASE_DIR/pins/verify-vendor-repo.sh"
grep -q '//bazel:srcs' "$BASE_DIR/BUILD.bazel"
grep -q '//bazel/platforms:srcs' "$BASE_DIR/BUILD.bazel"
grep -q 'was110_rbe_linux' "$BASE_DIR/bazel/platforms/BUILD.bazel"
grep -q 'u-boot-tools' "$BASE_DIR/containers/was110-rbe/Dockerfile"
grep -q 'python3' "$BASE_DIR/containers/was110-rbe/Dockerfile"
grep -q 'WAS110_GIT_REV' "$BASE_DIR/bazel/workspace_status.sh"
grep -q 'docs/\*\*' "$BASE_DIR/BUILD.bazel"
grep -q 'flake.nix' "$BASE_DIR/BUILD.bazel"
grep -q 'public_vendor_handoff_fixture' "$BASE_DIR/BUILD.bazel"
grep -q 'requires-was110-public-vendor-repo' "$BASE_DIR/BUILD.bazel"
grep -q 'analysis_fixture' "$BASE_DIR/tests/bazel/BUILD.bazel"
grep -q 'bfw_image sha256 mismatch' "$BASE_DIR/tests/test-bazel-vendor-rule.sh"

echo "bazel bridge text checks passed"
