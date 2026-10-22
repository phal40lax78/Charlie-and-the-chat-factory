# tests/sections/native-step.ps1: dot-sourced by tests/run-tests.ps1 in its turn,
# never on its own - it uses what the runner and the sections before it set.

# --- a pick's own failure (Invoke-ChatqPick, native/SPEC.md 3.6) -------------
Section 'native helper steps'

# A run that throws, through the loop and through Invoke-ChatqPick alone:
# the same error line, the job failed, and its failed alert sent while
# ChatqAlertJob still names it. Only the jobs made here are seen, and every
# other call the loop makes is stubbed.
$nsFnWas = @{}
foreach ($k in 'Get-ChatqJobs', 'Restore-ChatqWatchState', 'Repair-ChatqInterrupted', 'Test-ChatqHeldWaiting', 'Test-ChatqReplyOpen', 'Invoke-ChatqWatchAutoScan',
    'Clear-ChatqStrayFiles', 'Update-ChatqBlock', 'Set-ChatqKeepAwake', 'Save-ChatqWatchState', 'Write-ChatqBoard', 'Confirm-ChatqAllowed', 'Invoke-ChatqJob',
    'Send-ChatqAlert', 'Write-ChatqWatchLog') { $nsFnWas[$k] = (Get-Item "function:$k").ScriptBlock }
$nsSentWas = $script:ChatqAskSent
$nsAlertWas = $script:ChatqAlertJob
$nsLoopJob = New-TestJob 'plugin' 'a pick that throws, in the loop'
$nsPickJob = New-TestJob 'plugin' 'a pick that throws, on its own'
$script:nsIds = @($nsLoopJob.id)
$script:nsLog = New-Object System.Collections.Generic.List[string]
$script:nsAlerts = New-Object System.Collections.Generic.List[object]
try {
    $script:ChatqAskSent = @{}
    Set-Item function:Get-ChatqJobs { @(& $nsFnWas['Get-ChatqJobs'] | Where-Object { $script:nsIds -contains $_.id }) }
    Set-Item function:Restore-ChatqWatchState { param($W) $false }
    Set-Item function:Repair-ChatqInterrupted { }
    Set-Item function:Test-ChatqHeldWaiting { $false }
    Set-Item function:Test-ChatqReplyOpen { param($Cfg) $false }
    Set-Item function:Invoke-ChatqWatchAutoScan { param($W) 0 }
    Set-Item function:Clear-ChatqStrayFiles { @() }
    Set-Item function:Update-ChatqBlock { param($W, $Job, [switch]$Force) }
    Set-Item function:Set-ChatqKeepAwake { param([bool]$On) }
    Set-Item function:Save-ChatqWatchState { param($W) }
    Set-Item function:Write-ChatqBoard { }
    Set-Item function:Confirm-ChatqAllowed { param($W, $Job) $true }
    # the loop leaves through its stop path on the next pass
    Set-Item function:Invoke-ChatqJob { param($W, $Job) Set-Content -LiteralPath $script:ChatqStopPath -Value 'stop' -Encoding ASCII; throw 'the run broke' }
    Set-Item function:Send-ChatqAlert { param([string]$Kind, [string]$Text, [int]$Priority, $Job) $script:nsAlerts.Add([pscustomobject]@{ Kind = $Kind; Text = $Text; Priority = $Priority; Job = $Job.id; AlertJob = $script:ChatqAlertJob }); $true }
    Set-Item function:Write-ChatqWatchLog { param([string]$Text) $script:nsLog.Add($Text) }

    Invoke-ChatqWatchLoop -Foreground *> $null
    $nsLoopAfter = $script:ChatqAlertJob
    $nsLoopLog = @($script:nsLog | Where-Object { $_ -like '#* error: *' })

    $script:nsIds = @($nsPickJob.id)
    $script:nsLog.Clear()
    $nsW = New-ChatqWatchState
    $nsW.current = 'something'
    $script:ChatqAlertJob = "#$($nsPickJob.seq)"
    Invoke-ChatqPick $nsW (Find-ChatqJob $nsPickJob.id -Exact)
    $nsPickLog = @($script:nsLog | Where-Object { $_ -like '#* error: *' })
    Remove-Item -LiteralPath $script:ChatqStopPath -Force -EA SilentlyContinue
}
finally {
    foreach ($k in $nsFnWas.Keys) { Set-Item "function:$k" $nsFnWas[$k] }
    $script:ChatqAskSent = $nsSentWas
    $script:ChatqAlertJob = $nsAlertWas
}
$nsBad = @()
$nsLines = @()
foreach ($c in @(@{ Name = 'loop'; Job = $nsLoopJob; Log = $nsLoopLog; Alert = $script:nsAlerts[0] }, @{ Name = 'pick'; Job = $nsPickJob; Log = $nsPickLog; Alert = $script:nsAlerts[1] })) {
    $s = $c.Job.seq
    $f = Find-ChatqJob $c.Job.id -Exact
    if ($c.Log.Count -ne 1 -or $c.Log[0] -notmatch "^#$s error: the run broke @ at .+native-step\.ps1: line \d+\r?$") { $nsBad += "$($c.Name): log '$($c.Log -join ' | ')'" }
    else { $nsLines += $c.Log[0].Substring("#$s".Length) }
    if ($f.state -ne 'failed' -or $f.result.kind -ne 'failed' -or $f.result.reason -ne 'chatq error: the run broke' -or @($f.history)[-1].why -ne 'chatq error') { $nsBad += "$($c.Name): job $($f.state) $($f.result | ConvertTo-Json -Compress)" }
    $a = $c.Alert
    if (-not $a -or $a.Kind -ne 'failed' -or $a.Text -ne "$($c.Job.title) $($script:ChatqDot) chatq error: the run broke" -or $a.Priority -ne 2 -or $a.Job -ne $c.Job.id -or $a.AlertJob -ne "#$s") { $nsBad += "$($c.Name): alert $($a | ConvertTo-Json -Compress)" }
}
if ($script:nsAlerts.Count -ne 2) { $nsBad += "$($script:nsAlerts.Count) alerts" }
if ($nsLines.Count -eq 2 -and $nsLines[0] -cne $nsLines[1]) { $nsBad += "lines differ: '$($nsLines[0])' / '$($nsLines[1])'" }
if ($null -ne $nsLoopAfter) { $nsBad += "the loop left ChatqAlertJob '$nsLoopAfter'" }
if ($null -ne $nsW.current) { $nsBad += "Invoke-ChatqPick left current '$($nsW.current)'" }
Check 'a pick that throws: the same error line, the job failed and its failed alert while ChatqAlertJob names it, through the loop or Invoke-ChatqPick' (-not $nsBad) ($nsBad -join '; ')
# gone again, their numbers free: the sections after count the queue as it was
foreach ($c in $nsLoopJob, $nsPickJob) { $null = Remove-ChatqJob (Find-ChatqJob $c.id -Exact) 'test' }

# --- the pid seams (Get-ChatqRunnerPid, native/SPEC.md 3.6) -----------------
# A step names chatqd wherever the watcher's identity is written: a run's
# job and run-state, state.json and the permit.log/ask.log tags. The seam
# values here are no live process; with them gone, every site says $PID.
$nsSeamPid = 987654
if ($nsSeamPid -eq $PID) { $nsSeamPid++ }
$nsSeamAt = (Get-Date).AddHours(-1).ToString('o')
$nsStateWas = Read-TestFile $script:ChatqStatePath
$nsRsSeamWas = $script:ChatRunStateSeam
$script:nsSeen = $null
$nsRunJob = New-TestJob 'plugin' 'a run under the pid seams'
try {
    $script:ChatqWatcherPid = $nsSeamPid
    $script:ChatqWatcherStartedAt = $nsSeamAt
    $script:ChatqRunnerPid = $nsSeamPid
    # what is on disk as the run goes in: the job, the run-state, state.json
    $script:ChatRunStateSeam = {
        param($s)
        if ($s.phase -eq 'running') {
            $script:nsSeen = @{ Job = (Find-ChatqJob ([string]$s.jobId) -Exact).runnerPid; RunState = $s.runnerPid; State = (Read-TestFile $script:ChatqStatePath) }
        }
    }
    Invoke-ChatqJob (New-ChatqWatchState) (Find-ChatqJob $nsRunJob.id -Exact) *> $null
    Write-ChatqPermitLog 'native-step: the seam tag'
    Write-ChatqAskLog 'native-step: the seam tag'
    $nsTagged = @(foreach ($n in 'permit.log', 'ask.log') { @([System.IO.File]::ReadAllLines((Join-Path $script:ChatqLogDir $n), $utf8))[-1] })
}
finally {
    $script:ChatqWatcherPid = $null
    $script:ChatqWatcherStartedAt = $null
    $script:ChatqRunnerPid = $null
    $script:ChatRunStateSeam = $nsRsSeamWas
}
Write-ChatqPermitLog 'native-step: no seam'
$nsUntagged = @([System.IO.File]::ReadAllLines((Join-Path $script:ChatqLogDir 'permit.log'), $utf8))[-1]
$nsBad = @()
$nsDone = Find-ChatqJob $nsRunJob.id -Exact
if (-not $script:nsSeen) { $nsBad += "no running run-state ($($nsDone.state))" }
else {
    if ([int]$script:nsSeen.Job -ne $nsSeamPid) { $nsBad += "job runnerPid $($script:nsSeen.Job)" }
    if ([int]$script:nsSeen.RunState -ne $nsSeamPid) { $nsBad += "run-state runnerPid $($script:nsSeen.RunState)" }
    if ($script:nsSeen.State -notmatch "`"pid`":\s*$nsSeamPid\b" -or $script:nsSeen.State -notmatch "`"startedAt`":\s*`"$([regex]::Escape($nsSeamAt))`"") { $nsBad += "state.json $($script:nsSeen.State)" }
}
foreach ($l in $nsTagged) { if ($l -notmatch "  \[$nsSeamPid\] native-step: the seam tag$") { $nsBad += "log line '$l'" } }
if ($nsUntagged -notmatch "  \[$PID\] native-step: no seam$") { $nsBad += "no seam: '$nsUntagged'" }
if ((Get-ChatqRunnerPid) -ne $PID) { $nsBad += "no seam: Get-ChatqRunnerPid $(Get-ChatqRunnerPid)" }
Check 'the pid seams set: the job''s and the run-state''s runnerPid, state.json''s pid and startedAt and the permit.log/ask.log tags name them; unset, $PID again' (
    -not $nsBad -and $nsDone.state -eq 'done') "$($nsDone.state) $($nsBad -join '; ')"
Restore-TestFile $script:ChatqStatePath $nsStateWas
$null = Remove-ChatqJob $nsDone 'test'

# Repair-ChatqInterrupted leaves alone a job whose runnerPid is the seam's:
# chatqd holds the lock and runs it. The same job, with the seam gone, is
# one a dead watcher left.
$nsFnWas = @{}
foreach ($k in 'Get-ChatqJobs', 'Send-ChatqAlert') { $nsFnWas[$k] = (Get-Item "function:$k").ScriptBlock }
$nsRep = New-TestJob 'plugin' 'running under chatqd'
Set-ChatqProp $nsRep 'runnerPid' $nsSeamPid; Set-ChatqProp $nsRep 'startedAt' (Get-ChatqStamp); Set-ChatqJobState $nsRep 'running' 'test'
$script:nsIds = @($nsRep.id)
try {
    Set-Item function:Get-ChatqJobs { @(& $nsFnWas['Get-ChatqJobs'] | Where-Object { $script:nsIds -contains $_.id }) }
    Set-Item function:Send-ChatqAlert { $true }
    $script:ChatqRunnerPid = $nsSeamPid
    try { Repair-ChatqInterrupted } finally { $script:ChatqRunnerPid = $null }
    $nsRepSet = Find-ChatqJob $nsRep.id -Exact
    Repair-ChatqInterrupted
    $nsRepUnset = Find-ChatqJob $nsRep.id -Exact
}
finally { foreach ($k in $nsFnWas.Keys) { Set-Item "function:$k" $nsFnWas[$k] } }
Check 'Repair-ChatqInterrupted skips a job whose runnerPid is the seam''s, and repairs it once the seam is gone' (
    $nsRepSet.state -eq 'running' -and [int]$nsRepSet.runnerPid -eq $nsSeamPid -and $nsRepUnset.state -eq 'failed' -and $nsRepUnset.result.reason -like 'interrupted*') "$($nsRepSet.state) / $($nsRepUnset.state)"
$null = Remove-ChatqJob $nsRepUnset 'test'

# The parent check in Invoke-ChatqProcess's $check, only ever in a child:
# its Stop-Process takes whichever process has the seam set. Each child
# runs a 7 s command; one whose parent test says alive sees it to the end,
# one whose test says dead ends itself at the first 5 s check, leaving
# the command to finish on its own. Killed, not failed: Stop-Process's exit
# code is -1 on Windows and 137 (SIGKILL) elsewhere.
$nsKid = Join-Path $sb 'native-step-parent.ps1'
$nsKidOut = Join-Path $sb 'native-step-parent'
$nsPs = (Get-Process -Id $PID).Path
[System.IO.File]::WriteAllText($nsKid, @"
param([string]`$Say)
`$ErrorActionPreference = 'Stop'
. '$(Join-Path $sb 'tool\Charlie-and-the-chat-factory.ps1')'
`$script:ChatqStepParent = if (`$Say -eq 'alive') { { `$true } } else { { `$false } }
`$r = Invoke-ChatqProcess -Exe '$nsPs' -ArgList @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 7')
[System.IO.File]::WriteAllText('$nsKidOut.' + `$Say, "returned `$(`$r.ExitCode)")
"@, [System.Text.UTF8Encoding]::new($true))
$nsKids = @{}
foreach ($say in 'alive', 'dead') {
    Remove-Item -LiteralPath "$nsKidOut.$say" -Force -EA SilentlyContinue
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $nsPs
    $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$nsKid`" $say"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $nsKids[$say] = [System.Diagnostics.Process]::Start($psi)
}
foreach ($say in 'alive', 'dead') { $null = $nsKids[$say].WaitForExit(90000) }
$nsAlive = Read-TestFile "$nsKidOut.alive"
$nsDead = Read-TestFile "$nsKidOut.dead"
Check 'a step whose parent is gone ends itself at the next check of a run; one whose parent lives runs it to the end' (
    $nsKids['alive'].HasExited -and $nsAlive -eq 'returned 0' -and $nsKids['dead'].HasExited -and $null -eq $nsDead -and $nsKids['dead'].ExitCode -in -1, 137) "alive: '$nsAlive' / dead: '$nsDead' exit $(if ($nsKids['dead'].HasExited) { $nsKids['dead'].ExitCode })"
Remove-Item -LiteralPath $nsKid, "$nsKidOut.alive", "$nsKidOut.dead" -Force -EA SilentlyContinue

# --- the audit: what a step reaches (native/SPEC.md 3.6) --------------------
# Every function an op reaches from its entry, by the commands it calls and
# the ${function:...} it names, over the parts a step loads (the watcher's:
# all but the overlay's three). Not by a function's name in a string: that is
# a command line another process runs, as Get-ChatqWatcherLaunch names
# Invoke-ChatqWatchLoop. In them, each $script: variable, each $W.<key> (in a
# function with a $W parameter: the watch state) and each $PID must be in
# exactly one class below. One in none fails, so a new one is looked at
# before a step carries it wrong. The carry rows are what carry.clixml holds.
# Deferred: DEFERRED.md "The parent-name audit"
$nsAuEntries = 'Repair-ChatqInterrupted', 'Invoke-ChatqPick', 'Update-ChatqBlock', 'Invoke-ChatqWatchAutoScan', 'Clear-ChatqStrayFiles', 'Send-ChatqUsageSoon',
'Send-ChatqHeldSummary', 'Test-ChatqAskLanded', 'Send-ChatqAlert', 'Save-ChatqJob', 'Invoke-ChatqReplyPoll', 'Write-ChatqBoard', 'Invoke-ChatqNativeStep'
$nsAuW = @{
    native = 'blocked', 'lastAllowed', 'probeFails', 'scannedAt', 'outage', 'authAlerted', 'current', 'next', 'handoff', 'listening', 'startedAt'
    carry  = 'CutCache'
}
$nsAuVars = @{
    shared     = 'ChatqReplyHandled', 'ChatqReplySeen', 'ChatqAskSent', 'ChatqReplyJunkLog', 'ChatqReplyPolledAt', 'ChatqReplyErrAt', 'ChatqReplyBadIdAt',
    'ChatqReplySavedAt', 'ChatqUsageSent', 'ChatqSummaryTriedAt'
    # process-lifetime caches and throttles nothing native reads
    carry      = 'ChatqBoardCutCache', 'ChatqCliVersions', 'ChatqAskAliveCache', 'ChatqBoardCache', 'ChatqPermitAsked', 'ChatqAutoCache', 'ChatAgentDoneCache',
    'ChatHostFilesSeen', 'ChatOverlayLogSeen', 'ChatqAskCache', 'ChatqAutoSaid', 'ChatqBoardBgCache', 'ChatqBoardRegCache',
    'ChatqPhoneMetaCache', 'ChatShellChildList', 'ChatqDownErrAt', 'ChatqPhoneWakeAt', 'ChatqAskTidiedAt'
    # reset by each call, built on first use, or read only by the tests (the
    # read counters); ChatGhostWatcher never starts under CHATQ_WATCHER; the
    # index's rows read again by its stamp, cheaper than carried
    recomputed = 'ChatIndexCache', 'ChatIndexStamp', 'ChatqSendingSummary', 'ChatqLastAlertError', 'ChatqAlertReport', 'ChatqLastAlertAid', 'ChatqReplyTextWhy', 'ChatqAskDateKind', 'ChatSayRx',
    'ChatSessionRx', 'ChatGhostWatcher', 'ChatOverlayBytesRead', 'ChatOverlayRecentReads', 'ChatOverlayRecentLists', 'ChatqCutOffReads'
    # what the tests (and native-step.ps1's seams file) set; the last five
    # are the step's own, from In and the command line
    seam       = 'ChatCodeExesSeam', 'ChatCodeProfilesSeam', 'ChatCodeSeam', 'ChatGraceSleepSeam', 'ChatHandoverOff', 'ChatNoGhostWatch', 'ChatOverlayFolderSeam',
    'ChatOverlayNetDriveSeam', 'ChatParentSeam', 'ChatProcessTableSeam', 'ChatRunStateSeam', 'ChatShellChildSeam', 'ChatStopSeam', 'ChatWindowTitlesSeam',
    'ChatqAliveSeam', 'ChatqAskAliveSeam', 'ChatqClockSeam', 'ChatqDownSeam', 'ChatqExtHomeSeam', 'ChatqFooterSeam', 'ChatqHookTimeoutSec', 'ChatqIdleSeam',
    'ChatqJoinSeam', 'ChatqNtfySeam', 'ChatqPermitExeSeam', 'ChatqPermitWaitSeconds', 'ChatqReplyPollSeam', 'ChatqReplyServer', 'ChatqSpawn', 'ChatqStatusUrl',
    'ChatqToastSeam', 'ChatqWatcherPid', 'ChatqWatcherStartedAt', 'ChatqRunnerPid', 'ChatqStepParent', 'ChatqAlertJob'
    # paths, regexes, tables and numbers set at load; ChatqForeground too,
    # since only the loop sets it and a step is never in the foreground
    constant   = 'ChatBackgroundWords', 'ChatClaudeHome', 'ChatCodeWindowsCode', 'ChatCodexHome', 'ChatConsoleStatePath', 'ChatEffortLevels',
    'ChatHandoverAckSeconds', 'ChatHandoverLeaveSeconds', 'ChatHandoverPollMs', 'ChatIdleEndedPath', 'ChatIdleSeconds', 'ChatIndexPath', 'ChatIndexRead',
    'ChatIndexSep', 'ChatIsMac', 'ChatListSpan', 'ChatOpenPath', 'ChatOverlayFolderTtlSeconds', 'ChatOverlayOpenTabsDir', 'ChatOverlayPath',
    'ChatOverlayPendingText', 'ChatOverlayScanBudget', 'ChatOverlaySliceMs', 'ChatProcSnapCode', 'ChatProcTableCode', 'ChatProviders', 'ChatqAlertMark',
    'ChatqAskCaps', 'ChatqAskDir', 'ChatqAuthRx', 'ChatqAutoDir', 'ChatqAutoHoldMinutes', 'ChatqAutoLateMinutes', 'ChatqAutoLockPath', 'ChatqAutoMarkerDays',
    'ChatqAutoMaxAgeHours', 'ChatqAutoMaxResetHours', 'ChatqAutoPath', 'ChatqAutoStreakCap', 'ChatqBoardPath', 'ChatqClaudeMin', 'ChatqCodexAppServerMin',
    'ChatqCodexLimitRx', 'ChatqCodexOverloadRx', 'ChatqCodexSandboxes', 'ChatqComposeActs', 'ChatqComposeLimits', 'ChatqConfigPath', 'ChatqContinueText',
    'ChatqData', 'ChatqDot', 'ChatqDownAttachMax', 'ChatqDownInline', 'ChatqEllipsis', 'ChatqEnvDrop', 'ChatqForeground', 'ChatqHeldLockPath', 'ChatqHeldPath',
    'ChatqHeldTitlesPath', 'ChatqImageExt', 'ChatqIsWindows', 'ChatqJoinIcon', 'ChatqKeepMode', 'ChatqLimitRx', 'ChatqLockPath', 'ChatqLogDir',
    'ChatqModeLadder', 'ChatqNativeTarget', 'ChatqNetworkRx', 'ChatqOverloadRx', 'ChatqPermitDefaultTools', 'ChatqPermitDir', 'ChatqPermitFailPath',
    'ChatqPermitMin', 'ChatqPermitModes', 'ChatqPermitTool', 'ChatqPidPath', 'ChatqQueueDir', 'ChatqReplyActAge', 'ChatqReplyActAgeDefault',
    'ChatqReplyLockPath', 'ChatqReplyPage', 'ChatqReplyPath', 'ChatqRunEnv', 'ChatqRunSettingsDir', 'ChatqSafeSandboxes', 'ChatqSayKo', 'ChatqScriptPath',
    'ChatqSeqLockPath', 'ChatqShellWaitMinutes', 'ChatqStatePath', 'ChatqStatusComponent', 'ChatqStopPath', 'ChatqStrayHours', 'ChatqUsageAlertLockPath',
    'ChatqUsageAlertPath', 'ChatqWakePath', 'ChatqWideLimits', 'ChatReloadPath', 'ChatRoot', 'ChatRunAckDir', 'ChatRunStatePath', 'ChatSdkEntrypoints',
    'ChatSessionScanBudget', 'ChatShellChildTtlSeconds', 'ChatShowHoldSeconds', 'ChatSignalCarryMax', 'ChatSignalCarrySeconds', 'ChatSignalLockPath',
    'ChatTombPath', 'ChatVersion', 'ChatqStepFields', 'ChatqStepCaches', 'ChatqStepCarry'
}
# by the function a $PID is in: chatqd's identity, through the seams, or the
# step's own process (the PowerShell to launch with; the parent check's end)
$nsAuPid = @{
    watcher = 'Save-ChatqWatchState', 'Get-ChatqRunnerPid'
    own     = 'Invoke-ChatqAlertCommand', 'Get-ChatqPermitLaunch', 'Get-ChatqOutboxLaunch', 'Get-ChatqAskHookCommand', 'Get-ChatqWatcherLaunch',
    'Get-ChatOverlayLaunch', 'Receive-ChatOverlayCommands', 'Invoke-ChatOverlayCycle', 'Start-ChatqAskHook', 'Invoke-ChatqProcess', 'Invoke-ChatqNativeStep'
}
$nsAuBad = @()
$nsAuOf = @{}
foreach ($t in @{ W = $nsAuW; Var = $nsAuVars; Pid = $nsAuPid }.GetEnumerator()) {
    $nsAuOf[$t.Key] = @{}
    foreach ($c in $t.Value.GetEnumerator()) {
        foreach ($n in $c.Value) { if ($nsAuOf[$t.Key].ContainsKey($n)) { $nsAuBad += "$n in two classes" }; $nsAuOf[$t.Key][$n] = $c.Key }
    }
}
$nsAuP = [System.Management.Automation.Language.Parser]
$nsAuRoot = $nsAuP::ParseFile((Join-Path $root 'Charlie-and-the-chat-factory.ps1'), [ref]$null, [ref]$null)
$nsAuFn = @{}
foreach ($p in @($nsAuRoot.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$chatParts' }, $true).Right.FindAll(
            { param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { $_.Value } | Where-Object { $_ -notin 'overlay-windows', 'console', 'overlay-mac' })) {
    foreach ($f in $nsAuP::ParseFile((Join-Path $root "src\$p.ps1"), [ref]$null, [ref]$null).FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        if (-not $nsAuFn.ContainsKey($f.Name)) { $nsAuFn[$f.Name] = $f }
    }
}
$nsAuSeen = @{}; $nsAuFound = @{ W = @{}; Var = @{}; Pid = @{} }
$nsAuTodo = [System.Collections.Generic.Queue[string]]::new()
foreach ($e in $nsAuEntries) { if (-not $nsAuFn.ContainsKey($e)) { $nsAuBad += "no entry $e" }; $nsAuTodo.Enqueue($e) }
while ($nsAuTodo.Count) {
    $n = $nsAuTodo.Dequeue()
    if ($nsAuSeen.ContainsKey($n) -or -not $nsAuFn.ContainsKey($n)) { continue }
    $nsAuSeen[$n] = 1
    $f = $nsAuFn[$n]
    foreach ($c in $f.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] }, $true)) { $t = $c.GetCommandName(); if ($t) { $nsAuTodo.Enqueue($t) } }
    foreach ($v in $f.FindAll({ param($x) $x -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
        $up = $v.VariablePath.UserPath
        if ($up -like 'function:*') { $nsAuTodo.Enqueue($up.Substring(9)) }
        elseif ($up -like 'script:*') { $nsAuFound.Var[$up.Substring(7)] = $n }
        elseif ($up -eq 'PID') { $nsAuFound.Pid[$n] = '$PID' }
    }
    if (-not @($f.FindAll({ param($x) $x -is [System.Management.Automation.Language.ParameterAst] -and $x.Name.VariablePath.UserPath -eq 'W' }, $true)).Count) { continue }
    # $W.key, $W['key'] and $W.ContainsKey('key'); anything else on $W (a
    # computed key, another method) is listed as written, so it fails
    foreach ($x in $f.FindAll({ param($x) ($x -is [System.Management.Automation.Language.MemberExpressionAst] -and $x.Expression -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $x.Expression.VariablePath.UserPath -eq 'W') -or ($x -is [System.Management.Automation.Language.IndexExpressionAst] -and $x.Target -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $x.Target.VariablePath.UserPath -eq 'W') }, $true)) {
        $k = if ($x -is [System.Management.Automation.Language.IndexExpressionAst]) { $x.Index }
        elseif ($x -isnot [System.Management.Automation.Language.InvokeMemberExpressionAst]) { $x.Member }
        elseif ($x.Member.Extent.Text -eq 'ContainsKey' -and @($x.Arguments).Count -eq 1) { $x.Arguments[0] }
        $nsAuFound.W[$(if ($k -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $k.Value } else { $x.Extent.Text })] = $n
    }
}
foreach ($t in 'W', 'Var', 'Pid') {
    foreach ($kv in $nsAuFound[$t].GetEnumerator()) { if (-not $nsAuOf[$t].ContainsKey($kv.Key)) { $nsAuBad += "$t $($kv.Key) ($($kv.Value))" } }
}
# what step 4's carry.clixml holds: the carry rows
$nsAuCarry = @($nsAuVars.carry)
Check 'the audit: every $script: variable, $W key and $PID a step''s ops reach is in exactly one class - native W, shared, carry, recomputed, seam or constant; chatqd''s identity or the step''s own' (
    -not $nsAuBad -and $nsAuSeen.ContainsKey('Invoke-ChatqJob') -and $nsAuFound.Var.Count -ge 100) "$($nsAuSeen.Count) functions, $($nsAuFound.Var.Count) variables / $($nsAuBad -join '; ')"

# --- the round trips: the carry and `w` (native/SPEC.md 3.6) ---------------
# Where $B is not $A all the way down: each value's type, an [ordered]'s key
# order and comparer, an array's element type, a List's argument, a date's
# Kind and ticks, every other value as itself
function Compare-NsSame($A, $B, [string]$At) {
    if ($null -eq $A -or $null -eq $B) { if (($null -eq $A) -ne ($null -eq $B)) { "$At null on one side" }; return }
    $t = $A.GetType()
    if ($t -ne $B.GetType()) { "$At $($t.FullName) came back $($B.GetType().FullName)"; return }
    if ($A -is [System.Collections.Specialized.OrderedDictionary]) {
        $f = $t.GetField('_comparer', [System.Reflection.BindingFlags]'NonPublic,Instance')
        if (-not [object]::Equals($f.GetValue($A), $f.GetValue($B))) { "$At comparer $($f.GetValue($B))" }
        if ((@($A.Keys) -join '|') -cne (@($B.Keys) -join '|')) { "$At keys $(@($B.Keys) -join '|')"; return }
        foreach ($k in @($A.Keys)) { Compare-NsSame $A[$k] $B[$k] "$At.$k" }
        return
    }
    if ($A -is [System.Collections.IDictionary]) {
        if ($A.Count -ne $B.Count) { "$At $($B.Count) keys"; return }
        foreach ($k in @($A.Keys)) { if (-not $B.Contains($k)) { "$At no $k" } else { Compare-NsSame $A[$k] $B[$k] "$At.$k" } }
        return
    }
    if ($A -is [System.Collections.IList]) {
        if ($A.Count -ne $B.Count) { "$At $($B.Count) items"; return }
        for ($i = 0; $i -lt $A.Count; $i++) { Compare-NsSame $A[$i] $B[$i] "$At[$i]" }
        return
    }
    if ($A -is [System.Management.Automation.PSCustomObject]) {
        $na = @($A.PSObject.Properties | ForEach-Object { $_.Name }); $nb = @($B.PSObject.Properties | ForEach-Object { $_.Name })
        if (($na -join '|') -cne ($nb -join '|')) { "$At properties $($nb -join '|')"; return }
        foreach ($n in $na) { Compare-NsSame $A.$n $B.$n "$At.$n" }
        return
    }
    if ($A -is [datetime]) { if ($A.Kind -ne $B.Kind -or $A.Ticks -ne $B.Ticks) { "$At $($B.Kind) $($B.ToString('o'))" }; return }
    if ($A -cne $B) { "$At '$B'" }
}

# Each carry row, and $W.CutCache, in a sample of the shape its writers
# leave, through carry.clixml and back over a value of another type: the
# same all the way down - Import-Clixml alone would give a List or an array
# back an ArrayList, and an [ordered] a Hashtable on 5.1, its order lost
# (some not made until first used: those are gone again after)
$nsCaVarsWas = @{}
# each value, not its variable: Set-Variable changes the variable in place
foreach ($n in $nsAuCarry) { $v = Get-Variable -Name $n -Scope Script -EA SilentlyContinue; if ($v) { $nsCaVarsWas[$n] = @{ Value = $v.Value } } }
$nsCaNow = Get-Date
$nsCaOrd = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
$nsCaOrd['Which one?'] = 'B'; $nsCaOrd['which one?'] = 'a'
$nsCaAsked = [System.Collections.Generic.List[datetime]]::new(); $nsCaAsked.Add($nsCaNow.AddMinutes(-3)); $nsCaAsked.Add($nsCaNow)
$nsCaSample = @{
    ChatqBoardCutCache  = @{ 'C:\chats\a.jsonl' = @{ Sig = '120|638000'; Cut = $true } }
    ChatqCliVersions    = @{ 'C:\bin\claude.exe' = '2.1.4'; 'C:\bin\codex.exe' = $null }
    ChatqAskAliveCache  = @{ 'pid|42' = $true; 'pid|43' = $false }
    ChatqBoardCache     = @{ At = $nsCaNow; Body = 'the board'; Scan = @([pscustomobject]@{ Id = 'a'; At = $nsCaNow; Lines = @() }); ScanAt = $nsCaNow.AddSeconds(-5) }
    ChatqPermitAsked    = $nsCaAsked
    ChatqAutoCache      = @{ Sig = 'x|1'; Value = [pscustomobject]@{ Enabled = $true; Hold = 30 } }
    ChatAgentDoneCache  = @{ 'a.jsonl|99' = $true }
    ChatHostFilesSeen   = @{ 'C:\work' = @{ 'one.txt' = [int64]1200; 'two.txt' = @{ Len = [int64]3; At = $nsCaNow } } }
    ChatOverlayLogSeen  = @{ 'a' = $nsCaNow }
    ChatqAskCache       = @{ 'C:\ask\r1.json' = @{ Len = [int64]88; Mtime = [int64]638000000000000001; Result = [pscustomobject]@{ Rid = 'r1'; Answers = $nsCaOrd } } }
    ChatqAutoSaid       = @{ 'job|1' = $true }
    ChatqBoardBgCache   = @{ 'C:\chats\b.jsonl' = @{ Path = 'C:\chats\b.jsonl'; Offset = [int64]512; Open = [ordered]@{ t1 = @{ Id = 't1'; At = $nsCaNow; Name = 'Bash' } }; Done = 2 } }
    ChatqBoardRegCache  = @{ 'b' = [pscustomobject]@{ Title = 'a chat'; At = $nsCaNow } }
    ChatqPhoneMetaCache = @{ 'b|3' = [pscustomobject]@{ Model = 'opus'; Tokens = 1200 } }
    ChatShellChildList  = @{ At = $nsCaNow; Rows = [string[]]@('1|2|pwsh', '3|1|node') }
    ChatqDownErrAt      = $nsCaNow.AddMinutes(-1)
    ChatqPhoneWakeAt    = $null
    ChatqAskTidiedAt    = $nsCaNow.ToUniversalTime()
}
$nsCaW = New-ChatqWatchState
$nsCaCut = @{ 'C:\chats\c.jsonl' = @{ Sig = '1|2'; Row = [pscustomobject]@{ Id = 'c'; Cut = 3 } } }
$nsCaBack = @{}
try {
    foreach ($n in $nsAuCarry) { Set-Variable -Name $n -Scope Script -Value $nsCaSample[$n] }
    $nsCaW.CutCache = $nsCaCut
    Export-ChatqStepCarry $nsCaW
    foreach ($n in $nsAuCarry) { Set-Variable -Name $n -Scope Script -Value 'not carried' }
    $nsCaW.CutCache = 'not carried'
    Import-ChatqStepCarry $nsCaW
    foreach ($n in $nsAuCarry) { $nsCaBack[$n] = (Get-Variable -Name $n -Scope Script).Value }
}
finally {
    foreach ($n in $nsAuCarry) {
        if ($nsCaVarsWas[$n]) { Set-Variable -Name $n -Scope Script -Value $nsCaVarsWas[$n].Value } else { Remove-Variable -Name $n -Scope Script -EA SilentlyContinue }
    }
    Remove-Item -LiteralPath (Get-ChatqNativeFile 'carry.clixml') -Force -EA SilentlyContinue
}
$nsCaBad = @(foreach ($n in $nsAuCarry) { Compare-NsSame $nsCaSample[$n] $nsCaBack[$n] $n }) + @(Compare-NsSame $nsCaCut $nsCaW.CutCache 'CutCache')
$nsCaRows = (@($script:ChatqStepCarry | Sort-Object) -join ',') -eq (@($nsAuCarry | Sort-Object) -join ',')
Check 'the carry: the audit''s carry rows are what carry.clixml holds, and each, with $W.CutCache, comes back its own type all the way down - a List[datetime], an array''s element type, a hashtable or an object, an [ordered] in its order' (
    $nsCaRows -and -not $nsCaBad) "rows the same $nsCaRows / $($nsCaBad -join '; ')"

# `w` through JSON and back, as chatqd carries it: entries of both types, a
# map's empty key, a question's answers in their order and by case, a
# stamp-shaped string still a string, a date Kind Local again
$nsWcWas = @{}
foreach ($n in $script:ChatqStepCaches.Keys) { $nsWcWas[$n] = (Get-Variable -Name $n -Scope Script).Value }
$nsWcNow = Get-Date
$nsWcAns = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
$nsWcAns['Second?'] = 'no'; $nsWcAns['First?'] = 'yes'; $nsWcAns['first?'] = 'maybe'
$nsWcW = New-ChatqWatchState
$nsWcW.blocked = @{ 'claude' = [pscustomobject]@{ Until = $nsWcNow.AddHours(2); Type = 'limit'; Source = 'job'; At = $nsWcNow } }
$nsWcW.outage = @{ 'codex' = @{ Since = $nsWcNow; Attempts = 3; Status = 'major'; Alerted = $true; Reminded = $false; LastProbe = $nsWcNow; NextCheck = $null; AutoJob = $null } }
$nsWcW.lastAllowed = @{ '' = $nsWcNow; 'A' = $nsWcNow.AddSeconds(-1) }
$nsWcW.probeFails = @{ 'claude' = 2 }
$nsWcW.scannedAt = @{}
$nsWcW.authAlerted = @{ 'codex' = $true }
$nsWcW.current = 'job-1'
$nsWcW.next = $null
$nsWcW.startedAt = $nsWcNow.ToString('o')
$nsWcW.handoff = $false
$nsWcW.listening = $true
$nsWcCaches = @{
    ChatqReplyHandled = @{ 'm1' = $true; '2026-10-18T03:00:00.0000000Z' = $true }; ChatqReplySeen = @{}; ChatqUsageSent = @{ 'five|1' = $true }
    ChatqAskSent = @{ 'r1' = @{ Rid = 'r1'; At = $nsWcNow; ToolUseId = 't1'; Answers = $nsWcAns; Transcript = 'C:\a.jsonl'; SessionId = 's1'; Title = 'a chat' }
        # a named field holding another scalar than its kind travels as it is
        'r2' = @{ Rid = 'r2'; At = $nsWcNow; Answers = 'not a map' }
    }
    ChatqReplyJunkLog = @{ 'x' = [pscustomobject]@{ At = $nsWcNow; Count = 4 } }
    ChatqReplyPolledAt = $nsWcNow; ChatqReplyErrAt = $null; ChatqReplyBadIdAt = $null; ChatqReplySavedAt = $nsWcNow.AddMinutes(-9); ChatqSummaryTriedAt = $null
}
$nsWcErr = $null
try {
    foreach ($n in $script:ChatqStepCaches.Keys) { Set-Variable -Name $n -Scope Script -Value $nsWcCaches[$n] }
    $nsWcBack = ConvertFrom-ChatqStepW ((ConvertTo-ChatqStepW $nsWcW) | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
}
catch { $nsWcErr = "$_" }
finally { foreach ($n in $script:ChatqStepCaches.Keys) { Set-Variable -Name $n -Scope Script -Value $nsWcWas[$n] } }
$nsWcBad = if ($nsWcErr) { @($nsWcErr) } else {
    @(foreach ($k in 'blocked', 'outage', 'lastAllowed', 'probeFails', 'scannedAt', 'authAlerted', 'current', 'next', 'startedAt', 'handoff', 'listening') { Compare-NsSame $nsWcW[$k] $nsWcBack.W[$k] $k }) +
    @(foreach ($n in $script:ChatqStepCaches.Keys) { Compare-NsSame $nsWcCaches[$n] $nsWcBack.Caches[$n] $n })
}
Check '`w` through JSON and back: the watch state and the shared caches as they were - each entry''s type, the answers in order, keys by case, dates Kind Local, a stamp-shaped string text' (
    -not $nsWcBad) ($nsWcBad -join '; ')

# The step itself, in a child as chatqd starts it: a copy of the tool on
# its own data, the stray op, then In of an op not known, run here
$nsSmRoot = Join-Path $sb 'native-step-smoke'
Remove-Item -LiteralPath $nsSmRoot -Recurse -Force -EA SilentlyContinue
$null = New-Item -ItemType Directory -Path (Join-Path $nsSmRoot 'data\native') -Force
Copy-Item -LiteralPath (Join-Path $sb 'tool\Charlie-and-the-chat-factory.ps1') -Destination $nsSmRoot -Force
Copy-Item -LiteralPath (Join-Path $sb 'tool\src') -Destination $nsSmRoot -Recurse -Force
$nsSmEmpty = [ordered]@{ blocked = @(); outage = @(); lastAllowed = @(); probeFails = @(); scannedAt = @(); authAlerted = @(); current = $null; next = $null; startedAt = $null
    handoff = $false; listening = $false; caches = [ordered]@{}
}
foreach ($n in $script:ChatqStepCaches.Keys) { $nsSmEmpty.caches[$n] = if ($script:ChatqStepCaches[$n] -eq 'date') { $null } else { , @() } }
$nsSmStart = (Get-Process -Id $PID).StartTime.ToUniversalTime()
$nsSmIn = Join-Path $nsSmRoot 'data\native\step-1.in.json'
$nsSmOut = Join-Path $nsSmRoot 'data\native\step-1.out.json'
[System.IO.File]::WriteAllText($nsSmIn, ([ordered]@{ v = 1; op = 'stray'; watcherPid = $PID; startedAt = $nsSmStart.ToString('o'); alertJob = $null; w = $nsSmEmpty; args = @{} } | ConvertTo-Json -Depth 8), $utf8)
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $nsPs
$psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$(Join-Path $nsSmRoot 'src\native-step.ps1')`" -In `"$nsSmIn`" -Out `"$nsSmOut`" -Watcher $PID -WatcherStart $($nsSmStart.Ticks)"
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.EnvironmentVariables['CHATQ_WATCHER'] = '1'
$nsSm = [System.Diagnostics.Process]::Start($psi)
$nsSmDone = $nsSm.WaitForExit(120000)
$nsSmR = Read-ChatqJson $nsSmOut
$nsSmW = try { $null = ConvertFrom-ChatqStepW $nsSmR.w; 'decodes' } catch { "$_" }
Check 'a helper step, run as chatqd runs one: the stray op on a copy of the tool, exit 0, Out ok with removed 0 and a w that decodes' (
    $nsSmDone -and $nsSm.ExitCode -eq 0 -and $nsSmR.ok -eq $true -and $null -eq $nsSmR.error -and $nsSmR.result.removed -eq 0 -and $nsSmW -eq 'decodes') "exit $(if ($nsSmDone) { $nsSm.ExitCode }) / $(Read-TestFile $nsSmOut) / w $nsSmW"
[System.IO.File]::WriteAllText($nsSmIn, '{"v":1,"op":"nope","w":{},"args":{}}', $utf8)
Remove-Item -LiteralPath $nsSmOut -Force -EA SilentlyContinue
Invoke-ChatqNativeStep -In $nsSmIn -Out $nsSmOut
$nsSmR = Read-ChatqJson $nsSmOut
Check 'In naming an op not known: Out says bad step input, nothing run' ($nsSmR.ok -eq $false -and $nsSmR.error -eq 'bad step input' -and $null -eq $nsSmR.w) (Read-TestFile $nsSmOut)
Remove-Item -LiteralPath $nsSmRoot -Recurse -Force -EA SilentlyContinue

# --- each op through Invoke-ChatqNativeStep (native/SPEC.md 3.6) -------------
# Where an Out's w is not the schema: the eleven keys and caches, each map a
# list of {k, v}, each entry tagged with its type, each date a UTC o string.
# A scalar is read as the step reads one: pwsh 7 makes a [datetime] of a stamp.
function Get-NsWBad($J) {
    $o = '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{7}Z$'
    $pairs = {
        param($L, [string]$Kind, [string]$At, $Fields)
        if ($L -isnot [array]) { "$At not a list"; return }
        foreach ($p in $L) {
            if ($p -isnot [System.Management.Automation.PSCustomObject] -or (@($p.PSObject.Properties | ForEach-Object { $_.Name }) -join ',') -cne 'k,v' -or
                (ConvertFrom-ChatqStepText $p.k) -isnot [string]) { "$At pair $($p | ConvertTo-Json -Compress -Depth 4)" }
            else { & $val $p.v $Kind "$At[$($p.k)]" $Fields }
        }
    }
    $val = {
        param($V, [string]$Kind, [string]$At, $Fields)
        if ($null -eq $V) { return }
        $s = ConvertFrom-ChatqStepText $V
        switch ($Kind) {
            'date' { if ($s -isnot [string] -or $s -notmatch $o) { "$At not a UTC o date: $s" } }
            'int' { if ($V -isnot [int] -and $V -isnot [long]) { "$At not an int: $V" } }
            'bool' { if ($V -isnot [bool]) { "$At not a bool: $V" } }
            'string' { if ($s -isnot [string]) { "$At not a string: $V" } }
            'answers' { & $pairs $V 'string' $At $null }
            'entry' {
                if ($V -isnot [System.Management.Automation.PSCustomObject] -or -not $V.PSObject.Properties['_type'] -or [string]$V._type -cnotin 'psobject', 'hashtable') { "$At no _type"; return }
                foreach ($p in $V.PSObject.Properties) {
                    if ($p.Name -cne '_type') { & $val $p.Value $(if ($Fields -and $Fields[$p.Name]) { $Fields[$p.Name] } else { 'scalar' }) "$At.$($p.Name)" $null }
                }
            }
            default { if ($V -is [System.Management.Automation.PSCustomObject] -or $V -is [array]) { "$At not a scalar" } }
        }
    }
    if ($J -isnot [System.Management.Automation.PSCustomObject]) { 'w not an object'; return }
    $keys = 'blocked', 'outage', 'lastAllowed', 'probeFails', 'scannedAt', 'authAlerted', 'current', 'next', 'startedAt', 'handoff', 'listening', 'caches'
    $names = @($J.PSObject.Properties | ForEach-Object { $_.Name })
    if ((@($names | Sort-Object) -join ',') -cne (@($keys | Sort-Object) -join ',')) { "w keys $($names -join ',')"; return }
    $f = $script:ChatqStepFields
    foreach ($k in 'blocked', 'outage') { & $pairs $J.$k 'entry' $k $f[$k] }
    foreach ($k in 'lastAllowed', 'scannedAt') { & $pairs $J.$k 'date' $k $null }
    & $pairs $J.probeFails 'int' 'probeFails' $null
    & $pairs $J.authAlerted 'bool' 'authAlerted' $null
    foreach ($k in 'current', 'next', 'startedAt') { & $val $J.$k 'string' $k $null }
    foreach ($k in 'handoff', 'listening') { if ($J.$k -isnot [bool]) { "$k not a bool: $($J.$k)" } }
    $c = $J.caches
    if ($c -isnot [System.Management.Automation.PSCustomObject]) { 'caches not an object'; return }
    $cn = @($c.PSObject.Properties | ForEach-Object { $_.Name })
    if ((@($cn | Sort-Object) -join ',') -cne (@($script:ChatqStepCaches.Keys | Sort-Object) -join ',')) { "caches $($cn -join ',')"; return }
    foreach ($n in $script:ChatqStepCaches.Keys) {
        if ($script:ChatqStepCaches[$n] -eq 'date') { & $val $c.$n 'date' $n $null } else { & $pairs $c.$n $script:ChatqStepCaches[$n] $n $f[$n] }
    }
}

# `w` as chatqd sends it: this W and these caches (the rest empty), encoded
# as a step encodes them, the caches here put back after
function ConvertTo-NsStepW($W, $Caches) {
    $was = @{}
    foreach ($n in $script:ChatqStepCaches.Keys) { $was[$n] = (Get-Variable -Name $n -Scope Script).Value }
    try {
        foreach ($n in $script:ChatqStepCaches.Keys) {
            Set-Variable -Name $n -Scope Script -Value $(if ($Caches.ContainsKey($n)) { $Caches[$n] } elseif ($script:ChatqStepCaches[$n] -eq 'date') { $null } else { @{} })
        }
        ConvertTo-ChatqStepW $W
    }
    finally { foreach ($n in $script:ChatqStepCaches.Keys) { Set-Variable -Name $n -Scope Script -Value $was[$n] } }
}
function Save-NsStepIn([string]$Path, [string]$Op, $WJ, $ArgsJ, $AlertJob) {
    $in = [ordered]@{ v = 1; op = $Op; watcherPid = $PID; startedAt = $WJ.startedAt; alertJob = $AlertJob; w = $WJ; args = $ArgsJ }
    [System.IO.File]::WriteAllText($Path, ($in | ConvertTo-Json -Depth 12), $utf8)
}

# One op run here, on In made of $script:nsOpWJ: the caches, the carry's
# variables and the step's seams put back after, carry.clixml gone again
$nsOpIn = Join-Path $sb 'native-step-op.in.json'
$nsOpOut = Join-Path $sb 'native-step-op.out.json'
function Invoke-NsOp([string]$Op, $ArgsJ, $AlertJob) {
    $keep = @{}
    foreach ($n in @($script:ChatqStepCaches.Keys) + @($script:ChatqStepCarry) + @('ChatqWatcherPid', 'ChatqWatcherStartedAt', 'ChatqRunnerPid', 'ChatqAlertJob')) {
        $v = Get-Variable -Name $n -Scope Script -EA SilentlyContinue
        $keep[$n] = if ($v) { @{ Value = $v.Value } } else { $null }
    }
    Save-NsStepIn $nsOpIn $Op $script:nsOpWJ $ArgsJ $AlertJob
    Remove-Item -LiteralPath $nsOpOut -Force -EA SilentlyContinue
    try { $null = Invoke-ChatqNativeStep -In $nsOpIn -Out $nsOpOut }
    finally {
        foreach ($n in $keep.Keys) { if ($keep[$n]) { Set-Variable -Name $n -Scope Script -Value $keep[$n].Value } else { Remove-Variable -Name $n -Scope Script -EA SilentlyContinue } }
        Remove-Item -LiteralPath (Get-ChatqNativeFile 'carry.clixml') -Force -EA SilentlyContinue
    }
    Read-ChatqJson $nsOpOut
}

# Every op on one W and its caches, each entry function stubbed but pick's
# and job-write's: the w out is the w in, but for what the stub changed,
# and the result holds the fields its row names. A pick of a job removed,
# or no longer queued, does nothing at all: no probe, no line in watcher.log
# or jobs.log, the job's file as it was. A job-write's complete ends a
# queued job as chatqd's pick failure would, and leaves a done one alone.
$script:nsOpAt = (Get-Date).AddMinutes(-2)
$nsOpJob = New-TestJob 'plugin' 'an op''s job'
$nsOpLane = Get-ChatqLane $nsOpJob
$nsOpDone = New-TestJob 'plugin' 'an op''s job, done'
Set-ChatqJobState $nsOpDone 'done' 'test'
$nsOpGone = New-TestJob 'plugin' 'an op''s job, removed'
$null = Remove-ChatqJob (Find-ChatqJob $nsOpGone.id -Exact) 'test'
$nsOpEnd = New-TestJob 'plugin' 'an op''s job, failed for chatqd'
$nsOpDeferred = Find-ChatqJob $nsOpJob.id -Exact
Set-ChatqProp $nsOpDeferred 'deferUntil' ((Get-Date).AddHours(1).ToUniversalTime().ToString('o'))
Save-ChatqJob $nsOpDeferred
$nsOpW = New-ChatqWatchState
$nsOpW.blocked[$nsOpLane] = [pscustomobject]@{ Until = $script:nsOpAt.AddHours(3); Type = 'five_hour'; Source = 'run'; At = $script:nsOpAt }
$nsOpW.outage['codex'] = @{ Since = $script:nsOpAt; Attempts = 2; Status = 'major'; Alerted = $true; LastProbe = $script:nsOpAt; NextCheck = $script:nsOpAt.AddMinutes(5); AutoJob = $null }
$nsOpW.lastAllowed["$nsOpLane|opus"] = $script:nsOpAt
$nsOpW.probeFails['codex'] = 3
$nsOpW.authAlerted['codex'] = $true
$nsOpW.startedAt = $script:nsOpAt.ToUniversalTime().ToString('o')
$script:nsOpWJ = ConvertTo-NsStepW $nsOpW @{
    ChatqAskSent       = @{ 'r1' = @{ Rid = 'r1'; At = $script:nsOpAt; ToolUseId = 't1'; Answers = $null; Transcript = $null; SessionId = 's1'; Title = 'a chat' } }
    ChatqUsageSent     = @{ 's|codex|1' = $true }
    ChatqReplyPolledAt = $script:nsOpAt
}
$nsOpFail = "$($nsOpJob.title) $($script:ChatqDot) chatq error: helper step exited 1 with no answer"
# a pick failure's write, as chatqd hands it to a step (native/SPEC.md 2.4)
$nsOpEndArgs = { param($Id) [ordered]@{ jobId = $Id; complete = [ordered]@{ state = 'failed'; why = 'chatq error'; result = [ordered]@{ kind = 'failed'; reason = 'chatq error: helper step exited 1 with no answer' } } } }
$nsOpCases = @(
    @{ Op = 'repair'; Args = [ordered]@{}; Calls = 'repair'; Result = '' }
    @{ Op = 'pick'; Args = [ordered]@{ jobId = $nsOpJob.id }; Alert = "#$($nsOpJob.seq)"; Calls = "probe $($nsOpJob.id)"; Result = 'gone=False'; Want = { param($d) $d.W.probeFails[$nsOpLane] = 0 } }
    @{ Op = 'pick'; Name = 'pick, removed'; Args = [ordered]@{ jobId = $nsOpGone.id }; Calls = ''; Result = 'gone=True'; Quiet = $true }
    @{ Op = 'pick'; Name = 'pick, done'; Args = [ordered]@{ jobId = $nsOpDone.id }; Calls = ''; Result = 'gone=True'; Quiet = $true }
    @{ Op = 'block'; Args = [ordered]@{ jobIds = @($nsOpJob.id, $nsOpGone.id) }; Calls = "block $($nsOpJob.id)"; Result = ''; Want = { param($d) $d.W.scannedAt[$nsOpLane] = $script:nsOpAt } }
    @{ Op = 'auto'; Args = [ordered]@{}; Calls = 'auto 1'; Result = '' }
    @{ Op = 'stray'; Args = [ordered]@{}; Calls = ''; Result = 'removed=2'; Log = 'removed 2 stray file(s) and folder(s) from data/queue' }
    @{ Op = 'soon'; Args = [ordered]@{}; Calls = 'soon'; Result = "soonAt=$($script:nsOpAt.AddMinutes(30).ToUniversalTime().ToString('o'))"; Want = { param($d) $d.Caches.ChatqUsageSent["s|$nsOpLane|9"] = $true } }
    @{ Op = 'held'; Args = [ordered]@{}; Calls = 'held'; Result = 'sent=False'; Want = { param($d) $d.Caches.ChatqSummaryTriedAt = $script:nsOpAt } }
    @{ Op = 'ask-landed'; Args = [ordered]@{ quick = $false }; Calls = 'ask-landed False r1'; Result = ''; Want = { param($d) $d.Caches.ChatqAskSent.Remove('r1') } }
    @{ Op = 'alert'; Args = [ordered]@{ event = 'failed'; text = $nsOpFail; priority = 2; jobId = $nsOpJob.id; loud = $false; quick = $false; noReply = $false; usageKind = $null }
        Alert = "#$($nsOpJob.seq)"; Calls = "alert failed|$nsOpFail|2|False|$($nsOpJob.id)|False|False||#$($nsOpJob.seq)"; Result = 'sent=True' }
    @{ Op = 'job-write'; Args = [ordered]@{ jobId = $nsOpJob.id; set = [ordered]@{ deferUntil = $null } }; Calls = ''; Result = 'saved=True' }
    @{ Op = 'job-write'; Name = 'job-write, removed'; Args = [ordered]@{ jobId = $nsOpGone.id; set = [ordered]@{ deferUntil = $null } }; Calls = ''; Result = 'saved=False'; Quiet = $true }
    @{ Op = 'job-write'; Name = 'job-write, complete'; Args = (& $nsOpEndArgs $nsOpEnd.id); Calls = ''; Result = 'saved=True' }
    @{ Op = 'job-write'; Name = 'job-write, complete, done'; Args = (& $nsOpEndArgs $nsOpDone.id); Calls = ''; Result = 'saved=False'; Quiet = $true }
    # chatqd's batch as -Text, or the step's own fetch; -Force either way
    @{ Op = 'reply'; Args = [ordered]@{ text = "{`"id`":`"m1`"}`n{`"id`":`"m2`"}"; maxMessages = 10; quick = $false; timeoutSec = 8 }
        Calls = "reply True|True|{`"id`":`"m1`"}`n{`"id`":`"m2`"}|10|False|8"; Result = 'acted=2' }
    @{ Op = 'reply'; Name = 'reply, fetch'; Args = [ordered]@{ fetch = $true; maxMessages = 10; quick = $false; timeoutSec = 8 }; Calls = 'reply True|False||10|False|8'; Result = 'acted=2' }
    # counts left out: the poll's own defaults (the stand-in's, copied), not 0
    @{ Op = 'reply'; Name = 'reply, no counts given'; Args = [ordered]@{ fetch = $true }; Calls = 'reply True|False||10|False|8'; Result = 'acted=2' }
    @{ Op = 'board'; Args = [ordered]@{}; Calls = 'board'; Result = '' }
)
$nsFnWas = @{}
foreach ($k in 'Repair-ChatqInterrupted', 'Confirm-ChatqAllowed', 'Invoke-ChatqJob', 'Update-ChatqBlock', 'Invoke-ChatqWatchAutoScan', 'Clear-ChatqStrayFiles', 'Send-ChatqUsageSoon',
    'Send-ChatqHeldSummary', 'Test-ChatqAskLanded', 'Send-ChatqAlert', 'Invoke-ChatqReplyPoll', 'Write-ChatqBoard') { $nsFnWas[$k] = (Get-Item "function:$k").ScriptBlock }
$script:nsCalls = [System.Collections.Generic.List[string]]::new()
$nsOpBad = @()
$nsLogLen = { @(foreach ($n in 'watcher.log', 'jobs.log') { $p = Join-Path $script:ChatqLogDir $n; if (Test-Path -LiteralPath $p) { (Get-Item -LiteralPath $p).Length } else { 0 } }) -join ',' }
try {
    Set-Item function:Repair-ChatqInterrupted { $script:nsCalls.Add('repair') }
    Set-Item function:Confirm-ChatqAllowed { param($W, $Job) $script:nsCalls.Add("probe $($Job.id)"); $W.probeFails[(Get-ChatqLane $Job)] = 0; $false }
    Set-Item function:Invoke-ChatqJob { param($W, $Job) $script:nsCalls.Add("run $($Job.id)") }
    Set-Item function:Update-ChatqBlock { param($W, $Job, [switch]$Force) $script:nsCalls.Add("block $($Job.id)"); $W.scannedAt[(Get-ChatqLane $Job)] = $script:nsOpAt }
    Set-Item function:Invoke-ChatqWatchAutoScan { param($W) $script:nsCalls.Add("auto $($W.outage.Count)"); 0 }
    Set-Item function:Clear-ChatqStrayFiles { 'a stray file', 'a stray folder' }
    Set-Item function:Send-ChatqUsageSoon { param($W, [object[]]$Queued) $script:nsCalls.Add('soon'); $script:ChatqUsageSent["s|$(@($W.blocked.Keys)[0])|9"] = $true; $script:nsOpAt.AddMinutes(30) }
    Set-Item function:Send-ChatqHeldSummary { param([switch]$Force) $script:nsCalls.Add('held'); $script:ChatqSummaryTriedAt = $script:nsOpAt; $false }
    Set-Item function:Test-ChatqAskLanded { param([switch]$Quick) $script:nsCalls.Add("ask-landed $([bool]$Quick) $(@($script:ChatqAskSent.Keys) -join ',')"); $script:ChatqAskSent.Remove('r1') }
    Set-Item function:Send-ChatqAlert {
        param([string]$Kind, [string]$Text, [int]$Priority, [switch]$Loud, $Job, [switch]$Quick, [switch]$NoReply, [string]$UsageKind)
        $script:nsCalls.Add("alert $Kind|$Text|$Priority|$Loud|$($Job.id)|$Quick|$NoReply|$UsageKind|$script:ChatqAlertJob"); $true
    }
    Set-Item function:Invoke-ChatqReplyPoll {
        param([switch]$Force, [int]$TimeoutSec = 8, [int]$MinSeconds = 15, [int]$MaxMessages = 10, [switch]$Quick, [string]$Text)
        $script:nsCalls.Add("reply $Force|$($PSBoundParameters.ContainsKey('Text'))|$Text|$MaxMessages|$Quick|$TimeoutSec"); 2
    }
    Set-Item function:Write-ChatqBoard { $script:nsCalls.Add('board') }
    foreach ($c in $nsOpCases) {
        $name = if ($c.Name) { $c.Name } else { $c.Op }
        $script:nsCalls.Clear()
        $logsWas = & $nsLogLen
        $fileWas = Read-TestFile (Join-Path $script:ChatqQueueDir "$($nsOpDone.id).json")
        $r = Invoke-NsOp $c.Op $c.Args $c.Alert
        if (-not $r -or $r.ok -ne $true -or $null -ne $r.error) { $nsOpBad += "${name}: $(Read-TestFile $nsOpOut)"; continue }
        $bad = @(Get-NsWBad $r.w)
        $want = ConvertFrom-ChatqStepW ($script:nsOpWJ | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
        if ($c.Want) { & $c.Want $want }
        $got = try { ConvertFrom-ChatqStepW $r.w } catch { $bad += "w: $_"; $null }
        if ($got) {
            $bad += @(foreach ($k in 'blocked', 'outage', 'lastAllowed', 'probeFails', 'scannedAt', 'authAlerted', 'current', 'next', 'startedAt', 'handoff', 'listening') { Compare-NsSame $want.W[$k] $got.W[$k] $k })
            $bad += @(foreach ($n in $script:ChatqStepCaches.Keys) { Compare-NsSame $want.Caches[$n] $got.Caches[$n] $n })
        }
        $res = if ($r.result -is [System.Management.Automation.PSCustomObject]) { @($r.result.PSObject.Properties | ForEach-Object { "$($_.Name)=$(ConvertFrom-ChatqStepText $_.Value)" }) -join ';' } else { '(none)' }
        if ($res -cne $c.Result) { $bad += "result '$res'" }
        if (($script:nsCalls -join ' / ') -cne $c.Calls) { $bad += "calls '$($script:nsCalls -join ' / ')'" }
        if ($c.Quiet -and ((& $nsLogLen) -ne $logsWas -or (Read-TestFile (Join-Path $script:ChatqQueueDir "$($nsOpDone.id).json")) -cne $fileWas -or
                (Test-Path -LiteralPath (Join-Path $script:ChatqQueueDir "$($nsOpGone.id).json")))) { $bad += 'a log line, or a job written or made again' }
        if ($c.Log) {
            $last = @([System.IO.File]::ReadAllLines((Join-Path $script:ChatqLogDir 'watcher.log'), $utf8))[-1]
            if (-not $last.EndsWith("  $($c.Log)")) { $bad += "watcher.log '$last'" }
        }
        if ($bad) { $nsOpBad += "${name}: $($bad -join '; ')" }
    }
}
finally { foreach ($k in $nsFnWas.Keys) { Set-Item "function:$k" $nsFnWas[$k] } }
$nsOpWritten = Find-ChatqJob $nsOpJob.id -Exact
if (-not $nsOpWritten.PSObject.Properties['deferUntil'] -or $null -ne $nsOpWritten.deferUntil) { $nsOpBad += "job-write: deferUntil '$($nsOpWritten.deferUntil)'" }
$nsOpEnded = Find-ChatqJob $nsOpEnd.id -Exact
$nsOpEndLine = "#$($nsOpEnd.seq) failed - chatq error $($script:ChatqDot) $($nsOpEnd.title)"
if ($nsOpEnded.state -ne 'failed' -or $nsOpEnded.result.kind -ne 'failed' -or $nsOpEnded.result.reason -ne 'chatq error: helper step exited 1 with no answer' -or
    @($nsOpEnded.history)[-1].why -ne 'chatq error' -or -not $nsOpEnded.endedAt -or $null -ne $nsOpEnded.runnerPid -or
    -not (@([System.IO.File]::ReadAllLines((Join-Path $script:ChatqLogDir 'jobs.log'), $utf8)) | Where-Object { $_.EndsWith("  $nsOpEndLine") })) {
    $nsOpBad += "job-write, complete: $($nsOpEnded | ConvertTo-Json -Compress -Depth 4)"
}
$nsOpBad += @(Get-NsWBad ($script:nsOpWJ | ConvertTo-Json -Depth 12 | ConvertFrom-Json) | ForEach-Object { "In: $_" })
Check 'each op through Invoke-ChatqNativeStep: w in and out in the schema, the w in but for what the op changed, the result its row names; a pick of a job removed or done does nothing; job-write ends a queued job as chatqd''s pick failure, never a done one' (
    -not $nsOpBad -and $null -eq $script:ChatqWatcherPid -and $null -eq $script:ChatqRunnerPid) ($nsOpBad -join ' || ')

# --- held, soon and an alert as real steps, under the harness's seams ------
# Three children as chatqd starts them, on a copy of the tool with data of
# its own: Join set up and nobody at the PC, so each would toast and push.
# The seams file's capture takes both instead (src/native-step.ps1), and
# nothing leaves the PC.
$nsRpRoot = Join-Path $sb 'native-step-real'
$nsRpData = Join-Path $nsRpRoot 'data'
$nsRpCap = Join-Path $nsRpRoot 'capture'
Remove-Item -LiteralPath $nsRpRoot -Recurse -Force -EA SilentlyContinue
foreach ($d in (Join-Path $nsRpData 'native'), (Join-Path $nsRpData 'queue'), $nsRpCap) { $null = New-Item -ItemType Directory -Path $d -Force }
Copy-Item -LiteralPath (Join-Path $sb 'tool\Charlie-and-the-chat-factory.ps1') -Destination $nsRpRoot -Force
Copy-Item -LiteralPath (Join-Path $sb 'tool\src') -Destination $nsRpRoot -Recurse -Force
$nsCfgWas = Read-TestFile $script:ChatqConfigPath
$null = Set-ChatqNotifyConfig @{ ApiKey = '0123456789abcdef0123456789abcdef'; Device = 'group.phone'; Events = 'all' }
Copy-Item -LiteralPath $script:ChatqConfigPath -Destination (Join-Path $nsRpData 'config.json') -Force
Restore-TestFile $script:ChatqConfigPath $nsCfgWas
Copy-Item -LiteralPath (Join-Path $script:ChatqQueueDir "$($nsOpJob.id).json") -Destination (Join-Path $nsRpData 'queue') -Force
[System.IO.File]::WriteAllText((Join-Path $nsRpData 'held.jsonl'), (([ordered]@{ at = (Get-Date).AddHours(-3).ToUniversalTime().ToString('o'); event = 'done'; text = 'a chat finished in the night'
                priority = 1; seq = $nsOpJob.seq; title = $nsOpJob.title; until = $null
            } | ConvertTo-Json -Compress) + "`n"), $utf8)
$nsRpSeams = Join-Path $nsRpRoot 'seams.json'
[System.IO.File]::WriteAllText($nsRpSeams, ([ordered]@{ capture = $nsRpCap; spawn = $true; idleSeconds = 99999; handoverOff = $true } | ConvertTo-Json), $utf8)
$nsRpNow = Get-Date
$nsRpW = New-ChatqWatchState
$nsRpW.blocked[$nsOpLane] = [pscustomobject]@{ Until = $nsRpNow.AddMinutes(9); Type = 'five_hour'; Source = 'run'; At = $nsRpNow.AddMinutes(-120) }
$nsRpW.startedAt = $nsSmStart.ToString('o')
$nsRpWJ = ConvertTo-NsStepW $nsRpW @{}
# one step in a child: its exit code, its Out, and what it captured
function Invoke-NsRealStep([string]$Root, [int]$N, [string]$Op, $ArgsJ, $AlertJob) {
    $in = Join-Path $Root "data\native\step-$N.in.json"
    $out = Join-Path $Root "data\native\step-$N.out.json"
    Save-NsStepIn $in $Op $nsRpWJ $ArgsJ $AlertJob
    $capWas = @(Get-ChildItem -LiteralPath $nsRpCap -File | ForEach-Object { $_.Name })
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $nsPs
    $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$(Join-Path $Root 'src\native-step.ps1')`" -In `"$in`" -Out `"$out`" -Watcher $PID -WatcherStart $($nsSmStart.Ticks) -Seams `"$nsRpSeams`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    # the watcher's parts, as chatqd's environment has them
    $psi.EnvironmentVariables['CHATQ_WATCHER'] = '1'
    $psi.EnvironmentVariables.Remove('CHATQ_ALLPARTS')
    $p = [System.Diagnostics.Process]::Start($psi)
    if (-not $p.WaitForExit(120000)) { $p.Kill(); $null = $p.WaitForExit(10000) }
    $new = @(Get-ChildItem -LiteralPath $nsRpCap -File | Where-Object { $capWas -notcontains $_.Name } | Sort-Object Name)
    [pscustomobject]@{
        Exit = $p.ExitCode; Out = Read-ChatqJson $out; Text = Read-TestFile $out
        Kinds = (@($new | ForEach-Object { $_.Name -replace '-\d+\.json$', '' }) -join ',')
        Join = @($new | Where-Object { $_.Name -like 'join-*' } | ForEach-Object { Get-JoinPush (Read-ChatqJson $_.FullName).url })
    }
}
$nsRpHeld = Invoke-NsRealStep $nsRpRoot 1 'held' ([ordered]@{}) $null
$nsRpSoon = Invoke-NsRealStep $nsRpRoot 2 'soon' ([ordered]@{}) $null
$nsRpAlert = Invoke-NsRealStep $nsRpRoot 3 'alert' ([ordered]@{ event = 'failed'; text = $nsOpFail; priority = 2; jobId = $nsOpJob.id; loud = $false; quick = $false; noReply = $false; usageKind = $null }) "#$($nsOpJob.seq)"
$nsRpBad = @()
foreach ($c in @(@{ Name = 'held'; R = $nsRpHeld; Result = 'sent'; Is = $true }, @{ Name = 'soon'; R = $nsRpSoon; Result = 'soonAt'; Is = $null }, @{ Name = 'alert'; R = $nsRpAlert; Result = 'sent'; Is = $true })) {
    $r = $c.R
    if ($r.Exit -ne 0 -or -not $r.Out -or $r.Out.ok -ne $true) { $nsRpBad += "$($c.Name): exit $($r.Exit) $($r.Text)"; continue }
    $wb = @(Get-NsWBad $r.Out.w)
    if ($wb) { $nsRpBad += "$($c.Name): $($wb -join '; ')" }
    if ($r.Out.result.($c.Result) -ne $c.Is) { $nsRpBad += "$($c.Name): result $($r.Text)" }
    if ($r.Kinds -cne 'join,toast') { $nsRpBad += "$($c.Name): captured '$($r.Kinds)'" }
}
$nsRpSent = @($nsRpSoon.Out.w.caches.ChatqUsageSent)
if ($nsRpHeld.Join.Count -ne 1 -or $nsRpHeld.Join[0].Q['title'] -notlike '*summary' -or $nsRpHeld.Join[0].Q['text'] -notlike 'held in quiet hours: 1 done*a chat finished in the night*' -or
    (Test-Path -LiteralPath (Join-Path $nsRpData 'held.jsonl'))) { $nsRpBad += "held: push '$($nsRpHeld.Join.Q['title']): $($nsRpHeld.Join.Q['text'])'" }
if ($nsRpSoon.Join.Count -ne 1 -or $nsRpSoon.Join[0].Q['title'] -notlike '*usage' -or $nsRpSoon.Join[0].Q['text'] -notlike '* resets *1 queued*it goes then*' -or
    $nsRpSent.Count -ne 1 -or (ConvertFrom-ChatqStepText $nsRpSent[0].k) -notlike "s|$nsOpLane|*") { $nsRpBad += "soon: push '$($nsRpSoon.Join.Q['text'])', sent $($nsRpSent | ConvertTo-Json -Compress)" }
if ($nsRpAlert.Join.Count -ne 1 -or $nsRpAlert.Join[0].Q['text'] -notlike "*chatq error: helper step exited 1 with no answer*") { $nsRpBad += "alert: push '$($nsRpAlert.Join.Q['text'])'" }
Check 'held, soon and the failed alert as real steps under the harness''s seams: each ok, its w in the schema, its toast and its Join push captured, nothing sent' (
    -not $nsRpBad) ($nsRpBad -join ' || ')

# A loader that throws: the step exits 3, writing no Out
$nsBrRoot = Join-Path $sb 'native-step-broken'
Remove-Item -LiteralPath $nsBrRoot -Recurse -Force -EA SilentlyContinue
foreach ($d in (Join-Path $nsBrRoot 'src'), (Join-Path $nsBrRoot 'data\native')) { $null = New-Item -ItemType Directory -Path $d -Force }
Copy-Item -LiteralPath (Join-Path $sb 'tool\src\native-step.ps1') -Destination (Join-Path $nsBrRoot 'src') -Force
[System.IO.File]::WriteAllText((Join-Path $nsBrRoot 'Charlie-and-the-chat-factory.ps1'), "throw 'a part that will not load'`n", $utf8)
$nsBr = Invoke-NsRealStep $nsBrRoot 1 'stray' ([ordered]@{}) $null
Check 'a step whose loader throws exits 3 and writes no Out' ($nsBr.Exit -eq 3 -and $null -eq $nsBr.Text -and -not $nsBr.Kinds) "exit $($nsBr.Exit) / $($nsBr.Text)"

# --- parent death, in real steps (native/SPEC.md 3.6) -----------------------
# A pick as chatqd starts one, on a copy of the tool with data of its own,
# its lane allowed just now so no probe runs, and a fake CLI that sleeps:
# the step waits in Invoke-ChatqProcess's 5 s check. With a live pid whose
# start is 2 s off, as a reused pid's is, the step ends before its op: the
# job still queued, no CLI. With a parent of its own that exits once the run
# is in, it ends at the next check, with no Out and no carry, leaving what a
# killed watcher leaves: the job running behind a dead runnerPid and the CLI
# running on, until a repair step says interrupted. Never in the runner:
# ChatqStepParent stays unset here.
$nsPdRoot = Join-Path $sb 'native-step-parent-death'
$nsPdData = Join-Path $nsPdRoot 'data'
$nsPdRec = Join-Path $nsPdRoot 'fake'
Remove-Item -LiteralPath $nsPdRoot -Recurse -Force -EA SilentlyContinue
foreach ($d in (Join-Path $nsPdData 'native'), (Join-Path $nsPdData 'queue')) { $null = New-Item -ItemType Directory -Path $d -Force }
Copy-Item -LiteralPath (Join-Path $sb 'tool\Charlie-and-the-chat-factory.ps1') -Destination $nsPdRoot -Force
Copy-Item -LiteralPath (Join-Path $sb 'tool\src') -Destination $nsPdRoot -Recurse -Force
$nsPdJob = New-TestJob 'plugin' 'a pick whose chatqd goes'
foreach ($f in "$($nsPdJob.id).json", $nsPdJob.promptFile) { Copy-Item -LiteralPath (Join-Path $script:ChatqQueueDir $f) -Destination (Join-Path $nsPdData 'queue') -Force }
$nsPdLane = Get-ChatqLane $nsPdJob
$nsPdW = New-ChatqWatchState
$nsPdW.lastAllowed[$nsPdLane] = Get-Date
$nsPdW.lastAllowed["$nsPdLane|$(Get-ChatqRunModel $nsPdJob)"] = Get-Date
$nsPdW.startedAt = $nsSmStart.ToString('o')
$nsPdWJ = ConvertTo-NsStepW $nsPdW @{}
$null = Remove-ChatqJob (Find-ChatqJob $nsPdJob.id -Exact) 'test'
$nsPdFile = Join-Path $nsPdData "queue\$($nsPdJob.id).json"
$nsPdCarry = Join-Path $nsPdData 'native\carry.clixml'
# a pick step started, not waited for: In names -Watcher, as chatqd's does
function Start-NsPickStep([int]$N, [int]$Watcher, [int64]$Start) {
    $in = Join-Path $nsPdData "native\step-$N.in.json"
    $q = [ordered]@{ v = 1; op = 'pick'; watcherPid = $Watcher; startedAt = $nsPdWJ.startedAt; alertJob = "#$($nsPdJob.seq)"; w = $nsPdWJ; args = [ordered]@{ jobId = $nsPdJob.id } }
    [System.IO.File]::WriteAllText($in, ($q | ConvertTo-Json -Depth 12), $utf8)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $nsPs
    $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$(Join-Path $nsPdRoot 'src\native-step.ps1')`" -In `"$in`" -Out `"$(Join-Path $nsPdData "native\step-$N.out.json")`" -Watcher $Watcher -WatcherStart $Start -Seams `"$nsRpSeams`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['CHATQ_WATCHER'] = '1'
    $psi.EnvironmentVariables.Remove('CHATQ_ALLPARTS')
    $psi.EnvironmentVariables['FAKE_SLEEP'] = '60'
    $psi.EnvironmentVariables['FAKE_RECORD'] = $nsPdRec
    # the fake CLI reads its stdin to the end, even for the run's --version
    # call, and a hidden console's never ends: this one is closed at once
    $psi.RedirectStandardInput = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $p
}
$nsPdBad = @()
$nsPdFake = $null; $nsPdStep = $null; $nsPdCli = $null; $nsPdSecs = $null
try {
    $nsPdWas = Read-TestFile $nsPdFile
    $nsPdReused = Start-NsPickStep 1 $PID ($nsSmStart.Ticks + 20000000)
    if (-not $nsPdReused.WaitForExit(120000)) { $nsPdReused.Kill(); $nsPdBad += 'start 2 s off: the step ran on' }
    elseif ($nsPdReused.ExitCode -notin -1, 137) { $nsPdBad += "start 2 s off: exit $($nsPdReused.ExitCode)" }
    if ((Test-Path -LiteralPath (Join-Path $nsPdData 'native\step-1.out.json')) -or (Test-Path -LiteralPath $nsPdCarry) -or
        (Test-Path -LiteralPath $nsPdRec) -or (Read-TestFile $nsPdFile) -cne $nsPdWas) { $nsPdBad += 'start 2 s off: an Out, a carry, a CLI or the job written' }

    # chatqd's stand-in: a process of its own, ended once the run is in
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $nsPs
    $psi.Arguments = '-NoProfile -NonInteractive -Command Start-Sleep -Seconds 300'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $nsPdFake = [System.Diagnostics.Process]::Start($psi)
    $nsPdFakeId = $nsPdFake.Id
    $nsPdStep = Start-NsPickStep 2 $nsPdFakeId $nsPdFake.StartTime.ToUniversalTime().Ticks
    # in: the fake CLI says --resume (a --version call records too)
    $until = (Get-Date).AddSeconds(120)
    while (-not $nsPdCli -and -not $nsPdStep.HasExited -and (Get-Date) -lt $until) {
        try { if ((Read-TestFile (Join-Path $nsPdRec 'argv.txt')) -match '--resume') { $nsPdCli = [int]([regex]::Match((Read-TestFile (Join-Path $nsPdRec 'pid.txt')), '\d+').Value) } } catch {}
        if (-not $nsPdCli) { Start-Sleep -Milliseconds 250 }
    }
    if (-not $nsPdCli) { $nsPdBad += "parent gone: the run never went in (step $(if ($nsPdStep.HasExited) { "exited $($nsPdStep.ExitCode)" } else { 'running' }))" }
    else {
        $nsPdFake.Kill(); $null = $nsPdFake.WaitForExit(10000)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $nsPdGone = $nsPdStep.WaitForExit(30000)
        $nsPdSecs = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        if (-not $nsPdGone -or $nsPdSecs -gt 10) { $nsPdBad += "parent gone: the step still there after $nsPdSecs s" }
        elseif ($nsPdStep.ExitCode -notin -1, 137) { $nsPdBad += "parent gone: exit $($nsPdStep.ExitCode)" }
        if ((Test-Path -LiteralPath (Join-Path $nsPdData 'native\step-2.out.json')) -or (Test-Path -LiteralPath $nsPdCarry)) { $nsPdBad += 'parent gone: an Out or a carry' }
        $nsPdJ = Read-ChatqJson $nsPdFile
        if ($nsPdJ.state -ne 'running' -or [int]$nsPdJ.runnerPid -ne $nsPdFakeId -or (Get-Process -Id $nsPdFakeId -EA SilentlyContinue)) { $nsPdBad += "parent gone: job $($nsPdJ.state), runnerPid $($nsPdJ.runnerPid)" }
        if (-not (Get-Process -Id $nsPdCli -EA SilentlyContinue)) { $nsPdBad += 'parent gone: the CLI went with the step' }
    }
}
finally {
    foreach ($pp in $nsPdFake, $nsPdStep) { if ($pp -and -not $pp.HasExited) { $pp.Kill(); $null = $pp.WaitForExit(10000) } }
    # the orphaned CLI is this test's: its cmd.exe ends with it
    if ($nsPdCli) { Stop-Process -Id $nsPdCli -Force -EA SilentlyContinue }
}
# and the next watcher's repair, as a step under a live parent
$nsPdRep = Invoke-NsRealStep $nsPdRoot 3 'repair' ([ordered]@{}) $null
$nsPdJ = Read-ChatqJson $nsPdFile
if ($nsPdRep.Exit -ne 0 -or $nsPdRep.Out.ok -ne $true -or $nsPdJ.state -ne 'failed' -or $null -ne $nsPdJ.runnerPid -or
    $nsPdJ.result.reason -cne "interrupted - the watcher stopped mid-run; chatqrun $($nsPdJob.seq) sends it again") { $nsPdBad += "repair: exit $($nsPdRep.Exit), job $($nsPdJ.state) '$($nsPdJ.result.reason)'" }
Check 'parent death: a step whose parent''s start is off ends before its op; one whose parent exits mid-pick ends at the next check, no Out, the job running behind a dead runnerPid, the CLI left running, and a repair says interrupted' (
    -not $nsPdBad -and $null -eq $script:ChatqStepParent) "$($nsPdBad -join ' || ') (gone in $nsPdSecs s)"
Remove-Item -LiteralPath $nsPdRoot -Recurse -Force -EA SilentlyContinue
Remove-Item -LiteralPath $nsRpRoot, $nsBrRoot, $nsOpIn, $nsOpOut -Recurse -Force -EA SilentlyContinue
foreach ($c in $nsOpJob, $nsOpDone, $nsOpEnd) { $null = Remove-ChatqJob (Find-ChatqJob $c.id -Exact) 'test' }

# --- the handoff carry into PS (Restore-ChatqWatchState, native/SPEC.md 4.4) -
# chatqd handing over mid-life: handoff.json's watch state and caches, and
# the carry, taken whole in place of state.json's, each value its own type
# again. A file not chatqd's own, of another v, not JSON or that does not
# decode whole is ignored, for state.json's restore as before; both files
# are gone after either way. With no file, or no handoff in state.json,
# only state.json, as before, and a carry there left alone.
$nsHoState = Read-TestFile $script:ChatqStatePath
$nsHoFile = Get-ChatqNativeFile 'handoff.json'
$nsHoCarry = Get-ChatqNativeFile 'carry.clixml'
$nsHoCaWas = @{}
foreach ($n in $script:ChatqStepCaches.Keys) { $nsHoCaWas[$n] = (Get-Variable -Name $n -Scope Script).Value }
$nsHoCyWas = @{}
foreach ($n in $script:ChatqStepCarry) { $v = Get-Variable -Name $n -Scope Script -EA SilentlyContinue; if ($v) { $nsHoCyWas[$n] = @{ Value = $v.Value } } }
$nsHoNow = Get-Date
$nsHoAns = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
$nsHoAns['Which?'] = 'B'; $nsHoAns['which?'] = 'a'
# every native-owned field and every cache, none of them empty; an entry
# past its time too, which state.json's restore would drop
$nsHoW = New-ChatqWatchState
$nsHoW.blocked = @{ 'claude' = [pscustomobject]@{ Until = $nsHoNow.AddHours(2); Type = 'limit'; Source = 'job'; At = $nsHoNow.AddMinutes(-40) }
    'codex|C:\h' = @{ Until = $nsHoNow.AddMinutes(-5); Type = 'overloaded'; Source = 'probe' }
}
$nsHoW.outage = @{ 'codex' = @{ Since = $nsHoNow.AddMinutes(-30); Attempts = 3; Status = 'major_outage'; Alerted = $true; Reminded = $false; LastProbe = $nsHoNow.AddMinutes(-2); NextCheck = $nsHoNow.AddMinutes(3); AutoJob = 'j-7' } }
$nsHoW.lastAllowed = @{ 'claude' = $nsHoNow.AddMinutes(-7); '' = $nsHoNow }
$nsHoW.probeFails = @{ 'codex' = 2 }
$nsHoW.scannedAt = @{ 'claude' = $nsHoNow.AddMinutes(-3); 'codex|C:\h' = $nsHoNow.AddMinutes(-4) }
$nsHoW.authAlerted = @{ 'codex|C:\h' = $true }
$nsHoW.current = 'job-x'; $nsHoW.next = $nsHoNow.AddMinutes(9).ToUniversalTime().ToString('o'); $nsHoW.startedAt = $nsHoNow.ToUniversalTime().ToString('o')
$nsHoW.handoff = $true; $nsHoW.listening = $false
$nsHoCaches = @{
    ChatqReplyHandled = @{ 'm1' = $true }; ChatqReplySeen = @{ 'm2' = $true; '2026-10-18T03:00:00.0000000Z' = $true }; ChatqUsageSent = @{ 'five_hour|claude|1' = $true }
    ChatqAskSent = @{ 'r1' = @{ Rid = 'r1'; At = $nsHoNow.AddSeconds(-30); ToolUseId = 't1'; Answers = $nsHoAns; Transcript = 'C:\a.jsonl'; SessionId = 's1'; Title = 'a chat' } }
    ChatqReplyJunkLog = @{ 'x' = [pscustomobject]@{ At = $nsHoNow; Count = 4 } }
    ChatqReplyPolledAt = $nsHoNow.AddSeconds(-10); ChatqReplyErrAt = $nsHoNow.AddMinutes(-20); ChatqReplyBadIdAt = $nsHoNow.AddMinutes(-21)
    ChatqReplySavedAt = $nsHoNow.AddMinutes(-9); ChatqSummaryTriedAt = $nsHoNow.AddMinutes(-2)
}
$nsHoSaid = @{ 'job|handoff' = $true }
$nsHoCut = @{ 'C:\chats\h.jsonl' = @{ Sig = '9|8'; Row = [pscustomobject]@{ Id = 'h'; Cut = 1 } } }
# what state.json says: another lane, so which restore ran shows
$nsHoSt = New-ChatqWatchState
$nsHoSt.blocked['state-lane'] = [pscustomobject]@{ Until = $nsHoNow.AddHours(1); Type = 'five_hour'; Source = 'probe' }
$nsHoSt.authAlerted['state|x'] = $true
$nsHoBad = @()
try {
    foreach ($n in $script:ChatqStepCaches.Keys) { Set-Variable -Name $n -Scope Script -Value $nsHoCaches[$n] }
    $nsHoEnc = ConvertTo-ChatqStepW $nsHoW
    $nsHoBroken = ConvertTo-ChatqStepW $nsHoW
    $nsHoBroken.caches.ChatqUsageSent = 'not a list'
    $nsHoSt.handoff = $true
    Save-ChatqWatchState $nsHoSt
    $nsHoPid = (Get-ChatqState).pid
    # one case: state.json's handoff, then handoff.json as $Text (none
    # when $null) and a carry; the caches and the carried one marked, so
    # what was not taken shows
    $nsHoRun = {
        param($Text, [bool]$Handoff = $true)
        $nsHoSt.handoff = $Handoff
        Save-ChatqWatchState $nsHoSt
        Remove-Item -LiteralPath $nsHoFile, $nsHoCarry -Force -EA SilentlyContinue
        $script:ChatqAutoSaid = $nsHoSaid
        $cw = New-ChatqWatchState
        $cw.CutCache = $nsHoCut
        Export-ChatqStepCarry $cw
        $script:ChatqAutoSaid = 'not carried'
        foreach ($n in $script:ChatqStepCaches.Keys) { Set-Variable -Name $n -Scope Script -Value 'not taken' }
        if ($null -ne $Text) { [System.IO.File]::WriteAllText($nsHoFile, $Text, $utf8) }
        $w = New-ChatqWatchState
        $w.startedAt = 'its own'
        $ok = Restore-ChatqWatchState $w
        $c = @{}
        foreach ($n in $script:ChatqStepCaches.Keys) { $c[$n] = (Get-Variable -Name $n -Scope Script).Value }
        [pscustomobject]@{ Ok = $ok; W = $w; Caches = $c; Said = $script:ChatqAutoSaid; File = (Test-Path -LiteralPath $nsHoFile); Carry = (Test-Path -LiteralPath $nsHoCarry) }
    }
    $nsHoJson = { param($V, $WPid, $Wj) [ordered]@{ v = $V; watcherPid = $WPid; w = $Wj } | ConvertTo-Json -Depth 14 }
    $nsHoRef = & $nsHoRun $null
    $nsHoCold = & $nsHoRun (& $nsHoJson 1 $nsHoPid $nsHoEnc) $false
    $nsHoTaken = & $nsHoRun (& $nsHoJson 1 $nsHoPid $nsHoEnc)
    $nsHoNot = [ordered]@{
        'another pid'   = & $nsHoRun (& $nsHoJson 1 ($nsHoPid + 1) $nsHoEnc)
        'v 2'           = & $nsHoRun (& $nsHoJson 2 $nsHoPid $nsHoEnc)
        'not JSON'      = & $nsHoRun '{"v":1,"watcherPid":'
        'a w half good' = & $nsHoRun (& $nsHoJson 1 $nsHoPid $nsHoBroken)
    }
}
catch { $nsHoBad += "threw: $_" }
finally {
    foreach ($n in $script:ChatqStepCaches.Keys) { Set-Variable -Name $n -Scope Script -Value $nsHoCaWas[$n] }
    foreach ($n in $script:ChatqStepCarry) {
        if ($nsHoCyWas[$n]) { Set-Variable -Name $n -Scope Script -Value $nsHoCyWas[$n].Value } else { Remove-Variable -Name $n -Scope Script -EA SilentlyContinue }
    }
    Remove-Item -LiteralPath $nsHoFile, $nsHoCarry -Force -EA SilentlyContinue
    Restore-TestFile $script:ChatqStatePath $nsHoState
}
# the W a watcher keeps as its own, whatever it restores
$nsHoOwn = { param($R) $R.W.startedAt -ceq 'its own' -and $null -eq $R.W.current -and $null -eq $R.W.next -and $R.W.handoff -eq $false -and $R.W.listening -eq $false }
$nsHoSix = 'blocked', 'outage', 'lastAllowed', 'probeFails', 'scannedAt', 'authAlerted'
if (-not $nsHoBad) {
    # taken: the six fields, the ten caches and the carry, both files gone
    $t = $nsHoTaken
    if ($t.Ok -ne $true -or -not (& $nsHoOwn $t) -or $t.File -or $t.Carry) { $nsHoBad += "taken: ok $($t.Ok), own $(& $nsHoOwn $t), file $($t.File), carry $($t.Carry)" }
    $nsHoBad += @(foreach ($k in $nsHoSix) { Compare-NsSame $nsHoW[$k] $t.W[$k] "taken $k" })
    $nsHoBad += @(foreach ($n in $script:ChatqStepCaches.Keys) { Compare-NsSame $nsHoCaches[$n] $t.Caches[$n] "taken $n" })
    $nsHoBad += @(Compare-NsSame $nsHoSaid $t.Said 'taken ChatqAutoSaid') + @(Compare-NsSame $nsHoCut $t.W.CutCache 'taken CutCache')
    # no file: state.json's lane and alert, nothing else, the carry left
    $r = $nsHoRef
    $rb = $r.W.blocked['state-lane']
    if ($r.Ok -ne $true -or -not (& $nsHoOwn $r) -or $r.File -or -not $r.Carry -or $r.Said -cne 'not carried' -or $null -ne $r.W.CutCache -or
        (@($r.W.blocked.Keys) -join '|') -cne 'state-lane' -or $rb -isnot [System.Management.Automation.PSCustomObject] -or $rb.Type -cne 'five_hour' -or $rb.Source -cne 'probe' -or
        [math]::Abs(($rb.Until - $nsHoSt.blocked['state-lane'].Until).TotalSeconds) -ge 1 -or (@($r.W.authAlerted.Keys) -join '|') -cne 'state|x' -or $r.W.outage.Count -or
        $r.W.lastAllowed.Count -or $r.W.probeFails.Count -or $r.W.scannedAt.Count -or @($r.Caches.Values | Where-Object { $_ -cne 'not taken' }).Count) {
        $nsHoBad += "no file: ok $($r.Ok), blocked $(@($r.W.blocked.Keys) -join '|'), carry $($r.Carry) / $($r.Said)"
    }
    # not taken: as with no file, but both files gone
    foreach ($c in $nsHoNot.Keys) {
        $x = $nsHoNot[$c]
        if ($x.Ok -ne $true -or -not (& $nsHoOwn $x) -or $x.File -or $x.Carry -or $x.Said -cne 'not carried' -or $null -ne $x.W.CutCache -or
            @($x.Caches.Values | Where-Object { $_ -cne 'not taken' }).Count) { $nsHoBad += "$($c): ok $($x.Ok), file $($x.File), carry $($x.Carry), said $($x.Said)" }
        $nsHoBad += @(foreach ($k in $nsHoSix) { Compare-NsSame $r.W[$k] $x.W[$k] "$c $k" })
    }
    # no handoff in state.json: a cold start, the files not even looked at
    $x = $nsHoCold
    if ($x.Ok -ne $false -or -not $x.File -or -not $x.Carry -or $x.Said -cne 'not carried' -or
        @($nsHoSix | Where-Object { $x.W[$_].Count }).Count -or @($x.Caches.Values | Where-Object { $_ -cne 'not taken' }).Count) { $nsHoBad += "cold: ok $($x.Ok), file $($x.File), carry $($x.Carry)" }
}
Check 'a handoff from chatqd: handoff.json''s watch state and caches and the carry taken whole, each value its type again, then both files gone; one not its own, of another v, not JSON or half good ignored whole for state.json''s restore as before; no file, or a cold start, as before' (
    -not $nsHoBad) ($nsHoBad -join '; ')
