#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# The two workflows that publish the image are the only ones no pull request
# ever runs : "Docker image CI" fires on a version tag, "Base image refresh" on
# a schedule. A mistake in either is found at release time, or the morning
# after, by which point it has already cost a release or a night's rebuild.
# This is where they get read anyway.

function test_the_latest_reconciliation_survives_a_failure_above_it() {
  # It is placed after the release note so that a registry hiccup in it cannot
  # withhold the announcement of a version whose image did go out. Without a
  # guard the ordering also hands the release note a veto : a run that dies
  # writing the announcement skips the reconciliation and leaves "latest"
  # wherever the racing pushes put it, which is the state issue #325 was filed
  # for, reached through another door (issue #355).
  #
  # Running it after a failure is safe by construction -- the script walks the
  # versions the registry actually serves, so a release that never pushed is not
  # a candidate -- so the guard costs nothing and closes the window
  local -r RELEASE_WORKFLOW="$REPO_ROOT/.github/workflows/build_and_publish_docker_image.yml"
  if [ ! -f "$RELEASE_WORKFLOW" ]; then
    skip_test "no .github/workflows next to the scripts"
    return 0
  fi

  # The two lines of the step, in order : its name, then whatever follows before
  # the next key. A guard placed anywhere else in the file would not apply to it
  local -r GUARD_AFTER_THE_STEP=$(awk '
    /- name: Point "latest" at the highest published version/ { found = 1; next }
    found && /^ *if:/ { print; exit }
    found && /^ *- name:/ { exit }
  ' "$RELEASE_WORKFLOW")

  assert_contains "$GUARD_AFTER_THE_STEP" "cancelled()" \
    "the latest reconciliation has to run even when a step above it failed"
}

function test_no_docker_action_list_entry_ends_with_a_comment() {
  # docker/metadata-action reads its multi-line inputs with a CSV parser it asks
  # to treat "#" as a comment. Up to v5 that stripped a "#" found anywhere on the
  # line, so a note could sit at the end of an image name and disappear before
  # the action read it. From v6 on only a "#" that STARTS a line is a comment and
  # a trailing one is kept, because a "#" belongs inside values such as a URL
  # fragment or a label. Both "images" entries were written in the older form, so
  # the bump to v6 resolved them to "owner/image # docker.io/owner/image" : an
  # invalid reference the action accepts without a word, failing later at the
  # push, in the one workflow no pull request would have caught it in.
  #
  # A note about a list entry belongs above the key, where YAML strips it and the
  # action never sees it at all. On its own line inside the block it works too,
  # but there it is data whose indentation is load-bearing : one extra space and
  # it silently becomes an image name again, which is the trap this guards.
  if [ ! -d "$REPO_ROOT/.github/workflows" ]; then
    # The suite is running inside the built image, which does not carry the
    # workflows that built it
    skip_test "no .github/workflows next to the scripts"
    return 0
  fi

  # The multi-line inputs the docker/* actions parse this way. Their single-line
  # form needs no guard : there the "#" is a YAML comment, stripped before the
  # action is handed anything
  local -r PARSED_LIST_INPUTS='images|tags|labels|flavor|annotations|build-args|cache-from|cache-to|platforms|outputs|no-cache-filters|allow|attests'

  local WORKFLOW
  for WORKFLOW in "$REPO_ROOT"/.github/workflows/*.yml "$REPO_ROOT"/.github/workflows/*.yaml; do
    [ -f "$WORKFLOW" ] || continue

    # Character classes spelled out rather than [[:space:]] : the suite runs on
    # mawk on the runner and on GNU awk inside the image, and this form is read
    # the same way by both
    local TRAILING_COMMENTS
    TRAILING_COMMENTS=$(awk -v inputs="$PARSED_LIST_INPUTS" '
      FNR == 1 { in_block = 0 }

      # A block scalar opens on "<key>: |", and only the listed keys are read by
      # a parser that gives "#" a meaning
      $0 ~ "^[ \t]*(" inputs "):[ \t]*[|>]" {
        in_block = 1
        key_indent = match($0, /[^ \t]/) - 1
        next
      }

      in_block {
        # A blank line inside a block scalar is content, not its end
        if ($0 ~ /^[ \t]*$/) next

        # The block ends where the indentation returns to the key or above it
        if (match($0, /[^ \t]/) - 1 <= key_indent) {
          in_block = 0
          next
        }

        # A value, then a "#" : the form v6 keeps. A line whose first character
        # is the "#" is a comment to the parser too, so it is left alone
        if ($0 ~ /^[ \t]*[^ \t#][^#]*#/) {
          printf "  line %d: %s\n", FNR, $0
        }
      }
    ' "$WORKFLOW")

    if [ -z "$TRAILING_COMMENTS" ]; then
      pass
    else
      fail "${WORKFLOW#"$REPO_ROOT"/} ends a list entry with a comment, which the action reads as part of the value" \
        "$TRAILING_COMMENTS"
    fi
  done
}

function test_every_workflow_carries_the_licence_header() {
  # NOTICE names the SPDX headers as part of what discharges AGPL 5(a) and 7(b) :
  # "Keeping this file, the LICENSE file and the SPDX headers in the source files
  # intact is what satisfies them". That was true of every script and the
  # Dockerfile, and of none of these files, which are the only programs here that
  # carried no licence statement at all -- and there is no REUSE.toml or
  # .reuse/dep5 covering them by fallback either (issue #367).
  #
  # Asserted over the directory rather than a list, so that a workflow added
  # later fails here instead of quietly reopening the gap. That is the shape of
  # test_the_shellcheck_workflow_lints_every_script_it_is_scoped_to, and for the
  # same reason : a list somebody has to remember to extend is one that falls
  # behind
  local -r WORKFLOW_DIRECTORY="$REPO_ROOT/.github/workflows"
  if [ ! -d "$WORKFLOW_DIRECTORY" ]; then
    skip_test "no .github/workflows next to the scripts"
    return 0
  fi

  local WORKFLOW
  local UNCOVERED=""
  for WORKFLOW in "$WORKFLOW_DIRECTORY"/*.yml "$WORKFLOW_DIRECTORY"/*.yaml; do
    [ -f "$WORKFLOW" ] || continue
    # Read from the head of the file : a header is only a header where a reader
    # and a scanner both find it, and one buried below the job it belongs to
    # discharges nothing
    if ! head -5 "$WORKFLOW" | grep -q '^# SPDX-License-Identifier: AGPL-3.0-only$'; then
      UNCOVERED="$UNCOVERED ${WORKFLOW#"$REPO_ROOT"/}"
    fi
  done

  assert_empty "$UNCOVERED" \
    "every workflow has to open with the two SPDX lines the scripts and the Dockerfile carry"
}

# Every step of every workflow runs shell, and none of it is shell to any tool
# that reads this repository : shellcheck is pointed at the .sh files, bash never
# parses a workflow, and the YAML linters read the document rather than the
# scalar. Several hundred lines are therefore written and merged unchecked, and
# a missing "fi" in them is found by the run that needed the workflow -- a
# release, or the nightly rebuild -- rather than by the pull request that
# introduced it (issue #419).
#
# Pulling the scalars back out is enough to hand them to "bash -n", which is
# what the .sh files already get. It is a syntax check and nothing more : it
# says the block parses, never that it does the right thing. The ${{ }}
# expressions survive it -- bash reads them as a parameter expansion and asks
# no question about the name -- so the blocks are checked as written, with no
# substitution and nothing added to any workflow.
#
# Usage : extract_workflow_run_blocks WORKFLOW OUTPUT_DIRECTORY
#         -> one "LINE<TAB>SCRIPT" per block, the scripts written in the directory
function extract_workflow_run_blocks() {
  awk -v OUTPUT_DIRECTORY="$2" '
    # A block scalar ends where the indentation returns to the key that opened
    # it, and is written out dedented : a heredoc terminator carrying the
    # workflow indentation is one bash would never recognise
    function flush_block(   INDEX, TEXT, SCRIPT) {
      SCRIPT = OUTPUT_DIRECTORY "/" (++BLOCKS) ".sh"
      printf "" > SCRIPT
      for (INDEX = 1; INDEX <= BUFFERED; INDEX++) {
        TEXT = BUFFER[INDEX]
        if (TEXT !~ /^[[:space:]]*$/) TEXT = substr(TEXT, MINIMUM_INDENT + 1)
        print TEXT > SCRIPT
      }
      close(SCRIPT)
      print BLOCK_LINE "\t" SCRIPT
      BUFFERED = 0
      IN_BLOCK = 0
    }
    {
      LINE = $0
      if (IN_BLOCK) {
        if (LINE ~ /^[[:space:]]*$/) { BUFFER[++BUFFERED] = ""; next }
        match(LINE, /^[[:space:]]*/)
        if (RLENGTH > KEY_INDENT) {
          if (MINIMUM_INDENT < 0 || RLENGTH < MINIMUM_INDENT) MINIMUM_INDENT = RLENGTH
          BUFFER[++BUFFERED] = LINE
          next
        }
        flush_block()
      }
      # "run: |", the shape all but a handful of the steps are written in
      if (LINE ~ /^[[:space:]-]*run:[[:space:]]*\|[-+]?[[:space:]]*$/) {
        KEY_INDENT = index(LINE, "run:") - 1
        IN_BLOCK = 1
        MINIMUM_INDENT = -1
        BLOCK_LINE = FNR
        next
      }
      # "run: one command", the rest of them
      if (LINE ~ /^[[:space:]-]*run:[[:space:]]*[^|>[:space:]]/) {
        COMMAND = LINE
        sub(/^[[:space:]-]*run:[[:space:]]*/, "", COMMAND)
        SCRIPT = OUTPUT_DIRECTORY "/" (++BLOCKS) ".sh"
        print COMMAND > SCRIPT
        close(SCRIPT)
        print FNR "\t" SCRIPT
      }
    }
    END { if (IN_BLOCK) flush_block() }
  ' "$1"
}

function test_every_shell_block_the_workflows_run_has_a_valid_syntax() {
  local -r WORKFLOW_DIRECTORY="$REPO_ROOT/.github/workflows"
  if [ ! -d "$WORKFLOW_DIRECTORY" ]; then
    skip_test "no .github/workflows next to the scripts"
    return 0
  fi

  local -r EXTRACTION_DIRECTORY="$TEST_TEMPORARY_DIRECTORY/workflow_run_blocks"
  rm -rf "$EXTRACTION_DIRECTORY"
  mkdir -p "$EXTRACTION_DIRECTORY"

  local WORKFLOW RELATIVE_PATH DECLARED_BLOCKS EXTRACTED_BLOCKS BLOCK_LINE SCRIPT SYNTAX_ERRORS
  local CHECKED_BLOCKS=0
  for WORKFLOW in "$WORKFLOW_DIRECTORY"/*.yml "$WORKFLOW_DIRECTORY"/*.yaml; do
    [ -f "$WORKFLOW" ] || continue
    RELATIVE_PATH="${WORKFLOW#"$REPO_ROOT"/}"

    EXTRACTED_BLOCKS=0
    while IFS=$'\t' read -r BLOCK_LINE SCRIPT; do
      [ -n "$SCRIPT" ] || continue
      EXTRACTED_BLOCKS=$((EXTRACTED_BLOCKS + 1))
      CHECKED_BLOCKS=$((CHECKED_BLOCKS + 1))

      SYNTAX_ERRORS=$(bash -n "$SCRIPT" 2>&1)
      if [ -n "$SYNTAX_ERRORS" ]; then
        fail "$RELATIVE_PATH runs a shell block with a syntax error, at line $BLOCK_LINE" \
          "$SYNTAX_ERRORS"
      fi
    done < <(extract_workflow_run_blocks "$WORKFLOW" "$EXTRACTION_DIRECTORY")

    # A "run:" written in a shape the extraction above does not know -- a folded
    # scalar, a quoted string -- would be dropped rather than reported, and this
    # case would stay green over the one block nobody had ever parsed. Counting
    # the keys is what turns that into a failure
    DECLARED_BLOCKS=$(grep -cE '^[[:space:]-]*run:' "$WORKFLOW")

    assert_equals "$DECLARED_BLOCKS" "$EXTRACTED_BLOCKS" \
      "every run: block of $RELATIVE_PATH has to be one this case can read"
  done

  # And the whole walk finding nothing would be the same silence one level up
  if (( CHECKED_BLOCKS == 0 )); then
    fail "no shell block was found across the workflows, and every one of them runs shell"
  fi
}

# The content of a "<key>: |" block scalar, indentation stripped, wherever it
# appears in a workflow. Shared by the two tests below, which compare one block
# against another.
#
# The block ends where the indentation returns to the key or above it, and a
# blank line inside it is content rather than its end -- the same reading
# test_no_docker_action_list_entry_ends_with_a_comment does, kept in one place
# rather than copied into both callers. Character classes are spelled out rather
# than [[:space:]] for the reason that test gives : the suite runs on mawk on the
# runner and on GNU awk inside the image, and this form is read the same way by
# both
function extract_block_scalar() {
  local -r KEY="$1"
  local -r FILE="$2"

  awk -v key="$KEY" '
    $0 ~ "^[ \t]*" key ":[ \t]*[|>]" {
      in_block = 1
      key_indent = match($0, /[^ \t]/) - 1
      next
    }

    in_block {
      if ($0 ~ /^[ \t]*$/) next

      if (match($0, /[^ \t]/) - 1 <= key_indent) {
        in_block = 0
        next
      }

      sub(/^[ \t]+/, "")
      print
    }
  ' "$FILE"
}

function test_every_publishing_workflow_states_the_project_licence() {
  # metadata-action fills org.opencontainers.image.licenses from GitHub's licence
  # detection, and GitHub reports the plain "AGPL-3.0" for this repository rather
  # than the "-only" the project actually chose. "Docker image CI" has always
  # overridden it. "Base image refresh" did not -- and it republishes the SAME
  # "latest" tag, so every night the base moved, the published image quietly
  # stopped stating the project's own terms and started stating GitHub's guess at
  # them (issue #493). In a dual-licensed project that is not cosmetic : see
  # LICENSE, LICENSE-COMMERCIAL.md and what .github/check_sign_off.sh says the
  # licence record is load-bearing for.
  #
  # Both blocks are read, not just the labels : getAnnotations() returns
  # getOCIAnnotationsWithCustoms(inputs.annotations) and never looks at
  # inputs.labels, so a licence stated once reaches the image config and stops
  # there, leaving the index to carry the guess beside a config that disagrees.
  #
  # Swept over every publishing workflow rather than over a list of two, so that a
  # third publisher added later fails here instead of quietly reopening this
  if [ ! -d "$REPO_ROOT/.github/workflows" ]; then
    skip_test "no .github/workflows next to the scripts"
    return 0
  fi

  local WORKFLOW
  for WORKFLOW in "$REPO_ROOT"/.github/workflows/*.yml; do
    [ -f "$WORKFLOW" ] || continue
    grep -q '^ *push: true$' "$WORKFLOW" || continue

    local KEY
    for KEY in labels annotations; do
      local BLOCK
      BLOCK=$(extract_block_scalar "$KEY" "$WORKFLOW")

      assert_contains "$BLOCK" "org.opencontainers.image.licenses=AGPL-3.0-only" \
        "${WORKFLOW#"$REPO_ROOT"/} publishes an image whose $KEY do not state the project's licence, so metadata-action fills in GitHub's guess"
    done
  done
}

function test_every_publishing_workflow_annotates_the_image_index() {
  # Labels live in each per-platform image config ; annotations live on the
  # manifests and on the index. The index is what "docker pull" and
  # "imagetools inspect" resolve first, and until issue #493 neither publisher
  # passed the annotations input at all -- measured on the published image, the
  # index and both platform manifests carried none.
  #
  # Three things have to hold together, and each is inert without the others : the
  # levels variable has to name "index", because metadata-action attaches to
  # "manifest" alone by default ; every pushing build has to be handed the
  # annotations output beside the labels one ; and the two block scalars have to
  # agree, for the reason the licence test above gives. The third is the one that
  # keeps this from drifting back : a custom entry added to one block and not the
  # other is exactly how the licence went missing in the first place
  if [ ! -d "$REPO_ROOT/.github/workflows" ]; then
    skip_test "no .github/workflows next to the scripts"
    return 0
  fi

  local WORKFLOW
  for WORKFLOW in "$REPO_ROOT"/.github/workflows/*.yml; do
    [ -f "$WORKFLOW" ] || continue
    grep -q '^ *push: true$' "$WORKFLOW" || continue

    local RELATIVE_PATH="${WORKFLOW#"$REPO_ROOT"/}"

    local LEVELS
    LEVELS=$(grep -c '^ *DOCKER_METADATA_ANNOTATIONS_LEVELS: .*\bindex\b' "$WORKFLOW")
    assert_not_equals "$LEVELS" "0" \
      "$RELATIVE_PATH publishes an image without naming \"index\" in DOCKER_METADATA_ANNOTATIONS_LEVELS, so its annotations never reach the index"

    # One "annotations:" handed to a build for every "labels:" handed to one. The
    # single-line output form only, which is what a build step takes ; the block
    # scalars above are the action's inputs and are compared separately below
    local LABELS_PASSED ANNOTATIONS_PASSED
    LABELS_PASSED=$(grep -c '^ *labels: \${{ steps\.meta\.outputs\.labels }}$' "$WORKFLOW")
    ANNOTATIONS_PASSED=$(grep -c '^ *annotations: \${{ steps\.meta\.outputs\.annotations }}$' "$WORKFLOW")
    assert_equals "$ANNOTATIONS_PASSED" "$LABELS_PASSED" \
      "$RELATIVE_PATH hands its builds $LABELS_PASSED labels output(s) and $ANNOTATIONS_PASSED annotations one(s) ; a build given one and not the other publishes an image that describes itself in one place only"

    local LABELS_BLOCK ANNOTATIONS_BLOCK
    LABELS_BLOCK=$(extract_block_scalar labels "$WORKFLOW")
    ANNOTATIONS_BLOCK=$(extract_block_scalar annotations "$WORKFLOW")
    assert_equals "$ANNOTATIONS_BLOCK" "$LABELS_BLOCK" \
      "$RELATIVE_PATH states different custom entries as labels and as annotations ; getAnnotations() never reads the labels input, so whatever is missing here is missing from the index"
  done
}

# The checks .github/rulesets/master.json requires are matched by a job's
# display "name:", never by its key and never by the workflow's name, and only
# on a job that actually reports on a pull request. A context that names no such
# job never reports, and on a branch that requires it every pull request then
# waits for ever -- Dependabot's first, since nothing else would merge them.
# This is the counterpart of wader/postfix-relay's tests/test_ruleset.py, which
# every repository of this maintainer is aligned on.
function test_every_check_the_ruleset_requires_is_a_job_a_pull_request_runs() {
  local -r RULESET="$REPO_ROOT/.github/rulesets/master.json"
  local -r WORKFLOW_DIRECTORY="$REPO_ROOT/.github/workflows"
  if [ ! -f "$RULESET" ] || [ ! -d "$WORKFLOW_DIRECTORY" ] || ! command -v jq > /dev/null 2>&1; then
    skip_test "no .github next to the scripts, or no jq to read the ruleset with"
    return 0
  fi

  # Every job display name, from the workflows a pull request starts. A job
  # without a "name:" reports under its key, so the key is the default. Read
  # with awk rather than a YAML parser because the suite installs none, and
  # every workflow here is written in the one shape this reads : two-space job
  # keys under a top-level "jobs:", their "name:" four spaces in
  local WORKFLOW
  local REPORTED=""
  for WORKFLOW in "$WORKFLOW_DIRECTORY"/*.yml; do
    grep -Eq '^on: pull_request$|^  pull_request:' "$WORKFLOW" || continue
    REPORTED+=$(awk '
      /^jobs:/ { in_jobs = 1; next }
      in_jobs && /^[^ #]/ { in_jobs = 0 }
      !in_jobs { next }
      /^  [A-Za-z0-9_-]+:[ ]*$/ {
        if (key != "" && !named) print key
        key = $1; sub(/:$/, "", key); named = 0; next
      }
      key != "" && !named && /^    name:/ {
        line = $0; sub(/^    name:[ ]*/, "", line); gsub(/^"|"$/, "", line)
        print line; named = 1
      }
      END { if (key != "" && !named) print key }
    ' "$WORKFLOW")
    REPORTED+=$'\n'
  done

  local CONTEXT
  local MISSING=""
  while IFS= read -r CONTEXT; do
    [ -n "$CONTEXT" ] || continue
    if ! grep -Fxq -- "$CONTEXT" <<< "$REPORTED"; then
      MISSING="$MISSING \"$CONTEXT\""
    fi
  done < <(jq -r '.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context' "$RULESET")

  assert_empty "$MISSING" \
    "every required check has to be the name of a job a pull request runs, or it never reports"
}

# A re-export made after clicking around the settings page can hand back a file
# that still parses and no longer gates anything : disabled or in "evaluate"
# mode, aimed at another branch, opened to a bypass actor, its rule requiring
# checks dropped or emptied, a required approval added, or branches required to
# be up to date again. Each of those is checked, so that the file being
# importable is not mistaken for it being the same gate.
#
# The file is the whole of the live ruleset, not only its checks : master is
# also protected against deletion and force-pushes, takes pull requests only,
# and keeps a linear history, and a file carrying the checks alone would drop
# all four the day it was imported in place of the live one (#510). Those four
# are not asserted here -- they are protections, not what makes the gate pass
# or fail. The approval count is : one required approval holds every Dependabot
# update for a person, which is exactly what #506 closed.
#
# So is "Require branches to be up to date before merging". With it on, each
# merge leaves every other open pull request blocked until its branch is
# updated, and what updates them is best effort : "Auto-update pull request
# branches" leaves alone the ones that conflict, cannot write to a fork, skips
# drafts, leaves Dependabot's to Dependabot, and only reaches what a Dependabot
# merge left behind after the next push to master made any other way, a merge
# made in GITHUB_TOKEN's name starting no workflow, and so no wait.
# Each of those would turn from behind into blocked. What the setting bought --
# a pull request tested against the master it lands on -- is what that
# workflow gives wherever it can, and is paid for after the merge elsewhere,
# where "Tests" runs for real on any merge made behind master but a Dependabot
# one (see its "detect-reuse" job, and dependabot-auto-merge.yml for the
# exception), which is also the choice wader/postfix-relay made
function test_the_ruleset_still_gates_master() {
  local -r RULESET="$REPO_ROOT/.github/rulesets/master.json"
  if [ ! -f "$RULESET" ] || ! command -v jq > /dev/null 2>&1; then
    skip_test "no .github next to the scripts, or no jq to read the ruleset with"
    return 0
  fi

  assert_equals "active" "$(jq -r '.enforcement' "$RULESET")" \
    "the ruleset has to be enforced, not evaluated or disabled"
  assert_equals '["~DEFAULT_BRANCH"]' "$(jq -c '.conditions.ref_name.include' "$RULESET")" \
    "the ruleset has to target the default branch"
  assert_equals '[]' "$(jq -c '.conditions.ref_name.exclude' "$RULESET")" \
    "nothing may be excluded from the ruleset's target"
  assert_equals '[]' "$(jq -c '.bypass_actors' "$RULESET")" \
    "the ruleset has no bypass actor"
  assert_equals "1" "$(jq '[.rules[] | select(.type == "required_status_checks")] | length' "$RULESET")" \
    "the ruleset carries exactly one rule that requires checks"
  assert_not_equals "0" "$(jq '[.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]] | length' "$RULESET")" \
    "a ruleset requiring no check lets auto-merge land an update with nothing checked"
  assert_equals "0" "$(jq '[.rules[] | select(.type == "pull_request") | .parameters.required_approving_review_count] | add // 0' "$RULESET")" \
    "a required approval would hold every Dependabot update for a person, however green"
  assert_equals "false" "$(jq '[.rules[] | select(.type == "required_status_checks") | .parameters.strict_required_status_checks_policy] | any' "$RULESET")" \
    "requiring branches to be up to date would block every pull request the branch updater cannot reach, Dependabot's merges leaving all of them behind until the next push to master made any other way"
}

# "gh pr merge --auto" waits for the required checks ; a bare "gh pr merge" does
# not. The workflow used to fall back to the second whenever the first could not
# be enabled -- precisely when no check was being required -- and so merged
# Dependabot's updates with nothing having run. Every merge it issues has to be
# the waiting kind
function test_dependabot_updates_are_only_ever_queued_never_merged_directly() {
  local -r AUTO_MERGE_WORKFLOW="$REPO_ROOT/.github/workflows/dependabot-auto-merge.yml"
  if [ ! -f "$AUTO_MERGE_WORKFLOW" ]; then
    skip_test "no .github/workflows next to the scripts"
    return 0
  fi

  local -r MERGES=$(grep -v '^[[:space:]]*#' "$AUTO_MERGE_WORKFLOW" | grep -o 'gh pr merge[^|&;]*')
  assert_not_empty "$MERGES" "the workflow is expected to queue the merge with gh pr merge"
  assert_empty "$(grep -v -- '--auto' <<< "$MERGES")" \
    "every gh pr merge in the auto-merge workflow has to carry --auto, so that it waits for the required checks"
}

# Dependabot's minor and patch updates merge themselves once the required checks
# are green (dependabot-auto-merge.yml), and nothing those checks run says
# whether a release was published an hour ago by someone who should not have
# been able to. A cooldown makes Dependabot wait before it proposes a version
# that is only just out, which is the window in which a compromised release is
# usually noticed and pulled, and it applies to version updates only : a
# security update ignores it. So every entry of "updates" carries one, and an
# entry that loses it goes back to being merged within hours of a publication
# without anybody having decided that.
#
# The one entry that would be left without it is an official base image, whose
# freshness matters more than the delay. There is none : the base image of the
# Dockerfile is not tracked by Dependabot at all, base_image_refresh.yml
# rebuilds on it every night. If one is ever added it is named in
# ENTRIES_WITHOUT_A_COOLDOWN below, with the reason, rather than quietly
# missing its cooldown.
#
# Dependabot reports a configuration error only after the merge, on the
# repository's Insights > Dependency graph > Dependabot page, so nothing in CI
# can say the file is accepted : this reads what the file states, no more
function test_every_dependabot_update_waits_out_a_cooldown() {
  local -r DEPENDABOT_CONFIG="$REPO_ROOT/.github/dependabot.yml"
  if [ ! -f "$DEPENDABOT_CONFIG" ]; then
    # The suite is running inside the built image, which does not carry the
    # configuration of the repository that built it
    skip_test "no .github next to the scripts"
    return 0
  fi

  # "ecosystem:directory" pairs allowed to go without one, separated by spaces
  local -r ENTRIES_WITHOUT_A_COOLDOWN=""
  local -r MINIMUM_COOLDOWN_DAYS=3

  # One "ecosystem|directory|days" per entry of "updates", days being empty when
  # the entry has no cooldown or no default-days under it. Read with awk rather
  # than a YAML parser because the suite installs none, and this file is written
  # in the one shape this reads : an entry opens on a "  - package-ecosystem:"
  # line and its keys sit four spaces in. Comments are never matched, the
  # patterns being anchored on the key
  local ENTRIES
  ENTRIES=$(awk '
    function value(line) {
      sub(/^[^:]*:[ \t]*/, "", line)
      sub(/[ \t]*#.*$/, "", line)
      gsub(/^"|"$/, "", line)
      return line
    }
    function flush() {
      if (ecosystem != "") printf "%s|%s|%s\n", ecosystem, directory, days
      ecosystem = ""; directory = ""; days = ""; in_cooldown = 0
    }
    /^  - package-ecosystem:/ { flush(); ecosystem = value($0); next }
    ecosystem == "" { next }
    /^    directory:/ { directory = value($0); next }
    /^    cooldown:/ { in_cooldown = 1; next }
    /^    [^ #]/ { in_cooldown = 0; next }
    in_cooldown && /^      default-days:/ { days = value($0); next }
    END { flush() }
  ' "$DEPENDABOT_CONFIG")

  assert_not_empty "$ENTRIES" \
    "the Dependabot configuration is expected to hold at least one entry of updates, or this reads nothing" || return 1

  local ECOSYSTEM DIRECTORY DAYS
  while IFS='|' read -r ECOSYSTEM DIRECTORY DAYS; do
    if [[ " $ENTRIES_WITHOUT_A_COOLDOWN " == *" $ECOSYSTEM:$DIRECTORY "* ]]; then
      pass
      continue
    fi

    if [[ ! "$DAYS" =~ ^[0-9]+$ ]]; then
      fail "the $ECOSYSTEM entry for $DIRECTORY has no cooldown with a default-days, so Dependabot proposes a release the day it is published and auto-merge lands it within hours"
    elif [ "$DAYS" -lt "$MINIMUM_COOLDOWN_DAYS" ]; then
      fail "the $ECOSYSTEM entry for $DIRECTORY waits $DAYS day(s) before proposing a version, less than the $MINIMUM_COOLDOWN_DAYS the auto-merge is meant to be held back by"
    else
      pass
    fi
  done <<< "$ENTRIES"
}

# "Auto-update pull request branches" leaves Dependabot's pull requests to
# Dependabot. A rebase pushed by anyone else replaces the commit Dependabot
# signed, and dependabot/fetch-metadata in dependabot-auto-merge.yml refuses the
# result : "Dependabot's commit signature is not verified, refusing to proceed",
# which is what every Dependabot pull request answers once such a rebase has
# reached it (#514).
#
# Run here as written, over two pull requests equally far behind master, against
# a stubbed gh that answers the calls the step makes and records them : the one
# Dependabot opened must see no update at all, and the other one must still get
# its rebase, so that a filter which skipped everything would fail this as well.
#
# The same run covers the comment that announces a conflict (#527), over two
# more pull requests that conflict with master. The one with no comment yet gets
# exactly one, carrying the marker a later pass looks for ; the one already
# carrying it gets none, which is how a conflict is announced once however many
# passes see it. And the pull request that is conflict-free again has the
# comment removed, the comment beside it that is not the updater's left where
# it is, and Dependabot's pull request never reaches the comment API at all
function test_the_branch_updater_leaves_dependabot_pull_requests_to_dependabot_and_announces_each_conflict_once() {
  local -r WORKFLOW_FILE="$REPO_ROOT/.github/workflows/auto_update_pull_request_branches.yml"
  if [ ! -f "$WORKFLOW_FILE" ] || ! command -v jq > /dev/null 2>&1; then
    skip_test "no .github/workflows next to the scripts, or no jq for the step to read its answers with"
    return 0
  fi

  local -r SANDBOX="$TEST_TEMPORARY_DIRECTORY/branch_updater"
  rm -rf "$SANDBOX"
  mkdir -p "$SANDBOX/bin" "$SANDBOX/blocks"

  local RUN_LINE
  RUN_LINE=$(awk '
    index($0, "- name: Rebase every conflict-free pull request") { found = 1 }
    found && /^[ \t-]*run:/ { print FNR; exit }
  ' "$WORKFLOW_FILE")

  local SCRIPT
  SCRIPT=$(extract_workflow_run_blocks "$WORKFLOW_FILE" "$SANDBOX/blocks" |
    awk -F '\t' -v LINE="$RUN_LINE" '$1 == LINE { print $2 }')
  if [ -z "$RUN_LINE" ] || [ ! -f "$SCRIPT" ]; then
    fail "no \"Rebase every conflict-free pull request\" step with a run: block in the branch updater"
    return 1
  fi

  cat > "$SANDBOX/bin/gh" << 'STUB'
#!/bin/bash
# Pull request 11 is Dependabot's and 12 a person's, both mergeable and both two
# commits behind master. 12 carries a comment of the updater's from an earlier
# conflict, which is over, beside a comment that is not. 13 and 14 conflict with
# master : 13 has never been announced, 14 already has been. The --jq filter is
# not applied : each answer is already what that filter extracts. Anything else
# is refused, so a call the stub was not written for fails loudly instead of
# answering empty
set -uo pipefail

printf '%s\n' "$*" >> "$MOCK_GH_CALL_LOG"

case "$1 ${2:-}" in
  "pr list")
    printf '[{"number":11,"isDraft":false},{"number":12,"isDraft":false},{"number":13,"isDraft":false},{"number":14,"isDraft":false}]\n'
    ;;
  "api repos/example/repository/commits/master")
    printf 'master-sha\n'
    ;;
  "api repos/example/repository/pulls/11")
    printf '{"user":{"login":"dependabot[bot]"},"mergeable":true,"head":{"sha":"dependabot-sha"},"node_id":"DEPENDABOT_NODE"}\n'
    ;;
  "api repos/example/repository/pulls/12")
    printf '{"user":{"login":"tigerblue77"},"mergeable":true,"head":{"sha":"person-sha"},"node_id":"PERSON_NODE"}\n'
    ;;
  "api repos/example/repository/pulls/13")
    printf '{"user":{"login":"tigerblue77"},"mergeable":false,"head":{"sha":"unannounced-sha"},"node_id":"UNANNOUNCED_NODE"}\n'
    ;;
  "api repos/example/repository/pulls/14")
    printf '{"user":{"login":"tigerblue77"},"mergeable":false,"head":{"sha":"announced-sha"},"node_id":"ANNOUNCED_NODE"}\n'
    ;;
  "api repos/example/repository/compare/"*)
    printf '2\n'
    ;;
  "api graphql")
    printf '{"data":{"updatePullRequestBranch":{"pullRequest":{"headRefOid":"rebased-sha"}}}}\n'
    ;;
  "api repos/example/repository/issues/"*"/comments")
    # Writing a comment is the call that carries a body, and reading them is
    # the one that does not
    if [[ "$*" == *"--raw-field body="* ]]; then
      printf '{}\n'
      exit 0
    fi
    case "$2" in
      */issues/12/comments)
        printf '[{"id":1201,"body":"<!-- auto-update-pull-request-branches: conflict -->\\n\\nold"},{"id":1202,"body":"a comment from a person"}]\n'
        ;;
      */issues/14/comments)
        printf '[{"id":1401,"body":"<!-- auto-update-pull-request-branches: conflict -->\\n\\nold"}]\n'
        ;;
      *)
        printf '[]\n'
        ;;
    esac
    ;;
  "api --method")
    # Deleting a comment answers nothing the step reads
    ;;
  *)
    printf 'unexpected gh call : %s\n' "$*" >&2
    exit 64
    ;;
esac
STUB
  chmod 0755 "$SANDBOX/bin/gh"

  local -r CALL_LOG="$SANDBOX/gh_calls.log"
  : > "$CALL_LOG"

  local OUTPUT
  if ! OUTPUT=$(
    env MOCK_GH_CALL_LOG="$CALL_LOG" \
      GH_TOKEN=unused \
      UPDATING_AS="the GitHub App" \
      REPOSITORY=example/repository \
      FALL_BACK_TO_MERGE=true \
      GITHUB_STEP_SUMMARY="$SANDBOX/summary" \
      PATH="$SANDBOX/bin:$PATH" \
      bash "$SCRIPT" 2>&1
  ); then
    fail "the branch updater's step failed against the stubbed API" "$OUTPUT"
    return 1
  fi

  local -r CALLS=$(cat "$CALL_LOG")
  assert_not_contains "$CALLS" "DEPENDABOT_NODE" \
    "the branch updater must never push an update onto a Dependabot pull request"
  assert_not_contains "$CALLS" "dependabot-sha" \
    "a Dependabot pull request is left alone before anything is measured on it"
  assert_contains "$CALLS" "pullRequestId=PERSON_NODE" \
    "the other pull request, just as far behind, still has to be updated"
  assert_contains "$OUTPUT" "Pull request #11 is Dependabot's" \
    "the log should say why the Dependabot pull request was skipped"
  assert_not_contains "$CALLS" "issues/11/" \
    "a Dependabot pull request never reaches the comment API, whatever its mergeability"

  # The conflict that has never been announced : one comment, with the marker and
  # the text, and no other pull request gets one
  assert_contains "$CALLS" "issues/13/comments --raw-field body=<!-- auto-update-pull-request-branches: conflict -->" \
    "a pull request that conflicts with master has to be told so, behind the marker a later pass looks for"
  assert_contains "$CALLS" 'This pull request conflicts with `master`, so the branch updater cannot bring it level on its own' \
    "the comment has to say what is wrong and that the updater cannot mend it"
  assert_equals "1" "$(grep -c -- '--raw-field body=' "$CALL_LOG")" \
    "exactly one comment is written : the other conflict already carries one, and the rest have none"

  # The one announced on an earlier pass is neither written nor deleted again,
  # since its conflict is still there
  assert_not_contains "$CALLS" "issues/14/comments --raw-field" \
    "a conflict already announced is not announced twice"
  assert_not_contains "$CALLS" "issues/comments/1401" \
    "the comment of a conflict that is still there is not deleted"
  assert_contains "$OUTPUT" "Pull request #14 conflicts with master, leaving it to its author." \
    "the log should still say that the updater left the conflict to its author"

  # The pull request conflict-free again loses the updater's comment and only that
  assert_contains "$CALLS" "--method DELETE repos/example/repository/issues/comments/1201" \
    "the comment announcing a conflict that is over has to go, so the next one is announced afresh"
  assert_not_contains "$CALLS" "issues/comments/1202" \
    "a comment that is not the updater's is never deleted"

  assert_equals "Updated 1 pull request(s), announced 1 conflict(s)." "$(cat "$SANDBOX/summary")" \
    "only the person's pull request is counted as updated, and only the unannounced conflict as announced"
}

# The "detect-reuse" jobs of "Tests" and "Shellcheck" decide, on a push to
# master, whether the pull request that push merged was already checked on the
# exact tree it lands, and if so they skip the run and republish its result. A
# wrong "yes" is a green check on master for a tree nothing ran on, and no pull
# request ever exercises these blocks : they only act on master, after the merge.
#
# So they are run here, as written in the workflow, against a real repository :
# one standing in for GitHub's copy, holding master and the pull request's head
# under refs/pull/<number>/head, and a clone of it checked out on the merge, the
# way the job's own checkout is. GitHub's API is a stubbed gh first in the PATH
# that answers from that same repository, so a question asked the wrong way
# round gets the answer the real API would give, not the one a test hoped for.
#
# The question these exist for is the one the up-to-date requirement used to
# answer : with master taking pull requests that are behind it, a pull request's
# run tested it merged into whichever master it saw, and a matching tree alone
# does not prove that master was the one this push was made on.
readonly REUSE_DECIDING_WORKFLOWS=(".github/workflows/tests.yml" ".github/workflows/shellcheck.yml")
readonly REUSE_PULL_REQUEST_NUMBER=7
readonly REUSE_RUN_ID=4242

# The suite also runs inside the built image, which carries neither the
# workflows nor git
# Usage : if ! reuse_decision_can_run; then skip_test "..."; return 0; fi
function reuse_decision_can_run() {
  local WORKFLOW
  for WORKFLOW in "${REUSE_DECIDING_WORKFLOWS[@]}"; do
    [ -f "$REPO_ROOT/$WORKFLOW" ] || return 1
  done
  command -v git > /dev/null 2>&1
}

# Builds GitHub's copy of the repository and the job's checkout of the merge.
# The pull request branches off the first commit of master and adds one file ;
# what master does meanwhile is the scenario :
#   level     nothing, so the pull request is merged up to date
#   moved     another pull request adds a file first, so this one lands behind
#   reverted  another pull request is merged and then reverted, so this one
#             lands behind master with a tree identical to its own head
# Usage : build_reuse_sandbox level|moved|reverted
#         -> REUSE_SANDBOX, REUSE_CHECKOUT, REUSE_HEAD_SHA,
#            REUSE_PREVIOUS_MASTER_SHA, REUSE_MERGE_SHA
function build_reuse_sandbox() {
  local -r MASTER_HISTORY="$1"

  REUSE_SANDBOX="$(mktemp -d)"
  local -r ORIGIN="$REUSE_SANDBOX/origin"
  REUSE_CHECKOUT="$REUSE_SANDBOX/checkout"

  git init --quiet --initial-branch=master "$ORIGIN"
  git -C "$ORIGIN" config user.name "Maintainer"
  git -C "$ORIGIN" config user.email "maintainer@example.org"
  git -C "$ORIGIN" config commit.gpgsign false

  printf 'base\n' > "$ORIGIN/base.txt"
  git -C "$ORIGIN" add base.txt
  git -C "$ORIGIN" commit --quiet --no-verify -m "The commit the pull request starts from"

  git -C "$ORIGIN" checkout --quiet -b pull-request
  printf 'change\n' > "$ORIGIN/change.txt"
  git -C "$ORIGIN" add change.txt
  git -C "$ORIGIN" commit --quiet --no-verify -m "The pull request"
  REUSE_HEAD_SHA="$(git -C "$ORIGIN" rev-parse HEAD)"
  git -C "$ORIGIN" update-ref "refs/pull/$REUSE_PULL_REQUEST_NUMBER/head" "$REUSE_HEAD_SHA"
  git -C "$ORIGIN" checkout --quiet master

  if [ "$MASTER_HISTORY" != level ]; then
    printf 'other\n' > "$ORIGIN/other.txt"
    git -C "$ORIGIN" add other.txt
    git -C "$ORIGIN" commit --quiet --no-verify -m "Another pull request"
  fi
  if [ "$MASTER_HISTORY" = reverted ]; then
    git -C "$ORIGIN" revert --no-edit HEAD > /dev/null
  fi
  REUSE_PREVIOUS_MASTER_SHA="$(git -C "$ORIGIN" rev-parse HEAD)"

  # How the pull request is merged here : a squash
  git -C "$ORIGIN" merge --quiet --squash pull-request > /dev/null
  git -C "$ORIGIN" commit --quiet --no-verify -m "The pull request, squashed"
  REUSE_MERGE_SHA="$(git -C "$ORIGIN" rev-parse HEAD)"

  git clone --quiet "file://$ORIGIN" "$REUSE_CHECKOUT"
  git -C "$REUSE_CHECKOUT" checkout --quiet --detach "$REUSE_MERGE_SHA"

  mkdir -p "$REUSE_SANDBOX/bin"
  cat > "$REUSE_SANDBOX/bin/gh" << 'STUB'
#!/bin/bash
# Answers the five API calls the blocks make, in the shapes they make them, from
# the repository standing in for GitHub's. The --jq filter is not applied : each
# answer is already what that filter extracts. Anything else is refused, so a
# call the stub was not written for fails loudly instead of answering empty
set -uo pipefail

printf '%s\n' "$*" >> "$MOCK_GH_CALL_LOG"

[ "${1:-}" = api ] || { printf 'unexpected gh call : %s\n' "$*" >&2; exit 64; }
shift
[ "${1:-}" = --paginate ] && shift

ENDPOINT="${1:-}"
case "$ENDPOINT" in
  "repos/{owner}/{repo}/commits/$MOCK_MERGE_SHA/pulls")
    printf '%s\n' "$MOCK_PULL_REQUEST_NUMBER"
    ;;
  "repos/{owner}/{repo}/pulls/$MOCK_PULL_REQUEST_NUMBER")
    git -C "$MOCK_ORIGIN" rev-parse "refs/pull/$MOCK_PULL_REQUEST_NUMBER/head"
    ;;
  "repos/{owner}/{repo}/compare/"*...*)
    # behind_by : the commits the base side has and the head side does not
    RANGE="${ENDPOINT#"repos/{owner}/{repo}/compare/"}"
    git -C "$MOCK_ORIGIN" rev-list --count "${RANGE#*...}..${RANGE%%...*}"
    ;;
  "repos/{owner}/{repo}/commits/"*"/check-runs")
    printf 'success\n'
    ;;
  "repos/{owner}/{repo}/actions/workflows/tests.yml/runs?"*)
    printf '%s\n' "$MOCK_RUN_ID"
    ;;
  *)
    printf 'unexpected gh call : %s\n' "$*" >&2
    exit 64
    ;;
esac
STUB
  chmod 0755 "$REUSE_SANDBOX/bin/gh"

  export MOCK_GH_CALL_LOG="$REUSE_SANDBOX/gh_calls.log"
  export MOCK_ORIGIN="$ORIGIN"
  export MOCK_MERGE_SHA="$REUSE_MERGE_SHA"
  export MOCK_PULL_REQUEST_NUMBER="$REUSE_PULL_REQUEST_NUMBER"
  export MOCK_RUN_ID="$REUSE_RUN_ID"
  : > "$MOCK_GH_CALL_LOG"
}

function teardown_reuse_sandbox() {
  [ -n "${REUSE_SANDBOX:-}" ] && rm -rf "$REUSE_SANDBOX"
}

# Runs one workflow's decision against the sandbox, as the push of the merge to
# master, with the shell GitHub gives a "run:" that names none, and prints the
# value it wrote to its output : the run ID or "true" to reuse, empty to run for
# real. Fails, printing why, when the block cannot be found or does not reach
# the line that writes its output -- an empty value is only an answer when the
# block got as far as giving it
# Usage : if ! DECISION=$(run_reuse_decision WORKFLOW); then fail "$DECISION"; fi
function run_reuse_decision() {
  local -r WORKFLOW_FILE="$REPO_ROOT/$1"
  local -r EXTRACTION_DIRECTORY="$REUSE_SANDBOX/blocks/${1//\//_}"
  local -r OUTPUT_FILE="$REUSE_SANDBOX/output"
  mkdir -p "$EXTRACTION_DIRECTORY"

  local RUN_LINE
  RUN_LINE=$(awk '
    index($0, "- name: Decide whether to reuse a pull request") { found = 1 }
    found && /^[ \t-]*run:/ { print FNR; exit }
  ' "$WORKFLOW_FILE")

  local SCRIPT
  SCRIPT=$(extract_workflow_run_blocks "$WORKFLOW_FILE" "$EXTRACTION_DIRECTORY" |
    awk -F '\t' -v LINE="$RUN_LINE" '$1 == LINE { print $2 }')
  if [ -z "$RUN_LINE" ] || [ ! -f "$SCRIPT" ]; then
    printf 'no "Decide whether to reuse" step with a run: block in %s\n' "$1"
    return 1
  fi

  # An expression written into the block would reach bash as "${{ ... }}", a bad
  # substitution : what GitHub supplies has to come in through the environment
  if grep -q '\${{' "$SCRIPT"; then
    printf 'the decision in %s carries a ${{ }} expression, so it cannot run as it stands\n' "$1"
    return 1
  fi

  : > "$OUTPUT_FILE"
  local ERRORS
  ERRORS=$(
    cd "$REUSE_CHECKOUT" &&
      env GITHUB_EVENT_NAME=push \
        GITHUB_SHA="$REUSE_MERGE_SHA" \
        PREVIOUS_MASTER_SHA="$REUSE_PREVIOUS_MASTER_SHA" \
        GITHUB_OUTPUT="$OUTPUT_FILE" \
        GH_TOKEN=unused \
        PATH="$REUSE_SANDBOX/bin:$PATH" \
        bash -e "$SCRIPT" 2>&1
  )

  if ! grep -q '^[a-z-]*=' "$OUTPUT_FILE"; then
    printf 'the decision in %s stopped before writing its output : %s\n' "$1" "$ERRORS"
    return 1
  fi
  sed -n 's/^[a-z-]*=//p' "$OUTPUT_FILE"
}

function test_a_merge_of_a_pull_request_level_with_master_reuses_its_checks() {
  if ! reuse_decision_can_run; then
    skip_test "no .github/workflows next to the scripts, or no git"
    return 0
  fi

  # The case both jobs exist for (#500, #502) : nothing else reached master
  # while the pull request was open, so its runs tested this very tree
  build_reuse_sandbox level

  local WORKFLOW DECISION
  for WORKFLOW in "${REUSE_DECIDING_WORKFLOWS[@]}"; do
    if ! DECISION=$(run_reuse_decision "$WORKFLOW"); then
      fail "$DECISION"
      continue
    fi
    assert_not_empty "$DECISION" \
      "$WORKFLOW should reuse the checks of a pull request merged level with master, which ran on this exact tree"
  done

  # Asked the right way round : does the head contain master's previous tip,
  # and not the reverse, which a pull request with any commit of its own fails
  assert_contains "$(cat "$MOCK_GH_CALL_LOG")" "compare/$REUSE_PREVIOUS_MASTER_SHA...$REUSE_HEAD_SHA" \
    "the decision should ask whether the head contains master's tip from before the push"

  teardown_reuse_sandbox
}

function test_a_merge_of_a_pull_request_behind_master_is_checked_again() {
  if ! reuse_decision_can_run; then
    skip_test "no .github/workflows next to the scripts, or no git"
    return 0
  fi

  # What branches not being required to be up to date lets through, wherever
  # the branch updater did not reach : another pull request landed first, so
  # the tree this merge lands is one no run of this pull request ever saw, and
  # the suite has to run on master
  build_reuse_sandbox moved

  local WORKFLOW DECISION
  for WORKFLOW in "${REUSE_DECIDING_WORKFLOWS[@]}"; do
    if ! DECISION=$(run_reuse_decision "$WORKFLOW"); then
      fail "$DECISION"
      continue
    fi
    assert_empty "$DECISION" \
      "$WORKFLOW should run for real on a merge whose tree differs from the pull request's head"
  done

  teardown_reuse_sandbox
}

function test_a_merge_level_with_its_head_only_after_a_revert_is_checked_again() {
  if ! reuse_decision_can_run; then
    skip_test "no .github/workflows next to the scripts, or no git"
    return 0
  fi

  # The case a tree comparison alone lets through. Another pull request was
  # merged and then reverted while this one was open, so the merge's tree is
  # identical to this head's -- while a run of this pull request made between
  # the two tested it with the reverted commit in it. Only the head containing
  # master's previous tip rules that out, and here it does not
  build_reuse_sandbox reverted

  local HEAD_TREE MERGE_TREE
  HEAD_TREE=$(git -C "$REUSE_CHECKOUT" rev-parse "$REUSE_HEAD_SHA^{tree}")
  MERGE_TREE=$(git -C "$REUSE_CHECKOUT" rev-parse "$REUSE_MERGE_SHA^{tree}")
  if ! assert_equals "$HEAD_TREE" "$MERGE_TREE" \
    "the sandbox should hold a merge whose tree is the head's, or this case proves nothing"; then
    teardown_reuse_sandbox
    return 1
  fi

  local WORKFLOW DECISION
  for WORKFLOW in "${REUSE_DECIDING_WORKFLOWS[@]}"; do
    if ! DECISION=$(run_reuse_decision "$WORKFLOW"); then
      fail "$DECISION"
      continue
    fi
    assert_empty "$DECISION" \
      "$WORKFLOW should run for real when the pull request's head does not contain master's previous tip, however equal the trees"
  done

  teardown_reuse_sandbox
}
