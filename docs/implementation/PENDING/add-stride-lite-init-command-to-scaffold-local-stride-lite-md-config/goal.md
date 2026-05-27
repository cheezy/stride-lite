# Add /stride-lite:init command to scaffold local .stride_lite.md config

## Why

stride-lite v0.1.0 ships a working two-command surface (`/create-goal` and `/create-task`), but there is no project-local configuration file and no opinionated starting point for users who want to record per-project preferences (an email, plus hook command sections the user can fill in for whatever external workflow they wire up later). Adding `/stride-lite:init` gives users a single command to scaffold the file with the canonical shape, eliminating the "what should this file look like?" onboarding friction.

## What

Introduce a new third surface command `/stride-lite:init` that writes a `.stride_lite.md` file in the current working directory. The file contains exactly four documented sections: an email field, a `before_task` hook section, an `after_task` hook section, and an `after_goal` hook section. The command refuses to clobber an existing `.stride_lite.md` unless `--force` is supplied (matching `install.sh`'s safety posture), and on success prints a one-paragraph message telling the user to fill in the fields. The hook sections are static config in v0.2.0 — stride-lite does NOT execute them. Whether to wire them into a future lifecycle is deliberately deferred.

## Description

Adds a third surface command to stride-lite that scaffolds a project-local `.stride_lite.md` config file with an email field plus three hook sections (`before_task`, `after_task`, `after_goal`). Mirrors the create-goal/create-task command shell + surface skill pattern, refuses to clobber without `--force`, and prints a "fill in the fields" message after success. The hook sections are static configuration in v0.2.0 — stride-lite does not execute them. Bumps the plugin to v0.2.0 since this is a new feature pre-1.0.

## Acceptance criteria

Running `/stride-lite:init` in a project without an existing `.stride_lite.md` creates the file with all four documented sections (email, before_task, after_task, after_goal)
Running `/stride-lite:init` in a project that already has `.stride_lite.md` fails with a clear "use --force to overwrite" message and exits non-zero
Running `/stride-lite:init --force` in a project that already has `.stride_lite.md` overwrites the file and prints the standard success message
After successful write, the command prints a one-paragraph message instructing the user to fill in the fields
`README.md`, `AGENTS.md`, and `CHANGELOG.md` all document the new command
`plugin.json` version is bumped to 0.2.0 and matches the CHANGELOG entry
The smoke test exits 0 with the new init-flow assertions included

## Pitfalls

- Don't execute the hook sections in v0.2.0 — they are static config the user fills in; stride-lite has no lifecycle and must not grow one in this change
- Don't omit any of the four sections (email, before_task, after_task, after_goal) — the contract is exact
- Don't clobber an existing `.stride_lite.md` without `--force` — match the `install.sh` safety posture
- Don't bump `plugin.json` version without a matching CHANGELOG entry
- Don't write the file anywhere except the current working directory
- Don't add a `/stride-lite:init` prerequisite to the existing create-goal/create-task commands — init must remain optional

## Decomposition notes

Four-task split along plugin-architecture seams: (1) the surface skill that owns the file-write contract and the canonical template, (2) the thin slash-command shell that activates the skill, (3) documentation + version bump, (4) smoke-test parity. Tasks 1 and 2 form the implementation pair; tasks 3 and 4 fan out from task 1 (the canonical template source). All four tasks land in the same release (v0.2.0). The split is small enough that the entire goal fits in roughly one focused work session; the four-task shape keeps each piece individually reviewable.

## Tasks

1. [Author stride-lite-init skill and .stride_lite.md template](task1.md)
2. [Write /stride-lite:init slash-command shell](task2.md)
3. [Update README, AGENTS, CHANGELOG and bump plugin version to 0.2.0](task3.md)
4. [Extend smoke test with /stride-lite:init flow assertions](task4.md)
