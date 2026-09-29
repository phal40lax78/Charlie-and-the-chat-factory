# tests/sections/show-fresh.ps1: dot-sourced by tests/run-tests.ps1 in its turn,
# never on its own - it uses what the runner and the sections before it set.

Section 'show fresh'
# A chat in a folder of its own, its live processes in a Claude home of their
# own (only the registry lives there - the transcript is found through the
# index). Ending a process is the stop seam: it records the pid, and takes
# the process out of the fake claude agents and the registry, as ending it
# would.
# by $sb: $work was taken for a screen rect in the overlay section
$projS = Join-Path (Join-Path $sb 'work') 'projS'
$null = New-Item -ItemType Directory -Path $projS -Force
$idS = '5f5f5f5f-5f5f-4f5f-8f5f-5f5f5f5f5f5f'
$pS = New-FakeChat $projS $idS 'Show fresh chat' 1 @('first thing')
$null = @(Sync-ChatIndex)
$sfHome = Join-Path $sb 'claude-sf'
$sfSess = Join-Path $sfHome 'sessions'
$null = New-Item -ItemType Directory -Path $sfSess -Force
$script:ChatqAliveSeam = { param($e) $true }
$sfStart = [DateTimeOffset]::UtcNow.AddMinutes(-60).ToUnixTimeMilliseconds()
function Set-SfSession([int]$ProcId, [string]$Status = 'idle', [string]$Kind = 'interactive', [string]$Entrypoint = 'claude-vscode', [int64]$StartedAt = $sfStart) {
    $o = [ordered]@{ pid = $ProcId; sessionId = $idS; cwd = $projS; startedAt = $StartedAt; kind = $Kind; entrypoint = $Entrypoint
        pidDomain = "win32:$([Environment]::MachineName)"; status = $Status; updatedAt = $sfStart }
    [System.IO.File]::WriteAllText((Join-Path $sfSess "$ProcId.json"), ($o | ConvertTo-Json -Compress), $utf8)
}
function New-SfLive([int]$ProcId, [string]$Status = 'idle', [string]$Kind = 'interactive', [string]$Entrypoint = 'claude-vscode') {
    [pscustomobject]@{ SessionId = $idS; Pid = $ProcId; Status = $Status; Kind = $Kind; WaitingFor = $null; ProcStart = $null; StartedAt = $sfStart; Entrypoint = $Entrypoint }
}
function Set-SfAgents([object[]]$Live) {
    # what the fake claude agents says: the same entries, as JSON
    $env:FAKE_AGENTS = '[' + ((@($Live) | ForEach-Object { [ordered]@{ pid = $_.Pid; sessionId = $_.SessionId; kind = $_.Kind; status = $_.Status; startedAt = $_.StartedAt; entrypoint = $_.Entrypoint } | ConvertTo-Json -Compress }) -join ',') + ']'
}
function Clear-SfLive { Remove-Item env:FAKE_AGENTS -EA SilentlyContinue; Get-ChildItem -LiteralPath $sfSess -File | Remove-Item -Force }
$script:SfStops = [System.Collections.Generic.List[int]]::new()
$script:ChatStopSeam = { param($e) $script:SfStops.Add([int]$e.Pid); Remove-Item env:FAKE_AGENTS -EA SilentlyContinue; Remove-Item -LiteralPath (Join-Path $sfSess "$($e.Pid).json") -Force -EA SilentlyContinue; 'ended' }
$script:SfCode = [System.Collections.Generic.List[string]]::new()
$script:ChatCodeSeam = { param($f) $script:SfCode.Add($f); [pscustomobject]@{ Ok = $true; Code = 'ok'; Why = $null; Slow = $false } }
$terminalParent = { param($e) @{ Pid = 9; Name = 'pwsh'; StartTime = [datetime]::MinValue } }
function Add-SfLaunch([string]$Path, [string]$TaskId, [datetime]$At, [string]$Entrypoint = 'claude-vscode') {
    # as each writer stamps it: claude-vscode a window's process, sdk-cli a
    # print-mode run's (claude -p, a queued run)
    $r = [ordered]@{ type = 'user'; timestamp = $At.ToUniversalTime().ToString('o'); sessionId = $idS; entrypoint = $Entrypoint
        message = [ordered]@{ role = 'user'; content = @([ordered]@{ type = 'tool_result'; tool_use_id = 'toolu_x'; content = 'launched' }) }
        toolUseResult = [ordered]@{ status = 'async_launched'; taskId = $TaskId } } | ConvertTo-Json -Compress -Depth 6
    [System.IO.File]::AppendAllText($Path, $r + "`n", $utf8)
}
function Add-SfDone([string]$Path, [string]$TaskId) {
    $r = [ordered]@{ type = 'user'; timestamp = (Get-Date).ToUniversalTime().ToString('o'); sessionId = $idS
        message = [ordered]@{ role = 'user'; content = "<task-notification>`n<task-id>$TaskId</task-id>`n<status>completed</status>`n</task-notification>" } } | ConvertTo-Json -Compress -Depth 6
    # as Claude Code writes it: 5.1's ConvertTo-Json escapes < and >, Node's does not
    $u = [string][char]92 + 'u00'
    [System.IO.File]::AppendAllText($Path, $r.Replace("${u}3c", '<').Replace("${u}3e", '>') + "`n", $utf8)
}

# the registry: which program a process is, read; its secret never
$keyS = Join-Path $sfSess '901.0fb15029164cbeb453ceb405db09b1caeff7424a77491bfef6e933a8e0cc3172.key'
[System.IO.File]::WriteAllText($keyS, 'secret', $utf8)
Set-SfSession 901 'idle' 'interactive' 'cli'
Set-SfSession 902
$keyHold = [System.IO.File]::Open($keyS, 'Open', 'ReadWrite', 'None')
try { $regS = @(Read-ChatqSessionRegistry $sfSess); $liveR = @(Get-ChatqLiveSessions $sfHome -RegistryOnly) } finally { $keyHold.Dispose() }
Check 'the registry says which program each process is, and its .key is never opened' (
    (@($regS | Where-Object { $_.Pid -eq 901 })[0].Entrypoint -eq 'cli') -and (@($regS | Where-Object { $_.Pid -eq 902 })[0].Entrypoint -eq 'claude-vscode') -and
    $liveR.Count -eq 2 -and (@($liveR | Where-Object { $_.Pid -eq 901 })[0].Entrypoint -eq 'cli')) "$(@($regS | ForEach-Object { "$($_.Pid)=$($_.Entrypoint)" }) -join ' ')"
Remove-Item -LiteralPath $keyS -Force
$seenS = Join-Path $sb 'agents-seen.txt'
$env:FAKE_AGENTS_SEEN = $seenS
$null = Get-ChatqLiveSessions $sfHome -RegistryOnly
$seen0 = Test-Path -LiteralPath $seenS
$null = Get-ChatqLiveSessions $sfHome
$seen1 = Test-Path -LiteralPath $seenS
Remove-Item env:FAKE_AGENTS_SEEN
Check '-RegistryOnly never starts claude agents; without it, it does' (-not $seen0 -and $seen1)
Clear-SfLive

$t0s = Get-Date '2026-09-24T10:00:00'
Check 'VS Code''s own: claude-vscode under Code, or Code - Insiders; unnamed counts; a terminal''s, a shell''s child, or a parent younger than it is not' (
    (Test-ChatVsCodeOwned 'claude-vscode' 'Code' $t0s $t0s.AddMinutes(1)) -and -not (Test-ChatVsCodeOwned 'cli' 'Code' $t0s $t0s.AddMinutes(1)) -and
    (Test-ChatVsCodeOwned '' 'Code' $t0s $t0s.AddMinutes(1)) -and -not (Test-ChatVsCodeOwned 'claude-vscode' 'pwsh' $t0s $t0s.AddMinutes(1)) -and
    (Test-ChatVsCodeOwned 'claude-vscode' 'Code - Insiders' $null $null) -and -not (Test-ChatVsCodeOwned 'claude-vscode' 'Code' $t0s.AddMinutes(2) $t0s.AddMinutes(1)))

# Stop-ChatIdleProcess, case by case
$SfStop = { param([object[]]$Live, [hashtable]$More = @{}) Stop-ChatIdleProcess -SessionId $idS -Transcript $pS -ConfigDir $sfHome -Live $Live @More }
$script:SfStops.Clear(); Set-SfSession 1101
$s1 = & $SfStop @(New-SfLive 1101)
Check 'idle, a window''s, its registry file there: ended, and the window named' ($s1.OldProcess -eq 'ended' -and (@($s1.HostPids) -join ',') -eq '4242' -and ($script:SfStops -join ',') -eq '1101') "$($s1.OldProcess) $(@($s1.HostPids) -join ',') $($script:SfStops -join ',')"
$script:SfStops.Clear()
$s2 = & $SfStop @(New-SfLive 1102 'busy')
$s3 = & $SfStop @(New-SfLive 1103 'waiting')
Check 'busy or waiting: held, nothing ended' ($s2.OldProcess -eq 'held' -and $s3.OldProcess -eq 'held' -and -not $script:SfStops.Count) "$($s2.OldProcess) $($s3.OldProcess)"
$bgT = Join-Path $sb 'bg-chat.jsonl'
Copy-Item -LiteralPath $pS -Destination $bgT
$launchAt = (Get-Date).AddMinutes(-10)
Add-SfLaunch $bgT 'wsf0001' $launchAt
Set-SfSession 1104
$s4 = Stop-ChatIdleProcess -SessionId $idS -Transcript $bgT -ConfigDir $sfHome -Live @(New-SfLive 1104)
$bgP = Join-Path $sb 'bg-print-chat.jsonl'
Copy-Item -LiteralPath $pS -Destination $bgP
Add-SfLaunch $bgP 'wsf0101' $launchAt 'sdk-cli'
$s5 = Stop-ChatIdleProcess -SessionId $idS -Transcript $bgP -ConfigDir $sfHome -Live @(New-SfLive 1104)
Check 'a workflow the window''s process started: held; one a print-mode run started, that run gone: dead with it, ended' (
    $s4.OldProcess -eq 'held' -and $s5.OldProcess -eq 'ended' -and ($script:SfStops -join ',') -eq '1104') "$($s4.OldProcess) $($s5.OldProcess)"
$script:SfStops.Clear()
Set-SfSession 1105 'idle' 'print'
$s6 = & $SfStop @(New-SfLive 1105 'idle' 'print')
Set-SfSession 1112
$s6b = Stop-ChatIdleProcess -SessionId $idS -Transcript $bgP -ConfigDir $sfHome -Live @((New-SfLive 1112), (New-SfLive 1105 'idle' 'print'))
Check 'a print-mode claude going into the chat now: held, and the window''s process beside it not ended' (
    $s6.OldProcess -eq 'held' -and $s6b.OldProcess -eq 'held' -and -not $script:SfStops.Count) "$($s6.OldProcess) $($s6b.OldProcess)"
Set-SfSession 1106
$script:ChatParentSeam = $terminalParent
$s7 = & $SfStop @(New-SfLive 1106)
$script:ChatParentSeam = $script:SeamsAtStart.Parent
$script:ChatParentSeam = { param($e) if ($e.Pid -eq 1108) { @{ Pid = 9; Name = 'pwsh'; StartTime = [datetime]::MinValue } } else { @{ Pid = 4242; Name = 'Code'; StartTime = [datetime]::MinValue } } }
Set-SfSession 1107
Set-SfSession 1108 'idle' 'interactive' 'cli'
$s8 = & $SfStop @((New-SfLive 1107), (New-SfLive 1108 'idle' 'interactive' 'cli'))
$script:ChatParentSeam = $script:SeamsAtStart.Parent
Check 'a terminal''s claude: other, and nothing ended - not even the window''s beside it' ($s7.OldProcess -eq 'other' -and $s8.OldProcess -eq 'other' -and -not $script:SfStops.Count) "$($s7.OldProcess) $($s8.OldProcess) $($script:SfStops -join ',')"
Clear-SfLive
Set-SfSession 1109
$s9 = & $SfStop @(New-SfLive 1109) @{ JudgeOnly = $true }
Check '-JudgeOnly: live, the window named, nothing ended' ($s9.OldProcess -eq 'live' -and (@($s9.HostPids) -join ',') -eq '4242' -and -not $script:SfStops.Count) $s9.OldProcess
Set-SfSession 1110 'busy'
$s10 = & $SfStop @(New-SfLive 1110)
$s11 = & $SfStop @(New-SfLive 1111)
Check 'busy by the time its file is read again: held; no file to read: kept - neither ended' ($s10.OldProcess -eq 'held' -and $s11.OldProcess -eq 'kept' -and -not $script:SfStops.Count) "$($s10.OldProcess) $($s11.OldProcess)"
Clear-SfLive

# Show it closes the tab first, then ends what outlived the close: judged
# only, then given a grace, in its own window, never a tab opened since
$sfLog = Join-Path $script:ChatqLogDir 'watcher.log'
$sfLogN = { @(if (Test-Path -LiteralPath $sfLog) { [System.IO.File]::ReadAllLines($sfLog, $utf8) }).Count }
Set-SfSession 1120
$script:SfStops.Clear()
$jo1 = @(Show-ChatFresh -Via button -JudgeOnly -SessionId $idS -Cwd $projS -ConfigDir $sfHome)[-1]
$vjo = ConvertTo-ChatFreshVerdict $jo1
$vjoO = $vjo | ConvertFrom-Json
$vplain = ConvertTo-ChatFreshVerdict ([pscustomobject]@{ Busy = $false; OldProcess = 'ended'; Outcome = 'ok'; HostPids = @(4242) }) | ConvertFrom-Json
Check 'Show it asked only to judge (-JudgeOnly): its idle process live, its window named, nothing ended - and the verdict says judged only' (
    $jo1.Outcome -eq 'ok' -and $jo1.OldProcess -eq 'live' -and (@($jo1.HostPids) -join ',') -eq '4242' -and -not $script:SfStops.Count -and
    $vjoO.judged -eq 'only' -and -not $vplain.PSObject.Properties['judged']) "$($jo1.OldProcess) $vjo"
# what the extension's parseVerdict takes: busy null or a boolean, a known
# oldProcess, an outcome, whole numbers for hostPids - an extra field is left alone
Check 'the judged-only verdict still reads as a verdict to an extension from before it: the same four fields, of the same types' (
    ($null -eq $vjoO.busy -or $vjoO.busy -is [bool]) -and $vjoO.oldProcess -in 'none', 'ended', 'live', 'held', 'other', 'kept' -and $vjoO.outcome -is [string] -and
    @(@($vjoO.hostPids) | Where-Object { $_ -isnot [int] -and $_ -isnot [long] }).Count -eq 0 -and $vjo -notmatch '[^\x20-\x7E]') $vjo
Clear-SfLive
Set-SfSession 1121
$script:SfStops.Clear()
$script:SfSleeps = 0
$script:ChatGraceSleepSeam = { param($ms) $script:SfSleeps++; if ($script:SfSleeps -eq 3) { Remove-Item -LiteralPath (Join-Path $sfSess '1121.json') -Force } }
$gl0 = & $sfLogN
$g1 = & $SfStop @(New-SfLive 1121) @{ GraceSeconds = 8 }
$glNew = @([System.IO.File]::ReadAllLines($sfLog, $utf8) | Select-Object -Skip $gl0)
Check 'with a grace: a process that leaves by itself as its tab closes counts as ended, nothing is taken down, and watcher.log says it left' (
    $g1.OldProcess -eq 'ended' -and -not $script:SfStops.Count -and $script:SfSleeps -eq 3 -and
    @($glNew | Where-Object { $_ -like '*show: idle chat process 1121 (5f5f5f5f) left by itself' }).Count -eq 1) "$($g1.OldProcess) $($script:SfSleeps) $($glNew -join ' | ')"
Set-SfSession 1122
$script:SfSleeps = 0
$script:ChatGraceSleepSeam = { param($ms) $script:SfSleeps++ }
$g2 = & $SfStop @(New-SfLive 1122) @{ GraceSeconds = 8 }
$g2Stops = $script:SfStops -join ','
$g2Sleeps = $script:SfSleeps
Set-SfSession 1122
$g0 = & $SfStop @(New-SfLive 1122) @{ GraceSeconds = 0 }
$script:ChatGraceSleepSeam = $null
Check 'one that stays through the 8 s is ended after them, not before; with no grace, at once' (
    $g2.OldProcess -eq 'ended' -and $g2Stops -eq '1122' -and $g2Sleeps -eq 32 -and $g0.OldProcess -eq 'ended' -and $script:SfSleeps -eq 32 -and
    ($script:SfStops -join ',') -eq '1122,1122') "$($g2.OldProcess) $g2Stops $g2Sleeps $($g0.OldProcess) $($script:SfStops -join ',')"
Clear-SfLive
# gone before the grace's first look - its file and its process: it left by
# itself, not kept; one still running with no file to check it by (this very
# process) is kept. The gone pid is a multiple of 4 no process has: Windows
# drops a pid's low two bits when it opens one, so under pwsh (.NET's
# OpenProcess) 1127 answered as 1124 whenever the runner had a 1124.
$sfLiveIds = @(Get-Process | ForEach-Object { $_.Id })
$sfGonePid = 61440
while ($sfGonePid -in $sfLiveIds) { $sfGonePid += 4 }
$script:SfStops.Clear()
$script:ChatGraceSleepSeam = { param($ms) $script:SfSleeps++ }
$gl3 = & $sfLogN
$g3 = & $SfStop @(New-SfLive $sfGonePid) @{ GraceSeconds = 8 }
$g4 = & $SfStop @(New-SfLive $PID) @{ GraceSeconds = 8 }
$script:ChatGraceSleepSeam = $null
$gl3New = @([System.IO.File]::ReadAllLines($sfLog, $utf8) | Select-Object -Skip $gl3)
Check 'with a grace: a process gone with its file before the first look left by itself (ended, said so); one running with no file is kept' (
    $g3.OldProcess -eq 'ended' -and $g4.OldProcess -eq 'kept' -and -not $script:SfStops.Count -and
    @($gl3New | Where-Object { $_ -like "*show: idle chat process $sfGonePid (5f5f5f5f) left by itself" }).Count -eq 1) "$($g3.OldProcess) $($g4.OldProcess) $($gl3New -join ' | ')"
$script:SfStops.Clear()
$script:ChatParentSeam = { param($e) if ($e.Pid -eq 1124) { @{ Pid = 5353; Name = 'Code'; StartTime = [datetime]::MinValue } } else { @{ Pid = 4242; Name = 'Code'; StartTime = [datetime]::MinValue } } }
Set-SfSession 1123
Set-SfSession 1124
$hp1 = & $SfStop @((New-SfLive 1123), (New-SfLive 1124)) @{ HostPid = 4242 }
$hp2 = @(Show-ChatFresh -Via button -HostPid 7777 -SessionId $idS -Cwd $projS -ConfigDir $sfHome)[-1]
$script:ChatParentSeam = $script:SeamsAtStart.Parent
Check '-HostPid: only that window''s process of the chat ended, another window''s left; a window holding none ends none' (
    $hp1.OldProcess -eq 'ended' -and ($script:SfStops -join ',') -eq '1123' -and (@($hp1.HostPids) -join ',') -eq '4242' -and
    $hp2.OldProcess -eq 'none' -and $script:SfStops.Count -eq 1) "$($hp1.OldProcess) $($script:SfStops -join ',') $($hp2.OldProcess)"
Clear-SfLive
$script:SfStops.Clear()
$sfNowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
Set-SfSession 1125
Set-SfSession 1126 'busy' -StartedAt $sfNowMs
$sfNew = New-SfLive 1126 'busy'
$sfNew.StartedAt = $sfNowMs
$sb1 = & $SfStop @((New-SfLive 1125), $sfNew) @{ StartedBefore = (Get-Date).AddSeconds(-5).ToUniversalTime().ToString('o') }
Check '-StartedBefore: the process a tab opened since is never ended, nor its loading turn taken for the chat''s - the old one is' (
    $sb1.OldProcess -eq 'ended' -and ($script:SfStops -join ',') -eq '1125') "$($sb1.OldProcess) $($script:SfStops -join ',')"
Clear-SfLive

# liveIdle stop, before the run, by the same checks
$cfgWas = [System.IO.File]::ReadAllText($script:ChatqConfigPath, $utf8)
$cfgS = Get-ChatqConfig
Set-ChatqProp $cfgS 'liveIdle' 'stop'
Save-ChatqJson $script:ChatqConfigPath $cfgS
Push-Location -LiteralPath $projS
$jS = New-TestJob 'Show fresh chat' 'stop first'
Pop-Location
Set-ChatqProp $jS 'home' $sfHome; Save-ChatqJob $jS
$script:SfStops.Clear()
Set-SfSession 1201
Set-SfAgents @(New-SfLive 1201)
Invoke-ChatqJob (New-ChatqWatchState) (Find-ChatqJob $jS.id)
$jS = Find-ChatqJob $jS.id
$rqS = [System.IO.File]::ReadAllText($script:ChatReloadPath, $utf8) | ConvertFrom-Json
Check 'liveIdle stop: the idle process ended once, the run done, and the window told' ($jS.state -eq 'done' -and ($script:SfStops -join ',') -eq '1201' -and
    $rqS.kind -eq 'ran' -and $rqS.sessionId -eq $idS -and $rqS.oldProcess -eq 'none') "$($jS.state) stops=$($script:SfStops -join ',') $($rqS.kind) $($rqS.oldProcess)"
Push-Location -LiteralPath $projS
$jS2 = New-TestJob 'Show fresh chat' 'not while it works'
Pop-Location
Set-ChatqProp $jS2 'home' $sfHome; Save-ChatqJob $jS2
Add-SfLaunch $pS 'wsf0002' (Get-Date).AddMinutes(-5)
Set-SfSession 1202
Set-SfAgents @(New-SfLive 1202)
$script:SfStops.Clear()
Invoke-ChatqJob (New-ChatqWatchState) (Find-ChatqJob $jS2.id)
$jS2 = Find-ChatqJob $jS2.id
Check 'liveIdle stop with a workflow in flight: the job waits, as for a busy chat, and nothing is ended' ($jS2.state -eq 'queued' -and $jS2.deferUntil -and -not $script:SfStops.Count) "$($jS2.state) $($jS2.deferUntil)"
$null = Remove-ChatqJob $jS2 'test'
Add-SfDone $pS 'wsf0002'
# Cancel clicked while liveIdle stop ends the process (the job running): the
# prompt never goes in - cancelled, not run
Push-Location -LiteralPath $projS
$jS3 = New-TestJob 'Show fresh chat' 'cancelled at the stop'
Pop-Location
Set-ChatqProp $jS3 'home' $sfHome; Save-ChatqJob $jS3
Set-SfSession 1203
Set-SfAgents @(New-SfLive 1203)
$script:SfStops.Clear()
$stopWas = $script:ChatStopSeam
$script:ChatStopSeam = { param($e) Save-ChatqText (Join-Path $script:ChatqQueueDir "$($jS3.id).cancel") 'cancel'; & $stopWas $e }
Invoke-ChatqJob (New-ChatqWatchState) (Find-ChatqJob $jS3.id)
$script:ChatStopSeam = $stopWas
$jS3 = Find-ChatqJob $jS3.id
Check 'liveIdle stop, cancelled meanwhile: failed as cancelled, the cancel file gone, the prompt never sent' (
    $jS3.state -eq 'failed' -and $jS3.result.reason -eq 'cancelled' -and ($script:SfStops -join ',') -eq '1203' -and
    -not (Test-Path -LiteralPath (Join-Path $script:ChatqQueueDir "$($jS3.id).cancel")) -and
    -not (Test-Path -LiteralPath (Join-Path $script:ChatqLogDir "$($jS3.id).jsonl"))) "$($jS3.state) $($jS3.result.reason) stops=$($script:SfStops -join ',')"
[System.IO.File]::WriteAllText($script:ChatqConfigPath, $cfgWas, $utf8)
Clear-SfLive

# Show-ChatFresh after a run
Set-SfSession 1301
Set-SfAgents @(New-SfLive 1301)
$script:SfStops.Clear()
$f1 = @(Show-ChatFresh -Via run -SessionId $idS -Cwd $projS -Title 'Show fresh chat' -ConfigDir $sfHome -Transcript $pS -Away $true)[-1]
$rq1 = [System.IO.File]::ReadAllText($script:ChatReloadPath, $utf8) | ConvertFrom-Json
Check 'after a run, nobody at the PC: nothing ended any more - live, and the request says so, naming its window' ($f1.OldProcess -eq 'live' -and $f1.Busy -eq $false -and
    -not $script:SfStops.Count -and $rq1.oldProcess -eq 'live' -and $rq1.busy -eq $false -and $rq1.away -eq $true -and (@($rq1.hostPids) -join ',') -eq '4242' -and
    $rq1.home -eq $sfHome -and -not $rq1.PSObject.Properties['jobId']) ($rq1 | ConvertTo-Json -Compress)
Set-SfSession 1302
Set-SfAgents @(New-SfLive 1302)
$script:SfStops.Clear()
$f2 = @(Show-ChatFresh -Via run -SessionId $idS -Cwd $projS -Title 'Show fresh chat' -ConfigDir $sfHome -Transcript $pS -Away $false)[-1]
Check 'someone at the PC: left running (live), nothing ended' ($f2.OldProcess -eq 'live' -and -not $script:SfStops.Count) $f2.OldProcess
Set-SfAgents @(New-SfLive 1302 'busy')
$f3 = @(Show-ChatFresh -Via run -SessionId $idS -Cwd $projS -Title 'Show fresh chat' -ConfigDir $sfHome -Transcript $pS -Away $true)[-1]
$rq3 = [System.IO.File]::ReadAllText($script:ChatReloadPath, $utf8) | ConvertFrom-Json
Check 'the chat itself working: held, and busy' ($f3.OldProcess -eq 'held' -and $f3.Busy -eq $true -and $rq3.busy -eq $true -and -not $script:SfStops.Count) "$($f3.OldProcess) $($f3.Busy)"
Clear-SfLive
# after a handover: the chat's process left with its tab, and the request
# names the window that closed it all the same, and the job
$env:FAKE_AGENTS = '[]'
$f6 = @(Show-ChatFresh -Via run -SessionId $idS -Cwd $projS -Title 'Show fresh chat' -ConfigDir $sfHome -Transcript $pS -Away $false -HandoverPids @(4242) -JobId 'job-after-handover')[-1]
$rq6 = [System.IO.File]::ReadAllText($script:ChatReloadPath, $utf8) | ConvertFrom-Json
Set-SfAgents @(New-SfLive 1303)
Set-SfSession 1303
$script:ChatParentSeam = { param($e) @{ Pid = 6161; Name = 'Code'; StartTime = [datetime]::MinValue } }
$f7 = @(Show-ChatFresh -Via run -SessionId $idS -Cwd $projS -Title 'Show fresh chat' -ConfigDir $sfHome -Transcript $pS -Away $false -HandoverPids @(4242) -JobId 'job-2')[-1]
$script:ChatParentSeam = $script:SeamsAtStart.Parent
$rq7 = [System.IO.File]::ReadAllText($script:ChatReloadPath, $utf8) | ConvertFrom-Json
Check 'after a handover the run''s request names the windows it asked when none holds the chat now, and the job; one that holds it still is named instead' (
    $f6.OldProcess -eq 'none' -and $rq6.oldProcess -eq 'none' -and (@($rq6.hostPids) -join ',') -eq '4242' -and $rq6.jobId -eq 'job-after-handover' -and
    $f7.OldProcess -eq 'live' -and (@($rq7.hostPids) -join ',') -eq '6161' -and $rq7.jobId -eq 'job-2') "$($rq6 | ConvertTo-Json -Compress) | $($rq7 | ConvertTo-Json -Compress)"
Clear-SfLive

# Background work, told apart by who started it, never by when. The run left
# a workflow behind in the chat that never reported back - it died with the
# headless process - and the window's own process started one of its own
# while the run went on.
Add-SfLaunch $pS 'wsf0003' (Get-Date).AddSeconds(-20) 'sdk-cli'
$i1 = Test-ChatIdle -Cwd $projS -Except $pS -Seconds 5 -ConfigDir $sfHome -Live @(New-SfLive 1310)
$i2 = Test-ChatIdle -Cwd $projS -Except $pS -Seconds 5 -ConfigDir $sfHome -Live @((New-SfLive 1310), (New-SfLive 1311 'idle' 'print'))
Check 'Test-ChatIdle: a print-mode run''s leftover work is dead once no such run is alive; while one is, it counts' ($i1 -eq $true -and $i2 -eq $false) "$i1 $i2"
Set-SfSession 1312
Set-SfAgents @(New-SfLive 1312)
$script:SfStops.Clear()
$f4 = @(Show-ChatFresh -Via run -SessionId $idS -Cwd $projS -Title 'Show fresh chat' -ConfigDir $sfHome -Transcript $pS -Away $true)[-1]
Check 'after a run that left work of its own behind: not held - live, not busy, nothing ended' ($f4.OldProcess -eq 'live' -and $f4.Busy -eq $false -and -not $script:SfStops.Count) "$($f4.OldProcess) $($f4.Busy)"
Clear-SfLive
Set-SfSession 1313
$script:SfStops.Clear()
$b1 = @(Show-ChatFresh -Via button -SessionId $idS -Cwd $projS -ConfigDir $sfHome)[-1]
Set-SfSession 1318
Set-SfAgents @(New-SfLive 1318)
$script:ChatWindowTitlesSeam = { @('notes.md - projS - Visual Studio Code') }
$c0 = @(Show-ChatFresh -Via chip -SessionId $idS -Cwd $projS -ConfigDir $sfHome)[-1]
$script:ChatWindowTitlesSeam = $script:SeamsAtStart.Titles
Remove-Item -LiteralPath $script:ChatOpenPath -Force -EA SilentlyContinue
Check 'Show it and the chip after such a run: the leftover holds nothing - Show it ends the process, the chip leaves it live, neither held' (
    $b1.Outcome -eq 'ok' -and $b1.OldProcess -eq 'ended' -and $c0.ExitCode -eq 0 -and $c0.OldProcess -eq 'live' -and ($script:SfStops -join ',') -eq '1313') "$($b1.OldProcess) $($c0.OldProcess) $($script:SfStops -join ',')"
Add-SfLaunch $pS 'wsf0004' (Get-Date).AddSeconds(-10) 'claude-vscode'
Set-SfSession 1314
Set-SfAgents @(New-SfLive 1314)
$script:SfStops.Clear()
$f5 = @(Show-ChatFresh -Via run -SessionId $idS -Cwd $projS -Title 'Show fresh chat' -ConfigDir $sfHome -Transcript $pS -Away $true)[-1]
Check 'a workflow the window''s process started during the run: held, busy, nothing ended' ($f5.OldProcess -eq 'held' -and $f5.Busy -eq $true -and -not $script:SfStops.Count) "$($f5.OldProcess) $($f5.Busy)"
Add-SfDone $pS 'wsf0003'
Add-SfDone $pS 'wsf0004'
Clear-SfLive

# Show it while a queued prompt goes into the chat - the next one queued
# for it, say - or any print-mode claude: nothing ended, nothing shown
Set-SfSession 1315
Push-Location -LiteralPath $projS
$jR2 = New-TestJob 'Show fresh chat' 'running while you click'
Pop-Location
Set-ChatqJobState $jR2 'running' 'test'
$script:SfStops.Clear()
$b2 = @(Show-ChatFresh -Via button -SessionId $idS -Cwd $projS -ConfigDir $sfHome)[-1]
Set-ChatqJobState $jR2 'queued' 'test'
$null = Remove-ChatqJob (Find-ChatqJob $jR2.id) 'test'
Set-SfSession 1316 'busy' 'print'
$b3 = @(Show-ChatFresh -Via button -SessionId $idS -Cwd $projS -ConfigDir $sfHome)[-1]
$vb2 = ConvertTo-ChatFreshVerdict $b2 | ConvertFrom-Json
Check 'Show it while a queued prompt runs into the chat, or a print-mode claude does: running, held, busy - nothing ended' (
    $b2.Outcome -eq 'running' -and $b2.OldProcess -eq 'held' -and $b2.Busy -eq $true -and $b3.Outcome -eq 'running' -and
    $vb2.outcome -eq 'running' -and -not $script:SfStops.Count) "$($b2.Outcome) $($b2.OldProcess) $($b3.Outcome) $($script:SfStops -join ',')"
Clear-SfLive
$b4 = @(Show-ChatFresh -Via button -SessionId '5e5e5e5e-5e5e-4e5e-8e5e-5e5e5e5e5e5e' -Cwd $projS -ConfigDir $sfHome)[-1]
Check 'a check that judged nothing (missing) does not say none of the process' ($b4.Outcome -eq 'missing' -and $b4.OldProcess -eq 'kept') "$($b4.Outcome) $($b4.OldProcess)"

# after a request for the chat, the next run into it waits the show out
$script:ChatShowHoldSeconds = 30
Write-ChatReloadRequest -Title 'Show fresh chat' -Cwd $projS -Kind 'ran' -Busy $false -Away $true -SessionId $idS -OldProcess 'ended'
$h1 = Get-ChatShowHold $idS
$h2 = Get-ChatShowHold '5e5e5e5e-5e5e-4e5e-8e5e-5e5e5e5e5e5e'
$h3 = Get-ChatShowHold $idS (Get-Date).AddSeconds(31)
Push-Location -LiteralPath $projS
$jH = New-TestJob 'Show fresh chat' 'right after the last'
Pop-Location
Set-ChatqProp $jH 'home' $sfHome; Save-ChatqJob $jH
Invoke-ChatqJob (New-ChatqWatchState) (Find-ChatqJob $jH.id)
$jH = Find-ChatqJob $jH.id
Write-ChatReloadRequest -Title 'another' -Cwd $projS -Kind 'deleted'
Write-ChatOpenRequest -SessionId $idS -Cwd $projS -Title 'Show fresh chat' -Busy $false -OldProcess 'ended'
$h4 = Get-ChatShowHold $idS
Remove-Item -LiteralPath $script:ChatOpenPath -Force
$script:ChatShowHoldSeconds = 0
Check 'a run into a chat a window was just asked to show waits 30 s, not counted as busy; another chat''s, or an older request, does not' (
    $h1 -and $null -eq $h2 -and $null -eq $h3 -and $h4 -and $jH.state -eq 'queued' -and -not $jH.startedAt -and -not $jH.deferredSince -and
    [int]$jH.attempts -eq 0 -and (ConvertTo-ChatqDate $jH.deferUntil) -gt (Get-Date).AddSeconds(20)) "$h1 $h2 $h3 $h4 $($jH.state) $($jH.deferUntil)"
$null = Remove-ChatqJob $jH 'test'

# Show-ChatFresh for the overlay's chip, with a VS Code window on exactly
# its folder, by that window's title
$exactTitles = { @('notes.md - projS - Visual Studio Code') }
$script:ChatWindowTitlesSeam = $exactTitles
$reloadBytes = [System.IO.File]::ReadAllBytes($script:ChatReloadPath)
Remove-Item -LiteralPath $script:ChatOpenPath -Force -EA SilentlyContinue
Set-SfSession 1401
Set-SfAgents @(New-SfLive 1401)
$script:SfCode.Clear()
$script:SfStops.Clear()
$wlPath = Join-Path $script:ChatqLogDir 'watcher.log'
$wlShow = { @(if (Test-Path -LiteralPath $wlPath) { [System.IO.File]::ReadAllLines($wlPath, $utf8) | Where-Object { $_ -like '*  show (*' } }) }
$wl0 = @(& $wlShow).Count
$c1 = @(Show-ChatFresh -Via chip -SessionId $idS -Cwd $projS -TitleB64 ([Convert]::ToBase64String($utf8.GetBytes($tSel))) -ConfigDir $sfHome)[-1]
$wl1 = @(& $wlShow)
$oBytes = [System.IO.File]::ReadAllBytes($script:ChatOpenPath)
$oq = [System.IO.File]::ReadAllText($script:ChatOpenPath, $utf8) | ConvertFrom-Json
$sameReload = [Convert]::ToBase64String($reloadBytes) -eq [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($script:ChatReloadPath))
Check 'the chip: data/open-request, no BOM, with the chat, its folder, title, verdict and window' ($c1.ExitCode -eq 0 -and $oBytes[0] -eq [byte][char]'{' -and
    $oq.kind -eq 'open' -and $oq.sessionId -eq $idS -and $oq.cwd -eq $projS -and $oq.title -eq $tSel -and $oq.oldProcess -eq 'live' -and $null -eq $oq.busy -and
    (@($oq.hostPids) -join ',') -eq '4242' -and $oq.id -and $oq.at) ($oq | ConvertTo-Json -Compress)
Check 'the chip ends nothing: its idle process left running (live), and busy not judged' (
    $c1.OldProcess -eq 'live' -and $null -eq $c1.Busy -and -not @($c1.Stopped).Count -and -not $script:SfStops.Count) "$($c1.OldProcess) $($c1.Busy) $($script:SfStops -join ',')"
Check 'watcher.log: one ASCII line for the show - how, which chat, the process, busy, the windows, the outcome' (
    $wl1.Count -eq $wl0 + 1 -and $wl1[-1] -like '*  show (chip) 5f5f5f5f: live, busy unjudged, hosts 4242 -> ok' -and $wl1[-1] -notmatch '[^\x20-\x7E]') "$($wl1.Count - $wl0): $(@($wl1)[-1])"
Check 'code is asked once, for the folder; a run''s request beside it is left byte for byte' (($script:SfCode -join '|') -eq $projS -and $sameReload) ($script:SfCode -join '|')
Remove-Item -LiteralPath $script:ChatOpenPath -Force
$script:SfCode.Clear()
Set-SfSession 1402
Set-SfAgents @(New-SfLive 1402)
$script:ChatParentSeam = $terminalParent
$c2 = @(Show-ChatFresh -Via chip -SessionId $idS -Cwd $projS -ConfigDir $sfHome)[-1]
$script:ChatParentSeam = $script:SeamsAtStart.Parent
Check 'the chip on a terminal''s chat: 20, nothing written, code not asked' ($c2.ExitCode -eq 20 -and -not (Test-Path -LiteralPath $script:ChatOpenPath) -and -not $script:SfCode.Count) $c2.ExitCode
# mid-turn in a terminal: whose it is comes before held, or a tab would open
# beside a terminal that is writing to the chat. The chip reads the registry
# alone, as the panel does: busy is said there
Set-SfSession 1402 'busy'
Set-SfAgents @(New-SfLive 1402 'busy')
$script:ChatParentSeam = $terminalParent
$c2b = @(Show-ChatFresh -Via chip -SessionId $idS -Cwd $projS -ConfigDir $sfHome)[-1]
$script:ChatParentSeam = $script:SeamsAtStart.Parent
Check 'the chip on a terminal''s chat mid-turn: other (20), not held - nothing written, code not asked' (
    $c2b.ExitCode -eq 20 -and $c2b.OldProcess -eq 'other' -and -not (Test-Path -LiteralPath $script:ChatOpenPath) -and -not $script:SfCode.Count) "$($c2b.ExitCode) $($c2b.OldProcess)"
$c3 = @(Show-ChatFresh -Via chip -SessionId $idS -Cwd $projS -ConfigDir $sfHome)[-1]
$oq3 = if (Test-Path -LiteralPath $script:ChatOpenPath) { [System.IO.File]::ReadAllText($script:ChatOpenPath, $utf8) | ConvertFrom-Json } else { $null }
Remove-Item -LiteralPath $script:ChatOpenPath -Force -EA SilentlyContinue
Check 'the chip on a window''s working chat: 10, a request to focus it naming its window, nothing ended' (
    $c3.ExitCode -eq 10 -and $c3.OldProcess -eq 'held' -and (@($c3.HostPids) -join ',') -eq '4242' -and $oq3 -and $oq3.oldProcess -eq 'held' -and
    (@($oq3.hostPids) -join ',') -eq '4242' -and -not $script:SfStops.Contains(1402)) "$($c3.ExitCode) $($c3.OldProcess) $($oq3 | ConvertTo-Json -Compress)"
Clear-SfLive
Push-Location -LiteralPath $projS
$jR = New-TestJob 'Show fresh chat' 'running now'
Pop-Location
Set-ChatqJobState $jR 'running' 'test'
$script:SfCode.Clear()
Remove-Item -LiteralPath $script:ChatOpenPath -Force -EA SilentlyContinue
$c4 = @(Show-ChatFresh -Via chip -SessionId $idS -Cwd $projS -ConfigDir $sfHome)[-1]
$wq4 = [System.IO.File]::ReadAllText($script:ChatOpenPath, $utf8) | ConvertFrom-Json
$code4 = $script:SfCode.Count
# a live view opening holds no run back, as a chat opening does
$script:ChatShowHoldSeconds = 30
$hold4 = Get-ChatShowHold $idS
$script:ChatShowHoldSeconds = 0
# the run's handover asked a window, and none is on exactly the folder
$null = Write-ChatRunState $jR 'running' @{ HostPids = @(4242); OldProcess = 'live'; HandoverId = 'h-test' }
$script:ChatWindowTitlesSeam = { @('notes.md - my-workspace (Workspace) - Visual Studio Code') }
$c4b = @(Show-ChatFresh -Via chip -SessionId $idS -Cwd $projS -ConfigDir $sfHome -TitleB64 ([Convert]::ToBase64String($utf8.GetBytes($tSel))))[-1]
$wq4b = [System.IO.File]::ReadAllText($script:ChatOpenPath, $utf8) | ConvertFrom-Json
$script:ChatWindowTitlesSeam = $exactTitles
$code4b = $script:SfCode.Count
Set-ChatqJobState $jR 'queued' 'test'
$null = Remove-ChatqJob (Find-ChatqJob $jR.id) 'test'
Remove-Item -LiteralPath $script:ChatOpenPath -Force -EA SilentlyContinue
Check 'the chip while a queued prompt runs in that chat: watch (16) - its live view asked for, by job, and the window brought forward' (
    $c4.ExitCode -eq 16 -and $c4.Outcome -eq 'watch' -and $wq4.kind -eq 'watch' -and $wq4.jobId -eq $jR.id -and [int]$wq4.seq -eq [int]$jR.seq -and
    $wq4.sessionId -eq $idS -and $wq4.cwd -eq $projS -and $wq4.title -eq 'Show fresh chat' -and $wq4.home -eq $sfHome -and @($wq4.hostPids).Count -eq 0 -and
    $wq4.id -and $wq4.at -and $code4 -eq 1 -and $null -eq $hold4) "$($c4.ExitCode) $($wq4 | ConvertTo-Json -Compress) code $code4 hold $hold4"
Check 'with the run''s handover window named and none exactly on the folder: that window in the request, and 25 - no code -n' (
    $c4b.ExitCode -eq 25 -and $wq4b.kind -eq 'watch' -and (@($wq4b.hostPids) -join ',') -eq '4242' -and $wq4b.title -eq $tSel -and $code4b -eq 1) "$($c4b.ExitCode) $($wq4b | ConvertTo-Json -Compress) code $code4b"
Set-SfAgents @(New-SfLive 1406 'busy' 'print')
# the chip reads the registry alone, where Claude Code 2.1.283 writes a
# claude -p as interactive, stamped sdk-cli
Set-SfSession 1406 'busy' 'interactive' 'sdk-cli'
$c4c = @(Show-ChatFresh -Via chip -SessionId $idS -Cwd $projS -ConfigDir $sfHome)[-1]
Check 'someone''s own claude -p going into it, no job of chatq''s: 15, as before - nothing asked of the window' (
    $c4c.ExitCode -eq 15 -and -not (Test-Path -LiteralPath $script:ChatOpenPath)) $c4c.ExitCode
Clear-SfLive
Set-SfSession 1403
Set-SfAgents @(New-SfLive 1403)
$script:SfCode.Clear()
$script:ChatWindowTitlesSeam = { @('notes.md - my-workspace (Workspace) - Visual Studio Code') }
$c5 = @(Show-ChatFresh -Via chip -SessionId $idS -Cwd $projS -ConfigDir $sfHome)[-1]
Set-SfSession 1404
Set-SfAgents @(New-SfLive 1404)
$script:ChatWindowTitlesSeam = $exactTitles
$c6 = @(Show-ChatFresh -Via chip -SessionId $idS -Cwd $projS -ConfigDir $sfHome)[-1]
Check 'held in a window, none exactly its folder: 25, and no code -n to open a second; one exactly it: code' (
    $c5.ExitCode -eq 25 -and $c6.ExitCode -eq 0 -and $script:SfCode.Count -eq 1) "$($c5.ExitCode) $($c6.ExitCode) $($script:SfCode.Count)"
Clear-SfLive
$c7 = @(Show-ChatFresh -Via chip -SessionId '5e5e5e5e-5e5e-4e5e-8e5e-5e5e5e5e5e5e' -Cwd $projS -ConfigDir $sfHome)[-1]
$script:ChatCodeSeam = { param($f) [pscustomobject]@{ Ok = $false; Code = 'no-code'; Why = 'none'; Slow = $false } }
$c8 = @(Show-ChatFresh -Via chip -SessionId $idS -Cwd $projS -ConfigDir $sfHome)[-1]
$script:ChatCodeSeam = $script:SeamsAtStart.Code
$wl2 = @(& $wlShow).Count
$c9 = @(Show-ChatFresh -Via chip -SessionId "x'; exit 0; '" -Cwd $projS -ConfigDir $sfHome)[-1]
$wl3 = @(& $wlShow).Count
$script:ChatWindowTitlesSeam = $script:SeamsAtStart.Titles
Check 'a chat not started yet: 30; no code command: 40; no session id: 50, and no line in watcher.log for it' (
    $c7.ExitCode -eq 30 -and $c8.ExitCode -eq 40 -and $c9.ExitCode -eq 50 -and $wl3 -eq $wl2) "$($c7.ExitCode) $($c8.ExitCode) $($c9.ExitCode) $wl2 $wl3"
$v = ConvertTo-ChatFreshVerdict ([pscustomobject]@{ Busy = $false; OldProcess = 'ended'; Outcome = 'ok'; HostPids = @(1234) })
$vo = $v | ConvertFrom-Json
Check 'Show it''s verdict: one ASCII line, the four fields' ($v -notmatch '[^\x20-\x7E]' -and $vo.busy -eq $false -and $vo.oldProcess -eq 'ended' -and $vo.outcome -eq 'ok' -and
    (@($vo.hostPids) -join ',') -eq '1234' -and (ConvertTo-ChatFreshVerdict ([pscustomobject]@{ Busy = $null; OldProcess = 'none'; Outcome = 'ok'; HostPids = @() })) -eq '{"busy":null,"oldProcess":"none","outcome":"ok","hostPids":[]}') $v

# a queued run end to end, and what the alert says
$lastAlert = { @([System.IO.File]::ReadAllLines((Join-Path $script:ChatqLogDir 'alerts.log'), $utf8) | Where-Object { $_ -match "`tdone`t" })[-1] }
$runS = {
    param([string]$Say)
    Push-Location -LiteralPath $projS
    $j = New-TestJob 'Show fresh chat' $Say
    Pop-Location
    Set-ChatqProp $j 'home' $sfHome; Save-ChatqJob $j
    Invoke-ChatqJob (New-ChatqWatchState) (Find-ChatqJob $j.id)
    return (Find-ChatqJob $j.id)
}
$script:SfStops.Clear()
Set-SfSession 1501
Set-SfAgents @(New-SfLive 1501)
$e1 = & $runS 'nobody here'
$rqE = [System.IO.File]::ReadAllText($script:ChatReloadPath, $utf8) | ConvertFrom-Json
$a1 = & $lastAlert
Check 'a run into a chat a window holds, nobody at the PC: its process left running - the window closes its tab first - and the request names the chat, its window and the job' (
    $e1.state -eq 'done' -and -not $script:SfStops.Count -and $rqE.sessionId -eq $idS -and $rqE.oldProcess -eq 'live' -and (@($rqE.hostPids) -join ',') -eq '4242' -and
    $rqE.jobId -eq $e1.id) ($rqE | ConvertTo-Json -Compress)
Check 'and the alert says to show it before typing' ($a1 -like '*Show it in VS Code before typing*') $a1
Clear-SfLive
$script:ChatqIdleSeam = 30
Set-SfSession 1502
Set-SfAgents @(New-SfLive 1502)
$script:SfStops.Clear()
$null = & $runS 'someone here'
$a2 = & $lastAlert
$script:ChatqIdleSeam = 99999
Check 'someone at the PC: left running, and the alert says to show it before typing' ($a2 -like '*before typing*' -and -not $script:SfStops.Count) $a2
Clear-SfLive
Set-SfSession 1503
Set-SfAgents @(New-SfLive 1503)
$script:ChatParentSeam = $terminalParent
$null = & $runS 'terminal'
$script:ChatParentSeam = $script:SeamsAtStart.Parent
$a3 = & $lastAlert
Check 'open in a terminal: the alert says to type there' ($a3 -like '*open in a terminal too*') $a3
Clear-SfLive
# nothing held the chat as the run began, but a window opened it meanwhile:
# the fake run writes that window's process into the registry as it goes,
# and claude agents lists it from then on
Remove-Item -LiteralPath $script:ChatReloadPath -Force -EA SilentlyContinue
$env:FAKE_AGENTS_FILE = Join-Path $sb 'agents-late.json'
Remove-Item -LiteralPath $env:FAKE_AGENTS_FILE -Force -EA SilentlyContinue
$env:FAKE_REGISTER = Join-Path $sfSess '1504.json'
$env:FAKE_REGISTER_BODY = ([ordered]@{ pid = 1504; sessionId = $idS; cwd = $projS; startedAt = 0; kind = 'interactive'; entrypoint = 'claude-vscode'
        pidDomain = "win32:$([Environment]::MachineName)"; status = 'idle'; updatedAt = 0 } | ConvertTo-Json -Compress).Replace('"startedAt":0', '"startedAt":{{NOW}}')
$script:SfStops.Clear()
$e4 = & $runS 'opened meanwhile'
Remove-Item -LiteralPath $env:FAKE_AGENTS_FILE -Force -EA SilentlyContinue
Remove-Item env:FAKE_REGISTER, env:FAKE_REGISTER_BODY, env:FAKE_AGENTS_FILE
$rqL = if (Test-Path -LiteralPath $script:ChatReloadPath) { [System.IO.File]::ReadAllText($script:ChatReloadPath, $utf8) | ConvertFrom-Json } else { $null }
$a4 = & $lastAlert
Check 'a window that opened the chat during the run: treated as holding it - its process left to the window, the window told, the alert says so' (
    $e4.state -eq 'done' -and $rqL -and $rqL.kind -eq 'ran' -and $rqL.sessionId -eq $idS -and $rqL.oldProcess -eq 'live' -and
    -not $script:SfStops.Count -and $a4 -like '*Show it in VS Code*') "$($e4.state) $($rqL | ConvertTo-Json -Compress) $($script:SfStops -join ',') $a4"
# that window's process, gone as a closed tab's would be
Remove-Item -LiteralPath (Join-Path $sfSess '1504.json') -Force -EA SilentlyContinue
# one in the registry from before the run, which claude agents did not list
# (another chat's is all it names): not opened meanwhile, so not this
Set-SfSession 1505
$env:FAKE_AGENTS = '[{"pid":77,"sessionId":"00000000-0000-4000-8000-000000000077","kind":"interactive","status":"idle","startedAt":0}]'
$script:SfStops.Clear()
$null = & $runS 'opened before'
$rqN = if (Test-Path -LiteralPath $script:ChatReloadPath) { [System.IO.File]::ReadAllText($script:ChatReloadPath, $utf8) | ConvertFrom-Json } else { $null }
Check 'one open from before that nothing reported live is no late opener: no request' (-not ($rqN -and $rqN.kind -eq 'ran' -and $rqN.id -ne $rqL.id) -and -not $script:SfStops.Count) ($rqN | ConvertTo-Json -Compress)
Clear-SfLive

# the code CLI: what it inherits, how it is started, where it is found
$drops = @(Get-ChatCodeEnvDrops @('PATH', 'CLAUDE_CONFIG_DIR', 'VSCODE_PID', 'vscode_cwd', 'ELECTRON_RUN_AS_NODE', 'electron_no_attach_console'))
Check 'code: VS Code''s and Electron''s variables dropped, in any case; the rest kept' (($drops -join ',') -eq 'VSCODE_PID,vscode_cwd,ELECTRON_RUN_AS_NODE,electron_no_attach_console') ($drops -join ',')
$lc = Get-ChatCodeLaunch 'C:\VS Code\bin\code.cmd' 'D:\a & b' $true
$lp = Get-ChatCodeLaunch 'C:\VS Code\bin\code.cmd' 'D:\100%' $true
$lx = Get-ChatCodeLaunch 'C:\VS Code\Code.exe' 'D:\a b' $true
Check 'code.cmd through cmd, & kept literal; a % refused; an .exe started itself, with -n' (
    $lc.Exe -like '*cmd*' -and $lc.Arguments -eq '/d /s /v:off /c ""C:\VS Code\bin\code.cmd" -n "D:\a & b""' -and $null -eq $lp -and
    $lx.Exe -eq 'C:\VS Code\Code.exe' -and $lx.Arguments -eq '-n "D:\a b"') "$($lc.Arguments) | $($lx.Arguments)"
$env:CHATQ_CODE = 'C:\x\code.cmd'
$fc1 = Find-ChatCodeCommand
Remove-Item env:CHATQ_CODE
$pfWas = $env:ProgramFiles; $laWas = $env:LOCALAPPDATA; $pathWas = $env:PATH
$pfS = Join-Path $sb 'pf'
$null = New-Item -ItemType Directory -Path (Join-Path $pfS 'Microsoft VS Code\bin') -Force
[System.IO.File]::WriteAllText((Join-Path $pfS 'Microsoft VS Code\bin\code.cmd'), '@echo off', $utf8)
$env:ProgramFiles = $pfS; $env:LOCALAPPDATA = Join-Path $sb 'no-local'; $env:PATH = Join-Path $env:SystemRoot 'System32'
try { $fc2 = Find-ChatCodeCommand } finally { $env:ProgramFiles = $pfWas; $env:LOCALAPPDATA = $laWas; $env:PATH = $pathWas }
Check 'code found: CHATQ_CODE first, else where the system installer puts it' ($fc1 -eq 'C:\x\code.cmd' -and $fc2 -eq (Join-Path $pfS 'Microsoft VS Code\bin\code.cmd')) "$fc1 | $fc2"
# two installs, as on the machine this was found on: the one running wins
# over PATH and the installers' places, and a Code.exe with no bin\ beside
# it is passed over
$codeRun = Join-Path $sb 'code-running'
$null = New-Item -ItemType Directory -Path (Join-Path $codeRun 'bin') -Force
[System.IO.File]::WriteAllText((Join-Path $codeRun 'bin\code.cmd'), '@echo off', $utf8)
$env:ProgramFiles = $pfS; $env:LOCALAPPDATA = Join-Path $sb 'no-local'; $env:PATH = Join-Path $env:SystemRoot 'System32'
try {
    $script:ChatCodeExesSeam = { @((Join-Path $sb 'code-bare\Code.exe'), (Join-Path $codeRun 'Code.exe')) }
    $fc3 = Find-ChatCodeCommand
    $script:ChatCodeExesSeam = { @(Join-Path $sb 'code-bare\Code.exe') }
    $fc4 = Find-ChatCodeCommand
}
finally { $env:ProgramFiles = $pfWas; $env:LOCALAPPDATA = $laWas; $env:PATH = $pathWas; $script:ChatCodeExesSeam = { @() } }
Check 'code found beside the running Code.exe first; one with no bin\ beside it passed over' ($fc3 -eq (Join-Path $codeRun 'bin\code.cmd') -and $fc4 -eq (Join-Path $pfS 'Microsoft VS Code\bin\code.cmd')) "$fc3 | $fc4"

# the chip's child: every value quoted, the title only as base64
$script:SfSpawn = $null
$script:ChatShowSpawnSeam = { param($c) $script:SfSpawn = $c; 'spawned' }
$Hs = @{ Ctx = @{ ClaudeHome = $sfHome } }
$evil = "Evil'; Remove-Item x; '"
$rowS = { param($cwd, $sid = $idS) [pscustomobject]@{ provider = 'claude'; sessionId = $sid; cwd = $cwd; title = $evil; key = "s:$sid" } }
$sp1 = Start-ChatShowFreshProcess $Hs (& $rowS "D:\it's here")
$cmd1 = $script:SfSpawn
$sp2 = Start-ChatShowFreshProcess $Hs (& $rowS "D:\it$([char]0x2019)s here")
$cmd2 = $script:SfSpawn
$script:SfSpawn = $null
$sp3 = Start-ChatShowFreshProcess $Hs (& $rowS 'D:\p' 'not-a-guid')
$script:ChatShowSpawnSeam = { param($c) $null }
Check 'the chip''s child: quotes doubled, curly ones too; the title only as base64; marked as the overlay, exiting with the outcome' (
    $sp1 -eq 'spawned' -and $cmd1 -like "*-Cwd 'D:\it''s here'*" -and $cmd2 -like "*-Cwd 'D:\it$([char]0x2019)$([char]0x2019)s here'*" -and
    $cmd1 -notlike '*Remove-Item*' -and $cmd1 -like "*-TitleB64 '$([Convert]::ToBase64String($utf8.GetBytes($evil)))'*" -and
    $cmd1.StartsWith("`$env:CHATQ_OVERLAY='1'") -and $cmd1.EndsWith('exit [int]$r.ExitCode') -and $null -eq $sp3 -and $null -eq $script:SfSpawn) $cmd1

# the chip's timing, placing and rows - the pure parts
$tg = { param($shown, $under, $rest, $onChip, $since, $down, $blocked, $spent, $delay = 1000) Get-ChatOverlayChipTarget $shown $under $rest $onChip $since $down $blocked $spent $delay }
Check 'the chip: after a 1 s rest on a row, not before, and not on a sweep' (
    (& $tg '' 's:a' 900 $false 99999 $false $false '' 1000) -eq '' -and (& $tg '' 's:a' 1000 $false 99999 $false $false '' 1000) -eq 's:a' -and
    (& $tg '' 's:a' 0 $false 99999 $false $false '' 1000) -eq '')
Check 'shown: kept on it, gone at once on another row, which gets its own after its rest' (
    (& $tg 's:a' 's:b' 0 $true 0 $false $false 's:a' 1000) -eq 's:a' -and (& $tg 's:a' 's:b' 0 $false 0 $false $false 's:a' 1000) -eq '' -and
    (& $tg '' 's:b' 1000 $false 99999 $false $false 's:a' 1000) -eq 's:b')
Check 'the chip''s rest is 400 ms unless set - the config''s default too' (
    (Get-ChatOverlayChipTarget '' 's:a' 399 $false 99999 $false $false '') -eq '' -and (Get-ChatOverlayChipTarget '' 's:a' 400 $false 99999 $false $false '') -eq 's:a' -and
    (Get-ChatOverlayConfig ([pscustomobject]@{})).chipDelayMs -eq 400)
$cdLo = (Get-ChatOverlayConfig ([pscustomobject]@{ overlay = [pscustomobject]@{ chipDelayMs = 20 } })).chipDelayMs
$cdHi = (Get-ChatOverlayConfig ([pscustomobject]@{ overlay = [pscustomobject]@{ chipDelayMs = 9000 } })).chipDelayMs
$cdSet = (Get-ChatOverlayConfig ([pscustomobject]@{ overlay = [pscustomobject]@{ chipDelayMs = 250 } })).chipDelayMs
Check 'a rest set in config.json: 250 ms comes at 250, not before; held to 100 to 3000' (
    (& $tg '' 's:a' 249 $false 99999 $false $false '' $cdSet) -eq '' -and (& $tg '' 's:a' 250 $false 99999 $false $false '' $cdSet) -eq 's:a' -and
    $cdLo -eq 100 -and $cdHi -eq 3000) "$cdSet $cdLo $cdHi"
Check 'off everything: kept 300 ms, then gone' ((& $tg 's:a' '' 0 $false 200 $false $false 's:a') -eq 's:a' -and (& $tg 's:a' '' 0 $false 400 $false $false 's:a') -eq '')
Check 'never with a button held, collapsed or mid-drag, or twice on one visit to a row' (
    (& $tg '' 's:a' 5000 $false 99999 $true $false '') -eq '' -and (& $tg 's:a' 's:a' 5000 $true 0 $false $true 's:a') -eq '' -and
    (& $tg '' 's:a' 5000 $false 99999 $false $false 's:a') -eq '')
$tN = Get-Date
$S = @{ ChipUnder = $null; ChipUnderAt = $null; ChipLastPos = '5,5'; ChipKey = $null; ChipSpent = $null; ChipArmed = $false; ChipOverAt = $null }
Step-ChatOverlayChipState $S 's:a' '5,5' $false $tN
$still = $null -eq $S.ChipUnderAt
Step-ChatOverlayChipState $S 's:a' '6,5' $false $tN.AddSeconds(1)
$movedOn = $S.ChipUnderAt -eq $tN.AddSeconds(1)
Step-ChatOverlayChipState $S 's:b' '7,5' $false $tN.AddSeconds(2)
Check 'the rest starts when the pointer moves onto a row; rows redrawn under a still one start nothing' ($still -and $movedOn -and $S.ChipUnderAt -eq $tN.AddSeconds(2)) "$still $movedOn"
$S.ChipKey = 's:b'; $S.ChipSpent = 's:b'; $S.ChipArmed = $false
Step-ChatOverlayChipState $S 's:b' '7,5' $true $tN.AddSeconds(3)
$unarmed = -not $S.ChipArmed
Step-ChatOverlayChipState $S 's:b' '8,5' $false $tN.AddSeconds(4)
$armed = $S.ChipArmed
Step-ChatOverlayChipState $S '' '99,5' $false $tN.AddSeconds(5)
Check 'a chip that came up under the pointer takes no click until the pointer has been off it; leaving the row frees it for the next visit' ($unarmed -and $armed -and $null -eq $S.ChipSpent) "$unarmed $armed $($S.ChipSpent)"
$rr = @([pscustomobject]@{ Key = 's:a'; Rect = @(10, 20, 100, 30) })
Check 'a row under the pointer: its last pixel in, the next out' ((Find-ChatOverlayRowAt ([pscustomobject]@{ X = 109; Y = 49 }) $rr).Key -eq 's:a' -and
    $null -eq (Find-ChatOverlayRowAt ([pscustomobject]@{ X = 110; Y = 49 }) $rr) -and $null -eq (Find-ChatOverlayRowAt ([pscustomobject]@{ X = 109; Y = 50 }) $rr))
$scrS = [pscustomobject]@{ X = 0; Y = 0; Width = 1920; Height = 1040 }
$cp1 = Get-ChatOverlayChipPlacement @(1524, 200, 380, 20) @(40, 18) $scrS
$cp2 = Get-ChatOverlayChipPlacement @(1900, 1030, 380, 20) @(40, 18) $scrS
Check 'the chip flush with its row''s right end, centred on it, and kept on the screen' ($cp1.X -eq 1864 -and $cp1.Y -eq 201 -and $cp2.X -eq 1880 -and $cp2.Y -eq 1022) "$($cp1.X),$($cp1.Y) $($cp2.X),$($cp2.Y)"
Check 'only a Claude chat with an id and a folder gets one' ((Test-ChatOverlayRowOpenable (& $rowS 'C:\p')) -and
    -not (Test-ChatOverlayRowOpenable ([pscustomobject]@{ provider = 'codex'; sessionId = $idS; cwd = 'C:\p' })) -and
    -not (Test-ChatOverlayRowOpenable (& $rowS 'C:\p' 'j:1')) -and -not (Test-ChatOverlayRowOpenable (& $rowS '')) -and -not (Test-ChatOverlayRowOpenable $null))
Check 'the tray''s words for how an open went: every end but 0 says something - held, a bad id or folder, and a code it does not know (a crash) too' (
    (Get-ChatOverlayOpenBalloon 20) -like '*open in a terminal*' -and (Get-ChatOverlayOpenBalloon 25) -like '*bring it forward yourself*' -and
    $null -eq (Get-ChatOverlayOpenBalloon 0) -and (Get-ChatOverlayOpenBalloon 10) -like '*at work*' -and (Get-ChatOverlayOpenBalloon 50) -like 'Not opened*' -and
    (Get-ChatOverlayOpenBalloon 1) -like '*code 1*' -and (Get-ChatOverlayOpenBalloon -1) -like '*code -1*')
$osB = Get-ChatOverlayOpenSay 'A chat' 'busy' -Seconds 7
$osOk = Get-ChatOverlayOpenSay 'A chat' 'done' 0
$osF = Get-ChatOverlayOpenSay 'A chat' 'done' 20
$osL = Get-ChatOverlayOpenSay 'A chat' 'late'
$osN = Get-ChatOverlayOpenSay 'A chat' 'nostart'
Check 'the panel''s line for an open: busy with its seconds, kept while it runs; opened, briefly; a failure, a timeout or a child that did not start said in warn''s tone, and kept longer' (
    $osB.Text -eq "opening 'A chat' - 7s" -and $osB.Tone -eq 'dim' -and $osB.Keep -eq 0 -and $osOk.Text -eq "opened 'A chat'" -and $osOk.Keep -eq 5 -and
    $osF.Text -like "'A chat' - *terminal*" -and $osF.Tone -eq 'warn' -and $osL.Text -like '*no answer in 60 s*' -and $osL.Tone -eq 'warn' -and
    $osN.Text -like '*did not start*' -and $osN.Tone -eq 'warn' -and $osF.Keep -gt $osOk.Keep) "$($osB.Text) / $($osOk.Text) / $($osF.Text) / $($osL.Text) / $($osN.Text)"
Check 'a window exactly on the folder, from its title' ((Test-ChatWindowExact 'D:\w\projS' @('a.ps1 - projS - Visual Studio Code')) -and
    (Test-ChatWindowExact 'D:\w\projS' @('projS - Visual Studio Code [Administrator]')) -and -not (Test-ChatWindowExact 'D:\w\projS' @('a.ps1 - projS-Mobile - Visual Studio Code')) -and
    -not (Test-ChatWindowExact 'D:\w\projS' @('x - ws (Workspace) - Visual Studio Code')))
Check 'with a profile other than Default, its name after the folder''s: still exactly it - only a real profile''s name is taken off' (
    (Test-ChatWindowExact 'D:\w\projS' @('a.ps1 - projS - Work - Visual Studio Code') @('Work')) -and
    (Test-ChatWindowExact 'D:\w\projS' @('projS - Work - Visual Studio Code') @('Work')) -and
    -not (Test-ChatWindowExact 'D:\w\projS' @('a.ps1 - projS - Work - Visual Studio Code')) -and
    -not (Test-ChatWindowExact 'D:\w\projS' @('projS - ws (Workspace) - Visual Studio Code') @('Work')) -and
    (Test-ChatWindowExact 'D:\w\projS' @('a.ps1 - projS - Visual Studio Code') @('Work')))
$apWas = $env:APPDATA
$apS = Join-Path $sb 'appdata'
$null = New-Item -ItemType Directory -Path (Join-Path $apS 'Code\User\globalStorage') -Force
[System.IO.File]::WriteAllText((Join-Path $apS 'Code\User\globalStorage\storage.json'),
    '{"userDataProfilesMigration":true,"userDataProfiles":[{"location":"a1b2","name":"Work"},{"location":"c3d4","name":"Play","icon":"x"}]}', $utf8)
$script:ChatCodeProfilesSeam = $null
$env:APPDATA = $apS
try { $profS = @(Get-ChatCodeProfileNames) } finally { $env:APPDATA = $apWas; $script:ChatCodeProfilesSeam = { @() } }
Check 'VS Code''s profile names, read from its storage.json' (($profS -join ',') -eq 'Work,Play') ($profS -join ',')
$script:ChatCodeProfilesSeam = { @('Work') }
$script:ChatWindowTitlesSeam = { @('notes.md - projS - Work - Visual Studio Code') }
Set-SfSession 1405
Set-SfAgents @(New-SfLive 1405)
$script:SfCode.Clear()
$script:ChatCodeSeam = { param($f) $script:SfCode.Add($f); [pscustomobject]@{ Ok = $true; Code = 'ok'; Why = $null; Slow = $false } }
$c10 = @(Show-ChatFresh -Via chip -SessionId $idS -Cwd $projS -ConfigDir $sfHome)[-1]
$script:ChatCodeSeam = $script:SeamsAtStart.Code
$script:ChatWindowTitlesSeam = $script:SeamsAtStart.Titles
$script:ChatCodeProfilesSeam = { @() }
Remove-Item -LiteralPath $script:ChatOpenPath -Force -EA SilentlyContinue
Clear-SfLive
Check 'the chip on a chat whose window has a profile: the window brought forward, not 25' ($c10.ExitCode -eq 0 -and $script:SfCode.Count -eq 1) "$($c10.ExitCode) $($script:SfCode.Count)"

# the chip itself, built and shown off every screen, in the STA process WPF needs
$chipWpf = @"
`$env:CHATQ_OVERLAY = '1'
. '$(Join-Path $sb 'tool\Charlie-and-the-chat-factory.ps1')'
Set-StrictMode -Off
Initialize-ChatOverlayNative
`$H = New-ChatOverlayHostState
`$script:ChatOverlayHost = `$H
`$H.Ctx = New-ChatOverlayContext
`$H.State = [pscustomobject]@{ x = `$null; y = `$null; locked = `$true; hidden = `$false }
New-ChatOverlayWindow `$H
`$mk = { param(`$sid, `$t) [pscustomobject]@{ key = "s:`$sid"; kind = 'session'; provider = 'claude'; status = 'idle'; rank = 3; project = 'p'; title = `$t; prompt = `$null; stateText = 'idle 1m'; job = `$null; sessionId = `$sid; cwd = 'C:\p' } }
`$rows = @((& `$mk '11111111-1111-4111-8111-111111111111' 'one'), (& `$mk '22222222-2222-4222-8222-222222222222' 'two'))
`$none = [pscustomobject]@{ usage = @(); notes = @() }
`$H.Ctx.ViewSig = 'a'
Update-ChatOverlayView `$H ([pscustomobject]@{ header = `$none; rows = `$rows })
`$tagged = @(`$H.Stack.Children | Where-Object { `$_.Tag -and `$_.Tag.key }).Count
`$H.Placed = `$true
`$script:ChatOverlayWorkAreaSeam = { param(`$r) [pscustomobject]@{ X = -4000; Y = 0; Width = 1920; Height = 1020 } }
Set-ChatOverlayHidden `$H `$false
[ChatOverlayNative]::MoveTo(`$H.Hwnd, -2594, 197)
`$H.Win.UpdateLayout()
`$rects = @(Get-ChatOverlayRowRects `$H)
`$away = [System.Drawing.Point]::new(-9000, -9000)
Show-ChatOverlayChip `$H `$rects[0] `$away
`$cx = [ChatOverlayNative]::GetExStyle(`$H.ChipHwnd)
`$cr = [ChatOverlayNative]::GetRect(`$H.ChipHwnd)
`$ln = `$rects[0].Line
`$flush = [Math]::Abs((`$cr[0] + `$cr[2]) - (`$ln[0] + `$ln[2])) -le 1
`$shown = `$H.ChipWin.IsVisible -and `$H.ChipKey -eq `$rows[0].key -and `$H.ChipArmed
`$H.Ctx.ViewSig = 'b'
Update-ChatOverlayView `$H ([pscustomobject]@{ header = `$none; rows = @(`$rows[1]) })
`$dropped = -not `$H.ChipWin.IsVisible -and -not `$H.ChipKey
`$rects = @(Get-ChatOverlayRowRects `$H)
Show-ChatOverlayChip `$H `$rects[0] `$away
`$again = `$H.ChipWin.IsVisible
Set-ChatOverlayHidden `$H `$true
`$hid = -not `$H.ChipWin.IsVisible -and -not `$H.ChipKey
'{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}' -f `$tagged, `$cx, `$flush, `$shown, `$dropped, `$again, `$hid, "rects `$(@(`$rects).Count) line `$(`$ln -join ',') chip `$(`$cr -join ',')"
"@
$chipOut = Invoke-Sta 'chip-test' $chipWpf
$ch = "$chipOut" -split '\|'
$chx = if ($ch.Count -ge 2 -and $ch[1] -match '^\d+$') { [int64]$ch[1] } else { 0 }
Check 'each drawn row carries its row, for the chip to find' ($ch[0] -eq '2') "$chipOut"
Check 'the chip takes clicks but never focus, and is in neither Alt+Tab nor the taskbar' ((($chx -band 0x8080080) -eq 0x8080080) -and -not ($chx -band 0x20) -and -not ($chx -band 0x40000)) ('0x{0:X} {1}' -f $chx, "$chipOut")
Check 'it sits flush with its row''s right end, armed when the pointer is elsewhere' ($ch[2] -eq 'True' -and $ch[3] -eq 'True') "$chipOut"
Check 'a redraw without its row takes it away; hiding the panel takes it too' ($ch[4] -eq 'True' -and $ch[5] -eq 'True' -and $ch[6] -eq 'True') "$chipOut"

$script:ChatStopSeam = $script:SeamsAtStart.Stop
$script:ChatParentSeam = $script:SeamsAtStart.Parent
$script:ChatCodeSeam = $script:SeamsAtStart.Code
$script:ChatqAliveSeam = $null
Clear-SfLive
