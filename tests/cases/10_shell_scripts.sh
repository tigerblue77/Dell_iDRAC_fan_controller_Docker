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
      fail "${SCRIPT#"$REPO_ROOT"/} has a syntax error" "$SYNTAX_ERRORS"
    fi
  done
}

# The Shellcheck workflow runs two invocations : a hand-maintained list of the
# scripts nothing else would catch a mistake in, and a globbed pass over the
# tests/ tree beside it. The cases below are about the first, so they read the
# first step alone -- a glob line from the second would otherwise arrive in the
# list as a file somebody forgot to document (issue #432)
# Usage : scripts_the_shellcheck_workflow_names WORKFLOW -> one path per line
function scripts_the_shellcheck_workflow_names() {
  awk '/- name: Run shellcheck$/ { IS_THE_STEP = 1; next }
       IS_THE_STEP && /^ *- name:/ { exit }
       IS_THE_STEP' "$1" |
    sed -n 's/^ *\([A-Za-z0-9_./-]*\.sh\) *\\\{0,1\}$/\1/p'
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
  # Walked at any depth under .github/ and .claude/ rather than over the one
  # directory each holds a script in today, because that is the scope the
  # convention in CLAUDE.md states -- and a walk narrower than the sentence it
  # backs is a safety net that stays green while the sentence stops being true
  local -r LINTED_SCRIPTS="$(scripts_the_shellcheck_workflow_names "$SHELLCHECK_WORKFLOW")"

  shopt -s globstar
  local SCRIPT RELATIVE_PATH
  for SCRIPT in "$REPO_ROOT"/*.sh "$REPO_ROOT"/.github/**/*.sh "$REPO_ROOT"/.claude/**/*.sh; do
    [ -f "$SCRIPT" ] || continue

    RELATIVE_PATH="${SCRIPT#"$REPO_ROOT"/}"
    if printf '%s\n' "$LINTED_SCRIPTS" | grep -qxF "$RELATIVE_PATH"; then
      pass
    else
      fail "$RELATIVE_PATH is linted by nothing, the Shellcheck workflow does not name it" \
        "it checks : $(printf '%s' "$LINTED_SCRIPTS" | tr '\n' ' ')"
    fi
  done

  shopt -u globstar
}

# The second of the workflow's two invocations is globbed rather than named, so
# nothing has to remember a new case file. What a glob cannot do is say what it
# was meant to reach : "tests/case/*.sh" for "tests/cases/*.sh" expands to
# nothing, shellcheck is handed the files that remain, and the step stays green
# over a directory it stopped covering. Reading the patterns back and expanding
# them is what turns that into a failure (issue #432)
# Usage : shellcheck_patterns_of PATH "step name or command prefix" -> one per line
function shellcheck_patterns_of() {
  awk -v OPENING="$2" '
    !IS_THE_COMMAND { if (index($0, OPENING)) IS_THE_COMMAND = 1 ; next }
    {
      # Read the way a shell reads it : the trailing comment dropped, the
      # continuation dropped, the indentation the YAML block adds removed
      sub(/#.*$/, "")
      sub(/[[:space:]]*\\[[:space:]]*$/, "")
      sub(/^[[:space:]]+/, "")
      sub(/[[:space:]]+$/, "")
      if ($0 ~ /^tests\//) { IS_INSIDE = 1 ; print ; next }
      if (IS_INSIDE) exit
    }
  ' "$1"
}

function test_the_shellcheck_workflow_lints_every_file_of_the_test_suite() {
  local -r SHELLCHECK_WORKFLOW="$REPO_ROOT/.github/workflows/shellcheck.yml"

  if [ ! -f "$SHELLCHECK_WORKFLOW" ]; then
    skip_test "no .github/workflows next to the scripts"
    return 0
  fi

  local -r WORKFLOW_PATTERNS=$(shellcheck_patterns_of "$SHELLCHECK_WORKFLOW" "Run shellcheck on the test suite")

  assert_not_empty "$WORKFLOW_PATTERNS" \
    "the workflow should still hand shellcheck the tests/ tree" || return 1

  # Each test case runs in its own subshell, so the directory the globs resolve
  # from is this case's own
  cd "$REPO_ROOT" || return 1
  shopt -s nullglob
  local -a LINTED_FILES=($WORKFLOW_PATTERNS)
  shopt -u nullglob

  # A shebang is what tells a file of this tree from tests/README.md, and it is
  # what the tree happens to be : every file under it but that one carries one
  local -r LINTED_LIST=$(printf '%s\n' "${LINTED_FILES[@]}")

  shopt -s globstar
  local CANDIDATE
  for CANDIDATE in tests/**/*; do
    [ -f "$CANDIDATE" ] || continue
    [ "$(head -c 2 "$CANDIDATE")" = "#!" ] || continue

    if printf '%s\n' "$LINTED_LIST" | grep -qxF "$CANDIDATE"; then
      pass
    else
      fail "$CANDIDATE is linted by nothing, the Shellcheck workflow's tests/ patterns do not reach it" \
        "they expand to : ${LINTED_FILES[*]}"
    fi
  done
  shopt -u globstar
}

function test_the_suite_lint_command_claude_md_documents_is_the_one_the_workflow_runs() {
  local -r SHELLCHECK_WORKFLOW="$REPO_ROOT/.github/workflows/shellcheck.yml"

  if [ ! -f "$REPO_ROOT/CLAUDE.md" ] || [ ! -f "$SHELLCHECK_WORKFLOW" ]; then
    skip_test "no CLAUDE.md and no .github/workflows next to the scripts"
    return 0
  fi

  # Same reasoning as the case that pins the first invocation : the copy a session
  # runs before pushing is the one nothing executes, and being wrong about what CI
  # checks is what makes it push a file nothing linted. Compared as the set of
  # files each ends up handing shellcheck rather than as text
  local -r WORKFLOW_PATTERNS=$(shellcheck_patterns_of "$SHELLCHECK_WORKFLOW" "Run shellcheck on the test suite")
  local -r DOCUMENTED_PATTERNS=$(shellcheck_patterns_of "$REPO_ROOT/CLAUDE.md" "shellcheck -x -e ")

  assert_not_empty "$DOCUMENTED_PATTERNS" \
    "CLAUDE.md should still print the invocation that lints the suite" || return 1

  cd "$REPO_ROOT" || return 1
  shopt -s nullglob
  local -a WORKFLOW_FILES=($WORKFLOW_PATTERNS)
  local -a DOCUMENTED_FILES=($DOCUMENTED_PATTERNS)
  shopt -u nullglob

  assert_equals "${WORKFLOW_FILES[*]}" "${DOCUMENTED_FILES[*]}" \
    "CLAUDE.md and the Shellcheck workflow should lint the same files of the suite"

  # The exclusions are the argued half : a code silenced in one and not the other
  # means a session sees findings CI does not, or the reverse
  local -r WORKFLOW_EXCLUSIONS=$(grep -oE '^[[:space:]]*shellcheck -x -e [A-Z0-9,]+' "$SHELLCHECK_WORKFLOW" | grep -oE 'SC[0-9,SC]+')
  local -r DOCUMENTED_EXCLUSIONS=$(grep -oE '^shellcheck -x -e [A-Z0-9,]+' "$REPO_ROOT/CLAUDE.md" | grep -oE 'SC[0-9,SC]+')

  assert_equals "$WORKFLOW_EXCLUSIONS" "$DOCUMENTED_EXCLUSIONS" \
    "CLAUDE.md and the workflow should silence the same shellcheck codes over the suite"
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
      "${SCRIPT#"$REPO_ROOT"/} expands two command substitutions in one statement"
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

  # Every fenced block of the README that sets IDRAC_HOST : the two "docker run"
  # ones, the two docker-compose ones, and the "export" block further down for
  # running it from a plain checkout. Found by what they contain rather than by
  # their position -- and read from the whole file rather than from the "Usage"
  # section, because the export block sits outside it and was the one that drifted
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
  done < "$REPO_ROOT/README.md"

  # Without this the loop below would pass by having nothing to iterate over,
  # which is the failure mode these guards exist to prevent in the first place
  if (( ${#USAGE_EXAMPLES[@]} < 5 )); then
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

function test_the_mode_switching_recipe_only_names_parameters_the_image_declares() {
  # The Troubleshooting entry answering #407 is the one piece of documentation that
  # has users write a "docker create" of their own rather than copy a Usage block,
  # so the guard above -- which holds those four blocks to the Dockerfile's ENV list
  # -- does not reach it. A parameter renamed or dropped would leave this recipe
  # naming a variable the image no longer reads, and nothing would say so : the
  # container starts, ignores it, and drives the fans on the default instead.
  # Which is the shape of the whole entry's subject, a mode the user believes they
  # selected and did not
  if [ ! -f "$REPO_ROOT/Dockerfile" ] || [ ! -f "$REPO_ROOT/README.md" ]; then
    # The suite is running inside the built image, which carries neither
    skip_test "no Dockerfile and README next to the scripts"
    return 0
  fi

  # The entry alone, from its heading to the next one, so that an assertion below
  # cannot be satisfied by a passage somewhere else in the file -- the Usage blocks
  # in particular, which set the very same parameters
  local -r RECIPE=$(awk '/^### You want the fans quiet at some hours/ {inside = 1; next} /^## / || /^### / {inside = 0} inside' "$REPO_ROOT/README.md")

  # Without this the loop below would pass by having nothing to iterate over, which
  # is exactly what a renamed heading would produce
  assert_not_empty "$RECIPE" \
    "the README should carry the Troubleshooting entry on switching between the two modes" || return 1

  # Both spellings : the entry exists to say which way round they are, and half of
  # that is a reader left in the mode they wanted to leave
  assert_contains "$RECIPE" "MONITORING_ONLY_MODE=false" \
    "the recipe should name the value that has this container drive the fans"
  assert_contains "$RECIPE" "MONITORING_ONLY_MODE=true" \
    "and the value that leaves them to the iDRAC's own dynamic profile"

  # The "ENV NAME=" lines the image ships and the "# ENV NAME=" ones it comments out
  # for the two credentials, which are parameters it reads all the same
  local -r DECLARED_PARAMETERS=$(grep -oE '^#? ?ENV [A-Z_]+=' "$REPO_ROOT/Dockerfile" | sed -E 's/^#? ?ENV //; s/=$//' | sort -u)

  local PARAMETER
  while IFS= read -r PARAMETER; do
    [ -n "$PARAMETER" ] || continue

    if printf '%s\n' "$DECLARED_PARAMETERS" | grep -qxF "$PARAMETER"; then
      pass
    else
      fail "the mode switching recipe sets $PARAMETER, which the Dockerfile declares nowhere" \
        "it declares : $(printf '%s' "$DECLARED_PARAMETERS" | tr '\n' ' ')"
    fi
  done < <(printf '%s\n' "$RECIPE" | grep -oE '\b[A-Z][A-Z0-9_]+=' | tr -d '=' | sort -u)
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

  local -r LINTED_SCRIPTS=$(scripts_the_shellcheck_workflow_names "$SHELLCHECK_WORKFLOW")

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

function test_the_workflow_claude_md_says_builds_the_image_still_builds_it() {
  if [ ! -f "$REPO_ROOT/CLAUDE.md" ] || [ ! -f "$REPO_ROOT/.github/workflows/tests.yml" ]; then
    skip_test "no CLAUDE.md and no .github/workflows next to the scripts"
    return 0
  fi

  # CLAUDE.md lists three commands to run before pushing and says the third of them, the
  # image build, needs a Docker daemon that Claude Code on the web does not have. What
  # makes leaving it out safe there is the Tests workflow building the image on every pull
  # request, so a broken Dockerfile is still caught before a merge (#463).
  #
  # Two documents, one fact, and the permission rests entirely on it. If that step ever
  # goes, CLAUDE.md would be telling every session it may skip the only build there is --
  # the quiet kind of wrong this file exists to refuse
  local -r TESTS_WORKFLOW=$(cat "$REPO_ROOT/.github/workflows/tests.yml")

  assert_contains "$(cat "$REPO_ROOT/CLAUDE.md")" "builds the image on every pull request" \
    "CLAUDE.md should still say what covers the build a session cannot run" || return 1

  # Not anchored at a line end : "[[ =~ ]]" matches against the whole file as one string,
  # where "$" is its last character rather than the end of the line the command sits on
  assert_matches "$TESTS_WORKFLOW" 'run: docker build ' \
    "the Tests workflow should still build the image, which is what makes that true"
}

function test_the_workflow_claude_md_gives_as_its_reason_still_skips_drafts() {
  if [ ! -f "$REPO_ROOT/CLAUDE.md" ] || [ ! -f "$REPO_ROOT/.github/workflows/auto_update_pull_request_branches.yml" ]; then
    skip_test "no CLAUDE.md and no .github/workflows next to the scripts"
    return 0
  fi

  # CLAUDE.md tells a session never to open a draft, and the reason it gives is this
  # workflow : drafts are filtered out of what it updates, so a draft opened here would be
  # the one pull request master's moves never reach, falling behind at every merge under
  # "Require branches to be up to date before merging" (#448).
  #
  # Two documents, one fact, and the rule is only worth its line while the fact holds. The
  # filter is right for what it was written for -- a contributor's work in progress, often
  # in a fork -- so nothing here asks for it to go ; what this refuses is the filter going
  # quietly, leaving an instruction that a session still obeys and nobody can still argue
  local -r BRANCH_UPDATE_WORKFLOW=$(cat "$REPO_ROOT/.github/workflows/auto_update_pull_request_branches.yml")

  assert_contains "$(cat "$REPO_ROOT/CLAUDE.md")" "never as a draft" \
    "CLAUDE.md should still tell a session not to open a draft" || return 1

  assert_matches "$BRANCH_UPDATE_WORKFLOW" '\-\-json [A-Za-z,]*isDraft' \
    "the branch updater should still ask which open pull requests are drafts"
  assert_matches "$BRANCH_UPDATE_WORKFLOW" 'select\(\.isDraft[[:space:]]*\|[[:space:]]*not\)' \
    "the branch updater should still leave the drafts out of what it updates, which is why CLAUDE.md refuses to open one"
}

# What the runner takes is decided in one place : the "case" arms of its option
# parser, each naming the spellings it accepts, under a "*)" arm that turns
# everything else into a usage error and exit 2. The help text is a "cat" block
# written beside it, and reading the answer out of the help is reading a copy :
# an arm deleted while its help line stayed would leave the drift guard below
# green over an option the runner now refuses (issue #419). The arms are the
# source, and the case in between holds the help to them so the copy cannot
# drift either.
#
# Returned space separated and padded on both sides, so that " --list " tells
# an accepted option from a longer one it is the beginning of
# Usage : runner_options_the_parser_accepts -> " --filter --help ... -l "
function runner_options_the_parser_accepts() {
  local -r ACCEPTED=$(awk '/^[[:space:]]*case "\$1" in$/ { IN_PARSER = 1; next }
       IN_PARSER && /^[[:space:]]*esac$/ { exit }
       IN_PARSER' "$TESTS_DIRECTORY/run_tests.sh" |
    sed -nE 's/^[[:space:]]*((-{1,2}[A-Za-z][A-Za-z-]*[[:space:]]*\|[[:space:]]*)*-{1,2}[A-Za-z][A-Za-z-]*)\).*/\1/p' |
    grep -oE '\-{1,2}[A-Za-z][A-Za-z-]*' | sort -u | tr '\n' ' ')

  printf ' %s' "$ACCEPTED"
}

# The option column of the help, up to the two spaces that open its description :
# "-f, --filter PATTERN" yields "-f" and "--filter", and no word of the prose
# behind it can be mistaken for a spelling the runner takes
# Usage : runner_options_the_help_lists -> " --filter --help ... -l "
function runner_options_the_help_lists() {
  local -r LISTED=$(bash "$TESTS_DIRECTORY/run_tests.sh" --help 2>&1 |
    sed -E 's/^[[:space:]]+//' | grep '^-' | sed -E 's/[[:space:]]{2,}.*//' |
    grep -oE '\-{1,2}[A-Za-z][A-Za-z-]*' | sort -u | tr '\n' ' ')

  printf ' %s' "$LISTED"
}

function test_the_runner_help_lists_exactly_the_options_its_parser_accepts() {
  local -r ACCEPTED_OPTIONS=$(runner_options_the_parser_accepts)

  # A parser this case reads nothing out of would make every check below vacuous,
  # and the drift guard after it green over anything at all
  assert_contains "$ACCEPTED_OPTIONS" " --filter " \
    "the option parser should still be where the accepted spellings are read from" || return 1

  local -r LISTED_OPTIONS=$(runner_options_the_help_lists)

  assert_contains "$LISTED_OPTIONS" " --filter " \
    "the runner should still print what it takes" || return 1

  # Both directions, because the two ways they fall out of step cost different
  # things : an option accepted and no longer listed is one nobody finds, an
  # option listed and no longer accepted is a usage error on a documented command
  local OPTION
  for OPTION in $ACCEPTED_OPTIONS; do
    assert_contains "$LISTED_OPTIONS" " $OPTION " \
      "the runner accepts $OPTION, its help should still list it"
  done

  for OPTION in $LISTED_OPTIONS; do
    assert_contains "$ACCEPTED_OPTIONS" " $OPTION " \
      "the runner's help lists $OPTION, its option parser should still accept it"
  done
}

# Every option a document runs the suite with, read out of its fenced blocks
# alone : that is where a document runs a command, while in prose it quotes them,
# and a quoted option next to the runner's name is a reference rather than an
# invocation. Sentence "`./tests/run_tests.sh` exactly, then `shellcheck` and
# `bash -n`" cost this case a false failure over a -n the runner was never asked for
# Usage : runner_options_documented_in FILE -> one per line
function runner_options_documented_in() {
  awk '/^```/ { IS_FENCED = !IS_FENCED; next } IS_FENCED' "$1" |
    grep -oE '(\./)?tests/run_tests\.sh[^#]*' |
    grep -oE ' -{1,2}[A-Za-z][A-Za-z-]*' | tr -d ' ' | sort -u
}

function test_every_document_runs_the_suite_with_options_the_runner_accepts() {
  local -r ACCEPTED_OPTIONS=$(runner_options_the_parser_accepts)

  assert_contains "$ACCEPTED_OPTIONS" " --filter " \
    "the option parser should still be where the accepted spellings are read from" || return 1

  # Three documents run the suite, and until this walked all of them the checked
  # one was the one carrying the fewest : CLAUDE.md names two options, README.md
  # three and tests/README.md six. What an option costs when it stops being
  # accepted only changes reader -- a session meets exit 2 on the first command it
  # was told to run, a contributor loses the same minute with less to go on --
  # and CONTRIBUTING.md sends that contributor to tests/README.md by name (#437)
  local -r DOCUMENTS="CLAUDE.md README.md tests/README.md"

  local DOCUMENT DOCUMENTED_OPTION READ_ANY_DOCUMENT=false
  for DOCUMENT in $DOCUMENTS; do
    [ -f "$REPO_ROOT/$DOCUMENT" ] || continue
    READ_ANY_DOCUMENT=true

    while IFS= read -r DOCUMENTED_OPTION; do
      [ -n "$DOCUMENTED_OPTION" ] || continue

      assert_contains "$ACCEPTED_OPTIONS" " $DOCUMENTED_OPTION " \
        "$DOCUMENT runs the suite with $DOCUMENTED_OPTION, the runner should still accept it"
    done < <(runner_options_documented_in "$REPO_ROOT/$DOCUMENT")
  done

  if ! $READ_ANY_DOCUMENT; then
    skip_test "none of the documents that run the suite is next to the scripts"
  fi
}

function test_the_suites_own_readme_states_every_exit_code_the_runner_can_reach() {
  if [ ! -f "$REPO_ROOT/tests/README.md" ]; then
    skip_test "no tests/README.md next to the runner"
    return 0
  fi

  # The sentence under the usage block is what a CI step reads before it writes
  # "if [ $? -eq 1 ]". It said "0 when every test case passed, 1 otherwise", and
  # the runner has a third : the option parser exits 2 on an unknown option or on
  # one given without its value. Under "1 otherwise" that run takes the else
  # branch and is reported as a pass -- a usage error read as a green suite
  local -r REACHABLE_EXIT_CODES=$(grep -oE '^[[:space:]]*exit [0-9]+' "$TESTS_DIRECTORY/run_tests.sh" |
    grep -oE '[0-9]+' | sort -u)

  assert_not_empty "$REACHABLE_EXIT_CODES" "the runner should still exit with a status of its own" || return 1

  # The whole document rather than the sentence, so that moving the explanation
  # or splitting it in two is not a failure : what matters is that the number is
  # written down somewhere a reader of this file meets it
  local -r SUITE_README=$(< "$REPO_ROOT/tests/README.md")

  local EXIT_CODE
  while IFS= read -r EXIT_CODE; do
    [ -n "$EXIT_CODE" ] || continue

    assert_matches "$SUITE_README" "\`$EXIT_CODE\`" \
      "tests/run_tests.sh can exit $EXIT_CODE, and its README should say when"
  done <<< "$REACHABLE_EXIT_CODES"
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


function test_the_test_case_the_documentation_shows_passes_when_it_is_run() {
  # The cases above settle what the documents say about the repository. This one
  # settles the single block they hand a session to copy, and copying is exactly
  # how that block failed : it asserted on a variable only the controller sets,
  # read the sdr output through one a case never has, and carried a name the
  # suite had already taken. None of the cases above would have caught any of it
  # -- a code block names no path, no option and no figure -- and the only
  # reading that settles an example is to run it.
  #
  # Both documents carry that block, byte for byte, and both are read as
  # instructions : CLAUDE.md by a session, tests/README.md by the contributor
  # CLAUDE.md sends there before touching a test. Guarding one and not the other
  # is what let the same three defects sit in both until they were corrected by
  # hand, so the walk is over the pair rather than over the copy that happens to
  # be nearer (issue #392)
  local -a DOCUMENTS=()
  [ -f "$REPO_ROOT/CLAUDE.md" ] && DOCUMENTS+=("$REPO_ROOT/CLAUDE.md")
  [ -f "$TESTS_DIRECTORY/README.md" ] && DOCUMENTS+=("$TESTS_DIRECTORY/README.md")

  if [ "${#DOCUMENTS[@]}" -eq 0 ]; then
    skip_test "neither CLAUDE.md nor the suite's README next to the scripts"
    return 0
  fi

  # The probe machinery belongs to tests/cases/15_test_runner.sh, which is sourced
  # into this same shell along with every other case file, so it is reachable from
  # here whatever the filter
  if ! declare -F run_the_runner_on_a_probe_case_file > /dev/null; then
    fail "the probe helper tests/cases/15_test_runner.sh declares is gone, so the example cannot be run"
    return 1
  fi

  local DOCUMENT RELATIVE_PATH DOCUMENTED_CASE DOCUMENTED_CASE_NAME COLLIDING_FILES
  for DOCUMENT in "${DOCUMENTS[@]}"; do
    RELATIVE_PATH="${DOCUMENT#"$REPO_ROOT"/}"

    # Anchored on the section each document keeps it under -- "Writing a test
    # case" here, "Adding a test case" there -- rather than on the first
    # "function test_" anywhere in the file. Unanchored, any example added
    # earlier silently becomes what both halves below check, and the block a
    # contributor actually copies goes unguarded again
    DOCUMENTED_CASE=$(awk '
      /^## .*[Tt]est case$/ { IS_THE_SECTION = 1; next }
      /^## / { IS_THE_SECTION = 0 }
      IS_THE_SECTION && /^function test_/ { IS_THE_CASE = 1 }
      IS_THE_CASE { print }
      IS_THE_CASE && /^}/ { exit }' "$DOCUMENT")

    assert_matches "$DOCUMENTED_CASE" '^function test_[A-Za-z0-9_]+[[:space:]]*\(\)' \
      "$RELATIVE_PATH should still show a test case where it explains how to write one" || continue

    # Discovery reads the case files as text and the runner refuses to start on a
    # name declared twice, so a name the suite already carries makes the example
    # unusable as written whatever its body does. Matched with the runner's own
    # expression rather than a tighter one, so that the two cannot disagree
    DOCUMENTED_CASE_NAME=$(printf '%s' "$DOCUMENTED_CASE" | sed -n '1s/^function \([A-Za-z0-9_]*\).*/\1/p')
    COLLIDING_FILES=$(grep -rlE "^[[:space:]]*(function[[:space:]]+)?${DOCUMENTED_CASE_NAME}[[:space:]]*\(\)" "$TESTS_DIRECTORY/cases" || true)

    if [ -z "$COLLIDING_FILES" ]; then
      pass
    else
      fail "$RELATIVE_PATH shows $DOCUMENTED_CASE_NAME, a name the suite already declares, so pasting it stops the runner" \
        "declared in : $(printf '%s' "$COLLIDING_FILES" | tr '\n' ' ')"
    fi

    # Then run it the way a session would : the real runner, on a repository of
    # its own holding that case and nothing else
    run_the_runner_on_a_probe_case_file "$DOCUMENTED_CASE"

    if [ "$PROBE_EXIT_CODE" -eq 0 ]; then
      pass
    else
      fail "the test case $RELATIVE_PATH shows does not pass when it is run" "$PROBE_OUTPUT"
    fi
  done
}

function test_the_suites_own_readme_names_every_mock_it_ships() {
  # tests/README.md draws the tree a contributor navigates by, and its mocks/ line
  # enumerates what the suite fakes. It named three of the four for as long as the
  # fourth existed : tests/mocks/perl is the whole Redfish HTTPS transport, and
  # without it 15 of the 26 cases in cases/46 fail -- so the one document that says
  # what is mocked did not say the transport was, and a contributor writing a
  # Redfish case was sent to a list that did not hold what they needed.
  #
  # Matched over the document rather than over that one line : a mock named
  # anywhere in it is a mock a contributor can find, and pinning the line would
  # break on any rewording of the tree
  if [ ! -f "$TESTS_DIRECTORY/README.md" ]; then
    skip_test "no README next to the test cases"
    return 0
  fi

  local -r README_CONTENT=$(cat "$TESTS_DIRECTORY/README.md")

  local MOCK MOCK_NAME
  for MOCK in "$TESTS_DIRECTORY"/mocks/*; do
    [ -f "$MOCK" ] || continue

    MOCK_NAME=$(basename "$MOCK")
    assert_contains "$README_CONTENT" "$MOCK_NAME" \
      "the suite fakes $MOCK_NAME, the README should say so somewhere a contributor looks"
  done
}

function test_the_suites_own_readme_names_every_enclosure_the_catalogue_declares() {
  # The catalogue paragraph closes on a parenthesis listing what a model's
  # enclosure column can hold, and a closed list is a promise of completeness. It
  # named six of the seven the array declares, leaving out the 1955 -- the 9th
  # generation blade enclosure, which cases/55 loops over like every other one
  if [ ! -f "$TESTS_DIRECTORY/README.md" ]; then
    skip_test "no README next to the test cases"
    return 0
  fi

  local -r README_CONTENT=$(cat "$TESTS_DIRECTORY/README.md")

  local ENCLOSURE
  for ENCLOSURE in "${DELL_SERVER_ENCLOSURES[@]}"; do
    assert_contains "$README_CONTENT" "\`$ENCLOSURE\`" \
      "the catalogue declares the $ENCLOSURE enclosure, the README's list should name it"
  done
}

function test_the_notice_names_every_package_the_image_installs() {
  # NOTICE is copied into the image, and its own Attribution section says keeping
  # it intact is part of what discharges AGPL 5(a) and 7(b). Its third-party
  # paragraph enumerates what the published image contains that this project
  # neither wrote nor distributes in source form -- so the enumeration is the
  # claim, and it fell a release behind the Dockerfile when #374 added the Redfish
  # HTTPS client : perl and libio-socket-ssl-perl shipped, unnamed, for a week.
  #
  # Matched on a whole word, so that libio-socket-ssl-perl cannot stand in for
  # perl : a package named only inside a longer one is a package nobody attributed
  if [ ! -f "$REPO_ROOT/Dockerfile" ] || [ ! -f "$REPO_ROOT/NOTICE" ]; then
    # The suite is running inside the built image, which carries NOTICE but not
    # the Dockerfile that installed anything
    skip_test "no Dockerfile next to NOTICE"
    return 0
  fi

  local -r NOTICE_CONTENT=$(cat "$REPO_ROOT/NOTICE")
  local -r INSTALLED_PACKAGES=$(sed -n 's/.*apt-get install \(.*\) -y.*/\1/p' "$REPO_ROOT/Dockerfile")

  assert_not_empty "$INSTALLED_PACKAGES" \
    "the Dockerfile should still install its packages in one named apt-get line" || return 1

  local PACKAGE
  for PACKAGE in $INSTALLED_PACKAGES; do
    # apt-get's own options share the line with the package names. They are not
    # software shipped in the image, so NOTICE has nothing to say about them
    case "$PACKAGE" in -*) continue ;; esac

    assert_matches "$NOTICE_CONTENT" "(^|[^A-Za-z0-9_-])$PACKAGE([^A-Za-z0-9_-]|$)" \
      "the image installs $PACKAGE, NOTICE should name it among the software shipped with the image"
  done
}

function test_the_image_installs_the_packages_it_names_and_nothing_else() {
  # Left to its recommends, apt puts 13 packages and 3.3 MB into the image that
  # nothing in it ever calls : ipmitool recommends openipmi, a daemon whose job is
  # loading the IPMI kernel modules on a host -- which a container can neither do
  # nor need, being handed a /dev/ipmi0 the host already opened -- and openipmi
  # brings libsnmp, kmod, libpci and libpopt with it ; libio-socket-ssl-perl
  # recommends liburi-perl, which HTTP::Tiny does not use. Measured on
  # ubuntu:latest : 117 packages and 61.6 MB with them, 104 and 58.3 MB without,
  # the two images answering "ipmitool -h" with the same interface list, failing an
  # absent /dev/ipmi0 with the same message, printing the same "sensors -u" and
  # completing the same HTTPS round trip with Basic auth against a local TLS server
  #
  # The flag is also what makes the install line's four names the whole truth about
  # what ships, which is the claim the NOTICE case above reads them as
  if [ ! -f "$REPO_ROOT/Dockerfile" ]; then
    # The suite is running inside the built image, which does not carry the
    # Dockerfile that built it
    skip_test "no Dockerfile next to the scripts"
    return 0
  fi

  local -r DOCKERFILE_CONTENT=$(cat "$REPO_ROOT/Dockerfile")

  assert_contains "$DOCKERFILE_CONTENT" "apt-get install --no-install-recommends " \
    "the image should install what the Dockerfile names and nothing else" || return 1

  # perl reached the image on its own before #374 named it, through the very chain
  # this flag drops : ipmitool recommends openipmi, openipmi depends on libsnmp and
  # libsnmp on libperl. It is named here, and libio-socket-ssl-perl depends on it
  # outright, so the Redfish client does not rest on that coincidence any more --
  # but the name is what says so, and dropping it would put the image back on it
  local -r INSTALLED_PACKAGES=$(sed -n 's/.*apt-get install \(.*\) -y.*/\1/p' "$REPO_ROOT/Dockerfile")

  assert_matches "$INSTALLED_PACKAGES" "(^| )perl( |$)" \
    "perl is the Redfish client's interpreter, the Dockerfile should keep naming it explicitly"
}

function test_the_healthcheck_succeeds_when_the_sensors_can_be_read() {
  local OUTPUT
  OUTPUT=$(cd "$CONTROLLER_WORKING_DIRECTORY" && bash ./healthcheck.sh 2>&1)
  local -r EXIT_CODE=$?

  assert_equals 0 "$EXIT_CODE" "the healthcheck should succeed when ipmitool answers"
  assert_contains "$OUTPUT" "degrees C" "the healthcheck should print the sensor readings"
}

function test_the_healthcheck_fails_when_the_sensors_cannot_be_read() {
  export MOCK_IPMITOOL_SDR_EXIT_CODE=1
  export MOCK_IPMITOOL_SDR_OUTPUT=""

  local EXIT_CODE=0
  (cd "$CONTROLLER_WORKING_DIRECTORY" && bash ./healthcheck.sh) > /dev/null 2>&1 || EXIT_CODE=$?

  assert_not_equals 0 "$EXIT_CODE" "the healthcheck should fail when ipmitool fails, so Docker restarts the container"
}

# The heartbeat the healthcheck reads to tell a running monitoring loop from a wedged
# one. Until #440 the check only ever asked whether the TEMPERATURE SOURCE answered,
# so an iDRAC that kept answering while the loop had stopped left the container
# healthy with the fans pinned at FAN_SPEED and nothing evaluating the threshold --
# the one state with no recovery, the restart policy never firing.
#
# setup_test_context() points HEARTBEAT_FILE at this run's own temporary directory,
# the CI runner not being root and /run not being writable there
function test_a_recorded_cycle_says_the_monitoring_loop_is_running() {
  note_that_this_cycle_completed

  assert_command_succeeds "a completed cycle should be recorded" \
    test -f "$TEST_HEARTBEAT_FILE" || return 1
  assert_command_succeeds "a cycle recorded just now is a loop that is running" \
    is_the_monitoring_loop_still_reporting "$CHECK_INTERVAL"
}

function test_a_loop_that_stopped_recording_its_cycles_is_reported() {
  export CHECK_INTERVAL=5

  note_that_this_cycle_completed

  # Well past three check intervals AND past the one minute floor below them
  local LONG_AGO
  printf -v LONG_AGO '%(%s)T' -1
  touch -d "@$((LONG_AGO - 600))" "$TEST_HEARTBEAT_FILE"

  assert_command_fails "a record that stopped moving is a loop that stopped running" \
    is_the_monitoring_loop_still_reporting "$CHECK_INTERVAL"
}

function test_no_cycle_recorded_yet_is_never_a_verdict() {
  # The file does not exist before the first cycle, and the loop that waits for a
  # powered-off server to come back can run for hours by design before there is one.
  # Calling that unhealthy would restart exactly the container that loop exists to
  # keep alive, which is why absence is deliberately not a fault
  rm -f "$TEST_HEARTBEAT_FILE"

  assert_command_succeeds "a container that has not completed a cycle yet is not a wedged one" \
    is_the_monitoring_loop_still_reporting "$CHECK_INTERVAL"
}

function test_an_unreadable_record_is_never_a_verdict_either() {
  # Same reasoning as the ipmitool completion codes : an answer that was not
  # understood says nothing about the thing it was asked about
  printf 'not a timestamp\n' > "$TEST_HEARTBEAT_FILE"
  # stat reads the inode rather than the content, so the reading is broken the only
  # way it can be from the outside : by taking the file away underneath it
  rm -f "$TEST_HEARTBEAT_FILE"

  assert_command_succeeds "a record that cannot be read is not a loop that stopped" \
    is_the_monitoring_loop_still_reporting "$CHECK_INTERVAL"
}

function test_a_short_check_interval_cannot_make_the_deadline_tighter_than_the_floor() {
  # Three cycles of a 1 second interval is 3 seconds, which a single cycle's own IPMI
  # round trips can exceed on a slow iDRAC. Without the floor the healthcheck would
  # fail on every check of a container that is working, and Docker's --retries=3 would
  # turn that into a restart loop on a machine whose fans this container is holding
  export CHECK_INTERVAL=1

  note_that_this_cycle_completed

  local NOW
  printf -v NOW '%(%s)T' -1
  # Older than three cycles, younger than the floor
  touch -d "@$((NOW - 30))" "$TEST_HEARTBEAT_FILE"

  assert_command_succeeds "the deadline should never fall below ${MINIMUM_HEARTBEAT_STALENESS_IN_SECONDS}s" \
    is_the_monitoring_loop_still_reporting "$CHECK_INTERVAL"

  touch -d "@$((NOW - MINIMUM_HEARTBEAT_STALENESS_IN_SECONDS - 30))" "$TEST_HEARTBEAT_FILE"

  assert_command_fails "past the floor it is still a verdict" \
    is_the_monitoring_loop_still_reporting "$CHECK_INTERVAL"
}

function test_the_healthcheck_fails_on_a_loop_that_stopped_even_when_the_idrac_answers() {
  # The whole point of #440 : ipmitool answering is not the container working. Run
  # from the throwaway repository so the healthcheck reads the same redirected
  # heartbeat the test wrote
  export CHECK_INTERVAL=5

  note_that_this_cycle_completed

  local NOW
  printf -v NOW '%(%s)T' -1
  touch -d "@$((NOW - 600))" "$TEST_HEARTBEAT_FILE"

  local EXIT_CODE=0
  local OUTPUT
  OUTPUT=$(cd "$CONTROLLER_WORKING_DIRECTORY" && bash ./healthcheck.sh 2>&1) || EXIT_CODE=$?

  assert_not_equals 0 "$EXIT_CODE" \
    "the healthcheck should fail on a wedged loop, so Docker restarts the container"
  assert_contains "$OUTPUT" "has not completed a cycle" \
    "and say which of the two states it found"
  assert_not_contains "$OUTPUT" "degrees C" \
    "it should not go on to read the sensors it has already decided about"
}

function test_a_heartbeat_that_cannot_be_written_is_said_once_and_never_again() {
  # It costs the supervision this file adds, not the monitoring, so it is a warning
  # rather than a reason to stop -- and repeating it every cycle would be the log
  # spam this project removes everywhere else
  HEARTBEAT_FILE="$TEST_TEMPORARY_DIRECTORY/a_directory_that_does_not_exist/heartbeat"

  local FIRST SECOND
  capture_output note_that_this_cycle_completed
  FIRST="$CAPTURED_OUTPUT"
  capture_output note_that_this_cycle_completed
  SECOND="$CAPTURED_OUTPUT"

  assert_contains "$FIRST" "Could not write" "the first failure should be reported"
  assert_contains "$FIRST" "Fan control and temperature monitoring are unaffected" \
    "and say what it does and does not cost"
  assert_empty "$SECOND" "the second one should say nothing"
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
      fail "${SCRIPT#"$REPO_ROOT"/} dispatches a boolean parameter unquoted" "$UNQUOTED"
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
    while IFS= read -r CALL_LINE_NUMBER; do
      TERMINATOR_LINE=$(sed -n "$((CALL_LINE_NUMBER + 1))p" "$SCRIPT")
      # A statement doing nothing but ending a line, whitespace removed so that
      # indentation and the two spellings both reduce to the same few strings
      case "$(printf '%s' "$TERMINATOR_LINE" | tr -d '[:space:]')" in
        'printf"\n"' | "printf'\n'" | 'echo""' | "echo''" | 'echo')
          OFFENDERS+="$((CALL_LINE_NUMBER + 1)):$TERMINATOR_LINE"$'\n' ;;
      esac
    done < <(grep -nE "^[[:space:]]*print_(error|warning) " "$SCRIPT" | cut -d: -f1)

    if [ -z "$OFFENDERS" ]; then
      pass
    else
      fail "${SCRIPT#"$REPO_ROOT"/} terminates a message line a second time" "$OFFENDERS"
    fi
  done
}

function test_the_dependency_graph_claude_md_states_is_the_one_the_scripts_source() {
  if [ ! -f "$REPO_ROOT/CLAUDE.md" ]; then
    skip_test "no CLAUDE.md next to the scripts"
    return 0
  fi

  # CLAUDE.md closes its Layout section on a completeness claim -- "That is the
  # entire dependency graph" -- and a session relies on it when deciding where a
  # declaration has to live. The sentence was wrong the first time it was written
  # (it gave healthcheck.sh constants.sh as well), was fixed by hand, and was
  # classed at the time among the statements no test can settle. It is settleable :
  # the facts are the "source" lines of three files.
  #
  # The expected graph is written out here rather than parsed back out of the
  # prose, because a parser tight enough to read that sentence would break on any
  # rewording of it. A change to what a script sources therefore fails here and has
  # to be made in both places, which is the point
  local -r EXPECTED_GRAPH="Dell_iDRAC_fan_controller.sh: constants.sh functions.sh
healthcheck.sh: functions.sh
supervisor.sh: constants.sh functions.sh"

  local ACTUAL_GRAPH=""
  local SCRIPT SOURCED
  for SCRIPT in Dell_iDRAC_fan_controller.sh healthcheck.sh supervisor.sh; do
    [ -f "$REPO_ROOT/$SCRIPT" ] || continue

    SOURCED="$(sed -n 's/^[[:space:]]*\(source\|\.\)[[:space:]]\{1,\}\([A-Za-z0-9_.-]*\.sh\).*/\2/p' \
      "$REPO_ROOT/$SCRIPT" | sort -u | tr '\n' ' ')"
    ACTUAL_GRAPH+="$SCRIPT: ${SOURCED% }"$'\n'
  done

  assert_equals "$EXPECTED_GRAPH" "${ACTUAL_GRAPH%$'\n'}" \
    "the dependency graph changed ; CLAUDE.md's Layout section states it in prose and has to change with it"
}

function test_the_packages_claude_md_says_the_hook_installs_are_the_ones_it_installs() {
  local -r HOOK="$REPO_ROOT/.claude/hooks/session-start.sh"

  if [ ! -f "$REPO_ROOT/CLAUDE.md" ] || [ ! -f "$HOOK" ]; then
    skip_test "no CLAUDE.md, or no .claude next to the scripts"
    return 0
  fi

  # CLAUDE.md's Environment section names the tools a web session is promised and
  # says why each matters. The hook's package set lives in one loop, and nothing
  # read it : shrink the set and the suite stays green while the document goes on
  # promising both, so a session trusts a run that is quietly skipping cases, or
  # believes it can run the lint that gates its pull request when it cannot.
  #
  # Only the loop naming them literally : the hook has a second "for PACKAGE in"
  # over the ones it found missing, and matching bare words leaves that one out
  local -r INSTALLED_PACKAGES=$(sed -n 's/^for PACKAGE in \([a-z0-9 _-]\{1,\}\); do$/\1/p' "$HOOK")

  assert_not_empty "$INSTALLED_PACKAGES" \
    "the hook should still install its packages from one named loop" || return 1

  local -r ENVIRONMENT_SECTION=$(awk '
    /^## Environment$/ { IS_THE_SECTION = 1; next }
    /^## / { IS_THE_SECTION = 0 }
    IS_THE_SECTION' "$REPO_ROOT/CLAUDE.md")

  local PACKAGE
  for PACKAGE in $INSTALLED_PACKAGES; do
    assert_contains "$ENVIRONMENT_SECTION" "\`$PACKAGE\`" \
      "the hook installs $PACKAGE ; the Environment section is where a session is told so"
  done
}

function test_every_shell_script_carries_the_licence_header() {
  # The Dockerfile joins the walk : CONTRIBUTING.md calls the two SPDX lines how
  # AGPL-3.0 section 5(a) is satisfied file by file, and the file that builds the
  # image is not less of a file for not being a script. And .claude/ at any depth
  # rather than .claude/hooks/ alone, naming one directory being the mistake the
  # Shellcheck guard had to correct
  shopt -s globstar
  # CLAUDE.md states it as a convention and CONTRIBUTING.md as a rule, "test cases,
  # mocks and helpers included", and NOTICE ties these headers to what discharges
  # AGPL 5(a) and 7(b) : this is licence compliance rather than style. The suite
  # guards the header on the workflows and on CLAUDE.md itself, and guarded it on
  # no shell script at all -- which is every file the convention is about.
  #
  # Read from the first five lines, the same window the workflow case uses, so that
  # it sits where a human and a scanner both find it
  local SCRIPT
  for SCRIPT in "$REPO_ROOT"/*.sh "$REPO_ROOT"/.github/*.sh "$REPO_ROOT"/.claude/**/*.sh \
    "$TESTS_DIRECTORY"/*.sh "$TESTS_DIRECTORY"/lib/*.sh "$TESTS_DIRECTORY"/cases/*.sh \
    "$TESTS_DIRECTORY"/mocks/* "$REPO_ROOT"/Dockerfile; do
    [ -f "$SCRIPT" ] || continue

    if head -5 "$SCRIPT" | grep -q '^# SPDX-License-Identifier: AGPL-3.0-only$'; then
      pass
    else
      fail "${SCRIPT#"$REPO_ROOT"/} carries no SPDX licence header in its first five lines" \
        "every shell script here carries the two lines, mocks and helpers included"
    fi
  done
}

function test_no_case_reaches_the_healthcheck_through_the_repository_root() {
  # The healthcheck reads HEARTBEAT_FILE, and the only thing that points it at this run's own
  # directory is the throwaway repository build_throwaway_controller_repository() writes. Reached
  # from $REPO_ROOT instead, it sources the real functions.sh and reads the real
  # /run/dell_idrac_fan_controller.heartbeat -- a file belonging to the machine rather than to the
  # run, left behind by any container that has run here and stopped.
  #
  # That cannot be seen in a green run, which is the whole reason for this case : absence is
  # deliberately not a verdict, so on a fresh runner the real path never exists and every such case
  # passes. #442 moved two of them and left three behind, and nothing went red for it (issue #455)
  local -r OFFENDERS=$(grep -rn 'REPO_ROOT" && bash \./healthcheck\.sh' "$TESTS_DIRECTORY/cases")

  assert_empty "$OFFENDERS" \
    "a case must reach the healthcheck through CONTROLLER_WORKING_DIRECTORY, or it reads the machine's own heartbeat"
}
