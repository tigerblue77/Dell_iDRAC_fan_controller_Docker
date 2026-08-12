#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# The JUnit XML and Markdown reports. Nothing covered them until a malformed
# duration reached the publisher and turned a run red with every test case
# passing :
#
#   ValueError: could not convert string to float: '0.-992'
#
# The reports are the only part of the suite whose output is consumed by
# something other than a human, so "it looked fine in the terminal" is not a
# check. These cases hold the two properties a parser depends on : every number
# is a number, and the document is well formed.

# The runner reads its case files as text to list them in declaration order, so
# a definition merely quoted in this file would be discovered and run as part of
# the outer suite. The probe below therefore names its test cases through this
# prefix, exactly as cases/15_test_runner.sh does for the same reason -- under
# its own name, both files being sourced into the same shell
readonly REPORT_PROBE_PREFIX="test"

# Run the real runner over a throwaway case file, in a repository of symbolic
# links to the real scripts, and have it write a JUnit report. The report's path
# is printed
function write_a_junit_report_from_a_probe_run() {
  local -r PROBE_REPOSITORY="$TEST_TEMPORARY_DIRECTORY/report_probe"
  local -r REPORT="$PROBE_REPOSITORY/report.xml"

  rm -rf "$PROBE_REPOSITORY"
  mkdir -p "$PROBE_REPOSITORY/tests/cases"

  # The runner derives the repository root from its own path
  local REPOSITORY_FILE
  for REPOSITORY_FILE in "$REPO_ROOT"/*.sh "$REPO_ROOT/Dockerfile"; do
    [ -e "$REPOSITORY_FILE" ] && ln -s "$REPOSITORY_FILE" "$PROBE_REPOSITORY/"
  done
  cp "$TESTS_DIRECTORY/run_tests.sh" "$PROBE_REPOSITORY/tests/"
  cp -r "$TESTS_DIRECTORY/lib" "$TESTS_DIRECTORY/mocks" "$PROBE_REPOSITORY/tests/"

  # One of each outcome, so the report has a failure and a skip to carry
  {
    printf 'function %s_that_passes() { assert_equals "1" "1" ; }\n' "$REPORT_PROBE_PREFIX"
    printf 'function %s_that_fails() { assert_equals "1" "2" "a message the report carries" ; }\n' "$REPORT_PROBE_PREFIX"
    printf 'function %s_that_is_skipped() { skip_test "nothing to run here" ; }\n' "$REPORT_PROBE_PREFIX"
  } > "$PROBE_REPOSITORY/tests/cases/50_probe.sh"

  bash "$PROBE_REPOSITORY/tests/run_tests.sh" --junit "$REPORT" --no-color > /dev/null 2>&1

  printf '%s' "$REPORT"
}

function test_a_duration_is_formatted_as_seconds_and_milliseconds() {
  assert_equals "0.000" "$(format_duration 0)"
  assert_equals "0.001" "$(format_duration 1)"
  assert_equals "0.999" "$(format_duration 999)"
  assert_equals "1.000" "$(format_duration 1000)"
  assert_equals "1.234" "$(format_duration 1234)"
  assert_equals "12.050" "$(format_duration 12050)"
  assert_equals "3600.000" "$(format_duration 3600000)"
}

function test_a_duration_the_clock_made_negative_is_reported_as_zero() {
  # The durations are wall clock differences, and a wall clock may step
  # backwards -- a CI runner syncing its time between the two reads is enough.
  #
  # Bash truncates integer division towards zero and gives the remainder the
  # sign of the dividend, so -992 used to print as "0.-992" : each field correct
  # on its own, the string they compose not a number. The JUnit publisher parses
  # every "time" attribute as a float, so that one value aborted the entire
  # report and failed the workflow while every test case had passed
  assert_equals "0.000" "$(format_duration -1)" "the shape that produced 0.-001"
  assert_equals "0.000" "$(format_duration -992)" "the value actually observed in CI"
  assert_equals "0.000" "$(format_duration -1500)" "more than a second backwards"
}

function test_every_duration_a_report_can_hold_parses_as_a_number() {
  # The property the publisher actually depends on, checked over the formatter's
  # whole range rather than on a chosen value : a "time" it cannot read as a
  # float costs the report, not the reading
  local DURATION FORMATTED
  for DURATION in -100000 -992 -1 0 1 7 999 1000 1001 59999 86400000; do
    FORMATTED=$(format_duration "$DURATION")

    assert_matches "$FORMATTED" '^[0-9]+\.[0-9]{3}$' \
      "format_duration $DURATION should be a plain decimal number"
  done
}

function test_the_junit_report_is_well_formed_and_carries_every_outcome() {
  # End to end on the document rather than on one attribute : the real runner is
  # driven over a throwaway case file and the report it writes is read back
  local -r REPORT=$(write_a_junit_report_from_a_probe_run)

  if [ ! -s "$REPORT" ]; then
    fail "the runner should have written a JUnit report"
    return 1
  fi

  local -r REPORT_CONTENT=$(cat "$REPORT")

  assert_contains "$REPORT_CONTENT" "<testsuites " "the report should have a root element"
  assert_contains "$REPORT_CONTENT" 'tests="3"' "the three probe test cases should be counted"
  assert_contains "$REPORT_CONTENT" 'failures="1"'
  assert_contains "$REPORT_CONTENT" 'skipped="1"'
  assert_contains "$REPORT_CONTENT" "a message the report carries" \
    "a failure's message should reach the report"

  local -r MALFORMED_TIMES=$(grep -c 'time="[^"]*[^0-9."][^"]*"' "$REPORT" || true)
  assert_equals "0" "$MALFORMED_TIMES" "every time attribute should be a plain decimal number"

  # Well formedness, from whichever XML parser the machine has. Neither is a
  # dependency of this suite, so their absence skips the check rather than
  # failing it
  local XML_ERRORS
  if command -v python3 > /dev/null 2>&1; then
    if XML_ERRORS=$(python3 -c 'import sys,xml.etree.ElementTree as E; E.parse(sys.argv[1])' "$REPORT" 2>&1); then
      pass
    else
      fail "the JUnit report should be well formed XML" "$XML_ERRORS"
    fi
  elif command -v xmllint > /dev/null 2>&1; then
    if XML_ERRORS=$(xmllint --noout "$REPORT" 2>&1); then
      pass
    else
      fail "the JUnit report should be well formed XML" "$XML_ERRORS"
    fi
  fi
}
