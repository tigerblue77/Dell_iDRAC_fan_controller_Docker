#!/bin/bash

# Blades and modular servers : the M1000e and VRTX blades (M600 to M640), the FX2
# sleds (FC430, FC630, FC830, FC640), the MX7000 sleds (MX740c to MX760c) and the
# nodes of a C-series chassis (C6320 to C6620).
#
# They differ from a rack server in one way that changes everything this
# controller does : they carry no fan. The fans belong to the enclosure and are
# driven by its CMC, so the raw fan control commands sent to the server's own
# iDRAC control nothing, whatever its generation. The controller cannot cool
# them, and these test cases pin what it does instead : identify the server,
# report the rejection, and keep monitoring rather than crash or silently pretend
# the profile was applied.
#
# They also report no exhaust sensor, the airflow leaving through the enclosure
# rather than through the server, and some of them report no inlet sensor either.

function test_an_enclosure_housed_server_is_told_the_cooling_response_is_not_its_to_set() {
  # A blade or a sled has no fan of its own, so its iDRAC refuses Dell's OEM
  # cooling response command whatever its generation. The controller used to read
  # the generation off the model name and, since Dell never named a blade
  # "[RT]<digit><digit>0", treated a 2023 MX760c exactly like a 2007 M600 : it
  # sent the command forever and reported it applied. Asking the server settles it
  # for every one of them, without a name to recognize
  export DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE=true
  simulate_enclosure_housed_server "PowerEdge MX760c" --cpus 2
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0x30|0x30 0xce"

  local -r OUTPUT=$(run_controller "Not supported by this server")

  assert_matches "$OUTPUT" "fan control profile.*Not supported by this server" \
    "the table must report what the sled answered, not what the user asked for"
  # The one asked on the first cycle, plus the one graceful_exit sends on the way out
  assert_equals "2" "$(count_ipmitool_calls_matching "raw 0x30 0xce")" \
    "the sled answered rsp=0xc1, which settles it on the first try"
}

function test_the_catalogue_covers_every_enclosure_dell_shipped() {
  local ENCLOSURE
  for ENCLOSURE in "${DELL_SERVER_ENCLOSURES[@]}"; do
    local MODEL_COUNT
    MODEL_COUNT=$(catalogue_entries_housed_in_enclosure "$ENCLOSURE" | wc -l)
    if [ "$MODEL_COUNT" -ge 1 ]; then
      pass
    else
      fail "no model is catalogued for the $ENCLOSURE enclosure"
    fi
  done

  # The M1000e spans five generations of blades, from the M600 to the M640
  local -r M1000E_MODEL_COUNT=$(catalogue_entries_housed_in_enclosure "M1000e" | wc -l)
  if [ "$M1000E_MODEL_COUNT" -ge 10 ]; then
    pass
  else
    fail "only $M1000E_MODEL_COUNT M1000e blades are catalogued"
  fi

  # The VRTX takes a subset of the M1000e blades, so every VRTX model also fits
  # an M1000e : a model listed for the VRTX alone would be a catalogue mistake
  local ENTRY MODEL ENCLOSURES
  while IFS= read -r ENTRY; do
    IFS='|' read -r _ MODEL _ _ ENCLOSURES <<< "$ENTRY"
    assert_equals "M1000e/VRTX" "$ENCLOSURES" "$MODEL fits a VRTX, it must fit an M1000e too"
  done < <(catalogue_entries_housed_in_enclosure "VRTX")

  # Every enclosure-housed server must be marked as such in the fan control
  # column too, the two columns describing the same fact from both ends
  while IFS= read -r ENTRY; do
    IFS='|' read -r _ MODEL _ SUPPORT _ <<< "$ENTRY"
    assert_equals "chassis-managed" "$SUPPORT" \
      "$MODEL is housed in an enclosure, its fans cannot be driven through its own iDRAC"
  done < <(catalogue_entries_housed_in_an_enclosure)
}

function test_a_blade_reports_no_exhaust_temperature_sensor() {
  # An M630 in an M1000e : two CPUs, an inlet sensor, and no exhaust one
  export MOCK_IPMITOOL_SDR_OUTPUT
  MOCK_IPMITOOL_SDR_OUTPUT=$(make_sdr_output --cpus 2 --cpu-temperatures "43 45" --inlet 24 --no-exhaust)

  detect_CPU_temperature_sensors "$(retrieve_sdr_temperature_data)"
  retrieve_temperatures true

  assert_equals "2" "${#DETECTED_CPU_ENTITY_IDS[@]}"
  assert_equals "24" "$INLET_TEMPERATURE"
  assert_empty "$EXHAUST_TEMPERATURE" "a blade has no exhaust sensor of its own"
}

function test_a_sled_whose_enclosure_owns_the_airflow_reports_no_temperature_around_it() {
  # Some sleds expose neither an inlet nor an exhaust sensor : both ends of the
  # airflow are measured by the enclosure. Only the CPUs are left to read, and
  # they are the ones driving the decision anyway
  export MOCK_IPMITOOL_SDR_OUTPUT
  MOCK_IPMITOOL_SDR_OUTPUT=$(make_sdr_output --cpus 2 --cpu-temperatures "47 48" --no-inlet --no-exhaust)

  detect_CPU_temperature_sensors "$(retrieve_sdr_temperature_data)"
  retrieve_temperatures true

  assert_equals "47" "${DETECTED_CPU_TEMPERATURES[0]}"
  assert_equals "48" "${DETECTED_CPU_TEMPERATURES[1]}"
  assert_empty "$INLET_TEMPERATURE" "this sled has no inlet sensor"
  assert_empty "$EXHAUST_TEMPERATURE" "this sled has no exhaust sensor"
}

function test_every_enclosure_housed_server_reports_its_rejected_fan_control_commands() {
  # The mirror of the same test on the recent generations : there the firmware
  # refuses, here the BMC has no fan to drive. The controller must react the same
  # way in both cases, identify the server then report a readable error
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0x30"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="$ENCLOSURE_REJECTED_FAN_CONTROL_STDERR"

  local ENTRY MODEL SOCKETS
  while IFS= read -r ENTRY; do
    IFS='|' read -r _ MODEL SOCKETS _ _ <<< "$ENTRY"
    simulate_server "$MODEL" --cpus "$SOCKETS" --no-exhaust

    get_Dell_server_model
    assert_equals "$MODEL" "$SERVER_MODEL" "$MODEL should be identified"

    capture_output apply_Dell_default_fan_control_profile
    assert_contains "$CAPTURED_OUTPUT" "Failed to apply Dell default fan control profile" \
      "$MODEL should report the rejected safety profile"

    capture_output apply_user_fan_control_profile
    assert_contains "$CAPTURED_OUTPUT" "Failed to enable manual fan control" \
      "$MODEL should report the rejected user profile"
  done < <(catalogue_entries_with_fan_control_support "chassis-managed")
}

function test_the_controller_keeps_monitoring_a_server_it_cannot_cool() {
  # One representative of each enclosure, started exactly like its Docker image
  # does. None of them can have its fans driven, and all of them must still be
  # identified, monitored and logged
  local ENCLOSURE_AND_MODEL ENCLOSURE MODEL
  for ENCLOSURE_AND_MODEL in \
    "M1000e:PowerEdge M630" \
    "VRTX:PowerEdge M620" \
    "FX2:PowerEdge FC630" \
    "MX7000:PowerEdge MX740c" \
    "C-series:PowerEdge C6420"; do
    ENCLOSURE="${ENCLOSURE_AND_MODEL%%:*}"
    MODEL="${ENCLOSURE_AND_MODEL#*:}"

    forget_recorded_ipmitool_calls
    simulate_enclosure_housed_server "$MODEL" --cpus 2 --cpu-temperatures "44 46"

    local OUTPUT
    OUTPUT=$(run_controller)

    assert_contains "$OUTPUT" "Server model: DELL $MODEL" "$MODEL ($ENCLOSURE) should be identified"
    assert_contains "$OUTPUT" "No exhaust temperature sensor detected." \
      "$MODEL ($ENCLOSURE) has no exhaust sensor of its own"
    assert_contains "$OUTPUT" "Failed to enable manual fan control" \
      "$MODEL ($ENCLOSURE) should report that its enclosure owns the fans"
    assert_contains "$OUTPUT" "44°C" "$MODEL ($ENCLOSURE) should still be monitored"
    assert_contains "$OUTPUT" "46°C" "$MODEL ($ENCLOSURE) should still report its second CPU"
  done
}

function test_an_overheating_blade_still_falls_back_on_dells_profile() {
  # The fallback is a request the CMC is free to refuse, but the controller must
  # still make it, and say so : that log line is what tells the user their blade
  # is hot and that nothing this container does will cool it
  simulate_enclosure_housed_server "PowerEdge M640" --cpus 2 --cpu-temperatures "42 44"
  export MOCK_IPMITOOL_SDR_SECOND_OUTPUT
  MOCK_IPMITOOL_SDR_SECOND_OUTPUT=$(make_sdr_output --cpus 2 --cpu-temperatures "42 79" --no-exhaust)
  export MOCK_IPMITOOL_SDR_SWITCH_AFTER_CALLS=1

  local -r OUTPUT=$(run_controller "temperature is too high")

  assert_contains "$OUTPUT" "CPU 2 temperature is too high, Dell default dynamic fan control profile applied for safety"
  assert_contains "$OUTPUT" "Failed to apply Dell default fan control profile"
  if [ "$(count_ipmitool_calls_matching "raw 0x30 0x30 0x01 0x01")" -ge 1 ]; then
    pass
  else
    fail "the overheating blade should have been sent Dell's dynamic fan control profile"
  fi
}

function test_aiming_the_controller_at_the_enclosure_instead_of_a_blade_fails_safe() {
  # The address printed on an M1000e's front panel is the CMC's, not a blade's,
  # so users do point IDRAC_HOST at it. The CMC is a Dell product and it answers
  # IPMI, so the controller accepts it, but it hosts no CPU : rather than run the
  # low user fan speed on a reading it never got, the missing CPU 1 must be
  # treated as an overheating one and hand the fans back to Dell's own profile
  simulate_enclosure_management_controller "PowerEdge M1000e"

  local -r OUTPUT=$(run_controller)

  assert_contains "$OUTPUT" "Server model: DELL PowerEdge M1000e"
  assert_contains "$OUTPUT" "Dell default dynamic fan control profile" \
    "an unreadable CPU must fall back on Dell's own profile"
  # It exposes no processor entity, which is stated once at startup. The chassis
  # sensors it does expose are still worth logging, so the table is printed with
  # no CPU column rather than not printed at all
  assert_contains "$OUTPUT" "No CPU temperature sensor detected, only the chassis temperatures will be monitored." \
    "the enclosure reports no processor entity, and the controller says so"
  assert_equals "0" "$(count_ipmitool_calls_matching "raw 0x30 0x30 0x01 0x00")" \
    "manual fan control must never be enabled on readings the controller never got"
  assert_equals "0" "$(count_ipmitool_calls_matching "raw 0x30 0x30 0x02")" \
    "no fan speed must be sent either"
}

function test_the_enclosure_is_still_monitored_when_it_exposes_no_processor_entity() {
  # Regression test for issue #221 : waiting for a processor entity that a CMC
  # will never expose left the container printing one line and then nothing, for
  # ever -- with MONITORING_ONLY_MODE, whose entire purpose is those lines, the
  # sharpest edge. What the enclosure does expose is monitored instead
  simulate_enclosure_management_controller "PowerEdge M1000e"

  local -r OUTPUT=$(run_controller)

  assert_matches "$OUTPUT" 'Date & time      Inlet  Exhaust' \
    "the table is printed, with no CPU column between the inlet and the exhaust"
  assert_matches "$OUTPUT" '01-01-2024 00:00:00[[:space:]]+22°C' \
    "and the inlet reading the enclosure does report is logged"
  assert_contains "$OUTPUT" "No CPU temperature could be read, Dell default dynamic fan control profile applied for safety" \
    "the comment column says why the fans were handed to Dell"
  # The setting is applied inside the monitoring loop, so it was never applied at
  # all while the container waited for a CPU that was not coming
  if [ "$(count_ipmitool_calls_matching "raw 0x30 0xce")" -ge 1 ]; then
    pass
  else
    fail "the third-party PCIe card cooling response setting must still be applied"
  fi
}

function test_monitoring_only_mode_keeps_logging_an_enclosure_that_exposes_no_processor_entity() {
  # The sharp edge of issue #221 : logging temperatures is the entire purpose of
  # this mode, so a server it can only ever read chassis sensors from is exactly
  # the one it must keep printing lines for -- and it must still touch no fan
  export MONITORING_ONLY_MODE=true
  simulate_enclosure_management_controller "PowerEdge M1000e"

  local -r OUTPUT=$(run_controller)

  assert_matches "$OUTPUT" '01-01-2024 00:00:00[[:space:]]+22°C' \
    "the inlet reading must be logged, mode or no mode"
  assert_contains "$OUTPUT" "(monitoring only, not applied)" \
    "and the profile column must say the fans were left alone"
  assert_equals "0" "$(count_ipmitool_calls_matching "raw 0x30 0x30")" \
    "no fan control command must be sent in monitoring only mode"
}

function test_a_processor_entity_showing_up_later_is_adopted_by_a_table_that_had_none() {
  # The other half : an iDRAC answering before its processor entities are readable
  # starts a CPU-less table, and must widen it as soon as one answers rather than
  # stay chassis-only for the life of the container
  simulate_enclosure_management_controller "PowerEdge M1000e"
  export MOCK_IPMITOOL_SDR_SECOND_OUTPUT MOCK_IPMITOOL_SDR_SWITCH_AFTER_CALLS
  MOCK_IPMITOOL_SDR_SECOND_OUTPUT=$(make_sdr_output --cpus 2 --cpu-temperatures "44 46" --no-exhaust --inlet 22)
  MOCK_IPMITOOL_SDR_SWITCH_AFTER_CALLS=2

  # Waiting on the reading rather than on the adoption line : the columns are
  # widened on the cycle the set changes and filled on the next one, so stopping
  # at the adoption line would stop one cycle before the table proves it
  local -r OUTPUT=$(run_controller "44°C")

  assert_matches "$OUTPUT" 'Date & time      Inlet  Exhaust' \
    "the chassis-only table runs while no socket answers"
  assert_contains "$OUTPUT" "2 CPU temperature sensors detected (entities 3.1 3.2)." \
    "the sockets that became readable are adopted"
  assert_matches "$OUTPUT" 'Date & time      Inlet  CPU 1  CPU 2  Exhaust' \
    "and the table grows the two columns it had none of"
  assert_contains "$OUTPUT" "44°C" "and reads them from then on"
}
