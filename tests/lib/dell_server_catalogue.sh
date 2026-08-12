#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# Catalogue of Dell PowerEdge servers, from the 9th generation (2006) to the
# 17th (2024), used to drive the model detection tests.
#
# Columns, pipe-separated :
#   1. PowerEdge generation number (9 to 17)
#   2. model, as "ipmitool fru" reports it in "Product Name"
#   3. maximum number of CPU sockets of that model
#   4. whether Dell's IPMI raw fan control commands work on that server :
#        supported          - iDRAC 6/7/8, the raw commands work
#        firmware-dependent - iDRAC 9, works up to firmware 3.30.30.30 only
#        unsupported        - iDRAC 9 (recent firmware) / iDRAC 10, the raw
#                             commands are rejected by the BMC
#        chassis-managed    - the server carries no fan of its own : they belong
#                             to the enclosure and are driven by its CMC (or, on
#                             an MX7000, by OME-Modular). Whatever its
#                             generation, the raw fan control commands sent to
#                             the server's own iDRAC control nothing
#   5. enclosure the server is housed in, or "standalone" for the rack and tower
#      servers that carry their own fans. Several enclosures accept the same
#      server, separated by "/" :
#        1955    - 9th generation blade enclosure
#        M1000e  - blade enclosure, 10th to 14th generation blades (M...)
#        VRTX    - small office blade enclosure, taking a subset of the
#                  M1000e blades (half-height ones, and full-height ones over
#                  two slots)
#        FX2     - modular enclosure, FC... and FM... sleds
#        MX7000  - modular enclosure, MX...c sleds
#        C-series- multi-node chassis (C6300, C6400, C6500, C6600), 4 nodes
#                  sharing the chassis fans
#
# The catalogue used to carry a fifth column recording what the controller's
# model-name check detected, alongside the generation the server really is. The
# two disagreed for 23 models — the AMD ones (R6515, R7525, R6615, R7725...), the
# dense and modular ones (C6420, M640, MX740c), the specialty ones (XR11, XE9680)
# — because Dell never named them to a scheme a pattern could follow. That check
# is gone (issue #173) : the controller now asks the server whether it takes the
# command instead of guessing from its name, so there is no longer a detection to
# hold expectations about, and the column went with it.

readonly DELL_SERVER_CATALOGUE=(
  # 9th generation (2006) - BMC / DRAC 5
  "9|PowerEdge 1950|2|supported|standalone"
  "9|PowerEdge 2900|2|supported|standalone"
  "9|PowerEdge 2950|2|supported|standalone"
  # The first Dell blade, in the enclosure that preceded the M1000e
  "9|PowerEdge 1955|2|chassis-managed|1955"

  # 10th generation (2007) - iDRAC 6
  "10|PowerEdge R300|1|supported|standalone"
  "10|PowerEdge T300|1|supported|standalone"
  "10|PowerEdge R805|2|supported|standalone"
  "10|PowerEdge T605|2|supported|standalone"
  "10|PowerEdge R900|4|supported|standalone"
  "10|PowerEdge R905|4|supported|standalone"
  # M1000e blades, the enclosure Dell introduced with this generation
  "10|PowerEdge M600|2|chassis-managed|M1000e"
  "10|PowerEdge M605|2|chassis-managed|M1000e"
  "10|PowerEdge M805|2|chassis-managed|M1000e"
  "10|PowerEdge M905|4|chassis-managed|M1000e"

  # 11th generation (2009) - iDRAC 6
  "11|PowerEdge R210|1|supported|standalone"
  "11|PowerEdge R310|1|supported|standalone"
  "11|PowerEdge T110|1|supported|standalone"
  "11|PowerEdge T310|1|supported|standalone"
  "11|PowerEdge R410|2|supported|standalone"
  "11|PowerEdge R415|2|supported|standalone"
  "11|PowerEdge R510|2|supported|standalone"
  "11|PowerEdge R610|2|supported|standalone"
  "11|PowerEdge R710|2|supported|standalone"
  "11|PowerEdge R715|2|supported|standalone"
  "11|PowerEdge T610|2|supported|standalone"
  "11|PowerEdge T710|2|supported|standalone"
  "11|PowerEdge R810|4|supported|standalone"
  "11|PowerEdge R815|4|supported|standalone"
  "11|PowerEdge R910|4|supported|standalone"
  # M1000e blades
  "11|PowerEdge M610|2|chassis-managed|M1000e"
  "11|PowerEdge M710|2|chassis-managed|M1000e"
  "11|PowerEdge M710HD|2|chassis-managed|M1000e"
  "11|PowerEdge M910|4|chassis-managed|M1000e"
  "11|PowerEdge M915|4|chassis-managed|M1000e"

  # 12th generation (2012) - iDRAC 7
  "12|PowerEdge R220|1|supported|standalone"
  "12|PowerEdge R320|1|supported|standalone"
  "12|PowerEdge T320|1|supported|standalone"
  "12|PowerEdge R420|2|supported|standalone"
  "12|PowerEdge R520|2|supported|standalone"
  "12|PowerEdge R620|2|supported|standalone"
  "12|PowerEdge R720|2|supported|standalone"
  "12|PowerEdge R720xd|2|supported|standalone"
  "12|PowerEdge T420|2|supported|standalone"
  "12|PowerEdge T620|2|supported|standalone"
  "12|PowerEdge R820|4|supported|standalone"
  "12|PowerEdge R920|4|supported|standalone"
  # Blades. The VRTX arrived with this generation
  "12|PowerEdge M420|2|chassis-managed|M1000e"
  "12|PowerEdge M520|2|chassis-managed|M1000e/VRTX"
  "12|PowerEdge M620|2|chassis-managed|M1000e/VRTX"
  "12|PowerEdge M820|4|chassis-managed|M1000e/VRTX"

  # 13th generation (2014) - iDRAC 8
  "13|PowerEdge R230|1|supported|standalone"
  "13|PowerEdge R330|1|supported|standalone"
  "13|PowerEdge T130|1|supported|standalone"
  "13|PowerEdge T330|1|supported|standalone"
  "13|PowerEdge R430|2|supported|standalone"
  "13|PowerEdge R530|2|supported|standalone"
  "13|PowerEdge R630|2|supported|standalone"
  "13|PowerEdge R730|2|supported|standalone"
  "13|PowerEdge R730xd|2|supported|standalone"
  "13|PowerEdge T430|2|supported|standalone"
  "13|PowerEdge T630|2|supported|standalone"
  "13|PowerEdge R830|4|supported|standalone"
  "13|PowerEdge R930|4|supported|standalone"
  # Blades, FX2 sleds and the first dense multi-node chassis
  "13|PowerEdge M630|2|chassis-managed|M1000e/VRTX"
  "13|PowerEdge M830|4|chassis-managed|M1000e/VRTX"
  "13|PowerEdge FC430|2|chassis-managed|FX2"
  "13|PowerEdge FC630|2|chassis-managed|FX2"
  "13|PowerEdge FC830|4|chassis-managed|FX2"
  "13|PowerEdge C6320|2|chassis-managed|C-series"

  # 14th generation (2017) - iDRAC 9
  "14|PowerEdge R240|1|firmware-dependent|standalone"
  "14|PowerEdge R340|1|firmware-dependent|standalone"
  "14|PowerEdge T140|1|firmware-dependent|standalone"
  "14|PowerEdge T340|1|firmware-dependent|standalone"
  "14|PowerEdge R440|2|firmware-dependent|standalone"
  "14|PowerEdge R540|2|firmware-dependent|standalone"
  "14|PowerEdge R640|2|firmware-dependent|standalone"
  "14|PowerEdge R740|2|firmware-dependent|standalone"
  "14|PowerEdge R740xd|2|firmware-dependent|standalone"
  "14|PowerEdge T440|2|firmware-dependent|standalone"
  "14|PowerEdge T640|2|firmware-dependent|standalone"
  "14|PowerEdge R840|4|firmware-dependent|standalone"
  "14|PowerEdge R940|4|firmware-dependent|standalone"
  "14|PowerEdge R940xa|4|firmware-dependent|standalone"
  # Models Dell named outside the "[RT]<digit><digit>0" scheme : detected as Gen 13 or older
  "14|PowerEdge R6415|1|firmware-dependent|standalone"
  "14|PowerEdge R7415|1|firmware-dependent|standalone"
  "14|PowerEdge R7425|2|firmware-dependent|standalone"
  # Blades, FX2 sleds, the MX7000 that replaced the M1000e, and dense nodes
  "14|PowerEdge M640|2|chassis-managed|M1000e/VRTX"
  "14|PowerEdge FC640|2|chassis-managed|FX2"
  "14|PowerEdge MX740c|2|chassis-managed|MX7000"
  "14|PowerEdge MX840c|4|chassis-managed|MX7000"
  "14|PowerEdge C6420|2|chassis-managed|C-series"

  # 15th generation (2021) - iDRAC 9, IPMI raw fan control removed by firmware
  "15|PowerEdge R250|1|unsupported|standalone"
  "15|PowerEdge R350|1|unsupported|standalone"
  "15|PowerEdge T150|1|unsupported|standalone"
  "15|PowerEdge T350|1|unsupported|standalone"
  "15|PowerEdge R450|2|unsupported|standalone"
  "15|PowerEdge R550|2|unsupported|standalone"
  "15|PowerEdge R650|2|unsupported|standalone"
  "15|PowerEdge R650xs|2|unsupported|standalone"
  "15|PowerEdge R750|2|unsupported|standalone"
  "15|PowerEdge R750xa|2|unsupported|standalone"
  "15|PowerEdge R750xs|2|unsupported|standalone"
  "15|PowerEdge T550|2|unsupported|standalone"
  "15|PowerEdge R6515|1|unsupported|standalone"
  "15|PowerEdge R7515|1|unsupported|standalone"
  "15|PowerEdge XR11|1|unsupported|standalone"
  "15|PowerEdge XR12|1|unsupported|standalone"
  "15|PowerEdge R6525|2|unsupported|standalone"
  "15|PowerEdge R7525|2|unsupported|standalone"
  # MX7000 sleds and dense nodes
  "15|PowerEdge MX750c|2|chassis-managed|MX7000"
  "15|PowerEdge C6520|2|chassis-managed|C-series"
  "15|PowerEdge C6525|2|chassis-managed|C-series"

  # 16th generation (2023) - iDRAC 9, IPMI raw fan control removed by firmware
  "16|PowerEdge R260|1|unsupported|standalone"
  "16|PowerEdge R360|1|unsupported|standalone"
  "16|PowerEdge T160|1|unsupported|standalone"
  "16|PowerEdge T360|1|unsupported|standalone"
  "16|PowerEdge R460|2|unsupported|standalone"
  "16|PowerEdge R560|2|unsupported|standalone"
  "16|PowerEdge R660|2|unsupported|standalone"
  "16|PowerEdge R760|2|unsupported|standalone"
  "16|PowerEdge R760xa|2|unsupported|standalone"
  "16|PowerEdge T560|2|unsupported|standalone"
  "16|PowerEdge R860|4|unsupported|standalone"
  "16|PowerEdge R960|4|unsupported|standalone"
  "16|PowerEdge R6615|1|unsupported|standalone"
  "16|PowerEdge R7615|1|unsupported|standalone"
  "16|PowerEdge R6625|2|unsupported|standalone"
  "16|PowerEdge R7625|2|unsupported|standalone"
  "16|PowerEdge XE9680|2|unsupported|standalone"
  # MX7000 sleds and dense nodes
  "16|PowerEdge MX760c|2|chassis-managed|MX7000"
  "16|PowerEdge C6615|1|chassis-managed|C-series"
  "16|PowerEdge C6620|2|chassis-managed|C-series"

  # 17th generation (2024) - iDRAC 10, no IPMI raw fan control at all
  "17|PowerEdge R470|2|unsupported|standalone"
  "17|PowerEdge R570|2|unsupported|standalone"
  "17|PowerEdge R670|2|unsupported|standalone"
  "17|PowerEdge R770|2|unsupported|standalone"
  "17|PowerEdge R6715|1|unsupported|standalone"
  "17|PowerEdge R7715|1|unsupported|standalone"
  "17|PowerEdge R6725|2|unsupported|standalone"
  "17|PowerEdge R7725|2|unsupported|standalone"
  "17|PowerEdge XE7745|2|unsupported|standalone"
)

# Every generation the catalogue covers
readonly DELL_SERVER_GENERATIONS=(9 10 11 12 13 14 15 16 17)

# Every enclosure the catalogue covers, in the order Dell released them
readonly DELL_SERVER_ENCLOSURES=(1955 M1000e VRTX FX2 MX7000 C-series)

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
  local ENTRY_SUPPORT

  for ENTRY in "${DELL_SERVER_CATALOGUE[@]}"; do
    IFS='|' read -r _ _ _ ENTRY_SUPPORT _ <<< "$ENTRY"
    if [ "$ENTRY_SUPPORT" == "$SUPPORT" ]; then
      printf '%s\n' "$ENTRY"
    fi
  done
}

# Print the catalogue entries of the servers that carry no fan of their own : the
# blades, the modular sleds and the dense multi-node servers, whose fans belong
# to the enclosure and are driven by its CMC
# Usage : catalogue_entries_housed_in_an_enclosure
function catalogue_entries_housed_in_an_enclosure() {
  local ENTRY
  local ENTRY_ENCLOSURE

  for ENTRY in "${DELL_SERVER_CATALOGUE[@]}"; do
    IFS='|' read -r _ _ _ _ ENTRY_ENCLOSURE <<< "$ENTRY"
    if [ "$ENTRY_ENCLOSURE" != "standalone" ]; then
      printf '%s\n' "$ENTRY"
    fi
  done
}

# Print the catalogue entries of the servers a given enclosure accepts. A server
# several enclosures accept lists them all, separated by "/", so the column is
# matched field by field rather than as a whole
# Usage : catalogue_entries_housed_in_enclosure "VRTX"
function catalogue_entries_housed_in_enclosure() {
  local -r ENCLOSURE="$1"
  local ENTRY
  local ENTRY_ENCLOSURES
  local CANDIDATE

  for ENTRY in "${DELL_SERVER_CATALOGUE[@]}"; do
    IFS='|' read -r _ _ _ _ ENTRY_ENCLOSURES <<< "$ENTRY"
    while IFS= read -r CANDIDATE; do
      if [ "$CANDIDATE" == "$ENCLOSURE" ]; then
        printf '%s\n' "$ENTRY"
        break
      fi
    done < <(printf '%s\n' "${ENTRY_ENCLOSURES//\//$'\n'}")
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


