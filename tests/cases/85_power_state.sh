#!/bin/bash

# In network mode the container keeps running while the server it cools is
# powered off. Reading temperatures then would be meaningless, and applying a fan
# control profile would either fail or wake the fans of a sleeping chassis, so
# the whole cycle is skipped. Anything that is not a clear "powered on" answer
# must therefore be treated as powered off.

function test_a_powered_on_server_is_detected() {
  export MOCK_IPMITOOL_POWER_STATUS="Chassis Power is on"

  assert_command_succeeds "a server answering \"Chassis Power is on\" is powered on" is_server_powered_on
}

function test_a_powered_off_server_is_detected() {
  export MOCK_IPMITOOL_POWER_STATUS="Chassis Power is off"

  assert_command_fails "a server answering \"Chassis Power is off\" is powered off" is_server_powered_on
}

function test_an_empty_power_status_is_treated_as_powered_off() {
  export MOCK_IPMITOOL_POWER_STATUS=""

  assert_command_fails "no answer at all must not be read as powered on" is_server_powered_on
}

function test_a_failing_power_status_query_is_treated_as_powered_off() {
  # An iDRAC that stopped answering, a wrong password, a network outage : none of
  # them is a reason to start sending fan control commands into the void
  export MOCK_IPMITOOL_POWER_EXIT_CODE=1
  export MOCK_IPMITOOL_POWER_STATUS="Error: Unable to establish IPMI v2 / RMCP+ session"

  assert_command_fails "a failing query must not be read as powered on" is_server_powered_on
}

function test_the_power_status_is_queried_through_the_idrac_login_string() {
  IDRAC_LOGIN_STRING="lanplus -H 10.0.0.42 -U administrator -E"

  is_server_powered_on

  assert_equals "1" "$(count_ipmitool_calls_matching "chassis power status")"
  assert_contains "$(recorded_ipmitool_calls)" "-H 10.0.0.42 -U administrator -E" \
    "the power status must be read from the same iDRAC as the temperatures"
}
