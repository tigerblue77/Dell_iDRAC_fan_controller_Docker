#!/bin/bash

# The overheating decision. Everything here is safety-critical : a reading that
# cannot be trusted must send the server back to Dell's own dynamic profile, not
# leave it running on the low static speed the user asked for.

# is_any_CPU_overheating() answers through its exit code and reads the detected
# CPUs from globals, so these helpers keep the test cases readable and give the
# failure diagnostic the numbers that produced it
function given_the_detected_cpu_temperatures() {
  DETECTED_CPU_TEMPERATURES=("$@")
  DETECTED_CPU_ENTITY_IDS=()
  DETECTED_CPU_LABELS=()

  local INDEX
  for INDEX in "${!DETECTED_CPU_TEMPERATURES[@]}"; do
    DETECTED_CPU_ENTITY_IDS+=("3.$((INDEX + 1))")
    DETECTED_CPU_LABELS+=("CPU $((INDEX + 1))")
  done
}

function assert_a_cpu_is_overheating() {
  local -r MESSAGE="${1:-a CPU should be reported as overheating}"

  if is_any_CPU_overheating; then
    pass
  else
    fail "$MESSAGE" "readings:  [${DETECTED_CPU_TEMPERATURES[*]}]" "threshold: [$CPU_TEMPERATURE_THRESHOLD]"
  fi
}

function assert_no_cpu_is_overheating() {
  local -r MESSAGE="${1:-no CPU should be reported as overheating}"

  if is_any_CPU_overheating; then
    fail "$MESSAGE" "readings:  [${DETECTED_CPU_TEMPERATURES[*]}]" "threshold: [$CPU_TEMPERATURE_THRESHOLD]"
  else
    pass
  fi
}

function test_a_cpu_temperature_below_the_threshold_is_not_overheating() {
  export CPU_TEMPERATURE_THRESHOLD=50
  given_the_detected_cpu_temperatures 45 30

  assert_no_cpu_is_overheating
}

function test_a_cpu_temperature_equal_to_the_threshold_is_not_overheating() {
  # The README describes the threshold as the value "beyond which" Dell's profile
  # takes over : reaching it exactly is still fine
  export CPU_TEMPERATURE_THRESHOLD=50
  given_the_detected_cpu_temperatures 50 50

  assert_no_cpu_is_overheating
}

function test_a_cpu_temperature_above_the_threshold_is_overheating() {
  export CPU_TEMPERATURE_THRESHOLD=50
  given_the_detected_cpu_temperatures 51 51

  assert_a_cpu_is_overheating

  # A three-digit reading must be compared as a number, not as text
  given_the_detected_cpu_temperatures 100 100

  assert_a_cpu_is_overheating "100 degrees is above 50, not below it"
}

function test_any_of_the_detected_cpus_can_trigger_the_fallback() {
  # The whole point of issue #91 : a quad socket server whose CPU 3 or CPU 4 is
  # the only hot one must still fall back on Dell's profile
  export CPU_TEMPERATURE_THRESHOLD=50

  local HOT_CPU_INDEX
  for HOT_CPU_INDEX in 0 1 2 3; do
    local -a READINGS=(40 40 40 40)
    READINGS[HOT_CPU_INDEX]=75
    given_the_detected_cpu_temperatures "${READINGS[@]}"

    assert_a_cpu_is_overheating "CPU $((HOT_CPU_INDEX + 1)) alone above the threshold must trigger the fallback"
    assert_equals "CPU $((HOT_CPU_INDEX + 1))" "${OVERHEATING_CPUS_AND_TEMPERATURES[0]}" \
      "the comment must name the CPU that actually triggered the fallback"
  done
}

function test_a_missing_reading_fails_safe_and_reports_overheating() {
  export CPU_TEMPERATURE_THRESHOLD=50
  given_the_detected_cpu_temperatures "" ""

  assert_a_cpu_is_overheating "an unreadable CPU must fall back on Dell's dynamic profile"
}

function test_a_non_numeric_reading_fails_safe_and_reports_overheating() {
  # A mis-parsed reading used to make bash throw "unary operator expected" and
  # crash the container, or worse, silently keep the user's low fan speed
  export CPU_TEMPERATURE_THRESHOLD=50

  local UNUSABLE_READING
  for UNUSABLE_READING in "n/a" "-" "Disabled" "4 5" "45.5" "no reading"; do
    given_the_detected_cpu_temperatures "$UNUSABLE_READING" 40

    assert_a_cpu_is_overheating "an unusable reading (\"$UNUSABLE_READING\") must fail safe"
  done
}

function test_a_sub_zero_reading_is_a_reading_not_a_parsing_accident() {
  # A negative reading is in-spec, not unusable : Dell rates the PowerEdge line
  # down to -5°C, and a disconnected CPU sensor reports around -40°C on some
  # iDRACs. Reading it unsigned is what used to invert the decision -- -40 came
  # back as +40 and tripped the overheating branch, ramping the fans on a
  # machine that was not hot -- so a sub-zero CPU must be treated as cold
  export CPU_TEMPERATURE_THRESHOLD=50

  local SUB_ZERO_READING
  for SUB_ZERO_READING in "-1" "-10" "-40"; do
    given_the_detected_cpu_temperatures "$SUB_ZERO_READING" "$SUB_ZERO_READING"

    assert_no_cpu_is_overheating "$SUB_ZERO_READING°C is below the threshold, no CPU is overheating"
  done

  # And it stays a comparison, not a string match : a threshold below the
  # reading still trips, whichever side of zero they are on
  export CPU_TEMPERATURE_THRESHOLD=-20
  given_the_detected_cpu_temperatures "-10"
  assert_a_cpu_is_overheating "-10°C is above a -20°C threshold"

  assert_equals " -10" "$(format_temperature_for_display "-10" 4)" "the sign is kept when printing"
}

function test_a_reading_with_a_leading_zero_is_not_read_as_octal() {
  # "09" is not a valid octal number : bash used to abort on it
  export CPU_TEMPERATURE_THRESHOLD=50
  given_the_detected_cpu_temperatures "09" "08"

  assert_no_cpu_is_overheating "09 and 08 degrees are 9 and 8 degrees, not invalid octal numbers"
}

function test_the_threshold_is_honored_whatever_its_value() {
  # The README suggests setting it just below the CPU's Tcase, which ranges from
  # about 60 degrees on an old Xeon E5 to over 90 on a recent Scalable
  local THRESHOLD
  for THRESHOLD in 0 40 60 63 85 100; do
    export CPU_TEMPERATURE_THRESHOLD="$THRESHOLD"

    given_the_detected_cpu_temperatures $((THRESHOLD + 1))
    assert_a_cpu_is_overheating "one degree above the threshold is overheating"

    given_the_detected_cpu_temperatures "$THRESHOLD"
    assert_no_cpu_is_overheating "reaching the threshold exactly is not overheating"
  done
}

function test_an_unreadable_reading_is_reported_as_such_and_not_as_too_hot() {
  # Reporting "temperature is too high" on a reading that was never obtained
  # sends the user chasing a cooling problem instead of the sensor problem they
  # have, and contradicts the "-" printed in that CPU's own column
  export CPU_TEMPERATURE_THRESHOLD=50
  given_the_detected_cpu_temperatures 75 ""

  assert_a_cpu_is_overheating
  local -r COMMENT=$(build_fan_control_fallback_comment "${OVERHEATING_CPUS_AND_TEMPERATURES[@]}")

  assert_contains "$COMMENT" "CPU 1 temperature is too high"
  assert_contains "$COMMENT" "CPU 2 temperature could not be read"
}

function test_temperatures_are_printed_right_aligned_on_three_characters() {
  assert_equals "  5" "$(format_temperature_for_display 5)"
  assert_equals " 45" "$(format_temperature_for_display 45)"
  assert_equals "100" "$(format_temperature_for_display 100)"
  assert_equals "  9" "$(format_temperature_for_display 09)" "a leading zero must not be read as octal"
}

function test_temperatures_are_printed_on_the_width_the_table_asks_for() {
  # The CPU columns widen with their labels, so the reading has to follow
  assert_equals "   45" "$(format_temperature_for_display 45 5)"
  assert_equals "    -" "$(format_temperature_for_display "" 5)"
}

function test_an_unreadable_temperature_is_printed_as_a_placeholder() {
  # printf %d would abort on any of these, taking the whole container down
  local UNUSABLE_READING
  for UNUSABLE_READING in "" "-" "n/a" "Disabled" "45.5"; do
    assert_equals "  -" "$(format_temperature_for_display "$UNUSABLE_READING")" \
      "\"$UNUSABLE_READING\" should be printed as a placeholder"
  done

  # A sub-zero reading is a reading : it must be printed, sign included, and not
  # replaced by the placeholder the unusable ones get
  assert_equals " -1" "$(format_temperature_for_display "-1")"
  assert_equals "-10" "$(format_temperature_for_display "-10")"
  assert_equals "-40" "$(format_temperature_for_display "-40")"
}
