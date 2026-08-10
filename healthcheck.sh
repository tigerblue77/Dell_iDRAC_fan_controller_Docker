#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# Enable strict bash mode to stop the script if an uninitialized variable is used, if a command fails, or if a command with a pipe fails
# Not working in some setups : https://github.com/tigerblue77/Dell_iDRAC_fan_controller/issues/48
# set -euo pipefail

source functions.sh

# What makes the container healthy is being able to read the temperatures it supervises, so the check
# has to interrogate the source those readings actually come from. A user who set CPU_TEMPERATURE_SOURCE
# to "lm-sensors" did so because their iDRAC does not answer temperature queries : asking it anyway
# would report the container unhealthy for doing exactly what it was configured to do, and Docker's
# restart policy would turn that into a loop.
#
# "auto" keeps checking the iDRAC even on a container that has fallen back to lm-sensors. That is
# deliberate rather than an omission : the iDRAC is still the one being sent every fan control command,
# so a container that has lost it has lost the only thing it can act with, whatever it reads
if [ "$(normalize_CPU_temperature_source "$CPU_TEMPERATURE_SOURCE")" == "lm-sensors" ]; then
  CPU_TEMPERATURE_DATA=$(build_CPU_temperature_sdr_lines_from_lm_sensors)

  if [ -z "$CPU_TEMPERATURE_DATA" ]; then
    exit 1
  fi

  printf '%s\n' "$CPU_TEMPERATURE_DATA"
  exit 0
fi

set_iDRAC_login_string "$IDRAC_HOST" "$IDRAC_USERNAME" "$IDRAC_PASSWORD"

ipmitool -I $IDRAC_LOGIN_STRING sdr type temperature
