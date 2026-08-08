#!/bin/bash

# Checks on the scripts themselves, before any behavior is exercised : a syntax
# error or a file missing from the Docker image breaks every server at once,
# whatever its generation.

function test_every_shell_script_has_a_valid_syntax() {
  local SCRIPT
  for SCRIPT in \
    "$REPO_ROOT"/*.sh \
    "$TESTS_DIRECTORY"/*.sh \
    "$TESTS_DIRECTORY"/lib/*.sh \
    "$TESTS_DIRECTORY"/cases/*.sh \
    "$TESTS_DIRECTORY"/mocks/*; do
    [ -f "$SCRIPT" ] || continue

    local SYNTAX_ERRORS
    if SYNTAX_ERRORS=$(bash -n "$SCRIPT" 2>&1); then
      pass
    else
      fail "${SCRIPT#$REPO_ROOT/} has a syntax error" "$SYNTAX_ERRORS"
    fi
  done
}

function test_sourcing_functions_only_declares_functions() {
  # functions.sh is sourced by the controller, by the healthcheck and by this
  # suite : it must not run anything nor print anything on its own
  local OUTPUT
  OUTPUT=$(bash -c "source '$REPO_ROOT/functions.sh'" 2>&1)
  local -r EXIT_CODE=$?

  assert_equals 0 "$EXIT_CODE" "sourcing functions.sh should succeed"
  assert_empty "$OUTPUT" "sourcing functions.sh should not print anything"
}

function test_every_file_sourced_at_runtime_is_shipped_in_the_docker_image() {
  if [ ! -f "$REPO_ROOT/Dockerfile" ]; then
    # The suite is running inside the built image, which does not carry the
    # Dockerfile that produced it
    skip_test "no Dockerfile next to the scripts"
    return 0
  fi

  local -r DOCKERFILE_CONTENT=$(cat "$REPO_ROOT/Dockerfile")

  local SOURCED_FILE
  while IFS= read -r SOURCED_FILE; do
    [ -n "$SOURCED_FILE" ] || continue

    if [ ! -f "$REPO_ROOT/$SOURCED_FILE" ]; then
      fail "$SOURCED_FILE is sourced at runtime but does not exist"
      continue
    fi

    assert_matches "$DOCKERFILE_CONTENT" "(ADD|COPY) $SOURCED_FILE " \
      "$SOURCED_FILE is sourced at runtime, the Dockerfile must copy it into the image"
  done < <(grep -hoE '^source [A-Za-z0-9_.-]+\.sh' \
    "$REPO_ROOT/Dell_iDRAC_fan_controller.sh" "$REPO_ROOT/healthcheck.sh" |
    awk '{print $2}' | sort -u)
}

function test_the_test_context_starts_from_the_docker_images_defaults() {
  # Every test case starts from setup_test_context, which claims to reproduce
  # the environment the Docker image gives the controller. When the Dockerfile
  # changes a default and the harness does not follow, the whole suite quietly
  # starts validating a configuration nobody runs, and nothing goes red to say
  # so : that is exactly how CHECK_INTERVAL stayed at 60s after the image
  # dropped it to 5s. This is the guard against that drift
  if [ ! -f "$REPO_ROOT/Dockerfile" ]; then
    # The suite is running inside the built image, which does not carry the
    # Dockerfile that produced it
    skip_test "no Dockerfile next to the scripts"
    return 0
  fi

  # IDRAC_HOST is the one deliberate difference : the image defaults to local
  # mode, the suite to network mode, which is the one with a login string to
  # build, a reachable host to name in errors and a power state to poll
  local -r DELIBERATELY_DIFFERENT=" IDRAC_HOST "

  local ENV_DECLARATION KEY EXPECTED_VALUE
  while IFS= read -r ENV_DECLARATION; do
    KEY="${ENV_DECLARATION%%=*}"
    EXPECTED_VALUE="${ENV_DECLARATION#*=}"

    if [[ "$DELIBERATELY_DIFFERENT" == *" $KEY "* ]]; then
      continue
    fi

    assert_equals "$EXPECTED_VALUE" "${!KEY-}" \
      "$KEY should start from the value the Dockerfile gives the container"
  done < <(grep -E '^ENV [A-Z_]+=' "$REPO_ROOT/Dockerfile" | sed 's/^ENV //')
}

function test_the_env_example_offers_every_parameter_the_image_declares() {
  # .env.example is what a user copies to configure the container, and its own
  # header points at the README for the details. A parameter the image declares
  # but that file omits is a parameter nobody discovers by following the
  # documented path : MONITORING_ONLY_MODE was missing from it while the
  # controller's error messages told users to set that very variable. This is
  # the guard against that drift
  if [ ! -f "$REPO_ROOT/Dockerfile" ] || [ ! -f "$REPO_ROOT/.env.example" ]; then
    # The suite is running inside the built image, which carries neither the
    # Dockerfile that produced it nor the example file shipped beside it
    skip_test "no Dockerfile and .env.example next to the scripts"
    return 0
  fi

  # Space padded on both ends so a key can be matched whole, the same way the
  # test above tells IDRAC_HOST apart from a key merely containing it
  local ENV_EXAMPLE_KEYS=" "
  local LINE
  while IFS= read -r LINE; do
    ENV_EXAMPLE_KEYS+="${LINE%%=*} "
  done < <(grep -E '^[A-Z_]+=' "$REPO_ROOT/.env.example")

  local KEY
  while IFS= read -r KEY; do
    assert_contains "$ENV_EXAMPLE_KEYS" " $KEY " \
      "$KEY is declared by the Dockerfile, .env.example should show users how to set it"
  done < <(grep -E '^ENV [A-Z_]+=' "$REPO_ROOT/Dockerfile" | sed 's/^ENV //' | cut -d= -f1)
}

function test_the_healthcheck_succeeds_when_the_sensors_can_be_read() {
  local OUTPUT
  OUTPUT=$(bash "$REPO_ROOT/healthcheck.sh" 2>&1)
  local -r EXIT_CODE=$?

  assert_equals 0 "$EXIT_CODE" "the healthcheck should succeed when ipmitool answers"
  assert_contains "$OUTPUT" "degrees C" "the healthcheck should print the sensor readings"
}

function test_the_healthcheck_fails_when_the_sensors_cannot_be_read() {
  export MOCK_IPMITOOL_SDR_EXIT_CODE=1
  export MOCK_IPMITOOL_SDR_OUTPUT=""

  local EXIT_CODE=0
  bash "$REPO_ROOT/healthcheck.sh" > /dev/null 2>&1 || EXIT_CODE=$?

  assert_not_equals 0 "$EXIT_CODE" "the healthcheck should fail when ipmitool fails, so Docker restarts the container"
}
