#!/bin/bash

# Define the interval for printing temperature table header
readonly TABLE_HEADER_PRINT_INTERVAL=10

# Fallback CPU temperature threshold (in °C), used when CPU_TEMPERATURE_THRESHOLD is set to "auto" but the
# CPUs' own "high" temperature cannot be read from lm-sensors
readonly FALLBACK_CPU_TEMPERATURE_THRESHOLD=50

# Window (in °C) a CPU temperature threshold must fall into to be plausible. No CPU throttles below 20°C,
# and none tolerates more than 125°C, so a value outside it is a misreading or a typo rather than a
# setting : left in place it would either pin the fans low forever or never let them slow down at all
readonly MINIMUM_PLAUSIBLE_CPU_TEMPERATURE_THRESHOLD=20
readonly MAXIMUM_PLAUSIBLE_CPU_TEMPERATURE_THRESHOLD=125

# Bounds the check interval is measured against, in seconds. The interval is the controller's reaction
# time : between two checks the fans stay pinned at FAN_SPEED with Dell's own dynamic fan control
# disabled, so it is also the longest the server can heat up before anything raises them again.
# Past the warning threshold that delay is worth pointing out, past the maximum it stops being a
# configuration choice. Both are only meaningful when the controller actually drives the fans, so
# validate_check_interval_parameter ignores them in monitoring only mode
readonly CHECK_INTERVAL_WARNING_THRESHOLD_IN_SECONDS=60
readonly MAXIMUM_CHECK_INTERVAL_IN_SECONDS=900
