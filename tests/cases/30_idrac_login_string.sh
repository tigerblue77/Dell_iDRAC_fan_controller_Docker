#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# The controller talks to the iDRAC either through the host's IPMI device
# ("local" mode, the container runs on the server it cools) or over the network
# ("lanplus"). Everything else in the script depends on the login string built
# here, and the password must never leak into the container's process list.

# Local mode looks the IPMI character device up through IPMI_DEVICE_PATHS, so the
# cases below point it at a file of their own inside the run's temporary directory
# rather than at /dev, which is machine-global. Both branches of the lookup are
# then reachable on any machine, whether or not it has a real IPMI device, and two
# runs sharing a machine cannot make each other skip or fail.
function fake_IPMI_device() {
  local -r FAKE_IPMI_DEVICE="$TEST_TEMPORARY_DIRECTORY/ipmi0"

  touch "$FAKE_IPMI_DEVICE"
  IPMI_DEVICE_PATHS=("$FAKE_IPMI_DEVICE")
}

function no_IPMI_device() {
  IPMI_DEVICE_PATHS=("$TEST_TEMPORARY_DIRECTORY/absent/ipmi0")
}

function test_local_mode_uses_the_open_interface() {
  fake_IPMI_device

  set_iDRAC_login_string "local" "root" "calvin"

  assert_equals "open" "$IDRAC_LOGIN_STRING"
}

function test_local_mode_accepts_any_of_the_device_paths_the_driver_may_use() {
  # The driver has exposed its device under three different names, and only one of
  # them is ever present : finding the last one must work as well as the first
  local -r FAKE_IPMI_DEVICE="$TEST_TEMPORARY_DIRECTORY/ipmidev_0"
  touch "$FAKE_IPMI_DEVICE"
  IPMI_DEVICE_PATHS=("$TEST_TEMPORARY_DIRECTORY/absent0" "$TEST_TEMPORARY_DIRECTORY/absent1" "$FAKE_IPMI_DEVICE")

  set_iDRAC_login_string "local" "root" "calvin"

  assert_equals "open" "$IDRAC_LOGIN_STRING"
}

function test_local_mode_stops_the_controller_when_no_ipmi_device_is_exposed() {
  no_IPMI_device

  local OUTPUT
  OUTPUT=$(set_iDRAC_login_string "local" "root" "calvin" 2>&1)
  local -r EXIT_CODE=$?

  assert_equals 1 "$EXIT_CODE" "local mode without an IPMI device should stop the controller"
  assert_contains "$OUTPUT" "network mode" "the error should tell the user how to recover"
}

function test_the_error_enumerates_every_path_that_was_looked_for() {
  # The paths in the error are what a user matches against their --device flag, so
  # every one that was tried has to appear, joined the way the message always has
  IPMI_DEVICE_PATHS=("$TEST_TEMPORARY_DIRECTORY/absent0" "$TEST_TEMPORARY_DIRECTORY/absent1" "$TEST_TEMPORARY_DIRECTORY/absent2")

  local OUTPUT
  OUTPUT=$(set_iDRAC_login_string "local" "root" "calvin" 2>&1)

  assert_contains "$OUTPUT" "Could not open device at $TEST_TEMPORARY_DIRECTORY/absent0 or $TEST_TEMPORARY_DIRECTORY/absent1 or $TEST_TEMPORARY_DIRECTORY/absent2,"
}

function test_the_shipped_lookup_is_the_three_paths_the_driver_may_use() {
  # Asserted on the list itself rather than through the error, so that the case
  # holds identically on a machine that does have a real IPMI device.
  # Re-sourcing functions.sh in a subshell is what restores the shipped list
  assert_equals "/dev/ipmi0 /dev/ipmi/0 /dev/ipmidev/0" \
    "$(source "$REPO_ROOT/functions.sh"; printf '%s' "${IPMI_DEVICE_PATHS[*]}")"
}

function test_the_suite_never_writes_the_ipmi_device_to_dev() {
  # /dev is machine-global : creating the real path there to exercise the "device
  # is present" branch is what used to make two runs on the same machine interfere,
  # one silently skipping a case the other had made unreachable, and what left an
  # empty /dev/ipmi behind on a developer's machine. Regression test for issue #190
  local DEVICE_CREATED_UNDER_DEV
  DEVICE_CREATED_UNDER_DEV=$(grep -rnE '(^|[[:space:]])(mkdir|touch|ln|cp|mv|rm|rmdir)[[:space:]][^;|&]*/dev/ipmi' "$TESTS_DIRECTORY" || true)

  assert_empty "$DEVICE_CREATED_UNDER_DEV" \
    "no test may create or delete a device under /dev : the lookup is injectable for that reason"

  fake_IPMI_device
  set_iDRAC_login_string "local" "root" "calvin"

  assert_equals "open" "$IDRAC_LOGIN_STRING" "and the present-device branch is still covered"
}

function test_network_mode_builds_a_lanplus_login_string() {
  set_iDRAC_login_string "192.168.1.100" "root" "calvin" > /dev/null

  assert_equals "lanplus -H 192.168.1.100 -U root -E" "$IDRAC_LOGIN_STRING"
}

function test_network_mode_never_puts_the_password_on_the_command_line() {
  # -P would expose the password in `ps aux` and in /proc/<pid>/cmdline
  set_iDRAC_login_string "192.168.1.100" "root" "SuperSecret" > /dev/null

  assert_not_contains "$IDRAC_LOGIN_STRING" "SuperSecret" "the password must not end up in the ipmitool arguments"
  assert_not_contains "$IDRAC_LOGIN_STRING" "-P" "the password must be passed through the environment, not with -P"
  assert_contains "$IDRAC_LOGIN_STRING" "-E" "ipmitool must be told to read the password from IPMI_PASSWORD"
  assert_equals "SuperSecret" "$IPMI_PASSWORD" "the password must be exported as IPMI_PASSWORD"
}

function test_network_mode_logs_the_username_but_never_the_password() {
  local OUTPUT
  OUTPUT=$(set_iDRAC_login_string "192.168.1.100" "administrator" "SuperSecret" 2>&1)

  assert_contains "$OUTPUT" "administrator" "the username is logged to help debugging"
  assert_not_contains "$OUTPUT" "SuperSecret" "the password must never be logged"
}

function test_network_mode_preserves_a_password_containing_special_characters() {
  local -r COMPLEX_PASSWORD='a b$c"d'"'"'e\f'
  set_iDRAC_login_string "192.168.1.100" "root" "$COMPLEX_PASSWORD" > /dev/null

  assert_equals "$COMPLEX_PASSWORD" "$IPMI_PASSWORD" "the password must reach ipmitool untouched"
}
