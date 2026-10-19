# Charlie-and-the-chat-factory, src/watcher.ps1: dot-sourced by Charlie-and-the-chat-factory.ps1
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

function Format-ChatqProvider {
    # Claude or Codex, from a provider or a lane - the name an outage's words
    # give, so a Codex outage never says it waits for Claude
    param([string]$Lane)
    $p = ([string]$Lane -split '\|', 2)[0]
    if (-not $p) { $p = 'claude' }
    return (Get-Culture).TextInfo.ToTitleCase($p)
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
                autoJob = $o.AutoJob
            }
        }
    }
    $auth = @(foreach ($k in @($W.authAlerted.Keys)) { if ($W.authAlerted[$k]) { $k } })
    # a helper step of chatqd names chatqd, the watcher that holds the lock
    $wPid = if ($script:ChatqWatcherPid) { $script:ChatqWatcherPid } else { $PID }
    $wAt = if ($script:ChatqWatcherStartedAt) { $script:ChatqWatcherStartedAt } else { $W.startedAt }
    $s = [ordered]@{
        pid = $wPid; version = $script:ChatVersion; startedAt = $wAt; heartbeat = (Get-ChatqStamp)
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
    # chatqd handing over mid-life leaves its whole watch state, the shared
    # caches and the carry (native/SPEC.md 4.4): taken in place of what
    # state.json keeps when it is its own and decodes whole, else ignored,
    # and gone either way once looked at
    $hp = Get-ChatqNativeFile 'handoff.json'
    if ([System.IO.File]::Exists($hp)) {
        $h = Read-ChatqJson $hp
        $hPid = if ($h) { Get-ChatqNativeInt $h.watcherPid } else { $null }
        $d = $null
        if ($h -and (Get-ChatqNativeInt $h.v) -eq 1 -and $null -ne $hPid -and $hPid -eq (Get-ChatqNativeInt $s.pid)) {
            $d = try { ConvertFrom-ChatqStepW $h.w } catch { $null }
        }
        if ($d) {
            foreach ($k in 'blocked', 'lastAllowed', 'probeFails', 'scannedAt', 'outage', 'authAlerted') { $W[$k] = $d.W[$k] }
            foreach ($n in $script:ChatqStepCaches.Keys) { Set-Variable -Name $n -Scope Script -Value $d.Caches[$n] }
            Import-ChatqStepCarry $W
        }
        Remove-Item -LiteralPath $hp, (Get-ChatqNativeFile 'carry.clixml') -Force -EA SilentlyContinue
        if ($d) { return $true }
    }
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
                AutoJob = [string](Get-ChatField $v 'autoJob')
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
                Invoke-ChatCompile { Add-Type -Name ChatqPower -Namespace '' -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);' }
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
        Add-ChatqLogLine 'watcher.log' $Text
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
    # 1, 2, 5, 10, then every 15 minutes. Codex has no page read here, so its
    # outage is that backoff alone (Test-ChatqOutageOver).
    param($W, $Job, [string]$Why)
    $lane = Get-ChatqLane $Job
    $now = Get-Date
    $o = $W.outage[$lane]
    if (-not $o) {
        $o = @{ Since = $now; Attempts = 0; Status = $null; Alerted = $false; LastProbe = $now; NextCheck = $now }
        $W.outage[$lane] = $o
    }
    # a probe met the 529 itself: no longer only an auto job's guess
    # (Clear-ChatqAutoOutage)
    $o.AutoJob = $null
    $o.Attempts++
    $o.LastProbe = $now
    $steps = @(1, 2, 5, 10, 15)
    $o.NextCheck = $now.AddMinutes($steps[[Math]::Min($o.Attempts, $steps.Count) - 1])
    if ($Job.provider -eq 'claude') { $o.Status = Get-ChatqClaudeStatus }
    $page = if ($o.Status) { " $($script:ChatqDot) status.claude.com: $($o.Status -replace '_', ' ')" } else { '' }
    Write-ChatqWatchLog "$lane overloaded ($Why)$page - next check $($o.NextCheck.ToString('HH:mm:ss'))"
    if (-not $o.Alerted) {
        $o.Alerted = $true
        [void](Send-ChatqAlert 'overloaded' "$($Job.title) $($script:ChatqDot) $Why$page $($script:ChatqDot) resumes when $(Format-ChatqProvider $lane) is back" 0 -Job $Job)
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
    # Claude's page is read every minute; Codex is only tried, every 15 by now
    $how = if ($Job.provider -eq 'claude') { 'checked every minute' } else { 'tried again every 15 min' }
    [void](Send-ChatqAlert 'overloaded' "$(Format-ChatqProvider $Job.provider) still overloaded after 6 h$page $($script:ChatqDot) $($Job.title) waits, $how" 1 -Job $Job)
}

function Test-ChatqOutageOver {
    # Worth a probe yet? When status.claude.com shows Claude Code operational
    # again - checked every minute during an outage - or when 15 minutes went
    # by since the last try, in case the page lags behind the service. Codex
    # has no page read here: the backoff Enter-ChatqOutage set is its whole
    # wait, and a probe is due as soon as it is up. Read as Claude's, each
    # try waited the 15 minutes, never the 1, 2, 5 and 10 before them.
    param($W, $Job)
    $lane = Get-ChatqLane $Job
    $o = $W.outage[$lane]
    if (-not $o) { return $true }
    $now = Get-Date
    if ($now -lt $o.NextCheck) { return $false }
    if ($Job.provider -ne 'claude') {
        Send-ChatqOutageReminder $o $Job
        return $true
    }
    $s = Get-ChatqClaudeStatus
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
    # auto-continue's continue after a 529: waits as an outage the watcher
    # saw itself would (src/auto-continue.ps1) - and one such wait ends
    # once the job it was for no longer waits
    $null = Clear-ChatqAutoOutage $W $Job
    $null = Enter-ChatqAutoOutage $W $Job
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
    # what this job alone asks for cannot be handed to the CLI - a -Model
    # cmd.exe cannot carry (Get-ChatqCmdArgRefusal): the job fails with that
    # said, and the lane goes on to the next one, never blocked or backed
    # off as if the CLI were out of reach
    if ($r.Refused) {
        Write-ChatqWatchLog "#$($Job.seq) refused: $($r.Error)"
        if (Complete-ChatqJob $Job 'failed' ([pscustomobject]@{ kind = 'failed'; reason = $r.Error }) 'refused' -Existing) {
            [void](Send-ChatqAlert 'failed' "$($Job.title) $($script:ChatqDot) $($r.Error)" 2 -Job $Job)
        }
        return $false
    }
    if ($r.Overloaded) {
        $what = if ($Job.provider -eq 'claude') { 'the probe got 529 Overloaded' } else { "the probe found $(Format-ChatqProvider $lane) overloaded" }
        Enter-ChatqOutage $W $Job $what
        return $false
    }
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
        # a Codex answer that cost no turn says where it came from
        $from = if (Get-ChatField $r 'NoTurn') { " - $($r.Detail), no turn spent" } else { '' }
        Write-ChatqWatchLog "$lane still limited until $($until.ToString('HH:mm'))$from"
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
        if ($j.runnerPid -eq (Get-ChatqRunnerPid)) { continue }
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
        # the run-state it left still says it goes on: ended, so a window
        # takes back the tab its handover closed. Its handover's id kept as
        # it was: whether a window closed the tab died with the watcher, and
        # a 30 s hold on the chat's next run (Get-ChatShowHold) costs less
        # than a run going in while a window puts the tab back.
        $rs = Read-ChatRunState
        if ($rs -and [string](Get-ChatField $rs 'jobId') -eq [string]$j.id -and [string](Get-ChatField $rs 'phase') -ne 'ended') {
            $null = Write-ChatRunState $j 'ended' @{
                HostPids = [int[]]@(@(Get-ChatField $rs 'hostPids') | Where-Object { $_ }); OldProcess = [string](Get-ChatField $rs 'oldProcess')
                Away = Get-ChatqAwayAtEnd (Get-ChatField $rs 'away'); Beside = Get-ChatField $rs 'beside'; HandoverId = Get-ChatField $rs 'handoverId'
            }
        }
    }
    # and what such a run left for the phone's bridge (src/permit.ps1)
    Remove-ChatqPermitLeftovers
    # and the question hook's requests whose hook is gone (src/ask.ps1)
    try { Remove-ChatqAskLeftovers } catch {}
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
    # the one way a job leaves the queue for good. -Existing: not for a job
    # removed meanwhile (Set-ChatqJobState), and says whether it ended it
    param($Job, [string]$State, $Result, [string]$Why, [switch]$Existing)
    Set-ChatqProp $Job 'result' $Result
    Set-ChatqProp $Job 'endedAt' (Get-ChatqStamp)
    # its chat's transcript length then: what a phone reply finds written
    # after it is the chat going on since (Get-ChatqMovedOn)
    $endLen = $null
    $endPath = [string](Get-ChatField $Job 'path')
    if ($endPath) { try { $fi = [System.IO.FileInfo]::new($endPath); if ($fi.Exists) { $endLen = [int64]$fi.Length } } catch {} }
    Set-ChatqProp $Job 'endLen' $endLen
    Set-ChatqProp $Job 'runnerPid' $null
    if ($Existing) { return (Set-ChatqJobState $Job $State $Why -Existing) }
    Set-ChatqJobState $Job $State $Why
}

function Set-ChatqJobDeferred {
    <#
    A job put off because its chat is in use, looked at again in 5 minutes
    - 30 s when sent as Next from the console, a minute when it waits for you
    to leave its tab. -Act is Resolve-ChatqLiveAction's, or the handover's:
    Why is what it waits for - $null a busy chat, kept as busy, background
    (with Since and Note), in-use - and ShellOnly a wait on a background
    shell alone, which is bounded (20 minutes) and so never counts towards
    the 2 h alert or the 24 h give-up; the rest do. The job keeps what it
    waits for (deferWhy, deferSince, deferNote) for everything that shows
    its time (Format-ChatqDeferWhy), and its history says so whenever that
    changes - a background command ending into a turn of the chat's own
    too, which is why busy is a reason of its own and not the lack of one.
    A tab kept in use is looked at again less and less often - a minute,
    then 2, then 5 (deferTries, the same wait in a row). Returns $true when
    it gave up instead.
    #>
    param($Job, [hashtable]$Act, [datetime]$Now = (Get-Date))
    $why = if ($Act.Why) { [string]$Act.Why } else { 'busy' }
    # No reason kept yet - just queued, a start since, a hold of the
    # watcher's own - reads as busy: what the chat did before was not a wait
    # this one changes from, so a busy look says nothing new in the history
    # or jobs.log. Only a wait that had a reason of its own going busy does.
    $was = [string](Get-ChatField $Job 'deferWhy')
    if (-not $was) { $was = 'busy' }
    # the same wait as last time, counted; another one starts over
    $tries = if ([string]$why -eq $was) { [int](Get-ChatField $Job 'deferTries') + 1 } else { 1 }
    Set-ChatqProp $Job 'deferTries' $tries
    Set-ChatqProp $Job 'deferWhy' $why
    Set-ChatqProp $Job 'deferSince' $(if ($Act.Since) { ([datetime]$Act.Since).ToUniversalTime().ToString('o') } else { $null })
    Set-ChatqProp $Job 'deferNote' $(if ($Act.Note) { [string]$Act.Note } else { $null })
    $what = Format-ChatqDeferWhy $Job $Now
    $note = if ($Act.Note) { ": $($Act.Note)" } else { '' }
    if (-not $Act.ShellOnly) {
        if (-not $Job.deferredSince) { Set-ChatqProp $Job 'deferredSince' (Get-ChatqStamp) }
        $hours = ($Now - (ConvertTo-ChatqDate $Job.deferredSince)).TotalHours
        if ($hours -ge 24) {
            $r = switch ($why) {
                'background' { 'its background work ran for 24 h'; break }
                'in-use' { 'its tab stayed in use for 24 h'; break }
                default { 'the chat stayed busy for 24 h' }
            }
            $said = if ($why -ne 'busy') { "$r, gave up" } else { 'busy for 24 h, gave up' }
            if (Complete-ChatqJob $Job 'failed' ([pscustomobject]@{ kind = 'failed'; reason = $r }) 'busy 24h' -Existing) {
                [void](Send-ChatqAlert 'failed' "$($Job.title) $($script:ChatqDot) $said" 2 -Job $Job)
            }
            return $true
        }
        if ($hours -ge 2 -and -not $Job.busyAlerted) {
            Set-ChatqProp $Job 'busyAlerted' $true
            $said = if ($what) { "$what$note, for 2 h now - chatq goes on waiting" } else { 'has been busy for 2 h - chatq waits until it is idle' }
            [void](Send-ChatqAlert 'waiting' "$($Job.title) $($script:ChatqDot) $said" 0 -Job $Job)
        }
    }
    # sent as Next from the console: looked at again soon, not in 5 minutes.
    # A tab in use: each look is a start taken back and the window asked
    # again, so a tab someone stays in is asked less often.
    $back = if ($why -eq 'in-use') { @(60, 120, 300)[[Math]::Min($tries, 3) - 1] } elseif ($Job.PSObject.Properties['sendNow'] -and $Job.sendNow) { 30 } else { 300 }
    # a wait on shells alone ends at its bound, not up to 5 minutes past it
    if ($Act.ShellOnly -and $Act.Since) {
        $left = [int][Math]::Ceiling((([datetime]$Act.Since).AddMinutes($script:ChatqShellWaitMinutes) - $Now).TotalSeconds)
        if ($left -gt 0 -and $left -lt $back) { $back = [Math]::Max(5, $left) }
    }
    Set-ChatqProp $Job 'deferUntil' $Now.AddSeconds($back).ToUniversalTime().ToString('o')
    $text = if ($what) { "$what$note" } else { 'chat is in use' }
    # its history says what it waits for once, not every 5 minutes; a job
    # removed during the checks that led here is left gone
    $kept = if ($Job.state -ne 'queued' -or $why -ne $was) { Set-ChatqJobState $Job 'queued' $text -Existing } else { Save-ChatqJob $Job -Existing }
    if ($kept) { Write-ChatqWatchLog "#$($Job.seq) deferred: $text" }
    return $false
}

function Undo-ChatqJobStart {
    # A job set running whose run did not go in after all - its chat turned
    # out to be in use at the handover: as it was before it started, its
    # attempt not counted, and queued again as quietly as it was set running
    # (no history, no jobs.log line). What it waited for last is back too, so
    # Set-ChatqJobDeferred tells the same wait again from a new one.
    param($Job, [hashtable]$Was)
    Set-ChatqProp $Job 'state' 'queued'
    Set-ChatqProp $Job 'startedAt' $Was.StartedAt
    Set-ChatqProp $Job 'attempts' ([int]$Was.Attempts)
    Set-ChatqProp $Job 'deferredSince' $Was.DeferredSince
    Set-ChatqProp $Job 'deferWhy' $Was.DeferWhy
    Set-ChatqProp $Job 'deferSince' $Was.DeferSince
    Set-ChatqProp $Job 'deferNote' $Was.DeferNote
    Set-ChatqProp $Job 'deferTries' $Was.DeferTries
    Set-ChatqProp $Job 'runnerPid' $null
    # judged again at its next start
    Set-ChatqProp $Job 'ultracode' $null
    Set-ChatqProp $Job 'effort' $null
}

function Stop-ChatqCancelledStart {
    # A cancel written while the job stood running before its run went in -
    # during the handover's waits, or the liveIdle stop: Stop-ChatqJobRun
    # said cancelling, so the run never goes in, and the job ends as a
    # cancelled run does. Checked before any start is taken back: left
    # there, the next pick would take the file for a crashed run's and run
    # the job after all. $true when it was cancelled.
    param($W, $Job, [string]$Cancel, [hashtable]$Was)
    if (-not (Test-Path -LiteralPath $Cancel)) { return $false }
    Remove-Item -LiteralPath $Cancel -Force -EA SilentlyContinue
    $W.current = $null
    # The run never went in: its try is not counted and its start is the
    # one before, as for a start taken back (Undo-ChatqJobStart) - a
    # chatqrun <n> after it says attempt 1 if it is the first to go in,
    # and a job that never started keeps no start. A requeue's "did the
    # prompt land" then looks from the job's end, not its start
    # (Reset-ChatqJob): a prompt never sent is not in the chat after it,
    # whatever an earlier turn there says. It carried
    # nothing of the chat's either: the live view and the run-state must
    # not say Ultracode or a level. What it waited for is not put back - a
    # job that ended waits for nothing.
    if ($Was) {
        Set-ChatqProp $Job 'startedAt' $Was.StartedAt
        Set-ChatqProp $Job 'attempts' ([int]$Was.Attempts)
    }
    Set-ChatqProp $Job 'ultracode' $null
    Set-ChatqProp $Job 'effort' $null
    Complete-ChatqJob $Job 'failed' ([pscustomobject]@{ kind = 'failed'; reason = 'cancelled' }) 'cancelled'
    Write-ChatqWatchLog "#$($Job.seq) failed: cancelled"
    Save-ChatqWatchState $W
    Write-ChatqBoard
    return $true
}

function Test-ChatqHandoverOn {
    # config handover: on unless false. The tests turn it off everywhere but
    # their own section (ChatHandoverOff).
    param($Cfg)
    if ($script:ChatHandoverOff) { return $false }
    return ((Get-ChatField $Cfg 'handover') -ne $false)
}

# Deferred: DEFERRED.md "A `claude -p` that is not chatq's"
function Invoke-ChatqHandover {
    <#
    The run takes the tab's place. A VS Code window's tab shows the chat on
    an idle process of its own: a run going in beside it leaves that view
    stale, and whatever is typed there forks the chat. So the windows that
    hold it (-Run's HostPids) are asked, by data/run-state's phase handover
    (Write-ChatRunState), to close that tab and show the run's live view
    instead. The job is running already, so nothing opens the chat anew
    meanwhile. Each window answers in run-ack/<its pid>.json with that
    write's id:
      closing  the tab is closing: its processes of the chat are given 15 s
               from then to leave - Claude Code ends one about 7 s after
               its tab closes
      in-use   its tab is in front of someone, or the chat started a turn:
               nothing closed, and the run waits - never beside it
      unsure   the tab could not be told apart; off - watchRuns is off
    No answer in 3 s is a window with an extension that knows no handover.
    Every way but a clean close, the registry is read again and the chat
    judged again (Resolve-ChatqLiveAction): busy or waiting by now waits;
    idle runs beside it, Beside unsure - or timed-out, a close whose
    process stayed. Returns @{ Result (left, beside, in-use, defer); Beside;
    Act, the deferral; Live, the registry as read again; Closed, a window
    answered closing - so a tab is gone and is put back as the run ends }.
    #>
    param($Job, $Act, [hashtable]$Run)
    $sid = [string]$Job.sessionId
    $short = $sid.Substring(0, [Math]::Min(8, $sid.Length))
    $hosts = @($Run.HostPids | Where-Object { $_ })
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    # each window's own processes of the chat, by the extension host they
    # run under; all of them where that cannot be told
    $mine = @($Act.Live | Where-Object {
            $k = [string](Get-ChatField $_ 'Kind')
            [string](Get-ChatField $_ 'SessionId') -eq $sid -and (-not $k -or $k -eq 'interactive')
        })
    $byHost = @{}
    # each host's own process, for the note of a tab that closed
    $parOf = @{}
    foreach ($e in $mine) {
        $par = Get-ChatParentProcess $e $null
        $hp = if ($par) { [int](Get-ChatField $par 'Pid') } else { 0 }
        if ($hp -and -not $parOf.ContainsKey($hp)) { $parOf[$hp] = $par }
        if (-not $byHost.ContainsKey($hp)) { $byHost[$hp] = [System.Collections.Generic.List[int]]::new() }
        $byHost[$hp].Add([int](Get-ChatField $e 'Pid'))
    }
    # an answer from an earlier handover is no answer to this one
    foreach ($h in $hosts) { Remove-Item -LiteralPath (Join-Path $script:ChatRunAckDir "$h.json") -Force -EA SilentlyContinue }
    $t0 = Get-Date
    $Run.HandoverId = Write-ChatRunState $Job 'handover' $Run
    $answers = @{}
    while ($true) {
        foreach ($h in $hosts) {
            if ($answers.ContainsKey($h)) { continue }
            $a = Read-ChatRunAck $h
            if ($a -and [string](Get-ChatField $a 'id') -eq $Run.HandoverId -and (Get-ChatField $a 'answer')) {
                $answers[$h] = @{ Answer = [string]$a.answer; At = Get-Date }
            }
        }
        if ($answers.Count -ge $hosts.Count -or ((Get-Date) - $t0).TotalSeconds -ge $script:ChatHandoverAckSeconds) { break }
        Start-Sleep -Milliseconds $script:ChatHandoverPollMs
    }
    $said = @($hosts | ForEach-Object { "$_ $(if ($answers.ContainsKey($_)) { $answers[$_].Answer } else { 'no answer' })" }) -join ', '
    Write-ChatqWatchLog "handover ${short}: $said"
    # the windows closing their tab - each puts the chat back as the run ends
    $closing = @($hosts | Where-Object { $answers.ContainsKey($_) -and $answers[$_].Answer -eq 'closing' })
    $closed = [bool]$closing.Count
    # kept on the run as soon as it is known, not only in what this returns:
    # a throw from here on still ends the run holding the chat's next one
    # while the window puts the tab back (Invoke-ChatqJob's finally)
    if ($closed) { $Run.TabClosed = $true }
    if (@($answers.Values | Where-Object { $_.Answer -eq 'in-use' }).Count) {
        Write-ChatqWatchLog "handover ${short}: its tab is in use - the run waits"
        return @{ Result = 'in-use'; Act = @{ Action = 'defer'; Why = 'in-use' }; Closed = $closed }
    }
    # the tabs closing: their processes given the time to leave
    $timedOut = $false
    if ($closing.Count) {
        $pids = @($closing | ForEach-Object { if ($byHost.ContainsKey([int]$_)) { @($byHost[[int]$_]) } })
        if (-not $pids.Count) { $pids = @($mine | ForEach-Object { [int](Get-ChatField $_ 'Pid') }) }
        $last = @($closing | ForEach-Object { $answers[$_].At } | Sort-Object -Descending)[0]
        $until = $last.AddSeconds($script:ChatHandoverLeaveSeconds)
        while (($still = @(Get-ChatqStillThere $Job.home $sid $pids)).Count) {
            if ((Get-Date) -ge $until) { $timedOut = $true; break }
            Start-Sleep -Milliseconds $script:ChatHandoverPollMs
        }
        # Each window whose processes of the chat left with its tab, noted
        # as Show it notes one it ended (Add-ChatIdleEnded): its side bar may
        # still show the chat with nothing of it under it, and someone's own
        # claude -p into it after this run then holds that window's reload
        # (Get-ChatHostWork). Not a window whose process stayed: it holds
        # the chat itself.
        foreach ($h in $closing) {
            $own = if ($byHost.ContainsKey([int]$h)) { @($byHost[[int]$h]) } else { $pids }
            if (@($own | Where-Object { $_ -in $still }).Count) { continue }
            $par = $parOf[[int]$h]
            Add-ChatIdleEnded -SessionId $sid -HostPid ([int]$h) -HostStart $(if ($par) { Get-ChatField $par 'StartTime' } else { $null })
        }
        if (-not $timedOut -and $closing.Count -eq $hosts.Count) {
            Write-ChatqWatchLog "handover ${short}: tab closed after $(((Get-Date) - $t0).TotalSeconds.ToString('0.0', $inv)) s"
            return @{ Result = 'left'; Closed = $true }
        }
    }
    # not closed, or not by every window: judged again as it is now
    $live2 = @(Get-ChatqLiveSessions $Job.home -RegistryOnly)
    $act2 = Resolve-ChatqLiveAction $Job $live2
    if ($act2.Action -eq 'defer') {
        Write-ChatqWatchLog "handover ${short}: the chat is in use now - the run waits"
        return @{ Result = 'defer'; Act = $act2; Live = $live2; Closed = $closed }
    }
    if ($act2.Action -eq 'run') {
        Write-ChatqWatchLog "handover ${short}: nothing holds the chat now, after $(((Get-Date) - $t0).TotalSeconds.ToString('0.0', $inv)) s"
        return @{ Result = 'left'; Live = $live2; Closed = $closed }
    }
    $beside = if ($act2.Beside) { $act2.Beside } elseif ($timedOut) { 'timed-out' } else { 'unsure' }
    $how = if ($timedOut) { "still open after $($script:ChatHandoverLeaveSeconds) s" } else { 'its tab not closed' }
    Write-ChatqWatchLog "handover ${short}: $how - running beside it"
    return @{ Result = 'beside'; Beside = $beside; Live = $live2; Closed = $closed }
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
    $null = Update-ChatqHeldTitle $Job
    # a new chat not started yet: none of the chat checks below apply
    $fresh = Test-ChatqFreshChat $Job
    # the chat as it is now, not as it was when queued. A new chat whose
    # prompt landed and which is to be continued has had its transcript
    # deleted since: starting it afresh would make a chat that says only
    # "continue".
    if ($Job.provider -eq 'claude' -and (-not $fresh -or $sendsContinue)) {
        # Whether it is there and its last turn, nothing more: the mode and
        # model Get-ChatqClaudeMeta also reads walk back up to 64 MB of a
        # long chat, a 128 MB string at the worst, for nothing used here.
        $exists = -not $fresh -and $Job.path -and (Test-Path -LiteralPath $Job.path)
        $meta = [pscustomobject]@{ Exists = [bool]$exists; LastTurn = $(if ($exists) { Get-ChatqLastTurn $Job.path }) }
        # a chat deleted or archived since auto-continue queued it: never
        # your job, so no failed alert - only the log says so
        if (-not $meta.Exists -and (Get-ChatField $Job 'auto')) {
            if (Complete-ChatqJob $Job 'skipped' ([pscustomobject]@{ kind = 'skipped'; reason = 'the chat is gone' }) 'chat gone' -Existing) { Write-ChatqWatchLog "#$($Job.seq) skipped: the chat is gone" }
            return
        }
        if (-not $meta.Exists) {
            if (Complete-ChatqJob $Job 'failed' ([pscustomobject]@{ kind = 'failed'; reason = 'the chat is gone - its transcript was deleted' }) 'chat gone' -Existing) {
                [void](Send-ChatqAlert 'failed' "$($Job.title) $($script:ChatqDot) chat is gone" 2 -Job $Job)
            }
            return
        }
        # A "continue" only makes sense into a chat still stopped where the
        # limit or the 529 left it. One that has moved on - you continued it,
        # or Claude's own auto-continue did - would redo finished work. A
        # requeue you asked for (chatqrun <n>) is sent regardless.
        $checkStop = $Job.kind -eq 'continue' -or ($Job.retryAs -eq 'continue' -and $Job.autoContinue)
        if ($checkStop -and $meta.LastTurn -and -not ($meta.LastTurn.Limit -or $meta.LastTurn.Overloaded)) {
            if (Complete-ChatqJob $Job 'skipped' ([pscustomobject]@{ kind = 'skipped'; reason = 'already continued - by you or by Claude''s own auto-continue' }) 'already continued' -Existing) { Write-ChatqWatchLog "#$($Job.seq) skipped: already continued" }
            return
        }
        # The same for the continue of a chat a VS Code window's restart cut
        # off (Invoke-ChatqContinueChats): still where the restart left it -
        # its last message the one the cut-off is named by - or moved on,
        # and then not sent. Before its first try only: after that, the last
        # message is its own run's.
        $ru = [string](Get-ChatField $Job 'restartUuid')
        if ($ru -and [int]$Job.attempts -eq 0 -and $meta.LastTurn -and $meta.LastTurn.Uuid -and [string]$meta.LastTurn.Uuid -ne $ru) {
            if (Complete-ChatqJob $Job 'skipped' ([pscustomobject]@{ kind = 'skipped'; reason = 'already continued - the chat went on after the restart' }) 'already continued' -Existing) { Write-ChatqWatchLog "#$($Job.seq) skipped: already continued after the restart" }
            return
        }
    }
    if (-not $Job.cwd -or -not (Test-Path -LiteralPath $Job.cwd)) {
        if (Complete-ChatqJob $Job 'failed' ([pscustomobject]@{ kind = 'failed'; reason = "the chat's folder is gone: $($Job.cwd)" }) 'folder gone' -Existing) {
            [void](Send-ChatqAlert 'failed' "$($Job.title) $($script:ChatqDot) folder gone" 2 -Job $Job)
        }
        return
    }

    # A window may be showing this chat fresh right now, on a request a run
    # or the chip wrote moments ago: this run going in meanwhile would leave
    # it a copy from part way through. Not a busy chat - no back-off, and
    # nothing counts towards giving up - just a wait until that is done.
    $hold = if ($Job.provider -eq 'claude' -and -not $fresh) { Get-ChatShowHold $Job.sessionId $now } else { $null }
    if ($hold) {
        Set-ChatqProp $Job 'deferUntil' $hold.ToUniversalTime().ToString('o')
        # waits for the window now, not for what it waited for before
        foreach ($f in 'deferWhy', 'deferSince', 'deferNote', 'deferTries') { Set-ChatqProp $Job $f $null }
        if (Save-ChatqJob $Job -Existing) { Write-ChatqWatchLog "#$($Job.seq) held back: a window is showing that chat" }
        return
    }

    $live = if ($Job.provider -eq 'claude' -and -not $fresh) { @(Get-ChatqLiveSessions $Job.home) } else { @() }
    # auto-continue's own (src/auto-continue.ps1): a chat a terminal took
    # since is left to it, quietly; one open in a VS Code panel waits till
    # 5 minutes past the reset, for the panel's own auto-continue to go first
    if (Test-ChatqAutoTerminal $Job $live) {
        if (Complete-ChatqJob $Job 'skipped' ([pscustomobject]@{ kind = 'skipped'; reason = 'the chat is open in a terminal - left to it' }) 'in a terminal' -Existing) { Write-ChatqWatchLog "#$($Job.seq) skipped: the chat is open in a terminal" }
        return
    }
    $autoHold = Get-ChatqAutoHold $Job $live $now
    if ($autoHold) {
        Set-ChatqProp $Job 'deferUntil' $autoHold.ToUniversalTime().ToString('o')
        Set-ChatqProp $Job 'deferWhy' 'vscode'
        if (Save-ChatqJob $Job -Existing) { Write-ChatqWatchLog "#$($Job.seq) held: auto-continue waits until $($autoHold.ToString('HH:mm')) - the chat is open in VS Code" }
        return
    }
    $act = Resolve-ChatqLiveAction $Job $live
    # The chat's own process, judged and left alone for now: busy, or
    # background work in flight in it, waits as a busy chat does; a
    # terminal's claude is left, and the run goes ahead as with warn; a VS
    # Code window's idle one is the handover's once the job is running
    # (Invoke-ChatqHandover) - and liveIdle stop ends it only after that.
    $judge = $null
    if ($act.Action -in 'stop', 'warn') {
        $judge = Stop-ChatIdleProcess -SessionId $Job.sessionId -Transcript $Job.path -ConfigDir $Job.home -Live @($act.Live) -JudgeOnly
        if ($judge.OldProcess -eq 'held') { $act = @{ Action = 'defer'; Live = $act.Live } }
    }
    if ($act.Action -eq 'defer') {
        $null = Set-ChatqJobDeferred $Job $act $now
        return
    }
    # a window held the chat as the run began. After stop too: the side bar
    # keeps the chat's old view with its process gone (S29).
    $wasLive = $act.Action -in 'stop', 'warn'
    if ($act.Beside -eq 'background') {
        Write-ChatqWatchLog "#$($Job.seq) a background command has run in the chat for $($script:ChatqShellWaitMinutes) min - running beside it, its tab left open"
    }

    # once more, before the prompt is read: chatqrm, or the console's Remove,
    # during the checks above - its prompt and files went with it
    $again = Find-ChatqJob $Job.id -Exact
    if (-not $again -or $again.state -ne 'queued') { return }
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
        $null = Complete-ChatqJob $Job 'failed' ([pscustomobject]@{ kind = 'failed'; reason = 'the prompt file is empty or gone' }) 'empty prompt' -Existing
        return
    }
    # Ultracode and a session-only level as the chat last had them
    # (Get-ChatqRunCarry). It can read megabytes of the transcript, and a
    # chatqrm meanwhile must still stop the run: the save that sets it
    # running (below) makes no file for a job removed.
    $carry = Get-ChatqRunCarry $Job

    # a cancel left behind by an earlier, crashed run must not stop this one
    $cancel = Join-Path $script:ChatqQueueDir "$($Job.id).cancel"
    if (Test-Path -LiteralPath $cancel) { Remove-Item -LiteralPath $cancel -Force -EA SilentlyContinue }

    # what starting changes, for a start the handover takes back
    $was = @{ StartedAt = $Job.startedAt; Attempts = [int]$Job.attempts; DeferredSince = $Job.deferredSince
        DeferWhy = (Get-ChatField $Job 'deferWhy'); DeferSince = (Get-ChatField $Job 'deferSince')
        DeferNote = (Get-ChatField $Job 'deferNote'); DeferTries = (Get-ChatField $Job 'deferTries')
    }
    Set-ChatqProp $Job 'startedAt' (Get-ChatqStamp)
    Set-ChatqProp $Job 'attempts' ([int]$Job.attempts + 1)
    Set-ChatqProp $Job 'runnerPid' (Get-ChatqRunnerPid)
    Set-ChatqProp $Job 'deferUntil' $null
    Set-ChatqProp $Job 'deferredSince' $null
    Set-ChatqProp $Job 'retryAt' $null
    # what it waited for is over: never read as the reason of a later wait
    foreach ($f in 'deferWhy', 'deferSince', 'deferNote', 'deferTries') { Set-ChatqProp $Job $f $null }
    # the carry, kept on the job for this run, which the console, the
    # run-state and the history say (Format-ChatqRunCarry). Ultracode held
    # back for the run's mode is never claimed, and said so once it runs.
    Set-ChatqProp $Job 'ultracode' $(if ($carry.Ultracode) { $true } else { $null })
    Set-ChatqProp $Job 'effort' $(if ($carry.Effort) { [string]$carry.Effort } else { $null })
    $carrySay = Format-ChatqRunCarry $Job
    $ultraSay = if ($carrySay) { " - $carrySay, as the chat had $(if ($carry.Ultracode -and $carry.Effort) { 'them' } else { 'it' })" } else { '' }
    $held = [string](Get-ChatField $carry 'UltracodeHeld')
    $heldWhy = Format-ChatqUltracodeHeld $carry
    $heldSay = if ($held) { " - Ultracode left off ($heldWhy)" } else { '' }
    $beside = if ($act.Beside -eq 'background') { ' - beside a background command of the chat''s, left running' } else { '' }
    # Running from here on, before the handover: the chip, Show it and the
    # picker leave a chat alone that a job is running into, so nothing opens
    # it anew meanwhile - and whatever does is late (below). Quietly, for
    # now: a start the handover takes back leaves no trace - the history,
    # jobs.log, the board and watcher.log hear of it once the run goes in.
    # Removed in the last moment - while the carry was read, say: not run,
    # and not made again as running.
    Set-ChatqProp $Job 'state' 'running'
    if (-not (Save-ChatqJob $Job -Existing)) { Write-ChatqWatchLog "#$($Job.seq) removed as it was about to run - not sent"; return }
    $W.current = $Job.id
    $runStart = Get-Date
    # what data/run-state says of this run, the same in each of its writes -
    # but away, judged again for the 'ended' one (Get-ChatqAwayAtEnd)
    # TabClosed: a window closed the chat's tab for this run, and puts it
    # back at its end - set by Invoke-ChatqHandover the moment one answers
    $run = @{ HostPids = [int[]]@(); OldProcess = 'none'; Away = $null; Beside = $null; HandoverId = $null; TabClosed = $false }
    if ($judge) { $run.HostPids = [int[]]@($judge.HostPids | Where-Object { $_ }); $run.OldProcess = [string]$judge.OldProcess }
    $stale = $false
    try {
        $cfg = Get-ChatqConfig
        $run.Away = [bool](Test-ChatqUserAway $cfg)
        $left = $false
        $liveNow = @($act.Live)
        if ($wasLive -and $act.Beside -ne 'background' -and $judge.OldProcess -eq 'live' -and $run.HostPids.Count -and (Test-ChatqHandoverOn $cfg)) {
            $hand = Invoke-ChatqHandover $Job $act $run
            # cancelled while the windows were asked: ends here, whatever they said
            if (Stop-ChatqCancelledStart $W $Job $cancel $was) { return }
            if ($hand.Result -in 'in-use', 'defer') {
                # not run after all: back in the queue as it was, waiting as for
                # a busy chat - never beside a tab someone is in
                Undo-ChatqJobStart $Job $was
                $W.current = $null
                $null = Set-ChatqJobDeferred $Job $hand.Act (Get-Date)
                return
            }
            $left = $hand.Result -eq 'left'
            $run.Beside = $hand.Beside
            if ($null -ne $hand.Live) { $liveNow = @($hand.Live) }
        }
        elseif ($wasLive -and $run.HostPids.Count) { $run.Beside = if ($act.Beside) { $act.Beside } else { 'unsure' } }
        # liveIdle stop: only now, after the handover, and only what is still
        # there - never under a background command, which it would end with it.
        # A terminal's claude, or one that could not be checked, is left, and
        # the run goes ahead as with warn.
        if ($act.Action -eq 'stop' -and -not $left -and $act.Beside -ne 'background') {
            $stop = Stop-ChatIdleProcess -SessionId $Job.sessionId -Transcript $Job.path -ConfigDir $Job.home -Live $liveNow
            if (Stop-ChatqCancelledStart $W $Job $cancel $was) { return }
            if ($stop.OldProcess -eq 'held') {
                Undo-ChatqJobStart $Job $was
                $W.current = $null
                $null = Set-ChatqJobDeferred $Job @{ Action = 'defer' } (Get-Date)
                return
            }
            if (@($stop.Stopped).Count) { Write-ChatqWatchLog "#$($Job.seq) stopped idle chat process $(@($stop.Stopped) -join ',')" }
            if ($stop.OldProcess -in 'other', 'kept') {
                $stale = $true
                Write-ChatqWatchLog "#$($Job.seq) idle chat process left running ($($stop.OldProcess))"
            }
            elseif ($stop.OldProcess -in 'ended', 'none') { $run.Beside = $null }
        }
        elseif ($wasLive -and -not $left) { $stale = $true }
        # the last moment a cancel keeps the prompt out of the chat
        if (Stop-ChatqCancelledStart $W $Job $cancel $was) { return }
        # A view of the chat still open as the run goes in - a tab beside it,
        # the side bar's, a terminal's - takes whatever is typed there as a
        # second agent on the chat, working on the same files while this
        # one does. The started alert says so up front; the done alert says
        # how to come back. A handover that closed the tab leaves none.
        $keepOut = if (-not $wasLive -or $left) { '' }
        elseif ($run.OldProcess -eq 'other') { " $($script:ChatqDot) open in a terminal too: do not type there until done" }
        else { " $($script:ChatqDot) open in VS Code: do not type in it until done" }
        # the run goes in: said now, once
        Set-ChatqJobState $Job 'running' ("attempt $($Job.attempts)$ultraSay$heldSay$beside")
        Save-ChatqWatchState $W
        Write-ChatqBoard
        Write-ChatqWatchLog "#$($Job.seq) running: $($Job.title)$ultraSay"
        if ($held -and (Get-ChatField $carry 'HeldBy') -in 'deny', 'ask') { Write-ChatqWatchLog "#$($Job.seq) Ultracode left off: the chat had it, but $heldWhy, and no one can answer a run" }
        elseif ($held -eq 'plan') { Write-ChatqWatchLog "#$($Job.seq) Ultracode left off: the chat had it, but $heldWhy" }
        elseif ($held) { Write-ChatqWatchLog "#$($Job.seq) Ultracode left off: the chat had it, but $held mode would ask before each Workflow, and no one can answer a run" }
        elseif ((Get-ChatField $carry 'HeldBy') -eq 'allow') { Write-ChatqWatchLog "#$($Job.seq) Ultracode carried in $(Get-ChatqPermitMode $Job) mode: the $($carry.RuleIn) settings allow Workflow" }
        $null = Write-ChatRunState $Job 'running' $run

        # A prompt mid-run asks the phone, when that is on and can work
        # (src/permit.ps1); otherwise the run denies it as before.
        $permitRun = $null
        try { if ((Test-ChatqPermitReady $null $Job).Ok) { $permitRun = New-ChatqPermitRun $Job } }
        catch { Write-ChatqWatchLog "#$($Job.seq) permit: $($_.Exception.Message) - the run denies prompts as before" }
        $beat = @{ At = Get-Date; Poll = Get-Date; Every = 30 }
        # chatqrun -Stop (data/stop) ending the run: a cancel of yours, as
        # chatqcancel's is - noted as it ends the run, since a stop written
        # just after a run ended by itself stops nothing of it
        $byStop = @{ Hit = $false }
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
            # an answer from the phone to a chat's question: did it land (src/ask.ps1)
            if ($script:ChatqAskSent.Count) { $null = Test-ChatqAskLanded -Quick }
            if (Test-Path -LiteralPath $script:ChatqStopPath) { $byStop.Hit = $true }
            (Test-Path -LiteralPath $cancel) -or $byStop.Hit
        }
        $onStart = {
            param($st)
            $m = if ($st.Mode) { $st.Mode } else { $Job.mode }
            $what = if ($prompt -eq $script:ChatqContinueText) { if (Get-ChatField $Job 'auto') { 'auto-continue' } else { 'continue' } } else { (Get-ChatqPromptStats $prompt).First }
            if ($what.Length -gt 80) { $what = $what.Substring(0, 80) + $script:ChatqEllipsis }
            [void](Send-ChatqAlert 'started' "$($Job.title) $($script:ChatqDot) $m $($script:ChatqDot) $what$keepOut" 0 -Job $Job)
        }
        # the transcript's length as the run goes in: what it writes after is
        # its own, read as it ends for what it took of the carry
        $runLen = $null
        if ($carry.Ultracode -or $carry.Effort) { try { $runLen = [int64][System.IO.FileInfo]::new([string]$Job.path).Length } catch { $runLen = $null } }
        $out = Invoke-ChatqRun $Job $prompt $onTick $onStart -Files $files -Permit $permitRun -Carry $carry
        $W.current = $null
        $wasCancelled = (Test-Path -LiteralPath $cancel) -or $byStop.Hit
        if (Test-Path -LiteralPath $cancel) { Remove-Item -LiteralPath $cancel -Force -EA SilentlyContinue }
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
        # Not someone's own claude -p into it since: registered interactive
        # too (Claude Code 2.1.283), but stamped sdk-*, and no window.
        if (-not $wasLive -and -not $wasCancelled -and $Job.provider -eq 'claude' -and -not $fresh -and $Job.sessionId) {
            $late = @(Get-ChatqLiveSessions $Job.home -RegistryOnly | Where-Object {
                    [string]$_.SessionId -eq [string]$Job.sessionId -and (-not $_.Kind -or $_.Kind -eq 'interactive') -and
                    [string](Get-ChatField $_ 'Entrypoint') -cnotin $script:ChatSdkEntrypoints -and
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
        # a phone-made chat's neutral title gives way to Claude's own, so the
        # alert this run ends with names the chat as Claude does
        $null = Update-ChatqHeldTitle $Job
        # What the run was given is not what it took: Claude Code refuses
        # neither Ultracode nor a level, it only goes without - a model that
        # cannot do xhigh, workflows off, a level capped. Its own records say
        # (Get-ChatqRunTook): the job keeps what they say, and its history
        # entry as it ends says what differed (after the switch below).
        $tookSay = ''
        if ($null -ne $runLen -and -not $wasCancelled) {
            $tookSay = Confirm-ChatqRunCarry $Job (Get-ChatqRunTook ([string]$Job.path) $runLen)
            if ($tookSay) { Write-ChatqWatchLog "#$($Job.seq) $tookSay - the run's own records say so" }
        }
        $histAt = @($Job.history).Count
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
        # The chat's old process is never ended here, away or not: a tab still
        # showing the chat went dead under it. The window closes the tab first
        # and then ends what is left (its Show it). After a handover the process
        # is gone and the request names the windows it asked all the same, with
        # the job - so only the window that closed its tab acts on it.
        # A chatqrun -Stop, a cancel otherwise, still shows it: what the run
        # wrote before it stopped is in the chat all the same.
        $shown = $null
        if ($wasLive -and ($byStop.Hit -or -not $wasCancelled) -and $out.kind -notin 'limited', 'overloaded') {
            $cfg = Get-ChatqConfig
            $recent = [int][Math]::Max(60, (Get-ChatqQuietMinutes $cfg) * 60)
            $asked = if ($run.HandoverId) { [int[]]@($run.HostPids) } else { [int[]]@() }
            $shown = @(Show-ChatFresh -Via run -SessionId $Job.sessionId -Cwd $Job.cwd -Title $Job.title `
                    -ConfigDir $Job.home -Transcript $Job.path -Seconds $recent -Away (Test-ChatqUserAway $cfg) -Auto:([bool](Get-ChatField $Job 'auto')) `
                    -HandoverPids $asked -JobId ([string]$Job.id))[-1]
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
                # Codex has no status page read: it is tried again after 1, 2,
                # 5, 10, then every 15 minutes (Test-ChatqOutageOver)
                $wait = if ($Job.provider -eq 'claude') { 'waiting for status.claude.com' } else { "waiting for $(Format-ChatqProvider $lane) to be back" }
                Set-ChatqJobState $Job 'queued' "overloaded - $wait"
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
                # the 4 h deadline after the turn ended: what it still waited on was cut
                if (Get-ChatField $out 'note') { $x = " $($script:ChatqDot) $($out.note)$x" }
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
        # what the run took, on the entry its end wrote
        if ($tookSay -and @($Job.history).Count -gt $histAt) {
            $h = @($Job.history)[-1]
            $h.why = "$($h.why) - $tookSay"
            $null = Save-ChatqJob $Job -Existing
        }
        # an auto-continue that finished starts its chat's streak over; one that
        # failed adds to it (a cancel is yours, and counts for nothing)
        if (-not $wasCancelled -and (Get-ChatField $Job 'auto') -and $Job.state -in 'done', 'failed') {
            if ((Step-ChatqAutoStreak $Job) -and $Job.state -eq 'failed') { [void](Send-ChatqAlert 'failed' (Get-ChatqAutoStopText $Job) 2 -Job $Job) }
        }
        Save-ChatqWatchState $W
        Write-ChatqBoard
    }
    finally {
        # Over, however it went - done, back in the queue, cancelled, put
        # off at the handover, or thrown: the extension takes its tab back
        # from here. After the chat was listed again (Repair-ChatListed), so
        # a tab opened on this is never refused. A throw leaves the job
        # running for the watch loop to fail it: said as failed already.
        # Never a throw of its own from here, which would hide the run's.
        # Its handover's id only when a window closed the tab: that is what
        # holds the chat's next run the 30 s the window takes to put it back
        # (Get-ChatShowHold) - a tab in use, or one not told apart, closed
        # nothing, and nothing is put back. Away judged again for this write
        # (Get-ChatqAwayAtEnd); the run's own record is left as it started.
        try {
            $end = Find-ChatqJob $Job.id -Exact
            if (-not $end) { $end = $Job }
            if ($end.state -eq 'running') { Set-ChatqProp $end 'state' 'failed' }
            $endRun = $run.Clone()
            $endRun.Away = Get-ChatqAwayAtEnd $run.Away
            if (-not $run.TabClosed) { $endRun.HandoverId = $null }
            $null = Write-ChatRunState $end 'ended' $endRun
        }
        catch { Write-ChatqWatchLog "#$($Job.seq) run-state: $($_.Exception.Message)" }
    }
}

function Get-ChatqAwayAtEnd {
    # Away as a run ends, for its 'ended' run-state: the window that closed
    # the chat's tab for it opens the chat again on its own only while
    # nobody is at the PC, and asks (Open chat) while someone is - so it is
    # judged now, not kept from the start. A prompt queued for the night
    # starts with you away and may end with you back at work. Never throws:
    # the start's judgement stands if this one cannot be made.
    param($AtStart)
    try { return [bool](Test-ChatqUserAway (Get-ChatqConfig)) } catch { return $AtStart }
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

function Test-ChatqJobFound {
    # Whether the job's own id finds it in $All, the whole queue, as
    # Invoke-ChatqJob looks for it before it runs. Not when a second job
    # file holds the same id - a copy made by hand - or the id is blank or
    # finds another job: the run would find nothing and return, and the
    # loop pick the same job again at once, every pass with no wait.
    param($Job, $All)
    $f = Find-ChatqJob ([string]$Job.id) -Exact -Jobs $All
    return [bool]($f -and [string]$f.id -eq [string]$Job.id)
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

function Invoke-ChatqPick {
    # the job the watch loop picked: allowed, then run. The loop sets
    # ChatqAlertJob around it and saves the state and the board after.
    param($W, $Job)
    try {
        if (Confirm-ChatqAllowed $W $Job) { Invoke-ChatqJob $W $Job }
    }
    catch {
        # one job's failure must not end the watcher - the rest of
        # the queue is still waiting on it
        $msg = "$($_.Exception.Message) @ $(($_.ScriptStackTrace -split "`n")[0])"
        Write-ChatqWatchLog "#$($Job.seq) error: $msg"
        $W.current = $null
        $j = Find-ChatqJob $Job.id -Exact
        if ($j -and $j.state -in 'queued', 'running') {
            try { Complete-ChatqJob $j 'failed' ([pscustomobject]@{ kind = 'failed'; reason = "chatq error: $($_.Exception.Message)" }) 'chatq error' } catch {}
            [void](Send-ChatqAlert 'failed' "$($j.title) $($script:ChatqDot) chatq error: $($_.Exception.Message)" 2 -Job $j)
        }
    }
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
        $strayAt = [datetime]::MinValue
        # the ids a job not found by its own id has been named under
        $lostSaid = New-Object 'System.Collections.Generic.HashSet[string]'
        # kept when chatqd's handoff carried one in
        if ($null -eq $W.CutCache) { $W.CutCache = @{} }
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
                            if ($j.deferUntil) { Set-ChatqProp $j 'deferUntil' $null; $null = Save-ChatqJob $j -Existing }
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
            # an answer from the phone to a chat's question: did it land (src/ask.ps1)
            if ($script:ChatqAskSent.Count) { $null = Test-ChatqAskLanded }
            # auto-continue's scan, every 5 minutes, for when no overlay runs
            # to do it (src/auto-continue.ps1); what it queues is picked below
            if (((Get-Date) - $autoAt).TotalMinutes -ge 5) { $autoAt = Get-Date; $null = Invoke-ChatqWatchAutoScan $W }
            # images pasted into a prompt tab that was then cancelled, a day
            # old and linked from no prompt: at the start, then every 6 hours
            # (Clear-ChatqStrayFiles)
            if (((Get-Date) - $strayAt).TotalHours -ge 6) {
                $strayAt = Get-Date
                $swept = @(try { Clear-ChatqStrayFiles } catch { })
                if ($swept.Count) { Write-ChatqWatchLog "removed $($swept.Count) stray file(s) and folder(s) from data/queue" }
            }
            $all = @(Get-ChatqJobs)
            $queued = @($all | Where-Object { $_.state -eq 'queued' })
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
                # A job its own id does not find is passed over, as a job
                # file that does not read is: left queued and unwritten - a
                # write by id could land in its twin's file - and named in
                # watcher.log the first time its id is met
                if (-not (Test-ChatqJobFound $j $all)) {
                    if ($lostSaid.Add([string]$j.id)) {
                        Write-ChatqWatchLog "$(@(Get-ChatqJobFiles ([string]$j.id)) -join ', '): the id '$($j.id)' does not find one job - left queued, not run, until that is put right"
                    }
                    continue
                }
                Update-ChatqBlock $W $j
                $due = Get-ChatqDueTime $W $j $now
                if ($due) { if ($due -lt $nextAt) { $nextAt = $due }; continue }
                $pick = $j
                break
            }
            if ($pick) {
                Set-ChatqKeepAwake $true
                $script:ChatqAlertJob = "#$($pick.seq)"
                Invoke-ChatqPick $W $pick
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
    -Native the chatqd to start instead (Get-ChatqWatcherEngine): the same
    root, script and PowerShell, which it uses for every PowerShell it
    starts, and this shell's culture, which it renders times in for life as
    a PowerShell watcher does (native/SPEC.md 2.11, 4.1). Command is $null.
    #>
    param([string]$Path = $script:ChatqScriptPath, [string]$Native)
    if ($Native) {
        $ci = [System.Globalization.CultureInfo]::CurrentCulture
        $cj = [ordered]@{ name = $ci.Name; timeSep = $ci.DateTimeFormat.TimeSeparator; groupSep = $ci.NumberFormat.NumberGroupSeparator
            groupSizes = @($ci.NumberFormat.NumberGroupSizes) } | ConvertTo-Json -Compress
        $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($cj)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        $argv = @('watch', '--root', $script:ChatRoot, '--script', $Path, '--ps', (Get-Process -Id $PID).Path, '--culture', $b64)
        return [pscustomobject]@{ Exe = $Native; Args = $argv; Command = $null; Engine = 'native' }
    }
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
    return [pscustomobject]@{ Exe = (Get-Process -Id $PID).Path; Args = $argv; Command = $cmd; Engine = 'ps' }
}

function Start-ChatqWatcherProcess {
    # just the launch: Start-ChatqWatcher decides whether one is needed, and a
    # watcher handing over to a newer copy of itself calls this directly.
    # Which watcher is Get-ChatqWatcherEngine's to say; a native one that
    # will not start is a strike, and this launch the PowerShell one.
    $path = $script:ChatqScriptPath
    if (-not $script:ChatqSpawn -and (-not $path -or -not (Test-Path -LiteralPath $path))) {
        Write-Host '  cannot start the watcher: this shell does not know where Charlie-and-the-chat-factory.ps1 is' -ForegroundColor Yellow
        return $false
    }
    $eng = Get-ChatqWatcherEngine $path
    if ($eng.Engine -eq 'native') {
        $started = Start-ChatqNativeProcess (Get-ChatqWatcherLaunch $path -Native $eng.Exe) $eng.Version
        if ($null -ne $started) { return $started }
    }
    $l = Get-ChatqWatcherLaunch $path
    if ($script:ChatqSpawn) { return (& $script:ChatqSpawn $l) }   # tests: no real process
    # in your home folder, never the caller's: the watcher runs on for hours
    # after the shell that started it, and Windows will not delete or rename a
    # folder a process is in. Escaped, as Start-Process reads the folder as a
    # wildcard; -EA Stop, or a folder it cannot use is an error the catch never
    # sees, and $true goes back for a watcher that never started
    $wd = [WildcardPattern]::Escape($HOME)
    try {
        if ($script:ChatqIsWindows) {
            Start-Process -FilePath $l.Exe -WindowStyle Hidden -ArgumentList $l.Args -WorkingDirectory $wd -EA Stop | Out-Null
        }
        else {
            New-ChatqDir $script:ChatqLogDir
            Start-Process -FilePath 'nohup' -ArgumentList (@($l.Exe) + $l.Args) -WorkingDirectory $wd -EA Stop `
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

#region the native watcher's launch ------------------------------------------
# chatqd, the native watcher (native/SPEC.md), runs wherever its binary is:
# R/bin/<version>/<target>/, which only a developer's build fills until it
# ships, or CHATQ_CHATQD. The decision, its records in data/native/ and the
# fuse are held equal to native/crates/chatq-core/src/launch.rs by the cases
# in native/vectors/launch.json (tests/sections/native.ps1). With no binary -
# every user today - a launch costs a look for data/native and one for
# bin/ more than it did, and reads and writes nothing.

# the bin/ folder's name, not the compiled triple: both slices of the Mac's
# universal binary say universal-apple-darwin. None on Linux, which keeps
# the PowerShell watcher.
$script:ChatqNativeTarget = if ($script:ChatqIsWindows) { 'x86_64-pc-windows-msvc' } elseif ($script:ChatIsMac) { 'universal-apple-darwin' } else { $null }

function Get-ChatqNativeFile {
    # data/native/<Name>: pending.json, last.json, verified.json, fuse.json
    param([string]$Name)
    Join-Path (Join-Path $script:ChatqData 'native') $Name
}

# Deferred: DEFERRED.md "A relative CHATQ_CHATQD"
function Get-ChatqNativePath {
    # Only ever bin/<Version>/, the scripts' version on disk, so new scripts
    # never start an old binary. None when the shell does not know its
    # folder (iex). CHATQ_CHATQD made absolute against the process's folder,
    # not PowerShell's location, as launch.rs's std::path::absolute does:
    # else a relative one would be two binaries to the two launchers.
    param([string]$Version = $script:ChatVersion)
    if ($env:CHATQ_CHATQD) {
        try { return [System.IO.Path]::GetFullPath([System.IO.Path]::Combine([Environment]::CurrentDirectory, $env:CHATQ_CHATQD)) }
        catch { return $env:CHATQ_CHATQD }
    }
    if (-not $script:ChatRoot -or -not $script:ChatqNativeTarget) { return $null }
    $exe = if ($script:ChatqIsWindows) { 'chatqd.exe' } else { 'chatqd' }
    return [System.IO.Path]::Combine([string]$script:ChatRoot, 'bin', $Version, $script:ChatqNativeTarget, $exe)
}

function Get-ChatqLoaderVersion {
    # The version of the scripts a launch starts: the loader on disk, read
    # as extension/setup.js readVersion and launch.rs read_loader_version
    # read it (latin1, the first line that begins with it, after CR or LF).
    # Not this process's $script:ChatVersion, which a shell or a watcher
    # loaded before an update and keeps: its restart would pick the old
    # bin/ folder, or none, for the new scripts. $null when it cannot be read.
    param([string]$Path)
    if (-not $Path) { return $null }
    try { $t = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::GetEncoding(28591)) }
    catch { return $null }
    $m = [regex]::Match($t, '(?<![^\r\n])\$script:ChatVersion = ''(\d+\.\d+\.\d+)''')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Get-ChatqNativeInt {
    # a JSON integer as launch.rs reads one, else $null: a pid or a size
    # written as text, or as 1.0, is none
    param($Value)
    if (($Value -is [int] -or $Value -is [long]) -and $Value -ge 0) { return [long]$Value }
    return $null
}

function ConvertTo-ChatqNativeStamp {
    # a stamp as it was written: pwsh 7's ConvertFrom-Json makes it a
    # [datetime], which [string] would give back in this culture's words
    param($Value)
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('o') }
    return [string]$Value
}

function Test-ChatqNativeAlive {
    # a live process at that pid; with -Chatqd, one that is a chatqd, by its
    # name, so a pid reused by something else is never taken for one
    param($ProcessId, [switch]$Chatqd)
    $p = try { Get-Process -Id ([int]$ProcessId) -EA Stop } catch { $null }
    if (-not $p) { return $false }
    return (-not $Chatqd -or $p.ProcessName -eq 'chatqd')
}

function Test-ChatqNativeWanted {
    # CHATQ_ENGINE for one launch and what it starts, else config's watcher;
    # only ps says no. watcher: "ps" is set by hand - no command sets it
    $e = ([string]$env:CHATQ_ENGINE).Trim()
    if ($e) { return ($e -ne 'ps') }
    $c = Get-ChatqConfig
    $w = if ($c.PSObject.Properties['watcher']) { ([string]$c.watcher).Trim() } else { '' }
    return ($w -ne 'ps')
}

function Get-ChatqNativeFuse {
    # fuse.json's strikes and alert flag for this version. Another version's
    # record counts for nothing: a new version starts clean.
    param([string]$Version = $script:ChatVersion)
    $f = Read-ChatqJson (Get-ChatqNativeFile 'fuse.json')
    if ($f -and [string]$f.version -ceq $Version) {
        return [pscustomobject]@{ Strikes = @($f.strikes | Where-Object { $null -ne $_ }); Alerted = [bool]$f.alerted }
    }
    return [pscustomobject]@{ Strikes = @(); Alerted = $false }
}

function Save-ChatqNativeFuse {
    param($Strikes, [bool]$Alerted, [string]$Version = $script:ChatVersion)
    foreach ($s in @($Strikes)) { if ($s.PSObject.Properties['at']) { $s.at = ConvertTo-ChatqNativeStamp $s.at } }
    Save-ChatqJson (Get-ChatqNativeFile 'fuse.json') ([ordered]@{ version = $Version; strikes = @($Strikes); alerted = $Alerted })
}

function Add-ChatqNativeStrike {
    # one strike against this version, kept with the ones before it, and
    # said in chatqd.log beside chatqd's own lines
    param([string]$Why, $ProcessId, [string]$Text, [string]$Version = $script:ChatVersion)
    $f = Get-ChatqNativeFuse $Version
    try { Save-ChatqNativeFuse (@($f.Strikes) + @([pscustomobject]@{ at = Get-ChatqStamp; why = $Why; pid = $ProcessId })) $f.Alerted $Version } catch {}
    try { Add-ChatqLogLine 'chatqd.log' "fuse strike: $Text" } catch {}
}

function Test-ChatqNativeFuseBlown {
    # 3 strikes within 24 h: PowerShell until the version changes, or until
    # data/native/fuse.json is deleted
    param([string]$Version = $script:ChatVersion)
    $day = (Get-Date).AddHours(-24)
    return (@((Get-ChatqNativeFuse $Version).Strikes | Where-Object { $d = ConvertTo-ChatqDate $_.at; $d -and $d -gt $day }).Count -ge 3)
}

# Deferred: DEFERRED.md "Two launches of a native watcher at once"
function Send-ChatqNativeFuseAlert {
    # Once a fuse is blown, and only from PowerShell: chatqd has no alert of
    # its own yet, so a fuse it blows is said by the next launch from here.
    # Marked before it goes, as a push can take seconds and a launch
    # meanwhile must not say it again.
    param([string]$Version = $script:ChatVersion)
    if (-not (Test-ChatqNativeFuseBlown $Version)) { return }
    $f = Get-ChatqNativeFuse $Version
    if ($f.Alerted) { return }
    try { Save-ChatqNativeFuse $f.Strikes $true $Version } catch { return }
    try { Add-ChatqLogLine 'chatqd.log' "the native watcher failed 3 times for $Version - the PowerShell watcher runs instead" } catch {}
    try { [void](Send-ChatqAlert 'failed' 'the native watcher failed 3 times - the PowerShell watcher runs instead' -NoReply) } catch {}
}

# Deferred: DEFERRED.md "An unreadable record in data/native"
function Find-ChatqNativeStrikes {
    <#
    The strikes any launch records when it finds them, and what each was:
      no ack  pending.json older than 15 s, its pid no live chatqd: a launch
              that never reached the lock, or never said it found it busy.
              Of another version it is only cleared.
      crash   last.json says a chatqd of this version holds the lock, and it
              is dead, the lock free and watcher.pid still there, which a
              clean exit deletes. Once per pid; a kill by hand counts too.
    #>
    param([string]$Version = $script:ChatVersion)
    $found = @()
    $pp = Get-ChatqNativeFile 'pending.json'
    $p = Read-ChatqJson $pp
    if ($p) {
        $n = Get-ChatqNativeInt $p.pid
        $at = ConvertTo-ChatqDate $p.at
        $old = -not $at -or ((Get-Date) - $at).TotalMilliseconds -gt 15000
        if ($old -and -not ($null -ne $n -and (Test-ChatqNativeAlive $n -Chatqd))) {
            if ([string]$p.version -ceq $Version) {
                $t = "a launch was never acked (pid $([long]$n))"
                Add-ChatqNativeStrike 'no ack' $n $t $Version
                $found += $t
            }
            Remove-Item -LiteralPath $pp -Force -EA SilentlyContinue
        }
    }
    $l = Read-ChatqJson (Get-ChatqNativeFile 'last.json')
    $n = if ($l) { Get-ChatqNativeInt $l.pid } else { $null }
    if ($null -ne $n -and $l.engine -eq 'native' -and $l.state -eq 'holding' -and [string]$l.version -ceq $Version -and
        -not (Test-ChatqNativeAlive $n) -and -not (Test-ChatqLockHeld $script:ChatqLockPath) -and (Test-Path -LiteralPath $script:ChatqPidPath)) {
        if (-not @((Get-ChatqNativeFuse $Version).Strikes | Where-Object { $_.why -eq 'crash' -and (Get-ChatqNativeInt $_.pid) -eq $n })) {
            $t = "the native watcher $n died holding the lock"
            Add-ChatqNativeStrike 'crash' $n $t $Version
            $found += $t
        }
    }
    return $found
}

# Deferred: DEFERRED.md "A CHATQ_CHATQD in 8.3 short names"
function Get-ChatqNativeIdentity {
    # a binary as preflight knows it: its full path as FullName gives it -
    # absolute, / and .. resolved, as launch.rs's std::path::absolute does -
    # its size and its LastWriteTimeUtc
    param([string]$Path)
    $it = Get-Item -LiteralPath $Path -Force -EA SilentlyContinue
    if (-not $it) { return $null }
    return [pscustomobject]@{ path = $it.FullName; size = [long]$it.Length; mtime = $it.LastWriteTimeUtc.ToString('o') }
}

function Test-ChatqNativeVerified {
    # has this exact build passed preflight before? The path case-blind, as
    # -eq compares it
    param($Id)
    $v = Read-ChatqJson (Get-ChatqNativeFile 'verified.json')
    foreach ($e in @($v.passed)) {
        if ($e -and [string]$e.path -eq $Id.path -and (Get-ChatqNativeInt $e.size) -eq $Id.size -and (ConvertTo-ChatqNativeStamp $e.mtime) -ceq $Id.mtime) { return $true }
    }
    return $false
}

function Add-ChatqNativeVerified {
    # a pass, in place of any earlier one for the same path - a binary since
    # rebuilt - so the file keeps one entry per path and never grows
    param($Id)
    $f = Get-ChatqNativeFile 'verified.json'
    $v = Read-ChatqJson $f
    $passed = @(foreach ($e in @($v.passed)) {
            if (-not $e -or [string]$e.path -eq $Id.path) { continue }
            foreach ($k in 'mtime', 'at') { if ($e.PSObject.Properties[$k]) { $e.$k = ConvertTo-ChatqNativeStamp $e.$k } }
            $e
        })
    $passed += [pscustomobject]@{ path = $Id.path; size = $Id.size; mtime = $Id.mtime; at = Get-ChatqStamp }
    Save-ChatqJson $f ([ordered]@{ passed = $passed })
}

function Invoke-ChatqNativePreflight {
    <#
    chatqd version --root R, before a build's first launch: $null when it
    exits 0 within 5 s saying chatqd <version> <target>, else why not. It
    turns what would leave a launch waiting on nothing - an AV block, a
    missing DLL, the wrong architecture, a version mismatch - into a strike
    and the PowerShell watcher, at once.
    chatqd is a GUI-subsystem exe, which & neither waits for nor reads: a
    process of its own, its pipes redirected, waited for before it is read.
    Its one line fits in the pipe, so the wait cannot stall on a full one,
    where reading first would wait past the 5 s.
    #>
    param([string]$Exe, [string]$Version = $script:ChatVersion)
    $want = "chatqd $Version $script:ChatqNativeTarget"
    try { $p = [System.Diagnostics.Process]::Start((New-ChatqProcessStartInfo -Exe $Exe -ArgList @('version', '--root', $script:ChatRoot))) }
    catch { return "did not start: $($_.Exception.Message)" }
    try {
        try { $p.StandardInput.Close() } catch {}
        if (-not $p.WaitForExit(5000)) { try { $p.Kill() } catch {}; return 'no answer within 5 s' }
        $out = $p.StandardOutput.ReadToEnd().TrimEnd([char[]]"`r`n")
        if ($p.ExitCode -eq 0 -and $out -ceq $want) { return $null }
        return "exit $($p.ExitCode), said '$out'"
    }
    finally { $p.Dispose() }
}

function Get-ChatqWatcherEngine {
    <#
    Which watcher a launch of the loader at $Path starts (native/SPEC.md
    4.2): @{ Engine; Exe; Why; Strikes; Version }, Engine native only when
    all of these hold, else ps:
      - CHATQ_ENGINE, or else config's watcher, is not ps;
      - a Windows PC or a Mac, with the binary there to run - on a Mac its
        owner exec bit too, which a VSIX does not keep;
      - no strike found by this call, and no fuse blown;
      - the build has passed preflight, run once per build (verified.json).
    Strikes are looked for first, by every launch: one found makes this
    launch the PowerShell watcher's, so a broken binary leaves no gap longer
    than the next launch. The binary is looked for before config is read,
    which changes no answer and spares that read where there is none.
    Version is the loader's on disk (Get-ChatqLoaderVersion), as chatqd's
    respawn reads it, for the binary's folder, the records and preflight
    alike; one that cannot be read is the PowerShell watcher. It is read
    only where a binary or a record could be: with no data/native, no bin/
    and no CHATQ_CHATQD - every user today - this call is two looks.
    #>
    param([string]$Path = $script:ChatqScriptPath)
    Set-StrictMode -Off
    $seen = Test-Path -LiteralPath (Join-Path $script:ChatqData 'native')
    $look = $seen -or $env:CHATQ_CHATQD -or ($script:ChatRoot -and $script:ChatqNativeTarget -and
        (Test-Path -LiteralPath (Join-Path $script:ChatRoot 'bin') -PathType Container))
    $ver = if ($look) { Get-ChatqLoaderVersion $Path } else { $null }
    $struck = @(if ($seen -and $ver) { Find-ChatqNativeStrikes $ver })
    $why = $null
    $exe = $null
    $bin = if ($ver) { Get-ChatqNativePath $ver } else { $null }
    $runs = $script:ChatqNativeTarget -and $bin -and (Test-Path -LiteralPath $bin -PathType Leaf) -and
        -not ($script:ChatIsMac -and ([string](Get-Item -LiteralPath $bin).UnixMode)[3] -cnotin 'x', 's')
    if (-not $script:ChatqNativeTarget) { $why = 'no native build for this system' }
    elseif (-not $look) { $why = 'no chatqd: no bin folder and no CHATQ_CHATQD' }
    elseif (-not $ver) { $why = "the scripts' version cannot be read from $Path" }
    elseif (-not $runs) { $why = "no runnable chatqd at $bin" }
    elseif (-not (Test-ChatqNativeWanted)) { $why = 'the engine is set to ps' }
    elseif ($struck) { $why = 'a strike was just recorded' }
    elseif (Test-ChatqNativeFuseBlown $ver) { $why = "the native watcher failed 3 times for $ver" }
    else {
        $id = Get-ChatqNativeIdentity $bin
        if (-not $id) { $why = "cannot read $bin" }
        elseif (-not (Test-ChatqNativeVerified $id)) {
            $no = Invoke-ChatqNativePreflight $id.path $ver
            if ($no) {
                $why = "preflight failed: $no"
                Add-ChatqNativeStrike 'preflight' $null $why $ver
                $seen = $true
            }
            else { try { Add-ChatqNativeVerified $id } catch {} }
        }
        if (-not $why) { $exe = $id.path }
    }
    # the alert says the fuse keeps a binary from running: with none to run,
    # a developer's build since deleted, there is nothing for it to say
    if ($why -and $seen -and $runs) { Send-ChatqNativeFuseAlert $ver }
    return [pscustomobject]@{ Engine = $(if ($exe) { 'native' } else { 'ps' }); Exe = $exe; Why = $why; Strikes = $struck; Version = $ver }
}

function Start-ChatqNativeProcess {
    <#
    The native launch (native/SPEC.md 4.1): what the start said, or $null
    when chatqd would not start - a strike, and the caller's launch is the
    PowerShell watcher's. In your home folder, for Start-ChatqWatcherProcess's
    reasons. Every launch leaves pending.json, which the child deletes as its
    ack once it holds the lock or finds it busy; still there 15 s on with no
    chatqd at its pid, it is a strike (Find-ChatqNativeStrikes). $Version is
    the decision's, which records and strikes are kept under.
    #>
    param($Launch, [string]$Version = $script:ChatVersion)
    Set-StrictMode -Off
    $p = $null
    try {
        # tests: no real process, and a seam that throws is a start that failed
        if ($script:ChatqSpawn) { return [bool](& $script:ChatqSpawn $Launch) }
        $wd = [WildcardPattern]::Escape($HOME)
        # one line, quoted here: Start-Process joins a list with spaces and
        # quotes nothing, and the tool's folder may have a space in it
        $line = ConvertTo-ChatqArgLine $Launch.Args
        if ($script:ChatqIsWindows) {
            $p = Start-Process -FilePath $Launch.Exe -ArgumentList $line -WindowStyle Hidden -WorkingDirectory $wd -PassThru -EA Stop
        }
        else {
            New-ChatqDir $script:ChatqLogDir
            $p = Start-Process -FilePath 'nohup' -ArgumentList "$(ConvertTo-ChatqArgLine @($Launch.Exe)) $line" -WorkingDirectory $wd -PassThru -EA Stop `
                -RedirectStandardOutput (Join-Path $script:ChatqLogDir 'watcher.out') `
                -RedirectStandardError (Join-Path $script:ChatqLogDir 'watcher.err')
        }
    }
    catch {
        Add-ChatqNativeStrike 'start failed' $null "chatqd did not start: $($_.Exception.Message)" $Version
        Send-ChatqNativeFuseAlert $Version
        return $null
    }
    if ($p) { Write-ChatqNativePending $p $Version }
    return $true
}

# Deferred: DEFERRED.md "Two launches of a native watcher at once"
function Write-ChatqNativePending {
    # pending.json, for a child already running: Start-Process gives the pid
    # only then, so the child may have acked first - it holds or held the
    # lock (last.json names it), or has exited 0, as every ack does - and its
    # record would wait for nobody, a false strike 15 s on. One that exited
    # otherwise keeps it, for the strike it is.
    param($Process, [string]$Version = $script:ChatVersion)
    try {
        # held now: a child gone by the look below has no exit code to ask
        $null = $Process.Handle
        Save-ChatqJson (Get-ChatqNativeFile 'pending.json') ([ordered]@{ pid = $Process.Id; version = $Version; at = Get-ChatqStamp })
        $l = Read-ChatqJson (Get-ChatqNativeFile 'last.json')
        if (($l -and (Get-ChatqNativeInt $l.pid) -eq $Process.Id) -or ($Process.HasExited -and $Process.ExitCode -eq 0)) { Remove-ChatqNativePending $Process.Id }
    }
    catch {}
}

function Remove-ChatqNativePending {
    # the ack: only a record naming that pid, so a launch still in flight
    # for another keeps its own
    param([long]$ProcessId)
    $pp = Get-ChatqNativeFile 'pending.json'
    $p = Read-ChatqJson $pp
    if ($p -and (Get-ChatqNativeInt $p.pid) -eq $ProcessId) { Remove-Item -LiteralPath $pp -Force -EA SilentlyContinue }
}

#endregion

#region native helper steps ----------------------------------------------------
# chatqd runs the loop itself, and each piece of work still written here
# goes to a helper step: one PowerShell running src/native-step.ps1, one op,
# then gone (native/SPEC.md 3.6). The watch state crosses as `w` in the
# step's In and Out files, the caches nothing native reads in
# data/native/carry.clixml.

# The fields `w` names in each kind of entry, by its key: what is not here
# travels as the JSON scalar it is, or fails the encode
$script:ChatqStepFields = @{
    blocked           = @{ Until = 'date'; Type = 'string'; Source = 'string'; At = 'date' }
    outage            = @{ Since = 'date'; Attempts = 'int'; Status = 'string'; Alerted = 'bool'; Reminded = 'bool'; LastProbe = 'date'; NextCheck = 'date'; AutoJob = 'string' }
    ChatqAskSent      = @{ Rid = 'string'; At = 'date'; ToolUseId = 'string'; Answers = 'answers'; Transcript = 'string'; SessionId = 'string'; Title = 'string' }
    ChatqReplyJunkLog = @{ At = 'date'; Count = 'int' }
}
# w.caches: each name and what it holds - a map of entries or of true, or
# one date
$script:ChatqStepCaches = [ordered]@{
    ChatqReplyHandled = 'bool'; ChatqReplySeen = 'bool'; ChatqAskSent = 'entry'; ChatqReplyJunkLog = 'entry'; ChatqUsageSent = 'bool'
    ChatqReplyPolledAt = 'date'; ChatqReplyErrAt = 'date'; ChatqReplyBadIdAt = 'date'; ChatqReplySavedAt = 'date'; ChatqSummaryTriedAt = 'date'
}
# The process-lifetime caches and throttles nothing native reads, carried
# from step to step in carry.clixml with $W.CutCache, as the PowerShell
# watcher keeps them for its life. The self-test's audit holds the same list.
# Not the index (ChatIndexCache): the file read again costs less than its
# rows carried, ~3 s for 2000 on 5.1.
$script:ChatqStepCarry = 'ChatqBoardCutCache', 'ChatqCliVersions', 'ChatqAskAliveCache', 'ChatqBoardCache', 'ChatqPermitAsked', 'ChatqAutoCache', 'ChatAgentDoneCache',
'ChatHostFilesSeen', 'ChatOverlayLogSeen', 'ChatqAskCache', 'ChatqAutoSaid', 'ChatqBoardBgCache', 'ChatqBoardRegCache',
'ChatqPhoneMetaCache', 'ChatShellChildList', 'ChatqDownErrAt', 'ChatqPhoneWakeAt', 'ChatqAskTidiedAt'

function Test-ChatqStepScalar {
    # a value JSON holds as itself: a string, a bool or a number
    param($V)
    if ($V -is [string] -or $V -is [bool]) { return $true }
    return ($V -is [ValueType] -and -not $V.GetType().IsEnum -and [int][Type]::GetTypeCode($V.GetType()) -in 5..15)
}

function ConvertFrom-ChatqStepText {
    # a string as chatqd sent it: pwsh 7's ConvertFrom-Json makes a
    # [datetime] of one shaped like a stamp
    param($V)
    if ($V -isnot [datetime]) { return $V }
    if ($V.Kind -eq [System.DateTimeKind]::Utc) { return $V.ToUniversalTime().ToString('o') }
    return $V.ToString('o')
}

function ConvertTo-ChatqStepValue {
    # one value of `w` by its kind - date, entry, answers, or a scalar -
    # $Where naming it when it is none of them
    param($V, [string]$Kind, [string]$Where, $Fields)
    if ($null -eq $V) { return $null }
    if ($Kind -eq 'date' -and $V -is [datetime]) { return $V.ToUniversalTime().ToString('o') }
    if ($Kind -eq 'answers' -and $V -is [System.Collections.IDictionary]) { return , (ConvertTo-ChatqStepPairs $V 'string' $Where) }
    if ($Kind -eq 'entry' -and ($V -is [System.Collections.IDictionary] -or $V -is [System.Management.Automation.PSCustomObject])) {
        $dict = $V -is [System.Collections.IDictionary]
        $o = [ordered]@{ _type = $(if ($dict) { 'hashtable' } else { 'psobject' }) }
        $names = if ($dict) { @($V.Keys) } else { @($V.PSObject.Properties | ForEach-Object { $_.Name }) }
        foreach ($n in $names) {
            $x = if ($dict) { $V[$n] } else { $V.$n }
            $o[[string]$n] = ConvertTo-ChatqStepValue $x $Fields[[string]$n] "$Where.$n" $null
        }
        return $o
    }
    if (Test-ChatqStepScalar $V) { return $V }
    throw "bad step state: $Where"
}

function ConvertTo-ChatqStepPairs {
    # a map as `w` carries one: a list of {k, v}, never an object, since a
    # key may be empty or differ from another only in case
    param($Map, [string]$Kind, [string]$Where, $Fields)
    if ($Map -isnot [System.Collections.IDictionary]) { throw "bad step state: $Where" }
    $l = [System.Collections.Generic.List[object]]::new()
    foreach ($k in @($Map.Keys)) { $l.Add([ordered]@{ k = [string]$k; v = (ConvertTo-ChatqStepValue $Map[$k] $Kind $Where $Fields) }) }
    return , $l.ToArray()
}

function ConvertTo-ChatqStepW {
    # The watch state and the shared caches as `w` (native/SPEC.md 3.6
    # "The w encoding"). $W.CutCache goes to the carry, not here. Throws
    # 'bad step state: <key>.<field>' on a value the schema cannot carry.
    param($W)
    $f = $script:ChatqStepFields
    $c = [ordered]@{}
    foreach ($n in $script:ChatqStepCaches.Keys) {
        $v = (Get-Variable -Name $n -Scope Script).Value
        $c[$n] = if ($script:ChatqStepCaches[$n] -eq 'date') { ConvertTo-ChatqStepValue $v 'date' $n $null } else { ConvertTo-ChatqStepPairs $v $script:ChatqStepCaches[$n] $n $f[$n] }
    }
    [ordered]@{
        blocked = ConvertTo-ChatqStepPairs $W.blocked 'entry' 'blocked' $f['blocked']
        outage = ConvertTo-ChatqStepPairs $W.outage 'entry' 'outage' $f['outage']
        lastAllowed = ConvertTo-ChatqStepPairs $W.lastAllowed 'date' 'lastAllowed' $null
        probeFails = ConvertTo-ChatqStepPairs $W.probeFails 'int' 'probeFails' $null
        scannedAt = ConvertTo-ChatqStepPairs $W.scannedAt 'date' 'scannedAt' $null
        authAlerted = ConvertTo-ChatqStepPairs $W.authAlerted 'bool' 'authAlerted' $null
        current = ConvertTo-ChatqStepValue $W.current 'string' 'current' $null
        next = ConvertTo-ChatqStepValue $W.next 'string' 'next' $null
        startedAt = ConvertTo-ChatqStepValue $W.startedAt 'string' 'startedAt' $null
        handoff = ConvertTo-ChatqStepValue $W.handoff 'bool' 'handoff' $null
        listening = ConvertTo-ChatqStepValue $W.listening 'bool' 'listening' $null
        caches = $c
    }
}

function ConvertFrom-ChatqStepValue {
    # one value of `w` back by its kind: a Date Kind Local, as every writer
    # stores it; an int [int]; an entry the type its _type names; anything
    # else the scalar it is, a stamp-shaped string text again
    param($V, [string]$Kind, [string]$Where, $Fields)
    if ($null -eq $V) { return $null }
    if ($Kind -eq 'date' -and ($V -is [string] -or $V -is [datetime])) { $d = ConvertTo-ChatqDate $V; if ($d) { return $d } }
    if ($Kind -eq 'int' -and ($V -is [int] -or $V -is [long])) { return [int]$V }
    if ($Kind -eq 'answers' -and $V -is [array]) {
        $m = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
        foreach ($p in (ConvertFrom-ChatqStepPairs $V 'string' $Where $null)) { $m[$p.K] = $p.V }
        return , $m
    }
    if ($Kind -eq 'entry') {
        $t = if ($V -is [System.Management.Automation.PSCustomObject] -and $V.PSObject.Properties['_type']) { $V._type } else { $null }
        if ($t -cnotin 'psobject', 'hashtable') { throw "bad step input: $Where" }
        $o = [ordered]@{}
        foreach ($p in $V.PSObject.Properties) {
            if ($p.Name -ceq '_type') { continue }
            $o[$p.Name] = ConvertFrom-ChatqStepValue $p.Value $Fields[$p.Name] "$Where.$($p.Name)" $null
        }
        if ($t -eq 'psobject') { return [pscustomobject]$o }
        $h = @{}
        foreach ($k in $o.Keys) { $h[$k] = $o[$k] }
        return $h
    }
    if ($V -is [System.Management.Automation.PSCustomObject] -or $V -is [array]) { throw "bad step input: $Where" }
    return (ConvertFrom-ChatqStepText $V)
}

function ConvertFrom-ChatqStepPairs {
    # a list of {k, v} back, as @{ K; V } in its order
    param($L, [string]$Kind, [string]$Where, $Fields)
    if ($L -isnot [array]) { throw "bad step input: $Where" }
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $L) {
        if ($p -isnot [System.Management.Automation.PSCustomObject] -or -not $p.PSObject.Properties['k'] -or -not $p.PSObject.Properties['v']) { throw "bad step input: $Where" }
        $k = ConvertFrom-ChatqStepText $p.k
        if ($k -isnot [string]) { throw "bad step input: $Where" }
        $out.Add(@{ K = $k; V = (ConvertFrom-ChatqStepValue $p.v $Kind $Where $Fields) })
    }
    return , $out.ToArray()
}

function ConvertFrom-ChatqStepW {
    # `w` back: @{ W = a fresh watch state; Caches = name -> value }, all of
    # it or nothing - 'bad step input: <key>' on what the schema does not
    # carry, so a w that does not decode is taken nowhere
    param($J)
    if ($J -isnot [System.Management.Automation.PSCustomObject]) { throw 'bad step input: w' }
    $get = { param($o, $k) if (-not $o.PSObject.Properties[$k]) { throw "bad step input: $k" }; , $o.$k }
    $f = $script:ChatqStepFields
    $W = New-ChatqWatchState
    foreach ($k in 'blocked', 'outage', 'lastAllowed', 'probeFails', 'scannedAt', 'authAlerted') {
        $kind = switch ($k) { 'blocked' { 'entry' } 'outage' { 'entry' } 'probeFails' { 'int' } 'authAlerted' { 'bool' } default { 'date' } }
        $m = @{}
        foreach ($p in (ConvertFrom-ChatqStepPairs (& $get $J $k) $kind $k $f[$k])) { $m[$p.K] = $p.V }
        $W[$k] = $m
    }
    foreach ($k in 'current', 'next', 'startedAt') { $W[$k] = ConvertFrom-ChatqStepValue (& $get $J $k) 'string' $k $null }
    foreach ($k in 'handoff', 'listening') { $W[$k] = ConvertFrom-ChatqStepValue (& $get $J $k) 'bool' $k $null }
    $cj = & $get $J 'caches'
    if ($cj -isnot [System.Management.Automation.PSCustomObject]) { throw 'bad step input: caches' }
    $c = @{}
    foreach ($n in $script:ChatqStepCaches.Keys) {
        $kind = $script:ChatqStepCaches[$n]
        if ($kind -eq 'date') { $c[$n] = ConvertFrom-ChatqStepValue (& $get $cj $n) 'date' $n $null; continue }
        $m = @{}
        foreach ($p in (ConvertFrom-ChatqStepPairs (& $get $cj $n) $kind $n $f[$n])) { $m[$p.K] = $p.V }
        $c[$n] = $m
    }
    return @{ W = $W; Caches = $c }
}

function ConvertTo-ChatqCarryValue {
    # A cache's value as Import-Clixml gives it back the same: an array or
    # a List[T] would come back an ArrayList, and an [ordered] a Hashtable
    # on 5.1, its order lost, so those go as marked objects (ChatqCarry).
    # Hashtables, objects, strings, numbers and dates go as themselves.
    # Throws on any other type: that cache is not carried, and the next
    # step builds it again.
    param($V)
    if ($null -eq $V -or $V -is [string] -or $V -is [ValueType]) { return $V }
    $items = { param($all) $l = [System.Collections.Generic.List[object]]::new(); foreach ($x in $all) { $l.Add((ConvertTo-ChatqCarryValue $x)) }; , $l.ToArray() }
    if ($V -is [System.Collections.Specialized.OrderedDictionary]) {
        $cmp = [System.Collections.Specialized.OrderedDictionary].GetField('_comparer', [System.Reflection.BindingFlags]'NonPublic,Instance').GetValue($V)
        return [pscustomobject]@{ ChatqCarry = 'ordered'; Ordinal = [bool]($cmp -eq [StringComparer]::Ordinal); Keys = @($V.Keys); Values = (& $items $V.Values) }
    }
    if ($V -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in @($V.Keys)) { $h[$k] = ConvertTo-ChatqCarryValue $V[$k] }
        return $h
    }
    $t = $V.GetType()
    if ($V -is [array]) { return [pscustomobject]@{ ChatqCarry = 'array'; Type = $t.GetElementType().FullName; Items = (& $items $V) } }
    if ($t.IsGenericType -and $t.GetGenericTypeDefinition() -eq [System.Collections.Generic.List`1]) {
        return [pscustomobject]@{ ChatqCarry = 'list'; Type = $t.GetGenericArguments()[0].FullName; Items = (& $items $V) }
    }
    if ($V -is [System.Management.Automation.PSCustomObject]) {
        $o = [ordered]@{}
        foreach ($p in $V.PSObject.Properties) { $o[$p.Name] = ConvertTo-ChatqCarryValue $p.Value }
        return [pscustomobject]$o
    }
    throw "no carry for a $($t.FullName)"
}

function ConvertFrom-ChatqCarryValue {
    # ConvertTo-ChatqCarryValue's value back, from what Import-Clixml made
    param($V)
    if ($null -eq $V -or $V -is [string] -or $V -is [ValueType]) { return $V }
    if ($V -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in @($V.Keys)) { $h[$k] = ConvertFrom-ChatqCarryValue $V[$k] }
        return $h
    }
    if ($V -isnot [System.Management.Automation.PSCustomObject]) { throw "no carry for a $($V.GetType().FullName)" }
    $mark = if ($V.PSObject.Properties['ChatqCarry']) { [string]$V.ChatqCarry } else { '' }
    if ($mark -eq 'ordered') {
        $o = if ($V.Ordinal) { New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal) } else { [ordered]@{} }
        $vals = @($V.Values)
        $i = 0
        foreach ($k in @($V.Keys)) { $o[$k] = ConvertFrom-ChatqCarryValue $vals[$i]; $i++ }
        return , $o
    }
    if ($mark -in 'array', 'list') {
        $et = [string]$V.Type -as [type]
        if (-not $et) { throw "no carry for a $($V.Type)" }
        $all = @($V.Items)
        if ($mark -eq 'array') {
            $a = [Array]::CreateInstance($et, $all.Count)
            for ($i = 0; $i -lt $all.Count; $i++) { $a[$i] = ConvertFrom-ChatqCarryValue $all[$i] }
            return , $a
        }
        $l = [Activator]::CreateInstance([System.Collections.Generic.List`1].MakeGenericType($et))
        foreach ($x in $all) { $l.Add((ConvertFrom-ChatqCarryValue $x)) }
        return , $l
    }
    $o = [ordered]@{}
    foreach ($p in $V.PSObject.Properties) { $o[$p.Name] = ConvertFrom-ChatqCarryValue $p.Value }
    return [pscustomobject]$o
}

function Export-ChatqStepCarry {
    # the carry rows and $W.CutCache into carry.clixml for the next step; a
    # cache not made yet, or of a type the carry does not know, is left out,
    # to start again
    param($W)
    $vars = @{}
    foreach ($n in $script:ChatqStepCarry) {
        $v = Get-Variable -Name $n -Scope Script -EA SilentlyContinue
        if ($v) { try { $vars[$n] = ConvertTo-ChatqCarryValue $v.Value } catch {} }
    }
    $cut = try { ConvertTo-ChatqCarryValue $W.CutCache } catch { $null }
    try {
        New-ChatqDir (Join-Path $script:ChatqData 'native')
        Export-Clixml -LiteralPath (Get-ChatqNativeFile 'carry.clixml') -InputObject @{ Vars = $vars; CutCache = $cut } -Depth 64
    }
    catch {}
}

function Import-ChatqStepCarry {
    # what Export-ChatqStepCarry kept, when there is any: each cache it
    # holds set again, $W.CutCache @{} without one
    param($W)
    $W.CutCache = @{}
    $p = Get-ChatqNativeFile 'carry.clixml'
    if (-not [System.IO.File]::Exists($p)) { return }
    $c = try { Import-Clixml -LiteralPath $p } catch { $null }
    if ($c -isnot [hashtable]) { return }
    $cut = try { ConvertFrom-ChatqCarryValue $c['CutCache'] } catch { $null }
    if ($cut -is [hashtable]) { $W.CutCache = $cut }
    if ($c['Vars'] -isnot [hashtable]) { return }
    foreach ($n in $script:ChatqStepCarry) {
        if ($c['Vars'].ContainsKey($n)) { try { Set-Variable -Name $n -Scope Script -Value (ConvertFrom-ChatqCarryValue $c['Vars'][$n]) } catch {} }
    }
}

function Invoke-ChatqNativeStep {
    <#
    One helper step's op (native/SPEC.md 3.6), from src/native-step.ps1: In
    read, the watch state and the caches taken from it and the carry, the op
    run, and Out written - {v, ok, error, w, result}. A missing In, another
    v, an op not known or a w that does not decode is 'bad step input', and
    nothing is run or carried. The parent is checked before and after the op
    (ChatqStepParent): with chatqd gone, the step ends itself at once.
    #>
    param([string]$In, [string]$Out)
    $r = [ordered]@{ v = 1; ok = $false; error = 'bad step input'; w = $null; result = $null }
    $q = Read-ChatqJson $In
    $op = if ($q) { ConvertFrom-ChatqStepText $q.op } else { $null }
    $d = $null
    if ($q -and (Get-ChatqNativeInt $q.v) -eq 1 -and $op -is [string] -and
        $op -cin 'repair', 'pick', 'block', 'auto', 'stray', 'soon', 'held', 'ask-landed', 'alert', 'job-write') {
        $d = try { ConvertFrom-ChatqStepW $q.w } catch { $null }
    }
    if (-not $d) { Save-ChatqText $Out ($r | ConvertTo-Json -Depth 12); return }
    if ($script:ChatqStepParent -and -not (& $script:ChatqStepParent)) { Stop-Process -Id $PID -Force }
    $W = $d.W
    foreach ($n in $script:ChatqStepCaches.Keys) { Set-Variable -Name $n -Scope Script -Value $d.Caches[$n] }
    Import-ChatqStepCarry $W
    # chatqd's identity wherever a step writes the watcher's: state.json, a
    # run's runnerPid, the permit.log and ask.log tags
    $script:ChatqWatcherPid = $q.watcherPid
    $script:ChatqWatcherStartedAt = ConvertFrom-ChatqStepText $q.startedAt
    $script:ChatqRunnerPid = $q.watcherPid
    $script:ChatqAlertJob = ConvertFrom-ChatqStepText $q.alertJob
    $a = $q.args
    $arg = { param($n) if ($a -and $a.PSObject.Properties[$n]) { ConvertFrom-ChatqStepText $a.$n } else { $null } }
    $r.error = $null
    $res = $null
    try {
        switch -CaseSensitive ($op) {
            'repair' {
                Repair-ChatqInterrupted
                $W.CutCache = @{}
                $res = [ordered]@{}
            }
            'pick' {
                # gone, or no longer queued: nothing done at all, as
                # Invoke-ChatqJob's own re-read leaves it
                $job = Find-ChatqJob ([string](& $arg 'jobId')) -Exact
                $gone = -not $job -or $job.state -ne 'queued'
                if (-not $gone) { Invoke-ChatqPick $W $job }
                $res = [ordered]@{ gone = $gone }
            }
            'block' {
                foreach ($id in @($a.jobIds)) {
                    $job = Find-ChatqJob ([string](ConvertFrom-ChatqStepText $id)) -Exact
                    if ($job) { Update-ChatqBlock $W $job }
                }
                $res = [ordered]@{}
            }
            'auto' {
                $null = Invoke-ChatqWatchAutoScan $W
                $res = [ordered]@{}
            }
            'stray' {
                # the loop's own sweep and line
                $swept = @(try { Clear-ChatqStrayFiles } catch { })
                if ($swept.Count) { Write-ChatqWatchLog "removed $($swept.Count) stray file(s) and folder(s) from data/queue" }
                $res = [ordered]@{ removed = $swept.Count }
            }
            'soon' {
                $queued = @(Get-ChatqJobs | Where-Object { $_.state -eq 'queued' })
                $soonAt = Send-ChatqUsageSoon $W $queued
                $res = [ordered]@{ soonAt = $(if ($soonAt) { $soonAt.ToUniversalTime().ToString('o') } else { $null }) }
            }
            'held' {
                $res = [ordered]@{ sent = [bool](Send-ChatqHeldSummary) }
            }
            'ask-landed' {
                $null = Test-ChatqAskLanded -Quick:([bool](& $arg 'quick'))
                $res = [ordered]@{}
            }
            'alert' {
                $id = & $arg 'jobId'
                $job = if ($id) { Find-ChatqJob ([string]$id) -Exact } else { $null }
                $sent = Send-ChatqAlert ([string](& $arg 'event')) ([string](& $arg 'text')) ([int](& $arg 'priority')) -Loud:([bool](& $arg 'loud')) -Job $job `
                    -Quick:([bool](& $arg 'quick')) -NoReply:([bool](& $arg 'noReply')) -UsageKind ([string](& $arg 'usageKind'))
                $res = [ordered]@{ sent = [bool]$sent }
            }
            'job-write' {
                $job = Find-ChatqJob ([string](& $arg 'jobId')) -Exact
                $saved = $false
                if ($job -and $a.PSObject.Properties['set']) {
                    foreach ($p in $a.set.PSObject.Properties) { Set-ChatqProp $job $p.Name (ConvertFrom-ChatqStepText $p.Value) }
                    $saved = [bool](Save-ChatqJob $job -Existing)
                }
                elseif ($job -and $a.PSObject.Properties['complete'] -and $job.state -in 'queued', 'running') {
                    $cp = $a.complete
                    $saved = [bool](Complete-ChatqJob $job ([string](ConvertFrom-ChatqStepText $cp.state)) $cp.result ([string](ConvertFrom-ChatqStepText $cp.why)) -Existing)
                }
                $res = [ordered]@{ saved = $saved }
            }
        }
        $r.ok = $true
    }
    catch { $r.error = "$($_.Exception.Message) @ $(($_.ScriptStackTrace -split "`r?`n")[0])" }
    if ($script:ChatqStepParent -and -not (& $script:ChatqStepParent)) { Stop-Process -Id $PID -Force }
    Export-ChatqStepCarry $W
    if ($r.ok) {
        try { $r.w = ConvertTo-ChatqStepW $W; $r.result = $res }
        catch { $r.ok = $false; $r.error = $_.Exception.Message; $r.w = $null; $r.result = $null }
    }
    Save-ChatqText $Out ($r | ConvertTo-Json -Depth 12)
}

#endregion
