#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# SessionStart hook for Claude Code on the web.
#
# The test suite needs nothing but bash, coreutils, GNU grep and awk, all of which the
# remote image already has - it mocks ipmitool, lm-sensors and perl, so a session can run
# ./tests/run_tests.sh the moment it starts.
#
# The gap is shellcheck. The Shellcheck workflow gates every pull request on it and the
# remote image ships without it, so an agent working here has no way to run the check that
# will decide its push. Installing it up front turns "push and find out" into a local run,
# which is one CI round trip saved per finding.
#
# jq is the same story a size smaller : tests/cases/11_claude_code_settings.sh and
# tests/cases/14_latest_tag_reconciliation.sh skip themselves where jq is missing, so a run
# without it is quietly a little less green than it looks.
#
# Best-effort by design : the suite does not need either of them, so a package index that
# cannot be reached costs the session its linter, not its start.
#
# WHAT MAKES THAT PROMISE TRUE, rather than merely stated. This runs synchronously, so every
# second it spends is a second the session does not start, and three things had to be fixed
# before "costs the session its linter, not its start" was actually the case :
#
#   - apt is given a deadline. Unbounded, its own defaults are 120 s per connection with
#     retries, per source line. A mirror that refuses or fails DNS returns in seconds, but one
#     that accepts the connection and never answers - a filtering proxy, a half-open NAT, a
#     wedged mirror - does not : measured against a listener that accepts and never replies,
#     "apt-get update" blocked for 248 seconds. Both calls now carry acquire timeouts and sit
#     under "timeout", and .claude/settings.json gives the hook a budget larger than the sum,
#     so the script always gives up on its own terms before the platform kills it. A kill
#     landing inside dpkg is what leaves a container refusing every later apt operation until
#     someone runs "dpkg --configure -a" by hand, and the container state is cached, so that
#     breakage would persist across sessions rather than being retried from clean.
#
#   - "apt-get update" is told to treat a failed index as an error. It reports one as a
#     warning and exits 0 otherwise, which left the branch below dead in exactly the case it
#     was written for : the network could be down, nothing would say so, and the install would
#     go on against whatever index the image was built with.
#
#   - the messages that report a problem go to STDOUT. Claude Code feeds a hook's stdout into
#     the session and keeps stderr only on the non-zero-exit path, so a notice written to
#     stderr beside "exit 0" is the one combination the session never sees. Announcing success
#     while swallowing "you have no linter" is backwards : the failure is the half worth
#     delivering, since a session that does not know shellcheck is missing runs it, gets
#     "command not found", and pushes anyway.

set -uo pipefail

# Local checkouts are the developer's own machine, with their own package manager and
# their own idea of what should be installed on it
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

# The two identities a commit made here carries, set before anything below can exit
# early : the container is cached once this has run, so a second session reaches the
# "already installed" return and nothing after it.
#
# A commit has three identity fields, and they answer two different questions. WHO WROTE IT
# is the author, and that is the tool : git log, git blame, git shortlog and GitHub's
# contributor graph all read that field, so recording the tool anywhere else is not
# recording it. WHO CERTIFIES IT is the Signed-off-by trailer -- CONTRIBUTING.md asks for
# "a real name and a reachable address" and the DCO's own text is first-person, "I certify
# that", which a tool cannot say -- so that one is the maintainer's.
#
# Collapsing the two is what issue #388 refused to leave standing, and it can be collapsed
# in either direction. Left alone, a session writes "Signed-off-by: Claude
# <noreply@anthropic.com>", a trailer that satisfies the gate in .github/check_sign_off.sh
# while naming nobody who could make the attestation. Setting user.* to the maintainer
# repairs that trailer but moves the confusion into the author field, where the log then
# says the maintainer typed what a tool wrote (#439). Setting each field to the identity it
# is actually asking about is what says both things at once.
#
# The trailer therefore cannot come from "commit -s", which derives it from user.* -- the
# very fields that have to stay the tool's. It is passed explicitly instead, wrapped in an
# alias so that it is a command rather than something to remember : a rule that needs a
# human to recall it every time is a rule that will be forgotten, which is why #421 put the
# identity here in the first place.
#
# /!\ Do not fold this into "trailer.<token>.key". That config does work -- with the key
# spelled exactly "Signed-off-by", git supplies the ": " separator and the gate accepts the
# result -- but it fails invisibly when the key is spelled with the separator already in it.
# "Signed-off-by: " (trailing space) emits a line that is byte-for-byte identical to a valid
# sign-off, that "git log" displays normally and that %(trailers) lists, while a keyed read
# of it returns empty : git stored the key WITH the separator, so the gate looks for
# "Signed-off-by", finds nothing, and refuses a commit whose message looks perfectly right.
# There is no symptom to notice and nothing reports it. The alias carries the whole trailer
# as one string instead, where a mistake shows up in the line itself.
#
# What this does not do is make the certification true by itself : the maintainer certifies
# by reviewing and merging. It only stops either field from saying something else meanwhile.
# See CONTRIBUTING.md, "Contributions written by an agent".
#
# Repository-local on purpose -- this is this project's rule, and nothing here should reach
# into a configuration the session may share with other work
readonly SIGN_OFF_NAME="Tigerblue77"
readonly SIGN_OFF_EMAIL="37409593+tigerblue77@users.noreply.github.com"
readonly AGENT_NAME="Claude"
readonly AGENT_EMAIL="noreply@anthropic.com"

if ! git -C "${CLAUDE_PROJECT_DIR:-.}" config user.name "$AGENT_NAME" 2> /dev/null ||
  ! git -C "${CLAUDE_PROJECT_DIR:-.}" config user.email "$AGENT_EMAIL" 2> /dev/null ||
  ! git -C "${CLAUDE_PROJECT_DIR:-.}" config alias.signoff "commit --trailer \"Signed-off-by: $SIGN_OFF_NAME <$SIGN_OFF_EMAIL>\"" 2> /dev/null; then
  echo "session-start : could not set the git identity and its sign-off alias, so a commit made here would be authored and signed off by the session's default rather than by the tool and the maintainer"
fi

# Bounded so that a mirror which accepts a connection and then goes quiet cannot hold the
# session open : two acquire timeouts because a source line may be either scheme, one retry
# rather than apt's three, and an outer wall clock in case something below the acquire layer
# is what hangs
readonly APT_NETWORK_OPTIONS=(
  -o Acquire::http::Timeout=10
  -o Acquire::https::Timeout=10
  -o Acquire::Retries=1
)
readonly APT_DEADLINE_SECONDS=45

MISSING_PACKAGES=()
for PACKAGE in shellcheck jq; do
  command -v "$PACKAGE" > /dev/null 2>&1 || MISSING_PACKAGES+=("$PACKAGE")
done

# Idempotent : the container state is cached once the hook has run, so the second session
# onwards finds both already there and does nothing
if [ ${#MISSING_PACKAGES[@]} -eq 0 ]; then
  echo "session-start : shellcheck and jq are already installed"
  exit 0
fi

echo "session-start : installing ${MISSING_PACKAGES[*]}"

export DEBIAN_FRONTEND=noninteractive

# APT::Update::Error-Mode=any is what makes this test mean anything : without it a refresh
# that fetched nothing still exits 0, and the session would be told the index is current
# when it is whatever the image was built with
APT_OUTPUT=""
if ! APT_OUTPUT="$(timeout "$APT_DEADLINE_SECONDS" apt-get update -qq \
  "${APT_NETWORK_OPTIONS[@]}" -o APT::Update::Error-Mode=any 2>&1)"; then
  echo "session-start : could not refresh the package index, installing against the one the image was built with"
  printf '%s\n' "$APT_OUTPUT" | tail -3
fi

# Its output is kept rather than discarded : "could not install" with no reason attached
# cannot tell a dead network from an index too old to still name the version it offers,
# and those are repaired differently
APT_OUTPUT=""
if ! APT_OUTPUT="$(timeout "$APT_DEADLINE_SECONDS" apt-get install -y --no-install-recommends \
  "${APT_NETWORK_OPTIONS[@]}" "${MISSING_PACKAGES[@]}" 2>&1)"; then
  echo "session-start : could not install ${MISSING_PACKAGES[*]}."
  printf '%s\n' "$APT_OUTPUT" | tail -5
  echo "session-start : the test suite still runs (./tests/run_tests.sh) ; shellcheck findings will only surface in CI."
  exit 0
fi

for PACKAGE in "${MISSING_PACKAGES[@]}"; do
  if ! command -v "$PACKAGE" > /dev/null 2>&1; then
    echo "session-start : $PACKAGE reported installed but is not on the PATH"
    continue
  fi

  # The status is checked and only stdout is read, because a binary that is on the PATH and
  # cannot run is a real state : an installed shellcheck built against a newer glibc prints
  # "version `GLIBC_2.34' not found", and folding that into the version parse announces
  # "shellcheck 2.34 installed" to a session that in fact has nothing that runs
  VERSION_OUTPUT=""
  if ! VERSION_OUTPUT="$("$PACKAGE" --version 2> /dev/null)"; then
    echo "session-start : $PACKAGE is installed but does not run"
    continue
  fi

  VERSION=""
  VERSION="$(printf '%s' "$VERSION_OUTPUT" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"

  if [ -n "$VERSION" ]; then
    echo "session-start : $PACKAGE $VERSION installed"
  else
    echo "session-start : $PACKAGE installed"
  fi
done
