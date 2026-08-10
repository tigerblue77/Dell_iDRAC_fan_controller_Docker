#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# Builders for the two ipmitool outputs the controller parses: the FRU inventory
# ("ipmitool fru", used to identify the server) and the temperature sensor
# records ("ipmitool sdr type temperature").
#
# Both are generated rather than stored as flat files because the interesting
# dimension is combinatorial: every generation from 9 to 17, in 1, 2 and 4 CPU
# variants, with or without an inlet sensor, an exhaust sensor, a disabled CPU 2,
# etc. The exact column layout below is the real one, reproduced verbatim from
# ipmitool's "sdr type" output.

# Build an "ipmitool fru" output
# Usage : make_fru_output [--manufacturer NAME] [--model NAME] [--board-fields-only] [--no-manufacturer]
#
# --board-fields-only reproduces the servers that don't fill the "Product *"
# fields at all and only expose "Board Mfg" / "Board Product", which
# get_Dell_server_model() falls back on
function make_fru_output() {
  local MANUFACTURER="DELL"
  local MODEL="PowerEdge R730xd"
  local BOARD_FIELDS_ONLY=false
  local WITH_MANUFACTURER=true

  while [ $# -gt 0 ]; do
    case "$1" in
      --manufacturer) MANUFACTURER="$2"; shift 2 ;;
      --model) MODEL="$2"; shift 2 ;;
      --board-fields-only) BOARD_FIELDS_ONLY=true; shift ;;
      --no-manufacturer) WITH_MANUFACTURER=false; shift ;;
      *) printf 'make_fru_output: unknown option "%s"\n' "$1" >&2; return 1 ;;
    esac
  done

  printf 'FRU Device Description : Builtin FRU Device (ID 0)\n'
  printf ' Board Mfg Date        : Mon Jan  1 00:00:00 1996\n'
  if $WITH_MANUFACTURER; then
    printf ' Board Mfg             : %s\n' "$MANUFACTURER"
  fi
  printf ' Board Product         : %s\n' "$MODEL"
  printf ' Board Serial          : CN7016360I0026\n'
  printf ' Board Part Number     : 0599V5A05\n'

  if $BOARD_FIELDS_ONLY; then
    return 0
  fi

  if $WITH_MANUFACTURER; then
    printf ' Product Manufacturer  : %s\n' "$MANUFACTURER"
  fi
  printf ' Product Name          : %s\n' "$MODEL"
  printf ' Product Part Number   : 0599V5A05\n'
  printf ' Product Version       : A05\n'
  printf ' Product Serial        : 5N7XXX2\n'
  printf ' Product Asset Tag     :\n'
}

# Build a single "ipmitool sdr type temperature" line
# Usage : make_sdr_line "$SENSOR_NAME" "$SENSOR_ID" "$STATUS" "$ENTITY_ID" "$READING"
function make_sdr_line() {
  printf '%-16s | %s | %-3s | %4s | %s\n' "$1" "$2" "$3" "$4" "$5"
}

# Build an "ipmitool sdr type temperature" output
# Usage : make_sdr_output [option ...]
#   --cpus N                   number of CPU sensors, reported as entities 3.1 to 3.N
#   --cpu-temperatures "40 41" explicit readings, one per CPU (default 40, 41, 42...)
#   --cpu-sensor-id-base N     decimal value of the first CPU sensor's hexadecimal ID.
#                              Defaults to 14 (0Eh, 0Fh...); pass 9 to reproduce an
#                              R930, whose CPU sensor IDs (09h, 0Ah...) used to be
#                              mistaken for temperature readings (issue #91)
#   --inlet N / --no-inlet     inlet sensor reading, or no inlet sensor at all
#   --exhaust N / --no-exhaust exhaust sensor reading, or no exhaust sensor at all
#   --cpu2-disabled            CPU 2 is listed but has no reading ("ns | Disabled"),
#                              like a second socket left empty
#   --with-extra-sensors       add the non-CPU, non-inlet, non-exhaust temperature
#                              sensors bigger servers report (board, PCIe risers)
#   --eleventh-generation-sensor-names
#                              name the chassis sensors the way iDRAC6 does on 11G
#                              servers (R610, R710, R510, T610...) : "Ambient Temp"
#                              for the intake, a "Planar Temp" system board sensor on
#                              the same entity 7.1, and no exhaust sensor at all.
#                              "Inlet Temp" and "Exhaust Temp" only exist from 12G on
function make_sdr_output() {
  local CPU_COUNT=2
  local CPU_TEMPERATURES=""
  local CPU_SENSOR_ID_BASE=14
  local INLET_TEMPERATURE=23
  local EXHAUST_TEMPERATURE=34
  local WITH_INLET=true
  local WITH_EXHAUST=true
  local CPU2_DISABLED=false
  local WITH_EXTRA_SENSORS=false
  local ELEVENTH_GENERATION_SENSOR_NAMES=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --cpus) CPU_COUNT="$2"; shift 2 ;;
      --cpu-temperatures) CPU_TEMPERATURES="$2"; shift 2 ;;
      --cpu-sensor-id-base) CPU_SENSOR_ID_BASE="$2"; shift 2 ;;
      --inlet) INLET_TEMPERATURE="$2"; WITH_INLET=true; shift 2 ;;
      --exhaust) EXHAUST_TEMPERATURE="$2"; WITH_EXHAUST=true; shift 2 ;;
      --no-inlet) WITH_INLET=false; shift ;;
      --no-exhaust) WITH_EXHAUST=false; shift ;;
      --cpu2-disabled) CPU2_DISABLED=true; shift ;;
      --with-extra-sensors) WITH_EXTRA_SENSORS=true; shift ;;
      --eleventh-generation-sensor-names) ELEVENTH_GENERATION_SENSOR_NAMES=true; shift ;;
      *) printf 'make_sdr_output: unknown option "%s"\n' "$1" >&2; return 1 ;;
    esac
  done

  # Inlet and exhaust are both reported as entity 7.1: only their name tells them apart
  if $ELEVENTH_GENERATION_SENSOR_NAMES; then
    # Sensor names and hexadecimal IDs taken from a real R710 "ipmitool sdr elist". iDRAC6 reports
    # no exhaust sensor at all: "Planar Temp" shares entity 7.1 with the intake but is the system
    # board, not the air leaving the chassis, so it is emitted here precisely so that anything
    # tempted to read it as an exhaust reading is caught by a test
    if $WITH_INLET; then
      make_sdr_line "Ambient Temp" "0Eh" "ok" "7.1" "$INLET_TEMPERATURE degrees C"
    fi
    make_sdr_line "Planar Temp" "0Fh" "ok" "7.1" "36 degrees C"
  else
    if $WITH_INLET; then
      make_sdr_line "Inlet Temp" "04h" "ok" "7.1" "$INLET_TEMPERATURE degrees C"
    fi
    if $WITH_EXHAUST; then
      make_sdr_line "Exhaust Temp" "01h" "ok" "7.1" "$EXHAUST_TEMPERATURE degrees C"
    fi
  fi

  local -a REQUESTED_CPU_TEMPERATURES=($CPU_TEMPERATURES)
  local CPU_INDEX
  for ((CPU_INDEX = 1; CPU_INDEX <= CPU_COUNT; CPU_INDEX++)); do
    local SENSOR_ID
    SENSOR_ID=$(printf '%02Xh' "$((CPU_SENSOR_ID_BASE + CPU_INDEX - 1))")

    if $CPU2_DISABLED && [ "$CPU_INDEX" -eq 2 ]; then
      make_sdr_line "Temp" "$SENSOR_ID" "ns" "3.$CPU_INDEX" "Disabled"
      continue
    fi

    local CPU_TEMPERATURE="${REQUESTED_CPU_TEMPERATURES[$((CPU_INDEX - 1))]:-$((39 + CPU_INDEX))}"
    make_sdr_line "Temp" "$SENSOR_ID" "ok" "3.$CPU_INDEX" "$CPU_TEMPERATURE degrees C"
  done

  if $WITH_EXTRA_SENSORS; then
    make_sdr_line "Temp" "0Ah" "ok" "10.1" "38 degrees C"
    make_sdr_line "Temp" "0Bh" "ok" "10.2" "37 degrees C"
    make_sdr_line "PSU1 Inlet Temp" "68h" "ok" "10.1" "29 degrees C"
    make_sdr_line "PSU2 Inlet Temp" "69h" "ok" "10.2" "30 degrees C"
  fi
}

# Point the mocked ipmitool at a given server
# Usage : simulate_server "$SERVER_MODEL" [make_sdr_output option ...]
function simulate_server() {
  local -r SERVER_MODEL="$1"
  shift

  export MOCK_IPMITOOL_FRU_OUTPUT
  MOCK_IPMITOOL_FRU_OUTPUT="$(make_fru_output --model "$SERVER_MODEL")"
  export MOCK_IPMITOOL_SDR_OUTPUT
  MOCK_IPMITOOL_SDR_OUTPUT="$(make_sdr_output "$@")"
}

# The stderr a BMC with no fan of its own answers to Dell's raw fan control
# commands : the command exists in the netfn, but the fans it would drive are not
# behind this BMC, so it is refused outright
readonly ENCLOSURE_REJECTED_FAN_CONTROL_STDERR="Unable to send RAW command (channel=0x0 netfn=0x30 lun=0x0 cmd=0x30 rsp=0xc1): Invalid command"

# Point the mocked ipmitool at a server housed in an enclosure : an M1000e or
# VRTX blade, an FX2 or MX7000 sled, a node of a C-series chassis.
#
# Two things set them apart from a rack server, and both are reproduced here :
#   - they report no exhaust sensor. The airflow leaves through the enclosure,
#     not through the server, so only the enclosure measures it
#   - their fans belong to the enclosure and are driven by its CMC, so their own
#     iDRAC rejects Dell's raw fan control commands whatever the generation
#
# Usage : simulate_enclosure_housed_server "$SERVER_MODEL" [make_sdr_output option ...]
function simulate_enclosure_housed_server() {
  local -r SERVER_MODEL="$1"
  shift

  simulate_server "$SERVER_MODEL" --no-exhaust "$@"

  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0x30"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="$ENCLOSURE_REJECTED_FAN_CONTROL_STDERR"
}

# Point the mocked ipmitool at the enclosure's own management controller (the
# M1000e's or the VRTX's CMC, the MX7000's OME-Modular) rather than at a server
# housed in it.
#
# It is a Dell product and it answers IPMI, so the controller accepts it, but it
# hosts no CPU : it reports the enclosure's own temperature sensors and not a
# single processor entity. Aiming IDRAC_HOST at it is a mistake users do make,
# the enclosure being the address printed on the front panel.
#
# Usage : simulate_enclosure_management_controller "PowerEdge M1000e"
function simulate_enclosure_management_controller() {
  local -r ENCLOSURE_MODEL="$1"

  export MOCK_IPMITOOL_FRU_OUTPUT
  MOCK_IPMITOOL_FRU_OUTPUT="$(make_fru_output --model "$ENCLOSURE_MODEL")"
  export MOCK_IPMITOOL_SDR_OUTPUT
  MOCK_IPMITOOL_SDR_OUTPUT="$(make_sdr_output --cpus 0 --no-exhaust --inlet 22)"
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0x30"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="$ENCLOSURE_REJECTED_FAN_CONTROL_STDERR"
}
