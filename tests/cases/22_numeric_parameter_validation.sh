#!/bin/bash

# FAN_SPEED and CPU_TEMPERATURE_THRESHOLD, the two parameters that reach an
# ipmitool command and an arithmetic comparison as unchecked text. Neither fails
# visibly when malformed : FAN_SPEED goes through printf's base detection and
# converts to 0x00, the documented Dell command for 0% fan duty, while a
# non-integer threshold makes "-gt" return 2, which every caller reads as "not
# overheating". Both failures leave the container reporting business as usual,
# which is why they are refused before the first IPMI command rather than
# reported once running.

# The validators answer by stopping the controller, so the call has to happen in
# the subshell a command substitution creates : the exit inside
# print_configuration_error_and_exit would otherwise take the test runner down
function assert_fan_speed_is_refused() {
  local -r VALUE="$1"
  local -r MESSAGE="${2:-\"$VALUE\" should stop the controller}"

  local OUTPUT
  OUTPUT=$(validate_fan_speed_parameter "FAN_SPEED" "$VALUE" 2>&1)
  local -r EXIT_CODE=$?

  assert_equals 1 "$EXIT_CODE" "$MESSAGE"
  assert_contains "$OUTPUT" "FAN_SPEED" "the error should name the parameter at fault"
}

function assert_fan_speed_is_accepted() {
  local -r VALUE="$1"
  local -r MESSAGE="${2:-\"$VALUE\" is a usable fan speed and should be accepted}"

  local OUTPUT
  OUTPUT=$(validate_fan_speed_parameter "FAN_SPEED" "$VALUE" 2>&1)
  local -r EXIT_CODE=$?

  assert_equals 0 "$EXIT_CODE" "$MESSAGE"
  assert_empty "$OUTPUT" "accepting a value should print nothing"
}

function assert_threshold_is_refused() {
  local -r VALUE="$1"
  local -r MESSAGE="${2:-\"$VALUE\" should stop the controller}"

  local OUTPUT
  OUTPUT=$(validate_integer_parameter "CPU_TEMPERATURE_THRESHOLD" "$VALUE" -128 127 2>&1)
  local -r EXIT_CODE=$?

  assert_equals 1 "$EXIT_CODE" "$MESSAGE"
  assert_contains "$OUTPUT" "CPU_TEMPERATURE_THRESHOLD" "the error should name the parameter at fault"
}

function assert_threshold_is_accepted() {
  local -r VALUE="$1"
  local -r MESSAGE="${2:-\"$VALUE\" is a usable threshold and should be accepted}"

  local OUTPUT
  OUTPUT=$(validate_integer_parameter "CPU_TEMPERATURE_THRESHOLD" "$VALUE" -128 127 2>&1)
  local -r EXIT_CODE=$?

  assert_equals 0 "$EXIT_CODE" "$MESSAGE"
  assert_empty "$OUTPUT" "accepting a value should print nothing"
}

function test_a_fan_speed_percentage_is_accepted() {
  local VALUE
  for VALUE in 0 5 50 99 100; do
    assert_fan_speed_is_accepted "$VALUE"
  done
}

function test_a_fan_speed_in_hexadecimal_is_accepted() {
  # Both notations are documented, 0x64 being 100%
  local VALUE
  for VALUE in 0x00 0x05 0x32 0x64 0X64 0x0A 0x0a; do
    assert_fan_speed_is_accepted "$VALUE"
  done
}

function test_a_padded_fan_speed_is_read_as_decimal_not_octal() {
  # The reason #148 was filed : "09" and "08" are invalid octal numbers, and
  # printf hands back 0 for both, which is the command for 0% fan duty. They are
  # the values a user naturally writes when lining up two-digit numbers in a
  # config file, so they are read as the decimal numbers meant rather than refused
  assert_fan_speed_is_accepted "09" "09% is 9%, not an invalid octal number"
  assert_fan_speed_is_accepted "08" "08% is 8%, not an invalid octal number"
  assert_fan_speed_is_accepted "00" "00% is 0%"
}

function test_a_fan_speed_that_is_not_a_number_stops_the_controller() {
  # Every one of these converts to 0x00 without the validation, stopping the fans
  # while the container keeps reporting the user's profile as applied
  local VALUE
  for VALUE in "" "abc" "5%" "0x" "0xzz" "-5" "5.5" " 50" "50 " "1e2"; do
    assert_fan_speed_is_refused "$VALUE"
  done
}

function test_a_fan_speed_above_one_hundred_percent_stops_the_controller() {
  # Never range-checked before : "200" converted to 0xc8 and was sent verbatim
  assert_fan_speed_is_refused "101" "101% is not a duty cycle"
  assert_fan_speed_is_refused "200" "200% used to be sent to the fans as 0xc8"
  assert_fan_speed_is_refused "0x65" "0x65 is 101%, one over the maximum"
  assert_fan_speed_is_refused "0xff" "0xff is 255%"
}

function test_the_fan_speed_error_tells_the_user_what_is_wrong_and_what_is_accepted() {
  local OUTPUT
  OUTPUT=$(validate_fan_speed_parameter "FAN_SPEED" "abc" 2>&1)

  assert_contains "$OUTPUT" "abc" "the error should quote the offending value"
  assert_contains "$OUTPUT" "0 to 100" "the error should say which range is accepted"
  assert_contains "$OUTPUT" "0x00 to 0x64" "the error should say the same in the other notation"

  OUTPUT=$(validate_fan_speed_parameter "FAN_SPEED" "200" 2>&1)

  assert_contains "$OUTPUT" "200%" "an out of range value should be reported as the percentage it is"
}

function test_a_threshold_inside_the_ipmi_sensor_range_is_accepted() {
  # IPMI reports temperatures as a signed byte, so the range is what a sensor can
  # actually report rather than what is plausible in a datacenter
  local VALUE
  for VALUE in 0 50 95 127 -128 -5; do
    assert_threshold_is_accepted "$VALUE"
  done
}

function test_a_padded_threshold_is_read_as_decimal_not_octal() {
  assert_threshold_is_accepted "09" "09°C is 9°C, not an invalid octal number"
  assert_threshold_is_accepted "070" "070°C is 70°C"
}

function test_a_threshold_that_is_not_an_integer_stops_the_controller() {
  # The reason #149 was filed : each of these makes "-gt" return 2, which reads as
  # "not overheating" and silently disables the safety fallback
  local VALUE
  for VALUE in "" "abc" "60C" "60°C" "50.5" "5 0" "1e2"; do
    assert_threshold_is_refused "$VALUE"
  done
}

function test_a_threshold_outside_the_ipmi_sensor_range_stops_the_controller() {
  # A threshold no sensor reading can ever cross is a fallback that never fires
  assert_threshold_is_refused "128" "128°C is one over what a signed byte reports"
  assert_threshold_is_refused "-129" "-129°C is one under what a signed byte reports"
  assert_threshold_is_refused "1000"
}

function test_the_threshold_error_tells_the_user_what_is_wrong_and_what_is_accepted() {
  local -r OUTPUT=$(validate_integer_parameter "CPU_TEMPERATURE_THRESHOLD" "60C" -128 127 2>&1)

  assert_contains "$OUTPUT" "60C" "the error should quote the offending value"
  assert_contains "$OUTPUT" "-128" "the error should say which range is accepted"
  assert_contains "$OUTPUT" "127" "the error should say which range is accepted"
}

function test_every_configuration_error_says_the_container_will_not_start() {
  # The block exists so the reason survives a "docker logs" scroll : refusing to
  # start is only useful if the user can tell why from the output alone
  local -r OUTPUT=$(validate_fan_speed_parameter "FAN_SPEED" "abc" 2>&1)

  assert_contains "$OUTPUT" "the container will not start" "the error should say what happened"
  assert_contains "$OUTPUT" "Parameter :" "the error should name the parameter on its own line"
  assert_contains "$OUTPUT" "Value     :" "the error should quote the value on its own line"
  assert_contains "$OUTPUT" "Expected  :" "the error should say what would be accepted"
  assert_contains "$OUTPUT" "docker-compose.yml" "the error should say where to fix it"
}

function test_the_controller_refuses_to_start_on_an_unusable_fan_speed() {
  simulate_server "PowerEdge R730xd" --cpus 2 --cpu-temperatures "42 44"
  export FAN_SPEED="abc"

  local OUTPUT
  OUTPUT=$(run_controller "will not start")
  local -r EXIT_CODE=$?

  assert_equals 1 "$EXIT_CODE" "an unusable fan speed should stop the controller"
  assert_contains "$OUTPUT" "FAN_SPEED"
  assert_not_contains "$OUTPUT" "User static fan control profile" \
    "the container must never report a profile it could not have applied"
  assert_empty "$(recorded_ipmitool_calls)" \
    "the speed must be validated before the first IPMI command, so a bad value costs no iDRAC session"
}

function test_the_controller_refuses_to_start_on_an_unusable_threshold() {
  simulate_server "PowerEdge R730xd" --cpus 2 --cpu-temperatures "42 44"
  export CPU_TEMPERATURE_THRESHOLD="60C"

  local OUTPUT
  OUTPUT=$(run_controller "will not start")
  local -r EXIT_CODE=$?

  assert_equals 1 "$EXIT_CODE" "an unusable threshold should stop the controller"
  assert_contains "$OUTPUT" "CPU_TEMPERATURE_THRESHOLD"
  assert_empty "$(recorded_ipmitool_calls)" \
    "the threshold must be validated before the first IPMI command"
}

function test_the_controller_starts_normally_on_a_hexadecimal_fan_speed() {
  simulate_server "PowerEdge R730xd" --cpus 2 --cpu-temperatures "42 44"
  export FAN_SPEED="0x32"

  local -r OUTPUT=$(run_controller)

  assert_contains "$OUTPUT" "Fan speed objective: 50%" \
    "a validated hexadecimal speed should still be logged as a percentage"
  assert_contains "$OUTPUT" "User static fan control profile (50%)"
}

function test_the_controller_starts_normally_on_a_padded_fan_speed() {
  # The end to end version of #148 : "09" used to stop the fans and report the
  # user's profile as applied every cycle
  simulate_server "PowerEdge R730xd" --cpus 2 --cpu-temperatures "42 44"
  export FAN_SPEED="09"

  local -r OUTPUT=$(run_controller)

  assert_contains "$OUTPUT" "Fan speed objective: 9%" "09 is 9%, not 0%"
  assert_equals "0" "$(count_ipmitool_calls_matching "raw 0x30 0x30 0x02 0xff 0x00")" \
    "the fans must never be commanded to 0% duty by a padded value"
}
