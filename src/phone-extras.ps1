# Charlie-and-the-chat-factory, src/phone-extras.ps1: dot-sourced by Charlie-and-the-chat-factory.ps1
# in its turn, never on its own - see the list there.

#region phone extras: shared ---------------------------------------------------
# Four smaller phone features on top of 0.8.0's (docs/phone-extras-spec.md):
# usage heads-ups, with a Send now for a reset coming; quiet hours, whose
# held alerts go as one summary; a line Join reads aloud; and a reply typed
# outside the browser, which is the page's (docs/reply.html) and the
# README's recipe. Each hooks into the code that was there at a line or two
# - Send-ChatqAlert, the watcher's loop, the overlay's pass, chatnotify and
# the setup window - and the rest lives here. The rules 0.8.0 set hold for
# all of it: no key in any push, only a reply whose MAC checks out does
# anything, nothing above reply.maxMode, and nothing that sends or waits on
# the network inside a lock.

$script:ChatqUsageAlertPath = Join-Path $script:ChatqData 'usage-alerts.json'
$script:ChatqUsageAlertLockPath = Join-Path $script:ChatqData 'usage-alerts.lock'
$script:ChatqHeldPath = Join-Path $script:ChatqData 'held.jsonl'
$script:ChatqHeldLockPath = Join-Path $script:ChatqData 'held.lock'
# 'usage' is an event the phone can be kept from, like the rest: a user whose
# phoneEvents is a list does not get it until it is ticked
if ($script:ChatqPhoneEvents -notcontains 'usage') { $script:ChatqPhoneEvents = @($script:ChatqPhoneEvents) + 'usage' }
# when this process last did a Send now from the phone: a second within two
# minutes only says the first is under way
$script:ChatqPhoneWakeAt = $null
# the usage alerts this process knows went already, so a figure that stays
# over its threshold for hours does not take the lock on every pass
$script:ChatqUsageSent = @{}
# the summary's own Send-ChatqAlert must not go looking for a summary again
$script:ChatqSendingSummary = $false
# a summary that did not go is tried again 5 minutes later at the soonest
$script:ChatqSummaryTriedAt = $null
# tests only: the time quiet hours are judged at, in place of Get-Date
$script:ChatqClockSeam = $null

function Get-ChatqNow {
    # the wall clock quiet hours go by; $script:ChatqClockSeam moves it in tests
    if ($script:ChatqClockSeam) { return [datetime]$script:ChatqClockSeam }
    return (Get-Date)
}

function Invoke-ChatqLocked {
    <#
    Run a block holding a lock file opened with no sharing, as
    Use-ChatqReplyState holds data/replies.lock: up to 3 s of tries, each
    wait a random length so two writers retrying in step do not take turns
    forever. Throws when the lock cannot be had; what the block outputs is
    returned. Nothing that sends or waits on the network belongs inside.
    #>
    # odd names on purpose: the block runs in a scope below this one and
    # would see these in place of its caller's variables of the same name
    param([string]$ChatqLockFile, [scriptblock]$ChatqLockedBlock)
    New-ChatqDir $script:ChatqData
    $chatqLockHandle = $null
    $chatqLockUntil = (Get-Date).AddSeconds(3)
    while (-not $chatqLockHandle) {
        try { $chatqLockHandle = [System.IO.File]::Open($ChatqLockFile, 'OpenOrCreate', 'ReadWrite', 'None') }
        catch {
            if ((Get-Date) -gt $chatqLockUntil) { break }
            Start-Sleep -Milliseconds (Get-Random -Minimum 15 -Maximum 60)
        }
    }
    if (-not $chatqLockHandle) { throw "data/$(Split-Path $ChatqLockFile -Leaf) is held by another process" }
    try { return (& $ChatqLockedBlock) }
    finally { $chatqLockHandle.Dispose() }
}

function Limit-ChatqText {
    # at most -Max characters, never between the two halves of an emoji;
    # -Ellipsis marks a cut
    param([string]$Text, [int]$Max, [switch]$Ellipsis)
    $t = [string]$Text
    if ($t.Length -le $Max) { return $t }
    $n = if ($Ellipsis) { $Max - 1 } else { $Max }
    if ($n -gt 0 -and [char]::IsHighSurrogate($t[$n - 1])) { $n-- }
    $t = $t.Substring(0, [Math]::Max(0, $n))
    if ($Ellipsis) { $t = $t.TrimEnd() + $script:ChatqEllipsis }
    return $t
}

function Format-ChatqClockTime {
    # 13:00 today, Tue 13:00 any other day
    param([datetime]$When, [datetime]$Now = (Get-Date))
    $fmt = if ($When.Date -eq $Now.Date) { 'HH:mm' } else { 'ddd HH:mm' }
    return $When.ToString($fmt, [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-ChatqEventName {
    # an event as typed - needs-input, Needs_Input, needsinput - as the phone
    # events spell it
    param([string]$Name)
    $n = (([string]$Name).Trim() -replace '[-_]', ' ').ToLower()
    if ($n -eq 'needsinput') { $n = 'needs input' }
    return $n
}

#endregion

#region phone extras: usage heads-ups --------------------------------------------
# Three alerts under the event 'usage'. threshold: the overlay saw a 5-hour
# or weekly window cross usage.at (90%). soon: the watcher waits out a
# limit with prompts queued in it, and the reset is soonMinutes (10) away -
# with Send now on the page. reset: a lane that was limited probes allowed
# with two or more prompts queued in it. Each goes once: its key is recorded
# in data/usage-alerts.json before anything is sent, so a crash between the
# two loses a heads-up and never sends two.

function ConvertTo-ChatqUsageThresholds {
    # '75, 90', @(75, 90) or 90 as @(75, 90), ascending; $null for anything
    # that is not one to three whole percents from 1 to 99
    param($Value)
    $items = @(@($Value) | ForEach-Object { [string]$_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    if (-not $items.Count -or $items.Count -gt 3) { return $null }
    $out = @()
    foreach ($i in $items) {
        if ($i -notmatch '^\d{1,2}$') { return $null }
        $n = [int]$i
        if ($n -lt 1 -or $n -gt 99) { return $null }
        if ($out -notcontains $n) { $out += $n }
    }
    return , @($out | Sort-Object)
}

function Get-ChatqUsageAlertConfig {
    # config usage, defaults filled in and bad values dropped:
    # @{ Alerts; At; Reset; SoonMinutes }. A missing block is every default.
    param($Cfg)
    $u = if ($Cfg -and $Cfg.PSObject.Properties['usage'] -and $Cfg.usage) { $Cfg.usage } else { $null }
    $get = { param($n) if ($u -and $u.PSObject.Properties[$n]) { $u.$n } else { $null } }
    $alerts = $true
    $v = & $get 'alerts'
    if ($v -is [bool]) { $alerts = $v }
    $reset = $true
    $v = & $get 'reset'
    if ($v -is [bool]) { $reset = $v }
    $at = @(90)
    $v = & $get 'at'
    if ($null -ne $v) { $p = ConvertTo-ChatqUsageThresholds $v; if ($p) { $at = @($p) } }
    $soon = 10
    $v = & $get 'soonMinutes'
    if ($null -ne $v -and [string]$v -match '^\d{1,3}$' -and [int]$v -le 120) { $soon = [int]$v }
    [pscustomobject]@{ Alerts = [bool]$alerts; At = @($at); Reset = [bool]$reset; SoonMinutes = $soon }
}

function Get-ChatqEpochMinutes {
    # a time as whole minutes since 1970: what names one window, one reset
    param([datetime]$When)
    return [string][int64][Math]::Floor([DateTimeOffset]::new($When.ToUniversalTime()).ToUnixTimeSeconds() / 60)
}

function Get-ChatqUsageAlertState {
    # data/usage-alerts.json as key -> UTC time sent. Missing is empty. So is
    # one that cannot be read: it only keeps a heads-up from going twice, and
    # a file that wedged every heads-up for good would be worse than one
    # repeat
    $st = @{}
    if (-not (Test-Path -LiteralPath $script:ChatqUsageAlertPath)) { return $st }
    try {
        $raw = [System.IO.File]::ReadAllText($script:ChatqUsageAlertPath, (New-Object System.Text.UTF8Encoding $false))
        if (-not $raw.Trim()) { return $st }
        $j = $raw | ConvertFrom-Json
        foreach ($p in $j.PSObject.Properties) {
            $x = ConvertTo-ChatqDate $p.Value
            if ($x) { $st[$p.Name] = $x.ToUniversalTime().ToString('o') }
        }
    }
    catch {}
    return $st
}

function Save-ChatqUsageAlertState {
    # Pruned on every save: a key whose reset passed more than a day ago, an
    # 'x' key (a window with no reset time) 5 h after it went for a 5-hour
    # window and 7 days for any other, and anything past 200, the oldest
    # going first. Throws when it cannot save.
    param([hashtable]$State, [datetime]$Now)
    $nowU = $Now.ToUniversalTime()
    $keep = foreach ($k in @($State.Keys)) {
        $at = ConvertTo-ChatqDate $State[$k]
        if (-not $at) { continue }
        $at = $at.ToUniversalTime()
        $parts = @($k -split '\|')
        $last = $parts[-1]
        if ($last -eq 'x') {
            $label = if ($parts[0] -eq 't' -and $parts.Count -ge 6) { $parts[-3] } else { '' }
            $life = if ($label -eq '5h') { [TimeSpan]::FromHours(5) } else { [TimeSpan]::FromDays(7) }
            if ($at.Add($life) -lt $nowU) { continue }
        }
        elseif ($last -match '^\d+$') {
            $reset = [DateTimeOffset]::FromUnixTimeSeconds([int64]$last * 60).UtcDateTime
            if ($reset.AddDays(1) -lt $nowU) { continue }
        }
        [pscustomobject]@{ K = $k; At = $at }
    }
    $keep = @($keep | Sort-Object At, K | Select-Object -Last 200)
    $o = [ordered]@{}
    foreach ($e in $keep) { $o[$e.K] = $e.At.ToString('o') }
    Save-ChatqJson $script:ChatqUsageAlertPath $o
}

function Use-ChatqUsageAlertState {
    <#
    Every change to data/usage-alerts.json goes through here, holding
    data/usage-alerts.lock: the overlay and the watcher both write it. The
    block gets the state as a hashtable, changes it in place, and what it
    outputs is returned. Throws when the lock cannot be had or the save
    fails - and then the caller sends nothing; the next pass tries again.
    #>
    param([scriptblock]$UsageStateBlock, [datetime]$UsageStateNow = (Get-Date))
    return (Invoke-ChatqLocked $script:ChatqUsageAlertLockPath {
            $usageStateNow2 = Get-ChatqUsageAlertState
            $usageStateOut = & $UsageStateBlock $usageStateNow2
            Save-ChatqUsageAlertState $usageStateNow2 $UsageStateNow
            $usageStateOut
        })
}

function Update-ChatqUsageAlerts {
    <#
    Threshold heads-ups, from the overlay's pass (Invoke-ChatOverlayCycle,
    the Windows host's only), with the usage it just worked out for the
    snapshot - live from the endpoint or Claude Code's cache for Claude, the
    newest rollout for Codex - and the jobs it holds. A window counts when
    it is 5h, week or one model's week, not stale, not limited (a limit is
    the watcher's business) and read in the last 30 minutes. Only the
    highest threshold it crossed goes, and every one it crossed is recorded
    with it: at 95% with 75 and 90 both new, one alert says 95%. The key
    names the window by its reset, so the next window starts clean. The
    alert is handed to the outbox like a live alert, and goes through
    Send-ChatqAlert from there: the toast at the PC, the phone away. -Now
    is for the tests. Never throws.
    #>
    param($Ctx, [object[]]$Usage, [object[]]$Jobs, [datetime]$Now = (Get-Date))
    try {
        $cfg = Get-ChatqLiveAlertConfig $Ctx $Now
        $uc = Get-ChatqUsageAlertConfig $cfg
        if (-not $uc.Alerts) { return }
        $phones = Test-ChatqPhoneChannel $cfg
        $toastOn = -not ($cfg.PSObject.Properties['toast'] -and $cfg.toast -eq $false)
        if (-not $phones -and -not $toastOn) { return }
        if (-not $toastOn -and -not (Test-ChatqPhoneEvent $cfg 'usage')) { return }
        $nowMs = [DateTimeOffset]::new($Now).ToUnixTimeMilliseconds()
        $cfgDir = [string](Get-ChatField $Ctx 'ClaudeHome')
        $default = Join-Path $HOME '.claude'
        $acct = if ($cfgDir -and -not [string]::Equals($cfgDir.TrimEnd('\', '/'), $default.TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase)) { $cfgDir } else { '' }
        $seen = Get-ChatField $Ctx 'UsageSeen'
        if (-not $seen) { $seen = @{}; $Ctx['UsageSeen'] = $seen }
        $cand = [System.Collections.Generic.List[object]]::new()
        foreach ($u in @($Usage)) {
            if (-not $u) { continue }
            $prov = [string](Get-ChatField $u 'provider')
            # Copilot's is a monthly quota, and not this
            if ($prov -notin 'Claude', 'Codex') { continue }
            if (Get-ChatField $u 'stale') { continue }
            $at = Get-ChatField $u 'at'
            # a figure from a /usage hours ago is not news
            if (-not $at -or ($nowMs - [int64]$at) -gt 30 * 60000) { continue }
            $who = if ($prov -eq 'Claude') { $acct } else { '' }
            foreach ($w in @(Get-ChatField $u 'windows')) {
                if (-not $w) { continue }
                $label = [string](Get-ChatField $w 'label')
                if ($label -notmatch '^(5h|week|.+ week)$') { continue }
                if (Get-ChatField $w 'limited') { continue }
                $p = [int](Get-ChatField $w 'percent')
                if ($p -ge 100) { continue }
                $crossed = @($uc.At | Where-Object { $p -ge $_ })
                if (-not $crossed.Count) { continue }
                $rms = Get-ChatField $w 'resetsAt'
                $rk = if ($rms) { [string][int64][Math]::Floor([double]$rms / 60000) } else { 'x' }
                $keys = @($crossed | ForEach-Object { "t|$prov|$who|$label|$_|$rk" })
                $top = $keys[-1]
                if ($seen[$top]) { continue }
                $reset = if ($rms) { [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$rms).LocalDateTime } else { $null }
                $cand.Add([pscustomobject]@{ Provider = $prov; Label = $label; Percent = $p; Reset = $reset; Keys = $keys; Top = $top })
            }
        }
        if (-not $cand.Count) { return }
        $stamp = $Now.ToUniversalTime().ToString('o')
        $send = @(Use-ChatqUsageAlertState {
                param($st)
                foreach ($c in $cand) {
                    if ($st.ContainsKey($c.Top)) { continue }
                    foreach ($k in $c.Keys) { if (-not $st.ContainsKey($k)) { $st[$k] = $stamp } }
                    $c
                }
            } $Now)
        foreach ($c in $cand) { $seen[$c.Top] = $true }
        $d = $script:ChatqDot
        foreach ($c in $send) {
            $n = @($Jobs | Where-Object { $_ -and [string]$_.state -eq 'queued' -and [string]$_.provider -eq $c.Provider.ToLower() }).Count
            $text = "$($c.Provider) $($c.Label) at $($c.Percent)%"
            if ($c.Reset) { $text += " $d resets $(Format-ChatqClockTime $c.Reset $Now)" }
            if ($n) { $text += " $d $n queued" }
            $null = Send-ChatqLiveAlert ([ordered]@{ event = 'usage'; text = $text; priority = 0; kind = 'threshold' })
            Write-ChatOverlayLog "phone: usage heads-up handed to the outbox - $text" -Always
        }
    }
    catch {
        try { Write-ChatOverlayLog "phone: usage heads-up: $($_.Exception.Message)" } catch {}
    }
}

function Test-ChatqUsageLimitBlock {
    # a lane's block that is a usage limit: not a probe that failed, not a
    # login refused, not an overload
    param($Block)
    return [bool]($Block -and $Block.Until -and [string]$Block.Type -notin 'probe failed', 'login needed', 'overloaded')
}

function Get-ChatqLaneQueued {
    # the jobs queued in one lane
    param([string]$Lane, [object[]]$Jobs)
    return @($Jobs | Where-Object { $_ -and [string]$_.state -eq 'queued' -and (Get-ChatqLane $_) -eq $Lane })
}

function Send-ChatqUsageSoon {
    <#
    The soon alert, from the watcher's loop once it found nothing due: a
    lane waiting out a limit whose reset is usage.soonMinutes away, with a
    job queued in it that its own -At does not hold past the reset. Only a
    wait that was 30 minutes or more when the lane was blocked: the 15
    minutes the watcher guesses when a probe gives no reset time is a guess,
    not a reset. Its link offers Send now (w=1). Returns the soonest time a
    soon alert is still to go, so the loop wakes for it, or $null. Never
    throws.
    #>
    param($W, [object[]]$Queued, [datetime]$Now = (Get-Date))
    $next = $null
    try {
        $uc = Get-ChatqUsageAlertConfig (Get-ChatqConfig)
        if (-not $uc.Reset -or $uc.SoonMinutes -le 0) { return $null }
        foreach ($lane in @($W.blocked.Keys)) {
            $b = $W.blocked[$lane]
            if (-not (Test-ChatqUsageLimitBlock $b)) { continue }
            $since = ConvertTo-ChatqDate (Get-ChatField $b 'At')
            if (-not $since -or ($b.Until - $since).TotalMinutes -lt 30) { continue }
            $left = ($b.Until - $Now).TotalMinutes
            if ($left -le 0) { continue }
            $jobs = @(Get-ChatqLaneQueued $lane $Queued | Where-Object { $nb = ConvertTo-ChatqDate $_.notBefore; -not ($nb -and $nb -gt $b.Until) })
            if (-not $jobs.Count) { continue }
            $key = "s|$lane|$(Get-ChatqEpochMinutes $b.Until)"
            if ($script:ChatqUsageSent[$key]) { continue }
            if ($left -gt $uc.SoonMinutes) {
                $at = $b.Until.AddMinutes(-$uc.SoonMinutes)
                if (-not $next -or $at -lt $next) { $next = $at }
                continue
            }
            $stamp = $Now.ToUniversalTime().ToString('o')
            $go = Use-ChatqUsageAlertState { param($st) if ($st.ContainsKey($key)) { $false } else { $st[$key] = $stamp; $true } } $Now
            $script:ChatqUsageSent[$key] = $true
            if (-not $go) { continue }
            $d = $script:ChatqDot
            # one at a time: the watcher runs one job, then the next
            $go = if ($jobs.Count -gt 1) { 'they go then, one at a time' } else { 'it goes then' }
            $text = "$(Format-ChatqLane $lane) resets $(Format-ChatqClockTime $b.Until $Now) $d $($jobs.Count) queued $d $go"
            $null = Send-ChatqAlert 'usage' $text 0 -UsageKind soon
            Write-ChatqWatchLog "$lane resets at $($b.Until.ToString('HH:mm')) with $($jobs.Count) queued - soon alert sent"
        }
    }
    catch { Write-ChatqWatchLog "usage soon alert: $($_.Exception.Message)" }
    return $next
}

function Send-ChatqUsageReset {
    <#
    The reset alert, from Confirm-ChatqAllowed as a lane that was limited
    probes allowed: before the job runs, when two or more are queued in the
    lane - with one, the started alert seconds later says it. One per lane
    and reset, whatever the number of jobs. $Was is the block the lane had.
    Returns $true when it went; never throws.
    #>
    param($W, $Job, $Was, [datetime]$Now = (Get-Date))
    try {
        if (-not (Test-ChatqUsageLimitBlock $Was)) { return $false }
        $uc = Get-ChatqUsageAlertConfig (Get-ChatqConfig)
        if (-not $uc.Reset) { return $false }
        $lane = Get-ChatqLane $Job
        $q = @(Get-ChatqLaneQueued $lane @(Get-ChatqJobs))
        if ($q.Count -lt 2) { return $false }
        $key = "r|$lane|$(Get-ChatqEpochMinutes $Was.Until)"
        $stamp = $Now.ToUniversalTime().ToString('o')
        $go = Use-ChatqUsageAlertState { param($st) if ($st.ContainsKey($key)) { $false } else { $st[$key] = $stamp; $true } } $Now
        if (-not $go) { return $false }
        $d = $script:ChatqDot
        $text = "$(Format-ChatqLane $lane) limit reset $d $($q.Count) queued $d sending #$($Job.seq) now"
        $null = Send-ChatqAlert 'usage' $text 1 -UsageKind reset
        Write-ChatqWatchLog "$lane limit reset with $($q.Count) queued - reset alert sent"
        return $true
    }
    catch { Write-ChatqWatchLog "usage reset alert: $($_.Exception.Message)"; return $false }
}

function Invoke-ChatqReplyWake {
    <#
    Send now, from a soon alert's page: what chatqrun -Now writes, and the
    watcher that reads it is the one that acts - it forgets limits,
    overloads and busy-chat waits, then probes. A lane still limited is
    blocked again by that probe and nothing is typed into any chat
    (Confirm-ChatqAllowed); a chat busy at the PC is deferred again by the
    job's own checks. It picks no mode and queues nothing: the jobs run in
    the modes they were queued with at the PC, so reply.maxMode is not
    involved. Only for an alert the registry says was a soon one - never
    from anything the link says. Returns what the push answers.
    #>
    param($Entry, [datetime]$Now = (Get-Date))
    if ([string](Get-ChatField $Entry 'event') -ne 'usage' -or [string](Get-ChatField $Entry 'usage') -ne 'soon') { return 'Send now is for a usage alert about a reset - nothing done' }
    if ($script:ChatqPhoneWakeAt -and ($Now - $script:ChatqPhoneWakeAt).TotalMinutes -lt 2 -and $Now -ge $script:ChatqPhoneWakeAt) {
        $m = [Math]::Max(1, [int][Math]::Floor(($Now - $script:ChatqPhoneWakeAt).TotalMinutes))
        return "asked $m min ago - the watcher is on it"
    }
    $q = @(Get-ChatqJobs | Where-Object { $_.state -eq 'queued' }).Count
    if (-not $q) { return 'nothing queued - nothing to send' }
    Send-ChatqWake 'now'
    $script:ChatqPhoneWakeAt = $Now
    return "trying the queue now - $q queued; a probe goes first, so nothing is sent while the limit still holds"
}

#endregion

#region phone extras: quiet hours -----------------------------------------------
# A daily window, this PC's clock, when the phone's alerts are held - not
# dropped - except the urgent ones (failed, unless chosen otherwise). The
# toast, your command (told by CHATQ_QUIET=1) and alerts.log go on as ever.
# When the window is over, whoever sees it first - the next alert, the
# watcher's pass, the overlay's once a minute - sends one summary of what
# was held.

function ConvertTo-ChatqClock {
    # 'HH:mm' as a time of day, or $null; -Loose takes 7:00 too
    param([string]$Text, [switch]$Loose)
    $pat = if ($Loose) { '^([01]?\d|2[0-3]):([0-5]\d)$' } else { '^([01]\d|2[0-3]):([0-5]\d)$' }
    if ([string]$Text -notmatch $pat) { return $null }
    return [TimeSpan]::new([int]$Matches[1], [int]$Matches[2], 0)
}

function Get-ChatqQuietHours {
    <#
    config quietHours as @{ From; To; Urgent; Text }, or $null when off. A
    stored value that is not HH:mm, or a window whose from and to are the
    same, reads as off - never as a crash on every alert. Urgent absent is
    failed alone; an empty list is none (the whole phone held).
    #>
    param($Cfg)
    $q = if ($Cfg -and $Cfg.PSObject.Properties['quietHours'] -and $Cfg.quietHours) { $Cfg.quietHours } else { $null }
    if (-not $q) { return $null }
    $from = ConvertTo-ChatqClock ([string](Get-ChatField $q 'from'))
    $to = ConvertTo-ChatqClock ([string](Get-ChatField $q 'to'))
    if ($null -eq $from -or $null -eq $to -or $from -eq $to) { return $null }
    $urgent = if ($q.PSObject.Properties['urgent'] -and $null -ne $q.urgent) { @(@($q.urgent) | ForEach-Object { [string]$_ } | Where-Object { $_ }) } else { @('failed') }
    $f = { param($t) '{0:00}:{1:00}' -f $t.Hours, $t.Minutes }
    [pscustomobject]@{ From = $from; To = $to; Urgent = [string[]]@($urgent); Text = "$(& $f $from)-$(& $f $to)" }
}

function Test-ChatqQuietNow {
    <#
    Is $Now inside the window? @{ In; Until }: Until the next end of the
    window as a date - today's when the time is before it, else tomorrow's.
    Time-of-day comparisons on the local clock, so a DST night makes the
    window an hour shorter or longer and nothing else.
    #>
    param($Qh, [datetime]$Now)
    if (-not $Qh) { return [pscustomobject]@{ In = $false; Until = $null } }
    $t = $Now.TimeOfDay
    $in = if ($Qh.From -lt $Qh.To) { $t -ge $Qh.From -and $t -lt $Qh.To } else { $t -ge $Qh.From -or $t -lt $Qh.To }
    $until = if ($t -lt $Qh.To) { $Now.Date.Add($Qh.To) } else { $Now.Date.AddDays(1).Add($Qh.To) }
    return [pscustomobject]@{ In = [bool]$in; Until = $until }
}

function Test-ChatqQuietIn {
    # quiet hours on, and now inside them
    param($Cfg)
    $qh = Get-ChatqQuietHours $Cfg
    if (-not $qh) { return $false }
    return [bool](Test-ChatqQuietNow $qh (Get-ChatqNow)).In
}

function Test-ChatqHoldAlert {
    <#
    Send-ChatqAlert's quiet-hours step, for the phone channels, after the
    event filter and presence: $true when the alert is held, and then the
    caller returns $false with nothing registered and no window opened. Not
    held: -Loud (a test), what always goes (test, reply, pair, the summary
    itself), an urgent event, anything outside the window - and an alert
    that could not be written down, which is sent instead: a lost alert is
    worse than a woken user.
    #>
    param($Cfg, [string]$Event, [string]$Text, [int]$Priority, $Job, [switch]$Loud)
    if ($Loud -or $Event -in 'summary', 'test', 'reply', 'pair') { return $false }
    $qh = Get-ChatqQuietHours $Cfg
    if (-not $qh) { return $false }
    $q = Test-ChatqQuietNow $qh (Get-ChatqNow)
    if (-not $q.In -or $Event -in $qh.Urgent) { return $false }
    $until = $q.Until.ToString('HH:mm')
    if (Add-ChatqHeldAlert $Event $Text $Priority $Job $q.Until) {
        if ($script:ChatqAlertReport) { $script:ChatqAlertReport.Add("phone: held - quiet hours until $until") }
        $script:ChatqLastAlertError = "quiet hours - held until $until"
        return $true
    }
    if ($script:ChatqAlertReport) { $script:ChatqAlertReport.Add('phone: could not hold (quiet hours) - sent') }
    return $false
}

function Add-ChatqHeldAlert {
    # One held alert, one JSON line in data/held.jsonl, under data/held.lock;
    # 200 at most, the oldest going. $false when it could not be written.
    param([string]$Event, [string]$Text, [int]$Priority, $Job, $Until)
    try {
        $t = Limit-ChatqText ((([string]$Text) -replace '\s+', ' ').Trim()) 300
        $o = [ordered]@{
            at = (Get-ChatqNow).ToUniversalTime().ToString('o'); event = $Event; text = $t; priority = $Priority
            seq = $(if ($Job -and (Get-ChatField $Job 'seq')) { [int](Get-ChatField $Job 'seq') } else { $null })
            title = $(if ($Job -and (Get-ChatField $Job 'title')) { [string](Get-ChatField $Job 'title') } else { $null })
            until = $(if ($Until) { ([datetime]$Until).ToUniversalTime().ToString('o') } else { $null })
        }
        $heldLine = $o | ConvertTo-Json -Compress
        $null = Invoke-ChatqLocked $script:ChatqHeldLockPath {
            $heldLines = @()
            if (Test-Path -LiteralPath $script:ChatqHeldPath) { $heldLines = @([System.IO.File]::ReadAllLines($script:ChatqHeldPath, (New-Object System.Text.UTF8Encoding $false)) | Where-Object { $_.Trim() }) }
            $heldLines = @($heldLines) + $heldLine
            if ($heldLines.Count -gt 200) { $heldLines = @($heldLines | Select-Object -Last 200) }
            [System.IO.File]::WriteAllText($script:ChatqHeldPath, (($heldLines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding $false))
        }
        return $true
    }
    catch { return $false }
}

function Get-ChatqStaleSending {
    # held-*.sending files a sender claimed more than 10 minutes ago and
    # never cleared: it died
    return @(Get-ChildItem -LiteralPath $script:ChatqData -Filter 'held-*.sending' -File -EA SilentlyContinue |
            Where-Object { ((Get-Date) - $_.LastWriteTime).TotalMinutes -gt 10 })
}

function Test-ChatqHeldWaiting {
    # anything held and not yet summed up: cheap, asked on every alert
    if (Test-Path -LiteralPath $script:ChatqHeldPath) { return $true }
    return [bool](@(Get-ChatqStaleSending).Count)
}

function Get-ChatqHeldItems {
    # the held alerts in a file, oldest first; lines that are not JSON skipped
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $n = 0
    $out = foreach ($l in [System.IO.File]::ReadAllLines($Path, (New-Object System.Text.UTF8Encoding $false))) {
        if (-not $l.Trim()) { continue }
        $o = try { $l | ConvertFrom-Json } catch { $null }
        $n++
        # by time, then the file's own order: two held in one second keep theirs
        if ($o -and $o.event) { [pscustomobject]@{ Item = $o; At = [string](ConvertTo-ChatqDate $o.at).ToUniversalTime().ToString('o'); N = $n } }
    }
    return @($out | Sort-Object At, N | ForEach-Object { $_.Item })
}

function Get-ChatqHeldSummaryText {
    <#
    The summary: "held 00:00-07:00: 2 done, 1 needs input", then one line per
    held alert, oldest first - its time, its event, the job's number and its
    text cut to 80 - and one held more than 24 h ago marked (yesterday).
    700 characters at most, whole lines only, the rest counted: "and 4
    more (data/logs/alerts.log)".
    #>
    param([object[]]$Items, $Qh, [datetime]$Now)
    $d = $script:ChatqDot
    $counts = [ordered]@{}
    foreach ($i in $Items) { $e = [string]$i.event; if ($counts.Contains($e)) { $counts[$e]++ } else { $counts[$e] = 1 } }
    $what = (@($counts.GetEnumerator() | ForEach-Object { "$($_.Value) $($_.Key)" }) -join ', ')
    $head = if ($Qh) { "held $($Qh.Text): $what" } else { "held in quiet hours: $what" }
    $lines = @(foreach ($i in $Items) {
            $at = ConvertTo-ChatqDate $i.at
            $time = if ($at) { $at.ToString('HH:mm') } else { '--:--' }
            if ($at -and ($Now - $at).TotalHours -gt 24) { $time += ' (yesterday)' }
            $n = if ($i.seq) { "#$($i.seq) " } else { '' }
            "$time $($i.event) $d $n$(Limit-ChatqText ([string]$i.text) 80 -Ellipsis)"
        })
    $text = $head
    $shown = 0
    foreach ($l in $lines) {
        $left = $lines.Count - $shown - 1
        $tail = if ($left) { "`n$($script:ChatqEllipsis) and $left more (data/logs/alerts.log)" } else { '' }
        if (($text.Length + 1 + $l.Length + $tail.Length) -gt 700) { break }
        $text += "`n$l"
        $shown++
    }
    if ($shown -lt $lines.Count) { $text += "`n$($script:ChatqEllipsis) and $($lines.Count - $shown) more (data/logs/alerts.log)" }
    return $text
}

function Send-ChatqHeldSummary {
    <#
    What quiet hours held, as one push, once they are over. The file is
    claimed under data/held.lock by renaming it to held-<random>.sending,
    so a second sender finds nothing; the push goes outside the lock, as
    'summary' (priority 1, always a phone event, never held, never -Loud:
    at the PC it is the toast). Sent, or shown at the PC, the claim is
    deleted; a push that failed puts its lines back in front of whatever
    was held since, and is tried again 5 minutes later at the soonest
    (-Force: now). A claim older than 10 minutes belongs to a sender that
    died, and comes back. Returns $true when a summary went; never throws.
    #>
    param([switch]$Force)
    if ($script:ChatqSendingSummary) { return $false }
    try {
        if (-not (Test-ChatqHeldWaiting)) { return $false }
        if (-not $Force -and $script:ChatqSummaryTriedAt -and ((Get-Date) - $script:ChatqSummaryTriedAt).TotalMinutes -lt 5) { return $false }
        $now = Get-ChatqNow
        $cfg = Get-ChatqConfig
        $qh = Get-ChatqQuietHours $cfg
        if ($qh -and (Test-ChatqQuietNow $qh $now).In) { return $false }
        $utf = New-Object System.Text.UTF8Encoding $false
        $claim = Invoke-ChatqLocked $script:ChatqHeldLockPath {
            foreach ($old in @(Get-ChatqStaleSending)) {
                $back = @([System.IO.File]::ReadAllLines($old.FullName, $utf) | Where-Object { $_.Trim() })
                $rest = if (Test-Path -LiteralPath $script:ChatqHeldPath) { @([System.IO.File]::ReadAllLines($script:ChatqHeldPath, $utf) | Where-Object { $_.Trim() }) } else { @() }
                [System.IO.File]::WriteAllText($script:ChatqHeldPath, ((@($back) + @($rest)) -join "`n") + "`n", $utf)
                Remove-Item -LiteralPath $old.FullName -Force
            }
            if (-not (Test-Path -LiteralPath $script:ChatqHeldPath)) { return $null }
            $dest = Join-Path $script:ChatqData "held-$(New-ChatqRandomName 8).sending"
            [System.IO.File]::Move($script:ChatqHeldPath, $dest)
            # the claim's age is its own, not the last held alert's
            [System.IO.File]::SetLastWriteTime($dest, (Get-Date))
            $dest
        }
        if (-not $claim) { return $false }
        $items = @(Get-ChatqHeldItems $claim)
        if (-not $items.Count) { Remove-Item -LiteralPath $claim -Force -EA SilentlyContinue; return $false }
        $text = Get-ChatqHeldSummaryText $items $qh $now
        $script:ChatqSendingSummary = $true
        try { $ok = [bool](Send-ChatqAlert 'summary' $text 1) }
        finally { $script:ChatqSendingSummary = $false }
        $shown = $ok -or $script:ChatqLastAlertError -in @('you are at the PC, so the phone was left alone', 'no phone channel set up')
        if ($shown) {
            Remove-Item -LiteralPath $claim -Force -EA SilentlyContinue
            $script:ChatqSummaryTriedAt = $null
            return $true
        }
        $script:ChatqSummaryTriedAt = Get-Date
        try {
            $null = Invoke-ChatqLocked $script:ChatqHeldLockPath {
                $back = @([System.IO.File]::ReadAllLines($claim, $utf) | Where-Object { $_.Trim() })
                $rest = if (Test-Path -LiteralPath $script:ChatqHeldPath) { @([System.IO.File]::ReadAllLines($script:ChatqHeldPath, $utf) | Where-Object { $_.Trim() }) } else { @() }
                [System.IO.File]::WriteAllText($script:ChatqHeldPath, ((@($back) + @($rest)) -join "`n") + "`n", $utf)
                Remove-Item -LiteralPath $claim -Force
            }
        }
        catch {}
        return $false
    }
    catch { return $false }
}

function Update-ChatqHeldKick {
    # The overlay's part, once a minute: quiet hours over with alerts held
    # and no alert or watcher to notice - the outbox's sender is started,
    # which sends the summary first. The overlay's thread sends nothing.
    param($Ctx, [datetime]$Now = (Get-Date))
    try {
        $last = Get-ChatField $Ctx 'HeldKickAt'
        if ($last -and [Math]::Abs(($Now - $last).TotalSeconds) -lt 60) { return }
        $Ctx['HeldKickAt'] = $Now
        if (-not (Test-ChatqHeldWaiting)) { return }
        $qh = Get-ChatqQuietHours (Get-ChatqLiveAlertConfig $Ctx $Now)
        if ($qh -and (Test-ChatqQuietNow $qh (Get-ChatqNow)).In) { return }
        if (Test-ChatqLockHeld $script:ChatqOutboxLockPath) { return }
        if ($null -ne $script:ChatqHeldKickSeam) { & $script:ChatqHeldKickSeam; return }   # tests
        $null = Start-ChatqOutboxSender
        Write-ChatOverlayLog 'phone: quiet hours over with alerts held - the sender started for the summary' -Always
    }
    catch {}
}
$script:ChatqHeldKickSeam = $null

function Update-ChatqPhoneExtras {
    # the overlay's pass, for these features: threshold heads-ups, and the
    # held summary's once-a-minute look. Never throws.
    param($Ctx, [object[]]$Usage, [object[]]$Jobs, [datetime]$Now = (Get-Date))
    Update-ChatqUsageAlerts $Ctx $Usage $Jobs $Now
    Update-ChatqHeldKick $Ctx $Now
}

#endregion

#region phone extras: voice -----------------------------------------------------
# Join's sendPush takes say, "some text out loud", and language for it;
# the phone's text-to-speech reads it on whatever the audio output is, the
# speaker included - which is why nothing is read aloud until join.say
# names the events. The spoken line is short and says what happened, not
# the alert's text: the end of a reply read out in a room is the wrong
# default. ntfy has no speech.

$script:ChatqSayKo = @{
    # the words written as \uXXXX: every .ps1 here is ASCII, since Windows
    # PowerShell 5.1 reads a file with no BOM in the ANSI code page
    'needs input' = [regex]::Unescape('\uC785\uB825\uC744 \uAE30\uB2E4\uB9BD\uB2C8\uB2E4')
    'done'        = [regex]::Unescape('\uB05D\uB0AC\uC2B5\uB2C8\uB2E4')
    'failed'      = [regex]::Unescape('\uC2E4\uD328\uD588\uC2B5\uB2C8\uB2E4')
    'limited'     = [regex]::Unescape('\uD55C\uB3C4\uC5D0 \uAC78\uB838\uC2B5\uB2C8\uB2E4')
    'overloaded'  = [regex]::Unescape('\uACFC\uBD80\uD558')
    'waiting'     = [regex]::Unescape('\uC544\uC9C1 \uC791\uC5C5 \uC911\uC785\uB2C8\uB2E4')
    'started'     = [regex]::Unescape('\uC2DC\uC791\uD588\uC2B5\uB2C8\uB2E4')
    'usage'       = [regex]::Unescape('\uC0AC\uC6A9\uB7C9')
    'percent'     = [regex]::Unescape('\uD37C\uC13C\uD2B8')
    'reset'       = [regex]::Unescape('\uD55C\uB3C4 \uCD08\uAE30\uD654')
    'soon'        = [regex]::Unescape('\uACE7 \uCD08\uAE30\uD654')
    'test'        = [regex]::Unescape('\uD14C\uC2A4\uD2B8')
    'chat'        = [regex]::Unescape('\uCC44\uD305')
}

function Test-ChatqHangul {
    # Hangul syllables, or its jamo
    param([string]$Text)
    return ([string]$Text -match '[\uAC00-\uD7A3\u1100-\u11FF\u3130-\u318F]')
}

function Get-ChatqSayLanguage {
    <#
    join.sayLanguage for a spoken line about this title: auto (the default)
    is ko when the title holds Hangul, else en; en or ko force one; another
    language code (ja, de-DE) is sent as it is, with the English words. A
    value that is no language code reads as auto.
    #>
    param($Cfg, [string]$Title)
    $want = 'auto'
    $j = if ($Cfg -and $Cfg.PSObject.Properties['join'] -and $Cfg.join) { $Cfg.join } else { $null }
    if ($j -and $j.PSObject.Properties['sayLanguage'] -and $j.sayLanguage) {
        $v = ([string]$j.sayLanguage).Trim()
        if ($v -ceq 'auto' -or $v -cmatch '^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$') { $want = $v }
    }
    if ($want -eq 'auto') { if (Test-ChatqHangul $Title) { return 'ko' } else { return 'en' } }
    return $want
}

function Get-ChatqSayText {
    <#
    The spoken line for one alert, @{ Say; Language }, or $null for an event
    that has none. <title> is the job's or chat's, 40 characters at most;
    Korean words for language ko (ko-KR too), English for any other. $Text
    is read only for usage, for its percent. 100 characters at most.
    #>
    param([string]$Event, $Job, [string]$Text, $Cfg)
    $title = if ($Job -and (Get-ChatField $Job 'title')) { Limit-ChatqText ((([string](Get-ChatField $Job 'title')) -replace '\s+', ' ').Trim()) 40 } else { '' }
    $lang = Get-ChatqSayLanguage $Cfg $title
    $ko = $lang -match '^ko(-|$)'
    $k = $script:ChatqSayKo
    $t = if ($title) { $title } elseif ($ko) { $k['chat'] } else { 'a chat' }
    $pv = if ($Job -and (Get-ChatField $Job 'provider')) { [string](Get-ChatField $Job 'provider') } else { 'claude' }
    $prov = (Get-Culture).TextInfo.ToTitleCase($pv.ToLower())
    $say = switch -Exact ($Event) {
        'needs input' { if ($ko) { "$t $($k['needs input'])" } else { "$t needs input" } }
        'done' { if ($ko) { "$t $($k['done'])" } else { "$t is done" } }
        'failed' { if ($ko) { "$t $($k['failed'])" } else { "$t failed" } }
        'limited' { if ($ko) { "$t $($k['limited'])" } else { "$t hit the limit" } }
        'overloaded' { if ($ko) { "$prov $($k['overloaded'])" } else { "$prov is overloaded" } }
        'waiting' { if ($ko) { "$t $($k['waiting'])" } else { "$t is still busy" } }
        'started' { if ($ko) { "$t $($k['started'])" } else { "$t started" } }
        'test' { if ($ko) { "chatq $($k['test'])" } else { 'chatq test' } }
        'usage' {
            $who = if ([string]$Text -match '^(Claude|Codex)\b') { $Matches[1] } else { 'Claude' }
            if ([string]$Text -match '\b(\d{1,3})%') { if ($ko) { "$who $($k['usage']) $($Matches[1])$($k['percent'])" } else { "$who usage at $($Matches[1]) percent" } }
            elseif ([string]$Text -match '\blimit reset\b') { if ($ko) { "$who $($k['reset'])" } else { "$who limit reset" } }
            elseif ($ko) { "$who $($k['soon'])" }
            else { "$who limit resets soon" }
        }
        default { $null }
    }
    if (-not $say) { return $null }
    return [pscustomobject]@{ Say = (Limit-ChatqText $say 100); Language = $lang }
}

function Get-ChatqJoinSay {
    # The spoken line Send-ChatqJoin adds, or $null: only an event in
    # join.say, never the summary, a reply or the pairing push
    param($Cfg, [string]$Event, $Job, [string]$Text)
    if (-not $Event -or $Event -in 'summary', 'reply', 'pair') { return $null }
    $j = if ($Cfg -and $Cfg.PSObject.Properties['join'] -and $Cfg.join) { $Cfg.join } else { $null }
    if (-not ($j -and $j.PSObject.Properties['say'] -and $null -ne $j.say)) { return $null }
    if ($Event -notin @(@($j.say) | ForEach-Object { [string]$_ })) { return $null }
    return (Get-ChatqSayText $Event $Job $Text $Cfg)
}

#endregion

#region phone extras: settings --------------------------------------------------
# What chatnotify and the setup window change, through Set-ChatqNotifyConfig:
# its keys UsageAlerts, UsageAt, UsageReset, QuietHours, Urgent, Say and
# SayLanguage are read here with every other check - so a bad value saves
# nothing at all - and put into the config just before it is saved.

function Read-ChatqNotifyExtras {
    <#
    The extras' keys of a Set-ChatqNotifyConfig call, checked: @{ Error;
    UsageAlerts; UsageAt; UsageReset; QuietHours; Urgent; Say; SayLanguage },
    each $null when not asked for. QuietHours is 'off' or @{ From; To } as
    HH:mm; Urgent and Say an array, empty for none. $Msgs is the caller's
    list of @{ Text; Color }.
    #>
    param([hashtable]$Ch, $Msgs, $Cfg)
    $r = [pscustomobject]@{ Error = $null; UsageAlerts = $null; UsageAt = $null; UsageReset = $null; QuietHours = $null; Urgent = $null; Say = $null; SayLanguage = $null }
    $bad = { param($t, $e) $Msgs.Add([pscustomobject]@{ Text = $t; Color = 'Yellow' }); $r.Error = $e; $r }
    $onOff = {
        param($n)
        $v = $Ch[$n]
        if ($v -is [bool]) { return $v }
        switch (([string]$v).Trim().ToLower()) { 'on' { $true } 'off' { $false } default { $null } }
    }
    $has = { param($n) $Ch.ContainsKey($n) -and $null -ne $Ch[$n] -and '' -ne $Ch[$n] }
    foreach ($n in 'UsageAlerts', 'UsageReset') {
        if (& $has $n) {
            $v = & $onOff $n
            if ($null -eq $v) { return (& $bad "-$n takes on or off, not '$($Ch[$n])'" "bad $n value") }
            $r.$n = $v
        }
    }
    if (& $has 'UsageAt') {
        $p = ConvertTo-ChatqUsageThresholds $Ch['UsageAt']
        if (-not $p) { return (& $bad 'usage thresholds: up to three whole percents from 1 to 99' 'bad usage thresholds') }
        $r.UsageAt = @($p)
    }
    if (& $has 'QuietHours') {
        $v = ([string]$Ch['QuietHours']).Trim()
        if ($v -eq 'off') { $r.QuietHours = 'off' }
        else {
            $m = [regex]::Match($v, '^\s*(\d{1,2}:\d{2})\s*-\s*(\d{1,2}:\d{2})\s*$')
            $from = if ($m.Success) { ConvertTo-ChatqClock $m.Groups[1].Value -Loose } else { $null }
            $to = if ($m.Success) { ConvertTo-ChatqClock $m.Groups[2].Value -Loose } else { $null }
            if ($null -eq $from -or $null -eq $to) { return (& $bad 'quiet hours: HH:mm-HH:mm, like 00:00-07:00, or off' 'bad quiet hours') }
            if ($from -eq $to) { return (& $bad 'quiet hours: from and to cannot be the same time' 'bad quiet hours') }
            $f = { param($t) '{0:00}:{1:00}' -f $t.Hours, $t.Minutes }
            $r.QuietHours = [pscustomobject]@{ From = (& $f $from); To = (& $f $to) }
        }
    }
    $names = { param($v) @(@($v) | ForEach-Object { [string]$_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    if ($Ch.ContainsKey('Urgent') -and $null -ne $Ch['Urgent']) {
        $list = & $names $Ch['Urgent']
        $r.Urgent = @()
        if (-not (@($list | Where-Object { $_ -eq 'none' }).Count -and $list.Count -eq 1)) {
            foreach ($n in $list) {
                $want = ConvertTo-ChatqEventName $n
                if ($want -notin $script:ChatqPhoneEvents) { return (& $bad "no event '$n' - these are: none, $($script:ChatqPhoneEvents -join ', ')" "no event '$n'") }
                if ($want -notin $r.Urgent) { $r.Urgent += $want }
            }
        }
    }
    if ($Ch.ContainsKey('Say') -and $null -ne $Ch['Say']) {
        $list = & $names $Ch['Say']
        $r.Say = @()
        if (-not (@($list | Where-Object { $_ -eq 'none' }).Count -and $list.Count -eq 1)) {
            $can = @($script:ChatqPhoneEvents) + 'test'
            foreach ($n in $list) {
                $want = ConvertTo-ChatqEventName $n
                if ($want -notin $can) { return (& $bad "no event '$n' - these are: none, $($can -join ', ')" "no event '$n'") }
                if ($want -notin $r.Say) { $r.Say += $want }
            }
            $joinNow = ($Cfg.PSObject.Properties['join'] -and $Cfg.join -and $Cfg.join.apiKey) -and -not ($Ch.ContainsKey('RemoveJoin') -and $Ch['RemoveJoin'])
            $joinNew = $Ch.ContainsKey('ApiKey') -and ([string]$Ch['ApiKey']).Trim()
            if (-not ($joinNow -or $joinNew)) { return (& $bad "reading aloud is Join's - set up Join first (chatnotify -Setup, or -ApiKey)" 'no Join') }
        }
    }
    if (& $has 'SayLanguage') {
        $v = ([string]$Ch['SayLanguage']).Trim()
        if ($v -cne 'auto' -and $v -cnotmatch '^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$') { return (& $bad "the spoken language: auto, en, ko or a language code like de-DE, not '$v'" 'bad language') }
        $r.SayLanguage = $v
    }
    return $r
}

function Set-ChatqNotifyExtras {
    # Read-ChatqNotifyExtras's answer into the config object, with the lines
    # that say so. Returns $true when anything changed. Nothing is saved here.
    param($Cfg, $X, $Msgs)
    $say = { param($t, $c) $Msgs.Add([pscustomobject]@{ Text = $t; Color = $c }) }
    $changed = $false
    $d = $script:ChatqDot
    if ($null -ne $X.UsageAlerts -or $null -ne $X.UsageAt -or $null -ne $X.UsageReset) {
        $u = if ($Cfg.PSObject.Properties['usage'] -and $Cfg.usage) { $Cfg.usage } else { [pscustomobject]@{} }
        if ($null -ne $X.UsageAlerts) { Set-ChatqProp $u 'alerts' ([bool]$X.UsageAlerts) }
        if ($null -ne $X.UsageAt) { Set-ChatqProp $u 'at' @($X.UsageAt) }
        if ($null -ne $X.UsageReset) { Set-ChatqProp $u 'reset' ([bool]$X.UsageReset) }
        Set-ChatqProp $Cfg 'usage' $u
        $changed = $true
        $uc = Get-ChatqUsageAlertConfig $Cfg
        if ($null -ne $X.UsageAlerts -or $null -ne $X.UsageAt) {
            if ($uc.Alerts) { & $say "usage heads-ups at $((@($uc.At) | ForEach-Object { "$_%" }) -join ', ') of a 5-hour or weekly window" 'Green' }
            else { & $say 'usage heads-ups off' 'Green' }
        }
        if ($null -ne $X.UsageReset) {
            if ($uc.Reset) { & $say "resets: an alert $($uc.SoonMinutes) min before one with prompts queued, and when it happens" 'Green' }
            else { & $say 'resets: no alerts' 'Green' }
        }
        if ($uc.Alerts -and -not (Test-ChatqPhoneEvent $Cfg 'usage')) { & $say "usage heads-ups are on, but 'usage' is not among the phone's events" 'Yellow' }
    }
    if ($null -ne $X.QuietHours -or $null -ne $X.Urgent) {
        $q = if ($Cfg.PSObject.Properties['quietHours'] -and $Cfg.quietHours) { $Cfg.quietHours } else { $null }
        if ($X.QuietHours -is [string] -and $X.QuietHours -eq 'off') {
            if ($Cfg.PSObject.Properties['quietHours']) { $Cfg.PSObject.Properties.Remove('quietHours') }
            $q = $null
            & $say 'quiet hours off' 'Green'
        }
        elseif ($X.QuietHours) {
            if (-not $q) { $q = [pscustomobject]@{} }
            Set-ChatqProp $q 'from' $X.QuietHours.From
            Set-ChatqProp $q 'to' $X.QuietHours.To
        }
        if ($null -ne $X.Urgent) {
            if (-not $q) { $q = [pscustomobject]@{} }
            Set-ChatqProp $q 'urgent' @($X.Urgent)
        }
        if ($q) { Set-ChatqProp $Cfg 'quietHours' $q }
        $changed = $true
        $qh = Get-ChatqQuietHours $Cfg
        if ($qh) {
            $through = if (@($qh.Urgent).Count) { "$(@($qh.Urgent) -join ', ') still comes through" } else { 'nothing comes through' }
            & $say "quiet hours $($qh.Text) (this PC's clock) $d $through $d the rest in one summary at $($qh.Text.Split('-')[1])" 'Green'
        }
        elseif ($null -ne $X.Urgent -and -not ($X.QuietHours -is [string])) {
            & $say 'saved - quiet hours are off (-QuietHours 00:00-07:00 turns them on)' 'DarkGray'
        }
    }
    if ($null -ne $X.Say -or $null -ne $X.SayLanguage) {
        $j = if ($Cfg.PSObject.Properties['join'] -and $Cfg.join) { $Cfg.join } else { $null }
        if ($j) {
            if ($null -ne $X.Say) {
                if (@($X.Say).Count) { Set-ChatqProp $j 'say' @($X.Say) }
                elseif ($j.PSObject.Properties['say']) { $j.PSObject.Properties.Remove('say') }
            }
            if ($null -ne $X.SayLanguage) {
                if ($X.SayLanguage -eq 'auto') { if ($j.PSObject.Properties['sayLanguage']) { $j.PSObject.Properties.Remove('sayLanguage') } }
                else { Set-ChatqProp $j 'sayLanguage' $X.SayLanguage }
            }
            $changed = $true
            $list = if ($j.PSObject.Properties['say'] -and $null -ne $j.say) { @(@($j.say) | ForEach-Object { [string]$_ }) } else { @() }
            $lang = if ($j.PSObject.Properties['sayLanguage'] -and $j.sayLanguage) { [string]$j.sayLanguage } else { 'auto' }
            $how = if ($lang -eq 'auto') { 'auto - Korean for a Hangul title' } else { $lang }
            if ($list.Count) {
                & $say "read aloud on the phone: $($list -join ', ') (language: $how)" 'Green'
                foreach ($e in $list) {
                    if ($e -ne 'test' -and -not (Test-ChatqPhoneEvent $Cfg $e)) { & $say "$e is not among the phone's events - it is never read aloud until it is (-Events)" 'Yellow' }
                }
                & $say "Join speaks through the phone's speaker as well as headphones" 'DarkGray'
            }
            elseif ($null -ne $X.Say) { & $say 'nothing is read aloud on the phone' 'Green' }
            else { & $say "the spoken language: $how" 'Green' }
        }
    }
    return $changed
}

function Complete-ChatqNotifyExtras {
    # After the save: quiet hours switched off with alerts held sends the
    # summary now, from chatnotify itself
    param($X, $Msgs)
    if (-not ($X -and $X.QuietHours -is [string] -and $X.QuietHours -eq 'off')) { return }
    if (-not (Test-ChatqHeldWaiting)) { return }
    $ok = Send-ChatqHeldSummary -Force
    $t = if ($ok) { 'what quiet hours held went as one summary' } else { "what quiet hours held did not go yet: $($script:ChatqLastAlertError) - it goes with the next alert" }
    $Msgs.Add([pscustomobject]@{ Text = $t; Color = $(if ($ok) { 'Green' } else { 'Yellow' }) })
}

function Get-ChatqNotifyExtrasStatus {
    # chatnotify's status lines for these features, as @{ Text; Color }
    param($Cfg)
    $d = $script:ChatqDot
    $out = [System.Collections.Generic.List[object]]::new()
    $add = { param($t, $c = 'DarkGray') $out.Add([pscustomobject]@{ Text = $t; Color = $c }) }
    $uc = Get-ChatqUsageAlertConfig $Cfg
    $ut = if ($uc.Alerts) { "at $((@($uc.At) | ForEach-Object { "$_%" }) -join ', ') (the overlay checks)" } else { 'heads-ups off' }
    if ($uc.Alerts) {
        if (-not $script:ChatqIsWindows) { $ut += ' - only the Windows overlay checks' }
        elseif (-not (Test-ChatqLockHeld $script:ChatOverlayLockPath)) { $ut += ' - the overlay is not running, so none go now (chatoverlay)' }
    }
    & $add "usage    $ut $d resets $(if ($uc.Reset) { 'on' } else { 'off' })"
    if (($uc.Alerts -or $uc.Reset) -and -not (Test-ChatqPhoneEvent $Cfg 'usage')) { & $add "    usage heads-ups are on, but 'usage' is not among the phone's events" 'Yellow' }
    $qh = Get-ChatqQuietHours $Cfg
    $held = @()
    try { $held = @(Get-ChatqHeldItems $script:ChatqHeldPath) } catch {}
    if ($qh) {
        $through = if (@($qh.Urgent).Count) { "$(@($qh.Urgent) -join ', ') comes through" } else { 'nothing comes through' }
        $t = "quiet    $($qh.Text) $d $through"
        $q = Test-ChatqQuietNow $qh (Get-ChatqNow)
        if ($q.In) { $t += " $d now until $($q.Until.ToString('HH:mm')) $d $($held.Count) held" }
        & $add $t
    }
    if ($held.Count -and -not ($qh -and (Test-ChatqQuietNow $qh (Get-ChatqNow)).In)) {
        $first = ConvertTo-ChatqDate $held[0].at
        & $add "    $($held.Count) held since $(if ($first) { $first.ToString('HH:mm') }) - the summary goes with the next alert" 'Yellow'
    }
    $j = if ($Cfg.PSObject.Properties['join'] -and $Cfg.join) { $Cfg.join } else { $null }
    $list = if ($j -and $j.PSObject.Properties['say'] -and $null -ne $j.say) { @(@($j.say) | ForEach-Object { [string]$_ }) } else { @() }
    if ($list.Count) {
        $lang = if ($j.PSObject.Properties['sayLanguage'] -and $j.sayLanguage) { [string]$j.sayLanguage } else { 'auto' }
        & $add "voice    $($list -join ', ') $d language $lang"
    }
    return $out.ToArray()
}

function Write-ChatqNotifyExtrasStatus {
    param($Cfg)
    foreach ($m in @(Get-ChatqNotifyExtrasStatus $Cfg)) { Write-Host "  $($m.Text)" -ForegroundColor $m.Color }
}

#endregion

#region phone extras: the setup window ------------------------------------------
# The controls these features add to chatnotify -Setup's window, in its
# markup (src/phone-setup.ps1): Read aloud under Send test; quiet hours
# after the quiet-minutes row; the usage and reset boxes before the toast.
# Wired, filled, compared and turned into changes here, with the same keys
# chatnotify's switches use.

function Initialize-ChatqPhoneSetupExtras {
    # the controls found, the event boxes made, and every one wired
    param($U)
    foreach ($n in 'SayPanel', 'SayNote', 'QuietHoursBox', 'QuietFromBox', 'QuietToBox', 'UrgentPanel', 'UsageBox', 'UsageAtBox', 'ResetBox') { $U[$n] = $U.Win.FindName($n) }
    if (-not $U.SayPanel) { return }
    $U.UsageWas = $true; $U.UsageAtWas = '90'; $U.ResetWas = $true
    $U.QuietWasOn = $false; $U.QuietFromWas = '00:00'; $U.QuietToWas = '07:00'; $U.UrgentWas = 'failed'; $U.SayWas = ''
    $tick = { param($src, $e) Invoke-ChatqPhoneSetupAction $src { param($U) Update-ChatqPhoneSetupExtrasEnabled $U; Update-ChatqPhoneSetupDirty $U } }
    $mk = {
        param($Panel, [string]$Ev, [string]$Tip)
        $cb = [System.Windows.Controls.CheckBox]::new()
        $cb.Content = $Ev
        $cb.Tag = $Ev
        $cb.Margin = [System.Windows.Thickness]::new(0, 3, 16, 3)
        $cb.ToolTip = $Tip
        $cb.add_Click($tick)
        [void]$Panel.Children.Add($cb)
    }
    foreach ($ev in $script:ChatqPhoneEvents) { & $mk $U.UrgentPanel $ev "Send '$ev' alerts to the phone during quiet hours all the same" }
    foreach ($ev in @($script:ChatqPhoneEvents) + 'test') { & $mk $U.SayPanel $ev "Join reads '$ev' alerts out loud on the phone" }
    foreach ($b in $U.QuietHoursBox, $U.UsageBox, $U.ResetBox) { $b.add_Click($tick) }
    foreach ($b in $U.QuietFromBox, $U.QuietToBox, $U.UsageAtBox) {
        $b.add_TextChanged({ param($src, $e) Invoke-ChatqPhoneSetupAction $src { param($U) Update-ChatqPhoneSetupDirty $U } })
    }
    # an event ticked or not above decides which of these can be ticked
    foreach ($cb in $U.EventsPanel.Children) { $cb.add_Click($tick) }
    $U.KeyBox.add_PasswordChanged({ param($src, $e) Invoke-ChatqPhoneSetupAction $src { param($U) Update-ChatqPhoneSetupExtrasEnabled $U } })
    $U.UsageBox.ToolTip = 'A heads-up when a 5-hour or weekly window reaches this much - from the overlay'
    $U.UsageAtBox.ToolTip = '90, or up to three: 75, 90'
    $U.ResetBox.ToolTip = 'Ten minutes before a limit resets with prompts queued - with Send now - and when it does'
    $U.QuietHoursBox.ToolTip = 'Phone alerts wait until the end, then come as one summary; the toast and your command still run'
    $U.QuietFromBox.ToolTip = 'From, 24-hour: 00:00'
    $U.QuietToBox.ToolTip = 'To, 24-hour: 07:00'
}

function Read-ChatqPhoneSetupExtras {
    # the controls from config.json, and what they were, to compare against
    param($U, $Cfg)
    if (-not $U.SayPanel) { return }
    $uc = Get-ChatqUsageAlertConfig $Cfg
    $U.UsageWas = [bool]$uc.Alerts
    $U.UsageBox.IsChecked = $U.UsageWas
    $U.UsageAtWas = (@($uc.At) -join ', ')
    $U.UsageAtBox.Text = $U.UsageAtWas
    $U.ResetWas = [bool]$uc.Reset
    $U.ResetBox.IsChecked = $U.ResetWas
    $qh = Get-ChatqQuietHours $Cfg
    $U.QuietWasOn = [bool]$qh
    $U.QuietHoursBox.IsChecked = $U.QuietWasOn
    $U.QuietFromWas = if ($qh) { $qh.Text.Split('-')[0] } else { '00:00' }
    $U.QuietToWas = if ($qh) { $qh.Text.Split('-')[1] } else { '07:00' }
    $U.QuietFromBox.Text = $U.QuietFromWas
    $U.QuietToBox.Text = $U.QuietToWas
    $raw = if ($Cfg.PSObject.Properties['quietHours'] -and $Cfg.quietHours -and $Cfg.quietHours.PSObject.Properties['urgent'] -and $null -ne $Cfg.quietHours.urgent) { @(@($Cfg.quietHours.urgent) | ForEach-Object { [string]$_ }) } else { @('failed') }
    foreach ($cb in $U.UrgentPanel.Children) { $cb.IsChecked = $raw -contains [string]$cb.Tag }
    $U.UrgentWas = Get-ChatqPhoneSetupTicked $U.UrgentPanel
    $j = if ($Cfg.PSObject.Properties['join'] -and $Cfg.join) { $Cfg.join } else { $null }
    $said = if ($j -and $j.PSObject.Properties['say'] -and $null -ne $j.say) { @(@($j.say) | ForEach-Object { [string]$_ }) } else { @() }
    foreach ($cb in $U.SayPanel.Children) { $cb.IsChecked = $said -contains [string]$cb.Tag }
    $U.SayWas = Get-ChatqPhoneSetupTicked $U.SayPanel
    Update-ChatqPhoneSetupExtrasEnabled $U
}

function Get-ChatqPhoneSetupTicked {
    # the events ticked in a panel, in its order, joined; -Usable: only the
    # boxes that can be ticked now
    param($Panel, [switch]$Usable)
    return (@($Panel.Children | Where-Object { $_.IsChecked -and (-not $Usable -or $_.IsEnabled) } | ForEach-Object { [string]$_.Tag }) -join ',')
}

function Update-ChatqPhoneSetupExtrasEnabled {
    # Which controls can be used: the times and still-send boxes with quiet
    # hours ticked, and only for an event the phone gets; read aloud with a
    # Join key, saved or pasted, and again only for an event the phone gets
    # (and test); the thresholds with usage ticked. What is ticked is kept
    # either way, so ticking again brings it back.
    param($U)
    if (-not $U.SayPanel) { return }
    $on = @($U.EventsPanel.Children | Where-Object { $_.IsChecked } | ForEach-Object { [string]$_.Tag })
    $quiet = [bool]$U.QuietHoursBox.IsChecked
    $U.QuietFromBox.IsEnabled = $quiet
    $U.QuietToBox.IsEnabled = $quiet
    foreach ($cb in $U.UrgentPanel.Children) { $cb.IsEnabled = $quiet -and ($on -contains [string]$cb.Tag) }
    $join = [bool]($U.HasKey -or ([string]$U.KeyBox.Password).Trim())
    $U.SayPanel.IsEnabled = $join
    foreach ($cb in $U.SayPanel.Children) { $cb.IsEnabled = [string]$cb.Tag -eq 'test' -or ($on -contains [string]$cb.Tag) }
    $U.UsageAtBox.IsEnabled = [bool]$U.UsageBox.IsChecked
    $lost = @($U.SayPanel.Children | Where-Object { $_.IsChecked -and -not $_.IsEnabled })
    $note = if (-not $join) { 'Needs Join - paste its key above.' }
    elseif ($lost.Count) { "Ticked but not among the events below, so left out on Save: $(@($lost | ForEach-Object { [string]$_.Tag }) -join ', ')." }
    else { 'Join speaks it on the phone - through its speaker too, if no headphones are in.' }
    Set-ChatqPhoneSetupNote $U $U.SayNote $note $(if ($lost.Count -and $join) { 'warn' } else { 'dim' })
}

function Get-ChatqPhoneSetupExtrasSnapshot {
    # these controls as one string, for the form's unsaved check
    param($U)
    if (-not $U.SayPanel) { return '' }
    return (@([bool]$U.UsageBox.IsChecked, $U.UsageAtBox.Text.Trim(), [bool]$U.ResetBox.IsChecked, [bool]$U.QuietHoursBox.IsChecked,
            $U.QuietFromBox.Text.Trim(), $U.QuietToBox.Text.Trim(), (Get-ChatqPhoneSetupTicked $U.UrgentPanel), (Get-ChatqPhoneSetupTicked $U.SayPanel)) -join "`n")
}

function Add-ChatqPhoneSetupExtrasChanges {
    <#
    What Save hands Set-ChatqNotifyConfig for these controls, added to $C -
    only what differs from the file. Returns the error that blocks Save, or
    $null: a threshold that is not one to three whole percents, a time that
    is not one, or the same time twice.
    #>
    param($U, [hashtable]$C)
    if (-not $U.SayPanel) { return $null }
    $usage = [bool]$U.UsageBox.IsChecked
    if ($usage -ne $U.UsageWas) { $C.UsageAlerts = $usage }
    $at = $U.UsageAtBox.Text.Trim()
    if ($usage -or $at -ne $U.UsageAtWas) {
        $p = ConvertTo-ChatqUsageThresholds $at
        if (-not $p) { if ($usage) { return 'Usage: up to three whole percents from 1 to 99.' } }
        elseif ((@($p) -join ', ') -ne $U.UsageAtWas) { $C.UsageAt = (@($p) -join ',') }
    }
    $reset = [bool]$U.ResetBox.IsChecked
    if ($reset -ne $U.ResetWas) { $C.UsageReset = $reset }
    if ([bool]$U.QuietHoursBox.IsChecked) {
        $from = ConvertTo-ChatqClock $U.QuietFromBox.Text.Trim() -Loose
        $to = ConvertTo-ChatqClock $U.QuietToBox.Text.Trim() -Loose
        if ($null -eq $from -or $null -eq $to -or $from -eq $to) { return 'Quiet hours: times like 07:00, and not the same twice.' }
        $f = { param($t) '{0:00}:{1:00}' -f $t.Hours, $t.Minutes }
        $win = "$(& $f $from)-$(& $f $to)"
        if (-not $U.QuietWasOn -or $win -ne "$($U.QuietFromWas)-$($U.QuietToWas)") { $C.QuietHours = $win }
        $urgent = Get-ChatqPhoneSetupTicked $U.UrgentPanel -Usable
        if ($urgent -ne $U.UrgentWas) { $C.Urgent = if ($urgent) { [string[]]($urgent -split ',') } else { 'none' } }
    }
    elseif ($U.QuietWasOn) { $C.QuietHours = 'off' }
    if ($U.SayPanel.IsEnabled) {
        $said = Get-ChatqPhoneSetupTicked $U.SayPanel -Usable
        if ($said -ne $U.SayWas) { $C.Say = if ($said) { [string[]]($said -split ',') } else { 'none' } }
    }
    return $null
}

#endregion
