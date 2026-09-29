# tests/sections/handover.ps1: dot-sourced by tests/run-tests.ps1 in its turn,
# never on its own - it uses what the runner and the sections before it set.

Section 'handover: the run takes the tab''s place'
# A chat in a folder of its own, its processes in a Claude home of their own:
# the registry there, and the same entries as claude agents lists them. The
# extension's part is the run-state seam: it records each write, with the
# job's state on disk at that moment, and answers a handover as the test
# says - taking the chat's process away, as a closed tab does, when told.
$projH = Join-Path (Join-Path $sb 'work') 'projH'
$null = New-Item -ItemType Directory -Path $projH -Force
$idH = '6a6a6a6a-6a6a-4a6a-8a6a-6a6a6a6a6a6a'
$pH = New-FakeChat $projH $idH 'Handover chat' 1 @('first thing')
$idHB = '6b6b6b6b-6b6b-4b6b-8b6b-6b6b6b6b6b6b'
$pHB = New-FakeChat $projH $idHB 'Background wait chat' 1 @('start the suite')
$null = @(Sync-ChatIndex)
$hHome = Join-Path $sb 'claude-h'
$hSess = Join-Path $hHome 'sessions'
$null = New-Item -ItemType Directory -Path $hSess -Force
$script:ChatqAliveSeam = { param($e) $true }
$hStart = [DateTimeOffset]::UtcNow.AddMinutes(-60).ToUnixTimeMilliseconds()
function Set-HSession([int]$ProcId, [string]$Status = 'idle', [string]$Sid = $idH) {
    $o = [ordered]@{ pid = $ProcId; sessionId = $Sid; cwd = $projH; startedAt = $hStart; kind = 'interactive'; entrypoint = 'claude-vscode'
        pidDomain = "win32:$([Environment]::MachineName)"; status = $Status; updatedAt = $hStart }
    [System.IO.File]::WriteAllText((Join-Path $hSess "$ProcId.json"), ($o | ConvertTo-Json -Compress), $utf8)
}
function Set-HLive([int]$ProcId, [string]$Sid = $idH) {
    # the process in the registry, and claude agents listing it
    Set-HSession $ProcId 'idle' $Sid
    $env:FAKE_AGENTS = '[' + ([ordered]@{ pid = $ProcId; sessionId = $Sid; kind = 'interactive'; status = 'idle'; startedAt = $hStart; entrypoint = 'claude-vscode' } | ConvertTo-Json -Compress) + ']'
}
function Clear-HLive { Remove-Item env:FAKE_AGENTS -EA SilentlyContinue; Get-ChildItem -LiteralPath $hSess -File | Remove-Item -Force }
$script:HStates = [System.Collections.Generic.List[object]]::new()
$script:HAnswer = $null
$script:HLeave = $true
$script:HBusy = $false
$script:HThrow = $false
$script:HCancel = $false
$script:ChatRunStateSeam = {
    param($s)
    $jd = Find-ChatqJob ([string]$s.jobId) -Exact
    $script:HStates.Add([pscustomobject]@{ Phase = $s.phase; JobState = $(if ($jd) { [string]$jd.state } else { $null }); State = $s })
    if ($s.phase -eq 'handover') {
        # Cancel clicked while the windows are asked: Stop-ChatqJobRun's file,
        # as it writes it for a job it finds running under a live watcher
        if ($script:HCancel -and $jd.state -eq 'running') { Save-ChatqText (Join-Path $script:ChatqQueueDir "$($s.jobId).cancel") 'cancel' }
        if ($script:HAnswer) {
            New-Item -ItemType Directory -Path $script:ChatRunAckDir -Force | Out-Null
            foreach ($hp in @($s.hostPids)) {
                $ack = [ordered]@{ id = $s.id; answer = $script:HAnswer; at = (Get-Date).ToString('o') } | ConvertTo-Json -Compress
                # with a BOM, as some writers put one: read past all the same
                [System.IO.File]::WriteAllText((Join-Path $script:ChatRunAckDir "$hp.json"), $ack, [System.Text.UTF8Encoding]::new($true))
            }
        }
        if ($script:HAnswer -eq 'closing' -and $script:HLeave) { Clear-HLive }
        if ($script:HBusy) { foreach ($f in @(Get-ChildItem -LiteralPath $hSess -File)) { Set-HSession ([int]$f.BaseName) 'busy' } }
    }
    if ($s.phase -eq 'running' -and $script:HThrow) { throw 'the run-state seam threw' }
}
$runH = {
    param([string]$Title, [string]$Say)
    Push-Location -LiteralPath $projH
    $j = New-TestJob $Title $Say
    Pop-Location
    Set-ChatqProp $j 'home' $hHome; Save-ChatqJob $j
    $script:HStates.Clear()
    Invoke-ChatqJob (New-ChatqWatchState) (Find-ChatqJob $j.id)
    return (Find-ChatqJob $j.id)
}
$hPhases = { ($script:HStates | ForEach-Object { $_.Phase }) -join ',' }
$hState = { param($p) @($script:HStates | Where-Object { $_.Phase -eq $p })[-1].State }
$hLog = Join-Path $script:ChatqLogDir 'watcher.log'
$hLogFrom = { [System.IO.File]::ReadAllLines($hLog, $utf8).Count }
$hLogSince = { param($n) @([System.IO.File]::ReadAllLines($hLog, $utf8) | Select-Object -Skip $n) }
$script:ChatHandoverOff = $false
$script:ChatHandoverAckSeconds = 1
$script:ChatHandoverLeaveSeconds = 1
$script:ChatHandoverPollMs = 100

# the tab closes, and its process leaves with it
Set-HLive 2101
$script:HAnswer = 'closing'
$n0 = & $hLogFrom
$h1 = & $runH 'Handover chat' 'the tab closes'
$l1 = & $hLogSince $n0
$hs1 = & $hState 'handover'
$rs1 = & $hState 'running'
$es1 = & $hState 'ended'
$rq1 = [System.IO.File]::ReadAllText($script:ChatReloadPath, $utf8) | ConvertFrom-Json
Check 'a window''s tab holds the chat: the job is running first, then the window is asked to hand it over, then the run - then ended' (
    (& $hPhases) -eq 'handover,running,ended' -and @($script:HStates)[0].JobState -eq 'running' -and $h1.state -eq 'done' -and $es1.state -eq 'done') "$(& $hPhases) $(@($script:HStates)[0].JobState) $($h1.state)"
Check 'run-state: every field, the same run in each write, the handover''s id carried on' (
    $hs1.id -eq $hs1.handoverId -and $rs1.handoverId -eq $hs1.id -and $es1.handoverId -eq $hs1.id -and $rs1.id -ne $hs1.id -and
    $rs1.kind -eq 'prompt' -and $rs1.jobId -eq $h1.id -and [int]$rs1.seq -eq [int]$h1.seq -and $rs1.provider -eq 'claude' -and $rs1.sessionId -eq $idH -and
    $rs1.title -eq 'Handover chat' -and $rs1.cwd -eq $projH -and $rs1.home -eq $hHome -and (@($rs1.hostPids) -join ',') -eq '4242' -and $rs1.oldProcess -eq 'live' -and
    [int]$rs1.runnerPid -eq $PID -and $rs1.away -eq $true -and $null -eq $rs1.beside -and $rs1.log -eq (Join-Path $script:ChatqLogDir "$($h1.id).jsonl") -and
    $rs1.job -eq (Join-Path $script:ChatqQueueDir "$($h1.id).json") -and $rs1.state -eq 'running' -and $rs1.startedAt -and $rs1.at) ($rs1 | ConvertTo-Json -Compress)
$onDisk = Read-ChatRunState
Check 'data/run-state on disk: the last write, UTF-8 JSON with no BOM' ($onDisk.phase -eq 'ended' -and $onDisk.id -eq $es1.id -and
    [System.IO.File]::ReadAllBytes($script:ChatRunStatePath)[0] -eq [byte][char]'{') "$($onDisk.phase)"
Check 'its process left: nothing stale, and watcher.log says the tab closed' (-not (Get-ChatField $h1.result 'stale') -and
    @($l1 | Where-Object { $_ -like '*handover 6a6a6a6a: 4242 closing' }).Count -eq 1 -and @($l1 | Where-Object { $_ -match 'handover 6a6a6a6a: tab closed after \d+\.\d s$' }).Count -eq 1) ($l1 -join ' | ')
Check 'the run''s request names the window that handed over, though no process holds the chat now, and the job' (
    $rq1.kind -eq 'ran' -and $rq1.sessionId -eq $idH -and $rq1.oldProcess -eq 'none' -and (@($rq1.hostPids) -join ',') -eq '4242' -and $rq1.jobId -eq $h1.id) ($rq1 | ConvertTo-Json -Compress)
Clear-HLive

# in use: the tab in front of someone - never run beside it
Set-HLive 2102
$script:HAnswer = 'in-use'
$rqB = [System.IO.File]::ReadAllText($script:ChatReloadPath, $utf8)
$h2 = & $runH 'Handover chat' 'in use'
$du2 = ConvertTo-ChatqDate $h2.deferUntil
$eta2 = (Get-ChatqEta @($h2) @{})[$h2.id]
Check 'a tab in use: not run - back in the queue for a minute, its try not counted, and ended says queued' (
    (& $hPhases) -eq 'handover,ended' -and (& $hState 'ended').state -eq 'queued' -and $h2.state -eq 'queued' -and $h2.deferWhy -eq 'in-use' -and
    $du2 -gt (Get-Date).AddSeconds(45) -and $du2 -lt (Get-Date).AddSeconds(75) -and [int]$h2.attempts -eq 0 -and -not $h2.startedAt -and -not $h2.runnerPid -and
    -not $h2.result -and $h2.deferredSince -and @($h2.history)[-1].why -eq 'waits for you to leave its tab' -and
    [System.IO.File]::ReadAllText($script:ChatReloadPath, $utf8) -eq $rqB) "$(& $hPhases) $($h2.state) $($h2.deferWhy) $($h2.deferUntil) $(@($h2.history)[-1].why)"
Check 'and every list says what it waits for' ($eta2 -eq 'waits for you to leave its tab') $eta2
# asked again while the tab stays in use: running for the guards while the
# window is asked, but a start taken back leaves no trace - and it is asked
# less often: a minute, 2, then 5
$jobsLog = Join-Path $script:ChatqLogDir 'jobs.log'
$againH = {
    param($j)
    Set-ChatqProp $j 'deferUntil' $null; Save-ChatqJob $j
    $script:HStates.Clear()
    Invoke-ChatqJob (New-ChatqWatchState) (Find-ChatqJob $j.id)
    return (Find-ChatqJob $j.id)
}
$hist2 = @($h2.history).Count
$jl2 = [System.IO.File]::ReadAllText($jobsLog, $utf8)
$n0 = & $hLogFrom
$h2b = & $againH $h2
$du2b = ConvertTo-ChatqDate $h2b.deferUntil
$seen2b = @($script:HStates)[0].JobState
$h2c = & $againH $h2b
$du2c = ConvertTo-ChatqDate $h2c.deferUntil
$l2 = & $hLogSince $n0
Check 'the same tab still in use: running while asked, then queued again with nothing in its history, jobs.log or watcher.log saying it ran' (
    $seen2b -eq 'running' -and $h2c.state -eq 'queued' -and @($h2c.history).Count -eq $hist2 -and -not @($h2c.history | Where-Object { $_.state -eq 'running' }).Count -and
    [System.IO.File]::ReadAllText($jobsLog, $utf8) -eq $jl2 -and -not @($l2 | Where-Object { $_ -like "*#$($h2.seq) running*" }).Count -and
    [int]$h2c.attempts -eq 0 -and -not $h2c.startedAt) "$seen2b $($h2c.state) $(@($h2c.history).Count)/$hist2 $(@($h2c.history | ForEach-Object { $_.state }) -join ',')"
Check 'and asked less often each time: 2 minutes, then 5' (
    $du2b -gt (Get-Date).AddSeconds(100) -and $du2b -lt (Get-Date).AddSeconds(140) -and $du2c -gt (Get-Date).AddSeconds(280) -and $du2c -lt (Get-Date).AddSeconds(320) -and
    [int]$h2c.deferTries -eq 3) "$($h2b.deferUntil) $($h2c.deferUntil) $($h2c.deferTries)"
# another wait in between starts the count over
$script:HAnswer = 'unsure'
$script:HBusy = $true
$h2d = & $againH $h2c
$script:HBusy = $false
Set-HLive 2102
$script:HAnswer = 'in-use'
$h2e = & $againH $h2d
$du2e = ConvertTo-ChatqDate $h2e.deferUntil
Check 'a busy chat in between, then the tab in use again: a minute again, and its history says so again' (
    $null -eq $h2d.deferWhy -and $h2e.deferWhy -eq 'in-use' -and $du2e -gt (Get-Date).AddSeconds(45) -and $du2e -lt (Get-Date).AddSeconds(75) -and
    @($h2e.history).Count -eq $hist2 + 1 -and @($h2e.history)[-1].why -eq 'waits for you to leave its tab') "$($h2d.deferWhy) $($h2e.deferWhy) $($h2e.deferUntil) $(@($h2e.history).Count)"
$null = Remove-ChatqJob (Find-ChatqJob $h2.id) 'test'
Clear-HLive

# Cancel clicked while the windows are asked (Stop-ChatqJobRun sees it
# running): never deferred to run later, never run - cancelled
$cancelCase = {
    param([string]$Answer, [string]$Say)
    Set-HLive 2106
    $script:HAnswer = $Answer
    $script:HCancel = $true
    $j = & $runH 'Handover chat' $Say
    $script:HCancel = $false
    Clear-HLive
    [pscustomobject]@{ Job = $j; Phases = (& $hPhases); Ended = (& $hState 'ended'); Cancel = (Test-Path -LiteralPath (Join-Path $script:ChatqQueueDir "$($j.id).cancel"))
        Log = (Test-Path -LiteralPath (Join-Path $script:ChatqLogDir "$($j.id).jsonl")) }
}
$cu = & $cancelCase 'in-use' 'cancelled while in use'
$cc = & $cancelCase 'closing' 'cancelled while its tab closes'
foreach ($c in $cu, $cc) { Check "cancelled during the handover, the window answering $(if ($c -eq $cu) { 'in-use' } else { 'closing' }): failed as cancelled, the file gone, the prompt never sent, ended failed" (
        $c.Job.state -eq 'failed' -and $c.Job.result.reason -eq 'cancelled' -and @($c.Job.history)[-1].why -eq 'cancelled' -and -not $c.Cancel -and -not $c.Log -and
        $c.Phases -eq 'handover,ended' -and $c.Ended.state -eq 'failed' -and -not @($c.Job.history | Where-Object { $_.state -eq 'running' }).Count) "$($c.Job.state) $($c.Job.result.reason) $($c.Cancel) $($c.Log) $($c.Phases)" }

# After a handed-over run ends - here a cancel, which writes no ran request -
# the next run into the chat waits while the window puts it back, as after
# a ran request. What it waited for before is not the reason now. The
# run-state alone: the first run's ran request above may be under 30 s old.
$reqAside = @{}
foreach ($f in $script:ChatReloadPath, $script:ChatOpenPath) {
    if (Test-Path -LiteralPath $f) { $reqAside[$f] = [System.IO.File]::ReadAllBytes($f); Remove-Item -LiteralPath $f -Force }
}
$script:ChatShowHoldSeconds = 30
$endAt = ConvertTo-ChatqDate $cc.Ended.at
Push-Location -LiteralPath $projH
$j15 = New-TestJob 'Handover chat' 'right after the handover'
Pop-Location
Set-ChatqProp $j15 'home' $hHome
Set-ChatqProp $j15 'deferWhy' 'background'
Set-ChatqProp $j15 'deferSince' (Get-Date).ToUniversalTime().AddMinutes(-9).ToString('o')
Set-ChatqProp $j15 'deferNote' 'npm run dev'
Save-ChatqJob $j15
Set-HLive 2107
$script:HAnswer = 'closing'
$script:HStates.Clear()
Invoke-ChatqJob (New-ChatqWatchState) (Find-ChatqJob $j15.id)
$j15 = Find-ChatqJob $j15.id
$du15 = ConvertTo-ChatqDate $j15.deferUntil
$eta15 = (Get-ChatqEta @($j15) @{})[$j15.id]
Check 'the next run into a chat a handover just ended in: held back the same 30 s from the end, not started, not counted as busy' (
    $j15.state -eq 'queued' -and -not $script:HStates.Count -and [int]$j15.attempts -eq 0 -and -not $j15.deferredSince -and
    [Math]::Abs(($du15 - $endAt.AddSeconds(30)).TotalSeconds) -lt 2) "$($j15.state) $($j15.deferUntil) $($cc.Ended.at) $(& $hPhases)"
Check 'held back: an older wait''s reason, since and note cleared - never shown as what it waits for now' (
    $null -eq $j15.deferWhy -and $null -eq $j15.deferSince -and $null -eq $j15.deferNote -and $eta15 -notlike '*background*') "$($j15.deferWhy) $($j15.deferSince) $($j15.deferNote) | $eta15"
$runEnd = [System.IO.File]::ReadAllText($script:ChatRunStatePath, $utf8)
$hOf = {
    param([hashtable]$Set, [datetime]$Now = (Get-Date))
    $o = $runEnd | ConvertFrom-Json
    foreach ($k in $Set.Keys) { Set-ChatqProp $o $k $Set[$k] }
    [System.IO.File]::WriteAllText($script:ChatRunStatePath, ($o | ConvertTo-Json -Compress), $utf8)
    Get-ChatShowHold $idH $Now
}
$hRun = & $hOf @{ phase = 'running' }
$hNoId = & $hOf @{ handoverId = $null }
$hOther = & $hOf @{ sessionId = $idHB }
$hLater = & $hOf @{} (Get-Date).AddSeconds(31)
$hSame = & $hOf @{}
[System.IO.File]::WriteAllText($script:ChatRunStatePath, $runEnd, $utf8)
foreach ($f in $reqAside.Keys) { [System.IO.File]::WriteAllBytes($f, $reqAside[$f]) }
Check 'only an end that had a handover holds, for that chat, for 30 s: a run still going, a run with no handover, another chat''s, or an older end do not' (
    $null -eq $hRun -and $null -eq $hNoId -and $null -eq $hOther -and $null -eq $hLater -and $hSame) "$hRun | $hNoId | $hOther | $hLater | $hSame"
$script:ChatShowHoldSeconds = 0
# and once it starts, what it waited for is over
Set-ChatqProp $j15 'deferWhy' 'background'
$j15 = & $againH $j15
Check 'a job that starts: its old wait''s reason cleared, so no later wait is read as it' ($j15.state -eq 'done' -and $null -eq $j15.deferWhy -and $null -eq $j15.deferSince -and $null -eq $j15.deferNote) "$($j15.state) $($j15.deferWhy)"
Clear-HLive

# unsure, no answer, a close whose process stays: beside it, and stale
$besideCase = {
    param([string]$Answer, [bool]$Leave, [string]$Say)
    Set-HLive 2103
    $script:HAnswer = $Answer
    $script:HLeave = $Leave
    $t = [System.Diagnostics.Stopwatch]::StartNew()
    $j = & $runH 'Handover chat' $Say
    $ms = $t.ElapsedMilliseconds
    $rs = & $hState 'running'
    Clear-HLive
    $script:HLeave = $true
    [pscustomobject]@{ Job = $j; Beside = $rs.beside; Phases = (& $hPhases); Ms = $ms }
}
$n0 = & $hLogFrom
$bu = & $besideCase 'unsure' $true 'unsure'
$bn = & $besideCase $null $true 'no answer'
$bt = & $besideCase 'closing' $false 'stays'
$bo = & $besideCase 'off' $true 'watch runs off'
$lb = & $hLogSince $n0
Check 'a window unsure of its tab, or with watchRuns off: run beside it, said so, and stale' (
    $bu.Phases -eq 'handover,running,ended' -and $bu.Beside -eq 'unsure' -and $bu.Job.state -eq 'done' -and (Get-ChatField $bu.Job.result 'stale') -and
    $bo.Beside -eq 'unsure' -and (Get-ChatField $bo.Job.result 'stale')) "$($bu.Phases) $($bu.Beside) $($bu.Job.state) | $($bo.Beside)"
Check 'no answer - an extension that knows no handover: beside it after the wait for one' (
    $bn.Phases -eq 'handover,running,ended' -and $bn.Beside -eq 'unsure' -and $bn.Job.state -eq 'done' -and $bn.Ms -ge 900 -and
    @($lb | Where-Object { $_ -like '*handover 6a6a6a6a: 4242 no answer' }).Count -eq 1) "$($bn.Phases) $($bn.Beside) $($bn.Ms) ms"
Check 'a tab closing whose process outlives the wait: timed out, beside it' (
    $bt.Beside -eq 'timed-out' -and $bt.Job.state -eq 'done' -and (Get-ChatField $bt.Job.result 'stale') -and
    @($lb | Where-Object { $_ -like '*handover 6a6a6a6a: still open after 1 s - running beside it' }).Count -eq 1) "$($bt.Beside) $($lb -join ' | ')"
# unsure, and the chat started a turn meanwhile: judged again, and it waits
Set-HLive 2104
$script:HAnswer = 'unsure'
$script:HBusy = $true
$h5 = & $runH 'Handover chat' 'busy by now'
$script:HBusy = $false
Check 'not closed, and the chat busy by now: back in the queue as for a busy chat, ended queued - never beside a turn' (
    (& $hPhases) -eq 'handover,ended' -and $h5.state -eq 'queued' -and $null -eq $h5.deferWhy -and $h5.deferUntil -and [int]$h5.attempts -eq 0 -and
    (& $hState 'ended').state -eq 'queued') "$(& $hPhases) $($h5.state) $($h5.deferWhy)"
$null = Remove-ChatqJob (Find-ChatqJob $h5.id) 'test'
Clear-HLive

# the handover off (config handover false): straight to running, beside it
$cfgWasH = [System.IO.File]::ReadAllText($script:ChatqConfigPath, $utf8)
$cfgH = Get-ChatqConfig
Set-ChatqProp $cfgH 'handover' $false
Save-ChatqJson $script:ChatqConfigPath $cfgH
Set-HLive 2105
$script:HAnswer = 'closing'
$h6 = & $runH 'Handover chat' 'handover off'
[System.IO.File]::WriteAllText($script:ChatqConfigPath, $cfgWasH, $utf8)
Check 'config handover false: no handover - running beside it, stale' (
    (& $hPhases) -eq 'running,ended' -and (& $hState 'running').beside -eq 'unsure' -and $h6.state -eq 'done' -and (Get-ChatField $h6.result 'stale')) "$(& $hPhases) $($h6.state)"
Clear-HLive

# ended on every way out: a failure, the limit, a throw; and a job with no
# chat open anywhere is only running, then ended
$env:FAKE_SCENARIO = Join-Path $here 'fixtures\stream\error.jsonl'
$h7 = & $runH 'Handover chat' 'fails'
$p7 = & $hPhases
$e7 = (& $hState 'ended').state
$env:FAKE_SCENARIO = Join-Path $here 'fixtures\stream\rejected.jsonl'
$h8 = & $runH 'Handover chat' 'limited'
$p8 = & $hPhases
$e8 = (& $hState 'ended').state
Remove-Item env:FAKE_SCENARIO
Check 'nothing holding the chat: running, then ended - failed as failed, a limit back in the queue as queued' (
    $p7 -eq 'running,ended' -and $h7.state -eq 'failed' -and $e7 -eq 'failed' -and $p8 -eq 'running,ended' -and $h8.state -eq 'queued' -and $e8 -eq 'queued' -and
    $null -eq (& $hState 'running').beside) "$p7 $($h7.state) $e7 | $p8 $($h8.state) $e8"
$null = Remove-ChatqJob (Find-ChatqJob $h8.id) 'test'
$script:HThrow = $true
$thrown = $null
Push-Location -LiteralPath $projH
$j9 = New-TestJob 'Handover chat' 'throws'
Pop-Location
$script:HStates.Clear()
try { Invoke-ChatqJob (New-ChatqWatchState) (Find-ChatqJob $j9.id) } catch { $thrown = $_.Exception.Message }
$script:HThrow = $false
Check 'a run that throws: ended all the same, said as failed, for the watch loop to fail it' (
    $thrown -like '*seam threw*' -and (& $hPhases) -eq 'running,ended' -and (& $hState 'ended').state -eq 'failed') "$thrown $(& $hPhases)"
$j9 = Find-ChatqJob $j9.id
Complete-ChatqJob $j9 'failed' ([pscustomobject]@{ kind = 'failed'; reason = 'test' }) 'test'

# a watcher gone mid-run: the next one's start says ended
Push-Location -LiteralPath $projH
$j10 = New-TestJob 'Handover chat' 'interrupted'
Pop-Location
Set-ChatqProp $j10 'runnerPid' 999999
Set-ChatqProp $j10 'startedAt' (Get-ChatqStamp)
Set-ChatqJobState $j10 'running' 'test'
$script:HStates.Clear()
$null = Write-ChatRunState $j10 'running' @{ HostPids = @(4242); OldProcess = 'live'; HandoverId = 'h-10'; Beside = 'unsure' }
Repair-ChatqInterrupted
$rs10 = Read-ChatRunState
Check 'a run the watcher was stopped in: its next start marks the job failed and writes ended, keeping what the run-state said' (
    (& $hPhases) -eq 'running,ended' -and $rs10.phase -eq 'ended' -and $rs10.jobId -eq $j10.id -and $rs10.state -eq 'failed' -and
    (@($rs10.hostPids) -join ',') -eq '4242' -and $rs10.handoverId -eq 'h-10' -and $rs10.beside -eq 'unsure') ($rs10 | ConvertTo-Json -Compress)
$cj = Write-ChatRunState ([pscustomobject]@{ id = 'x'; seq = 1; provider = 'claude'; kind = 'prompt'; retryAs = 'continue'; title = 't'; cwd = $projH; state = 'running' }) 'running'
Check 'a continue - kind continue, or sent again as one - says so' ((& $hState 'running').kind -eq 'continue' -and $cj) "$((& $hState 'running').kind)"

# the env a queued Claude run is given, unless the watcher's own sets it
$recH = Join-Path $sb 'rec-h'
$env:FAKE_RECORD = $recH
$h11 = & $runH 'Handover chat' 'env'
$envH = [System.IO.File]::ReadAllText((Join-Path $recH 'env.txt'), $utf8)
$env:BASH_MAX_TIMEOUT_MS = '5000'
$h12 = & $runH 'Handover chat' 'env preset'
$envH2 = [System.IO.File]::ReadAllText((Join-Path $recH 'env.txt'), $utf8)
Remove-Item env:BASH_MAX_TIMEOUT_MS, env:FAKE_RECORD
Check 'a queued run: background tasks off, the Bash tool''s timeouts an hour and 30 minutes, print mode''s wait for background work an hour' (
    $h11.state -eq 'done' -and $envH -match '(?m)^CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1$' -and $envH -match '(?m)^BASH_MAX_TIMEOUT_MS=3600000$' -and
    $envH -match '(?m)^BASH_DEFAULT_TIMEOUT_MS=1800000$' -and $envH -match '(?m)^CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=3600000$') $envH
Check 'one the watcher''s own environment sets is left as it is; the rest still given' (
    $h12.state -eq 'done' -and $envH2 -match '(?m)^BASH_MAX_TIMEOUT_MS=5000$' -and $envH2 -match '(?m)^CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1$') $envH2
# the 4 h deadline after a turn that ended well: done, and said
$stD = New-ChatqRunState
$stD.Result = [pscustomobject]@{ type = 'result'; subtype = 'success'; is_error = $false; result = 'All green.'; num_turns = 3 }
$oD = Get-ChatqClaudeOutcome $stD ([pscustomobject]@{ ExitCode = -1; StdErr = ''; Stopped = 'timeout' }) 'auto'
$stE = New-ChatqRunState
$stE.Result = [pscustomobject]@{ type = 'result'; subtype = 'error_during_execution'; is_error = $true; result = 'crashed'; num_turns = 1 }
$oE = Get-ChatqClaudeOutcome $stE ([pscustomobject]@{ ExitCode = -1; StdErr = ''; Stopped = 'timeout' }) 'auto'
$oC = Get-ChatqClaudeOutcome $stD ([pscustomobject]@{ ExitCode = -1; StdErr = ''; Stopped = 'cancelled' }) 'auto'
Check 'the deadline after a turn that ended well - print mode still waiting on its background work: done, with a note; after a failed turn, or a cancel, failed' (
    $oD.kind -eq 'done' -and $oD.note -like '*cut off at the 4 h deadline*' -and $oE.kind -eq 'failed' -and $oE.reason -eq 'timeout' -and
    $oC.kind -eq 'failed' -and $oC.reason -eq 'cancelled') "$($oD.kind) $($oD.note) | $($oE.kind) $($oE.reason) | $($oC.kind)"

# Background work the chat's own process started, judged before a run
$hbBase = [System.IO.File]::ReadAllText($pHB, $utf8)
$hbTmp = Join-Path $sb 'hb-judge.jsonl'
$hbAgent = [ordered]@{ isAsync = $true; status = 'async_launched'; agentId = 'ahb0001'; description = 'map the tests' }
$hbShell = { param($id) [ordered]@{ stdout = ''; stderr = ''; interrupted = $false; backgroundTaskId = $id } }
function Add-HbLine([string]$Path, $Result, [double]$MinutesAgo, [string]$Entrypoint = 'claude-vscode') {
    $r = [ordered]@{ type = 'user'; timestamp = (Get-Date).ToUniversalTime().AddMinutes(-$MinutesAgo).ToString('o'); sessionId = $idHB; entrypoint = $Entrypoint
        message = [ordered]@{ role = 'user'; content = @([ordered]@{ type = 'tool_result'; tool_use_id = 'toolu_hb'; content = 'launched' }) }
        toolUseResult = $Result } | ConvertTo-Json -Compress -Depth 6
    [System.IO.File]::AppendAllText($Path, $r + "`n", $utf8)
}
$hbJudge = {
    param([scriptblock]$Fill, $Shells)
    [System.IO.File]::WriteAllText($hbTmp, $hbBase, $utf8)
    & $Fill
    $script:ChatShellChildSeam = [scriptblock]::Create("param(`$p) $Shells")
    $jb = [pscustomobject]@{ provider = 'claude'; sessionId = $idHB; path = $hbTmp }
    $lv = @([pscustomobject]@{ SessionId = $idHB; Pid = 3101; Status = 'idle'; Kind = 'interactive'; StartedAt = $hStart; Entrypoint = 'claude-vscode' })
    $a = Resolve-ChatqLiveAction $jb $lv
    $script:ChatShellChildSeam = $null
    $a
}
$ja = & $hbJudge { Add-HbLine $hbTmp $hbAgent 5 } '0'
$js = & $hbJudge { Add-HbLine $hbTmp (& $hbShell 'bhb0001') 5 } '1'
$jsOld = & $hbJudge { Add-HbLine $hbTmp (& $hbShell 'bhb0001') 25 } '1'
$jsGone = & $hbJudge { Add-HbLine $hbTmp (& $hbShell 'bhb0001') 5 } '0'
$jsUnknown = & $hbJudge { Add-HbLine $hbTmp (& $hbShell 'bhb0001') 5 } '$null'
$jaPrint = & $hbJudge { Add-HbLine $hbTmp $hbAgent 5 'sdk-cli' } '0'
$jaBefore = & $hbJudge { Add-HbLine $hbTmp $hbAgent 90 } '0'
$jaOld = & $hbJudge { Add-HbLine $hbTmp $hbAgent 50; Add-HbLine $hbTmp (& $hbShell 'bhb0001') 25 } '1'
Check 'an agent the window''s process started, still out: the run waits, as for a busy chat - background, since when, what it is' (
    $ja.Action -eq 'defer' -and $ja.Why -eq 'background' -and -not $ja.ShellOnly -and $ja.Note -eq 'map the tests' -and
    [Math]::Abs(((Get-Date) - $ja.Since).TotalMinutes - 5) -lt 1) "$($ja.Action) $($ja.Why) $($ja.ShellOnly) $($ja.Note) $($ja.Since)"
Check 'a background shell still running under the process: waits too, on shells alone' ($js.Action -eq 'defer' -and $js.Why -eq 'background' -and $js.ShellOnly -and $null -eq $js.Note) "$($js.Action) $($js.ShellOnly)"
Check 'past 20 minutes from the shell''s start: runs beside it - no waiting on a server that never ends' ($jsOld.Action -eq 'warn' -and $jsOld.Beside -eq 'background') "$($jsOld.Action) $($jsOld.Beside)"
Check 'a shell no longer running under it - ended from the task list - or one that cannot be counted holds nothing' (
    $jsGone.Action -eq 'warn' -and -not $jsGone.Beside -and $jsUnknown.Action -eq 'warn' -and -not $jsUnknown.Beside) "$($jsGone.Action) $($jsUnknown.Action)"
Check 'work a print-mode run started, or one from before the process started, holds nothing; an agent holds however long it has run' (
    $jaPrint.Action -eq 'warn' -and $jaBefore.Action -eq 'warn' -and $jaOld.Action -eq 'defer' -and -not $jaOld.ShellOnly) "$($jaPrint.Action) $($jaBefore.Action) $($jaOld.Action)"
Remove-Item -LiteralPath $hbTmp -Force -EA SilentlyContinue

# and through the watcher, with the handover on
Add-HbLine $pHB (& $hbShell 'bhb0001') 5
Set-HLive 3101 $idHB
$script:ChatShellChildSeam = { param($p) 1 }
Push-Location -LiteralPath $projH
$j13 = New-TestJob 'Background wait chat' 'after the suite'
Pop-Location
Set-ChatqProp $j13 'home' $hHome
# as if it had waited on a busy chat for a day before: a shell's wait still never gives up
Set-ChatqProp $j13 'deferredSince' (Get-Date).ToUniversalTime().AddHours(-25).ToString('o')
Save-ChatqJob $j13
$script:HStates.Clear()
$n0 = & $hLogFrom
Invoke-ChatqJob (New-ChatqWatchState) (Find-ChatqJob $j13.id)
$j13 = Find-ChatqJob $j13.id
$since13 = ConvertTo-ChatqDate $j13.deferSince
$words13 = "waits for a background command (since $($since13.ToString('HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)))"
$eta13 = (Get-ChatqEta @($j13) @{})[$j13.id]
$l13 = & $hLogSince $n0
Check 'the watcher: a job into a chat with a background shell running waits - background, since when - and a shell''s wait never gives up' (
    $j13.state -eq 'queued' -and $j13.deferWhy -eq 'background' -and [Math]::Abs(((Get-Date) - $since13).TotalMinutes - 5) -lt 1 -and $null -eq $j13.deferNote -and
    $j13.deferUntil -and -not $script:HStates.Count -and @($j13.history)[-1].why -eq $words13) "$($j13.state) $($j13.deferWhy) $($j13.deferSince) $(@($j13.history)[-1].why)"
Check 'and says so where its time shows, and in watcher.log - not chat busy' ($eta13 -eq $words13 -and @($l13 | Where-Object { $_ -like "*deferred: $words13" }).Count -eq 1) "$eta13 | $($l13 -join ' | ')"
# 20 minutes on: beside it, with no handover - closing the tab would end it
Add-HbLine $pHB (& $hbShell 'bhb0002') 25
$script:ChatShellChildSeam = { param($p) 2 }
$script:HAnswer = 'closing'
Set-ChatqProp $j13 'deferUntil' $null; Save-ChatqJob $j13
Invoke-ChatqJob (New-ChatqWatchState) (Find-ChatqJob $j13.id)
$j13 = Find-ChatqJob $j13.id
Check 'past its 20 minutes: run beside the chat, no handover asked, the run-state and the history saying why' (
    $j13.state -eq 'done' -and (& $hPhases) -eq 'running,ended' -and (& $hState 'running').beside -eq 'background' -and
    (Get-ChatField $j13.result 'stale') -and @($j13.history | Where-Object { $_.state -eq 'running' -and $_.why -like '*beside a background command*' }).Count -eq 1 -and
    (Test-Path -LiteralPath (Join-Path $hSess '3101.json'))) "$($j13.state) $(& $hPhases) $((& $hState 'running').beside)"
# an agent: waits as long as it runs, and counts towards giving up
Add-HbLine $pHB $hbAgent 5
Push-Location -LiteralPath $projH
$j14 = New-TestJob 'Background wait chat' 'after the agent'
Pop-Location
Set-ChatqProp $j14 'home' $hHome
Set-ChatqProp $j14 'deferredSince' (Get-Date).ToUniversalTime().AddHours(-25).ToString('o')
Save-ChatqJob $j14
Invoke-ChatqJob (New-ChatqWatchState) (Find-ChatqJob $j14.id)
$j14 = Find-ChatqJob $j14.id
Check 'an agent still out after a day of waiting: given up, in its words' ($j14.state -eq 'failed' -and $j14.result.reason -eq 'its background work ran for 24 h') "$($j14.state) $($j14.result.reason)"
$script:ChatShellChildSeam = $null

# back as the other sections expect it
$script:HAnswer = $null
$script:ChatRunStateSeam = $null
$script:ChatHandoverOff = $true
$script:ChatHandoverAckSeconds = 3
$script:ChatHandoverLeaveSeconds = 15
$script:ChatHandoverPollMs = 250
$script:ChatqAliveSeam = $null
Clear-HLive
foreach ($j in @(Get-ChatqJobs | Where-Object { $_.sessionId -in $idH, $idHB -and $_.state -eq 'queued' })) { $null = Remove-ChatqJob $j 'test' }
Remove-Item -LiteralPath $pH, $pHB -Force -EA SilentlyContinue
$null = @(Sync-ChatIndex)
