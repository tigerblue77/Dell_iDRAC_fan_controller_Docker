#!/bin/bash

# Assertion helpers.
#
# Each test runs in its own subshell, so an assertion cannot simply increment a
# counter: the outcome is recorded in the two files the runner prepares before
# every test ($TEST_ASSERTIONS_FILE and $TEST_DIAGNOSTICS_FILE).
#
# Assertions return 0 on success and 1 on failure but never abort the test, so
# that a data-driven test looping over a hundred server models reports every
# offending model in one run instead of only the first one. Use
# "assert_... || return 1" in the rare cases where the rest of the test cannot
# run once the assertion failed.

function _record_assertion() {
  printf '.' >> "$TEST_ASSERTIONS_FILE"
}

function _record_failure() {
  local -r TITLE="$1"
  shift

  {
    printf '%s\n' "$TITLE"
    local DETAIL
    for DETAIL in "$@"; do
      printf '  %s\n' "$DETAIL"
    done
  } >> "$TEST_DIAGNOSTICS_FILE"
}

# Record a passing assertion, for the tests that run the check themselves
# Usage : if <check>; then pass; else fail "..."; fi
function pass() {
  _record_assertion
}

# Unconditionally fail the current test
# Usage : fail "message" ["detail" ...]
function fail() {
  local -r MESSAGE="$1"
  shift

  _record_assertion
  _record_failure "$MESSAGE" "$@"
  return 1
}

# Usage : assert_equals "$EXPECTED" "$ACTUAL" ["message"]
function assert_equals() {
  local -r EXPECTED="$1"
  local -r ACTUAL="$2"
  local -r MESSAGE="${3:-values should be equal}"

  _record_assertion
  if [ "$EXPECTED" == "$ACTUAL" ]; then
    return 0
  fi

  _record_failure "$MESSAGE" "expected: [$EXPECTED]" "actual:   [$ACTUAL]"
  return 1
}

# Usage : assert_not_equals "$UNEXPECTED" "$ACTUAL" ["message"]
function assert_not_equals() {
  local -r UNEXPECTED="$1"
  local -r ACTUAL="$2"
  local -r MESSAGE="${3:-values should differ}"

  _record_assertion
  if [ "$UNEXPECTED" != "$ACTUAL" ]; then
    return 0
  fi

  _record_failure "$MESSAGE" "both values are: [$ACTUAL]"
  return 1
}

# Usage : assert_contains "$HAYSTACK" "$NEEDLE" ["message"]
function assert_contains() {
  local -r HAYSTACK="$1"
  local -r NEEDLE="$2"
  local -r MESSAGE="${3:-text should contain substring}"

  _record_assertion
  if [[ "$HAYSTACK" == *"$NEEDLE"* ]]; then
    return 0
  fi

  _record_failure "$MESSAGE" "substring: [$NEEDLE]" "text:      [$HAYSTACK]"
  return 1
}

# Usage : assert_not_contains "$HAYSTACK" "$NEEDLE" ["message"]
function assert_not_contains() {
  local -r HAYSTACK="$1"
  local -r NEEDLE="$2"
  local -r MESSAGE="${3:-text should not contain substring}"

  _record_assertion
  if [[ "$HAYSTACK" != *"$NEEDLE"* ]]; then
    return 0
  fi

  _record_failure "$MESSAGE" "substring: [$NEEDLE]" "text:      [$HAYSTACK]"
  return 1
}

# Usage : assert_matches "$VALUE" "$EXTENDED_REGEX" ["message"]
function assert_matches() {
  local -r VALUE="$1"
  local -r REGEX="$2"
  local -r MESSAGE="${3:-value should match regex}"

  _record_assertion
  if [[ "$VALUE" =~ $REGEX ]]; then
    return 0
  fi

  _record_failure "$MESSAGE" "regex: [$REGEX]" "value: [$VALUE]"
  return 1
}

# Usage : assert_empty "$VALUE" ["message"]
function assert_empty() {
  local -r VALUE="$1"
  local -r MESSAGE="${2:-value should be empty}"

  _record_assertion
  if [ -z "$VALUE" ]; then
    return 0
  fi

  _record_failure "$MESSAGE" "value: [$VALUE]"
  return 1
}

# Usage : assert_not_empty "$VALUE" ["message"]
function assert_not_empty() {
  local -r VALUE="$1"
  local -r MESSAGE="${2:-value should not be empty}"

  _record_assertion
  if [ -n "$VALUE" ]; then
    return 0
  fi

  _record_failure "$MESSAGE" "value is empty"
  return 1
}

# Usage : assert_command_succeeds "message" command [argument ...]
function assert_command_succeeds() {
  local -r MESSAGE="$1"
  shift

  local ACTUAL_EXIT_CODE=0
  "$@" > /dev/null 2>&1 || ACTUAL_EXIT_CODE=$?

  _record_assertion
  if [ "$ACTUAL_EXIT_CODE" -eq 0 ]; then
    return 0
  fi

  _record_failure "$MESSAGE" "command:   [$*]" "exit code: [$ACTUAL_EXIT_CODE]"
  return 1
}

# Usage : assert_command_fails "message" command [argument ...]
function assert_command_fails() {
  local -r MESSAGE="$1"
  shift

  local ACTUAL_EXIT_CODE=0
  "$@" > /dev/null 2>&1 || ACTUAL_EXIT_CODE=$?

  _record_assertion
  if [ "$ACTUAL_EXIT_CODE" -ne 0 ]; then
    return 0
  fi

  _record_failure "$MESSAGE" "command: [$*]" "it succeeded instead"
  return 1
}

# Skip the current test, reporting why. Used for the few cases that need a
# capability the environment may not provide (creating a fake /dev/ipmi device
# requires write access to /dev, which an unprivileged CI runner doesn't have)
# Usage : skip_test "reason"
function skip_test() {
  printf '%s\n' "$1" > "$TEST_SKIPPED_FILE"
}
