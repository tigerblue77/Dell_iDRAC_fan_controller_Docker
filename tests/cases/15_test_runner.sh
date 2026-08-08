#!/bin/bash

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

  PROBE_OUTPUT=$(bash "$PROBE_REPOSITORY/tests/run_tests.sh" --no-color 2>&1)
  PROBE_EXIT_CODE=$?
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

function test_a_test_case_the_runner_cannot_discover_fails_the_run() {
  # The safety net behind the discovery pattern : whatever form escapes it, a
  # test case that exists and would never run has to be loud
  run_the_runner_on_a_probe_case_file "eval 'function ${PROBE_PREFIX}_defined_through_eval() { pass; }'"

  assert_equals 1 "$PROBE_EXIT_CODE" "an undiscoverable test case should fail the run"
  assert_contains "$PROBE_OUTPUT" "${PROBE_PREFIX}_defined_through_eval" \
    "the report should name the test case that would never run"
}
