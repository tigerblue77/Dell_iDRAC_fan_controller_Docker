#!/bin/bash

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

function test_a_plain_number_of_seconds_is_accepted() {
  local VALUE
  for VALUE in 1 5 60 3600; do
    assert_check_interval_is_accepted "$VALUE"
  done
}

function test_a_unit_suffix_is_accepted() {
  # GNU sleep takes a unit suffix, so these have been pacing containers correctly
  # all along even though the README documents plain seconds. Refusing them now
  # would stop a container that never had a problem
  local VALUE
  for VALUE in 30s 5m 1h 1d; do
    assert_check_interval_is_accepted "$VALUE"
  done
}

function test_a_padded_value_is_read_as_decimal_not_octal() {
  # "08" is not a valid octal number : the zero check must not abort on it
  assert_check_interval_is_accepted "08" "08 seconds is 8 seconds, not an invalid octal number"
  assert_check_interval_is_accepted "090" "090 seconds is 90 seconds"
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
