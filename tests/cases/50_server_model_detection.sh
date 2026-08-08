#!/bin/bash

# Identification of the server : reading its manufacturer and model out of the
# FRU inventory, and refusing to run when the iDRAC cannot be reached at all.
#
# Nothing the controller does depends on the model name any more. It used to
# decide from it whether the server was a 14th generation PowerEdge or newer, and
# that decision is now taken by asking the server itself (issue #173), so the
# model is only ever logged — it helps whoever reads a posted output, and that is
# all it is for.
#
# The catalogue driving the tests here and in 55_enclosure_housed_servers.sh
# covers every generation from the 9th (2006) to the 17th (2024).

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
  assert_contains "$OUTPUT" "the container will not start" "the error should say the container is refusing to start"
  assert_contains "$OUTPUT" "credentials that can open an IPMI session" "the error should say what is expected instead"
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
  assert_not_contains "$CAPTURED_OUTPUT" "the container will not start" "a partial FRU read is not a connection failure"
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
  assert_contains "$OUTPUT" "credentials that can open an IPMI session"
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
    assert_matches "$ENTRY" '^(9|1[0-7])\|[^|]+\|[124]\|(supported|firmware-dependent|unsupported|chassis-managed)\|(standalone|[A-Za-z0-9-]+(/[A-Za-z0-9-]+)*)$' \
      "malformed catalogue entry"
  done
}
