#!/bin/bash

# A numeric comparison whose operand is empty, or not yet resolved, does not
# fail loudly : bash prints "integer expression expected" on stderr and "[" exits
# 2, which every caller here reads as "false". A guard written to refuse a
# configuration, or to trip a safety fallback, then silently stops guarding.
#
# It has landed three times (#149, #165, #291), twice as an ordering mistake
# rather than a missing validation -- the value was checked, just not yet,
# because the comparison sat above the line resolving it. shellcheck cannot see
# it, and the unit tests call the predicates with values already set, which is
# exactly the state the bug is not in.
#
# So this watches the real entry point across configurations that must all be
# accepted, and asserts none of them makes bash complain about an operand. A
# smoke test rather than a proof : it catches the reachable cases, which is what
# all three were.

function assert_no_comparison_error() {
  local -r DESCRIPTION="$1"
  local -r OUTPUT="$2"

  local PATTERN
  for PATTERN in "integer expression expected" "unary operator expected" "invalid integer constant"; do
    if [[ "$OUTPUT" == *"$PATTERN"* ]]; then
      fail "$DESCRIPTION made bash complain about a comparison operand" \
        "$(printf '%s\n' "$OUTPUT" | grep -F "$PATTERN" | head -3)"
      return 1
    fi
  done

  pass
}

function test_the_default_configuration_compares_only_resolved_operands() {
  simulate_server "PowerEdge R740" --cpus 2 --cpu-temperatures "42 44"

  assert_no_comparison_error "the default configuration" "$(run_controller)"
}

function test_an_automatic_cpu_threshold_is_resolved_before_it_is_compared() {
  # "auto" is the default, and it is a literal string until lm-sensors or the
  # fallback replaces it. Every comparison against it has to sit below that
  # resolution -- #291 put one above it
  export CPU_TEMPERATURE_THRESHOLD=auto
  simulate_server "PowerEdge R740" --cpus 2 --cpu-temperatures "42 44"

  assert_no_comparison_error "an automatic CPU temperature threshold" "$(run_controller)"
}

function test_a_numeric_cpu_threshold_compares_cleanly() {
  export CPU_TEMPERATURE_THRESHOLD=50
  simulate_server "PowerEdge R740" --cpus 2 --cpu-temperatures "42 44"

  assert_no_comparison_error "a numeric CPU temperature threshold" "$(run_controller)"
}

function test_a_hexadecimal_fan_speed_compares_cleanly() {
  # The decimal form is derived from the hexadecimal one, so anything comparing
  # against it depends on that conversion having run -- #165 compared above it
  export FAN_SPEED=0x1e
  simulate_server "PowerEdge R740" --cpus 2 --cpu-temperatures "42 44"

  assert_no_comparison_error "a hexadecimal fan speed" "$(run_controller)"
}

function test_an_overheating_cpu_compares_cleanly() {
  # The branch #149 was about : the overheating comparison itself
  export CPU_TEMPERATURE_THRESHOLD=50
  simulate_server "PowerEdge R740" --cpus 2 --cpu-temperatures "95 44"

  assert_no_comparison_error "an overheating CPU" "$(run_controller)"
}

function test_an_unreadable_cpu_reading_compares_cleanly() {
  # An unreadable reading must reach the fail-safe, not a bash error
  simulate_server "PowerEdge R740" --cpus 2 --cpu-temperatures "42 44"
  export MOCK_IPMITOOL_SDR_SECOND_OUTPUT
  MOCK_IPMITOOL_SDR_SECOND_OUTPUT=$(make_sdr_output --cpus 2 --cpu-temperatures "42 44" | grep -v ' 3\.2 ')
  export MOCK_IPMITOOL_SDR_SWITCH_AFTER_CALLS=1

  assert_no_comparison_error "an unreadable CPU reading" "$(run_controller)"
}

function test_monitoring_only_mode_compares_cleanly() {
  export MONITORING_ONLY_MODE=true
  simulate_server "PowerEdge R740" --cpus 2 --cpu-temperatures "42 44"

  assert_no_comparison_error "monitoring only mode" "$(run_controller)"
}

function test_a_powered_off_server_compares_cleanly() {
  simulate_server "PowerEdge R740" --cpus 2
  export MOCK_IPMITOOL_POWER_STATUS="Chassis Power is off"

  assert_no_comparison_error "a powered off server" \
    "$(run_controller "Target server is powered off")"
}
