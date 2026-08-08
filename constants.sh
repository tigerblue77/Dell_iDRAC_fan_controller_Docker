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
# the container's lifetime, so which of the two applies is settled once at startup
readonly FAN_CONTROL_PROFILE_COLUMN_WIDTH=40
readonly MONITORING_ONLY_MODE_FAN_CONTROL_PROFILE_COLUMN_WIDTH=71

# The cooling response column is sized by its own heading, "Third-party PCIe card Dell default cooling
# response", which is longer than anything that column ever holds : its widest value is "Disabled (not
# applied: monitoring only mode)" at 44. So, unlike the profile column, it does not move with the mode
readonly COOLING_RESPONSE_COLUMN_WIDTH=51

# How long the supervisor gives the monitoring process to stop on its own after forwarding it the signal,
# before killing it outright. Docker's own grace period is 10 seconds by default, so this has to stay
# comfortably inside it or the container is SIGKILLed as a whole before the supervisor gets to act
readonly SUPERVISOR_GRACE_PERIOD_IN_SECONDS=3

# How long a fan control profile may go without being re-sent to the BMC, in seconds.
#
# The profile only has to be sent when it changes : the commands are idempotent and the value is the
# same on every cycle. Re-sending it is nonetheless kept, at a much lower rate, because some iDRAC and
# BMC firmwares take fan control back on their own -- after an internal watchdog, a reset, or a firmware
# update -- and nothing else would notice. Sending only on change would remove that safety net, and the
# failure would be silent : fans louder than configured, no log line, nothing wrong on the surface.
#
# Bounded on its own terms rather than tied to CHECK_INTERVAL : the two answer different questions,
# "how fast do I react to heat" and "how long may a BMC hold the fans before I correct it"
readonly FAN_CONTROL_PROFILE_REFRESH_INTERVAL_IN_SECONDS=60
