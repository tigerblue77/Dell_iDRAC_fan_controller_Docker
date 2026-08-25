#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# The environment every test case runs in, and the few helpers that talk to the
# code under test : the mocked ipmitool's call log, and running the controller
# itself from end to end.

# Prepare the environment a test case starts from : the mocks come first in the
# PATH, and every variable the controller expects from its Docker image gets the
# Dockerfile's default value, so a test only has to set what it is about
function setup_test_context() {
  PATH="$TESTS_DIRECTORY/mocks:$PATH"
  export PATH

  # Dockerfile defaults
  export IDRAC_HOST="192.168.1.100"
  export IDRAC_USERNAME="root"
  export IDRAC_PASSWORD="calvin"
  export FAN_SPEED=5
  export CPU_TEMPERATURE_THRESHOLD=auto
  export CPU_TEMPERATURE_SOURCE=auto
  export CHECK_INTERVAL=5
  export MAXIMUM_IPMI_UNREACHABLE_DURATION="60s"
  export MAXIMUM_CONSECUTIVE_IPMI_FAILURES=""
  export DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE=false
  export KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT=false
  export MONITORING_ONLY_MODE=false

  # Values Dell_iDRAC_fan_controller.sh computes before entering its loop
  DECIMAL_FAN_SPEED=5
  HEXADECIMAL_FAN_SPEED="0x05"
  IDRAC_LOGIN_STRING="lanplus -H $IDRAC_HOST -U $IDRAC_USERNAME -E"
  NETWORK_MODE=true
  CPU_TEMPERATURE_SOURCE_IN_USE="ipmi"
  # The repository itself : only provide_local_ipmi_device() moves it
  CONTROLLER_WORKING_DIRECTORY="$REPO_ROOT"
  # Set before the trap by the controller, so graceful_exit can read it whenever a signal lands
  IS_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_SUPPORTED=true
  # Same, for the fan control commands : a test starts against a server that has refused nothing and
  # accepted nothing, which is what the controller starts from too
  IS_FAN_CONTROL_SUPPORTED=true
  WERE_THE_FANS_HANDED_BACK_THIS_CYCLE=false
  HAS_FAN_CONTROL_EVER_BEEN_ACCEPTED=false
  # Same, for the one-off explanation of a rejected fan selector : a test starts against a server that
  # has not been told anything yet
  HAS_THE_BROADCAST_FAN_SELECTOR_REJECTION_BEEN_REPORTED=false
  # Same, for the fan identifiers a refused broadcast selector makes the controller discover : a test
  # starts against a server nothing has been probed on yet
  # Same, for the same-machine verdict and the two values it rests on : a test starts against a container
  # that has not yet worked out whether it runs on the server it is cooling, and with the DMI lookup
  # pointing where production points it rather than at whatever file the previous case wrote (issue #465)
  HOST_DMI_SERIAL_PATHS=("/sys/class/dmi/id/product_serial" "/sys/class/dmi/id/board_serial")
  IS_THE_CONTAINER_ON_THE_CONTROLLED_SERVER=""
  SAME_MACHINE_VERDICT_REASON=""
  FRU_SERVER_SECTION=""
  DISCOVERED_FAN_IDENTIFIERS=()
  WAS_THE_FAN_IDENTIFIER_WALK_ABANDONED=false
  HAS_THE_FAN_IDENTIFIER_WALK_FOUND_NOTHING=false
  # Settled once at startup by the controller, and read by build_header() and by every row it prints
  resolve_fan_control_profile_column_width

  # Mock defaults : a healthy, powered-on dual CPU Gen 13 server
  export MOCK_IPMITOOL_CALL_LOG="$TEST_TEMPORARY_DIRECTORY/ipmitool_calls.log"
  : > "$MOCK_IPMITOOL_CALL_LOG"
  export MOCK_IPMITOOL_FRU_OUTPUT
  MOCK_IPMITOOL_FRU_OUTPUT="$(make_fru_output)"
  export MOCK_IPMITOOL_SDR_OUTPUT
  MOCK_IPMITOOL_SDR_OUTPUT="$(make_sdr_output)"
  export MOCK_IPMITOOL_MC_INFO_OUTPUT
  MOCK_IPMITOOL_MC_INFO_OUTPUT="$(make_mc_info_output)"
  export MOCK_IPMITOOL_POWER_STATUS="Chassis Power is on"
  export MOCK_SENSORS_CALL_LOG="$TEST_TEMPORARY_DIRECTORY/sensors_calls.log"
  : > "$MOCK_SENSORS_CALL_LOG"
  # Short enough to keep the suite fast, long enough for run_controller to stop
  # the controller while it is idle between two cycles rather than mid-cycle
  export MOCK_SLEEP_SECONDS="0.25"

  # The healthcheck's heartbeat, in this run's own temporary directory rather than
  # at the /run path the image uses : the CI runner is not root, so a case left on
  # the real path would exercise the "could not write it" branch there and the
  # working one here, which is the difference a suite exists to remove.
  # Set for the test's own shell, which has functions.sh sourced ; the controller
  # is a process of its own and is pointed at it by the throwaway repository below
  TEST_HEARTBEAT_FILE="$TEST_TEMPORARY_DIRECTORY/heartbeat"
  HEARTBEAT_FILE="$TEST_HEARTBEAT_FILE"
  HAS_THE_HEARTBEAT_FAILURE_BEEN_REPORTED=false
  rm -f "$TEST_HEARTBEAT_FILE"

  build_throwaway_controller_repository
}

# Build the repository run_controller() starts the controller from : symbolic links
# to the real scripts, and in place of functions.sh two lines that source the real
# one and then apply the overrides given here.
#
# That seam is the directory the controller runs from, because it sources
# "functions.sh" by a relative path. It is deliberately out of reach of the
# environment -- precisely so that "docker run -e HEARTBEAT_FILE=..." cannot
# redirect it -- and this must not weaken that : the assignment in functions.sh
# clobbers whatever the environment carried, on every source.
#
# Nothing is written outside the run's temporary directory and no root is needed, so
# these cases run on the CI runner as well as in the Docker image.
# Usage : build_throwaway_controller_repository ["OVERRIDE=..." ...]
function build_throwaway_controller_repository() {
  local -r CONTROLLER_REPOSITORY="$TEST_TEMPORARY_DIRECTORY/controller_repository"

  rm -rf "$CONTROLLER_REPOSITORY"
  mkdir -p "$CONTROLLER_REPOSITORY"

  local REPOSITORY_FILE BASE_NAME
  for REPOSITORY_FILE in "$REPO_ROOT"/*.sh; do
    BASE_NAME=$(basename "$REPOSITORY_FILE")
    [ "$BASE_NAME" == "functions.sh" ] && continue
    ln -s "$REPOSITORY_FILE" "$CONTROLLER_REPOSITORY/"
  done

  {
    printf 'source "%s/functions.sh"\n' "$REPO_ROOT"
    printf 'HEARTBEAT_FILE="%s"\n' "$TEST_HEARTBEAT_FILE"
    local OVERRIDE
    for OVERRIDE in "$@"; do
      printf '%s\n' "$OVERRIDE"
    done
  } > "$CONTROLLER_REPOSITORY/functions.sh"

  CONTROLLER_WORKING_DIRECTORY="$CONTROLLER_REPOSITORY"
}

# The timestamp the controller stamps every printed line with. It is formatted by
# bash itself rather than read from `date`, so it cannot be frozen from the
# outside : a test asserts its shape rather than a particular instant
readonly CONTROLLER_TIMESTAMP_PATTERN='[0-9]{2}-[0-9]{2}-[0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2}'

# Every ipmitool invocation recorded so far by the mock
function recorded_ipmitool_calls() {
  cat "$MOCK_IPMITOOL_CALL_LOG"
}

# Number of recorded invocations matching an extended regular expression
# Usage : count_ipmitool_calls_matching "raw 0x30 0x30"
function count_ipmitool_calls_matching() {
  grep -cE -- "$1" "$MOCK_IPMITOOL_CALL_LOG" || true
}

# Forget the invocations recorded so far
function forget_recorded_ipmitool_calls() {
  : > "$MOCK_IPMITOOL_CALL_LOG"
}

# Run a function with its output (stdout and stderr merged) captured in
# $CAPTURED_OUTPUT, without the subshell a command substitution would create :
# the variables the function sets stay visible to the test
# Usage : capture_output apply_user_fan_control_profile
function capture_output() {
  local -r CAPTURE_FILE="$TEST_TEMPORARY_DIRECTORY/captured_output"

  local EXIT_CODE=0
  "$@" > "$CAPTURE_FILE" 2>&1 || EXIT_CODE=$?
  CAPTURED_OUTPUT=$(cat "$CAPTURE_FILE")

  return "$EXIT_CODE"
}

# Make run_controller() start the whole controller in "local" mode, on a machine
# that has no IPMI device of its own.
#
# The controller refuses to start without one, and the lookup it walks lives in
# the IPMI_DEVICE_PATHS array so that it can be pointed elsewhere (issue #190) --
# but a bash array cannot cross a process boundary, and run_controller() starts
# the controller as its own process. That seam is deliberately out of reach of the
# environment, precisely so that "docker run -e IPMI_DEVICE_PATHS=..." cannot
# redirect it, and this must not weaken that.
#
# The controller sources "functions.sh" by a relative path, so the directory it
# runs from is the seam that is left. A throwaway one is built here, holding
# symbolic links to the real scripts and, in place of functions.sh, two lines
# that source the real one and then point the lookup at a file of this run's own
# temporary directory. Nothing is written outside it, and no root is needed, so
# these cases run on the CI runner as well as in the Docker image rather than
# skipping on whichever machine has no /dev to write to.
#
# Usage : provide_local_ipmi_device; OUTPUT=$(run_controller)
function provide_local_ipmi_device() {
  local -r FAKE_IPMI_DEVICE="$TEST_TEMPORARY_DIRECTORY/controller_repository/ipmi0"

  build_throwaway_controller_repository "IPMI_DEVICE_PATHS=(\"$FAKE_IPMI_DEVICE\")"

  touch "$FAKE_IPMI_DEVICE"
}

# Decide what the machine running the controller reports as its own serial number, for a case that goes
# through run_controller() rather than calling the function directly.
#
# Same seam and same reason as provide_local_ipmi_device() above : HOST_DMI_SERIAL_PATHS is an array, so
# it cannot cross the process boundary through the environment, and it must not be made to -- it is the
# value that decides whether the host's CPUs may answer for a server reached over the network.
#
# Without this, such a case reads the REAL /sys/class/dmi/id/product_serial of whatever machine the suite
# is running on, and its verdict changes with that machine. That is not hypothetical : the suite is run
# twice on every pull request, once on the runner and once inside the Docker image, and only the second
# runs as root -- so the same case saw an unreadable DMI on one and a readable one on the other, and
# passed on the runner while failing in the image (issue #465).
#
# Usage : provide_a_host_serial_to_the_controller "5N7XXX2"   # or with no argument, an unreadable one
function provide_a_host_serial_to_the_controller() {
  local -r DMI_FILE="$TEST_TEMPORARY_DIRECTORY/controller_host_dmi_serial"

  rm -f "$DMI_FILE"
  if [ $# -gt 0 ]; then
    printf '%s\n' "$1" > "$DMI_FILE"
  fi

  build_throwaway_controller_repository "HOST_DMI_SERIAL_PATHS=(\"$DMI_FILE\")"
}

# A COMPLETE line of the temperature table. The controller prints a line with
# several printf calls (one per column group), so matching on the readings alone
# would match a line still being written, and the controller would be signaled in
# the middle of a cycle instead of between two of them
readonly CONTROLLER_TEMPERATURE_LINE_PATTERN='°C .*fan control profile'

# How long a signalled controller is given to run its own graceful_exit() before
# it is killed outright : 150 polls of 20ms, three seconds, which is the deadline
# supervisor.sh gives it in production and for the same reason.
#
# That deadline is genuinely reached. A SIGTERM landing while bash is expanding a
# command substitution is swallowed : the trap never runs and the process keeps
# looping (issues #188 and #249, and supervisor.sh exists for it). Measured on
# master, two controllers in two hundred do it.
#
# Waiting for such a process without a bound stops the whole run on it -- no
# timeout, no diagnostic, and no name of the case it stopped on, since the runner
# only reports a case once it returns. Killing it costs that one case its graceful
# exit and lets the suite finish, and the run says how often it had to (#427)
readonly CONTROLLER_STOP_GRACE_POLLS=150

# Run the whole controller with the mocks in place, until what the test is
# waiting for shows up in its output (by default one line of the temperature
# table), then stop it with SIGTERM, exactly like "docker stop" does, so that its
# graceful exit is exercised too. A controller that stops on its own is not
# signaled at all.
#
# Waiting for the output rather than for a fixed duration is what makes these
# test cases reproducible : the signal is always delivered at the same point of
# the cycle, right after a line was printed, while the controller is idle waiting
# for its next check interval.
#
# Its output (stdout and stderr merged, like "docker logs" shows it) is printed,
# and its exit code is returned
# A second argument asks for several matching lines rather than one, which is how
# a test observes what the controller does on its later cycles and not only on
# its first
# Usage : CONTROLLER_OUTPUT=$(run_controller ["extended regex to wait for" [how many lines]])
function run_controller() {
  local -r AWAITED_PATTERN="${1:-$CONTROLLER_TEMPERATURE_LINE_PATTERN}"
  local -r AWAITED_MATCHES="${2:-1}"
  local -r OUTPUT_FILE="$TEST_TEMPORARY_DIRECTORY/controller_output"
  # 400 polls of 20ms : 8 seconds, only ever reached when the controller does not
  # print what the test is waiting for, which the assertions then report
  local -r MAXIMUM_POLLS=400

  : > "$OUTPUT_FILE"

  local EXIT_CODE=0
  (
    # The repository itself, unless provide_local_ipmi_device() has pointed this at
    # the throwaway one it builds to make local mode runnable
    cd "${CONTROLLER_WORKING_DIRECTORY:-$REPO_ROOT}" || exit 1

    bash ./Dell_iDRAC_fan_controller.sh > "$OUTPUT_FILE" 2>&1 &
    CONTROLLER_PID=$!

    POLLS=0
    while [ "$POLLS" -lt "$MAXIMUM_POLLS" ]; do
      # The controller stopped on its own (it refused to run, or it crashed)
      kill -0 "$CONTROLLER_PID" 2> /dev/null || break
      MATCHING_LINES=$(grep -cE "$AWAITED_PATTERN" "$OUTPUT_FILE")
      [ "$MATCHING_LINES" -ge "$AWAITED_MATCHES" ] && break
      # "command -p" looks the real sleep up in the system's default PATH, the
      # mocked one being first in this shell's own PATH
      command -p sleep 0.02
      POLLS=$((POLLS + 1))
    done

    kill -TERM "$CONTROLLER_PID" 2> /dev/null

    STOP_POLLS=0
    while [ "$STOP_POLLS" -lt "$CONTROLLER_STOP_GRACE_POLLS" ]; do
      kill -0 "$CONTROLLER_PID" 2> /dev/null || break
      command -p sleep 0.02
      STOP_POLLS=$((STOP_POLLS + 1))
    done

    if kill -0 "$CONTROLLER_PID" 2> /dev/null; then
      # Recorded, not asserted on. A controller that swallowed its signal is not
      # this test case's doing, and failing a case at random on it would teach the
      # reader to distrust a red suite. The run reports the total instead, and the
      # exit code below still tells this case's own assertions what happened
      if [ -n "${TEST_WEDGED_CONTROLLERS_FILE:-}" ]; then
        printf '%s\n' "${TEST_CASE_NAME:-an unnamed test case}" >> "$TEST_WEDGED_CONTROLLERS_FILE"
      fi
      kill -KILL "$CONTROLLER_PID" 2> /dev/null
    fi

    # Reports the real status either way : 0 when graceful_exit() ran, 137 when it
    # had to be killed. Reporting a clean exit for a process that was killed would
    # be the silence this whole bound exists to remove
    wait "$CONTROLLER_PID"
  ) || EXIT_CODE=$?

  cat "$OUTPUT_FILE"
  return "$EXIT_CODE"
}
