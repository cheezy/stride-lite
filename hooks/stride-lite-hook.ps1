param(
    [Parameter(Position = 0)]
    [string]$Phase = ''
)

# stride-lite-hook.ps1 — Bridges Claude Code hooks to stride-lite .stride_lite.md hook execution.
#
# PowerShell companion to stride-lite-hook.sh for Windows compatibility.
# Called by Claude Code's PreToolUse/PostToolUse hooks (configured in hooks.json).
# Receives the hook JSON on stdin, determines whether the tool call is one of the
# three stride-lite trigger conditions, and if so executes the corresponding
# `## before_task` / `## after_task` / `## after_goal` section from .stride_lite.md.
#
# Trigger conditions (identical to stride-lite-hook.sh):
#   pre  + Agent + subagent_type == "stride-lite:task-explorer" → before_task  (blocking)
#   pre  + Agent + subagent_type == "stride-lite:task-reviewer" → after_task   (blocking)
#   post + (Edit|Write) + file_path ~ */goal.md + body contains
#                                   "## Completion Summary"     → after_goal  (advisory)
#
# Usage: echo '<hook-json>' | pwsh stride-lite-hook.ps1 <pre|post>
#
# Exit codes:
#   0 — success, no-op, or non-trigger
#   2 — blocking PreToolUse failure (only meaningful for pre + before_task/after_task)
#
# Sections run only while the stride-lite-workflow orchestrator is driving a goal,
# which it signals by writing .stride-lite/.orchestrator_active. Without a fresh
# marker this script runs nothing and exits 0. STRIDE_LITE_ALLOW_DIRECT=1 bypasses.
#
# Cross-platform parity contract: this script and stride-lite-hook.sh MUST detect
# the same three trigger conditions, apply the same activation-marker gate and
# freshness window, produce equivalent single-line JSON results for the same
# input, export the same environment key set under the same empty-on-underivable
# rule, and apply the same exit-code contract.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectDir = if ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR } else { '.' }
$StrideLiteMd = Join-Path $ProjectDir '.stride_lite.md'

if (-not $Phase) { exit 0 }
if (-not (Test-Path $StrideLiteMd)) { exit 0 }

# Read Claude Code hook input from stdin
$InputJson = @($input) -join "`n"
if (-not $InputJson) { exit 0 }

# --- Pure JSON parsing via built-in ConvertFrom-Json (no module installs) ---
$ToolName = ''
$SubagentType = ''
$FilePath = ''
$Prompt = ''
try {
    $parsed = $InputJson | ConvertFrom-Json
    if ($parsed.PSObject.Properties.Name -contains 'tool_name') {
        $ToolName = [string]$parsed.tool_name
    }
    if ($parsed.PSObject.Properties.Name -contains 'tool_input' -and $parsed.tool_input) {
        $ti = $parsed.tool_input
        if ($ti.PSObject.Properties.Name -contains 'subagent_type') {
            $SubagentType = [string]$ti.subagent_type
        }
        if ($ti.PSObject.Properties.Name -contains 'file_path') {
            $FilePath = [string]$ti.file_path
        }
        if ($ti.PSObject.Properties.Name -contains 'prompt') {
            $Prompt = [string]$ti.prompt
        }
    }
} catch {
    # Malformed JSON — silent no-op.
    exit 0
}

# --- Determine which stride-lite hook to run ---
$HookName = ''
$Blocking = $false
# Source path and agent name for the derived hook environment (see
# Set-StrideLiteHookEnv). Both stay empty when the payload carries neither.
$HookSource = ''
$HookAgent = ''

switch ($Phase) {
    'pre' {
        if ($ToolName -eq 'Agent') {
            switch ($SubagentType) {
                'stride-lite:task-explorer' { $HookName = 'before_task'; $Blocking = $true }
                'stride-lite:task-reviewer' { $HookName = 'after_task';  $Blocking = $true }
            }
            if ($HookName) {
                # The dispatch prompt is the active task file's path (workflow contract).
                $HookSource = $Prompt
                $HookAgent = $SubagentType
            }
        }
    }
    'post' {
        if ($ToolName -eq 'Edit' -or $ToolName -eq 'Write') {
            if ($FilePath -match '(^|[/\\])goal\.md$') {
                # "## Completion Summary" detection — scan the entire hook JSON.
                # In goal.md edits, this string only appears in the Edit new_string
                # or Write content body, so a substring match is reliable.
                if ($InputJson -match '## Completion Summary') {
                    $HookName = 'after_goal'
                    $Blocking = $false
                    $HookSource = $FilePath
                }
            }
        }
    }
}

if (-not $HookName) { exit 0 }

# --- Orchestrator activation marker ---
# The workflow skill writes .stride-lite/.orchestrator_active when it starts a
# goal drive and clears it on every exit path. Without a fresh marker the
# trigger is a standalone dispatch — someone running stride-lite:task-explorer
# against a single task file by hand — and firing the user's before_task
# section there would run their test suite behind their back.
#
# A missing, malformed or stale marker means "run nothing, exit 0". It NEVER
# blocks: blocking a standalone dispatch would break the documented manual
# workflow, so the gate declines to act rather than declining to proceed.
#
# This is a COORDINATION mechanism, not a security boundary. Any local process
# can write the file; nothing may rely on it for authorization.
#
# Identical rules and window to stride-lite-hook.sh, per the parity contract.
# Parameterized rather than closing over script scope so test/smoke.sh's AST
# harness can drive it directly — and so the 4-hour window is pinned by the
# extracted function text instead of being re-declared, and thereby shadowed,
# by the harness. A dot-sourced function resolves free variables from the
# CALLING scope, so a script-scope $MarkerMaxAgeSeconds would make the window
# untestable: changing it here would leave every parity assertion green.
function Test-StrideLiteMarkerFresh {
    param(
        [string]$ProjectRoot = '',
        [int]$MaxAgeSeconds = 14400   # 4 hours, matching stride-lite-hook.sh
    )
    if ($env:STRIDE_LITE_ALLOW_DIRECT -eq '1') { return $true }
    try {
        if (-not $ProjectRoot) { return $false }
        $markerPath = Join-Path (Join-Path $ProjectRoot '.stride-lite') '.orchestrator_active'
        if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { return $false }

        $content = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 -ErrorAction Stop
        if (-not $content) { return $false }

        $started = ''
        try {
            $markerObj = $content | ConvertFrom-Json
            if ($markerObj.PSObject.Properties.Name -contains 'started_at') {
                $started = [string]$markerObj.started_at
            }
        } catch {
            if ($content -match '"started_at"\s*:\s*"([^"]*)"') { $started = $Matches[1] }
        }
        if (-not $started) { return $false }

        $startedDt = [datetime]::Parse(
            $started,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor
                [System.Globalization.DateTimeStyles]::AssumeUniversal)

        $age = ([datetime]::UtcNow - $startedDt).TotalSeconds
        # A negative age means a future timestamp (clock skew or a forged marker).
        return ($age -ge 0 -and $age -le $MaxAgeSeconds)
    } catch {
        return $false
    }
}

# Gate BEFORE deriving the environment: a run we are not going to perform should
# not read the user's task or goal markdown either.
if (-not (Test-StrideLiteMarkerFresh -ProjectRoot $ProjectDir)) { exit 0 }

# --- Derived hook environment (stride-lite native) ---
# stride-lite has no server, so there is no `hook.env` block to forward. The
# variable set is derived instead from the file context the hook already has:
# the Agent dispatch prompt (before_task / after_task, which by the workflow
# contract is the active task file's path) or the edited file path (after_goal).
#
# Rules, identical to stride-lite-hook.sh (the parity contract is normative):
#   - A value the script cannot derive is exported as the empty string. No
#     derivation failure aborts the hook or changes its exit code.
#   - Values are set as environment values, never spliced into the command text,
#     so a title containing $(...), backticks or semicolons reaches the command
#     as inert literal text.
#   - Keys that are not valid shell identifiers are dropped.
#   - Nothing is persisted to disk. 'Process' scope dies with this process;
#     stride-lite has no env-cache lifecycle to clean up.

$PathSep = [System.IO.Path]::DirectorySeparatorChar
# Windows paths are case-insensitive; POSIX paths are not.
$PathComparison = if ($PathSep -eq '\') {
    [System.StringComparison]::OrdinalIgnoreCase
} else {
    [System.StringComparison]::Ordinal
}

$ProjectAbs = ''
try {
    $ProjectAbs = (Resolve-Path -LiteralPath $ProjectDir -ErrorAction Stop).ProviderPath.TrimEnd($PathSep)
} catch {
    $ProjectAbs = ''
}

# Set one KEY=value pair, dropping keys that are not shell identifiers.
# Mirrors _export_env_kv: control characters stripped (a CR from a CRLF-authored
# file, a stray tab) and the value capped, which is an argv-size concern rather
# than an injection one — metacharacters are already inert because the value is
# set as an environment value and never spliced into the command text.
function Set-StrideLiteEnvKv {
    param([string]$Key, [string]$Value)
    if ($Key -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { return }
    $v = if ($null -eq $Value) { '' } else { [string]$Value }
    $v = $v -replace '\p{Cc}', ''
    if ($v.Length -gt 512) { $v = $v.Substring(0, 512) }
    [System.Environment]::SetEnvironmentVariable($Key, $v, 'Process')
}

# Resolve a path (absolute, or relative to $ProjectDir) and confirm it sits
# inside the project directory. Returns the resolved absolute path, or '' when
# the containing directory does not exist or resolves outside the project.
function Resolve-StrideLiteInProject {
    param([string]$Path)
    if (-not $Path) { return '' }
    if (-not $ProjectAbs) { return '' }

    try {
        $p = $Path
        if (-not [System.IO.Path]::IsPathRooted($p)) {
            # Join against the already-resolved project root, not $ProjectDir:
            # that defaults to '.' and the process location is not guaranteed to
            # be the project root here (Set-Location has not happened yet).
            $p = Join-Path $ProjectAbs $p
        }
        $dir = [System.IO.Path]::GetDirectoryName($p)
        $base = [System.IO.Path]::GetFileName($p)
        if (-not $dir -or -not $base) { return '' }
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return '' }

        $rp = (Resolve-Path -LiteralPath $dir -ErrorAction Stop).ProviderPath.TrimEnd($PathSep)
        if (-not $rp) { return '' }
        if (-not ($rp.Equals($ProjectAbs, $PathComparison) -or
                  $rp.StartsWith($ProjectAbs + $PathSep, $PathComparison))) {
            return ''
        }

        $full = $rp + $PathSep + $base
        # Existence and readability are part of "derivable" — a path we cannot
        # read is reported as empty, never as a phantom value.
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return '' }
        # The final component is the one element Resolve-Path never canonicalized,
        # so a linked task file could still point outside the project. Refuse
        # rather than follow it.
        $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
        if ($item.PSObject.Properties.Name -contains 'LinkType' -and $item.LinkType) { return '' }
        return $full
    } catch {
        return ''
    }
}

# First single-`#` markdown heading of a file, trailing whitespace trimmed.
# Empty when the file is missing, unreadable, or carries no such heading.
#
# Known, accepted divergence from the .sh: -Encoding UTF8 substitutes U+FFFD for
# each invalid byte, so a non-UTF-8 title is lossy here and byte-exact there.
# The parity contract covers the key set and the empty rule, not byte-level
# equality of a malformed-encoding title.
function Get-StrideLiteFirstHeading {
    param([string]$Path)
    if (-not $Path) { return '' }
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
        $lines = Get-Content -LiteralPath $Path -TotalCount 200 -Encoding UTF8 -ErrorAction Stop
        if (-not $lines) { return '' }
        foreach ($line in @($lines)) {
            if ([string]$line -match '^# (.*)$') {
                return $Matches[1].TrimEnd()
            }
        }
    } catch {
        return ''
    }
    return ''
}

# First stride-lite task/goal path token in an Agent dispatch prompt. The
# workflow contract passes the bare task file path, but a prose prompt that
# mentions the path resolves too.
#
# Matches only `goal.md` and `task<N>.md` — the two filenames stride-lite
# actually dispatches on. A looser `*.md` match would pick up a README.md
# mentioned earlier in a prose prompt and derive a title from the wrong file.
function Get-StrideLitePathFromPrompt {
    param([string]$Prompt)
    if (-not $Prompt) { return '' }
    try {
        # ConvertFrom-Json has already decoded real escapes, but a prompt may
        # still carry literal ones; treat them as the word separators they are.
        $text = $Prompt -replace '\\[nrt]', ' '
        foreach ($tok in ($text -split '\s+')) {
            $t = [string]$tok
            while ($t -and ($t -match '["`''\),.;:]$')) {
                $t = $t.Substring(0, $t.Length - 1)
            }
            while ($t -and ($t -match '^["`''\(\[<]')) {
                $t = $t.Substring(1)
            }
            if (-not $t) { continue }
            $leaf = ($t -split '[\\/]')[-1]
            if ($leaf -eq 'goal.md') { return $t }
            if ($leaf -match '^task[0-9]+\.md$') { return $t }
        }
    } catch {
        return ''
    }
    return ''
}

# Derive and set the environment for one section run. Always sets the full key
# set. Never throws.
function Set-StrideLiteHookEnv {
    param([string]$Hook, [string]$Source, [string]$Agent)

    $taskFile = ''
    $taskNumber = ''
    $taskTitle = ''
    $goalDir = ''
    $goalFile = ''
    $goalSlug = ''
    $goalTitle = ''

    try {
        $candidate = if ($Hook -eq 'after_goal') {
            $Source
        } else {
            Get-StrideLitePathFromPrompt -Prompt $Source
        }

        $resolved = Resolve-StrideLiteInProject -Path $candidate

        if ($resolved) {
            $base = [System.IO.Path]::GetFileName($resolved)
            if ($base -eq 'goal.md') {
                $goalFile = $resolved
            } else {
                $taskFile = $resolved
                if ($base -match '^task([0-9]+)\.md$') { $taskNumber = $Matches[1] }
                $taskTitle = Get-StrideLiteFirstHeading -Path $taskFile
            }

            $goalDir = [System.IO.Path]::GetDirectoryName($resolved)
            if (-not $goalDir) { $goalDir = [string]$PathSep }
            if (-not $goalFile) { $goalFile = Join-Path $goalDir 'goal.md' }

            if (Test-Path -LiteralPath $goalFile -PathType Leaf) {
                $goalSlug = [System.IO.Path]::GetFileName($goalDir)
                $goalTitle = Get-StrideLiteFirstHeading -Path $goalFile
            } else {
                # No goal.md beside the task file — this is a loose task (e.g.
                # one from /stride-lite:create-task under PENDING/tasks/), not a
                # goal member. Report absence rather than a directory name that
                # only looks like a slug.
                $goalDir = ''
                $goalFile = ''
            }
        }
    } catch {
        # Derivation failure degrades to empty values — never an error, never a
        # changed exit code. StrictMode + $ErrorActionPreference = 'Stop' would
        # otherwise turn any incidental error into a terminating one.
    }

    Set-StrideLiteEnvKv -Key 'HOOK_NAME'   -Value $Hook
    Set-StrideLiteEnvKv -Key 'TASK_FILE'   -Value $taskFile
    Set-StrideLiteEnvKv -Key 'TASK_NUMBER' -Value $taskNumber
    Set-StrideLiteEnvKv -Key 'TASK_TITLE'  -Value $taskTitle
    Set-StrideLiteEnvKv -Key 'GOAL_DIR'    -Value $goalDir
    Set-StrideLiteEnvKv -Key 'GOAL_FILE'   -Value $goalFile
    Set-StrideLiteEnvKv -Key 'GOAL_SLUG'   -Value $goalSlug
    Set-StrideLiteEnvKv -Key 'GOAL_TITLE'  -Value $goalTitle
    Set-StrideLiteEnvKv -Key 'AGENT_NAME'  -Value $Agent
}

# --- Parse and execute one .stride_lite.md hook section ---
# Returns:
#   0 — section missing OR empty fenced block OR all commands succeeded
#   2 — first command failed; structured failure JSON emitted on stdout
function Invoke-StrideLiteSection {
    param([string]$Section)

    $raw = Get-Content $StrideLiteMd -Raw -Encoding UTF8
    $raw = $raw -replace "`r`n", "`n"
    $lines = $raw -split "`n"

    $commandsText = ''
    $found = $false
    $capture = $false

    foreach ($rawLine in $lines) {
        $line = $rawLine.TrimEnd("`r")

        if ($line -match '^## (.+)$') {
            if ($found) { break }
            $heading = $Matches[1].TrimEnd()
            if ($heading -eq $Section) { $found = $true }
            continue
        }

        if ($found) {
            if ($line -match '^```bash') {
                $capture = $true
                continue
            }
            if ($line -match '^```') {
                if ($capture) { break }
                continue
            }
            if ($capture) {
                $commandsText += $line + "`n"
            }
        }
    }

    if (-not $commandsText.Trim()) {
        return 0
    }

    $cmdList = @()
    foreach ($cmd in ($commandsText -split "`n")) {
        $trimmedCmd = $cmd.TrimStart()
        if (-not $trimmedCmd) { continue }
        if ($trimmedCmd.StartsWith('#')) { continue }
        $cmdList += $trimmedCmd
    }

    if ($cmdList.Count -eq 0) {
        return 0
    }

    Set-Location $ProjectDir
    $completedCmds = @()
    $startTime = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $cmdIndex = 0
    $cmdTotal = $cmdList.Count

    foreach ($execTrimmed in $cmdList) {
        $stdoutFile = [System.IO.Path]::GetTempFileName()
        $stderrFile = [System.IO.Path]::GetTempFileName()

        try {
            # Delegate user command execution to bash so .stride_lite.md content
            # stays POSIX-portable (git-bash on Windows ships bash.exe; WSL also
            # provides one). Users who want native PowerShell can wrap their line
            # with `pwsh -c '...'` inside their bash block.
            $proc = Start-Process -FilePath 'bash' -ArgumentList '-c', $execTrimmed `
                -RedirectStandardOutput $stdoutFile `
                -RedirectStandardError $stderrFile `
                -NoNewWindow -Wait -PassThru

            if ($proc.ExitCode -eq 0) {
                $completedCmds += $execTrimmed
                if (Test-Path $stdoutFile) {
                    $stdoutText = Get-Content $stdoutFile -Raw -Encoding UTF8
                    if ($stdoutText) { [Console]::Error.Write($stdoutText) }
                }
                if (Test-Path $stderrFile) {
                    $stderrText = Get-Content $stderrFile -Raw -Encoding UTF8
                    if ($stderrText) { [Console]::Error.Write($stderrText) }
                }
            } else {
                $cmdExit = $proc.ExitCode
                $cmdStdout = ''
                $cmdStderr = ''
                if (Test-Path $stdoutFile) {
                    $allLines = @(Get-Content $stdoutFile -Encoding UTF8)
                    if ($allLines.Count -gt 50) { $allLines = $allLines[-50..-1] }
                    $cmdStdout = $allLines -join "`n"
                }
                if (Test-Path $stderrFile) {
                    $allLines = @(Get-Content $stderrFile -Encoding UTF8)
                    if ($allLines.Count -gt 50) { $allLines = $allLines[-50..-1] }
                    $cmdStderr = $allLines -join "`n"
                }
                Remove-Item -Force $stdoutFile, $stderrFile -ErrorAction SilentlyContinue

                $remainingCmds = @()
                if (($cmdIndex + 1) -lt $cmdTotal) {
                    $remainingCmds = $cmdList[($cmdIndex + 1)..($cmdTotal - 1)]
                }

                $failureResult = [ordered]@{
                    hook               = $Section
                    status             = 'failed'
                    failed_command     = $execTrimmed
                    command_index      = $cmdIndex
                    exit_code          = $cmdExit
                    stdout             = $cmdStdout
                    stderr             = $cmdStderr
                    commands_completed = @($completedCmds)
                    commands_remaining = @($remainingCmds)
                }
                # Write JSON directly to the host stdout stream to avoid
                # capturing it in the caller's `$rc = Invoke-StrideLiteSection`
                # assignment.
                [Console]::Out.WriteLine(($failureResult | ConvertTo-Json -Depth 5 -Compress))
                [Console]::Error.WriteLine("stride-lite $Section hook failed on command $($cmdIndex + 1)/$($cmdTotal): $execTrimmed")
                if ($cmdStderr) { [Console]::Error.WriteLine($cmdStderr) }

                return 2
            }
        } finally {
            Remove-Item -Force $stdoutFile, $stderrFile -ErrorAction SilentlyContinue
        }

        $cmdIndex++
    }

    $endTime = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $duration = $endTime - $startTime

    $successResult = [ordered]@{
        hook               = $Section
        status             = 'success'
        commands_completed = @($completedCmds)
        duration_seconds   = $duration
    }
    [Console]::Out.WriteLine(($successResult | ConvertTo-Json -Depth 5 -Compress))

    return 0
}

Set-StrideLiteHookEnv -Hook $HookName -Source $HookSource -Agent $HookAgent

$rc = Invoke-StrideLiteSection -Section $HookName

# PostToolUse cannot roll back the tool call — never block with exit 2 there.
# PreToolUse blocking failures propagate as exit 2 so the dispatch is aborted.
if ($Blocking -and $rc -ne 0) {
    exit $rc
}

exit 0
