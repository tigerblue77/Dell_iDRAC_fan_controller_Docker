#!/bin/bash

# Answers "does this version already have its release note ?", which is the
# question the release build has to ask before handing a tag to
# softprops/action-gh-release.
#
# Why it has to be asked at all :
#
# The action does not update a release note in place, it appends to it. A step
# that only asks it to generate notes hands it no body of its own, so on a tag
# that already has a release it re-sends the body already there ("body =
# workflowBody || existingReleaseBody", src/github.ts) and then appends the notes
# it has just generated to that ("body = `${body}\n\n${releaseNotes.data.body}`",
# in prepareReleaseMutation). First run, nothing is there, and one copy comes
# out. Second run, the copy the first one wrote is what gets appended to. v1.71
# was re-fired once and carries its changelog twice ; v1.75 did too and was
# repaired by hand. The "append_body" input is not what does this, and setting it
# to false changes nothing : it only ever applies to a body the step supplies
# itself.
#
# Re-firing a release build is the documented recovery path for a build that died
# before publishing, and what it is fired for is the image. The changelog of a
# version that has already announced itself is not what a re-fire is asked to
# refresh, and refreshing it would rewrite a published note out of today's pull
# request titles and today's contributor names. So the note is written once, when
# the version has none, and a re-fire leaves the release it finds alone.
#
# Nothing being rewritten is also what makes anything hand-written safe. v1.72
# and v1.75 carry an upgrade note above their changelog, written for the readers
# of exactly those versions : it survives here by construction, rather than by a
# rule about where in the body it is allowed to be written.
#
# What this deliberately does not cover : GitHub answers this question about
# PUBLISHED releases only, and a draft is where a note drafted by hand waits for
# its tag to be pushed. The action does find drafts - it lists the releases,
# "Because GitHub does not expose draft releases through that endpoint" - and
# appends to what it finds there, which is what makes a hand-drafted note come
# out as its own words followed by the changelog. The same path is the one window
# where a re-fire can still duplicate one : a run cancelled between the draft the
# action creates and the moment it publishes it leaves a draft already carrying
# the generated notes, and the next run appends to that. One copy at most, once,
# and visible on the release page.
#
# Exit 0 : it already has one, and nothing has to be written.
# Exit 1 : it has none, or GitHub could not be asked. Write it.
# Exit 2 : called wrong.
#
# Which answer sits on which code is not arbitrary. Under "set -e" the status a
# script exits with when something inside it breaks is 1, so 1 is deliberately
# the answer that costs the least to be wrong about : a run that dies here writes
# a release note that may already exist, where the other way round it would leave
# a published version announced by nothing, on a green run.
#
# Usage : STATUS=0; .github/release_note_already_exists.sh <owner/repository> <tag> || STATUS=$?

set -euo pipefail

if [ "$#" -ne 2 ]; then
  printf 'Usage : %s <owner/repository> <tag>\n' "${0##*/}" >&2
  exit 2
fi

readonly REPOSITORY="$1"
readonly TAG="$2"

# Whatever gh has to say about the call, kept without a temporary file to write
# it into : there is no scratch file here to fail to create, and no failure
# before the question is asked to be mistaken for an answer to it.
# "2>&1 >/dev/null" and not the other order : the first sends the diagnostics to
# the substitution, the second drops the release gh would otherwise print
if DIAGNOSTICS="$(gh api "repos/$REPOSITORY/releases/tags/$TAG" 2>&1 > /dev/null)"; then
  printf '%s already has a release, its note is left exactly as it is\n' "$TAG"
  exit 0
fi

# Three answers and not two, the way every other decision in this repository
# reads a registry or an API : "there is no release" and "GitHub did not answer"
# are not the same thing. They lead to the same place here, and they are still
# told apart, because only one of them is worth a warning
if printf '%s' "$DIAGNOSTICS" | grep -q 'HTTP 404'; then
  printf '%s has no release, its note is written now\n' "$TAG"
  exit 1
fi

# Unlike every other unreadable answer in this repository this one goes on rather
# than stops, because the two mistakes are not the same size. A note written
# twice shows on the release page and is repaired in one edit ; a note never
# written at all is a version that announces itself nowhere, which is what left
# seventeen of them behind a GitHub release with nothing to pull
printf '%s\n' "$DIAGNOSTICS" >&2
printf '::warning::Could not tell whether %s already has a release, so its note is written rather than risk a version that announces itself nowhere. If it had one, it now carries its changelog twice and one copy has to be deleted by hand\n' \
  "$TAG"
exit 1
