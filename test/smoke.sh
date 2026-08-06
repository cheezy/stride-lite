#!/usr/bin/env bash
# smoke.sh — Stride Lite lib/ helper smoke test.
#
# Exercises the four lib/ helpers (slugify, resolve_output_path,
# load_requirements_dir, parse_args) against known inputs and asserts the
# expected behavior. Pure bash + POSIX utilities — no test framework, no
# network, no external dependencies.
#
# The helper implementations below are byte-equivalent to the reference
# implementations in the corresponding lib/<name>.md spec files. If a spec
# changes, update this file in the same commit and bump the assertion count.
#
# Usage:
#   ./test/smoke.sh                # from the repo root
#   bash test/smoke.sh             # alternative invocation
#
# Exit codes:
#   0  all assertions passed
#   1  one or more assertions failed (count printed to stderr)

set -u  # NOT set -e — we want assertions to keep running after a failure

# Resolve repo root so the script works from any working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

ok() {
  PASS=$(( PASS + 1 ))
  echo "  PASS  $1"
}

nope() {
  FAIL=$(( FAIL + 1 ))
  echo "  FAIL  $1" >&2
  echo "        expected: $2" >&2
  echo "        actual:   $3" >&2
}

assert_eq() {
  local label="$1"
  local actual="$2"
  local expected="$3"
  if [ "$actual" = "$expected" ]; then
    ok "$label"
  else
    nope "$label" "$expected" "$actual"
  fi
}

# ------------------------------------------------------------------
# slugify — mirrors lib/slugify.md reference implementation
# ------------------------------------------------------------------

slugify() {
  local input="${1:-}"
  if [ -z "$input" ]; then
    echo "slugify: empty input" >&2
    return 1
  fi
  local lowered
  lowered="$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')"
  local replaced
  replaced="$(printf '%s' "$lowered" \
    | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-//; s/-$//')"
  if [ -z "$replaced" ]; then
    echo "slugify: slug normalized to empty string" >&2
    return 1
  fi
  printf '%s' "$replaced"
}

echo "slugify"
assert_eq "lowercases and dashes the prompt" \
  "$(slugify 'Add real-time notifications')" \
  'add-real-time-notifications'
assert_eq "collapses runs of dashes and trims" \
  "$(slugify '  Multiple   spaces & symbols!! ')" \
  'multiple-spaces-symbols'
assert_eq "numeric-only stays numeric-only" \
  "$(slugify '123')" \
  '123'
# Empty-input path returns non-zero — assert via exit code, not output.
if slugify '' >/dev/null 2>&1; then
  nope "rejects empty input" "non-zero exit" "exit 0"
else
  ok "rejects empty input"
fi

# ------------------------------------------------------------------
# resolve_output_path — mirrors lib/resolve_output_path.md
# ------------------------------------------------------------------

resolve_output_path() {
  local base_dir="${1:-}"
  local slug="${2:-}"
  local kind="${3:-}"
  local ext="${4:-}"
  if [ -z "$base_dir" ] || [ -z "$slug" ] || [ -z "$kind" ]; then
    echo "resolve_output_path: usage: resolve_output_path <base_dir> <slug> <dir|file> [<ext>]" >&2
    return 1
  fi
  if [ "$kind" != "dir" ] && [ "$kind" != "file" ]; then
    echo "resolve_output_path: kind must be 'dir' or 'file', got '$kind'" >&2
    return 1
  fi
  if [ "$kind" = "file" ] && [ -z "$ext" ]; then
    echo "resolve_output_path: ext is required when kind=file" >&2
    return 1
  fi

  local stripped="${base_dir%/}"
  local candidate
  if [ "$kind" = "dir" ]; then
    candidate="${stripped}/${slug}"
  else
    candidate="${stripped}/${slug}.${ext}"
  fi
  if [ ! -e "$candidate" ]; then
    printf '%s' "$candidate"
    return 0
  fi

  local n=2
  while :; do
    if [ "$kind" = "dir" ]; then
      candidate="${stripped}/${slug}-${n}"
    else
      candidate="${stripped}/${slug}-${n}.${ext}"
    fi
    if [ ! -e "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
    n=$(( n + 1 ))
    if [ "$n" -gt 1000 ]; then
      echo "resolve_output_path: refusing to scan past -1000 collisions" >&2
      return 2
    fi
  done
}

echo ""
echo "resolve_output_path"
# Create a sandbox under /tmp so we can simulate collisions safely.
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

assert_eq "returns the base path when nothing exists" \
  "$(resolve_output_path "$SANDBOX" 'add-notifs' dir)" \
  "$SANDBOX/add-notifs"

# Now create the directory and confirm we get -2.
mkdir -p "$SANDBOX/add-notifs"
assert_eq "appends -2 on first collision (dir)" \
  "$(resolve_output_path "$SANDBOX" 'add-notifs' dir)" \
  "$SANDBOX/add-notifs-2"

mkdir -p "$SANDBOX/add-notifs-2"
assert_eq "appends -3 on second collision (dir)" \
  "$(resolve_output_path "$SANDBOX" 'add-notifs' dir)" \
  "$SANDBOX/add-notifs-3"

# File-mode path.
assert_eq "returns base path for file mode" \
  "$(resolve_output_path "$SANDBOX" 'fix-typo' file md)" \
  "$SANDBOX/fix-typo.md"

touch "$SANDBOX/fix-typo.md"
assert_eq "appends -2 on first collision (file)" \
  "$(resolve_output_path "$SANDBOX" 'fix-typo' file md)" \
  "$SANDBOX/fix-typo-2.md"

# Caller-supplied base dir is honored (not hardcoded).
ALT_BASE="$SANDBOX/alt"
mkdir -p "$ALT_BASE"
assert_eq "honors caller-supplied base directory" \
  "$(resolve_output_path "$ALT_BASE" 'foo' dir)" \
  "$ALT_BASE/foo"

# ------------------------------------------------------------------
# load_requirements_dir — mirrors lib/load_requirements_dir.md
# ------------------------------------------------------------------

load_requirements_dir() {
  local dir="${1:-}"
  if [ -z "$dir" ]; then
    echo "load_requirements_dir: usage: load_requirements_dir <dir>" >&2
    return 0
  fi
  if [ ! -d "$dir" ]; then
    echo "load_requirements_dir: directory not found: $dir" >&2
    return 0
  fi

  local stripped="${dir%/}"
  local file rel

  find -L "$stripped" -type f -not -path '*/.*' 2>/dev/null \
    | sort \
    | while IFS= read -r file; do
        rel="${file#${stripped}/}"

        local size
        size="$(wc -c < "$file" 2>/dev/null | tr -d '[:space:]')"
        if [ -n "$size" ] && [ "$size" -gt 1048576 ]; then
          echo "load_requirements_dir: skipping (>1MiB): $rel" >&2
          continue
        fi

        local raw_bytes stripped_bytes
        raw_bytes="$(head -c 8192 "$file" 2>/dev/null | wc -c | tr -d '[:space:]')"
        stripped_bytes="$(head -c 8192 "$file" 2>/dev/null | LC_ALL=C tr -d '\0' | wc -c | tr -d '[:space:]')"
        if [ "${raw_bytes:-0}" -ne "${stripped_bytes:-0}" ]; then
          echo "load_requirements_dir: skipping (binary): $rel" >&2
          continue
        fi

        printf '=== %s ===\n\n' "$rel"
        cat "$file"
        if [ -n "$(tail -c 1 "$file" 2>/dev/null)" ]; then
          printf '\n'
        fi
        printf '\n'
      done
}

echo ""
echo "load_requirements_dir"

# Missing dir is non-fatal and returns empty stdout.
MISSING_OUTPUT="$(load_requirements_dir "$SANDBOX/does-not-exist" 2>/dev/null)"
assert_eq "missing directory yields empty stdout" \
  "$MISSING_OUTPUT" \
  ""

# Sample-requirements fixture: confirm load picks up the file and emits the header.
FIXTURE_DIR="$REPO_ROOT/fixtures"
FIXTURE_OUTPUT="$(load_requirements_dir "$FIXTURE_DIR" 2>/dev/null)"
# Crude check — should contain the sample-requirements.md header marker.
if printf '%s' "$FIXTURE_OUTPUT" | grep -q '=== sample-requirements.md ==='; then
  ok "reads fixtures/sample-requirements.md and emits header"
else
  nope "reads fixtures/sample-requirements.md and emits header" \
    "output contains '=== sample-requirements.md ==='" \
    "header not found in output"
fi

# Sort order check — create a temp dir with two files and ensure the alphabetically-first one is emitted first.
SORT_DIR="$(mktemp -d -p "$SANDBOX")"
printf 'BBB\n' > "$SORT_DIR/b.md"
printf 'AAA\n' > "$SORT_DIR/a.md"
SORT_OUTPUT="$(load_requirements_dir "$SORT_DIR" 2>/dev/null)"
# 'a.md' header should appear before 'b.md' header in the output.
A_LINE=$(printf '%s' "$SORT_OUTPUT" | grep -n '=== a.md ===' | head -1 | cut -d: -f1)
B_LINE=$(printf '%s' "$SORT_OUTPUT" | grep -n '=== b.md ===' | head -1 | cut -d: -f1)
if [ -n "$A_LINE" ] && [ -n "$B_LINE" ] && [ "$A_LINE" -lt "$B_LINE" ]; then
  ok "emits files in sorted-by-name order"
else
  nope "emits files in sorted-by-name order" \
    "a.md header line < b.md header line" \
    "a=$A_LINE b=$B_LINE"
fi

# ------------------------------------------------------------------
# parse_args — mirrors lib/parse_args.md
# ------------------------------------------------------------------

parse_args() {
  local requirements_dir="docs/requirements"
  local output_dir="docs/implementation/PENDING"
  local -a positional=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --requirements-dir)
        if [ $# -lt 2 ]; then
          echo "parse_args: --requirements-dir requires a value" >&2
          return 1
        fi
        requirements_dir="$2"
        shift 2
        ;;
      --output-dir)
        if [ $# -lt 2 ]; then
          echo "parse_args: --output-dir requires a value" >&2
          return 1
        fi
        output_dir="$2"
        shift 2
        ;;
      *)
        positional+=("$1")
        shift
        ;;
    esac
  done

  local prompt=""
  if [ "${#positional[@]}" -gt 0 ]; then
    prompt="${positional[*]}"
  fi

  if [ -z "$prompt" ]; then
    echo "parse_args: prompt is required (supply at least one positional argument)" >&2
    return 2
  fi

  printf 'PROMPT=%q\n' "$prompt"
  printf 'REQUIREMENTS_DIR=%q\n' "$requirements_dir"
  printf 'OUTPUT_DIR=%q\n' "$output_dir"
}

echo ""
echo "parse_args"

# Defaults case: prompt only, both flags should land on their documented defaults.
PROMPT="" REQUIREMENTS_DIR="" OUTPUT_DIR=""
eval "$(parse_args 'Add notifications' 2>/dev/null)"
assert_eq "extracts the prompt" "$PROMPT" "Add notifications"
assert_eq "defaults --requirements-dir to docs/requirements" "$REQUIREMENTS_DIR" "docs/requirements"
assert_eq "defaults --output-dir to docs/implementation/PENDING" "$OUTPUT_DIR" "docs/implementation/PENDING"

# --requirements-dir override.
PROMPT="" REQUIREMENTS_DIR="" OUTPUT_DIR=""
eval "$(parse_args --requirements-dir /tmp/reqs 'Add notifs' 2>/dev/null)"
assert_eq "honors --requirements-dir override" "$REQUIREMENTS_DIR" "/tmp/reqs"

# --output-dir override.
PROMPT="" REQUIREMENTS_DIR="" OUTPUT_DIR=""
eval "$(parse_args 'Add notifs' --output-dir build/goals 2>/dev/null)"
assert_eq "honors --output-dir override" "$OUTPUT_DIR" "build/goals"

# Empty argv: should fail.
if parse_args >/dev/null 2>&1; then
  nope "rejects empty argv" "non-zero exit" "exit 0"
else
  ok "rejects empty argv"
fi

# Flag without value: should fail.
if parse_args 'Hi' --requirements-dir >/dev/null 2>&1; then
  nope "rejects flag without value" "non-zero exit" "exit 0"
else
  ok "rejects flag without value"
fi

# ------------------------------------------------------------------
# stride-lite-init template — mirrors skills/stride-lite-init/SKILL.md
# ------------------------------------------------------------------
#
# This helper writes the canonical .stride_lite.md template documented in
# stride-lite/skills/stride-lite-init/SKILL.md to a caller-supplied target
# path. It must stay byte-equivalent to the template in the SKILL.md — if
# the SKILL.md changes, update this function in the same commit. That
# byte-equivalence is machine-enforced: the init-flow stage below extracts
# the canonical block from the SKILL.md and diffs it against this function's
# output, so drift fails the run instead of rotting silently.
write_stride_lite_template() {
  local target="${1:-}"
  if [ -z "$target" ]; then
    echo "write_stride_lite_template: usage: write_stride_lite_template <target>" >&2
    return 1
  fi
  mkdir -p "$(dirname "$target")"
  cat > "$target" <<'TEMPLATE'
# Stride Lite Configuration

This file is created by `/stride-lite:init`. Fill in the fields below.

**Note (v0.9.0+):** The hook sections are executed automatically by the Claude Code harness via the plugin's `hooks.json` at the corresponding lifecycle points (`before_task` before each task-explorer dispatch and `after_task` before each task-reviewer dispatch, both blocking — exit 2 stops the dispatch; `after_goal` after the goal-level Completion Summary is written, advisory). The format mirrors the full Stride plugin's `.stride.md` so your snippets transfer across plugins. Each hook command also receives the task/goal context as environment variables — `HOOK_NAME`, `TASK_FILE`, `TASK_NUMBER`, `TASK_TITLE`, `GOAL_DIR`, `GOAL_FILE`, `GOAL_SLUG`, `GOAL_TITLE` and `AGENT_NAME` — each exported as the empty string when it cannot be derived.

## email

your-email@example.com

## before_task

```bash
```

## after_task

```bash
# Available here: HOOK_NAME TASK_FILE TASK_NUMBER TASK_TITLE GOAL_DIR GOAL_FILE GOAL_SLUG GOAL_TITLE AGENT_NAME
# echo "Finished task $TASK_NUMBER of $GOAL_SLUG: $TASK_TITLE"
```

## after_goal

```bash
```
TEMPLATE
}

echo ""
echo "stride-lite-init template"

# Sandbox subdir for the init flow. $SANDBOX is the mktemp -d from earlier in
# the file; the EXIT trap cleans the whole tree.
INIT_DIR="$SANDBOX/init-flow"
INIT_TARGET="$INIT_DIR/.stride_lite.md"
write_stride_lite_template "$INIT_TARGET"

# Assertion 1: the file was written.
if [ -f "$INIT_TARGET" ]; then
  ok "writes .stride_lite.md to the target path"
else
  nope "writes .stride_lite.md to the target path" "file exists" "missing"
fi

# Assertion 1b: byte-parity with the canonical template in the init SKILL.md.
# The canonical block is delimited by the file's only quadruple-backtick fence
# pair (```` ````markdown ```` ... ```` ```` ````); extract it exclusive of the
# fences and diff against the rendered output above.
CANONICAL_TEMPLATE="$INIT_DIR/canonical-template.md"
awk 'in_block && /^````$/ {exit} in_block {print} /^````markdown$/ {in_block=1}' \
  "$REPO_ROOT/skills/stride-lite-init/SKILL.md" > "$CANONICAL_TEMPLATE"
if TEMPLATE_DIFF="$(diff -u "$CANONICAL_TEMPLATE" "$INIT_TARGET" 2>&1)"; then
  ok "embedded template is byte-identical to init SKILL.md canonical block"
else
  nope "embedded template is byte-identical to init SKILL.md canonical block" \
    "empty diff against SKILL.md canonical block" \
    "$TEMPLATE_DIFF"
fi

# Assertion 2: the email section is present.
if grep -qE '^## email$' "$INIT_TARGET"; then
  ok "template contains ## email section"
else
  nope "template contains ## email section" "## email header line" "not found"
fi

# Assertion 3: the three hook sections appear in the exact required order.
BEFORE_LINE=$(grep -nE '^## before_task$' "$INIT_TARGET" | head -1 | cut -d: -f1)
AFTER_LINE=$(grep -nE '^## after_task$' "$INIT_TARGET" | head -1 | cut -d: -f1)
GOAL_LINE=$(grep -nE '^## after_goal$' "$INIT_TARGET" | head -1 | cut -d: -f1)
if [ -n "$BEFORE_LINE" ] && [ -n "$AFTER_LINE" ] && [ -n "$GOAL_LINE" ] \
   && [ "$BEFORE_LINE" -lt "$AFTER_LINE" ] && [ "$AFTER_LINE" -lt "$GOAL_LINE" ]; then
  ok "before_task < after_task < after_goal in the template"
else
  nope "before_task < after_task < after_goal in the template" \
    "all three present and ordered" \
    "before=$BEFORE_LINE after=$AFTER_LINE goal=$GOAL_LINE"
fi

# Assertion 4: collision detection precondition — [ -e ] returns true on the
# now-existing file, so the SKILL.md's clobber-refusal branch would fire on a
# second invocation without --force.
if [ -e "$INIT_TARGET" ]; then
  ok "collision check would refuse second write without --force"
else
  nope "collision check would refuse second write without --force" \
    "[ -e ] returns true on the existing file" "file not present"
fi

# ------------------------------------------------------------------
# hook routing (stride-lite-hook.sh)
# ------------------------------------------------------------------
#
# Feeds synthetic hook JSON payloads through hooks/stride-lite-hook.sh as a
# full subprocess (the same way the Claude Code harness invokes it via
# hooks.json) and asserts the routing + exit-code contract: before_task and
# after_task are blocking PreToolUse intercepts on the two Agent dispatches
# (a failing section exits 2), after_goal is an advisory PostToolUse
# intercept on the goal.md Completion Summary write (a failing section still
# exits 0), and non-matching payloads pass through with empty stdout. All
# fixture commands are inert (true/false) and confined to the sandbox via a
# per-invocation CLAUDE_PROJECT_DIR prefix — the hook resolves its config
# and runs sections there, never in the repo.

echo ""
echo "hook routing (stride-lite-hook.sh)"

HOOK_SH="$REPO_ROOT/hooks/stride-lite-hook.sh"
HOOK_PS1="$REPO_ROOT/hooks/stride-lite-hook.ps1"
HOOK_OUT=""
HOOK_ERR=""
HOOK_RC=0

# run_hook <phase> <project-dir> <payload-json> — sets HOOK_OUT / HOOK_ERR / HOOK_RC.
# printf '%s' only: the payloads carry literal \n escapes that echo would
# mangle. Stdout carries the JSON contract; stderr is captured separately
# because the hook mirrors each command's stdout to stderr on the success
# path, which is where the injected env values are observable.
run_hook() {
  local phase="$1" dir="$2" payload="$3"
  local errfile
  errfile="$(mktemp)"
  HOOK_OUT="$(printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$dir" bash "$HOOK_SH" "$phase" 2>"$errfile")"
  HOOK_RC=$?
  HOOK_ERR="$(cat "$errfile" 2>/dev/null)"
  rm -f "$errfile"
}

# assert_hook_out <label> <marker> — HOOK_OUT must contain the marker.
assert_hook_out() {
  local label="$1" marker="$2"
  case "$HOOK_OUT" in
    *"$marker"*) ok "$label" ;;
    *) nope "$label" "$marker in stdout" "$HOOK_OUT" ;;
  esac
}

# assert_hook_err <label> <marker> — HOOK_ERR must contain the marker.
assert_hook_err() {
  local label="$1" marker="$2"
  case "$HOOK_ERR" in
    *"$marker"*) ok "$label" ;;
    *) nope "$label" "$marker in stderr" "$HOOK_ERR" ;;
  esac
}

# refute_hook_err <label> <marker> — HOOK_ERR must NOT contain the marker.
refute_hook_err() {
  local label="$1" marker="$2"
  case "$HOOK_ERR" in
    *"$marker"*) nope "$label" "$marker absent from stderr" "$HOOK_ERR" ;;
    *) ok "$label" ;;
  esac
}

# Two fixture configs: every section succeeds vs. blocking/advisory sections fail.
HOOK_PASS_DIR="$SANDBOX/hook-pass"
mkdir -p "$HOOK_PASS_DIR"
cat > "$HOOK_PASS_DIR/.stride_lite.md" <<'CONFIG'
## email

hook-fixture@example.com

## before_task

```bash
true
```

## after_task

```bash
true
```

## after_goal

```bash
true
```
CONFIG

HOOK_FAIL_DIR="$SANDBOX/hook-fail"
mkdir -p "$HOOK_FAIL_DIR"
cat > "$HOOK_FAIL_DIR/.stride_lite.md" <<'CONFIG'
## email

hook-fixture@example.com

## before_task

```bash
false
```

## after_task

```bash
```

## after_goal

```bash
false
```
CONFIG

EXPLORER_PAYLOAD='{"tool_name":"Agent","tool_input":{"subagent_type":"stride-lite:task-explorer","prompt":"Explore the task"}}'
REVIEWER_PAYLOAD='{"tool_name":"Agent","tool_input":{"subagent_type":"stride-lite:task-reviewer","prompt":"Review the task"}}'
GOAL_WRITE_PAYLOAD='{"tool_name":"Write","tool_input":{"file_path":"docs/implementation/PENDING/add-notifs/goal.md","content":"# Goal\n\n## Completion Summary\n\nAll tasks done."}}'

# Routing path 1: explorer dispatch fires before_task (blocking, success).
run_hook pre "$HOOK_PASS_DIR" "$EXPLORER_PAYLOAD"
assert_eq "explorer dispatch exits 0 when before_task succeeds" "$HOOK_RC" "0"
assert_hook_out "explorer dispatch emits before_task success JSON" '"hook":"before_task","status":"success"'

# Routing path 2: reviewer dispatch fires after_task (blocking, success).
run_hook pre "$HOOK_PASS_DIR" "$REVIEWER_PAYLOAD"
assert_eq "reviewer dispatch exits 0 when after_task succeeds" "$HOOK_RC" "0"
assert_hook_out "reviewer dispatch emits after_task success JSON" '"hook":"after_task","status":"success"'

# Routing path 3: goal.md write with Completion Summary fires after_goal.
run_hook post "$HOOK_PASS_DIR" "$GOAL_WRITE_PAYLOAD"
assert_eq "completion-summary write exits 0 when after_goal succeeds" "$HOOK_RC" "0"
assert_hook_out "completion-summary write emits after_goal success JSON" '"hook":"after_goal","status":"success"'

# Routing path 4: non-matching Agent dispatch passes through untouched.
run_hook pre "$HOOK_PASS_DIR" '{"tool_name":"Agent","tool_input":{"subagent_type":"general-purpose","prompt":"unrelated dispatch"}}'
assert_eq "non-matching subagent_type exits 0" "$HOOK_RC" "0"
assert_eq "non-matching subagent_type fires nothing (empty stdout)" "$HOOK_OUT" ""

# Edge case: payload with no subagent_type field at all.
run_hook pre "$HOOK_PASS_DIR" '{"tool_name":"Agent","tool_input":{"prompt":"no subagent field"}}'
assert_eq "missing subagent_type exits 0" "$HOOK_RC" "0"
assert_eq "missing subagent_type fires nothing (empty stdout)" "$HOOK_OUT" ""

# Edge case: goal.md write WITHOUT a Completion Summary must not fire.
run_hook post "$HOOK_PASS_DIR" '{"tool_name":"Write","tool_input":{"file_path":"docs/implementation/PENDING/add-notifs/goal.md","content":"# Goal\n\nStill in progress."}}'
assert_eq "goal.md write without Completion Summary exits 0" "$HOOK_RC" "0"
assert_eq "goal.md write without Completion Summary fires nothing (empty stdout)" "$HOOK_OUT" ""

# Path-filter check: Completion Summary in a non-goal.md file must not fire.
run_hook post "$HOOK_PASS_DIR" '{"tool_name":"Write","tool_input":{"file_path":"docs/notes.md","content":"## Completion Summary\n\nnot a goal file"}}'
assert_eq "non-goal.md path exits 0" "$HOOK_RC" "0"
assert_eq "non-goal.md path fires nothing (empty stdout)" "$HOOK_OUT" ""

# Blocking semantics: a failing before_task section exits 2 and blocks.
run_hook pre "$HOOK_FAIL_DIR" "$EXPLORER_PAYLOAD"
assert_eq "failing before_task section exits 2 (blocking)" "$HOOK_RC" "2"
assert_hook_out "failing before_task emits failure JSON" '"hook":"before_task","status":"failed"'

# Advisory semantics: a failing after_goal section still exits 0.
run_hook post "$HOOK_FAIL_DIR" "$GOAL_WRITE_PAYLOAD"
assert_eq "failing after_goal section exits 0 (advisory)" "$HOOK_RC" "0"
assert_hook_out "failing after_goal emits failure JSON" '"hook":"after_goal","status":"failed"'

# ------------------------------------------------------------------
# hook env injection (stride-lite-hook.sh)
# ------------------------------------------------------------------
#
# Asserts the derived environment block the hook exports into each
# .stride_lite.md command: the nine keys, their values for a real goal
# directory, the empty-string-when-underivable rule, project containment, and
# the inertness of a task title carrying shell metacharacters.
#
# The probe sections print each value bracketed as KEY=[value] so an empty
# value is assertable rather than merely absent. Those prints land on the
# hook's stderr (it mirrors each command's stdout there on the success path),
# which run_hook now captures into HOOK_ERR.
#
# They use ${KEY-<UNSET>} rather than $KEY so an UNSET key renders as
# KEY=[<UNSET>] and a set-but-empty one as KEY=[]. Without that the two are
# indistinguishable and the headline rule — defined-but-empty, never omitted —
# would survive a mutation that omits the export whenever the value is empty.
# `-` (not `:-`) is the unset-only default, and the hook relaxes `set -u`
# before the eval, so this is safe in the probe.

echo ""
echo "hook env injection (stride-lite-hook.sh)"

HOOK_ENV_DIR="$SANDBOX/hook-env"
ENV_GOAL_DIR="$HOOK_ENV_DIR/docs/implementation/PENDING/add-notifs"
ENV_EVIL_DIR="$HOOK_ENV_DIR/docs/implementation/PENDING/evil-goal"
ENV_OUTSIDE_DIR="$SANDBOX/outside-project/not-a-goal"
mkdir -p "$ENV_GOAL_DIR" "$ENV_EVIL_DIR" "$ENV_OUTSIDE_DIR"

printf '# Add notifications\n\nGoal body.\n'   > "$ENV_GOAL_DIR/goal.md"
printf '# Wire up the socket\n\nTask body.\n'  > "$ENV_GOAL_DIR/task1.md"
printf '# Evil goal\n\nGoal body.\n'           > "$ENV_EVIL_DIR/goal.md"
printf '# Outside the project\n'               > "$ENV_OUTSIDE_DIR/task1.md"

# Hostile heading: a quoted heredoc so the metacharacters land in the file
# literally. If the value were ever spliced into the command text rather than
# exported, $(id) would run and `touch` would create a marker in the project dir.
cat > "$ENV_EVIL_DIR/task2.md" <<'TASKMD'
# Add $(id) and `whoami`; touch pwned-marker

## Description

Fixture task whose title carries shell metacharacters.
TASKMD

cat > "$HOOK_ENV_DIR/.stride_lite.md" <<'CONFIG'
## email

hook-fixture@example.com

## before_task

```bash
printf 'HOOK_NAME=[%s] TASK_FILE=[%s] TASK_NUMBER=[%s] TASK_TITLE=[%s] GOAL_DIR=[%s] GOAL_FILE=[%s] GOAL_SLUG=[%s] GOAL_TITLE=[%s] AGENT_NAME=[%s]\n' "${HOOK_NAME-<UNSET>}" "${TASK_FILE-<UNSET>}" "${TASK_NUMBER-<UNSET>}" "${TASK_TITLE-<UNSET>}" "${GOAL_DIR-<UNSET>}" "${GOAL_FILE-<UNSET>}" "${GOAL_SLUG-<UNSET>}" "${GOAL_TITLE-<UNSET>}" "${AGENT_NAME-<UNSET>}"
```

## after_task

```bash
printf 'HOOK_NAME=[%s] TASK_TITLE=[%s] GOAL_SLUG=[%s] AGENT_NAME=[%s]\n' "${HOOK_NAME-<UNSET>}" "${TASK_TITLE-<UNSET>}" "${GOAL_SLUG-<UNSET>}" "${AGENT_NAME-<UNSET>}"
```

## after_goal

```bash
printf 'HOOK_NAME=[%s] TASK_FILE=[%s] TASK_NUMBER=[%s] TASK_TITLE=[%s] GOAL_SLUG=[%s] GOAL_TITLE=[%s] AGENT_NAME=[%s]\n' "${HOOK_NAME-<UNSET>}" "${TASK_FILE-<UNSET>}" "${TASK_NUMBER-<UNSET>}" "${TASK_TITLE-<UNSET>}" "${GOAL_SLUG-<UNSET>}" "${GOAL_TITLE-<UNSET>}" "${AGENT_NAME-<UNSET>}"
```
CONFIG

ENV_TASK_PAYLOAD='{"tool_name":"Agent","tool_input":{"subagent_type":"stride-lite:task-explorer","prompt":"docs/implementation/PENDING/add-notifs/task1.md"}}'
ENV_PROSE_PAYLOAD='{"tool_name":"Agent","tool_input":{"subagent_type":"stride-lite:task-reviewer","prompt":"Review docs/implementation/PENDING/add-notifs/task1.md against its acceptance criteria."}}'
ENV_EVIL_PAYLOAD='{"tool_name":"Agent","tool_input":{"subagent_type":"stride-lite:task-explorer","prompt":"docs/implementation/PENDING/evil-goal/task2.md"}}'
ENV_TRAVERSAL_PAYLOAD='{"tool_name":"Agent","tool_input":{"subagent_type":"stride-lite:task-explorer","prompt":"../outside-project/not-a-goal/task1.md"}}'
ENV_MISSING_PAYLOAD='{"tool_name":"Agent","tool_input":{"subagent_type":"stride-lite:task-explorer","prompt":"docs/implementation/PENDING/add-notifs/task9.md"}}'
ENV_GOAL_PAYLOAD='{"tool_name":"Write","tool_input":{"file_path":"docs/implementation/PENDING/add-notifs/goal.md","content":"# Add notifications\n\n## Completion Summary\n\nAll tasks done."}}'
ENV_ABS_PAYLOAD="$(printf '{"tool_name":"Agent","tool_input":{"subagent_type":"stride-lite:task-explorer","prompt":"%s"}}' "$ENV_GOAL_DIR/task1.md")"

# --- before_task against a real goal directory: all nine keys, real values ---
run_hook pre "$HOOK_ENV_DIR" "$ENV_TASK_PAYLOAD"
assert_eq "env probe before_task exits 0" "$HOOK_RC" "0"

ENV_MISSING_KEYS=""
for _key in HOOK_NAME TASK_FILE TASK_NUMBER TASK_TITLE GOAL_DIR GOAL_FILE GOAL_SLUG GOAL_TITLE AGENT_NAME; do
  case "$HOOK_ERR" in
    *"$_key=["*) ;;
    *) ENV_MISSING_KEYS="$ENV_MISSING_KEYS $_key" ;;
  esac
done
assert_eq "all nine env keys reach the executed command" "$ENV_MISSING_KEYS" ""

assert_hook_err "before_task exports HOOK_NAME"   'HOOK_NAME=[before_task]'
assert_hook_err "before_task exports TASK_NUMBER" 'TASK_NUMBER=[1]'
assert_hook_err "before_task exports TASK_TITLE"  'TASK_TITLE=[Wire up the socket]'
assert_hook_err "before_task exports GOAL_SLUG"   'GOAL_SLUG=[add-notifs]'
assert_hook_err "before_task exports GOAL_TITLE"  'GOAL_TITLE=[Add notifications]'
assert_hook_err "before_task exports AGENT_NAME"  'AGENT_NAME=[stride-lite:task-explorer]'
# The hook canonicalizes with `pwd -P`, so compare against the canonical form:
# on macOS $SANDBOX is under /var, which is a symlink to /private/var.
ENV_GOAL_DIR_REAL="$(cd "$ENV_GOAL_DIR" && pwd -P)"
assert_hook_err "TASK_FILE is the absolute task path" "TASK_FILE=[$ENV_GOAL_DIR_REAL/task1.md]"
assert_hook_err "GOAL_DIR is the absolute goal directory" "GOAL_DIR=[$ENV_GOAL_DIR_REAL]"
assert_hook_err "GOAL_FILE is the absolute goal.md path" "GOAL_FILE=[$ENV_GOAL_DIR_REAL/goal.md]"

# --- an absolute prompt path resolves identically to a relative one ---
run_hook pre "$HOOK_ENV_DIR" "$ENV_ABS_PAYLOAD"
assert_hook_err "absolute prompt path derives TASK_TITLE" 'TASK_TITLE=[Wire up the socket]'
assert_hook_err "absolute prompt path derives GOAL_SLUG"  'GOAL_SLUG=[add-notifs]'

# --- a prose prompt that merely mentions the path still resolves ---
run_hook pre "$HOOK_ENV_DIR" "$ENV_PROSE_PAYLOAD"
assert_hook_err "after_task exports HOOK_NAME"           'HOOK_NAME=[after_task]'
assert_hook_err "prose prompt still derives TASK_TITLE"  'TASK_TITLE=[Wire up the socket]'
assert_hook_err "after_task exports the reviewer as AGENT_NAME" 'AGENT_NAME=[stride-lite:task-reviewer]'

# --- after_goal: goal keys populated, task keys and AGENT_NAME empty ---
run_hook post "$HOOK_ENV_DIR" "$ENV_GOAL_PAYLOAD"
assert_eq "env probe after_goal exits 0" "$HOOK_RC" "0"
assert_hook_err "after_goal exports HOOK_NAME"  'HOOK_NAME=[after_goal]'
assert_hook_err "after_goal exports GOAL_SLUG"  'GOAL_SLUG=[add-notifs]'
assert_hook_err "after_goal exports GOAL_TITLE" 'GOAL_TITLE=[Add notifications]'
assert_hook_err "after_goal leaves TASK_FILE empty"   'TASK_FILE=[]'
assert_hook_err "after_goal leaves TASK_NUMBER empty" 'TASK_NUMBER=[]'
assert_hook_err "after_goal leaves TASK_TITLE empty"  'TASK_TITLE=[]'
assert_hook_err "after_goal leaves AGENT_NAME empty"  'AGENT_NAME=[]'

# --- a metacharacter-bearing title is inert literal text ---
run_hook pre "$HOOK_ENV_DIR" "$ENV_EVIL_PAYLOAD"
assert_eq "metacharacter title does not fail the hook" "$HOOK_RC" "0"
assert_hook_out "metacharacter title still emits success JSON" '"hook":"before_task","status":"success"'
assert_hook_err "metacharacter title reaches the command verbatim" \
  'TASK_TITLE=[Add $(id) and `whoami`; touch pwned-marker]'
refute_hook_err "the \$(id) in a title did not execute" 'uid='
if [ ! -e "$HOOK_ENV_DIR/pwned-marker" ]; then
  ok "the '; touch' in a title did not execute"
else
  nope "the '; touch' in a title did not execute" "no pwned-marker file" "pwned-marker created"
fi

# --- a path resolving outside the project is refused, not followed ---
# This is also the undeterminable-branch half of the coverage target: every key
# except HOOK_NAME and AGENT_NAME (which are derived from the payload, not the
# file tree, and so are always available) must come back defined-but-empty.
run_hook pre "$HOOK_ENV_DIR" "$ENV_TRAVERSAL_PAYLOAD"
assert_eq "out-of-project path does not fail the hook" "$HOOK_RC" "0"
assert_hook_err "out-of-project path leaves TASK_FILE empty"   'TASK_FILE=[]'
assert_hook_err "out-of-project path leaves TASK_NUMBER empty" 'TASK_NUMBER=[]'
assert_hook_err "out-of-project path leaves TASK_TITLE empty"  'TASK_TITLE=[]'
assert_hook_err "out-of-project path leaves GOAL_DIR empty"    'GOAL_DIR=[]'
assert_hook_err "out-of-project path leaves GOAL_FILE empty"   'GOAL_FILE=[]'
assert_hook_err "out-of-project path leaves GOAL_SLUG empty"   'GOAL_SLUG=[]'
assert_hook_err "out-of-project path leaves GOAL_TITLE empty"  'GOAL_TITLE=[]'
assert_hook_err "out-of-project path still exports HOOK_NAME"  'HOOK_NAME=[before_task]'
assert_hook_err "out-of-project path still exports AGENT_NAME" 'AGENT_NAME=[stride-lite:task-explorer]'

# --- a task file with no single-# heading yields an empty title, not an error ---
printf 'No heading here.\n\n## Description\n\nBody.\n' > "$ENV_GOAL_DIR/task5.md"
run_hook pre "$HOOK_ENV_DIR" '{"tool_name":"Agent","tool_input":{"subagent_type":"stride-lite:task-explorer","prompt":"docs/implementation/PENDING/add-notifs/task5.md"}}'
assert_eq "headingless task file does not fail the hook" "$HOOK_RC" "0"
assert_hook_err "headingless task file leaves TASK_TITLE empty" 'TASK_TITLE=[]'
assert_hook_err "headingless task file still derives TASK_NUMBER" 'TASK_NUMBER=[5]'

# --- a missing file degrades to empty values without changing the exit code ---
run_hook pre "$HOOK_ENV_DIR" "$ENV_MISSING_PAYLOAD"
assert_eq "missing task file does not fail the hook" "$HOOK_RC" "0"
assert_hook_err "missing task file leaves TASK_FILE empty"  'TASK_FILE=[]'
assert_hook_err "missing task file leaves TASK_TITLE empty" 'TASK_TITLE=[]'

# --- an undeterminable prompt still exports every key, all empty ---
run_hook pre "$HOOK_ENV_DIR" "$EXPLORER_PAYLOAD"
assert_eq "undeterminable prompt does not fail the hook" "$HOOK_RC" "0"
assert_hook_err "undeterminable prompt still exports HOOK_NAME" 'HOOK_NAME=[before_task]'
assert_hook_err "undeterminable prompt leaves TASK_TITLE empty" 'TASK_TITLE=[]'
assert_hook_err "undeterminable prompt leaves GOAL_SLUG empty"  'GOAL_SLUG=[]'

# --- cross-platform parity, part 1: the .sh and .ps1 export the same key set ---
# Extracted from the real export call sites in both scripts, so the assertion
# cannot pass while an implementation drifts. This pins the KEY SET only —
# part 2 below covers the rules.
EXPECTED_ENV_KEYS="$(printf '%s\n' AGENT_NAME GOAL_DIR GOAL_FILE GOAL_SLUG GOAL_TITLE HOOK_NAME TASK_FILE TASK_NUMBER TASK_TITLE)"
SH_ENV_KEYS="$(grep -oE '_export_env_kv +[A-Z_]+' "$HOOK_SH" | awk '{print $2}' | sort -u)"
PS_ENV_KEYS="$(grep -oE "Set-StrideLiteEnvKv +-Key +'[A-Z_]+'" "$HOOK_PS1" \
  | grep -oE "'[A-Z_]+'" | tr -d "'" | sort -u)"
assert_eq "hook env key set is identical in .sh and .ps1" "$PS_ENV_KEYS" "$SH_ENV_KEYS"
assert_eq "hook env key set is the documented nine" "$SH_ENV_KEYS" "$EXPECTED_ENV_KEYS"

# --- cross-platform parity, part 2: the .ps1 obeys the same RULES ---
#
# The .ps1 cannot be driven end-to-end from here: it reads stdin via `@($input)`,
# which is empty for an OS-level pipe, so a piped payload never reaches it. That
# is a pre-existing defect (it reproduces identically on `git show HEAD:` of the
# script) and is out of scope for the env-injection work — but it means the
# routing stage above has no PowerShell counterpart.
#
# What IS reachable is the part this task added: the derivation functions. The
# harness below AST-extracts them from the real script — no copy of the logic
# lives here — and drives them through the same fixtures the .sh stage uses,
# asserting the same derived values, the same empty-on-underivable rule, the
# same project containment, and the same metacharacter inertness.
#
# Gated on PowerShell being present. When it is absent the suite records an
# explicit skip line rather than passing silently.

PS_PARITY_DIR="$SANDBOX/ps-parity"
mkdir -p "$PS_PARITY_DIR"
cat > "$PS_PARITY_DIR/harness.ps1" <<'PSHARNESS'
param([string]$ScriptPath, [string]$ProjDir)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The path-separator, comparison-mode and project-root setup is RE-DECLARED
# here rather than extracted — $ProjectAbs is the containment baseline and
# $PathComparison the Windows case-insensitivity rule, so these carry rules
# too and a change to them in the .ps1 would not reach this harness. The
# derivation functions below ARE extracted from the script itself.
$ProjectDir = $ProjDir
$PathSep = [System.IO.Path]::DirectorySeparatorChar
$PathComparison = if ($PathSep -eq '\') {
    [System.StringComparison]::OrdinalIgnoreCase
} else {
    [System.StringComparison]::Ordinal
}
$ProjectAbs = (Resolve-Path -LiteralPath $ProjectDir).ProviderPath.TrimEnd($PathSep)

$errs = $null; $toks = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$toks, [ref]$errs)
if ($errs.Count -gt 0) { [Console]::Error.WriteLine('parse errors'); exit 1 }
foreach ($f in $ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true)) {
    if ($f.Name -like '*StrideLite*' -and $f.Name -ne 'Invoke-StrideLiteSection') {
        . ([scriptblock]::Create($f.Extent.Text))
    }
}

$keys = 'HOOK_NAME','TASK_FILE','TASK_NUMBER','TASK_TITLE','GOAL_DIR','GOAL_FILE','GOAL_SLUG','GOAL_TITLE','AGENT_NAME'
$scenarios = @(
    @{ label = 'derived';   hook = 'before_task'; src = 'docs/implementation/PENDING/add-notifs/task1.md'; agent = 'stride-lite:task-explorer' },
    @{ label = 'traversal'; hook = 'before_task'; src = '../outside-project/not-a-goal/task1.md';         agent = 'stride-lite:task-explorer' },
    @{ label = 'missing';   hook = 'before_task'; src = 'docs/implementation/PENDING/add-notifs/task9.md'; agent = 'stride-lite:task-explorer' },
    @{ label = 'evil';      hook = 'before_task'; src = 'docs/implementation/PENDING/evil-goal/task2.md';  agent = 'stride-lite:task-explorer' },
    @{ label = 'goal';      hook = 'after_goal';  src = 'docs/implementation/PENDING/add-notifs/goal.md';  agent = '' }
)

foreach ($s in $scenarios) {
    # Seed every key with a sentinel rather than clearing it, so a key the
    # function fails to set reads back as <UNSET> while one it sets to the
    # empty string reads back as empty. That is the distinction the headline
    # rule is about — defined-but-empty, never omitted — and without it a
    # mutation that skips the export whenever the value is empty would slip
    # past the empty-branch assertions below.
    #
    # A sentinel and not $null: on .NET, SetEnvironmentVariable(name, $null)
    # followed by GetEnvironmentVariable returns the EMPTY STRING, not $null,
    # so a null-based check cannot tell the two apart (verified on pwsh 7).
    foreach ($k in $keys) { [System.Environment]::SetEnvironmentVariable($k, '<UNSET>', 'Process') }
    Set-StrideLiteHookEnv -Hook $s.hook -Source $s.src -Agent $s.agent
    $parts = foreach ($k in $keys) {
        "$k=[" + [System.Environment]::GetEnvironmentVariable($k, 'Process') + ']'
    }
    [Console]::Out.WriteLine($s.label + ' ' + ($parts -join ' '))
}
PSHARNESS

PS_BIN=""
if command -v pwsh > /dev/null 2>&1; then
  PS_BIN="pwsh"
elif command -v powershell > /dev/null 2>&1; then
  PS_BIN="powershell"
fi

if [ -z "$PS_BIN" ]; then
  echo "  SKIP  .ps1 rule parity: no pwsh/powershell on PATH (key-set parity above still ran)"
  echo "  SKIP  .ps1 end-to-end via hooks/stride-lite-hook.ps1: blocked by the pre-existing"
  echo "        @(\$input) stdin defect, which predates this change"
else
  PS_PARITY_OUT="$("$PS_BIN" -NoProfile -File "$PS_PARITY_DIR/harness.ps1" \
    -ScriptPath "$HOOK_PS1" -ProjDir "$HOOK_ENV_DIR" 2>/dev/null)"

  # assert_ps_parity <label> <scenario-prefix> <marker>
  assert_ps_parity() {
    local label="$1" prefix="$2" marker="$3" line
    line="$(printf '%s\n' "$PS_PARITY_OUT" | grep "^$prefix " 2>/dev/null)"
    case "$line" in
      *"$marker"*) ok "$label" ;;
      *) nope "$label" "$marker in the .ps1 '$prefix' scenario" "$line" ;;
    esac
  }

  assert_ps_parity ".ps1 derives TASK_NUMBER like the .sh"  derived   'TASK_NUMBER=[1]'
  assert_ps_parity ".ps1 derives TASK_TITLE like the .sh"   derived   'TASK_TITLE=[Wire up the socket]'
  assert_ps_parity ".ps1 derives GOAL_SLUG like the .sh"    derived   'GOAL_SLUG=[add-notifs]'
  assert_ps_parity ".ps1 derives GOAL_TITLE like the .sh"   derived   'GOAL_TITLE=[Add notifications]'
  assert_ps_parity ".ps1 derives AGENT_NAME like the .sh"   derived   'AGENT_NAME=[stride-lite:task-explorer]'
  assert_ps_parity ".ps1 refuses an out-of-project path"    traversal 'TASK_FILE=[]'
  assert_ps_parity ".ps1 empties GOAL_SLUG out of project"  traversal 'GOAL_SLUG=[]'
  assert_ps_parity ".ps1 still exports HOOK_NAME when underivable" traversal 'HOOK_NAME=[before_task]'
  assert_ps_parity ".ps1 empties a missing task file"       missing   'TASK_TITLE=[]'
  assert_ps_parity ".ps1 keeps a metacharacter title literal" evil \
    'TASK_TITLE=[Add $(id) and `whoami`; touch pwned-marker]'
  assert_ps_parity ".ps1 after_goal derives GOAL_SLUG"      goal      'GOAL_SLUG=[add-notifs]'
  assert_ps_parity ".ps1 after_goal empties TASK_FILE"      goal      'TASK_FILE=[]'
  assert_ps_parity ".ps1 after_goal empties AGENT_NAME"     goal      'AGENT_NAME=[]'

  echo "  SKIP  .ps1 end-to-end via hooks/stride-lite-hook.ps1: blocked by the pre-existing"
  echo "        @(\$input) stdin defect, which predates this change"
fi

# --- the workflow SKILL.md documents every key it exports ---
ENV_UNDOCUMENTED=""
for _key in $EXPECTED_ENV_KEYS; do
  if ! grep -q "$_key" "$REPO_ROOT/skills/stride-lite-workflow/SKILL.md"; then
    ENV_UNDOCUMENTED="$ENV_UNDOCUMENTED $_key"
  fi
done
assert_eq "every exported key is documented in the workflow SKILL.md" "$ENV_UNDOCUMENTED" ""

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------

echo ""
echo "------------------------------------------------------------------"
echo "$PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

exit 0
