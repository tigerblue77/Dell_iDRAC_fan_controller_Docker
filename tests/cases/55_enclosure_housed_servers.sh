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

function test_every_enclosure_housed_server_is_detected_as_gen_13_or_older() {
  # Dell never named a blade or a sled "[RT]<digit><digit>0", so the name-based
  # detection cannot see a single one of them : a 2023 MX760c is treated exactly
  # like a 2007 M600. This documents that blind spot rather than wishes it away
  local ENTRY GENERATION MODEL EXPECTED_FLAG

  while IFS= read -r ENTRY; do
    IFS='|' read -r GENERATION MODEL _ EXPECTED_FLAG _ _ <<< "$ENTRY"

    local ACTUAL_FLAG=false
    if is_detected_as_gen_14_or_newer "$MODEL"; then
      ACTUAL_FLAG=true
    fi

    assert_equals "$EXPECTED_FLAG" "$ACTUAL_FLAG" \
      "$MODEL (Gen $GENERATION) should be detected as gen 14 or newer = $EXPECTED_FLAG"
  done < <(catalogue_entries_housed_in_an_enclosure)
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
    IFS='|' read -r _ MODEL _ _ _ ENCLOSURES <<< "$ENTRY"
    assert_equals "M1000e/VRTX" "$ENCLOSURES" "$MODEL fits a VRTX, it must fit an M1000e too"
  done < <(catalogue_entries_housed_in_enclosure "VRTX")

  # Every enclosure-housed server must be marked as such in the fan control
  # column too, the two columns describing the same fact from both ends
  while IFS= read -r ENTRY; do
    IFS='|' read -r _ MODEL _ _ SUPPORT _ <<< "$ENTRY"
    assert_equals "chassis-managed" "$SUPPORT" \
      "$MODEL is housed in an enclosure, its fans cannot be driven through its own iDRAC"
  done < <(catalogue_entries_housed_in_an_enclosure)
}

function test_a_blade_reports_no_exhaust_temperature_sensor() {
  # An M630 in an M1000e : two CPUs, an inlet sensor, and no exhaust one
  export MOCK_IPMITOOL_SDR_OUTPUT
  MOCK_IPMITOOL_SDR_OUTPUT=$(make_sdr_output --cpus 2 --cpu-temperatures "43 45" --inlet 24 --no-exhaust)

  detect_CPU_temperature_sensors "$(retrieve_sdr_temperature_data)"
  retrieve_temperatures

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
  retrieve_temperatures

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
    IFS='|' read -r _ MODEL SOCKETS _ _ _ <<< "$ENTRY"
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

function test_the_third_party_pcie_card_command_still_reaches_the_most_recent_sleds() {
  # The consequence of the blind spot the first test case documents : an MX760c
  # is a 2023 server, but the controller believes it is Gen 13 or older and keeps
  # sending it the third-party PCIe card cooling response command, which only
  # exists up to Gen 13. Harmless (the answer is discarded on purpose) but real,
  # and this pins it so that improving the detection shows up here.
  #
  # KEEP_..._ON_EXIT is set because graceful_exit() resets the cooling response
  # whatever the generation : leaving it to its default would have every server
  # send that command once on the way out, and the assertion below would then
  # hold for a Gen 14 server too, checking nothing at all.
  #
  # An R740, which the detection does recognize, is run through the same body as
  # the negative control. Without it, nothing in this test would fail if the
  # command started being sent to everyone, or to no one
  export DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE=true
  export KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT=true

  simulate_enclosure_housed_server "PowerEdge MX760c" --cpus 2
  local -r SLED_OUTPUT=$(run_controller)

  assert_contains "$SLED_OUTPUT" "Server model: DELL PowerEdge MX760c"
  if [ "$(count_ipmitool_calls_matching "raw 0x30 0xce")" -ge 1 ]; then
    pass
  else
    fail "the MX760c is detected as Gen 13 or older, so it is sent the third-party PCIe card command"
  fi

  forget_recorded_ipmitool_calls
  simulate_enclosure_housed_server "PowerEdge R740" --cpus 2
  local -r RACK_OUTPUT=$(run_controller)

  assert_contains "$RACK_OUTPUT" "Server model: DELL PowerEdge R740"
  assert_equals "0" "$(count_ipmitool_calls_matching "raw 0x30 0xce")" \
    "an R740 is detected as Gen 14 or newer, so the very same run must not send that command"
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
  # No processor entity at all means there is nothing to build a temperatures
  # table around, so the controller says so and keeps waiting for one instead of
  # printing a table whose only CPU column would never hold a reading
  assert_contains "$OUTPUT" "No CPU temperature sensor could be read" \
    "the enclosure reports no processor entity, and the controller says so"
  assert_equals "0" "$(count_ipmitool_calls_matching "raw 0x30 0x30 0x01 0x00")" \
    "manual fan control must never be enabled on readings the controller never got"
  assert_equals "0" "$(count_ipmitool_calls_matching "raw 0x30 0x30 0x02")" \
    "no fan speed must be sent either"
}
