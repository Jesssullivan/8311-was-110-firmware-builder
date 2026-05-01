# Build & audit architecture

```
Layer 0: vendor blobs
  kernel.bin, bootcore.bin, u-boot
  pinned in pins/inputs.json (sha256)
  source: stock BFW upgrade image
  rebuild status: blocked on GPL drop
    |
    v
Layer 1: rootfs mods
  mods/*.sh, files/, packages/
  reproducible: SOURCE_DATE_EPOCH + mksquashfs -all-time/-mkfs-time
  pinned: sha256 pre/post for every binary patched in mods/binary-mods
    |
    v
Layer 2: image assembly
  create.sh / wholeImage.sh
  outputs: local-upgrade.img, multicast_upgrade.img, whole-image.img
  audit: audit/fingerprint.sh -> out/manifest.json (signed)
    |
    v
Layer 3: device-side verification
  audit/verify-device.sh over SSH
  confirms running unit matches manifest
```

## Today (MVP)

- The kernel is opaque. We cannot prove it has CVE-X-Y-Z patched. We *can*
  prove which exact opaque blob is running, and that it has not silently
  changed since flash. That's what the manifest + verify-device capture.
- The rootfs is fully under our control and reproducibility-aware.
- Releases are tagged in git; CI builds (planned) emit a signed manifest.

## Tomorrow (kernel-upgrade target)

The next milestone is not "find the exact old source tree or stop". The
milestone is a bootable, patchable PRX126 kernel artifact with enough
provenance to survive audit. Exact WAS-110 source from the GPL requests in
`gpl-requests/` remains the best starting point, but the build pipeline is
ready to consume any verified kernel bundle that boots the device and ships
matching modules/firmware.

The public source candidates in `pins/source-stack-candidates.json` are for
reconstruction and diffing; they are not yet a release-grade source base for
the deployed WAS-110 kernel.

```
Layer 0': self-built kernel bundle
  sources pinned (flake input)
  hardening config in repo
  cross-built reproducibly via Nix
  outputs:
    kernel.bin
    lib/modules/
    lib/firmware/ if needed
```

The seam is now explicit:

```sh
./build.sh \
  -i path/to/pinned-bfw.img \
  -I path/to/pinned-basic-dir \
  --kernel-bundle path/to/kernel-bundle \
  --work-dir /tmp/was110-work \
  --out-dir out
```

The bundle contract is:

```
kernel-bundle/
|-- kernel.bin              # U-Boot image accepted by mkimage -l
|-- lib/modules/...         # matching modules for this exact kernel
|-- lib/firmware/...        # optional matching firmware
`-- kernel-build.json       # optional upstream build provenance
```

Use `audit/verify-kernel-bundle.sh <dir>` to validate that contract. For
early lab bring-up only, `--kernel-file` plus `--allow-module-mismatch`
permits a boot experiment without replacing modules; it should not be
used for release builds.

See `docs/KERNEL-UPGRADE-PATH.md` for the milestone plan and
`docs/KERNEL-BUNDLE.md` for the exact bundle contract and recommended
`kernel-build.json` shape.

Each build writes `out/build-inputs.json`, and `audit/fingerprint.sh`
embeds that record into `out/manifest.json`. This is the contract that lets
`gloriousflywheel`/`linux-x`, Nix, or later Bazel targets provide the
kernel bundle without rewriting the existing image assembly flow.

The build still defaults to `out/` and repo-local `rootfs*` staging for
operator compatibility. CI should pass `--work-dir` so extracted vendor
rootfs trees do not dirty the checkout.

## Why Nix and not Bazel here

Bazel shines for code-generation graphs across many languages. This project
is a chain of shell scripts orchestrating squashfs-tools, mtd-utils, and
mkimage. Nix's strength - reproducible binary closures pinned by content
hash - maps directly onto our problem. Bazel could publish artifacts via
`rules_oci` downstream, but offers little value at the build step itself.

A Nix flake (see `flake.nix`) provides the dev shell today and is the
intended host for the future hermetic build. `nix/vendor-inputs.nix`
bridges `pins/inputs.json` into Nix evaluation and validates checked-in
U-Boot blob hashes without pretending private vendor firmware can be
fetched from the public internet.

Bazel stays useful at the upstream boundary: when `linux-x` can produce a
PRX126 `kernel.bin` bundle, this repo should consume that artifact through
`--kernel-bundle` and record its git/hash identity in the
manifest. The whole firmware-builder shell pipeline does not need to become
Bazel-native first.

For Bazel/RBE integration, see `docs/BAZEL-RBE.md` and the optional
`was110_firmware` rule in `bazel/was110_firmware.bzl`. The key rule is
that vendor blobs must be explicit action inputs; remote execution means
those blobs enter the remote CAS, so use private RBE or force local
execution. Reviewed blobs can be materialized into a private Bazel
repository with `pins/import-vendor-blobs.sh`; see `docs/VENDOR-BLOBS.md`.
