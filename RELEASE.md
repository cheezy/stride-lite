# Releasing Stride Lite

A Stride Lite release is two pieces of work in two repositories: this one
(version, changelog, tag, GitHub release) and the `stride-marketplace` catalog,
which pins the version users install. This file names no real version number,
on purpose — see below.

## The three facts

**Where the version lives.** `.claude-plugin/plugin.json` (`"version"`), and
only there. `test/smoke.sh` holds this in place three ways:

- the first numbered `## [X.Y.Z]` heading in `CHANGELOG.md` must equal
  `plugin.json`'s version (`[Unreleased]` is skipped);
- the version string may not appear in any other `.md`, `.sh` or `.json` file
  in the tree — which is why this document says `X.Y.Z` throughout;
- the top changelog entry may not state a suite total ("N passed").

AGENTS.md makes the pairing a hard rule: never raise the version without the
matching changelog heading in the same commit.

**Changelog shape: mostly appended under `[Unreleased]`, but not uniformly.**
Most work commits add their entry under `## [Unreleased]`, and a release
commit later renames that heading to `## [X.Y.Z] — YYYY-MM-DD` (note the em
dash) and bumps `plugin.json`. At least one work commit instead did all three
itself — entry, dated heading and bump — in lockstep. The history does not
settle which is the rule; the only invariant the suite enforces is the
heading/manifest pairing above. Entries are accumulating under `[Unreleased]`
right now, so the next release stamps that heading.

**Catalog: `stride-marketplace`.** The plugin is listed in
`stride-marketplace/.claude-plugin/marketplace.json` as a URL source pointing
at this repository, with a `version` field that is what users see. A release
here is not finished until that catalog is updated, and the catalog has its
own one-release-is-one-commit ritual — follow the "Releases and tagging"
section of the `stride-marketplace` README, which is authoritative for that
side: the plugin row's version and description, the catalog's
`metadata.version`, the README table row and prose, and a catalog changelog
entry, all in one commit, then a catalog tag and GitHub release. The catalog's
tag numbers are its own sequence; they do not mirror this plugin's version.

## Before you add to the changelog: is the top heading already tagged?

This repository is where the fleet learned this one. A work commit appended
its entry under a numbered heading that had already been tagged and
released, which edited the record of a shipped release; the next release had
to move the entry under a new heading and say why ("A released entry is a
record of what shipped, not a place to add to"). Check before writing:

```bash
git tag -l "v$(sed -n 's/^## \[\([0-9][0-9.]*\)\].*/\1/p' CHANGELOG.md | head -n 1)"
```

Any output means the newest numbered heading is already released — add under
`[Unreleased]` (recreate it if it is missing), never under that heading. No
output means the newest numbered heading has not been tagged yet.

## Steps

1. Run the gates in this repository:

   ```bash
   bash test/smoke.sh
   bash hooks/test-stride-lite-hook.sh
   pwsh -File hooks/test-stride-lite-hook.ps1
   ```

   and the fleet drift check from the `stride` repository
   (`bash scripts/check-port-canon.sh` run there).

2. Run the top-heading check. Then, in one commit on `main`, rename
   `## [Unreleased]` to `## [X.Y.Z] — YYYY-MM-DD` and set `"version"` in
   `.claude-plugin/plugin.json` to `X.Y.Z`. Re-run `bash test/smoke.sh`; it
   now checks the pair. Recent release commits are titled
   `Release X.Y.Z — <summary>`. Push `main`.

3. Tag the release commit (annotated) and push the tag:

   ```bash
   git tag -a vX.Y.Z -m "vX.Y.Z"
   git push origin vX.Y.Z
   ```

4. Publish the GitHub release from the stamped entry:

   ```bash
   gh release create vX.Y.Z --repo cheezy/stride-lite --notes-file <notes.md>
   ```

5. Update `stride-marketplace` per its own README, then tag and release the
   catalog under its own next number.

## Known gaps on the record

- Older tags are a mix of annotated and lightweight; use annotated.
- The first eight versions in the changelog were never tagged; the tag
  series starts with the ninth, and every tag since has a GitHub release.
  No decision to accept or backfill that gap is on record, so treat it as
  unsettled rather than backfilling on your own.
