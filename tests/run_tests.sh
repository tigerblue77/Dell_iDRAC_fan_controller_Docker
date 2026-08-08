#!/bin/bash

# Automated test suite for the Dell iDRAC fan controller.
#
# Everything runs against a mocked ipmitool (tests/mocks/ipmitool), so the suite
# needs no Dell hardware, no iDRAC and no network : bash, coreutils, GNU grep and
# awk are enough. Run it with :
#
#   ./tests/run_tests.sh                 # run everything
#   ./tests/run_tests.sh --list          # list the test cases without running them
#   ./tests/run_tests.sh -f temperature  # run the test cases whose name matches
#   ./tests/run_tests.sh --tap           # emit TAP output for a CI parser
#   ./tests/run_tests.sh --junit FILE    # write a JUnit XML report
#   ./tests/run_tests.sh --summary FILE  # write a Markdown report
#
# It exits 0 when every test passed, 1 otherwise.

TESTS_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIRECTORY/.." && pwd)"
readonly TESTS_DIRECTORY REPO_ROOT
export TESTS_DIRECTORY REPO_ROOT

FILTER=""
LIST_ONLY=false
TAP_OUTPUT=false
USE_COLOR=true
JUNIT_REPORT_FILE=""
MARKDOWN_SUMMARY_FILE=""

function print_usage() {
  cat << 'EOF'
Usage: tests/run_tests.sh [option ...]

  -f, --filter PATTERN  only run the test cases whose name matches PATTERN
  -l, --list            list the test cases without running them
      --tap             emit TAP version 13 output
      --junit FILE      write a JUnit XML report, for a CI that publishes one
      --summary FILE    append a Markdown report, for $GITHUB_STEP_SUMMARY
      --no-color        disable colored output
  -h, --help            show this help
EOF
}

# Stop on an option given without the value it takes, instead of letting the loop
# below spin forever : "shift 2" with a single argument left shifts nothing and
# returns non-zero, so the loop would never advance
# Usage : require_option_value "$1" "$#"
function require_option_value() {
  if [ "$2" -lt 2 ]; then
    printf 'Option "%s" requires a value\n\n' "$1" >&2
    print_usage >&2
    exit 2
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    -f | --filter) require_option_value "$1" "$#"; FILTER="$2"; shift 2 ;;
    -l | --list) LIST_ONLY=true; shift ;;
    --tap) TAP_OUTPUT=true; USE_COLOR=false; shift ;;
    --junit) require_option_value "$1" "$#"; JUNIT_REPORT_FILE="$2"; shift 2 ;;
    --summary) require_option_value "$1" "$#"; MARKDOWN_SUMMARY_FILE="$2"; shift 2 ;;
    --no-color) USE_COLOR=false; shift ;;
    -h | --help) print_usage; exit 0 ;;
    *) printf 'Unknown option "%s"\n\n' "$1" >&2; print_usage >&2; exit 2 ;;
  esac
done

if [ ! -t 1 ]; then
  USE_COLOR=false
fi

if $USE_COLOR; then
  readonly COLOR_RESET=$'\e[0m'
  readonly COLOR_BOLD=$'\e[1m'
  readonly COLOR_DIM=$'\e[2m'
  readonly COLOR_GREEN=$'\e[32m'
  readonly COLOR_RED=$'\e[31m'
  readonly COLOR_YELLOW=$'\e[33m'
else
  readonly COLOR_RESET="" COLOR_BOLD="" COLOR_DIM="" COLOR_GREEN="" COLOR_RED="" COLOR_YELLOW=""
fi

# Load the helpers, then the code under test
source "$TESTS_DIRECTORY/lib/assertions.sh"
source "$TESTS_DIRECTORY/lib/fixtures.sh"
source "$TESTS_DIRECTORY/lib/dell_server_catalogue.sh"
source "$TESTS_DIRECTORY/lib/harness.sh"
source "$TESTS_DIRECTORY/lib/reports.sh"
source "$REPO_ROOT/functions.sh"
source "$REPO_ROOT/constants.sh"

GENERATION_14_OR_NEWER_REGEX="$(read_generation_detection_regex)"
readonly GENERATION_14_OR_NEWER_REGEX
if [ -z "$GENERATION_14_OR_NEWER_REGEX" ]; then
  printf 'Could not read the generation detection regular expression from Dell_iDRAC_fan_controller.sh\n' >&2
  exit 1
fi

# Collect the test case names of a file, in declaration order (declare -F would
# sort them alphabetically, which would scramble the story each file tells).
# Every form bash accepts for a top-level definition is matched : with or
# without the "function" keyword, indented, and with spaces around the parens
function test_case_names_of_file() {
  grep -oE '^[[:space:]]*(function[[:space:]]+)?test_[A-Za-z0-9_]+[[:space:]]*\(\)' "$1" |
    sed -E 's/^[[:space:]]*//; s/^function[[:space:]]+//; s/[[:space:]]*\(\)$//'
}

# "test_the_fan_speed_is_applied" -> "the fan speed is applied"
function humanize_test_case_name() {
  local -r NAME="${1#test_}"
  printf '%s' "${NAME//_/ }"
}

# tests/cases/20_conversions.sh -> "conversions"
function humanize_test_file_name() {
  local NAME
  NAME="$(basename "$1" .sh)"
  NAME="${NAME#*_}"
  printf '%s' "${NAME//_/ }"
}

declare -a TEST_FILES=()
while IFS= read -r TEST_FILE; do
  TEST_FILES+=("$TEST_FILE")
done < <(find "$TESTS_DIRECTORY/cases" -name '*.sh' -type f | sort)

if [ "${#TEST_FILES[@]}" -eq 0 ]; then
  printf 'No test case file found in %s\n' "$TESTS_DIRECTORY/cases" >&2
  exit 1
fi

# A case file is sourced into this shell, so an "exit" reached while it is read
# - a stray one, or a guard clause written at the top level by mistake - ends
# the runner right here, with that file's own exit code and nothing printed. It
# would look exactly like a successful run that happened to be quiet. The trap
# is what turns that silence into a failure
# The runner and the libraries have helpers of their own whose name starts with
# "test_" ; only the functions the case files add count as test cases
TEST_CASE_FUNCTIONS_BEFORE_SOURCING="$(declare -F | sed -n 's/^declare -f \(test_[A-Za-z0-9_]*\)$/\1/p')"
readonly TEST_CASE_FUNCTIONS_BEFORE_SOURCING

SOURCING_TEST_FILE=""
function report_interrupted_sourcing() {
  [ -n "$SOURCING_TEST_FILE" ] || return 0
  printf '%s stopped the run while it was being sourced, so no test case ran.\n' \
    "${SOURCING_TEST_FILE#"$REPO_ROOT"/}" >&2
  printf 'A case file must only declare functions and constants at its top level.\n' >&2
  exit 1
}
trap report_interrupted_sourcing EXIT

for TEST_FILE in "${TEST_FILES[@]}"; do
  SOURCING_TEST_FILE="$TEST_FILE"
  source "$TEST_FILE"
done

SOURCING_TEST_FILE=""
trap - EXIT

# Build the ordered list of test cases to run, as "file<tab>function" pairs
declare -a SELECTED_TEST_CASES=()
declare -a DISCOVERED_TEST_CASES=()
for TEST_FILE in "${TEST_FILES[@]}"; do
  while IFS= read -r TEST_CASE_NAME; do
    [ -n "$TEST_CASE_NAME" ] || continue
    DISCOVERED_TEST_CASES+=("$TEST_CASE_NAME")
    if [ -n "$FILTER" ] && [[ ! "$TEST_CASE_NAME" =~ $FILTER ]] && [[ ! "$TEST_FILE" =~ $FILTER ]]; then
      continue
    fi
    SELECTED_TEST_CASES+=("$TEST_FILE"$'\t'"$TEST_CASE_NAME")
  done < <(test_case_names_of_file "$TEST_FILE")
done

# Discovery reads the files as text, execution runs what bash actually defined.
# When the two disagree, a test case exists and never runs - the failure mode
# that costs the most, because the suite stays green while covering less than
# it says. Comparing the two lists is what keeps them honest
declare -a UNDISCOVERED_TEST_CASES=()
while IFS= read -r DEFINED_TEST_CASE; do
  [ -n "$DEFINED_TEST_CASE" ] || continue
  FOUND=false
  for TEST_CASE_NAME in "${DISCOVERED_TEST_CASES[@]}"; do
    if [ "$TEST_CASE_NAME" == "$DEFINED_TEST_CASE" ]; then
      FOUND=true
      break
    fi
  done
  $FOUND || UNDISCOVERED_TEST_CASES+=("$DEFINED_TEST_CASE")
done < <(declare -F | sed -n 's/^declare -f \(test_[A-Za-z0-9_]*\)$/\1/p' |
  grep -Fxv -f <(printf '%s\n' "$TEST_CASE_FUNCTIONS_BEFORE_SOURCING") || true)

if [ "${#UNDISCOVERED_TEST_CASES[@]}" -ne 0 ]; then
  printf 'These test cases are defined but were not found by the runner, so they would never run :\n' >&2
  printf '  %s\n' "${UNDISCOVERED_TEST_CASES[@]}" >&2
  printf 'Declare them at the top level of their file, as "function test_name() {".\n' >&2
  exit 1
fi

readonly TOTAL_TEST_CASES="${#SELECTED_TEST_CASES[@]}"

if [ "$TOTAL_TEST_CASES" -eq 0 ]; then
  printf 'No test case matched "%s"\n' "$FILTER" >&2
  exit 1
fi

if $LIST_ONLY; then
  CURRENT_TEST_FILE=""
  for TEST_CASE in "${SELECTED_TEST_CASES[@]}"; do
    TEST_FILE="${TEST_CASE%%$'\t'*}"
    TEST_CASE_NAME="${TEST_CASE##*$'\t'}"
    if [ "$TEST_FILE" != "$CURRENT_TEST_FILE" ]; then
      CURRENT_TEST_FILE="$TEST_FILE"
      printf '\n%s\n' "$(humanize_test_file_name "$TEST_FILE")"
    fi
    printf '  %s\n' "$(humanize_test_case_name "$TEST_CASE_NAME")"
  done
  printf '\n%d test cases\n' "$TOTAL_TEST_CASES"
  exit 0
fi

TEST_TEMPORARY_DIRECTORY="$(mktemp -d)"
readonly TEST_TEMPORARY_DIRECTORY
export TEST_TEMPORARY_DIRECTORY
trap 'rm -rf "$TEST_TEMPORARY_DIRECTORY"' EXIT

TEST_ASSERTIONS_FILE="$TEST_TEMPORARY_DIRECTORY/assertions"
TEST_DIAGNOSTICS_FILE="$TEST_TEMPORARY_DIRECTORY/diagnostics"
TEST_SKIPPED_FILE="$TEST_TEMPORARY_DIRECTORY/skipped"
readonly TEST_ASSERTIONS_FILE TEST_DIAGNOSTICS_FILE TEST_SKIPPED_FILE
export TEST_ASSERTIONS_FILE TEST_DIAGNOSTICS_FILE TEST_SKIPPED_FILE

if $TAP_OUTPUT; then
  printf 'TAP version 13\n'
  printf '1..%d\n' "$TOTAL_TEST_CASES"
else
  printf '%sDell iDRAC fan controller - automated test suite%s\n' "$COLOR_BOLD" "$COLOR_RESET"
  printf '%s%s, %s%s\n\n' "$COLOR_DIM" "$(bash --version | head -1)" "$REPO_ROOT" "$COLOR_RESET"
fi

PASSED_TEST_CASES=0
FAILED_TEST_CASES=0
SKIPPED_TEST_CASES=0
TOTAL_ASSERTIONS=0
TEST_CASE_INDEX=0
CURRENT_TEST_FILE=""
declare -a FAILED_TEST_CASE_NAMES=()

for TEST_CASE in "${SELECTED_TEST_CASES[@]}"; do
  TEST_FILE="${TEST_CASE%%$'\t'*}"
  TEST_CASE_NAME="${TEST_CASE##*$'\t'}"
  ((TEST_CASE_INDEX++))

  if [ "$TEST_FILE" != "$CURRENT_TEST_FILE" ]; then
    CURRENT_TEST_FILE="$TEST_FILE"
    if ! $TAP_OUTPUT; then
      printf '%s%s%s\n' "$COLOR_BOLD" "$(humanize_test_file_name "$TEST_FILE")" "$COLOR_RESET"
    fi
  fi

  : > "$TEST_ASSERTIONS_FILE"
  : > "$TEST_DIAGNOSTICS_FILE"
  rm -f "$TEST_SKIPPED_FILE"

  # Each test case runs in its own subshell so that the variables, functions,
  # PATH and working directory it changes cannot leak into the next one
  TEST_CASE_EXIT_CODE=0
  TEST_CASE_STARTED_AT=$(current_time_in_milliseconds)
  (
    setup_test_context
    cd "$REPO_ROOT" || exit 1
    "$TEST_CASE_NAME"
  ) > "$TEST_TEMPORARY_DIRECTORY/output" 2>&1 || TEST_CASE_EXIT_CODE=$?
  TEST_CASE_DURATION=$(($(current_time_in_milliseconds) - TEST_CASE_STARTED_AT))

  TEST_CASE_ASSERTIONS=$(wc -c < "$TEST_ASSERTIONS_FILE" | tr -d ' ')
  TOTAL_ASSERTIONS=$((TOTAL_ASSERTIONS + TEST_CASE_ASSERTIONS))
  HUMAN_READABLE_NAME="$(humanize_test_case_name "$TEST_CASE_NAME")"
  TEST_SUITE_NAME="$(humanize_test_file_name "$TEST_FILE")"
  TEST_FILE_PATH="${TEST_FILE#"$REPO_ROOT"/}"

  # skip_test() only records a reason, it does not return from the test case.
  # Anything that failed before or after that call still counts : a skip is a
  # statement that nothing was verified, so it cannot also hide a failure
  if [ -f "$TEST_SKIPPED_FILE" ] && [ ! -s "$TEST_DIAGNOSTICS_FILE" ] && [ "$TEST_CASE_EXIT_CODE" -eq 0 ]; then
    ((SKIPPED_TEST_CASES++))
    SKIP_REASON="$(cat "$TEST_SKIPPED_FILE")"
    record_test_result "$TEST_SUITE_NAME" "$TEST_FILE_PATH" "$TEST_CASE_NAME" "$HUMAN_READABLE_NAME" \
      "skipped" "$TEST_CASE_DURATION" "$TEST_CASE_ASSERTIONS" "$SKIP_REASON"
    if $TAP_OUTPUT; then
      printf 'ok %d - %s # SKIP %s\n' "$TEST_CASE_INDEX" "$HUMAN_READABLE_NAME" "$SKIP_REASON"
    else
      printf '  %sskip%s %s %s(%s)%s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$HUMAN_READABLE_NAME" "$COLOR_DIM" "$SKIP_REASON" "$COLOR_RESET"
    fi
    continue
  fi

  # A test case that asserted nothing verified nothing. It usually means the
  # case returned early on a condition that no longer holds, and it is the one
  # failure a passing suite cannot show you, so it is reported as a failure
  # rather than counted among the green ones
  if [ ! -f "$TEST_SKIPPED_FILE" ] && [ "$TEST_CASE_ASSERTIONS" -eq 0 ] &&
    [ ! -s "$TEST_DIAGNOSTICS_FILE" ] && [ "$TEST_CASE_EXIT_CODE" -eq 0 ]; then
    printf 'the test case recorded no assertion, so it verified nothing\n' > "$TEST_DIAGNOSTICS_FILE"
  fi

  if [ -s "$TEST_DIAGNOSTICS_FILE" ] || [ "$TEST_CASE_EXIT_CODE" -ne 0 ]; then
    ((FAILED_TEST_CASES++))
    FAILED_TEST_CASE_NAMES+=("$TEST_CASE_NAME")
    # A non-zero exit code with no recorded failure means the test case itself
    # crashed, which is worth showing whatever it wrote
    TEST_CASE_DIAGNOSTICS="$(cat "$TEST_DIAGNOSTICS_FILE")"
    if [ "$TEST_CASE_EXIT_CODE" -ne 0 ] && [ ! -s "$TEST_DIAGNOSTICS_FILE" ]; then
      TEST_CASE_DIAGNOSTICS="test case exited with code $TEST_CASE_EXIT_CODE"$'\n'"$(cat "$TEST_TEMPORARY_DIRECTORY/output")"
    fi
    record_test_result "$TEST_SUITE_NAME" "$TEST_FILE_PATH" "$TEST_CASE_NAME" "$HUMAN_READABLE_NAME" \
      "failed" "$TEST_CASE_DURATION" "$TEST_CASE_ASSERTIONS" "$TEST_CASE_DIAGNOSTICS"

    if $TAP_OUTPUT; then
      printf 'not ok %d - %s\n' "$TEST_CASE_INDEX" "$HUMAN_READABLE_NAME"
      printf '%s\n' "$TEST_CASE_DIAGNOSTICS" | sed 's/^/# /'
    else
      printf '  %sfail%s %s\n' "$COLOR_RED" "$COLOR_RESET" "$HUMAN_READABLE_NAME"
      printf '%s\n' "$TEST_CASE_DIAGNOSTICS" | sed 's/^/       /'
    fi
    continue
  fi

  ((PASSED_TEST_CASES++))
  record_test_result "$TEST_SUITE_NAME" "$TEST_FILE_PATH" "$TEST_CASE_NAME" "$HUMAN_READABLE_NAME" \
    "passed" "$TEST_CASE_DURATION" "$TEST_CASE_ASSERTIONS" ""
  if $TAP_OUTPUT; then
    printf 'ok %d - %s\n' "$TEST_CASE_INDEX" "$HUMAN_READABLE_NAME"
  else
    printf '  %sok%s   %s %s(%d assertions)%s\n' "$COLOR_GREEN" "$COLOR_RESET" "$HUMAN_READABLE_NAME" "$COLOR_DIM" "$TEST_CASE_ASSERTIONS" "$COLOR_RESET"
  fi
done

if ! $TAP_OUTPUT; then
  printf '\n'
  if [ "$FAILED_TEST_CASES" -eq 0 ]; then
    printf '%s%d test cases passed%s' "$COLOR_GREEN" "$PASSED_TEST_CASES" "$COLOR_RESET"
  else
    printf '%s%d test cases failed%s, %d passed' "$COLOR_RED" "$FAILED_TEST_CASES" "$COLOR_RESET" "$PASSED_TEST_CASES"
  fi
  if [ "$SKIPPED_TEST_CASES" -gt 0 ]; then
    printf ', %d skipped' "$SKIPPED_TEST_CASES"
  fi
  printf ' (%d assertions)\n' "$TOTAL_ASSERTIONS"

  if [ "$FAILED_TEST_CASES" -ne 0 ]; then
    printf '\nRe-run a single failing test case with:\n'
    printf '  tests/run_tests.sh --filter %s\n' "${FAILED_TEST_CASE_NAMES[0]}"
  fi
fi

# The reports are written whatever the outcome : a red run is the one whose
# report matters most
if [ -n "$JUNIT_REPORT_FILE" ]; then
  write_junit_report "$JUNIT_REPORT_FILE" ||
    printf 'Could not write the JUnit report to "%s"\n' "$JUNIT_REPORT_FILE" >&2
fi
if [ -n "$MARKDOWN_SUMMARY_FILE" ]; then
  write_markdown_summary "$MARKDOWN_SUMMARY_FILE" ||
    printf 'Could not write the Markdown summary to "%s"\n' "$MARKDOWN_SUMMARY_FILE" >&2
fi

[ "$FAILED_TEST_CASES" -eq 0 ]
