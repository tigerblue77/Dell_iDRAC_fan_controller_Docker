<!--
SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
SPDX-License-Identifier: AGPL-3.0-only
-->

# Working in this repository

Bash, no build step, no package manager. A container reads the CPU temperatures of a
Dell PowerEdge server and drives its fans over IPMI. It talks to twenty years of Dell
firmware, so most of the difficulty here is in what a given generation accepts, not in
the control logic.

The **CPU temperatures** come from two sources, though. The iDRAC over IPMI, and — when
it reports none — the Docker host's own chips through `lm-sensors`.
`CPU_TEMPERATURE_SOURCE` selects between them and defaults to `auto`.
`retrieve_temperature_data` in `functions.sh` is the single place the two meet, and
`healthcheck.sh` branches on the source before it contacts anything, so a change to CPU
reading that only considers IPMI has missed half the program. Everything else is IPMI
either way : the other sensors, and every fan control command.

## Layout

| File | What it holds |
| --- | --- |
| `supervisor.sh` | The image's entrypoint. Starts the controller and, if it dies without doing it itself, hands the fans back to Dell |
| `Dell_iDRAC_fan_controller.sh` | Configuration validation, then the monitoring loop |
| `functions.sh` | Every shared function (94, flat namespace, no modules). `supervisor.sh` keeps two of its own |
| `constants.sh` | The fixed values everything else is measured against : bounds, thresholds, intervals, column widths, Redfish URIs. The raw IPMI commands are in `functions.sh` |
| `healthcheck.sh` | `HEALTHCHECK` for the image |
| `tests/` | The suite. See `tests/README.md`, which is thorough — read it before touching a test |

`Dell_iDRAC_fan_controller.sh` and `supervisor.sh` each `source functions.sh` and
`constants.sh` ; `healthcheck.sh` sources `functions.sh` alone. That is the entire
dependency graph.

## Commands

```bash
./tests/run_tests.sh                 # the whole suite : no hardware, no iDRAC, no network
./tests/run_tests.sh -f temperature  # only the cases whose name, or whose case file, matches
./tests/run_tests.sh --list          # list them without running

shellcheck -x Dell_iDRAC_fan_controller.sh functions.sh constants.sh \
              healthcheck.sh supervisor.sh .github/*.sh \
              .claude/hooks/session-start.sh   # what CI lints

shellcheck -x -e SC2155,SC2034,SC2016,SC1091,SC1090 \
              tests/run_tests.sh tests/lib/*.sh \
              tests/cases/*.sh tests/mocks/*    # the suite, same as CI

docker build -t dell_idrac_fan_controller:dev .
```

Run all three before pushing. CI runs the suite twice — on the runner and inside the
built image — and both shellcheck invocations on every pull request. The five codes the
second one silences are the suite's own shape rather than defects, and they are argued
in `.github/workflows/shellcheck.yml` beside the step that carries them ; they never
reach `.shellcheckrc`, so the scripts above keep the full lint (issue #432).

**The last of the three needs a Docker daemon, and Claude Code on the web has none** —
the binary is on the PATH, so it looks runnable until it answers "cannot connect to the
Docker daemon". Say so rather than reporting a build that did not happen : piped into
`tail` or `head` it exits 0 whatever docker did, the status being the pipe's last command
(#463). Nothing is lost by leaving it out where it cannot run — `.github/workflows/tests.yml`
builds the image on every pull request, in the job that then runs the suite inside it — but
it costs a CI round trip, which is the cost the SessionStart hook installs `shellcheck` to
avoid. So the first two are what a session owes on any change ; the build is worth finding
a daemon for when the change touches the `Dockerfile` or a script the image ships.

## Conventions

- **Sign off every commit** with **`git signoff`**, never `git commit -s`. A commit without
  `Signed-off-by` is not mergeable ; see `CONTRIBUTING.md` for what it certifies in a
  dual-licensed project. Two identities are involved and they answer different questions :
  the commit is **authored** by the session, because that is who wrote it, and the trailer
  names the **maintainer**, because a tool certifies nothing. `-s` derives the trailer from
  the author and would collapse the two, so the alias carrying the right one is set by
  `.claude/hooks/session-start.sh` at the start of every session and nothing has to be
  remembered (#439). No `Co-Authored-By` is needed : the author field already says it.
- **Open every issue and pull request assigned to `tigerblue77`, and never as a draft.**
  Both are fields on the call that creates the thing, and the session that would come back
  to repair them afterwards has ended by then. Draft is the half with a price on it :
  `.github/workflows/auto_update_pull_request_branches.yml` skips drafts deliberately, so a
  pull request opened as one is the one pull request `master`'s moves never reach : it falls
  further behind at every merge, its checks go on describing a `master` that is gone, and it
  has to be converted by hand before it can be merged at all, at the moment somebody wanted
  to merge it — so the state buys nothing here. Unassigned is quieter and costs the
  same way : the maintainer's *Assigned* list is where the work is scheduled, and what is
  not on it has to be remembered instead. A contributor's own draft is untouched by this —
  the rule is what a session opens, not what that workflow does with a draft it finds.
  `.claude/hooks/session-start.sh` says both at the start of every session and
  `tests/cases/11_claude_code_settings.sh` holds them (#448). **This governs the
  maintainer's sessions, not everyone who clones the repository** : the two documents that
  carry the rule travel with the tree, so the hook checks that `origin` is this repository
  before it says any of it, and says nothing on a fork. A contributor's session is not
  addressed by this at all — its pull request is theirs to assign and theirs to open as a
  draft, which is what the branch updater's filter is there to protect (#457).
- **Issues and pull requests are written in English, and one that is not is flagged, in
  every repository of this maintainer** but the private ones whose own instructions put
  issues and pull requests in French — the private repositories of the
  `Dragnix-Tigerblue77` organisation among them — where code and commit messages still
  stay in English. Titles, bodies and comments alike. One found breaking it is never let
  pass silently : the maintainer is told, every time, with the link, and offered a
  translation, which is made once they agree. This is what a session does, not a demand
  on whoever reports or contributes : an outside contributor writes in the language they
  have, and the flag and the offer are the session's (#516 ; pull requests since #518).
- **Everything a session posts on GitHub is signed, with the link to the session that
  wrote it.** An issue, a pull request, a comment, a review and a reply on a review thread
  each end with a blank line, a `---` rule and this line, and an edit to one keeps it :

  ```
  _Generated by [Claude Code](https://claude.ai/code/session_<id>) and supervised by @tigerblue77._
  ```

  The link is the one to the session itself, the address the session's own attribution
  instructions give, so that the maintainer can go from any issue, pull request or comment
  straight to the conversation that produced it — the only place the reasoning that never
  reached the text still lives. The tooling appends a footer of its own to some posts, a
  pull request for one, and only the signature stays : once the post exists, its body is
  edited so that the signature is the last thing in it, since two lines saying the same
  thing are noise and only this one carries the maintainer's name. An issue opened without
  a signature is the case this rule exists for : nothing then links it to its conversation.
  The wording is the maintainer's, "supervised by" and not "reviewed by", and it is one
  fixed formula in every repository, whatever the language of the text above it — English
  here, French in the private repositories whose own instructions say so — because it is a
  signature and not prose. A commit message is not covered : it carries its sign-off, as
  *Sign off every commit* above says. Shared with every repository of the maintainer that
  carries agent instructions, and written out in full in each.
- **Another repository of this maintainer is cited only where this one calls it** : pulls
  its image, vendors its code, downloads its release or registers something for it. That
  goes for its name and for its issues and pull requests alike. It is never cited to say
  where a rule or a lesson came from, that a copy of a rule exists elsewhere, or how the
  other one does it : a citation like that is a dependency with nothing keeping it true,
  and it goes on pointing at whatever the other repository has since become. A rule
  shared across the maintainer's repositories is written out here in full and stands on
  its own, with no citation of where it came from. **A public repository never names a
  private one at all**, not even one it calls, never cites its issues or pull requests
  and never describes what it holds : not in a file, a commit message, a branch name, an
  issue, a pull request or a comment. This repository is public ; "the maintainer's
  private repositories" is as close as a reference gets, and the `Dragnix-Tigerblue77`
  organisation, being public, may be named. Third-party projects are not the maintainer's
  repositories, and this rule leaves them alone (#522, #524).
- **Every new shell script carries the two SPDX lines** right after the shebang, test
  cases, mocks and helpers included. Copy them from any existing script.
- **A new script under the repository root, `.github/` or `.claude/` must be added
  by hand to `.github/workflows/shellcheck.yml`.** That workflow names its files one
  by one instead of globbing, and `tests/cases/10_shell_scripts.sh` guards the list —
  a script missing from it is analysed by nothing at all.
- **A checkout does not keep the job token.** By default the checkout action keeps the
  job's token after it has finished, usable through git by every later step of the job.
  Every checkout in `.github/workflows/` therefore sets `persist-credentials: false`,
  so that the credential it set up is removed right after its fetch and no later step
  inherits it. That is all it does, `secrets.GITHUB_TOKEN` stays usable by a step that
  names it : a step that wants the token is given it by name, where a reader of the
  workflow sees it.
  That includes the `detect-reuse` job of `.github/workflows/tests.yml` and of
  `.github/workflows/shellcheck.yml`, whose decision step fetches a pull request's head
  ref without it. That works because the repository is public, and it costs nothing when
  it does not : a fetch that fails makes the suite run for real, the saving is lost and
  no verdict is. `tests/cases/12_github_workflows.sh` holds the rule, that failure and
  a list of the checkouts allowed to keep the credential, which is empty (#530).
- **Add a test case for what you change.** A behaviour with no test is one the next
  refactor is free to break, and this codebase's refactors span a hundred server models.
- **Dependabot's minor and patch updates merge themselves once CI is green, in every
  repository of this maintainer.** A Dependabot pull request sitting open with every check
  green is a defect in that process, not a task for a human. Here, as on wader/postfix-relay
  which is the reference, it is GitHub that waits :
  `.github/workflows/dependabot-auto-merge.yml` queues the merge with `gh pr merge --auto`
  and never merges directly, and the checks it waits for are
  `.github/rulesets/master.json`, which `tests/cases/12_github_workflows.sh` keeps naming
  jobs that exist. A private repository, where GitHub enforces no ruleset, does the waiting
  in its own workflow instead ; the rule is the same. What gets through is decided by the
  suite, not by a guess about which ecosystem is risky : majors wait for a human, and so
  does anything red.
- **Pull requests are kept level with the default branch, and never required to be, in
  every repository of this maintainer.** "Require branches to be up to date before
  merging" stays off : whatever cannot be updated automatically — a conflict, a fork, a
  draft, and every pull request after a Dependabot merge, which starts no workflow — would
  be blocked rather than behind. `.github/workflows/auto_update_pull_request_branches.yml`
  does the updating, as best effort, once the default branch has stayed quiet for an hour
  after a push : the run sleeps, and the next push cancels it and starts the wait over, so
  a series of merges is followed by one pass and not by one per merge, and there is no
  schedule (#527). A merge that starts no workflow starts no wait either, so what a
  Dependabot merge leaves behind is brought level after the next push made any other way.
  A pull request that conflicts is left to its author, with one comment saying so, which
  the pass that finds it conflict-free again deletes : it has to be written by the GitHub
  App and not by the personal access token, GitHub emailing nobody about their own
  activity. The updater leaves Dependabot's own pull requests to Dependabot : a rebase
  pushed by anyone else strips the signature the auto-merge checks before it acts (#514).
  A public repository runs it, its minutes costing nothing ; a private one carries the
  same file switched off behind the `PULL_REQUESTS_UPDATE_ENABLED` variable, until it
  moves to the organisation whose runners will run it (#512).
- **Nothing is assumed : an ambiguity is a question, not a judgement call.** Where two
  readings of an instruction would lead to materially different work, the question is put
  before the work starts, even though asking costs a round trip — because guessing costs
  the work. The judgement being asked for is narrow : routine calls a careful colleague
  makes alone stay made alone, and what gets asked is what changes the shape of what gets
  delivered. A default chosen silently is a decision nobody made, and it surfaces at
  review, which is the most expensive place for it to surface.
- **A reply is as short as the decision it carries.** A wall of prose is skipped whole, which
  costs more than saying too little : what got skipped included the question. So the verdict
  first, the numbers behind it, the question that needs an answer, and nothing else. The reasoning
  that earned a conclusion is not lost by leaving it out — it is in the commit message and the
  pull request body, where a reviewer can go and find it, and repeating it in the chat is the
  second copy that drifts. Tables and lists over paragraphs, and never a restatement of what was
  just asked.
- **A request to merge says what the pull request brings.** Merging is the maintainer's own
  act, so the ask carries what they need in order to decide, pull request by pull request :
  what it does, which goal it serves, what it changes, and — whenever it changes something
  that runs — how to test it, as the command to type or the thing to watch rather than "CI
  is green". What in it could not be verified, and why, stays in. Several at once come in the
  order they want merging in : the one their dependencies impose, and where nothing imposes
  one, the simplest first, so that each review starts from a smaller diff than the last.
  "This is ready" makes them work all of that out from the diff, which is the work the
  session was supposed to have already done, done twice. On a project
  that talks to twenty years of firmware, "what could not be verified" is rarely empty and
  is the half that matters : say which generation it was tested on, and which it was not.

## Invariants that are not obvious from the code

These are settled decisions with a cost behind them. Do not "clean them up".

- **One command substitution per statement.** Bash re-parses the text of every `$( )`
  at expansion time and runs pending trap handlers from inside that same reader loop.
  A `SIGTERM` landing there gets its handler parsed with the substitution still open,
  `graceful_exit` never runs, and the container dies leaving the fans on the user's
  static speed (issue #188). Measured : two substitutions in one expansion failed 61
  to 182 times in 250 runs, one alone failed 2. Compute into a variable, then use the
  variable. `tests/cases/10_shell_scripts.sh` enforces this.
- **The same boundary swallows `exit` and discards globals**, which is the half the rule
  above does not cover — and "compute into a variable" steers straight into it, because
  `VAR=$(f)` runs `f` in a subshell. Two consequences, each already paid for. An `exit`
  inside a function reached that way only leaves the subshell : four functions in
  `functions.sh` carry the same warning verbatim, and they are the validators meant to
  stop the container on a bad configuration — called as `X=$(validate_...)` the container
  starts anyway with the value it just refused. And a global assigned inside is lost,
  which is why `retrieve_temperature_data` returns its reading in the data rather than
  setting a variable. Nothing enforces this one : a unit test calling the function
  directly in the test's own shell sees a global that production would lose.
- **`IDRAC_LOGIN_STRING` is deliberately left unquoted** at every `ipmitool` call site.
  It is a single space-separated string of arguments that has to split back into
  separate argv entries ; quoting it passes `ipmitool` one argument instead of several
  and breaks every call in network mode. This is why `SC2086` and `SC2206` are disabled
  project-wide in `.shellcheckrc` — everywhere else, variables are quoted.
- **Test case names must be unique across the whole suite.** Every file in
  `tests/cases/` is sourced into one shell, so a duplicate name would silently replace
  a definition. The runner refuses to start rather than allow it.
- **Assertions do not stop a test case.** They record and carry on, so a loop over a
  hundred server models reports every offending one in a single run. Use
  `assert_... || return 1` when the rest of the case cannot run after a failure.
- **The controller must keep trying after a rejected fan control command.** Recent
  generations refuse Dell's IPMI raw commands outright ; the correct behaviour is to
  say so once and keep monitoring, never to exit.

## Writing a test case

Add a `test_<what it checks>` function to the relevant `tests/cases/*.sh` file. The
runner discovers it in declaration order and turns its name into the reported line —
nothing to register.

```bash
function test_a_single_socket_server_reports_one_cpu() {
  export MOCK_IPMITOOL_SDR_OUTPUT
  MOCK_IPMITOOL_SDR_OUTPUT=$(make_sdr_output --cpus 1 --cpu-temperatures "44")

  detect_CPU_temperature_sensors "$(retrieve_sdr_temperature_data)"
  retrieve_temperatures

  assert_equals "1" "${#DETECTED_CPU_ENTITY_IDS[@]}"
}
```

Describe the server with `simulate_server` / `simulate_enclosure_housed_server`, build
`ipmitool` output with `make_fru_output` and `make_sdr_output` (options in
`tests/lib/fixtures.sh`), set what the server answers with the `MOCK_IPMITOOL_*`
variables (`tests/mocks/ipmitool`) — or the `MOCK_SENSORS_*` ones (`tests/mocks/sensors`)
for the lm-sensors source — read back what was sent with
`count_ipmitool_calls_matching`, and start the whole controller the way the image does
with `run_controller`.

Server models come from `tests/lib/dell_server_catalogue.sh` : a hundred-plus PowerEdge
models from the 9th generation (2006) to the 17th (2024), each with its socket count,
whether its firmware still accepts the raw fan control commands, and its enclosure.
Blades and modular sleds carry no fan of their own — the enclosure's CMC does — so the
controller cannot cool them, and the suite pins what it does instead.

## Environment

`.claude/hooks/session-start.sh` installs `shellcheck` and `jq` in Claude Code on the
web, where neither is there by default : CI gates every pull request on the first, and
`tests/cases/11_claude_code_settings.sh` and `tests/cases/14_latest_tag_reconciliation.sh`
skip themselves without the second. `ipmitool`, `lm-sensors` and `perl` are not needed to
run the suite — it mocks them.

`.claude/settings.json` also pre-approves three commands, so a session runs them without
stopping to ask : `./tests/run_tests.sh` **exactly**, then `shellcheck` and `bash -n`
with any arguments. The suite's rule carries no `:*` on purpose — a prefix rule
pre-approves every argument list, and `--junit FILE` / `--summary FILE` create
directories and write wherever they are pointed — the first truncating the file it is
given, the second appending to it ; `shellcheck` and `bash -n` have no option that
names a file to write. `git` and `docker build` were deliberately
left out (issue #382). That list is a standing grant to every session opened here, so
adding to it is a decision to argue, not a line to append :
`tests/cases/11_claude_code_settings.sh` holds it.
