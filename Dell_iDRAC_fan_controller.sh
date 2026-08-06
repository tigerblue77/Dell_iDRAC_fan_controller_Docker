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

# Check present sensors
IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT=true

# Start timer in background
sleep "$CHECK_INTERVAL" &
SLEEP_PROCESS_PID=$!

# Detect the CPU temperature sensors once, at startup : the number of sockets doesn't change while the
# server is running, and the table header is built from it. Any number of CPUs up to Dell's 4-socket
# maximum is supported, so 4-socket servers (R930, R830...) get all of their CPUs monitored
detect_CPU_temperature_sensors "$(retrieve_sdr_temperature_data)"
readonly NUMBER_OF_DETECTED_CPUS=${#DETECTED_CPU_ENTITY_IDS[@]}

if [ "$NUMBER_OF_DETECTED_CPUS" -eq 0 ]; then
  # The login string is deliberately left out of this message: it carries the iDRAC host and username, and
  # this error explicitly invites the user to paste the container's logs into a public GitHub issue
  print_error_and_exit "No CPU temperature sensor detected, cannot monitor this server's temperatures. Please open an issue at https://github.com/tigerblue77/Dell_iDRAC_fan_controller_Docker/issues including your server model and the output of the \"ipmitool sdr type temperature\" command"
fi
echo "$NUMBER_OF_DETECTED_CPUS CPU temperature sensor(s) detected."

retrieve_temperatures $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT

if [ -z "$EXHAUST_TEMPERATURE" ]; then
  echo "No exhaust temperature sensor detected."
  IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT=false
fi
# Output new line to beautify output
echo ""

readonly HEADER=$(build_header $NUMBER_OF_DETECTED_CPUS)

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
    retrieve_temperatures $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT
  fi

  # Initialize a variable to store the comments displayed when the fan control profile changed
  COMMENT=" -"
  # Check if any of the detected CPUs is overheating then apply Dell default dynamic fan control profile if true
  if is_any_CPU_overheating; then
    apply_Dell_default_fan_control_profile

    if ! $IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED; then
      IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED=true

      # is_any_CPU_overheating() named the CPUs actually concerned, however many of them there are
      COMMENT="$OVERHEATING_REASON, Dell default dynamic fan control profile applied for safety"
    fi
  else
    apply_user_fan_control_profile

    # Check if user fan control profile is applied then apply it if not
    if $IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED; then
      IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED=false
      COMMENT="CPU temperature decreased and is now OK (<= $CPU_TEMPERATURE_THRESHOLD°C), user's fan control profile applied."
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
  print_temperature_array_line "$INLET_TEMPERATURE" "$CPUS_TEMPERATURES" "$EXHAUST_TEMPERATURE" "$CURRENT_FAN_CONTROL_PROFILE" "$THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS" "$COMMENT"
  ((TABLE_HEADER_PRINT_COUNTER++))

  wait $SLEEP_PROCESS_PID

  # Start timer in background for next cycle
  sleep "$CHECK_INTERVAL" &
  SLEEP_PROCESS_PID=$!

  retrieve_temperatures $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT
done
