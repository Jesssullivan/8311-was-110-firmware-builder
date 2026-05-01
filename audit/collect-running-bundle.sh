#!/usr/bin/env bash
# Collect read-only binary and metadata evidence from a live WAS-110.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: collect-running-bundle.sh [options] <host> [user]

Options:
  --out-dir <dir>            Output root (default: out/device-bundles).
  --manifest <manifest>      Use artifact sizes from manifest when dumping UBI volumes.
  --include-inactive         Also dump the inactive A/B firmware volumes.
  --include-sensitive        Include full fw_printenv and /etc/config archive.
  --include-mtd              Dump raw /dev/mtd* partitions. Sensitive and large.
  --no-volume-dump           Collect metadata/modules/DTB only; do not dump UBI volumes.
  --no-tar                   Do not create a .tar.gz copy of the output directory.
  -h, --help                 Show this help.

Default collection is read-only and dumps the active kernel/bootcore/rootfs
UBI volumes, module tree, firmware tree, DTB/device-tree, and inventories.
EOF
  exit "${1:-2}"
}

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
OUT_ROOT="$BASE_DIR/out/device-bundles"
MANIFEST=""
INCLUDE_INACTIVE=false
INCLUDE_SENSITIVE=false
INCLUDE_MTD=false
VOLUME_DUMP=true
MAKE_TAR=true

while [ "$#" -gt 0 ]; do
  case "$1" in
    --out-dir)
      OUT_ROOT="${2:-}"
      [ -n "$OUT_ROOT" ] || usage
      shift
      ;;
    --manifest)
      MANIFEST="${2:-}"
      [ -n "$MANIFEST" ] || usage
      shift
      ;;
    --include-inactive)
      INCLUDE_INACTIVE=true
      ;;
    --include-sensitive)
      INCLUDE_SENSITIVE=true
      ;;
    --include-mtd)
      INCLUDE_MTD=true
      ;;
    --no-volume-dump)
      VOLUME_DUMP=false
      ;;
    --no-tar)
      MAKE_TAR=false
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

HOST="${1:-}"
USER="${2:-root}"
[ -n "$HOST" ] || usage
[ -z "$MANIFEST" ] || [ -f "$MANIFEST" ] || { echo "missing manifest: $MANIFEST" >&2; exit 2; }
command -v ssh >/dev/null || { echo "ssh required" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 2; }
command -v sha256sum >/dev/null || { echo "sha256sum required" >&2; exit 2; }

SSH=(ssh -T -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 "${USER}@${HOST}")

safe_host=$(printf '%s' "$HOST" | tr -c 'A-Za-z0-9_.-' '_')
stamp=$(date -u +%Y%m%dT%H%M%SZ)
OUT_ROOT=$(mkdir -p "$OUT_ROOT" && cd "$OUT_ROOT" && pwd)
OUT_DIR="$OUT_ROOT/$safe_host-$stamp"
mkdir -p "$OUT_DIR"/{metadata,trees,volumes,observed-kernel-bundle,sensitive,mtd}

collect_text() {
  local name="$1" remote_cmd="$2"
  "${SSH[@]}" "$remote_cmd" > "$OUT_DIR/metadata/$name" 2>&1 || true
}

dump_remote_file() {
  local remote_path="$1" dest="$2"
  if "${SSH[@]}" "test -r '$remote_path'" >/dev/null 2>&1; then
    "${SSH[@]}" "cat '$remote_path'" > "$dest"
  fi
}

dump_remote_tar() {
  local label="$1" remote_path="$2" dest="$3"
  if "${SSH[@]}" "test -e '$remote_path'" >/dev/null 2>&1; then
    if "${SSH[@]}" "tar -czf - -C '$remote_path' . 2>/dev/null" > "$dest"; then
      :
    else
      rm -f "$dest"
      echo "warning: unable to tar $label from $remote_path" >&2
    fi
  fi
}

manifest_size_for() {
  local volume="$1" artifact=""
  [ -n "$MANIFEST" ] || { printf '\n'; return; }
  case "$volume" in
    kernel*) artifact="kernel.bin" ;;
    bootcore*) artifact="bootcore.bin" ;;
    rootfs*) artifact="rootfs.img" ;;
    *) printf '\n'; return ;;
  esac
  jq -r --arg artifact "$artifact" '.artifacts[$artifact].size_bytes // empty' "$MANIFEST"
}

dump_ubi_volume() {
  local name="$1" bytes="$2"
  local dest="$OUT_DIR/volumes/$name.bin"
  echo "dump UBI volume $name -> $dest"
  if "${SSH[@]}" sh -s -- "$name" "$bytes" > "$dest" <<'REMOTE'
set -eu
name="$1"
bytes="$2"
if ! command -v ubinfo >/dev/null 2>&1; then
  echo "ubinfo not found" >&2
  exit 2
fi
info=$(ubinfo /dev/ubi0 -N "$name" 2>/dev/null) || {
  echo "volume not found: $name" >&2
  exit 3
}
id=$(printf '%s\n' "$info" | awk '/Volume ID:/ {print $3; exit}')
if [ -z "$bytes" ] || [ "$bytes" = "null" ]; then
  bytes=$(printf '%s\n' "$info" | awk -F'[()]' '/Size:/ {print $2; exit}' | awk '{print $1}')
fi
[ -n "$id" ] && [ -n "$bytes" ] || {
  echo "could not determine id/size for $name" >&2
  exit 4
}
head -c "$bytes" "/dev/ubi0_$id"
REMOTE
  then
    :
  else
    rm -f "$dest"
    echo "warning: failed to dump UBI volume $name" >&2
  fi
}

collect_text proc-version 'cat /proc/version'
collect_text uname 'uname -a; uname -r'
collect_text cmdline 'cat /proc/cmdline'
collect_text mounts 'cat /proc/mounts'
collect_text proc-mtd 'cat /proc/mtd 2>/dev/null'
collect_text ubinfo 'ubinfo -a 2>/dev/null || true'
collect_text openwrt-release 'cat /etc/openwrt_release 2>/dev/null || true; cat /etc/os-release 2>/dev/null || true'
collect_text firmware-version 'cat /etc/8311_version 2>/dev/null || true'
collect_text modules 'cat /proc/modules 2>/dev/null || lsmod 2>/dev/null || true'
collect_text packages 'opkg list-installed 2>/dev/null || true'
collect_text processes 'ps w 2>/dev/null || ps 2>/dev/null || true'
# shellcheck disable=SC2016
collect_text pon-inventory 'for d in /etc/init.d /usr/bin /usr/sbin /sbin /bin /lib/modules /lib/firmware; do [ -e "$d" ] && find "$d" -maxdepth 4 -type f 2>/dev/null; done | grep -Ei "pon|xpon|gpon|omci|mib|sfp|optic|ploam" || true'
# shellcheck disable=SC2016
collect_text module-tree-hashes 'if [ -d /lib/modules ]; then find /lib/modules -type f -print 2>/dev/null | sort | while read -r f; do sha256sum "$f"; done; fi'
# shellcheck disable=SC2016
collect_text firmware-tree-hashes 'if [ -d /lib/firmware ]; then find /lib/firmware -type f -print 2>/dev/null | sort | while read -r f; do sha256sum "$f"; done; fi'
collect_text fwenv-filtered 'fw_printenv 2>/dev/null | grep -Ei "^(8311_|bootcmd|bootargs|bootdelay|baudrate|mtdparts|verify|active|committed|image|kernel|rootfs|bootcore)" || true'

if $INCLUDE_SENSITIVE; then
  collect_text fwenv-full 'fw_printenv 2>/dev/null || true'
  mv "$OUT_DIR/metadata/fwenv-full" "$OUT_DIR/sensitive/fwenv-full.txt"
  dump_remote_tar etc-config /etc/config "$OUT_DIR/sensitive/etc-config.tar.gz"
fi

dump_remote_file /proc/config.gz "$OUT_DIR/metadata/proc-config.gz"
dump_remote_file /sys/firmware/fdt "$OUT_DIR/metadata/fdt.dtb"
dump_remote_tar proc-device-tree /proc/device-tree "$OUT_DIR/trees/proc-device-tree.tar.gz"
dump_remote_tar sys-device-tree /sys/firmware/devicetree/base "$OUT_DIR/trees/sys-firmware-devicetree.tar.gz"

KERNEL_RELEASE=$("${SSH[@]}" 'uname -r' 2>/dev/null | tr -d '\r' | sed -n '1p' || true)
ACTIVE_BANK=$("${SSH[@]}" 'grep -E -o "\brootfsname=rootfs[AB]\b" /proc/cmdline | grep -E -o "[AB]$" | head -n1 || true' 2>/dev/null | tr -d '\r' || true)

if [ -n "$KERNEL_RELEASE" ]; then
  dump_remote_tar "modules-$KERNEL_RELEASE" "/lib/modules/$KERNEL_RELEASE" "$OUT_DIR/trees/modules-$KERNEL_RELEASE.tar.gz"
fi
dump_remote_tar firmware /lib/firmware "$OUT_DIR/trees/firmware.tar.gz"

if $VOLUME_DUMP; then
  volumes=()
  if [ "$ACTIVE_BANK" = "A" ] || [ "$ACTIVE_BANK" = "B" ]; then
    volumes=("kernel$ACTIVE_BANK" "bootcore$ACTIVE_BANK" "rootfs$ACTIVE_BANK")
    if $INCLUDE_INACTIVE; then
      if [ "$ACTIVE_BANK" = "A" ]; then
        volumes+=("kernelB" "bootcoreB" "rootfsB")
      else
        volumes+=("kernelA" "bootcoreA" "rootfsA")
      fi
    fi
  else
    echo "warning: active bank unknown; dumping all standard firmware volumes" >&2
    volumes=(kernelA bootcoreA rootfsA kernelB bootcoreB rootfsB)
  fi
  for volume in "${volumes[@]}"; do
    dump_ubi_volume "$volume" "$(manifest_size_for "$volume")"
  done
fi

if [ "$ACTIVE_BANK" = "A" ] || [ "$ACTIVE_BANK" = "B" ]; then
  active_kernel="$OUT_DIR/volumes/kernel$ACTIVE_BANK.bin"
  if [ -f "$active_kernel" ]; then
    cp "$active_kernel" "$OUT_DIR/observed-kernel-bundle/kernel.bin"
    "$BASE_DIR/audit/kernel-banner.sh" "$active_kernel" > "$OUT_DIR/observed-kernel-bundle/kernel-banner.txt" 2>/dev/null || true
  fi
fi
if [ -n "$KERNEL_RELEASE" ] && [ -f "$OUT_DIR/trees/modules-$KERNEL_RELEASE.tar.gz" ]; then
  mkdir -p "$OUT_DIR/observed-kernel-bundle/lib/modules/$KERNEL_RELEASE"
  tar -xzf "$OUT_DIR/trees/modules-$KERNEL_RELEASE.tar.gz" -C "$OUT_DIR/observed-kernel-bundle/lib/modules/$KERNEL_RELEASE" 2>/dev/null || true
fi
if [ -f "$OUT_DIR/trees/firmware.tar.gz" ]; then
  mkdir -p "$OUT_DIR/observed-kernel-bundle/lib/firmware"
  tar -xzf "$OUT_DIR/trees/firmware.tar.gz" -C "$OUT_DIR/observed-kernel-bundle/lib/firmware" 2>/dev/null || true
fi

if $INCLUDE_MTD; then
  "${SSH[@]}" 'cat /proc/mtd 2>/dev/null' | awk -F: '/^mtd[0-9]+:/ {print $1}' | while read -r mtd; do
    [ -n "$mtd" ] || continue
    echo "dump MTD $mtd -> $OUT_DIR/mtd/$mtd.bin" >&2
    if "${SSH[@]}" sh -s -- "$mtd" > "$OUT_DIR/mtd/$mtd.bin" <<'REMOTE'
set -eu
mtd="$1"
if command -v nanddump >/dev/null 2>&1; then
  nanddump -f - "/dev/$mtd" 2>/dev/null
else
  cat "/dev/$mtd"
fi
REMOTE
    then
      :
    else
      rm -f "$OUT_DIR/mtd/$mtd.bin"
      echo "warning: failed to dump /dev/$mtd" >&2
    fi
  done
fi

(
  cd "$OUT_DIR"
  sums_tmp=$(mktemp)
  find . -type f ! -name SHA256SUMS ! -name manifest.json -print | LC_ALL=C sort | while IFS= read -r f; do
    sha256sum "$f"
  done > "$sums_tmp"
  mv "$sums_tmp" SHA256SUMS
)

jq -n \
  --arg kind "8311-was-110-running-device-bundle" \
  --arg host "$HOST" \
  --arg user "$USER" \
  --arg collected_at "$stamp" \
  --arg active_bank "$ACTIVE_BANK" \
  --arg kernel_release "$KERNEL_RELEASE" \
  --arg manifest "$MANIFEST" \
  --argjson include_inactive "$INCLUDE_INACTIVE" \
  --argjson include_sensitive "$INCLUDE_SENSITIVE" \
  --argjson include_mtd "$INCLUDE_MTD" \
  --argjson volume_dump "$VOLUME_DUMP" \
  '{
    schema_version: 1,
    kind: $kind,
    collected_at: $collected_at,
    target: {host: $host, user: $user},
    active_bank: $active_bank,
    kernel_release: $kernel_release,
    expected_manifest: $manifest,
    options: {
      include_inactive: $include_inactive,
      include_sensitive: $include_sensitive,
      include_mtd: $include_mtd,
      volume_dump: $volume_dump
    },
    notes: [
      "This is binary/runtime evidence from a live unit, not GPL source.",
      "See SHA256SUMS for file identities.",
      "Files under sensitive/ and mtd/ may contain lab/device-specific secrets."
    ]
  }' > "$OUT_DIR/manifest.json"

if $MAKE_TAR; then
  tarball="$OUT_DIR.tar.gz"
  tar -czf "$tarball" -C "$OUT_ROOT" "$(basename "$OUT_DIR")"
  echo "wrote $tarball"
fi

echo "wrote $OUT_DIR"
