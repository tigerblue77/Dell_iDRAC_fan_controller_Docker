# Define global functions
# This function applies Dell's default dynamic fan control profile
# In monitoring only mode, the profile is only logged, not actually applied
function apply_Dell_default_fan_control_profile() {
  if "$MONITORING_ONLY_MODE"; then
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
    # The command never reached the server, so the table must not claim the profile is active : this is
    # the safety fallback, and an operator reading "applied for safety" on a cooking server would have
    # no reason to look further
    CURRENT_FAN_CONTROL_PROFILE="Dell default profile FAILED TO APPLY"
    return 1
  fi
  CURRENT_FAN_CONTROL_PROFILE="Dell default dynamic fan control profile"
}

# This function applies a static fan control profile at the given speed
# Usage : apply_static_fan_control_profile $DECIMAL_SPEED $HEXADECIMAL_SPEED "$PROFILE_NAME"
#
# The speed is a parameter rather than the FAN_SPEED global because two different profiles use this
# same command: the user's normal one, and the reduced one the low temperature protection applies
#
# In monitoring only mode, the profile is only logged, not actually applied
function apply_static_fan_control_profile() {
  if (( $# != 3 )); then
    print_error "Illegal number of parameters.\nUsage: apply_static_fan_control_profile \$DECIMAL_SPEED \$HEXADECIMAL_SPEED \"\$PROFILE_NAME\""
    return 1
  fi
  local -r DECIMAL_SPEED="$1"
  local -r HEXADECIMAL_SPEED="$2"
  local -r PROFILE_NAME="$3"

  if "$MONITORING_ONLY_MODE"; then
    CURRENT_FAN_CONTROL_PROFILE="$PROFILE_NAME ($DECIMAL_SPEED%) (monitoring only, not applied)"
    return
  fi
  # Use ipmitool to send the raw command to set fan control to the given value.
  # Same reasoning as apply_Dell_default_fan_control_profile: only surface stderr if the command
  # actually failed, instead of always discarding it (this profile changes real fan speed)
  local ipmitool_stderr
  ipmitool_stderr=$(ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0x30 0x01 0x00 2>&1 >/dev/null)
  if [ $? -ne 0 ]; then
    print_error "Failed to enable manual fan control. ipmitool said: $ipmitool_stderr"
    # Returning early rather than sending a speed anyway : without manual control the speed command is
    # meaningless, and iDRAC is still managing the fans, which is the safe state to leave the server in
    CURRENT_FAN_CONTROL_PROFILE="Manual fan control FAILED TO ENABLE"
    return 1
  fi
  ipmitool_stderr=$(ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0x30 0x02 0xff $HEXADECIMAL_SPEED 2>&1 >/dev/null)
  if [ $? -ne 0 ]; then
    print_error "Failed to set fan speed to $DECIMAL_SPEED%. ipmitool said: $ipmitool_stderr"
    # The worst of the three states and the one that most needs naming: manual control is now ON, so
    # iDRAC has stopped managing the fans, and the speed that was supposed to replace it never arrived.
    # The fans are sitting at whatever value was last set, under nobody's control
    CURRENT_FAN_CONTROL_PROFILE="Fan speed FAILED TO APPLY ($DECIMAL_SPEED% requested)"
    return 1
  fi
  CURRENT_FAN_CONTROL_PROFILE="$PROFILE_NAME ($DECIMAL_SPEED%)"
}

# This function applies the user-specified static fan control profile
function apply_user_fan_control_profile() {
  apply_static_fan_control_profile "$DECIMAL_FAN_SPEED" "$HEXADECIMAL_FAN_SPEED" "User static fan control profile"
}

# This function applies the reduced static fan control profile that the low temperature protection uses
function apply_low_temperature_fan_control_profile() {
  apply_static_fan_control_profile "$DECIMAL_LOW_TEMPERATURE_FAN_SPEED" "$HEXADECIMAL_LOW_TEMPERATURE_FAN_SPEED" "Low temperature fan profile"
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

# Stop the container unless the given parameter is an integer within an inclusive range
# Usage : validate_integer_parameter "$PARAMETER_NAME" "$VALUE" $MINIMUM $MAXIMUM
#
# User-supplied parameters reach us as unchecked text and are then used in arithmetic, where a
# malformed one fails quietly instead of loudly. A non-integer CPU_TEMPERATURE_THRESHOLD makes bash's
# "-gt" return 2, which every caller reads as "not overheating", disabling the safety fallback the
# container exists to provide. Refusing to start is the only outcome that can't be mistaken for
# normal operation.
#
# This function must be called as a statement, never through a command substitution : the exit inside
# print_error_and_exit would otherwise only leave the subshell and the container would keep running
function validate_integer_parameter() {
  local -r PARAMETER_NAME="$1"
  local -r VALUE="$2"
  local -r MINIMUM="$3"
  local -r MAXIMUM="$4"

  if [[ ! "$VALUE" =~ ^-?[0-9]+$ ]]; then
    print_configuration_error_and_exit "$PARAMETER_NAME" "$VALUE" "a whole number between $MINIMUM and $MAXIMUM"
  fi

  local -r NORMALIZED_VALUE=$(normalize_decimal_value "$VALUE")
  if [ "$NORMALIZED_VALUE" -lt "$MINIMUM" ] || [ "$NORMALIZED_VALUE" -gt "$MAXIMUM" ]; then
    print_configuration_error_and_exit "$PARAMETER_NAME" "$VALUE" "a whole number between $MINIMUM and $MAXIMUM"
  fi
}

# Stop the container unless the given parameter is a usable fan speed, in either accepted notation
# Usage : validate_fan_speed_parameter "$PARAMETER_NAME" "$VALUE"
#
# bash's printf applies base detection, so an unchecked value never fails visibly : "09" is an invalid
# octal number, "abc" an invalid number, an empty value produces no diagnostic at all, and all three
# convert to 0x00 -- the documented Dell command for 0% fan duty. The container would then report the
# user's profile as applied every cycle with the fans stopped, and only recover once a CPU crossed
# CPU_TEMPERATURE_THRESHOLD, i.e. after it had already heated up
function validate_fan_speed_parameter() {
  local -r PARAMETER_NAME="$1"
  local -r VALUE="$2"
  local DECIMAL_VALUE

  if [[ "$VALUE" =~ ^0[xX][0-9A-Fa-f]{1,2}$ ]]; then
    DECIMAL_VALUE=$(convert_hexadecimal_value_to_decimal "$VALUE")
  elif [[ "$VALUE" =~ ^[0-9]+$ ]]; then
    DECIMAL_VALUE=$(normalize_decimal_value "$VALUE")
  else
    print_configuration_error_and_exit "$PARAMETER_NAME" "$VALUE" "a percentage from 0 to 100, or the same value in hexadecimal from 0x00 to 0x64"
  fi

  if [ "$DECIMAL_VALUE" -gt 100 ]; then
    print_configuration_error_and_exit "$PARAMETER_NAME" "$VALUE" "a percentage from 0 to 100, or the same value in hexadecimal from 0x00 to 0x64 (this is ${DECIMAL_VALUE}%)"
  fi
}

# Stop the container unless the given parameter is a duration sleep can actually wait for
# Usage : validate_check_interval_parameter "$PARAMETER_NAME" "$VALUE"
#
# The value is passed straight to sleep, whose exit status the loop discards, so an unusable one
# doesn't stop anything : sleep returns in a few milliseconds and the monitoring loop starts spinning
# at full speed, opening an IPMI session per iteration and flooding the logs.
#
# GNU sleep accepts a unit suffix, and "60s" or "5m" are therefore working configurations even though
# the README documents plain seconds. They stay accepted here : rejecting a value that has been
# waiting correctly all along would break a working container for no benefit
function validate_check_interval_parameter() {
  local -r PARAMETER_NAME="$1"
  local -r VALUE="$2"

  if [[ ! "$VALUE" =~ ^[0-9]+[smhd]?$ ]]; then
    print_configuration_error_and_exit "$PARAMETER_NAME" "$VALUE" "a number of seconds, optionally suffixed with s, m, h or d (for example 60, 60s, 5m or 1h)"
  fi

  # A zero interval is syntactically valid for sleep and still spins the loop, so it's rejected on its
  # own terms rather than on its format
  if [ "$((10#${VALUE%[smhd]}))" -eq 0 ]; then
    print_configuration_error_and_exit "$PARAMETER_NAME" "$VALUE" "a duration greater than zero, otherwise the monitoring loop would never pause between two readings"
  fi
}

# Stop the container unless the given parameter is one of the two documented boolean values
# Usage : validate_boolean_parameter "$PARAMETER_NAME" "$VALUE"
#
# Booleans are dispatched by running their value as a command, "true" and "false" being real programs.
# Anything else is a command that doesn't exist : it exits 127 and the branch is silently taken as
# false, so "True", "TRUE", "1", "on" and "Yes" all give the user the opposite of what they asked for.
# MONITORING_ONLY_MODE=True is the dangerous one, the container reporting the mode as disabled and then
# taking real control of the fans on a server the operator asked it not to touch.
#
# "yes" is worse still, being a command that DOES exist and never returns : the container blocks on the
# first test, floods stdout at hundreds of MB per second, and cannot be stopped by "docker stop", the
# graceful_exit trap being deferred while yes holds the foreground
function validate_boolean_parameter() {
  local -r PARAMETER_NAME="$1"
  local -r VALUE="$2"

  if [ "$VALUE" != "true" ] && [ "$VALUE" != "false" ]; then
    print_configuration_error_and_exit "$PARAMETER_NAME" "$VALUE" "exactly \"true\" or \"false\", in lower case ; \"True\", \"1\", \"yes\" and \"on\" are not accepted because they would silently be taken as false"
  fi
}

# Express an already validated fan speed parameter in both notations at once
# Usage : convert_fan_speed_parameter "$VALUE"
# Returns : DECIMAL_SPEED, HEXADECIMAL_SPEED
function convert_fan_speed_parameter() {
  local -r VALUE="$1"

  if [[ "$VALUE" == 0[xX]* ]]; then
    DECIMAL_SPEED=$(convert_hexadecimal_value_to_decimal "$VALUE")
    HEXADECIMAL_SPEED="$VALUE"
  else
    # Leading zeros are stripped before the conversion, printf would otherwise read "09" as an invalid
    # octal number and hand back 0x00
    DECIMAL_SPEED=$(normalize_decimal_value "$VALUE")
    HEXADECIMAL_SPEED=$(convert_decimal_value_to_hexadecimal "$DECIMAL_SPEED")
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
# Usage : retrieve_temperatures $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT
# Returns : CPU_TEMPERATURES (indexed array), NUMBER_OF_DETECTED_CPUS, CPUS_TEMPERATURES,
#           INLET_TEMPERATURE, EXHAUST_TEMPERATURE
#
# The CPU 2 presence flag is gone: the CPUs are discovered on every reading, so their count is an
# output of this function rather than something the caller has to tell it
function retrieve_temperatures() {
  if (( $# != 1 )); then
    print_error "Illegal number of parameters. Usage: retrieve_temperatures \$IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT"
    return 1
  fi
  local -r IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT=$1

  # stderr is discarded here: this is a read-only diagnostic call (it never changes fan behavior) and some
  # iDRAC/BMC firmwares print a harmless protocol warning on every call even though the reading succeeds
  local -r DATA=$(ipmitool -I $IDRAC_LOGIN_STRING sdr type temperature 2>/dev/null | grep degrees)

  # Discover the CPUs rather than assuming two of them. Entity 3 is the processor, so 3.1 is CPU 1,
  # 3.2 is CPU 2, and so on: the lookup was already generation-independent, but the enumerated set was
  # hardcoded to the first two, so a 4-socket R810/R815/R910/R930 ran with half its sockets never
  # sampled and never checked for overheating -- on a machine whose own thermal management this
  # container had just disabled
  local i
  CPU_TEMPERATURES=()
  NUMBER_OF_DETECTED_CPUS=0
  # The bound is defaulted rather than assumed: functions.sh is sourced on its own by healthcheck.sh,
  # and an unset constant would silently make this loop detect no CPU at all
  for ((i = 1; i <= ${MAXIMUM_NUMBER_OF_CPUS:-4}; i++)); do
    local CPU_TEMPERATURE=$(retrieve_temperature_by_entity_id "$DATA" "3.$i")

    # Dell populates sockets contiguously, so the first entity with no reading at all marks the end of
    # the populated ones rather than a failed read to be skipped over
    if [ -z "$CPU_TEMPERATURE" ] && [ $i -gt 1 ]; then
      break
    fi

    CPU_TEMPERATURES+=("$CPU_TEMPERATURE")
    ((NUMBER_OF_DETECTED_CPUS++))
  done

  # Build the display string. An unreadable reading falls back to the "-" placeholder so that it still
  # takes up its column when the line is printed : CPUS_TEMPERATURES is split to build the display
  # array, so an empty value would be dropped and shift every following column to the left.
  # CPU_TEMPERATURES itself is left untouched, the overheating checks must still see the invalid reading
  CPUS_TEMPERATURES=""
  for ((i = 0; i < NUMBER_OF_DETECTED_CPUS; i++)); do
    if [ -n "$CPUS_TEMPERATURES" ]; then
      CPUS_TEMPERATURES+=";"
    fi
    CPUS_TEMPERATURES+="${CPU_TEMPERATURES[$i]:--}"
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

# Report the target server's power state
# Returns : 0 if it is powered on, 1 if it is powered off, 2 if the iDRAC could not be reached
#
# Only meaningful in network mode: in local mode the container runs on the target server itself,
# so it cannot be observed powered off while the container is running
#
# The three outcomes used to be two. stderr and the exit code were both discarded and the verdict came
# from a substring, so a failed call produced empty output, didn't contain "is on", and was reported as
# a powered-off chassis -- indistinguishable from the real thing. A dropped session, rotated
# credentials, an iDRAC reboot and a LAN flap all landed in the same branch, and the caller skipped the
# cycle without reading temperatures or applying any profile, leaving the fans frozen at the user's
# static speed on a running, loaded server while the log called it benign
function get_server_power_state() {
  local POWER_STATUS
  POWER_STATUS=$(ipmitool -I $IDRAC_LOGIN_STRING chassis power status 2>&1)
  if [ $? -ne 0 ]; then
    IPMI_UNREACHABLE_REASON="$POWER_STATUS"
    return 2
  fi

  [[ "$POWER_STATUS" == *"is on"* ]]
}

# /!\ Use this function only for Gen 13 and older generation servers /!\
# In monitoring only mode, this is a no-op
function enable_third_party_PCIe_card_Dell_default_cooling_response() {
  if "$MONITORING_ONLY_MODE"; then
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
  if "$MONITORING_ONLY_MODE"; then
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
  if "$MONITORING_ONLY_MODE"; then
    print_warning_and_exit "Container stopped (monitoring only mode, no fan control profile was ever applied)"
  fi

  local restored=true
  apply_Dell_default_fan_control_profile || restored=false

  # Reset third-party PCIe card cooling response to Dell default depending on the user's choice at startup
  if ! "$KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT"; then
    enable_third_party_PCIe_card_Dell_default_cooling_response
  fi

  # The goodbye message is the last thing an operator sees, and it used to assert the fans were safe
  # whether or not the command had actually reached the server. On failure the container is exiting and
  # leaving the fans under nobody's control, which is worth a non-zero exit code as well as a mention
  if ! $restored; then
    print_error_and_exit "Container stopped but the Dell default dynamic fan control profile could NOT be restored, the fans are still under this container's last setting"
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
    print_configuration_error_and_exit "IDRAC_HOST / IDRAC_USERNAME / IDRAC_PASSWORD" "$IDRAC_HOST" "credentials that can open an IPMI session. ipmitool said: $IPMI_FRU_content"
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

# Check whether a detected CPU is above the threshold, by its 0-based index in CPU_TEMPERATURES.
# If a reading isn't a valid number (missing sensor, transient IPMI parsing glitch, etc.), fail safe and
# report overheating so the Dell default fan control profile kicks in, instead of crashing (bash's "-gt"
# throws "unary operator expected" on empty/non-numeric input) or silently running the low user fan speed
# on unverified data
function CPU_OVERHEATING() {
  local -r TEMPERATURE="${CPU_TEMPERATURES[$1]}"

  is_temperature_reading_valid "$TEMPERATURE" || return 0
  [ "$(normalize_decimal_value "$TEMPERATURE")" -gt "$CPU_TEMPERATURE_THRESHOLD" ]
}

# Returns 0 (true) if any detected CPU is overheating, 1 (false) otherwise
# Returns : OVERHEATING_CPUS_AND_TEMPERATURES, alternating "CPU <n>" labels and their readings, in the
#           pair form build_fan_control_fallback_comment() takes, so it can be passed straight through
#
# Every detected CPU is checked rather than the first two: on a 4-socket server the container has just
# disabled iDRAC's own thermal management, so a CPU it doesn't look at is a CPU nothing is looking at
function ANY_CPU_OVERHEATING() {
  local i
  OVERHEATING_CPUS_AND_TEMPERATURES=()

  # No readable CPU at all is not "nothing is too hot", it means the container is flying blind. An
  # empty loop below would return false and hold the user's static speed on an unmonitored machine,
  # so this fails safe the same way an unreadable individual reading does
  if [ "${NUMBER_OF_DETECTED_CPUS:-0}" -eq 0 ]; then
    return 0
  fi

  for ((i = 0; i < NUMBER_OF_DETECTED_CPUS; i++)); do
    if CPU_OVERHEATING $i; then
      OVERHEATING_CPUS_AND_TEMPERATURES+=("CPU $((i + 1))" "${CPU_TEMPERATURES[$i]}")
    fi
  done

  [ ${#OVERHEATING_CPUS_AND_TEMPERATURES[@]} -gt 0 ]
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
# CPU_OVERHEATING() deliberately returns true both when a CPU is genuinely too hot and when its reading
# is unusable, so an unverifiable temperature still falls back to Dell's profile.
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

# Returns 0 (true) if intake air is hotter than HIGH_INLET_TEMPERATURE_THRESHOLD, 1 (false) otherwise
#
# Above its rated intake temperature a server's fans are the only mitigation left, and a static low
# fan speed is exactly the wrong thing to be holding. The volume PowerEdge line is rated to ASHRAE
# class A2, whose allowable inlet ceiling is 35°C; Dell Fresh Air models add A3 (40°C) and A4 (45°C),
# both restricted to a share of annual operating hours rather than continuous use. Past the configured
# limit, iDRAC's own profile knows the platform's airflow requirements better than a fixed percentage.
#
# The default is 35°C, so the check is on unless it is turned off. A false trigger is deliberately the
# cheap direction: handing control back to iDRAC makes the server behave exactly as it would if this
# container had never been installed -- louder, but never less safe. Leaving the threshold empty
# disables the check, which then never fires.
#
# An unreadable inlet reading also returns false. That is the opposite of how the CPU checks treat bad
# data, and deliberately so: an intake temperature that was not measured says nothing about whether
# the server is in danger, and the CPU checks already cover the case that actually endangers it
function INLET_TEMPERATURE_TOO_HIGH() {
  [ -n "$HIGH_INLET_TEMPERATURE_THRESHOLD" ] || return 1
  [[ "$INLET_TEMPERATURE" =~ ^-?[0-9]+$ ]] || return 1
  [ "$(normalize_decimal_value "$INLET_TEMPERATURE")" -gt "$HIGH_INLET_TEMPERATURE_THRESHOLD" ]
}

# Returns 0 (true) if every configured low temperature condition is met, 1 (false) otherwise
#
# Cold intake air doesn't damage silicon, but a chassis held at a sub-zero ambient by a high static
# fan speed drags the components that do have a lower limit down with it: enterprise disks are rated
# from 5°C (0°C on some ranges) and stiffen their spindle lubricant below it, PERC battery backup
# units are lithium-ion and plate metallic lithium if charged below 0°C, and Dell's own operating
# envelope stops at 10°C, or 5°C continuously and -5°C for up to 1% of annual operating hours.
# Reducing airflow lets the machine's own waste heat hold the inside above ambient.
#
# The conditions are combined with AND rather than OR. The point of the protection is a minimum
# temperature *inside* the chassis, and a cold room with a busy server in it is not a situation to
# reduce airflow in: configuring LOW_CPU_TEMPERATURE_THRESHOLD next to LOW_INLET_TEMPERATURE_THRESHOLD
# is what keeps cold intake air from throttling the fans over a CPU that is working.
#
# An unreadable sensor never satisfies its condition, so the protection stays disengaged rather than
# reducing airflow on data it could not verify
function SERVER_TOO_COLD() {
  local IS_ANY_CONDITION_CONFIGURED=false

  if [ -n "$LOW_INLET_TEMPERATURE_THRESHOLD" ]; then
    IS_ANY_CONDITION_CONFIGURED=true
    [[ "$INLET_TEMPERATURE" =~ ^-?[0-9]+$ ]] || return 1
    [ "$(normalize_decimal_value "$INLET_TEMPERATURE")" -lt "$LOW_INLET_TEMPERATURE_THRESHOLD" ] || return 1
  fi

  if [ -n "$LOW_CPU_TEMPERATURE_THRESHOLD" ]; then
    IS_ANY_CONDITION_CONFIGURED=true
    # Every detected CPU has to be cold : one busy CPU is enough to mean the chassis isn't
    local i
    for ((i = 0; i < NUMBER_OF_DETECTED_CPUS; i++)); do
      [[ "${CPU_TEMPERATURES[$i]}" =~ ^-?[0-9]+$ ]] || return 1
      [ "$(normalize_decimal_value "${CPU_TEMPERATURES[$i]}")" -lt "$LOW_CPU_TEMPERATURE_THRESHOLD" ] || return 1
    done
  fi

  # Neither threshold configured means the protection is off, not that every condition trivially held
  $IS_ANY_CONDITION_CONFIGURED
}

# Stop the container on an invalid configuration parameter, with everything needed to fix it
# Usage : print_configuration_error_and_exit "$PARAMETER_NAME" "$VALUE" "$EXPECTED"
#
# Refusing to start is the point : a malformed parameter fails silently once the container is running,
# so the only outcome that can't be mistaken for normal operation is not running at all. But refusing
# to start is only useful if the reason survives a "docker logs" scroll, hence the block form rather
# than one line among the startup output -- the user has to be able to see, without reading the source,
# which parameter is wrong, what it currently is, what is accepted, and where to change it
function print_configuration_error_and_exit() {
  local -r PARAMETER_NAME="$1"
  local -r VALUE="$2"
  local -r EXPECTED="$3"

  printf "\n/!\\ Error /!\\ Invalid configuration, the container will not start.\n\n" >&2
  printf "  Parameter : %s\n" "$PARAMETER_NAME" >&2
  printf "  Value     : \"%s\"\n" "$VALUE" >&2
  printf "  Expected  : %s\n\n" "$EXPECTED" >&2
  printf "  Fix it in the \"-e\" arguments of your \"docker run\" command, or in the \"environment\"\n" >&2
  printf "  section of your docker-compose.yml, then start the container again.\n\n" >&2

  exit 1
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
