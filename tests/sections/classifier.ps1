# tests/sections/classifier.ps1: dot-sourced by tests/run-tests.ps1 in its turn,
# never on its own - it uses what the runner and the sections before it set.

Section 'classifier'
function Invoke-Scenario([string]$Name, [string]$Mode = 'auto') {
    $st = New-ChatqRunState
    $file = Join-Path $here "fixtures\stream\$Name.jsonl"
    foreach ($l in [System.IO.File]::ReadAllLines($file, $utf8)) {
        if ($l.Trim()) { Update-ChatqClaudeState $st ($l.Replace('{{RESETS}}', "$future").Replace('{{SESSION}}', $idCard)) }
    }
    Get-ChatqClaudeOutcome $st ([pscustomobject]@{ ExitCode = 0; StdErr = ''; Stopped = $null }) $Mode
}
# a Codex fixture through Codex's classifier; -Failed sets a turn.failed by
# hand, and the exit code is a failed run's unless given
function Invoke-CodexScenario([string]$Name, [string]$StdErr = '', [string]$Failed, [int]$ExitCode = 1) {
    $s = New-ChatqRunState
    if ($Name) { foreach ($l in [System.IO.File]::ReadAllLines((Join-Path $here "fixtures\stream\$Name.jsonl"), $utf8)) { if ($l.Trim()) { Update-ChatqCodexState $s $l } } }
    if ($Failed) { $s.TurnStarted = $true; $s.TurnFailed = $Failed; $s.Failed = $Failed }
    Get-ChatqCodexOutcome $s ([pscustomobject]@{ ExitCode = $ExitCode; StdErr = $StdErr; Stopped = $null })
}
$o = Invoke-Scenario 'denied'
Check 'denial -> needs-input' ($o.kind -eq 'needs-input' -and $o.reason -like '*Write(note.txt)*') "$($o.kind) $($o.reason)"
$o = Invoke-Scenario 'rejected'
Check 'rejected event -> limited, reset time kept' ($o.kind -eq 'limited' -and $o.resetsAt) "$($o.kind) $($o.resetsAt)"
$o = Invoke-Scenario 'legacy'
Check 'legacy "|epoch" -> limited with time' ($o.kind -eq 'limited' -and $o.resetsAt) "$($o.kind) $($o.resetsAt)"
$o = Invoke-Scenario 'weekly-synthetic'
Check 'weekly limit text -> limited' ($o.kind -eq 'limited') "$($o.kind)"
$o = Invoke-Scenario 'plan' 'plan'
Check 'plan mode -> needs-input' ($o.kind -eq 'needs-input') "$($o.kind)"
$o = Invoke-Scenario 'maxturns'
Check 'turn limit -> needs-input' ($o.kind -eq 'needs-input') "$($o.kind)"
$o = Invoke-Scenario 'error'
Check 'error subtype -> failed' ($o.kind -eq 'failed') "$($o.kind)"
$o = Invoke-Scenario 'noresult'
Check 'no result line -> failed' ($o.kind -eq 'failed' -and $o.reason -like 'no result*') "$($o.kind) $($o.reason)"
$o = Invoke-Scenario 'asks'
Check 'ends on a question -> done, asks' ($o.kind -eq 'done' -and $o.asks) "$($o.kind) $($o.asks)"
Check 'excerpt drops code fences' ($o.excerpt -notlike '*some code*' -and $o.excerpt -like '*update the tests?*') $o.excerpt
$o = Invoke-CodexScenario 'codex-limit'
Check 'codex usage limit -> limited with time' ($o.kind -eq 'limited' -and $o.resetsAt) "$($o.kind) $($o.resetsAt)"
$o = Invoke-CodexScenario 'codex-done' -ExitCode 0
Check 'codex turn.completed -> done' ($o.kind -eq 'done' -and $o.excerpt -like '*build passes*') "$($o.kind) $($o.excerpt)"
$o = Invoke-CodexScenario 'codex-retry-done' -ExitCode 0
Check 'codex reconnect notice then turn.completed -> done' ($o.kind -eq 'done') "$($o.kind) $($o.reason)"
$o = Invoke-Scenario 'overloaded'
Check '529 Overloaded -> overloaded, not failed' ($o.kind -eq 'overloaded' -and $o.reason -like 'API Error: 529*') "$($o.kind) $($o.reason)"
$o = Invoke-Scenario 'overage-success'
Check 'a rejected event before a successful turn -> done' ($o.kind -eq 'done') "$($o.kind)"
