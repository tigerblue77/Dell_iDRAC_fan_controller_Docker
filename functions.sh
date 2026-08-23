#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# shellcheck disable=SC2034  # Every function/constant here is consumed by the scripts that source this file, not by this file itself

# Define global functions
# This function applies Dell's default dynamic fan control profile
# In monitoring only mode, the profile is only logged, not actually applied
function apply_Dell_default_fan_control_profile() {
  if "$MONITORING_ONLY_MODE"; then
    CURRENT_FAN_CONTROL_PROFILE="Dell default dynamic fan control profile (monitoring only, not applied)"
    return
  fi
  # A server that answered "I will not do this" answers it again every cycle, so the command is not sent
  # any more once it has. The fans are Dell's own -- they are what the refused command would have taken
  # them from -- which is what the badge says
  if has_the_server_refused_fan_control; then
    CURRENT_FAN_CONTROL_PROFILE="Dell default dynamic fan control profile (refused)"
    return 1
  fi
  # Use ipmitool to send the raw command to set fan control to Dell default.
  # Some iDRAC/BMC firmwares print a harmless protocol warning on stderr (e.g. "Received an Unexpected
  # message...") even when the command actually succeeds. Rather than discard stderr unconditionally (which
  # would also hide a genuine failure to apply this safety-critical profile), capture it and only surface it
  # if the command actually failed (non-zero exit code)
  local ipmitool_stderr
  ipmitool_stderr=$(ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0x30 0x01 0x01 2>&1 >/dev/null)
  # shellcheck disable=SC2181  # $? here is the command substitution above, already run; there is no direct command left to negate
  if [ $? -ne 0 ]; then
    print_error "Failed to apply Dell default fan control profile. ipmitool said: $ipmitool_stderr"
    note_that_the_server_refuses_fan_control "$ipmitool_stderr"
    # The table says what the server is actually doing, not what was attempted : this profile is the
    # safety fallback, so claiming it while the command was refused is the one lie that matters here
    CURRENT_FAN_CONTROL_PROFILE="Dell default dynamic fan control profile (not applied)"
    return 1
  fi
  HAS_FAN_CONTROL_EVER_BEEN_ACCEPTED=true
  CURRENT_FAN_CONTROL_PROFILE="Dell default dynamic fan control profile"
}

# This function applies a user-specified static fan control profile
# In monitoring only mode, the profile is only logged, not actually applied
function apply_user_fan_control_profile() {
  if "$MONITORING_ONLY_MODE"; then
    CURRENT_FAN_CONTROL_PROFILE="User static fan control profile ($DECIMAL_FAN_SPEED%) (monitoring only, not applied)"
    return
  fi
  # Same as above : a server that refused to hand its fans over is not asked again, and the profile it
  # is actually running -- Dell's own, since the refused command is the one that would have taken the
  # fans from it -- is what the table reports rather than a user profile that was never applied
  if has_the_server_refused_fan_control; then
    CURRENT_FAN_CONTROL_PROFILE="Dell default dynamic fan control profile (refused)"
    return 1
  fi
  # Use ipmitool to send the raw command to set fan control to user-specified value.
  # Same reasoning as apply_Dell_default_fan_control_profile: only surface stderr if the command
  # actually failed, instead of always discarding it (this profile changes real fan speed)
  # Both commands have to land for the profile to be the one the server is running : the first takes
  # fan control away from Dell's own dynamic profile, the second sets the speed. Failing the first and
  # succeeding the second is not a partial success but the worst case -- the fans are still Dell's to
  # drive -- so either failure means the profile was not applied
  local ipmitool_stderr
  local IS_PROFILE_APPLIED=true
  # What the server answered to the command that takes the fans, kept until both commands have run so
  # that the verdict below is drawn after everything this cycle had to say, rather than between two
  # error lines it would then look like it did not cover
  local MANUAL_FAN_CONTROL_STDERR=""

  ipmitool_stderr=$(ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0x30 0x01 0x00 2>&1 >/dev/null)
  # shellcheck disable=SC2181  # $? here is the command substitution above, already run; there is no direct command left to negate
  if [ $? -ne 0 ]; then
    print_error "Failed to enable manual fan control. ipmitool said: $ipmitool_stderr"
    MANUAL_FAN_CONTROL_STDERR="$ipmitool_stderr"
    IS_PROFILE_APPLIED=false
  else
    HAS_FAN_CONTROL_EVER_BEEN_ACCEPTED=true
  fi
  ipmitool_stderr=$(ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0x30 0x02 0xff $HEXADECIMAL_FAN_SPEED 2>&1 >/dev/null)
  # shellcheck disable=SC2181  # $? here is the command substitution above, already run; there is no direct command left to negate
  if [ $? -ne 0 ]; then
    print_error "Failed to set fan speed to $DECIMAL_FAN_SPEED%. ipmitool said: $ipmitool_stderr"
    # A server that answered "invalid data field" ran the command and refused an argument, which is a
    # different situation from the refusals below and gets its own explanation -- once, rather than as
    # a raw ipmitool line on every cycle. It settles nothing and stops nothing being sent
    note_that_the_server_rejects_the_broadcast_fan_selector "$ipmitool_stderr"
    IS_PROFILE_APPLIED=false
  fi

  # Only the first of the two commands can settle whether this server lets its fans be taken at all.
  # The speed command runs on fans the controller already holds, so its refusal is a failure to obey and
  # not a refusal to hand anything over : concluding from it would stop the controller from ever giving
  # back fans it had already taken, which is the one outcome that leaves them pinned with nobody watching
  if [ -n "$MANUAL_FAN_CONTROL_STDERR" ]; then
    note_that_the_server_refuses_fan_control "$MANUAL_FAN_CONTROL_STDERR"
  fi

  if ! $IS_PROFILE_APPLIED; then
    CURRENT_FAN_CONTROL_PROFILE="User static fan control profile ($DECIMAL_FAN_SPEED%) (not applied)"
    return 1
  fi
  CURRENT_FAN_CONTROL_PROFILE="User static fan control profile ($DECIMAL_FAN_SPEED%)"
}

# Convert first parameter given ($DECIMAL_NUMBER) to hexadecimal
# Usage : convert_decimal_value_to_hexadecimal $DECIMAL_NUMBER
# Returns : hexadecimal value of DECIMAL_NUMBER
function convert_decimal_value_to_hexadecimal() {
  local -r DECIMAL_NUMBER=$1
  local -r HEXADECIMAL_NUMBER=$(printf '0x%02x' $DECIMAL_NUMBER)
  echo $HEXADECIMAL_NUMBER
}

# Convert first parameter given ($HEXADECIMAL_NUMBER) to decimal
# Usage : convert_hexadecimal_value_to_decimal "$HEXADECIMAL_NUMBER"
# Returns : decimal value of HEXADECIMAL_NUMBER
function convert_hexadecimal_value_to_decimal() {
  local -r HEXADECIMAL_NUMBER=$1
  local -r DECIMAL_NUMBER=$(printf '%d' $HEXADECIMAL_NUMBER)
  echo $DECIMAL_NUMBER
}

# Convert a duration into a number of seconds, so it can be compared against a threshold
# Usage : convert_duration_to_seconds "5m"
#
# Shared by every parameter written in that grammar -- CHECK_INTERVAL and
# MAXIMUM_IPMI_UNREACHABLE_DURATION -- so they accept the exact same spellings
# Returns : the equivalent number of seconds
#
# The value must already have passed validate_check_interval_parameter's format check : this only
# reads the shapes that regex allows. The suffix is stripped and 10# forces base 10 so that a padded
# value ("00", "08") is read as the decimal number the user meant instead of an invalid octal one
function convert_duration_to_seconds() {
  local -r VALUE="$1"
  local -r NUMBER="$((10#${VALUE%[smhd]}))"

  case "$VALUE" in
    *m) echo "$((NUMBER * 60))" ;;
    *h) echo "$((NUMBER * 3600))" ;;
    *d) echo "$((NUMBER * 86400))" ;;
    *) echo "$NUMBER" ;;
  esac
}

# Stop the container unless the given parameter is a usable fan speed, in either accepted notation
# Usage : validate_fan_speed_parameter "$PARAMETER_NAME" "$VALUE"
#
# bash's printf applies base detection, so an unchecked value never fails visibly : "09" is an invalid
# octal number, "abc" an invalid number, an empty value produces no diagnostic at all, and all three
# convert to 0x00 -- the documented Dell command for 0% fan duty. Only one stderr line at startup says
# so, and every temperature table row printed afterwards keeps naming the speed the user asked for
# while the fans sit at zero, the profile being re-sent unchanged every cycle. The machine recovers
# only once a CPU crosses CPU_TEMPERATURE_THRESHOLD, i.e. after it has already heated up
function validate_fan_speed_parameter() {
  local -r PARAMETER_NAME="$1"
  local -r VALUE="$2"
  local DECIMAL_VALUE

  # One command substitution per statement, which is why these are hoisted rather than expanded inside
  # the messages below (see test_no_statement_expands_two_command_substitutions)
  local -r MINIMUM_HEXADECIMAL_FAN_SPEED=$(convert_decimal_value_to_hexadecimal "$MINIMUM_FAN_SPEED_PERCENTAGE")
  local -r MAXIMUM_HEXADECIMAL_FAN_SPEED=$(convert_decimal_value_to_hexadecimal "$MAXIMUM_FAN_SPEED_PERCENTAGE")
  local -r ACCEPTED_RANGE="a percentage from ${MINIMUM_FAN_SPEED_PERCENTAGE} to ${MAXIMUM_FAN_SPEED_PERCENTAGE}, or the same value in hexadecimal from ${MINIMUM_HEXADECIMAL_FAN_SPEED} to ${MAXIMUM_HEXADECIMAL_FAN_SPEED}"

  if [[ "$VALUE" =~ ^0[xX][0-9A-Fa-f]{1,2}$ ]]; then
    DECIMAL_VALUE=$(convert_hexadecimal_value_to_decimal "$VALUE")
  elif [[ "$VALUE" =~ ^[0-9]+$ ]]; then
    DECIMAL_VALUE=$(normalize_decimal_value "$VALUE")
  else
    print_configuration_error_and_exit "$PARAMETER_NAME" "$VALUE" "$ACCEPTED_RANGE. The \"0x\" prefix is what tells the two notations apart"
  fi

  if [ "$DECIMAL_VALUE" -gt "$MAXIMUM_FAN_SPEED_PERCENTAGE" ]; then
    print_configuration_error_and_exit "$PARAMETER_NAME" "$VALUE" "$ACCEPTED_RANGE (this is ${DECIMAL_VALUE}%)"
  fi
}

# Stop the container unless the given parameter is one of the two literals the shell can safely run
# Usage : validate_boolean_parameter "$PARAMETER_NAME" "$VALUE"
#
# Boolean parameters are dispatched by running their value as a command : "if $MONITORING_ONLY_MODE".
# The idiom is exact for "true" and "false", which really are commands returning 0 and 1, and it is a
# trap for every other spelling, because every other spelling is a command too.
#
# A value naming nothing exits 127, which the branch reads as false. "True", "TRUE", "1", "on" and
# "Yes" therefore all silently mean false : MONITORING_ONLY_MODE=True seizes manual fan control and
# pins the fans on a server the operator explicitly asked it not to touch, while logging "Monitoring
# only mode: Disabled", and KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT=True resets on
# exit the very state it names.
#
# A value that does name a real command is worse. "yes" is /usr/bin/yes, so the branch never returns :
# it fills the log at hundreds of megabytes a second and, running in the foreground, defers the
# graceful_exit trap indefinitely, so docker stop cannot end the container and only SIGKILL does. The
# unquoted occurrences word-split on top of that, so a value carrying arguments runs with them.
#
# Refusing anything but the two literals is what makes that idiom safe, which is why the call sites
# keep it instead of being rewritten. No coherent configuration stops working : the rejected spellings
# were already read as false, or already hanging the container. The one that did reach the monitoring
# branch is an empty MONITORING_ONLY_MODE, which the unquoted dispatch expanded to no words at all, so
# the branch tested nothing and succeeded ; it reached it while validate_check_interval_parameter, given
# that same empty value and defaulting it with "${3:-false}", judged the interval as if the fans were
# being driven. That value never meant one thing, so refusing it settles a contradiction rather than
# taking a working setup away.
#
# This function must be called as a statement, never through a command substitution : the exit inside
# print_configuration_error_and_exit would otherwise only leave the subshell and the container would
# keep running
function validate_boolean_parameter() {
  local -r PARAMETER_NAME="$1"
  local -r VALUE="$2"

  if [ "$VALUE" != "true" ] && [ "$VALUE" != "false" ]; then
    print_configuration_error_and_exit "$PARAMETER_NAME" "$VALUE" "exactly \"true\" or \"false\". Spellings such as \"True\", \"1\", \"yes\" or \"on\" are not accepted : this parameter is dispatched by running its value, so anything else is either read as false without a word or run as whatever command it names"
  fi
}

# Express the unreachable-iDRAC escalation as a number of cycles, whichever way it was configured
# Usage : resolve_IPMI_failures_before_exit "$COUNT" "$DURATION" $CHECK_INTERVAL_IN_SECONDS
# Returns : IPMI_FAILURES_BEFORE_EXIT, empty when the escalation is disabled
#
# The duration is the one users configure : it is what they actually care about ("give up after a
# minute"), and it keeps meaning the same thing when CHECK_INTERVAL changes, where a raw cycle count
# silently would not. The count remains for anyone who wants the threshold in cycles exactly, and
# takes precedence when set, being the more specific of the two.
#
# Rounded up, and never below 1 : a duration shorter than one cycle still has to allow one failure to
# be observed before anything can be concluded from it
function resolve_IPMI_failures_before_exit() {
  local -r COUNT="$1"
  local -r DURATION="$2"
  local -r CYCLE_IN_SECONDS="$3"

  if [ -n "$COUNT" ]; then
    IPMI_FAILURES_BEFORE_EXIT="$((10#$COUNT))"
    return 0
  fi

  if [ -z "$DURATION" ]; then
    IPMI_FAILURES_BEFORE_EXIT=""
    return 0
  fi

  local -r DURATION_IN_SECONDS=$(convert_duration_to_seconds "$DURATION")
  IPMI_FAILURES_BEFORE_EXIT=$(( (DURATION_IN_SECONDS + CYCLE_IN_SECONDS - 1) / CYCLE_IN_SECONDS ))
  if [ "$IPMI_FAILURES_BEFORE_EXIT" -lt 1 ]; then
    IPMI_FAILURES_BEFORE_EXIT=1
  fi
}

# Stop the container when the iDRAC has been unreachable for the configured number of cycles
# Usage : exit_if_iDRAC_unreachable_for_too_long
#
# Reads CONSECUTIVE_IPMI_FAILURES, IPMI_FAILURES_BEFORE_EXIT and CHECK_INTERVAL_IN_SECONDS.
# Does nothing when the escalation is disabled, which is the default.
#
# Called from both waiting points -- the startup sensor detection and the monitoring loop -- because
# the failure that matters most, a wrong host or wrong credentials, happens before the loop is ever
# entered : without it there, the container would sit printing the same line forever having never
# supervised anything.
#
# This function must be called as a statement, never through a command substitution : the exit inside
# print_error_and_exit would otherwise only leave the subshell and the container would keep running
function exit_if_iDRAC_unreachable_for_too_long() {
  [ -n "$IPMI_FAILURES_BEFORE_EXIT" ] || return 0
  [ "$CONSECUTIVE_IPMI_FAILURES" -ge "$IPMI_FAILURES_BEFORE_EXIT" ] || return 0

  # The duration is computed into a local first : this is a runtime condition, not a refused
  # configuration, and it must not read like one -- nor name a parameter in its message
  local -r UNREACHABLE_FOR_SECONDS=$(( CONSECUTIVE_IPMI_FAILURES * CHECK_INTERVAL_IN_SECONDS ))

  print_error_and_exit "The iDRAC could not be reached $CONSECUTIVE_IPMI_FAILURES times in a row, i.e. for about $UNREACHABLE_FOR_SECONDS seconds. Exiting so that a restart policy can retry with a fresh IPMI session. An unreachable iDRAC accepts no command, so this cannot and does not try to move the fans : they keep the speed they were last set to until something reaches the iDRAC again"
}

# Describe the resolved escalation, for the startup log
# Usage : describe_IPMI_unreachable_escalation "$COUNT" "$DURATION" $IPMI_FAILURES_BEFORE_EXIT
#
# Every other configured parameter states what it resolved to, and this one is the only whose
# resolution performs a conversion the user did not write : a duration becomes a number of checks,
# rounded up against CHECK_INTERVAL. Leaving that unsaid is what let a value collapse to a single
# check without anybody being able to see it from the log (issue #332)
function describe_IPMI_unreachable_escalation() {
  local -r COUNT="$1"
  local -r DURATION="$2"
  local -r FAILURES_BEFORE_EXIT="$3"

  if [ -z "$FAILURES_BEFORE_EXIT" ]; then
    echo "Disabled (the iDRAC is retried until it answers)"
    return 0
  fi

  # The count is the user's own number of checks, so there is no conversion to report -- only which
  # of the two parameters is the one in force, the count taking precedence when both are set
  if [ -n "$COUNT" ]; then
    echo "After $(pluralize_checks "$FAILURES_BEFORE_EXIT") (set by MAXIMUM_CONSECUTIVE_IPMI_FAILURES)"
    return 0
  fi

  echo "After $(pluralize_checks "$FAILURES_BEFORE_EXIT") ($DURATION, rounded up to whole check intervals)"
}

# "1 check" / "12 checks", so the line reads as a sentence in the case that matters most
# Usage : pluralize_checks $COUNT
function pluralize_checks() {
  local -r COUNT="$1"

  if [ "$COUNT" -eq 1 ]; then
    echo "1 check"
    return 0
  fi

  echo "$COUNT checks"
}

# Warn when the escalation would exit on the very first unreachable reading
# Usage : warn_if_the_escalation_exits_on_the_first_failure "$COUNT" "$DURATION" $IPMI_FAILURES_BEFORE_EXIT
#
# A single check is exiting on the first unreachable reading -- word for word the behaviour
# validate_IPMI_unreachable_duration_parameter refuses a zero for. It is reached two ways, and both
# are warned about : the consequence is the same for the server whichever parameter produced it, and
# a warning that fires on one and not the other would read as the other being safe.
#
# They are worded apart because they are not the same mistake. A duration at or below CHECK_INTERVAL
# was rounded there without the user seeing it -- the rounding itself is right, nothing being
# concluded from less than one observed failure -- while a count of one was typed. Neither is refused,
# both being legitimate on a rock-solid LAN ; this only makes sure nobody arrives there unaware, the
# way validate_check_interval_parameter warns above its own threshold rather than accepting in silence
function warn_if_the_escalation_exits_on_the_first_failure() {
  local -r COUNT="$1"
  local -r DURATION="$2"
  local -r FAILURES_BEFORE_EXIT="$3"

  [ "$FAILURES_BEFORE_EXIT" == "1" ] || return 0

  local WHAT_WAS_CONFIGURED
  if [ -n "$COUNT" ]; then
    WHAT_WAS_CONFIGURED="MAXIMUM_CONSECUTIVE_IPMI_FAILURES is \"$COUNT\""
  elif [ -n "$DURATION" ]; then
    WHAT_WAS_CONFIGURED="MAXIMUM_IPMI_UNREACHABLE_DURATION is \"$DURATION\", at or below CHECK_INTERVAL, so it resolves to a single check"
  else
    # Unreachable through resolve_IPMI_failures_before_exit, which leaves the threshold empty when
    # neither parameter is set. Guarded all the same rather than naming a parameter nobody configured
    return 0
  fi

  print_warning "$WHAT_WAS_CONFIGURED : the container will exit on the very first unreachable reading, i.e. on any transient glitch, which is what a zero is refused for. Raise it so that more than one failure has to be observed before anything is concluded"
}

# Stop the container unless the given parameter is a usable unreachable-iDRAC duration
# Usage : validate_IPMI_unreachable_duration_parameter "$PARAMETER_NAME" "$VALUE"
#
# Same grammar as CHECK_INTERVAL, deliberately : both are durations, and a user who has learnt that
# "5m" works in one should not discover it does not in the other. Empty disables the escalation
function validate_IPMI_unreachable_duration_parameter() {
  local -r PARAMETER_NAME="$1"
  local -r VALUE="$2"

  [ -n "$VALUE" ] || return 0

  if [[ ! "$VALUE" =~ ^[0-9]+[smhd]?$ ]]; then
    print_configuration_error_and_exit "$PARAMETER_NAME" "$VALUE" "a number of seconds, optionally suffixed with s, m, h or d, or empty to disable the escalation"
  fi

  # Zero would exit on the very first unreachable cycle, i.e. on any transient glitch, which is the
  # opposite of riding one out
  if [ "$(convert_duration_to_seconds "$VALUE")" -eq 0 ]; then
    print_configuration_error_and_exit "$PARAMETER_NAME" "$VALUE" "greater than zero : a zero duration would exit on the very first unreachable cycle, i.e. on any transient glitch"
  fi
}

# Stop the container unless the given parameter is a usable consecutive-failure threshold
# Usage : validate_maximum_consecutive_IPMI_failures_parameter "$PARAMETER_NAME" "$VALUE"
#
# Empty means the escalation is off, which is the default : exiting only helps a container something
# restarts, and Docker's default restart policy is "no". Left enabled by default it would turn a blind
# supervisor into an absent one -- graceful_exit's attempt to restore Dell's profile goes through the
# same unreachable iDRAC and fails too, so the fans would stay pinned with nothing watching them
function validate_maximum_consecutive_IPMI_failures_parameter() {
  local -r PARAMETER_NAME="$1"
  local -r VALUE="$2"

  [ -n "$VALUE" ] || return 0

  if [[ ! "$VALUE" =~ ^[0-9]+$ ]]; then
    print_configuration_error_and_exit "$PARAMETER_NAME" "$VALUE" "a whole number of consecutive failed cycles (1 or more), or empty to disable the escalation"
  fi

  # Zero would exit on the very first unreachable cycle, i.e. on any transient glitch, which is the
  # opposite of riding one out
  if [ "$((10#$VALUE))" -lt 1 ]; then
    print_configuration_error_and_exit "$PARAMETER_NAME" "$VALUE" "at least 1 : zero would exit on the very first unreachable cycle, i.e. on any transient glitch. If you meant to switch the escalation off rather than to make it immediate, leave this parameter empty : that is what disables it"
  fi
}

# Stop the container unless the given parameter is a duration sleep can actually wait for, and unless
# that duration is short enough for the controller to still be reacting to temperature changes
# Usage : validate_check_interval_parameter "$PARAMETER_NAME" "$VALUE" ["$MONITORING_ONLY_MODE"]
#
# The value is passed straight to sleep, whose exit status the loop discards, so an unusable one
# doesn't stop anything : sleep returns in a few milliseconds and the monitoring loop starts spinning
# at full speed, opening an IPMI session per iteration and flooding the logs.
#
# The interval is bounded from above too, because it is the controller's reaction time. Once
# apply_user_fan_control_profile has run, Dell's own dynamic fan control is disabled (raw 0x30 0x30
# 0x01 0x00) and the fans are pinned at FAN_SPEED (raw 0x30 0x30 0x02 0xff ...), so nothing raises them
# again until a later check reads a temperature above CPU_TEMPERATURE_THRESHOLD. The interval is
# therefore the longest the server can heat up with its cooling frozen at a speed chosen for an idle
# machine, which is why a long one is worth a warning and a very long one is refused outright.
#
# Both bounds are lifted in monitoring only mode : no fan control profile is ever applied there, Dell's
# dynamic fan control keeps the fans, and the interval is only how often temperatures are logged. There
# is no reaction time to warn about, and refusing a slow logging cadence would reject a configuration
# that carries no thermal risk whatsoever. The argument defaults to false so that a call that omits it
# keeps the strictest reading, fan control being the assumption that fails safe.
#
# This function must be called as a statement, never through a command substitution : the exit inside
# print_configuration_error_and_exit would otherwise only leave the subshell and the container would
# keep running
function validate_check_interval_parameter() {
  local -r PARAMETER_NAME="$1"
  local -r VALUE="$2"
  local -r IS_MONITORING_ONLY_MODE="${3:-false}"

  if [[ ! "$VALUE" =~ ^[0-9]+[smhd]?$ ]]; then
    print_configuration_error_and_exit "$PARAMETER_NAME" "$VALUE" "a number of seconds, optionally suffixed with s, m, h or d (for example 60, 90s, 5m or 1h)"
  fi

  local -r VALUE_IN_SECONDS=$(convert_duration_to_seconds "$VALUE")

  # Zero is the third failing case, and the only one sleep itself accepts : it parses fine, returns
  # immediately, and spins the loop just like an unparseable value. It is therefore rejected on its own
  # terms rather than on its format
  if [ "$VALUE_IN_SECONDS" -eq 0 ]; then
    print_configuration_error_and_exit "$PARAMETER_NAME" "$VALUE" "a duration greater than zero, otherwise the monitoring loop would never pause between two readings"
  fi

  if [ "$IS_MONITORING_ONLY_MODE" == "true" ]; then
    return
  fi

  if [ "$VALUE_IN_SECONDS" -gt "$MAXIMUM_CHECK_INTERVAL_IN_SECONDS" ]; then
    print_configuration_error_and_exit "$PARAMETER_NAME" "$VALUE" "at most $((MAXIMUM_CHECK_INTERVAL_IN_SECONDS / 60)) minutes when this container drives the fans. Between two checks the fans stay pinned at the FAN_SPEED you configured, with Dell's dynamic fan control disabled, so the server would be left heating up unattended for that long. Use a shorter interval, or set MONITORING_ONLY_MODE=true if all you want is temperature logging"
  fi

  if [ "$VALUE_IN_SECONDS" -gt "$CHECK_INTERVAL_WARNING_THRESHOLD_IN_SECONDS" ]; then
    print_warning "$PARAMETER_NAME is \"$VALUE\", over $CHECK_INTERVAL_WARNING_THRESHOLD_IN_SECONDS seconds. Between two checks the fans stay pinned at the FAN_SPEED you configured, with Dell's dynamic fan control disabled, so the controller will take up to that long to react to a temperature spike"
  fi
}

# Express an already validated fan speed parameter in both notations at once
# Usage : convert_fan_speed_parameter "$VALUE"
# Returns : DECIMAL_SPEED, HEXADECIMAL_SPEED
function convert_fan_speed_parameter() {
  local -r VALUE="$1"

  if [[ "$VALUE" == 0[xX]* ]]; then
    DECIMAL_SPEED=$(convert_hexadecimal_value_to_decimal "$VALUE")
    HEXADECIMAL_SPEED="$VALUE"
  else
    # Leading zeros are stripped before the conversion, printf would otherwise read "09" as an invalid
    # octal number and hand back 0x00
    DECIMAL_SPEED=$(normalize_decimal_value "$VALUE")
    HEXADECIMAL_SPEED=$(convert_decimal_value_to_hexadecimal "$DECIMAL_SPEED")
  fi
}

# Where the Linux IPMI driver exposes its character device, under the three names it has carried across
# kernel versions and distributions. Local mode needs one of them to be visible inside the container.
#
# Kept in a variable rather than written into the check so that the test suite can point the lookup at a
# file of its own : /dev is machine-global, and creating the real path there to exercise the "device is
# present" branch is what used to make two runs on the same machine interfere with each other, one
# silently skipping a case the other had made unreachable.
#
# It is out of reach of the container's environment all the same, being an array : bash cannot export
# one, so "docker run -e IPMI_DEVICE_PATHS=..." cannot reach this. Declared here rather than in
# constants.sh because healthcheck.sh sources this file alone, and it takes the local mode path too.
# Not readonly, that being the whole point
IPMI_DEVICE_PATHS=("/dev/ipmi0" "/dev/ipmi/0" "/dev/ipmidev/0")

# Set the IDRAC_LOGIN_STRING variable based on connection type
# Usage : set_iDRAC_login_string $IDRAC_HOST $IDRAC_USERNAME $IDRAC_PASSWORD
# Returns : IDRAC_LOGIN_STRING
function set_iDRAC_login_string() {
  local IDRAC_HOST="$1"
  local IDRAC_USERNAME="$2"
  local IDRAC_PASSWORD="$3"

  IDRAC_LOGIN_STRING=""

  # Check if the iDRAC host is set to 'local' or not then set the IDRAC_LOGIN_STRING accordingly
  if [[ "$IDRAC_HOST" == "local" ]]; then
    # Check that the Docker host IPMI device (the iDRAC) has been exposed to the Docker container
    local IPMI_DEVICE_PATH
    local IS_IPMI_DEVICE_EXPOSED=false
    for IPMI_DEVICE_PATH in "${IPMI_DEVICE_PATHS[@]}"; do
      if [ -e "$IPMI_DEVICE_PATH" ]; then
        IS_IPMI_DEVICE_EXPOSED=true
        break
      fi
    done

    if ! $IS_IPMI_DEVICE_EXPOSED; then
      # A device path holds no space, so joining on the separator is enough to enumerate them the way
      # the error always has : "/dev/ipmi0 or /dev/ipmi/0 or /dev/ipmidev/0"
      local -r IPMI_DEVICE_PATHS_ENUMERATION="${IPMI_DEVICE_PATHS[*]}"
      # IDRAC_HOST is what is named, it being the parameter that makes the device mandatory : the
      # device itself is not a parameter the user can be told to correct, only to add
      print_configuration_error_and_exit "IDRAC_HOST" "$IDRAC_HOST" \
        "local mode needs the host's IPMI device inside the container. Could not open device at ${IPMI_DEVICE_PATHS_ENUMERATION// / or }, none of them being visible from here" \
        "Add \"--device=${IPMI_DEVICE_PATHS[0]}\" to your \"docker run\" command, or a \"devices:\" section to
your docker-compose.yml, then start the container again. Alternatively, set IDRAC_HOST to
your iDRAC's address to use network mode instead."
    fi
    IDRAC_LOGIN_STRING='open'
  else
    echo "iDRAC/IPMI username: $IDRAC_USERNAME"
    #echo "iDRAC/IPMI password: $IDRAC_PASSWORD"
    # Pass the password via the IPMI_PASSWORD environment variable (-E) instead of the command line (-P)
    # so it never appears in the container's process list (e.g. `ps aux`, /proc/<pid>/cmdline) or logs
    export IPMI_PASSWORD="$IDRAC_PASSWORD"
    IDRAC_LOGIN_STRING="lanplus -H $IDRAC_HOST -U $IDRAC_USERNAME -E"
  fi
}

# Retrieve the "high" temperature the CPU manufacturer itself defines, as reported by the lm-sensors
# utility ("Package id 0:  +45.0°C  (high = +62.0°C, crit = +72.0°C)")
# Usage : retrieve_CPU_high_temperature_from_lm_sensors
# Returns : the lowest "high" temperature in degrees Celsius (integer), or an empty string if lm-sensors
#           is unavailable or exposes no such value
#
# /!\ lm-sensors reads the CPUs of the machine this script runs on, so this is only meaningful in local
# mode, where that machine is the very server whose fans are being controlled /!\
#
# Only Intel's "coretemp" chips are read. The other chips lm-sensors exposes (chipset, NVMe drives...)
# publish their own unrelated "high" values, which would silently become the CPU threshold, and AMD's
# drivers publish nothing usable : k10temp hides both "high" and "crit" on every Zen part (so on every
# EPYC PowerEdge), its "high" on older parts is a hardcoded 70°C driver constant on the non-physical
# Tctl scale rather than a manufacturer value, and k8temp exposes no limit at all. An AMD server
# therefore falls back to FALLBACK_CPU_TEMPERATURE_THRESHOLD, which the startup log states explicitly,
# instead of silently adopting a number that means nothing
function retrieve_CPU_high_temperature_from_lm_sensors() {
  if ! command -v sensors > /dev/null 2>&1; then
    return
  fi

  # "sensors -u" prints raw sub-feature values ("temp1_max: 62.000") instead of the decorated, localized
  # human-readable format ("high = +62.0°C"), which keeps the parsing independent from locale and layout
  local -r HIGH_TEMPERATURE=$(sensors -u 2>/dev/null | awk '
    # Chip names are the only unindented lines that are neither "Adapter: ..." nor a feature label such as
    # "Package id 0:", which always ends with a colon
    /^[^[:space:]]/ {
      if ($0 !~ /^Adapter:/ && $0 !~ /:[[:space:]]*$/) {
        chip = $0
        is_CPU_chip = (chip ~ /^coretemp-/)
      }
      next
    }
    !is_CPU_chip { next }
    # "high" is the "_max" sub-feature and "crit" the "_crit" one. Both are collected per sensor, so that
    # they can be compared below ("_crit_alarm" and "_crit_hyst" do not match, the colon must follow)
    $1 ~ /^temp[0-9]+_(max|crit):$/ && $2 ~ /^[0-9]+(\.[0-9]+)?$/ {
      split($1, subfeature, "_")
      sub(/:$/, "", subfeature[2])
      if (subfeature[2] == "max") {
        high[chip, subfeature[1]] = $2 + 0
      } else {
        critical[chip, subfeature[1]] = $2 + 0
      }
    }
    END {
      for (sensor in high) {
        # "high" must sit strictly below "crit". coretemp derives "high" by subtracting an offset from
        # TjMax that Intel documents as reserved : when a CPU leaves it at zero, "high" comes back equal
        # to "crit", i.e. to the temperature at which the CPU already throttles itself. Adopting that as
        # the threshold would keep the fans low until the hardware has acted, so such a sensor is skipped
        # and the caller falls back instead
        if ((sensor in critical) && high[sensor] >= critical[sensor]) continue
        # Keep the lowest, so the most constrained CPU of a multi-socket server is the one being protected
        if (lowest == "" || high[sensor] < lowest) lowest = high[sensor]
      }
      # Truncate rather than round, so the threshold is never set above what the CPU manufacturer defined
      if (lowest != "") printf "%d", lowest
    }')

  # Ignore implausible readings (unsupported or misreporting sensor) instead of letting them become the
  # threshold that protects the hardware
  if [[ "$HIGH_TEMPERATURE" =~ ^[0-9]+$ ]] \
    && [ "$HIGH_TEMPERATURE" -ge "$MINIMUM_PLAUSIBLE_CPU_TEMPERATURE_THRESHOLD" ] \
    && [ "$HIGH_TEMPERATURE" -le "$MAXIMUM_PLAUSIBLE_CPU_TEMPERATURE_THRESHOLD" ]; then
    echo "$HIGH_TEMPERATURE"
  fi
}

# Where the CPU temperatures the controller supervises are actually being read from : "ipmi" (the
# iDRAC's sensor records) or "lm-sensors" (the host's own hwmon chips). It is not the CPU_TEMPERATURE_SOURCE
# parameter, which is what the user asked for : on "auto" this starts at "ipmi" and only ever becomes
# "lm-sensors" once the iDRAC has proven it reports no CPU temperature at all
CPU_TEMPERATURE_SOURCE_IN_USE="ipmi"

# Normalize a CPU_TEMPERATURE_SOURCE value into one of "auto", "ipmi" or "lm-sensors"
# Usage : normalize_CPU_temperature_source "$CPU_TEMPERATURE_SOURCE"
# Returns : the normalized value, or the input itself when it is none of them, so that the caller can
#           report what the user actually wrote
#
# The same shapes CPU_TEMPERATURE_THRESHOLD has to tolerate reach this parameter : Docker's --env-file
# parser keeps the trailing space of a "CPU_TEMPERATURE_SOURCE=ipmi " line, and copying the documented
# placeholder can carry quotes along. The separator inside "lm-sensors" is accepted in its three
# plausible spellings, none of which can be confused with another value
function normalize_CPU_temperature_source() {
  local VALUE="$1"

  VALUE="${VALUE//[[:space:]]/}"
  VALUE="${VALUE#[\"\']}"
  VALUE="${VALUE%[\"\']}"
  VALUE="${VALUE,,}"
  VALUE="${VALUE:-auto}"

  case "$VALUE" in
    lm_sensors | lmsensors) VALUE="lm-sensors" ;;
  esac

  printf '%s' "$VALUE"
}

# Read the CPUs' current temperatures from the lm-sensors utility
# Usage : retrieve_CPU_temperatures_from_lm_sensors
# Returns : one "<socket> <chip> <temperature>" line per populated socket, sorted by socket number,
#           or nothing at all when lm-sensors is unavailable or exposes no CPU temperature
#
# /!\ lm-sensors reads the CPUs of the machine this script runs on, so this is only meaningful in local
# mode, where that machine is the very server whose fans are being controlled /!\
#
# Only Intel's "coretemp" chips are read, for the same reason threshold detection only reads them : the
# other chips lm-sensors exposes (chipset, NVMe drives...) are not CPUs, and AMD's k10temp publishes
# "Tctl", a control value on a scale that is not the physical temperature the iDRAC reports on the very
# same server. An AMD server therefore keeps reading its CPUs through IPMI, which is where they are
# right, instead of silently being supervised against a number that means something else
#
# Only the package sub-feature is read. The per-core ones ("Core 0", "Core 1"...) describe parts of the
# same die and would each get a column of their own, turning a two-socket server into a twenty-CPU table
function retrieve_CPU_temperatures_from_lm_sensors() {
  if ! command -v sensors > /dev/null 2>&1; then
    return
  fi

  # "sensors -u" prints raw sub-feature values ("temp1_input: 45.000") instead of the decorated,
  # localized human-readable format ("Package id 0:  +45.0°C"), which keeps the parsing independent
  # from locale and layout
  sensors -u 2>/dev/null | awk '
    # Chip names, feature labels and sub-features are told apart by their indentation : a chip name and
    # a feature label are both unindented, but a feature label always ends with a colon ("Package id 0:")
    # and a chip name never does. "Adapter:" is neither
    /^[^[:space:]]/ {
      if ($0 ~ /^Adapter:/) next
      if ($0 ~ /:[[:space:]]*$/) next
      CHIP = $0
      IS_CPU_CHIP = (CHIP ~ /^coretemp-/)
      if (IS_CPU_CHIP) {
        # The socket is read from the chip name -- coretemp registers one platform device per physical
        # package, "coretemp-isa-0000" being package 0 -- rather than from the "Package id N" feature
        # label the readings used to be located by. A chip that exposes no package has no such label at
        # all, so numbering the sockets from it would have left the fallback below with nothing to
        # number by, and two schemes that can disagree instead of the one used everywhere
        SOCKET_NAME = CHIP
        sub(/^.*-/, "", SOCKET_NAME)
        if (SOCKET_NAME ~ /^[0-9]+$/) {
          SOCKET = SOCKET_NAME + 0
        } else {
          # A chip named in a shape this does not recognize still gets a column rather than being
          # dropped : an unmonitored CPU is the one outcome worse than an oddly numbered one
          SOCKET = NEXT_UNNAMED_SOCKET++
        }
        CHIP_OF[SOCKET] = CHIP
      }
      next
    }
    !IS_CPU_CHIP { next }

    # The sub-feature number is what identifies the package, not the label above it. coretemp puts the
    # package on temp1 and the cores on temp2 upwards ("core N" becoming temp(N+2)), and the label is
    # the one part a user can rewrite : /etc/sensors.d can rename any feature, and unraid ships a
    # configuration that renames a coretemp feature to "CPU Temp" (issue #378). Matching the label
    # therefore lost the reading on a machine that had it, which the sub-feature number cannot.
    # /!\ This is the driver -- consistent across every dump this repository has seen, including a
    # package-less chip whose cores still start at temp2, leaving temp1 empty rather than reusing it --
    # rather than the documented hwmon interface, which is the label. If a kernel ever renumbers them,
    # a core would be read where a package is expected
    $1 ~ /^temp[0-9]+_input:$/ && $2 ~ /^-?[0-9]+(\.[0-9]+)?$/ {
      SUBFEATURE = $1
      sub(/^temp/, "", SUBFEATURE)
      sub(/_input:$/, "", SUBFEATURE)

      if (SUBFEATURE + 0 == 1) {
        if (!(SOCKET in PACKAGE)) PACKAGE[SOCKET] = $2 + 0
        next
      }

      # The hottest core, not their average : the threshold they are compared against is itself a
      # per-core value ("temp<N>_max", what the CPU manufacturer set for one core), and the package
      # sensor this stands in for tracks the hottest point of the die rather than a mean. An average
      # would read far below both on a partly loaded CPU -- one core at 70°C among five idle ones
      # averages to about 37°C -- and keep the fans low while a core approached throttling
      if (!(SOCKET in HOTTEST_CORE) || $2 + 0 > HOTTEST_CORE[SOCKET]) HOTTEST_CORE[SOCKET] = $2 + 0
    }
    END {
      for (SOCKET in CHIP_OF) {
        if (SOCKET in PACKAGE) {
          KIND = "package"
          READING = PACKAGE[SOCKET]
        } else if (SOCKET in HOTTEST_CORE) {
          KIND = "hottest-core"
          READING = HOTTEST_CORE[SOCKET]
        } else {
          continue
        }
        # Rounded rather than truncated : this is a reading, not the threshold it is compared against,
        # and reporting a 45.8°C CPU as 45°C would under-report it by nearly a degree on every cycle.
        # iDRAC hands out whole degrees too, so this keeps both sources on the same scale
        printf "%d %s %s %d\n", SOCKET, CHIP_OF[SOCKET], KIND, (READING >= 0 ? READING + 0.5 : READING - 0.5)
      }
    }' | sort -n -k1,1
}

# Returns 0 (true) if lm-sensors exposes at least one CPU temperature on this machine
# Usage : is_lm_sensors_reporting_CPU_temperatures
function is_lm_sensors_reporting_CPU_temperatures() {
  [ -n "$(retrieve_CPU_temperatures_from_lm_sensors)" ]
}

# Render the CPU temperatures lm-sensors reports as the "ipmitool sdr type temperature" lines the rest
# of the controller already parses
# Usage : build_CPU_temperature_sdr_lines_from_lm_sensors
#
# Everything downstream -- detecting the CPUs, reading them by entity, following the ones that appear or
# go silent, building the table -- is written against that one shape. Rendering the readings into it,
# rather than teaching each of those steps about a second source, is what keeps a single code path
# supervising the temperatures whichever source they came from.
#
# Sockets are numbered after coretemp's own "Package id N", which is the physical package : socket 0
# becomes processor entity 3.1, exactly as the iDRAC would report it. A depopulated socket therefore
# leaves a gap, which is a shape the detection already handles (entity instances are not required to be
# contiguous). The chip name is carried in the sensor name column so that the startup log can name the
# chip each CPU column is read from, and the sensor ID column holds "--" : there is no IPMI sensor here
# and inventing a plausible hexadecimal ID would be the one thing that could mislead
function build_CPU_temperature_sdr_lines_from_lm_sensors() {
  HAS_ANY_CPU_BEEN_READ_FROM_ITS_CORES=false
  local SOCKET CHIP KIND TEMPERATURE
  while read -r SOCKET CHIP KIND TEMPERATURE; do
    [ -n "$CHIP" ] || continue
    if [ "$KIND" == "hottest-core" ]; then
      HAS_ANY_CPU_BEEN_READ_FROM_ITS_CORES=true
    fi
    printf '%-16s | %s | %-3s | %4s | %s degrees C\n' "$CHIP" "--" "ok" "3.$((SOCKET + 1))" "$TEMPERATURE"
  done < <(retrieve_CPU_temperatures_from_lm_sensors)
}

# Whether the last reading had to fall back to a CPU's cores for want of a package sensor, and whether
# that has been said. Set by build_CPU_temperature_sdr_lines_from_lm_sensors() above
HAS_ANY_CPU_BEEN_READ_FROM_ITS_CORES=false
HAS_THE_CORE_TEMPERATURE_FALLBACK_BEEN_REPORTED=false

# Say once that a CPU column is being filled from its cores rather than from its package.
# Usage : report_the_core_temperature_fallback
# Returns : 0 if this call is the one that said it
#
# Worth saying because the two are not the same measurement. The package sensor tracks the hottest
# point of the die ; the hottest core is the closest stand-in for it, and on a CPU that has no package
# sensor at all it is the only one available. A column filled either way looks identical in the table,
# so the difference has to be stated somewhere rather than left for someone to discover by comparing
# two machines
function report_the_core_temperature_fallback() {
  if ! "$HAS_ANY_CPU_BEEN_READ_FROM_ITS_CORES"; then
    return 1
  fi

  if "$HAS_THE_CORE_TEMPERATURE_FALLBACK_BEEN_REPORTED"; then
    return 1
  fi

  HAS_THE_CORE_TEMPERATURE_FALLBACK_BEEN_REPORTED=true

  local TIMESTAMP
  set_log_timestamp TIMESTAMP
  printf "%19s  At least one CPU here exposes no package temperature sensor, so its column shows its hottest core instead. That is the closest stand-in -- the package sensor tracks the hottest point of the die rather than an average -- but it is not the same reading, and it runs slightly warmer than a package one would.\n" "$TIMESTAMP"
}

# Replace the processor entities of an ipmitool sdr output with the ones lm-sensors reports
# Usage : merge_lm_sensors_CPU_temperatures_into_temperature_data "$SDR_DATA"
#
# Only the CPU rows are replaced : whatever else the iDRAC does report -- most notably the inlet and
# exhaust temperatures, which lm-sensors has no equivalent for -- is kept exactly as it came. The
# fallback therefore fills the one hole the iDRAC leaves instead of blinding the controller to
# everything else it can still read.
#
# The iDRAC's own processor rows are dropped rather than kept alongside : the lm-sensors rows are
# appended after them, and retrieve_temperature_by_entity_id() stops at the first match, so any
# processor row the iDRAC still carries would shadow the reading meant to replace it. That is not a
# hypothetical : the fallback only engages once no processor entity was *readable*, which a socket the
# iDRAC reports for another CPU, or one that becomes readable again later, does not preclude.
#
# A socket the iDRAC lists as "Disabled" is not the case at issue, contrary to what one might expect :
# it carries no "degrees", so retrieve_sdr_temperature_data()'s own filter has already removed it long
# before this function sees the data. Dropping the whole entity rather than only the rows holding a
# reading is what makes the replacement hold whichever of the two it was
function merge_lm_sensors_CPU_temperatures_into_temperature_data() {
  local -r SDR_DATA="$1"

  if [ -n "$SDR_DATA" ]; then
    printf '%s\n' "$SDR_DATA" | awk -F'|' '
      { ENTITY_ID = $4; gsub(/^[[:space:]]+|[[:space:]]+$/, "", ENTITY_ID) }
      ENTITY_ID !~ /^3\.[0-9]+$/'
  fi

  build_CPU_temperature_sdr_lines_from_lm_sensors
}

# Decide where the CPU temperatures will be read from, and refuse to start on a request that cannot be
# honoured
# Usage : resolve_CPU_temperature_source "$CPU_TEMPERATURE_SOURCE" "$NETWORK_MODE"
# Sets : CPU_TEMPERATURE_SOURCE (normalized), CPU_TEMPERATURE_SOURCE_IN_USE and
#        CPU_TEMPERATURE_SOURCE_DESCRIPTION, the startup log line's provenance clause
#
# The iDRAC stays the source in every case where it can be one : it is the only one that describes the
# controlled server whatever the mode, it is the source every existing installation is running on, and
# it is the one the fan control commands go to anyway. lm-sensors is the answer to a single, narrow
# situation -- an iDRAC that drives the fans but reports no CPU temperature at all -- so it is engaged
# either by the user saying so, or by the iDRAC proving over several consecutive checks that it is in
# exactly that situation. It is never engaged just because one query came back empty.
#
# This function must be called as a statement, never through a command substitution : the exit inside
# print_error_and_exit would otherwise only leave the subshell and the container would keep running
function resolve_CPU_temperature_source() {
  local -r REQUESTED_SOURCE="$1"
  local -r IS_NETWORK_MODE="$2"

  CPU_TEMPERATURE_SOURCE=$(normalize_CPU_temperature_source "$REQUESTED_SOURCE")
  CPU_TEMPERATURE_SOURCE_IN_USE="ipmi"
  CPU_TEMPERATURE_SOURCE_DESCRIPTION=""

  case "$CPU_TEMPERATURE_SOURCE" in
    auto)
      if [ "$IS_NETWORK_MODE" == "true" ]; then
        CPU_TEMPERATURE_SOURCE_DESCRIPTION="iDRAC (IPMI), the lm-sensors fallback being only available in local mode"
      else
        CPU_TEMPERATURE_SOURCE_DESCRIPTION="iDRAC (IPMI), falling back to lm-sensors if it turns out to report no CPU temperature at all"
      fi
      ;;
    ipmi)
      CPU_TEMPERATURE_SOURCE_DESCRIPTION="iDRAC (IPMI), as requested"
      ;;
    lm-sensors)
      # Refused rather than quietly downgraded to IPMI : the user asked for a specific source, and a
      # container that silently supervises the wrong CPUs is the failure this whole parameter exists
      # to make impossible
      if [ "$IS_NETWORK_MODE" == "true" ]; then
        print_configuration_error_and_exit "CPU_TEMPERATURE_SOURCE" "$REQUESTED_SOURCE" "a source that can describe the controlled server. lm-sensors reads the CPUs of the machine this container runs on, and in network mode that machine is not the server whose fans are being controlled, so those readings would describe the wrong hardware. Set IDRAC_HOST to \"local\", or leave CPU_TEMPERATURE_SOURCE to its default"
      fi

      # Checked now rather than discovered in the monitoring loop : with no reading at all, every cycle
      # would hand the fans back to Dell's profile forever, which looks exactly like a container doing
      # its job and is the hardest possible way to find out that a kernel module is missing
      if ! is_lm_sensors_reporting_CPU_temperatures; then
        print_configuration_error_and_exit "CPU_TEMPERATURE_SOURCE" "$REQUESTED_SOURCE" "a source that actually reports something : no CPU temperature could be read from lm-sensors. Check that your Docker host exposes them through /sys (the \"coretemp\" kernel module) and that \"sensors\" reports a \"coretemp-\" chip with at least one temperature under it. Note that only Intel CPUs are supported here: AMD's \"k10temp\" driver reports \"Tctl\", which is not the physical temperature the iDRAC reports"
      fi

      CPU_TEMPERATURE_SOURCE_IN_USE="lm-sensors"
      CPU_TEMPERATURE_SOURCE_DESCRIPTION="lm-sensors, as requested (the iDRAC is still the one driving the fans)"
      ;;
    *)
      # Left in place, an unrecognized value would silently mean "auto" : the user would believe one
      # source is being read while another one is
      print_configuration_error_and_exit "CPU_TEMPERATURE_SOURCE" "$REQUESTED_SOURCE" "exactly \"auto\", \"ipmi\" or \"lm-sensors\""
      ;;
  esac
}

# Switch the controller over to reading its CPUs from lm-sensors, if that is allowed and possible
# Usage : engage_lm_sensors_CPU_temperature_fallback
# Returns : 0 (true) if the source was switched, 1 if it was not and the caller must give up on the
#           iDRAC's own verdict
#
# Called on the single check that found the iDRAC answering and reporting no readable CPU temperature
# sensor. One such check is enough to conclude, and that is not this function's claim to make : it is
# the reason the caller exits rather than retries, an iDRAC exposing no processor entity doing so on
# every check rather than on that one. Waiting for several agreeing checks would therefore only delay
# a container that is about to stop
function engage_lm_sensors_CPU_temperature_fallback() {
  # Only the automatic mode ever switches on its own : "ipmi" is the user asking for no surprise, and
  # "lm-sensors" has already been resolved at startup
  if [ "$CPU_TEMPERATURE_SOURCE" != "auto" ] || [ "$CPU_TEMPERATURE_SOURCE_IN_USE" != "ipmi" ]; then
    return 1
  fi

  # In network mode lm-sensors describes the machine running the container, not the controlled server,
  # so there is nothing to fall back on. The same constraint already applies to threshold detection
  if [ "$NETWORK_MODE" == "true" ]; then
    return 1
  fi

  # Nothing to switch to : the caller reports the iDRAC's verdict, which is what it did before this
  # fallback existed
  if ! is_lm_sensors_reporting_CPU_temperatures; then
    return 1
  fi

  CPU_TEMPERATURE_SOURCE_IN_USE="lm-sensors"
  local TIMESTAMP
  set_log_timestamp TIMESTAMP
  printf "%19s  The iDRAC reports no readable CPU temperature sensor, reading the CPUs from lm-sensors instead. Fan control keeps going through the iDRAC.\n" "$TIMESTAMP"
  return 0
}

# Extract the temperature reading carried by a single ipmitool sdr line
# Usage : extract_temperature_from_sdr_line "$SDR_LINE"
# Returns : the temperature in degrees Celsius, or an empty string if that line carries no reading
#
# An sdr line looks like "Temp             | 09h | ok  |  3.1 | 45 degrees C", the reading being its
# 5th pipe-delimited column. Isolating that column first keeps the other ones (most notably the
# sensor's hexadecimal ID) from contributing digits of their own.
#
# The value is matched on its "degrees" suffix rather than on a fixed two-digit width, so that its
# width stops mattering : "100 degrees C" used to be truncated to 10°C, and "9 degrees C" used to
# match nothing at all, which callers cannot tell apart from a missing sensor
#
# The sign is part of the match : "\d+" alone silently returned sub-zero readings as their absolute
# value, turning a -40°C CPU sensor (what a disconnected sensor reports on some iDRACs) into a 40°C
# one hot enough to trip the overheating branch, and making the sub-zero inlet temperatures this
# container is expected to react to indistinguishable from mild ones
function extract_temperature_from_sdr_line() {
  local -r SDR_LINE="$1"

  # The sign is written as a character class rather than as a bare "-?" so the pattern doesn't start
  # with a dash, which grep would otherwise try to parse as one of its own options
  echo "$SDR_LINE" | cut -d'|' -f5 | grep -Po '[-]?\d+(?=[[:space:]]*degrees)'
}

# Convert a temperature reading into a plain base 10 integer, usable in arithmetic and comparisons
# Usage : normalize_decimal_value "$VALUE"
# Returns : the value as a base 10 integer
#
# Readings reach us as text and carry two traps that have to be defused together. A leading zero makes
# bash read the value as octal, where "09" is not a valid number, which is what the "10#" prefix is
# for. But "10#" cannot itself accept a sign : "10#-5" is an "invalid integer constant" and aborts the
# arithmetic. The sign is therefore split off, the digits forced to base 10, and the sign re-applied
function normalize_decimal_value() {
  local VALUE="$1"
  local SIGN=1

  if [[ "$VALUE" == -* ]]; then
    SIGN=-1
    VALUE="${VALUE#-}"
  fi

  echo $((SIGN * 10#$VALUE))
}

# Extract a single temperature reading from ipmitool sdr output, located by its IPMI entity ID
# Usage : retrieve_temperature_by_entity_id "$SDR_DATA" $ENTITY_ID
# Returns : the temperature in degrees Celsius, or an empty string if that entity has no reading
#
# The entity ID is the 4th pipe-delimited column of an sdr line. Entity 3 is the processor, so 3.1 is
# CPU 1, 3.2 is CPU 2, and so on.
#
# Locating a CPU by its entity rather than by counting values makes the parsing independent from the
# sensors' hexadecimal IDs, from the order iDRAC returns them in, and therefore from the server
# generation. Counting used to require per-generation offsets because the digits were extracted from
# the whole line: a sensor whose hexadecimal ID happens to be two digits (e.g. "09h" on an R930, or
# every CPU sensor on some generations) contributed a second, bogus value per line, shifting
# everything (see https://github.com/tigerblue77/Dell_iDRAC_fan_controller_Docker/issues/91)
function retrieve_temperature_by_entity_id() {
  local -r SDR_DATA="$1"
  local -r ENTITY_ID="$2"

  # The entity ID is trimmed through a copy rather than in place, so that the line is printed
  # untouched : assigning to a field makes awk rebuild the whole record with OFS (a space) as its
  # separator, which would strip the pipe delimiters the extraction relies on
  local -r SDR_LINE=$(echo "$SDR_DATA" | awk -F'|' -v entity="$ENTITY_ID" '
    { entity_id = $4; gsub(/^[[:space:]]+|[[:space:]]+$/, "", entity_id) }
    entity_id == entity { print; exit }')

  extract_temperature_from_sdr_line "$SDR_LINE"
}

# Extract the name of the sensor a reading comes from, located by its IPMI entity ID
# Usage : retrieve_sensor_name_by_entity_id "$SDR_DATA" $ENTITY_ID
# Returns : the sensor's name, or an empty string if that entity is not in the data
#
# The name is the 1st pipe-delimited column. On a real iDRAC it is the uninformative "Temp" every CPU
# shares, which is why the entity is what identifies a CPU everywhere else. It becomes worth reading
# when the readings come from lm-sensors, where that column carries the hwmon chip each CPU was read
# from and is the only thing that can tell the user which one their column shows
function retrieve_sensor_name_by_entity_id() {
  local -r SDR_DATA="$1"
  local -r ENTITY_ID="$2"

  printf '%s\n' "$SDR_DATA" | awk -F'|' -v ENTITY="$ENTITY_ID" '
    {
      SENSOR_ENTITY_ID = $4
      SENSOR_NAME = $1
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", SENSOR_ENTITY_ID)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", SENSOR_NAME)
    }
    SENSOR_ENTITY_ID == ENTITY { print SENSOR_NAME; exit }'
}

# Extract a single temperature reading from ipmitool sdr output, located by its sensor name
# Usage : retrieve_temperature_by_sensor_name "$SDR_DATA" "$SENSOR_NAME"
# Returns : the temperature in degrees Celsius, or an empty string if no such sensor has a reading
#
# Inlet and exhaust are both reported as entity 7.1 on Dell servers, so their name is the only thing
# telling them apart and they cannot use retrieve_temperature_by_entity_id()
function retrieve_temperature_by_sensor_name() {
  local -r SDR_DATA="$1"
  local -r SENSOR_NAME="$2"

  # The name is matched at the start of the line, the sensor name being the first pipe-delimited column.
  # Matching it anywhere would let "PSU1 Inlet Temp" and "PSU2 Inlet Temp" -- which most servers with
  # redundant power supplies report -- answer for "Inlet Temp", and the last of them would win, so the
  # intake column showed a power supply's own intake instead of the chassis air intake (issue #231).
  # tail -1 is kept for the genuinely unexpected case of two sensors sharing the same leading name
  local -r SDR_LINE=$(echo "$SDR_DATA" | grep -E "^[[:space:]]*$SENSOR_NAME" | tail -1)

  extract_temperature_from_sdr_line "$SDR_LINE"
}

# Read the raw temperature sensors data from ipmitool
# Usage : retrieve_sdr_temperature_data
# Returns : the "sdr type temperature" lines holding an actual reading
#
# stderr is discarded here: this is a read-only diagnostic call (it never changes fan behavior) and some
# iDRAC/BMC firmwares print a harmless protocol warning on every call even though the reading succeeds
function retrieve_sdr_temperature_data() {
  ipmitool -I $IDRAC_LOGIN_STRING sdr type temperature 2>/dev/null | grep degrees
}

# Read the temperature sensors data the controller supervises, from whichever source is in use
# Usage : retrieve_temperature_data
# Returns : "sdr type temperature" shaped lines holding an actual reading
#
# This is the single place the two sources meet. Everything above and below it -- detection, per-entity
# reads, the table, the overheating check -- sees the same shape either way
function retrieve_temperature_data() {
  if [ "${CPU_TEMPERATURE_SOURCE_IN_USE:-ipmi}" == "lm-sensors" ]; then
    merge_lm_sensors_CPU_temperatures_into_temperature_data "$(retrieve_sdr_temperature_data)"
  else
    retrieve_sdr_temperature_data
  fi
}

# Detect the CPU temperature sensors the server exposes
# Usage : detect_CPU_temperature_sensors "$SDR_DATA"
# Returns : populates the DETECTED_CPU_ENTITY_IDS and DETECTED_CPU_LABELS global arrays, index-aligned,
#           in socket order
#
# Entity 3 is "Processor" (IPMI v2.0 table 43-13), so the sockets are exposed as 3.1, 3.2, ... Every
# processor entity actually carrying a reading is enumerated, rather than probing 3.1, 3.2, ... in order
# and stopping at the first gap, because none of what that probing assumed holds :
# - IPMI only requires entity instances to be unique, not contiguous nor 1-based (section 39.1)
# - iDRAC returns them out of order (an R930 lists 3.4 before 3.1, see issue #91)
# - Dell keeps the SDR row of an unreadable or depopulated socket and reports it "Disabled" instead of
#   omitting it, so the set of *readable* CPUs is legitimately sparse
# No upper bound is applied either : the entity instance is a 7-bit field, and a CPU dropped for being
# past an arbitrary limit would be a heat source nobody watches
function detect_CPU_temperature_sensors() {
  local -r SDR_DATA="$1"

  # The entity is matched on the trimmed 4th column, anchored, so that "13.1" or "30.1" can't be taken
  # for a processor and "3.10" can't be truncated to "3.1". Instances are deduplicated, as two sensors
  # sharing an entity would otherwise get two columns both showing the first one
  # (retrieve_temperature_by_entity_id() stops at the first match), and sorted on the instance number
  # alone, a lexicographic sort putting 3.10 between 3.1 and 3.2
  local -a CPU_ENTITY_INSTANCES
  mapfile -t CPU_ENTITY_INSTANCES < <(printf '%s\n' "$SDR_DATA" | awk -F'|' '
    { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $4) }
    $4 ~ /^3\.[0-9]+$/ && $5 ~ /[0-9]+[[:space:]]*degrees/ {
      split($4, ENTITY, ".")
      if (!(ENTITY[2] in SEEN)) {
        SEEN[ENTITY[2]] = 1
        print ENTITY[2] + 0
      }
    }' | sort -n)

  set_detected_CPU_temperature_sensors "${CPU_ENTITY_INSTANCES[@]}"
}

# Fills the DETECTED_CPU_* arrays from a list of entity instances, expected sorted
# Usage : set_detected_CPU_temperature_sensors 1 2 3 4
function set_detected_CPU_temperature_sensors() {
  local -r -a CPU_ENTITY_INSTANCES=("$@")

  # CPUs are numbered 1, 2, 3... in the order their entities come, rather than after the entity instance
  # they are read from. Every Dell dump this repository has seen numbers its processor entities 1..N,
  # matching the sockets -- see the comment above retrieve_temperature_by_entity_id() -- so on that
  # hardware the two schemes agree, and the counter is preferred for what it guarantees when they would
  # not : it is defined for every possible instance set, including a sparse one, whereas "CPU <instance>"
  # has no sensible output on an empty one ; and it keeps a real Dell's columns at
  # MINIMUM_CPU_COLUMN_CONTENT_WIDTH, which a two-digit instance would widen for every CPU at once.
  # The entity each column maps to is logged at startup and on every set change, which is what makes an
  # unusual numbering diagnosable without putting it in the table.
  # /!\ IPMI only requires entity instances to be unique (section 39.1), so a BMC numbering them from 0
  # or sparsely would be within spec -- but no Dell server has been observed doing it, and this comment
  # used to present that possibility as if it had been. If you ever see one, the "ipmitool sdr elist all"
  # output is worth attaching to https://github.com/tigerblue77/Dell_iDRAC_fan_controller_Docker/issues
  DETECTED_CPU_ENTITY_IDS=()
  DETECTED_CPU_LABELS=()
  local CPU_ENTITY_INSTANCE
  local CPU_NUMBER=1
  for CPU_ENTITY_INSTANCE in "${CPU_ENTITY_INSTANCES[@]}"; do
    DETECTED_CPU_ENTITY_IDS+=("3.$CPU_ENTITY_INSTANCE")
    DETECTED_CPU_LABELS+=("CPU $CPU_NUMBER")
    ((CPU_NUMBER++))
  done
}

# Set to true when the target server has just been powered back on. A CPU can only be added or removed
# with the server switched off, so that transition is the only moment one may legitimately leave the
# monitored set : while the server keeps running, a sensor going quiet is a fault, not a missing socket
IS_CPU_REMOVAL_ALLOWED=false

# The readable set seen while a removal is allowed, and how many consecutive readings have agreed on it.
# A socket can still be slow to become readable during POST, so a smaller set has to be confirmed by
# CPU_REMOVAL_CONFIRMING_READINGS identical readings before CPUs are dropped from the table
PENDING_CPU_REMOVAL_SIGNATURE=""
PENDING_CPU_REMOVAL_READINGS=0

# Runs the detection again on already-fetched sensor data and reports whether the monitored set changed.
# Usage : refresh_CPU_temperature_sensors "$SDR_DATA"
# Returns : 0 (true) if the set changed, the DETECTED_CPU_* arrays then describing the new one
#
# A CPU showing up is adopted immediately : the server may have been powered off precisely to add one,
# and keeping the previous set would leave it both invisible in the table and, far worse, never compared
# to the temperature threshold.
#
# A CPU disappearing is only acted upon after a power cycle, and only once CPU_REMOVAL_CONFIRMING_READINGS
# readings have agreed on it. Dell reports a socket being POSTed and a socket that has been removed in exactly the same way, so
# they cannot be told apart from a single reading -- but a CPU cannot physically leave a running server,
# so a sensor that goes quiet while it keeps running is a fault, and its column stays, reading "-", which
# fails safe to the Dell default profile. Dropping it there would silently stop watching a CPU that is
# still installed
function refresh_CPU_temperature_sensors() {
  local -r SDR_DATA="$1"
  local -r -a PREVIOUS_CPU_ENTITY_IDS=("${DETECTED_CPU_ENTITY_IDS[@]}")

  detect_CPU_temperature_sensors "$SDR_DATA"
  local -r -a READABLE_CPU_ENTITY_IDS=("${DETECTED_CPU_ENTITY_IDS[@]}")

  # Entity IDs hold no space, so the padded-join membership test is unambiguous
  local -a MISSING_CPU_ENTITY_IDS=()
  local CPU_ENTITY_ID
  for CPU_ENTITY_ID in "${PREVIOUS_CPU_ENTITY_IDS[@]}"; do
    if [[ " ${READABLE_CPU_ENTITY_IDS[*]} " != *" $CPU_ENTITY_ID "* ]]; then
      MISSING_CPU_ENTITY_IDS+=("$CPU_ENTITY_ID")
    fi
  done

  # Every CPU going silent at once is an IPMI or host problem, not every socket being unplugged together,
  # so it never confirms anything
  local IS_REMOVAL_CONFIRMED=false
  if (( ${#MISSING_CPU_ENTITY_IDS[@]} > 0 )) && (( ${#READABLE_CPU_ENTITY_IDS[@]} > 0 )) && $IS_CPU_REMOVAL_ALLOWED; then
    if [ "${READABLE_CPU_ENTITY_IDS[*]}" == "$PENDING_CPU_REMOVAL_SIGNATURE" ]; then
      ((PENDING_CPU_REMOVAL_READINGS++))
    else
      # A different set restarts the count : only readings that agree with each other confirm anything
      PENDING_CPU_REMOVAL_SIGNATURE="${READABLE_CPU_ENTITY_IDS[*]}"
      PENDING_CPU_REMOVAL_READINGS=1
    fi
    if (( PENDING_CPU_REMOVAL_READINGS >= CPU_REMOVAL_CONFIRMING_READINGS )); then
      IS_REMOVAL_CONFIRMED=true
    fi
  else
    PENDING_CPU_REMOVAL_SIGNATURE=""
    PENDING_CPU_REMOVAL_READINGS=0
  fi

  # The new set is everything readable, plus the known CPUs keeping their column for now.
  # detect_CPU_temperature_sensors() has already overwritten the arrays by now, hence the rebuild
  local -a CPU_ENTITY_INSTANCES=()
  for CPU_ENTITY_ID in "${READABLE_CPU_ENTITY_IDS[@]}"; do
    CPU_ENTITY_INSTANCES+=("${CPU_ENTITY_ID#3.}")
  done
  if ! $IS_REMOVAL_CONFIRMED; then
    for CPU_ENTITY_ID in "${MISSING_CPU_ENTITY_IDS[@]}"; do
      CPU_ENTITY_INSTANCES+=("${CPU_ENTITY_ID#3.}")
    done
  fi

  # Guarded because printf with a format but no argument still prints it once : sorting an empty set
  # would hand back one empty line, which becomes a phantom "CPU 1" reading entity "3." and never
  # holding a temperature. Reachable in monitoring only mode, the one mode a CPU-less server reaches
  if (( ${#CPU_ENTITY_INSTANCES[@]} > 0 )); then
    mapfile -t CPU_ENTITY_INSTANCES < <(printf '%s\n' "${CPU_ENTITY_INSTANCES[@]}" | sort -n)
  fi
  set_detected_CPU_temperature_sensors "${CPU_ENTITY_INSTANCES[@]}"

  # The window closes as soon as it has been used, or as soon as the server has come back with every CPU
  # it had, there being nothing left to remove
  if $IS_REMOVAL_CONFIRMED || (( ${#MISSING_CPU_ENTITY_IDS[@]} == 0 )); then
    IS_CPU_REMOVAL_ALLOWED=false
  fi

  [ "${DETECTED_CPU_ENTITY_IDS[*]}" != "${PREVIOUS_CPU_ENTITY_IDS[*]}" ]
}

# Describes the detected CPU temperature sensors, along with the IPMI entities they are read from : that
# is what the README asks users to correlate with their own "ipmitool sdr type temperature" output
# Usage : format_detected_CPU_temperature_sensors
#
# When the readings come from lm-sensors, the entities are the controller's own numbering rather than
# something the iDRAC ever reported, so naming them would send the user looking for rows that do not
# exist in their "ipmitool sdr type temperature" output. The hwmon chips are named instead, which is
# how "sensors" itself names them and therefore what can be correlated
function format_detected_CPU_temperature_sensors() {
  # Only monitoring only mode reaches this : every other mode refuses to start on a server reporting no
  # CPU at all. It states a fact rather than a failure, that mode having nothing to do with CPUs
  if (( ${#DETECTED_CPU_ENTITY_IDS[@]} == 0 )); then
    printf 'No CPU temperature sensor detected, only the chassis temperatures will be monitored'
    return
  fi

  local -r NUMBER_OF_SENSORS=${#DETECTED_CPU_ENTITY_IDS[@]}
  local SOURCES=("${DETECTED_CPU_ENTITY_IDS[@]}")
  local SINGULAR_LABEL="entity"
  local PLURAL_LABEL="entities"

  if [ "${CPU_TEMPERATURE_SOURCE_IN_USE:-ipmi}" == "lm-sensors" ]; then
    SINGULAR_LABEL="lm-sensors chip"
    PLURAL_LABEL="lm-sensors chips"

    local INDEX CHIP
    for INDEX in "${!DETECTED_CPU_ENTITY_IDS[@]}"; do
      CHIP=$(retrieve_sensor_name_by_entity_id "$SDR_TEMPERATURE_DATA" "${DETECTED_CPU_ENTITY_IDS[INDEX]}")
      # A CPU whose chip went silent keeps its column until it is confirmed gone, and the data no
      # longer holds a row to read its name from : the entity it is still being looked up by is what
      # is left to name it
      SOURCES[INDEX]="${CHIP:-${DETECTED_CPU_ENTITY_IDS[INDEX]}}"
    done
  fi

  if (( NUMBER_OF_SENSORS == 1 )); then
    printf '1 CPU temperature sensor detected (%s %s)' "$SINGULAR_LABEL" "${SOURCES[0]}"
  else
    printf '%d CPU temperature sensors detected (%s %s)' "$NUMBER_OF_SENSORS" "$PLURAL_LABEL" "${SOURCES[*]}"
  fi
}

# Warns when more CPU temperature sensors are detected than any Dell server has sockets.
# Usage : warn_if_unexpected_number_of_CPUs
#
# Nothing is ever dropped : every detected CPU stays monitored whatever its number, because dropping a
# column would mean silently not watching a heat source. This only reports a count the hardware cannot
# produce, which necessarily means the sensors were mis-parsed
function warn_if_unexpected_number_of_CPUs() {
  if (( ${#DETECTED_CPU_ENTITY_IDS[@]} <= MAXIMUM_NUMBER_OF_CPUS_IN_A_DELL_SERVER )); then
    return
  fi

  print_warning "${#DETECTED_CPU_ENTITY_IDS[@]} CPU temperature sensors is more than any Dell server has sockets. All of them will be monitored, but please open an issue at https://github.com/tigerblue77/Dell_iDRAC_fan_controller_Docker/issues with your server model and the output of the \"ipmitool sdr type temperature\" command"
}

# The widest content a CPU column must hold : a reading renders as "NNN°C" (5 columns), which every label
# up to "CPU 9" fits into. A tenth column would be labelled "CPU 10" and push everything on its right by
# one, so the width follows the labels. No Dell server has ten sockets, so this only ever triggers on a
# mis-parse -- the same one the startup warning reports -- but a broken table is a poor way to find out
# Usage : compute_CPU_column_content_width "CPU 1" "CPU 2" ...
function compute_CPU_column_content_width() {
  local WIDTH=$MINIMUM_CPU_COLUMN_CONTENT_WIDTH
  local CPU_LABEL

  for CPU_LABEL in "$@"; do
    if (( ${#CPU_LABEL} > WIDTH )); then
      WIDTH=${#CPU_LABEL}
    fi
  done

  printf '%s' "$WIDTH"
}

# Retrieve temperature sensors data using ipmitool
# Usage : retrieve_temperatures ["$SDR_DATA"]
#
# The sensor data can be handed over by a caller that has just read it, so that detecting the CPUs and
# taking their first readings cost a single IPMI round-trip and describe the very same instant
function retrieve_temperatures() {
  if (( $# > 1 )); then
    print_error "Illegal number of parameters. Usage: retrieve_temperatures [\"\$SDR_DATA\"]"
    return 1
  fi

  # Kept in a global so that refresh_CPU_temperature_sensors() can look for a newly readable CPU in the
  # very same data, without spending another IPMI round-trip on it
  if (( $# == 1 )); then
    SDR_TEMPERATURE_DATA="$1"
  else
    SDR_TEMPERATURE_DATA=$(retrieve_temperature_data)
  fi
  local -r DATA="$SDR_TEMPERATURE_DATA"

  # Parse every CPU detected at startup, each one being located by its IPMI entity ID.
  # DETECTED_CPU_TEMPERATURES holds the raw readings, indexed by CPU number minus one, and is what
  # is_any_CPU_overheating() evaluates : a reading left empty by a transient IPMI glitch must reach it
  # untouched so it can fail safe on it.
  # CPUS_TEMPERATURES is the display string, in which an unreadable reading falls back to the "-"
  # placeholder so that it still takes up its column when the line is printed : it is split to build the
  # display array, so an empty value would be dropped and shift every following column to the left
  DETECTED_CPU_TEMPERATURES=()
  CPUS_TEMPERATURES=""
  local ENTITY_ID CPU_TEMPERATURE
  for ENTITY_ID in "${DETECTED_CPU_ENTITY_IDS[@]}"; do
    CPU_TEMPERATURE=$(retrieve_temperature_by_entity_id "$DATA" "$ENTITY_ID")
    DETECTED_CPU_TEMPERATURES+=("$CPU_TEMPERATURE")

    if [ -n "$CPUS_TEMPERATURES" ]; then
      CPUS_TEMPERATURES+=";"
    fi
    CPUS_TEMPERATURES+="${CPU_TEMPERATURE:--}"
  done

  # Parse inlet temperature data, the sensor being located by its name
  INLET_TEMPERATURE=$(retrieve_temperature_by_sensor_name "$DATA" "Inlet")

  # 11th generation servers (iDRAC6 : R610, R710, R510, T610...) call that very sensor "Ambient Temp".
  # "Inlet Temp" only appears from the 12th generation on, so on every 11G server -- all of which the
  # catalogue lists as supported -- the intake column showed the "-" placeholder for a sensor that was
  # answering perfectly well under a name nobody asked it for.
  #
  # Deliberately not paired with a "Planar" fallback for the exhaust, although 11G reports one on the
  # same entity 7.1 : "Planar Temp" is the system board's own temperature, not the air leaving the
  # chassis. Putting it in the exhaust column would fill it with a number the heading does not describe,
  # which is worse than leaving it empty. 11G has no exhaust sensor, and "-" is the honest answer
  if [ -z "$INLET_TEMPERATURE" ]; then
    INLET_TEMPERATURE=$(retrieve_temperature_by_sensor_name "$DATA" "Ambient")
  fi

  # Parse exhaust temperature data, the sensor being located by its name like the inlet one.
  # It is read on every cycle rather than once, an empty value meaning "nothing on this cycle" rather
  # than "no such sensor" : the presence flag this used to consult was decided from a single pre-loop
  # reading and only ever set to false, so one partial SDR response -- or chassis sensors not yet
  # initialised while the CPU entities already were -- dropped the column for the container's lifetime
  # even though the sensor answered a second later. The display layer already renders an unreadable
  # value as the "-" placeholder, so a server that genuinely has no exhaust sensor still shows the
  # same column it did before, on every line
  EXHAUST_TEMPERATURE=$(retrieve_temperature_by_sensor_name "$DATA" "Exhaust")
}

# Report the target server's power state
# Returns : 0 if it is powered on, 1 if it is powered off, 2 if the iDRAC could not be reached
#
# Only meaningful in network mode: in local mode the container runs on the target server itself,
# so it cannot be observed powered off while the container is running
#
# The three outcomes used to be two. stderr and the exit code were both discarded and the verdict came
# from a substring, so a failed call produced empty output, didn't contain "is on", and was reported as
# a powered-off chassis -- indistinguishable from the real thing. A dropped session, rotated
# credentials, an iDRAC reboot and a LAN flap all landed in the same branch, and the caller skipped the
# cycle without reading temperatures or applying any profile, leaving the fans frozen at the user's
# static speed on a running, loaded server while the log called it benign
function get_server_power_state() {
  local POWER_STATUS
  POWER_STATUS=$(ipmitool -I $IDRAC_LOGIN_STRING chassis power status 2>&1)
  # shellcheck disable=SC2181  # $? here is the command substitution above, already run; there is no direct command left to negate
  if [ $? -ne 0 ]; then
    IPMI_UNREACHABLE_REASON="$POWER_STATUS"
    return 2
  fi

  [[ "$POWER_STATUS" == *"is on"* ]]
}

# Ask the server to apply Dell's default cooling response to third-party PCIe cards.
# In monitoring only mode, this is a no-op.
#
# Returns the server's own verdict : 0 if it took the command, non-zero if it refused it, and leaves
# what ipmitool said in THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STDERR for
# does_the_server_lack_this_command() to read.
#
# stderr is captured rather than printed : on a server that doesn't have this Dell OEM command it fails
# the exact same way on every single cycle forever, and this setting is a non-safety-critical cosmetic
# cooling response rather than core CPU fan control, so surfacing it every cycle would just recreate the
# original log-spam problem for no benefit. It is read, not shown
function enable_third_party_PCIe_card_Dell_default_cooling_response() {
  if "$MONITORING_ONLY_MODE"; then
    return 0
  fi
  # We could check the current cooling response before applying but it's not very useful so let's skip the test and apply directly
  THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STDERR=$(ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0xce 0x00 0x16 0x05 0x00 0x00 0x00 0x05 0x00 0x00 0x00 0x00 2>&1 >/dev/null)
}

# Ask the server to stop applying Dell's default cooling response to third-party PCIe cards.
# In monitoring only mode, this is a no-op.
# Returns the server's own verdict, exactly like its enable_ counterpart above
function disable_third_party_PCIe_card_Dell_default_cooling_response() {
  if "$MONITORING_ONLY_MODE"; then
    return 0
  fi
  # We could check the current cooling response before applying but it's not very useful so let's skip the test and apply directly
  THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STDERR=$(ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0xce 0x00 0x16 0x05 0x00 0x00 0x00 0x05 0x00 0x01 0x00 0x00 2>&1 >/dev/null)
}

# Returns :
# - 0 if third-party PCIe card Dell default cooling response is currently DISABLED
# - 1 if third-party PCIe card Dell default cooling response is currently ENABLED
# - 2 if the current status returned by ipmitool command output is unexpected
# function is_third_party_PCIe_card_Dell_default_cooling_response_disabled() {
#   THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE=$(ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0xce 0x01 0x16 0x05 0x00 0x00 0x00)

#   if [ "$THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE" == "16 05 00 00 00 05 00 01 00 00" ]; then
#     return 0
#   elif [ "$THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE" == "16 05 00 00 00 05 00 00 00 00" ]; then
#     return 1
#   else
#     print_error "Unexpected output: $THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE"
#     return 2
#   fi
# }

# Whether the given ipmitool stderr says the BMC itself answered and does not have the command, as
# opposed to ipmitool never having reached it.
# Usage : does_the_server_lack_this_command "$THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STDERR"
#
# ipmitool exits non-zero for both, which is exactly why the text is needed. A BMC that answered reports
# an IPMI completion code :
#   Unable to send RAW command (channel=0x0 netfn=0x30 lun=0x0 cmd=0xce rsp=0xc1): Invalid command
# while one that was never reached produces no completion code at all :
#   Error: Unable to establish IPMI v2 / RMCP+ session
#
# Only the two codes that mean "this command is not there" count : 0xc1 (invalid command) and 0xd5 (not
# supported in present state). Every other answer -- 0xc0 node busy, a timeout, an unreachable host, a
# message this function does not recognize -- is deliberately NOT a verdict, so the command keeps being
# retried rather than a conclusion being drawn from something that was never understood
function does_the_server_lack_this_command() {
  local -r IPMITOOL_STDERR="$1"

  [[ "$IPMITOOL_STDERR" == *"rsp=0xc1"* || "$IPMITOOL_STDERR" == *"rsp=0xd5"* ]]
}

# Whether the given ipmitool stderr says the BMC itself answered and refused the command for want of
# privilege, rather than not having it at all.
# Usage : does_the_command_need_a_higher_privilege_level "$THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STDERR"
#
# 0xd4 is "insufficient privilege level" : the command is there and this account may not run it. It is
# deliberately kept out of does_the_server_lack_this_command() above, because concluding "not supported
# by this server" from it would send a user to look at their hardware for something that lives in their
# iDRAC account -- the same shape of wrong diagnosis #195 set out to remove, on a different input.
#
# It is a verdict all the same, and a permanent one for this run : the credentials this container was
# given do not change while it runs, so neither will the answer. Concluded once and never retried,
# where a 0xc0 node busy or an unreachable host keep being sent the command on every cycle
function does_the_command_need_a_higher_privilege_level() {
  local -r IPMITOOL_STDERR="$1"

  [[ "$IPMITOOL_STDERR" == *"rsp=0xd4"* ]]
}

# Whether the given ipmitool stderr says the BMC itself answered, ran far enough to read the command's
# arguments, and rejected one of them.
# Usage : does_the_server_reject_this_data_field "$IPMITOOL_STDERR"
#
# 0xcc is "invalid data field in request" : the command is there and the account may run it, so the BMC
# got as far as reading its data bytes and refused one of them. That is the opposite verdict from the
# two predicates above, and it is deliberately kept out of both : concluding "this server has no fan
# control" from it would stop the controller sending a command the server does have, over an argument
# it could have been sent differently.
#
# What it does NOT say is which byte. That has to come from the hardware, and on the one server it has
# been reported from -- an R510 whose iDRAC6 answers 0xcc to the broadcast fan selector 0xff and takes
# the very same command with a single fan's ID (issue #378) -- it is the selector
function does_the_server_reject_this_data_field() {
  local -r IPMITOOL_STDERR="$1"

  [[ "$IPMITOOL_STDERR" == *"rsp=0xcc"* ]]
}

# Read one Redfish resource from the iDRAC and print what it answered.
# Usage : redfish_get "<resource path>"
# Prints : the HTTP status code on its own first line, then the response body
# Returns : 0 if the request could be attempted at all, 1 if it could not
#
# Redfish is HTTPS, a transport this container has never needed before, so three things are stated here
# rather than left to be discovered.
#
# It only exists in NETWORK mode. In local mode the controller reaches the BMC through /dev/ipmi0 and is
# given no iDRAC address and no credentials at all -- IDRAC_USERNAME and IDRAC_PASSWORD are documented as
# unused there -- so there is nothing to address an HTTPS request to. That is a property of the mode
# rather than a failure, which is why callers check it up front instead of discovering it as a timeout.
#
# Certificate verification is off, and that is a decision rather than a shortcut. An iDRAC ships a
# self-signed certificate from the factory and the overwhelming majority are never replaced, so verifying
# would fail on nearly every server this runs against. The request carries the credentials the IPMI
# session already carries, to the host it already talks to, on the same management network : it is the
# same trust decision, taken once more over a different transport. Turning verification on would not make
# those servers safer, it would make the feature unavailable on them.
#
# The password travels in the environment rather than in the argument list, for the reason
# set_iDRAC_login_string() passes ipmitool -E instead of -P : anything in argv is readable in ps
function redfish_request() {
  local -r HTTP_METHOD="$1"
  local -r RESOURCE_PATH="$2"
  local -r REQUEST_BODY="${3:-}"
  local -r TIMEOUT_IN_SECONDS="${4:-$REDFISH_REQUEST_TIMEOUT_IN_SECONDS}"

  if [ "$IDRAC_HOST" == "local" ]; then
    return 1
  fi

  REDFISH_REQUEST_BODY="$REQUEST_BODY" perl - "https://${IDRAC_HOST}${RESOURCE_PATH}" "$IDRAC_USERNAME" "$HTTP_METHOD" "$TIMEOUT_IN_SECONDS" <<'PERL_SCRIPT'
use strict;
use warnings;
use HTTP::Tiny;
use MIME::Base64 qw(encode_base64);

my ($url, $username, $method, $timeout) = @ARGV;
my $password = defined $ENV{'IPMI_PASSWORD'} ? $ENV{'IPMI_PASSWORD'} : '';
my $body     = defined $ENV{'REDFISH_REQUEST_BODY'} ? $ENV{'REDFISH_REQUEST_BODY'} : '';
my $credentials = encode_base64("$username:$password", '');

my %options = (headers => { 'Authorization' => "Basic $credentials" });
if (length $body) {
  $options{'content'} = $body;
  $options{'headers'}{'Content-Type'} = 'application/json';
}

# HTTP::Tiny reports anything that stopped the request from completing -- an unreachable host, a refused
# connection, a TLS failure -- as status 599, which is how an iDRAC that never answered stays
# distinguishable from one that answered 401 or 404
my $response = HTTP::Tiny->new(timeout => $timeout, verify_SSL => 0)
  ->request($method, $url, \%options);

print $response->{status}, "\n";
print $response->{content} if defined $response->{content};
PERL_SCRIPT
}

# Read one Redfish resource. See redfish_request() above.
# Usage : redfish_get "<resource path>" ["<timeout>"]
function redfish_get() {
  redfish_request "GET" "$1" "" "${2:-}"
}

# Change Redfish attributes. See redfish_request() above.
# Usage : redfish_patch "<resource path>" "<json body>" ["<timeout>"]
#
# This is the only place in this container that writes anything over anything other than IPMI, and it is
# reached only for the third-party PCIe card cooling response : never for a fan speed, never for a
# thermal profile, and never for a minimum fan speed, none of which Redfish could make this container's
# job possible anyway (issue #360)
function redfish_patch() {
  redfish_request "PATCH" "$1" "$2" "${3:-}"
}

# Whether this server exposes the third-party PCIe card cooling response over Redfish, asked of a server
# whose BMC has just answered that it does not have the IPMI command for it.
# Usage : does_this_server_expose_the_cooling_response_over_redfish
# Returns : 0 if the per-slot control was found, 1 otherwise, and
#           REDFISH_COOLING_RESPONSE_SLOT_COUNT, how many slots carry it
#
# TWO URIs, because neither reaches every iDRAC on its own. That is measured rather than assumed
# (issue #360) : the conformant one does not exist before iDRAC 9 5.x, where it answers 404 with
# Base.1.2.ResourceMissingAtURI -- the resource is absent, it is not a refusal, which would be 401 or
# 403 -- while the legacy one is documented as removed on iDRAC 10. The conformant path is therefore
# tried first and the legacy one only after a 404. Trying them the other way round would work on every
# machine reported so far and stop working on the newest hardware Dell sells.
#
# WHAT IS LOOKED FOR is the PCIeSlotLFM.<n>.LFMMode instances, and deliberately not the
# ThermalSettings.1.PCIeSlotLFMSupport flag that appears to exist for exactly this question. That flag
# reads "Not Supported" on a T550 whose 42 slot instances are populated and one of which is actively
# configured, and "Supported" on machines with fewer. The instances are evidence ; the flag is not, and
# believing it would switch this off on servers that support it perfectly well
function does_this_server_expose_the_cooling_response_over_redfish() {
  local -r TIMEOUT_IN_SECONDS="${1:-$REDFISH_REQUEST_TIMEOUT_IN_SECONDS}"

  REDFISH_COOLING_RESPONSE_SLOT_COUNT=0
  REDFISH_ATTRIBUTES_URI=""
  REDFISH_THIRD_PARTY_SLOTS=""
  # Empty means the request could not be made at all -- local mode, or no client to make it with --
  # which is a different thing from an iDRAC that answered something
  REDFISH_LAST_PROBE_STATUS=""

  local REDFISH_ANSWER
  local REDFISH_STATUS

  REDFISH_ANSWER=$(redfish_get "$REDFISH_CONFORMANT_ATTRIBUTES_URI" "$TIMEOUT_IN_SECONDS") || return 1
  REDFISH_STATUS=$(printf '%s\n' "$REDFISH_ANSWER" | head -n 1)
  REDFISH_LAST_PROBE_STATUS="$REDFISH_STATUS"
  REDFISH_ATTRIBUTES_URI="$REDFISH_CONFORMANT_ATTRIBUTES_URI"

  if [ "$REDFISH_STATUS" == "404" ]; then
    REDFISH_ANSWER=$(redfish_get "$REDFISH_LEGACY_ATTRIBUTES_URI" "$TIMEOUT_IN_SECONDS") || return 1
    REDFISH_STATUS=$(printf '%s\n' "$REDFISH_ANSWER" | head -n 1)
    REDFISH_LAST_PROBE_STATUS="$REDFISH_STATUS"
    REDFISH_ATTRIBUTES_URI="$REDFISH_LEGACY_ATTRIBUTES_URI"
  fi

  if [ "$REDFISH_STATUS" != "200" ]; then
    REDFISH_ATTRIBUTES_URI=""
    return 1
  fi

  REDFISH_COOLING_RESPONSE_SLOT_COUNT=$(printf '%s\n' "$REDFISH_ANSWER" | grep -o '"PCIeSlotLFM\.[0-9]\+\.LFMMode"' | wc -l)

  # The slots that actually hold a third-party card are the only ones this parameter is about, and the
  # only ones worth writing to. A slot answering "No" holds a Dell card, whose airflow Dell has real data
  # for ; one answering "N/A" is empty. Writing to either would change a setting nobody asked about, on a
  # slot where the cooling response was never the problem
  # The slot number is taken with sed rather than by grepping digits out of the matched attribute name :
  # "3rdPartyCard" begins with a digit of its own, so "PCIeSlotLFM.6.3rdPartyCard" yields 6 AND 3 to any
  # pattern that simply collects numbers. That reads as twice the slots there are, half of them wrong,
  # and would have written the setting to slots holding somebody else's card
  REDFISH_THIRD_PARTY_SLOTS=$(printf '%s\n' "$REDFISH_ANSWER" | tr ',' '\n' \
    | sed -n 's/^[^"]*"PCIeSlotLFM\.\([0-9]\+\)\.3rdPartyCard":"Yes".*$/\1/p' \
    | sort -n -u | tr '\n' ' ')

  [ "$REDFISH_COOLING_RESPONSE_SLOT_COUNT" -gt 0 ]
}

# Read the LFM mode one PCIe slot is currently in.
# Usage : read_the_lfm_mode_of_slot "$REDFISH_BODY" "$SLOT_NUMBER"
function read_the_lfm_mode_of_slot() {
  local -r REDFISH_BODY="$1"
  local -r SLOT_NUMBER="$2"

  printf '%s\n' "$REDFISH_BODY" | tr ',' '\n' \
    | grep -o "\"PCIeSlotLFM\.${SLOT_NUMBER}\.LFMMode\":\"[^\"]*\"" \
    | head -n 1 | sed 's/.*:"//; s/"$//'
}

# Put the third-party PCIe card cooling response into the wanted state over Redfish, on the slots that
# hold such a card.
# Usage : set_the_cooling_response_over_redfish "Disabled"|"Automatic"
# Returns : 0 if every slot that needed changing was changed, 1 otherwise, and
#           REDFISH_SLOTS_WRITTEN, how many were
#
# "Automatic" is Dell's default and is what "enabled" means here : the iDRAC decides that slot's airflow
# for itself, which is exactly the behaviour DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE
# exists to switch off. Restoring it is therefore applying Dell's default rather than putting back
# whatever was there before -- the same thing enable_third_party_PCIe_card_Dell_default_cooling_response()
# does over IPMI, so KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT keeps one meaning on both
# transports. It also means no per-slot state has to be carried anywhere, which is what lets the
# supervisor hand this back on a path where it remembers nothing.
#
# WRITTEN ONCE AND ONLY WHERE NEEDED, unlike the IPMI command that is re-sent every cycle. A Redfish
# PATCH is not a free stateless command : each one creates a configuration job on the iDRAC, so
# re-sending it every CHECK_INTERVAL would fill that queue for no gain. The slots already in the wanted
# state are skipped, and a human who changes one back is not fought over it every five seconds
function set_the_cooling_response_over_redfish() {
  local -r WANTED_LFM_MODE="$1"
  local -r TIMEOUT_IN_SECONDS="${2:-$REDFISH_REQUEST_TIMEOUT_IN_SECONDS}"

  REDFISH_SLOTS_WRITTEN=0

  if [ -z "$REDFISH_ATTRIBUTES_URI" ] || [ -z "$REDFISH_THIRD_PARTY_SLOTS" ]; then
    return 0
  fi

  local REDFISH_ANSWER
  REDFISH_ANSWER=$(redfish_get "$REDFISH_ATTRIBUTES_URI" "$TIMEOUT_IN_SECONDS") || return 1
  if [ "$(printf '%s\n' "$REDFISH_ANSWER" | head -n 1)" != "200" ]; then
    return 1
  fi

  local ATTRIBUTES_TO_WRITE=""
  local SLOT
  for SLOT in $REDFISH_THIRD_PARTY_SLOTS; do
    if [ "$(read_the_lfm_mode_of_slot "$REDFISH_ANSWER" "$SLOT")" == "$WANTED_LFM_MODE" ]; then
      continue
    fi
    [ -n "$ATTRIBUTES_TO_WRITE" ] && ATTRIBUTES_TO_WRITE+=","
    ATTRIBUTES_TO_WRITE+="\"PCIeSlotLFM.${SLOT}.LFMMode\":\"${WANTED_LFM_MODE}\""
    REDFISH_SLOTS_WRITTEN=$((REDFISH_SLOTS_WRITTEN + 1))
  done

  if [ -z "$ATTRIBUTES_TO_WRITE" ]; then
    return 0
  fi

  # Every slot in one PATCH rather than one request each : the iDRAC applies the whole Attributes object
  # in a single configuration job, which is both faster and one job instead of N on a server that may
  # have forty of them
  REDFISH_LAST_WRITE_STATUS=$(redfish_patch "$REDFISH_ATTRIBUTES_URI" "{\"Attributes\":{${ATTRIBUTES_TO_WRITE}}}" "$TIMEOUT_IN_SECONDS" | head -n 1)

  case "$REDFISH_LAST_WRITE_STATUS" in
    200|202|204) return 0 ;;
    *) REDFISH_SLOTS_WRITTEN=0 ; return 1 ;;
  esac
}

# Whether an answer to a Redfish write settles the question for the life of this container, as opposed
# to describing a moment this iDRAC was having.
# Usage : is_this_redfish_answer_a_verdict "$REDFISH_LAST_WRITE_STATUS"
#
# Only the answers about the REQUEST, the RESOURCE or the CREDENTIALS count, none of which changes while
# the container runs : 400 a body this iDRAC will reject identically every time, 401 and 403 an account
# whose rights are what they are, 404 a resource that is not there -- and both URIs have already been
# tried by then -- and 405 a method this resource does not take.
#
# Everything else is a moment rather than a verdict -- 409 a configuration job already running, 500 a
# busy iDRAC, 503 a full job queue, 599 a request that never completed at all because something between
# here and the BMC was down. AND SO IS ANY ANSWER NOT LISTED HERE, deliberately : concluding from a code
# nobody here has seen would be drawing a permanent conclusion from something that was never understood,
# which is the mistake does_the_server_lack_this_command() is written to avoid on the IPMI side (#376)
function is_this_redfish_answer_a_verdict() {
  local -r WRITE_STATUS="$1"

  case "$WRITE_STATUS" in
    400|401|403|404|405) return 0 ;;
    *) return 1 ;;
  esac
}

# Try to put the third-party PCIe card cooling response into the wanted state over Redfish, count the
# attempt, and decide whether there is any point in another one.
# Usage : apply_the_cooling_response_over_redfish "<wanted LFM mode>" "<Enabled|Disabled>"
# Returns : THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS, what the table says
#           REDFISH_COOLING_RESPONSE_SETTLED, whether this stops being attempted
#           REDFISH_ATTEMPTS, how many have been made
#
# Called on the cycle the IPMI verdict is reached and, while nothing has settled it, on later cycles --
# which is what spaces the attempts a CHECK_INTERVAL apart instead of looping here and starving the
# temperature reading this container still does correctly on these servers
function apply_the_cooling_response_over_redfish() {
  local -r WANTED_LFM_MODE="$1"
  local -r REQUESTED_STATE="$2"

  REDFISH_ATTEMPTS=$(( ${REDFISH_ATTEMPTS:-0} + 1 ))

  if set_the_cooling_response_over_redfish "$WANTED_LFM_MODE"; then
    REDFISH_COOLING_RESPONSE_SETTLED=true
    THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS="$REQUESTED_STATE over Redfish"
    print_warning "This server does not have the IPMI command for the third-party PCIe card cooling response, so it is being set over Redfish instead.
 Dell moved it at the 14th generation, from one command covering the whole server to one attribute per PCIe slot. This iDRAC exposes it on $REDFISH_COOLING_RESPONSE_SLOT_COUNT slots, of which $(printf '%s' "$REDFISH_THIRD_PARTY_SLOTS" | wc -w) hold a third-party card : $REDFISH_THIRD_PARTY_SLOTS.
 Those are the only ones written to, and $REDFISH_SLOTS_WRITTEN of them needed changing. A slot holding a Dell card or no card at all is left alone, its airflow being something Dell has real data for.
 Written once rather than on every cycle : a Redfish write creates a configuration job on the iDRAC, so re-sending it every CHECK_INTERVAL would fill that queue for nothing."
    return 0
  fi

  # An answer about the request or the credentials will not read differently on the next cycle, so
  # trying again would only make the same wrong request twice more
  if is_this_redfish_answer_a_verdict "$REDFISH_LAST_WRITE_STATUS"; then
    REDFISH_COOLING_RESPONSE_SETTLED=true
    THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS="Redfish refused this change (see the log)"
    print_error "This server exposes the third-party PCIe card cooling response over Redfish, but refused to change it with HTTP $REDFISH_LAST_WRITE_STATUS. That answer is about this request or these credentials rather than about a moment the iDRAC was having, so it will not read differently on the next cycle and is not retried. $REDFISH_MANUAL_INSTRUCTIONS"
    return 1
  fi

  if [ "$REDFISH_ATTEMPTS" -lt "$MAXIMUM_REDFISH_ATTEMPTS" ]; then
    THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS="Redfish refused this change, retrying"
    return 1
  fi

  # The span between the first attempt and this one, which is what the reader needs : "three times" says
  # nothing without the interval they were spread over, and CHECK_INTERVAL ranges from seconds to minutes
  REDFISH_COOLING_RESPONSE_SETTLED=true
  local -r REFUSED_OVER_SECONDS=$(( (REDFISH_ATTEMPTS - 1) * ${CHECK_INTERVAL_IN_SECONDS:-0} ))
  THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS="Redfish refused this change (see the log)"
  print_error "This server exposes the third-party PCIe card cooling response over Redfish, but refused to change it $REDFISH_ATTEMPTS times, i.e. over about $REFUSED_OVER_SECONDS seconds. The last answer was HTTP $REDFISH_LAST_WRITE_STATUS. Answers like that one describe a moment rather than a decision -- a busy iDRAC, a full configuration job queue, a request that never completed -- so they were retried rather than concluded from, and $MAXIMUM_REDFISH_ATTEMPTS attempts is where that stops. $REDFISH_MANUAL_INSTRUCTIONS"
  return 1
}

# The whole Redfish errand for the cooling response : find out whether the server has the setting, then
# put it into the wanted state. One entry point, so that the cycle the IPMI verdict is reached and every
# retry after it take exactly the same path.
# Usage : attempt_the_redfish_cooling_response "<wanted LFM mode>" "<Enabled|Disabled>"
#
# THE PROBE FAILING IS NOT AN ANSWER ABOUT THE SERVER. It was treated as one, and that put back the
# exact falsehood #374 was written to remove : an iDRAC whose HTTPS stack did not answer at that second
# -- reachable over IPMI, merely busy or briefly unreachable -- had its server reported as not having a
# setting it has, for the life of the container. So the same split the write uses applies here : an
# answer about the resource or the credentials settles it, a moment is tried again (#376)
function attempt_the_redfish_cooling_response() {
  local -r WANTED_LFM_MODE="$1"
  local -r REQUESTED_STATE="$2"

  if does_this_server_expose_the_cooling_response_over_redfish "$REDFISH_REQUEST_TIMEOUT_IN_SECONDS"; then
    IS_THE_COOLING_RESPONSE_DRIVEN_OVER_REDFISH=true

    if [ -z "$REDFISH_THIRD_PARTY_SLOTS" ]; then
      # The server has the setting and nothing to apply it to. Saying that is worth more than either
      # alternative : "not supported" would be false about the machine, and reporting it applied would be
      # false about what was done
      REDFISH_COOLING_RESPONSE_SETTLED=true
      THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS="No third-party PCIe card to apply it to"
      print_warning "This server does not have the IPMI command for the third-party PCIe card cooling response, but it does have the setting, on $REDFISH_COOLING_RESPONSE_SLOT_COUNT PCIe slots over Redfish.
 None of them currently holds a third-party card, so there is nothing to apply DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE to. Dell's own airflow data covers the cards that are there.
 Nothing else changes : temperatures keep being read and logged every cycle."
      return 0
    fi

    if "$MONITORING_ONLY_MODE"; then
      REDFISH_COOLING_RESPONSE_SETTLED=true
      THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS="Redfish (not applied: monitoring only mode)"
      return 0
    fi

    apply_the_cooling_response_over_redfish "$WANTED_LFM_MODE" "$REQUESTED_STATE"
    return $?
  fi

  REDFISH_ATTEMPTS=$(( ${REDFISH_ATTEMPTS:-0} + 1 ))

  # Nothing was asked, because there was nothing to ask. In local mode the controller reaches the BMC
  # through /dev/ipmi0 and is given no iDRAC address and no credentials, so this says what is true --
  # the transport is missing -- rather than blaming a server that may well have the setting
  if [ -z "$REDFISH_LAST_PROBE_STATUS" ]; then
    REDFISH_COOLING_RESPONSE_SETTLED=true
    THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS="Not over IPMI (Redfish needs network mode)"
    print_warning "This server does not have the IPMI command for the third-party PCIe card cooling response. Dell moved it at the 14th generation to a per-slot setting reachable over Redfish, which is HTTPS and therefore needs an iDRAC address and credentials -- and local mode has neither, reaching the BMC through /dev/ipmi0 instead. Set IDRAC_HOST, IDRAC_USERNAME and IDRAC_PASSWORD to run this container in network mode if you want DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE to have an effect on this server. Nothing else changes : temperatures keep being read and logged every cycle."
    return 1
  fi

  # Read, understood, and the answer is no : the attribute document is there and carries no per-slot
  # control at all. That is the one case where naming the server is the honest thing to do
  if [ "$REDFISH_LAST_PROBE_STATUS" == "200" ] || [ "$REDFISH_LAST_PROBE_STATUS" == "404" ]; then
    REDFISH_COOLING_RESPONSE_SETTLED=true
    THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS="Not supported by this server"
    return 1
  fi

  if is_this_redfish_answer_a_verdict "$REDFISH_LAST_PROBE_STATUS"; then
    REDFISH_COOLING_RESPONSE_SETTLED=true
    THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS="Redfish refused to answer (see the log)"
    print_error "This server does not have the IPMI command for the third-party PCIe card cooling response, and its Redfish interface answered HTTP $REDFISH_LAST_PROBE_STATUS when asked whether it has the setting instead. That answer is about these credentials or this request rather than about a moment the iDRAC was having, so it will not read differently on the next cycle and is not retried. Whether this server has the setting is therefore unknown rather than answered : check that IDRAC_USERNAME may read the iDRAC attributes. $REDFISH_MANUAL_INSTRUCTIONS"
    return 1
  fi

  if [ "$REDFISH_ATTEMPTS" -lt "$MAXIMUM_REDFISH_ATTEMPTS" ]; then
    THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS="Cannot reach Redfish yet, retrying"
    return 1
  fi

  REDFISH_COOLING_RESPONSE_SETTLED=true
  local -r UNREACHED_OVER_SECONDS=$(( (REDFISH_ATTEMPTS - 1) * ${CHECK_INTERVAL_IN_SECONDS:-0} ))
  THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS="Redfish could not be reached (see the log)"
  print_error "This server does not have the IPMI command for the third-party PCIe card cooling response, and its Redfish interface could not be reached to find out whether it has the setting instead : $REDFISH_ATTEMPTS attempts, i.e. over about $UNREACHED_OVER_SECONDS seconds, the last answering HTTP $REDFISH_LAST_PROBE_STATUS. This says nothing about the server, only about reaching it, so it is deliberately NOT reported as a server without the setting. $REDFISH_MANUAL_INSTRUCTIONS"
  return 1
}

# Whether this server has been seen to refuse fan control outright, in which case the controller stops
# sending it. The fan control profile functions at the top of this file are the ones that stop on it ;
# graceful_exit() and fan_control_comment_clause() only read it to word what they report.
# Usage : has_the_server_refused_fan_control
#
# The default matters, and the supervisor is why. functions.sh is also sourced by the healthcheck, which
# sends no fan control command at all, by the test harness, and by supervisor.sh, which sends exactly one
# -- the hand-back of apply_Dell_default_fan_control_profile(), on the path issues #188 and #249 exist
# for -- from a process that never watched a single answer and therefore never reached a verdict. Left
# undefined there, the guard would read empty and the safety net would skip the one command it exists to
# send. Nowhere the verdict was never made can be a place where it was made against the server
function has_the_server_refused_fan_control() {
  ! "${IS_FAN_CONTROL_SUPPORTED:-true}"
}

# Read a refused fan control command and, if the server itself refused it, record that it is not worth
# sending again and say so once.
# Usage : note_that_the_server_refuses_fan_control "$IPMITOOL_STDERR"
# Returns : IS_FAN_CONTROL_SUPPORTED, and 0 if the verdict was reached on this call
#
# Two conditions, and the second is the one that keeps this safe. A refusal only settles anything while
# nothing has ever been accepted : once a fan control command has landed, the fans are the controller's
# and a later refusal is a failure to give them back rather than a server that never let them go. Giving
# up there would leave them pinned at the user's speed with nobody raising them, which is the accident
# this whole container exists to avoid
function note_that_the_server_refuses_fan_control() {
  local -r IPMITOOL_STDERR="$1"

  if "${HAS_FAN_CONTROL_EVER_BEEN_ACCEPTED:-false}"; then
    return 1
  fi

  if ! does_the_server_lack_this_command "$IPMITOOL_STDERR" && ! does_the_command_need_a_higher_privilege_level "$IPMITOOL_STDERR"; then
    return 1
  fi

  IS_FAN_CONTROL_SUPPORTED=false

  print_warning "This server refused fan control, so the container will stop asking and keep reading temperatures instead.
 Its fans are not left in an unknown state : the command that was refused is the one that takes them away from Dell's own dynamic fan control profile, so they never left it.
 Two things answer like this, and the completion code does not say which. Dell removed these commands from the 14th generation on -- an iDRAC 9 refuses them from firmware 3.34.34.34 onwards, and an iDRAC 10 has never had them -- and an iDRAC also refuses them to an account that is not an Administrator. This iDRAC reports firmware version ${IDRAC_FIRMWARE_VERSION:-unknown}.
 If your iDRAC is one that used to accept them, check the privilege level of IDRAC_USERNAME before concluding that the firmware is the reason. The README's \"iDRAC version\" section covers both.
 Nothing else changes : temperatures keep being read and logged every cycle, as MONITORING_ONLY_MODE would"
}

# Whether the server has already been told about the broadcast fan selector it rejects, so that it is
# explained the once rather than on every cycle for the life of the container.
# Only ever written by note_that_the_server_rejects_the_broadcast_fan_selector() below
HAS_THE_BROADCAST_FAN_SELECTOR_REJECTION_BEEN_REPORTED=false

# Read a refused fan speed command and, if the server refused it over its data bytes, explain the one
# thing that answers like this and say it once.
# Usage : note_that_the_server_rejects_the_broadcast_fan_selector "$IPMITOOL_STDERR"
# Returns : 0 if this call is the one that explained it
#
# This deliberately reaches NO verdict and stops nothing being sent. It is the counterpart of
# note_that_the_server_refuses_fan_control() for the other completion code, and the difference between
# the two is the whole point : 0xc1, 0xd4 and 0xd5 are a server saying the command is not its to run,
# while 0xcc is a server that has the command, ran it, and refused an argument. Giving up on the second
# would stop the controller sending a command the server does have.
#
# What it says instead is the state the fans are actually in, which is the part a raw ipmitool line
# repeated every 60 seconds does not. Only the second of the two commands failed here : the first one
# has already taken the fans away from Dell's own dynamic fan control profile, and the speed that was
# supposed to follow it never landed. The fans are therefore on neither profile -- not Dell's, and not
# the user's -- which is exactly the shape of "too low with nobody raising them" reported in issue #378
#
# /!\ The per-fan fallback this points to is NOT implemented yet, and this message must not claim it is.
# The one server that has reported this answers 0xcc to the broadcast selector 0xff and accepts the same
# command with a single fan's ID, but one accepted ID says nothing about how many fans the server has
# nor whether Dell numbers them from 0 or from 1, and addressing the wrong set would leave some fans
# unset while reporting the profile applied
function note_that_the_server_rejects_the_broadcast_fan_selector() {
  local -r IPMITOOL_STDERR="$1"

  if ! does_the_server_reject_this_data_field "$IPMITOOL_STDERR"; then
    return 1
  fi

  if "$HAS_THE_BROADCAST_FAN_SELECTOR_REJECTION_BEEN_REPORTED"; then
    return 1
  fi

  HAS_THE_BROADCAST_FAN_SELECTOR_REJECTION_BEEN_REPORTED=true

  print_warning "This server took the command that puts its fans under manual control, then refused the one that sets their speed, over one of its arguments rather than over the command itself (completion code 0xcc, \"invalid data field in request\").
 Its fans are consequently on neither profile : they have left Dell's own dynamic fan control profile, and the speed of $DECIMAL_FAN_SPEED% that was meant to replace it never reached them. They are running at whatever this iDRAC does with manual control and no speed set, which nothing here can read back.
 The known cause is the fan selector : the speed is addressed to every fan at once with 0xff, and an 11th generation iDRAC6 has been reported to reject that and to accept the very same command addressed to one fan's ID at a time (issue #378). Sending it per fan instead is not implemented yet -- it needs to be known how many fans a server exposes and how this iDRAC numbers them, and guessing would silently leave some of them unset.
 Until then, set MONITORING_ONLY_MODE=true so the container never takes the fans from Dell's own dynamic fan control profile at all and only logs temperatures, or stop it : stopping hands them back to that profile on the way out.
 If your server answers this, the output of \"ipmitool -I lanplus -H <iDRAC IP address> -U <iDRAC username> -P <iDRAC password> sdr type fan\" on issue #378 is what is missing to implement it"
}

# Prepare traps in case of container exit
function graceful_exit() {
  if "$MONITORING_ONLY_MODE"; then
    print_warning_and_exit "Container stopped (monitoring only mode, no fan control profile was ever applied)"
  fi

  apply_Dell_default_fan_control_profile

  # Reset third-party PCIe card cooling response to Dell default depending on the user's choice at
  # startup. This is deliberately NOT gated on whether the server was seen to accept the command
  # earlier : the controller gives up on a command refused several cycles in a row, and if it gave up
  # for the wrong reason — an iDRAC that was being reset, a network outage — skipping the reset here
  # would leave the server on the user's setting for good. One refused command on the way out costs
  # nothing; a setting left behind on a server nothing is monitoring any more does
  if ! "$KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT"; then
    # Over whichever transport it was driven. On a 14th generation server the IPMI command below is the
    # one the BMC answered "invalid command" to on the first cycle, so sending it again would undo
    # nothing : what has to be put back is the per-slot Redfish attribute this container wrote. The
    # short timeout is the point -- this runs after the fans are already safe, but still inside Docker's
    # ten second stop grace period, and a container killed for taking too long to stop would be worse
    # than a cooling response left as the user set it
    if "${IS_THE_COOLING_RESPONSE_DRIVEN_OVER_REDFISH:-false}"; then
      set_the_cooling_response_over_redfish "Automatic" "$REDFISH_EXIT_REQUEST_TIMEOUT_IN_SECONDS" \
        || print_error "Could not hand the third-party PCIe card cooling response back to Dell's default over Redfish. It is left as this container set it, and can be put back in the iDRAC web interface"
    else
      enable_third_party_PCIe_card_Dell_default_cooling_response
    fi
  fi

  # Nothing was handed back on a server that never let anything be taken, and saying otherwise would be
  # the same lie as naming a profile the server is not running. The verdict itself only holds while no
  # fan control command has ever been accepted, so there is no state left behind for this line to hide
  if has_the_server_refused_fan_control; then
    print_warning_and_exit "Container stopped (this server refused fan control, so no profile was ever applied and its fans never left Dell's own dynamic fan control profile)"
  fi

  print_warning_and_exit "Container stopped, Dell default dynamic fan control profile applied for safety"
}

# Helps debugging when people are posting their output
function get_Dell_server_model() {
  local IPMI_FRU_content
  # FRU stands for "Field Replaceable Unit". Capture stderr too so a failed IPMI connection can be reported instead of silently discarded
  IPMI_FRU_content=$(ipmitool -I $IDRAC_LOGIN_STRING fru 2>&1)
  local -r ipmitool_exit_code=$?

  # The server is the builtin FRU device (ID 0). "ipmitool fru" describes every FRU device on the bus,
  # and all the others are parts rather than the server : a populated power supply fills these very same
  # fields with its own manufacturer and its own product name.
  #
  # Reading the whole inventory and taking the first match (issue #319) is right only as long as the
  # builtin device fills the field itself. When it does not, the first match silently comes from
  # whichever device is listed next, so a server declaring no manufacturer of its own gets identified by
  # its power supply's brand -- and a non-Dell server carrying a Dell branded power supply then passes
  # the caller's "is this a Dell?" test, which exists to keep Dell's raw commands away from hardware
  # that is not Dell. Narrowing the search to the builtin device's own section closes that.
  #
  # An inventory that labels no builtin device is read whole, exactly as before, rather than not at all
  local FRU_SERVER_SECTION
  FRU_SERVER_SECTION=$(echo "$IPMI_FRU_content" | awk '
    /^FRU Device Description/ { inside = ($0 ~ /Builtin FRU Device/); next }
    inside')
  if [ -z "$FRU_SERVER_SECTION" ]; then
    FRU_SERVER_SECTION="$IPMI_FRU_content"
  fi

  # First match only within that section too : one device cannot sensibly report the field twice, but a
  # whole-inventory fallback above would otherwise bring the parts back in
  SERVER_MANUFACTURER=$(echo "$FRU_SERVER_SECTION" | grep "Product Manufacturer" | awk -F ': ' '{print $2; exit}')
  SERVER_MODEL=$(echo "$FRU_SERVER_SECTION" | grep "Product Name" | awk -F ': ' '{print $2; exit}')

  # Check if SERVER_MANUFACTURER is empty, if yes, assign value based on "Board Mfg"
  if [ -z "$SERVER_MANUFACTURER" ]; then
    SERVER_MANUFACTURER=$(echo "$FRU_SERVER_SECTION" | tr -s ' ' | grep "Board Mfg :" | awk -F ': ' '{print $2; exit}')
  fi

  # Check if SERVER_MODEL is empty, if yes, assign value based on "Board Product"
  if [ -z "$SERVER_MODEL" ]; then
    SERVER_MODEL=$(echo "$FRU_SERVER_SECTION" | tr -s ' ' | grep "Board Product :" | awk -F ': ' '{print $2; exit}')
  fi

  # Whether the server could be identified is the reliable signal here, not ipmitool's
  # exit code : "ipmitool fru" walks every FRU device and returns non-zero as soon as a
  # single one of them fails to read, which is the normal state of healthy hardware.
  # An unpopulated drive backplane or PSU bay answers "Device not present (Timeout)"
  # while the builtin FRU device (ID 0) still returns the manufacturer and the model, so
  # exiting on the exit code alone refused to start on servers that were perfectly fine.
  # The FRU walk is a property of the inventory and not of the transport, so "-I open"
  # and "-I lanplus" were refused alike.
  #
  # The failure #103 asked to catch is total rather than partial, so gating on the
  # identification keeps catching it : a session that cannot be opened returns no
  # inventory at all, both fields above stay empty and the error below still fires
  if [ -n "$SERVER_MANUFACTURER" ] || [ -n "$SERVER_MODEL" ]; then
    return 0
  fi

  # Only mention the exit code when there is one to report : an inventory that came back
  # empty from a call that succeeded is not a failed call, and "exited with code 0" inside
  # a connection error would contradict itself
  local IPMITOOL_REPORT="ipmitool said: $IPMI_FRU_content"
  if [ $ipmitool_exit_code -ne 0 ]; then
    IPMITOOL_REPORT="ipmitool exited with code $ipmitool_exit_code and said: $IPMI_FRU_content"
  fi

  # Local mode never sends a username nor a password -- it talks to the Docker host's own
  # BMC through the exposed IPMI device -- so naming those two parameters there would send
  # the user to correct something the connection does not even use
  if [[ "$IDRAC_HOST" == "local" ]]; then
    print_configuration_error_and_exit "IDRAC_HOST" "$IDRAC_HOST" \
      "an IPMI device the host's own BMC answers on. Nothing could be read from it, so the server could not be identified. IDRAC_USERNAME and IDRAC_PASSWORD are not used in local mode, so they are not what to check here. $IPMITOOL_REPORT" \
      "Check that the device exposed with \"--device=\" is your server's IPMI device and that its
kernel modules (\"ipmi_devintf\", \"ipmi_si\") are loaded on the Docker host, then start the
container again. Alternatively, set IDRAC_HOST to your iDRAC's address to use network mode instead." \
      "false"
  fi

  # The one refusal a restart can genuinely clear, and the only one that must not claim otherwise : a
  # BMC that was resetting, an iDRAC still booting or a network that was down all answer on the next
  # attempt without anybody correcting anything, and the restart policy is what carries that user
  # through. It is also the escalation MAXIMUM_IPMI_UNREACHABLE_DURATION relies on once the loop is
  # running, and the README already tells its readers to run under a restart policy because of it
  print_configuration_error_and_exit "IDRAC_HOST / IDRAC_USERNAME / IDRAC_PASSWORD" "$IDRAC_HOST" "credentials that can open an IPMI session. $IPMITOOL_REPORT" "" "false"
}

# Read the firmware version the iDRAC reports about itself, for the startup log.
# Usage : get_iDRAC_firmware_version
# Returns : IDRAC_FIRMWARE_VERSION, or "unknown" when the iDRAC reported none
#
# Also helps debugging when people are posting their output : the firmware version is the first thing
# asked for on every report about fan control not being applied, and it was the one thing about the
# server this container never printed.
#
# "ipmitool mc info" reports two numbers where Dell's own firmware bundles carry four -- an iDRAC 9 on
# 6.10.30.00 answers "6.10" -- and that is a property of IPMI rather than of Dell : the Get Device ID
# response spends one byte on the major version and one on the minor one, and leaves the rest to a
# vendor-specific auxiliary field this does not try to decode. Two numbers are enough for what this is
# for, which is a log line a human reads, and the exact build is one "racadm getversion" away for
# anyone who needs it.
#
# /!\ What it is NOT for is deciding whether this server accepts fan control. Nothing here compares the
# version against 3.34.34.34, because the numbering restarted at 1.x with the iDRAC 10 of the 17th
# generation : every comparison that reads "below 3.34.34.34, so the commands are there" calls the
# newest hardware Dell makes the oldest. The controller settles that question the way it settles every
# other one, by sending the command and reading the answer
function get_iDRAC_firmware_version() {
  local IPMI_MC_INFO
  # stderr is discarded : this is a read-only diagnostic call, some iDRAC firmwares print a harmless
  # protocol warning on every call, and a version that could not be read is reported as unknown rather
  # than turned into an error. Nothing the controller does depends on it
  IPMI_MC_INFO=$(ipmitool -I $IDRAC_LOGIN_STRING mc info 2>/dev/null)

  IDRAC_FIRMWARE_VERSION=$(echo "$IPMI_MC_INFO" | grep -m 1 "Firmware Revision" | awk -F ':' '{print $2}' | tr -d '[:space:]')

  if [ -z "$IDRAC_FIRMWARE_VERSION" ]; then
    IDRAC_FIRMWARE_VERSION="unknown"
  fi
}

# Settle the width of the "Active fan speed profile" column, which the header and the rows both lay
# themselves out from. It depends only on MONITORING_ONLY_MODE, fixed for the container's lifetime, so it
# is resolved once at startup rather than per row -- and, coming from one place, the header and the rows
# cannot end up reserving different widths for the same column, which is the defect this exists to close
# Usage : resolve_fan_control_profile_column_width
# Returns : TABLE_FAN_CONTROL_PROFILE_COLUMN_WIDTH
function resolve_fan_control_profile_column_width() {
  if "$MONITORING_ONLY_MODE"; then
    TABLE_FAN_CONTROL_PROFILE_COLUMN_WIDTH=$MONITORING_ONLY_MODE_FAN_CONTROL_PROFILE_COLUMN_WIDTH
  else
    TABLE_FAN_CONTROL_PROFILE_COLUMN_WIDTH=$FAN_CONTROL_PROFILE_COLUMN_WIDTH
  fi
}

# Centre a column heading in a column of the given width, the odd character going to the left, which is the
# convention the "Temperatures" banner already follows. Written into a named variable like
# set_log_timestamp() does, rather than echoed, so that no subshell is paid for a string this short.
#
# Centred rather than right-aligned : the values below are right-aligned, but the monitoring only mode
# profile column is 71 characters wide, and a heading flush against its right edge would drift away from
# the heading on its left. This is also what the table has always displayed
# Usage : center_column_heading HEADING_VARIABLE "Heading" $COLUMN_WIDTH
function center_column_heading() {
  local -r TARGET_VARIABLE_NAME="$1"
  local -r HEADING="$2"
  local -r COLUMN_WIDTH="$3"

  local -r LEFT_PADDING_WIDTH=$(( (COLUMN_WIDTH - ${#HEADING} + 1) / 2 ))
  local -r RIGHT_PADDING_WIDTH=$(( COLUMN_WIDTH - ${#HEADING} - LEFT_PADDING_WIDTH ))

  printf -v "$TARGET_VARIABLE_NAME" '%*s%s%*s' "$LEFT_PADDING_WIDTH" '' "$HEADING" "$RIGHT_PADDING_WIDTH" ''
}

# Builds the two header lines of the temperatures table, sized for the CPUs actually detected
# Usage : build_header $CPU_COLUMN_CONTENT_WIDTH ["CPU 1" "CPU 2" ...]
#
# No label at all is a valid table : monitoring only mode runs on a server exposing no processor
# entity, and its inlet and exhaust are still worth logging. The banner then spans "Inlet  Exhaust",
# which is the width of its own title, so it comes out with no dashes on either side rather than
# mis-sized
function build_header() {
  if (( $# < 1 )); then
    print_error "build_header() requires a column content width"
    return 1
  fi

  # The one width that does not arrive as an argument : the rows read it too, and threading it through the
  # seven parameters print_temperature_array_line() already takes would be worse than naming it once. Left
  # unresolved it would pad to nothing and misalign every row silently, so it is refused here instead --
  # this runs once, at startup, and the caller turns a refusal into a container that stops
  if [ -z "$TABLE_FAN_CONTROL_PROFILE_COLUMN_WIDTH" ]; then
    print_error "build_header() needs the fan control profile column width, resolve_fan_control_profile_column_width() has not run"
    return 1
  fi

  # Prefixed with LOCAL_ like in print_temperature_array_line() : the caller stores this width in a
  # readonly global of the obvious name, and a local shadowing it would be refused by bash
  local -r LOCAL_CPU_COLUMN_CONTENT_WIDTH="$1"
  shift
  local -r -a CPU_LABELS=("$@")

  # The banner spans the whole temperatures section, from the "I" of "Inlet" to the "t" of "Exhaust" :
  # "Inlet" (5) and its trailing space, then one column per CPU (its content plus a space on each side),
  # then the space preceding "Exhaust" (7). Hence the fixed 5 + 1 + 1 + 7 = 14
  local -r TITLE=" Temperatures "
  local -r BANNER_WIDTH=$(( ${#CPU_LABELS[@]} * (LOCAL_CPU_COLUMN_CONTENT_WIDTH + 2) + 14 ))
  local -r NUMBER_OF_LEFT_DASHES=$(( (BANNER_WIDTH - ${#TITLE} + 1) / 2 ))
  local -r NUMBER_OF_RIGHT_DASHES=$(( BANNER_WIDTH - ${#TITLE} - NUMBER_OF_LEFT_DASHES ))

  local LEFT_DASHES RIGHT_DASHES
  printf -v LEFT_DASHES '%*s' "$NUMBER_OF_LEFT_DASHES" ''
  printf -v RIGHT_DASHES '%*s' "$NUMBER_OF_RIGHT_DASHES" ''

  # 21 leading spaces : the date column (19) plus the two spaces separating it from the inlet column
  local header
  printf -v header '%21s' ''
  header+="${LEFT_DASHES// /-}${TITLE}${RIGHT_DASHES// /-}"$'\n'
  header+='    Date & time      Inlet '

  # Each CPU label is right-aligned in the shared column width, so that a label wider than a reading
  # widens every column consistently instead of shifting the ones on its right
  local CPU_LABEL
  for CPU_LABEL in "${CPU_LABELS[@]}"; do
    header+=$(printf ' %*s ' "$LOCAL_CPU_COLUMN_CONTENT_WIDTH" "$CPU_LABEL")
  done

  # Padded to the very widths the rows print into, so that a heading keeps sitting above its own values
  # instead of the rows overflowing a header that reserved less
  local FAN_CONTROL_PROFILE_HEADING COOLING_RESPONSE_HEADING
  center_column_heading FAN_CONTROL_PROFILE_HEADING 'Active fan speed profile' "$TABLE_FAN_CONTROL_PROFILE_COLUMN_WIDTH"
  center_column_heading COOLING_RESPONSE_HEADING 'Third-party PCIe card Dell default cooling response' "$COOLING_RESPONSE_COLUMN_WIDTH"

  header+=" Exhaust  ${FAN_CONTROL_PROFILE_HEADING}  ${COOLING_RESPONSE_HEADING}  Comment"
  printf "%s" "$header"
}

function print_temperature_array_line() {
  local -r LOCAL_CPU_COLUMN_CONTENT_WIDTH="$1"
  local -r LOCAL_INLET_TEMPERATURE="$2"
  local -r LOCAL_CPUS_TEMPERATURES="$3"
  local -r LOCAL_EXHAUST_TEMPERATURE="$4"
  local -r LOCAL_CURRENT_FAN_CONTROL_PROFILE="$5"
  local -r LOCAL_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS="$6"
  local -r LOCAL_COMMENT="$7"

  # Creating an array from the string
  local -r CPUs_temperatures_array=(${LOCAL_CPUS_TEMPERATURES//;/ })
  # Declared like its neighbours : functions.sh is sourced into the entry point, so a loop counter left
  # undeclared here lands in the container's main shell, and this function runs on every cycle
  local temperature

  local TIMESTAMP FORMATTED_TEMPERATURE
  set_log_timestamp TIMESTAMP
  FORMATTED_TEMPERATURE=$(format_temperature_for_display "$LOCAL_INLET_TEMPERATURE")
  printf "%19s  %s°C " "$TIMESTAMP" "$FORMATTED_TEMPERATURE"
  # Itération sur les températures dans le tableau.
  # Only the number is padded, never the assembled "NNN°C" string : the container runs in the POSIX
  # locale (the Dockerfile sets no LANG), where "°" is two bytes, so printf-padding the whole cell would
  # count it as two columns and shift the table by one character per CPU
  for temperature in "${CPUs_temperatures_array[@]}"; do
    printf " %s°C " "$(format_temperature_for_display "$temperature" "$((LOCAL_CPU_COLUMN_CONTENT_WIDTH - 2))")"
  done

  # Exhaust goes through the same formatter as the other three temperature columns, so that a reading
  # that failed on this cycle shows the "-" placeholder rather than an empty column reading as "°C"
  printf " %5s°C  %*s  %*s  %s\n" "$(format_temperature_for_display "$LOCAL_EXHAUST_TEMPERATURE")" "$TABLE_FAN_CONTROL_PROFILE_COLUMN_WIDTH" "$LOCAL_CURRENT_FAN_CONTROL_PROFILE" "$COOLING_RESPONSE_COLUMN_WIDTH" "$LOCAL_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS" "$LOCAL_COMMENT"
}

# Stamp the current local time into the named variable, in the format every logged line starts with.
# Usage : set_log_timestamp TIMESTAMP
#
# bash's own strftime rather than $(date ...). A command substitution expanded alongside another one in
# the same statement is what lets a SIGTERM delivered at that instant leave bash's parser mid-expansion:
# the trap command string is then parsed with that state still open, fails, and graceful_exit never runs,
# leaving the fans on the user's static speed (issue #188). It also saves a fork per logged line
function set_log_timestamp() {
  printf -v "$1" '%(%d-%m-%Y %T)T' -1
}

# Formats a temperature reading as a right-aligned decimal number of the given width (3 by default).
# Falls back to "-" instead of letting printf %d crash when the reading is empty, a placeholder ("-"),
# or has a leading zero that would otherwise be misinterpreted as an invalid octal number (e.g. "09").
# Sub-zero readings are values in their own right, not invalid ones, so they keep their sign
# Usage : format_temperature_for_display "$VALUE" [$WIDTH]
function format_temperature_for_display() {
  local -r VALUE="$1"
  local -r WIDTH="${2:-3}"
  if is_temperature_reading_valid "$VALUE"; then
    printf '%*d' "$WIDTH" "$(normalize_decimal_value "$VALUE")"
  else
    printf '%*s' "$WIDTH" "-"
  fi
}

# Returns 0 (true) if the given temperature reading is usable, i.e. an integer.
# A missing sensor, a transient IPMI parsing glitch or an "ns"/"Disabled" sensor all yield something
# that isn't.
#
# A sub-zero reading is a value in its own right rather than an unusable one : Dell rates the PowerEdge
# line down to -5°C, so an unheated room produces one in normal operation
function is_temperature_reading_valid() {
  [[ "$1" =~ ^-?[0-9]+$ ]]
}

# Checks whether any of the detected CPUs needs the Dell default fan control profile.
# Returns 0 (true) if at least one does, and fills OVERHEATING_CPUS_AND_TEMPERATURES with the
# "label temperature" pairs build_fan_control_fallback_comment() expects, so the log line can tell the
# user which CPU triggered the switch and whether it was too hot or simply unreadable.
#
# Every detected CPU is evaluated, not just the first two : on a 4-socket server (R930, R830...) CPU 3
# and CPU 4 used to be read by nobody, so they could cross the threshold while the controller happily
# kept the user's low fan speed running.
#
# Like the per-CPU checks it replaces, it deliberately returns true both when a CPU is genuinely too hot
# and when its reading is unusable, so an unverifiable temperature still falls back to Dell's profile
# instead of crashing (bash's "-gt" throws "unary operator expected" on empty/non-numeric input) or
# silently running the low user fan speed on unverified data. The same goes for an unusable threshold,
# the comparison having two operands and only one of them having been guarded until now
function is_any_CPU_overheating() {
  OVERHEATING_CPUS_AND_TEMPERATURES=()

  # The threshold is the comparison's other operand, and "-gt" fails the same way on either side : on a
  # value it cannot parse the test returns non-zero, which reads as "not overheating" -- the one answer
  # that leaves a hot CPU running on the user's low static fan speed. It is therefore checked like the
  # readings are, and normalized once here rather than per CPU, an empty result meaning "unusable".
  # Dell_iDRAC_fan_controller.sh resolves and validates the threshold before the monitoring loop starts
  # and then makes it readonly, so this is not reachable from the container : it is what keeps the answer
  # safe on its own terms instead of by depending on a check living in another file (see issue #218)
  local NORMALIZED_CPU_TEMPERATURE_THRESHOLD=""
  if is_temperature_reading_valid "$CPU_TEMPERATURE_THRESHOLD"; then
    NORMALIZED_CPU_TEMPERATURE_THRESHOLD=$(normalize_decimal_value "$CPU_TEMPERATURE_THRESHOLD")
  fi

  local INDEX CPU_TEMPERATURE
  for INDEX in "${!DETECTED_CPU_TEMPERATURES[@]}"; do
    CPU_TEMPERATURE="${DETECTED_CPU_TEMPERATURES[INDEX]}"
    if [ -z "$NORMALIZED_CPU_TEMPERATURE_THRESHOLD" ] || ! is_temperature_reading_valid "$CPU_TEMPERATURE" || [ "$(normalize_decimal_value "$CPU_TEMPERATURE")" -gt "$NORMALIZED_CPU_TEMPERATURE_THRESHOLD" ]; then
      # The label is taken from the table's own labels rather than rebuilt here, so that the CPU named
      # in the comment is always the one whose column shows the reading that triggered it. It falls back
      # to the position rather than to an empty string, so that a comment naming no CPU at all can never
      # be the thing a user has to diagnose an overheat with
      OVERHEATING_CPUS_AND_TEMPERATURES+=("${DETECTED_CPU_LABELS[INDEX]:-CPU $((INDEX + 1))}" "$CPU_TEMPERATURE")
    fi
  done

  # Not being able to read a single CPU means nothing can be verified, so fail safe rather than trust
  # the absence of data. Reached on every cycle in monitoring only mode on a server reporting no CPU at
  # all -- where it costs nothing, that mode driving no fan -- and by a caller getting here before any
  # detection ran. Every other mode refuses to start on such a server rather than arrive here
  if (( ${#DETECTED_CPU_TEMPERATURES[@]} == 0 )); then
    return 0
  fi

  (( ${#OVERHEATING_CPUS_AND_TEMPERATURES[@]} > 0 ))
}

# Join the given items into an enumeration : "CPU 1", "CPU 1 and CPU 2", "CPU 1, CPU 2 and CPU 3"...
# Usage : join_with_and $ITEM...
function join_with_and() {
  local result=""
  local i

  for (( i = 1; i <= $#; i++ )); do
    if (( i == 1 )); then
      result="${!i}"
    elif (( i == $# )); then
      result+=" and ${!i}"
    else
      result+=", ${!i}"
    fi
  done

  echo "$result"
}

# The clause a comment ends on, naming what the controller did about the fans.
# Usage : fan_control_comment_clause "$WHAT_THE_CONTROLLER_ASKED_FOR"
#
# The comment column explains a profile change, and on a server that refused fan control there is none
# to explain : the fans have been Dell's own since before the container started and no command of its
# own reached them. The reason the profile would have changed is still worth printing -- a hot CPU is
# news whoever drives the fans -- so only the half of the sentence that names an applied profile is
# replaced, rather than the whole comment being dropped
function fan_control_comment_clause() {
  local -r APPLIED_CLAUSE="$1"

  if has_the_server_refused_fan_control; then
    echo "and this server refused fan control, so its fans stay Dell's own to drive"
    return
  fi

  echo "$APPLIED_CLAUSE"
}

# Build the comment explaining why the Dell default fan control profile was applied.
# Usage : build_fan_control_fallback_comment $CPU_NAME $CPU_TEMPERATURE [$CPU_NAME $CPU_TEMPERATURE]...
#
# is_any_CPU_overheating() deliberately reports both a CPU that is genuinely too hot and one whose
# reading is unusable, so an unverifiable temperature still falls back to Dell's profile.
# The comment has to tell the two apart : reporting "temperature is too high" on a reading that was
# never obtained sends the user chasing a cooling problem instead of the sensor problem they have
function build_fan_control_fallback_comment() {
  local -a too_hot=()
  local -a unreadable=()
  local -a reasons=()

  while (( $# >= 2 )); do
    if is_temperature_reading_valid "$2"; then
      too_hot+=("$1")
    else
      unreadable+=("$1")
    fi
    shift 2
  done

  if (( ${#too_hot[@]} == 1 )); then
    reasons+=("${too_hot[0]} temperature is too high")
  elif (( ${#too_hot[@]} > 1 )); then
    reasons+=("$(join_with_and "${too_hot[@]}") temperatures are too high")
  fi

  if (( ${#unreadable[@]} == 1 )); then
    reasons+=("${unreadable[0]} temperature could not be read")
  elif (( ${#unreadable[@]} > 1 )); then
    reasons+=("$(join_with_and "${unreadable[@]}") temperatures could not be read")
  fi

  local FAN_CONTROL_CLAUSE
  FAN_CONTROL_CLAUSE=$(fan_control_comment_clause "Dell default dynamic fan control profile applied for safety")

  echo "$(join_with_and "${reasons[@]}"), $FAN_CONTROL_CLAUSE"
}

# Stop the container on an invalid configuration parameter, with everything needed to fix it
# Usage : print_configuration_error_and_exit "$PARAMETER_NAME" "$VALUE" "$EXPECTED" ["$WHERE_TO_FIX_IT" ["$RESTARTING_WOULD_MEET_THE_SAME_REFUSAL"]]
#
# Refusing to start is the point : a malformed parameter fails silently once the container is running,
# so the only outcome that can't be mistaken for normal operation is not running at all. But refusing
# to start is only useful if the reason survives a "docker logs" scroll, hence the block form rather
# than one line among the startup output -- the user has to be able to see, without reading the source,
# which parameter is wrong, what it currently is, what is accepted, and where to change it
#
# The closing sentence is overridable because not every configuration mistake is made in the same
# place : almost all of them are environment variables, but exposing the host's IPMI device is a
# "--device" argument, and sending that user to "-e" would be worse than saying nothing. It defaults
# to the environment variable wording, which is what every parameter validator wants
#
# The last argument says whether the very same refusal is what the next start would meet. It is true
# of everything decided from a value's own content -- the value is read identically on every start --
# and the block says so, because a restart policy otherwise turns one refusal into an unbroken run of
# them : that is what issue #326 was reported as, a container seen flapping rather than a mistake seen
# in a variable, by a user with no way to tell a permanent refusal from a transient failure worth
# waiting out. It defaults to true because every parameter validator is that case. It is false for the
# refusals that come from asking hardware, an iDRAC that did not answer this time being able to answer
# the next : telling that user restarting will not help would be worse than saying nothing, the
# restart policy being exactly what recovers them
function print_configuration_error_and_exit() {
  local -r PARAMETER_NAME="$1"
  local -r VALUE="$2"
  local -r EXPECTED="$3"
  local -r WHERE_TO_FIX_IT="${4:-Fix it in the \"-e\" arguments of your \"docker run\" command, or in the \"environment\"
section of your docker-compose.yml, then start the container again.}"
  local -r RESTARTING_WOULD_MEET_THE_SAME_REFUSAL="${5:-true}"

  # Assembled whole, then written once. The block is a unit -- half of it is worse than none, the
  # parameter being named without what is accepted, or what is accepted without where to fix it -- and
  # printing it piecemeal made it interruptible : a SIGTERM landing between two of the printfs cut it
  # off mid-block, and the tail went through a pipeline, i.e. a subshell, which is exactly where a
  # signal is most likely to land. The test suite reproduced it by design, awaiting the first line and
  # stopping the controller as soon as it appeared. Docker sends the same signal to the same process
  local BLOCK PIECE
  printf -v BLOCK "\n/!\\ Error /!\\ Invalid configuration, the container will not start.\n\n"
  printf -v PIECE "  Parameter : %s\n" "$PARAMETER_NAME"
  BLOCK+="$PIECE"
  printf -v PIECE "  Value     : \"%s\"\n" "$VALUE"
  BLOCK+="$PIECE"
  printf -v PIECE "  Expected  : %s\n\n" "$EXPECTED"
  BLOCK+="$PIECE"
  # No exit status could carry this instead : "always" and "unless-stopped" restart on the policy
  # rather than on the code, and those are the two the README's own examples recommend. Saying it is
  # therefore the only thing that can spare the user the wait
  if [ "$RESTARTING_WOULD_MEET_THE_SAME_REFUSAL" == "true" ]; then
    printf -v PIECE "  Restarting will not help : this is read the same way on every start, so a container under\n  an \"always\", \"unless-stopped\" or \"on-failure\" restart policy stops here again on every\n  attempt, until the configuration itself is corrected.\n\n"
    BLOCK+="$PIECE"
  fi

  # Indented line by line so a closing sentence written across several lines keeps the block's margin.
  # Fed by a here-string rather than a pipe, a pipeline being the subshell this used to lose
  local LINE
  while IFS= read -r LINE; do
    printf -v PIECE "  %s\n" "$LINE"
    BLOCK+="$PIECE"
  done <<< "$WHERE_TO_FIX_IT"

  printf "%s\n" "$BLOCK" >&2

  exit 1
}

# Each of these terminates its own line. print_error() and print_warning() used not to, which was
# deliberate only for the " Exiting." suffix of their _and_exit() variants : every standalone call left
# the message unterminated, so it fused with the next thing printed. The realistic case is an iDRAC
# rejecting the fan speed command, which errors on every cycle and prefixes every table row with ~180
# characters, moving the timestamp out of column 1 and breaking any log parser keyed on it. The exit
# variants print their line in full rather than depend on that omission, and keep their exact wording
function print_error() {
  local -r ERROR_MESSAGE="$1"
  printf "/!\ Error /!\ %s.\n" "$ERROR_MESSAGE" >&2
}

function print_error_and_exit() {
  local -r ERROR_MESSAGE="$1"
  printf "/!\ Error /!\ %s. Exiting.\n" "$ERROR_MESSAGE" >&2
  exit 1
}

function print_warning() {
  local -r WARNING_MESSAGE="$1"
  printf "/!\ Warning /!\ %s.\n" "$WARNING_MESSAGE"
}

function print_warning_and_exit() {
  local -r WARNING_MESSAGE="$1"
  printf "/!\ Warning /!\ %s. Exiting.\n" "$WARNING_MESSAGE"
  exit 0
}
