#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# Supervisor : the container's PID 1, whose only job is to make sure the fans are handed back to Dell's
# dynamic profile when the container stops, even when the monitoring process cannot do it itself.
#
# The monitoring process normally does it, in graceful_exit(). It sometimes cannot : a SIGTERM landing
# while bash is expanding a command substitution corrupts its parser, so the trap fails to parse and the
# handler never runs, and in a third of those cases bash does not even exit -- it wedges and ignores the
# signal until docker's ten second grace period runs out and SIGKILL takes it (issues #188 and #249).
# Nothing running inside that shell can recover from it, which is why this runs in a shell of its own.
#
# This process spends effectively all of its life blocked in "wait", with no command substitution in
# flight, which is precisely the state where a trap parses cleanly. It runs no loop, formats nothing and
# reads no sensor : everything it does happens once, either at startup or on the way out.
#
# Usage : supervisor.sh [COMMAND [ARGUMENT...]]
# The command defaults to the monitoring process, ./Dell_iDRAC_fan_controller.sh

source functions.sh
source constants.sh

# The monitoring process is started through "bash" rather than executed directly, because its executable
# bit is not what the repository tracks : the file is a regular 644 one and only the image's "chmod 0777"
# makes it runnable. Running it from anywhere else -- the test suite, a clone, a bind mount -- would fail
# with "Permission denied" and the container would stop before it ever started monitoring anything
if [ "$#" -gt 0 ]; then
  readonly MONITORED_COMMAND=("$@")
else
  readonly MONITORED_COMMAND=(bash ./Dell_iDRAC_fan_controller.sh)
fi

# Whether a signal was ever forwarded to the monitored process.
#
# This is what keeps the safety net from firing at a server the monitoring process refused to run on. A
# container that stops because CHECK_INTERVAL was unusable, because the iDRAC never answered or because
# the server is not a Dell exits on its own, without this supervisor signalling anything, and must be
# left alone : sending a fan control command to a machine the controller deliberately declined to touch
# would be worse than the problem this file exists to solve
SIGNAL_WAS_FORWARDED=false

# Hand the fans back to Dell's dynamic fan control profile, on the way out and on this process's behalf.
#
# Only ever called after the monitored process has gone without doing it itself. Applying the profile
# twice would be harmless -- it is the same idempotent IPMI command -- but saying so twice in the log
# would not, so the caller decides
function apply_Dell_default_fan_control_profile_on_behalf_of_the_monitoring_process() {
  if "$MONITORING_ONLY_MODE"; then
    print_warning "Monitoring process stopped without exiting cleanly. Monitoring only mode, so no fan control profile was ever applied and none is applied now"
    return 0
  fi

  print_warning "Monitoring process stopped without handing the fans back. Applying Dell default dynamic fan control profile for safety"

  apply_Dell_default_fan_control_profile

  if ! "$KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT"; then
    # This process never watched a single answer, so unlike graceful_exit() it cannot know which
    # transport the cooling response was driven over. It asks. On a 14th generation server the IPMI
    # command below is the one the BMC answers "invalid command" to, so sending it would undo nothing
    # and the per-slot Redfish attribute would be left as the monitoring process set it.
    #
    # Both requests use the short timeout and run AFTER the fans have been handed back, so the worst
    # case is this being cut short by Docker's stop grace period -- which leaves the setting exactly
    # where it already was, never somewhere new
    if does_this_server_expose_the_cooling_response_over_redfish "$REDFISH_EXIT_REQUEST_TIMEOUT_IN_SECONDS" \
      && [ -n "$REDFISH_THIRD_PARTY_SLOTS" ]; then
      set_the_cooling_response_over_redfish "Automatic" "$REDFISH_EXIT_REQUEST_TIMEOUT_IN_SECONDS" \
        || print_error "Could not hand the third-party PCIe card cooling response back to Dell's default over Redfish. $REDFISH_MANUAL_INSTRUCTIONS"
    else
      enable_third_party_PCIe_card_Dell_default_cooling_response
    fi
  fi
}

# Stop the monitored process, giving it a chance to stop itself first.
#
# It is asked with the signal it traps, then given SUPERVISOR_GRACE_PERIOD_IN_SECONDS to run its own
# graceful_exit(). A process that is still there afterwards is one whose trap never ran -- the wedged
# case -- and no further signal it can catch will change that, so it is killed outright. Docker's own
# grace period is ten seconds by default, so this deadline has to be comfortably inside it or the
# container is SIGKILLed as a whole before this ever gets to act
# shellcheck disable=SC2317,SC2329  # Only invoked indirectly, via the trap below; shellcheck's reachability analysis can't see that.
# Both codes are needed : shellcheck 0.11.0 split the "defined but only reached through a trap" case out of
# SC2317, which still covers the commands in the body, into SC2329 on the definition itself. Neither version
# objects to the code it does not know, so this one line is green on both sides of the runner image's bump
function stop_the_monitored_process() {
  SIGNAL_WAS_FORWARDED=true

  kill -TERM "$MONITORED_PROCESS_PID" 2> /dev/null

  local WAITED_TENTHS_OF_A_SECOND=0
  local -r DEADLINE_IN_TENTHS_OF_A_SECOND=$((SUPERVISOR_GRACE_PERIOD_IN_SECONDS * 10))
  local -r SECOND_ASK_IN_TENTHS_OF_A_SECOND=$((SUPERVISOR_SECOND_ASK_DELAY_IN_SECONDS * 10))
  local HAS_BEEN_ASKED_TWICE=false
  while [ "$WAITED_TENTHS_OF_A_SECOND" -lt "$DEADLINE_IN_TENTHS_OF_A_SECOND" ]; do
    kill -0 "$MONITORED_PROCESS_PID" 2> /dev/null || break

    # Ask once more before giving up on asking. The request above is sometimes lost outright -- a
    # SIGTERM landing while bash expands a command substitution is swallowed and the process carries on
    # as though nothing had been sent -- and the handler survives that, so a second signal is honoured
    # where the first was not. Killing without having asked twice spends this container's own graceful
    # exit on a process that never heard the question (#443).
    #
    # Once, not on every iteration : a process that DID hear the first one is running graceful_exit
    # right now, and re-entering it is what its own guard exists to prevent rather than something to
    # provoke repeatedly
    if ! "$HAS_BEEN_ASKED_TWICE" && [ "$WAITED_TENTHS_OF_A_SECOND" -ge "$SECOND_ASK_IN_TENTHS_OF_A_SECOND" ]; then
      HAS_BEEN_ASKED_TWICE=true
      kill -TERM "$MONITORED_PROCESS_PID" 2> /dev/null
    fi

    sleep 0.1
    WAITED_TENTHS_OF_A_SECOND=$((WAITED_TENTHS_OF_A_SECOND + 1))
  done

  if kill -0 "$MONITORED_PROCESS_PID" 2> /dev/null; then
    print_warning "Monitoring process did not stop within ${SUPERVISOR_GRACE_PERIOD_IN_SECONDS}s, killing it"
    kill -KILL "$MONITORED_PROCESS_PID" 2> /dev/null
  fi
}

trap 'stop_the_monitored_process' SIGINT SIGQUIT SIGTERM

# The login string is built here too : the monitored process builds its own, and this one needs it to be
# able to send the safety command without it. Its output is dropped so the username is not logged twice
set_iDRAC_login_string "$IDRAC_HOST" "$IDRAC_USERNAME" "$IDRAC_PASSWORD" > /dev/null

"${MONITORED_COMMAND[@]}" &
MONITORED_PROCESS_PID=$!

# "wait" is interrupted by the trap, so this returns either when the monitored process ended on its own
# or once stop_the_monitored_process() has dealt with it
MONITORED_PROCESS_EXIT_CODE=0
wait "$MONITORED_PROCESS_PID" 2> /dev/null || MONITORED_PROCESS_EXIT_CODE=$?

if $SIGNAL_WAS_FORWARDED; then
  # A "wait" cut short by a trap reports the signal that interrupted it (128 + 15), not what the process
  # it was waiting for did. Only bash's own "wait" reaps a background job, so the process has not been
  # reaped yet and this second call collects its real status : 0 if its graceful_exit() ran, the signal
  # that killed it otherwise
  MONITORED_PROCESS_EXIT_CODE=0
  wait "$MONITORED_PROCESS_PID" 2> /dev/null || MONITORED_PROCESS_EXIT_CODE=$?
fi

if ! $SIGNAL_WAS_FORWARDED; then
  # The monitored process stopped by itself : it refused to start, or it stopped for a reason of its own.
  # Either way nothing here has any business sending it IPMI commands
  exit "$MONITORED_PROCESS_EXIT_CODE"
fi

if [ "$MONITORED_PROCESS_EXIT_CODE" -ne 0 ]; then
  # It was signalled and did not stop cleanly : either its graceful_exit() never ran, or it had to be
  # killed. In both cases the fans are still on whatever profile was last applied
  apply_Dell_default_fan_control_profile_on_behalf_of_the_monitoring_process
fi

exit 0
