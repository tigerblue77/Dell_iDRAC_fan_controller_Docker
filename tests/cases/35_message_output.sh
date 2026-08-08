#!/bin/bash

# How error and warning messages reach the container log. stdout and stderr are
# both "docker logs", so a message that does not terminate its line fuses with
# whatever is printed next -- and what the monitoring loop prints next, on every
# cycle, is a row of the temperatures table (issue #169).
#
# Nothing about a message read on its own shows the defect : only the line after
# it does. Every case here therefore prints something behind the message and
# reads the junction between the two, which catches the opposite mistake in the
# same assertion -- a line terminated twice, leaving a blank line in the log.

# A row of the temperatures table, of the shape a log parser keys on : the
# timestamp first, at column 1
readonly A_TABLE_ROW="08-08-2026 08:35:44  21°C  34°C  45°C  46°C  5%  User static fan control profile (5%)  -"

# The realistic path of issue #169 : an iDRAC that rejects the fan speed raw
# command errors on every cycle, and the loop prints the table right after
function report_a_rejected_fan_speed_then_print_a_table_row() {
  print_error "Failed to set fan speed to 5%. ipmitool said: Unable to send RAW command (channel=0x0 netfn=0x30 lun=0x0 cmd=0x30 rsp=0xc1): Invalid command"
  printf '%s\n' "$A_TABLE_ROW"
}

function warn_about_a_long_check_interval_then_print_a_table_row() {
  validate_check_interval_parameter "CHECK_INTERVAL" "5m" "false"
  printf '%s\n' "$A_TABLE_ROW"
}

function warn_about_too_many_CPUs_then_print_a_table_row() {
  DETECTED_CPU_ENTITY_IDS=(1 2 3 4 5)
  warn_if_unexpected_number_of_CPUs
  printf '%s\n' "$A_TABLE_ROW"
}

function test_an_error_does_not_swallow_the_line_printed_after_it() {
  capture_output report_a_rejected_fan_speed_then_print_a_table_row

  assert_contains "$CAPTURED_OUTPUT" "Invalid command."$'\n'"$A_TABLE_ROW" \
    "the row must start on its own line, at column 1, immediately after the error"
}

function test_the_check_interval_warning_does_not_swallow_the_line_printed_after_it() {
  capture_output warn_about_a_long_check_interval_then_print_a_table_row

  assert_contains "$CAPTURED_OUTPUT" "temperature spike."$'\n'"$A_TABLE_ROW" \
    "this call site used to terminate the line itself with a printf"
}

function test_the_too_many_cpus_warning_does_not_swallow_the_line_printed_after_it() {
  capture_output warn_about_too_many_CPUs_then_print_a_table_row

  assert_contains "$CAPTURED_OUTPUT" "temperature\" command."$'\n'"$A_TABLE_ROW" \
    "this call site used to terminate the line itself with an echo"
}

function test_the_exit_variants_keep_their_exact_wording() {
  # These two build their line in full rather than appending " Exiting." to an
  # unterminated message, so the wording is where that rewrite could show. The
  # first is what a user running this on a non-Dell server reads, and the README
  # quotes it; the second is printed on every "docker stop"
  local OUTPUT

  OUTPUT=$(print_error_and_exit "Your server isn't a Dell product" 2>&1)
  assert_equals "/!\\ Error /!\\ Your server isn't a Dell product. Exiting." "$OUTPUT"

  OUTPUT=$(print_warning_and_exit "Container stopped, Dell default dynamic fan control profile applied for safety" 2>&1)
  assert_equals "/!\\ Warning /!\\ Container stopped, Dell default dynamic fan control profile applied for safety. Exiting." "$OUTPUT"
}
