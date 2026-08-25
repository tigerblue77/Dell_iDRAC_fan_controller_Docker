#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# Enable strict bash mode to stop the script if an uninitialized variable is used, if a command fails, or if a command with a pipe fails
# Not working in some setups : https://github.com/tigerblue77/Dell_iDRAC_fan_controller/issues/48
# set -euo pipefail

source functions.sh
source constants.sh

# Dell's "third-party PCIe card default cooling response" is an OEM command that not every server
# takes, and the monitoring loop below finds out by sending it and reading the answer rather than by
# guessing from the model name
IS_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_SUPPORTED=true

# Whether this container is driving the third-party PCIe card cooling response over Redfish rather than
# over IPMI. Read by graceful_exit(), which has to hand it back over the transport that took it : on a
# 14th generation server the IPMI command is the one the BMC already answered "invalid command" to, so
# sending it on the way out would undo nothing
IS_THE_COOLING_RESPONSE_DRIVEN_OVER_REDFISH=false

# Whether the Redfish cooling response has stopped being attempted, and how many attempts it took. A
# refusal describing a moment the iDRAC was having -- busy, queued, unreachable -- is retried on later
# cycles up to MAXIMUM_REDFISH_ATTEMPTS, where a refusal about the request or the credentials
# settles it on the first answer (#376)
REDFISH_COOLING_RESPONSE_SETTLED=false
REDFISH_ATTEMPTS=0
# Which slots still need changing, and whether that has been worked out yet. Carried between cycles
# because the errand may read the slots back on one and send the PATCH on the next, on an iDRAC slow
# enough that doing both would run the cycle past its CHECK_INTERVAL (#444)
REDFISH_ATTRIBUTES_TO_WRITE=""
IS_THE_REDFISH_WRITE_PLANNED=false

# Whether the IPMI command for the cooling response has been found gone, which is what makes this a
# Redfish question at all. Set the moment that verdict is reached and BEFORE anything is asked over
# HTTPS, because a probe that could not reach the iDRAC is not an answer about the server and has to
# leave a later cycle able to ask again (#376)
IS_THE_COOLING_RESPONSE_A_REDFISH_QUESTION=false

# The fan control commands themselves are found out the same way, and for the same reason : Dell removed
# them from the 14th generation on, an iDRAC 9 refusing them from firmware 3.34.34.34 onwards, and no
# model name says which firmware a server is running. Without this the controller kept sending them and
# reporting the same two failures every cycle, for the life of the container.
#
# The second flag is what keeps the first one safe : a refusal only settles anything while nothing has
# ever been accepted. Both are declared here, before the trap below, because graceful_exit reads them
IS_FAN_CONTROL_SUPPORTED=true
HAS_FAN_CONTROL_EVER_BEEN_ACCEPTED=false

# Whether the healthcheck's heartbeat has already been reported unwritable. It is said once and never
# again : it costs the supervision that file adds, not the monitoring (issue #440)
HAS_THE_HEARTBEAT_FAILURE_BEEN_REPORTED=false

# Whether graceful_exit() has already begun. The stop signal can arrive more than once -- a second
# Ctrl-C, and supervisor.sh deliberately asking twice because the first request is sometimes lost
# (#443) -- and bash runs the handler again on each one. Declared here, before the trap below, because
# that is what reads it
HAS_THE_GRACEFUL_EXIT_STARTED=false

# Catch the stop signals Docker sends so graceful_exit runs before the process ends
trap 'graceful_exit' SIGINT SIGQUIT SIGTERM

# Prepare, format and define initial variables

# readonly DELL_FRESH_AIR_COMPLIANCE=45

# The boolean parameters are dispatched by running their value as a command ("if $MONITORING_ONLY_MODE"),
# an idiom that is only safe once the value is known to be one of the two literals it expects : anything
# else is read as false without a word, or run as whatever command it happens to name. Validate them
# first, before the first IPMI command and before anything reads them. MONITORING_ONLY_MODE especially,
# since it decides how the check interval just below is bounded and what graceful_exit does on the way out
validate_boolean_parameter "MONITORING_ONLY_MODE" "$MONITORING_ONLY_MODE"
validate_boolean_parameter "DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE" "$DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE"
validate_boolean_parameter "KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT" "$KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT"

# FAN_SPEED is unchecked text until here and fails silently rather than loudly when malformed : it goes
# through printf's base detection and converts to 0x00, the documented Dell command for 0% fan duty.
# Only one stderr line at startup says so, and every temperature table row afterwards keeps naming the
# speed the user asked for while the fans sit at zero. Refuse to start rather than fail silently
validate_fan_speed_parameter "FAN_SPEED" "$FAN_SPEED"
# CHECK_INTERVAL paces the whole monitoring loop and is handed straight to sleep, whose exit status the
# loop never looks at. It is also the controller's reaction time, the fans being pinned between two
# checks, so an excessively long one is refused as well. The monitoring only mode is passed along
# because it decides whether that reaction time exists at all
validate_check_interval_parameter "CHECK_INTERVAL" "$CHECK_INTERVAL" "$MONITORING_ONLY_MODE"

# Escalation for an iDRAC that stops answering, expressed either as a duration (the default) or as a
# raw number of cycles
validate_IPMI_unreachable_duration_parameter "MAXIMUM_IPMI_UNREACHABLE_DURATION" "$MAXIMUM_IPMI_UNREACHABLE_DURATION"
validate_maximum_consecutive_IPMI_failures_parameter "MAXIMUM_CONSECUTIVE_IPMI_FAILURES" "$MAXIMUM_CONSECUTIVE_IPMI_FAILURES"
readonly MAXIMUM_IPMI_UNREACHABLE_DURATION
readonly MAXIMUM_CONSECUTIVE_IPMI_FAILURES

# CHECK_INTERVAL is allowed a unit suffix, so it is turned into seconds once : the escalation counts
# cycles, and the duration the user configured has to be expressed in those same cycles
CHECK_INTERVAL_IN_SECONDS=$(convert_duration_to_seconds "$CHECK_INTERVAL")
readonly CHECK_INTERVAL_IN_SECONDS
resolve_IPMI_failures_before_exit "$MAXIMUM_CONSECUTIVE_IPMI_FAILURES" "$MAXIMUM_IPMI_UNREACHABLE_DURATION" "$CHECK_INTERVAL_IN_SECONDS"
readonly IPMI_FAILURES_BEFORE_EXIT
warn_if_the_escalation_exits_on_the_first_failure "$MAXIMUM_CONSECUTIVE_IPMI_FAILURES" "$MAXIMUM_IPMI_UNREACHABLE_DURATION" "$IPMI_FAILURES_BEFORE_EXIT"

# Express FAN_SPEED in both notations, whichever one the user gave it in
convert_fan_speed_parameter "$FAN_SPEED"
readonly DECIMAL_FAN_SPEED="$DECIMAL_SPEED"
readonly HEXADECIMAL_FAN_SPEED="$HEXADECIMAL_SPEED"

# In local mode, the container runs on the target server itself. Two things depend on that : lm-sensors
# can only describe the controlled server's CPUs in that mode, and the server can never be observed
# powered off while the container is running, so that check is only meaningful in network mode
if [[ "$IDRAC_HOST" == "local" ]]; then
  readonly NETWORK_MODE=false
else
  readonly NETWORK_MODE=true
fi

# Resolve where the CPU temperatures will be read from. The iDRAC is the source in every case where it
# can be one; lm-sensors only ever takes over on an iDRAC that drives the fans but reports no CPU
# temperature at all, or when the user names it explicitly
# (see https://github.com/tigerblue77/Dell_iDRAC_fan_controller_Docker/issues/216)
resolve_CPU_temperature_source "$CPU_TEMPERATURE_SOURCE" "$NETWORK_MODE"
readonly CPU_TEMPERATURE_SOURCE

# Resolve the CPU temperature threshold. "auto" (the default) asks the CPUs themselves, through lm-sensors,
# for the "high" temperature defined by their manufacturer : that value describes the actual hardware being
# cooled, unlike a single fixed threshold shared by every CPU model
# (see https://github.com/tigerblue77/Dell_iDRAC_fan_controller_Docker/issues/26)
#
# /!\ This resolution must stay ahead of everything that reads CPU_TEMPERATURE_THRESHOLD as a number /!\
# It is deliberately placed here, right after the FAN_SPEED conversion, so that any later validation sees
# an already-resolved integer rather than the literal string "auto"

# Normalize the raw value first. Docker's --env-file parser keeps the trailing space of a
# "CPU_TEMPERATURE_THRESHOLD=50 " line, and copying the documented placeholder can carry quotes along.
# Bash's own "-gt" used to tolerate both, so rejecting them here would turn a previously working
# configuration into a startup failure, which a restart policy then turns into a crash loop
CPU_TEMPERATURE_THRESHOLD="${CPU_TEMPERATURE_THRESHOLD//[[:space:]]/}"
CPU_TEMPERATURE_THRESHOLD="${CPU_TEMPERATURE_THRESHOLD#[\"\']}"
CPU_TEMPERATURE_THRESHOLD="${CPU_TEMPERATURE_THRESHOLD%[\"\']}"
CPU_TEMPERATURE_THRESHOLD="${CPU_TEMPERATURE_THRESHOLD#+}"
CPU_TEMPERATURE_THRESHOLD="${CPU_TEMPERATURE_THRESHOLD:-auto}"
CPU_TEMPERATURE_THRESHOLD_SOURCE=""
if [[ "${CPU_TEMPERATURE_THRESHOLD,,}" == "auto" ]]; then
  if $NETWORK_MODE; then
    # lm-sensors can only read the CPUs of the machine this container runs on. In network mode that machine
    # isn't the server whose fans are controlled, so its "high" temperature would describe the wrong hardware
    CPU_TEMPERATURE_THRESHOLD=$FALLBACK_CPU_TEMPERATURE_THRESHOLD
    CPU_TEMPERATURE_THRESHOLD_SOURCE=" (fallback value, automatic detection is only available in local mode)"
  else
    DETECTED_CPU_TEMPERATURE_THRESHOLD=$(retrieve_CPU_high_temperature_from_lm_sensors)
    if [ -n "$DETECTED_CPU_TEMPERATURE_THRESHOLD" ]; then
      CPU_TEMPERATURE_THRESHOLD=$DETECTED_CPU_TEMPERATURE_THRESHOLD
      CPU_TEMPERATURE_THRESHOLD_SOURCE=" (automatically detected, \"high\" temperature reported by lm-sensors)"
    else
      CPU_TEMPERATURE_THRESHOLD=$FALLBACK_CPU_TEMPERATURE_THRESHOLD
      CPU_TEMPERATURE_THRESHOLD_SOURCE=" (fallback value, no CPU \"high\" temperature could be read from lm-sensors)"
    fi
  fi
elif [[ "$CPU_TEMPERATURE_THRESHOLD" =~ ^[0-9]{1,3}$ ]]; then
  # Drop any leading zero so the value isn't later interpreted as an octal number (e.g. "050" as 40°C).
  # The digit count is bounded above so that a very long number can't silently wrap around 64 bits here
  CPU_TEMPERATURE_THRESHOLD=$((10#$CPU_TEMPERATURE_THRESHOLD))
  # Hold a user-supplied value to the same plausibility window as an automatically detected one. A typo
  # such as "500" (or a Fahrenheit value) is otherwise accepted silently and no CPU ever reaches it, so
  # the Dell default profile is never restored and the fans stay low for the life of the container.
  #
  # A value above the maximum is not a stricter setting but the absence of one, and the refusal says so
  # rather than only stating a window : no PowerEdge CPU reaches 125°C, the server's own thermal
  # protection powering the machine off first, so such a threshold could never be crossed and the
  # fallback it governs could never fire. The container would print a threshold at startup while
  # supervising nothing, which is what issue #326 turned out to be about. Being unable to disable that
  # fallback is the intended behaviour, so the refusal deliberately offers no value that would.
  # The README documents the same range and unit, and
  # test_the_readme_documents_the_plausible_temperature_threshold_window() keeps the two from drifting
  if [ "$CPU_TEMPERATURE_THRESHOLD" -lt "$MINIMUM_PLAUSIBLE_CPU_TEMPERATURE_THRESHOLD" ] || [ "$CPU_TEMPERATURE_THRESHOLD" -gt "$MAXIMUM_PLAUSIBLE_CPU_TEMPERATURE_THRESHOLD" ]; then
    print_configuration_error_and_exit "CPU_TEMPERATURE_THRESHOLD" "${CPU_TEMPERATURE_THRESHOLD}°C" "a temperature in degrees Celsius between ${MINIMUM_PLAUSIBLE_CPU_TEMPERATURE_THRESHOLD} and ${MAXIMUM_PLAUSIBLE_CPU_TEMPERATURE_THRESHOLD}, no CPU throttling below the first nor tolerating more than the second. Above the maximum is not a stricter setting but the absence of one : no PowerEdge CPU reaches it, the server's own thermal protection powering the machine off first, so the threshold could never be crossed and the overheat fallback it governs could never fire -- this container would print a threshold at startup while supervising nothing. That fallback is not meant to be switched off, so set the temperature your CPUs should not exceed, or \"auto\" to take the \"high\" value they report themselves"
  fi
else
  # Reject an unusable threshold right away : every temperature comparison would fail against it, which
  # silently keeps the user's (low) fan speed applied instead of ever triggering the Dell default profile
  print_configuration_error_and_exit "CPU_TEMPERATURE_THRESHOLD" "$CPU_TEMPERATURE_THRESHOLD" "a positive integer number of degrees Celsius, or \"auto\" to take the CPUs' own \"high\" temperature as reported by lm-sensors"
fi
readonly CPU_TEMPERATURE_THRESHOLD

set_iDRAC_login_string "$IDRAC_HOST" "$IDRAC_USERNAME" "$IDRAC_PASSWORD"

get_Dell_server_model

if [[ ! $SERVER_MANUFACTURER == "DELL" ]]; then
  print_error_and_exit "Your server isn't a Dell product"
fi

# Asked once the server is known to be a Dell, next to the model it belongs with, and never treated as a
# reason not to start : an iDRAC that will not say which firmware it runs still drives fans
get_iDRAC_firmware_version

# CPU temperature indexes are gone: retrieve_temperatures() now locates each CPU by its IPMI entity ID
# instead of counting values, which no longer depends on the server generation

# Log main informations
echo "Server model: $SERVER_MANUFACTURER $SERVER_MODEL"
echo "iDRAC/IPMI host: $IDRAC_HOST"
echo "iDRAC firmware version: $IDRAC_FIRMWARE_VERSION"

# Log the fan speed objective, CPU temperature threshold and check interval
echo "Fan speed objective: $DECIMAL_FAN_SPEED%"
echo "CPU temperature threshold: ${CPU_TEMPERATURE_THRESHOLD}°C${CPU_TEMPERATURE_THRESHOLD_SOURCE}"
echo "CPU temperature source: $CPU_TEMPERATURE_SOURCE_DESCRIPTION"
# The unit is only appended when the value doesn't already carry one, "90s" and "5m" being accepted
# forms that would otherwise be logged as "90ss" and "5ms"
if [[ "$CHECK_INTERVAL" =~ ^[0-9]+$ ]]; then
  echo "Check interval: ${CHECK_INTERVAL}s"
else
  echo "Check interval: $CHECK_INTERVAL"
fi
echo "iDRAC unreachable escalation: $(describe_IPMI_unreachable_escalation "$MAXIMUM_CONSECUTIVE_IPMI_FAILURES" "$MAXIMUM_IPMI_UNREACHABLE_DURATION" "$IPMI_FAILURES_BEFORE_EXIT")"
if "$MONITORING_ONLY_MODE"; then
  echo "Monitoring only mode: Enabled (no fan control profile will be applied, temperatures will only be logged)"
else
  echo "Monitoring only mode: Disabled"
fi
echo ""

TABLE_HEADER_PRINT_COUNTER=$TABLE_HEADER_PRINT_INTERVAL
# Set the flag used to check if the active fan control profile has changed
IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED=true
# The comment column explains a profile CHANGE, and the first cycle changes nothing:
# it establishes the profile. Without this, whichever branch the first cycle takes
# stays silent -- and since the flag above starts at true, the silent one is the
# fail-safe branch, so a server whose sensors could not be read has its fans handed
# to Dell's profile with no explanation, which is exactly when the user needs one.
# No starting value of that flag fixes it: setting it the other way just moves the
# silence onto the healthy path
IS_FIRST_MONITORING_CYCLE=true
# Tracks whether the previous cycle was skipped, so temperatures can be refreshed the moment the
# server comes back instead of reusing data read before/during the outage. Set by both reasons a
# cycle is skipped, the readings being equally stale either way
IS_TARGET_SERVER_UNAVAILABLE=false
# Counts only the cycles that failed to REACH the iDRAC. A powered-off chassis is a state we observed
# correctly, so it never counts towards the escalation
CONSECUTIVE_IPMI_FAILURES=0
# Tracks whether that outage was the server actually being powered off, as opposed to an iDRAC we
# could not reach. Only the first can have changed the CPUs, and only it may open the removal window
IS_TARGET_SERVER_POWERED_OFF=false

# Start timer in background
sleep "$CHECK_INTERVAL" &
SLEEP_PROCESS_PID=$!

# Detect the CPU temperature sensors before entering the monitoring loop, the table header being built
# from them. The loop then keeps watching for CPUs showing up later, so a partial set read here is not
# final.
WAITING_FOR_TEMPERATURE_SENSORS_CYCLES=0
# The target server may be powered off when the container starts. No sensor can be read then, so keep
# waiting instead of giving up : this container is expected to outlive its target server being powered
# off, and exiting there would just make it restart in a loop.
# A server that does answer is a different matter, and is handled inside the loop : it has CPUs, so
# reporting none of them is a fault to report rather than a state to wait out
while true; do
  # Either outcome get_server_power_state reports as non-zero -- powered off, or an iDRAC that cannot be
  # reached at all -- means no sensor can be read yet, which is what this loop waits on. They are only
  # worth telling apart once the monitoring loop is running and a profile is actually being held
  IS_TARGET_SERVER_ANSWERING=true
  if $NETWORK_MODE; then
    get_server_power_state
    TARGET_SERVER_POWER_STATE=$?

    if [ $TARGET_SERVER_POWER_STATE -ne 0 ]; then
      IS_TARGET_SERVER_ANSWERING=false

      # This loop treats both non-zero outcomes alike for what it waits on, but not for the escalation :
      # a server left switched off must be waited out however long it takes, while an iDRAC that never
      # answers is usually a wrong host or wrong credentials, which waiting cannot fix
      if [ $TARGET_SERVER_POWER_STATE -eq 2 ]; then
        (( CONSECUTIVE_IPMI_FAILURES++ ))
        exit_if_iDRAC_unreachable_for_too_long
      else
        CONSECUTIVE_IPMI_FAILURES=0
      fi
    else
      CONSECUTIVE_IPMI_FAILURES=0
    fi
  fi

  if $IS_TARGET_SERVER_ANSWERING; then
    # Kept for the first retrieve_temperatures() below, so that detecting the CPUs and taking their
    # first readings cost a single IPMI round-trip and describe the very same instant
    SDR_TEMPERATURE_DATA=$(retrieve_temperature_data)
    detect_CPU_temperature_sensors "$SDR_TEMPERATURE_DATA"
    if [ ${#DETECTED_CPU_ENTITY_IDS[@]} -gt 0 ]; then
      break
    fi

    # An empty answer is not an answer : ipmitool returned no sensor line at all, which a busy BMC, a
    # partial response or an iDRAC still coming up all produce, and which says nothing about what the
    # server has. It belongs with "not answering yet" below, not with the verdict underneath : the
    # refusal is about a server that listed its sensors and had no CPU among them
    if [ -z "$SDR_TEMPERATURE_DATA" ]; then
      # Verified rather than announced, for the same reason as the refusal further down : this line was
      # printed on every header interval for the life of a container whose BMC may well have refused it
      WERE_THE_FANS_HANDED_BACK=true
      apply_Dell_default_fan_control_profile || WERE_THE_FANS_HANDED_BACK=false

      # Repeated on the rhythm the monitoring loop reprints its table header rather than once, so a
      # container waiting on an iDRAC that never returns anything cannot be mistaken for a hung one
      if (( WAITING_FOR_TEMPERATURE_SENSORS_CYCLES % TABLE_HEADER_PRINT_INTERVAL == 0 )); then
        set_log_timestamp TIMESTAMP
        if "$WERE_THE_FANS_HANDED_BACK"; then
          printf "%19s  No temperature sensor could be read at all, Dell default dynamic fan control profile applied for safety while waiting...\n" "$TIMESTAMP"
        else
          printf "%19s  No temperature sensor could be read at all, and this server refused to be put back on Dell default dynamic fan control profile. Still waiting...\n" "$TIMESTAMP"
        fi
      fi
      ((WAITING_FOR_TEMPERATURE_SENSORS_CYCLES++))

      wait $SLEEP_PROCESS_PID

      # Start timer in background for next attempt
      sleep "$CHECK_INTERVAL" &
      SLEEP_PROCESS_PID=$!
      continue
    fi

    # The server answers, and answers that it has no readable CPU temperature sensor. Every PowerEdge
    # has at least one CPU, so this is not a state to sit and wait out : an iDRAC that exposes no
    # processor entity does so on every check, not on this one.
    #
    # That very conclusion is what makes the fallback safe to engage on this single check rather than on
    # several agreeing ones : the answer will not change. In local mode this machine is the server, so
    # its own CPUs can be read instead of the ones its iDRAC refuses to report, which is the whole point
    # of issue #216. Tried before giving up, and only ever reached once the iDRAC has failed to supply
    # the one thing the controller cannot do without
    if engage_lm_sensors_CPU_temperature_fallback; then
      SDR_TEMPERATURE_DATA=$(retrieve_temperature_data)
      detect_CPU_temperature_sensors "$SDR_TEMPERATURE_DATA"
      if [ ${#DETECTED_CPU_ENTITY_IDS[@]} -gt 0 ]; then
        break
      fi
    fi

    # Neither source has a CPU to offer.
    #
    # Monitoring only mode is the exception : it drives no fan, so a CPU it cannot read costs it a
    # column and nothing else, while the chassis sensors it can read are the whole reason it was
    # started. Refusing there would take away the one mode that still has something to do -- and it is
    # also the mode the refusal below tells everyone else to fall back on, which it cannot do if that
    # mode refuses too. Checked here, once both sources have failed, so that lm-sensors still gets to
    # fill the CPU columns of a local mode container rather than being skipped over
    if "$MONITORING_ONLY_MODE"; then
      break
    fi

    # Retrying forever would leave a container that looks alive and supervises nothing.
    #
    # Hand the fans back to Dell before leaving, rather than leave them wherever they were : a previous
    # run of this container may have left the BMC in manual mode, in which case they would stay pinned
    # at the user's low speed with nobody watching the temperatures. graceful_exit is not reached here,
    # the trap only covering the termination signals
    # Verified rather than announced. The closing line below used to state that Dell's profile had been
    # applied whatever the BMC answered, so a server that refused the hand-back was told the opposite of
    # what the line above it had just logged
    WERE_THE_FANS_HANDED_BACK=true
    apply_Dell_default_fan_control_profile || WERE_THE_FANS_HANDED_BACK=false

    if "$WERE_THE_FANS_HANDED_BACK"; then
      HAND_BACK_CLAUSE=" Dell default dynamic fan control profile applied for safety before exiting"
    else
      HAND_BACK_CLAUSE=" This server also refused to be put back on Dell's own dynamic fan control profile, so its fans are left wherever they were"
    fi

    # The one remedy this server actually has, said to the only people it applies to. An iDRAC that
    # reports no CPU temperature is read from lm-sensors instead -- but only in local mode, because
    # lm-sensors reads the machine this container runs on and network mode does not assume that is the
    # server being controlled. Issue #378's reporter hit exactly this, on a machine that WAS the same
    # one, and had to work out on his own that local mode was the answer
    NETWORK_MODE_CLAUSE=""
    if "$NETWORK_MODE"; then
      # Network mode no longer refuses the fallback outright : it reads lm-sensors when the container is
      # PROVEN to be running on the server IDRAC_HOST names (issue #465). Reaching this refusal in network
      # mode therefore means the proof was not made, and the reason it was not is the useful half -- most
      # often that /sys/class/dmi/id/product_serial is not readable from inside the container. Saying
      # "unavailable in network mode" here would be what the message said before that check existed
      NETWORK_MODE_CLAUSE="
 This container is in network mode, where lm-sensors may only stand in for the iDRAC once this container is shown to be running on the very server IDRAC_HOST names -- it reads the machine it runs on, and reading the wrong machine's CPUs to drive this server's fans is the one failure that check exists to prevent. It was not shown here${SAME_MACHINE_VERDICT_REASON:+ : $SAME_MACHINE_VERDICT_REASON}.
 If this container DOES run on that server, either make /sys/class/dmi/id/product_serial readable from inside it, or set IDRAC_HOST=local and give it the host's /dev/ipmi0 -- the CPUs are then read locally while every fan control command still goes to the very same BMC."
    fi

    print_error_and_exit "No CPU temperature sensor could be read from $SERVER_MANUFACTURER $SERVER_MODEL, and every PowerEdge has at least one CPU.
 If IDRAC_HOST points at a chassis management controller (VRTX, FX2, M1000e, MX7000), point it at a node's own iDRAC instead : the chassis hosts no CPU, and its CMC drives the enclosure fans rather than a node's.
 Otherwise, run \"ipmitool -I lanplus -H <iDRAC IP address> -U <iDRAC username> -P <iDRAC password> sdr type temperature\" (drop the connection options in local mode) and look for lines whose 4th column is an entity \"3.<something>\" and whose reading ends in \"degrees C\". An entity that is listed but reads \"Disabled\" or \"No Reading\" is an iDRAC publishing no CPU temperature, which is the case below.$NETWORK_MODE_CLAUSE
 If some are listed and the container still reports none, or if none is listed at all, please open an issue with your server model and that output : https://github.com/tigerblue77/Dell_iDRAC_fan_controller_Docker/issues
 Set MONITORING_ONLY_MODE=true to keep the container running and logging the temperatures it can read, without driving the fans.$HAND_BACK_CLAUSE"
  fi

  # Worded and repeated exactly like the monitoring loop does for the same situation : this is the
  # same powered-off server, only observed before the first reading rather than after
  set_log_timestamp TIMESTAMP
  printf "%19s  Target server is powered off, no fan control profile applied.\n" "$TIMESTAMP"

  wait $SLEEP_PROCESS_PID

  # Start timer in background for next attempt
  sleep "$CHECK_INTERVAL" &
  SLEEP_PROCESS_PID=$!
done

# Not readonly : the monitoring loop follows the CPUs the server exposes, which can change while it runs
NUMBER_OF_DETECTED_CPUS=${#DETECTED_CPU_ENTITY_IDS[@]}

echo "$(format_detected_CPU_temperature_sensors)."

warn_if_unexpected_number_of_CPUs

retrieve_temperatures "$SDR_TEMPERATURE_DATA"

# Reported for information only. Most servers printing this line genuinely have no exhaust sensor --
# blades and enclosure-housed sleds never do -- so the wording stays as it was ; what changed is that
# the line no longer decides anything. The sensor is read again on every cycle, so a chassis whose
# sensors were merely not readable at this instant starts showing its temperature as soon as they
# answer, instead of being written off for the container's lifetime
if [ -z "$EXHAUST_TEMPERATURE" ]; then
  echo "No exhaust temperature sensor detected."
fi
# Output new line to beautify output
echo ""

# Settled here, once, and read by both the header and every row : the profile column is too tight to hold
# the monitoring only mode badge, so its width follows the mode rather than being a literal in two places
resolve_fan_control_profile_column_width

CPU_COLUMN_CONTENT_WIDTH=$(compute_CPU_column_content_width "${DETECTED_CPU_LABELS[@]}")
if ! HEADER=$(build_header "$CPU_COLUMN_CONTENT_WIDTH" "${DETECTED_CPU_LABELS[@]}"); then
  print_error_and_exit "Could not build the temperatures table header"
fi

# Start monitoring
while true; do
  # In network mode, if the target server is powered off, skip this cycle entirely: don't read
  # temperatures (they would be meaningless) and don't apply any fan control profile.
  # A cycle is also skipped when the iDRAC can't be reached at all, but the two are reported
  # separately: one is a machine that is legitimately off, the other is a server we may well be
  # holding at a static fan speed with no way to see or change anything about it
  if $NETWORK_MODE; then
    get_server_power_state
    TARGET_SERVER_POWER_STATE=$?

    if [ $TARGET_SERVER_POWER_STATE -ne 0 ]; then
      IS_TARGET_SERVER_UNAVAILABLE=true
      set_log_timestamp TIMESTAMP

      if [ $TARGET_SERVER_POWER_STATE -eq 2 ]; then
        # Deliberately not flagged as powered off : we did not observe the server, we failed to ask.
        # A dropped session or a LAN flap leaves it running, and its CPUs cannot have changed
        (( CONSECUTIVE_IPMI_FAILURES++ ))
        printf "%19s  Cannot reach the iDRAC, target server state unknown and fan control profile left as-is. ipmitool said: %s\n" "$TIMESTAMP" "$IPMI_UNREACHABLE_REASON" >&2
        exit_if_iDRAC_unreachable_for_too_long
      else
        IS_TARGET_SERVER_POWERED_OFF=true
        # Observed correctly : the chassis really is off, so this is not a failure to reach anything
        CONSECUTIVE_IPMI_FAILURES=0
        printf "%19s  Target server is powered off, no fan control profile applied.\n" "$TIMESTAMP"
      fi

      # A skipped cycle is a completed one : the server is off, or its iDRAC was briefly unreachable,
      # and this container observed that correctly rather than stopping
      note_that_this_cycle_completed

      wait $SLEEP_PROCESS_PID

      # Start timer in background for next cycle
      sleep "$CHECK_INTERVAL" &
      SLEEP_PROCESS_PID=$!
      continue
    fi

    # Reached only when the iDRAC answered, so any streak of failures is over. Reset rather than
    # decrement : the threshold is about losing the server, not about how often it hiccups
    CONSECUTIVE_IPMI_FAILURES=0
  fi

  # The server just powered back on: refresh temperatures now instead of evaluating stale data read
  # before/during the outage (could be the initial pre-loop reading, or readings from before it powered off)
  if $IS_TARGET_SERVER_UNAVAILABLE; then
    IS_TARGET_SERVER_UNAVAILABLE=false

    # Only a server that was really switched off and on again can have changed CPUs, so only that opens
    # the window during which one is allowed to leave the monitored set. An iDRAC we merely could not
    # reach says nothing about the machine : it kept running, and treating the outage as a power cycle
    # would let five unreadable readings after a LAN flap drop a socket that never went anywhere
    if $IS_TARGET_SERVER_POWERED_OFF; then
      IS_TARGET_SERVER_POWERED_OFF=false
      IS_CPU_REMOVAL_ALLOWED=true
      PENDING_CPU_REMOVAL_SIGNATURE=""
      PENDING_CPU_REMOVAL_READINGS=0
    fi

    # Refreshed after either outage : the readings taken before or during it are equally stale
    retrieve_temperatures
  fi

  # Follow the CPUs the server exposes : one may have been added while it was powered off, one may have
  # been removed, and one may simply not have finished POSTing yet. Checked every cycle, and reusing the
  # data retrieve_temperatures() just fetched, so it costs no extra IPMI round-trip
  PREVIOUS_CPU_ENTITY_IDS=("${DETECTED_CPU_ENTITY_IDS[@]}")
  PREVIOUS_CPU_LABELS=("${DETECTED_CPU_LABELS[@]}")
  if refresh_CPU_temperature_sensors "$SDR_TEMPERATURE_DATA"; then
    NUMBER_OF_DETECTED_CPUS=${#DETECTED_CPU_ENTITY_IDS[@]}
    CPU_COLUMN_CONTENT_WIDTH=$(compute_CPU_column_content_width "${DETECTED_CPU_LABELS[@]}")
    HEADER=$(build_header "$CPU_COLUMN_CONTENT_WIDTH" "${DETECTED_CPU_LABELS[@]}")
    # The table just changed shape, so its header is reprinted before the next line
    TABLE_HEADER_PRINT_COUNTER=$TABLE_HEADER_PRINT_INTERVAL

    # Which CPUs left is computed from the sets themselves rather than from the count, so that CPUs
    # leaving and appearing on the same cycle can't cancel each other out and pass unreported.
    # They are named with the labels their columns carried until now, which is what the reader has just
    # been looking at, and with their entity so the line can be matched against an ipmitool output
    REMOVED_CPU_LABELS=()
    REMOVED_CPU_ENTITY_IDS=()
    for INDEX in "${!PREVIOUS_CPU_ENTITY_IDS[@]}"; do
      if [[ " ${DETECTED_CPU_ENTITY_IDS[*]} " != *" ${PREVIOUS_CPU_ENTITY_IDS[INDEX]} "* ]]; then
        REMOVED_CPU_LABELS+=("${PREVIOUS_CPU_LABELS[INDEX]}")
        REMOVED_CPU_ENTITY_IDS+=("${PREVIOUS_CPU_ENTITY_IDS[INDEX]}")
      fi
    done

    # A CPU leaving the table means one less heat source watched, which deserves more than the plain
    # count : it is the only trace left that the server used to have it. The line states the conclusion
    # the controller drew and the rule it applied to draw it, rather than the symptom alone : a sensor
    # that went quiet is not a reason to stop watching a CPU, a CPU that is gone is
    set_log_timestamp TIMESTAMP
    DETECTED_CPU_TEMPERATURE_SENSORS=$(format_detected_CPU_temperature_sensors)
    if [ "${#REMOVED_CPU_LABELS[@]}" -eq 1 ]; then
      printf "%19s  %s is considered removed from the server: its temperature sensor (entity %s) reported nothing on the %s readings that followed the server powering back on. %s.\n" "$TIMESTAMP" "${REMOVED_CPU_LABELS[0]}" "${REMOVED_CPU_ENTITY_IDS[0]}" "$CPU_REMOVAL_CONFIRMING_READINGS" "$DETECTED_CPU_TEMPERATURE_SENSORS"
    elif [ "${#REMOVED_CPU_LABELS[@]}" -gt 1 ]; then
      REMOVED_CPU_LABELS_ENUMERATION=$(join_with_and "${REMOVED_CPU_LABELS[@]}")
      REMOVED_CPU_ENTITY_IDS_ENUMERATION=$(join_with_and "${REMOVED_CPU_ENTITY_IDS[@]}")
      printf "%19s  %s are considered removed from the server: their temperature sensors (entities %s) reported nothing on the %s readings that followed the server powering back on. %s.\n" "$TIMESTAMP" "$REMOVED_CPU_LABELS_ENUMERATION" "$REMOVED_CPU_ENTITY_IDS_ENUMERATION" "$CPU_REMOVAL_CONFIRMING_READINGS" "$DETECTED_CPU_TEMPERATURE_SENSORS"
    else
      printf "%19s  %s.\n" "$TIMESTAMP" "$DETECTED_CPU_TEMPERATURE_SENSORS"
    fi

    # Checked again here and not only at startup : a mis-parse can just as well show up mid-run
    warn_if_unexpected_number_of_CPUs

    # A CPU appearing can sort before the known ones, so the readings are taken again against the new
    # entity list rather than reused from before it changed. The same data is handed back rather than
    # fetched again : following the CPUs then costs no IPMI round-trip at all, and the readings keep
    # describing the very instant the set was detected on
    retrieve_temperatures "$SDR_TEMPERATURE_DATA"
  fi

  # Initialize a variable to store the comments displayed when the fan control profile changed
  COMMENT=" -"
  # Check if any of the detected CPUs is overheating then apply Dell default dynamic fan control profile if true
  if is_any_CPU_overheating; then
    apply_Dell_default_fan_control_profile

    if ! $IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED || $IS_FIRST_MONITORING_CYCLE; then
      IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED=true

      # is_any_CPU_overheating() collected every CPU concerned, however many of them there are, each
      # with its reading so the comment can tell "too high" from "could not be read"
      if (( ${#OVERHEATING_CPUS_AND_TEMPERATURES[@]} > 0 )); then
        COMMENT=$(build_fan_control_fallback_comment "${OVERHEATING_CPUS_AND_TEMPERATURES[@]}")
      else
        COMMENT="No CPU temperature could be read, $(fan_control_comment_clause "Dell default dynamic fan control profile applied for safety")"
      fi
    fi
  else
    apply_user_fan_control_profile

    # Check if user fan control profile is applied then apply it if not
    if $IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED || $IS_FIRST_MONITORING_CYCLE; then
      IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED=false
      # Kept symmetric with the clause naming the CPUs that triggered the switch, plural included.
      # It says the temperatures are OK rather than that they decreased, because the Dell default profile
      # is also applied when a reading can't be parsed : claiming a temperature dropped would contradict
      # the "could not be read" comment printed when that happened
      if [ "$NUMBER_OF_DETECTED_CPUS" -eq 1 ]; then
        COMMENT="CPU temperature is now OK (<= $CPU_TEMPERATURE_THRESHOLD°C), $(fan_control_comment_clause "user's fan control profile applied")."
      else
        COMMENT="All CPU temperatures are now OK (<= $CPU_TEMPERATURE_THRESHOLD°C), $(fan_control_comment_clause "user's fan control profile applied")."
      fi
    fi
  fi

  # The third-party PCIe card Dell default cooling response is an OEM command that not every server
  # takes : it no longer exists from the 14th generation on, and a blade or a modular sled has no fan
  # of its own to apply it to. Which servers those are cannot be read from the model name — Dell never
  # named the AMD, dense and modular models to a scheme a pattern could follow, so a name-based check
  # told an R6515 or an MX740c apart from an R730 exactly backwards (issue #173).
  #
  # So ask the server and report what it answered. A command that failed is not a verdict on its own :
  # ipmitool exits non-zero both for a command the BMC does not have and for a BMC it never reached, and
  # only the completion code it prints tells the two apart. The controller therefore stops asking on the
  # first genuine "I do not have this command", and never on a network outage, however long it lasts
  if $IS_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_SUPPORTED; then
    # Enable or disable, depending on the user's choice, third-party PCIe card Dell default cooling response
    # No comment will be displayed on the change of this parameter since it is not related to the temperature of any device (CPU, GPU, etc...) but only to the settings made by the user when launching this Docker container
    if "$DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE"; then
      REQUESTED_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE="Disabled"
      disable_third_party_PCIe_card_Dell_default_cooling_response
    else
      REQUESTED_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE="Enabled"
      enable_third_party_PCIe_card_Dell_default_cooling_response
    fi
    # The status of the command the branch above just ran
    THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_EXIT_CODE=$?

    if [ $THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_EXIT_CODE -eq 0 ]; then
      THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS="$REQUESTED_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE"

      if "$MONITORING_ONLY_MODE"; then
        THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS+=" (not applied: monitoring only mode)"
      fi
    elif does_the_server_lack_this_command "$THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STDERR"; then
      # The BMC answered, and answered that it does not have this command. That will not change while
      # this container runs, so stop sending it
      IS_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_SUPPORTED=false

      # "Not supported by this server" is true of the COMMAND and can be false of the SERVER. Dell moved
      # this setting from one global IPMI command to a per-slot Redfish attribute at the 14th generation,
      # so a machine that has just said it lacks the command may expose the very same control on
      # PCIeSlotLFM.<n>.LFMMode -- and some owners already drive it there by hand. Reporting the loss
      # without asking would send them to look at their hardware for something their hardware has, which
      # is the shape of wrong diagnosis #195 and #347 exist to remove.
      #
      # Asked once, on the cycle the verdict is reached, and never again : the answer cannot change while
      # this container runs, and this is the one place that already knows the IPMI command is gone
      IS_THE_COOLING_RESPONSE_A_REDFISH_QUESTION=true

      # "Automatic" is Dell's default and is what "enabled" means for a slot : the iDRAC decides that
      # slot's airflow for itself, which is the behaviour this parameter exists to switch off
      if "$DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE"; then
        WANTED_LFM_MODE="Disabled"
      else
        WANTED_LFM_MODE="Automatic"
      fi

      attempt_the_redfish_cooling_response "$WANTED_LFM_MODE" "$REQUESTED_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE"
    elif does_the_command_need_a_higher_privilege_level "$THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STDERR"; then
      # The BMC answered too, and answered that this account may not run the command. Also permanent for
      # this run -- the credentials do not change while the container does -- so it stops being sent for
      # the same reason as above, and the column says so rather than repeating "could not be applied on
      # this cycle" for the life of the container on a condition no cycle will ever clear.
      #
      # What it must NOT say is "not supported by this server" : the server has the command, this account
      # may not use it, and naming the hardware sends the reader to check a server that is fine instead
      # of the iDRAC user they can actually fix. Reported on an R550 in #29, where every raw command --
      # the fan control ones included -- answered "Insufficient privilege level"
      IS_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_SUPPORTED=false
      THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS="Refused: this account lacks the privilege level"
    else
      # The command did not go through, but nothing says the server refused it : an unreachable iDRAC, a
      # busy BMC, an answer this controller does not recognize. Report the cycle and try again on the next
      THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS="Could not be applied on this cycle"
    fi
  elif "$IS_THE_COOLING_RESPONSE_A_REDFISH_QUESTION" && ! "$REDFISH_COOLING_RESPONSE_SETTLED"; then
    # The IPMI command is settled -- gone -- but Redfish has not answered anything that settles what
    # replaces it : the iDRAC was busy, its job queue full, or its HTTPS stack briefly unreachable. This
    # is the retry, a CHECK_INTERVAL after the last one, which is what gives it time to stop being so.
    # It covers both halves of the errand : a probe that never got an answer and a write that was
    # refused by a moment are the same kind of not-yet (#376)
    if "$DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE"; then
      REQUESTED_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE="Disabled"
      WANTED_LFM_MODE="Disabled"
    else
      REQUESTED_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE="Enabled"
      WANTED_LFM_MODE="Automatic"
    fi

    attempt_the_redfish_cooling_response "$WANTED_LFM_MODE" "$REQUESTED_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE"
  fi

  # Print temperatures, active fan control profile and comment if any change happened during last time interval
  if [ $TABLE_HEADER_PRINT_COUNTER -eq $TABLE_HEADER_PRINT_INTERVAL ]; then
    printf "%s\n" "$HEADER"
    TABLE_HEADER_PRINT_COUNTER=0
  fi
  print_temperature_array_line "$CPU_COLUMN_CONTENT_WIDTH" "$INLET_TEMPERATURE" "$CPUS_TEMPERATURES" "$EXHAUST_TEMPERATURE" "$CURRENT_FAN_CONTROL_PROFILE" "$THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS" "$COMMENT"
  IS_FIRST_MONITORING_CYCLE=false
  ((TABLE_HEADER_PRINT_COUNTER++))

  # The row is printed and the profile is applied : this cycle is done, which is what the healthcheck
  # reads to tell a running loop from a wedged one (issue #440)
  note_that_this_cycle_completed

  wait $SLEEP_PROCESS_PID

  # Start timer in background for next cycle
  sleep "$CHECK_INTERVAL" &
  SLEEP_PROCESS_PID=$!

  retrieve_temperatures
done
