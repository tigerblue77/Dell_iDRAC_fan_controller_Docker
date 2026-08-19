#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# The third-party PCIe card cooling response on servers whose IPMI command for it
# is gone.
#
# Dell moved this setting at the 14th generation. Up to the 13th it is one OEM IPMI
# command covering the whole server ; from the 14th it is one Redfish attribute per
# PCIe slot, PCIeSlotLFM.<n>.LFMMode, and the IPMI command answers rsp=0xc1.
#
# The controller used to report that as "Not supported by this server", which is
# true of the command and can be false of the server : owners of those machines set
# the very same control by hand in the iDRAC web interface. These cases pin that it
# now asks before saying so, and that every way of not getting an answer leaves the
# old wording rather than inventing a capability.
#
# What is deliberately NOT built on is ThermalSettings.1.PCIeSlotLFMSupport, the
# flag that names this exact feature : it reads "Not Supported" on machines whose
# slot instances are populated and in use. See the last case below.

# A System attributes document as an iDRAC minifies it, carrying one LFMMode per
# slot. --slots sets how many, --support sets what the (untrustworthy) support flag
# claims
function make_redfish_attributes_body() {
  local SLOT_COUNT=2
  local SUPPORT_FLAG="Supported"
  local THIRD_PARTY_SLOTS=""
  local LFM_MODE="Automatic"

  while [ $# -gt 0 ]; do
    case "$1" in
      --slots) SLOT_COUNT="$2"; shift 2 ;;
      --support) SUPPORT_FLAG="$2"; shift 2 ;;
      --third-party) THIRD_PARTY_SLOTS=" $2 "; shift 2 ;;
      --mode) LFM_MODE="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  local BODY='{"@odata.id":"/redfish/v1","Attributes":{"ThermalSettings.1.ThermalProfile":"Default Thermal Profile Settings"'
  BODY+=',"ThermalSettings.1.PCIeSlotLFMSupport":"'"$SUPPORT_FLAG"'"'

  local SLOT
  local CARD
  for ((SLOT = 1; SLOT <= SLOT_COUNT; SLOT++)); do
    if [[ "$THIRD_PARTY_SLOTS" == *" $SLOT "* ]]; then
      CARD="Yes"
    else
      CARD="No"
    fi
    BODY+=',"PCIeSlotLFM.'"$SLOT"'.LFMMode":"'"$LFM_MODE"'","PCIeSlotLFM.'"$SLOT"'.3rdPartyCard":"'"$CARD"'"'
  done

  BODY+='}}'
  printf '%s' "$BODY"
}

# A server that has the setting, on the URI that exists from iDRAC 9 5.x onwards
function simulate_a_server_exposing_the_cooling_response_over_redfish() {
  export MOCK_REDFISH_CONFORMANT_STATUS="200"
  export MOCK_REDFISH_CONFORMANT_BODY
  MOCK_REDFISH_CONFORMANT_BODY=$(make_redfish_attributes_body "$@")
  # A server that remembers what it was told, which is what makes "written once"
  # and "put back on the way out" mean anything
  export MOCK_REDFISH_STATE_FILE="$TEST_TEMPORARY_DIRECTORY/redfish_state"
  : > "$MOCK_REDFISH_STATE_FILE"
}

function test_a_server_that_lost_the_command_but_kept_the_setting_is_not_told_it_lacks_it() {
  simulate_a_server_exposing_the_cooling_response_over_redfish --slots 34

  does_this_server_expose_the_cooling_response_over_redfish

  assert_equals "0" "$?" "the LFMMode instances are there, so the server has the setting"
  assert_equals "34" "$REDFISH_COOLING_RESPONSE_SLOT_COUNT" \
    "every slot carrying LFMMode should be counted, so the message can say how many"
}

function test_the_conformant_uri_is_tried_first_and_the_legacy_one_only_after_a_404() {
  # Neither URI reaches every iDRAC : the conformant one does not exist before
  # 5.x, the legacy one is documented as removed on iDRAC 10. Trying them in the
  # other order works on every machine reported so far and breaks on the newest
  export MOCK_PERL_CALL_LOG="$TEST_TEMPORARY_DIRECTORY/perl_calls"
  : > "$MOCK_PERL_CALL_LOG"
  export MOCK_REDFISH_CONFORMANT_STATUS="404"
  export MOCK_REDFISH_LEGACY_STATUS="200"
  export MOCK_REDFISH_LEGACY_BODY
  MOCK_REDFISH_LEGACY_BODY=$(make_redfish_attributes_body --slots 15)

  does_this_server_expose_the_cooling_response_over_redfish

  assert_equals "0" "$?" "a 404 on the conformant URI must fall back, not conclude"
  assert_equals "15" "$REDFISH_COOLING_RESPONSE_SLOT_COUNT"
  assert_matches "$(head -n 1 "$MOCK_PERL_CALL_LOG")" "Oem/Dell/DellAttributes" \
    "the conformant URI is the one that also works on an iDRAC 10, so it goes first"
  assert_matches "$(tail -n 1 "$MOCK_PERL_CALL_LOG")" "Managers/System.Embedded.1/Attributes" \
    "the legacy URI is only reached after the conformant one answered 404"
}

function test_a_server_that_answers_on_the_conformant_uri_is_never_asked_the_legacy_one() {
  export MOCK_PERL_CALL_LOG="$TEST_TEMPORARY_DIRECTORY/perl_calls"
  : > "$MOCK_PERL_CALL_LOG"
  simulate_a_server_exposing_the_cooling_response_over_redfish --slots 42

  does_this_server_expose_the_cooling_response_over_redfish

  assert_equals "1" "$(grep -c "" "$MOCK_PERL_CALL_LOG")" \
    "one answer is enough ; asking the second URI would only add a request"
}

function test_an_unreachable_idrac_is_never_read_as_a_server_that_has_the_setting() {
  # HTTP::Tiny reports anything that stopped the request -- no route, refused
  # connection, TLS failure -- as 599. Concluding from it would claim a capability
  # nobody observed, on a machine that answered nothing at all
  export MOCK_REDFISH_CONFORMANT_STATUS="599"
  export MOCK_REDFISH_LEGACY_STATUS="599"

  does_this_server_expose_the_cooling_response_over_redfish

  assert_equals "1" "$?" "no answer is not an answer"
  assert_equals "0" "$REDFISH_COOLING_RESPONSE_SLOT_COUNT"
}

function test_an_idrac_that_refuses_the_credentials_is_not_read_as_a_verdict_either() {
  local STATUS
  for STATUS in "401" "403" "500"; do
    export MOCK_REDFISH_CONFORMANT_STATUS="$STATUS"
    export MOCK_REDFISH_LEGACY_STATUS="$STATUS"

    does_this_server_expose_the_cooling_response_over_redfish

    assert_equals "1" "$?" "HTTP $STATUS says nothing about whether the setting exists"
  done
}

function test_an_answer_carrying_no_slot_instance_is_not_a_capability() {
  # The document is there and readable, and simply has no per-slot control in it.
  # That is a 13th generation answer, or a machine where the group is absent, and
  # it is the case where "Not supported by this server" stays the honest wording
  export MOCK_REDFISH_CONFORMANT_STATUS="200"
  export MOCK_REDFISH_CONFORMANT_BODY='{"Attributes":{"ThermalSettings.1.ThermalProfile":"Sound Cap"}}'

  does_this_server_expose_the_cooling_response_over_redfish

  assert_equals "1" "$?" "a readable document without LFMMode is a server without the setting"
}

function test_local_mode_asks_nothing_over_the_network() {
  # In local mode the controller reaches the BMC through /dev/ipmi0 and is given no
  # iDRAC address and no credentials at all. There is nothing to address a request
  # to, and that has to be known up front rather than discovered as a ten second
  # timeout on every affected server
  export MOCK_PERL_CALL_LOG="$TEST_TEMPORARY_DIRECTORY/perl_calls"
  : > "$MOCK_PERL_CALL_LOG"
  export IDRAC_HOST="local"
  simulate_a_server_exposing_the_cooling_response_over_redfish

  does_this_server_expose_the_cooling_response_over_redfish

  assert_equals "1" "$?" "local mode cannot reach Redfish, so it reaches no verdict"
  assert_equals "0" "$(grep -c "" "$MOCK_PERL_CALL_LOG")" \
    "no HTTPS request should be attempted when there is no address to send it to"
}

function test_the_support_flag_is_not_believed_over_the_instances_it_contradicts() {
  # ThermalSettings.1.PCIeSlotLFMSupport reads "Not Supported" on a T550 whose 42
  # slot instances are populated and one of which is actively configured, and
  # "Supported" on machines with fewer. Gating on it -- the obvious thing to do,
  # given its name -- would switch this off on servers that support it perfectly
  # well. The instances are the evidence
  simulate_a_server_exposing_the_cooling_response_over_redfish --slots 42 --support "Not Supported"

  does_this_server_expose_the_cooling_response_over_redfish

  assert_equals "0" "$?" \
    "the slot instances are there and configurable, whatever the support flag claims"
  assert_equals "42" "$REDFISH_COOLING_RESPONSE_SLOT_COUNT"
}

function test_only_the_slots_holding_a_third_party_card_are_written_to() {
  # A slot answering "No" holds a Dell card, whose airflow Dell has real data for ; one answering "N/A"
  # is empty. Writing to either would change a setting nobody asked about, on a slot where the cooling
  # response was never the problem
  export MOCK_REDFISH_PATCH_LOG="$TEST_TEMPORARY_DIRECTORY/patches"
  : > "$MOCK_REDFISH_PATCH_LOG"
  simulate_a_server_exposing_the_cooling_response_over_redfish --slots 8 --third-party "3 6"

  does_this_server_expose_the_cooling_response_over_redfish
  set_the_cooling_response_over_redfish "Disabled"

  assert_equals "0" "$?" "the write should succeed"
  assert_equals "2" "$REDFISH_SLOTS_WRITTEN" "only the two third-party slots needed changing"
  local -r PATCH_BODY=$(cat "$MOCK_REDFISH_PATCH_LOG")
  assert_matches "$PATCH_BODY" 'PCIeSlotLFM.3.LFMMode":"Disabled"'
  assert_matches "$PATCH_BODY" 'PCIeSlotLFM.6.LFMMode":"Disabled"'
  assert_not_contains "$PATCH_BODY" 'PCIeSlotLFM.1.LFMMode' \
    "slot 1 holds a Dell card and must be left alone"
}

function test_every_slot_is_written_in_one_request_rather_than_one_each() {
  # A Redfish write creates a configuration job on the iDRAC. Forty slots must not become forty jobs
  export MOCK_REDFISH_PATCH_LOG="$TEST_TEMPORARY_DIRECTORY/patches"
  : > "$MOCK_REDFISH_PATCH_LOG"
  simulate_a_server_exposing_the_cooling_response_over_redfish --slots 40 --third-party "2 5 9 34"

  does_this_server_expose_the_cooling_response_over_redfish
  set_the_cooling_response_over_redfish "Disabled"

  assert_equals "4" "$REDFISH_SLOTS_WRITTEN"
  assert_equals "1" "$(grep -c "" "$MOCK_REDFISH_PATCH_LOG")" \
    "one PATCH carrying every slot, not one per slot"
}

function test_a_slot_already_in_the_wanted_state_is_not_written_again() {
  # The IPMI command is re-sent every cycle because it is stateless and cheap. This is neither, and a
  # human who sets a slot back by hand should not be fought over it every five seconds
  export MOCK_REDFISH_PATCH_LOG="$TEST_TEMPORARY_DIRECTORY/patches"
  : > "$MOCK_REDFISH_PATCH_LOG"
  simulate_a_server_exposing_the_cooling_response_over_redfish --slots 4 --third-party "2" --mode "Disabled"

  does_this_server_expose_the_cooling_response_over_redfish
  set_the_cooling_response_over_redfish "Disabled"

  assert_equals "0" "$?" "already being in the wanted state is a success, not a failure"
  assert_equals "0" "$REDFISH_SLOTS_WRITTEN"
  assert_equals "0" "$(grep -c "" "$MOCK_REDFISH_PATCH_LOG")" "nothing needed changing, so nothing was sent"
}

function test_a_server_with_no_third_party_card_is_written_to_at_all() {
  export MOCK_REDFISH_PATCH_LOG="$TEST_TEMPORARY_DIRECTORY/patches"
  : > "$MOCK_REDFISH_PATCH_LOG"
  simulate_a_server_exposing_the_cooling_response_over_redfish --slots 6

  does_this_server_expose_the_cooling_response_over_redfish

  assert_equals "" "$REDFISH_THIRD_PARTY_SLOTS" "no slot holds a third-party card"

  set_the_cooling_response_over_redfish "Disabled"

  assert_equals "0" "$(grep -c "" "$MOCK_REDFISH_PATCH_LOG")" \
    "there is nothing this parameter is about on such a server"
}

function test_a_refused_write_is_never_reported_as_applied() {
  local STATUS
  for STATUS in "400" "401" "403" "500" "599"; do
    export MOCK_REDFISH_PATCH_STATUS="$STATUS"
    simulate_a_server_exposing_the_cooling_response_over_redfish --slots 4 --third-party "2"

    does_this_server_expose_the_cooling_response_over_redfish
    set_the_cooling_response_over_redfish "Disabled"

    assert_equals "1" "$?" "HTTP $STATUS is a refusal, and the setting is left where it was"
    assert_equals "0" "$REDFISH_SLOTS_WRITTEN" \
      "nothing may be counted as written when the request was refused"
  done
}

function test_handing_it_back_asks_for_dells_default_rather_than_what_was_found() {
  # KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT=false means "put Dell's default back", not
  # "put back what I found" -- which is exactly what the IPMI path has always done. Keeping one meaning
  # across both transports is also what lets the supervisor do this without remembering anything
  export MOCK_REDFISH_PATCH_LOG="$TEST_TEMPORARY_DIRECTORY/patches"
  : > "$MOCK_REDFISH_PATCH_LOG"
  simulate_a_server_exposing_the_cooling_response_over_redfish --slots 4 --third-party "2" --mode "Disabled"

  does_this_server_expose_the_cooling_response_over_redfish
  set_the_cooling_response_over_redfish "Automatic"

  assert_matches "$(cat "$MOCK_REDFISH_PATCH_LOG")" 'PCIeSlotLFM.2.LFMMode":"Automatic"' \
    "the slot goes back to Dell's default"
}

function test_the_digit_inside_the_attribute_name_is_never_read_as_a_slot_number() {
  # "PCIeSlotLFM.10.3rdPartyCard" carries two numbers, and only the first is a slot :
  # "3rdPartyCard" begins with a digit of its own. Collecting digits out of the matched
  # attribute name reads as two slots, 10 and 3, and the setting then goes to slot 3 --
  # somebody else's card, on a server where nothing asked for it
  export MOCK_REDFISH_PATCH_LOG="$TEST_TEMPORARY_DIRECTORY/patches"
  : > "$MOCK_REDFISH_PATCH_LOG"
  simulate_a_server_exposing_the_cooling_response_over_redfish --slots 12 --third-party "10"

  does_this_server_expose_the_cooling_response_over_redfish

  assert_equals "10 " "$REDFISH_THIRD_PARTY_SLOTS" "one slot holds a third-party card, and it is slot 10"

  set_the_cooling_response_over_redfish "Disabled"

  assert_equals "1" "$REDFISH_SLOTS_WRITTEN"
  assert_not_contains "$(cat "$MOCK_REDFISH_PATCH_LOG")" 'PCIeSlotLFM.3.LFMMode' \
    "slot 3 was never asked for and must not be touched"
}

# The cases above exercise the functions directly. These two run the whole
# controller, because the wiring between the IPMI verdict and the Redfish write is
# where a mistake would not show up anywhere else : every unit case here would stay
# green on a branch that never reached this code at all.

function test_the_controller_applies_the_setting_over_redfish_and_says_so_in_the_table() {
  export DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE=true
  export MOCK_REDFISH_PATCH_LOG="$TEST_TEMPORARY_DIRECTORY/patches"
  : > "$MOCK_REDFISH_PATCH_LOG"
  simulate_server "PowerEdge R6515" --cpus 1
  # The 14th generation answer : the BMC has the fan control commands but not this one
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0xce"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="Unable to send RAW command (channel=0x0 netfn=0x30 lun=0x0 cmd=0xce rsp=0xc1): Invalid command"
  simulate_a_server_exposing_the_cooling_response_over_redfish --slots 8 --third-party "4"

  local -r OUTPUT=$(run_controller "" 3)

  assert_matches "$OUTPUT" "fan control profile.*Disabled over Redfish" \
    "the table must report the transport the setting was actually applied over"
  assert_not_contains "$OUTPUT" "Not supported by this server" \
    "the server has the setting, so it must never be told it does not"
  assert_matches "$(cat "$MOCK_REDFISH_PATCH_LOG")" 'PCIeSlotLFM.4.LFMMode":"Disabled"' \
    "the slot holding the third-party card is the one written to"
}

function test_stopping_the_container_hands_the_setting_back_over_redfish_and_not_over_ipmi() {
  # graceful_exit() has always re-sent the IPMI command on the way out. On a server
  # that answered "invalid command" to it, doing that again would undo nothing and
  # leave the slot exactly as this container set it -- which is the whole failure
  # this branch exists to stop. The hand-back has to follow the transport that took
  # the setting, not the one the code was written for
  export DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE=true
  export KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT=false
  export MOCK_REDFISH_PATCH_LOG="$TEST_TEMPORARY_DIRECTORY/patches"
  : > "$MOCK_REDFISH_PATCH_LOG"
  simulate_server "PowerEdge R6515" --cpus 1
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0xce"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="Unable to send RAW command (channel=0x0 netfn=0x30 lun=0x0 cmd=0xce rsp=0xc1): Invalid command"
  simulate_a_server_exposing_the_cooling_response_over_redfish --slots 8 --third-party "4"

  run_controller "" 3 > /dev/null

  assert_matches "$(tail -n 1 "$MOCK_REDFISH_PATCH_LOG")" 'PCIeSlotLFM.4.LFMMode":"Automatic"' \
    "stopping the container puts Dell's default back on the slot it changed"
  # One call on the first cycle, and none on the way out : the IPMI hand-back would
  # be sent to a command this BMC has already said it does not have
  assert_equals "1" "$(count_ipmitool_calls_matching "raw 0x30 0xce")" \
    "the dead IPMI command must not be re-sent on exit once Redfish is driving this"
}
