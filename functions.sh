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

  # On Dell the entity instance is the socket number, so it is used as-is to label the column. IPMI
  # allows instance 0 though, which would label the first processor "CPU 0", so a BMC numbering from
  # zero gets its labels shifted back to the 1-based numbering users expect
  local LABEL_OFFSET=0
  if (( ${#CPU_ENTITY_INSTANCES[@]} > 0 )) && (( CPU_ENTITY_INSTANCES[0] == 0 )); then
    LABEL_OFFSET=1
  fi

  DETECTED_CPU_ENTITY_IDS=()
  DETECTED_CPU_LABELS=()
  local CPU_ENTITY_INSTANCE
  for CPU_ENTITY_INSTANCE in "${CPU_ENTITY_INSTANCES[@]}"; do
    DETECTED_CPU_ENTITY_IDS+=("3.$CPU_ENTITY_INSTANCE")
    DETECTED_CPU_LABELS+=("CPU $((CPU_ENTITY_INSTANCE + LABEL_OFFSET))")
  done
}

# Runs the detection again on already-fetched sensor data and reports whether a CPU showed up.
# Usage : refresh_CPU_temperature_sensors "$SDR_DATA"
# Returns : 0 (true) if a CPU was added, the DETECTED_CPU_* arrays then describing the new set
#
# The point is the server being powered off to add a CPU : keeping the set detected before the outage
# would leave that CPU both invisible in the table and, far worse, never compared to the threshold.
#
# The monitored set only ever grows, and the new one is adopted only when it still contains every CPU
# already being monitored. A server answering as powered on can still be POSTing, exposing part of its
# sockets as "Disabled", and Dell reports a depopulated socket in exactly the same way : the two cannot
# be told apart from the SDR, so shrinking on that basis would silently stop watching CPUs that are
# merely not readable yet. A CPU that really was removed keeps its column, reading "-", which fails safe
# to the Dell default profile until the container is restarted
function refresh_CPU_temperature_sensors() {
  local -r SDR_DATA="$1"
  local -r -a PREVIOUS_CPU_ENTITY_IDS=("${DETECTED_CPU_ENTITY_IDS[@]}")
  local -r -a PREVIOUS_CPU_LABELS=("${DETECTED_CPU_LABELS[@]}")

  detect_CPU_temperature_sensors "$SDR_DATA"

  # Entity IDs hold no space, so the padded-join membership test is unambiguous
  local PREVIOUS_CPU_ENTITY_ID
  for PREVIOUS_CPU_ENTITY_ID in "${PREVIOUS_CPU_ENTITY_IDS[@]}"; do
    if [[ " ${DETECTED_CPU_ENTITY_IDS[*]} " != *" $PREVIOUS_CPU_ENTITY_ID "* ]]; then
      DETECTED_CPU_ENTITY_IDS=("${PREVIOUS_CPU_ENTITY_IDS[@]}")
      DETECTED_CPU_LABELS=("${PREVIOUS_CPU_LABELS[@]}")
      return 1
    fi
  done

  [ "${DETECTED_CPU_ENTITY_IDS[*]}" != "${PREVIOUS_CPU_ENTITY_IDS[*]}" ]
}

# Describes the detected CPU temperature sensors, along with the IPMI entities they are read from : that
# is what the README asks users to correlate with their own "ipmitool sdr type temperature" output
# Usage : format_detected_CPU_temperature_sensors
function format_detected_CPU_temperature_sensors() {
  if (( ${#DETECTED_CPU_ENTITY_IDS[@]} == 1 )); then
    printf '1 CPU temperature sensor detected (entity %s)' "${DETECTED_CPU_ENTITY_IDS[0]}"
  else
    printf '%d CPU temperature sensors detected (entities %s)' "${#DETECTED_CPU_ENTITY_IDS[@]}" "${DETECTED_CPU_ENTITY_IDS[*]}"
  fi
}

# The widest content a CPU column must hold : a reading renders as "NNN°C" (5 columns), but a label such
# as "CPU 10" is wider and would otherwise push every column on its right by one
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
# Usage : retrieve_temperatures $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT
function retrieve_temperatures() {
  if (( $# != 1 )); then
    print_error "Illegal number of parameters. Usage: retrieve_temperatures \$IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT"
    return 1
  fi
  local -r IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT=$1

  # Kept in a global so that refresh_CPU_temperature_sensors() can look for a newly readable CPU in the
  # very same data, without spending another IPMI round-trip on it
  SDR_TEMPERATURE_DATA=$(retrieve_sdr_temperature_data)
  local -r DATA="$SDR_TEMPERATURE_DATA"

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

  # Parse inlet temperature data.
  # Matched on the "degrees" suffix rather than on a fixed two-digit width, like the CPU readings are :
  # '\d{2}' truncated "100 degrees C" to 10°C and missed a single-digit reading entirely.
  # Inlet and exhaust are located by name and not by entity ID, unlike the CPUs : Dell puts them both on
  # the same entity (7.1 on an R730), so their entity can't tell them apart
  INLET_TEMPERATURE=$(echo "$DATA" | grep Inlet | cut -d'|' -f5 | grep -Po '\d+(?=[[:space:]]*degrees)' | tail -1)

  # If exhaust temperature sensor is present, parse its temperature data
  if $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT; then
    EXHAUST_TEMPERATURE=$(echo "$DATA" | grep Exhaust | cut -d'|' -f5 | grep -Po '\d+(?=[[:space:]]*degrees)' | tail -1)
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

# Builds the two header lines of the temperatures table, sized for the CPUs actually detected
# Usage : build_header $CPU_COLUMN_CONTENT_WIDTH "CPU 1" "CPU 2" ...
function build_header() {
  if (( $# < 2 )); then
    print_error "build_header() requires a column content width and at least one CPU label"
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

  # Each CPU label is right-aligned in the shared column width, so that a wider label (e.g. "CPU 10")
  # widens every column consistently instead of shifting the ones on its right
  local CPU_LABEL
  for CPU_LABEL in "${CPU_LABELS[@]}"; do
    header+=$(printf ' %*s ' "$LOCAL_CPU_COLUMN_CONTENT_WIDTH" "$CPU_LABEL")
  done

  header+=' Exhaust          Active fan speed profile          Third-party PCIe card Dell default cooling response  Comment'
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

  printf "%19s  %s°C " "$(date +"%d-%m-%Y %T")" "$(format_temperature_for_display "$LOCAL_INLET_TEMPERATURE")"
  # Itération sur les températures dans le tableau.
  # Only the number is padded, never the assembled "NNN°C" string : the container runs in the POSIX
  # locale (the Dockerfile sets no LANG), where "°" is two bytes, so printf-padding the whole cell would
  # count it as two columns and shift the table by one character per CPU
  for temperature in "${CPUs_temperatures_array[@]}"; do
    printf " %s°C " "$(format_temperature_for_display "$temperature" "$((LOCAL_CPU_COLUMN_CONTENT_WIDTH - 2))")"
  done

  printf " %5s°C  %40s  %51s  %s\n" "$LOCAL_EXHAUST_TEMPERATURE" "$LOCAL_CURRENT_FAN_CONTROL_PROFILE" "$LOCAL_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS" "$LOCAL_COMMENT"
}

# Formats a temperature reading as a right-aligned decimal number of the given width (3 by default).
# Falls back to "-" instead of letting printf %d crash when the reading is empty, a placeholder ("-"),
# or has a leading zero that would otherwise be misinterpreted as an invalid octal number (e.g. "09")
# Usage : format_temperature_for_display "$VALUE" [$WIDTH]
function format_temperature_for_display() {
  local -r VALUE="$1"
  local -r WIDTH="${2:-3}"
  if [[ "$VALUE" =~ ^[0-9]+$ ]]; then
    printf '%*d' "$WIDTH" "$((10#$VALUE))"
  else
    printf '%*s' "$WIDTH" "-"
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

# Builds a clause such as "CPU 2 temperature is too high" or "CPU 1 and CPU 3 temperatures are too high",
# picking the singular or plural form depending on how many CPUs are listed. Prints nothing when the list
# is empty, so the caller can simply test the result
# Usage : format_CPUs_temperature_clause "is too high" "are too high" "CPU 1" "CPU 3"
function format_CPUs_temperature_clause() {
  local -r SINGULAR_ENDING="$1"
  local -r PLURAL_ENDING="$2"
  shift 2
  local -r -a CPU_LABELS=("$@")

  if (( ${#CPU_LABELS[@]} == 0 )); then
    return
  fi

  printf '%s temperature' "$(format_CPU_list_for_display "${CPU_LABELS[@]}")"
  if (( ${#CPU_LABELS[@]} > 1 )); then
    printf 's %s' "$PLURAL_ENDING"
  else
    printf ' %s' "$SINGULAR_ENDING"
  fi
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
# on unverified data. Such a CPU is reported as unreadable rather than as too hot, because the controller
# has no evidence that it is : claiming otherwise would contradict the "-" printed in its own column
function is_any_CPU_overheating() {
  # No CPU sensor at all means nothing can be verified, so fail safe rather than trust the absence of data
  if (( ${#CPU_TEMPERATURES[@]} == 0 )); then
    OVERHEATING_REASON="No CPU temperature could be read"
    return 0
  fi

  local -a TOO_HOT_CPU_LABELS=()
  local -a UNREADABLE_CPU_LABELS=()
  local INDEX CPU_TEMPERATURE CPU_LABEL

  for INDEX in "${!CPU_TEMPERATURES[@]}"; do
    CPU_TEMPERATURE="${CPU_TEMPERATURES[INDEX]}"
    # The label comes from the detected entity, not from the position in the array : with non-contiguous
    # entities (3.1 and 3.3), position 1 is CPU 3, and naming it "CPU 2" would point at a socket that
    # doesn't even have a column in the table
    CPU_LABEL="${DETECTED_CPU_LABELS[INDEX]}"

    if [[ ! "$CPU_TEMPERATURE" =~ ^[0-9]+$ ]]; then
      UNREADABLE_CPU_LABELS+=("$CPU_LABEL")
    elif [ "$((10#$CPU_TEMPERATURE))" -gt "$CPU_TEMPERATURE_THRESHOLD" ]; then
      TOO_HOT_CPU_LABELS+=("$CPU_LABEL")
    fi
  done

  local -a REASONS=()
  local REASON
  REASON=$(format_CPUs_temperature_clause "is too high" "are too high" "${TOO_HOT_CPU_LABELS[@]}")
  if [ -n "$REASON" ]; then
    REASONS+=("$REASON")
  fi
  REASON=$(format_CPUs_temperature_clause "could not be read" "could not be read" "${UNREADABLE_CPU_LABELS[@]}")
  if [ -n "$REASON" ]; then
    REASONS+=("$REASON")
  fi

  if (( ${#REASONS[@]} == 0 )); then
    OVERHEATING_REASON=""
    return 1
  fi

  OVERHEATING_REASON="${REASONS[0]}"
  if (( ${#REASONS[@]} > 1 )); then
    OVERHEATING_REASON+=", ${REASONS[1]}"
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
