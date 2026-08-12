#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# Docker Hub is where most users meet this image, and the page it shows them is
# not stored here : it is uploaded by the "Docker Hub description" workflow,
# which runs .github/generate_dockerhub_description.sh. Like the two publishing
# workflows, that one never runs on a pull request, and what it produces is read
# by nobody in this repository. These are the checks that read it anyway.
#
# That page used to be README.md, rendered down to Docker Hub's 25,000-character
# limit by dropping whole sections from the end. These cases used to guard the
# distance between the page and the next section it would lose, because an
# ordinary paragraph anywhere in the README could spend it. The page is now a
# short pointer at the documentation on GitHub, which is why that guard and the
# arithmetic behind it are gone : the failure it existed to catch cannot happen
# to a page that says nothing the documentation can change.
#
# What is left to check is that the pointer points somewhere, that it points
# there in a way Docker Hub can follow, and that it stays independent of the
# documentation -- the last being the property the whole change was made for.

# The owner and name a real run gets from GITHUB_REPOSITORY. Anything would do,
# it is pinned here so that the links the generator builds can be asserted on
# without the assertions depending on which fork the suite runs from
readonly DOCKERHUB_DESCRIPTION_REPOSITORY="owner/repository"
readonly DOCKERHUB_DESCRIPTION_REPOSITORY_URL="https://github.com/$DOCKERHUB_DESCRIPTION_REPOSITORY"

# Docker Hub's own limit, stated again rather than read from the generator : the
# point of a test is to hold the contract from outside
readonly DOCKERHUB_DESCRIPTION_SIZE_LIMIT=25000

# What the page is allowed to weigh. Far below the limit on purpose : this is
# not headroom to be spent, it is a bound that says the page is a pointer and
# not a copy of the documentation. A page that grows past this has started
# becoming the second thing to keep correct that the rewrite removed
readonly DOCKERHUB_DESCRIPTION_MAXIMUM_SIZE=2000

readonly DOCKERHUB_DESCRIPTION_GENERATOR=".github/generate_dockerhub_description.sh"
readonly DOCKERHUB_DESCRIPTION_WORKFLOW=".github/workflows/dockerhub_description.yml"

# The suite also runs inside the built image, which carries the scripts but not
# the .github directory
# Usage : if ! dockerhub_description_can_be_rendered; then skip_test "..."; return 0; fi
function dockerhub_description_can_be_rendered() {
  [ -x "$REPO_ROOT/$DOCKERHUB_DESCRIPTION_GENERATOR" ]
}

# Usage : DESCRIPTION="$(rendered_dockerhub_description)"
function rendered_dockerhub_description() {
  GITHUB_REPOSITORY="$DOCKERHUB_DESCRIPTION_REPOSITORY" \
    "$REPO_ROOT/$DOCKERHUB_DESCRIPTION_GENERATOR"
}

function test_the_dockerhub_description_stays_a_pointer_and_not_a_second_copy() {
  # Docker Hub does not refuse an oversized description, the action uploading it
  # truncates it. The old page lived a few hundred characters from that edge and
  # every documentation change moved it ; this one is nowhere near, and the
  # bound is here so that it stays a pointer rather than drifting back into
  # being a copy of the README with a different set of gaps
  if ! dockerhub_description_can_be_rendered; then
    skip_test "no .github next to the scripts"
    return 0
  fi

  local DESCRIPTION
  DESCRIPTION="$(rendered_dockerhub_description)"

  local SIZE
  SIZE="$(printf '%s' "$DESCRIPTION" | wc -c)"
  # BSD wc pads its output, GNU wc does not
  SIZE="${SIZE//[[:space:]]/}"

  if [ "$SIZE" -gt "$DOCKERHUB_DESCRIPTION_SIZE_LIMIT" ]; then
    fail "the page is $SIZE characters long, Docker Hub keeps the first $DOCKERHUB_DESCRIPTION_SIZE_LIMIT and drops the rest"
    return 0
  fi

  if [ "$SIZE" -le "$DOCKERHUB_DESCRIPTION_MAXIMUM_SIZE" ]; then
    pass
  else
    fail "the Docker Hub page is $SIZE characters long, and a pointer at the documentation should not need $DOCKERHUB_DESCRIPTION_MAXIMUM_SIZE" \
      "this page exists so there is one page to keep correct instead of two ; documentation belongs in README.md, which it links to"
  fi
}

function test_the_dockerhub_description_does_not_depend_on_the_documentation() {
  # The property the rewrite was made for. The page used to be rendered from
  # README.md, so every documentation change could alter it -- and did, silently,
  # since no pull request runs the workflow that publishes it. Rendering the
  # generator on its own, with no repository around it at all, has to produce
  # exactly what rendering it here produces : that is what "the documentation
  # cannot break this page" means, checked rather than asserted in a comment
  if ! dockerhub_description_can_be_rendered; then
    skip_test "no .github next to the scripts"
    return 0
  fi

  local ISOLATED_DIRECTORY
  ISOLATED_DIRECTORY="$(mktemp -d)"
  cp "$REPO_ROOT/$DOCKERHUB_DESCRIPTION_GENERATOR" "$ISOLATED_DIRECTORY/generator.sh"

  local ISOLATED_DESCRIPTION
  ISOLATED_DESCRIPTION="$(GITHUB_REPOSITORY="$DOCKERHUB_DESCRIPTION_REPOSITORY" "$ISOLATED_DIRECTORY/generator.sh")"
  rm -rf "$ISOLATED_DIRECTORY"

  assert_equals "$(rendered_dockerhub_description)" "$ISOLATED_DESCRIPTION" \
    "the page has to be the same whether or not the documentation is next to it, or a README change can alter it again"
}

function test_the_dockerhub_description_carries_no_link_docker_hub_cannot_resolve() {
  # A relative link resolves against Docker Hub's own domain there, and an
  # anchor points at an id that page does not have. Both render as a working
  # link and answer a 404
  if ! dockerhub_description_can_be_rendered; then
    skip_test "no .github next to the scripts"
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
    "an anchor into this page goes nowhere on Docker Hub"
}

function test_the_dockerhub_description_sends_the_reader_to_the_documentation() {
  # The one thing this page is for. A reader who reaches Docker Hub instead of
  # GitHub has to leave with the documentation, and with the headings that tell
  # them it answers their question -- otherwise the pointer costs them the visit
  if ! dockerhub_description_can_be_rendered; then
    skip_test "no .github next to the scripts"
    return 0
  fi

  local DESCRIPTION
  DESCRIPTION="$(rendered_dockerhub_description)"

  assert_contains "$DESCRIPTION" "$DOCKERHUB_DESCRIPTION_REPOSITORY_URL#readme" \
    "the page has to link the README it stands in for"

  local SUBJECT
  for SUBJECT in "Requirements" "Usage" "Parameters" "Troubleshooting"; do
    assert_contains "$DESCRIPTION" "$SUBJECT" \
      "a reader has to be able to tell that \"$SUBJECT\" is answered on the other side of the link"
  done

  assert_contains "$DESCRIPTION" "$DOCKERHUB_DESCRIPTION_REPOSITORY_URL/issues" \
    "the page has to say where a question goes"
}

function test_the_dockerhub_description_states_the_licence() {
  # This page is where a company evaluating the image decides whether it may
  # ship it, and the licence is not something to make them follow a link for.
  # The identifier names the AGPL alone : the commercial alternative is
  # negotiated per licensee rather than granted by this page
  if ! dockerhub_description_can_be_rendered; then
    skip_test "no .github next to the scripts"
    return 0
  fi

  local DESCRIPTION
  DESCRIPTION="$(rendered_dockerhub_description)"

  assert_contains "$DESCRIPTION" "AGPL" \
    "the page has to name the licence the image is conveyed under"
  assert_contains "$DESCRIPTION" "$DOCKERHUB_DESCRIPTION_REPOSITORY_URL/blob/HEAD/LICENSE-COMMERCIAL.md" \
    "the page has to link the commercial licence, for the readers who cannot meet the AGPL"
}

function test_the_dockerhub_description_workflow_publishes_what_this_generates() {
  # The generator and the workflow are a pair : nothing in this repository reads
  # what is published, so a workflow that stopped calling this script, or called
  # it and uploaded something else, would go unnoticed until somebody looked at
  # Docker Hub
  if [ ! -f "$REPO_ROOT/$DOCKERHUB_DESCRIPTION_WORKFLOW" ]; then
    skip_test "no .github next to the scripts"
    return 0
  fi

  local WORKFLOW
  WORKFLOW="$(< "$REPO_ROOT/$DOCKERHUB_DESCRIPTION_WORKFLOW")"

  assert_contains "$WORKFLOW" "$DOCKERHUB_DESCRIPTION_GENERATOR" \
    "the workflow has to build the page with the generator these cases check"
  assert_contains "$WORKFLOW" "readme-filepath" \
    "the workflow has to hand the generated file to the action that uploads it"

  # The page no longer depends on README.md, so a README change must no longer
  # republish it : the run would upload a page identical to the one already
  # there, on every documentation commit
  assert_not_contains "$WORKFLOW" "- README.md" \
    "the page does not depend on README.md any more, so a README change should not trigger a republication"
}
