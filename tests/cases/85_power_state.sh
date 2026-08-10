#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# In network mode the container keeps running while the server it cools is
# powered off. Reading temperatures then would be meaningless, and applying a fan
# control profile would either fail or wake the fans of a sleeping chassis, so
# the whole cycle is skipped.
#
# A chassis that is genuinely off and an iDRAC that cannot be reached at all both
# skip the cycle, but they are not the same event and must not be reported as
# one: the first is a machine legitimately at rest, the second is a server we may
# well be holding at a static fan speed with no way to see or change anything
# about it. get_server_power_state therefore has three outcomes rather than two.

function test_a_powered_on_server_is_detected() {
  export MOCK_IPMITOOL_POWER_STATUS="Chassis Power is on"

  assert_command_succeeds "a server answering \"Chassis Power is on\" is powered on" get_server_power_state
}

function test_a_powered_off_server_is_detected() {
  export MOCK_IPMITOOL_POWER_STATUS="Chassis Power is off"

  get_server_power_state
  assert_equals "1" "$?" "a server answering \"Chassis Power is off\" is powered off, not unreachable"
}

function test_an_empty_power_status_is_not_read_as_powered_on() {
  # The query succeeded and simply didn't say "is on". That is not an unreachable
  # iDRAC, so it stays in the powered-off branch rather than being escalated
  export MOCK_IPMITOOL_POWER_STATUS=""

  get_server_power_state
  assert_equals "1" "$?" "no answer at all must not be read as powered on"
}

function test_an_unreachable_idrac_is_told_apart_from_a_powered_off_server() {
  # An iDRAC that stopped answering, a wrong password, a network outage: none of
  # them is a powered-off chassis, and reporting them as one is what used to
  # freeze fan control indefinitely while the log called it benign
  export MOCK_IPMITOOL_POWER_EXIT_CODE=1
  export MOCK_IPMITOOL_POWER_STATUS="Error: Unable to establish IPMI v2 / RMCP+ session"

  get_server_power_state
  assert_equals "2" "$?" "a failing query must be reported as unreachable, not as powered off"
}

function test_an_unreachable_idrac_keeps_the_reason_it_gave() {
  # The caller prints this, so a user can tell a rotated password from a LAN flap
  # instead of being told the server is off
  export MOCK_IPMITOOL_POWER_EXIT_CODE=1
  export MOCK_IPMITOOL_POWER_STATUS="Error: Unable to establish IPMI v2 / RMCP+ session"

  get_server_power_state

  assert_contains "$IPMI_UNREACHABLE_REASON" "Unable to establish IPMI v2 / RMCP+ session" \
    "the reason ipmitool gave must survive for the caller to report"
}

function test_the_power_status_is_queried_through_the_idrac_login_string() {
  IDRAC_LOGIN_STRING="lanplus -H 10.0.0.42 -U administrator -E"

  get_server_power_state

  assert_equals "1" "$(count_ipmitool_calls_matching "chassis power status")"
  assert_contains "$(recorded_ipmitool_calls)" "-H 10.0.0.42 -U administrator -E" \
    "the power status must be read from the same iDRAC as the temperatures"
}

function test_the_escalation_can_be_disabled_by_emptying_both_parameters() {
  # Exiting only helps a container something restarts, and Docker's default policy
  # is "no", so emptying both has to remain a supported configuration : it restores
  # the retry-forever behaviour, which recovers on its own when the iDRAC answers
  export MAXIMUM_IPMI_UNREACHABLE_DURATION=""
  export MAXIMUM_CONSECUTIVE_IPMI_FAILURES=""
  simulate_server "PowerEdge R740" --cpus 2
  # Reachable long enough to start, then unreachable and staying so
  export MOCK_IPMITOOL_POWER_EXIT_CODE_SEQUENCE="0 1"

  local -r OUTPUT=$(run_controller "Cannot reach the iDRAC" 4)

  assert_contains "$OUTPUT" "Cannot reach the iDRAC" \
    "the container must keep reporting the unreachable iDRAC"
  assert_not_contains "$OUTPUT" "times in a row" \
    "no escalation may happen once both parameters are emptied"
}

function test_the_container_exits_after_the_configured_consecutive_failures() {
  export MAXIMUM_CONSECUTIVE_IPMI_FAILURES=3
  simulate_server "PowerEdge R740" --cpus 2
  export MOCK_IPMITOOL_POWER_EXIT_CODE=1

  local -r OUTPUT=$(run_controller "times in a row")

  assert_contains "$OUTPUT" "could not be reached 3 times in a row" \
    "the message must say how many consecutive failures were reached"
  assert_contains "$OUTPUT" "restart policy" \
    "and why exiting is the useful move, since it cannot move the fans itself"
}

function test_the_startup_log_states_what_the_escalation_resolved_to() {
  # It is the only configured parameter whose resolution performs a conversion the
  # user did not write -- a duration becomes a number of checks, rounded up against
  # CHECK_INTERVAL -- and it was the only one whose resolved value was never shown.
  # Every shape is asserted, the disabled one included, a log that goes silent when
  # the escalation is off being indistinguishable from one that forgot to print it
  assert_equals "After 12 checks (60s, rounded up to whole check intervals)" \
    "$(describe_IPMI_unreachable_escalation "" "60s" 12)" \
    "a duration should be reported with the number of checks it became"
  assert_equals "After 1 check (5, rounded up to whole check intervals)" \
    "$(describe_IPMI_unreachable_escalation "" "5" 1)" \
    "and in the singular when it collapsed to one"
  assert_equals "After 3 checks (set by MAXIMUM_CONSECUTIVE_IPMI_FAILURES)" \
    "$(describe_IPMI_unreachable_escalation "3" "60s" 3)" \
    "a count converts nothing, so it names the parameter in force instead"
  assert_equals "Disabled (the iDRAC is retried until it answers)" \
    "$(describe_IPMI_unreachable_escalation "" "" "")" \
    "and a disabled escalation says what happens instead of exiting"
}

function test_the_controller_reports_the_escalation_it_will_apply() {
  export MAXIMUM_IPMI_UNREACHABLE_DURATION="60s"
  export MAXIMUM_CONSECUTIVE_IPMI_FAILURES=""
  export CHECK_INTERVAL=5
  simulate_server "PowerEdge R740" --cpus 2

  local -r OUTPUT=$(run_controller)

  assert_contains "$OUTPUT" "iDRAC unreachable escalation: After 12 checks" \
    "the startup log should state the escalation alongside every other parameter"
}

function test_a_duration_that_collapses_to_a_single_check_is_warned_about() {
  # A single check is exiting on the very first unreachable reading, which is word
  # for word what a zero is refused for -- and reachable by any duration at or below
  # CHECK_INTERVAL without a refusal. The rounding is right; its silence was not
  local -r OUTPUT=$(warn_if_the_escalation_exits_on_the_first_failure "" "5" "1")

  assert_contains "$OUTPUT" "Warning" "a duration worth one check should not pass in silence"
  assert_contains "$OUTPUT" "MAXIMUM_IPMI_UNREACHABLE_DURATION is \"5\"" \
    "the warning should quote back the parameter that produced it"
  assert_contains "$OUTPUT" "at or below CHECK_INTERVAL" \
    "and say why a value that looks reasonable resolved to one check"
  assert_contains "$OUTPUT" "very first unreachable reading" \
    "and what a single check actually does"
}

function test_an_explicitly_configured_single_failure_is_warned_about_too() {
  # Reached by typing it rather than by an invisible rounding, but the server does
  # not care which parameter produced it : one check is one glitch away from a
  # container that exits either way. Warning on one and not the other would read as
  # the other being the safe way to ask for the same thing
  local -r OUTPUT=$(warn_if_the_escalation_exits_on_the_first_failure "1" "" "1")

  assert_contains "$OUTPUT" "Warning" "one check is one check, whichever parameter set it"
  assert_contains "$OUTPUT" "MAXIMUM_CONSECUTIVE_IPMI_FAILURES is \"1\"" \
    "the warning should name the parameter actually in force"
  assert_not_contains "$OUTPUT" "CHECK_INTERVAL, so it resolves" \
    "nothing was rounded here, so it must not be explained as if it had been"
}

function test_a_duration_worth_several_checks_is_not_warned_about() {
  local -r OUTPUT=$(warn_if_the_escalation_exits_on_the_first_failure "" "60s" "12")

  assert_empty "$OUTPUT" "a duration that survives more than one glitch needs no warning"
}

function test_a_disabled_escalation_is_not_warned_about() {
  # Nothing exits at all, so there is no first failure to warn about -- and naming a
  # parameter the user did not set would send them looking for one they never wrote
  local -r OUTPUT=$(warn_if_the_escalation_exits_on_the_first_failure "" "" "")

  assert_empty "$OUTPUT" "an escalation that never fires cannot fire too early"
}

function test_a_powered_off_server_never_counts_towards_the_escalation() {
  # A chassis correctly reported as off is a state that was observed, not a failure
  # to reach anything : counting it would exit on a server simply left switched off
  export MAXIMUM_CONSECUTIVE_IPMI_FAILURES=2
  simulate_server "PowerEdge R740" --cpus 2
  export MOCK_IPMITOOL_POWER_STATUS="Chassis Power is off"

  local -r OUTPUT=$(run_controller "Target server is powered off" 5)

  assert_contains "$OUTPUT" "Target server is powered off"
  assert_not_contains "$OUTPUT" "times in a row" \
    "a powered off server must never trigger the escalation, however long it stays off"
}

function test_the_duration_is_resolved_into_cycles_against_the_check_interval() {
  # The duration is what users configure, so it has to keep meaning the same thing
  # whatever CHECK_INTERVAL is : 60s is 12 cycles at 5s and 6 at 10s
  resolve_IPMI_failures_before_exit "" "60s" 5
  assert_equals "12" "$IPMI_FAILURES_BEFORE_EXIT" "60s at a 5s interval is 12 cycles"

  resolve_IPMI_failures_before_exit "" "60s" 10
  assert_equals "6" "$IPMI_FAILURES_BEFORE_EXIT" "the same duration is fewer cycles at a longer interval"

  resolve_IPMI_failures_before_exit "" "5m" 5
  assert_equals "60" "$IPMI_FAILURES_BEFORE_EXIT" "a unit suffix is understood like CHECK_INTERVAL's"

  # Rounded up, never below one : a threshold shorter than a cycle still has to let
  # one failure happen before anything can be concluded from it
  resolve_IPMI_failures_before_exit "" "7s" 5
  assert_equals "2" "$IPMI_FAILURES_BEFORE_EXIT" "a partial cycle rounds up rather than down"
  resolve_IPMI_failures_before_exit "" "1s" 30
  assert_equals "1" "$IPMI_FAILURES_BEFORE_EXIT" "shorter than one cycle still allows one failure"
}

function test_an_explicit_cycle_count_takes_precedence_over_the_duration() {
  resolve_IPMI_failures_before_exit "3" "60s" 5
  assert_equals "3" "$IPMI_FAILURES_BEFORE_EXIT" \
    "the count is the more specific of the two and wins when set"

  resolve_IPMI_failures_before_exit "" "" 5
  assert_empty "$IPMI_FAILURES_BEFORE_EXIT" "both empty disables the escalation"
}

function test_the_container_exits_after_the_configured_unreachable_duration() {
  # 10s at the 5s interval the tests run with is 2 cycles
  export MAXIMUM_IPMI_UNREACHABLE_DURATION=10s
  simulate_server "PowerEdge R740" --cpus 2
  export MOCK_IPMITOOL_POWER_EXIT_CODE=1

  local -r OUTPUT=$(run_controller "times in a row")

  assert_contains "$OUTPUT" "could not be reached 2 times in a row" \
    "the duration must be honoured through the cycle count it represents"
  assert_contains "$OUTPUT" "restart policy"
}
