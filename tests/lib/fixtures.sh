#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# Builders for the ipmitool outputs the controller parses: the FRU inventory
# ("ipmitool fru", used to identify the server), the controller's own description
# ("ipmitool mc info", used to log the iDRAC firmware version) and the temperature
# sensor records ("ipmitool sdr type temperature").
#
# Both are generated rather than stored as flat files because the interesting
# dimension is combinatorial: every generation from 9 to 17, in 1, 2 and 4 CPU
# variants, with or without an inlet sensor, an exhaust sensor, a disabled CPU 2,
# etc. The exact column layout below is the real one, reproduced verbatim from
# ipmitool's "sdr type" output.

# Build an "ipmitool fru" output
# Usage : make_fru_output [--manufacturer NAME] [--model NAME] [--board-fields-only] [--no-manufacturer]
#                         [--with-unreadable-devices] [--with-readable-psu]
#
# --board-fields-only reproduces the servers that don't fill the "Product *"
# fields at all and only expose "Board Mfg" / "Board Product", which
# get_Dell_server_model() falls back on
#
# --no-manufacturer reproduces the servers that name themselves but declare no
# manufacturer at all, in either the board or the product fields. Combined with
# --with-readable-psu it is what tells whether the identification is really reading
# the server, or merely the first FRU device that happened to fill the field
#
# --with-unreadable-devices appends the empty drive backplane, PERC and PSU bays that
# a partially populated server reports as unreadable. They are what makes the real
# "ipmitool fru" exit non-zero on hardware that is nonetheless perfectly healthy, and
# they belong to the inventory rather than to the transport, so they show up in local
# and network mode alike (issue #193)
#
# --with-readable-psu appends a POPULATED power supply. It is a FRU device of its
# own, and it fills the very same manufacturer and product fields as the server, so
# it is what makes a parse keeping every match collect two values instead of one
# (issue #319)
#
# The two are independent and combine : a server with an empty drive bay AND a
# populated power supply is ordinary hardware, and it meets both hazards at once
function make_fru_output() {
  local MANUFACTURER="DELL"
  local MODEL="PowerEdge R730xd"
  local BOARD_FIELDS_ONLY=false
  local WITH_MANUFACTURER=true
  local WITH_UNREADABLE_DEVICES=false
  local WITH_READABLE_PSU=false
  local SERIAL="5N7XXX2"
  local WITH_SERIAL=true
  # Written into Board Serial when it differs from the Product one. They are the same by default, which
  # is convenient and is also exactly what hid a defect : the R510 of issue #378 carries NO Product
  # Serial at all and a Board Serial that is a different identifier entirely (issue #469)
  local BOARD_SERIAL=""
  local WITH_PRODUCT_SERIAL=true

  while [ $# -gt 0 ]; do
    case "$1" in
      --manufacturer) MANUFACTURER="$2"; shift 2 ;;
      --model) MODEL="$2"; shift 2 ;;
      --serial) SERIAL="$2"; shift 2 ;;
      --no-serial) WITH_SERIAL=false; shift ;;
      --board-serial) BOARD_SERIAL="$2"; shift 2 ;;
      --no-product-serial) WITH_PRODUCT_SERIAL=false; shift ;;
      --board-fields-only) BOARD_FIELDS_ONLY=true; shift ;;
      --no-manufacturer) WITH_MANUFACTURER=false; shift ;;
      --with-unreadable-devices) WITH_UNREADABLE_DEVICES=true; shift ;;
      --with-readable-psu) WITH_READABLE_PSU=true; shift ;;
      *) printf 'make_fru_output: unknown option "%s"\n' "$1" >&2; return 1 ;;
    esac
  done

  printf 'FRU Device Description : Builtin FRU Device (ID 0)\n'
  printf ' Board Mfg Date        : Mon Jan  1 00:00:00 1996\n'
  if $WITH_MANUFACTURER; then
    printf ' Board Mfg             : %s\n' "$MANUFACTURER"
  fi
  printf ' Board Product         : %s\n' "$MODEL"
  if $WITH_SERIAL; then
    printf ' Board Serial          : %s\n' "${BOARD_SERIAL:-$SERIAL}"
  fi
  printf ' Board Part Number     : 0599V5A05\n'

  if $BOARD_FIELDS_ONLY; then
    if $WITH_READABLE_PSU; then
      make_readable_psu_fru_device --board-fields-only
    fi
    if $WITH_UNREADABLE_DEVICES; then
      make_unreadable_fru_devices
    fi
    return 0
  fi

  if $WITH_MANUFACTURER; then
    printf ' Product Manufacturer  : %s\n' "$MANUFACTURER"
  fi
  printf ' Product Name          : %s\n' "$MODEL"
  printf ' Product Part Number   : 0599V5A05\n'
  printf ' Product Version       : A05\n'
  if $WITH_SERIAL && $WITH_PRODUCT_SERIAL; then
    printf ' Product Serial        : %s\n' "$SERIAL"
  fi
  printf ' Product Asset Tag     :\n'

  if $WITH_READABLE_PSU; then
    make_readable_psu_fru_device
  fi
  if $WITH_UNREADABLE_DEVICES; then
    make_unreadable_fru_devices
  fi
}

# A populated power supply, as "ipmitool fru" lists it after the builtin FRU device
# (ID 0) that describes the server. Its manufacturer is the same string the server
# reports, and its product name is the PSU's own, so a parse taking every match hands
# the caller "DELL\nDELL" and a two-line model.
#
# --board-fields-only reproduces the Dell power supplies that leave the "Product *"
# fields empty : that shape is what reaches get_Dell_server_model()'s board fallback,
# which only runs when the server itself filled no product field either
# Usage : make_readable_psu_fru_device [--board-fields-only]
function make_readable_psu_fru_device() {
  printf '\n'
  printf 'FRU Device Description : PSU1 (ID 1)\n'
  printf ' Board Mfg             : DELL\n'
  printf ' Board Product         : PWR SPLY,750W,RDNT,LTON\n'
  printf ' Board Serial          : CN7792165F0J3B\n'

  if [ "${1:-}" == "--board-fields-only" ]; then
    return 0
  fi

  printf ' Product Manufacturer  : DELL\n'
  printf ' Product Name          : PWR SPLY,750W,RDNT,LTON\n'
  printf ' Product Part Number   : 0PJMDNA01\n'
}

# The empty bays of a partially populated server, as "ipmitool fru" lists them once it
# has walked past the builtin FRU device (ID 0) that identified the server
function make_unreadable_fru_devices() {
  printf '\n'
  printf 'FRU Device Description : BP0 (ID 12)\n'
  printf ' Device not present (Timeout)\n'
  printf '\n'
  printf 'FRU Device Description : BP2 (ID 14)\n'
  printf ' Device not present (Timeout)\n'
  printf '\n'
  printf 'FRU Device Description : PERC2 (ID 11)\n'
  printf ' Device not present (Parameter out of range)\n'
}

# The stderr the real "ipmitool fru" leaves behind when it walked the bus but some of its
# devices did not answer
readonly UNREADABLE_FRU_DEVICES_STDERR="Get Device ID command failed: 0xc9 Parameter out of range"

# Point the mocked ipmitool at a server whose FRU inventory is only partially readable :
# the builtin FRU device (ID 0) identifies it, its empty bays answer nothing, and the walk
# therefore exits non-zero while the inventory still reaches stdout. This is what healthy,
# partially populated hardware returns, and taking it for a connection failure is issue #193
# Usage : simulate_partially_readable_fru_inventory [make_fru_output option ...]
function simulate_partially_readable_fru_inventory() {
  export MOCK_IPMITOOL_FRU_OUTPUT MOCK_IPMITOOL_FRU_STDERR MOCK_IPMITOOL_FRU_EXIT_CODE
  MOCK_IPMITOOL_FRU_OUTPUT="$(make_fru_output --with-unreadable-devices "$@")"
  MOCK_IPMITOOL_FRU_STDERR="$UNREADABLE_FRU_DEVICES_STDERR"
  MOCK_IPMITOOL_FRU_EXIT_CODE=1
}

# Build an "ipmitool mc info" output, the one the iDRAC's own firmware version is read from
# Usage : make_mc_info_output [--firmware-revision VERSION] [--no-firmware-revision]
#
# --firmware-revision takes the two numbers the command reports, not the four a Dell firmware bundle is
# named after : an iDRAC 9 on 6.10.30.00 answers "6.10", the IPMI Get Device ID response having one byte
# for the major version and one for the minor one. The remaining two live in the vendor-specific
# auxiliary field reproduced below, undecoded, exactly as ipmitool prints it -- one hex byte per line,
# which is also what makes it a line the version parser must not pick up
#
# --no-firmware-revision drops the line entirely, for the BMCs that report none
function make_mc_info_output() {
  local FIRMWARE_REVISION="2.86"
  local WITH_FIRMWARE_REVISION=true

  while [ $# -gt 0 ]; do
    case "$1" in
      --firmware-revision) FIRMWARE_REVISION="$2"; shift 2 ;;
      --no-firmware-revision) WITH_FIRMWARE_REVISION=false; shift ;;
      *) printf 'make_mc_info_output: unknown option "%s"\n' "$1" >&2; return 1 ;;
    esac
  done

  printf 'Device ID                 : 32\n'
  printf 'Device Revision           : 1\n'
  if $WITH_FIRMWARE_REVISION; then
    printf 'Firmware Revision         : %s\n' "$FIRMWARE_REVISION"
  fi
  printf 'IPMI Version              : 2.0\n'
  printf 'Manufacturer ID           : 674\n'
  printf 'Manufacturer Name         : DELL Inc\n'
  printf 'Product ID                : 256 (0x0100)\n'
  printf 'Product Name              : Unknown (0x100)\n'
  printf 'Device Available          : yes\n'
  printf 'Provides Device SDRs      : yes\n'
  printf 'Additional Device Support :\n'
  printf '    Sensor Device\n'
  printf '    SDR Repository Device\n'
  printf '    SEL Device\n'
  printf '    FRU Inventory Device\n'
  printf '    IPMB Event Receiver\n'
  printf '    IPMB Event Generator\n'
  printf '    Chassis Device\n'
  printf 'Aux Firmware Rev Info     : \n'
  printf '    0x00\n'
  printf '    0x1d\n'
  printf '    0x1e\n'
  printf '    0x00\n'
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
#   --every-cpu-disabled       EVERY processor entity is listed and none carries a
#                              reading. This is not an empty socket : it is what an
#                              iDRAC6 reports on an 11G server whose CPUs it cannot
#                              measure at all (issue #378, an R510 on firmware 2.92),
#                              and it is the shape the lm-sensors fallback of #216
#                              exists to rescue. Distinct from "--cpus 0", which emits
#                              no processor row at all -- a shape no reported hardware
#                              produces, and the one the fallback used to be tested on
#   --with-extra-sensors       add the non-CPU, non-inlet, non-exhaust temperature
#                              sensors bigger servers report : four power supply
#                              rows, entity 10 being "Power Supply" in IPMI v2.0
#                              table 43-13. Two carry the same uninformative
#                              "Temp" name the CPU rows do, and two are named
#                              "PSU1 Inlet Temp" and "PSU2 Inlet Temp".
#                              That second pair is what the option is for : both
#                              names contain "Inlet", so they are what makes the
#                              anchored match in retrieve_temperature_by_sensor_name()
#                              load-bearing rather than decorative -- unanchored,
#                              a power supply's own intake answers for the chassis
#                              air intake and the intake column shows a sensor
#                              several degrees too hot (issue #231)
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
  local EVERY_CPU_DISABLED=false
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
      --every-cpu-disabled) EVERY_CPU_DISABLED=true; shift ;;
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

    if $EVERY_CPU_DISABLED; then
      make_sdr_line "Temp" "$SENSOR_ID" "ns" "3.$CPU_INDEX" "Disabled"
      continue
    fi

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

# The System attributes of a real PowerEdge R740xd2, as @bitspill posted them on issue #360 on
# 2026-08-29 : iDRAC 9 firmware 3.30.30.30, Enterprise licence, host running.
#
# Every other Redfish body this suite feeds the controller is one make_redfish_attributes_body() built
# to the shape the code expects, which is the shape whoever wrote the code had in mind. This one is not
# invented, and four things in it are only true because an iDRAC produced them :
#
#   - it came from the LEGACY URI. The conformant one answered 404 on this machine, which is why the
#     cases below set MOCK_REDFISH_LEGACY_BODY and leave the conformant status at its 404 default : the
#     fallback is not a defensive branch here, it is the only way this server ever answers ;
#   - it is ordered ALPHABETICALLY, which is how Dell returns these documents. That puts PCIeSlotLFM
#     before ThermalSettings and 3rdPartyCard before LFMMode, so the very first attribute of the object
#     is "PCIeSlotLFM.1.3rdPartyCard" -- the position an anchored pattern used to drop silently (#412) ;
#   - its slots run 1, 10, 11 ... 15, 2, 3 ... 9, because that ordering is lexicographic and not
#     numeric. Nothing here should care, and this is what says so ;
#   - it is the first capture of a server that HAS the setting on 15 slots and holds no third-party
#     card at all : fourteen slots empty and one AHCI controller reading "No". The branch that reports
#     "No third-party PCIe card to apply it to" was written against a mock because no real machine had
#     ever shown it.
#
# What is reproduced is his paste, not the whole document : he ran the capture through
# "tr ',' '\n' | grep -Ei 'thermal|pcieslotlfm|...'", so it arrived one attribute per line and carries
# the four families that filter kept -- PCIeSlotLFM, ThermalConfig, ThermalHistorical and
# ThermalSettings. The two the controller reads are among them, so nothing it looks at is missing ; a
# real body would also hold the several hundred attributes it ignores, and the other two families are
# left in precisely because they are of that kind and the parsers have to walk past them. The
# line-per-attribute form is kept here to stay readable and re-joined below into the single minified
# line the iDRAC really answers with. Within what he posted nothing is added, reordered or corrected --
# 150 attributes, byte for byte and in his order -- including MFSMinimumLimit at 63, the highest of the
# eight machines reported on that issue and the clearest evidence that the floor is not a setpoint.
# Usage : make_captured_r740xd2_attributes_body ["<slot>=<attribute>=<value>" ...]
#         each optional argument replaces one attribute of the capture, for a case that needs a shape
#         the machine did not happen to have
function make_captured_r740xd2_attributes_body() {
  local CAPTURED_ATTRIBUTES
  CAPTURED_ATTRIBUTES=$(cat << 'CAPTURE'
"PCIeSlotLFM.1.3rdPartyCard":"N/A"
"PCIeSlotLFM.1.CardType":"Empty"
"PCIeSlotLFM.1.CustomLFM":0
"PCIeSlotLFM.1.LFMMode":"Automatic"
"PCIeSlotLFM.1.MaxLFM":0
"PCIeSlotLFM.1.PCIeInletTemperature":34
"PCIeSlotLFM.1.SlotState":"Defined"
"PCIeSlotLFM.1.TargetLFM":"-"
"PCIeSlotLFM.10.3rdPartyCard":"N/A"
"PCIeSlotLFM.10.CardType":"Empty"
"PCIeSlotLFM.10.CustomLFM":0
"PCIeSlotLFM.10.LFMMode":"Automatic"
"PCIeSlotLFM.10.MaxLFM":0
"PCIeSlotLFM.10.PCIeInletTemperature":0
"PCIeSlotLFM.10.SlotState":"Not-Defined"
"PCIeSlotLFM.10.TargetLFM":"-"
"PCIeSlotLFM.11.3rdPartyCard":"N/A"
"PCIeSlotLFM.11.CardType":"Empty"
"PCIeSlotLFM.11.CustomLFM":0
"PCIeSlotLFM.11.LFMMode":"Automatic"
"PCIeSlotLFM.11.MaxLFM":0
"PCIeSlotLFM.11.PCIeInletTemperature":0
"PCIeSlotLFM.11.SlotState":"Not-Defined"
"PCIeSlotLFM.11.TargetLFM":"-"
"PCIeSlotLFM.12.3rdPartyCard":"N/A"
"PCIeSlotLFM.12.CardType":"Empty"
"PCIeSlotLFM.12.CustomLFM":0
"PCIeSlotLFM.12.LFMMode":"Automatic"
"PCIeSlotLFM.12.MaxLFM":0
"PCIeSlotLFM.12.PCIeInletTemperature":0
"PCIeSlotLFM.12.SlotState":"Not-Defined"
"PCIeSlotLFM.12.TargetLFM":"-"
"PCIeSlotLFM.13.3rdPartyCard":"N/A"
"PCIeSlotLFM.13.CardType":"Empty"
"PCIeSlotLFM.13.CustomLFM":0
"PCIeSlotLFM.13.LFMMode":"Automatic"
"PCIeSlotLFM.13.MaxLFM":0
"PCIeSlotLFM.13.PCIeInletTemperature":0
"PCIeSlotLFM.13.SlotState":"Not-Defined"
"PCIeSlotLFM.13.TargetLFM":"-"
"PCIeSlotLFM.14.3rdPartyCard":"N/A"
"PCIeSlotLFM.14.CardType":"Empty"
"PCIeSlotLFM.14.CustomLFM":0
"PCIeSlotLFM.14.LFMMode":"Automatic"
"PCIeSlotLFM.14.MaxLFM":0
"PCIeSlotLFM.14.PCIeInletTemperature":0
"PCIeSlotLFM.14.SlotState":"Not-Defined"
"PCIeSlotLFM.14.TargetLFM":"-"
"PCIeSlotLFM.15.3rdPartyCard":"N/A"
"PCIeSlotLFM.15.CardType":"Empty"
"PCIeSlotLFM.15.CustomLFM":0
"PCIeSlotLFM.15.LFMMode":"Automatic"
"PCIeSlotLFM.15.MaxLFM":0
"PCIeSlotLFM.15.PCIeInletTemperature":0
"PCIeSlotLFM.15.SlotState":"Not-Defined"
"PCIeSlotLFM.15.TargetLFM":"-"
"PCIeSlotLFM.2.3rdPartyCard":"No"
"PCIeSlotLFM.2.CardType":"AHCI"
"PCIeSlotLFM.2.CustomLFM":0
"PCIeSlotLFM.2.LFMMode":"Automatic"
"PCIeSlotLFM.2.MaxLFM":390
"PCIeSlotLFM.2.PCIeInletTemperature":34
"PCIeSlotLFM.2.SlotState":"Defined"
"PCIeSlotLFM.2.TargetLFM":"Airflow Controlled"
"PCIeSlotLFM.3.3rdPartyCard":"N/A"
"PCIeSlotLFM.3.CardType":"Empty"
"PCIeSlotLFM.3.CustomLFM":0
"PCIeSlotLFM.3.LFMMode":"Automatic"
"PCIeSlotLFM.3.MaxLFM":330
"PCIeSlotLFM.3.PCIeInletTemperature":34
"PCIeSlotLFM.3.SlotState":"Not-Defined"
"PCIeSlotLFM.3.TargetLFM":"-"
"PCIeSlotLFM.4.3rdPartyCard":"N/A"
"PCIeSlotLFM.4.CardType":"Empty"
"PCIeSlotLFM.4.CustomLFM":0
"PCIeSlotLFM.4.LFMMode":"Automatic"
"PCIeSlotLFM.4.MaxLFM":180
"PCIeSlotLFM.4.PCIeInletTemperature":34
"PCIeSlotLFM.4.SlotState":"Not-Defined"
"PCIeSlotLFM.4.TargetLFM":"-"
"PCIeSlotLFM.5.3rdPartyCard":"N/A"
"PCIeSlotLFM.5.CardType":"Empty"
"PCIeSlotLFM.5.CustomLFM":0
"PCIeSlotLFM.5.LFMMode":"Automatic"
"PCIeSlotLFM.5.MaxLFM":260
"PCIeSlotLFM.5.PCIeInletTemperature":34
"PCIeSlotLFM.5.SlotState":"Not-Defined"
"PCIeSlotLFM.5.TargetLFM":"-"
"PCIeSlotLFM.6.3rdPartyCard":"N/A"
"PCIeSlotLFM.6.CardType":"Empty"
"PCIeSlotLFM.6.CustomLFM":0
"PCIeSlotLFM.6.LFMMode":"Automatic"
"PCIeSlotLFM.6.MaxLFM":290
"PCIeSlotLFM.6.PCIeInletTemperature":34
"PCIeSlotLFM.6.SlotState":"Not-Defined"
"PCIeSlotLFM.6.TargetLFM":"-"
"PCIeSlotLFM.7.3rdPartyCard":"N/A"
"PCIeSlotLFM.7.CardType":"Empty"
"PCIeSlotLFM.7.CustomLFM":0
"PCIeSlotLFM.7.LFMMode":"Automatic"
"PCIeSlotLFM.7.MaxLFM":0
"PCIeSlotLFM.7.PCIeInletTemperature":0
"PCIeSlotLFM.7.SlotState":"Not-Defined"
"PCIeSlotLFM.7.TargetLFM":"-"
"PCIeSlotLFM.8.3rdPartyCard":"N/A"
"PCIeSlotLFM.8.CardType":"Empty"
"PCIeSlotLFM.8.CustomLFM":0
"PCIeSlotLFM.8.LFMMode":"Automatic"
"PCIeSlotLFM.8.MaxLFM":0
"PCIeSlotLFM.8.PCIeInletTemperature":0
"PCIeSlotLFM.8.SlotState":"Not-Defined"
"PCIeSlotLFM.8.TargetLFM":"-"
"PCIeSlotLFM.9.3rdPartyCard":"N/A"
"PCIeSlotLFM.9.CardType":"Empty"
"PCIeSlotLFM.9.CustomLFM":0
"PCIeSlotLFM.9.LFMMode":"Automatic"
"PCIeSlotLFM.9.MaxLFM":0
"PCIeSlotLFM.9.PCIeInletTemperature":0
"PCIeSlotLFM.9.SlotState":"Not-Defined"
"PCIeSlotLFM.9.TargetLFM":"-"
"ThermalConfig.1.CriticalEventGenerationInterval":30
"ThermalConfig.1.EventGenerationInterval":30
"ThermalConfig.1.FreshAirCompliantConfiguration":"Not Applicable"
"ThermalConfig.1.MaxCFM":61
"ThermalConfig.1.ValidFanConfiguration":"Yes"
"ThermalHistorical.1.IntervalInSeconds":0
"ThermalSettings.1.AirExhaustTemp":"70"
"ThermalSettings.1.AirExhaustTempSupport":"Supported"
"ThermalSettings.1.AirTemperatureRiseLimit":"NO LIMIT"
"ThermalSettings.1.AirTemperatureRiseLimitSupport":"Not Supported"
"ThermalSettings.1.CurrentSystemProfileValue":"Minimum Power"
"ThermalSettings.1.FanSpeedHighOffsetVal":75
"ThermalSettings.1.FanSpeedLowOffsetVal":25
"ThermalSettings.1.FanSpeedMaxOffsetVal":100
"ThermalSettings.1.FanSpeedMediumOffsetVal":50
"ThermalSettings.1.FanSpeedOffset":"Off"
"ThermalSettings.1.MFSMaximumLimit":100
"ThermalSettings.1.MFSMinimumLimit":63
"ThermalSettings.1.MaximumPCIeInletTemperatureLimit":"55"
"ThermalSettings.1.MaximumPCIeInletTemperatureLimitSupport":"Not Supported"
"ThermalSettings.1.MinimumFanSpeed":255
"ThermalSettings.1.PCIeSlotLFMSupport":"Supported"
"ThermalSettings.1.SetAirTemperatureRiseLimit":"Disabled"
"ThermalSettings.1.SetMaximumExhaustTemperatureLimit":"Disabled"
"ThermalSettings.1.SystemCFMSupport":"Supported"
"ThermalSettings.1.SystemExhaustTemperature":38
"ThermalSettings.1.SystemInletTemperature":23
"ThermalSettings.1.SystemInletTemperatureSupportLimitPerConfiguration":30
"ThermalSettings.1.TargetExhaustTemperatureLimit":70
"ThermalSettings.1.ThermalProfile":"Sound Cap"
CAPTURE
  )

  local REPLACEMENT SLOT ATTRIBUTE VALUE
  for REPLACEMENT in "$@"; do
    SLOT="${REPLACEMENT%%=*}"
    ATTRIBUTE="${REPLACEMENT#*=}"
    VALUE="${ATTRIBUTE#*=}"
    ATTRIBUTE="${ATTRIBUTE%%=*}"
    CAPTURED_ATTRIBUTES=$(printf '%s\n' "$CAPTURED_ATTRIBUTES" |
      sed "s|^\"PCIeSlotLFM\.${SLOT}\.${ATTRIBUTE}\":.*$|\"PCIeSlotLFM.${SLOT}.${ATTRIBUTE}\":\"${VALUE}\"|")
  done

  local MINIFIED
  MINIFIED=$(printf '%s\n' "$CAPTURED_ATTRIBUTES" | paste -sd ',' -)

  printf '{"Attributes":{%s}}' "$MINIFIED"
}
