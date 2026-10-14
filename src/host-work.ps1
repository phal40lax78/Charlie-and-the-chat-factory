# Charlie-and-the-chat-factory, src/host-work.ps1: dot-sourced by Charlie-and-the-chat-factory.ps1
# in its turn, never on its own - see the list there.

#region the chats one VS Code window runs --------------------------------------
# A VS Code window runs its extensions in one process, the extension host, and
# the Claude extension starts a claude process under it for every chat the
# window has open. Restarting that host - which is how a new version of an
# extension gets loaded - or reloading the window ends every one of them: a
# turn in flight, a permission prompt, a workflow or a background agent, all
# gone. It happened twice on 2026-09-27, each time after a new chatq VSIX was
# installed from the command line while chats worked. So before the extension
# restarts its window, or reloads it by itself, it asks here which chats of
# that one window are working.

# Deferred: DEFERRED.md "A busy judgement per window"
function Get-ChatHostWork {
    <#
    The Claude chats whose process runs under one extension host, -HostPid
    (that host's process.pid, as the extension knows it), and what keeps
    each one working. The judgement is Test-ChatIdle's, made of one window's
    chats instead of one folder's - the registry first, then the transcript:
      turn        Claude calls it busy: a turn in flight
      prompt      Claude calls it waiting: a permission prompt, or a question
                  it asked
      run         a print-mode claude is going into it right now - a queued
                  prompt, a phone reply, anyone's claude -p - or a chatq job
                  is running into it. The run is not this window's and a
                  restart would not end it, but the window would load the
                  chat again part way through, a second writer beside it.
                  A running chatq job is one even when no process of the
                  window holds its chat: it is listed with no pids. So is
                  anyone's claude -p into a chat an idle process of this
                  window was ended for (Add-ChatIdleEnded): a view here may
                  still show it. No other chat's: any claude -p anywhere
                  would hold every reload
      background  a workflow or a background agent it started has not
                  reported back. The turn that started one has ended, so
                  Claude calls the chat idle while the work goes on; what a
                  print-mode run started died with that run
      ''          none of these
    Written says whether its transcript was written in the last -Seconds -
    by a record of a turn, not only on disk (Get-ChatLastWritten) - which
    Test-ChatIdle counts as live too. It is kept apart so the caller
    can leave out the chat a queued run has just written, as Test-ChatIdle's
    -Except does. A background shell is not counted - it is as often a
    server that never ends (DEFERRED.md), and a reload is not a question
    of whether the chat would wake up and write beside a run. Only a queued
    run into the chat waits on one, and for 20 minutes at most
    (Resolve-ChatqLiveAction).
    Returns HostPid, Known and Chats, one per session: SessionId, Pids, Cwd,
    Transcript, Why, Written, Since (its processes' oldest start, $null for
    a job's chat no process holds). Known is whether the processes' parents could
    be read at all. Off Windows they cannot, and every VS Code chat of the
    Claude home is listed, since any of them may be this window's: a restart
    then waits on other windows' chats too, which is the safe side.
    The registry only, never claude agents: the extension asks this every
    25 seconds while it waits, and that CLI can take 30 s to start.
    #>
    param([int]$HostPid, [string]$ConfigDir, [int]$Seconds = $script:ChatIdleSeconds, [datetime]$Now = (Get-Date))
    $claudeDir = Get-ChatqHomeDir 'claude' $ConfigDir
    $res = [pscustomobject]@{ HostPid = $HostPid; Known = $true; Chats = @() }
    $live = @(Read-ChatqSessionRegistry (Join-Path $claudeDir 'sessions') | Where-Object { Test-ChatqSessionAlive $_ })

    # which of the interactive processes are this window's: those whose
    # parents, walked up, reach its extension host - read in one snapshot of
    # every process, as the overlay reads them
    $mine = [System.Collections.Generic.List[object]]::new()
    $procs = @{}
    $ctx = @{}
    foreach ($e in $live) {
        $k = [string](Get-ChatField $e 'Kind')
        if ($k -and $k -ne 'interactive') { continue }   # a print-mode run: counted by its chat, below
        if (-not $procs.Taken) { $procs.Taken = $true; $procs.Table = Get-ChatProcessTable }
        if ($null -eq $procs.Table) {
            $res.Known = $false
            $ep = [string](Get-ChatField $e 'Entrypoint')
            if (-not $ep -or $ep -eq 'claude-vscode') { $mine.Add($e) }
            continue
        }
        if (@(Get-ChatOverlayProcessChain $ctx $e $procs) -contains $HostPid) { $mine.Add($e) }
    }
    # A chatq job running: its claude -p may not have written its registry
    # file yet. Looked at before any chat of the window is known, since a run
    # can go into a chat that no process of this window holds any more - a
    # run before it ended the window's idle process on purpose (liveIdle
    # stop, or a handover whose tab closed), yet a view here still shows the
    # chat - a side bar, the run's live view - and would load it part way
    # through. Every running one counts, whichever
    # window: runs end, so waiting on one too many is the safe side.
    $running = @(try { @(Get-ChatqJobs) | Where-Object { $_.state -eq 'running' -and $_.PSObject.Properties['sessionId'] -and $_.sessionId } } catch { })
    # The chats an idle process of this window was ended for, a print-mode
    # claude going into one now: its window's view may still show it, with
    # nothing of the window under it, and that run need not be chatq's. A
    # note counts while its window is the one it was taken in - its host
    # started when the note says (Test-ChatIdleEndedHost). Processes that
    # cannot be listed keep it by the pid alone: waiting on one run too many
    # is the safe side here too.
    $ended = @(Read-ChatIdleEnded | Where-Object { [int]$_.hostPid -eq $HostPid -and (Test-ChatPrintLive $live ([string]$_.sessionId)) })
    if ($ended.Count) {
        if (-not $procs.Taken) { $procs.Taken = $true; $procs.Table = Get-ChatProcessTable }
        if ($null -ne $procs.Table) { $ended = @($ended | Where-Object { Test-ChatIdleEndedHost $_ $procs.Table }) }
    }
    if (-not $mine.Count -and -not $running.Count -and -not $ended.Count) { return $res }
    $cut = $Now.AddSeconds(-$Seconds)
    $bySid = [ordered]@{}
    foreach ($e in $mine) {
        $sid = [string](Get-ChatField $e 'SessionId')
        if (-not $sid) { continue }
        if (-not $bySid.Contains($sid)) { $bySid[$sid] = [System.Collections.Generic.List[object]]::new() }
        $bySid[$sid].Add($e)
    }
    $res.Chats = @(foreach ($sid in @($bySid.Keys)) {
            $es = @($bySid[$sid])
            $cwd = [string](Get-ChatField $es[0] 'Cwd')
            $file = $null
            if ($sid -match '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') { $file = Find-ChatOverlayTranscript $claudeDir $cwd $sid }
            $wrote = if ($file) { try { (Get-Item -LiteralPath $file -EA Stop).LastWriteTime } catch { $null } } else { $null }
            $why = ''
            if (@($es | Where-Object { [string](Get-ChatField $_ 'Status') -eq 'busy' }).Count) { $why = 'turn' }
            elseif (@($es | Where-Object { [string](Get-ChatField $_ 'Status') -eq 'waiting' }).Count) { $why = 'prompt' }
            elseif ((Test-ChatPrintLive $live $sid) -or @($running | Where-Object { [string]$_.sessionId -eq $sid }).Count) { $why = 'run' }
            elseif ($wrote) {
                foreach ($e in $es) {
                    # untouched since this process started: it has started nothing
                    $since = Get-ChatqEntryStart $e
                    if ($wrote -lt $since) { continue }
                    # no print-mode run of it is alive (just above), so what
                    # one started is dead, and left out
                    if (@(Get-ChatBackgroundTasks $file $since -SkipPrint).Count) { $why = 'background'; break }
                }
            }
            # the oldest of its processes' starts: what one of them started
            # before it is not this window's to lose (Save-ChatHostWorkNote)
            $first = $null
            foreach ($e in $es) { $s = Get-ChatqEntryStart $e; if ($s -gt [datetime]::MinValue -and (-not $first -or $s -lt $first)) { $first = $s } }
            [pscustomobject]@{
                SessionId = $sid; Pids = [int[]]@($es | ForEach-Object { [int](Get-ChatField $_ 'Pid') }); Cwd = $cwd
                Transcript = $file; Why = $why; Written = (Test-ChatWrittenSince $file $wrote $cut); Since = $first
            }
        })
    # the running jobs no process of this window held: a run each
    $extra = @(foreach ($j in $running) {
            $sid = [string]$j.sessionId
            if ($bySid.Contains($sid)) { continue }
            $bySid[$sid] = $null
            $file = if ($j.PSObject.Properties['path'] -and $j.path) { [string]$j.path } else { $null }
            $wrote = if ($file) { try { (Get-Item -LiteralPath $file -EA Stop).LastWriteTime } catch { $null } } else { $null }
            [pscustomobject]@{
                SessionId = $sid; Pids = [int[]]@(); Cwd = [string](Get-ChatField $j 'cwd'); Transcript = $file; Why = 'run'
                Written = (Test-ChatWrittenSince $file $wrote $cut); Since = $null
            }
        })
    if ($extra.Count) { $res.Chats = @($res.Chats) + $extra }
    # the noted chats a claude -p goes into: a run each, with no pids
    $noted = @(foreach ($n in $ended) {
            $sid = [string]$n.sessionId
            if ($bySid.Contains($sid)) { continue }
            $bySid[$sid] = $null
            $e = @($live | Where-Object { [string](Get-ChatField $_ 'SessionId') -eq $sid }) | Select-Object -First 1
            $cwd = [string](Get-ChatField $e 'Cwd')
            $file = $null
            if ($sid -match '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') { $file = Find-ChatOverlayTranscript $claudeDir $cwd $sid }
            $wrote = if ($file) { try { (Get-Item -LiteralPath $file -EA Stop).LastWriteTime } catch { $null } } else { $null }
            [pscustomobject]@{
                SessionId = $sid; Pids = [int[]]@(); Cwd = $cwd; Transcript = $file; Why = 'run'
                Written = (Test-ChatWrittenSince $file $wrote $cut)
            }
        })
    if ($noted.Count) { $res.Chats = @($res.Chats) + $noted }
    return $res
}

function Add-ChatIdleEnded {
    <#
    A note that a window's idle process of a chat was ended, or left as its
    tab closed (Stop-ChatIdleProcess, Invoke-ChatqHandover): data/idle-ended.json, @{ notes }, each
    @{ sessionId; hostPid; hostStart; at } - the window by its extension
    host, and when that host started, so a pid taken by another process
    since is told apart. The window may still show the chat - the side bar
    keeps its old view with its process gone (S29) - and a claude -p going
    into it later would be loaded part way through by that window's reload
    (Get-ChatHostWork). A note lives as long as its window: one whose host
    is gone, or started at another time, is dropped as the next one is
    written, and none is kept past 7 days, or beyond the newest 200. Those
    hosts are looked up by their own pids (Get-ChatIdleEndedHosts), never
    by a query of every process: Show it writes this between ending the
    process and asking the window to show the chat, and that wait is the
    user's. The file is read and written under data/idle-ended.lock: Show
    it's child and the watcher's liveIdle stop can write at once, and a note
    lost would leave a window's reload not waiting. Never throws: the note
    is worth less than the end it follows.
    #>
    param([string]$SessionId, [int]$HostPid, $HostStart, [datetime]$Now = (Get-Date))
    if (-not $SessionId -or $HostPid -le 0) { return }
    try {
        $start = if ($HostStart -is [datetime] -and $HostStart -ne [datetime]::MinValue) { $HostStart.ToUniversalTime().ToString('o') } else { $null }
        $add = [pscustomobject][ordered]@{ sessionId = $SessionId; hostPid = $HostPid; hostStart = $start; at = $Now.ToUniversalTime().ToString('o') }
        $null = Invoke-ChatqLocked (Join-Path $script:ChatqData 'idle-ended.lock') {
            $had = @(Read-ChatIdleEnded)
            # the hosts looked up only when there are notes to look at
            $table = if ($had.Count) { Get-ChatIdleEndedHosts @($had | ForEach-Object { [int]$_.hostPid }) } else { $null }
            $cut = $Now.AddDays(-7)
            $keep = [System.Collections.Generic.List[object]]::new()
            foreach ($n in $had) {
                # the same chat in the same window: the new note stands for it
                if ([string]$n.sessionId -eq $SessionId -and [int]$n.hostPid -eq $HostPid) { continue }
                $at = ConvertTo-ChatqDate $n.at
                if (-not $at -or $at -lt $cut) { continue }
                if ($null -ne $table -and -not (Test-ChatIdleEndedHost $n $table)) { continue }
                $keep.Add($n)
            }
            $keep.Add($add)
            $list = @($keep | Select-Object -Last 200)
            Save-ChatqText $script:ChatIdleEndedPath (ConvertTo-Json -InputObject ([ordered]@{ notes = $list }) -Compress -Depth 4)
        }
    }
    catch {}
}

function Get-ChatIdleEndedHosts {
    # The processes of -Pids that are running, as a table by pid of @{ Pid;
    # Start } for Test-ChatIdleEndedHost: Get-Process on those pids alone,
    # milliseconds where a Win32_Process query of every process takes a
    # good part of a second. A start that cannot be read is $null, and the
    # note goes by the pid. The tests' process table stands in when set.
    param([int[]]$Pids)
    if ($script:ChatProcessTableSeam) { return (Get-ChatProcessTable) }   # tests
    $t = @{}
    $ids = @($Pids | Where-Object { $_ -gt 0 } | Select-Object -Unique)
    if (-not $ids.Count) { return $t }
    foreach ($p in @(Get-Process -Id $ids -EA SilentlyContinue)) {
        $st = try { $p.StartTime } catch { $null }
        $t[[int]$p.Id] = @{ Pid = [int]$p.Id; Start = $st }
    }
    return $t
}

function Read-ChatIdleEnded {
    # data/idle-ended.json's notes (Add-ChatIdleEnded), each with a chat and
    # a host; none when there is no file, or it cannot be read
    param([string]$Path = $script:ChatIdleEndedPath)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $o = try { [System.IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF) | ConvertFrom-Json } catch { $null }
    if (-not $o -or -not $o.PSObject.Properties['notes']) { return @() }
    return @(@($o.notes) | Where-Object { $_ -and $_.PSObject.Properties['sessionId'] -and $_.sessionId -and $_.PSObject.Properties['hostPid'] -and [int]$_.hostPid -gt 0 })
}

function Test-ChatIdleEndedHost {
    # Is a note's window still the one it was taken in? Its host's pid in
    # -Table (Get-ChatProcessTable), started when the note says, to 3 s. A
    # note or a table with no start goes by the pid alone. Pure.
    param($Note, [hashtable]$Table)
    if (-not $Note -or -not $Table) { return $false }
    $p = $Table[[int]$Note.hostPid]
    if (-not $p) { return $false }
    $want = ConvertTo-ChatqDate (Get-ChatField $Note 'hostStart')
    if (-not $want -or -not $p.Start) { return $true }
    return ([Math]::Abs(($p.Start - $want).TotalSeconds) -le 3)
}

function Test-ChatWrittenSince {
    # whether a transcript was written after -Cut by a chat at work: the
    # file's time first, which costs nothing, then its records' own
    # (Get-ChatLastWritten) - only for a file touched since
    param([string]$File, $Wrote, [datetime]$Cut)
    if (-not $File -or -not $Wrote -or $Wrote -le $Cut) { return $false }
    return [bool]((Get-ChatLastWritten $File $Wrote) -gt $Cut)
}

function ConvertTo-ChatHostWorkJson {
    # What the extension reads (readHostWork in extension/safe-restart.js):
    # one line of JSON. Every character past ASCII is written \uXXXX, since a
    # child's output reaches the extension through the console's code page,
    # and a folder may well be named in Hangul. Pure.
    param($Result)
    $o = [ordered]@{
        hostPid = [int]$Result.HostPid
        known   = [bool]$Result.Known
        chats   = @(foreach ($c in @($Result.Chats)) {
                if (-not $c) { continue }
                [ordered]@{
                    sessionId = [string]$c.SessionId
                    pids      = [int[]]@($c.Pids)
                    file      = $(if ($c.Transcript) { [string]$c.Transcript } else { $null })
                    why       = [string]$c.Why
                    written   = [bool]$c.Written
                }
            })
    }
    $j = $o | ConvertTo-Json -Compress -Depth 5
    return [regex]::Replace($j, '[^\x00-\x7F]', { param($m) '\u{0:x4}' -f [int][char]$m.Value })
}

#endregion

#region the chats a reload stopped ---------------------------------------------
# The look above keeps a reload from going ahead under working chats when
# chatq is asked. But a window still restarts under them - Reload now on the
# update notice, Reload anyway on chatq's own reload, a reload after Later -
# and each chat it cuts off stays cut off, its answer half written, a
# permission prompt or a workflow gone, and nobody told. So every look that
# finds work leaves a note of it (Save-ChatHostWorkNote), one per extension
# host; the overlay's cut-off look finds the notes whose host is gone
# (Get-ChatRestartCutOffs) and offers to continue what it cut off, through
# the reset ask (Get-ChatqResetAsk), as a chat the limit cut off is offered
# - once, on the overlay, the phone and the console. A window that goes
# down with no look before it - out of memory, a crash, Developer: Reload
# Window, another extension's update - leaves the note the Windows
# overlay's own passes keep (Update-ChatHostWorkNotes), and VS Code's own
# log says which it was (Get-ChatHostEndCause). With no overlay running,
# or off Windows, only a look's note is there (DEFERRED.md).

# data/host-work/<host pid>.json: what one extension host's chats were
# doing at its last look that found work
$script:ChatHostWorkDir = Join-Path $script:ChatqData 'host-work'
# how long a note is worth reading: the reset ask offers nothing older
$script:ChatHostWorkHours = 12
# how long a chat a process from before the note seems to hold is kept
# before it counts as another window's (Get-ChatRestartCutOffs): past the
# overlay's 10 s cache of the live processes, with room to spare
$script:ChatHostHeldSeconds = 60
# tests: a scriptblock ($hostPid, $hostStart) standing in for
# Test-ChatHostAlive's look at the process
$script:ChatHostAliveSeam = $null
# the overlay's own notes (Update-ChatHostWorkNotes): how long a chat seen
# working stays in its host's note after it stops, how often a note whose
# chats did not change is written again, and how long a note the
# extension's look wrote - as it waits to reload - is left as it is
$script:ChatHostWorkGraceSeconds = 30
$script:ChatHostWorkRewriteMinutes = 10
$script:ChatHostWorkTheirsSeconds = 60
# tests: a scriptblock standing in for the folders VS Code keeps its logs
# in (Get-ChatHostEndCause)
$script:ChatHostLogRootsSeam = $null
# how long after a look first finds a host gone its chats wait for VS
# Code's log to say why (Get-ChatRestartCutOffs): its lines come a moment
# after the host goes, seconds late while memory runs short - and never
# from a VS Code whose log is elsewhere, or whose own process was ended
$script:ChatHostCauseWaitSeconds = 30
# how long past the 10 s after a renderer's line Get-ChatHostEndCause
# waits before it counts the hosts that exited in them: a VS Code short
# of memory writes another host's exit seconds late
$script:ChatHostLogLagSeconds = 5

# Deferred: DEFERRED.md "Continue the chats a reload stopped"
function Save-ChatHostWorkNote {
    <#
    A look's answer (Get-ChatHostWork, -Result) kept as the note of what its
    extension host ran: data/host-work/<host pid>.json, with the host's
    start (-HostStart, epoch ms - a pid alone is used again by Windows),
    when, and each chat at work - a turn, a prompt, background work - with
    its folder, transcript, why, the transcript's size and its processes'
    oldest start. A run is left out: a print-mode claude is no process of
    the window, and a reload does not end it. Nothing at work - or which
    chats are the window's not known, where every VS Code chat is listed -
    removes the note: every chat of it is idle, or none can be told. The
    extension's command calls it after every look (hostWorkCommand in
    extension/safe-restart.js), so the notice's look writes one as it goes
    out and the wait's looks keep it up to date. Any other host's note
    past its 12 hours goes too: the overlay's own pass that prunes them
    runs only while it asks or shows cut-offs, and a host left after
    Later would leave its note for good. -By names a writer that is not
    the extension's look - the overlay's own passes write by 'overlay'
    (Update-ChatHostWorkNotes), which tells their notes apart. Prints
    nothing - the extension reads the look's one line - and never throws.
    #>
    param($Result, [int64]$HostStart = 0, [datetime]$Now = (Get-Date), [string]$By)
    try {
        # by the file's time, which is no earlier than the note's own: a
        # note is only ever kept longer by it, never cut short
        $old = $Now.AddHours(-$script:ChatHostWorkHours)
        foreach ($f in @(try { @(Get-ChildItem -LiteralPath $script:ChatHostWorkDir -Filter *.json -File -EA Stop) } catch { })) {
            if ($f.LastWriteTime -lt $old) { Remove-Item -LiteralPath $f.FullName -Force -EA SilentlyContinue }
        }
        $hp = [int]$Result.HostPid
        if ($hp -le 0) { return }
        $p = Join-Path $script:ChatHostWorkDir "$hp.json"
        $work = @(@($Result.Chats) | Where-Object { $_ -and [string]$_.Why -in 'turn', 'prompt', 'background' -and $_.Transcript })
        if (-not $Result.Known -or -not $work.Count) {
            if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -EA SilentlyContinue }
            return
        }
        $utc = { param($d) if ($d -is [datetime] -and $d -gt [datetime]::MinValue) { $d.ToUniversalTime().ToString('o') } else { $null } }
        $o = [ordered]@{
            v         = 1
            hostPid   = $hp
            hostStart = $(if ($HostStart -gt 0) { [DateTimeOffset]::FromUnixTimeMilliseconds($HostStart).UtcDateTime.ToString('o') } else { $null })
            at        = (& $utc $Now)
            chats     = @(foreach ($c in $work) {
                    $size = try { ([System.IO.FileInfo]::new([string]$c.Transcript)).Length } catch { 0 }
                    [ordered]@{
                        sessionId = [string]$c.SessionId; cwd = [string]$c.Cwd; file = [string]$c.Transcript; why = [string]$c.Why
                        size = [int64]$size; since = (& $utc (Get-ChatField $c 'Since'))
                    }
                })
        }
        if ($By) { $o['by'] = $By }
        Save-ChatqText $p ($o | ConvertTo-Json -Depth 4)
    }
    catch {}
}

function Update-ChatHostWorkNotes {
    <#
    The Windows overlay's own notes of what each VS Code window's chats are
    doing (Save-ChatHostWorkNote -By overlay), so a window that goes down
    with no look before it - out of memory, a crash, a reload no chatq
    notice asked - still leaves its cut-offs for Get-ChatRestartCutOffs.
    The extension looks only as it is about to reload. Each pass, from what
    the pass holds already: every live chat of the VS Code extension (-Live,
    entrypoint claude-vscode) by its window's extension host
    (Get-ChatEntryHost), and why it works, as Get-ChatHostWork judges it -
    busy a turn, waiting a prompt, a workflow or a background agent out
    (-Background, Update-ChatOverlayBackground's) background; a print-mode
    run going into it, or a chatq job running into it (-Alive, -Jobs), is
    no work of the window's. Shells are left out, as there.
    A chat seen working stays in its host's note for 30 s after it stops:
    a window going down can take its chats' processes, or their busy, a
    moment before its host. A note is written when its chats or their why
    change, and every 10 minutes besides, and only while its host runs - a
    note written after it died would date the chats' new processes to
    before it, and they would read as another window's. A note the
    extension's look wrote stands for a minute: its wait looks every 25 s.
    One for an earlier process of the same pid is the cut-off look's, and
    left alone. A host with nothing at work any more loses the overlay's
    note while it runs; a dead host's note is never touched - it is what
    the cut-off look reads. In $Ctx.HostWork: each chat process's host
    (Hosts), the chats seen working (Seen), and the notes written (Notes) -
    the overlay's own from before it started among them, while their host
    runs. Never throws.
    #>
    param($Ctx, [object[]]$Live, [object[]]$Alive, [hashtable]$Background, [object[]]$Jobs, [datetime]$Now = (Get-Date))
    try {
        if (-not $Ctx.HostWork) {
            $Ctx.HostWork = @{ Hosts = @{}; Seen = @{}; Notes = @{} }
            # The overlay's own notes from before it started - an update, a
            # restart - whose host still runs: taken for written here, so one
            # whose chats stopped meanwhile goes as any other. Left alone, it
            # would stay until its host went, and offer chats that stopped
            # long before.
            foreach ($f in @(try { @(Get-ChildItem -LiteralPath $script:ChatHostWorkDir -Filter *.json -File -EA Stop) } catch { })) {
                if ($f.BaseName -notmatch '^\d{1,9}$') { continue }
                $n = Read-ChatqJson $f.FullName
                if (-not $n -or [string](Get-ChatField $n 'by') -ne 'overlay') { continue }
                $ns = Get-ChatField $n 'hostStart'
                if (Test-ChatHostAlive ([int]$f.BaseName) $ns) {
                    $Ctx.HostWork.Notes[[int]$f.BaseName] = @{ Start = $ns; Sig = ''; At = [datetime]::MinValue; Stamp = $f.LastWriteTimeUtc.Ticks }
                }
            }
        }
        $hw = $Ctx.HostWork
        $running = @{}
        foreach ($j in @($Jobs)) { if ($j -and [string]$j.state -eq 'running' -and $j.sessionId) { $running[[string]$j.sessionId] = $true } }
        # each chat of the window's extension, by its host: one process list
        # a pass, taken only for a process whose host is not known yet
        $procs = @{}
        $keys = @{}
        $groups = [ordered]@{}
        foreach ($e in @($Live)) {
            if (-not $e -or [string](Get-ChatField $e 'Entrypoint') -ne 'claude-vscode') { continue }
            $sid = [string](Get-ChatField $e 'SessionId')
            if (-not $sid) { continue }
            $keys["$(Get-ChatField $e 'Pid')|$(Get-ChatField $e 'ProcStart')|$(Get-ChatField $e 'StartedAt')"] = $true
            $h = Get-ChatEntryHost $Ctx $e $procs
            if (-not $h) { continue }
            $k = "$($h.Pid)|$sid"
            if (-not $groups.Contains($k)) { $groups[$k] = @{ Host = $h; Sid = $sid; Es = [System.Collections.Generic.List[object]]::new() } }
            $groups[$k].Es.Add($e)
        }
        foreach ($k in @($hw.Hosts.Keys)) { if (-not $keys[$k]) { $hw.Hosts.Remove($k) } }
        foreach ($k in @($groups.Keys)) {
            $g = $groups[$k]
            $es = @($g.Es)
            $sid = $g.Sid
            $bg = if ($Background) { $Background[$sid] } else { $null }
            $why = if (@($es | Where-Object { [string]$_.Status -eq 'busy' }).Count) { 'turn' }
            elseif (@($es | Where-Object { [string]$_.Status -eq 'waiting' }).Count) { 'prompt' }
            elseif ($running[$sid] -or (Test-ChatPrintLive $Alive $sid)) { '' }
            elseif ($bg -and ([int]$bg.Workflows + [int]$bg.Agents) -gt 0) { 'background' }
            else { '' }
            $t = if ($Ctx.Text) { $Ctx.Text[$sid] } else { $null }
            $file = if ($t) { [string]$t.Path } else { '' }
            if (-not $why -or -not $file) { continue }
            $since = $null
            foreach ($e in $es) { $s = Get-ChatqEntryStart $e; if ($s -gt [datetime]::MinValue -and (-not $since -or $s -lt $since)) { $since = $s } }
            $hw.Seen[$k] = @{ Host = $g.Host; Sid = $sid; Why = $why; At = $Now; Since = $since; Cwd = [string](Get-ChatField $es[0] 'Cwd'); File = $file }
        }
        $byHost = @{}
        foreach ($k in @($hw.Seen.Keys)) {
            $s = $hw.Seen[$k]
            if (($Now - $s.At).TotalSeconds -gt $script:ChatHostWorkGraceSeconds) { $hw.Seen.Remove($k); continue }
            $hp = [int]$s.Host.Pid
            if (-not $byHost.ContainsKey($hp)) { $byHost[$hp] = [System.Collections.Generic.List[object]]::new() }
            $byHost[$hp].Add($s)
        }
        foreach ($hp in @(@($byHost.Keys) + @($hw.Notes.Keys) | Select-Object -Unique)) {
            $mine = $hw.Notes[$hp]
            $p = Join-Path $script:ChatHostWorkDir "$hp.json"
            $fi = [System.IO.FileInfo]::new($p)
            $stamp = if ($fi.Exists) { $fi.LastWriteTimeUtc.Ticks } else { 0L }
            if (-not $byHost.ContainsKey($hp)) {
                # Nothing at work there any more: the overlay's own note goes
                # while its host runs. A dead host's is the cut-off look's to
                # read, and one written over since is not the overlay's.
                if ($mine -and $stamp -and $stamp -eq $mine.Stamp -and (Test-ChatHostAlive $hp $mine.Start)) {
                    Remove-Item -LiteralPath $p -Force -EA SilentlyContinue
                }
                $hw.Notes.Remove($hp)
                continue
            }
            $chats = @($byHost[$hp] | Sort-Object { $_.Sid })
            $start = $chats[0].Host.Start
            $sig = "$(ConvertTo-ChatOverlayMs $start)|" + (@($chats | ForEach-Object { "$($_.Sid)=$($_.Why)" }) -join ',')
            if ($mine -and $mine.Sig -eq $sig -and $stamp -eq $mine.Stamp -and ($Now - $mine.At).TotalMinutes -lt $script:ChatHostWorkRewriteMinutes) { continue }
            if ($stamp -and -not ($mine -and $stamp -eq $mine.Stamp)) {
                $n = Read-ChatqJson $p
                if ($n) {
                    # an earlier process given the same pid: its cut-offs are
                    # the cut-off look's, and its note stays as it is
                    $ns = ConvertTo-ChatqDate (Get-ChatField $n 'hostStart')
                    if ($ns -and $start -and [Math]::Abs(($ns - $start).TotalSeconds) -gt 5) { $hw.Notes.Remove($hp); continue }
                    # the extension's look, waiting to reload: its note stands a while
                    $nat = ConvertTo-ChatqDate (Get-ChatField $n 'at')
                    if ([string](Get-ChatField $n 'by') -ne 'overlay' -and $nat -and ($Now - $nat).TotalSeconds -lt $script:ChatHostWorkTheirsSeconds) { continue }
                }
            }
            if (-not (Test-ChatHostAlive $hp $start)) { continue }
            $res = [pscustomobject]@{ HostPid = $hp; Known = $true; Chats = @($chats | ForEach-Object {
                        [pscustomobject]@{ SessionId = $_.Sid; Cwd = $_.Cwd; Transcript = $_.File; Why = $_.Why; Since = $_.Since }
                    })
            }
            Save-ChatHostWorkNote $res -HostStart ([int64](ConvertTo-ChatOverlayMs $start)) -Now $Now -By overlay
            $fi.Refresh()
            $hw.Notes[$hp] = @{ Start = $start; Sig = $sig; At = $Now; Stamp = $(if ($fi.Exists) { $fi.LastWriteTimeUtc.Ticks } else { 0L }) }
        }
    }
    catch { Write-ChatOverlayLog "host work: $($_.Exception.Message)" }
}

function Get-ChatEntryHost {
    <#
    The extension host a VS Code chat's claude runs under, as @{ Pid; Start
    }: the first Code process above it (Get-ChatOverlayProcessChain) - the
    Claude extension starts claude straight under its window's host - with
    its start from the process list. Kept in $Ctx.HostWork.Hosts by the
    chat's process, as its chain is: a process's parents never change. $null
    when it cannot be told - no process list, the chat's process not in it,
    which is asked again the next pass - or there is no Code above it,
    which is kept. -Procs: the pass's holder of the process list.
    #>
    param($Ctx, $Entry, [hashtable]$Procs)
    $key = "$(Get-ChatField $Entry 'Pid')|$(Get-ChatField $Entry 'ProcStart')|$(Get-ChatField $Entry 'StartedAt')"
    $hosts = $Ctx.HostWork.Hosts
    if ($hosts.ContainsKey($key)) { return $hosts[$key] }
    $chain = @(Get-ChatOverlayProcessChain $Ctx $Entry $Procs)
    if (-not $chain.Count) { return $null }
    if (-not $Procs.Taken) { $Procs.Taken = $true; $Procs.Table = Get-ChatProcessTable }
    $t = $Procs.Table
    if (-not $t -or -not $t.ContainsKey([int]$chain[0])) { return $null }
    $found = $null
    for ($i = 1; $i -lt $chain.Count; $i++) {
        $x = $t[[int]$chain[$i]]
        if ($x -and $x.Name -match '^Code( - Insiders)?$') { $found = @{ Pid = [int]$chain[$i]; Start = $x.Start }; break }
    }
    $hosts[$key] = $found
    return $found
}

function Test-ChatHostAlive {
    # Is the extension host a note names still that process: one with its
    # pid that started when it did, to 5 s? Windows gives a pid to another
    # process within minutes, and a note is read for hours. A note with no
    # start goes by the pid alone, and a process whose start cannot be read
    # counts as the host - the safe side: nothing is offered for it.
    param([int]$HostPid, $HostStart)
    if ($script:ChatHostAliveSeam) { return [bool](& $script:ChatHostAliveSeam $HostPid $HostStart) }   # tests
    if ($HostPid -le 0) { return $false }
    $p = Get-Process -Id $HostPid -EA SilentlyContinue
    if (-not $p) { return $false }
    # local time, as StartTime is: a UTC one would be off by the zone
    $HostStart = ConvertTo-ChatqDate $HostStart
    if (-not $HostStart) { return $true }
    $st = try { $p.StartTime } catch { $null }
    if (-not $st) { return $true }
    return ([Math]::Abs(($st - $HostStart).TotalSeconds) -le 5)
}

# Deferred: DEFERRED.md "Continue the chats a reload stopped"
function Get-ChatHostEndCause {
    <#
    Why an extension host ended, as VS Code's own log tells it: 'oom' when
    the window it served ran out of memory, 'crash' when it or that window
    crashed, '' when the log says neither - a reload, a window closed,
    VS Code quit, or no log to read. From main.log in each of VS Code's log
    sessions (%APPDATA%\Code\logs\<yyyyMMddTHHmmss>, and Code - Insiders')
    written since -From, its lines from -From to -To alone - a renderer's
    from 10 s before -From: a host that crashed logs its pid twice
    ("Extension host with pid P exited with code: <not 0>",
    "[UtilityProcess id: N, type: extensionHost, pid: P]: crashed with code
    C"). One whose window's renderer died exits as if asked to, code 0, a
    few seconds after a line that names no window ("CodeWindow: renderer
    process gone (reason: oom, code: C)"), so a renderer gone within 10 s
    before the host's exit is taken for its window's - unless more hosts
    exited in the 10 s after it than there are such lines: a window closed
    just after another ran out of memory, and either may be the one that
    did. 'pending' while the log has yet to say: the host's exit not in
    it yet - VS Code writes it a moment after, later still while memory
    runs short - or in it, -To under 15 s after a renderer's line before
    it: its 10 s, and 5 s for another host's exit written late. Two
    windows gone together may swap causes - most likely both out of
    memory, as on 2026-10-14. Read-only; never throws.
    #>
    param([int]$HostPid, [datetime]$From, [datetime]$To = (Get-Date))
    try {
        if ($HostPid -le 0) { return '' }
        $roots = if ($script:ChatHostLogRootsSeam) { @(& $script:ChatHostLogRootsSeam) }   # tests
        elseif ($script:ChatqIsWindows -and $env:APPDATA) { @('Code', 'Code - Insiders' | ForEach-Object { Join-Path (Join-Path $env:APPDATA $_) 'logs' }) }
        else { @() }
        $exit = $null
        $code = $null
        $crashed = $false
        $gone = [System.Collections.Generic.List[object]]::new()
        $ends = [System.Collections.Generic.List[datetime]]::new()   # every host's plain exit
        $logs = $false   # VS Code keeps its log here, so the host's exit gets a line
        $lines = [regex]'(?m)^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3}) \[\w+\] (.*?)\r?$'
        foreach ($root in $roots) {
            foreach ($d in @(try { @(Get-ChildItem -LiteralPath $root -Directory -EA Stop) } catch { })) {
                if ($d.Name -notmatch '^\d{8}T\d{6}$') { continue }
                $f = [System.IO.FileInfo]::new((Join-Path $d.FullName 'main.log'))
                if (-not $f.Exists) { continue }
                $logs = $true
                if ($f.LastWriteTime -lt $From.AddMinutes(-1)) { continue }
                foreach ($m in $lines.Matches([string](Read-ChatAllText $f.FullName))) {
                    $at = [datetime]::ParseExact($m.Groups[1].Value, 'yyyy-MM-dd HH:mm:ss.fff', [System.Globalization.CultureInfo]::InvariantCulture)
                    # from 10 s before -From: a renderer's line counts up to
                    # 10 s before its host's exit
                    if ($at -lt $From.AddSeconds(-10) -or $at -gt $To) { continue }
                    $msg = $m.Groups[2].Value
                    if ($msg -match "type: extensionHost, pid: $HostPid\]: crashed with code") { if ($at -ge $From) { $crashed = $true } }
                    elseif ($msg -match '^Extension host with pid (\d+) exited with code: (\S+?),') {
                        if ($Matches[2] -eq '0') { $ends.Add($at) }
                        if ($Matches[1] -eq "$HostPid" -and $at -ge $From) { $exit = $at; $code = $Matches[2] }
                    }
                    elseif ($msg -match 'renderer process gone \(reason: ([\w-]+)') { $gone.Add(@{ At = $at; Reason = $Matches[1] }) }
                }
            }
        }
        if ($crashed -or ($exit -and $code -ne '0')) { return 'crash' }
        # the host is gone and its exit not logged yet: the line comes a
        # moment on, seconds late from a VS Code short of memory
        if (-not $exit) { if ($logs) { return 'pending' }; return '' }
        $near = $null
        $first = $null
        $count = 0
        foreach ($g in $gone) {
            if ($g.At -gt $exit -or ($exit - $g.At).TotalSeconds -gt 10) { continue }
            $count++
            if (-not $near -or $g.At -gt $near.At) { $near = $g }
            if (-not $first -or $g.At -lt $first) { $first = $g.At }
        }
        if (-not $near) { return '' }
        # A renderer's line names no window, so any host that exits within
        # 10 s after it may be its window's. More of those exits than lines
        # - a window closed just after another ran out of memory - and none
        # is known (DEFERRED.md, Continue the chats a reload stopped); nor
        # until those 10 s are all in the log - 5 s on, for an exit VS Code
        # writes late: one missed would make the window seem the only one.
        $last = $near.At.AddSeconds(10)
        if ($To -lt $last.AddSeconds($script:ChatHostLogLagSeconds)) { return 'pending' }
        if (@($ends | Where-Object { $_ -ge $first -and $_ -le $last }).Count -gt $count) { return '' }
        if ($near.Reason -eq 'oom') { return 'oom' }
        if ($near.Reason -in 'crashed', 'abnormal-exit', 'killed', 'launch-failed', 'integrity-failure') { return 'crash' }
        return ''
    }
    catch { return '' }
}

function Format-ChatRestartCause {
    # What ended a window's chats (Get-ChatHostEndCause), in the words every
    # surface says it: 'oom' VS Code ran out of memory, 'crash' VS Code
    # crashed, anything else VS Code restarted. Pure.
    param([string]$Cause)
    if ($Cause -eq 'oom') { return 'VS Code ran out of memory' }
    if ($Cause -eq 'crash') { return 'VS Code crashed' }
    return 'VS Code restarted'
}

function Test-ChatRestartMid {
    # Whether a chat's last message (Get-ChatqLastTurn) owes an answer, read
    # as Test-ChatTranscriptBusy reads a transcript parked mid-turn: an
    # assistant tool_use - a tool running, or a prompt waiting on you - or a
    # user message, a prompt or a tool's result, with nothing after it. Not
    # a turn you stopped yourself (Test-ChatStoppedByHand), nor a slash
    # command's own records (<command-name>, <local-command-stdout>), which
    # no turn follows. An assistant message with no stop reason is not
    # taken for one cut part way: a finished answer can carry none too, and
    # a chat that finished is no cut-off. Pure.
    param($Last)
    if (-not $Last) { return $false }
    $t = ([string]$Last.Text).TrimStart()
    if ([string]$Last.Type -eq 'assistant') { return ([string]$Last.StopReason -eq 'tool_use') }
    if ([string]$Last.Type -ne 'user') { return $false }
    if ((Test-ChatStoppedByHand $Last) -or $t -match '^<(command-name|command-message|local-command-stdout|local-command-stderr)>') { return $false }
    return $true
}

# Deferred: DEFERRED.md "Continue the chats a reload stopped"
function Get-ChatRestartCutOffs {
    <#
    The chats a window's restart cut off, as cut-off rows the reset ask
    takes (Get-ChatqCutOffChats' shape, Why 'restart'): from the notes in
    data/host-work whose host is gone (Test-ChatHostAlive). Each chat of a
    note counts when, read now:
      - no process of it is at work, and no job is queued or running into
        it (-Live, the registry's live entries; -Jobs) - one at work is left
        for a later look;
      - none of its processes outlived the host - another window held it.
        One that seems to is kept, marked heldAt, and dropped only when a
        look a minute later still finds it: the old host's own process,
        killed, can read as alive for a moment (the overlay's -Live is up
        to 10 s old);
      - its transcript is there, no shorter than the note saw it, and has
        no turn written since the host went - the note's goneAt, set the
        first time a look finds the host gone, or the start of a process
        that holds the chat again, if earlier: past that the chat moved on;
      - it was not the limit or a 529, which the cut-off look has;
      - it was not you who stopped it last (Test-ChatStoppedByHand) - not
        even with a workflow it started still out;
      - and something was lost: its last message owes an answer
        (Test-ChatRestartMid) - or a workflow or background agent it
        started, since its processes did, never reported back
        (Select-ChatBackgroundOpen), read only for a chat the checks above
        left in, and not for one whose last message is a finished answer
        and whose note names no background work: its turn ended before
        the window went.
    A last message that cannot be read decides nothing: the chat is kept
    for a later look.
    A row names its cut-off by the last message's uuid (LimitUuid), so it
    is asked about once (Get-ChatqCutKey), and carries what was lost for
    the prompt that continues it (Get-ChatqRestartPrompt): Mid, and Tasks -
    Kind, Id, Note - and Cause, why the host went (Get-ChatHostEndCause:
    oom, crash, or '' for a restart), which every wording of it says
    (Format-ChatRestartCause). While the log cannot tell yet ('pending'),
    a note's chats are no rows, up to 30 s from goneAt: an ask is
    announced once, in the words of the look that first offers it. Their
    host pid goes into -Pending, for a look again soon. -Once: a pass
    that keeps no notes, chatoverlay -Print's - a note with no goneAt kept
    waits for nothing, as nothing here would ever keep one. -Asked: the
    answered keys; an answered chat is no row. -Prune (the overlay's own
    passes): a note keeps only the chats a later look may still offer - it
    goes once none is left, or once it is over 12 h old - and keeps goneAt
    and cause. -Cache: by note and chat, what a transcript said at its
    length and time. Never throws; newest first.
    #>
    param([object[]]$Live, [hashtable]$Asked, [object[]]$Jobs, [hashtable]$Cache, [hashtable]$Pending, [switch]$Prune, [switch]$Once, [datetime]$Now = (Get-Date))
    $out = [System.Collections.Generic.List[object]]::new()
    $files = @(try { @(Get-ChildItem -LiteralPath $script:ChatHostWorkDir -Filter *.json -File -EA Stop) } catch { })
    if (-not $files.Count) { if ($Cache) { $Cache.Clear() }; return @() }
    $bySid = @{}
    foreach ($e in @($Live)) {
        $sid = [string](Get-ChatField $e 'SessionId')
        if (-not $sid) { continue }
        if (-not $bySid.ContainsKey($sid)) { $bySid[$sid] = [System.Collections.Generic.List[object]]::new() }
        $bySid[$sid].Add($e)
    }
    $taken = @{}
    foreach ($j in @($Jobs)) { if ($j -and [string]$j.state -in 'queued', 'running' -and $j.sessionId) { $taken[[string]$j.sessionId] = $true } }
    $seen = @{}
    foreach ($f in $files) {
        if ($f.BaseName -notmatch '^\d+$') { continue }
        $n = Read-ChatqJson $f.FullName
        $at = if ($n) { ConvertTo-ChatqDate (Get-ChatField $n 'at') } else { $null }
        if (-not $at -or $at -lt $Now.AddHours(-$script:ChatHostWorkHours)) {
            # past its time, or not a note: a half-written one is never seen,
            # as Save-ChatqText swaps a file in whole
            if ($Prune) { Remove-Item -LiteralPath $f.FullName -Force -EA SilentlyContinue }
            continue
        }
        $hp = [int](Get-ChatField $n 'hostPid')
        if (Test-ChatHostAlive $hp (Get-ChatField $n 'hostStart')) { continue }
        $gone = ConvertTo-ChatqDate (Get-ChatField $n 'goneAt')
        $hadGone = [bool]$gone
        $dirty = $false
        # one ahead of now - the clock put back since - counts from now: the
        # wait below would otherwise last until the clock caught up
        if (-not $gone -or $gone -gt $Now) { $gone = $Now; Set-ChatqProp $n 'goneAt' $Now.ToUniversalTime().ToString('o'); $dirty = $true }
        # why the host went, from VS Code's log: kept once found, and once
        # two minutes have gone by with nothing found - its lines may come a
        # moment after the host is gone, and none ever comes for a reload
        $cause = [string](Get-ChatField $n 'cause')
        if (-not $n.PSObject.Properties['cause']) {
            $cause = Get-ChatHostEndCause $hp $at.AddSeconds(-5) $Now
            if ($cause -eq 'pending') {
                # Not sure yet - the host's exit not logged yet, or its
                # renderer's line seconds old: the chats wait, so the ask's
                # balloon and the phone, said once, say it in the right words.
                # A pass that keeps no notes (-Once) waits only on a goneAt
                # a host's pass kept: it would wait for ever on its own.
                if (($Now - $gone).TotalSeconds -lt $script:ChatHostCauseWaitSeconds -and ($hadGone -or -not $Once)) {
                    if ($null -ne $Pending) { $Pending[$hp] = $true }
                    if ($Prune -and $dirty) { try { Save-ChatqText $f.FullName ($n | ConvertTo-Json -Depth 5) } catch {} }
                    continue
                }
                $cause = ''
            }
            if ($cause -or ($Now - $gone).TotalSeconds -ge 120) { Set-ChatqProp $n 'cause' $cause; $dirty = $true }
        }
        $chats = @(Get-ChatField $n 'chats' | Where-Object { $_ })
        $keep = [System.Collections.Generic.List[object]]::new()
        foreach ($c in $chats) {
            try {
                $sid = [string](Get-ChatField $c 'sessionId')
                $file = [string](Get-ChatField $c 'file')
                if ($sid -cnotmatch '^[0-9A-Za-z-]+$' -or -not $file) { continue }
                $ents = if ($bySid.ContainsKey($sid)) { @($bySid[$sid]) } else { @() }
                $busy = $taken[$sid] -or @($ents | Where-Object {
                        $k = [string](Get-ChatField $_ 'Kind')
                        [string](Get-ChatField $_ 'Status') -in 'busy', 'waiting' -or ($k -and $k -ne 'interactive')
                    }).Count
                if ($busy) { $keep.Add($c); continue }
                $bound = $gone
                $outlived = $false
                foreach ($e in $ents) {
                    $s = Get-ChatqEntryStart $e
                    if ($s -le [datetime]::MinValue) { continue }
                    if ($s -lt $at) { $outlived = $true } elseif ($s -lt $bound) { $bound = $s }
                }
                if ($outlived) {
                    # Another window held it - or the old host's own process,
                    # killed, still reads as alive: the overlay's -Live is up
                    # to 10 s old, and a claude can outlive a killed host by a
                    # moment. So a first sighting only marks it (heldAt) and
                    # keeps it; it is dropped once a look a minute on still
                    # finds such a process.
                    $held = ConvertTo-ChatqDate (Get-ChatField $c 'heldAt')
                    if ($held -and ($Now - $held).TotalSeconds -ge $script:ChatHostHeldSeconds) { continue }
                    if (-not $held) { Set-ChatqProp $c 'heldAt' $Now.ToUniversalTime().ToString('o'); $dirty = $true }
                    $keep.Add($c)
                    continue
                }
                if ($c.PSObject.Properties['heldAt']) { $c.PSObject.Properties.Remove('heldAt'); $dirty = $true }
                $fi = [System.IO.FileInfo]::new($file)
                if (-not $fi.Exists -or $fi.Length -lt [int64](Get-ChatField $c 'size')) { continue }
                $ck = "$hp|$sid"
                $seen[$ck] = $true
                $sig = "$($fi.Length)|$($fi.LastWriteTimeUtc.Ticks)"
                $look = if ($Cache -and $Cache.ContainsKey($ck) -and $Cache[$ck].Sig -eq $sig) { $Cache[$ck].Look } else { $null }
                if (-not $look) {
                    # the tail only, which is cheap; the whole transcript is
                    # read for its background work below, and only for a chat
                    # still in the running
                    $look = @{ Last = (Get-ChatqLastTurn $file); Tasks = $null }
                    if ($Cache) { $Cache[$ck] = @{ Sig = $sig; Look = $look } }
                }
                $last = $look.Last
                # no last message to read - a read that failed, most likely:
                # not decided, so kept for a later look
                if (-not $last) { $keep.Add($c); continue }
                if ($last.Limit -or $last.Overloaded) { continue }
                if ($last.At -and $last.At -gt $bound) { continue }
                # You stopped it last: whatever that turn left running - a
                # workflow, which Claude Code 2.1.291 lets go on past a Stop -
                # you stopped too, as far as anything here can tell. Work a
                # later turn started would have left a record after it.
                if (Test-ChatStoppedByHand $last) { continue }
                $mid = Test-ChatRestartMid $last
                # A finished answer last, and no background work in the note:
                # its turn ended before the window went - a close or a quit
                # just after one - and nothing was lost, but for a workflow
                # that turn started seconds before, which the note has yet
                # to say (DEFERRED.md, Continue the chats a reload
                # stopped). Past that, the whole transcript, by the reader
                # the overlay's background look uses: it parses only the
                # lines that can start or end something, in a third of the
                # time of a read line by line - this runs on the thread the
                # Windows panel draws on.
                $ended = [string]$last.Type -eq 'assistant' -and [string]$last.StopReason -in 'end_turn', 'stop_sequence' -and
                    [string](Get-ChatField $c 'why') -ne 'background'
                if ($null -eq $look.Tasks -and -not $ended) {
                    $since = ConvertTo-ChatqDate (Get-ChatField $c 'since')
                    if (-not $since) { $since = [datetime]::MinValue }
                    $scan = @{}
                    Update-ChatBackgroundScan $scan $file -MaxBytes ([int]::MaxValue)
                    $look.Tasks = @(if ($scan.Done) { Select-ChatBackgroundOpen $scan.Open $since -SkipPrint -SessionDir (Get-ChatSessionDir $file) })
                }
                $tasks = @($look.Tasks | Where-Object { $_ })
                if (-not $mid -and -not $tasks.Count) { continue }
                # the title from the transcript, kept with the look: the
                # index, loaded for it, would stay parsed for the overlay's
                # life (Get-ChatqCutOffChats)
                if ($null -eq $look.Title) {
                    $rec = try { & $script:ChatProviders['claude'].Describe $fi } catch { $null }
                    $look.Title = if ($rec -and $rec.Title -and $rec.Title -ne '(empty)') { [string]$rec.Title } else { $sid }
                }
                $title = $look.Title
                $cwd = [string](Get-ChatField $c 'cwd')
                if (-not $cwd) { $cwd = [string]$last.Cwd }
                $row = [pscustomobject]@{
                    Id = $sid; Title = $title; Group = $fi.Directory.Name; At = $bound; ResetsAt = $null; Why = 'restart'
                    Path = $fi.FullName; Cwd = $cwd; LimitUuid = $(if ($last.Uuid) { [string]$last.Uuid } else { "h$hp" })
                    Mid = [bool]$mid; HostPid = $hp; Cause = $cause
                    Tasks = @($tasks | ForEach-Object { [pscustomobject]@{ Kind = [string]$_.Kind; Id = [string]$_.Id; Note = [string]$_.Note } })
                }
                $key = Get-ChatqCutKey $row
                if (-not $key -or ($Asked -and $Asked[$key])) { continue }
                $keep.Add($c)
                $out.Add($row)
            }
            catch { $keep.Add($c) }
        }
        if ($Prune) {
            if (-not $keep.Count) { Remove-Item -LiteralPath $f.FullName -Force -EA SilentlyContinue }
            elseif ($dirty -or $keep.Count -ne $chats.Count) {
                Set-ChatqProp $n 'chats' @($keep.ToArray())
                try { Save-ChatqText $f.FullName ($n | ConvertTo-Json -Depth 5) } catch {}
            }
        }
    }
    if ($Cache) { foreach ($k in @($Cache.Keys)) { if (-not $seen[$k]) { $Cache.Remove($k) } } }
    return @($out | Sort-Object At -Descending)
}

#endregion
