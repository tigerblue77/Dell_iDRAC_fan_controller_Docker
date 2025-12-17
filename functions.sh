# Define global functions
# This function applies Dell's default dynamic fan control profile
function apply_Dell_default_fan_control_profile() {
  # Use ipmitool to send the raw command to set fan control to Dell default
  if ! ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0x30 0x01 0x01 >/dev/null 2>&1; then
    print_error "Failed to apply Dell default fan control profile via IPMI (continuing)"
  fi
  CURRENT_FAN_CONTROL_PROFILE="Dell default dynamic fan control profile"
}

# This function applies a user-specified static fan control profile
# Usage: apply_user_fan_control_profile [speed]
# If speed parameter is provided, use it; otherwise use DECIMAL_FAN_SPEED (backward compatible)
function apply_user_fan_control_profile() {
  local FAN_SPEED_TO_APPLY
  local FAN_SPEED_HEX
  
  if [ $# -eq 1 ]; then
    # Speed parameter provided (curve mode)
    FAN_SPEED_TO_APPLY=$1
    FAN_SPEED_HEX=$(convert_decimal_value_to_hexadecimal "$FAN_SPEED_TO_APPLY")
    CURRENT_FAN_CONTROL_PROFILE="User curve fan control profile ($FAN_SPEED_TO_APPLY%)"
  else
    # No parameter (static mode - backward compatible)
    FAN_SPEED_TO_APPLY=$DECIMAL_FAN_SPEED
    FAN_SPEED_HEX=$HEXADECIMAL_FAN_SPEED
    CURRENT_FAN_CONTROL_PROFILE="User static fan control profile ($DECIMAL_FAN_SPEED%)"
  fi
  
  # Use ipmitool to send the raw command to set fan control to user-specified value
  if ! ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0x30 0x01 0x00 >/dev/null 2>&1; then
    print_error "Failed to set fan control mode via IPMI (continuing)"
  fi

  if ! ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0x30 0x02 0xff $FAN_SPEED_HEX >/dev/null 2>&1; then
    print_error "Failed to set fan speed to $FAN_SPEED_TO_APPLY% ($FAN_SPEED_HEX) via IPMI (continuing)"
  fi
}

# Convert first parameter given ($DECIMAL_NUMBER) to hexadecimal
# Usage : convert_decimal_value_to_hexadecimal $DECIMAL_NUMBER
# Returns : hexadecimal value of DECIMAL_NUMBER (0x00-0x64)
function convert_decimal_value_to_hexadecimal() {
  local -r DECIMAL_NUMBER=$1

  # Validate input is numeric and in range
  if ! [[ "$DECIMAL_NUMBER" =~ ^[0-9]+$ ]] || [ "$DECIMAL_NUMBER" -lt 0 ] || [ "$DECIMAL_NUMBER" -gt 100 ]; then
    echo "0x00"  # Safe fallback
    return 1
  fi

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
    if [ ! -e "/dev/ipmi0" ] && [ ! -e "/dev/ipmi/0" ] && [ ! -e "/dev/ipmidev/0" ]; then
      print_error_and_exit "Could not open device at /dev/ipmi0 or /dev/ipmi/0 or /dev/ipmidev/0, check that you added the device to your Docker container or stop using local mode"
    fi
    IDRAC_LOGIN_STRING='open'
  else
    echo "iDRAC/IPMI username: $IDRAC_USERNAME"
    #echo "iDRAC/IPMI password: $IDRAC_PASSWORD"
    IDRAC_LOGIN_STRING="lanplus -H $IDRAC_HOST -U $IDRAC_USERNAME -P $IDRAC_PASSWORD"
  fi
}

# Retrieve temperature sensors data using ipmitool
# Usage : retrieve_temperatures $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT $IS_CPU2_TEMPERATURE_SENSOR_PRESENT
function retrieve_temperatures() {
  if (( $# != 2 )); then
    print_error "Illegal number of parameters.\nUsage: retrieve_temperatures \$IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT \$IS_CPU2_TEMPERATURE_SENSOR_PRESENT"
    return 1
  fi
  local -r IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT=$1
  local -r IS_CPU2_TEMPERATURE_SENSOR_PRESENT=$2

  # Execute IPMI command with basic error handling
  local DATA=""
  if ! DATA=$(ipmitool -I $IDRAC_LOGIN_STRING sdr type temperature 2>/dev/null | grep degrees); then
    print_error "Failed to retrieve temperature data from IPMI (continuing with defaults)"
    # Set safe defaults but don't fail
    CPU1_TEMPERATURE="50"
    CPU2_TEMPERATURE="-"
    INLET_TEMPERATURE="25"
    EXHAUST_TEMPERATURE="-"
    return 0  # Don't fail, just use defaults
  fi

  # Parse CPU data with basic validation
  local -r CPU_DATA=$(echo "$DATA" | grep "3\." | grep -Po '\d{2}')

  # Extract CPU1 temperature with fallback
  if [ -n "$CPU_DATA" ] && [ $CPU1_TEMPERATURE_INDEX -ge 1 ]; then
    CPU1_TEMPERATURE=$(echo $CPU_DATA | awk "{print \$$CPU1_TEMPERATURE_INDEX;}" 2>/dev/null || echo "50")
  else
    CPU1_TEMPERATURE="50"  # Safe default
  fi

  # Extract CPU2 temperature with fallback
  if $IS_CPU2_TEMPERATURE_SENSOR_PRESENT && [ -n "$CPU_DATA" ] && [ $CPU2_TEMPERATURE_INDEX -ge 1 ]; then
    CPU2_TEMPERATURE=$(echo $CPU_DATA | awk "{print \$$CPU2_TEMPERATURE_INDEX;}" 2>/dev/null || echo "-")
  else
    CPU2_TEMPERATURE="-"
  fi

  # Initialize CPUS_TEMPERATURES
  CPUS_TEMPERATURES="$CPU1_TEMPERATURE"
  NUMBER_OF_DETECTED_CPUS=1

  # If CPU2 is present, parse its temperature data and add it to CPUS_TEMPERATURES
  if [ -n "$CPU2_TEMPERATURE" ]; then
    CPUS_TEMPERATURES+=";$CPU2_TEMPERATURE"
    ((NUMBER_OF_DETECTED_CPUS++))
  fi

  # Parse inlet temperature data
  INLET_TEMPERATURE=$(echo "$DATA" | grep Inlet | grep -Po '\d{2}' | tail -1)

  # If exhaust temperature sensor is present, parse its temperature data
  if $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT; then
    EXHAUST_TEMPERATURE=$(echo "$DATA" | grep Exhaust | grep -Po '\d{2}' | tail -1)
  else
    EXHAUST_TEMPERATURE="-"
  fi
}

# /!\ Use this function only for Gen 13 and older generation servers /!\
function enable_third_party_PCIe_card_Dell_default_cooling_response() {
  # We could check the current cooling response before applying but it's not very useful so let's skip the test and apply directly
  if ! ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0xce 0x00 0x16 0x05 0x00 0x00 0x00 0x05 0x00 0x00 0x00 0x00 >/dev/null 2>&1; then
    print_error "Failed to enable third-party PCIe card cooling response via IPMI (continuing)"
  fi
}

# /!\ Use this function only for Gen 13 and older generation servers /!\
function disable_third_party_PCIe_card_Dell_default_cooling_response() {
  # We could check the current cooling response before applying but it's not very useful so let's skip the test and apply directly
  if ! ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0xce 0x00 0x16 0x05 0x00 0x00 0x00 0x05 0x00 0x01 0x00 0x00 >/dev/null 2>&1; then
    print_error "Failed to disable third-party PCIe card cooling response via IPMI (continuing)"
  fi
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

# Prepare traps in case of container exit
function graceful_exit() {
  apply_Dell_default_fan_control_profile

  # Reset third-party PCIe card cooling response to Dell default depending on the user's choice at startup
  if ! "$KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT"; then
    enable_third_party_PCIe_card_Dell_default_cooling_response
  fi

  print_warning_and_exit "Container stopped, Dell default dynamic fan control profile applied for safety"
}

# Helps debugging when people are posting their output
function get_Dell_server_model() {
  local -r IPMI_FRU_content=$(ipmitool -I $IDRAC_LOGIN_STRING fru 2>/dev/null) # FRU stands for "Field Replaceable Unit"

  SERVER_MANUFACTURER=$(echo "$IPMI_FRU_content" | grep "Product Manufacturer" | awk -F ': ' '{print $2}')
  SERVER_MODEL=$(echo "$IPMI_FRU_content" | grep "Product Name" | awk -F ': ' '{print $2}')

  # Check if SERVER_MANUFACTURER is empty, if yes, assign value based on "Board Mfg"
  if [ -z "$SERVER_MANUFACTURER" ]; then
    SERVER_MANUFACTURER=$(echo "$IPMI_FRU_content" | tr -s ' ' | grep "Board Mfg :" | awk -F ': ' '{print $2}')
  fi

  # Check if SERVER_MODEL is empty, if yes, assign value based on "Board Product"
  if [ -z "$SERVER_MODEL" ]; then
    SERVER_MODEL=$(echo "$IPMI_FRU_content" | tr -s ' ' | grep "Board Product :" | awk -F ': ' '{print $2}')
  fi
}

function build_header() {
  # Check number of arguments
  if [ "$#" -ne 1 ]; then
    print_error "build_header() requires an argument (number_of_CPUs)"
    return 1
  fi

  local -r number_of_CPUs="$1"
  local -r CPU_column_width=7
  local -r Exhaust_column_width=9

  local header="                     ----" # Width ready for 1 CPU

  # Calculate the number of dashes to add on each side of the title
  number_of_dashes=$(((number_of_CPUs-1)*CPU_column_width/2))

  # Loop to add dashes
  for ((i=1; i<=number_of_dashes; i++)); do
    header+="-"
  done

  header+=" Temperatures ---"

  # Check parity and add an extra dash on the right if odd
  if (( (number_of_CPUs - 1) * CPU_column_width % 2 != 0 )); then
    header+="-"
  fi

  # Loop to add dashes
  for ((i=1; i<=number_of_dashes; i++)); do
    header+="-"
  done
  header+=$'\n    Date & time      Inlet  CPU 1 '

  # Loop to add CPU columns
  for ((i=2; i<=number_of_CPUs; i++)); do
    header+=" CPU $i "
  done

  header+=$' Exhaust          Active fan speed profile          Third-party PCIe card Dell default cooling response  Comment'
  printf "%s" "$header"
}

function print_temperature_array_line() {
  local -r LOCAL_INLET_TEMPERATURE="$1"
  local -r LOCAL_CPUS_TEMPERATURES="$2"
  local -r LOCAL_EXHAUST_TEMPERATURE="$3"
  local -r LOCAL_CURRENT_FAN_CONTROL_PROFILE="$4"
  local -r LOCAL_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS="$5"
  local -r LOCAL_COMMENT="$6"

  # Creating an array from the string
  local -r CPUs_temperatures_array=(${LOCAL_CPUS_TEMPERATURES//;/ })

  printf "%19s  %3d°C " "$(date +"%d-%m-%Y %T")" $LOCAL_INLET_TEMPERATURE
  # Itération sur les températures dans le tableau
  for temperature in "${CPUs_temperatures_array[@]}"; do
    printf " %3d°C " $temperature
  done

  printf " %5s°C  %40s  %51s  %s\n" "$LOCAL_EXHAUST_TEMPERATURE" "$LOCAL_CURRENT_FAN_CONTROL_PROFILE" "$LOCAL_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS" "$LOCAL_COMMENT"
}

# Define functions to check if CPU 1 and CPU 2 temperatures are above the threshold
function CPU1_OVERHEATING() {
    [[ "$CPU1_TEMPERATURE" =~ ^[0-9]+$ ]] && [ "$CPU1_TEMPERATURE" -gt "$CPU_TEMPERATURE_THRESHOLD" ];
}
function CPU2_OVERHEATING() {
    [[ "$CPU2_TEMPERATURE" =~ ^[0-9]+$ ]] && [ "$CPU2_TEMPERATURE" -gt "$CPU_TEMPERATURE_THRESHOLD" ];
}

# Get maximum CPU temperature (CPU1 and CPU2 if available)
# Usage: get_max_cpu_temperature
# Returns: Maximum temperature value
function get_max_cpu_temperature() {
    local MAX_TEMP=""

    # Get valid CPU1 temp
    if [[ "$CPU1_TEMPERATURE" =~ ^[0-9]+$ ]]; then
        MAX_TEMP=$CPU1_TEMPERATURE
    else
        MAX_TEMP=50  # Safe default
    fi

    # Compare with CPU2 if valid
    if $IS_CPU2_TEMPERATURE_SENSOR_PRESENT && [[ "$CPU2_TEMPERATURE" =~ ^[0-9]+$ ]]; then
        if [ $CPU2_TEMPERATURE -gt $MAX_TEMP ]; then
            MAX_TEMP=$CPU2_TEMPERATURE
        fi
    fi

    echo $MAX_TEMP
}

# Parse fan curve from CSV format string
# Usage: parse_fan_curve "30:5,40:15,50:30"
# Sets global arrays: FAN_CURVE_TEMPS[] and FAN_CURVE_SPEEDS[]
# Returns: 0 on success, 1 on error (logs error and allows fallback)
function parse_fan_curve() {
  local -r CURVE_STRING="$1"

  if [ -z "$CURVE_STRING" ]; then
    log_curve_error "FAN_CURVE is required when FAN_CONTROL_MODE=curve"
    return 1
  fi

  # Clear and initialize arrays
  FAN_CURVE_TEMPS=()
  FAN_CURVE_SPEEDS=()
  declare -g FAN_CURVE_TEMPS FAN_CURVE_SPEEDS

  # Split by comma and process each pair
  IFS=',' read -ra PAIRS <<< "$CURVE_STRING"

  if [ ${#PAIRS[@]} -lt 2 ]; then
    log_curve_error "FAN_CURVE must contain at least 2 temperature:speed pairs"
    return 1
  fi

  # Parse each pair
  for pair in "${PAIRS[@]}"; do
    # Remove whitespace
    pair=$(echo "$pair" | tr -d '[:space:]')

    # Check format (should be temp:speed)
    if [[ ! "$pair" =~ ^[0-9]+:[0-9]+$ ]]; then
      log_curve_error "Invalid FAN_CURVE format: '$pair'. Expected format: temp:speed (e.g., 30:5)"
      return 1
    fi

    local TEMP=$(echo "$pair" | cut -d':' -f1)
    local SPEED=$(echo "$pair" | cut -d':' -f2)

    # Validate ranges
    if [ $TEMP -lt 0 ] || [ $TEMP -gt 100 ]; then
      log_curve_error "Invalid temperature in FAN_CURVE: $TEMP. Must be between 0 and 100"
      return 1
    fi

    if [ $SPEED -lt 0 ] || [ $SPEED -gt 100 ]; then
      log_curve_error "Invalid speed in FAN_CURVE: $SPEED. Must be between 0 and 100"
      return 1
    fi

    # Check for duplicate temperatures
    for existing_temp in "${FAN_CURVE_TEMPS[@]}"; do
      if [ $existing_temp -eq $TEMP ]; then
        log_curve_error "Duplicate temperature in FAN_CURVE: $TEMP"
        return 1
      fi
    done

    FAN_CURVE_TEMPS+=($TEMP)
    FAN_CURVE_SPEEDS+=($SPEED)
  done

  # Validate array lengths match
  local temp_count=${#FAN_CURVE_TEMPS[@]}
  local speed_count=${#FAN_CURVE_SPEEDS[@]}
  if [ $temp_count -ne $speed_count ]; then
    log_curve_error "FAN_CURVE parsing error: temperature and speed arrays have different lengths"
    return 1
  fi

  # Sort arrays by temperature (bubble sort for simplicity)
  for ((i=0; i<temp_count-1; i++)); do
    for ((j=0; j<temp_count-i-1; j++)); do
      # Validate array access
      if [ $j -ge 0 ] && [ $j -lt $temp_count ] && [ $((j+1)) -lt $temp_count ]; then
        if [ ${FAN_CURVE_TEMPS[j]} -gt ${FAN_CURVE_TEMPS[j+1]} ]; then
          # Swap temperatures
          local temp=${FAN_CURVE_TEMPS[j]}
          FAN_CURVE_TEMPS[j]=${FAN_CURVE_TEMPS[j+1]}
          FAN_CURVE_TEMPS[j+1]=$temp

          # Swap speeds
          local speed=${FAN_CURVE_SPEEDS[j]}
          FAN_CURVE_SPEEDS[j]=${FAN_CURVE_SPEEDS[j+1]}
          FAN_CURVE_SPEEDS[j+1]=$speed
        fi
      fi
    done
  done

  return 0  # Success
}

# Calculate fan speed from curve based on current temperature
# Usage: calculate_fan_speed_from_curve current_temp [last_applied_temp:last_applied_speed]
# Returns: Calculated fan speed (0-100)
function calculate_fan_speed_from_curve() {
  local -r CURRENT_TEMP=$1
  local LAST_APPLIED_TEMP_SPEED=${2:-}

  # Validate input temperature
  if ! [[ "$CURRENT_TEMP" =~ ^[0-9]+$ ]] || [ "$CURRENT_TEMP" -lt -50 ] || [ "$CURRENT_TEMP" -gt 150 ]; then
    # Invalid temperature, return safe default
    echo 20
    return
  fi

  # Safety check: ensure curve arrays exist and have data
  if [ ${#FAN_CURVE_TEMPS[@]} -eq 0 ] || [ ${#FAN_CURVE_SPEEDS[@]} -eq 0 ]; then
    # Curve data corrupted, return safe default
    echo 20
    return
  fi

  local CURVE_SIZE=${#FAN_CURVE_TEMPS[@]}
  
  # If temperature is below lowest point, use lowest speed
  if [ $CURRENT_TEMP -le ${FAN_CURVE_TEMPS[0]} ]; then
    echo ${FAN_CURVE_SPEEDS[0]}
    return
  fi
  
  # If temperature is above highest point, use highest speed
  local LAST_INDEX=$((CURVE_SIZE - 1))
  if [ $CURRENT_TEMP -ge ${FAN_CURVE_TEMPS[$LAST_INDEX]} ]; then
    echo ${FAN_CURVE_SPEEDS[$LAST_INDEX]}
    return
  fi
  
  # Find the two points to interpolate between
  local LOWER_TEMP=""
  local LOWER_SPEED=""
  local UPPER_TEMP=""
  local UPPER_SPEED=""

  # Find the appropriate segment
  for ((i=0; i<CURVE_SIZE-1; i++)); do
    # Validate array access
    if [ $i -ge 0 ] && [ $i -lt $CURVE_SIZE ] && [ $((i+1)) -lt $CURVE_SIZE ]; then
      local temp_i=${FAN_CURVE_TEMPS[i]}
      local temp_next=${FAN_CURVE_TEMPS[i+1]}

      if [ $CURRENT_TEMP -ge $temp_i ] && [ $CURRENT_TEMP -le $temp_next ]; then
        LOWER_TEMP=$temp_i
        LOWER_SPEED=${FAN_CURVE_SPEEDS[i]}
        UPPER_TEMP=$temp_next
        UPPER_SPEED=${FAN_CURVE_SPEEDS[i+1]}
        break
      fi
    fi
  done

  # If no segment found (shouldn't happen with proper bounds checking above), use safe defaults
  if [ -z "$LOWER_TEMP" ] || [ -z "$UPPER_TEMP" ]; then
    echo ${FAN_CURVE_SPEEDS[0]}
    return
  fi
  
  # Calculate interpolated speed
  local TEMP_DIFF=$((UPPER_TEMP - LOWER_TEMP))
  local SPEED_DIFF=$((UPPER_SPEED - LOWER_SPEED))
  local TEMP_OFFSET=$((CURRENT_TEMP - LOWER_TEMP))
  
  # Avoid division by zero
  if [ $TEMP_DIFF -eq 0 ]; then
    echo $LOWER_SPEED
    return
  fi
  
  # Safe linear interpolation with bounds checking
  local INTERPOLATED_SPEED=""
  if [ $TEMP_DIFF -gt 0 ]; then
    # Calculate: lower_speed + (temp_offset * speed_diff / temp_diff)
    # Use intermediate calculation to avoid integer overflow
    local TEMP_RATIO=$((TEMP_OFFSET * SPEED_DIFF))
    if [ $SPEED_DIFF -ge 0 ]; then
      INTERPOLATED_SPEED=$((LOWER_SPEED + (TEMP_RATIO / TEMP_DIFF)))
    else
      INTERPOLATED_SPEED=$((LOWER_SPEED + (TEMP_RATIO / TEMP_DIFF)))
    fi
  else
    INTERPOLATED_SPEED=$LOWER_SPEED
  fi

  # Ensure result is within bounds (0-100)
  if [ "$INTERPOLATED_SPEED" -lt 0 ] 2>/dev/null; then
    INTERPOLATED_SPEED=0
  elif [ "$INTERPOLATED_SPEED" -gt 100 ] 2>/dev/null; then
    INTERPOLATED_SPEED=100
  fi

  # Apply hysteresis if configured and we have valid previous data
  if [ "$FAN_CURVE_HYSTERESIS" -gt 0 ] && [ -n "$LAST_APPLIED_TEMP_SPEED" ]; then
    # Parse the last applied data safely
    local LAST_TEMP=""
    local LAST_SPEED=""

    # Use more robust parsing
    if [[ "$LAST_APPLIED_TEMP_SPEED" =~ ^([0-9]+):([0-9]+)$ ]]; then
      LAST_TEMP="${BASH_REMATCH[1]}"
      LAST_SPEED="${BASH_REMATCH[2]}"
    else
      # Invalid format, skip hysteresis
      echo $INTERPOLATED_SPEED
      return
    fi

    # Validate parsed values
    if ! [[ "$LAST_TEMP" =~ ^[0-9]+$ ]] || ! [[ "$LAST_SPEED" =~ ^[0-9]+$ ]] || \
       [ "$LAST_TEMP" -lt 0 ] || [ "$LAST_TEMP" -gt 200 ] || \
       [ "$LAST_SPEED" -lt 0 ] || [ "$LAST_SPEED" -gt 100 ]; then
      # Invalid data, skip hysteresis
      echo $INTERPOLATED_SPEED
      return
    fi

    # Calculate absolute temperature difference
    local TEMP_DIFF_FROM_LAST=$((CURRENT_TEMP - LAST_TEMP))
    # Handle negative numbers properly in bash
    local ABS_TEMP_DIFF=$((TEMP_DIFF_FROM_LAST < 0 ? -TEMP_DIFF_FROM_LAST : TEMP_DIFF_FROM_LAST))

    # Only apply new speed if temperature has changed by hysteresis amount or more
    if [ $ABS_TEMP_DIFF -ge $FAN_CURVE_HYSTERESIS ]; then
      echo $INTERPOLATED_SPEED
    else
      echo $LAST_SPEED
    fi
  else
    # No hysteresis or first run - apply calculated speed
    echo $INTERPOLATED_SPEED
  fi
}

function print_error() {
  local -r ERROR_MESSAGE="$1"
  printf "/!\ Error /!\ %s." "$ERROR_MESSAGE" >&2
}

function print_error_and_exit() {
  local -r ERROR_MESSAGE="$1"
  print_error "$ERROR_MESSAGE"
  printf " Exiting.\n" >&2
  exit 1
}

# Log curve error and return error code (don't exit)
# Usage: log_curve_error "error message"
# Returns: 1 (error)
function log_curve_error() {
  local -r ERROR_MESSAGE="$1"
  print_error "$ERROR_MESSAGE"
  printf " Falling back to static fan control mode.\n" >&2
  return 1
}

function print_warning() {
  local -r WARNING_MESSAGE="$1"
  printf "/!\ Warning /!\ %s." "$WARNING_MESSAGE"
}

function print_warning_and_exit() {
  local -r WARNING_MESSAGE="$1"
  print_warning "$WARNING_MESSAGE"
  printf " Exiting.\n"
  exit 0
}
