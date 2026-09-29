# tests/sections/auto-continue.ps1: dot-sourced by tests/run-tests.ps1 in its
# turn, never on its own - it uses what the runner and the sections before it
# set.
#
# Auto-continue's automatic mode, config autoContinue "on" (src/auto-continue.ps1,
# docs/auto-continue-spec.md): a chat the limit cut off gets "continue"
# queued by itself. Chats of its own in a project folder of its own, cut off
# minutes ago; the registry's entries made here and handed in; no real
# watcher, no real push. Everything changed - the config, auto-continue.json,
# the markers, the jobs and chats made here - is put back at the end. The
# default, the reset ask, is tests/sections/reset-ask.ps1's.

Section 'auto-continue'
$acCfgWas = if (Test-Path -LiteralPath $script:ChatqConfigPath) { [System.IO.File]::ReadAllText($script:ChatqConfigPath, $utf8) } else { $null }
$acStateWas = if (Test-Path -LiteralPath $script:ChatqAutoPath) { [System.IO.File]::ReadAllText($script:ChatqAutoPath, $utf8) } else { $null }
$acJobsBefore = @(Get-ChatqJobs | ForEach-Object { [string]$_.id })
$acWas = @{ Spawn = $script:ChatqSpawn; Join = $script:ChatqJoinSeam; Idle = $script:ChatqIdleSeam; Send = $script:ChatqLiveSendSeam; Hold = $script:ChatShowHoldSeconds }
$script:ChatqSpawn = { $true }
$script:ChatqIdleSeam = 99999
# the sandbox's work folder by its path: the overlay section reuses $work
# for a screen's work area
$projAC = Join-Path (Join-Path $sb 'work') 'projAC'
$null = New-Item -ItemType Directory -Path $projAC -Force
Remove-Item -LiteralPath $script:ChatqAutoPath -Force -EA SilentlyContinue
Remove-Item -LiteralPath $script:ChatqAutoDir -Recurse -Force -EA SilentlyContinue
$script:ChatqAutoSaid = @{}
$script:ChatqAutoCache = $null
$cfg0 = Get-ChatqConfig
if ($cfg0.PSObject.Properties['autoContinue']) { $cfg0.PSObject.Properties.Remove('autoContinue'); Save-ChatqJson $script:ChatqConfigPath $cfg0 }

function Add-AcLimit {
    # the synthetic limit record Claude Code ends a cut-off turn with; its uuid
    param([string]$Path, [string]$Id, [double]$MinutesAgo = 1, [double]$ResetInMin = 60, [string]$Proj = $projAC)
    $u = [guid]::NewGuid().ToString()
    $t = (Get-Date).ToUniversalTime().AddMinutes(-$MinutesAgo)
    $s = [ordered]@{ parentUuid = $null; isSidechain = $false; type = 'assistant'; uuid = $u; timestamp = $t.ToString('o')
        message = [ordered]@{ model = '<synthetic>'; role = 'assistant'; content = @([ordered]@{ type = 'text'; text = "You've hit your session limit" }) }
        quotaLimits = [ordered]@{ status = 'rejected'; resetsAt = [DateTimeOffset]::UtcNow.AddMinutes($ResetInMin).ToUnixTimeSeconds(); rateLimitType = 'five_hour' }
        error = 'rate_limit'; isApiErrorMessage = $true; cwd = $Proj; sessionId = $Id }
    [System.IO.File]::AppendAllText($Path, ($s | ConvertTo-Json -Compress -Depth 8) + "`n", $utf8)
    return $u
}
function New-AcChat {
    # a chat of its own the limit cut off -MinutesAgo, resetting -ResetInMin on
    param([string]$Id, [string]$Title, [double]$MinutesAgo = 1, [double]$ResetInMin = 60, [string]$Mode = 'acceptEdits')
    $p = New-FakeChat $projAC $Id $Title 0.5 @('do the thing') -Mode $Mode
    $u = Add-AcLimit $p $Id $MinutesAgo $ResetInMin
    return [pscustomobject]@{ Path = $p; Id = $Id; Uuid = $u; Title = $Title }
}
function Get-AcCut([string]$Id) { @(Get-ChatqCutOffChats @() -Hours 48 | Where-Object { $_.Id -eq $Id })[0] }
function Get-AcJobs([string]$Id) { @(Get-ChatqJobs | Where-Object { $_.sessionId -eq $Id -and $_.state -in 'queued', 'running' }) }
function Invoke-AcScan([object[]]$Cut, [object[]]$Live = @()) { Invoke-ChatqAutoContinueScan -CutOff @($Cut) -Jobs @(Get-ChatqJobs) -Live $Live -Source watcher }
$acPanel = { param($id) [pscustomobject]@{ SessionId = $id; Pid = 4343; Status = 'idle'; Kind = 'interactive'; Entrypoint = 'claude-vscode' } }
$acTerm = { param($id) [pscustomobject]@{ SessionId = $id; Pid = 4344; Status = 'idle'; Kind = 'interactive'; Entrypoint = 'cli' } }
$acPrint = { param($id) [pscustomobject]@{ SessionId = $id; Pid = 4345; Status = 'idle'; Kind = 'print'; Entrypoint = 'claude-vscode' } }

# --- the setting: three values now ------------------------------------------------------
$acOn = { param($v) Get-ChatqAutoContinue ([pscustomobject]@{ autoContinue = $v }) }
Check 'autoContinue: "on" is the automatic mode; true still reads as ask - nothing written before turns it on; off and false are off' (
    (& $acOn 'on') -eq 'on' -and (& $acOn ' ON ') -eq 'on' -and (& $acOn $true) -eq 'ask' -and (& $acOn 'ask') -eq 'ask' -and (& $acOn $false) -eq 'off' -and (& $acOn 'off') -eq 'off') "$(& $acOn 'on') $(& $acOn $true)"
$null = Set-ChatqAutoContinue -Value on
$ac0 = Get-ChatqAutoConfig -Fresh
$sinceWas = $ac0.Since
Start-Sleep -Milliseconds 20
$null = Set-ChatqAutoContinue -Value on
$sinceSame = (Get-ChatqAutoConfig -Fresh).Since -eq $sinceWas
Check 'Set-ChatqAutoContinue -Value on: config.json''s top level says on, and since is written as it turns on - not again while it stays on' (
    (Get-ChatqConfig).autoContinue -eq 'on' -and $ac0.Mode -eq 'on' -and $ac0.On -and $ac0.Since -and ((Get-Date) - $ac0.Since).TotalMinutes -lt 2 -and $sinceSame) "$($ac0.Mode) $($ac0.Since)"

# --- the states, words exact: Get-ChatqAutoState is pure ---------------------------
$tn = [datetime]::new(2026, 9, 27, 12, 41, 0)
$d = [string][char]0xB7
$stCfg = { param([bool]$On = $true, $Chats = @{}, $Streak = @{}, $Since = $tn.AddDays(-1), [bool]$Exists = $true, [string]$Mode = '')
    $m = if ($Mode) { $Mode } elseif ($On) { 'on' } else { 'off' }
    [pscustomobject]@{ Mode = $m; On = $On; Since = $Since; Chats = $Chats; Streak = $Streak; Noticed = $true; Told = $true; Exists = $Exists } }
$stCut = { param([string]$Id = 's1', $At = $tn.AddMinutes(-1), $Reset = $tn.Date.AddHours(13), [string]$Why = 'limit', [string]$Uuid = 'u1')
    [pscustomobject]@{ Id = $Id; Title = 'Parser rewrite'; At = $At; ResetsAt = $Reset; Why = $Why; LimitUuid = $Uuid; Path = ''; Cwd = '' } }
$stJob = { param([string]$State = 'queued') [pscustomobject]@{ id = 'j12'; seq = 12; sessionId = 's1'; state = $State; auto = $true; cutUuid = 'u1'; title = 'Parser rewrite' } }
$S = { param($c, $j = @(), $l = @(), $cfg = (& $stCfg), $m = @{}, $e = @{}) Get-ChatqAutoState $c $j $l $cfg $m $tn $e }
$ready = & $S (& $stCut)
$armed = & $S (& $stCut) @(& $stJob) -e @{ j12 = '13:01' }
$armedNext = & $S (& $stCut) @(& $stJob) -e @{ j12 = 'next' }
$due = & $S (& $stCut -Reset $tn.AddMinutes(-11)) @(& $stJob) -e @{ j12 = '13:05 (open in VS Code)' }
$dueAfter = & $S (& $stCut -Reset $tn.AddMinutes(-11)) @(& $stJob) -e @{ j12 = 'after #3' }
$running = & $S (& $stCut) @(& $stJob 'running')
# behind a continue that waits for the same reset: after it, one at a time;
# behind a run in progress, the reset still ahead: at the reset
$armedTied = & $S (& $stCut) @((& $stJob), [pscustomobject]@{ id = 'j11'; seq = 11; sessionId = 's0'; state = 'queued' }) -e @{ j11 = '13:01'; j12 = 'after #11' }
$armedBusy = & $S (& $stCut) @((& $stJob), [pscustomobject]@{ id = 'j3'; seq = 3; sessionId = 's0'; state = 'running' }) -e @{ j3 = 'running'; j12 = 'after #3' }
$off = & $S (& $stCut) -cfg (& $stCfg $false)
$askSt = & $S (& $stCut) -cfg (& $stCfg $false -Mode 'ask')
$always = & $S (& $stCut) -cfg (& $stCfg $false @{ s1 = [pscustomobject]@{ auto = 'always' } })
$never = & $S (& $stCut) -cfg (& $stCfg $true @{ s1 = [pscustomobject]@{ auto = 'never' } })
$term = & $S (& $stCut) -l @(& $acTerm 's1')
$print = & $S (& $stCut) -l @(& $acPrint 's1')
$panel = & $S (& $stCut) -l @(& $acPanel 's1')
$stopped = & $S (& $stCut) -cfg (& $stCfg $true @{} @{ s1 = [pscustomobject]@{ n = 2; uuid = 'u1' } })
$stoppedOld = & $S (& $stCut) -cfg (& $stCfg $true @{} @{ s1 = [pscustomobject]@{ n = 2; uuid = 'u0' } })
$declined = & $S (& $stCut) -m @{ 's1_u1' = [pscustomobject]@{ jobId = 'gone'; seq = @(9) } }
$failedJ = & $S (& $stCut) @([pscustomobject]@{ id = 'jf'; seq = 9; sessionId = 's1'; state = 'failed'; result = [pscustomobject]@{ reason = 'gave up: 5 tries' } }) -m @{ 's1_u1' = [pscustomobject]@{ jobId = 'jf'; seq = @(9) } }
$failedE = & $S (& $stCut) -m @{ 's1_u1' = [pscustomobject]@{ error = 'the chat could not be read' } }
$farSince = & $S (& $stCut -At $tn.AddDays(-2).AddHours(1))
$far12 = & $S (& $stCut -At $tn.AddHours(-13) -Reset $tn.AddMinutes(20))
$far24 = & $S (& $stCut -Reset $tn.AddHours(30))
$farNoSince = & $S (& $stCut) -cfg (& $stCfg $true @{} @{} $null $false)
$late = & $S (& $stCut -At $tn.AddHours(-2) -Reset $tn.AddMinutes(-45))
$over = & $S (& $stCut -Why 'overloaded')
$farDay = & $S (& $stCut -Reset $tn.AddHours(30))
$ws = { param($x) "$($x.State)|$($x.Words)|$($x.Long)" }
Check 'the states: ready, armed, due, running - words exact, short on the row and in full beside it' (
    (& $ws $ready) -eq "ready|resets 13:00|cut off - resets 13:00 $d auto-continue queues it" -and
    (& $ws $armed) -eq 'armed|#12 auto 13:01|#12 auto-continues 13:01' -and (& $ws $armedNext) -eq 'armed|#12 auto 13:01|#12 auto-continues 13:01' -and
    (& $ws $due) -eq 'due|#12 auto 13:05|#12 auto-continues 13:05 (open in VS Code)' -and (& $ws $dueAfter) -eq 'due|#12 auto after #3|#12 auto-continues after #3' -and
    (& $ws $running) -eq 'running|#12 running|#12 running' -and $armed.Seq -eq 12 -and $armed.JobId -eq 'j12' -and $armed.At -eq '13:01' -and
    (& $ws $armedTied) -eq 'armed|#12 auto after #11|#12 auto-continues after #11' -and $armedTied.Why -like '*sends "continue" after #11' -and
    (& $ws $armedBusy) -eq 'armed|#12 auto 13:01|#12 auto-continues 13:01') (
    @($ready, $armed, $armedNext, $due, $dueAfter, $running, $armedTied, $armedBusy) | ForEach-Object { & $ws $_ }) -join ' / '
Check 'the states: off - and ask, which says it asks - always with them, never, terminal (a terminal''s claude, any entry not a panel''s), a panel''s is no bar' (
    (& $ws $off) -eq 'off|resets 13:00|cut off - resets 13:00' -and $off.Why -like 'auto-continue is off*' -and $askSt.State -eq 'off' -and $askSt.Why -like 'auto-continue asks once the limit is over*' -and
    $always.State -eq 'ready' -and
    (& $ws $never) -eq "never|resets 13:00 $d never|cut off - resets 13:00 $d never auto" -and
    (& $ws $term) -eq "terminal|resets 13:00 $d terminal|cut off - resets 13:00 $d in a terminal" -and $print.State -eq 'terminal' -and $panel.State -eq 'ready') (
    @($off, $askSt, $always, $never, $term, $print, $panel) | ForEach-Object { & $ws $_ }) -join ' / '
Check 'the states: stopped on its own cut-off only, declined, failed (its job, or the marker''s error)' (
    (& $ws $stopped) -eq "stopped|resets 13:00 $d stopped|cut off - resets 13:00 $d auto stopped" -and $stoppedOld.State -eq 'ready' -and
    (& $ws $declined) -eq "declined|resets 13:00 $d skipped|cut off - resets 13:00 $d not continued" -and
    (& $ws $failedJ) -eq "failed|resets 13:00 $d failed|cut off - resets 13:00 $d auto-continue failed" -and $failedJ.Why -like '#9 ended failed: gave up*' -and
    $failedE.State -eq 'failed' -and $failedE.Why -like '*the chat could not be read') (
    @($stopped, $stoppedOld, $declined, $failedJ, $failedE) | ForEach-Object { & $ws $_ }) -join ' / '
# the reset ask's markers are this mode's too: leave is declined, a continue
# whose job failed is failed - its jobs named by number
$askLeave = & $S (& $stCut) -m @{ 's1_u1' = [pscustomobject]@{ at = 'x'; answer = 'leave'; source = 'overlay'; seq = @() } }
$askGo = & $S (& $stCut) @([pscustomobject]@{ id = 'jq'; seq = 14; sessionId = 's1'; state = 'failed' }) -m @{ 's1_u1' = [pscustomobject]@{ at = 'x'; answer = 'continue'; source = 'console'; seq = @(14) } }
$askGoDone = & $S (& $stCut) @([pscustomobject]@{ id = 'jq'; seq = 14; sessionId = 's1'; state = 'done' }) -m @{ 's1_u1' = [pscustomobject]@{ at = 'x'; answer = 'continue'; source = 'console'; seq = @(14) } }
Check 'a cut-off the reset ask answered: leave is declined, never queued here; a continue whose job failed is failed; one that ran, declined' (
    $askLeave.State -eq 'declined' -and $askLeave.Why -like 'left as it was when the reset was asked about*' -and $askGo.State -eq 'failed' -and $askGo.Why -like '#14 ended failed*' -and
    $askGoDone.State -eq 'declined') "$($askLeave.State) $($askGo.State) $($askGoDone.State)"
# spike A3: a chat woken before its reset hits the limit again, a new uuid,
# the same reset - a continue removed for the first holds for it
$sibMk = { param($r, $jid = 'gone') @{ 's1_u1' = [pscustomobject]@{ sessionId = 's1'; jobId = $jid; seq = @(9); resetsAt = ([datetime]$r).ToUniversalTime().ToString('o') } } }
$sibSame = & $S (& $stCut -Uuid 'u2') -m (& $sibMk $tn.Date.AddHours(13))
$sibOther = & $S (& $stCut -Uuid 'u2') -m (& $sibMk $tn.Date.AddHours(8))
$sibFailed = & $S (& $stCut -Uuid 'u2') @([pscustomobject]@{ id = 'jf'; seq = 9; sessionId = 's1'; state = 'failed' }) -m (& $sibMk $tn.Date.AddHours(13) 'jf')
$sibAsk = & $S (& $stCut -Uuid 'u2') -m @{ 's1_u1' = [pscustomobject]@{ answer = 'leave'; seq = @(); resetsAt = $tn.Date.AddHours(13).ToUniversalTime().ToString('o') } }
Check 'a new cut-off with the same reset as one whose continue was removed, or that the ask left: declined too; another reset, or a failed one, is not' (
    $sibSame.State -eq 'declined' -and $sibOther.State -eq 'ready' -and $sibFailed.State -eq 'ready' -and $sibAsk.State -eq 'declined') "$($sibSame.State) $($sibOther.State) $($sibFailed.State) $($sibAsk.State)"
Check 'the states: far (before since, over 12 h, reset over 24 h, no since yet), late, and a 529 as it was' (
    (& $ws $farSince) -eq "far|resets 13:00 $d by hand|cut off - resets 13:00 $d by hand" -and $farSince.Why -like '*before auto-continue was on*' -and
    $far12.State -eq 'far' -and $far12.Why -like '*over 12 h ago*' -and $far24.State -eq 'far' -and $far24.Why -like '*weekly*' -and
    $farDay.Words -like "resets * $d by hand" -and $farDay.Words -match 'resets [A-Z][a-z]{2} \d\d:\d\d' -and $farNoSince.State -eq 'far' -and
    (& $ws $late) -eq "late|limit over $d by hand|cut off - limit over $d by hand" -and
    (& $ws $over) -eq 'overloaded|529 - waits for Claude|529 - waits for Claude') (
    @($farSince, $far12, $far24, $farDay, $farNoSince, $late, $over) | ForEach-Object { & $ws $_ }) -join ' / '

# --- the scan -------------------------------------------------------------------------
# since was written as the switch turned on: a cut-off from before it - one
# on screen as it was chosen - is shown, never queued
$idA0 = 'ac000000-0000-4000-8000-000000000000'
$a0 = New-AcChat $idA0 'Auto before since chat' 5 45
$fw = Get-AcCut $idA0
$r0 = Invoke-AcScan @($fw)
Check 'a cut-off from before the switch turned on is far - never queued' (
    @($r0.Queued).Count -eq 0 -and @($r0.Skipped | Where-Object { $_.State -eq 'far' }).Count -eq 1 -and $fw.LimitUuid -eq $a0.Uuid) "$(@($r0.Skipped | ForEach-Object State) -join ',') $($fw.LimitUuid)"
# no since at all - set on by hand in config.json: the first scan writes it
$null = Update-ChatqAutoState { param($v) $v.Since = $null }
$rNs = Invoke-AcScan @($fw)
$acNs = Get-ChatqAutoConfig -Fresh
Check 'a scan that finds no since writes it, and queues nothing from before it' ($acNs.Since -and ((Get-Date) - $acNs.Since).TotalMinutes -lt 2 -and @($rNs.Queued).Count -eq 0) "$($acNs.Since)"
# the rest go as if auto-continue had been on for a few hours
$null = Update-ChatqAutoState { param($v) $v.Since = (Get-Date).AddHours(-3) }
# every change is made holding data/auto-continue.lock: with another writer
# in the middle of its own, one waits, then fails rather than save over it
$lkId = 'ac00lock-0000-4000-8000-000000000000'
$alk = [System.IO.File]::Open($script:ChatqAutoLockPath, 'OpenOrCreate', 'ReadWrite', 'None')
$lkThrew = $false
$lkAt = Get-Date
try { $null = Update-ChatqAutoState { param($v) $v.Chats[$lkId] = [pscustomobject]@{ auto = 'never'; at = ''; title = 'x' } } } catch { $lkThrew = $true } finally { $alk.Dispose() }
$lkWaited = ((Get-Date) - $lkAt).TotalSeconds
$lkHeld = [bool](Get-ChatqAutoConfig -Fresh).Chats[$lkId]
$lkVal = Update-ChatqAutoState { param($v) $v.Chats[$lkId] = [pscustomobject]@{ auto = 'never'; at = ''; title = 'x' } }
$lkSaved = $lkVal.Chats[$lkId].auto -eq 'never'
$null = Update-ChatqAutoState { param($v) $v.Chats.Remove($lkId) }
Check 'data/auto-continue.json changes under its lock: held by another writer, a change waits about 3 s and fails unsaved; free, it saves' (
    $lkThrew -and -not $lkHeld -and $lkWaited -ge 2.5 -and $lkSaved -and -not (Get-ChatqAutoConfig -Fresh).Chats[$lkId]) "$lkThrew $lkHeld $lkWaited $lkSaved"

$idA1 = 'ac000001-0000-4000-8000-000000000001'
$a1 = New-AcChat $idA1 'Auto closed chat' 2 45
$c1 = Get-AcCut $idA1
$r1 = Invoke-AcScan @($c1)
$j1 = @(Get-AcJobs $idA1)[0]
$mk1 = Read-ChatqJson (Join-Path $script:ChatqAutoDir "$($idA1)_$($a1.Uuid).json")
$jl = [System.IO.File]::ReadAllText((Join-Path $script:ChatqLogDir 'jobs.log'), $utf8)
$resetHm = Format-ChatqAutoTime $c1.ResetsAt
Check 'a chat not open anywhere, cut off: one continue queued, kind continue, rule auto, auto, its cut-off''s uuid, the chat''s own mode, no hold' (
    @($r1.Queued).Count -eq 1 -and $j1 -and $j1.kind -eq 'continue' -and $j1.rule -eq 'auto' -and $j1.auto -eq $true -and $j1.cutUuid -eq $a1.Uuid -and
    $j1.modeAtQueue -eq 'acceptEdits' -and $j1.model -eq 'claude-opus-5' -and -not $j1.mode -and -not $j1.deferUntil -and $c1.LimitUuid -eq $a1.Uuid) ($j1 | ConvertTo-Json -Compress -Depth 3)
Check 'its marker - the ask''s name and shape: answer continue, the job''s number - names the job; jobs.log says it is auto, with the limit and the reset' (
    $mk1 -and $mk1.jobId -eq $j1.id -and (@($mk1.seq) -join ',') -eq "$($j1.seq)" -and $mk1.answer -eq 'continue' -and $mk1.source -eq 'watcher' -and $mk1.sessionId -eq $idA1 -and
    (Read-ChatqAskState)["$($idA1)_$($a1.Uuid)"] -and
    $jl -like "*#$($j1.seq) queued (continue, auto - limit $(Format-ChatqAutoTime $c1.At), resets $resetHm) $d Auto closed chat*") ($mk1 | ConvertTo-Json -Compress)
$r1b = Invoke-AcScan @($c1)
Check 'scanned again: nothing more - its continue is queued' (@($r1b.Queued).Count -eq 0 -and @(Get-AcJobs $idA1).Count -eq 1)
$null = Remove-ChatqJob $j1 'chip'
$r1c = Invoke-AcScan @($c1)
$st1 = Get-ChatqAutoState $c1 @(Get-ChatqJobs) @() (Get-ChatqAutoConfig) (Get-ChatqAutoMarkers) (Get-Date)
Check 'a continue removed never comes back for the same cut-off: its marker stays, and the chat is declined' (@($r1c.Queued).Count -eq 0 -and -not @(Get-AcJobs $idA1).Count -and
    $st1.State -eq 'declined') $st1.State
$u1b = Add-AcLimit $a1.Path $idA1 0.5 60
$c1b = Get-AcCut $idA1
$r1d = Invoke-AcScan @($c1b)
$j1b = @(Get-AcJobs $idA1)[0]
Check 'a new cut-off of the same chat - a new uuid - is queued again' (@($r1d.Queued).Count -eq 1 -and $j1b.cutUuid -eq $u1b -and $c1b.LimitUuid -eq $u1b) "$($j1b.cutUuid) $u1b"
# one the reset ask left, before the switch went on: never queued here
$idAk = 'ac00000a-0000-4000-8000-00000000000a'
$aK = New-AcChat $idAk 'Auto asked chat' 2 45
$cK = Get-AcCut $idAk
$null = Save-ChatqAskAnswer -Keys @(Get-ChatqCutKey $cK) -Answer leave -Source overlay
$rK = Invoke-AcScan @($cK)
Check 'a cut-off the reset ask answered leave is not queued - the same marker' (@($rK.Queued).Count -eq 0 -and -not @(Get-AcJobs $idAk).Count -and
    @($rK.Skipped | Where-Object { $_.State -eq 'declined' }).Count -eq 1) "$(@($rK.Skipped | ForEach-Object State) -join ',')"

$idA2 = 'ac000002-0000-4000-8000-000000000002'
$a2 = New-AcChat $idA2 'Auto panel chat' 2 30
$c2 = Get-AcCut $idA2
$r2 = Invoke-AcScan @($c2) @(& $acPanel $idA2)
$j2 = @(Get-AcJobs $idA2)[0]
$du2 = ConvertTo-ChatqDate $j2.deferUntil
$eta2 = (Get-ChatqEta @($j2) @{})[$j2.id]
Check 'a chat open in a VS Code panel: queued, held till 5 minutes past the reset, and its time says why' ($j2 -and $j2.deferWhy -eq 'vscode' -and $du2 -and
    [Math]::Abs(($du2 - $c2.ResetsAt.AddMinutes(5)).TotalSeconds) -lt 2 -and $eta2 -eq "$(Format-ChatqAutoTime $du2) (open in VS Code)") "$($j2.deferUntil) $eta2"

$idA3 = 'ac000003-0000-4000-8000-000000000003'
$a3 = New-AcChat $idA3 'Auto terminal chat' 2 30
$c3 = Get-AcCut $idA3
$r3 = Invoke-AcScan @($c3) @(& $acTerm $idA3)
$r3p = Invoke-AcScan @($c3) @(& $acPrint $idA3)
$none3 = -not @(Get-AcJobs $idA3).Count
$r3b = Invoke-AcScan @($c3)
Check 'held by a terminal''s claude, or any entry not a panel''s: not queued - and once it is gone, the next scan queues it' ($none3 -and
    @($r3.Skipped | Where-Object { $_.State -eq 'terminal' }).Count -eq 1 -and @($r3p.Skipped | Where-Object { $_.State -eq 'terminal' }).Count -eq 1 -and
    @($r3b.Queued).Count -eq 1) "$none3 $(@($r3.Skipped).State) $(@($r3b.Queued).Count)"
$ovl = [System.IO.File]::ReadAllText((Join-Path $script:ChatqLogDir 'watcher.log'), $utf8)
Check 'said once in the log: not queued - in a terminal; the queued one too' (@([regex]::Matches($ovl, "auto-continue: $($idA3.Substring(0, 8)) not queued - in a terminal")).Count -eq 1 -and
    $ovl -like "*auto-continue: queued #* for $($idA3.Substring(0, 8)) (scan)*")

$idA4 = 'ac000004-0000-4000-8000-000000000004'
$p4 = New-FakeChat $projAC $idA4 'Auto overloaded chat' 0.02 @('x') -Overloaded
$c4 = Get-AcCut $idA4
$r4 = Invoke-AcScan @($c4)
$other = @(Get-ChatqCutOffChats @() -Hours 200 | Where-Object { $_.Id -eq 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' })
Check 'a 529 is not auto-continued; a chat under another config dir is not even scanned' ($c4.Why -eq 'overloaded' -and @($r4.Queued).Count -eq 0 -and
    -not @(Get-AcJobs $idA4).Count -and -not $other.Count) "$($c4.Why) $(@($r4.Queued).Count) $($other.Count)"

# the switch, and one chat's own
$idA5 = 'ac000005-0000-4000-8000-000000000005'
$a5 = New-AcChat $idA5 'Auto switched chat' 2 30
$c5 = Get-AcCut $idA5
$null = Set-ChatqAutoContinue -Value off
$r5 = Invoke-AcScan @($c5)
$off5 = -not @(Get-AcJobs $idA5).Count -and @($r5.Skipped | Where-Object { $_.State -eq 'off' }).Count -eq 1
$null = Set-ChatqAutoContinue -Value ask
$r5a = Invoke-AcScan @($c5)
$ask5 = -not @(Get-AcJobs $idA5).Count -and @($r5a.Skipped | Where-Object { $_.State -eq 'off' }).Count -eq 1
$null = Set-ChatqAutoChat -Id $idA5 -Title 'Auto switched chat' -Value always
$r5b = Invoke-AcScan @($c5)
$always5 = @($r5b.Queued).Count -eq 1
# on again: since from now - and back to three hours, for the rest
$null = Set-ChatqAutoContinue -Value on
$sinceOn = (Get-ChatqAutoConfig -Fresh).Since
$null = Update-ChatqAutoState { param($v) $v.Since = (Get-Date).AddHours(-3) }
$null = Set-ChatqAutoChat -Id $idA5 -Title 'Auto switched chat' -Value never
$never5 = -not @(Get-AcJobs $idA5).Count
$u5 = Add-AcLimit $a5.Path $idA5 0.5 60
$r5c = Invoke-AcScan @(Get-AcCut $idA5)
Check 'the switch off or ask: not queued; always with it off: queued; on again writes since anew; never: its continue removed, and a new cut-off not queued' (
    $off5 -and $ask5 -and $always5 -and $sinceOn -and ((Get-Date) - $sinceOn).TotalMinutes -lt 1 -and $never5 -and
    @($r5c.Queued).Count -eq 0 -and @($r5c.Skipped | Where-Object { $_.State -eq 'never' }).Count -eq 1) "$off5 $ask5 $always5 $sinceOn $never5 $(@($r5c.Skipped).State)"
$null = Set-ChatqAutoChat -Id $idA5 -Title 'Auto switched chat' -Value default

$idA6 = 'ac000006-0000-4000-8000-000000000006'
$a6 = New-AcChat $idA6 'Auto already queued chat' 2 30
$c6 = Get-AcCut $idA6
$mine6 = New-ChatqJob -Row (Get-ChatqRowById $idA6 'claude' $a6.Path) -Kind continue -Rule continue
$r6 = Invoke-AcScan @($c6)
Check 'a job already queued for it - one you queued: nothing more, and no marker made' (@($r6.Queued).Count -eq 0 -and @(Get-AcJobs $idA6).Count -eq 1 -and
    -not (Test-Path -LiteralPath (Join-Path $script:ChatqAutoDir "$($idA6)_$($a6.Uuid).json")))

$idA7 = 'ac000007-0000-4000-8000-000000000007'
$a7 = New-AcChat $idA7 'Auto late chat' 75 -45
$idA8 = 'ac000008-0000-4000-8000-000000000008'
$a8 = New-AcChat $idA8 'Auto weekly chat' 2 (30 * 60)
$r78 = Invoke-AcScan @((Get-AcCut $idA7), (Get-AcCut $idA8))
Check 'first seen 45 minutes past its reset: late; a reset 30 h out: far - neither queued' (@($r78.Queued).Count -eq 0 -and
    (@($r78.Skipped | Sort-Object Id | ForEach-Object State) -join ',') -eq 'late,far') (@($r78.Skipped | ForEach-Object { "$($_.Id.Substring(0, 8))=$($_.State)" }) -join ',')
# gone again: a reset 30 h out would hold every job of the lane that long
Remove-Item -LiteralPath $a7.Path, $a8.Path -Force

# the marker
$idA9 = 'ac000009-0000-4000-8000-000000000009'
$a9 = New-AcChat $idA9 'Auto marker chat' 2 30
$k9 = "$($idA9)_$($a9.Uuid)"
$first9 = New-ChatqAutoMarker $k9 @{ at = 'x' }
$second9 = New-ChatqAutoMarker $k9 @{ at = 'y' }
Set-ChatqAutoMarker $k9 ([ordered]@{ at = 'x'; error = 'the chat could not be read' })
$r9 = Invoke-AcScan @(Get-AcCut $idA9)
$st9 = Get-ChatqAutoState (Get-AcCut $idA9) @(Get-ChatqJobs) @() (Get-ChatqAutoConfig) (Get-ChatqAutoMarkers) (Get-Date)
Check 'a marker is made once - the second exclusive create is refused, as is a name no key has - and one holding an error is never tried again' ($first9 -and -not $second9 -and
    -not (New-ChatqAutoMarker '..\x_y' @{ at = 'z' }) -and @($r9.Queued).Count -eq 0 -and -not @(Get-AcJobs $idA9).Count -and $st9.State -eq 'failed') "$first9 $second9 $($st9.State)"
$oldM = Join-Path $script:ChatqAutoDir 'deadbeef-0000-4000-8000-000000000000_old.json'
[System.IO.File]::WriteAllText($oldM, '{"at":"x"}', $utf8)
(Get-Item -LiteralPath $oldM).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddDays(-9)
$null = Invoke-AcScan @()
Check 'markers over 8 days old are deleted by a scan' (-not (Test-Path -LiteralPath $oldM))
$u9 = [guid]::NewGuid()
$t9 = [datetime]::new(2026, 9, 27, 3, 0, 0, [DateTimeKind]::Utc)
Check 'a cut-off''s id past its chat: its record''s uuid, or its time where it has none - the marker''s name after the session id' (
    (Get-ChatqCutId ([pscustomobject]@{ Id = 'a1'; At = $t9 })) -eq "$($t9.Ticks)" -and (Get-ChatqCutId ([pscustomobject]@{ Id = 'a1'; LimitUuid = "$u9" })) -eq "$u9" -and
    $null -eq (Get-ChatqCutId ([pscustomobject]@{ Id = 'a/b'; LimitUuid = 'c' })) -and
    (Get-ChatqAutoMarkerPath ([pscustomobject]@{ sessionId = 'a1'; cutUuid = "$u9" })) -eq (Join-Path $script:ChatqAutoDir "a1_$u9.json") -and
    $null -eq (Get-ChatqAutoMarkerPath ([pscustomobject]@{ sessionId = 'a1'; cutUuid = '..\..' })))

# two scans at once, as the overlay and the watcher may: one job
$idAR = 'ac0000aa-0000-4000-8000-0000000000aa'
$aR = New-AcChat $idAR 'Auto race chat' 2 30
$go = Join-Path $sb 'ac-race-go'
Remove-Item -LiteralPath $go -Force -EA SilentlyContinue
$raceCode = {
    param($Tool, $Go, $Id, $N)
    $ChatNoKeyBindings = $true
    . $Tool
    [System.IO.File]::WriteAllText("$Go.ready$N", 'x')
    $t0 = Get-Date
    while (-not (Test-Path -LiteralPath $Go) -and ((Get-Date) - $t0).TotalSeconds -lt 60) { Start-Sleep -Milliseconds 5 }
    $c = @(Get-ChatqCutOffChats @() -Hours 48 | Where-Object { $_.Id -eq $Id })
    $r = Invoke-ChatqAutoContinueScan -CutOff $c -Jobs @(Get-ChatqJobs) -Live @() -Source watcher
    @($r.Queued).Count
}
$race = @(foreach ($n in 1, 2) {
        $ps = [powershell]::Create()
        [void]$ps.AddScript($raceCode.ToString()).AddArgument((Join-Path $sb 'tool\VS-code-chat-manager.ps1')).AddArgument($go).AddArgument($idAR).AddArgument($n)
        @{ Ps = $ps; H = $ps.BeginInvoke() }
    })
$t0 = Get-Date
while (-not ((Test-Path -LiteralPath "$go.ready1") -and (Test-Path -LiteralPath "$go.ready2")) -and ((Get-Date) - $t0).TotalSeconds -lt 90) { Start-Sleep -Milliseconds 50 }
[System.IO.File]::WriteAllText($go, 'go')
$raceGot = @(foreach ($x in $race) { try { @($x.Ps.EndInvoke($x.H))[-1] } catch { "err: $($_.Exception.Message)" } finally { $x.Ps.Dispose() } })
Remove-Item -Path "$go*" -Force -EA SilentlyContinue
Check 'two scans at once - two runspaces, as the overlay and the watcher - queue one continue between them' (@(Get-AcJobs $idAR).Count -eq 1 -and
    (($raceGot | ForEach-Object { [int]$_ } | Measure-Object -Sum).Sum) -eq 1) "jobs $(@(Get-AcJobs $idAR).Count), said $($raceGot -join ',')"

# --- the watcher --------------------------------------------------------------------
$W = New-ChatqWatchState
$env:FAKE_RECORD = $rec
# the hold: a panel holds the chat, and the reset plus 5 minutes is ahead
$idW1 = 'ac0000b1-0000-4000-8000-0000000000b1'
$w1 = New-AcChat $idW1 'Auto hold chat' 2 -1
$rw1 = Invoke-AcScan @(Get-AcCut $idW1)
$jw1 = @(Get-AcJobs $idW1)[0]
$env:FAKE_AGENTS = '[{"pid":1,"sessionId":"' + $idW1 + '","kind":"interactive","status":"idle","entrypoint":"claude-vscode"}]'
Invoke-ChatqJob $W (Find-ChatqJob $jw1.id)
$jw1 = Find-ChatqJob $jw1.id
$du = ConvertTo-ChatqDate $jw1.deferUntil
$wl = [System.IO.File]::ReadAllText((Join-Path $script:ChatqLogDir 'watcher.log'), $utf8)
$wantHold = (Get-AcCut $idW1).ResetsAt.AddMinutes(5)
Check 'the watcher holds an auto continue for a chat open in VS Code till 5 minutes past the reset, and says so' ($jw1.state -eq 'queued' -and $jw1.deferWhy -eq 'vscode' -and
    $du -and [Math]::Abs(($du - $wantHold).TotalSeconds) -lt 2 -and $wl -like "*#$($jw1.seq) held: auto-continue waits until $($wantHold.ToString('HH:mm')) - the chat is open in VS Code*") "$($jw1.state) $($jw1.deferUntil) $($jw1.deferWhy)"
# a terminal took it since: left to it, quietly
$env:FAKE_AGENTS = '[{"pid":1,"sessionId":"' + $idW1 + '","kind":"interactive","status":"idle","entrypoint":"cli"}]'
Set-ChatqProp $jw1 'deferUntil' $null; Save-ChatqJob $jw1
$fa0 = Get-AlertCount '*failed*'
Invoke-ChatqJob $W (Find-ChatqJob $jw1.id)
$jw1 = Find-ChatqJob $jw1.id
Check 'a terminal holding the chat as it is about to run: skipped, no alert' ($jw1.state -eq 'skipped' -and $jw1.result.reason -like '*terminal*' -and (Get-AlertCount '*failed*') -eq $fa0) "$($jw1.state) $($jw1.result.reason)"
Remove-Item env:FAKE_AGENTS
# gone: deleted since - skipped without an alert, where a job you queued still fails and alerts
$idW2 = 'ac0000b2-0000-4000-8000-0000000000b2'
$w2 = New-AcChat $idW2 'Auto gone chat' 2 -1
$null = Invoke-AcScan @(Get-AcCut $idW2)
$jw2 = @(Get-AcJobs $idW2)[0]
$mine2 = New-ChatqJob -Row (Get-ChatqRowById $idW2 'claude' $w2.Path) -Prompt 'mine' -Kind prompt
Remove-Item -LiteralPath $w2.Path -Force
$ga0 = Get-AlertCount '*chat is gone*'
Invoke-ChatqJob $W (Find-ChatqJob $jw2.id)
$ga1 = Get-AlertCount '*chat is gone*'
Invoke-ChatqJob $W (Find-ChatqJob $mine2.Job.id)
$ga2 = Get-AlertCount '*chat is gone*'
$jw2 = Find-ChatqJob $jw2.id
$mj2 = Find-ChatqJob $mine2.Job.id
$wl = [System.IO.File]::ReadAllText((Join-Path $script:ChatqLogDir 'watcher.log'), $utf8)
Check 'a chat gone since: its auto continue skipped with no alert - one you queued still fails and alerts' ($jw2.state -eq 'skipped' -and $jw2.result.reason -eq 'the chat is gone' -and
    $ga1 -eq $ga0 -and $mj2.state -eq 'failed' -and $ga2 -eq $ga0 + 1 -and $wl -like "*#$($jw2.seq) skipped: the chat is gone*") "$($jw2.state) $ga0 $ga1 $ga2"
# the streak: 2 auto-continues in a row that got no reply stop it, with the alert that says so
$cfgR = Get-ChatqConfig
Set-ChatqProp $cfgR 'maxRetries' 1
Save-ChatqJson $script:ChatqConfigPath $cfgR
$idW3 = 'ac0000b3-0000-4000-8000-0000000000b3'
$w3 = New-AcChat $idW3 'Auto streak chat' 2 -1
$null = Invoke-AcScan @(Get-AcCut $idW3)
$jw3 = @(Get-AcJobs $idW3)[0]
$env:FAKE_SCENARIO = Join-Path $here 'fixtures\stream\rejected.jsonl'
# what the run's own limit leaves in the chat: a new record
$x2 = Add-AcLimit $w3.Path $idW3 0.2 -1
$W = New-ChatqWatchState
Invoke-ChatqJob $W (Find-ChatqJob $jw3.id)
$jw3 = Find-ChatqJob $jw3.id
$sk1 = (Get-ChatqAutoConfig -Fresh).Streak[$idW3]
$c3b = Get-AcCut $idW3
$null = Invoke-AcScan @($c3b)
$jw3b = @(Get-AcJobs $idW3)[0]
$x3 = Add-AcLimit $w3.Path $idW3 0.1 -1
$sa0 = Get-AlertCount '*auto-continue stopped: 2 tries in a row got no reply - continue it yourself*'
$W = New-ChatqWatchState
Invoke-ChatqJob $W (Find-ChatqJob $jw3b.id)
$jw3b = Find-ChatqJob $jw3b.id
$sk2 = (Get-ChatqAutoConfig -Fresh).Streak[$idW3]
$sa1 = Get-AlertCount '*auto-continue stopped: 2 tries in a row got no reply - continue it yourself*'
$c3c = Get-AcCut $idW3
$st3c = Get-ChatqAutoState $c3c @(Get-ChatqJobs) @() (Get-ChatqAutoConfig) (Get-ChatqAutoMarkers) (Get-Date)
$r3c = Invoke-AcScan @($c3c)
$wl = [System.IO.File]::ReadAllText((Join-Path $script:ChatqLogDir 'watcher.log'), $utf8)
Check 'the first auto continue that gives up: failed, a streak of 1 on the cut-off it left - and the next cut-off is queued' ($jw3.state -eq 'failed' -and
    $sk1 -and [int]$sk1.n -eq 1 -and $sk1.uuid -eq $x2 -and $c3b.LimitUuid -eq $x2 -and $jw3b -and $jw3b.cutUuid -eq $x2) "$($jw3.state) $($sk1 | ConvertTo-Json -Compress) $($jw3b.cutUuid)"
Check 'the second in a row: its alert says it stopped, the chat is stopped, and nothing more is queued for it' ($jw3b.state -eq 'failed' -and [int]$sk2.n -eq 2 -and
    $sa1 -eq $sa0 + 1 -and $st3c.State -eq 'stopped' -and @($r3c.Queued).Count -eq 0 -and $wl -like "*auto-continue stopped for $($idW3.Substring(0, 8)): 2 in a row failed*") "$($sk2 | ConvertTo-Json -Compress) $sa0/$sa1 $($st3c.State)"
Remove-Item env:FAKE_SCENARIO
$cfgR.PSObject.Properties.Remove('maxRetries')
Save-ChatqJson $script:ChatqConfigPath $cfgR
# a turn ended without the limit - a new cut-off after it - or always again: the streak starts over
$x4 = Add-AcLimit $w3.Path $idW3 0.05 30
$st3d = Get-ChatqAutoState (Get-AcCut $idW3) @(Get-ChatqJobs) @() (Get-ChatqAutoConfig) (Get-ChatqAutoMarkers) (Get-Date)
$null = Set-ChatqAutoChat -Id $idW3 -Title 'Auto streak chat' -Value always
$sk3 = (Get-ChatqAutoConfig -Fresh).Streak[$idW3]
$null = Set-ChatqAutoChat -Id $idW3 -Title 'Auto streak chat' -Value default
# and one that finished clears it
$fin = [pscustomobject]@{ auto = $true; sessionId = $idW3; state = 'done'; path = $w3.Path; cutUuid = $x4 }
$null = Update-ChatqAutoState { param($v) $v.Streak[$idW3] = [pscustomobject]@{ n = 1; uuid = $x4 } }
$null = Step-ChatqAutoStreak $fin
$sk4 = (Get-ChatqAutoConfig -Fresh).Streak[$idW3]
Check 'a streak holds only for the cut-off it left: a later one is ready; always again, or an auto continue that finished, starts it over' ($st3d.State -eq 'ready' -and
    -not $sk3 -and -not $sk4) "$($st3d.State) $($sk3 | ConvertTo-Json -Compress) $($sk4 | ConvertTo-Json -Compress)"
# the started alert names it
$idW5 = 'ac0000b5-0000-4000-8000-0000000000b5'
$w5 = New-AcChat $idW5 'Auto started chat' 2 -1
$null = Invoke-AcScan @(Get-AcCut $idW5)
$jw5 = @(Get-AcJobs $idW5)[0]
$W = New-ChatqWatchState
Invoke-ChatqJob $W (Find-ChatqJob $jw5.id)
$jw5 = Find-ChatqJob $jw5.id
Check 'the run goes, and its started alert says auto-continue, not continue' ($jw5.state -eq 'done' -and (Get-AlertCount "*started*Auto started chat $d * $d auto-continue") -eq 1) "$($jw5.state)"
Remove-Item env:FAKE_RECORD
# the watcher's own scan, for when no overlay runs, and it is in the loop every 5 minutes
$idW6 = 'ac0000b6-0000-4000-8000-0000000000b6'
$w6 = New-AcChat $idW6 'Auto watcher scan chat' 1 30
$Ws = New-ChatqWatchState
$nW = Invoke-ChatqWatchAutoScan $Ws
$loopDef = (Get-Command Invoke-ChatqWatchLoop).Definition
Check 'the watcher''s scan queues what the limit cut off with no overlay running; the loop runs it every 5 minutes' ($nW -ge 1 -and @(Get-AcJobs $idW6).Count -eq 1 -and
    $Ws.CutCache.Count -gt 0 -and $loopDef -match 'TotalMinutes -ge 5\) \{ \$autoAt = Get-Date; \$null = Invoke-ChatqWatchAutoScan \$W') "$nW"
$null = Set-ChatqAutoContinue -Value ask
$idW7 = 'ac0000b7-0000-4000-8000-0000000000b7'
$w7 = New-AcChat $idW7 'Auto watcher ask chat' 1 30
$nW7 = Invoke-ChatqWatchAutoScan (New-ChatqWatchState)
$null = Set-ChatqAutoContinue -Value on
$null = Update-ChatqAutoState { param($v) $v.Since = (Get-Date).AddHours(-3) }
Check 'with the switch on ask - the default - the watcher''s scan queues nothing' ($nW7 -eq 0 -and -not @(Get-AcJobs $idW7).Count) "$nW7"
Remove-Item -LiteralPath $w7.Path -Force

# --- chatq -AutoContinue ---------------------------------------------------------------
$say = { param([scriptblock]$Do) (& $Do 6>&1 | Out-String) -replace '\r', '' }
$idC1 = 'ac0000c1-0000-4000-8000-0000000000c1'
$cc1 = New-AcChat $idC1 'Autocli target chat' 1 30
$null = Invoke-AcScan @(Get-AcCut $idC1)
$jc1 = @(Get-AcJobs $idC1)[0]
$null = Set-ChatqAutoChat -Id $idA5 -Title 'Auto switched chat' -Value always
$offSaid = & $say { chatq -AutoContinue off }
$offCfg = (Get-ChatqConfig).autoContinue
$onSaid = & $say { chatq -AutoContinue on }
$nAuto = @(Get-ChatqAutoJobs).Count
Check 'chatq -AutoContinue off: its line, the continues kept and how to drop one, the chats set to always' ($offCfg -eq 'off' -and
    $offSaid -like "*auto-continue: off - chats the limit cuts off are only marked; chatq '<title>' -Continue queues one*" -and
    $offSaid -like "*$nAuto already queued * kept: #* (chatqrm * drops it)*" -and $offSaid -like '*1 chat set to always is still continued: Auto switched chat*') $offSaid
Check 'chatq -AutoContinue on: its line and how to keep one chat out' ((Get-ChatqConfig).autoContinue -eq 'on' -and
    $onSaid -like '*auto-continue: on - a chat the limit cuts off gets "continue" a minute after the reset*' -and $onSaid -like "*chatq '<title>' -AutoContinue never keeps one out*") $onSaid
$null = Update-ChatqAutoState { param($v) $v.Since = (Get-Date).AddHours(-3) }
$null = Set-ChatqAutoChat -Id $idA5 -Title 'Auto switched chat' -Value default
$bad1 = & $say { chatq 'Autocli target' -AutoContinue on }
$bad2 = & $say { chatq -AutoContinue never }
$bad3 = & $say { chatq 'Autocli target' -AutoContinue never -Prompt 'x' }
Check 'refused: on|ask|off with a title, always|never with none, and with -Prompt' ($bad1 -like '*-AutoContinue on|ask|off is the switch for every chat - for this one, always|never|default*' -and
    $bad2 -like "*-AutoContinue never is for one chat*" -and $bad3 -like '*-AutoContinue sets a switch and queues nothing - run it on its own*' -and
    (Get-ChatqConfig).autoContinue -eq 'on') "$bad1 | $bad2 | $bad3"
$wi = & $say { chatq 'Autocli target' -AutoContinue never -WhatIf }
$wiSet = (Get-ChatqAutoConfig -Fresh).Chats[$idC1]
$mineC = New-ChatqJob -Row (Get-ChatqRowById $idC1 'claude' $cc1.Path) -Prompt 'my own prompt' -Kind prompt
$nv = & $say { chatq 'Autocli target' -AutoContinue never }
$nvSet = (Get-ChatqAutoConfig -Fresh).Chats[$idC1]
# the dropped job looked for by its whole id: yours, queued in the same
# second, is that id with -2 after it, which Find-ChatqJob's prefix takes
Check '-WhatIf shows the pick and saves nothing; never: the pick, its line, its auto continue dropped - your own job kept' ($wi -like "*'Autocli target chat'*-WhatIf: nothing changed*" -and
    -not $wiSet -and $nvSet.auto -eq 'never' -and $nv -like "*'Autocli target chat': never auto-continued*" -and $nv -like "*dropped #$($jc1.seq), its auto-continue*" -and
    -not @(Get-ChatqJobs | Where-Object { $_.id -eq $jc1.id }).Count -and (Find-ChatqJob $mineC.Job.id).state -eq 'queued') "$wi | $nv"
$al = & $say { chatq "$($mineC.Job.seq)" -AutoContinue always }
$df = & $say { chatq 'Autocli target' -AutoContinue default }
$cx = & $say { chatq 'Codex gitignore thread' -AutoContinue never }
Check 'a job number names its chat; always and default say so; a Codex chat is refused and nothing saved' ($al -like "*the chat of #$($mineC.Job.seq)*'Autocli target chat': always auto-continued, even with the switch on ask or off*" -and
    $df -like "*'Autocli target chat': follows the switch - auto-continue is on*" -and -not (Get-ChatqAutoConfig -Fresh).Chats[$idC1] -and
    $cx -like '*auto-continue is for Claude chats - a Codex job chatq runs is continued anyway*' -and -not (Get-ChatqAutoConfig).Chats[$cxId]) "$al | $df | $cx"
$null = Remove-ChatqJob (Find-ChatqJob $mineC.Job.id) 'test'
$sheet = & $say { Write-ChatqCheatSheet }
$help = (Get-Help chatq -Parameter AutoContinue | Out-String)
Check 'the cheat sheet has it, and so does chatq''s help' ($sheet -like '*chatq `[<title>`] -AutoContinue ask|on|off|never*' -and $help -like '*on*always*never*default*') $sheet

# --- chatqlist and the board -------------------------------------------------------------
$idL1 = 'ac0000d1-0000-4000-8000-0000000000d1'
$l1 = New-AcChat $idL1 'Autolist queued chat' 1 30
$null = Invoke-AcScan @(Get-AcCut $idL1)
$jl1 = @(Get-AcJobs $idL1)[0]
$idL2 = 'ac0000d2-0000-4000-8000-0000000000d2'
$l2 = New-AcChat $idL2 'Autolist never chat' 1 30
$null = Set-ChatqAutoChat -Id $idL2 -Title 'Autolist never chat' -Value never
$lsNobody = & $say { Write-ChatqList }
$lk = [System.IO.File]::Open($script:ChatqLockPath, 'OpenOrCreate', 'ReadWrite', 'None')
try { $lsOn = & $say { Write-ChatqList } } finally { $lk.Dispose() }
$null = Set-ChatqAutoContinue -Value off
$lsOff = & $say { Write-ChatqList }
$null = Set-ChatqAutoContinue -Value ask
$lsAsk = & $say { Write-ChatqList }
$null = Set-ChatqAutoContinue -Value on
$null = Update-ChatqAutoState { param($v) $v.Since = (Get-Date).AddHours(-3) }
# each Write-Host piece of a job's line comes back a line of its own
$lsLine = if ($lsOn -match 'Autolist queued chat[^\n]*\n\s*(continue \(auto\))') { $Matches[1] } else { '' }
Check 'chatqlist: nothing watching, said in yellow; with a watcher, the switch and its counts; off, how to turn it on; ask with no overlay, said' (
    $lsNobody -like '*auto-continue on - but nothing is watching for cut-off chats: chatoverlay starts the overlay*' -and
    $lsOn -match "auto-continue on $d \d+ queued $d 1 chat never" -and $lsOff -like "*auto-continue off $d chatq -AutoContinue ask|on turns it on*" -and
    $lsAsk -like '*auto-continue ask - but no overlay runs to ask about cut-off chats: chatoverlay starts it*') "$lsNobody"
Check 'chatqlist: an auto job reads continue (auto); a cut-off not continued is tagged' ($lsLine -like '*continue (auto)*' -and
    $lsOn -like '*Autolist never chat (limit *, never auto)*') "$lsLine | $lsOn"
Write-ChatqBoard
$board = [System.IO.File]::ReadAllText($script:ChatqBoardPath, $utf8)
Check 'the board: continue (auto) in the prompt column, picked by auto' ($board -like "*| $($jl1.seq) | Autolist queued chat | queued |*| continue (auto) (*" -and
    $board -like "*## #$($jl1.seq) $d Autolist queued chat*picked by auto*") ''

# --- chatrm ------------------------------------------------------------------------------
$hitL1 = [pscustomobject]@{ Record = [pscustomobject]@{ Id = $idL1; Title = 'Autolist queued chat' } }
$rmSaid = (Test-ChatJobsHold $hitL1 6>&1 | Out-String)
$held1 = Test-ChatJobsHold $hitL1 6> $null
$mineL = New-ChatqJob -Row (Get-ChatqRowById $idL1 'claude' $l1.Path) -Prompt 'mine' -Kind prompt
$held2 = Test-ChatJobsHold $hitL1 6> $null
Check 'chatrm drops a chat''s auto continue without -DropJobs, and says so; a job you queued still keeps the chat' ($rmSaid -like "*dropped #$($jl1.seq), its auto-continue*" -and
    -not (Find-ChatqJob $jl1.id) -and -not $held1 -and $held2) "$rmSaid $held1 $held2"
$null = Remove-ChatqJob (Find-ChatqJob $mineL.Job.id) 'test'

# --- the overlay's rows -------------------------------------------------------------------
$idO1 = 'ac0000e1-0000-4000-8000-0000000000e1'
$o1 = New-AcChat $idO1 'Autorow closed chat' 1 30
$idO2 = 'ac0000e2-0000-4000-8000-0000000000e2'
$o2 = New-AcChat $idO2 'Autorow open chat' 1 30
$ctxA = New-ChatOverlayContext
$ctxA.WantAuto = $true
$ctxA.WantAsk = $true
$sessDir = Join-Path $claudeHome 'sessions'
$null = New-Item -ItemType Directory -Path $sessDir -Force
$reg = Join-Path $sessDir '4747.json'
[System.IO.File]::WriteAllText($reg, ([ordered]@{ pid = 4747; sessionId = $idO2; cwd = $projAC; status = 'idle'; kind = 'interactive'; entrypoint = 'claude-vscode'; startedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() } | ConvertTo-Json -Compress), $utf8)
$aliveWas = $script:ChatqAliveSeam
$script:ChatqAliveSeam = { param($e) $e.Pid -eq 4747 }
try {
    $peekSnap = Invoke-ChatOverlayCycle $ctxA -Peek
    $peekJobs = @(Get-AcJobs $idO1).Count + @(Get-AcJobs $idO2).Count
    $printCtx = New-ChatOverlayContext
    $null = Invoke-ChatOverlayCycle $printCtx
    $printJobs = @(Get-AcJobs $idO1).Count + @(Get-AcJobs $idO2).Count
    # the cut-off list read afresh, as it is a minute on
    $ctxA.CutAt = [datetime]::MinValue
    $snapA = Invoke-ChatOverlayCycle $ctxA
}
finally { $script:ChatqAliveSeam = $aliveWas; Remove-Item -LiteralPath $reg -Force -EA SilentlyContinue }
$ro1 = @($snapA.rows | Where-Object { $_.sessionId -eq $idO1 })
$ro2 = @($snapA.rows | Where-Object { $_.sessionId -eq $idO2 })
$jo1 = @(Get-AcJobs $idO1)[0]
$jo2 = @(Get-AcJobs $idO2)[0]
Check 'a -Peek pass, and a context no host made (chatoverlay -Print), queue nothing' ($peekJobs -eq 0 -and $printJobs -eq 0) "$peekJobs $printJobs"
Check 'the host''s pass queues; a closed chat keeps one orange cut-off row carrying its job, and the job no row of its own' ($jo1 -and $ro1.Count -eq 1 -and
    $ro1[0].kind -eq 'cutoff' -and $ro1[0].status -eq 'cutoff' -and $ro1[0].rank -eq 0.5 -and $ro1[0].auto.state -eq 'armed' -and $ro1[0].job.seq -eq $jo1.seq -and
    $ro1[0].stateText -match "^#$($jo1.seq) auto ([A-Z][a-z]{2} )?\d\d:\d\d$") ($ro1 | ConvertTo-Json -Compress -Depth 4)
Check 'an open chat: its own row stays orange with the job on it, held for VS Code; the counts say cut off, and auto; the switch in the header, and no reset ask while it is on' ($jo2 -and $jo2.deferWhy -eq 'vscode' -and $ro2.Count -eq 1 -and
    $ro2[0].kind -eq 'session' -and $ro2[0].status -eq 'cutoff' -and $ro2[0].auto.state -eq 'armed' -and $ro2[0].job.seq -eq $jo2.seq -and
    [int]$snapA.counts.cutOff -ge 2 -and [int]$snapA.counts.auto -ge 2 -and $snapA.header.autoOn -eq $true -and $snapA.header.autoContinue -eq 'on' -and
    $null -eq $snapA.header.ask -and $null -eq $ctxA.Ask) "$($ro2 | ConvertTo-Json -Compress -Depth 4) $($snapA.counts | ConvertTo-Json -Compress)"
$qlog = [System.IO.File]::ReadAllText((Join-Path $script:ChatqLogDir 'overlay.log'), $utf8)
Check 'the overlay''s log says what it queued' ($qlog -like "*auto-continue: queued #$($jo1.seq) for $($idO1.Substring(0, 8)) (Autorow closed chat), resets *") ''
# a verb from the Mac menu (or a shell) sets the switch, and is not handed on
Send-ChatOverlayCommand 'auto-off'
$snapOff = Invoke-ChatOverlayCycle $ctxA
$offVerb = (Get-ChatqConfig).autoContinue -eq 'off' -and $snapOff.header.autoOn -eq $false -and $snapOff.header.autoContinue -eq 'off' -and $ctxA.Config.autoContinue -eq 'off' -and
    -not @($ctxA.Commands | Where-Object { $_.verb -like 'auto-*' }).Count -and ($ctxA.Verbs -contains 'reload')
Send-ChatOverlayCommand 'auto-ask'
$null = Invoke-ChatOverlayCycle $ctxA
$askVerb = (Get-ChatqConfig).autoContinue -eq 'ask'
Send-ChatOverlayCommand 'auto-on'
$null = Invoke-ChatOverlayCycle $ctxA
$null = Update-ChatqAutoState { param($v) $v.Since = (Get-Date).AddHours(-3) }
Check 'auto-on, auto-ask and auto-off from overlay-cmd set the switch, the config read again; the snapshot says it, for the Mac menu''s check' ($offVerb -and $askVerb -and (Get-ChatqConfig).autoContinue -eq 'on') "$offVerb $askVerb"
# the switch turned to ask with the auto job kept: its chat's cut-off row has
# no state to say it by, so the job - which still runs at the reset - keeps
# a row of its own
$null = Set-ChatqAutoContinue -Value ask
$ctxA.CutAt = [datetime]::MinValue
$snapKept = Invoke-ChatOverlayCycle $ctxA -Peek
$null = Set-ChatqAutoContinue -Value on
$null = Update-ChatqAutoState { param($v) $v.Since = (Get-Date).AddHours(-3) }
$ctxA.CutAt = [datetime]::MinValue
$keptRows = @($snapKept.rows | Where-Object { $_.sessionId -eq $idO1 })
Check 'switched to ask with an auto continue kept: the job has a row of its own, not a plain cut-off row that hides it' ((Find-ChatqJob $jo1.id -Exact) -and
    @($keptRows | Where-Object { $_.kind -eq 'job' -and $_.job.seq -eq $jo1.seq }).Count -eq 1 -and -not @($keptRows | Where-Object { $_.kind -eq 'cutoff' }).Count) ($keptRows | ConvertTo-Json -Compress -Depth 4)
# overlay.cutOff false: no rows, and the scan still runs while auto-continue is on
$idO3 = 'ac0000e3-0000-4000-8000-0000000000e3'
$o3 = New-AcChat $idO3 'Autorow hidden chat' 1 30
Set-ChatOverlayConfig @{ cutOff = $false }
$ctxB = New-ChatOverlayContext
$ctxB.WantAuto = $true
$snapB = Invoke-ChatOverlayCycle $ctxB
Set-ChatOverlayConfig @{ cutOff = $true }
Check 'overlay.cutOff false: no cut-off rows, and the scan runs all the same' (@(Get-AcJobs $idO3).Count -eq 1 -and -not @($snapB.rows | Where-Object { $_.status -eq 'cutoff' }).Count) ''
# rows built directly: the chips each state gets
$rowOf = { param($st, [string]$cwd = 'C:\p') [pscustomobject]@{ key = 'c:x'; kind = 'cutoff'; provider = 'claude'; sessionId = '11111111-1111-4111-8111-111111111111'; cwd = $cwd; title = 'T'
        auto = [pscustomobject]@{ state = $st; words = 'w'; long = 'L'; why = 'y'; seq = 3; jobId = 'j3' } } }
$acts = { param($r) (@(Get-ChatOverlayChipActions $r) | ForEach-Object Id) -join ',' }
Check 'the chips a row gets: don''t continue on armed and due, continue where nothing will, none on running, a terminal or a 529 - open beside where it opens' (
    (& $acts (& $rowOf 'armed')) -eq 'dont,open' -and (& $acts (& $rowOf 'due')) -eq 'dont,open' -and
    (@('off', 'never', 'declined', 'failed', 'stopped', 'far', 'late', 'ready') | ForEach-Object { & $acts (& $rowOf $_) }) -join '|' -eq ((1..8 | ForEach-Object { 'continue,open' }) -join '|') -and
    (& $acts (& $rowOf 'running')) -eq 'open' -and (& $acts (& $rowOf 'terminal')) -eq 'open' -and (& $acts (& $rowOf 'overloaded')) -eq 'open' -and
    (& $acts (& $rowOf 'armed' '')) -eq 'dont' -and (& $acts ([pscustomobject]@{ provider = 'claude'; sessionId = 'x' })) -eq '') ''
$dontTip = @(Get-ChatOverlayChipActions (& $rowOf 'armed'))[0].Tip
Check 'don''t continue''s tooltip carries what the row says in full, and the spec''s words' ($dontTip -like 'L. Don''t send "continue" to this chat after this reset. The next time the limit cuts it off, it is continued again - chatq ''T'' -AutoContinue never stops that.') $dontTip
$scrA = [pscustomobject]@{ X = 0; Y = 0; Width = 1920; Height = 1040 }
$cpA = Get-ChatOverlayChipPlacement @(1524, 200, 380, 20) @(170, 18) $scrA 90
$cpB = Get-ChatOverlayChipPlacement @(1524, 200, 380, 20) @(170, 18) $scrA 400
$cpC = Get-ChatOverlayChipPlacement @(1524, 200, 380, 20) @(40, 18) $scrA
Check 'the auto chips keep clear of the row''s state, and never leave the row; open alone stays flush right' ($cpA.X -eq (1524 + 380 - 90 - 170) -and $cpB.X -eq 1524 -and $cpC.X -eq (1524 + 380 - 40)) "$($cpA.X) $($cpB.X) $($cpC.X)"
# a press on one chip released on another does nothing; the auto chips never take the unread dot
$script:AcOpened = 0; $script:AcAuto = @(); $script:AcAsk = @()
$fnOpen = ${function:Invoke-ChatOverlayOpen}; $fnAuto = ${function:Invoke-ChatOverlayAutoChip}; $fnAsk = ${function:Invoke-ChatOverlayAskAnswer}
${function:Invoke-ChatOverlayOpen} = { param($H, $Row) $script:AcOpened++ }
${function:Invoke-ChatOverlayAutoChip} = { param($H, $Row, $Act) $script:AcAuto += $Act }
${function:Invoke-ChatOverlayAskAnswer} = { param($H, $Answer, $Keys) $script:AcAsk += "$Answer=$(@($Keys) -join ',')" }
try {
    $Hx = @{ ChipRow = (& $rowOf 'armed') }
    Invoke-ChatOverlayChipRelease $Hx 'dont' 'open'
    Invoke-ChatOverlayChipRelease $Hx 'open' 'dont'
    Invoke-ChatOverlayChipRelease $Hx '' 'open'
    $mis = $script:AcOpened -eq 0 -and -not $script:AcAuto.Count
    Invoke-ChatOverlayChipRelease $Hx 'dont' 'dont'
    Invoke-ChatOverlayChipRelease $Hx 'open' 'open'
    $Hx.ChipRow = [pscustomobject]@{ key = 'ask'; kind = 'ask'; keys = @('k_1', 'k_2') }
    Invoke-ChatOverlayChipRelease $Hx 'ask-go' 'ask-go'
    Invoke-ChatOverlayChipRelease $Hx 'ask-go' 'ask-leave'
}
finally { ${function:Invoke-ChatOverlayOpen} = $fnOpen; ${function:Invoke-ChatOverlayAutoChip} = $fnAuto; ${function:Invoke-ChatOverlayAskAnswer} = $fnAsk }
Check 'a chip acts only when pressed and released on it - a press dragged onto another does nothing; the banner''s answers go the same way' (
    $mis -and $script:AcOpened -eq 1 -and ($script:AcAuto -join ',') -eq 'dont' -and ($script:AcAsk -join '|') -eq 'continue=k_1,k_2') "$($script:AcOpened) $($script:AcAuto -join ',') $($script:AcAsk -join '|')"
$Hu = @{ Ctx = @{ Unread = @{ $idO1 = $true }; JobsSig = 'x' }; Tray = $null }
$rowO1 = @($snapA.rows | Where-Object { $_.sessionId -eq $idO1 })[0]
Invoke-ChatOverlayAutoChip $Hu $rowO1 'dont'
$goneO1 = -not (Find-ChatqJob $jo1.id)
Invoke-ChatOverlayAutoChip $Hu $rowO1 'continue'
$backO1 = @(Get-AcJobs $idO1 | Where-Object { -not $_.auto -and $_.kind -eq 'continue' }).Count -eq 1
$jl = [System.IO.File]::ReadAllText((Join-Path $script:ChatqLogDir 'jobs.log'), $utf8)
Check 'don''t continue from the chip removes the auto continue (by chip); continue queues one you asked for; the unread dot stays' ($goneO1 -and $backO1 -and
    $Hu.Ctx.Unread[$idO1] -and $jl -like "*#$($jo1.seq) removed by chip (was queued)*") "$goneO1 $backO1"
# the row stays drawn until the next pass and the chip comes back on it: a
# second continue finds the one just queued
Invoke-ChatOverlayAutoChip $Hu $rowO1 'continue'
$twiceO1 = @(Get-AcJobs $idO1 | Where-Object { -not $_.auto -and $_.kind -eq 'continue' }).Count
Check 'continue from the chip a second time, before the list is redrawn: no second continue queued' ($twiceO1 -eq 1) "$twiceO1"
Check 'chatoverlay -Print words a cut-off in full, from the row''s auto' ((Get-Command Write-ChatOverlayPrint).Definition.Contains('if ($au -and $au.long) { $right = [string]$au.long }')) ''

# --- the console ------------------------------------------------------------------------------
Check 'the console''s queue: an auto job auto-continues at its time' ((Get-ChatConsoleJobStatus ([pscustomobject]@{ state = 'queued'; auto = $true }) '13:01').Text -eq 'auto-continues 13:01' -and
    (Get-ChatConsoleJobStatus ([pscustomobject]@{ state = 'queued' }) '13:01').Text -eq 'sends 13:01') ''
$note = Get-ChatqAutoJobNote $jo2
Check 'its detail: queued by auto-continue, when the limit cut the chat off and when it resets' ($note -like 'queued by auto-continue: the limit cut this chat off at *, and it resets at *') $note

# --- the phone -----------------------------------------------------------------------------
$stA = [pscustomobject]@{ State = 'armed'; At = '13:01'; Tag = '' }
$stN = [pscustomobject]@{ State = 'never'; At = $null; Tag = 'never auto' }
$tA = Get-ChatqLiveAlertText 'limited' 'Autolive chat' $projAC $o1.Path @() -Auto $stA
$tN = Get-ChatqLiveAlertText 'done' 'Autolive chat' $projAC $o1.Path @() -Auto $stN
Check 'the live alert''s words: auto-continues at its time, or why not' ($tA -eq "Autolive chat $d stopped by the usage limit $d auto-continues 13:01" -and
    $tN -like "Autolive chat $d stopped by the usage limit until * $d never auto") "$tA | $tN"
# a live chat cut off with a continue queued: limited, about the job; none queued: done
$script:AcSent = [System.Collections.Generic.List[object]]::new()
$script:ChatqLiveSendSeam = { param($a) $script:AcSent.Add($a) }
$cfgP = Get-ChatqConfig
Set-ChatqProp $cfgP 'join' ([pscustomobject]@{ apiKey = (Protect-ChatqSecret 'k'); device = 'group.phone' })
Save-ChatqJson $script:ChatqConfigPath $cfgP
$lvE = { param($s) [pscustomobject]@{ SessionId = $idO2; Pid = 4747; Status = $s; Kind = 'interactive'; WaitingFor = $null; Cwd = $projAC; Name = 'n'; ProcStart = $null; StartedAt = $null; Entrypoint = 'claude-vscode' } }
$lvC = @{ ClaudeHome = $claudeHome; Text = @{}; Jobs = @(@{ Job = $jo2; First = 'continue' }); Chains = @{}; AutoStates = @{ $idO2 = [pscustomobject]@{ State = 'armed'; At = '13:01'; Tag = ''; Job = $jo2 } } }
$b0 = Get-Date
foreach ($s in @(@(0, 'idle'), @(2, 'busy'), @(4, 'idle'), @(12, 'idle'))) { Update-ChatqLiveAlerts $lvC @(& $lvE $s[1]) $b0.AddSeconds($s[0]) }
$sentA = @($script:AcSent)
$lvC2 = @{ ClaudeHome = $claudeHome; Text = @{}; Jobs = @(); Chains = @{}; AutoStates = @{ $idO2 = [pscustomobject]@{ State = 'never'; At = $null; Tag = 'never auto'; Job = $null } } }
foreach ($s in @(@(0, 'idle'), @(2, 'busy'), @(4, 'idle'), @(12, 'idle'))) { Update-ChatqLiveAlerts $lvC2 @(& $lvE $s[1]) $b0.AddSeconds($s[0]) }
$sentB = @($script:AcSent | Select-Object -Skip $sentA.Count)
Check 'a chat you run yourself, cut off with a continue queued: limited, priority 0, about that job; with none: done, and why not' ($sentA.Count -eq 1 -and
    $sentA[0].event -eq 'limited' -and $sentA[0].priority -eq 0 -and $sentA[0].jobId -eq $jo2.id -and $sentA[0].text -like "* $d stopped by the usage limit $d auto-continues 13:01" -and
    $sentB.Count -eq 1 -and $sentB[0].event -eq 'done' -and $sentB[0].text -like "* $d never auto" -and -not $sentB[0].jobId) "$($sentA | ConvertTo-Json -Compress) / $($sentB | ConvertTo-Json -Compress)"
# the outbox sends it about the job: the link's n and j=queued
Remove-Item -Path (Join-Path $script:ChatqOutboxDir '*') -Force -EA SilentlyContinue
$script:ChatqLiveSendSeam = $null
$script:AcJoins = [System.Collections.Generic.List[string]]::new()
$script:ChatqJoinSeam = { param($u) $script:AcJoins.Add($u); $null }
$fnStart = ${function:Start-ChatqOutboxSender}
${function:Start-ChatqOutboxSender} = { $true }
try {
    $of = Send-ChatqLiveAlert $sentA[0]
    $null = Send-ChatqOutboxFile $of
}
finally { ${function:Start-ChatqOutboxSender} = $fnStart }
$ju = if ($script:AcJoins.Count) { [uri]::UnescapeDataString($script:AcJoins[0]) } else { '' }
Check 'the outbox keeps the job and sends the alert about it: its number in the notification' ($ju -like "*title=chatq $d limited*" -and $ju -like "*auto-continues 13:01*") $ju
# skip on the phone: its own words, the marker kept
$payload = [pscustomobject]@{ act = 'skip'; text = '' }
$fbk = Invoke-ChatqReply $payload @{ jobId = $jo2.id; seq = $jo2.seq; sessionId = $idO2; event = 'limited' } 'aidac'
$mkKept = Test-Path -LiteralPath (Get-ChatqAutoMarkerPath $jo2)
$st2 = Get-ChatqAutoState (Get-AcCut $idO2) @(Get-ChatqJobs) @() (Get-ChatqAutoConfig) (Get-ChatqAutoMarkers) (Get-Date)
Check 'skip from the phone on an auto continue: its own answer, the marker kept - declined, not queued again' ($fbk.Feedback -eq "#$($jo2.seq) skipped - Autorow open chat will not be continued after this reset" -and
    $mkKept -and $st2.State -eq 'declined') "$($fbk.Feedback) $mkKept $($st2.State)"
$nobody = Invoke-ChatqReply ([pscustomobject]@{ act = 'auto'; text = 'on' }) @{ sessionId = $idO2; event = 'limited' } 'aidac2'
Check 'no act turns auto-continue on or off from the phone' ($null -eq $nobody -and (Get-ChatqConfig).autoContinue -eq 'on') ''

# --- the overlay's window, in the STA process WPF needs (Windows) ---------------------------------
if ($script:ChatqIsWindows) {
    $acWpf = @"
`$env:CHATQ_OVERLAY = '1'
. '$(Join-Path $sb 'tool\VS-code-chat-manager.ps1')'
Set-StrictMode -Off
`$script:ChatqSpawn = { `$true }
`$cfgWas = [IO.File]::ReadAllText(`$script:ChatqConfigPath)
`$stateWas = if (Test-Path -LiteralPath `$script:ChatqAutoPath) { [IO.File]::ReadAllText(`$script:ChatqAutoPath) } else { `$null }
Set-ChatOverlayConfig @{ width = 380; maxRows = 8; hotkey = 'none'; consoleHotkey = 'none' }
`$null = Set-ChatqAutoContinue -Value on
`$script:AcBalloons = [System.Collections.Generic.List[object]]::new()
`$script:ChatOverlayBalloonSeam = { param(`$b) `$script:AcBalloons.Add([pscustomobject]`$b) }
Initialize-ChatOverlayNative
`$H = New-ChatOverlayHostState
`$script:ChatOverlayHost = `$H
`$H.Ctx = New-ChatOverlayContext
`$H.State = [pscustomobject]@{ x = `$null; y = `$null; locked = `$true; hidden = `$false }
New-ChatOverlayWindow `$H
# the settings box's seventh row: Cut off, Continue, Ask and Leave, tooltips on all
Set-ChatOverlaySettingsOpen `$H `$true
`$g = `$H.Settings.Child
`$lab = @(`$g.Children | Where-Object { `$_ -is [System.Windows.Controls.TextBlock] -and `$_.Text -eq 'Cut off' })[0]
`$chipsOf = { @(`$H.Settings.Child.Children | Where-Object { `$_ -is [System.Windows.Controls.StackPanel] -and @(`$_.Children | ForEach-Object { `$_.Tag }) -contains 'leave' })[0] }
`$ch = & `$chipsOf
`$on = { param(`$p) @(`$p.Children | Where-Object { `$_.Background -eq (Get-ChatOverlayBrush 'accent') } | ForEach-Object { `$_.Tag }) -join ',' }
`$row7 = `$lab -and [System.Windows.Controls.Grid]::GetRow(`$lab) -eq 6 -and `$g.RowDefinitions.Count -eq 7 -and
    `$lab.ToolTip -like 'A chat the usage limit cuts off: Continue sends it "Continue from where you left off." a minute after the reset. Ask says so once the limit is over, and continues it if you say so. Leave only marks it orange.' -and
    (@(`$ch.Children | ForEach-Object { `$_.Tag }) -join ',') -eq 'continue,ask,leave' -and (@(`$ch.Children | ForEach-Object { `$_.Child.Text }) -join ',') -eq 'Continue,Ask,Leave' -and
    `$ch.Children[0].ToolTip -eq 'Continue each chat the limit cuts off, by itself.' -and `$ch.Children[1].ToolTip -like 'Once the limit is over*' -and
    `$ch.Children[2].ToolTip -like 'Only mark them - Continue in the console*' -and (& `$on `$ch) -eq 'continue'
# a click on Leave: config.json, and the box made anew with Leave filled
`$up = [System.Windows.Input.MouseButtonEventArgs]::new([System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]::Left)
`$up.RoutedEvent = [System.Windows.UIElement]::MouseLeftButtonUpEvent
`$ch.Children[2].RaiseEvent(`$up)
`$left = (Get-ChatqConfig).autoContinue -eq 'off' -and (& `$on (& `$chipsOf)) -eq 'leave'
# Continue again: on, since anew, and the notice once
`$null = Update-ChatqAutoState { param(`$v) `$v.Noticed = `$false }
`$script:AcBalloons.Clear()
Set-ChatOverlayAutoChoice `$H 'continue'
Set-ChatOverlayAutoChoice `$H 'leave'
Set-ChatOverlayAutoChoice `$H 'continue'
`$noticed = (Get-ChatqConfig).autoContinue -eq 'on' -and `$H.Ctx.Config.autoContinue -eq 'on' -and `$script:AcBalloons.Count -eq 1 -and
    `$script:AcBalloons[0].Text -like 'chatq now continues chats the usage limit cuts off from here on*' -and (Get-ChatqAutoConfig -Fresh).Noticed
# the tray's item follows config.json, and its verb goes through Invoke-ChatOverlayVerb
`$H.Menu = @{ Lock = [System.Windows.Forms.ToolStripMenuItem]::new('l'); Hide = [System.Windows.Forms.ToolStripMenuItem]::new('h'); Fold = [System.Windows.Forms.ToolStripMenuItem]::new('f')
    Hotkey = [System.Windows.Forms.ToolStripMenuItem]::new('k'); Auto = [System.Windows.Forms.ToolStripMenuItem]::new('Auto-continue cut-off chats') }
Invoke-ChatOverlayVerb 'auto-ask'
Update-ChatOverlayMenu `$H
`$trayOff = -not `$H.Menu.Auto.Checked -and (Get-ChatqConfig).autoContinue -eq 'ask'
Invoke-ChatOverlayVerb 'auto-on'
Update-ChatOverlayMenu `$H
`$trayOn = `$H.Menu.Auto.Checked -and (Get-ChatqConfig).autoContinue -eq 'on' -and (& `$on (& `$chipsOf)) -eq 'continue'
`$trayDef = (Get-Command New-ChatOverlayTrayIcon).Definition
`$trayItem = `$trayDef.Contains('Auto-continue cut-off chats') -and `$trayDef.Contains('Invoke-ChatOverlayVerb') -and `$trayDef.Contains("'auto-ask'") -and `$trayDef.Contains("'auto-on'")
# held while the console runs a loop of its own
`$H.Mode = 'console'; `$H.Con = @{ Modal = `$true }; `$H.Held = @()
Invoke-ChatOverlayVerb 'auto-off'
`$heldOk = (@(`$H.Held) -join ',') -eq 'auto-off' -and (Get-ChatqConfig).autoContinue -eq 'on'
`$H.Mode = 'panel'; `$H.Con = `$null; `$H.Held = @()
# the box with the panel at the screen's top: the buttons and box go below it, all on the screen
`$script:ChatOverlayWorkAreaSeam = { param(`$r) [pscustomobject]@{ X = -4000; Y = 0; Width = 1920; Height = 1020 } }
`$H.Placed = `$true
`$rows = @(1..8 | ForEach-Object { [pscustomobject]@{ key = "s:`$_"; kind = 'session'; status = 'idle'; rank = 3; project = 'p'; title = "chat `$_"; prompt = 'x'; stateText = 'idle 1m'; job = `$null } })
`$H.Ctx.ViewSig = 'top'
Set-ChatOverlayHidden `$H `$false
[ChatOverlayNative]::MoveTo(`$H.Hwnd, -2594, 0)
Update-ChatOverlayView `$H ([pscustomobject]@{ header = [pscustomobject]@{ usage = @(); notes = @() }; rows = `$rows })
`$H.Win.UpdateLayout()
Show-ChatOverlayControls `$H `$true
Set-ChatOverlaySettingsOpen `$H `$true
`$H.CtlWin.UpdateLayout()
Set-ChatOverlayControlsPlacement `$H
`$t = Get-ChatOverlayControlsTarget `$H
`$p = [ChatOverlayNative]::GetRect(`$H.Hwnd)
`$H.Settings.Measure([System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
`$boxH = `$H.Settings.DesiredSize.Height
`$top = `$t.Side -eq 'below' -and `$t.Y -ge (`$p[1] + `$p[3]) -and (`$t.Y + `$t.Height) -le 1020 -and `$boxH -gt 0 -and `$boxH -le 28 * 7
Show-ChatOverlayControls `$H `$false
# the chip window over an auto row: don't continue and open, left of the state
`$sid = '11111111-1111-4111-8111-111111111111'
`$ar = [pscustomobject]@{ key = "c:`$sid"; kind = 'cutoff'; provider = 'claude'; status = 'cutoff'; chat = 'cutoff'; rank = 0.5; project = 'p'; title = 'an auto chat'; prompt = `$null
    stateText = '#12 auto 13:01'; job = `$null; sessionId = `$sid; cwd = 'C:\p'; where = ''; unread = `$false
    auto = [pscustomobject]@{ state = 'armed'; words = '#12 auto 13:01'; long = '#12 auto-continues 13:01'; why = 'w'; seq = 12; jobId = 'j12' } }
`$H.Ctx.ViewSig = 'chip'
Update-ChatOverlayView `$H ([pscustomobject]@{ header = [pscustomobject]@{ usage = @(); notes = @() }; rows = @(`$ar) })
`$H.Win.UpdateLayout()
`$rects = @(Get-ChatOverlayRowRects `$H)
Show-ChatOverlayChip `$H `$rects[0] ([System.Drawing.Point]::new(-9000, -9000))
`$kids = @(`$H.ChipWin.Content.Children)
`$cr = [ChatOverlayNative]::GetRect(`$H.ChipHwnd)
`$sr = `$rects[0].State
`$two = `$kids.Count -eq 2 -and (@(`$kids | ForEach-Object { `$_.Tag }) -join ',') -eq 'dont,open' -and `$kids[0].Child.Text -eq "don't continue" -and
    `$kids[0].ToolTip -like '#12 auto-continues 13:01. Don''t send*' -and `$H.ChipText -eq `$kids[1].Child -and `$sr -and (`$cr[0] + `$cr[2]) -le `$sr[0]
# a row with no mark keeps its title in the column: an empty slot where the mark goes
`$slot = @(@(`$H.Stack.Children | Where-Object { `$_.Tag -and `$_.Tag -isnot [string] })[0].Children[0].Children | Where-Object { `$_.Tag -eq 'slot' }).Count -eq 1
# a press on don't continue released on open does nothing; the same chip acts
`$script:Opened = 0; `$script:AutoActs = @()
`${function:Invoke-ChatOverlayOpen} = { param(`$H, `$Row) `$script:Opened++ }
`${function:Invoke-ChatOverlayAutoChip} = { param(`$H, `$Row, `$Act) `$script:AutoActs += `$Act }
# a fresh event each time: one raised already is handled, and reaches no handler again
`$ev = { param([bool]`$Down) `$a = [System.Windows.Input.MouseButtonEventArgs]::new([System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]::Left)
    `$a.RoutedEvent = if (`$Down) { [System.Windows.UIElement]::MouseLeftButtonDownEvent } else { [System.Windows.UIElement]::MouseLeftButtonUpEvent }; `$a }
`$H.ChipArmed = `$true
`$kids[0].RaiseEvent((& `$ev `$true)); `$kids[1].RaiseEvent((& `$ev `$false))
`$dragged = `$script:Opened -eq 0 -and -not `$script:AutoActs.Count
`$kids[0].RaiseEvent((& `$ev `$true)); `$kids[0].RaiseEvent((& `$ev `$false))
`$same = (`$script:AutoActs -join ',') -eq 'dont' -and `$script:Opened -eq 0
# an unarmed chip takes no click
`$H.ChipArmed = `$false
`$kids[1].RaiseEvent((& `$ev `$true)); `$kids[1].RaiseEvent((& `$ev `$false))
`$unarmed = `$script:Opened -eq 0
# a plain row: open alone, flush right
`$pr = [pscustomobject]@{ key = "s:`$sid"; kind = 'session'; provider = 'claude'; status = 'idle'; rank = 3; project = 'p'; title = 'plain'; prompt = `$null; stateText = 'idle 1m'; job = `$null; sessionId = `$sid; cwd = 'C:\p'; where = 'vscode' }
`$H.Ctx.ViewSig = 'plain'
Update-ChatOverlayView `$H ([pscustomobject]@{ header = [pscustomobject]@{ usage = @(); notes = @() }; rows = @(`$pr) })
`$H.Win.UpdateLayout()
`$rects = @(Get-ChatOverlayRowRects `$H)
Show-ChatOverlayChip `$H `$rects[0] ([System.Drawing.Point]::new(-9000, -9000))
`$cr2 = [ChatOverlayNative]::GetRect(`$H.ChipHwnd)
`$ln = `$rects[0].Line
`$plain = @(`$H.ChipWin.Content.Children).Count -eq 1 -and [Math]::Abs((`$cr2[0] + `$cr2[2]) - (`$ln[0] + `$ln[2])) -le 1
# the collapsed line counts the auto ones
`$H.Ctx.ViewSig = 'fold'
`$H.Collapsed = `$true
Update-ChatOverlayView `$H ([pscustomobject]@{ header = [pscustomobject]@{ usage = @(); notes = @() }; counts = [pscustomobject]@{ cutOff = 3; auto = 1 }; rows = @() })
`$fold = @(`$H.Stack.Children[0].Children | Where-Object { `$_ -is [System.Windows.Controls.TextBlock] -and `$_.Text -like '*cut off*' })[0].Text
`$folded = `$fold -eq '3 cut off (1 auto)'
Set-ChatOverlayHidden `$H `$true
[IO.File]::WriteAllText(`$script:ChatqConfigPath, `$cfgWas)
if (`$null -ne `$stateWas) { [IO.File]::WriteAllText(`$script:ChatqAutoPath, `$stateWas) }
'{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}|{10}|{11}|{12}|{13}' -f `$row7, `$left, (`$trayOff -and `$trayOn -and `$trayItem), `$heldOk, `$top, `$two, `$dragged, `$same, `$unarmed, `$plain, `$folded, `$noticed, `$slot, "side `$(`$t.Side) y `$(`$t.Y) h `$(`$t.Height) p `$(`$p -join ',') box `$boxH chip `$(`$cr -join ',') state `$(`$sr -join ',') fold '`$fold' kids `$(@(`$kids | ForEach-Object { `$_.Tag }) -join ',') opened `$(`$script:Opened) acts `$(`$script:AutoActs -join ',') balloons `$(@(`$script:AcBalloons | ForEach-Object { `$_.Text }) -join ' // ')"
"@
    $acOut = Invoke-Sta 'auto-continue-test' $acWpf
    $aw = "$acOut" -split '\|'
    Check 'the settings box''s seventh row: Cut off, Continue, Ask and Leave, each with its tooltip' ($aw[0] -eq 'True') "$acOut"
    Check 'a click on Leave keeps auto-continue off in config.json, and the box shows it' ($aw[1] -eq 'True') "$acOut"
    Check 'the tray''s item is checked as config.json has it, and toggles on and ask through Invoke-ChatOverlayVerb' ($aw[2] -eq 'True') "$acOut"
    Check 'the tray''s toggle is held while the console runs a loop of its own' ($aw[3] -eq 'True') "$acOut"
    Check 'seven rows fit: with the panel at the screen''s top, the buttons and box go below it, on the screen' ($aw[4] -eq 'True') "$acOut"
    Check 'the chip window over an auto row: don''t continue and open, left of the row''s state, the state in the tooltip' ($aw[5] -eq 'True') "$acOut"
    Check 'a press on one chip released on the other does nothing; on the same chip it acts; an unarmed chip takes no click' ($aw[6] -eq 'True' -and $aw[7] -eq 'True' -and $aw[8] -eq 'True') "$acOut"
    Check 'a plain row still gets open alone, flush with its right end' ($aw[9] -eq 'True') "$acOut"
    Check 'collapsed, the one line counts the cut-off chats auto-continue will continue' ($aw[10] -eq 'True') "$acOut"
    Check 'Continue chosen in the settings box: on, and the notice said once' ($aw[11] -eq 'True') "$acOut"
    Check 'a row with no mark gets an empty slot, so every title starts in one column' ($aw[12] -eq 'True') "$acOut"
}

# --- put it all back ------------------------------------------------------------------------
foreach ($j in @(Get-ChatqJobs | Where-Object { [string]$_.id -notin $acJobsBefore })) { $null = Remove-ChatqJob $j 'test' }
Remove-Item -LiteralPath $projAC -Recurse -Force -EA SilentlyContinue
Remove-Item -LiteralPath (Join-Path (Join-Path $claudeHome 'projects') (Get-Slug $projAC)) -Recurse -Force -EA SilentlyContinue
Remove-Item -LiteralPath $script:ChatqAutoDir -Recurse -Force -EA SilentlyContinue
if ($null -ne $acStateWas) { [System.IO.File]::WriteAllText($script:ChatqAutoPath, $acStateWas, $utf8) } else { Remove-Item -LiteralPath $script:ChatqAutoPath -Force -EA SilentlyContinue }
if ($null -ne $acCfgWas) { [System.IO.File]::WriteAllText($script:ChatqConfigPath, $acCfgWas, $utf8) } else { Remove-Item -LiteralPath $script:ChatqConfigPath -Force -EA SilentlyContinue }
Remove-Item -Path (Join-Path $script:ChatqOutboxDir '*') -Force -EA SilentlyContinue
foreach ($p in $script:ChatOverlayCmdPath, $script:ChatOverlayPath) { Remove-Item -LiteralPath $p -Force -EA SilentlyContinue }
$script:ChatqAutoCache = $null
$script:ChatqAutoSaid = @{}
$script:ChatqSpawn = $acWas.Spawn
$script:ChatqJoinSeam = $acWas.Join
$script:ChatqIdleSeam = $acWas.Idle
$script:ChatqLiveSendSeam = $acWas.Send
$script:ChatShowHoldSeconds = $acWas.Hold
