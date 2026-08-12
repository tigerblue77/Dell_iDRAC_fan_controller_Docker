#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# The check interval, the monitoring loop's only pacing mechanism. It is handed
# straight to sleep, whose exit status the loop cannot observe : it waits on the
# background timer's PID, and wait returns as soon as the already-dead child is
# reaped, so a sleep that refused to run looks exactly like one that waited. A
# value sleep cannot wait for therefore doesn't slow the loop down, it removes
# the pacing entirely and leaves it spinning against the iDRAC.

# validate_check_interval_parameter answers by stopping the controller, so the
# call has to happen in the subshell a command substitution creates : the exit
# inside print_error_and_exit would otherwise take the test runner down with it
function assert_check_interval_is_refused() {
  local -r VALUE="$1"
  local -r MESSAGE="${2:-\"$VALUE\" should stop the controller}"

  local OUTPUT
  OUTPUT=$(validate_check_interval_parameter "CHECK_INTERVAL" "$VALUE" 2>&1)
  local -r EXIT_CODE=$?

  assert_equals 1 "$EXIT_CODE" "$MESSAGE"
  assert_contains "$OUTPUT" "CHECK_INTERVAL" "the error should name the parameter at fault"
}

function assert_check_interval_is_accepted() {
  local -r VALUE="$1"
  local -r MESSAGE="${2:-\"$VALUE\" is a duration sleep waits for and should be accepted}"

  local OUTPUT
  OUTPUT=$(validate_check_interval_parameter "CHECK_INTERVAL" "$VALUE" 2>&1)
  local -r EXIT_CODE=$?

  assert_equals 0 "$EXIT_CODE" "$MESSAGE"
  assert_empty "$OUTPUT" "accepting a value should print nothing"
}

# A long interval still paces the loop, so it is accepted, but it is also how
# long the fans stay pinned before anything reacts : the user is told
function assert_check_interval_is_accepted_with_a_warning() {
  local -r VALUE="$1"
  local -r MESSAGE="${2:-\"$VALUE\" should be accepted, with a warning about the reaction time}"

  local OUTPUT
  OUTPUT=$(validate_check_interval_parameter "CHECK_INTERVAL" "$VALUE" 2>&1)
  local -r EXIT_CODE=$?

  assert_equals 0 "$EXIT_CODE" "$MESSAGE"
  assert_contains "$OUTPUT" "Warning" "a long interval should warn instead of staying silent"
  assert_contains "$OUTPUT" "$VALUE" "the warning should quote the value it is about"
}

# In monitoring only mode no profile is ever applied, so both bounds are lifted
function assert_check_interval_is_accepted_in_monitoring_only_mode() {
  local -r VALUE="$1"
  local -r MESSAGE="${2:-\"$VALUE\" carries no thermal risk in monitoring only mode}"

  local OUTPUT
  OUTPUT=$(validate_check_interval_parameter "CHECK_INTERVAL" "$VALUE" "true" 2>&1)
  local -r EXIT_CODE=$?

  assert_equals 0 "$EXIT_CODE" "$MESSAGE"
  assert_empty "$OUTPUT" "there is no reaction time to warn about when the fans are left to the iDRAC"
}

function test_a_plain_number_of_seconds_is_accepted() {
  local VALUE
  for VALUE in 1 5 60; do
    assert_check_interval_is_accepted "$VALUE"
  done
}

function test_a_unit_suffix_is_accepted() {
  # GNU sleep takes a unit suffix, so these have been pacing containers correctly
  # all along even though the README documents plain seconds. Refusing them now
  # would stop a container that never had a problem
  assert_check_interval_is_accepted "30s"
  assert_check_interval_is_accepted_with_a_warning "5m"
}

function test_a_padded_check_interval_is_read_as_decimal_not_octal() {
  # "08" is not a valid octal number : the zero check must not abort on it
  assert_check_interval_is_accepted "08" "08 seconds is 8 seconds, not an invalid octal number"
  # Warned about rather than silent, which is the proof it was read as 90 and
  # compared against the threshold as such
  assert_check_interval_is_accepted_with_a_warning "090" "090 seconds is 90 seconds"
}

function test_a_value_sleep_cannot_parse_stops_the_controller() {
  # Every one of these makes the real sleep return in about 4 ms instead of
  # waiting, which the loop has no way of noticing
  local VALUE
  for VALUE in "" "abc" "60 s" "60ss" "-5" "1 minute" "60S"; do
    assert_check_interval_is_refused "$VALUE"
  done
}

function test_a_zero_check_interval_stops_the_controller() {
  # Zero is the case sleep itself accepts : it parses, returns immediately, and
  # spins the loop just like a value sleep rejects outright
  local VALUE
  for VALUE in "0" "00" "0s" "0m"; do
    assert_check_interval_is_refused "$VALUE" "a zero interval leaves the loop unpaced"
  done
}

function test_a_fractional_value_is_refused_although_sleep_accepts_it() {
  # sleep waits for "0.5" happily, so this is a decision rather than an oversight :
  # a sub-second cycle would send the 4 to 5 IPMI commands a cycle costs more than
  # once a second, which is the hammering this validation exists to prevent
  local VALUE
  for VALUE in "0.5" ".5" "1.5" "0.5s" "2.5m"; do
    assert_check_interval_is_refused "$VALUE" "\"$VALUE\" is refused on purpose, despite sleep accepting it"
  done
}

function test_the_suffix_decides_how_long_the_interval_really_is() {
  # The bounds are compared against seconds, so the suffix has to be applied
  # rather than stripped : "2h" is 7200 seconds, not 2
  assert_equals 90 "$(convert_duration_to_seconds 90)" "a bare number is already seconds"
  assert_equals 90 "$(convert_duration_to_seconds 90s)" "an s suffix is seconds"
  assert_equals 120 "$(convert_duration_to_seconds 2m)" "an m suffix is minutes"
  assert_equals 7200 "$(convert_duration_to_seconds 2h)" "an h suffix is hours"
  assert_equals 86400 "$(convert_duration_to_seconds 1d)" "a d suffix is days"
  assert_equals 8 "$(convert_duration_to_seconds 08)" "a padded value is decimal, not octal"
}

function test_an_interval_longer_than_a_minute_is_accepted_with_a_warning() {
  # Nothing here is unusable : the loop is paced correctly, the iDRAC is not
  # hammered. What the user is told is that the controller now needs this long
  # to notice a temperature spike, the fans being pinned in the meantime
  local VALUE
  for VALUE in 61 90 300 5m 900 15m; do
    assert_check_interval_is_accepted_with_a_warning "$VALUE"
  done
}

function test_the_warning_starts_above_a_minute_not_at_it() {
  assert_check_interval_is_accepted "60" "a minute is the threshold itself and should stay silent"
  assert_check_interval_is_accepted "1m" "a minute expressed with its unit is the same interval"
  assert_check_interval_is_accepted_with_a_warning "61" "a second past the threshold should warn"
}

function test_an_interval_beyond_the_maximum_stops_the_controller() {
  # Past this point the fans would stay pinned at a speed chosen for an idle
  # machine for so long that the controller is not controlling anything anymore
  local VALUE
  for VALUE in 901 16m 1h 1d 3600; do
    assert_check_interval_is_refused "$VALUE" "\"$VALUE\" leaves the server unattended for too long"
  done
}

function test_the_maximum_is_a_boundary_the_value_has_to_exceed() {
  assert_check_interval_is_accepted_with_a_warning "15m" "fifteen minutes is the maximum, not past it"
  assert_check_interval_is_accepted_with_a_warning "900" "the same interval in seconds is also accepted"
  assert_check_interval_is_refused "901" "a second past the maximum should be refused"
}

function test_both_bounds_are_lifted_in_monitoring_only_mode() {
  # No fan control profile is ever applied in that mode : Dell's own dynamic fan
  # control keeps the fans and the interval is only a logging cadence, so a slow
  # one carries no thermal risk and there is no reaction time to warn about
  local VALUE
  for VALUE in 90 5m 1h 1d; do
    assert_check_interval_is_accepted_in_monitoring_only_mode "$VALUE"
  done
}

function test_an_unusable_interval_is_still_refused_in_monitoring_only_mode() {
  # Lifting the thermal bounds doesn't make an unpaced loop acceptable : the
  # busy loop hammers the iDRAC just as hard when it only reads temperatures
  local OUTPUT
  local EXIT_CODE

  local VALUE
  for VALUE in "abc" "0" "0.5" ""; do
    OUTPUT=$(validate_check_interval_parameter "CHECK_INTERVAL" "$VALUE" "true" 2>&1)
    EXIT_CODE=$?
    assert_equals 1 "$EXIT_CODE" "\"$VALUE\" leaves the loop unpaced whatever the mode"
  done
}

function test_the_bounds_apply_when_the_mode_is_not_given() {
  # Omitting the argument has to keep the strictest reading : assuming fan
  # control is active is the assumption that fails safe
  local OUTPUT
  OUTPUT=$(validate_check_interval_parameter "CHECK_INTERVAL" "1h" 2>&1)
  local -r EXIT_CODE=$?

  assert_equals 1 "$EXIT_CODE" "a missing mode should be read as fan control being active"
  assert_contains "$OUTPUT" "CHECK_INTERVAL" "the error should name the parameter at fault"
}

function test_the_error_on_a_too_long_interval_points_at_the_way_out() {
  local -r OUTPUT=$(validate_check_interval_parameter "CHECK_INTERVAL" "1h" 2>&1)

  assert_contains "$OUTPUT" "1h" "the error should quote the offending value"
  assert_contains "$OUTPUT" "15 minutes" "the error should say what the maximum is"
  assert_contains "$OUTPUT" "MONITORING_ONLY_MODE" \
    "the error should point at the mode that lifts the bound, for users who only want logging"
}

function test_the_controller_refuses_to_start_on_a_too_long_check_interval() {
  export CHECK_INTERVAL="2h"

  local OUTPUT
  OUTPUT=$(run_controller)
  local -r EXIT_CODE=$?

  assert_equals 1 "$EXIT_CODE" "a too long check interval should stop the controller"
  assert_contains "$OUTPUT" "CHECK_INTERVAL"
  assert_empty "$(recorded_ipmitool_calls)" \
    "the interval is validated before the first IPMI command, so a refused value costs no iDRAC session"
}

function test_the_controller_starts_on_a_too_long_check_interval_in_monitoring_only_mode() {
  export CHECK_INTERVAL="2h"
  export MONITORING_ONLY_MODE=true

  local -r OUTPUT=$(run_controller)

  assert_contains "$OUTPUT" "Server model:" "monitoring only mode should lift the maximum"
  assert_contains "$OUTPUT" "°C" "the temperatures should still be monitored"
  assert_equals 0 "$(count_ipmitool_calls_matching "raw 0x30 0x30")" \
    "no fan control profile should be applied, which is exactly why the bound is lifted"
}

function test_the_error_tells_the_user_what_is_wrong_and_what_is_accepted() {
  local OUTPUT
  OUTPUT=$(validate_check_interval_parameter "CHECK_INTERVAL" "abc" 2>&1)

  assert_contains "$OUTPUT" "abc" "the error should quote the offending value"
  assert_contains "$OUTPUT" "s, m, h or d" "the error should say which suffixes are accepted"

  OUTPUT=$(validate_check_interval_parameter "CHECK_INTERVAL" "0" 2>&1)

  assert_contains "$OUTPUT" "greater than zero" "zero should be refused on its own terms"
}

function test_the_controller_refuses_to_start_on_an_unusable_check_interval() {
  export CHECK_INTERVAL="abc"

  local OUTPUT
  OUTPUT=$(run_controller)
  local -r EXIT_CODE=$?

  assert_equals 1 "$EXIT_CODE" "an unusable check interval should stop the controller"
  assert_contains "$OUTPUT" "CHECK_INTERVAL"
  assert_empty "$(recorded_ipmitool_calls)" \
    "the interval must be validated before the first IPMI command, so a bad value costs no iDRAC session"
}

function test_the_controller_starts_normally_on_a_suffixed_check_interval() {
  export CHECK_INTERVAL="5m"

  local -r OUTPUT=$(run_controller)

  assert_contains "$OUTPUT" "Server model:" "a suffixed interval should not stop the controller"
  assert_contains "$OUTPUT" "°C" "the temperatures should still be monitored"
}

function test_the_logged_check_interval_carries_exactly_one_unit() {
  export CHECK_INTERVAL=60

  local OUTPUT
  OUTPUT=$(run_controller "Check interval:")
  assert_contains "$OUTPUT" "Check interval: 60s" "a plain number should be logged with its unit"

  export CHECK_INTERVAL="5m"

  OUTPUT=$(run_controller "Check interval:")
  assert_contains "$OUTPUT" "Check interval: 5m" "a value that already carries a unit keeps it"
  assert_not_contains "$OUTPUT" "5ms" "the unit must not be appended twice"
}
