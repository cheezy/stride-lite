# Security Model

This document describes what the **stride-lite** Claude Code plugin does at
runtime, written for a security reviewer evaluating it for the plugin
directory. Every claim here is backed by the plugin's own code — primarily
[`hooks/stride-lite-hook.sh`](hooks/stride-lite-hook.sh),
[`hooks/hooks.json`](hooks/hooks.json), and the behaviourally-mirrored
PowerShell variant `hooks/stride-lite-hook.ps1`.

## Trust boundary (read this first)

**The plugin executes shell commands that the user wrote, with the user's own
privileges, and deliberately does not validate them.**

`/stride-lite:init` scaffolds a `.stride_lite.md` file in the project root with
four sections. Three of them — `## before_task`, `## after_task` and
`## after_goal` — contain fenced `bash` blocks. When the workflow skill is
driving a goal, Claude Code's hook harness runs the commands in those blocks
verbatim, one per line, in the project directory.

This is the plugin's entire reason to exist and it is not a vulnerability: it is
the same trust model as a `Makefile`, a `package.json` script, or a git hook.
The commands come from a file in the user's own repository, under their own
version control, and run as them.

**What follows from that, and what a reviewer should check:**

- The plugin **never composes a command of its own** and never wraps, escapes,
  interpolates into, or otherwise rewrites what the user wrote. It reads the
  line and runs it. `## Bash scope` in
  [`skills/stride-lite-workflow/SKILL.md`](skills/stride-lite-workflow/SKILL.md)
  is an explicit allow/deny list of the only commands the workflow skill body
  may run itself, and it is asserted by the test suite.
- The plugin **never validates or sanitizes** a `.stride_lite.md` command. A
  malicious `.stride_lite.md` is a malicious repository, which is a threat the
  user accepts when they clone and open it — the same as a malicious
  `Makefile`. Reviewing that file is the user's responsibility, and the README
  says so.
- Anyone who can write to `.stride_lite.md` can run code as the user the next
  time a workflow drives a goal. Treat write access to that file as equivalent
  to write access to a git hook.

## What the plugin installs

`install.sh` copies `.claude-plugin/`, `commands/`, `skills/`, `agents/`,
`lib/`, `hooks/`, the four root markdown files and `LICENSE` into the plugin
directory.
It removes the hook test suites afterwards — they have no runtime purpose in an
installed plugin. Nothing else is written, and nothing outside the target
directory is touched.

The plugin has **no network access of any kind**: no API client, no HTTP
library, no `curl`, no `wget`. `AGENTS.md` makes this a hard rule and the
prohibition is greppable.

## What runs at runtime

`hooks/hooks.json` registers three interception points:

| Trigger | Hook section | Blocking |
|---|---|---|
| `PreToolUse` on `Agent` with `subagent_type == stride-lite:task-explorer` | `## before_task` | yes — a non-zero exit stops the dispatch |
| `PreToolUse` on `Agent` with `subagent_type == stride-lite:task-reviewer` | `## after_task` | yes |
| `PostToolUse` on `Edit`/`Write` to a `goal.md` containing `## Completion Summary` | `## after_goal` | no — the write already happened |

Nothing else fires a hook. Any other payload exits 0 with no output.

Each command receives a derived environment block — `HOOK_NAME`, `TASK_FILE`,
`TASK_NUMBER`, `TASK_TITLE`, `GOAL_DIR`, `GOAL_FILE`, `GOAL_SLUG`, `GOAL_TITLE`,
`AGENT_NAME` — every value of which comes from the task file or the dispatch
prompt. Three properties matter for review, and each is asserted in
`test/smoke.sh` or `hooks/test-stride-lite-hook.sh`:

- **Values are passed as environment variables, never interpolated into a
  command.** A task title containing `$(id)`, backticks or `; rm -rf` reaches
  the command as a literal string; the test suite asserts non-execution
  directly, by checking that the injected command produced no side effect.
- **Every value is sanitized before export**: control characters are stripped,
  keys that are not valid shell identifiers are dropped, and values are capped
  at 512 bytes.
- **Path values are confined to the project.** A path that resolves outside the
  project root, or whose final component is a symbolic link, resolves to empty
  rather than being followed.

## The activation marker is not a security boundary

The workflow skill writes `.stride-lite/.orchestrator_active` at Step 0 and
clears it on every exit path. The hook harness declines to fire any hook unless
that marker exists and is under four hours old — **or unless
`STRIDE_LITE_ALLOW_DIRECT=1` is set in the environment**, which bypasses the
check entirely and exists for plugin debugging and scripted runs. Only the exact
value `1` bypasses it; the test suites assert that `0` does not.

That escape hatch is not a weakening of the model — it is the clearest evidence
for it. A gate anyone can turn off with an environment variable was never an
authorization boundary, and treating it as one is the mistake this section
exists to prevent.

**This is a coordination mechanism, not an authorization mechanism.** Any local
process can create the file. Its only job is to keep a standalone
`stride-lite:task-explorer` dispatch — a workflow the README documents as
supported — from silently running the user's `## before_task` commands when no
goal drive is in progress.

`AGENTS.md` carries this as a hard rule: *"never treat the activation marker as
authorization."* Nothing that matters for security may ever be gated on it, and
a reviewer should treat any future change that does as a defect.

## Cross-plugin dispatch surfaces

Three optional, gated steps in the workflow skill dispatch an agent belonging to
a **different** plugin. All three are skipped entirely when that plugin is not
installed, and a closed gate never fails a task.

- **Step 6a** dispatches `stride-exploratory-testing:explorer`, which exercises
  a **running application**. This is the highest-risk capability in the plugin,
  and it is gated on an **authorized-and-non-production affirmative that comes
  from the user** and is collected once, at Step 0. The skill states that this
  affirmative has exactly one legitimate source, must never be inferred from a
  `localhost` URL or anything a task file says, and must never be supplied on
  the user's behalf. Inferring it *is* supplying it. The dispatched agent
  operates under its own plugin's safety boundary, which stride-lite neither
  relaxes nor re-implements.
- **Step 6b** dispatches `/stride-exploratory-testing:harden`, which writes
  regression-check drafts under `.exploratory/checks/` and holds no test runner.
- **Step 6c** dispatches `stride-security-review:security-reviewer` against the
  working-tree diff.

**A dispatch is not a network call.** stride-lite opens no socket, imports no
HTTP client and holds no credential; the dispatched agent reaches whatever it
reaches under its own plugin's contract and under authorization the user gave
directly. This is stated in `AGENTS.md` as a hard rule specifically so that no
future change reads it as licence to add an HTTP client.

## Credentials

The plugin holds none, stores none and transmits none. Where a dispatch needs
test accounts or seed data, the workflow skill requires a **pointer** to where
they live and explicitly forbids pasting a credential into a dispatch prompt.
Findings and evidence written back into a task file are restated rather than
copied, and any embedded secret is replaced with a literal redaction sentinel.

## Blocking semantics and failure modes

`before_task` and `after_task` are blocking: a non-zero exit returns exit code 2
and stops the agent dispatch that triggered it. `after_goal` is advisory,
because a `PostToolUse` hook cannot undo the write that fired it.

On failure the hook emits a structured JSON document naming the failed command,
its zero-based index, its exit code, and the commands that did and did not run.
Command output is truncated to the last 50 lines.

## Cross-platform parity

`hooks/stride-lite-hook.sh` delegates to `hooks/stride-lite-hook.ps1` on native
Windows. The two are intended to behave identically. `hooks/test-stride-lite-hook.sh`
compares their **emitted JSON** — the failure document byte-for-byte, the success
document apart from its measured duration — on a host with PowerShell available;
`test/smoke.sh` separately compares the **exported environment key set** and the
marker gate's outcomes, driving the `.ps1`'s own functions through the same
fixtures as the bash stage.

**One divergence is known, and it is recorded rather than hidden.** The `.ps1`
cannot read an OS-level pipe, so it cannot be driven end to end by a test; it is
filed as D215 and the suites report it as a named skip rather than passing
silently. A second — the executor re-splitting each command so only its first
token reached the shell, which meant every multi-word hook command silently did
nothing on Windows — was found by these suites and has since been
**fixed** (D218); both suites now assert that behaviour instead of skipping it.

**The PowerShell executor has not been verified on a real Windows host.** What
has been verified is that its functions, driven directly under `pwsh` on macOS,
agree with the bash implementation on the cases the suites cover.

## Reporting

Security concerns about this plugin can be raised via the issue tracker at
<https://github.com/cheezy/stride-lite>.
