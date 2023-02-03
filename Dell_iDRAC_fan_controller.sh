#!/bin/bash

# Define global functions
# This function applies Dell's default dynamic fan control profile
function apply_Dell_profile () {
  # Use ipmitool to send the raw command to set fan control to Dell default
  ipmitool -I $LOGIN_STRING raw 0x30 0x30 0x01 0x01 > /dev/null
  CURRENT_FAN_CONTROL_PROFILE="Dell default dynamic fan control profile"
}

# This function applies a user-specified static fan control profile
function apply_user_profile () {
  # Use ipmitool to send the raw command to set fan control to user-specified value
  ipmitool -I $LOGIN_STRING raw 0x30 0x30 0x01 0x00 > /dev/null
  ipmitool -I $LOGIN_STRING raw 0x30 0x30 0x02 0xff $HEXADECIMAL_FAN_SPEED > /dev/null
  CURRENT_FAN_CONTROL_PROFILE="User static fan control profile ($DECIMAL_FAN_SPEED%)"
}

function enable_third_party_PCIe_card_Dell_default_cooling_response () {
  # We could check the current cooling response before applying but it's not very useful so let's skip the test and apply directly
  ipmitool -I $LOGIN_STRING raw 0x30 0xce 0x00 0x16 0x05 0x00 0x00 0x00 0x05 0x00 0x00 0x00 0x00 > /dev/null
}

function disable_third_party_PCIe_card_Dell_default_cooling_response () {
  # We could check the current cooling response before applying but it's not very useful so let's skip the test and apply directly
  ipmitool -I $LOGIN_STRING raw 0x30 0xce 0x00 0x16 0x05 0x00 0x00 0x00 0x05 0x00 0x01 0x00 0x00 > /dev/null
}

# Returns :
# - 0 if third-party PCIe card Dell default cooling response is currently DISABLED
# - 1 if third-party PCIe card Dell default cooling response is currently ENABLED
# - 2 if the current status returned by ipmitool command output is unexpected
# function is_third_party_PCIe_card_Dell_default_cooling_response_disabled() {
#   THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE=$(ipmitool -I $LOGIN_STRING raw 0x30 0xce 0x01 0x16 0x05 0x00 0x00 0x00)

#   if [ "$THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE" == "16 05 00 00 00 05 00 01 00 00" ]; then
#     return 0
#   elif [ "$THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE" == "16 05 00 00 00 05 00 00 00 00" ]; then
#     return 1
#   else
#     echo "Unexpected output: $THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE" >&2
#     return 2
#   fi
# }

# Prepare traps in case of container exit
function gracefull_exit () {
  apply_Dell_profile
  enable_third_party_PCIe_card_Dell_default_cooling_response
  echo "/!\ WARNING /!\ Container stopped, Dell default dynamic fan control profile applied for safety."
  exit 0
}

# Trap the signals for container exit and run gracefull_exit function
trap 'gracefull_exit' SIGQUIT SIGKILL SIGTERM

# Prepare, format and define initial variables

# Check if FAN_SPEED variable is in hexadecimal format, if not convert it to hexadecimal
if [[ $FAN_SPEED == 0x* ]]
then
  DECIMAL_FAN_SPEED=$(printf '%d' $FAN_SPEED)
  HEXADECIMAL_FAN_SPEED=$FAN_SPEED
else
  DECIMAL_FAN_SPEED=$FAN_SPEED
  HEXADECIMAL_FAN_SPEED=$(printf '0x%02x' $FAN_SPEED)
fi

# Log main informations given to the container
echo "Idrac/IPMI host: $IDRAC_HOST"

# Check if the Idrac host is set to 'local', and set the LOGIN_STRING accordingly
if [[ $IDRAC_HOST == "local" ]]
then
  LOGIN_STRING='open'
else
  echo "Idrac/IPMI username: $IDRAC_USERNAME"
  echo "Idrac/IPMI password: $IDRAC_PASSWORD"
  LOGIN_STRING="lanplus -H $IDRAC_HOST -U $IDRAC_USERNAME -P $IDRAC_PASSWORD"
fi

# Log the fan speed objective, CPU temperature threshold, and check interval
echo "Fan speed objective: $DECIMAL_FAN_SPEED%"
echo "CPU temperature treshold: $CPU_TEMPERATURE_TRESHOLD°C"
echo "Check interval: ${CHECK_INTERVAL}s"
echo ""

# Define the interval for printing
readonly TABLE_HEADER_PRINT_INTERVAL=10
i=$TABLE_HEADER_PRINT_INTERVAL
IS_DELL_PROFILE_APPLIED=true

# Start monitoring
while true; do
  # Sleep for the specified interval before taking another reading
  sleep $CHECK_INTERVAL &
  SLEEP_PROCESS_PID=$!

  # Retrieve sensor data using ipmitool
  DATA=$(ipmitool -I $LOGIN_STRING sdr type temperature | grep degrees)
  INLET_TEMPERATURE=$(echo "$DATA" | grep Inlet | grep -Po '\d{2}' | tail -1)
  EXHAUST_TEMPERATURE=$(echo "$DATA" | grep Exhaust | grep -Po '\d{2}' | tail -1)
  CPU_DATA=$(echo "$DATA" | grep "3\." | grep -Po '\d{2}')
  CPU1_TEMPERATURE=$(echo $CPU_DATA | awk '{print $1;}')
  CPU2_TEMPERATURE=$(echo $CPU_DATA | awk '{print $2;}')

  # Define functions to check if CPU1 and CPU2 temperatures are above the threshold
  CPU1_OVERHEAT () { [ $CPU1_TEMPERATURE -gt $CPU_TEMPERATURE_TRESHOLD ]; }
  CPU2_OVERHEAT () { [ $CPU2_TEMPERATURE -gt $CPU_TEMPERATURE_TRESHOLD ]; }

  # Initialize a variable to store comments
  COMMENT=" -"
  # Check if CPU1 is overheating and apply Dell profile if true
  if CPU1_OVERHEAT
  then
    apply_Dell_profile
    # Set the flag to indicate that Dell profile is applied
    if ! $IS_DELL_PROFILE_APPLIED
    then
      IS_DELL_PROFILE_APPLIED=true
    fi

    if CPU2_OVERHEAT
    then
      COMMENT="CPU 1 and CPU 2 temperatures are too high, Dell default dynamic fan control profile applied for safety"
    else
      COMMENT="CPU 1 temperature is too high, Dell default dynamic fan control profile applied for safety"
    fi
  else
    # Check if CPU2 is overheating and apply Dell profile if true
    if CPU2_OVERHEAT
    then
      apply_Dell_profile
      if ! $IS_DELL_PROFILE_APPLIED
      then
        IS_DELL_PROFILE_APPLIED=true
      fi
      COMMENT="CPU 2 temperature is too high, Dell default dynamic fan control profile applied for safety"
    else
      # Check if user profile is applied and apply it if not
      if $IS_DELL_PROFILE_APPLIED
      then
        apply_user_profile
        IS_DELL_PROFILE_APPLIED=false
      fi
    fi

  # Enable or disable, depending on the user's choice, third-party PCIe card Dell default cooling response
  # No comment will be displayed on the change of this parameter since it is not related to the temperature of any device (CPU, GPU, etc...) but only to the settings made by the user when launching this Docker container
  if $DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE
  then
    disable_third_party_PCIe_card_Dell_default_cooling_response
    THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS="Disabled"
  else
    enable_third_party_PCIe_card_Dell_default_cooling_response
    THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS="Enabled"
  fi
  fi
  # Print the results, including the current fan control profile and comment
  if [ $i -eq $TABLE_HEADER_PRINT_INTERVAL ]
  then
    echo "Time                CPU1    CPU2    Inlet    Exhaust    Fan Control Profile          Third-party PCIe card Dell default cooling response                                 Comment"
    i=0
  fi
  echo "$(date +%T)    $CPU1_TEMPERATURE°C    $CPU2_TEMPERATURE°C    $INLET_TEMPERATURE°C    $EXHAUST_TEMPERATURE°C    $CURRENT_FAN_CONTROL_PROFILE    $THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS    $COMMENT"
  i=$(($i+1))
  wait $SLEEP_PROCESS_PID
done

