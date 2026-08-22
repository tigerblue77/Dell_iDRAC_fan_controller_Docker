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
# jq is the same story a size smaller : tests/cases/14_latest_tag_reconciliation.sh skips
# itself where jq is missing, so a run without it is quietly a little less green than it
# looks.
#
# Best-effort by design : the suite does not need either of them, so a package index that
# cannot be reached costs the session its linter, not its start. It says so and exits 0.

set -uo pipefail

# Local checkouts are the developer's own machine, with their own package manager and
# their own idea of what should be installed on it
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

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

if ! apt-get update -qq > /dev/null 2>&1; then
  echo "session-start : could not refresh the package index, carrying on without ${MISSING_PACKAGES[*]}" >&2
fi

if ! apt-get install -y --no-install-recommends "${MISSING_PACKAGES[@]}" > /dev/null 2>&1; then
  echo "session-start : could not install ${MISSING_PACKAGES[*]}." >&2
  echo "session-start : the test suite still runs (./tests/run_tests.sh) ; shellcheck findings will only surface in CI." >&2
  exit 0
fi

for PACKAGE in "${MISSING_PACKAGES[@]}"; do
  if command -v "$PACKAGE" > /dev/null 2>&1; then
    echo "session-start : $PACKAGE $("$PACKAGE" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1) installed"
  else
    echo "session-start : $PACKAGE reported installed but is not on the PATH" >&2
  fi
done
