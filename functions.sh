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
function extract_temperature_from_sdr_line() {
  local -r SDR_LINE="$1"

  echo "$SDR_LINE" | cut -d'|' -f5 | grep -Po '\d+(?=[[:space:]]*degrees)'
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

  set_detected_CPU_temperature_sensors "${CPU_ENTITY_INSTANCES[@]}"
}

# Fills the DETECTED_CPU_* arrays from a list of entity instances, expected sorted
# Usage : set_detected_CPU_temperature_sensors 1 2 3 4
function set_detected_CPU_temperature_sensors() {
  local -r -a CPU_ENTITY_INSTANCES=("$@")

  # CPUs are numbered 1, 2, 3... in the order their entities come, rather than after the entity instance
  # they are read from. The instance is an IPMI implementation detail : it is only required to be unique,
  # so it is free to start at 0 or to be sparse, and labelling a two-CPU server "CPU 0"/"CPU 96" would be
  # accurate yet useless. The entity each column maps to is logged at startup instead, which is what
  # makes an unusual numbering diagnosable without putting it in the table
  DETECTED_CPU_ENTITY_IDS=()
  DETECTED_CPU_LABELS=()
  local CPU_ENTITY_INSTANCE
  local CPU_NUMBER=1
  for CPU_ENTITY_INSTANCE in "${CPU_ENTITY_INSTANCES[@]}"; do
    DETECTED_CPU_ENTITY_IDS+=("3.$CPU_ENTITY_INSTANCE")
    DETECTED_CPU_LABELS+=("CPU $CPU_NUMBER")
    ((CPU_NUMBER++))
  done
}

# Runs the detection again on already-fetched sensor data and reports whether the monitored set changed.
# Usage : refresh_CPU_temperature_sensors "$SDR_DATA" $NOW
# Returns : 0 (true) if the set changed, the DETECTED_CPU_* arrays then describing the new one
#
# A CPU showing up is adopted immediately : the server may have been powered off precisely to add one,
# and keeping the previous set would leave it both invisible in the table and, far worse, never compared
# to the temperature threshold.
#
# A CPU disappearing is only acted upon after CPU_TEMPERATURE_SENSOR_EXPIRY seconds without a reading.
# A socket being POSTed and a socket that has been removed look exactly the same in the SDR, Dell
# reporting both as "Disabled", so at any single instant they cannot be told apart -- but over time they
# can, since POST ends and removal doesn't. Dropping a CPU on the spot would stop watching one that is
# merely not readable yet; never dropping it would pin the server to the Dell default profile forever,
# as its unreadable column keeps failing safe, until someone restarts the container
function refresh_CPU_temperature_sensors() {
  local -r SDR_DATA="$1"
  local -r NOW="$2"
  local -r -a PREVIOUS_CPU_ENTITY_IDS=("${DETECTED_CPU_ENTITY_IDS[@]}")

  detect_CPU_temperature_sensors "$SDR_DATA"

  local -a CPU_ENTITY_INSTANCES=()
  local CPU_ENTITY_ID
  for CPU_ENTITY_ID in "${DETECTED_CPU_ENTITY_IDS[@]}"; do
    CPU_LAST_READABLE_AT[$CPU_ENTITY_ID]=$NOW
    CPU_ENTITY_INSTANCES+=("${CPU_ENTITY_ID#3.}")
  done

  # Keep the CPUs that are missing from this reading but were still answering recently enough for the
  # silence to be explainable by a reboot rather than by a removal
  for CPU_ENTITY_ID in "${PREVIOUS_CPU_ENTITY_IDS[@]}"; do
    # Entity IDs hold no space, so the padded-join membership test is unambiguous
    if [[ " ${DETECTED_CPU_ENTITY_IDS[*]} " == *" $CPU_ENTITY_ID "* ]]; then
      continue
    fi
    if (( NOW - ${CPU_LAST_READABLE_AT[$CPU_ENTITY_ID]:-0} <= CPU_TEMPERATURE_SENSOR_EXPIRY )); then
      CPU_ENTITY_INSTANCES+=("${CPU_ENTITY_ID#3.}")
    fi
  done

  # Every CPU going silent at once is an IPMI or host problem, not four sockets being unplugged
  # together. Emptying the table on that would leave nothing to fail safe on, so the previous set is
  # restored and each column goes on reading "-", which does apply the Dell default profile.
  # detect_CPU_temperature_sensors() has already overwritten the arrays by now, hence the rebuild
  if (( ${#CPU_ENTITY_INSTANCES[@]} == 0 )); then
    for CPU_ENTITY_ID in "${PREVIOUS_CPU_ENTITY_IDS[@]}"; do
      CPU_ENTITY_INSTANCES+=("${CPU_ENTITY_ID#3.}")
    done
    set_detected_CPU_temperature_sensors "${CPU_ENTITY_INSTANCES[@]}"
    return 1
  fi

  mapfile -t CPU_ENTITY_INSTANCES < <(printf '%s\n' "${CPU_ENTITY_INSTANCES[@]}" | sort -n)
  set_detected_CPU_temperature_sensors "${CPU_ENTITY_INSTANCES[@]}"

  [ "${DETECTED_CPU_ENTITY_IDS[*]}" != "${PREVIOUS_CPU_ENTITY_IDS[*]}" ]
}

# Pushes back the expiry of every monitored CPU temperature sensor.
# Usage : postpone_CPU_temperature_sensors_expiry $NOW
#
# Called while the target server is powered off : the sensors are legitimately silent then, and that
# silence must not count towards the delay after which a CPU is considered removed. Without this, a
# server left powered off longer than the delay would come back with all of its CPUs already expired
function postpone_CPU_temperature_sensors_expiry() {
  local -r NOW="$1"
  local CPU_ENTITY_ID

  for CPU_ENTITY_ID in "${DETECTED_CPU_ENTITY_IDS[@]}"; do
    CPU_LAST_READABLE_AT[$CPU_ENTITY_ID]=$NOW
  done
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

# Warns when more CPU temperature sensors are detected than any Dell server has sockets.
# Usage : warn_if_unexpected_number_of_CPUs
#
# Nothing is ever dropped : every detected CPU stays monitored whatever its number, because dropping a
# column would mean silently not watching a heat source. This only reports a count the hardware cannot
# produce, which necessarily means the sensors were mis-parsed
function warn_if_unexpected_number_of_CPUs() {
  if (( ${#DETECTED_CPU_ENTITY_IDS[@]} <= MAXIMUM_NUMBER_OF_CPUS_IN_A_DELL_SERVER )); then
    return
  fi

  print_warning "${#DETECTED_CPU_ENTITY_IDS[@]} CPU temperature sensors is more than any Dell server has sockets. All of them will be monitored, but please open an issue at https://github.com/tigerblue77/Dell_iDRAC_fan_controller_Docker/issues with your server model and the output of the \"ipmitool sdr type temperature\" command"
  # print_warning() emits no trailing newline
  echo ""
}

# The widest content a CPU column must hold : a reading renders as "NNN°C" (5 columns), which every label
# up to "CPU 9" fits into. A tenth column would be labelled "CPU 10" and push everything on its right by
# one, so the width follows the labels. No Dell server has ten sockets, so this only ever triggers on a
# mis-parse -- the same one the startup warning reports -- but a broken table is a poor way to find out
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

  # Each CPU label is right-aligned in the shared column width, so that a label wider than a reading
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

# Returns 0 (true) if the given temperature reading is usable, i.e. a plain non-negative integer.
# A missing sensor, a transient IPMI parsing glitch or an "ns"/"Disabled" sensor all yield something
# that isn't
function is_temperature_reading_valid() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

# Checks whether any of the detected CPUs needs the Dell default fan control profile.
# Returns 0 (true) if at least one does, and fills OVERHEATING_CPUS_AND_TEMPERATURES with the
# "label temperature" pairs build_fan_control_fallback_comment() expects, so the log line can tell the
# user which CPU triggered the switch and whether it was too hot or simply unreadable.
#
# Every detected CPU is evaluated, not just the first two : on a 4-socket server (R930, R830...) CPU 3
# and CPU 4 used to be read by nobody, so they could cross the threshold while the controller happily
# kept the user's low fan speed running.
#
# Like the per-CPU checks it replaces, it deliberately returns true both when a CPU is genuinely too hot
# and when its reading is unusable, so an unverifiable temperature still falls back to Dell's profile
# instead of crashing (bash's "-gt" throws "unary operator expected" on empty/non-numeric input) or
# silently running the low user fan speed on unverified data
function is_any_CPU_overheating() {
  OVERHEATING_CPUS_AND_TEMPERATURES=()

  local INDEX CPU_TEMPERATURE
  for INDEX in "${!CPU_TEMPERATURES[@]}"; do
    CPU_TEMPERATURE="${CPU_TEMPERATURES[INDEX]}"
    if ! is_temperature_reading_valid "$CPU_TEMPERATURE" || [ "$((10#$CPU_TEMPERATURE))" -gt "$CPU_TEMPERATURE_THRESHOLD" ]; then
      # The label is taken from the table's own labels rather than rebuilt here, so that the CPU named
      # in the comment is always the one whose column shows the reading that triggered it. It falls back
      # to the position rather than to an empty string, so that a comment naming no CPU at all can never
      # be the thing a user has to diagnose an overheat with
      OVERHEATING_CPUS_AND_TEMPERATURES+=("${DETECTED_CPU_LABELS[INDEX]:-CPU $((INDEX + 1))}" "$CPU_TEMPERATURE")
    fi
  done

  # Not being able to read a single CPU means nothing can be verified, so fail safe rather than trust
  # the absence of data. refresh_CPU_temperature_sensors() keeps the set from ever emptying, so this
  # only guards against a caller reaching here before any detection ran
  if (( ${#CPU_TEMPERATURES[@]} == 0 )); then
    return 0
  fi

  (( ${#OVERHEATING_CPUS_AND_TEMPERATURES[@]} > 0 ))
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
# is_any_CPU_overheating() deliberately reports both a CPU that is genuinely too hot and one whose
# reading is unusable, so an unverifiable temperature still falls back to Dell's profile.
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
