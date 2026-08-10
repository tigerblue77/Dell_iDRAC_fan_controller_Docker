#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# Docker Hub is where most users meet this image, and the page it shows them is
# not stored here : it is uploaded by the "Docker Hub description" workflow,
# which renders README.md through .github/generate_dockerhub_description.sh.
# Like the two publishing workflows, that one never runs on a pull request, and
# what it produces is read by nobody in this repository. These are the checks
# that read it anyway.

# The owner and name a real run gets from GITHUB_REPOSITORY. Anything would do,
# it is pinned here so that the links the renderer builds can be asserted on
# without the assertions depending on which fork the suite runs from
readonly DOCKERHUB_DESCRIPTION_REPOSITORY="owner/repository"
readonly DOCKERHUB_DESCRIPTION_REPOSITORY_URL="https://github.com/$DOCKERHUB_DESCRIPTION_REPOSITORY"

# Docker Hub's own limit, stated again rather than read from the renderer : the
# point of a test is to hold the contract from outside. A renderer that raises
# its own constant should fail here, not agree with itself
readonly DOCKERHUB_DESCRIPTION_SIZE_LIMIT=25000

readonly DOCKERHUB_DESCRIPTION_GENERATOR=".github/generate_dockerhub_description.sh"
readonly DOCKERHUB_DESCRIPTION_WORKFLOW=".github/workflows/dockerhub_description.yml"

# The suite also runs inside the built image, which carries the scripts but
# neither the .github directory nor the README they are rendered from
# Usage : if ! dockerhub_description_can_be_rendered; then skip_test "..."; return 0; fi
function dockerhub_description_can_be_rendered() {
  [ -x "$REPO_ROOT/$DOCKERHUB_DESCRIPTION_GENERATOR" ] && [ -f "$REPO_ROOT/README.md" ]
}

# Usage : DESCRIPTION="$(rendered_dockerhub_description)"
function rendered_dockerhub_description() {
  GITHUB_REPOSITORY="$DOCKERHUB_DESCRIPTION_REPOSITORY" \
    "$REPO_ROOT/$DOCKERHUB_DESCRIPTION_GENERATOR" "$REPO_ROOT/README.md"
}

function test_the_dockerhub_description_fits_the_page_docker_hub_allows() {
  # This is the whole reason the README is not simply uploaded as it is : Docker
  # Hub does not refuse an oversized description, the action uploading it
  # truncates it, and a page cut in the middle of the parameters table looks
  # exactly like a page that documents that much and no more
  if ! dockerhub_description_can_be_rendered; then
    skip_test "no .github and README next to the scripts"
    return 0
  fi

  local DESCRIPTION
  DESCRIPTION="$(rendered_dockerhub_description)"

  local SIZE
  SIZE="$(printf '%s' "$DESCRIPTION" | wc -c)"
  # BSD wc pads its output, GNU wc does not
  SIZE="${SIZE//[[:space:]]/}"

  if [ "$SIZE" -le "$DOCKERHUB_DESCRIPTION_SIZE_LIMIT" ]; then
    pass
  else
    fail "the rendered page is $SIZE characters long, Docker Hub keeps the first $DOCKERHUB_DESCRIPTION_SIZE_LIMIT and drops the rest"
  fi
}

function test_the_dockerhub_description_carries_no_link_docker_hub_cannot_resolve() {
  # A relative link resolves against Docker Hub's own domain there, and the
  # anchors the README navigates itself with point at ids that page does not
  # have. Both render as a working link and answer a 404
  if ! dockerhub_description_can_be_rendered; then
    skip_test "no .github and README next to the scripts"
    return 0
  fi

  local DESCRIPTION
  DESCRIPTION="$(rendered_dockerhub_description)"

  local RELATIVE_LINKS
  RELATIVE_LINKS="$(printf '%s\n' "$DESCRIPTION" |
    grep -noE '\]\([^)]*\)' |
    grep -vE '\((https?://|mailto:)' || true)"
  assert_empty "$RELATIVE_LINKS" \
    "every link on the Docker Hub page has to be absolute, it is not served from GitHub"

  local SELF_ANCHORS
  SELF_ANCHORS="$(printf '%s\n' "$DESCRIPTION" | grep -nE 'href="#|back to top' || true)"
  assert_empty "$SELF_ANCHORS" \
    "the anchors the README navigates itself with go nowhere on the Docker Hub page"
}

function test_no_readme_section_disappears_from_the_dockerhub_description() {
  # The renderer drops whole sections from the end until what is left fits, so
  # which ones it drops changes as the README grows. What must not change is
  # that a dropped section is still named on the page, with a link to it :
  # otherwise a section quietly stops existing for every reader who arrives
  # through Docker Hub, and nothing anywhere says so
  if ! dockerhub_description_can_be_rendered; then
    skip_test "no .github and README next to the scripts"
    return 0
  fi

  local DESCRIPTION
  DESCRIPTION="$(rendered_dockerhub_description)"

  local SECTION_TITLE
  while IFS= read -r SECTION_TITLE; do
    [ -n "$SECTION_TITLE" ] || continue
    # The table of contents is a list of anchors and nothing else, it is
    # dropped rather than linked to
    [ "$SECTION_TITLE" != "Table of contents" ] || continue

    if printf '%s\n' "$DESCRIPTION" | grep -qxF "## $SECTION_TITLE"; then
      pass
    elif printf '%s\n' "$DESCRIPTION" | grep -qF "[$SECTION_TITLE]($DOCKERHUB_DESCRIPTION_REPOSITORY_URL"; then
      pass
    else
      fail "the README has a \"$SECTION_TITLE\" section, the Docker Hub page neither carries it nor links to it"
    fi
  done < <(grep -E '^## ' "$REPO_ROOT/README.md" | sed 's/^## //')
}

function test_the_dockerhub_description_keeps_what_the_reader_came_for() {
  # Whatever the cut leaves out, someone landing on the image's page is there to
  # find out what it needs and how to start it. These are the sections that
  # answer that, and the page is worth publishing only while it still holds them
  if ! dockerhub_description_can_be_rendered; then
    skip_test "no .github and README next to the scripts"
    return 0
  fi

  local DESCRIPTION
  DESCRIPTION="$(rendered_dockerhub_description)"

  local SECTION
  for SECTION in "Requirements" "Supported architectures" "Usage" "Parameters"; do
    assert_contains "$DESCRIPTION" "## $SECTION" \
      "the Docker Hub page has to keep its \"$SECTION\" section"
  done

  assert_contains "$DESCRIPTION" "docker run" \
    "the Docker Hub page has to show how the image is started"
  assert_contains "$DESCRIPTION" "$DOCKERHUB_DESCRIPTION_REPOSITORY_URL" \
    "the Docker Hub page has to link back to the repository it is rendered from"
}

function test_the_dockerhub_description_states_the_licence_whatever_the_cut() {
  # The project is dual-licensed, and the page Docker Hub shows is where a
  # company evaluating the image decides whether it may ship it. The README's
  # "License" section cannot answer that here : it is the last section, so it is
  # the first the cut drops, and it has never once reached the page. The footer
  # is outside the cut, which is why the terms are stated there instead.
  #
  # Asserted on the rendered page rather than on the footer function, because
  # what matters is that the answer is on the page no matter how much of the
  # README had to be left out
  if ! dockerhub_description_can_be_rendered; then
    skip_test "no .github and README next to the scripts"
    return 0
  fi

  local DESCRIPTION
  DESCRIPTION="$(rendered_dockerhub_description)"

  assert_contains "$DESCRIPTION" "AGPL" \
    "the Docker Hub page has to name the licence the image is published under"
  assert_contains "$DESCRIPTION" "$DOCKERHUB_DESCRIPTION_REPOSITORY_URL/blob/HEAD/LICENSE-COMMERCIAL.md" \
    "the Docker Hub page has to link the commercial licence, the reader who needs it arrives here"
}

function test_the_dockerhub_description_workflow_renders_the_page_it_publishes() {
  # The renderer and the workflow only meet at a path written in both. Renaming
  # one of them is caught here rather than by a red run of the one workflow no
  # pull request fires
  if [ ! -f "$REPO_ROOT/$DOCKERHUB_DESCRIPTION_WORKFLOW" ]; then
    skip_test "no .github/workflows next to the scripts"
    return 0
  fi

  local -r WORKFLOW_CONTENT="$(cat "$REPO_ROOT/$DOCKERHUB_DESCRIPTION_WORKFLOW")"

  assert_contains "$WORKFLOW_CONTENT" "$DOCKERHUB_DESCRIPTION_GENERATOR" \
    "the workflow has to render the page through $DOCKERHUB_DESCRIPTION_GENERATOR"

  if [ -f "$REPO_ROOT/$DOCKERHUB_DESCRIPTION_GENERATOR" ]; then
    pass
  else
    fail "$DOCKERHUB_DESCRIPTION_WORKFLOW runs $DOCKERHUB_DESCRIPTION_GENERATOR, which does not exist"
    return 1
  fi

  # The workflow runs it as a command rather than through bash, so the bit is
  # what makes the difference between a rendered page and "Permission denied"
  if [ -x "$REPO_ROOT/$DOCKERHUB_DESCRIPTION_GENERATOR" ]; then
    pass
  else
    fail "$DOCKERHUB_DESCRIPTION_GENERATOR is run as a command by the workflow, it has to be executable"
  fi

  # A README change that never reaches the page is the drift this whole
  # workflow exists to remove. Read line by line off the file rather than
  # matched on the content read above : bash anchors a regex on the whole
  # string, so "^" there would only ever mean the first line of the workflow
  local README_TRIGGER
  README_TRIGGER="$(grep -E '^[[:space:]]+- README\.md$' "$REPO_ROOT/$DOCKERHUB_DESCRIPTION_WORKFLOW" || true)"
  assert_not_empty "$README_TRIGGER" \
    "the workflow has to list README.md among the paths it runs on"
}
