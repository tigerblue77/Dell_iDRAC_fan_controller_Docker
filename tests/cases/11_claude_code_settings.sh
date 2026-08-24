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

# The suite also runs inside the built image, which carries the shipped scripts and
# none of the files a contributor works with : no .github, no .claude.
#
# jq is the second condition. The list is read out of a JSON file, and reading JSON
# with sed is how the first version of this guard came to stop at the first "]" of a
# rule and report green over everything that followed it. Two rewrites that kept to
# grep and awk were tried and measured against jq : both mis-read a rule holding an
# escaped quote, "Bash(grep -E \"[0-9]\":*)", and one of them stopped there and never
# saw the two entries after it. A rule can contain any character JSON can carry, so
# what reads it has to be a JSON parser.
#
# The suite's own dependencies stop at bash, coreutils, grep and awk, so a machine
# without jq skips these rather than turning the promise in tests/README.md into a
# lie -- the same trade cases/14 makes. The skip is reported rather than silent, the
# runner counts it, and every runner, the devcontainer and the SessionStart hook
# provide jq : what gates a pull request runs these for real
# Usage : if ! claude_code_settings_can_be_read; then skip_test "..."; return 0; fi
function claude_code_settings_can_be_read() {
  [ -f "$REPO_ROOT/$CLAUDE_CODE_SETTINGS_FILE" ] && command -v jq > /dev/null 2>&1
}

# The permission rules the settings pre-approve, one per line, exactly as written
function pre_approved_permission_rules() {
  jq -r '.permissions.allow[]?' "$REPO_ROOT/$CLAUDE_CODE_SETTINGS_FILE" 2> /dev/null
}

# The command a permission rule pre-approves, stripped of the "Bash(...)" wrapper and
# of the ":*" that makes a rule match a prefix rather than one exact command line :
# "Bash(shellcheck:*)" reads back as "shellcheck". A rule of any other shape is
# returned untouched, which is what makes it fail the guard below rather than pass it
# under a wrong name
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
  if ! claude_code_settings_can_be_read; then
    skip_test "no .claude next to the scripts, or no jq to read it with"
    return 0
  fi

  assert_command_succeeds "$CLAUDE_CODE_SETTINGS_FILE should parse, a settings file that does not is ignored whole" \
    jq empty "$REPO_ROOT/$CLAUDE_CODE_SETTINGS_FILE"
}

function test_every_pre_approved_rule_is_one_that_was_argued() {
  # The rules #382 settled on, and the shape each of them is written in. Both halves
  # matter, which is why this compares whole rules rather than the commands inside
  # them : ":*" is not decoration, it pre-approves every argument list there is, and
  # an argument list is where a harmless command stops being one.
  #
  # - Bash(./tests/run_tests.sh) is EXACT, deliberately. Run with no arguments the
  #   suite mocks ipmitool, lm-sensors and sleep, needs no iDRAC and no network, and
  #   writes only inside the throwaway directory it makes with mktemp -d. Run as
  #   "--junit FILE" or "--summary FILE" it creates directories and writes wherever
  #   the caller points it -- truncating for the first, appending for the second
  #   (tests/lib/reports.sh) -- which a prefix rule would hand to every session
  #   without a prompt. Filtered runs are one prompt each ;
  #   that is the price of the entry staying what it claims to be.
  # - Bash(shellcheck:*) and Bash(bash -n:*) are prefixes, which is safe here for the
  #   reason the first one is not : neither has an option that names a file to write.
  #   They read, they analyse, and bash -n parses without running a statement of it.
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
  if ! claude_code_settings_can_be_read; then
    skip_test "no .claude next to the scripts, or no jq to read it with"
    return 0
  fi

  local -r PERMISSION_RULES=$(pre_approved_permission_rules)

  # Without this the loop below would report green by having nothing to iterate
  # over, which is the failure mode these guards exist to prevent in the first place
  assert_not_empty "$PERMISSION_RULES" \
    "$CLAUDE_CODE_SETTINGS_FILE should pre-approve the repository's routine commands, or this guard watches nothing" ||
    return 1

  local RULE
  while IFS= read -r RULE; do
    case "$RULE" in
      'Bash(./tests/run_tests.sh)' | 'Bash(shellcheck:*)' | 'Bash(bash -n:*)')
        pass ;;
      'Bash(./tests/run_tests.sh:*)')
        fail "[$RULE] grants the suite by prefix, which pre-approves every argument list it takes" \
          "--junit FILE and --summary FILE create directories and write wherever the caller points them" \
          "the rule that was argued is the exact one : Bash(./tests/run_tests.sh)" ;;
      *)
        fail "[$RULE] is pre-approved for every session opened on this repository, and it is not one of the rules #382 argued for" \
          "the vetted ones are : Bash(./tests/run_tests.sh), Bash(shellcheck:*), Bash(bash -n:*)" \
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
  if ! claude_code_settings_can_be_read; then
    skip_test "no .claude next to the scripts, or no jq to read it with"
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
        # The syntax check in cases/10, which is the only thing in the suite that
        # runs it. A comment does not count : cases/10 names the command in one of
        # its own comments, so a plain search for the string stayed green with the
        # function that runs it deleted -- and this file names it more often still.
        # Comments are skipped the way cases/10 skips them for the same reason, and
        # this file is left out of the search altogether
        local THIS_CASE_FILE
        THIS_CASE_FILE=$(basename "${BASH_SOURCE[0]}")

        if grep -rqE --exclude="$THIS_CASE_FILE" -- '^[^#]*bash -n' "$TESTS_DIRECTORY/cases"; then
          pass
        else
          fail "bash -n is pre-approved but nothing in the suite runs it any more"
        fi ;;
      *)
        fail "nothing in the tree proves this repository still runs [$COMMAND]" \
          "a pre-approved command needs a reason to stay pre-approved" ;;
    esac
  done < <(pre_approved_permission_rules)
}
