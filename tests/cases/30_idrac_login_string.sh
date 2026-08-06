#!/bin/bash

# The controller talks to the iDRAC either through the host's IPMI device
# ("local" mode, the container runs on the server it cools) or over the network
# ("lanplus"). Everything else in the script depends on the login string built
# here, and the password must never leak into the container's process list.

function test_local_mode_uses_the_open_interface() {
  local IPMI_DEVICE_CREATED=false

  if [ ! -e /dev/ipmi0 ] && [ ! -e /dev/ipmi/0 ] && [ ! -e /dev/ipmidev/0 ]; then
    # No real IPMI device here : fake the one the function looks for. /dev is
    # only writable when the suite runs as root (in the Docker image, or in a
    # CI container), so give up gracefully rather than fail elsewhere
    if ! (mkdir -p /dev/ipmi && touch /dev/ipmi/0) 2> /dev/null; then
      skip_test "no IPMI device available and /dev is not writable"
      return 0
    fi
    IPMI_DEVICE_CREATED=true
  fi

  set_iDRAC_login_string "local" "root" "calvin"
  assert_equals "open" "$IDRAC_LOGIN_STRING"

  if $IPMI_DEVICE_CREATED; then
    rm -f /dev/ipmi/0
    rmdir /dev/ipmi 2> /dev/null
  fi
}

function test_local_mode_stops_the_controller_when_no_ipmi_device_is_exposed() {
  if [ -e /dev/ipmi0 ] || [ -e /dev/ipmi/0 ] || [ -e /dev/ipmidev/0 ]; then
    skip_test "this machine really has an IPMI device"
    return 0
  fi

  local OUTPUT
  OUTPUT=$(set_iDRAC_login_string "local" "root" "calvin" 2>&1)
  local -r EXIT_CODE=$?

  assert_equals 1 "$EXIT_CODE" "local mode without an IPMI device should stop the controller"
  assert_contains "$OUTPUT" "/dev/ipmi0" "the error should name the device paths that were looked for"
  assert_contains "$OUTPUT" "/dev/ipmi/0"
  assert_contains "$OUTPUT" "/dev/ipmidev/0"
  assert_contains "$OUTPUT" "stop using local mode" "the error should tell the user how to recover"
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
