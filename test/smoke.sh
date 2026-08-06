#!/usr/bin/env bash
# smoke.sh — Stride Lite lib/ helper smoke test.
#
# Exercises the five lib/ helpers (slugify, resolve_output_path,
# load_requirements_dir, parse_args, select_workflow_branch) against known
# inputs and asserts the expected behavior. Pure bash + POSIX utilities — no test framework, no
# network, no external dependencies.
#
# The helper implementations below are byte-equivalent to the reference
# implementations in the corresponding lib/<name>.md spec files. If a spec
# changes, update this file in the same commit and bump the assertion count.
#
# Usage:
#   ./test/smoke.sh                # from the repo root
#   bash test/smoke.sh             # alternative invocation
#
# Exit codes:
#   0  all assertions passed
#   1  one or more assertions failed (count printed to stderr)

set -u  # NOT set -e — we want assertions to keep running after a failure

# Resolve repo root so the script works from any working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

ok() {
  PASS=$(( PASS + 1 ))
  echo "  PASS  $1"
}

nope() {
  FAIL=$(( FAIL + 1 ))
  echo "  FAIL  $1" >&2
  echo "        expected: $2" >&2
  echo "        actual:   $3" >&2
}

assert_eq() {
  local label="$1"
  local actual="$2"
  local expected="$3"
  if [ "$actual" = "$expected" ]; then
    ok "$label"
  else
    nope "$label" "$expected" "$actual"
  fi
}

# ------------------------------------------------------------------
# slugify — mirrors lib/slugify.md reference implementation
# ------------------------------------------------------------------

slugify() {
  local input="${1:-}"
  if [ -z "$input" ]; then
    echo "slugify: empty input" >&2
    return 1
  fi
  local lowered
  lowered="$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')"
  local replaced
  replaced="$(printf '%s' "$lowered" \
    | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-//; s/-$//')"
  if [ -z "$replaced" ]; then
    echo "slugify: slug normalized to empty string" >&2
    return 1
  fi
  printf '%s' "$replaced"
}

echo "slugify"
assert_eq "lowercases and dashes the prompt" \
  "$(slugify 'Add real-time notifications')" \
  'add-real-time-notifications'
assert_eq "collapses runs of dashes and trims" \
  "$(slugify '  Multiple   spaces & symbols!! ')" \
  'multiple-spaces-symbols'
assert_eq "numeric-only stays numeric-only" \
  "$(slugify '123')" \
  '123'
# Empty-input path returns non-zero — assert via exit code, not output.
if slugify '' >/dev/null 2>&1; then
  nope "rejects empty input" "non-zero exit" "exit 0"
else
  ok "rejects empty input"
fi

# ------------------------------------------------------------------
# resolve_output_path — mirrors lib/resolve_output_path.md
# ------------------------------------------------------------------

resolve_output_path() {
  local base_dir="${1:-}"
  local slug="${2:-}"
  local kind="${3:-}"
  local ext="${4:-}"
  if [ -z "$base_dir" ] || [ -z "$slug" ] || [ -z "$kind" ]; then
    echo "resolve_output_path: usage: resolve_output_path <base_dir> <slug> <dir|file> [<ext>]" >&2
    return 1
  fi
  if [ "$kind" != "dir" ] && [ "$kind" != "file" ]; then
    echo "resolve_output_path: kind must be 'dir' or 'file', got '$kind'" >&2
    return 1
  fi
  if [ "$kind" = "file" ] && [ -z "$ext" ]; then
    echo "resolve_output_path: ext is required when kind=file" >&2
    return 1
  fi

  local stripped="${base_dir%/}"
  local candidate
  if [ "$kind" = "dir" ]; then
    candidate="${stripped}/${slug}"
  else
    candidate="${stripped}/${slug}.${ext}"
  fi
  if [ ! -e "$candidate" ]; then
    printf '%s' "$candidate"
    return 0
  fi

  local n=2
  while :; do
    if [ "$kind" = "dir" ]; then
      candidate="${stripped}/${slug}-${n}"
    else
      candidate="${stripped}/${slug}-${n}.${ext}"
    fi
    if [ ! -e "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
    n=$(( n + 1 ))
    if [ "$n" -gt 1000 ]; then
      echo "resolve_output_path: refusing to scan past -1000 collisions" >&2
      return 2
    fi
  done
}

echo ""
echo "resolve_output_path"
# Create a sandbox under /tmp so we can simulate collisions safely.
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

assert_eq "returns the base path when nothing exists" \
  "$(resolve_output_path "$SANDBOX" 'add-notifs' dir)" \
  "$SANDBOX/add-notifs"

# Now create the directory and confirm we get -2.
mkdir -p "$SANDBOX/add-notifs"
assert_eq "appends -2 on first collision (dir)" \
  "$(resolve_output_path "$SANDBOX" 'add-notifs' dir)" \
  "$SANDBOX/add-notifs-2"

mkdir -p "$SANDBOX/add-notifs-2"
assert_eq "appends -3 on second collision (dir)" \
  "$(resolve_output_path "$SANDBOX" 'add-notifs' dir)" \
  "$SANDBOX/add-notifs-3"

# File-mode path.
assert_eq "returns base path for file mode" \
  "$(resolve_output_path "$SANDBOX" 'fix-typo' file md)" \
  "$SANDBOX/fix-typo.md"

touch "$SANDBOX/fix-typo.md"
assert_eq "appends -2 on first collision (file)" \
  "$(resolve_output_path "$SANDBOX" 'fix-typo' file md)" \
  "$SANDBOX/fix-typo-2.md"

# Caller-supplied base dir is honored (not hardcoded).
ALT_BASE="$SANDBOX/alt"
mkdir -p "$ALT_BASE"
assert_eq "honors caller-supplied base directory" \
  "$(resolve_output_path "$ALT_BASE" 'foo' dir)" \
  "$ALT_BASE/foo"

# ------------------------------------------------------------------
# load_requirements_dir — mirrors lib/load_requirements_dir.md
# ------------------------------------------------------------------

load_requirements_dir() {
  local dir="${1:-}"
  if [ -z "$dir" ]; then
    echo "load_requirements_dir: usage: load_requirements_dir <dir>" >&2
    return 0
  fi
  if [ ! -d "$dir" ]; then
    echo "load_requirements_dir: directory not found: $dir" >&2
    return 0
  fi

  local stripped="${dir%/}"
  local file rel

  find -L "$stripped" -type f -not -path '*/.*' 2>/dev/null \
    | sort \
    | while IFS= read -r file; do
        rel="${file#${stripped}/}"

        local size
        size="$(wc -c < "$file" 2>/dev/null | tr -d '[:space:]')"
        if [ -n "$size" ] && [ "$size" -gt 1048576 ]; then
          echo "load_requirements_dir: skipping (>1MiB): $rel" >&2
          continue
        fi

        local raw_bytes stripped_bytes
        raw_bytes="$(head -c 8192 "$file" 2>/dev/null | wc -c | tr -d '[:space:]')"
        stripped_bytes="$(head -c 8192 "$file" 2>/dev/null | LC_ALL=C tr -d '\0' | wc -c | tr -d '[:space:]')"
        if [ "${raw_bytes:-0}" -ne "${stripped_bytes:-0}" ]; then
          echo "load_requirements_dir: skipping (binary): $rel" >&2
          continue
        fi

        printf '=== %s ===\n\n' "$rel"
        cat "$file"
        if [ -n "$(tail -c 1 "$file" 2>/dev/null)" ]; then
          printf '\n'
        fi
        printf '\n'
      done
}

echo ""
echo "load_requirements_dir"

# Missing dir is non-fatal and returns empty stdout.
MISSING_OUTPUT="$(load_requirements_dir "$SANDBOX/does-not-exist" 2>/dev/null)"
assert_eq "missing directory yields empty stdout" \
  "$MISSING_OUTPUT" \
  ""

# Sample-requirements fixture: confirm load picks up the file and emits the header.
FIXTURE_DIR="$REPO_ROOT/fixtures"
FIXTURE_OUTPUT="$(load_requirements_dir "$FIXTURE_DIR" 2>/dev/null)"
# Crude check — should contain the sample-requirements.md header marker.
if printf '%s' "$FIXTURE_OUTPUT" | grep -q '=== sample-requirements.md ==='; then
  ok "reads fixtures/sample-requirements.md and emits header"
else
  nope "reads fixtures/sample-requirements.md and emits header" \
    "output contains '=== sample-requirements.md ==='" \
    "header not found in output"
fi

# Sort order check — create a temp dir with two files and ensure the alphabetically-first one is emitted first.
SORT_DIR="$(mktemp -d -p "$SANDBOX")"
printf 'BBB\n' > "$SORT_DIR/b.md"
printf 'AAA\n' > "$SORT_DIR/a.md"
SORT_OUTPUT="$(load_requirements_dir "$SORT_DIR" 2>/dev/null)"
# 'a.md' header should appear before 'b.md' header in the output.
A_LINE=$(printf '%s' "$SORT_OUTPUT" | grep -n '=== a.md ===' | head -1 | cut -d: -f1)
B_LINE=$(printf '%s' "$SORT_OUTPUT" | grep -n '=== b.md ===' | head -1 | cut -d: -f1)
if [ -n "$A_LINE" ] && [ -n "$B_LINE" ] && [ "$A_LINE" -lt "$B_LINE" ]; then
  ok "emits files in sorted-by-name order"
else
  nope "emits files in sorted-by-name order" \
    "a.md header line < b.md header line" \
    "a=$A_LINE b=$B_LINE"
fi

# ------------------------------------------------------------------
# parse_args — mirrors lib/parse_args.md
# ------------------------------------------------------------------

parse_args() {
  local requirements_dir="docs/requirements"
  local output_dir="docs/implementation/PENDING"
  local -a positional=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --requirements-dir)
        if [ $# -lt 2 ]; then
          echo "parse_args: --requirements-dir requires a value" >&2
          return 1
        fi
        requirements_dir="$2"
        shift 2
        ;;
      --output-dir)
        if [ $# -lt 2 ]; then
          echo "parse_args: --output-dir requires a value" >&2
          return 1
        fi
        output_dir="$2"
        shift 2
        ;;
      *)
        positional+=("$1")
        shift
        ;;
    esac
  done

  local prompt=""
  if [ "${#positional[@]}" -gt 0 ]; then
    prompt="${positional[*]}"
  fi

  if [ -z "$prompt" ]; then
    echo "parse_args: prompt is required (supply at least one positional argument)" >&2
    return 2
  fi

  printf 'PROMPT=%q\n' "$prompt"
  printf 'REQUIREMENTS_DIR=%q\n' "$requirements_dir"
  printf 'OUTPUT_DIR=%q\n' "$output_dir"
}

echo ""
echo "parse_args"

# Defaults case: prompt only, both flags should land on their documented defaults.
PROMPT="" REQUIREMENTS_DIR="" OUTPUT_DIR=""
eval "$(parse_args 'Add notifications' 2>/dev/null)"
assert_eq "extracts the prompt" "$PROMPT" "Add notifications"
assert_eq "defaults --requirements-dir to docs/requirements" "$REQUIREMENTS_DIR" "docs/requirements"
assert_eq "defaults --output-dir to docs/implementation/PENDING" "$OUTPUT_DIR" "docs/implementation/PENDING"

# --requirements-dir override.
PROMPT="" REQUIREMENTS_DIR="" OUTPUT_DIR=""
eval "$(parse_args --requirements-dir /tmp/reqs 'Add notifs' 2>/dev/null)"
assert_eq "honors --requirements-dir override" "$REQUIREMENTS_DIR" "/tmp/reqs"

# --output-dir override.
PROMPT="" REQUIREMENTS_DIR="" OUTPUT_DIR=""
eval "$(parse_args 'Add notifs' --output-dir build/goals 2>/dev/null)"
assert_eq "honors --output-dir override" "$OUTPUT_DIR" "build/goals"

# Empty argv: should fail.
if parse_args >/dev/null 2>&1; then
  nope "rejects empty argv" "non-zero exit" "exit 0"
else
  ok "rejects empty argv"
fi

# Flag without value: should fail.
if parse_args 'Hi' --requirements-dir >/dev/null 2>&1; then
  nope "rejects flag without value" "non-zero exit" "exit 0"
else
  ok "rejects flag without value"
fi

# ------------------------------------------------------------------
# select_workflow_branch — mirrors lib/select_workflow_branch.md
# ------------------------------------------------------------------

# --- BEGIN mirrored lib/select_workflow_branch.md reference implementation ---
select_workflow_branch() {
  local task_file="${1:-}"
  local complexity="" in_key_files=0 saw_key_files=0 line lower path probe
  local -a seen=()

  if [ -n "$task_file" ] && [ -f "$task_file" ] && [ -r "$task_file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      # Markdown allows up to three leading spaces on a heading or table row,
      # and an indented row that went uncounted would undercount key files —
      # which fails toward skip-all, the one direction that ships an
      # unreviewed diff. Normalize before matching.
      line="${line#"${line%%[![:space:]]*}"}"

      # Metadata line: "> Type: work · Complexity: small · Priority: medium"
      case "$line" in
        '> '*'Complexity:'*)
          if [ -z "$complexity" ]; then
            complexity="${line#*Complexity:}"
            complexity="${complexity%%·*}"
            complexity="${complexity#"${complexity%%[![:space:]]*}"}"
            complexity="${complexity%"${complexity##*[![:space:]]}"}"
            complexity="$(printf '%s' "$complexity" | tr '[:upper:]' '[:lower:]')"
          fi
          continue
          ;;
      esac

      # Only the rows under the key-files heading count. Match it
      # case-insensitively: "## Key Files" is the same section to a human, and
      # treating it as a different one silently counts zero files.
      # Match '## ' WITH the trailing space, never a bare '##'. A '###'
      # subheading inside the section must fall through to the row check and
      # leave the flag set — matching it here would close the section early and
      # drop every row below it, which undercounts toward skip-all.
      case "$line" in
        '## '*)
          lower="$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')"
          case "$lower" in
            '## key files'*) in_key_files=1; saw_key_files=1 ;;
            *)               in_key_files=0 ;;
          esac
          continue
          ;;
      esac

      [ "$in_key_files" -eq 1 ] || continue
      case "$line" in
        '|'*) ;;
        *) continue ;;
      esac

      path="${line#|}"
      path="${path%%|*}"
      path="${path#"${path%%[![:space:]]*}"}"
      path="${path%"${path##*[![:space:]]}"}"
      path="${path#\`}"
      path="${path%\`}"

      # Header and separator rows both begin with "|" — drop them. Strip the
      # characters a separator can legally contain and see whether anything is
      # left; a bracket expression like [!-:| ] is read as a RANGE and silently
      # drops real paths.
      [ -z "$path" ] && continue
      [ "$path" = "File" ] && continue
      # Case-insensitive, so this agrees with the enrichment gate's placeholder
      # check — otherwise "(None)" is an empty cell to one parser and a file
      # path to the other, and they describe the same section incompatibly.
      case "$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')" in
        '(none)') continue ;;
      esac
      probe="${path//-/}"
      probe="${probe//:/}"
      [ -z "$probe" ] && continue

      local dup=0 s
      for s in ${seen+"${seen[@]}"}; do
        [ "$s" = "$path" ] && { dup=1; break; }
      done
      [ "$dup" -eq 1 ] && continue
      seen+=("$path")
    done < "$task_file"
  fi

  # A file that HAS a key-files section we could read may legitimately list
  # 0 or 1 paths. A file with no recognizable section at all told us nothing,
  # and nothing is not evidence of a small task — take the safe branch.
  if [ "$saw_key_files" -eq 0 ]; then
    printf '%s' 'full'
    return 0
  fi

  case "$complexity" in
    small)
      if [ "${#seen[@]}" -le 1 ]; then
        printf '%s' 'skip-all'
      else
        printf '%s' 'explore-review'
      fi
      ;;
    medium|large) printf '%s' 'full' ;;
    *)            printf '%s' 'full' ;;
  esac
}
# --- END mirrored lib/select_workflow_branch.md reference implementation ---

echo ""
echo "select_workflow_branch"

# write_task_fixture <path> <metadata-line-or-NONE> <key-file-path>...
write_task_fixture() {
  local target="$1" meta="$2"; shift 2
  mkdir -p "$(dirname "$target")"
  {
    echo "# Fixture task"
    echo ""
    [ "$meta" != "NONE" ] && { echo "$meta"; echo ""; }
    echo "## Description"
    echo ""
    echo "Body prose that mentions Complexity: small in passing."
    echo ""
    echo "## Key files"
    echo ""
    if [ "$#" -eq 0 ]; then
      echo "(none)"
    else
      echo "| File | Note |"
      echo "|---|---|"
      local f
      for f in "$@"; do echo "| \`$f\` | why |"; done
    fi
    echo ""
    echo "## Verification steps"
    echo ""
    echo "| Step | Expected |"
    echo "|---|---|"
    echo "| \`bash test/smoke.sh\` | passes |"
  } > "$target"
}

MATRIX_DIR="$SANDBOX/matrix"
SMALL_META='> Type: work · Complexity: small · Priority: medium'
MEDIUM_META='> Type: work · Complexity: medium · Priority: high'
LARGE_META='> Type: work · Complexity: large · Priority: high'

# Row 1 — small with 0-1 key files skips everything.
write_task_fixture "$MATRIX_DIR/t-small-1.md" "$SMALL_META" "lib/a.ex"
assert_eq "small + 1 key file selects skip-all" \
  "$(select_workflow_branch "$MATRIX_DIR/t-small-1.md")" "skip-all"

write_task_fixture "$MATRIX_DIR/t-small-0.md" "$SMALL_META"
assert_eq "small + (none) key files selects skip-all" \
  "$(select_workflow_branch "$MATRIX_DIR/t-small-0.md")" "skip-all"

# Row 2 — small with 2+ key files explores and reviews, but does not plan.
write_task_fixture "$MATRIX_DIR/t-small-3.md" "$SMALL_META" "lib/a.ex" "lib/b.ex" "test/c.exs"
assert_eq "small + 3 key files selects explore-review, not full" \
  "$(select_workflow_branch "$MATRIX_DIR/t-small-3.md")" "explore-review"

write_task_fixture "$MATRIX_DIR/t-small-2.md" "$SMALL_META" "lib/a.ex" "lib/b.ex"
assert_eq "small + 2 key files crosses the review threshold" \
  "$(select_workflow_branch "$MATRIX_DIR/t-small-2.md")" "explore-review"

# Rows 3 and 4 — medium and large always do all three, whatever the count.
write_task_fixture "$MATRIX_DIR/t-medium-1.md" "$MEDIUM_META" "lib/a.ex"
assert_eq "medium + 1 key file selects full" \
  "$(select_workflow_branch "$MATRIX_DIR/t-medium-1.md")" "full"

write_task_fixture "$MATRIX_DIR/t-medium-0.md" "$MEDIUM_META"
assert_eq "medium + no key files still selects full" \
  "$(select_workflow_branch "$MATRIX_DIR/t-medium-0.md")" "full"

write_task_fixture "$MATRIX_DIR/t-large-1.md" "$LARGE_META" "lib/a.ex"
assert_eq "large + 1 key file selects full" \
  "$(select_workflow_branch "$MATRIX_DIR/t-large-1.md")" "full"

# Row 5 — the conservative fallback. Absence of evidence is not evidence of a
# small task, so every unreadable signal dispatches everything.
write_task_fixture "$MATRIX_DIR/t-unknown.md" '> Type: work · Complexity: enormous · Priority: low' "lib/a.ex"
assert_eq "an unrecognized complexity falls back to full" \
  "$(select_workflow_branch "$MATRIX_DIR/t-unknown.md")" "full"

write_task_fixture "$MATRIX_DIR/t-nometa.md" NONE "lib/a.ex"
assert_eq "a missing metadata line falls back to full" \
  "$(select_workflow_branch "$MATRIX_DIR/t-nometa.md")" "full"

assert_eq "a missing task file falls back to full" \
  "$(select_workflow_branch "$MATRIX_DIR/does-not-exist.md")" "full"

: > "$MATRIX_DIR/t-empty.md"
assert_eq "an empty task file falls back to full" \
  "$(select_workflow_branch "$MATRIX_DIR/t-empty.md")" "full"

# Edge case: the same path twice is one file, so the threshold is not crossed.
write_task_fixture "$MATRIX_DIR/t-dup.md" "$SMALL_META" "lib/a.ex" "lib/a.ex"
assert_eq "a duplicate key-file path counts once, not twice" \
  "$(select_workflow_branch "$MATRIX_DIR/t-dup.md")" "skip-all"

# Edge case: the header and separator rows both start with "|" and must not be
# counted — an empty table would otherwise report 2 and upgrade every task.
printf '# T\n\n%s\n\n## Key files\n\n| File | Note |\n|---|---|\n\n## Next\n' "$SMALL_META" \
  > "$MATRIX_DIR/t-emptytable.md"
assert_eq "an empty key-files table counts 0, not its header rows" \
  "$(select_workflow_branch "$MATRIX_DIR/t-emptytable.md")" "skip-all"

# --- Hardened inputs: an undercounted key-files section fails toward skip-all,
# --- which is the one direction that ships an unreviewed diff.

# Heading cased differently is the same section to a human.
printf '# T\n\n%s\n\n## Key Files\n\n| File | Note |\n|---|---|\n| `lib/a.ex` | x |\n| `lib/b.ex` | x |\n| `lib/c.ex` | x |\n' \
  "$SMALL_META" > "$MATRIX_DIR/t-headingcase.md"
assert_eq "a differently-cased Key Files heading still counts its rows" \
  "$(select_workflow_branch "$MATRIX_DIR/t-headingcase.md")" "explore-review"

# Markdown allows up to three leading spaces on a table row.
printf '# T\n\n%s\n\n## Key files\n\n  | File | Note |\n  |---|---|\n  | `lib/a.ex` | x |\n  | `lib/b.ex` | x |\n' \
  "$SMALL_META" > "$MATRIX_DIR/t-indented.md"
assert_eq "indented key-files rows are still counted" \
  "$(select_workflow_branch "$MATRIX_DIR/t-indented.md")" "explore-review"

# "(none)" rendered as a table row is a placeholder, not a file.
printf '# T\n\n%s\n\n## Key files\n\n| File | Note |\n|---|---|\n| (none) | |\n| `lib/a.ex` | x |\n' \
  "$SMALL_META" > "$MATRIX_DIR/t-nonerow.md"
assert_eq "a (none) table row is not counted as a file" \
  "$(select_workflow_branch "$MATRIX_DIR/t-nonerow.md")" "skip-all"

# A subheading inside the section must not close it — closing early drops every
# row below and undercounts toward skip-all, which is the unsafe direction.
printf '# T\n\n%s\n\n## Key files\n\n### Primary\n\n| File | Note |\n|---|---|\n| `lib/a.ex` | x |\n| `lib/b.ex` | x |\n| `lib/c.ex` | x |\n' \
  "$SMALL_META" > "$MATRIX_DIR/t-subheading.md"
assert_eq "a ### subheading inside key files does not drop its rows" \
  "$(select_workflow_branch "$MATRIX_DIR/t-subheading.md")" "explore-review"

printf '# T\n\n%s\n\n## Key files\n\n| File | Note |\n|---|---|\n| `lib/a.ex` | x |\n\n### Also\n\n| File | Note |\n|---|---|\n| `lib/b.ex` | x |\n' \
  "$SMALL_META" > "$MATRIX_DIR/t-subheading-mid.md"
assert_eq "rows after a mid-section subheading are still counted" \
  "$(select_workflow_branch "$MATRIX_DIR/t-subheading-mid.md")" "explore-review"

# No recognizable key-files section at all told us nothing about the surface area.
printf '# T\n\n%s\n\n## Description\n\nBody.\n' "$SMALL_META" > "$MATRIX_DIR/t-nokeyfiles.md"
assert_eq "a missing key-files section falls back to full, not skip-all" \
  "$(select_workflow_branch "$MATRIX_DIR/t-nokeyfiles.md")" "full"

# Complexity is matched case-insensitively.
write_task_fixture "$MATRIX_DIR/t-caps.md" '> Type: work · Complexity: SMALL · Priority: medium' "lib/a.ex"
assert_eq "an upper-case complexity value is recognized" \
  "$(select_workflow_branch "$MATRIX_DIR/t-caps.md")" "skip-all"

# The metadata line need not carry a trailing separator.
write_task_fixture "$MATRIX_DIR/t-nosep.md" '> Complexity: small' "lib/a.ex"
assert_eq "a metadata line with no trailing separator still parses" \
  "$(select_workflow_branch "$MATRIX_DIR/t-nosep.md")" "skip-all"

# Edge case: a goal whose every task is skip-all dispatches no agent at all.
SKIPGOAL="$MATRIX_DIR/all-small-goal"
write_task_fixture "$SKIPGOAL/task1.md" "$SMALL_META" "lib/a.ex"
write_task_fixture "$SKIPGOAL/task2.md" "$SMALL_META"
write_task_fixture "$SKIPGOAL/task3.md" "$SMALL_META" "lib/c.ex" "lib/c.ex"
GOAL_DISPATCHES=0
for _t in "$SKIPGOAL"/task*.md; do
  [ "$(select_workflow_branch "$_t")" = "skip-all" ] || GOAL_DISPATCHES=$(( GOAL_DISPATCHES + 2 ))
done
assert_eq "an all-small goal dispatches zero agents across every task" "$GOAL_DISPATCHES" "0"

# --- Byte-parity between the mirror above and lib/select_workflow_branch.md.
# Without this the mirror can drift from the shipped spec and every assertion
# above keeps passing against a copy nothing else uses.
BRANCH_LIB_EXTRACT="$SANDBOX/branch-lib.sh"
BRANCH_MIRROR_COPY="$SANDBOX/branch-mirror.sh"
awk '/^```bash$/ { if (seen++) exit; inb=1; next } inb && /^```$/ { exit } inb { print }' \
  "$REPO_ROOT/lib/select_workflow_branch.md" > "$BRANCH_LIB_EXTRACT"
awk '/^# --- BEGIN mirrored lib\/select_workflow_branch/ { inb=1; next }
     /^# --- END mirrored lib\/select_workflow_branch/   { exit }
     inb { print }' "$SCRIPT_DIR/smoke.sh" > "$BRANCH_MIRROR_COPY"

# Guard the extractors: two empty files diff clean and would pass vacuously.
if [ -s "$BRANCH_LIB_EXTRACT" ] && [ -s "$BRANCH_MIRROR_COPY" ]; then
  ok "both select_workflow_branch blocks extracted non-empty"
else
  nope "both select_workflow_branch blocks extracted non-empty" "two non-empty extracts" \
    "lib=$(wc -l < "$BRANCH_LIB_EXTRACT") mirror=$(wc -l < "$BRANCH_MIRROR_COPY")"
fi

if BRANCH_DIFF="$(diff -u "$BRANCH_LIB_EXTRACT" "$BRANCH_MIRROR_COPY" 2>&1)"; then
  ok "mirrored select_workflow_branch is byte-identical to lib/select_workflow_branch.md"
else
  nope "mirrored select_workflow_branch is byte-identical to lib/select_workflow_branch.md" \
    "empty diff against the lib reference implementation" "$BRANCH_DIFF"
fi

# The matrix table in the workflow SKILL.md must carry every branch the helper
# can return and every skip reason it can justify — prose and behaviour drifting
# apart is the failure mode here.
MATRIX_SKILL="$REPO_ROOT/skills/stride-lite-workflow/SKILL.md"
MATRIX_MISSING=""
for _row in 'skip-all' 'explore-review' 'full'; do
  grep -q "\`$_row\`" "$MATRIX_SKILL" || MATRIX_MISSING="$MATRIX_MISSING $_row"
done
for _sig in 'Complexity' 'Key files' 'small_task_0_1_key_files' 'small_task_2_plus_key_files'; do
  grep -q "$_sig" "$MATRIX_SKILL" || MATRIX_MISSING="$MATRIX_MISSING $_sig"
done
assert_eq "the workflow SKILL.md documents every branch and skip reason" "$MATRIX_MISSING" ""

# ------------------------------------------------------------------
# stride-lite-init template — mirrors skills/stride-lite-init/SKILL.md
# ------------------------------------------------------------------
#
# This helper writes the canonical .stride_lite.md template documented in
# stride-lite/skills/stride-lite-init/SKILL.md to a caller-supplied target
# path. It must stay byte-equivalent to the template in the SKILL.md — if
# the SKILL.md changes, update this function in the same commit. That
# byte-equivalence is machine-enforced: the init-flow stage below extracts
# the canonical block from the SKILL.md and diffs it against this function's
# output, so drift fails the run instead of rotting silently.
write_stride_lite_template() {
  local target="${1:-}"
  if [ -z "$target" ]; then
    echo "write_stride_lite_template: usage: write_stride_lite_template <target>" >&2
    return 1
  fi
  mkdir -p "$(dirname "$target")"
  cat > "$target" <<'TEMPLATE'
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
TEMPLATE
}

echo ""
echo "stride-lite-init template"

# Sandbox subdir for the init flow. $SANDBOX is the mktemp -d from earlier in
# the file; the EXIT trap cleans the whole tree.
INIT_DIR="$SANDBOX/init-flow"
INIT_TARGET="$INIT_DIR/.stride_lite.md"
write_stride_lite_template "$INIT_TARGET"

# Assertion 1: the file was written.
if [ -f "$INIT_TARGET" ]; then
  ok "writes .stride_lite.md to the target path"
else
  nope "writes .stride_lite.md to the target path" "file exists" "missing"
fi

# Assertion 1b: byte-parity with the canonical template in the init SKILL.md.
# The canonical block is delimited by the file's only quadruple-backtick fence
# pair (```` ````markdown ```` ... ```` ```` ````); extract it exclusive of the
# fences and diff against the rendered output above.
CANONICAL_TEMPLATE="$INIT_DIR/canonical-template.md"
awk 'in_block && /^````$/ {exit} in_block {print} /^````markdown$/ {in_block=1}' \
  "$REPO_ROOT/skills/stride-lite-init/SKILL.md" > "$CANONICAL_TEMPLATE"
if TEMPLATE_DIFF="$(diff -u "$CANONICAL_TEMPLATE" "$INIT_TARGET" 2>&1)"; then
  ok "embedded template is byte-identical to init SKILL.md canonical block"
else
  nope "embedded template is byte-identical to init SKILL.md canonical block" \
    "empty diff against SKILL.md canonical block" \
    "$TEMPLATE_DIFF"
fi

# Assertion 2: the email section is present.
if grep -qE '^## email$' "$INIT_TARGET"; then
  ok "template contains ## email section"
else
  nope "template contains ## email section" "## email header line" "not found"
fi

# Assertion 3: the three hook sections appear in the exact required order.
BEFORE_LINE=$(grep -nE '^## before_task$' "$INIT_TARGET" | head -1 | cut -d: -f1)
AFTER_LINE=$(grep -nE '^## after_task$' "$INIT_TARGET" | head -1 | cut -d: -f1)
GOAL_LINE=$(grep -nE '^## after_goal$' "$INIT_TARGET" | head -1 | cut -d: -f1)
if [ -n "$BEFORE_LINE" ] && [ -n "$AFTER_LINE" ] && [ -n "$GOAL_LINE" ] \
   && [ "$BEFORE_LINE" -lt "$AFTER_LINE" ] && [ "$AFTER_LINE" -lt "$GOAL_LINE" ]; then
  ok "before_task < after_task < after_goal in the template"
else
  nope "before_task < after_task < after_goal in the template" \
    "all three present and ordered" \
    "before=$BEFORE_LINE after=$AFTER_LINE goal=$GOAL_LINE"
fi

# Assertion 4: collision detection precondition — [ -e ] returns true on the
# now-existing file, so the SKILL.md's clobber-refusal branch would fire on a
# second invocation without --force.
if [ -e "$INIT_TARGET" ]; then
  ok "collision check would refuse second write without --force"
else
  nope "collision check would refuse second write without --force" \
    "[ -e ] returns true on the existing file" "file not present"
fi

# ------------------------------------------------------------------
# task-enricher agent contract
# ------------------------------------------------------------------
#
# The enricher fills ONLY a task file's empty sections. Two invariants matter
# enough to pin: the set of sections it claims to own must exactly partition
# the set the task template renders (so a template change cannot silently leave
# a section unowned or double-owned), and its tool grant must never gain Bash.

echo ""
echo "task-enricher agent contract"

ENRICHER="$REPO_ROOT/agents/task-enricher.md"
TASK_TEMPLATE_SKILL="$REPO_ROOT/skills/stride-lite-create-goal/SKILL.md"
WORKFLOW_SKILL="$REPO_ROOT/skills/stride-lite-workflow/SKILL.md"

if [ -f "$ENRICHER" ]; then
  ok "agents/task-enricher.md exists"
else
  nope "agents/task-enricher.md exists" "the agent file" "missing"
fi

# Required sections, mirroring how the other surface files are structured.
ENRICHER_MISSING=""
for _sec in '## Inputs' '## What this agent does' '## What this agent does NOT do' \
            '## Sections this agent owns' '## Enrichment methodology' \
            '## In-place mutation contract' '## Never copy secrets into the task file' \
            '## Pitfalls'; do
  grep -qxF "$_sec" "$ENRICHER" || ENRICHER_MISSING="$ENRICHER_MISSING [$_sec]"
done
assert_eq "task-enricher.md carries every required section" "$ENRICHER_MISSING" ""

# Four phases, per the acceptance criterion.
ENRICHER_PHASES="$(grep -c '^### Phase [0-9]' "$ENRICHER" | tr -d ' ')"
assert_eq "task-enricher.md documents a four-phase methodology" "$ENRICHER_PHASES" "4"

# The tool grant is a security boundary: no Bash, ever.
# Frontmatter-scoped so a `tools:` mention in the body cannot satisfy it.
ENRICHER_TOOLS="$(awk 'NR==1 && $0=="---" { inb=1; next } inb && /^---$/ { exit }
                       inb && /^tools:[[:space:]]/ { print; exit }' "$ENRICHER")"
assert_eq "task-enricher grants exactly Read, Grep, Glob, Write" \
  "$ENRICHER_TOOLS" "tools: Read, Grep, Glob, Write"
case "$ENRICHER_TOOLS" in
  *Edit*) nope "task-enricher holds no Edit tool" \
            "no Edit — read-whole/write-once is enforced by the tool list" "$ENRICHER_TOOLS" ;;
  *) ok "task-enricher holds no Edit tool" ;;
esac
case "$ENRICHER_TOOLS" in
  *Bash*) nope "task-enricher's tool grant excludes Bash" "no Bash in the tools line" "$ENRICHER_TOOLS" ;;
  '') nope "task-enricher's tool grant excludes Bash" "a tools: line" "none found" ;;
  *) ok "task-enricher's tool grant excludes Bash" ;;
esac
case "$ENRICHER_TOOLS" in
  *Read*Grep*Glob*) ok "task-enricher's tool grant includes Read, Grep and Glob" ;;
  *) nope "task-enricher's tool grant includes Read, Grep and Glob" "Read, Grep, Glob" "$ENRICHER_TOOLS" ;;
esac

# --- Heading-sync invariant -----------------------------------------------
# The template's headings must be exactly partitioned by the agent's owned and
# protected lists. Extract all three from their real sources so neither side
# can drift without this failing.
# Anchor on the taskN.md template heading — the file also carries a goal.md
# template fence earlier, and taking the first fence would read the wrong one.
TEMPLATE_HEADINGS="$(awk '
  /^### taskN\.md template$/ { armed=1; next }
  armed && /^```markdown$/    { armed=0; inb=1; next }
  inb && /^```$/              { exit }
  inb && /^## /               { print }
' "$TASK_TEMPLATE_SKILL" | sort -u)"
TEMPLATE_COUNT="$(printf '%s\n' "$TEMPLATE_HEADINGS" | grep -c '^## ')"
assert_eq "the taskN template renders 14 sections" "$TEMPLATE_COUNT" "14"

# The agent's owned/protected table: two columns of backticked headings.
OWNED_HEADINGS="$(awk -F'|' '
  /^\| Owned \(fillable when sparse\) \| Protected \(never touched\) \|/ { inb=1; next }
  inb && /^\|[-: |]+\|$/ { next }
  inb && /^\|/ { print $2; next }
  inb { exit }
' "$ENRICHER" | tr -d '`' | sed -E 's/^ +//; s/ +$//' | grep '^## ' | sort -u)"
PROTECTED_HEADINGS="$(awk -F'|' '
  /^\| Owned \(fillable when sparse\) \| Protected \(never touched\) \|/ { inb=1; next }
  inb && /^\|[-: |]+\|$/ { next }
  inb && /^\|/ { print $3; next }
  inb { exit }
' "$ENRICHER" | tr -d '`' | sed -E 's/^ +//; s/ +$//' | grep '^## ' | sort -u)"

OWNED_COUNT="$(printf '%s\n' "$OWNED_HEADINGS" | grep -c '^## ')"
PROTECTED_COUNT="$(printf '%s\n' "$PROTECTED_HEADINGS" | grep -c '^## ')"
assert_eq "the agent claims 11 owned sections" "$OWNED_COUNT" "11"
assert_eq "the agent claims 3 protected sections" "$PROTECTED_COUNT" "3"

# Disjoint: no heading may be both owned and protected.
BOTH="$(printf '%s\n%s\n' "$OWNED_HEADINGS" "$PROTECTED_HEADINGS" | sort | uniq -d)"
assert_eq "no section is both owned and protected" "$BOTH" ""

# Exhaustive: owned + protected covers exactly the template's headings.
UNION="$(printf '%s\n%s\n' "$OWNED_HEADINGS" "$PROTECTED_HEADINGS" | sort -u)"
if UNION_DIFF="$(diff <(printf '%s\n' "$TEMPLATE_HEADINGS") <(printf '%s\n' "$UNION") 2>&1)"; then
  ok "owned + protected is exactly the set of template headings"
else
  nope "owned + protected is exactly the set of template headings" \
    "the agent's two lists to partition the template's 14 headings" "$UNION_DIFF"
fi

# The three intent sections are the protected ones, named explicitly.
PROTECTED_EXPECTED="$(printf '%s\n' '## Description' '## What' '## Why')"
assert_eq "the protected set is exactly Description, Why and What" \
  "$PROTECTED_HEADINGS" "$PROTECTED_EXPECTED"

# The workflow's Step 1a must name every owned section it will check.
#
# Grep the STEP 1a SLICE, not the whole file: Step 4 already backticks all
# fourteen template headings as the implementer's spec list, so a whole-file
# grep succeeds even if Step 1a is deleted outright.
STEP1A_SLICE="$(awk '/^### Step 1a/ { f=1; next } /^### Step 2 / { f=0 } f' "$WORKFLOW_SKILL")"

if [ -n "$STEP1A_SLICE" ]; then
  ok "the workflow SKILL.md has a Step 1a enrichment section"
else
  nope "the workflow SKILL.md has a Step 1a enrichment section" \
    "a '### Step 1a' section before Step 2" "not found"
fi

case "$STEP1A_SLICE" in
  *"stride-lite:task-enricher"*) ok "Step 1a dispatches stride-lite:task-enricher" ;;
  *) nope "Step 1a dispatches stride-lite:task-enricher" "the agent named in Step 1a" "$STEP1A_SLICE" ;;
esac

STEP1A_MISSING=""
while IFS= read -r _h; do
  [ -n "$_h" ] || continue
  case "$STEP1A_SLICE" in
    *"\`$_h\`"*) ;;
    *) STEP1A_MISSING="$STEP1A_MISSING [$_h]" ;;
  esac
done <<EOF_HEADINGS
$OWNED_HEADINGS
EOF_HEADINGS
assert_eq "Step 1a names every owned section" "$STEP1A_MISSING" ""

# Step 1a must also state the ordering constraint against Step 3's matrix —
# enriching after the matrix resolves would route a task that is about to gain
# key files straight to skip-all.
case "$STEP1A_SLICE" in
  *"BEFORE Step 3"*) ok "Step 1a states it must run before Step 3's matrix" ;;
  *) nope "Step 1a states it must run before Step 3's matrix" "the ordering rationale" "$STEP1A_SLICE" ;;
esac

# --- Sparse detection ------------------------------------------------------
# Mirrors the rule both the workflow Step 1a and the agent file document: a
# section is sparse when its body is empty, whitespace-only, or exactly the
# "- (none)" empty-list placeholder.
count_sparse_sections() {
  local file="$1" current="" body_has_content=0 sparse=0 line probe cell
  local -a owned=('## Where' '## Acceptance criteria' '## Patterns to follow' \
                  '## Pitfalls' '## Security considerations' '## Integration points' \
                  '## Technology requirements' '## Logging requirements' \
                  '## Key files' '## Verification steps' '## Testing strategy')
  [ -f "$file" ] || { printf '0'; return 0; }

  _enricher_flush() {
    [ -n "$current" ] || return 0
    local o lo
    for o in "${owned[@]}"; do
      lo="$(printf '%s' "$o" | tr '[:upper:]' '[:lower:]')"
      # PREFIX match, not equality — select_workflow_branch matches its heading
      # with `case "$lower" in '## key files'*)`, so "## Key files:" and
      # "## Key files (updated)" are the same section to it. Requiring exact
      # equality here would make the gate blind to a heading the matrix sees,
      # which is the neither-enriched-nor-reviewed hazard one axis over.
      # No owned or protected heading is a prefix of another, so this is safe.
      case "$current" in
        "$lo"*)
          if [ "$body_has_content" -eq 0 ]; then sparse=$(( sparse + 1 )); fi
          ;;
      esac
    done
  }

  while IFS= read -r line || [ -n "$line" ]; do
    # Trim FIRST, then match — and match the heading case-insensitively. This
    # must agree with select_workflow_branch, which reads the same ## Key files
    # section: if one parser sees "## Key Files" or an indented heading as a
    # different section and the other does not, a task can be judged
    # not-sparse (no enrichment) and zero-key-files (skip-all) at once.
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    case "$line" in
      '## '*)
        _enricher_flush
        current="$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')"
        body_has_content=0
        continue
        ;;
    esac
    [ -n "$current" ] || continue
    [ -z "$line" ] && continue

    # A table row: judge it by its first cell, the way the key-files table is
    # rendered. This is what makes "| (none) | |" and a header-plus-separator
    # table read as EMPTY — without it the thinnest task files, the ones that
    # most need enrichment, would be classified as populated.
    case "$line" in
      '|'*)
        cell="${line#|}"
        cell="${cell%%|*}"
        cell="${cell#"${cell%%[![:space:]]*}"}"
        cell="${cell%"${cell##*[![:space:]]}"}"
        cell="${cell#\`}"
        cell="${cell%\`}"
        [ -z "$cell" ] && continue
        [ "$cell" = "File" ] && continue
        probe="${cell//-/}"; probe="${probe//:/}"
        [ -z "$probe" ] && continue
        case "$(printf '%s' "$cell" | tr '[:upper:]' '[:lower:]')" in
          '(none)') continue ;;
        esac
        body_has_content=1
        continue
        ;;
    esac

    # A prose or bullet line. Strip one bullet marker, then compare the WHOLE
    # line with "(none)" — a substring match would misclassify the shipped
    # fixture's "- (none for this task — ...)" prose as a placeholder.
    cell="${line#- }"
    cell="${cell#\* }"
    cell="${cell#\`}"
    cell="${cell%\`}"
    case "$(printf '%s' "$cell" | tr '[:upper:]' '[:lower:]')" in
      '(none)'|'') continue ;;
    esac
    body_has_content=1
  done < "$file"
  _enricher_flush

  printf '%s' "$sparse"
}

# write_sparse_fixture <path> <body-for-the-three-derivable-sections> [<body-for-the-intent-sections>]
write_sparse_fixture() {
  local target="$1" filler="$2" intent="${3:-- real content}" h
  mkdir -p "$(dirname "$target")"
  {
    echo "# Fixture task"
    echo ""
    echo "> Type: work · Complexity: small · Priority: medium"
    for h in '## Description' '## Why' '## What' '## Where' '## Acceptance criteria' \
             '## Patterns to follow' '## Pitfalls' '## Security considerations' \
             '## Integration points' '## Technology requirements' \
             '## Logging requirements' '## Key files' '## Verification steps' \
             '## Testing strategy'; do
      echo ""
      echo "$h"
      echo ""
      case "$h" in
        '## Key files'|'## Patterns to follow'|'## Testing strategy') echo "$filler" ;;
        '## Description'|'## Why'|'## What') echo "$intent" ;;
        *) echo "- real content" ;;
      esac
    done
  } > "$target"
}

ENRICH_DIR="$SANDBOX/enricher"

write_sparse_fixture "$ENRICH_DIR/sparse.md" "- (none)"
assert_eq "three (none) sections are detected as sparse" \
  "$(count_sparse_sections "$ENRICH_DIR/sparse.md")" "3"

write_sparse_fixture "$ENRICH_DIR/populated.md" "- something concrete"
assert_eq "a fully-populated task file is detected as not sparse" \
  "$(count_sparse_sections "$ENRICH_DIR/populated.md")" "0"

# Edge case: heading present, body is whitespace only.
write_sparse_fixture "$ENRICH_DIR/whitespace.md" "   "
assert_eq "a whitespace-only body counts as sparse" \
  "$(count_sparse_sections "$ENRICH_DIR/whitespace.md")" "3"

# Edge case: a prior task-explorer run left an Exploration Report at the bottom.
cp "$ENRICH_DIR/sparse.md" "$ENRICH_DIR/with-report.md"
printf '\n## Exploration Report\n\n### File state\n\n- (none)\n' >> "$ENRICH_DIR/with-report.md"
assert_eq "an existing Exploration Report does not change the sparse count" \
  "$(count_sparse_sections "$ENRICH_DIR/with-report.md")" "3"

# The intent sections are never counted, even when empty. Built in pure bash so
# the case cannot silently degrade on a host without python3.
write_sparse_fixture "$ENRICH_DIR/intent-empty.md" "- something concrete" "- (none)"
assert_eq "empty intent sections are never counted as sparse" \
  "$(count_sparse_sections "$ENRICH_DIR/intent-empty.md")" "0"

# ...and an intent-empty file whose derivable sections are ALSO empty still
# counts only the derivable ones.
write_sparse_fixture "$ENRICH_DIR/both-empty.md" "- (none)" "- (none)"
assert_eq "only derivable sections are counted when intent is empty too" \
  "$(count_sparse_sections "$ENRICH_DIR/both-empty.md")" "3"

# --- Table-rendered placeholder shapes ------------------------------------
# ## Key files renders as a TABLE. If "| (none) | |" or a header-plus-separator
# table read as populated, the enricher would never fire on exactly the thinnest
# task files — while select_workflow_branch counts the same section as zero and
# routes them to skip-all. That combination is no enrichment AND no review.
ENRICH_TABLE_DIR="$ENRICH_DIR/tables"
mkdir -p "$ENRICH_TABLE_DIR"

_write_keyfiles_variant() {
  printf '# T\n\n> Type: work · Complexity: small · Priority: medium\n\n## Key files\n\n%b\n\n## Verification steps\n\n- real content\n' \
    "$2" > "$1"
}

_write_keyfiles_variant "$ENRICH_TABLE_DIR/none-row.md"   '| File | Note |\n|---|---|\n| (none) | |'
_write_keyfiles_variant "$ENRICH_TABLE_DIR/empty-table.md" '| File | Note |\n|---|---|'
_write_keyfiles_variant "$ENRICH_TABLE_DIR/bare-none.md"   '(none)'
_write_keyfiles_variant "$ENRICH_TABLE_DIR/real.md"        '| File | Note |\n|---|---|\n| `lib/a.ex` | why |'

assert_eq "a (none) table row counts the section as sparse" \
  "$(count_sparse_sections "$ENRICH_TABLE_DIR/none-row.md")" "1"
assert_eq "a header-plus-separator table counts the section as sparse" \
  "$(count_sparse_sections "$ENRICH_TABLE_DIR/empty-table.md")" "1"
assert_eq "a bare (none) line counts the section as sparse" \
  "$(count_sparse_sections "$ENRICH_TABLE_DIR/bare-none.md")" "1"
assert_eq "a real table row counts the section as populated" \
  "$(count_sparse_sections "$ENRICH_TABLE_DIR/real.md")" "0"

# Whole-line equality, not substring: the shipped fixture renders
# "- (none for this task — ...)", which is prose and must stay content.
assert_eq "the shipped fully-populated fixture reports nothing sparse" \
  "$(count_sparse_sections "$REPO_ROOT/fixtures/expected-output/task1.md")" "0"

# --- The enrichment gate and the decision matrix must agree ----------------
# They read the same ## Key files TABLE with two different parsers. If they
# disagree, a task can be judged "has key files" (no enrichment) and "zero key
# files" (skip-all) at once — neither enriched nor reviewed. The agreement is
# scoped to table-shaped bodies: select_workflow_branch counts rows only, so a
# bullet-list key-files section is zero there and populated here. That is a
# pre-existing limitation of that helper, recorded in its own Edge cases.
assert_eq "bare (none) key files: sparse here, skip-all in the matrix" \
  "$(count_sparse_sections "$MATRIX_DIR/t-small-0.md")/$(select_workflow_branch "$MATRIX_DIR/t-small-0.md")" \
  "1/skip-all"
assert_eq "header-only key-files table: sparse here, skip-all in the matrix" \
  "$(count_sparse_sections "$MATRIX_DIR/t-emptytable.md")/$(select_workflow_branch "$MATRIX_DIR/t-emptytable.md")" \
  "1/skip-all"
assert_eq "a (none) row beside one real file: populated here, skip-all in the matrix" \
  "$(count_sparse_sections "$MATRIX_DIR/t-nonerow.md")/$(select_workflow_branch "$MATRIX_DIR/t-nonerow.md")" \
  "0/skip-all"
assert_eq "two real key files: not sparse here, explore-review in the matrix" \
  "$(count_sparse_sections "$MATRIX_DIR/t-small-2.md")/$(select_workflow_branch "$MATRIX_DIR/t-small-2.md")" \
  "0/explore-review"

# Heading variants must be seen identically by BOTH parsers. A capital-F or
# indented heading that one sees and the other does not is how a task ends up
# neither enriched nor reviewed — the same divergence class that bit the
# decision matrix in the task before this one.
_write_keyfiles_variant "$ENRICH_TABLE_DIR/capital.md" '| File | Note |\n|---|---|\n| (none) | |'
sed -i.bak 's/^## Key files$/## Key Files/' "$ENRICH_TABLE_DIR/capital.md" && rm -f "$ENRICH_TABLE_DIR/capital.md.bak"
assert_eq "a capital-F Key Files heading is still classified" \
  "$(count_sparse_sections "$ENRICH_TABLE_DIR/capital.md")" "1"

_write_keyfiles_variant "$ENRICH_TABLE_DIR/indented.md" '| File | Note |\n|---|---|\n| (none) | |'
sed -i.bak 's/^## Key files$/   ## Key files/' "$ENRICH_TABLE_DIR/indented.md" && rm -f "$ENRICH_TABLE_DIR/indented.md.bak"
assert_eq "an indented Key files heading is still classified" \
  "$(count_sparse_sections "$ENRICH_TABLE_DIR/indented.md")" "1"

# And both parsers must agree on those variants, not merely each behave.
MATRIX_CAPITAL="$ENRICH_TABLE_DIR/matrix-capital.md"
printf '# T\n\n> Type: work · Complexity: small · Priority: medium\n\n## Key Files\n\n| File | Note |\n|---|---|\n| `lib/a.ex` | x |\n| `lib/b.ex` | x |\n\n## Verification steps\n\n- real\n' > "$MATRIX_CAPITAL"
assert_eq "capital heading with two real files: not sparse, and the matrix reviews" \
  "$(count_sparse_sections "$MATRIX_CAPITAL")/$(select_workflow_branch "$MATRIX_CAPITAL")" \
  "0/explore-review"

# The pure "(none)"-only table, cross-checked against both parsers.
assert_eq "a (none)-only key-files table: sparse here, skip-all in the matrix" \
  "$(count_sparse_sections "$ENRICH_TABLE_DIR/none-row.md")/$(select_workflow_branch "$ENRICH_TABLE_DIR/none-row.md")" \
  "1/skip-all"

# The sparse rule is worded identically in the workflow skill and the agent —
# the cross-file agreement of this rule is what makes the two documents one
# contract, so claim it only if it is pinned.
# Anchor to the rule's LOCATION, not to any occurrence in the file. The phrase
# also appears in the agent's frontmatter description, and a whole-file grep is
# satisfied by that blurb while the normative rule is free to drift — a grep
# whose scope is wider than its subject, which is the shape of every coverage
# gap this stage has had.
SPARSE_RULE='absent, empty, whitespace-only, or a `(none)` placeholder in any rendered shape'

# In the agent: the classification rule inside the fenced "What this agent does" block.
ENRICHER_RULE_SLICE="$(awk '/^## What this agent does$/ { f=1; next } f && /^## / { exit } f' "$ENRICHER")"
case "$ENRICHER_RULE_SLICE" in
  *"$SPARSE_RULE"*) ok "the agent states the sparse rule in its classification block" ;;
  *) nope "the agent states the sparse rule in its classification block" \
       "the rule inside '## What this agent does'" "$ENRICHER_RULE_SLICE" ;;
esac

# In the workflow: the Step 1a slice extracted above.
case "$STEP1A_SLICE" in
  *"$SPARSE_RULE"*) ok "Step 1a states the sparse rule in its own section" ;;
  *) nope "Step 1a states the sparse rule in its own section" "the rule inside Step 1a" "$STEP1A_SLICE" ;;
esac

# A suffixed heading is the same section to select_workflow_branch, so it must
# be the same section to the gate too.
_write_keyfiles_variant "$ENRICH_TABLE_DIR/suffix-colon.md" '| File | Note |\n|---|---|\n| (none) | |'
sed -i.bak 's/^## Key files$/## Key files:/' "$ENRICH_TABLE_DIR/suffix-colon.md" && rm -f "$ENRICH_TABLE_DIR/suffix-colon.md.bak"
assert_eq "a colon-suffixed Key files heading is still classified" \
  "$(count_sparse_sections "$ENRICH_TABLE_DIR/suffix-colon.md")" "1"

MATRIX_SUFFIX="$ENRICH_TABLE_DIR/matrix-suffix.md"
printf '# T\n\n> Type: work · Complexity: small · Priority: medium\n\n## Key files (updated)\n\n| File | Note |\n|---|---|\n| (none) | |\n\n## Verification steps\n\n- real\n' > "$MATRIX_SUFFIX"
assert_eq "a parenthetical-suffixed heading: sparse here, skip-all in the matrix" \
  "$(count_sparse_sections "$MATRIX_SUFFIX")/$(select_workflow_branch "$MATRIX_SUFFIX")" \
  "1/skip-all"

# Mixed-case placeholders must read the same way to both parsers.
MATRIX_MIXED="$ENRICH_TABLE_DIR/matrix-mixedcase.md"
printf '# T\n\n> Type: work · Complexity: small · Priority: medium\n\n## Key files\n\n| File | Note |\n|---|---|\n| (None) | |\n| (NONE) | |\n\n## Verification steps\n\n- real\n' > "$MATRIX_MIXED"
assert_eq "mixed-case (none) rows: sparse here, skip-all in the matrix" \
  "$(count_sparse_sections "$MATRIX_MIXED")/$(select_workflow_branch "$MATRIX_MIXED")" \
  "1/skip-all"

# --- Step 1a's trigger set is the four gate sections, not all eleven -------
STEP1A_TRIGGERS=""
for _t in '## Key files' '## Acceptance criteria' '## Verification steps' '## Testing strategy'; do
  case "$STEP1A_SLICE" in
    *"\`$_t\`"*) ;;
    *) STEP1A_TRIGGERS="$STEP1A_TRIGGERS [$_t]" ;;
  esac
done
assert_eq "Step 1a names all four trigger sections" "$STEP1A_TRIGGERS" ""
case "$STEP1A_SLICE" in
  *"strict subset"*) ok "Step 1a states the trigger set is a subset of the fillable set" ;;
  *) nope "Step 1a states the trigger set is a subset of the fillable set" \
       "the trigger-subset rationale" "$STEP1A_SLICE" ;;
esac

# install.sh's dynamic agent count must match the files on disk.
INSTALL_AGENT_COUNT="$(ls "$REPO_ROOT/agents"/*.md 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "the agents/ directory holds five subagents" "$INSTALL_AGENT_COUNT" "5"
if grep -q 'ls "$TARGET_DIR/agents"/\*\.md' "$REPO_ROOT/install.sh"; then
  ok "install.sh counts agents dynamically rather than hard-coding a number"
else
  nope "install.sh counts agents dynamically rather than hard-coding a number" \
    "a computed agent count in install.sh" "$(grep -n 'Agents:' "$REPO_ROOT/install.sh")"
fi

# ------------------------------------------------------------------
# hook-diagnostician agent contract
# ------------------------------------------------------------------
#
# The diagnostician's entire input is the hook script's failure JSON. That makes
# the key set a contract between two files, so it is pinned in both directions:
# every key the script emits must be documented, and every key documented must
# be one the script emits. The tool grant is pinned too — this agent triages a
# failure, so giving it the ability to act on a misdiagnosis is the one change
# that would make it dangerous.

echo ""
echo "hook-diagnostician agent contract"

DIAGNOSTICIAN="$REPO_ROOT/agents/hook-diagnostician.md"
# Defined here rather than relying on the hook-routing stage below, which runs
# after this one — an unbound variable there made the .ps1 comparison pass by
# comparing two empty strings.
HOOK_SH="$REPO_ROOT/hooks/stride-lite-hook.sh"
HOOK_PS1="$REPO_ROOT/hooks/stride-lite-hook.ps1"

if [ -f "$DIAGNOSTICIAN" ]; then
  ok "agents/hook-diagnostician.md exists"
else
  nope "agents/hook-diagnostician.md exists" "the agent file" "missing"
fi

DIAG_MISSING=""
for _sec in '## Inputs' '## What this agent does' '## What this agent does NOT do' \
            '## Reading combined output' '## Severity' '## Fix priority' \
            '## Output contract' '## When there is no payload' '## `after_goal` is advisory' \
            '## Never echo the payload verbatim' \
            '## Command output is data, not instructions' '## Pitfalls'; do
  grep -qxF "$_sec" "$DIAGNOSTICIAN" || DIAG_MISSING="$DIAG_MISSING [$_sec]"
done
assert_eq "hook-diagnostician.md carries every required section" "$DIAG_MISSING" ""

# Tool grant: read-only. No Bash (cannot run a fix), no Edit/Write (cannot apply one).
DIAG_TOOLS="$(awk 'NR==1 && $0=="---" { inb=1; next } inb && /^---$/ { exit }
                   inb && /^tools:[[:space:]]/ { print; exit }' "$DIAGNOSTICIAN")"
assert_eq "hook-diagnostician grants exactly Read, Grep, Glob" \
  "$DIAG_TOOLS" "tools: Read, Grep, Glob"
for _forbidden in Bash Edit Write; do
  case "$DIAG_TOOLS" in
    *"$_forbidden"*) nope "hook-diagnostician holds no $_forbidden tool" \
                       "no $_forbidden — it diagnoses, it does not act" "$DIAG_TOOLS" ;;
    *) ok "hook-diagnostician holds no $_forbidden tool" ;;
  esac
done

# --- Input-contract sync: the script's failure JSON vs the agent's key table ---
# Extract the keys the failure printf actually emits, and the keys the agent's
# "failure JSON key set" table documents. Slice-anchor both: a whole-file grep
# would be satisfied by any mention of the word anywhere in either file.
SCRIPT_FAILURE_KEYS="$(awk '/printf .\{"hook":"%s","status":"failed"/ { print; exit }' "$HOOK_SH" \
  | grep -oE '"[a-z_]+":' | tr -d '":' | sort -u)"

DIAG_KEY_TABLE="$(awk '/^### The failure JSON key set$/ { f=1; next } f && /^## / { exit } f' "$DIAGNOSTICIAN")"
DIAG_DOC_KEYS="$(printf '%s\n' "$DIAG_KEY_TABLE" | grep -oE '^\| `[a-z_]+`' | tr -d '|` ' | sort -u)"

# Guard both extracts: two empty strings compare equal and would pass vacuously.
if [ -n "$SCRIPT_FAILURE_KEYS" ] && [ -n "$DIAG_DOC_KEYS" ]; then
  ok "both failure-JSON key lists extracted non-empty"
else
  nope "both failure-JSON key lists extracted non-empty" "two non-empty key lists" \
    "script=[$SCRIPT_FAILURE_KEYS] doc=[$DIAG_DOC_KEYS]"
fi

assert_eq "the agent documents exactly the keys the failure JSON emits" \
  "$DIAG_DOC_KEYS" "$SCRIPT_FAILURE_KEYS"

assert_eq "the failure JSON carries nine keys" \
  "$(printf '%s\n' "$SCRIPT_FAILURE_KEYS" | grep -c .)" "9"

# The .ps1 must emit the same key set — the parity contract covers the result JSON.
# NOTE: POSIX awk has no \s escape — using it here silently failed to match the
# closing brace, so the extractor ran past the block and swept up later code.
PS_FAILURE_KEYS="$(awk '/\$failureResult = \[ordered\]@\{/ { f=1; next }
                        f && /^[[:space:]]*\}/ { exit }
                        f && /=/ { print }' "$HOOK_PS1" \
  | sed -E 's/^[[:space:]]*([a-z_]+)[[:space:]]*=.*/\1/' | sort -u)"
if [ -n "$PS_FAILURE_KEYS" ]; then
  ok "the .ps1 failure-JSON key list extracted non-empty"
else
  nope "the .ps1 failure-JSON key list extracted non-empty" "a non-empty key list" "empty"
fi
assert_eq "the .ps1 failure JSON emits the same key set as the .sh" \
  "$PS_FAILURE_KEYS" "$SCRIPT_FAILURE_KEYS"

# --- Workflow wiring: both blocking paths dispatch it, and still stop ---
DIAG_WIRING_MISSING=""
# Labelled by the section actually sliced — the before_task failure text lives
# in Step 2 and the after_task one in Step 5, so labelling them 3 and 6 would
# send whoever hits a red line to the wrong heading.
for _step in 'Step 2 (before_task)' 'Step 5 (after_task)'; do
  case "$_step" in
    'Step 2'*) _slice="$(awk '/^### Step 2 /{f=1;next} /^### Step 3 /{f=0} f' "$WORKFLOW_SKILL")" ;;
    'Step 5'*) _slice="$(awk '/^### Step 5 /{f=1;next} /^### Step 6 /{f=0} f' "$WORKFLOW_SKILL")" ;;
  esac
  case "$_slice" in
    *"stride-lite:hook-diagnostician"*) ;;
    *) DIAG_WIRING_MISSING="$DIAG_WIRING_MISSING [$_step]" ;;
  esac
  # Triage must not replace the stop.
  case "$_slice" in
    *"stop the workflow"*) ;;
    *) DIAG_WIRING_MISSING="$DIAG_WIRING_MISSING [$_step-no-stop]" ;;
  esac
done
assert_eq "both blocking-failure paths dispatch the diagnostician and still stop" \
  "$DIAG_WIRING_MISSING" ""

# The advisory after_goal path mentions it WITHOUT making it mandatory.
AFTER_GOAL_SLICE="$(awk '/PostToolUse cannot roll back the write/ { f=1 } f { print }
                         f && /Move the goal directory/ { exit }' "$WORKFLOW_SKILL")"
case "$AFTER_GOAL_SLICE" in
  *"stride-lite:hook-diagnostician"*) ok "the advisory after_goal path mentions the diagnostician" ;;
  *) nope "the advisory after_goal path mentions the diagnostician" "an optional dispatch" "$AFTER_GOAL_SLICE" ;;
esac
# Assert on a DISCRIMINATING phrase plus a negative guard. A bare `*optional*`
# substring test survives the negation "not optional", which is precisely the
# violation this criterion is about — and a criterion whose whole content is a
# negative is the one shape a substring match cannot express.
AFTER_GOAL_OPTIONAL=1
case "$AFTER_GOAL_SLICE" in
  *'You **may** dispatch'*) ;;
  *) AFTER_GOAL_OPTIONAL=0 ;;
esac
case "$AFTER_GOAL_SLICE" in
  *"MUST dispatch"*|*"must dispatch"*|*"not optional"*) AFTER_GOAL_OPTIONAL=0 ;;
esac
if [ "$AFTER_GOAL_OPTIONAL" -eq 1 ]; then
  ok "the advisory after_goal dispatch is optional, not mandatory"
else
  nope "the advisory after_goal dispatch is optional, not mandatory" \
    "'You **may** dispatch' present and no mandatory phrasing" "$AFTER_GOAL_SLICE"
fi

# ------------------------------------------------------------------
# hook routing (stride-lite-hook.sh)
# ------------------------------------------------------------------
#
# Feeds synthetic hook JSON payloads through hooks/stride-lite-hook.sh as a
# full subprocess (the same way the Claude Code harness invokes it via
# hooks.json) and asserts the routing + exit-code contract: before_task and
# after_task are blocking PreToolUse intercepts on the two Agent dispatches
# (a failing section exits 2), after_goal is an advisory PostToolUse
# intercept on the goal.md Completion Summary write (a failing section still
# exits 0), and non-matching payloads pass through with empty stdout. All
# fixture commands are inert (true/false) and confined to the sandbox via a
# per-invocation CLAUDE_PROJECT_DIR prefix — the hook resolves its config
# and runs sections there, never in the repo.

echo ""
echo "hook routing (stride-lite-hook.sh)"

HOOK_SH="$REPO_ROOT/hooks/stride-lite-hook.sh"
HOOK_PS1="$REPO_ROOT/hooks/stride-lite-hook.ps1"
HOOK_OUT=""
HOOK_ERR=""
HOOK_RC=0

# run_hook <phase> <project-dir> <payload-json> — sets HOOK_OUT / HOOK_ERR / HOOK_RC.
# printf '%s' only: the payloads carry literal \n escapes that echo would
# mangle. Stdout carries the JSON contract; stderr is captured separately
# because the hook mirrors each command's stdout to stderr on the success
# path, which is where the injected env values are observable.
run_hook() {
  local phase="$1" dir="$2" payload="$3"
  local errfile
  errfile="$(mktemp)"
  HOOK_OUT="$(printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$dir" bash "$HOOK_SH" "$phase" 2>"$errfile")"
  HOOK_RC=$?
  HOOK_ERR="$(cat "$errfile" 2>/dev/null)"
  rm -f "$errfile"
}

# assert_hook_out <label> <marker> — HOOK_OUT must contain the marker.
assert_hook_out() {
  local label="$1" marker="$2"
  case "$HOOK_OUT" in
    *"$marker"*) ok "$label" ;;
    *) nope "$label" "$marker in stdout" "$HOOK_OUT" ;;
  esac
}

# assert_hook_err <label> <marker> — HOOK_ERR must contain the marker.
assert_hook_err() {
  local label="$1" marker="$2"
  case "$HOOK_ERR" in
    *"$marker"*) ok "$label" ;;
    *) nope "$label" "$marker in stderr" "$HOOK_ERR" ;;
  esac
}

# refute_hook_err <label> <marker> — HOOK_ERR must NOT contain the marker.
refute_hook_err() {
  local label="$1" marker="$2"
  case "$HOOK_ERR" in
    *"$marker"*) nope "$label" "$marker absent from stderr" "$HOOK_ERR" ;;
    *) ok "$label" ;;
  esac
}

# write_activation_marker <project-dir> [<seconds-ago>] — write the workflow's
# activation marker so the hook will actually run a section. Every fixture
# project below needs one: without it the gate makes the hook a no-op, which is
# the whole point of W2010. Pass a seconds-ago value to forge a stale marker.
# The timestamp arithmetic is portable across BSD/macOS and GNU date.
write_activation_marker() {
  local dir="$1" ago="${2:-0}" stamp
  mkdir -p "$dir/.stride-lite"
  # Epoch arithmetic FIRST, then format. `date -v` cannot express a negative
  # seconds-ago (it renders as `-v--18000S`, which BSD date rejects), so the
  # future-dated case must not go through it. `-r <epoch>` is BSD/macOS and
  # `-d @<epoch>` is GNU; both accept any sign.
  local epoch
  epoch=$(( $(date -u +%s) - ago ))
  stamp="$(date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  if [ -z "$stamp" ]; then
    # Never write an empty started_at: it reads as "not fresh", which would make
    # a stale or future assertion pass for the wrong reason.
    echo "write_activation_marker: no usable date(1) formatter on this host" >&2
    return 1
  fi
  printf '{"session_id":"smoke","started_at":"%s","pid":%d}\n' "$stamp" "$$" \
    > "$dir/.stride-lite/.orchestrator_active"
}

# Two fixture configs: every section succeeds vs. blocking/advisory sections fail.
HOOK_PASS_DIR="$SANDBOX/hook-pass"
mkdir -p "$HOOK_PASS_DIR"
write_activation_marker "$HOOK_PASS_DIR"
cat > "$HOOK_PASS_DIR/.stride_lite.md" <<'CONFIG'
## email

hook-fixture@example.com

## before_task

```bash
true
```

## after_task

```bash
true
```

## after_goal

```bash
true
```
CONFIG

HOOK_FAIL_DIR="$SANDBOX/hook-fail"
mkdir -p "$HOOK_FAIL_DIR"
write_activation_marker "$HOOK_FAIL_DIR"
cat > "$HOOK_FAIL_DIR/.stride_lite.md" <<'CONFIG'
## email

hook-fixture@example.com

## before_task

```bash
false
```

## after_task

```bash
```

## after_goal

```bash
false
```
CONFIG

EXPLORER_PAYLOAD='{"tool_name":"Agent","tool_input":{"subagent_type":"stride-lite:task-explorer","prompt":"Explore the task"}}'
REVIEWER_PAYLOAD='{"tool_name":"Agent","tool_input":{"subagent_type":"stride-lite:task-reviewer","prompt":"Review the task"}}'
GOAL_WRITE_PAYLOAD='{"tool_name":"Write","tool_input":{"file_path":"docs/implementation/PENDING/add-notifs/goal.md","content":"# Goal\n\n## Completion Summary\n\nAll tasks done."}}'

# Routing path 1: explorer dispatch fires before_task (blocking, success).
run_hook pre "$HOOK_PASS_DIR" "$EXPLORER_PAYLOAD"
assert_eq "explorer dispatch exits 0 when before_task succeeds" "$HOOK_RC" "0"
assert_hook_out "explorer dispatch emits before_task success JSON" '"hook":"before_task","status":"success"'

# Routing path 2: reviewer dispatch fires after_task (blocking, success).
run_hook pre "$HOOK_PASS_DIR" "$REVIEWER_PAYLOAD"
assert_eq "reviewer dispatch exits 0 when after_task succeeds" "$HOOK_RC" "0"
assert_hook_out "reviewer dispatch emits after_task success JSON" '"hook":"after_task","status":"success"'

# Routing path 3: goal.md write with Completion Summary fires after_goal.
run_hook post "$HOOK_PASS_DIR" "$GOAL_WRITE_PAYLOAD"
assert_eq "completion-summary write exits 0 when after_goal succeeds" "$HOOK_RC" "0"
assert_hook_out "completion-summary write emits after_goal success JSON" '"hook":"after_goal","status":"success"'

# Routing path 4: non-matching Agent dispatch passes through untouched.
run_hook pre "$HOOK_PASS_DIR" '{"tool_name":"Agent","tool_input":{"subagent_type":"general-purpose","prompt":"unrelated dispatch"}}'
assert_eq "non-matching subagent_type exits 0" "$HOOK_RC" "0"
assert_eq "non-matching subagent_type fires nothing (empty stdout)" "$HOOK_OUT" ""

# A task-enricher dispatch is a third Agent dispatch inside an active-marker
# window, and Step 1a asserts it fires no hook. Pin that: only the explorer and
# reviewer subagent types are triggers.
run_hook pre "$HOOK_PASS_DIR" '{"tool_name":"Agent","tool_input":{"subagent_type":"stride-lite:task-enricher","prompt":"docs/implementation/PENDING/demo/task1.md"}}'
assert_eq "task-enricher dispatch exits 0" "$HOOK_RC" "0"
assert_eq "task-enricher dispatch fires no hook (empty stdout)" "$HOOK_OUT" ""

# Edge case: payload with no subagent_type field at all.
run_hook pre "$HOOK_PASS_DIR" '{"tool_name":"Agent","tool_input":{"prompt":"no subagent field"}}'
assert_eq "missing subagent_type exits 0" "$HOOK_RC" "0"
assert_eq "missing subagent_type fires nothing (empty stdout)" "$HOOK_OUT" ""

# Edge case: goal.md write WITHOUT a Completion Summary must not fire.
run_hook post "$HOOK_PASS_DIR" '{"tool_name":"Write","tool_input":{"file_path":"docs/implementation/PENDING/add-notifs/goal.md","content":"# Goal\n\nStill in progress."}}'
assert_eq "goal.md write without Completion Summary exits 0" "$HOOK_RC" "0"
assert_eq "goal.md write without Completion Summary fires nothing (empty stdout)" "$HOOK_OUT" ""

# Path-filter check: Completion Summary in a non-goal.md file must not fire.
run_hook post "$HOOK_PASS_DIR" '{"tool_name":"Write","tool_input":{"file_path":"docs/notes.md","content":"## Completion Summary\n\nnot a goal file"}}'
assert_eq "non-goal.md path exits 0" "$HOOK_RC" "0"
assert_eq "non-goal.md path fires nothing (empty stdout)" "$HOOK_OUT" ""

# Blocking semantics: a failing before_task section exits 2 and blocks.
run_hook pre "$HOOK_FAIL_DIR" "$EXPLORER_PAYLOAD"
assert_eq "failing before_task section exits 2 (blocking)" "$HOOK_RC" "2"
assert_hook_out "failing before_task emits failure JSON" '"hook":"before_task","status":"failed"'

# Advisory semantics: a failing after_goal section still exits 0.
run_hook post "$HOOK_FAIL_DIR" "$GOAL_WRITE_PAYLOAD"
assert_eq "failing after_goal section exits 0 (advisory)" "$HOOK_RC" "0"
assert_hook_out "failing after_goal emits failure JSON" '"hook":"after_goal","status":"failed"'

# ------------------------------------------------------------------
# hook env injection (stride-lite-hook.sh)
# ------------------------------------------------------------------
#
# Asserts the derived environment block the hook exports into each
# .stride_lite.md command: the nine keys, their values for a real goal
# directory, the empty-string-when-underivable rule, project containment, and
# the inertness of a task title carrying shell metacharacters.
#
# The probe sections print each value bracketed as KEY=[value] so an empty
# value is assertable rather than merely absent. Those prints land on the
# hook's stderr (it mirrors each command's stdout there on the success path),
# which run_hook now captures into HOOK_ERR.
#
# They use ${KEY-<UNSET>} rather than $KEY so an UNSET key renders as
# KEY=[<UNSET>] and a set-but-empty one as KEY=[]. Without that the two are
# indistinguishable and the headline rule — defined-but-empty, never omitted —
# would survive a mutation that omits the export whenever the value is empty.
# `-` (not `:-`) is the unset-only default, and the hook relaxes `set -u`
# before the eval, so this is safe in the probe.

echo ""
echo "hook env injection (stride-lite-hook.sh)"

HOOK_ENV_DIR="$SANDBOX/hook-env"
ENV_GOAL_DIR="$HOOK_ENV_DIR/docs/implementation/PENDING/add-notifs"
ENV_EVIL_DIR="$HOOK_ENV_DIR/docs/implementation/PENDING/evil-goal"
ENV_OUTSIDE_DIR="$SANDBOX/outside-project/not-a-goal"
mkdir -p "$ENV_GOAL_DIR" "$ENV_EVIL_DIR" "$ENV_OUTSIDE_DIR"
write_activation_marker "$HOOK_ENV_DIR"

printf '# Add notifications\n\nGoal body.\n'   > "$ENV_GOAL_DIR/goal.md"
printf '# Wire up the socket\n\nTask body.\n'  > "$ENV_GOAL_DIR/task1.md"
printf '# Evil goal\n\nGoal body.\n'           > "$ENV_EVIL_DIR/goal.md"
printf '# Outside the project\n'               > "$ENV_OUTSIDE_DIR/task1.md"

# Hostile heading: a quoted heredoc so the metacharacters land in the file
# literally. If the value were ever spliced into the command text rather than
# exported, $(id) would run and `touch` would create a marker in the project dir.
cat > "$ENV_EVIL_DIR/task2.md" <<'TASKMD'
# Add $(id) and `whoami`; touch pwned-marker

## Description

Fixture task whose title carries shell metacharacters.
TASKMD

cat > "$HOOK_ENV_DIR/.stride_lite.md" <<'CONFIG'
## email

hook-fixture@example.com

## before_task

```bash
printf 'HOOK_NAME=[%s] TASK_FILE=[%s] TASK_NUMBER=[%s] TASK_TITLE=[%s] GOAL_DIR=[%s] GOAL_FILE=[%s] GOAL_SLUG=[%s] GOAL_TITLE=[%s] AGENT_NAME=[%s]\n' "${HOOK_NAME-<UNSET>}" "${TASK_FILE-<UNSET>}" "${TASK_NUMBER-<UNSET>}" "${TASK_TITLE-<UNSET>}" "${GOAL_DIR-<UNSET>}" "${GOAL_FILE-<UNSET>}" "${GOAL_SLUG-<UNSET>}" "${GOAL_TITLE-<UNSET>}" "${AGENT_NAME-<UNSET>}"
```

## after_task

```bash
printf 'HOOK_NAME=[%s] TASK_TITLE=[%s] GOAL_SLUG=[%s] AGENT_NAME=[%s]\n' "${HOOK_NAME-<UNSET>}" "${TASK_TITLE-<UNSET>}" "${GOAL_SLUG-<UNSET>}" "${AGENT_NAME-<UNSET>}"
```

## after_goal

```bash
printf 'HOOK_NAME=[%s] TASK_FILE=[%s] TASK_NUMBER=[%s] TASK_TITLE=[%s] GOAL_SLUG=[%s] GOAL_TITLE=[%s] AGENT_NAME=[%s]\n' "${HOOK_NAME-<UNSET>}" "${TASK_FILE-<UNSET>}" "${TASK_NUMBER-<UNSET>}" "${TASK_TITLE-<UNSET>}" "${GOAL_SLUG-<UNSET>}" "${GOAL_TITLE-<UNSET>}" "${AGENT_NAME-<UNSET>}"
```
CONFIG

ENV_TASK_PAYLOAD='{"tool_name":"Agent","tool_input":{"subagent_type":"stride-lite:task-explorer","prompt":"docs/implementation/PENDING/add-notifs/task1.md"}}'
ENV_PROSE_PAYLOAD='{"tool_name":"Agent","tool_input":{"subagent_type":"stride-lite:task-reviewer","prompt":"Review docs/implementation/PENDING/add-notifs/task1.md against its acceptance criteria."}}'
ENV_EVIL_PAYLOAD='{"tool_name":"Agent","tool_input":{"subagent_type":"stride-lite:task-explorer","prompt":"docs/implementation/PENDING/evil-goal/task2.md"}}'
ENV_TRAVERSAL_PAYLOAD='{"tool_name":"Agent","tool_input":{"subagent_type":"stride-lite:task-explorer","prompt":"../outside-project/not-a-goal/task1.md"}}'
ENV_MISSING_PAYLOAD='{"tool_name":"Agent","tool_input":{"subagent_type":"stride-lite:task-explorer","prompt":"docs/implementation/PENDING/add-notifs/task9.md"}}'
ENV_GOAL_PAYLOAD='{"tool_name":"Write","tool_input":{"file_path":"docs/implementation/PENDING/add-notifs/goal.md","content":"# Add notifications\n\n## Completion Summary\n\nAll tasks done."}}'
ENV_ABS_PAYLOAD="$(printf '{"tool_name":"Agent","tool_input":{"subagent_type":"stride-lite:task-explorer","prompt":"%s"}}' "$ENV_GOAL_DIR/task1.md")"

# --- before_task against a real goal directory: all nine keys, real values ---
run_hook pre "$HOOK_ENV_DIR" "$ENV_TASK_PAYLOAD"
assert_eq "env probe before_task exits 0" "$HOOK_RC" "0"

ENV_MISSING_KEYS=""
for _key in HOOK_NAME TASK_FILE TASK_NUMBER TASK_TITLE GOAL_DIR GOAL_FILE GOAL_SLUG GOAL_TITLE AGENT_NAME; do
  case "$HOOK_ERR" in
    *"$_key=["*) ;;
    *) ENV_MISSING_KEYS="$ENV_MISSING_KEYS $_key" ;;
  esac
done
assert_eq "all nine env keys reach the executed command" "$ENV_MISSING_KEYS" ""

assert_hook_err "before_task exports HOOK_NAME"   'HOOK_NAME=[before_task]'
assert_hook_err "before_task exports TASK_NUMBER" 'TASK_NUMBER=[1]'
assert_hook_err "before_task exports TASK_TITLE"  'TASK_TITLE=[Wire up the socket]'
assert_hook_err "before_task exports GOAL_SLUG"   'GOAL_SLUG=[add-notifs]'
assert_hook_err "before_task exports GOAL_TITLE"  'GOAL_TITLE=[Add notifications]'
assert_hook_err "before_task exports AGENT_NAME"  'AGENT_NAME=[stride-lite:task-explorer]'
# The hook canonicalizes with `pwd -P`, so compare against the canonical form:
# on macOS $SANDBOX is under /var, which is a symlink to /private/var.
ENV_GOAL_DIR_REAL="$(cd "$ENV_GOAL_DIR" && pwd -P)"
assert_hook_err "TASK_FILE is the absolute task path" "TASK_FILE=[$ENV_GOAL_DIR_REAL/task1.md]"
assert_hook_err "GOAL_DIR is the absolute goal directory" "GOAL_DIR=[$ENV_GOAL_DIR_REAL]"
assert_hook_err "GOAL_FILE is the absolute goal.md path" "GOAL_FILE=[$ENV_GOAL_DIR_REAL/goal.md]"

# --- an absolute prompt path resolves identically to a relative one ---
run_hook pre "$HOOK_ENV_DIR" "$ENV_ABS_PAYLOAD"
assert_hook_err "absolute prompt path derives TASK_TITLE" 'TASK_TITLE=[Wire up the socket]'
assert_hook_err "absolute prompt path derives GOAL_SLUG"  'GOAL_SLUG=[add-notifs]'

# --- a prose prompt that merely mentions the path still resolves ---
run_hook pre "$HOOK_ENV_DIR" "$ENV_PROSE_PAYLOAD"
assert_hook_err "after_task exports HOOK_NAME"           'HOOK_NAME=[after_task]'
assert_hook_err "prose prompt still derives TASK_TITLE"  'TASK_TITLE=[Wire up the socket]'
assert_hook_err "after_task exports the reviewer as AGENT_NAME" 'AGENT_NAME=[stride-lite:task-reviewer]'

# --- after_goal: goal keys populated, task keys and AGENT_NAME empty ---
run_hook post "$HOOK_ENV_DIR" "$ENV_GOAL_PAYLOAD"
assert_eq "env probe after_goal exits 0" "$HOOK_RC" "0"
assert_hook_err "after_goal exports HOOK_NAME"  'HOOK_NAME=[after_goal]'
assert_hook_err "after_goal exports GOAL_SLUG"  'GOAL_SLUG=[add-notifs]'
assert_hook_err "after_goal exports GOAL_TITLE" 'GOAL_TITLE=[Add notifications]'
assert_hook_err "after_goal leaves TASK_FILE empty"   'TASK_FILE=[]'
assert_hook_err "after_goal leaves TASK_NUMBER empty" 'TASK_NUMBER=[]'
assert_hook_err "after_goal leaves TASK_TITLE empty"  'TASK_TITLE=[]'
assert_hook_err "after_goal leaves AGENT_NAME empty"  'AGENT_NAME=[]'

# --- a metacharacter-bearing title is inert literal text ---
run_hook pre "$HOOK_ENV_DIR" "$ENV_EVIL_PAYLOAD"
assert_eq "metacharacter title does not fail the hook" "$HOOK_RC" "0"
assert_hook_out "metacharacter title still emits success JSON" '"hook":"before_task","status":"success"'
assert_hook_err "metacharacter title reaches the command verbatim" \
  'TASK_TITLE=[Add $(id) and `whoami`; touch pwned-marker]'
refute_hook_err "the \$(id) in a title did not execute" 'uid='
if [ ! -e "$HOOK_ENV_DIR/pwned-marker" ]; then
  ok "the '; touch' in a title did not execute"
else
  nope "the '; touch' in a title did not execute" "no pwned-marker file" "pwned-marker created"
fi

# --- a path resolving outside the project is refused, not followed ---
# This is also the undeterminable-branch half of the coverage target: every key
# except HOOK_NAME and AGENT_NAME (which are derived from the payload, not the
# file tree, and so are always available) must come back defined-but-empty.
run_hook pre "$HOOK_ENV_DIR" "$ENV_TRAVERSAL_PAYLOAD"
assert_eq "out-of-project path does not fail the hook" "$HOOK_RC" "0"
assert_hook_err "out-of-project path leaves TASK_FILE empty"   'TASK_FILE=[]'
assert_hook_err "out-of-project path leaves TASK_NUMBER empty" 'TASK_NUMBER=[]'
assert_hook_err "out-of-project path leaves TASK_TITLE empty"  'TASK_TITLE=[]'
assert_hook_err "out-of-project path leaves GOAL_DIR empty"    'GOAL_DIR=[]'
assert_hook_err "out-of-project path leaves GOAL_FILE empty"   'GOAL_FILE=[]'
assert_hook_err "out-of-project path leaves GOAL_SLUG empty"   'GOAL_SLUG=[]'
assert_hook_err "out-of-project path leaves GOAL_TITLE empty"  'GOAL_TITLE=[]'
assert_hook_err "out-of-project path still exports HOOK_NAME"  'HOOK_NAME=[before_task]'
assert_hook_err "out-of-project path still exports AGENT_NAME" 'AGENT_NAME=[stride-lite:task-explorer]'

# --- a task file with no single-# heading yields an empty title, not an error ---
printf 'No heading here.\n\n## Description\n\nBody.\n' > "$ENV_GOAL_DIR/task5.md"
run_hook pre "$HOOK_ENV_DIR" '{"tool_name":"Agent","tool_input":{"subagent_type":"stride-lite:task-explorer","prompt":"docs/implementation/PENDING/add-notifs/task5.md"}}'
assert_eq "headingless task file does not fail the hook" "$HOOK_RC" "0"
assert_hook_err "headingless task file leaves TASK_TITLE empty" 'TASK_TITLE=[]'
assert_hook_err "headingless task file still derives TASK_NUMBER" 'TASK_NUMBER=[5]'

# --- a missing file degrades to empty values without changing the exit code ---
run_hook pre "$HOOK_ENV_DIR" "$ENV_MISSING_PAYLOAD"
assert_eq "missing task file does not fail the hook" "$HOOK_RC" "0"
assert_hook_err "missing task file leaves TASK_FILE empty"  'TASK_FILE=[]'
assert_hook_err "missing task file leaves TASK_TITLE empty" 'TASK_TITLE=[]'

# --- an undeterminable prompt still exports every key, all empty ---
run_hook pre "$HOOK_ENV_DIR" "$EXPLORER_PAYLOAD"
assert_eq "undeterminable prompt does not fail the hook" "$HOOK_RC" "0"
assert_hook_err "undeterminable prompt still exports HOOK_NAME" 'HOOK_NAME=[before_task]'
assert_hook_err "undeterminable prompt leaves TASK_TITLE empty" 'TASK_TITLE=[]'
assert_hook_err "undeterminable prompt leaves GOAL_SLUG empty"  'GOAL_SLUG=[]'

# ------------------------------------------------------------------
# activation-marker gate (stride-lite-hook.sh)
# ------------------------------------------------------------------
#
# The hook runs a section only while the workflow skill is driving a goal,
# which it signals with .stride-lite/.orchestrator_active. A missing, stale,
# malformed or future-dated marker means "run nothing, exit 0" — it must never
# block, because blocking would break the documented standalone dispatch of
# stride-lite:task-explorer.
#
# Every fixture project above carries a fresh marker (written by
# write_activation_marker), which is why those stages still exercise the real
# sections. This stage removes and forges markers to pin the gate itself.

echo ""
echo "activation-marker gate (stride-lite-hook.sh)"

MARKER_DIR="$SANDBOX/marker-gate"
mkdir -p "$MARKER_DIR"
cat > "$MARKER_DIR/.stride_lite.md" <<'CONFIG'
## email

hook-fixture@example.com

## before_task

```bash
true
```

## after_task

```bash
true
```

## after_goal

```bash
true
```
CONFIG

# run_hook_direct <phase> <project-dir> <payload> — as run_hook, but with the
# STRIDE_LITE_ALLOW_DIRECT override set.
run_hook_direct() {
  local phase="$1" dir="$2" payload="$3"
  local errfile
  errfile="$(mktemp)"
  HOOK_OUT="$(printf '%s' "$payload" \
    | STRIDE_LITE_ALLOW_DIRECT=1 CLAUDE_PROJECT_DIR="$dir" bash "$HOOK_SH" "$phase" 2>"$errfile")"
  HOOK_RC=$?
  HOOK_ERR="$(cat "$errfile" 2>/dev/null)"
  rm -f "$errfile"
}

# --- fresh marker: the section runs exactly as it does without the gate ---
write_activation_marker "$MARKER_DIR"
run_hook pre "$MARKER_DIR" "$EXPLORER_PAYLOAD"
assert_eq "fresh marker: explorer dispatch exits 0" "$HOOK_RC" "0"
assert_hook_out "fresh marker: before_task section runs" '"hook":"before_task","status":"success"'
run_hook post "$MARKER_DIR" "$GOAL_WRITE_PAYLOAD"
assert_eq "fresh marker: goal write exits 0" "$HOOK_RC" "0"
assert_hook_out "fresh marker: after_goal section runs" '"hook":"after_goal","status":"success"'

# --- no marker: blocking AND advisory triggers both run nothing, exit 0 ---
rm -rf "$MARKER_DIR/.stride-lite"
run_hook pre "$MARKER_DIR" "$EXPLORER_PAYLOAD"
assert_eq "no marker: blocking trigger exits 0 (never blocks)" "$HOOK_RC" "0"
assert_eq "no marker: blocking trigger runs nothing (empty stdout)" "$HOOK_OUT" ""
run_hook pre "$MARKER_DIR" "$REVIEWER_PAYLOAD"
assert_eq "no marker: after_task trigger exits 0" "$HOOK_RC" "0"
assert_eq "no marker: after_task trigger runs nothing (empty stdout)" "$HOOK_OUT" ""
run_hook post "$MARKER_DIR" "$GOAL_WRITE_PAYLOAD"
assert_eq "no marker: advisory trigger exits 0" "$HOOK_RC" "0"
assert_eq "no marker: advisory trigger runs nothing (empty stdout)" "$HOOK_OUT" ""

# --- stale marker (5h > the 4h window): same as absent ---
write_activation_marker "$MARKER_DIR" 18000
run_hook pre "$MARKER_DIR" "$EXPLORER_PAYLOAD"
assert_eq "stale marker: blocking trigger exits 0" "$HOOK_RC" "0"
assert_eq "stale marker: blocking trigger runs nothing (empty stdout)" "$HOOK_OUT" ""
run_hook post "$MARKER_DIR" "$GOAL_WRITE_PAYLOAD"
assert_eq "stale marker: advisory trigger exits 0" "$HOOK_RC" "0"
assert_eq "stale marker: advisory trigger runs nothing (empty stdout)" "$HOOK_OUT" ""

# --- freshness-window boundary ---
write_activation_marker "$MARKER_DIR" 14000
run_hook pre "$MARKER_DIR" "$EXPLORER_PAYLOAD"
assert_hook_out "marker just inside the 4h window still runs" '"hook":"before_task","status":"success"'
write_activation_marker "$MARKER_DIR" 14500
run_hook pre "$MARKER_DIR" "$EXPLORER_PAYLOAD"
assert_eq "marker just outside the 4h window runs nothing" "$HOOK_OUT" ""

# --- malformed marker: treated as absent, never an error ---
mkdir -p "$MARKER_DIR/.stride-lite"
printf 'not json at all\n' > "$MARKER_DIR/.stride-lite/.orchestrator_active"
run_hook pre "$MARKER_DIR" "$EXPLORER_PAYLOAD"
assert_eq "malformed marker exits 0" "$HOOK_RC" "0"
assert_eq "malformed marker runs nothing (empty stdout)" "$HOOK_OUT" ""

# --- future-dated marker (clock skew or forgery): treated as absent ---
write_activation_marker "$MARKER_DIR" -18000
run_hook pre "$MARKER_DIR" "$EXPLORER_PAYLOAD"
assert_eq "future-dated marker exits 0" "$HOOK_RC" "0"
assert_eq "future-dated marker runs nothing (empty stdout)" "$HOOK_OUT" ""

# --- STRIDE_LITE_ALLOW_DIRECT=1 bypasses the gate entirely ---
rm -rf "$MARKER_DIR/.stride-lite"
run_hook_direct pre "$MARKER_DIR" "$EXPLORER_PAYLOAD"
assert_hook_out "ALLOW_DIRECT runs the section with no marker at all" '"hook":"before_task","status":"success"'
write_activation_marker "$MARKER_DIR" 18000
run_hook_direct pre "$MARKER_DIR" "$EXPLORER_PAYLOAD"
assert_hook_out "ALLOW_DIRECT runs the section despite a stale marker" '"hook":"before_task","status":"success"'
run_hook_direct post "$MARKER_DIR" "$GOAL_WRITE_PAYLOAD"
assert_hook_out "ALLOW_DIRECT applies to the advisory trigger too" '"hook":"after_goal","status":"success"'

# --- the gate declines to ACT, it does not decline to proceed ---
# $MARKER_FAIL_DIR's before_task is `false`. With a marker the hook exits 2 and
# blocks the dispatch; with no marker it must exit 0 and stay silent. This is
# the assertion that distinguishes "the gate suppressed the section" from "the
# section ran and its failure was swallowed" — the all-`true` fixture above
# cannot tell those apart. It pins the headline rule: a missing marker must
# never block the documented standalone dispatch.
MARKER_FAIL_DIR="$SANDBOX/marker-gate-fail"
mkdir -p "$MARKER_FAIL_DIR"
cp "$HOOK_FAIL_DIR/.stride_lite.md" "$MARKER_FAIL_DIR/.stride_lite.md"

write_activation_marker "$MARKER_FAIL_DIR"
run_hook pre "$MARKER_FAIL_DIR" "$EXPLORER_PAYLOAD"
assert_eq "control: with a marker, a failing before_task still exits 2" "$HOOK_RC" "2"
assert_hook_out "control: with a marker, the failure JSON is emitted" '"hook":"before_task","status":"failed"'

rm -rf "$MARKER_FAIL_DIR/.stride-lite"
run_hook pre "$MARKER_FAIL_DIR" "$EXPLORER_PAYLOAD"
assert_eq "no marker: a FAILING before_task exits 0, never 2" "$HOOK_RC" "0"
assert_eq "no marker: a failing before_task emits no failure JSON" "$HOOK_OUT" ""

# --- degenerate marker contents are all treated as absent ---
mkdir -p "$MARKER_DIR/.stride-lite"
: > "$MARKER_DIR/.stride-lite/.orchestrator_active"
run_hook pre "$MARKER_DIR" "$EXPLORER_PAYLOAD"
assert_eq "empty marker file runs nothing" "$HOOK_OUT" ""
printf '{"session_id":"x","pid":1}\n' > "$MARKER_DIR/.stride-lite/.orchestrator_active"
run_hook pre "$MARKER_DIR" "$EXPLORER_PAYLOAD"
assert_eq "marker with no started_at runs nothing" "$HOOK_OUT" ""

# --- the override is =1, not merely "set" ---
rm -rf "$MARKER_DIR/.stride-lite"
HOOK_OUT="$(printf '%s' "$EXPLORER_PAYLOAD" \
  | STRIDE_LITE_ALLOW_DIRECT=0 CLAUDE_PROJECT_DIR="$MARKER_DIR" bash "$HOOK_SH" pre 2>/dev/null)"
assert_eq "STRIDE_LITE_ALLOW_DIRECT=0 does not bypass the gate" "$HOOK_OUT" ""

# --- a non-trigger payload is still inert, marker or not ---
write_activation_marker "$MARKER_DIR"
run_hook pre "$MARKER_DIR" '{"tool_name":"Agent","tool_input":{"subagent_type":"general-purpose","prompt":"unrelated"}}'
assert_eq "fresh marker does not make a non-trigger payload fire" "$HOOK_OUT" ""

# --- cross-platform parity, part 1: the .sh and .ps1 export the same key set ---
# Extracted from the real export call sites in both scripts, so the assertion
# cannot pass while an implementation drifts. This pins the KEY SET only —
# part 2 below covers the rules.
EXPECTED_ENV_KEYS="$(printf '%s\n' AGENT_NAME GOAL_DIR GOAL_FILE GOAL_SLUG GOAL_TITLE HOOK_NAME TASK_FILE TASK_NUMBER TASK_TITLE)"
SH_ENV_KEYS="$(grep -oE '_export_env_kv +[A-Z_]+' "$HOOK_SH" | awk '{print $2}' | sort -u)"
PS_ENV_KEYS="$(grep -oE "Set-StrideLiteEnvKv +-Key +'[A-Z_]+'" "$HOOK_PS1" \
  | grep -oE "'[A-Z_]+'" | tr -d "'" | sort -u)"
assert_eq "hook env key set is identical in .sh and .ps1" "$PS_ENV_KEYS" "$SH_ENV_KEYS"
assert_eq "hook env key set is the documented nine" "$SH_ENV_KEYS" "$EXPECTED_ENV_KEYS"

# The .ps1 gate takes its project root as a PARAMETER, so the call site carries
# the binding and the parity harness (which passes its own -ProjectRoot) cannot
# see it. Drop the argument in the shipped script and $ProjectRoot defaults to
# '' , trips the empty-root guard, and silently disarms every hook on Windows —
# with the suite still green. Pin the real call site the same way the key-set
# assertion above pins the real export call sites.
if grep -qE 'Test-StrideLiteMarkerFresh +-ProjectRoot +\$ProjectDir' "$HOOK_PS1"; then
  ok ".ps1 gate call site binds -ProjectRoot to \$ProjectDir"
else
  nope ".ps1 gate call site binds -ProjectRoot to \$ProjectDir" \
    "a 'Test-StrideLiteMarkerFresh -ProjectRoot \$ProjectDir' call site" \
    "$(grep -n 'Test-StrideLiteMarkerFresh' "$HOOK_PS1" | tr '\n' ' ')"
fi

# --- cross-platform parity, part 2: the .ps1 obeys the same RULES ---
#
# The .ps1 cannot be driven end-to-end from here: it reads stdin via `@($input)`,
# which is empty for an OS-level pipe, so a piped payload never reaches it. That
# is a pre-existing defect (it reproduces identically on `git show HEAD:` of the
# script) and is out of scope for the env-injection work — but it means the
# routing stage above has no PowerShell counterpart.
#
# What IS reachable is the part this task added: the derivation functions. The
# harness below AST-extracts them from the real script — no copy of the logic
# lives here — and drives them through the same fixtures the .sh stage uses,
# asserting the same derived values, the same empty-on-underivable rule, the
# same project containment, and the same metacharacter inertness.
#
# Gated on PowerShell being present. When it is absent the suite records an
# explicit skip line rather than passing silently.

PS_PARITY_DIR="$SANDBOX/ps-parity"
mkdir -p "$PS_PARITY_DIR"
cat > "$PS_PARITY_DIR/harness.ps1" <<'PSHARNESS'
param([string]$ScriptPath, [string]$ProjDir, [string]$MarkerProbeDir)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The path-separator, comparison-mode and project-root setup is RE-DECLARED
# here rather than extracted — $ProjectAbs is the containment baseline and
# $PathComparison the Windows case-insensitivity rule, so these carry rules
# too and a change to them in the .ps1 would not reach this harness. The
# derivation functions below ARE extracted from the script itself.
$ProjectDir = $ProjDir
$PathSep = [System.IO.Path]::DirectorySeparatorChar
$PathComparison = if ($PathSep -eq '\') {
    [System.StringComparison]::OrdinalIgnoreCase
} else {
    [System.StringComparison]::Ordinal
}
$ProjectAbs = (Resolve-Path -LiteralPath $ProjectDir).ProviderPath.TrimEnd($PathSep)

$errs = $null; $toks = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$toks, [ref]$errs)
if ($errs.Count -gt 0) { [Console]::Error.WriteLine('parse errors'); exit 1 }
foreach ($f in $ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true)) {
    if ($f.Name -like '*StrideLite*' -and $f.Name -ne 'Invoke-StrideLiteSection') {
        . ([scriptblock]::Create($f.Extent.Text))
    }
}

$keys = 'HOOK_NAME','TASK_FILE','TASK_NUMBER','TASK_TITLE','GOAL_DIR','GOAL_FILE','GOAL_SLUG','GOAL_TITLE','AGENT_NAME'
$scenarios = @(
    @{ label = 'derived';   hook = 'before_task'; src = 'docs/implementation/PENDING/add-notifs/task1.md'; agent = 'stride-lite:task-explorer' },
    @{ label = 'traversal'; hook = 'before_task'; src = '../outside-project/not-a-goal/task1.md';         agent = 'stride-lite:task-explorer' },
    @{ label = 'missing';   hook = 'before_task'; src = 'docs/implementation/PENDING/add-notifs/task9.md'; agent = 'stride-lite:task-explorer' },
    @{ label = 'evil';      hook = 'before_task'; src = 'docs/implementation/PENDING/evil-goal/task2.md';  agent = 'stride-lite:task-explorer' },
    @{ label = 'goal';      hook = 'after_goal';  src = 'docs/implementation/PENDING/add-notifs/goal.md';  agent = '' }
)

foreach ($s in $scenarios) {
    # Seed every key with a sentinel rather than clearing it, so a key the
    # function fails to set reads back as <UNSET> while one it sets to the
    # empty string reads back as empty. That is the distinction the headline
    # rule is about — defined-but-empty, never omitted — and without it a
    # mutation that skips the export whenever the value is empty would slip
    # past the empty-branch assertions below.
    #
    # A sentinel and not $null: on .NET, SetEnvironmentVariable(name, $null)
    # followed by GetEnvironmentVariable returns the EMPTY STRING, not $null,
    # so a null-based check cannot tell the two apart (verified on pwsh 7).
    foreach ($k in $keys) { [System.Environment]::SetEnvironmentVariable($k, '<UNSET>', 'Process') }
    Set-StrideLiteHookEnv -Hook $s.hook -Source $s.src -Agent $s.agent
    $parts = foreach ($k in $keys) {
        "$k=[" + [System.Environment]::GetEnvironmentVariable($k, 'Process') + ']'
    }
    [Console]::Out.WriteLine($s.label + ' ' + ($parts -join ' '))
}

# --- Activation-marker gate parity ---
# Same states the bash gate stage pins, driven through the .ps1's own
# Test-StrideLiteMarkerFresh (extracted above, not reimplemented here).
# NOTE: deliberately no $MarkerMaxAgeSeconds here. The function takes its window
# as a parameter with its own default, so the 14000/14500 boundary probes below
# exercise the value that actually ships. Re-declaring it here would shadow it.
$markerDir = Join-Path $MarkerProbeDir '.stride-lite'
$markerFile = Join-Path $markerDir '.orchestrator_active'
New-Item -ItemType Directory -Force -Path $markerDir | Out-Null

function Write-ProbeMarker {
    param([int]$SecondsAgo)
    $stamp = [datetime]::UtcNow.AddSeconds(-$SecondsAgo).ToString('yyyy-MM-ddTHH:mm:ssZ')
    Set-Content -LiteralPath $markerFile -Value ('{"session_id":"smoke","started_at":"' + $stamp + '","pid":1}') -NoNewline
}

Remove-Item -LiteralPath $markerFile -Force -ErrorAction SilentlyContinue
[Console]::Out.WriteLine('marker-missing ' + (Test-StrideLiteMarkerFresh -ProjectRoot $MarkerProbeDir))
Write-ProbeMarker -SecondsAgo 0
[Console]::Out.WriteLine('marker-fresh ' + (Test-StrideLiteMarkerFresh -ProjectRoot $MarkerProbeDir))
Write-ProbeMarker -SecondsAgo 18000
[Console]::Out.WriteLine('marker-stale ' + (Test-StrideLiteMarkerFresh -ProjectRoot $MarkerProbeDir))
Write-ProbeMarker -SecondsAgo 14000
[Console]::Out.WriteLine('marker-inside-window ' + (Test-StrideLiteMarkerFresh -ProjectRoot $MarkerProbeDir))
Write-ProbeMarker -SecondsAgo 14500
[Console]::Out.WriteLine('marker-outside-window ' + (Test-StrideLiteMarkerFresh -ProjectRoot $MarkerProbeDir))
Write-ProbeMarker -SecondsAgo -18000
[Console]::Out.WriteLine('marker-future ' + (Test-StrideLiteMarkerFresh -ProjectRoot $MarkerProbeDir))
Set-Content -LiteralPath $markerFile -Value 'not json at all'
[Console]::Out.WriteLine('marker-malformed ' + (Test-StrideLiteMarkerFresh -ProjectRoot $MarkerProbeDir))
$env:STRIDE_LITE_ALLOW_DIRECT = '1'
Remove-Item -LiteralPath $markerFile -Force -ErrorAction SilentlyContinue
[Console]::Out.WriteLine('marker-override ' + (Test-StrideLiteMarkerFresh -ProjectRoot $MarkerProbeDir))
$env:STRIDE_LITE_ALLOW_DIRECT = ''
PSHARNESS

PS_BIN=""
if command -v pwsh > /dev/null 2>&1; then
  PS_BIN="pwsh"
elif command -v powershell > /dev/null 2>&1; then
  PS_BIN="powershell"
fi

if [ -z "$PS_BIN" ]; then
  echo "  SKIP  .ps1 rule parity: no pwsh/powershell on PATH (key-set parity above still ran)"
  echo "  SKIP  .ps1 end-to-end via hooks/stride-lite-hook.ps1: blocked by the pre-existing"
  echo "        @(\$input) stdin defect, which predates this change"
else
  PS_MARKER_PROBE_DIR="$PS_PARITY_DIR/marker-probe"
  mkdir -p "$PS_MARKER_PROBE_DIR"
  PS_PARITY_OUT="$("$PS_BIN" -NoProfile -File "$PS_PARITY_DIR/harness.ps1" \
    -ScriptPath "$HOOK_PS1" -ProjDir "$HOOK_ENV_DIR" \
    -MarkerProbeDir "$PS_MARKER_PROBE_DIR" 2>/dev/null)"

  # assert_ps_parity <label> <scenario-prefix> <marker>
  assert_ps_parity() {
    local label="$1" prefix="$2" marker="$3" line
    line="$(printf '%s\n' "$PS_PARITY_OUT" | grep "^$prefix " 2>/dev/null)"
    case "$line" in
      *"$marker"*) ok "$label" ;;
      *) nope "$label" "$marker in the .ps1 '$prefix' scenario" "$line" ;;
    esac
  }

  assert_ps_parity ".ps1 derives TASK_NUMBER like the .sh"  derived   'TASK_NUMBER=[1]'
  assert_ps_parity ".ps1 derives TASK_TITLE like the .sh"   derived   'TASK_TITLE=[Wire up the socket]'
  assert_ps_parity ".ps1 derives GOAL_SLUG like the .sh"    derived   'GOAL_SLUG=[add-notifs]'
  assert_ps_parity ".ps1 derives GOAL_TITLE like the .sh"   derived   'GOAL_TITLE=[Add notifications]'
  assert_ps_parity ".ps1 derives AGENT_NAME like the .sh"   derived   'AGENT_NAME=[stride-lite:task-explorer]'
  assert_ps_parity ".ps1 refuses an out-of-project path"    traversal 'TASK_FILE=[]'
  assert_ps_parity ".ps1 empties GOAL_SLUG out of project"  traversal 'GOAL_SLUG=[]'
  assert_ps_parity ".ps1 still exports HOOK_NAME when underivable" traversal 'HOOK_NAME=[before_task]'
  assert_ps_parity ".ps1 empties a missing task file"       missing   'TASK_TITLE=[]'
  assert_ps_parity ".ps1 keeps a metacharacter title literal" evil \
    'TASK_TITLE=[Add $(id) and `whoami`; touch pwned-marker]'
  assert_ps_parity ".ps1 after_goal derives GOAL_SLUG"      goal      'GOAL_SLUG=[add-notifs]'
  assert_ps_parity ".ps1 after_goal empties TASK_FILE"      goal      'TASK_FILE=[]'
  assert_ps_parity ".ps1 after_goal empties AGENT_NAME"     goal      'AGENT_NAME=[]'

  # Activation-marker gate: the same states the bash gate stage pins above.
  assert_ps_parity ".ps1 gate: missing marker is not fresh"        marker-missing        'False'
  assert_ps_parity ".ps1 gate: fresh marker is fresh"              marker-fresh          'True'
  assert_ps_parity ".ps1 gate: stale marker is not fresh"          marker-stale          'False'
  assert_ps_parity ".ps1 gate: just inside the 4h window is fresh" marker-inside-window  'True'
  assert_ps_parity ".ps1 gate: just outside the 4h window is not"  marker-outside-window 'False'
  assert_ps_parity ".ps1 gate: future-dated marker is not fresh"   marker-future         'False'
  assert_ps_parity ".ps1 gate: malformed marker is not fresh"      marker-malformed      'False'
  assert_ps_parity ".ps1 gate: ALLOW_DIRECT bypasses entirely"     marker-override       'True'

  echo "  SKIP  .ps1 end-to-end via hooks/stride-lite-hook.ps1: blocked by the pre-existing"
  echo "        @(\$input) stdin defect, which predates this change"
fi

# --- the workflow SKILL.md documents every key it exports ---
ENV_UNDOCUMENTED=""
for _key in $EXPECTED_ENV_KEYS; do
  if ! grep -q "$_key" "$REPO_ROOT/skills/stride-lite-workflow/SKILL.md"; then
    ENV_UNDOCUMENTED="$ENV_UNDOCUMENTED $_key"
  fi
done
assert_eq "every exported key is documented in the workflow SKILL.md" "$ENV_UNDOCUMENTED" ""

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------

echo ""
echo "------------------------------------------------------------------"
echo "$PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

exit 0
