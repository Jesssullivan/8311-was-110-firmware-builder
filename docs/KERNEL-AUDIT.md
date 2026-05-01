# Kernel audit & CVE coverage

## What ships today

| field | value | source |
| --- | --- | --- |
| Linux version | 4.9.308+ | banner string in vendor `kernel.bin` |
| Compiler | GCC 8.3.0 | banner string |
| SDK | OpenWrt 19.07.8 + MaxLinear vendor delta | banner string |
| Build target | `prx126-sfp-qspi-nand` | bootcore log |
| SoC | MaxLinear PRX126 (MIPS interAptiv 34Kc) | datasheet |
| Bootloader | U-Boot 2016.07-MXL-v-3.1.261 | u-boot version string |

Capture per-build via `audit/fingerprint.sh`; capture per-device via
`audit/verify-device.sh`.

## Source status

As of the 2026-05-01 source review, we do not have exact corresponding
source for the shipping WAS-110 `kernel.bin` or the full
`v19.07.8_maxlinear` OpenWrt/UGW SDK. The public source candidates are
tracked in `pins/source-stack-candidates.json` and summarized in
`docs/PUBLIC-SOURCES.md`.

The closest public source bases are useful for reconstruction work:
upstream OpenWrt `v19.07.8`, prpl Foundation Intel UGW `8.4.2` / `8.5.2`
manifests, prpl `intel/linux` 4.9 PRX300 trees, prpl `feed_target_mips`
with `PRX126_SFP_PON`, and AVM `prxI` GPL drops. They are not sufficient
to claim CVE-patched self-built kernel coverage for the deployed WAS-110
modules.

## CVE exposure baseline

**Linux 4.9 LTS reached upstream end-of-life with 4.9.337 on
2023-01-07.** Any CVE published after that date that affects 4.9 code
paths is, by default, treated as unpatched on the WAS-110 unless MaxLinear
or another distributor backported it in a later vendor build that we then
deploy.

### How we track

Until we control the kernel build:

1. **Frozen baseline.** The version string in the manifest is the single
   declared kernel state. We do not infer "patched" status - we record
   what's there and what's known about it.
2. **CVE list generation.** For audits, generate a candidate CVE list with:

   - `linuxkernelcves.com` - query for kernel `4.9.308`; flag everything
     introduced in the affected-version range that has no fix in 4.9.
   - Debian / Ubuntu / SUSE security trackers filtered to 4.9.x backports -
     useful as "what a competent distro would have patched by now".
   - NVD / MITRE keyword search across MIPS-relevant subsystems we actually
     ship (UBI, squashfs, dropbear's kernel touchpoints, the network stack).

   Start from `audit/cve-baseline-template.csv`, then persist the
   resulting list as `audit/cve-baseline-<release>.csv` alongside
   `manifest.json`. Validate it with:

   ```sh
   ./audit/verify-cve-baseline.sh audit/cve-baseline-<release>.csv out/manifest.json
   ./audit/verify-release-policy.sh --cve-baseline audit/cve-baseline-<release>.csv out
   ```
3. **Compensating controls** - what we *can* harden without rebuilding the
   kernel:

   - SSH: persisted dropbear keys + locked `authorized_keys` (already done;
     see common mods).
   - Userspace: drop unneeded packages via `copy_packages.sh`'s
     `REMOVE_PACKAGES` list.
   - Network exposure: management VLAN isolation; the WAS-110 is wired
     into a dedicated management subnet, not the data path it bridges.
   - Filesystem integrity: rootfs is read-only squashfs; persistent
     overlay scope is bounded.
4. **Insurance posture.** State the baseline plainly in audit responses:

   > Lab edge ONTs run Linux 4.9.308+ as shipped by the device vendor.
   > 4.9 is upstream-EOL. CVE remediation depends on vendor backports
   > we cannot verify. Compensating controls: management-VLAN isolation,
   > read-only rootfs, monitored via `8311/metrics`. Kernel source
   > requests are open with the vendor (see `docs/gpl-requests/`); a
   > self-built kernel with current-LTS hardening is on the roadmap.

That posture is honest, defensible, and directly answers the auditor's
real question.

## Target state (post-GPL)

First rebuild the vendor 4.9 tree exactly enough to boot, then harden in
small steps. A current supported LTS kernel is the long-term goal, but the
first usable milestone is a self-built vendor-compatible 4.9 kernel with
known source provenance.

Realistic vendor-4.9 hardening candidates:

- `CONFIG_CC_STACKPROTECTOR_STRONG=y`
- `CONFIG_SECURITY_DMESG_RESTRICT=y`
- `CONFIG_DEFAULT_MMAP_MIN_ADDR=65536` or stronger after testing
- `CONFIG_DEVKMEM=n`, `CONFIG_DEVMEM=n` (or strict)
- `CONFIG_LEGACY_PTYS=n`
- `CONFIG_PROC_KCORE=n`
- disable debugfs in production images when the PON/userland stack permits
- module signing, or built-in modules only, if the vendor module stack can
  tolerate it

Treat these as port-validation items, not assumed wins:

- `CONFIG_HARDENED_USERCOPY`
- strict kernel/module RWX
- VMAP stack
- seccomp filter
- lockdown / integrity LSMs

Do not assume MIPS interAptiv 34Kc supports KASLR-style
`CONFIG_RANDOMIZE_BASE`; verify during porting.

## Boot and rootfs integrity

U-Boot FIT signatures and dm-verity are later-stage work.

- FIT signatures only enforce anything if the installed U-Boot has
  signature verification enabled and a non-mutable public key.
- dm-verity is useful for a read-only squashfs rootfs once the kernel and
  boot command line are under our control. Without an authenticated root
  hash from the boot path, dm-verity detects corruption but does not create
  a full chain of trust.
- Today, the defensible control is signed release manifests plus
  post-flash UBI volume hash verification.

## References

- Public source map: `docs/PUBLIC-SOURCES.md`
- Linux 4.9.337 EOL note:
  <https://www.spinics.net/lists/kernel/msg4643112.html>
- U-Boot FIT signature verification:
  <https://docs.u-boot.org/en/stable/usage/fit/signature.html>
- Linux fs-verity documentation, including dm-verity positioning:
  <https://www.kernel.org/doc/html/latest/filesystems/fsverity.html>
