#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

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
  retrieve_temperatures

  assert_equals "-40" "${DETECTED_CPU_TEMPERATURES[0]}"
  assert_equals "-5" "${DETECTED_CPU_TEMPERATURES[1]}"
  assert_equals "-3" "$INLET_TEMPERATURE"
  assert_equals "-40;-5" "$CPUS_TEMPERATURES"
}

function test_the_intake_sensor_is_found_under_its_eleventh_generation_name() {
  # iDRAC6 (11G : R610, R710, R510, T610...) calls the chassis intake "Ambient Temp". "Inlet Temp"
  # only exists from 12G on, so looking for that name alone left the intake column showing "-" on
  # every 11G server -- all of which the catalogue lists as supported
  export MOCK_IPMITOOL_SDR_OUTPUT
  MOCK_IPMITOOL_SDR_OUTPUT=$(make_sdr_output --cpus 2 --eleventh-generation-sensor-names --inlet 21)

  retrieve_temperatures

  assert_equals "21" "$INLET_TEMPERATURE" "an 11G intake reading must be found under the name iDRAC6 gives it"
}

function test_the_system_board_sensor_is_never_reported_as_the_exhaust() {
  # 11G reports "Planar Temp" on entity 7.1, the same entity the intake uses, and it is the only
  # other temperature the chassis exposes -- which makes it the obvious thing to mistake for an
  # exhaust reading. It is the system board's own temperature, not the air leaving the chassis, so
  # the empty value the display layer renders as "-" is the honest answer here
  export MOCK_IPMITOOL_SDR_OUTPUT
  MOCK_IPMITOOL_SDR_OUTPUT=$(make_sdr_output --cpus 2 --eleventh-generation-sensor-names --inlet 21)

  retrieve_temperatures

  assert_empty "$EXHAUST_TEMPERATURE" "11G has no exhaust sensor, and its system board sensor is not one"
  assert_not_equals "36" "$INLET_TEMPERATURE" "the system board reading must not answer for the intake either"
}

function test_the_twelfth_generation_intake_still_wins_over_the_fallback() {
  # The fallback must not become the answer on a server that has both names -- the intake column
  # has to keep showing the sensor Dell means by "Inlet" wherever one exists
  local -r SDR_DATA=$(printf '%s\n%s\n' \
    "$(make_sdr_line "Inlet Temp" "04h" "ok" "7.1" "23 degrees C")" \
    "$(make_sdr_line "Ambient Temp" "0Eh" "ok" "7.1" "18 degrees C")")

  export MOCK_IPMITOOL_SDR_OUTPUT
  MOCK_IPMITOOL_SDR_OUTPUT="$SDR_DATA"

  retrieve_temperatures

  assert_equals "23" "$INLET_TEMPERATURE" "\"Inlet Temp\" is what Dell means by the intake when it exists"
}

function test_a_power_supply_intake_never_answers_for_the_chassis_intake() {
  # The name is matched at the start of the line for this reason (issue #231), and the 11G fallback
  # must not reopen the hole : 11G reports two power supply sensors of its own on entity 10.x
  local -r SDR_DATA=$(printf '%s\n%s\n' \
    "$(make_sdr_line "PSU1 Inlet Temp" "68h" "ok" "10.1" "29 degrees C")" \
    "$(make_sdr_line "PSU2 Inlet Temp" "69h" "ok" "10.2" "30 degrees C")")

  export MOCK_IPMITOOL_SDR_OUTPUT
  MOCK_IPMITOOL_SDR_OUTPUT="$SDR_DATA"

  retrieve_temperatures

  assert_empty "$INLET_TEMPERATURE" "a power supply's own intake is not the chassis air intake"
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

function test_a_power_supplys_own_intake_does_not_answer_for_the_chassis_one() {
  # Most servers with redundant power supplies report "PSU1 Inlet Temp" and
  # "PSU2 Inlet Temp" alongside the chassis "Inlet Temp". All three contain
  # "Inlet", so a match anywhere on the line let a power supply's own intake --
  # several degrees hotter, sitting downstream of its own losses -- be displayed
  # as the server's air intake (issue #231).
  #
  # This test used to assert the opposite. It was written while building the
  # suite, took the behaviour for intentional because the comment above it said
  # "on the unexpected event of several sensors matching", and pinned a defect
  # instead of reporting it
  local -r SDR_DATA=$(make_sdr_output --inlet 21 --exhaust 36 --with-extra-sensors)

  assert_equals "21" "$(retrieve_temperature_by_sensor_name "$SDR_DATA" "Inlet")" \
    "the chassis air intake is what the Inlet column is about"
  assert_equals "36" "$(retrieve_temperature_by_sensor_name "$SDR_DATA" "Exhaust")" \
    "the exhaust sensor is unaffected, but goes through the same matching rule"
}
