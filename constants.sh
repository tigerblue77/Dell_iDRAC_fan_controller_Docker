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
# is 47 characters, reached by both "Refused: this account lacks the privilege level" and "Not over IPMI
# (this server has it over Redfish)". So, unlike the profile column, it does not move with the mode.
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

# The two URIs the System attributes answer on, and the order they are tried in. Neither reaches every
# iDRAC : the conformant one does not exist before iDRAC 9 5.x, where it answers 404 with
# Base.1.2.ResourceMissingAtURI -- the resource is absent, which is not a refusal, that would be 401 or
# 403 -- and the legacy one is documented as removed on iDRAC 10. Both measured on real hardware in
# issue #360, which is also why the conformant one goes first : trying them the other way round works on
# every machine reported there and stops working on the newest hardware Dell sells
readonly REDFISH_CONFORMANT_ATTRIBUTES_URI="/redfish/v1/Managers/iDRAC.Embedded.1/Oem/Dell/DellAttributes/System.Embedded.1"
readonly REDFISH_LEGACY_ATTRIBUTES_URI="/redfish/v1/Managers/System.Embedded.1/Attributes"

# How long a Redfish request is given. The startup probe can afford to wait ; the one on the way out
# cannot, because it runs after the fans have been handed back but still inside Docker's ten second
# stop grace period, and a container killed for taking too long to stop would be a worse outcome than a
# cooling response left as the user set it
readonly REDFISH_REQUEST_TIMEOUT_IN_SECONDS=10
readonly REDFISH_EXIT_REQUEST_TIMEOUT_IN_SECONDS=3

# How many times reaching the cooling response over Redfish is attempted before the container stops
# trying, counting the first attempt. It covers the whole errand -- reading the attributes and writing
# them -- because a reader does not care which half of it an unreachable iDRAC stopped. Deliberately not a parameter : it is an internal robustness detail rather than
# something to tune, and a third failure-handling knob beside MAXIMUM_CONSECUTIVE_IPMI_FAILURES and
# MAXIMUM_IPMI_UNREACHABLE_DURATION would cost every reader more than it buys the few who reach this
# path at all (#376).
#
# The attempts are a CHECK_INTERVAL apart rather than in a loop, so that the cycle keeps reading and
# logging temperatures -- the one thing this container still does correctly on these servers -- and so
# that a busy iDRAC is given time to stop being busy, which a tight loop would not
readonly MAXIMUM_REDFISH_ATTEMPTS=3

# Said identically wherever a Redfish write could not be made, so that the reader is never given two
# slightly different descriptions of the same three clicks
readonly REDFISH_MANUAL_INSTRUCTIONS="The setting is left exactly as it was, and can be set in the iDRAC web interface under Configuration > System Settings > Hardware Settings, in Cooling Configuration -- named Fans Configuration on older firmware -- by setting LFM Mode on the slot holding the card. Fan control and temperature monitoring are unaffected."
