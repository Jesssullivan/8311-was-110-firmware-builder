#!/usr/bin/env bash
# Verify a bundle collected by audit/collect-running-bundle.sh.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: verify-running-bundle.sh [options] <bundle-dir|bundle.tar.gz>

Options:
  --expected-manifest <manifest.json>  Compare active dumped volumes and
                                      kernel banner against a release manifest.
  --strict                            Require active bank, active volume dumps,
                                      expected manifest, and observed kernel copy.
  --reject-sensitive                  Fail if sensitive/ or mtd/ contain files.
  -h, --help                          Show this help.

The verifier checks the bundle's SHA256SUMS, collector manifest shape,
runtime metadata, active A/B slot dumps, and optional release-manifest match.
EOF
  exit "${1:-2}"
}

EXPECTED_MANIFEST=""
STRICT=false
REJECT_SENSITIVE=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --expected-manifest)
      EXPECTED_MANIFEST="${2:-}"
      [ -n "$EXPECTED_MANIFEST" ] || usage
      shift
      ;;
    --strict)
      STRICT=true
      ;;
    --reject-sensitive)
      REJECT_SENSITIVE=true
      ;;
    -h|--help)
      usage 0
      ;;
    *)
      break
      ;;
  esac
  shift
done

BUNDLE="${1:-}"
[ -n "$BUNDLE" ] || usage
[ -z "$EXPECTED_MANIFEST" ] || [ -f "$EXPECTED_MANIFEST" ] || {
  echo "missing expected manifest: $EXPECTED_MANIFEST" >&2
  exit 2
}

command -v jq >/dev/null || { echo "jq required" >&2; exit 2; }
command -v sha256sum >/dev/null || { echo "sha256sum required" >&2; exit 2; }

TMP=""
cleanup() {
  [ -z "$TMP" ] || rm -rf "$TMP"
}
trap cleanup EXIT

if [ -d "$BUNDLE" ]; then
  BUNDLE_DIR=$(cd "$BUNDLE" && pwd)
elif [ -f "$BUNDLE" ]; then
  case "$BUNDLE" in
    *.tar.gz|*.tgz)
      TMP=$(mktemp -d)
      tar -xzf "$BUNDLE" -C "$TMP"
      dir_count=$(find "$TMP" -mindepth 1 -maxdepth 1 -type d | wc -l | awk '{print $1}')
      [ "$dir_count" -eq 1 ] || {
        echo "expected one top-level directory in $BUNDLE, found $dir_count" >&2
        exit 1
      }
      BUNDLE_DIR=$(find "$TMP" -mindepth 1 -maxdepth 1 -type d -print -quit)
      ;;
    *)
      echo "unsupported bundle file: $BUNDLE" >&2
      exit 2
      ;;
  esac
else
  echo "no such bundle: $BUNDLE" >&2
  exit 2
fi

MANIFEST="$BUNDLE_DIR/manifest.json"
SUMS="$BUNDLE_DIR/SHA256SUMS"
FAIL=0

fail() {
  echo "fail: $*" >&2
  FAIL=1
}

warn() {
  echo "warn: $*" >&2
}

ok() {
  echo "ok     $*"
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

expected_artifact_sha() {
  local artifact="$1"
  [ -n "$EXPECTED_MANIFEST" ] || return 0
  jq -r --arg artifact "$artifact" '.artifacts[$artifact].sha256 // empty' "$EXPECTED_MANIFEST"
}

expected_artifact_size() {
  local artifact="$1"
  [ -n "$EXPECTED_MANIFEST" ] || return 0
  jq -r --arg artifact "$artifact" '.artifacts[$artifact].size_bytes // empty' "$EXPECTED_MANIFEST"
}

compare_volume_to_expected() {
  local volume="$1" artifact="$2" file
  local expected_sha expected_size actual_sha actual_size
  file="$BUNDLE_DIR/volumes/$volume.bin"

  expected_sha=$(expected_artifact_sha "$artifact")
  [ -n "$expected_sha" ] || {
    fail "expected manifest missing artifact hash for $artifact"
    return
  }
  [ -f "$file" ] || {
    fail "missing active volume dump: volumes/$volume.bin"
    return
  }

  actual_sha=$(sha256_file "$file")
  if [ "$actual_sha" = "$expected_sha" ]; then
    ok "$volume matches $artifact $actual_sha"
  else
    fail "$volume hash mismatch for $artifact: expected $expected_sha, got $actual_sha"
  fi

  expected_size=$(expected_artifact_size "$artifact")
  if [ -n "$expected_size" ] && [ "$expected_size" != "null" ]; then
    actual_size=$(wc -c < "$file" | awk '{print $1}')
    if [ "$actual_size" = "$expected_size" ]; then
      ok "$volume size matches $artifact $actual_size bytes"
    else
      fail "$volume size mismatch for $artifact: expected $expected_size, got $actual_size"
    fi
  fi
}

[ -f "$MANIFEST" ] || { echo "missing $MANIFEST" >&2; exit 1; }
[ -f "$SUMS" ] || { echo "missing $SUMS" >&2; exit 1; }

if jq -e '
  .schema_version == 1
  and .kind == "8311-was-110-running-device-bundle"
  and (.target.host | type == "string")
  and (.collected_at | type == "string")
  and (.options.volume_dump | type == "boolean")
' "$MANIFEST" >/dev/null; then
  ok "collector manifest shape"
else
  fail "invalid running bundle manifest shape"
fi

(
  cd "$BUNDLE_DIR"
  sha256sum -c SHA256SUMS >/dev/null
) && ok "SHA256SUMS" || fail "SHA256SUMS verification failed"

metadata_required=(
  metadata/proc-version
  metadata/uname
  metadata/cmdline
  metadata/proc-mtd
  metadata/ubinfo
  metadata/fwenv-filtered
)
for rel in "${metadata_required[@]}"; do
  if [ -f "$BUNDLE_DIR/$rel" ]; then
    ok "$rel present"
  elif $STRICT; then
    fail "missing $rel"
  else
    warn "missing $rel"
  fi
done

active_bank=$(jq -r '.active_bank // empty' "$MANIFEST")
kernel_release=$(jq -r '.kernel_release // empty' "$MANIFEST")
volume_dump=$(jq -r '.options.volume_dump // false' "$MANIFEST")
include_sensitive=$(jq -r '.options.include_sensitive // false' "$MANIFEST")
include_mtd=$(jq -r '.options.include_mtd // false' "$MANIFEST")

case "$active_bank" in
  A|B)
    ok "active bank $active_bank"
    ;;
  "")
    $STRICT && fail "active bank missing" || warn "active bank missing"
    ;;
  *)
    $STRICT && fail "unexpected active bank: $active_bank" || warn "unexpected active bank: $active_bank"
    ;;
esac

[ -n "$kernel_release" ] && ok "kernel release $kernel_release" || warn "kernel release missing"

sensitive_count=$(find "$BUNDLE_DIR/sensitive" "$BUNDLE_DIR/mtd" -type f 2>/dev/null | wc -l | awk '{print $1}')
if [ "$sensitive_count" -gt 0 ]; then
  if $REJECT_SENSITIVE; then
    fail "sensitive/mtd evidence present ($sensitive_count files)"
  else
    warn "sensitive/mtd evidence present ($sensitive_count files)"
  fi
elif [ "$include_sensitive" = true ] || [ "$include_mtd" = true ]; then
  warn "manifest says sensitive/mtd collection was enabled, but no files were found"
else
  ok "no sensitive/mtd files"
fi

if [ "$volume_dump" = true ]; then
  if [ "$active_bank" = A ] || [ "$active_bank" = B ]; then
    for prefix in kernel bootcore rootfs; do
      rel="volumes/$prefix$active_bank.bin"
      if [ -f "$BUNDLE_DIR/$rel" ]; then
        ok "$rel present"
      else
        fail "missing active volume dump: $rel"
      fi
    done

    active_kernel="$BUNDLE_DIR/volumes/kernel$active_bank.bin"
    observed_kernel="$BUNDLE_DIR/observed-kernel-bundle/kernel.bin"
    if [ -f "$active_kernel" ] && [ -f "$observed_kernel" ]; then
      active_kernel_sha=$(sha256_file "$active_kernel")
      observed_kernel_sha=$(sha256_file "$observed_kernel")
      if [ "$active_kernel_sha" = "$observed_kernel_sha" ]; then
        ok "observed kernel copy matches active kernel volume"
      else
        fail "observed kernel copy does not match active kernel volume"
      fi
    elif $STRICT; then
      fail "missing observed kernel copy for active volume"
    else
      warn "missing observed kernel copy for active volume"
    fi

    if [ -n "$EXPECTED_MANIFEST" ]; then
      compare_volume_to_expected "kernel$active_bank" kernel.bin
      compare_volume_to_expected "bootcore$active_bank" bootcore.bin
      compare_volume_to_expected "rootfs$active_bank" rootfs.img
    elif $STRICT; then
      fail "--expected-manifest is required in --strict mode"
    else
      warn "no expected manifest supplied; active volume hashes not compared to release"
    fi
  else
    $STRICT && fail "cannot validate active volumes without active bank" || warn "cannot validate active volumes without active bank"
  fi
else
  $STRICT && fail "volume dumps disabled" || warn "volume dumps disabled"
fi

if [ -n "$EXPECTED_MANIFEST" ]; then
  expected_banner=$(jq -r '.kernel.banner // empty' "$EXPECTED_MANIFEST")
  if [ -n "$expected_banner" ]; then
    if [ -f "$BUNDLE_DIR/metadata/proc-version" ] && grep -Fq "$expected_banner" "$BUNDLE_DIR/metadata/proc-version"; then
      ok "kernel banner matches expected manifest"
    else
      fail "kernel banner mismatch against expected manifest"
    fi
  else
    warn "expected manifest has no kernel.banner"
  fi
fi

if $STRICT; then
  [ -f "$BUNDLE_DIR/trees/proc-device-tree.tar.gz" ] || [ -f "$BUNDLE_DIR/trees/sys-firmware-devicetree.tar.gz" ] || \
    fail "missing device tree tarball"
  if [ -n "$kernel_release" ]; then
    [ -f "$BUNDLE_DIR/trees/modules-$kernel_release.tar.gz" ] || \
      fail "missing modules tarball for kernel release $kernel_release"
  fi
fi

if [ "$FAIL" -eq 0 ]; then
  echo "running bundle verified: $BUNDLE_DIR"
else
  echo "running bundle verification failed: $BUNDLE_DIR" >&2
fi
exit "$FAIL"
