#!/bin/bash

# Server typologies : single socket (R210, R240, R6515...), dual socket (R720,
# R740, R760...) and quad socket (R910, R930, R940, R960...), with or without an
# exhaust sensor, with an empty second socket, with an unreadable reading.
#
# The table is printed column by column, so the number of detected CPUs decides
# both the header and every following line : a miscounted CPU shifts the whole
# table and makes the logs unreadable.

function test_a_single_cpu_server_reports_one_cpu() {
  export MOCK_IPMITOOL_SDR_OUTPUT
  MOCK_IPMITOOL_SDR_OUTPUT=$(make_sdr_output --cpus 1 --cpu-temperatures "44")

  retrieve_temperatures true true

  assert_equals "1" "$NUMBER_OF_DETECTED_CPUS"
  assert_equals "44" "$CPU1_TEMPERATURE"
  assert_equals "44" "$CPUS_TEMPERATURES"
  assert_empty "$CPU2_TEMPERATURE" "a single socket server has no CPU 2 reading"
}

function test_a_dual_cpu_server_reports_two_cpus() {
  export MOCK_IPMITOOL_SDR_OUTPUT
  MOCK_IPMITOOL_SDR_OUTPUT=$(make_sdr_output --cpus 2 --cpu-temperatures "44 46")

  retrieve_temperatures true true

  assert_equals "2" "$NUMBER_OF_DETECTED_CPUS"
  assert_equals "44" "$CPU1_TEMPERATURE"
  assert_equals "46" "$CPU2_TEMPERATURE"
  assert_equals "44;46" "$CPUS_TEMPERATURES"
}

function test_a_quad_cpu_server_only_reports_its_first_two_cpus() {
  # Documents the current behavior : an R930 or an R940 exposes four processor
  # entities but only CPU 1 and CPU 2 are read, and only those two drive the fans
  export MOCK_IPMITOOL_SDR_OUTPUT
  MOCK_IPMITOOL_SDR_OUTPUT=$(make_sdr_output --cpus 4 --cpu-temperatures "41 40 39 38" --cpu-sensor-id-base 9)

  retrieve_temperatures true true

  assert_equals "2" "$NUMBER_OF_DETECTED_CPUS" "CPU 3 and CPU 4 are not monitored"
  assert_equals "41;40" "$CPUS_TEMPERATURES"
}

function test_an_empty_second_socket_is_not_counted_as_a_detected_cpu() {
  # A dual socket server sold with one CPU lists the second sensor as disabled :
  # counting it would add a column the header does not have
  export MOCK_IPMITOOL_SDR_OUTPUT
  MOCK_IPMITOOL_SDR_OUTPUT=$(make_sdr_output --cpus 2 --cpu-temperatures "44" --cpu2-disabled)

  retrieve_temperatures true true

  assert_equals "1" "$NUMBER_OF_DETECTED_CPUS"
  assert_equals "44" "$CPUS_TEMPERATURES"
}

function test_the_sensors_known_to_be_absent_are_replaced_by_placeholders() {
  export MOCK_IPMITOOL_SDR_OUTPUT
  MOCK_IPMITOOL_SDR_OUTPUT=$(make_sdr_output --cpus 2 --cpu-temperatures "44 46" --exhaust 36)

  # Once the controller has detected that a sensor is missing, it stops reading
  # it, and the placeholder must not be counted as a detected CPU
  retrieve_temperatures true false
  assert_equals "-" "$CPU2_TEMPERATURE"
  assert_equals "1" "$NUMBER_OF_DETECTED_CPUS"
  assert_equals "44" "$CPUS_TEMPERATURES"

  retrieve_temperatures false true
  assert_equals "-" "$EXHAUST_TEMPERATURE"
  assert_equals "2" "$NUMBER_OF_DETECTED_CPUS" "a missing exhaust sensor must not change the CPU count"
}

function test_a_server_without_an_inlet_or_exhaust_sensor_reports_no_reading() {
  export MOCK_IPMITOOL_SDR_OUTPUT
  MOCK_IPMITOOL_SDR_OUTPUT=$(make_sdr_output --cpus 2 --no-inlet --no-exhaust)

  retrieve_temperatures true true

  assert_empty "$INLET_TEMPERATURE"
  assert_empty "$EXHAUST_TEMPERATURE" "an empty exhaust reading is how the controller detects the missing sensor"
  assert_equals "2" "$NUMBER_OF_DETECTED_CPUS" "missing chassis sensors must not affect the CPU count"
}

function test_an_unreadable_cpu1_temperature_keeps_its_column() {
  # CPU 1 unreadable : the reading itself stays empty so that the overheating
  # check can fail safe on it, but the printed column falls back on a placeholder
  export MOCK_IPMITOOL_SDR_OUTPUT
  MOCK_IPMITOOL_SDR_OUTPUT=$(make_sdr_output --cpus 2 --cpu2-disabled)
  MOCK_IPMITOOL_SDR_OUTPUT=$(printf '%s\n' "$MOCK_IPMITOOL_SDR_OUTPUT" | grep -v ' 3\.1 ')

  retrieve_temperatures true true

  assert_empty "$CPU1_TEMPERATURE" "the raw reading stays empty for the overheating check"
  assert_equals "-" "$CPUS_TEMPERATURES" "the printed value falls back on a placeholder"
  assert_equals "1" "$NUMBER_OF_DETECTED_CPUS"
}

function test_the_internal_functions_reject_a_wrong_number_of_parameters() {
  local RETRIEVE_OUTPUT BUILD_HEADER_OUTPUT

  RETRIEVE_OUTPUT=$(retrieve_temperatures true 2>&1)
  local -r RETRIEVE_EXIT_CODE=$?
  BUILD_HEADER_OUTPUT=$(build_header 2>&1)
  local -r BUILD_HEADER_EXIT_CODE=$?

  assert_equals 1 "$RETRIEVE_EXIT_CODE"
  assert_contains "$RETRIEVE_OUTPUT" "Illegal number of parameters"
  assert_equals 1 "$BUILD_HEADER_EXIT_CODE"
  assert_contains "$BUILD_HEADER_OUTPUT" "requires an argument"
}

function test_the_header_of_a_single_cpu_server() {
  local -r EXPECTED_HEADER="                     ---- Temperatures ---
    Date & time      Inlet  CPU 1  Exhaust          Active fan speed profile          Third-party PCIe card Dell default cooling response  Comment"

  assert_equals "$EXPECTED_HEADER" "$(build_header 1)"
}

function test_the_header_of_a_dual_cpu_server() {
  local -r EXPECTED_HEADER="                     ------- Temperatures -------
    Date & time      Inlet  CPU 1  CPU 2  Exhaust          Active fan speed profile          Third-party PCIe card Dell default cooling response  Comment"

  assert_equals "$EXPECTED_HEADER" "$(build_header 2)"
}

function test_the_header_of_a_quad_cpu_server() {
  local -r EXPECTED_HEADER="                     -------------- Temperatures --------------
    Date & time      Inlet  CPU 1  CPU 2  CPU 3  CPU 4  Exhaust          Active fan speed profile          Third-party PCIe card Dell default cooling response  Comment"

  assert_equals "$EXPECTED_HEADER" "$(build_header 4)"
}

function test_the_header_grows_with_the_cpu_count() {
  local CPU_COUNT
  for CPU_COUNT in 1 2 3 4 8; do
    local TITLE_LINE COLUMNS_LINE
    TITLE_LINE=$(build_header "$CPU_COUNT" | head -1)
    COLUMNS_LINE=$(build_header "$CPU_COUNT" | tail -1)

    # The "Temperatures" title is framed by a comparable number of dashes on
    # each side (they can differ by one, the frame has no half dash to give)
    local DASHES_BEFORE="${TITLE_LINE%% Temperatures *}"
    DASHES_BEFORE="${DASHES_BEFORE##*[[:space:]]}"
    local DASHES_AFTER="${TITLE_LINE##* Temperatures }"
    local DIFFERENCE=$((${#DASHES_BEFORE} - ${#DASHES_AFTER}))
    if [ "${DIFFERENCE#-}" -le 1 ]; then
      pass
    else
      fail "the dashes are not balanced around the title for $CPU_COUNT CPUs" \
        "before: ${#DASHES_BEFORE}" "after:  ${#DASHES_AFTER}"
    fi

    assert_contains "$COLUMNS_LINE" "CPU $CPU_COUNT " "the header should have a column for CPU $CPU_COUNT"
    assert_equals "$CPU_COUNT" "$(grep -o 'CPU [0-9]' <<< "$COLUMNS_LINE" | wc -l | tr -d ' ')" \
      "the header of a $CPU_COUNT CPU server should have exactly $CPU_COUNT CPU columns"
  done
}

function test_the_temperature_line_has_one_column_per_detected_cpu() {
  local -r SINGLE_CPU_LINE=$(print_temperature_array_line "23" "44" "36" "User static fan control profile (5%)" "Enabled" " -")
  local -r DUAL_CPU_LINE=$(print_temperature_array_line "23" "44;46" "36" "User static fan control profile (5%)" "Enabled" " -")
  local -r QUAD_CPU_LINE=$(print_temperature_array_line "23" "44;46;45;47" "36" "User static fan control profile (5%)" "Enabled" " -")

  assert_equals "3" "$(grep -o '°C' <<< "$SINGLE_CPU_LINE" | wc -l | tr -d ' ')" "inlet, CPU 1 and exhaust"
  assert_equals "4" "$(grep -o '°C' <<< "$DUAL_CPU_LINE" | wc -l | tr -d ' ')" "inlet, CPU 1, CPU 2 and exhaust"
  assert_equals "6" "$(grep -o '°C' <<< "$QUAD_CPU_LINE" | wc -l | tr -d ' ')" "inlet, four CPUs and exhaust"

  assert_matches "$DUAL_CPU_LINE" "^$CONTROLLER_TIMESTAMP_PATTERN  " "every line starts with its timestamp"
  assert_contains "$DUAL_CPU_LINE" "User static fan control profile (5%)"
}

function test_missing_readings_are_printed_without_shifting_the_columns() {
  # A server with no exhaust sensor and an unreadable CPU 2 must still print a
  # line of the same width as a complete one, or the table becomes unreadable
  local -r COMPLETE_LINE=$(print_temperature_array_line "23" "44;46" "36" "Dell default dynamic fan control profile" "Enabled" " -")
  local -r INCOMPLETE_LINE=$(print_temperature_array_line "" "-;-" "-" "Dell default dynamic fan control profile" "Enabled" " -")

  assert_equals "${#COMPLETE_LINE}" "${#INCOMPLETE_LINE}" "both lines should have the same width"
  assert_contains "$INCOMPLETE_LINE" "  -°C" "a missing reading is printed as a placeholder"
}
