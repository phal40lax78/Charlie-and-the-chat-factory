# Charlie-and-the-chat-factory, src/auto-continue.ps1: dot-sourced by
# Charlie-and-the-chat-factory.ps1 in its turn, never on its own - see the list there.

#region auto-continue: settings, markers, states -----------------------------
# config autoContinue "on", the mode you choose: a chat the usage limit cut
# off gets "Continue from where you left off." queued for it by itself, a
# minute after the limit resets. The default, "ask", waits for your word
# instead (Get-ChatqResetAsk, in src/queue.ps1); "off" only marks the chats.
# Each chat can also be set to always or never, whatever the switch says
# (docs/auto-continue-spec.md). The overlay scans once a minute, the watcher
# every 5 minutes while it runs; nothing else ever queues one. Only for chats
# chatq did not start: a prompt you queued that the limit cuts off mid-run
# comes back as a continue anyway, whatever the switch says.
# Both modes keep one marker per cut-off in data/auto (Get-ChatqCutKey): the
# ask's answer or this mode's job, so neither acts on a cut-off the other
# already has.
# This file stays pure ASCII, as every .ps1 here does (see src/queue.ps1).

$script:ChatqAutoPath = Join-Path $script:ChatqData 'auto-continue.json'
# held while that file is read, changed and saved (Update-ChatqAutoState)
$script:ChatqAutoLockPath = Join-Path $script:ChatqData 'auto-continue.lock'
# a chat open in a VS Code panel: the run waits this long past the reset, so
# the panel's own auto-continue - if it has one (spike A1: none was seen on
# 2.1.282-2.1.283, but no controlled run has settled it) - can go first
$script:ChatqAutoHoldMinutes = 5
# a cut-off older than this, or whose reset is further than this past it,
# is left to you - a weekly limit days out, as Claude Code leaves it
$script:ChatqAutoMaxAgeHours = 12
$script:ChatqAutoMaxResetHours = 24
# first seen this long after its reset: you came back to it, it is yours
$script:ChatqAutoLateMinutes = 30
# auto-continues in a row that failed before it stops trying - Claude Code's
# own wait gives up after the same number
$script:ChatqAutoStreakCap = 2
$script:ChatqAutoMarkerDays = 8
# Get-ChatqAutoConfig's copy, and which cut-offs were said not to be queued
# already (once each per process, not once a minute)
$script:ChatqAutoCache = $null
$script:ChatqAutoSaid = @{}

function Get-ChatqAutoStamp {
    # a file's write time and length, 0 when it is not there
    param([string]$Path)
    try {
        $f = [System.IO.FileInfo]::new($Path)
        if (-not $f.Exists) { return '0' }
        return "$($f.LastWriteTimeUtc.Ticks)|$($f.Length)"
    }
    catch { return '-1' }
}

function Get-ChatqAutoConfig {
    <#
    config.json's autoContinue - Mode, on / ask / off (Get-ChatqAutoContinue),
    and On when it is on - and data/auto-continue.json: since, the chats set
    to always or never, the streak of failed auto-continues per chat, and
    whether the notices were shown. Read again only when either file's
    write time moved: the overlay asks every pass.
    #>
    param([switch]$Fresh)
    $sig = "$(Get-ChatqAutoStamp $script:ChatqConfigPath)|$(Get-ChatqAutoStamp $script:ChatqAutoPath)|$script:ChatqAutoPath"
    $c = $script:ChatqAutoCache
    if (-not $Fresh -and $c -and $c.Sig -eq $sig) { return $c.Value }
    $mode = Get-ChatqAutoContinue (Get-ChatqConfig)
    $st = Read-ChatqJson $script:ChatqAutoPath
    $get = { param($n) if ($st -and $st.PSObject.Properties[$n]) { $st.$n } else { $null } }
    $chats = @{}
    $cs = & $get 'chats'
    if ($cs) {
        foreach ($p in $cs.PSObject.Properties) {
            $a = [string](Get-ChatField $p.Value 'auto')
            if ($a -in 'always', 'never') {
                $chats[$p.Name] = [pscustomobject]@{ auto = $a; at = [string](Get-ChatField $p.Value 'at'); title = [string](Get-ChatField $p.Value 'title') }
            }
        }
    }
    $streak = @{}
    $ss = & $get 'streak'
    if ($ss) {
        foreach ($p in $ss.PSObject.Properties) {
            # a bare number is the spec's first shape; { n, uuid } says which
            # cut-off the last failure left, so a turn in between starts over
            if ($p.Value -is [ValueType]) { $streak[$p.Name] = [pscustomobject]@{ n = [int]$p.Value; uuid = $null } }
            elseif ($p.Value) { $streak[$p.Name] = [pscustomobject]@{ n = [int](Get-ChatField $p.Value 'n'); uuid = [string](Get-ChatField $p.Value 'uuid') } }
        }
    }
    $v = [pscustomobject]@{
        Mode = $mode; On = ($mode -eq 'on'); Since = (ConvertTo-ChatqDate (& $get 'since')); Chats = $chats; Streak = $streak
        Noticed = [bool](& $get 'noticed'); Told = [bool](& $get 'told'); Exists = [bool]$st
    }
    $script:ChatqAutoCache = @{ Sig = $sig; Value = $v }
    return $v
}

function Test-ChatqAutoWanted {
    # anything for the scan to queue: the switch on, or one chat set to always
    param($Config)
    if (-not $Config) { $Config = Get-ChatqAutoConfig }
    if ($Config.On) { return $true }
    foreach ($k in @($Config.Chats.Keys)) { if ($Config.Chats[$k].auto -eq 'always') { return $true } }
    return $false
}

function Save-ChatqAutoState {
    # data/auto-continue.json, whole, from what Get-ChatqAutoConfig gave
    param($Value)
    $chats = [ordered]@{}
    foreach ($k in @($Value.Chats.Keys | Sort-Object)) {
        $x = $Value.Chats[$k]
        $chats[$k] = [ordered]@{ auto = [string]$x.auto; at = [string]$x.at; title = [string]$x.title }
    }
    $streak = [ordered]@{}
    foreach ($k in @($Value.Streak.Keys | Sort-Object)) {
        $x = $Value.Streak[$k]
        $streak[$k] = [ordered]@{ n = [int]$x.n; uuid = $(if ($x.uuid) { [string]$x.uuid } else { $null }) }
    }
    $o = [ordered]@{
        v = 1; since = $(if ($Value.Since) { ([datetime]$Value.Since).ToUniversalTime().ToString('o') } else { $null })
        noticed = [bool]$Value.Noticed; told = [bool]$Value.Told; chats = $chats; streak = $streak
    }
    Save-ChatqJson $script:ChatqAutoPath ([pscustomobject]$o)
    $script:ChatqAutoCache = $null
}

function Update-ChatqAutoState {
    # Read, changed by -Change, written back, all holding
    # data/auto-continue.lock; the new value is returned. The overlay, the
    # watcher and a shell all write it, and one's save between another's read
    # and save dropped that change: the streak that stops auto-continue after
    # 2 failures went back, or a chat set to never was forgotten. Throws when
    # the lock cannot be had within 3 s (Invoke-ChatqLocked).
    param([scriptblock]$Change)
    # odd names: -Change runs below here, and reads its caller's variables
    $autoStateChange = $Change
    Invoke-ChatqLocked $script:ChatqAutoLockPath {
        $autoStateNow = Get-ChatqAutoConfig -Fresh
        & $autoStateChange $autoStateNow
        Save-ChatqAutoState $autoStateNow
    }
    return (Get-ChatqAutoConfig -Fresh)
}

function Reset-ChatqAutoSince {
    # Set-ChatqAutoContinue, as the switch turns to on: from now. A cut-off
    # from before it is shown, never queued - choosing on is no reason to
    # send a batch of continues into chats cut off hours ago. Never throws.
    try { $null = Update-ChatqAutoState { param($v) $v.Since = (Get-Date) } } catch {}
}

function Get-ChatqCutId {
    # A cut-off's identity past its chat, as its job's cutUuid keeps it: the
    # part of its marker's name (Get-ChatqCutKey) after the session id - the
    # limit record's uuid, which nothing rewrites (spike A3: a record copied
    # keeps it), or its time where it has none. $null when there is no key.
    param($Row)
    $k = Get-ChatqCutKey $Row
    if (-not $k) { return $null }
    return $k.Substring($k.IndexOf('_') + 1)
}

function Get-ChatqAutoMarkerPath {
    # the marker of the cut-off an auto job was queued for, or $null
    param($Job)
    $k = "$([string]$Job.sessionId)_$([string](Get-ChatField $Job 'cutUuid'))"
    if ($k -cnotmatch '^[0-9A-Za-z-]+_[0-9A-Za-z-]+$') { return $null }
    return (Join-Path $script:ChatqAutoDir "$k.json")
}

function New-ChatqAutoMarker {
    # One marker per cut-off, made before its job with an exclusive create:
    # $true when this caller made it. The overlay and the watcher both scan,
    # and only the one that made the marker queues - so they never both do,
    # a continue that was removed never comes back for the same cut-off, and
    # one the reset ask answered (Save-ChatqAskAnswer, the same folder and
    # the same name) is never queued here.
    param([string]$Key, $Fields)
    if (-not $Key -or $Key -cnotmatch '^[0-9A-Za-z-]+_[0-9A-Za-z-]+$') { return $false }
    New-ChatqDir $script:ChatqAutoDir
    $p = Join-Path $script:ChatqAutoDir "$Key.json"
    $fs = $null
    try { $fs = [System.IO.File]::Open($p, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None) }
    catch { return $false }
    try {
        $b = (New-Object System.Text.UTF8Encoding $false).GetBytes(($Fields | ConvertTo-Json -Depth 4))
        $fs.Write($b, 0, $b.Length)
    }
    finally { $fs.Dispose() }
    return $true
}

function Set-ChatqAutoMarker {
    # what became of the cut-off's job, written over the marker
    param([string]$Key, $Fields)
    try { Save-ChatqJson (Join-Path $script:ChatqAutoDir "$Key.json") ([pscustomobject]$Fields) } catch {}
}

function Get-ChatqAskExtra {
    # What an answer to the reset ask keeps beside it (Save-ChatqAskAnswer
    # -Extra): each cut-off's chat and reset, by its key, so a later cut-off
    # of that chat with the same reset is held too, as one this mode queued
    # would be. -Items and -Keys side by side, as Get-ChatqResetAsk gives them.
    param([object[]]$Items, [string[]]$Keys)
    $out = @{}
    $ii = @($Items)
    $kk = @($Keys)
    for ($i = 0; $i -lt $ii.Count -and $i -lt $kk.Count; $i++) {
        if (-not $kk[$i] -or -not $ii[$i]) { continue }
        $r = ConvertTo-ChatqDate (Get-ChatField $ii[$i] 'ResetsAt')
        $x = [ordered]@{ sessionId = [string](Get-ChatField $ii[$i] 'Id'); resetsAt = $(if ($r) { $r.ToUniversalTime().ToString('o') } else { $null }) }
        # a window's restart cut it, not the limit: it has no reset, and
        # holds nothing of this mode's (Get-ChatRestartCutOffs)
        if ([string](Get-ChatField $ii[$i] 'Why') -eq 'restart') { $x['why'] = 'restart' }
        $out[[string]$kk[$i]] = $x
    }
    return $out
}

function Get-ChatqAutoMarkers {
    # every marker - this mode's and the ask's answers - by its key. -Prune:
    # those over 8 days old go first - their cut-offs are long past being
    # continued by anyone.
    param([switch]$Prune)
    $out = @{}
    if (-not (Test-Path -LiteralPath $script:ChatqAutoDir)) { return $out }
    $old = (Get-Date).ToUniversalTime().AddDays(-$script:ChatqAutoMarkerDays)
    foreach ($f in @(Get-ChildItem -LiteralPath $script:ChatqAutoDir -Filter *.json -File -EA SilentlyContinue)) {
        if ($Prune -and $f.LastWriteTimeUtc -lt $old) { Remove-Item -LiteralPath $f.FullName -Force -EA SilentlyContinue; continue }
        $m = Read-ChatqJson $f.FullName
        # one caught mid-write still counts: it was made, so it is taken
        if (-not $m) { $m = [pscustomobject]@{ at = $null } }
        $out[$f.BaseName] = $m
    }
    return $out
}

function Format-ChatqAutoTime {
    # 13:01 today, Mon 13:01 on another day
    param($When, [datetime]$Now = (Get-Date))
    if (-not $When) { return '' }
    return (Format-ChatqClockTime ([datetime]$When) $Now)
}

function Format-ChatqAutoTitle {
    # a title short enough for a line that says something after it
    param([string]$Title, [int]$Max = 24)
    $t = [string]$Title
    if ($t.Length -le $Max) { return $t }
    return (Limit-ChatqText $t ($Max - 1)) + $script:ChatqEllipsis
}

function Get-ChatqAutoMarkerJobs {
    # the jobs a marker names: this mode's jobId, or the ask's seq list
    param($Marker, [string]$SessionId, [object[]]$Jobs)
    $id = [string](Get-ChatField $Marker 'jobId')
    if ($id) { return @($Jobs | Where-Object { $_ -and [string]$_.id -eq $id }) }
    $seqs = @(@(Get-ChatField $Marker 'seq') | Where-Object { $null -ne $_ } | ForEach-Object { [int]$_ })
    if (-not $seqs.Count) { return @() }
    return @($Jobs | Where-Object { $_ -and [string]$_.sessionId -eq $SessionId -and [int]$_.seq -in $seqs })
}

function Test-ChatqAutoHeldElsewhere {
    # Held by a process that is not a VS Code panel's: a terminal's claude, a
    # background session, claude -p. Claude Code's own wait continues it
    # there, and a continue queued here would be a second writer.
    param([string]$SessionId, [object[]]$Live)
    return [bool]@($Live | Where-Object {
            $_ -and [string](Get-ChatField $_ 'SessionId') -eq $SessionId -and -not (
                ([string](Get-ChatField $_ 'Kind') -in '', 'interactive') -and [string](Get-ChatField $_ 'Entrypoint') -eq 'claude-vscode')
        }).Count
}

function Get-ChatqAutoState {
    <#
    What auto-continue does with one cut-off (a Get-ChatqCutOffChats row),
    as @{ State; Words; Long; Tag; Why; At; Job; Seq; JobId }. Pure: the
    jobs, the live registry entries, the settings (Get-ChatqAutoConfig), the
    markers and -Now come in; -Eta is Get-ChatqEta's answer, for the time a
    queued continue goes. Words are the overlay row's, short: the reason
    they leave out is in Long (the chip's tooltip, the console, -Print,
    chatqlist) and Why. A 529 Overloaded goes through the same checks: it
    has no reset, so its continue is due at once and waits in the watcher
    for Claude to be back (Enter-ChatqAutoOutage), not for a time. The
    checks, in order:
      restart     a VS Code window's restart cut it off - only ever asked about
      running / armed / due   a continue auto-continue queued: running, the
                  reset still ahead, or past it and waiting its turn - a
                  529's is due
      never, off  the chat set to never; the switch not on and it not always
                  (off keeps the row's old words: cut off - resets 13:00);
                  a 529's is overloaded then, the row as it always was
      terminal    a live process other than a VS Code panel's holds it
      stopped     2 auto-continues in a row failed, on this cut-off
      failed, declined   its marker: the job failed, or was removed or
                  skipped, or the reset ask was answered leave - or the job
                  could not be made (failed)
      far         before since, over 12 h old, or its reset over 24 h after it
      late        first seen over 30 min after its reset - a 529's, over
                  30 min after it
      ready       none of them: the scan queues it
    #>
    param($CutOff, [object[]]$Jobs, [object[]]$Live, $Config, [hashtable]$Markers, [datetime]$Now = (Get-Date), [hashtable]$Eta)
    $d = $script:ChatqDot
    $sid = [string]$CutOff.Id
    # anything not the limit is the server's trouble: a 529, or another 5xx
    # (Get-ChatqLastTurn) - Claude being back ends it, never a reset
    $ov = [string]$CutOff.Why -ne 'limit'
    $reset = if ($ov) { $null } else { $CutOff.ResetsAt }
    $when = if ($ov) { '529' } elseif ($reset -and $reset -gt $Now) { "resets $(Format-ChatqAutoTime $reset $Now)" } else { 'limit over' }
    $lead = if ($ov) { 'cut off by a 529' } else { "cut off - $when" }
    # the row's words are short - at the panel's default width a long state
    # leaves the title a few letters - so each tag has a one-word form there
    $brief = @{ 'never auto' = 'never'; 'in a terminal' = 'terminal'; 'auto stopped' = 'stopped'; 'auto-continue failed' = 'failed'; 'not continued' = 'skipped'; 'by hand' = 'by hand' }
    $make = {
        param([string]$State, [string]$Short, [string]$Tag, [string]$Why, $Job, [string]$Long, [string]$At)
        $w = if ($Short) { $Short } elseif ($Tag) { "$when $d $($brief[$Tag])" } elseif ($ov) { '529 - waits for Claude' } else { $when }
        $l = if ($Long) { $Long } elseif ($Tag) { "$lead $d $Tag" } else { $lead }
        [pscustomobject]@{
            State = $State; Words = $w; Long = $l; Tag = $Tag; Why = $Why; At = $At; Job = $Job
            Seq = $(if ($Job) { [int]$Job.seq } else { $null }); JobId = $(if ($Job) { [string]$Job.id } else { $null })
        }
    }
    $cutAt = if ($CutOff.At) { " at $(Format-ChatqAutoTime $CutOff.At $Now)" } else { '' }
    # a VS Code window's restart (Get-ChatRestartCutOffs): never continued by
    # itself, whatever the switch or the chat says - the reset ask offers it
    if ($CutOff.Why -eq 'restart') {
        return (& $make 'restart' 'cut off - VS Code restarted' '' 'a VS Code window restarted under it - auto-continue never continues one by itself; the reset ask offers it' $null 'cut off - VS Code restarted')
    }
    # a continue auto-continue queued for it: running, or waiting
    $job = @($Jobs | Where-Object { $_ -and [string]$_.sessionId -eq $sid -and [string]$_.state -in 'queued', 'running' -and (Get-ChatField $_ 'auto') }) | Select-Object -First 1
    if ($job) {
        if ($job.state -eq 'running') { return (& $make 'running' "#$($job.seq) running" '' 'auto-continue is running it now' $job "#$($job.seq) running") }
        $e = if ($Eta) { [string]$Eta[[string]$job.id] } else { '' }
        $at = ($e -replace '\s*\([^)]*\)$', '').Trim()
        $note = if ($e -match '\(([^)]*)\)$') { $Matches[1] } else { '' }
        if ($ov) {
            # no time to wait for: the watcher sends it once Claude is back -
            # at once when a probe says so, or behind the jobs before it
            if ($at -in '', 'next', 'when Claude is back') { $at = 'when Claude is back' }
            $short = if ($at -eq 'when Claude is back') { "#$($job.seq) auto $d 529" } else { "#$($job.seq) auto $at" }
            $why = "a 529 cut it off$cutAt, and auto-continue sends ""continue"" $(if ($at -match '^\d|^[A-Z][a-z]{2} ') { "at $at" } else { $at })$(if ($note) { " - $note" })"
            return (& $make 'due' $short '' $why $job "#$($job.seq) auto-continues $at$(if ($note) { " ($note)" })" $at)
        }
        # never before its own reset, whatever the queue says - but after a
        # job that itself waits for a time is the truth: one limit's cut-offs
        # all go at its reset, one at a time (Get-ChatqEta)
        $root = $at
        for ($k = 0; $k -lt 50 -and $root -match '^after #(\d+)'; $k++) {
            $n = [int]$Matches[1]
            $before = @($Jobs | Where-Object { $_ -and [int]$_.seq -eq $n -and [string]$_.state -eq 'queued' }) | Select-Object -First 1
            $root = if ($before -and $Eta) { ([string]$Eta[[string]$before.id] -replace '\s*\([^)]*\)$', '').Trim() } else { '' }
        }
        $behindWait = $at -like 'after *' -and $root -match '^\d|^[A-Z][a-z]{2} '
        if ($reset -and $reset -gt $Now -and ($at -in '', 'next' -or ($at -like 'after *' -and -not $behindWait))) { $at = Format-ChatqAutoTime $reset.AddMinutes(1) $Now }
        if (-not $at) { $at = 'next' }
        $state = if ($reset -and $reset -gt $Now) { 'armed' } else { 'due' }
        $why = "the limit cut it off$cutAt, and auto-continue sends ""continue"" $(if ($at -match '^\d|^[A-Z][a-z]{2} ') { "at $at" } else { $at })$(if ($note) { " - $note" })"
        return (& $make $state "#$($job.seq) auto $at" '' $why $job "#$($job.seq) auto-continues $at$(if ($note) { " ($note)" })" $at)
    }
    $pref = if ($Config -and $Config.Chats -and $Config.Chats[$sid]) { [string]$Config.Chats[$sid].auto } else { '' }
    if ($pref -eq 'never') { return (& $make 'never' '' 'never auto' "this chat is set to never auto-continue - chatq '<title>' -AutoContinue default follows the switch again") }
    if ($pref -ne 'always' -and -not ($Config -and $Config.On)) {
        # a 529 with the switch not on: the row it always had - the reset ask
        # is for the limit only, and has nothing to ask about here
        if ($ov) {
            $how = if ($Config -and $Config.Mode -eq 'ask') { 'auto-continue asks after the limit only - Continue queues one now' } else { 'auto-continue is off - Continue queues one' }
            return (& $make 'overloaded' '529 - waits for Claude' '' "Claude was overloaded (a 529) - $how" $null '529 - waits for Claude')
        }
        $how = if ($Config -and $Config.Mode -eq 'ask') { 'auto-continue asks once the limit is over - Continue queues one now' } else { 'auto-continue is off - Continue queues one' }
        # the words the row had before auto-continue, short and long: the
        # state is there for the row's continue chip, not to reword it
        $old = Format-ChatOverlayCutOff $CutOff $Now
        return (& $make 'off' $old '' $how $null $old)
    }
    if (Test-ChatqAutoHeldElsewhere $sid $Live) { return (& $make 'terminal' '' 'in a terminal' 'open in a terminal, or held by another claude - Claude Code''s own wait continues it there') }
    $cut = Get-ChatqCutId $CutOff
    $sk = if ($Config -and $Config.Streak) { $Config.Streak[$sid] } else { $null }
    if ($sk -and [int]$sk.n -ge $script:ChatqAutoStreakCap -and (-not $sk.uuid -or [string]$sk.uuid -eq $cut)) {
        return (& $make 'stopped' '' 'auto stopped' "$([int]$sk.n) auto-continues in a row failed - continue it yourself; -AutoContinue always tries again")
    }
    $mk = if ($Markers -and $cut) { $Markers["${sid}_$cut"] } else { $null }
    # Don't continue is for this reset. A chat woken again before it - a
    # background task's note arriving - hits the limit again under a new
    # uuid with the same reset (spike A3 saw it): a continue removed for the
    # first cut-off holds for that one too. The ask's markers carry the
    # chat and the reset as well.
    if (-not $mk -and $Markers -and $reset) {
        foreach ($k in @($Markers.Keys)) {
            $o = $Markers[$k]
            $osid = [string](Get-ChatField $o 'sessionId')
            if (-not $osid) { $osid = ([string]$k -split '_')[0] }
            if ($osid -ne $sid -or (Get-ChatField $o 'error')) { continue }
            $or = ConvertTo-ChatqDate (Get-ChatField $o 'resetsAt')
            if (-not $or -or [Math]::Abs(($or.ToUniversalTime() - ([datetime]$reset).ToUniversalTime()).TotalSeconds) -gt 60) { continue }
            $oj = @(Get-ChatqAutoMarkerJobs $o $sid $Jobs)
            if (@($oj | Where-Object { [string]$_.state -in 'failed', 'needs-input' }).Count) { continue }
            $mk = $o
            break
        }
    }
    if ($mk) {
        $err = [string](Get-ChatField $mk 'error')
        if ($err) { return (& $make 'failed' '' 'auto-continue failed' "auto-continue could not queue it: $err") }
        $mj = @(Get-ChatqAutoMarkerJobs $mk $sid $Jobs | Where-Object { [string]$_.state -in 'failed', 'needs-input' }) | Select-Object -First 1
        if ($mj) {
            $r = if ($mj.result -and $mj.result.reason) { ": $($mj.result.reason)" } else { '' }
            return (& $make 'failed' '' 'auto-continue failed' "#$($mj.seq) ended $($mj.state)$r")
        }
        if ([string](Get-ChatField $mk 'answer') -eq 'leave') {
            return (& $make 'declined' '' 'not continued' 'left as it was when the reset was asked about - Continue queues one')
        }
        if ($ov) { return (& $make 'declined' '' 'not continued' 'its continue was removed - not sent for this 529; the next cut-off is continued again') }
        return (& $make 'declined' '' 'not continued' 'its continue was removed - not sent after this reset; the next time the limit cuts it off, it is continued again')
    }
    $since = if ($Config -and $Config.Since) { $Config.Since } else { $Now }
    $at0 = $CutOff.At
    $far = if (-not $at0 -or -not $cut) { 'no time was recorded for the cut-off' }
    elseif (-not $ov -and -not $reset) { 'no reset time was recorded' }
    elseif ($since -and $at0 -lt $since) { 'it was cut off before auto-continue was on here' }
    elseif (($Now - $at0).TotalHours -gt $script:ChatqAutoMaxAgeHours) { "it was cut off over $($script:ChatqAutoMaxAgeHours) h ago" }
    elseif (-not $ov -and ($reset - $at0).TotalHours -gt $script:ChatqAutoMaxResetHours) { "its reset is over $($script:ChatqAutoMaxResetHours) h away - a weekly limit" }
    else { $null }
    if ($far) { return (& $make 'far' '' 'by hand' "$far - continue it yourself") }
    # a 529 has no reset: the 30 minutes run from the cut-off itself - one
    # found later was continued by hand, or is past wanting it
    if ($ov -and $at0 -lt $Now.AddMinutes(-$script:ChatqAutoLateMinutes)) {
        return (& $make 'late' '' 'by hand' "first seen over $($script:ChatqAutoLateMinutes) minutes after the 529 - continue it yourself")
    }
    if (-not $ov -and $reset -lt $Now.AddMinutes(-$script:ChatqAutoLateMinutes)) {
        return (& $make 'late' '' 'by hand' "first seen over $($script:ChatqAutoLateMinutes) minutes after its reset - continue it yourself")
    }
    return (& $make 'ready' '' '' 'auto-continue queues "continue" for it at its next look' $null "$lead $d auto-continue queues it")
}

#endregion

#region auto-continue: the scan -------------------------------------------------

function Get-ChatqAutoHoldUntil {
    # Until when a continue waits for a chat open in a VS Code panel: the
    # reset and 5 minutes, once a claude-vscode entry holds it; $null when
    # none does, or that time has passed
    param([string]$SessionId, $ResetsAt, [object[]]$Live, [datetime]$Now = (Get-Date))
    $panel = @($Live | Where-Object {
            $_ -and [string](Get-ChatField $_ 'SessionId') -eq $SessionId -and [string](Get-ChatField $_ 'Entrypoint') -eq 'claude-vscode' -and
            ([string](Get-ChatField $_ 'Kind') -in '', 'interactive')
        })
    if (-not $panel) { return $null }
    $base = if ($ResetsAt) { ConvertTo-ChatqDate $ResetsAt } else { $Now }
    if (-not $base) { $base = $Now }
    $until = $base.AddMinutes($script:ChatqAutoHoldMinutes)
    if ($until -le $Now) { return $null }
    return $until
}

function Write-ChatqAutoLog {
    # the overlay's log or the watcher's, by who scanned
    param([string]$Source, [string]$Text, [switch]$Always)
    if ($Source -eq 'watcher') { Write-ChatqWatchLog $Text } else { Write-ChatOverlayLog $Text -Always:$Always }
}

function New-ChatqAutoJob {
    # The marker first, then the job -Continue makes, in the chat's own mode
    # and model, with the other continues ahead of the prompts waiting
    # (Get-ChatqJobs). $null when another scan made the
    # marker first, or the job could not be made - which the marker then
    # says, so that cut-off is never tried again. The marker has the ask's
    # shape (Save-ChatqAskAnswer: at, answer, source, seq) and what this
    # mode reads back: the chat, the cut-off, its reset and the job - and
    # why it stopped: overloaded for a 529, which has no reset, so the
    # watcher waits for Claude to be back instead (Enter-ChatqAutoOutage).
    param($CutOff, [object[]]$Live, [string]$Source, [datetime]$Now)
    $sid = [string]$CutOff.Id
    $key = Get-ChatqCutKey $CutOff
    if (-not $key) { return $null }
    $cut = Get-ChatqCutId $CutOff
    $ov = [string]$CutOff.Why -ne 'limit'
    $utc = { param($x) $dd = ConvertTo-ChatqDate $x; if ($dd) { $dd.ToUniversalTime().ToString('o') } else { $null } }
    $fields = [ordered]@{
        at = (Get-ChatqStamp); answer = 'continue'; source = $Source; seq = @(); sessionId = $sid; cutUuid = $cut
        cutAt = (& $utc $CutOff.At); resetsAt = $(if ($ov) { $null } else { & $utc $CutOff.ResetsAt }); jobId = $null
        why = $(if ($ov) { 'overloaded' } else { 'limit' })
    }
    if (-not (New-ChatqAutoMarker $key $fields)) { return $null }
    $sid8 = $sid.Substring(0, [Math]::Min(8, $sid.Length))
    try {
        $row = Get-ChatqRowById $sid 'claude' ([string]$CutOff.Path) ([string]$CutOff.Cwd)
        if (-not $row) { throw 'the chat could not be read' }
        $info = Get-ChatqJobInfo $row
        if ($info.Error) { throw [string]$info.Error }
        $set = @{ auto = $true; cutUuid = $cut }
        # a 529's panel hold runs from the cut-off: there is no reset to
        # wait for, and the panel's own retry, if any, goes in those minutes
        $holdBase = if ($ov) { $CutOff.At } else { $CutOff.ResetsAt }
        $hold = Get-ChatqAutoHoldUntil $sid $holdBase $Live $Now
        if ($hold) { $set['deferUntil'] = $hold.ToUniversalTime().ToString('o'); $set['deferWhy'] = 'vscode' }
        $note = if ($ov) { "auto - 529 $(Format-ChatqAutoTime $CutOff.At $Now)" } else { "auto - limit $(Format-ChatqAutoTime $CutOff.At $Now), resets $(Format-ChatqAutoTime $CutOff.ResetsAt $Now)" }
        $made = New-ChatqJob -Row $row -Kind continue -Rule auto -Info $info -Set $set -LogNote $note
        if ($made.Error) { throw [string]$made.Error }
        $fields.jobId = [string]$made.Job.id
        $fields.seq = @([int]$made.Job.seq)
        Set-ChatqAutoMarker $key $fields
        $after = if ($ov) { 'a 529, goes when Claude is back' } else { "resets $(Format-ChatqAutoTime $CutOff.ResetsAt $Now)" }
        if ($Source -eq 'watcher') { Write-ChatqWatchLog "auto-continue: queued #$($made.Job.seq) for $sid8 (scan)" }
        else { Write-ChatOverlayLog "auto-continue: queued #$($made.Job.seq) for $sid8 ($(Format-ChatqAutoTitle $row.Title)), $after" -Always }
        return $made.Job
    }
    catch {
        $fields['error'] = [string]$_.Exception.Message
        Set-ChatqAutoMarker $key $fields
        Write-ChatqAutoLog $Source "auto-continue: $sid8 not queued - error: $($_.Exception.Message)" -Always
        return $null
    }
}

function Invoke-ChatqAutoContinueScan {
    <#
    The checks for each cut-off (Get-ChatqAutoState), and for each one that
    passes every one of them the marker, the job and the log line
    (New-ChatqAutoJob). -Jobs every job there is, -Live the registry's live
    entries of every kind. A scan that finds no since - the switch set on by
    hand in config.json, or one chat set to always - writes it: cut-offs
    from before it are shown, never queued. Returns @{ Queued; Skipped;
    Error }. Never throws.
    #>
    param([object[]]$CutOff, [object[]]$Jobs, [object[]]$Live, [string]$Source = 'overlay', [datetime]$Now = (Get-Date))
    $queued = [System.Collections.Generic.List[object]]::new()
    $skipped = [System.Collections.Generic.List[object]]::new()
    $err = $null
    try {
        $cfg = Get-ChatqAutoConfig
        if (-not $cfg.Since) { $cfg = Update-ChatqAutoState { param($v) if (-not $v.Since) { $v.Since = $Now } } }
        $markers = Get-ChatqAutoMarkers -Prune
        $all = [System.Collections.Generic.List[object]]::new()
        foreach ($j in @($Jobs)) { if ($j) { $all.Add($j) } }
        foreach ($c in @($CutOff)) {
            if (-not $c -or -not $c.Id) { continue }
            $sid = [string]$c.Id
            # a job of any kind queued or running for it: that one goes
            if (@($all | Where-Object { [string]$_.sessionId -eq $sid -and [string]$_.state -in 'queued', 'running' }).Count) { continue }
            $st = Get-ChatqAutoState $c $all.ToArray() $Live $cfg $markers $Now
            if ($st.State -ne 'ready') {
                $skipped.Add([pscustomobject]@{ Id = $sid; State = $st.State })
                # said once per cut-off; the switch off is no news each minute
                $k = "$sid|$(Get-ChatqCutId $c)|$($st.State)"
                if ($st.State -in 'terminal', 'never', 'far', 'late', 'stopped' -and -not $script:ChatqAutoSaid[$k]) {
                    $script:ChatqAutoSaid[$k] = $true
                    $words = switch ($st.State) { 'never' { 'never auto' } 'terminal' { 'in a terminal' } default { $st.State } }
                    Write-ChatqAutoLog $Source "auto-continue: $($sid.Substring(0, [Math]::Min(8, $sid.Length))) not queued - $words"
                }
                continue
            }
            $j = New-ChatqAutoJob $c $Live $Source $Now
            if ($j) { $queued.Add($j); $all.Add($j) }
        }
    }
    catch {
        $err = $_.Exception.Message
        try { Write-ChatqAutoLog $Source "auto-continue: $err" } catch {}
    }
    return [pscustomobject]@{ Queued = $queued.ToArray(); Skipped = $skipped.ToArray(); Error = $err }
}

function Invoke-ChatqWatchAutoScan {
    # The watcher's own scan, every 5 minutes (Invoke-ChatqWatchLoop): the
    # overlay may not be running. Its cut-off cache is $W.CutCache. Never
    # throws; returns how many it queued.
    param($W)
    try {
        $cfg = Get-ChatqAutoConfig
        if (-not (Test-ChatqAutoWanted $cfg)) { return 0 }
        if (-not $W.ContainsKey('CutCache') -or $null -eq $W.CutCache) { $W.CutCache = @{} }
        $jobs = @(Get-ChatqJobs)
        $live = @(Get-ChatqLiveSessions $script:ChatClaudeHome -RegistryOnly)
        $working = @($live | Where-Object { $_.Status -in 'busy', 'waiting' } | ForEach-Object { [string]$_.SessionId })
        $cut = @(Get-ChatqCutOffChats $jobs -Hours 24 -Cache $W.CutCache -Skip $working)
        $r = Invoke-ChatqAutoContinueScan -CutOff $cut -Jobs $jobs -Live $live -Source watcher
        return @($r.Queued).Count
    }
    catch {
        Write-ChatqWatchLog "auto-continue: $($_.Exception.Message)"
        return 0
    }
}

#endregion

#region auto-continue: the watcher's side --------------------------------------

function Get-ChatqAutoHold {
    # The VS Code hold for an auto job as the watcher reaches it: the chat
    # live in a panel, and the reset - from its marker - plus 5 minutes still
    # ahead; for a 529's, the cut-off plus 5 minutes. $null otherwise, and
    # for any other job.
    param($Job, [object[]]$Live, [datetime]$Now = (Get-Date))
    if (-not (Get-ChatField $Job 'auto') -or -not $Job.sessionId) { return $null }
    $p = Get-ChatqAutoMarkerPath $Job
    $m = if ($p) { Read-ChatqJson $p } else { $null }
    $f = if ($m -and [string](Get-ChatField $m 'why') -eq 'overloaded') { 'cutAt' } else { 'resetsAt' }
    $reset = if ($m) { ConvertTo-ChatqDate (Get-ChatField $m $f) } else { $null }
    if (-not $reset) { return $null }
    return (Get-ChatqAutoHoldUntil ([string]$Job.sessionId) $reset $Live $Now)
}

function Get-ChatqAutoCutTurn {
    # An auto job's chat as it stands now, when that is still where its
    # cut-off left it: the transcript there, its last turn the limit or the
    # 529, and that turn the one the job was queued for (its cutUuid). That
    # last turn, else $null - the chat is gone, or it moved on: you retried
    # it in the panel, or it was cut off again since. Never throws.
    param($Job)
    try {
        if (-not $Job.path -or -not (Test-Path -LiteralPath $Job.path)) { return $null }
        $last = Get-ChatqLastTurn $Job.path
        if (-not $last -or -not ($last.Limit -or $last.Overloaded)) { return $null }
        $cut = Get-ChatqCutId ([pscustomobject]@{ Id = [string]$Job.sessionId; LimitUuid = $last.Uuid; At = $last.At })
        if (-not $cut -or $cut -ne [string](Get-ChatField $Job 'cutUuid')) { return $null }
        return $last
    }
    catch { return $null }
}

function Enter-ChatqAutoOutage {
    <#
    An auto job for a 529 cut-off, about to be probed for (Confirm-ChatqAllowed):
    its lane is taken as overloaded from the cut-off on, as if the watcher
    had seen the 529 itself (Enter-ChatqOutage), so Test-ChatqOutageOver lets
    it go - at once when status.claude.com shows Claude Code operational, else
    15 minutes after the 529 - and a probe that gets a 529 again keeps it
    waiting the same way. Not when the lane is in an outage already, nor when
    a probe said allowed since the 529: Claude was back then. Nor when the
    chat no longer stands where the 529 left it (Get-ChatqAutoCutTurn): this
    runs before Invoke-ChatqJob's own checks, and a chat you retried in the
    panel - the usual case - would otherwise hold every prompt on the
    account for a job that is then skipped as already continued. No alert -
    the 529 was the chat's, and you saw it there. The outage keeps the job's
    id (AutoJob) for Clear-ChatqAutoOutage. Never throws; $true when it
    started one.
    #>
    param($W, $Job)
    try {
        if (-not (Get-ChatField $Job 'auto') -or $Job.provider -ne 'claude') { return $false }
        $lane = Get-ChatqLane $Job
        if ($W.outage[$lane]) { return $false }
        $p = Get-ChatqAutoMarkerPath $Job
        $m = if ($p) { Read-ChatqJson $p } else { $null }
        if (-not $m -or [string](Get-ChatField $m 'why') -ne 'overloaded') { return $false }
        $cutAt = ConvertTo-ChatqDate (Get-ChatField $m 'cutAt')
        if (-not $cutAt) { return $false }
        $ok = $W.lastAllowed[$lane]
        if ($ok -and $ok -ge $cutAt) { return $false }
        $turn = Get-ChatqAutoCutTurn $Job
        if (-not $turn -or -not $turn.Overloaded) { return $false }
        # Since is now, not the 529: the 6-hour reminder counts from here.
        # LastProbe is the 529, so the 15 minutes run from it
        $W.outage[$lane] = @{ Since = (Get-Date); Attempts = 0; Status = $null; Alerted = $true; Reminded = $false; LastProbe = $cutAt; NextCheck = (Get-Date); AutoJob = [string]$Job.id }
        Write-ChatqWatchLog "#$($Job.seq) auto-continue after a 529 at $(Format-ChatqAutoTime $cutAt): waits for Claude to be back"
        return $true
    }
    catch { return $false }
}

function Clear-ChatqAutoOutage {
    <#
    An outage Enter-ChatqAutoOutage started, ended once the job it was for
    no longer waits on it: removed (Don't continue), run, skipped, or its
    chat moved on since (a retry in the panel). That outage was only the
    chat's 529, never seen by a probe, and the lane's other prompts would
    wait for nothing. One a probe has since met a 529 in is the watcher's
    own (Enter-ChatqOutage drops AutoJob) and stays. Never throws; $true
    when it ended one.
    #>
    param($W, $Job)
    try {
        $lane = Get-ChatqLane $Job
        $o = $W.outage[$lane]
        if (-not $o -or -not $o.AutoJob) { return $false }
        $j = Find-ChatqJob ([string]$o.AutoJob) -Exact
        if ($j -and $j.state -eq 'queued') {
            $turn = Get-ChatqAutoCutTurn $j
            if ($turn -and $turn.Overloaded) { return $false }
        }
        $W.outage[$lane] = $null
        $which = if ($j) { "#$($j.seq)" } else { 'its job' }
        Write-ChatqWatchLog "$lane no longer waits for Claude: $which, the 529's auto-continue, is no longer waiting"
        return $true
    }
    catch { return $false }
}

function Test-ChatqAutoTerminal {
    # an auto job's chat held, as it is about to run, by a process that is
    # not a VS Code panel's: left to it, as it would not have been queued
    param($Job, [object[]]$Live)
    if (-not (Get-ChatField $Job 'auto')) { return $false }
    return (Test-ChatqAutoHeldElsewhere ([string]$Job.sessionId) $Live)
}

function Step-ChatqAutoStreak {
    <#
    An auto job ended: done clears its chat's streak; failed adds one when
    the job was for the cut-off the last failure left, else starts at one,
    and remembers the cut-off the chat is left on now. $true when this made
    it stop - Get-ChatqAutoState says stopped until a turn ends without the
    limit, or the chat is set to always again. Never throws.
    #>
    param($Job)
    if (-not (Get-ChatField $Job 'auto') -or -not $Job.sessionId) { return $false }
    $sid = [string]$Job.sessionId
    try {
        if ($Job.state -eq 'done') {
            if ((Get-ChatqAutoConfig).Streak[$sid]) { $null = Update-ChatqAutoState { param($v) $v.Streak.Remove($sid) } }
            return $false
        }
        if ($Job.state -ne 'failed') { return $false }
        $last = if ($Job.path) { try { Get-ChatqLastTurn $Job.path } catch { $null } } else { $null }
        $left = if ($last -and ($last.Limit -or $last.Overloaded)) { Get-ChatqCutId ([pscustomobject]@{ Id = $sid; LimitUuid = $last.Uuid; At = $last.At }) } else { $null }
        $was = [string](Get-ChatField $Job 'cutUuid')
        if (-not $left) { $left = $was }
        $v = Update-ChatqAutoState {
            param($v)
            $p = $v.Streak[$sid]
            $n = if ($p -and (-not $p.uuid -or [string]$p.uuid -eq $was)) { [int]$p.n + 1 } else { 1 }
            $v.Streak[$sid] = [pscustomobject]@{ n = $n; uuid = $left }
        }
        $n = [int]$v.Streak[$sid].n
        if ($n -ge $script:ChatqAutoStreakCap) {
            Write-ChatqWatchLog "auto-continue stopped for $($sid.Substring(0, [Math]::Min(8, $sid.Length))): $n in a row failed"
            return $true
        }
    }
    catch {}
    return $false
}

function Get-ChatqAutoStopText {
    # the failed alert for the auto-continue that made it stop
    param($Job)
    return "$($Job.title) $($script:ChatqDot) auto-continue stopped: $($script:ChatqAutoStreakCap) tries in a row got no reply - continue it yourself"
}

function Get-ChatqAutoJobNote {
    # the console's detail for an auto job: when the limit cut it off, and
    # when it resets - from its marker; or when a 529 did
    param($Job)
    if (-not (Get-ChatField $Job 'auto')) { return $null }
    $p = Get-ChatqAutoMarkerPath $Job
    $m = if ($p) { Read-ChatqJson $p } else { $null }
    $cutAt = if ($m) { ConvertTo-ChatqDate (Get-ChatField $m 'cutAt') } else { $null }
    $reset = if ($m) { ConvertTo-ChatqDate (Get-ChatField $m 'resetsAt') } else { $null }
    $t = 'queued by auto-continue'
    if ($m -and [string](Get-ChatField $m 'why') -eq 'overloaded') {
        return "${t}: a 529 cut this chat off$(if ($cutAt) { " at $(Format-ChatqAutoTime $cutAt)" }), and it goes when Claude is back"
    }
    if ($cutAt -or $reset) {
        $t += ': the limit cut this chat off'
        if ($cutAt) { $t += " at $(Format-ChatqAutoTime $cutAt)" }
        if ($reset) { $t += ", and it resets at $(Format-ChatqAutoTime $reset)" }
    }
    return $t
}

#endregion

#region auto-continue: the switches ---------------------------------------------

function Get-ChatqAutoJobs {
    # the continues auto-continue queued and that have not run yet
    param([object[]]$Jobs, [string]$SessionId)
    if ($null -eq $Jobs) { $Jobs = @(Get-ChatqJobs) }
    return @($Jobs | Where-Object { $_ -and [string]$_.state -eq 'queued' -and (Get-ChatField $_ 'auto') -and (-not $SessionId -or [string]$_.sessionId -eq $SessionId) })
}

function Get-ChatqAutoSwitchSay {
    <#
    What chatq -AutoContinue on|ask|off says, the switch just set
    (Set-ChatqAutoContinue, the one writer): its line, and under it how to
    keep one chat out (on), or the continues this mode queued that are kept -
    each can be removed - and the chats set to always, which it still
    continues (ask, off). Returns @{ Text; Color } each.
    #>
    param([ValidateSet('on', 'ask', 'off')][string]$Value)
    $msg = [System.Collections.Generic.List[object]]::new()
    switch ($Value) {
        'on' {
            $msg.Add([pscustomobject]@{ Text = 'auto-continue: on - a chat the limit cuts off gets "continue" a minute after the reset - one a 529 cuts off, once Claude is back'; Color = 'Green' })
            $msg.Add([pscustomobject]@{ Text = "  chatq '<title>' -AutoContinue never keeps one out"; Color = 'DarkGray' })
            return $msg.ToArray()
        }
        'ask' { $msg.Add([pscustomobject]@{ Text = 'auto-continue: ask - once the limit is over, the overlay says how many chats it cut off, and continues them if you say so'; Color = 'Green' }) }
        'off' { $msg.Add([pscustomobject]@{ Text = "auto-continue: off - chats the limit cuts off are only marked; chatq '<title>' -Continue queues one"; Color = 'Green' }) }
    }
    $kept = @(Get-ChatqAutoJobs)
    if ($kept) {
        $first = $kept[0]
        $more = if ($kept.Count -gt 1) { " and $($kept.Count - 1) more" } else { '' }
        $msg.Add([pscustomobject]@{ Text = "  $($kept.Count) already queued $(if ($kept.Count -eq 1) { 'is' } else { 'are' }) kept: #$($first.seq) $(Format-ChatqAutoTitle $first.title)$more (chatqrm $($first.seq) drops it)"; Color = 'DarkGray' })
    }
    $ac = Get-ChatqAutoConfig -Fresh
    $always = @($ac.Chats.Keys | Where-Object { $ac.Chats[$_].auto -eq 'always' })
    if ($always) {
        $names = @($always | Select-Object -First 3 | ForEach-Object { $t = [string]$ac.Chats[$_].title; if ($t) { $t } else { $_.Substring(0, [Math]::Min(8, $_.Length)) } }) -join ', '
        $msg.Add([pscustomobject]@{ Text = "  $($always.Count) chat$(if ($always.Count -ne 1) { 's' }) set to always $(if ($always.Count -eq 1) { 'is' } else { 'are' }) still continued: $names"; Color = 'DarkGray' })
    }
    return $msg.ToArray()
}

function Set-ChatqAutoChat {
    <#
    One chat: always, never or default (which drops the entry). never also
    removes the continues auto-continue queued for it; a job you queued
    stays. always starts its streak over. Returns @{ Messages; Removed }.
    #>
    param([string]$Id, [string]$Title, [ValidateSet('always', 'never', 'default')][string]$Value, [string]$By = 'chatq -AutoContinue never')
    $null = Update-ChatqAutoState {
        param($v)
        if ($Value -eq 'default') { $v.Chats.Remove($Id) }
        else { $v.Chats[$Id] = [pscustomobject]@{ auto = $Value; at = (Get-ChatqStamp); title = $Title } }
        if ($Value -eq 'always') { $v.Streak.Remove($Id) }
    }
    $removed = @()
    if ($Value -eq 'never') {
        $removed = @(foreach ($j in @(Get-ChatqAutoJobs -SessionId $Id)) { if (Remove-ChatqJob $j $By) { $j } })
    }
    $msg = [System.Collections.Generic.List[object]]::new()
    switch ($Value) {
        'never' { $msg.Add([pscustomobject]@{ Text = "'$Title': never auto-continued"; Color = 'Green' }) }
        'always' { $msg.Add([pscustomobject]@{ Text = "'$Title': always auto-continued, even with the switch on ask or off"; Color = 'Green' }) }
        default { $msg.Add([pscustomobject]@{ Text = "'$Title': follows the switch - auto-continue is $((Get-ChatqAutoConfig).Mode)"; Color = 'Green' }) }
    }
    foreach ($j in $removed) { $msg.Add([pscustomobject]@{ Text = "  dropped #$($j.seq), its auto-continue"; Color = 'DarkGray' }) }
    return [pscustomobject]@{ Messages = $msg.ToArray(); Removed = $removed }
}

function Invoke-ChatqAutoCommand {
    <#
    chatq -AutoContinue: with no title the switch for every chat (on, ask,
    off), with a title or a job number that chat's own (always, never,
    default). It sets a switch and queues nothing, so it goes alone: beside
    anything but a title, -WhatIf, -Provider and -AllProjects it is refused.
    #>
    param([string]$Value, [string]$Target, [string[]]$Given, [switch]$WhatIf, [string[]]$Provider, [switch]$AllProjects)
    if (@($Given | Where-Object { $_ -notin 'AutoContinue', 'WhatIf', 'Target', 'Provider', 'AllProjects' }).Count) {
        Write-Host '  -AutoContinue sets a switch and queues nothing - run it on its own' -ForegroundColor Yellow
        return
    }
    if ($Value -in 'on', 'ask', 'off') {
        if ($Target) { Write-Host '  -AutoContinue on|ask|off is the switch for every chat - for this one, always|never|default' -ForegroundColor Yellow; return }
        $say = @(Get-ChatqAutoSwitchSay $Value)
        if ($WhatIf) { Write-Host "  -WhatIf: $($say[0].Text)" -ForegroundColor DarkGray; return }
        try { $null = Set-ChatqAutoContinue -Value $Value }
        catch { Write-Host "  could not save it: $($_.Exception.Message)" -ForegroundColor Yellow; return }
        # read again: the kept continues and the always chats as they are now
        foreach ($m in @(Get-ChatqAutoSwitchSay $Value)) { Write-Host "  $($m.Text)" -ForegroundColor $m.Color }
        # a running overlay reads the config again; one not running reads it
        # as it starts
        if (Test-ChatOverlayAlive) { try { Send-ChatOverlayCommand 'reload' } catch {} }
        elseif ($Value -eq 'ask') { Write-Host '    nothing asks while no overlay runs - chatoverlay starts it' -ForegroundColor DarkGray }
        elseif ($Value -eq 'on' -and -not (Test-ChatqWatcherAlive)) { Write-Host '    nothing is continued while no overlay or watcher runs - chatoverlay starts the overlay' -ForegroundColor DarkGray }
        return
    }
    if (-not $Target) {
        Write-Host "  -AutoContinue $Value is for one chat - chatq '<title>' -AutoContinue $Value; on|ask|off is the switch for every chat" -ForegroundColor Yellow
        return
    }
    $row = $null
    if ($Target -match '^#?\d{1,4}$') {
        $job = Find-ChatqJob $Target
        if (-not $job) { Write-Host "  no job $Target" -ForegroundColor Yellow; return }
        if ($job.provider -ne 'claude' -or -not $job.sessionId) { Write-Host '  auto-continue is for Claude chats - a Codex job chatq runs is continued anyway' -ForegroundColor Yellow; return }
        $row = Get-ChatqRowById ([string]$job.sessionId) 'claude' ([string]$job.path) ([string]$job.cwd)
        if (-not $row) { $row = [pscustomobject]@{ Provider = 'claude'; Id = [string]$job.sessionId; Title = [string]$job.title } }
        Write-Host '  -> ' -NoNewline
        Write-Host "'$($row.Title)'" -NoNewline -ForegroundColor Cyan
        Write-Host "  the chat of #$($job.seq)" -ForegroundColor DarkGray
    }
    else {
        $res = Resolve-ChatqTarget $Target '' $Provider -AllProjects:$AllProjects
        if ($res.Error) { Write-Host "  $($res.Error)" -ForegroundColor Yellow; return }
        Write-ChatqPick $res
        $row = $res.Row
    }
    if ($row.Provider -ne 'claude') { Write-Host '  auto-continue is for Claude chats - a Codex job chatq runs is continued anyway' -ForegroundColor Yellow; return }
    if ($WhatIf) { Write-Host '     -WhatIf: nothing changed' -ForegroundColor DarkGray; return }
    $r = Set-ChatqAutoChat -Id ([string]$row.Id) -Title ([string]$row.Title) -Value $Value
    foreach ($m in @($r.Messages)) { Write-Host "  $($m.Text)" -ForegroundColor $m.Color }
    Write-ChatqBoard
}

#endregion

#region auto-continue: chatqlist and the phone ---------------------------------

function Get-ChatqAutoListStates {
    # the state of each cut-off chatqlist lists, as the overlay would word
    # it: the registry read once, the markers and settings as they are
    param([object[]]$CutOff, [object[]]$Jobs)
    $out = @{}
    if (-not @($CutOff).Count) { return $out }
    $cfg = Get-ChatqAutoConfig
    $live = @(try { Get-ChatqLiveSessions $script:ChatClaudeHome -RegistryOnly } catch { @() })
    $markers = Get-ChatqAutoMarkers
    foreach ($c in @($CutOff)) { if ($c -and $c.Id) { $out[[string]$c.Id] = Get-ChatqAutoState $c $Jobs $live $cfg $markers (Get-Date) } }
    return $out
}

function Write-ChatqAutoLine {
    <#
    chatqlist's line under the usage one: what auto-continue is set to, and
    how many chats are set otherwise - only when there is something to say
    about it: a cut-off chat, a continue it queued, a chat set to always or
    never, or the switch off. What each mode needs running and does not
    have - on: an overlay or a watcher; ask: an overlay - says so, in
    yellow: nothing is continued, or asked, then.
    #>
    param([object[]]$Jobs, [object[]]$CutOff)
    $cfg = Get-ChatqAutoConfig
    $autoJobs = @(Get-ChatqAutoJobs -Jobs $Jobs)
    $never = @($cfg.Chats.Keys | Where-Object { $cfg.Chats[$_].auto -eq 'never' }).Count
    $always = @($cfg.Chats.Keys | Where-Object { $cfg.Chats[$_].auto -eq 'always' }).Count
    if (-not ($cfg.Mode -eq 'off' -or @($CutOff).Count -or $autoJobs.Count -or $never -or $always)) { return }
    $d = $script:ChatqDot
    if ($cfg.Mode -eq 'off') {
        $t = "  auto-continue off $d chatq -AutoContinue ask|on turns it on"
        if ($always) { $t += " $d $always always" }
        Write-Host $t -ForegroundColor DarkGray
        return
    }
    $overlay = Test-ChatqLockHeld $script:ChatOverlayLockPath
    if ($cfg.Mode -eq 'ask' -and -not $overlay -and @($CutOff).Count) {
        Write-Host '  auto-continue ask - but no overlay runs to ask about cut-off chats: chatoverlay starts it' -ForegroundColor Yellow
        return
    }
    if ($cfg.On -and -not ($overlay -or (Test-ChatqWatcherAlive))) {
        Write-Host '  auto-continue on - but nothing is watching for cut-off chats: chatoverlay starts the overlay' -ForegroundColor Yellow
        return
    }
    $bits = @("auto-continue $($cfg.Mode)")
    if ($autoJobs.Count) { $bits += "$($autoJobs.Count) queued" }
    if ($never) { $bits += "$never chat$(if ($never -ne 1) { 's' }) never" }
    if ($always) { $bits += "$always always" }
    Write-Host ('  ' + ($bits -join " $d ")) -ForegroundColor DarkGray
}

function Get-ChatqAutoListTag {
    # a cut-off's tag in chatqlist's "cut off, nothing queued" line
    param($State)
    if (-not $State -or -not $State.Tag) { return '' }
    return ", $($State.Tag)"
}

function Get-ChatqLiveAutoJob {
    # the continue auto-continue queued for a chat you run yourself, as the
    # overlay's pass has it, when one waits ($null otherwise): its live
    # alert is limited, about that job, in place of done
    param($Ctx, [string]$SessionId)
    $states = Get-ChatField $Ctx 'AutoStates'
    if (-not $states) { return $null }
    $s = $states[$SessionId]
    if ($s -and $s.State -in 'armed', 'due' -and $s.Job) { return $s.Job }
    return $null
}

function Get-ChatqAutoSkipText {
    # the phone's answer to a skip, for a continue auto-continue queued
    param($Job)
    return "#$($Job.seq) skipped - $(Format-ChatqAutoTitle $Job.title) will not be continued $(Get-ChatqAutoWhen $Job)"
}

function Get-ChatqAutoWhen {
    # what a continue removed is not sent for, from its marker: "after this
    # reset", or "for this 529" - which has no reset
    param($Job)
    $p = if ($Job) { Get-ChatqAutoMarkerPath $Job } else { $null }
    $m = if ($p) { Read-ChatqJson $p } else { $null }
    if ($m -and [string](Get-ChatField $m 'why') -eq 'overloaded') { return 'for this 529' }
    return 'after this reset'
}

#endregion

#region auto-continue: the overlay's pass ---------------------------------------

function Update-ChatOverlayAuto {
    <#
    Each collector pass (Invoke-ChatOverlayCycle), right after the cut-off
    scan: the state of every cut-off chat drawn, into $Ctx.AutoStates for
    the rows - and, -Scan (the Windows and macOS hosts' passes, never -Print
    or a -Peek), once the cut-off list was read afresh, the scan that
    queues, over -Rows: the whole look, not only the rows drawn, so it runs
    with overlay.cutOff false too. The markers are read again with that
    list. Returns $true when it queued anything: the caller works out the
    queue's times again.
    #>
    param($Ctx, [object[]]$Live, [datetime]$Now, [hashtable]$Eta, [switch]$Scan, [object[]]$Rows)
    $cfg = Get-ChatqAutoConfig
    $Ctx.AutoOn = [bool]$cfg.On
    # nothing for this mode to do - ask or off, no chat set to always: off
    # on each row, which reads as it always did and has the continue chip,
    # and no marker read
    if (-not (Test-ChatqAutoWanted $cfg)) {
        $Ctx.AutoMarkers = $null
        $Ctx.AutoStates = Get-ChatqAutoRowStates -CutOff $Ctx.CutOff -Jobs @($Ctx.Jobs | ForEach-Object { $_.Job }) -Live $Live -Config $cfg -Now $Now -Eta $Eta
        return $false
    }
    $fresh = $Ctx.CutAt -eq $Now
    $got = $false
    if ($Scan -and $fresh -and @($Rows).Count) {
        # every job, not only the open ones the pass keeps: a marker's job
        # that failed says so
        $every = @(Get-ChatqJobs)
        $r = Invoke-ChatqAutoContinueScan -CutOff $Rows -Jobs $every -Live $Live -Source overlay -Now $Now
        foreach ($j in @($r.Queued)) {
            # where Get-ChatqJobs puts it, so this pass's "sends" agree with
            # the watcher: behind the jobs put first and the continues, ahead
            # of every other prompt
            $all = @($Ctx.Jobs)
            $at = 0
            for ($k = 0; $k -lt $all.Count; $k++) {
                $x = $all[$k].Job
                if (($x.PSObject.Properties['first'] -and $x.first) -or $x.kind -eq 'continue' -or [string](Get-ChatField $x 'rule') -eq 'restart') { $at = $k + 1 }
            }
            $Ctx.Jobs = @($all | Select-Object -First $at) + @([pscustomobject]@{ Job = $j; First = 'continue' }) + @($all | Select-Object -Skip $at)
            $Ctx.AutoQueued.Add($j)
            $got = $true
        }
        if ($got) { try { $null = Request-ChatqWatcher -Wake poke } catch { Write-ChatOverlayLog "auto-continue: the watcher: $($_.Exception.Message)" } }
        $cfg = Get-ChatqAutoConfig
    }
    if ($fresh -or $got -or $null -eq $Ctx.AutoMarkers) { Update-ChatOverlayAutoMarkers $Ctx }
    if (-not $got) { Update-ChatOverlayAutoStates $Ctx $Live $Now $Eta $cfg }
    return $got
}

function Update-ChatOverlayAutoMarkers {
    # The markers of the chats cut off now, and the jobs they name that the
    # pass does not keep - ended ones, which say failed or declined. Read
    # with the cut-off list, a minute apart, not every pass. Every marker of
    # a chat drawn is kept, not only its own cut-off's: one for the same
    # reset holds it too (Get-ChatqAutoState).
    param($Ctx)
    $all = Get-ChatqAutoMarkers
    $want = @{}
    foreach ($c in @($Ctx.CutOff)) { if ($c -and $c.Id) { $want[[string]$c.Id] = $true } }
    $mine = @{}
    foreach ($k in @($all.Keys)) { if ($want[([string]$k -split '_')[0]]) { $mine[$k] = $all[$k] } }
    $open = @{}
    foreach ($w in @($Ctx.Jobs)) { if ($w -and $w.Job) { $open[[string]$w.Job.id] = $true } }
    $ended = @()
    $every = $null
    foreach ($k in @($mine.Keys)) {
        $id = [string](Get-ChatField $mine[$k] 'jobId')
        if ($id) {
            if ($open[$id]) { continue }
            $p = Join-Path $script:ChatqQueueDir "$id.json"
            if (Test-Path -LiteralPath $p) { $x = Read-ChatqJson $p; if ($x) { $ended += $x } }
            continue
        }
        # the ask's markers name their jobs by number: the queue read once
        $sid = ([string]$k -split '_')[0]
        $seqs = @(@(Get-ChatField $mine[$k] 'seq') | Where-Object { $null -ne $_ } | ForEach-Object { [int]$_ })
        if ($seqs.Count) {
            if ($null -eq $every) { $every = @(Get-ChatqJobs) }
            foreach ($x in @($every | Where-Object { [string]$_.sessionId -eq $sid -and [int]$_.seq -in $seqs -and -not $open[[string]$_.id] })) { $ended += $x }
        }
    }
    $Ctx.AutoMarkers = $mine
    $Ctx.AutoEnded = $ended
}

function Update-ChatOverlayAutoStates {
    # The states alone, from what the pass holds (Get-ChatqAutoRowStates).
    param($Ctx, [object[]]$Live, [datetime]$Now, [hashtable]$Eta, $Config)
    if (-not $Config) { $Config = Get-ChatqAutoConfig }
    if ($null -eq $Ctx.AutoMarkers) { Update-ChatOverlayAutoMarkers $Ctx }
    $jobs = @($Ctx.Jobs | ForEach-Object { $_.Job })
    $all = @($jobs) + @($Ctx.AutoEnded | Where-Object { $_ })
    $Ctx.AutoStates = Get-ChatqAutoRowStates -CutOff $Ctx.CutOff -Jobs $all -Live $Live -Config $Config -Markers $Ctx.AutoMarkers -Now $Now -Eta $Eta
}

function Get-ChatqAutoRowStates {
    <#
    Each cut-off's state for its row (Get-ChatqAutoState), by session id -
    the overlay's pass and the phone board's scan (Get-ChatqBoardScan)
    alike. A 529 left overloaded - the switch not on - has none: its row
    says so itself. With nothing for the
    automatic mode to do (Test-ChatqAutoWanted: the switch on ask or off, no
    chat set to always) only off is kept, and a chat set to never is as any
    other - the reset ask offers it all the same - so every row reads as it
    did before auto-continue, with the continue chip; the markers are not
    needed then. An off held by a terminal (Test-ChatqAutoHeldElsewhere) is
    dropped in every mode: off comes before that check, and its continue
    chip would queue a second writer beside the terminal's claude - the
    row reads as before, with no chip, as the reset ask leaves it out. A
    continue auto-continue queued before the switch turned has no state to
    ride on, and keeps a row of its own (Get-ChatOverlayRows).
    #>
    param([object[]]$CutOff, [object[]]$Jobs, [object[]]$Live, $Config, [hashtable]$Markers, [datetime]$Now = (Get-Date), [hashtable]$Eta)
    if (-not $Config) { $Config = Get-ChatqAutoConfig }
    $idle = -not (Test-ChatqAutoWanted $Config)
    $cfg = if ($idle) { [pscustomobject]@{ Mode = $Config.Mode; On = $false; Since = $Config.Since; Chats = @{}; Streak = @{} } } else { $Config }
    $states = @{}
    foreach ($c in @($CutOff)) {
        if (-not $c -or -not $c.Id) { continue }
        $st = Get-ChatqAutoState $c $Jobs $Live $cfg $(if ($idle) { $null } else { $Markers }) $Now $Eta
        $keep = if ($idle) { $st.State -eq 'off' } else { $st.State -notin 'overloaded', 'restart' }
        if ($keep -and $st.State -eq 'off' -and (Test-ChatqAutoHeldElsewhere ([string]$c.Id) $Live)) { $keep = $false }
        if ($keep) { $states[[string]$c.Id] = $st }
    }
    return $states
}

function Invoke-ChatOverlayAutoVerbs {
    <#
    The switch from overlay-cmd - the macOS menu's item, or a shell:
    auto-on, auto-ask and auto-off, the last one asked for set here
    (Set-ChatqAutoContinue) for every host, and taken out of -Verbs, so
    none is handed on to a renderer. Returns the verbs left, with reload
    added when one was set: every host then reads the config again, and the
    Windows panel draws its settings box anew. Never throws.
    #>
    param($Ctx, [object[]]$Verbs)
    $all = @($Verbs)
    $v = @($all | Where-Object { $_ -in 'auto-on', 'auto-ask', 'auto-off' }) | Select-Object -Last 1
    if (-not $v) { return $all }
    $left = @($all | Where-Object { $_ -notin 'auto-on', 'auto-ask', 'auto-off' })
    try {
        $null = Set-ChatqAutoContinue -Value ($v -replace '^auto-', '')
        $Ctx.CutAt = [datetime]::MinValue
        Write-ChatOverlayLog "auto-continue $($v -replace '^auto-', '') from overlay-cmd" -Always
        if ($left -notcontains 'reload') { $left += 'reload' }
    }
    catch { Write-ChatOverlayLog "auto-continue: $($_.Exception.Message)" }
    return $left
}

#endregion

#region auto-continue: the overlay's window (Windows) ---------------------------

function Invoke-ChatOverlayAutoChip {
    <#
    don't continue or continue, clicked on a row's chip. don't continue
    removes the continue auto-continue queued, its marker kept, so this
    cut-off is not queued again; continue queues one as the console's
    Continue does - a job you asked for, no marker. Neither counts as the
    chat seen: its unread dot stays. The tray says what was done. Never
    throws into the window's thread.
    #>
    param($H, $Row, [string]$Act)
    if (-not $H -or -not $Row) { return }
    try {
        $sid = [string](Get-ChatField $Row 'sessionId')
        $title = Format-ChatqAutoTitle ([string](Get-ChatField $Row 'title'))
        $say = $null
        if ($Act -eq 'dont') {
            $a = Get-ChatField $Row 'auto'
            $id = if ($a) { [string](Get-ChatField $a 'jobId') } else { '' }
            $j = if ($id) { Find-ChatqJob $id -Exact } else { $null }
            if (-not $j) { $j = @(Get-ChatqAutoJobs -SessionId $sid) | Select-Object -First 1 }
            $when = if ($j) { Get-ChatqAutoWhen $j } else { '' }
            if ($j -and (Remove-ChatqJob $j 'chip')) { $say = "$title will not be continued $when." }
            elseif ($j) {
                $now = Find-ChatqJob $j.id -Exact
                $say = if ($now -and $now.state -eq 'running') { "#$($j.seq) is running - it cannot be taken back now." } else { "#$($j.seq) could not be removed - its file is in use; try again." }
            }
            else { $say = 'That continue is gone already.' }
            Write-ChatOverlayLog "auto-continue: don't continue $($sid.Substring(0, [Math]::Min(8, $sid.Length))) from the chip" -Always
        }
        elseif ($Act -eq 'continue') {
            # through Invoke-ChatqContinueChats, as the console's Continue: the
            # row stays drawn until the next pass, and the chip comes back on
            # it - a second click, or one after the console's, finds the job
            # queued already rather than queueing a second continue
            $res = Invoke-ChatqContinueChats -Items @([pscustomobject]@{ Id = $sid; Title = [string](Get-ChatField $Row 'title'); Path = [string](Get-ChatField $Row 'path'); Cwd = [string](Get-ChatField $Row 'cwd') })
            $q = @($res.Queued)
            if ($q.Count) {
                $say = "Queued #$($q[0].seq), a continue for $title"
                try { $null = Request-ChatqWatcher -Wake poke } catch {}
            }
            elseif (@($res.Had).Count) { $say = "$title already has a job queued or running - nothing more queued." }
            elseif (@($res.Fails).Count -and [string]@($res.Fails)[0] -like '*: not found') { $say = "$title could not be read - nothing queued." }
            else { $say = "Nothing queued: $((@($res.Fails)[0] -split ': ', 2)[-1])" }
            Write-ChatOverlayLog "auto-continue: continue $($sid.Substring(0, [Math]::Min(8, $sid.Length))) from the chip" -Always
        }
        Hide-ChatOverlayChip $H
        # a pass at the next tick sees the queue as it is now
        if ($H.Ctx) { $H.Ctx.JobsSig = $null }
        if ($say) { Show-ChatOverlayBalloon $H $say }
    }
    catch { Write-ChatOverlayLog "auto chip: $($_.Exception.Message)" }
}

function Show-ChatOverlayAutoNotice {
    # Once, the first time the Windows overlay runs with the switch on - at
    # its start, or as Continue is chosen: the tray says what it does and
    # where to change it
    param($H)
    try {
        $cfg = Get-ChatqAutoConfig
        if (-not $cfg.On -or $cfg.Noticed) { return }
        Show-ChatOverlayBalloon $H 'chatq now continues chats the usage limit cuts off from here on, a minute after the reset. Settings (the two sliders) > Cut off > Ask or Leave changes it.' -Ms 10000
        $null = Update-ChatqAutoState { param($v) $v.Noticed = $true }
    }
    catch { Write-ChatOverlayLog "auto-continue notice: $($_.Exception.Message)" }
}

function Show-ChatOverlayAutoQueued {
    # after a pass: the first continue auto-continue ever queued is said in
    # the tray, with where to take it back
    param($H)
    try {
        if (-not $H.Ctx -or -not $H.Ctx.AutoQueued -or -not $H.Ctx.AutoQueued.Count) { return }
        $j = $H.Ctx.AutoQueued[0]
        $H.Ctx.AutoQueued.Clear()
        $cfg = Get-ChatqAutoConfig
        if ($cfg.Told) { return }
        $at = $null
        $s = if ($H.Ctx.AutoStates) { $H.Ctx.AutoStates[[string]$j.sessionId] } else { $null }
        if ($s -and $s.At) { $at = $s.At }
        # a time, or "after #11" - behind another continue, one at a time
        $when = if (-not $at) { '' } elseif ($at -match '^\d|^[A-Z][a-z]{2} ') { " at $at" } else { " $at" }
        Show-ChatOverlayBalloon $H "$(Format-ChatqAutoTitle $j.title) will be continued$when. Rest on its row for ""don't continue""." -Ms 8000
        $null = Update-ChatqAutoState { param($v) $v.Told = $true }
    }
    catch { Write-ChatOverlayLog "auto-continue: $($_.Exception.Message)" }
}

#endregion

#region auto-continue: the console (Windows) ------------------------------------

function Add-ChatConsoleAutoLine {
    # Under the To line, for a Claude chat picked: this chat's switch -
    # Default, which names what the switch says now, Always or Never.
    # Not for a Codex chat, nor + New chat.
    param($H)
    $C = $H.Con
    $t = $C.Target
    if (-not $t -or $t.Kind -eq 'new' -or $t.Provider -ne 'claude' -or -not $t.Id) { return }
    $cfg = Get-ChatqAutoConfig
    $cur = if ($cfg.Chats[[string]$t.Id]) { [string]$cfg.Chats[[string]$t.Id].auto } else { 'default' }
    $d = [System.Windows.Controls.DockPanel]::new()
    $d.Margin = [System.Windows.Thickness]::new(0, 3, 0, 0)
    $l = New-ChatOverlayText 'Auto-continue after a limit' 'dim' 11.5
    $l.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $l.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    [System.Windows.Controls.DockPanel]::SetDock($l, [System.Windows.Controls.Dock]::Left)
    [void]$d.Children.Add($l)
    $chips = New-ChatConsoleChips @('default', 'always', 'never') @("Default ($($cfg.Mode))", 'Always', 'Never') $cur {
        param($s, $e) $e.Handled = $true; Set-ChatConsoleAutoChat $script:ChatOverlayHost ([string]$s.Tag)
    }
    $tips = @{ default = "Follow the setting in the panel's settings box."; always = 'Continue this chat after every limit or 529, even with the switch on Ask or Leave.'; never = 'Never continue this chat by itself; its orange row stays until you do.' }
    foreach ($c in @($chips.Children)) { $c.ToolTip = $tips[[string]$c.Tag] }
    [void]$d.Children.Add($chips)
    $d.Tag = 'auto'
    [void]$C.To.Children.Add($d)
}

function Set-ChatConsoleAutoChat {
    # the console's per-chat chips: Set-ChatqAutoChat, and the status line
    # says what it did - never names the continue it removed
    param($H, [string]$Value)
    $C = $H.Con
    $t = $C.Target
    if (-not $t -or -not $t.Id) { return }
    try {
        $r = Set-ChatqAutoChat -Id ([string]$t.Id) -Title ([string]$t.Title) -Value $Value -By 'the console'
        $say = @($r.Messages | ForEach-Object { $_.Text.Trim() }) -join ' - '
        Set-ChatConsoleStatus $H $say
        $C.JobsSig = $null
        if ($H.Ctx) { $H.Ctx.CutAt = [datetime]::MinValue }
        Update-ChatConsoleTarget $H
        Update-ChatConsoleNow $H
    }
    catch { Set-ChatConsoleStatus $H "auto-continue: $($_.Exception.Message)" 'warn' }
}

function Invoke-ChatConsoleDontContinue {
    # Don't continue, in the Cut off list or on a job in the queue: one
    # click in both - Continue undoes it. The continue goes; its marker stays.
    param($H, [string]$JobId, [string]$SessionId)
    $j = if ($JobId) { Find-ChatqJob $JobId -Exact } else { $null }
    if (-not $j -and $SessionId) { $j = @(Get-ChatqAutoJobs -SessionId $SessionId) | Select-Object -First 1 }
    if (-not $j) { Set-ChatConsoleStatus $H 'that continue is gone already' 'warn'; return }
    if (-not (Remove-ChatqJob $j 'the console')) {
        $now = Find-ChatqJob $j.id -Exact
        Set-ChatConsoleStatus $H $(if ($now -and $now.state -eq 'running') { "#$($j.seq) is running - cancel it instead" } else { "#$($j.seq) could not be removed - its file is in use; try again" }) 'warn'
        return
    }
    Set-ChatConsoleStatus $H "#$($j.seq) removed - $(Format-ChatqAutoTitle $j.title) will not be continued $(Get-ChatqAutoWhen $j)"
    if ($H.Con.Sel -eq $j.id) { $H.Con.Sel = $null }
    Update-ChatConsoleNow $H
}

#endregion
