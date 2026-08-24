#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# The rhythm the monitoring loop keeps, which four lines have carried since the
# beginning and which nothing checked.
#
# The loop starts its timer BEFORE doing a cycle's work and waits on it after, so a
# cycle costs max(CHECK_INTERVAL, the work) rather than CHECK_INTERVAL plus the work.
# That is what makes CHECK_INTERVAL mean what the README says it means : the period
# between two readings, not a pause added to however long a reading took.
#
# It matters beyond tidiness. The gap between two runs of is_any_CPU_overheating()
# IS the cycle, and that check is the only thing that takes fans off the user's
# static speed when a CPU climbs. Work that adds to the interval instead of fitting
# inside it stretches that gap by however slow the server is being (#444).
#
# Guarded by the SHAPE of the loop rather than by a stopwatch, on purpose. A cycle
# costs max(CHECK_INTERVAL, its work), so telling that apart from CHECK_INTERVAL plus
# the work needs the work to be an appreciable share of the interval -- and then the
# two spans differ by that same share, which at this suite's ~5 ipmitool calls a
# cycle came to about two seconds either side of the threshold. A guard that fails
# because a runner was busy is worse than none in a repository where every pull
# request has to be green, so what is pinned here is the arrangement that produces
# the rhythm : the timer started before the work, and waited on after it. A refactor
# that moved the sleep back inline is what this catches, and that is the regression
# that would really happen.

function test_the_timer_of_a_cycle_is_started_before_its_work_and_waited_on_after() {
  # The shape of the four lines, guarded here because the timing case below can only
  # ever say the rhythm is right on the machine it happened to run on, and because a
  # refactor that moved the "sleep &" after the work would leave every existing case
  # green while turning CHECK_INTERVAL into a pause between cycles
  local -r CONTROLLER=$(cat "$REPO_ROOT/Dell_iDRAC_fan_controller.sh")

  assert_matches "$CONTROLLER" 'wait \$SLEEP_PROCESS_PID' \
    "the loop must wait on the timer it started, rather than sleeping inline"
  assert_matches "$CONTROLLER" 'sleep "\$CHECK_INTERVAL" &' \
    "and the timer must run in the background while the work is done"

  # The order is the whole invariant : waited on, then the next one started, then the
  # work. Read from the END of the monitoring loop rather than from its first match --
  # the loop waits and restarts the timer higher up too, on the cycle it skips when the
  # server is unreachable, and matching that one made this guard compare lines that have
  # nothing to do with each other and pass while the sleep sat after the work
  local -r CYCLE_END=$(awk '/^while true; do$/ { block++ }
    block == 2 && /wait \$SLEEP_PROCESS_PID/ { slice = ""; capturing = 1 }
    capturing { slice = slice $0 "\n" }
    END { printf "%s", slice }' "$REPO_ROOT/Dell_iDRAC_fan_controller.sh")

  assert_not_empty "$CYCLE_END" "the monitoring loop must end on a wait for its timer" || return 1

  local -r TIMER_LINE=$(printf '%s\n' "$CYCLE_END" | grep -n 'sleep "\$CHECK_INTERVAL" &' | head -n 1 | cut -d: -f1)
  local -r WORK_LINE=$(printf '%s\n' "$CYCLE_END" | grep -n '^  retrieve_temperatures$' | head -n 1 | cut -d: -f1)

  assert_not_empty "$TIMER_LINE" "the cycle must start the next timer before it ends" || return 1
  assert_not_empty "$WORK_LINE" "and read the temperatures for the next cycle" || return 1
  assert_equals "true" "$([ "$WORK_LINE" -gt "$TIMER_LINE" ] && echo true || echo false)" \
    "the work is done while the timer runs, which is what stops it being added to the interval"
}
