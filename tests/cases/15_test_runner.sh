#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# Checks on the runner itself. Every other case file trusts it to turn a broken
# controller into a red run ; these pin the four ways it used to stay green
# while nothing had been verified. A suite that guards master has to be able to
# fail, and that is what is tested here.

# The runner reads its case files as text to list them in declaration order, so
# a case file that merely quotes a definition would have it discovered too. That
# is exactly what this file does, so the probes below name their test cases
# through this prefix : nothing here reads as a definition to the outer run
readonly PROBE_PREFIX="test"

# Run the real runner against a throwaway case file, inside a repository of
# symbolic links to the real scripts. The probe therefore exercises the real
# controller, and never joins the suite that is currently running
function run_the_runner_on_a_probe_case_file() {
  local -r PROBE_CONTENT="$1"
  shift

  local -r PROBE_REPOSITORY="$TEST_TEMPORARY_DIRECTORY/runner_probe"
  rm -rf "$PROBE_REPOSITORY"
  mkdir -p "$PROBE_REPOSITORY/tests/cases"

  # The runner derives the repository root from its own path
  local REPOSITORY_FILE
  for REPOSITORY_FILE in "$REPO_ROOT"/*.sh "$REPO_ROOT/Dockerfile"; do
    [ -e "$REPOSITORY_FILE" ] && ln -s "$REPOSITORY_FILE" "$PROBE_REPOSITORY/"
  done
  cp "$TESTS_DIRECTORY/run_tests.sh" "$PROBE_REPOSITORY/tests/"
  cp -r "$TESTS_DIRECTORY/lib" "$TESTS_DIRECTORY/mocks" "$PROBE_REPOSITORY/tests/"
  printf '%s\n' "$PROBE_CONTENT" > "$PROBE_REPOSITORY/tests/cases/50_probe.sh"

  # Anything after the probe content is handed to the runner, which is how a case
  # exercises an option rather than only the discovery
  PROBE_OUTPUT=$(bash "$PROBE_REPOSITORY/tests/run_tests.sh" --no-color "$@" 2>&1)
  PROBE_EXIT_CODE=$?
}

function test_a_filter_matches_a_case_file_by_name_and_never_by_the_path_it_sits_at() {
  # The runner matches a filter against the case name or the case FILE. Which of the
  # two the file contributes decides whether the directory somebody cloned into is
  # part of the question : while it was the absolute path, "-f fan" selected every
  # case in this repository, the clone being named Dell_iDRAC_fan_controller_Docker,
  # and the documented "-f temperature" selected four files' worth of cases beyond
  # the ones whose name carries the word. Nothing said the filter had been widened --
  # the count was the only clue.
  #
  # The probe repository sits under a directory called "runner_probe", a string that
  # appears in neither the case file's name nor the case's own name, so filtering on
  # it selects nothing unless the path is being matched
  run_the_runner_on_a_probe_case_file \
    "function ${PROBE_PREFIX}_is_selected_by_its_own_name() { pass ; }" \
    --filter runner_probe

  assert_equals 1 "$PROBE_EXIT_CODE" "a filter matching only the path a repository was cloned into should select nothing"
  assert_contains "$PROBE_OUTPUT" "No test case matched" \
    "and the runner should say so, rather than silently run every case"

  # The other half of the same decision : a filter naming the case file is the way to
  # run one file, and that has to keep working
  run_the_runner_on_a_probe_case_file \
    "function ${PROBE_PREFIX}_is_selected_by_its_own_name() { pass ; }" \
    --filter 50_probe

  assert_equals 0 "$PROBE_EXIT_CODE" "a filter naming the case file should still select what is in it"
  assert_contains "$PROBE_OUTPUT" "1 test cases passed" "and select exactly that"
}

function test_a_test_case_that_asserts_nothing_is_reported_as_a_failure() {
  # A case returning early on a condition that no longer holds asserts nothing
  # and used to be counted among the passing ones
  run_the_runner_on_a_probe_case_file "function ${PROBE_PREFIX}_verifies_nothing() { : ; }"

  assert_equals 1 "$PROBE_EXIT_CODE" "a case that asserted nothing should fail the run"
  assert_contains "$PROBE_OUTPUT" "recorded no assertion" \
    "the report should say the case verified nothing"
}

function test_a_case_file_that_exits_while_being_sourced_fails_the_run() {
  # Case files are sourced into the runner's own shell, so an exit reached at
  # their top level ended the run with nothing printed and a zero exit code
  run_the_runner_on_a_probe_case_file "exit 0
function ${PROBE_PREFIX}_never_reached() { fail 'this case should never run'; }"

  assert_equals 1 "$PROBE_EXIT_CODE" "a case file exiting while sourced should fail the run"
  assert_contains "$PROBE_OUTPUT" "while it was being sourced" \
    "the report should name what happened"
}

function test_skipping_a_test_case_does_not_hide_a_failure_it_also_recorded() {
  # skip_test() only records a reason, it does not return from the case, so a
  # failing assertion written after it used to disappear behind the skip
  run_the_runner_on_a_probe_case_file "function ${PROBE_PREFIX}_skips_then_fails() {
  skip_test 'not applicable here'
  fail 'this failure must stay visible'
}"

  assert_equals 1 "$PROBE_EXIT_CODE" "a skipped case that also failed should fail the run"
  assert_contains "$PROBE_OUTPUT" "this failure must stay visible" \
    "the failure should be reported, not swallowed by the skip"
}

function test_a_test_case_skipped_without_failing_is_still_a_skip() {
  # The counterpart of the case above : a genuine skip must stay a skip, or
  # every environment-dependent case would turn red
  run_the_runner_on_a_probe_case_file "function ${PROBE_PREFIX}_only_skips() {
  skip_test 'nothing to check here'
  return 0
}"

  assert_equals 0 "$PROBE_EXIT_CODE" "a case that only skipped should not fail the run"
  assert_contains "$PROBE_OUTPUT" "nothing to check here" "the skip reason should be reported"
}

function test_every_form_bash_accepts_for_a_test_case_is_discovered() {
  # Discovery reads the files as text. These three declarations are all valid
  # bash, and the two indented or spaced ones used to be silently ignored
  run_the_runner_on_a_probe_case_file "function ${PROBE_PREFIX}_with_a_space_before_the_parens () { pass; }
  function ${PROBE_PREFIX}_indented() { pass; }
${PROBE_PREFIX}_without_the_function_keyword() { pass; }"

  assert_equals 0 "$PROBE_EXIT_CODE" "the probe cases should all pass"
  assert_contains "$PROBE_OUTPUT" "with a space before the parens" "the spaced form should run"
  assert_contains "$PROBE_OUTPUT" "indented" "the indented form should run"
  assert_contains "$PROBE_OUTPUT" "without the function keyword" "the bare form should run"
}

function test_a_test_case_name_declared_twice_fails_the_run() {
  # Case files are all sourced into the runner's own shell, so the second
  # definition replaces the first without a word : both names are discovered,
  # both run the second body, everything passes, and one of the two test cases
  # has stopped existing. The suite reports more coverage than it has
  run_the_runner_on_a_probe_case_file "function ${PROBE_PREFIX}_declared_twice() { pass; }
function ${PROBE_PREFIX}_declared_twice() { pass; }"

  assert_equals 1 "$PROBE_EXIT_CODE" "a test case name declared twice should fail the run"
  assert_contains "$PROBE_OUTPUT" "${PROBE_PREFIX}_declared_twice" \
    "the report should name the test case that was declared twice"
  assert_contains "$PROBE_OUTPUT" "declared more than once"
}

function test_a_test_case_the_runner_cannot_discover_fails_the_run() {
  # The safety net behind the discovery pattern : whatever form escapes it, a
  # test case that exists and would never run has to be loud
  run_the_runner_on_a_probe_case_file "eval 'function ${PROBE_PREFIX}_defined_through_eval() { pass; }'"

  assert_equals 1 "$PROBE_EXIT_CODE" "an undiscoverable test case should fail the run"
  assert_contains "$PROBE_OUTPUT" "${PROBE_PREFIX}_defined_through_eval" \
    "the report should name the test case that would never run"
}

function test_a_controller_that_ignores_sigterm_is_killed_rather_than_left_to_hang_the_run() {
  # The fifth way the runner used to stay silent, and the worst of them : it did not
  # stay green, it stopped. run_controller() signalled the controller and then waited
  # for it with no bound at all, so a controller that swallowed its SIGTERM -- which
  # a real one does about twice in two hundred starts (issues #188 and #249, and the
  # reason supervisor.sh exists) -- kept looping and the run stopped on it. No
  # timeout, no diagnostic, and not even the name of the case it stopped on, since a
  # case is only reported once it returns.
  #
  # The probe controller refuses the signal outright rather than racing for it, so
  # what is pinned here is the harness's behaviour and not the odds of reproducing a
  # bash bug. The declaration below carries a placeholder rather than the prefix
  # itself for the reason the file's header gives : discovery reads this file as
  # text, and a literal definition would be discovered here too
  local PROBE_CONTENT
  PROBE_CONTENT=$(cat <<'PROBE'
function PROBE_PREFIX_PLACEHOLDER_meets_a_controller_that_will_not_stop() {
  local -r WEDGED_CONTROLLER_DIRECTORY="$TEST_TEMPORARY_DIRECTORY/wedged_controller"
  mkdir -p "$WEDGED_CONTROLLER_DIRECTORY"
  cat > "$WEDGED_CONTROLLER_DIRECTORY/Dell_iDRAC_fan_controller.sh" <<'WEDGED_CONTROLLER'
#!/bin/bash
# What a controller whose trap was swallowed does in practice : it keeps looping
trap '' SIGTERM
while true; do
  printf '  23°C  User static fan control profile (5%%)\n'
  command -p sleep 0.05
done
WEDGED_CONTROLLER

  CONTROLLER_WORKING_DIRECTORY="$WEDGED_CONTROLLER_DIRECTORY"

  # Two statements on purpose : "local X=$(...)" reports the exit code of "local"
  # and not of what it ran, so a killed controller would read as a clean stop
  local OUTPUT=""
  local EXIT_CODE=0
  OUTPUT=$(run_controller) || EXIT_CODE=$?

  assert_equals 137 "$EXIT_CODE" "a controller that had to be killed should report it, not a clean exit"
  assert_contains "$OUTPUT" "fan control profile" "what it printed before being killed is still its output"
}
PROBE
)

  run_the_runner_on_a_probe_case_file "${PROBE_CONTENT//PROBE_PREFIX_PLACEHOLDER/$PROBE_PREFIX}"

  assert_equals 0 "$PROBE_EXIT_CODE" \
    "the run should finish rather than stop on a controller that will not stop" || return 1
  assert_contains "$PROBE_OUTPUT" "ignored SIGTERM and had to be killed" \
    "and it should say so, a killed controller being worth knowing about"
  assert_contains "$PROBE_OUTPUT" "meets_a_controller_that_will_not_stop" \
    "naming the case it happened in, which is what an unbounded wait could never do"
}
