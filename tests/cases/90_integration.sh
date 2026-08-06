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
  assert_contains "$OUTPUT" "Check interval: 60s"
  assert_contains "$OUTPUT" "CPU 1  CPU 2 " "a dual CPU server gets two CPU columns"
  assert_contains "$OUTPUT" "User static fan control profile (5%)"
  assert_contains "$OUTPUT" "CPU temperature decreased and is now OK (<= 50°C), user's fan control profile applied."
  assert_not_contains "$OUTPUT" "temperature is too high" "cold CPUs must never trigger the safety profile"
  assert_equals "1" "$(count_ipmitool_calls_matching "raw 0x30 0x30 0x01 0x01")" \
    "Dell's dynamic profile is only applied once, when the container is stopped"
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

  assert_contains "$OUTPUT" "No CPU2 temperature sensor detected."
  assert_contains "$OUTPUT" "Inlet  CPU 1  Exhaust" "a single CPU server gets a single CPU column"
  assert_not_contains "$OUTPUT" "CPU 2 "
}

function test_the_controller_reports_a_quad_cpu_server() {
  # An R930 also exercises the CPU sensor IDs (09h, 0Ah...) that used to be
  # mistaken for temperature readings
  simulate_server "PowerEdge R930" --cpus 4 --cpu-temperatures "41 40 39 38" --cpu-sensor-id-base 9

  local -r OUTPUT=$(run_controller)

  assert_contains "$OUTPUT" "Server model: DELL PowerEdge R930"
  assert_contains "$OUTPUT" "CPU 1  CPU 2  Exhaust" "only the first two CPUs are monitored today"
  assert_not_contains "$OUTPUT" "CPU 3 "
  assert_contains "$OUTPUT" " 41°C   40°C" "the readings must not be shifted by the two-digit sensor IDs"
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

function test_the_controller_leaves_the_third_party_pcie_card_setting_alone_on_gen_14_and_newer() {
  # The Dell OEM command does not exist on Gen 14+, sending it would only produce
  # a rejection on every single cycle.
  # KEEP_..._ON_EXIT is set so that the graceful exit does not send that same
  # command itself : it resets the cooling response whatever the generation, so
  # leaving it to its default would hide what this test is about
  export DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE=true
  export KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT=true
  simulate_server "PowerEdge R740xd" --cpus 2

  local -r OUTPUT=$(run_controller)

  assert_contains "$OUTPUT" "Server model: DELL PowerEdge R740xd"
  assert_equals "0" "$(count_ipmitool_calls_matching "raw 0x30 0xce")"
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
  assert_contains "$OUTPUT" "Could not establish IPMI connection"
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
