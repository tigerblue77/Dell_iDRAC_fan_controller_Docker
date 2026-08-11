#!/bin/bash

# The firmware version the iDRAC reports about itself, read from "ipmitool mc info"
# and printed once at startup.
#
# It is the first thing asked for on every report about fan control not being
# applied, and the container used to print everything about the server except it.
#
# What it is NOT is a way to decide whether this server accepts fan control : the
# numbering restarted at 1.x with the iDRAC 10 of the 17th generation, so every
# comparison against 3.34.34.34 calls the newest hardware Dell makes the oldest.
# That question is settled by sending the command and reading the answer, and
# test_a_recent_firmware_version_is_never_turned_into_a_verdict below pins it.

function test_the_firmware_version_the_idrac_reports_is_read() {
  export MOCK_IPMITOOL_MC_INFO_OUTPUT
  MOCK_IPMITOOL_MC_INFO_OUTPUT=$(make_mc_info_output --firmware-revision "2.86")

  get_iDRAC_firmware_version

  assert_equals "2.86" "$IDRAC_FIRMWARE_VERSION"
}

function test_the_firmware_version_is_read_from_every_generation_of_idrac() {
  # The two numbers "ipmitool mc info" reports for the firmwares this container
  # meets : an iDRAC 6 to 8 on the generations where the raw commands work, an
  # iDRAC 9 on both sides of the 3.34.34.34 boundary, and the iDRAC 10 whose
  # numbering starts over at 1.x
  local FIRMWARE_REVISION
  for FIRMWARE_REVISION in "1.66" "2.86" "3.21" "3.30" "3.34" "6.10" "7.00" "1.30"; do
    export MOCK_IPMITOOL_MC_INFO_OUTPUT
    MOCK_IPMITOOL_MC_INFO_OUTPUT=$(make_mc_info_output --firmware-revision "$FIRMWARE_REVISION")

    get_iDRAC_firmware_version

    assert_equals "$FIRMWARE_REVISION" "$IDRAC_FIRMWARE_VERSION" \
      "firmware $FIRMWARE_REVISION should be read exactly as the iDRAC reports it"
  done
}

function test_the_auxiliary_revision_bytes_are_not_mistaken_for_the_version() {
  # "ipmitool mc info" ends on the vendor-specific auxiliary firmware revision,
  # printed as four hexadecimal bytes on four lines of their own. They hold the
  # two numbers the version line drops, undecoded, and a parse that read one line
  # too far would report "0x00" as the firmware version
  export MOCK_IPMITOOL_MC_INFO_OUTPUT
  MOCK_IPMITOOL_MC_INFO_OUTPUT=$(make_mc_info_output --firmware-revision "6.10")

  get_iDRAC_firmware_version

  assert_equals "6.10" "$IDRAC_FIRMWARE_VERSION"
  assert_not_contains "$IDRAC_FIRMWARE_VERSION" "0x" \
    "the auxiliary revision bytes are not the firmware version"
}

function test_an_idrac_that_reports_no_firmware_version_is_reported_as_unknown() {
  # Nothing the controller does depends on this value, so a BMC that does not
  # report one is logged as unknown rather than treated as a failure
  export MOCK_IPMITOOL_MC_INFO_OUTPUT
  MOCK_IPMITOOL_MC_INFO_OUTPUT=$(make_mc_info_output --no-firmware-revision)

  get_iDRAC_firmware_version

  assert_equals "unknown" "$IDRAC_FIRMWARE_VERSION"
}

function test_an_idrac_that_answers_nothing_at_all_is_reported_as_unknown() {
  # The controller is already running against this iDRAC by the time this is
  # asked -- the server was identified from its FRU inventory two calls earlier --
  # so a failed call here is a curiosity, not a reason to refuse to start
  export MOCK_IPMITOOL_MC_INFO_OUTPUT=""
  export MOCK_IPMITOOL_MC_INFO_EXIT_CODE=1

  assert_command_succeeds "an unanswered mc info must not fail the caller" get_iDRAC_firmware_version
  assert_equals "unknown" "$IDRAC_FIRMWARE_VERSION"
}

function test_the_firmware_noise_some_idracs_print_is_not_read_as_a_version() {
  # Some iDRAC firmwares print a protocol warning on stderr on every single call,
  # even when the call succeeds. It is discarded here rather than parsed
  export MOCK_IPMITOOL_MC_INFO_OUTPUT
  MOCK_IPMITOOL_MC_INFO_OUTPUT=$(make_mc_info_output --firmware-revision "2.65")
  export MOCK_IPMITOOL_MC_INFO_STDERR="Received an Unexpected message with sequence number 12"

  capture_output get_iDRAC_firmware_version

  assert_equals "2.65" "$IDRAC_FIRMWARE_VERSION"
  assert_empty "$CAPTURED_OUTPUT" "the protocol warning must not reach the log through this call"
}
