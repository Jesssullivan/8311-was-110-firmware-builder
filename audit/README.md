# audit/

Tooling that turns a build into something you can attest to in a security
review.

| script | when | output |
| --- | --- | --- |
| `kernel-banner.sh kernel.bin` | any time | the `Linux version ...` string for the kernel image |
| `fingerprint.sh [out/]` | after a build | `out/manifest.json` - git rev, build inputs, every artifact's sha256, kernel banner |
| `provenance.sh [manifest] [out]` | after manifest generation | `out/provenance.intoto.json` - in-toto/SLSA-shaped provenance for the artifact set |
| `release-summary.sh [out/] [summary.md]` | audit prep | human-readable release summary derived from `manifest.json` |
| `release-pack.sh [out/]` | after a build | `manifest.json`, `provenance.intoto.json`, `audit-summary.md`, `inputs.json`, and `SHA256SUMS` in the output dir |
| `verify-release-pack.sh [out/]` | after release-pack/download | verifies manifest artifact hashes, `SHA256SUMS`, and provenance subjects |
| `verify-release-policy.sh [out/]` | release gate | enforces lab policy: pinned vendor inputs, known source rev, safe kernel provenance, required artifacts |
| `verify-cve-baseline.sh <csv> [manifest]` | release gate / audit prep | validates the per-release kernel CVE baseline schema and manifest identity |
| `verify-fwenv-profile.sh <profile> [dump]` | post-flash, CI fixture | validates expected `8311_*` fwenv state |
| `verify-device.sh [--fwenv-profile profile] <host> [user] [manifest]` | post-flash, on demand | a captured snapshot of the running unit's kernel, UBI volume hashes, and fwenv overrides |
| `collect-device-evidence.sh [options] <host> [user]` | post-flash | saves `verify-device.sh` output as `out/verify-<host>-<timestamp>.txt` |
| `collect-running-bundle.sh [options] <host> [user]` | source archaeology / audit evidence | saves active firmware volumes, DTB/device-tree, modules, firmware, package inventory, and runtime metadata from a live unit |
| `verify-running-bundle.sh [options] <bundle-dir\|bundle.tar.gz>` | after running-bundle collection | verifies bundle checksums, active A/B volume dumps, optional release-manifest match, and sensitive dump policy |
| `verify-kernel-bundle.sh <dir>` | before external kernel build | validates the `kernel.bin` + `lib/modules` artifact contract |
| `pack-kernel-bundle.sh <dir> <out.tar>` | before Bazel/RBE build | validates and packages a deterministic `kernel_bundle_tar` |

The manifest is the document we sign (`cosign sign-blob` in CI)
and attach to GitHub releases. The verify script is what an auditor runs
against a live unit to confirm "this device is on this release".

See `docs/RUNBOOK.md` for the end-to-end procedure and `docs/KERNEL-AUDIT.md`
for what the kernel-banner string actually tells us about CVE exposure.
