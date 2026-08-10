#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

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
  # A value is read identically on the next start, so the restart policy the
  # README's own examples recommend turns one refusal into an unbroken run of them
  # -- reported as a container flapping rather than as a mistake in a variable
  # (issue #326). No exit status ends that loop, "always" and "unless-stopped"
  # restarting on the policy rather than on the code, so the only thing that spares
  # the user the wait is the block saying so
  assert_contains "$OUTPUT" "Restarting will not help" \
    "the error should say that a restart would only meet the same refusal"
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

function test_an_unusable_temperature_source_reports_as_a_configuration_error() {
  local OUTPUT
  OUTPUT=$(resolve_CPU_temperature_source "sensors" "false" 2>&1)
  local -r EXIT_CODE=$?

  assert_reported_as_a_configuration_error "CPU_TEMPERATURE_SOURCE" "sensors" "$EXIT_CODE" "$OUTPUT"
}

function test_lm_sensors_requested_in_network_mode_reports_as_a_configuration_error() {
  # Valid spelling, unusable in this mode : still the user's parameter to fix
  local OUTPUT
  OUTPUT=$(resolve_CPU_temperature_source "lm-sensors" "true" 2>&1)
  local -r EXIT_CODE=$?

  assert_reported_as_a_configuration_error "CPU_TEMPERATURE_SOURCE" "lm-sensors" "$EXIT_CODE" "$OUTPUT"
  assert_contains "$OUTPUT" "IDRAC_HOST" "the error should say which other parameter can resolve it"
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
  # The one refusal of the lot a restart can genuinely clear, and therefore the one
  # the notice above must stay away from : an iDRAC that was rebooting, or a network
  # that was down, answers on the next attempt without anybody correcting anything.
  # Telling that user restarting will not help would send them looking for a mistake
  # they did not make, and away from the restart policy the README asks them to run
  # under for this very reason
  assert_not_contains "$OUTPUT" "Restarting will not help" \
    "an iDRAC that did not answer this time may answer the next"
}

function test_a_missing_ipmi_device_reports_as_a_configuration_error() {
  # Local mode without the host's IPMI device exposed to the container. IPMI_DEVICE_PATHS
  # is pointed at paths that cannot exist rather than at /dev, which is machine-global
  local OUTPUT
  OUTPUT=$(
    IPMI_DEVICE_PATHS=("$TEST_TEMPORARY_DIRECTORY/absent-ipmi0" "$TEST_TEMPORARY_DIRECTORY/absent-ipmi1")
    set_iDRAC_login_string "local" "root" "calvin" 2>&1
  )
  local -r EXIT_CODE=$?

  assert_reported_as_a_configuration_error "IDRAC_HOST" "local" "$EXIT_CODE" "$OUTPUT"
}

function test_the_missing_device_error_points_at_device_rather_than_at_e() {
  # The reason this refusal was held back from #258 : its fix is in "--device", so the
  # closing sentence every other parameter shares would send the user to the wrong place
  local -r OUTPUT=$(
    IPMI_DEVICE_PATHS=("$TEST_TEMPORARY_DIRECTORY/absent-ipmi0")
    set_iDRAC_login_string "local" "root" "calvin" 2>&1
  )

  assert_contains "$OUTPUT" "--device=" "the fix is a device argument, and should be spelled out"
  assert_contains "$OUTPUT" "devices:" "the compose equivalent should be named too"
  assert_contains "$OUTPUT" "network mode" "the other way out is to stop asking for local mode"
  assert_not_contains "$OUTPUT" "\"-e\" arguments" \
    "the environment variable wording would send the user to the wrong place here"
}

function test_no_configuration_refusal_is_left_reporting_as_a_single_line() {
  # The point of the block is that it is the only form a refused parameter takes.
  # A refusal added later and wired to print_error_and_exit out of habit is exactly
  # what this case is here to catch -- it already happened once, CPU_TEMPERATURE_SOURCE
  # having landed with three single-line refusals while this branch was open.
  #
  # Matched on the parameter names rather than on one spelling of the call, a refusal
  # naming its parameter in a variable and one naming it literally being the same
  # mistake.
  #
  # "Could not open device" is listed separately because it is the one refusal whose
  # message names no parameter at all -- adding IDRAC_HOST to the list below does not
  # reach it, so a revert to the single-line form would slip past a names-only match.
  # The two cases above cover that revert behaviourally ; this keeps the grep honest
  local -r PARAMETERS="FAN_SPEED|CHECK_INTERVAL|CPU_TEMPERATURE_THRESHOLD|CPU_TEMPERATURE_SOURCE|IDRAC_HOST|MONITORING_ONLY_MODE|DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE|KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT|PARAMETER_NAME|Could not open device"

  local OFFENDERS
  OFFENDERS=$(grep -nE "print_error_and_exit .*($PARAMETERS)" \
    "$REPO_ROOT/functions.sh" "$REPO_ROOT/Dell_iDRAC_fan_controller.sh" | grep -v "would otherwise" || true)

  assert_empty "$OFFENDERS" \
    "a refused configuration parameter should report through print_configuration_error_and_exit, not as a single line"
}
