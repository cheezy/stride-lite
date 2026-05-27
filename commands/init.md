---
description: Scaffold a project-local `.stride_lite.md` config file in the current working directory with the canonical four sections (`## email`, `## before_task`, `## after_task`, `## after_goal`). The hook sections are static configuration in v0.2.0 — stride-lite does NOT execute them. Refuses to clobber an existing `.stride_lite.md` unless `--force` is supplied. Never POSTs to any API.
allowed-tools: Bash(test:*), Bash(rm:*), Bash(mkdir:*), Bash(. *:*), Bash(bash:*), Read, Write, Skill
argument-hint: "[--force]"
---

# /stride-lite:init

Scaffold a project-local `.stride_lite.md` config file in the current working directory. The orchestration — argument parsing, the canonical template, the `--force` collision check, and the success-message contract — lives in `skills/stride-lite-init/SKILL.md`. This command is the surface: it parses `$ARGUMENTS` and invokes the skill.

## What to do

Follow these steps in order. Do NOT skip steps.

### Step 1: Parse `$ARGUMENTS`

The user invoked you with `$ARGUMENTS`. Hand the unmodified arg string to the `stride-lite-init` skill — it parses the single optional `--force` flag internally:

- (no args) — write `.stride_lite.md` only if it does not already exist
- `--force` — overwrite an existing `.stride_lite.md` (or proceed normally if the file does not exist)

Any other argument is a hard error surfaced by the skill, not silently absorbed by this command file.

### Step 2: Invoke the `stride-lite-init` skill

Activate the skill and pass `$ARGUMENTS` through verbatim. The skill walks all three flow steps documented in `skills/stride-lite-init/SKILL.md`:

1. Parse the optional `--force` flag
2. Collision-check `./.stride_lite.md` and write the canonical four-section template
3. Print the success message instructing the user to fill in the fields

### Step 3: Surface the result

Pass the skill's stdout to the user verbatim. The skill prints a multi-line success message identifying the written file and listing the four sections the user needs to fill in. The command does NOT add a summary, ask follow-up questions, or chain into another tool.

## What this command does NOT do

- **No business logic in this file.** All parsing, collision-checking, template-writing, and message-printing happen in `skills/stride-lite-init/SKILL.md`.
- **Never POSTs to any API.** stride-lite remains a "no network" plugin.
- **Never executes the hook sections.** The `before_task`, `after_task`, and `after_goal` sections in the written `.stride_lite.md` are static configuration — stride-lite does not run them in v0.2.0.
- **Never writes outside the current working directory.** The target is always `./.stride_lite.md` relative to the cwd at invocation time.
- **Never asks the user mid-flow.** The invocation is fire-and-forget — no prompts, no confirmations.
