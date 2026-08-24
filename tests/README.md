# Test suite

Automated tests for the Dell iDRAC fan controller. Everything runs against a
mocked `ipmitool`, so the suite needs **no Dell hardware, no iDRAC and no
network** : `bash`, `coreutils`, `findutils`, `sed` and GNU `grep` and `awk` are
enough.

```bash
./tests/run_tests.sh                 # run everything
./tests/run_tests.sh --list          # list the test cases without running them
./tests/run_tests.sh -f temperature  # only run the cases whose name, or whose case file, matches
./tests/run_tests.sh --tap           # emit TAP version 13 output for a CI parser
./tests/run_tests.sh --junit FILE    # write a JUnit XML report
./tests/run_tests.sh --summary FILE  # append a Markdown report
./tests/run_tests.sh --no-color      # disable colored output
```

It exits `0` when every test case passed, `1` otherwise.

## What is covered

| File | What it checks |
| --- | --- |
| `cases/10_shell_scripts.sh` | Syntax of every script, the licence header each one and the `Dockerfile` carry, files shipped in the Docker image, drift between the code and what documents it — the lint list, `CLAUDE.md`'s layout table, paths, figures, dependency graph and worked example, and the packages its Environment section promises — healthcheck |
| `cases/11_claude_code_settings.sh` | The settings a Claude Code session starts from, which no server ever reads : that the file still parses, that the rules letting any session run a command without asking are the ones argued for — in the shape they were argued in, still runnable, only those, and all of them still there — and that the `SessionStart` hook is still wired to a script that exists, under a budget outlasting what that script allows itself. Skipped where `jq` is missing, the list being read out of JSON |
| `cases/12_github_workflows.sh` | The two publishing workflows no pull request ever runs : the release build and the base image refresh. Also that every workflow carries the licence header, which is the whole directory rather than those two |
| `cases/13_dockerhub_description.sh` | The page Docker Hub shows on the image's repository, built by a workflow no pull request fires either : that it stays a pointer at the documentation rather than a copy of it, and that no change to `README.md` can alter it |
| `cases/14_latest_tag_reconciliation.sh` | Which version `latest` ends up on after a release, against a stubbed registry. Skipped where `jq` is missing, the one thing the script needs that the suite does not |
| `cases/15_test_runner.sh` | The runner itself : the ways it used to stay green while nothing had been verified, and what `--filter` is allowed to match |
| `cases/16_release_note_publication.sh` | Whether a version tag still needs its GitHub release note written, against a stubbed GitHub : the decision that keeps a re-fired release from appending a second copy of its changelog to the one it already carries |
| `cases/17_reports.sh` | The JUnit XML and Markdown reports, whose consumer is a parser rather than a reader |
| `cases/18_sign_off.sh` | The gate that keeps an unsigned commit off `master`, on the pull request it arrives on : that a branch is refused for one missing trailer and every offender named in a single run, that the merge a contributor made to resolve their conflict is not asked to certify anything, and that a range it cannot read fails closed rather than green. Against a repository built for each case rather than a stubbed `git`, so skipped where `git` is missing |
| `cases/20_fan_speed_conversions.sh` | `FAN_SPEED` given as a percentage or as a hexadecimal byte |
| `cases/21_fan_speed_validation.sh` | `FAN_SPEED` values that would reach `ipmitool` as an unintended duty cycle, refused before the first command |
| `cases/22_cpu_temperature_threshold.sh` | `CPU_TEMPERATURE_THRESHOLD`, and reading "auto" off the CPUs with `lm-sensors` |
| `cases/23_cpu_temperature_source.sh` | `CPU_TEMPERATURE_SOURCE`, and reading the CPUs from `lm-sensors` when the iDRAC reports none |
| `cases/25_check_interval_validation.sh` | `CHECK_INTERVAL` values the monitoring loop can actually be paced by, and the reaction time bounds above them |
| `cases/26_boolean_parameter_validation.sh` | The boolean parameters, which are dispatched by running their value as a command |
| `cases/27_configuration_error_format.sh` | The one shape every startup refusal reports in, so the reason survives a `docker logs` scroll |
| `cases/28_comparison_operands.sh` | That no accepted configuration makes bash complain about a comparison operand |
| `cases/30_idrac_login_string.sh` | Local (`/dev/ipmi0`) and network (`lanplus`) modes, password handling |
| `cases/35_message_output.sh` | How error and warning messages reach the log, read at their junction with the line that follows |
| `cases/40_temperature_parsing.sh` | Reading the sensors out of `ipmitool sdr type temperature` |
| `cases/45_idrac_firmware_version.sh` | Reading the iDRAC's own firmware version out of `ipmitool mc info`, and never turning it into a verdict about fan control |
| `cases/46_redfish_cooling_response.sh` | The three halves of the Redfish cooling response : asking a server that lost the IPMI command whether it still exposes the setting and never inventing a capability out of an answer that never came, applying it per PCIe slot and handing Dell's default back on the way out over the same transport, and retrying only what describes a moment rather than a decision. Also what the parser makes of an answer that is ordered or spaced differently than the one it was written against |
| `cases/50_server_model_detection.sh` | Reading the manufacturer and model out of the FRU inventory, and refusing to run on an unreachable iDRAC |
| `cases/55_enclosure_housed_servers.sh` | Blades and modular servers, whose fans belong to their enclosure |
| `cases/60_cpu_topologies.sh` | 1, 2 and 4 socket servers, missing sensors, table layout |
| `cases/70_fan_control_profiles.sh` | The raw commands sent to the server, what their rejections mean, and the one refusal that must never stop the controller from trying again |
| `cases/80_temperature_thresholds.sh` | The overheating decision, including its fail-safe behavior |
| `cases/85_power_state.sh` | Skipping the cycle when the target server is powered off, and half the file over what happens when it cannot be reached at all : `MAXIMUM_IPMI_UNREACHABLE_DURATION` and `MAXIMUM_CONSECUTIVE_IPMI_FAILURES`, how each resolves into cycles, which of the two wins, and the container giving up |
| `cases/90_integration.sh` | The whole controller, started like its Docker image does |
| `cases/95_supervisor.sh` | The supervisor, and the fan handover it guarantees when the controller cannot do it itself |

Server generations are covered from the catalogue in
`lib/dell_server_catalogue.sh`, which lists more than a hundred PowerEdge models
from the 9th generation (2006) to the 17th (2024), each with its socket count,
whether its firmware still accepts Dell's IPMI raw fan control commands, and the
enclosure it is housed in (`1955`, `M1000e`, `VRTX`, `FX2`, `MX7000`, a `C-series`
chassis, or `standalone` for the rack and tower servers carrying their own fans).

## Reports

Beside the output it prints while it runs, the suite writes two reports for
whoever reads the run afterwards :

| Option | What it produces |
| --- | --- |
| `--junit FILE` | A JUnit XML report. The [`Tests`](../.github/workflows/tests.yml) workflow publishes it, which is what turns a pull request into a test result comment, a check run listing every test case, and a comparison against the base commit |
| `--summary FILE` | A Markdown report, **appended** to the file, written for `$GITHUB_STEP_SUMMARY` so that GitHub renders it on the job page : a table per suite, every test case that ran, and each failure with what it expected, what it obtained and the command to run it again on its own |

Both are built from the same recorded results, so they can never disagree, and
both are written whatever the outcome : a red run is the one whose report matters
most.

## Layout

```
tests/
├── run_tests.sh                    entry point : discovers, runs and reports
├── cases/                          the test cases themselves
├── lib/
│   ├── assertions.sh               assert_equals, assert_contains, fail, skip_test...
│   ├── dell_server_catalogue.sh    every Dell PowerEdge model the suite knows about
│   ├── fixtures.sh                 builders for the ipmitool outputs (FRU, SDR)
│   ├── harness.sh                  the environment a test case runs in, and its helpers
│   └── reports.sh                  the JUnit XML and Markdown reports
└── mocks/                          fake ipmitool, perl, sensors and sleep, first in the PATH
```

Each test case runs in its own subshell, starting from the environment
`setup_test_context` prepares : the mocks first in the `PATH`, and every variable
the controller expects from its Docker image set to the Dockerfile's default. A
test case only has to set what it is about.

## Adding a test case

Add a function named `test_<what it checks>` to the relevant file in `cases/` :
the runner picks it up on its own, in declaration order, and turns its name into
the line it reports. Nothing else to register. Its name has to be unique across
the whole suite, every case file being sourced into the same shell : the runner
refuses to run rather than let one definition silently replace another.

```bash
function test_a_single_socket_server_reports_one_cpu() {
  export MOCK_IPMITOOL_SDR_OUTPUT
  MOCK_IPMITOOL_SDR_OUTPUT=$(make_sdr_output --cpus 1 --cpu-temperatures "44")

  detect_CPU_temperature_sensors "$(retrieve_sdr_temperature_data)"
  retrieve_temperatures

  assert_equals "1" "${#DETECTED_CPU_ENTITY_IDS[@]}"
}
```

Assertions record their outcome and let the test case carry on, so a loop over a
hundred server models reports every offending model in one run. Use
`assert_... || return 1` when the rest of the test case cannot run once the
assertion failed.

Describing the server to simulate is done through `simulate_server`,
`simulate_enclosure_housed_server` (a blade or a modular sled),
`make_fru_output` and `make_sdr_output` (see `lib/fixtures.sh` for their options),
and what the server answers to a given command through the
`MOCK_IPMITOOL_*` variables (see `mocks/ipmitool`). `count_ipmitool_calls_matching`
reads back what was actually sent to it, and `run_controller` starts the whole
controller the way its Docker image does.
