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
echo "Check interval: ${CHECK_INTERVAL}s"
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
# When each monitored CPU temperature sensor was last readable, keyed by IPMI entity ID, so that a CPU
# staying silent longer than CPU_TEMPERATURE_SENSOR_EXPIRY can be told from one that is merely rebooting
declare -A CPU_LAST_READABLE_AT

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
  if ! $NETWORK_MODE || is_server_powered_on; then
    detect_CPU_temperature_sensors "$(retrieve_sdr_temperature_data)"
    if [ ${#DETECTED_CPU_ENTITY_IDS[@]} -gt 0 ]; then
      break
    fi

    # The server answers but exposes no readable CPU temperature, so nothing can be supervised. Hand the
    # fans back to Dell rather than leave them wherever they were: a previous run of this container may
    # have left the BMC in manual mode, in which case they would stay pinned at the user's low speed
    # with nobody watching the temperatures
    apply_Dell_default_fan_control_profile
  fi

  # Only logged once, to say why the container isn't printing temperatures yet without flooding the logs
  if ! $IS_WAITING_FOR_CPU_TEMPERATURE_SENSORS_LOGGED; then
    IS_WAITING_FOR_CPU_TEMPERATURE_SENSORS_LOGGED=true
    if $NETWORK_MODE; then
      printf "%19s  No CPU temperature sensor could be read yet (is the target server powered off ?), Dell default dynamic fan control profile applied for safety while waiting...\n" "$(date +"%d-%m-%Y %T")"
    else
      # In local mode the server is by definition powered on, so pointing at its power state would send
      # the user looking in the wrong direction: the sensors are there, they just can't be parsed
      printf "%19s  No CPU temperature sensor could be read, see the troubleshooting section of the README. Dell default dynamic fan control profile applied for safety while waiting...\n" "$(date +"%d-%m-%Y %T")"
    fi
  fi

  wait $SLEEP_PROCESS_PID

  # Start timer in background for next attempt
  sleep "$CHECK_INTERVAL" &
  SLEEP_PROCESS_PID=$!
done

# Start the expiry delay of every CPU detected here : without this they would have no last-readable time
# at all, and the first cycle on which one of them is silent would expire it instantly
postpone_CPU_temperature_sensors_expiry "$(date +%s)"

# Not readonly : the monitoring loop follows the CPUs the server exposes, which can change while it runs
NUMBER_OF_DETECTED_CPUS=${#DETECTED_CPU_ENTITY_IDS[@]}

echo "$(format_detected_CPU_temperature_sensors)."

# Nothing is dropped when this triggers, every detected CPU is monitored : it only flags a count that no
# Dell hardware can produce, which most likely means the sensors were mis-parsed
if [ "$NUMBER_OF_DETECTED_CPUS" -gt "$MAXIMUM_NUMBER_OF_CPUS_IN_A_DELL_SERVER" ]; then
  # print_warning() emits no trailing newline, hence the echo
  print_warning "$NUMBER_OF_DETECTED_CPUS CPU temperature sensors is more than any Dell server has sockets. All of them will be monitored, but please open an issue at https://github.com/tigerblue77/Dell_iDRAC_fan_controller_Docker/issues with your server model and the output of the \"ipmitool sdr type temperature\" command"
  echo ""
fi

retrieve_temperatures $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT

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

    # Its sensors are legitimately silent while it is off, so that silence must not count towards the
    # delay after which a CPU is considered removed
    postpone_CPU_temperature_sensors_expiry "$(date +%s)"

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
    retrieve_temperatures $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT
  fi

  # Follow the CPUs the server exposes : one may have been added while it was powered off, one may have
  # been removed, and one may simply not have finished POSTing yet. Checked every cycle rather than only
  # on a power transition, and reusing the data retrieve_temperatures() just fetched, so it costs no
  # extra IPMI round-trip
  PREVIOUS_NUMBER_OF_DETECTED_CPUS=$NUMBER_OF_DETECTED_CPUS
  if refresh_CPU_temperature_sensors "$SDR_TEMPERATURE_DATA" "$(date +%s)"; then
    NUMBER_OF_DETECTED_CPUS=${#DETECTED_CPU_ENTITY_IDS[@]}
    CPU_COLUMN_CONTENT_WIDTH=$(compute_CPU_column_content_width "${DETECTED_CPU_LABELS[@]}")
    HEADER=$(build_header "$CPU_COLUMN_CONTENT_WIDTH" "${DETECTED_CPU_LABELS[@]}")
    # The table just changed shape, so its header is reprinted before the next line
    TABLE_HEADER_PRINT_COUNTER=$TABLE_HEADER_PRINT_INTERVAL

    # A CPU leaving the table means one less heat source watched, which deserves more than the plain
    # count : it is the only trace left that the server used to have it
    if [ "$NUMBER_OF_DETECTED_CPUS" -lt "$PREVIOUS_NUMBER_OF_DETECTED_CPUS" ]; then
      printf "%19s  A CPU stopped reporting its temperature for more than %ss and is no longer monitored, %s.\n" "$(date +"%d-%m-%Y %T")" "$CPU_TEMPERATURE_SENSOR_EXPIRY" "$(format_detected_CPU_temperature_sensors)"
    else
      printf "%19s  %s.\n" "$(date +"%d-%m-%Y %T")" "$(format_detected_CPU_temperature_sensors)"
    fi

    # A CPU appearing can sort before the known ones, so the readings must be taken again against the
    # new entity list rather than reused from before it changed
    retrieve_temperatures $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT
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
