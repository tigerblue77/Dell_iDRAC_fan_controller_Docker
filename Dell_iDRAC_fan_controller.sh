#!/bin/bash

# Define global functions
apply_Dell_profile () {
  ipmitool -I $LOGIN_STRING raw 0x30 0x30 0x01 0x01 > /dev/null
  CURRENT_FAN_CONTROL_PROFILE="Dell default dynamic fan control profile"
}

apply_user_profile () {
  ipmitool -I $LOGIN_STRING raw 0x30 0x30 0x01 0x00 > /dev/null
  ipmitool -I $LOGIN_STRING raw 0x30 0x30 0x02 0xff $HEXADECIMAL_FAN_SPEED > /dev/null
  CURRENT_FAN_CONTROL_PROFILE="User static fan control profile ($DECIMAL_FAN_SPEED%)"
}

# Prepare traps in case of container exit
gracefull_exit () {
  apply_Dell_profile
  echo "/!\ WARNING /!\ Container stopped, Dell default dynamic fan control profile applied for safety."
  exit 0
}

trap 'gracefull_exit' SIGQUIT SIGKILL SIGTERM

# Prepare, format and define initial variables

#readonly DELL_FRESH_AIR_COMPLIANCE=45

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
if [[ $IDRAC_HOST == "local" ]]
then
  LOGIN_STRING='open'
else
  echo "Idrac/IPMI username: $IDRAC_USERNAME"
  echo "Idrac/IPMI password: $IDRAC_PASSWORD"
  LOGIN_STRING="lanplus -H $IDRAC_HOST -U $IDRAC_USERNAME -P $IDRAC_PASSWORD"
fi
echo "Fan speed objective: $DECIMAL_FAN_SPEED%"
echo "CPU temperature treshold: $CPU_TEMPERATURE_TRESHOLD°C"
echo "Check interval: ${CHECK_INTERVAL}s"
echo ""

readonly TABLE_HEADER_PRINT_INTERVAL=10
i=$TABLE_HEADER_PRINT_INTERVAL
IS_DELL_PROFILE_APPLIED=true

# Start monitoring
while true; do
  sleep $CHECK_INTERVAL &
  SLEEP_PROCESS_PID=$!

  DATA=$(ipmitool -I $LOGIN_STRING sdr type temperature | grep degrees)
  INLET_TEMPERATURE=$(echo "$DATA" | grep Inlet | grep -Po '\d{2}' | tail -1)
  EXHAUST_TEMPERATURE=$(echo "$DATA" | grep Exhaust | grep -Po '\d{2}' | tail -1)
  CPU_DATA=$(echo "$DATA" | grep "3\." | grep -Po '\d{2}')
  CPU1_TEMPERATURE=$(echo $CPU_DATA | awk '{print $1;}')
  CPU2_TEMPERATURE=$(echo $CPU_DATA | awk '{print $2;}')

  CPU1_OVERHEAT () { [[ $CPU1_TEMPERATURE -gt $CPU_TEMPERATURE_TRESHOLD ]]; }
  CPU2_OVERHEAT () { [[ $CPU2_TEMPERATURE -gt $CPU_TEMPERATURE_TRESHOLD ]]; }

  COMMENT=" -"
  if CPU1_OVERHEAT
  then
    apply_Dell_profile

    if ! $IS_DELL_PROFILE_APPLIED
    then
      IS_DELL_PROFILE_APPLIED=true

      if CPU2_OVERHEAT
      then
        COMMENT="CPU 1 and CPU 2 temperatures are too high. Dell default dynamic fan control profile applied."
      else
        COMMENT="CPU 1 temperature is too high. Dell default dynamic fan control profile applied."
      fi
    fi
  elif CPU2_OVERHEAT
  then
    apply_Dell_profile

    if ! $IS_DELL_PROFILE_APPLIED
    then
      IS_DELL_PROFILE_APPLIED=true
      COMMENT="CPU 2 temperature is too high. Dell default dynamic fan control profile applied."
    fi
  else
    apply_user_profile

    if $IS_DELL_PROFILE_APPLIED
    then
      COMMENT="CPU temperature decreased and is now OK (<= $CPU_TEMPERATURE_TRESHOLD°C). User's fan control profile applied."
      IS_DELL_PROFILE_APPLIED=false
    fi
  fi

  # Print temperatures array
  if [ $i -ge $TABLE_HEADER_PRINT_INTERVAL ]
  then
    echo "                   ------- Temperatures -------"
    echo "   Date & time     Inlet  CPU 1  CPU 2  Exhaust          Active fan speed profile          Comment"
    i=0
  fi
   printf "%12s  %3d  C  %3d  C  %3d  C  %5d  C" "$(date +"%d-%m-%y %H:%M:%S")" $INLET_TEMPERATURE $CPU1_TEMPERATURE $CPU2_TEMPERATURE
   printf " %s %s\n" "$CURRENT_FAN_CONTROL_PROFILE" "$COMMENT"
 
  ((i++))
  wait $SLEEP_PROCESS_PID
done
