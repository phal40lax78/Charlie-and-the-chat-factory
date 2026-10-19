# tests/sections/watcher.ps1: dot-sourced by tests/run-tests.ps1 in its turn,
# never on its own - it uses what the runner and the sections before it set.

Section 'jobs and the watcher'
function Lock-Queue([scriptblock]$Do) {
    # a held lock is what a running watcher looks like: chatq queues, starts none
    New-ChatqDir $script:ChatqData
    $lk = [System.IO.File]::Open($script:ChatqLockPath, 'OpenOrCreate', 'ReadWrite', 'None')
    try { & $Do } finally { $lk.Dispose() }
}
function New-TestJob([string]$Target, [string]$PromptText, [switch]$Continue, [string]$Cwd) {
    # the real chatq command, with the watcher kept from starting. -Cwd runs it
    # from that folder, as typing chatq there does
    if ($Cwd) { Push-Location -LiteralPath $Cwd }
    Lock-Queue { if ($Continue) { chatq $Target -Continue *> $null } else { chatq $Target -Prompt $PromptText *> $null } }
    $made = @(Get-ChatqJobs | Sort-Object { [int]$_.seq })[-1]
    if ($Cwd) { Pop-Location }
    return $made
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

# chatqrun -Stop mid-run (data/stop): the run ends as chatqcancel's does -
# failed, cancelled, and no failed alert - not as a run that broke
$j = New-TestJob 'card redesign' 'stop me midway'
$alertsLog = Join-Path $script:ChatqLogDir 'alerts.log'
$alertsAt = $alerts.Length
$env:FAKE_SLEEP = '20'
Save-ChatqText $script:ChatqStopPath 'stop'
$stopSw = [System.Diagnostics.Stopwatch]::StartNew()
try { Invoke-ChatqJob $W (Find-ChatqJob $j.id) }
finally { Remove-Item env:FAKE_SLEEP; Remove-Item -LiteralPath $script:ChatqStopPath -Force -EA SilentlyContinue }
$stopSw.Stop()
$j = Find-ChatqJob $j.id
$stopAlerts = ([System.IO.File]::ReadAllText($alertsLog, $utf8)).Substring($alertsAt)
Check 'chatqrun -Stop mid-run: the run cut short, the job failed as cancelled, and no failed alert - as chatqcancel''s' (
    $j.state -eq 'failed' -and $j.result.reason -eq 'cancelled' -and $stopSw.Elapsed.TotalSeconds -lt 15 -and $stopAlerts -notmatch "`tfailed`t") "$($j.state) $($j.result.reason) $([int]$stopSw.Elapsed.TotalSeconds) s | $stopAlerts"

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

# -Continue on a chat that has moved on is dropped, not sent - judged by
# its last turn alone: the mode and model reads, up to 64 MB back on a long
# chat, are not made
$j = New-TestJob $titleCard -Continue
$ftsFn = ${function:Find-ChatqTailString}
$ftmFn = ${function:Find-ChatqTailMatch}
$tailReads = @{ n = 0 }
${function:Find-ChatqTailString} = { $tailReads.n++; & $ftsFn @args }
${function:Find-ChatqTailMatch} = { $tailReads.n++; & $ftmFn @args }
Invoke-ChatqJob $W (Find-ChatqJob $j.id)
${function:Find-ChatqTailString} = $ftsFn
${function:Find-ChatqTailMatch} = $ftmFn
$j = Find-ChatqJob $j.id
Check '-Continue on a chat already continued -> skipped' ($j.state -eq 'skipped') "$($j.state)"
Check 'the job''s chat is read for its last turn only, not its mode or model' ($tailReads.n -eq 0) "$($tailReads.n) reads"

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

# A Remove - the console's, chatqrm - while the watcher checks a job, here
# inside its look at the live sessions (claude agents, up to 30 s): what the
# watcher writes after is no longer written back. It had come back queued,
# or failed, and a continue was sent after it was removed.
$fnLive = ${function:Get-ChatqLiveSessions}
${function:Get-ChatqLiveSessions} = {
    param([string]$ConfigDir, [switch]$RegistryOnly)
    if ($script:RmMid) { $null = Remove-ChatqJob (Find-ChatqJob $script:RmMid -Exact) 'the console'; $script:RmMid = $null }
    @($script:RmLive)
}
try {
    $rmSaid = foreach ($c in @(@('busy', 'prompt'), @('idle', 'prompt'), @('none', 'prompt'), @('busy', 'continue'))) {
        $sid = if ($c[1] -eq 'continue') { $idTong } else { $idOld }
        $jr = if ($c[1] -eq 'continue') { (New-ChatqJob -Row (Get-ChatqRowById $idTong) -Kind continue -Rule continue -SendNow).Job } else { (New-ChatqJob -Row (Get-ChatqRowById $idOld) -Prompt 'drop me').Job }
        $script:RmLive = if ($c[0] -eq 'none') { @() } else { @([pscustomobject]@{ SessionId = $sid; Pid = 1; Status = $c[0]; Kind = 'interactive'; WaitingFor = $null; ProcStart = $null; StartedAt = $null; Entrypoint = 'claude-vscode' }) }
        $script:RmMid = $jr.id
        Invoke-ChatqJob (New-ChatqWatchState) (Find-ChatqJob $jr.id -Exact)
        $back = (Test-Path -LiteralPath (Join-Path $script:ChatqQueueDir "$($jr.id).json")) -or (Test-Path -LiteralPath (Join-Path $script:ChatqQueueDir "$($jr.id).json.tmp"))
        "$($c -join '/'):$(if ($back) { 'BACK' } else { 'gone' })"
    }
}
finally { ${function:Get-ChatqLiveSessions} = $fnLive; $script:RmMid = $null; $script:RmLive = $null }
Check 'a Remove during the watcher''s checks stays a removal: busy (deferred), idle and not open (about to run), a continue sent now - nothing written back' (
    ($rmSaid -join ' ') -eq 'busy/prompt:gone idle/prompt:gone none/prompt:gone busy/continue:gone') "$rmSaid"
$ghost = (New-ChatqJob -Row (Get-ChatqRowById $idOld) -Prompt 'ghost').Job
$null = Remove-ChatqJob $ghost 'test'
$ghostSaved = Save-ChatqJob $ghost -Existing
Check 'Save-ChatqJob -Existing makes no file for a job removed, and leaves no copy aside' (
    $ghostSaved -eq $false -and -not (Test-Path -LiteralPath (Join-Path $script:ChatqQueueDir "$($ghost.id).json")) -and
    -not (Test-Path -LiteralPath (Join-Path $script:ChatqQueueDir "$($ghost.id).json.tmp"))) "$ghostSaved"

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
# an image pasted into a prompt tab that was cancelled two days ago: swept
# as the loop starts (Clear-ChatqStrayFiles)
$wlStray = Join-Path $script:ChatqQueueDir 'loop-stray-shot.png'
[System.IO.File]::WriteAllBytes($wlStray, [byte[]]@(1, 2, 3))
(Get-Item -LiteralPath $wlStray).CreationTime = (Get-Date).AddDays(-2)
(Get-Item -LiteralPath $wlStray).LastWriteTime = (Get-Date).AddDays(-2)
$wlLogP = Join-Path $script:ChatqLogDir 'watcher.log'
$wlLog0 = if (Test-Path -LiteralPath $wlLogP) { @([System.IO.File]::ReadAllLines($wlLogP, $utf8)).Count } else { 0 }
Send-ChatqWake 'now'
Invoke-ChatqWatchLoop -Foreground *> $null
$j = Find-ChatqJob $j.id
Check 'watcher loop runs the queue and exits' ($j.state -eq 'done' -and -not (Test-ChatqWatcherAlive)) "$($j.state)"
$wlSwept = @([System.IO.File]::ReadAllLines($wlLogP, $utf8) | Select-Object -Skip $wlLog0 | Where-Object { $_ -like '*stray file(s) and folder(s) from data/queue*' })
Check 'and sweeps data/queue/ of a day-old file no prompt links to as it starts, once, saying so in watcher.log' (
    -not (Test-Path -LiteralPath $wlStray) -and $wlSwept.Count -eq 1) "$(Test-Path -LiteralPath $wlStray) $($wlSwept -join ' | ')"
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

# and where it starts: your home folder, never the folder of the shell that
# started it, which it would hold for as long as it runs. Started for real,
# from a folder whose [1] Windows PowerShell 5.1 reads as a wildcard, with a
# stand-in script that writes down the folder it finds itself in.
$wlCwdStub = Join-Path $sb 'watcher-stub-cwd.ps1'
[IO.File]::WriteAllText($wlCwdStub, @'
$global:WlCwdFile = Join-Path $PSScriptRoot 'watcher-cwd.txt'
function Invoke-ChatqWatchLoop { [IO.File]::WriteAllText($global:WlCwdFile, [Environment]::CurrentDirectory) }
'@, $utf8)
$wlCwdOut = Join-Path $sb 'watcher-cwd.txt'
$wlFrom = Join-Path $sb 'wd[1]'
[void][IO.Directory]::CreateDirectory($wlFrom)
$wlWas = @{ Spawn = $script:ChatqSpawn; Path = $script:ChatqScriptPath }
$script:ChatqSpawn = $null
$script:ChatqScriptPath = $wlCwdStub
Push-Location -LiteralPath $wlFrom
try { $wlOk = Start-ChatqWatcherProcess }
finally { Pop-Location; $script:ChatqSpawn = $wlWas.Spawn; $script:ChatqScriptPath = $wlWas.Path }
$wlCwd = ''
$wlUntil = (Get-Date).AddSeconds(60)
while ($wlOk -and -not $wlCwd -and (Get-Date) -lt $wlUntil) {
    Start-Sleep -Milliseconds 200
    $wlCwd = try { [IO.File]::ReadAllText($wlCwdOut) } catch { '' }
}
Check 'the watcher starts in your home folder, not the folder of the shell that started it, even one with [1] in its name' ($wlOk -and
    $wlCwd.TrimEnd('\', '/') -eq $HOME.TrimEnd('\', '/')) "started $wlOk, in '$wlCwd'"
Remove-Item -LiteralPath $wlCwdStub, $wlCwdOut, $wlFrom -Force -EA SilentlyContinue

# The respawn after 'queue empty', with the reply window asked per call:
# shut at the pass's look and at the empty recheck, open by the look after
# the lock is let go - a shell's alert in between. The sequence of looks,
# log lines and starts is the one chatqd's own replay of that exit asserts
# (native/crates/chatqd/src/watch/timers_replay.rs). Every other call the
# loop makes is stubbed, the queue is seen as empty, and no -Now is lying
# about.
$wlFnWas = @{}
foreach ($k in 'Get-ChatqJobs', 'Restore-ChatqWatchState', 'Repair-ChatqInterrupted', 'Test-ChatqHeldWaiting', 'Test-ChatqReplyOpen', 'Invoke-ChatqWatchAutoScan',
    'Clear-ChatqStrayFiles', 'Set-ChatqKeepAwake', 'Save-ChatqWatchState', 'Write-ChatqBoard', 'Write-ChatqWatchLog', 'Start-ChatqWatcherProcess') { $wlFnWas[$k] = (Get-Item "function:$k").ScriptBlock }
$wlSentWas = $script:ChatqAskSent
$wlFgWas = $script:ChatqForeground
$wlWake = Read-TestFile $script:ChatqWakePath
$script:wlSeq = New-Object System.Collections.Generic.List[string]
$script:wlOpens = 0
try {
    $script:ChatqAskSent = @{}
    Remove-Item -LiteralPath $script:ChatqStopPath, $script:ChatqWakePath -Force -EA SilentlyContinue
    Set-Item function:Get-ChatqJobs { @() }
    Set-Item function:Restore-ChatqWatchState { param($W) $false }
    Set-Item function:Repair-ChatqInterrupted { }
    Set-Item function:Test-ChatqHeldWaiting { $false }
    Set-Item function:Test-ChatqReplyOpen { param($Cfg) $script:wlOpens++; $o = $script:wlOpens -ge 3; $script:wlSeq.Add("reply open: $o"); $o }
    Set-Item function:Invoke-ChatqWatchAutoScan { param($W) 0 }
    Set-Item function:Clear-ChatqStrayFiles { @() }
    Set-Item function:Set-ChatqKeepAwake { param([bool]$On) }
    Set-Item function:Save-ChatqWatchState { param($W) }
    Set-Item function:Write-ChatqBoard { }
    Set-Item function:Write-ChatqWatchLog { param([string]$Text) $script:wlSeq.Add("log: $Text") }
    Set-Item function:Start-ChatqWatcherProcess { $script:wlSeq.Add('start a watcher'); $true }
    Invoke-ChatqWatchLoop -Foreground *> $null
}
finally {
    foreach ($k in $wlFnWas.Keys) { Set-Item "function:$k" $wlFnWas[$k] }
    $script:ChatqAskSent = $wlSentWas
    $script:ChatqForeground = $wlFgWas
    Restore-TestFile $script:ChatqWakePath $wlWake
}
$wlWant = "log: watcher $PID started ($script:ChatVersion)", 'reply open: False', 'reply open: False', 'log: queue empty', "log: watcher $PID stopped",
    'reply open: True', 'log: a phone alert went out as this watcher left - starting another to listen', 'start a watcher'
Check 'the respawn after queue empty, the window asked per call: shut at the pass and the recheck, open after the lock is let go - one watcher started, in that order' (
    ($script:wlSeq -join ' | ') -ceq ($wlWant -join ' | ')) ($script:wlSeq -join ' | ')

# A queued job its own id does not find: two files holding one id (a copy
# made by hand) and a blank id. The pick would look for it, find nothing and
# return, and the loop used to pick it again at once, every pass with no
# wait. Now it is passed over, named once in watcher.log, its files left as
# they are, and the job after it runs. Three scripted passes, as
# tests/vectors/timers.ps1 scripts them: the pass marker writes data/stop on
# the last. The pick finds the job again as Invoke-ChatqJob does. chatqd's
# replay of the same queue asserts the same lines
# (native/crates/chatqd/src/watch/timers_replay.rs).
$wlLostDir = Join-Path $sb 'lost-queue'
$null = New-Item -ItemType Directory -Path $wlLostDir -Force
$wlLostFiles = [ordered]@{ 'a.json' = @('d', 1); 'b.json' = @('d', 2); 'blank.json' = @(' ', 3); 'g.json' = @('g', 4) }
foreach ($k in $wlLostFiles.Keys) {
    $wlL = $wlLostFiles[$k]
    $wlJ = [ordered]@{ id = $wlL[0]; seq = $wlL[1]; state = 'queued'; kind = 'prompt'; title = "chat $($wlL[1])"; createdAt = "2026-10-15T08:0$($wlL[1]):00.0000000Z"; provider = 'claude'; history = @() }
    [System.IO.File]::WriteAllText((Join-Path $wlLostDir $k), ($wlJ | ConvertTo-Json -Depth 4), $utf8)
}
$wlLostBefore = @{}
foreach ($k in 'a.json', 'b.json', 'blank.json') { $wlLostBefore[$k] = [System.IO.File]::ReadAllText((Join-Path $wlLostDir $k), $utf8) }
$wlFnWas = @{}
foreach ($k in 'Restore-ChatqWatchState', 'Repair-ChatqInterrupted', 'Test-ChatqHeldWaiting', 'Test-ChatqReplyOpen', 'Invoke-ChatqWatchAutoScan', 'Clear-ChatqStrayFiles', 'Update-ChatqBlock',
    'Invoke-ChatqPick', 'Send-ChatqUsageSoon', 'Set-ChatqKeepAwake', 'Save-ChatqWatchState', 'Write-ChatqBoard', 'Write-ChatqWatchLog', 'Wait-ChatqUntil') { $wlFnWas[$k] = (Get-Item "function:$k").ScriptBlock }
$wlQueueWas = $script:ChatqQueueDir
$wlSentWas = $script:ChatqAskSent
$wlFgWas = $script:ChatqForeground
$wlWake = Read-TestFile $script:ChatqWakePath
$script:wlSeq = New-Object System.Collections.Generic.List[string]
$script:wlPass = 0
try {
    $script:ChatqQueueDir = $wlLostDir
    $script:ChatqAskSent = @{}
    Remove-Item -LiteralPath $script:ChatqStopPath, $script:ChatqWakePath -Force -EA SilentlyContinue
    Set-Item function:Restore-ChatqWatchState { param($W) $false }
    Set-Item function:Repair-ChatqInterrupted { }
    Set-Item function:Test-ChatqHeldWaiting {
        $script:wlPass++
        if ($script:wlPass -gt 3) { throw 'the loop went round more than 3 times' }
        $script:wlSeq.Add('pass')
        if ($script:wlPass -eq 3) { Set-Content -LiteralPath $script:ChatqStopPath -Value 'stop' -Encoding ASCII }
        $false
    }
    Set-Item function:Test-ChatqReplyOpen { param($Cfg) $false }
    Set-Item function:Invoke-ChatqWatchAutoScan { param($W) 0 }
    Set-Item function:Clear-ChatqStrayFiles { @() }
    Set-Item function:Update-ChatqBlock { param($W, $Job) $script:wlSeq.Add("block #$($Job.seq)") }
    Set-Item function:Invoke-ChatqPick {
        param($W, $Job)
        $j = Find-ChatqJob $Job.id -Exact
        if (-not $j -or $j.state -ne 'queued') { $script:wlSeq.Add("pick #$($Job.seq): not found"); return }
        $script:wlSeq.Add("run #$($j.seq)")
        Set-ChatqProp $j 'state' 'done'
        $null = Save-ChatqJob $j -Existing
    }
    Set-Item function:Send-ChatqUsageSoon { param($W, $Queued) $null }
    Set-Item function:Set-ChatqKeepAwake { param([bool]$On) }
    Set-Item function:Save-ChatqWatchState { param($W) }
    Set-Item function:Write-ChatqBoard { }
    Set-Item function:Write-ChatqWatchLog { param([string]$Text) if ($Text -notmatch '^watcher \d+ (started|stopped)') { $script:wlSeq.Add("log: $Text") } }
    Set-Item function:Wait-ChatqUntil { param([datetime]$When) $script:wlSeq.Add('wait') }
    Invoke-ChatqWatchLoop -Foreground *> $null
}
finally {
    foreach ($k in $wlFnWas.Keys) { Set-Item "function:$k" $wlFnWas[$k] }
    $script:ChatqQueueDir = $wlQueueWas
    $script:ChatqAskSent = $wlSentWas
    $script:ChatqForeground = $wlFgWas
    Remove-Item -LiteralPath $script:ChatqStopPath -Force -EA SilentlyContinue
    Restore-TestFile $script:ChatqWakePath $wlWake
}
$wlWant = 'pass', "log: a.json, b.json: the id 'd' does not find one job - left queued, not run, until that is put right",
    "log: blank.json: the id ' ' does not find one job - left queued, not run, until that is put right", 'block #4', 'run #4', 'pass', 'wait', 'pass', 'wait', 'log: stop requested'
$wlLostKept = @($wlLostBefore.Keys | Where-Object { [System.IO.File]::ReadAllText((Join-Path $wlLostDir $_), $utf8) -cne $wlLostBefore[$_] })
Check 'a queued job its own id does not find (an id two files hold, a blank id): passed over, each named once in watcher.log, its files untouched, the next job run, and the passes after wait' (
    ($script:wlSeq -join ' | ') -ceq ($wlWant -join ' | ') -and $wlLostKept.Count -eq 0) "$($script:wlSeq -join ' | ') / changed: $($wlLostKept -join ', ')"
Remove-Item -LiteralPath $wlLostDir -Recurse -Force -EA SilentlyContinue
