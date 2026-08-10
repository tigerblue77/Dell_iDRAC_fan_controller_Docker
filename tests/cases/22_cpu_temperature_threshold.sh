#!/bin/bash

# The CPU temperature threshold, and where it comes from. It is the single number
# that decides whether the server keeps running on the user's low static fan speed
# or gets handed back to Dell's own dynamic profile, so a wrong one is not a
# cosmetic problem : too high and the whole chassis stays at FAN_SPEED while the
# CPU climbs, too low and the fans never slow down at all.
#
# "auto" asks the CPUs themselves through lm-sensors. These cases cover what that
# reads, what it refuses to read, and what it falls back to.

# A coretemp chip block as "sensors -u" prints it, ready for MOCK_SENSORS_OUTPUT
# Usage : coretemp_chip $CHIP_INDEX $HIGH $CRIT
function coretemp_chip() {
  local -r CHIP_INDEX="$1"
  local -r HIGH="$2"
  local -r CRIT="$3"

  printf 'coretemp-isa-000%s\\nAdapter: ISA adapter\\nPackage id %s:\\n  temp1_input: 45.000\\n' "$CHIP_INDEX" "$CHIP_INDEX"
  [ -n "$HIGH" ] && printf '  temp1_max: %s.000\\n' "$HIGH"
  [ -n "$CRIT" ] && printf '  temp1_crit: %s.000\\n' "$CRIT"
}

function assert_detected_threshold_is() {
  local -r EXPECTED="$1"
  local -r MESSAGE="${2:-lm-sensors detection should return [$EXPECTED]}"

  local -r DETECTED=$(retrieve_CPU_high_temperature_from_lm_sensors)
  assert_equals "$EXPECTED" "$DETECTED" "$MESSAGE"
}

function test_the_high_temperature_of_a_coretemp_chip_is_detected() {
  export MOCK_SENSORS_OUTPUT="$(coretemp_chip 0 62 72)"
  assert_detected_threshold_is 62
}

function test_the_lowest_high_temperature_of_a_multi_socket_server_is_kept() {
  # The most constrained CPU is the one that has to be protected
  export MOCK_SENSORS_OUTPUT="$(coretemp_chip 0 90 100)$(coretemp_chip 1 85 95)"
  assert_detected_threshold_is 85
}

function test_a_high_temperature_equal_to_crit_is_refused() {
  # coretemp derives "high" by subtracting from TjMax an offset Intel documents as
  # reserved. A CPU that leaves it at zero reports "high" equal to "crit", i.e. the
  # temperature at which it already throttles itself. Adopting that as the point
  # where the fans are finally allowed to ramp would give them nothing to do
  export MOCK_SENSORS_OUTPUT="$(coretemp_chip 0 100 100)"
  assert_detected_threshold_is "" "a high equal to crit is the throttling point, not a fan trigger"
}

function test_a_degenerate_socket_does_not_hide_a_usable_one() {
  export MOCK_SENSORS_OUTPUT="$(coretemp_chip 0 100 100)$(coretemp_chip 1 90 100)"
  assert_detected_threshold_is 90
}

function test_a_high_temperature_without_a_crit_is_still_accepted() {
  # Nothing to compare it against, and no reason to discard a value the CPU did report
  export MOCK_SENSORS_OUTPUT="$(coretemp_chip 0 85 "")"
  assert_detected_threshold_is 85
}

function test_the_crit_alarm_flag_is_not_mistaken_for_crit() {
  # "temp1_crit_alarm" is a latching out-of-spec bit, not a temperature. Reading it
  # as the crit value would compare 62 against 0 and refuse a perfectly good sensor
  export MOCK_SENSORS_OUTPUT="$(coretemp_chip 0 62 72)  temp1_crit_alarm: 0.000\\n"
  assert_detected_threshold_is 62
}

function test_chips_that_are_not_cpus_are_ignored() {
  # An NVMe drive publishes its own, much higher "high" value. Letting it through
  # would silently raise the CPU threshold to a number about a different device
  export MOCK_SENSORS_OUTPUT="$(coretemp_chip 0 62 72)nvme-pci-0100\\nAdapter: PCI adapter\\nComposite:\\n  temp1_max: 74.850\\n  temp1_crit: 84.850\\n"
  assert_detected_threshold_is 62 "an NVMe drive's high value must not become the CPU threshold"
}

function test_amd_chips_are_ignored() {
  # k10temp hides both values on every Zen part, and on older ones its "high" is a
  # hardcoded 70°C constant in the Linux driver, on the non-physical Tctl scale.
  # Neither describes what iDRAC reports, so AMD servers must fall back instead
  export MOCK_SENSORS_OUTPUT='k10temp-pci-00c3\nAdapter: PCI adapter\ntemp1:\n  temp1_input: 30.500\n  temp1_max: 70.000\n  temp1_crit: 90.000\n'
  assert_detected_threshold_is "" "k10temp's 70°C is a driver constant, not an AMD specification"

  export MOCK_SENSORS_OUTPUT='k8temp-pci-00c3\nAdapter: PCI adapter\nCore0 Temp:\n  temp1_input: 30.000\n'
  assert_detected_threshold_is "" "k8temp publishes no limit at all"
}

function test_a_real_dual_socket_poweredge_is_read_correctly() {
  # Captured on a PowerEdge T630 : two coretemp chips at high = 83 / crit = 85, an
  # i350 NIC whose own limits are inverted (high = 120 above crit = 110), two NVMe
  # drives with no limits at all, and an ACPI power meter. Only the CPUs may count.
  #
  # This SKU is also why the gap between "high" and "crit" must not be assumed : it
  # is 2°C here, against 10°C on the CPU issue #26 was opened with
  export MOCK_SENSORS_OUTPUT='coretemp-isa-0000\nAdapter: ISA adapter\nPackage id 0:\n  temp1_input: 59.000\n  temp1_max: 83.000\n  temp1_crit: 85.000\n  temp1_crit_alarm: 0.000\nCore 0:\n  temp2_input: 52.000\n  temp2_max: 83.000\n  temp2_crit: 85.000\nnvme-pci-0200\nAdapter: PCI adapter\nComposite:\n  temp1_input: 48.850\ni350bb-pci-0100\nAdapter: PCI adapter\nloc1:\n  temp1_input: 56.000\n  temp1_max: 120.000\n  temp1_crit: 110.000\ncoretemp-isa-0001\nAdapter: ISA adapter\nPackage id 1:\n  temp1_input: 58.000\n  temp1_max: 83.000\n  temp1_crit: 85.000\npower_meter-acpi-0\nAdapter: ACPI interface\npower1:\n  power1_average: 334.000\nnvme-pci-0400\nAdapter: PCI adapter\nComposite:\n  temp1_input: 47.850\n'

  assert_detected_threshold_is 83 "the CPUs' own high value, not the NIC's 120°C nor a drive's"
}

function test_an_implausible_reading_is_refused() {
  local VALUE
  for VALUE in 3 200; do
    export MOCK_SENSORS_OUTPUT="$(coretemp_chip 0 "$VALUE" "")"
    assert_detected_threshold_is "" "${VALUE}°C is a misreading, not a threshold"
  done
}

function test_a_sensors_that_finds_nothing_detects_nothing() {
  # The usual case on a host whose kernel exposes no CPU hwmon chip
  export MOCK_SENSORS_EXIT_CODE=1
  export MOCK_SENSORS_OUTPUT=""
  assert_detected_threshold_is ""
}

function test_an_absent_lm_sensors_detects_nothing() {
  # The controller must not depend on the utility being installed : it is only
  # present because its own Dockerfile installs it, and the scripts can be run
  # directly, outside the image
  local -r ORIGINAL_PATH="$PATH"
  PATH="${PATH//$TESTS_DIRECTORY\/mocks:/}"
  export PATH

  assert_detected_threshold_is "" "no sensors binary should mean no detection, not an error"

  PATH="$ORIGINAL_PATH"
  export PATH
}

# The resolution itself, as the controller performs it at startup. It reports both
# the value and where it came from on the "CPU temperature threshold:" line, so
# running the controller and reading that line is what these cases assert on.
function assert_startup_reports() {
  local -r EXPECTED="$1"
  local -r MESSAGE="${2:-the startup log should report $EXPECTED}"

  simulate_server "PowerEdge R730xd" --cpus 2 --cpu-temperatures "42 44"
  local -r OUTPUT=$(run_controller)
  assert_contains "$OUTPUT" "$EXPECTED" "$MESSAGE"
}

function assert_startup_is_refused() {
  local -r MESSAGE="$1"

  simulate_server "PowerEdge R730xd" --cpus 2 --cpu-temperatures "42 44"
  local -r OUTPUT=$(run_controller 'Error')
  assert_contains "$OUTPUT" "CPU_TEMPERATURE_THRESHOLD" "$MESSAGE"
}

function test_auto_is_resolved_from_lm_sensors_in_local_mode() {
  # Local mode needs the host's IPMI device, which the controller checks for before
  # anything else. This case used to skip on every machine that has none, which is
  # every CI machine : provide_local_ipmi_device() gives the controller one inside
  # this run's temporary directory instead, so it runs everywhere
  provide_local_ipmi_device

  export IDRAC_HOST="local"
  export CPU_TEMPERATURE_THRESHOLD="auto"
  export MOCK_SENSORS_OUTPUT="$(coretemp_chip 0 62 72)"

  assert_startup_reports 'CPU temperature threshold: 62°C (automatically detected'
}

function test_auto_falls_back_in_network_mode() {
  # lm-sensors reads the machine the container runs on. In network mode that isn't
  # the server whose fans are being controlled, so its CPUs describe other hardware
  export CPU_TEMPERATURE_THRESHOLD="auto"
  export MOCK_SENSORS_OUTPUT="$(coretemp_chip 0 62 72)"

  assert_startup_reports 'CPU temperature threshold: 50°C (fallback value, automatic detection is only available in local mode)'
}

function test_an_explicit_value_is_used_as_is() {
  export CPU_TEMPERATURE_THRESHOLD=65
  assert_startup_reports 'CPU temperature threshold: 65°C'
}

function test_an_explicit_value_is_reported_without_a_provenance() {
  # The provenance only makes sense for a value the container chose itself
  export CPU_TEMPERATURE_THRESHOLD=65
  simulate_server "PowerEdge R730xd" --cpus 2 --cpu-temperatures "42 44"

  local -r OUTPUT=$(run_controller)
  assert_not_contains "$OUTPUT" "CPU temperature threshold: 65°C (" "a value the user set needs no explanation"
}

function test_a_padded_threshold_is_read_as_decimal_not_octal() {
  export CPU_TEMPERATURE_THRESHOLD=050
  assert_startup_reports 'CPU temperature threshold: 50°C' "050 is 50°C, not an invalid octal number"
}

function test_the_forms_an_env_file_produces_are_accepted() {
  # Docker's --env-file keeps the trailing space of "CPU_TEMPERATURE_THRESHOLD=50 ",
  # and the documented placeholder used to show quotes that get copied along. Bash's
  # own "-gt" tolerated all of these, so refusing them would turn a container that
  # had been running fine into a crash loop the moment it is updated
  local VALUE
  for VALUE in "50 " " 50" "+50" '"50"' "'50'"; do
    export CPU_TEMPERATURE_THRESHOLD="$VALUE"
    assert_startup_reports 'CPU temperature threshold: 50°C' "[$VALUE] should resolve to 50°C"
  done

  export CPU_TEMPERATURE_THRESHOLD='"auto"'
  assert_startup_reports 'CPU temperature threshold: 50°C (fallback value' 'a quoted "auto" should still be auto'
}

function test_an_unusable_threshold_stops_the_controller() {
  # Left in place, it makes every comparison fail, and a failing comparison reads as
  # "not overheating" : the server would keep running on the low static fan speed
  # and never be handed back to Dell's profile
  local VALUE
  for VALUE in "abc" "50.5" "-40" "1e2"; do
    export CPU_TEMPERATURE_THRESHOLD="$VALUE"
    assert_startup_is_refused "[$VALUE] should stop the controller"
  done
}

function test_an_implausible_threshold_stops_the_controller() {
  # "500" is a typo for 50. No CPU ever reaches it, so the Dell default profile
  # would never be restored for the life of the container. The last value is long
  # enough to wrap around 64 bits into a plausible looking number
  local VALUE
  for VALUE in 500 10 18446744073709551700; do
    export CPU_TEMPERATURE_THRESHOLD="$VALUE"
    assert_startup_is_refused "[$VALUE] should stop the controller"
  done
}

function test_both_ends_of_the_plausible_window_are_themselves_accepted() {
  # A window stated as "between 20°C and 125°C" that refuses 20 or 125 would be a
  # window the documentation describes wrongly, and the maximum is not just a bound
  # here : it is the value the refusal tells the user to set. Refusing the very
  # value the error recommends is the one way this could fail silently
  export CPU_TEMPERATURE_THRESHOLD="$MINIMUM_PLAUSIBLE_CPU_TEMPERATURE_THRESHOLD"
  assert_startup_reports "CPU temperature threshold: ${MINIMUM_PLAUSIBLE_CPU_TEMPERATURE_THRESHOLD}°C" \
    "the bottom of the plausible window should be accepted"

  export CPU_TEMPERATURE_THRESHOLD="$MAXIMUM_PLAUSIBLE_CPU_TEMPERATURE_THRESHOLD"
  assert_startup_reports "CPU temperature threshold: ${MAXIMUM_PLAUSIBLE_CPU_TEMPERATURE_THRESHOLD}°C" \
    "the top of the plausible window should be accepted, the refusal pointing users at it"
}

function test_the_refusal_names_the_window_and_what_to_set_instead() {
  # 160 is the value issue #326 was reported with. It was not a typo : setting a
  # very high threshold was how users expressed "never hand the fans back to Dell's
  # profile", there being no parameter that says so. Refusing it while naming a
  # range no document mentioned, and nothing to use instead, is what left that user
  # with a container restarting into the same error and no way to act on it
  export CPU_TEMPERATURE_THRESHOLD=160
  simulate_server "PowerEdge R730xd" --cpus 2 --cpu-temperatures "42 44"

  local -r OUTPUT=$(run_controller 'Error')

  assert_contains "$OUTPUT" \
    "between ${MINIMUM_PLAUSIBLE_CPU_TEMPERATURE_THRESHOLD}°C and ${MAXIMUM_PLAUSIBLE_CPU_TEMPERATURE_THRESHOLD}°C" \
    "the refusal should state the window rather than leave the user to find it"
  assert_contains "$OUTPUT" "set ${MAXIMUM_PLAUSIBLE_CPU_TEMPERATURE_THRESHOLD}" \
    "the refusal should name the maximum as what expresses that intent inside the window"
  assert_contains "$OUTPUT" "cannot be read" \
    "and should not let the user believe the maximum disables the safety fallback outright"
}
