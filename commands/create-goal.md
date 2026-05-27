---
description: Turn a free-text prompt plus an optional requirements directory into a written goal directory at `<output-dir>/<slug>/` containing one `goal.md` and one `taskN.md` per child task — rendered as readable markdown that mirrors the Stride goal/task field contracts. Never POSTs to any API. Defaults `--requirements-dir` to `docs/requirements` and `--output-dir` to `docs/implementation/PENDING`.
allowed-tools: Bash(mkdir:*), Bash(test:*), Bash(. *:*), Bash(bash:*), Read, Write, Skill, Agent
argument-hint: "<prompt> [--requirements-dir <path>] [--output-dir <path>]"
---

# /stride-lite:create-goal

Drive the end-to-end create-goal flow for the stride-lite plugin: parse the invocation, load any requirements text from the requirements directory, dispatch the `create-decomposer` subagent in `mode=goal`, slugify the goal title, resolve a unique output directory, and write `<output-dir>/<slug>/goal.md` plus one `taskN.md` per child task. All orchestration logic — including the validation gates that fire BEFORE any file write — lives in `skills/stride-lite-create-goal/SKILL.md`. This command is the surface: it parses `$ARGUMENTS` and invokes the skill.

## What to do

Follow these steps in order. Do NOT skip steps.

### Step 1: Parse `$ARGUMENTS`

The user invoked you with `$ARGUMENTS`. Hand the unmodified arg string to the `stride-lite-create-goal` skill — it runs `lib/parse_args` internally to extract:

- `PROMPT` — the positional argument(s), space-joined
- `REQUIREMENTS_DIR` — value of `--requirements-dir <path>` flag, default `docs/requirements`
- `OUTPUT_DIR` — value of `--output-dir <path>` flag, default `docs/implementation/PENDING`

If `$ARGUMENTS` is empty (no positional prompt), the skill exits non-zero with a usage line via `lib/parse_args`. Do NOT pre-validate or default the prompt at this layer — the skill owns the contract.

### Step 2: Invoke the `stride-lite-create-goal` skill

Activate the skill and pass `$ARGUMENTS` through verbatim. The skill walks all seven flow steps documented in `skills/stride-lite-create-goal/SKILL.md`:

1. `lib/parse_args` — extract prompt + flags
2. `lib/load_requirements_dir` — read the requirements directory (non-fatal when missing)
3. Dispatch `create-decomposer` in `mode=goal`
4. `lib/slugify` — normalize the goal title
5. `lib/resolve_output_path` with `kind=dir` — produce a unique `<output-dir>/<slug>/`
6. Render `goal.md` plus one `taskN.md` per child task
7. Print the final directory path

### Step 3: Surface the result

Pass the skill's final stdout to the user verbatim. The skill prints the resolved directory path and the file list — that is the entire output. The command does NOT add a summary, ask follow-up questions, or chain into another tool.

## Defaults

| Flag | Default |
|---|---|
| `--requirements-dir` | `docs/requirements` |
| `--output-dir` | `docs/implementation/PENDING` |

With both defaults the goal directory lands at `docs/implementation/PENDING/<slug>/` — sibling to any `docs/implementation/PENDING/tasks/<slug>.md` files produced by `/stride-lite:create-task`.

## What this command does NOT do

- **No business logic in this file.** All decomposition, validation, slugification, path resolution, and rendering happens in `skills/stride-lite-create-goal/SKILL.md` and the `lib/` helpers it invokes.
- **Never POSTs to the Stride API.** The output is markdown on disk; the user chooses any follow-up.
- **Never overwrites an existing goal directory.** `resolve_output_path` handles collisions by suffixing `-2`, `-3`, ...
- **Never asks the user mid-flow** — the prompt and the requirements directory are the entire input. If they are insufficient the decomposer subagent makes conservative choices and notes the assumption in `decomposition_notes`.
