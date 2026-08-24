#!/bin/bash

# SPDX-FileCopyrightText: 2020-2026 Tigerblue77 and the Dell iDRAC fan controller Docker image contributors
# SPDX-License-Identifier: AGPL-3.0-only

# The settings a Claude Code session starts from, under .claude/.
#
# Nothing in there reaches a server : the file holds the SessionStart hook that
# installs the linter CI gates on, and the list of commands a session may run
# without stopping to ask for a human's approval first.
#
# That list is a standing grant. It is not given to the person who wrote it, it is
# given to every session ever opened on this repository, including one acting on a
# prompt that came from a pull request body, an issue comment or a fetched page. So
# what belongs in it was argued rather than assumed (issue #382), and this file is
# where that argument is held against the settings : one guard for what the list may
# contain, one for whether the repository still runs what it names.

readonly CLAUDE_CODE_SETTINGS_FILE=".claude/settings.json"

# The suite also runs inside the built image, which carries the shipped scripts and
# none of the files a contributor works with : no .github, no .claude.
#
# jq is the second condition. The list is read out of a JSON file, and reading JSON
# with sed is how the first version of this guard came to stop at the first "]" of a
# rule and report green over everything that followed it. Two rewrites that kept to
# grep and awk were tried and measured against jq : both mis-read a rule holding an
# escaped quote, "Bash(grep -E \"[0-9]\":*)", and one of them stopped there and never
# saw the two entries after it. A rule can contain any character JSON can carry, so
# what reads it has to be a JSON parser.
#
# The suite's own dependencies stop at bash, coreutils, grep and awk, so a machine
# without jq skips these rather than turning the promise in tests/README.md into a
# lie -- the same trade cases/14 makes. The skip is reported rather than silent, the
# runner counts it, and every runner, the devcontainer and the SessionStart hook
# provide jq : what gates a pull request runs these for real
# Usage : if ! claude_code_settings_can_be_read; then skip_test "..."; return 0; fi
function claude_code_settings_can_be_read() {
  [ -f "$REPO_ROOT/$CLAUDE_CODE_SETTINGS_FILE" ] && command -v jq > /dev/null 2>&1
}

# The permission rules the settings pre-approve, one per line, exactly as written
function pre_approved_permission_rules() {
  jq -r '.permissions.allow[]?' "$REPO_ROOT/$CLAUDE_CODE_SETTINGS_FILE" 2> /dev/null
}

# The command a permission rule pre-approves, stripped of the "Bash(...)" wrapper and
# of the ":*" that makes a rule match a prefix rather than one exact command line :
# "Bash(shellcheck:*)" reads back as "shellcheck". A rule of any other shape is
# returned untouched, which is what makes it fail the guard below rather than pass it
# under a wrong name
# Usage : pre_approved_command "Bash(shellcheck:*)" -> "shellcheck"
function pre_approved_command() {
  local RULE="$1"

  if [[ "$RULE" == Bash\(*\) ]]; then
    RULE="${RULE#Bash(}"
    RULE="${RULE%)}"
    RULE="${RULE%':*'}"
  fi

  printf '%s' "$RULE"
}

function test_the_claude_code_settings_are_valid_json() {
  # A settings file that does not parse is not a settings file with one broken
  # entry : the whole of it is dropped, silently. The SessionStart hook stops
  # installing shellcheck, the permission list stops pre-approving anything, and
  # the only symptom is a session that asks about everything again -- which reads
  # as "the grant was refused" rather than as "the JSON has a trailing comma"
  if ! claude_code_settings_can_be_read; then
    skip_test "no .claude next to the scripts, or no jq to read it with"
    return 0
  fi

  assert_command_succeeds "$CLAUDE_CODE_SETTINGS_FILE should parse, a settings file that does not is ignored whole" \
    jq empty "$REPO_ROOT/$CLAUDE_CODE_SETTINGS_FILE"
}

function test_every_pre_approved_rule_is_one_that_was_argued() {
  # The rules #382 settled on, and the shape each of them is written in. Both halves
  # matter, which is why this compares whole rules rather than the commands inside
  # them : ":*" is not decoration, it pre-approves every argument list there is, and
  # an argument list is where a harmless command stops being one.
  #
  # - Bash(./tests/run_tests.sh) is EXACT, deliberately. Run with no arguments the
  #   suite mocks ipmitool, lm-sensors and sleep, needs no iDRAC and no network, and
  #   writes only inside the throwaway directory it makes with mktemp -d. Run as
  #   "--junit FILE" or "--summary FILE" it creates directories and writes wherever
  #   the caller points it -- truncating for the first, appending for the second
  #   (tests/lib/reports.sh) -- which a prefix rule would hand to every session
  #   without a prompt. Filtered runs are one prompt each ;
  #   that is the price of the entry staying what it claims to be.
  # - Bash(shellcheck:*) and Bash(bash -n:*) are prefixes, which is safe here for the
  #   reason the first one is not : neither has an option that names a file to write.
  #   They read, they analyse, and bash -n parses without running a statement of it.
  #
  # Two commands were argued out and are meant to stay out. "git" : "git diff" is
  # harmless, but the prefix matching that would allow it is easy to widen by
  # accident and the blast radius of getting it wrong once is the branch.
  # "docker build" : it runs apt-get against the network as root inside the build,
  # which is not something to grant standing approval to for the sake of one prompt.
  #
  # Nothing in Claude Code will ever refuse a fourth entry, so this is the only
  # place that can : a rule outside the vetted set fails here, and widening the
  # grant means coming back to this comment and arguing the new one the same way
  if ! claude_code_settings_can_be_read; then
    skip_test "no .claude next to the scripts, or no jq to read it with"
    return 0
  fi

  local -r PERMISSION_RULES=$(pre_approved_permission_rules)

  # Without this the loop below would report green by having nothing to iterate
  # over, which is the failure mode these guards exist to prevent in the first place
  assert_not_empty "$PERMISSION_RULES" \
    "$CLAUDE_CODE_SETTINGS_FILE should pre-approve the repository's routine commands, or this guard watches nothing" ||
    return 1

  local RULE
  while IFS= read -r RULE; do
    case "$RULE" in
      'Bash(./tests/run_tests.sh)' | 'Bash(shellcheck:*)' | 'Bash(bash -n:*)')
        pass ;;
      'Bash(./tests/run_tests.sh:*)')
        fail "[$RULE] grants the suite by prefix, which pre-approves every argument list it takes" \
          "--junit FILE and --summary FILE create directories and write wherever the caller points them" \
          "the rule that was argued is the exact one : Bash(./tests/run_tests.sh)" ;;
      *)
        fail "[$RULE] is pre-approved for every session opened on this repository, and it is not one of the rules #382 argued for" \
          "the vetted ones are : Bash(./tests/run_tests.sh), Bash(shellcheck:*), Bash(bash -n:*)" \
          "git and docker build were deliberately left out ; a new entry has to be argued the same way, here and in the settings" ;;
    esac
  done < <(printf '%s\n' "$PERMISSION_RULES")

  # The same list read the other way round. The loop above refuses a rule nobody
  # argued for ; it has nothing to say about one that quietly left, and CLAUDE.md
  # counts three of them and names all three. A grant that disappears costs no
  # security and breaks no test -- it just puts the prompts back while the
  # documentation says they are gone, which is the drift this file exists for
  local VETTED_RULE
  for VETTED_RULE in 'Bash(./tests/run_tests.sh)' 'Bash(shellcheck:*)' 'Bash(bash -n:*)'; do
    assert_contains "$PERMISSION_RULES" "$VETTED_RULE" \
      "[$VETTED_RULE] is one of the three rules #382 argued for and CLAUDE.md still names, and the settings no longer carry it"
  done
}

function test_every_pre_approved_command_is_one_the_repository_still_runs() {
  # The other end of the same list. A grant that outlives the command it was given
  # for is a grant nobody reads again : the session goes back to asking about
  # everything, the entry stays in the file looking deliberate, and the next
  # person to widen the list starts from a list already half wrong.
  #
  # Each command is held to the thing in the tree that proves the repository still
  # runs it, rather than to a second copy of the list
  if ! claude_code_settings_can_be_read; then
    skip_test "no .claude next to the scripts, or no jq to read it with"
    return 0
  fi

  local RULE COMMAND
  while IFS= read -r RULE; do
    COMMAND=$(pre_approved_command "$RULE")

    case "$COMMAND" in
      './'*)
        # A path is pre-approved relative to the project directory, which is where
        # a session runs : it has to exist there, and be runnable that way
        if [ -x "$REPO_ROOT/${COMMAND#./}" ]; then
          pass
        else
          fail "$COMMAND is pre-approved but is not an executable file of this repository" \
            "a rule naming a path that moved pre-approves nothing at all"
        fi ;;
      'shellcheck')
        # What makes the grant worth having is that a pull request is gated on it
        if [ -f "$REPO_ROOT/.github/workflows/shellcheck.yml" ]; then
          pass
        else
          fail "shellcheck is pre-approved but no workflow gates a pull request on it any more"
        fi ;;
      'bash -n')
        # The syntax check in cases/10, which is the only thing in the suite that
        # runs it. A comment does not count : cases/10 names the command in one of
        # its own comments, so a plain search for the string stayed green with the
        # function that runs it deleted -- and this file names it more often still.
        # Comments are skipped the way cases/10 skips them for the same reason, and
        # this file is left out of the search altogether
        local THIS_CASE_FILE
        THIS_CASE_FILE=$(basename "${BASH_SOURCE[0]}")

        if grep -rqE --exclude="$THIS_CASE_FILE" -- '^[^#]*bash -n' "$TESTS_DIRECTORY/cases"; then
          pass
        else
          fail "bash -n is pre-approved but nothing in the suite runs it any more"
        fi ;;
      *)
        fail "nothing in the tree proves this repository still runs [$COMMAND]" \
          "a pre-approved command needs a reason to stay pre-approved" ;;
    esac
  done < <(pre_approved_permission_rules)
}

# The hook half of the same file. The list above is what a session may run without
# asking ; this is what runs before it can ask anything at all, and nothing looked
# at it : the entry could be pointed at a path that does not exist, or dropped
# altogether, and every test here would still pass while every web session opened
# on this repository quietly lost its linter.
readonly SESSION_START_HOOK_SCRIPT=".claude/hooks/session-start.sh"

# Usage : FIELD=$(session_start_hook_field <jq-field>)
function session_start_hook_field() {
  jq -r ".hooks.SessionStart[0].hooks[0].$1 // empty" \
    "$REPO_ROOT/$CLAUDE_CODE_SETTINGS_FILE" 2> /dev/null
}

function test_the_session_start_hook_still_points_at_a_script_that_exists() {
  if ! claude_code_settings_can_be_read; then
    skip_test "no .claude next to the scripts, or no jq to read it with"
    return 0
  fi

  local COMMAND
  COMMAND="$(session_start_hook_field command)"

  assert_not_empty "$COMMAND" \
    "the SessionStart hook is what puts shellcheck in a web session ; an entry that is gone takes it with it" || return 1

  # The platform expands $CLAUDE_PROJECT_DIR to the repository root, which is
  # exactly what REPO_ROOT is here
  local -r RESOLVED_PATH="${COMMAND/\$CLAUDE_PROJECT_DIR/$REPO_ROOT}"

  assert_command_succeeds "the hook command should name a file that exists" test -f "$RESOLVED_PATH"
  assert_command_succeeds "a hook the platform cannot execute is a hook that does not run" test -x "$RESOLVED_PATH"
}

function test_the_session_start_hook_budget_outlasts_what_the_script_allows_itself() {
  if ! claude_code_settings_can_be_read; then
    skip_test "no .claude next to the scripts, or no jq to read it with"
    return 0
  fi

  if [ ! -f "$REPO_ROOT/$SESSION_START_HOOK_SCRIPT" ]; then
    skip_test "no hook script next to the settings"
    return 0
  fi

  local HOOK_TIMEOUT
  HOOK_TIMEOUT="$(session_start_hook_field timeout)"

  assert_not_empty "$HOOK_TIMEOUT" \
    "without a timeout of its own the entry takes the platform's default, which is not written down anywhere near it" || return 1

  # The script bounds each of its two apt calls with the same deadline, so its own
  # worst case is twice that. The platform's kill has to land after the script has
  # given up on its own terms : one landing inside dpkg leaves a container refusing
  # every later apt operation until "dpkg --configure -a" is run by hand, and the
  # container state is cached, so that state would outlive the session that caused it
  local SCRIPT_DEADLINE
  SCRIPT_DEADLINE="$(sed -n 's/^readonly APT_DEADLINE_SECONDS=\([0-9]\{1,\}\)$/\1/p' \
    "$REPO_ROOT/$SESSION_START_HOOK_SCRIPT")"

  assert_not_empty "$SCRIPT_DEADLINE" \
    "the hook should still bound its apt calls ; unbounded, a mirror that goes quiet holds the session open" || return 1

  local -r SCRIPT_WORST_CASE=$((SCRIPT_DEADLINE * 2))

  if [ "$HOOK_TIMEOUT" -gt "$SCRIPT_WORST_CASE" ]; then
    pass
  else
    fail "the hook's budget ($HOOK_TIMEOUT s) does not outlast what the script allows itself (${SCRIPT_WORST_CASE} s)" \
      "the platform would kill it mid-apt rather than let it report what went wrong"
  fi
}

function test_every_rule_that_was_argued_is_still_in_the_list() {
  if ! claude_code_settings_can_be_read; then
    skip_test "no .claude next to the scripts, or no jq to read it with"
    return 0
  fi

  # The two rule cases above are one-way : they walk what the file contains and
  # refuse anything outside the vetted set. Neither notices a rule that has GONE.
  # An editor conflict, a merge, or someone tidying the file can drop one and
  # leave the suite green while CLAUDE.md keeps promising a session that all three
  # are pre-approved -- so the session stops to ask for a command the document
  # said it would not have to, which reads as the grant having been refused rather
  # than lost. Completeness is the half that was missing
  local -r RULES=$(pre_approved_permission_rules)

  local RULE
  for RULE in 'Bash(./tests/run_tests.sh)' 'Bash(shellcheck:*)' 'Bash(bash -n:*)'; do
    if printf '%s\n' "$RULES" | grep -qxF "$RULE"; then
      pass
    else
      fail "$RULE was argued for and is no longer in the list" \
        "the list holds : $(printf '%s' "$RULES" | tr '\n' ' ')"
    fi
  done
}

function test_the_session_start_hook_names_the_identity_a_commit_is_signed_with() {
  if [ ! -f "$REPO_ROOT/$SESSION_START_HOOK_SCRIPT" ]; then
    skip_test "no hook script next to the settings"
    return 0
  fi

  # Two identities, answering two questions. The author says who wrote the commit and
  # is the session ; the Signed-off-by says who certifies it and is the maintainer,
  # CONTRIBUTING.md requiring a trailer that names a real person and a tool being none.
  # Drop the first pair and every commit here goes back to certifying under a name that
  # certifies nothing, which is the state issue #388 was opened over ; drop the alias and
  # "-s" derives the trailer from the author, collapsing the two the other way (#439)
  local -r HOOK=$(cat "$REPO_ROOT/$SESSION_START_HOOK_SCRIPT")

  assert_contains "$HOOK" "config user.name" \
    "the hook should still set the name a commit made here is authored under"
  assert_contains "$HOOK" "config user.email" \
    "the hook should still set the address that goes with it"
  assert_contains "$HOOK" "config alias.signoff" \
    "the hook should still set the alias carrying the maintainer's sign-off trailer"
}

function test_the_session_start_hook_sets_that_identity_before_it_can_return_early() {
  if [ ! -f "$REPO_ROOT/$SESSION_START_HOOK_SCRIPT" ]; then
    skip_test "no hook script next to the settings"
    return 0
  fi

  # The trap this pins. The container state is cached once the hook has installed
  # its packages, so from the second session onwards the run reaches the "already
  # installed" return and stops there. An identity set after that point would be
  # set exactly once, in the first session on a fresh container, and never again --
  # and nothing about the sessions that followed would look wrong until a commit
  # came out signed by the tool.
  #
  # Read as line numbers rather than by running the hook, because reproducing the
  # cached-container path here would mean installing and removing packages
  local -r IDENTITY_LINE=$(grep -n 'config user\.name' "$REPO_ROOT/$SESSION_START_HOOK_SCRIPT" | head -1 | cut -d: -f1)
  local -r EARLY_RETURN_LINE=$(grep -n 'MISSING_PACKAGES\[@\]} -eq 0' "$REPO_ROOT/$SESSION_START_HOOK_SCRIPT" | head -1 | cut -d: -f1)

  assert_not_empty "$IDENTITY_LINE" "the hook should still set the identity" || return 1
  assert_not_empty "$EARLY_RETURN_LINE" "the hook should still return early once nothing is missing" || return 1

  if [ "$IDENTITY_LINE" -lt "$EARLY_RETURN_LINE" ]; then
    pass
  else
    fail "the identity is set at line $IDENTITY_LINE, after the early return at line $EARLY_RETURN_LINE" \
      "every session but the first on a fresh container would stop before reaching it"
  fi
}

# What the two identities actually produce, run rather than grepped. The trap this exists for
# is not a missing line but a working-looking one, and the sign-off has a failure mode with no
# symptom at all : a trailer key spelled "Signed-off-by: ", separator included, emits a line
# byte-for-byte identical to a valid sign-off, which "git log" shows and %(trailers) lists,
# while a keyed read of it comes back empty and .github/check_sign_off.sh refuses the commit.
# Reading the hook's text cannot tell that apart from a correct one, and neither can reading
# the commit message ; only asking git for the trailer BY KEY can, which is what this does.
# The alias's quoting can break just as quietly (#439).
#
# git is the thing under test as much as the hook is, which is why this builds a real
# repository like tests/cases/18_sign_off.sh does instead of asserting on the text
function test_the_session_start_hook_authors_as_the_session_and_signs_off_as_the_maintainer() {
  if [ ! -f "$REPO_ROOT/$SESSION_START_HOOK_SCRIPT" ]; then
    skip_test "no hook script next to the settings"
    return 0
  fi

  if ! command -v git > /dev/null 2>&1; then
    skip_test "git is not available, and it is what this case exercises"
    return 0
  fi

  local SANDBOX
  SANDBOX=$(mktemp -d)

  # Only the identity block is run : everything below it in the hook installs packages,
  # which this has no business doing. Taken from the first constant to the "fi" closing
  # the branch that applies them, so a rewrite that moves either end fails here loudly
  local IDENTITY_BLOCK
  IDENTITY_BLOCK=$(sed -n '/^readonly SIGN_OFF_NAME/,/^fi$/p' "$REPO_ROOT/$SESSION_START_HOOK_SCRIPT")

  if ! assert_not_empty "$IDENTITY_BLOCK" "the hook should still carry an identity block"; then
    rm -rf "$SANDBOX"
    return 1
  fi

  git init --quiet --initial-branch=master "$SANDBOX"
  git -C "$SANDBOX" config commit.gpgsign false
  CLAUDE_PROJECT_DIR="$SANDBOX" bash -c "$IDENTITY_BLOCK" > /dev/null 2>&1

  printf 'x\n' > "$SANDBOX/file.txt"
  git -C "$SANDBOX" add file.txt
  git -C "$SANDBOX" signoff --quiet -m "A commit made the way a session here makes one" --no-verify

  local COMMIT_AUTHOR
  COMMIT_AUTHOR=$(git -C "$SANDBOX" log -1 --format='%an <%ae>')
  local COMMIT_SIGN_OFF
  COMMIT_SIGN_OFF=$(git -C "$SANDBOX" log -1 --format='%(trailers:key=Signed-off-by,valueonly)')

  rm -rf "$SANDBOX"

  assert_equals "Claude <noreply@anthropic.com>" "$COMMIT_AUTHOR" \
    "the author names who wrote the commit, which is the session"
  assert_equals "Tigerblue77 <37409593+tigerblue77@users.noreply.github.com>" "${COMMIT_SIGN_OFF//$'\n'/}" \
    "the trailer names who certifies it, which is the maintainer"
}

# The GitHub half of what a session starts with. The identity above governs the commits it
# makes ; this governs the two things it opens, and neither of them is a setting anywhere :
# an issue and a pull request are created through the platform's API with whatever the
# caller passes, so the only place this repository's answer can live is a sentence the
# session is handed. Two fields, both decided at that call, both left to a default nobody
# here chose until #448 : assigned, because what is not on the maintainer's list is not
# scheduled ; not a draft, because
# .github/workflows/auto_update_pull_request_branches.yml skips drafts, which makes one
# opened here the single pull request master's moves never reach.
#
# A sentence is all it is, which is exactly why it is guarded : nothing downstream refuses a
# pull request for being a draft, and nothing refuses an assignee for being the wrong
# person, so a line quietly lost here has no symptom at all.
#
# And it is said to the maintainer's sessions only. This file travels with the tree, so a
# contributor's session on their fork runs the same hook, where neither half holds : GitHub
# drops "assignees" from a caller without write access, silently, and their draft is what
# the branch updater's filter exists to leave alone (#457). The cases below run the block
# against a repository whose origin they choose, which is the only way to see what a fork
# is told without owning one.

# The announcement, taken from the constant to the "fi" that closes its guard, so a rewrite
# moving either end fails these loudly rather than quietly running more of the hook than was
# meant -- everything below it installs packages.
# Usage : announcement_block
function announcement_block() {
  awk '/^readonly MAINTAINER_GITHUB_LOGIN=/ { IS_BLOCK = 1 }
       IS_BLOCK
       IS_BLOCK && /^fi$/ { exit }' "$REPO_ROOT/$SESSION_START_HOOK_SCRIPT"
}

# What the hook prints in a repository whose origin is the URL given, or nothing at all when
# it is called with none. Run rather than read : the login reaches the message through a
# variable and the fork check through git itself, and reading the text would prove that both
# are mentioned while saying nothing about what either one answers.
# Usage : announcement_for_origin "https://github.com/owner/repository" -> what it says
function announcement_for_origin() {
  local -r ORIGIN="$1"

  local SANDBOX
  SANDBOX=$(mktemp -d)

  # Every git configuration the machine can supply is taken out of the way, here and around
  # the block below. Not tidiness : "url.<base>.insteadOf" rewrites a remote AT READ TIME,
  # so a machine carrying one hands the SSH case the HTTPS form -- the case then passes
  # without ever reaching the branch written for it, and goes on passing once that branch is
  # deleted. Measured on the first version of these cases, where deleting it changed nothing.
  #
  # THREE sources, and the third is the one that surprised this file. Two are files, silenced
  # by pointing them at /dev/null. The third is the environment : GIT_CONFIG_COUNT with its
  # GIT_CONFIG_KEY_n / GIT_CONFIG_VALUE_n pairs is configuration git reads before either
  # file, unaffected by silencing them, and it is what carries the rewrite in Claude Code on
  # the web -- three pairs, two of them "url.https://github.com/.insteadOf". Dropping the
  # count is what disables them : git reads exactly that many pairs and no more.
  #
  # A sandbox that reads the machine it runs on is not a sandbox, which is the reason
  # cases/18 gives for building a repository of its own rather than trusting the developer's
  local -r HERMETIC_GIT=(env -u GIT_CONFIG_COUNT GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null)

  "${HERMETIC_GIT[@]}" git init --quiet --initial-branch=master "$SANDBOX"

  if [ -n "$ORIGIN" ]; then
    "${HERMETIC_GIT[@]}" git -C "$SANDBOX" remote add origin "$ORIGIN"
  fi

  local -r BLOCK=$(announcement_block)
  local OUTPUT
  OUTPUT=$("${HERMETIC_GIT[@]}" CLAUDE_PROJECT_DIR="$SANDBOX" bash -c "$BLOCK" 2>&1)

  rm -rf "$SANDBOX"

  printf '%s' "$OUTPUT"
}

# Usage : if ! the_announcement_can_be_run; then skip_test "..."; return 0; fi
function the_announcement_can_be_run() {
  [ -f "$REPO_ROOT/$SESSION_START_HOOK_SCRIPT" ] && command -v git > /dev/null 2>&1
}

function test_the_session_start_hook_states_how_an_issue_or_pull_request_is_opened() {
  if ! the_announcement_can_be_run; then
    skip_test "no hook script next to the settings, or no git to read a remote with"
    return 0
  fi

  assert_not_empty "$(announcement_block)" \
    "the hook should still name the login a session opens an issue and a pull request under" || return 1

  local -r ANNOUNCEMENT=$(announcement_for_origin "https://github.com/tigerblue77/Dell_iDRAC_fan_controller_Docker.git")

  assert_contains "$ANNOUNCEMENT" "assigned to tigerblue77" \
    "the session should be told who an issue and a pull request opened here belong to"
  assert_contains "$ANNOUNCEMENT" "never a draft" \
    "the session should be told that a pull request opened here is not a draft, its harness having told it otherwise"
}

function test_the_ssh_form_of_this_repositorys_origin_is_recognised_too() {
  if ! the_announcement_can_be_run; then
    skip_test "no hook script next to the settings, or no git to read a remote with"
    return 0
  fi

  # "git@github.com:owner/repository" carries the owner behind a colon rather than a slash,
  # and a clone URL keeps whatever case was typed while a GitHub login compares
  # case-insensitively. A check that reads only the HTTPS form, or only lower case, would
  # leave the maintainer's own session silently unaddressed -- the failure this whole rule
  # exists to prevent, arrived at from the other side
  local -r ANNOUNCEMENT=$(announcement_for_origin "git@github.com:Tigerblue77/Dell_iDRAC_fan_controller_Docker.git")

  assert_contains "$ANNOUNCEMENT" "assigned to tigerblue77" \
    "an SSH remote, in any case, is still this repository"
}

function test_a_session_on_a_contributors_fork_is_told_none_of_it() {
  if ! the_announcement_can_be_run; then
    skip_test "no hook script next to the settings, or no git to read a remote with"
    return 0
  fi

  # The case #457 was opened over. A contributor forks, opens a session, and this hook runs
  # for them exactly as it does here : telling them to assign the maintainer is an
  # instruction GitHub will drop without a word, and telling them not to open a draft
  # contradicts the one carve-out the branch updater makes for their benefit
  local -r ANNOUNCEMENT=$(announcement_for_origin "https://github.com/a-contributor/Dell_iDRAC_fan_controller_Docker.git")

  assert_empty "$ANNOUNCEMENT" \
    "a fork is somebody else's repository, and this rule is not addressed to their session"
}

function test_a_checkout_with_no_origin_is_told_nothing_either() {
  if ! the_announcement_can_be_run; then
    skip_test "no hook script next to the settings, or no git to read a remote with"
    return 0
  fi

  # Silence on every answer that is not this repository, including no answer at all. The
  # trade is deliberate and it is not symmetrical : a checkout with no origin loses a
  # reminder CLAUDE.md still carries, while the opposite default would hand the rule to
  # whoever happens to have cloned the tree
  local -r ANNOUNCEMENT=$(announcement_for_origin "")

  assert_empty "$ANNOUNCEMENT" \
    "a checkout with no remote is not evidence that this is the maintainer's own"
}

function test_the_session_start_hook_says_that_before_it_can_return_early() {
  if [ ! -f "$REPO_ROOT/$SESSION_START_HOOK_SCRIPT" ]; then
    skip_test "no hook script next to the settings"
    return 0
  fi

  # The same trap the identity case above pins, and this half falls into it more easily
  # because it is only an echo : the container is cached once the packages are installed,
  # so from the second session onwards the run reaches the "already installed" return and
  # stops there. A reminder printed after that point would be printed once, on a fresh
  # container, to the one session that happened to open it first
  local -r ANNOUNCEMENT_LINE=$(grep -n 'MAINTAINER_GITHUB_LOGIN' "$REPO_ROOT/$SESSION_START_HOOK_SCRIPT" | tail -1 | cut -d: -f1)
  local -r EARLY_RETURN_LINE=$(grep -n 'MISSING_PACKAGES\[@\]} -eq 0' "$REPO_ROOT/$SESSION_START_HOOK_SCRIPT" | head -1 | cut -d: -f1)

  assert_not_empty "$ANNOUNCEMENT_LINE" "the hook should still say how an issue and a pull request are opened" || return 1
  assert_not_empty "$EARLY_RETURN_LINE" "the hook should still return early once nothing is missing" || return 1

  if [ "$ANNOUNCEMENT_LINE" -lt "$EARLY_RETURN_LINE" ]; then
    pass
  else
    fail "the rule is stated at line $ANNOUNCEMENT_LINE, after the early return at line $EARLY_RETURN_LINE" \
      "every session but the first on a fresh container would stop before being told it"
  fi
}

function test_the_login_a_session_assigns_to_is_the_maintainer_the_commits_are_signed_off_under() {
  if [ ! -f "$REPO_ROOT/$SESSION_START_HOOK_SCRIPT" ]; then
    skip_test "no hook script next to the settings"
    return 0
  fi

  # One person, written down twice in the same file : the address the sign-off trailer
  # carries, and the login an issue is assigned to. Nothing makes them agree, and they
  # fail differently -- a wrong address is refused by .github/check_sign_off.sh, while a
  # wrong login is refused by nobody, GitHub accepting any name that exists, and the work
  # simply lands on a stranger's list with everything looking right here.
  #
  # The address is the half with a gate behind it, so it is the one the login is measured
  # against : GitHub's no-reply form is "<id>+<login>@users.noreply.github.com"
  local -r SIGN_OFF_ADDRESS=$(sed -nE 's/^readonly SIGN_OFF_EMAIL="(.*)"$/\1/p' "$REPO_ROOT/$SESSION_START_HOOK_SCRIPT" | head -1)
  local -r ASSIGNEE_LOGIN=$(sed -nE 's/^readonly MAINTAINER_GITHUB_LOGIN="(.*)"$/\1/p' "$REPO_ROOT/$SESSION_START_HOOK_SCRIPT" | head -1)

  assert_not_empty "$SIGN_OFF_ADDRESS" "the hook should still name the address a commit is signed off with" || return 1
  assert_not_empty "$ASSIGNEE_LOGIN" "the hook should still name the login an issue is assigned to" || return 1

  # Checked rather than assumed : the parse below reads a "+" that a plain address does
  # not carry, and would otherwise compare the login against a whole local part and call
  # the difference drift
  assert_matches "$SIGN_OFF_ADDRESS" '^[0-9]+\+[^@]+@users\.noreply\.github\.com$' \
    "the sign-off address should still be a GitHub no-reply one, which is what carries the login" || return 1

  local -r LOGIN_IN_ADDRESS="${SIGN_OFF_ADDRESS#*+}"

  assert_equals "${LOGIN_IN_ADDRESS%@*}" "$ASSIGNEE_LOGIN" \
    "the login a session assigns to and the address it signs off under should name the same person"
}
