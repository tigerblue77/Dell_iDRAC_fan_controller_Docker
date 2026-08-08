#!/bin/bash

# The whole controller, started exactly like its Docker image does, against a
# mocked iDRAC. Each test case describes one server and reads back what the user
# would see in "docker logs", then stops the container with SIGTERM like
# "docker stop" does.

function test_the_controller_applies_the_user_fan_control_profile_on_a_healthy_server() {
  simulate_server "PowerEdge R730xd" --cpus 2 --cpu-temperatures "42 44" --inlet 21 --exhaust 34

  local -r OUTPUT=$(run_controller)

  assert_contains "$OUTPUT" "Server model: DELL PowerEdge R730xd"
  assert_contains "$OUTPUT" "Fan speed objective: 5%"
  assert_contains "$OUTPUT" "CPU temperature threshold: 50°C"
  assert_contains "$OUTPUT" "Check interval: 5s"
  assert_contains "$OUTPUT" "CPU 1  CPU 2 " "a dual CPU server gets two CPU columns"
  assert_contains "$OUTPUT" "User static fan control profile (5%)"
  assert_contains "$OUTPUT" "All CPU temperatures are now OK (<= 50°C), user's fan control profile applied."
  assert_not_contains "$OUTPUT" "temperature is too high" "cold CPUs must never trigger the safety profile"
  assert_equals "1" "$(count_ipmitool_calls_matching "raw 0x30 0x30 0x01 0x01")" \
    "Dell's dynamic profile is only applied once, when the container is stopped"
}

function test_the_very_first_line_says_when_the_server_started_out_hot() {
  # A server already above its threshold when the container starts. The comment
  # column explains a profile CHANGE, and the first cycle changes nothing -- it
  # establishes the profile -- so this stayed silent : Dell's profile applied, and
  # a bare "-" where the reason belongs.
  #
  # The neighbouring case, a server with no readable CPU sensor at all, is already
  # covered by the startup waiting path and is deliberately not retested here : it
  # passes with or without this change, so asserting on it would prove nothing
  simulate_server "PowerEdge R730xd" --cpus 2 --cpu-temperatures "80 41"

  local -r OUTPUT=$(run_controller)

  assert_contains "$OUTPUT" "CPU 1 temperature is too high, Dell default dynamic fan control profile applied for safety"
}

function test_the_very_first_line_still_explains_a_healthy_start() {
  # The branch that already spoke must keep speaking : the fix must not trade one
  # silence for another
  simulate_server "PowerEdge R730xd" --cpus 2 --cpu-temperatures "40 41"

  local -r OUTPUT=$(run_controller)

  assert_contains "$OUTPUT" "user's fan control profile applied."
}

function test_the_explanation_is_printed_once_not_on_every_cycle() {
  # It explains a change, so a server that stays hot must not repeat it forever :
  # that would be the log spam the comment column exists to avoid.
  #
  # The second cycle reports a different reading, still above the threshold, so
  # the harness has a positive signal to wait for. Waiting for the message NOT to
  # reappear would mean waiting for the poll budget to run out -- eight seconds
  # per run, and a test whose meaning depends on a timeout rather than on output
  simulate_server "PowerEdge R730xd" --cpus 2 --cpu-temperatures "80 41"
  export MOCK_IPMITOOL_SDR_SECOND_OUTPUT
  MOCK_IPMITOOL_SDR_SECOND_OUTPUT=$(make_sdr_output --cpus 2 --cpu-temperatures "81 41")
  export MOCK_IPMITOOL_SDR_SWITCH_AFTER_CALLS=1

  local -r OUTPUT=$(run_controller "81°C")

  assert_contains "$OUTPUT" "81°C" "the second cycle must have been reached"
  assert_equals "1" "$(printf '%s' "$OUTPUT" | grep -c "CPU 1 temperature is too high")" \
    "the reason is stated on the cycle that established the profile, then not again"
}

function test_the_controller_falls_back_on_the_dell_default_profile_when_a_cpu_starts_overheating() {
  # Cold CPUs on the first cycle, CPU 2 above the threshold from the second one :
  # the profile change is what the user must see in the logs
  simulate_server "PowerEdge R730xd" --cpus 2 --cpu-temperatures "42 44"
  export MOCK_IPMITOOL_SDR_SECOND_OUTPUT
  MOCK_IPMITOOL_SDR_SECOND_OUTPUT=$(make_sdr_output --cpus 2 --cpu-temperatures "42 78")
  export MOCK_IPMITOOL_SDR_SWITCH_AFTER_CALLS=1

  local -r OUTPUT=$(run_controller "temperature is too high")

  assert_contains "$OUTPUT" "CPU 2 temperature is too high, Dell default dynamic fan control profile applied for safety"
  assert_contains "$OUTPUT" "Dell default dynamic fan control profile"
  if [ "$(count_ipmitool_calls_matching "raw 0x30 0x30 0x01 0x01")" -ge 1 ]; then
    pass
  else
    fail "Dell's dynamic fan control profile should have been applied to the overheating server"
  fi
}

function test_the_comment_closing_a_fallback_says_the_temperatures_are_ok_not_that_they_decreased() {
  # Symmetric with the clause naming the CPUs that opened the fallback, plural
  # included. It states that the temperatures are OK rather than that they
  # decreased, because the Dell default profile is also applied when a reading
  # cannot be parsed at all : on that path nothing ever went up, so claiming
  # something came back down would contradict the "could not be read" comment
  # printed when it happened, and send the user looking for a heat problem they
  # never had
  simulate_server "PowerEdge R730xd" --cpus 2 --cpu-temperatures "81 78"
  export MOCK_IPMITOOL_SDR_SECOND_OUTPUT
  MOCK_IPMITOOL_SDR_SECOND_OUTPUT=$(make_sdr_output --cpus 2 --cpu-temperatures "42 44")
  export MOCK_IPMITOOL_SDR_SWITCH_AFTER_CALLS=1

  local -r OUTPUT=$(run_controller "now OK")

  assert_contains "$OUTPUT" " 81°C   78°C     34°C  Dell default dynamic fan control profile" \
    "the hot reading must keep the server on Dell's profile"
  assert_contains "$OUTPUT" "All CPU temperatures are now OK (<= 50°C), user's fan control profile applied."
  assert_not_contains "$OUTPUT" "decreased" "a reading that was never obtained cannot have decreased"
}

function test_the_comment_closing_a_fallback_is_written_in_the_singular_on_a_single_cpu_server() {
  simulate_server "PowerEdge R230" --cpus 1 --cpu-temperatures "81"
  export MOCK_IPMITOOL_SDR_SECOND_OUTPUT
  MOCK_IPMITOOL_SDR_SECOND_OUTPUT=$(make_sdr_output --cpus 1 --cpu-temperatures "42")
  export MOCK_IPMITOOL_SDR_SWITCH_AFTER_CALLS=1

  local -r OUTPUT=$(run_controller "now OK")

  assert_contains "$OUTPUT" "CPU temperature is now OK (<= 50°C), user's fan control profile applied."
  assert_not_contains "$OUTPUT" "All CPU temperatures" "a server with one CPU has nothing to write in the plural"
}

function test_the_controller_explains_a_fallback_caused_by_a_sensor_that_dropped_out() {
  # The real-world case behind the fallback comment : the server is fine, one
  # sensor simply stopped answering mid-run. The fans ramp up either way, so the
  # log line is the only thing telling the user which of the two happened
  simulate_server "PowerEdge R730xd" --cpus 2 --cpu-temperatures "42 44"
  export MOCK_IPMITOOL_SDR_SECOND_OUTPUT
  MOCK_IPMITOOL_SDR_SECOND_OUTPUT=$(make_sdr_output --cpus 2 --cpu2-disabled --cpu-temperatures "42")
  export MOCK_IPMITOOL_SDR_SWITCH_AFTER_CALLS=1

  local -r OUTPUT=$(run_controller "could not be read")

  assert_contains "$OUTPUT" "CPU 2 temperature could not be read, Dell default dynamic fan control profile applied for safety"
  assert_not_contains "$OUTPUT" "CPU 2 temperature is too high" \
    "a sensor that stopped answering is not an overheating CPU"
  if [ "$(count_ipmitool_calls_matching "raw 0x30 0x30 0x01 0x01")" -ge 1 ]; then
    pass
  else
    fail "the controller must still hand the fans back to Dell on an unreadable reading"
  fi
}

function test_the_controller_reports_both_cpus_when_they_are_overheating_together() {
  simulate_server "PowerEdge R630" --cpus 2 --cpu-temperatures "42 44"
  export MOCK_IPMITOOL_SDR_SECOND_OUTPUT
  MOCK_IPMITOOL_SDR_SECOND_OUTPUT=$(make_sdr_output --cpus 2 --cpu-temperatures "81 78")
  export MOCK_IPMITOOL_SDR_SWITCH_AFTER_CALLS=1

  local -r OUTPUT=$(run_controller "temperatures are too high")

  assert_contains "$OUTPUT" "CPU 1 and CPU 2 temperatures are too high, Dell default dynamic fan control profile applied for safety"
}

function test_the_controller_reports_a_single_cpu_server() {
  simulate_server "PowerEdge R230" --cpus 1 --cpu-temperatures "38"

  local -r OUTPUT=$(run_controller)

  assert_contains "$OUTPUT" "1 CPU temperature sensor detected (entity 3.1)."
  assert_contains "$OUTPUT" "Inlet  CPU 1  Exhaust" "a single CPU server gets a single CPU column"
  assert_not_contains "$OUTPUT" "CPU 2 "
}

function test_the_controller_reports_a_quad_cpu_server() {
  # An R930 also exercises the CPU sensor IDs (09h, 0Ah...) that used to be
  # mistaken for temperature readings
  simulate_server "PowerEdge R930" --cpus 4 --cpu-temperatures "41 40 39 38" --cpu-sensor-id-base 9

  local -r OUTPUT=$(run_controller)

  assert_contains "$OUTPUT" "Server model: DELL PowerEdge R930"
  assert_contains "$OUTPUT" "4 CPU temperature sensors detected (entities 3.1 3.2 3.3 3.4)."
  assert_contains "$OUTPUT" "CPU 1  CPU 2  CPU 3  CPU 4  Exhaust" "all four sockets get their own column"
  assert_contains "$OUTPUT" " 41°C   40°C   39°C   38°C" "the readings must not be shifted by the two-digit sensor IDs"
}

function test_the_controller_reports_a_server_without_an_exhaust_sensor() {
  simulate_server "PowerEdge R720" --cpus 2 --no-exhaust

  local -r OUTPUT=$(run_controller)

  assert_contains "$OUTPUT" "No exhaust temperature sensor detected."
  assert_contains "$OUTPUT" "User static fan control profile (5%)" "a missing sensor must not stop the fan control"
}

function test_the_controller_manages_the_third_party_pcie_card_setting_on_gen_13_and_older() {
  export DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE=true
  simulate_server "PowerEdge R730xd" --cpus 2

  local -r OUTPUT=$(run_controller)

  assert_contains "$OUTPUT" "Third-party PCIe card Dell default cooling response"
  assert_contains "$OUTPUT" "Disabled"
  if [ "$(count_ipmitool_calls_matching "raw 0x30 0xce")" -ge 1 ]; then
    pass
  else
    fail "a Gen 13 server must be sent the third-party PCIe card cooling response command"
  fi
}

function test_the_controller_stops_sending_a_command_the_server_refused() {
  # A Gen 14+ server has no third-party PCIe card cooling response to set, and
  # says so. The controller must ask once, believe the answer, and never ask
  # again -- however Dell named the model. An R6515 is a Gen 15 AMD server whose
  # name carries nothing a pattern could recognize, which is exactly why the
  # question is put to the server rather than to its name (issue #173)
  export DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE=true
  simulate_server "PowerEdge R6515" --cpus 1
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0xce"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="Unable to send RAW command (channel=0x0 netfn=0x30 lun=0x0 cmd=0xce rsp=0xc1): Invalid command"

  # Wait for five table lines, well past the point where the controller gives up,
  # so that a command still being re-sent would show up in the call log
  local -r OUTPUT=$(run_controller "" 5)

  assert_contains "$OUTPUT" "Server model: DELL PowerEdge R6515"
  assert_matches "$OUTPUT" "fan control profile.*Not supported by this server" \
    "rsp=0xc1 is the BMC saying it does not have the command, which settles it on the first try"
  # The one asked on the first cycle, plus the one graceful_exit sends on the way
  # out. That last one is deliberately NOT gated on the conclusion : one refused
  # command on the way out costs nothing, a setting left behind on a server
  # nothing monitors any more does
  assert_equals "2" "$(count_ipmitool_calls_matching "raw 0x30 0xce")" \
    "an answered refusal settles it, so the command is never sent again"
}

function test_a_transient_ipmi_failure_does_not_disable_the_cooling_response_for_good() {
  # ipmitool exits non-zero both for a command the BMC does not implement and for
  # a BMC it could not reach. Only the completion code it prints tells the two
  # apart, and an unreachable iDRAC prints none : an iDRAC being reset or a
  # momentary network glitch must not permanently disable the setting on a
  # perfectly healthy server and make the column report the opposite of reality —
  # exactly the defect this whole change exists to remove
  export DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE=true
  simulate_server "PowerEdge R730xd" --cpus 2
  # Refuse the very first cooling response command, then answer normally
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0xce"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="Error: Unable to establish IPMI v2 / RMCP+ session"
  export MOCK_IPMITOOL_RAW_FAIL_ONLY_ONCE=true

  local -r OUTPUT=$(run_controller "" 4)

  assert_matches "$OUTPUT" "fan control profile.*Disabled" \
    "the server recovered, so the setting must be applied and reported again"
  assert_not_contains "$OUTPUT" "Not supported by this server" \
    "one glitch is not a verdict"
  if [ "$(count_ipmitool_calls_matching "raw 0x30 0xce")" -ge 4 ]; then
    pass
  else
    fail "the controller must keep sending the command after a transient refusal" \
      "calls: $(recorded_ipmitool_calls)"
  fi
}

function test_an_unreachable_idrac_never_becomes_a_verdict_however_long_it_lasts() {
  # The counting version of this decision gave up after a fixed number of cycles,
  # so a long enough outage concluded "Not supported by this server" on a server
  # that supports it perfectly well. Reading the completion code removes the
  # deadline entirely : no answer, no verdict, however many cycles go by
  export DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE=true
  simulate_server "PowerEdge R730xd" --cpus 2
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0xce"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="Error: Unable to establish IPMI v2 / RMCP+ session"

  local -r OUTPUT=$(run_controller "" 6)

  assert_not_contains "$OUTPUT" "Not supported by this server" \
    "nothing answered, so there is nothing to conclude"
  assert_matches "$OUTPUT" "fan control profile.*Could not be applied on this cycle" \
    "the column reports the cycle that failed, without drawing a conclusion from it"
  if [ "$(count_ipmitool_calls_matching "raw 0x30 0xce")" -ge 6 ]; then
    pass
  else
    fail "the command must keep being retried while the iDRAC is unreachable" \
      "calls: $(recorded_ipmitool_calls)"
  fi
}

function test_the_controller_keeps_applying_a_command_the_server_accepts() {
  # The other side of the same decision : a server that takes the command must
  # keep being sent it on every cycle, and the table must show the user's setting
  export DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE=true
  simulate_server "PowerEdge R730xd" --cpus 2

  local -r OUTPUT=$(run_controller "" 2)

  assert_matches "$OUTPUT" "fan control profile.*Disabled" "the Gen 13 server took the command"
  assert_not_contains "$OUTPUT" "Not supported by this server"
  if [ "$(count_ipmitool_calls_matching "raw 0x30 0xce")" -ge 2 ]; then
    pass
  else
    fail "a server that accepts the command should be sent it on every cycle" \
      "calls: $(recorded_ipmitool_calls)"
  fi
}

function test_the_controller_survives_a_recent_server_that_rejects_the_fan_control_commands() {
  # A Gen 16 server : its iDRAC 9 firmware no longer accepts the raw fan control
  # commands. The controller must say so and keep monitoring, not crash
  simulate_server "PowerEdge R760" --cpus 2 --cpu-temperatures "45 46"
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0x30"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="Unable to send RAW command (channel=0x0 netfn=0x30 lun=0x0 cmd=0x30 rsp=0xd5): Command not supported in present state"

  local -r OUTPUT=$(run_controller)

  assert_contains "$OUTPUT" "Server model: DELL PowerEdge R760"
  assert_contains "$OUTPUT" "Failed to enable manual fan control"
  assert_contains "$OUTPUT" "Command not supported in present state"
  assert_contains "$OUTPUT" "45°C" "the temperatures must still be monitored and logged"
}

function test_the_controller_refuses_to_run_on_a_server_that_is_not_a_dell() {
  export MOCK_IPMITOOL_FRU_OUTPUT
  MOCK_IPMITOOL_FRU_OUTPUT=$(make_fru_output --manufacturer "Supermicro" --model "Super Server X11DPi-N")

  local OUTPUT
  OUTPUT=$(run_controller)
  local -r EXIT_CODE=$?

  assert_equals 1 "$EXIT_CODE"
  assert_contains "$OUTPUT" "Your server isn't a Dell product"
  assert_equals "0" "$(count_ipmitool_calls_matching "raw 0x30")" \
    "no fan control command must ever reach a non-Dell server"
}

function test_the_controller_stops_when_the_ipmi_connection_cannot_be_established() {
  export MOCK_IPMITOOL_FRU_EXIT_CODE=1
  export MOCK_IPMITOOL_FRU_OUTPUT="Error: Unable to establish IPMI v2 / RMCP+ session"

  local OUTPUT
  OUTPUT=$(run_controller)
  local -r EXIT_CODE=$?

  assert_equals 1 "$EXIT_CODE"
  assert_contains "$OUTPUT" "the container will not start" "the error should say the container is refusing to start"
  assert_contains "$OUTPUT" "192.168.1.100" "the error should name the host that could not be reached"
}

function test_the_controller_skips_the_cycle_when_the_target_server_is_powered_off() {
  simulate_server "PowerEdge R740" --cpus 2
  export MOCK_IPMITOOL_POWER_STATUS="Chassis Power is off"

  # A powered off server never gets a temperature line, so the cycle it does
  # print is what tells the harness the controller reached its steady state
  local -r OUTPUT=$(run_controller "Target server is powered off, no fan control profile applied\.")

  assert_contains "$OUTPUT" "Target server is powered off, no fan control profile applied."
  assert_equals "0" "$(count_ipmitool_calls_matching "raw 0x30 0x30 0x01 0x00")" \
    "manual fan control must not be enabled on a powered off server"
  assert_equals "0" "$(count_ipmitool_calls_matching "raw 0x30 0x30 0x02")" \
    "no fan speed must be sent to a powered off server"
  assert_not_contains "$OUTPUT" "User static fan control profile" \
    "no temperature line must be printed for a server that is off"
}

function test_monitoring_only_mode_never_touches_the_fans() {
  export MONITORING_ONLY_MODE=true
  simulate_server "PowerEdge R640" --cpus 2 --cpu-temperatures "42 78"

  local -r OUTPUT=$(run_controller)

  assert_contains "$OUTPUT" "Monitoring only mode: Enabled"
  assert_contains "$OUTPUT" "monitoring only, not applied"
  assert_contains "$OUTPUT" "78°C" "the temperatures must still be logged"
  assert_equals "0" "$(count_ipmitool_calls_matching "raw 0x30")" \
    "not a single command may be sent in monitoring only mode, even for an overheating CPU"
}

function test_a_fan_speed_given_in_hexadecimal_is_logged_as_a_percentage() {
  export FAN_SPEED=0x1e
  simulate_server "PowerEdge R730" --cpus 2

  local -r OUTPUT=$(run_controller)

  assert_contains "$OUTPUT" "Fan speed objective: 30%"
  assert_contains "$OUTPUT" "User static fan control profile (30%)"
  if [ "$(count_ipmitool_calls_matching "raw 0x30 0x30 0x02 0xff 0x1e")" -ge 1 ]; then
    pass
  else
    fail "the hexadecimal speed should reach ipmitool untouched" "calls: $(recorded_ipmitool_calls)"
  fi
}

function test_stopping_the_container_restores_dells_profile_whatever_the_generation() {
  # SIGTERM is what "docker stop" sends : whichever generation it runs on, the
  # container must hand the fans back to the server before leaving
  local MODEL
  for MODEL in "PowerEdge 2950" "PowerEdge R710" "PowerEdge R730xd" "PowerEdge R740" "PowerEdge R760" "PowerEdge R770"; do
    forget_recorded_ipmitool_calls
    simulate_server "$MODEL" --cpus 2

    local OUTPUT
    OUTPUT=$(run_controller)

    assert_contains "$OUTPUT" "Container stopped, Dell default dynamic fan control profile applied for safety" \
      "$MODEL should hand the fans back on exit"
    if [ "$(count_ipmitool_calls_matching "raw 0x30 0x30 0x01 0x01")" -ge 1 ]; then
      pass
    else
      fail "$MODEL should be sent Dell's dynamic fan control profile on exit"
    fi
  done
}

function test_a_removed_cpu_is_reported_as_removed_and_not_merely_as_silent() {
  # The decision is deterministic, so the line has to say what the controller
  # concluded and the rule it applied, not just that a sensor went quiet : a
  # sensor going quiet is not a reason to stop watching a CPU, a CPU being gone
  # is. The CPUs are named with the labels their columns carried until then,
  # which is what the reader has just been looking at.
  # Removals are only concluded across a power cycle, so the server is switched
  # off and back on with two CPUs fewer, and the smaller set is then confirmed by
  # a second reading
  simulate_server "PowerEdge R930" --cpus 4 --cpu-temperatures "41 40 39 38"
  export MOCK_IPMITOOL_POWER_STATUS_SEQUENCE MOCK_IPMITOOL_SDR_SECOND_OUTPUT MOCK_IPMITOOL_SDR_SWITCH_AFTER_CALLS
  MOCK_IPMITOOL_POWER_STATUS_SEQUENCE="on on off on"
  MOCK_IPMITOOL_SDR_SECOND_OUTPUT=$(make_sdr_output --cpus 2 --cpu-temperatures "41 40")
  MOCK_IPMITOOL_SDR_SWITCH_AFTER_CALLS=2

  local -r OUTPUT=$(run_controller "considered removed")

  assert_contains "$OUTPUT" "CPU 3 and CPU 4 are considered removed from the server" \
    "the line must state the conclusion, with the labels the table was showing"
  assert_contains "$OUTPUT" "(entities 3.3 and 3.4)" \
    "and the entities, so the line can be matched against an ipmitool output"
  assert_contains "$OUTPUT" "2 CPU temperature sensors detected (entities 3.1 3.2)."
}
