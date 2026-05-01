# Kernel bundle contract

The firmware builder can consume a self-built kernel as a directory:

```text
kernel-bundle/
|-- kernel.bin
|-- lib/modules/<kernel-release>/...
|-- lib/firmware/...              # optional
`-- kernel-build.json             # required for release builds
```

This is the integration seam for kernel upgradability. See
`docs/KERNEL-UPGRADE-PATH.md` for the bring-up milestones and audit
language; this document defines the artifact contract.

Use:

```sh
./audit/verify-kernel-bundle.sh path/to/kernel-bundle
./build.sh -i path/to/bfw.img -I path/to/basic-dir --kernel-bundle path/to/kernel-bundle
```

`kernel.bin` must be a U-Boot image accepted by `mkimage -l`. The
`lib/modules` tree must match that exact kernel. If the bundle includes
`kernel-build.json`, `kernel.release` is checked against the extracted
banner when available, the module directory names, and module vermagic
strings when present. `lib/firmware` is copied when present.

If `kernel-build.json` is present, the builder copies it into `out/` and
embeds it in `out/build-inputs.json`, which is then included in
`out/manifest.json` and signed as part of the release pack.

Release builds (`build.sh -R`) using an external kernel require
`--kernel-bundle` and `kernel-build.json`. Granular `--kernel-file` inputs
are for sacrificial-unit bring-up only.

For Bazel/RBE, package the directory as a deterministic tar:

```sh
./audit/pack-kernel-bundle.sh path/to/kernel-bundle out/kernel-bundle.tar
```

The packer validates the bundle first, normalizes tar metadata, and checks
any non-`TBD` hashes already present in `kernel-build.json`. A stale
`kernel-build.json` is a build failure, not an advisory warning.

The Nix package `.#knownGoodKernelBundle` produces a deterministic
evidence-only tar from the pinned public community release. Use
`.#publicCommunityKernelBundleHandoffProof` to prove that the builder can
consume that tar's unpacked bundle via `--kernel-bundle` without claiming
source-built kernel coverage.

Recommended `kernel-build.json` shape:

```json
{
  "schema_version": 1,
  "kind": "8311-was-110-kernel-build",
  "builder": {
    "system": "nix",
    "derivation": "gloriousflywheel#was110-kernel",
    "build_id": "TBD"
  },
  "source": {
    "repo": "https://example.invalid/linux-x.git",
    "rev": "TBD",
    "tree_sha256": "TBD"
  },
  "target": {
    "soc": "MaxLinear PRX126",
    "board": "prx126-sfp-qspi-nand",
    "arch": "mips"
  },
  "kernel": {
    "release": "4.9.x-was110"
  },
  "toolchain": {
    "name": "OpenWrt mips_interaptiv",
    "version": "TBD"
  },
  "config": {
    "sha256": "TBD",
    "hardening_profile": "docs/KERNEL-AUDIT.md"
  },
  "outputs": {
    "kernel_bin_sha256": "TBD",
    "modules_tree_sha256": "TBD",
    "firmware_tree_sha256": "TBD"
  }
}
```
