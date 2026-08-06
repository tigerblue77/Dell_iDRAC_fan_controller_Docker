#!/bin/bash

# Define the interval for printing temperature table header
readonly TABLE_HEADER_PRINT_INTERVAL=10

# Number of CPU temperature sensors above which the detection result is far more likely to be a parsing
# accident than real hardware : no Dell PowerEdge has ever had more than 4 sockets behind a single iDRAC,
# and chassis products (VRTX, FX2, M1000e, MX7000) expose one iDRAC per sled rather than an aggregated
# one, their CMC not even listening on the IPMI port.
# This is only a diagnostic threshold, never a limit : every detected CPU is monitored whatever its
# number, because dropping a CPU column would mean silently not watching a heat source
readonly UNEXPECTED_NUMBER_OF_CPUS_WARNING_THRESHOLD=8

# A temperature renders as "NNN°C", i.e. 5 display columns. A CPU column only gets wider than that when
# its label is wider (e.g. "CPU 10")
readonly MINIMUM_CPU_COLUMN_CONTENT_WIDTH=5
