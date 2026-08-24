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

# Commit under a chosen author, with a chosen Signed-off-by, which is what the two
# identities #441 settled are made of : the author says who wrote it, the trailer
# says who certifies it
# Usage : commit_authored_by "<name>" "<email>" "<subject>" ["<sign-off value>"]
function commit_authored_by() {
  local -r AUTHOR_NAME="$1"
  local -r AUTHOR_EMAIL="$2"
  local -r SUBJECT="$3"
  local -r SIGN_OFF="${4:-}"

  printf '%s\n' "$SUBJECT" >> file.txt
  git add file.txt

  if [ -n "$SIGN_OFF" ]; then
    git -c "user.name=$AUTHOR_NAME" -c "user.email=$AUTHOR_EMAIL" \
      commit --quiet -m "$SUBJECT" --trailer "Signed-off-by: $SIGN_OFF" --no-verify
    return
  fi

  git -c "user.name=$AUTHOR_NAME" -c "user.email=$AUTHOR_EMAIL" \
    commit --quiet -m "$SUBJECT" --no-verify
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

function test_a_message_that_merely_quotes_the_rule_certifies_nothing() {
  # The hole the shape check alone leaves open, and the one this repository walks
  # into rather than a hypothetical : its commit messages quote the rule while
  # explaining it, and CONTRIBUTING.md's own example is a well-formed sign-off
  # line. Pasted into a paragraph it certifies nobody, git reports no trailer on
  # such a commit -- and a search of the message body reports a match.
  #
  # Measured before this case existed : the check answered "All 1 commits carry a
  # sign-off" over a commit git itself says has none. Reading git's trailer parser
  # rather than the body is what tells the two apart
  if ! sign_off_check_can_run; then
    skip_test "no .github next to the scripts, or no git"
    return 0
  fi

  setup_sign_off_sandbox || return 1

  printf 'quoted\n' >> file.txt
  git add file.txt
  git commit --quiet --no-verify -m "Explain what the rule is" -m "CONTRIBUTING.md shows the shape :
Signed-off-by: Random J Developer <random@developer.example.org>
which this quotes without doing." -m "A paragraph after it, so the quotation is not the last one."

  local OUTPUT STATUS
  OUTPUT="$(run_sign_off_check "$BASE" HEAD)" && STATUS=0 || STATUS=$?

  assert_equals "1" "$STATUS" "a body quoting the trailer is not a trailer, and the check must refuse it"

  # The premise, asserted rather than assumed : git records no trailer here, while
  # the string is plainly in the message. That gap is the whole case
  local -r TRAILERS="$(git log -1 --format='%(trailers:key=Signed-off-by,valueonly)' HEAD)"
  local -r MESSAGE="$(git log -1 --format='%B' HEAD)"
  assert_empty "${TRAILERS//[[:space:]]/}" "git should record no trailer on this commit"
  assert_contains "$MESSAGE" "Signed-off-by: Random J Developer" \
    "while the message plainly carries the line, which is what a body search would have matched"

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

# The identities #441 settled, and the one direction a workflow can check : a commit
# the agent AUTHORED must not also certify under it. See issue #446
readonly AGENT_SIGN_OFF="Claude <noreply@anthropic.com>"
readonly MAINTAINER_SIGN_OFF="Tigerblue77 <37409593+tigerblue77@users.noreply.github.com>"

function test_a_commit_the_agent_authored_and_certified_under_is_refused() {
  # The accident this exists for, measured on the first head of #442 : a session that
  # started before the hook did, or ran an older one, produces a commit whose trailer
  # names a tool. It carried a well-formed sign-off and passed the gate green
  sign_off_check_can_run || { skip_test "git or the sign-off script is missing"; return 0; }
  setup_sign_off_sandbox || return 1

  commit_authored_by "Claude" "noreply@anthropic.com" "Written and certified by the tool" "$AGENT_SIGN_OFF"

  local HEAD
  HEAD="$(git rev-parse HEAD)"

  local OUTPUT
  OUTPUT=$(run_sign_off_check "$BASE" "$HEAD")
  local -r STATUS=$?

  assert_not_equals 0 "$STATUS" "a tool certifying its own work should not pass"
  assert_contains "$OUTPUT" "authored by the agent" "the error should say what it found"
  assert_contains "$OUTPUT" "git signoff" "and name the command that repairs it"
  assert_not_contains "$OUTPUT" "carries no Signed-off-by" \
    "it carries one ; saying otherwise would send the reader to the wrong remedy"

  teardown_sign_off_sandbox
}

function test_a_commit_the_agent_authored_and_the_maintainer_certified_is_accepted() {
  # The arrangement #441 put in place, and the one "git signoff" produces
  sign_off_check_can_run || { skip_test "git or the sign-off script is missing"; return 0; }
  setup_sign_off_sandbox || return 1

  commit_authored_by "Claude" "noreply@anthropic.com" "Written by the tool, certified by the maintainer" "$MAINTAINER_SIGN_OFF"

  local HEAD
  HEAD="$(git rev-parse HEAD)"

  local OUTPUT
  OUTPUT=$(run_sign_off_check "$BASE" "$HEAD")
  local -r STATUS=$?

  assert_equals 0 "$STATUS" "this is exactly what the hook sets up"
  assert_contains "$OUTPUT" "carry a sign-off" "and it should be reported clean"

  teardown_sign_off_sandbox
}

function test_a_contributor_certifying_their_own_work_is_left_alone() {
  # The half that is NOT closable, and the reason the check is conditional on the
  # agent identity rather than on "author equals sign-off" : that shape is the normal
  # and correct one for everybody who is not a tool, and refusing it would turn this
  # gate on the contributors it was never about
  sign_off_check_can_run || { skip_test "git or the sign-off script is missing"; return 0; }
  setup_sign_off_sandbox || return 1

  commit_authored_by "Random J Developer" "random@developer.example.org" \
    "Mine, and I certify it" "Random J Developer <random@developer.example.org>"

  local HEAD
  HEAD="$(git rev-parse HEAD)"

  local OUTPUT
  OUTPUT=$(run_sign_off_check "$BASE" "$HEAD")
  local -r STATUS=$?

  assert_equals 0 "$STATUS" "an outside contributor authors and certifies their own work"
  assert_not_contains "$OUTPUT" "authored by the agent" "and is not the subject of this check"

  teardown_sign_off_sandbox
}

function test_the_sign_off_gate_knows_the_identities_the_hook_sets() {
  # The gate runs in a workflow that never sources the hook, so the two addresses are
  # written in both files. Held together here rather than left to agree by hand : a
  # change to either that missed the other would not fail, it would quietly stop
  # matching, and the gate would go green on the very commits it exists to refuse.
  #
  # Read allowing indentation on the hook's side : those constants sit inside the branch
  # that only runs where this repository is the origin (#459), and an anchored read of them
  # is exactly the "quietly stops matching" this case was written about
  local -r HOOK="$REPO_ROOT/.claude/hooks/session-start.sh"

  if [ ! -f "$HOOK" ] || [ ! -f "$REPO_ROOT/$SIGN_OFF_SCRIPT" ]; then
    skip_test "no hook and sign-off script next to the scripts"
    return 0
  fi

  local HOOK_AGENT_EMAIL GATE_AGENT_EMAIL
  HOOK_AGENT_EMAIL=$(sed -n 's/^[[:space:]]*readonly AGENT_EMAIL="\(.*\)"$/\1/p' "$HOOK")
  GATE_AGENT_EMAIL=$(sed -n 's/^readonly AGENT_EMAIL="\(.*\)"$/\1/p' "$REPO_ROOT/$SIGN_OFF_SCRIPT")

  assert_not_empty "$HOOK_AGENT_EMAIL" "the hook should state the address it authors under" || return 1
  assert_equals "$HOOK_AGENT_EMAIL" "$GATE_AGENT_EMAIL" \
    "the gate has to look for the address the hook actually authors under"

  local HOOK_SIGN_OFF_EMAIL GATE_SIGN_OFF_EMAIL
  HOOK_SIGN_OFF_EMAIL=$(sed -n 's/^[[:space:]]*readonly SIGN_OFF_EMAIL="\(.*\)"$/\1/p' "$HOOK")
  GATE_SIGN_OFF_EMAIL=$(sed -n 's/^readonly SIGN_OFF_EMAIL="\(.*\)"$/\1/p' "$REPO_ROOT/$SIGN_OFF_SCRIPT")

  assert_not_empty "$HOOK_SIGN_OFF_EMAIL" "and the address it puts on the trailer" || return 1
  assert_equals "$HOOK_SIGN_OFF_EMAIL" "$GATE_SIGN_OFF_EMAIL" \
    "the gate has to accept the address the hook actually signs off under"
}

function test_the_shape_the_first_head_of_442_had_is_refused() {
  # Reconstructed exactly : authored by the maintainer, certified by the maintainer,
  # with the agent in Co-Authored-By. That is #421's arrangement, made after #441
  # replaced it, and it passed this gate green -- which is what issue #446 is
  sign_off_check_can_run || { skip_test "git or the sign-off script is missing"; return 0; }
  setup_sign_off_sandbox || return 1

  printf 'the shape 442 had\n' >> file.txt
  git add file.txt
  git -c "user.name=Tigerblue77" -c "user.email=37409593+tigerblue77@users.noreply.github.com" \
    commit --quiet -m "Written by the tool, recorded as the maintainer's" \
    --trailer "Co-Authored-By: $AGENT_SIGN_OFF" \
    --trailer "Signed-off-by: $MAINTAINER_SIGN_OFF" --no-verify

  local HEAD
  HEAD="$(git rev-parse HEAD)"

  local OUTPUT
  OUTPUT=$(run_sign_off_check "$BASE" "$HEAD")
  local -r STATUS=$?

  assert_not_equals 0 "$STATUS" "the arrangement #441 replaced should not pass any more"
  assert_contains "$OUTPUT" "names the agent as a co-author" "the error should say what it found"
  assert_contains "$OUTPUT" "--reset-author" "and name what repairs it"

  teardown_sign_off_sandbox
}

function test_a_redundant_co_author_on_a_commit_the_agent_authored_is_left_alone() {
  # The author field already says it, so the trailer adds nothing -- but it contradicts
  # nothing either, and refusing it would fail a commit whose two identities are both
  # already right
  sign_off_check_can_run || { skip_test "git or the sign-off script is missing"; return 0; }
  setup_sign_off_sandbox || return 1

  printf 'redundant\n' >> file.txt
  git add file.txt
  git -c "user.name=Claude" -c "user.email=noreply@anthropic.com" \
    commit --quiet -m "Authored by the tool, and saying so twice" \
    --trailer "Co-Authored-By: $AGENT_SIGN_OFF" \
    --trailer "Signed-off-by: $MAINTAINER_SIGN_OFF" --no-verify

  local HEAD
  HEAD="$(git rev-parse HEAD)"

  local OUTPUT
  OUTPUT=$(run_sign_off_check "$BASE" "$HEAD")
  local -r STATUS=$?

  assert_equals 0 "$STATUS" "both identities are right ; the extra trailer is redundant, not wrong"

  teardown_sign_off_sandbox
}
