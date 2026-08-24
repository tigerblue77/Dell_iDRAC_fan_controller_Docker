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
# Asked before anything is read, and without touching the network : what this check is for is telling
# Docker to restart a container that has stopped doing its job, and until now it only ever asked whether
# the TEMPERATURE SOURCE was answering. Those are different states. An iDRAC that keeps answering while
# the monitoring loop has wedged left the container healthy with the fans pinned at FAN_SPEED, Dell's own
# regulation switched off and nothing evaluating the threshold any more -- the one state with no recovery,
# since the restart policy never fires (issue #440).
#
# Absence is not a fault, and neither is an unreadable record : see is_the_monitoring_loop_still_reporting()
if ! is_the_monitoring_loop_still_reporting "$CHECK_INTERVAL"; then
  printf 'The monitoring loop has not completed a cycle for longer than its check interval allows\n' >&2
  exit 1
fi

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
