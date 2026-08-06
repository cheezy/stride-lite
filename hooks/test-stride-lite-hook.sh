#!/usr/bin/env bash
#
# test-stride-lite-hook.sh — dedicated suite for hooks/stride-lite-hook.sh
#
# SCOPE, and why it is drawn where it is.
#
#   test/smoke.sh already drives the hook script as a SUBPROCESS: the three
#   trigger conditions, the non-matching payload shapes, the nine derived env
#   keys, and every marker-freshness state. Re-asserting any of that here would
#   be a byte-for-byte duplicate, and two copies of one assertion rot in
#   opposite directions.
#
#   This suite owns what a subprocess test cannot reach cheaply: the internals
#   of `run_stride_lite_section` and each private helper. It gets at them
#   through the affordance the hook script documents for exactly this purpose --
#   sourcing it with no arguments defines every function and returns before the
#   main flow reads stdin.
#
# WHERE EACH SUBJECT LIVES, stated because the task's acceptance criterion
# names this file as the subject for all of them and that is not where they all
# ended up. Coverage is distributed across the pair by level of access:
#
#   trigger routing, all three hooks .............. test/smoke.sh (subprocess)
#   non-matching payload shapes ................... test/smoke.sh (subprocess)
#   the nine derived env keys ..................... test/smoke.sh (subprocess)
#   shell-metacharacter inertness ................. test/smoke.sh (subprocess)
#   every marker-freshness STATE .................. test/smoke.sh (subprocess)
#
#   section parsing and its four no-op branches ... here
#   per-command execution, first-failure stop ..... here
#   both structured JSON shapes, key counts ....... here
#   output truncation ............................. here
#   env DERIVATION helpers, branch by branch ...... here
#   marker-gate RETURN CODES ...................... here
#   the main-flow guards no fixture reached ....... here
#
# Moving the smoke.sh cases here would violate the non-duplication requirement
# and would replace a stronger metacharacter case -- it asserts non-execution
# twice, including that no marker file appeared -- with a weaker new one.
#
# Pure bash. No jq, no python3, no network. Every fixture command is inert and
# confined to a sandbox; the suite leaves nothing behind.
#
# Usage: bash hooks/test-stride-lite-hook.sh
# Exit:  0 if every assertion passed, 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK_SH="$SCRIPT_DIR/stride-lite-hook.sh"

PASS=0
FAIL=0
SKIP=0

ok()   { PASS=$((PASS + 1)); echo "  PASS  $1"; }
nope() {
  FAIL=$((FAIL + 1))
  echo "  FAIL  $1" >&2
  echo "        expected: $2" >&2
  echo "        actual:   $3" >&2
}
skip() { SKIP=$((SKIP + 1)); echo "  SKIP  $1 — $2"; }

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then ok "$label"; else nope "$label" "$expected" "$actual"; fi
}
assert_has() {
  local label="$1" haystack="$2" needle="$3"
  case "$haystack" in *"$needle"*) ok "$label" ;; *) nope "$label" "contains: $needle" "$haystack" ;; esac
}
# An empty haystack trivially lacks any needle, so a negative assertion against
# one passes for a reason that has nothing to do with the subject. Refuse it
# rather than relying on every call site being paired with a positive.
assert_lacks() {
  local label="$1" haystack="$2" needle="$3"
  if [ -z "$haystack" ]; then
    nope "$label" "a non-empty haystack to search" "(empty)"
    return
  fi
  case "$haystack" in *"$needle"*) nope "$label" "must NOT contain: $needle" "$haystack" ;; *) ok "$label" ;; esac
}

if [ ! -f "$HOOK_SH" ]; then
  echo "FATAL: $HOOK_SH not found" >&2
  exit 1
fi

# One sandbox for the run, a named subdirectory per fixture -- the same shape
# test/smoke.sh and stride's own suites use. The trap fires on every exit path,
# so a failed assertion still cleans up.
# Honour STRIDE_LITE_TEST_SANDBOX_BASE when set, so the confinement claim can be
# checked from a path containing a space. BSD `mktemp -d` with no template
# ignores TMPDIR, so setting TMPDIR alone silently proves nothing.
SANDBOX_BASE_CREATED=""
if [ -n "${STRIDE_LITE_TEST_SANDBOX_BASE:-}" ]; then
  [ -d "$STRIDE_LITE_TEST_SANDBOX_BASE" ] || SANDBOX_BASE_CREATED=1
  mkdir -p "$STRIDE_LITE_TEST_SANDBOX_BASE"
  SANDBOX="$(mktemp -d "$STRIDE_LITE_TEST_SANDBOX_BASE/tmp.XXXXXX")"
else
  SANDBOX="$(mktemp -d)"
fi
# Remove the opt-in base too, but only if this run created it and only if it is
# empty -- `rmdir` refuses a non-empty directory, so a base the operator was
# already using cannot be taken out from under them.
_cleanup() {
  rm -rf "$SANDBOX"
  if [ -n "$SANDBOX_BASE_CREATED" ]; then
    _d="$STRIDE_LITE_TEST_SANDBOX_BASE"
    while [ -n "$_d" ] && [ "$_d" != "/" ] && [ "$_d" != "." ]; do
      rmdir "$_d" 2>/dev/null || break
      _d="$(dirname "$_d")"
    done
  fi
  return 0
}
trap _cleanup EXIT

echo "stride-lite hook script — dedicated suite"
echo "sandbox: $SANDBOX"

# ---------------------------------------------------------------------------
# Source the script to get its functions without running the main flow.
#
# The script's own comment sanctions this: "Early exits placed after function
# definitions so tests can source this script and invoke run_stride_lite_section
# in isolation." With no positional argument, PHASE is empty and the main flow
# returns before `INPUT=$(cat)` -- so sourcing never blocks on stdin.
# ---------------------------------------------------------------------------
export CLAUDE_PROJECT_DIR="$SANDBOX"
# shellcheck disable=SC1090
. "$HOOK_SH"

echo ""
echo "the sourcing affordance itself"

# If this ever regresses -- an early exit moved above the function definitions,
# or the main flow stops guarding on an empty PHASE -- every case below would
# silently test nothing. Prove the affordance works before relying on it.
if command -v run_stride_lite_section >/dev/null 2>&1; then
  ok "sourcing with no argument defines run_stride_lite_section"
else
  nope "sourcing with no argument defines run_stride_lite_section" "a defined function" "undefined"
fi
_MISSING_FN=""
for _fn in _extract_string _json_escape _json_array_from_lines _marker_is_fresh \
           _export_env_kv _resolve_in_project _first_heading _path_from_prompt \
           _derive_hook_env run_stride_lite_section; do
  command -v "$_fn" >/dev/null 2>&1 || _MISSING_FN="$_MISSING_FN [$_fn]"
done
assert_eq "sourcing defines every helper this suite exercises" "$_MISSING_FN" ""

# ---------------------------------------------------------------------------
# run_stride_lite_section — the no-op branches
#
# Four different inputs all mean "nothing to run", and all four must return 0
# with empty stdout. They are separate branches in the function and a reader
# would reasonably expect at least one of them to be an error, so each is
# pinned individually rather than as a group.
# ---------------------------------------------------------------------------
echo ""
echo "run_stride_lite_section — the no-op branches"

# Runs the section and leaves stdout in $OUT and the return code in $RC.
# Not a command substitution: $() runs in a subshell, so a return code assigned
# inside it never reaches the caller -- the first version of this helper looked
# like it worked and reported an unbound variable instead.
_run_section() {  # $1 = project dir, $2 = section name
  local _d="$1" _s="$2"
  PROJECT_DIR="$_d"
  STRIDE_LITE_MD="$_d/.stride_lite.md"
  # run_stride_lite_section does a bare `cd "$PROJECT_DIR"` with no subshell, so
  # calling it in the current shell permanently relocates the suite's cwd into a
  # fixture the EXIT trap later deletes. Contain it.
  ( cd "$SANDBOX" && run_stride_lite_section "$_s" ) > "$SANDBOX/.out" 2> "$SANDBOX/.err"
  RC=$?
  OUT=$(cat "$SANDBOX/.out")
  ERR=$(cat "$SANDBOX/.err")
}

NOOP_MISSING_FILE="$SANDBOX/noop-missing-file"
mkdir -p "$NOOP_MISSING_FILE"          # deliberately no .stride_lite.md
_run_section "$NOOP_MISSING_FILE" before_task
assert_eq "a missing .stride_lite.md returns 0" "$RC" "0"
assert_eq "a missing .stride_lite.md emits nothing" "$OUT" ""

NOOP_NO_SECTION="$SANDBOX/noop-no-section"
mkdir -p "$NOOP_NO_SECTION"
cat > "$NOOP_NO_SECTION/.stride_lite.md" <<'FIXTURE'
# stride-lite hooks

## after_task

```bash
true
```
FIXTURE
_run_section "$NOOP_NO_SECTION" before_task
assert_eq "a missing section returns 0" "$RC" "0"
assert_eq "a missing section emits nothing" "$OUT" ""
# ...and the section that IS present still runs, so the case above proves the
# heading match is selective rather than the file being unreadable.
_run_section "$NOOP_NO_SECTION" after_task
assert_eq "the section that is present still runs" "$RC" "0"
assert_has "the present section emits success JSON" "$OUT" '"status":"success"'

NOOP_EMPTY_BLOCK="$SANDBOX/noop-empty-block"
mkdir -p "$NOOP_EMPTY_BLOCK"
printf '## before_task\n\n```bash\n```\n' > "$NOOP_EMPTY_BLOCK/.stride_lite.md"
_run_section "$NOOP_EMPTY_BLOCK" before_task
assert_eq "an empty fenced block returns 0" "$RC" "0"
assert_eq "an empty fenced block emits nothing" "$OUT" ""

# A body of nothing but comments and blanks filters down to zero commands. This
# is a DIFFERENT branch from the empty block -- the block is non-empty, the
# command list is -- and it is the shape a user leaves behind after commenting
# a hook out, which is exactly when a spurious failure would be most confusing.
NOOP_COMMENTS="$SANDBOX/noop-comments"
mkdir -p "$NOOP_COMMENTS"
cat > "$NOOP_COMMENTS/.stride_lite.md" <<'FIXTURE'
## before_task

```bash
# commented out while I debug something
#   indented comment

# another
```
FIXTURE
_run_section "$NOOP_COMMENTS" before_task
assert_eq "a comment-only body returns 0" "$RC" "0"
assert_eq "a comment-only body emits nothing" "$OUT" ""

# ---------------------------------------------------------------------------
# run_stride_lite_section — the success shape
#
# test/smoke.sh checks the substring '"status":"success"'. Nothing anywhere
# counts the success JSON's keys or looks at what commands_completed actually
# contains, while the failure shape's nine keys ARE counted -- so the success
# shape is the weaker half of a pair.
# ---------------------------------------------------------------------------
echo ""
echo "run_stride_lite_section — the success shape"

SUCCESS_DIR="$SANDBOX/success-multi"
mkdir -p "$SUCCESS_DIR"
cat > "$SUCCESS_DIR/.stride_lite.md" <<'FIXTURE'
## before_task

```bash
true
# a comment between commands must not become a command
:
true
```
FIXTURE
_run_section "$SUCCESS_DIR" before_task
assert_eq "a multi-command section returns 0" "$RC" "0"
assert_has "the success JSON names its hook" "$OUT" '"hook":"before_task"'
assert_has "the success JSON reports success" "$OUT" '"status":"success"'
SUCCESS_KEYS=$(printf '%s' "$OUT" | grep -oE '"[a-z_]+":' | sort -u | tr -d '":' | tr '\n' ' ')
assert_eq "the success JSON carries exactly its four documented keys" \
  "$SUCCESS_KEYS" "commands_completed duration_seconds hook status "
# The comment line must not appear as a command. Counting the array's entries is
# what proves the filter ran -- a substring check would pass either way.
SUCCESS_N=$(printf '%s' "$OUT" | sed -n 's/.*"commands_completed":\[\([^]]*\)\].*/\1/p' | tr ',' '\n' | grep -c .)
assert_eq "commands_completed holds one entry per real command" "$SUCCESS_N" "3"
assert_lacks "commands_completed excludes the comment line" "$OUT" "must not become a command"

# ---------------------------------------------------------------------------
# run_stride_lite_section — first-failure stop and the failure shape
#
# test/smoke.sh only ever fails a SINGLE-command section, so the fields that
# describe position in a list -- command_index, commands_completed,
# commands_remaining -- have never been asserted against real content. A
# single-command fixture cannot distinguish a correct partition from one that
# is off by one, or reversed.
# ---------------------------------------------------------------------------
echo ""
echo "run_stride_lite_section — first-failure stop"

FAIL_DIR="$SANDBOX/fail-midlist"
mkdir -p "$FAIL_DIR"
cat > "$FAIL_DIR/.stride_lite.md" <<'FIXTURE'
## before_task

```bash
echo marker-one
false
echo marker-three
```
FIXTURE
_run_section "$FAIL_DIR" before_task
assert_eq "a failing command returns 2" "$RC" "2"
assert_has "the failure JSON names the failing command" "$OUT" '"failed_command":"false"'
# command_index is ZERO-based -- agents/hook-diagnostician.md documents it as
# "its zero-based position in the section" -- while the human-facing stderr line
# converts to 1-based. Both are correct and they must not drift into each other.
assert_eq "the failure JSON reports a zero-based index" \
  "$(printf '%s' "$OUT" | sed -n 's/.*"command_index":\([0-9]*\).*/\1/p')" "1"
assert_has "the stderr summary converts to 1-based for a human" "$ERR" \
  "failed on command 2/3"
assert_has "the failure JSON carries the command's exit code" "$OUT" '"exit_code":1'
# The partition is the point: everything before the failure ran, everything
# after it did not, and the failing command is in neither list.
assert_has "commands_completed holds only what ran" "$OUT" '"commands_completed":["echo marker-one"]'
assert_has "commands_remaining holds only what did not" "$OUT" '"commands_remaining":["echo marker-three"]'
assert_lacks "the failing command is in neither partition" "$OUT" '"commands_completed":["echo marker-one","false"]'
# Stop-on-first-failure, proven by absence: the third command's own output must
# not appear anywhere, on either stream.
# Proving the third command did not RUN is not the same as proving the string is
# absent -- it legitimately appears in commands_remaining. The stderr stream is
# where a command's output actually lands, so that is where to look.
#
# NOT the JSON's stdout field: that always holds the FAILING command's stdout,
# captured into its own temp file, so it would read empty even if the third
# command had run. An assertion that cannot fail for the reason its label gives
# is worse than no assertion.
assert_lacks "the third command's output never reached stderr" "$ERR" "marker-three"
# And the first command's output DID reach stderr, so the case above is not
# passing because nothing ran at all.
assert_has "the first command did run" "$ERR" "marker-one"
FAILURE_KEYS=$(printf '%s' "$OUT" | grep -oE '"[a-z_]+":' | sort -u | tr -d '":' | tr '\n' ' ')
assert_eq "the failure JSON carries exactly its nine documented keys" "$FAILURE_KEYS" \
  "command_index commands_completed commands_remaining exit_code failed_command hook status stderr stdout "

# The whole failure path must also work when the FIRST command fails, where the
# completed list is empty rather than merely short -- an empty JSON array is the
# shape most likely to be rendered as null or omitted.
FAIL_FIRST="$SANDBOX/fail-first"
mkdir -p "$FAIL_FIRST"
printf '## after_task\n\n```bash\nfalse\necho unreached\n```\n' > "$FAIL_FIRST/.stride_lite.md"
_run_section "$FAIL_FIRST" after_task
assert_eq "failing on the first command returns 2" "$RC" "2"
assert_has "an empty completed list renders as []" "$OUT" '"commands_completed":[]'
assert_eq "the index is 0 when the first command fails" \
  "$(printf '%s' "$OUT" | sed -n 's/.*"command_index":\([0-9]*\).*/\1/p')" "0"
assert_has "the stderr summary still reads 1/2 for a human" "$ERR" "failed on command 1/2"

# Output is tailed to the last 50 lines. Nothing exercises the truncation, and
# an untruncated failure JSON on a chatty command is how a hook payload becomes
# unusable rather than merely large.
echo ""
echo "run_stride_lite_section — output truncation"

TAIL_DIR="$SANDBOX/tail-50"
mkdir -p "$TAIL_DIR"
cat > "$TAIL_DIR/.stride_lite.md" <<'FIXTURE'
## before_task

```bash
i=1; while [ $i -le 120 ]; do echo "line-$i"; i=$((i + 1)); done; false
```
FIXTURE
_run_section "$TAIL_DIR" before_task
assert_eq "the chatty failing command returns 2" "$RC" "2"
assert_has "the tail keeps the last line" "$OUT" "line-120"
assert_lacks "the tail drops the first line" "$OUT" "line-1\\n"
assert_lacks "the tail drops everything before the last 50" "$OUT" "line-70"
assert_has "the tail keeps exactly the last 50" "$OUT" "line-71"

# ---------------------------------------------------------------------------
# _export_env_kv — the sanitization branches
#
# test/smoke.sh asserts the nine keys arrive with the right values. It never
# reaches the branches that refuse or reshape a value, because those need a key
# or a value the derivation path cannot produce.
# ---------------------------------------------------------------------------
echo ""
echo "_export_env_kv — sanitization"

# A key that is not a valid shell identifier is dropped rather than exported,
# because `export 1FOO=x` is a syntax error that would take the whole hook down.
# Checked through `env` rather than `${1FOO}` -- bash cannot even parse a
# parameter expansion whose name starts with a digit, which is the whole reason
# the function refuses such keys.
_export_env_kv "1FOO" "value"
assert_eq "a key starting with a digit is dropped" "$(env | grep -c '^1FOO=')" "0"
_export_env_kv "FOO-BAR" "value"
assert_eq "a key containing a hyphen is dropped" "$(env | grep -c '^FOO-BAR=')" "0"
_export_env_kv "VALID_KEY_1" "kept"
assert_eq "a valid identifier is exported" "${VALID_KEY_1:-}" "kept"

# Control characters are stripped. A raw newline or carriage return in an
# exported value is what turns one env assignment into two.
_export_env_kv "CTRL_TEST" "$(printf 'a\tb\rc')"
assert_eq "control characters are stripped from the value" "${CTRL_TEST:-}" "abc"

# Values are capped at 512 bytes. A task title is attacker-influenceable in the
# sense that it comes from a file, and an unbounded export is an unbounded
# environment.
_LONG=$(printf 'x%.0s' $(seq 1 900))
_export_env_kv "LONG_TEST" "$_LONG"
assert_eq "an oversized value is truncated to 512 bytes" "${#LONG_TEST}" "512"
_SHORT=$(printf 'y%.0s' $(seq 1 100))
_export_env_kv "SHORT_TEST" "$_SHORT"
assert_eq "a value under the cap is left whole" "${#SHORT_TEST}" "100"

# ---------------------------------------------------------------------------
# _resolve_in_project — containment
#
# smoke.sh reaches the traversal refusal. The symlink refusal is a separate
# branch and is the one that matters more: a traversal is visible in the path,
# a symlink is not.
# ---------------------------------------------------------------------------
echo ""
echo "_resolve_in_project — containment"

RESOLVE_DIR="$SANDBOX/resolve"
mkdir -p "$RESOLVE_DIR/goal"
OUTSIDE="$SANDBOX/outside"
mkdir -p "$OUTSIDE"
printf '# Real task\n' > "$RESOLVE_DIR/goal/task1.md"
printf '# Secret\n' > "$OUTSIDE/secret.md"
# Canonicalize the fixture root exactly as the script does at startup. Without
# this, `pwd -P` resolves the sandbox's /var to /private/var and NOTHING matches
# the containment prefix -- every refusal below would pass because every path
# resolved to empty. The positive control immediately after is what catches
# that, and it is the reason this block has one.
_PROJECT_ABS="$(cd "$RESOLVE_DIR" && pwd -P)"
PROJECT_DIR="$_PROJECT_ABS"

# THE POSITIVE CONTROL. Every assertion below expects empty, so without one
# passing case they would all be satisfied by a function that always returns
# empty for an unrelated reason.
assert_eq "a real file inside the project resolves" \
  "$(_resolve_in_project "goal/task1.md")" "$_PROJECT_ABS/goal/task1.md"
assert_eq "an empty path resolves to empty" "$(_resolve_in_project "")" ""
assert_eq "a file outside the project is refused" "$(_resolve_in_project "../outside/secret.md")" ""
assert_eq "a nonexistent file resolves to empty" "$(_resolve_in_project "goal/nope.md")" ""

# The symlink refusal. Both directions matter: a link pointing outside is the
# obvious attack, and a link pointing INSIDE is refused too -- the rule is about
# the final component being a link at all, not about where it lands, because
# the target can be repointed after the check.
ln -sf "$OUTSIDE/secret.md" "$RESOLVE_DIR/goal/link-out.md"
assert_eq "a symlink pointing outside the project is refused" \
  "$(_resolve_in_project "goal/link-out.md")" ""
ln -sf "$RESOLVE_DIR/goal/task1.md" "$RESOLVE_DIR/goal/link-in.md"
assert_eq "a symlink pointing inside the project is refused too" \
  "$(_resolve_in_project "goal/link-in.md")" ""

# ---------------------------------------------------------------------------
# _first_heading
# ---------------------------------------------------------------------------
echo ""
echo "_first_heading"

HEAD_DIR="$SANDBOX/headings"
mkdir -p "$HEAD_DIR"
printf '# The title\n\nBody.\n' > "$HEAD_DIR/plain.md"
assert_eq "the first H1 is returned" "$(_first_heading "$HEAD_DIR/plain.md")" "The title"
printf 'Prose first.\n\n# Later title\n' > "$HEAD_DIR/late.md"
assert_eq "an H1 after prose is still found" "$(_first_heading "$HEAD_DIR/late.md")" "Later title"
# Only a single-# heading counts. An H2 is not a title, and scanning must
# continue past it rather than stopping or returning it.
printf '## Not a title\n\n# The real title\n' > "$HEAD_DIR/h2first.md"
assert_eq "an H2 is skipped and scanning continues" "$(_first_heading "$HEAD_DIR/h2first.md")" "The real title"
printf 'No heading at all.\n' > "$HEAD_DIR/none.md"
assert_eq "a file with no H1 returns empty" "$(_first_heading "$HEAD_DIR/none.md")" ""
assert_eq "a missing file returns empty" "$(_first_heading "$HEAD_DIR/absent.md")" ""
# The scan stops at 200 lines, so a heading below that is deliberately not
# found -- an unbounded read of an arbitrary file is the thing being avoided.
{ printf 'filler\n%.0s' $(seq 1 205); printf '# Too late\n'; } > "$HEAD_DIR/deep.md"
assert_eq "a heading past the 200-line cap is not found" "$(_first_heading "$HEAD_DIR/deep.md")" ""
{ printf 'filler\n%.0s' $(seq 1 150); printf '# Just in time\n'; } > "$HEAD_DIR/shallow.md"
assert_eq "a heading within the cap is found" "$(_first_heading "$HEAD_DIR/shallow.md")" "Just in time"

# ---------------------------------------------------------------------------
# _path_from_prompt
#
# Every one of these branches exists because a dispatch prompt is prose written
# by an agent, not a path passed by a caller.
# ---------------------------------------------------------------------------
echo ""
echo "_path_from_prompt"

assert_eq "an empty prompt yields empty" "$(_path_from_prompt "")" ""
assert_eq "a bare task path is found" "$(_path_from_prompt "Review docs/g/task2.md now")" "docs/g/task2.md"
assert_eq "a bare goal path is found" "$(_path_from_prompt "See docs/g/goal.md")" "docs/g/goal.md"
# Escape sequences arrive as literal backslash-n in a JSON-carried prompt, so
# they have to be treated as separators or the path fuses to its neighbour.
assert_eq "a literal \\n before the path is a separator" \
  "$(_path_from_prompt 'Task:\ndocs/g/task1.md\nGo')" "docs/g/task1.md"
assert_eq "a literal \\t is a separator too" \
  "$(_path_from_prompt 'Task:\tdocs/g/task3.md')" "docs/g/task3.md"
# Surrounding punctuation is stripped from both ends -- prose puts paths in
# parentheses, quotes and sentence-final periods.
assert_eq "a trailing period is stripped" "$(_path_from_prompt "Read docs/g/task1.md.")" "docs/g/task1.md"
assert_eq "wrapping parentheses are stripped" "$(_path_from_prompt "Read (docs/g/task1.md)")" "docs/g/task1.md"
assert_eq "wrapping backticks are stripped" "$(_path_from_prompt 'Read `docs/g/task1.md`')" "docs/g/task1.md"
assert_eq "a trailing comma is stripped" "$(_path_from_prompt "Read docs/g/task1.md, then stop")" "docs/g/task1.md"
# Only goal.md and task<digits>.md are recognised. A near-miss must yield empty
# rather than a path the rest of the derivation would then treat as real.
assert_eq "task.md without a number is not a task file" "$(_path_from_prompt "Read docs/g/task.md")" ""
assert_eq "taskX.md is not a task file" "$(_path_from_prompt "Read docs/g/taskX.md")" ""
assert_eq "an unrelated markdown file is not matched" "$(_path_from_prompt "Read docs/g/notes.md")" ""
# Prose with no path at all is the common case for a hand-written dispatch.
assert_eq "prose with no path yields empty" \
  "$(_path_from_prompt "Please review the second task in the goal")" ""

# ---------------------------------------------------------------------------
# _derive_hook_env — the loose-task branch
#
# The README documents `<output-dir>/tasks/<slug>.md` as a real shape: a single
# task with no sibling goal.md. Every smoke.sh fixture is a goal directory, so
# this branch -- which must clear GOAL_DIR and GOAL_FILE rather than pointing
# them at whatever happens to be adjacent -- is reached by nothing.
# ---------------------------------------------------------------------------
echo ""
echo "_derive_hook_env — a loose task with no sibling goal.md"

LOOSE_DIR="$SANDBOX/loose"
mkdir -p "$LOOSE_DIR/tasks"
printf '# A standalone task\n' > "$LOOSE_DIR/tasks/some-slug.md"
# The hook name matters here and is easy to get wrong. `before_task` routes the
# source through _path_from_prompt, which matches only goal.md and task<N>.md --
# so a slug-named file never resolves and the WHOLE derivation block is skipped.
# Every "is empty" assertion below would then pass because nothing resolved,
# which is the opposite of testing the branch. `after_goal` takes the candidate
# directly, which is what reaches it.
PROJECT_DIR="$(cd "$LOOSE_DIR" && pwd -P)"
_PROJECT_ABS="$PROJECT_DIR"
_reset_env_keys() {
  for _k in HOOK_NAME TASK_FILE TASK_NUMBER TASK_TITLE GOAL_DIR GOAL_FILE GOAL_SLUG GOAL_TITLE AGENT_NAME; do
    unset "$_k" 2>/dev/null || true
  done
}
_reset_env_keys
_derive_hook_env "after_goal" "tasks/some-slug.md" ""

# THE POSITIVE CONTROLS. Without these, "GOAL_DIR is empty" cannot tell a
# cleared branch apart from a path that never resolved at all -- and the first
# version of this block could not, which is exactly how it passed while covering
# nothing.
assert_eq "the loose task file itself resolves" "${TASK_FILE:-}" "$PROJECT_DIR/tasks/some-slug.md"
assert_eq "the loose task's title is read from it" "${TASK_TITLE:-}" "A standalone task"
assert_eq "a loose task leaves GOAL_DIR empty" "${GOAL_DIR:-}" ""
assert_eq "a loose task leaves GOAL_FILE empty" "${GOAL_FILE:-}" ""
assert_eq "a loose task leaves GOAL_TITLE empty" "${GOAL_TITLE:-}" ""
assert_eq "a loose task leaves GOAL_SLUG empty" "${GOAL_SLUG:-}" ""

# The other side of the branch: an identical shape WITH a sibling goal.md must
# populate the goal keys. Without this the cleared-keys assertions above would
# still pass against a function that never populates them for anyone.
WITHGOAL_DIR="$SANDBOX/withgoal"
mkdir -p "$WITHGOAL_DIR/tasks"
printf '# The Goal\n' > "$WITHGOAL_DIR/tasks/goal.md"
printf '# A sibling task\n' > "$WITHGOAL_DIR/tasks/task1.md"
PROJECT_DIR="$(cd "$WITHGOAL_DIR" && pwd -P)"
_PROJECT_ABS="$PROJECT_DIR"
_reset_env_keys
_derive_hook_env "after_goal" "tasks/goal.md" ""
assert_eq "a task beside a goal.md populates GOAL_FILE" "${GOAL_FILE:-}" "$PROJECT_DIR/tasks/goal.md"
assert_eq "a task beside a goal.md populates GOAL_TITLE" "${GOAL_TITLE:-}" "The Goal"
assert_eq "a task beside a goal.md populates GOAL_SLUG" "${GOAL_SLUG:-}" "tasks"
assert_eq "a task beside a goal.md populates GOAL_DIR" "${GOAL_DIR:-}" "$PROJECT_DIR/tasks"
# Every key is still DEFINED even when empty, which is the contract: a consumer
# reading $GOAL_DIR must get an empty string, never an unbound-variable error.
# Read the key list out of the script's own call sites rather than restating it.
# A tenth key added to the hook would otherwise leave this case silently
# checking the old nine and reporting a pass.
DERIVED_KEYS=$(grep -oE '_export_env_kv +[A-Z_]+' "$HOOK_SH" | awk '{print $2}' | sort -u)
assert_eq "the hook exports nine keys" "$(printf '%s\n' "$DERIVED_KEYS" | grep -c .)" "9"
_UNDEF=""
for _k in $DERIVED_KEYS; do
  eval "[ \"\${$_k+set}\" = set ]" || _UNDEF="$_UNDEF [$_k]"
done
assert_eq "every exported key is defined even when empty" "$_UNDEF" ""

# ---------------------------------------------------------------------------
# Main flow — the guards no fixture reaches
#
# These run the script as a real subprocess, which is the only way to reach
# them. They do not overlap test/smoke.sh: it always passes a phase, always
# pipes a payload, and every one of its fixture projects has a .stride_lite.md.
# ---------------------------------------------------------------------------
echo ""
echo "main flow — the early guards"

MAIN_DIR="$SANDBOX/main-guards"
mkdir -p "$MAIN_DIR/.stride-lite"
printf '## before_task\n\n```bash\necho should-not-run\n```\n' > "$MAIN_DIR/.stride_lite.md"
printf '{"session_id":"t","started_at":"%s","pid":1}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  > "$MAIN_DIR/.stride-lite/.orchestrator_active"
PAYLOAD='{"tool_name":"Agent","tool_input":{"subagent_type":"stride-lite:task-explorer","prompt":"x"}}'

OUT=$(printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$MAIN_DIR" bash "$HOOK_SH" 2>&1); RC=$?
assert_eq "no phase argument exits 0" "$RC" "0"
assert_eq "no phase argument runs nothing" "$OUT" ""

OUT=$(printf '' | CLAUDE_PROJECT_DIR="$MAIN_DIR" bash "$HOOK_SH" pre 2>&1); RC=$?
assert_eq "empty stdin exits 0" "$RC" "0"
assert_eq "empty stdin runs nothing" "$OUT" ""

NOMD_DIR="$SANDBOX/main-no-md"
mkdir -p "$NOMD_DIR/.stride-lite"
printf '{"session_id":"t","started_at":"%s","pid":1}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  > "$NOMD_DIR/.stride-lite/.orchestrator_active"
OUT=$(printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$NOMD_DIR" bash "$HOOK_SH" pre 2>&1); RC=$?
assert_eq "a missing .stride_lite.md exits 0" "$RC" "0"
assert_eq "a missing .stride_lite.md runs nothing" "$OUT" ""

# A sandbox path containing a space is a listed edge case, and an unquoted
# expansion anywhere in the path handling would surface here and nowhere else.
SPACE_DIR="$SANDBOX/dir with spaces"
mkdir -p "$SPACE_DIR/.stride-lite"
printf '## before_task\n\n```bash\necho ran-in-spaced-dir\n```\n' > "$SPACE_DIR/.stride_lite.md"
printf '{"session_id":"t","started_at":"%s","pid":1}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  > "$SPACE_DIR/.stride-lite/.orchestrator_active"
ERR_F="$SANDBOX/.spaced-err"
OUT=$(printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$SPACE_DIR" bash "$HOOK_SH" pre 2>"$ERR_F"); RC=$?
assert_eq "a project path containing spaces exits 0" "$RC" "0"
assert_has "a project path containing spaces still runs the section" "$(cat "$ERR_F")" "ran-in-spaced-dir"
assert_has "a project path containing spaces emits success JSON" "$OUT" '"status":"success"'

# CRLF line endings are a listed edge case: a .stride_lite.md authored on
# Windows must still parse, or the whole hook layer silently no-ops there.
CRLF_DIR="$SANDBOX/crlf"
mkdir -p "$CRLF_DIR/.stride-lite"
printf '## before_task\r\n\r\n```bash\r\necho ran-under-crlf\r\n```\r\n' > "$CRLF_DIR/.stride_lite.md"
printf '{"session_id":"t","started_at":"%s","pid":1}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  > "$CRLF_DIR/.stride-lite/.orchestrator_active"
ERR_F="$SANDBOX/.crlf-err"
OUT=$(printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$CRLF_DIR" bash "$HOOK_SH" pre 2>"$ERR_F"); RC=$?
assert_eq "a CRLF .stride_lite.md exits 0" "$RC" "0"
assert_has "a CRLF .stride_lite.md still runs the section" "$(cat "$ERR_F")" "ran-under-crlf"

# ---------------------------------------------------------------------------
# _marker_is_fresh — called directly
#
# test/smoke.sh covers every marker STATE through the subprocess, which is the
# behaviour that matters. What it cannot show is the function's own return
# code, and a suppressed hook and a fresh-but-empty section look identical from
# outside. These call the function, so the return code is the assertion.
#
# The sandbox is used as the project root throughout: a marker written into the
# real project directory would arm hooks for any concurrent session.
# ---------------------------------------------------------------------------
echo ""
echo "_marker_is_fresh — return codes"

MARKER_DIR="$SANDBOX/marker-fn"
mkdir -p "$MARKER_DIR/.stride-lite"
PROJECT_DIR="$MARKER_DIR"
STRIDE_LITE_ALLOW_DIRECT=""

_write_marker() { printf '{"session_id":"t","started_at":"%s","pid":1}\n' "$1" > "$MARKER_DIR/.stride-lite/.orchestrator_active"; }
_now_iso()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
_ago_iso()  { # $1 = seconds ago, portable across GNU and BSD date
  local _n; _n=$(date -u +%s)
  local _t=$(( _n - $1 ))
  date -u -r "$_t" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$_t" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

rm -f "$MARKER_DIR/.stride-lite/.orchestrator_active"
if _marker_is_fresh; then nope "a missing marker returns non-zero" "return 1" "return 0"; else ok "a missing marker returns non-zero"; fi

_write_marker "$(_now_iso)"
if _marker_is_fresh; then ok "a fresh marker returns zero"; else nope "a fresh marker returns zero" "return 0" "return 1"; fi

: > "$MARKER_DIR/.stride-lite/.orchestrator_active"
if _marker_is_fresh; then nope "an empty marker returns non-zero" "return 1" "return 0"; else ok "an empty marker returns non-zero"; fi

printf '{"session_id":"t","pid":1}\n' > "$MARKER_DIR/.stride-lite/.orchestrator_active"
if _marker_is_fresh; then nope "a marker with no started_at returns non-zero" "return 1" "return 0"; else ok "a marker with no started_at returns non-zero"; fi

_STALE=$(_ago_iso 18000)   # 5h, past the 4h window
if [ -n "$_STALE" ]; then
  _write_marker "$_STALE"
  if _marker_is_fresh; then nope "a stale marker returns non-zero" "return 1" "return 0"; else ok "a stale marker returns non-zero"; fi
else
  skip "a stale marker returns non-zero" "neither GNU nor BSD date could compute a past timestamp"
fi

# A future timestamp is a clock skew or a forged marker, and either way it is
# not evidence that a workflow is running now.
_FUTURE=$(_ago_iso -3600)
if [ -n "$_FUTURE" ]; then
  _write_marker "$_FUTURE"
  if _marker_is_fresh; then nope "a future-dated marker returns non-zero" "return 1" "return 0"; else ok "a future-dated marker returns non-zero"; fi
else
  skip "a future-dated marker returns non-zero" "neither GNU nor BSD date could compute a future timestamp"
fi

# The override bypasses the gate entirely, and only the exact value 1 does.
rm -f "$MARKER_DIR/.stride-lite/.orchestrator_active"
STRIDE_LITE_ALLOW_DIRECT=1
if _marker_is_fresh; then ok "the override bypasses a missing marker"; else nope "the override bypasses a missing marker" "return 0" "return 1"; fi
STRIDE_LITE_ALLOW_DIRECT=0
if _marker_is_fresh; then nope "the override set to 0 does not bypass" "return 1" "return 0"; else ok "the override set to 0 does not bypass"; fi
STRIDE_LITE_ALLOW_DIRECT=""

# ---------------------------------------------------------------------------
# Cross-platform parity — the same fixtures through both executors
#
# There is no stride precedent to copy here: stride's .ps1 suites are separate
# rather than comparative. The design is to run one fixture set through
# run_stride_lite_section and through Invoke-StrideLiteSection, normalize, and
# compare the emitted JSON.
#
# The .ps1 cannot be driven end-to-end -- @($input) is empty for an OS-level
# pipe (D215) -- so the PowerShell side dot-sources the function via AST
# extraction and calls it directly, the technique test/smoke.sh already uses for
# the derivation helpers. That defect blocks a full subprocess run; it does not
# block calling the function.
#
# Where PowerShell is absent this reports a SKIP with a reason, so an absent run
# is distinguishable from a passing one.
# ---------------------------------------------------------------------------
echo ""
echo "cross-platform parity (.sh vs .ps1)"

HOOK_PS1="$SCRIPT_DIR/stride-lite-hook.ps1"
PS_BIN=""
for _c in pwsh powershell; do command -v "$_c" >/dev/null 2>&1 && { PS_BIN="$_c"; break; }; done

if [ ! -f "$HOOK_PS1" ]; then
  nope "the .ps1 executor exists" "a file at hooks/stride-lite-hook.ps1" "missing"
elif [ -z "$PS_BIN" ]; then
  skip "parity: .sh and .ps1 emit equivalent JSON" "no pwsh or powershell on PATH"
  skip "parity: .sh and .ps1 agree on the failure shape" "no pwsh or powershell on PATH"
else
  PARITY_DIR="$SANDBOX/parity"
  mkdir -p "$PARITY_DIR"
  cat > "$PARITY_DIR/.stride_lite.md" <<'FIXTURE'
## before_task

```bash
true
true
```

## after_task

```bash
:
false
true
```
FIXTURE

  # The after_task fixture is deliberately ASYMMETRIC -- `:` then `false` then
  # `true`, so commands_completed is [":"] and commands_remaining is ["true"].
  # With `true / false / true` both arrays render as ["true"], and a byte-
  # identical compare cannot see an executor that reverses the partition.

  # --- bash side -----------------------------------------------------------
  _run_section "$PARITY_DIR" before_task
  SH_SUCCESS="$OUT"
  _run_section "$PARITY_DIR" after_task
  SH_FAILURE="$OUT"

  # --- PowerShell side -----------------------------------------------------
  # Extract Invoke-StrideLiteSection by AST and call it directly. smoke.sh's
  # harness explicitly EXCLUDES this function; including it here is the point.
  PS_HARNESS="$SANDBOX/parity-harness.ps1"
  cat > "$PS_HARNESS" <<'PSEOF'
param([string]$HookPs1, [string]$FixtureDir)
$ErrorActionPreference = 'Stop'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($HookPs1, [ref]$null, [ref]$null)
$fns = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
foreach ($f in $fns) { . ([scriptblock]::Create($f.Extent.Text)) }
# Free variables Invoke-StrideLiteSection closes over, set in this scope.
$script:StrideLiteMd = Join-Path $FixtureDir '.stride_lite.md'
$script:ProjectDir   = $FixtureDir
$StrideLiteMd = $script:StrideLiteMd
$ProjectDir   = $script:ProjectDir
# Invoke-StrideLiteSection emits its JSON with [Console]::Out.WriteLine, which
# bypasses the PowerShell pipeline entirely -- assigning the call to a variable
# captures the RETURN CODE, not the JSON. Write the delimiters the same way so
# they interleave correctly, and let the JSON land on process stdout.
[Console]::Out.WriteLine('---BEFORE---')
$null = Invoke-StrideLiteSection -Section 'before_task'
[Console]::Out.WriteLine('---AFTER---')
$null = Invoke-StrideLiteSection -Section 'after_task'
[Console]::Out.WriteLine('---END---')
PSEOF
  PS_OUT=$("$PS_BIN" -NoProfile -File "$PS_HARNESS" -HookPs1 "$HOOK_PS1" -FixtureDir "$PARITY_DIR" 2>&1 | tr -d '\r')
  PS_SUCCESS=$(printf '%s\n' "$PS_OUT" | sed -n '/^---BEFORE---$/,/^---AFTER---$/p' | sed '1d;$d' | grep '^{' || true)
  PS_FAILURE=$(printf '%s\n' "$PS_OUT" | sed -n '/^---AFTER---$/,/^---END---$/p' | sed '1d;$d' | grep '^{' || true)

  if [ -z "$PS_SUCCESS" ] && [ -z "$PS_FAILURE" ]; then
    # Do not let an empty harness result pass as agreement. Report it and say
    # what came back, so a harness that broke is distinguishable from parity.
    nope "the PowerShell harness produced output" "JSON from both sections" "$PS_OUT"
  else
    ok "the PowerShell harness produced output"

    # Compare the failure JSON WHOLE. Every field in it is deterministic --
    # there is no duration_seconds here -- and the three fields most likely to
    # diverge between two independent implementations are exactly the ones a
    # key-set comparison cannot see: commands_completed, commands_remaining and
    # failed_command. A key-set compare passes on an executor that reverses the
    # partition and names the wrong failing command.
    assert_eq "parity: the failure JSON is byte-identical" "$PS_FAILURE" "$SH_FAILURE"

    # The success JSON carries one measured field, so strip that field and
    # compare the rest whole. The measured value justifies excluding ONE field,
    # not falling back to key sets for the whole shape.
    _strip_duration() { printf '%s' "$1" | sed 's/,"duration_seconds":[0-9]*//; s/"duration_seconds":[0-9]*,//'; }
    assert_eq "parity: the success JSON matches apart from its measured duration" \
      "$(_strip_duration "$PS_SUCCESS")" "$(_strip_duration "$SH_SUCCESS")"
    # ...and the field that was excluded is still present on both sides, so the
    # strip cannot be hiding its absence from one of them.
    assert_has "parity: the .sh success JSON reports a duration" "$SH_SUCCESS" '"duration_seconds":'
    assert_has "parity: the .ps1 success JSON reports a duration" "$PS_SUCCESS" '"duration_seconds":'

    # --- A known divergence, recorded rather than hidden ------------------
    #
    # The two executors agree on the JSON above because every fixture command in
    # it is a single token. They do NOT agree on whether a MULTI-WORD command
    # runs at all: the .ps1 passes each command through
    # `Start-Process -ArgumentList '-c', $cmd`, which re-splits the argument, so
    # bash receives only the first token as its script. `echo x > f` creates no
    # file and the section still reports success.
    #
    # Filed as D218. Asserting the broken behaviour would cement it, and
    # asserting the correct behaviour would leave the suite permanently red, so
    # the divergence is proven once here and reported as a SKIP naming the
    # defect -- the same treatment D215 gets. When D218 is fixed this block
    # becomes a real parity assertion.
    DIVERGE_DIR="$SANDBOX/diverge"
    mkdir -p "$DIVERGE_DIR"
    # A RELATIVE target, deliberately. Interpolating the sandbox path into the
    # redirect meant a sandbox whose path contains a space split the command and
    # wrote OUTSIDE the sandbox. run_stride_lite_section cds to PROJECT_DIR
    # first, so a relative redirect is confined by construction and there is no
    # interpolation left to get wrong.
    printf '## before_task\n\n```bash\necho ran > proof.txt\n```\n' > "$DIVERGE_DIR/.stride_lite.md"
    rm -f "$DIVERGE_DIR/proof.txt"
    _run_section "$DIVERGE_DIR" before_task
    if [ -f "$DIVERGE_DIR/proof.txt" ]; then
      ok "the .sh executor runs a multi-word command"
    else
      nope "the .sh executor runs a multi-word command" "proof.txt created" "not created"
    fi
    rm -f "$DIVERGE_DIR/proof.txt"
    PS_DIV="$SANDBOX/diverge-harness.ps1"
    cat > "$PS_DIV" <<'PSEOF'
param([string]$HookPs1, [string]$FixtureDir)
$ast = [System.Management.Automation.Language.Parser]::ParseFile($HookPs1, [ref]$null, [ref]$null)
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
  . ([scriptblock]::Create($f.Extent.Text))
}
$StrideLiteMd = Join-Path $FixtureDir '.stride_lite.md'
$ProjectDir   = $FixtureDir
$null = Invoke-StrideLiteSection -Section 'before_task'
PSEOF
    "$PS_BIN" -NoProfile -File "$PS_DIV" -HookPs1 "$HOOK_PS1" -FixtureDir "$DIVERGE_DIR" >/dev/null 2>&1
    if [ -f "$DIVERGE_DIR/proof.txt" ]; then
      ok "the .ps1 executor runs a multi-word command (D218 appears fixed — turn this into a parity assertion)"
    else
      skip "parity: a multi-word command runs under both executors" \
           "D218 — the .ps1 re-splits the command through Start-Process, so only its first token reaches bash"
    fi
  fi
fi

# ---------------------------------------------------------------------------
echo ""
echo "------------------------------------------------------------------"
TOTAL=$((PASS + FAIL))
if [ "$SKIP" -gt 0 ]; then
  echo "$PASS passed, $FAIL failed, $SKIP skipped (out of $TOTAL run)"
else
  echo "$PASS passed, $FAIL failed (out of $TOTAL)"
fi
echo "------------------------------------------------------------------"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
