# Changelog

All notable changes to **Stride Lite** are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.5.0] — 2026-05-27

### Changed

- **BREAKING:** Goal render template stripped. The `goal.md` blockquote header line (`> Type: goal · Complexity: <c> · Priority: <p> · needs_review: <r>`) and the entire `## Where` section have been removed from the rendered goal output. The new section order is `# <title>` → `## Why` → `## What` → `## Description` → `## Acceptance criteria` → `## Pitfalls` → `## Decomposition notes` → `## Tasks`. Rationale: `type` is implied by the file's location (`goal.md`), `complexity`/`priority` are project-management metadata that don't help the goal audience, `needs_review` is set by humans at column-move time (same logic as the v0.4.0 task-level removal), and `where_context` is more usefully captured per-task.
- **BREAKING:** `create-decomposer` agent YAML schema for the goal object stripped. The keys `type`, `complexity`, `priority`, `needs_review`, and `where_context` are no longer emitted inside the `goal:` object in `kind=goal` output. The Goal fields table in the schema doc now lists exactly six fields: `title`, `why`, `what`, `description`, `acceptance_criteria`, `pitfalls` (plus the nested `tasks:` array). The `kind: goal` discriminator at the YAML root is unchanged — that's the calling skill's renderer dispatch, distinct from the now-removed `type: goal` field inside the goal object.

### Notes

- **Per-task template untouched.** The v0.4.0 byte-equivalence between the per-task templates in `stride-lite-create-goal/SKILL.md` and `stride-lite-create-task/SKILL.md` is preserved — the diff still returns empty post-change.
- **`decomposition_notes` and `## Tasks` preserved.** These goal-level sections were not in the removal scope and remain useful signal for reviewers navigating the goal directory.
- **Smoke test untouched.** `stride-lite/test/smoke.sh` doesn't assert on the goal template shape (it covers only the four `lib/` helpers and the `.stride_lite.md` init template), so it continues to exit 0 with `24 passed, 0 failed`.

[0.5.0]: https://github.com/cheezy/stride-lite/releases/tag/v0.5.0

## [0.4.0] — 2026-05-27

### Changed

- **BREAKING:** Per-task render template rework. The `needs_review` header attribute and the `## Dependencies` section have been removed from the rendered `taskN.md` shape — `needs_review` is set by humans at column-move time in real Stride and `dependencies` is not meaningfully expressible in a single-task surface. In their place, four operationally-substantive sections are now rendered: `## Security considerations`, `## Integration points`, `## Technology requirements`, `## Logging requirements`. Each renders the corresponding source list as a bullet block, with `- (none)` when empty per the existing empty-value contract.
- **BREAKING:** `create-decomposer` agent YAML schema rework. The `needs_review` and `dependencies` keys are no longer emitted on tasks. Four new task-level keys are emitted instead: `security_considerations`, `integration_points`, `technology_requirements`, `logging_requirements` — each a YAML list of strings. The four new keys MUST be present (empty lists allowed); missing keys are rejected by the calling skill's validation gate.
- Validation gates in both `stride-lite-create-goal` and `stride-lite-create-task` SKILL.md files updated to match the new schema — `dependencies` is no longer required, `needs_review: true` is no longer forbidden (the field is simply gone), and the four new operational keys are now required-as-keys (values may be empty lists).
- The two per-task template blocks (in `stride-lite-create-goal/SKILL.md` and `stride-lite-create-task/SKILL.md`) are now strictly byte-equivalent. Prior versions allowed minor placeholder-count drift; v0.4.0 raises the bar — extract both fenced blocks and diff; the diff must be empty.

### Notes

- **Migration:** if you have rendered task markdown from a prior version sitting in `docs/implementation/PENDING/` and you re-run `/stride-lite:create-goal` or `/stride-lite:create-task` against the same prompt, the new output will not match the old shape. The new files land at suffixed paths (`<slug>-2`, `<slug>-3`, ...) per the resolve_output_path contract — no overwrite, no data loss.
- **Goal-level template unchanged.** Only the per-task render shape changed in this release. `goal.md` still renders `needs_review` in the header line and does not (yet) carry the four new operational sections.
- **Smoke test untouched.** `stride-lite/test/smoke.sh` does not assert on the per-task template shape — it covers only the four `lib/` helpers and the `.stride_lite.md` init template — so the change does not require test updates. The test continues to exit 0 with `24 passed, 0 failed`.

[0.4.0]: https://github.com/cheezy/stride-lite/releases/tag/v0.4.0

## [0.3.0] — 2026-05-27

### Changed

- **BREAKING:** `--output-dir` default renamed from `docs/implementation/goals` to `docs/implementation/PENDING`. The new uppercase `PENDING` directory name communicates the lifecycle state of the produced markdown — these are scaffolded plans pending review, not the final implementation target. Users who relied on the prior default and want to keep their existing layout must now pass `--output-dir docs/implementation/goals` explicitly to `/stride-lite:create-goal` and `/stride-lite:create-task`, or move their existing artifacts to the new directory name. Pre-1.0 semver: clean break with no backwards-compat shim.

### Notes

- All authoritative references to the default path (canonical `lib/parse_args.md` spec, both surface skills, both slash-command shells, README, AGENTS, smoke test) were updated in the same commit as the version bump. Historical [0.1.0] and [0.2.0] entries below retain the old default in their text because that's what shipped at those versions.

[0.3.0]: https://github.com/cheezy/stride-lite/releases/tag/v0.3.0

## [0.2.0] — 2026-05-27

### Added

- **`/stride-lite:init`** slash command — scaffolds a project-local `.stride_lite.md` config file in the current working directory containing four canonical sections: an `## email` field plus `## before_task`, `## after_task`, and `## after_goal` hook sections. The hook sections are static configuration in v0.2.0 — stride-lite does not execute them. The format matches the full Stride plugin's `.stride.md` so user snippets transfer across plugins later.
- **`--force` flag** on `/stride-lite:init` — overwrite an existing `.stride_lite.md`. By default the command refuses to clobber, matching `install.sh`'s safety posture.
- **`stride-lite-init` surface skill** at `skills/stride-lite-init/SKILL.md` — owns the canonical template, the collision check, and the post-write success-message contract. The skill never POSTs to any API and never executes the hook sections.

### Notes

- **`/stride-lite:init` is optional.** `/stride-lite:create-goal` and `/stride-lite:create-task` continue to work without ever invoking it.
- **No new hooks are executed.** stride-lite remains a "no lifecycle" plugin in v0.2.0; the four `.stride_lite.md` sections are documentation only. Whether to wire them into a future lifecycle is deliberately deferred.

[0.2.0]: https://github.com/cheezy/stride-lite/releases/tag/v0.2.0

## [0.1.0] — 2026-05-27

Initial release. Claude Code only.

### Added

- **`/stride-lite:create-goal <prompt>`** slash command — decomposes a free-text prompt plus an optional requirements directory into a goal directory at `<output-dir>/<slug>/` containing one `goal.md` and one `taskN.md` per child task (capped at 8 child tasks).
- **`/stride-lite:create-task <prompt>`** slash command — produces a single task markdown file at `<output-dir>/tasks/<slug>.md` using the same per-task template as `/stride-lite:create-goal`.
- **`--requirements-dir <path>` flag** on both commands (default `docs/requirements`). The directory's contents are concatenated and prepended to the decomposer's context; missing directories are non-fatal.
- **`--output-dir <path>` flag** on both commands (default `docs/implementation/goals`). Overrides the base directory under which goal directories and the `tasks/` sibling land. Collisions are resolved by suffixing `-2`, `-3`, ... — existing files are never overwritten.
- **`create-decomposer` subagent** at `agents/create-decomposer.md` — accepts a prompt, requirements text, and a `mode` flag (`goal` or `task`) and returns a single fenced YAML document mirroring the stride-creating-goals and stride-creating-tasks field contracts. Hard-caps goal output at 8 child tasks. Never calls any API.
- **`lib/` helper specs** with bash reference implementations:
  - `lib/slugify.md` — lowercase + replace-non-alphanumeric-with-dash + collapse-runs + trim normalization.
  - `lib/resolve_output_path.md` — unique-path resolver with `-2`/`-3` collision suffixing and a 1000-iteration safety cap; never overwrites.
  - `lib/load_requirements_dir.md` — read-and-concatenate with file-name headers, binary-file skipping, 1 MiB per-file cap, and a non-fatal missing-directory contract.
  - `lib/parse_args.md` — extract prompt + `--requirements-dir` + `--output-dir` with the documented defaults; emits three shell-quoted assignment lines for `eval`.
- **`install.sh` installer** — copies the plugin into `~/.claude/plugins/stride-lite/`. Refuses to clobber an existing install unless `--force` is given.
- **`README.md`** with install instructions, both command references with copy-paste examples, flag documentation, and the output-layout tree.
- **`AGENTS.md`** with codebase-agent guidelines including module boundaries, hard rules, and helper/command extension procedures.

### Notes

- **No Stride API calls.** This plugin writes markdown to disk; the user (or follow-up tooling) chooses any next step.
- **No `.stride_auth.md` or `.stride.md` required.** Those files are for the full Stride plugin.
- **Claude Code only.** Codex, Cursor, and Continue support are out of scope for v0.1.0.
- **Manual install only.** No marketplace listing in v0.1.0; install via `git clone` + `./install.sh` (or a symlink).

[0.1.0]: https://github.com/cheezy/stride-lite/releases/tag/v0.1.0
