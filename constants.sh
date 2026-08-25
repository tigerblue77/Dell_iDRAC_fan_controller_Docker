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

# How far the per-fan identifier probe goes before it stops, on a server that refuses the broadcast fan
# selector 0xff and has to be addressed one fan at a time (issue #378).
#
# The probe tries every identifier from 0x00 up to this bound, keeping the ones the server accepts and
# carrying on past the ones it refuses, so this is the end of the address space a discovery searches --
# and the number of commands it costs -- rather than a guard against a walk that would never stop. It is
# deliberately far above any real fan count -- the R510 this was reported from accepts 0x00 to 0x07 and
# refuses 0x08 onwards, and no PowerEdge exposes anything close to 32 fans -- because being too low would
# silently stop the walk on a server that has more, leaving the fans past the cut running at whatever
# speed they had, which is the one failure this whole fallback exists to remove
readonly MAXIMUM_FAN_IDENTIFIER_PROBES=32

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
# Outside monitoring only mode the width follows the widest badge the code can put after a profile name
# rather than the bare profile : a refused ipmitool call keeps the table honest by saying the profile is
# not the one the server is running, and those suffixes are characters the bare name does not account
# for. Sizing on the bare name is what #170 was. The widest is now " (speed refused)", the 16 characters
# #389 added to Dell's own 40-character name, which is where 56 comes from -- it was 54 for " (not
# applied)" and stayed there for a week while the rows printed two characters past it (#416)
readonly FAN_CONTROL_PROFILE_COLUMN_WIDTH=56
readonly MONITORING_ONLY_MODE_FAN_CONTROL_PROFILE_COLUMN_WIDTH=71

# The cooling response column is sized by its own heading, "Third-party PCIe card Dell default cooling
# response", which is 51 characters and longer than anything that column ever holds : its widest value is
# 47 characters, "Refused: this account lacks the privilege level". So, unlike the profile column, it does
# not move with the mode.
#
# That sentence used to name "Not over IPMI (this server has it over Redfish)" beside it, which is the
# same 47 characters and was true when #374 wrote it -- and stopped being emitted by anything when #375
# replaced it with "$REQUESTED_STATE over Redfish". The number survived the change, so nothing went red
# over a comment naming a status the container can no longer print (#415).
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

# How far into that grace period the supervisor asks a SECOND time, before it gives up and kills.
#
# It asks twice because the first request is sometimes lost : a SIGTERM landing while bash is expanding
# a command substitution is swallowed whole, and the process carries on as if nothing had been sent
# (issues #188 and #249). Measured on this repository, two controllers in two hundred. The handler
# survives it -- a second signal is honoured immediately -- so the one thing that turns that 1% into a
# clean stop is asking again.
#
# One second rather than immediately, and rather than half way : immediately would signal a process that
# is already running graceful_exit, and later would leave that handler too little of the grace period to
# finish its own IPMI commands in. A process that heard the first request is gone well before this
readonly SUPERVISOR_SECOND_ASK_DELAY_IN_SECONDS=1

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
# cooling response left as the user set it.
#
# The exit figure is per REQUEST. The monitoring one is the whole ERRAND's, which is the difference #430
# settled : one cycle's errand makes up to FOUR requests -- the probe's two URIs, then the write path's
# read and its PATCH -- and four times ten seconds inside a cycle whose CHECK_INTERVAL defaults to five
# is not what the paragraph on MAXIMUM_REDFISH_ATTEMPTS below promises. That paragraph says the attempts
# are spaced a CHECK_INTERVAL apart so the cycle keeps reading temperatures ; a cycle spending forty
# seconds in the errand is not reading them either, and the gap between two runs of
# is_any_CPU_overheating() went from one interval to nine, on fans held at the static speed the user
# asked for.
#
# So attempt_the_redfish_cooling_response() opens a deadline of this many seconds, redfish_request()
# gives each request what is left of it, and the errand closes it again however it returned. Lowering the
# number was the other way out and is the wrong one : an iDRAC's Redfish stack is genuinely slow, and a
# per-request timeout short enough to bound the cycle would turn a working server into an unreachable
# one. Sharing it costs a healthy iDRAC nothing -- it answers in well under a second -- lets a slow but
# working one fit its four requests inside the budget, and cuts only one that hangs, which is what should
# be cut, the whole errand being attempted again on the next cycle.
#
# The floor is one second per request, because zero is not "no time left" to HTTP::Tiny but no timeout at
# all : the true bound is this figure plus a second for each request still to be made, which is 13 rather
# than 40 in the worst case that exists. tests/cases/46_redfish_cooling_response.sh pins the count, the
# sharing and the floor
#
# The exit figure is per REQUEST and the hand-back makes two of them -- it reads the slots back, then
# writes them -- so what has to fit inside a deadline is twice this number, not this number. At 3 it did
# not fit anything : graceful_exit() runs under the supervisor's own SUPERVISOR_GRACE_PERIOD_IN_SECONDS,
# also 3, so an iDRAC that simply did not answer made a healthy monitoring process miss that deadline and
# be SIGKILLed as wedged -- with the fans already safe, but the log saying the container had hung. The
# supervisor's own hand-back on that path can make four requests (two probing, two writing) and had 12
# seconds of budget against Docker's 10. At 1 the pair costs 2 seconds against a 3 second deadline, and
# the supervisor's four cost 4 against 10, both with room left over. An iDRAC that needs more than a
# second to answer on the way out is one whose answer nobody is waiting for anyway : the fans are back on
# Dell's profile before any of this runs, and the cooling response is left exactly where it already was.
# tests/cases/46_redfish_cooling_response.sh holds the arithmetic so it cannot drift back (#414)
readonly REDFISH_REQUEST_TIMEOUT_IN_SECONDS=10
readonly REDFISH_EXIT_REQUEST_TIMEOUT_IN_SECONDS=1

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

# How much of a cycle the Redfish errand may spend before it stops and continues on the next one. Read
# in microseconds because the reading it comes from is : a whole-second counter answers "a second has
# passed" for an errand that straddles a boundary however fast it was, which split healthy iDRACs across
# cycles for nothing (#444)
readonly REDFISH_ERRAND_STEP_PAUSE_IN_MICROSECONDS=1000000

# What the column says on a cycle the errand stopped for time rather than for an answer. It is not a
# failure and not a refusal : the iDRAC answered, slowly, and the next request waits for the next cycle
# so the loop keeps its rhythm (#444)
readonly REDFISH_SLOW_ANSWER_STATUS="Redfish is slow, one request per cycle"

# Said identically wherever a Redfish write could not be made, so that the reader is never given two
# slightly different descriptions of the same three clicks
readonly REDFISH_MANUAL_INSTRUCTIONS="The setting is left exactly as it was. On the generations that have it -- the 14th onwards, the only ones where it is a per-slot attribute at all -- it can be set in the iDRAC web interface under Configuration > System Settings > Hardware Settings, in Cooling Configuration, named Fans Configuration on older firmware, by setting LFM Mode on the slot holding the card ; an iDRAC with no such page is one whose server never had this setting, over Redfish or over IPMI, and there is nothing to look for. Fan control and temperature monitoring are unaffected"
