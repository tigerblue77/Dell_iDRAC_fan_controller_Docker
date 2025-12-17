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

# Initialize fan control mode (default to static for backward compatibility)
FAN_CONTROL_MODE=${FAN_CONTROL_MODE:-static}
FAN_CONTROL_MODE_ORIGINAL="$FAN_CONTROL_MODE"  # Track original setting for logging

# Initialize hysteresis (default to 2°C, with safety bounds)
FAN_CURVE_HYSTERESIS=${FAN_CURVE_HYSTERESIS:-2}
if [[ "$FAN_CURVE_HYSTERESIS" =~ ^[0-9]+$ ]]; then
    if [ "$FAN_CURVE_HYSTERESIS" -lt 0 ]; then
        FAN_CURVE_HYSTERESIS=0
    fi
    if [ "$FAN_CURVE_HYSTERESIS" -gt 20 ]; then
        FAN_CURVE_HYSTERESIS=20  # Cap at 20°C to prevent extreme values
    fi
else
    FAN_CURVE_HYSTERESIS=2  # Reset to default if not numeric
fi

# Validate CHECK_INTERVAL (default 60s, reasonable safety bounds)
CHECK_INTERVAL=${CHECK_INTERVAL:-60}
if [[ "$CHECK_INTERVAL" =~ ^[0-9]+$ ]]; then
    if [ "$CHECK_INTERVAL" -lt 5 ]; then
        CHECK_INTERVAL=5  # Minimum 5 seconds
    fi
    if [ "$CHECK_INTERVAL" -gt 3600 ]; then
        CHECK_INTERVAL=3600  # Maximum 1 hour
    fi
else
    CHECK_INTERVAL=60  # Reset to default if not numeric
fi

# Validate CPU_TEMPERATURE_THRESHOLD (default 50°C, reasonable safety bounds)
CPU_TEMPERATURE_THRESHOLD=${CPU_TEMPERATURE_THRESHOLD:-50}
if [[ "$CPU_TEMPERATURE_THRESHOLD" =~ ^[0-9]+$ ]]; then
    if [ "$CPU_TEMPERATURE_THRESHOLD" -lt 30 ]; then
        CPU_TEMPERATURE_THRESHOLD=30  # Minimum safe threshold
    fi
    if [ "$CPU_TEMPERATURE_THRESHOLD" -gt 80 ]; then
        CPU_TEMPERATURE_THRESHOLD=80  # Maximum reasonable threshold
    fi
else
    CPU_TEMPERATURE_THRESHOLD=50  # Reset to default if not numeric
fi

# Parse curve if in curve mode
if [[ "$FAN_CONTROL_MODE" == "curve" ]]; then
  if [ -z "$FAN_CURVE" ]; then
    print_error "FAN_CONTROL_MODE=curve but FAN_CURVE is not set. Falling back to static fan control mode."
    FAN_CONTROL_MODE="static"  # Fallback to static mode
  else
    # Try to parse the curve
    if ! parse_fan_curve "$FAN_CURVE"; then
      print_error "Failed to parse FAN_CURVE. Falling back to static fan control mode."
      FAN_CONTROL_MODE="static"  # Fallback to static mode
    fi
  fi
fi

# Variable to track last applied temperature and fan speed for hysteresis (only used in curve mode)
# Format: "temp:speed" (e.g., "45:25")
LAST_APPLIED_TEMP_SPEED=""

set_iDRAC_login_string "$IDRAC_HOST" "$IDRAC_USERNAME" "$IDRAC_PASSWORD"

get_Dell_server_model

if [[ ! $SERVER_MANUFACTURER == "DELL" ]]; then
  print_error_and_exit "Your server isn't a Dell product"
fi

# If server model is Gen 14 (*40) or newer
if [[ $SERVER_MODEL =~ .*[RT][[:space:]]?[0-9][4-9]0.* ]]; then
  readonly DELL_POWEREDGE_GEN_14_OR_NEWER=true
  readonly CPU1_TEMPERATURE_INDEX=2
  readonly CPU2_TEMPERATURE_INDEX=4
else
  readonly DELL_POWEREDGE_GEN_14_OR_NEWER=false
  readonly CPU1_TEMPERATURE_INDEX=1
  readonly CPU2_TEMPERATURE_INDEX=2
fi

# Log main informations
echo "Server model: $SERVER_MANUFACTURER $SERVER_MODEL"
echo "iDRAC/IPMI host: $IDRAC_HOST"

# Log the fan speed objective, CPU temperature threshold and check interval
if [[ "$FAN_CONTROL_MODE" == "curve" ]]; then
  echo "Fan control mode: Curve"
  echo "Fan curve: $FAN_CURVE"
  echo "Fan curve hysteresis: ${FAN_CURVE_HYSTERESIS}°C"
else
  echo "Fan control mode: Static"
  echo "Fan speed objective: $DECIMAL_FAN_SPEED%"
  if [[ "$FAN_CONTROL_MODE_ORIGINAL" == "curve" ]]; then
    echo "Note: Fell back to static mode due to curve configuration issues"
  fi
fi
echo "CPU temperature threshold: "$CPU_TEMPERATURE_THRESHOLD"°C"
echo "Check interval: ${CHECK_INTERVAL}s"
echo ""

TABLE_HEADER_PRINT_COUNTER=$TABLE_HEADER_PRINT_INTERVAL
# Set the flag used to check if the active fan control profile has changed
IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED=true

# Check present sensors
IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT=true
IS_CPU2_TEMPERATURE_SENSOR_PRESENT=true
retrieve_temperatures $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT $IS_CPU2_TEMPERATURE_SENSOR_PRESENT
if [ -z "$EXHAUST_TEMPERATURE" ]; then
  echo "No exhaust temperature sensor detected."
  IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT=false
fi
if [ -z "$CPU2_TEMPERATURE" ]; then
  echo "No CPU2 temperature sensor detected."
  IS_CPU2_TEMPERATURE_SENSOR_PRESENT=false
fi
# Output new line to beautify output if one of the previous conditions have echoed
if ! $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT || ! $IS_CPU2_TEMPERATURE_SENSOR_PRESENT; then
  echo ""
fi

#readonly NUMBER_OF_DETECTED_CPUS=(${CPUS_TEMPERATURES//;/ })
# TODO : write "X CPU sensors detected." and remove previous ifs
readonly HEADER=$(build_header $NUMBER_OF_DETECTED_CPUS)

# Start monitoring
while true; do
  # Validate sleep interval is reasonable before sleeping (safety check)
  if [ "$CHECK_INTERVAL" -lt 1 ] || [ "$CHECK_INTERVAL" -gt 3600 ]; then
    print_error "Invalid CHECK_INTERVAL: $CHECK_INTERVAL. Using 60 seconds."
    CHECK_INTERVAL=60
  fi

  # Sleep for the specified interval before taking another reading
  sleep "$CHECK_INTERVAL" &
  SLEEP_PROCESS_PID=$!

  retrieve_temperatures $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT $IS_CPU2_TEMPERATURE_SENSOR_PRESENT

  # Initialize a variable to store the comments displayed when the fan control profile changed
  COMMENT=" -"
  # Check if CPU 1 or CPU 2 is overheating then apply Dell default dynamic fan control profile if true
  if CPU1_OVERHEATING || ($IS_CPU2_TEMPERATURE_SENSOR_PRESENT && CPU2_OVERHEATING); then
    apply_Dell_default_fan_control_profile

    if ! $IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED; then
      IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED=true

      # Set appropriate comment based on which CPUs are overheating
      if CPU1_OVERHEATING && $IS_CPU2_TEMPERATURE_SENSOR_PRESENT && CPU2_OVERHEATING; then
        COMMENT="CPU 1 and CPU 2 temperatures are too high, Dell default dynamic fan control profile applied for safety"
      else
        COMMENT="CPU temperature is too high, Dell default dynamic fan control profile applied for safety"
      fi
    fi
  else
    # Apply user fan control profile (static or curve mode)
    if [[ "$FAN_CONTROL_MODE" == "curve" ]]; then
      # Curve mode: calculate fan speed from temperature
      MAX_CPU_TEMP=$(get_max_cpu_temperature)
      CALCULATED_FAN_SPEED=$(calculate_fan_speed_from_curve $MAX_CPU_TEMP "$LAST_APPLIED_TEMP_SPEED")
      apply_user_fan_control_profile $CALCULATED_FAN_SPEED
      LAST_APPLIED_TEMP_SPEED="$MAX_CPU_TEMP:$CALCULATED_FAN_SPEED"
    else
      # Static mode: use existing FAN_SPEED (backward compatible)
      apply_user_fan_control_profile
      LAST_APPLIED_TEMP_SPEED=""
    fi

    # Check if user fan control profile is applied then apply it if not
    if $IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED; then
      IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED=false
      COMMENT="CPU temperature decreased and is now OK (<= $CPU_TEMPERATURE_THRESHOLD°C), user's fan control profile applied."
      # Reset last applied temp/speed when switching from Dell default to user profile
      LAST_APPLIED_TEMP_SPEED=""
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
  fi

  # Print temperatures, active fan control profile and comment if any change happened during last time interval
  if [ $TABLE_HEADER_PRINT_COUNTER -eq $TABLE_HEADER_PRINT_INTERVAL ]; then
    printf "%s\n" "$HEADER"
    TABLE_HEADER_PRINT_COUNTER=0
  fi
  print_temperature_array_line "$INLET_TEMPERATURE" "$CPUS_TEMPERATURES" "$EXHAUST_TEMPERATURE" "$CURRENT_FAN_CONTROL_PROFILE" "$THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS" "$COMMENT"
  ((TABLE_HEADER_PRINT_COUNTER++))
  wait $SLEEP_PROCESS_PID
done
