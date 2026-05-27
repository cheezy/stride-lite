# Stride Lite — Agent Guidelines

Project guidelines for AI agents working **on** the Stride Lite plugin codebase (not for agents *using* the plugin's commands — that audience is served by the surface skills' SKILL.md files).

## What this plugin is

A Claude Code plugin that turns a free-text prompt plus an optional requirements directory into Stride-shaped markdown documents on disk. Two slash commands (`/stride-lite:create-goal`, `/stride-lite:create-task`), one subagent (`create-decomposer`), four `lib/` helpers, and zero API calls. The lifecycle is bounded: parse args → load requirements → dispatch decomposer → render markdown → write files. There is no kanban server, no claim/complete loop, no hooks.

## Repository layout

```
stride-lite/
  .claude-plugin/plugin.json    ← plugin manifest (name, version, license)
  commands/
    create-goal.md              ← /stride-lite:create-goal slash command shell
    create-task.md              ← /stride-lite:create-task slash command shell
    init.md                     ← /stride-lite:init slash command shell
  skills/
    stride-lite-create-goal/SKILL.md   ← goal-flow orchestrator
    stride-lite-create-task/SKILL.md   ← single-task-flow orchestrator
    stride-lite-init/SKILL.md          ← .stride_lite.md scaffold flow (no hook execution)
  agents/
    create-decomposer.md        ← subagent: prompt + requirements + mode → fenced YAML
  lib/
    parse_args.md               ← extract prompt + --requirements-dir + --output-dir
    load_requirements_dir.md    ← read a directory, concatenate text files
    slugify.md                  ← normalize a title into a filesystem-safe slug
    resolve_output_path.md      ← produce a unique <base>/<slug>(.<ext>)? path
  README.md                     ← user-facing intro and command reference
  AGENTS.md                     ← this file
  LICENSE                       ← MIT
```

All `lib/*.md` files document a single pure helper with a Contract table, Spec/Rules, Reference Implementation (bash), Examples, and Edge Cases. The reference implementations are normative — when you ship a runtime that needs an executable helper, transliterate the bash from these docs without renaming functions or changing the exit-code semantics.

## Module boundaries

- **`commands/` files are thin shells.** They parse `$ARGUMENTS` and invoke the matching skill. No decomposition logic, no slugification, no file writes.
- **`skills/<name>/SKILL.md` files orchestrate.** They wire `lib/` helpers and the `create-decomposer` subagent together. They never duplicate logic that lives in `lib/`.
- **`agents/create-decomposer.md` produces structured output.** It receives a prompt, requirements text, and a `mode` flag, and returns a single fenced ```yaml document. It does not call APIs, does not ask the user clarifying questions, and does not have access to a codebase.
- **`lib/*.md` files are pure helpers.** Each documents one function. They have no side effects beyond writing to stdout/stderr.

When extending the plugin, add new helpers under `lib/`, new agents under `agents/`, new skills under `skills/`, and new slash commands under `commands/`. Do not move logic across these boundaries.

## Hard rules for agents working on this codebase

- **Never add Stride API calls.** Stride Lite's contract is "no network." If a feature seems to require an API call, it belongs in the full Stride plugin (`stride/`), not here.
- **Never change the default paths** without coordinating with the README, the slash commands, and both skill files in the same commit. The two defaults are the cross-skill contract:
  - `--requirements-dir` defaults to `docs/requirements`.
  - `--output-dir` defaults to `docs/implementation/PENDING`.
- **Never diverge the task markdown template** between `stride-lite-create-goal/SKILL.md` and `stride-lite-create-task/SKILL.md`. The two skills MUST render task markdown identically. The template is reproduced verbatim in both files so divergence is visible in code review.
- **Never raise the plugin version** without a matching CHANGELOG entry and a plugin.json bump in the same commit.
- **Never list more than 8 child tasks in a goal.** The `create-decomposer` agent enforces this cap; downstream tools (the surface skills) reject decomposer output that violates it.

## Adding a new helper to `lib/`

1. Create `lib/<helper_name>.md` following the existing format: Contract table, Spec/Rules section, Reference Implementation in bash, Examples table, Edge Cases.
2. Document inputs as a table, outputs as a stdout contract (with trailing-newline behavior called out), and exit codes as a table.
3. Pure functions only — no global state, no network, no `mkdir` (callers handle directory creation).
4. Errors go to stderr with a function-name prefix (`<helper_name>: <reason>`).
5. Update `AGENTS.md` (this file) — add the helper to the repository layout block.

## Adding a new slash command

1. Create `commands/<command-name>.md` mirroring `create-goal.md` or `create-task.md` (YAML frontmatter with `description`, `allowed-tools`, `argument-hint`; single-`#` title; `## What to do` with numbered `### Step` subsections; `## Defaults` table; `## What this command does NOT do` block).
2. Create the matching skill at `skills/stride-lite-<command-name>/SKILL.md`. The skill owns the orchestration logic; the command file is a thin shell.
3. Document the command in `README.md` under `## Commands` with at least one copy-paste example.
4. Update `AGENTS.md` (this file) — add the command and skill to the repository layout block.

## Conventions

- **All filenames are kebab-case** (`create-goal.md`, `load_requirements_dir.md`). The exception is `lib/*.md` files, where snake_case mirrors the bash function name they document.
- **Markdown templates use angle-bracket placeholders** (`<task.title>`, `<key_files[0].file_path>`) — these are documentation, not runnable code. Implementing runtimes substitute the values at render time.
- **Empty values render as `(none)`** rather than disappearing from the output. Reviewability is the goal of the markdown layer.
- **Code fences are language-tagged** (`` ```bash ``, `` ```yaml ``, `` ```markdown ``). Untagged fences are reserved for raw output blocks where no language fits.

## What NOT to add

- **No Elixir/Phoenix-specific guidance.** Stride Lite is project-agnostic. The full Stride plugin has Phoenix conventions baked in; this plugin does not.
- **No multi-harness fallbacks.** v0.1.0 is Claude Code only. Adding Codex/Cursor/Continue paths is out of scope until the harness story is settled in a later release.
- **No hooks.** Stride Lite has no lifecycle and therefore no hook surface. A `hooks/` directory would be a red flag.
- **No API client.** A `curl` invocation, a Stride client wrapper, or an HTTP library import is a contract violation. The whole point of this plugin is "no network."
