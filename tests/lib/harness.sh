#!/bin/bash

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
  export CHECK_INTERVAL=5
  export DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE=false
  export KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT=false
  export MONITORING_ONLY_MODE=false

  # Values Dell_iDRAC_fan_controller.sh computes before entering its loop
  DECIMAL_FAN_SPEED=5
  HEXADECIMAL_FAN_SPEED="0x05"
  IDRAC_LOGIN_STRING="lanplus -H $IDRAC_HOST -U $IDRAC_USERNAME -E"

  # Mock defaults : a healthy, powered-on dual CPU Gen 13 server
  export MOCK_IPMITOOL_CALL_LOG="$TEST_TEMPORARY_DIRECTORY/ipmitool_calls.log"
  : > "$MOCK_IPMITOOL_CALL_LOG"
  export MOCK_IPMITOOL_FRU_OUTPUT
  MOCK_IPMITOOL_FRU_OUTPUT="$(make_fru_output)"
  export MOCK_IPMITOOL_SDR_OUTPUT
  MOCK_IPMITOOL_SDR_OUTPUT="$(make_sdr_output)"
  export MOCK_IPMITOOL_POWER_STATUS="Chassis Power is on"
  export MOCK_DATE_OUTPUT="01-01-2024 00:00:00"
  # Short enough to keep the suite fast, long enough for run_controller to stop
  # the controller while it is idle between two cycles rather than mid-cycle
  export MOCK_SLEEP_SECONDS="0.25"
}

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

# A COMPLETE line of the temperature table. The controller prints a line with
# several printf calls (one per column group), so matching on the readings alone
# would match a line still being written, and the controller would be signaled in
# the middle of a cycle instead of between two of them
readonly CONTROLLER_TEMPERATURE_LINE_PATTERN='°C .*fan control profile'

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
# Usage : CONTROLLER_OUTPUT=$(run_controller ["extended regex to wait for"])
function run_controller() {
  local -r AWAITED_PATTERN="${1:-$CONTROLLER_TEMPERATURE_LINE_PATTERN}"
  local -r OUTPUT_FILE="$TEST_TEMPORARY_DIRECTORY/controller_output"
  # 400 polls of 20ms : 8 seconds, only ever reached when the controller does not
  # print what the test is waiting for, which the assertions then report
  local -r MAXIMUM_POLLS=400

  : > "$OUTPUT_FILE"

  local EXIT_CODE=0
  (
    cd "$REPO_ROOT" || exit 1

    bash ./Dell_iDRAC_fan_controller.sh > "$OUTPUT_FILE" 2>&1 &
    CONTROLLER_PID=$!

    POLLS=0
    while [ "$POLLS" -lt "$MAXIMUM_POLLS" ]; do
      # The controller stopped on its own (it refused to run, or it crashed)
      kill -0 "$CONTROLLER_PID" 2> /dev/null || break
      grep -qE "$AWAITED_PATTERN" "$OUTPUT_FILE" && break
      # "command -p" looks the real sleep up in the system's default PATH, the
      # mocked one being first in this shell's own PATH
      command -p sleep 0.02
      POLLS=$((POLLS + 1))
    done

    kill -TERM "$CONTROLLER_PID" 2> /dev/null
    wait "$CONTROLLER_PID"
  ) || EXIT_CODE=$?

  cat "$OUTPUT_FILE"
  return "$EXIT_CODE"
}
