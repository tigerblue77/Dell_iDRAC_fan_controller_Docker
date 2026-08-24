<!--
SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
SPDX-License-Identifier: AGPL-3.0-only
-->

# Contributing

Contributions are what make the open source community such an amazing place to learn, inspire and create. Any contribution you make is **greatly appreciated**.

This page covers the licensing side of contributing. For the practical side — how to build the image, how to run the controller from a plain checkout, how to run and extend the test suite — see the [Contributing](./README.md#contributing) section of the README and [`tests/README.md`](./tests/README.md).

## Licensing of your contributions

This project is dual-licensed: [AGPL-3.0-only](./LICENSE) for everyone, plus a [separate commercial licence](./LICENSE-COMMERCIAL.md) for parties who cannot meet the AGPL's obligations. A dual licence only works if every line in the tree can be offered under both arms — a single contribution that arrives under the AGPL alone would make the commercial arm impossible to grant honestly from that point on.

So, **by submitting a contribution to this repository, you agree that**:

1. your contribution is licensed to the public under the **GNU Affero General Public License, version 3** (`AGPL-3.0-only`), the same terms as the rest of the project; and
2. you grant **Tigerblue77** ([@tigerblue77](https://github.com/tigerblue77)) a perpetual, worldwide, non-exclusive, royalty-free, irrevocable licence to reproduce, prepare derivative works of, publicly display, sublicense and distribute your contribution **under other terms as well, including proprietary commercial terms**; and
3. you have the right to grant both — the work is yours, or you are authorised to submit it (your employer's IP policy included).

What this is **not**:

- **It is not a copyright assignment.** You keep the copyright in what you wrote, in full. You may relicense, reuse or sell your own contribution elsewhere, exactly as you could before.
- **It is not exclusive.** Point 2 gives the maintainer a licence alongside yours, not instead of it.
- **It does not put your work behind a paywall.** Everything you contribute stays available to everyone under the AGPL, permanently. Point 2 only lets the maintainer *additionally* offer the same code to a party who is paying for terms the AGPL cannot give them.

If you are not comfortable with point 2, say so in your pull request rather than staying silent: a contribution the maintainer cannot dual-license is better identified at review time than after it is merged.

## Sign your work — Developer Certificate of Origin

Every commit must carry a `Signed-off-by` line. Adding one is your statement of the [Developer Certificate of Origin 1.1](https://developercertificate.org/):

> By making a contribution to this project, I certify that:
>
> &nbsp;&nbsp;&nbsp;&nbsp;(a) The contribution was created in whole or in part by me and I have the right to submit it under the open source license indicated in the file; or
>
> &nbsp;&nbsp;&nbsp;&nbsp;(b) The contribution is based upon previous work that, to the best of my knowledge, is covered under an appropriate open source license and I have the right under that license to submit that work with modifications, whether created in whole or in part by me, under the same open source license (unless I am permitted to submit under a different license), as indicated in the file; or
>
> &nbsp;&nbsp;&nbsp;&nbsp;(c) The contribution was provided directly to me by some other person who certified (a), (b) or (c) and I have not modified it.
>
> &nbsp;&nbsp;&nbsp;&nbsp;(d) I understand and agree that this project and the contribution are public and that a record of the contribution (including all personal information I submit with it, including my sign-off) is maintained indefinitely and may be redistributed consistent with this project or the open source license(s) involved.

Sign off with the `-s` flag, using a real name and a reachable address:

```bash
git commit -s -m "Your commit message"
```

which appends:

```
Signed-off-by: Random J Developer <random@developer.example.org>
```

Forgot it on the last commit ? `git commit --amend -s`. On several ? `git rebase --signoff <base>`.

### Contributions written by an agent

Some of the code here is written by a coding agent working on the maintainer's instruction. The DCO does not bend for that, and this project cannot afford it to : the sign-off is what records that a contribution could be offered under **both** licences, which is what keeps the commercial arm grantable.

An agent is a tool. A tool cannot certify anything, and a `Signed-off-by` naming one would be a trailer that satisfies a checker while naming nobody who could make the statement above. But it is also what actually wrote the code, and a commit has room to say both. So for those commits :

- **the author is the agent.** `git log`, `git blame`, `git shortlog` and GitHub's contributor graph all read that field, so it is the one place where recording who wrote the work counts. Naming the maintainer there would say they typed what a tool wrote ;
- **the `Signed-off-by` is the maintainer's**, because the certification is theirs to make. It cannot come from `git commit -s`, which derives the trailer from the author — the field that has to stay the agent's — so it is passed explicitly through the `git signoff` alias that `.claude/hooks/session-start.sh` sets at the start of every session, a rule that has to be remembered every time being a rule that gets forgotten ;
- **the certification is the maintainer's act of reviewing and merging.** The trailer states it ; the review is what makes it true. A pull request merged unread carries a sign-off that means nothing, and no workflow can tell the difference — [`.github/check_sign_off.sh`](./.github/check_sign_off.sh) reads the trailer's shape, never who stands behind it.

No `Co-Authored-By` accompanies them : the author field already names the agent, and a secondary attribution repeating it would only be another place to fall out of step.

If you are a contributor rather than the maintainer, none of this concerns you : sign your own work, with your own name.

## Licence headers

Every shell script carries a two-line [SPDX](https://spdx.dev/) header, right after the shebang:

```bash
#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only
```

Copy it into any new file you add — including test cases, mocks and helpers. It is what lets a downstream packager or an automated scanner tell what the file is under without reading the whole repository, and it is how AGPL-3.0 section 5(a) is satisfied file by file.

Do not add your own copyright line: the collective notice above already covers every contributor, and the commit history is the authoritative record of who wrote what. If you would rather be named explicitly, ask in your pull request and it will be added to [`NOTICE`](./NOTICE).

## Before opening a pull request

- Run the test suite: `./tests/run_tests.sh`. It needs no Dell hardware, no iDRAC and no network.
- Add a test case for what you changed. The suite covers every PowerEdge generation from the 9th to the 17th, and a behaviour with no test is a behaviour the next refactor is free to break.
- Keep [`shellcheck`](https://www.shellcheck.net/) quiet — CI runs it on every pull request.
- Say which server model and iDRAC generation you tested on, if you tested on real hardware. That context is worth more than it looks in a project that talks to twenty years of firmware.
