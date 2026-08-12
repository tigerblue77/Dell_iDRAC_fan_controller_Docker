#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

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
    IFS='|' read -r _ MODEL SOCKETS _ _ <<< "$ENTRY"
    simulate_server "$MODEL" --cpus "$SOCKETS" --no-exhaust

    get_Dell_server_model
    assert_equals "$MODEL" "$SERVER_MODEL" "$MODEL should be identified"

    # A refusal settles the question for the rest of a container's life, and each of the two calls
    # below stands for the cycle that reached the command first, on another server. So the verdict is
    # reset before each of them rather than letting one model, or one code path, answer for the others
    IS_FAN_CONTROL_SUPPORTED=true
    capture_output apply_Dell_default_fan_control_profile
    assert_contains "$CAPTURED_OUTPUT" "Failed to apply Dell default fan control profile" \
      "$MODEL should report the rejected safety profile"

    IS_FAN_CONTROL_SUPPORTED=true
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

function test_an_overheating_blade_is_reported_although_nothing_here_can_cool_it() {
  # The fallback is a request the CMC refuses, and it refuses it identically on
  # every cycle : the controller asks once, is told the command is not there, and
  # from then on says why rather than repeating the same failure forever.
  # What must survive that is the news itself -- this blade is hot and nothing
  # this container does will cool it -- which is the whole reason the comment is
  # printed at all
  simulate_enclosure_housed_server "PowerEdge M640" --cpus 2 --cpu-temperatures "42 44"
  export MOCK_IPMITOOL_SDR_SECOND_OUTPUT
  MOCK_IPMITOOL_SDR_SECOND_OUTPUT=$(make_sdr_output --cpus 2 --cpu-temperatures "42 79" --no-exhaust)
  export MOCK_IPMITOOL_SDR_SWITCH_AFTER_CALLS=1

  local -r OUTPUT=$(run_controller "temperature is too high")

  assert_contains "$OUTPUT" "CPU 2 temperature is too high, and this server refused fan control" \
    "the hot CPU must still be named, and the comment must not claim a profile the CMC never applied"
  assert_contains "$OUTPUT" "This server refused fan control" \
    "the refusal must be explained once, in full"
  assert_contains "$OUTPUT" "Failed to enable manual fan control" \
    "the answer the blade actually gave must be quoted before any conclusion is drawn from it"
  assert_equals "1" "$(count_ipmitool_calls_matching "raw 0x30 0x30 0x01 0x00")" \
    "the command is sent once and not on every cycle afterwards"
  assert_equals "0" "$(count_ipmitool_calls_matching "raw 0x30 0x30 0x01 0x01")" \
    "there is nothing to hand back to Dell on fans this container was never given"
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

function test_the_controller_refuses_to_run_on_a_server_reporting_no_cpu_sensor() {
  # Every PowerEdge has at least one CPU, and an iDRAC that exposes no processor
  # entity exposes none on every check : waiting it out would leave a container
  # that looks alive and supervises nothing. It has to say so and stop, with what
  # the user needs to report the problem
  simulate_enclosure_management_controller "PowerEdge M1000e"

  local OUTPUT
  OUTPUT=$(run_controller "No CPU temperature sensor could be read")
  local -r EXIT_CODE=$?

  assert_equals 1 "$EXIT_CODE" "the container must stop rather than wait forever"
  assert_contains "$OUTPUT" "No CPU temperature sensor could be read"
  assert_contains "$OUTPUT" "every PowerEdge has at least one CPU"
  assert_contains "$OUTPUT" "sdr type temperature" "the user is told what to run"
  assert_contains "$OUTPUT" "github.com/tigerblue77/Dell_iDRAC_fan_controller_Docker/issues" \
    "and where to report it"
  # The likeliest cause by far, and the only one the user can fix themselves :
  # lm-sensors cannot rescue this one either, the fallback being local mode only
  # and the enclosure rejecting the fan control commands anyway
  assert_contains "$OUTPUT" "chassis management controller" \
    "the chassis mistake is named first, being the likeliest cause"
  assert_contains "$OUTPUT" "point it at a node's own iDRAC instead" \
    "the apostrophe must not come out escaped, the message being a double quoted string"
  assert_not_contains "$OUTPUT" "exiting.. Exiting." \
    "print_error_and_exit appends its own sentence, so the message must not end on a full stop"
}

function test_the_fans_are_handed_back_to_dell_before_refusing_to_run() {
  # A previous run of this container may have left the BMC in manual mode, in
  # which case exiting without a word would leave the fans pinned at the user's
  # low speed with nobody watching the temperatures. graceful_exit is not reached
  # on this path, the trap only covering the termination signals
  simulate_enclosure_management_controller "PowerEdge M1000e"

  run_controller "No CPU temperature sensor could be read" > /dev/null

  assert_equals "1" "$(count_ipmitool_calls_matching "raw 0x30 0x30 0x01 0x01")" \
    "Dell's own dynamic profile must be applied before exiting"
  assert_equals "0" "$(count_ipmitool_calls_matching "raw 0x30 0x30 0x02")" \
    "and no fan speed must ever be sent on readings the controller never got"
}

function test_the_refusal_never_prints_the_idrac_password() {
  # The message tells the user which ipmitool command to run, and the connection
  # string the controller uses carries -P <password> : printing it would put the
  # iDRAC password in the container logs
  export IDRAC_PASSWORD="hunter2-should-never-be-logged"
  simulate_enclosure_management_controller "PowerEdge M1000e"

  local -r OUTPUT=$(run_controller "No CPU temperature sensor could be read")

  assert_not_contains "$OUTPUT" "$IDRAC_PASSWORD" "the password must never reach the logs"
  assert_contains "$OUTPUT" "<iDRAC password>" "the command is shown with a placeholder instead"
}

function test_a_transiently_empty_sdr_read_is_waited_out_not_refused() {
  # ipmitool returning no sensor line at all says nothing about what the server
  # has : a busy BMC, a partial response or an iDRAC still coming up all produce
  # it. Concluding "this server has no CPU" on it turns a hiccup at startup into
  # a container that will not start
  export MOCK_IPMITOOL_FRU_OUTPUT
  MOCK_IPMITOOL_FRU_OUTPUT="$(make_fru_output --model "PowerEdge R730")"
  export MOCK_IPMITOOL_SDR_OUTPUT=""
  export MOCK_IPMITOOL_SDR_SECOND_OUTPUT MOCK_IPMITOOL_SDR_SWITCH_AFTER_CALLS
  MOCK_IPMITOOL_SDR_SECOND_OUTPUT=$(make_sdr_output --cpus 2 --cpu-temperatures "44 46")
  MOCK_IPMITOOL_SDR_SWITCH_AFTER_CALLS=2

  local -r OUTPUT=$(run_controller "44°C")

  assert_not_contains "$OUTPUT" "could be read from" \
    "an empty answer must never be taken for a server without a CPU"
  assert_contains "$OUTPUT" "No temperature sensor could be read at all" \
    "the container says what it is waiting on instead of going quiet"
  assert_contains "$OUTPUT" "2 CPU temperature sensors detected (entities 3.1 3.2)." \
    "and picks the CPUs up on the cycle they answer"
  assert_contains "$OUTPUT" "44°C" "then monitors them normally"
}

function test_the_refusal_still_fires_on_a_server_that_did_answer_with_sensors() {
  # The counterpart : the verdict is about a server that listed its sensors and
  # had no CPU among them, which stays a fault to report on the first answer
  simulate_enclosure_management_controller "PowerEdge M1000e"

  local OUTPUT
  OUTPUT=$(run_controller "could be read from")
  local -r EXIT_CODE=$?

  assert_equals 1 "$EXIT_CODE"
  assert_contains "$OUTPUT" "No CPU temperature sensor could be read from DELL PowerEdge M1000e"
}

function test_monitoring_only_mode_is_exempt_from_the_refusal() {
  # The refusal exists because a container that cannot read a CPU cannot decide a
  # fan speed. Monitoring only mode decides no fan speed to begin with : a CPU it
  # cannot read costs it a column, while the chassis sensors it can read are the
  # whole reason it was started. Refusing there would take away the one mode that
  # still has something to do on such a server
  export MONITORING_ONLY_MODE=true
  simulate_enclosure_management_controller "PowerEdge M1000e"

  local -r OUTPUT=$(run_controller)

  assert_not_contains "$OUTPUT" "No CPU temperature sensor could be read from" \
    "this mode must not be refused"
  assert_contains "$OUTPUT" "No CPU temperature sensor detected, only the chassis temperatures will be monitored." \
    "it says what it will monitor instead"
  assert_matches "$OUTPUT" 'Date & time      Inlet  Exhaust' \
    "and prints the table with no CPU column between the inlet and the exhaust"
  assert_matches "$OUTPUT" '[[:space:]]22°C[[:space:]]+-°C[[:space:]]' \
    "with the inlet reading the enclosure does report, and the exhaust it does not"
  assert_equals "0" "$(count_ipmitool_calls_matching "raw 0x30 0x30")" \
    "and still sends no fan control command at all"
}

function test_the_refusal_points_at_monitoring_only_mode() {
  # The mode above is the way out for a user whose server genuinely reports no
  # CPU : the refusal has to name it, or they are left with a container that only
  # ever exits
  simulate_enclosure_management_controller "PowerEdge M1000e"

  local -r OUTPUT=$(run_controller "No CPU temperature sensor could be read")

  assert_contains "$OUTPUT" "Set MONITORING_ONLY_MODE=true" \
    "the refusal must offer the mode that still works on such a server"
}
