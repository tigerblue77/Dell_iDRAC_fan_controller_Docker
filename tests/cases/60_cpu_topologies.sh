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
  detect_CPU_temperature_sensors "$(retrieve_sdr_temperature_data)"
  retrieve_temperatures
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

function test_a_three_cpu_server_reports_its_three_cpus() {
  # Three populated sockets on a four socket board, which is a configuration a quad
  # socket server really ships in, and the count left as an open question in issue
  # #91. Every other socket count is walked by a test of its own ; this one was only
  # ever reached obliquely, through the sparse set a depopulated socket leaves
  export MOCK_IPMITOOL_SDR_OUTPUT
  MOCK_IPMITOOL_SDR_OUTPUT=$(make_sdr_output --cpus 3 --cpu-temperatures "41 40 39" --cpu-sensor-id-base 9)

  detect_then_retrieve_temperatures

  assert_equals "3" "${#DETECTED_CPU_ENTITY_IDS[@]}"
  assert_equals "3.1 3.2 3.3" "${DETECTED_CPU_ENTITY_IDS[*]}"
  assert_equals "CPU 1 CPU 2 CPU 3" "${DETECTED_CPU_LABELS[*]}"
  assert_equals "41;40;39" "$CPUS_TEMPERATURES"
  assert_equals "3 CPU temperature sensors detected (entities 3.1 3.2 3.3)" \
    "$(format_detected_CPU_temperature_sensors)"
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

function test_the_detection_excludes_an_unreadable_socket_on_its_own() {
  # The test above reaches the detection through retrieve_sdr_temperature_data(), which pipes ipmitool
  # through "grep degrees" : the depopulated socket is already gone by the time the detection sees the
  # rows, so what that test pins is the grep, not the guard the detection applies to the reading column
  # itself. Taking that guard out leaves the whole suite green while the function alone starts counting
  # sockets Dell reports as "Disabled" -- one column per empty socket, reading "-" forever, and the fans
  # handed to Dell for good by the reading that never comes.
  #
  # So it is called here with rows the grep has not been over, which is the only way the two defences are
  # held apart. "No Reading" is in there next to "Disabled" because an iDRAC uses both wordings
  local -r SDR_DATA="$(make_sdr_line "Temp" "0Eh" "ok" "3.1" "40 degrees C")
$(make_sdr_line "Temp" "0Fh" "ns" "3.2" "Disabled")
$(make_sdr_line "Temp" "10h" "ns" "3.3" "No Reading")
$(make_sdr_line "Temp" "11h" "ok" "3.4" "43 degrees C")"

  detect_CPU_temperature_sensors "$SDR_DATA"

  assert_equals "3.1 3.4" "${DETECTED_CPU_ENTITY_IDS[*]}" "only the sockets carrying a reading are counted"
  assert_equals "CPU 1 CPU 2" "${DETECTED_CPU_LABELS[*]}" "the columns stay numbered from 1"
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

function test_an_exhaust_sensor_missing_from_one_reading_comes_back_on_the_next() {
  # The exhaust sensor used to be probed once before the loop, and a single reading
  # without it settled the question for the container's whole life : one partial sdr
  # response, or chassis sensors not yet initialised while the CPU entities already
  # were, dropped the column until the container was restarted. It is read every
  # cycle now, so a sensor that answers a second later is picked back up
  export MOCK_IPMITOOL_SDR_OUTPUT
  MOCK_IPMITOOL_SDR_OUTPUT=$(make_sdr_output --cpus 2 --cpu-temperatures "44 46" --no-exhaust)

  detect_then_retrieve_temperatures

  assert_empty "$EXHAUST_TEMPERATURE" "a reading without the exhaust sensor yields no value"
  assert_equals "2" "${#DETECTED_CPU_ENTITY_IDS[@]}" "a missing exhaust sensor must not change the CPU count"
  assert_equals "44;46" "$CPUS_TEMPERATURES"

  MOCK_IPMITOOL_SDR_OUTPUT=$(make_sdr_output --cpus 2 --cpu-temperatures "44 46" --exhaust 36)

  retrieve_temperatures

  assert_equals "36" "$EXHAUST_TEMPERATURE" "the exhaust sensor must be read again rather than written off"
}

function test_a_server_genuinely_without_an_exhaust_sensor_keeps_its_column() {
  # Reading it every cycle must not cost the column on hardware that has none :
  # the display layer renders an unreadable value as the "-" placeholder, so the
  # line keeps the same shape it had when absence was a settled verdict
  export MOCK_IPMITOOL_SDR_OUTPUT
  MOCK_IPMITOOL_SDR_OUTPUT=$(make_sdr_output --cpus 2 --cpu-temperatures "44 46" --no-exhaust)

  detect_then_retrieve_temperatures

  assert_equals "  -" "$(format_temperature_for_display "$EXHAUST_TEMPERATURE")"
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
  retrieve_temperatures

  assert_empty "${DETECTED_CPU_TEMPERATURES[1]}" "the raw reading stays empty for the overheating check"
  assert_equals "44;-" "$CPUS_TEMPERATURES" "the printed value falls back on a placeholder"
}

function test_the_internal_functions_reject_a_wrong_number_of_parameters() {
  local RETRIEVE_OUTPUT BUILD_HEADER_OUTPUT

  RETRIEVE_OUTPUT=$(retrieve_temperatures extra1 extra2 2>&1)
  local -r RETRIEVE_EXIT_CODE=$?
  # No CPU label is a valid table : monitoring only mode runs on a server exposing
  # no processor entity, and its inlet and exhaust are still worth logging, so the
  # guard is on the width alone
  BUILD_HEADER_OUTPUT=$(build_header 2>&1)
  local -r BUILD_HEADER_EXIT_CODE=$?

  assert_equals 1 "$RETRIEVE_EXIT_CODE"
  assert_contains "$RETRIEVE_OUTPUT" "Illegal number of parameters"
  assert_equals 1 "$BUILD_HEADER_EXIT_CODE"
  assert_contains "$BUILD_HEADER_OUTPUT" "requires a column content width"
}

function test_the_header_of_a_server_exposing_no_processor_entity() {
  # Monitoring only mode on a chassis management controller : no CPU column at all.
  # The banner then spans "Inlet  Exhaust", which is exactly the width of its own
  # title, so it comes out with no dash on either side rather than mis-sized.
  # Written as two concatenated lines rather than one string spanning them, so that
  # the space the title is padded with on its right -- the one no dash replaces at
  # this width -- survives an editor trimming trailing whitespace
  local -r BANNER_LINE="                      Temperatures "
  local -r COLUMNS_LINE="    Date & time      Inlet  Exhaust                 Active fan speed profile                 Third-party PCIe card Dell default cooling response  Comment"

  assert_equals "$BANNER_LINE"$'\n'"$COLUMNS_LINE" "$(build_header 5)"
}

function test_the_temperature_line_of_a_server_exposing_no_processor_entity() {
  local -r LINE=$(print_temperature_array_line 5 "22" "" "31" "Dell default dynamic fan control profile" "Enabled" " -")

  assert_matches "$LINE" '22°C[[:space:]]+31°C' \
    "the inlet and the exhaust sit next to each other, with no empty CPU column between them"
}

function test_the_header_of_a_single_cpu_server() {
  local -r EXPECTED_HEADER="                     ---- Temperatures ---
    Date & time      Inlet  CPU 1  Exhaust                 Active fan speed profile                 Third-party PCIe card Dell default cooling response  Comment"

  assert_equals "$EXPECTED_HEADER" "$(build_header 5 "CPU 1")"
}

function test_the_header_of_a_dual_cpu_server() {
  local -r EXPECTED_HEADER="                     ------- Temperatures -------
    Date & time      Inlet  CPU 1  CPU 2  Exhaust                 Active fan speed profile                 Third-party PCIe card Dell default cooling response  Comment"

  assert_equals "$EXPECTED_HEADER" "$(build_header 5 "CPU 1" "CPU 2")"
}

function test_the_header_of_a_quad_cpu_server() {
  local -r EXPECTED_HEADER="                     -------------- Temperatures --------------
    Date & time      Inlet  CPU 1  CPU 2  CPU 3  CPU 4  Exhaust                 Active fan speed profile                 Third-party PCIe card Dell default cooling response  Comment"

  assert_equals "$EXPECTED_HEADER" "$(build_header 5 "CPU 1" "CPU 2" "CPU 3" "CPU 4")"
}

function test_the_header_of_a_three_cpu_server() {
  # The last socket count left without a header of its own, 1, 2 and 4 each having one.
  # An odd number of CPU columns lands the banner on an odd width, where the frame has
  # no half dash to give and the extra one goes left -- the convention
  # center_column_heading() follows too. Both even counts come out symmetrical, so that
  # rounding only ever shows on this table and on the single CPU one
  local -r EXPECTED_HEADER="                     ----------- Temperatures ----------
    Date & time      Inlet  CPU 1  CPU 2  CPU 3  Exhaust                 Active fan speed profile                 Third-party PCIe card Dell default cooling response  Comment"

  assert_equals "$EXPECTED_HEADER" "$(build_header 5 "CPU 1" "CPU 2" "CPU 3")"
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
  retrieve_temperatures "$SDR_DATA"

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

# The two right-hand columns of the table, whose widths the header and the rows have to agree on.
#
# The "°C" of a reading is one character on screen but two bytes in UTF-8, and the container runs in the
# POSIX locale (the Dockerfile sets no LANG), where "${#STRING}" counts bytes. A row therefore measures
# longer than it looks while a header, which carries no "°", does not. Every measurement below replaces the
# degree sign with a one-byte stand-in first, so what is compared is what the reader sees, in any locale
function display_width() {
  local -r LINE="${1//°/o}"
  printf '%s' "${#LINE}"
}

# Where the "Comment" column starts, which is the position everything to its left adds up to : it moves as
# soon as a value overflows the field reserved for it, and it is the last column, so nothing hides the shift
function comment_column_start_in_header() {
  local -r HEADER_COLUMNS_LINE="$1"
  printf '%s' "$(( $(display_width "$HEADER_COLUMNS_LINE") - ${#COMMENT_HEADING} ))"
}

readonly COMMENT_HEADING="Comment"
readonly COMMENT_MARKER="COMMENT-MARKER"

# 1-based position of the last character of the Nth occurrence of a token in a line, or -1 when the line
# holds fewer than N of them.
#
# awk rather than bash string surgery : the token this locates repeats along the line, and "${LINE%%token*}"
# only ever finds the first one. Positions are counted in characters, so the caller has to hand over a line
# the degree sign has already been taken out of -- see display_width() for why it would otherwise count two
function end_position_of_occurrence() {
  local -r LINE="$1"
  local -r TOKEN="$2"
  local -r OCCURRENCE="$3"

  awk -v line="$LINE" -v token="$TOKEN" -v occurrence="$OCCURRENCE" 'BEGIN {
    position = 0
    start = 1
    for (found = 1; found <= occurrence; found++) {
      offset = index(substr(line, start), token)
      if (offset == 0) { print -1; exit }
      position = start + offset - 1
      start = position + 1
    }
    print position + length(token) - 1
  }'
}

function assert_the_table_columns_line_up() {
  local -r IS_MONITORING_ONLY_MODE="$1"
  local -r FAN_CONTROL_PROFILE="$2"
  local -r COOLING_RESPONSE_STATUS="$3"

  export MONITORING_ONLY_MODE="$IS_MONITORING_ONLY_MODE"
  resolve_fan_control_profile_column_width

  local -r HEADER_COLUMNS_LINE=$(build_header 5 "CPU 1" "CPU 2" | tail -1)
  local -r ROW=$(print_temperature_array_line 5 "21" "45;46" "34" "$FAN_CONTROL_PROFILE" "$COOLING_RESPONSE_STATUS" "$COMMENT_MARKER")

  local -r ROW_BEFORE_COMMENT="${ROW%%"$COMMENT_MARKER"*}"

  assert_equals "$(comment_column_start_in_header "$HEADER_COLUMNS_LINE")" "$(display_width "$ROW_BEFORE_COMMENT")" \
    "MONITORING_ONLY_MODE=$IS_MONITORING_ONLY_MODE, \"$FAN_CONTROL_PROFILE\" : the comment column must start where the header says it does"
}

function test_the_table_columns_line_up_whatever_the_profile_and_the_mode() {
  # The defect of #170 : the profile column had zero slack -- "Dell default dynamic fan control profile" is
  # exactly the 40 characters it reserved -- so the monitoring only mode badge simply widened the field and
  # pushed the cooling response and comment columns 27 to 31 characters right of their headings. The shift
  # was not even constant, it followed the active profile and the configured percentage, so the columns
  # jittered from row to row and the header reprinted every TABLE_HEADER_PRINT_INTERVAL cycles never lined
  # up with a single data row
  assert_the_table_columns_line_up false "Dell default dynamic fan control profile" "Enabled"
  assert_the_table_columns_line_up false "User static fan control profile (5%)" "Could not be applied on this cycle"
  assert_the_table_columns_line_up false "User static fan control profile (100%)" "Not supported by this server"

  assert_the_table_columns_line_up true "Dell default dynamic fan control profile (monitoring only, not applied)" \
    "Enabled (not applied: monitoring only mode)"
  assert_the_table_columns_line_up true "User static fan control profile (5%) (monitoring only, not applied)" \
    "Disabled (not applied: monitoring only mode)"
  assert_the_table_columns_line_up true "User static fan control profile (100%) (monitoring only, not applied)" \
    "Enabled (not applied: monitoring only mode)"
}

function test_every_cpu_heading_sits_over_the_reading_it_labels() {
  # The test above measures a total : where the "Comment" column starts, on a table hardcoded to two CPUs.
  # That catches the right-hand columns drifting as a block, but not the CPU columns drifting among
  # themselves -- a header cell is printed by one printf ("' %*s '") and a row cell by another ("\" %s°C \""),
  # so the two can disagree while the widths still add up to the same total and the comment column never
  # moves. A reading sitting under the wrong socket's heading is what issue #91 looked like in the logs, and
  # a table of one or four CPUs, the two @ctark reported on, was never checked for alignment at all.
  #
  # Both cells end on their own trailing space, so the heading and the reading it labels have to end on the
  # same column. The readings are located by their "°C" rather than by their digits, which the timestamp
  # would otherwise collide with : the first one is the inlet's, so CPU N carries the (N + 1)th
  local CPU_COUNT CPU_NUMBER COLUMN_WIDTH HEADER_COLUMNS_LINE ROW ROW_IN_SINGLE_BYTE_CHARACTERS
  local -a CPU_LABELS
  local CPU_TEMPERATURES

  for CPU_COUNT in 1 2 3 4; do
    CPU_LABELS=()
    CPU_TEMPERATURES=""
    for ((CPU_NUMBER = 1; CPU_NUMBER <= CPU_COUNT; CPU_NUMBER++)); do
      CPU_LABELS+=("CPU $CPU_NUMBER")
      CPU_TEMPERATURES+="${CPU_TEMPERATURES:+;}$((40 + CPU_NUMBER))"
    done

    COLUMN_WIDTH=$(compute_CPU_column_content_width "${CPU_LABELS[@]}")
    HEADER_COLUMNS_LINE=$(build_header "$COLUMN_WIDTH" "${CPU_LABELS[@]}" | tail -1)
    ROW=$(print_temperature_array_line "$COLUMN_WIDTH" "21" "$CPU_TEMPERATURES" "34" \
      "Dell default dynamic fan control profile" "Enabled" "$COMMENT_MARKER")
    ROW_IN_SINGLE_BYTE_CHARACTERS="${ROW//°/o}"

    for ((CPU_NUMBER = 1; CPU_NUMBER <= CPU_COUNT; CPU_NUMBER++)); do
      assert_equals \
        "$(end_position_of_occurrence "$HEADER_COLUMNS_LINE" "CPU $CPU_NUMBER" 1)" \
        "$(end_position_of_occurrence "$ROW_IN_SINGLE_BYTE_CHARACTERS" "oC" $((CPU_NUMBER + 1)))" \
        "$CPU_COUNT CPU table : the \"CPU $CPU_NUMBER\" heading must end on the column CPU $CPU_NUMBER's reading ends on"
    done
  done
}

function test_no_fan_control_profile_can_outgrow_the_column_reserved_for_it() {
  # The widths are constants, so they can only stay right for as long as the strings do. This walks every
  # profile the code can actually produce -- both modes, every fan speed a user can configure -- and every
  # cooling response status, against the width its column reserves. A string longer than its column is what
  # #170 was, so a new profile wording has to be caught here rather than in somebody's docker logs
  local -r MONITORING_ONLY_MODE_BADGE=" (monitoring only, not applied)"
  # Outside monitoring only mode a profile whose ipmitool call was refused is reported with this suffix
  # instead of the bare name, so it is a string the code really produces and has to be walked here too.
  # Leaving it out is how #170's overflow came back : the column was still sized on the bare name while
  # the rows had started printing 14 characters more into it
  local -r NOT_APPLIED_BADGE=" (not applied)"
  local SPEED PROFILE VARIANT
  local IS_MONITORING_ONLY_MODE

  for IS_MONITORING_ONLY_MODE in false true; do
    export MONITORING_ONLY_MODE="$IS_MONITORING_ONLY_MODE"
    resolve_fan_control_profile_column_width

    local -a PROFILES=("Dell default dynamic fan control profile")
    for SPEED in 1 5 10 50 100; do
      PROFILES+=("User static fan control profile ($SPEED%)")
    done

    local WIDEST_PROFILE_WIDTH=0
    local -a VARIANTS
    for PROFILE in "${PROFILES[@]}"; do
      # In monitoring only mode the apply functions return before touching ipmitool, so the badge is the
      # only form that mode can produce. Outside it, both the applied and the refused forms occur
      if [ "$IS_MONITORING_ONLY_MODE" == "true" ]; then
        VARIANTS=("$PROFILE$MONITORING_ONLY_MODE_BADGE")
      else
        VARIANTS=("$PROFILE" "$PROFILE$NOT_APPLIED_BADGE")
      fi

      for VARIANT in "${VARIANTS[@]}"; do
        (( ${#VARIANT} > WIDEST_PROFILE_WIDTH )) && WIDEST_PROFILE_WIDTH=${#VARIANT}
        assert_equals "true" "$([ "${#VARIANT}" -le "$TABLE_FAN_CONTROL_PROFILE_COLUMN_WIDTH" ] && echo true || echo false)" \
          "MONITORING_ONLY_MODE=$IS_MONITORING_ONLY_MODE : \"$VARIANT\" (${#VARIANT}) must fit in $TABLE_FAN_CONTROL_PROFILE_COLUMN_WIDTH"
      done
    done

    # Reserving far more than the widest string would push the comment column right for nothing, so the
    # width is also asserted not to be generous
    assert_equals "$WIDEST_PROFILE_WIDTH" "$TABLE_FAN_CONTROL_PROFILE_COLUMN_WIDTH" \
      "MONITORING_ONLY_MODE=$IS_MONITORING_ONLY_MODE : the column is exactly as wide as its widest profile"
  done

  local COOLING_RESPONSE_STATUS
  for COOLING_RESPONSE_STATUS in "Enabled" "Disabled" "Not supported by this server" \
    "Could not be applied on this cycle" "Enabled (not applied: monitoring only mode)" \
    "Disabled (not applied: monitoring only mode)"; do
    assert_equals "true" "$([ "${#COOLING_RESPONSE_STATUS}" -le "$COOLING_RESPONSE_COLUMN_WIDTH" ] && echo true || echo false)" \
      "\"$COOLING_RESPONSE_STATUS\" (${#COOLING_RESPONSE_STATUS}) must fit in $COOLING_RESPONSE_COLUMN_WIDTH"
  done
}

function test_the_header_is_refused_when_the_profile_column_width_is_unresolved() {
  # That width is the one build_header() does not receive as an argument, the rows reading it too. Left
  # unresolved, printf pads to nothing and every row comes out misaligned without a word -- which is the
  # defect of #170 all over again, so it is refused rather than rendered
  local -r RESOLVED_WIDTH="$TABLE_FAN_CONTROL_PROFILE_COLUMN_WIDTH"
  unset TABLE_FAN_CONTROL_PROFILE_COLUMN_WIDTH

  local OUTPUT
  OUTPUT=$(build_header 5 "CPU 1" 2>&1)
  local -r EXIT_CODE=$?

  TABLE_FAN_CONTROL_PROFILE_COLUMN_WIDTH="$RESOLVED_WIDTH"

  assert_equals 1 "$EXIT_CODE" "a header that cannot be sized must not be printed"
  assert_contains "$OUTPUT" "resolve_fan_control_profile_column_width" "the refusal names what has not run"
}

function test_printing_a_row_leaks_no_variable_into_the_calling_shell() {
  # functions.sh is sourced by the entry point, so anything a function leaves undeclared lands in the
  # container's main shell -- and this one runs on every cycle of the monitoring loop. Nothing reads a
  # variable by these names today, which is exactly why the leak could sit there unnoticed (#171)
  local LEAKED_NAME
  for LEAKED_NAME in temperature i number_of_dashes; do
    unset "$LEAKED_NAME"
  done

  print_temperature_array_line 5 "21" "45;46" "34" "Dell default dynamic fan control profile" "Enabled" "-" > /dev/null
  build_header 5 "CPU 1" "CPU 2" > /dev/null

  for LEAKED_NAME in temperature i number_of_dashes; do
    assert_equals "unset" "${!LEAKED_NAME+set}${!LEAKED_NAME-unset}" \
      "\"$LEAKED_NAME\" must not escape into the shell that sourced functions.sh"
  done
}
