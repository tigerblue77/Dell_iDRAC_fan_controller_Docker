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

  while [ $# -gt 0 ]; do
    case "$1" in
      --slots) SLOT_COUNT="$2"; shift 2 ;;
      --support) SUPPORT_FLAG="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  local BODY='{"@odata.id":"/redfish/v1","Attributes":{"ThermalSettings.1.ThermalProfile":"Default Thermal Profile Settings"'
  BODY+=',"ThermalSettings.1.PCIeSlotLFMSupport":"'"$SUPPORT_FLAG"'"'

  local SLOT
  for ((SLOT = 1; SLOT <= SLOT_COUNT; SLOT++)); do
    BODY+=',"PCIeSlotLFM.'"$SLOT"'.LFMMode":"Automatic","PCIeSlotLFM.'"$SLOT"'.3rdPartyCard":"No"'
  done

  BODY+='}}'
  printf '%s' "$BODY"
}

# A server that has the setting, on the URI that exists from iDRAC 9 5.x onwards
function simulate_a_server_exposing_the_cooling_response_over_redfish() {
  export MOCK_REDFISH_CONFORMANT_STATUS="200"
  export MOCK_REDFISH_CONFORMANT_BODY
  MOCK_REDFISH_CONFORMANT_BODY=$(make_redfish_attributes_body "$@")
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
