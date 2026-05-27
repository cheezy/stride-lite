# Changelog

All notable changes to **Stride Lite** are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.9.0] — 2026-05-27

### Added

- **`hooks/hooks.json`** — Claude Code PreToolUse/PostToolUse handler registration. Registers a single command (`${CLAUDE_PLUGIN_ROOT}/hooks/stride-lite-hook.sh`) under a `PreToolUse` matcher on `Agent` and `PostToolUse` matchers on `Edit` and `Write`. The shell script handles cross-platform delegation internally (mirror of `stride/hooks/hooks.json`'s wrapper-script pattern — no per-entry OS conditionals, no duplicate platform-tagged entries).
- **`hooks/stride-lite-hook.sh`** — POSIX bash executor for macOS/Linux (and Git Bash / WSL on Windows). Reads the Claude Code hook JSON from stdin, accepts `pre` or `post` as the phase argument, parses `tool_name` / `tool_input.subagent_type` / `tool_input.file_path` via pure bash (no jq dependency), and dispatches to one of three `.stride_lite.md` sections:
  - PreToolUse + `tool_name == Agent` + `subagent_type == stride-lite:task-explorer` → `## before_task` (blocking, returns exit 2 on failure)
  - PreToolUse + `tool_name == Agent` + `subagent_type == stride-lite:task-reviewer` → `## after_task` (blocking, returns exit 2 on failure)
  - PostToolUse + `tool_name in (Edit, Write)` + `file_path` ends in `goal.md` + body contains `## Completion Summary` → `## after_goal` (advisory; returns exit 0 even on failure since PostToolUse cannot roll back the write)
  Emits single-line structured JSON to stdout (success: `{hook, status, commands_completed, duration_seconds}`; failure: `{hook, status, failed_command, command_index, exit_code, stdout, stderr, commands_completed, commands_remaining}`). Silently no-ops on missing `.stride_lite.md`, missing section, empty fenced block, or non-trigger tool calls.
- **`hooks/stride-lite-hook.ps1`** — PowerShell 5.1+ executor for native Windows, behavior-equivalent to `stride-lite-hook.sh`. Mirrors the same three trigger conditions, the same JSON output shape (via `ConvertTo-Json -Compress`), and the same exit-code contract (exit 2 on PreToolUse failure / exit 0 on PostToolUse always). Parses JSON via the built-in `ConvertFrom-Json` (no module installs) and shells out to `bash -c` for each user command line so `.stride_lite.md` hook content remains POSIX-portable. `stride-lite-hook.sh` auto-delegates to this script on native Windows (OSTYPE unset + COMSPEC set).
- **Cross-platform from day one.** Both `.sh` and `.ps1` are authored in the same release. Windows users get a working install without a follow-up patch.

### Changed

- **`stride-lite-workflow` SKILL.md** Steps 2, 5, and the after_goal sub-step of Step 8 amended: the workflow skill body no longer reads or executes `.stride_lite.md` hook sections directly. The harness auto-fires them at the corresponding `Agent` / `Edit` / `Write` tool calls. The `## Hook execution contract` section is rewritten to document the auto-fire trigger table; the `## Bash scope` ✅ list drops the "hook execution" bullet. The eight-step structure (`### Step 1` through `### Step 8`) is preserved verbatim.
- **README.md** Workflow section extended with a "Cross-platform hook enforcement" subsection documenting the trigger table and the Windows-delegation path. The `/stride-lite:init` blurb updated to reflect harness-enforced auto-fire (no longer "executed by the workflow skill").
- **AGENTS.md** repository layout block adds a `hooks/` entry with all three files. The project-overview paragraph updated to mention the v0.9.0 enforcement layer. The previously documented "red flag — stride-lite hooks live in .stride_lite.md ... not as a separate orchestration tier" hard rule under "What NOT to add" is rewritten to describe the new harness-enforced model.

### Notes

- **Behavior parity between `.sh` and `.ps1`** is the v0.9.0 invariant. Both scripts must detect the same three trigger conditions, emit byte-equivalent JSON for the same input + `.stride_lite.md` content, and apply the same exit-code contract. Divergence is the failure mode the cross-platform contract is built to prevent.
- **No JSON parser dependency on `.sh`** — pure bash grep/sed/parameter-expansion JSON parsing. `.ps1` uses the built-in `ConvertFrom-Json` / `ConvertTo-Json` (no module installs).
- **`.stride_lite.md` template shape unchanged.** The init skill's canonical template still emits the four sections (`## email`, `## before_task`, `## after_task`, `## after_goal`) in the same order with the same empty fenced bash blocks. Existing `.stride_lite.md` files continue to work without modification — the only change is that the hooks now auto-fire.
- **No changes to existing agents.** `agents/create-decomposer.md`, `agents/task-explorer.md`, and `agents/task-reviewer.md` are byte-equivalent to their v0.8.0 state. The harness intercepts the Agent dispatch from outside the agent — it does not modify the agent contracts.
- **v0.4.0 per-task template byte-parity preserved.** This release does not modify either `stride-lite-create-goal/SKILL.md` or `stride-lite-create-task/SKILL.md`; the parity diff still returns empty.
- **Smoke test unchanged.** `test/smoke.sh` does not assert on hooks, skills, agents, or the plugin manifest, so v0.9.0 ships without modifying the test — it continues to exit 0 with `24 passed, 0 failed`. Cross-platform behavioral parity between `.sh` and `.ps1` is verified manually via the integration-test list in the W916 testing strategy; a dedicated test suite (`test-stride-lite-hook.sh` + `test-stride-lite-hook.ps1`) is out of scope for this release and can follow in a later patch.
- **`hooks/` is not on the canonical-pattern red-flag list anymore.** The "What NOT to add" block in AGENTS.md previously called it out as a red flag; the v0.9.0 enforcement layer is the principled exception that explicitly addresses why the layer is wanted (harness-enforced enforcement that survives skill amendments).
- **PostToolUse advisory semantics for `after_goal`.** A failing `## after_goal` hook emits the structured failure JSON but does NOT block — the `goal.md` write has already happened and cannot be rolled back. The user can inspect the failure JSON and re-run the hook manually if desired.

[0.9.0]: https://github.com/cheezy/stride-lite/releases/tag/v0.9.0

## [0.8.0] — 2026-05-27

### Added

- **`stride-lite-workflow` orchestrator skill** at `skills/stride-lite-workflow/SKILL.md` — the file-based equivalent of the full Stride plugin's `stride-workflow`. Takes a goal-directory path as input and walks the goal through an eight-step task lifecycle: (1) select next incomplete task (first `taskN.md` without `## Completion Summary`), (2) execute `## before_task` hook from `.stride_lite.md`, (3) dispatch `stride-lite:task-explorer`, (4) implementation, (5) execute `## after_task` hook, (6) dispatch `stride-lite:task-reviewer`, (7) review-loop decision (approved → proceed; changes_requested → loop back to step 4, capped at **3 iterations** by default via the optional `max_review_iterations` input), (8) append `## Completion Summary` to the task file; if this was the final task, also append `## Completion Summary` to `goal.md` and execute the `## after_goal` hook.
- **Invocation surface: Skill tool** with `skill: stride-lite-workflow` and the goal-directory path as input. No new slash command in this release — matches the full Stride plugin's `stride-workflow` invocation pattern.
- **Hook execution contract** documented in the skill body: read `.stride_lite.md` from the project root, locate `## before_task` / `## after_task` / `## after_goal` sections, parse the fenced bash block, execute each line one at a time via Bash, capture aggregated exit_code/output/duration_ms, treat any non-zero exit on blocking hooks as a hard stop.

### Changed

- **BREAKING (contract semantics, not file shape):** The v0.2.0 init contract previously declared `.stride_lite.md` hooks "static configuration — stride-lite does NOT execute them". As of v0.8.0, the `stride-lite-workflow` skill DOES execute the three hooks at the corresponding lifecycle points. The `.stride_lite.md` file shape itself remains byte-equivalent (same four sections: `## email`, `## before_task`, `## after_task`, `## after_goal`), so existing files continue to work — but commands in the hook sections now run when the workflow skill is invoked. Users who put placeholder content there during v0.2.0–v0.7.0 should review their `.stride_lite.md` before invoking `stride-lite-workflow` for the first time.
- **stride-lite-init SKILL.md** language updated to reflect the new contract: the init skill itself remains a pure scaffolder (it writes the file and exits, executing nothing), but its description, NOT-do block, success-message template, canonical template intro, and pitfalls section no longer claim the hooks are "static config — not executed by stride-lite". The new language cross-references `stride-lite-workflow` as the executor.
- **README.md and AGENTS.md** project-overview language updated: the previous "no hooks" / "no lifecycle" claims now read as "no server-mediated lifecycle" with explicit notes that the workflow skill executes `.stride_lite.md` hooks inline against the file tree.

### Notes

- **No new slash command.** The workflow skill is dispatched via the Skill tool directly. A `/stride-lite:work <path>` command surface may follow in a future release if it earns its complexity.
- **No changes to existing agents.** `agents/create-decomposer.md`, `agents/task-explorer.md`, and `agents/task-reviewer.md` are byte-equivalent to their v0.7.0 state. The workflow skill consumes them via Claude Code's Agent tool — it does not amend their contracts.
- **v0.4.0 per-task template byte-parity preserved.** This release does not modify either `stride-lite-create-goal/SKILL.md` or `stride-lite-create-task/SKILL.md`; the parity diff still returns empty.
- **Smoke test unchanged.** `test/smoke.sh` does not assert on skills or the workflow surface, so v0.8.0 ships without modifying the test — it continues to exit 0 with `24 passed, 0 failed`.
- **Bash scope** for the workflow skill follows the v0.7.0 task-reviewer's discipline: explicit ✅ list (hook execution, `git rev-parse --show-toplevel`, `ls`/`test -f`/`find` for directory navigation) and ❌ list (no `mix`/`npm`/`cargo`, no `curl`/`wget`/`nc`, no mutating git). User-supplied hook commands in `.stride_lite.md` are executed verbatim — the user is responsible for their content.

[0.8.0]: https://github.com/cheezy/stride-lite/releases/tag/v0.8.0

## [0.7.0] — 2026-05-27

### Added

- **`stride-lite:task-reviewer` subagent** at `agents/task-reviewer.md` — reviews code changes against a stride-lite task markdown file's acceptance criteria, pitfalls, patterns, and testing strategy. Takes the task-file path plus an optional `diff_range` (defaults to `HEAD` = working-tree vs HEAD), captures the diff via `git diff <range>`, evaluates each acceptance criterion against the diff (met / not_met with file:line evidence), checks pitfall avoidance and pattern compliance and testing-strategy coverage, categorizes findings as Critical / Important / Minor, and appends a `## Review Report` section to the bottom of the input file with a prose summary line, the issue list, a per-acceptance-criterion table, and an embedded structured JSON block matching stride's `reviewer_result` schema (schema_version `"1.1"`) for downstream tooling.
- **Re-run semantic: replace in place.** Identical 3-state logic to the v0.6.0 task-explorer (State A append / State B replace / State C refuse), scoped to the `## Review Report` heading. No duplicate sections, no numeric discriminators.
- **Invocation surface: Claude Code `Agent` tool with `subagent_type: stride-lite:task-reviewer`** and the task-file path (plus optional diff range) as the prompt. No new slash command or surface skill — same dispatch pattern as the v0.6.0 task-explorer.

### Notes

- **Convention with task-explorer:** run `stride-lite:task-explorer` FIRST (during planning, before implementation) and `stride-lite:task-reviewer` LAST (after implementation). Both reports can coexist on the same task file — Exploration above, Review at the bottom. If the order is reversed (reviewer first, explorer second), the v0.6.0 task-explorer's "always last" contract will refuse to mutate; recover by manually removing the Review Report and re-running explorer.
- **Bash scope.** task-reviewer is the first stride-lite agent with `Bash` in its tool list — required for `git diff` / `git log`. The agent body explicitly scopes Bash to read-only git operations only: no `mix`, `npm`, `cargo`, `curl`, `wget`, no mutating git commands (`commit`/`push`/`checkout`/`reset`). The body documents both ✅ and ❌ examples to prevent scope creep.
- **No-network and file-mutation-scoped contracts preserved.** The agent does NOT have WebFetch. `Edit` and `Write` target ONLY the input task file path — no traversal, no mutations elsewhere.
- **v0.6.0 task-explorer unchanged.** The two-agent interaction is documented in the new agent's body, not enforced by retrofitting the prior contract. `agents/task-explorer.md` is byte-equivalent to its v0.6.0 state in this release.
- **Per-task template byte-parity preserved.** This release does not modify either SKILL.md; the v0.4.0 invariant that the two per-task template blocks are byte-equivalent still holds.
- **Smoke test unchanged.** `test/smoke.sh` does not assert on agents, so v0.7.0 ships without modifying the test — it continues to exit 0 with `24 passed, 0 failed`.

[0.7.0]: https://github.com/cheezy/stride-lite/releases/tag/v0.7.0

## [0.6.0] — 2026-05-27

### Added

- **`stride-lite:task-explorer` subagent** at `agents/task-explorer.md` — enriches a generated task markdown file with concrete codebase context. Takes the task-file path as input, parses the `## Key files`, `## Patterns to follow`, `## Where`, and `## Testing strategy` sections, runs read-only codebase exploration (Read each key_file, Grep for patterns, Glob for related tests), and appends an `## Exploration Report` section to the bottom of the input file with findings organized as File state per key_file, Pattern matches, Related tests, and Implementation notes.
- **Re-run semantic: replace in place.** Dispatching the agent against a file that already has an `## Exploration Report` section REPLACES that section in place (slice from the heading through EOF, overwrite with freshly-generated content). No duplicate sections, no numeric discriminators like `## Exploration Report 2`. If the existing heading is NOT at the last position (the user manually added content below it after a prior run), the agent refuses to mutate and surfaces a clear error rather than guessing the slice boundary.
- **Invocation surface: Claude Code `Agent` tool with `subagent_type: stride-lite:task-explorer`** and the task-file path as the prompt. No new slash command or surface skill in this release — the agent is dispatched directly. A `/stride-lite:explore-task <path>` command surface may follow in a future release if it earns its complexity.

### Notes

- **Append-only, file-scoped mutation.** The agent's `Edit` and `Write` tools target ONLY the input task file path. No traversal, no edits elsewhere in the filesystem. Sections of the task file above the `## Exploration Report` remain byte-equivalent across runs.
- **No new network or code-execution surface.** The agent's tool list is `Read, Grep, Glob, Edit, Write` — no Bash, no WebFetch.
- **Per-task template byte-parity preserved.** This release does not modify either `stride-lite-create-goal/SKILL.md` or `stride-lite-create-task/SKILL.md`; the v0.4.0 invariant that the two per-task template blocks are byte-equivalent still holds (diff returns empty).
- **Smoke test unchanged.** `stride-lite/test/smoke.sh` does not assert on agents, so v0.6.0 ships without modifying the test — it continues to exit 0 with `24 passed, 0 failed`.

[0.6.0]: https://github.com/cheezy/stride-lite/releases/tag/v0.6.0

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
