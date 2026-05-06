# WAS-110 kernel upgrade path

Last reviewed: 2026-05-01.

Execution tracker: `docs/DELIVERABLES.md` and Linear project
<https://linear.app/tinyland/project/was-110-kernel-upgradability-and-audit-build-e5c3c9b147a4>.

## Thesis

Finding the exact source for the currently shipped WAS-110 `4.9.308+`
kernel is valuable, but it is not the only unblocker for lab kernel
upgradability.

The release engineering goal is narrower and more practical:

1. produce a bootable PRX126 `kernel.bin`,
2. ship the matching `lib/modules` and any required `lib/firmware`,
3. record source, config, toolchain, and output hashes in
   `kernel-build.json`,
4. inject that bundle through `build.sh --kernel-bundle`, and
5. verify on a flashed module that the active kernel volume and runtime
   banner match the signed release manifest.

Exact vendor source gives us the best starting point. A reconstructed
PRX126 kernel from public UGW/OpenWrt sources can still be useful if it
boots, loads matching modules, keeps PON registration stable, and is
attested as the kernel we actually built.

## Current source position

The current public-source finding is machine-readable in
`pins/source-stack-candidates.json`:

- exact WAS-110 `4.9.308+` kernel source: not found publicly
- exact `v19.07.8_maxlinear` SDK/feed revisions: not found publicly
- usable public scaffolding: yes
- public OpenWrt baseline: OpenWrt `v19.07.8`
- PRX126/PRX300 candidates: prpl Foundation Intel `linux`, `manifest`,
  and `feed_target_mips`
- adjacent GPL sources: AVM 5530/5590 Fiber `prxI` source archives

Those candidates are not corresponding source for the deployed
`kernel.bin`. They are the starting point for a patchable PRX126 kernel
branch.

## Evidence classes

| evidence | repo record | what it is good for | what it does not prove |
| --- | --- | --- | --- |
| Public community blobs | `pins/public-source-lock.json`, `docs/SOURCE-TRACE.md` | reproducible binary baseline; public RBE/CAS staging | source-level CVE patch status |
| Live module extraction | `audit/collect-running-bundle.sh` output | confirms what lab units actually boot; extracts DTB/modules/firmware for comparison | corresponding source |
| Public source candidates | `pins/source-stack-candidates.json`, `docs/PUBLIC-SOURCES.md` | PRX126 reconstruction, DTS/config diffing, GPL request scope | exact WAS-110 provenance |
| Self-built kernel bundle | `docs/KERNEL-BUNDLE.md`, `kernel-build.json` | audited kernel patching and release claims | bootloader/rootfs integrity by itself |

## MVP milestones

### 0. Pinned binary baseline

Build the current community baseline from pinned public artifacts:

```sh
nix build .#publicCommunityRelease
```

This gives audit-grade identity for the opaque kernel while kernel
bring-up proceeds separately.

### 1. Collect running bundle evidence

Run against each lab module before and after flash:

```sh
nix develop
./audit/collect-running-bundle.sh \
  --out-dir out/device-bundles \
  --manifest out/manifest.json \
  <was110-ip> root
```

The collector is read-only by default. It saves the active
`kernel*`/`bootcore*`/`rootfs*` UBI volumes, DTB/device-tree,
`/lib/modules`, `/lib/firmware`, package inventory, PON-related runtime
inventory, filtered U-Boot environment, and hashes. Full config, inactive
banks, and raw MTD dumps are opt-in.

Use this evidence to compare the lab unit against both the pinned public
baseline and the public PRX126 source candidates.

### 2. Prove the kernel-bundle handoff with the current kernel

Before changing code, package the known-good current kernel plus observed
module/firmware trees as a bundle and pass it through the builder. This
tests the integration seam without introducing a new kernel variable.

Release-grade bundles must include `kernel-build.json`; observed bundles
from live units are evidence only until backed by source/build metadata.

```sh
./audit/verify-kernel-bundle.sh path/to/kernel-bundle
./audit/pack-kernel-bundle.sh path/to/kernel-bundle out/kernel-bundle.tar
./build.sh -i path/to/bfw.img -I path/to/basic-dir --kernel-bundle path/to/kernel-bundle
```

The repo also carries a Nix proof that exercises this seam without
changing the kernel:

```sh
nix build .#knownGoodKernelBundle
nix build .#publicCommunityKernelBundleHandoffProof
```

`knownGoodKernelBundle` derives `kernel.bin`, `lib/modules`, and
`lib/firmware` from the pinned public community release. It is an
evidence-only bundle because it intentionally does not include
`kernel-build.json`. `publicCommunityKernelBundleHandoffProof` feeds that
bundle back through `build.sh --kernel-bundle` and checks that the manifest
records an external opaque kernel, not a source-built kernel.

### 3. Bring up a reconstructed PRX126 kernel on a sacrificial module

Candidate starting points:

- OpenWrt `v19.07.8` for toolchain/package baseline
- prpl Intel `manifest` `ugw-8.5.2`
- prpl Intel `linux` `intel-4.9.276` / `ugw-8.5.2`
- prpl Intel `feed_target_mips` `ugw-8.5.2`, especially
  `dts/prx126-sfp-pon.dts` and `PRX126_SFP_PON`
- AVM 5530/5590 Fiber `prxI` GPL drops for PRX300/Falcon-family diffing

Materialize the public Git candidates with:

```sh
./pins/verify-source-stack-candidates.sh
./pins/fetch-source-stack-candidates.sh \
  --out-dir vendor-blobs/source-stack-candidates \
  --only prpl-feed-target-mips-ugw-8.5.2 \
  --force
```

Use `--pack-archives` when the next handoff needs source tarballs instead
of local checkouts, and omit `--only` only when you intentionally want
every locked Git candidate. The AVM OSP tarballs are intentionally listed
but not downloaded by that script because each is roughly 600 MiB.

Early experiments can use `--kernel-file` or `--allow-module-mismatch`
only on sacrificial hardware. Release builds use `--kernel-bundle` with
matching modules and metadata.

### 4. Promote a self-built kernel to release status

A kernel is release-candidate material only when:

- `mkimage -l kernel.bin` accepts it,
- module directory names and module `vermagic` match the kernel release,
- PON services start and the unit registers on the lab OLT,
- rollback to the inactive bank is known to work,
- `audit/verify-device.sh` confirms the active kernel hash and banner
  match `out/manifest.json`, and
- `kernel-build.json` records source revision, config hash, toolchain,
  output hashes, and hardening profile.

Only at this point should audit material claim kernel CVE coverage beyond
the opaque vendor baseline.

## Bazel/RBE staging

The locked public community inputs can be mirrored or staged into Bazel
remote execution because they are public, content-pinned inputs:

- BFW archive / extracted `local-upgrade.img`
- basic archive / extracted `bootcore.bin`, `kernel.bin`, `rootfs.img`
- `8311-xgspon-bypass` commit

The clean model is:

1. mirror public archives into an internal artifact store by SHA-256,
2. generate or import a Bazel repository exposing those files as labels,
3. wire that repo into the consumer with the generated handoff files,
4. pass those labels to `was110_firmware`,
5. let RBE upload them to the private or approved CAS, and
6. sign the resulting manifest and provenance.

For private vendor drops or lab-extracted bundles, use the same label
shape but keep execution inside the lab trust boundary, or mark the target
local-only with `no-remote`, `no-remote-cache`, and `no-remote-exec`.

Mirror-backed materialization is supported directly:

```sh
./pins/fetch-public-inputs.sh \
  --archive-dir /mirror/was110/public-archives \
  --offline \
  --vendor-repo /secure/was110-public-community-repo \
  --update-pins \
  --force
```

See `docs/BAZEL-RBE.md` and `docs/VENDOR-BLOBS.md` for the concrete
repository rule and import commands.

## Audit language

Until a self-built kernel bundle is deployed and verified, the correct
claim is:

> The WAS-110 firmware release is built from pinned public/vendor binary
> inputs and verified on-device by kernel hash and banner. The currently
> deployed kernel is an opaque vendor/community blob; kernel CVE patch
> status is not inferred from upstream Linux alone.

After a self-built bundle is deployed and verified, the claim can become:

> The WAS-110 firmware release embeds a self-built PRX126 kernel bundle
> identified by `kernel-build.json`, signed release manifest, and
> post-flash device verification. Kernel CVE status is derived from that
> source revision, config, and patch set.
