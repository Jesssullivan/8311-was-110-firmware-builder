# pins/

Cryptographic pin manifest for every vendor-supplied input that flows into a
release artifact.

## Why

The WAS-110 ships with a vendor-built kernel and bootloader for which we do
not currently have buildable source (see `docs/gpl-requests/`). Until that
changes, "audit-grade reproducibility" means: we can prove which exact
upstream blobs went into a given release, and a third party can reproduce the
same output bit-for-bit.

`inputs.json` is the source of truth. `verify.sh` checks the working tree
against it and is run as the first step of every build (see `docs/RUNBOOK.md`).

## Workflow

1. New vendor image arrives -> record `sha256`, `size_bytes`, `fetched_on`,
   and `source_url` under the appropriate key in `inputs.json`.
2. Open a PR with the change. Reviewer cross-checks the hash against an
   independent download.
3. Merge unlocks the next signed release.

Hashes set to `"TBD"` are surfaced as warnings by default. Release builds
must use:

```sh
./pins/verify.sh --strict path/to/bfw.img path/to/basic-image-dir
```

In strict mode, any `TBD` pin is a failure.

To materialize the locked public community baseline:

```sh
./pins/fetch-public-inputs.sh \
  --archive-dir /mirror/was110/public-archives \
  --offline \
  --vendor-repo vendor-blobs/public-community-repo \
  --update-pins \
  --force
```

This uses `pins/public-source-lock.json`, verifies archive hashes and
extracted file hashes, and then imports the files like any other private
blob set. See `docs/SOURCE-TRACE.md`.

Those public inputs can be mirrored into an internal artifact store and
used as Bazel/RBE action inputs because they are public and content-pinned.
Private vendor drops and live-unit extractions should use the same pinning
shape but stay inside an approved private CAS or local-only build.

For first bootstrap, omit `--archive-dir --offline` and let the script
download from the locked public release URLs. Once mirrored, keep
`--offline` in CI so mutable upstream release pages cannot affect builds.

`pins/source-stack-candidates.json` tracks the public kernel/OpenWrt/UGW
source candidates found during research. It is intentionally separate from
`public-source-lock.json`: candidates are useful for porting and GPL
request scope, but they are not exact corresponding source for the
shipping WAS-110 kernel blob.

Verify and materialize those public source candidates separately:

```sh
./pins/verify-source-stack-candidates.sh
./pins/fetch-source-stack-candidates.sh \
  --out-dir vendor-blobs/source-stack-candidates \
  --only prpl-feed-target-mips-ugw-8.5.2 \
  --force
```

The fetcher writes `source-stack.manifest.json` next to the checkouts. Add
`--pack-archives` when source tarballs are needed for handoff/RBE; omit
`--only` only for a full source-candidate materialization.

CI can verify that committed pins still match the public source lock
without downloading blobs:

```sh
./pins/verify-public-source-lock.sh
```

To reduce hand-edit mistakes, update hashes from reviewed local files with:

```sh
./pins/update-from-files.sh \
  --vendor-version <version> \
  --source-url <reviewed-url-or-path> \
  path/to/bfw-local-upgrade.img \
  path/to/basic-image-dir
```

Review the resulting JSON diff before merging. The helper records hashes
and sizes; it does not decide whether a vendor image is trustworthy.

For Bazel/RBE handoff, create a private vendor blob repository after review:

```sh
./pins/import-vendor-blobs.sh \
  --update-pins \
  --vendor-version <version> \
  --source-url <reviewed-url-or-ticket> \
  --visibility '@//firmware/was110:__pkg__' \
  path/to/bfw-local-upgrade.img \
  path/to/basic-image-dir \
  /secure/was110-vendor-blobs
```

The generated directory is intentionally ignored by git and exposes Bazel
labels for the blobs plus `@was110_vendor_blobs//:pins_inputs`. See
`docs/VENDOR-BLOBS.md`.

Before using that private repository:

```sh
./pins/verify-vendor-repo.sh /secure/was110-vendor-blobs
```

To validate an alternate manifest before replacing `pins/inputs.json`:

```sh
./pins/verify.sh --pins /tmp/inputs.json --strict path/to/bfw.img path/to/basic-image-dir
```
