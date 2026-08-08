#!/bin/bash

# Parsing of "ipmitool sdr type temperature". This is where the generation of the
# server used to leak into the code : sensor hexadecimal IDs, sensor ordering and
# reading widths all vary from one PowerEdge generation to the next, so every
# reading is located by its IPMI entity ID (or by its name for inlet and exhaust,
# which share entity 7.1) and extracted from the reading column only.

function test_a_temperature_is_read_from_a_standard_sensor_line() {
  local -r SDR_LINE=$(make_sdr_line "Temp" "0Eh" "ok" "3.1" "45 degrees C")

  assert_equals "45" "$(extract_temperature_from_sdr_line "$SDR_LINE")"
}

function test_a_single_digit_temperature_is_read() {
  # A cold server idling in a cold room : "9 degrees C" used to match nothing,
  # which callers could not tell apart from a missing sensor
  local -r SDR_LINE=$(make_sdr_line "Inlet Temp" "04h" "ok" "7.1" "9 degrees C")

  assert_equals "9" "$(extract_temperature_from_sdr_line "$SDR_LINE")"
}

function test_a_three_digit_temperature_is_read() {
  # An overheating CPU : "100 degrees C" used to be truncated to 10 degrees,
  # which would have kept the low user fan speed on a burning server
  local -r SDR_LINE=$(make_sdr_line "Temp" "0Eh" "ok" "3.1" "100 degrees C")

  assert_equals "100" "$(extract_temperature_from_sdr_line "$SDR_LINE")"
}

function test_a_sub_zero_temperature_keeps_its_sign() {
  # The reading whose sign used to be dropped, and the reason this file exists :
  # the pattern matched digits only, so "-40 degrees C" came back as "40". On the
  # inlet that only made a cold room look mild, but on a CPU it inverted a safety
  # decision -- a disconnected sensor reporting -40°C was read as +40°C and
  # tripped the overheating branch, ramping the fans on a machine that was cold.
  #
  # -40°C is what some iDRACs report for a disconnected CPU sensor, and -5°C is
  # in-spec: Dell rates the PowerEdge line down to it
  local SDR_LINE

  SDR_LINE=$(make_sdr_line "Temp" "0Eh" "ok" "3.1" "-40 degrees C")
  assert_equals "-40" "$(extract_temperature_from_sdr_line "$SDR_LINE")" \
    "a disconnected CPU sensor must not be read as +40°C"

  SDR_LINE=$(make_sdr_line "Inlet Temp" "04h" "ok" "7.1" "-5 degrees C")
  assert_equals "-5" "$(extract_temperature_from_sdr_line "$SDR_LINE")" \
    "a single digit sub-zero inlet must keep its sign too"

  SDR_LINE=$(make_sdr_line "Inlet Temp" "04h" "ok" "7.1" "-0 degrees C")
  assert_equals "-0" "$(extract_temperature_from_sdr_line "$SDR_LINE")" \
    "the reading is returned as the sensor worded it, sign included"
}

function test_the_sign_survives_the_whole_read_not_just_the_extraction() {
  # The extraction above is one of three places the sign can be lost: the sdr
  # line has to reach the caller through retrieve_temperatures() too
  export MOCK_IPMITOOL_SDR_OUTPUT
  MOCK_IPMITOOL_SDR_OUTPUT=$(make_sdr_output --cpus 2 --cpu-temperatures "-40 -5" --inlet -3 --exhaust 12)

  detect_CPU_temperature_sensors "$(retrieve_sdr_temperature_data)"
  retrieve_temperatures true

  assert_equals "-40" "${DETECTED_CPU_TEMPERATURES[0]}"
  assert_equals "-5" "${DETECTED_CPU_TEMPERATURES[1]}"
  assert_equals "-3" "$INLET_TEMPERATURE"
  assert_equals "-40;-5" "$CPUS_TEMPERATURES"
}

function test_the_hexadecimal_sensor_id_is_not_mistaken_for_a_temperature() {
  # An R930 numbers its CPU sensors 09h, 0Ah... : the "09" used to be picked up
  # as a reading of its own (issue #91)
  local -r SDR_LINE=$(make_sdr_line "Temp" "09h" "ok" "3.1" "41 degrees C")

  assert_equals "41" "$(extract_temperature_from_sdr_line "$SDR_LINE")"
}

function test_a_sensor_line_without_a_reading_yields_no_temperature() {
  local -r DISABLED_SENSOR_LINE=$(make_sdr_line "Temp" "0Fh" "ns" "3.2" "Disabled")

  assert_empty "$(extract_temperature_from_sdr_line "$DISABLED_SENSOR_LINE")" "a disabled sensor has no reading"
  assert_empty "$(extract_temperature_from_sdr_line "")" "an empty line has no reading"
}

function test_each_cpu_is_located_by_its_ipmi_entity_id() {
  local -r SDR_DATA=$(make_sdr_output --cpus 2 --cpu-temperatures "42 47")

  assert_equals "42" "$(retrieve_temperature_by_entity_id "$SDR_DATA" "3.1")" "entity 3.1 is CPU 1"
  assert_equals "47" "$(retrieve_temperature_by_entity_id "$SDR_DATA" "3.2")" "entity 3.2 is CPU 2"
}

function test_the_four_cpus_of_a_quad_socket_server_are_located_by_their_entity_ids() {
  # R810, R910, R920, R930, R940, R860, R960... all report four processor entities
  local -r SDR_DATA=$(make_sdr_output --cpus 4 --cpu-temperatures "41 40 39 38" --cpu-sensor-id-base 9)

  assert_equals "41" "$(retrieve_temperature_by_entity_id "$SDR_DATA" "3.1")"
  assert_equals "40" "$(retrieve_temperature_by_entity_id "$SDR_DATA" "3.2")"
  assert_equals "39" "$(retrieve_temperature_by_entity_id "$SDR_DATA" "3.3")"
  assert_equals "38" "$(retrieve_temperature_by_entity_id "$SDR_DATA" "3.4")"
}

function test_an_entity_id_is_matched_exactly_and_not_by_prefix() {
  # A server with ten or more processor entities must not let 3.10 answer for 3.1
  local -r SDR_DATA="$(make_sdr_line "Temp" "20h" "ok" "3.10" "70 degrees C")
$(make_sdr_line "Temp" "0Eh" "ok" "3.1" "40 degrees C")"

  assert_equals "40" "$(retrieve_temperature_by_entity_id "$SDR_DATA" "3.1")"
  assert_equals "70" "$(retrieve_temperature_by_entity_id "$SDR_DATA" "3.10")"
}

function test_a_missing_or_disabled_sensor_yields_no_temperature() {
  local -r SINGLE_SOCKET_DATA=$(make_sdr_output --cpus 1)
  # Second socket physically empty : the sensor is listed but reports nothing
  local -r EMPTY_SOCKET_DATA=$(make_sdr_output --cpus 2 --cpu2-disabled)
  local -r NO_CHASSIS_SENSOR_DATA=$(make_sdr_output --no-inlet --no-exhaust)

  assert_empty "$(retrieve_temperature_by_entity_id "$SINGLE_SOCKET_DATA" "3.2")" "a single socket server has no entity 3.2"
  assert_empty "$(retrieve_temperature_by_entity_id "" "3.1")" "no data means no reading"
  assert_not_empty "$(retrieve_temperature_by_entity_id "$EMPTY_SOCKET_DATA" "3.1")"
  assert_empty "$(retrieve_temperature_by_entity_id "$EMPTY_SOCKET_DATA" "3.2")" "a disabled sensor has no reading"
  assert_empty "$(retrieve_temperature_by_sensor_name "$NO_CHASSIS_SENSOR_DATA" "Inlet")"
  assert_empty "$(retrieve_temperature_by_sensor_name "$NO_CHASSIS_SENSOR_DATA" "Exhaust")"
}

function test_inlet_and_exhaust_are_told_apart_by_their_name() {
  # Both are reported as entity 7.1, so the entity ID cannot disambiguate them
  local -r SDR_DATA=$(make_sdr_output --inlet 21 --exhaust 36)

  assert_equals "21" "$(retrieve_temperature_by_sensor_name "$SDR_DATA" "Inlet")"
  assert_equals "36" "$(retrieve_temperature_by_sensor_name "$SDR_DATA" "Exhaust")"
}

function test_the_last_matching_sensor_wins_when_several_share_a_name() {
  # Big chassis report one inlet sensor per power supply on top of the main one
  local -r SDR_DATA=$(make_sdr_output --inlet 21 --exhaust 36 --with-extra-sensors)

  assert_equals "30" "$(retrieve_temperature_by_sensor_name "$SDR_DATA" "Inlet")" \
    "PSU2 Inlet Temp is the last line matching \"Inlet\""
}
