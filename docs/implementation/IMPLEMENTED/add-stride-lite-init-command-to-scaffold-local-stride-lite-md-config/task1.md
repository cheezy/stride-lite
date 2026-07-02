# Author stride-lite-init skill and .stride_lite.md template

> Type: work · Complexity: small · Priority: medium

## Description

Create the surface skill that drives the init flow: parse a single optional `--force` flag, refuse to clobber an existing `.stride_lite.md` in the cwd without `--force`, write the canonical `.stride_lite.md` template (email field + before_task + after_task + after_goal sections), and print a "fill in the fields" success message. The template text lives inline in the SKILL.md as the source of truth.

## Why

Without a surface skill, the slash command in the next task has nothing to activate. This skill owns the file-write logic, the `--force` gate, and the canonical template text.

## What

New file `stride-lite/skills/stride-lite-init/SKILL.md` with YAML frontmatter (`name: stride-lite-init`, description, `skills_version: 1.0`), a "What this skill does" block, a "What this skill does NOT do" block (no hook execution, no API calls, no operation outside cwd), an Inputs table (just `--force`), a Flow section with three numbered steps (parse args, write file with collision check, print success message), the inline `.stride_lite.md` template, and a Pitfalls section. The template MUST contain exactly these four sections in this order: `## email` (single-line value), `## before_task` (empty fenced bash block), `## after_task` (empty fenced bash block), `## after_goal` (empty fenced bash block). The hook block format mirrors the full Stride plugin's `.stride.md` shape so users transferring between the two plugins see familiar syntax.

## Where

`stride-lite/skills/stride-lite-init/SKILL.md` — new file. No other changes in this task.

## Acceptance criteria

`stride-lite/skills/stride-lite-init/SKILL.md` exists with valid YAML frontmatter (`name=stride-lite-init`, `skills_version="1.0"`)
The SKILL.md contains the canonical `.stride_lite.md` template with exactly four sections in order: email, before_task, after_task, after_goal
The flow documents `--force` handling (refuse to clobber without it; overwrite cleanly with it)
The flow documents the post-write success message instructing the user to fill in the fields
The SKILL.md explicitly states the hook sections are static config and are NOT executed by stride-lite
The Pitfalls section enumerates the no-clobber, no-API-call, no-hook-execution, cwd-only invariants

## Patterns to follow

Mirror the orchestration shape of `stride-lite/skills/stride-lite-create-task/SKILL.md` (frontmatter, "What this skill does", "What this skill does NOT do", Inputs table, Flow with numbered Steps, Pitfalls)
Use the `install.sh` `--force` gating pattern at `stride-lite/install.sh:54-67` as the reference for the collision check
Keep the `.stride_lite.md` hook block format (`## section` followed by a fenced bash block) byte-equivalent to the full Stride plugin's `.stride.md` to ease user mental-model transfer

## Pitfalls

- Don't execute the hook sections — the template documents them; stride-lite does not run them
- Don't omit any of the four sections — the template contract is exact
- Don't clobber an existing `.stride_lite.md` without `--force` — refuse and exit non-zero
- Don't write the file anywhere except the cwd — never resolve to absolute paths or parent traversal
- Don't make any API calls — the skill writes one local file and prints a message

## Security considerations

- Resolve the target as exactly `./.stride_lite.md` relative to the cwd at invocation time — no `realpath` canonicalization, no `$HOME` resolution, no parent traversal. A user invoking the command from an unexpected directory should overwrite a file in *that* directory, never escape it.
- Refuse to clobber an existing `.stride_lite.md` unless `--force` is supplied. The collision-check defends against the user accidentally running `/stride-lite:init` in a project that already has the config and losing whatever edits they made to the email/hook sections.
- The template's `## email` field is documentation only — the skill writes the placeholder `your-email@example.com`, never the operator's actual email. There is no read-side hook in this skill that picks up the email value, so no PII is captured at write time.

## Integration points

- Full Stride plugin's `.stride.md` — the four sections in the produced `.stride_lite.md` (`## email`, `## before_task`, `## after_task`, `## after_goal`) mirror that file's section format byte-equivalently so users can later transfer hook snippets between the two plugins without reshaping.
- `install.sh` (`stride-lite/install.sh:54-67`) — the `--force` collision-check pattern in this skill is copied from the installer's safety posture so the two surfaces behave identically.

## Technology requirements

- Bash + POSIX file operations (`test -e`, `rm -rf`, here-doc `cat > target <<EOF`). No external deps.
- Claude Code skill loader — the skill is activated by the `/stride-lite:init` slash command via the Skill tool; no direct invocation surface outside Claude Code in v0.2.0.

## Logging requirements

- On success: emit the multi-line "fill in the fields" paragraph to stdout (documented in Step 3 of the skill's Flow section). This is the user-visible signal that the file landed; no separate audit log.
- On refuse-to-clobber: emit `stride-lite-init: .stride_lite.md already exists in the current directory` and `Re-run with --force to overwrite.` to stderr, exit 1.
- On unknown argument: emit `stride-lite-init: unknown argument: <arg>` to stderr, exit non-zero.
- No telemetry, no metrics, no `Logger.info` — the skill is a one-shot file-write with no lifecycle to instrument.

## Key files

| File | Note |
|---|---|
| `stride-lite/skills/stride-lite-init/SKILL.md` | New surface skill — owns the file-write logic, `--force` gate, and canonical template |

## Verification steps

1. **command** — `test -f stride-lite/skills/stride-lite-init/SKILL.md && head -5 stride-lite/skills/stride-lite-init/SKILL.md` → expected: file exists with frontmatter (`name: stride-lite-init`, `skills_version: '1.0'`)
2. **manual** — Read the SKILL.md and confirm the canonical `.stride_lite.md` template lists exactly four sections in order: email, before_task, after_task, after_goal → expected: all four sections present in the exact order specified
3. **manual** — Confirm the Flow section documents `--force` handling and the post-write success message → expected: both behaviors documented in the numbered steps

## Testing strategy

- **Coverage target:** Full template contract documented; skill flow covers all three exit cases (success, collision-without-force, `--force` overwrite)
- **Unit tests:**
  - (none for this task — the surface skill is documentation; the smoke test in task 4 adds the behavioral assertions)
- **Integration tests:**
  - After implementing the skill, manually invoke `/stride-lite:init` in a temp directory and confirm the file is created with the four documented sections
  - Invoke `/stride-lite:init` twice in the same directory; the second invocation must fail with `--force` advice; the third invocation with `--force` must succeed
- **Manual tests:**
  - Read the SKILL.md and confirm the template hook-block format matches the full Stride plugin's `.stride.md` byte-equivalently
- **Edge cases:**
  - `.stride_lite.md` already exists (refuse without `--force`)
  - Running from a directory where the user lacks write permission (clear error from the file write)
  - cwd contains a directory named `.stride_lite.md` (not a file) — refuse and exit non-zero
