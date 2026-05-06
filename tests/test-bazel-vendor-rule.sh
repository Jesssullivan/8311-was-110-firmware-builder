#!/usr/bin/env bash
set -euo pipefail

if ! command -v bazelisk >/dev/null; then
  echo "skipping Bazel vendor repository rule test (bazelisk unavailable)"
  exit 0
fi

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

make_workspace() {
  local name="$1" blobs="$2" pins="$3" workspace="$4"
  mkdir -p "$workspace/bazel"
  cp "$BASE_DIR/bazel/vendor_blobs.bzl" "$workspace/bazel/vendor_blobs.bzl"
  cat > "$workspace/bazel/BUILD.bazel" <<'EOF'
exports_files(["vendor_blobs.bzl"])
EOF
  cat > "$workspace/MODULE.bazel" <<EOF
module(name = "$name")
was110_vendor_blobs_repository = use_repo_rule("//bazel:vendor_blobs.bzl", "was110_vendor_blobs_repository")
was110_vendor_blobs_repository(
    name = "was110_vendor_blobs",
    bfw_image = "$blobs/bfw.img",
    basic_bootcore = "$blobs/basic/bootcore.bin",
    basic_kernel = "$blobs/basic/kernel.bin",
    basic_rootfs = "$blobs/basic/rootfs.img",
    pins_manifest = "$pins",
)
EOF
  cat > "$workspace/BUILD.bazel" <<'EOF'
filegroup(
    name = "use_blobs",
    srcs = [
        "@was110_vendor_blobs//:bfw.img",
        "@was110_vendor_blobs//:basic_bootcore",
        "@was110_vendor_blobs//:basic_kernel",
        "@was110_vendor_blobs//:basic_rootfs",
        "@was110_vendor_blobs//:pins_inputs",
    ],
)
EOF
}

BLOBS="$TMP/blobs"
mkdir -p "$BLOBS/basic"
printf 'bfw\n' > "$BLOBS/bfw.img"
printf 'bootcore\n' > "$BLOBS/basic/bootcore.bin"
printf 'kernel\n' > "$BLOBS/basic/kernel.bin"
printf 'rootfs\n' > "$BLOBS/basic/rootfs.img"

PINS="$TMP/inputs.json"
cp "$BASE_DIR/pins/inputs.json" "$PINS"
"$BASE_DIR/pins/update-from-files.sh" \
  --pins "$PINS" \
  --vendor-version bazel-smoke \
  --source-url file://bazel-smoke \
  "$BLOBS/bfw.img" \
  "$BLOBS/basic" >/dev/null

GOOD_WS="$TMP/good"
make_workspace was110_vendor_rule_positive "$BLOBS" "$PINS" "$GOOD_WS"
(
  cd "$GOOD_WS"
  bazelisk build //:use_blobs --nobuild
) >/dev/null

BAD_BLOBS="$TMP/bad-blobs"
cp -a "$BLOBS" "$BAD_BLOBS"
printf 'tamper\n' >> "$BAD_BLOBS/bfw.img"
BAD_WS="$TMP/bad"
make_workspace was110_vendor_rule_negative "$BAD_BLOBS" "$PINS" "$BAD_WS"
NEGATIVE_LOG="$TMP/negative.log"
if (
  cd "$BAD_WS"
  bazelisk build //:use_blobs --nobuild
) >"$NEGATIVE_LOG" 2>&1; then
  cat "$NEGATIVE_LOG" >&2
  echo "tampered repository rule unexpectedly passed" >&2
  exit 1
fi
grep -q 'bfw_image sha256 mismatch' "$NEGATIVE_LOG"

IMPORTED_REPO="$TMP/imported-repo"
"$BASE_DIR/pins/import-vendor-blobs.sh" \
  --pins "$PINS" \
  "$BLOBS/bfw.img" \
  "$BLOBS/basic" \
  "$IMPORTED_REPO" >/dev/null
"$BASE_DIR/pins/verify-vendor-repo.sh" "$IMPORTED_REPO" >/dev/null

HANDOFF_WS="$TMP/handoff"
mkdir -p "$HANDOFF_WS"
cat > "$HANDOFF_WS/.bazelrc" <<EOF
try-import $IMPORTED_REPO/was110_vendor_blobs.bazelrc
EOF
cat > "$HANDOFF_WS/MODULE.bazel" <<'EOF'
module(name = "was110_vendor_rule_handoff")
EOF
cat > "$HANDOFF_WS/BUILD.bazel" <<'EOF'
filegroup(
    name = "use_blobs",
    srcs = [
        "@was110_vendor_blobs//:bfw.img",
        "@was110_vendor_blobs//:basic_bootcore",
        "@was110_vendor_blobs//:basic_kernel",
        "@was110_vendor_blobs//:basic_rootfs",
        "@was110_vendor_blobs//:pins_inputs",
    ],
)
EOF
(
  cd "$HANDOFF_WS"
  bazelisk build //:use_blobs --nobuild
) >/dev/null

echo "bazel vendor repository rule tests passed"
