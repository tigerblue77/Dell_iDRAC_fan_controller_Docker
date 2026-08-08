#!/bin/bash

# Enable strict bash mode to stop the script if an uninitialized variable is used, if a command fails, or if a command with a pipe fails
# Not working in some setups : https://github.com/tigerblue77/Dell_iDRAC_fan_controller/issues/48
# set -euo pipefail

source functions.sh
source constants.sh

# Trap the signals for container exit and run graceful_exit function
trap 'graceful_exit' SIGINT SIGQUIT SIGTERM

# Prepare, format and define initial variables

# readonly DELL_FRESH_AIR_COMPLIANCE=45

# CHECK_INTERVAL paces the whole monitoring loop and is handed straight to sleep, whose exit status the
# loop never looks at, so an unusable value doesn't stop anything : it makes every cycle return at once
# and turns the loop into a busy loop hammering the iDRAC. Validate it here, before the first IPMI
# command, and refuse to start rather than fail silently once running
validate_check_interval_parameter "CHECK_INTERVAL" "$CHECK_INTERVAL"

# Check if FAN_SPEED variable is in hexadecimal format. If not, convert it to hexadecimal
if [[ "$FAN_SPEED" == 0x* ]]; then
  readonly DECIMAL_FAN_SPEED=$(convert_hexadecimal_value_to_decimal "$FAN_SPEED")
  readonly HEXADECIMAL_FAN_SPEED="$FAN_SPEED"
else
  readonly DECIMAL_FAN_SPEED="$FAN_SPEED"
  readonly HEXADECIMAL_FAN_SPEED=$(convert_decimal_value_to_hexadecimal "$FAN_SPEED")
fi

set_iDRAC_login_string "$IDRAC_HOST" "$IDRAC_USERNAME" "$IDRAC_PASSWORD"

get_Dell_server_model

if [[ ! $SERVER_MANUFACTURER == "DELL" ]]; then
  print_error_and_exit "Your server isn't a Dell product"
fi

# CPU temperature indexes are gone: retrieve_temperatures() now locates each CPU by its IPMI entity ID
# instead of counting values, which no longer depends on the server generation

# If server model is Gen 14 (*40) or newer
if [[ $SERVER_MODEL =~ .*[RT][[:space:]]?[0-9][4-9]0.* ]]; then
  readonly DELL_POWEREDGE_GEN_14_OR_NEWER=true
else
  readonly DELL_POWEREDGE_GEN_14_OR_NEWER=false
fi

# In local mode, the container runs on the target server itself, so it can never observe it powered off
# while the container is running. This check is therefore only meaningful in network mode.
if [[ "$IDRAC_HOST" == "local" ]]; then
  readonly NETWORK_MODE=false
else
  readonly NETWORK_MODE=true
fi

# Log main informations
echo "Server model: $SERVER_MANUFACTURER $SERVER_MODEL"
echo "iDRAC/IPMI host: $IDRAC_HOST"

# Log the fan speed objective, CPU temperature threshold and check interval
echo "Fan speed objective: $DECIMAL_FAN_SPEED%"
echo "CPU temperature threshold: "$CPU_TEMPERATURE_THRESHOLD"°C"
# The unit is only appended when the value doesn't already carry one, "90s" and "5m" being accepted
# forms that would otherwise be logged as "90ss" and "5ms"
if [[ "$CHECK_INTERVAL" =~ ^[0-9]+$ ]]; then
  echo "Check interval: ${CHECK_INTERVAL}s"
else
  echo "Check interval: $CHECK_INTERVAL"
fi
if $MONITORING_ONLY_MODE; then
  echo "Monitoring only mode: Enabled (no fan control profile will be applied, temperatures will only be logged)"
else
  echo "Monitoring only mode: Disabled"
fi
echo ""

TABLE_HEADER_PRINT_COUNTER=$TABLE_HEADER_PRINT_INTERVAL
# Set the flag used to check if the active fan control profile has changed
IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED=true
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
# The target server may be powered off, or its iDRAC may not be answering yet, when the container starts.
# No sensor can be read then, so keep waiting instead of giving up : this container is expected to
# outlive its target server being powered off, and exiting here would just make it restart in a loop
IS_WAITING_FOR_CPU_TEMPERATURE_SENSORS_LOGGED=false
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

    # The server answers but exposes no readable CPU temperature, so nothing can be supervised. Hand the
    # fans back to Dell rather than leave them wherever they were: a previous run of this container may
    # have left the BMC in manual mode, in which case they would stay pinned at the user's low speed
    # with nobody watching the temperatures
    apply_Dell_default_fan_control_profile
  fi

  if ! $IS_TARGET_SERVER_ANSWERING; then
    # Worded and repeated exactly like the monitoring loop does for the same situation : this is the
    # same powered-off server, only observed before the first reading rather than after
    printf "%19s  Target server is powered off, no fan control profile applied.\n" "$(date +"%d-%m-%Y %T")"
  elif ! $IS_WAITING_FOR_CPU_TEMPERATURE_SENSORS_LOGGED; then
    # The server answers but exposes nothing readable. Logged once only, to say why the container isn't
    # printing temperatures yet without flooding the logs every cycle
    IS_WAITING_FOR_CPU_TEMPERATURE_SENSORS_LOGGED=true

    if $NETWORK_MODE; then
      WAITING_REASON="is the target server still starting up ?"
    else
      # In local mode the server is by definition powered on, so pointing at its power state would send
      # the user looking in the wrong direction: the sensors are there, they just can't be parsed
      WAITING_REASON="see the troubleshooting section of the README"
    fi

    # The profile is only claimed when it was really sent : applying it is a no-op in monitoring only mode
    if $MONITORING_ONLY_MODE; then
      printf "%19s  No CPU temperature sensor could be read (%s), waiting...\n" "$(date +"%d-%m-%Y %T")" "$WAITING_REASON"
    else
      printf "%19s  No CPU temperature sensor could be read (%s), Dell default dynamic fan control profile applied for safety while waiting...\n" "$(date +"%d-%m-%Y %T")" "$WAITING_REASON"
    fi
  fi

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

    if ! $IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED; then
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
    if $IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED; then
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

  # If server model is not Gen 14 (*40) or newer
  if ! $DELL_POWEREDGE_GEN_14_OR_NEWER; then
    # Enable or disable, depending on the user's choice, third-party PCIe card Dell default cooling response
    # No comment will be displayed on the change of this parameter since it is not related to the temperature of any device (CPU, GPU, etc...) but only to the settings made by the user when launching this Docker container
    if "$DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE"; then
      disable_third_party_PCIe_card_Dell_default_cooling_response
      THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS="Disabled"
    else
      enable_third_party_PCIe_card_Dell_default_cooling_response
      THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS="Enabled"
    fi

    if $MONITORING_ONLY_MODE; then
      THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS+=" (not applied: monitoring only mode)"
    fi
  fi

  # Print temperatures, active fan control profile and comment if any change happened during last time interval
  if [ $TABLE_HEADER_PRINT_COUNTER -eq $TABLE_HEADER_PRINT_INTERVAL ]; then
    printf "%s\n" "$HEADER"
    TABLE_HEADER_PRINT_COUNTER=0
  fi
  print_temperature_array_line "$CPU_COLUMN_CONTENT_WIDTH" "$INLET_TEMPERATURE" "$CPUS_TEMPERATURES" "$EXHAUST_TEMPERATURE" "$CURRENT_FAN_CONTROL_PROFILE" "$THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS" "$COMMENT"
  ((TABLE_HEADER_PRINT_COUNTER++))

  wait $SLEEP_PROCESS_PID

  # Start timer in background for next cycle
  sleep "$CHECK_INTERVAL" &
  SLEEP_PROCESS_PID=$!

  retrieve_temperatures $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT
done
