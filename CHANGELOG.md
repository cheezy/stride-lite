# Changelog

All notable changes to **Stride Lite** are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed — the failed-verdict `note` rule the server already enforces (D240)

This port's task-reviewer prompt described `note` as optional on every section verdict. The completion API has required it on a `"failed"` verdict since D231, and enforces that **unconditionally** — independently of the `strict_completion_validation` flag — so an agent on this runtime could emit a note-less failed verdict that its own prompt endorsed and be rejected with a `422`. The rejection is self-describing and recoverable, so nothing was broken; every such completion simply paid an avoidable round trip.

The prompt now states that on a `"failed"` section verdict `note` is **REQUIRED** and must name the specific violation or gap in at least **20 non-whitespace characters**, carries the anti-placeholder prohibition (no stub, `TODO`, empty string, or bare restatement of the status), and directs that an empty note means the *verdict* is wrong rather than that the note is unnecessary. `note` stays **optional** on `"passed"` and `"not_assessed"`, so the ordinary empty-section case gains no friction.

Producer-side only: the server-side check in `Kanban.Tasks.CompletionValidation.ReviewContract` is unchanged, and no port was accommodated by weakening it.

## [0.12.0] — 2026-08-06

> This release adds three optional gated sub-steps to the workflow, each dispatching an agent from a **different** plugin. All three are skipped cleanly when that plugin is not installed, and a closed gate never fails a task — so an install without `stride-exploratory-testing` or `stride-security-review` behaves exactly as it did before. The plugin still makes no network request of its own; a dispatch is a local tool call.

### Added — SECURITY.md (W2019)

The plugin executes arbitrary user-authored shell commands from `.stride_lite.md` — the single most security-relevant thing it does — and had no document saying so. `SECURITY.md` now states the trust boundary plainly: the commands come from a file in the user's own repository, run with their privileges, and are never validated, wrapped, escaped or rewritten by the plugin. It also records what the activation marker is **not** — a coordination signal, forgeable by any local process, never an authorization — so no future change leans on it; the three cross-plugin dispatch surfaces and the user-supplied affirmative that gates the riskiest of them; the sanitization applied to every exported env value; and the two known PowerShell divergences, including the honest statement that the `.ps1` executor has **not** been verified on a real Windows host, only driven under `pwsh` on macOS.

### Added — manual & exploratory testing, gated (W2015)

Step 6a maps a task's manual-test entries to charters and dispatches `stride-exploratory-testing:explorer`, one per charter, with an explicit session budget read from the installed agent's own contract rather than hard-coded here. `stride-exploratory-testing:explorer` is the only sanctioned surface: `/explore`, `/pair`, `/recon`, `/nightmare-headline` and the router skill are each forbidden with their own reason, because each can require a human and this workflow never prompts between steps. The authorized-and-non-production affirmative is collected at Step 0 or never — inferring it from a `localhost` URL *is* supplying it on the user's behalf. Step 6b then dispatches `/harden` on confirmed findings; drafts stage outside the test tree and are never reported as passing, because `/harden` holds no test runner.

### Added — deep security-considerations review, gated (W2016)

Step 6c dispatches `stride-security-review:security-reviewer` in explicitly-declared considerations mode and captures one verdict per listed consideration. The mode declaration is load-bearing: the agent assumes `diff` mode when the tag is missing and emits the verdict array only in considerations mode, so an undeclared mode returns a plausible review with no verdicts at all. Fail-closed means a consideration is never dispositioned as `mitigated` on the strength of a verdict set that could not be read — an eight-row anomaly table sends every unreadable shape to Step 7's new security-escalation branch, which reuses the existing `max_review_iterations` cap rather than adding one. A dispatch that fails outright is the one exception: it is a clean skip, because looping on an unavailable third-party agent would let it terminate every task in a goal.

### Added — anti-rationalization scaffolding across all four skills (W2017)

Every skill now carries a Red flags list and a Rationalization Table, and the workflow skill gains a Quick reference card. The rows are written for this plugin's actual failure modes rather than ported from stride, whose tables cite API endpoints, batch root keys and review queues that do not exist here — a table full of irrelevant rows trains agents to skim it. The card indexes the loop by **gating** rather than step order, because gating is the one dimension the loop's own structure cannot express. Two rows are controls rather than prose, and `AGENTS.md` now says so: softening them would weaken a safety property while looking like a copy-edit.

### Added — dedicated hook test suites with a PowerShell mirror (W2018)

`hooks/test-stride-lite-hook.sh` and `hooks/test-stride-lite-hook.ps1` cover what `test/smoke.sh` structurally could not: the section executor's internals, the derivation helpers branch by branch, and the main-flow guards no fixture reached. They get there through the sourcing affordance the hook script has documented since v0.9.0 and which nothing had ever used. The division is by level of access — `test/smoke.sh` owns the subprocess contract, the new suites own function internals — and neither re-asserts the other's cases. The `.ps1`'s section executor is tested for the first time; the stdin defect that blocks an end-to-end run does not block calling a function.

### Fixed — the workflow skill's own claims about the hook environment

The workflow documentation, `README.md` and `AGENTS.md` were swept for statements the preceding tasks made false: the eight-step loop summary now names the three gated sub-steps, the repository layout lists the new files, and the "no multi-harness fallbacks" rule explicitly states that dispatching another *plugin's* agent is not the thing it forbids. The telemetry vocabulary grew from seven names to ten, and every rendering of it — the contract example, three walkthrough iterations, and the README's count — moved together.

### Fixed — the PowerShell executor never received the hook payload at all (D215)

`hooks/stride-lite-hook.ps1` read the hook JSON with `@($input)`, which PowerShell populates only for an internal pipeline. For the OS-level pipe the harness actually uses it was empty, so the script hit its own empty-payload guard and exited 0 without doing anything — the documented hook auto-fire had never worked on the native-Windows path, and because it exits 0 nothing ever reported it.

The read now goes through `[Console]::In`, guarded on `IsInputRedirected` so a terminal cannot hang it, and bounded so a pathological payload is not held whole in memory. The fallback for a PowerShell-internal pipeline is reached via `Get-Variable` rather than by writing `$input`, and that is not stylistic: a **lexical** `$input` token anywhere in the script makes PowerShell treat it as pipeline-consuming, so it attempts parameter binding on the piped object — which both emits "The input object cannot be bound to any parameters" and **consumes stdin before the body runs**. Measured against the original file: it read 0 bytes on every path tried, OS pipe and internal pipeline alike, with or without a positional argument. The premise that an internal-pipeline caller worked and had to be preserved turned out not to hold.

The `[Parameter(Position = 0)]` attribute went too: it made this an *advanced* script, which rejects unbindable pipeline input at binding time — before the body runs — so the internal-pipeline form failed regardless of how stdin was read. A plain positional parameter binds `$Phase` identically and leaves both paths working. A payload above the 1 MiB cap is now refused with a diagnostic on stderr rather than truncated into a parse failure and a silent `exit 0`, which would have reintroduced the very signature this defect removed.

`test/smoke.sh` now drives the whole script as a subprocess for all three routing conditions, the derived environment block, a non-matching payload and an empty one — coverage that was previously a standing SKIP, because the extracted functions could never exercise parameter binding, the stdin read and the routing together, which is exactly where the defect lived.

### Fixed — the PowerShell executor dropped all but the first token of every command (D218)

`hooks/stride-lite-hook.ps1` ran each `.stride_lite.md` command through `Start-Process -FilePath bash -ArgumentList '-c', $cmd`, and `Start-Process` **re-splits** that argument — so `bash` received only the first whitespace-delimited token as its `-c` script and the rest as positional parameters a `-c` script ignores. A `before_task` block of `echo ran > proof.txt` created no file and the section still reported `status: success`. On native Windows, the only platform this file runs on, every multi-word hook command silently did nothing while the workflow recorded the hooks as clean.

Found by the new hook suite's parity stage while implementing W2018: single-token commands like `true` and `false` behave identically under both executors, which is exactly why the JSON comparison passed and why nothing caught this before. Fixed by invoking through PowerShell's call operator — `& bash -c $execTrimmed 1>$out 2>$err` — which passes the variable's contents as one argument without re-parsing, and redirects the child's real streams to files rather than through a .NET pipe the parent must drain. `ProcessStartInfo.ArgumentList` would also have solved the splitting and was rejected on two grounds, both measured rather than assumed: it deadlocks on a chatty command unless the streams are drained asynchronously, and it does not exist in .NET Framework — `stride-lite-hook.sh` delegates specifically to `powershell.exe`, so it would have thrown on the real target. Both suites' D218 skips are now assertions on the observable effect, because the exit codes agreed throughout.

### Fixed — a bullet-list `## Key files` section counted zero and skipped the review (D216)

`lib/select_workflow_branch.md` counted only markdown **table rows** under `## Key files`, so a section written as a bullet list — the shape a hand-written or hand-edited task file usually carries — counted zero. A task naming three real files therefore matched the `small, 0–1 key files` row and resolved to `skip-all`: no explorer, no reviewer, and neither the `before_task` nor the `after_task` hook. The enrichment gate read the very same section correctly as populated, so the two parsers described one section incompatibly, and the task was judged "has key files" (needs no enrichment) and "zero key files" (needs no review) at once.

List items now count alongside table rows — bulleted (`-`, `*`, `+`) and numbered (`1.`, `1)`) alike, since a numbered list is as much a declaration as a bulleted one and a hand-written section is as likely to reach for it. A marker must be followed by a space, so prose opening with a date is not an entry. A bullet's identity is the text before the em dash the form puts between a path and its note, which is what lets the same path dedupe across shapes; with no em dash the **whole** entry is the identity, deliberately, because reducing a sentence-shaped bullet to its first word would collapse two "We modify …" entries onto one and send a two-file task back to `skip-all`. Prose still counts nothing — a bullet is a declaration that a file is a key file, a sentence that happens to name a path is not, and counting sentences would make the branch depend on how wordy the author was. That single remaining divergence from the enrichment gate is now asserted explicitly in `test/smoke.sh` rather than left to drift, alongside the placeholder shapes W2011 and W2012 pinned, which all still count zero in every shape. The gate itself gained the two markers it was missing: it stripped only `-` and `*`, so teaching the matrix about `+` and numbered items would have opened a fresh split — `+ (none)` reading as a placeholder to one parser and as content to the other — in the very change that closed the first one.

### Fixed — a fence-pairing assertion that a balance check could never make (D217)

`agents/task-reviewer.md` wrapped its Review Report shape spec in a three-backtick `markdown` fence containing a three-backtick `json` block. CommonMark forbids an info string on a *closing* fence, so the inner block's terminator legally closed the outer wrapper, the next line opened a fresh anonymous block, and it ran to end of file — the "every subsection MUST appear" rule, the whole append-or-replace contract and the Pitfalls all rendered as sample output rather than as instructions. The fence itself was widened to four backticks during W2016; what was still missing is the assertion that stops it recurring, in this file or any other.

Counting fences cannot be that assertion, and neither can walking for an unterminated one. Both report the defective file **clean**: it carried six fence lines that balanced perfectly while pairing wrongly. The suite now walks fences the way a renderer does and reports two distinct defects — an opener end-of-file never closed, and a fence of the *same width* as the block it sits in that carries an info string, which is the D217 shape exactly and the one a balance check is blind to. A nested fence is legitimate only when the outer one is wider.

The walk covers all 24 tracked markdown files — a superset of the 21 `install.sh` actually ships — in both fence syntaxes, since the same defect written with tildes would otherwise slip through. Exact count guards on both sweeps stop an unmatched glob reporting every file clean, and a paired control on the trailing heading: the four-backtick version renders it as a heading and the three-backtick version swallows it, so the assertion pins what the fence width actually buys rather than merely that the file parses. Verified against the real pre-fix file recovered from git, which the walk flags at the exact line the defect report named.

### Changed — `install.sh` no longer ships the test suites

`hooks/` is copied wholesale, so the two new suites would have landed in every installed plugin as dead weight. They are removed after the copy. `SECURITY.md` is now copied.

### Verification

`test/smoke.sh` more than tenfold its v0.11.0 size, and two new hook suites join it. Deliberately no totals here: the previous draft of this paragraph carried two hard-coded assertion counts and **both were wrong** — one measured against the wrong baseline, the other stale before the release shipped. A number in release prose describes the moment it was typed, and the plugin's own pitfalls say to prefer count-agnostic wording for exactly this reason. `test/smoke.sh` prints its own total on every run, which is the only place it can be right. The two bash suites are green on stock bash 3.2 and under a sandbox path containing a space, and `test-stride-lite-hook.sh` reports named skips rather than passing silently when no PowerShell is on `PATH`; the PowerShell mirror is green under `pwsh`. Every new assertion was mutation-tested, which found and closed several cases where a green suite was concealing nothing — including, during review of this very entry, two wrong numbers in this paragraph.

## [0.11.0] — 2026-07-02

> **If you installed stride-lite by running `./install.sh` (rather than symlinking the checkout), re-run the installer after updating.** Every copy install made before v0.11.0 is missing the `hooks/` enforcement layer entirely — the documented `.stride_lite.md` hook auto-fire never worked on that install path (W1481 below). A fresh `./install.sh --force` run from this version ships it.

### Fixed — the stale init-command PENDING artifact archived per the plugin's own convention (W1483)

The plugin dogfoods its own file-based workflow, yet the goal directory for `/stride-lite:init` — shipped at v0.2.0 — still sat under `docs/implementation/PENDING/`, contradicting the v0.10.0 PENDING→IMPLEMENTED archive convention the workflow skill documents. Resolved by manually applying the plugin's own terminal step: `goal.md` gained a Completion Summary recording the v0.2.0 ship, the fact that task2–task4 files were never committed (the work landed anyway — a gap in the paper trail, not the feature), and that the body's "hooks are static" statements are preserved v0.2.0-era history superseded by the v0.9.0 harness; the directory then moved to `docs/implementation/IMPLEMENTED/` via `git mv` so rename history survives. No historical body text was rewritten, and PENDING now contains no shipped-feature artifacts.

### Fixed — copy installs now ship the hook enforcement layer (W1481)

`install.sh` copied every plugin directory except `hooks/` — a user who installed by running the script (rather than symlinking the checkout) got a plugin whose documented PreToolUse/PostToolUse auto-fire simply did not exist: no `hooks.json` for Claude Code to register, no hook scripts to invoke, and a green "installed successfully" message throughout. The copy set now includes `hooks/` (via the same `cp -a` idiom, so `stride-lite-hook.sh`'s executable bit survives), the install summary reports the hook scripts copied, and a post-copy sanity check fails loudly — before any success banner — if `hooks/hooks.json` did not land. The README install section now names `./install.sh` as the copy path and states that both install methods ship the enforcement layer, keeping visible that the hook scripts execute shell commands the user authors in `.stride_lite.md`. Verified behaviorally against temp HOMEs: fresh install, `--force` upgrade over a previously hookless install, unchanged clobber refusal, and both failure modes (missing source `hooks/` dies at the copy; empty `hooks/` trips the new sanity check with no success line).

### Fixed — README version label, command count, and the create-goal step count (W1480)

Three storefront staleness fixes with drift-resistant wording. The README's installation and limitations sections claimed "v0.1.0" ten releases after the fact — both now say "currently" so they stay true across releases (the Claude-Code-only limitation itself is unchanged). The command list said two slash commands while `/stride-lite:init` shipped as a documented third — it now says three with an init row in the existing format, which also resolves the README's own internal contradiction (the Subagents section already said "three"). And `commands/create-goal.md` claimed "all seven flow steps" against its skill's eight — its prose is now count-agnostic ("walks every flow step") and its enumerated list is corrected to eight items matching the skill's step headings one-for-one (the old item 6 conflated the goal.md and taskN.md render steps); the same count-agnostic prose is applied to `commands/create-task.md` for symmetry, whose seven-item list was verified correct and kept. plugin.json remains the single version source, untouched.

### Added — smoke test hardened: init-template parity enforcement and hook-routing coverage (W1482)

Two silent gaps closed in `test/smoke.sh`. Its embedded `.stride_lite.md` template still carried the v0.2.0-era "does not execute" Note — violating its own byte-equivalence invariant without any red output, because assertions checked only section headers. The template is synced to the canonical v0.9.0+ wording, and a new parity assertion extracts the canonical block from the init SKILL.md (via its unique quadruple-backtick fence pair) and diffs full content, so future drift fails the run with the diff shown — demonstrated by breaking one character locally and watching it fail. And the v0.9.0 enforcement layer — the thing that makes stride-lite more than markdown — had zero test coverage: a new hook-routing stage feeds nine synthetic Claude Code hook payloads through `hooks/stride-lite-hook.sh` as full subprocesses in the sandbox, pinning the routing contract in executable fixtures: explorer dispatch fires `before_task` and reviewer dispatch fires `after_task` (both blocking — a failing section demonstrably exits 2), a goal.md Completion Summary write fires `after_goal` (advisory — a failing section demonstrably exits 0), and non-matching payloads (wrong subagent, missing subagent field, goal.md without a summary, summary in a non-goal file) pass through with empty stdout. Pure bash throughout, all fixture commands inert and sandbox-confined, the hook script untouched. The suite grows from 24 to 43 assertions.

### Fixed — phantom command references purged and the create-decomposer contract enforced (W1479)

Three files cited slash commands that never shipped — `/stride-lite:ideate` and `/stride-lite:decompose`, copy-paste drift from the stride-ideation sibling's naming — sending agents and users to surfaces that do not exist. The decomposer agent's intro and both worked examples now invoke the real `/stride-lite:create-goal` and `/stride-lite:create-task` commands (scenarios unchanged), and `lib/parse_args.md`/`lib/slugify.md` point at the real callers. The agent's contract contradiction is resolved: its frontmatter granted `Read, Grep` while its own body promises it never sees the codebase — both real dispatch sites were verified to pass the requirements text inline (never a file path), so the unjustified grant is removed. Its section-list claim now names the goal template's real seven headings (Why, What, Description, Acceptance criteria, Pitfalls, Decomposition notes, Tasks — there is no Goal heading). Zero phantom references remain repo-wide; the smoke suite stays 24/24.

### Fixed — the workflow walkthrough no longer teaches double execution and now ends with the archive move (W1478)

The Concrete Walkthrough — the section agents imitate step by step — still carried pre-v0.9.0 text telling the agent to read `.stride_lite.md` and execute the `before_task`, `after_task`, and `after_goal` sections directly, reintroducing exactly the double-execution the v0.9.0 harness migration removed (each hook would run once by the agent's hand and once via the harness). The three walkthrough steps now narrate what actually happens: the harness auto-fires `before_task` at the explorer dispatch and `after_task` at the reviewer dispatch (PreToolUse, blocking — a failure blocks the dispatch), and fires `after_goal` after the goal.md Completion Summary write (PostToolUse, advisory — it cannot roll back the write). Walkthrough Step 8 also gains the v0.10.0 terminal outcome the body mandates: the PENDING→IMPLEMENTED archive move (git mv when tracked, collision-suffixed) with the no-move guard when the harness reports an `after_goal` failure, and the end-state paragraph now shows the archived path. Body steps are unrenumbered; only walkthrough text changed.

### Fixed — stale hooks-never-execute claims purged from the init surface (W1477)

The init command and init skill were frozen at v0.2.0 semantics — the first thing a new user runs told them the hook sections are "static configuration that stride-lite does NOT execute," and the sites that did assert execution misattributed it to the `stride-lite-workflow` skill (true at v0.8.0, wrong since the v0.9.0 harness took over). All eight sites — the command frontmatter and NOT-do bullet, the skill frontmatter, intro, NOT-do bullet, the Step 3 success message printed verbatim to users, the canonical `.stride_lite.md` template Note, and the pitfalls entry — now carry one consistent statement: the init surface never executes hooks itself (pure scaffolder); as of v0.9.0 the Claude Code harness auto-fires them via the plugin's `hooks.json`, `before_task`/`after_task` blocking (exit 2 stops the dispatch) and `after_goal` advisory, with the trigger points matching the workflow skill's table. The scaffolded template structure and `test/smoke.sh` are untouched (the smoke test's embedded template copy is synced in a dependent task).

## [0.10.0] — 2026-05-27

### Added

- **Terminal PENDING → IMPLEMENTED archive move** in `skills/stride-lite-workflow/SKILL.md` Step 8's final-task branch. After the harness auto-fires the `## after_goal` hook on the goal.md write, the workflow moves the goal directory from `docs/implementation/PENDING/<slug>/` to `docs/implementation/IMPLEMENTED/<slug>/` and then exits. Four behavioral details land together:
  - **Timing.** The move happens AFTER `after_goal` fires — the user's hook sees the still-PENDING path, matching what the hook was scoped to handle.
  - **After-goal-failure guard.** If the harness emitted a structured failure JSON for `after_goal` (`"status": "failed"`), the move is skipped and the goal directory stays in `PENDING/` so the user can inspect and re-trigger. A clean no-op (no `after_goal` section, missing `.stride_lite.md`, empty fenced block) is NOT a failure and proceeds with the move.
  - **Non-`/PENDING/` path handling.** If `goal_directory_path` does not contain `/PENDING/` as a directory segment (custom `--output-dir`), the workflow logs a warning to stderr and skips the move without failing the workflow.
  - **Move tool selection.** Prefers `git mv` when (a) `git rev-parse --is-inside-work-tree` succeeds and (b) `git ls-files <path>` is non-empty — this preserves rename history for users who commit their goal directories. Falls back to plain `mv` otherwise.
  - **Collision suffixing.** If `IMPLEMENTED/<slug>/` already exists, the target is suffixed with `-2`, `-3`, ... up to a 1000-iteration safety cap, mirroring `lib/resolve_output_path.md`'s semantics exactly (start at `n=2`, never overwrite, cap exhaustion logs a stderr warning and skips the move). The IMPLEMENTED archive never overwrites prior entries.
  - **Filesystem-mv failure handling.** If `mv` / `git mv` returns non-zero (permissions, disk full, cross-device), the workflow logs the error to stderr and exits cleanly — the goal work is complete, a failed archive is a recovery operation. The workflow itself does not fail because of an archive-move failure.
- **Reference bash idiom** for the move embedded in Step 8 sub-step 3 of `stride-lite-workflow/SKILL.md`. The snippet shows the exact parameter-expansion idioms (`${goal_path%/}`, `${goal_path##*/}`, `${goal_path%/PENDING/*}`), the `n=2..1000` collision loop, and the `git mv` / `mv` selector. Implementors transliterate the snippet at runtime without reinventing the path arithmetic.

### Changed

- **`stride-lite-workflow` SKILL.md `## Bash scope` ✅ list** expanded with four scoped exceptions, each annotated "for the terminal-move step in Step 8's final-task branch only": `mv` / `git mv`, `git rev-parse --is-inside-work-tree`, `git ls-files <path>`, `mkdir -p <impl_base>`. The existing ❌ bullet for `rm` / `cp` / `mv` is amended in place to reflect the narrow terminal-move carve-out (the previous "except inside user-supplied hook bash blocks" exception is preserved alongside the new carve-out).
- **`stride-lite-workflow` SKILL.md `### Step 8` final-task branch** sub-list grew from 3 numbered sub-steps to 4 (the new sub-step 3 is the terminal move; the old sub-step 3 "Workflow complete. Stop." renumbers to 4). The eight-step heading structure (`### Step 1` through `### Step 8`) is preserved verbatim — V5 still asserts `grep -cE '^### Step [1-8]'` == 8.
- **README.md `## Output layout`** tree diagram updated to show `PENDING/` and `IMPLEMENTED/` as sibling directories under `docs/implementation/`, with a follow-up paragraph documenting that the workflow's terminal move populates IMPLEMENTED, that `git mv` is preferred when tracked, that collisions suffix with `-2`/`-3`/..., that non-`/PENDING/` paths skip with a warning, and that single-task files under `PENDING/tasks/` are NEVER moved (only goal directories).
- **README.md `## Workflow`** step 8 bullet renamed from "Completion summary" to "Completion summary + archive move" and extended to mention the v0.10.0 terminal move and its skip conditions.
- **AGENTS.md "Hard rules for agents working on this codebase"** default-paths bullet expanded to mention `docs/implementation/IMPLEMENTED` as the archive location, name `stride-lite-workflow` SKILL.md as the new co-author of the cross-skill contract (any change to `--output-dir` must also touch the workflow's `/PENDING/` substring substitution), and call out the silent-breakage failure mode if the two paths drift.

### Notes

- **No new files.** The change is contained in `skills/stride-lite-workflow/SKILL.md` (Step 8 sub-step + Bash scope), `README.md`, `AGENTS.md`, `CHANGELOG.md`, and `.claude-plugin/plugin.json` (version bump). The `hooks/` enforcement layer (added in v0.9.0), the `.stride_lite.md` template, the three subagents (`create-decomposer`, `task-explorer`, `task-reviewer`), and the four `lib/` helpers are all unchanged.
- **`lib/resolve_output_path.md` is referenced but not modified.** The terminal-move step's collision loop mirrors its bash idiom (`n=2`, `[ ! -e "$candidate" ]` probe, 1000-iteration cap) inline rather than calling the helper as a subprocess — the helper is spec-only documentation, not a runtime file.
- **Smoke test unchanged.** `test/smoke.sh` does not assert on the workflow SKILL.md, README, AGENTS.md, CHANGELOG, plugin.json, or the goal/task lifecycle, so v0.10.0 ships without modifying the test — it continues to exit 0 with `24 passed, 0 failed`. Integration testing of the move step (the 7 scenarios listed in W917's testing strategy: happy path, collision suffix, git-tracked vs non-tracked, non-`/PENDING/` skip, cap exhaustion, after-goal-failure no-move guard, filesystem-mv failure) is verified by transcribing the SKILL.md reference snippet into a scratch script and exercising each scenario manually.
- **v0.4.0 per-task template byte-parity preserved.** This release does not modify either `stride-lite-create-goal/SKILL.md` or `stride-lite-create-task/SKILL.md`; the parity diff still returns empty.
- **No changes to existing agents.** `agents/create-decomposer.md`, `agents/task-explorer.md`, and `agents/task-reviewer.md` are byte-equivalent to their v0.9.0 state. The terminal move is a workflow-skill-body concern, not an agent concern.
- **No changes to the `hooks/` enforcement layer.** `hooks/hooks.json`, `hooks/stride-lite-hook.sh`, and `hooks/stride-lite-hook.ps1` are byte-equivalent to their v0.9.0 state. The harness still intercepts the same three triggers; the v0.10.0 move step runs in the workflow skill body AFTER the harness's `after_goal` PostToolUse hook has fired and emitted its structured JSON, which the workflow inspects to decide whether to move or skip.
- **PostToolUse advisory-failure semantics revisited.** The v0.9.0 release intentionally made `after_goal` advisory because PostToolUse cannot roll back the `goal.md` write. v0.10.0 honors that posture: the terminal move is similarly advisory — a failed move logs and exits cleanly rather than failing the workflow.

[0.10.0]: https://github.com/cheezy/stride-lite/releases/tag/v0.10.0

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

[0.11.0]: https://github.com/cheezy/stride-lite/releases/tag/v0.11.0
[0.1.0]: https://github.com/cheezy/stride-lite/releases/tag/v0.1.0
