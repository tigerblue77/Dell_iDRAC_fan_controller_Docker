#!/bin/bash

# The three boolean parameters, which the controller dispatches by running their
# value as a command : "if $MONITORING_ONLY_MODE; then". That idiom is exact for
# the two literals and a trap for everything else, because everything else is a
# command too. A spelling naming nothing exits 127 and is read as false, so
# MONITORING_ONLY_MODE=True takes the fans on a server the operator asked it not
# to touch ; a spelling naming something real runs it, so =yes never returns.

function assert_boolean_is_refused() {
  local -r PARAMETER_NAME="$1"
  local -r VALUE="$2"
  local -r MESSAGE="${3:-\"$VALUE\" should stop the controller}"

  # The call has to happen in the subshell a command substitution creates : the
  # exit inside print_error_and_exit would otherwise take the test runner down
  local OUTPUT
  OUTPUT=$(validate_boolean_parameter "$PARAMETER_NAME" "$VALUE" 2>&1)
  local -r EXIT_CODE=$?

  assert_equals 1 "$EXIT_CODE" "$MESSAGE"
  assert_contains "$OUTPUT" "$PARAMETER_NAME" "the error should name the parameter at fault"
}

function assert_boolean_is_accepted() {
  local -r PARAMETER_NAME="$1"
  local -r VALUE="$2"

  local OUTPUT
  OUTPUT=$(validate_boolean_parameter "$PARAMETER_NAME" "$VALUE" 2>&1)
  local -r EXIT_CODE=$?

  assert_equals 0 "$EXIT_CODE" "\"$VALUE\" is what the dispatch idiom expects and should be accepted"
  assert_empty "$OUTPUT" "accepting a value should print nothing"
}

# The three parameters the user supplies, all read through the same idiom
readonly BOOLEAN_PARAMETERS=(
  "MONITORING_ONLY_MODE"
  "DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE"
  "KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT"
)

function test_the_two_literals_are_accepted() {
  local PARAMETER_NAME
  for PARAMETER_NAME in "${BOOLEAN_PARAMETERS[@]}"; do
    assert_boolean_is_accepted "$PARAMETER_NAME" "true"
    assert_boolean_is_accepted "$PARAMETER_NAME" "false"
  done
}

function test_a_capitalised_spelling_stops_the_controller() {
  # These are the values that used to be read as false without a word. The mode
  # they silently disabled is the one the README tells users to run first,
  # precisely to check the container before letting it touch the fans
  local VALUE
  for VALUE in "True" "TRUE" "False" "FALSE"; do
    assert_boolean_is_refused "MONITORING_ONLY_MODE" "$VALUE"
  done
}

function test_a_plausible_boolean_spelling_stops_the_controller() {
  # Every one of these is a perfectly reasonable thing for a user to write, and
  # every one of them meant false whatever it said
  local VALUE
  for VALUE in "1" "0" "on" "off" "Yes" "No" "enabled" "disabled" ""; do
    assert_boolean_is_refused "MONITORING_ONLY_MODE" "$VALUE"
  done
}

function test_an_unfilled_env_placeholder_stops_the_controller() {
  # docker takes everything after the "=" verbatim, so a .env copied but not
  # filled in arrives as its own placeholder text rather than as an empty value
  local -r PLACEHOLDER="<true or false>"

  assert_boolean_is_refused "MONITORING_ONLY_MODE" "$PLACEHOLDER"

  # The value has to be quoted back at the user, not merely described. This is
  # the needle that proves it : the two literals the message lists are in its
  # static text, so asserting on either of those would pass without the value
  # ever being interpolated
  local -r OUTPUT=$(validate_boolean_parameter "MONITORING_ONLY_MODE" "$PLACEHOLDER" 2>&1)

  assert_contains "$OUTPUT" "$PLACEHOLDER" "the error should quote the offending value back"
}

function test_the_three_parameters_are_all_validated() {
  # The exit-time booleans invert the user's intent just as quietly : =True on
  # KEEP_..._ON_EXIT resets on exit the very state its name asks to keep
  local PARAMETER_NAME
  for PARAMETER_NAME in "${BOOLEAN_PARAMETERS[@]}"; do
    assert_boolean_is_refused "$PARAMETER_NAME" "True"
    assert_boolean_is_refused "$PARAMETER_NAME" "1"
  done
}

function test_the_validation_never_runs_the_value_it_is_given() {
  # The unquoted occurrences word-split, so a value carrying arguments used to
  # run with them. The validation that now guards them must not reproduce that :
  # it compares the value, it never dispatches it
  local -r WITNESS="$TEST_TEMPORARY_DIRECTORY/the_value_was_executed"
  rm -f "$WITNESS"

  assert_boolean_is_refused "MONITORING_ONLY_MODE" "touch $WITNESS"

  assert_command_fails "validating a value must not execute it, whatever it names" \
    test -e "$WITNESS"
}

function test_the_error_says_what_is_accepted_and_why() {
  local -r OUTPUT=$(validate_boolean_parameter "MONITORING_ONLY_MODE" "yes" 2>&1)

  assert_contains "$OUTPUT" "yes" "the error should quote the offending value"
  assert_contains "$OUTPUT" "true" "the error should say which values are accepted"
  assert_contains "$OUTPUT" "false" "the error should name both of them"
}

function test_the_controller_refuses_to_start_on_a_capitalised_boolean() {
  export MONITORING_ONLY_MODE="True"

  local OUTPUT
  OUTPUT=$(run_controller)
  local -r EXIT_CODE=$?

  assert_equals 1 "$EXIT_CODE" "a value that is not one of the two literals should stop the controller"
  assert_contains "$OUTPUT" "MONITORING_ONLY_MODE" "the error should name the parameter at fault"
  assert_empty "$(recorded_ipmitool_calls)" \
    "the booleans are validated before the first IPMI command, so a refused value costs no iDRAC session"
}

function test_the_controller_no_longer_seizes_the_fans_on_a_capitalised_monitoring_mode() {
  # The defect this replaces : MONITORING_ONLY_MODE=True was read as false, so
  # the container disabled Dell's dynamic fan control and pinned the fans on a
  # server the operator had explicitly asked it to leave alone, all while
  # logging "Monitoring only mode: Disabled"
  export MONITORING_ONLY_MODE="True"

  run_controller > /dev/null

  assert_equals 0 "$(count_ipmitool_calls_matching "raw 0x30 0x30")" \
    "no fan control command should reach a server whose operator asked for monitoring only"
}

function test_the_controller_refuses_to_start_on_each_of_the_three_booleans() {
  local PARAMETER_NAME OUTPUT
  for PARAMETER_NAME in "${BOOLEAN_PARAMETERS[@]}"; do
    setup_test_context
    export "$PARAMETER_NAME=True"

    OUTPUT=$(run_controller)

    assert_contains "$OUTPUT" "$PARAMETER_NAME" \
      "$PARAMETER_NAME should be validated too, not just the monitoring mode"
  done
}

function test_the_monitoring_mode_is_validated_before_the_check_interval_reads_it() {
  # validate_check_interval_parameter takes the mode as an argument, to decide
  # whether the reaction time bounds apply. It must receive a value that has
  # already been checked, or an unusable mode would silently pick the bounds
  export MONITORING_ONLY_MODE="True"
  export CHECK_INTERVAL="2h"

  local -r OUTPUT=$(run_controller)

  assert_contains "$OUTPUT" "MONITORING_ONLY_MODE" \
    "the mode should be reported first, being what decides how the interval is judged"
  assert_not_contains "$OUTPUT" "CHECK_INTERVAL" \
    "the interval should not be judged against a mode that was never valid"
}

function test_the_controller_does_not_hang_on_a_boolean_naming_a_real_command() {
  # "yes" is /usr/bin/yes, so the branch never returned : the container filled
  # the log at hundreds of megabytes a second and, that binary running in the
  # foreground, the graceful_exit trap stayed deferred, so docker stop could not
  # end it and only SIGKILL did.
  #
  # This case is deliberately not run through run_controller : it waits on the
  # controller after signaling it, and a regression here would never answer that
  # signal, so the suite would hang instead of going red. The timeout bounds the
  # wait ; head bounds the disk, a regression being killed by SIGPIPE as soon as
  # it writes past what head reads, long before it can fill anything. PIPESTATUS
  # is what carries the controller's own exit code out of that pipeline
  export MONITORING_ONLY_MODE="yes"

  local OUTPUT
  OUTPUT=$(cd "$REPO_ROOT" && timeout 10 bash ./Dell_iDRAC_fan_controller.sh 2>&1 | head -c 2048; exit "${PIPESTATUS[0]}")
  local -r EXIT_CODE=$?

  # Anything but a clean refusal is the defect : 124 if it looped until the
  # timeout, 141 if head cut it short, 0 if it somehow carried on
  assert_equals 1 "$EXIT_CODE" "the controller should refuse the value and exit, not loop on it"
  assert_contains "$OUTPUT" "MONITORING_ONLY_MODE" "it should stop by naming the parameter at fault"
}
