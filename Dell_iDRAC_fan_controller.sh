#!/bin/bash

# Enable strict bash mode to stop the script if an uninitialized variable is used, if a command fails, or if a command with a pipe fails
# Not working in some setups : https://github.com/tigerblue77/Dell_iDRAC_fan_controller/issues/48
# set -euo pipefail

source functions.sh
source constants.sh

# Trap the signals for container exit and run graceful_exit function
trap 'graceful_exit' SIGINT SIGQUIT SIGTERM

# Prepare, format and define initial variables

# Validate every user-supplied number before it reaches an arithmetic comparison or an ipmitool
# command. All of them are unchecked text until here, and each one fails silently rather than loudly
# when malformed: FAN_SPEED converts to 0x00 and stops the fans, CPU_TEMPERATURE_THRESHOLD makes the
# overheating checks return "not overheating" and disables the safety fallback, and a CHECK_INTERVAL
# sleep cannot parse makes it return at once, turning the monitoring loop into a busy loop
validate_fan_speed_parameter "FAN_SPEED" "$FAN_SPEED"
# IPMI reports temperatures as a signed byte, so no threshold outside that range can ever be crossed
validate_integer_parameter "CPU_TEMPERATURE_THRESHOLD" "$CPU_TEMPERATURE_THRESHOLD" -128 127
validate_check_interval_parameter "CHECK_INTERVAL" "$CHECK_INTERVAL"

# The booleans are validated for the same reason, their failure mode just being quieter still: they are
# dispatched by running their value as a command, so anything that isn't literally "true" or "false" is
# a command that doesn't exist, exits 127, and takes the branch as false. "True", "1" and "Yes" would
# each give the user the exact opposite of what they configured, without a word about it
validate_boolean_parameter "DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE" "$DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE"
validate_boolean_parameter "KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT" "$KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT"
validate_boolean_parameter "MONITORING_ONLY_MODE" "$MONITORING_ONLY_MODE"

# Leading zeros are stripped so that the value used in comparisons is the one the user meant, "09"
# being read as an invalid octal number everywhere else
CPU_TEMPERATURE_THRESHOLD=$(normalize_decimal_value "$CPU_TEMPERATURE_THRESHOLD")
readonly CPU_TEMPERATURE_THRESHOLD

# Express FAN_SPEED in both notations, whichever one the user gave it in
convert_fan_speed_parameter "$FAN_SPEED"
readonly DECIMAL_FAN_SPEED="$DECIMAL_SPEED"
readonly HEXADECIMAL_FAN_SPEED="$HEXADECIMAL_SPEED"

# HIGH_INLET_TEMPERATURE_THRESHOLD defaults to 35°C, the ASHRAE A2 allowable ceiling. An empty value
# still disables the check, which is how an ASHRAE A3/A4 (Dell Fresh Air) deployment or anyone who
# prefers the previous CPU-only behaviour opts out. The low temperature protections below stay opt-in
if [ -n "$HIGH_INLET_TEMPERATURE_THRESHOLD" ]; then
  validate_integer_parameter "HIGH_INLET_TEMPERATURE_THRESHOLD" "$HIGH_INLET_TEMPERATURE_THRESHOLD" -128 127
  HIGH_INLET_TEMPERATURE_THRESHOLD=$(normalize_decimal_value "$HIGH_INLET_TEMPERATURE_THRESHOLD")
fi
readonly HIGH_INLET_TEMPERATURE_THRESHOLD

if [ -n "$LOW_INLET_TEMPERATURE_THRESHOLD" ]; then
  validate_integer_parameter "LOW_INLET_TEMPERATURE_THRESHOLD" "$LOW_INLET_TEMPERATURE_THRESHOLD" -128 127
  LOW_INLET_TEMPERATURE_THRESHOLD=$(normalize_decimal_value "$LOW_INLET_TEMPERATURE_THRESHOLD")

  if [ -n "$HIGH_INLET_TEMPERATURE_THRESHOLD" ] && [ "$LOW_INLET_TEMPERATURE_THRESHOLD" -ge "$HIGH_INLET_TEMPERATURE_THRESHOLD" ]; then
    print_configuration_error_and_exit "LOW_INLET_TEMPERATURE_THRESHOLD" "$LOW_INLET_TEMPERATURE_THRESHOLD" "a temperature below HIGH_INLET_TEMPERATURE_THRESHOLD (${HIGH_INLET_TEMPERATURE_THRESHOLD}°C), otherwise the two intake air limits would overlap"
  fi
fi
readonly LOW_INLET_TEMPERATURE_THRESHOLD

if [ -n "$LOW_CPU_TEMPERATURE_THRESHOLD" ]; then
  validate_integer_parameter "LOW_CPU_TEMPERATURE_THRESHOLD" "$LOW_CPU_TEMPERATURE_THRESHOLD" -128 127
  LOW_CPU_TEMPERATURE_THRESHOLD=$(normalize_decimal_value "$LOW_CPU_TEMPERATURE_THRESHOLD")

  if [ "$LOW_CPU_TEMPERATURE_THRESHOLD" -ge "$CPU_TEMPERATURE_THRESHOLD" ]; then
    print_configuration_error_and_exit "LOW_CPU_TEMPERATURE_THRESHOLD" "$LOW_CPU_TEMPERATURE_THRESHOLD" "a temperature below CPU_TEMPERATURE_THRESHOLD (${CPU_TEMPERATURE_THRESHOLD}°C), otherwise the same reading would be both too cold and too hot"
  fi
fi
readonly LOW_CPU_TEMPERATURE_THRESHOLD

# LOW_TEMPERATURE_FAN_SPEED is what the low temperature protection applies, so it becomes required as
# soon as either of its triggers is configured, and it must not exceed FAN_SPEED : the protection
# exists to reduce airflow when the chassis is too cold, never to increase it
if [ -n "$LOW_INLET_TEMPERATURE_THRESHOLD" ] || [ -n "$LOW_CPU_TEMPERATURE_THRESHOLD" ]; then
  if [ -z "$LOW_TEMPERATURE_FAN_SPEED" ]; then
    print_configuration_error_and_exit "LOW_TEMPERATURE_FAN_SPEED" "" "a fan speed, because it is what the low temperature protection applies and you set LOW_INLET_TEMPERATURE_THRESHOLD or LOW_CPU_TEMPERATURE_THRESHOLD"
  fi

  validate_fan_speed_parameter "LOW_TEMPERATURE_FAN_SPEED" "$LOW_TEMPERATURE_FAN_SPEED"
  convert_fan_speed_parameter "$LOW_TEMPERATURE_FAN_SPEED"

  if [ "$DECIMAL_SPEED" -gt "$DECIMAL_FAN_SPEED" ]; then
    print_configuration_error_and_exit "LOW_TEMPERATURE_FAN_SPEED" "$LOW_TEMPERATURE_FAN_SPEED" "a fan speed at or below FAN_SPEED (${DECIMAL_FAN_SPEED}%), the low temperature protection only ever reduces the fan speed"
  fi

  readonly DECIMAL_LOW_TEMPERATURE_FAN_SPEED="$DECIMAL_SPEED"
  readonly HEXADECIMAL_LOW_TEMPERATURE_FAN_SPEED="$HEXADECIMAL_SPEED"
  readonly IS_LOW_TEMPERATURE_PROTECTION_ENABLED=true
else
  readonly IS_LOW_TEMPERATURE_PROTECTION_ENABLED=false
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
# The unit is only appended when the value doesn't already carry one, "60s" being an accepted form
if [[ "$CHECK_INTERVAL" =~ ^[0-9.]+$ ]]; then
  echo "Check interval: ${CHECK_INTERVAL}s"
else
  echo "Check interval: $CHECK_INTERVAL"
fi
if [ -n "$HIGH_INLET_TEMPERATURE_THRESHOLD" ]; then
  echo "High inlet temperature threshold: ${HIGH_INLET_TEMPERATURE_THRESHOLD}°C (Dell default dynamic fan control profile applied above, set HIGH_INLET_TEMPERATURE_THRESHOLD empty to disable)"
else
  echo "High inlet temperature threshold: Disabled"
fi
if $IS_LOW_TEMPERATURE_PROTECTION_ENABLED; then
  # Both triggers are listed so the log states the exact conjunction that has to hold, the protection
  # engaging only once every configured one does
  LOW_TEMPERATURE_CONDITIONS=""
  if [ -n "$LOW_INLET_TEMPERATURE_THRESHOLD" ]; then
    LOW_TEMPERATURE_CONDITIONS="inlet < ${LOW_INLET_TEMPERATURE_THRESHOLD}°C"
  fi
  if [ -n "$LOW_CPU_TEMPERATURE_THRESHOLD" ]; then
    if [ -n "$LOW_TEMPERATURE_CONDITIONS" ]; then
      LOW_TEMPERATURE_CONDITIONS+=" and "
    fi
    LOW_TEMPERATURE_CONDITIONS+="every CPU < ${LOW_CPU_TEMPERATURE_THRESHOLD}°C"
  fi
  echo "Low temperature protection: Enabled (${DECIMAL_LOW_TEMPERATURE_FAN_SPEED}% applied while $LOW_TEMPERATURE_CONDITIONS)"
else
  echo "Low temperature protection: Disabled"
fi
if "$MONITORING_ONLY_MODE"; then
  echo "Monitoring only mode: Enabled (no fan control profile will be applied, temperatures will only be logged)"
else
  echo "Monitoring only mode: Disabled"
fi
echo ""

TABLE_HEADER_PRINT_COUNTER=$TABLE_HEADER_PRINT_INTERVAL
# Tracks which fan control profile is currently applied, so that a change can be commented on the
# cycle it happens rather than on every cycle. A boolean was enough while there were only two
# profiles; the low temperature protection adds a third one to tell apart.
# Values : "Dell", "user" or "low temperature". Starts at "Dell", the profile in force before the
# container takes control
ACTIVE_FAN_CONTROL_PROFILE="Dell"
# Tracks whether the target server was powered off on the previous cycle, so temperatures can be
# refreshed right when it powers back on instead of reusing data read before/during the outage
IS_TARGET_SERVER_POWERED_OFF=false

# Check present sensors
IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT=true
IS_CPU2_TEMPERATURE_SENSOR_PRESENT=true

# Start timer in background
sleep "$CHECK_INTERVAL" &
SLEEP_PROCESS_PID=$!

retrieve_temperatures $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT $IS_CPU2_TEMPERATURE_SENSOR_PRESENT

if [ -z "$EXHAUST_TEMPERATURE" ]; then
  echo "No exhaust temperature sensor detected."
  IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT=false
  # This reading was taken before the sensor was known to be absent, so it holds an empty string where
  # every later cycle will hold the "-" placeholder. Backfilling it here keeps the first printed line
  # consistent with the rest, instead of leaving a blank under the "Exhaust" heading
  EXHAUST_TEMPERATURE="-"
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
  # In network mode, if the target server is powered off, skip this cycle entirely: don't read
  # temperatures (they would be meaningless) and don't apply any fan control profile.
  # A cycle is also skipped when the iDRAC can't be reached at all, but the two are reported
  # separately: one is a machine that is legitimately off, the other is a server we may well be
  # holding at a static fan speed with no way to see or change anything about it
  if $NETWORK_MODE; then
    get_server_power_state
    TARGET_SERVER_POWER_STATE=$?

    if [ $TARGET_SERVER_POWER_STATE -ne 0 ]; then
      IS_TARGET_SERVER_POWERED_OFF=true

      if [ $TARGET_SERVER_POWER_STATE -eq 2 ]; then
        printf "%19s  Cannot reach the iDRAC, target server state unknown and fan control profile left as-is. ipmitool said: %s\n" "$(date +"%d-%m-%Y %T")" "$IPMI_UNREACHABLE_REASON" >&2
      else
        printf "%19s  Target server is powered off, no fan control profile applied.\n" "$(date +"%d-%m-%Y %T")"
      fi

      wait $SLEEP_PROCESS_PID

      # Start timer in background for next cycle
      sleep "$CHECK_INTERVAL" &
      SLEEP_PROCESS_PID=$!
      continue
    fi
  fi

  # The server just powered back on: refresh temperatures now instead of evaluating stale data read
  # before/during the outage (could be the initial pre-loop reading, or readings from before it powered off)
  if $IS_TARGET_SERVER_POWERED_OFF; then
    IS_TARGET_SERVER_POWERED_OFF=false
    retrieve_temperatures $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT $IS_CPU2_TEMPERATURE_SENSOR_PRESENT
  fi

  # Initialize a variable to store the comments displayed when the fan control profile changed
  COMMENT=" -"
  # The branches below are ordered by priority, and CPU overheating deliberately comes first: whatever
  # the intake air is doing, a CPU past its threshold has to get the Dell default profile, and no
  # later branch may reduce the fan speed while that is the case
  #
  # Check if CPU 1 is overheating then apply Dell default dynamic fan control profile if true
  if CPU1_OVERHEATING; then
    # The state is only latched if the command actually reached the server: latching on a failure
    # would silence every later cycle through the "!= Dell" guard, leaving the log asserting that the
    # safety profile is active while the fans are still held at the user's speed
    if apply_Dell_default_fan_control_profile && [ "$ACTIVE_FAN_CONTROL_PROFILE" != "Dell" ]; then
      ACTIVE_FAN_CONTROL_PROFILE="Dell"

      # If CPU 2 temperature sensor is present, check if it is overheating too.
      # Do not apply Dell default dynamic fan control profile as it has already been applied before
      if $IS_CPU2_TEMPERATURE_SENSOR_PRESENT && CPU2_OVERHEATING; then
        COMMENT=$(build_fan_control_fallback_comment "CPU 1" "$CPU1_TEMPERATURE" "CPU 2" "$CPU2_TEMPERATURE")
      else
        COMMENT=$(build_fan_control_fallback_comment "CPU 1" "$CPU1_TEMPERATURE")
      fi
    fi
  # If CPU 2 temperature sensor is present, check if it is overheating then apply Dell default dynamic fan control profile if true
  elif $IS_CPU2_TEMPERATURE_SENSOR_PRESENT && CPU2_OVERHEATING; then
    if apply_Dell_default_fan_control_profile && [ "$ACTIVE_FAN_CONTROL_PROFILE" != "Dell" ]; then
      ACTIVE_FAN_CONTROL_PROFILE="Dell"
      COMMENT=$(build_fan_control_fallback_comment "CPU 2" "$CPU2_TEMPERATURE")
    fi
  # Intake air hotter than the server is rated for: a static fan speed is the wrong thing to be
  # holding, so hand control back to iDRAC, which knows the platform's own airflow requirements
  elif INLET_TEMPERATURE_TOO_HIGH; then
    if apply_Dell_default_fan_control_profile && [ "$ACTIVE_FAN_CONTROL_PROFILE" != "Dell" ]; then
      ACTIVE_FAN_CONTROL_PROFILE="Dell"
      COMMENT="Inlet temperature is too high (> $HIGH_INLET_TEMPERATURE_THRESHOLD°C), Dell default dynamic fan control profile applied for safety"
    fi
  # Chassis colder than its components are rated for: reduce the airflow so their own waste heat can
  # hold the inside of the server above the ambient temperature
  elif SERVER_TOO_COLD; then
    if apply_low_temperature_fan_control_profile && [ "$ACTIVE_FAN_CONTROL_PROFILE" != "low temperature" ]; then
      ACTIVE_FAN_CONTROL_PROFILE="low temperature"
      COMMENT="Server is too cold, fan speed reduced to $DECIMAL_LOW_TEMPERATURE_FAN_SPEED% to preserve a minimum internal temperature"
    fi
  else
    # Check if user fan control profile is applied then apply it if not
    if apply_user_fan_control_profile && [ "$ACTIVE_FAN_CONTROL_PROFILE" != "user" ]; then
      # The profile being left says which condition cleared, the return to the user's profile meaning
      # different things depending on it
      if [ "$ACTIVE_FAN_CONTROL_PROFILE" == "low temperature" ]; then
        COMMENT="Server warmed back up, user's fan control profile applied."
      else
        COMMENT="CPU temperature decreased and is now OK (<= $CPU_TEMPERATURE_THRESHOLD°C), user's fan control profile applied."
      fi
      ACTIVE_FAN_CONTROL_PROFILE="user"
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

    if "$MONITORING_ONLY_MODE"; then
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

  retrieve_temperatures $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT $IS_CPU2_TEMPERATURE_SENSOR_PRESENT
done
