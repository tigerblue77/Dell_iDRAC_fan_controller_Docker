#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# The commands actually sent to the server, and what happens when the server
# refuses them - which is the normal situation on an iDRAC 9 running firmware
# 3.34.34.34 or newer (Gen 15, 16) and on the iDRAC 10 of a Gen 17 server, where
# Dell removed the IPMI raw fan control commands altogether. 3.30.30.30 is the
# newest firmware they are confirmed to still work on, and what the two releases
# between the two, 3.31.31.31 and 3.32.32.32, answer has never been reported.
#
# Applying a fan control profile is the one thing the controller exists for, so
# a silent failure here is the worst possible outcome : the user believes their
# fans are quiet while the server actually runs on whatever profile it had.

readonly MANUAL_FAN_CONTROL_COMMAND="raw 0x30 0x30 0x01 0x00"
readonly FAN_SPEED_COMMAND="raw 0x30 0x30 0x02 0xff"
readonly DELL_DEFAULT_FAN_CONTROL_COMMAND="raw 0x30 0x30 0x01 0x01"
readonly THIRD_PARTY_PCIE_CARD_COMMAND="raw 0x30 0xce 0x00 0x16 0x05"

# What an iDRAC 9 running firmware >= 3.34.34.34 answers to a fan control command
readonly REJECTED_BY_FIRMWARE_STDERR="Unable to send RAW command (channel=0x0 netfn=0x30 lun=0x0 cmd=0x30 rsp=0xd5): Command not supported in present state"

# What a BMC answers when the command exists but the account may not run it. Reported on an R550 in
# issue #29, where every raw command answered "Insufficient privilege level"
# The same answer on a fan control command, which is what an iDRAC 9 running firmware 3.34.34.34 or
# newer gives : Dell removed a privilege there rather than a command
readonly FAN_CONTROL_REFUSED_FOR_PRIVILEGE_STDERR="Unable to send RAW command (channel=0x0 netfn=0x30 lun=0x0 cmd=0x30 rsp=0xd4): Insufficient privilege level"

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
  # A Gen 15/16/17 server, or a Gen 14 whose firmware was updated to 3.34.34.34 or newer
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

function test_every_other_answer_a_bmc_can_give_settles_nothing() {
  # test_a_privilege_refusal_is_told_apart_from_a_command_the_server_does_not_have above covers 0xc1,
  # 0xd4 and an iDRAC that was never reached. This covers the rest of what comes back : the second
  # code that does settle something, and the ones that must never be allowed to. A busy BMC, a code
  # neither predicate knows and an empty answer are not a server refusing anything, and concluding
  # from them would silence the fan control commands for good over a network glitch
  assert_command_succeeds "0xd5 is the server saying it will not run the command in this state" \
    does_the_server_lack_this_command "$REJECTED_BY_FIRMWARE_STDERR"
  assert_command_fails "0xd5 is not a privilege problem either" \
    does_the_command_need_a_higher_privilege_level "$REJECTED_BY_FIRMWARE_STDERR"

  local ANSWER
  for ANSWER in \
    "Unable to send RAW command (channel=0x0 netfn=0x30 lun=0x0 cmd=0x30 rsp=0xc0): Node busy" \
    "Unable to send RAW command (channel=0x0 netfn=0x30 lun=0x0 cmd=0x30 rsp=0xff): Unspecified error" \
    ""; do
    assert_command_fails "\"$ANSWER\" does not say the command is absent" \
      does_the_server_lack_this_command "$ANSWER"
    assert_command_fails "\"$ANSWER\" does not say the account may not run it" \
      does_the_command_need_a_higher_privilege_level "$ANSWER"
  done
}

function test_a_server_that_refused_fan_control_is_not_asked_again() {
  # The defect this closes : the same two commands were sent, and the same two
  # errors printed, on every cycle for the life of the container -- twelve times a
  # minute at the default check interval, on a server that answered the first time
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0x30"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="$REJECTED_BY_FIRMWARE_STDERR"

  capture_output apply_user_fan_control_profile
  assert_contains "$CAPTURED_OUTPUT" "This server refused fan control" \
    "the verdict must be explained the once it is reached"

  forget_recorded_ipmitool_calls
  capture_output apply_user_fan_control_profile

  assert_equals "0" "$(count_ipmitool_calls_matching "raw 0x30 0x30")" \
    "not a single command must be sent on the cycles that follow"
  assert_empty "$CAPTURED_OUTPUT" "nor a single line printed"
  assert_equals "Dell default dynamic fan control profile (refused)" "$CURRENT_FAN_CONTROL_PROFILE" \
    "the table must name the profile the server is actually running, and say why it is that one"
}

function test_a_server_that_refuses_the_safety_profile_is_not_asked_again() {
  # The same verdict, reached through the other door. The overheating branch of
  # the monitoring loop only ever calls this function, so a server that is
  # already too hot on the cycle it starts on reaches the verdict here and
  # nowhere else -- and would otherwise keep being asked, and keep refusing,
  # for as long as it stayed hot
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0x30"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="$REJECTED_BY_FIRMWARE_STDERR"

  capture_output apply_Dell_default_fan_control_profile
  assert_contains "$CAPTURED_OUTPUT" "This server refused fan control" \
    "the verdict must be reached on the path the overheating branch takes too"

  forget_recorded_ipmitool_calls
  capture_output apply_Dell_default_fan_control_profile

  assert_equals "0" "$(count_ipmitool_calls_matching "raw 0x30 0x30")" \
    "not a single command must be sent on the cycles that follow"
  assert_empty "$CAPTURED_OUTPUT" "nor a single line printed"
  assert_equals "Dell default dynamic fan control profile (refused)" "$CURRENT_FAN_CONTROL_PROFILE"
}

function test_a_forbidden_fan_control_command_settles_it_too() {
  # 0xd4 rather than 0xd5 : the answer of an iDRAC 9 on 3.34.34.34 or newer, and
  # the one this container will meet most often from now on
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0x30"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="$FAN_CONTROL_REFUSED_FOR_PRIVILEGE_STDERR"

  capture_output apply_user_fan_control_profile

  assert_contains "$CAPTURED_OUTPUT" "This server refused fan control"
  assert_contains "$CAPTURED_OUTPUT" "not an Administrator" \
    "0xd4 has two causes and only one of them is the firmware, so both must be named"

  forget_recorded_ipmitool_calls
  apply_user_fan_control_profile 2>/dev/null

  assert_equals "0" "$(count_ipmitool_calls_matching "raw 0x30 0x30")"
}

function test_an_unreachable_idrac_never_stops_the_controller_from_trying() {
  # No completion code at all : the BMC was never reached, and an outage that
  # silenced the fan control commands for good would leave the fans wherever they
  # were with nobody raising them once it ended
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0x30"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="Error: Unable to establish IPMI v2 / RMCP+ session"

  apply_user_fan_control_profile 2>/dev/null
  forget_recorded_ipmitool_calls
  apply_user_fan_control_profile 2>/dev/null

  assert_equals "1" "$(count_ipmitool_calls_matching "raw 0x30 0x30 0x01 0x00")" \
    "the controller must keep asking an iDRAC it merely could not reach"
  assert_equals "1" "$(count_ipmitool_calls_matching "raw 0x30 0x30 0x02")"
}

function test_a_refused_fan_speed_never_stops_the_controller_from_trying() {
  # The one refusal that must never settle anything. Manual fan control was taken
  # successfully, so the fans are the controller's : giving up here would leave
  # them pinned at a speed nothing raises, on a server that is heating up. Only
  # the command that takes them away from Dell's profile can settle whether this
  # server hands them over at all
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0x30 0x02"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="$FAN_CONTROL_REFUSED_FOR_PRIVILEGE_STDERR"

  apply_user_fan_control_profile 2>/dev/null
  forget_recorded_ipmitool_calls
  apply_user_fan_control_profile 2>/dev/null

  assert_equals "1" "$(count_ipmitool_calls_matching "raw 0x30 0x30 0x01 0x00")" \
    "the fans are already the controller's, it must keep driving them"
  assert_equals "1" "$(count_ipmitool_calls_matching "raw 0x30 0x30 0x02")"
}

function test_a_refusal_that_follows_an_accepted_command_never_settles_anything() {
  # The same hazard from the other end : a server that accepted the commands and
  # starts refusing them mid-run holds fans the controller took. Every refusal
  # from then on is a failure to give them back, and each retry is another attempt
  # to -- so the controller keeps asking, however long it takes
  apply_user_fan_control_profile
  assert_equals "User static fan control profile (5%)" "$CURRENT_FAN_CONTROL_PROFILE" \
    "the fans must have been taken for this test to mean anything"

  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0x30"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="$REJECTED_BY_FIRMWARE_STDERR"
  apply_Dell_default_fan_control_profile 2>/dev/null

  forget_recorded_ipmitool_calls
  apply_Dell_default_fan_control_profile 2>/dev/null

  assert_equals "1" "$(count_ipmitool_calls_matching "raw 0x30 0x30 0x01 0x01")" \
    "handing the fans back must be retried for as long as the container runs"
}

function test_monitoring_only_mode_reaches_no_verdict_because_it_asks_nothing() {
  # Nothing is sent in this mode, so nothing can be refused : the badge must stay
  # the monitoring only one rather than become a refusal the server never uttered
  export MONITORING_ONLY_MODE=true
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0x30"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="$REJECTED_BY_FIRMWARE_STDERR"

  apply_user_fan_control_profile
  apply_user_fan_control_profile

  assert_contains "$CURRENT_FAN_CONTROL_PROFILE" "monitoring only, not applied"
  assert_equals "0" "$(count_ipmitool_calls_matching "raw 0x30 0x30")"
}

# What an 11th generation iDRAC6 answers to the fan speed command addressed to every fan at once, as
# reported on an R510 in issue #378. The very same command with a single fan's ID is accepted there,
# so this is the BMC refusing an argument, not the command
readonly BROADCAST_FAN_SELECTOR_REJECTED_STDERR="Unable to send RAW command (channel=0x0 netfn=0x30 lun=0x0 cmd=0x30 rsp=0xcc): Invalid data field in request"

function test_a_rejected_data_field_is_told_apart_from_a_command_the_server_does_not_have() {
  # The distinction the whole change rests on. 0xcc is a server that HAS the fan control commands and
  # refused an argument of one of them : reading it as "this server refuses fan control" would stop the
  # controller sending commands an R510 does take, and would report fans left with Dell that are not
  assert_command_succeeds "0xcc is the server refusing one of the command's data bytes" \
    does_the_server_reject_this_data_field "$BROADCAST_FAN_SELECTOR_REJECTED_STDERR"
  assert_command_fails "0xcc does not say the command is absent" \
    does_the_server_lack_this_command "$BROADCAST_FAN_SELECTOR_REJECTED_STDERR"
  assert_command_fails "0xcc does not say the account may not run it" \
    does_the_command_need_a_higher_privilege_level "$BROADCAST_FAN_SELECTOR_REJECTED_STDERR"

  local ANSWER
  for ANSWER in "$REJECTED_BY_FIRMWARE_STDERR" "$FAN_CONTROL_REFUSED_FOR_PRIVILEGE_STDERR" \
    "Unable to send RAW command (channel=0x0 netfn=0x30 lun=0x0 cmd=0x30 rsp=0xc0): Node busy" \
    "Error: Unable to establish IPMI v2 / RMCP+ session" \
    ""; do
    assert_command_fails "\"$ANSWER\" is not a rejected data field" \
      does_the_server_reject_this_data_field "$ANSWER"
  done
}

function test_a_rejected_fan_selector_never_makes_the_controller_give_up_on_fan_control() {
  # The regression this guards against : 0xcc reaching note_that_the_server_refuses_fan_control() would
  # silence every later command on a server that accepts them, and graceful_exit would then skip the
  # hand-back on the way out, leaving the fans under manual control for good
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0x30 0x02 (0xff|$REFUSED_FAN_IDENTIFIER_PATTERN)"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="$BROADCAST_FAN_SELECTOR_REJECTED_STDERR"

  capture_output apply_user_fan_control_profile

  assert_command_fails "a rejected argument is not a server refusing fan control" \
    has_the_server_refused_fan_control

  forget_recorded_ipmitool_calls
  capture_output apply_user_fan_control_profile

  assert_equals "1" "$(count_ipmitool_calls_matching "$MANUAL_FAN_CONTROL_COMMAND")" \
    "the commands must keep being sent to a server that has them"
  assert_equals "8" "$(count_ipmitool_calls_matching "raw 0x30 0x30 0x02 0x0")" \
    "and the speed keeps reaching every fan, through the addressing this server accepts"
}

function test_a_rejected_fan_selector_is_explained_once_and_names_the_state_the_fans_are_in() {
  # The defect from the user's side : the log repeated one raw ipmitool line a minute, and nothing said
  # that manual control had been taken while the speed had not, which is why the fans sat "too low".
  # Only a server that refuses the speed BOTH ways reaches this now -- one that merely refuses the
  # broadcast selector is handled rather than reported, which the fallback tests below cover
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0x30 0x02"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="$BROADCAST_FAN_SELECTOR_REJECTED_STDERR"

  capture_output apply_user_fan_control_profile

  assert_contains "$CAPTURED_OUTPUT" "neither profile" \
    "the fans are on neither Dell's profile nor the user's, and that is the part worth saying"
  assert_contains "$CAPTURED_OUTPUT" "0xcc" \
    "the completion code the verdict was read from must be quoted"
  assert_contains "$CAPTURED_OUTPUT" "MONITORING_ONLY_MODE" \
    "the one setting that gets this server out of it must be named"

  forget_recorded_ipmitool_calls
  capture_output apply_user_fan_control_profile

  assert_not_contains "$CAPTURED_OUTPUT" "neither profile" \
    "explained the once, not on every cycle for the life of the container"
}

function test_a_rejected_fan_selector_still_denies_the_profile() {
  # Whatever is said about it, the table must not name a profile the fans are not running. A server that
  # refuses the speed however it is addressed is running neither
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0x30 0x02"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="$BROADCAST_FAN_SELECTOR_REJECTED_STDERR"

  apply_user_fan_control_profile 2>/dev/null
  local -r EXIT_CODE=$?

  assert_equals "1" "$EXIT_CODE"
  assert_contains "$CURRENT_FAN_CONTROL_PROFILE" "not applied"
}

# The identifiers an 11G iDRAC6 accepts, as swept on the R510 of issue #378 : 0x00 to 0x07 answer, 0x08
# and upwards are refused. Ten fan RPM sensors are exposed (five modules, an A and a B rotor each) and
# eight identifiers are accepted, which is why the address space is probed rather than counted
readonly REFUSED_FAN_IDENTIFIER_PATTERN="0x(0[89a-f]|[1-9a-f][0-9a-f])"

function test_a_refused_broadcast_selector_falls_back_to_addressing_each_fan() {
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0x30 0x02 (0xff|$REFUSED_FAN_IDENTIFIER_PATTERN)"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="$BROADCAST_FAN_SELECTOR_REJECTED_STDERR"
  DECIMAL_FAN_SPEED=30
  HEXADECIMAL_FAN_SPEED="0x1e"

  capture_output apply_user_fan_control_profile
  local -r EXIT_CODE=$?

  assert_equals "0" "$EXIT_CODE" "the profile is applied once every fan has been set individually"
  assert_equals "User static fan control profile (30%)" "$CURRENT_FAN_CONTROL_PROFILE" \
    "and the table names it plainly, with no caveat"

  local IDENTIFIER
  for IDENTIFIER in 0x00 0x01 0x02 0x03 0x04 0x05 0x06 0x07; do
    assert_equals "1" "$(count_ipmitool_calls_matching "raw 0x30 0x30 0x02 $IDENTIFIER 0x1e")" \
      "fan $IDENTIFIER must be set to the speed that was asked for"
  done
  assert_equals "1" "$(count_ipmitool_calls_matching "raw 0x30 0x30 0x02 0x08")" \
    "an identifier this server does not have is asked once, and refused"
  assert_not_contains "${DISCOVERED_FAN_IDENTIFIERS[*]}" "0x08" \
    "a refused identifier is not kept"
  assert_equals "1" "$(count_ipmitool_calls_matching "raw 0x30 0x30 0x02 0x1f")" \
    "the walk covers the whole range rather than stopping at the first refusal, since nothing says the accepted identifiers are contiguous"
}

function test_the_discovered_fan_identifiers_are_not_probed_again() {
  # The defect this avoids : one refused command per cycle, for the life of the container, on a server
  # that already answered the question once
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0x30 0x02 (0xff|$REFUSED_FAN_IDENTIFIER_PATTERN)"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="$BROADCAST_FAN_SELECTOR_REJECTED_STDERR"

  capture_output apply_user_fan_control_profile

  forget_recorded_ipmitool_calls
  capture_output apply_user_fan_control_profile

  assert_equals "8" "$(count_ipmitool_calls_matching "raw 0x30 0x30 0x02 0x0")" \
    "the eight accepted fans are set again"
  assert_equals "0" "$(count_ipmitool_calls_matching "raw 0x30 0x30 0x02 0x08")" \
    "but the refused identifier is never sent a second time"
  assert_not_contains "$CAPTURED_OUTPUT" "one at a time" \
    "and the explanation is not repeated on every cycle"
}

function test_the_fan_identifier_set_is_never_counted_from_the_sensor_list() {
  # The R510 of #378 exposes ten fan RPM sensors and accepts eight identifiers, so a count taken from
  # "sdr type fan" would have left two fans running at whatever speed they had while the table reported
  # the profile applied. The server is asked instead, and this pins that it is asked
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0x30 0x02 (0xff|$REFUSED_FAN_IDENTIFIER_PATTERN)"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="$BROADCAST_FAN_SELECTOR_REJECTED_STDERR"

  capture_output apply_user_fan_control_profile

  assert_equals "8" "${#DISCOVERED_FAN_IDENTIFIERS[@]}" \
    "the set is what the server accepted, not what its sensor list suggests"
  assert_equals "0x00" "${DISCOVERED_FAN_IDENTIFIERS[0]}"
  assert_equals "0x07" "${DISCOVERED_FAN_IDENTIFIERS[${#DISCOVERED_FAN_IDENTIFIERS[@]}-1]}"
  assert_contains "$CAPTURED_OUTPUT" "one at a time" \
    "the change of addressing is worth saying once"
}

function test_a_server_refusing_the_speed_every_way_is_reported_rather_than_probed_forever() {
  # Nothing is accepted here, so the selector was never what stood in the way. The walk must stop at
  # 0x00, the profile must not claim to be applied, and the user must be told
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0x30 0x02"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="$BROADCAST_FAN_SELECTOR_REJECTED_STDERR"

  capture_output apply_user_fan_control_profile
  local -r EXIT_CODE=$?

  assert_equals "1" "$EXIT_CODE"
  assert_contains "$CURRENT_FAN_CONTROL_PROFILE" "not applied"
  assert_equals "0" "${#DISCOVERED_FAN_IDENTIFIERS[@]}" "nothing was accepted, so nothing is remembered"
  assert_contains "$CAPTURED_OUTPUT" "Both ways of asking were refused" \
    "the message must describe the server that refused both, not send the user probing again"
  assert_command_fails "refusing a data field is still not refusing fan control" \
    has_the_server_refused_fan_control
}

function test_a_server_that_takes_the_broadcast_selector_never_probes_a_single_fan() {
  # The fallback must be invisible on healthy hardware : one command, no walk, no message
  DECIMAL_FAN_SPEED=30
  HEXADECIMAL_FAN_SPEED="0x1e"

  capture_output apply_user_fan_control_profile

  assert_equals "1" "$(count_ipmitool_calls_matching "raw 0x30 0x30 0x02 0xff 0x1e")"
  assert_equals "0" "$(count_ipmitool_calls_matching "raw 0x30 0x30 0x02 0x00")" \
    "not a single per-fan command must be sent to a server that took the broadcast one"
  assert_equals "0" "${#DISCOVERED_FAN_IDENTIFIERS[@]}"
  assert_empty "$CAPTURED_OUTPUT"
}

function test_the_fan_identifier_walk_is_bounded_on_a_server_that_accepts_everything() {
  # The backstop MAXIMUM_FAN_IDENTIFIER_PROBES exists for : a BMC that answers every identifier would
  # otherwise keep the walk running, and a container stuck sending raw commands drives no fans at all.
  # Only the broadcast selector is refused here, so nothing ever stops the walk on its own
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0x30 0x02 0xff"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="$BROADCAST_FAN_SELECTOR_REJECTED_STDERR"

  capture_output apply_user_fan_control_profile

  assert_equals "$MAXIMUM_FAN_IDENTIFIER_PROBES" "${#DISCOVERED_FAN_IDENTIFIERS[@]}" \
    "the walk must stop at the cap rather than run on"
  assert_equals "0" "$(count_ipmitool_calls_matching "raw 0x30 0x30 0x02 0x20")" \
    "and never send the identifier just past it"
}

function test_a_momentary_answer_during_the_walk_settles_nothing_and_is_retried() {
  # The defect this closes : the walk used to break on any non-zero ipmitool exit, and ipmitool exits
  # non-zero both for an identifier the server does not have and for a BMC that was momentarily busy.
  # One blip therefore froze a set missing every fan above it, for the life of the container, while the
  # profile was reported applied -- the very failure this fallback exists to remove
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0x30 0x02 (0xff|$REFUSED_FAN_IDENTIFIER_PATTERN)"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="$BROADCAST_FAN_SELECTOR_REJECTED_STDERR"
  export MOCK_IPMITOOL_RAW_TRANSIENT_PATTERN="0x30 0x30 0x02 0x03"

  capture_output apply_user_fan_control_profile 2>/dev/null
  local -r EXIT_CODE=$?

  assert_equals "1" "$EXIT_CODE" "a discovery that could not be completed is not a profile applied"
  assert_contains "$CURRENT_FAN_CONTROL_PROFILE" "not applied" \
    "and the table must not name a profile some fans are not running"
  assert_equals "0" "${#DISCOVERED_FAN_IDENTIFIERS[@]}" \
    "nothing is remembered from a walk that was interrupted, or the gap would be permanent"

  # The blip is over. The next cycle must start the discovery again rather than live with the gap
  unset MOCK_IPMITOOL_RAW_TRANSIENT_PATTERN
  forget_recorded_ipmitool_calls
  capture_output apply_user_fan_control_profile

  assert_equals "8" "${#DISCOVERED_FAN_IDENTIFIERS[@]}" \
    "the walk is done again, and this time it finds every fan"
  assert_equals "1" "$(count_ipmitool_calls_matching "raw 0x30 0x30 0x02 0x03")" \
    "including the one that was momentarily busy"
}

function test_a_gap_in_the_accepted_identifiers_does_not_cut_the_set_short() {
  # Nothing says the identifiers a BMC accepts form an unbroken run from 0x00. Stopping at the first
  # refusal would leave every fan above the gap unset while the profile claimed to be applied
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0x30 0x02 (0xff|0x03|$REFUSED_FAN_IDENTIFIER_PATTERN)"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="$BROADCAST_FAN_SELECTOR_REJECTED_STDERR"

  capture_output apply_user_fan_control_profile
  local -r EXIT_CODE=$?

  assert_equals "0" "$EXIT_CODE"
  assert_equals "7" "${#DISCOVERED_FAN_IDENTIFIERS[@]}" \
    "the seven fans either side of the gap are all found"
  assert_equals "1" "$(count_ipmitool_calls_matching "raw 0x30 0x30 0x02 0x07")" \
    "the fans above the gap must still be set"
}

function test_a_server_numbering_its_fans_from_one_is_not_told_it_refused_everything() {
  # A walk that stopped at the first refusal found nothing here, and the message then asserted that the
  # server had refused the speed both ways -- a conclusion drawn from a single identifier, which also
  # steered the user away from the addressing that would have worked
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0x30 0x02 (0xff|0x00|$REFUSED_FAN_IDENTIFIER_PATTERN)"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="$BROADCAST_FAN_SELECTOR_REJECTED_STDERR"

  capture_output apply_user_fan_control_profile
  local -r EXIT_CODE=$?

  assert_equals "0" "$EXIT_CODE" "a server whose fans start at 0x01 is still a server whose fans can be set"
  assert_equals "7" "${#DISCOVERED_FAN_IDENTIFIERS[@]}"
  assert_equals "0x01" "${DISCOVERED_FAN_IDENTIFIERS[0]}"
  assert_not_contains "$CAPTURED_OUTPUT" "Both ways of asking were refused" \
    "nothing was refused both ways here"
}

function test_the_broadcast_selector_is_never_sent_again_once_the_fans_are_known() {
  # Guards the guard : without it the doomed 0xff command went back on the wire every single cycle for
  # the life of the container, which is what issues #267 and #347 exist about
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0x30 0x02 (0xff|$REFUSED_FAN_IDENTIFIER_PATTERN)"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="$BROADCAST_FAN_SELECTOR_REJECTED_STDERR"

  capture_output apply_user_fan_control_profile

  forget_recorded_ipmitool_calls
  capture_output apply_user_fan_control_profile
  capture_output apply_user_fan_control_profile

  assert_equals "0" "$(count_ipmitool_calls_matching "raw 0x30 0x30 0x02 0xff")" \
    "not one broadcast command may be sent on the cycles that follow discovery"
}

function test_a_remembered_fan_that_stops_answering_denies_the_profile() {
  # The reuse path has its own verdict to reach : a fan that was set yesterday and refuses today means
  # the speed the table names is not the one every fan is running
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0x30 0x02 (0xff|$REFUSED_FAN_IDENTIFIER_PATTERN)"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="$BROADCAST_FAN_SELECTOR_REJECTED_STDERR"

  capture_output apply_user_fan_control_profile
  assert_equals "8" "${#DISCOVERED_FAN_IDENTIFIERS[@]}" "the set is known before anything is broken"

  # One of the remembered fans now refuses
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0x30 0x02 (0xff|0x05|$REFUSED_FAN_IDENTIFIER_PATTERN)"

  capture_output apply_user_fan_control_profile 2>/dev/null
  local -r EXIT_CODE=$?

  assert_equals "1" "$EXIT_CODE"
  assert_contains "$CURRENT_FAN_CONTROL_PROFILE" "not applied" \
    "one fan left behind is enough to deny the profile"
}
