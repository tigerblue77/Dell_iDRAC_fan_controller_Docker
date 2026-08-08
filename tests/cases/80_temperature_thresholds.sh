#!/bin/bash

# The overheating decision. Everything here is safety-critical : a reading that
# cannot be trusted must send the server back to Dell's own dynamic profile, not
# leave it running on the low static speed the user asked for.

# CPU1_OVERHEATING and CPU2_OVERHEATING answer through their exit code and read
# the temperature from a global, so these two wrappers keep the test cases
# readable and give the failure diagnostic the numbers that produced it
function assert_cpu_is_overheating() {
  local -r CPU_NUMBER="$1"
  local -r MESSAGE="${2:-CPU $CPU_NUMBER should be reported as overheating}"

  if "CPU${CPU_NUMBER}_OVERHEATING"; then
    pass
  else
    local -r TEMPERATURE_VARIABLE="CPU${CPU_NUMBER}_TEMPERATURE"
    fail "$MESSAGE" "reading:   [${!TEMPERATURE_VARIABLE}]" "threshold: [$CPU_TEMPERATURE_THRESHOLD]"
  fi
}

function assert_cpu_is_not_overheating() {
  local -r CPU_NUMBER="$1"
  local -r MESSAGE="${2:-CPU $CPU_NUMBER should not be reported as overheating}"

  if "CPU${CPU_NUMBER}_OVERHEATING"; then
    local -r TEMPERATURE_VARIABLE="CPU${CPU_NUMBER}_TEMPERATURE"
    fail "$MESSAGE" "reading:   [${!TEMPERATURE_VARIABLE}]" "threshold: [$CPU_TEMPERATURE_THRESHOLD]"
  else
    pass
  fi
}

function test_a_cpu_temperature_below_the_threshold_is_not_overheating() {
  export CPU_TEMPERATURE_THRESHOLD=50
  CPU1_TEMPERATURE=45
  CPU2_TEMPERATURE=30

  assert_cpu_is_not_overheating 1
  assert_cpu_is_not_overheating 2
}

function test_a_cpu_temperature_equal_to_the_threshold_is_not_overheating() {
  # The README describes the threshold as the value "beyond which" Dell's profile
  # takes over : reaching it exactly is still fine
  export CPU_TEMPERATURE_THRESHOLD=50
  CPU1_TEMPERATURE=50
  CPU2_TEMPERATURE=50

  assert_cpu_is_not_overheating 1
  assert_cpu_is_not_overheating 2
}

function test_a_cpu_temperature_above_the_threshold_is_overheating() {
  export CPU_TEMPERATURE_THRESHOLD=50
  CPU1_TEMPERATURE=51
  CPU2_TEMPERATURE=51

  assert_cpu_is_overheating 1
  assert_cpu_is_overheating 2

  # A three-digit reading must be compared as a number, not as text
  CPU1_TEMPERATURE=100
  CPU2_TEMPERATURE=100

  assert_cpu_is_overheating 1 "100 degrees is above 50, not below it"
  assert_cpu_is_overheating 2 "100 degrees is above 50, not below it"
}

function test_a_missing_reading_fails_safe_and_reports_overheating() {
  export CPU_TEMPERATURE_THRESHOLD=50
  CPU1_TEMPERATURE=""
  CPU2_TEMPERATURE=""

  assert_cpu_is_overheating 1 "an unreadable CPU 1 must fall back on Dell's dynamic profile"
  assert_cpu_is_overheating 2 "an unreadable CPU 2 must fall back on Dell's dynamic profile"
}

function test_a_non_numeric_reading_fails_safe_and_reports_overheating() {
  # A mis-parsed reading used to make bash throw "unary operator expected" and
  # crash the container, or worse, silently keep the user's low fan speed
  export CPU_TEMPERATURE_THRESHOLD=50

  local UNUSABLE_READING
  for UNUSABLE_READING in "n/a" "-" "Disabled" "4 5" "45.5" "-10" "no reading"; do
    CPU1_TEMPERATURE="$UNUSABLE_READING"
    CPU2_TEMPERATURE="$UNUSABLE_READING"

    assert_cpu_is_overheating 1 "an unusable CPU 1 reading must fail safe"
    assert_cpu_is_overheating 2 "an unusable CPU 2 reading must fail safe"
  done
}

function test_a_reading_with_a_leading_zero_is_not_read_as_octal() {
  # "09" is not a valid octal number : bash used to abort on it
  export CPU_TEMPERATURE_THRESHOLD=50
  CPU1_TEMPERATURE="09"
  CPU2_TEMPERATURE="08"

  assert_cpu_is_not_overheating 1 "09 degrees is 9 degrees, not an invalid octal number"
  assert_cpu_is_not_overheating 2 "08 degrees is 8 degrees, not an invalid octal number"
}

function test_the_threshold_is_honored_whatever_its_value() {
  # The README suggests setting it just below the CPU's Tcase, which ranges from
  # about 60 degrees on an old Xeon E5 to over 90 on a recent Scalable
  local THRESHOLD
  for THRESHOLD in 0 40 60 63 85 100; do
    export CPU_TEMPERATURE_THRESHOLD="$THRESHOLD"

    CPU1_TEMPERATURE=$((THRESHOLD + 1))
    assert_cpu_is_overheating 1 "one degree above the threshold is overheating"

    CPU1_TEMPERATURE="$THRESHOLD"
    assert_cpu_is_not_overheating 1 "reaching the threshold exactly is not overheating"
  done
}

function test_temperatures_are_printed_right_aligned_on_three_characters() {
  assert_equals "  5" "$(format_temperature_for_display 5)"
  assert_equals " 45" "$(format_temperature_for_display 45)"
  assert_equals "100" "$(format_temperature_for_display 100)"
  assert_equals "  9" "$(format_temperature_for_display 09)" "a leading zero must not be read as octal"
}

function test_an_unreadable_temperature_is_printed_as_a_placeholder() {
  # printf %d would abort on any of these, taking the whole container down
  local UNUSABLE_READING
  for UNUSABLE_READING in "" "-" "n/a" "Disabled" "45.5" "-10"; do
    assert_equals "  -" "$(format_temperature_for_display "$UNUSABLE_READING")" \
      "\"$UNUSABLE_READING\" should be printed as a placeholder"
  done
}
