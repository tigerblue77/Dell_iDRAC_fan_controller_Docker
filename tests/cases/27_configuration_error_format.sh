#!/bin/bash

# Every parameter the container refuses to start on reports the same way. The
# block form exists because refusing to start is only useful if the reason
# survives a "docker logs" scroll : the user has to see, without reading the
# source, which parameter is wrong, what it currently is, what is accepted and
# where to change it. That argument does not single out any one parameter, so
# these cases hold all of them to it rather than to their individual wording,
# which each parameter's own file already covers.

function assert_reported_as_a_configuration_error() {
  local -r PARAMETER_NAME="$1"
  local -r VALUE="$2"
  local -r EXIT_CODE="$3"
  local -r OUTPUT="$4"

  assert_equals 1 "$EXIT_CODE" "$PARAMETER_NAME=\"$VALUE\" should stop the container"
  assert_contains "$OUTPUT" "the container will not start" \
    "the error should say the container is refusing to start"
  assert_contains "$OUTPUT" "Parameter : $PARAMETER_NAME" \
    "the parameter at fault should be named on its own row"
  assert_contains "$OUTPUT" "Value     : \"$VALUE\"" \
    "the offending value should be quoted back on its own row"
  assert_contains "$OUTPUT" "Expected  : " \
    "the error should say what would have been accepted"
  assert_contains "$OUTPUT" "docker-compose.yml" \
    "the error should say where to fix it"
}

# The validators answer by stopping the controller, so the call has to happen in
# the subshell a command substitution creates
function assert_validator_reports_as_a_configuration_error() {
  local -r VALIDATOR="$1"
  local -r PARAMETER_NAME="$2"
  local -r VALUE="$3"

  local OUTPUT
  OUTPUT=$("$VALIDATOR" "$PARAMETER_NAME" "$VALUE" 2>&1)
  local -r EXIT_CODE=$?

  assert_reported_as_a_configuration_error "$PARAMETER_NAME" "$VALUE" "$EXIT_CODE" "$OUTPUT"
}

function test_an_unusable_fan_speed_reports_as_a_configuration_error() {
  assert_validator_reports_as_a_configuration_error validate_fan_speed_parameter "FAN_SPEED" "abc"
  assert_validator_reports_as_a_configuration_error validate_fan_speed_parameter "FAN_SPEED" "200"
}

function test_an_unusable_check_interval_reports_as_a_configuration_error() {
  # Its three refusals : the format, the zero and the maximum
  assert_validator_reports_as_a_configuration_error validate_check_interval_parameter "CHECK_INTERVAL" "abc"
  assert_validator_reports_as_a_configuration_error validate_check_interval_parameter "CHECK_INTERVAL" "0"
  assert_validator_reports_as_a_configuration_error validate_check_interval_parameter "CHECK_INTERVAL" "1h"
}

function test_an_unusable_boolean_reports_as_a_configuration_error() {
  local PARAMETER_NAME
  for PARAMETER_NAME in MONITORING_ONLY_MODE \
    DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE \
    KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT; do
    assert_validator_reports_as_a_configuration_error validate_boolean_parameter "$PARAMETER_NAME" "True"
  done
}

function test_an_unusable_temperature_threshold_reports_as_a_configuration_error() {
  # Resolved inline in the entrypoint rather than by a validator of its own,
  # "auto" having to be settled before anything reads the value as a number
  simulate_server "PowerEdge R730xd" --cpus 2 --cpu-temperatures "42 44"
  export CPU_TEMPERATURE_THRESHOLD="60C"

  local OUTPUT
  OUTPUT=$(run_controller "will not start")
  local -r EXIT_CODE=$?

  assert_reported_as_a_configuration_error "CPU_TEMPERATURE_THRESHOLD" "60C" "$EXIT_CODE" "$OUTPUT"
}

function test_a_temperature_threshold_outside_the_plausible_window_reports_as_a_configuration_error() {
  simulate_server "PowerEdge R730xd" --cpus 2 --cpu-temperatures "42 44"
  export CPU_TEMPERATURE_THRESHOLD="500"

  local OUTPUT
  OUTPUT=$(run_controller "will not start")
  local -r EXIT_CODE=$?

  assert_reported_as_a_configuration_error "CPU_TEMPERATURE_THRESHOLD" "500°C" "$EXIT_CODE" "$OUTPUT"
}

function test_a_failed_ipmi_connection_reports_as_a_configuration_error() {
  # Not a single parameter but the three that make up the connection, and the
  # other error a user hits before the container ever reaches its loop
  export MOCK_IPMITOOL_FRU_EXIT_CODE=1
  export MOCK_IPMITOOL_FRU_OUTPUT="Error: Unable to establish IPMI v2 / RMCP+ session"

  local -r OUTPUT=$(run_controller "will not start")

  assert_contains "$OUTPUT" "the container will not start" \
    "an unreachable iDRAC should report like any other configuration mistake"
  assert_contains "$OUTPUT" "Parameter : IDRAC_HOST / IDRAC_USERNAME / IDRAC_PASSWORD" \
    "the three parameters that make up the connection should be named"
  assert_contains "$OUTPUT" "docker-compose.yml" "the error should say where to fix it"
}

function test_no_configuration_refusal_is_left_reporting_as_a_single_line() {
  # The point of the block is that it is the only form a refused parameter takes.
  # A new validator added later, wired to print_error_and_exit out of habit, is
  # exactly what this case is here to catch
  local -r VALIDATORS=$(grep -c "print_error_and_exit \"\$PARAMETER_NAME" "$REPO_ROOT/functions.sh" || true)

  assert_equals "0" "$VALIDATORS" \
    "a parameter validator should refuse through print_configuration_error_and_exit, not through a single line"
}
