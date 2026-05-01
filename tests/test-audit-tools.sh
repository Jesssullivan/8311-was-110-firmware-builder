#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

sha256() { sha256sum "$1" | awk '{print $1}'; }
sz() { stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1"; }

BFW="$TMP/bfw.img"
BASIC="$TMP/basic"
PINS="$TMP/inputs.json"
mkdir -p "$BASIC"
printf 'bfw-vendor-image\n' > "$BFW"
printf 'bootcore\n' > "$BASIC/bootcore.bin"
printf 'kernel\n' > "$BASIC/kernel.bin"
printf 'rootfs\n' > "$BASIC/rootfs.img"
cp "$BASE_DIR/pins/inputs.json" "$PINS"

"$BASE_DIR/pins/update-from-files.sh" \
  --pins "$PINS" \
  --vendor-version test-v1 \
  --source-url file://fixture \
  "$BFW" \
  "$BASIC" >/dev/null

test "$(jq -r '.inputs.bfw_image.sha256' "$PINS")" = "$(sha256 "$BFW")"
test "$(jq -r '.inputs.bfw_image.size_bytes' "$PINS")" = "$(sz "$BFW")"
test "$(jq -r '.inputs.bfw_image.vendor_version' "$PINS")" = "test-v1"
test "$(jq -r '.inputs.basic_image_dir.files["bootcore.bin"].sha256' "$PINS")" = "$(sha256 "$BASIC/bootcore.bin")"
test "$(jq -r '.inputs.basic_image_dir.files["kernel.bin"].size_bytes' "$PINS")" = "$(sz "$BASIC/kernel.bin")"
test "$(jq -r '.inputs.basic_image_dir.files["rootfs.img"].sha256' "$PINS")" = "$(sha256 "$BASIC/rootfs.img")"
"$BASE_DIR/pins/verify.sh" --pins "$PINS" --strict "$BFW" "$BASIC" >/dev/null

jq -e '
  .kind == "8311-was-110-public-community-source-lock"
  and .sources.bfw_image.asset_sha256
  and .sources.basic_image_dir.extract.files["kernel.bin"].sha256
' "$BASE_DIR/pins/public-source-lock.json" >/dev/null
"$BASE_DIR/pins/fetch-public-inputs.sh" --help >/dev/null 2>&1
"$BASE_DIR/audit/collect-running-bundle.sh" --help >/dev/null 2>&1
"$BASE_DIR/pins/verify-public-source-lock.sh" >/dev/null

VENDOR_REPO="$TMP/vendor-repo"
"$BASE_DIR/pins/import-vendor-blobs.sh" \
  --pins "$PINS" \
  --visibility '@//firmware/was110:__pkg__' \
  "$BFW" \
  "$BASIC" \
  "$VENDOR_REPO" >/dev/null
test -f "$VENDOR_REPO/BUILD.bazel"
test -f "$VENDOR_REPO/REPO.bazel"
test -f "$VENDOR_REPO/pins.inputs.json"
test -f "$VENDOR_REPO/vendor_blobs.meta.json"
grep -q 'pins_inputs' "$VENDOR_REPO/BUILD.bazel"
grep -q '@//firmware/was110:__pkg__' "$VENDOR_REPO/BUILD.bazel"
(
  cd "$VENDOR_REPO"
  sha256sum -c SHA256SUMS >/dev/null
)
jq -e '.kind == "8311-was-110-private-vendor-blob-repo" and .files["bfw.img"].sha256' "$VENDOR_REPO/vendor_blobs.meta.json" >/dev/null
"$BASE_DIR/pins/verify.sh" --pins "$VENDOR_REPO/pins.inputs.json" --strict "$VENDOR_REPO/bfw.img" "$VENDOR_REPO/basic" >/dev/null
"$BASE_DIR/pins/verify-vendor-repo.sh" "$VENDOR_REPO" >/dev/null
cp -a "$VENDOR_REPO" "$TMP/vendor-repo-tampered"
chmod u+w "$TMP/vendor-repo-tampered/bfw.img"
printf 'tamper\n' >> "$TMP/vendor-repo-tampered/bfw.img"
if "$BASE_DIR/pins/verify-vendor-repo.sh" "$TMP/vendor-repo-tampered" >/dev/null 2>&1; then
  echo "tampered vendor repo unexpectedly passed" >&2
  exit 1
fi

OUT="$TMP/out"
mkdir -p "$OUT"
printf 'kernel artifact\n' > "$OUT/kernel.bin"
printf 'bootcore artifact\n' > "$OUT/bootcore.bin"
printf 'rootfs artifact\n' > "$OUT/rootfs.img"
printf '{"schema_version":1,"kind":"8311-was-110-kernel-build"}\n' > "$OUT/kernel-build.json"
cat > "$OUT/build-inputs.json" <<'JSON'
{
  "schema_version": 1,
  "firmware": {"variant": "basic", "version": "test", "revision": "test"},
  "kernel": {
    "variant": "external",
    "source": "external:kernel-bundle",
    "source_path": "/tmp/kernel.bin",
    "sha256": "fixture",
    "size_bytes": 16,
    "banner": "Linux version fixture",
    "modules_source": "/tmp/lib/modules",
    "firmware_source": "",
    "allow_module_mismatch": false,
    "build_provenance_path": "/tmp/kernel-build.json",
    "build_provenance_sha256": "fixture",
    "build_provenance": {
      "schema_version": 1,
      "kind": "8311-was-110-kernel-build",
      "source": {"repo": "fixture", "rev": "fixture"}
    }
  },
  "bootcore": {
    "variant": "basic",
    "source": "basic-image-dir:bootcore.bin",
    "source_path": "/tmp/bootcore.bin",
    "sha256": "fixture",
    "size_bytes": 17
  },
  "rootfs": {
    "bfw_source_path": "/tmp/rootfs-bfw.img",
    "basic_source_path": "/tmp/rootfs.img"
  }
}
JSON

"$BASE_DIR/audit/fingerprint.sh" "$OUT" >/dev/null
jq -e '.artifacts["kernel.bin"].sha256 and .build_inputs.kernel.source == "external:kernel-bundle" and .build_inputs.kernel.build_provenance.kind == "8311-was-110-kernel-build"' "$OUT/manifest.json" >/dev/null

"$BASE_DIR/audit/provenance.sh" "$OUT/manifest.json" "$OUT/provenance.intoto.json" >/dev/null
jq -e '.predicateType == "https://slsa.dev/provenance/v1" and (.subject | length) >= 3 and .predicate.buildDefinition.externalParameters.kernel_build_provenance.kind == "8311-was-110-kernel-build"' "$OUT/provenance.intoto.json" >/dev/null

"$BASE_DIR/audit/release-pack.sh" "$OUT" >/dev/null
test -f "$OUT/inputs.json"
test -f "$OUT/audit-summary.md"
test -f "$OUT/SHA256SUMS"
grep -q 'manifest.json' "$OUT/SHA256SUMS"
grep -q 'kernel-build.json' "$OUT/SHA256SUMS"
grep -q 'audit-summary.md' "$OUT/SHA256SUMS"
grep -q 'WAS-110 Release Audit Summary' "$OUT/audit-summary.md"
"$BASE_DIR/audit/verify-release-pack.sh" "$OUT" >/dev/null

POLICY_OUT="$TMP/policy-out"
mkdir -p "$POLICY_OUT"
required_artifacts=(
  kernel.bin
  bootcore.bin
  rootfs.img
  local-upgrade.img
  local-upgrade.tar
  multicast_upgrade.img
  multicast_reset.img
  whole-image.img
  whole-image-endian.img
)
for artifact in "${required_artifacts[@]}"; do
  printf '%s\n' "$artifact" > "$POLICY_OUT/$artifact"
done
artifacts_json=$(
  for artifact in "${required_artifacts[@]}"; do
    jq -n \
      --arg name "$artifact" \
      --arg sha "$(sha256 "$POLICY_OUT/$artifact")" \
      --argjson size "$(sz "$POLICY_OUT/$artifact")" \
      '{($name): {"sha256": $sha, "size_bytes": $size}}'
  done | jq -s 'add'
)
pin_hash="$(sha256 "$BFW")"
cat > "$POLICY_OUT/manifest.json" <<JSON
{
  "schema_version": 1,
  "kind": "8311-was-110-firmware-build-manifest",
  "git": {"rev": "abcdef1234567890", "rev_short": "abcdef1", "tag": "", "dirty": false, "commit_epoch": 1234567890},
  "kernel": {"banner": "Linux version 4.9.308+ fixture", "rebuilt_from_source": false},
  "build_inputs": {
    "kernel": {"variant": "basic", "allow_module_mismatch": false},
    "firmware": {"variant": "basic", "version": "test-v1"},
    "bootcore": {"variant": "basic"}
  },
  "pinned_inputs": {
    "bfw_image": {"sha256": "$pin_hash", "size_bytes": 1},
    "basic_image_dir": {
      "files": {
        "bootcore.bin": {"sha256": "$pin_hash"},
        "kernel.bin": {"sha256": "$pin_hash"},
        "rootfs.img": {"sha256": "$pin_hash"}
      }
    }
  },
  "artifacts": $artifacts_json
}
JSON
"$BASE_DIR/audit/verify-release-policy.sh" "$POLICY_OUT" >/dev/null
cp "$BASE_DIR/audit/cve-baseline-template.csv" "$TMP/cve-template.csv"
"$BASE_DIR/audit/verify-cve-baseline.sh" --allow-template "$TMP/cve-template.csv" >/dev/null
cat > "$POLICY_OUT/cve-baseline.csv" <<'CSV'
release_id,kernel_banner,cve_id,source,affected_component,affected_versions,upstream_fix,was110_status,evidence,notes
test-v1,Linux version 4.9.308+ fixture,CVE-2024-12345,NVD,kernel net,4.9.x,upstream-commit,unknown,https://example.invalid/advisory,fixture
CSV
"$BASE_DIR/audit/verify-cve-baseline.sh" "$POLICY_OUT/cve-baseline.csv" "$POLICY_OUT/manifest.json" >/dev/null
"$BASE_DIR/audit/verify-release-policy.sh" --cve-baseline "$POLICY_OUT/cve-baseline.csv" "$POLICY_OUT" >/dev/null
jq '.git.dirty = true' "$POLICY_OUT/manifest.json" > "$POLICY_OUT/dirty-manifest.json"
if "$BASE_DIR/audit/verify-release-policy.sh" "$POLICY_OUT/dirty-manifest.json" >/dev/null 2>&1; then
  echo "dirty release policy unexpectedly passed" >&2
  exit 1
fi

"$BASE_DIR/audit/verify-fwenv-profile.sh" "$BASE_DIR/audit/fwenv-profile.example.json" >/dev/null
cat > "$TMP/fwenv.txt" <<'EOF'
8311_fix_vlans=1
8311_console_en=1
8311_persist_root=0
8311_mib_file=/etc/mibs/prx300_1V.ini
EOF
"$BASE_DIR/audit/verify-fwenv-profile.sh" "$BASE_DIR/audit/fwenv-profile.example.json" "$TMP/fwenv.txt" >/dev/null
sed 's/8311_console_en=1/8311_console_en=0/' "$TMP/fwenv.txt" > "$TMP/fwenv-bad.txt"
if "$BASE_DIR/audit/verify-fwenv-profile.sh" "$BASE_DIR/audit/fwenv-profile.example.json" "$TMP/fwenv-bad.txt" >/dev/null 2>&1; then
  echo "bad fwenv profile unexpectedly passed" >&2
  exit 1
fi

FAKE_SSH_DIR="$TMP/fake-ssh-bin"
mkdir -p "$FAKE_SSH_DIR"
printf '#!%s\n' "$(command -v bash)" > "$FAKE_SSH_DIR/ssh"
cat >> "$FAKE_SSH_DIR/ssh" <<'EOF'
set -euo pipefail

args=" $* "

if printf '%s\n' "$args" | grep -q ' sh -s -- '; then
  cat >/dev/null
  if [ "${FAKE_SSH_ACTIVE_DIFF:-}" = "1" ]; then
    cat <<REMOTE
active bank: A
kernelA    DIFF-ACTIVE   9999999999999999999999999999999999999999999999999999999999999999
bootcoreA  MATCH         bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
rootfsA    MATCH         cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
kernelB    DIFF-INACTIVE dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
REMOTE
  else
    cat <<REMOTE
active bank: A
kernelA    MATCH         aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
bootcoreA  MATCH         bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
rootfsA    MATCH         cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
kernelB    DIFF-INACTIVE dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
REMOTE
  fi
  exit 0
fi

case "$args" in
  *"cat /proc/version"*)
    if [ "${FAKE_SSH_BAD_BANNER:-}" = "1" ]; then
      echo "Linux version 4.9.0-wrong (fixture)"
    else
      echo "Linux version 4.9.308+ (fixture)"
    fi
    ;;
  *"cat /etc/8311_version"*)
    echo "test-v1"
    ;;
  *"cat /proc/mounts"*)
    echo "/dev/ubi0_2 /rom squashfs ro,relatime 0 0"
    ;;
  *"cat /proc/mtd"*)
    echo "mtd0: 00100000 00020000 \"u-boot\""
    ;;
  *"fw_printenv"*)
    cat <<FWENV
8311_fix_vlans=1
8311_console_en=1
8311_persist_root=0
8311_mib_file=/etc/mibs/prx300_1V.ini
FWENV
    ;;
  *)
    echo "unexpected fake ssh invocation: $*" >&2
    exit 99
    ;;
esac
EOF
chmod +x "$FAKE_SSH_DIR/ssh"

DEVICE_MANIFEST="$TMP/device-manifest.json"
cat > "$DEVICE_MANIFEST" <<'JSON'
{
  "schema_version": 1,
  "kind": "8311-was-110-firmware-build-manifest",
  "kernel": {"banner": "Linux version 4.9.308+ (fixture)"},
  "artifacts": {
    "kernel.bin": {
      "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "size_bytes": 10
    },
    "bootcore.bin": {
      "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "size_bytes": 11
    },
    "rootfs.img": {
      "sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
      "size_bytes": 12
    }
  }
}
JSON

PATH="$FAKE_SSH_DIR:$PATH" "$BASE_DIR/audit/verify-device.sh" \
  --fwenv-profile "$BASE_DIR/audit/fwenv-profile.example.json" \
  fixture-host root "$DEVICE_MANIFEST" > "$TMP/verify-device-good.txt"
grep -q 'kernel banner: MATCH' "$TMP/verify-device-good.txt"
grep -q 'kernelA    MATCH' "$TMP/verify-device-good.txt"
grep -q 'DIFF-INACTIVE' "$TMP/verify-device-good.txt"

if FAKE_SSH_ACTIVE_DIFF=1 PATH="$FAKE_SSH_DIR:$PATH" "$BASE_DIR/audit/verify-device.sh" \
  fixture-host root "$DEVICE_MANIFEST" >/dev/null 2>&1; then
  echo "verify-device active volume mismatch unexpectedly passed" >&2
  exit 1
fi

if FAKE_SSH_BAD_BANNER=1 PATH="$FAKE_SSH_DIR:$PATH" "$BASE_DIR/audit/verify-device.sh" \
  fixture-host root "$DEVICE_MANIFEST" >/dev/null 2>&1; then
  echo "verify-device banner mismatch unexpectedly passed" >&2
  exit 1
fi

BAD_BUNDLE="$TMP/bad-kernel-bundle"
mkdir -p "$BAD_BUNDLE/lib/modules/4.9.999"
printf 'not a uimage\n' > "$BAD_BUNDLE/kernel.bin"
printf 'module\n' > "$BAD_BUNDLE/lib/modules/4.9.999/test.ko"
if "$BASE_DIR/audit/verify-kernel-bundle.sh" "$BAD_BUNDLE" >/dev/null 2>&1; then
  echo "bad kernel bundle unexpectedly passed" >&2
  exit 1
fi

TAR_BIN="${TAR:-tar}"
if ! "$TAR_BIN" --version 2>/dev/null | grep -qi 'gnu tar' && command -v gtar >/dev/null; then
  TAR_BIN=gtar
fi

if command -v mkimage >/dev/null && "$TAR_BIN" --version 2>/dev/null | grep -qi 'gnu tar'; then
  GOOD_BUNDLE="$TMP/good-kernel-bundle"
  mkdir -p "$GOOD_BUNDLE/lib/modules/4.9.999" "$GOOD_BUNDLE/lib/firmware"
  printf 'Linux version 4.9.999 (fixture)\nkernel payload\n' > "$TMP/kernel-payload.bin"
  mkimage \
    -A mips \
    -O linux \
    -T kernel \
    -C none \
    -a 0x80000000 \
    -e 0x80000000 \
    -n test-was110-kernel \
    -d "$TMP/kernel-payload.bin" \
    "$GOOD_BUNDLE/kernel.bin" >/dev/null
  printf 'vermagic=4.9.999 SMP mod_unload\nmodule\n' > "$GOOD_BUNDLE/lib/modules/4.9.999/test.ko"
  printf 'firmware\n' > "$GOOD_BUNDLE/lib/firmware/test.bin"
  cat > "$GOOD_BUNDLE/kernel-build.json" <<'JSON'
{
  "schema_version": 1,
  "kind": "8311-was-110-kernel-build",
  "kernel": {
    "release": "4.9.999"
  },
  "outputs": {
    "kernel_bin_sha256": "TBD",
    "modules_tree_sha256": "TBD",
    "firmware_tree_sha256": "TBD"
  }
}
JSON
  "$BASE_DIR/audit/verify-kernel-bundle.sh" "$GOOD_BUNDLE" >/dev/null
  STALE_BUNDLE="$TMP/stale-kernel-bundle"
  cp -a "$GOOD_BUNDLE" "$STALE_BUNDLE"
  jq '.outputs.kernel_bin_sha256 = "0000000000000000000000000000000000000000000000000000000000000000"' \
    "$GOOD_BUNDLE/kernel-build.json" > "$STALE_BUNDLE/kernel-build.json"
  if "$BASE_DIR/audit/verify-kernel-bundle.sh" "$STALE_BUNDLE" >/dev/null 2>&1; then
    echo "stale kernel-build.json hash unexpectedly passed" >&2
    exit 1
  fi
  BAD_VERMAGIC_BUNDLE="$TMP/bad-vermagic-kernel-bundle"
  cp -a "$GOOD_BUNDLE" "$BAD_VERMAGIC_BUNDLE"
  printf 'vermagic=4.9.998 SMP mod_unload\nmodule\n' > "$BAD_VERMAGIC_BUNDLE/lib/modules/4.9.999/bad.ko"
  if "$BASE_DIR/audit/verify-kernel-bundle.sh" "$BAD_VERMAGIC_BUNDLE" >/dev/null 2>&1; then
    echo "mixed kernel module vermagic unexpectedly passed" >&2
    exit 1
  fi
  EXTRA_RELEASE_BUNDLE="$TMP/extra-release-kernel-bundle"
  cp -a "$GOOD_BUNDLE" "$EXTRA_RELEASE_BUNDLE"
  mkdir -p "$EXTRA_RELEASE_BUNDLE/lib/modules/4.9.998"
  printf 'vermagic=4.9.998 SMP mod_unload\nmodule\n' > "$EXTRA_RELEASE_BUNDLE/lib/modules/4.9.998/extra.ko"
  if "$BASE_DIR/audit/verify-kernel-bundle.sh" "$EXTRA_RELEASE_BUNDLE" >/dev/null 2>&1; then
    echo "extra kernel module release unexpectedly passed" >&2
    exit 1
  fi
  WRONG_RELEASE_BUNDLE="$TMP/wrong-release-kernel-bundle"
  cp -a "$GOOD_BUNDLE" "$WRONG_RELEASE_BUNDLE"
  jq '.kernel.release = "4.9.998"' \
    "$GOOD_BUNDLE/kernel-build.json" > "$WRONG_RELEASE_BUNDLE/kernel-build.json"
  if "$BASE_DIR/audit/verify-kernel-bundle.sh" "$WRONG_RELEASE_BUNDLE" >/dev/null 2>&1; then
    echo "wrong kernel-build.json release unexpectedly passed" >&2
    exit 1
  fi
  TAR="$TAR_BIN" "$BASE_DIR/audit/pack-kernel-bundle.sh" "$GOOD_BUNDLE" "$TMP/kernel-bundle.tar" >/dev/null
  test -s "$TMP/kernel-bundle.tar"
  first_bundle_sha=$(sha256 "$TMP/kernel-bundle.tar")
  TAR="$TAR_BIN" "$BASE_DIR/audit/pack-kernel-bundle.sh" "$GOOD_BUNDLE" "$TMP/kernel-bundle.tar" >/dev/null
  test "$first_bundle_sha" = "$(sha256 "$TMP/kernel-bundle.tar")"
  "$TAR_BIN" -tf "$TMP/kernel-bundle.tar" | grep -q './kernel.bin'
  KERNEL_VENDOR_REPO="$TMP/vendor-repo-kernel"
  "$BASE_DIR/pins/import-vendor-blobs.sh" \
    --pins "$PINS" \
    --kernel-bundle-tar "$TMP/kernel-bundle.tar" \
    "$BFW" \
    "$BASIC" \
    "$KERNEL_VENDOR_REPO" >/dev/null
  grep -q 'kernel_bundle_tar' "$KERNEL_VENDOR_REPO/BUILD.bazel"
  grep -q 'kernel-bundle.tar' "$KERNEL_VENDOR_REPO/SHA256SUMS"
else
  echo "skipping positive kernel bundle pack test (mkimage or GNU tar unavailable)"
fi

echo "audit tool tests passed"
