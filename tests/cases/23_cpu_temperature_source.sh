#!/bin/bash

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

  assert_equals "0 coretemp-isa-0000 45
1 coretemp-isa-0001 47" "$READINGS"
}

function test_the_per_core_sub_features_are_not_read() {
  # A ten-core CPU publishes ten of them. Read as CPUs, a two-socket server would
  # get a twenty column table of readings that all describe the same two dies
  export MOCK_SENSORS_OUTPUT="$(coretemp_chip_reporting 0 45.000)$(coretemp_cores 44.000 43.000)"

  local -r READINGS=$(retrieve_CPU_temperatures_from_lm_sensors)

  assert_equals "0 coretemp-isa-0000 45" "$READINGS"
}

function test_a_reading_is_rounded_and_not_truncated() {
  # Unlike the threshold, which is deliberately truncated so it never ends up above
  # what the manufacturer defined, this is a measurement : truncating it would
  # under-report a 45.8°C CPU by nearly a degree on every single cycle
  export MOCK_SENSORS_OUTPUT="$(coretemp_chip_reporting 0 45.800)"
  assert_equals "0 coretemp-isa-0000 46" "$(retrieve_CPU_temperatures_from_lm_sensors)"

  export MOCK_SENSORS_OUTPUT="$(coretemp_chip_reporting 0 45.200)"
  assert_equals "0 coretemp-isa-0000 45" "$(retrieve_CPU_temperatures_from_lm_sensors)"
}

function test_chips_that_are_not_cpus_are_not_read_as_cpus() {
  # An NVMe drive is not a heat source this container controls, and reading it as a
  # CPU would put its temperature in a column labelled "CPU 2"
  export MOCK_SENSORS_OUTPUT="$(coretemp_chip_reporting 0 45.000)nvme-pci-0100\\nAdapter: PCI adapter\\nComposite:\\n  temp1_input: 38.850\\n"

  assert_equals "0 coretemp-isa-0000 45" "$(retrieve_CPU_temperatures_from_lm_sensors)"
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

function test_the_automatic_source_says_it_has_no_fallback_in_network_mode() {
  resolve_CPU_temperature_source "auto" "true"

  assert_equals "ipmi" "$CPU_TEMPERATURE_SOURCE_IN_USE"
  assert_contains "$CPU_TEMPERATURE_SOURCE_DESCRIPTION" "only available in local mode"
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
  assert_contains "$OUTPUT" "would describe the wrong hardware"
  assert_contains "$OUTPUT" 'Set IDRAC_HOST to "local"' "the error should say how to recover"
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
  assert_contains "$OUTPUT" 'but is "idrac"' "the error should quote what the user wrote"
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

  assert_equals "2 CPU temperature sensors detected (lm-sensors chips coretemp-isa-0000 coretemp-isa-0001)" \
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

  assert_equals "2 CPU temperature sensors detected (entities 3.1 3.2)" \
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
  assert_contains "$OUTPUT" "2 CPU temperature sensors detected (lm-sensors chips coretemp-isa-0000 coretemp-isa-0001)"
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
  assert_contains "$OUTPUT" "2 CPU temperature sensors detected (entities 3.1 3.2)"
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

  assert_contains "$OUTPUT" "CPU_TEMPERATURE_SOURCE must be"
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
  OUTPUT=$(cd "$REPO_ROOT" && bash ./healthcheck.sh 2>&1)
  local -r EXIT_CODE=$?

  assert_equals 0 "$EXIT_CODE" "the source the container reads answers, so the container is healthy"
  assert_contains "$OUTPUT" "45 degrees C"
}

function test_the_healthcheck_fails_when_the_source_the_container_reads_says_nothing() {
  export CPU_TEMPERATURE_SOURCE="lm-sensors"
  export MOCK_SENSORS_EXIT_CODE=1
  export MOCK_SENSORS_OUTPUT=""

  local EXIT_CODE=0
  (cd "$REPO_ROOT" && bash ./healthcheck.sh) > /dev/null 2>&1 || EXIT_CODE=$?

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
  (cd "$REPO_ROOT" && bash ./healthcheck.sh) > /dev/null 2>&1 || EXIT_CODE=$?

  assert_not_equals 0 "$EXIT_CODE"
}
