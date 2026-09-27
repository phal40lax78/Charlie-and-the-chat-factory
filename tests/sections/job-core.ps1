# tests/sections/job-core.ps1: dot-sourced by tests/run-tests.ps1 in its turn,
# never on its own - it uses what the runner and the sections before it set.

Section 'the job core'
# what chatq writes is what it always wrote, plus sendNow at the end
$jc = New-TestJob 'card redesign' 'field order'
$fields = ($jc.PSObject.Properties | ForEach-Object Name) -join ','
$want = 'v,id,seq,provider,sessionId,title,group,path,cwd,home,chatWhen,typed,rule,score,runnerUp,kind,promptFile,mode,modeAtQueue,model,runModel,first,sandbox,network,notBefore,state,attempts,retryAs,autoContinue,auto,cutUuid,deferUntil,deferWhy,deferredSince,busyAlerted,createdAt,startedAt,endedAt,runnerPid,result,history,sendNow'
Check 'a job made by chatq has the fields it always had, in order, and sendNow' ($fields -eq $want -and $jc.sendNow -eq $false) $fields
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
