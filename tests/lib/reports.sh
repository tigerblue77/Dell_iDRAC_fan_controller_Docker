#!/bin/bash

# Machine-readable reports, written on top of the human-readable output the
# runner prints while it goes.
#
# The terminal output is meant to be read while the suite runs; these two are
# meant to be read afterwards, by someone looking at a pull request:
#
#   --junit FILE    a JUnit XML report, the format every CI knows how to publish.
#                   GitHub Actions turns it into the test result comment and the
#                   check run, so a failure is shown with what was expected and
#                   what was obtained instead of being buried in the raw log
#   --summary FILE  a Markdown report, written for $GITHUB_STEP_SUMMARY, which
#                   GitHub renders on the job page itself. It carries what the
#                   XML cannot: every test case that ran, suite by suite
#
# Both are built from the same recorded results, so they can never disagree.

# One entry per test case that ran, in the order they ran
declare -a RESULT_SUITES=()
declare -a RESULT_FILES=()
declare -a RESULT_FUNCTIONS=()
declare -a RESULT_NAMES=()
declare -a RESULT_STATUSES=()
declare -a RESULT_DURATIONS=()
declare -a RESULT_ASSERTIONS=()
declare -a RESULT_MESSAGES=()

# Usage : record_test_result "$SUITE" "$FILE" "$FUNCTION" "$NAME" "$STATUS" "$DURATION_MS" "$ASSERTIONS" "$MESSAGE"
# $STATUS is one of passed, failed, skipped. $MESSAGE carries the diagnostics of
# a failed test case, or the reason a skipped one was skipped
function record_test_result() {
  RESULT_SUITES+=("$1")
  RESULT_FILES+=("$2")
  RESULT_FUNCTIONS+=("$3")
  RESULT_NAMES+=("$4")
  RESULT_STATUSES+=("$5")
  RESULT_DURATIONS+=("$6")
  RESULT_ASSERTIONS+=("$7")
  RESULT_MESSAGES+=("$8")
}

# Milliseconds since the epoch, used to time each test case.
#
# EPOCHREALTIME is a bash 5 builtin, which both the Docker image and the CI
# runners have. Where it is missing (macOS still ships bash 3.2) the report falls
# back on whole seconds rather than on nothing
function current_time_in_milliseconds() {
  if [ -n "${EPOCHREALTIME:-}" ]; then
    # "1712345678.901234", or with a comma depending on the locale, so the
    # separator is matched as a class rather than as a literal dot
    local -r SECONDS_PART="${EPOCHREALTIME%[.,]*}"
    local -r MICROSECONDS_PART="${EPOCHREALTIME#*[.,]}"
    printf '%s' "$((SECONDS_PART * 1000 + 10#${MICROSECONDS_PART:0:6} / 1000))"
    return 0
  fi

  printf '%s' "$(($(date +%s) * 1000))"
}

# "1234" -> "1.234", the duration format both reports use
function format_duration() {
  printf '%d.%03d' "$(($1 / 1000))" "$(($1 % 1000))"
}

# Replace the characters XML gives a meaning to, and drop the control characters
# XML 1.0 forbids outright (an escape sequence caught in a captured output would
# otherwise produce a report no parser accepts)
function xml_escaped() {
  local TEXT="$1"
  TEXT="${TEXT//&/&amp;}"
  TEXT="${TEXT//</&lt;}"
  TEXT="${TEXT//>/&gt;}"
  TEXT="${TEXT//\"/&quot;}"
  printf '%s' "$TEXT" | tr -d '\000-\010\013\014\016-\037'
}

# Write a JUnit XML report, one <testsuite> per test case file
# Usage : write_junit_report "$FILE"
function write_junit_report() {
  local -r REPORT_FILE="$1"

  mkdir -p "$(dirname "$REPORT_FILE")" || return 1

  local TOTAL_DURATION=0
  local INDEX
  for ((INDEX = 0; INDEX < ${#RESULT_NAMES[@]}; INDEX++)); do
    TOTAL_DURATION=$((TOTAL_DURATION + RESULT_DURATIONS[INDEX]))
  done

  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<testsuites name="Dell iDRAC fan controller" tests="%d" failures="%d" skipped="%d" time="%s">\n' \
      "${#RESULT_NAMES[@]}" "$FAILED_TEST_CASES" "$SKIPPED_TEST_CASES" "$(format_duration "$TOTAL_DURATION")"

    local SUITE
    while IFS= read -r SUITE; do
      _write_junit_testsuite "$SUITE"
    done < <(printf '%s\n' "${RESULT_SUITES[@]}" | awk '!seen[$0]++')

    printf '</testsuites>\n'
  } > "$REPORT_FILE"
}

# Write the <testsuite> element of a single test case file
function _write_junit_testsuite() {
  local -r SUITE="$1"

  local SUITE_TESTS=0 SUITE_FAILURES=0 SUITE_SKIPPED=0 SUITE_DURATION=0
  local INDEX
  for ((INDEX = 0; INDEX < ${#RESULT_NAMES[@]}; INDEX++)); do
    [ "${RESULT_SUITES[INDEX]}" == "$SUITE" ] || continue
    ((SUITE_TESTS++))
    SUITE_DURATION=$((SUITE_DURATION + RESULT_DURATIONS[INDEX]))
    case "${RESULT_STATUSES[INDEX]}" in
      failed) ((SUITE_FAILURES++)) ;;
      skipped) ((SUITE_SKIPPED++)) ;;
    esac
  done

  printf '  <testsuite name="%s" tests="%d" failures="%d" skipped="%d" time="%s">\n' \
    "$(xml_escaped "$SUITE")" "$SUITE_TESTS" "$SUITE_FAILURES" "$SUITE_SKIPPED" \
    "$(format_duration "$SUITE_DURATION")"

  for ((INDEX = 0; INDEX < ${#RESULT_NAMES[@]}; INDEX++)); do
    [ "${RESULT_SUITES[INDEX]}" == "$SUITE" ] || continue

    printf '    <testcase classname="%s" name="%s" time="%s">\n' \
      "$(xml_escaped "$SUITE")" "$(xml_escaped "${RESULT_NAMES[INDEX]}")" \
      "$(format_duration "${RESULT_DURATIONS[INDEX]}")"

    case "${RESULT_STATUSES[INDEX]}" in
      failed)
        # The first line of the diagnostics is the assertion's own message, the
        # rest is what it expected and what it got. The message attribute is what
        # a CI shows as the failure's headline, the body is the detail behind it
        local HEADLINE="${RESULT_MESSAGES[INDEX]%%$'\n'*}"
        printf '      <failure message="%s" type="assertion">%s</failure>\n' \
          "$(xml_escaped "$HEADLINE")" "$(xml_escaped "${RESULT_MESSAGES[INDEX]}")"
        ;;
      skipped)
        printf '      <skipped message="%s"/>\n' "$(xml_escaped "${RESULT_MESSAGES[INDEX]}")"
        ;;
    esac

    # What the test case is, and how to run it again on its own. This is the
    # context a reader needs that the test name alone does not carry
    printf '      <system-out>%s</system-out>\n' \
      "$(xml_escaped "$(printf '%s assertions in %s\ntests/run_tests.sh --filter %s' \
        "${RESULT_ASSERTIONS[INDEX]}" "${RESULT_FILES[INDEX]}" "${RESULT_FUNCTIONS[INDEX]}")")"

    printf '    </testcase>\n'
  done

  printf '  </testsuite>\n'
}

# Fence a block of diagnostics so that it survives Markdown rendering
function markdown_code_block() {
  # A backtick fence inside the content would end the block early
  local -r CONTENT="${1//\`\`\`/\'\'\'}"

  printf '```text\n%s\n```\n' "$CONTENT"
}

# Append a Markdown report to a file, written for $GITHUB_STEP_SUMMARY : a
# headline, the failures in full, then every test case that ran
# Usage : write_markdown_summary "$FILE"
function write_markdown_summary() {
  local -r SUMMARY_FILE="$1"

  mkdir -p "$(dirname "$SUMMARY_FILE")" || return 1

  local TOTAL_DURATION=0
  local INDEX
  for ((INDEX = 0; INDEX < ${#RESULT_NAMES[@]}; INDEX++)); do
    TOTAL_DURATION=$((TOTAL_DURATION + RESULT_DURATIONS[INDEX]))
  done

  {
    printf '## Dell iDRAC fan controller test suite\n\n'

    if [ "$FAILED_TEST_CASES" -eq 0 ]; then
      printf '**%d test cases passed**' "$PASSED_TEST_CASES"
    else
      printf '**%d test cases failed**, %d passed' "$FAILED_TEST_CASES" "$PASSED_TEST_CASES"
    fi
    if [ "$SKIPPED_TEST_CASES" -gt 0 ]; then
      printf ', %d skipped' "$SKIPPED_TEST_CASES"
    fi
    printf ' — %d assertions in %ss, against a mocked `ipmitool`\n\n' \
      "$TOTAL_ASSERTIONS" "$(format_duration "$TOTAL_DURATION")"

    if [ "$FAILED_TEST_CASES" -gt 0 ]; then
      _write_markdown_failures
    fi

    _write_markdown_suite_table
    _write_markdown_every_test_case
  } >> "$SUMMARY_FILE"
}

function _write_markdown_failures() {
  printf '### Failures\n\n'

  local INDEX
  for ((INDEX = 0; INDEX < ${#RESULT_NAMES[@]}; INDEX++)); do
    [ "${RESULT_STATUSES[INDEX]}" == "failed" ] || continue

    printf '#### %s — %s\n\n' "${RESULT_SUITES[INDEX]}" "${RESULT_NAMES[INDEX]}"
    markdown_code_block "${RESULT_MESSAGES[INDEX]}"
    printf '\nIn `%s`. Run it again on its own with :\n\n' "${RESULT_FILES[INDEX]}"
    markdown_code_block "tests/run_tests.sh --filter ${RESULT_FUNCTIONS[INDEX]}"
    printf '\n'
  done
}

function _write_markdown_suite_table() {
  printf '| Suite | Test cases | Assertions | Time |\n'
  printf '| --- | ---: | ---: | ---: |\n'

  local SUITE
  while IFS= read -r SUITE; do
    local SUITE_TESTS=0 SUITE_FAILURES=0 SUITE_SKIPPED=0 SUITE_ASSERTIONS=0 SUITE_DURATION=0
    local INDEX
    for ((INDEX = 0; INDEX < ${#RESULT_NAMES[@]}; INDEX++)); do
      [ "${RESULT_SUITES[INDEX]}" == "$SUITE" ] || continue
      ((SUITE_TESTS++))
      SUITE_ASSERTIONS=$((SUITE_ASSERTIONS + RESULT_ASSERTIONS[INDEX]))
      SUITE_DURATION=$((SUITE_DURATION + RESULT_DURATIONS[INDEX]))
      case "${RESULT_STATUSES[INDEX]}" in
        failed) ((SUITE_FAILURES++)) ;;
        skipped) ((SUITE_SKIPPED++)) ;;
      esac
    done

    local SUITE_COUNTS="$SUITE_TESTS"
    if [ "$SUITE_FAILURES" -gt 0 ]; then
      SUITE_COUNTS="$SUITE_TESTS ($SUITE_FAILURES failed)"
    elif [ "$SUITE_SKIPPED" -gt 0 ]; then
      SUITE_COUNTS="$SUITE_TESTS ($SUITE_SKIPPED skipped)"
    fi

    printf '| %s %s | %s | %d | %ss |\n' \
      "$(_markdown_suite_icon "$SUITE_FAILURES" "$SUITE_SKIPPED")" "$SUITE" \
      "$SUITE_COUNTS" "$SUITE_ASSERTIONS" "$(format_duration "$SUITE_DURATION")"
  done < <(printf '%s\n' "${RESULT_SUITES[@]}" | awk '!seen[$0]++')

  printf '\n'
}

function _markdown_suite_icon() {
  if [ "$1" -gt 0 ]; then
    printf ':x:'
  elif [ "$2" -gt 0 ]; then
    printf ':fast_forward:'
  else
    printf ':white_check_mark:'
  fi
}

function _write_markdown_every_test_case() {
  printf '<details>\n<summary>Every test case that ran</summary>\n\n'

  local SUITE
  while IFS= read -r SUITE; do
    printf '**%s**\n\n' "$SUITE"
    printf '| | Test case | Assertions | Time |\n'
    printf '| --- | --- | ---: | ---: |\n'

    local INDEX
    for ((INDEX = 0; INDEX < ${#RESULT_NAMES[@]}; INDEX++)); do
      [ "${RESULT_SUITES[INDEX]}" == "$SUITE" ] || continue

      local ICON=':white_check_mark:' DETAIL="${RESULT_ASSERTIONS[INDEX]}"
      case "${RESULT_STATUSES[INDEX]}" in
        failed) ICON=':x:' ;;
        skipped) ICON=':fast_forward:'; DETAIL="skipped, ${RESULT_MESSAGES[INDEX]}" ;;
      esac

      printf '| %s | %s | %s | %ss |\n' "$ICON" "${RESULT_NAMES[INDEX]}" "$DETAIL" \
        "$(format_duration "${RESULT_DURATIONS[INDEX]}")"
    done

    printf '\n'
  done < <(printf '%s\n' "${RESULT_SUITES[@]}" | awk '!seen[$0]++')

  printf '</details>\n'
}
