#!/bin/bash

# "latest" is the tag almost every user actually pulls, and the only one whose
# value is a decision rather than a name. That decision is taken twice : once
# before the build, by the check that gates it, and once after the push, by
# .github/reconcile_latest_tag.sh. Neither runs on a pull request, and both are
# read by nobody until "latest" is already wrong on somebody's server.
#
# The registry is stubbed here, so these exercise the decision and not Docker :
# a fake "docker" first in the PATH answers for a registry whose contents the
# test states, and records what was written back to it.

readonly RECONCILIATION_SCRIPT=".github/reconcile_latest_tag.sh"
readonly RECONCILIATION_WORKFLOW=".github/workflows/build_and_publish_docker_image.yml"
readonly RECONCILIATION_IMAGE="owner/image"

# The suite also runs inside the built image, which carries the shipped scripts
# but not the .github directory. jq is what the script reads a label with : the
# suite's own dependencies stop at bash, coreutils, grep and awk, so a machine
# without it skips these rather than turning the promise in tests/README.md into
# a lie. Every runner and the devcontainer have it
# Usage : if ! latest_tag_reconciliation_can_run; then skip_test "..."; return 0; fi
function latest_tag_reconciliation_can_run() {
  [ -x "$REPO_ROOT/$RECONCILIATION_SCRIPT" ] && command -v jq > /dev/null 2>&1
}

# Builds the world the script runs in : a git repository holding the version
# tags it walks, and a registry it can only see through a stubbed docker.
#
# The registry is a file of "reference<tab>version" lines. A reference absent
# from it does not exist, and the version "!UNREADABLE" is a registry that
# answers something that is neither, which the script must never read as empty.
# Usage : setup_reconciliation_sandbox "v1.74 v1.75" \
#           "docker.io/owner/image:v1.75	v1.75" "docker.io/owner/image:latest	v1.74"
function setup_reconciliation_sandbox() {
  local -r GIT_TAGS="$1"
  shift

  SANDBOX="$(mktemp -d)"
  REGISTRY_STATE_FILE="$SANDBOX/registry"
  REGISTRY_CREATE_LOG="$SANDBOX/created"
  export MOCK_REGISTRY_STATE_FILE="$REGISTRY_STATE_FILE"
  export MOCK_REGISTRY_CREATE_LOG="$REGISTRY_CREATE_LOG"

  : > "$REGISTRY_STATE_FILE"
  : > "$REGISTRY_CREATE_LOG"
  local ENTRY
  for ENTRY in "$@"; do
    printf '%s\n' "$ENTRY" >> "$REGISTRY_STATE_FILE"
  done

  mkdir -p "$SANDBOX/bin"
  cat > "$SANDBOX/bin/docker" << 'STUB'
#!/bin/bash
# Answers the two imagetools calls the script makes, off the state file, and
# records the writes. Positional rather than parsed : the script calls this with
# a fixed shape, and a stub that accepted more shapes than the real command
# would hide a call that docker itself would refuse
#   docker buildx imagetools inspect <reference> --format <template>
#   docker buildx imagetools create --tag <target> <source>
set -uo pipefail

function version_of() {
  awk -F'\t' -v reference="$1" '$1 == reference { print $2; found = 1; exit }
                                END { if (!found) exit 1 }' "$MOCK_REGISTRY_STATE_FILE"
}

case "${3:-}" in
  inspect)
    REFERENCE="${4:-}"
    if ! VERSION="$(version_of "$REFERENCE")"; then
      printf '%s: not found\n' "$REFERENCE" >&2
      exit 1
    fi
    if [ "$VERSION" = "!UNREADABLE" ]; then
      printf 'unexpected status from HEAD request to %s: 429 Too Many Requests\n' "$REFERENCE" >&2
      exit 1
    fi
    case "${6:-}" in
      *.Manifest*) printf '{"digest":"sha256:%s"}\n' "${REFERENCE//[^a-z0-9]/}" ;;
      *.Image*)
        if [ "$VERSION" = "!UNLABELLED" ]; then
          printf '{"config":{"Labels":{}}}\n'
        else
          printf '{"config":{"Labels":{"org.opencontainers.image.version":"%s"}}}\n' "$VERSION"
        fi
        ;;
      *) printf 'unexpected format %s\n' "${6:-}" >&2; exit 64 ;;
    esac
    ;;
  create)
    TARGET="${5:-}"
    SOURCE="${6:-}"
    printf '%s <- %s\n' "$TARGET" "$SOURCE" >> "$MOCK_REGISTRY_CREATE_LOG"
    # A manifest copy leaves the target carrying the source's labels, which is
    # what the script reads back to confirm the write landed
    if [ "${MOCK_REGISTRY_CREATE_IS_A_NOOP:-false}" = true ]; then
      # A registry that takes the write, answers 200 and serves the old image
      # anyway. Nothing in the exit code says so
      exit 0
    fi
    VERSION="$(version_of "$SOURCE")" || VERSION=""
    awk -F'\t' -v reference="$TARGET" '$1 != reference' "$MOCK_REGISTRY_STATE_FILE" > "$MOCK_REGISTRY_STATE_FILE.new"
    mv "$MOCK_REGISTRY_STATE_FILE.new" "$MOCK_REGISTRY_STATE_FILE"
    printf '%s\t%s\n' "$TARGET" "$VERSION" >> "$MOCK_REGISTRY_STATE_FILE"
    ;;
  *)
    printf 'the stub was called in a shape the script is not supposed to use : %s\n' "$*" >&2
    exit 64
    ;;
esac
STUB
  chmod 0755 "$SANDBOX/bin/docker"
  export PATH="$SANDBOX/bin:$PATH"

  mkdir -p "$SANDBOX/repository"
  git -C "$SANDBOX/repository" init -q
  git -C "$SANDBOX/repository" -c user.name=t -c user.email=t@t \
    commit -q --allow-empty -m "tagged"
  local TAG
  for TAG in $GIT_TAGS; do
    git -C "$SANDBOX/repository" tag "$TAG"
  done
}

function teardown_reconciliation_sandbox() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
}

# Usage : OUTPUT="$(run_reconciliation docker.io ghcr.io)"
function run_reconciliation() {
  # From inside the repository, because the version tags the script walks are
  # the ones git answers with where it runs
  (cd "$SANDBOX/repository" && "$REPO_ROOT/$RECONCILIATION_SCRIPT" "$RECONCILIATION_IMAGE" "$@") 2>&1
}

# Usage : VERSION="$(published_version "docker.io/owner/image:latest")"
function published_version() {
  awk -F'\t' -v reference="$1" '$1 == reference { print $2; exit }' "$REGISTRY_STATE_FILE"
}

function test_latest_is_repointed_at_the_highest_published_version() {
  if ! latest_tag_reconciliation_can_run; then
    skip_test "no .github next to the scripts, or no jq"
    return 0
  fi

  # The state issue #325 left behind : the same two version tags published
  # everywhere, and a "latest" that disagrees from one registry to the other
  setup_reconciliation_sandbox "v1.74 v1.75" \
    "docker.io/owner/image:v1.74	v1.74" \
    "docker.io/owner/image:v1.75	v1.75" \
    "docker.io/owner/image:latest	v1.75" \
    "ghcr.io/owner/image:v1.74	v1.74" \
    "ghcr.io/owner/image:v1.75	v1.75" \
    "ghcr.io/owner/image:latest	v1.74"

  local OUTPUT
  OUTPUT="$(run_reconciliation docker.io ghcr.io)"

  assert_equals "v1.75" "$(published_version "ghcr.io/owner/image:latest")" \
    "the registry left behind has to be brought onto the highest published version"
  assert_equals "v1.75" "$(published_version "docker.io/owner/image:latest")" \
    "the registry that was already right has to stay right"
  assert_contains "$OUTPUT" "ghcr.io" "the registry it repointed should be named"

  # Only the registry that was wrong is written to : a release published on its
  # own must cost no write at all
  assert_equals "ghcr.io/owner/image:latest <- ghcr.io/owner/image:v1.75" \
    "$(cat "$REGISTRY_CREATE_LOG")" \
    "only the registry that disagreed should have been written to"

  teardown_reconciliation_sandbox
}

function test_a_latest_already_on_the_highest_version_is_left_untouched() {
  if ! latest_tag_reconciliation_can_run; then
    skip_test "no .github next to the scripts, or no jq"
    return 0
  fi

  setup_reconciliation_sandbox "v1.74 v1.75" \
    "docker.io/owner/image:v1.75	v1.75" \
    "docker.io/owner/image:latest	v1.75"

  run_reconciliation docker.io > /dev/null

  assert_empty "$(cat "$REGISTRY_CREATE_LOG")" \
    "nothing should be written when the registry already serves the highest published version"

  teardown_reconciliation_sandbox
}

function test_reconciling_twice_writes_once() {
  if ! latest_tag_reconciliation_can_run; then
    skip_test "no .github next to the scripts, or no jq"
    return 0
  fi

  # The property the whole approach rests on. Two releases publishing seconds
  # apart both reach this script, and the second one must not undo the first
  # nor write again : once the images are published the answer no longer
  # depends on who asks, or when
  setup_reconciliation_sandbox "v1.74 v1.75" \
    "docker.io/owner/image:v1.74	v1.74" \
    "docker.io/owner/image:v1.75	v1.75" \
    "docker.io/owner/image:latest	v1.74"

  run_reconciliation docker.io > /dev/null
  run_reconciliation docker.io > /dev/null

  assert_equals "1" "$(grep -c . "$REGISTRY_CREATE_LOG")" \
    "the second run should find nothing left to do"
  assert_equals "v1.75" "$(published_version "docker.io/owner/image:latest")" \
    "the second run should not move latest off the highest published version"

  teardown_reconciliation_sandbox
}

function test_a_version_tagged_in_git_but_never_published_does_not_hold_latest_back() {
  if ! latest_tag_reconciliation_can_run; then
    skip_test "no .github next to the scripts, or no jq"
    return 0
  fi

  # v1.76 is exactly what v1.60 and v1.61 are : a tag whose build never pushed
  # anything. Treating it as the highest version is what froze "latest" on the
  # v1.46 image for two days, and this script must not reintroduce it
  setup_reconciliation_sandbox "v1.74 v1.75 v1.76" \
    "docker.io/owner/image:v1.75	v1.75" \
    "docker.io/owner/image:latest	v1.74"

  run_reconciliation docker.io > /dev/null

  assert_equals "v1.75" "$(published_version "docker.io/owner/image:latest")" \
    "a tag that published nothing outranks nothing"

  teardown_reconciliation_sandbox
}

function test_an_unreadable_registry_is_left_alone_rather_than_treated_as_empty() {
  if ! latest_tag_reconciliation_can_run; then
    skip_test "no .github next to the scripts, or no jq"
    return 0
  fi

  # A rate limit, an expired token, an outage : none of them is an answer to
  # "which version is published ?". Reading one as "nothing is published" is
  # how "latest" would walk backwards, so the registry is skipped, loudly.
  #
  # The state is arranged so that reading it wrong does damage rather than
  # nothing : "latest" is already right, and the version that cannot be read is
  # the one holding it there. Skip v1.75 and v1.74 becomes the highest thing
  # visible, which would drag "latest" back a release. A test where the
  # mistaken answer happens to be harmless proves nothing about the guard
  setup_reconciliation_sandbox "v1.74 v1.75" \
    "docker.io/owner/image:v1.74	v1.74" \
    "docker.io/owner/image:v1.75	!UNREADABLE" \
    "docker.io/owner/image:latest	v1.75"

  local OUTPUT EXIT_CODE=0
  OUTPUT="$(run_reconciliation docker.io)" || EXIT_CODE=$?

  assert_equals "v1.75" "$(published_version "docker.io/owner/image:latest")" \
    "an unreadable registry must not have its latest moved, least of all backwards"
  assert_empty "$(cat "$REGISTRY_CREATE_LOG")" \
    "an unreadable registry must not be written to"
  assert_contains "$OUTPUT" "::warning::" \
    "skipping a registry has to be said out loud"
  assert_equals "0" "$EXIT_CODE" \
    "a registry that could not be read must not redden a release that did go out"

  teardown_reconciliation_sandbox
}

function test_a_latest_ahead_of_every_published_version_is_not_dragged_backwards() {
  if ! latest_tag_reconciliation_can_run; then
    skip_test "no .github next to the scripts, or no jq"
    return 0
  fi

  # A version tag deleted from under us, or something pushed by hand : "latest"
  # is on v1.76 and no v1.76 resolves any more. Pointing it at the highest
  # version that still does would hand every user of "latest" an OLDER image
  # than the one they already have, which is the single thing this script must
  # never do. "Base image refresh" refuses the same situation
  setup_reconciliation_sandbox "v1.74 v1.75" \
    "docker.io/owner/image:v1.74	v1.74" \
    "docker.io/owner/image:v1.75	v1.75" \
    "docker.io/owner/image:latest	v1.76"

  local OUTPUT EXIT_CODE=0
  OUTPUT="$(run_reconciliation docker.io)" || EXIT_CODE=$?

  assert_equals "v1.76" "$(published_version "docker.io/owner/image:latest")" \
    "latest must not be moved back onto an older version than the one it serves"
  assert_empty "$(cat "$REGISTRY_CREATE_LOG")" \
    "nothing should be written when the only available move is backwards"
  assert_contains "$OUTPUT" "::warning::" \
    "a state nothing here produced has to be reported for someone to look at"
  assert_equals "0" "$EXIT_CODE" \
    "it must not redden a release whose image did go out"

  teardown_reconciliation_sandbox
}

function test_a_write_that_did_not_take_is_reported_rather_than_assumed() {
  if ! latest_tag_reconciliation_can_run; then
    skip_test "no .github next to the scripts, or no jq"
    return 0
  fi

  # "latest" pointing at the wrong version is silent : every pull succeeds, they
  # just get an older image. Nothing downstream notices, and the run that caused
  # it is green. Reading the tag back is the one cheap moment it can be caught,
  # so a registry that accepts the write and serves the old image anyway has to
  # come out red here
  setup_reconciliation_sandbox "v1.74 v1.75" \
    "docker.io/owner/image:v1.74	v1.74" \
    "docker.io/owner/image:v1.75	v1.75" \
    "docker.io/owner/image:latest	v1.74"
  export MOCK_REGISTRY_CREATE_IS_A_NOOP=true

  local OUTPUT EXIT_CODE=0
  OUTPUT="$(run_reconciliation docker.io)" || EXIT_CODE=$?

  assert_not_equals "0" "$EXIT_CODE" \
    "a latest that did not move has to fail the run"
  assert_contains "$OUTPUT" "::error::" \
    "and it has to say so where the run summary shows it"

  unset MOCK_REGISTRY_CREATE_IS_A_NOOP
  teardown_reconciliation_sandbox
}

function test_the_workflow_reconciles_latest_through_the_script_that_exists() {
  # The workflow and the script only meet at a path written in both, and the
  # step that joins them runs on a version tag, where no pull request looks
  if [ ! -f "$REPO_ROOT/$RECONCILIATION_WORKFLOW" ]; then
    skip_test "no .github/workflows next to the scripts"
    return 0
  fi

  local -r WORKFLOW_CONTENT="$(cat "$REPO_ROOT/$RECONCILIATION_WORKFLOW")"

  assert_contains "$WORKFLOW_CONTENT" "$RECONCILIATION_SCRIPT" \
    "the release workflow has to reconcile latest through $RECONCILIATION_SCRIPT"

  local REGISTRY
  for REGISTRY in docker.io ghcr.io; do
    assert_contains "$WORKFLOW_CONTENT" "$REGISTRY" \
      "$REGISTRY receives the image, so its latest has to be reconciled too"
  done

  if [ -x "$REPO_ROOT/$RECONCILIATION_SCRIPT" ]; then
    pass
  else
    fail "$RECONCILIATION_SCRIPT is run as a command by the workflow, it has to be executable"
  fi
}
