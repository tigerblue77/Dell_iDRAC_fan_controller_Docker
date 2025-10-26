#!/bin/bash

# Enable strict bash mode to stop the script if an uninitialized variable is used, if a command fails, or if a command with a pipe fails
# Not working in some setups : https://github.com/tigerblue77/Dell_iDRAC_fan_controller/issues/48
# set -euo pipefail

source functions.sh

set_iDRAC_login_string "$IDRAC_HOST" "$IDRAC_USERNAME" "$IDRAC_PASSWORD"

ipmitool -I $IDRAC_LOGIN_STRING sdr type temperature
