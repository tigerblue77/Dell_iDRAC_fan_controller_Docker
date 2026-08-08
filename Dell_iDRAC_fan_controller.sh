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

# CHECK_INTERVAL paces the whole monitoring loop and is handed straight to sleep, whose exit status the
# loop never looks at, so an unusable value doesn't stop anything : it makes every cycle return at once
# and turns the loop into a busy loop hammering the iDRAC. It is also the controller's reaction time,
# the fans being pinned between two checks, so an excessively long one is refused as well. Validate it
# here, before the first IPMI command, and refuse to start rather than fail silently once running.
# The monitoring only mode is passed along because it decides whether that reaction time exists at all
validate_check_interval_parameter "CHECK_INTERVAL" "$CHECK_INTERVAL" "$MONITORING_ONLY_MODE"

# Check if FAN_SPEED variable is in hexadecimal format. If not, convert it to hexadecimal
if [[ "$FAN_SPEED" == 0x* ]]; then
  readonly DECIMAL_FAN_SPEED=$(convert_hexadecimal_value_to_decimal "$FAN_SPEED")
  readonly HEXADECIMAL_FAN_SPEED="$FAN_SPEED"
else
  readonly DECIMAL_FAN_SPEED="$FAN_SPEED"
  readonly HEXADECIMAL_FAN_SPEED=$(convert_decimal_value_to_hexadecimal "$FAN_SPEED")
fi

# In local mode, the container runs on the target server itself. Two things depend on that : lm-sensors
# can only describe the controlled server's CPUs in that mode, and the server can never be observed
# powered off while the container is running, so that check is only meaningful in network mode
if [[ "$IDRAC_HOST" == "local" ]]; then
  readonly NETWORK_MODE=false
else
  readonly NETWORK_MODE=true
fi

# Resolve the CPU temperature threshold. "auto" (the default) asks the CPUs themselves, through lm-sensors,
# for the "high" temperature defined by their manufacturer : that value describes the actual hardware being
# cooled, unlike a single fixed threshold shared by every CPU model
# (see https://github.com/tigerblue77/Dell_iDRAC_fan_controller_Docker/issues/26)
#
# /!\ This resolution must stay ahead of everything that reads CPU_TEMPERATURE_THRESHOLD as a number /!\
# It is deliberately placed here, right after the FAN_SPEED conversion, so that any later validation sees
# an already-resolved integer rather than the literal string "auto"

# Normalize the raw value first. Docker's --env-file parser keeps the trailing space of a
# "CPU_TEMPERATURE_THRESHOLD=50 " line, and copying the documented placeholder can carry quotes along.
# Bash's own "-gt" used to tolerate both, so rejecting them here would turn a previously working
# configuration into a startup failure, which a restart policy then turns into a crash loop
CPU_TEMPERATURE_THRESHOLD="${CPU_TEMPERATURE_THRESHOLD//[[:space:]]/}"
CPU_TEMPERATURE_THRESHOLD="${CPU_TEMPERATURE_THRESHOLD#[\"\']}"
CPU_TEMPERATURE_THRESHOLD="${CPU_TEMPERATURE_THRESHOLD%[\"\']}"
CPU_TEMPERATURE_THRESHOLD="${CPU_TEMPERATURE_THRESHOLD#+}"
CPU_TEMPERATURE_THRESHOLD="${CPU_TEMPERATURE_THRESHOLD:-auto}"
CPU_TEMPERATURE_THRESHOLD_SOURCE=""
if [[ "${CPU_TEMPERATURE_THRESHOLD,,}" == "auto" ]]; then
  if $NETWORK_MODE; then
    # lm-sensors can only read the CPUs of the machine this container runs on. In network mode that machine
    # isn't the server whose fans are controlled, so its "high" temperature would describe the wrong hardware
    CPU_TEMPERATURE_THRESHOLD=$FALLBACK_CPU_TEMPERATURE_THRESHOLD
    CPU_TEMPERATURE_THRESHOLD_SOURCE=" (fallback value, automatic detection is only available in local mode)"
  else
    DETECTED_CPU_TEMPERATURE_THRESHOLD=$(retrieve_CPU_high_temperature_from_lm_sensors)
    if [ -n "$DETECTED_CPU_TEMPERATURE_THRESHOLD" ]; then
      CPU_TEMPERATURE_THRESHOLD=$DETECTED_CPU_TEMPERATURE_THRESHOLD
      CPU_TEMPERATURE_THRESHOLD_SOURCE=" (automatically detected, \"high\" temperature reported by lm-sensors)"
    else
      CPU_TEMPERATURE_THRESHOLD=$FALLBACK_CPU_TEMPERATURE_THRESHOLD
      CPU_TEMPERATURE_THRESHOLD_SOURCE=" (fallback value, no CPU \"high\" temperature could be read from lm-sensors)"
    fi
  fi
elif [[ "$CPU_TEMPERATURE_THRESHOLD" =~ ^[0-9]{1,3}$ ]]; then
  # Drop any leading zero so the value isn't later interpreted as an octal number (e.g. "050" as 40°C).
  # The digit count is bounded above so that a very long number can't silently wrap around 64 bits here
  CPU_TEMPERATURE_THRESHOLD=$((10#$CPU_TEMPERATURE_THRESHOLD))
  # Hold a user-supplied value to the same plausibility window as an automatically detected one. A typo
  # such as "500" (or a Fahrenheit value) is otherwise accepted silently and no CPU ever reaches it, so
  # the Dell default profile is never restored and the fans stay low for the life of the container
  if [ "$CPU_TEMPERATURE_THRESHOLD" -lt "$MINIMUM_PLAUSIBLE_CPU_TEMPERATURE_THRESHOLD" ] || [ "$CPU_TEMPERATURE_THRESHOLD" -gt "$MAXIMUM_PLAUSIBLE_CPU_TEMPERATURE_THRESHOLD" ]; then
    print_error_and_exit "CPU_TEMPERATURE_THRESHOLD must be between ${MINIMUM_PLAUSIBLE_CPU_TEMPERATURE_THRESHOLD}°C and ${MAXIMUM_PLAUSIBLE_CPU_TEMPERATURE_THRESHOLD}°C, but is ${CPU_TEMPERATURE_THRESHOLD}°C"
  fi
else
  # Reject an unusable threshold right away : every temperature comparison would fail against it, which
  # silently keeps the user's (low) fan speed applied instead of ever triggering the Dell default profile
  print_error_and_exit "CPU_TEMPERATURE_THRESHOLD must be a positive integer number of degrees Celsius or \"auto\", but is \"$CPU_TEMPERATURE_THRESHOLD\""
fi
readonly CPU_TEMPERATURE_THRESHOLD

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

# Log main informations
echo "Server model: $SERVER_MANUFACTURER $SERVER_MODEL"
echo "iDRAC/IPMI host: $IDRAC_HOST"

# Log the fan speed objective, CPU temperature threshold and check interval
echo "Fan speed objective: $DECIMAL_FAN_SPEED%"
echo "CPU temperature threshold: ${CPU_TEMPERATURE_THRESHOLD}°C${CPU_TEMPERATURE_THRESHOLD_SOURCE}"
# The unit is only appended when the value doesn't already carry one, "90s" and "5m" being accepted
# forms that would otherwise be logged as "90ss" and "5ms"
if [[ "$CHECK_INTERVAL" =~ ^[0-9]+$ ]]; then
  echo "Check interval: ${CHECK_INTERVAL}s"
else
  echo "Check interval: $CHECK_INTERVAL"
fi
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
    retrieve_temperatures $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT $IS_CPU2_TEMPERATURE_SENSOR_PRESENT
  fi

  # Initialize a variable to store the comments displayed when the fan control profile changed
  COMMENT=" -"
  # Check if CPU 1 is overheating then apply Dell default dynamic fan control profile if true
  if CPU1_OVERHEATING; then
    apply_Dell_default_fan_control_profile

    if ! $IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED; then
      IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED=true

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
    apply_Dell_default_fan_control_profile

    if ! $IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED; then
      IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED=true
      COMMENT=$(build_fan_control_fallback_comment "CPU 2" "$CPU2_TEMPERATURE")
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

  retrieve_temperatures $IS_EXHAUST_TEMPERATURE_SENSOR_PRESENT $IS_CPU2_TEMPERATURE_SENSOR_PRESENT
done
