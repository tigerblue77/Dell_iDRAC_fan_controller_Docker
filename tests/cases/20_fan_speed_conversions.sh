#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# FAN_SPEED can be given either as a percentage (5) or as the hexadecimal byte
# ipmitool actually sends (0x05), and the controller keeps both representations :
# the decimal one for the logs, the hexadecimal one for the raw IPMI command.

function test_a_decimal_fan_speed_is_converted_to_hexadecimal() {
  assert_equals "0x00" "$(convert_decimal_value_to_hexadecimal 0)"
  assert_equals "0x05" "$(convert_decimal_value_to_hexadecimal 5)" "5% is the Docker image's default fan speed"
  assert_equals "0x0a" "$(convert_decimal_value_to_hexadecimal 10)"
  assert_equals "0x32" "$(convert_decimal_value_to_hexadecimal 50)"
  assert_equals "0x64" "$(convert_decimal_value_to_hexadecimal 100)" "100% is the documented maximum fan speed"
}

function test_a_hexadecimal_fan_speed_is_converted_to_decimal() {
  assert_equals "0" "$(convert_hexadecimal_value_to_decimal 0x00)"
  assert_equals "5" "$(convert_hexadecimal_value_to_decimal 0x05)"
  assert_equals "10" "$(convert_hexadecimal_value_to_decimal 0x0a)"
  assert_equals "50" "$(convert_hexadecimal_value_to_decimal 0x32)"
  assert_equals "100" "$(convert_hexadecimal_value_to_decimal 0x64)"
}

function test_an_uppercase_hexadecimal_fan_speed_is_accepted() {
  # The README documents lowercase values, nothing stops a user from typing 0x0A
  assert_equals "10" "$(convert_hexadecimal_value_to_decimal 0x0A)"
  assert_equals "255" "$(convert_hexadecimal_value_to_decimal 0xFF)"
}

function test_a_hexadecimal_fan_speed_is_always_a_lowercase_two_digit_byte() {
  # ipmitool expects a byte : a bare "0x5" would be sent as an incomplete value
  local DECIMAL_VALUE
  for DECIMAL_VALUE in 0 1 9 15 16 100 171 255; do
    assert_matches "$(convert_decimal_value_to_hexadecimal "$DECIMAL_VALUE")" '^0x[0-9a-f]{2}$' \
      "$DECIMAL_VALUE% should be converted to a two-digit lowercase hexadecimal byte"
  done
  assert_equals "0xab" "$(convert_decimal_value_to_hexadecimal 171)"
}

function test_the_prefix_is_what_tells_the_two_notations_apart() {
  # Both spellings are accepted and neither is refused, so the prefix is the whole
  # difference between them : a value that lost its "0x" applies another duty cycle
  # rather than reporting anything. The README states this pair, and this is what
  # holds the statement to the dispatcher that produces it (#328)
  convert_fan_speed_parameter "0x64"
  assert_equals "100" "$DECIMAL_SPEED" "0x64 is 100%"
  assert_equals "0x64" "$HEXADECIMAL_SPEED" "and reaches ipmitool as the byte it already was"

  convert_fan_speed_parameter "64"
  assert_equals "64" "$DECIMAL_SPEED" "64 without the prefix is 64%, not 100%"
  assert_equals "0x40" "$HEXADECIMAL_SPEED" "and reaches ipmitool as 0x40"

  convert_fan_speed_parameter "0x30"
  assert_equals "48" "$DECIMAL_SPEED" "0x30 is 48%"

  convert_fan_speed_parameter "30"
  assert_equals "30" "$DECIMAL_SPEED" "30 without the prefix is 30%, not 48%"
}

function test_every_valid_fan_speed_percentage_survives_a_round_trip() {
  local PERCENTAGE
  for ((PERCENTAGE = 0; PERCENTAGE <= 100; PERCENTAGE++)); do
    local HEXADECIMAL_VALUE
    HEXADECIMAL_VALUE=$(convert_decimal_value_to_hexadecimal "$PERCENTAGE")
    assert_equals "$PERCENTAGE" "$(convert_hexadecimal_value_to_decimal "$HEXADECIMAL_VALUE")" \
      "$PERCENTAGE% should survive the decimal -> hexadecimal -> decimal round trip"
  done

  # Out of the documented 0-100 range, but a user typo must not silently become
  # another, valid speed : 256 stays 256 instead of wrapping around to 0
  assert_equals "0x100" "$(convert_decimal_value_to_hexadecimal 256)"
  assert_equals "256" "$(convert_hexadecimal_value_to_decimal 0x100)"
}
