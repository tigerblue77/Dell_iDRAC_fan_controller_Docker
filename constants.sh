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

# How many cycles in a row the server has to refuse Dell's OEM third-party PCIe card cooling response
# command before the controller stops sending it. ipmitool exits non-zero both for a command the BMC
# does not implement and for a BMC it could not reach at all, and those two must not be confused : a
# server that has no such setting refuses every single time, an iDRAC being reset or a momentary
# network glitch refuses once
readonly THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_REFUSALS_BEFORE_GIVING_UP=3
