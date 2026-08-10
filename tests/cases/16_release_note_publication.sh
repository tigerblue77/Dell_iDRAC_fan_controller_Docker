#!/bin/bash

# A release note is the announcement that a version is out, and the only artefact
# of a release a human writes into by hand. It is also written by a step that
# only ever runs on a version tag, where no pull request looks : issue #337 was
# found by reading a release page weeks later, and by then v1.71 carried its
# changelog twice and every hand-written upgrade note was standing on the same
# trapdoor.
#
# GitHub is stubbed here, so these exercise the decision and not the API : a fake
# "gh" first in the PATH answers for a repository whose releases the test states.

readonly RELEASE_NOTE_SCRIPT=".github/release_note_already_exists.sh"
readonly RELEASE_NOTE_WORKFLOW=".github/workflows/build_and_publish_docker_image.yml"
readonly RELEASE_NOTE_REPOSITORY="owner/repository"

# The suite also runs inside the built image, which carries the shipped scripts
# but not the .github directory
# Usage : if ! release_note_decision_can_run; then skip_test "..."; return 0; fi
function release_note_decision_can_run() {
  [ -x "$REPO_ROOT/$RELEASE_NOTE_SCRIPT" ]
}

# Builds the world the script runs in : a GitHub it can only see through a
# stubbed gh, which answers for the one release lookup the script makes.
# Usage : setup_release_note_sandbox
function setup_release_note_sandbox() {
  SANDBOX="$(mktemp -d)"
  export MOCK_RELEASE_EXISTS=false
  export MOCK_RELEASE_LOOKUP_ERROR=""
  export MOCK_GH_CALL_LOG="$SANDBOX/gh_calls.log"
  : > "$MOCK_GH_CALL_LOG"

  mkdir -p "$SANDBOX/bin"
  cat > "$SANDBOX/bin/gh" << 'STUB'
#!/bin/bash
# Answers the one API call the script makes, and nothing else. Positional rather
# than parsed : the script calls this with a fixed shape, and a stub that
# accepted more shapes than the real command would hide a call gh itself would
# refuse
#   gh api repos/<repository>/releases/tags/<tag>
set -uo pipefail

printf '%s\n' "$*" >> "$MOCK_GH_CALL_LOG"

case "${1:-}:${2:-}" in
  api:*/releases/tags/*)
    if [ -n "${MOCK_RELEASE_LOOKUP_ERROR:-}" ]; then
      printf '%s\n' "$MOCK_RELEASE_LOOKUP_ERROR" >&2
      exit 1
    fi
    # The wording gh reports a release that does not exist with, and the only
    # one the script may read as "there is none"
    if [ "${MOCK_RELEASE_EXISTS:-false}" != true ]; then
      printf 'gh: Not Found (HTTP 404)\n' >&2
      exit 1
    fi
    ;;
  *)
    printf 'the stub was called in a shape the script is not supposed to use : %s\n' "$*" >&2
    exit 64
    ;;
esac
STUB
  chmod 0755 "$SANDBOX/bin/gh"
  export PATH="$SANDBOX/bin:$PATH"
}

function teardown_release_note_sandbox() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
}

# Everything the stubbed gh was asked, so a lookup about something other than
# the release it was given cannot pass for one about it
# Usage : assert_contains "$(recorded_gh_calls)" "..."
function recorded_gh_calls() {
  cat "$MOCK_GH_CALL_LOG"
}

# The block of one step of the release workflow, from its "- name:" line to the
# line that starts the next step. An assertion against the whole file cannot say
# which step a line belongs to, and "the gate is somewhere in the file" is not
# what has to be true : it has to be on the step that writes the note
# Usage : BLOCK="$(release_workflow_step "Generate release note")"
function release_workflow_step() {
  awk -v WANTED="      - name: $1" '
    $0 == WANTED { inside = 1; next }
    inside && /^      - name: / { exit }
    inside { print }
  ' "$REPO_ROOT/$RELEASE_NOTE_WORKFLOW"
}

# The id a step declares for itself, out of its block
# Usage : DECLARED="$(declared_step_id "$CHECKING_STEP")"
function declared_step_id() {
  printf '%s\n' "$1" | sed -n 's/^ *id: *\([A-Za-z0-9_-]*\) *$/\1/p'
}

# The step id, and the output name, that a gate reads : "steps.<id>.outputs.<name>"
# Usage : GATED_ON="$(gate_reads "$WRITING_STEP" 1)"   # 1 the id, 2 the output
function gate_reads() {
  printf '%s\n' "$1" |
    sed -n "s/^ *if: *steps\.\([A-Za-z0-9_-]*\)\.outputs\.\([A-Za-z0-9_-]*\) *==.*/\\$2/p"
}

# Usage : OUTPUT="$(release_note_already_exists v1.76)"; EXIT_CODE=$?
function release_note_already_exists() {
  "$REPO_ROOT/$RELEASE_NOTE_SCRIPT" "$RELEASE_NOTE_REPOSITORY" "$1" 2>&1
}

function test_a_version_with_no_release_yet_has_its_note_written() {
  if ! release_note_decision_can_run; then
    skip_test "no .github next to the scripts"
    return 0
  fi

  # The ordinary release, and the recovery the workflow documents : a build that
  # died before publishing left no release behind, so re-firing it writes the
  # note for the first time. That path was never the broken one and has to stay
  # exactly as it was
  setup_release_note_sandbox

  local OUTPUT EXIT_CODE=0
  OUTPUT="$(release_note_already_exists v1.76)" || EXIT_CODE=$?

  assert_equals "1" "$EXIT_CODE" \
    "a version whose release does not exist has to get its release note"
  assert_contains "$OUTPUT" "no release" \
    "and the run log should say which of the two situations it found"

  teardown_release_note_sandbox
}

function test_a_version_that_already_has_a_release_keeps_the_note_it_has() {
  if ! release_note_decision_can_run; then
    skip_test "no .github next to the scripts"
    return 0
  fi

  # Issue #337 itself. The release action appends to a body rather than
  # replacing it, so handing it a tag that already has a release added one more
  # copy of the changelog every time - and would eventually have done the same
  # to the upgrade note written above it by hand
  setup_release_note_sandbox
  export MOCK_RELEASE_EXISTS=true

  local OUTPUT EXIT_CODE=0
  OUTPUT="$(release_note_already_exists v1.71)" || EXIT_CODE=$?

  assert_equals "0" "$EXIT_CODE" \
    "a release that exists must not be handed to a step that appends to it"
  assert_contains "$OUTPUT" "left exactly as it is" \
    "and the run log has to say the note was left alone"
  assert_not_contains "$OUTPUT" "::error::" \
    "leaving a release note alone is the ordinary outcome of a re-fire, not a failure"

  teardown_release_note_sandbox
}

function test_a_lookup_that_fails_writes_the_note_rather_than_risk_a_version_without_one() {
  if ! release_note_decision_can_run; then
    skip_test "no .github next to the scripts"
    return 0
  fi

  # "GitHub did not answer" is not "there is no release", and this is the one
  # decision in this repository where the unreadable answer goes on rather than
  # stops : the two mistakes are not the same size. A changelog written twice
  # shows on the release page and is repaired in one edit ; a version announced
  # nowhere is what left seventeen of them behind a release with nothing to pull
  setup_release_note_sandbox
  export MOCK_RELEASE_LOOKUP_ERROR="gh: Resource not accessible by integration (HTTP 403)"

  local OUTPUT EXIT_CODE=0
  OUTPUT="$(release_note_already_exists v1.76)" || EXIT_CODE=$?

  assert_equals "1" "$EXIT_CODE" \
    "an unreadable answer must not withhold the announcement of a published version"
  assert_contains "$OUTPUT" "::warning::" \
    "but going on without an answer has to be said out loud"

  teardown_release_note_sandbox
}

function test_the_release_lookup_refuses_to_guess_which_tag_it_is_about() {
  if ! release_note_decision_can_run; then
    skip_test "no .github next to the scripts"
    return 0
  fi

  setup_release_note_sandbox

  local EXIT_CODE=0
  "$REPO_ROOT/$RELEASE_NOTE_SCRIPT" "$RELEASE_NOTE_REPOSITORY" > /dev/null 2>&1 || EXIT_CODE=$?

  assert_equals "2" "$EXIT_CODE" \
    "called without a tag it has to refuse rather than answer about something else"

  teardown_release_note_sandbox
}

function test_a_lookup_that_cannot_even_run_writes_the_note() {
  if ! release_note_decision_can_run; then
    skip_test "no .github next to the scripts"
    return 0
  fi

  # Not "gh answered something unexpected" but "gh was never there to answer".
  # It matters which way a broken lookup falls, and under "set -e" a script that
  # breaks exits 1 : that is the code carrying "write the note", so any failure
  # inside this one lands on the side that costs the least to be wrong about
  setup_release_note_sandbox
  local -r EMPTY_DIRECTORY="$SANDBOX/no_commands"
  mkdir -p "$EMPTY_DIRECTORY"

  local OUTPUT EXIT_CODE=0
  OUTPUT="$(PATH="$EMPTY_DIRECTORY" "$REPO_ROOT/$RELEASE_NOTE_SCRIPT" \
    "$RELEASE_NOTE_REPOSITORY" v1.76 2>&1)" || EXIT_CODE=$?

  assert_equals "1" "$EXIT_CODE" \
    "a lookup that could not run at all must not read as a release that already has its note"
  assert_contains "$OUTPUT" "::warning::" \
    "and going on without an answer has to be said out loud rather than assumed"

  teardown_release_note_sandbox
}

function test_the_lookup_asks_github_about_the_release_it_was_given() {
  if ! release_note_decision_can_run; then
    skip_test "no .github next to the scripts"
    return 0
  fi

  # Every answer below is the same whatever is asked, so nothing else in this
  # file would notice a lookup about the wrong repository or the wrong tag - two
  # arguments of the same shape, one line apart, in a step no pull request runs
  setup_release_note_sandbox
  export MOCK_RELEASE_EXISTS=true

  release_note_already_exists v1.71 > /dev/null || true

  assert_equals "api repos/$RELEASE_NOTE_REPOSITORY/releases/tags/v1.71" \
    "$(recorded_gh_calls)" \
    "the release it asks GitHub about has to be the one it was given, and it has to ask once"

  teardown_release_note_sandbox
}

function test_the_release_note_step_runs_only_when_that_lookup_says_so() {
  # The workflow and the script only meet at a path written in both, and the
  # step that joins them runs on a version tag, where no pull request looks
  if [ ! -f "$REPO_ROOT/$RELEASE_NOTE_WORKFLOW" ]; then
    skip_test "no .github/workflows next to the scripts"
    return 0
  fi

  local -r CHECKING_STEP="$(release_workflow_step "Check whether this version already has its release note")"
  local -r WRITING_STEP="$(release_workflow_step "Generate release note")"

  assert_contains "$CHECKING_STEP" "$RELEASE_NOTE_SCRIPT" \
    "the release workflow has to ask $RELEASE_NOTE_SCRIPT before writing a note"
  assert_contains "$WRITING_STEP" "softprops/action-gh-release" \
    "the step that writes the note is the one that runs the release action"

  # The gate and the step it reads are two strings fifteen lines apart that have
  # to name the same thing, and asserting either one on its own cannot say that :
  # "id: release_note_check" contains "id: release_note". So both sides are
  # pulled out and compared. An id that resolves to nothing is not an error in
  # Actions - the expression is simply empty, the gate is false forever, and
  # every release goes out with no note at all, on green runs
  local -r DECLARED_ID="$(declared_step_id "$CHECKING_STEP")"
  local -r GATED_ON_ID="$(gate_reads "$WRITING_STEP" 1)"
  local -r GATED_ON_OUTPUT="$(gate_reads "$WRITING_STEP" 2)"

  assert_not_empty "$GATED_ON_ID" \
    "the step that writes the note has to be gated on a step output, which is the whole of issue #337"
  assert_equals "$DECLARED_ID" "$GATED_ON_ID" \
    "the gate has to name the id the checking step declares for itself"

  # The case statement in between is the whole translation from the exit code to
  # that gate, and swapping its two arms passes every other test in this file :
  # every version that already had a note would be handed to the step that
  # appends to it, and every version that had none would be gated out of it
  assert_contains "$CHECKING_STEP" "0) echo \"$GATED_ON_OUTPUT=false\"" \
    "a release that already has its note has to map to not writing one"
  assert_contains "$CHECKING_STEP" "1) echo \"$GATED_ON_OUTPUT=true\"" \
    "and a release that has none, or could not be asked about, has to map to writing one"

  # The generation itself is right where it is : the path it runs on is the one
  # that creates a release, and there it produces exactly one copy
  assert_contains "$WRITING_STEP" "generate_release_notes: true" \
    "a release being created for the first time still gets its changelog generated"

  if [ -x "$REPO_ROOT/$RELEASE_NOTE_SCRIPT" ]; then
    pass
  else
    fail "$RELEASE_NOTE_SCRIPT is run as a command by the workflow, it has to be executable"
  fi
}
