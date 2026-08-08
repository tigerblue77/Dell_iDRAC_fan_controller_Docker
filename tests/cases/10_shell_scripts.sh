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

function test_no_statement_expands_two_command_substitutions() {
  # Bash re-parses the text of every $( ) at expansion time, and it runs pending
  # trap handlers from inside that same reader loop. A SIGTERM landing there gets
  # its handler parsed with the substitution's state still open, so the trap
  # string fails to parse, graceful_exit never runs, and the container dies
  # leaving the fans on the user's static speed (issue #188).
  #
  # The risk is not linear in the number of substitutions, it jumps as soon as two
  # of them are expanded in the same pass. Measured on 250 SIGTERM'd runs per
  # variant, on tiny scripts doing nothing else :
  #
  #   no command substitution at all ......................   0
  #   two of them, in two separate statements ............   0
  #   one of them ........................................   2
  #   two of them in the same expansion .................. 61 to 182
  #
  # So the invariant the shipped scripts hold is one substitution per statement.
  # Compute each value into a variable and use the variable. That does not make
  # bash safe -- a single substitution still measured 2 runs in 250, and no amount
  # of hoisting removes the last one -- but it is what took the controller itself
  # from 11 stops in 400 down to none.
  #
  # Arithmetic expansion, $(( )), is deliberately not matched : it measured no
  # worse than a single substitution
  local SCRIPT
  for SCRIPT in "$REPO_ROOT"/*.sh; do
    [ -f "$SCRIPT" ] || continue

    local OFFENDING_LINES
    OFFENDING_LINES=$(grep -nE '\$\([^(].*\$\([^(]' "$SCRIPT" || true)
    assert_empty "$OFFENDING_LINES" \
      "${SCRIPT#$REPO_ROOT/} expands two command substitutions in one statement"
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
    "$REPO_ROOT/Dell_iDRAC_fan_controller.sh" "$REPO_ROOT/healthcheck.sh" "$REPO_ROOT/supervisor.sh" |
    awk '{print $2}' | sort -u)
}

function test_the_docker_images_entrypoint_is_shipped_in_it() {
  # The entrypoint is the one file whose absence makes the image start nothing at
  # all, and it is the only script not reached by the "sourced at runtime" scan
  # above : nothing sources it, the container execs it
  if [ ! -f "$REPO_ROOT/Dockerfile" ]; then
    skip_test "no Dockerfile next to the scripts"
    return 0
  fi

  local -r DOCKERFILE_CONTENT=$(cat "$REPO_ROOT/Dockerfile")
  local -r ENTRYPOINT_SCRIPT=$(grep -oE '^ENTRYPOINT \["\./[A-Za-z0-9_.-]+\.sh"' "$REPO_ROOT/Dockerfile" |
    grep -oE '[A-Za-z0-9_.-]+\.sh')

  assert_not_empty "$ENTRYPOINT_SCRIPT" "the Dockerfile must declare a script as its ENTRYPOINT" || return 1

  if [ -f "$REPO_ROOT/$ENTRYPOINT_SCRIPT" ]; then
    pass
  else
    fail "$ENTRYPOINT_SCRIPT is the image's ENTRYPOINT but does not exist"
  fi

  assert_matches "$DOCKERFILE_CONTENT" "(ADD|COPY) $ENTRYPOINT_SCRIPT " \
    "$ENTRYPOINT_SCRIPT is the image's ENTRYPOINT, the Dockerfile must copy it into the image"
  assert_matches "$DOCKERFILE_CONTENT" "chmod [0-7]+ .*/$ENTRYPOINT_SCRIPT" \
    "$ENTRYPOINT_SCRIPT is exec'd by the container, the image must make it executable"
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

# The README states the default of every parameter, the Dockerfile declares the
# real one, and nothing compared the two : the documentation could tell the reader
# one thing while the container did another, with no test going red. That is the
# same drift the test case above guards one level down, where the harness kept
# CHECK_INTERVAL=60 after the image had dropped it to 5.
#
# The value is stated in several shapes -- "local", 5(%), 50(°C), false followed by
# a clause -- so it is normalised rather than matched literally : the wording is
# free to change, only a value that disagrees fails.
# Usage : documented_default_value "5(%)" -> "5"
function documented_default_value() {
  local VALUE="$1"
  # Keep what precedes the first comma : some defaults are followed by a clause
  VALUE="${VALUE%%,*}"
  # Drop a trailing unit in parentheses : "5(%)", "50(°C)", "5(s)"
  VALUE="${VALUE%%(*}"
  # Drop the quotes and backticks the prose wraps some values in
  VALUE="${VALUE//[\"\`]/}"
  # Trim
  VALUE="${VALUE#"${VALUE%%[![:space:]]*}"}"
  VALUE="${VALUE%"${VALUE##*[![:space:]]}"}"
  printf '%s' "$VALUE"
}

function test_the_readme_documents_the_defaults_the_image_actually_ships() {
  if [ ! -f "$REPO_ROOT/Dockerfile" ] || [ ! -f "$REPO_ROOT/README.md" ]; then
    # The suite is running inside the built image, which carries neither
    skip_test "no Dockerfile and README next to the scripts"
    return 0
  fi

  local -r README_CONTENT=$(cat "$REPO_ROOT/README.md")

  local ENV_DECLARATION KEY DOCKERFILE_VALUE DOCUMENTED_SENTENCE
  while IFS= read -r ENV_DECLARATION; do
    KEY="${ENV_DECLARATION%%=*}"
    DOCKERFILE_VALUE="${ENV_DECLARATION#*=}"

    DOCUMENTED_SENTENCE=$(printf '%s' "$README_CONTENT" |
      grep -oE '`'"$KEY"'`[^*]*\*\*Default\*\* value is [^.]*' | head -1)

    if [ -z "$DOCUMENTED_SENTENCE" ]; then
      fail "$KEY is shipped by the Dockerfile but the README states no default for it"
      continue
    fi

    assert_equals "$DOCKERFILE_VALUE" \
      "$(documented_default_value "${DOCUMENTED_SENTENCE##*value is }")" \
      "the README's default for $KEY should be the one the Dockerfile ships"
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

function test_the_usage_examples_offer_every_parameter_the_image_declares() {
  # The README's "Usage" section is the first thing a user copies, well before the
  # "Parameters" list below it or the .env.example beside it. A parameter missing
  # from those four blocks is one most users never learn exists : the two guards
  # above watch .env.example and the documented defaults, and CPU_TEMPERATURE_SOURCE
  # still shipped documented everywhere except in the commands people actually run.
  # This is the guard against that drift
  if [ ! -f "$REPO_ROOT/Dockerfile" ] || [ ! -f "$REPO_ROOT/README.md" ]; then
    # The suite is running inside the built image, which carries neither
    skip_test "no Dockerfile and README next to the scripts"
    return 0
  fi

  # The configuration examples are the fenced blocks of the "Usage" section that
  # set IDRAC_HOST : the two "docker run" ones and the two docker-compose ones.
  # Found by what they contain rather than by their position, so that reordering
  # them, or adding a fifth, needs no change here
  local -r USAGE_SECTION=$(awk '/^## Usage$/ {inside = 1; next} /^## / {inside = 0} inside' "$REPO_ROOT/README.md")

  local -a USAGE_EXAMPLES=()
  local BLOCK="" IS_INSIDE_BLOCK=false LINE
  while IFS= read -r LINE; do
    if [[ "$LINE" == '```'* ]]; then
      if $IS_INSIDE_BLOCK; then
        [[ "$BLOCK" == *IDRAC_HOST* ]] && USAGE_EXAMPLES+=("$BLOCK")
        BLOCK=""
      fi
      $IS_INSIDE_BLOCK && IS_INSIDE_BLOCK=false || IS_INSIDE_BLOCK=true
      continue
    fi
    $IS_INSIDE_BLOCK && BLOCK+="$LINE"$'\n'
  done < <(printf '%s\n' "$USAGE_SECTION")

  # Without this the loop below would pass by having nothing to iterate over,
  # which is the failure mode these guards exist to prevent in the first place
  if (( ${#USAGE_EXAMPLES[@]} < 4 )); then
    fail "only ${#USAGE_EXAMPLES[@]} usage examples were found in the README, expected at least 4"
    return 1
  fi

  local KEY EXAMPLE EXAMPLE_NUMBER
  while IFS= read -r KEY; do
    EXAMPLE_NUMBER=1
    for EXAMPLE in "${USAGE_EXAMPLES[@]}"; do
      assert_contains "$EXAMPLE" "$KEY" \
        "$KEY is declared by the Dockerfile, usage example $EXAMPLE_NUMBER should show users how to set it"
      ((EXAMPLE_NUMBER++))
    done
  done < <(grep -E '^ENV [A-Z_]+=' "$REPO_ROOT/Dockerfile" | sed 's/^ENV //' | cut -d= -f1)
}

function test_the_env_example_offers_every_parameter_the_readme_documents() {
  # The test above can only see what the Dockerfile declares, and the Dockerfile
  # declares no ENV for IDRAC_USERNAME and IDRAC_PASSWORD : they are credentials,
  # they have no default to ship. So the two parameters .env.example exists for
  # in the first place are precisely the two its guard does not cover. Dropping
  # either of them from the file leaves the whole suite green.
  # The README's own parameter bullets are the list that does include them
  if [ ! -f "$REPO_ROOT/README.md" ] || [ ! -f "$REPO_ROOT/.env.example" ]; then
    # The suite is running inside the built image, which carries neither the
    # README (excluded by .dockerignore) nor the example file shipped beside it
    skip_test "no README and .env.example next to the scripts"
    return 0
  fi

  # Space padded on both ends so a key can be matched whole, as above
  local ENV_EXAMPLE_KEYS=" "
  local LINE
  while IFS= read -r LINE; do
    ENV_EXAMPLE_KEYS+="${LINE%%=*} "
  done < <(grep -E '^[A-Z_]+=' "$REPO_ROOT/.env.example")

  local KEY
  while IFS= read -r KEY; do
    assert_contains "$ENV_EXAMPLE_KEYS" " $KEY " \
      "$KEY is documented in the README, .env.example should show users how to set it"
  done < <(grep -oE '^- `[A-Z_]+`' "$REPO_ROOT/README.md" | tr -d '`' | sed 's/^- //')
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

function test_no_boolean_parameter_is_dispatched_unquoted() {
  # The boolean parameters are dispatched by running their value as a command
  # ("if $MONITORING_ONLY_MODE"). validate_boolean_parameter() is what makes that
  # idiom safe, and the call sites deliberately keep it rather than being
  # rewritten -- so the invariant it rests on has to hold at every one of them.
  #
  # Quoting is the part that stops a value carrying arguments from running with
  # them, should any dispatch ever be reached before the validation: a new
  # parameter, the validation block moving, or a value reassigned mid-run. #166
  # measured what that costs (MONITORING_ONLY_MODE=yes runs /usr/bin/yes, fills
  # the log at hundreds of MB/s and defers the graceful_exit trap so that
  # docker stop cannot end the container).
  #
  # It drifted once already: #166 asked for the quoting, #217 delivered the
  # validation and 8 of the 9 quotes, and the 9th was only caught later (#245).
  local -r BOOLEAN_PARAMETERS='MONITORING_ONLY_MODE|DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE|KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT'
  local SCRIPT UNQUOTED
  for SCRIPT in "$REPO_ROOT"/*.sh; do
    [ -f "$SCRIPT" ] || continue

    # Comments quote the idiom while explaining it, so they are skipped
    UNQUOTED=$(grep -nE "^[^#]*\bif !? ?\\\$($BOOLEAN_PARAMETERS)\b" "$SCRIPT" || true)
    if [ -z "$UNQUOTED" ]; then
      pass
    else
      fail "${SCRIPT#$REPO_ROOT/} dispatches a boolean parameter unquoted" "$UNQUOTED"
    fi
  done
}
