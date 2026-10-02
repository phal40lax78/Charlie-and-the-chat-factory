# tests/sections/overload.ps1: dot-sourced by tests/run-tests.ps1 in its turn,
# never on its own - it uses what the runner and the sections before it set.

Section 'overload and status.claude.com'
$lt = Get-ChatqLastTurn $pOver
Check 'a chat stopped by a 529 is recognised' ($lt.Overloaded -and -not $lt.Limit) "over=$($lt.Overloaded) limit=$($lt.Limit)"
$cut = @(Get-ChatqCutOffChats @())
Check '529-stopped chat listed as cut off' (@($cut | Where-Object { $_.Id -eq $idOver -and $_.Why -eq 'overloaded' }).Count -eq 1)
$script:ChatqStatusUrl = $statusFile
Set-FakeStatus 'major_outage'
Check 'status page read' ((Get-ChatqClaudeStatus) -eq 'major_outage') (Get-ChatqClaudeStatus)
$Wo = New-ChatqWatchState
$fakeJob = [pscustomobject]@{ provider = 'claude'; home = $claudeHome; title = 'x'; model = $null; cwd = $projA }
Enter-ChatqOutage $Wo $fakeJob 'API Error: 529'
$lane = Get-ChatqLane $fakeJob
Check 'first retry waits a minute' ([Math]::Abs(($Wo.outage[$lane].NextCheck - (Get-Date).AddMinutes(1)).TotalSeconds) -lt 5)
$Wo.outage[$lane].NextCheck = (Get-Date).AddSeconds(-1)
Check 'outage page: no probe yet' (-not (Test-ChatqOutageOver $Wo $fakeJob))
Check 'then the page is polled every minute' ([Math]::Abs(($Wo.outage[$lane].NextCheck - (Get-Date).AddSeconds(60)).TotalSeconds) -lt 5)
Set-FakeStatus 'operational'
$Wo.outage[$lane].NextCheck = (Get-Date).AddSeconds(-1)
Check 'operational again: probe at once' (Test-ChatqOutageOver $Wo $fakeJob)
Set-FakeStatus 'partial_outage'
$Wo.outage[$lane].NextCheck = (Get-Date).AddSeconds(-1)
$Wo.outage[$lane].LastProbe = (Get-Date).AddMinutes(-16)
Check 'page lagging for 15 min: probe anyway' (Test-ChatqOutageOver $Wo $fakeJob)
Set-FakeStatus 'operational'
$Wo.outage[$lane].NextCheck = (Get-Date).AddSeconds(-1)
Check 'a good probe ends the outage' ((Confirm-ChatqAllowed $Wo $fakeJob) -and -not $Wo.outage[$lane])
$alerts0 = if (Test-Path -LiteralPath (Join-Path $script:ChatqLogDir 'alerts.log')) { [System.IO.File]::ReadAllText((Join-Path $script:ChatqLogDir 'alerts.log'), $utf8) } else { '' }
Check 'one overloaded alert' (([regex]::Matches($alerts0, "`toverloaded`t")).Count -eq 1)

# A Codex lane: no status page to wait on - not even read - so the backoff
# alone, 1, 2, 5, 10, then every 15 minutes, and no word of Claude
Set-FakeStatus 'major_outage'
$ovCxJob = [pscustomobject]@{ provider = 'codex'; home = $null; title = 'Codex overload check'; model = $null; runModel = $null; cwd = $projA }
$ovCxLane = Get-ChatqLane $ovCxJob
$ovStatusFn = ${function:Get-ChatqClaudeStatus}
$script:OvStatusReads = 0
${function:Get-ChatqClaudeStatus} = { $script:OvStatusReads++; 'major_outage' }
try {
    Enter-ChatqOutage $Wo $ovCxJob 'exceeded retry limit, last status: 503'
    $ovFirst = $Wo.outage[$ovCxLane].NextCheck
    $ovEarly = Test-ChatqOutageOver $Wo $ovCxJob
    $Wo.outage[$ovCxLane].NextCheck = (Get-Date).AddSeconds(-1)
    $ovDue = Test-ChatqOutageOver $Wo $ovCxJob
    # a probe still overloaded: the next step, two minutes
    Enter-ChatqOutage $Wo $ovCxJob 'the probe found Codex overloaded'
    $ovSecond = $Wo.outage[$ovCxLane].NextCheck
    # six hours on: the one reminder, in Codex's words too
    $Wo.outage[$ovCxLane].Since = (Get-Date).AddHours(-7)
    $Wo.outage[$ovCxLane].NextCheck = (Get-Date).AddSeconds(-1)
    $null = Test-ChatqOutageOver $Wo $ovCxJob
}
finally { ${function:Get-ChatqClaudeStatus} = $ovStatusFn }
Check 'a Codex outage: first try a minute out, then due once that passed, the next two minutes out - and the status page never read' (
    [Math]::Abs(($ovFirst - (Get-Date).AddMinutes(1)).TotalSeconds) -lt 5 -and -not $ovEarly -and $ovDue -and
    [Math]::Abs(($ovSecond - (Get-Date).AddMinutes(2)).TotalSeconds) -lt 5 -and $script:OvStatusReads -eq 0 -and
    -not $Wo.outage[$ovCxLane].Status) "first $ovFirst early $ovEarly due $ovDue second $ovSecond reads $($script:OvStatusReads)"
$ovLines = @([System.IO.File]::ReadAllLines((Join-Path $script:ChatqLogDir 'alerts.log'), $utf8) | Where-Object { $_ -like '*Codex overload check*' })
Check 'its alert and its 6 h reminder say Codex, never Claude or its status page' (
    $ovLines.Count -eq 2 -and $ovLines[0] -like '*resumes when Codex is back*' -and $ovLines[1] -like '*Codex still overloaded after 6 h*tried again every 15 min*' -and
    -not @($ovLines | Where-Object { $_ -match 'Claude|status\.claude\.com' }).Count) ($ovLines -join ' / ')
# the words a queued job's lane shows, from the watcher's saved view: a
# Codex outage sends "when Codex is back", and the console and chatq say so
$ovEta = Get-ChatqEta @([pscustomobject]@{ id = 'ov-cx'; seq = 1; state = 'queued'; provider = 'codex'; home = $null; notBefore = $null; deferUntil = $null; retryAt = $null }) @{ codex = [pscustomobject]@{ Until = (Get-Date).AddMinutes(1); Type = 'overloaded'; Source = 'backoff' } }
$ovPvCx = Get-ChatConsoleSendPreview @{ Kind = 'chat'; Live = $null; Provider = 'codex' } @{} ([pscustomobject]@{ Until = (Get-Date); Type = 'overloaded' }) 0 $true
$ovPvCl = Get-ChatConsoleSendPreview @{ Kind = 'chat'; Live = $null; Provider = 'claude' } @{} ([pscustomobject]@{ Until = (Get-Date); Type = 'overloaded' }) 0 $true
Check 'a Codex lane overloaded: sends "when Codex is back"; the console''s preview names Codex and its tries, Claude''s still its page' (
    $ovEta['ov-cx'] -eq 'when Codex is back' -and $ovPvCx -like 'Codex is overloaded - sends once a try gets through*' -and $ovPvCx -notmatch 'Claude' -and
    $ovPvCl -like 'Claude is overloaded - sends once status.claude.com has it back*') "$($ovEta['ov-cx']) / $ovPvCx / $ovPvCl"
# a good Codex probe ends it
$Wo.outage[$ovCxLane].NextCheck = (Get-Date).AddSeconds(-1)
$env:FAKE_SCENARIO = Join-Path $here 'fixtures\stream\codex-done.jsonl'
try { $ovBack = Confirm-ChatqAllowed $Wo $ovCxJob } finally { Remove-Item env:FAKE_SCENARIO }
Check 'and a good Codex probe ends the outage' ($ovBack -and -not $Wo.outage[$ovCxLane]) "$ovBack"
Set-FakeStatus 'operational'
