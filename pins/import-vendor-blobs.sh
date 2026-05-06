#!/usr/bin/env bash
# Create a private Bazel repository from reviewed WAS-110 vendor blobs.
set -euo pipefail

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PINS="$BASE_DIR/pins/inputs.json"
UPDATE_PINS=false
FORCE=false
MODE=copy
VENDOR_VERSION=""
SOURCE_URL=""
KERNEL_BUNDLE_TAR=""
OUT_DIR=""
VISIBILITY=("@//:__pkg__")
VISIBILITY_SET=false
POSITIONAL=()

usage() {
  cat >&2 <<'EOF'
usage: pins/import-vendor-blobs.sh [options] <bfw-local-upgrade.img> <basic-image-dir> <out-dir>

Options:
  --pins <file>              use an alternate pins manifest
  --update-pins              update the pins manifest from the supplied files before verifying
  --vendor-version <value>   version recorded when --update-pins is used
  --source-url <value>       source URL/path recorded when --update-pins is used
  --kernel-bundle-tar <file> include a reviewed external kernel bundle tar
  --visibility <label>       Bazel visibility for exported blob labels; repeatable
                             default: @//:__pkg__
  --public                   shorthand for --visibility //visibility:public
  --copy                     copy blobs into <out-dir> (default; best for RBE/CAS handoff)
  --symlink                  symlink blobs into <out-dir> (local-only convenience)
  --force                    replace generated files in an existing <out-dir>
  -h, --help                 show this help

The basic image dir must contain bootcore.bin, kernel.bin, and rootfs.img.
The output dir is a private Bazel repository. Do not commit it.
EOF
}

add_visibility() {
  if ! $VISIBILITY_SET; then
    VISIBILITY=()
    VISIBILITY_SET=true
  fi
  VISIBILITY+=("$1")
}

while [ $# -gt 0 ]; do
  case "$1" in
    --pins)
      PINS="${2:?--pins requires a file}"
      shift
    ;;
    --update-pins)
      UPDATE_PINS=true
    ;;
    --vendor-version)
      VENDOR_VERSION="${2:?--vendor-version requires a value}"
      shift
    ;;
    --source-url)
      SOURCE_URL="${2:?--source-url requires a value}"
      shift
    ;;
    --kernel-bundle-tar)
      KERNEL_BUNDLE_TAR="${2:?--kernel-bundle-tar requires a file}"
      shift
    ;;
    --visibility)
      add_visibility "${2:?--visibility requires a Bazel visibility label}"
      shift
    ;;
    --public)
      add_visibility "//visibility:public"
    ;;
    --copy)
      MODE=copy
    ;;
    --symlink)
      MODE=symlink
    ;;
    --force)
      FORCE=true
    ;;
    -h|--help)
      usage
      exit 0
    ;;
    --)
      shift
      while [ $# -gt 0 ]; do
        POSITIONAL+=("$1")
        shift
      done
      break
    ;;
    -*)
      echo "unexpected option: $1" >&2
      usage
      exit 2
    ;;
    *)
      POSITIONAL+=("$1")
    ;;
  esac
  shift
done

if [ "${#POSITIONAL[@]}" -gt 3 ]; then
  echo "too many positional arguments" >&2
  usage
  exit 2
fi

BFW_IMAGE="${POSITIONAL[0]:-}"
BASIC_DIR="${POSITIONAL[1]:-}"
OUT_DIR="${POSITIONAL[2]:-$OUT_DIR}"

if [ -z "$BFW_IMAGE" ] || [ ! -f "$BFW_IMAGE" ]; then
  echo "missing BFW image: $BFW_IMAGE" >&2
  exit 2
fi
if [ -z "$BASIC_DIR" ] || [ ! -d "$BASIC_DIR" ]; then
  echo "missing basic image dir: $BASIC_DIR" >&2
  exit 2
fi
[ -n "$OUT_DIR" ] || { echo "missing output dir" >&2; usage; exit 2; }
[ -f "$PINS" ] || { echo "missing pins manifest: $PINS" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 2; }
command -v sha256sum >/dev/null || { echo "sha256sum required" >&2; exit 2; }

for f in bootcore.bin kernel.bin rootfs.img; do
  [ -f "$BASIC_DIR/$f" ] || { echo "missing $BASIC_DIR/$f" >&2; exit 2; }
done

if [ -n "$KERNEL_BUNDLE_TAR" ]; then
  [ -f "$KERNEL_BUNDLE_TAR" ] || { echo "missing kernel bundle tar: $KERNEL_BUNDLE_TAR" >&2; exit 2; }
  TAR_LIST=$(mktemp)
  trap 'rm -f "$TAR_LIST"' EXIT
  tar -tf "$KERNEL_BUNDLE_TAR" > "$TAR_LIST"
  grep -Eq '^(\./)?kernel\.bin$' "$TAR_LIST" || { echo "kernel bundle tar lacks kernel.bin" >&2; exit 2; }
  grep -Eq '^(\./)?kernel-build\.json$' "$TAR_LIST" || { echo "kernel bundle tar lacks kernel-build.json" >&2; exit 2; }
else
  TAR_LIST=""
fi

if $UPDATE_PINS; then
  update_args=(--pins "$PINS")
  [ -z "$VENDOR_VERSION" ] || update_args+=(--vendor-version "$VENDOR_VERSION")
  [ -z "$SOURCE_URL" ] || update_args+=(--source-url "$SOURCE_URL")
  "$BASE_DIR/pins/update-from-files.sh" "${update_args[@]}" "$BFW_IMAGE" "$BASIC_DIR"
fi

"$BASE_DIR/pins/verify.sh" --pins "$PINS" --strict "$BFW_IMAGE" "$BASIC_DIR"

mkdir -p "$OUT_DIR"
if [ -n "$(find "$OUT_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
  if ! $FORCE; then
    echo "output dir is not empty: $OUT_DIR (use --force to replace generated files)" >&2
    exit 2
  fi
  rm -rf \
    "$OUT_DIR/basic" \
    "$OUT_DIR/BUILD.bazel" \
    "$OUT_DIR/README.md" \
    "$OUT_DIR/REPO.bazel" \
    "$OUT_DIR/SHA256SUMS" \
    "$OUT_DIR/WORKSPACE" \
    "$OUT_DIR/bfw.img" \
    "$OUT_DIR/kernel-bundle.tar" \
    "$OUT_DIR/pins.inputs.json" \
    "$OUT_DIR/was110_vendor_blobs.bazelrc" \
    "$OUT_DIR/was110_vendor_blobs.env" \
    "$OUT_DIR/was110_vendor_blobs.handoff.json" \
    "$OUT_DIR/vendor_blobs.meta.json"
fi

OUT_DIR_ABS=$(cd "$OUT_DIR" && pwd -P)
REPO_NAME=was110_vendor_blobs

source_abs() {
  local p="$1"
  (cd "$(dirname "$p")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$p")")
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

put_file() {
  local src="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  if [ "$MODE" = "symlink" ]; then
    rm -f "$dest"
    ln -s "$(source_abs "$src")" "$dest"
  else
    cp -fL "$src" "$dest"
    chmod 0444 "$dest" 2>/dev/null || true
  fi
}

sha256() { sha256sum "$1" | awk '{print $1}'; }
sz() { stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1"; }

put_file "$BFW_IMAGE" "$OUT_DIR_ABS/bfw.img"
put_file "$BASIC_DIR/bootcore.bin" "$OUT_DIR_ABS/basic/bootcore.bin"
put_file "$BASIC_DIR/kernel.bin" "$OUT_DIR_ABS/basic/kernel.bin"
put_file "$BASIC_DIR/rootfs.img" "$OUT_DIR_ABS/basic/rootfs.img"
put_file "$PINS" "$OUT_DIR_ABS/pins.inputs.json"
if [ -n "$KERNEL_BUNDLE_TAR" ]; then
  put_file "$KERNEL_BUNDLE_TAR" "$OUT_DIR_ABS/kernel-bundle.tar"
fi

VISIBILITY_EXPR=$(printf '%s\n' "${VISIBILITY[@]}" | jq -R . | jq -s -c .)
KERNEL_TARGET=""
if [ -n "$KERNEL_BUNDLE_TAR" ]; then
  KERNEL_TARGET="filegroup(name = \"kernel_bundle_tar\", srcs = [\"kernel-bundle.tar\"], visibility = $VISIBILITY_EXPR)"
fi

cat > "$OUT_DIR_ABS/BUILD.bazel" <<EOF
package(default_visibility = ["//visibility:private"])

exports_files(["bfw.img", "pins.inputs.json"], visibility = $VISIBILITY_EXPR)

filegroup(name = "basic_bootcore", srcs = ["basic/bootcore.bin"], visibility = $VISIBILITY_EXPR)
filegroup(name = "basic_kernel", srcs = ["basic/kernel.bin"], visibility = $VISIBILITY_EXPR)
filegroup(name = "basic_rootfs", srcs = ["basic/rootfs.img"], visibility = $VISIBILITY_EXPR)
filegroup(name = "pins_inputs", srcs = ["pins.inputs.json"], visibility = $VISIBILITY_EXPR)
$KERNEL_TARGET
EOF

cat > "$OUT_DIR_ABS/REPO.bazel" <<'EOF'
repo(default_visibility = ["//visibility:public"])
EOF

cat > "$OUT_DIR_ABS/WORKSPACE" <<'EOF'
# Generated private repository for WAS-110 vendor blobs.
EOF

jq -n \
  --arg mode "$MODE" \
  --arg pins_sha "$(sha256 "$OUT_DIR_ABS/pins.inputs.json")" \
  --arg bfw_sha "$(sha256 "$OUT_DIR_ABS/bfw.img")" \
  --arg bootcore_sha "$(sha256 "$OUT_DIR_ABS/basic/bootcore.bin")" \
  --arg kernel_sha "$(sha256 "$OUT_DIR_ABS/basic/kernel.bin")" \
  --arg rootfs_sha "$(sha256 "$OUT_DIR_ABS/basic/rootfs.img")" \
  --argjson bfw_size "$(sz "$OUT_DIR_ABS/bfw.img")" \
  --argjson bootcore_size "$(sz "$OUT_DIR_ABS/basic/bootcore.bin")" \
  --argjson kernel_size "$(sz "$OUT_DIR_ABS/basic/kernel.bin")" \
  --argjson rootfs_size "$(sz "$OUT_DIR_ABS/basic/rootfs.img")" \
  --argjson visibility "$VISIBILITY_EXPR" \
  '{
    schema_version: 1,
    kind: "8311-was-110-private-vendor-blob-repo",
    mode: $mode,
    visibility: $visibility,
    pins_manifest: {path: "pins.inputs.json", sha256: $pins_sha},
    files: {
      "bfw.img": {sha256: $bfw_sha, size_bytes: $bfw_size},
      "basic/bootcore.bin": {sha256: $bootcore_sha, size_bytes: $bootcore_size},
      "basic/kernel.bin": {sha256: $kernel_sha, size_bytes: $kernel_size},
      "basic/rootfs.img": {sha256: $rootfs_sha, size_bytes: $rootfs_size}
    }
  }' > "$OUT_DIR_ABS/vendor_blobs.meta.json"

if [ -n "$KERNEL_BUNDLE_TAR" ]; then
  tmp_meta=$(mktemp)
  jq \
    --arg sha "$(sha256 "$OUT_DIR_ABS/kernel-bundle.tar")" \
    --argjson size "$(sz "$OUT_DIR_ABS/kernel-bundle.tar")" \
    '.files["kernel-bundle.tar"] = {sha256: $sha, size_bytes: $size}' \
    "$OUT_DIR_ABS/vendor_blobs.meta.json" > "$tmp_meta"
  mv "$tmp_meta" "$OUT_DIR_ABS/vendor_blobs.meta.json"
fi

cat > "$OUT_DIR_ABS/was110_vendor_blobs.env" <<EOF
# Generated by pins/import-vendor-blobs.sh.
# Source this from a GloriousFlywheel cache-backed consumer before running
# scripts/bazel-cache-backed.sh.
export GF_BAZEL_INJECT_REPOSITORIES=$(shell_quote "$REPO_NAME=$OUT_DIR_ABS")
if [ -z "\${GF_BAZEL_SUBSTRATE_MODE:-}" ]; then
  export GF_BAZEL_SUBSTRATE_MODE=shared-cache-backed
fi
EOF

cat > "$OUT_DIR_ABS/was110_vendor_blobs.bazelrc" <<EOF
# Generated by pins/import-vendor-blobs.sh.
# Import this from a consuming Bazel workspace only after approving the
# repository path and CAS trust boundary recorded in was110_vendor_blobs.handoff.json.
common --inject_repository=$REPO_NAME=$OUT_DIR_ABS
EOF

jq \
  --arg repo_name "$REPO_NAME" \
  --arg repo_path "$OUT_DIR_ABS" \
  --arg env_file "was110_vendor_blobs.env" \
  --arg bazelrc_file "was110_vendor_blobs.bazelrc" \
  '{
    schema_version: 1,
    kind: "8311-was-110-bazel-input-handoff",
    repository_name: $repo_name,
    repository_path: $repo_path,
    handoff_files: {
      gloriousflywheel_env: $env_file,
      bazelrc_fragment: $bazelrc_file
    },
    bazel_labels: [
      "@" + $repo_name + "//:bfw.img",
      "@" + $repo_name + "//:basic_bootcore",
      "@" + $repo_name + "//:basic_kernel",
      "@" + $repo_name + "//:basic_rootfs",
      "@" + $repo_name + "//:pins_inputs"
    ],
    trust_boundary: {
      remote_execution_proven: false,
      public_inputs_cas_policy: "content-pinned public community inputs may enter an approved CAS",
      private_inputs_cas_policy: "private vendor blobs require a lab-approved private CAS or local-only execution requirements"
    },
    source_repository: {
      kind: .kind,
      mode: .mode,
      visibility: .visibility,
      pins_manifest: .pins_manifest,
      files: .files
    }
  }' "$OUT_DIR_ABS/vendor_blobs.meta.json" > "$OUT_DIR_ABS/was110_vendor_blobs.handoff.json"

cat > "$OUT_DIR_ABS/README.md" <<'EOF'
# WAS-110 private vendor blobs

Generated by `pins/import-vendor-blobs.sh` from reviewed local inputs.
This directory is intended to be mounted or injected as a private Bazel
repository. Do not commit it to the firmware builder repository.

Verify this repository before use:

```sh
./pins/verify-vendor-repo.sh /path/to/this/directory
```

Use `@was110_vendor_blobs//:pins_inputs` as the `pins_manifest` label when
the consuming Bazel workspace should carry the pins snapshot privately.

For GloriousFlywheel cache-forward consumers, source the generated handoff:

```sh
. /path/to/this/directory/was110_vendor_blobs.env
scripts/bazel-cache-backed.sh build //firmware/was110:was110_lab_release
```

For direct Bazel consumers with an approved CAS boundary, import the generated
rc fragment from the consuming workspace:

```text
try-import /path/to/this/directory/was110_vendor_blobs.bazelrc
```

Review `was110_vendor_blobs.handoff.json` before enabling remote execution.
EOF

FILES=(
  BUILD.bazel
  README.md
  REPO.bazel
  WORKSPACE
  bfw.img
  basic/bootcore.bin
  basic/kernel.bin
  basic/rootfs.img
  pins.inputs.json
  was110_vendor_blobs.bazelrc
  was110_vendor_blobs.env
  was110_vendor_blobs.handoff.json
  vendor_blobs.meta.json
)
[ -z "$KERNEL_BUNDLE_TAR" ] || FILES+=(kernel-bundle.tar)

(
  cd "$OUT_DIR_ABS"
  for f in "${FILES[@]}"; do
    sha256sum "$f"
  done > SHA256SUMS
)

echo "created private vendor blob repo: $OUT_DIR_ABS"
echo "bazel labels:"
echo "  @was110_vendor_blobs//:bfw.img"
echo "  @was110_vendor_blobs//:basic_bootcore"
echo "  @was110_vendor_blobs//:basic_kernel"
echo "  @was110_vendor_blobs//:basic_rootfs"
echo "  @was110_vendor_blobs//:pins_inputs"
if [ -n "$KERNEL_BUNDLE_TAR" ]; then
  echo "  @was110_vendor_blobs//:kernel_bundle_tar"
fi
echo "handoff files:"
echo "  $OUT_DIR_ABS/was110_vendor_blobs.env"
echo "  $OUT_DIR_ABS/was110_vendor_blobs.bazelrc"
echo "  $OUT_DIR_ABS/was110_vendor_blobs.handoff.json"
