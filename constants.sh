#!/bin/bash

# Define the interval for printing temperature table header
readonly TABLE_HEADER_PRINT_INTERVAL=10

# Highest number of CPUs the controller looks for at startup. Dell PowerEdge servers top out at 4
# sockets (R830, R930, R920...), so entities 3.1 to 3.4 cover every supported machine
readonly MAXIMUM_SUPPORTED_NUMBER_OF_CPUS=4
