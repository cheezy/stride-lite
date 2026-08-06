---
name: stride-lite-workflow
description: |
  Activate ONLY when the user explicitly states intent to work on a stride-lite goal (e.g., "work this goal", "drive the X goal to completion", "process all tasks in <path>", "resume the X goal") AND supplies a path to a goal directory (either inline in the same turn, or as a follow-up answer to a clarifying question from the agent). Without BOTH the intent statement AND the path, do not activate — the user might want one-off work on a single task, manual inspection, or some other unrelated operation. Once activated, the skill drives the goal through its full eight-step lifecycle for every taskN.md in numeric order: select the next incomplete task → `## before_task` hook (auto-fired by hooks/hooks.json pre-explorer-dispatch) → dispatch `stride-lite:task-explorer` to enrich the task with codebase context → implement the code changes per the task's acceptance criteria → `## after_task` hook (auto-fired pre-reviewer-dispatch) → dispatch `stride-lite:task-reviewer` to validate the diff → if review approved proceed, else loop back to coding (cap: 3 iterations) → write a `## Completion Summary` to the task file → advance to the next taskN.md. The skill exits cleanly ONLY after the final task's Completion Summary is written, `goal.md` has its Completion Summary appended, and the `## after_goal` hook has auto-fired (PostToolUse on the goal.md Edit/Write). Do not re-enter the loop after exit; subsequent goals require a fresh activation with a new path. The skill is the file-based equivalent of the full Stride plugin's `stride-workflow` orchestrator: no API calls, no claim/complete server endpoints, no kanban authentication — only goal/task markdown files, the project-local `.stride_lite.md` hook file, and the two existing stride-lite subagents. Examples: <example>Context: User has run /stride-lite:create-goal and now wants to drive the resulting goal through implementation. user: "Work the docs/implementation/PENDING/add-real-time-notifications-for-board-comments goal." assistant: "Activating stride-lite-workflow with that path as goal_directory_path; the skill will iterate task1.md, task2.md, task3.md in order until every task and goal.md has a Completion Summary, then exit." <commentary>Both conditions are met in a single turn: explicit intent ("Work the X goal") + path supplied inline. The skill iterates every taskN.md and exits only after Step 8's final-task branch runs.</commentary></example> <example>Context: User states intent without a path. user: "Let's work on a stride-lite goal." assistant: "Which goal directory? Please give me the path (e.g., docs/implementation/PENDING/add-notifications/)." <commentary>Intent without a path — do NOT activate yet. Ask for the path; activate only when the user supplies it.</commentary></example> <example>Context: User wants to resume a partially-completed goal where task1.md is already done. user: "Resume the add-notifications goal at docs/implementation/PENDING/add-notifications/" assistant: "Activating stride-lite-workflow. The first task already has a ## Completion Summary section, so the skill will pick up at task2.md and continue until every remaining task and goal.md is wrapped up, then exit." <commentary>The 'next task' rule is 'first taskN.md without ## Completion Summary' — partial-run resumption works automatically. Exit still happens only after the final-task branch fires.</commentary></example> <example>Context: User asks for a single task. user: "Implement task3.md in the add-notifications goal." assistant: "That's a single-task request — I'll do it manually rather than activating stride-lite-workflow, which is for full-goal drives. Want me to use the workflow on the full goal instead?" <commentary>Single-task requests do NOT match the activation contract (the workflow always iterates the full remaining set and runs the goal close-out). Do the work manually or confirm a full-goal drive.</commentary></example>
skills_version: "1.0"
---

# stride-lite-workflow

The file-based equivalent of `stride:stride-workflow`. Walks a stride-lite goal directory through the eight-step task lifecycle: select next task → before_task hook → explorer → implementation → after_task hook → reviewer → review-loop → completion summary → (on final task) goal completion summary + after_goal hook. No API calls, no kanban server interaction, no auth — the goal/task markdown files plus the project-local `.stride_lite.md` hook file are the entire surface.

## When to invoke

### Activation contract

Activate the skill if and ONLY if **both** conditions are met:

1. **Explicit intent.** The user states they want to work on a goal — e.g., "work this goal", "drive the X goal to completion", "process all tasks in <path>", "resume the X goal", "implement the add-notifications goal". Hedged or ambiguous phrasing ("could you look at...", "what's in this directory?", "show me task3") does **not** satisfy the intent condition.
2. **Path supplied.** The user provides a path to a goal directory — either inline in the same turn, or as a follow-up answer to a clarifying question from the agent. The path must point at a directory that contains `goal.md` plus at least one `task1.md`.

If intent is present but the path is missing, ask for the path; do NOT activate yet. If a path is present but intent is missing (e.g., the user just pastes a path with no instruction), ask what they want done with it; do NOT activate yet. Activate the moment both conditions are jointly satisfied.

### Termination contract

The skill exits **exactly once**, after all of these have happened:

1. Every `taskN.md` in the goal directory has a `## Completion Summary` section appended.
2. `goal.md` has its `## Completion Summary` appended.
3. The `## after_goal` hook has auto-fired (via PostToolUse on the goal.md Edit/Write) and the agent has either observed the structured success JSON or surfaced any failure JSON to the user.
4. The activation marker has been cleared.

Every abnormal termination clears the marker too — see [Orchestrator activation marker](#orchestrator-activation-marker). `rm -f` is idempotent, so clear unconditionally rather than reasoning about whether Step 0 ran.

After exit, do **not** re-enter the loop, do **not** start another goal, do **not** ask "should I work on another goal?". If the user wants another goal worked, they invoke the skill again with a different path. If the user wants the same goal re-run, that's an error — the skill detects "every taskN.md already has a Completion Summary" at Step 1 and stops cleanly with a "goal already complete" log line.

### What does NOT activate this skill

- Single-task requests (e.g., "implement task3.md") — do the work manually; the workflow always iterates the full remaining set.
- Goal-directory inspection requests (e.g., "what's in this goal?", "show me task1") — read the files directly; do not activate.
- Scaffolding requests (e.g., "create a goal for X") — those use `/stride-lite:create-goal` and `/stride-lite:create-task`.
- File-tree exploration with no stated intent — ask what the user wants before activating.

## Inputs

| Input | Type | Required | Default | Notes |
|---|---|---|---|---|
| `goal_directory_path` | string | yes | — | Path to a stride-lite goal directory (e.g., `docs/implementation/PENDING/<slug>/`). The directory must contain `goal.md` plus `task1.md`, `task2.md`, ... in sequential numeric order. |
| `max_review_iterations` | integer | no | `3` | Cap on the Step 7 review-loop. After this many consecutive `changes_requested` reviews, the skill surfaces the failing review and stops without writing the Completion Summary. |

## What this skill does NOT do

- **Never POSTs to any API.** stride-lite remains a "no network" plugin; the workflow surface adds hook execution and subagent dispatch but no network calls.
- **Never creates new task files.** Use `/stride-lite:create-goal` or `/stride-lite:create-task` to scaffold; the workflow consumes existing files only.
- **Never modifies the goal.md or taskN.md files** beyond the documented append-only mutations: appending `## Completion Summary` to the task file in Step 8, and appending `## Completion Summary` to goal.md on the final task. Everything above those appended sections stays byte-equivalent across runs.
- **Never executes non-hook Bash commands** outside the documented scope (see `## Bash scope` below).
- **Never amends the v0.6.0 task-explorer.md or v0.7.0 task-reviewer.md contracts.** The workflow consumes them as dispatchable agents via Claude Code's Agent tool — it does not retrofit their contracts.

## Orchestrator activation marker

The `.stride_lite.md` hooks fire from the Claude Code harness on tool calls — an `Agent` dispatch, an `Edit`/`Write` of `goal.md` — and those same tool calls happen when a user dispatches `stride-lite:task-explorer` by hand, outside any workflow. Nothing in the payload distinguishes the two. So this skill writes a marker while it is driving a goal, and the hook scripts run a section only when they find a fresh one.

| Field | Value |
|---|---|
| Path | `$CLAUDE_PROJECT_DIR/.stride-lite/.orchestrator_active` |
| Format | Single-line JSON: `{"session_id": "<id>", "started_at": "<ISO8601>", "pid": <pid>}`. `started_at` MUST be strict `YYYY-MM-DDTHH:MM:SSZ` — the three platforms' date parsers accept different supersets of ISO-8601, so only the canonical form reads identically everywhere |
| Lifecycle | Written in Step 0, cleared on **every** exit path — clean completion, review-cap stop, and every hard error |
| Freshness window | 4 hours — a marker older than `started_at + 4h` is treated as absent |
| Stale/malformed handling | The hook runs nothing and exits 0. It never blocks the dispatch |
| Directory | `.stride-lite/` is created with `mkdir -p` if absent |
| `.gitignore` | `.stride-lite/` belongs in the project's `.gitignore` — it is transient session state |
| Override | `STRIDE_LITE_ALLOW_DIRECT=1` bypasses the gate entirely (debugging and CI only) |

**Not `.stride/`.** That directory is the full Stride plugin's marker, and a project may have both plugins installed.

**A coordination mechanism, not a security boundary.** Any local process can write the file. It exists so the skill and the hook scripts agree on whether a workflow is running; never rely on it for authorization.

**Clearing is unconditional.** A marker left behind by a crashed run keeps hooks armed until the freshness window expires — up to 4 hours. The window bounds that exposure; clearing on every exit is what keeps it to seconds in practice. Wherever a step below says *stop*, clear the marker first:

```bash
STRIDE_LITE_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
rm -f "$STRIDE_LITE_ROOT/.stride-lite/.orchestrator_active"
```

`rm -f` on a path that does not exist is a no-op, so clear **unconditionally** rather than reasoning about whether Step 0 got as far as writing it.

**Resolve the project root the same way the hook does.** `CLAUDE_PROJECT_DIR` is not always set; the hook scripts fall back to `.`, so a marker written under a *different* root than the hook reads is the same as no marker at all — and because the gate fails silently, the symptom is that none of the user's hooks ever run, with nothing reported. Use the fallback above in both the write and the clear.

## The Eight-Step Loop

For each incomplete task in the goal directory (in numeric `taskN.md` order), walk these eight steps. On the final task, the workflow exits cleanly after Step 8 instead of looping. Step 0 runs once per goal drive, not once per task.

### Step 0 — Write the activation marker

Before the first agent dispatch — and before Step 1 reads anything — write the marker:

```bash
STRIDE_LITE_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
mkdir -p "$STRIDE_LITE_ROOT/.stride-lite"
printf '{"session_id":"%s","started_at":"%s","pid":%d}\n' \
  "${CLAUDE_SESSION_ID:-$(uuidgen 2>/dev/null || date +%s)}" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  "$$" \
  > "$STRIDE_LITE_ROOT/.stride-lite/.orchestrator_active"
test -f "$STRIDE_LITE_ROOT/.stride-lite/.orchestrator_active" \
  || echo "stride-lite: could not write the activation marker — hooks will not fire" >&2
```

**Verify the write landed.** A failed `mkdir` (an unset `CLAUDE_PROJECT_DIR` resolving to `/`, a read-only tree) otherwise disarms every hook for the whole goal drive with no signal at all — the gate's silence is a feature for standalone dispatches and a trap here. The `test -f` turns that into a visible warning.

Without it every `.stride_lite.md` hook silently no-ops and the user's `before_task` / `after_task` commands never run. **Run this once, at workflow entry** — re-writing it per task would refresh `started_at` and defeat the freshness window's purpose as a crash bound.

### Step 1 — Select the next task

Read the goal directory. Iterate `task1.md`, `task2.md`, `task3.md`, ... in strict numeric order. For each task file, check whether it contains a `## Completion Summary` section at the bottom of the file:

- If yes → this task is complete; skip to the next numeric task.
- If no → this is the **next task**. Proceed to Step 2 with this file as the active task.

If every `taskN.md` in the goal directory already has a `## Completion Summary` section, the goal is already complete — clear the marker, log this and stop (without running `after_goal` again).

**Gap handling.** If the iteration finds `task1.md` and `task3.md` but no `task2.md`, treat this as a hard error: the goal directory is malformed. Clear the marker, surface the gap to the user and stop without mutation. (The contract is "consecutive numeric files starting at 1"; do NOT silently skip gaps.)

### Step 2 — Execute the `## before_task` hook

The `hooks/hooks.json` registered with Claude Code auto-fires the `## before_task` section from `.stride_lite.md` as a **PreToolUse** hook on the Step 3 `Agent` dispatch of `stride-lite:task-explorer`. The harness runs the hook before the agent dispatch completes; a non-zero exit returns `exit 2` and blocks the dispatch, which surfaces to you as a Step 3 failure.

You do **NOT** read `.stride_lite.md` or execute its hook sections directly in this step — the harness does that. Missing `.stride_lite.md`, a missing `## before_task` section, or an empty fenced block all degrade to a clean no-op (exit 0) so the dispatch proceeds. A failing command emits a structured failure JSON on stdout for your Step 8 Completion Summary to reference.

If Step 3's dispatch is blocked by a `before_task` failure, clear the marker, surface the failing command and its stderr to the user and stop the workflow.

### Step 3 — Dispatch `stride-lite:task-explorer`

Use Claude Code's `Agent` tool with `subagent_type: stride-lite:task-explorer` and the active task file's path as the prompt input. The explorer parses the task file's metadata (`## Key files`, `## Patterns to follow`, `## Where`, `## Testing strategy`), runs read-only codebase exploration, and appends/replaces a `## Exploration Report` section at the bottom of the task file (per the v0.6.0 contract).

If the explorer dispatch fails (e.g., the agent surfaces a clear error and exits without mutation), clear the marker, stop the workflow and surface the error. The explorer is a hard prerequisite for high-quality implementation in Step 4.

### Step 4 — Implementation

Now write code. Use the active task file as your spec — `## Description`, `## Why`, `## What`, `## Where`, `## Acceptance criteria`, `## Patterns to follow`, `## Pitfalls`, `## Security considerations`, `## Integration points`, `## Technology requirements`, `## Logging requirements`, `## Key files`, `## Verification steps`, `## Testing strategy` — plus the `## Exploration Report` the explorer just appended.

Follow the acceptance criteria as your definition of done. Replicate the patterns. Avoid the pitfalls. Modify the files listed in `## Key files`. Write the tests specified in `## Testing strategy`.

**This is the only step where the orchestrator agent writes code.** Steps 1, 2, 5, 7, 8 are file-mutation-or-hook-execution; Steps 3 and 6 are agent dispatches.

### Step 5 — Execute the `## after_task` hook

Same auto-fire pattern as Step 2, but the harness runs the `## after_task` section as a **PreToolUse** hook on the Step 6 `Agent` dispatch of `stride-lite:task-reviewer`. Same blocking semantics — a non-zero exit blocks the reviewer dispatch, which surfaces to you as a Step 6 failure.

If the reviewer dispatch is blocked by an `after_task` failure, clear the marker, surface the failing command and its stderr to the user and stop the workflow.

You do **NOT** execute `.stride_lite.md` hook sections directly in this step. The harness handles it; a failing command emits structured failure JSON for your Step 8 Completion Summary.

### Step 6 — Dispatch `stride-lite:task-reviewer`

Use Claude Code's `Agent` tool with `subagent_type: stride-lite:task-reviewer` and the active task file's path as the prompt input. The reviewer captures `git diff HEAD` (working tree vs HEAD), evaluates the diff against the task file's acceptance criteria / pitfalls / patterns / testing strategy, and appends/replaces a `## Review Report` section at the bottom of the task file (per the v0.7.0 contract).

The reviewer emits a prose summary line AND a fenced ```json block. Step 7 parses the JSON to decide the next step.

### Step 7 — Review-loop decision

Read the active task file's `## Review Report` section. Extract the first fenced ```json block from that section and parse it. Read the `status` field:

- If `status == "approved"` → proceed to Step 8.
- If `status == "changes_requested"` → increment the `review_iteration` counter (initialized to 0 at Step 2) and:
  - If `review_iteration < max_review_iterations` (default 3) → loop back to **Step 4** (Implementation). Make further code changes addressing the reviewer's issues. Then re-run Steps 5, 6, 7 in sequence.
  - If `review_iteration >= max_review_iterations` → clear the marker and stop the workflow. Surface the failing review's prose summary line + the list of unresolved issues to the user. Do NOT write a Completion Summary; the task remains incomplete.

**JSON parse fallback.** If the `## Review Report` section has no fenced ```json block (e.g., the agent fell back to prose-only), parse the prose summary line instead: substring-match `"Approved"` → treat as `approved`; substring-match `"N issues found"` → treat as `changes_requested`. If neither pattern matches, treat as `changes_requested` (conservative default — better to retry than to falsely approve).

### Step 8 — Completion summary + final-task detection + after_goal hook

Append a `## Completion Summary` section to the active task file at EOF. The section contains:

- A one-paragraph synthesis: what was implemented, which acceptance criteria were met, key decisions made.
- A bullet list summarizing the hook results from Steps 2 and 5 (exit_code, brief output).
- A reference to the embedded review JSON's `status` ("approved" — by contract, since we only reach Step 8 if Step 7 returned approved).

**Final-task detection.** After appending the Completion Summary to `taskK.md`, check the goal directory for `task(K+1).md`:

- If `task(K+1).md` **exists** → return to Step 1 to process the next task in the loop.
- If `task(K+1).md` **does NOT exist** → this was the final task in the goal. Continue with the goal-level wrap-up:
  1. Append a `## Completion Summary` section to `goal.md` (the goal-level summary). Content: one-paragraph synthesis of the work across all child tasks, bullet list of completed tasks with one-line each, total elapsed time if trackable.
  2. The append to `goal.md` is performed via `Edit` or `Write`; the harness auto-fires the `## after_goal` section from `.stride_lite.md` as a **PostToolUse** hook when (a) the file path ends in `goal.md` and (b) the written content contains the literal string `## Completion Summary`. PostToolUse cannot roll back the write, so `after_goal` is **advisory** — a failure emits structured failure JSON on stdout for the user to inspect but does not stop or roll back. You do NOT execute `.stride_lite.md` hook sections directly in this step.
  3. **Move the goal directory from `PENDING/` to `IMPLEMENTED/`.** After the `after_goal` hook has fired, archive the completed goal by moving the goal directory from `docs/implementation/PENDING/<slug>/` to `docs/implementation/IMPLEMENTED/<slug>/`. Four behavioral details:

     - **Timing.** This move happens AFTER `after_goal` fires — the user's hook sees the still-PENDING path, matching what the hook was scoped to handle. Never move before the hook.
     - **After-goal-failure guard.** If the harness emitted a structured failure JSON for the `after_goal` hook (`"status": "failed"`), do NOT move the directory. Leave it in `PENDING/` so the user can inspect the failure and re-trigger. A clean no-op (no `after_goal` section, missing `.stride_lite.md`, empty fenced block) is NOT a failure — proceed with the move.
     - **Non-`/PENDING/` path.** If `goal_directory_path` (after stripping the trailing slash) does not contain `/PENDING/` as a directory segment — for example, the user passed a custom `--output-dir` to `/stride-lite:create-goal` and the goal lives at `docs/custom-archive/<slug>/` — log a warning to stderr (`stride-lite-workflow: goal directory not under PENDING — skipping move; you can move it manually to your archive location`) and skip the move. Do NOT fail the workflow.
     - **Move tool selection.** Try `git mv` first when (a) `git rev-parse --is-inside-work-tree` succeeds and (b) `git ls-files "$goal_path"` returns a non-empty list (the goal directory's files are tracked). This preserves rename history. Otherwise fall back to plain `mv`.
     - **Collision suffixing.** If the target `IMPLEMENTED/<slug>/` already exists, suffix the destination with `-2`, `-3`, ... up to a 1000-iteration cap, mirroring `lib/resolve_output_path.md`'s semantics exactly (start at `n=2`, probe with `[ ! -e "$candidate" ]`, never overwrite, cap exhaustion emits a stderr warning and skips the move). Never overwrite an existing IMPLEMENTED entry.
     - **Filesystem-mv failure.** If `mv` / `git mv` returns non-zero (permissions, disk full, cross-device, etc.), log the error to stderr and skip the move — the goal work is complete, a failed archive is a recovery operation. Do NOT fail the workflow.

     **Reference bash idiom** (use as a template; adapt variable names freely):

     ```bash
     goal_path="${goal_directory_path%/}"          # strip trailing slash
     slug="${goal_path##*/}"                       # basename = slug

     case "$goal_path" in
       */PENDING/*)
         pending_parent="${goal_path%/PENDING/*}"  # path up to /PENDING parent
         impl_base="${pending_parent%/}/IMPLEMENTED"
         candidate="${impl_base}/${slug}"
         n=2
         while [ -e "$candidate" ]; do
           candidate="${impl_base}/${slug}-${n}"
           n=$(( n + 1 ))
           if [ "$n" -gt 1000 ]; then
             echo "stride-lite-workflow: refusing to scan past -1000 collisions for IMPLEMENTED destination" >&2
             candidate=""; break
           fi
         done
         if [ -n "$candidate" ]; then
           mkdir -p "$impl_base"
           if git rev-parse --is-inside-work-tree > /dev/null 2>&1 \
              && [ -n "$(git ls-files "$goal_path")" ]; then
             git mv "$goal_path" "$candidate" \
               || { echo "stride-lite-workflow: git mv failed; leaving in PENDING" >&2; }
           else
             mv "$goal_path" "$candidate" \
               || { echo "stride-lite-workflow: mv failed; leaving in PENDING" >&2; }
           fi
         fi
         ;;
       *)
         echo "stride-lite-workflow: goal directory not under PENDING — skipping move; you can move it manually to your archive location" >&2
         ;;
     esac
     ```

  4. Clear the marker, then stop. Workflow complete.

## Hook execution contract

As of v0.9.0 the three hooks (`## before_task`, `## after_task`, `## after_goal`) are **auto-fired by Claude Code via `hooks/hooks.json`** — the workflow skill body does NOT execute `.stride_lite.md` hook sections directly. The harness invokes `hooks/stride-lite-hook.sh` on macOS/Linux (which delegates to `hooks/stride-lite-hook.ps1` on native Windows) at three intercept points:

| Section | Phase | Matcher | Trigger condition | Blocking? |
|---|---|---|---|---|
| `## before_task` | PreToolUse | `Agent` | `tool_input.subagent_type == "stride-lite:task-explorer"` (Step 3 dispatch) | yes (exit 2 blocks the dispatch) |
| `## after_task` | PreToolUse | `Agent` | `tool_input.subagent_type == "stride-lite:task-reviewer"` (Step 6 dispatch) | yes (exit 2 blocks the dispatch) |
| `## after_goal` | PostToolUse | `Edit` or `Write` | file path ends in `goal.md` AND body contains `## Completion Summary` (Step 8 final-task wrap-up) | no (advisory; failure cannot roll back the write) |

All three triggers are additionally gated on the activation marker — the table above describes what fires **while a workflow run is active**.

For each trigger, the hook executor:

1. Checks `$CLAUDE_PROJECT_DIR/.stride-lite/.orchestrator_active`. With no marker, a stale one (`started_at` older than 4h, or in the future), or an unreadable/malformed one, it runs nothing and exits 0 — no JSON, no section, and **no block**: the intercepted tool call proceeds either way. `STRIDE_LITE_ALLOW_DIRECT=1` skips this check. See [Orchestrator activation marker](#orchestrator-activation-marker).
2. Locates `.stride_lite.md` via `$CLAUDE_PROJECT_DIR` (falls back to the current directory).
3. Parses the named `## <section>` heading and the first fenced ` ```bash ... ``` ` block under it.
4. Derives the task/goal context from the hook payload and the files it names, and exports it into each command's environment (table below).
5. Executes each non-empty, non-comment line one at a time. On the first non-zero exit it stops and emits a structured failure JSON on stdout (`hook`, `status: "failed"`, `failed_command`, `command_index`, `exit_code`, `stdout`, `stderr`, `commands_completed`, `commands_remaining`); on all-success it emits a structured success JSON (`hook`, `status: "success"`, `commands_completed`, `duration_seconds`).
6. An absent or stale activation marker, a missing `.stride_lite.md`, a missing section, or an empty fenced block all degrade to a clean no-op (exit 0, no JSON).

### Injected environment variables

Before running the section, the executor exports a derived environment block into every command's environment. stride-lite has no server, so there is no `hook.env` payload to forward — the values come from the task and goal markdown the hook already has in hand.

| Variable | `before_task` | `after_task` | `after_goal` | Derived from |
|---|:---:|:---:|:---:|---|
| `HOOK_NAME` | ✓ | ✓ | ✓ | The section being run. |
| `AGENT_NAME` | ✓ | ✓ | — | The intercepted `tool_input.subagent_type`. `after_goal` intercepts a file write, not an agent dispatch, so it has no agent to name. |
| `TASK_FILE` | ✓ | ✓ | — | Absolute path of the `taskN.md` named in the Agent dispatch prompt. |
| `TASK_NUMBER` | ✓ | ✓ | — | The digits in `taskN.md`. |
| `TASK_TITLE` | ✓ | ✓ | — | The first `# ` heading of `TASK_FILE`. |
| `GOAL_DIR` | ✓ | ✓ | ✓ | Parent directory of `TASK_FILE` — or of the written `goal.md`, for `after_goal`. |
| `GOAL_FILE` | ✓ | ✓ | ✓ | `$GOAL_DIR/goal.md`. |
| `GOAL_SLUG` | ✓ | ✓ | ✓ | Basename of `GOAL_DIR` — the slug `/stride-lite:create-goal` generated. |
| `GOAL_TITLE` | ✓ | ✓ | ✓ | The first `# ` heading of `GOAL_FILE`. |

Rules, identical in `stride-lite-hook.sh` and `stride-lite-hook.ps1` (`test/smoke.sh` diffs the key set out of both scripts and, where PowerShell is available, drives the `.ps1`'s derivation functions through the same fixtures as the bash stage — so drift in either the key set or the rules fails the suite):

- **Every key is always exported.** A key the executor cannot derive — an unparseable prompt, a missing or unreadable file, a path outside the project — is exported as the **empty string**: defined-but-empty, never omitted, never an error. No derivation failure changes the hook's exit code, so a `set -u` inside your command cannot abort on one.
- **`before_task` and `after_task` carry the `GOAL_*` keys too**, because a task file's parent directory *is* its goal directory. Only `after_goal` drops the `TASK_*` keys — it is a goal-level event with no single task behind it. A task file with no `goal.md` beside it reports empty `GOAL_*` rather than a directory name that merely looks like a slug.
- **Values are exported, never spliced into the command text.** A title containing `$(id)`, backticks or `;` reaches your command as inert literal text. Quote your references (`"$TASK_TITLE"`) as you would any variable.
- **Paths are confined to the project.** A prompt or `file_path` resolving outside `$CLAUDE_PROJECT_DIR` is refused and the derived keys stay empty, as is a symlinked task file pointing out of the tree.
- **Nothing is cached.** The block lives in the hook process and the commands it spawns — no file on disk, and no value survives into the next invocation.
- **No board, column or status keys.** stride-lite has no board, no column and no status field, so it exports nothing it cannot truthfully derive from the file tree. This is a deliberate divergence from the full Stride plugin's server-supplied `BOARD_*` / `COLUMN_*` / `TASK_STATUS` block: inventing empty versions here would teach a contract stride-lite cannot honour.

Shaped as it appears in `.stride_lite.md` — the heading sits outside the fenced block:

````markdown
## after_task

```bash
echo "Finished task $TASK_NUMBER of $GOAL_SLUG: $TASK_TITLE"
```
````

## Bash scope

The workflow skill's Bash usage is scoped to a specific set of operations. Explicit ✅ examples:

- ✅ `.stride_lite.md` hook execution is performed by the harness via `hooks/stride-lite-hook.sh` (or `.ps1` on native Windows) — this skill body does NOT run `## before_task` / `## after_task` / `## after_goal` directly.
- ✅ `git diff HEAD` — captured by the task-reviewer agent in Step 6 (not directly by this skill; the agent has its own Bash grant).
- ✅ `ls`, `test -f`, `find` — for filesystem navigation inside the goal directory (listing taskN.md files, checking for task(K+1).md existence).
- ✅ `git rev-parse --show-toplevel` — for locating the project root (e.g., to inspect `.stride_lite.md` for the user, not to execute it).
- ✅ `mv` and `git mv` — for the terminal-move step in Step 8's final-task branch only (PENDING → IMPLEMENTED archive move). Forbidden elsewhere in the skill body.
- ✅ `git rev-parse --is-inside-work-tree` — for the terminal-move step in Step 8's final-task branch only (detecting whether to prefer `git mv` over plain `mv`). Forbidden elsewhere in the skill body.
- ✅ `git ls-files <path>` — for the terminal-move step in Step 8's final-task branch only (detecting whether the goal directory's files are git-tracked before invoking `git mv`). Forbidden elsewhere in the skill body.
- ✅ `mkdir -p <impl_base>` — for the terminal-move step only (ensuring the IMPLEMENTED parent directory exists before `mv` / `git mv` lands the goal into it). Forbidden elsewhere in the skill body.
- ✅ `mkdir -p "$STRIDE_LITE_ROOT/.stride-lite"`, the `printf … > .stride-lite/.orchestrator_active` redirect, the `test -f` verification, and the `date -u` / `uuidgen` / `git rev-parse --show-toplevel` / `pwd` they interpolate — for Step 0's activation-marker write only. Forbidden elsewhere in the skill body.
- ✅ `rm -f "$STRIDE_LITE_ROOT/.stride-lite/.orchestrator_active"` — the marker clear, on every exit path. This is the ONLY sanctioned `rm` in this skill, and it is scoped to that exact path.

Explicit ❌ anti-examples — the workflow skill MUST NEVER directly invoke:

- ❌ `mix test`, `mix compile`, `npm test`, `npm run`, `cargo test`, `cargo build` — these belong in the user's `## after_task` hook, not in the skill body.
- ❌ `curl`, `wget`, `nc` — no network calls (matches the v0.7.0 task-reviewer's discipline).
- ❌ `git commit`, `git push`, `git checkout`, `git reset`, `git merge`, `git rebase` — no mutating git operations.
- ❌ `rm`, `cp` and `mv` outside the documented narrow uses (user-supplied hook bash blocks; the terminal-move step in Step 8's final-task branch carving out `mv` / `git mv` / `mkdir -p`; and the activation-marker write and clear — all as listed in the ✅ block above) — no filesystem mutation outside the documented append-only task/goal file mutations, the activation marker, plus the terminal archive move.

If the user wants build/test/lint runs as part of the workflow, they put them in `## after_task` in `.stride_lite.md`. The harness's PreToolUse hook on the Step 6 reviewer dispatch executes them verbatim — that's how the scope expands by configuration, not by skill-body code.

## Edge cases

- **No `.stride_lite.md` in project root** — log a warning, treat all three hooks as no-ops, proceed with the workflow. The user may not have initialized stride-lite; that's a valid (if reduced-functionality) configuration.
- **`.stride_lite.md` exists but a hook section is missing** — treat that specific hook as a no-op (exit_code 0, empty output). Don't fail; the user may have deliberately omitted unneeded hooks.
- **`.stride_lite.md` hook section exists but the fenced bash block is empty** — same as missing: no-op, proceed.
- **Goal directory missing `goal.md`** — hard error: clear the marker, surface a clear message ("goal_directory_path is not a valid stride-lite goal — no goal.md found") and stop.
- **Goal directory has no taskN.md files** — hard error: clear the marker, surface a clear message and stop. The workflow needs at least task1.md to do anything.
- **Goal directory has task1.md and task3.md but no task2.md** — hard error per Step 1's gap-handling rule. Clear the marker, surface the gap and stop.
- **Every taskN.md already has `## Completion Summary`** — clear the marker, log "goal already complete" and stop. Do NOT re-run after_goal (the goal has already been wrapped up in a prior session).
- **task-explorer agent dispatch fails or returns an error** — clear the marker, surface the explorer's error and stop. The explorer's findings are a prerequisite for high-quality implementation.
- **task-reviewer agent dispatch fails or returns an error** — clear the marker, surface the reviewer's error and stop. Without a review verdict, the workflow can't decide Step 7.
- **task-reviewer's `## Review Report` has no fenced JSON block** — fall back to prose-substring matching per Step 7's JSON parse fallback. Conservative default on ambiguity: treat as `changes_requested`.
- **Review-loop exhausts max_review_iterations** — clear the marker and stop without writing the Completion Summary. The task file retains its latest `## Review Report` section as the audit trail. The user can manually fix the issues and re-run the workflow; on re-run the task is "incomplete" (no Completion Summary) so Step 1 picks it up again.
- **after_goal hook fails after goal.md Completion Summary is written** — surface the failure but do NOT roll back the goal.md mutation. Still clear the marker before stopping. The user can re-run the after_goal hook manually (e.g., by inspecting `.stride_lite.md` and running the commands directly).

## Concrete walkthrough

A two-task goal at `docs/implementation/PENDING/add-notifications/` containing `goal.md`, `task1.md`, `task2.md`, and a `.stride_lite.md` in the project root with all three hook sections populated. The workflow proceeds:

- **Step 0.** Write `.stride-lite/.orchestrator_active` once, at workflow entry. Until it exists the harness's hook gate is closed and none of the `.stride_lite.md` sections below would fire.

**Iteration 1 — task1.md (Emit PubSub broadcast on comment insert).**

- **Step 1.** Scan goal dir. task1.md has no `## Completion Summary` → next task is task1.md.
- **Step 2.** Nothing to run by hand — the `## before_task` hook is auto-fired by the Claude Code harness at Step 3's explorer dispatch (PreToolUse intercept, blocking). The harness runs the section's bash (e.g., `git pull origin main`) and emits its structured success JSON; a non-zero exit would surface as exit 2 and block the dispatch.
- **Step 3.** Dispatch `stride-lite:task-explorer` with `task1.md` as the prompt. After ~30s the agent appends a `## Exploration Report` section to task1.md covering File state per key_file, Pattern matches (Kanban.Boards.create_board broadcast at boards.ex:42), Related tests (test/kanban/comments_test.exs), Implementation notes (use Kanban.PubSub, follow with-chain placement).
- **Step 4.** Implement the broadcast. Modify `lib/kanban/comments.ex` (add Phoenix.PubSub.broadcast inside the success arm) and `test/kanban/comments_test.exs` (subscriber test).
- **Step 5.** Again no direct execution — the harness auto-fires the `## after_task` hook at Step 6's reviewer dispatch (PreToolUse intercept, blocking). Its bash (e.g., `mix test` and `mix credo --strict`) runs and succeeds; a failure would block the reviewer dispatch until the root cause is fixed.
- **Step 6.** Dispatch `stride-lite:task-reviewer` with `task1.md` as the prompt. After ~25s the agent appends a `## Review Report` section. The embedded JSON's `status` is `approved`.
- **Step 7.** Parse the JSON. `status == approved` → proceed to Step 8.
- **Step 8.** Append a `## Completion Summary` section to task1.md (one-paragraph synthesis + hook results + review status). Check for task2.md: exists. Return to Step 1.

**Iteration 2 — task2.md (Subscribe to comment broadcasts in BoardLive.Show).**

- **Step 1.** Scan again. task1.md now has `## Completion Summary` → skip. task2.md has no `## Completion Summary` → next task is task2.md.
- **Step 2–7.** Same pattern. The reviewer first returns `changes_requested` (the BoardLive subscribe wasn't filtering by board_id). The workflow loops back to Step 4 (iteration 1 of the review-loop), the implementation is fixed, Step 5/6/7 re-run, the reviewer now returns `approved` (iteration 2 — under the cap). Proceed to Step 8.
- **Step 8.** Append `## Completion Summary` to task2.md. Check for task3.md: does NOT exist. This was the final task.
- **Step 8 (continued).** Append `## Completion Summary` to `goal.md` with the goal-level synthesis: "Real-time notifications shipped via 2-task split — broadcast emission in the context module (task1), LiveView subscription in BoardLive.Show (task2). Both tasks reviewed and approved. All hooks completed cleanly."
- **Step 8 (final).** The harness auto-fires the `## after_goal` hook after the goal.md Completion Summary write (PostToolUse intercept, advisory — it cannot roll back the write that already happened). On success or a clean no-op, archive the goal: move `docs/implementation/PENDING/add-notifications/` to `docs/implementation/IMPLEMENTED/add-notifications/` (git mv when the files are tracked, plain mv otherwise, collision-suffixed per body Step 8). If the harness emitted a structured `"status": "failed"` for after_goal, do NOT move the directory — leave it in PENDING so the user can inspect the failure and re-trigger; goal.md's Completion Summary remains either way. Finally, clear the activation marker as the last act of the run — after the archive move, so nothing between the last hook and exit runs unarmed. Workflow complete.

**End state.** Both taskN.md files have full lifecycle sections (Description → ... → Exploration Report → Review Report → Completion Summary). goal.md has a `## Completion Summary` at EOF, and the goal directory now lives at `docs/implementation/IMPLEMENTED/add-notifications/`. The user can navigate the archived goal directory and see exactly what happened, in order, in each file.

## Red flags — STOP

If you catch yourself thinking any of these, go back to the documented step:

- **"This task is small — I'll skip the explorer dispatch in Step 3."** No. The explorer is part of the documented loop; every task gets it. The explorer's findings inform Step 4's implementation, and skipping it produces lower-quality code reviews in Step 6.
- **"The reviewer's `changes_requested` looks minor — I'll write the Completion Summary anyway."** No. The Step 7 contract is binary: `approved` proceeds, anything else loops back. Bypassing the loop defeats the safeguard.
- **"The after_task hook failed but it's just a flaky test — let me skip and complete the task."** No. Blocking failures must clear the marker and stop the workflow. Fix the root cause (in the user's `.stride_lite.md`) and re-run.
- **"The goal directory was malformed so nothing really started — I can skip the marker clear."** No. `rm -f` on a path that does not exist is a no-op. Clear on every exit path, unconditionally.
- **"`.stride_lite.md` doesn't exist, I'll skip the hooks but write Completion Summaries anyway."** Yes, this is actually correct — no `.stride_lite.md` is a valid reduced-functionality configuration. But surface a warning so the user knows the hooks were skipped.
- **"The review-loop has hit 3 iterations but the reviewer keeps finding the same issue — I'll force-approve."** No. Clear the marker, stop, surface the unresolved issue, and let the user intervene. Forcing approval defeats the entire review-loop purpose.

## Pitfalls

- **Don't write code in Steps 1, 2, 3, 5, 6, 7, or 8.** Only Step 4 is implementation; the others are orchestration. Mixing concerns produces ambiguous task files.
- **Don't dispatch task-explorer or task-reviewer with parameters other than the task file path.** Both have file-based contracts; they read the file, mutate the file, return nothing structured to you. Treat them as black boxes invoked by path.
- **Don't read or modify `goal.md` in Step 1 — only the taskN.md files determine the next task.** The goal.md is for the human reader; the workflow ignores it until Step 8's final-task wrap-up.
- **Don't execute the after_goal hook except on the final task.** Step 8's final-task detection (task(K+1).md doesn't exist) is the only trigger.
- **Don't mutate goal.md or taskN.md beyond the documented append-only summaries.** Everything above the appended `## Completion Summary` section stays byte-equivalent across workflow runs.
- **Don't fail silently on hook errors.** Blocking failures must clear the marker, surface a clear error and stop the workflow.
- **Don't leave the activation marker behind.** A leftover marker arms the user's `.stride_lite.md` hooks for *any* dispatch in this project for up to four hours — including the standalone `stride-lite:task-explorer` dispatch the README documents as a supported manual workflow. The freshness window bounds a crash; it does not excuse a skipped clear.
- **Don't expand the Bash scope beyond the explicit ✅ list.** If you need a non-allowed command, clear the marker, surface the limitation and stop; let the user add it to `.stride_lite.md` if they want it part of the workflow.
- **Don't loop forever in Step 7.** The `max_review_iterations` cap (default 3) is mandatory. After the cap, clear the marker and stop with the failing review surfaced.
- **Don't conflate "task-explorer error" with "implementation error".** Step 3 has its own failure mode (the agent surfaces an error); Step 4's implementation is on you. Clear the marker, surface explorer errors and stop; don't proceed to a Step 4 without exploration findings.
- **Don't introduce a new slash command in this skill.** Invocation is via the Skill tool only — same pattern as `stride:stride-workflow`. If a command surface is wanted, it's a follow-up release.
- **Don't read user-supplied hook commands as anything other than verbatim bash.** Do not pre-validate them, do not "sanitize" them. The user owns `.stride_lite.md` content; if they put a destructive command there, the workflow will execute it. That's a user responsibility, not a skill safety net.
