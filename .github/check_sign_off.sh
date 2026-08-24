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
# WHAT THIS DECIDES ABOUT WHOSE NAME IS ON THE TRAILER, AND WHAT IT CANNOT. The DCO
# is a first-person certification -- "I certify that..." -- and CONTRIBUTING.md asks
# for "a real name and a reachable address". No tool can tell a person from an
# identity configured in git config, so for most of this file's life that question
# was left open, as the half of issue #388 belonging to whoever maintains the
# project rather than to a workflow.
#
# #441 answered it : a commit written by the session is AUTHORED under the tool, and
# its Signed-off-by names the MAINTAINER, who certifies it by reviewing and merging.
# One half of that is checkable from here and is checked below : a commit whose
# AUTHOR is the agent identity must not also certify under it.
#
# The other half is not, and no amount of trying would make it so. A commit authored
# by the maintainer that a session actually wrote is indistinguishable from one they
# typed. And the shape that would catch it -- refusing "author equals sign-off" --
# is the NORMAL and correct shape for every outside contributor, who authors their
# own work and certifies it themselves. So the check below fires on the agent
# identity and stays silent on everyone else, which is what keeps it from punishing
# the contributors it is not about (issue #446).
#
# MERGE COMMITS ARE SKIPPED. Merging the base branch into a branch to resolve a
# conflict is the correct thing to do, and git writes that commit itself with no
# sign-off. Failing a pull request for it would punish the contributor who
# resolved their conflict properly, and the merge carries no contribution of its
# own to certify -- every change it brings in was already signed where it was
# authored.
#
# Exit 0 : every commit in the range carries a well-formed sign-off.
# Exit 1 : at least one does not, or one certifies under the agent identity that
#          authored it, or the range could not be read, or it is empty.
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

# The trailer git itself writes with "commit -s", read as a TRAILER and matched on
# its SHAPE. Both halves are needed, and each closes a hole the other leaves open :
#
# Searching the message body for the pattern passes a commit that merely QUOTES the
# rule. The messages in this repository quote it routinely -- CONTRIBUTING.md's own
# example, pasted into a commit explaining the sign-off, is a well-formed line that
# certifies nobody -- and git itself reports no trailer on such a commit while a
# grep over %B reports a match. Measured on one : the check answered "All 1 commits
# carry a sign-off" over a commit git says has none.
#
# Reading the trailer without looking at its value passes the other shape : "Signed-off-by:" followed by nothing, or by a name
# with no address, is what a broken git config produces, and it certifies
# nobody. The address only has to look like one -- an "@" with something on
# either side -- because deciding whether a mailbox is reachable is not this
# script's job and never could be from here.
#
# Case-insensitive because a handful of tools write the trailer in their own
# casing and the certification is the same either way ; git's own -s always
# writes it exactly as CONTRIBUTING.md quotes it
# Matched against the trailer's VALUE, git having already consumed the key -- which
# it matches case-insensitively itself, so nothing here has to
readonly SIGN_OFF_VALUE_PATTERN='^.+ <[^[:space:]<>]+@[^[:space:]<>]+>[[:space:]]*$'

# The identity .claude/hooks/session-start.sh authors a session's commits under, and
# the one it puts on their trailer. Stated here as well as there because this script
# runs in a workflow that never sources the hook -- and held to it by
# test_the_sign_off_gate_knows_the_identities_the_hook_sets(), so that changing one
# without the other fails rather than quietly stops matching.
#
# The addresses are what identify them, and the names are deliberately not read at
# all : a human contributor may be called anything, "Claude" is not a reserved word,
# and a maintainer who changes how their name is spelled has not stopped being able to
# certify. Matched case-insensitively, addresses being so
readonly AGENT_EMAIL="noreply@anthropic.com"
readonly SIGN_OFF_EMAIL="37409593+tigerblue77@users.noreply.github.com"

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
SELF_CERTIFIED_COUNT=0
MISATTRIBUTED_COUNT=0
CHECKED_COUNT=0

while IFS= read -r COMMIT; do
  [ -n "$COMMIT" ] || continue

  CHECKED_COUNT=$((CHECKED_COUNT + 1))

  # git's own trailer parser rather than the message body : a line quoting the rule
  # in a paragraph is not a trailer, and git is the authority on which is which
  SIGN_OFFS=""
  # What this reading is and is not : STRICTLY STRONGER than searching the message
  # body, and not complete. Every trailer git finds is also a well-formed line, so
  # it refuses everything a body search refuses -- and one shape besides, a
  # well-formed sign-off quoted in a paragraph that is not the last, which git
  # reports no trailer for. A quotation placed AT THE END is parsed as a trailer
  # and still passes ; that is measured, it is the bound of what is claimed here,
  # and it is written down so the next reader who finds it knows it was known
  SIGN_OFFS="$(git log -1 --format='%(trailers:key=Signed-off-by,valueonly)' "$COMMIT")"

  # One well-formed value is enough : a commit may carry several, and a co-author's
  # malformed line does not undo the author's certification
  if printf '%s\n' "$SIGN_OFFS" | grep -qE "$SIGN_OFF_VALUE_PATTERN"; then
    # Signed, and now : by whom, on a commit the agent authored ?
    #
    # Only this direction is decidable (see the header). A commit authored by anyone
    # else is left alone here, which is what keeps an outside contributor -- who
    # authors their own work and certifies it themselves, author and trailer being
    # the same person -- from being refused for the normal shape
    AUTHOR_EMAIL=""
    AUTHOR_EMAIL="$(git log -1 --format='%ae' "$COMMIT")"

    if [ "${AUTHOR_EMAIL,,}" != "$AGENT_EMAIL" ]; then
      # Not the agent's, so the trailer is nobody's business here -- with one shape
      # excepted. A commit that names the agent as a CO-AUTHOR while somebody else
      # authored it is the arrangement #421 put in place and #441 replaced : the tool
      # in the secondary field, a person in the primary one. It is what the first head
      # of #442 was, made after #441 merged by a session still running the old hook,
      # and it passed this gate green. That combination is decidable, unlike "a session
      # wrote this" in general, so it is the other half worth refusing (issue #446).
      #
      # A Co-Authored-By naming the agent on a commit the agent DID author is merely
      # redundant, and is left alone : the author field already says it
      CO_AUTHORS=""
      CO_AUTHORS="$(git log -1 --format='%(trailers:key=Co-Authored-By,valueonly)' "$COMMIT")"

      if ! printf '%s\n' "$CO_AUTHORS" | grep -qiF "<$AGENT_EMAIL>"; then
        continue
      fi

      MISATTRIBUTED_COUNT=$((MISATTRIBUTED_COUNT + 1))

      SUBJECT=""
      SUBJECT="$(git log -1 --format='%s' "$COMMIT")"

      printf '::error::%s "%s" names the agent as a co-author while someone else authored it. The author field is where the work is recorded\n' \
        "${COMMIT:0:8}" "$SUBJECT" >&2
      continue
    fi

    # It authored it. The trailer must therefore name somebody who can certify it,
    # which is the maintainer and not the tool. Checked on the address rather than
    # the name, for the same reason the author is
    if printf '%s\n' "$SIGN_OFFS" | grep -qiF "<$SIGN_OFF_EMAIL>"; then
      continue
    fi

    SELF_CERTIFIED_COUNT=$((SELF_CERTIFIED_COUNT + 1))

    SUBJECT=""
    SUBJECT="$(git log -1 --format='%s' "$COMMIT")"

    printf '::error::%s "%s" is authored by the agent and certifies under it too. The Signed-off-by has to name the maintainer\n' \
      "${COMMIT:0:8}" "$SUBJECT" >&2
    continue
  fi

  UNSIGNED_COUNT=$((UNSIGNED_COUNT + 1))

  SUBJECT=""
  SUBJECT="$(git log -1 --format='%s' "$COMMIT")"

  printf '::error::%s "%s" carries no Signed-off-by\n' "${COMMIT:0:8}" "$SUBJECT" >&2
done <<< "$COMMITS"

if [ "$UNSIGNED_COUNT" -eq 0 ] && [ "$SELF_CERTIFIED_COUNT" -eq 0 ] && [ "$MISATTRIBUTED_COUNT" -eq 0 ]; then
  printf 'All %d commits carry a sign-off\n' "$CHECKED_COUNT"
  exit 0
fi

# The two failures are reported apart because they are fixed apart, and telling one
# to do the other's remedy is how a contributor ends up force-pushing over a branch
# for nothing
if [ "$UNSIGNED_COUNT" -gt 0 ]; then
  printf '\n%d of the %d commits in this pull request carry no sign-off.\n\n' "$UNSIGNED_COUNT" "$CHECKED_COUNT" >&2
  printf 'Adding one is your statement of the Developer Certificate of Origin, which is what\n' >&2
  printf 'lets this dual-licensed project offer your contribution under both of its licences.\n' >&2
  printf 'See CONTRIBUTING.md. To sign the commits already on this branch :\n\n' >&2
  printf '  git rebase --signoff %s\n  git push --force-with-lease\n\n' "$BASE" >&2
  printf 'and "git commit -s" from here on, or "git commit --amend -s" for the last one.\n' >&2
  printf '\nA session working in this repository uses "git signoff" instead, never "-s" :\n' >&2
  printf 'see CONTRIBUTING.md, "Contributions written by an agent", and the paragraph below.\n' >&2
fi

if [ "$SELF_CERTIFIED_COUNT" -gt 0 ]; then
  printf '\n%d of the %d commits in this pull request are authored by the agent and signed off under it too.\n\n' \
    "$SELF_CERTIFIED_COUNT" "$CHECKED_COUNT" >&2
  printf 'A tool certifies nothing, so the trailer has to name the maintainer while the author\n' >&2
  printf 'field keeps saying who wrote the work. See CONTRIBUTING.md, "Contributions written by\n' >&2
  printf 'an agent", and issue #439.\n\n' >&2
  printf 'This is what .claude/hooks/session-start.sh sets up at the start of every session, so\n' >&2
  printf 'the usual cause is a session that started before the hook did, or ran an older one.\n' >&2
  printf 'Re-run it, then commit with the alias it defines rather than with "-s", which derives\n' >&2
  printf 'the trailer from the author and would write this same commit again :\n\n' >&2
  printf '  bash .claude/hooks/session-start.sh\n' >&2
  printf '  git signoff --amend --no-edit          # for the last commit\n\n' >&2
  printf 'For several, re-commit them with "git signoff" ; "git rebase --signoff" derives the\n' >&2
  printf 'trailer from the author exactly as "-s" does, so it cannot repair this one.\n' >&2
fi

if [ "$MISATTRIBUTED_COUNT" -gt 0 ]; then
  printf '\n%d of the %d commits in this pull request name the agent as a co-author while somebody else authored them.\n\n' \
    "$MISATTRIBUTED_COUNT" "$CHECKED_COUNT" >&2
  printf 'That is the arrangement issue #439 replaced : Co-Authored-By is a secondary field,\n' >&2
  printf 'and Author is the one git log, git blame, git shortlog and the contributor graph read.\n' >&2
  printf 'The work is recorded by authoring it under the tool, and certified by a trailer naming\n' >&2
  printf 'the maintainer. See CONTRIBUTING.md, "Contributions written by an agent".\n\n' >&2
  printf 'The usual cause is a session that started before .claude/hooks/session-start.sh did,\n' >&2
  printf 'or ran an older one. Re-run it, then re-author the commit and drop the trailer :\n\n' >&2
  printf '  bash .claude/hooks/session-start.sh\n' >&2
  printf '  git signoff --amend --reset-author        # then remove the Co-Authored-By line\n' >&2
fi

exit 1
