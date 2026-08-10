#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# shellcheck disable=SC2034  # Every constant here is consumed by the scripts that source this file, not by this file itself

# Define the interval for printing temperature table header
readonly TABLE_HEADER_PRINT_INTERVAL=10

# Fallback CPU temperature threshold (in °C), used when CPU_TEMPERATURE_THRESHOLD is set to "auto" but the
# CPUs' own "high" temperature cannot be read from lm-sensors
readonly FALLBACK_CPU_TEMPERATURE_THRESHOLD=50

# Window (in °C) a CPU temperature threshold must fall into to be plausible. No CPU throttles below 20°C,
# and none tolerates more than 125°C, so a value outside it is a misreading or a typo rather than a
# setting : left in place it would either pin the fans low forever or never let them slow down at all.
#
# The maximum is a safety limit rather than a sanity check, and that is why it is not negotiable : a
# threshold above it is not a stricter setting but the absence of one, no PowerEdge CPU reaching 125°C
# before its own thermal protection powers the machine off, so the fallback such a threshold governs
# could never fire and the container would supervise nothing while printing a threshold at startup.
# Being unable to disable that fallback is the intended behaviour. Only hardware whose manufacturer
# "high" value genuinely exceeds this would reopen the number, and none is known to exist (issue #326)
readonly MINIMUM_PLAUSIBLE_CPU_TEMPERATURE_THRESHOLD=20
readonly MAXIMUM_PLAUSIBLE_CPU_TEMPERATURE_THRESHOLD=125

# Bounds of the fan speed, as a percentage of the fans' duty cycle. Dell's raw command takes a byte,
# so the same setting is also accepted in hexadecimal, and the maximum is 0x64 in that notation --
# derived from this number rather than written beside it, two spellings of one bound being one more
# thing that can drift apart.
#
# Kept here rather than written into validate_fan_speed_parameter() for the same reason the check
# interval's bounds are : the documentation states them too, and nothing could compare the two while
# they lived only in the validator. test_the_readme_documents_the_fan_speed_range() now does (#328)
readonly MINIMUM_FAN_SPEED_PERCENTAGE=0
readonly MAXIMUM_FAN_SPEED_PERCENTAGE=100

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

# Widths of the two right-hand columns of the temperatures table. The header and the rows are both laid out
# from these, rather than each repeating a literal of its own, which is how the profile column came to
# reserve less in the header than the rows were printing into it.
#
# That column has zero slack by construction : "Dell default dynamic fan control profile" is exactly 40
# characters, so the " (monitoring only, not applied)" badge -- 31 more -- cannot be made to fit by
# shortening anything, and the column has to widen with the mode instead. MONITORING_ONLY_MODE is fixed for
# the container's lifetime, so which of the two applies is settled once at startup.
#
# Outside monitoring only mode the width follows " (not applied)" rather than the bare profile : a refused
# ipmitool call keeps the table honest by saying the profile is not the one the server is running, and that
# suffix is 14 characters the bare name does not account for. Sizing on the bare name is what #170 was
readonly FAN_CONTROL_PROFILE_COLUMN_WIDTH=54
readonly MONITORING_ONLY_MODE_FAN_CONTROL_PROFILE_COLUMN_WIDTH=71

# The cooling response column is sized by its own heading, "Third-party PCIe card Dell default cooling
# response", which is 51 characters and longer than anything that column ever holds : its widest value
# is "Refused: this account lacks the privilege level" at 47. So, unlike the profile column, it does not
# move with the mode.
#
# That sentence used to name a value of 44 that a later status overtook, and nothing went red over it --
# the suite asserted every status fits, which stayed true, but never that this number is the heading's
# length nor that the heading beats every value, which is what the sentence actually claims. Both are
# asserted now, in test_no_fan_control_profile_can_outgrow_the_column_reserved_for_it() (issue #344)
readonly COOLING_RESPONSE_COLUMN_WIDTH=51

# How long the supervisor gives the monitoring process to stop on its own after forwarding it the signal,
# before killing it outright. Docker's own grace period is 10 seconds by default, so this has to stay
# comfortably inside it or the container is SIGKILLed as a whole before the supervisor gets to act
readonly SUPERVISOR_GRACE_PERIOD_IN_SECONDS=3
