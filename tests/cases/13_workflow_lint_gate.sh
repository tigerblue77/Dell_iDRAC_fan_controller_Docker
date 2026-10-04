#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# The two linters over the workflows, actionlint and zizmor, are only a gate
# while a handful of things stay true, and none of them is visible in a green
# run. Both are read from .github/workflows/lint-workflows.yml, and the ruleset
# is read as the form "Import a ruleset" takes, so what this checks is the file,
# and the file only gates once the maintainer has imported it.
#
# The ruleset names them, or they report without blocking anything. They run on
# every pull request, because a required check that is skipped counts as
# satisfied : a job with an "if", a "needs" on one that may be skipped, a
# "continue-on-error" or a "paths:" filter that hides the check from a pull
# request which touches nothing it names would let that pull request through by
# not running them, or leave it waiting for a check that never reports, which is
# the single thing a gate on the workflows must not be able to do.
#
# zizmor is run offline, because its online audits answer from GitHub and the
# advisory databases, which change from one day to the next with nobody touching
# this repository, and would turn a required check red on a pull request that
# caused nothing. That skips five audits, impostor-commit,
# known-vulnerable-actions, ref-confusion, stale-action-refs and
# ref-version-mismatch, so a green zizmor is not a scan for vulnerable actions. And it is run with
# --strict-collection, because without it a file zizmor cannot parse is skipped
# with a warning and the check stays green, dependabot.yml being read by nothing
# else. actionlint is run with its shellcheck and pyflakes integrations off, so
# that the answer does not depend on whichever versions the runner image ships.
function test_the_workflow_lint_checks_are_required_and_cannot_pass_by_not_running() {
  local -r RULESET="$REPO_ROOT/.github/rulesets/master.json"
  local -r LINT_WORKFLOW="$REPO_ROOT/.github/workflows/lint-workflows.yml"
  if [ ! -f "$RULESET" ] || [ ! -f "$LINT_WORKFLOW" ] || ! command -v jq > /dev/null 2>&1; then
    skip_test "no .github next to the scripts, or no jq to read the ruleset with"
    return 0
  fi

  local -r REQUIRED=$(jq -r '.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context' "$RULESET")
  local CHECK
  for CHECK in actionlint zizmor; do
    assert_contains "$(printf '\n%s\n' "$REQUIRED")" "$(printf '\n%s\n' "$CHECK")" \
      "the ruleset has to require the $CHECK check, or it reports on a pull request without blocking it"
  done

  # Comments dropped first : the header of the workflow talks about every one of
  # these words
  local -r LINT_WORKFLOW_CODE=$(grep -v '^[[:space:]]*#' "$LINT_WORKFLOW")

  assert_empty "$(grep -nE '^[[:space:]]*(- )?(if|needs|continue-on-error):' <<< "$LINT_WORKFLOW_CODE")" \
    "no job or step of the workflow lint may carry an if, a needs or a continue-on-error : a required check that is skipped counts as satisfied"
  assert_contains "$LINT_WORKFLOW_CODE" "pull_request:" \
    "the workflow lint has to run on a pull request, which is where a required check reports"
  assert_empty "$(grep -nE '^[[:space:]]*paths(-ignore)?:' <<< "$LINT_WORKFLOW_CODE")" \
    "the workflow lint may not filter on paths : a required check hidden from a pull request waits for ever"

  local -r ZIZMOR_COMMAND=$(grep -E 'bin/zizmor"?[[:space:]]' <<< "$LINT_WORKFLOW_CODE")
  assert_not_empty "$ZIZMOR_COMMAND" "the workflow lint should still run zizmor" || return 1
  assert_contains "$ZIZMOR_COMMAND" "--offline" \
    "zizmor has to run offline, its online audits answer from databases that change under a pull request that touched nothing"
  assert_contains "$ZIZMOR_COMMAND" "--strict-collection" \
    "zizmor has to run with --strict-collection, or a file it cannot parse is skipped with a warning and the check stays green"

  local -r ACTIONLINT_COMMAND=$(grep -E 'bin/actionlint"?[[:space:]]' <<< "$LINT_WORKFLOW_CODE")
  assert_not_empty "$ACTIONLINT_COMMAND" "the workflow lint should still run actionlint" || return 1
  assert_contains "$ACTIONLINT_COMMAND" "-shellcheck=" \
    "actionlint has to run with its shellcheck integration off, or the answer depends on the runner image's version"
  assert_contains "$ACTIONLINT_COMMAND" "-pyflakes=" \
    "actionlint has to run with its pyflakes integration off, for the same reason"
}

# A finding is ignored with a "# zizmor: ignore[rule]" comment on the line it is
# about, and one that gives no reason after it is a finding silenced for nobody
# to find out why. Both halves are asked for : the rule in brackets, so that it
# silences one audit and not all of them, and the reason after them
function test_every_zizmor_ignore_names_its_rule_and_gives_its_reason() {
  local -r WORKFLOW_DIRECTORY="$REPO_ROOT/.github/workflows"
  if [ ! -d "$WORKFLOW_DIRECTORY" ]; then
    skip_test "no .github/workflows next to the scripts"
    return 0
  fi

  local WORKFLOW
  local UNEXPLAINED=""
  for WORKFLOW in "$WORKFLOW_DIRECTORY"/*.yml "$WORKFLOW_DIRECTORY"/*.yaml; do
    [ -f "$WORKFLOW" ] || continue
    UNEXPLAINED+=$(grep -v '^[[:space:]]*#' "$WORKFLOW" |
      grep -E 'zizmor: ignore([^[]|$)|zizmor: ignore\[[^]]*\][[:space:]]*$' |
      sed "s|^|${WORKFLOW#"$REPO_ROOT"/} : |")
  done

  assert_empty "$UNEXPLAINED" \
    "every zizmor: ignore has to name the rule in brackets and give its reason after them"
}

# "# zizmor: ignore[dangerous-triggers]" on the workflow_run of test-results.yml
# exempts the whole of its "on:" block, so what justifies it is pinned here, and
# an added "pull_request_target:" or a step that starts running something would
# be refused instead of passing under the ignore. What makes a workflow_run
# dangerous is a workflow that checks out or runs what the triggering run
# produced, and the reason this one is not is that it does neither : its only
# trigger is workflow_run, it has no checkout, and it has no step that runs a
# script, so what it downloads from the run that just finished is handed to the
# publishing action as data and nothing in it is ever executed here
function test_the_workflow_run_trigger_zizmor_is_told_to_ignore_still_deserves_it() {
  local -r WORKFLOW="$REPO_ROOT/.github/workflows/test-results.yml"
  if [ ! -f "$WORKFLOW" ]; then
    skip_test "no .github/workflows next to the scripts"
    return 0
  fi

  # Comments dropped first : the header explains the reasoning in the very words
  # this looks for
  local -r CODE=$(grep -v '^[[:space:]]*#' "$WORKFLOW")

  # The keys of "on:", two spaces in, up to the next top-level key. A one-line
  # "on: ..." is a shape this does not read, and fails rather than passing
  local -r TRIGGERS=$(awk '
    /^on:[ \t]*[^ \t#]/ { print "(inline)"; next }
    /^on:/ { in_on = 1; next }
    in_on && /^[^ \t]/ { in_on = 0 }
    in_on && /^  [A-Za-z_]+:/ { key = $1; sub(/:.*$/, "", key); print key }
  ' <<< "$CODE")
  assert_equals "workflow_run" "$TRIGGERS" \
    "test-results.yml has to have workflow_run as its only trigger : the zizmor ignore on it covers every trigger of the block, and pull_request_target would pass under it"

  assert_empty "$(grep -niE 'actions/checkout' <<< "$CODE")" \
    "test-results.yml may not check anything out : it runs on a trigger that carries the fork's run, and the ignore says it reads only data"
  assert_empty "$(grep -nE '^[[:space:]-]*run:' <<< "$CODE")" \
    "test-results.yml may not run a script : the ignore says nothing from the artifacts it downloads is executed here"
  assert_empty "$(grep -nE '^[[:space:]-]*uses:[[:space:]]*\./' <<< "$CODE")" \
    "test-results.yml may not use a local action, which would be code from a checkout"
}

# The ignores are the exceptions to a gate, so the exceptions are what has to be
# pinned : "every ignore has a reason" says nothing about an ignore that was
# widened to silence more than it was written for, or one more that was added.
# The inline ones are compared as a whole set of file, rules and the code on the
# line they sit on, with the ref of a "uses:" left out so that a version bump of
# the action does not fail it. A rule list that grows, an ignore moved to another
# line, a third ignore or a different rule all differ from it. Removing one is
# the one change that is meant to edit this case too, which is how #535 ends
function test_the_inline_zizmor_ignores_are_exactly_the_two_expected_ones() {
  local -r WORKFLOW_DIRECTORY="$REPO_ROOT/.github/workflows"
  if [ ! -d "$WORKFLOW_DIRECTORY" ]; then
    skip_test "no .github/workflows next to the scripts"
    return 0
  fi

  local -r EXPECTED='build_and_publish_docker_image.yml|superfluous-actions|uses: softprops/action-gh-release
test-results.yml|dangerous-triggers|workflow_run:'

  local WORKFLOW LINE ACTUAL=""
  for WORKFLOW in "$WORKFLOW_DIRECTORY"/*.yml "$WORKFLOW_DIRECTORY"/*.yaml; do
    [ -f "$WORKFLOW" ] || continue
    while IFS= read -r LINE; do
      ACTUAL+="${WORKFLOW##*/}|$LINE"$'\n'
    done < <(grep -v '^[[:space:]]*#' "$WORKFLOW" |
      grep -E 'zizmor: ignore\[' |
      sed -E 's/^[[:space:]-]*([^#]*[^#[:space:]])[[:space:]]*#[[:space:]]*zizmor: ignore\[([^]]*)\].*$/\2|\1/; s/@[^[:space:]]*$//')
  done

  assert_equals "$(sort <<< "$EXPECTED")" "$(grep . <<< "$ACTUAL" | sort)" \
    "the inline zizmor ignores have to be exactly the two expected ones, each for one rule on its own line"
}

# The same for the two configuration files. .github/actionlint.yaml holds two
# patterns for one file and nothing else : a pattern widened to match more, a
# third pattern, or the path turned into a glob would silence findings nobody
# looked at, so its lines are compared with the expected ones, comments left
# out. Deleting the file passes, which is how it is meant to end once actionlint
# knows the inputs of create-github-app-token v3 : the workflow gate then lints
# without it, or fails by itself. .github/zizmor.yml holds one policy and no
# ignore, for the same reason
function test_the_lint_configuration_files_hold_exactly_what_they_were_written_for() {
  local -r ACTIONLINT_CONFIG="$REPO_ROOT/.github/actionlint.yaml"
  local -r ZIZMOR_CONFIG="$REPO_ROOT/.github/zizmor.yml"
  if [ ! -f "$ZIZMOR_CONFIG" ]; then
    skip_test "no .github next to the scripts"
    return 0
  fi

  local -r EXPECTED_ZIZMOR='rules:
  unpinned-uses:
    config:
      policies:
        "*": ref-pin'
  assert_equals "$EXPECTED_ZIZMOR" "$(grep -vE '^[[:space:]]*(#|$)' "$ZIZMOR_CONFIG")" \
    ".github/zizmor.yml has to hold the ref-pin policy and nothing else : a looser policy or an ignore silences findings nobody looked at"

  if [ ! -f "$ACTIONLINT_CONFIG" ]; then
    pass
    return 0
  fi

  local -r EXPECTED_ACTIONLINT='paths:
  .github/workflows/auto_update_pull_request_branches.yml:
    ignore:
      - '"'"'missing input "app-id" which is required by action "actions/create-github-app-token@v3"'"'"'
      - '"'"'input "client-id" is not defined in action "actions/create-github-app-token@v3"'"'"
  assert_equals "$EXPECTED_ACTIONLINT" "$(grep -vE '^[[:space:]]*(#|$)' "$ACTIONLINT_CONFIG")" \
    ".github/actionlint.yaml has to hold exactly the two messages of create-github-app-token@v3 for the one workflow that uses it"
}
