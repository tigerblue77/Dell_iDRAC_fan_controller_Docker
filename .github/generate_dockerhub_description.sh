#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# Prints the page Docker Hub shows on the image's repository : a short pointer
# at the documentation, which lives on GitHub.
#
# This used to render README.md into that page, dropping whole sections from the
# end until the result fitted Docker Hub's 25,000-character limit. That worked,
# and cost more than it was worth. The README passed the limit long ago, so the
# page was always an extract ; which sections it carried moved every time the
# documentation did ; and an ordinary paragraph three sections away could push
# the last section a reader actually needed off the page. Guarding against that
# meant measuring headroom, warning before it ran out, and periodically deciding
# which paragraph to sacrifice to a registry's character count -- a recurring
# editorial argument that produced nothing for anyone reading either page.
#
# So the page no longer competes with the README : it points at it. There is one
# page to keep correct instead of two, this one cannot go stale because it says
# nothing that can, and no documentation change can ever break it again.
#
# What is lost is real and worth stating : a reader on Docker Hub no longer sees
# the parameters without following a link. What is gained is that they no longer
# see an arbitrary two thirds of them and no sign that the rest exists.
#
# Usage : .github/generate_dockerhub_description.sh

set -euo pipefail

# The links this writes have to be absolute, so the repository they point at has
# to be known. GITHUB_REPOSITORY is set on every runner ; the git remote covers
# a run from a working copy, and having neither is not something to guess at :
# a wrong owner here is a page pointing at somebody else's repository
REPOSITORY="${GITHUB_REPOSITORY:-}"
if [ -z "$REPOSITORY" ]; then
  REMOTE_URL="$(git -C "$(dirname "${BASH_SOURCE[0]}")" remote get-url origin 2> /dev/null || true)"
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

cat << EOF
# Dell iDRAC fan controller

Control the fans of a Dell PowerEdge server from its CPU temperatures, over IPMI.

## The documentation is on GitHub

**$REPOSITORY_URL#readme**

It is kept there rather than copied here, so that there is one page to keep
correct instead of two :

- **Requirements** — which iDRAC firmware still accepts the fan control
  commands, and the privileges the account needs
- **Usage** — \`docker run\` and \`docker compose\`, against a local or a remote
  iDRAC
- **Parameters** — every variable, what it does and what it defaults to
- **Troubleshooting** — what to look at when the fans do not move

## Licence

GNU AGPL v3, or a commercial licence for uses it does not fit :
$BLOB_URL/LICENSE-COMMERCIAL.md

## Issues and discussions

$REPOSITORY_URL/issues
EOF
