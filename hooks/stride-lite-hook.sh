#!/usr/bin/env bash
# stride-lite-hook.sh — Bridges Claude Code hooks to stride-lite .stride_lite.md hook execution.
#
# Called by Claude Code's PreToolUse/PostToolUse hooks (configured in hooks.json).
# Receives the hook JSON on stdin, determines whether the tool call is one of the
# three stride-lite trigger conditions, and if so executes the corresponding
# `## before_task` / `## after_task` / `## after_goal` section from .stride_lite.md.
#
# Trigger conditions:
#   pre  + Agent + subagent_type == "stride-lite:task-explorer" → before_task  (blocking)
#   pre  + Agent + subagent_type == "stride-lite:task-reviewer" → after_task   (blocking)
#   post + (Edit|Write) + file_path ~ */goal.md + body contains
#                                   "## Completion Summary"     → after_goal  (advisory)
#
# Usage: echo '<hook-json>' | stride-lite-hook.sh <pre|post>
#
# Exit codes:
#   0 — success, no-op, or non-trigger
#   2 — blocking PreToolUse failure (only meaningful for pre + before_task/after_task)
#
# Cross-platform parity contract: this script and stride-lite-hook.ps1 MUST detect
# the same three trigger conditions, produce equivalent single-line JSON results
# for the same input, export the same environment key set under the same
# empty-on-underivable rule, and apply the same exit-code contract.

set -uo pipefail

PHASE="${1:-}"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
STRIDE_LITE_MD="$PROJECT_DIR/.stride_lite.md"

# --- Platform detection: delegate to PowerShell on native Windows ---
# Git Bash (OSTYPE=msys*) and WSL have full bash — run directly.
# Native Windows without bash (COMSPEC set, no OSTYPE) → delegate to .ps1
_delegate_to_ps1=false
if [ -z "${OSTYPE:-}" ] && [ -n "${COMSPEC:-}" ]; then
  _delegate_to_ps1=true
fi

if [ "$_delegate_to_ps1" = "true" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  PS1_SCRIPT="$SCRIPT_DIR/stride-lite-hook.ps1"
  if [ ! -f "$PS1_SCRIPT" ]; then
    echo "stride-lite-hook.sh: Windows detected but stride-lite-hook.ps1 not found at $PS1_SCRIPT" >&2
    exit 2
  fi
  if ! command -v powershell.exe > /dev/null 2>&1; then
    echo "stride-lite-hook.sh: Windows detected but powershell.exe not found in PATH" >&2
    exit 2
  fi
  exec powershell.exe -ExecutionPolicy Bypass -File "$PS1_SCRIPT" "$PHASE"
fi

# --- Pure-bash JSON value extractor (no jq dependency) ---
# Extracts the first string value for the given key. Handles whitespace between
# colon and value, but does NOT handle escaped quotes inside values — fine for
# our use (tool_name, subagent_type, file_path are all simple identifiers/paths).
# Empty on miss.
_extract_string() {
  local key="$1"
  local input="$2"
  local tmp="${input#*\"$key\"}"
  if [ "$tmp" = "$input" ]; then
    printf ''
    return
  fi
  tmp="${tmp#*:}"
  tmp="${tmp#"${tmp%%[![:space:]]*}"}"
  case "$tmp" in
    \"*)
      tmp="${tmp#\"}"
      # Stop at first unescaped quote — for our keys this is sufficient.
      printf '%s' "${tmp%%\"*}"
      ;;
    *)
      printf ''
      ;;
  esac
}

# --- JSON string escape (no jq) ---
# Escapes backslash, double quote, and common control chars. Sufficient for
# emitting command strings, exit messages, and stdout/stderr tails.
_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# --- JSON array builder from a newline-delimited list ---
# Reads stdin one line per element, emits a compact JSON array literal.
_json_array_from_lines() {
  local first=1
  local line
  printf '['
  while IFS= read -r line; do
    if [ "$first" -eq 1 ]; then
      first=0
    else
      printf ','
    fi
    printf '"%s"' "$(_json_escape "$line")"
  done
  printf ']'
}

# --- Derived hook environment (stride-lite native) ---
# stride-lite has no server, so there is no `hook.env` block to forward. The
# variable set is derived instead from the file context the hook already has:
# the Agent dispatch prompt (before_task / after_task, which by the workflow
# contract is the active task file's path) or the edited file path (after_goal).
#
# Rules, mirroring the full Stride executor's forwarding contract:
#   - A value the script cannot derive is exported as the empty string. No
#     derivation failure aborts the hook or changes its exit code, so a `set -u`
#     inside a user's command sees defined-but-empty rather than unset.
#   - Values are exported, never spliced into the command text, so a title
#     containing $(...), backticks or semicolons reaches the command as inert
#     literal text.
#   - Keys that are not valid shell identifiers are dropped.
#   - Nothing is persisted to disk. The exports live and die with this process;
#     stride-lite has no env-cache lifecycle to clean up.
#
# The key set is deliberately file-shaped, not server-shaped: there is no board,
# column or status in stride-lite, and exporting empty ones would teach a
# contract the plugin cannot honour.

_PROJECT_ABS=""

# Export one KEY=value pair, dropping keys that are not shell identifiers.
_export_env_kv() {
  local _key="$1" _value="${2-}"
  case "$_key" in
    ''|[0-9]*|*[!A-Za-z0-9_]*) return 0 ;;
  esac
  # Values are exported, never spliced, so shell metacharacters are already
  # inert and need no escaping. What still needs removing is structure:
  # control characters (a CR from a CRLF-authored file, a stray tab; a NUL is
  # dropped by `read` before we ever see it) and unbounded length, which is an
  # argv-size problem rather than an injection one.
  #
  # Deliberately [[:cntrl:]] and not [![:print:]]: under LANG=C the latter
  # would strip every byte >= 0x80 and mangle a legitimately non-ASCII title.
  # Non-UTF-8 bytes pass through untouched — they are opaque data in an env
  # value, and the child's own locale decides how to render them.
  #
  # Known, accepted divergence from the .ps1: PowerShell reads the heading with
  # Get-Content -Encoding UTF8, which substitutes U+FFFD for each invalid byte,
  # so a non-UTF-8 title is lossy on Windows and byte-exact here. The parity
  # contract covers the key set and the empty rule, not byte-level equality of
  # a malformed-encoding title.
  _value="${_value//[[:cntrl:]]/}"
  _value="${_value:0:512}"
  export "$_key=$_value"
}

# Resolve a path (absolute, or relative to PROJECT_DIR) and confirm it sits
# inside the project directory. Emits the resolved absolute path, or empty when
# the containing directory does not exist or resolves outside the project.
# `cd ... && pwd -P` canonicalizes `..` segments and symlinks without depending
# on a GNU `realpath`, which macOS does not reliably ship.
_resolve_in_project() {
  local _p="$1" _dir _base _rp
  [ -n "$_p" ] || { printf ''; return 0; }
  [ -n "$_PROJECT_ABS" ] || { printf ''; return 0; }
  # Join against the already-canonicalized project root, NOT $PROJECT_DIR:
  # that defaults to "." and the process cwd is not guaranteed to be the
  # project root here (run_stride_lite_section's `cd` has not happened yet).
  case "$_p" in /*) ;; *) _p="$_PROJECT_ABS/$_p" ;; esac
  case "$_p" in
    */*) _dir="${_p%/*}"; _base="${_p##*/}" ;;
    *)   _dir="."; _base="$_p" ;;
  esac
  [ -n "$_dir" ] || _dir="/"
  [ -n "$_base" ] || { printf ''; return 0; }
  _rp="$(cd "$_dir" 2>/dev/null && pwd -P)" || { printf ''; return 0; }
  [ -n "$_rp" ] || { printf ''; return 0; }
  case "$_rp/" in
    "$_PROJECT_ABS"/*)
      # Existence and readability are part of "derivable" — a path we cannot
      # read is reported as empty, never as a phantom value.
      { [ -f "$_rp/$_base" ] && [ -r "$_rp/$_base" ]; } || { printf ''; return 0; }
      # The final component is the one path element `pwd -P` never canonicalizes,
      # so a symlinked task file could still point outside the project. Refuse
      # rather than follow it.
      [ ! -L "$_rp/$_base" ] || { printf ''; return 0; }
      printf '%s/%s' "$_rp" "$_base"
      ;;
    *) printf '' ;;
  esac
}

# First single-`#` markdown heading of a file, trailing whitespace trimmed.
# Empty when the file is missing, unreadable, or carries no such heading.
# Read line-by-line with `read -r` only — the heading is user-authored markdown
# and must never reach a subshell that could evaluate it.
_first_heading() {
  local _f="$1" _line _n=0
  { [ -n "$_f" ] && [ -f "$_f" ] && [ -r "$_f" ]; } || { printf ''; return 0; }
  while IFS= read -r _line || [ -n "$_line" ]; do
    _n=$((_n + 1))
    [ "$_n" -gt 200 ] && break
    case "$_line" in
      '# '*)
        _line="${_line#\# }"
        _line="${_line%"${_line##*[![:space:]]}"}"
        printf '%s' "$_line"
        return 0
        ;;
    esac
  done < "$_f"
  printf ''
}

# First stride-lite task/goal path token in an Agent dispatch prompt. The
# workflow contract passes the bare task file path, but a prose prompt that
# mentions the path resolves too. `read -a` splits on whitespace without glob
# expansion (a `for tok in $text` loop would need `set -f`).
#
# Matches only `goal.md` and `task<N>.md` — the two filenames stride-lite
# actually dispatches on. A looser `*.md` match would pick up a README.md or
# CHANGELOG.md mentioned earlier in a prose prompt and derive a title from
# the wrong file.
_path_from_prompt() {
  local _prompt="$1" _tok _leaf
  local _toks=()
  [ -n "$_prompt" ] || { printf ''; return 0; }
  # _extract_string returns the raw JSON string body, so escape sequences are
  # still two literal characters. A prompt written as "…/task1.md\n\nExplore it"
  # would otherwise arrive as ONE token, "…/task1.md\n\nExplore" — the escapes
  # separate words in the source text, so treat them as separators here too.
  _prompt="${_prompt//\\n/ }"
  _prompt="${_prompt//\\r/ }"
  _prompt="${_prompt//\\t/ }"
  IFS=$' \t' read -r -a _toks <<< "$_prompt"
  [ ${#_toks[@]} -eq 0 ] && { printf ''; return 0; }
  for _tok in "${_toks[@]}"; do
    # Strip surrounding punctuation: a path cited mid-sentence as "…/task1.md,"
    # or "(…/task1.md)" or "`…/task1.md`" is still that path.
    while :; do
      case "$_tok" in
        *[\"\`\'\),.\;:]) _tok="${_tok%?}" ;;
        *) break ;;
      esac
    done
    while :; do
      case "$_tok" in
        [\"\`\'\(\[\<]*) _tok="${_tok#?}" ;;
        *) break ;;
      esac
    done
    _leaf="${_tok##*/}"
    case "$_leaf" in
      goal.md) printf '%s' "$_tok"; return 0 ;;
      task*.md)
        _leaf="${_leaf#task}"
        _leaf="${_leaf%.md}"
        case "$_leaf" in
          ''|*[!0-9]*) ;;
          *) printf '%s' "$_tok"; return 0 ;;
        esac
        ;;
    esac
  done
  printf ''
}

# Derive and export the environment for one section run.
#   $1 — hook name (before_task | after_task | after_goal)
#   $2 — source path: the Agent dispatch prompt (pre) or the edited file path
#        (post). May be empty, prose, or point at a file that does not exist.
#   $3 — agent name: the dispatching subagent_type; empty for after_goal, which
#        is triggered by a file write rather than an agent dispatch.
# Always exports the full key set. Never returns non-zero.
_derive_hook_env() {
  local _hook="$1" _source="${2-}" _agent="${3-}"
  local _task_file="" _task_number="" _task_title=""
  local _goal_dir="" _goal_file="" _goal_slug="" _goal_title=""
  local _candidate="" _resolved="" _base=""

  _PROJECT_ABS="$(cd "$PROJECT_DIR" 2>/dev/null && pwd -P)" || _PROJECT_ABS=""
  [ "$_PROJECT_ABS" = "/" ] && _PROJECT_ABS=""

  case "$_hook" in
    after_goal) _candidate="$_source" ;;
    *)          _candidate="$(_path_from_prompt "$_source")" ;;
  esac

  _resolved="$(_resolve_in_project "$_candidate")"

  if [ -n "$_resolved" ]; then
    _base="${_resolved##*/}"
    case "$_base" in
      goal.md)
        _goal_file="$_resolved"
        ;;
      *)
        _task_file="$_resolved"
        case "$_base" in
          task[0-9]*.md)
            _task_number="${_base#task}"
            _task_number="${_task_number%.md}"
            case "$_task_number" in ''|*[!0-9]*) _task_number="" ;; esac
            ;;
        esac
        _task_title="$(_first_heading "$_task_file")"
        ;;
    esac

    _goal_dir="${_resolved%/*}"
    [ -n "$_goal_dir" ] || _goal_dir="/"
    [ -n "$_goal_file" ] || _goal_file="$_goal_dir/goal.md"

    if [ -f "$_goal_file" ] && [ -r "$_goal_file" ]; then
      _goal_slug="${_goal_dir##*/}"
      _goal_title="$(_first_heading "$_goal_file")"
    else
      # No goal.md beside the task file — this is a loose task (e.g. one from
      # /stride-lite:create-task under PENDING/tasks/), not a goal member.
      # Report absence rather than a directory name that only looks like a slug.
      _goal_dir=""
      _goal_file=""
    fi
  fi

  _export_env_kv HOOK_NAME   "$_hook"
  _export_env_kv TASK_FILE   "$_task_file"
  _export_env_kv TASK_NUMBER "$_task_number"
  _export_env_kv TASK_TITLE  "$_task_title"
  _export_env_kv GOAL_DIR    "$_goal_dir"
  _export_env_kv GOAL_FILE   "$_goal_file"
  _export_env_kv GOAL_SLUG   "$_goal_slug"
  _export_env_kv GOAL_TITLE  "$_goal_title"
  _export_env_kv AGENT_NAME  "$_agent"

  return 0
}

# --- Parse and execute one .stride_lite.md hook section ---
# Mirrors stride-hook.sh:run_stride_section but reads .stride_lite.md, dispatches
# on the three stride-lite section names, and emits JSON without jq.
#
# Returns:
#   0 — section missing OR empty fenced block OR all commands succeeded
#   2 — first command failed; structured failure JSON emitted on stdout
run_stride_lite_section() {
  local _section="$1"
  local _commands=""
  local _found=0
  local _capture=0
  local _line _heading

  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in
      "## "*)
        [ "$_found" -eq 1 ] && break
        _heading="${_line#\#\# }"
        _heading="${_heading%"${_heading##*[![:space:]]}"}"
        [ "$_heading" = "$_section" ] && _found=1
        continue
        ;;
    esac
    if [ "$_found" -eq 1 ]; then
      case "$_line" in
        '```bash'*) _capture=1; continue ;;
        '```'*)     [ "$_capture" -eq 1 ] && break; continue ;;
      esac
      [ "$_capture" -eq 1 ] && _commands="${_commands}${_line}
"
    fi
  done < "$STRIDE_LITE_MD"

  if [ -z "$_commands" ]; then
    return 0
  fi

  local _cmd _trimmed
  local _cmd_list=()
  while IFS= read -r _cmd; do
    _trimmed="${_cmd#"${_cmd%%[![:space:]]*}"}"
    [ -z "$_trimmed" ] && continue
    case "$_trimmed" in \#*) continue ;; esac
    _cmd_list+=("$_trimmed")
  done <<< "$_commands"

  if [ ${#_cmd_list[@]} -eq 0 ]; then
    return 0
  fi

  cd "$PROJECT_DIR"
  local _completed_file
  _completed_file=$(mktemp)
  local _start_secs
  _start_secs=$(date +%s)
  local _cmd_index=0
  local _cmd_total=${#_cmd_list[@]}
  local _cmd_stdout_file _cmd_stderr_file _cmd_exit _cmd_stdout _cmd_stderr
  local _remaining_file _completed_json _remaining_json _end_secs _duration _i

  for _trimmed in "${_cmd_list[@]}"; do
    _cmd_stdout_file=$(mktemp)
    _cmd_stderr_file=$(mktemp)

    # Relax `set -u` and `pipefail` for the user's command so a reference to an
    # unset env var doesn't silently abort eval before the actual command runs.
    set +uo pipefail
    eval "$_trimmed" > "$_cmd_stdout_file" 2> "$_cmd_stderr_file"
    _cmd_exit=$?
    set -uo pipefail

    if [ "$_cmd_exit" -eq 0 ]; then
      echo "$_trimmed" >> "$_completed_file"
      cat "$_cmd_stdout_file" >&2
      cat "$_cmd_stderr_file" >&2
    else
      _cmd_stdout=$(tail -50 "$_cmd_stdout_file")
      _cmd_stderr=$(tail -50 "$_cmd_stderr_file")
      rm -f "$_cmd_stdout_file" "$_cmd_stderr_file"

      _remaining_file=$(mktemp)
      if [ $((_cmd_index + 1)) -lt $_cmd_total ]; then
        for ((_i = _cmd_index + 1; _i < _cmd_total; _i++)); do
          echo "${_cmd_list[$_i]}" >> "$_remaining_file"
        done
      fi

      _completed_json=$(_json_array_from_lines < "$_completed_file")
      _remaining_json=$(_json_array_from_lines < "$_remaining_file")

      printf '{"hook":"%s","status":"failed","failed_command":"%s","command_index":%d,"exit_code":%d,"stdout":"%s","stderr":"%s","commands_completed":%s,"commands_remaining":%s}\n' \
        "$(_json_escape "$_section")" \
        "$(_json_escape "$_trimmed")" \
        "$_cmd_index" \
        "$_cmd_exit" \
        "$(_json_escape "$_cmd_stdout")" \
        "$(_json_escape "$_cmd_stderr")" \
        "$_completed_json" \
        "$_remaining_json"

      echo "stride-lite $_section hook failed on command $((_cmd_index + 1))/$_cmd_total: $_trimmed" >&2
      [ -n "$_cmd_stderr" ] && echo "$_cmd_stderr" >&2
      rm -f "$_completed_file" "$_remaining_file"
      return 2
    fi

    rm -f "$_cmd_stdout_file" "$_cmd_stderr_file"
    _cmd_index=$((_cmd_index + 1))
  done

  _end_secs=$(date +%s)
  _duration=$((_end_secs - _start_secs))

  _completed_json=$(_json_array_from_lines < "$_completed_file")

  printf '{"hook":"%s","status":"success","commands_completed":%s,"duration_seconds":%d}\n' \
    "$(_json_escape "$_section")" \
    "$_completed_json" \
    "$_duration"

  rm -f "$_completed_file"
  return 0
}

# --- Main flow ---
# Early exits placed after function definitions so tests can source this script
# and invoke run_stride_lite_section in isolation.

if [ -z "$PHASE" ]; then
  return 0 2>/dev/null || exit 0
fi
if [ ! -f "$STRIDE_LITE_MD" ]; then
  return 0 2>/dev/null || exit 0
fi

INPUT=$(cat)
if [ -z "$INPUT" ]; then
  exit 0
fi

TOOL_NAME=$(_extract_string "tool_name" "$INPUT")

HOOK_NAME=""
BLOCKING=0
# Source path and agent name for the derived hook environment (see
# _derive_hook_env). Both stay empty when the payload carries neither.
HOOK_SOURCE=""
HOOK_AGENT=""

case "$PHASE" in
  pre)
    if [ "$TOOL_NAME" = "Agent" ]; then
      SUBAGENT_TYPE=$(_extract_string "subagent_type" "$INPUT")
      case "$SUBAGENT_TYPE" in
        stride-lite:task-explorer) HOOK_NAME="before_task"; BLOCKING=1 ;;
        stride-lite:task-reviewer) HOOK_NAME="after_task";  BLOCKING=1 ;;
      esac
      if [ -n "$HOOK_NAME" ]; then
        # The dispatch prompt is the active task file's path (workflow contract).
        #
        # `prompt` is the one field the extractor's "simple identifiers/paths"
        # assumption does not fully hold for: _extract_string stops at the first
        # double quote, escaped or not, so a prompt carrying an escaped quote
        # before the path truncates and every derived key degrades to empty.
        # The .ps1 uses a real JSON parser and does not truncate there. Both
        # workflow dispatch sites pass a bare path, and the .sh degrades safely,
        # so this is an accepted divergence rather than a derivation bug.
        HOOK_SOURCE=$(_extract_string "prompt" "$INPUT")
        HOOK_AGENT="$SUBAGENT_TYPE"
      fi
    fi
    ;;
  post)
    case "$TOOL_NAME" in
      Edit|Write)
        FILE_PATH=$(_extract_string "file_path" "$INPUT")
        case "$FILE_PATH" in
          */goal.md|goal.md)
            # "## Completion Summary" detection — scan the entire hook JSON.
            # In goal.md edits, this string only appears in the Edit new_string
            # or Write content body, so a substring grep is reliable.
            if printf '%s' "$INPUT" | grep -q '## Completion Summary'; then
              HOOK_NAME="after_goal"
              BLOCKING=0
              HOOK_SOURCE="$FILE_PATH"
            fi
            ;;
        esac
        ;;
    esac
    ;;
esac

if [ -z "$HOOK_NAME" ]; then
  exit 0
fi

_derive_hook_env "$HOOK_NAME" "$HOOK_SOURCE" "$HOOK_AGENT"

run_stride_lite_section "$HOOK_NAME"
RC=$?

# PostToolUse cannot roll back the tool call — never block with exit 2 there.
# PreToolUse blocking failures propagate as exit 2 so the dispatch is aborted.
if [ "$BLOCKING" -eq 1 ] && [ "$RC" -ne 0 ]; then
  exit "$RC"
fi

exit 0
