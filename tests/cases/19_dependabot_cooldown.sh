#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# Dependabot's minor and patch updates merge themselves once the required checks
# are green (dependabot-auto-merge.yml), and nothing those checks run says
# whether a release can be trusted. A cooldown makes Dependabot wait before it
# proposes a version that is only just out, which is the window in which a
# compromised release is usually noticed and pulled. Dependabot waits three days
# on its own when none is configured ; every entry of "updates" asks for more
# than that, by a number that is the maintainer's to change and that
# MINIMUM_COOLDOWN_DAYS below keeps from being lowered without anybody deciding
# it. A cooldown applies to version updates only : a security update is never
# delayed.
#
# An entry with no cooldown block is not exempt from that, it is on the
# three-day default, which is below the minimum and fails here. What exempts one
# dependency is the cooldown's "exclude" list, and the entry keeps its block.
# The one thing named in ENTRIES_WITHOUT_A_COOLDOWN is an entry that is
# deliberately left on the default, an official base image whose freshness
# matters more than the delay being the case it was written for. There is none :
# the base image of the Dockerfile is not tracked by Dependabot at all,
# base_image_refresh.yml checks it every night and rebuilds from the last
# release tag when it moved.
#
# GitHub's own check of .github/dependabot.yml runs on a pull request that
# changes it, but what each ecosystem then does with the file shows only after
# the merge, on the repository's Insights > Dependency graph > Dependabot page,
# so nothing in this suite can say the file is accepted : it reads what the file
# states, no more
function test_every_dependabot_update_waits_out_a_cooldown() {
  local -r DEPENDABOT_CONFIG="$REPO_ROOT/.github/dependabot.yml"
  if [ ! -f "$DEPENDABOT_CONFIG" ]; then
    # The suite is running inside the built image, which does not carry the
    # configuration of the repository that built it
    skip_test "no .github next to the scripts"
    return 0
  fi

  # "ecosystem:directory" pairs allowed to stay on Dependabot's default, separated
  # by spaces, each with the reason it is there
  local -r ENTRIES_WITHOUT_A_COOLDOWN=""
  local -r MINIMUM_COOLDOWN_DAYS=7

  # One "ecosystem|directories|days" per entry of "updates", days being empty
  # when the entry has no cooldown or no default-days under it. Read with awk
  # rather than a YAML parser because the suite installs none, and this file is
  # written in the one shape this reads : an entry opens on a "  - " line, which
  # may carry any of its keys and not only package-ecosystem, and its keys sit
  # four spaces in. Comments are never matched, the patterns being anchored on
  # the key
  local ENTRIES
  ENTRIES=$(awk '
    function value(line) {
      sub(/^[^:]*:[ \t]*/, "", line)
      sub(/[ \t]*#.*$/, "", line)
      gsub(/"/, "", line)
      return line
    }
    function flush() {
      if (opened) printf "%s|%s|%s\n", (ecosystem == "" ? "(none)" : ecosystem), (directory == "" ? "(none)" : directory), days
      ecosystem = ""; directory = ""; days = ""
      opened = 0; in_cooldown = 0; in_directories = 0
    }
    /^[^ #]/ { flush(); next }
    /^  - / { flush(); opened = 1; sub(/^  - /, "    ") }
    !opened { next }
    /^    package-ecosystem:/ { ecosystem = value($0); in_cooldown = 0; in_directories = 0; next }
    /^    directory:/ { directory = value($0); in_cooldown = 0; in_directories = 0; next }
    /^    directories:/ { in_directories = 1; in_cooldown = 0; next }
    /^    cooldown:/ { in_cooldown = 1; in_directories = 0; next }
    /^    [^ #]/ { in_cooldown = 0; in_directories = 0; next }
    in_directories && /^      - / {
      item = $0
      sub(/^      - /, "", item)
      sub(/[ \t]*#.*$/, "", item)
      gsub(/"/, "", item)
      directory = (directory == "" ? item : directory "," item)
      next
    }
    in_cooldown && /^      default-days:/ { days = value($0); next }
    END { flush() }
  ' "$DEPENDABOT_CONFIG")

  assert_not_empty "$ENTRIES" \
    "the Dependabot configuration is expected to hold at least one entry of updates, or this reads nothing" || return 1

  # Every entry has to be one this read as an entry of an ecosystem : the number
  # of lines opening one is the number of package-ecosystem keys, or an entry
  # has none and Dependabot refuses the file, or a shape this does not follow
  # has hidden one
  local -r OPENING_LINES=$(grep -cE '^  - ' "$DEPENDABOT_CONFIG")
  local -r ECOSYSTEM_KEYS=$(grep -cE '^(  - |    )package-ecosystem:' "$DEPENDABOT_CONFIG")
  assert_equals "$ECOSYSTEM_KEYS" "$OPENING_LINES" \
    "every entry of updates opens on one line and names its package-ecosystem, or this cannot be sure it read them all"

  local ECOSYSTEM DIRECTORY DAYS
  while IFS='|' read -r ECOSYSTEM DIRECTORY DAYS; do
    if [[ " $ENTRIES_WITHOUT_A_COOLDOWN " == *" $ECOSYSTEM:$DIRECTORY "* ]]; then
      pass
      continue
    fi

    if [[ ! "$DAYS" =~ ^[0-9]+$ ]]; then
      fail "the $ECOSYSTEM entry for $DIRECTORY has no cooldown with a default-days, so it is on Dependabot's default of three days, below the $MINIMUM_COOLDOWN_DAYS this repository asks for"
    elif [ "$DAYS" -lt "$MINIMUM_COOLDOWN_DAYS" ]; then
      fail "the $ECOSYSTEM entry for $DIRECTORY waits $DAYS day(s) before proposing a version, less than the $MINIMUM_COOLDOWN_DAYS this repository asks for"
    else
      pass
    fi
  done <<< "$ENTRIES"
}
