# Vendor blob intake

This repo should track hashes and provenance for vendor firmware blobs, not
the blobs themselves. The intake workflow turns reviewed local files into a
private Bazel repository that can be mounted locally or uploaded to a
private RBE CAS as declared action inputs.

## Import reviewed files

For the locked public community baseline, materialize inputs from
`pins/public-source-lock.json`:

```sh
./pins/fetch-public-inputs.sh \
  --vendor-repo vendor-blobs/public-community-repo \
  --update-pins \
  --force
```

This path is documented in `docs/SOURCE-TRACE.md`.

For Nix-first release builds on Linux, skip the local blob directory and
let Nix fetch the locked archives directly:

```sh
nix build .#publicCommunityRelease
```

That output is suitable for audit review, but it is still based on the
public community release chain rather than original vendor stock firmware.

For manually reviewed local vendor files:

```sh
./pins/import-vendor-blobs.sh \
  --update-pins \
  --vendor-version <vendor-version> \
  --source-url <reviewed-url-or-internal-ticket> \
  --visibility '@//firmware/was110:__pkg__' \
  path/to/stock-bfw.img \
  path/to/basic-image-dir \
  /secure/was110-vendor-blobs
```

`basic-image-dir` must contain:

- `bootcore.bin`
- `kernel.bin`
- `rootfs.img`

The script updates pins when requested, verifies strict hashes, and writes:

```text
/secure/was110-vendor-blobs/
|-- BUILD.bazel
|-- REPO.bazel
|-- WORKSPACE
|-- SHA256SUMS
|-- bfw.img
|-- pins.inputs.json
|-- vendor_blobs.meta.json
`-- basic/
    |-- bootcore.bin
    |-- kernel.bin
    `-- rootfs.img
```

Do not commit this directory. It is a private artifact store input.

Verify the private repo before injecting it into Bazel or mirroring it to
internal artifact storage:

```sh
./pins/verify-vendor-repo.sh /secure/was110-vendor-blobs
```

This checks `SHA256SUMS`, re-runs strict pin verification, and verifies the
metadata file.

For GloriousFlywheel consumers, pass the verified repo through
`GF_BAZEL_INJECT_REPOSITORIES=was110_vendor_blobs=/secure/was110-vendor-blobs`
so the cache-forward wrapper owns the Bazel injection. Continue to use
`BAZEL_DISTDIR` and `BAZEL_REPOSITORY_CACHE` for ordinary public archive
fetches.

## External kernel handoff

When a rebuildable kernel exists, package it first:

```sh
./audit/pack-kernel-bundle.sh \
  /path/to/kernel-bundle \
  /secure/kernel-bundle.tar
```

Then include it in the private repo:

```sh
./pins/import-vendor-blobs.sh \
  --kernel-bundle-tar /secure/kernel-bundle.tar \
  path/to/stock-bfw.img \
  path/to/basic-image-dir \
  /secure/was110-vendor-blobs
```

The tar must contain `kernel.bin` and `kernel-build.json`.

## Bazel labels

The generated repository exposes:

- `@was110_vendor_blobs//:bfw.img`
- `@was110_vendor_blobs//:basic_bootcore`
- `@was110_vendor_blobs//:basic_kernel`
- `@was110_vendor_blobs//:basic_rootfs`
- `@was110_vendor_blobs//:pins_inputs`
- `@was110_vendor_blobs//:kernel_bundle_tar` when a kernel bundle is present

Wire `pins_inputs` into `was110_firmware.pins_manifest` when the consuming
Bazel workspace should carry the reviewed pins snapshot privately rather
than relying on the source-tree `pins/inputs.json`.

When using `was110_vendor_blobs_repository`, `verify_pins = True` is the
default. If `pins_manifest` is set, Bazel verifies the BFW/basic blob hashes
and sizes during repository setup before the firmware build action can run.
