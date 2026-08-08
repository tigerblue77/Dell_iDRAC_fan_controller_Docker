#!/bin/bash

# Define the interval for printing temperature table header
readonly TABLE_HEADER_PRINT_INTERVAL=10

# Highest number of CPUs any Dell PowerEdge has ever had behind a single iDRAC. Chassis products (VRTX,
# FX2, M1000e, MX7000) expose one iDRAC per sled rather than an aggregated one, their CMC not even
# listening on the IPMI port, so this holds for them too.
# /!\ This is NOT a limit : detecting more only prints a warning, and every detected CPU is monitored
# whatever its number. Dropping a CPU column would mean silently not watching a heat source, which is
# strictly worse than displaying one CPU too many. It exists so that a count this hardware cannot
# produce -- necessarily a parsing accident -- gets reported instead of passing unnoticed
readonly MAXIMUM_NUMBER_OF_CPUS_IN_A_DELL_SERVER=4

# How long a CPU temperature sensor may stay unreadable before its CPU is considered gone and stops
# being monitored. Dell reports a socket being POSTed and a socket that has been removed identically
# ("Disabled"), so only the duration tells them apart. Generous enough to outlast the POST of a large
# memory configuration, since expiring a CPU that is merely booting would stop watching a real heat
# source, while the only cost of waiting is running the Dell default fan control profile a bit longer
readonly CPU_TEMPERATURE_SENSOR_EXPIRY=600

# A temperature renders as "NNN°C", i.e. 5 display columns. A CPU column only gets wider than that when
# a label is wider, which does not take ten CPUs : a label carries the IPMI entity instance the CPU is
# read from, a 7-bit field (0-127) that has nothing to do with the socket count. A BMC using
# device-relative instances (0x60 and up) labels a two-CPU server "CPU 96" and "CPU 97"
readonly MINIMUM_CPU_COLUMN_CONTENT_WIDTH=5
