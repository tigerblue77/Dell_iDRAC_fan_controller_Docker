#!/bin/bash

# Server typologies : single socket (R210, R240, R6515...), dual socket (R720,
# R740, R760...) and quad socket (R910, R930, R940, R960...), with or without an
# exhaust sensor, with an empty second socket, with an unreadable reading.
#
# The table is printed column by column, so the number of detected CPUs decides
# both the header and every following line : a miscounted CPU shifts the whole
# table and makes the logs unreadable.
#
# The CPUs are detected in their own step, from the same sdr output the readings
# come from, so a test drives the pair the way the controller does.

function detect_then_retrieve_temperatures() {
  local -r IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT="${1:-true}"

  detect_CPU_temperature_sensors "$(retrieve_sdr_temperature_data)"
  retrieve_temperatures "$IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT"
}

function test_a_single_cpu_server_reports_one_cpu() {
  export MOCK_IPMITOOL_SDR_OUTPUT
  MOCK_IPMITOOL_SDR_OUTPUT=$(make_sdr_output --cpus 1 --cpu-temperatures "44")

  detect_then_retrieve_temperatures

  assert_equals "1" "${#DETECTED_CPU_ENTITY_IDS[@]}"
  assert_equals "3.1" "${DETECTED_CPU_ENTITY_IDS[*]}"
  assert_equals "44" "${DETECTED_CPU_TEMPERATURES[0]}"
  assert_equals "44" "$CPUS_TEMPERATURES"
}

function test_a_dual_cpu_server_reports_two_cpus() {
  export MOCK_IPMITOOL_SDR_OUTPUT
  MOCK_IPMITOOL_SDR_OUTPUT=$(make_sdr_output --cpus 2 --cpu-temperatures "44 46")

  detect_then_retrieve_temperatures

  assert_equals "2" "${#DETECTED_CPU_ENTITY_IDS[@]}"
  assert_equals "44" "${DETECTED_CPU_TEMPERATURES[0]}"
  assert_equals "46" "${DETECTED_CPU_TEMPERATURES[1]}"
  assert_equals "44;46" "$CPUS_TEMPERATURES"
}

function test_a_quad_cpu_server_reports_its_four_cpus() {
  # An R930 or an R940 exposes four processor entities, and all four are read and
  # compared to the threshold. Its CPU sensors carry two-digit hexadecimal IDs
  # ("09h"), which is what used to shift the parsing (issue #91)
  export MOCK_IPMITOOL_SDR_OUTPUT
  MOCK_IPMITOOL_SDR_OUTPUT=$(make_sdr_output --cpus 4 --cpu-temperatures "41 40 39 38" --cpu-sensor-id-base 9)

  detect_then_retrieve_temperatures

  assert_equals "4" "${#DETECTED_CPU_ENTITY_IDS[@]}" "CPU 3 and CPU 4 are monitored too"
  assert_equals "3.1 3.2 3.3 3.4" "${DETECTED_CPU_ENTITY_IDS[*]}"
  assert_equals "CPU 1 CPU 2 CPU 3 CPU 4" "${DETECTED_CPU_LABELS[*]}"
  assert_equals "41;40;39;38" "$CPUS_TEMPERATURES"
}

function test_a_quad_cpu_server_detects_its_cpus_whatever_the_order_they_come_in() {
  # The only real quad socket dump available (an R930, issue #91) lists entity
  # 3.4 first : the detection sorts on the entity instance, not on the sdr order
  export MOCK_IPMITOOL_SDR_OUTPUT
  MOCK_IPMITOOL_SDR_OUTPUT=$(make_sdr_output --cpus 4 --cpu-temperatures "41 40 39 38" | tac)

  detect_then_retrieve_temperatures

  assert_equals "3.1 3.2 3.3 3.4" "${DETECTED_CPU_ENTITY_IDS[*]}"
  assert_equals "41;40;39;38" "$CPUS_TEMPERATURES" "each reading stays with its own CPU"
}

function test_an_empty_second_socket_is_not_counted_as_a_detected_cpu() {
  # A dual socket server sold with one CPU lists the second sensor as disabled :
  # counting it would add a column the header does not have
  export MOCK_IPMITOOL_SDR_OUTPUT
  MOCK_IPMITOOL_SDR_OUTPUT=$(make_sdr_output --cpus 2 --cpu-temperatures "44" --cpu2-disabled)

  detect_then_retrieve_temperatures

  assert_equals "1" "${#DETECTED_CPU_ENTITY_IDS[@]}"
  assert_equals "44" "$CPUS_TEMPERATURES"
}

function test_a_gap_between_two_readable_sockets_does_not_truncate_the_list() {
  # IPMI only requires entity instances to be unique, not contiguous, and Dell
  # reports an unreadable socket as "Disabled" rather than omitting it. Stopping
  # at the first gap would leave the sockets past it unwatched
  export MOCK_IPMITOOL_SDR_OUTPUT
  MOCK_IPMITOOL_SDR_OUTPUT=$(make_sdr_output --cpus 4 --cpu-temperatures "41 40 39 38")
  MOCK_IPMITOOL_SDR_OUTPUT=$(printf '%s\n' "$MOCK_IPMITOOL_SDR_OUTPUT" | grep -v ' 3\.2 ')

  detect_then_retrieve_temperatures

  assert_equals "3.1 3.3 3.4" "${DETECTED_CPU_ENTITY_IDS[*]}"
  assert_equals "CPU 1 CPU 2 CPU 3" "${DETECTED_CPU_LABELS[*]}" "columns stay numbered from 1"
  assert_equals "41;39;38" "$CPUS_TEMPERATURES"
}

function test_the_sensors_known_to_be_absent_are_replaced_by_placeholders() {
  export MOCK_IPMITOOL_SDR_OUTPUT
  MOCK_IPMITOOL_SDR_OUTPUT=$(make_sdr_output --cpus 2 --cpu-temperatures "44 46" --exhaust 36)

  # Once the controller has detected that the exhaust sensor is missing, it stops
  # reading it and prints a placeholder in its place
  detect_then_retrieve_temperatures false

  assert_equals "-" "$EXHAUST_TEMPERATURE"
  assert_equals "2" "${#DETECTED_CPU_ENTITY_IDS[@]}" "a missing exhaust sensor must not change the CPU count"
  assert_equals "44;46" "$CPUS_TEMPERATURES"
}

function test_a_server_without_an_inlet_or_exhaust_sensor_reports_no_reading() {
  export MOCK_IPMITOOL_SDR_OUTPUT
  MOCK_IPMITOOL_SDR_OUTPUT=$(make_sdr_output --cpus 2 --no-inlet --no-exhaust)

  detect_then_retrieve_temperatures

  assert_empty "$INLET_TEMPERATURE"
  assert_empty "$EXHAUST_TEMPERATURE" "an empty exhaust reading is how the controller detects the missing sensor"
  assert_equals "2" "${#DETECTED_CPU_ENTITY_IDS[@]}" "missing chassis sensors must not affect the CPU count"
}

function test_an_unreadable_cpu1_temperature_keeps_its_column() {
  # CPU 1 readable, CPU 2 detected then going silent : the reading itself stays
  # empty so that the overheating check can fail safe on it, but the printed
  # column falls back on a placeholder rather than disappearing
  export MOCK_IPMITOOL_SDR_OUTPUT
  MOCK_IPMITOOL_SDR_OUTPUT=$(make_sdr_output --cpus 2 --cpu-temperatures "44 46")

  detect_then_retrieve_temperatures
  assert_equals "2" "${#DETECTED_CPU_ENTITY_IDS[@]}"

  MOCK_IPMITOOL_SDR_OUTPUT=$(printf '%s\n' "$MOCK_IPMITOOL_SDR_OUTPUT" | grep -v ' 3\.2 ')
  retrieve_temperatures true

  assert_empty "${DETECTED_CPU_TEMPERATURES[1]}" "the raw reading stays empty for the overheating check"
  assert_equals "44;-" "$CPUS_TEMPERATURES" "the printed value falls back on a placeholder"
}

function test_the_internal_functions_reject_a_wrong_number_of_parameters() {
  local RETRIEVE_OUTPUT BUILD_HEADER_OUTPUT

  RETRIEVE_OUTPUT=$(retrieve_temperatures true true true 2>&1)
  local -r RETRIEVE_EXIT_CODE=$?
  BUILD_HEADER_OUTPUT=$(build_header 5 2>&1)
  local -r BUILD_HEADER_EXIT_CODE=$?

  assert_equals 1 "$RETRIEVE_EXIT_CODE"
  assert_contains "$RETRIEVE_OUTPUT" "Illegal number of parameters"
  assert_equals 1 "$BUILD_HEADER_EXIT_CODE"
  assert_contains "$BUILD_HEADER_OUTPUT" "requires a column content width and at least one CPU label"
}

function test_the_header_of_a_single_cpu_server() {
  local -r EXPECTED_HEADER="                     ---- Temperatures ---
    Date & time      Inlet  CPU 1  Exhaust          Active fan speed profile          Third-party PCIe card Dell default cooling response  Comment"

  assert_equals "$EXPECTED_HEADER" "$(build_header 5 "CPU 1")"
}

function test_the_header_of_a_dual_cpu_server() {
  local -r EXPECTED_HEADER="                     ------- Temperatures -------
    Date & time      Inlet  CPU 1  CPU 2  Exhaust          Active fan speed profile          Third-party PCIe card Dell default cooling response  Comment"

  assert_equals "$EXPECTED_HEADER" "$(build_header 5 "CPU 1" "CPU 2")"
}

function test_the_header_of_a_quad_cpu_server() {
  local -r EXPECTED_HEADER="                     -------------- Temperatures --------------
    Date & time      Inlet  CPU 1  CPU 2  CPU 3  CPU 4  Exhaust          Active fan speed profile          Third-party PCIe card Dell default cooling response  Comment"

  assert_equals "$EXPECTED_HEADER" "$(build_header 5 "CPU 1" "CPU 2" "CPU 3" "CPU 4")"
}

function test_the_header_grows_with_the_cpu_count() {
  local CPU_COUNT
  for CPU_COUNT in 1 2 3 4 8; do
    local -a CPU_LABELS=()
    local CPU_NUMBER
    for ((CPU_NUMBER = 1; CPU_NUMBER <= CPU_COUNT; CPU_NUMBER++)); do
      CPU_LABELS+=("CPU $CPU_NUMBER")
    done
    local COLUMN_WIDTH
    COLUMN_WIDTH=$(compute_CPU_column_content_width "${CPU_LABELS[@]}")

    local TITLE_LINE COLUMNS_LINE
    TITLE_LINE=$(build_header "$COLUMN_WIDTH" "${CPU_LABELS[@]}" | head -1)
    COLUMNS_LINE=$(build_header "$COLUMN_WIDTH" "${CPU_LABELS[@]}" | tail -1)

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
  local -r SINGLE_CPU_LINE=$(print_temperature_array_line 5 "23" "44" "36" "User static fan control profile (5%)" "Enabled" " -")
  local -r DUAL_CPU_LINE=$(print_temperature_array_line 5 "23" "44;46" "36" "User static fan control profile (5%)" "Enabled" " -")
  local -r QUAD_CPU_LINE=$(print_temperature_array_line 5 "23" "44;46;45;47" "36" "User static fan control profile (5%)" "Enabled" " -")

  assert_equals "3" "$(grep -o '°C' <<< "$SINGLE_CPU_LINE" | wc -l | tr -d ' ')" "inlet, CPU 1 and exhaust"
  assert_equals "4" "$(grep -o '°C' <<< "$DUAL_CPU_LINE" | wc -l | tr -d ' ')" "inlet, CPU 1, CPU 2 and exhaust"
  assert_equals "6" "$(grep -o '°C' <<< "$QUAD_CPU_LINE" | wc -l | tr -d ' ')" "inlet, four CPUs and exhaust"

  assert_matches "$DUAL_CPU_LINE" "^$CONTROLLER_TIMESTAMP_PATTERN  " "every line starts with its timestamp"
  assert_contains "$DUAL_CPU_LINE" "User static fan control profile (5%)"
}

function test_missing_readings_are_printed_without_shifting_the_columns() {
  # A server with no exhaust sensor and an unreadable CPU 2 must still print a
  # line of the same width as a complete one, or the table becomes unreadable
  local -r COMPLETE_LINE=$(print_temperature_array_line 5 "23" "44;46" "36" "Dell default dynamic fan control profile" "Enabled" " -")
  local -r INCOMPLETE_LINE=$(print_temperature_array_line 5 "" "-;-" "-" "Dell default dynamic fan control profile" "Enabled" " -")

  assert_equals "${#COMPLETE_LINE}" "${#INCOMPLETE_LINE}" "both lines should have the same width"
  assert_contains "$INCOMPLETE_LINE" "  -°C" "a missing reading is printed as a placeholder"
}

function test_a_cpu_showing_up_later_is_picked_up_and_monitored() {
  # Adding a CPU means powering the server off, which nobody stops the container
  # for : a CPU appearing must be adopted, or it would stay both invisible in the
  # table and, far worse, never compared to the threshold
  export MOCK_IPMITOOL_SDR_OUTPUT
  MOCK_IPMITOOL_SDR_OUTPUT=$(make_sdr_output --cpus 2 --cpu-temperatures "40 41")
  detect_then_retrieve_temperatures
  assert_equals "3.1 3.2" "${DETECTED_CPU_ENTITY_IDS[*]}"

  MOCK_IPMITOOL_SDR_OUTPUT=$(make_sdr_output --cpus 4 --cpu-temperatures "40 41 42 43")
  if refresh_CPU_temperature_sensors "$(retrieve_sdr_temperature_data)" 1000; then
    pass
  else
    fail "the two CPUs that showed up should have been reported as a change"
  fi
  assert_equals "3.1 3.2 3.3 3.4" "${DETECTED_CPU_ENTITY_IDS[*]}"
}

function test_a_cpu_going_silent_on_a_running_server_keeps_its_column() {
  # A CPU cannot physically leave a server that is running, so a sensor going
  # quiet there is a fault, not a missing socket. Dropping its column would
  # silently stop watching a CPU that is still installed
  export MOCK_IPMITOOL_SDR_OUTPUT
  MOCK_IPMITOOL_SDR_OUTPUT=$(make_sdr_output --cpus 4 --cpu-temperatures "40 41 42 43")
  detect_then_retrieve_temperatures
  IS_CPU_REMOVAL_ALLOWED=false

  MOCK_IPMITOOL_SDR_OUTPUT=$(make_sdr_output --cpus 2 --cpu-temperatures "40 41")
  local -r SDR_DATA=$(retrieve_sdr_temperature_data)

  local READING
  for ((READING = 1; READING <= CPU_REMOVAL_CONFIRMING_READINGS + 2; READING++)); do
    refresh_CPU_temperature_sensors "$SDR_DATA"
  done
  retrieve_temperatures true "$SDR_DATA"

  assert_equals "3.1 3.2 3.3 3.4" "${DETECTED_CPU_ENTITY_IDS[*]}" "no power cycle, no removal"
  assert_equals "40;41;-;-" "$CPUS_TEMPERATURES" "the silent CPUs keep their column, reading as a placeholder"

  CPU_TEMPERATURE_THRESHOLD=50
  if is_any_CPU_overheating; then
    pass
  else
    fail "an unreadable CPU must keep failing safe to Dell's profile"
  fi
}

function test_a_cpu_removed_across_a_power_cycle_leaves_once_enough_readings_agree() {
  # Powering the server off is the only way its CPUs can change, so that is the
  # only moment one may leave the set -- and a socket can still be slow to become
  # readable during POST, hence the confirmation by a second identical reading
  export MOCK_IPMITOOL_SDR_OUTPUT
  MOCK_IPMITOOL_SDR_OUTPUT=$(make_sdr_output --cpus 4 --cpu-temperatures "40 41 42 43")
  detect_then_retrieve_temperatures

  # The server has just been powered back on with two CPUs removed
  IS_CPU_REMOVAL_ALLOWED=true
  PENDING_CPU_REMOVAL_SIGNATURE=""
  MOCK_IPMITOOL_SDR_OUTPUT=$(make_sdr_output --cpus 2 --cpu-temperatures "40 41")
  local -r SDR_DATA=$(retrieve_sdr_temperature_data)

  local READING
  for ((READING = 1; READING < CPU_REMOVAL_CONFIRMING_READINGS; READING++)); do
    refresh_CPU_temperature_sensors "$SDR_DATA"
    assert_equals "3.1 3.2 3.3 3.4" "${DETECTED_CPU_ENTITY_IDS[*]}" \
      "reading $READING of $CPU_REMOVAL_CONFIRMING_READINGS is not enough to conclude"
  done

  refresh_CPU_temperature_sensors "$SDR_DATA"
  assert_equals "3.1 3.2" "${DETECTED_CPU_ENTITY_IDS[*]}" "the last agreeing reading confirms it"
  assert_equals "CPU 1 CPU 2" "${DETECTED_CPU_LABELS[*]}"
}

function test_a_socket_slow_to_become_readable_after_a_reboot_keeps_its_column() {
  # The reason the removal needs confirming : right after POST, a populated
  # socket can read "Disabled" on one cycle and report its temperature on the
  # next. Concluding on the first reading would drop a CPU that is still there
  export MOCK_IPMITOOL_SDR_OUTPUT
  MOCK_IPMITOOL_SDR_OUTPUT=$(make_sdr_output --cpus 4 --cpu-temperatures "40 41 42 43")
  detect_then_retrieve_temperatures

  IS_CPU_REMOVAL_ALLOWED=true
  PENDING_CPU_REMOVAL_SIGNATURE=""

  # First readings after the reboot : CPU 3 and CPU 4 not readable yet
  MOCK_IPMITOOL_SDR_OUTPUT=$(make_sdr_output --cpus 2 --cpu-temperatures "40 41")
  refresh_CPU_temperature_sensors "$(retrieve_sdr_temperature_data)"
  refresh_CPU_temperature_sensors "$(retrieve_sdr_temperature_data)"
  assert_equals "3.1 3.2 3.3 3.4" "${DETECTED_CPU_ENTITY_IDS[*]}"

  # They show up on the next one, and the window closes with nothing removed
  MOCK_IPMITOOL_SDR_OUTPUT=$(make_sdr_output --cpus 4 --cpu-temperatures "40 41 42 43")
  refresh_CPU_temperature_sensors "$(retrieve_sdr_temperature_data)"
  assert_equals "3.1 3.2 3.3 3.4" "${DETECTED_CPU_ENTITY_IDS[*]}" "every CPU is back, none was dropped"
  assert_equals "false" "$IS_CPU_REMOVAL_ALLOWED" "the server came back complete, nothing left to remove"
}


function test_two_sensors_sharing_an_entity_get_a_single_column() {
  # retrieve_temperature_by_entity_id() stops at its first match, so a duplicated
  # entity would otherwise get two columns both showing the same reading
  local -r SDR_DATA="$(make_sdr_line "Temp" "0Eh" "ok" "3.1" "40 degrees C")
$(make_sdr_line "Temp" "0Fh" "ok" "3.1" "41 degrees C")
$(make_sdr_line "Temp" "10h" "ok" "3.2" "42 degrees C")"

  detect_CPU_temperature_sensors "$SDR_DATA"

  assert_equals "3.1 3.2" "${DETECTED_CPU_ENTITY_IDS[*]}" "the repeated entity is counted once"
  assert_equals "CPU 1 CPU 2" "${DETECTED_CPU_LABELS[*]}"
}

function test_a_tenth_processor_entity_sorts_after_the_second_one() {
  # A lexicographic sort puts 3.10 between 3.1 and 3.2, which would label the
  # sockets in an order that doesn't match the entities they are read from
  local -r SDR_DATA="$(make_sdr_line "Temp" "20h" "ok" "3.10" "43 degrees C")
$(make_sdr_line "Temp" "0Eh" "ok" "3.1" "40 degrees C")
$(make_sdr_line "Temp" "0Fh" "ok" "3.2" "41 degrees C")"

  detect_CPU_temperature_sensors "$SDR_DATA"

  assert_equals "3.1 3.2 3.10" "${DETECTED_CPU_ENTITY_IDS[*]}" "instances are sorted as numbers"
  assert_equals "CPU 1 CPU 2 CPU 3" "${DETECTED_CPU_LABELS[*]}" "columns stay numbered from 1"
}

function test_a_non_processor_entity_is_not_taken_for_a_cpu() {
  # The entity is matched anchored : "13.1" and "30.1" both contain "3.1" but
  # neither is entity 3, and counting them would add columns for heat sources
  # that don't exist
  local -r SDR_DATA="$(make_sdr_line "Temp" "0Eh" "ok" "3.1" "40 degrees C")
$(make_sdr_line "Temp" "11h" "ok" "13.1" "44 degrees C")
$(make_sdr_line "Temp" "12h" "ok" "30.1" "45 degrees C")"

  detect_CPU_temperature_sensors "$SDR_DATA"

  assert_equals "3.1" "${DETECTED_CPU_ENTITY_IDS[*]}" "only entity 3 is a processor"
  assert_equals "CPU 1" "${DETECTED_CPU_LABELS[*]}"
}

function test_every_cpu_going_silent_at_once_never_empties_the_table() {
  # Every socket falling silent together is an IPMI or host problem, not four
  # CPUs being unplugged at the same instant. Emptying the table would leave
  # is_any_CPU_overheating() with nothing to fail safe on
  export MOCK_IPMITOOL_SDR_OUTPUT
  MOCK_IPMITOOL_SDR_OUTPUT=$(make_sdr_output --cpus 4 --cpu-temperatures "40 41 42 43")
  detect_then_retrieve_temperatures

  IS_CPU_REMOVAL_ALLOWED=true
  PENDING_CPU_REMOVAL_SIGNATURE=""

  local READING
  for ((READING = 1; READING <= CPU_REMOVAL_CONFIRMING_READINGS + 2; READING++)); do
    refresh_CPU_temperature_sensors ""
    assert_equals "3.1 3.2 3.3 3.4" "${DETECTED_CPU_ENTITY_IDS[*]}" \
      "reading $READING left the table intact"
  done
}
