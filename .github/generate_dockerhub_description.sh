#!/bin/bash

# Renders README.md into the page Docker Hub shows on the image's repository,
# and prints it on stdout.
#
# Why the README is not simply uploaded as it is :
#
#   - Docker Hub caps that page at 25,000 characters, and the README passed
#     that a while ago. The action that uploads it truncates whatever it is
#     handed, which lands in the middle of the parameters table with nothing on
#     the page to say a word about it. Here the cut is made on a section
#     boundary and every section left out is named at the bottom, with a link.
#   - The README navigates itself through anchors : a table of contents, and a
#     "back to top" link under each section. Docker Hub renders the page
#     without the ids they point at, so all of them go nowhere.
#   - A relative link resolves against Docker Hub there, so "./.env.example"
#     is a 404. They are rewritten into their absolute GitHub form.
#
# Usage : .github/generate_dockerhub_description.sh [README path]

set -euo pipefail

# Docker Hub's own limit on a repository description. Counted in bytes below,
# which is the same number for the ASCII the README is almost entirely made of
# and an over-estimate for the handful of characters that are not : erring on
# the short side is what keeps the upload from being rejected
readonly DESCRIPTION_SIZE_LIMIT=25000

README_FILE="${1:-}"
if [ -z "$README_FILE" ]; then
  REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  README_FILE="$REPOSITORY_ROOT/README.md"
fi
readonly README_FILE

if [ ! -f "$README_FILE" ]; then
  printf 'No README to render at %s\n' "$README_FILE" >&2
  exit 1
fi

# The links this writes have to be absolute, so the repository they point at has
# to be known. GITHUB_REPOSITORY is set on every runner ; the git remote covers
# a run from a working copy, and having neither is not something to guess at :
# a wrong owner here is a page full of links to somebody else's repository
REPOSITORY="${GITHUB_REPOSITORY:-}"
if [ -z "$REPOSITORY" ]; then
  REMOTE_URL="$(git -C "$(dirname "$README_FILE")" remote get-url origin 2> /dev/null || true)"
  REPOSITORY="$(printf '%s' "$REMOTE_URL" | sed -E 's#^.*github\.com[:/]##; s#\.git$##')"
fi
if [ -z "$REPOSITORY" ]; then
  printf 'Set GITHUB_REPOSITORY to "owner/name" : the absolute links cannot be built without it\n' >&2
  exit 1
fi
readonly REPOSITORY

readonly REPOSITORY_URL="https://github.com/$REPOSITORY"
# "HEAD" rather than a branch name : GitHub resolves it to the repository's
# default branch, so these links keep working whatever branch this runs from,
# and survive the default branch being renamed
readonly BLOB_URL="$REPOSITORY_URL/blob/HEAD"

# "Container console log example" -> "container-console-log-example", the anchor
# GitHub gives that heading. Lowercase, spaces to hyphens, and everything that
# is neither a letter, a digit, a hyphen nor an underscore dropped. The classes
# are spelled out in ASCII on purpose : tr works on bytes, so a UTF-8 character
# must not be handed to it as something to case-fold
function anchor_of_heading() {
  local SLUG
  SLUG="$(printf '%s' "$1" | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz')"
  SLUG="${SLUG// /-}"
  SLUG="$(printf '%s' "$SLUG" | sed 's/[^a-z0-9_-]//g')"
  printf '%s' "$SLUG"
}

CLEANED_FILE="$(mktemp)"
readonly CLEANED_FILE
trap 'rm -f "$CLEANED_FILE"' EXIT

# First pass : everything that is about the README being read on GitHub rather
# than about the image
awk -v blob_url="$BLOB_URL" '
  # Rewrites the target of every markdown link on the line into an absolute one.
  # Written as a scan rather than a gsub because the replacement depends on the
  # target : an anchor becomes a link into the README, a path becomes a link
  # into the repository, and anything already absolute is left alone
  function absolutise(line,   out, opening, closing, target) {
    out = ""
    while ((opening = index(line, "](")) > 0) {
      out = out substr(line, 1, opening + 1)
      line = substr(line, opening + 2)
      closing = index(line, ")")
      # An unbalanced "](" is left exactly as it was rather than guessed at
      if (closing == 0) break
      target = substr(line, 1, closing - 1)
      out = out absolutise_target(target)
      line = substr(line, closing)
    }
    return out line
  }

  function absolutise_target(target) {
    # "#usage" : a section of the README, which only exists on GitHub
    if (target ~ /^#/) return blob_url "/README.md" target
    # "https:", "mailto:", "//host/..." : already absolute
    if (target ~ /^[a-zA-Z][a-zA-Z0-9+.-]*:/) return target
    if (target ~ /^\/\//) return target
    sub(/^\.\//, "", target)
    return blob_url "/" target
  }

  # Removing lines leaves the gaps they used to fill. Blank lines are held back
  # rather than printed as they come, so a run of them collapses to one and the
  # ones a removal left at the top of the file are dropped altogether : markdown
  # reads both the same way, and every byte saved here is a byte of
  # documentation that fits on the page. Every rule that prints flushes what is
  # held first, or it would swallow a separation that was meant to be there
  function flush_pending_blank_line() {
    if (blank_lines > 0 && printed_any) print ""
    blank_lines = 0
    printed_any = 1
  }

  # A fenced block is copied out untouched : "./Dell_iDRAC_fan_controller.sh" in
  # a shell example is a path on the reader"s machine, not a link to rewrite.
  # Its own blank lines are content, and reach the rule below while in_code
  # holds, which prints them as they are
  /^[ \t]*```/ { in_code = !in_code; flush_pending_blank_line(); print; next }
  in_code { print; next }

  # The table of contents, down to the heading that follows it : every one of
  # its entries is an anchor, and none of them resolves on Docker Hub
  /^## / && in_table_of_contents { in_table_of_contents = 0 }
  /^##[ \t]+[Tt]able of contents[ \t]*$/ { in_table_of_contents = 1; next }
  in_table_of_contents { next }

  # The div the "back to top" links target, and the links themselves
  /^<div id="top">/ { next }
  /^<p align="right">.*back to top/ { next }

  # The comments that announce each section, "<!-- USAGE -->". Invisible in both
  # renderings, so nothing on the page changes ; what this avoids is the one
  # belonging to the first dropped section being left behind by the cut below,
  # hanging under the last section that was kept
  /^[ \t]*<!--.*-->[ \t]*$/ { next }

  # A reference-style definition, "[label]: ./LICENSE". The inline form is
  # handled by absolutise() above, this one is a line of its own
  /^\[[^]]+\]:[ \t]*[^ \t]/ {
    label = $0
    sub(/:[ \t]*.*$/, ":", label)
    target = $0
    sub(/^\[[^]]+\]:[ \t]*/, "", target)
    title = ""
    if (match(target, /[ \t]+["(].*$/)) {
      title = substr(target, RSTART)
      target = substr(target, 1, RSTART - 1)
    }
    flush_pending_blank_line()
    print label " " absolutise_target(target) title
    next
  }

  /^[ \t]*$/ { blank_lines++; next }

  {
    flush_pending_blank_line()
    print absolutise($0)
  }
' "$README_FILE" > "$CLEANED_FILE"

# Second pass : where the sections start, so the cut below lands between two of
# them instead of inside one. Fence-aware, so a "## " written inside a code
# block is not mistaken for a heading
declare -a SECTION_START_LINES=()
declare -a SECTION_TITLES=()
while IFS=$'\t' read -r LINE_NUMBER TITLE; do
  SECTION_START_LINES+=("$LINE_NUMBER")
  SECTION_TITLES+=("$TITLE")
done < <(awk '
  /^[ \t]*```/ { in_code = !in_code; next }
  in_code { next }
  /^## / { printf "%d\t%s\n", FNR, substr($0, 4) }
' "$CLEANED_FILE")

readonly SECTION_COUNT="${#SECTION_START_LINES[@]}"

# The footer is what tells the reader this page is an extract and where the rest
# is. Its own size counts against the limit, so it is rebuilt for each candidate
# rather than measured once
# Usage : footer_for "Troubleshooting" "Contributing"
function footer_for() {
  printf -- '---\n\n'
  if [ "$#" -gt 0 ]; then
    printf 'Docker Hub allows %s characters on this page, which the full documentation no longer fits in. These sections are on GitHub :\n\n' \
      "$DESCRIPTION_SIZE_LIMIT"

    local DROPPED_TITLE
    for DROPPED_TITLE in "$@"; do
      printf -- '- [%s](%s/README.md#%s)\n' "$DROPPED_TITLE" "$BLOB_URL" "$(anchor_of_heading "$DROPPED_TITLE")"
    done
    printf '\n'
  fi
  printf 'Issues, discussions and the full documentation : %s\n' "$REPOSITORY_URL"
}

# Usage : byte_size "$TEXT"
function byte_size() {
  local SIZE
  SIZE="$(printf '%s' "$1" | wc -c)"
  printf '%s' "${SIZE// /}"
}

# Keep as many whole sections as fit, dropping them from the end : the reader
# who lands here wants to know what the image is, what it needs and how to run
# it, in that order, and that is the order the README already puts them in.
# Written as a search rather than a fixed list of sections to leave out so that
# the page follows the README on its own : a section that grows pushes the last
# one off, a section that shrinks brings it back
KEPT_SECTIONS="$SECTION_COUNT"
while [ "$KEPT_SECTIONS" -ge 0 ]; do
  if [ "$KEPT_SECTIONS" -eq "$SECTION_COUNT" ]; then
    BODY="$(cat "$CLEANED_FILE")"
  else
    LAST_KEPT_LINE=$(( ${SECTION_START_LINES[$KEPT_SECTIONS]} - 1 ))
    BODY="$(head -n "$LAST_KEPT_LINE" "$CLEANED_FILE")"
  fi

  DROPPED_TITLES=("${SECTION_TITLES[@]:$KEPT_SECTIONS}")
  CANDIDATE="$BODY"$'\n\n'"$(footer_for "${DROPPED_TITLES[@]}")"

  if [ "$(byte_size "$CANDIDATE")" -le "$DESCRIPTION_SIZE_LIMIT" ]; then
    printf '%s\n' "$CANDIDATE"
    exit 0
  fi

  KEPT_SECTIONS=$(( KEPT_SECTIONS - 1 ))
done

# Not reachable while the text above the first section is a title and a table of
# contents. Should that ever stop being true, a page cut mid-sentence still
# beats no page at all, and the warning says which one this is
printf '::warning::%s does not fit in %s characters before its first section, cutting inside it\n' \
  "$README_FILE" "$DESCRIPTION_SIZE_LIMIT" >&2

FOOTER="$(footer_for "${SECTION_TITLES[@]}")"
BUDGET=$(( DESCRIPTION_SIZE_LIMIT - $(byte_size "$FOOTER") - 2 ))
head -c "$BUDGET" "$CLEANED_FILE" | head -n -1
printf '\n%s\n' "$FOOTER"
