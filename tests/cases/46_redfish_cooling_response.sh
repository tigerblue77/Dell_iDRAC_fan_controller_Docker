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
  # "<slot>=<mode> <slot>=<mode>", overriding --mode for those slots. A server where one third-party
  # card is already where it should be and another is not is the only shape in which the skip and the
  # comma-joining of the write meet, and it was describable by nothing until #417
  local SLOT_MODES=""
  # An iDRAC minifies its answers, and this builder does too by default -- but nothing in HTTP or JSON
  # promises it, so --pretty produces the same document with the whitespace a formatter would add
  local PRETTY=false
  # Orders the whole document the way an iDRAC really returns it -- alphabetically, which puts
  # PCIeSlotLFM before ThermalSettings and, within a slot, 3rdPartyCard before LFMMode. That makes
  # "PCIeSlotLFM.1.3rdPartyCard" the first attribute of the object, which is the entry the slot list
  # used to drop
  local SLOTS_FIRST=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --slots) SLOT_COUNT="$2"; shift 2 ;;
      --support) SUPPORT_FLAG="$2"; shift 2 ;;
      --third-party) THIRD_PARTY_SLOTS=" $2 "; shift 2 ;;
      --mode) LFM_MODE="$2"; shift 2 ;;
      --slot-modes) SLOT_MODES=" $2 "; shift 2 ;;
      --pretty) PRETTY=true; shift ;;
      --slots-first) SLOTS_FIRST=true; shift ;;
      *) shift ;;
    esac
  done

  local THERMAL_ATTRIBUTES='"ThermalSettings.1.ThermalProfile":"Default Thermal Profile Settings"'
  THERMAL_ATTRIBUTES+=',"ThermalSettings.1.PCIeSlotLFMSupport":"'"$SUPPORT_FLAG"'"'

  local SLOT_ATTRIBUTES=""
  local SLOT
  local CARD
  local MODE
  for ((SLOT = 1; SLOT <= SLOT_COUNT; SLOT++)); do
    if [[ "$THIRD_PARTY_SLOTS" == *" $SLOT "* ]]; then
      CARD="Yes"
    else
      CARD="No"
    fi

    MODE="$LFM_MODE"
    if [[ "$SLOT_MODES" == *" $SLOT="* ]]; then
      MODE="${SLOT_MODES##* "$SLOT"=}"
      MODE="${MODE%% *}"
    fi

    [ -n "$SLOT_ATTRIBUTES" ] && SLOT_ATTRIBUTES+=","
    if "$SLOTS_FIRST"; then
      SLOT_ATTRIBUTES+='"PCIeSlotLFM.'"$SLOT"'.3rdPartyCard":"'"$CARD"'","PCIeSlotLFM.'"$SLOT"'.LFMMode":"'"$MODE"'"'
    else
      SLOT_ATTRIBUTES+='"PCIeSlotLFM.'"$SLOT"'.LFMMode":"'"$MODE"'","PCIeSlotLFM.'"$SLOT"'.3rdPartyCard":"'"$CARD"'"'
    fi
  done

  local BODY
  if "$SLOTS_FIRST"; then
    # No @odata.id either : it is a real key of a real answer, but putting it first would leave the slot
    # attributes in the middle of the document and hide the very position being tested
    BODY='{"Attributes":{'"$SLOT_ATTRIBUTES"','"$THERMAL_ATTRIBUTES"'}}'
  else
    BODY='{"@odata.id":"/redfish/v1","Attributes":{'"$THERMAL_ATTRIBUTES"','"$SLOT_ATTRIBUTES"'}}'
  fi

  if "$PRETTY"; then
    BODY="${BODY//\":\"/\" : \"}"
    BODY="${BODY//,\"/, \"}"
  fi

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

# A refused write is not one thing. An answer about the request or the credentials will read the same
# on every later cycle ; a busy iDRAC, a full configuration job queue or a request that never completed
# describe a moment. #376 : the first settles it, the second is retried.

function test_an_answer_about_the_request_or_the_credentials_settles_it_on_the_first_refusal() {
  local STATUS
  for STATUS in "400" "401" "403" "404" "405"; do
    assert_equals "true" "$(is_this_redfish_answer_a_verdict "$STATUS" && echo true || echo false)" \
      "HTTP $STATUS will not read differently on the next cycle"
  done
}

function test_an_answer_describing_a_moment_is_never_taken_as_a_decision() {
  # The last one matters most : an answer nobody here has seen is retried rather than concluded from,
  # the same choice does_the_server_lack_this_command() makes on the IPMI side
  local STATUS
  for STATUS in "409" "500" "502" "503" "599" "418"; do
    assert_equals "false" "$(is_this_redfish_answer_a_verdict "$STATUS" && echo true || echo false)" \
      "HTTP $STATUS describes a moment, or is unrecognised, and neither is a verdict"
  done
}

function test_a_busy_idrac_is_retried_and_settles_after_the_bounded_number_of_attempts() {
  export MOCK_REDFISH_PATCH_LOG="$TEST_TEMPORARY_DIRECTORY/patches"
  : > "$MOCK_REDFISH_PATCH_LOG"
  export MOCK_REDFISH_PATCH_STATUS="503"
  export CHECK_INTERVAL_IN_SECONDS=5
  REDFISH_ATTEMPTS=0
  REDFISH_COOLING_RESPONSE_SETTLED=false
  simulate_a_server_exposing_the_cooling_response_over_redfish --slots 4 --third-party "2"
  does_this_server_expose_the_cooling_response_over_redfish

  local ATTEMPT
  for ((ATTEMPT = 1; ATTEMPT < MAXIMUM_REDFISH_ATTEMPTS; ATTEMPT++)); do
    apply_the_cooling_response_over_redfish "Disabled" "Disabled"
    assert_equals "false" "$REDFISH_COOLING_RESPONSE_SETTLED" \
      "attempt $ATTEMPT of $MAXIMUM_REDFISH_ATTEMPTS must leave another one to make"
    assert_equals "Redfish refused this change, retrying" \
      "$THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS"
  done

  # Redirected to a file rather than captured with $( ), which would run the function in a subshell and
  # leave every global it sets behind in it
  apply_the_cooling_response_over_redfish "Disabled" "Disabled" > "$TEST_TEMPORARY_DIRECTORY/last_attempt" 2>&1
  local -r LAST_OUTPUT=$(cat "$TEST_TEMPORARY_DIRECTORY/last_attempt")

  assert_equals "true" "$REDFISH_COOLING_RESPONSE_SETTLED" "the bound is where retrying stops"
  assert_equals "$MAXIMUM_REDFISH_ATTEMPTS" "$REDFISH_ATTEMPTS"
  assert_equals "Redfish refused this change (see the log)" \
    "$THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS"
  # Three attempts a five second interval apart span ten seconds, not fifteen : the reader is told the
  # span between the first and the last, not a count multiplied by an interval
  assert_matches "$LAST_OUTPUT" "could not be made in 3 attempts, spread over about 10 seconds" \
    "the message must say how long it went on, CHECK_INTERVAL ranging from seconds to minutes"
  # It counts the errand rather than asserting three refusals : the budget is shared with the probe, so
  # some of those attempts may never have reached the iDRAC at all, and saying it refused three times
  # would be a statement about the server made out of attempts it never saw (#413)
  assert_matches "$LAST_OUTPUT" "HTTP 503 while writing it" \
    "the message must name which half of the errand the last answer came from"
}

function test_an_answer_about_the_credentials_is_not_retried_at_all() {
  export MOCK_REDFISH_PATCH_LOG="$TEST_TEMPORARY_DIRECTORY/patches"
  : > "$MOCK_REDFISH_PATCH_LOG"
  export MOCK_REDFISH_PATCH_STATUS="403"
  REDFISH_ATTEMPTS=0
  REDFISH_COOLING_RESPONSE_SETTLED=false
  simulate_a_server_exposing_the_cooling_response_over_redfish --slots 4 --third-party "2"
  does_this_server_expose_the_cooling_response_over_redfish

  apply_the_cooling_response_over_redfish "Disabled" "Disabled" > "$TEST_TEMPORARY_DIRECTORY/refusal" 2>&1
  local -r OUTPUT=$(cat "$TEST_TEMPORARY_DIRECTORY/refusal")

  assert_equals "true" "$REDFISH_COOLING_RESPONSE_SETTLED" "an account's rights do not change mid-run"
  assert_equals "1" "$REDFISH_ATTEMPTS" "making the same wrong request twice more helps nobody"
  assert_matches "$OUTPUT" "about this request or these credentials"
  assert_not_contains "$OUTPUT" "times, i.e. over about" \
    "there is no elapsed span to report when nothing was retried"
}

function test_the_controller_retries_a_busy_idrac_across_cycles_and_then_stops() {
  export DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE=true
  export MOCK_REDFISH_PATCH_LOG="$TEST_TEMPORARY_DIRECTORY/patches"
  : > "$MOCK_REDFISH_PATCH_LOG"
  export MOCK_REDFISH_PATCH_STATUS="500"
  simulate_server "PowerEdge R6515" --cpus 1
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0xce"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="Unable to send RAW command (channel=0x0 netfn=0x30 lun=0x0 cmd=0xce rsp=0xc1): Invalid command"
  simulate_a_server_exposing_the_cooling_response_over_redfish --slots 8 --third-party "4"

  # Well past the third attempt, so a fourth would show up in the log
  local -r OUTPUT=$(run_controller "" 6)

  assert_equals "3" "$(grep -c "" "$MOCK_REDFISH_PATCH_LOG")" \
    "three attempts, one per cycle, and then no more for the life of the container"
  assert_matches "$OUTPUT" "could not be made in 3 attempts"
  assert_matches "$OUTPUT" "fan control profile.*Redfish refused this change \(see the log\)" \
    "the table must stop implying a later cycle could clear it"
}

# The probe failing is not an answer about the server. Treating it as one is how "Not supported by this
# server" came back for an iDRAC that was merely busy -- the exact falsehood #374 removed, reintroduced
# through the one path #375 never looked at (#376).

function test_an_idrac_that_could_not_be_reached_is_never_reported_as_a_server_without_the_setting() {
  export MOCK_REDFISH_CONFORMANT_STATUS="599"
  export MOCK_REDFISH_LEGACY_STATUS="599"
  export CHECK_INTERVAL_IN_SECONDS=5
  REDFISH_ATTEMPTS=0
  REDFISH_COOLING_RESPONSE_SETTLED=false

  attempt_the_redfish_cooling_response "Disabled" "Disabled" > "$TEST_TEMPORARY_DIRECTORY/probe" 2>&1

  assert_equals "false" "$REDFISH_COOLING_RESPONSE_SETTLED" "an unreachable iDRAC leaves the question open"
  assert_equals "Cannot reach Redfish yet, retrying" \
    "$THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS"

  attempt_the_redfish_cooling_response "Disabled" "Disabled" > /dev/null 2>&1
  attempt_the_redfish_cooling_response "Disabled" "Disabled" > "$TEST_TEMPORARY_DIRECTORY/probe" 2>&1
  local -r LAST_OUTPUT=$(cat "$TEST_TEMPORARY_DIRECTORY/probe")

  assert_equals "true" "$REDFISH_COOLING_RESPONSE_SETTLED" "the bound stops the asking"
  assert_equals "Redfish could not be reached (see the log)" \
    "$THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS" \
    "which is NOT the same statement as the server not having the setting"
  assert_matches "$LAST_OUTPUT" "3 attempts, i.e. over about 10 seconds"
  assert_matches "$LAST_OUTPUT" "says nothing about the server, only about reaching it"
}

function test_a_readable_answer_carrying_no_slot_is_the_one_case_that_names_the_server() {
  # Read, understood, and the answer is no. Here "Not supported by this server" is true of the server
  # and not merely of the transport, which is the whole distinction
  export MOCK_REDFISH_CONFORMANT_STATUS="200"
  export MOCK_REDFISH_CONFORMANT_BODY='{"Attributes":{"ThermalSettings.1.ThermalProfile":"Sound Cap"}}'
  REDFISH_ATTEMPTS=0
  REDFISH_COOLING_RESPONSE_SETTLED=false

  attempt_the_redfish_cooling_response "Disabled" "Disabled" > /dev/null 2>&1

  assert_equals "true" "$REDFISH_COOLING_RESPONSE_SETTLED"
  assert_equals "Not supported by this server" \
    "$THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS"
}

function test_local_mode_says_the_transport_is_missing_rather_than_blaming_the_server() {
  export IDRAC_HOST="local"
  REDFISH_ATTEMPTS=0
  REDFISH_COOLING_RESPONSE_SETTLED=false

  attempt_the_redfish_cooling_response "Disabled" "Disabled" > "$TEST_TEMPORARY_DIRECTORY/local" 2>&1

  assert_equals "true" "$REDFISH_COOLING_RESPONSE_SETTLED" "no later cycle grows an iDRAC address"
  assert_equals "Not over IPMI (Redfish needs network mode)" \
    "$THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS" \
    "the server may well have the setting ; this container simply cannot ask from local mode"
  assert_matches "$(cat "$TEST_TEMPORARY_DIRECTORY/local")" "Set IDRAC_HOST, IDRAC_USERNAME and IDRAC_PASSWORD"
}

function test_the_readme_names_both_causes_of_the_refusal_the_warning_names() {
  # #482 stopped the warning asserting a cause the container cannot know. The README went on explaining
  # the same refusal with the 14th generation alone -- nothing false, but the only explanation on offer,
  # so a reader whose log shows the refusal places themselves in that bucket by elimination. Which is the
  # inference #481 was opened to stop the container inviting, and the README is where the log sends people.
  #
  # Same shape as issue #483, one pull request later : the code moved and the document did not (issue #485)
  if [ ! -f "$REPO_ROOT/README.md" ]; then
    # The suite is running inside the built image, which .dockerignore keeps the README out of
    skip_test "no README next to the scripts"
    return 0
  fi

  local -r README_CONTENT=$(cat "$REPO_ROOT/README.md")

  assert_contains "$README_CONTENT" "older** than the generations that ever had the setting" \
    "the README has to offer the second cause too, or the first one is reached by elimination"
  assert_contains "$README_CONTENT" "the completion code does not tell the two apart" \
    "and say why the container cannot decide it for the reader"
}

function test_local_mode_names_both_causes_of_the_refusal_rather_than_asserting_one() {
  # The refusal of "raw 0x30 0xce" has two opposite causes and does not say which : a server NEWER than
  # the 13th generation, where Dell moved the setting to a per-slot Redfish attribute, and one OLDER than
  # any that ever had it, where network mode would find nothing at all. The warning asserted the first
  # and suggested acting on it -- which is how the R510 of issue #378, 11th generation and no Redfish
  # anywhere on it, was sent to a mode that had nothing in it for him. #173 deliberately retired guessing
  # the generation from the model name, so the container genuinely cannot tell which case it is in and
  # has to name both (issue #481)
  export IDRAC_HOST="local"
  REDFISH_ATTEMPTS=0
  REDFISH_COOLING_RESPONSE_SETTLED=false

  attempt_the_redfish_cooling_response "Disabled" "Disabled" \
    > "$TEST_TEMPORARY_DIRECTORY/both_causes" 2>&1
  local -r OUTPUT=$(cat "$TEST_TEMPORARY_DIRECTORY/both_causes")

  assert_contains "$OUTPUT" "the refusal does not say which" \
    "the container does not know the cause, and must not read as though it did"
  assert_contains "$OUTPUT" "older than the generations that ever had the setting" \
    "the second cause has to be named, not only the one that makes the switch worth making"
  assert_contains "$OUTPUT" "nothing for network mode to reach either" \
    "and what that cause means for the reader has to be spelt out"
  assert_not_contains "$OUTPUT" "to have an effect on this server" \
    "an effect on THIS server cannot be promised when its generation is exactly what is unknown"
}

function test_local_mode_does_not_promise_nothing_else_changes_when_the_cpus_come_from_lm_sensors() {
  # The sentence that cost issue #378's reporter a run. He read "Nothing else changes", followed the
  # advice, and his container refused to start : his iDRAC publishes no CPU temperature, so his CPUs
  # come from lm-sensors, and network mode refused that fallback outright at the time. Issue #465 has
  # since made it survive the switch on a container that can be shown to be running on the controlled
  # server, which is what the warning below now says instead of a flat promise
  export IDRAC_HOST="local"
  CPU_TEMPERATURE_SOURCE_IN_USE="lm-sensors"
  REDFISH_ATTEMPTS=0
  REDFISH_COOLING_RESPONSE_SETTLED=false

  attempt_the_redfish_cooling_response "Disabled" "Disabled" > "$TEST_TEMPORARY_DIRECTORY/lm_sensors" 2>&1
  local -r OUTPUT=$(cat "$TEST_TEMPORARY_DIRECTORY/lm_sensors")

  assert_not_contains "$OUTPUT" "Nothing else changes" \
    "on this server the switch would cost the only CPU reading it has"
  assert_contains "$OUTPUT" "would refuse to start" \
    "what the switch would actually do has to be said before it is suggested"
  assert_contains "$OUTPUT" "Local mode needs no such proof"
  # Since issue #465 the fallback survives the switch on a container that proves where it runs, so this
  # warning must not go on presenting local mode as the only place it exists -- it still did after #468
  # had landed everywhere else (#469)
  assert_not_contains "$OUTPUT" "exists only in local mode" \
    "network mode keeps the reading when the container is shown to be on the server itself"
  assert_contains "$OUTPUT" "can be SHOWN to be running on the very server" \
    "and what it now depends on has to be named"
}

function test_local_mode_still_promises_nothing_else_changes_when_the_idrac_reports_the_cpus() {
  # The negative control : a server whose iDRAC does report its CPUs loses nothing by switching, and
  # must not be warned off a mode that would work for it
  export IDRAC_HOST="local"
  CPU_TEMPERATURE_SOURCE_IN_USE="ipmi"
  REDFISH_ATTEMPTS=0
  REDFISH_COOLING_RESPONSE_SETTLED=false

  attempt_the_redfish_cooling_response "Disabled" "Disabled" > "$TEST_TEMPORARY_DIRECTORY/ipmi" 2>&1
  local -r OUTPUT=$(cat "$TEST_TEMPORARY_DIRECTORY/ipmi")

  assert_contains "$OUTPUT" "Nothing else changes"
  assert_not_contains "$OUTPUT" "would refuse to start"
}

function test_no_warning_or_error_ends_on_a_doubled_full_stop() {
  # print_warning and print_error both append a period, so a message that ends with one prints two.
  # Visible in the reporter's own log as "...logged every cycle.." -- small, but it is the kind of
  # thing that makes a careful log look careless
  local OUTPUT

  export IDRAC_HOST="local"
  CPU_TEMPERATURE_SOURCE_IN_USE="ipmi"
  REDFISH_ATTEMPTS=0
  REDFISH_COOLING_RESPONSE_SETTLED=false
  attempt_the_redfish_cooling_response "Disabled" "Disabled" > "$TEST_TEMPORARY_DIRECTORY/stops" 2>&1
  OUTPUT=$(cat "$TEST_TEMPORARY_DIRECTORY/stops")

  assert_not_contains "$OUTPUT" ".." "a message must not supply the period print_warning already appends"
}

function test_the_manual_redfish_instructions_do_not_supply_their_own_full_stop() {
  # The other half, which the case above cannot reach : four print_error call sites end on this shared
  # constant, and print_error appends a period of its own, so a constant ending in one printed
  # "...are unaffected..". Pinned on the constant rather than on any single caller, it being the tail
  # all four share
  assert_not_contains "${REDFISH_MANUAL_INSTRUCTIONS: -1}" "." \
    "print_error supplies the terminal period, so this constant must not"
}

function test_the_controller_keeps_asking_a_briefly_unreachable_idrac_instead_of_naming_the_server() {
  export DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE=true
  simulate_server "PowerEdge R6515" --cpus 1
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0xce"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="Unable to send RAW command (channel=0x0 netfn=0x30 lun=0x0 cmd=0xce rsp=0xc1): Invalid command"
  # Reachable over IPMI, its HTTPS stack answering nothing
  export MOCK_REDFISH_CONFORMANT_STATUS="599"
  export MOCK_REDFISH_LEGACY_STATUS="599"

  local -r OUTPUT=$(run_controller "" 6)

  assert_not_contains "$OUTPUT" "Not supported by this server" \
    "the server was never asked, so it must never be reported as answering no"
  assert_matches "$OUTPUT" "fan control profile.*Cannot reach Redfish yet, retrying" \
    "the early cycles must say the transport is the problem"
  assert_matches "$OUTPUT" "3 attempts, i.e. over about"
}

# The cases below come from an audit of everything #374, #375 and #377 shipped, against what the suite
# actually pinned. Five of them reproduce defects that were live in master -- two in the parser, two in
# what the write path records and says, one in a timeout that did not fit the deadline enforcing it --
# and the rest pin branches that were correct and reached by nothing at all
# (#412, #413, #414, #417).

function test_a_third_party_slot_that_opens_the_document_is_not_dropped() {
  # The slot list is read out of comma-separated fields, and the pattern used to be anchored : "^[^"]*"
  # cannot cross the quote that opens the enclosing "Attributes" key, so whichever slot came FIRST in
  # the answer never matched and was left out of every write. Dell orders these documents
  # alphabetically, which puts PCIeSlotLFM before ThermalSettings -- so on a real answer the slot being
  # silently dropped was the first PCIe slot of the machine
  simulate_a_server_exposing_the_cooling_response_over_redfish --slots 3 --third-party "1 3" --slots-first

  does_this_server_expose_the_cooling_response_over_redfish

  assert_equals "1 3 " "$REDFISH_THIRD_PARTY_SLOTS" \
    "a card in the first slot of the document is a card like any other"
  assert_equals "3" "$REDFISH_COOLING_RESPONSE_SLOT_COUNT"
}

function test_an_answer_that_was_not_minified_is_read_the_same_way() {
  # Nothing in HTTP or JSON promises a body without whitespace, and this document is parsed with sed and
  # grep. The failure was asymmetric, which is what made it dangerous : the slot COUNT matches the bare
  # key and would still have said the server has the setting, while the slot LIST and the mode read-back
  # both matched on a hard-coded ":" and found nothing. The container would then settle, once and for
  # the life of the container, on a server that has the setting and nothing to apply it to
  simulate_a_server_exposing_the_cooling_response_over_redfish --slots 2 --third-party "2" \
    --mode "Disabled" --pretty

  does_this_server_expose_the_cooling_response_over_redfish

  assert_equals "2 " "$REDFISH_THIRD_PARTY_SLOTS" "the whitespace is the formatter's, not the server's"
  assert_equals "Disabled" "$(read_the_lfm_mode_of_slot "$MOCK_REDFISH_CONFORMANT_BODY" 2)" \
    "a mode read as empty never equals the wanted one, so every slot would be rewritten every cycle"
}

function test_only_the_third_party_slots_not_already_set_are_written() {
  # The one shape where the skip and the comma-joining of the write meet. A leading or doubled comma
  # produces a body the iDRAC answers 400 to, which is_this_redfish_answer_a_verdict() then reads as a
  # decision -- so the feature would be off for the life of the container over a punctuation mistake
  export MOCK_REDFISH_PATCH_LOG="$TEST_TEMPORARY_DIRECTORY/patches"
  : > "$MOCK_REDFISH_PATCH_LOG"
  simulate_a_server_exposing_the_cooling_response_over_redfish --slots 6 --third-party "2 5" \
    --mode "Automatic" --slot-modes "2=Disabled"

  does_this_server_expose_the_cooling_response_over_redfish
  set_the_cooling_response_over_redfish "Disabled"

  assert_equals "1" "$REDFISH_SLOTS_WRITTEN" "the slot already in the wanted state is left alone"
  assert_equals "1" "$(grep -c "" "$MOCK_REDFISH_PATCH_LOG")" "and the other one still goes in one request"
  assert_matches "$(cat "$MOCK_REDFISH_PATCH_LOG")" '\{"Attributes":\{"PCIeSlotLFM\.5\.LFMMode":"Disabled"\}\}' \
    "the body carries the one slot that needed changing, and no stray comma"
}

function test_a_read_refused_inside_the_write_path_names_what_stopped_it() {
  # The errand is two requests and only the second used to record its answer. A server that stopped
  # answering after the probe therefore produced "refused to change it 3 times ... The last answer was
  # HTTP ." -- a truncated sentence, about refusals that never happened, with no status for the reader
  # to quote on the tracker and no PATCH ever sent
  export MOCK_REDFISH_PATCH_LOG="$TEST_TEMPORARY_DIRECTORY/patches"
  : > "$MOCK_REDFISH_PATCH_LOG"
  export CHECK_INTERVAL_IN_SECONDS=5
  REDFISH_ATTEMPTS=0
  REDFISH_COOLING_RESPONSE_SETTLED=false
  simulate_a_server_exposing_the_cooling_response_over_redfish --slots 4 --third-party "2"
  does_this_server_expose_the_cooling_response_over_redfish

  # The probe is done ; from here the iDRAC answers nothing but 500
  export MOCK_REDFISH_CONFORMANT_STATUS="500"

  local ATTEMPT
  for ((ATTEMPT = 1; ATTEMPT <= MAXIMUM_REDFISH_ATTEMPTS; ATTEMPT++)); do
    apply_the_cooling_response_over_redfish "Disabled" "Disabled" \
      > "$TEST_TEMPORARY_DIRECTORY/read_refused" 2>&1
  done
  local -r OUTPUT=$(cat "$TEST_TEMPORARY_DIRECTORY/read_refused")

  assert_equals "true" "$REDFISH_COOLING_RESPONSE_SETTLED"
  assert_equals "500" "$REDFISH_LAST_WRITE_STATUS" "the read's answer is what stopped the errand"
  assert_matches "$OUTPUT" "HTTP 500 while reading the setting back" \
    "the reader is told which half of the errand answered, and what it answered"
  assert_not_contains "$OUTPUT" "HTTP \." "an empty status is a sentence about nothing"
  assert_equals "0" "$(grep -c "" "$MOCK_REDFISH_PATCH_LOG")" \
    "nothing was ever written, so nothing can have been refused"
}

function test_an_answer_about_the_credentials_while_reading_back_settles_at_once() {
  # #377's rule is that a decision concludes on the first answer, and it was enforced on the PATCH only.
  # A 401 on the read half was retried three times instead -- three requests an account whose rights are
  # what they are will refuse identically
  REDFISH_ATTEMPTS=0
  REDFISH_COOLING_RESPONSE_SETTLED=false
  simulate_a_server_exposing_the_cooling_response_over_redfish --slots 4 --third-party "2"
  does_this_server_expose_the_cooling_response_over_redfish

  export MOCK_REDFISH_CONFORMANT_STATUS="401"
  apply_the_cooling_response_over_redfish "Disabled" "Disabled" \
    > "$TEST_TEMPORARY_DIRECTORY/credentials_read" 2>&1

  assert_equals "true" "$REDFISH_COOLING_RESPONSE_SETTLED" "a 401 will not read differently next cycle"
  assert_equals "1" "$REDFISH_ATTEMPTS" "and is therefore asked exactly once"
  assert_matches "$(cat "$TEST_TEMPORARY_DIRECTORY/credentials_read")" \
    "HTTP 401 while reading the setting back"
}

function test_a_probe_refused_over_the_credentials_is_not_asked_again() {
  # The same split, on the half that asks whether the server has the setting at all. The write half had
  # both its cases pinned since #377 ; this one had neither
  local PROBE_STATUS
  for PROBE_STATUS in 401 403 405; do
    export MOCK_REDFISH_CONFORMANT_STATUS="$PROBE_STATUS"
    export MOCK_REDFISH_LEGACY_STATUS="$PROBE_STATUS"
    REDFISH_ATTEMPTS=0
    REDFISH_COOLING_RESPONSE_SETTLED=false

    attempt_the_redfish_cooling_response "Disabled" "Disabled" \
      > "$TEST_TEMPORARY_DIRECTORY/probe_$PROBE_STATUS" 2>&1

    assert_equals "true" "$REDFISH_COOLING_RESPONSE_SETTLED" "HTTP $PROBE_STATUS is a decision"
    assert_equals "1" "$REDFISH_ATTEMPTS" "HTTP $PROBE_STATUS must not be asked twice"
    assert_equals "Redfish refused to answer (see the log)" \
      "$THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS" \
      "HTTP $PROBE_STATUS says nothing about the hardware, so the column must not name it"
  done
}

function test_a_legacy_uri_that_never_answered_is_not_a_server_without_the_setting() {
  # 404 then 599 : an iDRAC 9 4.x, which has no conformant URI, whose HTTPS stack is briefly down. The
  # only fallback case any test reached ended in 200, so nothing pinned what the other endings do -- and
  # this one is #376's exact scenario, one URI further along
  export MOCK_PERL_CALL_LOG="$TEST_TEMPORARY_DIRECTORY/perl_calls"
  : > "$MOCK_PERL_CALL_LOG"
  export MOCK_REDFISH_CONFORMANT_STATUS="404"
  export MOCK_REDFISH_LEGACY_STATUS="599"
  REDFISH_ATTEMPTS=0
  REDFISH_COOLING_RESPONSE_SETTLED=false

  attempt_the_redfish_cooling_response "Disabled" "Disabled" > /dev/null 2>&1

  assert_equals "2" "$(grep -c "" "$MOCK_PERL_CALL_LOG")" "the legacy URI is the one that has to answer"
  assert_equals "false" "$REDFISH_COOLING_RESPONSE_SETTLED" "an unreachable URI settles nothing"
  assert_equals "Cannot reach Redfish yet, retrying" \
    "$THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS"
}

function test_both_uris_answering_404_is_the_one_case_that_names_the_server() {
  # Read, understood, and the answer is no : neither URI is there. That is a statement about the
  # machine, and the only shape in which making one is honest
  export MOCK_PERL_CALL_LOG="$TEST_TEMPORARY_DIRECTORY/perl_calls"
  : > "$MOCK_PERL_CALL_LOG"
  export MOCK_REDFISH_CONFORMANT_STATUS="404"
  export MOCK_REDFISH_LEGACY_STATUS="404"
  REDFISH_ATTEMPTS=0
  REDFISH_COOLING_RESPONSE_SETTLED=false

  attempt_the_redfish_cooling_response "Disabled" "Disabled" > /dev/null 2>&1

  assert_equals "2" "$(grep -c "" "$MOCK_PERL_CALL_LOG")" "both URIs are tried before the server is named"
  assert_equals "true" "$REDFISH_COOLING_RESPONSE_SETTLED" "no later cycle grows the resource"
  assert_equals "Not supported by this server" \
    "$THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS"
}

function test_keeping_the_state_on_exit_writes_nothing_over_redfish() {
  # KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT is a user asking the container to leave
  # the slot where it put it. Over IPMI that promise is pinned ; over Redfish nothing checked it
  export MOCK_REDFISH_PATCH_LOG="$TEST_TEMPORARY_DIRECTORY/patches"
  : > "$MOCK_REDFISH_PATCH_LOG"
  export KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT=true
  simulate_a_server_exposing_the_cooling_response_over_redfish --slots 4 --third-party "2" --mode "Disabled"
  does_this_server_expose_the_cooling_response_over_redfish
  IS_THE_COOLING_RESPONSE_DRIVEN_OVER_REDFISH=true

  # graceful_exit() ends the shell it runs in, so it is run in one of its own
  ( graceful_exit > /dev/null 2>&1 )

  assert_equals "0" "$(grep -c "" "$MOCK_REDFISH_PATCH_LOG")" \
    "the slot is left exactly where the container put it"
  assert_equals "0" "$(count_ipmitool_calls_matching "raw 0x30 0xce")" \
    "and the command this server does not have is not sent either"
}

function test_a_hand_back_the_idrac_refuses_names_the_manual_path() {
  # The one moment the owner needs the three clicks : the container is going away with the slot still
  # where it put it. Both exit paths used to word that themselves rather than use the constant that
  # exists so the same three clicks are never described two slightly different ways
  export KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT=false
  simulate_a_server_exposing_the_cooling_response_over_redfish --slots 4 --third-party "2" --mode "Disabled"
  does_this_server_expose_the_cooling_response_over_redfish
  IS_THE_COOLING_RESPONSE_DRIVEN_OVER_REDFISH=true
  export MOCK_REDFISH_PATCH_STATUS="500"

  ( graceful_exit > "$TEST_TEMPORARY_DIRECTORY/exit_refused" 2>&1 )
  local -r OUTPUT=$(cat "$TEST_TEMPORARY_DIRECTORY/exit_refused")

  assert_matches "$OUTPUT" "Could not hand the third-party PCIe card cooling response back" \
    "a hand-back that did not land is never silent"
  assert_contains "$OUTPUT" "Cooling Configuration" "and says where to put it back by hand"
}

function test_the_exit_timeout_fits_the_deadlines_it_runs_inside() {
  # This is arithmetic, and it was wrong from #375 until #414. The exit figure is per REQUEST and the
  # hand-back makes two of them -- it reads the slots back, then writes them -- inside a deadline the
  # supervisor enforces with SIGKILL. At 3 seconds each, a pair could not fit a 3 second grace period,
  # so an iDRAC that simply did not answer made a healthy monitoring process be killed as wedged. The
  # supervisor's own hand-back on that path can make four requests, against Docker's ten seconds
  local -r DOCKER_DEFAULT_STOP_GRACE_PERIOD_IN_SECONDS=10

  assert_equals "true" \
    "$([ $((2 * REDFISH_EXIT_REQUEST_TIMEOUT_IN_SECONDS)) -lt "$SUPERVISOR_GRACE_PERIOD_IN_SECONDS" ] && echo true || echo false)" \
    "graceful_exit()'s two requests must fit inside the supervisor's grace period"
  assert_equals "true" \
    "$([ $((4 * REDFISH_EXIT_REQUEST_TIMEOUT_IN_SECONDS)) -lt "$DOCKER_DEFAULT_STOP_GRACE_PERIOD_IN_SECONDS" ] && echo true || echo false)" \
    "and the supervisor's own four must fit inside Docker's"
  assert_equals "true" \
    "$([ "$REDFISH_EXIT_REQUEST_TIMEOUT_IN_SECONDS" -lt "$REDFISH_REQUEST_TIMEOUT_IN_SECONDS" ] && echo true || echo false)" \
    "the way out is the half that cannot afford to wait"
}

function test_monitoring_only_mode_never_reaches_redfish_at_all() {
  # MONITORING_ONLY_MODE is the promise that nothing is sent to the server, and Redfish is the one
  # transport in this container that can write over something other than IPMI. The IPMI call returns
  # before touching ipmitool in that mode, so the verdict that starts the Redfish errand is never
  # reached -- which is the right behaviour and was pinned by nothing
  export MONITORING_ONLY_MODE=true
  export DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE=true
  export MOCK_PERL_CALL_LOG="$TEST_TEMPORARY_DIRECTORY/perl_calls"
  export MOCK_REDFISH_PATCH_LOG="$TEST_TEMPORARY_DIRECTORY/patches"
  : > "$MOCK_PERL_CALL_LOG"
  : > "$MOCK_REDFISH_PATCH_LOG"
  simulate_server "PowerEdge R6515" --cpus 1
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0xce"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="Unable to send RAW command (channel=0x0 netfn=0x30 lun=0x0 cmd=0xce rsp=0xc1): Invalid command"
  simulate_a_server_exposing_the_cooling_response_over_redfish --slots 4 --third-party "2"

  local -r OUTPUT=$(run_controller "" 4)

  assert_equals "0" "$(grep -c "" "$MOCK_PERL_CALL_LOG")" \
    "not one HTTPS request may leave a container asked to observe and nothing else"
  assert_equals "0" "$(grep -c "" "$MOCK_REDFISH_PATCH_LOG")"
  assert_matches "$OUTPUT" "not applied: monitoring only mode" \
    "and the table says why, rather than reporting a setting that was never touched"
}

function test_the_controller_puts_dells_default_back_over_redfish_when_the_parameter_is_off() {
  # Every controller-level case here runs with the parameter on. Both branches write to the owner's PCIe
  # slots, and swapping them would send "Disabled" to a user who asked to keep Dell's cooling response
  export DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE=false
  export MOCK_REDFISH_PATCH_LOG="$TEST_TEMPORARY_DIRECTORY/patches"
  : > "$MOCK_REDFISH_PATCH_LOG"
  simulate_server "PowerEdge R6515" --cpus 1
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0xce"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="Unable to send RAW command (channel=0x0 netfn=0x30 lun=0x0 cmd=0xce rsp=0xc1): Invalid command"
  simulate_a_server_exposing_the_cooling_response_over_redfish --slots 4 --third-party "2" --mode "Disabled"

  local -r OUTPUT=$(run_controller "" 3)

  assert_matches "$(cat "$MOCK_REDFISH_PATCH_LOG")" '"PCIeSlotLFM\.2\.LFMMode":"Automatic"' \
    "Automatic is what enabled means for a slot : the iDRAC decides that slot's airflow itself"
  assert_matches "$OUTPUT" "fan control profile.*Enabled over Redfish" \
    "and the table reports the state that was asked for"
}

function test_a_missing_https_client_is_not_reported_as_local_mode() {
  # redfish_request() comes back without an answer for two reasons that need different things from the
  # reader : local mode, where there is no address to ask, and an HTTPS client that did not run. Both
  # produced the local mode wording, so a container addressed at 192.168.1.100 with credentials set was
  # told to "set IDRAC_HOST, IDRAC_USERNAME and IDRAC_PASSWORD" -- three variables it had set -- while
  # the real cause went unnamed. Reachable from the README's own "run it from a plain checkout" path, on
  # a host without perl or without IO::Socket::SSL (#429)
  local -r CLIENTLESS_DIRECTORY="$TEST_TEMPORARY_DIRECTORY/no_https_client"
  mkdir -p "$CLIENTLESS_DIRECTORY"
  cat > "$CLIENTLESS_DIRECTORY/perl" << 'STUB'
#!/bin/bash
echo "Can't locate IO/Socket/SSL.pm in @INC" >&2
exit 2
STUB
  chmod +x "$CLIENTLESS_DIRECTORY/perl"

  export MOCK_REDFISH_CONFORMANT_STATUS="200"
  REDFISH_ATTEMPTS=0
  REDFISH_COOLING_RESPONSE_SETTLED=false

  PATH="$CLIENTLESS_DIRECTORY:$PATH" \
    attempt_the_redfish_cooling_response "Disabled" "Disabled" \
    > "$TEST_TEMPORARY_DIRECTORY/no_client" 2>&1
  local -r OUTPUT=$(cat "$TEST_TEMPORARY_DIRECTORY/no_client")

  assert_equals "Not over IPMI (no HTTPS client to ask with)" \
    "$THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS" \
    "the column must not claim a network mode container needs network mode"
  assert_not_contains "$OUTPUT" "Set IDRAC_HOST, IDRAC_USERNAME and IDRAC_PASSWORD" \
    "they are already set : sending the reader to check them is sending them to the wrong place"
  assert_matches "$OUTPUT" "IO::Socket::SSL" "the cause has to be named to be fixable"
  assert_equals "true" "$REDFISH_COOLING_RESPONSE_SETTLED" "no later cycle grows an HTTPS client"
}

function test_local_mode_still_says_local_mode() {
  # The other half of the same branch, so that telling the two causes apart cannot silently become
  # telling neither
  export IDRAC_HOST="local"
  REDFISH_ATTEMPTS=0
  REDFISH_COOLING_RESPONSE_SETTLED=false

  attempt_the_redfish_cooling_response "Disabled" "Disabled" \
    > "$TEST_TEMPORARY_DIRECTORY/local_again" 2>&1

  assert_equals "Not over IPMI (Redfish needs network mode)" \
    "$THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS"
  assert_matches "$(cat "$TEST_TEMPORARY_DIRECTORY/local_again")" \
    "Set IDRAC_HOST, IDRAC_USERNAME and IDRAC_PASSWORD" \
    "here they are genuinely unset, and setting them is genuinely the answer"
}

function test_a_server_whose_slots_all_hold_dell_cards_is_told_there_is_nothing_to_apply_it_to() {
  # The last branch of the errand no case reached. A server that has the setting and nothing to apply it
  # to must say so and settle : "Not supported by this server" would be false about the machine,
  # "Disabled over Redfish" false about what was done, and re-probing every cycle for the life of the
  # container is what #347 removed everywhere else
  export MOCK_REDFISH_PATCH_LOG="$TEST_TEMPORARY_DIRECTORY/patches"
  : > "$MOCK_REDFISH_PATCH_LOG"
  simulate_a_server_exposing_the_cooling_response_over_redfish --slots 6
  REDFISH_ATTEMPTS=0
  REDFISH_COOLING_RESPONSE_SETTLED=false

  attempt_the_redfish_cooling_response "Disabled" "Disabled" \
    > "$TEST_TEMPORARY_DIRECTORY/nothing_to_apply" 2>&1

  assert_equals "No third-party PCIe card to apply it to" \
    "$THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS"
  assert_equals "true" "$REDFISH_COOLING_RESPONSE_SETTLED" "no later cycle grows a third-party card"
  assert_equals "0" "$(grep -c "" "$MOCK_REDFISH_PATCH_LOG")" \
    "a slot holding a Dell card is airflow Dell has real data for, and is left alone"
  assert_matches "$(cat "$TEST_TEMPORARY_DIRECTORY/nothing_to_apply")" "6 PCIe slots over Redfish" \
    "the reader is told what was found rather than only what was not"
}

function test_one_cycle_of_the_errand_costs_at_most_four_requests() {
  # The count the budget is shared between : the probe's two URIs, then the write path's read and its
  # PATCH. It is pinned so that a fifth request cannot join the errand without the arithmetic beside
  # REDFISH_REQUEST_TIMEOUT_IN_SECONDS being revisited -- the budget is one figure for all of them, so
  # each new request makes every other one's share smaller rather than adding to the total (#430)
  export MOCK_PERL_CALL_LOG="$TEST_TEMPORARY_DIRECTORY/perl_calls"
  : > "$MOCK_PERL_CALL_LOG"
  # The worst arrangement : the conformant URI is not there, the legacy one answers, and the write is
  # refused by something that describes a moment
  export MOCK_REDFISH_CONFORMANT_STATUS="404"
  export MOCK_REDFISH_LEGACY_STATUS="200"
  export MOCK_REDFISH_LEGACY_BODY
  MOCK_REDFISH_LEGACY_BODY=$(make_redfish_attributes_body --slots 4 --third-party "2")
  export MOCK_REDFISH_PATCH_STATUS="503"
  REDFISH_ATTEMPTS=0
  REDFISH_COOLING_RESPONSE_SETTLED=false

  attempt_the_redfish_cooling_response "Disabled" "Disabled" > /dev/null 2>&1

  assert_equals "4" "$(grep -c "" "$MOCK_PERL_CALL_LOG")" \
    "the errand is two probe requests and two write ones, which is what the timeout has to be read against"
  assert_equals "true" \
    "$([ $((4 * REDFISH_REQUEST_TIMEOUT_IN_SECONDS * MAXIMUM_REDFISH_ATTEMPTS)) -le 120 ] && echo true || echo false)" \
    "and what the whole errand may cost a container over its life stays bounded and stated"
}

function test_the_errand_spends_one_budget_rather_than_one_per_request() {
  # Each request used to be given REDFISH_REQUEST_TIMEOUT_IN_SECONDS of its own, and the errand makes up
  # to four of them. The budget is the errand's now, and each request gets what is left of it -- watched
  # here on the probe's pair, which is the one place two requests still share a cycle : the conformant
  # URI answers 404 quickly enough to be worth trying the legacy one straight away (#430)
  export MOCK_PERL_CALL_LOG="$TEST_TEMPORARY_DIRECTORY/perl_calls"
  : > "$MOCK_PERL_CALL_LOG"
  export MOCK_PERL_DELAY_IN_SECONDS=1
  export MOCK_REDFISH_CONFORMANT_STATUS="404"
  export MOCK_REDFISH_LEGACY_STATUS="200"
  export MOCK_REDFISH_LEGACY_BODY
  MOCK_REDFISH_LEGACY_BODY=$(make_redfish_attributes_body --slots 4 --third-party "2")
  REDFISH_ATTEMPTS=0
  REDFISH_COOLING_RESPONSE_SETTLED=false
  REDFISH_ATTRIBUTES_URI=""
  IS_THE_REDFISH_WRITE_PLANNED=false

  attempt_the_redfish_cooling_response "Disabled" "Disabled" > /dev/null 2>&1

  # The timeout the controller chose is the last argument of each invocation
  local -r TIMEOUTS=$(awk '{ print $NF }' "$MOCK_PERL_CALL_LOG")
  local -r FIRST_TIMEOUT=$(printf '%s\n' "$TIMEOUTS" | head -n 1)
  local -r LAST_TIMEOUT=$(printf '%s\n' "$TIMEOUTS" | tail -n 1)

  assert_equals "2" "$(grep -c "" "$MOCK_PERL_CALL_LOG")" \
    "the probe's two URIs share one cycle ; the write does not join them on an iDRAC this slow"
  assert_equals "$REDFISH_REQUEST_TIMEOUT_IN_SECONDS" "$FIRST_TIMEOUT" \
    "the first request may have the whole budget, nothing having been spent yet"
  assert_equals "true" "$([ "$LAST_TIMEOUT" -lt "$FIRST_TIMEOUT" ] && echo true || echo false)" \
    "and the second is given only what the first left of it, not a second full share"
}

function test_a_slow_idrac_gets_one_request_per_cycle_instead_of_a_stretched_one() {
  # The rhythm the loop keeps is max(CHECK_INTERVAL, the work), so work that runs long stretches the gap
  # between two runs of is_any_CPU_overheating() -- the only thing that takes fans off the user's static
  # speed. An iDRAC answering in a second or more therefore gets its errand spread over cycles : ask on
  # one, read the slots back on the next, write on the one after. Each cycle spends one request (#444)
  export MOCK_PERL_CALL_LOG="$TEST_TEMPORARY_DIRECTORY/perl_calls"
  : > "$MOCK_PERL_CALL_LOG"
  export MOCK_REDFISH_PATCH_LOG="$TEST_TEMPORARY_DIRECTORY/patches"
  : > "$MOCK_REDFISH_PATCH_LOG"
  export MOCK_PERL_DELAY_IN_SECONDS=1
  simulate_a_server_exposing_the_cooling_response_over_redfish --slots 4 --third-party "2"
  REDFISH_ATTEMPTS=0
  REDFISH_COOLING_RESPONSE_SETTLED=false
  REDFISH_ATTRIBUTES_URI=""
  IS_THE_REDFISH_WRITE_PLANNED=false

  # Cycle one : the server is asked whether it has the setting, and nothing else
  attempt_the_redfish_cooling_response "Disabled" "Disabled" > /dev/null 2>&1
  assert_equals "1" "$(grep -c "" "$MOCK_PERL_CALL_LOG")" "the asking is a cycle's work on its own"
  assert_equals "$REDFISH_SLOW_ANSWER_STATUS" "$THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS" \
    "and the column says why the rest waits, rather than reporting a failure that did not happen"
  assert_equals "false" "$REDFISH_COOLING_RESPONSE_SETTLED" "stopping for time settles nothing"

  # Cycle two : the slots are read back. The server is not asked again -- that answer does not change
  attempt_the_redfish_cooling_response "Disabled" "Disabled" > /dev/null 2>&1
  assert_equals "2" "$(grep -c "" "$MOCK_PERL_CALL_LOG")" "one more request, not three"
  assert_equals "0" "$(grep -c "" "$MOCK_REDFISH_PATCH_LOG")" "and nothing written yet"

  # Cycle three : the PATCH
  attempt_the_redfish_cooling_response "Disabled" "Disabled" > /dev/null 2>&1
  assert_equals "1" "$(grep -c "" "$MOCK_REDFISH_PATCH_LOG")" "the write lands on the cycle after the read"
  assert_matches "$(cat "$MOCK_REDFISH_PATCH_LOG")" '"PCIeSlotLFM\.2\.LFMMode":"Disabled"'
  assert_equals "true" "$REDFISH_COOLING_RESPONSE_SETTLED" "and the errand is done"
  assert_equals "0" "$REDFISH_ATTEMPTS" \
    "spreading the work over cycles is progress, not failed attempts : the retry budget is untouched"
}

function test_a_healthy_idrac_still_does_the_whole_errand_in_one_cycle() {
  # The other half of the same decision. Splitting across cycles is for a server slow enough that the
  # work would run past the interval ; one answering in milliseconds must still be finished with in one
  # cycle, exactly as before #444
  export MOCK_PERL_CALL_LOG="$TEST_TEMPORARY_DIRECTORY/perl_calls"
  : > "$MOCK_PERL_CALL_LOG"
  export MOCK_REDFISH_PATCH_LOG="$TEST_TEMPORARY_DIRECTORY/patches"
  : > "$MOCK_REDFISH_PATCH_LOG"
  simulate_a_server_exposing_the_cooling_response_over_redfish --slots 4 --third-party "2"
  REDFISH_ATTEMPTS=0
  REDFISH_COOLING_RESPONSE_SETTLED=false
  REDFISH_ATTRIBUTES_URI=""
  IS_THE_REDFISH_WRITE_PLANNED=false

  attempt_the_redfish_cooling_response "Disabled" "Disabled" > /dev/null 2>&1

  assert_equals "true" "$REDFISH_COOLING_RESPONSE_SETTLED" "one cycle is enough on a server that answers"
  assert_equals "1" "$(grep -c "" "$MOCK_REDFISH_PATCH_LOG")" "and the setting is applied in it"
  assert_equals "Disabled over Redfish" "$THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE_STATUS"
}

function test_no_request_is_ever_given_no_time_at_all() {
  # A timeout of zero is not "no time left" to HTTP::Tiny, it is no timeout at all -- which would turn an
  # exhausted budget into the one request that can hang for ever. The floor is a second, and the request
  # is still made rather than skipped : skipping is how the legacy URI would stop being tried at all on a
  # server whose conformant one hangs
  export MOCK_PERL_CALL_LOG="$TEST_TEMPORARY_DIRECTORY/perl_calls"
  : > "$MOCK_PERL_CALL_LOG"
  export MOCK_REDFISH_CONFORMANT_STATUS="200"

  # A budget that ran out five seconds ago
  REDFISH_ERRAND_DEADLINE_IN_SECONDS=$(( SECONDS - 5 ))
  redfish_get "$REDFISH_CONFORMANT_ATTRIBUTES_URI" "$REDFISH_REQUEST_TIMEOUT_IN_SECONDS" > /dev/null 2>&1
  REDFISH_ERRAND_DEADLINE_IN_SECONDS=""

  assert_equals "1" "$(grep -c "" "$MOCK_PERL_CALL_LOG")" "the request is made rather than skipped"
  assert_equals "1" "$(awk '{ print $NF }' "$MOCK_PERL_CALL_LOG")" \
    "and given a second, never zero, which perl would read as no timeout at all"
}

function test_the_way_out_keeps_the_budget_the_deadline_that_kills_it_allows() {
  # graceful_exit() and supervisor.sh reach set_the_cooling_response_over_redfish() on their own, with the
  # short per-request timeout #414 sized against the supervisor's grace period. The errand's budget must
  # not leak into them : a deadline left over from a monitoring cycle would clamp every exit request to
  # the one second floor, and worse, an unclosed one would do it for the life of the container
  export MOCK_PERL_CALL_LOG="$TEST_TEMPORARY_DIRECTORY/perl_calls"
  export MOCK_REDFISH_CONFORMANT_STATUS="200"
  REDFISH_ATTEMPTS=0
  REDFISH_COOLING_RESPONSE_SETTLED=false
  simulate_a_server_exposing_the_cooling_response_over_redfish --slots 4 --third-party "2"

  attempt_the_redfish_cooling_response "Disabled" "Disabled" > /dev/null 2>&1

  assert_empty "$REDFISH_ERRAND_DEADLINE_IN_SECONDS" \
    "the errand closes its budget however it returned"

  : > "$MOCK_PERL_CALL_LOG"
  set_the_cooling_response_over_redfish "Automatic" "$REDFISH_EXIT_REQUEST_TIMEOUT_IN_SECONDS" > /dev/null 2>&1

  assert_equals "$REDFISH_EXIT_REQUEST_TIMEOUT_IN_SECONDS" \
    "$(awk '{ print $NF }' "$MOCK_PERL_CALL_LOG" | head -n 1)" \
    "the way out asks for what it was given, not for what is left of somebody else's budget"
}

function test_a_fast_errand_that_straddles_a_second_is_not_split() {
  # The regression guard for how #444 was first written. Asking a whole-second counter whether a second
  # has passed answers yes for any errand that crosses a boundary, however fast it was -- so a healthy
  # iDRAC answering in milliseconds got its errand split across cycles whenever the boundary happened to
  # fall inside it. That is a coin toss, which is why it passed here and failed on the runner.
  #
  # This case removes the luck : it waits until a boundary is imminent, THEN runs the errand, so the
  # straddle is certain. Under a whole-second reading it fails every time
  export MOCK_REDFISH_PATCH_LOG="$TEST_TEMPORARY_DIRECTORY/patches"
  : > "$MOCK_REDFISH_PATCH_LOG"
  simulate_a_server_exposing_the_cooling_response_over_redfish --slots 4 --third-party "2"
  REDFISH_ATTEMPTS=0
  REDFISH_COOLING_RESPONSE_SETTLED=false
  REDFISH_ATTRIBUTES_URI=""
  IS_THE_REDFISH_WRITE_PLANNED=false

  # Up to a second of 10ms steps, until the clock is within 50ms of ticking over
  local WAITED_HUNDREDTHS=0
  local FRACTION
  while [ "$WAITED_HUNDREDTHS" -lt 100 ]; do
    FRACTION="${EPOCHREALTIME#*[.,]}"
    [ "${FRACTION:0:2}" == "99" ] && break
    command -p sleep 0.01
    WAITED_HUNDREDTHS=$((WAITED_HUNDREDTHS + 1))
  done

  attempt_the_redfish_cooling_response "Disabled" "Disabled" > /dev/null 2>&1

  assert_equals "true" "$REDFISH_COOLING_RESPONSE_SETTLED" \
    "crossing a second is not spending one : a server answering in milliseconds is finished with in one cycle"
  assert_equals "1" "$(grep -c "" "$MOCK_REDFISH_PATCH_LOG")" "and the setting is applied in it"
}

# The cases below drive the controller with a document no one here wrote : the System attributes of a
# real PowerEdge R740xd2, posted on #360. Everything above builds its own body to the shape the code
# expects, which is the shape whoever wrote the code had in mind ; these run against what an iDRAC
# actually answered, in the order it answered it (#489).

function test_a_captured_document_is_read_as_the_machine_it_came_from() {
  # The conformant URI answered 404 on this machine, so the capture is served where it really came
  # from : the legacy one, reached only after that 404. Its status is left at the mock's default
  export MOCK_REDFISH_LEGACY_STATUS="200"
  export MOCK_REDFISH_LEGACY_BODY
  MOCK_REDFISH_LEGACY_BODY=$(make_captured_r740xd2_attributes_body)

  does_this_server_expose_the_cooling_response_over_redfish

  assert_equals "15" "$REDFISH_COOLING_RESPONSE_SLOT_COUNT" \
    "the capture carries fifteen slot instances, ordered 1, 10, 11 ... 15, 2, 3 ... 9"
  assert_empty "$REDFISH_THIRD_PARTY_SLOTS" \
    "fourteen of its slots are empty and the fifteenth holds an AHCI controller reading \"No\""
  assert_equals "Automatic" "$(read_the_lfm_mode_of_slot "$MOCK_REDFISH_LEGACY_BODY" 1)" \
    "slot 1's mode is the first slot of the document, read from its real text"
  assert_equals "Automatic" "$(read_the_lfm_mode_of_slot "$MOCK_REDFISH_LEGACY_BODY" 15)" \
    "and slot 15 is the one a lexicographic order puts fifth, not last"
}

function test_the_attribute_a_real_document_opens_on_is_not_dropped() {
  # Dell orders these alphabetically, so a real answer opens on PCIeSlotLFM.1.3rdPartyCard -- the exact
  # position an anchored pattern could not reach, which cost the machine's FIRST PCIe slot until #412.
  # That fix was proved against a body written to have the shape ; this proves it against one that has
  # the shape because an iDRAC produced it. One value is changed, and only one : slot 1's card flag
  export MOCK_REDFISH_LEGACY_STATUS="200"
  export MOCK_REDFISH_LEGACY_BODY
  MOCK_REDFISH_LEGACY_BODY=$(make_captured_r740xd2_attributes_body "1=3rdPartyCard=Yes")

  does_this_server_expose_the_cooling_response_over_redfish

  assert_equals "1 " "$REDFISH_THIRD_PARTY_SLOTS" \
    "the card in the document's opening attribute is a card like any other"
  assert_equals "15" "$REDFISH_COOLING_RESPONSE_SLOT_COUNT" "and the slot count is unchanged by it"
}

function test_the_controller_tells_a_captured_r740xd2_owner_there_is_nothing_to_apply_it_to() {
  # End to end, on the machine the capture came from : a 14th generation iDRAC that answers the raw
  # command with rsp=0xc1, has the setting on fifteen slots, and holds no third-party card anywhere.
  # The column must say that rather than name the server unable or claim something was applied
  export DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE=true
  export MOCK_REDFISH_PATCH_LOG="$TEST_TEMPORARY_DIRECTORY/patches"
  : > "$MOCK_REDFISH_PATCH_LOG"
  simulate_server "PowerEdge R740xd2" --cpus 2
  export MOCK_IPMITOOL_RAW_FAIL_PATTERN="0x30 0xce"
  export MOCK_IPMITOOL_RAW_FAIL_STDERR="Unable to send RAW command (channel=0x0 netfn=0x30 lun=0x0 cmd=0xce rsp=0xc1): Invalid command"
  export MOCK_REDFISH_LEGACY_STATUS="200"
  export MOCK_REDFISH_LEGACY_BODY
  MOCK_REDFISH_LEGACY_BODY=$(make_captured_r740xd2_attributes_body)

  local -r OUTPUT=$(run_controller "" 3)

  assert_matches "$OUTPUT" "fan control profile.*No third-party PCIe card to apply it to" \
    "the table must report what was found rather than what the command answered"
  assert_equals "0" "$(grep -c "" "$MOCK_REDFISH_PATCH_LOG")" \
    "and nothing may be written to a slot holding a Dell card or no card at all"
  assert_matches "$OUTPUT" "15 PCIe slots over Redfish" "the reader is told how many were found"
}
