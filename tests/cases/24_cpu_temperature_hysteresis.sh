#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# CPU_TEMPERATURE_HYSTERESIS : the band by which the fallback to Dell's profile ends lower than it
# began. Without it a CPU sitting on the threshold crosses it in both directions every CHECK_INTERVAL
# and the fans pulse between the user's speed and Dell's for as long as the load lasts (#242, #406).
#
# Everything here is safety-adjacent rather than safety-critical : the band can only ever DELAY the
# return to the user's (low) profile, never the departure from it, so a bug here makes the fans louder
# than asked and not quieter. The cases that pin that asymmetry are the ones worth keeping.

# is_any_CPU_overheating() reads the detected CPUs and the current profile from globals, so these
# helpers set the whole decision context in one line and keep the failure diagnostics readable.
# Deliberately named apart from 80_temperature_thresholds.sh's own helpers : every case file is sourced
# into one shell, and two definitions of one name would silently replace each other
function given_a_server_running_on_the_dell_profile() {
  HYSTERESIS_DETECTED_CPU_TEMPERATURES=("$@")
  IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED=true
  IS_FIRST_MONITORING_CYCLE=false
  apply_the_hysteresis_decision_context
}

function given_a_server_running_on_the_users_profile() {
  HYSTERESIS_DETECTED_CPU_TEMPERATURES=("$@")
  IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED=false
  IS_FIRST_MONITORING_CYCLE=false
  apply_the_hysteresis_decision_context
}

function given_a_server_on_its_first_monitoring_cycle() {
  HYSTERESIS_DETECTED_CPU_TEMPERATURES=("$@")
  # What the controller itself starts from : Dell holds the fans until the first cycle says otherwise
  IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED=true
  IS_FIRST_MONITORING_CYCLE=true
  apply_the_hysteresis_decision_context
}

function apply_the_hysteresis_decision_context() {
  DETECTED_CPU_TEMPERATURES=("${HYSTERESIS_DETECTED_CPU_TEMPERATURES[@]}")
  DETECTED_CPU_ENTITY_IDS=()
  DETECTED_CPU_LABELS=()

  local INDEX
  for INDEX in "${!DETECTED_CPU_TEMPERATURES[@]}"; do
    DETECTED_CPU_ENTITY_IDS+=("3.$((INDEX + 1))")
    DETECTED_CPU_LABELS+=("CPU $((INDEX + 1))")
  done
}

# The default messages carry no apostrophe on purpose : inside "${1:-...}" bash reads one as opening a
# real single quote, which then swallows everything up to the next one -- including whatever function
# is declared next, which ends up nested inside this one rather than defined. "bash -n" sees nothing
function assert_the_fallback_holds() {
  local -r MESSAGE="${1:-the fallback to the Dell profile should still be held}"

  if is_any_CPU_overheating; then
    pass
  else
    fail "$MESSAGE" \
      "readings:   [${DETECTED_CPU_TEMPERATURES[*]}]" \
      "threshold:  [$CPU_TEMPERATURE_THRESHOLD]" \
      "hysteresis: [$CPU_TEMPERATURE_HYSTERESIS]" \
      "bound used: [$APPLIED_CPU_TEMPERATURE_BOUND]"
  fi
}

function assert_the_fallback_ends() {
  local -r MESSAGE="${1:-the user fan control profile should be restored}"

  if is_any_CPU_overheating; then
    fail "$MESSAGE" \
      "readings:   [${DETECTED_CPU_TEMPERATURES[*]}]" \
      "threshold:  [$CPU_TEMPERATURE_THRESHOLD]" \
      "hysteresis: [$CPU_TEMPERATURE_HYSTERESIS]" \
      "bound used: [$APPLIED_CPU_TEMPERATURE_BOUND]"
  else
    pass
  fi
}

# --- The decision itself -----------------------------------------------------------------------

function test_a_temperature_inside_the_band_does_not_end_the_fallback() {
  # The whole point of the parameter : 65°C is back under the 70°C threshold that opened the fallback,
  # and handing the fans back there is exactly what makes them pulse
  export CPU_TEMPERATURE_THRESHOLD=70 CPU_TEMPERATURE_HYSTERESIS=10
  given_a_server_running_on_the_dell_profile 65 64

  assert_the_fallback_holds "65°C is inside the 60-70°C band, the fallback must hold"
}

function test_a_temperature_at_the_resume_point_ends_the_fallback() {
  # The bound is inclusive on this side exactly as the threshold is on the other : the README describes
  # the threshold as the value "beyond which" Dell's profile takes over, and reaching either exactly is
  # still on the calm side of it
  export CPU_TEMPERATURE_THRESHOLD=70 CPU_TEMPERATURE_HYSTERESIS=10
  given_a_server_running_on_the_dell_profile 60 58

  assert_the_fallback_ends "60°C is the resume point itself, the user's profile must come back"
}

function test_a_temperature_below_the_resume_point_ends_the_fallback() {
  export CPU_TEMPERATURE_THRESHOLD=70 CPU_TEMPERATURE_HYSTERESIS=10
  given_a_server_running_on_the_dell_profile 45 44

  assert_the_fallback_ends
}

function test_the_hottest_cpu_alone_can_hold_the_fallback() {
  # Symmetric with the threshold's own rule : one CPU is enough to open the fallback, so one CPU has to
  # be enough to hold it. A four socket server whose CPU 4 is still inside the band must not have its
  # fans handed back because the other three cooled down
  export CPU_TEMPERATURE_THRESHOLD=70 CPU_TEMPERATURE_HYSTERESIS=10
  given_a_server_running_on_the_dell_profile 45 44 46 65

  assert_the_fallback_holds "CPU 4 is still inside the band"
}

function test_the_band_never_delays_the_departure_to_the_dell_profile() {
  # The asymmetry that makes this parameter safe : while the user's profile is the applied one, the
  # threshold governs alone. A 65°C reading with a 10°C band is calm, and a 71°C one is handed to Dell
  # on that very cycle rather than at 71+10
  export CPU_TEMPERATURE_THRESHOLD=70 CPU_TEMPERATURE_HYSTERESIS=10
  given_a_server_running_on_the_users_profile 65 64
  assert_the_fallback_ends "the band must not lower the temperature the fallback fires at"

  given_a_server_running_on_the_users_profile 71 64
  assert_the_fallback_holds "71°C is above the threshold, the fallback must fire on this cycle"
}

function test_the_first_monitoring_cycle_decides_on_the_threshold_itself() {
  # It establishes a profile rather than changing one, and the flag it reads starts at true. Honouring
  # the band there would leave a server idling inside it on Dell's profile for the life of the
  # container, its FAN_SPEED never once applied -- a container that looks like it is doing nothing
  export CPU_TEMPERATURE_THRESHOLD=70 CPU_TEMPERATURE_HYSTERESIS=10
  given_a_server_on_its_first_monitoring_cycle 65 64

  assert_the_fallback_ends "the first cycle must take the fans on the threshold, not on the band"
}

function test_no_hysteresis_decides_exactly_as_before() {
  # The default, and the behaviour of every version that shipped before this parameter existed : one
  # bound in both directions. This is the regression guard for every user who sets nothing
  export CPU_TEMPERATURE_THRESHOLD=70 CPU_TEMPERATURE_HYSTERESIS=0
  given_a_server_running_on_the_dell_profile 65 64
  assert_the_fallback_ends "with no band, 65°C is simply back under the threshold"

  given_a_server_running_on_the_dell_profile 70 70
  assert_the_fallback_ends "the threshold itself is still not overheating"

  given_a_server_running_on_the_dell_profile 71 70
  assert_the_fallback_holds "above the threshold is still overheating"
}

function test_an_unreadable_reading_is_held_by_the_band_like_a_hot_one() {
  # Dell's profile is applied both for a CPU that is too hot and for one that cannot be read at all, and
  # the return is governed by one rule whatever opened it : every CPU readable AND at or below the
  # resume point. A single reading landing just under the threshold after a spell of dead sensors is
  # not enough to take the fans back
  export CPU_TEMPERATURE_THRESHOLD=70 CPU_TEMPERATURE_HYSTERESIS=10
  given_a_server_running_on_the_dell_profile "" 64
  assert_the_fallback_holds "an unreadable CPU still holds the fallback"

  given_a_server_running_on_the_dell_profile 65 64
  assert_the_fallback_holds "readable again, but still inside the band"

  given_a_server_running_on_the_dell_profile 59 58
  assert_the_fallback_ends "readable and under the resume point, the fallback ends"
}

function test_an_unusable_threshold_still_fails_safe_with_a_band_configured() {
  # The threshold is the bound the band is subtracted from : with no usable threshold there is no usable
  # bound either, and the answer that keeps a hot CPU on the user's low speed is the one this function
  # must never give. The band must not turn "unusable" into a number
  export CPU_TEMPERATURE_THRESHOLD="auto" CPU_TEMPERATURE_HYSTERESIS=10
  given_a_server_running_on_the_dell_profile 30 30

  assert_the_fallback_holds "an unusable threshold must fail safe whatever the band says"
}

function test_an_unusable_band_is_read_as_no_band_rather_than_crashing() {
  # Dell_iDRAC_fan_controller.sh refuses these before the loop starts, so this is not reachable from the
  # container. It is what keeps the answer safe on its own terms rather than by depending on a check
  # living in another file, which is the rule is_any_CPU_overheating() already follows for the threshold
  local VALUE
  for VALUE in "abc" "10.5" "-10" ""; do
    export CPU_TEMPERATURE_THRESHOLD=70 CPU_TEMPERATURE_HYSTERESIS="$VALUE"
    given_a_server_running_on_the_dell_profile 65 64

    assert_the_fallback_ends "[$VALUE] should be read as no band at all, not crash the comparison"
  done
}

function test_a_band_with_a_leading_zero_is_not_read_as_octal() {
  # "010" is 10°C, not 8°C. The same trap the threshold and the fan speed each had
  export CPU_TEMPERATURE_THRESHOLD=70 CPU_TEMPERATURE_HYSTERESIS=010
  given_a_server_running_on_the_dell_profile 61 60
  assert_the_fallback_holds "010 should be a 10°C band, resuming at 60°C"

  given_a_server_running_on_the_dell_profile 60 60
  assert_the_fallback_ends "010 should be a 10°C band, resuming at 60°C"
}

function test_the_bound_actually_compared_against_is_published() {
  # The comment column names it, and naming the threshold instead would print a temperature nothing was
  # measured against on the very line a user reads to understand why the fans just changed
  export CPU_TEMPERATURE_THRESHOLD=70 CPU_TEMPERATURE_HYSTERESIS=10

  given_a_server_running_on_the_dell_profile 45 44
  is_any_CPU_overheating
  assert_equals "60" "$APPLIED_CPU_TEMPERATURE_BOUND" "leaving the fallback is decided on the resume point"

  given_a_server_running_on_the_users_profile 45 44
  is_any_CPU_overheating
  assert_equals "70" "$APPLIED_CPU_TEMPERATURE_BOUND" "entering it is decided on the threshold"

  given_a_server_on_its_first_monitoring_cycle 45 44
  is_any_CPU_overheating
  assert_equals "70" "$APPLIED_CPU_TEMPERATURE_BOUND" "the first cycle is decided on the threshold"
}

# --- The parameter, as the controller resolves it at startup -----------------------------------

function assert_hysteresis_startup_reports() {
  local -r EXPECTED="$1"
  local -r MESSAGE="${2:-the startup log should report $EXPECTED}"

  simulate_server "PowerEdge R730xd" --cpus 2 --cpu-temperatures "42 44"
  local -r OUTPUT=$(run_controller)
  assert_contains "$OUTPUT" "$EXPECTED" "$MESSAGE"
}

function assert_hysteresis_startup_is_refused() {
  local -r MESSAGE="$1"

  simulate_server "PowerEdge R730xd" --cpus 2 --cpu-temperatures "42 44"
  local -r OUTPUT=$(run_controller 'Error')
  assert_contains "$OUTPUT" "CPU_TEMPERATURE_HYSTERESIS" "$MESSAGE"
}

function test_the_startup_log_states_the_temperature_the_profile_comes_back_at() {
  # The band is what the user sets, the temperature is what the controller acts on and what they have to
  # recognise in the comment column later
  export CPU_TEMPERATURE_THRESHOLD=70 CPU_TEMPERATURE_HYSTERESIS=10
  assert_hysteresis_startup_reports "CPU temperature hysteresis: 10°C (your fan control profile is restored at 60°C"
}

function test_the_startup_log_says_so_when_no_band_is_configured() {
  # Printed rather than omitted : a reader diagnosing pulsing fans needs to see that the parameter
  # exists and is off, not to find nothing and conclude the container has no such setting
  export CPU_TEMPERATURE_THRESHOLD=70 CPU_TEMPERATURE_HYSTERESIS=0
  assert_hysteresis_startup_reports "CPU temperature hysteresis: Disabled"
}

function test_the_band_is_measured_against_the_resolved_threshold() {
  # On "auto" the threshold is only a number once lm-sensors has answered, which is why the validation
  # runs after that resolution rather than with the other parameters at the top of the file
  provide_local_ipmi_device

  export IDRAC_HOST="local"
  export CPU_TEMPERATURE_THRESHOLD="auto"
  export CPU_TEMPERATURE_HYSTERESIS=10
  export MOCK_SENSORS_OUTPUT="$(coretemp_chip 0 62 72)"

  assert_hysteresis_startup_reports "your fan control profile is restored at 52°C" \
    "the band should be subtracted from the threshold the container resolved, not from a default"
}

function test_the_forms_an_env_file_produces_are_accepted_for_the_band() {
  # Docker's --env-file keeps the trailing space of a "CPU_TEMPERATURE_HYSTERESIS=10 " line, and copying
  # the documented placeholder can carry quotes along. The threshold beside it tolerates all of these,
  # and a parameter that did not would turn a working configuration into a crash loop on update
  export CPU_TEMPERATURE_THRESHOLD=70

  local VALUE
  for VALUE in "10 " " 10" "+10" '"10"' "'10'" "010"; do
    export CPU_TEMPERATURE_HYSTERESIS="$VALUE"
    assert_hysteresis_startup_reports "CPU temperature hysteresis: 10°C" "[$VALUE] should resolve to a 10°C band"
  done

  export CPU_TEMPERATURE_HYSTERESIS=""
  assert_hysteresis_startup_reports "CPU temperature hysteresis: Disabled" "an empty value should mean no band"
}

function test_an_unusable_band_stops_the_controller() {
  # A negative value is refused rather than read as "no band" : it names the opposite intention --
  # restoring the user's profile ABOVE the threshold the fallback fired on -- and silently doing nothing
  # with it would leave the fans pulsing the parameter was set to stop
  export CPU_TEMPERATURE_THRESHOLD=70

  local VALUE
  for VALUE in "abc" "10.5" "-10" "1e1"; do
    export CPU_TEMPERATURE_HYSTERESIS="$VALUE"
    assert_hysteresis_startup_is_refused "[$VALUE] should stop the controller"
  done
}

function test_a_band_that_could_never_be_climbed_back_out_of_stops_the_controller() {
  # The mirror of the threshold's own plausibility window : a band wide enough to push the resume point
  # under 20°C means the fallback fires normally and then never ends, the server staying on Dell's
  # profile for the life of the container while the startup log prints a fan speed nothing applies
  export CPU_TEMPERATURE_THRESHOLD=70 CPU_TEMPERATURE_HYSTERESIS=51
  assert_hysteresis_startup_is_refused "a band resuming at 19°C should stop the controller"

  export CPU_TEMPERATURE_THRESHOLD=70 CPU_TEMPERATURE_HYSTERESIS=999
  assert_hysteresis_startup_is_refused "a band wider than the threshold should stop the controller"
}

function test_the_widest_usable_band_is_itself_accepted() {
  # A bound the documentation states but that refuses exactly it is a bound described wrongly, and an
  # off-by-one here is invisible until somebody sets precisely the maximum
  export CPU_TEMPERATURE_THRESHOLD=70
  export CPU_TEMPERATURE_HYSTERESIS=$((70 - MINIMUM_PLAUSIBLE_CPU_TEMPERATURE_THRESHOLD))

  assert_hysteresis_startup_reports "your fan control profile is restored at ${MINIMUM_PLAUSIBLE_CPU_TEMPERATURE_THRESHOLD}°C" \
    "the widest band that still leaves a plausible resume point should be accepted"
}

function test_the_refusal_says_what_the_band_would_cost_rather_than_only_a_bound() {
  # The lesson of #326, applied to this parameter : a bound quoted without its reason is what leaves a
  # user restarting into the same error. It also names the maximum against THEIR threshold, that
  # maximum being a different number for every threshold
  export CPU_TEMPERATURE_THRESHOLD=70 CPU_TEMPERATURE_HYSTERESIS=60
  simulate_server "PowerEdge R730xd" --cpus 2 --cpu-temperatures "42 44"

  local -r OUTPUT=$(run_controller 'Error')

  assert_contains "$OUTPUT" "at most 50°C" "the refusal should name the maximum for the threshold in use"
  assert_contains "$OUTPUT" "never end" "the refusal should say what the band would cost, not only that it is too wide"
}

# --- The whole controller, across cycles -------------------------------------------------------

function test_the_controller_keeps_the_dell_profile_while_the_temperature_is_inside_the_band() {
  # The end to end case, and the one #406 reported : the server is handed to Dell above the threshold,
  # cools back under it, and must NOT be taken back until it reaches the resume point
  export CPU_TEMPERATURE_THRESHOLD=70 CPU_TEMPERATURE_HYSTERESIS=10

  simulate_server "PowerEdge R730xd" --cpus 2 --cpu-temperatures "78 44"
  export MOCK_IPMITOOL_SDR_SECOND_OUTPUT
  MOCK_IPMITOOL_SDR_SECOND_OUTPUT=$(make_sdr_output --cpus 2 --cpu-temperatures "65 44")
  export MOCK_IPMITOOL_SDR_SWITCH_AFTER_CALLS=1

  local -r OUTPUT=$(run_controller "65°C")

  assert_contains "$OUTPUT" "65°C" "the second cycle must have been reached"
  assert_not_contains "$OUTPUT" "temperatures are now OK" \
    "65°C is inside the band, the controller must not announce a return to the user's profile"
  assert_not_contains "$OUTPUT" "CPU temperature is now OK" \
    "65°C is inside the band, the controller must not announce a return to the user's profile"
}

function test_the_controller_takes_the_fans_back_once_the_resume_point_is_reached() {
  # The other half of the same story, and what keeps the case above from passing on a controller that
  # simply never restores anything
  export CPU_TEMPERATURE_THRESHOLD=70 CPU_TEMPERATURE_HYSTERESIS=10

  simulate_server "PowerEdge R730xd" --cpus 2 --cpu-temperatures "78 44"
  export MOCK_IPMITOOL_SDR_SECOND_OUTPUT
  MOCK_IPMITOOL_SDR_SECOND_OUTPUT=$(make_sdr_output --cpus 2 --cpu-temperatures "59 44")
  export MOCK_IPMITOOL_SDR_SWITCH_AFTER_CALLS=1

  local -r OUTPUT=$(run_controller "temperatures are now OK")

  assert_contains "$OUTPUT" "All CPU temperatures are now OK (<= 60°C)" \
    "the comment should name the resume point it was actually decided on, not the threshold"
}

function test_without_a_band_the_controller_takes_the_fans_back_under_the_threshold() {
  # The regression guard at the controller level : the very readings the band held above are handed
  # straight back to the user's profile when no band is configured, which is what every existing
  # deployment does today
  export CPU_TEMPERATURE_THRESHOLD=70 CPU_TEMPERATURE_HYSTERESIS=0

  simulate_server "PowerEdge R730xd" --cpus 2 --cpu-temperatures "78 44"
  export MOCK_IPMITOOL_SDR_SECOND_OUTPUT
  MOCK_IPMITOOL_SDR_SECOND_OUTPUT=$(make_sdr_output --cpus 2 --cpu-temperatures "65 44")
  export MOCK_IPMITOOL_SDR_SWITCH_AFTER_CALLS=1

  local -r OUTPUT=$(run_controller "temperatures are now OK")

  assert_contains "$OUTPUT" "All CPU temperatures are now OK (<= 70°C)" \
    "with no band the threshold governs both directions, exactly as before"
}
