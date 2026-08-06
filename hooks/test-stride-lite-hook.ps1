#!/usr/bin/env pwsh
#
# test-stride-lite-hook.ps1 — dedicated suite for hooks/stride-lite-hook.ps1
#
# The PowerShell counterpart of test-stride-lite-hook.sh, covering the same
# cases against the .ps1 executor. Until now the .ps1 was 549 lines asserted by
# nothing except a key-set comparison and two derivation helpers driven from
# test/smoke.sh.
#
# HOW IT DRIVES THE SCRIPT, and why not end to end.
#
#   stride-lite-hook.ps1 reads its payload with `@($input)`, which is empty for
#   an OS-level pipe (defect D215). A full subprocess run is therefore not
#   available, and this suite does not pretend otherwise. It dot-sources each
#   function via AST extraction and calls it directly -- the technique
#   test/smoke.sh already uses for the derivation helpers, extended here to
#   Invoke-StrideLiteSection, which that harness explicitly excludes.
#
#   That defect blocks an end-to-end run. It does not block calling a function,
#   so the section executor is testable today and simply was not tested.
#
# Every fixture command is inert and confined to a sandbox; the suite removes
# its sandbox on every exit path.
#
# Usage: pwsh -File hooks/test-stride-lite-hook.ps1
# Exit:  0 if every assertion passed, 1 otherwise.

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$HookPs1   = Join-Path $ScriptDir 'stride-lite-hook.ps1'

$script:Pass = 0
$script:Fail = 0
$script:Skip = 0

function Write-Ok   { param([string]$Label) $script:Pass++; Write-Host "  PASS  $Label" }
function Write-Nope {
    param([string]$Label, [string]$Expected, [string]$Actual)
    $script:Fail++
    Write-Host "  FAIL  $Label"
    Write-Host "        expected: $Expected"
    Write-Host "        actual:   $Actual"
}
function Write-Skipped { param([string]$Label, [string]$Reason) $script:Skip++; Write-Host "  SKIP  $Label — $Reason" }

function Assert-Eq {
    param([string]$Label, $Actual, $Expected)
    if ("$Actual" -ceq "$Expected") { Write-Ok $Label } else { Write-Nope $Label "$Expected" "$Actual" }
}
function Assert-Has {
    param([string]$Label, [string]$Haystack, [string]$Needle)
    if ($Haystack -and $Haystack.Contains($Needle)) { Write-Ok $Label }
    else { Write-Nope $Label "contains: $Needle" $Haystack }
}
function Assert-Lacks {
    param([string]$Label, [string]$Haystack, [string]$Needle)
    # An empty haystack trivially lacks any needle, so a negative assertion
    # against one passes for a reason unrelated to its subject. Refuse it.
    if (-not $Haystack) { Write-Nope $Label 'a non-empty haystack to search' '(empty)'; return }
    if ($Haystack.Contains($Needle)) { Write-Nope $Label "must NOT contain: $Needle" $Haystack }
    else { Write-Ok $Label }
}

if (-not (Test-Path $HookPs1)) {
    Write-Host "FATAL: $HookPs1 not found"
    exit 1
}

# The .ps1's section executor shells out to bash for each command, so without
# bash on PATH the execution cases cannot run. Report that rather than failing
# them, and keep the parsing cases, which need no shell.
$HasBash = $null -ne (Get-Command bash -ErrorAction SilentlyContinue)

$Sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("stride-lite-ps-" + [System.Guid]::NewGuid().ToString('N').Substring(0,12))
New-Item -ItemType Directory -Path $Sandbox -Force | Out-Null

try {
    Write-Host "stride-lite hook script (.ps1) — dedicated suite"
    Write-Host "sandbox: $Sandbox"

    # -----------------------------------------------------------------------
    # Dot-source every function out of the executor by AST.
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "the AST-extraction affordance itself"

    $ast = [System.Management.Automation.Language.Parser]::ParseFile($HookPs1, [ref]$null, [ref]$null)
    $fns = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    foreach ($f in $fns) { . ([scriptblock]::Create($f.Extent.Text)) }

    # If extraction ever silently returns nothing, every case below would report
    # a failure with a confusing message instead of one clear one. Prove it first.
    Assert-Eq "the executor defines seven functions" $fns.Count 7
    $missing = @()
    foreach ($n in @('Test-StrideLiteMarkerFresh','Set-StrideLiteEnvKv','Resolve-StrideLiteInProject',
                     'Get-StrideLiteFirstHeading','Get-StrideLitePathFromPrompt','Set-StrideLiteHookEnv',
                     'Invoke-StrideLiteSection')) {
        if (-not (Get-Command $n -ErrorAction SilentlyContinue)) { $missing += $n }
    }
    Assert-Eq "every function this suite exercises was extracted" ($missing -join ' ') ''

    # -----------------------------------------------------------------------
    # Invoke-StrideLiteSection — the branch set test/smoke.sh excludes entirely
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "Invoke-StrideLiteSection — the no-op branches"

    function Invoke-Section {
        param([string]$FixtureDir, [string]$Section)
        # The function closes over $StrideLiteMd and $ProjectDir, and emits its
        # JSON with [Console]::Out.WriteLine — which bypasses the pipeline, so
        # the JSON has to be captured from a child process's stdout rather than
        # by assigning the call.
        $harness = Join-Path $Sandbox 'invoke-harness.ps1'
        @'
param([string]$HookPs1, [string]$FixtureDir, [string]$Section)
$ast = [System.Management.Automation.Language.Parser]::ParseFile($HookPs1, [ref]$null, [ref]$null)
$fns = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
foreach ($f in $fns) { . ([scriptblock]::Create($f.Extent.Text)) }
$StrideLiteMd = Join-Path $FixtureDir '.stride_lite.md'
$ProjectDir   = $FixtureDir
$rc = Invoke-StrideLiteSection -Section $Section
[Console]::Out.WriteLine("---RC:$rc---")
'@ | Set-Content -Path $harness -Encoding UTF8
        $psExe = (Get-Process -Id $PID).Path
        # Capture stderr rather than discarding it: a child that dies otherwise
        # yields Json='' and Rc=0, which is EXACTLY what the no-op branches
        # assert -- so eight assertions would pass against an executor that
        # cannot run at all.
        $errFile = Join-Path $Sandbox 'invoke-harness.err'
        $raw = & $psExe -NoProfile -File $harness -HookPs1 $HookPs1 -FixtureDir $FixtureDir -Section $Section 2>$errFile
        $text = ($raw | Out-String) -replace "`r", ''
        # The marker is the proof the function ran to completion. Its absence is
        # a harness failure, never a result -- fail loudly with what came back.
        if ($text -notmatch '---RC:(\d+)---') {
            $errText = if (Test-Path $errFile) { (Get-Content $errFile -Raw) } else { '' }
            Write-Nope "the .ps1 harness completed for section '$Section'" `
                       "an ---RC:<n>--- marker" ("stdout=[" + $text.Trim() + "] stderr=[" + $errText.Trim() + "]")
            return [pscustomobject]@{ Json = '<<HARNESS DID NOT COMPLETE>>'; Rc = -1 }
        }
        $rc = [int]$Matches[1]
        $json = ($text -split "`n" | Where-Object { $_.TrimStart().StartsWith('{') }) -join ''
        return [pscustomobject]@{ Json = $json; Rc = $rc }
    }

    function New-Fixture {
        param([string]$Name, [string]$Content)
        $d = Join-Path $Sandbox $Name
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        if ($null -ne $Content) { Set-Content -Path (Join-Path $d '.stride_lite.md') -Value $Content -Encoding UTF8 -NoNewline }
        return $d
    }

    if (-not $HasBash) {
        Write-Skipped "Invoke-StrideLiteSection cases" "no bash on PATH; the .ps1 executor runs each command through bash"
    } else {
        $d = New-Fixture 'ps-noop-missing' $null
        $r = Invoke-Section $d 'before_task'
        Assert-Eq "a missing .stride_lite.md returns 0" $r.Rc 0
        Assert-Eq "a missing .stride_lite.md emits nothing" $r.Json ''

        $d = New-Fixture 'ps-noop-section' "## after_task`n`n``````bash`ntrue`n``````"
        $r = Invoke-Section $d 'before_task'
        Assert-Eq "a missing section returns 0" $r.Rc 0
        Assert-Eq "a missing section emits nothing" $r.Json ''
        $r = Invoke-Section $d 'after_task'
        Assert-Eq "the section that is present still runs" $r.Rc 0
        Assert-Has "the present section emits success JSON" $r.Json '"status":"success"'

        $d = New-Fixture 'ps-noop-empty' "## before_task`n`n``````bash`n``````"
        $r = Invoke-Section $d 'before_task'
        Assert-Eq "an empty fenced block returns 0" $r.Rc 0
        Assert-Eq "an empty fenced block emits nothing" $r.Json ''

        $d = New-Fixture 'ps-noop-comments' "## before_task`n`n``````bash`n# only a comment`n`n#   another`n``````"
        $r = Invoke-Section $d 'before_task'
        Assert-Eq "a comment-only body returns 0" $r.Rc 0
        Assert-Eq "a comment-only body emits nothing" $r.Json ''

        Write-Host ""
        Write-Host "Invoke-StrideLiteSection — the success shape"

        $d = New-Fixture 'ps-success' "## before_task`n`n``````bash`ntrue`n# not a command`n:`ntrue`n``````"
        $r = Invoke-Section $d 'before_task'
        Assert-Eq "a multi-command section returns 0" $r.Rc 0
        Assert-Has "the success JSON names its hook" $r.Json '"hook":"before_task"'
        $keys = ([regex]::Matches($r.Json, '"([a-z_]+)"\s*:') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique) -join ' '
        Assert-Eq "the success JSON carries exactly its four documented keys" $keys 'commands_completed duration_seconds hook status'
        Assert-Lacks "commands_completed excludes the comment line" $r.Json 'not a command'

        Write-Host ""
        Write-Host "Invoke-StrideLiteSection — first-failure stop"

        $d = New-Fixture 'ps-failure' "## before_task`n`n``````bash`necho marker-one`nfalse`necho marker-three`n``````"
        $r = Invoke-Section $d 'before_task'
        Assert-Eq "a failing command returns 2" $r.Rc 2
        Assert-Has "the failure JSON names the failing command" $r.Json '"failed_command":"false"'
        # Zero-based, matching the .sh and what agents/hook-diagnostician.md documents.
        Assert-Has "the failure JSON reports a zero-based index" $r.Json '"command_index":1'
        Assert-Has "commands_completed holds only what ran" $r.Json '"commands_completed":["echo marker-one"]'
        Assert-Has "commands_remaining holds only what did not" $r.Json '"commands_remaining":["echo marker-three"]'
        $fkeys = ([regex]::Matches($r.Json, '"([a-z_]+)"\s*:') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique) -join ' '
        Assert-Eq "the failure JSON carries exactly its nine documented keys" $fkeys `
            'command_index commands_completed commands_remaining exit_code failed_command hook status stderr stdout'

        Write-Host ""
        Write-Host "Invoke-StrideLiteSection — output truncation"

        $tail = "## before_task`n`n``````bash`ni=1; while [ `$i -le 120 ]; do echo line-`$i; i=`$((i + 1)); done; false`n``````"
        $d = New-Fixture 'ps-tail' $tail
        $r = Invoke-Section $d 'before_task'
        Assert-Eq "the chatty failing command returns 2" $r.Rc 2
        Assert-Has "the tail keeps the last line" $r.Json 'line-120'
        Assert-Has "the tail keeps exactly the last 50" $r.Json 'line-71'
        Assert-Lacks "the tail drops everything before the last 50" $r.Json 'line-70'

        $d = New-Fixture 'ps-fail-first' "## after_task`n`n``````bash`nfalse`necho unreached`n``````"
        $r = Invoke-Section $d 'after_task'
        Assert-Eq "failing on the first command returns 2" $r.Rc 2
        Assert-Has "an empty completed list renders as []" $r.Json '"commands_completed":[]'
        Assert-Has "the index is 0 when the first command fails" $r.Json '"command_index":0'
    }

    # -----------------------------------------------------------------------
    # Set-StrideLiteEnvKv — sanitization
    #
    # Extracted but never called until now, which the extraction assertion's own
    # wording ("every function this suite exercises") made invisible.
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "Set-StrideLiteEnvKv — sanitization"

    Set-StrideLiteEnvKv -Key '1FOO' -Value 'value'
    Assert-Eq "a key starting with a digit is dropped" ([string][System.Environment]::GetEnvironmentVariable('1FOO')) ''
    Set-StrideLiteEnvKv -Key 'FOO-BAR' -Value 'value'
    Assert-Eq "a key containing a hyphen is dropped" ([string][System.Environment]::GetEnvironmentVariable('FOO-BAR')) ''
    Set-StrideLiteEnvKv -Key 'PS_VALID_KEY' -Value 'kept'
    Assert-Eq "a valid identifier is set" ([string][System.Environment]::GetEnvironmentVariable('PS_VALID_KEY')) 'kept'
    Set-StrideLiteEnvKv -Key 'PS_CTRL' -Value "a`tb`rc"
    Assert-Eq "control characters are stripped from the value" ([string][System.Environment]::GetEnvironmentVariable('PS_CTRL')) 'abc'
    Set-StrideLiteEnvKv -Key 'PS_LONG' -Value ('x' * 900)
    Assert-Eq "an oversized value is truncated to 512" ([string][System.Environment]::GetEnvironmentVariable('PS_LONG')).Length 512
    Set-StrideLiteEnvKv -Key 'PS_SHORT' -Value ('y' * 100)
    Assert-Eq "a value under the cap is left whole" ([string][System.Environment]::GetEnvironmentVariable('PS_SHORT')).Length 100

    # -----------------------------------------------------------------------
    # Set-StrideLiteHookEnv — the loose-task branch
    #
    # Also extracted but never called. The hook name matters: only after_goal
    # takes the source candidate directly, so a slug-named file resolves at all.
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "Set-StrideLiteHookEnv — a loose task with no sibling goal.md"

    $looseRoot = Join-Path $Sandbox 'ps-loose'
    New-Item -ItemType Directory -Path (Join-Path $looseRoot 'tasks') -Force | Out-Null
    Set-Content -Path (Join-Path $looseRoot 'tasks/some-slug.md') -Value "# A standalone task" -Encoding UTF8
    $PathSep = [System.IO.Path]::DirectorySeparatorChar
    $PathComparison = if ($PathSep -eq '\') { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    $ProjectAbs = (Resolve-Path -LiteralPath $looseRoot).ProviderPath.TrimEnd($PathSep)
    $ProjectDir = $ProjectAbs
    foreach ($k in @('HOOK_NAME','TASK_FILE','TASK_NUMBER','TASK_TITLE','GOAL_DIR','GOAL_FILE','GOAL_SLUG','GOAL_TITLE','AGENT_NAME')) {
        [System.Environment]::SetEnvironmentVariable($k, $null)
    }
    Set-StrideLiteHookEnv -Hook 'after_goal' -Source 'tasks/some-slug.md' -Agent ''
    # Positive controls first: without them "GOAL_DIR is empty" cannot tell a
    # cleared branch from a path that never resolved.
    Assert-Eq "the loose task file itself resolves" `
        ([string][System.Environment]::GetEnvironmentVariable('TASK_FILE')) (Join-Path (Join-Path $ProjectAbs 'tasks') 'some-slug.md')
    Assert-Eq "the loose task's title is read from it" ([string][System.Environment]::GetEnvironmentVariable('TASK_TITLE')) 'A standalone task'
    Assert-Eq "a loose task leaves GOAL_DIR empty" ([string][System.Environment]::GetEnvironmentVariable('GOAL_DIR')) ''
    Assert-Eq "a loose task leaves GOAL_FILE empty" ([string][System.Environment]::GetEnvironmentVariable('GOAL_FILE')) ''
    Assert-Eq "a loose task leaves GOAL_TITLE empty" ([string][System.Environment]::GetEnvironmentVariable('GOAL_TITLE')) ''
    Assert-Eq "a loose task leaves GOAL_SLUG empty" ([string][System.Environment]::GetEnvironmentVariable('GOAL_SLUG')) ''

    # The other side of the branch. Without it, every "is empty" assertion above
    # still passes against a function that never populates the goal keys for
    # anyone -- which is exactly what a mutant proved on this suite.
    $withGoal = Join-Path $Sandbox 'ps-withgoal'
    New-Item -ItemType Directory -Path (Join-Path $withGoal 'tasks') -Force | Out-Null
    Set-Content -Path (Join-Path $withGoal 'tasks/goal.md')  -Value "# The Goal"      -Encoding UTF8
    Set-Content -Path (Join-Path $withGoal 'tasks/task1.md') -Value "# A sibling task" -Encoding UTF8
    $ProjectAbs = (Resolve-Path -LiteralPath $withGoal).ProviderPath.TrimEnd($PathSep)
    $ProjectDir = $ProjectAbs
    foreach ($k in @('HOOK_NAME','TASK_FILE','TASK_NUMBER','TASK_TITLE','GOAL_DIR','GOAL_FILE','GOAL_SLUG','GOAL_TITLE','AGENT_NAME')) {
        [System.Environment]::SetEnvironmentVariable($k, $null)
    }
    Set-StrideLiteHookEnv -Hook 'after_goal' -Source 'tasks/goal.md' -Agent ''
    Assert-Eq "a task beside a goal.md populates GOAL_FILE" `
        ([string][System.Environment]::GetEnvironmentVariable('GOAL_FILE')) (Join-Path (Join-Path $ProjectAbs 'tasks') 'goal.md')
    Assert-Eq "a task beside a goal.md populates GOAL_TITLE" ([string][System.Environment]::GetEnvironmentVariable('GOAL_TITLE')) 'The Goal'
    Assert-Eq "a task beside a goal.md populates GOAL_SLUG" ([string][System.Environment]::GetEnvironmentVariable('GOAL_SLUG')) 'tasks'
    Assert-Eq "a task beside a goal.md populates GOAL_DIR" `
        ([string][System.Environment]::GetEnvironmentVariable('GOAL_DIR')) (Join-Path $ProjectAbs 'tasks')

    # -----------------------------------------------------------------------
    # Resolve-StrideLiteInProject — containment
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "Resolve-StrideLiteInProject — containment"

    $resolveRoot = Join-Path $Sandbox 'ps-resolve'
    New-Item -ItemType Directory -Path (Join-Path $resolveRoot 'goal') -Force | Out-Null
    $outside = Join-Path $Sandbox 'ps-outside'
    New-Item -ItemType Directory -Path $outside -Force | Out-Null
    Set-Content -Path (Join-Path $resolveRoot 'goal/task1.md') -Value "# Real task" -Encoding UTF8
    Set-Content -Path (Join-Path $outside 'secret.md') -Value "# Secret" -Encoding UTF8
    # Re-declare the module-scope variables the function closes over, exactly as
    # the executor sets them. Missing any one of them makes EVERY case below
    # return empty for an unrelated reason, so the refusals would all pass
    # vacuously -- which is precisely what the positive control below caught.
    $PathSep = [System.IO.Path]::DirectorySeparatorChar
    $PathComparison = if ($PathSep -eq '\') {
        [System.StringComparison]::OrdinalIgnoreCase
    } else {
        [System.StringComparison]::Ordinal
    }
    $ProjectAbs = (Resolve-Path -LiteralPath $resolveRoot).ProviderPath.TrimEnd($PathSep)
    $ProjectDir = $ProjectAbs

    # THE POSITIVE CONTROL — without one passing case the refusals prove nothing.
    $hit = Resolve-StrideLiteInProject -Path 'goal/task1.md'
    Assert-Eq "a real file inside the project resolves" ([string]$hit) (Join-Path (Join-Path $ProjectAbs 'goal') 'task1.md')
    Assert-Eq "an empty path resolves to empty" ([string](Resolve-StrideLiteInProject -Path '')) ''
    Assert-Eq "a file outside the project is refused" ([string](Resolve-StrideLiteInProject -Path '../ps-outside/secret.md')) ''
    Assert-Eq "a nonexistent file resolves to empty" ([string](Resolve-StrideLiteInProject -Path 'goal/nope.md')) ''

    # The final path component is the one element canonicalization never
    # resolves, so a symlinked task file could still point outside the project.
    # Both directions are refused: the rule is about the component BEING a link,
    # not about where it currently lands, because a target can be repointed
    # after the check.
    $linkOut = Join-Path (Join-Path $ProjectAbs 'goal') 'link-out.md'
    $linkIn  = Join-Path (Join-Path $ProjectAbs 'goal') 'link-in.md'
    New-Item -ItemType SymbolicLink -Path $linkOut -Target (Join-Path $outside 'secret.md') -Force | Out-Null
    New-Item -ItemType SymbolicLink -Path $linkIn  -Target (Join-Path (Join-Path $ProjectAbs 'goal') 'task1.md') -Force | Out-Null
    Assert-Eq "a symlink pointing outside the project is refused" ([string](Resolve-StrideLiteInProject -Path 'goal/link-out.md')) ''
    Assert-Eq "a symlink pointing inside the project is refused too" ([string](Resolve-StrideLiteInProject -Path 'goal/link-in.md')) ''

    # -----------------------------------------------------------------------
    # Get-StrideLiteFirstHeading
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "Get-StrideLiteFirstHeading"

    $hd = Join-Path $Sandbox 'ps-headings'
    New-Item -ItemType Directory -Path $hd -Force | Out-Null
    Set-Content -Path (Join-Path $hd 'plain.md')   -Value "# The title`n`nBody." -Encoding UTF8
    Set-Content -Path (Join-Path $hd 'h2first.md') -Value "## Not a title`n`n# The real title" -Encoding UTF8
    Set-Content -Path (Join-Path $hd 'none.md')    -Value "No heading at all." -Encoding UTF8
    Assert-Eq "the first H1 is returned" ([string](Get-StrideLiteFirstHeading -Path (Join-Path $hd 'plain.md'))) 'The title'
    Assert-Eq "an H2 is skipped and scanning continues" ([string](Get-StrideLiteFirstHeading -Path (Join-Path $hd 'h2first.md'))) 'The real title'
    Assert-Eq "a file with no H1 returns empty" ([string](Get-StrideLiteFirstHeading -Path (Join-Path $hd 'none.md'))) ''
    Assert-Eq "a missing file returns empty" ([string](Get-StrideLiteFirstHeading -Path (Join-Path $hd 'absent.md'))) ''
    # The scan stops at 200 lines -- an unbounded read of an arbitrary file is
    # what is being avoided -- so a heading below the cap is deliberately missed.
    Set-Content -Path (Join-Path $hd 'deep.md')    -Value (((1..205 | ForEach-Object { 'filler' }) -join "`n") + "`n# Too late") -Encoding UTF8
    Set-Content -Path (Join-Path $hd 'shallow.md') -Value (((1..150 | ForEach-Object { 'filler' }) -join "`n") + "`n# Just in time") -Encoding UTF8
    Assert-Eq "a heading past the 200-line cap is not found" ([string](Get-StrideLiteFirstHeading -Path (Join-Path $hd 'deep.md'))) ''
    Assert-Eq "a heading within the cap is found" ([string](Get-StrideLiteFirstHeading -Path (Join-Path $hd 'shallow.md'))) 'Just in time'

    # -----------------------------------------------------------------------
    # Get-StrideLitePathFromPrompt
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "Get-StrideLitePathFromPrompt"

    Assert-Eq "an empty prompt yields empty" ([string](Get-StrideLitePathFromPrompt -Prompt '')) ''
    Assert-Eq "a bare task path is found" ([string](Get-StrideLitePathFromPrompt -Prompt 'Review docs/g/task2.md now')) 'docs/g/task2.md'
    Assert-Eq "a bare goal path is found" ([string](Get-StrideLitePathFromPrompt -Prompt 'See docs/g/goal.md')) 'docs/g/goal.md'
    Assert-Eq "a trailing period is stripped" ([string](Get-StrideLitePathFromPrompt -Prompt 'Read docs/g/task1.md.')) 'docs/g/task1.md'
    Assert-Eq "task.md without a number is not a task file" ([string](Get-StrideLitePathFromPrompt -Prompt 'Read docs/g/task.md')) ''
    Assert-Eq "prose with no path yields empty" ([string](Get-StrideLitePathFromPrompt -Prompt 'Please review the second task')) ''
    # Escape sequences arrive as literal backslash-n in a JSON-carried prompt, so
    # they must act as separators or the path fuses to its neighbour.
    Assert-Eq "a literal backslash-n before the path is a separator" ([string](Get-StrideLitePathFromPrompt -Prompt 'Task:\ndocs/g/task1.md\nGo')) 'docs/g/task1.md'
    Assert-Eq "a literal backslash-t is a separator too" ([string](Get-StrideLitePathFromPrompt -Prompt 'Task:\tdocs/g/task3.md')) 'docs/g/task3.md'
    Assert-Eq "wrapping parentheses are stripped" ([string](Get-StrideLitePathFromPrompt -Prompt 'Read (docs/g/task1.md)')) 'docs/g/task1.md'
    Assert-Eq "a trailing comma is stripped" ([string](Get-StrideLitePathFromPrompt -Prompt 'Read docs/g/task1.md, then stop')) 'docs/g/task1.md'
    Assert-Eq "taskX.md is not a task file" ([string](Get-StrideLitePathFromPrompt -Prompt 'Read docs/g/taskX.md')) ''
    Assert-Eq "an unrelated markdown file is not matched" ([string](Get-StrideLitePathFromPrompt -Prompt 'Read docs/g/notes.md')) ''

    # -----------------------------------------------------------------------
    # Test-StrideLiteMarkerFresh — return values
    #
    # Sandboxed project root throughout: a marker written into the real project
    # directory would arm hooks for any concurrent session.
    # -----------------------------------------------------------------------
    Write-Host ""
    Write-Host "Test-StrideLiteMarkerFresh — return values"

    $mk = Join-Path $Sandbox 'ps-marker'
    New-Item -ItemType Directory -Path (Join-Path $mk '.stride-lite') -Force | Out-Null
    $markerPath = Join-Path $mk '.stride-lite/.orchestrator_active'
    function Write-Marker { param([datetime]$When)
        $iso = $When.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        Set-Content -Path $markerPath -Value ('{"session_id":"t","started_at":"' + $iso + '","pid":1}') -Encoding UTF8
    }

    if (Test-Path $markerPath) { Remove-Item -Force $markerPath }
    Assert-Eq "a missing marker is not fresh" (Test-StrideLiteMarkerFresh -ProjectRoot $mk) $false
    Write-Marker (Get-Date)
    Assert-Eq "a fresh marker is fresh" (Test-StrideLiteMarkerFresh -ProjectRoot $mk) $true
    Set-Content -Path $markerPath -Value '' -Encoding UTF8
    Assert-Eq "an empty marker is not fresh" (Test-StrideLiteMarkerFresh -ProjectRoot $mk) $false
    Set-Content -Path $markerPath -Value '{"session_id":"t","pid":1}' -Encoding UTF8
    Assert-Eq "a marker with no started_at is not fresh" (Test-StrideLiteMarkerFresh -ProjectRoot $mk) $false
    Write-Marker ((Get-Date).AddHours(-5))
    Assert-Eq "a stale marker is not fresh" (Test-StrideLiteMarkerFresh -ProjectRoot $mk) $false
    Write-Marker ((Get-Date).AddHours(1))
    Assert-Eq "a future-dated marker is not fresh" (Test-StrideLiteMarkerFresh -ProjectRoot $mk) $false
    # The window is a parameter rather than a script-scope variable precisely so
    # a caller cannot shadow it; pin that it is honoured.
    Write-Marker ((Get-Date).AddHours(-5))
    Assert-Eq "a wider window accepts the same marker" (Test-StrideLiteMarkerFresh -ProjectRoot $mk -MaxAgeSeconds 36000) $true

    # The override bypasses the gate entirely, and ONLY the exact value 1 does.
    # A regression from -eq '1' to a truthiness check would make `=0` arm a
    # user's hooks on a standalone dispatch, and nothing here would notice.
    if (Test-Path $markerPath) { Remove-Item -Force $markerPath }
    $env:STRIDE_LITE_ALLOW_DIRECT = '1'
    Assert-Eq "the override bypasses a missing marker" (Test-StrideLiteMarkerFresh -ProjectRoot $mk) $true
    $env:STRIDE_LITE_ALLOW_DIRECT = '0'
    Assert-Eq "the override set to 0 does not bypass" (Test-StrideLiteMarkerFresh -ProjectRoot $mk) $false
    $env:STRIDE_LITE_ALLOW_DIRECT = $null
}
finally {
    if (Test-Path $Sandbox) { Remove-Item -Recurse -Force $Sandbox }
}

Write-Host ""
Write-Host "------------------------------------------------------------------"
$total = $script:Pass + $script:Fail
if ($script:Skip -gt 0) {
    Write-Host "$($script:Pass) passed, $($script:Fail) failed, $($script:Skip) skipped (out of $total run)"
} else {
    Write-Host "$($script:Pass) passed, $($script:Fail) failed (out of $total)"
}
Write-Host "------------------------------------------------------------------"
if ($script:Fail -ne 0) { exit 1 }
exit 0
