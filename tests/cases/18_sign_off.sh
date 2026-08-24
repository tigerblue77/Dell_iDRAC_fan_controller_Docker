#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# The gate that keeps an unsigned commit off master, from the pull request it
# arrives on (issue #388).
#
# CONTRIBUTING.md has required a Signed-off-by on every commit for as long as it
# has existed, and CLAUDE.md repeats it to every session. Nothing looked for one :
# 7 of the last 30 commits on master carried it when the check was written. What
# is exercised here is the decision, on a real repository built for each case --
# git is the thing under test as much as the script is, and a stub for it would
# only prove that the stub agrees with itself.
#
# The sandbox is a repository of its own under a temporary directory, with its own
# identity configured locally, so nothing here reads or writes the contributor's
# git configuration and no test depends on how the machine running it is set up.

readonly SIGN_OFF_SCRIPT=".github/check_sign_off.sh"
readonly SIGN_OFF_WORKFLOW=".github/workflows/sign_off.yml"

# The suite also runs inside the built image, which carries the shipped scripts
# and neither the .github directory nor git.
# Usage : if ! sign_off_check_can_run; then skip_test "..."; return 0; fi
function sign_off_check_can_run() {
  [ -x "$REPO_ROOT/$SIGN_OFF_SCRIPT" ] && command -v git > /dev/null 2>&1
}

# A repository with one commit on its base branch, and the base SHA exported as
# BASE for the cases to build on.
# Usage : setup_sign_off_sandbox
function setup_sign_off_sandbox() {
  SANDBOX="$(mktemp -d)"
  cd "$SANDBOX" || return 1

  git init --quiet --initial-branch=master .
  git config user.name "Base Author"
  git config user.email "base@example.org"
  git config commit.gpgsign false

  printf 'base\n' > file.txt
  git add file.txt
  git commit --quiet -m "The commit the branch starts from" --no-verify

  BASE="$(git rev-parse HEAD)"
}

# Usage : teardown_sign_off_sandbox
function teardown_sign_off_sandbox() {
  cd "$REPO_ROOT" || return 1
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
}

# Usage : commit_signed "<subject>" ; commit_unsigned "<subject>"
function commit_signed() {
  printf '%s\n' "$1" >> file.txt
  git add file.txt
  git commit --quiet -s -m "$1" --no-verify
}

function commit_unsigned() {
  printf '%s\n' "$1" >> file.txt
  git add file.txt
  git commit --quiet -m "$1" --no-verify
}

# Usage : OUTPUT=$(run_sign_off_check <base> <head>) ; STATUS=$?
function run_sign_off_check() {
  "$REPO_ROOT/$SIGN_OFF_SCRIPT" "$1" "$2" 2>&1
}

function test_a_branch_whose_commits_are_all_signed_is_accepted() {
  if ! sign_off_check_can_run; then
    skip_test "no .github next to the scripts, or no git"
    return 0
  fi

  setup_sign_off_sandbox || return 1

  commit_signed "A first signed contribution"
  commit_signed "A second signed contribution"

  local OUTPUT STATUS
  OUTPUT="$(run_sign_off_check "$BASE" HEAD)" && STATUS=0 || STATUS=$?

  assert_equals "0" "$STATUS" "a branch whose every commit is signed should be accepted"
  assert_contains "$OUTPUT" "All 2 commits" "it should say how many it checked"

  teardown_sign_off_sandbox
}

function test_a_single_unsigned_commit_fails_the_branch() {
  if ! sign_off_check_can_run; then
    skip_test "no .github next to the scripts, or no git"
    return 0
  fi

  setup_sign_off_sandbox || return 1

  commit_signed "A signed contribution"
  commit_unsigned "The one that forgot"

  local OUTPUT STATUS
  OUTPUT="$(run_sign_off_check "$BASE" HEAD)" && STATUS=0 || STATUS=$?

  assert_equals "1" "$STATUS" "one unsigned commit is enough to refuse the branch"
  assert_contains "$OUTPUT" "The one that forgot" \
    "it should name the offending commit rather than only counting it"
  assert_contains "$OUTPUT" "1 of the 2 commits" "it should say how many of how many"

  teardown_sign_off_sandbox
}

function test_every_unsigned_commit_is_reported_and_not_only_the_first() {
  if ! sign_off_check_can_run; then
    skip_test "no .github next to the scripts, or no git"
    return 0
  fi

  setup_sign_off_sandbox || return 1

  commit_unsigned "The first one that forgot"
  commit_signed "A signed contribution"
  commit_unsigned "The second one that forgot"

  local OUTPUT STATUS
  OUTPUT="$(run_sign_off_check "$BASE" HEAD)" && STATUS=0 || STATUS=$?

  assert_equals "1" "$STATUS" "the branch should be refused"
  assert_contains "$OUTPUT" "The first one that forgot" "the first offender should be named"
  assert_contains "$OUTPUT" "The second one that forgot" \
    "a contributor fixing these should see all of them in one run, not one per push"

  teardown_sign_off_sandbox
}

function test_a_merge_commit_is_not_asked_for_a_sign_off() {
  if ! sign_off_check_can_run; then
    skip_test "no .github next to the scripts, or no git"
    return 0
  fi

  setup_sign_off_sandbox || return 1

  # The branch, signed as it should be
  git checkout --quiet -b contribution
  commit_signed "A signed contribution"

  # Meanwhile master moves, which is what makes the merge below necessary
  git checkout --quiet master
  printf 'moved\n' > other.txt
  git add other.txt
  git commit --quiet -s -m "Master moves under the branch" --no-verify
  local -r NEW_BASE="$(git rev-parse HEAD)"

  # Resolving that by merging the base branch in is the correct thing to do, and
  # git writes the merge itself with no sign-off. Refusing the branch for it
  # would punish the contributor who did the right thing
  git checkout --quiet contribution
  git merge --quiet --no-ff --no-edit master

  local OUTPUT STATUS
  OUTPUT="$(run_sign_off_check "$NEW_BASE" HEAD)" && STATUS=0 || STATUS=$?

  assert_equals "0" "$STATUS" \
    "merging the base branch in to resolve a conflict should not fail the pull request"

  teardown_sign_off_sandbox
}

function test_a_sign_off_naming_nobody_is_refused() {
  if ! sign_off_check_can_run; then
    skip_test "no .github next to the scripts, or no git"
    return 0
  fi

  setup_sign_off_sandbox || return 1

  # What a broken git config produces : the trailer's name, and nothing that
  # could certify anything. CONTRIBUTING.md asks for a real name and a reachable
  # address, so the shape is what is checked and not merely the word
  printf 'malformed\n' >> file.txt
  git add file.txt
  git commit --quiet --no-verify -m "A contribution

Signed-off-by:"

  local OUTPUT STATUS
  OUTPUT="$(run_sign_off_check "$BASE" HEAD)" && STATUS=0 || STATUS=$?

  assert_equals "1" "$STATUS" "a trailer with no name and no address certifies nobody"

  teardown_sign_off_sandbox
}

function test_a_sign_off_carrying_no_address_is_refused() {
  if ! sign_off_check_can_run; then
    skip_test "no .github next to the scripts, or no git"
    return 0
  fi

  setup_sign_off_sandbox || return 1

  printf 'nameonly\n' >> file.txt
  git add file.txt
  git commit --quiet --no-verify -m "A contribution

Signed-off-by: Random J Developer"

  local OUTPUT STATUS
  OUTPUT="$(run_sign_off_check "$BASE" HEAD)" && STATUS=0 || STATUS=$?

  assert_equals "1" "$STATUS" "a name with no reachable address is not what CONTRIBUTING.md asks for"

  teardown_sign_off_sandbox
}

function test_a_range_holding_no_commit_is_refused_rather_than_reported_clean() {
  if ! sign_off_check_can_run; then
    skip_test "no .github next to the scripts, or no git"
    return 0
  fi

  setup_sign_off_sandbox || return 1

  # A pull request that genuinely adds nothing is a state nobody needs this
  # job's opinion on. A range that resolves to nothing because the base or the
  # head was computed wrong is the shape of a false green -- a shallow checkout,
  # a branch compared against itself -- and from inside the script the two are
  # indistinguishable. So both land on the refusal : this exists to keep an
  # unsigned commit off master, which makes the red the cheap mistake
  local OUTPUT STATUS
  OUTPUT="$(run_sign_off_check "$BASE" HEAD)" && STATUS=0 || STATUS=$?

  assert_equals "1" "$STATUS" "an empty range is what a miscomputed base looks like, and must not read as clean"
  assert_contains "$OUTPUT" "No commit" "and it should say which range it found empty"

  teardown_sign_off_sandbox
}

function test_a_message_that_merely_quotes_the_rule_certifies_nothing() {
  if ! sign_off_check_can_run; then
    skip_test "no .github next to the scripts, or no git"
    return 0
  fi

  setup_sign_off_sandbox || return 1

  # Commit messages here quote the rule while explaining it -- the commit adding
  # this case does -- so the string travels through the history in bodies that
  # certify nothing. What keeps this refused is the anchoring : the pattern wants
  # the trailer at the start of its own line, carrying a name and an address,
  # rather than the words anywhere in the body.
  #
  # Reading it through "git ... %(trailers:)" instead would not be stronger. Git
  # takes the last paragraph as the trailer block and finds a key:value line
  # inside it wherever it sits, so a quotation placed at the end satisfies the
  # trailer parser too -- measured, not assumed
  printf 'quoting\n' >> file.txt
  git add file.txt
  git commit --quiet --no-verify -m "A change that talks about the rule

CONTRIBUTING.md says a commit without Signed-off-by is not mergeable, which this quotes and does not do."

  local OUTPUT STATUS
  OUTPUT="$(run_sign_off_check "$BASE" HEAD)" && STATUS=0 || STATUS=$?

  assert_equals "1" "$STATUS" "a body quoting the trailer is not a trailer" || return 1

  # The premise, asserted rather than assumed : a plain search really would have
  # been satisfied here, which is what makes the refusal worth pinning
  local MESSAGE
  MESSAGE="$(git log -1 --format='%B' HEAD)"
  assert_contains "$MESSAGE" "Signed-off-by" \
    "the message does carry the string, so a bare grep would have passed this commit"

  teardown_sign_off_sandbox
}

function test_a_range_that_cannot_be_read_fails_closed() {
  if ! sign_off_check_can_run; then
    skip_test "no .github next to the scripts, or no git"
    return 0
  fi

  setup_sign_off_sandbox || return 1

  # What a shallow checkout looks like from here : an end of the range the
  # repository does not have. The answer has to be the refusal, never the pass --
  # a false green is the one outcome this check exists to prevent
  local OUTPUT STATUS
  OUTPUT="$(run_sign_off_check "0000000000000000000000000000000000000000" HEAD)" && STATUS=0 || STATUS=$?

  assert_equals "1" "$STATUS" "an unreadable range should fail closed, not pass"
  assert_contains "$OUTPUT" "fetch-depth" "and should name what makes both ends present"

  teardown_sign_off_sandbox
}

function test_the_sign_off_check_refuses_to_run_without_a_range() {
  if ! sign_off_check_can_run; then
    skip_test "no .github next to the scripts, or no git"
    return 0
  fi

  local STATUS
  "$REPO_ROOT/$SIGN_OFF_SCRIPT" > /dev/null 2>&1 && STATUS=0 || STATUS=$?

  assert_equals "2" "$STATUS" \
    "called wrong is its own answer, told apart from the branch being unsigned"
}

function test_the_sign_off_workflow_runs_the_script_that_holds_the_decision() {
  if [ ! -f "$REPO_ROOT/$SIGN_OFF_WORKFLOW" ]; then
    skip_test "no .github/workflows next to the scripts"
    return 0
  fi

  local -r WORKFLOW="$(cat "$REPO_ROOT/$SIGN_OFF_WORKFLOW")"

  assert_contains "$WORKFLOW" "$SIGN_OFF_SCRIPT" \
    "the workflow should call the script rather than carry a second copy of the rule inline"

  # Without it the checkout is shallow and neither end of base..head is present,
  # which the script can only answer by failing closed -- a red on every pull
  # request, for a reason that is in this file rather than in the contribution
  assert_contains "$WORKFLOW" "fetch-depth: 0" \
    "the script reads base..head, which a shallow checkout does not have"

  # On master it would be permanently red : the unsigned commits already there
  # cannot be signed without rewriting published history
  assert_contains "$WORKFLOW" "pull_request" "the branch's commits are the last place the trailer exists"
  assert_not_contains "$WORKFLOW" "branches: [master]" \
    "running this on master would gate a history that cannot be repaired"
}
