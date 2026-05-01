# WAS-110 kernel upgradability deliverables

Last reviewed: 2026-05-01.

Linear project:
<https://linear.app/tinyland/project/was-110-kernel-upgradability-and-audit-build-e5c3c9b147a4>

Linear project document:
<https://linear.app/tinyland/document/deliverables-and-repo-authority-548560175b5b>

## Goal

Make the WAS-110 firmware path auditable today and incrementally capable of
shipping a self-built, patchable PRX126 kernel bundle.

This does not require finding the exact source tree for the currently
deployed `4.9.308+` vendor kernel before any progress can be made. Exact
source remains a high-value input, but the operational milestone is a
kernel artifact that we can build, patch, attest, flash, and verify.

## Delivery Shape

| milestone | target | Linear | outcome |
| --- | --- | --- | --- |
| M0: Pinned Baseline and Source Map | 2026-05-10 | `TIN-880`, `TIN-885` | current public/community inputs and source candidates are pinned, reviewed, and honest about gaps |
| M1: Device Evidence and Audit Runbook | 2026-05-24 | `TIN-881` | lab modules have dated running-bundle evidence and post-flash verification workflow |
| M2: Bazel/RBE and Kernel Bundle Handoff | 2026-06-14 | `TIN-882`, `TIN-883`, `TIN-884` | public blobs can be staged through approved RBE/CAS; release pack and kernel-bundle seam are proven |
| M3: PRX126 Kernel Bring-Up Spike | 2026-07-31 | `TIN-886`, `TIN-887` | a reconstructed/self-built PRX126 kernel candidate is built and tested on sacrificial hardware |
| M4: Audit Release Promotion | 2026-09-30 | `TIN-888` | audit language and CVE coverage claims are tied to signed manifests and device evidence |

## Current Status

As of 2026-05-01:

- `TIN-882` is in progress.
- PR #1 merged the audit build, kernel-bundle handoff, Nix, Bazel/RBE,
  source-trace, and runbook scaffolding to `master`:
  `fcc2098cdde659f69c2654fc9b9a1e61d7c3145f`.
- PR #2 merged the signed public community release workflow to `master`:
  `ed569d56cdd4362bd427cb04f41113d2754be00c`.
- PR #3 made the public community release workflow runnable on
  GitHub-hosted Ubuntu while retaining the lab-runner override:
  `0fb51b21b41a69e98c553df39e77a091a564dde2`.
- PR #4 pinned the official GitHub workflow actions by commit SHA:
  `e59802470464423b314e1310d3298bb0e2431473`.
- PR #6 added offline verification for collected running-device bundles:
  `38990fa06602144ca1379f337ad2ee1d2ca7add4`.
- The public community release workflow now defaults to GitHub-hosted
  Ubuntu, installs Nix with pinned `cachix/install-nix-action` commit
  `ab739621df7a23f52766f9ccc97f38da6b7af14f`, uses pinned
  `actions/checkout` and `actions/upload-artifact` commits, builds
  `.#publicCommunityRelease`, verifies release policy, keyless-signs the
  attestable files, uploads the signed pack, and can create a draft
  GitHub Release.
- `p7zip` is available in both the Nix dev shell and the operator's user
  Nix profile.
- The real public community archives are staged locally at
  `vendor-blobs/public-archive-mirror/` (ignored by git).
- Offline materialization from that mirror has recreated:
  - `vendor-blobs/public-community-inputs/`
  - `vendor-blobs/public-community-repo/`
- `pins/inputs.json` matches the public source lock; no repo diff was
  produced by the offline materialization.
- `pins/verify-vendor-repo.sh vendor-blobs/public-community-repo` passes.
- Bazel can resolve the generated repository through
  `--inject_repository=was110_vendor_blobs=$PWD/vendor-blobs/public-community-repo`,
  including `@was110_vendor_blobs//:bfw.img`,
  `@was110_vendor_blobs//:basic_bootcore`,
  `@was110_vendor_blobs//:basic_kernel`,
  `@was110_vendor_blobs//:basic_rootfs`, and
  `@was110_vendor_blobs//:pins_inputs`.
- `TIN-883` is done. It has a committed mainline Nix release-pack proof
  and a signed GitHub Actions release proof via
  `nix build .#publicCommunityRelease` from clean `master`.
  The pack includes `manifest.json`, `provenance.intoto.json`,
  `SHA256SUMS`, `inputs.json`, `public-source-lock.json`, firmware
  artifacts, and `audit-summary.md`.
- Final signed public community release proof:
  - workflow run:
    <https://github.com/Jesssullivan/8311-was-110-firmware-builder/actions/runs/25235727828>
  - draft GitHub Release:
    <https://github.com/Jesssullivan/8311-was-110-firmware-builder/releases/tag/untagged-a35993d18ef94a4801fc>
  - git revision:
    `e59802470464423b314e1310d3298bb0e2431473`
  - `kernel.rebuilt_from_source`:
    `false`
  - release tarball SHA-256:
    `70b2cc62660effbba36cf4b8445f93baae131ff0b572f75529b1074c408ee65f`
  - `manifest.json` SHA-256:
    `82ec8a2e9bcf26d274748b50448bd5d6f326d8a62c74a67b6f6912135187607f`
  - `provenance.intoto.json` SHA-256:
    `a18cf947ffe35b5abbf6c0e09c5811cea36c9252754b7c018d0ca081fa33d143`
  - `kernel.bin` SHA-256:
    `d66b24cf873cc1071a3aa2d155bf677f503f10d221513e469083f8a591f6b96c`
  - `local-upgrade.img` SHA-256:
    `5994678126ef89583a31e05240ebaa0e84f89d518ee6ee9403ce253ebdb476f7`
  - `multicast_upgrade.img` SHA-256:
    `7b65b2f98fb92c2ff675333be5676ceac7ecc4574e2362e40c8d704afc320a41`
  - verification:
    `audit/verify-release-pack.sh`, `audit/verify-release-policy.sh`, and
    `cosign verify-blob` for `manifest.json`, `SHA256SUMS`, and
    `provenance.intoto.json` all passed after downloading the artifact.
- `TIN-881` is in progress. The repo now has an offline audit gate for
  running-device bundles collected from live lab modules:
  - verifier:
    `audit/verify-running-bundle.sh`
  - operator command:
    `./audit/verify-running-bundle.sh --strict --reject-sensitive --expected-manifest out/manifest.json out/device-bundles/<unit>-<timestamp>.tar.gz`
  - policy:
    normal audit storage rejects `sensitive/` and `mtd/` content unless
    the evidence pack is explicitly routed to restricted storage.
  - remaining work:
    collect and verify bundles from both lab WAS-110 units.
- Earlier path-flake output captured during pre-merge validation:
  `/nix/store/f96qxrcb1qrkfxzhxa6kjyqjcfk95yl9-was110-public-community-release-community-bfw-v2.4.0+basic-v2.8.3`.
- That path-flake build recorded source identity as `path-q8gnr4b5jkhc`
  with `dirty=true`. Dirty path-flake store paths and image hashes are
  local proof evidence, not stable release identifiers; a committed git
  build should replace them with the real git revision before publishing.
- Representative local release-pack proof hashes from that validation run:
  - `local-upgrade.img`:
    `2e14a1690423cb6eafc743137a24d5cfec121bc7ae80bad5712719552b9e2e01`
  - `multicast_upgrade.img`:
    `4cc9eac2e4c3a181b7454720503d43f1b58de3aebd837dbd44e83e38c118da4b`
  - `kernel.bin`:
    `d66b24cf873cc1071a3aa2d155bf677f503f10d221513e469083f8a591f6b96c`
- `TIN-884` has a local kernel-bundle handoff proof via
  `nix build .#knownGoodKernelBundle` and
  `nix build .#publicCommunityKernelBundleHandoffProof`.
  Representative path-flake outputs captured during validation:
  - known-good bundle package:
    `/nix/store/8iis1a0dccjgryd3kpfa80ypyyavj0rl-was110-known-good-kernel-bundle-public-community`
  - external-bundle release proof:
    `/nix/store/q0gb79qbsmim0wv3xk2nvprij7xxmhl3-was110-public-community-release-community-bfw-v2.4.0+basic-v2.8.3-kernel-bundle-proof`
  - bundle tar SHA-256:
    `4949dec448fac8006c2ec4e84b6eaf76ee8dd13f024ba11317bbc9a14967b639`
  - kernel SHA-256:
    `d66b24cf873cc1071a3aa2d155bf677f503f10d221513e469083f8a591f6b96c`
  - proof manifest records `build_inputs.kernel.source` as
    `external:kernel-bundle`, `kernel.rebuilt_from_source` as `false`,
    and no `build_provenance`.
  - module tree hash before and after install:
    `062746e1c3efd512f9e79833c1f34b14a5a77e5ca1d385623b5bf539fc066ca4`
  - firmware tree hash before and after install:
    `be40d0059d03d4b9ee3f19ce0d107b6b2a9b3c90b8a703e665f3494608d439c4`
- `TIN-886` has a first public-source materialization for the PRX126 feed
  scaffold:
  - command:
    `./pins/fetch-source-stack-candidates.sh --out-dir vendor-blobs/source-stack-candidates --only prpl-feed-target-mips-ugw-8.5.2 --force`
  - manifest:
    `vendor-blobs/source-stack-candidates/source-stack.manifest.json`
  - source:
    `https://gitlab.com/prpl-foundation/intel/feed_target_mips.git`
  - ref:
    `refs/heads/ugw-8.5.2`
  - commit:
    `d5b97df3b6a049bd91abc6e4531170409d434c4e`
  - tree:
    `f5bf2ec56fec9a745483f0a7e61ab6525e6ab4ed`
  - key evidence files:
    `dts/prx126-sfp-pon.dts`, `image/prx300.mk`, `image/packages.mk`

## Linear Issues

| issue | title | repo authority |
| --- | --- | --- |
| [`TIN-880`](https://linear.app/tinyland/issue/TIN-880/finalize-was-110-pinned-public-baseline-and-source-map) | Finalize WAS-110 pinned public baseline and source map | `pins/public-source-lock.json`, `pins/source-stack-candidates.json`, `docs/SOURCE-TRACE.md`, `docs/PUBLIC-SOURCES.md` |
| [`TIN-881`](https://linear.app/tinyland/issue/TIN-881/collect-running-bundle-evidence-from-lab-was-110-modules) | Collect running bundle evidence from lab WAS-110 modules | `audit/collect-running-bundle.sh`, `docs/RUNBOOK.md` |
| [`TIN-882`](https://linear.app/tinyland/issue/TIN-882/stage-pinned-public-was-110-inputs-through-approved-bazelrbe-mirror) | Stage pinned public WAS-110 inputs through approved Bazel/RBE mirror | `pins/fetch-public-inputs.sh`, `pins/import-vendor-blobs.sh`, `docs/BAZEL-RBE.md`, `docs/VENDOR-BLOBS.md` |
| [`TIN-883`](https://linear.app/tinyland/issue/TIN-883/publish-signed-was-110-release-pack-from-pinned-inputs) | Publish signed WAS-110 release pack from pinned inputs | `.github/workflows/release-build.yml`, `.github/workflows/public-community-release.yml`, `audit/release-pack.sh`, `audit/verify-release-pack.sh`, `audit/provenance.sh` |
| [`TIN-884`](https://linear.app/tinyland/issue/TIN-884/prove-external-kernel-bundle-handoff-with-known-good-kernel) | Prove external kernel-bundle handoff with known-good kernel | `docs/KERNEL-BUNDLE.md`, `audit/verify-kernel-bundle.sh`, `audit/pack-kernel-bundle.sh`, `build.sh --kernel-bundle` |
| [`TIN-885`](https://linear.app/tinyland/issue/TIN-885/send-and-track-gplsource-requests-for-was-110-prx126-stack) | Send and track GPL/source requests for WAS-110 PRX126 stack | `docs/gpl-requests/` |
| [`TIN-886`](https://linear.app/tinyland/issue/TIN-886/build-prx126-reconstruction-branch-from-public-openwrtugw-candidates) | Build PRX126 reconstruction branch from public OpenWrt/UGW candidates | `pins/source-stack-candidates.json`, `docs/PUBLIC-SOURCES.md`, external `linux-x`/kernel infra |
| [`TIN-887`](https://linear.app/tinyland/issue/TIN-887/run-sacrificial-was-110-kernel-bring-up-and-rollback-proof) | Run sacrificial WAS-110 kernel bring-up and rollback proof | `docs/RUNBOOK.md`, `audit/verify-device.sh`, `audit/collect-running-bundle.sh` |
| [`TIN-888`](https://linear.app/tinyland/issue/TIN-888/define-was-110-kernel-cve-coverage-and-audit-promotion-gate) | Define WAS-110 kernel CVE coverage and audit promotion gate | `docs/KERNEL-AUDIT.md`, `audit/verify-release-policy.sh`, `audit/verify-cve-baseline.sh` |

## Critical Path

1. `TIN-880` finalizes the public baseline and source map.
2. `TIN-882` stages the pinned public inputs through the lab mirror/RBE
   path.
3. `TIN-883` produces a signed release pack from those pinned inputs.
4. `TIN-881` collects device-local evidence from the lab modules.
5. `TIN-884` proves the kernel-bundle seam with a known-good kernel.
6. `TIN-886` builds a reconstructed PRX126 kernel candidate.
7. `TIN-887` tests that candidate on sacrificial hardware.
8. `TIN-888` defines what can be claimed in audit material.

`TIN-885` runs in parallel. It may improve the kernel source base, but it
does not block the kernel-bundle architecture.

## Acceptance Gates

### Blob Baseline Release

The current opaque-kernel release path is acceptable when:

- public or private binary inputs are pinned by SHA-256 and size,
- build outputs include `manifest.json`, `provenance.intoto.json`,
  `inputs.json`, and `SHA256SUMS`,
- release pack verification passes,
- on-device verification confirms active kernel hash and banner, and
- audit language states that kernel CVE patch status is not inferred from
  upstream Linux alone.

### Self-Built Kernel Release

A release may claim self-built kernel coverage only when:

- `kernel.bin` is produced by a reviewed source/build pipeline,
- matching `lib/modules` and any required `lib/firmware` are in the
  kernel bundle,
- `kernel-build.json` records source revision, config hash, toolchain, and
  output hashes,
- `audit/verify-kernel-bundle.sh` passes without mismatch overrides,
- sacrificial-device bring-up and rollback evidence exists, and
- `audit/verify-device.sh` confirms the flashed module is running the
  signed manifest's kernel.

## RBE Policy

Public community inputs can be mirrored/staged through Bazel RBE because
they are public and content-pinned in `pins/public-source-lock.json`.

Private vendor drops, live-unit extractions, or lab-only kernel bundles can
use the same Bazel label shape, but they must stay inside an approved
private CAS/worker pool or be forced local-only with `no-remote`,
`no-remote-cache`, and `no-remote-exec`.
