<!--
SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
SPDX-License-Identifier: AGPL-3.0-only
-->

# Working in this repository

Bash, no build step, no package manager. A container reads the CPU temperatures of a
Dell PowerEdge server over IPMI and drives its fans. It talks to twenty years of Dell
firmware, so most of the difficulty here is in what a given generation accepts, not in
the control logic.

## Layout

| File | What it holds |
| --- | --- |
| `supervisor.sh` | The image's entrypoint. Starts the controller and, if it dies without doing it itself, hands the fans back to Dell |
| `Dell_iDRAC_fan_controller.sh` | Configuration validation, then the monitoring loop |
| `functions.sh` | Every function (76, flat namespace, no modules) |
| `constants.sh` | The raw IPMI commands and the tables they are read against |
| `healthcheck.sh` | `HEALTHCHECK` for the image |
| `tests/` | The suite. See `tests/README.md`, which is thorough — read it before touching a test |

`Dell_iDRAC_fan_controller.sh`, `healthcheck.sh` and `supervisor.sh` each `source
functions.sh` and `constants.sh`. That is the entire dependency graph.

## Commands

```bash
./tests/run_tests.sh                 # the whole suite : no hardware, no iDRAC, no network
./tests/run_tests.sh -f temperature  # only the cases whose name matches
./tests/run_tests.sh --list          # list them without running

shellcheck -x Dell_iDRAC_fan_controller.sh functions.sh constants.sh \
              healthcheck.sh supervisor.sh .github/*.sh   # what CI lints

docker build -t dell_idrac_fan_controller:dev .
```

Run both before pushing. CI runs the suite twice — on the runner and inside the built
image — and shellcheck on every pull request.

## Conventions

- **Sign off every commit.** `git commit -s`. A commit without `Signed-off-by` is not
  mergeable ; see `CONTRIBUTING.md` for what it certifies in a dual-licensed project.
- **Every new shell script carries the two SPDX lines** right after the shebang, test
  cases, mocks and helpers included. Copy them from any existing script.
- **A new script under the repository root or `.github/` must be added by hand to
  `.github/workflows/shellcheck.yml`.** That workflow names its files one by one
  instead of globbing, and `tests/cases/10_shell_scripts.sh` guards the list —
  a script missing from it is analysed by nothing at all.
- **Add a test case for what you change.** A behaviour with no test is one the next
  refactor is free to break, and this codebase's refactors span a hundred server models.

## Invariants that are not obvious from the code

These are settled decisions with a cost behind them. Do not "clean them up".

- **One command substitution per statement.** Bash re-parses the text of every `$( )`
  at expansion time and runs pending trap handlers from inside that same reader loop.
  A `SIGTERM` landing there gets its handler parsed with the substitution still open,
  `graceful_exit` never runs, and the container dies leaving the fans on the user's
  static speed (issue #188). Measured : two substitutions in one expansion failed 61
  to 182 times in 250 runs, one alone failed 2. Compute into a variable, then use the
  variable. `tests/cases/10_shell_scripts.sh` enforces this.
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
function test_a_single_cpu_server_reports_one_cpu() {
  export MOCK_IPMITOOL_SDR_OUTPUT
  MOCK_IPMITOOL_SDR_OUTPUT=$(make_sdr_output --cpus 1 --cpu-temperatures "44")

  retrieve_temperatures "$SDR_DATA"

  assert_equals "1" "$NUMBER_OF_DETECTED_CPUS"
}
```

Describe the server with `simulate_server` / `simulate_enclosure_housed_server`, build
`ipmitool` output with `make_fru_output` and `make_sdr_output` (options in
`tests/lib/fixtures.sh`), set what the server answers with the `MOCK_IPMITOOL_*`
variables (`tests/mocks/ipmitool`), read back what was sent with
`count_ipmitool_calls_matching`, and start the whole controller the way the image does
with `run_controller`.

Server models come from `tests/lib/dell_server_catalogue.sh` : a hundred-plus PowerEdge
models from the 9th generation (2006) to the 17th (2024), each with its socket count,
whether its firmware still accepts the raw fan control commands, and its enclosure.
Blades and modular sleds carry no fan of their own — the enclosure's CMC does — so the
controller cannot cool them, and the suite pins what it does instead.

## Environment

`.claude/hooks/session-start.sh` installs `shellcheck` in Claude Code on the web, where
it is otherwise missing while CI still gates on it. `ipmitool`, `lm-sensors` and `perl`
are not needed to run the suite — it mocks them.

`.claude/settings.json` also pre-approves three commands, so a session runs them without
stopping to ask : `./tests/run_tests.sh` **exactly**, then `shellcheck` and `bash -n`
with any arguments. The suite's rule carries no `:*` on purpose — a prefix rule
pre-approves every argument list, and `--junit FILE` / `--summary FILE` create
directories and truncate files wherever they are pointed ; `shellcheck` and `bash -n`
have no option that names a file to write. `git` and `docker build` were deliberately
left out (issue #382). That list is a standing grant to every session opened here, so
adding to it is a decision to argue, not a line to append :
`tests/cases/11_claude_code_settings.sh` holds it.
