#!/bin/bash

# Catalogue of Dell PowerEdge servers, from the 9th generation (2006) to the
# 17th (2024), used to drive the model detection tests.
#
# Columns, pipe-separated :
#   1. PowerEdge generation number (9 to 17)
#   2. model, as "ipmitool fru" reports it in "Product Name"
#   3. maximum number of CPU sockets of that model
#   4. expected value of the controller's DELL_POWEREDGE_GEN_14_OR_NEWER flag
#   5. whether Dell's IPMI raw fan control commands work on that server :
#        supported          - iDRAC 6/7/8, the raw commands work
#        firmware-dependent - iDRAC 9, works below firmware 3.30.30.30 only
#        unsupported        - iDRAC 9 (recent firmware) / iDRAC 10, the raw
#                             commands are rejected by the BMC
#
# /!\ Column 4 records what the controller CURRENTLY detects, not the actual
# generation of the server. The detection is a match on the model name
# ("[RT]<digit>[4-9]0"), so it structurally cannot recognize the models Dell
# named differently : the AMD ones (R6515, R7525, R6615, R7725...), the dense
# and modular ones (C6420, M640, MX740c), and the specialty ones (XR11, XE9680).
# Those are Gen 14 or newer yet detected as older, which makes the controller
# send them the Gen 13-and-older third-party PCIe card cooling response command.
# It is harmless (the BMC rejects an unknown command and the controller discards
# that error on purpose) but it is a real blind spot, so the catalogue records it
# explicitly instead of hiding it, and one test documents it on its own.

readonly DELL_SERVER_CATALOGUE=(
  # 9th generation (2006) - BMC / DRAC 5
  "9|PowerEdge 1950|2|false|supported"
  "9|PowerEdge 1955|2|false|supported"
  "9|PowerEdge 2900|2|false|supported"
  "9|PowerEdge 2950|2|false|supported"

  # 10th generation (2007) - iDRAC 6
  "10|PowerEdge R300|1|false|supported"
  "10|PowerEdge T300|1|false|supported"
  "10|PowerEdge R805|2|false|supported"
  "10|PowerEdge T605|2|false|supported"
  "10|PowerEdge R900|4|false|supported"
  "10|PowerEdge R905|4|false|supported"

  # 11th generation (2009) - iDRAC 6
  "11|PowerEdge R210|1|false|supported"
  "11|PowerEdge R310|1|false|supported"
  "11|PowerEdge T110|1|false|supported"
  "11|PowerEdge T310|1|false|supported"
  "11|PowerEdge R410|2|false|supported"
  "11|PowerEdge R415|2|false|supported"
  "11|PowerEdge R510|2|false|supported"
  "11|PowerEdge R610|2|false|supported"
  "11|PowerEdge R710|2|false|supported"
  "11|PowerEdge R715|2|false|supported"
  "11|PowerEdge T610|2|false|supported"
  "11|PowerEdge T710|2|false|supported"
  "11|PowerEdge R810|4|false|supported"
  "11|PowerEdge R815|4|false|supported"
  "11|PowerEdge R910|4|false|supported"

  # 12th generation (2012) - iDRAC 7
  "12|PowerEdge R220|1|false|supported"
  "12|PowerEdge R320|1|false|supported"
  "12|PowerEdge T320|1|false|supported"
  "12|PowerEdge R420|2|false|supported"
  "12|PowerEdge R520|2|false|supported"
  "12|PowerEdge R620|2|false|supported"
  "12|PowerEdge R720|2|false|supported"
  "12|PowerEdge R720xd|2|false|supported"
  "12|PowerEdge T420|2|false|supported"
  "12|PowerEdge T620|2|false|supported"
  "12|PowerEdge M620|2|false|supported"
  "12|PowerEdge R820|4|false|supported"
  "12|PowerEdge R920|4|false|supported"

  # 13th generation (2014) - iDRAC 8
  "13|PowerEdge R230|1|false|supported"
  "13|PowerEdge R330|1|false|supported"
  "13|PowerEdge T130|1|false|supported"
  "13|PowerEdge T330|1|false|supported"
  "13|PowerEdge R430|2|false|supported"
  "13|PowerEdge R530|2|false|supported"
  "13|PowerEdge R630|2|false|supported"
  "13|PowerEdge R730|2|false|supported"
  "13|PowerEdge R730xd|2|false|supported"
  "13|PowerEdge T430|2|false|supported"
  "13|PowerEdge T630|2|false|supported"
  "13|PowerEdge M630|2|false|supported"
  "13|PowerEdge FC630|2|false|supported"
  "13|PowerEdge R830|4|false|supported"
  "13|PowerEdge R930|4|false|supported"

  # 14th generation (2017) - iDRAC 9
  "14|PowerEdge R240|1|true|firmware-dependent"
  "14|PowerEdge R340|1|true|firmware-dependent"
  "14|PowerEdge T140|1|true|firmware-dependent"
  "14|PowerEdge T340|1|true|firmware-dependent"
  "14|PowerEdge R440|2|true|firmware-dependent"
  "14|PowerEdge R540|2|true|firmware-dependent"
  "14|PowerEdge R640|2|true|firmware-dependent"
  "14|PowerEdge R740|2|true|firmware-dependent"
  "14|PowerEdge R740xd|2|true|firmware-dependent"
  "14|PowerEdge T440|2|true|firmware-dependent"
  "14|PowerEdge T640|2|true|firmware-dependent"
  "14|PowerEdge R840|4|true|firmware-dependent"
  "14|PowerEdge R940|4|true|firmware-dependent"
  "14|PowerEdge R940xa|4|true|firmware-dependent"
  # Models Dell named outside the "[RT]<digit><digit>0" scheme : detected as Gen 13 or older
  "14|PowerEdge R6415|1|false|firmware-dependent"
  "14|PowerEdge R7415|1|false|firmware-dependent"
  "14|PowerEdge R7425|2|false|firmware-dependent"
  "14|PowerEdge C6420|2|false|firmware-dependent"
  "14|PowerEdge M640|2|false|firmware-dependent"
  "14|PowerEdge MX740c|2|false|firmware-dependent"

  # 15th generation (2021) - iDRAC 9, IPMI raw fan control removed by firmware
  "15|PowerEdge R250|1|true|unsupported"
  "15|PowerEdge R350|1|true|unsupported"
  "15|PowerEdge T150|1|true|unsupported"
  "15|PowerEdge T350|1|true|unsupported"
  "15|PowerEdge R450|2|true|unsupported"
  "15|PowerEdge R550|2|true|unsupported"
  "15|PowerEdge R650|2|true|unsupported"
  "15|PowerEdge R650xs|2|true|unsupported"
  "15|PowerEdge R750|2|true|unsupported"
  "15|PowerEdge R750xa|2|true|unsupported"
  "15|PowerEdge R750xs|2|true|unsupported"
  "15|PowerEdge T550|2|true|unsupported"
  "15|PowerEdge R6515|1|false|unsupported"
  "15|PowerEdge R7515|1|false|unsupported"
  "15|PowerEdge XR11|1|false|unsupported"
  "15|PowerEdge XR12|1|false|unsupported"
  "15|PowerEdge R6525|2|false|unsupported"
  "15|PowerEdge R7525|2|false|unsupported"

  # 16th generation (2023) - iDRAC 9, IPMI raw fan control removed by firmware
  "16|PowerEdge R260|1|true|unsupported"
  "16|PowerEdge R360|1|true|unsupported"
  "16|PowerEdge T160|1|true|unsupported"
  "16|PowerEdge T360|1|true|unsupported"
  "16|PowerEdge R460|2|true|unsupported"
  "16|PowerEdge R560|2|true|unsupported"
  "16|PowerEdge R660|2|true|unsupported"
  "16|PowerEdge R760|2|true|unsupported"
  "16|PowerEdge R760xa|2|true|unsupported"
  "16|PowerEdge T560|2|true|unsupported"
  "16|PowerEdge R860|4|true|unsupported"
  "16|PowerEdge R960|4|true|unsupported"
  "16|PowerEdge R6615|1|false|unsupported"
  "16|PowerEdge R7615|1|false|unsupported"
  "16|PowerEdge R6625|2|false|unsupported"
  "16|PowerEdge R7625|2|false|unsupported"
  "16|PowerEdge C6620|2|false|unsupported"
  "16|PowerEdge XE9680|2|false|unsupported"

  # 17th generation (2024) - iDRAC 10, no IPMI raw fan control at all
  "17|PowerEdge R470|2|true|unsupported"
  "17|PowerEdge R570|2|true|unsupported"
  "17|PowerEdge R670|2|true|unsupported"
  "17|PowerEdge R770|2|true|unsupported"
  "17|PowerEdge R6715|1|false|unsupported"
  "17|PowerEdge R7715|1|false|unsupported"
  "17|PowerEdge R6725|2|false|unsupported"
  "17|PowerEdge R7725|2|false|unsupported"
  "17|PowerEdge XE7745|2|false|unsupported"
)

# Every generation the catalogue covers
readonly DELL_SERVER_GENERATIONS=(9 10 11 12 13 14 15 16 17)

# Print the catalogue entries of a given generation
# Usage : catalogue_entries_of_generation $GENERATION
function catalogue_entries_of_generation() {
  local -r GENERATION="$1"
  local ENTRY

  for ENTRY in "${DELL_SERVER_CATALOGUE[@]}"; do
    if [ "${ENTRY%%|*}" == "$GENERATION" ]; then
      printf '%s\n' "$ENTRY"
    fi
  done
}

# Print the catalogue entries whose IPMI fan control support column matches
# Usage : catalogue_entries_with_fan_control_support "unsupported"
function catalogue_entries_with_fan_control_support() {
  local -r SUPPORT="$1"
  local ENTRY

  for ENTRY in "${DELL_SERVER_CATALOGUE[@]}"; do
    if [ "${ENTRY##*|}" == "$SUPPORT" ]; then
      printf '%s\n' "$ENTRY"
    fi
  done
}

# Print the catalogue entries whose model has the given number of CPU sockets
# Usage : catalogue_entries_with_sockets 4
function catalogue_entries_with_sockets() {
  local -r SOCKETS="$1"
  local ENTRY
  local ENTRY_SOCKETS

  for ENTRY in "${DELL_SERVER_CATALOGUE[@]}"; do
    IFS='|' read -r _ _ ENTRY_SOCKETS _ _ <<< "$ENTRY"
    if [ "$ENTRY_SOCKETS" == "$SOCKETS" ]; then
      printf '%s\n' "$ENTRY"
    fi
  done
}

# Reproduce the controller's own generation detection, so that a test asserts
# against the very expression Dell_iDRAC_fan_controller.sh uses. The expression
# is read from the script instead of being copied here, so that the tests cannot
# silently keep validating an outdated copy of it
# Usage : is_detected_as_gen_14_or_newer "$SERVER_MODEL"
function is_detected_as_gen_14_or_newer() {
  local -r SERVER_MODEL="$1"

  [[ $SERVER_MODEL =~ $GENERATION_14_OR_NEWER_REGEX ]]
}

# Extract the generation detection regular expression from the controller script
# Usage : GENERATION_14_OR_NEWER_REGEX=$(read_generation_detection_regex)
function read_generation_detection_regex() {
  grep -oE '^if \[\[ \$SERVER_MODEL =~ .* \]\]; then$' "$REPO_ROOT/Dell_iDRAC_fan_controller.sh" |
    sed -E 's/^if \[\[ \$SERVER_MODEL =~ //; s/ \]\]; then$//'
}
