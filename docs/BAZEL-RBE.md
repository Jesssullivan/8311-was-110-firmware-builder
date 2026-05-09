# Bazel/RBE vendor input model

Yes: the BFW image and basic firmware blobs can be supplied through Bazel
Remote Build Execution, but only as explicit Bazel inputs.

The model is:

1. A private Bazel repository exposes reviewed vendor blobs as labels.
2. `was110_firmware` declares those labels, and optionally a private pins
   manifest snapshot, as action inputs.
3. Bazel uploads those files to the remote CAS for the action.
4. The remote worker runs `build.sh` with `SUDO=` and writes a release
   directory TreeArtifact.
5. The release directory contains `manifest.json`, `provenance.intoto.json`,
   `inputs.json`, and `SHA256SUMS`, then CI signs those files.

## Public mirror / staging model

The public community seed inputs in `pins/public-source-lock.json` are
good candidates for RBE staging because they are already public and
content-pinned:

- the BFW release archive and extracted `local-upgrade.img`
- the basic release archive and extracted `bootcore.bin`, `kernel.bin`,
  and `rootfs.img`
- the `8311-xgspon-bypass` git commit used by the Nix release build

For those inputs, it is reasonable to mirror the archives into an internal
artifact store by SHA-256, generate a Bazel repository exposing the
reviewed extracted files as labels, and let remote execution upload them
to an approved CAS. The important invariant is that Bazel sees the exact
files as declared action inputs; URLs and mutable release pages are not the
release identity.

Materialize from an internal mirror with:

```sh
./pins/fetch-public-inputs.sh \
  --archive-dir /mirror/was110/public-archives \
  --offline \
  --vendor-repo /secure/was110-public-community-repo \
  --update-pins \
  --force
./pins/verify-vendor-repo.sh /secure/was110-public-community-repo
```

The archive directory must contain files named exactly as the lock records,
for example `WAS-110_8311_firmware_mod_2.4.0_bfw.7z` and
`WAS-110_8311_firmware_mod_v2.8.3_basic.7z`. The script still verifies
archive hashes, extracted blob hashes, and sizes against
`pins/public-source-lock.json`.

That public mirror path is different from private vendor drops or
lab-extracted bundles. Private blobs can use the same Bazel label shape,
but the CAS/worker pool must be inside the lab trust boundary or the target
must be marked local-only.

## Trust boundary

Remote execution does not avoid copying vendor blobs. It copies them into
the Bazel CAS so workers can execute hermetically. That is fine for a
private Buildbarn/BuildBuddy/EngFlow-style deployment inside the lab trust
boundary. It is not fine for an unreviewed shared/public remote cache.

If the CAS is not approved for vendor firmware, set the target local-only:

```python
was110_firmware(
    name = "lab_release",
    bfw_image = "@was110_vendor_blobs//:bfw.img",
    basic_bootcore = "@was110_vendor_blobs//:basic_bootcore",
    basic_kernel = "@was110_vendor_blobs//:basic_kernel",
    basic_rootfs = "@was110_vendor_blobs//:basic_rootfs",
    pins_manifest = "@was110_vendor_blobs//:pins_inputs",
    execution_requirements = {
        "no-remote": "1",
        "no-remote-cache": "1",
        "no-remote-exec": "1",
    },
    tags = ["manual", "requires-was110-vendor-blobs"],
)
```

`no-remote-exec` prevents remote execution. `no-remote-cache` prevents
uploading vendor-derived outputs to a remote cache. `no-remote` requests
both for Bazel versions that support the combined keyword. None of these
make an otherwise remote build magically private; if you allow remote
execution, inputs must enter CAS.

## Private vendor blob repository

The repo includes a helper repository rule for local reviewed blobs. With
Bzlmod:

```python
was110_vendor_blobs_repository = use_repo_rule(
    "@was110_firmware_builder//bazel:vendor_blobs.bzl",
    "was110_vendor_blobs_repository",
)

was110_vendor_blobs_repository(
    name = "was110_vendor_blobs",
    bfw_image = "/secure/was110-vendor/bfw.img",
    basic_bootcore = "/secure/was110-vendor/basic/bootcore.bin",
    basic_kernel = "/secure/was110-vendor/basic/kernel.bin",
    basic_rootfs = "/secure/was110-vendor/basic/rootfs.img",
    pins_manifest = "/secure/was110-vendor/pins.inputs.json",  # optional
    kernel_bundle_tar = "/secure/was110-artifacts/kernel-bundle.tar",  # optional
    target_visibility = ["@//firmware/was110:__pkg__"],
    verify_pins = True,  # default; fails analysis on hash/size drift
)
```

With `WORKSPACE`:

```python
load("@was110_firmware_builder//bazel:vendor_blobs.bzl", "was110_vendor_blobs_repository")

was110_vendor_blobs_repository(
    name = "was110_vendor_blobs",
    bfw_image = "/secure/was110-vendor/bfw.img",
    basic_bootcore = "/secure/was110-vendor/basic/bootcore.bin",
    basic_kernel = "/secure/was110-vendor/basic/kernel.bin",
    basic_rootfs = "/secure/was110-vendor/basic/rootfs.img",
    pins_manifest = "/secure/was110-vendor/pins.inputs.json",  # optional
    kernel_bundle_tar = "/secure/was110-artifacts/kernel-bundle.tar",  # optional
    target_visibility = ["@//firmware/was110:__pkg__"],
    verify_pins = True,  # default; fails analysis on hash/size drift
)
```

The rule symlinks those paths into an external repository and exposes:

- `@was110_vendor_blobs//:bfw.img`
- `@was110_vendor_blobs//:basic_bootcore`
- `@was110_vendor_blobs//:basic_kernel`
- `@was110_vendor_blobs//:basic_rootfs`
- `@was110_vendor_blobs//:pins_inputs` when `pins_manifest` is set
- `@was110_vendor_blobs//:kernel_bundle_tar` when `kernel_bundle_tar` is set

This makes the blobs explicit action inputs. For remote execution, Bazel
uploads them to CAS.

The helper rule defaults to root-package visibility in the consuming
workspace. In a monorepo, set `target_visibility` to the one package that owns
firmware release builds; do not expose vendor blobs workspace-wide unless
the whole workspace is inside the firmware trust boundary.

When `pins_manifest` is set, `verify_pins = True` verifies BFW/basic hashes
and sizes during repository setup. A drifted local file fails Bazel
analysis before the remote action is scheduled.

The same repository can be generated from reviewed files:

```sh
./pins/import-vendor-blobs.sh \
  --update-pins \
  --vendor-version <version> \
  --source-url <reviewed-url-or-internal-ticket> \
  --visibility '@//firmware/was110:__pkg__' \
  path/to/stock-bfw.img \
  path/to/basic-image-dir \
  /secure/was110-vendor-blobs
```

The generated repository includes handoff files so consumers do not need to
carry one-off inject flags:

- `was110_vendor_blobs.env` for GloriousFlywheel's cache-backed wrapper
- `was110_vendor_blobs.bazelrc` for direct Bazel consumers that import
  private repository wiring
- `was110_vendor_blobs.handoff.json` recording labels and CAS policy

Run `./pins/verify-vendor-repo.sh /secure/was110-vendor-blobs` before
mirroring or wiring the generated repo into a consuming workspace.

When the consumer is running through GloriousFlywheel's cache-forward Bazel
wrapper, keep the same reviewed repo shape and pass it through the wrapper
contract instead of adding one-off Bazel flags:

```sh
export BAZEL_DISTDIR=/mirror/was110/public-archives
export BAZEL_REPOSITORY_CACHE=/var/cache/bazel/repository
. /secure/was110-vendor-blobs/was110_vendor_blobs.env
scripts/bazel-cache-backed.sh build //firmware/was110:was110_lab_release
```

`BAZEL_DISTDIR` and `BAZEL_REPOSITORY_CACHE` are cache-forward inputs for
ordinary external fetches. The generated env file sets
`GF_BAZEL_INJECT_REPOSITORIES` as the authority handoff for this reviewed
blob repository. The blobs still become declared action inputs if remote
execution is enabled, so the CAS approval rule above still applies.

For a direct Bazel consumer, import the generated rc fragment from the
consuming workspace after reviewing the handoff manifest:

```text
try-import /secure/was110-vendor-blobs/was110_vendor_blobs.bazelrc
```

## Private vendor blob package

Create a private, non-git directory or internal artifact mirror with a
Bazel package if you prefer not to use the repository rule:

```text
/secure/was110-vendor/
|-- BUILD.bazel
|-- bfw.img
|-- pins.inputs.json
`-- basic/
    |-- bootcore.bin
    |-- kernel.bin
    `-- rootfs.img
```

Example `BUILD.bazel`:

```python
package(default_visibility = ["//visibility:private"])

exports_files(["bfw.img"], visibility = ["@//firmware/was110:__pkg__"])

filegroup(name = "basic_bootcore", srcs = ["basic/bootcore.bin"], visibility = ["@//firmware/was110:__pkg__"])
filegroup(name = "basic_kernel", srcs = ["basic/kernel.bin"], visibility = ["@//firmware/was110:__pkg__"])
filegroup(name = "basic_rootfs", srcs = ["basic/rootfs.img"], visibility = ["@//firmware/was110:__pkg__"])
filegroup(name = "pins_inputs", srcs = ["pins.inputs.json"], visibility = ["@//firmware/was110:__pkg__"])
```

Wire that directory into your lab monorepo however your Bazel setup
normally handles private repos, then call:

```python
load("@was110_firmware_builder//bazel:was110_firmware.bzl", "was110_firmware")

was110_firmware(
    name = "was110_lab_release",
    bfw_image = "@was110_vendor_blobs//:bfw.img",
    basic_bootcore = "@was110_vendor_blobs//:basic_bootcore",
    basic_kernel = "@was110_vendor_blobs//:basic_kernel",
    basic_rootfs = "@was110_vendor_blobs//:basic_rootfs",
    pins_manifest = "@was110_vendor_blobs//:pins_inputs",
    kernel_bundle_tar = "@was110_vendor_blobs//:kernel_bundle_tar",
    tags = ["requires-private-rbe"],
)
```

The output is a TreeArtifact:

```sh
bazel build //:was110_lab_release
ls bazel-bin/was110_lab_release.out
```

If your Bazel config uses `--remote_download_minimal`, request the release
tree explicitly when you need to inspect or sign it locally:

```sh
bazel build //:was110_lab_release --remote_download_outputs=all
```

For correct source identity in the manifest when the action runs outside a
Git checkout, enable the workspace-status command:

```sh
bazel build //:was110_lab_release \
  --workspace_status_command=./bazel/workspace_status.sh
```

## Local validation

This repository includes an analysis-only Bazel fixture that uses tiny fake
inputs and never runs the firmware build action:

```sh
bazel query //:was110_builder_srcs
bazel build --nobuild //tests/bazel:analysis_fixture
```

That verifies the Starlark rule shape and action graph without requiring
vendor blobs. It also produces or updates `MODULE.bazel.lock`; review that
lockfile like any other dependency lockfile before merging Bazel changes.

To smoke-test the private blob repository rule and its pin-drift failure
path:

```sh
nix shell nixpkgs#bazelisk -c ./tests/test-bazel-vendor-rule.sh
```

To prove the public-community handoff through an external executor without
building a full firmware release, materialize and verify the public vendor repo
first, then build:

```sh
bazel build \
  --inject_repository=was110_vendor_blobs=/absolute/was110-public-community-repo \
  //:public_vendor_handoff_fixture
```

That fixture hashes the declared public-community blob labels as action inputs.
It is intentionally tagged `manual` and requires an injected
`was110_vendor_blobs` repository, so ordinary CI does not silently fetch or
publish public inputs.

## Kernel bundle tar

For Bazel, the external kernel bundle is passed as a tar so directory
layout survives the action boundary:

```text
kernel-bundle.tar
|-- kernel.bin
|-- lib/modules/<kernel-release>/...
|-- lib/firmware/...              # optional
`-- kernel-build.json             # required for release builds
```

`kernel-build.json` should follow `docs/KERNEL-BUNDLE.md`. The builder
copies it into the release output and embeds it into manifest/provenance.

From a `linux-x` or Nix build, hand off the kernel with:

```sh
./audit/pack-kernel-bundle.sh \
  /path/to/kernel-bundle \
  /secure/was110-artifacts/kernel-bundle.tar
```

Then expose that tar as a private Bazel label and pass it as
`kernel_bundle_tar`. This is the clean integration point for Bazel remote
execution: the tar is a declared input, the action unpacks it inside the
remote sandbox, and the final manifest records the embedded
`kernel-build.json`.

## Remote worker requirements

The execution platform/container must provide:

- `bash`, `coreutils`, `findutils`, `gawk`, `grep`, `sed`, `perl` with `Digest::CRC`, `python3`
- `jq`, `tar`, `p7zip`
- `squashfs-tools`, `mtd-utils`, `u-boot-tools`
- `xz`, `gzip`, `lz4`, `file`
- `fakeroot` for unprivileged workers, so device nodes survive rootfs extraction/repack

The action runs `fakeroot -- env SUDO= ./build.sh ...` when `fakeroot` is
available; remote workers should not require privileged `sudo`.

This repo includes a starter container image at
`containers/was110-rbe/Dockerfile` and a Bazel platform target at
`//bazel/platforms:was110_rbe_linux`. The platform uses a placeholder
`container-image` property:

```python
exec_properties = {
    "container-image": "docker://ghcr.io/YOUR_ORG/was110-rbe:latest",
}
```

Replace that with your internal registry image, or override the platform in
the consuming workspace. The exact execution property key is RBE-provider
specific; some deployments use `container-image`, others configure images
outside Bazel platform metadata.
