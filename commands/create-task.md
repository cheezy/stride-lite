---
description: Turn a free-text prompt plus an optional requirements directory into a single written task markdown file at `<output-dir>/tasks/<slug>.md` — rendered with the same per-task template as `/stride-lite:create-goal`. Never POSTs to any API. Defaults `--requirements-dir` to `docs/requirements` and `--output-dir` to `docs/implementation/PENDING`.
allowed-tools: Bash(mkdir:*), Bash(test:*), Bash(. *:*), Bash(bash:*), Read, Write, Skill, Agent
argument-hint: "<prompt> [--requirements-dir <path>] [--output-dir <path>]"
---

# /stride-lite:create-task

Drive the single-task flow for the stride-lite plugin: parse the invocation, load any requirements text, dispatch the `create-decomposer` subagent in `mode=task`, slugify the task title, resolve a unique file path under `<output-dir>/tasks/`, and write one `<slug>.md` file. The orchestration — including the validation gate that catches a `kind: goal` contract violation before any file write — lives in `skills/stride-lite-create-task/SKILL.md`. This command is the surface: it parses `$ARGUMENTS` and invokes the skill.

## What to do

Follow these steps in order. Do NOT skip steps.

### Step 1: Parse `$ARGUMENTS`

The user invoked you with `$ARGUMENTS`. Hand the unmodified arg string to the `stride-lite-create-task` skill — it runs `lib/parse_args` internally to extract:

- `PROMPT` — the positional argument(s), space-joined
- `REQUIREMENTS_DIR` — value of `--requirements-dir <path>` flag, default `docs/requirements`
- `OUTPUT_DIR` — value of `--output-dir <path>` flag, default `docs/implementation/PENDING`

If `$ARGUMENTS` is empty (no positional prompt), the skill exits non-zero with a usage line via `lib/parse_args`. Do NOT pre-validate or default the prompt at this layer.

### Step 2: Invoke the `stride-lite-create-task` skill

Activate the skill and pass `$ARGUMENTS` through verbatim. The skill walks all seven flow steps documented in `skills/stride-lite-create-task/SKILL.md`:

1. `lib/parse_args` — extract prompt + flags
2. `lib/load_requirements_dir` — read the requirements directory (non-fatal when missing)
3. Dispatch `create-decomposer` in `mode=task` (validation gate rejects `kind: goal` responses)
4. `lib/slugify` — normalize the task title
5. `lib/resolve_output_path` with `kind=file, ext=md`, base = `<output-dir>/tasks` — produce a unique `<output-dir>/tasks/<slug>.md`
6. Render the task markdown using the same template as `/stride-lite:create-goal`
7. Print the final file path

### Step 3: Surface the result

Pass the skill's final stdout to the user verbatim. The skill prints the resolved file path — that is the entire output. The command does NOT add a summary, ask follow-up questions, or chain into another tool.

## Defaults

| Flag | Default |
|---|---|
| `--requirements-dir` | `docs/requirements` |
| `--output-dir` | `docs/implementation/PENDING` |

The full resolved single-task output path with both defaults is `docs/implementation/PENDING/tasks/<slug>.md` — a sibling of any goal directories produced by `/stride-lite:create-goal`.

## What this command does NOT do

- **No business logic in this file.** All decomposition, validation, slugification, path resolution, and rendering happens in `skills/stride-lite-create-task/SKILL.md` and the `lib/` helpers it invokes.
- **Never POSTs to the Stride API.** The output is one markdown file on disk.
- **Never writes to `<output-dir>/<slug>/`** (the goal-flow shape). The single-task output is always `<output-dir>/tasks/<slug>.md`.
- **Never overwrites an existing task file.** `resolve_output_path` suffixes `-2`, `-3`, ... on collision.
- **Never asks the user mid-flow** — the prompt and the requirements directory are the entire input.
