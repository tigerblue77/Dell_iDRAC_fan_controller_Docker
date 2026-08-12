#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# The supervisor, the container's PID 1. Its only job is to make sure the fans are handed back to Dell's
# dynamic profile when the container stops, including in the cases where the monitoring process cannot do
# it itself : the SIGTERM parse failure of issue #188, and the wedged shell of issue #249 that ignores the
# signal entirely until docker's grace period runs out.
#
# It is driven here with stand-in commands rather than the real monitoring process, because the failures
# it exists for are precisely the ones the real one cannot be made to produce on demand : a shell whose
# parser is corrupted is a race, not a switch. The stand-ins reproduce what the supervisor actually sees —
# a child that exits cleanly, one that exits without cleaning up, one that ignores the signal, one that
# refused to start — which is all it has to decide on.

# Write a stand-in for the monitoring process into the test's temporary directory, and print its path
# Usage : MONITORED=$(write_stand_in_monitoring_process <<'EOF' ... EOF)
function write_stand_in_monitoring_process() {
  local -r STAND_IN="$TEST_TEMPORARY_DIRECTORY/stand_in_monitoring_process.sh"

  cat > "$STAND_IN"
  chmod +x "$STAND_IN"
  printf '%s' "$STAND_IN"
}

# Run the supervisor against a stand-in, stop it with SIGTERM the way "docker stop" does, and print its
# output. Its exit code is returned
# Usage : OUTPUT=$(run_supervisor "$STAND_IN" [SECONDS_BEFORE_SIGNALLING])
function run_supervisor() {
  local -r STAND_IN="$1"
  local -r SECONDS_BEFORE_SIGNALLING="${2:-0.4}"
  local -r OUTPUT_FILE="$TEST_TEMPORARY_DIRECTORY/supervisor_output"

  : > "$OUTPUT_FILE"

  local EXIT_CODE=0
  (
    cd "$REPO_ROOT" || exit 1

    bash ./supervisor.sh "$STAND_IN" > "$OUTPUT_FILE" 2>&1 &
    SUPERVISOR_PID=$!

    command -p sleep "$SECONDS_BEFORE_SIGNALLING"
    kill -TERM "$SUPERVISOR_PID" 2> /dev/null
    wait "$SUPERVISOR_PID"
  ) || EXIT_CODE=$?

  cat "$OUTPUT_FILE"
  return "$EXIT_CODE"
}

# Run the supervisor the way the Dockerfile's ENTRYPOINT does -- with no argument at all, so it starts
# the real monitoring process -- until the temperature table shows it is running, then stop it with
# SIGTERM. Its output is printed and its exit code returned
# Usage : OUTPUT=$(run_supervisor_with_no_argument)
function run_supervisor_with_no_argument() {
  local -r OUTPUT_FILE="$TEST_TEMPORARY_DIRECTORY/supervisor_output"
  # 400 polls of 20ms : 8 seconds, only ever reached when nothing is printed at all, which is what the
  # assertions then report
  local -r MAXIMUM_POLLS=400

  : > "$OUTPUT_FILE"

  local EXIT_CODE=0
  (
    cd "$REPO_ROOT" || exit 1

    bash ./supervisor.sh > "$OUTPUT_FILE" 2>&1 &
    SUPERVISOR_PID=$!

    POLLS=0
    while [ "$POLLS" -lt "$MAXIMUM_POLLS" ]; do
      kill -0 "$SUPERVISOR_PID" 2> /dev/null || break
      grep -qE "$CONTROLLER_TEMPERATURE_LINE_PATTERN" "$OUTPUT_FILE" && break
      command -p sleep 0.02
      POLLS=$((POLLS + 1))
    done

    kill -TERM "$SUPERVISOR_PID" 2> /dev/null
    wait "$SUPERVISOR_PID"
  ) || EXIT_CODE=$?

  cat "$OUTPUT_FILE"
  return "$EXIT_CODE"
}

function test_the_supervisor_starts_the_monitoring_process_from_a_plain_checkout() {
  # The monitoring process is tracked as a regular 644 file : only the image's "chmod 0777" makes it
  # executable, so a supervisor running it directly dies with "Permission denied" and exit code 126
  # before monitoring anything. Every other test case here passes its stand-in as an argument and made
  # its own executable, which is precisely why none of them saw it
  local OUTPUT
  OUTPUT=$(run_supervisor_with_no_argument)
  local -r EXIT_CODE=$?

  assert_equals 0 "$EXIT_CODE" "the supervisor must not fail to start the monitoring process"
  assert_not_contains "$OUTPUT" "Permission denied" \
    "the monitoring process must be started in a way its file mode cannot break"
  assert_matches "$OUTPUT" "$CONTROLLER_TEMPERATURE_LINE_PATTERN" \
    "the monitoring process really ran, rather than the supervisor idling on nothing"
  assert_equals "1" "$(count_ipmitool_calls_matching "raw 0x30 0x30 0x01 0x01")" \
    "and its own graceful exit handed the fans back, without the supervisor having to"
}

function test_a_monitoring_process_that_stops_cleanly_is_left_to_do_its_own_job() {
  # The normal case : graceful_exit() ran, the fans are already back on Dell's
  # profile, and the supervisor must not send the command a second time nor say
  # anything about it
  local -r STAND_IN=$(write_stand_in_monitoring_process << 'EOF'
#!/bin/bash
trap 'exit 0' SIGTERM
while true; do sleep 0.05; done
EOF
  )

  local OUTPUT
  OUTPUT=$(run_supervisor "$STAND_IN")
  local -r EXIT_CODE=$?

  assert_equals 0 "$EXIT_CODE"
  assert_equals "0" "$(count_ipmitool_calls_matching "raw 0x30 0x30 0x01 0x01")" \
    "the monitoring process handed the fans back itself"
  assert_not_contains "$OUTPUT" "without handing the fans back"
}

function test_a_monitoring_process_killed_by_the_signal_gets_the_fans_handed_back_for_it() {
  # What issue #188 produces : the trap failed to parse, so graceful_exit() never
  # ran and the process died on the default action of the signal. The fans are
  # still pinned at the user's static speed and only the supervisor can free them
  local -r STAND_IN=$(write_stand_in_monitoring_process << 'EOF'
#!/bin/bash
while true; do sleep 0.05; done
EOF
  )

  local OUTPUT
  OUTPUT=$(run_supervisor "$STAND_IN")
  local -r EXIT_CODE=$?

  assert_equals 0 "$EXIT_CODE" "the container still stops cleanly"
  assert_equals "1" "$(count_ipmitool_calls_matching "raw 0x30 0x30 0x01 0x01")" \
    "the supervisor hands the fans back on the monitoring process's behalf"
  assert_contains "$OUTPUT" "without handing the fans back" \
    "and says so, rather than letting it pass unnoticed"
}

function test_a_wedged_monitoring_process_is_killed_and_the_fans_handed_back() {
  # What issue #249 produces : the shell's parser is corrupted, it ignores the
  # signal entirely and keeps looping. Docker would wait out its whole grace
  # period and then SIGKILL it, with nothing left to hand the fans back
  local -r STAND_IN=$(write_stand_in_monitoring_process << 'EOF'
#!/bin/bash
trap '' SIGTERM
while true; do sleep 0.05; done
EOF
  )

  local OUTPUT
  OUTPUT=$(run_supervisor "$STAND_IN")
  local -r EXIT_CODE=$?

  assert_equals 0 "$EXIT_CODE"
  assert_contains "$OUTPUT" "did not stop within" "the deadline is reported, not silently waited out"
  assert_contains "$OUTPUT" "killing it"
  assert_equals "1" "$(count_ipmitool_calls_matching "raw 0x30 0x30 0x01 0x01")" \
    "a process that cannot be asked to stop still must not leave the fans pinned"
}

function test_a_monitoring_process_that_refused_to_start_is_not_sent_any_command() {
  # The trap an EXIT trap fell into, and the reason the supervisor only ever acts
  # on a signal it forwarded itself : a container that stops because the server is
  # not a Dell, because CHECK_INTERVAL was unusable or because the iDRAC never
  # answered must not have fan control commands fired at it on the way out
  local -r STAND_IN=$(write_stand_in_monitoring_process << 'EOF'
#!/bin/bash
echo "/!\ Error /!\ Your server isn't a Dell product. Exiting."
exit 1
EOF
  )

  local OUTPUT
  OUTPUT=$(run_supervisor "$STAND_IN" 0.6)
  local -r EXIT_CODE=$?

  assert_equals 1 "$EXIT_CODE" "the supervisor must not swallow a startup failure"
  assert_contains "$OUTPUT" "isn't a Dell product" "the reason still reaches the logs"
  assert_equals "0" "$(count_ipmitool_calls_matching "raw 0x30")" \
    "not one command may reach a server the controller declined to touch"
}

function test_monitoring_only_mode_is_still_never_sent_a_fan_control_command() {
  # The supervisor is a safety net for the fans, and in monitoring only mode there
  # is deliberately nothing to catch : no profile was ever applied, so none has to
  # be restored
  export MONITORING_ONLY_MODE=true
  local -r STAND_IN=$(write_stand_in_monitoring_process << 'EOF'
#!/bin/bash
while true; do sleep 0.05; done
EOF
  )

  local OUTPUT
  OUTPUT=$(run_supervisor "$STAND_IN")

  assert_equals "0" "$(count_ipmitool_calls_matching "raw 0x30")" \
    "monitoring only mode must stay read-only, even on the way out"
  assert_contains "$OUTPUT" "no fan control profile was ever applied"
}

function test_the_supervisor_does_not_log_the_username_a_second_time() {
  # It builds its own iDRAC login string so it can send the safety command without
  # the monitoring process, and set_iDRAC_login_string() logs the username. The
  # monitoring process logs it too, and one container start must not print it twice
  local -r STAND_IN=$(write_stand_in_monitoring_process << 'EOF'
#!/bin/bash
trap 'exit 0' SIGTERM
while true; do sleep 0.05; done
EOF
  )

  local OUTPUT
  OUTPUT=$(run_supervisor "$STAND_IN")

  assert_not_contains "$OUTPUT" "iDRAC/IPMI username" \
    "the supervisor's own login string setup must stay quiet"
}

function test_the_supervisor_runs_the_monitoring_process_by_default() {
  # The Dockerfile's ENTRYPOINT passes no argument, so the default has to be the
  # real monitoring process or the container starts nothing at all
  local -r SUPERVISOR_SOURCE=$(cat "$REPO_ROOT/supervisor.sh")

  assert_contains "$SUPERVISOR_SOURCE" './Dell_iDRAC_fan_controller.sh' \
    "the default command must be the monitoring process"
}

function test_the_docker_image_starts_the_supervisor_and_not_the_monitoring_process() {
  # Everything above is worth nothing if the image still execs the monitoring
  # process directly : the supervisor would simply never run
  if [ ! -f "$REPO_ROOT/Dockerfile" ]; then
    # The suite is running inside the built image, which does not carry the
    # Dockerfile that produced it
    skip_test "no Dockerfile next to the scripts"
    return 0
  fi

  assert_matches "$(cat "$REPO_ROOT/Dockerfile")" 'ENTRYPOINT \["\./supervisor\.sh"\]' \
    "the image must start the supervisor rather than the monitoring process directly"
}
