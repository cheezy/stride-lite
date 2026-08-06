---
name: stride-lite-init
description: Use to scaffold a `.stride_lite.md` config file in the current working directory containing the four canonical sections (`## email`, `## before_task`, `## after_task`, `## after_goal`). The skill writes one file and prints a success message instructing the user to fill in the fields. Refuses to clobber an existing `.stride_lite.md` unless `--force` is supplied. The init command itself never executes the hook sections (it is purely a scaffolder); as of v0.9.0 the Claude Code harness executes them automatically via the plugin's `hooks.json` at the corresponding lifecycle points (before_task before each task-explorer dispatch, after_task before each task-reviewer dispatch, after_goal after the goal-level Completion Summary is written). Never POSTs to any API. Invoke when the user types `/stride-lite:init` (optionally with `--force`).
skills_version: "1.0"
---

# stride-lite-init

Surface skill for the init flow. Writes a project-local `.stride_lite.md` file with the canonical four-section template, and prints a one-paragraph message asking the user to fill in the fields. The hook sections (`before_task`, `after_task`, `after_goal`) are **executed automatically by the Claude Code harness via the plugin's `hooks.json` as of v0.9.0** — `before_task` and `after_task` blocking (exit 2 stops the dispatch), `after_goal` advisory. The format mirrors the full Stride plugin's `.stride.md` so users moving between the two plugins recognize the shape.

## What this skill does

```
parse_args (--force?)  ->  collision check on ./.stride_lite.md
                       ->  write canonical template to ./.stride_lite.md
                       ->  print "fill in the fields" success message
```

That is the entire side effect.

## What this skill does NOT do

- **Never POSTs to any API.** stride-lite remains a "no network" plugin.
- **Never executes the hook sections.** The init skill is a pure scaffolder — it writes the template, prints the success message, exits. The hook sections (`## before_task`, `## after_task`, `## after_goal`) are executed automatically by the Claude Code harness via the plugin's `hooks.json` (v0.9.0+), not by this skill.
- **Never writes outside the current working directory.** No absolute paths, no parent traversal (`../`), no `$HOME` resolution. The target is always `./.stride_lite.md` relative to the cwd at invocation time.
- **Never clobbers an existing `.stride_lite.md`** unless `--force` is supplied. Mirrors the safety posture of `install.sh:54-67`.
- **Never asks the user mid-flow.** The invocation is fire-and-forget.

## Inputs

| Input | Default | Notes |
|---|---|---|
| `--force` | absent | Boolean flag. When present, overwrites an existing `./.stride_lite.md`. When absent and the file already exists, the skill exits non-zero with a "use --force to overwrite" message. |

No positional arguments. No other flags. Any unknown argument is a hard error surfaced to the user (do NOT silently absorb).

## Flow

### Step 1 — Parse arguments

Parse `$ARGUMENTS` for a single optional `--force` token. Two valid argv shapes:

- `` (empty) — no overwrite
- `--force` — overwrite allowed

Anything else is an error: print `"stride-lite-init: unknown argument: <arg>"` to stderr and exit non-zero. Do NOT fall back to a default behavior.

### Step 2 — Write `./.stride_lite.md` with collision check

Resolve the target path as exactly `./.stride_lite.md` relative to the current working directory. Do not canonicalize, do not follow symlinks to alternate locations.

Collision-check pattern (mirrors `stride-lite/install.sh:54-67`):

```bash
TARGET=".stride_lite.md"

if [ -e "$TARGET" ] && [ "$FORCE" -ne 1 ]; then
  echo "stride-lite-init: .stride_lite.md already exists in the current directory" >&2
  echo "Re-run with --force to overwrite." >&2
  exit 1
fi

# If --force AND the target exists, remove it first (defensive — handles the rare
# case where the existing entry is a directory rather than a file).
if [ "$FORCE" -eq 1 ] && [ -e "$TARGET" ]; then
  rm -rf "$TARGET"
fi
```

Then write the canonical template (verbatim from "Canonical template" below) to `$TARGET`.

### Step 3 — Print the success message

After the file write succeeds, print exactly this paragraph to stdout (a fresh line for each sentence):

```
Wrote .stride_lite.md to the current directory.

Open the file and fill in the four sections:
  - ## email — your contact email
  - ## before_task — the shell commands you want to run before starting each task (auto-fired by the Claude Code harness before each task-explorer dispatch; blocking — exit 2 stops the dispatch)
  - ## after_task — the shell commands you want to run after each task's implementation (auto-fired by the Claude Code harness before each task-reviewer dispatch; blocking — exit 2 stops the dispatch)
  - ## after_goal — the shell commands you want to run when the final task in a goal completes (auto-fired by the Claude Code harness after the goal-level Completion Summary is written; advisory)

The hook sections are executed automatically by the Claude Code harness via the plugin's hooks.json at the corresponding lifecycle points (v0.9.0+). The format mirrors the full Stride plugin's .stride.md so your snippets transfer across plugins.

Each hook command receives the task/goal context as environment variables: HOOK_NAME, TASK_FILE, TASK_NUMBER, TASK_TITLE, GOAL_DIR, GOAL_FILE, GOAL_SLUG, GOAL_TITLE and AGENT_NAME. Anything that cannot be derived is exported as the empty string, never an error.
```

That is the entire stdout output. The skill does not chain into any follow-up command.

## Canonical template

The skill writes this exact text to `./.stride_lite.md`. Keep the section order and the command-free fenced bash blocks byte-equivalent to the format used by the full Stride plugin's `.stride.md` — that mental-model transfer is the reason for the empty-bash-block shape. The two lines in the `## after_task` block are comments, which the executor strips before running anything, so every section still scaffolds as a clean no-op; they exist so the injected variables are discoverable at the moment the user opens the file to fill it in.

````markdown
# Stride Lite Configuration

This file is created by `/stride-lite:init`. Fill in the fields below.

**Note (v0.9.0+):** The hook sections are executed automatically by the Claude Code harness via the plugin's `hooks.json` at the corresponding lifecycle points (`before_task` before each task-explorer dispatch and `after_task` before each task-reviewer dispatch, both blocking — exit 2 stops the dispatch; `after_goal` after the goal-level Completion Summary is written, advisory). The format mirrors the full Stride plugin's `.stride.md` so your snippets transfer across plugins. Each hook command also receives the task/goal context as environment variables — `HOOK_NAME`, `TASK_FILE`, `TASK_NUMBER`, `TASK_TITLE`, `GOAL_DIR`, `GOAL_FILE`, `GOAL_SLUG`, `GOAL_TITLE` and `AGENT_NAME` — each exported as the empty string when it cannot be derived.

## email

your-email@example.com

## before_task

```bash
```

## after_task

```bash
# Available here: HOOK_NAME TASK_FILE TASK_NUMBER TASK_TITLE GOAL_DIR GOAL_FILE GOAL_SLUG GOAL_TITLE AGENT_NAME
# echo "Finished task $TASK_NUMBER of $GOAL_SLUG: $TASK_TITLE"
```

## after_goal

```bash
```
````

## Pitfalls

- **Don't execute the hook sections in THIS skill.** The init skill is a pure scaffolder — write the file, print the message, exit. Hook execution is the Claude Code harness's job via the plugin's `hooks.json` (v0.9.0+).
- **Don't omit any of the four sections.** The template contract is exact: `## email`, `## before_task`, `## after_task`, `## after_goal`, in that order.
- **Don't clobber an existing `.stride_lite.md` without `--force`.** Refuse and exit non-zero with a clear message pointing to the flag.
- **Don't write the file anywhere except the cwd.** No absolute paths, no parent traversal, no `$HOME` or `$XDG_CONFIG_HOME` resolution.
- **Don't make any API calls.** No `curl`, no Stride client, no network.
- **Don't add `/stride-lite:init` as a prerequisite to the other surface commands.** `/stride-lite:create-goal` and `/stride-lite:create-task` must continue to work without `.stride_lite.md` present.

## Edge cases

- **`.stride_lite.md` exists as a regular file** — refuse without `--force`; overwrite with `--force` (the `rm -rf` step in the collision-check block handles the unlikely directory case as well).
- **`.stride_lite.md` exists as a directory** — same `--force` rule applies. The `rm -rf` in the collision-check block removes the directory before writing the file.
- **User lacks write permission in cwd** — the file-write step fails with the shell's standard "permission denied" error; surface that and exit non-zero. Do not retry, do not prompt.
- **`--force` supplied but no existing file** — proceed as if `--force` were absent. No error, no warning. `--force` only matters when there is something to overwrite.
- **Unknown argument** — hard error. Do not silently absorb into a positional argv slot; the command takes no positionals.


## Red flags — STOP

If you catch yourself thinking any of these, stop: this skill writes one file and exits.

- "I'll run the `## before_task` block once, just to check it works."
- "The harness fires it anyway — running it now is the same thing, only earlier."
- "There's an existing `.stride_lite.md`, but it's probably still the default — `--force` it."
- "They ran this from `apps/web/` — they obviously meant the repo root."
- "They don't use `after_goal`, so I'll leave that section out."
- "I'll reorder the sections to put `email` last; nothing parses by position."
- "The create commands should really require `init` first — I'll say so."
- "I'll check that the email address resolves before I write the file."

**All of these mean: write the template, print the message, exit.** Hook execution belongs to the Claude Code harness via `hooks/hooks.json`; running a section here either doubles its side effects or removes the `exit 2` that was the whole point of it.

## Rationalization Table

| Excuse | Reality | Consequence |
|---|---|---|
| "I just scaffolded `.stride_lite.md` — I'll run the `## before_task` block once to prove it works." | This skill is a **pure scaffolder**: write the file, print the message, exit. The Claude Code harness fires the sections from `hooks/hooks.json` at the real lifecycle intercept points. | The section runs **twice** — once by your hand and once when the harness fires it on the real dispatch — so an `## after_goal` that tags a release, deploys, or posts a notification does all of it twice, and neither run knows about the other. |
| "The harness fires `## after_task` anyway — running it here is the same thing, just earlier." | `before_task` and `after_task` are **blocking PreToolUse** hooks. Their entire value is the `exit 2` that stops the dispatch. | Run by hand, a non-zero exit is a message on your screen and nothing more: the `stride-lite:task-reviewer` dispatch it was supposed to block proceeds, so the gate never fires at all. The failure mode is not "ran twice" but "never ran". |
| "`.stride_lite.md` already exists but it's probably still the default template — I'll pass `--force` and rewrite it." | With `--force` the target is removed before the write. Without it the skill refuses and exits non-zero pointing at the flag. | The user's filled-in `## before_task`, `## after_task` and `## after_goal` — their test command, their deploy step, their contact address — are deleted with no prompt, no backup and no diff, and the skill prints its ordinary success message on top. |
| "The user ran this from a subdirectory — they clearly meant the repo root, so I'll resolve up to it." | The target is exactly `./.stride_lite.md` relative to the cwd at invocation: no `../`, no `$HOME`, no canonicalization, no symlink following. | In a monorepo or a nested checkout the root you resolve to is a directory the user never named, and a `.stride_lite.md` already sitting there — with somebody else's `## after_task` in it — is the file you are about to collision-check and, under `--force`, delete. |
| "The user has no goal-completion command — I'll leave `## after_goal` out of the scaffold." | The template contract is exact and ordered: `## email`, `## before_task`, `## after_task`, `## after_goal`. An empty fenced `bash` block is the intended no-op shape for an unused hook. | `test/smoke.sh` byte-diffs this template against its own copy, so the suite goes red immediately — and the user never discovers `after_goal` exists, because the scaffold is the only place it is ever named to them. |
| "`/stride-lite:create-goal` will want hooks eventually — I'll tell the user to run `/stride-lite:init` first." | Init is deliberately **not** a prerequisite for either create command, and `stride-lite-workflow` treats a missing `.stride_lite.md` as a valid reduced-functionality configuration. | You attach a required setup step to `/stride-lite:create-goal` and `/stride-lite:create-task`, which both work without one, and a user who declines it reads your message as "the create commands are broken" and stops using them. |
| "The `## email` field is filled in — I'll validate the address or send a test message so they know it works." | stride-lite makes no network request of any kind. The `## email` value is scaffold text; the hook executor dispatches only on the three hook section names and never reads it. | A scaffolder that makes a request is a scaffolder that hangs on a slow DNS lookup, fails on an offline machine, or transmits the user's address off it — and `AGENTS.md`'s no-network contract, which is why this plugin ships with no credential store, stops being true. |
