# GPL source request - MaxLinear (PRX126 / UGW kernel)

**Status:** template - not yet sent.
**Owner:** TBD
**Sent on:** TBD
**Response:** TBD

---

## Recipient

MaxLinear, Inc. - Open-Source Compliance / Legal. Best-effort contacts:

- `opensource@maxlinear.com` (canonical-style address; verify before sending)
- Postal: MaxLinear, 5966 La Place Court, Suite 100, Carlsbad, CA 92008, USA

## Notes on legal posture

MaxLinear is the SoC vendor and original author of the v19.07.8 OpenWrt
fork ("UGW"). Their GPLv2 obligations primarily run to their direct
licensees (OEMs / ODMs), not to end users of devices built on their
SDK. This request is therefore weaker than the request directly to BFW
Solutions, but useful as:

1. A documented attempt to obtain the upstream from the closest source.
2. A nudge toward publication of fragments already at
   `gitlab.com/prpl-foundation/intel/linux` being refreshed past 2020.

## Subject

Request for public availability of MaxLinear PRX126 Linux kernel sources

## Body

> Dear MaxLinear Open-Source team,
>
> The PRX126 GPON ONU SoC powers a small but active community of
> independent operators (lab researchers, fibre ISPs, security
> auditors) running the WAS-110 SFP+ stick.
>
> Devices in this community ship a Linux kernel identified as 4.9.308+,
> built with GCC 8.3.0 against your vendor SDK
> "OpenWrt GCC 8.3.0 v19.07.8_maxlinear", target
> `prx126-sfp-qspi-nand`. Older fragments of this tree are publicly
> available at `gitlab.com/prpl-foundation/intel/linux` (last updated
> 2020), which has been valuable.
>
> Could you confirm:
>
> 1. Whether MaxLinear publishes the v19.07.8 sources (kernel +
>    matching U-Boot 2016.07-MXL-v-3.1.261 fork) anywhere public, or
>    intends to.
> 2. Whether MaxLinear publishes the newer PRX126 4.9.337 /
>    OpenWrt 22.03.0-rc2 source line seen on HLX-SFPX / Calix-adjacent
>    modules.
> 3. The contact path for end users / lab operators (not OEM partners)
>    seeking corresponding source for GPL-licensed components shipped
>    in PRX126-based devices, where the redistributor is unable to
>    provide it directly.
> 4. Whether the prpl Foundation `intel/linux` group remains the
>    intended public mirror, and if so, whether an update for the
>    PRX126 4.9.308+ / 4.9.337 lines is anticipated.
>
> Public availability of these sources would meaningfully improve the
> security posture of fielded PRX126 devices - current LTS Linux
> hardening cannot be applied to opaque vendor binaries.
>
> Thank you for your time,
> <NAME>
> <CONTACT>
