#!/bin/bash

# Identification of the server, and the single decision that depends on it :
# whether it is a 14th generation PowerEdge or newer. Gen 14+ servers must not be
# sent the third-party PCIe card cooling response command, which only exists on
# Gen 13 and older.
#
# The catalogue driving these tests covers every generation from the 9th (2006)
# to the 17th (2024), including the recent ones whose firmware no longer accepts
# Dell's IPMI raw fan control commands at all.

# Shared body of the nine per-generation test cases
function assert_generation_is_detected_as_the_catalogue_expects() {
  local -r GENERATION="$1"
  local ENTRY MODEL EXPECTED_FLAG

  while IFS= read -r ENTRY; do
    IFS='|' read -r _ MODEL _ EXPECTED_FLAG _ _ <<< "$ENTRY"

    local ACTUAL_FLAG=false
    if is_detected_as_gen_14_or_newer "$MODEL"; then
      ACTUAL_FLAG=true
    fi

    assert_equals "$EXPECTED_FLAG" "$ACTUAL_FLAG" \
      "$MODEL (Gen $GENERATION) should be detected as gen 14 or newer = $EXPECTED_FLAG"
  done < <(catalogue_entries_of_generation "$GENERATION")
}

function test_every_9th_generation_model_is_detected_as_the_catalogue_expects() {
  assert_generation_is_detected_as_the_catalogue_expects 9
}

function test_every_10th_generation_model_is_detected_as_the_catalogue_expects() {
  assert_generation_is_detected_as_the_catalogue_expects 10
}

function test_every_11th_generation_model_is_detected_as_the_catalogue_expects() {
  assert_generation_is_detected_as_the_catalogue_expects 11
}

function test_every_12th_generation_model_is_detected_as_the_catalogue_expects() {
  assert_generation_is_detected_as_the_catalogue_expects 12
}

function test_every_13th_generation_model_is_detected_as_the_catalogue_expects() {
  assert_generation_is_detected_as_the_catalogue_expects 13
}

function test_every_14th_generation_model_is_detected_as_the_catalogue_expects() {
  assert_generation_is_detected_as_the_catalogue_expects 14
}

function test_every_15th_generation_model_is_detected_as_the_catalogue_expects() {
  assert_generation_is_detected_as_the_catalogue_expects 15
}

function test_every_16th_generation_model_is_detected_as_the_catalogue_expects() {
  assert_generation_is_detected_as_the_catalogue_expects 16
}

function test_every_17th_generation_model_is_detected_as_the_catalogue_expects() {
  assert_generation_is_detected_as_the_catalogue_expects 17
}

function test_the_models_named_outside_dells_usual_scheme_are_not_detected_as_gen_14_or_newer() {
  # Documents a known blind spot of the name-based detection rather than a wish :
  # these servers are Gen 14 or newer but their name carries no "[RT]<digit><digit>0",
  # so the controller treats them as Gen 13 or older and keeps sending them the
  # third-party PCIe card cooling response command (which their BMC rejects, and
  # the controller discards that rejection on purpose)
  local MODEL
  for MODEL in \
    "PowerEdge R6415" "PowerEdge R7425" "PowerEdge C6420" "PowerEdge M640" "PowerEdge MX740c" \
    "PowerEdge R6515" "PowerEdge R7525" "PowerEdge XR11" \
    "PowerEdge R6615" "PowerEdge R7625" "PowerEdge XE9680" \
    "PowerEdge R6715" "PowerEdge R7725" "PowerEdge XE7745"; do
    if is_detected_as_gen_14_or_newer "$MODEL"; then
      fail "$MODEL is currently detected as gen 14 or newer" \
        "the detection is a match on the model name, update the catalogue if it was improved"
    else
      pass
    fi
  done
}

function test_the_detection_relies_on_the_uppercase_letter_directly_before_the_digits() {
  # The optional whitespace is what makes "PowerEdge R 740" work...
  assert_matches "PowerEdge R 740" "$GENERATION_14_OR_NEWER_REGEX" "a space between the letter and the digits is tolerated"
  assert_matches "PowerEdge T 640" "$GENERATION_14_OR_NEWER_REGEX"
  # ...but the letter itself is matched case-sensitively, and nothing else stands in for it
  if is_detected_as_gen_14_or_newer "poweredge r740"; then
    fail "a lowercase model name should not be detected as gen 14 or newer"
  else
    pass
  fi
  if is_detected_as_gen_14_or_newer ""; then
    fail "an empty model name should not be detected as gen 14 or newer"
  else
    pass
  fi
  if is_detected_as_gen_14_or_newer "Super Server X11DPi-N"; then
    fail "a model name from another manufacturer should not be detected as gen 14 or newer"
  else
    pass
  fi
}

function test_the_server_model_is_read_from_the_fru_product_fields() {
  export MOCK_IPMITOOL_FRU_OUTPUT
  MOCK_IPMITOOL_FRU_OUTPUT=$(make_fru_output --manufacturer "DELL" --model "PowerEdge R740xd")

  get_Dell_server_model

  assert_equals "DELL" "$SERVER_MANUFACTURER"
  assert_equals "PowerEdge R740xd" "$SERVER_MODEL"
}

function test_the_server_model_falls_back_on_the_fru_board_fields() {
  # Some servers leave the "Product *" fields empty and only fill the board ones
  export MOCK_IPMITOOL_FRU_OUTPUT
  MOCK_IPMITOOL_FRU_OUTPUT=$(make_fru_output --manufacturer "DELL" --model "PowerEdge R630" --board-fields-only)

  get_Dell_server_model

  assert_equals "DELL" "$SERVER_MANUFACTURER"
  assert_equals "PowerEdge R630" "$SERVER_MODEL"
}

function test_a_failing_ipmi_connection_stops_the_controller_with_an_actionable_error() {
  export MOCK_IPMITOOL_FRU_EXIT_CODE=1
  export MOCK_IPMITOOL_FRU_OUTPUT="Error: Unable to establish IPMI v2 / RMCP+ session"

  local OUTPUT
  OUTPUT=$(get_Dell_server_model 2>&1)
  local -r EXIT_CODE=$?

  assert_equals 1 "$EXIT_CODE" "an unreachable iDRAC should stop the controller instead of silently continuing"
  assert_contains "$OUTPUT" "Could not establish IPMI connection"
  assert_contains "$OUTPUT" "IDRAC_HOST" "the error should name the variables to check"
  assert_contains "$OUTPUT" "Unable to establish IPMI v2 / RMCP+ session" "the error should quote what ipmitool said"
}

function test_unreadable_fru_devices_do_not_stop_a_server_that_could_still_be_identified() {
  # "ipmitool fru" walks every FRU device and exits non-zero as soon as one of them
  # fails to read, so an R740xd with an empty drive backplane bay returns 1 while still
  # reporting its model. Exiting on that exit code alone refused to start on healthy
  # hardware, which is the regression this guards against.
  # The harness builds a lanplus login string, so this is the network mode case
  export MOCK_IPMITOOL_FRU_OUTPUT MOCK_IPMITOOL_FRU_STDERR MOCK_IPMITOOL_FRU_EXIT_CODE
  MOCK_IPMITOOL_FRU_OUTPUT=$(make_fru_output --manufacturer "DELL" --model "PowerEdge R740xd" --with-unreadable-devices)
  MOCK_IPMITOOL_FRU_STDERR="Get Device ID command failed: 0xc9 Parameter out of range"
  MOCK_IPMITOOL_FRU_EXIT_CODE=1

  local EXIT_CODE=0
  capture_output get_Dell_server_model || EXIT_CODE=$?

  assert_equals 0 "$EXIT_CODE" "an identified server should start even though ipmitool exited non-zero"
  assert_not_contains "$CAPTURED_OUTPUT" "Could not establish IPMI connection" "a partial FRU read is not a connection failure"
  assert_equals "DELL" "$SERVER_MANUFACTURER"
  assert_equals "PowerEdge R740xd" "$SERVER_MODEL"
}

function test_unreadable_fru_devices_do_not_stop_the_controller_in_local_mode_either() {
  # The transport says nothing about whether individual FRU devices answered, so local
  # mode must not be stricter than the network mode covered above. Both were reproduced
  # on the same R740xd : "-I open" and "-I lanplus" each exit 1, each report the same
  # three unreadable bays (BP0, BP2, PERC2), and each still return the model
  export MOCK_IPMITOOL_FRU_OUTPUT MOCK_IPMITOOL_FRU_STDERR MOCK_IPMITOOL_FRU_EXIT_CODE
  MOCK_IPMITOOL_FRU_OUTPUT=$(make_fru_output --manufacturer "DELL" --model "PowerEdge R740xd" --with-unreadable-devices)
  MOCK_IPMITOOL_FRU_STDERR="Get Device ID command failed: 0xc9 Parameter out of range"
  MOCK_IPMITOOL_FRU_EXIT_CODE=1

  local -r IDRAC_LOGIN_STRING="open"

  local EXIT_CODE=0
  capture_output get_Dell_server_model || EXIT_CODE=$?

  assert_equals 0 "$EXIT_CODE" "local mode should tolerate a partial FRU read exactly like network mode"
  assert_equals "DELL" "$SERVER_MANUFACTURER"
  assert_equals "PowerEdge R740xd" "$SERVER_MODEL"
}

function test_unreadable_fru_devices_still_stop_a_server_that_could_not_be_identified_at_all() {
  # The counterpart : when nothing came back, the non-zero exit code is a real failure
  # and the controller must still refuse to run blind
  export MOCK_IPMITOOL_FRU_OUTPUT MOCK_IPMITOOL_FRU_STDERR MOCK_IPMITOOL_FRU_EXIT_CODE
  MOCK_IPMITOOL_FRU_OUTPUT=""
  MOCK_IPMITOOL_FRU_STDERR="Device not present (Timeout)"
  MOCK_IPMITOOL_FRU_EXIT_CODE=1

  local OUTPUT
  OUTPUT=$(get_Dell_server_model 2>&1)
  local -r EXIT_CODE=$?

  assert_equals 1 "$EXIT_CODE" "a server that could not be identified at all should stop the controller"
  assert_contains "$OUTPUT" "Could not establish IPMI connection"
}

function test_the_catalogue_covers_every_generation_and_typology_without_duplicates() {
  local GENERATION
  for GENERATION in "${DELL_SERVER_GENERATIONS[@]}"; do
    local MODEL_COUNT
    MODEL_COUNT=$(catalogue_entries_of_generation "$GENERATION" | wc -l)
    if [ "$MODEL_COUNT" -ge 4 ]; then
      pass
    else
      fail "generation $GENERATION is only covered by $MODEL_COUNT models"
    fi
  done

  # Single, dual and quad socket servers must all be represented
  local SOCKETS
  for SOCKETS in 1 2 4; do
    local TYPOLOGY_COUNT
    TYPOLOGY_COUNT=$(catalogue_entries_with_sockets "$SOCKETS" | wc -l)
    if [ "$TYPOLOGY_COUNT" -ge 4 ]; then
      pass
    else
      fail "only $TYPOLOGY_COUNT models with $SOCKETS CPU sockets are catalogued"
    fi
  done

  local DUPLICATED_MODELS
  DUPLICATED_MODELS=$(printf '%s\n' "${DELL_SERVER_CATALOGUE[@]}" | cut -d'|' -f2 | sort | uniq -d)
  assert_empty "$DUPLICATED_MODELS" "the catalogue should not list the same model twice"

  # Rack and tower servers, blades and modular sleds must all be represented
  local -r ENCLOSURE_HOUSED_COUNT=$(catalogue_entries_housed_in_an_enclosure | wc -l)
  if [ "$ENCLOSURE_HOUSED_COUNT" -ge 20 ]; then
    pass
  else
    fail "only $ENCLOSURE_HOUSED_COUNT servers housed in an enclosure are catalogued"
  fi

  local ENTRY
  for ENTRY in "${DELL_SERVER_CATALOGUE[@]}"; do
    assert_matches "$ENTRY" '^(9|1[0-7])\|[^|]+\|[124]\|(true|false)\|(supported|firmware-dependent|unsupported|chassis-managed)\|(standalone|[A-Za-z0-9-]+(/[A-Za-z0-9-]+)*)$' \
      "malformed catalogue entry"
  done
}
