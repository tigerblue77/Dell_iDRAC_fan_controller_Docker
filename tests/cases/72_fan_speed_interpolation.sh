#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# ENABLE_LINE_INTERPOLATION (issue #44) : an opt-in ramp between FAN_SPEED and HIGH_FAN_SPEED as the
# hottest detected CPU rises from CPU_TEMPERATURE_FOR_START_LINE_INTERPOLATION towards
# CPU_TEMPERATURE_THRESHOLD, instead of jumping straight from FAN_SPEED to Dell's default profile.
#
# Five community pull requests attempted this feature before this one, and every one of them was found,
# on review, to have reintroduced at least one already-settled bug from this codebase's own history :
# passing variable names instead of values into a command substitution ("return" instead of "echo",
# which a subshell then discards), dividing before multiplying (silently truncating the whole ramp to
# its base speed), or duplicating apply_user_fan_control_profile() instead of parameterizing it (losing
# the refusal memory, the per-fan identifier walk and the hand-back to Dell for the interpolated path
# alone). The test cases below are aimed squarely at that history.

# MANUAL_FAN_CONTROL_COMMAND and FAN_SPEED_COMMAND are already declared readonly by
# cases/70_fan_control_profiles.sh, every case file being sourced into the same shell

# --- compute_interpolated_fan_speed() -------------------------------------------------------------

function given_the_interpolation_parameters() {
  DECIMAL_FAN_SPEED="$1"
  DECIMAL_HIGH_FAN_SPEED="$2"
  CPU_TEMPERATURE_FOR_START_LINE_INTERPOLATION="$3"
  CPU_TEMPERATURE_THRESHOLD="$4"
}

function test_the_interpolated_speed_matches_the_worked_example_the_readme_documents() {
  # FAN_SPEED=10, HIGH_FAN_SPEED=50, start=30°C, threshold=70°C : the exact table README.md's
  # CPU_TEMPERATURE_FOR_START_LINE_INTERPOLATION bullet documents
  given_the_interpolation_parameters 10 50 30 70

  assert_equals "10" "$(compute_interpolated_fan_speed 15)" "below the start point : base speed"
  assert_equals "10" "$(compute_interpolated_fan_speed 30)" "at the start point : base speed"
  assert_equals "15" "$(compute_interpolated_fan_speed 35)"
  assert_equals "30" "$(compute_interpolated_fan_speed 50)"
  assert_equals "49" "$(compute_interpolated_fan_speed 69)"
  assert_equals "50" "$(compute_interpolated_fan_speed 70)" "at the threshold : the top of the ramp"
}

function test_the_interpolated_speed_multiplies_before_it_divides() {
  # A value that only survives when the fan speed delta is multiplied by the temperature offset
  # BEFORE dividing by the temperature range : done the other way round, bash's integer division
  # truncates (69-30)/(70-30) to 0 first, and every reading in the ramp comes back as the base speed
  given_the_interpolation_parameters 10 50 30 70

  assert_not_equals "10" "$(compute_interpolated_fan_speed 69)" \
    "divide-before-multiply silently flattens the whole ramp to the base speed"
}

function test_the_interpolated_speed_clamps_above_the_threshold() {
  # Defensive : the only caller never asks past the threshold (is_any_CPU_overheating already routed
  # anything higher to Dell's profile), but the function is safety-relevant on its own terms
  given_the_interpolation_parameters 10 50 30 70

  assert_equals "50" "$(compute_interpolated_fan_speed 95)"
}

function test_the_interpolated_speed_fails_safe_on_an_unreadable_temperature() {
  given_the_interpolation_parameters 10 50 30 70

  assert_equals "10" "$(compute_interpolated_fan_speed "")" "an empty reading must fall back to the base speed"
  assert_equals "10" "$(compute_interpolated_fan_speed "-")" "an unreadable reading must fall back to the base speed"
}

function test_the_interpolated_speed_does_not_read_a_leading_zero_as_octal() {
  # "050" parsed with bash's own arithmetic expansion is 40 in decimal, not 50 -- normalize_decimal_value
  # is what compute_interpolated_fan_speed relies on to avoid it
  given_the_interpolation_parameters 10 50 30 70

  assert_equals "10" "$(compute_interpolated_fan_speed "030")" "030°C is the start point, not octal 24"
}

# --- hottest_detected_CPU_temperature() -----------------------------------------------------------

function test_the_hottest_detected_cpu_drives_the_ramp_on_a_multi_socket_server() {
  # Unlike the two-CPU-only shape ENABLE_LINE_INTERPOLATION was first proposed with, a 4-socket
  # server (R930, R830...) must be driven by whichever of its CPUs is hottest, not only the first one
  given_the_detected_cpu_temperatures 40 55 38 61

  assert_equals "61" "$(hottest_detected_CPU_temperature)"
}

function test_the_hottest_detected_cpu_skips_an_unreadable_reading() {
  given_the_detected_cpu_temperatures 40 "-" 38

  assert_equals "40" "$(hottest_detected_CPU_temperature)"
}

function test_the_hottest_detected_cpu_is_empty_when_none_is_readable() {
  given_the_detected_cpu_temperatures "-" ""

  assert_empty "$(hottest_detected_CPU_temperature)"
}

# --- apply_user_fan_control_profile(), parameterized -------------------------------------------------

function test_apply_user_fan_control_profile_with_no_argument_is_unchanged() {
  # The whole point of extending this function instead of duplicating it : every existing call site,
  # in this codebase and in this very suite, keeps working with no argument at all
  DECIMAL_FAN_SPEED=5
  HEXADECIMAL_FAN_SPEED="0x05"

  apply_user_fan_control_profile

  assert_equals "1" "$(count_ipmitool_calls_matching "$FAN_SPEED_COMMAND 0x05")"
  assert_equals "User static fan control profile (5%)" "$CURRENT_FAN_CONTROL_PROFILE"
}

function test_apply_user_fan_control_profile_sends_the_interpolated_speed_not_the_static_one() {
  DECIMAL_FAN_SPEED=5
  HEXADECIMAL_FAN_SPEED="0x05"

  apply_user_fan_control_profile 37 "0x25" "User interpolated fan profile"

  assert_equals "0" "$(count_ipmitool_calls_matching "$FAN_SPEED_COMMAND 0x05")" \
    "the static FAN_SPEED must not be the one sent"
  assert_equals "1" "$(count_ipmitool_calls_matching "$FAN_SPEED_COMMAND 0x25")"
  assert_equals "1" "$(count_ipmitool_calls_matching "$MANUAL_FAN_CONTROL_COMMAND")"
  assert_equals "User interpolated fan profile (37%)" "$CURRENT_FAN_CONTROL_PROFILE"
}

function test_apply_user_fan_control_profile_reports_the_interpolated_speed_in_monitoring_only_mode() {
  export MONITORING_ONLY_MODE=true

  apply_user_fan_control_profile 37 "0x25" "User interpolated fan profile"

  assert_equals "0" "$(count_ipmitool_calls_matching "raw 0x30 0x30")" \
    "monitoring only mode must not send a single fan control command"
  assert_equals "User interpolated fan profile (37%) (monitoring only, not applied)" "$CURRENT_FAN_CONTROL_PROFILE"
}

function test_apply_user_fan_control_profile_reports_a_refused_interpolated_speed() {
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0x30 0x02 0xff 0x25"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="Unable to send RAW command (channel=0x0 netfn=0x30 lun=0x0 cmd=0x30 rsp=0xff): Unspecified error"

  apply_user_fan_control_profile 37 "0x25" "User interpolated fan profile"

  assert_equals "User interpolated fan profile (37%) (not applied)" "$CURRENT_FAN_CONTROL_PROFILE"
}

# --- Startup validation -----------------------------------------------------------------------------

function test_line_interpolation_is_disabled_by_default() {
  simulate_server "PowerEdge R730xd" --cpus 1 --cpu-temperatures "42"

  local -r OUTPUT=$(run_controller)

  assert_contains "$OUTPUT" "Fan speed interpolation: Disabled"
}

function test_an_invalid_enable_line_interpolation_value_refuses_to_start() {
  simulate_server "PowerEdge R730xd" --cpus 1 --cpu-temperatures "42"
  export ENABLE_LINE_INTERPOLATION="yes"

  local -r OUTPUT=$(run_controller)

  assert_contains "$OUTPUT" "Invalid configuration, the container will not start"
  assert_contains "$OUTPUT" "ENABLE_LINE_INTERPOLATION"
}

function test_high_fan_speed_and_the_start_temperature_are_not_validated_when_the_feature_is_disabled() {
  # A value that would be refused with the feature on must not stop a container that never reads it :
  # nothing here is about HIGH_FAN_SPEED / CPU_TEMPERATURE_FOR_START_LINE_INTERPOLATION unless
  # ENABLE_LINE_INTERPOLATION actually turns them on
  simulate_server "PowerEdge R730xd" --cpus 1 --cpu-temperatures "42"
  export HIGH_FAN_SPEED="not a speed"
  export CPU_TEMPERATURE_FOR_START_LINE_INTERPOLATION="not a temperature"

  local -r OUTPUT=$(run_controller)

  assert_not_contains "$OUTPUT" "Invalid configuration, the container will not start"
  assert_contains "$OUTPUT" "Fan speed interpolation: Disabled"
}

function test_a_start_temperature_at_or_above_the_threshold_refuses_to_start() {
  simulate_server "PowerEdge R730xd" --cpus 1 --cpu-temperatures "42"
  export ENABLE_LINE_INTERPOLATION=true
  export CPU_TEMPERATURE_THRESHOLD=50
  export CPU_TEMPERATURE_FOR_START_LINE_INTERPOLATION=50

  local -r OUTPUT=$(run_controller)

  assert_contains "$OUTPUT" "Invalid configuration, the container will not start"
  assert_contains "$OUTPUT" "CPU_TEMPERATURE_FOR_START_LINE_INTERPOLATION"
}

function test_a_high_fan_speed_at_or_below_fan_speed_refuses_to_start() {
  simulate_server "PowerEdge R730xd" --cpus 1 --cpu-temperatures "42"
  export ENABLE_LINE_INTERPOLATION=true
  export FAN_SPEED=20
  export HIGH_FAN_SPEED=20

  local -r OUTPUT=$(run_controller)

  assert_contains "$OUTPUT" "Invalid configuration, the container will not start"
  assert_contains "$OUTPUT" "HIGH_FAN_SPEED"
}

function test_a_start_temperature_outside_the_plausible_window_refuses_to_start() {
  simulate_server "PowerEdge R730xd" --cpus 1 --cpu-temperatures "42"
  export ENABLE_LINE_INTERPOLATION=true
  export CPU_TEMPERATURE_FOR_START_LINE_INTERPOLATION=200

  local -r OUTPUT=$(run_controller)

  assert_contains "$OUTPUT" "Invalid configuration, the container will not start"
  assert_contains "$OUTPUT" "CPU_TEMPERATURE_FOR_START_LINE_INTERPOLATION"
}

function test_enabling_interpolation_against_the_auto_threshold_still_starts() {
  # The one regression every rework of this feature is at risk of : validating
  # CPU_TEMPERATURE_FOR_START_LINE_INTERPOLATION against CPU_TEMPERATURE_THRESHOLD before "auto" has been
  # resolved to a number refuses to start on the image's own stock default
  simulate_server "PowerEdge R730xd" --cpus 1 --cpu-temperatures "42"
  export ENABLE_LINE_INTERPOLATION=true
  export CPU_TEMPERATURE_THRESHOLD=auto

  local -r OUTPUT=$(run_controller)

  assert_not_contains "$OUTPUT" "Invalid configuration, the container will not start"
  assert_contains "$OUTPUT" "Fan speed interpolation: Enabled"
}

# --- End to end ---------------------------------------------------------------------------------------

function test_the_controller_ramps_the_fan_speed_between_the_two_configured_thresholds() {
  simulate_server "PowerEdge R730xd" --cpus 2 --cpu-temperatures "50 35"
  export ENABLE_LINE_INTERPOLATION=true
  export FAN_SPEED=10
  export HIGH_FAN_SPEED=50
  export CPU_TEMPERATURE_FOR_START_LINE_INTERPOLATION=30
  export CPU_TEMPERATURE_THRESHOLD=70

  local -r OUTPUT=$(run_controller)

  # Hottest of the two is CPU 1 at 50°C, which compute_interpolated_fan_speed(10, 50, 30, 70) puts at 30%
  assert_contains "$OUTPUT" "User interpolated fan profile (30%)"
  assert_equals "1" "$(count_ipmitool_calls_matching "$FAN_SPEED_COMMAND 0x1e")" \
    "30% must be the byte actually sent to the server (0x1e)"
  assert_equals "0" "$(count_ipmitool_calls_matching "$FAN_SPEED_COMMAND 0x0a")" \
    "FAN_SPEED (0x0a) itself must not be the one sent while the ramp is active"
}

function test_the_controller_still_falls_back_to_dell_above_the_threshold_while_interpolation_is_on() {
  # CPU_TEMPERATURE_THRESHOLD is documented as still applying unchanged as the final safety fallback :
  # this is what proves it rather than only the ramp underneath it
  simulate_server "PowerEdge R730xd" --cpus 1 --cpu-temperatures "80"
  export ENABLE_LINE_INTERPOLATION=true
  export CPU_TEMPERATURE_THRESHOLD=70

  local -r OUTPUT=$(run_controller)

  assert_contains "$OUTPUT" "Dell default dynamic fan control profile applied for safety"
  assert_not_contains "$OUTPUT" "User interpolated fan profile"
}
