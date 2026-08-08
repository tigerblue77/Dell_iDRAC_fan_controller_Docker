# Test suite

Automated tests for the Dell iDRAC fan controller. Everything runs against a
mocked `ipmitool`, so the suite needs **no Dell hardware, no iDRAC and no
network** : `bash`, `coreutils`, GNU `grep` and `awk` are enough.

```bash
./tests/run_tests.sh                 # run everything
./tests/run_tests.sh --list          # list the test cases without running them
./tests/run_tests.sh -f temperature  # only run the test cases whose name matches
./tests/run_tests.sh --tap           # emit TAP version 13 output for a CI parser
./tests/run_tests.sh --junit FILE    # write a JUnit XML report
./tests/run_tests.sh --summary FILE  # append a Markdown report
./tests/run_tests.sh --no-color      # disable colored output
```

It exits `0` when every test case passed, `1` otherwise.

## What is covered

| File | What it checks |
| --- | --- |
| `cases/10_shell_scripts.sh` | Syntax of every script, files shipped in the Docker image, healthcheck |
| `cases/20_fan_speed_conversions.sh` | `FAN_SPEED` given as a percentage or as a hexadecimal byte |
| `cases/25_check_interval_validation.sh` | `CHECK_INTERVAL` values the monitoring loop can actually be paced by, and the reaction time bounds above them |
| `cases/26_boolean_parameter_validation.sh` | The boolean parameters, which are dispatched by running their value as a command |
| `cases/30_idrac_login_string.sh` | Local (`/dev/ipmi0`) and network (`lanplus`) modes, password handling |
| `cases/40_temperature_parsing.sh` | Reading the sensors out of `ipmitool sdr type temperature` |
| `cases/50_server_model_detection.sh` | Identifying the server, and detecting Gen 14 or newer |
| `cases/55_enclosure_housed_servers.sh` | Blades and modular servers, whose fans belong to their enclosure |
| `cases/60_cpu_topologies.sh` | 1, 2 and 4 socket servers, missing sensors, table layout |
| `cases/70_fan_control_profiles.sh` | The raw commands sent to the server, and their rejections |
| `cases/80_temperature_thresholds.sh` | The overheating decision, including its fail-safe behavior |
| `cases/85_power_state.sh` | Skipping the cycle when the target server is powered off |
| `cases/90_integration.sh` | The whole controller, started like its Docker image does |

Server generations are covered from the catalogue in
`lib/dell_server_catalogue.sh`, which lists more than a hundred PowerEdge models
from the 9th generation (2006) to the 17th (2024), each with its socket count,
whether its firmware still accepts Dell's IPMI raw fan control commands, and the
enclosure it is housed in (`M1000e`, `VRTX`, `FX2`, `MX7000`, a `C-series`
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
└── mocks/                          fake ipmitool, date and sleep, put first in the PATH
```

Each test case runs in its own subshell, starting from the environment
`setup_test_context` prepares : the mocks first in the `PATH`, and every variable
the controller expects from its Docker image set to the Dockerfile's default. A
test case only has to set what it is about.

## Adding a test case

Add a function named `test_<what it checks>` to the relevant file in `cases/` :
the runner picks it up on its own, in declaration order, and turns its name into
the line it reports. Nothing else to register.

```bash
function test_a_single_cpu_server_reports_one_cpu() {
  export MOCK_IPMITOOL_SDR_OUTPUT
  MOCK_IPMITOOL_SDR_OUTPUT=$(make_sdr_output --cpus 1 --cpu-temperatures "44")

  retrieve_temperatures true true

  assert_equals "1" "$NUMBER_OF_DETECTED_CPUS"
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
