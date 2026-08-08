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

# Stop the container unless the given parameter is a duration sleep can actually wait for
# Usage : validate_check_interval_parameter "$PARAMETER_NAME" "$VALUE"
#
# CHECK_INTERVAL is the monitoring loop's only pacing mechanism and reaches sleep as unchecked text.
# The loop starts the timer in background then waits on its PID without ever looking at what wait
# hands back, so nothing notices a sleep that refused to run : the cycle returns at once and the loop
# runs at full speed, sending the 5 IPMI commands a cycle costs over LAN (4 locally, one fewer on
# Gen 14 and newer) as fast as ipmitool completes them, with nothing in the log but sleep's own
# two-line complaint each time.
#
# The Dockerfile's ENV CHECK_INTERVAL is a default, not a guarantee : any entry the user supplies for
# the same key replaces it. Measured on Docker 29 and Compose v5, "-e CHECK_INTERVAL=", an --env-file
# or compose line with nothing after the "=", and a compose "${CHECK_INTERVAL}" resolving to nothing
# all arrive as an empty string, while a bare "-e CHECK_INTERVAL" whose host variable is unset drops
# the variable altogether, which expands to the empty string just the same since strict bash mode is
# disabled. The likeliest case isn't empty at all : docker takes everything after the "=" verbatim, so
# an unfilled .env placeholder arrives as the literal "<seconds between each check>" text.
#
# GNU sleep accepts a unit suffix, so "90s" and "5m" do wait and are working configurations today.
# They stay accepted here : rejecting a value that has been pacing a container correctly all along
# would break it for no benefit. The fractional values sleep also accepts ("0.5") are refused all the
# same, a sub-second cycle being exactly the hammering this check exists to prevent.
#
# This function must be called as a statement, never through a command substitution : the exit inside
# print_error_and_exit would otherwise only leave the subshell and the container would keep running
function validate_check_interval_parameter() {
  local -r PARAMETER_NAME="$1"
  local -r VALUE="$2"

  if [[ ! "$VALUE" =~ ^[0-9]+[smhd]?$ ]]; then
    print_error_and_exit "$PARAMETER_NAME must be a number of seconds, optionally suffixed with s, m, h or d, but is \"$VALUE\""
  fi

  # Zero is the third failing case, and the only one sleep itself accepts : it parses fine, returns
  # immediately, and spins the loop just like an unparseable value. It is therefore rejected on its own
  # terms rather than on its format. The suffix is stripped and 10# forces base 10 so that a padded
  # value ("00", "08") is read as the decimal number the user meant instead of an invalid octal one
  if [ "$((10#${VALUE%[smhd]}))" -eq 0 ]; then
    print_error_and_exit "$PARAMETER_NAME must be greater than zero, but is \"$VALUE\""
  fi
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

# Extract a single temperature reading from ipmitool sdr output, located by its sensor name
# Usage : retrieve_temperature_by_sensor_name "$SDR_DATA" "$SENSOR_NAME"
# Returns : the temperature in degrees Celsius, or an empty string if no such sensor has a reading
#
# Inlet and exhaust are both reported as entity 7.1 on Dell servers, so their name is the only thing
# telling them apart and they cannot use retrieve_temperature_by_entity_id()
function retrieve_temperature_by_sensor_name() {
  local -r SDR_DATA="$1"
  local -r SENSOR_NAME="$2"

  # On the (unexpected) event of several sensors matching the name, the last one wins, as it did when
  # the reading was picked with "grep -Po ... | tail -1"
  local -r SDR_LINE=$(echo "$SDR_DATA" | grep "$SENSOR_NAME" | tail -1)

  extract_temperature_from_sdr_line "$SDR_LINE"
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

  # stderr is discarded here: this is a read-only diagnostic call (it never changes fan behavior) and some
  # iDRAC/BMC firmwares print a harmless protocol warning on every call even though the reading succeeds
  local -r DATA=$(ipmitool -I $IDRAC_LOGIN_STRING sdr type temperature 2>/dev/null | grep degrees)

  # Parse CPU data, each CPU being located by its IPMI entity ID (3.1 is CPU 1, 3.2 is CPU 2)
  CPU1_TEMPERATURE=$(retrieve_temperature_by_entity_id "$DATA" "3.1")
  if $IS_CPU2_TEMPERATURE_SENSOR_PRESENT; then
    CPU2_TEMPERATURE=$(retrieve_temperature_by_entity_id "$DATA" "3.2")
  else
    CPU2_TEMPERATURE="-"
  fi

  # Initialize CPUS_TEMPERATURES. An unreadable CPU 1 reading falls back to the "-" placeholder so that it
  # still takes up its column when the line is printed : CPUS_TEMPERATURES is split on whitespace to build
  # the display array, so an empty value would be dropped and shift every following column to the left.
  # CPU1_TEMPERATURE itself is left untouched, CPU1_OVERHEATING() must still see the invalid reading
  CPUS_TEMPERATURES="${CPU1_TEMPERATURE:--}"
  NUMBER_OF_DETECTED_CPUS=1

  # If CPU2 is present, parse its temperature data and add it to CPUS_TEMPERATURES.
  # "-" is the placeholder set above when the sensor is known to be absent, so it must not be counted as a
  # detected CPU: otherwise servers without a CPU2 sensor get an extra column that the header, built once
  # from the first reading (when the placeholder isn't set yet), doesn't account for
  if [ -n "$CPU2_TEMPERATURE" ] && [ "$CPU2_TEMPERATURE" != "-" ]; then
    CPUS_TEMPERATURES+=";$CPU2_TEMPERATURE"
    ((NUMBER_OF_DETECTED_CPUS++))
  fi

  # Parse inlet temperature data, the sensor being located by its name
  INLET_TEMPERATURE=$(retrieve_temperature_by_sensor_name "$DATA" "Inlet")

  # If exhaust temperature sensor is present, parse its temperature data
  if $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT; then
    EXHAUST_TEMPERATURE=$(retrieve_temperature_by_sensor_name "$DATA" "Exhaust")
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

  # Whether the server could be identified is the reliable signal here, not ipmitool's
  # exit code : "ipmitool fru" walks every FRU device and returns non-zero as soon as a
  # single one of them fails to read, which is the normal state of healthy hardware.
  # An unpopulated drive backplane or PSU bay answers "Device not present (Timeout)"
  # while the builtin FRU device (ID 0) still returns the manufacturer and the model, so
  # exiting on the exit code alone refused to start on servers that were perfectly fine.
  if [ -z "$SERVER_MANUFACTURER" ] && [ -z "$SERVER_MODEL" ]; then
    print_error_and_exit "Could not establish IPMI connection to iDRAC/IPMI host \"$IDRAC_HOST\". Check that IDRAC_HOST, IDRAC_USERNAME and IDRAC_PASSWORD are correct. ipmitool exited with code $ipmitool_exit_code and said: $IPMI_FRU_content"
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

  # Exhaust goes through the same formatter as the other three temperature columns, so that a reading
  # that failed on this cycle shows the "-" placeholder rather than an empty column reading as "°C"
  printf " %5s°C  %40s  %51s  %s\n" "$(format_temperature_for_display "$LOCAL_EXHAUST_TEMPERATURE")" "$LOCAL_CURRENT_FAN_CONTROL_PROFILE" "$LOCAL_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS" "$LOCAL_COMMENT"
}

# Formats a temperature reading as a right-aligned, 3-character-wide decimal number for display.
# Falls back to "  -" instead of letting printf %d crash when the reading is empty, a placeholder ("-"),
# or has a leading zero that would otherwise be misinterpreted as an invalid octal number (e.g. "09").
# Sub-zero readings are values in their own right, not invalid ones, so they keep their sign
function format_temperature_for_display() {
  local -r VALUE="$1"
  if is_temperature_reading_valid "$VALUE"; then
    printf '%3d' "$(normalize_decimal_value "$VALUE")"
  else
    printf '%3s' "-"
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

# Define functions to check if CPU 1 and CPU 2 temperatures are above the threshold.
# If a reading isn't valid, fail safe and report overheating so the Dell default fan control profile
# kicks in, instead of crashing (bash's "-gt" throws "unary operator expected" on empty/non-numeric
# input) or silently running the low user fan speed on unverified data
function CPU1_OVERHEATING() {
  is_temperature_reading_valid "$CPU1_TEMPERATURE" || return 0
  [ "$(normalize_decimal_value "$CPU1_TEMPERATURE")" -gt "$CPU_TEMPERATURE_THRESHOLD" ]
}
function CPU2_OVERHEATING() {
  is_temperature_reading_valid "$CPU2_TEMPERATURE" || return 0
  [ "$(normalize_decimal_value "$CPU2_TEMPERATURE")" -gt "$CPU_TEMPERATURE_THRESHOLD" ]
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

# Build the comment explaining why the Dell default fan control profile was applied.
# Usage : build_fan_control_fallback_comment $CPU_NAME $CPU_TEMPERATURE [$CPU_NAME $CPU_TEMPERATURE]...
#
# CPU1_OVERHEATING()/CPU2_OVERHEATING() deliberately return true both when a CPU is genuinely too hot
# and when its reading is unusable, so an unverifiable temperature still falls back to Dell's profile.
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

  echo "$(join_with_and "${reasons[@]}"), Dell default dynamic fan control profile applied for safety"
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
