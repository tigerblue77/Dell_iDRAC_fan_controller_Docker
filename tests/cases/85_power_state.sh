#!/bin/bash

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
