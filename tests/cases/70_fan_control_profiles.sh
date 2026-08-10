#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# The commands actually sent to the server, and what happens when the server
# refuses them - which is the normal situation on an iDRAC 9 running firmware
# 3.30.30.30 or newer (Gen 15, 16) and on the iDRAC 10 of a Gen 17 server, where
# Dell removed the IPMI raw fan control commands altogether.
#
# Applying a fan control profile is the one thing the controller exists for, so
# a silent failure here is the worst possible outcome : the user believes their
# fans are quiet while the server actually runs on whatever profile it had.

readonly MANUAL_FAN_CONTROL_COMMAND="raw 0x30 0x30 0x01 0x00"
readonly FAN_SPEED_COMMAND="raw 0x30 0x30 0x02 0xff"
readonly DELL_DEFAULT_FAN_CONTROL_COMMAND="raw 0x30 0x30 0x01 0x01"
readonly THIRD_PARTY_PCIE_CARD_COMMAND="raw 0x30 0xce 0x00 0x16 0x05"

# What an iDRAC 9 running firmware >= 3.30.30.30 answers to a fan control command
readonly REJECTED_BY_FIRMWARE_STDERR="Unable to send RAW command (channel=0x0 netfn=0x30 lun=0x0 cmd=0x30 rsp=0xd5): Command not supported in present state"

# What a BMC answers when the command exists but the account may not run it. Reported on an R550 in
# issue #29, where every raw command answered "Insufficient privilege level"
readonly REFUSED_FOR_PRIVILEGE_STDERR="Unable to send RAW command (channel=0x0 netfn=0x30 lun=0x0 cmd=0xce rsp=0xd4): Insufficient privilege level"

function test_the_user_fan_control_profile_enables_manual_control_then_sets_the_speed() {
  DECIMAL_FAN_SPEED=30
  HEXADECIMAL_FAN_SPEED="0x1e"

  apply_user_fan_control_profile

  assert_equals "1" "$(count_ipmitool_calls_matching "$MANUAL_FAN_CONTROL_COMMAND")" \
    "manual fan control must be enabled first"
  assert_equals "1" "$(count_ipmitool_calls_matching "$FAN_SPEED_COMMAND 0x1e")" \
    "the speed must be sent as the hexadecimal byte, applied to every fan (0xff)"
  assert_equals "0" "$(count_ipmitool_calls_matching "$DELL_DEFAULT_FAN_CONTROL_COMMAND")"
  assert_equals "User static fan control profile (30%)" "$CURRENT_FAN_CONTROL_PROFILE" \
    "the table shows the percentage, not the hexadecimal byte"
}

function test_the_dell_default_fan_control_profile_has_its_own_raw_command() {
  apply_Dell_default_fan_control_profile

  assert_equals "1" "$(count_ipmitool_calls_matching "$DELL_DEFAULT_FAN_CONTROL_COMMAND")"
  assert_equals "0" "$(count_ipmitool_calls_matching "$MANUAL_FAN_CONTROL_COMMAND")"
  assert_equals "Dell default dynamic fan control profile" "$CURRENT_FAN_CONTROL_PROFILE"
}

function test_monitoring_only_mode_never_sends_a_fan_control_command() {
  export MONITORING_ONLY_MODE=true

  apply_user_fan_control_profile
  assert_contains "$CURRENT_FAN_CONTROL_PROFILE" "not applied" "the table must say the profile was not applied"
  assert_contains "$CURRENT_FAN_CONTROL_PROFILE" "User static fan control profile (5%)"

  apply_Dell_default_fan_control_profile
  assert_contains "$CURRENT_FAN_CONTROL_PROFILE" "not applied"
  assert_contains "$CURRENT_FAN_CONTROL_PROFILE" "Dell default dynamic fan control profile"

  assert_equals "0" "$(count_ipmitool_calls_matching "raw 0x30 0x30")" \
    "monitoring only mode must not send a single fan control command"
}

function test_harmless_firmware_noise_is_not_reported_when_the_command_succeeds() {
  # Some iDRAC firmwares print a protocol warning on stderr even when the command
  # worked : reporting it on every cycle floods the logs for nothing (issue #96)
  export MOCK_IPMITOOL_RAW_STDERR="Received an Unexpected message"
  export MOCK_IPMITOOL_RAW_EXIT_CODE=0

  capture_output apply_user_fan_control_profile

  assert_empty "$CAPTURED_OUTPUT" "a successful command must stay silent even when the firmware talks"
  assert_equals "User static fan control profile (5%)" "$CURRENT_FAN_CONTROL_PROFILE"
}

function test_a_rejected_manual_fan_control_command_is_reported() {
  # A Gen 15/16/17 server, or a Gen 14 whose firmware was updated past 3.30.30.30
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0x30 0x01 0x00"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="$REJECTED_BY_FIRMWARE_STDERR"

  local OUTPUT
  OUTPUT=$(apply_user_fan_control_profile 2>&1)

  assert_contains "$OUTPUT" "Failed to enable manual fan control" \
    "the user must be told their fans are not under the controller's control"
  assert_contains "$OUTPUT" "Command not supported in present state" \
    "the error must quote what ipmitool said, it is the only clue about the firmware"
}

function test_a_rejected_fan_speed_command_is_reported_with_the_requested_speed() {
  DECIMAL_FAN_SPEED=30
  HEXADECIMAL_FAN_SPEED="0x1e"
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0x30 0x02"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="$REJECTED_BY_FIRMWARE_STDERR"

  local OUTPUT
  OUTPUT=$(apply_user_fan_control_profile 2>&1)

  assert_contains "$OUTPUT" "Failed to set fan speed to 30%"
  assert_contains "$OUTPUT" "Command not supported in present state"
  assert_not_contains "$OUTPUT" "Failed to enable manual fan control" \
    "only the command that actually failed should be reported"
}

function test_a_rejected_dell_default_command_is_reported() {
  # The safety profile : failing to apply it must be as loud as possible
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0x30 0x01 0x01"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="$REJECTED_BY_FIRMWARE_STDERR"

  local OUTPUT
  OUTPUT=$(apply_Dell_default_fan_control_profile 2>&1)

  assert_contains "$OUTPUT" "Failed to apply Dell default fan control profile"
  assert_contains "$OUTPUT" "Command not supported in present state"
}

function test_every_recent_generation_that_rejects_the_commands_is_reported_the_same_way() {
  # Gen 15, 16 and 17 servers : their firmware answers "Command not supported in
  # present state" to the fan control commands. Whatever the model, the
  # controller must identify the server, then report a readable error rather
  # than crash or silently pretend the profile was applied
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0x30"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="$REJECTED_BY_FIRMWARE_STDERR"

  local ENTRY MODEL SOCKETS
  while IFS= read -r ENTRY; do
    IFS='|' read -r _ MODEL SOCKETS _ _ <<< "$ENTRY"
    simulate_server "$MODEL" --cpus "$SOCKETS"

    get_Dell_server_model
    assert_equals "$MODEL" "$SERVER_MODEL" "$MODEL should be identified"

    capture_output apply_Dell_default_fan_control_profile
    assert_contains "$CAPTURED_OUTPUT" "Failed to apply Dell default fan control profile" \
      "$MODEL should report the rejected safety profile"

    capture_output apply_user_fan_control_profile
    assert_contains "$CAPTURED_OUTPUT" "Failed to enable manual fan control" \
      "$MODEL should report the rejected user profile"
  done < <(catalogue_entries_with_fan_control_support "unsupported")
}

function test_the_third_party_pcie_card_cooling_response_is_toggled_with_dells_oem_command() {
  enable_third_party_PCIe_card_Dell_default_cooling_response
  assert_equals "1" "$(count_ipmitool_calls_matching "$THIRD_PARTY_PCIE_CARD_COMMAND 0x00 0x00 0x00 0x05 0x00 0x00 0x00 0x00")" \
    "enabling sends the Dell default cooling response payload"

  forget_recorded_ipmitool_calls

  disable_third_party_PCIe_card_Dell_default_cooling_response
  assert_equals "1" "$(count_ipmitool_calls_matching "$THIRD_PARTY_PCIE_CARD_COMMAND 0x00 0x00 0x00 0x05 0x00 0x01 0x00 0x00")" \
    "disabling only differs by one byte"
}

function test_an_unsupported_third_party_pcie_card_command_stays_silent() {
  # On a Gen 14+ server, or on hardware that never supported this Dell OEM
  # command, it fails the exact same way on every single cycle : reporting it
  # would flood the logs with a permanent, non-actionable error
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0xce"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="Unable to send RAW command (channel=0x0 netfn=0x30 lun=0x0 cmd=0xce rsp=0xc1): Invalid command"

  capture_output enable_third_party_PCIe_card_Dell_default_cooling_response
  assert_empty "$CAPTURED_OUTPUT" "an unsupported enable command must not flood the logs"

  capture_output disable_third_party_PCIe_card_Dell_default_cooling_response
  assert_empty "$CAPTURED_OUTPUT" "an unsupported disable command must not flood the logs"
}

function test_a_privilege_refusal_is_told_apart_from_a_command_the_server_does_not_have() {
  # Two answers that both come from the BMC and both stop the command being sent, but that mean
  # opposite things to whoever reads the table. 0xc1 and 0xd5 say the server has no such command ;
  # 0xd4 says it has it and this account may not run it. Reporting the second as the first sends a
  # user to check hardware that is fine instead of the iDRAC account they can actually change
  local -r LACKS_IT="Unable to send RAW command (channel=0x0 netfn=0x30 lun=0x0 cmd=0xce rsp=0xc1): Invalid command"

  assert_command_succeeds "0xc1 is the server saying it does not have the command" \
    does_the_server_lack_this_command "$LACKS_IT"
  assert_command_fails "0xc1 is not a privilege problem" \
    does_the_command_need_a_higher_privilege_level "$LACKS_IT"

  assert_command_succeeds "0xd4 is the account lacking the privilege level" \
    does_the_command_need_a_higher_privilege_level "$REFUSED_FOR_PRIVILEGE_STDERR"
  assert_command_fails "0xd4 must never be read as the server lacking the command" \
    does_the_server_lack_this_command "$REFUSED_FOR_PRIVILEGE_STDERR"

  # And neither of them is a verdict, so that the command keeps being retried
  local -r NEVER_REACHED="Error: Unable to establish IPMI v2 / RMCP+ session"
  assert_command_fails "a BMC that was never reached said nothing about the command" \
    does_the_server_lack_this_command "$NEVER_REACHED"
  assert_command_fails "nor about the privilege level" \
    does_the_command_need_a_higher_privilege_level "$NEVER_REACHED"
}

function test_monitoring_only_mode_never_changes_the_third_party_pcie_card_cooling_response() {
  export MONITORING_ONLY_MODE=true

  enable_third_party_PCIe_card_Dell_default_cooling_response
  disable_third_party_PCIe_card_Dell_default_cooling_response

  assert_equals "0" "$(count_ipmitool_calls_matching "raw 0x30 0xce")"
}

function test_stopping_the_container_restores_the_dell_default_fan_control_profile() {
  # Without this, stopping the container would leave the server running forever
  # on the low static speed the user chose, with nothing left to raise it
  local OUTPUT
  OUTPUT=$(graceful_exit 2>&1)
  local -r EXIT_CODE=$?

  assert_equals 0 "$EXIT_CODE"
  assert_contains "$OUTPUT" "Dell default dynamic fan control profile applied for safety"
}

function test_stopping_the_container_honors_the_third_party_pcie_card_setting() {
  export KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT=false

  # graceful_exit ends with "exit 0", so it has to run in a subshell of its own,
  # otherwise it would stop the test case right here. The mocked ipmitool records
  # its calls in a file, which outlives that subshell
  (graceful_exit) > /dev/null 2>&1

  assert_equals "1" "$(count_ipmitool_calls_matching "$DELL_DEFAULT_FAN_CONTROL_COMMAND")"
  assert_equals "1" "$(count_ipmitool_calls_matching "$THIRD_PARTY_PCIE_CARD_COMMAND 0x00 0x00 0x00 0x05 0x00 0x00 0x00 0x00")" \
    "the cooling response must be reset to Dell's default"

  forget_recorded_ipmitool_calls
  export KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT=true

  (graceful_exit) > /dev/null 2>&1

  assert_equals "1" "$(count_ipmitool_calls_matching "$DELL_DEFAULT_FAN_CONTROL_COMMAND")" \
    "the fan control profile is always restored, whatever this setting"
  assert_equals "0" "$(count_ipmitool_calls_matching "raw 0x30 0xce")" \
    "the cooling response must be left as it is when the user asked for it"
}

function test_stopping_the_container_in_monitoring_only_mode_changes_nothing() {
  export MONITORING_ONLY_MODE=true

  local OUTPUT
  OUTPUT=$(graceful_exit 2>&1)
  local -r EXIT_CODE=$?

  assert_equals 0 "$EXIT_CODE"
  assert_contains "$OUTPUT" "no fan control profile was ever applied"
  assert_equals "0" "$(count_ipmitool_calls_matching "raw 0x30")" \
    "a monitoring only container must leave the server exactly as it found it"
}

function test_a_refused_profile_is_not_reported_as_applied() {
  # The table column is the only thing telling an operator what the server is
  # actually doing. Naming the profile the controller *tried* to apply, on a
  # command the iDRAC refused, describes a machine that does not exist : the fans
  # are still Dell's to drive, at whatever speed its own profile picks
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0x30 0x01 0x00"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="$REJECTED_BY_FIRMWARE_STDERR"

  apply_user_fan_control_profile 2>/dev/null
  local -r EXIT_CODE=$?

  assert_equals "1" "$EXIT_CODE" "a refused profile must report itself as not applied"
  assert_contains "$CURRENT_FAN_CONTROL_PROFILE" "not applied" \
    "the table must say the profile was not applied rather than name it as active"
}

function test_a_refused_fan_speed_alone_is_enough_to_deny_the_profile() {
  # Taking control away from Dell's profile and then failing to set a speed leaves
  # the fans on the controller's watch at an unknown duty : the profile named in
  # the table is not the one running either way
  DECIMAL_FAN_SPEED=30
  HEXADECIMAL_FAN_SPEED="0x1e"
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0x30 0x02"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="$REJECTED_BY_FIRMWARE_STDERR"

  apply_user_fan_control_profile 2>/dev/null

  assert_contains "$CURRENT_FAN_CONTROL_PROFILE" "not applied"
  assert_contains "$CURRENT_FAN_CONTROL_PROFILE" "30%" \
    "the speed that was asked for is still worth showing, it is what was refused"
}

function test_a_refused_dell_default_profile_is_not_reported_as_applied() {
  # This is the safety fallback : reporting it as applied on a server whose iDRAC
  # refused it tells the operator the machine is protected when it is not
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0x30 0x01 0x01"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="$REJECTED_BY_FIRMWARE_STDERR"

  apply_Dell_default_fan_control_profile 2>/dev/null
  local -r EXIT_CODE=$?

  assert_equals "1" "$EXIT_CODE"
  assert_contains "$CURRENT_FAN_CONTROL_PROFILE" "not applied"
}

function test_an_applied_profile_still_reports_itself_as_applied() {
  # The guard must not fire on the healthy path : an accepted profile is named
  # plainly, with no caveat
  DECIMAL_FAN_SPEED=5
  HEXADECIMAL_FAN_SPEED="0x05"

  apply_user_fan_control_profile
  local -r EXIT_CODE=$?

  assert_equals "0" "$EXIT_CODE"
  assert_equals "User static fan control profile (5%)" "$CURRENT_FAN_CONTROL_PROFILE"
}
