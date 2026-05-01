# Runbook: build -> flash -> verify

## 0. Prereqs

```
nix develop .#linux-build   # Linux build shell with artifact tools pinned
nix develop                # cross-platform audit shell
# or install: bash perl libdigest-crc-perl python3 jq squashfs-tools mtd-utils u-boot-tools p7zip
```

The build script uses `sudo unsquashfs` by default. On runners where the
build user can extract and chown the rootfs directly, use `SUDO=`.
Unprivileged CI/RBE builds should use `fakeroot` so device nodes round-trip
through `unsquashfs` and `mksquashfs`. macOS hosts will need a Linux remote
builder or VM for artifact builds; the default Nix shell is useful for audit
tooling on macOS.

## 1. Build

After selecting a reviewed vendor firmware set, update and review the pin
manifest:

```sh
# Option A: materialize locked public community inputs
./pins/fetch-public-inputs.sh \
  --out-dir vendor-blobs/public-community-inputs \
  --vendor-repo vendor-blobs/public-community-repo \
  --update-pins \
  --force
```

The public community path is traceable and reproducible, but it is not the
same as original vendor stock firmware. See `docs/SOURCE-TRACE.md`.

On Linux or a Linux remote builder, the same locked public source path can
build an audit pack without first materializing `vendor-blobs/`:

```sh
nix build .#publicCommunityRelease
ls result
```

That package fetches the locked public archives, injects the pinned
`8311-xgspon-bypass` submodule commit, runs `build.sh -R`, and verifies the
release pack/policy. Dirty local worktrees are allowed for developer
iteration, but the manifest records the dirty source state.

```sh
# Option B: use reviewed local vendor files
./pins/update-from-files.sh \
  --vendor-version <version> \
  --source-url <reviewed-url-or-path> \
  path/to/stock-bfw.img \
  path/to/basic-image-dir
git diff -- pins/inputs.json
```

For Bazel/RBE or shared lab handoff, materialize the same reviewed files as
a private vendor blob repository:

```sh
./pins/import-vendor-blobs.sh \
  --visibility '@//firmware/was110:__pkg__' \
  path/to/stock-bfw.img \
  path/to/basic-image-dir \
  /secure/was110-vendor-blobs
```

That directory is not committed; it is mounted, mirrored, or injected into
the private build graph. See `docs/VENDOR-BLOBS.md`.

```sh
./pins/verify.sh --strict path/to/stock-bfw.img path/to/basic-image-dir
./build.sh -i path/to/stock-bfw.img -I path/to/basic-image-dir
./audit/release-pack.sh out
./audit/verify-release-pack.sh out
./audit/verify-release-policy.sh out
# For formal audit packs:
./audit/verify-release-policy.sh --cve-baseline audit/cve-baseline-<release>.csv out
```

Outputs land in `out/`. The manifest at `out/manifest.json` is the
audit-ready record.

Inspect the kernel identity:

```sh
./audit/kernel-banner.sh out/kernel.bin
jq .kernel.banner out/manifest.json
```

Expected banner contains `Linux version 4.9.` and
`OpenWrt GCC 8.3.0 v19.07.8_maxlinear`. Anything else: stop and
investigate before flashing.

### External kernel bring-up

For a kernel built outside this repo:

```sh
./audit/verify-kernel-bundle.sh path/to/kernel-bundle
./audit/pack-kernel-bundle.sh path/to/kernel-bundle out/kernel-bundle.tar
./build.sh \
  -i path/to/stock-bfw.img \
  -I path/to/basic-image-dir \
  --kernel-bundle path/to/kernel-bundle
./audit/fingerprint.sh
```

The bundle must contain `kernel.bin` plus matching `lib/modules`; include
`lib/firmware` when the kernel expects firmware from rootfs. Granular
`--kernel-file` / `--kernel-root` options remain available for
sacrificial-unit bring-up. Signed release builds with an external kernel
must use `--kernel-bundle` with `kernel-build.json`; `--allow-module-mismatch`
should never be used for a signed release. See `docs/KERNEL-BUNDLE.md` for
the recommended `kernel-build.json` provenance payload.

For CI or Nix-driven builds, keep temporary rootfs extraction out of the
checkout:

```sh
SUDO= ./build.sh \
  -i path/to/stock-bfw.img \
  -I path/to/basic-image-dir \
  --work-dir /tmp/was110-work \
  --out-dir "$PWD/out"
```

Only use `SUDO=` when the build user can create the extracted rootfs tree
and preserve enough metadata for the later `mksquashfs -all-root` step.

## 2. Flash

Two paths, in order of preference.

### 2a. Local upgrade via the WAS-110 web UI (BFW path)

1. SSH or web UI on the unit. Confirm current `/etc/8311_version`.
2. Upload `out/local-upgrade.img` through the BFW upgrade form.
3. Unit reboots into the inactive slot. New `8311_version` should appear.
4. Verify (section 3) before promoting / before treating the unit as production.

### 2b. Local upgrade via SSH (basic path)

1. `scp out/local-upgrade.tar root@<unit>:/tmp/`
2. SSH in: `cd /tmp && tar xf local-upgrade.tar && ./upgrade.sh`
3. Unit reboots. Verify (section 3).

If the unit comes back wedged, both A/B slots remain on flash - boot
into the previous slot via u-boot console (serial pin enabled when
`8311_console_en=1`).

### 2c. Whole-image flash (factory recovery)

`out/whole-image.img` writes the entire SPI/NAND, including u-boot env.
Only used during initial provisioning or unbricking. Procedure depends
on hardware programmer; out of scope for this runbook.

## 3. Verify

```sh
./audit/collect-device-evidence.sh \
  --out-dir out \
  --fwenv-profile audit/fwenv-profile.example.json \
  <unit-ip> \
  root
```

This saves `out/verify-<unit-ip>-<timestamp>.txt`. The underlying
`verify-device.sh` script captures `/proc/version`, `/etc/8311_version`,
`/proc/mtd`, hashes of the UBI `kernelA/B`, `bootcoreA/B`, and
`rootfsA/B` volumes, and any `8311_*` fwenv overrides. Copy
`audit/fwenv-profile.example.json` to a site-specific profile and verify
against that profile after flashing. With a manifest supplied, matching
volumes are labeled `MATCH`. A mismatch in the booted bank is
`DIFF-ACTIVE`; a mismatch in the inactive bank is `DIFF-INACTIVE` and may
be expected when the other slot still contains an older firmware. The
verification command exits nonzero for a kernel banner mismatch, fwenv
profile mismatch, or any `DIFF-ACTIVE` volume mismatch.

- `/proc/version` contains `manifest.kernel.banner`
- active `kernel*` volume hash == `manifest.artifacts["kernel.bin"].sha256`
- active `bootcore*` volume hash == `manifest.artifacts["bootcore.bin"].sha256`
- active `rootfs*` volume hash == `manifest.artifacts["rootfs.img"].sha256`
- `8311_*` fwenv values match expected lab profile

Persist the captured output alongside the manifest in audit storage.

### 3a. Collect Running Binary Bundle

For source archaeology and deeper audit evidence, collect the currently
booted binary bundle from a live unit:

```sh
./audit/collect-running-bundle.sh \
  --out-dir out/device-bundles \
  --manifest out/manifest.json \
  <unit-ip> \
  root
```

This creates `out/device-bundles/<unit>-<timestamp>/` plus a `.tar.gz`
copy. By default it is read-only and collects:

- active `kernel*`, `bootcore*`, and `rootfs*` UBI volumes
- `/proc/version`, `/proc/cmdline`, `/proc/mtd`, `ubinfo`, package list,
  process list, module list, and filtered boot/fwenv data
- raw DTB when exposed at `/sys/firmware/fdt`
- `/proc/device-tree` / `/sys/firmware/devicetree/base` tarballs
- `/lib/modules/<uname -r>` and `/lib/firmware` tarballs
- an `observed-kernel-bundle/` directory containing the active
  `kernel.bin` and observed module/firmware trees

Pass `--include-inactive` to capture both A/B slots. Pass
`--include-sensitive` only for restricted lab storage; it includes full
`fw_printenv` and `/etc/config`. Pass `--include-mtd` only for forensic
work; raw MTD dumps can include bootloader/env/calibration material and
device-specific secrets.

This evidence is useful for comparing lab units, extracting the exact DTB
shape, identifying shipped PON modules/firmware/userland, and writing
complete GPL requests. It is not source and should not be described as a
self-built kernel bundle.

## 4. Audit pack

For each release, archive together:

```
release-<version>/
|-- manifest.json                        # from fingerprint.sh
|-- manifest.json.sig                    # cosign signature (CI)
|-- provenance.intoto.json               # from provenance.sh
|-- provenance.intoto.json.bundle        # cosign bundle (CI)
|-- audit-summary.md                     # human-readable summary
|-- cve-baseline-<version>.csv           # per docs/KERNEL-AUDIT.md
|-- inputs.json                          # snapshot of pins/inputs.json at build
`-- verify-<unit>-<date>.txt             # output of verify-device.sh per unit
```

This is what we hand to insurers / auditors.

## 4a. CI release build

`.github/workflows/release-build.yml` is a manual workflow for a Nix-enabled
Linux runner that already has the pinned vendor inputs available on disk.
Use a self-hosted runner or other controlled runner; do not upload vendor
blobs to the repository.

The workflow runs strict pin verification, builds with `-R`, runs
`audit/release-pack.sh`, verifies the release pack, enforces
`audit/verify-release-policy.sh`, and keyless-signs `manifest.json`,
`SHA256SUMS`, and `provenance.intoto.json` with `cosign`.

If `cve_baseline` is supplied to the workflow, it is copied into
`out/cve-baseline.csv` before `audit/release-pack.sh` runs, so the baseline
is included in `manifest.json` and `SHA256SUMS`.

For the pinned public community baseline, use
`.github/workflows/public-community-release.yml` after changes are merged to
`master`. This workflow uses GitHub-hosted Ubuntu by default, installs Nix
with a pinned `cachix/install-nix-action` commit, builds
`.#publicCommunityRelease` directly from committed public pins, verifies the
release pack, keyless-signs `manifest.json`, `SHA256SUMS`, and
`provenance.intoto.json` with GitHub OIDC/cosign bundles, and uploads the
signed release directory as a workflow artifact. Supplying `release_tag`
also creates a draft GitHub Release containing the signed pack.

To run the same public workflow on a pre-provisioned lab runner, dispatch it
with `runner_labels=["self-hosted","Linux"]` and `install_nix=false`.
Do not use the public workflow for private vendor drops or live-unit bundle
extracts; those belong in the controlled `release-build.yml` / Bazel private
CAS path.

For Bazel/RBE execution, use the `was110_firmware` rule and private vendor
blob repository described in `docs/BAZEL-RBE.md`. Remote execution is
appropriate only when the remote CAS/worker pool is inside the lab trust
boundary for vendor firmware. Validate rule analysis without real blobs
with:

```sh
bazel query //bazel/platforms:was110_rbe_linux
bazel build --nobuild //tests/bazel:analysis_fixture
```

## 5. Rolling forward

- Vendor releases new BFW image -> update `pins/inputs.json` in a PR,
  rebuild, retest, retag.
- Linux 4.9.x backport published via vendor -> same flow; banner string
  in the manifest will change accordingly.
- GPL sources arrive -> see `docs/ARCHITECTURE.md` section "Tomorrow"; the
  replacement artifact is a kernel bundle (`kernel.bin` plus matching
  modules/firmware), passed through `--kernel-bundle`.
