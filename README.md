# Stride Lite

A lightweight companion plugin to [Stride](https://www.stridelikeaboss.com) — produces Stride-shaped **goal and task markdown documents on disk** from a free-text prompt plus an optional requirements directory. No API calls, no kanban setup, no auth files. Just markdown.

Stride Lite is useful when you want the Stride field discipline (acceptance criteria, key files, pitfalls, testing strategy, dependencies) without committing to the full Stride server workflow. The documents it produces can be reviewed, edited, or later submitted to a real Stride deployment by hand or by tooling — but this plugin never does so itself.

## Installation

Stride Lite v0.1.0 is Claude Code only and ships as a manual install (no marketplace yet).

```bash
git clone https://github.com/cheezy/stride-lite.git ~/dev/stride-lite
```

Then symlink the plugin into your Claude Code plugin directory (or copy if you prefer):

```bash
ln -s ~/dev/stride-lite ~/.claude/plugins/stride-lite
```

Restart Claude Code (or run `/plugin reload`) so the loader picks up the new commands.

After install, two slash commands are available:

- `/stride-lite:create-goal <prompt>` — produces a goal directory with one `goal.md` plus one `taskN.md` per child task.
- `/stride-lite:create-task <prompt>` — produces a single task markdown file.

## Commands

### `/stride-lite:create-goal`

Decomposes a free-text prompt into a goal plus **1–8 child tasks** (capped at 8 — larger initiatives should be split into multiple invocations) and writes them to disk.

```bash
/stride-lite:create-goal "Add real-time notifications for board comments"
```

Output (with both flag defaults):

```
docs/implementation/PENDING/add-real-time-notifications-for-board-comments/
  goal.md
  task1.md
  task2.md
  task3.md
  ...
```

Override the requirements directory:

```bash
/stride-lite:create-goal "Add notifications" --requirements-dir docs/specs
```

Override the output base:

```bash
/stride-lite:create-goal "Add notifications" --output-dir build/goals
```

Both flags together:

```bash
/stride-lite:create-goal "Add notifications" --requirements-dir docs/specs --output-dir build/goals
```

### `/stride-lite:create-task`

Renders a single task — no goal wrapper, no children. Useful for one-off changes that don't warrant a multi-task decomposition.

```bash
/stride-lite:create-task "Fix the typo in the login button label"
```

Output (with both flag defaults):

```
docs/implementation/PENDING/tasks/fix-the-typo-in-the-login-button-label.md
```

The single-task file lives at `<output-dir>/tasks/<slug>.md` — a sibling of any goal directories produced by `/stride-lite:create-goal`. The same flag defaults apply.

### `/stride-lite:init`

Scaffold a project-local `.stride_lite.md` config file in the current working directory with four canonical sections: an email field, plus `before_task`, `after_task`, and `after_goal` hook sections. The hook sections are **executed by the `stride-lite-workflow` skill (v0.8.0+)** at the corresponding lifecycle points: `before_task` at the start of each task iteration, `after_task` after each implementation phase, `after_goal` after the final task in a goal directory wraps up. The shape matches the full Stride plugin's `.stride.md` so your snippets transfer across plugins.

```bash
/stride-lite:init
```

Output:

```
.stride_lite.md
```

Refuses to clobber an existing `.stride_lite.md` unless you pass `--force`:

```bash
/stride-lite:init --force
```

After writing, the command prints a multi-line message listing the four sections to fill in. `/stride-lite:init` is optional — `/stride-lite:create-goal` and `/stride-lite:create-task` work without ever invoking it.

## Flags

| Flag | Default | Description |
|---|---|---|
| `--requirements-dir <path>` | `docs/requirements` | Directory whose contents are concatenated and prepended as context for the decomposer. Missing directories are non-fatal — the decomposer works from the prompt alone and notes the absence in `decomposition_notes`. |
| `--output-dir <path>` | `docs/implementation/PENDING` | Base directory for written artifacts. Goal directories land at `<output-dir>/<slug>/`; single-task files land at `<output-dir>/tasks/<slug>.md`. Collisions are resolved with `-2`, `-3`, ... suffixes — existing files are never overwritten. |

Both flags accept relative or absolute paths. The output base is created with `mkdir -p` if it does not exist.

## Subagents

In addition to the three slash commands, stride-lite ships subagents that you can dispatch directly via Claude Code's `Agent` tool.

### `stride-lite:task-explorer`

Enriches a generated task markdown file with concrete codebase context. The agent takes the task-file path as input, parses the `## Key files`, `## Patterns to follow`, `## Where`, and `## Testing strategy` sections, runs read-only codebase exploration (Read each key_file, Grep for patterns, Glob for related tests), and appends an `## Exploration Report` section to the bottom of the input file with the findings.

Invoke it via Claude Code's `Agent` tool with `subagent_type: stride-lite:task-explorer` and the task-file path as the prompt:

```
Dispatch stride-lite:task-explorer on docs/implementation/PENDING/add-notifications/task1.md
```

After it runs, the input file gains a new `## Exploration Report` section at the bottom containing File state per key_file, Pattern matches, Related tests, and Implementation notes. All prior sections of the task file (Description, Why, What, Where, Acceptance criteria, etc.) remain byte-equivalent to the pre-run state.

**Re-runs replace in place.** Dispatching the agent a second time against the same file does NOT append a duplicate section or use a numeric discriminator like `## Exploration Report 2` — it slices from the existing `## Exploration Report` heading through EOF and overwrites with the freshly-generated content. The contract assumes the report is always the last section in the file; if you've manually added content below it after a prior run, the agent will refuse to mutate and surface a clear error.

### `stride-lite:task-reviewer`

Reviews code changes against a task markdown file's acceptance criteria, pitfalls, patterns, and testing strategy — the equivalent of the full Stride plugin's task-reviewer, adapted for the file-based contract. The agent takes the task-file path (required) plus an optional `diff_range` (defaults to `HEAD` = working-tree vs HEAD), captures the diff via `git diff <range>`, evaluates each acceptance criterion against the diff (met / not_met with file:line evidence), checks pitfall avoidance and pattern compliance and testing-strategy coverage, and appends a `## Review Report` section to the bottom of the input file with a prose summary line, a categorized issue list (Critical / Important / Minor), a per-acceptance-criterion table, and an embedded structured JSON block matching the stride task-reviewer's `reviewer_result` schema for downstream tooling.

Invoke it via Claude Code's `Agent` tool with `subagent_type: stride-lite:task-reviewer` and the task-file path (and optional diff range) as the prompt:

```
Dispatch stride-lite:task-reviewer on docs/implementation/PENDING/add-notifications/task1.md
```

After it runs, the input file gains a new `## Review Report` section at the bottom. All prior sections remain byte-equivalent.

**Re-runs replace in place** — same contract as task-explorer. Dispatching the agent a second time slices from the existing `## Review Report` heading through EOF and overwrites.

**Convention when using both subagents:** run `stride-lite:task-explorer` FIRST (during planning, before implementation) and `stride-lite:task-reviewer` LAST (after implementation). Both reports can coexist on the same file — Exploration above, Review at the bottom. If you reverse the order (reviewer first, explorer second), the explorer's "always last" contract from v0.6.0 will refuse to mutate; remove the Review Report manually and re-run explorer to recover.

**Bash scope:** task-reviewer's tool list includes `Bash` (the only stride-lite agent that has it) so it can run `git diff` / `git log` to capture the change set. Bash is explicitly scoped to read-only git commands only — no `mix test`, `npm run`, `curl`, no mutating git operations (`commit`/`push`/`checkout`/`reset`).

## Workflow

Added in **v0.8.0**, the `stride-lite-workflow` skill is the file-based equivalent of the full Stride plugin's `stride-workflow` orchestrator. It walks a goal directory through the eight-step task lifecycle, executing the hooks from `.stride_lite.md` and dispatching the two existing subagents at the right moments.

Invoke it via Claude Code's Skill tool with the goal-directory path as input:

```
Activate stride-lite-workflow on docs/implementation/PENDING/add-notifications/
```

**The eight-step loop**, run for each incomplete task in the goal directory (numeric `taskN.md` order):

1. **Select the next task** — first `taskN.md` without a `## Completion Summary` section
2. **Run the `## before_task` hook** from `.stride_lite.md` (blocking — non-zero exit stops the workflow)
3. **Dispatch `stride-lite:task-explorer`** against the task file (appends `## Exploration Report`)
4. **Implementation** — the workflow agent makes code changes per the task's acceptance criteria, patterns, and exploration findings
5. **Run the `## after_task` hook** from `.stride_lite.md` (blocking — typically the place for `mix test`, `npm run lint`, etc.)
6. **Dispatch `stride-lite:task-reviewer`** against the task file with the working-tree diff (appends `## Review Report`)
7. **Review-loop decision** — parse the review's status: `approved` → continue; `changes_requested` → loop back to step 4 (capped at **3 iterations** by default; configurable via `max_review_iterations`)
8. **Completion summary** — append `## Completion Summary` to the task file. If this was the final task in the goal (no `task(K+1).md` exists), also append `## Completion Summary` to `goal.md` and run the `## after_goal` hook

The skill never POSTs to any API — it's a file-only orchestrator wrapping the existing surface (create-goal, create-task, init, task-explorer, task-reviewer). See `skills/stride-lite-workflow/SKILL.md` for the full contract.

## Output layout

With both defaults left in place, every invocation lands under `docs/implementation/PENDING/`:

```
docs/
  implementation/
    PENDING/
      add-notifications/         ← goal directory (from /stride-lite:create-goal)
        goal.md
        task1.md
        task2.md
        ...
      refactor-auth/             ← another goal directory
        goal.md
        task1.md
        ...
      tasks/                     ← single-task sibling directory
        fix-typo-login-button.md ← from /stride-lite:create-task
        bump-deps.md
        ...
```

`goal.md` and each `taskN.md` are plain markdown — readable in any editor, reviewable in any PR, diffable in `git log`. The structure mirrors the Stride goal/task field contracts so the docs can be hand-copied (or scripted) into a Stride board later without reformatting.

## What this plugin does NOT do

- **No Stride API calls.** Stride Lite writes markdown to disk. It does not POST, claim, complete, or interact with any kanban server.
- **No `.stride_auth.md` or `.stride.md` required.** Those files are for the full Stride plugin. Stride Lite needs neither.
- **No server-mediated lifecycle.** The full Stride plugin runs `.stride.md` hooks against a kanban server lifecycle (claim → doing → review → done). Stride Lite has no server interaction — but as of v0.8.0 the `stride-lite-workflow` skill DOES execute the three hooks (`before_task`, `after_task`, `after_goal`) from `.stride_lite.md` at the corresponding points in its file-based loop.
- **No marketplace, no Codex/Cursor/Continue support in v0.1.0.** Claude Code only, manual install only. Multi-harness support and a marketplace listing are slated for later releases.

## License

MIT — see [LICENSE](LICENSE) for details.
