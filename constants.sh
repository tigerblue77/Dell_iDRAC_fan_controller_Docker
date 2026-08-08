#!/bin/bash

# Define the interval for printing temperature table header
readonly TABLE_HEADER_PRINT_INTERVAL=10

# Bounds the check interval is measured against, in seconds. The interval is the controller's reaction
# time : between two checks the fans stay pinned at FAN_SPEED with Dell's own dynamic fan control
# disabled, so it is also the longest the server can heat up before anything raises them again.
# Past the warning threshold that delay is worth pointing out, past the maximum it stops being a
# configuration choice. Both are only meaningful when the controller actually drives the fans, so
# validate_check_interval_parameter ignores them in monitoring only mode
readonly CHECK_INTERVAL_WARNING_THRESHOLD_IN_SECONDS=60
readonly MAXIMUM_CHECK_INTERVAL_IN_SECONDS=900

# Highest number of CPUs any Dell PowerEdge has ever had behind a single iDRAC. Chassis products (VRTX,
# FX2, M1000e, MX7000) expose one iDRAC per sled rather than an aggregated one, their CMC not even
# listening on the IPMI port, so this holds for them too.
# /!\ This is NOT a limit : detecting more only prints a warning, and every detected CPU is monitored
# whatever its number. Dropping a CPU column would mean silently not watching a heat source, which is
# strictly worse than displaying one CPU too many. It exists so that a count this hardware cannot
# produce -- necessarily a parsing accident -- gets reported instead of passing unnoticed
readonly MAXIMUM_NUMBER_OF_CPUS_IN_A_DELL_SERVER=4

# A temperature renders as "NNN°C", i.e. 5 display columns, which every label up to "CPU 9" fits into.
# A CPU column only gets wider than that from a tenth CPU on ("CPU 10"), which no Dell server can have
# and therefore only a mis-parse can produce
readonly MINIMUM_CPU_COLUMN_CONTENT_WIDTH=5

# How many consecutive readings must agree before a CPU that stopped reporting its temperature is
# considered removed. They are only counted after the target server has been switched off and back on,
# a CPU being unable to leave a running machine.
# The cost of waiting is running the Dell default fan control profile a few cycles longer on a server
# that has genuinely lost a CPU; the cost of concluding too early is dropping a socket that was merely
# slow to become readable after POST, and monitoring one heat source less until it shows up again
readonly CPU_REMOVAL_CONFIRMING_READINGS=5
