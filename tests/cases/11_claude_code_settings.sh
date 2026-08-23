#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# The settings a Claude Code session starts from, under .claude/.
#
# Nothing in there reaches a server : the file holds the SessionStart hook that
# installs the linter CI gates on, and the list of commands a session may run
# without stopping to ask for a human's approval first.
#
# That list is a standing grant. It is not given to the person who wrote it, it is
# given to every session ever opened on this repository, including one acting on a
# prompt that came from a pull request body, an issue comment or a fetched page. So
# what belongs in it was argued rather than assumed (issue #382), and this file is
# where that argument is held against the settings : one guard for what the list may
# contain, one for whether the repository still runs what it names.

readonly CLAUDE_CODE_SETTINGS_FILE=".claude/settings.json"

# The permission rules the settings pre-approve, one per line, exactly as written.
#
# jq is not a dependency of this suite -- tests/README.md promises it runs on bash,
# coreutils, grep and awk alone -- and this file is small, hand-written and ours, so
# the array is isolated by its key and then read one quoted string at a time
function pre_approved_permission_rules() {
  local -r SETTINGS_ON_ONE_LINE=$(tr '\n' ' ' < "$REPO_ROOT/$CLAUDE_CODE_SETTINGS_FILE")
  local -r ALLOW_LIST=$(printf '%s' "$SETTINGS_ON_ONE_LINE" | sed -n 's/.*"allow"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p')

  printf '%s' "$ALLOW_LIST" | grep -oE '"[^"]*"' | tr -d '"'
}

# The command a permission rule pre-approves, stripped of the "Bash(...)" wrapper
# and of the ":*" that makes the rule match a prefix : "Bash(shellcheck:*)" reads
# back as "shellcheck". A rule of any other shape is returned untouched, which is
# what makes it fail the guard below rather than pass it under a wrong name
# Usage : pre_approved_command "Bash(shellcheck:*)" -> "shellcheck"
function pre_approved_command() {
  local RULE="$1"

  if [[ "$RULE" == Bash\(*\) ]]; then
    RULE="${RULE#Bash(}"
    RULE="${RULE%)}"
    RULE="${RULE%':*'}"
  fi

  printf '%s' "$RULE"
}

function test_the_claude_code_settings_are_valid_json() {
  # A settings file that does not parse is not a settings file with one broken
  # entry : the whole of it is dropped, silently. The SessionStart hook stops
  # installing shellcheck, the permission list stops pre-approving anything, and
  # the only symptom is a session that asks about everything again -- which reads
  # as "the grant was refused" rather than as "the JSON has a trailing comma"
  if [ ! -f "$REPO_ROOT/$CLAUDE_CODE_SETTINGS_FILE" ]; then
    # The suite is running inside the built image, which carries the shipped
    # scripts and none of the files a contributor works with
    skip_test "no .claude next to the scripts"
    return 0
  fi

  if ! command -v jq > /dev/null 2>&1; then
    # Same reasoning as cases/14 : the suite's own dependencies stop at bash,
    # coreutils, grep and awk, so a machine without jq skips this rather than
    # turning the promise in tests/README.md into a lie. Every runner, the
    # devcontainer and the SessionStart hook provide it
    skip_test "jq is missing"
    return 0
  fi

  assert_command_succeeds "$CLAUDE_CODE_SETTINGS_FILE should parse, a settings file that does not is ignored whole" \
    jq empty "$REPO_ROOT/$CLAUDE_CODE_SETTINGS_FILE"
}

function test_every_pre_approved_command_is_read_only_or_sandboxed() {
  # The three rules #382 settled on share one property : none of them can change
  # anything outside the tree, whoever asked for them to run.
  #
  # - ./tests/run_tests.sh mocks ipmitool, lm-sensors and sleep, needs no iDRAC and
  #   no network, and writes only under its own temporary directory
  # - shellcheck reads the scripts, analyses them, and executes none of them
  # - bash -n parses a script without running a single statement of it
  # (the dashes are not decoration : a comment line beginning with the linter's own
  # name is read by it as a directive, and refuses to parse)
  #
  # Two commands were argued out and are meant to stay out. "git" : "git diff" is
  # harmless, but the prefix matching that would allow it is easy to widen by
  # accident and the blast radius of getting it wrong once is the branch.
  # "docker build" : it runs apt-get against the network as root inside the build,
  # which is not something to grant standing approval to for the sake of one prompt.
  #
  # Nothing in Claude Code will ever refuse a fourth entry, so this is the only
  # place that can : a rule outside the vetted set fails here, and widening the
  # grant means coming back to this comment and arguing the new one the same way
  if [ ! -f "$REPO_ROOT/$CLAUDE_CODE_SETTINGS_FILE" ]; then
    skip_test "no .claude next to the scripts"
    return 0
  fi

  local -r PERMISSION_RULES=$(pre_approved_permission_rules)

  # Without this the loop below would report green by having nothing to iterate
  # over, which is the failure mode these guards exist to prevent in the first place
  assert_not_empty "$PERMISSION_RULES" \
    "$CLAUDE_CODE_SETTINGS_FILE should pre-approve the repository's routine commands, or this guard watches nothing" ||
    return 1

  local RULE COMMAND
  while IFS= read -r RULE; do
    COMMAND=$(pre_approved_command "$RULE")

    case "$COMMAND" in
      './tests/run_tests.sh' | 'shellcheck' | 'bash -n')
        pass ;;
      *)
        fail "[$RULE] is pre-approved for every session opened on this repository, and it is not one of the commands #382 argued for" \
          "the vetted ones are : ./tests/run_tests.sh (mocked and self-contained), shellcheck and bash -n (analysers that run nothing)" \
          "git and docker build were deliberately left out ; a new entry has to be argued the same way, here and in the settings" ;;
    esac
  done < <(printf '%s\n' "$PERMISSION_RULES")
}

function test_every_pre_approved_command_is_one_the_repository_still_runs() {
  # The other end of the same list. A grant that outlives the command it was given
  # for is a grant nobody reads again : the session goes back to asking about
  # everything, the entry stays in the file looking deliberate, and the next
  # person to widen the list starts from a list already half wrong.
  #
  # Each command is held to the thing in the tree that proves the repository still
  # runs it, rather than to a second copy of the list
  if [ ! -f "$REPO_ROOT/$CLAUDE_CODE_SETTINGS_FILE" ]; then
    skip_test "no .claude next to the scripts"
    return 0
  fi

  local RULE COMMAND
  while IFS= read -r RULE; do
    COMMAND=$(pre_approved_command "$RULE")

    case "$COMMAND" in
      './'*)
        # A path is pre-approved relative to the project directory, which is where
        # a session runs : it has to exist there, and be runnable that way
        if [ -x "$REPO_ROOT/${COMMAND#./}" ]; then
          pass
        else
          fail "$COMMAND is pre-approved but is not an executable file of this repository" \
            "a rule naming a path that moved pre-approves nothing at all"
        fi ;;
      'shellcheck')
        # What makes the grant worth having is that a pull request is gated on it
        if [ -f "$REPO_ROOT/.github/workflows/shellcheck.yml" ]; then
          pass
        else
          fail "shellcheck is pre-approved but no workflow gates a pull request on it any more"
        fi ;;
      'bash -n')
        # The syntax check cases/10 runs over every script of the repository. This
        # file is the one place the search leaves out : it names the command in
        # every second comment, and would answer the question with itself
        local THIS_CASE_FILE
        THIS_CASE_FILE=$(basename "${BASH_SOURCE[0]}")

        if grep -rqF --exclude="$THIS_CASE_FILE" -- 'bash -n' "$TESTS_DIRECTORY/cases"; then
          pass
        else
          fail "bash -n is pre-approved but the suite does not run it any more"
        fi ;;
      *)
        fail "nothing in the tree proves this repository still runs [$COMMAND]" \
          "a pre-approved command needs a reason to stay pre-approved" ;;
    esac
  done < <(pre_approved_permission_rules)
}
