#!/bin/bash
_help() {
	printf -- 'Tool for building new modded WAS-110 firmware images\n\n'
	printf -- 'Usage: %s [options]\n\n' "$0"
	printf -- 'Options:\n'
	printf -- '-i --image <filename>\t\tSpecify stock local upgrade image file of BFW firmware.\n'
	printf -- '-I --image-dir <dir>\t\tSpecify stock image directory of the basic firmware (must contain bootcore.bin, kernel.bin, and rootfs.img).\n'
	printf -- '-o --image-out <filename>\tSpecify local upgrade image file to output.\n'
	printf -- '-O --tar-out <filename>\t\tSpecify local upgrade tar file to output.\n'
	printf -- '--out-dir <dir>\t\t\tSpecify build output directory (default: out).\n'
	printf -- '--work-dir <dir>\t\tSpecify temporary rootfs work directory (default: repo root).\n'
	printf -- '-V --image-version <version>\tSpecify custom image version string.\n'
	printf -- '-r --image-revision <revision>\tSpecify custom image revision string.\n'
	printf -- '-w --basic\t\t\tBuild a basic variant image.\n'
	printf -- '-W --bfw\t\t\tBuild a bfw variant image.\n'
	printf -- '-k --basic-kernel\t\tBuild image using the basic kernel.\n'
	printf -- '-K --bfw-kernel\t\t\tBuild image using the bfw kernel.\n'
	printf -- '--kernel-bundle <dir>\t\tBuild image using a self-built kernel bundle (kernel.bin + lib/modules).\n'
	printf -- '--kernel-file <filename>\tBuild image using an externally supplied kernel.bin.\n'
	printf -- '--kernel-root <dir>\t\tRoot tree containing lib/modules and optional lib/firmware for --kernel-file.\n'
	printf -- '--kernel-modules-dir <dir>\tModule tree to install as /lib/modules for --kernel-file.\n'
	printf -- '--kernel-firmware-dir <dir>\tFirmware tree to install as /lib/firmware for --kernel-file.\n'
	printf -- '--allow-module-mismatch\t\tAllow --kernel-file without matching modules. For lab bring-up only.\n'
	printf -- '-b --basic-bootcore\t\tBuild image using the basic bootcore.\n'
	printf -- '-B --bfw-bootcore\t\tBuild image using the bfw bootcore.\n'
	printf -- '-R --release\t\tCreate release archive files.\n'

	printf -- '-h --help\t\t\tThis help text\n'
}

IMGFILE=
IMGDIR=
BASE_DIR=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
TOOLS_DIR="$BASE_DIR/tools"
OUT_DIR="$BASE_DIR/out"
WORK_DIR="$BASE_DIR"
LIB_DIR="$BASE_DIR/lib"
IMG_OUT=""
TAR_OUT=""
FW_VARIANT="basic"
BOOTCORE_VARIANT=""
FW_VER=""
KERNEL_VARIANT=""
KERNEL_BUNDLE=""
KERNEL_FILE=""
KERNEL_ROOT=""
KERNEL_MODULES_DIR=""
KERNEL_FIRMWARE_DIR=""
KERNEL_MODULES_SOURCE=""
KERNEL_FIRMWARE_SOURCE=""
KERNEL_SOURCE_HINT=""
KERNEL_BUILD_JSON=""
ALLOW_MODULE_MISMATCH=false
RELEASE=false
SUDO="${SUDO-sudo}"

while [ $# -gt 0 ]; do
	case "$1" in
		-i|--image|--bfw-image-file)
			IMGFILE="$2"
			shift
		;;
		-I|--image-dir|--basic-image-dir)
			IMGDIR="$2"
			shift
		;;
		-o|--image-out)
			IMG_OUT="$2"
			shift
		;;
		-O|--tar-out)
			TAR_OUT="$2"
			shift
		;;
		--out-dir)
			OUT_DIR="$2"
			shift
		;;
		--work-dir)
			WORK_DIR="$2"
			shift
		;;
		-V|--image-version)
			FW_VER="$2"
			shift
		;;
		-r|--image-revision)
			FW_REV="$2"
			shift
		;;
		-w|--basic)
			FW_VARIANT="basic"
		;;
		-W|--bfw)
			FW_VARIANT="bfw"
		;;
		-k|--basic-kernel)
			KERNEL_VARIANT="basic"
		;;
		-K|--bfw-kernel)
			KERNEL_VARIANT="bfw"
		;;
		--kernel-bundle)
			KERNEL_BUNDLE="$2"
			shift
		;;
		--kernel-file)
			KERNEL_FILE="$2"
			shift
		;;
		--kernel-root)
			KERNEL_ROOT="$2"
			shift
		;;
		--kernel-modules-dir)
			KERNEL_MODULES_DIR="$2"
			shift
		;;
		--kernel-firmware-dir)
			KERNEL_FIRMWARE_DIR="$2"
			shift
		;;
		--allow-module-mismatch)
			ALLOW_MODULE_MISMATCH=true
		;;
		-b|--basic-bootcore)
			BOOTCORE_VARIANT="basic"
		;;
		-B|--bfw-bootcore)
			BOOTCORE_VARIANT="bfw"
		;;
		-R|--release)
			RELEASE=true
		;;
		-h|--help)
			_help
			exit 0
		;;
		*)
			_help
			exit 1
		;;
	esac
	shift
done

_err() {
	echo "$1" >&2
	exit ${2:-1}
}

sha256() {
	{ [ -n "$1" ] &&  sha256sum "$1" || sha256sum; } | awk '{print $1}'
}

file_size() {
	stat -c "%s" "$1"
}

tree_sha256() {
	dir="$1"
	[ -d "$dir" ] || { echo ""; return; }
	(
		cd "$dir"
		find . \( -type f -o -type l \) -print | LC_ALL=C sort | while IFS= read -r rel; do
			clean=${rel#./}
			if [ -L "$rel" ]; then
				printf 'L  %s  %s\n' "$clean" "$(readlink "$rel")"
			else
				printf 'F  %s  %s\n' "$clean" "$(sha256 "$rel")"
			fi
		done
	) | sha256sum | awk '{print $1}'
}

json_str() {
	jq -Rn --arg v "$1" '$v'
}

json_file_or_null() {
	if [ -n "$1" ] && [ -f "$1" ]; then
		jq '.' "$1"
	else
		printf 'null\n'
	fi
}

check_file() {
	[ -f "$1" ] && [ "$(sha256 "$1")" = "$2" ]
}

expected_hash() {
	EXPECTED_HASH="$2"
	FINAL_HASH=$(sha256 "$1")
	if ! [ "$FINAL_HASH" = "$EXPECTED_HASH" ]; then
		_err "Final '$1' SHA256 hash '$FINAL_HASH' != '$EXPECTED_HASH'" >&2
	fi
}

run_sudo() {
	if [ -n "$SUDO" ]; then
		"$SUDO" "$@"
	else
		"$@"
	fi
}

git_cmd() {
	git -C "$BASE_DIR" "$@" 2>/dev/null
}

GIT_HASH=$(git_cmd rev-parse --short HEAD || true)
if [ -z "$GIT_HASH" ]; then
	if [ -n "${SOURCE_GIT_REV_SHORT:-}" ]; then
		GIT_HASH="$SOURCE_GIT_REV_SHORT"
	elif [ -n "${SOURCE_GIT_REV:-}" ]; then
		GIT_HASH="${SOURCE_GIT_REV:0:12}"
	else
		GIT_HASH="unknown"
	fi
fi

GIT_DIFF="$(git_cmd diff HEAD || true)"
GIT_DIFF_HASH="${SOURCE_GIT_DIFF_HASH:-}"
if git_cmd rev-parse --git-dir >/dev/null; then
	GIT_TAG=$(git_cmd tag --points-at HEAD | grep -P '^v\d+\.\d+\.\d+' | tr '-' '~' | sort -V -r | tr '~' '-' | head -n1)
else
	GIT_TAG="${SOURCE_GIT_TAG:-}"
fi
GIT_EPOCH=$(git_cmd log -1 --format="%at" || true)
GIT_EPOCH=${GIT_EPOCH:-${SOURCE_GIT_EPOCH:-0}}

FW_SUFFIX=""
FW_VER="${FW_VER:-${GIT_TAG:-""}}"
[ -n "$GIT_DIFF" ] && FW_SUFFIX="~$(echo "$GIT_DIFF" | sha256 | head -c 7)"
if [ -z "$FW_SUFFIX" ] && [ "${SOURCE_GIT_DIRTY:-false}" = "true" ] && [ -n "$GIT_DIFF_HASH" ]; then
	FW_SUFFIX="~$(printf '%s' "$GIT_DIFF_HASH" | head -c 7)"
fi
[ -n "$FW_VER" ] && FW_VERSION="${FW_VER}${FW_SUFFIX}" || { FW_VER="dev"; FW_VERSION="dev"; }

FW_REV="${FW_REV:-$GIT_HASH}"
FW_REVISION="$FW_REV$FW_SUFFIX"

set -e

OUT_DIR=$(realpath -m "$OUT_DIR")
WORK_DIR=$(realpath -m "$WORK_DIR")
mkdir -pv "$WORK_DIR"

if [ -n "$IMGFILE" ]; then
	IMG_FILE=$(realpath "$IMGFILE")
	[ -f "$IMG_FILE" ] || _err "Image file '$IMG_FILE' does not exist."

	HEADER="$OUT_DIR/header.bin"
else
	_err "Must specify --bfw-image-file"
fi

if [ -n "$IMGDIR" ] && [ -d "$IMGDIR" ]; then
	IMG_DIR=$(realpath "$IMGDIR")
	[ -d "$IMG_DIR" ] || _err "Image directory '$IMG_DIR' does not exist."
else
	_err "Must specify --basic-image-dir"
fi

if [ -n "$KERNEL_BUNDLE" ]; then
	[ -z "$KERNEL_FILE" ] && [ -z "$KERNEL_ROOT" ] && [ -z "$KERNEL_MODULES_DIR" ] && [ -z "$KERNEL_FIRMWARE_DIR" ] \
		|| _err "--kernel-bundle cannot be combined with granular kernel-file/root/modules/firmware options."
	KERNEL_BUNDLE=$(realpath "$KERNEL_BUNDLE")
	[ -d "$KERNEL_BUNDLE" ] || _err "Kernel bundle '$KERNEL_BUNDLE' does not exist."
	"$BASE_DIR/audit/verify-kernel-bundle.sh" "$KERNEL_BUNDLE" >/dev/null || _err "Kernel bundle '$KERNEL_BUNDLE' failed validation."
	KERNEL_FILE="$KERNEL_BUNDLE/kernel.bin"
	KERNEL_ROOT="$KERNEL_BUNDLE"
	KERNEL_SOURCE_HINT="external:kernel-bundle"
	[ -f "$KERNEL_BUNDLE/kernel-build.json" ] && KERNEL_BUILD_JSON="$KERNEL_BUNDLE/kernel-build.json"
fi

if [ -z "$KERNEL_FILE" ] && { [ -n "$KERNEL_ROOT" ] || [ -n "$KERNEL_MODULES_DIR" ] || [ -n "$KERNEL_FIRMWARE_DIR" ]; }; then
	_err "--kernel-root/--kernel-modules-dir/--kernel-firmware-dir require --kernel-file or --kernel-bundle."
fi

if [ -n "$KERNEL_FILE" ]; then
	KERNEL_FILE=$(realpath "$KERNEL_FILE")
	[ -f "$KERNEL_FILE" ] || _err "Kernel file '$KERNEL_FILE' does not exist."
	mkimage -l "$KERNEL_FILE" >/dev/null || _err "Kernel file '$KERNEL_FILE' is not a u-boot image mkimage can read."
	KERNEL_VARIANT="external"
fi

if [ -n "$KERNEL_ROOT" ]; then
	KERNEL_ROOT=$(realpath "$KERNEL_ROOT")
	[ -d "$KERNEL_ROOT" ] || _err "Kernel root '$KERNEL_ROOT' does not exist."
fi

if [ -n "$KERNEL_MODULES_DIR" ]; then
	KERNEL_MODULES_DIR=$(realpath "$KERNEL_MODULES_DIR")
	[ -d "$KERNEL_MODULES_DIR" ] || _err "Kernel modules directory '$KERNEL_MODULES_DIR' does not exist."
fi

if [ -n "$KERNEL_FIRMWARE_DIR" ]; then
	KERNEL_FIRMWARE_DIR=$(realpath "$KERNEL_FIRMWARE_DIR")
	[ -d "$KERNEL_FIRMWARE_DIR" ] || _err "Kernel firmware directory '$KERNEL_FIRMWARE_DIR' does not exist."
fi

rm -rfv "$OUT_DIR"
mkdir -pv "$OUT_DIR"

KERNEL_BFW="$OUT_DIR/kernel-bfw.bin"
KERNEL_BASIC="$IMG_DIR/kernel.bin"

BOOTCORE_BFW="$OUT_DIR/bootcore-bfw.bin"
BOOTCORE_BASIC="$IMG_DIR/bootcore.bin"

ROOTFS_BFW="$OUT_DIR/rootfs-bfw.img"
ROOTFS_BASIC="$IMG_DIR/rootfs.img"

KERNEL_VARIANT="${KERNEL_VARIANT:-$FW_VARIANT}"
BOOTCORE_VARIANT="${BOOTCORE_VARIANT:-$FW_VARIANT}"

case "$KERNEL_VARIANT" in
	bfw)
		KERNEL="$KERNEL_BFW"
		KERNEL_SOURCE="bfw-image:kernel.bin"
	;;
	basic)
		KERNEL="$KERNEL_BASIC"
		KERNEL_SOURCE="basic-image-dir:kernel.bin"
	;;
	external)
		KERNEL="$KERNEL_FILE"
		KERNEL_SOURCE="${KERNEL_SOURCE_HINT:-external:kernel-file}"
	;;
	*)
		_err "Invalid kernel variant '$KERNEL_VARIANT'"
	;;
esac

if $RELEASE && [ "$KERNEL_VARIANT" = "external" ] && [ -z "$KERNEL_BUILD_JSON" ]; then
	_err "Release builds with an external kernel require --kernel-bundle containing kernel-build.json."
fi

case "$BOOTCORE_VARIANT" in
	bfw)
		BOOTCORE="$BOOTCORE_BFW"
		BOOTCORE_SOURCE="bfw-image:bootcore.bin"
	;;
	basic)
		BOOTCORE="$BOOTCORE_BASIC"
		BOOTCORE_SOURCE="basic-image-dir:bootcore.bin"
	;;
	*)
		_err "Invalid bootcore variant '$BOOTCORE_VARIANT'"
	;;
esac

./extract.sh -i "$IMGFILE" -H "$HEADER" -b "$BOOTCORE_BFW" -k "$KERNEL_BFW" -r "$ROOTFS_BFW" || _err "Error extracting image '$IMG_FILE'"


echo

ROOTFS="$OUT_DIR/rootfs.img"
ROOTFS_RESET="$OUT_DIR/rootfs-reset.img"

[ -f "$HEADER" ] || _err "Header file '$HEADER' does not exist."
[ -f "$BOOTCORE" ] || _err "Bootcore file '$BOOTCORE' does not exist."
[ -f "$KERNEL" ] || _err "Kernel file '$KERNEL' does not exist."
[ -f "$ROOTFS_BFW" ] || _err "RootFS file '$ROOTFS_BFW' does not exist."
[ -f "$ROOTFS_BASIC" ] || _err "RootFS file '$ROOTFS_BASIC' does not exist."

ROOT_BASE="$WORK_DIR/rootfs"
ROOT_BFW="${ROOT_BASE}-bfw"
ROOT_BASIC="${ROOT_BASE}-basic"

ROOT_DIR="${ROOT_BASE}-${FW_VARIANT}"

rm -rfv "$ROOT_BASE" "$ROOT_BFW" "$ROOT_BASIC"

run_sudo unsquashfs -d "$ROOT_BFW" "$ROOTFS_BFW" || _err "Error unsquashifying bfw RootFS image '$ROOTFS_BFW'"
run_sudo unsquashfs -d "$ROOT_BASIC" "$ROOTFS_BASIC" || _err "Error unsquashifying basic RootFS image '$ROOTFS_BASIC'"

ln -s "rootfs-${FW_VARIANT}" "$ROOT_BASE"

[ -d "$ROOT_BFW/ptrom" ] || _err "/ptrom not found in bfw rootfs"
[ -d "$ROOT_BASIC/ptrom" ] && _err "/ptrom found in basic rootfs"

USER=$(id -un)
GROUP=$(id -gn)

run_sudo chown -R "$USER:$GROUP" "$ROOT_BASIC" "$ROOT_BFW"

FW_LONG_VERSION="${FW_VER}_${FW_VARIANT}_${FW_REV}${FW_SUFFIX}"

. mods/binary-mods.sh

. mods/pre-common-mods.sh

. "mods/${FW_VARIANT}-mods.sh"
[ "$FW_VARIANT" = "basic" ] && . mods/basic-i18n.sh

install_external_kernel_payload() {
	[ "$KERNEL_VARIANT" = "external" ] || return 0

	local modules_src="$KERNEL_MODULES_DIR"
	local firmware_src="$KERNEL_FIRMWARE_DIR"

	if [ -z "$modules_src" ] && [ -n "$KERNEL_ROOT" ] && [ -d "$KERNEL_ROOT/lib/modules" ]; then
		modules_src="$KERNEL_ROOT/lib/modules"
	fi

	if [ -z "$firmware_src" ] && [ -n "$KERNEL_ROOT" ] && [ -d "$KERNEL_ROOT/lib/firmware" ]; then
		firmware_src="$KERNEL_ROOT/lib/firmware"
	fi

	if [ -z "$modules_src" ]; then
		if $ALLOW_MODULE_MISMATCH; then
			echo "WARNING: external kernel supplied without matching modules; keeping ${FW_VARIANT} rootfs modules."
		else
			_err "External kernel requires --kernel-root with lib/modules or --kernel-modules-dir. Use --allow-module-mismatch only for bring-up."
		fi
	else
		KERNEL_MODULES_SOURCE="$modules_src"
		rm -rfv "$ROOT_DIR/lib/modules"
		mkdir -pv "$ROOT_DIR/lib/modules"
		cp -va "$modules_src/." "$ROOT_DIR/lib/modules"
	fi

	if [ -n "$firmware_src" ]; then
		KERNEL_FIRMWARE_SOURCE="$firmware_src"
		rm -rfv "$ROOT_DIR/lib/firmware"
		mkdir -pv "$ROOT_DIR/lib/firmware"
		cp -va "$firmware_src/." "$ROOT_DIR/lib/firmware"
	fi
}

install_external_kernel_payload

for required in \
	8311-xgspon-bypass/8311-detect-config.sh \
	8311-xgspon-bypass/8311-fix-vlans.sh \
	8311-xgspon-bypass/8311-vlans-lib.sh
do
	[ -f "$BASE_DIR/$required" ] || _err "Missing required submodule file '$required'. Run: git submodule update --init"
done

. mods/common-mods.sh

VERSION_FILE="$ROOT_DIR/etc/8311_version"
cat > "$VERSION_FILE" <<8311_VER
FW_VER=$FW_VER
FW_VERSION=$FW_VERSION
FW_LONG_VERSION=$FW_LONG_VERSION
FW_REV=$FW_REV
FW_REVISION=$FW_REVISION
FW_VARIANT=$FW_VARIANT
FW_SUFFIX=$FW_SUFFIX
8311_VER


REAL_OUT=$(realpath "$OUT_DIR")

OUT_BOOTCORE="$REAL_OUT/bootcore.bin"
[ "$BOOTCORE" = "$OUT_BOOTCORE" ] || cp -fv "$BOOTCORE" "$OUT_BOOTCORE"
OUT_KERNEL="$REAL_OUT/kernel.bin"
[ "$KERNEL" = "$OUT_KERNEL" ] || cp -fv "$KERNEL" "$OUT_KERNEL"
if [ -n "$KERNEL_BUILD_JSON" ]; then
	cp -fv "$KERNEL_BUILD_JSON" "$REAL_OUT/kernel-build.json"
	KERNEL_BUILD_JSON_OUT="$REAL_OUT/kernel-build.json"
else
	KERNEL_BUILD_JSON_OUT=""
fi

BUILD_INPUTS="$REAL_OUT/build-inputs.json"
KERNEL_BANNER=$("$BASE_DIR/audit/kernel-banner.sh" "$OUT_KERNEL" 2>/dev/null || true)
KERNEL_MODULES_TREE_SHA256="$([ -n "$KERNEL_MODULES_SOURCE" ] && tree_sha256 "$KERNEL_MODULES_SOURCE" || true)"
KERNEL_FIRMWARE_TREE_SHA256="$([ -n "$KERNEL_FIRMWARE_SOURCE" ] && tree_sha256 "$KERNEL_FIRMWARE_SOURCE" || true)"
INSTALLED_MODULES_TREE_SHA256="$([ -d "$ROOT_DIR/lib/modules" ] && tree_sha256 "$ROOT_DIR/lib/modules" || true)"
INSTALLED_FIRMWARE_TREE_SHA256="$([ -d "$ROOT_DIR/lib/firmware" ] && tree_sha256 "$ROOT_DIR/lib/firmware" || true)"
cat > "$BUILD_INPUTS" <<8311_BUILD_INPUTS
{
  "schema_version": 1,
  "firmware": {
    "variant": $(json_str "$FW_VARIANT"),
    "version": $(json_str "$FW_VERSION"),
    "revision": $(json_str "$FW_REVISION")
  },
  "kernel": {
    "variant": $(json_str "$KERNEL_VARIANT"),
    "source": $(json_str "$KERNEL_SOURCE"),
    "source_path": $(json_str "$(realpath "$KERNEL")"),
    "sha256": $(json_str "$(sha256 "$OUT_KERNEL")"),
    "size_bytes": $(file_size "$OUT_KERNEL"),
    "banner": $(json_str "$KERNEL_BANNER"),
    "modules_source": $(json_str "$KERNEL_MODULES_SOURCE"),
    "modules_tree_sha256": $(json_str "$KERNEL_MODULES_TREE_SHA256"),
    "firmware_source": $(json_str "$KERNEL_FIRMWARE_SOURCE"),
    "firmware_tree_sha256": $(json_str "$KERNEL_FIRMWARE_TREE_SHA256"),
    "installed_modules_tree_sha256": $(json_str "$INSTALLED_MODULES_TREE_SHA256"),
    "installed_firmware_tree_sha256": $(json_str "$INSTALLED_FIRMWARE_TREE_SHA256"),
    "allow_module_mismatch": $ALLOW_MODULE_MISMATCH,
    "build_provenance_path": $(json_str "$KERNEL_BUILD_JSON_OUT"),
    "build_provenance_sha256": $(json_str "$([ -n "$KERNEL_BUILD_JSON_OUT" ] && sha256 "$KERNEL_BUILD_JSON_OUT" || true)"),
    "build_provenance": $(json_file_or_null "$KERNEL_BUILD_JSON_OUT")
  },
  "bootcore": {
    "variant": $(json_str "$BOOTCORE_VARIANT"),
    "source": $(json_str "$BOOTCORE_SOURCE"),
    "source_path": $(json_str "$(realpath "$BOOTCORE")"),
    "sha256": $(json_str "$(sha256 "$OUT_BOOTCORE")"),
    "size_bytes": $(file_size "$OUT_BOOTCORE")
  },
  "rootfs": {
    "bfw_source_path": $(json_str "$ROOTFS_BFW"),
    "basic_source_path": $(json_str "$ROOTFS_BASIC")
  }
}
8311_BUILD_INPUTS

IMG_OUT="${IMG_OUT:-"$REAL_OUT/local-upgrade.img"}"
TAR_OUT="${TAR_OUT:-"$REAL_OUT/local-upgrade.tar"}"

env -u SOURCE_DATE_EPOCH mksquashfs "$ROOT_DIR" "$ROOTFS" -all-root -noappend -no-xattrs -comp xz -b 256K -all-time "$GIT_EPOCH" -mkfs-time "$GIT_EPOCH" || _err "Error creating new rootfs image"

. mods/reset-mods.sh

env -u SOURCE_DATE_EPOCH mksquashfs "$ROOT_DIR" "$ROOTFS_RESET" -all-root -noappend -no-xattrs -comp xz -b 256K -all-time "$GIT_EPOCH" -mkfs-time "$GIT_EPOCH" || _err "Error creating new factory reset rootfs image"

touch -d "@$GIT_EPOCH" "$ROOTFS" "$ROOTFS_RESET"
OUT_UROOTFS="$REAL_OUT/urootfs.img"
OUT_UROOTFS_RESET="$REAL_OUT/urootfs-reset.img"
SOURCE_DATE_EPOCH="$GIT_EPOCH" mkimage -A MIPS -O Linux -T filesystem -C none -n "$FW_LONG_VERSION" -d "$ROOTFS" "$OUT_UROOTFS"
SOURCE_DATE_EPOCH="$GIT_EPOCH" mkimage -A MIPS -O Linux -T filesystem -C none -n "MC Factory Reset $FW_VER" -d "$ROOTFS_RESET" "$OUT_UROOTFS_RESET"

#OUT_UMULTI="$REAL_OUT/uMulti.img"
#mkimage -A MIPS -O Linux -T multi -C none -n "MC $FW_LONG_VERSION" -d "$OUT_KERNEL:$OUT_BOOTCORE:$OUT_UROOTFS" "$OUT_UMULTI"

OUT_MCUPG="$REAL_OUT/multicast_upgrade.img"
cat "$OUT_KERNEL" "$OUT_BOOTCORE" "$OUT_UROOTFS" > "$OUT_MCUPG"

OUT_MCRESET="$REAL_OUT/multicast_reset.img"
cat "$OUT_KERNEL" "$OUT_BOOTCORE" "$OUT_UROOTFS_RESET" > "$OUT_MCRESET"

touch -d "@$GIT_EPOCH" "$OUT_MCUPG" "$OUT_MCRESET"

CREATE=("-b" "$OUT_BOOTCORE" "-k" "$OUT_KERNEL" "-r" "$ROOTFS" -D "@$GIT_EPOCH")
./create.sh --basic -i "$TAR_OUT" -F "$VERSION_FILE" "${CREATE[@]}"
./create.sh --bfw -i "$IMG_OUT" -V "$FW_VER" -L "$FW_LONG_VERSION" -H "$HEADER" "${CREATE[@]}"

rm -fv "$HEADER" "$KERNEL_BFW" "$BOOTCORE_BFW" "$ROOTFS_BFW" "$OUT_UROOTFS" "$OUT_UROOTFS_RESET" "$ROOTFS_RESET"

./wholeImage.sh "$GIT_EPOCH" "$REAL_OUT"

if $RELEASE; then
	cd "$REAL_OUT"
	REL_NAME="WAS-110_8311_firmware_mod_${FW_VERSION}_${FW_VARIANT}"
	7z a -md=128m -mx=9 -ms=on -mmt=on -mmtf=on -m0=LZMA2 "$REL_NAME.7z" -- "local-upgrade.tar" "local-upgrade.img" "multicast_upgrade.img" "multicast_reset.img" "bootcore.bin" "kernel.bin" "rootfs.img" "whole-image.img"
	cd "$BASE_DIR"
	cat "files/7z/7zsd_LZMA2_upx.sfx" "files/7z/was-110.cfg" "$REAL_OUT/$REL_NAME.7z" > "$REAL_OUT/$REL_NAME.exe"
fi

echo "Firmware build $FW_LONG_VERSION complete."
