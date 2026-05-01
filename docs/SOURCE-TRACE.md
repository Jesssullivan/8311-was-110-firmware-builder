# Source trace for required inputs

The builder needs two binary input sets:

| input | required files | current public trace |
| --- | --- | --- |
| BFW image | `local-upgrade.img` passed to `build.sh -i` | 8311 community `v2.4.0` BFW archive, extracted `local-upgrade.img` |
| Basic image dir | `bootcore.bin`, `kernel.bin`, `rootfs.img` passed to `build.sh -I` | 8311 community `v2.8.3` basic archive |
| `8311-xgspon-bypass` | submodule files copied into rootfs by `mods/common-mods.sh` | Git commit `69f3c0e4b88505b168c89796386d12bfd705a30d` |

This is a community-baseline trace, not original vendor stock firmware.
Original BFW/Azores, MaxLinear, and Potron source requests remain tracked
under `docs/gpl-requests/`.

## Public community baseline

The exact lock is `pins/public-source-lock.json`.

```sh
nix develop
./pins/fetch-public-inputs.sh \
  --archive-dir /mirror/was110/public-archives \
  --offline \
  --out-dir vendor-blobs/public-community-inputs \
  --vendor-repo vendor-blobs/public-community-repo \
  --update-pins \
  --force
```

This downloads the locked public archives, verifies archive and extracted
file hashes, extracts:

```text
vendor-blobs/public-community-inputs/
|-- bfw/local-upgrade.img
`-- basic/
    |-- bootcore.bin
    |-- kernel.bin
    `-- rootfs.img
```

Then it can create a private Bazel blob repo at
`vendor-blobs/public-community-repo/`.

Because these seed inputs are public and content-pinned, the generated
repo can also be mirrored or staged for Bazel/RBE. Treat the SHA-256
values in `pins/public-source-lock.json`, not the mutable GitHub release
URLs, as the identity of the staged inputs.

For internet-connected bootstrap, omit `--archive-dir --offline` and the
script downloads from the locked upstream URLs. For CI/RBE, mirror the two
archive assets into an internal artifact store under their recorded asset
names and keep `--offline` enabled.

To verify the committed pins match this lock without downloading blobs:

```sh
./pins/verify-public-source-lock.sh
```

To build from the lock directly on Linux:

```sh
nix build .#publicCommunityRelease
```

The Nix package fetches the locked archives via fixed-output derivations and
fetches `8311-xgspon-bypass` at git commit
`69f3c0e4b88505b168c89796386d12bfd705a30d`, matching the repository
submodule gitlink. That commit and its Nix fetch hash are recorded in
`pins/public-source-lock.json`. The resulting `result/` directory is a
verified release pack.

## Locked sources

### BFW image

- Source: `djGrrr/8311-was-110-firmware-builder` release `v2.4.0`
- Asset: `WAS-110_8311_firmware_mod_2.4.0_bfw.7z`
- URL: <https://github.com/djGrrr/8311-was-110-firmware-builder/releases/download/v2.4.0/WAS-110_8311_firmware_mod_2.4.0_bfw.7z>
- Archive SHA-256: `b0b03bc28c540239beffb3a9e64f653c4a403d2e7e97a291b2ed785a05079031`
- Extracted file: `local-upgrade.img`
- Extracted SHA-256: `9e93115074604376f275d88551a3d926b2a1cd1ab3cf7c22f64d03b8031f2ca7`

`v2.4.0` is the latest public 8311 release found with a BFW archive asset
during the 2026-05-01 source-lock review. Its rootfs contains `/ptrom`,
which the current builder expects from the BFW input path.

### Basic image dir

- Source: `djGrrr/8311-was-110-firmware-builder` release `v2.8.3`
- Asset: `WAS-110_8311_firmware_mod_v2.8.3_basic.7z`
- URL: <https://github.com/djGrrr/8311-was-110-firmware-builder/releases/download/v2.8.3/WAS-110_8311_firmware_mod_v2.8.3_basic.7z>
- Archive SHA-256: `5d72e7552e396127b59a548c6163113d088d545708aecb0fed38097b862288f8`

Extracted files:

| file | SHA-256 |
| --- | --- |
| `bootcore.bin` | `e99e25332bdcb3c9b0447abad1be9b1e54511b6bda99f2b51ae2499db5b905a4` |
| `kernel.bin` | `d66b24cf873cc1071a3aa2d155bf677f503f10d221513e469083f8a591f6b96c` |
| `rootfs.img` | `756da584829d8ef144bdd8e400fb763ff31711e2b84e430912118fb6093b7e33` |

## Source notes

PON wiki documents the 8311 community firmware download location and notes
that the basic firmware is based on a MaxLinear OpenWrt 19.07 build from
Potrontec. The multicast recovery guide documents that the community
archive contains the `kernel.bin`, `bootcore.bin`, and `rootfs.img` blobs
used to compose multicast images.

The repository submodule URL is an SSH GitHub URL in `.gitmodules`; the
Nix release build uses the equivalent public HTTPS URL from the source lock
so remote builders do not need GitHub deploy keys for this public source.

## Open Origin Questions

The current public trace starts at the `djGrrr/8311-was-110-firmware-builder`
release assets. It does not yet prove where those release assets obtained:

- the original BFW-format stock `local-upgrade.img`
- the basic `bootcore.bin`, `kernel.bin`, and `rootfs.img`
- the MaxLinear `v19.07.8_maxlinear` OpenWrt/UGW build inputs
- PON driver, OMCI daemon, and firmware package source
- U-Boot `2016.07-MXL-v-3.1.261` source/config

Use `audit/collect-running-bundle.sh` against lab modules to extract the
currently booted binary volumes, DTB/device-tree, module tree, firmware
tree, package inventory, and PON runtime inventory. That output gives us
device-local evidence to compare against the public release assets and
against the public PRX126/PRX300 source candidates in
`pins/source-stack-candidates.json`.

To materialize the public Git source candidates for PRX126 kernel
reconstruction work:

```sh
./pins/verify-source-stack-candidates.sh
./pins/fetch-source-stack-candidates.sh \
  --out-dir vendor-blobs/source-stack-candidates \
  --only prpl-feed-target-mips-ugw-8.5.2 \
  --force
```

This produces local checkouts and `source-stack.manifest.json`; add
`--pack-archives` only when source tarballs are needed for handoff or
Bazel/RBE staging, and omit `--only` only for a full source-candidate
materialization.
