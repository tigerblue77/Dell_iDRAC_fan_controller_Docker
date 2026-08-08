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
  for UNUSABLE_READING in "n/a" "-" "Disabled" "4 5" "45.5" "no reading"; do
    CPU1_TEMPERATURE="$UNUSABLE_READING"
    CPU2_TEMPERATURE="$UNUSABLE_READING"

    assert_cpu_is_overheating 1 "an unusable CPU 1 reading must fail safe"
    assert_cpu_is_overheating 2 "an unusable CPU 2 reading must fail safe"
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
    CPU1_TEMPERATURE="$SUB_ZERO_READING"
    CPU2_TEMPERATURE="$SUB_ZERO_READING"

    assert_cpu_is_not_overheating 1 "$SUB_ZERO_READING°C is below the threshold, CPU 1 is not overheating"
    assert_cpu_is_not_overheating 2 "$SUB_ZERO_READING°C is below the threshold, CPU 2 is not overheating"
  done

  # And it stays a comparison, not a string match : a threshold below the
  # reading still trips, whichever side of zero they are on
  export CPU_TEMPERATURE_THRESHOLD=-20
  CPU1_TEMPERATURE="-10"
  assert_cpu_is_overheating 1 "-10°C is above a -20°C threshold"
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

# The comment the controller prints when it hands the fans back to Dell. It is
# the only thing telling the user WHY : a server that is genuinely hot, or a
# sensor that stopped answering. Getting that wrong sends someone looking for a
# cooling problem they do not have, or ignoring one they do.
#
# The "too high" half of it is already exercised end to end in 90_integration.sh;
# what follows covers the "could not be read" half, which is what #163 added, and
# the mixed case where both reasons hold at once.
#
# The function is only ever called with CPUs the controller has already decided
# are overheating, so a valid reading here means "genuinely too hot" and an
# invalid one means "unreadable, failed safe".

readonly FAN_CONTROL_FALLBACK_ACTION="Dell default dynamic fan control profile applied for safety"

function test_the_fallback_comment_names_the_cpu_that_is_too_hot() {
  assert_equals "CPU 1 temperature is too high, $FAN_CONTROL_FALLBACK_ACTION" \
    "$(build_fan_control_fallback_comment "CPU 1" "70")"

  assert_equals "CPU 2 temperature is too high, $FAN_CONTROL_FALLBACK_ACTION" \
    "$(build_fan_control_fallback_comment "CPU 2" "70")"
}

function test_the_fallback_comment_puts_two_hot_cpus_in_the_plural() {
  assert_equals "CPU 1 and CPU 2 temperatures are too high, $FAN_CONTROL_FALLBACK_ACTION" \
    "$(build_fan_control_fallback_comment "CPU 1" "70" "CPU 2" "80")"
}

function test_the_fallback_comment_says_when_a_reading_could_not_be_read() {
  # The reason #163 exists : the fans ramping up because a sensor dropped out is
  # not the same event as the server being hot, and the log must not conflate them
  local -r COMMENT="$(build_fan_control_fallback_comment "CPU 1" "")"

  assert_equals "CPU 1 temperature could not be read, $FAN_CONTROL_FALLBACK_ACTION" "$COMMENT"
  assert_not_contains "$COMMENT" "too high" \
    "an unreadable sensor must not be reported as an overheating CPU"
}

function test_the_fallback_comment_puts_two_unreadable_cpus_in_the_plural() {
  assert_equals "CPU 1 and CPU 2 temperatures could not be read, $FAN_CONTROL_FALLBACK_ACTION" \
    "$(build_fan_control_fallback_comment "CPU 1" "" "CPU 2" "")"
}

function test_the_fallback_comment_tells_a_hot_cpu_from_an_unreadable_one() {
  # Both reasons hold at once : one CPU is genuinely too hot, the other's sensor
  # stopped answering. The comment must carry both, and attribute each to the
  # right CPU rather than collapsing them
  assert_equals "CPU 1 temperature is too high and CPU 2 temperature could not be read, $FAN_CONTROL_FALLBACK_ACTION" \
    "$(build_fan_control_fallback_comment "CPU 1" "70" "CPU 2" "")"

  # The reasons are grouped by kind, not by CPU order : whichever CPU is hot is
  # named first, so swapping the roles swaps the order of the two halves
  assert_equals "CPU 2 temperature is too high and CPU 1 temperature could not be read, $FAN_CONTROL_FALLBACK_ACTION" \
    "$(build_fan_control_fallback_comment "CPU 1" "" "CPU 2" "80")"
}

function test_every_shape_of_unusable_reading_is_reported_as_unreadable() {
  # Whatever the sensor answered, if it is not a number it is not a temperature
  local UNUSABLE_READING
  for UNUSABLE_READING in "" "-" "n/a" "Disabled" "45.5" "no reading"; do
    assert_equals "CPU 1 temperature could not be read, $FAN_CONTROL_FALLBACK_ACTION" \
      "$(build_fan_control_fallback_comment "CPU 1" "$UNUSABLE_READING")" \
      "\"$UNUSABLE_READING\" is not a reading"
  done
}

function test_the_fallback_comment_always_says_what_was_done_about_it() {
  # Whichever branch produced the reason, the user must be told the fans were
  # handed back to Dell's own profile
  local -r COMMENTS=(
    "$(build_fan_control_fallback_comment "CPU 1" "70")"
    "$(build_fan_control_fallback_comment "CPU 1" "")"
    "$(build_fan_control_fallback_comment "CPU 1" "70" "CPU 2" "80")"
    "$(build_fan_control_fallback_comment "CPU 1" "" "CPU 2" "")"
    "$(build_fan_control_fallback_comment "CPU 1" "70" "CPU 2" "")"
  )

  local COMMENT
  for COMMENT in "${COMMENTS[@]}"; do
    assert_contains "$COMMENT" "$FAN_CONTROL_FALLBACK_ACTION"
  done
}

function test_reasons_are_joined_the_way_a_sentence_is() {
  # join_with_and builds every list above. Its three-and-more branch is not
  # reachable with two CPUs, but it is written, and it is what a controller
  # monitoring every socket would use
  assert_equals "CPU 1" "$(join_with_and "CPU 1")"
  assert_equals "CPU 1 and CPU 2" "$(join_with_and "CPU 1" "CPU 2")"
  assert_equals "CPU 1, CPU 2 and CPU 3" "$(join_with_and "CPU 1" "CPU 2" "CPU 3")"
  assert_equals "CPU 1, CPU 2, CPU 3 and CPU 4" "$(join_with_and "CPU 1" "CPU 2" "CPU 3" "CPU 4")"
}
