---
name: stride-lite-workflow
description: |
  Use to drive a stride-lite goal directory through its full eight-step lifecycle: select the next incomplete task → run the `## before_task` hook from `.stride_lite.md` → dispatch `stride-lite:task-explorer` to enrich the task with codebase context → implement the code changes per the task's acceptance criteria → run the `## after_task` hook → dispatch `stride-lite:task-reviewer` to validate the diff → if review approved proceed, else loop back to coding (cap: 3 iterations) → write a `## Completion Summary` to the task file. On the final task in the goal, also write a Completion Summary to `goal.md` and run the `## after_goal` hook. The skill is the file-based equivalent of the full Stride plugin's `stride-workflow` orchestrator: no API calls, no claim/complete server endpoints, no kanban authentication — only goal/task markdown files, the project-local `.stride_lite.md` hook file, and the two existing stride-lite subagents. Examples: <example>Context: User has run /stride-lite:create-goal and now wants to drive the resulting goal through implementation. user: "Work the docs/implementation/PENDING/add-real-time-notifications-for-board-comments goal." assistant: "Activating stride-lite-workflow with that path as goal_directory_path; the skill will iterate task1.md, task2.md, task3.md in order, running before_task → explorer → implement → after_task → reviewer → completion-summary on each, and after_goal at the end." <commentary>The skill picks task1.md (the first incomplete one), runs the eight-step loop, advances to task2.md, repeats, and on task3.md (the final task per goal.md's Tasks index) appends Completion Summary to goal.md and runs the after_goal hook.</commentary></example> <example>Context: User wants to resume a partially-completed goal where task1.md is already done. user: "Resume the add-notifications goal." assistant: "Activating stride-lite-workflow. The first task already has a ## Completion Summary section, so the skill will pick up at task2.md and continue." <commentary>The 'next task' rule is 'first taskN.md without ## Completion Summary' — partial-run resumption works automatically without separate state tracking.</commentary></example>
skills_version: "1.0"
---

# stride-lite-workflow

The file-based equivalent of `stride:stride-workflow`. Walks a stride-lite goal directory through the eight-step task lifecycle: select next task → before_task hook → explorer → implementation → after_task hook → reviewer → review-loop → completion summary → (on final task) goal completion summary + after_goal hook. No API calls, no kanban server interaction, no auth — the goal/task markdown files plus the project-local `.stride_lite.md` hook file are the entire surface.

## When to invoke

Invoke this skill once when you're ready to drive a goal directory through implementation. It handles the full per-task loop and the per-goal wrap-up. Do not invoke it on individual task files outside a goal directory — for single-task scaffolds produced by `/stride-lite:create-task`, do the work manually.

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

## The Eight-Step Loop

For each incomplete task in the goal directory (in numeric `taskN.md` order), walk these eight steps. On the final task, the workflow exits cleanly after Step 8 instead of looping.

### Step 1 — Select the next task

Read the goal directory. Iterate `task1.md`, `task2.md`, `task3.md`, ... in strict numeric order. For each task file, check whether it contains a `## Completion Summary` section at the bottom of the file:

- If yes → this task is complete; skip to the next numeric task.
- If no → this is the **next task**. Proceed to Step 2 with this file as the active task.

If every `taskN.md` in the goal directory already has a `## Completion Summary` section, the goal is already complete — log this and stop (without running `after_goal` again).

**Gap handling.** If the iteration finds `task1.md` and `task3.md` but no `task2.md`, treat this as a hard error: the goal directory is malformed. Surface the gap to the user and stop without mutation. (The contract is "consecutive numeric files starting at 1"; do NOT silently skip gaps.)

### Step 2 — Execute the `## before_task` hook

Read `.stride_lite.md` from the project root (the file `/stride-lite:init` scaffolds). Locate the `## before_task` section. Parse the fenced bash block inside it — one command per line.

Execute each command line via Bash, one at a time, capturing `exit_code`, `stdout`, `stderr`, and `duration_ms` for each. Stop on the first non-zero exit:

- If `## before_task` section is **missing** from `.stride_lite.md` → treat as a no-op (exit_code 0, empty output) and proceed.
- If the section exists but the fenced block is **empty** → no-op and proceed.
- If `.stride_lite.md` itself is **missing** → log a clear warning ("no .stride_lite.md found in project root; skipping hook execution") and proceed.
- If any command **exits non-zero** → this is a blocking failure. Surface the failing command and its stderr to the user and stop the workflow. Do NOT proceed to Step 3.

**Capture the aggregated hook result** (exit_code = max of all line exit_codes, output = concatenated stdout/stderr, duration_ms = wall-clock total). The Step 8 Completion Summary references this result.

### Step 3 — Dispatch `stride-lite:task-explorer`

Use Claude Code's `Agent` tool with `subagent_type: stride-lite:task-explorer` and the active task file's path as the prompt input. The explorer parses the task file's metadata (`## Key files`, `## Patterns to follow`, `## Where`, `## Testing strategy`), runs read-only codebase exploration, and appends/replaces a `## Exploration Report` section at the bottom of the task file (per the v0.6.0 contract).

If the explorer dispatch fails (e.g., the agent surfaces a clear error and exits without mutation), stop the workflow and surface the error. The explorer is a hard prerequisite for high-quality implementation in Step 4.

### Step 4 — Implementation

Now write code. Use the active task file as your spec — `## Description`, `## Why`, `## What`, `## Where`, `## Acceptance criteria`, `## Patterns to follow`, `## Pitfalls`, `## Security considerations`, `## Integration points`, `## Technology requirements`, `## Logging requirements`, `## Key files`, `## Verification steps`, `## Testing strategy` — plus the `## Exploration Report` the explorer just appended.

Follow the acceptance criteria as your definition of done. Replicate the patterns. Avoid the pitfalls. Modify the files listed in `## Key files`. Write the tests specified in `## Testing strategy`.

**This is the only step where the orchestrator agent writes code.** Steps 1, 2, 5, 7, 8 are file-mutation-or-hook-execution; Steps 3 and 6 are agent dispatches.

### Step 5 — Execute the `## after_task` hook

Same pattern as Step 2, but read the `## after_task` section from `.stride_lite.md`. Same blocking semantics: any non-zero exit stops the workflow.

Capture the aggregated hook result for the Completion Summary in Step 8.

### Step 6 — Dispatch `stride-lite:task-reviewer`

Use Claude Code's `Agent` tool with `subagent_type: stride-lite:task-reviewer` and the active task file's path as the prompt input. The reviewer captures `git diff HEAD` (working tree vs HEAD), evaluates the diff against the task file's acceptance criteria / pitfalls / patterns / testing strategy, and appends/replaces a `## Review Report` section at the bottom of the task file (per the v0.7.0 contract).

The reviewer emits a prose summary line AND a fenced ```json block. Step 7 parses the JSON to decide the next step.

### Step 7 — Review-loop decision

Read the active task file's `## Review Report` section. Extract the first fenced ```json block from that section and parse it. Read the `status` field:

- If `status == "approved"` → proceed to Step 8.
- If `status == "changes_requested"` → increment the `review_iteration` counter (initialized to 0 at Step 2) and:
  - If `review_iteration < max_review_iterations` (default 3) → loop back to **Step 4** (Implementation). Make further code changes addressing the reviewer's issues. Then re-run Steps 5, 6, 7 in sequence.
  - If `review_iteration >= max_review_iterations` → stop the workflow. Surface the failing review's prose summary line + the list of unresolved issues to the user. Do NOT write a Completion Summary; the task remains incomplete.

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
  2. Execute the `## after_goal` hook from `.stride_lite.md` (same pattern as Step 2). A failure here stops the workflow but does NOT roll back the Completion Summary — the user can re-run the after_goal hook manually.
  3. Workflow complete. Stop.

## Hook execution contract

The three hooks (`## before_task`, `## after_task`, `## after_goal`) all use the same execution pattern, captured here once:

1. Read `.stride_lite.md` from the project root (use `git rev-parse --show-toplevel` to locate it; fall back to the current working directory if not inside a git repo).
2. Find the relevant `## <hook_name>` section. If absent, treat as no-op (exit_code 0, empty output) and proceed.
3. Parse the fenced bash block (` ```bash ... ``` `) inside that section. If the block is empty or missing, treat as no-op.
4. Execute each command line via Bash, one at a time:
   - Capture stdout, stderr, exit_code per line.
   - Aggregate: result_exit_code = max of all line exit_codes; result_output = concatenated stdout (then stderr, prefixed `--- stderr ---`); result_duration_ms = wall-clock total.
5. If `result_exit_code != 0` (blocking failure):
   - Surface the failing command, its line number in `.stride_lite.md`, and its stderr to the user.
   - Stop the workflow. Do NOT proceed to the next step.
6. Otherwise (success), record the aggregated result. The Completion Summary in Step 8 references it.

The hook environment is the same Bash shell environment the workflow itself runs in — no special env-var injection beyond what the user's command lines reference. (This differs from the full Stride plugin which injects `TASK_*` / `GOAL_*` env vars; stride-lite hooks rely on the user writing self-contained commands.)

## Bash scope

The workflow skill's Bash usage is scoped to a specific set of operations. Explicit ✅ examples:

- ✅ Hook execution from `.stride_lite.md` (`## before_task` / `## after_task` / `## after_goal` fenced bash blocks) — the user supplies these commands; execute them verbatim.
- ✅ `git diff HEAD` — captured by the task-reviewer agent in Step 6 (not directly by this skill; the agent has its own Bash grant).
- ✅ `ls`, `test -f`, `find` — for filesystem navigation inside the goal directory (listing taskN.md files, checking for task(K+1).md existence).
- ✅ `git rev-parse --show-toplevel` — for locating the project root to find `.stride_lite.md`.

Explicit ❌ anti-examples — the workflow skill MUST NEVER directly invoke:

- ❌ `mix test`, `mix compile`, `npm test`, `npm run`, `cargo test`, `cargo build` — these belong in the user's `## after_task` hook, not in the skill body.
- ❌ `curl`, `wget`, `nc` — no network calls (matches the v0.7.0 task-reviewer's discipline).
- ❌ `git commit`, `git push`, `git checkout`, `git reset`, `git merge`, `git rebase` — no mutating git operations.
- ❌ `rm`, `mv`, `cp` (except inside user-supplied hook bash blocks) — no filesystem mutation outside the documented append-only task/goal file mutations.

If the user wants build/test/lint runs as part of the workflow, they put them in `## after_task` in `.stride_lite.md`. The workflow executes them verbatim — that's how the scope expands by configuration, not by skill-body code.

## Edge cases

- **No `.stride_lite.md` in project root** — log a warning, treat all three hooks as no-ops, proceed with the workflow. The user may not have initialized stride-lite; that's a valid (if reduced-functionality) configuration.
- **`.stride_lite.md` exists but a hook section is missing** — treat that specific hook as a no-op (exit_code 0, empty output). Don't fail; the user may have deliberately omitted unneeded hooks.
- **`.stride_lite.md` hook section exists but the fenced bash block is empty** — same as missing: no-op, proceed.
- **Goal directory missing `goal.md`** — hard error: surface a clear message ("goal_directory_path is not a valid stride-lite goal — no goal.md found") and stop.
- **Goal directory has no taskN.md files** — hard error: surface a clear message and stop. The workflow needs at least task1.md to do anything.
- **Goal directory has task1.md and task3.md but no task2.md** — hard error per Step 1's gap-handling rule. Surface the gap and stop.
- **Every taskN.md already has `## Completion Summary`** — log "goal already complete" and stop. Do NOT re-run after_goal (the goal has already been wrapped up in a prior session).
- **task-explorer agent dispatch fails or returns an error** — surface the explorer's error and stop. The explorer's findings are a prerequisite for high-quality implementation.
- **task-reviewer agent dispatch fails or returns an error** — surface the reviewer's error and stop. Without a review verdict, the workflow can't decide Step 7.
- **task-reviewer's `## Review Report` has no fenced JSON block** — fall back to prose-substring matching per Step 7's JSON parse fallback. Conservative default on ambiguity: treat as `changes_requested`.
- **Review-loop exhausts max_review_iterations** — stop without writing the Completion Summary. The task file retains its latest `## Review Report` section as the audit trail. The user can manually fix the issues and re-run the workflow; on re-run the task is "incomplete" (no Completion Summary) so Step 1 picks it up again.
- **after_goal hook fails after goal.md Completion Summary is written** — surface the failure but do NOT roll back the goal.md mutation. The user can re-run the after_goal hook manually (e.g., by inspecting `.stride_lite.md` and running the commands directly).

## Concrete walkthrough

A two-task goal at `docs/implementation/PENDING/add-notifications/` containing `goal.md`, `task1.md`, `task2.md`, and a `.stride_lite.md` in the project root with all three hook sections populated. The workflow proceeds:

**Iteration 1 — task1.md (Emit PubSub broadcast on comment insert).**

- **Step 1.** Scan goal dir. task1.md has no `## Completion Summary` → next task is task1.md.
- **Step 2.** Read `.stride_lite.md` `## before_task` section. Execute the bash (e.g., `git pull origin main`). Capture exit_code=0, output, duration_ms=2400. Proceed.
- **Step 3.** Dispatch `stride-lite:task-explorer` with `task1.md` as the prompt. After ~30s the agent appends a `## Exploration Report` section to task1.md covering File state per key_file, Pattern matches (Kanban.Boards.create_board broadcast at boards.ex:42), Related tests (test/kanban/comments_test.exs), Implementation notes (use Kanban.PubSub, follow with-chain placement).
- **Step 4.** Implement the broadcast. Modify `lib/kanban/comments.ex` (add Phoenix.PubSub.broadcast inside the success arm) and `test/kanban/comments_test.exs` (subscriber test).
- **Step 5.** Read `.stride_lite.md` `## after_task` section. Execute the bash (e.g., `mix test` and `mix credo --strict`). Capture exit_code=0, duration_ms=18000. Proceed.
- **Step 6.** Dispatch `stride-lite:task-reviewer` with `task1.md` as the prompt. After ~25s the agent appends a `## Review Report` section. The embedded JSON's `status` is `approved`.
- **Step 7.** Parse the JSON. `status == approved` → proceed to Step 8.
- **Step 8.** Append a `## Completion Summary` section to task1.md (one-paragraph synthesis + hook results + review status). Check for task2.md: exists. Return to Step 1.

**Iteration 2 — task2.md (Subscribe to comment broadcasts in BoardLive.Show).**

- **Step 1.** Scan again. task1.md now has `## Completion Summary` → skip. task2.md has no `## Completion Summary` → next task is task2.md.
- **Step 2–7.** Same pattern. The reviewer first returns `changes_requested` (the BoardLive subscribe wasn't filtering by board_id). The workflow loops back to Step 4 (iteration 1 of the review-loop), the implementation is fixed, Step 5/6/7 re-run, the reviewer now returns `approved` (iteration 2 — under the cap). Proceed to Step 8.
- **Step 8.** Append `## Completion Summary` to task2.md. Check for task3.md: does NOT exist. This was the final task.
- **Step 8 (continued).** Append `## Completion Summary` to `goal.md` with the goal-level synthesis: "Real-time notifications shipped via 2-task split — broadcast emission in the context module (task1), LiveView subscription in BoardLive.Show (task2). Both tasks reviewed and approved. All hooks completed cleanly."
- **Step 8 (final).** Execute `.stride_lite.md` `## after_goal` section. If it succeeds, workflow complete. If it fails, surface the failure — goal.md's Completion Summary remains; user re-runs the hook manually.

**End state.** Both taskN.md files have full lifecycle sections (Description → ... → Exploration Report → Review Report → Completion Summary). goal.md has a `## Completion Summary` at EOF. The user can navigate the goal directory and see exactly what happened, in order, in each file.

## Red flags — STOP

If you catch yourself thinking any of these, go back to the documented step:

- **"This task is small — I'll skip the explorer dispatch in Step 3."** No. The explorer is part of the documented loop; every task gets it. The explorer's findings inform Step 4's implementation, and skipping it produces lower-quality code reviews in Step 6.
- **"The reviewer's `changes_requested` looks minor — I'll write the Completion Summary anyway."** No. The Step 7 contract is binary: `approved` proceeds, anything else loops back. Bypassing the loop defeats the safeguard.
- **"The after_task hook failed but it's just a flaky test — let me skip and complete the task."** No. Blocking failures must stop the workflow. Fix the root cause (in the user's `.stride_lite.md`) and re-run.
- **"`.stride_lite.md` doesn't exist, I'll skip the hooks but write Completion Summaries anyway."** Yes, this is actually correct — no `.stride_lite.md` is a valid reduced-functionality configuration. But surface a warning so the user knows the hooks were skipped.
- **"The review-loop has hit 3 iterations but the reviewer keeps finding the same issue — I'll force-approve."** No. Stop, surface the unresolved issue, and let the user intervene. Forcing approval defeats the entire review-loop purpose.

## Pitfalls

- **Don't write code in Steps 1, 2, 3, 5, 6, 7, or 8.** Only Step 4 is implementation; the others are orchestration. Mixing concerns produces ambiguous task files.
- **Don't dispatch task-explorer or task-reviewer with parameters other than the task file path.** Both have file-based contracts; they read the file, mutate the file, return nothing structured to you. Treat them as black boxes invoked by path.
- **Don't read or modify `goal.md` in Step 1 — only the taskN.md files determine the next task.** The goal.md is for the human reader; the workflow ignores it until Step 8's final-task wrap-up.
- **Don't execute the after_goal hook except on the final task.** Step 8's final-task detection (task(K+1).md doesn't exist) is the only trigger.
- **Don't mutate goal.md or taskN.md beyond the documented append-only summaries.** Everything above the appended `## Completion Summary` section stays byte-equivalent across workflow runs.
- **Don't fail silently on hook errors.** Blocking failures must surface a clear error and stop the workflow.
- **Don't expand the Bash scope beyond the explicit ✅ list.** If you need a non-allowed command, surface the limitation and stop; let the user add it to `.stride_lite.md` if they want it part of the workflow.
- **Don't loop forever in Step 7.** The `max_review_iterations` cap (default 3) is mandatory. After the cap, stop with the failing review surfaced.
- **Don't conflate "task-explorer error" with "implementation error".** Step 3 has its own failure mode (the agent surfaces an error); Step 4's implementation is on you. Surface explorer errors and stop; don't proceed to a Step 4 without exploration findings.
- **Don't introduce a new slash command in this skill.** Invocation is via the Skill tool only — same pattern as `stride:stride-workflow`. If a command surface is wanted, it's a follow-up release.
- **Don't read user-supplied hook commands as anything other than verbatim bash.** Do not pre-validate them, do not "sanitize" them. The user owns `.stride_lite.md` content; if they put a destructive command there, the workflow will execute it. That's a user responsibility, not a skill safety net.
