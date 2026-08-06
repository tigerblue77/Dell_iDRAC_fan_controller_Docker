# Define global functions
# This function applies Dell's default dynamic fan control profile
# In monitoring only mode, the profile is only logged, not actually applied
function apply_Dell_default_fan_control_profile() {
  if $MONITORING_ONLY_MODE; then
    CURRENT_FAN_CONTROL_PROFILE="Dell default dynamic fan control profile (monitoring only, not applied)"
    return
  fi
  # Use ipmitool to send the raw command to set fan control to Dell default.
  # Some iDRAC/BMC firmwares print a harmless protocol warning on stderr (e.g. "Received an Unexpected
  # message...") even when the command actually succeeds. Rather than discard stderr unconditionally (which
  # would also hide a genuine failure to apply this safety-critical profile), capture it and only surface it
  # if the command actually failed (non-zero exit code)
  local ipmitool_stderr
  ipmitool_stderr=$(ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0x30 0x01 0x01 2>&1 >/dev/null)
  if [ $? -ne 0 ]; then
    print_error "Failed to apply Dell default fan control profile. ipmitool said: $ipmitool_stderr"
  fi
  CURRENT_FAN_CONTROL_PROFILE="Dell default dynamic fan control profile"
}

# This function applies a user-specified static fan control profile
# In monitoring only mode, the profile is only logged, not actually applied
function apply_user_fan_control_profile() {
  if $MONITORING_ONLY_MODE; then
    CURRENT_FAN_CONTROL_PROFILE="User static fan control profile ($DECIMAL_FAN_SPEED%) (monitoring only, not applied)"
    return
  fi
  # Use ipmitool to send the raw command to set fan control to user-specified value.
  # Same reasoning as apply_Dell_default_fan_control_profile: only surface stderr if the command
  # actually failed, instead of always discarding it (this profile changes real fan speed)
  local ipmitool_stderr
  ipmitool_stderr=$(ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0x30 0x01 0x00 2>&1 >/dev/null)
  if [ $? -ne 0 ]; then
    print_error "Failed to enable manual fan control. ipmitool said: $ipmitool_stderr"
  fi
  ipmitool_stderr=$(ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0x30 0x02 0xff $HEXADECIMAL_FAN_SPEED 2>&1 >/dev/null)
  if [ $? -ne 0 ]; then
    print_error "Failed to set fan speed to $DECIMAL_FAN_SPEED%. ipmitool said: $ipmitool_stderr"
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
    # Pass the password via the IPMI_PASSWORD environment variable (-E) instead of the command line (-P)
    # so it never appears in the container's process list (e.g. `ps aux`, /proc/<pid>/cmdline) or logs
    export IPMI_PASSWORD="$IDRAC_PASSWORD"
    IDRAC_LOGIN_STRING="lanplus -H $IDRAC_HOST -U $IDRAC_USERNAME -E"
  fi
}

# Extract a single temperature reading from ipmitool sdr output, located by its IPMI entity ID
# Usage : retrieve_temperature_by_entity_id "$SDR_DATA" $ENTITY_ID
# Returns : the temperature in degrees Celsius, or an empty string if that entity has no reading
#
# An sdr line looks like "Temp             | 09h | ok  |  3.1 | 45 degrees C", the 4th pipe-delimited
# column being the entity ID. Entity 3 is the processor, so 3.1 is CPU 1, 3.2 is CPU 2, and so on.
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

  # The reading is matched on the "degrees" suffix rather than on a fixed two-digit width, so that an
  # overheating CPU reporting three digits isn't truncated : "100 degrees C" used to be read as 10°C,
  # silently keeping the user's low fan speed on a CPU that needed the Dell default profile
  echo "$SDR_DATA" | awk -F'|' -v entity="$ENTITY_ID" '
    { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $4) }
    $4 == entity { print $5; exit }' | grep -Po '\d+(?=[[:space:]]*degrees)'
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

# Detect the CPU temperature sensors the server exposes, once, at startup
# Usage : detect_CPU_temperature_sensors "$SDR_DATA"
# Returns : populates the DETECTED_CPU_ENTITY_IDS global array, in CPU order
#
# Entity 3 is the processor, so the sockets are exposed as 3.1, 3.2, ... Probing stops at the first
# missing entity: Dell populates sockets in order, so a gap means there is no further CPU. This also
# keeps the "CPU N" column labels aligned with the entity sub-IDs they are read from
function detect_CPU_temperature_sensors() {
  local -r SDR_DATA="$1"

  DETECTED_CPU_ENTITY_IDS=()
  local CPU_NUMBER
  for ((CPU_NUMBER=1; CPU_NUMBER<=MAXIMUM_SUPPORTED_NUMBER_OF_CPUS; CPU_NUMBER++)); do
    if [ -z "$(retrieve_temperature_by_entity_id "$SDR_DATA" "3.$CPU_NUMBER")" ]; then
      break
    fi
    DETECTED_CPU_ENTITY_IDS+=("3.$CPU_NUMBER")
  done
}

# Retrieve temperature sensors data using ipmitool
# Usage : retrieve_temperatures $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT
function retrieve_temperatures() {
  if (( $# != 1 )); then
    print_error "Illegal number of parameters.\nUsage: retrieve_temperatures \$IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT"
    return 1
  fi
  local -r IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT=$1

  local -r DATA=$(retrieve_sdr_temperature_data)

  # Parse every CPU detected at startup, each one being located by its IPMI entity ID.
  # CPU_TEMPERATURES holds the raw readings, indexed by CPU number minus one, and is what
  # is_any_CPU_overheating() evaluates : a reading left empty by a transient IPMI glitch must reach it
  # untouched so it can fail safe on it.
  # CPUS_TEMPERATURES is the display string, in which an unreadable reading falls back to the "-"
  # placeholder so that it still takes up its column when the line is printed : it is split to build the
  # display array, so an empty value would be dropped and shift every following column to the left
  CPU_TEMPERATURES=()
  CPUS_TEMPERATURES=""
  local ENTITY_ID CPU_TEMPERATURE
  for ENTITY_ID in "${DETECTED_CPU_ENTITY_IDS[@]}"; do
    CPU_TEMPERATURE=$(retrieve_temperature_by_entity_id "$DATA" "$ENTITY_ID")
    CPU_TEMPERATURES+=("$CPU_TEMPERATURE")

    if [ -n "$CPUS_TEMPERATURES" ]; then
      CPUS_TEMPERATURES+=";"
    fi
    CPUS_TEMPERATURES+="${CPU_TEMPERATURE:--}"
  done

  # Parse inlet temperature data
  INLET_TEMPERATURE=$(echo "$DATA" | grep Inlet | cut -d'|' -f5 | grep -Po '\d{2}' | tail -1)

  # If exhaust temperature sensor is present, parse its temperature data
  if $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT; then
    EXHAUST_TEMPERATURE=$(echo "$DATA" | grep Exhaust | cut -d'|' -f5 | grep -Po '\d{2}' | tail -1)
  else
    EXHAUST_TEMPERATURE="-"
  fi
}

# Returns 0 (true) if the target server is currently powered on, 1 (false) otherwise
# Only meaningful in network mode: in local mode the container runs on the target server itself,
# so it cannot be observed powered off while the container is running
function is_server_powered_on() {
  local -r POWER_STATUS=$(ipmitool -I $IDRAC_LOGIN_STRING chassis power status 2>/dev/null)
  [[ "$POWER_STATUS" == *"is on"* ]]
}

# /!\ Use this function only for Gen 13 and older generation servers /!\
# In monitoring only mode, this is a no-op
function enable_third_party_PCIe_card_Dell_default_cooling_response() {
  if $MONITORING_ONLY_MODE; then
    return
  fi
  # We could check the current cooling response before applying but it's not very useful so let's skip the test and apply directly
  # Unlike the fan speed control commands, stderr IS unconditionally discarded here: on hardware/firmware
  # that doesn't support this Dell OEM command at all, it fails the exact same way ("Invalid command") on
  # every single cycle forever. That's a deterministic, permanent, non-actionable failure (not a transient
  # glitch), and this setting is a non-safety-critical cosmetic cooling response, not core CPU fan control
  # -- so surfacing it every cycle would just recreate the original log-spam problem for no benefit
  ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0xce 0x00 0x16 0x05 0x00 0x00 0x00 0x05 0x00 0x00 0x00 0x00 > /dev/null 2>&1
}

# /!\ Use this function only for Gen 13 and older generation servers /!\
# In monitoring only mode, this is a no-op
function disable_third_party_PCIe_card_Dell_default_cooling_response() {
  if $MONITORING_ONLY_MODE; then
    return
  fi
  # We could check the current cooling response before applying but it's not very useful so let's skip the test and apply directly
  # Unlike the fan speed control commands, stderr IS unconditionally discarded here: on hardware/firmware
  # that doesn't support this Dell OEM command at all, it fails the exact same way ("Invalid command") on
  # every single cycle forever. That's a deterministic, permanent, non-actionable failure (not a transient
  # glitch), and this setting is a non-safety-critical cosmetic cooling response, not core CPU fan control
  # -- so surfacing it every cycle would just recreate the original log-spam problem for no benefit
  ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0xce 0x00 0x16 0x05 0x00 0x00 0x00 0x05 0x00 0x01 0x00 0x00 > /dev/null 2>&1
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
  if $MONITORING_ONLY_MODE; then
    print_warning_and_exit "Container stopped (monitoring only mode, no fan control profile was ever applied)"
  fi

  apply_Dell_default_fan_control_profile

  # Reset third-party PCIe card cooling response to Dell default depending on the user's choice at startup
  if ! "$KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT"; then
    enable_third_party_PCIe_card_Dell_default_cooling_response
  fi

  print_warning_and_exit "Container stopped, Dell default dynamic fan control profile applied for safety"
}

# Helps debugging when people are posting their output
function get_Dell_server_model() {
  local IPMI_FRU_content
  # FRU stands for "Field Replaceable Unit". Capture stderr too so a failed IPMI connection can be reported instead of silently discarded
  IPMI_FRU_content=$(ipmitool -I $IDRAC_LOGIN_STRING fru 2>&1)
  local -r ipmitool_exit_code=$?

  if [ $ipmitool_exit_code -ne 0 ]; then
    print_error_and_exit "Could not establish IPMI connection to iDRAC/IPMI host \"$IDRAC_HOST\". Check that IDRAC_HOST, IDRAC_USERNAME and IDRAC_PASSWORD are correct. ipmitool said: $IPMI_FRU_content"
  fi

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

  printf "%19s  %s°C " "$(date +"%d-%m-%Y %T")" "$(format_temperature_for_display "$LOCAL_INLET_TEMPERATURE")"
  # Itération sur les températures dans le tableau
  for temperature in "${CPUs_temperatures_array[@]}"; do
    printf " %s°C " "$(format_temperature_for_display "$temperature")"
  done

  printf " %5s°C  %40s  %51s  %s\n" "$LOCAL_EXHAUST_TEMPERATURE" "$LOCAL_CURRENT_FAN_CONTROL_PROFILE" "$LOCAL_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS" "$LOCAL_COMMENT"
}

# Formats a temperature reading as a right-aligned, 3-character-wide decimal number for display.
# Falls back to "  -" instead of letting printf %d crash when the reading is empty, a placeholder ("-"),
# or has a leading zero that would otherwise be misinterpreted as an invalid octal number (e.g. "09")
function format_temperature_for_display() {
  local -r VALUE="$1"
  if [[ "$VALUE" =~ ^[0-9]+$ ]]; then
    printf '%3d' "$((10#$VALUE))"
  else
    printf '%3s' "-"
  fi
}

# Enumerates CPU labels the way a human would : "CPU 1", "CPU 1 and CPU 2", "CPU 1, CPU 2 and CPU 4"
# Usage : format_CPU_list_for_display "CPU 1" "CPU 3"
function format_CPU_list_for_display() {
  local -r -a CPU_LABELS=("$@")
  local -r LAST_INDEX=$(( ${#CPU_LABELS[@]} - 1 ))
  local RESULT=""
  local INDEX

  for ((INDEX=0; INDEX<=LAST_INDEX; INDEX++)); do
    if (( INDEX == 0 )); then
      RESULT="${CPU_LABELS[INDEX]}"
    elif (( INDEX == LAST_INDEX )); then
      RESULT+=" and ${CPU_LABELS[INDEX]}"
    else
      RESULT+=", ${CPU_LABELS[INDEX]}"
    fi
  done

  printf '%s' "$RESULT"
}

# Checks whether any of the detected CPUs is above the temperature threshold.
# Returns 0 (true) if at least one is, and sets OVERHEATING_REASON to a ready-to-log clause naming the
# CPUs concerned ("CPU 3 temperature is too high", "CPU 1 and CPU 3 temperatures are too high"), so the
# log line can tell the user which CPU actually triggered the switch.
#
# Every detected CPU is evaluated, not just the first two : on a 4-socket server (R930, R830...) CPU 3
# and CPU 4 used to be read by nobody, so they could cross the threshold while the controller happily
# kept the user's low fan speed running.
#
# If a reading isn't a valid number (missing sensor, transient IPMI parsing glitch, etc.), fail safe and
# report overheating so the Dell default fan control profile kicks in, instead of crashing (bash's "-gt"
# throws "unary operator expected" on empty/non-numeric input) or silently running the low user fan speed
# on unverified data
function is_any_CPU_overheating() {
  # No CPU sensor at all means nothing can be verified, so fail safe rather than trust the absence of data
  if (( ${#CPU_TEMPERATURES[@]} == 0 )); then
    OVERHEATING_REASON="No CPU temperature could be read"
    return 0
  fi

  local -a OVERHEATING_CPU_LABELS=()
  local INDEX CPU_TEMPERATURE

  for INDEX in "${!CPU_TEMPERATURES[@]}"; do
    CPU_TEMPERATURE="${CPU_TEMPERATURES[INDEX]}"
    if [[ ! "$CPU_TEMPERATURE" =~ ^[0-9]+$ ]] || [ "$((10#$CPU_TEMPERATURE))" -gt "$CPU_TEMPERATURE_THRESHOLD" ]; then
      OVERHEATING_CPU_LABELS+=("CPU $((INDEX + 1))")
    fi
  done

  local -r NUMBER_OF_OVERHEATING_CPUS=${#OVERHEATING_CPU_LABELS[@]}
  if (( NUMBER_OF_OVERHEATING_CPUS == 0 )); then
    OVERHEATING_REASON=""
    return 1
  fi

  OVERHEATING_REASON="$(format_CPU_list_for_display "${OVERHEATING_CPU_LABELS[@]}") temperature"
  if (( NUMBER_OF_OVERHEATING_CPUS > 1 )); then
    OVERHEATING_REASON+="s are too high"
  else
    OVERHEATING_REASON+=" is too high"
  fi
  return 0
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
