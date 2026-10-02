# tests/sections/job-core.ps1: dot-sourced by tests/run-tests.ps1 in its turn,
# never on its own - it uses what the runner and the sections before it set.

Section 'the job core'
# what chatq writes is what it always wrote, plus sendNow, the Codex
# chat's effort (effortAtQueue) and its unknown sandbox word at the end
$jc = New-TestJob 'card redesign' 'field order'
$fields = ($jc.PSObject.Properties | ForEach-Object Name) -join ','
$want = 'v,id,seq,provider,sessionId,title,group,path,cwd,home,chatWhen,typed,rule,score,runnerUp,kind,promptFile,mode,modeAtQueue,model,runModel,first,sandbox,network,notBefore,state,attempts,retryAs,autoContinue,auto,cutUuid,deferUntil,deferWhy,deferredSince,busyAlerted,createdAt,startedAt,endedAt,runnerPid,result,history,sendNow,effortAtQueue,sandboxUnknown'
Check 'a job made by chatq has the fields it always had, in order, then sendNow, effortAtQueue and sandboxUnknown' ($fields -eq $want -and $jc.sendNow -eq $false -and $null -eq $jc.effortAtQueue -and $null -eq $jc.sandboxUnknown) $fields
$null = Remove-ChatqJob $jc 'test'
$rowCard = Get-ChatqRowById $idCard
$rowUpper = Get-ChatqRowById $idCard.ToUpperInvariant()
Check 'a row by its id - exact, any case, nothing fuzzy' ($rowCard.Id -eq $idCard -and $rowUpper.Id -eq $idCard -and -not (Get-ChatqRowById 'facade') -and -not (Get-ChatqRowById $idCard.Substring(0, 8))) "$($rowCard.Title)"
$before = @(Get-ChildItem -LiteralPath $script:ChatqQueueDir).Count
$nEmpty = New-ChatqJob -Row $rowCard -Prompt '   '
$nCopilot = New-ChatqJob -Row ([pscustomobject]@{ Provider = 'copilot'; Id = 'x'; Title = 'c' }) -Prompt 'hi'
$nKind = New-ChatqJob -Row $rowCard -Kind continue -Sources @{ Files = @($pFw) }
$nInfo = New-ChatqJob -Row ([pscustomobject]@{ Provider = 'claude'; Id = 'deadbeef-0000'; Title = 'gone'; Path = (Join-Path $sb 'no-such.jsonl'); Group = 'x' }) -Prompt 'hi'
$nCopy = New-ChatqJob -Row $rowCard -Prompt 'with a file' -Sources @{ Files = @($pFw, (Join-Path $sb 'no-such-file.png')) }
$after = @(Get-ChildItem -LiteralPath $script:ChatqQueueDir).Count
Check 'New-ChatqJob says why and leaves nothing: empty, Copilot, continue with files, a chat gone, a file gone' (
    $nEmpty.Code -eq 'empty' -and $nEmpty.Error -eq 'empty prompt - nothing queued' -and $nCopilot.Code -eq 'provider' -and $nKind.Code -eq 'kind' -and
    $nInfo.Code -eq 'info' -and $nCopy.Code -eq 'copy' -and $nCopy.Error -like 'a file could not be copied - nothing queued*' -and $after -eq $before -and -not $nCopy.Job) "$($nEmpty.Code) $($nCopilot.Code) $($nKind.Code) $($nInfo.Code) $($nCopy.Code) $before/$after"
# the console's own staged copy moves in; two jobs in one second get two ids
$stage = Join-Path $sb 'stage'
$null = New-Item -ItemType Directory -Path $stage -Force
$staged = Join-Path $stage 'shot 1.png'
[System.IO.File]::WriteAllBytes($staged, [byte[]](1, 2, 3))
$at = (Get-Date).AddHours(3)
$n1 = New-ChatqJob -Row $rowCard -Prompt 'first of two' -First -SendNow -Model 'sonnet' -NotBefore $at -Sources @{ Files = @($staged); Images = @(@{ Name = 'clip.png'; Bytes = [byte[]](9, 9) }) } -MoveSources -Rule 'picked'
$n2 = New-ChatqJob -Row $rowCard -Prompt 'second of two' -Rule 'picked'
$f1 = @($n1.Files | ForEach-Object Name | Sort-Object) -join ','
Check 'New-ChatqJob: first, send now, a model, not before, a staged file moved in and a pasted image' (
    $n1.Job -and $n1.Job.first -and $n1.Job.sendNow -and $n1.Job.runModel -eq 'sonnet' -and $n1.Job.rule -eq 'picked' -and
    [math]::Abs(((ConvertTo-ChatqDate $n1.Job.notBefore) - $at).TotalSeconds) -lt 2 -and $f1 -eq 'clip.png,shot-1.png' -and -not (Test-Path -LiteralPath $staged) -and
    (Read-ChatqPrompt $n1.Job) -eq 'first of two') "$f1 $($n1.Job.notBefore)"
Check 'two jobs for one chat inside a second get ids of their own' ($n2.Job -and $n2.Job.id -ne $n1.Job.id -and (Get-ChatqAttachDir $n2.Job) -ne (Get-ChatqAttachDir $n1.Job)) "$($n1.Job.id) $($n2.Job.id)"
Check 'and the first one sorts ahead of the queue' ((@(Get-ChatqJobs | Where-Object { $_.state -eq 'queued' })[0]).id -eq $n1.Job.id)
# an id and the same id with -2 after it: the whole id finds the first, not
# nothing - the watcher looks each job up by id before it runs it
$twins = @([pscustomobject]@{ id = '20260924-101010-abcd'; seq = 1 }, [pscustomobject]@{ id = '20260924-101010-abcd-2'; seq = 2 })
Check 'a job is found by its whole id even when another id starts with it' (
    (Find-ChatqJob '20260924-101010-abcd' $twins).seq -eq 1 -and (Find-ChatqJob '20260924-101010-abcd-2' $twins).seq -eq 2 -and
    -not (Find-ChatqJob '20260924-101010' $twins))
$noAdd = Add-ChatqJobFiles ([pscustomobject]@{ seq = 9; state = 'done'; kind = 'prompt' }) @{ Files = @($pFw) }
Check 'files go only to a job still waiting' ($noAdd.Error -eq '#9 is done - files added now would go nowhere')
$null = Remove-ChatqJob $n1.Job 'test'
$null = Remove-ChatqJob $n2.Job 'test'
Check 'Remove-ChatqJob takes its prompt and files too' (-not (Test-Path -LiteralPath (Get-ChatqAttachDir $n1.Job)) -and -not (Test-Path -LiteralPath (Get-ChatqPromptPath $n1.Job)))
# The console's Remove, timed by the clicks' own times (the mouse's
# Timestamp) on a console with no window: only the decision and the job are
# looked at. A click asks; the second half of a double-click is no answer;
# an ask 5 s old goes back to Remove, as a user off to VS Code between
# clicks finds it - it had stood as "sure?" for good, and a click on it only
# asked again; a click 0.4 s on from the latest ask removes.
$Hc = @{ Con = @{ Confirm = @{}; Sigs = @{}; Jobs = @(); Sel = $null; ShowLog = $false; JobsSig = $null } }
$rm = (New-ChatqJob -Row $rowCard -Prompt 'remove me').Job
$t = [int64]1000000
Invoke-ChatConsoleJobAction $Hc $rm.id 'remove' -At $t
$rmAsked = $Hc.Con.Confirm.ContainsKey([string]$rm.id) -and [bool](Find-ChatqJob $rm.id -Exact)
Invoke-ChatConsoleJobAction $Hc $rm.id 'remove' -At ($t + 150)
$rmDouble = [bool](Find-ChatqJob $rm.id -Exact)
Update-ChatConsoleAsks $Hc ($t + 5100)
$rmBack = -not $Hc.Con.Confirm.Count
Invoke-ChatConsoleJobAction $Hc $rm.id 'remove' -At ($t + 7000)
$rmAgain = [bool](Find-ChatqJob $rm.id -Exact) -and $Hc.Con.Confirm[[string]$rm.id] -eq $t + 7000
Invoke-ChatConsoleJobAction $Hc $rm.id 'remove' -At ($t + 8500)
$rmGone = -not (Find-ChatqJob $rm.id -Exact) -and -not $Hc.Con.Confirm.Count
Check 'the console''s Remove: a click asks, a double-click''s second half does not answer, an ask 5 s old goes back to Remove, a click 1.5 s after the latest ask removes' (
    $rmAsked -and $rmDouble -and $rmBack -and $rmAgain -and $rmGone) "$rmAsked $rmDouble $rmBack $rmAgain $rmGone"
Check 'Remove''s window, pure: none asks, under 0.4 s is a double-click, up to 7 s removes, past it asks again; the tick count''s wrap' (
    (@(-1, 150, 399, 400, 5000, 7000, 7001 | ForEach-Object { Get-ChatConsoleRemoveStep $_ }) -join ',') -eq 'ask,double,double,remove,remove,remove,stale' -and
    (Get-ChatConsoleSince 2147483000 -2147483000) -eq 1296) (@(-1, 150, 399, 400, 5000, 7000, 7001 | ForEach-Object { Get-ChatConsoleRemoveStep $_ }) -join ',')
# Remove-ChatqJob goes by the job's file: one the watcher started since the
# caller read it is kept, and no removal is logged
$rr = (New-ChatqJob -Row $rowCard -Prompt 'started meanwhile').Job
$rrDisk = Find-ChatqJob $rr.id -Exact
Set-ChatqJobState $rrDisk 'running' 'attempt 1'
$jl = Join-Path $script:ChatqLogDir 'jobs.log'
$jl0 = [System.IO.File]::ReadAllText($jl, $utf8).Length
$rrKept = -not (Remove-ChatqJob $rr 'the console') -and [bool](Find-ChatqJob $rr.id -Exact)
$jlNew = [System.IO.File]::ReadAllText($jl, $utf8).Substring($jl0)
Check 'Remove-ChatqJob refuses a job running on disk though the caller''s copy says queued, and logs no removal' ($rrKept -and $jlNew -notmatch 'removed by') "$rrKept [$jlNew]"
Set-ChatqJobState $rrDisk 'failed' 'test'
$null = Remove-ChatqJob $rrDisk 'test'
# A job's number is held from the moment its slot is taken. A chatq editor
# tab still open has its prompt file and no .json yet, and a job made then
# took the same number - and the same prompt file, over the tab's own text.
$openSlot = New-ChatqJobSlot $rowCard
$meanwhile = New-ChatqJob -Row $rowCard -Prompt 'made while a tab is open' -Rule 'picked'
Check 'a slot with no .json yet holds its number: a job made meanwhile gets the next, and a prompt file of its own' (
    $meanwhile.Job -and [int]$meanwhile.Job.seq -eq [int]$openSlot.Seq + 1 -and $meanwhile.Job.promptFile -ne $openSlot.File -and
    (Read-ChatqPrompt $meanwhile.Job) -eq 'made while a tab is open' -and [System.IO.File]::ReadAllText($openSlot.Path) -eq $openSlot.Header -and
    $meanwhile.Job.id -ne $openSlot.Id) "#$($openSlot.Seq) $($openSlot.File) $($openSlot.Id) / #$($meanwhile.Job.seq) $($meanwhile.Job.promptFile) $($meanwhile.Job.id)"
Check 'the folder that held a job''s id goes once its .json is saved, when no file went in' (
    (Test-Path -LiteralPath $openSlot.Dir) -and -not (Test-Path -LiteralPath (Get-ChatqAttachDir $meanwhile.Job)))
$null = Remove-ChatqJob $meanwhile.Job 'test'
Remove-Item -LiteralPath $openSlot.Path, $openSlot.Dir -Recurse -Force
Check 'a tab closed empty gives its number back' ((New-ChatqSeq) -eq [int]$openSlot.Seq) "$(New-ChatqSeq) for #$($openSlot.Seq)"
# job-numbers.lock held by someone else past its 3 s: the job is made anyway
$seqLock = [System.IO.File]::Open($script:ChatqSeqLockPath, 'OpenOrCreate', 'ReadWrite', 'None')
try { $unlocked = New-ChatqJob -Row $rowCard -Prompt 'the lock held elsewhere' -Rule 'picked' } finally { $seqLock.Dispose() }
Check 'job-numbers.lock held by another process: the job is made all the same' (
    $unlocked.Job -and -not $unlocked.Error -and (Read-ChatqPrompt $unlocked.Job) -eq 'the lock held elsewhere') "$($unlocked.Error)"
$null = Remove-ChatqJob $unlocked.Job 'test'
# Two processes making jobs for one chat at once - a shell's chatq and the
# overlay's console, say - never take one number, one id or one prompt file
$raceGo = Join-Path $sb 'seq-race.go'
$raceOut = Join-Path $sb 'seq-race.out'
$raceFile = Join-Path $sb 'seq-race.ps1'
[System.IO.File]::WriteAllText($raceFile, @"
`$ErrorActionPreference = 'Stop'
. '$(Join-Path $sb 'tool\Charlie-and-the-chat-factory.ps1')'
`$row = Get-ChatqRowById '$idCard' 'claude' '$($rowCard.Path)'
[System.IO.File]::WriteAllText('$raceGo', 'go')
`$got = foreach (`$i in 1..12) { (New-ChatqJob -Row `$row -Prompt "child `$i" -Rule 'picked').Job.seq }
[System.IO.File]::WriteAllText('$raceOut', (`$got -join ','))
"@, [System.Text.UTF8Encoding]::new($true))
$racePsi = New-Object System.Diagnostics.ProcessStartInfo
$racePsi.FileName = (Get-Process -Id $PID).Path
$racePsi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$raceFile`""
$racePsi.UseShellExecute = $false
$racePsi.CreateNoWindow = $true
$racer = [System.Diagnostics.Process]::Start($racePsi)
$raceUntil = (Get-Date).AddSeconds(90)
while (-not (Test-Path -LiteralPath $raceGo) -and -not $racer.HasExited -and (Get-Date) -lt $raceUntil) { Start-Sleep -Milliseconds 10 }
$raceMine = @(foreach ($i in 1..12) { (New-ChatqJob -Row $rowCard -Prompt "parent $i" -Rule 'picked').Job.seq })
$null = $racer.WaitForExit(90000)
$raceTheirs = @(if (Test-Path -LiteralPath $raceOut) { ([System.IO.File]::ReadAllText($raceOut)).Trim() -split ',' | Where-Object { $_ } })
$raceJobs = @(Get-ChatqJobs | Where-Object { $_.sessionId -eq $idCard -and (Read-ChatqPrompt $_) -match '^(parent|child) \d+$' })
Check 'two processes making jobs for one chat at once: no number, id or prompt file taken twice, none lost' (
    $raceMine.Count -eq 12 -and $raceTheirs.Count -eq 12 -and @(@($raceMine) + @($raceTheirs) | ForEach-Object { [int]$_ } | Sort-Object -Unique).Count -eq 24 -and
    $raceJobs.Count -eq 24 -and @($raceJobs | ForEach-Object { $_.id } | Sort-Object -Unique).Count -eq 24 -and
    @($raceJobs | ForEach-Object { $_.promptFile } | Sort-Object -Unique).Count -eq 24 -and
    @($raceJobs | ForEach-Object { Read-ChatqPrompt $_ } | Sort-Object -Unique).Count -eq 24) "mine $($raceMine -join ',') / theirs $($raceTheirs -join ',') / $($raceJobs.Count) jobs"
foreach ($x in $raceJobs) { $null = Remove-ChatqJob $x 'test' }
Remove-Item -LiteralPath $raceGo, $raceOut, $raceFile -Force -EA SilentlyContinue
# what a run did, from its log - the plain run above
$ran = @(Get-ChatqJobs | Where-Object { $_.state -eq 'done' -and (Test-Path -LiteralPath (Join-Path $script:ChatqLogDir "$($_.id).jsonl")) })[0]
$ents = @(Get-ChatqLogEntries $ran)
$tail = @(Get-ChatqLogEntries $ran -MaxBytes 200)
Check 'a run''s log read as entries: its start, the reply, how it ended; a tail read reads less' (
    @($ents | Where-Object Type -eq 'init').Count -and @($ents | Where-Object Type -eq 'result').Count -and $tail.Count -lt $ents.Count) "$(($ents | ForEach-Object Type) -join ',') / $($tail.Count)"
# a running job's log is held open for writing by its run
$held = [System.IO.File]::Open((Join-Path $script:ChatqLogDir "$($ran.id).jsonl"), 'Open', 'ReadWrite', 'ReadWrite')
try { $entsHeld = @(Get-ChatqLogEntries $ran) } finally { $held.Dispose() }
Check 'and read while a run still holds it open to write' ($entsHeld.Count -eq $ents.Count) "$($entsHeld.Count) of $($ents.Count)"
Check 'Stop-ChatqJobRun leaves a job that already ended as it ended' ((Stop-ChatqJobRun $ran) -eq 'not running' -and (Find-ChatqJob $ran.id).state -eq 'done')
# the watcher asked for without a wait: the wake goes, a process only when none runs
$spawnWas = $script:ChatqSpawn
$script:ChatqSpawns = 0
$script:ChatqSpawn = { $script:ChatqSpawns++; $true }
$lk = [System.IO.File]::Open($script:ChatqLockPath, 'OpenOrCreate', 'ReadWrite', 'None')
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$rq1 = Request-ChatqWatcher -Wake now
$ms1 = $sw.ElapsedMilliseconds
$sp1 = $rq1.Spawned
$st1 = Test-ChatqWatcherRequest $rq1 $true
$lk.Dispose()
$rq2 = Request-ChatqWatcher
$st2 = Test-ChatqWatcherRequest $rq2 $true
$rq2.At = (Get-Date).AddSeconds(-11)
$st3 = Test-ChatqWatcherRequest $rq2 $true
# one running when poked that has gone since, with jobs waiting: started again, once
$st4 = Test-ChatqWatcherRequest $rq1 $true
$st5 = Test-ChatqWatcherRequest $rq1 $false
$script:ChatqSpawn = $spawnWas
Check 'Request-ChatqWatcher never waits: a running watcher gets the wake, none gets a start' (
    $rq1.Alive -and -not $sp1 -and $ms1 -lt 500 -and $st1 -eq 'up' -and (Get-Content -LiteralPath $script:ChatqWakePath -Raw).Trim() -eq 'poke' -and
    $rq2.Spawned -and $st2 -eq 'waiting' -and $st3 -eq 'failed' -and $st4 -eq 'waiting' -and $rq1.Respawned -and $st5 -eq 'up' -and $script:ChatqSpawns -eq 2) "$ms1 ms $st1 $st2 $st3 $st4 $st5 spawns=$($script:ChatqSpawns)"
