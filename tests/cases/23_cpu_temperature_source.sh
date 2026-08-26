#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# Where the CPU temperatures come from.
#
# The iDRAC is the source in every case where it can be one. lm-sensors answers a
# single, narrow situation : an iDRAC that accepts Dell's raw fan control commands
# but reports no CPU temperature at all, which leaves the controller able to do
# nothing but hand the fans back to Dell forever (issue #216). These cases pin
# when it engages, when it must not, and that the readings it produces are the
# same shape the rest of the controller supervises.

# A coretemp chip block as "sensors -u" prints it, package reading included, ready
# for MOCK_SENSORS_OUTPUT
# Usage : coretemp_chip_reporting $CHIP_INDEX $TEMPERATURE [$HIGH $CRIT]
function coretemp_chip_reporting() {
  local -r CHIP_INDEX="$1"
  local -r TEMPERATURE="$2"
  local -r HIGH="${3:-62}"
  local -r CRIT="${4:-72}"

  printf 'coretemp-isa-000%s\\nAdapter: ISA adapter\\nPackage id %s:\\n  temp%s_input: %s\\n  temp1_max: %s.000\\n  temp1_crit: %s.000\\n' \
    "$CHIP_INDEX" "$CHIP_INDEX" "1" "$TEMPERATURE" "$HIGH" "$CRIT"
}

# The per-core sub-features coretemp publishes next to the package one
# Usage : coretemp_cores $FIRST_CORE_TEMPERATURE $SECOND_CORE_TEMPERATURE
function coretemp_cores() {
  printf 'Core 0:\\n  temp2_input: %s\\nCore 1:\\n  temp3_input: %s\\n' "$1" "$2"
}

# A coretemp chip with NO package sensor at all : its cores still start at temp2, the temp1 slot being
# reserved for a package this CPU does not have rather than reused. Taken from the R510 of issue #378,
# whose two Westmere Xeons both report this shape
# Usage : coretemp_chip_without_a_package $CHIP_INDEX $FIRST_CORE $SECOND_CORE $THIRD_CORE
function coretemp_chip_without_a_package() {
  printf 'coretemp-isa-000%s\\nAdapter: ISA adapter\\nCore 0:\\n  temp2_input: %s\\n  temp2_max: 69.000\\nCore 1:\\n  temp3_input: %s\\n  temp3_max: 69.000\\nCore 8:\\n  temp10_input: %s\\n  temp10_max: 69.000\\n' \
    "$1" "$2" "$3" "$4"
}

# The same, with the first core relabelled the way unraid's Dynamix plugin does it : "label temp2 CPU
# Temp" in /etc/sensors.d/sensors.conf renames the feature, and "sensors -u" prints the new name
# Usage : coretemp_chip_without_a_package_relabelled $CHIP_INDEX $FIRST_CORE $SECOND_CORE $THIRD_CORE
function coretemp_chip_without_a_package_relabelled() {
  printf 'coretemp-isa-000%s\\nAdapter: ISA adapter\\nCPU Temp:\\n  temp2_input: %s\\n  temp2_max: 69.000\\nCore 1:\\n  temp3_input: %s\\n  temp3_max: 69.000\\nCore 8:\\n  temp10_input: %s\\n  temp10_max: 69.000\\n' \
    "$1" "$2" "$3" "$4"
}

# A coretemp chip whose PACKAGE feature has been renamed, which is what /etc/sensors.d does : the
# package still sits on temp1, only the label above it changed. This is the shape that tells matching
# on the label apart from matching on the sub-feature number -- the previous relabelled fixture renamed
# a core on a chip that had no temp1 at all, so it passed under both
# Usage : coretemp_chip_with_a_renamed_package $CHIP_INDEX $PACKAGE $FIRST_CORE $SECOND_CORE
function coretemp_chip_with_a_renamed_package() {
  printf 'coretemp-isa-000%s\\nAdapter: ISA adapter\\nCPU Temp:\\n  temp1_input: %s\\n  temp1_max: 62.000\\nCore 0:\\n  temp2_input: %s\\nCore 1:\\n  temp3_input: %s\\n' \
    "$1" "$2" "$3" "$4"
}

# A dual socket machine whose CPUs lm-sensors can read
# Usage : simulate_readable_CPUs_in_lm_sensors [$FIRST_TEMPERATURE $SECOND_TEMPERATURE]
function simulate_readable_CPUs_in_lm_sensors() {
  export MOCK_SENSORS_OUTPUT="$(coretemp_chip_reporting 0 "${1:-45.000}")$(coretemp_chip_reporting 1 "${2:-47.000}")"
}

# An iDRAC that answers, reports its inlet and exhaust sensors, and exposes no
# processor entity whatsoever : the very hardware issue #216 is about
function simulate_iDRAC_reporting_no_CPU() {
  export MOCK_IPMITOOL_SDR_OUTPUT
  MOCK_IPMITOOL_SDR_OUTPUT=$(make_sdr_output --cpus 0 --inlet 23 --exhaust 34)
}

# The same server as reported hardware actually presents it : the processor entities ARE there, they
# simply carry no reading. Issue #256 asked which of the two shapes the affected servers have, and the
# R510 of #378 answered -- it is this one, not the one above
# Usage : simulate_iDRAC_reporting_every_CPU_as_disabled
function simulate_iDRAC_reporting_every_CPU_as_disabled() {
  export MOCK_IPMITOOL_SDR_OUTPUT
  MOCK_IPMITOOL_SDR_OUTPUT=$(make_sdr_output --cpus 2 --every-cpu-disabled --inlet 29 --no-exhaust)
}

# --- The parameter itself -----------------------------------------------------

function test_the_three_sources_are_recognized() {
  local VALUE
  for VALUE in auto ipmi lm-sensors; do
    assert_equals "$VALUE" "$(normalize_CPU_temperature_source "$VALUE")"
  done
}

function test_the_forms_an_env_file_produces_are_accepted_for_the_source() {
  # Docker's --env-file keeps the trailing space of "CPU_TEMPERATURE_SOURCE=ipmi ",
  # and the documented placeholder used to show quotes that get copied along
  local VALUE
  for VALUE in "ipmi " " ipmi" '"ipmi"' "'ipmi'" "IPMI" "Ipmi"; do
    assert_equals "ipmi" "$(normalize_CPU_temperature_source "$VALUE")" "[$VALUE] should be the IPMI source"
  done

  # The separator inside "lm-sensors" is the one thing a user can plausibly write
  # three ways, and none of them can be confused with another value
  for VALUE in "lm-sensors" "lm_sensors" "lmsensors" "LM-Sensors" "lm sensors"; do
    assert_equals "lm-sensors" "$(normalize_CPU_temperature_source "$VALUE")" "[$VALUE] should be the lm-sensors source"
  done
}

function test_an_unset_source_is_the_automatic_one() {
  assert_equals "auto" "$(normalize_CPU_temperature_source "")"
}

function test_an_unknown_source_is_returned_untouched_so_it_can_be_reported() {
  # Mapping it to "auto" would have the container read a source the user did not
  # ask for, and the error message would have nothing left to quote
  assert_equals "idrac" "$(normalize_CPU_temperature_source "idrac")"
}

# --- Reading the CPUs from lm-sensors -----------------------------------------

function test_the_package_temperature_of_each_socket_is_read() {
  simulate_readable_CPUs_in_lm_sensors 45.000 47.000

  local -r READINGS=$(retrieve_CPU_temperatures_from_lm_sensors)

  assert_equals "0 coretemp-isa-0000 package 45
1 coretemp-isa-0001 package 47" "$READINGS"
}

function test_the_per_core_sub_features_are_not_read() {
  # A ten-core CPU publishes ten of them. Read as CPUs, a two-socket server would
  # get a twenty column table of readings that all describe the same two dies
  export MOCK_SENSORS_OUTPUT="$(coretemp_chip_reporting 0 45.000)$(coretemp_cores 44.000 43.000)"

  local -r READINGS=$(retrieve_CPU_temperatures_from_lm_sensors)

  assert_equals "0 coretemp-isa-0000 package 45" "$READINGS"
}

function test_a_reading_is_rounded_and_not_truncated() {
  # Unlike the threshold, which is deliberately truncated so it never ends up above
  # what the manufacturer defined, this is a measurement : truncating it would
  # under-report a 45.8°C CPU by nearly a degree on every single cycle
  export MOCK_SENSORS_OUTPUT="$(coretemp_chip_reporting 0 45.800)"
  assert_equals "0 coretemp-isa-0000 package 46" "$(retrieve_CPU_temperatures_from_lm_sensors)"

  export MOCK_SENSORS_OUTPUT="$(coretemp_chip_reporting 0 45.200)"
  assert_equals "0 coretemp-isa-0000 package 45" "$(retrieve_CPU_temperatures_from_lm_sensors)"
}

function test_chips_that_are_not_cpus_are_not_read_as_cpus() {
  # An NVMe drive is not a heat source this container controls, and reading it as a
  # CPU would put its temperature in a column labelled "CPU 2"
  export MOCK_SENSORS_OUTPUT="$(coretemp_chip_reporting 0 45.000)nvme-pci-0100\\nAdapter: PCI adapter\\nComposite:\\n  temp1_input: 38.850\\n"

  assert_equals "0 coretemp-isa-0000 package 45" "$(retrieve_CPU_temperatures_from_lm_sensors)"
}

function test_amd_chips_are_not_read() {
  # k10temp reports "Tctl", a control value on a scale that is not the physical
  # temperature the iDRAC reports for the very same CPU. Supervising one against a
  # threshold that describes the other is worse than not supervising it at all
  export MOCK_SENSORS_OUTPUT='k10temp-pci-00c3\nAdapter: PCI adapter\nTctl:\n  temp1_input: 42.500\n'

  assert_empty "$(retrieve_CPU_temperatures_from_lm_sensors)" "an AMD server must keep reading its CPUs through IPMI"
}

function test_a_machine_without_any_sensor_reads_nothing() {
  export MOCK_SENSORS_EXIT_CODE=1
  export MOCK_SENSORS_OUTPUT=""

  assert_empty "$(retrieve_CPU_temperatures_from_lm_sensors)"
  if is_lm_sensors_reporting_CPU_temperatures; then
    fail "lm-sensors reports nothing here, it must not be considered a usable source"
  else
    pass
  fi
}

function test_an_absent_lm_sensors_reads_nothing() {
  # The scripts can be run directly, outside the Docker image that installs it
  local -r ORIGINAL_PATH="$PATH"
  PATH="${PATH//$TESTS_DIRECTORY\/mocks:/}"
  export PATH

  assert_empty "$(retrieve_CPU_temperatures_from_lm_sensors)" "no sensors binary should mean no reading, not an error"

  PATH="$ORIGINAL_PATH"
  export PATH
}

# --- Rendering them the way the rest of the controller reads them --------------

function test_the_readings_are_rendered_as_processor_entities() {
  # Socket 0 is entity 3.1, exactly as an iDRAC would report it, so that detection,
  # per-entity reads and the table all keep working on a single shape
  simulate_readable_CPUs_in_lm_sensors 45.000 47.000

  local -r LINES=$(build_CPU_temperature_sdr_lines_from_lm_sensors)

  # The column layout is asserted verbatim, and not only through the parsing round
  # trip below : it is the contract every parsing function in the controller is
  # written against, and "ipmitool sdr type temperature" is the one producing it
  assert_equals "coretemp-isa-0000 | -- | ok  |  3.1 | 45 degrees C
coretemp-isa-0001 | -- | ok  |  3.2 | 47 degrees C" "$LINES"
}

function test_the_rendered_readings_are_parsed_back_by_the_existing_parsing() {
  simulate_readable_CPUs_in_lm_sensors 45.000 47.000

  local -r DATA=$(build_CPU_temperature_sdr_lines_from_lm_sensors)

  detect_CPU_temperature_sensors "$DATA"
  assert_equals "3.1 3.2" "${DETECTED_CPU_ENTITY_IDS[*]}"
  assert_equals "45" "$(retrieve_temperature_by_entity_id "$DATA" "3.1")"
  assert_equals "47" "$(retrieve_temperature_by_entity_id "$DATA" "3.2")"
}

function test_a_depopulated_socket_leaves_its_entity_free() {
  # coretemp only exposes the packages that are populated. Numbering the entities
  # after the package rather than after the order they come in is what keeps
  # "CPU 2" meaning the second socket instead of the second readable chip
  export MOCK_SENSORS_OUTPUT="$(coretemp_chip_reporting 1 47.000)"

  assert_matches "$(build_CPU_temperature_sdr_lines_from_lm_sensors)" '\| +3\.2 \| 47 degrees C$'
}

function test_only_the_processor_rows_of_the_idrac_are_replaced() {
  # lm-sensors has no equivalent for the inlet and exhaust sensors, so whatever the
  # iDRAC does report has to survive the merge : the fallback fills the hole it
  # leaves rather than blinding the controller to everything else
  simulate_readable_CPUs_in_lm_sensors 45.000 47.000
  local -r IDRAC_DATA=$(make_sdr_output --cpus 2 --cpu-temperatures "60 61" --inlet 23 --exhaust 34)

  local -r MERGED=$(merge_lm_sensors_CPU_temperatures_into_temperature_data "$IDRAC_DATA")

  assert_equals "23" "$(retrieve_temperature_by_sensor_name "$MERGED" "Inlet")" "the iDRAC's inlet sensor must survive"
  assert_equals "34" "$(retrieve_temperature_by_sensor_name "$MERGED" "Exhaust")" "the iDRAC's exhaust sensor must survive"
  assert_equals "45" "$(retrieve_temperature_by_entity_id "$MERGED" "3.1")" "the CPU rows must come from lm-sensors"
  assert_equals "47" "$(retrieve_temperature_by_entity_id "$MERGED" "3.2")"
  assert_not_contains "$MERGED" "60 degrees C" "the iDRAC's own CPU rows must be gone, not kept alongside"
}

function test_a_processor_row_the_idrac_still_carries_cannot_shadow_its_replacement() {
  # The lm-sensors rows are appended after the iDRAC's, and the per-entity lookup
  # stops at the first match : a processor row the iDRAC still reports would be the
  # one answering, and the reading meant to replace it would never be seen.
  #
  # The data is filtered exactly as retrieve_sdr_temperature_data() filters it, so
  # this exercises the shape the real path produces and not a richer one : a socket
  # the iDRAC lists as "Disabled" carries no "degrees" and is already gone by here,
  # which is why the readable row, not that one, is what has to be covered
  simulate_readable_CPUs_in_lm_sensors 45.000 47.000
  local -r IDRAC_DATA=$(make_sdr_output --cpus 2 --cpu-temperatures "60 61" --cpu2-disabled --inlet 23 | grep degrees)

  assert_contains "$IDRAC_DATA" "60 degrees C" "the iDRAC still reports its first socket"
  assert_not_contains "$IDRAC_DATA" "Disabled" "and its second one never reaches the merge"

  local -r MERGED=$(merge_lm_sensors_CPU_temperatures_into_temperature_data "$IDRAC_DATA")

  assert_equals "45" "$(retrieve_temperature_by_entity_id "$MERGED" "3.1")" "the reading must be lm-sensors', not the iDRAC's 60"
  assert_equals "47" "$(retrieve_temperature_by_entity_id "$MERGED" "3.2")"
}

function test_a_disabled_row_reaching_the_merge_is_dropped_all_the_same() {
  # Belt and braces : retrieve_sdr_temperature_data() removes it first, so this
  # shape does not occur today. The whole entity is dropped rather than only the
  # rows holding a reading, so the replacement holds whichever of the two it was,
  # and this pins that rather than the filter upstream staying where it is
  simulate_readable_CPUs_in_lm_sensors 45.000 47.000
  local -r IDRAC_DATA=$(make_sdr_output --cpus 2 --cpu2-disabled --inlet 23)

  local -r MERGED=$(merge_lm_sensors_CPU_temperatures_into_temperature_data "$IDRAC_DATA")

  assert_equals "47" "$(retrieve_temperature_by_entity_id "$MERGED" "3.2")"
  assert_not_contains "$MERGED" "Disabled"
}

function test_an_idrac_reporting_nothing_at_all_still_yields_the_cpus() {
  simulate_readable_CPUs_in_lm_sensors 45.000 47.000

  local -r MERGED=$(merge_lm_sensors_CPU_temperatures_into_temperature_data "")

  detect_CPU_temperature_sensors "$MERGED"
  assert_equals "3.1 3.2" "${DETECTED_CPU_ENTITY_IDS[*]}"
  assert_empty "$(retrieve_temperature_by_sensor_name "$MERGED" "Inlet")" "there is no inlet temperature to be had here"
}

# --- Resolving the source at startup ------------------------------------------

function test_the_automatic_source_starts_on_the_idrac() {
  resolve_CPU_temperature_source "auto" "false"

  assert_equals "auto" "$CPU_TEMPERATURE_SOURCE"
  assert_equals "ipmi" "$CPU_TEMPERATURE_SOURCE_IN_USE" "lm-sensors is a fallback, not a starting point"
  assert_contains "$CPU_TEMPERATURE_SOURCE_DESCRIPTION" "falling back to lm-sensors"
}

function test_the_automatic_source_states_the_network_mode_fallback_as_a_condition() {
  # Whether the fallback is available cannot be known at this point : the iDRAC has not been contacted
  # yet, and the answer now depends on whether this container turns out to be running on the server
  # IDRAC_HOST names (issue #465). So the line states the condition rather than a verdict
  resolve_CPU_temperature_source "auto" "true"

  assert_equals "ipmi" "$CPU_TEMPERATURE_SOURCE_IN_USE"
  assert_contains "$CPU_TEMPERATURE_SOURCE_DESCRIPTION" "proves to be running on the server itself"
  assert_not_contains "$CPU_TEMPERATURE_SOURCE_DESCRIPTION" "only available in local mode" \
    "network mode is no longer a blanket refusal, so the startup line must not say it is"
}

function test_the_explicit_lm_sensors_source_is_resolved_in_local_mode() {
  simulate_readable_CPUs_in_lm_sensors

  resolve_CPU_temperature_source "lm-sensors" "false"

  assert_equals "lm-sensors" "$CPU_TEMPERATURE_SOURCE_IN_USE"
  assert_contains "$CPU_TEMPERATURE_SOURCE_DESCRIPTION" "the iDRAC is still the one driving the fans"
}

function test_the_explicit_lm_sensors_source_is_refused_in_network_mode() {
  # It would read the CPUs of the machine running the container, which is not the
  # server whose fans are being controlled
  simulate_readable_CPUs_in_lm_sensors

  local OUTPUT
  OUTPUT=$(resolve_CPU_temperature_source "lm-sensors" "true" 2>&1)
  local -r EXIT_CODE=$?

  assert_equals 1 "$EXIT_CODE"
  assert_contains "$OUTPUT" "without anything having checked that they do" \
    "asking for it outright is asserting what auto checks"
  assert_contains "$OUTPUT" 'Leave CPU_TEMPERATURE_SOURCE to its default "auto"' \
    "the error should name the mode that can now reach the fallback in network mode"
  assert_contains "$OUTPUT" 'Setting IDRAC_HOST to "local"' "and the other way to recover"
}

function test_the_explicit_lm_sensors_source_is_refused_when_it_reads_nothing() {
  # Accepted, it would hand the fans back to Dell's profile on every single cycle,
  # which looks exactly like a container doing its job
  export MOCK_SENSORS_EXIT_CODE=1
  export MOCK_SENSORS_OUTPUT=""

  local OUTPUT
  OUTPUT=$(resolve_CPU_temperature_source "lm-sensors" "false" 2>&1)
  local -r EXIT_CODE=$?

  assert_equals 1 "$EXIT_CODE"
  assert_contains "$OUTPUT" "no CPU temperature could be read"
  assert_contains "$OUTPUT" "coretemp" "the error should name the kernel module to load"
}

function test_an_unknown_source_stops_the_controller() {
  local OUTPUT
  OUTPUT=$(resolve_CPU_temperature_source "idrac" "false" 2>&1)
  local -r EXIT_CODE=$?

  assert_equals 1 "$EXIT_CODE"
  assert_contains "$OUTPUT" 'Value     : "idrac"' "the error should quote what the user wrote"
}

# --- Deciding to fall back ----------------------------------------------------

function test_the_fallback_engages_on_the_check_that_found_no_sensor() {
  # One check is enough to conclude, and that is not this function's call to make :
  # it is why the controller exits rather than retries, an iDRAC exposing no
  # processor entity doing so on every check rather than on that one. Waiting for
  # several agreeing checks would only delay a container about to stop
  NETWORK_MODE=false
  CPU_TEMPERATURE_SOURCE=auto
  simulate_readable_CPUs_in_lm_sensors

  if engage_lm_sensors_CPU_temperature_fallback > /dev/null; then
    pass
  else
    fail "the fallback should engage on the check that found no readable sensor"
    return 1
  fi

  assert_equals "lm-sensors" "$CPU_TEMPERATURE_SOURCE_IN_USE"
}

function test_the_fallback_engages_only_once() {
  NETWORK_MODE=false
  CPU_TEMPERATURE_SOURCE=auto
  simulate_readable_CPUs_in_lm_sensors

  engage_lm_sensors_CPU_temperature_fallback > /dev/null || return 1

  if engage_lm_sensors_CPU_temperature_fallback > /dev/null; then
    fail "the source is already lm-sensors, there is nothing left to switch"
  else
    pass
  fi
}

function test_the_fallback_never_engages_in_network_mode() {
  NETWORK_MODE=true
  CPU_TEMPERATURE_SOURCE=auto
  simulate_readable_CPUs_in_lm_sensors

  if engage_lm_sensors_CPU_temperature_fallback > /dev/null; then
    fail "lm-sensors describes the wrong machine in network mode"
  else
    pass
  fi

  assert_equals "ipmi" "$CPU_TEMPERATURE_SOURCE_IN_USE"
}

function test_the_fallback_never_engages_on_the_explicit_ipmi_source() {
  NETWORK_MODE=false
  CPU_TEMPERATURE_SOURCE=ipmi
  simulate_readable_CPUs_in_lm_sensors

  if engage_lm_sensors_CPU_temperature_fallback > /dev/null; then
    fail "the user asked for the iDRAC and nothing else"
  else
    pass
  fi

  assert_equals "ipmi" "$CPU_TEMPERATURE_SOURCE_IN_USE"
}

function test_the_fallback_does_not_engage_when_lm_sensors_reads_nothing() {
  # Nothing to fall back on : the caller reports the iDRAC's verdict, which is what
  # it did before this fallback existed
  NETWORK_MODE=false
  CPU_TEMPERATURE_SOURCE=auto
  export MOCK_SENSORS_EXIT_CODE=1
  export MOCK_SENSORS_OUTPUT=""

  if engage_lm_sensors_CPU_temperature_fallback > /dev/null; then
    fail "there is no readable CPU to switch to"
  else
    pass
  fi

  assert_equals "ipmi" "$CPU_TEMPERATURE_SOURCE_IN_USE"
}

function test_the_switch_is_logged_with_what_led_to_it() {
  NETWORK_MODE=false
  CPU_TEMPERATURE_SOURCE=auto
  simulate_readable_CPUs_in_lm_sensors

  local -r OUTPUT=$(engage_lm_sensors_CPU_temperature_fallback)

  assert_contains "$OUTPUT" "The iDRAC reports no readable CPU temperature sensor, reading the CPUs from lm-sensors instead"
  assert_contains "$OUTPUT" "Fan control keeps going through the iDRAC" \
    "the log must not let the user believe the fans are being driven by something else"
  assert_matches "$OUTPUT" "^$CONTROLLER_TIMESTAMP_PATTERN " "the line must carry a timestamp like every other one"
}

# --- What the startup log says ------------------------------------------------

function test_the_detected_sensors_are_named_after_the_chips_they_are_read_from() {
  # Naming IPMI entities the iDRAC never reported would send the user looking for
  # rows that do not exist in their own "ipmitool sdr type temperature" output
  simulate_readable_CPUs_in_lm_sensors
  CPU_TEMPERATURE_SOURCE_IN_USE="lm-sensors"
  SDR_TEMPERATURE_DATA=$(build_CPU_temperature_sdr_lines_from_lm_sensors)
  detect_CPU_temperature_sensors "$SDR_TEMPERATURE_DATA"

  assert_equals "2 CPU temperature sensors detected (lm-sensors chips coretemp-isa-0000 and coretemp-isa-0001)" \
    "$(format_detected_CPU_temperature_sensors)"
}

function test_a_single_cpu_is_named_in_the_singular() {
  export MOCK_SENSORS_OUTPUT="$(coretemp_chip_reporting 0 45.000)"
  CPU_TEMPERATURE_SOURCE_IN_USE="lm-sensors"
  SDR_TEMPERATURE_DATA=$(build_CPU_temperature_sdr_lines_from_lm_sensors)
  detect_CPU_temperature_sensors "$SDR_TEMPERATURE_DATA"

  assert_equals "1 CPU temperature sensor detected (lm-sensors chip coretemp-isa-0000)" \
    "$(format_detected_CPU_temperature_sensors)"
}

function test_the_ipmi_source_keeps_naming_the_entities() {
  # The wording the README asks users to correlate with their own ipmitool output
  SDR_TEMPERATURE_DATA=$(make_sdr_output --cpus 2)
  detect_CPU_temperature_sensors "$SDR_TEMPERATURE_DATA"

  assert_equals "2 CPU temperature sensors detected (entities 3.1 and 3.2)" \
    "$(format_detected_CPU_temperature_sensors)"
}

# --- End to end ---------------------------------------------------------------

function test_the_controller_supervises_a_server_whose_idrac_reports_no_cpu() {
  # The whole point : an iDRAC that answers, drives the fans, and reports not a
  # single processor entity. Before the fallback, this container could do nothing
  # but hand the fans back to Dell forever
  provide_local_ipmi_device

  export IDRAC_HOST="local"
  export CPU_TEMPERATURE_SOURCE="auto"
  simulate_iDRAC_reporting_no_CPU
  simulate_readable_CPUs_in_lm_sensors 45.000 47.000

  local -r OUTPUT=$(run_controller)

  assert_contains "$OUTPUT" "reading the CPUs from lm-sensors instead"
  assert_contains "$OUTPUT" "2 CPU temperature sensors detected (lm-sensors chips coretemp-isa-0000 and coretemp-isa-0001)"
  assert_contains "$OUTPUT" "45°C" "the first CPU should be supervised"
  assert_contains "$OUTPUT" "47°C" "the second CPU should be supervised"
  assert_contains "$OUTPUT" "User static fan control profile" \
    "the fans must finally be driven, which is what this container exists for"
}

function test_the_inlet_and_exhaust_sensors_of_such_a_server_are_still_reported() {
  provide_local_ipmi_device

  export IDRAC_HOST="local"
  export CPU_TEMPERATURE_SOURCE="auto"
  simulate_iDRAC_reporting_no_CPU
  simulate_readable_CPUs_in_lm_sensors 45.000 47.000

  local -r OUTPUT=$(run_controller)

  assert_not_contains "$OUTPUT" "No exhaust temperature sensor detected." \
    "this iDRAC does report an exhaust sensor, only its CPUs are missing"
  assert_contains "$OUTPUT" "23°C" "the iDRAC's inlet temperature should still be shown"
  assert_contains "$OUTPUT" "34°C" "the iDRAC's exhaust temperature should still be shown"
}

function test_an_overheating_cpu_read_from_lm_sensors_falls_back_on_dells_profile() {
  # The readings have to reach the same decision the IPMI ones do, or the fallback
  # would be supervision in name only
  provide_local_ipmi_device

  export IDRAC_HOST="local"
  export CPU_TEMPERATURE_SOURCE="lm-sensors"
  export CPU_TEMPERATURE_THRESHOLD=50
  simulate_iDRAC_reporting_no_CPU
  # Cool on the readings the controller starts on, so that the switch to Dell's
  # profile is a change it reports rather than the state it started in. The first
  # two calls are the startup ones (resolving the source, then detecting the CPUs),
  # so the heat shows up on the second line of the table. Switching later than
  # needed would only cost the controller a few more cycles before the assertion
  # below is satisfied
  simulate_readable_CPUs_in_lm_sensors 45.000 47.000
  export MOCK_SENSORS_SECOND_OUTPUT="$(coretemp_chip_reporting 0 45.000)$(coretemp_chip_reporting 1 79.000)"
  export MOCK_SENSORS_SWITCH_AFTER_CALLS=2

  local -r OUTPUT=$(run_controller "temperature is too high")

  assert_contains "$OUTPUT" "User static fan control profile" \
    "the cool readings should have been supervised, and the user's fan speed applied"
  assert_contains "$OUTPUT" "CPU 2 temperature is too high, Dell default dynamic fan control profile applied for safety"
}

function test_the_controller_still_refuses_when_the_idrac_and_lm_sensors_both_report_nothing() {
  # Neither source has a CPU to offer. The fallback changes nothing here : the
  # controller hands the fans back to Dell and refuses to run, exactly as it does
  # without this feature, rather than supervise a table it can never fill
  provide_local_ipmi_device

  export IDRAC_HOST="local"
  export CPU_TEMPERATURE_SOURCE="auto"
  simulate_iDRAC_reporting_no_CPU
  export MOCK_SENSORS_EXIT_CODE=1
  export MOCK_SENSORS_OUTPUT=""

  local -r OUTPUT=$(run_controller "No CPU temperature sensor could be read")

  assert_contains "$OUTPUT" "No CPU temperature sensor could be read"
  assert_contains "$OUTPUT" "Dell default dynamic fan control profile applied for safety before exiting"
  assert_not_contains "$OUTPUT" "reading the CPUs from lm-sensors instead"
  # The negative control of the network-mode remedy below : in local mode the fallback already ran and
  # still found nothing, so naming the mode the user is already in would be noise
  assert_not_contains "$OUTPUT" "set IDRAC_HOST=local" \
    "a container already in local mode must not be told to switch to it"
  assert_equals "0" "$(count_ipmitool_calls_matching "raw 0x30 0x30 0x01 0x00")" \
    "manual fan control must never be enabled on readings the controller never got"
}

function test_a_network_mode_server_reporting_no_cpu_is_refused_rather_than_read_locally() {
  # lm-sensors would describe the machine running the container, not the server
  # being cooled. The negative control of the case above : same iDRAC, same readable
  # CPUs on this machine, other mode -- and the refusal stands
  simulate_iDRAC_reporting_no_CPU
  simulate_readable_CPUs_in_lm_sensors 45.000 47.000

  local -r OUTPUT=$(run_controller "No CPU temperature sensor could be read")

  assert_not_contains "$OUTPUT" "reading the CPUs from lm-sensors instead"
  assert_contains "$OUTPUT" "No CPU temperature sensor could be read"
}

function test_the_network_mode_refusal_names_the_one_remedy_that_server_has() {
  # Issue #378's reporter met this refusal on a machine that WAS the server being cooled, and the
  # message said nothing about the mode that would have worked. He had to work local mode out himself.
  # The refusal is correct -- network mode cannot assume the two are the same machine -- but a refusal
  # that names no remedy sends a user who has one away empty-handed
  simulate_iDRAC_reporting_no_CPU
  simulate_readable_CPUs_in_lm_sensors 45.000 47.000
  # Pinned rather than inherited from whatever machine runs the suite. Left to the real
  # /sys/class/dmi/id/product_serial this case reads an unreadable DMI on the CI runner and a readable
  # one inside the Docker image, where the suite runs as root -- so it passed on one and failed on the
  # other, on a difference that says nothing about the code (issue #465)
  provide_a_host_serial_to_the_controller

  local -r OUTPUT=$(run_controller "No CPU temperature sensor could be read")

  assert_contains "$OUTPUT" "set IDRAC_HOST=local" \
    "the mode that reads this server's CPUs has to be named"
  assert_contains "$OUTPUT" "every fan control command still goes to the very same BMC" \
    "and the reason it costs nothing, since the fans are driven through the iDRAC either way"
  # Since issue #465 the fallback is not refused in network mode, it is refused when the container could
  # not be SHOWN to run on the controlled server -- so the refusal has to say which of those happened,
  # and why. "Unavailable in network mode" is what it said before that check existed
  assert_not_contains "$OUTPUT" "that fallback is unavailable" \
    "network mode is no longer a blanket refusal, so the message must not describe it as one"
  assert_contains "$OUTPUT" "It was not shown here : " \
    "a refusal that rests on a check has to say what the check found"
  assert_contains "$OUTPUT" "does not report a usable serial number of its own" \
    "and here it is the host's own DMI that could not be read, which is the commonest reason by far"
}

function test_the_network_mode_refusal_names_the_two_machines_when_they_differ() {
  # The other branch of the same refusal, and one CI proved reachable rather than theoretical : the suite
  # running as root inside the Docker image reads the runner's own DMI, so a container CAN read this file.
  # A user who mistyped IDRAC_HOST, or pointed it at another node of the same rack, gets both tags named
  # rather than a verdict with nothing to check it against
  simulate_iDRAC_reporting_no_CPU
  simulate_readable_CPUs_in_lm_sensors 45.000 47.000
  provide_a_host_serial_to_the_controller "JQ3TW42"

  local -r OUTPUT=$(run_controller "No CPU temperature sensor could be read")

  assert_contains "$OUTPUT" "JQ3TW42" "the machine this container runs on has to be named"
  assert_contains "$OUTPUT" "5N7XXX2" "and so does the server IDRAC_HOST points at"
  assert_not_contains "$OUTPUT" "does not report a usable serial number" \
    "both were read here, so the refusal must not blame an unreadable one"
}

function test_two_chips_standing_in_for_a_package_are_not_run_together() {
  # What the reporter's own log read like : "lm-sensors chips coretemp-isa-0000 (hottest core)
  # coretemp-isa-0001 (hottest core)" -- two names joined by a space, each already containing spaces,
  # so the list read as one run-on string with no way to see where the first name ended
  export MOCK_SENSORS_OUTPUT
  MOCK_SENSORS_OUTPUT="$(coretemp_chip_without_a_package 0 32.000 26.000)$(coretemp_chip_without_a_package 1 22.000 31.000)"
  CPU_TEMPERATURE_SOURCE_IN_USE="lm-sensors"
  SDR_TEMPERATURE_DATA=$(build_CPU_temperature_sdr_lines_from_lm_sensors)
  detect_CPU_temperature_sensors "$SDR_TEMPERATURE_DATA"

  assert_equals "2 CPU temperature sensors detected (lm-sensors chips coretemp-isa-0000 (hottest core) and coretemp-isa-0001 (hottest core))" \
    "$(format_detected_CPU_temperature_sensors)" \
    "the two names have to be told apart, which a bare space cannot do here"
}

function test_a_healthy_idrac_is_never_second_guessed() {
  # The negative control of the whole feature : a server whose iDRAC reports its
  # CPUs must be supervised through it, and lm-sensors must never be consulted
  # even though it would answer
  provide_local_ipmi_device

  export IDRAC_HOST="local"
  export CPU_TEMPERATURE_SOURCE="auto"
  simulate_server "PowerEdge R730xd" --cpus 2 --cpu-temperatures "42 44"
  simulate_readable_CPUs_in_lm_sensors 45.000 47.000

  local -r OUTPUT=$(run_controller)

  assert_not_contains "$OUTPUT" "reading the CPUs from lm-sensors instead"
  assert_contains "$OUTPUT" "2 CPU temperature sensors detected (entities 3.1 and 3.2)"
  assert_contains "$OUTPUT" "42°C" "the temperatures must be the iDRAC's, not lm-sensors'"
  assert_contains "$OUTPUT" "44°C"
}

function test_the_startup_log_states_where_the_temperatures_come_from() {
  simulate_server "PowerEdge R730xd" --cpus 2 --cpu-temperatures "42 44"

  local -r OUTPUT=$(run_controller)

  assert_contains "$OUTPUT" "CPU temperature source: iDRAC (IPMI)" \
    "a user comparing the container's output against the iDRAC's own has to know which one it reads"
}

function test_an_unusable_source_stops_the_controller_before_it_touches_the_fans() {
  export CPU_TEMPERATURE_SOURCE="idrac"
  simulate_server "PowerEdge R730xd" --cpus 2 --cpu-temperatures "42 44"

  local -r OUTPUT=$(run_controller 'Error')

  assert_contains "$OUTPUT" "Parameter : CPU_TEMPERATURE_SOURCE" \
    "the error should name the parameter at fault"
  assert_equals "0" "$(count_ipmitool_calls_matching "raw 0x30 0x30")" \
    "no fan control profile should be applied on a configuration the container refuses"
}

# --- The healthcheck ----------------------------------------------------------

function test_the_healthcheck_asks_lm_sensors_when_that_is_what_the_container_reads() {
  # Asking the iDRAC would report the container unhealthy for doing exactly what it
  # was configured to do, and Docker's restart policy would turn that into a loop
  export CPU_TEMPERATURE_SOURCE="lm-sensors"
  simulate_readable_CPUs_in_lm_sensors 45.000 47.000
  export MOCK_IPMITOOL_SDR_EXIT_CODE=1
  export MOCK_IPMITOOL_SDR_OUTPUT=""

  local OUTPUT
  OUTPUT=$(cd "$CONTROLLER_WORKING_DIRECTORY" && bash ./healthcheck.sh 2>&1)
  local -r EXIT_CODE=$?

  assert_equals 0 "$EXIT_CODE" "the source the container reads answers, so the container is healthy"
  assert_contains "$OUTPUT" "45 degrees C"
}

function test_the_healthcheck_fails_when_the_source_the_container_reads_says_nothing() {
  export CPU_TEMPERATURE_SOURCE="lm-sensors"
  export MOCK_SENSORS_EXIT_CODE=1
  export MOCK_SENSORS_OUTPUT=""

  local EXIT_CODE=0
  (cd "$CONTROLLER_WORKING_DIRECTORY" && bash ./healthcheck.sh) > /dev/null 2>&1 || EXIT_CODE=$?

  assert_not_equals 0 "$EXIT_CODE" "the container can no longer read the temperatures it supervises"
}

function test_the_healthcheck_keeps_asking_the_idrac_on_the_automatic_source() {
  # Even on a container that has fallen back : the iDRAC is still the one being
  # sent every fan control command, so a container that has lost it has lost the
  # only thing it can act with, whatever it reads
  export CPU_TEMPERATURE_SOURCE="auto"
  simulate_readable_CPUs_in_lm_sensors
  export MOCK_IPMITOOL_SDR_EXIT_CODE=1
  export MOCK_IPMITOOL_SDR_OUTPUT=""

  local EXIT_CODE=0
  (cd "$CONTROLLER_WORKING_DIRECTORY" && bash ./healthcheck.sh) > /dev/null 2>&1 || EXIT_CODE=$?

  assert_not_equals 0 "$EXIT_CODE"
}

# --- CPUs that expose no package temperature sensor (issue #378) ---------------

function test_a_cpu_without_a_package_sensor_is_read_from_its_hottest_core() {
  # The R510 of issue #378 : two Westmere Xeons, neither exposing a package sensor, so the container
  # found nothing and refused to start. The hottest core is the closest stand-in -- the package sensor
  # tracks the hottest point of the die rather than a mean
  export MOCK_SENSORS_OUTPUT="$(coretemp_chip_without_a_package 0 32.000 26.000 25.000)"

  assert_equals "0 coretemp-isa-0000 hottest-core 32" "$(retrieve_CPU_temperatures_from_lm_sensors)" \
    "the hottest of the three cores is what stands in for the missing package"
}

function test_the_hottest_core_is_taken_rather_than_their_average() {
  # An average would read far below the threshold on a partly loaded CPU : one core at 70°C among five
  # idle ones averages to about 37°C, and the fans would stay low while that core approached
  # throttling. The threshold it is compared against is itself a per-core value
  export MOCK_SENSORS_OUTPUT="$(coretemp_chip_without_a_package 0 70.000 30.000 30.000)"

  assert_equals "0 coretemp-isa-0000 hottest-core 70" "$(retrieve_CPU_temperatures_from_lm_sensors)" \
    "the average of these three cores is about 43, which would keep the fans low on a throttling CPU"
}

function test_a_relabelled_feature_no_longer_hides_the_reading() {
  # What actually broke on the reporter's machine : unraid's sensors.conf renames a coretemp feature,
  # and the readings used to be located by that very name. The sub-feature number cannot be renamed
  export MOCK_SENSORS_OUTPUT="$(coretemp_chip_without_a_package_relabelled 0 22.000 32.000 28.000)"

  assert_equals "0 coretemp-isa-0000 hottest-core 32" "$(retrieve_CPU_temperatures_from_lm_sensors)" \
    "a renamed feature must not cost the reading"
}

function test_a_package_sensor_still_wins_over_the_cores_it_sits_with() {
  # The fallback must stay invisible on hardware that has a package : reading the hottest core there
  # would quietly raise what every existing lm-sensors user is supervised against
  export MOCK_SENSORS_OUTPUT="$(coretemp_chip_reporting 0 45.000)$(coretemp_cores 48.000 52.000)"

  assert_equals "0 coretemp-isa-0000 package 45" "$(retrieve_CPU_temperatures_from_lm_sensors)" \
    "45 is the package, and the 52°C core must not answer for it"
}

function test_a_socket_is_numbered_from_its_chip_rather_than_from_a_label() {
  # With no "Package id N" to read the socket from, the chip name is what numbers them -- and it has to
  # number them the same way on a machine that does have packages, or the two schemes could disagree
  export MOCK_SENSORS_OUTPUT="$(coretemp_chip_without_a_package 0 32.000 26.000 25.000)$(coretemp_chip_without_a_package 1 22.000 32.000 28.000)"

  assert_equals "0 coretemp-isa-0000 hottest-core 32
1 coretemp-isa-0001 hottest-core 32" "$(retrieve_CPU_temperatures_from_lm_sensors)" \
    "both sockets are read, and numbered after the chip that carries them"
}


function test_a_renamed_package_feature_is_still_read_as_the_package() {
  # The defect this closes, and the one the previous relabelled fixture could not catch : unraid's
  # /etc/sensors.d renames a coretemp feature, the package is still on temp1, and matching on the label
  # lost it. Reverting to label matching must fail here
  export MOCK_SENSORS_OUTPUT="$(coretemp_chip_with_a_renamed_package 0 45.000 48.000 52.000)"

  assert_equals "0 coretemp-isa-0000 package 45" "$(retrieve_CPU_temperatures_from_lm_sensors)" \
    "the package is on temp1 whatever it is called, and its 45 must not be replaced by the 52°C core"
}

function test_an_oddly_named_chip_never_takes_a_socket_another_chip_holds() {
  # NEXT_UNNAMED_SOCKET used to start at an unset variable, i.e. at 0, so the first chip with an
  # unrecognized name overwrote coretemp-isa-0000's name and lost its own reading
  export MOCK_SENSORS_OUTPUT="$(coretemp_chip_reporting 0 45.000)coretemp-isa-beef\nAdapter: ISA adapter\nPackage id 9:\n  temp1_input: 61.000\n"

  local -r READINGS=$(retrieve_CPU_temperatures_from_lm_sensors)

  assert_contains "$READINGS" "coretemp-isa-0000 package 45" "the normally named chip keeps its socket"
  assert_contains "$READINGS" "coretemp-isa-beef package 61" "and the odd one gets a column of its own"
}

function test_a_core_read_column_names_itself_in_the_startup_log() {
  # The fact has to travel in the data : every production caller reaches the builder through a command
  # substitution, so a global set inside it would be lost with the subshell
  export MOCK_SENSORS_OUTPUT="$(coretemp_chip_without_a_package 0 32.000 26.000 25.000)"
  CPU_TEMPERATURE_SOURCE_IN_USE="lm-sensors"

  SDR_TEMPERATURE_DATA=$(retrieve_temperature_data)
  detect_CPU_temperature_sensors "$SDR_TEMPERATURE_DATA"

  assert_contains "$SDR_TEMPERATURE_DATA" "hottest core" \
    "the reading's provenance must survive the command substitution the controller reads it through"
  assert_contains "$(format_detected_CPU_temperature_sensors)" "hottest core" \
    "and reach the line that already names the source of every CPU column"
}

function test_a_package_read_column_says_nothing_extra() {
  export MOCK_SENSORS_OUTPUT="$(coretemp_chip_reporting 0 45.000)"
  CPU_TEMPERATURE_SOURCE_IN_USE="lm-sensors"

  SDR_TEMPERATURE_DATA=$(retrieve_temperature_data)
  detect_CPU_temperature_sensors "$SDR_TEMPERATURE_DATA"

  assert_not_contains "$(format_detected_CPU_temperature_sensors)" "hottest core" \
    "nothing is standing in for anything on a chip that has its package"
}

# --- The shape reported hardware actually has (issues #256, #378) --------------

function test_processor_entities_that_carry_no_reading_are_not_counted_as_CPUs() {
  # An iDRAC6 on an 11G server lists its processor entities and reports "Disabled" where a temperature
  # would be. "Disabled" is not a malformed reading to be parsed more cleverly -- it is the absence of
  # one -- so the entity must not become a column whose value nothing can produce
  local -r SDR_DATA=$(make_sdr_output --cpus 2 --every-cpu-disabled --inlet 29 --no-exhaust)

  detect_CPU_temperature_sensors "$SDR_DATA"

  assert_equals "0" "${#DETECTED_CPU_ENTITY_IDS[@]}" \
    "entities 3.1 and 3.2 are listed, but neither carries a temperature"
}

function test_a_disabled_entity_is_told_apart_from_an_absent_one_only_by_its_reading() {
  # The two shapes must reach the same verdict, because the container's answer to both is the same :
  # ask another source. Pinning it here is what stops a looser reading check from making one of them
  # look like a CPU -- the entity row is present in this one, and only the reading column says no
  local -r NO_ENTITY_AT_ALL=$(make_sdr_output --cpus 0 --inlet 29)
  local -r EVERY_ENTITY_DISABLED=$(make_sdr_output --cpus 2 --every-cpu-disabled --inlet 29)

  assert_not_contains "$NO_ENTITY_AT_ALL" "3.1" "this shape emits no processor row"
  assert_contains "$EVERY_ENTITY_DISABLED" "3.1" "this one does, which is the whole difference"

  detect_CPU_temperature_sensors "$NO_ENTITY_AT_ALL"
  local -r WITHOUT_ENTITIES=${#DETECTED_CPU_ENTITY_IDS[@]}
  detect_CPU_temperature_sensors "$EVERY_ENTITY_DISABLED"
  local -r WITH_DISABLED_ENTITIES=${#DETECTED_CPU_ENTITY_IDS[@]}

  assert_equals "$WITHOUT_ENTITIES" "$WITH_DISABLED_ENTITIES" \
    "both are a server with no readable CPU, however differently the iDRAC words it"
}

function test_the_controller_supervises_a_server_whose_cpu_entities_are_all_disabled() {
  # The end to end path #216 built and #256 asked to confirm, on the shape real hardware has rather
  # than on the one it was first tested with. Before the fallback this container could do nothing but
  # hand the fans back to Dell forever
  provide_local_ipmi_device

  export IDRAC_HOST="local"
  export CPU_TEMPERATURE_SOURCE="auto"
  simulate_iDRAC_reporting_every_CPU_as_disabled
  simulate_readable_CPUs_in_lm_sensors 45.000 47.000

  local -r OUTPUT=$(run_controller)

  assert_contains "$OUTPUT" "reading the CPUs from lm-sensors instead" \
    "the fallback must engage on this shape too"
  assert_contains "$OUTPUT" "45°C" "the first CPU should be supervised"
  assert_contains "$OUTPUT" "47°C" "the second CPU should be supervised"
  assert_contains "$OUTPUT" "User static fan control profile" \
    "the fans must finally be driven, which is what this container exists for"
}

function test_such_a_server_still_reports_the_one_temperature_its_idrac_can_read() {
  # The R510 of #378 publishes exactly one readable temperature, its intake. Losing it while rescuing
  # the CPU columns would trade one blind spot for another
  provide_local_ipmi_device

  export IDRAC_HOST="local"
  export CPU_TEMPERATURE_SOURCE="auto"
  simulate_iDRAC_reporting_every_CPU_as_disabled
  simulate_readable_CPUs_in_lm_sensors 45.000 47.000

  local -r OUTPUT=$(run_controller)

  assert_contains "$OUTPUT" "29°C" "the intake reading must survive the switch of CPU source"
}

# --- Network mode on the very server being cooled (issue #465) -----------------
#
# lm-sensors reads the machine this container runs on. Network mode used to refuse it outright, because
# it could not tell whether that machine was the controlled server. It now compares the serial number the
# host reports about itself with the one the iDRAC reports for the server it manages -- and ANYTHING
# short of a positive match keeps the old refusal exactly as it was.

# Point the DMI lookup at a file of this test's own, holding the given value.
# Usage : simulate_host_reporting_its_own_serial "5N7XXX2"
function simulate_host_reporting_its_own_serial() {
  local -r SERIAL="$1"
  local -r DMI_FILE="$TEST_TEMPORARY_DIRECTORY/host_product_serial"

  printf '%s\n' "$SERIAL" > "$DMI_FILE"
  HOST_DMI_SERIAL_PATHS=("$DMI_FILE")
}

# A host whose DMI cannot be read at all : /sys not mounted, or product_serial readable by root alone.
# Usage : simulate_host_reporting_no_serial
function simulate_host_reporting_no_serial() {
  HOST_DMI_SERIAL_PATHS=("$TEST_TEMPORARY_DIRECTORY/there_is_no_dmi_here")
}

# A host that reports a board serial but no chassis service tag, which is what makes the pairing matter.
# The two arrays are walked by index, so the board file has to sit at index 1 -- where "Board Serial" is.
# Usage : simulate_host_reporting_only_a_board_serial "CN7016360I0026"
function simulate_host_reporting_only_a_board_serial() {
  local -r BOARD_FILE="$TEST_TEMPORARY_DIRECTORY/host_board_serial"

  printf '%s\n' "$1" > "$BOARD_FILE"
  HOST_DMI_SERIAL_PATHS=("$TEST_TEMPORARY_DIRECTORY/there_is_no_product_serial_here" "$BOARD_FILE")
}

# A host that reports both, so that each pair has something on its side.
# Usage : simulate_host_reporting_both_serials "90ABCDE" "CN7016360I0026"
function simulate_host_reporting_both_serials() {
  local -r PRODUCT_FILE="$TEST_TEMPORARY_DIRECTORY/host_product_serial"
  local -r BOARD_FILE="$TEST_TEMPORARY_DIRECTORY/host_board_serial"

  printf '%s\n' "$1" > "$PRODUCT_FILE"
  printf '%s\n' "$2" > "$BOARD_FILE"
  HOST_DMI_SERIAL_PATHS=("$PRODUCT_FILE" "$BOARD_FILE")
}

# Put the controller in the state engage_lm_sensors_CPU_temperature_fallback() is called from, against a
# server whose iDRAC reports the given serial number.
# Usage : arrange_a_network_mode_server_serialled "5N7XXX2"
function arrange_a_network_mode_server_serialled() {
  export MOCK_IPMITOOL_FRU_OUTPUT
  MOCK_IPMITOOL_FRU_OUTPUT=$(make_fru_output --serial "$1")

  NETWORK_MODE=true
  CPU_TEMPERATURE_SOURCE="auto"
  CPU_TEMPERATURE_SOURCE_IN_USE="ipmi"
  SAME_MACHINE_VERDICT=()
  simulate_readable_CPUs_in_lm_sensors
  get_Dell_server_model
}

function test_network_mode_reads_lm_sensors_when_the_two_serial_numbers_match() {
  # Issue #378's reporter : IDRAC_HOST pointed at the very box the container was running on, and the
  # blanket refusal cost him the only CPU reading his iDRAC 6 leaves him
  arrange_a_network_mode_server_serialled "5N7XXX2"
  simulate_host_reporting_its_own_serial "5N7XXX2"

  capture_output engage_lm_sensors_CPU_temperature_fallback
  local -r EXIT_CODE=$?

  assert_equals "0" "$EXIT_CODE" "the two machines are the same, so the host's chips describe the right CPUs"
  assert_equals "lm-sensors" "$CPU_TEMPERATURE_SOURCE_IN_USE"
  assert_contains "$CAPTURED_OUTPUT" "running on that very server" \
    "the switch rests on a proof, so the proof has to be in the log"
  assert_contains "$CAPTURED_OUTPUT" "5N7XXX2" "and the reader must be able to check the match themselves"
}

function test_network_mode_still_refuses_when_the_serial_numbers_differ() {
  # The case the refusal has always existed for : a container cooling a server it does not run on. Its
  # own CPUs say nothing about that server, and driving its fans from them leaves it heating up
  arrange_a_network_mode_server_serialled "5N7XXX2"
  simulate_host_reporting_its_own_serial "JQ3TW42"

  capture_output engage_lm_sensors_CPU_temperature_fallback

  assert_equals "1" "$?" "different machines must never be read for one another"
  assert_equals "ipmi" "$CPU_TEMPERATURE_SOURCE_IN_USE"
}

function test_a_host_that_reports_no_serial_number_is_not_proven_and_is_refused() {
  # The ordinary case, not an exotic one : /sys/class/dmi/id/product_serial is readable by root alone on
  # most distributions, and absent altogether when /sys is not mounted into the container. Unreadable is
  # "not proven", and not proven keeps the refusal
  arrange_a_network_mode_server_serialled "5N7XXX2"
  simulate_host_reporting_no_serial

  capture_output engage_lm_sensors_CPU_temperature_fallback

  assert_equals "1" "$?"
  assert_equals "ipmi" "$CPU_TEMPERATURE_SOURCE_IN_USE"
}

function test_an_idrac_that_reports_no_serial_number_is_not_proven_and_is_refused() {
  export MOCK_IPMITOOL_FRU_OUTPUT
  MOCK_IPMITOOL_FRU_OUTPUT=$(make_fru_output --no-serial)
  NETWORK_MODE=true
  CPU_TEMPERATURE_SOURCE="auto"
  CPU_TEMPERATURE_SOURCE_IN_USE="ipmi"
  SAME_MACHINE_VERDICT=()
  simulate_readable_CPUs_in_lm_sensors
  get_Dell_server_model
  simulate_host_reporting_its_own_serial "5N7XXX2"

  capture_output engage_lm_sensors_CPU_temperature_fallback

  assert_equals "1" "$?" "one side missing is one comparison that proves nothing"
  assert_equals "ipmi" "$CPU_TEMPERATURE_SOURCE_IN_USE"
}

function test_two_machines_that_both_report_a_placeholder_are_never_called_the_same_one() {
  # The failure this whole check would otherwise create. A DMI table nobody filled in reads "To Be Filled
  # By O.E.M." -- on EVERY such machine -- so a bare string comparison would declare any two of them the
  # same server and read one's CPUs for the other's fans. That is worse than the refusal it replaces, and
  # it is why a value has to be an identifier before it is ever compared
  arrange_a_network_mode_server_serialled "To Be Filled By O.E.M."
  simulate_host_reporting_its_own_serial "To Be Filled By O.E.M."

  capture_output engage_lm_sensors_CPU_temperature_fallback

  assert_equals "1" "$?" "equal placeholders are not a proven match, they are two unfilled fields"
  assert_equals "ipmi" "$CPU_TEMPERATURE_SOURCE_IN_USE"
}

function test_a_serial_number_too_short_to_identify_anything_is_refused() {
  # A short string is what two different machines are likeliest to share by accident
  arrange_a_network_mode_server_serialled "0"
  simulate_host_reporting_its_own_serial "0"

  capture_output engage_lm_sensors_CPU_temperature_fallback

  assert_equals "1" "$?"
}

function test_the_match_survives_the_padding_and_the_case_the_two_sides_report_it_in() {
  # One side is a kernel file, the other a fixed-length FRU field a BMC pads. Neither is worth trusting
  # to match character for character on spacing, and a service tag is not case sensitive
  arrange_a_network_mode_server_serialled "5n7xxx2  "
  simulate_host_reporting_its_own_serial "  5N7XXX2"

  capture_output engage_lm_sensors_CPU_temperature_fallback

  assert_equals "0" "$?" "the same tag reported two ways is still the same machine"
}

function test_local_mode_never_needs_the_host_to_prove_anything() {
  # The negative control : in local mode the container reaches the BMC through /dev/ipmi0, so it is on
  # that server by construction. A host whose DMI says nothing must not lose the fallback it always had
  arrange_a_network_mode_server_serialled "5N7XXX2"
  NETWORK_MODE=false
  simulate_host_reporting_no_serial

  capture_output engage_lm_sensors_CPU_temperature_fallback

  assert_equals "0" "$?" "local mode needs no proof, and must not start demanding one"
  assert_equals "lm-sensors" "$CPU_TEMPERATURE_SOURCE_IN_USE"
  assert_not_contains "$CAPTURED_OUTPUT" "running on that very server" \
    "and must not claim a proof it never made"
}

function test_the_verdict_is_settled_once_rather_than_on_every_check() {
  arrange_a_network_mode_server_serialled "5N7XXX2"
  simulate_host_reporting_its_own_serial "5N7XXX2"

  assert_command_succeeds "the two machines are the same" is_this_container_running_on_the_controlled_server

  # The host's DMI now says something else entirely. The answer must not change : neither serial number
  # changes while a container runs, and re-deriving it on every check is work with no question behind it
  simulate_host_reporting_its_own_serial "JQ3TW42"

  assert_command_succeeds "the verdict was settled on the first check" \
    is_this_container_running_on_the_controlled_server
}

# --- What the same-machine check must not be talked out of (issue #469) -------

function test_the_same_machine_verdict_cannot_be_handed_in_from_the_environment() {
  # The hole this closes. The verdict was memoised in a plain scalar, so
  # "docker run -e IS_THE_CONTAINER_ON_THE_CONTROLLED_SERVER=true" reached a "proven" answer with neither
  # serial number read -- the whole check turned off from the command line, three lines below the comment
  # explaining why HOST_DMI_SERIAL_PATHS had to be an array for exactly that reason
  arrange_a_network_mode_server_serialled "5N7XXX2"
  simulate_host_reporting_no_serial

  local NAME
  for NAME in IS_THE_CONTAINER_ON_THE_CONTROLLED_SERVER SAME_MACHINE_VERDICT; do
    SAME_MACHINE_VERDICT=()
    assert_command_fails "no environment variable named $NAME may stand in for reading a serial number" \
      env "$NAME=true" bash -c '
        cd "$1" || exit 2
        source constants.sh
        source functions.sh
        NETWORK_MODE=true
        FRU_SERVER_SECTION=""
        HOST_DMI_SERIAL_PATHS=("/there/is/no/dmi/here")
        is_this_container_running_on_the_controlled_server' _ "$REPO_ROOT"
  done
}

function test_a_serial_number_that_is_one_character_repeated_is_not_an_identifier() {
  # The curated list can only chase values someone has already seen, and its own near neighbours walk
  # through it : it holds eight zeros and seven x's, so ten zeros and eight x's were accepted and two
  # unrelated machines reporting either were called the same server
  local VALUE
  for VALUE in "0000000000" "XXXXXXXX" "00000000000000" "aaaa"; do
    assert_command_fails "\"$VALUE\" is a field nobody filled in, not a service tag" \
      is_this_serial_number_usable "$VALUE"
  done
}

function test_a_serial_number_carrying_no_letter_and_no_digit_is_not_an_identifier() {
  local VALUE
  for VALUE in "........" "--------" "-.-.-.-." "________"; do
    assert_command_fails "\"$VALUE\" carries nothing that could identify a machine" \
      is_this_serial_number_usable "$VALUE"
  done
}

function test_a_real_service_tag_still_passes_every_shape_rule() {
  # The negative control the two cases above need : rules that reject junk must not reject the thing they
  # exist to let through. A Dell service tag is seven alphanumeric characters
  local VALUE
  for VALUE in "5N7XXX2" "JQ3TW42" "1A2B3C4" "CN7016360I0026"; do
    assert_command_succeeds "\"$VALUE\" is a service tag and must be compared, not discarded" \
      is_this_serial_number_usable "$VALUE"
  done
}

function test_two_machines_reporting_the_same_unfilled_field_are_never_called_the_same_one() {
  # End to end, on the values that used to get through. Each of these is two unrelated servers being
  # declared one, and the container then driving a remote server's fans from its own CPU temperatures
  local VALUE
  for VALUE in "0000000000" "XXXXXXXX" "........"; do
    arrange_a_network_mode_server_serialled "$VALUE"
    simulate_host_reporting_its_own_serial "$VALUE"

    capture_output engage_lm_sensors_CPU_temperature_fallback

    assert_equals "1" "$?" "two machines both reporting \"$VALUE\" are two unfilled fields, not one server"
    assert_equals "ipmi" "$CPU_TEMPERATURE_SOURCE_IN_USE"
  done
}

function test_the_refusal_does_not_blame_the_proof_when_the_proof_succeeded() {
  # The two machines match, and lm-sensors then reports nothing. That reaches the same fatal refusal, and
  # it used to print "It was not shown here : both report serial number 5N7XXX2" -- a sentence whose
  # second half contradicts its first
  simulate_iDRAC_reporting_no_CPU
  export MOCK_SENSORS_OUTPUT=""
  export MOCK_SENSORS_EXIT_CODE=1
  provide_a_host_serial_to_the_controller "5N7XXX2"

  local -r OUTPUT=$(run_controller "No CPU temperature sensor could be read")

  assert_not_contains "$OUTPUT" "It was not shown here" \
    "the proof was made here : it is lm-sensors that had nothing to say"
}

# --- Each side compared against its own counterpart, never the other one (issue #469) ----------------

function test_a_service_tag_is_never_compared_against_a_board_serial() {
  # The R510 of issue #378, exactly as its owner dumped it : no "Product Serial" in the FRU at all, and a
  # "Board Serial" that is a different identifier. With the two sides falling back independently, the
  # host kept product_serial while the iDRAC fell through to Board Serial, and the check compared
  # 90ABCDE against CN7016360I0026 -- refusing the one machine it has ever run on, for good
  export MOCK_IPMITOOL_FRU_OUTPUT
  MOCK_IPMITOOL_FRU_OUTPUT=$(make_fru_output --no-product-serial --board-serial "CN7016360I0026")
  NETWORK_MODE=true
  CPU_TEMPERATURE_SOURCE="auto"
  CPU_TEMPERATURE_SOURCE_IN_USE="ipmi"
  SAME_MACHINE_VERDICT=()
  simulate_readable_CPUs_in_lm_sensors
  get_Dell_server_model
  simulate_host_reporting_both_serials "90ABCDE" "CN7016360I0026"

  assert_command_succeeds "the board serials match, so this IS the controlled server" \
    is_this_container_running_on_the_controlled_server
  assert_contains "$SAME_MACHINE_VERDICT_REASON" "Board Serial CN7016360I0026" \
    "and the pair that answered has to be named, not just the value"
}

function test_a_matching_service_tag_is_taken_before_the_board_serial() {
  # The first pair wins when it answers : a chassis service tag identifies the machine more directly than
  # a motherboard serial, which survives the board being swapped into another chassis
  export MOCK_IPMITOOL_FRU_OUTPUT
  MOCK_IPMITOOL_FRU_OUTPUT=$(make_fru_output --serial "5N7XXX2" --board-serial "CN7016360I0026")
  NETWORK_MODE=true
  CPU_TEMPERATURE_SOURCE="auto"
  CPU_TEMPERATURE_SOURCE_IN_USE="ipmi"
  SAME_MACHINE_VERDICT=()
  simulate_readable_CPUs_in_lm_sensors
  get_Dell_server_model
  simulate_host_reporting_both_serials "5N7XXX2" "CN7016360I0026"

  assert_command_succeeds "both pairs match here" is_this_container_running_on_the_controlled_server
  assert_contains "$SAME_MACHINE_VERDICT_REASON" "Product Serial 5N7XXX2" \
    "the service tag is the more direct identifier and answers first"
}

function test_a_host_serial_with_no_counterpart_says_which_side_is_missing() {
  # What the R510 of #378 gets when its host reports no board serial either : its product_serial WAS
  # read, so "neither reports one" would send its owner looking at the wrong side of the comparison
  export MOCK_IPMITOOL_FRU_OUTPUT
  MOCK_IPMITOOL_FRU_OUTPUT=$(make_fru_output --no-product-serial --board-serial "CN7016360I0026")
  NETWORK_MODE=true
  CPU_TEMPERATURE_SOURCE="auto"
  CPU_TEMPERATURE_SOURCE_IN_USE="ipmi"
  SAME_MACHINE_VERDICT=()
  simulate_readable_CPUs_in_lm_sensors
  get_Dell_server_model
  simulate_host_reporting_its_own_serial "90ABCDE"

  assert_command_fails "nothing pairs up here, so nothing is proven" \
    is_this_container_running_on_the_controlled_server
  assert_contains "$SAME_MACHINE_VERDICT_REASON" "reports no Product Serial" \
    "the iDRAC is the side that has nothing, and the message must say so"
  assert_contains "$SAME_MACHINE_VERDICT_REASON" "90ABCDE" \
    "while naming what the host did report, so the reader can check it"
}

function test_a_board_serial_that_differs_is_still_a_refusal() {
  # The negative control of the pairing : pairing like with like must not make matches easier to reach,
  # only accurate. Two different boards stay two different machines
  export MOCK_IPMITOOL_FRU_OUTPUT
  MOCK_IPMITOOL_FRU_OUTPUT=$(make_fru_output --no-product-serial --board-serial "CN7016360I0026")
  NETWORK_MODE=true
  CPU_TEMPERATURE_SOURCE="auto"
  CPU_TEMPERATURE_SOURCE_IN_USE="ipmi"
  SAME_MACHINE_VERDICT=()
  simulate_readable_CPUs_in_lm_sensors
  get_Dell_server_model
  simulate_host_reporting_only_a_board_serial "CN9999999Z9999"

  assert_command_fails "different boards are different machines" \
    is_this_container_running_on_the_controlled_server
  assert_contains "$SAME_MACHINE_VERDICT_REASON" "CN9999999Z9999" "both values have to be named"
  assert_contains "$SAME_MACHINE_VERDICT_REASON" "CN7016360I0026"
}
