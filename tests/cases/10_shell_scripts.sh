#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# Checks on the scripts themselves, before any behavior is exercised : a syntax
# error or a file missing from the Docker image breaks every server at once,
# whatever its generation.

function test_every_shell_script_has_a_valid_syntax() {
  local SCRIPT
  for SCRIPT in \
    "$REPO_ROOT"/*.sh \
    "$REPO_ROOT"/.github/*.sh \
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

function test_the_shellcheck_workflow_lints_every_script_it_is_scoped_to() {
  local -r SHELLCHECK_WORKFLOW="$REPO_ROOT/.github/workflows/shellcheck.yml"

  if [ ! -f "$SHELLCHECK_WORKFLOW" ]; then
    # The suite is running inside the built image, which does not carry the
    # workflows that built it
    skip_test "no .github/workflows next to the scripts"
    return 0
  fi

  # That workflow names its scripts one by one rather than globbing them, which
  # is what lets it leave the tests/ tree out - and what let two scripts added
  # to .github/ afterwards stay out of it for months without a word. The list is
  # hand-maintained, so it is worth a guard : nothing else lints these files.
  # "bash -n" above is a syntax check and the suite invokes shellcheck nowhere,
  # so a script missing from that list is analysed by nothing at all. The ones
  # under .github/ run first on the tag or the push that publishes -- the suite
  # does execute all three, in cases 13, 14 and 16, but never on the path a
  # release takes. The hook under .claude/ has neither : it runs when a Claude
  # Code on the web session opens, where no workflow and no test ever looks.
  #
  # Walked over all of .claude/ rather than the one directory a script lives in
  # today, because that is the scope the convention in CLAUDE.md states
  local -r LINTED_SCRIPTS="$(sed -n 's/^ *\([A-Za-z0-9_./-]*\.sh\) *\\\{0,1\}$/\1/p' "$SHELLCHECK_WORKFLOW")"

  shopt -s globstar
  local SCRIPT RELATIVE_PATH
  for SCRIPT in "$REPO_ROOT"/*.sh "$REPO_ROOT"/.github/*.sh "$REPO_ROOT"/.claude/**/*.sh; do
    [ -f "$SCRIPT" ] || continue

    RELATIVE_PATH="${SCRIPT#$REPO_ROOT/}"
    if printf '%s\n' "$LINTED_SCRIPTS" | grep -qxF "$RELATIVE_PATH"; then
      pass
    else
      fail "$RELATIVE_PATH is linted by nothing, the Shellcheck workflow does not name it" \
        "it checks : $(printf '%s' "$LINTED_SCRIPTS" | tr '\n' ' ')"
    fi
  done

  shopt -u globstar
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

function test_the_readme_states_the_deadline_the_supervisor_actually_waits() {
  # The README tells users to keep Docker's stop timeout above the supervisor's
  # grace period, and states that period as a number. Nothing else in the project
  # would notice the two disagreeing, and the consequence of the README being
  # short is the one the supervisor exists to prevent : a container SIGKILLed
  # while it was still about to hand the fans back
  if [ ! -f "$REPO_ROOT/README.md" ]; then
    # The suite is running inside the built image, which does not carry the
    # README (excluded by .dockerignore)
    skip_test "no README next to the scripts"
    return 0
  fi

  assert_not_empty "$SUPERVISOR_GRACE_PERIOD_IN_SECONDS" \
    "constants.sh should define the supervisor's grace period" || return 1

  assert_matches "$(cat "$REPO_ROOT/README.md")" \
    "\*\*$SUPERVISOR_GRACE_PERIOD_IN_SECONDS seconds\*\*" \
    "the README should state the ${SUPERVISOR_GRACE_PERIOD_IN_SECONDS}s the supervisor really waits"
  assert_matches "$(cat "$REPO_ROOT/README.md")" \
    "above $SUPERVISOR_GRACE_PERIOD_IN_SECONDS seconds" \
    "and ask for a stop timeout above that same value"
}

function test_the_readme_documents_the_plausible_temperature_threshold_window() {
  # The window is what the container refuses to start outside of, and until issue
  # #326 it was written down nowhere : the README described the parameter as "a
  # decimal number of degrees Celsius" with no bound, .env.example said nothing
  # either, and a user who had set 160 discovered the range from a container that
  # would not start. A refusal a document does not prepare the reader for is the
  # one they cannot act on, so the two are held together here rather than left to
  # agree by hand
  if [ ! -f "$REPO_ROOT/README.md" ] || [ ! -f "$REPO_ROOT/.env.example" ]; then
    # The suite is running inside the built image, which carries neither the
    # README (excluded by .dockerignore) nor the example file shipped beside it
    skip_test "no README and .env.example next to the scripts"
    return 0
  fi

  assert_not_empty "$MINIMUM_PLAUSIBLE_CPU_TEMPERATURE_THRESHOLD" \
    "constants.sh should define the bottom of the plausible window" || return 1
  assert_not_empty "$MAXIMUM_PLAUSIBLE_CPU_TEMPERATURE_THRESHOLD" \
    "constants.sh should define the top of the plausible window" || return 1

  local -r README_CONTENT=$(cat "$REPO_ROOT/README.md")

  assert_matches "$README_CONTENT" \
    "\*\*between $MINIMUM_PLAUSIBLE_CPU_TEMPERATURE_THRESHOLD°C and $MAXIMUM_PLAUSIBLE_CPU_TEMPERATURE_THRESHOLD°C\*\*" \
    "the README should state the window the container really enforces"

  # The placeholders are what a user copies into a "docker run" or a compose file,
  # well before reading the bullet that explains them. They carry the unit as well
  # as the range : a placeholder that names neither is how "160" gets typed as a
  # Fahrenheit figure into a parameter whose bullet says Celsius three sections away
  local -r PLACEHOLDER="in °C, from $MINIMUM_PLAUSIBLE_CPU_TEMPERATURE_THRESHOLD to $MAXIMUM_PLAUSIBLE_CPU_TEMPERATURE_THRESHOLD"
  assert_contains "$README_CONTENT" "$PLACEHOLDER" \
    "the README's CPU_TEMPERATURE_THRESHOLD placeholders should carry the unit and the range"
  assert_contains "$(cat "$REPO_ROOT/.env.example")" "$PLACEHOLDER" \
    ".env.example should carry the same unit and range, being the other file users copy from"
}

function test_the_readme_documents_the_fan_speed_range() {
  # The range validate_fan_speed_parameter() enforces was stated in exactly one
  # sentence of the README -- which spelled it "hexadecimaladecimal" -- and in
  # none of the six placeholders a user copies into a "docker run", a compose file
  # or a .env. A bound met for the first time as a container refusing to start is
  # the defect #326 was about; this is the same one, one parameter over (#328)
  if [ ! -f "$REPO_ROOT/README.md" ] || [ ! -f "$REPO_ROOT/.env.example" ]; then
    # The suite is running inside the built image, which carries neither the
    # README (excluded by .dockerignore) nor the example file shipped beside it
    skip_test "no README and .env.example next to the scripts"
    return 0
  fi

  assert_not_empty "$MINIMUM_FAN_SPEED_PERCENTAGE" \
    "constants.sh should define the bottom of the fan speed range" || return 1
  assert_not_empty "$MAXIMUM_FAN_SPEED_PERCENTAGE" \
    "constants.sh should define the top of the fan speed range" || return 1

  # Derived rather than written out, so that the documentation is held to the same
  # bound in both notations. One substitution per statement, as everywhere else
  local -r MINIMUM_HEXADECIMAL_FAN_SPEED=$(convert_decimal_value_to_hexadecimal "$MINIMUM_FAN_SPEED_PERCENTAGE")
  local -r MAXIMUM_HEXADECIMAL_FAN_SPEED=$(convert_decimal_value_to_hexadecimal "$MAXIMUM_FAN_SPEED_PERCENTAGE")

  local -r README_CONTENT=$(cat "$REPO_ROOT/README.md")

  # The parameter's own bullet, matched with its parentheses so that the assertion
  # cannot be satisfied by the placeholders further up the file
  assert_contains "$README_CONTENT" \
    "(from $MINIMUM_FAN_SPEED_PERCENTAGE to $MAXIMUM_FAN_SPEED_PERCENTAGE%)" \
    "the README's FAN_SPEED bullet should state the percentage range the validator enforces"
  assert_contains "$README_CONTENT" \
    "(from $MINIMUM_HEXADECIMAL_FAN_SPEED to $MAXIMUM_HEXADECIMAL_FAN_SPEED)" \
    "and the same bound in the hexadecimal notation it also accepts"

  # The placeholders, which is where a user meets the parameter first : they carry
  # the unit as well, "%" being what says 5 is a duty cycle rather than a speed
  local -r PLACEHOLDER="in %, from $MINIMUM_FAN_SPEED_PERCENTAGE to $MAXIMUM_FAN_SPEED_PERCENTAGE, or hexadecimal from $MINIMUM_HEXADECIMAL_FAN_SPEED to $MAXIMUM_HEXADECIMAL_FAN_SPEED"
  assert_contains "$README_CONTENT" "$PLACEHOLDER" \
    "the README's FAN_SPEED placeholders should carry the unit and both ranges"
  assert_contains "$(cat "$REPO_ROOT/.env.example")" "$PLACEHOLDER" \
    ".env.example should carry the same, being the other file users copy from"
}

function test_the_readme_documents_the_check_interval_bounds() {
  # The fourth number of this kind, and the one that was left unguarded : the
  # supervisor's grace period, the temperature window and the fan speed range are
  # all held to their constants, this one never was. It is also the only one the
  # README states in another unit than the constant carries -- "15 minutes" against
  # a MAXIMUM_CHECK_INTERVAL_IN_SECONDS of 900 -- so lowering that constant leaves
  # the suite green, the refusal saying one number and the documentation another,
  # and the user planning around whichever they read first (#330)
  if [ ! -f "$REPO_ROOT/README.md" ] || [ ! -f "$REPO_ROOT/.env.example" ]; then
    # The suite is running inside the built image, which carries neither the
    # README (excluded by .dockerignore) nor the example file shipped beside it
    skip_test "no README and .env.example next to the scripts"
    return 0
  fi

  assert_not_empty "$CHECK_INTERVAL_WARNING_THRESHOLD_IN_SECONDS" \
    "constants.sh should define the interval a warning starts above" || return 1
  assert_not_empty "$MAXIMUM_CHECK_INTERVAL_IN_SECONDS" \
    "constants.sh should define the interval the container refuses above" || return 1

  # The conversion the refusal itself performs, done here rather than written out,
  # so that the two cannot end up disagreeing about what 900 seconds are
  local -r MAXIMUM_IN_MINUTES=$((MAXIMUM_CHECK_INTERVAL_IN_SECONDS / 60))

  local -r README_CONTENT=$(cat "$REPO_ROOT/README.md")

  assert_matches "$README_CONTENT" \
    "\*\*$CHECK_INTERVAL_WARNING_THRESHOLD_IN_SECONDS seconds\*\*" \
    "the README should state the interval the container really starts warning above"
  assert_matches "$README_CONTENT" \
    "\*\*$MAXIMUM_IN_MINUTES minutes\*\*" \
    "and the one it really refuses above, in the unit it is written in there"

  # The placeholders, where a user meets the parameter before any of that prose :
  # they carried neither the ceiling nor the fact that a suffix is accepted at all
  local -r PLACEHOLDER="up to $MAXIMUM_IN_MINUTES minutes"
  assert_contains "$README_CONTENT" "$PLACEHOLDER" \
    "the README's CHECK_INTERVAL placeholders should carry the ceiling"
  assert_contains "$(cat "$REPO_ROOT/.env.example")" "$PLACEHOLDER" \
    ".env.example should carry the same, being the other file users copy from"
}

function test_the_documented_unreachable_duration_spelling_is_one_the_validator_takes() {
  # This parameter's placeholders said "how long" and stopped there -- the only one
  # of the four naming no unit at all -- so nothing told a user filling the file in
  # that 5 is five seconds. They now name it, and show a suffixed spelling, which
  # is worth holding to the grammar that really accepts it : a documented example
  # the validator would refuse is worse than no example (#332)
  if [ ! -f "$REPO_ROOT/README.md" ] || [ ! -f "$REPO_ROOT/.env.example" ]; then
    # The suite is running inside the built image, which carries neither the
    # README (excluded by .dockerignore) nor the example file shipped beside it
    skip_test "no README and .env.example next to the scripts"
    return 0
  fi

  local -r DOCUMENTED_SPELLING="5m"
  local -r PLACEHOLDER="in seconds or suffixed like $DOCUMENTED_SPELLING"

  assert_contains "$(cat "$REPO_ROOT/README.md")" "$PLACEHOLDER" \
    "the README's MAXIMUM_IPMI_UNREACHABLE_DURATION placeholders should name the unit"
  assert_contains "$(cat "$REPO_ROOT/.env.example")" "$PLACEHOLDER" \
    ".env.example should name it too, being the other file users copy from"

  # The validator answers by stopping the controller, so the call has to happen in
  # the subshell a command substitution creates
  local OUTPUT
  OUTPUT=$(validate_IPMI_unreachable_duration_parameter "MAXIMUM_IPMI_UNREACHABLE_DURATION" "$DOCUMENTED_SPELLING" 2>&1)
  local -r EXIT_CODE=$?

  assert_equals 0 "$EXIT_CODE" \
    "[$DOCUMENTED_SPELLING] is the spelling the documentation shows, so the validator has to take it"
  assert_empty "$OUTPUT" "and take it without a word"
}

function test_the_documented_consecutive_failures_minimum_is_the_one_enforced() {
  # The last placeholder of the family that stated its unit but not its refusal :
  # 0 is refused, and 0 is what somebody writes to mean "do not escalate" -- the
  # way to do that being an empty value. Held to the validator rather than to a
  # constant, the minimum of one being structural : nothing can be concluded from
  # fewer than one observed failure, so there is no number here that could drift
  if [ ! -f "$REPO_ROOT/README.md" ] || [ ! -f "$REPO_ROOT/.env.example" ]; then
    # The suite is running inside the built image, which carries neither the
    # README (excluded by .dockerignore) nor the example file shipped beside it
    skip_test "no README and .env.example next to the scripts"
    return 0
  fi

  local -r DOCUMENTED_MINIMUM="1 or more"

  assert_contains "$(cat "$REPO_ROOT/README.md")" "$DOCUMENTED_MINIMUM" \
    "the README's MAXIMUM_CONSECUTIVE_IPMI_FAILURES placeholders should state the minimum"
  assert_contains "$(cat "$REPO_ROOT/.env.example")" "$DOCUMENTED_MINIMUM" \
    ".env.example should state it too, being the other file users copy from"

  # The validator answers by stopping the controller, so the calls have to happen
  # in the subshell a command substitution creates
  local OUTPUT
  OUTPUT=$(validate_maximum_consecutive_IPMI_failures_parameter "MAXIMUM_CONSECUTIVE_IPMI_FAILURES" "1" 2>&1)
  local -r ACCEPTED_EXIT_CODE=$?
  assert_equals 0 "$ACCEPTED_EXIT_CODE" "1 is the documented minimum, so the validator has to take it"

  OUTPUT=$(validate_maximum_consecutive_IPMI_failures_parameter "MAXIMUM_CONSECUTIVE_IPMI_FAILURES" "0" 2>&1)
  local -r REFUSED_EXIT_CODE=$?
  assert_equals 1 "$REFUSED_EXIT_CODE" "and refuse what the documentation says is below it"
  assert_contains "$OUTPUT" "leave this parameter empty" \
    "0 is what somebody writes to disable the escalation, so the refusal has to name what really does"
}

function test_the_suites_own_readme_lists_every_case_file() {
  # The three guards above watch the documentation the users read. This one
  # watches the documentation the contributors read : tests/README.md holds a
  # "What is covered" table with one row per case file, and it is what somebody
  # adding a test consults to decide where the test goes.
  #
  # Nothing compared the table with the directory, so it silently fell three
  # files behind -- and a coverage table that omits a file is worse than no
  # table, since it reads as "this is everything" while it is not. The runner
  # discovers case files on its own, so an unlisted file still runs : the drift
  # is invisible until somebody notices the table is short
  if [ ! -f "$TESTS_DIRECTORY/README.md" ]; then
    skip_test "no README next to the test cases"
    return 0
  fi

  # Space padded on both ends so a file name can be matched whole
  local LISTED_FILES=" "
  local LINE
  while IFS= read -r LINE; do
    LISTED_FILES+="$LINE "
  done < <(grep -oE 'cases/[0-9A-Za-z_]+\.sh' "$TESTS_DIRECTORY/README.md" | sort -u)

  local CASE_FILE
  for CASE_FILE in "$TESTS_DIRECTORY"/cases/*.sh; do
    [ -f "$CASE_FILE" ] || continue

    assert_contains "$LISTED_FILES" " cases/$(basename "$CASE_FILE") " \
      "cases/$(basename "$CASE_FILE") runs in every suite, the README's coverage table should say what it checks"
  done

  local LISTED_FILE
  for LISTED_FILE in $LISTED_FILES; do
    if [ -f "$TESTS_DIRECTORY/$LISTED_FILE" ]; then
      pass
    else
      fail "the README's coverage table lists $LISTED_FILE, which does not exist"
    fi
  done
}

# The cases below guard CLAUDE.md, the file a Claude Code session reads before it
# touches anything here. Documentation that has fallen behind is a stale
# paragraph everywhere else in this repository ; there it is an instruction, and
# a session acts on it. A renamed script, or a lint command that no longer covers
# what the pull request will be judged on, makes the session confidently wrong
# and leaves the human to catch it in review (issue #381).
#
# What is pinned is what a machine can settle : the paths, the two lists that are
# maintained in two places, the options, the one figure. The "Invariants" section
# is prose about why a decision was taken and is deliberately left alone -- a test
# over it would either be satisfied by a keyword or break on any rewording, and
# neither would say anything about whether it is still true.

function test_claude_md_carries_the_licence_header() {
  # NOTICE names the SPDX headers as part of what discharges AGPL 5(a) and 7(b),
  # and the workflows were brought under the same rule by #368. This file is
  # prose rather than a program, so it carries them in an HTML comment : nothing
  # shows where the document is rendered, and the two lines are still where a
  # reader and a licence scanner look for them
  if [ ! -f "$REPO_ROOT/CLAUDE.md" ]; then
    # The suite is running inside the built image, which carries the scripts and
    # not what documents them
    skip_test "no CLAUDE.md next to the scripts"
    return 0
  fi

  local -r HEADER=$(head -4 "$REPO_ROOT/CLAUDE.md")

  assert_contains "$HEADER" "SPDX-FileCopyrightText: 2020-2026 Tigerblue77" \
    "CLAUDE.md should open with the copyright line every other file here carries"
  assert_contains "$HEADER" "SPDX-License-Identifier: AGPL-3.0-only" \
    "CLAUDE.md should open with the licence line every other file here carries"
}

function test_the_lint_command_claude_md_documents_is_the_one_the_workflow_runs() {
  local -r SHELLCHECK_WORKFLOW="$REPO_ROOT/.github/workflows/shellcheck.yml"

  if [ ! -f "$REPO_ROOT/CLAUDE.md" ] || [ ! -f "$SHELLCHECK_WORKFLOW" ]; then
    skip_test "no CLAUDE.md and no .github/workflows next to the scripts"
    return 0
  fi

  # CLAUDE.md prints a shellcheck invocation under "Commands" and calls it what
  # CI lints, so a session that runs it before pushing believes it has seen
  # everything the pull request will be judged on. The workflow names its files
  # one by one for the reasons the case above gives, which leaves the same list
  # written down twice -- and the copy in CLAUDE.md is the one nothing runs.
  #
  # It is compared against the workflow rather than against the tree because
  # being wrong about what CI checks is what makes a session push a file that
  # nothing linted. The command is read the way a shell reads it : continuations
  # joined, the trailing comment dropped, globs expanded from the repository
  # root. What matters is the set of files it ends up handing shellcheck, not how
  # it spells them
  local -r DOCUMENTED_COMMAND=$(awk '
    /^shellcheck -x/ { IS_THE_COMMAND = 1 }
    IS_THE_COMMAND {
      sub(/#.*$/, "")
      CONTINUES = ($0 ~ /\\[[:space:]]*$/)
      sub(/\\[[:space:]]*$/, "")
      printf "%s ", $0
      if (!CONTINUES) { exit }
    }' "$REPO_ROOT/CLAUDE.md")

  assert_not_empty "$DOCUMENTED_COMMAND" \
    "CLAUDE.md should still print the shellcheck invocation it calls what CI lints" || return 1

  # Each test case runs in its own subshell, so the working directory the globs
  # are resolved from is this case's own
  cd "$REPO_ROOT" || return 1
  shopt -s nullglob
  local -a DOCUMENTED_SCRIPTS=(${DOCUMENTED_COMMAND#shellcheck -x })
  shopt -u nullglob

  local -r LINTED_SCRIPTS=$(sed -n 's/^ *\([A-Za-z0-9_./-]*\.sh\) *\\\{0,1\}$/\1/p' "$SHELLCHECK_WORKFLOW")

  local DOCUMENTED_SCRIPT
  for DOCUMENTED_SCRIPT in "${DOCUMENTED_SCRIPTS[@]}"; do
    if printf '%s\n' "$LINTED_SCRIPTS" | grep -qxF "$DOCUMENTED_SCRIPT"; then
      pass
    else
      fail "CLAUDE.md has a session lint $DOCUMENTED_SCRIPT, which the Shellcheck workflow does not" \
        "the workflow lints : $(printf '%s' "$LINTED_SCRIPTS" | tr '\n' ' ')"
    fi
  done

  local LINTED_SCRIPT
  while IFS= read -r LINTED_SCRIPT; do
    [ -n "$LINTED_SCRIPT" ] || continue

    if printf '%s\n' "${DOCUMENTED_SCRIPTS[@]}" | grep -qxF "$LINTED_SCRIPT"; then
      pass
    else
      fail "the Shellcheck workflow lints $LINTED_SCRIPT, which the command in CLAUDE.md leaves out" \
        "that command covers : ${DOCUMENTED_SCRIPTS[*]}"
    fi
  done <<< "$LINTED_SCRIPTS"
}

function test_the_claude_md_layout_table_names_every_script_at_the_repository_root() {
  if [ ! -f "$REPO_ROOT/CLAUDE.md" ]; then
    skip_test "no CLAUDE.md next to the scripts"
    return 0
  fi

  # "Layout" is a table of one row per file, and it is where a session decides
  # which file to open. A script it does not name is one the session does not
  # know exists, so the table reads as the whole of the program while it is not
  # -- the failure tests/README.md's own coverage table had, three files behind
  # and still reading as complete.
  #
  # Read down the first column rather than over the section, because the section
  # also holds the sentence naming the three scripts that source the other two :
  # matched against the prose, this case stays green with the table emptied row
  # by row. The other direction, a row naming a file that has been renamed away,
  # is the case below, over the whole document rather than this table alone
  local -r TABLE_FILE_COLUMN=$(awk -F '|' '
    /^## Layout$/ { IS_THE_LAYOUT = 1; next }
    /^## / { IS_THE_LAYOUT = 0 }
    IS_THE_LAYOUT && /^\|/ { print $2 }' "$REPO_ROOT/CLAUDE.md")

  assert_not_empty "$TABLE_FILE_COLUMN" "CLAUDE.md should still carry a \"Layout\" table" || return 1

  local SCRIPT RELATIVE_PATH
  for SCRIPT in "$REPO_ROOT"/*.sh; do
    [ -f "$SCRIPT" ] || continue

    RELATIVE_PATH="${SCRIPT#"$REPO_ROOT"/}"
    assert_contains "$TABLE_FILE_COLUMN" "\`$RELATIVE_PATH\`" \
      "$RELATIVE_PATH ships in the image, the Layout table should have a row saying what it holds"
  done
}

function test_every_repository_path_claude_md_names_exists() {
  if [ ! -f "$REPO_ROOT/CLAUDE.md" ]; then
    skip_test "no CLAUDE.md next to the scripts"
    return 0
  fi

  # Every path the document quotes, against the tree. A rename that leaves it
  # behind is the realistic failure here, and the document is almost entirely
  # made of them : the file table, the two case files named as the guards a
  # contributor is told to respect, the fixtures and the mock a new test is told
  # to build on, the catalogue the server models come from, the hook that
  # installs shellcheck. Sent to a path that no longer exists, a session either
  # invents a replacement or reports the repository as broken.
  #
  # Only the quoted tokens shaped like a path are kept -- a slash, one of the
  # extensions used here, or a leading dot -- so that the function names, the
  # variables and the environment variables quoted the same way stay out. Fenced
  # blocks are dropped first : they are shell rather than prose, and the words in
  # them are commands
  local -r NAMED_PATHS=$(awk '/^```/ { IS_FENCED = !IS_FENCED; next } !IS_FENCED' "$REPO_ROOT/CLAUDE.md" |
    grep -oE '`[^`]+`' | tr -d '`' |
    grep -E '^[A-Za-z0-9_.*/-]+$' | grep -E '(/|\.sh$|\.md$|\.yml$|^\.)' | sort -u)

  assert_not_empty "$NAMED_PATHS" "CLAUDE.md should still name the files it sends a session to" || return 1

  cd "$REPO_ROOT" || return 1
  shopt -s nullglob

  local NAMED_PATH
  local -a MATCHES
  while IFS= read -r NAMED_PATH; do
    [ -n "$NAMED_PATH" ] || continue

    # A pattern where the document quotes one, a name where it quotes a name.
    # Both are checked through the same expansion, and both halves are needed :
    # nullglob drops a pattern nothing answers, and leaves a word carrying no
    # pattern character at all exactly as it was written, existing or not
    MATCHES=($NAMED_PATH)
    if [ "${#MATCHES[@]}" -gt 0 ] && [ -e "${MATCHES[0]}" ]; then
      pass
    else
      fail "CLAUDE.md sends a session to $NAMED_PATH, which is not in the repository"
    fi
  done <<< "$NAMED_PATHS"

  shopt -u nullglob
}

function test_the_runner_options_claude_md_documents_are_ones_the_runner_accepts() {
  if [ ! -f "$REPO_ROOT/CLAUDE.md" ]; then
    skip_test "no CLAUDE.md next to the scripts"
    return 0
  fi

  # The runner prints its options from a single cat block, so its help is the
  # list of what it takes. An option CLAUDE.md documents and the runner no longer
  # accepts sends the session into a usage error on the first command it was told
  # to run, at the moment it is trying to find out whether the tree is sound
  #
  # Read out of the fenced blocks alone, because that is where the document runs
  # a command : in prose it quotes them, and a quoted option next to the runner's
  # name is a reference rather than an invocation. Sentence "`./tests/run_tests.sh`
  # exactly, then `shellcheck` and `bash -n`" cost this case a false failure over
  # a -n the runner was never asked for
  local -r RUNNER_HELP=$(bash "$TESTS_DIRECTORY/run_tests.sh" --help 2>&1)

  assert_not_empty "$RUNNER_HELP" "the runner should still print what it takes" || return 1

  local DOCUMENTED_OPTION
  while IFS= read -r DOCUMENTED_OPTION; do
    [ -n "$DOCUMENTED_OPTION" ] || continue

    assert_matches "$RUNNER_HELP" "(^|[[:space:],])$DOCUMENTED_OPTION([[:space:],]|$)" \
      "CLAUDE.md runs the suite with $DOCUMENTED_OPTION, the runner should still accept it"
  done < <(awk '/^```/ { IS_FENCED = !IS_FENCED; next } IS_FENCED' "$REPO_ROOT/CLAUDE.md" |
    grep -oE '(\./)?tests/run_tests\.sh[^#]*' |
    grep -oE ' -{1,2}[A-Za-z][A-Za-z-]*' | tr -d ' ' | sort -u)
}

function test_the_function_count_claude_md_states_is_the_one_functions_sh_declares() {
  if [ ! -f "$REPO_ROOT/CLAUDE.md" ]; then
    skip_test "no CLAUDE.md next to the scripts"
    return 0
  fi

  # The Layout table does not only name functions.sh, it counts what is in it,
  # and that is the one figure in the document. The README's figures are pinned
  # against the code above for the same reason -- the fan speed range, the check
  # interval bounds, the supervisor's deadline -- since a number nobody checks is
  # a number that stops being true without anybody noticing, and this one moves
  # every time a function is added.
  #
  # The figure is read out of the row rather than matched word for word, so that
  # rewording the cell does not fail here. Dropping the count is a legitimate way
  # to answer a failure of this case : a claim that is not made cannot drift
  local -r FUNCTIONS_ROW=$(grep -m 1 -F '| `functions.sh` |' "$REPO_ROOT/CLAUDE.md")

  assert_not_empty "$FUNCTIONS_ROW" "the Layout table should still have a row for functions.sh" || return 1

  local -r STATED_COUNT=$(printf '%s' "$FUNCTIONS_ROW" | grep -oE '[0-9]+' | head -1)
  if [ -z "$STATED_COUNT" ]; then
    pass
    return 0
  fi

  local -r DECLARED_COUNT=$(grep -c '^function ' "$REPO_ROOT/functions.sh")

  assert_equals "$DECLARED_COUNT" "$STATED_COUNT" \
    "CLAUDE.md counts the functions functions.sh holds, the count should be the number it declares"
}


function test_the_test_case_claude_md_documents_passes_when_it_is_run() {
  if [ ! -f "$REPO_ROOT/CLAUDE.md" ]; then
    skip_test "no CLAUDE.md next to the scripts"
    return 0
  fi

  # The cases above settle what the document says about the repository. This one
  # settles the single block it hands a session to copy, and copying is exactly
  # how that block failed : it asserted on a variable only the controller sets,
  # read the sdr output through one a case never has, and carried a name the
  # suite had already taken. None of the cases above would have caught any of it
  # -- a code block names no path, no option and no figure -- and the only
  # reading that settles an example is to run it.
  #
  # Both failure modes are pinned, because they land at different moments : the
  # name stops the runner before a single case runs, the body fails once one does
  local -r DOCUMENTED_CASE=$(awk '
    /^function test_/ { IS_THE_CASE = 1 }
    IS_THE_CASE { print }
    IS_THE_CASE && /^}/ { exit }' "$REPO_ROOT/CLAUDE.md")

  assert_matches "$DOCUMENTED_CASE" '^function test_[A-Za-z0-9_]+[[:space:]]*\(\)' \
    "CLAUDE.md should still show a test case under \"Writing a test case\"" || return 1

  # Discovery reads the case files as text and the runner refuses to start on a
  # name declared twice, so a name the suite already carries makes the example
  # unusable as written whatever its body does. Matched with the runner's own
  # expression rather than a tighter one, so that the two cannot disagree
  local -r DOCUMENTED_CASE_NAME=$(printf '%s' "$DOCUMENTED_CASE" | sed -n '1s/^function \([A-Za-z0-9_]*\).*/\1/p')
  local -r COLLIDING_FILES=$(grep -rlE "^[[:space:]]*(function[[:space:]]+)?$DOCUMENTED_CASE_NAME[[:space:]]*\(\)" "$TESTS_DIRECTORY/cases" || true)

  if [ -z "$COLLIDING_FILES" ]; then
    pass
  else
    fail "$DOCUMENTED_CASE_NAME is already declared in the suite, so pasting the example stops the runner" \
      "declared in : $(printf '%s' "$COLLIDING_FILES" | tr '\n' ' ')"
  fi

  # Then run it the way a session would : the real runner, on a repository of its
  # own holding that case and nothing else. The probe machinery belongs to
  # tests/cases/15_test_runner.sh, which is sourced into this same shell along
  # with every other case file, so it is reachable from here whatever the filter
  if ! declare -F run_the_runner_on_a_probe_case_file > /dev/null; then
    fail "the probe helper tests/cases/15_test_runner.sh declares is gone, so the example cannot be run"
    return 1
  fi

  run_the_runner_on_a_probe_case_file "$DOCUMENTED_CASE"

  if [ "$PROBE_EXIT_CODE" -eq 0 ]; then
    pass
  else
    fail "the test case CLAUDE.md documents does not pass when it is run" "$PROBE_OUTPUT"
  fi
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

function test_no_call_site_terminates_a_message_line_itself() {
  # print_error() and print_warning() close their own line (issue #169). A call
  # site adding a second terminator prints a blank line after the message, and --
  # worse -- hides the day the helpers lose their "\n" again : that one call site
  # would keep looking right while every other one fused with the line printed
  # next.
  #
  # This is not hypothetical, the trap caught three separate changes while #169
  # sat open, each patching the missing newline where it was noticed rather than
  # in the helper : validate_check_interval_parameter with a printf,
  # warn_if_unexpected_number_of_CPUs with an echo under a comment stating the
  # helper emitted none, and the supervisor with one printf per warning.
  local SCRIPT CALL_LINE_NUMBER TERMINATOR_LINE OFFENDERS
  for SCRIPT in "$REPO_ROOT"/*.sh; do
    [ -f "$SCRIPT" ] || continue

    OFFENDERS=""
    # The _and_exit variants are excluded by the trailing space : they close the
    # line and leave, so nothing of theirs can be terminated twice
    for CALL_LINE_NUMBER in $(grep -nE "^[[:space:]]*print_(error|warning) " "$SCRIPT" | cut -d: -f1); do
      TERMINATOR_LINE=$(sed -n "$((CALL_LINE_NUMBER + 1))p" "$SCRIPT")
      # A statement doing nothing but ending a line, whitespace removed so that
      # indentation and the two spellings both reduce to the same few strings
      case "$(printf '%s' "$TERMINATOR_LINE" | tr -d '[:space:]')" in
        'printf"\n"' | "printf'\n'" | 'echo""' | "echo''" | 'echo')
          OFFENDERS+="$((CALL_LINE_NUMBER + 1)):$TERMINATOR_LINE"$'\n' ;;
      esac
    done

    if [ -z "$OFFENDERS" ]; then
      pass
    else
      fail "${SCRIPT#$REPO_ROOT/} terminates a message line a second time" "$OFFENDERS"
    fi
  done
}
