#!/bin/bash

# Define the interval for printing temperature table header
readonly TABLE_HEADER_PRINT_INTERVAL=10

# How many cycles in a row the server has to refuse Dell's OEM third-party PCIe card cooling response
# command before the controller stops sending it. ipmitool exits non-zero both for a command the BMC
# does not implement and for a BMC it could not reach at all, and those two must not be confused : a
# server that has no such setting refuses every single time, an iDRAC being reset or a momentary
# network glitch refuses once
readonly THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_REFUSALS_BEFORE_GIVING_UP=3
