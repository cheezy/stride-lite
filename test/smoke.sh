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

# Fixed-string containment against a FILE. Takes a path, not a captured string:
# these haystacks are whole document sections, and passing one through "$(cat)"
# makes every assertion's outcome depend on shell word-splitting of the
# document's own punctuation.
assert_has() {
  local label="$1" file="$2" needle="$3"
  if [ ! -s "$file" ]; then
    nope "$label" "a non-empty haystack at $file" "file missing or empty"
  elif grep -qF -- "$needle" "$file"; then
    ok "$label"
  else
    nope "$label" "contains: $needle" "not found in $file"
  fi
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
# Slice to Step 3's own section. This was a WHOLE-FILE grep, which meant the
# tokens were satisfied by any prose anywhere -- deleting the entire decision
# matrix left the suite green. The Quick reference card added in W2017 says
# "Key files" too, so the whole-file form could only get weaker from here.
MATRIX_SLICE="$SANDBOX/matrix-slice.txt"
awk '/^### Step 3 /{f=1;next} f && /^### Step /{exit} f' "$MATRIX_SKILL" > "$MATRIX_SLICE"
if [ -s "$MATRIX_SLICE" ]; then
  ok "the decision-matrix slice extracted non-empty"
else
  nope "the decision-matrix slice extracted non-empty" "content" "(empty)"
fi
MATRIX_MISSING=""
for _row in 'skip-all' 'explore-review' 'full'; do
  grep -q "\`$_row\`" "$MATRIX_SLICE" || MATRIX_MISSING="$MATRIX_MISSING $_row"
done
for _sig in 'Complexity' 'Key files'; do
  grep -q "$_sig" "$MATRIX_SLICE" || MATRIX_MISSING="$MATRIX_MISSING $_sig"
done
# The closed skip-reason vocabulary lives in its own section, not Step 3's, so
# it needs its own slice -- one whole-file grep covering both was how the
# original assertion survived deleting the matrix outright.
SKIPVOCAB_SLICE="$SANDBOX/skip-vocab-slice.txt"
awk '/^#### Recording a skipped step/{f=1;next} f && /^#### /{exit} f' "$MATRIX_SKILL" > "$SKIPVOCAB_SLICE"
if [ -s "$SKIPVOCAB_SLICE" ]; then
  ok "the skip-vocabulary slice extracted non-empty"
else
  nope "the skip-vocabulary slice extracted non-empty" "content" "(empty)"
fi
for _sig in 'small_task_0_1_key_files' 'small_task_2_plus_key_files'; do
  grep -q "$_sig" "$SKIPVOCAB_SLICE" || MATRIX_MISSING="$MATRIX_MISSING $_sig"
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
# workflow telemetry vocabulary
# ------------------------------------------------------------------
#
# The telemetry names every step the loop performs, so the vocabulary and the
# loop must not drift: adding a step without a telemetry name would let it be
# skipped invisibly, which is the one thing the record exists to prevent.
#
# Every grep here is SLICE-ANCHORED. Names like "explorer" and "reviewer" are
# ordinary words that appear throughout this file, so a whole-file grep would
# pass whether or not the vocabulary table contains them.

echo ""
echo "workflow telemetry vocabulary"

TELEM_SKILL="$REPO_ROOT/skills/stride-lite-workflow/SKILL.md"

# The vocabulary table: rows between its heading and the next heading.
TELEM_TABLE="$(awk '/^##### Step name vocabulary$/ { f=1; next } f && /^#####? / { exit } f' "$TELEM_SKILL")"
TELEM_NAMES="$(printf '%s\n' "$TELEM_TABLE" | awk -F'|' '/^\| `/ { gsub(/[` ]/,"",$2); print $2 }')"
TELEM_STEPS="$(printf '%s\n' "$TELEM_TABLE" | awk -F'|' '/^\| `/ { gsub(/^ +| +$/,"",$4); print $4 }')"

if [ -n "$TELEM_NAMES" ] && [ -n "$TELEM_STEPS" ]; then
  ok "the telemetry vocabulary table extracted non-empty"
else
  nope "the telemetry vocabulary table extracted non-empty" "names and steps" \
    "names=[$TELEM_NAMES] steps=[$TELEM_STEPS]"
fi

assert_eq "the telemetry vocabulary names ten steps" \
  "$(printf '%s\n' "$TELEM_NAMES" | grep -c .)" "10"

# stride's names must NOT appear — they describe hooks stride-lite cannot run.
TELEM_FOREIGN=""
for _n in after_doing before_review; do
  case "$TELEM_NAMES" in
    *"$_n"*) TELEM_FOREIGN="$TELEM_FOREIGN [$_n]" ;;
  esac
done
assert_eq "the vocabulary borrows no stride-only step names" "$TELEM_FOREIGN" ""

# --- Vocabulary/loop sync: every step the table cites must be a real heading ---
# This is the assertion that fails if a step is added to the loop without a
# telemetry name, or a name is documented for a step that does not exist.
TELEM_BAD_STEP=""
while IFS= read -r _step; do
  [ -n "$_step" ] || continue
  grep -q "^### ${_step} —" "$TELEM_SKILL" || TELEM_BAD_STEP="$TELEM_BAD_STEP [$_step]"
done <<EOF_STEPS
$TELEM_STEPS
EOF_STEPS
assert_eq "every telemetry entry cites a real loop step" "$TELEM_BAD_STEP" ""

# The converse: every dispatch-or-hook step in the loop must have a telemetry
# name. Steps 0, 1, 7 and 8 are orchestration the agent does itself, so they are
# deliberately unrecorded — they are the only exemptions.
TELEM_UNRECORDED=""
while IFS= read -r _heading; do
  [ -n "$_heading" ] || continue
  case "$_heading" in
    'Step 0'|'Step 1'|'Step 7'|'Step 8') continue ;;
  esac
  # Line-anchored, not substring: "Step 3a" contains "Step 3", so a substring
  # test lets a longer citation silently satisfy a shorter step's requirement.
  printf '%s\n' "$TELEM_STEPS" | grep -qx "$_heading" \
    || TELEM_UNRECORDED="$TELEM_UNRECORDED [$_heading]"
done <<EOF_HEADINGS
$(grep -oE '^### Step [0-9]+[a-z]?' "$TELEM_SKILL" | sed 's/^### //')
EOF_HEADINGS
assert_eq "every dispatch-or-hook loop step has a telemetry name" "$TELEM_UNRECORDED" ""

# --- The walkthrough shows real telemetry for every iteration ---
WALKTHROUGH="$(awk '/^## Concrete walkthrough$/ { f=1; next } f && /^## / { exit } f' "$TELEM_SKILL")"
WALK_BLOCKS="$(printf '%s\n' "$WALKTHROUGH" | grep -c '"name": "enricher"')"
assert_eq "the walkthrough shows a telemetry block for each of its three iterations" \
  "$WALK_BLOCKS" "3"

# The contract says the table and the JSON are BOTH mandatory. The walkthrough is
# the imitation target, so an example showing JSON alone teaches the shape the
# contract forbids — assert every block is preceded by its table.
# PAIR them, do not count them: three tables anywhere in the slice satisfies a
# count even if all three sit above iteration 1 and the others show bare JSON.
# Walk the slice and require a header row between each block and the previous.
WALK_UNPAIRED="$(printf '%s\n' "$WALKTHROUGH" | awk '
  /^ *\| Step \| Dispatched \| Duration \| Reason \|/ { seen_table=1; next }
  /"name": "enricher"/ { if (!seen_table) unpaired++; seen_table=0 }
  END { print unpaired+0 }')"
assert_eq "each walkthrough telemetry block is preceded by its own table" "$WALK_UNPAIRED" "0"

# Every block must list all seven names — a block missing one is the omission
# the whole record exists to prevent.
WALK_INCOMPLETE=""
while IFS= read -r _n; do
  [ -n "$_n" ] || continue
  _count="$(printf '%s\n' "$WALKTHROUGH" | grep -c "\"name\": \"$_n\"")"
  [ "$_count" -eq 3 ] || WALK_INCOMPLETE="$WALK_INCOMPLETE [$_n=$_count]"
done <<EOF_NAMES
$TELEM_NAMES
EOF_NAMES
assert_eq "every telemetry name appears in all three walkthrough blocks" "$WALK_INCOMPLETE" ""

# --- Structural sanity of every telemetry entry in the file ---
# The suite has no JSON parser and deliberately stays pure bash, so check the
# invariants that actually matter: a skipped entry carries a reason, and a
# reason never merely restates the skip.
TELEM_ENTRIES="$(grep -o '{"name": "[a-z_]*",[^}]*}' "$TELEM_SKILL")"
assert_eq "every telemetry entry names a step and a dispatched flag" \
  "$(printf '%s\n' "$TELEM_ENTRIES" | grep -cv '"dispatched": \(true\|false\)')" "0"

TELEM_SKIP_NO_REASON="$(printf '%s\n' "$TELEM_ENTRIES" | grep '"dispatched": false' | grep -cv '"reason":')"
assert_eq "every skipped telemetry entry carries a reason" "$TELEM_SKIP_NO_REASON" "0"

# A reason that just says "skipped" restates the flag beside it and audits nothing.
# Match on SHAPE, not character distance. An offset window is green on margin
# rather than on meaning: it rejects a legitimate short reason and accepts a
# restatement padded past the cutoff. "<step> was skipped" is the shape that
# says nothing; a reason that merely mentions a skipped dispatch is fine.
# A restatement ENDS on "skipped" — that is its whole payload. Every real reason
# ends on the condition instead ("...already populated", "...1 key file",
# "...skipped by the matrix"). Anchoring on the tail catches both the skill's
# named bad example and a restatement padded out to any length, without the
# false positives an offset window produces on a legitimately short reason.
TELEM_LAZY_REASON="$(printf '%s\n' "$TELEM_ENTRIES" | grep -o '"reason": "[^"]*"' \
  | grep -ciE '(was |is |been )?skipped\.?"$' || true)"
assert_eq "no telemetry reason merely restates the skip" "${TELEM_LAZY_REASON:-0}" "0"

# --- Every telemetry JSON block is structurally sound ---------------------
# The suite deliberately carries no JSON parser (pure bash + POSIX), so check
# the invariants that actually matter per block rather than pretending to parse:
# each block opens and closes its array, and each carries exactly seven entries.
# Fences may be indented — the walkthrough's blocks sit inside list items, and a
# line-anchored fence pattern would silently find only the unindented one.
TELEM_BLOCK_COUNT=0
TELEM_BAD_BLOCK=""
_telem_blocks_file="$SANDBOX/telemetry-blocks.txt"
# Only blocks whose entries are telemetry entries — an unrelated JSON example
# added later must not fail with a message about telemetry.
awk '/^[ \t]*```json$/ { inb=1; n=0; next }
     inb && /^[ \t]*```$/ { if (n > 0) print n; inb=0; next }
     inb && /\{"name": "/ { n++ }' "$TELEM_SKILL" > "$_telem_blocks_file"

while IFS= read -r _n; do
  [ -n "$_n" ] || continue
  TELEM_BLOCK_COUNT=$(( TELEM_BLOCK_COUNT + 1 ))
  [ "$_n" -eq 10 ] || TELEM_BAD_BLOCK="$TELEM_BAD_BLOCK [block $TELEM_BLOCK_COUNT has $_n entries]"
done < "$_telem_blocks_file"

assert_eq "the skill carries four telemetry JSON blocks (contract + three iterations)" \
  "$TELEM_BLOCK_COUNT" "4"
assert_eq "every telemetry JSON block carries exactly ten entries" "$TELEM_BAD_BLOCK" ""

# Bracket balance per block — a truncated block is the failure a count alone misses.
TELEM_UNBALANCED="$(awk '/^[ \t]*```json$/ { inb=1; o=0; c=0; t=0; next }
     inb && /^[ \t]*```$/ { if (t > 0 && o != c) bad++; inb=0; next }
     inb { if ($0 ~ /\{"name": "/) t++
           n=gsub(/\{/,"{"); o+=n; n=gsub(/\}/,"}"); c+=n }
     END { print bad+0 }' "$TELEM_SKILL")"
assert_eq "every telemetry JSON block has balanced braces" "$TELEM_UNBALANCED" "0"

# A dispatched entry must never carry a reason — reasons explain absence.
TELEM_DISPATCHED_REASON="$(printf '%s\n' "$TELEM_ENTRIES" | grep '"dispatched": true' | grep -c '"reason":' || true)"
assert_eq "no dispatched telemetry entry carries a skip reason" "${TELEM_DISPATCHED_REASON:-0}" "0"

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
echo "gated exploratory-testing steps (6a / 6b)"

# ---------------------------------------------------------------------------
# Steps 6a and 6b dispatch a SEPARATE plugin against a RUNNING application.
# Every assertion here is slice-anchored to one step's own section: the two
# steps share vocabulary ("gated", "skip", "budget"), so a whole-file grep for
# any of it passes off the other step's text and proves nothing about the one
# named in the assertion.
# ---------------------------------------------------------------------------
XT_SKILL="$REPO_ROOT/skills/stride-lite-workflow/SKILL.md"

# Slice each step: from its own heading to the next ### heading.
_slice_step() {
  awk -v want="$1" '
    /^### / { inside = (index($0, want) == 1) }
    inside { print }
  ' "$XT_SKILL"
}
XT_6A="$SANDBOX/step-6a.md"
XT_6B="$SANDBOX/step-6b.md"
XT_6C="$SANDBOX/step-6c.md"
_slice_step "### Step 6a" > "$XT_6A"
_slice_step "### Step 6b" > "$XT_6B"
_slice_step "### Step 6c" > "$XT_6C"

# A guard on the guards: an awk change that silently emptied either slice would
# turn every grep -qv below into a free pass. Assert non-empty FIRST, and assert
# the slices are disjoint -- 6a's text must not bleed into 6b's.
if [ -s "$XT_6A" ] && [ -s "$XT_6B" ] && [ -s "$XT_6C" ]; then
  ok "all three gated-step slices extracted non-empty"
else
  nope "all three gated-step slices extracted non-empty" "content" "6a/6b/6c empty"
fi
assert_eq "the 6a slice does not swallow Step 6b" \
  "$(grep -c '^### Step 6b' "$XT_6A")" "0"
assert_eq "the 6b slice does not swallow Step 6c" \
  "$(grep -c '^### Step 6c' "$XT_6B")" "0"
assert_eq "the 6c slice does not swallow Step 7" \
  "$(grep -c '^### Step 7' "$XT_6C")" "0"

# --- Both steps are gated, and the gate is a conjunction, not a preference ---
for _step in 6a 6b 6c; do
  eval "_f=\$XT_$(printf '%s' "$_step" | tr 'a-z' 'A-Z')"
  assert_has "Step $_step declares itself optional and gated" "$_f" \
    "optional and gated"
  # THREE conditions, ANDed. A gate documented as "any of" would let a dispatch
  # proceed on one condition -- for 6a that means dispatching against a live app
  # without the safety affirmative.
  # Count ONLY in the gate preamble -- before the first #### subheading. Step 6b
  # also numbers its three dispositions, and a whole-section count sums the two
  # into 6, which is a number no rule in the step actually asserts.
  assert_eq "Step $_step states all three gate conditions" \
    "$(awk '/^#### /{exit} /^[0-9]\. /{n++} END{print n+0}' "$_f")" "3"
  assert_has "Step $_step skips with no failure when the gate is closed" "$_f" \
    "no failure"
  # The decision summary is the table a reader consults under time pressure; a
  # step whose prose says "skip" and whose table omits the row is the shape that
  # gets skipped wrongly.
  assert_has "Step $_step carries a decision summary" "$_f" \
    "#### Decision summary"
done

# --- 6a: how the plugin is detected --------------------------------------
# Executing another plugin's content to test whether it is installed is exactly
# the probe you do not want; and seeing a surface listed is not permission to run
# it, which matters most for the router skill sitting in the same list.
assert_has "6a checks availability without executing plugin content" "$XT_6A" \
    "Never execute plugin content to probe for it"
assert_has "6a states detection is not a dispatch licence" "$XT_6A" \
    "confers no dispatch licence"

# --- 6a: exactly one sanctioned surface, and it is the AGENT ---------------
# The bare agent name matches four lines in the slice, so it cannot pin the
# "only sanctioned surface" claim AC3 asks for. Anchor on the exclusivity too.
assert_has "6a names stride-exploratory-testing:explorer as the surface" \
  "$XT_6A" 'stride-exploratory-testing:explorer'
assert_has "6a names it as the ONLY sanctioned surface" "$XT_6A" \
  "and nothing else"

# Every human-requiring surface must be named. Naming them individually matters:
# a reader who finds only a general "do not dispatch commands" rule has to
# decide for themselves whether the router skill counts, and the router is the
# one reached by mistake because the bare plugin name resolves to it.
# Delimit the needle with BOTH backticks and the leading slash. Bare
# "stride-exploratory-testing:explore" is a substring of the SANCTIONED agent's
# name, ":explorer", so an undelimited needle is satisfied by the very surface
# this step tells you to use -- the assertion would pass with the forbidden row
# deleted outright.
for _forbidden in explore pair recon nightmare-headline; do
  assert_has "6a forbids /$_forbidden by name" "$XT_6A" \
    '`/stride-exploratory-testing:'"$_forbidden"'`'
done

# Each forbidden surface needs its OWN reason. A shared "these need a human"
# blanket rots the moment one surface changes, and gives a reader nothing to
# re-verify against when the other plugin releases.
XT_FORBIDDEN_TABLE="$SANDBOX/xt_forbidden.txt"
awk '/\| Surface \| Why it needs a human \|/,/^$/' "$XT_6A" > "$XT_FORBIDDEN_TABLE"
if [ -s "$XT_FORBIDDEN_TABLE" ]; then
  ok "the forbidden-surface table extracted non-empty"
else
  nope "the forbidden-surface table extracted non-empty" "rows" "(empty)"
fi
# Count rows that actually NAME a surface -- not every line beginning with a
# pipe, which folds in the header and would report a populated table for one
# that lost every row.
# "router skill" also appears in the decision-summary row, so assert it inside
# the table -- the row that carries the REASON AC3 asks for.
assert_has "6a forbids the router skill by name" "$XT_FORBIDDEN_TABLE" \
    "router skill"
assert_eq "the forbidden-surface table has one row per surface" \
  "$(grep -cE '^\| (`/?stride-exploratory-testing|The `stride-exploratory-testing)' "$XT_FORBIDDEN_TABLE")" "5"

# The rule must be stated as a PRINCIPLE, not only as a list -- a list cannot
# classify a surface the next plugin release adds.
assert_has "6a gives a principle that generalizes past the list" "$XT_6A" \
    "without a human"
assert_has "6a says to re-verify the table when the other plugin changes" "$XT_6A" \
    "version changes"

# --- 6a runs at most once per task, on a settled diff ---------------------
# Without this, a task that loops the reviewer three times runs three exploratory
# sessions -- two of them against a diff that is about to change, spending probe
# budget on code that will not ship.
assert_has "6a enters at most once per task, on a settled diff" "$XT_6A" \
    "at most once per task"
assert_has "6a stays out of a changes_requested iteration" "$XT_6A" \
    "go straight to Step 7 and let the loop run"
# Reading Step 7's verdict early is a borrow, not a transfer -- say so, or the
# two steps end up both believing they own the counter.
assert_has "6a leaves the loop, counter and cap with Step 7" "$XT_6A" \
    "Step 7 still owns the loop, the counter and the cap"

# Every gate condition needs a row in the decision table too. Prose that says
# "skip" and a table that omits the row is the shape a reader under time pressure
# resolves by consulting the table -- and then not skipping.
XT_6A_TABLE="$SANDBOX/xt_6a_table.txt"
awk '/^\| Condition \| Action \|/{f=1} f && !/^\|/{exit} f' "$XT_6A" > "$XT_6A_TABLE"
# `- (none)` is the task template's rendering of an empty section, so a gate that
# stops recognising it dispatches a live-app session for EVERY task -- the
# most-taken path, and the first of the four edge cases the task itself lists.
assert_has "6a's first gate condition excludes the (none) placeholder" "$XT_6A" \
    "not \`- (none)\`"
assert_has "the 6a table has a row for a task with no manual tests" "$XT_6A_TABLE" \
    "- (none)"
assert_has "the 6a table has a row for a missing plugin" "$XT_6A_TABLE" \
    "Plugin not available"
assert_has "the 6a table has a row for an undispatchable explorer" "$XT_6A_TABLE" \
    "cannot dispatch the \`explorer\` agent"
assert_has "the 6a table has a row for a changes_requested iteration" "$XT_6A_TABLE" \
    "Do not enter"
assert_has "the 6a table has a row for a missing affirmative" "$XT_6A_TABLE" \
    "Never ask now"

# --- 6a: dispatch capability is its own gate condition --------------------
# The explorer ships in a DIFFERENT plugin on its own cadence, so "the agents are
# always available" -- true of stride-lite's own five subagents -- does not carry.
assert_has "6a checks it can actually dispatch the explorer" "$XT_6A" \
    "the \`Agent\` tool is present"
assert_has "6a does not assume the explorer's availability" "$XT_6A" \
    "do not assume it"
# The affirmative sits at dispatch level, not in the gate, so a drive that never
# reached a dispatch and a drive that reached one unauthorized stay distinct.
# NOT "not a fourth gate condition" -- the gitignore precondition reuses that
# phrase, so the needle survives deleting the affirmative paragraph entirely.
assert_has "6a places the affirmative at dispatch level, not in the gate" "$XT_6A" \
    "we got there and had no authorization"

# --- 6a: the safety affirmative ------------------------------------------
assert_has "6a requires an authorized-and-non-production affirmative" "$XT_6A" \
    "not production"
assert_has "6a forbids inferring the affirmative" "$XT_6A" \
    "Never infer it"
# The /recon table row also contains this phrase, so anchor on the affirmative
# subsection's own sentence.
assert_has "6a forbids supplying it on the user's behalf" "$XT_6A" \
    "Never infer it and never supply it on the user's behalf"
# Naming the collection point is what makes "never ask now" actionable rather
# than a dead end: without a named earlier point the rule reads as "you may
# never have it", and an agent under pressure resolves that by inferring one.
assert_has "6a names Step 0 as the collection point" "$XT_6A" \
    "Collect it at Step 0"
assert_has "6a resolves a missing affirmative to the skip, not a prompt" "$XT_6A" \
    "Do not ask now"

# And Step 0 must actually collect it, or the pointer dangles.
XT_STEP0="$SANDBOX/xt_step0.txt"
_slice_step '### Step 0' > "$XT_STEP0"
assert_has "Step 0 collects the authorized/non-production answer" "$XT_STEP0" \
    "authorized to test and is not production"
assert_has "Step 0 refuses to default to authorized" "$XT_STEP0" \
    "never default to authorized"
assert_has "Step 0 asks for a seed-data pointer, never pasted credentials" "$XT_STEP0" \
    "never pasted credentials"

# --- 6a: the session budget ----------------------------------------------
assert_has "6a requires a budget on every dispatch" "$XT_6A" \
    "Never omit it"
assert_has "6a pins the explorer's two-argument dispatch shape" "$XT_6A" \
    "takes exactly two arguments"
assert_has "6a says how to choose within the band" "$XT_6A" \
    "Pick from the band"
# The unit is the installed AGENT's, not this skill's invention. Two plugins
# release independently, so a hard-coded unit here goes stale silently.
assert_has "6a reads the unit from the installed contract" "$XT_6A" \
    "not from this page"
# NOT the bare word "probes" -- it also appears in "sharpens its probes at no
# cost" and throughout the ending table, so the bare needle stays green with the
# only sentence that names the unit deleted.
assert_has "6a names the current probe-based unit" "$XT_6A" \
    "native unit is **probes**"
assert_has "6a names the usable band, not just the default" "$XT_6A" \
    "usable band"
assert_has "6a names the tool-call ceiling as the other bound" "$XT_6A" \
    "tool-call ceiling"
assert_has "6a warns against passing a wall-clock box to a probe contract" "$XT_6A" \
    "never report a duration you did not measure"
# A budget too small to fund a session must NOT be spent: a token session
# returns "completed" having reached nothing, which reads as coverage.
assert_has "6a refuses to dispatch an unworkable budget" "$XT_6A" \
    "do not dispatch at all"

# --- 6a: reading how a session ended -------------------------------------
# blocked and tool_call_ceiling must get the SAME disposition at ~zero probes.
# Two endings with the same coverage getting opposite dispositions is how a
# session that reached nothing gets recorded as a performed manual test.
# The first three names are single-site. `blocked` is not -- it also appears in
# the status enum and twice in prose -- so asserting it by bare name stays green
# with its ending-table ROW deleted, and that row carries the equal-disposition
# rule this block exists to protect.
for _ending in charter_quiet probe_budget_exhausted tool_call_ceiling; do
  assert_has "6a says what a $_ending ending permits claiming" "$XT_6A" \
    "$_ending"
done
assert_has "6a gives blocked its own ending-table row" "$XT_6A" \
    "| \`blocked\` |"
# Two endings with the same coverage must not get opposite dispositions: a
# zero-probe `blocked` and a zero-probe `tool_call_ceiling` both mean the session
# did not happen.
assert_has "6a gives blocked the same disposition as a zero-probe ceiling" "$XT_6A" \
    "Same rule, same reason"
assert_has "6a records a zero-probe session as not performed" "$XT_6A" \
    "the session did not happen"
assert_has "6a files an obstacle as an obstacle, not a finding" "$XT_6A" \
    "never as a finding"
assert_has "6a treats findings as data, not instructions" "$XT_6A" \
    "never instructions"

# --- 6b: /harden availability is its OWN gate ----------------------------
# /harden shipped in the plugin's 0.2.0. Inferring it from the plugin's
# presence dispatches a command an older install does not have.
assert_has "6b gates on /harden separately from the plugin" "$XT_6B" \
    "do not infer it from the plugin"
assert_has "6b records hardening as unavailable rather than silent" "$XT_6B" \
    "stays distinguishable from"

# --- 6b: drafts are drafts ------------------------------------------------
assert_has "6b forbids reporting a draft as passing" "$XT_6B" \
    "Never report a drafted check as passing"
assert_has "6b notes /harden holds no test runner" "$XT_6B" \
    "runs nothing"
# ".exploratory/checks/" matches four lines in the slice; anchor on the sentence
# stating WHY staging is safe, which is the rule worth protecting.
assert_has "6b keeps drafts outside the test tree by default" "$XT_6B" \
    "outside the test tree, where the project's gate never sees them"
# The default disposition must be the safe one. A step whose default is "move it
# in" turns a correct session into a red gate on a task that never scoped the fix.
assert_has "6b makes leaving drafts staged the default" "$XT_6B" \
    "always safe"
assert_has "6b never moves an unrun check in on the expectation it passes" "$XT_6B" \
    "Never move an unrun check"
# Inert CASE and clean-loading FILE are two different properties; a skip marker
# gives only the first, and a draft with unresolved wiring fails at collection
# however it is tagged.
assert_has "6b distinguishes an inert case from a clean-loading file" "$XT_6B" \
    "does not make a *file* inert"
assert_has "6b notes xfail is not a skip" "$XT_6B" \
    "xfail"
assert_has "6b requires a suite-wide gate run, not the moved file alone" "$XT_6B" \
    "across the whole suite"
assert_has "6b reverts rather than leaving the gate red" "$XT_6B" \
    "revert everything"
# /harden suffixes collisions only inside its own staging dir, so the overwrite
# check on the MOVE is the workflow's own responsibility.
assert_has "6b owns the overwrite check on the move" "$XT_6B" \
    "Nothing is protecting the move **you** perform"
# The decision-summary row repeats this, so anchor on the prose rule that also
# states WHY -- a rule that turns on a judgement call resolves toward not doing it.
assert_has "6b re-runs the reviewer when a check entered the tree" "$XT_6B" \
    "still unreviewed executable code"

# --- The Bash-scope carve-out exists and is bounded ----------------------
# AC7 needs the project's gate command run, but the scope list forbids it
# outright. A contradiction between two sections of one skill is resolved by
# whichever the reader happens to hit first -- so the carve-out must be written
# where the prohibition is, not only where the need is.
XT_BASH="$SANDBOX/xt_bash.txt"
awk '/^## Bash scope/,/^## Edge cases/' "$XT_SKILL" > "$XT_BASH"
if [ -s "$XT_BASH" ]; then
  ok "the Bash scope section extracted non-empty"
else
  nope "the Bash scope section extracted non-empty" "content" "(empty)"
fi
assert_has "the gate-command prohibition carries the Step 6b exception" "$XT_BASH" \
    "One narrow exception, Step 6b only"
assert_has "the carve-out is scoped to Step 6b's move branch" "$XT_BASH" \
    "only on the move branch"
# The distinguishing rule: the skill never COMPOSES a test command, it re-runs
# the user's own. That is what keeps `mix test` closed as a skill-body capability
# while still permitting the one verification a tree entry needs.
assert_has "the carve-out composes nothing, it re-runs the user's own block" "$XT_BASH" \
    "never composed here"
assert_has "the carve-out still forbids a command this skill chose" "$XT_BASH" \
    "this skill chose"
# Bounded in both directions: naming what it does NOT license is what keeps a
# one-line exception from becoming a general licence to run the suite.
assert_has "the carve-out excludes a general test run" "$XT_BASH" \
    "not a general test run"
assert_has "the carve-out excludes re-running after_task" \
  "$XT_BASH" 'not re-running `## after_task`'

# Step 6b moves a file into the test tree and must be able to revert it. The
# revert has no non-Bash equivalent, so without a sanctioned command a compliant
# agent is pushed into the "clear the marker and stop" pitfall -- from inside a
# step that must never fail anything.
assert_has "the scope sanctions Step 6b's copy into the test tree" "$XT_BASH" \
    "into the project's test tree"
assert_has "the scope sanctions the revert Step 6b mandates" "$XT_BASH" \
    "on revert"
assert_has "the scope copies rather than moves, so a revert is possible" "$XT_BASH" \
    "Copy rather than move"
# The "ONLY sanctioned rm" claim became false the moment a second rm was
# sanctioned; an unamended absolute is worse than no claim.
assert_has "the scope's rm claim was amended, not left false" "$XT_BASH" \
    "only two"
# The pre-move existence check is in the TEST TREE, not under .exploratory/, so
# scoping it "under .exploratory/checks/" excluded one of the entry's own uses.
assert_has "the scope sanctions the pre-move check on its real path" "$XT_BASH" \
    "the single target path Step 6b is about to write"
assert_has "the scope covers reading a root-level project file" "$XT_BASH" \
    "Reading a root-level project file"
assert_has "the scope sanctions reading back what /harden staged" "$XT_BASH" \
    "for reading back what \`/harden\` staged"
# Every narrow carve-out here carries a confinement clause; an entry without one
# is how a carve-out becomes a general licence.
#
# Counting the CLAUSE was inverted: adding two unconfined bullets kept the count
# at 8 and passed, while adding a properly-confined one broke it. Check the
# property per bullet instead -- every step-scoped carve-out must confine itself.
XT_UNCONFINED=""
while IFS= read -r _b; do
  case "$_b" in
    *"Step 6a"*|*"Step 6b"*|*"Step 8"*|*"Step 0"*) ;;
    *) continue ;;
  esac
  case "$_b" in
    *"Forbidden elsewhere in the skill body"*|*"ONLY sanctioned"*|*"only two"*) ;;
    *) XT_UNCONFINED="$XT_UNCONFINED [${_b%%—*}]" ;;
  esac
done <<EOF_SCOPE
$(grep '^- ✅' "$XT_BASH")
EOF_SCOPE
assert_eq "every step-scoped Bash carve-out confines itself" "$XT_UNCONFINED" ""

# And pin the total, so a brand-new carve-out cannot slip in unnoticed even if it
# names no step. The number is the point: changing it must be deliberate.
assert_eq "the Bash allow-list has not grown silently" \
  "$(grep -c '^- ✅' "$XT_BASH")" "14"

# --- The user's project must actually ignore .exploratory/ ----------------
# This repo's own .gitignore protects this repo. Sessions write into the USER's
# project, and .gitignore is inert for a path once it is tracked -- so a mention
# at Step 0 that nothing verifies leaves the artifacts unprotected.
assert_has "6a checks the user's project ignores .exploratory/" "$XT_6A" \
    "confirm \`.exploratory/\` is actually ignored"
assert_has "an un-ignored .exploratory/ is a clean skip, not a failure" "$XT_6A" \
    "unmet means a clean skip with a recorded reason"
assert_has "6a never edits the user's .gitignore to satisfy the check" "$XT_6A" \
    "a check that repairs its own subject is not a check"
# The heading and the policy are not the instruction. Without this the
# precondition reduces to a heading with a policy and no action.
assert_has "6a says what to actually do when the entry is missing" "$XT_6A" \
    "skip Step 6a and record why"
# The read must be designated a Read, or the Bash-scope pitfall turns it into a
# halt -- from inside a step that must never fail anything.
assert_has "6a designates the read as a Read-tool operation" "$XT_6A" \
    "not a Bash call"

# --- .exploratory/ is gitignored ------------------------------------------
XT_GITIGNORE="$REPO_ROOT/.gitignore"
assert_eq "the repo gitignores .exploratory/" \
  "$(grep -cx '\.exploratory/' "$XT_GITIGNORE")" "1"
# Staged checks live outside the test tree on purpose; committing them defeats
# that, so the entry needs the reason attached or a later reader removes it.
assert_has "the .exploratory/ entry says why it is ignored" "$XT_GITIGNORE" \
    "OUTSIDE the test tree"

# --- 6c: the gate, and the placeholder rule it turns on -------------------
# `- (none)` is what stride-lite's OWN template renders for an empty list. It is
# a different string from stride's "None — no security surface" and from the
# security plugin's own "None — ..." verdict convention; a gate that matched
# stride's literal would never fire correctly on a stride-lite task file.
assert_has "6c gates on a non-empty Security considerations section" "$XT_6C" \
    "at least one real consideration"
assert_has "6c gates on the security plugin being available" "$XT_6C" \
    '`stride-security-review` plugin is available'
assert_has "6c checks it can actually dispatch the security-reviewer" "$XT_6C" \
    "not implied by the first"
# Anchor on the RULES, not the rationale sentence below them. The earlier
# needles matched only the "Forms 3 and 4 exist because..." paragraph, so both
# rules could be deleted outright with the suite green.
assert_eq "6c enumerates exactly four placeholder forms" \
  "$(awk '/^#### Which section entries count/{f=1} f&&/^#### Count first/{exit} f&&/^[0-9]\. /{n++} END{print n+0}' "$XT_6C")" "4"
assert_has "6c treats an empty entry as a placeholder" "$XT_6C" \
    "1. is empty, **or**"
assert_has "6c treats a bare none as a placeholder" "$XT_6C" \
    '3. is `none`, **or**' 
assert_has "6c treats none-plus-separator as a placeholder" "$XT_6C" \
    "followed by a separator: an em dash"
assert_has "6c excludes the template's own (none) placeholder" "$XT_6C" \
    "the literal stride-lite's own template renders"
assert_has "6c also excludes the None-em-dash form a hand-written file can carry" "$XT_6C" \
    "None — no security surface"
assert_has "6c matches the placeholder case-insensitively" "$XT_6C" \
    "so \`(None)\` and \`(NONE)\` are placeholders too"
# A bullet that merely says the word "none" mid-sentence is a real consideration.
assert_has "6c keeps the placeholder list closed" "$XT_6C" \
    "closed and short on purpose"
assert_has "6c checks availability without executing plugin content" "$XT_6C" \
    "never by executing plugin content to probe for it"
# An absent section and an explicit (none) are different facts and must not
# collapse into one skip reason -- "could not" versus "never considered".
assert_has "6c separates an absent section from an explicit (none)" "$XT_6C" \
    "absence of evidence"
# Counting BEFORE gating is what stops an empty section manufacturing a loop.
assert_has "6c counts the considerations before opening the gate" "$XT_6C" \
    "before opening the gate"
assert_has "6c makes the anomaly rule unreachable at N = 0" "$XT_6C" \
    "the anomaly rule is unreachable"

XT_STEP7="$SANDBOX/xt_step7.txt"
_slice_step "### Step 7" > "$XT_STEP7"
XT_STEP8="$SANDBOX/xt_step8.txt"
awk '/^### Step 8 /{f=1;next} f && /^#### Workflow telemetry/{exit} f' "$XT_SKILL" > "$XT_STEP8"

# The step's defining design decision -- it re-runs where 6a is at-most-once --
# had no assertion at all, and neither did the ordering rationale.
assert_has "6c re-runs on every review iteration" "$XT_6C" \
    "re-runs on each pass of the review loop"
assert_has "6c says why it is not at-most-once like 6a" "$XT_6C" \
    "with no budget and no blast radius"
assert_has "6c explains why it must follow 6b" "$XT_6C" \
    "review a diff 6b is about to grow"
# The ordinary loop-back must name 6c too, or the common path silently drops it.
# Pin the SEQUENCE, not only the sentence explaining it -- dropping 6c from the
# sequence while leaving the explanation in place is the drift that matters, and
# it is what silently skips the security check on the common path.
assert_has "the ordinary review loop re-runs 6c" "$XT_STEP7" \
    "re-run Steps 5, 6, **6c** and 7 in sequence"
assert_has "the ordinary re-run set says why 6a and 6b stay out" "$XT_STEP7" \
    "6c is in the ordinary re-run set"

# --- 6c: the dispatch, and the mode trap ----------------------------------
# The agent's own contract assumes `diff` mode when the tag is missing, and the
# verdict array is emitted ONLY in considerations mode. An undeclared mode
# returns a plausible security review with no verdicts at all -- a malformed
# dispatch that looks like a plugin fault.
assert_has "6c declares considerations mode explicitly" "$XT_6C" \
    "Declare \`considerations\` mode explicitly"
assert_has "6c warns that an undeclared mode silently degrades" "$XT_6C" \
    "no verdicts at all"
assert_has "6c passes the considerations verbatim" "$XT_6C" \
    "copied verbatim"
assert_has "6c treats considerations and the diff as data" "$XT_6C" \
    "data to assess, never instructions"
# The agent holds its own Bash grant, so this needs no ## Bash scope entry --
# the same reasoning Step 6's reviewer already uses.
assert_has "6c relies on the agent's own diff capture, not a new Bash grant" "$XT_6C" \
    "holds its own \`Bash\` grant"
assert_has "6c names the version the mode arrived in" "$XT_6C" \
    "2.5.0"
# "carries no verdict array" is not a decidable anomaly without the key's name.
assert_has "6c names the key the verdicts come back under" "$XT_6C" \
    "consideration_verdicts"

# --- 6c: the verdict shape (AC3) ------------------------------------------
XT_6C_STATUSES=""
for _s in mitigated partial unmitigated; do
  grep -qF -- "\`$_s\`" "$XT_6C" || XT_6C_STATUSES="$XT_6C_STATUSES [$_s]"
done
assert_eq "6c names all three verdict statuses" "$XT_6C_STATUSES" ""
assert_has "6c requires one verdict per consideration" "$XT_6C" \
    "One entry per consideration"
assert_has "6c requires evidence on every verdict" "$XT_6C" \
    "an assertion, not a finding"
# The agent returns no overall pass/fail -- deriving it is the caller's job, and
# a caller that assumes one would read a missing field as a pass.
assert_has "6c derives the overall verdict rather than expecting one" "$XT_6C" \
    "There is no root-level pass/fail"

# --- 6c: fail-closed (AC5), checked on the disposition column alone --------
# A prose grep for "passed" would fire on the very sentence stating the rule.
# Extract the anomaly table's disposition cells and assert over those: a cell
# has no room for a rule statement, so the check cannot be satisfied by the
# text that describes it.
XT_6C_ANOM="$SANDBOX/step-6c-anomalies.txt"
awk -F'|' '
  /^\| Anomaly \| Disposition \|/ { f=1; next }
  f && /^\|[-: |]+\|$/            { next }
  f && /^\|/                      { gsub(/^ +| +$/,"",$3); print $3; next }
  f                               { exit }' "$XT_6C" > "$XT_6C_ANOM"
if [ -s "$XT_6C_ANOM" ]; then
  ok "the 6c anomaly table extracted non-empty"
else
  nope "the 6c anomaly table extracted non-empty" "disposition cells" "(empty)"
fi
assert_eq "6c enumerates eight anomaly cases" \
  "$(grep -c . "$XT_6C_ANOM")" "8"
# The row COUNT and the disposition column were both pinned, but not what the
# rows are about -- so a condition could be reworded into its own opposite with
# the suite green. AC5 names three cases specifically; pin those.
XT_6C_ROWS=""
for _c in "no fenced JSON block" "carries no verdict array" "present but empty"           "Fewer entries than the N counted" "outside the three-value enum"           "no evidence" "corresponding to no counted consideration"           "unreachable at call time"; do
  grep -qF -- "$_c" "$XT_6C" || XT_6C_ROWS="$XT_6C_ROWS [$_c]"
done
assert_eq "every anomaly row names its own condition" "$XT_6C_ROWS" ""
# THE negative for AC5. Nothing in a disposition cell may resolve to a pass.
assert_eq "no anomaly disposition resolves to a pass" \
  "$(grep -ciE 'mitigated|passed|approved|proceed to Step 8' "$XT_6C_ANOM")" "0"
# And the disposition vocabulary is closed at two values, so a third could not
# be introduced without the test noticing.
XT_6C_BADDISP=""
while IFS= read -r _d; do
  [ -n "$_d" ] || continue
  case "$_d" in
    *"changes_requested"*|*"Clean skip"*) ;;
    *) XT_6C_BADDISP="$XT_6C_BADDISP [$_d]" ;;
  esac
done < "$XT_6C_ANOM"
assert_eq "every anomaly disposition is a loop-back or a recorded skip" \
  "$XT_6C_BADDISP" ""
assert_has "6c states the fail-closed rule in its own words" "$XT_6C" \
    "never dispositioned as \`mitigated\`"
assert_has "6c distinguishes fail-closed from failing the task" "$XT_6C" \
    "It does not mean this step fails the task"
assert_has "a dispatch that never ran is a skip, not a loop" "$XT_6C" \
    "produced no evidence in either direction"

# --- 6c writes nothing it does not own ------------------------------------
assert_has "6c never writes into the Review Report" "$XT_6C" \
    "this skill never writes into it"
assert_has "6c never edits the Security considerations section" "$XT_6C" \
    "never edits \`## Security considerations\`"
assert_has "6c does not hand its verdicts to the reviewer" "$XT_6C" \
    "reaches its own conclusions from its own pass"
# Consideration and evidence strings are author-authored and nothing upstream
# redacts them; the verdicts are routed to the Completion Summary and surfaced
# at the cap, so both carriers need the rule.
assert_has "6c redacts rather than pasting consideration or evidence text" "$XT_6C" \
    "REDACTED — text embedded a credential"
assert_has "6c echoes verbatim only to the agent, not into the record" "$XT_6C" \
    "restate it in your own words"

# --- Step 8 records the security outcome ----------------------------------
assert_has "Step 8 records the security-considerations outcome" "$XT_STEP8" \
    "The security-considerations outcome"
assert_has "Step 8 carries the redaction rule for considerations" "$XT_STEP8" \
    "out of a consideration or an evidence string"
assert_has "Step 8 keeps the two skip reasons distinct" "$XT_STEP8" \
    "there was no readable section"
# Step 7 tells the reader Step 8 labels stale coverage; that label must exist.
assert_has "Step 8 labels coverage predating a security fix" "$XT_STEP8" \
    "pre-dating the security fix"

# --- Step 7's security-escalation branch (AC4) ----------------------------
# Both slices are also built later in this file for the session-branch
# assertions; building them here too is idempotent and keeps each block
# readable on its own rather than depending on where it sits in the file.
XT_STEP7="$SANDBOX/xt_step7.txt"
_slice_step "### Step 7" > "$XT_STEP7"
XT_AGENTS="$REPO_ROOT/AGENTS.md"
assert_has "Step 7 carries the security-escalation branch" "$XT_STEP7" \
    "Security-escalation branch"
# Each branch needs its OWN cap sentence: sharing one phrasing would make both
# assertions vacuous, since either could satisfy the other's needle.
assert_has "the security escalation reuses the existing cap" "$XT_STEP7" \
    "bounded by the same \`max_review_iterations\` cap"
assert_eq "the session branch's cap sentence stays single-site" \
  "$(grep -c 'The cap is the same `max_review_iterations`' "$XT_STEP7")" "1"
assert_has "the security escalation adds no second cap" "$XT_STEP7" \
    "Do not add a second cap"
assert_has "the two escalations share one increment per iteration" "$XT_STEP7" \
    "One increment per iteration, not one per branch"
assert_has "reaching Step 8 is a conjunction of all three verdicts" "$XT_STEP7" \
    "necessary and no longer sufficient"
assert_has "the conjunction is scoped to what 6c returned, not what it listed" "$XT_STEP7" \
    "**returned a verdict for** came back"
assert_has "a skipped 6c satisfies the conjunction vacuously" "$XT_STEP7" \
    "satisfies this conjunct vacuously"
assert_has "6a does not re-enter on the security escalation" "$XT_STEP7" \
    "Step 6a does not re-enter on this branch"
assert_has "coverage predating a security fix is labelled as such" "$XT_STEP7" \
    "pre-dating the security fix"

# --- task-reviewer documents the verdict array (AC6) ----------------------
# agents/task-reviewer.md had no coverage at all before this task.
XT_REVIEWER="$REPO_ROOT/agents/task-reviewer.md"
XT_RV_STRUCT="$SANDBOX/reviewer-structured.txt"
awk '/^### Structured result$/{f=1;next} f && /^## /{exit} f' "$XT_REVIEWER" > "$XT_RV_STRUCT"
if [ -s "$XT_RV_STRUCT" ]; then
  ok "the reviewer's Structured result section extracted non-empty"
else
  nope "the reviewer's Structured result section extracted non-empty" "content" "(empty)"
fi
assert_has "the reviewer documents the security_considerations object" "$XT_RV_STRUCT" \
    '"security_considerations"'
assert_has "the reviewer documents the per-consideration array" "$XT_RV_STRUCT" \
    '"considerations"'
XT_RV_MISSING=""
for _f in mitigated partial unmitigated evidence consideration; do
  grep -qF -- "\"$_f\"" "$XT_RV_STRUCT" || XT_RV_MISSING="$XT_RV_MISSING [$_f]"
done
assert_eq "the verdict array documents its full entry shape" "$XT_RV_MISSING" ""
assert_has "a single bad entry cannot leave the section passed" "$XT_RV_STRUCT" \
    "can never leave the section status at"
# The nested array arrived at stride schema 1.5, so a block citing 1.1 could not
# legitimately carry it. Pin the cited version to one that has the field.
assert_eq "the reviewer cites a schema version that carries considerations[]" \
  "$(grep -oE 'schema_version .[0-9]+\.[0-9]+.' "$XT_REVIEWER" | sort -u | grep -c '1\.6')" "1"
# The citation is written schema_version `"1.1"` -- backtick then quote -- so a
# pattern expecting a single character between them can never match, and the
# negative passed against the very defect it was written to catch.
assert_eq "the reviewer no longer cites the pre-considerations schema 1.1" \
  "$(grep -c 'schema_version [^0-9]*1\.1' "$XT_REVIEWER")" "0"
# Stronger: every citation in the file must resolve to the same version.
assert_eq "every schema citation in the reviewer agrees" \
  "$(grep -oE 'schema_version [^0-9]*[0-9]+\.[0-9]+' "$XT_REVIEWER" | grep -oE '[0-9]+\.[0-9]+' | sort -u | tr '\n' ' ')" \
  "1.6 "
assert_has "the reviewer has a security-considerations methodology step" "$XT_REVIEWER" \
    "**Security considerations.**"
# The reviewer's placeholder rule must not be a SHORTER restatement of the
# workflow's -- two parsers of one section that disagree describe it
# incompatibly, and the disagreement surfaces as a `critical` verdict against a
# placeholder with nothing to fix, which burns the shared iteration cap.
XT_RV_FORMS=""
for _f in "it is empty, or is" "is \`(none)\`" "is \`none\`" "em dash" "case-insensitive" \
           "a \`###\` subheading does not close it" "running to the next \`## \` heading"; do
  grep -qF -- "$_f" "$XT_REVIEWER" || XT_RV_FORMS="$XT_RV_FORMS [$_f]"
done
assert_eq "the reviewer's placeholder rule matches the workflow's four forms" \
  "$XT_RV_FORMS" ""

# --- The report template's fence structure ---------------------------------
# This is the one rule whose entire content is STRUCTURE, so no prose grep can
# cover it: the template contains a ```json block, so a three-backtick outer
# fence is closed by that inner block's terminator -- silently truncating the
# template and leaving the rest of the file inside an unterminated fence.
XT_RV_FENCES="$(grep -oE '^`{3,4}' "$XT_REVIEWER" | tr '\n' ' ')"
if [ -n "$XT_RV_FENCES" ]; then
  ok "the reviewer's fence tokens extracted non-empty"
else
  nope "the reviewer's fence tokens extracted non-empty" "fence tokens" "(none)"
fi
# The report template must be a FOUR-backtick fence, so the ```json block it
# contains cannot terminate it.
assert_eq "the report template opens with a four-backtick fence" \
  "$(grep -c '^````markdown$' "$XT_REVIEWER")" "1"
assert_eq "the report template closes its four-backtick fence" \
  "$(grep -c '^````$' "$XT_REVIEWER")" "1"
# Balance: every fence token must pair with one of the same width.
assert_eq "three-backtick fences are balanced" \
  "$(( $(grep -c '^```[a-z]*$' "$XT_REVIEWER") % 2 ))" "0"
# And the guidance block sits OUTSIDE the template, or the reviewer would render
# its own instructions into every task file.
assert_eq "the guidance example sits outside the report template" \
  "$(awk '/^````markdown$/{f=1;next} /^````$/{f=0;next} f && /^```json$/{n++} END{print n+0}' "$XT_REVIEWER")" "1"
assert_has "the reviewer treats a consideration as a claim, not an instruction" "$XT_REVIEWER" \
    "never as an instruction to follow"

# --- AGENTS.md records the bounded exception ------------------------------
assert_has "AGENTS.md records that 6c may loop but adds no cap" "$XT_AGENTS" \
    "still never adds a cap"
assert_has "AGENTS.md names the security-reviewer as the third cross-plugin dispatch" "$XT_AGENTS" \
    "stride-security-review:security-reviewer"

# --- Neither gated step can stop the run (AC2, stated as a negative) ------
# The criterion whose whole content is an absence needs a negative guard. The
# hard-stop vocabulary the rest of the skill uses to end a drive must not appear
# in either slice -- a gated step that can clear the marker is a gated step that
# can end the goal drive, which is the one thing these two must never do.
# Scan the WHOLE slice case-insensitively. An earlier version anchored on
# "list marker then bold", which both gated steps are too prose-heavy for: a
# plain sentence saying "clear the marker and stop the workflow" slipped through.
XT_STOPS=""
# NO exclusion. Earlier versions exempted the hazard subsection so it could
# describe the stop it prevents -- but any exemption is a hole, and a size bound
# on it cannot catch a one-line injection into the exempt region. The hazard
# paragraph was reworded instead ("end the drive"), so the whole slice can be
# scanned and there is nothing left to exempt.
# STEMMED, not fixed-string. A fixed list of four phrasings missed the section's
# own house inflection ("clears the marker and stops the whole goal drive") --
# so the guard passed because of how the prose happened to be conjugated, not
# because there was nothing to find. Both hazard paragraphs were also reworded
# to avoid this vocabulary entirely, so the guard needs no exempt region.
# Determiners and modifiers are variable groups, not fixed words: "stop this
# drive", "halt the entire drive" and "stop the goal" are one word away from
# forms already covered, and reachable by ordinary prose editing rather than by
# adversarial phrasing. The marker branch likewise allows a qualifier, so
# "clear the activation marker" cannot slip past a fixed adjacency.
XT_STOP_RE='(clear|clears|clearing) (the |this |that )?[^.]{0,24}marker|(stop|stops|stopping|end|ends|ending|halt|halts|halting|abort|aborts|aborting|terminate|terminates|terminating|abandon|abandons|abandoning) (the|this|that) (whole |entire |current )?(workflow|goal drive|goal|drive|run|task)'
for _f in "$XT_6A" "$XT_6B" "$XT_6C"; do
  if grep -qiE -- "$XT_STOP_RE" "$_f"; then
    XT_STOPS="$XT_STOPS [$(basename "$_f"): $(grep -ioE -- "$XT_STOP_RE" "$_f" | head -1)]"
  fi
done
assert_eq "no gated step's own body instructs the reader to stop the run" "$XT_STOPS" ""

# --- The move branch's command vocabulary is closed -----------------------
# The suite pinned that the carve-out entries are PRESENT, never that the
# allow-list covers every operation Step 6b's prose actually mandates. It did
# not: an earlier draft sanctioned reverting a directory `cp` cannot create and
# no entry sanctioned creating, so a draft targeting a new directory left the
# branch with no legal command -- and the Bash-scope pitfall turns that into a
# halted drive from inside a step that must never fail anything.
# Exclude the one line that names another command's allow-list rather than this
# workflow's own vocabulary -- Step 6b legitimately reports that /harden's Bash
# grant is `date` and `mkdir`, which is a fact about /harden, not an instruction
# to this workflow. Narrow, single-purpose, and guarded for size below.
# Strip the CLAUSE, not the line. Dropping the whole line also drops whatever
# else shares it -- and since that line already contains `mkdir`, a real
# instruction appended to the same sentence became invisible. Same shape as the
# subsection exemption removed in an earlier round, one sentence smaller.
XT_6B_OWN="$SANDBOX/step-6b-own-commands.txt"
sed 's/Its own allow-list is `date` and `mkdir`;//' "$XT_6B" > "$XT_6B_OWN"
# The clause must actually have been present and actually have been removed --
# a renamed clause would silently leave `mkdir` in the haystack and fail loudly,
# which is the safe direction, but a silent no-op strip would not.
assert_eq "the closure check strips exactly the /harden allow-list clause" \
  "$(grep -c 'Its own allow-list is' "$XT_6B")-$(grep -c 'Its own allow-list is' "$XT_6B_OWN")" \
  "1-0"
XT_6B_CMDS=""
for _cmd in mkdir mv rmdir rsync install ln; do
  grep -qiE -- "\`$_cmd|\b$_cmd -" "$XT_6B_OWN" && XT_6B_CMDS="$XT_6B_CMDS [$_cmd]"
done
assert_eq "Step 6b's prose names no command outside its two-command allow-list" \
  "$XT_6B_CMDS" ""
# And it must say so, rather than leaving the closure implicit.
assert_has "the scope states the move branch's whole vocabulary" "$XT_BASH" \
    "no \`mkdir\`, no \`mv\`, no \`rmdir\`"
assert_has "6b defers rather than creating a missing target directory" "$XT_6B" \
    "do not create it: take disposition 3"
assert_has "6b's revert is exactly one file" "$XT_6B" \
    "which is exactly one file"

# --- The escalation lives in Step 7, which owns the loop and the cap -------
XT_STEP7="$SANDBOX/xt_step7.txt"
_slice_step "### Step 7" > "$XT_STEP7"
assert_has "Step 7 carries the session-escalation branch" "$XT_STEP7" \
    "Session-escalation branch"
assert_has "the session escalation reuses the existing cap" "$XT_STEP7" \
    "The cap is the same \`max_review_iterations\`"
# A re-run that stopped on its budget before reaching the defect has verified
# nothing; reading it as confirmation is the failure this pins.
assert_has "the escalation requires the re-run to re-reach the defect" "$XT_STEP7" \
    "must actually re-reach the defect"
assert_has "a discovered Critical never enters the loop" "$XT_STEP7" \
    "never enters this branch"
# The reviewer agent owns ## Review Report; the skill body never writes there.
assert_has "the escalation does not hand-edit the Review Report" "$XT_STEP7" \
    "Do not edit \`## Review Report\`"

# --- Provenance is decided from agent-owned artifacts, never app output ----
assert_has "6a decides provenance from the workflow's own artifacts" "$XT_6A" \
    "never from the application's text"
# stride reconstructs a line-exact change set from a claim-time base ref.
# stride-lite has none, and guessing one is worse than admitting the gap.
assert_has "6a admits it cannot reconstruct a change set" "$XT_6A" \
    "Do not reconstruct one"
assert_has "6a falls back to discovered when there is no Review Report" "$XT_6A" \
    "No \`## Review Report\` at all"

# --- Red flags names the surface a reader is most likely to reach for ------
XT_RED="$SANDBOX/xt_red.txt"
awk '/^## Red flags/{f=1;next} f && /^## /{exit} f' "$XT_SKILL" > "$XT_RED"
# Same trap: the Red flags entry legitimately names the sanctioned agent as the
# remedy, so any needle ":explorer" satisfies proves nothing. Anchor on the
# entry's own reasoning -- why /explore is the tempting mistake.
assert_has "Red flags warns against reaching for /explore" "$XT_RED" \
    "headline command"
assert_has "Red flags warns the bare plugin name hits the router" "$XT_RED" \
    "resolves to the router skill"
assert_has "Red flags rejects inferring authorization from localhost" "$XT_RED" \
    "localhost"
assert_has "Red flags rejects calling a draft covered" "$XT_RED" \
    "Drafted, not run"

# --- Step 8 records both outcomes in the Completion Summary ---------------
# Telemetry records whether a step ran; the summary records what it found. A
# dispatched session whose result appears nowhere in prose is the shape that
# lets "manual tests performed" stand on a session that reached nothing.
XT_STEP8="$SANDBOX/xt_step8.txt"
awk '/^### Step 8 /{f=1;next} f && /^#### Workflow telemetry/{exit} f' "$XT_SKILL" > "$XT_STEP8"
assert_has "Step 8 records the exploratory outcome" "$XT_STEP8" \
    "The exploratory-testing outcome"
assert_has "Step 8 records a partial session as partial" "$XT_STEP8" \
    "rather than folded into"
assert_has "Step 8 redacts findings rather than copying them" "$XT_STEP8" \
    "Restate findings in the workflow's own words"
assert_has "Step 8 records the hardening outcome" "$XT_STEP8" \
    "The hardening outcome"
assert_has "Step 8 phrases drafts as drafted, not run" "$XT_STEP8" \
    "drafted, not run"
assert_has "Step 8 carries a discovered Critical into goal.md" "$XT_STEP8" \
    "Any discovered Critical"

# --- AGENTS.md keeps the no-network contract intact -----------------------
# The integration dispatches another plugin's agent, which can reach a running
# app. The contract is unchanged -- stride-lite still opens no socket -- but the
# distinction is subtle enough that a later reader could take it as licence to
# add an HTTP client "since we already talk to the app now."
XT_AGENTS="$REPO_ROOT/AGENTS.md"
assert_has "AGENTS.md states a dispatch is not a network call" "$XT_AGENTS" \
    "not a network call"
assert_has "AGENTS.md refuses it as a precedent for an API client" "$XT_AGENTS" \
    "a precedent for one"
assert_has "AGENTS.md keeps the other plugin optional in both directions" "$XT_AGENTS" \
    "No hard dependency on another plugin"
assert_has "AGENTS.md forbids probing by executing plugin content" "$XT_AGENTS" \
    "check availability only"
assert_has "AGENTS.md records that neither gated step can fail a task" "$XT_AGENTS" \
    "able to fail a task"

# --- The README's step count tracks the vocabulary ------------------------
# README.md states how many loop steps the telemetry records. It is a hand-
# maintained number in a different file, so it drifts silently the moment the
# vocabulary changes -- which is exactly what happened to it this commit.
XT_README="$REPO_ROOT/README.md"
assert_eq "the README's telemetry step count matches the vocabulary" \
  "$(grep -oE 'records all [a-z]+ loop steps' "$XT_README" | head -1)" \
  "records all ten loop steps"
# And the two gated sub-steps are documented where a reader looks for the loop,
# not only inside the skill that implements them.
for _sub in "Step 6a" "Step 6b" "Step 6c"; do
  assert_eq "the README documents $_sub" \
    "$(grep -c "$_sub —" "$XT_README")" "1"
done

# --- Both new telemetry names are wired into the vocabulary ---------------
# Without this, the two most-skippable steps in the workflow are the two with
# no record of having been skipped.
for _name in exploratory harden; do
  assert_eq "the telemetry vocabulary carries a \`$_name\` row" \
    "$(printf '%s\n' "$TELEM_NAMES" | grep -cx "$_name")" "1"
done

echo ""
echo "release surface"

# ---------------------------------------------------------------------------
# The documented counts and the shipped files must agree. Every one of these
# was a hand-maintained number in prose, which is precisely the class of
# staleness the CHANGELOG records fixing release after release.
# ---------------------------------------------------------------------------
RS_AGENTS="$REPO_ROOT/AGENTS.md"
RS_README="$REPO_ROOT/README.md"
RS_SEC="$REPO_ROOT/SECURITY.md"
RS_PLUGIN="$REPO_ROOT/.claude-plugin/plugin.json"
RS_CHANGELOG="$REPO_ROOT/CHANGELOG.md"

# --- SECURITY.md exists and covers what it must ---------------------------
if [ -s "$RS_SEC" ]; then
  ok "SECURITY.md exists at the repo root"
else
  nope "SECURITY.md exists at the repo root" "a non-empty SECURITY.md" "missing or empty"
fi
# The execution model is the whole reason the file exists: the plugin runs
# user-authored shell commands and deliberately does not validate them.
assert_has "SECURITY.md states the plugin runs user-authored commands" "$RS_SEC" \
    "executes shell commands that the user wrote"
assert_has "SECURITY.md states it does not validate them" "$RS_SEC" \
    "deliberately does not validate them"
# The marker's non-security status, so no future change leans on it.
assert_has "SECURITY.md states the marker is not an authorization mechanism" "$RS_SEC" \
    "not an authorization mechanism"
assert_has "SECURITY.md says any local process can forge the marker" "$RS_SEC" \
    "process can create the file"
# The cross-plugin surfaces and the affirmative that gates the riskiest.
assert_has "SECURITY.md covers the cross-plugin dispatch surfaces" "$RS_SEC" \
    "Cross-plugin dispatch surfaces"
assert_has "SECURITY.md names the affirmative as a user-supplied control" "$RS_SEC" \
    "authorized-and-non-production affirmative"
assert_has "SECURITY.md states a dispatch is not a network call" "$RS_SEC" \
    "A dispatch is not a network call"
assert_has "SECURITY.md gives a reporting channel" "$RS_SEC" "## Reporting"
# An overstated security claim in a shipped document is itself a risk, so the
# one thing that has NOT been verified must say so.
assert_has "SECURITY.md does not overclaim Windows verification" "$RS_SEC" \
    "has not been verified on a real Windows host"
# The marker gate is NOT unconditional -- an environment variable bypasses it.
# Describing it as absolute gives a security reviewer a model the code does not
# have, which is the failure mode the fifth consideration names.
assert_has "SECURITY.md names the marker-gate bypass" "$RS_SEC" \
    "STRIDE_LITE_ALLOW_DIRECT=1"
assert_has "SECURITY.md explains why the bypass supports the model" "$RS_SEC" \
    "A gate anyone can turn off with an environment variable"

# --- Documented counts match the filesystem -------------------------------
RS_COUNT_BAD=""
_rs_check() {  # $1 = human number word, $2 = actual count, $3 = what
  local _word="$1" _actual="$2" _what="$3" _expect
  case "$_actual" in
    3) _expect=three ;; 4) _expect=four ;; 5) _expect=five ;; 6) _expect=six ;;
    7) _expect=seven ;; 8) _expect=eight ;; 9) _expect=nine ;; 10) _expect=ten ;;
    *) _expect="$_actual" ;;
  esac
  [ "$_word" = "$_expect" ] || RS_COUNT_BAD="$RS_COUNT_BAD [$_what: doc says $_word, tree has $_actual]"
}
_rs_check "$(grep -oE '(three|four|five|six|seven|eight|nine|ten) subagents' "$RS_AGENTS" | head -1 | awk '{print $1}')" \
          "$(ls "$REPO_ROOT"/agents/*.md 2>/dev/null | grep -c .)" "subagents"
_rs_check "$(grep -oE '(three|four|five|six|seven|eight|nine|ten) \`lib/\` helpers' "$RS_AGENTS" | head -1 | awk '{print $1}')" \
          "$(ls "$REPO_ROOT"/lib/*.md 2>/dev/null | grep -c .)" "lib helpers"
_rs_check "$(grep -oE '(three|four|five|six|seven|eight|nine|ten) skills' "$RS_AGENTS" | head -1 | awk '{print $1}')" \
          "$(ls -d "$REPO_ROOT"/skills/*/ 2>/dev/null | grep -c .)" "skills"
_rs_check "$(grep -oiE '(three|four|five|six|seven|eight|nine|ten) slash commands' "$RS_AGENTS" | head -1 | awk '{print tolower($1)}')" \
          "$(ls "$REPO_ROOT"/commands/*.md 2>/dev/null | grep -c .)" "slash commands"
assert_eq "every count documented in AGENTS.md matches the tree" "$RS_COUNT_BAD" ""

# Every agent file must appear in the layout block, so a new subagent cannot be
# added without the map noticing.
# Extract the fenced layout block FIRST. Grepping the whole file meant
# hooks.json and the two executors -- each named several times in the prose --
# were "found" no matter what the layout block said, so the assertion covered
# only the files that did not need it.
RS_LAYOUT="$SANDBOX/agents-layout.txt"
awk '/^## Repository layout$/{f=1;next} f && /^## /{exit} f' "$RS_AGENTS" > "$RS_LAYOUT"
if [ -s "$RS_LAYOUT" ]; then
  ok "the AGENTS.md layout block extracted non-empty"
else
  nope "the AGENTS.md layout block extracted non-empty" "content" "(empty)"
fi
RS_LAYOUT_MISSING=""
for _a in "$REPO_ROOT"/agents/*.md; do
  _b="$(basename "$_a")"
  grep -qF -- "$_b" "$RS_LAYOUT" || RS_LAYOUT_MISSING="$RS_LAYOUT_MISSING [$_b]"
done
assert_eq "every agent file appears in the AGENTS.md layout block" "$RS_LAYOUT_MISSING" ""
# ...and the same for the lib helpers and the hooks directory's shipped files.
RS_LIB_MISSING=""
for _l in "$REPO_ROOT"/lib/*.md; do
  grep -qF -- "$(basename "$_l")" "$RS_LAYOUT" || RS_LIB_MISSING="$RS_LIB_MISSING [$(basename "$_l")]"
done
assert_eq "every lib helper appears in the AGENTS.md layout block" "$RS_LIB_MISSING" ""
RS_HOOKS_MISSING=""
for _h in "$REPO_ROOT"/hooks/*; do
  grep -qF -- "$(basename "$_h")" "$RS_LAYOUT" || RS_HOOKS_MISSING="$RS_HOOKS_MISSING [$(basename "$_h")]"
done
assert_eq "every hooks/ file appears in the AGENTS.md layout block" "$RS_HOOKS_MISSING" ""
# ...and every top-level entry, since SECURITY.md and README both send readers
# to install.sh and test/smoke.sh, neither of which the map used to list.
RS_TOP_MISSING=""
for _t in install.sh test fixtures docs README.md AGENTS.md SECURITY.md CHANGELOG.md LICENSE; do
  [ -e "$REPO_ROOT/$_t" ] || continue
  grep -qF -- "$_t" "$RS_LAYOUT" || RS_TOP_MISSING="$RS_TOP_MISSING [$_t]"
done
assert_eq "every top-level entry appears in the AGENTS.md layout block" "$RS_TOP_MISSING" ""

# --- The version has exactly one source -----------------------------------
RS_VERSION="$(grep -oE '"version": *"[0-9]+\.[0-9]+\.[0-9]+"' "$RS_PLUGIN" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
if [ -n "$RS_VERSION" ]; then
  ok "plugin.json carries a semver version"
else
  nope "plugin.json carries a semver version" "a version field" "(none)"
fi
# The CHANGELOG's top entry must name that version, which is the pairing
# AGENTS.md makes a hard rule.
assert_eq "the CHANGELOG's top entry matches plugin.json" \
  "$(grep -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' "$RS_CHANGELOG" | head -1 | tr -d '#[] ')" "$RS_VERSION"
# ...and it is stated nowhere else, so a bump can never half-land.
# Exclude .git. A commit message legitimately names the version it ships, and
# .git/COMMIT_EDITMSG holds the most recent one -- so without this the assertion
# passes until the release is committed and fails immediately afterwards, which
# is the worst possible time for it to go off.
RS_VER_FILES="$SANDBOX/version-mentions.txt"
grep -rlF -- "$RS_VERSION" "$REPO_ROOT" --exclude-dir=.git \
    --include=*.md --include=*.sh --include=*.json 2>/dev/null \
  | grep -v '/\.git/' | grep -v 'CHANGELOG\.md$' | grep -v 'plugin\.json$' > "$RS_VER_FILES" || true
assert_eq "the version is not hard-coded outside plugin.json" \
  "$(cat "$RS_VER_FILES" | tr '\n' ' ')" ""

# The CHANGELOG must not carry a hard-coded assertion total. The previous draft
# did, and both numbers were wrong -- in the very paragraph announcing the
# assertions added to stop that. A count in release prose describes the moment
# it was typed; the suite prints its own on every run, which is the only place
# it can be right. This is the plugin's own pitfall, enforced.
RS_CL_TOP="$SANDBOX/changelog-top.txt"
awk 'NR>1 && /^## \[/{n++} n==1' "$RS_CHANGELOG" > "$RS_CL_TOP"
if [ -s "$RS_CL_TOP" ]; then
  ok "the CHANGELOG's top entry extracted non-empty"
else
  nope "the CHANGELOG's top entry extracted non-empty" "content" "(empty)"
fi
assert_eq "the CHANGELOG's top entry states no hard-coded suite total" \
  "$(grep -cE '[0-9]+ (assertions|passed)' "$RS_CL_TOP" || true)" "0"
assert_has "the CHANGELOG says why it carries no totals" "$RS_CHANGELOG" \
    "Deliberately no totals here"

# --- install.sh ships every root document ---------------------------------
RS_INSTALL_MISSING=""
for _f in README.md AGENTS.md SECURITY.md LICENSE CHANGELOG.md; do
  grep -qF -- "\$SRC_DIR/$_f" "$REPO_ROOT/install.sh" || RS_INSTALL_MISSING="$RS_INSTALL_MISSING [$_f]"
done
assert_eq "install.sh copies every root document" "$RS_INSTALL_MISSING" ""

# A security document nobody is pointed at is a document nobody reads.
assert_has "the README points at SECURITY.md" "$RS_README" "[\`SECURITY.md\`](SECURITY.md)"
assert_has "the README states the trust model in its own words" "$RS_README" \
    "runs them verbatim with your privileges"

# --- The no-network contract survived the whole release -------------------
# Scan the SHIPPED scripts only. The markdown legitimately discusses what the
# plugin does not do, and a whole-tree grep would fire on every prohibition.
RS_NET="$(grep -nE '(^|[^a-zA-Z_-])(curl|wget|nc)[[:space:]]' \
  "$REPO_ROOT"/install.sh "$REPO_ROOT"/hooks/*.sh "$REPO_ROOT"/hooks/*.ps1 2>/dev/null \
  | grep -v 'test-stride-lite-hook' || true)"
assert_eq "no shipped script makes a network call" "$RS_NET" ""

echo ""
echo "the dedicated hook test suites"

# ---------------------------------------------------------------------------
# These assert that the suites EXIST, are wired, and do not overlap this file.
# They deliberately do not re-run them: this suite covers the hook script's
# surface (routing, exit codes, env injection through real subprocess runs) and
# the dedicated suites cover each function's own edge cases. Two copies of one
# assertion rot in opposite directions, which is what AC7 is guarding against.
# ---------------------------------------------------------------------------
HS_SH="$REPO_ROOT/hooks/test-stride-lite-hook.sh"
HS_PS1="$REPO_ROOT/hooks/test-stride-lite-hook.ps1"
for _p in "$HS_SH" "$HS_PS1"; do
  if [ -s "$_p" ]; then
    ok "$(basename "$_p") exists and is non-empty"
  else
    nope "$(basename "$_p") exists and is non-empty" "a suite file" "missing or empty"
  fi
done
assert_eq "the bash hook suite parses" "$(bash -n "$HS_SH" 2>&1 | grep -c .)" "0"
# Both must be executable, or the README's documented invocation is the only way
# to run them and a `./hooks/test-...` fails confusingly.
for _p in "$HS_SH" "$HS_PS1"; do
  [ -x "$_p" ] && ok "$(basename "$_p") is executable" \
                || nope "$(basename "$_p") is executable" "mode +x" "not executable"
done

# The division of labour has to be stated somewhere a reader will find it, or
# the next person duplicates a case in whichever file they opened first.
assert_has "the bash suite states why it does not repeat smoke.sh" "$HS_SH" \
    "be a byte-for-byte duplicate, and two copies of one assertion rot"
assert_has "the PowerShell suite states why it cannot run end to end" "$HS_PS1" \
    "an OS-level pipe (defect D215)"
# The split is deliberate and asymmetric, so it has to be legible from either
# file. Without the map, the next reader adds a case to whichever they opened.
assert_has "the bash suite maps every subject to the file that owns it" "$HS_SH" \
    "WHERE EACH SUBJECT LIVES"
assert_has "the bash suite says why the smoke cases were not moved" "$HS_SH" \
    "would replace a stronger metacharacter case"
# D218 is FIXED: both suites now assert the behaviour rather than recording a
# divergence, so the check is that the fixed case is asserted -- and that no
# suite still carries a skip naming it, which would mean the fix regressed or
# the skip was left behind.
assert_has "the bash suite asserts the multi-word command parity D218 blocked" "$HS_SH" \
    "parity: the .ps1 executor runs a multi-word command too"
assert_eq "no suite still skips for D218" \
  "$( { grep -hE -A1 '^[[:space:]]*(skip|Write-Skipped)\b' "$HS_SH" "$HS_PS1" 2>/dev/null || true; } \
      | grep -c 'D218' || true)" "0"
# D215 is still open, and its skip must stay named rather than quietly dropped.
assert_has "the PowerShell suite still records the open D215 divergence" "$HS_PS1" "D215"
# The confinement claim has to be checkable from a path containing a space, and
# setting TMPDIR does not achieve that: BSD `mktemp -d` with no template ignores
# it, so a "green under a spaced TMPDIR" run proves nothing on macOS.
assert_has "the bash suite can be pointed at a sandbox base for the spaced-path check" "$HS_SH" \
    "STRIDE_LITE_TEST_SANDBOX_BASE"
assert_has "the suite says why TMPDIR alone would not prove confinement" "$HS_SH" \
    "ignores TMPDIR, so setting TMPDIR alone silently proves nothing"
# The D218 fixture must not interpolate a path into a shell redirect -- that is
# how it escaped the sandbox the first time.
assert_eq "no fixture interpolates a sandbox path into a redirect" \
  "$(grep -c 'echo ran > %s' "$HS_SH")" "0"

# The non-duplication claim, checked rather than asserted in prose: this file
# must not reach into run_stride_lite_section's internals, and the dedicated
# suite must not re-drive the routing table this file owns.
assert_eq "smoke.sh does not source the hook script" \
  "$(grep -cE '^[[:space:]]*(\.|source) .*stride-lite-hook\.sh' "$0")" "0"
HS_SH_FLAT="$SANDBOX/hook-suite-flat.txt"
tr '\n' ' ' < "$HS_SH" > "$HS_SH_FLAT"
if [ -s "$HS_SH_FLAT" ]; then
  ok "the flattened hook-suite copy extracted non-empty"
else
  nope "the flattened hook-suite copy extracted non-empty" "content" "(empty)"
fi
assert_eq "the dedicated suite does not re-assert the routing table" \
  "$(grep -oE 'subagent_type.{0,200}(before_task|after_task)|goal\.md.{0,200}Completion Summary' "$HS_SH_FLAT" | grep -c . || true)" "0"
# ...and the negative-payload shapes stay smoke.sh's too.
assert_eq "the dedicated suite does not re-assert the non-matching payloads" \
  "$(grep -cE 'task-enricher|general-purpose' "$HS_SH")" "0"

# The README must document both, or a suite nobody knows to run is a suite that
# does not run.
assert_has "the README documents the bash suite" "$XT_README" \
    "bash hooks/test-stride-lite-hook.sh"
assert_has "the README documents the PowerShell suite" "$XT_README" \
    "pwsh hooks/test-stride-lite-hook.ps1"
assert_has "the README explains the division of labour" "$XT_README" \
    "Neither re-asserts the other's cases"
# A silent skip is indistinguishable from a pass, which is the whole reason the
# suites report one with a reason.
assert_has "the README says an absent PowerShell reports a skip" "$XT_README" \
    "SKIP with a reason"

# install.sh copies hooks/ wholesale, so without an explicit removal the suites
# ship into every installed plugin as dead weight.
assert_has "install.sh does not ship the test suites" "$REPO_ROOT/install.sh" \
    "rm -f \"\$TARGET_DIR/hooks\"/test-stride-lite-hook."

echo ""
echo "anti-rationalization scaffolding"

# ---------------------------------------------------------------------------
# Every assertion here is SLICE-ANCHORED to one section of one skill file. The
# forbidden-surface check in particular MUST see only table rows: the SKILL.md
# prose and AGENTS.md legitimately discuss machinery stride-lite does NOT have
# ("its after_doing and before_review do not exist here"), so a whole-file grep
# would fire on the very sentences that get the distinction right.
# ---------------------------------------------------------------------------
RAT_WF="$REPO_ROOT/skills/stride-lite-workflow/SKILL.md"
RAT_CG="$REPO_ROOT/skills/stride-lite-create-goal/SKILL.md"
RAT_CT="$REPO_ROOT/skills/stride-lite-create-task/SKILL.md"
RAT_IN="$REPO_ROOT/skills/stride-lite-init/SKILL.md"

# Case-insensitive on the heading, matching this repo's own parsing idiom, so
# the exact capitalisation never becomes load-bearing.
_rat_slice() {  # $1 = file, $2 = lowercased heading prefix
  awk -v want="$2" 'tolower($0) ~ ("^" want) { f=1; next } f && /^## / { exit } f' "$1"
}
RAT_EMPTY=""
for _pair in "wf:$RAT_WF" "cg:$RAT_CG" "ct:$RAT_CT" "in:$RAT_IN"; do
  _k="${_pair%%:*}"; _f="${_pair#*:}"
  _rat_slice "$_f" '## rationalization table' > "$SANDBOX/rat-$_k.txt"
  _rat_slice "$_f" '## red flags' > "$SANDBOX/red-$_k.txt"
  [ -s "$SANDBOX/rat-$_k.txt" ] || RAT_EMPTY="$RAT_EMPTY [rat-$_k]"
  [ -s "$SANDBOX/red-$_k.txt" ] || RAT_EMPTY="$RAT_EMPTY [red-$_k]"
done
# Guard the guards FIRST. A slice that came back empty makes every negative
# below a free pass -- the exact vacuity this suite keeps having to fix.
assert_eq "all eight scaffolding slices extracted non-empty" "$RAT_EMPTY" ""
# And no slice may run past its own section into the next one.
RAT_OVERRUN=0
for _k in wf cg ct in; do
  RAT_OVERRUN=$(( RAT_OVERRUN + $(grep -c '^## ' "$SANDBOX/rat-$_k.txt") \
                              + $(grep -c '^## ' "$SANDBOX/red-$_k.txt") ))
done
assert_eq "no scaffolding slice swallows the next section" "$RAT_OVERRUN" "0"

# --- The table is a real three-column table, not a stub -------------------
_rat_rows() {  # $1 = slice file -> data rows only
  awk '/^\| *Excuse *\| *Reality *\| *Consequence *\|/ { f=1; next }
       f && /^\|[-: |]+\|$/ { next }
       f && /^\|/           { print; next }
       f                    { exit }' "$1"
}
for _k in wf cg ct in; do
  _rat_rows "$SANDBOX/rat-$_k.txt" > "$SANDBOX/rows-$_k.txt"
done
cat "$SANDBOX/rows-wf.txt" "$SANDBOX/rows-cg.txt" \
    "$SANDBOX/rows-ct.txt" "$SANDBOX/rows-in.txt" > "$SANDBOX/rows-all.txt"
if [ -s "$SANDBOX/rows-all.txt" ]; then
  ok "table rows extracted non-empty across all four skills"
else
  nope "table rows extracted non-empty across all four skills" "rows" "(none)"
fi

RAT_HDR=""
for _pair in "wf:$RAT_WF" "cg:$RAT_CG" "ct:$RAT_CT" "in:$RAT_IN"; do
  _k="${_pair%%:*}"; _f="${_pair#*:}"
  [ "$(grep -c '^| Excuse | Reality | Consequence |$' "$_f")" = "1" ] \
    || RAT_HDR="$RAT_HDR [$_k]"
done
assert_eq "each skill carries exactly one three-column table header" "$RAT_HDR" ""

# Minimum row counts, so a table cannot be reduced to a token stub.
RAT_COUNTS=""
for _spec in "wf:10" "cg:6" "ct:6" "in:5"; do
  _k="${_spec%%:*}"; _min="${_spec#*:}"
  _n=$(grep -c . "$SANDBOX/rows-$_k.txt")
  [ "$_n" -ge "$_min" ] || RAT_COUNTS="$RAT_COUNTS [$_k=$_n<$_min]"
done
assert_eq "every rationalization table meets its minimum row count" "$RAT_COUNTS" ""
# ...and uniqueness, which is what makes the count non-gameable by duplication.
RAT_DUPES=""
for _k in wf cg ct in; do
  _d=$(awk -F'|' '{gsub(/^ +| +$/,"",$2); print $2}' "$SANDBOX/rows-$_k.txt" | sort | uniq -d | grep -c .)
  [ "$_d" = "0" ] || RAT_DUPES="$RAT_DUPES [$_k]"
done
assert_eq "no rationalization table pads its count with duplicate excuses" "$RAT_DUPES" ""

# Structural shape: three non-empty cells per row.
RAT_SHAPE=$(awk -F'|' 'NF != 5 { n++ } END { print n+0 }' "$SANDBOX/rows-all.txt")
assert_eq "every row has exactly three columns" "$RAT_SHAPE" "0"
RAT_BLANK=$(awk -F'|' '{ for (i=2;i<=4;i++) { c=$i; gsub(/^ +| +$/,"",c); if (c=="") { n++; break } } } END { print n+0 }' "$SANDBOX/rows-all.txt")
assert_eq "no row ships an empty cell" "$RAT_BLANK" "0"

# --- Every Consequence is CONCRETE (AC3) ----------------------------------
awk -F'|' '{ c=$4; gsub(/^ +| +$/,"",c); print c }' "$SANDBOX/rows-all.txt" > "$SANDBOX/conseq.txt"
if [ -s "$SANDBOX/conseq.txt" ]; then
  ok "consequence cells extracted non-empty"
else
  nope "consequence cells extracted non-empty" "cells" "(none)"
fi
# A length floor alone is gameable by padding, and a banned-word list alone is
# necessary but not sufficient -- "The run stops." contains no banned word and
# is entirely vague. Three checks together give a real floor.
RAT_SHORT=$(awk 'length($0) < 40 { n++ } END { print n+0 }' "$SANDBOX/conseq.txt")
assert_eq "no consequence is a one-liner" "$RAT_SHORT" "0"
# Hedging modals are the strongest machine-detectable vagueness signal, and
# unlike banning "worse" or "quality" they do not collide with this repo's own
# existing prose. The guard is deliberately over-strict: it also fires on a
# relative clause ("the user who could fix it"), and the right response to that
# is to reword the cell rather than to carve an exemption -- an exemption is a
# hole, and "can" costs one character.
assert_eq "no consequence hedges" \
  "$(grep -ciE '\b(may|might|could|possibly|potentially)\b|can lead to|risk of|quality suffers|technical debt|harder to maintain' "$SANDBOX/conseq.txt")" "0"
# The load-bearing one: a consequence that names no surface in this system is
# not a consequence. Every cell must cite a backticked span or a Step number.
assert_eq "every consequence names a concrete surface" \
  "$(grep -cvE '`[^`]+`|Step [0-9]' "$SANDBOX/conseq.txt")" "0"

# --- No row cites a surface stride-lite does not have (AC4) ---------------
# Scoped to extracted ROWS. The underscore form `review_queue` appears nowhere
# here, but the hyphenated "review-queue-scored" legitimately does in the create
# skills -- so ban the underscore form only, never a loose review.queue match.
RAT_FORBIDDEN=""
for _bad in 'POST /api' '/api/tasks' 'root key' 'review_queue' 'needs_review' \
            'created_by_agent' 'empty pill' 'before_doing' 'after_doing' 'before_review'; do
  grep -qF -- "$_bad" "$SANDBOX/rows-all.txt" && RAT_FORBIDDEN="$RAT_FORBIDDEN [$_bad]"
done
grep -qE '[0-9]+%' "$SANDBOX/rows-all.txt" && RAT_FORBIDDEN="$RAT_FORBIDDEN [pct]"
assert_eq "no table row cites a surface stride-lite lacks" "$RAT_FORBIDDEN" ""

# --- The two security-bearing rows (AC6) ----------------------------------
# Assert EXACTLY ONE row owns each rule, and that the supporting literals sit in
# that SAME row -- otherwise a needle can be satisfied by a different row and
# the rule can drift apart across two half-rows.
RAT_SEC_A=$(grep -F 'authorized-and-non-production affirmative' "$SANDBOX/rows-wf.txt")
assert_eq "exactly one workflow row owns the affirmative rule" \
  "$(printf '%s\n' "$RAT_SEC_A" | grep -c .)" "1"
RAT_SEC_A_MISS=""
for _n in "never supply it on the user's behalf" "exactly one source" "localhost"; do
  case "$RAT_SEC_A" in *"$_n"*) ;; *) RAT_SEC_A_MISS="$RAT_SEC_A_MISS [$_n]" ;; esac
done
assert_eq "the affirmative row states its rule, its source and its lure" "$RAT_SEC_A_MISS" ""

# A row that claims a guard catches a failure it structurally cannot is worse
# than a vague row -- it teaches the reader to rely on something that is not
# there. Step 0's `test -f` stats the path it just wrote, so it proves the write
# landed somewhere, never that it landed where the hook reads.
assert_has "the marker-root row does not claim a guard it does not have" "$SANDBOX/rows-wf.txt" \
    "Nothing catches this"
assert_eq "no workflow row credits test -f with catching a wrong-root marker" \
  "$(grep -c 'test -f. exists to turn exactly this' "$SANDBOX/rows-wf.txt")" "0"
# The marker row's consequence must name a downstream outcome, not restate that
# the marker is forgeable -- which its own Reality column already says.
assert_has "the marker row names an outcome rather than restating its reality" "$SANDBOX/rows-wf.txt" \
    "with no workflow running and nothing recorded"

# Security consideration 2: a future edit could weaken a control by softening a
# row, which looks like a copy-edit. AGENTS.md must say the safety rows are not
# editorial, or the only thing protecting them is this file.
assert_has "AGENTS.md marks the safety rows as controls, not prose" "$XT_AGENTS" \
    "are not editorial"
assert_has "AGENTS.md names both safety rows" "$XT_AGENTS" \
    "never supplied on the user's behalf"
assert_has "AGENTS.md ties a reworded hard rule to its table row" "$XT_AGENTS" \
    "must be revisited in the same commit"

RAT_SEC_B=$(grep -F 'never dispositioned as mitigated' "$SANDBOX/rows-wf.txt")
assert_eq "exactly one workflow row owns the fail-closed rule" \
  "$(printf '%s\n' "$RAT_SEC_B" | grep -c .)" "1"
RAT_SEC_B_MISS=""
for _n in "unmitigated" "Fail-closed"; do
  case "$RAT_SEC_B" in *"$_n"*) ;; *) RAT_SEC_B_MISS="$RAT_SEC_B_MISS [$_n]" ;; esac
done
assert_eq "the fail-closed row names the disposition it forces" "$RAT_SEC_B_MISS" ""

# --- AGENTS.md's hard rules are the source, and must not drift silently ---
# Set equality on the rule set, not a count: a COUNT catches an addition but not
# a rewording, and a reworded rule is exactly the case where somebody must
# decide whether a table row needs to change with it.
RAT_AGENTS_RULES=$(awk '/^## Hard rules for agents working on this codebase$/{f=1;next} f&&/^## /{exit} f' "$REPO_ROOT/AGENTS.md" \
  | sed -n 's/^- \*\*\([^*]*\)\*\*.*/\1/p' | sed "s/[\`.']/ /g" | sed 's/  */ /g; s/ $//' | sort)
if [ -n "$RAT_AGENTS_RULES" ]; then
  ok "the AGENTS.md hard-rule set extracted non-empty"
else
  nope "the AGENTS.md hard-rule set extracted non-empty" "rules" "(none)"
fi
# SET EQUALITY, not a count. A count catches an added rule but not a REWORDED
# one -- and a rewording is exactly the case where somebody has to decide
# whether the table row that maps to it still says the right thing.
RAT_RULES_EXPECTED='Dispatching another plugin s agent is not a network call, and it is not an exception to the no-network rule
Never add Stride API calls
Never change the default paths
Never diverge the task markdown template
Never give a file-mutating agent Bash
Never list more than 8 child tasks in a goal
Never make either exploratory step able to fail a task
Never raise the plugin version
Never write to stride/ from stride-lite, and never treat the activation marker as authorization
Step 6c may loop, but it still never adds a cap
The safety rows in a ## Rationalization Table are not editorial'
assert_eq "the hard-rule set is exactly the one this stage maps" \
  "$RAT_AGENTS_RULES" "$RAT_RULES_EXPECTED"
# Each mapped rule must have a needle present somewhere in the four tables.
# Two rules are EXEMPT and say why: they govern authoring the plugin, so no
# agent running one of these four skills can reach them, and a row about agent
# frontmatter grants would be exactly the generic noise this task exists to avoid.
RAT_RULE_MISS=""
for _spec in 'no network' '/PENDING/' 'identical task markdown' 'not an authorization' \
             'opens no socket' 'clean skip' 'max_review_iterations' '1 to 8'; do
  grep -qF -- "$_spec" "$SANDBOX/rows-all.txt" || RAT_RULE_MISS="$RAT_RULE_MISS [$_spec]"
done
# EXEMPT: "Never give a file-mutating agent Bash", "Never raise the plugin
# version" and "The safety rows ... are not editorial" -- codebase-authoring
# rules no skill USER can violate. The last one governs editing the tables
# themselves, so a row about it inside a table would be circular.
assert_eq "every non-exempt hard rule appears as a table row" "$RAT_RULE_MISS" ""

# --- Red flags shape, in stride's canonical form --------------------------
RAT_RED=""
for _k in wf cg ct in; do
  _n=$(grep -c '^- ' "$SANDBOX/red-$_k.txt")
  [ "$_n" -ge 5 ] || RAT_RED="$RAT_RED [$_k-bullets=$_n]"
  # Every bullet quotes a first-person rationalization.
  _bad=$(grep '^- ' "$SANDBOX/red-$_k.txt" | grep -cv '"')
  [ "$_bad" = "0" ] || RAT_RED="$RAT_RED [$_k-unquoted=$_bad]"
  # Closes with the canonical line, and that line is NOT itself a bullet.
  [ "$(grep -c '^\*\*All of these mean' "$SANDBOX/red-$_k.txt")" = "1" ] \
    || RAT_RED="$RAT_RED [$_k-no-closer]"
  [ "$(grep -c '^- \*\*All of these mean' "$SANDBOX/red-$_k.txt")" = "0" ] \
    || RAT_RED="$RAT_RED [$_k-closer-is-bullet]"
done
assert_eq "every Red flags section has the canonical shape" "$RAT_RED" ""

# --- The Quick reference card (workflow only) -----------------------------
RAT_CARD="$SANDBOX/card.txt"
_rat_slice "$RAT_WF" '## quick reference card' > "$RAT_CARD"
if [ -s "$RAT_CARD" ]; then
  ok "the Quick reference card slice extracted non-empty"
else
  nope "the Quick reference card slice extracted non-empty" "content" "(empty)"
fi
# It belongs to the workflow skill alone: the other three already open with a
# four-line pipeline diagram, and a card there would be that block reprinted --
# which is the duplication this task's own pitfall forbids.
RAT_CARD_ELSEWHERE=""
for _pair in "cg:$RAT_CG" "ct:$RAT_CT" "in:$RAT_IN"; do
  grep -qi '^## quick reference card' "${_pair#*:}" && RAT_CARD_ELSEWHERE="$RAT_CARD_ELSEWHERE [${_pair%%:*}]"
done
assert_eq "the card lives in the workflow skill only" "$RAT_CARD_ELSEWHERE" ""
RAT_CARD_BODY="$SANDBOX/card-body.txt"
awk '/^```$/{f=!f;next} f' "$RAT_CARD" > "$RAT_CARD_BODY"
RAT_CARD_LINES=$(grep -c . "$RAT_CARD_BODY")
if [ "$RAT_CARD_LINES" -ge 20 ] && [ "$RAT_CARD_LINES" -le 55 ]; then
  ok "the card is an index, not a second copy of the loop"
else
  nope "the card is an index, not a second copy of the loop" "20-55 non-blank lines" "$RAT_CARD_LINES"
fi
# It indexes the loop by GATING, a dimension the loop's own structure cannot
# express -- so all three panes must be present, and no step heading may be
# copied in.
RAT_CARD_MISS=""
for _pane in "WHICH STEPS RUN" "WHAT STOPS THE DRIVE" "WHAT IS A CLEAN SKIP"; do
  grep -qF -- "$_pane" "$RAT_CARD_BODY" || RAT_CARD_MISS="$RAT_CARD_MISS [$_pane]"
done
assert_eq "the card carries all three panes" "$RAT_CARD_MISS" ""
assert_eq "the card copies no step heading from the loop" \
  "$(grep -c '^### Step' "$RAT_CARD_BODY")" "0"
# Checked against a vocabulary that is ITSELF pinned at ten elsewhere in this
# suite, so an eleventh step fails the card rather than quietly leaving the
# index incomplete.
RAT_CARD_STEPS=""
while IFS= read -r _name; do
  [ -n "$_name" ] || continue
  grep -qF -- "$_name" "$RAT_CARD_BODY" || RAT_CARD_STEPS="$RAT_CARD_STEPS [$_name]"
done <<EOF_CARDNAMES
$TELEM_NAMES
EOF_CARDNAMES
assert_eq "the card indexes every telemetry step name" "$RAT_CARD_STEPS" ""

# --- Placement guard: nothing new may enter the two parsed fences ---------
# create-goal's taskN.md template fence is counted at exactly 14 sections and
# cascades into the enricher partition; init's canonical template is byte-diffed.
RAT_TAIL=""
for _pair in "cg:$RAT_CG" "ct:$RAT_CT" "in:$RAT_IN"; do
  _k="${_pair%%:*}"
  _t=$(grep '^## ' "${_pair#*:}" | tail -2 | tr '\n' '|')
  [ "$_t" = "## Red flags — STOP|## Rationalization Table|" ] || RAT_TAIL="$RAT_TAIL [$_k:$_t]"
done
assert_eq "the new sections are appended at EOF, clear of both parsed fences" "$RAT_TAIL" ""

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
  echo "  SKIP  .ps1 end-to-end via hooks/stride-lite-hook.ps1: no pwsh/powershell on PATH"
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

  # --- .ps1 END TO END, as a real subprocess (D215) ---------------------
  #
  # This was skipped because the .ps1 read stdin with `@($input)`, which is
  # populated only for a PowerShell-internal pipeline -- for the OS-level pipe
  # the harness actually uses it was empty, so the script hit its own
  # empty-payload guard and exited 0 without doing anything. The documented
  # hook auto-fire had never worked on native Windows, and because it exits 0
  # nothing reported it.
  #
  # Now that stdin reaches it, drive the WHOLE script rather than its extracted
  # functions: that is the only way to cover parameter binding, the stdin read
  # and the routing together, which is exactly where the defect lived.
  E2E_DIR="$PS_PARITY_DIR/e2e"
  mkdir -p "$E2E_DIR/g" "$E2E_DIR/.stride-lite"
  printf '# The E2E Goal\n'  > "$E2E_DIR/g/goal.md"
  printf '# The E2E Task\n'  > "$E2E_DIR/g/task1.md"
  printf '## before_task\n\n```bash\necho "BT:$HOOK_NAME:$TASK_TITLE:$GOAL_TITLE"\n```\n\n## after_task\n\n```bash\necho "AT:$HOOK_NAME"\n```\n\n## after_goal\n\n```bash\necho "AG:$HOOK_NAME"\n```\n' \
    > "$E2E_DIR/.stride_lite.md"
  printf '{"session_id":"t","started_at":"%s","pid":1}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$E2E_DIR/.stride-lite/.orchestrator_active"

  _ps_e2e() {  # $1 = phase, $2 = payload -> $PS_E2E_OUT / $PS_E2E_ERR / $PS_E2E_RC
    printf '%s' "$2" | CLAUDE_PROJECT_DIR="$E2E_DIR" "$PS_BIN" -NoProfile \
      -File "$REPO_ROOT/hooks/stride-lite-hook.ps1" "$1" \
      > "$E2E_DIR/.out" 2> "$E2E_DIR/.err"
    PS_E2E_RC=$?
    PS_E2E_OUT=$(cat "$E2E_DIR/.out")
    PS_E2E_ERR=$(cat "$E2E_DIR/.err")
  }

  # Routing condition 1 of 3 — and the payload the defect made invisible.
  _ps_e2e pre '{"tool_name":"Agent","tool_input":{"subagent_type":"stride-lite:task-explorer","prompt":"g/task1.md"}}'
  assert_eq ".ps1 e2e: the explorer dispatch exits 0" "$PS_E2E_RC" "0"
  assert_has ".ps1 e2e: the explorer dispatch runs before_task" "$E2E_DIR/.out" '"hook":"before_task"'
  # The derived env block reached the command, which is the half the extracted
  # functions could never prove end to end.
  assert_has ".ps1 e2e: the derived env block reaches the command" "$E2E_DIR/.err" "BT:before_task:The E2E Task:The E2E Goal"
  # The binding error the defect emitted must be gone, not merely tolerated.
  assert_eq ".ps1 e2e: no parameter-binding error on stderr" \
    "$(printf '%s' "$PS_E2E_ERR" | grep -c 'cannot be bound' || true)" "0"

  # Routing condition 2 of 3.
  _ps_e2e pre '{"tool_name":"Agent","tool_input":{"subagent_type":"stride-lite:task-reviewer","prompt":"g/task1.md"}}'
  assert_has ".ps1 e2e: the reviewer dispatch runs after_task" "$E2E_DIR/.out" '"hook":"after_task"'

  # Routing condition 3 of 3 — the PostToolUse goal.md write.
  _ps_e2e post '{"tool_name":"Write","tool_input":{"file_path":"g/goal.md","content":"## Completion Summary\n"}}'
  assert_has ".ps1 e2e: the goal.md write runs after_goal" "$E2E_DIR/.out" '"hook":"after_goal"'

  # A non-matching payload still fires nothing, so the routing above is
  # selective rather than the script running on anything it is handed.
  _ps_e2e pre '{"tool_name":"Agent","tool_input":{"subagent_type":"general-purpose","prompt":"x"}}'
  assert_eq ".ps1 e2e: an unrelated dispatch fires nothing" "$PS_E2E_OUT" ""
  # And an empty payload is still the silent no-op the contract promises.
  _ps_e2e pre ''
  assert_eq ".ps1 e2e: an empty payload still exits 0" "$PS_E2E_RC" "0"
  assert_eq ".ps1 e2e: an empty payload still emits nothing" "$PS_E2E_OUT" ""
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
