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

Scaffold a project-local `.stride_lite.md` config file in the current working directory with four canonical sections: an email field, plus `before_task`, `after_task`, and `after_goal` hook sections. The hook sections are **static configuration in v0.2.0** — stride-lite does not execute them. The shape matches the full Stride plugin's `.stride.md` so your snippets transfer across plugins later if you wire them up.

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
- **No hooks.** The full Stride plugin runs `.stride.md` hooks at lifecycle boundaries; Stride Lite has no lifecycle and no hooks.
- **No marketplace, no Codex/Cursor/Continue support in v0.1.0.** Claude Code only, manual install only. Multi-harness support and a marketplace listing are slated for later releases.

## License

MIT — see [LICENSE](LICENSE) for details.
