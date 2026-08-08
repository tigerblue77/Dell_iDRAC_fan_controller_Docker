#!/bin/bash

# The two workflows that publish the image are the only ones no pull request
# ever runs : "Docker image CI" fires on a version tag, "Base image refresh" on
# a schedule. A mistake in either is found at release time, or the morning
# after, by which point it has already cost a release or a night's rebuild.
# This is where they get read anyway.

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
