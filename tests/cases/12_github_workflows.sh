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
      fail "${WORKFLOW#$REPO_ROOT/} ends a list entry with a comment, which the action reads as part of the value" \
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
