#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# Points "latest" at the highest version actually published, in each registry it
# is given, and leaves alone the ones where it already does.
#
# Why this exists next to the check that already gates "latest" at build time,
# rather than replacing it :
#
# That check asks the registry "is a higher version already published ?", and it
# asks about ninety seconds before the push. Releases tagged inside that window
# - v1.73, v1.74 and v1.75 went out twenty-eight seconds apart - all get "no"
# for an answer, because none of them has finished publishing when the others
# ask. Each then pushes "latest", and which push lands last is settled per
# registry inside a single buildx export : that is how "latest" came to be v1.75
# on Docker Hub and v1.74 on GHCR at the same moment (issue #325).
#
# The point of running after the push is not that the window is narrower here.
# It is that once the builds HAVE published, the question stops depending on
# when it is asked : two concurrent releases reaching this script compute the
# same answer and write the same thing. The race stops mattering rather than
# being avoided more carefully.
#
# It reads before it writes and writes nothing when the two already agree, so
# the ordinary release - published on its own, "latest" already correct - costs
# two reads per registry and no write at all.
#
# Usage : .github/reconcile_latest_tag.sh <namespace/image> <registry> [registry ...]

set -euo pipefail

readonly LATEST_TAG="latest"
# Stamped on every image by both publishing workflows, and already what "Base
# image refresh" reads back to tell which version "latest" is on
readonly VERSION_LABEL="org.opencontainers.image.version"

if [ "$#" -lt 2 ]; then
  printf 'Usage : %s <namespace/image> <registry> [registry ...]\n' "${0##*/}" >&2
  exit 2
fi

IMAGE="$1"
shift
# Registry APIs reject the repository's own capitalisation, and the caller is
# likely to be holding it the way GitHub spells it
readonly IMAGE="${IMAGE,,}"
declare -ra REGISTRIES=("$@")

ERRORS_FILE="$(mktemp)"
readonly ERRORS_FILE
trap 'rm -f "$ERRORS_FILE"' EXIT

# Three answers and not two, for the reason the build-time check gives : "the
# registry did not answer" is not "there is nothing there". 0 published, 1
# nothing under that tag, 2 no usable answer.
# Note what is deliberately absent from the wordings below : "denied" and
# "unauthorized". A token that cannot read the package must never look like an
# empty registry, that is exactly how "latest" would walk backwards on a
# permissions mistake.
# Usage : tag_is_published "ghcr.io/owner/image:v1.75"
function tag_is_published() {
  if docker buildx imagetools inspect "$1" --format '{{json .Manifest}}' > /dev/null 2>"$ERRORS_FILE"; then
    return 0
  fi
  if grep -qiE 'not found|manifest unknown|name unknown' "$ERRORS_FILE"; then
    return 1
  fi
  cat "$ERRORS_FILE" >&2
  return 2
}

# Which version a tag is on, read off the label rather than compared on digests.
# An index re-created under a second name can be re-marshalled into different
# bytes for the same content, so a digest comparison would find a difference
# that is not one, rewrite "latest" over it, and do so again on every release
# forever. The label moves with the image and answers the question that is
# actually being asked.
# Same three answers as above.
# Usage : VERSION="$(version_of_tag "ghcr.io/owner/image:latest")"
function version_of_tag() {
  local CONFIG
  if CONFIG="$(docker buildx imagetools inspect "$1" --format '{{json .Image}}' 2>"$ERRORS_FILE")"; then
    # A multi-platform image answers with one config per platform, a
    # single-platform one with the config itself. Both publishers stamp the
    # same version on every platform, so the first one found is the answer
    printf '%s' "$CONFIG" |
      jq -r 'if has("config") then [.] else [.[]] end
             | map(.config.Labels["'"$VERSION_LABEL"'"] // empty)
             | first // ""'
    return 0
  fi
  if grep -qiE 'not found|manifest unknown|name unknown' "$ERRORS_FILE"; then
    return 1
  fi
  cat "$ERRORS_FILE" >&2
  return 2
}

# Highest first, so the first tag found published in a registry is the highest
# published one there and the walk stops. A tag existing in git says someone
# typed "git tag" and nothing about an image having come out of it, which is
# why each candidate is asked of the registry rather than trusted
declare -a VERSION_TAGS=()
while IFS= read -r VERSION_TAG; do
  [ -n "$VERSION_TAG" ] || continue
  VERSION_TAGS+=("$VERSION_TAG")
done < <(git tag --list 'v[0-9]*.[0-9]*' --sort=-v:refname)

if [ "${#VERSION_TAGS[@]}" -eq 0 ]; then
  printf '::warning::No version tag exists, there is nothing to point "%s" at\n' "$LATEST_TAG"
  exit 0
fi

EXIT_CODE=0

for REGISTRY in "${REGISTRIES[@]}"; do
  REFERENCE="$REGISTRY/$IMAGE"

  HIGHEST_PUBLISHED=""
  UNREADABLE=""
  for VERSION_TAG in "${VERSION_TAGS[@]}"; do
    STATUS=0
    tag_is_published "$REFERENCE:$VERSION_TAG" || STATUS=$?
    case "$STATUS" in
      0) HIGHEST_PUBLISHED="$VERSION_TAG"; break ;;
      1) ;; # tagged in git, never pushed here : it is not a candidate
      *) UNREADABLE="$VERSION_TAG"; break ;;
    esac
  done

  # An unreadable registry is not an answer, and this script is the last thing
  # standing between a published release and the run's summary : it warns and
  # moves on rather than redden a release that did go out. The next release
  # asks again, and re-firing this tag retries it immediately
  if [ -n "$UNREADABLE" ]; then
    printf '::warning::Could not tell whether %s is published on %s, leaving its "%s" alone\n' \
      "$UNREADABLE" "$REGISTRY" "$LATEST_TAG"
    continue
  fi

  if [ -z "$HIGHEST_PUBLISHED" ]; then
    printf '::warning::No version is published on %s, there is nothing to point "%s" at\n' \
      "$REGISTRY" "$LATEST_TAG"
    continue
  fi

  STATUS=0
  CURRENT_VERSION="$(version_of_tag "$REFERENCE:$LATEST_TAG")" || STATUS=$?
  # Anything that is not "read it" or "it is not there" is the unreadable case :
  # a read that failed in a way this script has no name for is the last thing
  # that should be allowed to decide where "latest" points
  if [ "$STATUS" -ge 2 ]; then
    printf '::warning::Could not read "%s" on %s, leaving it alone\n' "$LATEST_TAG" "$REGISTRY"
    continue
  fi

  if [ "$STATUS" -eq 0 ] && [ "$CURRENT_VERSION" = "$HIGHEST_PUBLISHED" ]; then
    printf '%s : "%s" is already %s\n' "$REGISTRY" "$LATEST_TAG" "$HIGHEST_PUBLISHED"
    continue
  fi

  # "latest" already ahead of every version that resolves means a version tag
  # was deleted from under us, or something was published by hand. Pointing it
  # at the highest version still published would move "latest" BACKWARDS, and
  # handing users an older image than the one they already have is the one thing
  # no workflow here may ever do. "Base image refresh" refuses the same
  # situation for the same reason.
  #
  # It warns where that workflow errors, and the difference is deliberate : that
  # one is a maintenance run with nothing to withhold, this one stands behind a
  # release whose image did go out. Someone still has to look - a state nothing
  # here produced does not repair itself - but not at the cost of a red release
  if [ -n "$CURRENT_VERSION" ] && [ "$CURRENT_VERSION" != "$HIGHEST_PUBLISHED" ] &&
    [ "$(printf '%s\n%s\n' "$CURRENT_VERSION" "$HIGHEST_PUBLISHED" | sort -V | tail -n 1)" = "$CURRENT_VERSION" ]; then
    printf '::warning::"%s" on %s is on %s, ahead of the highest version published there (%s). Refusing to move it backwards\n' \
      "$LATEST_TAG" "$REGISTRY" "$CURRENT_VERSION" "$HIGHEST_PUBLISHED"
    continue
  fi

  # An image published before the version label existed reads as empty here, and
  # is repointed once rather than left unexplained
  printf '%s : "%s" is on %s, pointing it at %s\n' \
    "$REGISTRY" "$LATEST_TAG" "${CURRENT_VERSION:-an image carrying no version}" "$HIGHEST_PUBLISHED"

  # A manifest copy and not a rebuild : the bytes of the highest published
  # version are what "latest" has to serve, and rebuilding them would produce a
  # different image than the one that version tag resolves to
  if ! docker buildx imagetools create --tag "$REFERENCE:$LATEST_TAG" "$REFERENCE:$HIGHEST_PUBLISHED"; then
    # Knowing what to do and failing to do it is a real failure, unlike a
    # registry that could not be read : this one goes red
    printf '::error::Could not point "%s" at %s on %s\n' "$LATEST_TAG" "$HIGHEST_PUBLISHED" "$REGISTRY" >&2
    EXIT_CODE=1
    continue
  fi

  # Read back rather than trust the write. "latest" resolving to the wrong
  # version is silent by nature - every pull succeeds, they just get the wrong
  # image - so the one moment it can be caught cheaply is here
  STATUS=0
  CURRENT_VERSION="$(version_of_tag "$REFERENCE:$LATEST_TAG")" || STATUS=$?
  if [ "$STATUS" -ne 0 ] || [ "$CURRENT_VERSION" != "$HIGHEST_PUBLISHED" ]; then
    printf '::error::"%s" on %s did not settle on %s\n' "$LATEST_TAG" "$REGISTRY" "$HIGHEST_PUBLISHED" >&2
    EXIT_CODE=1
    continue
  fi

  printf '%s : "%s" is now %s\n' "$REGISTRY" "$LATEST_TAG" "$HIGHEST_PUBLISHED"
done

exit "$EXIT_CODE"
