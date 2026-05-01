# Public PRX126 / PRX300 source map

Last reviewed: 2026-05-01.

This is the public-source map for the WAS-110 kernel-upgrade track. It is
not a claim that we can rebuild the shipping WAS-110 kernel today; it is
the evidence trail for the nearest public source bases and GPL request
targets.

For the exact public community firmware artifacts used to materialize the
current binary inputs, see `docs/SOURCE-TRACE.md` and
`pins/public-source-lock.json`. That lock also records the exact
`8311-xgspon-bypass` commit injected into the rootfs by the Nix release
build.

For machine-readable source candidates for kernel and OpenWrt stack work,
see `pins/source-stack-candidates.json`.

That JSON includes a flat `materialization.git_sources` lock that is
directly consumable by repo tooling:

```sh
./pins/verify-source-stack-candidates.sh
./pins/fetch-source-stack-candidates.sh \
  --out-dir vendor-blobs/source-stack-candidates \
  --only prpl-feed-target-mips-ugw-8.5.2 \
  --force
```

The verifier checks that public Git refs still resolve to the pinned
commits. The fetcher creates local checkouts under
`vendor-blobs/source-stack-candidates/git/` and writes
`source-stack.manifest.json`. Add `--pack-archives` only when source
tarballs are needed for handoff/RBE; OpenWrt and UGW trees are large.
Omit `--only` when you intentionally want every locked Git candidate.

Before using a materialized workspace as input to `linux-x`, Nix, Bazel, or
manual diffing, verify the local checkouts against that manifest:

```sh
./pins/verify-source-stack-materialization.sh \
  --dir vendor-blobs/source-stack-candidates \
  --require prpl-feed-target-mips-ugw-8.5.2
```

That offline check confirms the checkout commit, tree hash, dirty state,
evidence paths, and any packed source archive hash/size.

The first local materialization captured for this repo is:

```text
vendor-blobs/source-stack-candidates/
|-- source-stack.manifest.json
`-- git/prpl-feed-target-mips-ugw-8.5.2/
    |-- dts/prx126-sfp-pon.dts
    |-- image/prx300.mk
    `-- image/packages.mk
```

It is pinned to `feed_target_mips` `ugw-8.5.2` commit
`d5b97df3b6a049bd91abc6e4531170409d434c4e`, tree
`f5bf2ec56fec9a745483f0a7e61ab6525e6ab4ed`.

## Current Verdict

We do not have exact corresponding source for the shipping WAS-110
`kernel.bin` or the full `v19.07.8_maxlinear` OpenWrt/UGW SDK.

We do have usable public scaffolding:

- upstream OpenWrt `v19.07.8`, commit
  `31f2f76cd5d7745e28fae3797d79b746360461f5`, matching the banner's
  OpenWrt release family but not the PRX126 target.
- prpl Foundation Intel UGW manifests for `ugw_8.4.2` and `ugw-8.5.2`.
- prpl Foundation `intel/linux` 4.9 PRX300/UGW kernel trees, including
  `intel-4.9.276`.
- prpl Foundation `feed_target_mips` `ugw-8.5.2`, which contains
  `dts/prx126-sfp-pon.dts` and the `PRX126_SFP_PON` image target.
- AVM OSP `prxI` source tarballs for PRX300/Falcon-family FRITZ!Box
  5530/5590 Fiber devices.

That is enough to start a source-reconstruction branch and to diff PRX126
board support. It is not enough to claim the lab is rebuilding the shipped
WAS-110 kernel from corresponding source.

This distinction is deliberate. Exact corresponding source is a provenance
win, but the MVP kernel-upgrade path is to produce a bootable PRX126 kernel
bundle with matching modules/firmware and auditable build metadata. See
`docs/KERNEL-UPGRADE-PATH.md`.

For live-unit binary evidence, use `audit/collect-running-bundle.sh`. It
captures the active kernel/rootfs/bootcore volumes, DTB/device-tree,
module tree, firmware tree, package inventory, and PON-related runtime
inventory. That output helps compare public source candidates against what
the module actually boots.

## Device facts

The WAS-110 is documented as a MaxLinear PRX126 module using a MIPS
interAptiv 34Kc CPU. Public boot logs show U-Boot
`2016.07-MXL-v-3.1.261`, build target `prx126-sfp-qspi-nand`, and Linux
`4.9.308+` built with `OpenWrt GCC 8.3.0 v19.07.8_maxlinear`.

MaxLinear describes PRX126 as a 10G PON SoC for SFP+ ONU applications and
lists secure boot as a chip capability, but public SDK/kernel source is
not linked from the product page.

## Closest public kernel trees

| source | why it matters | gap |
| --- | --- | --- |
| prpl Foundation `intel/linux` `intel-4.9.276` | Full public Linux tree for the PRX300/Falcon family; best baseline for diffing and eventual source rebuild work. | Older than WAS-110 `4.9.308+`; not exact device source. |
| prpl Foundation `intel/linux` `ugw_8.4.2` | UGW release patch stack with explicit PRX300 patches. | Patch stack / release tree, not a clean product SDK for WAS-110. |
| prpl Foundation `intel/feed_target_mips` `ugw-8.5.2` | Contains PRX126/PRX321 DTS and OpenWrt image target evidence, including `prx126-sfp-pon`. | Still not a complete ready-to-run public WAS-110 SDK. |
| AVM OSP 5530/5590 Fiber `prxI` tarballs | Public OEM GPL source drops for Falcon/PRX300-family fiber devices. | PRX321/AVM board focus; PON stack and WAS-110 board specifics differ. |
| BoxMatrix AVM source scans | Indexes AVM Falcon sources and kernel versions, useful for historical triangulation. | Third-party index; use AVM OSP tarballs as source of record. |

## Public OpenWrt / UGW stack sources

| stack | pinned evidence | role |
| --- | --- | --- |
| upstream OpenWrt `v19.07.8` | tag object `9ca5a5ae94e561c5dad796729f70e32f937ef5e3`, commit `31f2f76cd5d7745e28fae3797d79b746360461f5` | upstream OpenWrt baseline; useful for toolchain/package provenance |
| prpl Intel `manifest` `ugw_8.4.2` | `e421a128ddb68ec2f3b9f51a115db3f591646c82` | older public UGW manifest for Intel/MaxLinear MIPS stack |
| prpl Intel `manifest` `ugw-8.5.2` | `2388399a5973f56fb34635c1d7f4cc92d25f5e3f` | newer public UGW manifest; best public PRX126 stack scaffold |
| prpl Intel `feed_target_mips` `ugw-8.5.2` | `d5b97df3b6a049bd91abc6e4531170409d434c4e` | contains `prx126-sfp-pon.dts`, `PRX126_SFP_PON`, and PRX300 PON package lists |

Notably, the public prpl group lists many UGW feeds and sources, but I did
not find public `pon_drv` / full PON OMCI source corresponding to the
shipping WAS-110 image. `feed_target_mips` names the PON package set
(`gpon-omci-onu`, `kmod-pon-*`, `pon-lib`, firmware packages), which helps
define the missing-source request scope.

## Near hardware analogs

The Calix / HALNy HLX-SFPX 100-05610 is another PRX126 XGS-PON SFP+
module. Public boot logs show Linux `4.9.337` and MaxLinear OpenWrt
`22.03.0-rc2_maxlinear`. This is newer and interesting for diffing, but
I did not find public corresponding source.

## GPL request scope

Requests should go first to the parties distributing the binaries:

- BFW Solutions / Azores / WAS-110 firmware distributor: complete
  corresponding source for Linux `4.9.308+`, OpenWrt
  `19.07.8_maxlinear`, U-Boot `2016.07-MXL-v-3.1.261`, device DTS/config
  for `PRX126-SFP-PON`, kernel patches, package Makefiles, build scripts,
  toolchain instructions, and module source.
- Calix / HALNy / HLX-SFPX firmware distributor: corresponding source for
  Linux `4.9.337`, OpenWrt `22.03.0-rc2_maxlinear`, and U-Boot
  `2016.07-MXL-v-3.1.272`.
- MaxLinear: SDK/source corresponding to PRX126 PRX300/Falcon Linux
  `4.9.308+` and `4.9.337`; they are the SDK origin but may not be the
  direct distributor of the exact WAS-110 binary.

## Source links

- prpl Foundation Intel Linux:
  <https://gitlab.com/prpl-foundation/intel/linux>
- prpl `ugw_8.4.2` PRX300 patch example:
  <https://gitlab.com/prpl-foundation/intel/linux/-/raw/ugw_8.4.2/linux_patches/0677-DRVLIB-SW-2520-Fix-PRX300-GPIO-driver-compiler-warni.patch>
- AVM 5590 Fiber OSP index:
  <https://osp.avm.de/fritzbox/fritzbox-5590-fiber/>
- AVM 5530 Fiber OSP index:
  <https://osp.avm.de/fritzbox/fritzbox-5530-fiber/>
- WAS-110 public hardware / boot-log notes:
  <https://pon.wiki/xgs-pon/ont/bfw-solutions/was-110/>
- Calix / HLX-SFPX public hardware / boot-log notes:
  <https://pon.wiki/xgs-pon/ont/calix/100-05610/>
- MaxLinear PRX126 product page:
  <https://www.maxlinear.com/product/access/fiber-access/socs-for-optical-networking-units-onu/prx126>
