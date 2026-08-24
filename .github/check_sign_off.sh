#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# Answers "does every commit this pull request adds carry a Signed-off-by ?",
# which is the question nothing in this repository asked until now.
#
# CONTRIBUTING.md states the rule -- "Every commit must carry a Signed-off-by
# line" -- and CLAUDE.md repeats it to every session that opens here. Measured
# when issue #388 was written, 7 of the last 30 commits on master held it. A rule
# stated twice, held a quarter of the time and checked nowhere is worse than no
# rule at all : nobody goes looking for what is already required.
#
# It matters more here than in most repositories. This project is dual-licensed --
# AGPL-3.0-only in LICENSE, plus LICENSE-COMMERCIAL.md -- and CONTRIBUTING.md
# makes the sign-off the record that a contributor had the right to submit their
# work under both arms. It is what makes the commercial half defensible.
#
# WHERE THEY WERE LOST. A squash merge composes the commit message from the pull
# request rather than from the branch, so commits that were signed on the branch
# still land unsigned on master. That is why this runs on the pull request and
# reads the branch's own commits : by the time master has the squash, the
# information is gone. It follows that this cannot repair the history it was
# written for, and it does not try -- master keeps its 23 unsigned commits, and
# rewriting a published branch to fix a trailer would break every fork and every
# open pull request for a line of metadata.
#
# WHAT THIS DELIBERATELY DOES NOT DECIDE. The DCO is a first-person certification
# -- "I certify that..." -- and CONTRIBUTING.md asks for "a real name and a
# reachable address". No tool can tell a person from an identity configured in
# git config : three commits on master certify the DCO under "Claude
# <noreply@anthropic.com>", and a check for the trailer's presence passes them
# happily. This one does too, knowingly. Whether an agent's commits should be
# amended to the maintainer's identity before merging, or CONTRIBUTING.md should
# say how they are signed instead, is the half of issue #388 that belongs to
# whoever maintains the project rather than to a workflow.
#
# MERGE COMMITS ARE SKIPPED. Merging the base branch into a branch to resolve a
# conflict is the correct thing to do, and git writes that commit itself with no
# sign-off. Failing a pull request for it would punish the contributor who
# resolved their conflict properly, and the merge carries no contribution of its
# own to certify -- every change it brings in was already signed where it was
# authored.
#
# Exit 0 : every commit in the range carries a well-formed sign-off.
# Exit 1 : at least one does not, or the range could not be read, or it is empty.
# Exit 2 : called wrong.
#
# Which answer sits on which code is deliberate. Under "set -e" a script that
# breaks somewhere inside itself exits 1, so 1 has to be the answer that is safe
# to give by accident. Here that is "this pull request is not signed" : a false
# red is read by a human who can see the commits for themselves, where a false
# green would let through exactly the thing this exists to catch, on a run that
# looks fine. It fails closed.
#
# Usage : .github/check_sign_off.sh <base-sha> <head-sha>

set -euo pipefail

if [ "$#" -ne 2 ]; then
  printf 'Usage : %s <base-sha> <head-sha>\n' "${0##*/}" >&2
  exit 2
fi

readonly BASE="$1"
readonly HEAD="$2"

# The trailer git itself writes with "commit -s", matched on its shape rather
# than merely on its name : "Signed-off-by:" followed by nothing, or by a name
# with no address, is what a broken git config produces, and it certifies
# nobody. The address only has to look like one -- an "@" with something on
# either side -- because deciding whether a mailbox is reachable is not this
# script's job and never could be from here.
#
# Case-insensitive because a handful of tools write the trailer in their own
# casing and the certification is the same either way ; git's own -s always
# writes it exactly as CONTRIBUTING.md quotes it
readonly SIGN_OFF_PATTERN='^[Ss]igned-off-by: .+ <[^[:space:]<>]+@[^[:space:]<>]+>[[:space:]]*$'

# One command substitution per statement, for the reason CLAUDE.md gives : a
# signal landing inside a second one in the same expansion gets its trap handler
# parsed with the substitution still open
COMMITS=""
if ! COMMITS="$(git log --no-merges --format='%H' "$BASE..$HEAD" 2> /dev/null)"; then
  printf '::error::Could not read the commits between %s and %s. Checking out with fetch-depth 0 is what makes both of them present\n' \
    "$BASE" "$HEAD" >&2
  exit 1
fi

# An empty range is refused rather than passed. A pull request that genuinely
# adds no commit is a state nobody needs this job's opinion on ; a range that
# resolves to nothing because the base or the head was computed wrong is the
# shape of a false green, and it is indistinguishable from here. Both land on
# the refusal, for the reason the exit codes are chosen on above : this exists
# to keep an unsigned commit off master, so the cheap mistake is the red one
if [ -z "$COMMITS" ]; then
  printf '::error::No commit between %s and %s. A range that resolves to nothing is refused rather than reported clean, since a base or head computed wrong looks exactly like this\n' \
    "$BASE" "$HEAD" >&2
  exit 1
fi

UNSIGNED_COUNT=0
CHECKED_COUNT=0

while IFS= read -r COMMIT; do
  [ -n "$COMMIT" ] || continue

  CHECKED_COUNT=$((CHECKED_COUNT + 1))

  MESSAGE=""
  MESSAGE="$(git log -1 --format='%B' "$COMMIT")"

  if printf '%s\n' "$MESSAGE" | grep -qE "$SIGN_OFF_PATTERN"; then
    continue
  fi

  UNSIGNED_COUNT=$((UNSIGNED_COUNT + 1))

  SUBJECT=""
  SUBJECT="$(git log -1 --format='%s' "$COMMIT")"

  printf '::error::%s "%s" carries no Signed-off-by\n' "${COMMIT:0:8}" "$SUBJECT" >&2
done <<< "$COMMITS"

if [ "$UNSIGNED_COUNT" -eq 0 ]; then
  printf 'All %d commits carry a sign-off\n' "$CHECKED_COUNT"
  exit 0
fi

printf '\n%d of the %d commits in this pull request carry no sign-off.\n\n' "$UNSIGNED_COUNT" "$CHECKED_COUNT" >&2
printf 'Adding one is your statement of the Developer Certificate of Origin, which is what\n' >&2
printf 'lets this dual-licensed project offer your contribution under both of its licences.\n' >&2
printf 'See CONTRIBUTING.md. To sign the commits already on this branch :\n\n' >&2
printf '  git rebase --signoff %s\n  git push --force-with-lease\n\n' "$BASE" >&2
printf 'and "git commit -s" from here on, or "git commit --amend -s" for the last one.\n' >&2

exit 1
