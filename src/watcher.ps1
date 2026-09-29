# VS-code-chat-manager, src/watcher.ps1: dot-sourced by VS-code-chat-manager.ps1
# in its turn, never on its own - see the list there.

#region the watcher -----------------------------------------------------------
# One per machine, a hidden PowerShell that loads this same file. It sleeps
# until a queued job's provider is free, checks with a probe, runs the job, and
# exits when nothing is left - unless a phone alert out there can still be
# answered, when it stays to poll for the reply (src/phone.ps1). Nothing is
# registered with the OS: loading the profile starts it again if jobs are
# pending or a reply is awaited, which covers a reboot.

function Get-ChatqLane {
    # What a limit or an overload applies to: the provider, and the account
    # when the job names its own config dir. Two accounts do not share a limit.
    param($Job)
    if ($Job.home) { return "$($Job.provider)|$($Job.home)" }
    return [string]$Job.provider
}

function Format-ChatqLane {
    param([string]$Lane)
    $p, $h = $Lane -split '\|', 2
    $name = (Get-Culture).TextInfo.ToTitleCase([string]$p)
    if ($h) { return "$name ($h)" }
    return $name
}

function New-ChatqWatchState {
    @{
        blocked = @{}; lastAllowed = @{}; probeFails = @{}; scannedAt = @{}; outage = @{}; authAlerted = @{}
        current = $null; next = $null; startedAt = $null; handoff = $false; listening = $false
    }
}

function Save-ChatqWatchState {
    param($W)
    $blocked = @{}
    foreach ($k in @($W.blocked.Keys)) {
        $b = $W.blocked[$k]
        if ($b) { $blocked[$k] = @{ until = $b.Until.ToUniversalTime().ToString('o'); type = $b.Type; source = $b.Source } }
        # when the lane was blocked: a soon alert needs the wait to have been long
        $ba = if ($b) { ConvertTo-ChatqDate (Get-ChatField $b 'At') } else { $null }
        if ($ba) { $blocked[$k]['at'] = $ba.ToUniversalTime().ToString('o') }
    }
    $outage = @{}
    foreach ($k in @($W.outage.Keys)) {
        $o = $W.outage[$k]
        if ($o) {
            $outage[$k] = @{
                since = $o.Since.ToUniversalTime().ToString('o'); next = $o.NextCheck.ToUniversalTime().ToString('o')
                lastProbe = $o.LastProbe.ToUniversalTime().ToString('o')
                status = $o.Status; attempts = $o.Attempts; alerted = [bool]$o.Alerted; reminded = [bool]$o.Reminded
            }
        }
    }
    $auth = @(foreach ($k in @($W.authAlerted.Keys)) { if ($W.authAlerted[$k]) { $k } })
    $s = [ordered]@{
        pid = $PID; version = $script:ChatVersion; startedAt = $W.startedAt; heartbeat = (Get-ChatqStamp)
        current = $W.current; next = $W.next; blocked = $blocked; outage = $outage; authAlerted = $auth
        # set by a watcher handing over to a newer copy of itself, so the one it
        # starts carries on from here instead of from nothing
        handoff = [bool]$W.handoff
        # only listening for phone replies, nothing to run: its limits view
        # goes stale, and Get-ChatqBlocks scans instead of trusting it
        listening = [bool]$W.listening
    }
    try { Save-ChatqJson $script:ChatqStatePath $s } catch {}
}

function Restore-ChatqWatchState {
    # What a watcher that handed over knew: which lanes are limited until when,
    # which are overloaded and since when, which alerts already went out. Only
    # after a handoff - a watcher starting cold asks again, as it always did.
    param($W)
    $s = Get-ChatqState
    if (-not $s.handoff) { return $false }
    if ($s.blocked) {
        foreach ($p in $s.blocked.PSObject.Properties) {
            $u = ConvertTo-ChatqDate $p.Value.until
            if ($u -and $u -gt (Get-Date)) { $W.blocked[$p.Name] = [pscustomobject]@{ Until = $u; Type = $p.Value.type; Source = $p.Value.source } }
            $ba = if ($W.blocked[$p.Name] -and $p.Value.PSObject.Properties['at']) { ConvertTo-ChatqDate $p.Value.at } else { $null }
            if ($ba) { $W.blocked[$p.Name] | Add-Member -NotePropertyName At -NotePropertyValue $ba -Force }
        }
    }
    if ($s.outage) {
        foreach ($p in $s.outage.PSObject.Properties) {
            $v = $p.Value
            $since = ConvertTo-ChatqDate $v.since
            if (-not $since) { continue }
            $next = ConvertTo-ChatqDate $v.next
            $last = ConvertTo-ChatqDate $v.lastProbe
            $W.outage[$p.Name] = @{
                Since = $since; Attempts = [int]$v.attempts; Status = $v.status
                Alerted = [bool]$v.alerted; Reminded = [bool]$v.reminded
                LastProbe = if ($last) { $last } else { $since }; NextCheck = if ($next) { $next } else { Get-Date }
            }
        }
    }
    foreach ($k in @($s.authAlerted)) { if ($k) { $W.authAlerted[[string]$k] = $true } }
    return $true
}

function Set-ChatqKeepAwake {
    # A limit resets 1-5 h out and a default power plan sleeps after 15-30
    # minutes of no input - without this, "unattended" fails in the ordinary
    # case. The display may still turn off; only system sleep is held off.
    param([bool]$On)
    if ($script:ChatqAwake -eq $On) { return }
    try {
        if ($script:ChatqIsWindows) {
            if (-not ('ChatqPower' -as [type])) {
                Add-Type -Name ChatqPower -Namespace '' -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);'
            }
            # ES_CONTINUOUS (0x80000000) | ES_SYSTEM_REQUIRED (0x1), or CONTINUOUS alone to let go
            $flags = if ($On) { [uint32]2147483649 } else { [uint32]2147483648 }
            [void][ChatqPower]::SetThreadExecutionState($flags)
        }
        elseif ($On) {
            # Both inhibitors end on their own when the watcher does, however it
            # dies: caffeinate -w watches the pid, and tail --pid exits with it.
            # A plain 'sleep infinity' would hold the machine awake for good
            # after a kill -9.
            $cmd = if ($script:ChatIsMac) { @('caffeinate', '-i', '-w', "$PID") }
            elseif (Get-Command systemd-inhibit -EA SilentlyContinue) {
                @('systemd-inhibit', '--what=sleep:idle', '--who=chatq', '--why=queued prompts', 'tail', "--pid=$PID", '-f', '/dev/null')
            }
            if ($cmd) { $script:ChatqAwakeProc = Start-Process -FilePath $cmd[0] -ArgumentList $cmd[1..($cmd.Count - 1)] -PassThru }
        }
        elseif ($script:ChatqAwakeProc) {
            try { $script:ChatqAwakeProc.Kill($true) } catch { try { $script:ChatqAwakeProc.Kill() } catch {} }
            $script:ChatqAwakeProc = $null
        }
        $script:ChatqAwake = $On
    }
    catch {}
}

function Write-ChatqWatchLog {
    param([string]$Text)
    try {
        New-ChatqDir $script:ChatqLogDir
        $p = Join-Path $script:ChatqLogDir 'watcher.log'
        if ((Test-Path -LiteralPath $p) -and (Get-Item -LiteralPath $p).Length -gt 1MB) {
            Move-Item -LiteralPath $p -Destination "$p.1" -Force
        }
        [System.IO.File]::AppendAllText($p, "$((Get-Date).ToString('o'))  $Text`n", (New-Object System.Text.UTF8Encoding $false))
        if ($script:ChatqForeground) { Write-Host "  $((Get-Date).ToString('HH:mm:ss'))  $Text" -ForegroundColor DarkGray }
    }
    catch {}
}

function Update-ChatqBlock {
    # re-read when a lane is free again - at most every 10 minutes while
    # waiting, since it means reading the tails of 30 transcripts
    param($W, $Job, [switch]$Force)
    $lane = Get-ChatqLane $Job
    $at = $W.scannedAt[$lane]
    if (-not $Force -and $at -and ((Get-Date) - $at).TotalMinutes -lt 10) { return }
    $b = if ($Job.provider -eq 'codex') { Get-ChatqCodexBlock $Job.home } else { Get-ChatqClaudeBlock $Job.home }
    # a record written before a probe that said "allowed" is history, not a
    # wall - the limit was lifted early, or extra usage carries the account
    $ok = $W.lastAllowed[$lane]
    if ($b -and $ok -and (-not $b.At -or $b.At -lt $ok)) { $b = $null }
    $cur = $W.blocked[$lane]
    if ($b -and (-not $cur -or $b.Until -gt $cur.Until)) { $W.blocked[$lane] = $b }
    $W.scannedAt[$lane] = Get-Date
}

function Enter-ChatqOutage {
    # A 529 Overloaded, or another 5xx: the server's trouble, not the account's.
    # Wait for status.claude.com to show Claude Code operational again, and try
    # again at once when it does; a blip the page never shows is retried after
    # 1, 2, 5, 10, then every 15 minutes.
    param($W, $Job, [string]$Why)
    $lane = Get-ChatqLane $Job
    $now = Get-Date
    $o = $W.outage[$lane]
    if (-not $o) {
        $o = @{ Since = $now; Attempts = 0; Status = $null; Alerted = $false; LastProbe = $now; NextCheck = $now }
        $W.outage[$lane] = $o
    }
    $o.Attempts++
    $o.LastProbe = $now
    $steps = @(1, 2, 5, 10, 15)
    $o.NextCheck = $now.AddMinutes($steps[[Math]::Min($o.Attempts, $steps.Count) - 1])
    if ($Job.provider -eq 'claude') { $o.Status = Get-ChatqClaudeStatus }
    $page = if ($o.Status) { " $($script:ChatqDot) status.claude.com: $($o.Status -replace '_', ' ')" } else { '' }
    Write-ChatqWatchLog "$lane overloaded ($Why)$page - next check $($o.NextCheck.ToString('HH:mm:ss'))"
    if (-not $o.Alerted) {
        $o.Alerted = $true
        [void](Send-ChatqAlert 'overloaded' "$($Job.title) $($script:ChatqDot) $Why$page $($script:ChatqDot) resumes when Claude is back" 0 -Job $Job)
    }
    Send-ChatqOutageReminder $o $Job
}

function Send-ChatqOutageReminder {
    # One more word after six hours: the first alert said "resumes by itself",
    # and an outage that long is worth knowing about while it is still going.
    param($O, $Job)
    if ($O.Reminded -or ((Get-Date) - $O.Since).TotalHours -lt 6) { return }
    $O.Reminded = $true
    $page = if ($O.Status) { " $($script:ChatqDot) status.claude.com: $($O.Status -replace '_', ' ')" } else { '' }
    [void](Send-ChatqAlert 'overloaded' "still overloaded after 6 h$page $($script:ChatqDot) $($Job.title) waits, checked every minute" 1 -Job $Job)
}

function Test-ChatqOutageOver {
    # Worth a probe yet? When status.claude.com shows Claude Code operational
    # again - checked every minute during an outage - or when 15 minutes went
    # by since the last try, in case the page lags behind the service.
    param($W, $Job)
    $lane = Get-ChatqLane $Job
    $o = $W.outage[$lane]
    if (-not $o) { return $true }
    $now = Get-Date
    if ($now -lt $o.NextCheck) { return $false }
    $s = if ($Job.provider -eq 'claude') { Get-ChatqClaudeStatus } else { $null }
    if ($s -ne $o.Status) { Write-ChatqWatchLog "status.claude.com: Claude Code $s" }
    $o.Status = $s
    Send-ChatqOutageReminder $o $Job
    if ($s -eq 'operational' -or ($now - $o.LastProbe).TotalMinutes -ge 15) { return $true }
    $o.NextCheck = $now.AddSeconds(60)
    return $false
}

function Confirm-ChatqAllowed {
    # A probe, unless one with this job's model and account said "allowed" in
    # the last three minutes. The model is part of the key: a weekly limit can
    # belong to one model, and a probe for another says nothing about it.
    param($W, $Job)
    $lane = Get-ChatqLane $Job
    $key = "$lane|$(Get-ChatqRunModel $Job)"
    $last = $W.lastAllowed[$key]
    if ($last -and ((Get-Date) - $last).TotalMinutes -lt 3 -and -not $W.outage[$lane]) { return $true }
    if ($W.outage[$lane] -and -not (Test-ChatqOutageOver $W $Job)) { return $false }
    $r = Invoke-ChatqProbe $Job.provider $Job
    if ($r.Allowed) {
        $W.lastAllowed[$key] = Get-Date
        $W.lastAllowed[$lane] = Get-Date
        # the limit it had, for the reset alert below
        $wasBlock = $W.blocked[$lane]
        $W.blocked[$lane] = $null
        $W.probeFails[$lane] = 0
        $W.authAlerted[$lane] = $false
        if ($W.outage[$lane]) {
            $since = $W.outage[$lane].Since
            $W.outage[$lane] = $null
            Write-ChatqWatchLog "$lane back after $([int]((Get-Date) - $since).TotalMinutes) min"
        }
        Write-ChatqWatchLog "$lane allowed"
        # a limit reset with prompts queued: said before the first one runs
        $null = Send-ChatqUsageReset $W $Job $wasBlock
        return $true
    }
    if ($r.Overloaded) { Enter-ChatqOutage $W $Job 'the probe got 529 Overloaded'; return $false }
    if ($r.Auth) { Block-ChatqLogin $W $Job $r.Error $r.Detail; return $false }
    if ($r.Limited) {
        $until = $r.Until
        if (-not $until) {
            $b = if ($Job.provider -eq 'codex') { Get-ChatqCodexBlock $Job.home } else { Get-ChatqClaudeBlock $Job.home }
            if ($b) { $until = $b.Until }
        }
        if (-not $until -or $until -le (Get-Date)) { $until = (Get-Date).AddMinutes(15) }
        $W.blocked[$lane] = [pscustomobject]@{ Until = $until; Type = $r.Type; Source = 'probe' }
        $W.blocked[$lane] | Add-Member -NotePropertyName At -NotePropertyValue (Get-Date) -Force
        $W.lastAllowed[$lane] = $null
        Write-ChatqWatchLog "$lane still limited until $($until.ToString('HH:mm'))"
        return $false
    }
    # network, login, a CLI that will not start: back off, and say so on the
    # third miss rather than the first - a laptop waking up has no network yet
    $n = [int]$W.probeFails[$lane] + 1
    $W.probeFails[$lane] = $n
    $W.blocked[$lane] = [pscustomobject]@{ Until = (Get-Date).AddMinutes(5 * [Math]::Min($n, 6)); Type = 'probe failed'; Source = $r.Error }
    Write-ChatqWatchLog "$lane probe failed ($n): $($r.Error)"
    if ($n -eq 3) { [void](Send-ChatqAlert 'failed' "can't reach $($Job.provider) to check the limit: $($r.Error)" 2 -Job $Job) }
    return $false
}

function Block-ChatqLogin {
    # A login that expired fails every job in that account the same way, so it
    # is the account that waits, not each job: one alert, the jobs stay queued,
    # and it is looked at again every 15 minutes until someone logs in. A
    # subscription that ran out is refused the same way, so the alert passes on
    # what the CLI said instead of guessing "logged out".
    param($W, $Job, [string]$Reason, [string]$Detail)
    $lane = Get-ChatqLane $Job
    $said = if ($Reason) { $Reason } else { 'login refused' }
    $W.blocked[$lane] = [pscustomobject]@{ Until = (Get-Date).AddMinutes(15); Type = 'login needed'; Source = $said }
    $W.lastAllowed[$lane] = $null
    Write-ChatqWatchLog "$lane $said"
    if ($Detail) { Write-ChatqWatchLog "$lane error text: $Detail" }
    if (-not $W.authAlerted[$lane]) {
        $W.authAlerted[$lane] = $true
        $how = if ($Job.provider -eq 'codex') { 'codex login' } else { 'claude, then /login' }
        [void](Send-ChatqAlert 'failed' "$(Format-ChatqLane $lane) $said $($script:ChatqDot) run $how, or check the subscription $($script:ChatqDot) queued prompts wait for it" 2 -Job $Job)
    }
}

function Repair-ChatqInterrupted {
    # A job left 'running' never finished: this watcher holds the lock, so no
    # other one can be running it - a live process at its old pid is one that
    # reused the number. Say so, and never send it again on its own: it may
    # have done half its work.
    foreach ($j in @(Get-ChatqJobs | Where-Object { $_.state -eq 'running' })) {
        if ($j.runnerPid -eq $PID) { continue }
        $cancel = Join-Path $script:ChatqQueueDir "$($j.id).cancel"
        if (Test-Path -LiteralPath $cancel) { Remove-Item -LiteralPath $cancel -Force -EA SilentlyContinue }
        if ($j.path -and (Test-ChatqPromptLanded $j.path ([string](Read-ChatqPrompt $j)) $j.startedAt $j.provider)) {
            Set-ChatqProp $j 'retryAs' 'continue'
        }
        Set-ChatqProp $j 'runnerPid' $null
        Set-ChatqProp $j 'result' ([pscustomobject]@{ kind = 'failed'; reason = "interrupted - the watcher stopped mid-run; chatqrun $($j.seq) sends it again" })
        Set-ChatqProp $j 'endedAt' (Get-ChatqStamp)
        Set-ChatqJobState $j 'failed' 'interrupted'
        [void](Send-ChatqAlert 'failed' "$($j.title) $($script:ChatqDot) interrupted mid-run" 2 -Job $j)
    }
    # and what such a run left for the phone's bridge (src/permit.ps1)
    Remove-ChatqPermitLeftovers
}

function Test-ChatqClaudeProcess {
    # Before chatq ends a process it believes is a chat's idle claude: is it
    # one? A registry file can outlive its process and the pid be reused.
    param($Process, $ProcStart)
    if (-not $Process -or $Process.ProcessName -notmatch '^(claude|node)') { return $false }
    # a FILETIME on Windows; macOS writes a date string, which says nothing
    # this comparison could use
    if ([string]$ProcStart -match '^\d{17,}$') {
        try {
            if ([Math]::Abs($Process.StartTime.ToFileTimeUtc() - [int64]$ProcStart) -gt 30000000) { return $false }
        }
        catch {}
    }
    return $true
}

function Complete-ChatqJob {
    # the one way a job leaves the queue for good
    param($Job, [string]$State, $Result, [string]$Why)
    Set-ChatqProp $Job 'result' $Result
    Set-ChatqProp $Job 'endedAt' (Get-ChatqStamp)
    Set-ChatqProp $Job 'runnerPid' $null
    Set-ChatqJobState $Job $State $Why
}

function Invoke-ChatqJob {
    param($W, $Job)
    $now = Get-Date
    # The file as it is now: seconds went by in the probe, and the job may have
    # been dropped or edited meanwhile - saving the old copy would undo that.
    $Job = Find-ChatqJob $Job.id -Exact
    if (-not $Job -or $Job.state -ne 'queued') { return }
    $lane = Get-ChatqLane $Job
    $sendsContinue = $Job.kind -eq 'continue' -or $Job.retryAs -eq 'continue'
    Update-ChatqNewChatPath $Job
    # a new chat not started yet: none of the chat checks below apply
    $fresh = Test-ChatqFreshChat $Job
    # the chat as it is now, not as it was when queued. A new chat whose
    # prompt landed and which is to be continued has had its transcript
    # deleted since: starting it afresh would make a chat that says only
    # "continue".
    if ($Job.provider -eq 'claude' -and (-not $fresh -or $sendsContinue)) {
        $meta = if ($fresh) { [pscustomobject]@{ Exists = $false } } else { Get-ChatqClaudeMeta $Job.path $Job.group }
        # a chat deleted or archived since auto-continue queued it: never
        # your job, so no failed alert - only the log says so
        if (-not $meta.Exists -and (Get-ChatField $Job 'auto')) {
            Complete-ChatqJob $Job 'skipped' ([pscustomobject]@{ kind = 'skipped'; reason = 'the chat is gone' }) 'chat gone'
            Write-ChatqWatchLog "#$($Job.seq) skipped: the chat is gone"
            return
        }
        if (-not $meta.Exists) {
            Complete-ChatqJob $Job 'failed' ([pscustomobject]@{ kind = 'failed'; reason = 'the chat is gone - its transcript was deleted' }) 'chat gone'
            [void](Send-ChatqAlert 'failed' "$($Job.title) $($script:ChatqDot) chat is gone" 2 -Job $Job)
            return
        }
        # A "continue" only makes sense into a chat still stopped where the
        # limit or the 529 left it. One that has moved on - you continued it,
        # or Claude's own auto-continue did - would redo finished work. A
        # requeue you asked for (chatqrun <n>) is sent regardless.
        $checkStop = $Job.kind -eq 'continue' -or ($Job.retryAs -eq 'continue' -and $Job.autoContinue)
        if ($checkStop -and $meta.LastTurn -and -not ($meta.LastTurn.Limit -or $meta.LastTurn.Overloaded)) {
            Complete-ChatqJob $Job 'skipped' ([pscustomobject]@{ kind = 'skipped'; reason = 'already continued - by you or by Claude''s own auto-continue' }) 'already continued'
            Write-ChatqWatchLog "#$($Job.seq) skipped: already continued"
            return
        }
    }
    if (-not $Job.cwd -or -not (Test-Path -LiteralPath $Job.cwd)) {
        Complete-ChatqJob $Job 'failed' ([pscustomobject]@{ kind = 'failed'; reason = "the chat's folder is gone: $($Job.cwd)" }) 'folder gone'
        [void](Send-ChatqAlert 'failed' "$($Job.title) $($script:ChatqDot) folder gone" 2 -Job $Job)
        return
    }

    # A window may be showing this chat fresh right now, on a request a run
    # or the chip wrote moments ago: this run going in meanwhile would leave
    # it a copy from part way through. Not a busy chat - no back-off, and
    # nothing counts towards giving up - just a wait until that is done.
    $hold = if ($Job.provider -eq 'claude' -and -not $fresh) { Get-ChatShowHold $Job.sessionId $now } else { $null }
    if ($hold) {
        Set-ChatqProp $Job 'deferUntil' $hold.ToUniversalTime().ToString('o')
        Save-ChatqJob $Job
        Write-ChatqWatchLog "#$($Job.seq) held back: a window is showing that chat"
        return
    }

    $live = if ($Job.provider -eq 'claude' -and -not $fresh) { @(Get-ChatqLiveSessions $Job.home) } else { @() }
    # auto-continue's own (src/auto-continue.ps1): a chat a terminal took
    # since is left to it, quietly; one open in a VS Code panel waits till
    # 5 minutes past the reset, for the panel's own auto-continue to go first
    if (Test-ChatqAutoTerminal $Job $live) {
        Complete-ChatqJob $Job 'skipped' ([pscustomobject]@{ kind = 'skipped'; reason = 'the chat is open in a terminal - left to it' }) 'in a terminal'
        Write-ChatqWatchLog "#$($Job.seq) skipped: the chat is open in a terminal"
        return
    }
    $autoHold = Get-ChatqAutoHold $Job $live $now
    if ($autoHold) {
        Set-ChatqProp $Job 'deferUntil' $autoHold.ToUniversalTime().ToString('o')
        Set-ChatqProp $Job 'deferWhy' 'vscode'
        Save-ChatqJob $Job
        Write-ChatqWatchLog "#$($Job.seq) held: auto-continue waits until $($autoHold.ToString('HH:mm')) - the chat is open in VS Code"
        return
    }
    $act = Resolve-ChatqLiveAction $Job $live
    # liveIdle stop: the idle process ends before the run, by the same checks
    # as everywhere else - and background work in flight in it waits, as a
    # busy chat does. A terminal's claude, or one that could not be checked,
    # is left, and the run goes ahead as with warn.
    $stop = $null
    if ($act.Action -eq 'stop') {
        $stop = Stop-ChatIdleProcess -SessionId $Job.sessionId -Transcript $Job.path -ConfigDir $Job.home -Live @($act.Live)
        if ($stop.OldProcess -eq 'held') { $act = @{ Action = 'defer'; Live = $act.Live } }
    }
    if ($act.Action -eq 'defer') {
        if (-not $Job.deferredSince) { Set-ChatqProp $Job 'deferredSince' (Get-ChatqStamp) }
        $since = ConvertTo-ChatqDate $Job.deferredSince
        $hours = ($now - $since).TotalHours
        if ($hours -ge 24) {
            Complete-ChatqJob $Job 'failed' ([pscustomobject]@{ kind = 'failed'; reason = 'the chat stayed busy for 24 h' }) 'busy 24h'
            [void](Send-ChatqAlert 'failed' "$($Job.title) $($script:ChatqDot) busy for 24 h, gave up" 2 -Job $Job)
            return
        }
        if ($hours -ge 2 -and -not $Job.busyAlerted) {
            Set-ChatqProp $Job 'busyAlerted' $true
            [void](Send-ChatqAlert 'waiting' "$($Job.title) $($script:ChatqDot) has been busy for 2 h - chatq waits until it is idle" 0 -Job $Job)
        }
        # sent "now" from the console: looked at again soon, not in 5 minutes
        $back = if ($Job.PSObject.Properties['sendNow'] -and $Job.sendNow) { 30 } else { 300 }
        Set-ChatqProp $Job 'deferUntil' $now.AddSeconds($back).ToUniversalTime().ToString('o')
        # busy now, not held for VS Code: the ETA says chat busy
        Set-ChatqProp $Job 'deferWhy' $null
        Save-ChatqJob $Job
        Write-ChatqWatchLog "#$($Job.seq) deferred: chat is in use"
        return
    }
    $stale = $false
    if ($act.Action -eq 'stop') {
        if (@($stop.Stopped).Count) { Write-ChatqWatchLog "#$($Job.seq) stopped idle chat process $(@($stop.Stopped) -join ',')" }
        if ($stop.OldProcess -in 'other', 'kept') {
            $stale = $true
            Write-ChatqWatchLog "#$($Job.seq) idle chat process left running ($($stop.OldProcess))"
        }
    }
    elseif ($act.Action -eq 'warn') { $stale = $true }
    # a window held the chat as the run began. After stop too: the side bar
    # keeps the chat's old view with its process gone (S29).
    $wasLive = $act.Action -in 'stop', 'warn'

    # A "continue" goes alone: the files went with the prompt the first time.
    $files = @()
    if ($sendsContinue) { $prompt = $script:ChatqContinueText }
    else {
        # an image pasted into the prompt since it was queued comes along
        # too. A prompt typed on the phone had every link in it defused as
        # it was written (New-ChatqJob -NoLinks), so only what someone at
        # the PC linked since counts.
        foreach ($x in @(Sync-ChatqAttachments $Job)) { Write-ChatqWatchLog "#$($Job.seq) could not take in $x - sent without it" }
        $prompt = Read-ChatqPrompt $Job
        $files = @(Get-ChatqAttachments $Job)
    }
    if (-not $prompt) {
        Complete-ChatqJob $Job 'failed' ([pscustomobject]@{ kind = 'failed'; reason = 'the prompt file is empty or gone' }) 'empty prompt'
        return
    }

    # once more, just before the prompt goes out: chatqrm during the checks above
    $again = Find-ChatqJob $Job.id -Exact
    if (-not $again -or $again.state -ne 'queued') { return }
    # a cancel left behind by an earlier, crashed run must not stop this one
    $cancel = Join-Path $script:ChatqQueueDir "$($Job.id).cancel"
    if (Test-Path -LiteralPath $cancel) { Remove-Item -LiteralPath $cancel -Force -EA SilentlyContinue }

    Set-ChatqProp $Job 'startedAt' (Get-ChatqStamp)
    Set-ChatqProp $Job 'attempts' ([int]$Job.attempts + 1)
    Set-ChatqProp $Job 'runnerPid' $PID
    Set-ChatqProp $Job 'deferUntil' $null
    Set-ChatqProp $Job 'deferredSince' $null
    Set-ChatqProp $Job 'retryAt' $null
    Set-ChatqJobState $Job 'running' ("attempt $($Job.attempts)")
    $W.current = $Job.id
    Save-ChatqWatchState $W
    Write-ChatqBoard
    Write-ChatqWatchLog "#$($Job.seq) running: $($Job.title)"

    # A prompt mid-run asks the phone, when that is on and can work
    # (src/permit.ps1); otherwise the run denies it as before.
    $permitRun = $null
    try { if ((Test-ChatqPermitReady $null $Job).Ok) { $permitRun = New-ChatqPermitRun $Job } }
    catch { Write-ChatqWatchLog "#$($Job.seq) permit: $($_.Exception.Message) - the run denies prompts as before" }
    $beat = @{ At = Get-Date; Poll = Get-Date; Every = 30 }
    $onTick = {
        if (((Get-Date) - $beat.At).TotalSeconds -ge 60) { $beat.At = Get-Date; Save-ChatqWatchState $W }
        # a request the bridge wrote goes to the phone first; while one is
        # open the reply topic is polled every 5 s, not every 30 (or 10)
        $asking = if ($permitRun) { Update-ChatqPermitRequests $Job $permitRun } else { $false }
        $every = if ($asking) { 5 } else { $beat.Every }
        # the phone mid-run, every 30 s and briefly: a "stop" for this very
        # run lands as the cancel file checked just below, a new prompt waits
        # in the queue for this run to end. Two messages a tick at most, and
        # their answers one short try each: the run's output is not read
        # while this goes on. Every 10 s for the 2 minutes after the phone
        # asked for its board (Get-ChatqReplyPollSeconds).
        if (((Get-Date) - $beat.Poll).TotalSeconds -ge $every) {
            $beat.Poll = Get-Date
            $null = Invoke-ChatqReplyPoll -TimeoutSec 5 -MinSeconds $every -MaxMessages 2 -Quick
            $beat.Every = Get-ChatqReplyPollSeconds -InRun
        }
        (Test-Path -LiteralPath $cancel) -or (Test-Path -LiteralPath $script:ChatqStopPath)
    }
    $onStart = {
        param($st)
        $m = if ($st.Mode) { $st.Mode } else { $Job.mode }
        $what = if ($prompt -eq $script:ChatqContinueText) { if (Get-ChatField $Job 'auto') { 'auto-continue' } else { 'continue' } } else { (Get-ChatqPromptStats $prompt).First }
        if ($what.Length -gt 80) { $what = $what.Substring(0, 80) + $script:ChatqEllipsis }
        [void](Send-ChatqAlert 'started' "$($Job.title) $($script:ChatqDot) $m $($script:ChatqDot) $what" 0 -Job $Job)
    }
    $runStart = Get-Date
    $out = Invoke-ChatqRun $Job $prompt $onTick $onStart -Files $files -Permit $permitRun
    $W.current = $null
    $wasCancelled = Test-Path -LiteralPath $cancel
    if ($wasCancelled) { Remove-Item -LiteralPath $cancel -Force -EA SilentlyContinue }
    Set-ChatqProp $Job 'runnerPid' $null
    # the bridge's folder and open requests, however the run ended - a run
    # that never started leaves them too (Close-ChatqPermitRun is safe twice)
    if ($permitRun -and (Test-Path -LiteralPath $permitRun.Dir)) { $null = Close-ChatqPermitRun $Job $permitRun }
    # The bridge never came up: that one prompt ended the run. Once more
    # without it, as after a dropped connection - as "continue" when the
    # prompt reached the chat - and this job never asks the phone again.
    if ($permitRun -and -not $wasCancelled -and (Get-ChatField $out 'permitFailed')) {
        Complete-ChatqPermitStartFailure $W $Job $out $prompt
        return
    }
    if ($permitRun) { Clear-ChatqPermitFailure }
    # A window that opened the chat while the run went on - a click in its
    # side bar, a Show it or the chip just before this run began - loaded it
    # part way through: as stale as one held from before, and treated so.
    if (-not $wasLive -and -not $wasCancelled -and $Job.provider -eq 'claude' -and -not $fresh -and $Job.sessionId) {
        $late = @(Get-ChatqLiveSessions $Job.home -RegistryOnly | Where-Object {
                [string]$_.SessionId -eq [string]$Job.sessionId -and (-not $_.Kind -or $_.Kind -eq 'interactive') -and
                (Get-ChatqEntryStart $_) -ge $runStart })
        if ($late) {
            $wasLive = $true
            $stale = $true
            Write-ChatqWatchLog "#$($Job.seq) a window opened the chat during the run"
        }
    }
    if ($stale) { Set-ChatqProp $out 'stale' $true }
    # the new chat's transcript, if this run made it where the slug did not say
    Update-ChatqNewChatPath $Job
    # The run stamped its records sdk-cli, which leaves a chat whose head
    # names no entrypoint out of Claude Code's lists - and out of every tab.
    # Listed again now, however the run ended (Repair-ChatListed).
    if ($Job.provider -eq 'claude' -and $Job.path -and $Job.sessionId) {
        $listed = Repair-ChatListed -Path $Job.path -SessionId $Job.sessionId -Live @(Get-ChatqLiveSessions $Job.home -RegistryOnly)
        if ($listed -eq 'relisted') { Write-ChatqWatchLog "#$($Job.seq) listed again: Claude Code had left the chat out of its lists" }
    }
    # The window still holding this chat shows none of the run until it
    # redraws. The extension in extension/ shows it fresh - Reload Webviews,
    # or a tab of its own - in that window only: the windows that held the
    # chat, else the job's folder, never this process's own. Not for a run
    # that goes back in the queue: it is not finished yet.
    # Judged here, as the run ends: the window shows it by itself only when
    # nobody is at the PC to be typing in it and no other chat in the folder
    # is working - otherwise it asks. "Working" reaches back quietMinutes
    # here, not one: a chat written that recently is someone's, at this PC or
    # driving it from the phone, which the idle clock never sees.
    # The chat's old process is ended here only when nobody is at the PC.
    # Then the window shows the run by itself, or whoever comes back to a
    # stale view finds their next message starting from disk. With someone
    # there it is left alone, because what a side bar does when the chat on
    # screen loses its process is unchecked (S30 item 5); Show it ends it.
    $shown = $null
    if ($wasLive -and -not $wasCancelled -and $out.kind -notin 'limited', 'overloaded') {
        $cfg = Get-ChatqConfig
        $recent = [int][Math]::Max(60, (Get-ChatqQuietMinutes $cfg) * 60)
        $shown = @(Show-ChatFresh -Via run -SessionId $Job.sessionId -Cwd $Job.cwd -Title $Job.title `
                -ConfigDir $Job.home -Transcript $Job.path -Seconds $recent -Away (Test-ChatqUserAway $cfg) -Auto:([bool](Get-ChatField $Job 'auto')))[-1]
        if ($shown -and $shown.OldProcess -eq 'ended') { Write-ChatqWatchLog "#$($Job.seq) ended the chat's idle process after the run" }
    }
    # A new chat is on disk now, and the chat list of a window on its folder
    # shows it only after a reload - the same offer, in words of its own. On
    # the first run that finishes rather than the first run: one the limit
    # cut goes back in the queue, and its continue is no longer fresh.
    elseif ($Job.kind -eq 'new' -and -not ($Job.PSObject.Properties['newOffered'] -and $Job.newOffered) -and -not $wasCancelled -and
        $out.kind -notin 'limited', 'overloaded', 'network', 'auth' -and $Job.path -and (Test-Path -LiteralPath $Job.path)) {
        Write-ChatReloadRequest -Title $Job.title -Cwd $Job.cwd -Kind 'new'
        Set-ChatqProp $Job 'newOffered' $true
    }

    $dur = ''
    $s0 = ConvertTo-ChatqDate $Job.startedAt
    if ($s0) { $dur = Get-ChatAge $s0; if ($dur -eq 'now') { $dur = '<1m' } }
    # what to do before typing in the chat, by what became of its old process
    $reload = ''
    if ($wasLive) {
        $old = if ($shown) { [string]$shown.OldProcess } else { $null }
        $reload = " $($script:ChatqDot) " + $(switch ($old) {
                { $_ -in 'ended', 'none' } { 'Show it in VS Code to see the run'; break }
                'live' { 'Show it in VS Code before typing in this chat'; break }
                'other' { 'it is open in a terminal too: type there, not in VS Code'; break }
                default { 'reload the VS Code window before typing in this chat' }
            })
    }
    # A limit, a 529, a dropped connection, a login gone: all go back in the
    # queue. A prompt that already reached the chat comes back as "continue",
    # never as itself a second time.
    if ($out.kind -in 'limited', 'overloaded', 'network', 'auth' -and -not $wasCancelled) {
        $landed = Test-ChatqPromptLanded $Job.path $prompt $Job.startedAt $Job.provider
        if ($landed -and $prompt -ne $script:ChatqContinueText) { Set-ChatqProp $Job 'retryAs' 'continue' }
        # Only a limit or a 529 leaves a record in the chat saying it was cut
        # off. After anything else "has the chat moved on?" would read that
        # missing record as yes, and drop the continue without sending it.
        if ($out.kind -in 'network', 'auth') { Set-ChatqProp $Job 'autoContinue' $false }
        elseif ($landed -and $prompt -ne $script:ChatqContinueText) { Set-ChatqProp $Job 'autoContinue' $true }
        Set-ChatqProp $Job 'result' $out
        # The cap counts runs that broke before a single reply. A long task that
        # gets through several limit windows moves on each time and never
        # meets it; one that keeps dying on the spot is going nowhere.
        $stuck = if ([int]$out.assistant -gt 0) { 0 } else { [int]$Job.noProgress + 1 }
        Set-ChatqProp $Job 'noProgress' $stuck
        $cap = Get-ChatqMaxRetries
        if ($stuck -ge $cap) {
            $why = "gave up: $stuck tries in a row got no reply ($($out.kind): $($out.reason))"
            Complete-ChatqJob $Job 'failed' ([pscustomobject]@{ kind = 'failed'; reason = $why }) 'gave up'
            # an auto-continue that failed the second time in a row: that is
            # what the alert says, and it is not tried again
            if (Step-ChatqAutoStreak $Job) { [void](Send-ChatqAlert 'failed' (Get-ChatqAutoStopText $Job) 2 -Job $Job) }
            else { [void](Send-ChatqAlert 'failed' "$($Job.title) $($script:ChatqDot) $why" 2 -Job $Job) }
            Write-ChatqWatchLog "#$($Job.seq) $why"
            Save-ChatqWatchState $W
            Write-ChatqBoard
            return
        }
    }
    elseif (-not $wasCancelled) { Set-ChatqProp $Job 'noProgress' 0 }
    if ($out.kind -ne 'network') { Set-ChatqProp $Job 'netRetries' 0 }
    switch ($out.kind) {
        'network' {
            if ($wasCancelled) { Complete-ChatqJob $Job 'failed' $out 'cancelled'; break }
            $k = [int]$Job.netRetries + 1
            Set-ChatqProp $Job 'netRetries' $k
            if ($k -gt 3) {
                $out.reason = "$($out.reason) - gave up after 3 retries"
                Complete-ChatqJob $Job 'failed' $out 'network'
                [void](Send-ChatqAlert 'failed' "$($Job.title) $($script:ChatqDot) $($out.reason)" 2 -Job $Job)
                Write-ChatqWatchLog "#$($Job.seq) $($out.reason)"
                break
            }
            # kept in the job, not in this process: a restart must not reset it
            $at = (Get-Date).AddMinutes(@(1, 2, 5)[$k - 1])
            Set-ChatqProp $Job 'retryAt' $at.ToUniversalTime().ToString('o')
            Set-ChatqJobState $Job 'queued' "network drop - retry $k/3 at $($at.ToString('HH:mm'))"
            Write-ChatqWatchLog "#$($Job.seq) $($out.reason) - retry $k/3 at $($at.ToString('HH:mm'))"
        }
        'auth' {
            if ($wasCancelled) { Complete-ChatqJob $Job 'failed' $out 'cancelled'; break }
            Block-ChatqLogin $W $Job $out.reason $out.detail
            Set-ChatqJobState $Job 'queued' 'waiting for the login to work again'
        }
        'overloaded' {
            if ($wasCancelled) { Complete-ChatqJob $Job 'failed' $out 'cancelled'; break }
            Set-ChatqJobState $Job 'queued' 'overloaded - waiting for status.claude.com'
            Enter-ChatqOutage $W $Job $out.reason
        }
        'limited' {
            if ($wasCancelled) { Complete-ChatqJob $Job 'failed' $out 'cancelled'; break }
            $until = ConvertTo-ChatqDate $out.resetsAt
            if (-not $until -and $Job.provider -eq 'claude') { $lt = Get-ChatqLastTurn $Job.path; if ($lt.ResetsAt) { $until = $lt.ResetsAt } }
            $W.lastAllowed[$lane] = $null
            if (-not $until) { Update-ChatqBlock $W $Job -Force; if ($W.blocked[$lane]) { $until = $W.blocked[$lane].Until } }
            if (-not $until -or $until -le (Get-Date)) { $until = (Get-Date).AddMinutes(15) }
            $W.blocked[$lane] = [pscustomobject]@{ Until = $until; Type = $out.limitType; Source = 'run' }
            $W.blocked[$lane] | Add-Member -NotePropertyName At -NotePropertyValue (Get-Date) -Force
            foreach ($k in @($W.lastAllowed.Keys)) { if ($k -like "$lane|*") { $W.lastAllowed[$k] = $null } }
            Set-ChatqJobState $Job 'queued' "limited mid-run, continues at $($until.ToString('HH:mm'))"
            if ($landed) { [void](Send-ChatqAlert 'limited' "$($Job.title) $($script:ChatqDot) hit the limit mid-run, continues at $($until.ToString('HH:mm'))" 0 -Job $Job) }
            Write-ChatqWatchLog "#$($Job.seq) limited until $($until.ToString('HH:mm'))"
        }
        'needs-input' {
            Complete-ChatqJob $Job 'needs-input' $out $out.reason
            $x = if ($out.excerpt) { " $($script:ChatqDot) `"$($out.excerpt)`"" } else { '' }
            [void](Send-ChatqAlert 'needs input' "$($Job.title) $($script:ChatqDot) $($out.reason)$x$reload" 2 -Job $Job)
            Write-ChatqWatchLog "#$($Job.seq) needs input: $($out.reason)"
        }
        'done' {
            Complete-ChatqJob $Job 'done' $out 'finished'
            $turns = if ($out.turns) { ", $($out.turns) turns" } else { '' }
            $ask = if ($out.asks) { 'asks: ' } else { '' }
            $x = if ($out.excerpt) { " $($script:ChatqDot) $ask`"$($out.excerpt)`"" } else { '' }
            # what the phone said no to, and the run went on without
            if (Get-ChatField $out 'youDenied') { $x = " $($script:ChatqDot) you denied $(@($out.youDenied) -join ', ')$x" }
            [void](Send-ChatqAlert 'done' "$($Job.title) $($script:ChatqDot) $dur$turns$x$reload" 1 -Job $Job)
            Write-ChatqWatchLog "#$($Job.seq) done"
        }
        default {
            if ($wasCancelled) { $out.reason = 'cancelled' }
            Complete-ChatqJob $Job 'failed' $out $out.reason
            if (-not $wasCancelled) { [void](Send-ChatqAlert 'failed' "$($Job.title) $($script:ChatqDot) $($out.reason)" 2 -Job $Job) }
            Write-ChatqWatchLog "#$($Job.seq) failed: $($out.reason)"
        }
    }
    # an auto-continue that finished starts its chat's streak over; one that
    # failed adds to it (a cancel is yours, and counts for nothing)
    if (-not $wasCancelled -and (Get-ChatField $Job 'auto') -and $Job.state -in 'done', 'failed') {
        if ((Step-ChatqAutoStreak $Job) -and $Job.state -eq 'failed') { [void](Send-ChatqAlert 'failed' (Get-ChatqAutoStopText $Job) 2 -Job $Job) }
    }
    Save-ChatqWatchState $W
    Write-ChatqBoard
}

function Wait-ChatqUntil {
    # wall-clock, in short steps: a machine that slept wakes up past the time
    # and goes straight on; a new job, chatqrun -Now or -Stop cut it short
    param([datetime]$When)
    $wake = if (Test-Path -LiteralPath $script:ChatqWakePath) { (Get-Item -LiteralPath $script:ChatqWakePath).LastWriteTimeUtc } else { $null }
    $end = [Math]::Min(30, [Math]::Max(1, ($When - (Get-Date)).TotalSeconds))
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt $end) {
        Start-Sleep -Seconds 2
        if (Test-Path -LiteralPath $script:ChatqStopPath) { return }
        $now = if (Test-Path -LiteralPath $script:ChatqWakePath) { (Get-Item -LiteralPath $script:ChatqWakePath).LastWriteTimeUtc } else { $null }
        if ($now -ne $wake) { return }
    }
}

function Get-ChatqDueTime {
    # when the watcher may next pick this job: the latest of its lane's limit
    # (a minute after the reset), its lane's next overload check, -At/-In, and
    # a busy chat's deferral. $null means now.
    param($W, $Job, [datetime]$Now)
    $lane = Get-ChatqLane $Job
    $times = @()
    $b = $W.blocked[$lane]
    if ($b -and $b.Until -gt $Now) { $times += $b.Until.AddSeconds(60) }
    $o = $W.outage[$lane]
    if ($o -and $o.NextCheck -gt $Now) { $times += $o.NextCheck }
    $nb = ConvertTo-ChatqDate $Job.notBefore
    if ($nb -and $nb -gt $Now) { $times += $nb }
    $du = ConvertTo-ChatqDate $Job.deferUntil
    if ($du -and $du -gt $Now) { $times += $du }
    $ra = ConvertTo-ChatqDate $Job.retryAt
    if ($ra -and $ra -gt $Now) { $times += $ra }
    return ($times | Sort-Object -Descending | Select-Object -First 1)
}

function Get-ChatqMaxRetries {
    # config maxRetries: how many runs in a row may break before any reply
    $n = 5
    $c = Get-ChatqConfig
    if ($c.PSObject.Properties['maxRetries'] -and [int]$c.maxRetries -ge 1) { $n = [int]$c.maxRetries }
    return $n
}

function Invoke-ChatqWatchLoop {
    param([switch]$Foreground)
    Set-StrictMode -Off
    $script:ChatqForeground = [bool]$Foreground
    New-ChatqDir $script:ChatqData
    # A few tries, not one: a watcher handing over to this one lets go of the
    # lock only as it exits, and a shell checking whether one is alive holds
    # it for an instant too. Either would otherwise leave nobody watching.
    $lock = $null
    for ($try = 1; $try -le 5 -and -not $lock; $try++) {
        $lock = try { [System.IO.File]::Open($script:ChatqLockPath, 'OpenOrCreate', 'ReadWrite', 'None') } catch { $null }
        if (-not $lock -and $try -lt 5) { Start-Sleep -Milliseconds 200 }
    }
    if (-not $lock) {
        if ($Foreground) { Write-Host '  a watcher is already running - chatqrun -Stop first' -ForegroundColor Yellow }
        return
    }
    $W = New-ChatqWatchState
    $W.startedAt = Get-ChatqStamp
    $restart = $false
    $emptied = $false
    try {
        Set-Content -LiteralPath $script:ChatqPidPath -Value $PID -Encoding ASCII
        if (Test-Path -LiteralPath $script:ChatqStopPath) { Remove-Item -LiteralPath $script:ChatqStopPath -Force }
        Write-ChatqWatchLog "watcher $PID started ($script:ChatVersion)"
        if (Restore-ChatqWatchState $W) { Write-ChatqWatchLog 'carrying on from the watcher before it' }
        Repair-ChatqInterrupted
        $wakeSeen = $null
        $replyWasOpen = $false
        $listening = $false
        $boardAt = [datetime]::MinValue
        $autoAt = [datetime]::MinValue
        $W.CutCache = @{}
        while ($true) {
            if (Test-Path -LiteralPath $script:ChatqStopPath) {
                Remove-Item -LiteralPath $script:ChatqStopPath -Force -EA SilentlyContinue
                Write-ChatqWatchLog 'stop requested'
                break
            }
            # chatinstall put a newer copy of this file in place. Between jobs,
            # never in the middle of one, and never in a console someone is
            # watching: hand over to a watcher running the new code.
            if (-not $Foreground -and (Test-Path -LiteralPath $script:ChatqRestartPath)) {
                Remove-Item -LiteralPath $script:ChatqRestartPath -Force -EA SilentlyContinue
                Write-ChatqWatchLog 'a newer copy was installed - handing over'
                $W.handoff = $true
                $restart = $true
                break
            }
            # chatqrun -Now: forget every wait - limits, overloads, busy chats -
            # and ask again
            if (Test-Path -LiteralPath $script:ChatqWakePath) {
                $wk = Get-Item -LiteralPath $script:ChatqWakePath
                if ($wk.LastWriteTimeUtc -ne $wakeSeen) {
                    $wakeSeen = $wk.LastWriteTimeUtc
                    $what = try { (Get-Content -LiteralPath $wk.FullName -Raw).Trim() } catch { '' }
                    # a -Now is a request of the moment: one left lying around
                    # must not cancel the wait of every watcher started later
                    $fresh = ((Get-Date).ToUniversalTime() - $wk.LastWriteTimeUtc).TotalMinutes -lt 5
                    if ($what -eq 'now' -and $fresh) {
                        Send-ChatqWake 'seen'
                        $W.blocked = @{}; $W.lastAllowed = @{}; $W.outage = @{}
                        foreach ($j in @(Get-ChatqJobs | Where-Object { $_.state -eq 'queued' })) {
                            $W.scannedAt[(Get-ChatqLane $j)] = Get-Date
                            if ($j.deferUntil) { Set-ChatqProp $j 'deferUntil' $null; Save-ChatqJob $j }
                        }
                        Write-ChatqWatchLog 'woken: -Now'
                    }
                }
            }
            # quiet hours over with alerts held: the summary, once a pass at
            # most - nothing but a look for a file when there is none
            if (Test-ChatqHeldWaiting) { $null = Send-ChatqHeldSummary }
            # Phone replies: while an alert that can be answered is out, look
            # at the reply topic - at most every 15 s, however often this
            # loop comes round. What a reply queues is picked up below.
            $replyOpen = Test-ChatqReplyOpen
            if ($replyWasOpen -and -not $replyOpen) { Write-ChatqWatchLog 'replies closed' }
            $replyWasOpen = $replyOpen
            # 15 s while an alert is out, 20 s listening all the time, 6 s just
            # after the phone asked for its board (Get-ChatqReplyPollSeconds)
            $pollEvery = if ($replyOpen) { Get-ChatqReplyPollSeconds } else { 15 }
            $polled = if ($replyOpen) { Invoke-ChatqReplyPoll -MinSeconds $pollEvery } else { 0 }
            # auto-continue's scan, every 5 minutes, for when no overlay runs
            # to do it (src/auto-continue.ps1); what it queues is picked below
            if (((Get-Date) - $autoAt).TotalMinutes -ge 5) { $autoAt = Get-Date; $null = Invoke-ChatqWatchAutoScan $W }
            $queued = @(Get-ChatqJobs | Where-Object { $_.state -eq 'queued' })
            if (-not $queued -and $replyOpen) {
                # Nothing to run, only listening: the machine may sleep - no
                # reply is worth keeping a laptop awake for, and the poll
                # simply resumes when it wakes - and the board and the state
                # are written on the way in and when a reply did something,
                # not every 15 s.
                if (-not $listening -or $polled) {
                    Set-ChatqKeepAwake $false
                    $W.current = $null; $W.next = $null
                    $W.listening = $true
                    Save-ChatqWatchState $W
                    Write-ChatqBoard
                }
                if (-not $listening) {
                    $listening = $true
                    Write-ChatqWatchLog "listening for phone replies $(Get-ChatqReplyListenText)"
                }
                if (-not $polled) { Wait-ChatqUntil (Get-Date).AddSeconds($pollEvery) }
                continue
            }
            $listening = $false
            $W.listening = $false
            if (-not $queued) {
                # Tidy up first and look once more last thing: a job queued
                # while this one is on its way out gets only a poke, and a
                # watcher that has stopped listening would leave it unwatched.
                Set-ChatqKeepAwake $false
                $W.current = $null; $W.next = $null
                Save-ChatqWatchState $W
                Write-ChatqBoard
                if (@(Get-ChatqJobs | Where-Object { $_.state -eq 'queued' })) { continue }
                # the same for an alert sent meanwhile by a shell, which saw
                # this watcher alive and so started none of its own
                if (Test-ChatqReplyOpen) { continue }
                Write-ChatqWatchLog 'queue empty'
                $emptied = $true
                break
            }
            $now = Get-Date
            $pick = $null
            $nextAt = $now.AddMinutes(15)
            foreach ($j in $queued) {
                Update-ChatqBlock $W $j
                $due = Get-ChatqDueTime $W $j $now
                if ($due) { if ($due -lt $nextAt) { $nextAt = $due }; continue }
                $pick = $j
                break
            }
            if ($pick) {
                Set-ChatqKeepAwake $true
                $script:ChatqAlertJob = "#$($pick.seq)"
                try {
                    if (Confirm-ChatqAllowed $W $pick) { Invoke-ChatqJob $W $pick }
                }
                catch {
                    # one job's failure must not end the watcher - the rest of
                    # the queue is still waiting on it
                    $msg = "$($_.Exception.Message) @ $(($_.ScriptStackTrace -split "`n")[0])"
                    Write-ChatqWatchLog "#$($pick.seq) error: $msg"
                    $W.current = $null
                    $j = Find-ChatqJob $pick.id -Exact
                    if ($j -and $j.state -in 'queued', 'running') {
                        try { Complete-ChatqJob $j 'failed' ([pscustomobject]@{ kind = 'failed'; reason = "chatq error: $($_.Exception.Message)" }) 'chatq error' } catch {}
                        [void](Send-ChatqAlert 'failed' "$($j.title) $($script:ChatqDot) chatq error: $($_.Exception.Message)" 2 -Job $j)
                    }
                }
                $script:ChatqAlertJob = $null
                Save-ChatqWatchState $W
                Write-ChatqBoard
                continue
            }
            # a reset coming with prompts queued: said soonMinutes before,
            # and the wait ends in time to say it
            $soonAt = Send-ChatqUsageSoon $W $queued
            if ($soonAt -and $soonAt -lt $nextAt) { $nextAt = $soonAt }
            # hold the machine awake only for a wait worth holding it for: a
            # weekly limit days out should not keep a laptop from sleeping
            Set-ChatqKeepAwake (($nextAt - $now).TotalHours -le 6)
            $W.next = $nextAt.ToUniversalTime().ToString('o')
            # listening shortens the wait to 15 s, which must not make the
            # board be rewritten twice as often as it was
            if (-not $replyOpen -or $polled -or ((Get-Date) - $boardAt).TotalSeconds -ge 30) {
                Save-ChatqWatchState $W
                Write-ChatqBoard
                $boardAt = Get-Date
            }
            $wakeAt = $nextAt
            if ($replyOpen -and $wakeAt -gt (Get-Date).AddSeconds($pollEvery)) { $wakeAt = (Get-Date).AddSeconds($pollEvery) }
            Wait-ChatqUntil $wakeAt
        }
    }
    finally {
        Set-ChatqKeepAwake $false
        try { Remove-Item -LiteralPath $script:ChatqPidPath -Force -EA SilentlyContinue } catch {}
        $W.current = $null; $W.next = $null; $W.listening = $false
        Save-ChatqWatchState $W
        $lock.Dispose()
        Write-ChatqWatchLog "watcher $PID stopped"
    }
    # Last of all, after the lock, the pid file and the state are settled: a
    # successor started any sooner would find its pid file deleted by this
    # one, or this one still holding the lock.
    if ($restart) { [void](Start-ChatqWatcherProcess) }
    # A shell that sent an answerable alert in the moment between the last
    # look at the window and the lock let go saw this watcher alive and
    # started none. It wrote the window first, so it is there to see now.
    # Never over a stop: chatqrun -Stop shuts the window before it writes
    # data/stop, and a watcher started now would delete that file unread.
    elseif ($emptied -and -not (Test-Path -LiteralPath $script:ChatqStopPath) -and (Test-ChatqReplyOpen)) {
        Write-ChatqWatchLog 'a phone alert went out as this watcher left - starting another to listen'
        [void](Start-ChatqWatcherProcess)
    }
}

function Send-ChatqWake {
    param([string]$What = 'poke')
    New-ChatqDir $script:ChatqData
    Set-Content -LiteralPath $script:ChatqWakePath -Value $What -Encoding ASCII
}

function Start-ChatqWatcher {
    # A hidden PowerShell of the same flavour, loading this same file. The
    # environment it needs is written into the command itself: a process
    # started this way does not have to share the calling shell's variables.
    # -Wake is what a running watcher is told: 'poke' (look again) or 'now'
    # (chatqrun -Now: stop waiting) - one write, so neither overwrites the other.
    param([string]$Wake = 'poke')
    if (Test-ChatqWatcherAlive) {
        Send-ChatqWake $Wake
        # it may have been on its way out - checked the queue, found nothing,
        # not yet let go of the lock. Give it a moment, then look again.
        Start-Sleep -Milliseconds 1500
        if (Test-ChatqWatcherAlive) { return $true }
    }
    elseif ($Wake -eq 'now') { Send-ChatqWake 'now' }
    if (-not (Start-ChatqWatcherProcess)) { return $false }
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 250
        if (Test-ChatqWatcherAlive) { return $true }
    }
    # an empty queue ends it at once, so not seeing it is not always a failure
    return (Test-ChatqWatcherAlive)
}

function Get-ChatqWatcherLaunch {
    <#
    How the watcher starts: @{ Exe; Args; Command }. The PowerShell this runs
    in, no profile, -ExecutionPolicy Bypass for that process alone: the setup
    window and the outbox's sender are Windows PowerShell 5.1, and for someone
    who only ever set a policy in pwsh 7, 5.1's is still Restricted - the
    dot-source below would fail, and no reply would be read. The policy goes
    again once the script has loaded, as the sender's does: -ExecutionPolicy
    lives on in the process's environment as PSExecutionPolicyPreference, and
    the jobs this watcher runs for hours, and your own alert command, run
    under your policy, not Bypass. A load that fails anyway lands in
    data/logs/watcher.log.
    #>
    param([string]$Path = $script:ChatqScriptPath)
    $q = { param($s) "'" + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent([string]$s) + "'" }
    $pre = '$env:CHATQ_WATCHER=''1''; '
    foreach ($n in 'CHATQ_CLAUDE', 'CHATQ_CODEX') {
        $v = [Environment]::GetEnvironmentVariable($n)
        if ($v) { $pre += "`$env:$n=$(& $q $v); " }
    }
    $log = Join-Path $script:ChatqLogDir 'watcher.log'
    $cmd = $pre + "try { . $(& $q $Path) } catch { try { [void][IO.Directory]::CreateDirectory($(& $q $script:ChatqLogDir)); " +
    "[IO.File]::AppendAllText($(& $q $log), (Get-Date).ToString('o') + '  the watcher did not load: ' + `$_.Exception.Message + [char]10) } catch {}; exit 1 }; " +
    "Remove-Item -LiteralPath 'env:PSExecutionPolicyPreference' -EA SilentlyContinue; Invoke-ChatqWatchLoop"
    $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmd))
    $argv = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc)
    return [pscustomobject]@{ Exe = (Get-Process -Id $PID).Path; Args = $argv; Command = $cmd }
}

function Start-ChatqWatcherProcess {
    # just the launch: Start-ChatqWatcher decides whether one is needed, and a
    # watcher handing over to a newer copy of itself calls this directly
    if ($script:ChatqSpawn) { return (& $script:ChatqSpawn) }   # tests: no real process
    $path = $script:ChatqScriptPath
    if (-not $path -or -not (Test-Path -LiteralPath $path)) {
        Write-Host '  cannot start the watcher: this shell does not know where VS-code-chat-manager.ps1 is' -ForegroundColor Yellow
        return $false
    }
    $l = Get-ChatqWatcherLaunch $path
    try {
        if ($script:ChatqIsWindows) {
            Start-Process -FilePath $l.Exe -WindowStyle Hidden -ArgumentList $l.Args | Out-Null
        }
        else {
            New-ChatqDir $script:ChatqLogDir
            Start-Process -FilePath 'nohup' -ArgumentList (@($l.Exe) + $l.Args) `
                -RedirectStandardOutput (Join-Path $script:ChatqLogDir 'watcher.out') `
                -RedirectStandardError (Join-Path $script:ChatqLogDir 'watcher.err') | Out-Null
        }
    }
    catch {
        Write-Host "  cannot start the watcher: $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
    return $true
}

#endregion
