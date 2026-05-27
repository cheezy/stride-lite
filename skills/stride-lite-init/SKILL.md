---
name: stride-lite-init
description: Use to scaffold a `.stride_lite.md` config file in the current working directory containing the four canonical sections (`## email`, `## before_task`, `## after_task`, `## after_goal`). The skill writes one file and prints a success message instructing the user to fill in the fields. Refuses to clobber an existing `.stride_lite.md` unless `--force` is supplied. Never executes the hook sections — they are static configuration the user fills in. Never POSTs to any API. Invoke when the user types `/stride-lite:init` (optionally with `--force`).
skills_version: "1.0"
---

# stride-lite-init

Surface skill for the init flow. Writes a project-local `.stride_lite.md` file with the canonical four-section template, and prints a one-paragraph message asking the user to fill in the fields. The hook sections (`before_task`, `after_task`, `after_goal`) are **static documentation in v0.2.0** — stride-lite does not execute them. The format mirrors the full Stride plugin's `.stride.md` so users moving between the two plugins recognize the shape.

## What this skill does

```
parse_args (--force?)  ->  collision check on ./.stride_lite.md
                       ->  write canonical template to ./.stride_lite.md
                       ->  print "fill in the fields" success message
```

That is the entire side effect.

## What this skill does NOT do

- **Never POSTs to any API.** stride-lite remains a "no network" plugin.
- **Never executes the hook sections.** `## before_task`, `## after_task`, and `## after_goal` are static configuration in v0.2.0. Whether a future release wires them into a lifecycle is deliberately deferred — this skill must not introduce one.
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
  - ## before_task — the shell commands you want to run before claiming a task (static config in v0.2.0; stride-lite does not execute them)
  - ## after_task — the shell commands you want to run after completing a task (same caveat)
  - ## after_goal — the shell commands you want to run when a goal finishes (same caveat)

The hook sections are documentation only in v0.2.0 — stride-lite will not run them. They match the shape of the full Stride plugin's .stride.md so your snippets transfer across plugins later if you wire them up.
```

That is the entire stdout output. The skill does not chain into any follow-up command.

## Canonical template

The skill writes this exact text to `./.stride_lite.md`. Keep the section order and the empty fenced bash blocks byte-equivalent to the format used by the full Stride plugin's `.stride.md` — that mental-model transfer is the reason for the empty-bash-block shape.

````markdown
# Stride Lite Configuration

This file is created by `/stride-lite:init`. Fill in the fields below.

**Note (v0.2.0):** The hook sections are static configuration — stride-lite does not execute them. The format mirrors the full Stride plugin's `.stride.md` so your snippets can transfer between plugins later.

## email

your-email@example.com

## before_task

```bash
```

## after_task

```bash
```

## after_goal

```bash
```
````

## Pitfalls

- **Don't execute the hook sections.** They are static config the user fills in. stride-lite has no lifecycle in v0.2.0 and must not grow one in this change.
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
