# tests/sections/watcher.ps1: dot-sourced by tests/run-tests.ps1 in its turn,
# never on its own - it uses what the runner and the sections before it set.

Section 'jobs and the watcher'
function New-TestJob([string]$Target, [string]$PromptText, [switch]$Continue) {
    # the real chatq command, with the watcher kept from starting: holding the
    # lock is exactly what a running watcher looks like
    New-ChatqDir $script:ChatqData
    $lk = [System.IO.File]::Open($script:ChatqLockPath, 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        if ($Continue) { chatq $Target -Continue *> $null } else { chatq $Target -Prompt $PromptText *> $null }
    }
    finally { $lk.Dispose() }
    return @(Get-ChatqJobs | Sort-Object { [int]$_.seq })[-1]
}
$j = New-TestJob 'card redesign' (U 'level the heights \uC120\uD0DD')
Check 'chatq queues with the chat''s cwd and mode' ($j.sessionId -eq $idCard -and $j.cwd -eq $projA -and $j.modeAtQueue -eq 'acceptEdits') "$($j.sessionId) $($j.cwd) $($j.modeAtQueue)"
Check 'prompt kept in its own .md' ((Read-ChatqPrompt $j) -eq (U 'level the heights \uC120\uD0DD')) (Read-ChatqPrompt $j)
Check 'the prompt file is named after the chat' ($j.promptFile -like "#$($j.seq) $tSel card UI redesign.md") $j.promptFile

$W = New-ChatqWatchState
$env:FAKE_RECORD = $rec
Invoke-ChatqJob $W (Find-ChatqJob $j.id)
$j = Find-ChatqJob $j.id
Check 'a plain run ends done' ($j.state -eq 'done') "$($j.state) $($j.result.reason)"
$argv = [System.IO.File]::ReadAllText((Join-Path $rec 'argv.txt'))
Check 'resumed with the chat''s own mode, prompts denied' ($argv -match '--resume\s+' + $idCard -and $argv -match 'acceptEdits' -and $argv -match 'none') ($argv -replace "`n", ' ')
$alerts = [System.IO.File]::ReadAllText((Join-Path $script:ChatqLogDir 'alerts.log'), $utf8)
Check 'started and done alerts logged' ($alerts -match "`tstarted`t" -and $alerts -match "`tdone`t")

# a limit mid-run, after the prompt reached the chat: back in the queue, as a
# "continue", and the provider blocked until the reset the run reported
$j = New-TestJob 'Parser rewrite and plugin unification' 'second half please'
$env:FAKE_SCENARIO = Join-Path $here 'fixtures\stream\rejected.jsonl'
$env:FAKE_LAND = $pFw
Invoke-ChatqJob $W (Find-ChatqJob $j.id)
$j = Find-ChatqJob $j.id
Check 'limited mid-run -> queued again' ($j.state -eq 'queued') $j.state
Check 'landed prompt retries as continue' ($j.retryAs -eq 'continue') $j.retryAs
$laneA = Get-ChatqLane $j
Check 'provider blocked until the reset' ($W.blocked[$laneA] -and $W.blocked[$laneA].Until -gt (Get-Date).AddMinutes(90)) $W.blocked[$laneA]
Remove-Item env:FAKE_SCENARIO, env:FAKE_LAND

# denied -> needs-input, parked
$env:FAKE_SCENARIO = Join-Path $here 'fixtures\stream\denied.jsonl'
$j = New-TestJob 'Old chat about gitignore rules' 'write them'
Invoke-ChatqJob $W (Find-ChatqJob $j.id)
$j = Find-ChatqJob $j.id
Check 'denied -> needs-input' ($j.state -eq 'needs-input') "$($j.state) $($j.result.reason)"
Remove-Item env:FAKE_SCENARIO

# -Continue on a chat that has moved on is dropped, not sent
$j = New-TestJob $titleCard -Continue
Invoke-ChatqJob $W (Find-ChatqJob $j.id)
$j = Find-ChatqJob $j.id
Check '-Continue on a chat already continued -> skipped' ($j.state -eq 'skipped') "$($j.state)"

# busy in a live window -> deferred, not run
$env:FAKE_AGENTS = '[{"pid":1,"sessionId":"' + $idOld + '","kind":"interactive","status":"busy"}]'
$j = New-TestJob 'Old chat about gitignore rules' 'again'
Invoke-ChatqJob $W (Find-ChatqJob $j.id)
$j = Find-ChatqJob $j.id
Check 'a busy chat is deferred' ($j.state -eq 'queued' -and $j.deferUntil) "$($j.state) $($j.deferUntil)"
$env:FAKE_AGENTS = '[{"pid":1,"sessionId":"' + $idOld + '","kind":"interactive","status":"idle"}]'
Set-ChatqProp $j 'deferUntil' $null; Save-ChatqJob $j
# as a real run leaves it: the chat's transcript written this minute
(Get-Item -LiteralPath $j.path).LastWriteTime = Get-Date
Invoke-ChatqJob $W (Find-ChatqJob $j.id)
$j = Find-ChatqJob $j.id
Check 'an idle live chat runs, with a reload warning' ($j.state -eq 'done' -and $j.result.stale) "$($j.state) stale=$($j.result.stale)"
$rq = [System.IO.File]::ReadAllText($script:ChatReloadPath, $utf8) | ConvertFrom-Json
Check 'and a reload offer for the window that holds it' ($rq.kind -eq 'ran' -and $rq.cwd -eq $projA) "$($rq.kind) $($rq.cwd)"
# projA has chats left mid-turn by the tests above, so busy is only checked
# for being judged here; 'reload while a chat works' checks its value
Check 'saying nobody is at the PC, and whether the folder was busy' ($rq.away -eq $true -and $null -ne $rq.busy) "away=$($rq.away) busy=$($rq.busy)"
Remove-Item env:FAKE_AGENTS

# a 529 mid-run, after the prompt reached the chat: queued again as an
# automatic "continue", its lane waiting on status.claude.com
$j = New-TestJob 'Overloaded mid task' 'finish the parser refactor'
$env:FAKE_SCENARIO = Join-Path $here 'fixtures\stream\overloaded.jsonl'
$env:FAKE_LAND = $pOver
Set-FakeStatus 'major_outage'
Invoke-ChatqJob $W (Find-ChatqJob $j.id)
$j = Find-ChatqJob $j.id
Check '529 mid-run -> queued again, not failed' ($j.state -eq 'queued') "$($j.state) $($j.result.reason)"
Check 'landed prompt retries as an automatic continue' ($j.retryAs -eq 'continue' -and $j.autoContinue) "$($j.retryAs) $($j.autoContinue)"
Check 'its lane waits on the status page' ($null -ne $W.outage[(Get-ChatqLane $j)])
Check 'the watcher will not pick it before the next check' ($null -ne (Get-ChatqDueTime $W $j (Get-Date)))
Remove-Item env:FAKE_SCENARIO, env:FAKE_LAND
# Claude writes the 529 turn into the chat as well. While it is the chat's
# last word the continue goes out; once the chat has moved on it is dropped.
$rec529 = [ordered]@{ type = 'assistant'; uuid = [guid]::NewGuid().ToString(); timestamp = (Get-Date).ToUniversalTime().ToString('o')
    message = [ordered]@{ model = '<synthetic>'; role = 'assistant'; content = @([ordered]@{ type = 'text'; text = 'API Error: 529 Overloaded.' }) }
    error = 'server_error'; isApiErrorMessage = $true; apiErrorStatus = 529; sessionId = $idOver } | ConvertTo-Json -Compress -Depth 6
[System.IO.File]::AppendAllText($pOver, $rec529 + "`n", $utf8)
Set-FakeStatus 'operational'
$W.outage = @{}
Invoke-ChatqJob $W (Find-ChatqJob $j.id)
$j = Find-ChatqJob $j.id
Check 'chat still stopped by the 529 -> the continue is sent' ($j.state -eq 'done') "$($j.state) $($j.result.reason)"
$moved = [ordered]@{ type = 'assistant'; uuid = [guid]::NewGuid().ToString(); timestamp = (Get-Date).ToUniversalTime().ToString('o')
    message = [ordered]@{ model = 'claude-opus-5'; role = 'assistant'; content = @([ordered]@{ type = 'text'; text = 'all done' }); stop_reason = 'end_turn' }
    sessionId = $idOver } | ConvertTo-Json -Compress -Depth 6
[System.IO.File]::AppendAllText($pOver, $moved + "`n", $utf8)
Set-ChatqProp $j 'retryAs' 'continue'; Set-ChatqProp $j 'autoContinue' $true; Set-ChatqJobState $j 'queued' 'test'
Invoke-ChatqJob $W (Find-ChatqJob $j.id)
$j = Find-ChatqJob $j.id
Check 'an automatic continue into a chat that moved on is dropped' ($j.state -eq 'skipped') "$($j.state)"

# a job left running by a dead watcher - even when its old pid is alive
# again as some other process
$j = New-TestJob 'Mode far back' 'x'
$other = (Get-Process | Where-Object { $_.Id -ne $PID -and $_.Id -gt 4 } | Select-Object -First 1).Id
Set-ChatqProp $j 'runnerPid' $other; Set-ChatqProp $j 'startedAt' (Get-ChatqStamp); Set-ChatqJobState $j 'running' 'test'
Repair-ChatqInterrupted
$j = Find-ChatqJob $j.id
Check 'interrupted run -> failed, never resent on its own' ($j.state -eq 'failed' -and $j.result.reason -like 'interrupted*') "$($j.state)"
Set-ChatqJobState $j 'running' 'test'
chatqrm $j.seq -Force *> $null
$j = Find-ChatqJob $j.id
Check 'chatqrm -Force with no watcher fails it at once, leaves no cancel file' ($j.state -eq 'failed' -and -not (Test-Path -LiteralPath (Join-Path $script:ChatqQueueDir "$($j.id).cancel"))) $j.state
$lk = [System.IO.File]::Open($script:ChatqLockPath, 'OpenOrCreate', 'ReadWrite', 'None')
$null = Start-ChatqWatcher -Wake 'now'
$lk.Dispose()
Check '-Now reaches a running watcher intact' ((Get-Content -LiteralPath $script:ChatqWakePath -Raw).Trim() -eq 'now')

# the whole loop, once. The sandbox holds a chat cut off with a reset two
# hours out, so a plain start would wait for it - chatqrun -Now is the way
# past, and after it the watcher runs the queue (the limited job above too)
# and exits
$j = New-TestJob 'plugin' 'loop test'
Send-ChatqWake 'now'
Invoke-ChatqWatchLoop -Foreground *> $null
$j = Find-ChatqJob $j.id
Check 'watcher loop runs the queue and exits' ($j.state -eq 'done' -and -not (Test-ChatqWatcherAlive)) "$($j.state)"
$lk = [System.IO.File]::Open($script:ChatqLockPath, 'OpenOrCreate', 'ReadWrite', 'None')
$t0 = Get-Date
Invoke-ChatqWatchLoop -Foreground *> $null
Check 'a second watcher will not start' (((Get-Date) - $t0).TotalSeconds -lt 5)
$lk.Dispose()
Remove-Item env:FAKE_RECORD

# the launch: its own -ExecutionPolicy Bypass loads the script where the
# process's policy would refuse it - a 5.1 whose policy was only ever set in
# pwsh 7 - and the policy goes again before the loop, so the jobs run under
# yours. A stand-in script says what it saw, in a child handed Restricted as
# a process policy is handed on; off Windows there is no policy to refuse.
$wlStub = Join-Path $sb 'watcher-stub.ps1'
[IO.File]::WriteAllText($wlStub, @'
$global:WlLoad = [string]$env:PSExecutionPolicyPreference
function Invoke-ChatqWatchLoop { [Console]::Out.WriteLine("load=$($global:WlLoad) after=$env:PSExecutionPolicyPreference watcher=$env:CHATQ_WATCHER") }
'@, $utf8)
$wlL = Get-ChatqWatcherLaunch $wlStub
$wlDec = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($wlL.Args[-1]))
$wlOut = New-Object System.Collections.Generic.List[string]
$wlRun = Invoke-ChatqProcess -Exe $wlL.Exe -ArgList $wlL.Args -StdIn '' -SetEnv @{ PSExecutionPolicyPreference = 'Restricted' } -OnLine { param($l) $wlOut.Add($l) } -TimeoutSec 60
$wlSaw = @($wlOut | Where-Object { $_ -like 'load=*' }) | Select-Object -Last 1
Check 'the watcher''s launch: no profile, Bypass for the load alone, then the loop with the policy gone and CHATQ_WATCHER set' ($wlRun.ExitCode -eq 0 -and
    $wlSaw -like '* after= watcher=1' -and (-not $script:ChatqIsWindows -or $wlSaw -like 'load=Bypass *') -and $wlDec -eq $wlL.Command -and
    $wlDec -like "*CHATQ_WATCHER='1'*$wlStub*Remove-Item -LiteralPath 'env:PSExecutionPolicyPreference'*Invoke-ChatqWatchLoop" -and
    ($wlL.Args[0..4] -join ' ') -eq '-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand' -and $wlL.Exe -eq (Get-Process -Id $PID).Path) "exit $($wlRun.ExitCode): $($wlOut -join ' | ') $($wlRun.StdErr)"
$wlBad = Join-Path $sb 'watcher-stub-bad.ps1'
[IO.File]::WriteAllText($wlBad, "throw 'the stub will not load'`n", $utf8)
$wlL = Get-ChatqWatcherLaunch $wlBad
$wlRun = Invoke-ChatqProcess -Exe $wlL.Exe -ArgList $wlL.Args -StdIn '' -TimeoutSec 60
$wlLog = @([IO.File]::ReadAllLines((Join-Path $script:ChatqLogDir 'watcher.log'), $utf8))[-1]
Check 'a watcher that cannot load says so in watcher.log, and exits 1' ($wlRun.ExitCode -eq 1 -and $wlLog -like '*  the watcher did not load: the stub will not load') "exit $($wlRun.ExitCode): $wlLog"
Remove-Item -LiteralPath $wlStub, $wlBad -Force -EA SilentlyContinue
