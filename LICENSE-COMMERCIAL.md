<!--
SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
SPDX-License-Identifier: AGPL-3.0-only
-->

# Commercial licence

This project is dual-licensed. It is available:

- to everyone, under the [GNU Affero General Public License version 3](./LICENSE) (`AGPL-3.0-only`), at no cost and with no formality;
- or, to those who ask for it, under a **separate commercial licence** negotiated with the copyright holder.

**The two are alternatives, and the choice is the recipient's.** Nothing here restricts the AGPL grant: taking the program under the AGPL requires no permission, no registration and no notice to anybody, and this page cannot and does not add conditions to it. If the AGPL suits you — and for the overwhelming majority of users, including businesses running the container on their own servers, it does — you need nothing from this page.

## Do I need one ?

Almost certainly not. Read this table before assuming otherwise.

| What you are doing | AGPL is enough | Commercial licence |
|---|:---:|:---:|
| Running the container on your own servers, at home | ✅ | |
| Running it on your company's or your employer's servers, in production, at any scale | ✅ | |
| Modifying it for your own use and never distributing the result | ✅ | |
| Publishing your modifications, under the AGPL | ✅ | |
| Redistributing the image or the scripts as-is, licence and notices intact | ✅ | |
| Shipping it inside a product, an appliance or a firmware, and **not** releasing your modified source under the AGPL | | ✅ |
| Bundling it into a proprietary management suite whose source you cannot publish | | ✅ |
| Offering it as part of a hosted or managed service and declining the AGPL section 13 source obligation | | ✅ |
| Needing a warranty, an indemnity, or a support commitment — the AGPL disclaims all three (sections 15 and 16) | | ✅ |

The short version: **using** it never requires a commercial licence. Only **conveying** it while withholding the corresponding source does, and that is exactly what the AGPL asks in exchange for the grant.

Two consequences of the AGPL are worth spelling out, because they are what most commercial enquiries turn out to be about:

- **Copyleft reaches your modifications, not your infrastructure.** Running the container next to proprietary software of yours does not make that software a derived work. Mere aggregation is explicitly carved out (AGPL section 5, final paragraph).
- **Section 13 concerns users interacting with the program over a network.** This controller exposes no network interface to users — it talks to a BMC over IPMI, on the operator's own behalf. Section 13 therefore stays dormant in ordinary deployments; it matters if you build a service around the program that its users interact with remotely.

## What the commercial licence typically covers

Terms are agreed case by case, because a licence that fits an appliance vendor does not fit a managed-service provider. The usual shape is:

- a non-exclusive right to use, modify and redistribute the program in object or source form, **without** the AGPL's reciprocal source-disclosure obligations;
- the right to sublicense it as part of a larger product, under the licensee's own terms;
- the attribution and notice obligations reduced to what the licensee's product can practically carry;
- optionally: a warranty, an indemnity, a support or maintenance commitment, or a defined update channel — none of which the AGPL version carries.

It covers only the parts of the program whose copyright this project holds or is authorised to sublicense. It does not and cannot cover the third-party software aggregated in the published Docker image (the Ubuntu base image, `ipmitool`, `lm-sensors`); those keep their own licences in every case. See [`NOTICE`](./NOTICE).

## How to ask

**Through GitHub — that is the channel, and there is no separate mailing address.** Open an issue on this repository describing your use case, or reach the maintainer, [@tigerblue77](https://github.com/tigerblue77), on his profile there. An issue is the better of the two unless what you have to say is confidential : it is seen sooner, and it leaves a record both sides can point back to.

Please include:

1. what the product or service is, and how the controller would sit inside it;
2. whether you would redistribute it, host it, or both;
3. the scale involved, and the obligations you specifically need lifted;
4. any warranty, indemnity or support requirement.

There is no published price list, because there is no standard case. Small-volume, hobbyist and non-profit uses that genuinely cannot fit the AGPL are usually settled for nothing at all — ask.

## Notes

- **This page is not itself a licence.** It is a description of an offer to negotiate. A commercial licence exists only once it is signed; until then, the AGPL is the only licence in force, and it applies in full.
- **Contributors:** [`CONTRIBUTING.md`](./CONTRIBUTING.md) explains why contributing to this project means granting the maintainer the right to include your contribution under both arms of the licence, and what that does and does not mean for you.
- **History:** this project was licensed under CC BY-NC-SA 4.0 until the relicensing recorded in [`NOTICE`](./NOTICE). Copies obtained under those terms keep them; the relicensing withdraws nothing from anyone who already holds one.
