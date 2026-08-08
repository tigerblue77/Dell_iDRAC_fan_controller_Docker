#!/bin/bash

# Both ends of Dell's intake air operating envelope. Every one of these branches
# can only reduce airflow or hand it back to iDRAC, so what matters is not that
# they fire but that they never fire when they should not : a chassis whose fans
# were slowed on a misread sensor is a heat source nobody is watching.

function assert_profile_for() {
  local -r EXPECTED="$1"; shift
  INLET_TEMPERATURE="$1"; shift
  DETECTED_CPU_TEMPERATURES=("$@")

  local ACTUAL="User"
  if is_inlet_temperature_too_high; then
    ACTUAL="Dell"
  elif is_server_too_cold; then
    ACTUAL="LowTemperature"
  fi

  assert_equals "$EXPECTED" "$ACTUAL" \
    "inlet ${INLET_TEMPERATURE}°C, CPUs ${DETECTED_CPU_TEMPERATURES[*]}"
}

function test_the_protection_is_off_when_nothing_is_configured() {
  HIGH_INLET_TEMPERATURE_THRESHOLD=""
  LOW_INLET_TEMPERATURE_THRESHOLD=""
  LOW_CPU_TEMPERATURE_THRESHOLD=""

  assert_profile_for "User" 5 30
  assert_profile_for "User" -20 30
  assert_profile_for "User" 45 30
}

function test_a_cold_chassis_reduces_the_fan_speed() {
  HIGH_INLET_TEMPERATURE_THRESHOLD=""
  LOW_INLET_TEMPERATURE_THRESHOLD=10
  LOW_CPU_TEMPERATURE_THRESHOLD=35

  assert_profile_for "LowTemperature" 5 30
  assert_profile_for "LowTemperature" -20 30
  assert_profile_for "LowTemperature" 5 30 30 30 30
}

function test_one_busy_cpu_is_enough_to_keep_the_fans_up() {
  # The AND is the whole point : a cold room with a working server in it is not a
  # situation to reduce airflow in
  HIGH_INLET_TEMPERATURE_THRESHOLD=""
  LOW_INLET_TEMPERATURE_THRESHOLD=10
  LOW_CPU_TEMPERATURE_THRESHOLD=35

  assert_profile_for "User" 5 45
  assert_profile_for "User" 5 30 45
  assert_profile_for "User" 5 30 30 30 45
  assert_profile_for "User" 25 30
}

function test_an_unreadable_reading_never_engages_the_protection() {
  # The opposite of how the CPU overheating check treats bad data, deliberately :
  # an unmeasured temperature says nothing about danger, and reducing airflow on
  # it would act on data that could not be verified
  HIGH_INLET_TEMPERATURE_THRESHOLD=35
  LOW_INLET_TEMPERATURE_THRESHOLD=10
  LOW_CPU_TEMPERATURE_THRESHOLD=35

  assert_profile_for "User" "" 30
  assert_profile_for "User" "-" 30
  assert_profile_for "User" "n/a" 30
  assert_profile_for "User" 5 ""
  assert_profile_for "User" 5 30 ""
}

function test_no_cpu_reading_at_all_is_not_every_cpu_being_cold() {
  HIGH_INLET_TEMPERATURE_THRESHOLD=""
  LOW_INLET_TEMPERATURE_THRESHOLD=10
  LOW_CPU_TEMPERATURE_THRESHOLD=35

  INLET_TEMPERATURE=5
  DETECTED_CPU_TEMPERATURES=()

  assert_command_fails "an empty CPU list must not satisfy the AND" is_server_too_cold
}

function test_a_hot_intake_hands_control_back_to_idrac() {
  HIGH_INLET_TEMPERATURE_THRESHOLD=35
  LOW_INLET_TEMPERATURE_THRESHOLD=""
  LOW_CPU_TEMPERATURE_THRESHOLD=""

  assert_profile_for "Dell" 40 45
  assert_profile_for "User" 30 45
  assert_profile_for "User" 35 45
}

function test_either_trigger_alone_is_a_supported_configuration() {
  # Setting only one leaves it as the sole condition, which is the OR reading of
  # the original issue, reachable for anyone who wants it
  HIGH_INLET_TEMPERATURE_THRESHOLD=""
  LOW_INLET_TEMPERATURE_THRESHOLD=10
  LOW_CPU_TEMPERATURE_THRESHOLD=""
  assert_profile_for "LowTemperature" 5 90

  LOW_INLET_TEMPERATURE_THRESHOLD=""
  LOW_CPU_TEMPERATURE_THRESHOLD=35
  assert_profile_for "LowTemperature" 25 30
}

function test_a_reduced_speed_above_the_configured_one_is_refused_at_startup() {
  # The protection may only ever LOWER the fan speed. The comparison is against
  # DECIMAL_FAN_SPEED, so it is only meaningful once FAN_SPEED has been resolved :
  # an empty right operand makes bash's "-gt" return 2, which reads as "not
  # greater" and lets a raised speed through in silence. That is the shape of
  # #149, and it is why the order of the two blocks in the entrypoint matters
  export FAN_SPEED=5
  export LOW_INLET_TEMPERATURE_THRESHOLD=10
  export LOW_TEMPERATURE_FAN_SPEED=50
  simulate_server "PowerEdge R740" --cpus 2

  local OUTPUT
  OUTPUT=$(run_controller "Invalid configuration" 2>&1 || true)

  assert_contains "$OUTPUT" "LOW_TEMPERATURE_FAN_SPEED" \
    "a reduced speed above FAN_SPEED must stop the container"
  assert_not_contains "$OUTPUT" "integer expression expected" \
    "and the comparison must have both its operands, not fail its way past the guard"
}

function test_a_reduced_speed_below_the_configured_one_is_accepted() {
  export FAN_SPEED=30
  export LOW_INLET_TEMPERATURE_THRESHOLD=10
  export LOW_TEMPERATURE_FAN_SPEED=10
  simulate_server "PowerEdge R740" --cpus 2 --cpu-temperatures "40 40" --inlet 25

  local -r OUTPUT=$(run_controller)

  assert_not_contains "$OUTPUT" "Invalid configuration" \
    "a genuinely reduced speed is the supported configuration"
}
