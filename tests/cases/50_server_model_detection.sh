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

function test_a_populated_power_supply_is_not_mistaken_for_the_server_itself() {
  # "ipmitool fru" describes every FRU device on the bus, and a populated power supply
  # fills the same "Product Manufacturer" / "Product Name" fields as the server. Keeping
  # every match makes the manufacturer "DELL\nDELL", which the caller's
  # [[ ! $SERVER_MANUFACTURER == "DELL" ]] fails, refusing to start with "Your server
  # isn't a Dell product" on a server that was just identified correctly
  export MOCK_IPMITOOL_FRU_OUTPUT
  MOCK_IPMITOOL_FRU_OUTPUT=$(make_fru_output --manufacturer "DELL" --model "PowerEdge R740xd" --with-readable-psu)

  get_Dell_server_model

  assert_equals "DELL" "$SERVER_MANUFACTURER" "the manufacturer is the server's own, once, not one per FRU device"
  assert_equals "PowerEdge R740xd" "$SERVER_MODEL" "the model is the server's, not its power supply's"
  assert_not_contains "$SERVER_MODEL" "PWR SPLY" "the power supply's product name must not leak into the model"
}

function test_a_populated_power_supply_does_not_poison_the_board_field_fallback_either() {
  # The same hazard on the fallback path, and the likelier one on real hardware : Dell
  # power supplies commonly leave the "Product *" fields empty and fill only the board
  # ones, and the fallback is exactly what runs on a server that filled no product field
  # either. Nothing about a failing connection is involved -- this inventory is entirely
  # readable, so "ipmitool fru" exits 0 and no connection check stands in the way
  export MOCK_IPMITOOL_FRU_OUTPUT
  MOCK_IPMITOOL_FRU_OUTPUT=$(make_fru_output --manufacturer "DELL" --model "PowerEdge R630" --board-fields-only --with-readable-psu)

  get_Dell_server_model

  assert_equals "DELL" "$SERVER_MANUFACTURER" "the board fallback must take the first match only"
  assert_equals "PowerEdge R630" "$SERVER_MODEL" "the board fallback must not append the power supply's board product"
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
  assert_contains "$OUTPUT" "exited with code 1" "the error should report the exit code it no longer decides on"
}

function test_unreadable_fru_devices_do_not_stop_a_server_that_could_still_be_identified() {
  # "ipmitool fru" walks every FRU device and exits non-zero as soon as one of them
  # fails to read, so an R740xd with an empty drive backplane bay returns 1 while still
  # reporting its model. Exiting on that exit code alone refused to start on healthy
  # hardware, which is the regression this guards against.
  # The harness builds a lanplus login string, so this is the network mode case
  simulate_partially_readable_fru_inventory --manufacturer "DELL" --model "PowerEdge R740xd"

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
  IDRAC_HOST="local"
  IDRAC_LOGIN_STRING="open"
  simulate_partially_readable_fru_inventory --manufacturer "DELL" --model "PowerEdge R740xd"

  local EXIT_CODE=0
  capture_output get_Dell_server_model || EXIT_CODE=$?

  assert_equals 0 "$EXIT_CODE" "local mode should tolerate a partial FRU read exactly like network mode"
  assert_equals "DELL" "$SERVER_MANUFACTURER"
  assert_equals "PowerEdge R740xd" "$SERVER_MODEL"
  assert_equals "1" "$(count_ipmitool_calls_matching '^-I open fru$')" \
    "the inventory should have been read over the local interface, which is what this case is about"
}

function test_a_partially_read_inventory_still_falls_back_on_the_fru_board_fields() {
  # The two halves meeting : a server that fills only the "Board *" fields AND has empty
  # bays. The fallback runs before anything is decided, so the board fields alone identify it
  simulate_partially_readable_fru_inventory --manufacturer "DELL" --model "PowerEdge R630" --board-fields-only

  local EXIT_CODE=0
  capture_output get_Dell_server_model || EXIT_CODE=$?

  assert_equals 0 "$EXIT_CODE" "the board fields identify the server just as well as the product ones"
  assert_equals "DELL" "$SERVER_MANUFACTURER"
  assert_equals "PowerEdge R630" "$SERVER_MODEL"
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

function test_an_empty_inventory_is_not_reported_as_a_failure_ipmitool_never_returned() {
  # An inventory that came back blank from a call that SUCCEEDED is not a failed call. The
  # error still has to fire -- nothing identified the server -- but quoting an exit code of
  # 0 in it would send the user looking for a failure ipmitool never reported
  export MOCK_IPMITOOL_FRU_OUTPUT="FRU Device Description : Builtin FRU Device (ID 0)"
  export MOCK_IPMITOOL_FRU_EXIT_CODE=0

  local OUTPUT
  OUTPUT=$(get_Dell_server_model 2>&1)
  local -r EXIT_CODE=$?

  assert_equals 1 "$EXIT_CODE" "an inventory identifying nothing should stop the controller"
  assert_not_contains "$OUTPUT" "exited with code" "a call that succeeded has no exit code worth reporting"
  assert_contains "$OUTPUT" "ipmitool said:" "the error should still quote the inventory it could not read"
}

function test_local_mode_is_not_told_to_check_a_username_and_a_password_it_never_sends() {
  # Local mode talks to the host's own BMC through the exposed IPMI device : naming
  # IDRAC_USERNAME and IDRAC_PASSWORD there sends the user to correct something the
  # connection does not even use
  IDRAC_HOST="local"
  IDRAC_LOGIN_STRING="open"
  export MOCK_IPMITOOL_FRU_EXIT_CODE=1
  export MOCK_IPMITOOL_FRU_OUTPUT="Could not open device at /dev/ipmi0 or /dev/ipmi/0 or /dev/ipmidev/0: No such file or directory"

  local OUTPUT
  OUTPUT=$(get_Dell_server_model 2>&1)
  local -r EXIT_CODE=$?

  assert_equals 1 "$EXIT_CODE" "a local BMC that answers nothing should stop the controller too"
  assert_contains "$OUTPUT" "IDRAC_HOST" "the error should name the parameter that selects local mode"
  assert_not_contains "$OUTPUT" "Parameter : IDRAC_HOST / IDRAC_USERNAME / IDRAC_PASSWORD" \
    "local mode should not be told to check credentials it never sends"
  assert_contains "$OUTPUT" "Could not open device at" "the error should quote what ipmitool said"
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
