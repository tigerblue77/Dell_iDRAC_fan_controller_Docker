#!/bin/bash

# Enable strict bash mode to stop the script if an uninitialized variable is used, if a command fails, or if a command with a pipe fails
# Not working in some setups : https://github.com/tigerblue77/Dell_iDRAC_fan_controller/issues/48
# set -euo pipefail

source functions.sh
source constants.sh

# Dell's "third-party PCIe card default cooling response" is an OEM command that not every server
# takes, and the monitoring loop below finds out by sending it and reading the answer rather than by
# guessing from the model name
IS_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_SUPPORTED=true

# Trap the signals for container exit and run graceful_exit function
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

# CHECK_INTERVAL paces the whole monitoring loop and is handed straight to sleep, whose exit status the
# loop never looks at, so an unusable value doesn't stop anything : it makes every cycle return at once
# and turns the loop into a busy loop hammering the iDRAC. It is also the controller's reaction time,
# the fans being pinned between two checks, so an excessively long one is refused as well. Validate it
# here, before the first IPMI command, and refuse to start rather than fail silently once running.
# The monitoring only mode is passed along because it decides whether that reaction time exists at all
validate_check_interval_parameter "CHECK_INTERVAL" "$CHECK_INTERVAL" "$MONITORING_ONLY_MODE"

# Check if FAN_SPEED variable is in hexadecimal format. If not, convert it to hexadecimal
if [[ "$FAN_SPEED" == 0x* ]]; then
  readonly DECIMAL_FAN_SPEED=$(convert_hexadecimal_value_to_decimal "$FAN_SPEED")
  readonly HEXADECIMAL_FAN_SPEED="$FAN_SPEED"
else
  readonly DECIMAL_FAN_SPEED="$FAN_SPEED"
  readonly HEXADECIMAL_FAN_SPEED=$(convert_decimal_value_to_hexadecimal "$FAN_SPEED")
fi

# In local mode, the container runs on the target server itself. Two things depend on that : lm-sensors
# can only describe the controlled server's CPUs in that mode, and the server can never be observed
# powered off while the container is running, so that check is only meaningful in network mode
if [[ "$IDRAC_HOST" == "local" ]]; then
  readonly NETWORK_MODE=false
else
  readonly NETWORK_MODE=true
fi

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
  # the Dell default profile is never restored and the fans stay low for the life of the container
  if [ "$CPU_TEMPERATURE_THRESHOLD" -lt "$MINIMUM_PLAUSIBLE_CPU_TEMPERATURE_THRESHOLD" ] || [ "$CPU_TEMPERATURE_THRESHOLD" -gt "$MAXIMUM_PLAUSIBLE_CPU_TEMPERATURE_THRESHOLD" ]; then
    print_error_and_exit "CPU_TEMPERATURE_THRESHOLD must be between ${MINIMUM_PLAUSIBLE_CPU_TEMPERATURE_THRESHOLD}°C and ${MAXIMUM_PLAUSIBLE_CPU_TEMPERATURE_THRESHOLD}°C, but is ${CPU_TEMPERATURE_THRESHOLD}°C"
  fi
else
  # Reject an unusable threshold right away : every temperature comparison would fail against it, which
  # silently keeps the user's (low) fan speed applied instead of ever triggering the Dell default profile
  print_error_and_exit "CPU_TEMPERATURE_THRESHOLD must be a positive integer number of degrees Celsius or \"auto\", but is \"$CPU_TEMPERATURE_THRESHOLD\""
fi
readonly CPU_TEMPERATURE_THRESHOLD

set_iDRAC_login_string "$IDRAC_HOST" "$IDRAC_USERNAME" "$IDRAC_PASSWORD"

get_Dell_server_model

if [[ ! $SERVER_MANUFACTURER == "DELL" ]]; then
  print_error_and_exit "Your server isn't a Dell product"
fi

# CPU temperature indexes are gone: retrieve_temperatures() now locates each CPU by its IPMI entity ID
# instead of counting values, which no longer depends on the server generation

# Log main informations
echo "Server model: $SERVER_MANUFACTURER $SERVER_MODEL"
echo "iDRAC/IPMI host: $IDRAC_HOST"

# Log the fan speed objective, CPU temperature threshold and check interval
echo "Fan speed objective: $DECIMAL_FAN_SPEED%"
echo "CPU temperature threshold: ${CPU_TEMPERATURE_THRESHOLD}°C${CPU_TEMPERATURE_THRESHOLD_SOURCE}"
# The unit is only appended when the value doesn't already carry one, "90s" and "5m" being accepted
# forms that would otherwise be logged as "90ss" and "5ms"
if [[ "$CHECK_INTERVAL" =~ ^[0-9]+$ ]]; then
  echo "Check interval: ${CHECK_INTERVAL}s"
else
  echo "Check interval: $CHECK_INTERVAL"
fi
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
# Tracks whether the target server was powered off on the previous cycle, so temperatures can be
# refreshed right when it powers back on instead of reusing data read before/during the outage
IS_TARGET_SERVER_POWERED_OFF=false

# Check present sensors
IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT=true

# Start timer in background
sleep "$CHECK_INTERVAL" &
SLEEP_PROCESS_PID=$!

# Detect the CPU temperature sensors before entering the monitoring loop, the table header being built
# from them. The loop then keeps watching for CPUs showing up later, so a partial set read here is not
# final.
# The target server may be powered off when the container starts. No sensor can be read then, so keep
# waiting instead of giving up : this container is expected to outlive its target server being powered
# off, and exiting there would just make it restart in a loop.
# A server that does answer is a different matter, and is handled inside the loop : it has CPUs, so
# reporting none of them is a fault to report rather than a state to wait out
while true; do
  IS_TARGET_SERVER_ANSWERING=true
  if $NETWORK_MODE && ! is_server_powered_on; then
    IS_TARGET_SERVER_ANSWERING=false
  fi

  if $IS_TARGET_SERVER_ANSWERING; then
    # Kept for the first retrieve_temperatures() below, so that detecting the CPUs and taking their
    # first readings cost a single IPMI round-trip and describe the very same instant
    SDR_TEMPERATURE_DATA=$(retrieve_sdr_temperature_data)
    detect_CPU_temperature_sensors "$SDR_TEMPERATURE_DATA"
    if [ ${#DETECTED_CPU_ENTITY_IDS[@]} -gt 0 ]; then
      break
    fi

    # The server answers, and answers that it has no readable CPU temperature sensor. Every PowerEdge
    # has at least one CPU, so this is not a state to sit and wait out : an iDRAC that exposes no
    # processor entity does so on every check, not on this one. Retrying forever would leave a container
    # that looks alive and supervises nothing.
    #
    # Hand the fans back to Dell before leaving, rather than leave them wherever they were : a previous
    # run of this container may have left the BMC in manual mode, in which case they would stay pinned
    # at the user's low speed with nobody watching the temperatures. graceful_exit is not reached here,
    # the trap only covering the termination signals
    apply_Dell_default_fan_control_profile

    print_error_and_exit "No CPU temperature sensor could be read from $SERVER_MANUFACTURER $SERVER_MODEL, and every PowerEdge has at least one CPU.
 If IDRAC_HOST points at a chassis management controller (VRTX, FX2, M1000e, MX7000), point it at a node\'s own iDRAC instead : the chassis hosts no CPU, and its CMC drives the enclosure fans rather than a node\'s.
 Otherwise, run \"ipmitool -I lanplus -H <iDRAC IP address> -U <iDRAC username> -P <iDRAC password> sdr type temperature\" (drop the connection options in local mode) and look for lines whose 4th column is an entity \"3.<something>\" and whose reading ends in \"degrees C\".
 If some are listed and the container still reports none, or if none is listed at all, please open an issue with your server model and that output : https://github.com/tigerblue77/Dell_iDRAC_fan_controller_Docker/issues
 Dell default dynamic fan control profile applied for safety before exiting."
  fi

  # Worded and repeated exactly like the monitoring loop does for the same situation : this is the
  # same powered-off server, only observed before the first reading rather than after
  printf "%19s  Target server is powered off, no fan control profile applied.\n" "$(date +"%d-%m-%Y %T")"

  wait $SLEEP_PROCESS_PID

  # Start timer in background for next attempt
  sleep "$CHECK_INTERVAL" &
  SLEEP_PROCESS_PID=$!
done

# Not readonly : the monitoring loop follows the CPUs the server exposes, which can change while it runs
NUMBER_OF_DETECTED_CPUS=${#DETECTED_CPU_ENTITY_IDS[@]}

echo "$(format_detected_CPU_temperature_sensors)."

warn_if_unexpected_number_of_CPUs

retrieve_temperatures $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT "$SDR_TEMPERATURE_DATA"

if [ -z "$EXHAUST_TEMPERATURE" ]; then
  echo "No exhaust temperature sensor detected."
  IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT=false
  # This reading was taken before the sensor was known to be absent, so it holds an empty string where
  # every later cycle will hold the "-" placeholder. Backfilling it here keeps the first printed line
  # consistent with the rest, instead of leaving a blank under the "Exhaust" heading
  EXHAUST_TEMPERATURE="-"
fi
# Output new line to beautify output
echo ""

CPU_COLUMN_CONTENT_WIDTH=$(compute_CPU_column_content_width "${DETECTED_CPU_LABELS[@]}")
if ! HEADER=$(build_header "$CPU_COLUMN_CONTENT_WIDTH" "${DETECTED_CPU_LABELS[@]}"); then
  print_error_and_exit "Could not build the temperatures table header"
fi

# Start monitoring
while true; do
  # In network mode, if the target server is powered off, skip this cycle entirely: don't read
  # temperatures (they would be meaningless) and don't apply any fan control profile
  if $NETWORK_MODE && ! is_server_powered_on; then
    IS_TARGET_SERVER_POWERED_OFF=true
    printf "%19s  Target server is powered off, no fan control profile applied.\n" "$(date +"%d-%m-%Y %T")"

    wait $SLEEP_PROCESS_PID

    # Start timer in background for next cycle
    sleep "$CHECK_INTERVAL" &
    SLEEP_PROCESS_PID=$!
    continue
  fi

  # The server just powered back on: refresh temperatures now instead of evaluating stale data read
  # before/during the outage (could be the initial pre-loop reading, or readings from before it powered off)
  if $IS_TARGET_SERVER_POWERED_OFF; then
    IS_TARGET_SERVER_POWERED_OFF=false
    # It has just been switched off and on again, which is the only way its CPUs can have changed : open
    # the window during which one is allowed to leave the monitored set
    IS_CPU_REMOVAL_ALLOWED=true
    PENDING_CPU_REMOVAL_SIGNATURE=""
    PENDING_CPU_REMOVAL_READINGS=0
    retrieve_temperatures $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT
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
    if [ "${#REMOVED_CPU_LABELS[@]}" -eq 1 ]; then
      printf "%19s  %s is considered removed from the server: its temperature sensor (entity %s) reported nothing on the %s readings that followed the server powering back on. %s.\n" "$(date +"%d-%m-%Y %T")" "${REMOVED_CPU_LABELS[0]}" "${REMOVED_CPU_ENTITY_IDS[0]}" "$CPU_REMOVAL_CONFIRMING_READINGS" "$(format_detected_CPU_temperature_sensors)"
    elif [ "${#REMOVED_CPU_LABELS[@]}" -gt 1 ]; then
      printf "%19s  %s are considered removed from the server: their temperature sensors (entities %s) reported nothing on the %s readings that followed the server powering back on. %s.\n" "$(date +"%d-%m-%Y %T")" "$(join_with_and "${REMOVED_CPU_LABELS[@]}")" "$(join_with_and "${REMOVED_CPU_ENTITY_IDS[@]}")" "$CPU_REMOVAL_CONFIRMING_READINGS" "$(format_detected_CPU_temperature_sensors)"
    else
      printf "%19s  %s.\n" "$(date +"%d-%m-%Y %T")" "$(format_detected_CPU_temperature_sensors)"
    fi

    # Checked again here and not only at startup : a mis-parse can just as well show up mid-run
    warn_if_unexpected_number_of_CPUs

    # A CPU appearing can sort before the known ones, so the readings are taken again against the new
    # entity list rather than reused from before it changed. The same data is handed back rather than
    # fetched again : following the CPUs then costs no IPMI round-trip at all, and the readings keep
    # describing the very instant the set was detected on
    retrieve_temperatures $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT "$SDR_TEMPERATURE_DATA"
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
        COMMENT="No CPU temperature could be read, Dell default dynamic fan control profile applied for safety"
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
        COMMENT="CPU temperature is now OK (<= $CPU_TEMPERATURE_THRESHOLD°C), user's fan control profile applied."
      else
        COMMENT="All CPU temperatures are now OK (<= $CPU_TEMPERATURE_THRESHOLD°C), user's fan control profile applied."
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
      THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS="Not supported by this server"
    else
      # The command did not go through, but nothing says the server refused it : an unreachable iDRAC, a
      # busy BMC, an answer this controller does not recognize. Report the cycle and try again on the next
      THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS="Could not be applied on this cycle"
    fi
  fi

  # Print temperatures, active fan control profile and comment if any change happened during last time interval
  if [ $TABLE_HEADER_PRINT_COUNTER -eq $TABLE_HEADER_PRINT_INTERVAL ]; then
    printf "%s\n" "$HEADER"
    TABLE_HEADER_PRINT_COUNTER=0
  fi
  print_temperature_array_line "$CPU_COLUMN_CONTENT_WIDTH" "$INLET_TEMPERATURE" "$CPUS_TEMPERATURES" "$EXHAUST_TEMPERATURE" "$CURRENT_FAN_CONTROL_PROFILE" "$THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS" "$COMMENT"
  IS_FIRST_MONITORING_CYCLE=false
  ((TABLE_HEADER_PRINT_COUNTER++))

  wait $SLEEP_PROCESS_PID

  # Start timer in background for next cycle
  sleep "$CHECK_INTERVAL" &
  SLEEP_PROCESS_PID=$!

  retrieve_temperatures $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT
done
