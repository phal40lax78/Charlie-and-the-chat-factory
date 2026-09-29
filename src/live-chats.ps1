# claude-codex-chat-manager, src/live-chats.ps1: dot-sourced by claude-codex-chat-manager.ps1
# in its turn, never on its own - see the list there.

#region live chats ------------------------------------------------------------
# Each VS Code window keeps a claude process alive for every chat opened in it,
# not just the one on screen, and clicking a chat in the history list switches
# back to that live process rather than re-reading the transcript. A run
# delivered from outside lands in the transcript that process never re-reads.

function Get-ChatqLiveSessions {
    # claude agents --json lists them all, panel tabs included, with no TTY.
    # ~/.claude/sessions/<pid>.json is the registry behind it - the fallback.
    # -RegistryOnly goes straight to it: a click waiting on an answer should
    # not wait up to 30 s for a CLI to start.
    param([string]$ConfigDir, [switch]$RegistryOnly)
    $exe = if ($RegistryOnly) { $null } else { Find-ChatqExe claude }
    if ($exe) {
        $buf = [System.Collections.Generic.List[string]]::new()
        try {
            $null = Invoke-ChatqProcess -Exe $exe -ArgList @('agents', '--json') -StdIn '' -TimeoutSec 30 `
                -SetEnv @{ CLAUDE_CONFIG_DIR = $ConfigDir } -OnLine { param($l) $buf.Add($l) }
            $list = ($buf -join "`n") | ConvertFrom-Json
            if ($null -ne $list) {
                return @($list | ForEach-Object {
                        $ep = if ($_.PSObject.Properties['entrypoint']) { [string]$_.entrypoint } else { $null }
                        [pscustomobject]@{ SessionId = $_.sessionId; Pid = $_.pid; Status = $_.status; Kind = $_.kind; WaitingFor = $_.waitingFor; ProcStart = $null; StartedAt = $_.startedAt; Entrypoint = $ep }
                    })
            }
        }
        catch {}
    }
    # A registry file can outlive its process, and the pid be reused by
    # something else - only a claude that started when the file says counts.
    $dir = Join-Path (Get-ChatqHomeDir 'claude' $ConfigDir) 'sessions'
    return @(Read-ChatqSessionRegistry $dir | Where-Object { Test-ChatqSessionAlive $_ } | ForEach-Object {
            [pscustomobject]@{ SessionId = $_.SessionId; Pid = $_.Pid; Status = $_.Status; Kind = $_.Kind; WaitingFor = $_.WaitingFor; ProcStart = $_.ProcStart; StartedAt = $_.StartedAt; Entrypoint = $_.Entrypoint }
        })
}

function Read-ChatqSessionRegistry {
    <#
    Claude Code's own list of what runs: sessions/<pid>.json, one per process,
    rewritten as its status moves between idle, busy and waiting. Only
    <digits>.json is read. The <pid>.<hash>.key beside each one is that
    session's messaging secret, and is never opened - nor is the file's
    messagingSocketPath taken: only the fields below are.
    -Cache (a hashtable kept between calls) re-parses only a file whose length
    or write time moved, which is what lets the overlay list it every 2 s.
    It also carries StatusUpdatedAt across a rewrite that left the status
    where it was: Claude Code stamps that field on every write.
    #>
    param([string]$Dir, [hashtable]$Cache)
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir)) { return @() }
    $seen = @{}
    $out = foreach ($f in @(Get-ChildItem -LiteralPath $Dir -Filter *.json -File -EA SilentlyContinue)) {
        if ($f.Name -notmatch '^\d+\.json$') { continue }
        $key = "$($f.Length)|$($f.LastWriteTimeUtc.Ticks)"
        $seen[$f.FullName] = $true
        $hit = if ($Cache) { $Cache[$f.FullName] } else { $null }
        if ($hit -and $hit.Key -eq $key) { if ($hit.Entry) { $hit.Entry }; continue }
        # one try, no waiting: a file caught mid-write reads again next pass,
        # and until then the last good copy stands
        $o = try { [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { $null }
        if (-not $o -or -not $o.pid) {
            if ($hit -and $hit.Entry) { $hit.Entry }
            continue
        }
        $p = { param($n) if ($o.PSObject.Properties[$n]) { $o.$n } else { $null } }
        $e = [pscustomobject]@{
            Pid = [int]$o.pid; SessionId = [string](& $p 'sessionId'); Cwd = [string](& $p 'cwd')
            Status = [string](& $p 'status'); WaitingFor = & $p 'waitingFor'; Name = [string](& $p 'name')
            Kind = [string](& $p 'kind'); ProcStart = & $p 'procStart'; StartedAt = & $p 'startedAt'
            UpdatedAt = & $p 'updatedAt'; StatusUpdatedAt = & $p 'statusUpdatedAt'; PidDomain = [string](& $p 'pidDomain')
            # claude-vscode for a VS Code panel's process, something else for a terminal's
            Entrypoint = [string](& $p 'entrypoint')
            # the CLI's own version: the question hook asks for one it was tried on (src/ask.ps1)
            Version = [string](& $p 'version')
        }
        # statusUpdatedAt moves on every write of the file, not only when the
        # status does - a limit reset rewrites them all at once, and every
        # chat's "busy 40m" would read "busy 0m". The same session still in
        # the same status keeps the time it was first seen in it.
        if ($hit -and $hit.Entry -and $hit.Entry.StatusUpdatedAt -and $hit.Entry.SessionId -eq $e.SessionId -and $hit.Entry.Status -eq $e.Status) {
            $e.StatusUpdatedAt = $hit.Entry.StatusUpdatedAt
        }
        if ($Cache) { $Cache[$f.FullName] = @{ Key = $key; Entry = $e } }
        $e
    }
    if ($Cache) { foreach ($k in @($Cache.Keys)) { if (-not $seen[$k]) { $Cache.Remove($k) } } }
    return @($out)
}

function Test-ChatqSessionAlive {
    <#
    Is the process a registry entry names still that session? The file
    outlives a crash, and Windows hands a pid to something else within
    minutes. So: a claude or node process with that pid, on this machine,
    started when the entry says - to 3 s by procStart where that is a FILETIME,
    and never more than 10 s after startedAt, which is what catches a pid
    reused by a later process.
    -Procs is a pid-keyed snapshot, so a pass over many entries asks the OS once.
    #>
    param($Entry, [hashtable]$Procs)
    if ($script:ChatqAliveSeam) { return [bool](& $script:ChatqAliveSeam $Entry) }   # tests
    if (-not $Entry -or -not $Entry.Pid) { return $false }
    # "win32:<host>": a registry synced in from another machine names its own
    if ($Entry.PidDomain -match '^win32:(.+)$' -and $Matches[1] -ne [Environment]::MachineName) { return $false }
    $pr = if ($Procs) { $Procs[[int]$Entry.Pid] } else { Get-Process -Id $Entry.Pid -EA SilentlyContinue }
    if (-not (Test-ChatqClaudeProcess $pr $Entry.ProcStart)) { return $false }
    if ($Entry.StartedAt) {
        try {
            $began = [System.DateTimeOffset]::FromUnixTimeMilliseconds([int64]$Entry.StartedAt).LocalDateTime
            if (($pr.StartTime - $began).TotalSeconds -gt 10) { return $false }
        }
        catch {}
    }
    return $true
}

# how long a queued run waits on a background shell alone before it goes in
# beside it: a dev server never ends (Resolve-ChatqLiveAction)
$script:ChatqShellWaitMinutes = 20

function Resolve-ChatqLiveAction {
    <#
    run    nothing holds the chat - the next click on it loads the run from disk
    defer  busy or waiting: someone, or Claude's own auto-continue, is using it
           - or background work its window's process started is still out,
           which wakes the chat when it reports back and writes beside the run
    stop   idle: end that process first, so the next click has to re-load
    warn   idle: run anyway and say to reload the window before typing there
    The idle case is config liveIdle ('warn' until the panel is known to
    recover cleanly from 'stop'); this is the one place it is decided, under
    either setting.
    Background work defers with Why 'background', Since (when the oldest of
    it started) and Note (what it is, where known). An agent or a workflow
    holds the chat for as long as it runs, as a busy chat does. A background
    shell only while the process still has shells under it - one ended from
    the task list leaves no mark - and 20 minutes from its start at most: a
    dev server never ends. Where the shells cannot be counted (off Windows)
    a shell holds nothing. A wait on shells alone is ShellOnly, which never
    counts towards giving up, and past its 20 minutes the idle action comes
    back with Beside 'background': the run goes in beside the chat with no
    handover, since closing its tab would end the server.
    #>
    param($Job, [object[]]$Live, [datetime]$Now = (Get-Date))
    if ($Job.provider -ne 'claude') { return @{ Action = 'run' } }
    $hit = @($Live | Where-Object { $_.SessionId -eq $Job.sessionId })
    if (-not $hit) { return @{ Action = 'run' } }
    if (@($hit | Where-Object { $_.Status -in 'busy', 'waiting' })) { return @{ Action = 'defer'; Live = $hit } }
    $cfg = Get-ChatqConfig
    $idle = if ($cfg.liveIdle -in 'stop', 'warn') { $cfg.liveIdle } else { 'warn' }
    $bg = Get-ChatqLiveBackground $Job $hit
    if (-not $bg) { return @{ Action = $idle; Live = $hit } }
    $held = @(@($bg.Work) + @($bg.Shells))
    $first = $null
    foreach ($t in $held) { if ($t.At -and (-not $first -or $t.At -lt $first.At)) { $first = $t } }
    if (-not $first) { $first = $held[0] }
    $since = if ($first.At) { $first.At } else { $Now }
    $note = $first.Note
    if (-not $note) { foreach ($t in $held) { if ($t.Note) { $note = $t.Note; break } } }
    $out = @{ Action = 'defer'; Live = $hit; Why = 'background'; Since = $since; Note = $note; ShellOnly = -not @($bg.Work).Count }
    if ($out.ShellOnly -and $Now -ge $since.AddMinutes($script:ChatqShellWaitMinutes)) {
        $out.Action = $idle
        $out.Beside = 'background'
    }
    return $out
}

function Get-ChatqLiveBackground {
    <#
    Resolve-ChatqLiveAction's reading: what the chat's live interactive
    processes (-Live, its own entries, none busy) started and still have out
    - @{ Work; Shells }, starts as Step-ChatBackgroundLine keeps them - or
    $null for none. Only starts since each process started: the work dies
    with the process that ran it. None a print-mode run made: no job of
    the chat runs yet, and claude -p stamps its entries sdk-*, whose work
    died with it. Shells as many of the newest as run under that process
    (Get-ChatShellChildCount), and none where that cannot be told.
    #>
    param($Job, [object[]]$Live)
    $path = [string]$Job.path
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $mine = @($Live | Where-Object {
            $k = [string](Get-ChatField $_ 'Kind')
            (-not $k -or $k -eq 'interactive') -and [string](Get-ChatField $_ 'Entrypoint') -cnotin $script:ChatSdkEntrypoints
        })
    if (-not $mine.Count) { return $null }
    $wrote = (Get-Item -LiteralPath $path).LastWriteTime
    $open = $null
    $dir = Get-ChatSessionDir $path
    $work = [System.Collections.Generic.List[object]]::new()
    $shells = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    foreach ($e in $mine) {
        $since = Get-ChatqEntryStart $e
        # untouched since this process started: it has started nothing
        if ($wrote -lt $since) { continue }
        if ($null -eq $open) { $open = Read-ChatBackgroundOpen $path }
        if (-not $open -or -not $open.Count) { break }
        $got = @(Select-ChatBackgroundOpen $open $since -SkipPrint -Shells -SessionDir $dir)
        $sh = @($got | Where-Object { $_.Kind -eq 'shell' })
        if ($sh.Count) {
            $n = Get-ChatShellChildCount @([int](Get-ChatField $e 'Pid'))
            $sh = if ($null -eq $n) { @() } elseif ($n -lt $sh.Count) { @($sh | Select-Object -Last $n) } else { $sh }
        }
        foreach ($t in @($got | Where-Object { $_.Kind -ne 'shell' })) { if (-not $seen[$t.Id]) { $seen[$t.Id] = $true; $work.Add($t) } }
        foreach ($t in $sh) { if (-not $seen[$t.Id]) { $seen[$t.Id] = $true; $shells.Add($t) } }
    }
    if (-not $work.Count -and -not $shells.Count) { return $null }
    return [pscustomobject]@{ Work = @($work); Shells = @($shells) }
}

function Get-ChatField {
    # a property that may be missing, read without tripping StrictMode
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Get-ChatqEntryStart {
    # when a live entry's process started: what it says, else the process's own
    param($Entry)
    $at = Get-ChatField $Entry 'StartedAt'
    if ($at) { try { return [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$at).LocalDateTime } catch {} }
    try { return (Get-Process -Id ([int](Get-ChatField $Entry 'Pid')) -EA Stop).StartTime } catch { return [datetime]::MinValue }
}

function Get-ChatqStillThere {
    # Which of -Pids still hold the chat: a registry file naming it, whose
    # process is still that session (Test-ChatqSessionAlive). One that left
    # by itself took its file with it; one killed left the file behind and
    # its pid dead. The registry alone: this is asked every 250 ms.
    param([string]$ConfigDir, [string]$SessionId, [int[]]$Pids)
    $want = @($Pids | Where-Object { $_ })
    if (-not $want.Count) { return @() }
    $reg = @(Read-ChatqSessionRegistry (Join-Path (Get-ChatqHomeDir 'claude' $ConfigDir) 'sessions'))
    return @($want | Where-Object {
            $p = $_
            @($reg | Where-Object { $_.Pid -eq $p -and [string]$_.SessionId -eq $SessionId -and (Test-ChatqSessionAlive $_) }).Count
        })
}

function Test-ChatVsCodeOwned {
    # Is this claude a VS Code window's? Its registry entry says claude-vscode,
    # and its parent is a Code.exe that started before it - the window's
    # extension host (S29). A terminal's claude, even in VS Code's own
    # terminal, has a shell for a parent. The parent is worth its lookup for
    # its pid too: that names the one window holding the chat (hostPids).
    # Pure, for the tests.
    param([string]$Entrypoint, [string]$ParentName, $ParentStart, $ChildStart)
    if ($Entrypoint -and $Entrypoint -ne 'claude-vscode') { return $false }
    if ($ParentName -notmatch '^Code( - Insiders)?$') { return $false }
    if ($ParentStart -and $ChildStart -and $ParentStart -gt $ChildStart) { return $false }  # parent pid reused
    return $true
}

function Get-ChatParentProcess {
    # The process a chat's claude runs under, @{ Pid; Name; StartTime } - or
    # $null when that cannot be told, and off Windows, where there is no CIM
    # to ask.
    param($Entry, $Process)
    if ($script:ChatParentSeam) { return (& $script:ChatParentSeam $Entry) }   # tests
    if (-not $script:ChatqIsWindows) { return $null }
    try {
        $id = if ($Process) { [int]$Process.Id } else { [int](Get-ChatField $Entry 'Pid') }
        $w = Get-CimInstance Win32_Process -Filter "ProcessId = $id" -EA Stop | Select-Object -First 1
        if (-not $w) { return $null }
        $pp = Get-Process -Id ([int]$w.ParentProcessId) -EA Stop
        $st = try { $pp.StartTime } catch { $null }
        return @{ Pid = [int]$pp.Id; Name = [string]$pp.ProcessName; StartTime = $st }
    }
    catch { return $null }
}

function Stop-ChatIdleProcess {
    <#
    The one place a chat's old process is ended, so the next look at the chat
    loads it from disk (spike S29). Only a VS Code window's process, and only
    one Claude calls idle with no workflow or background agent of its own in
    flight - its registry file read again just before it goes. A terminal's
    claude is never ended. OldProcess says what became of it:
      none   nothing holds the chat
      held   busy, waiting, or background work in flight - or a print-mode
             claude going into the chat right now: nothing ended
      other  a terminal's claude holds it: nothing ended, and the chat is not
             to be shown in VS Code as well - that would be a second writer
      live   -JudgeOnly: a window's idle process, left running
      ended  every window's process of it ended
      kept   one could not be checked or ended (no registry file for it while
             it runs, off Windows): left running
    HostPids: the Code.exe each window's process runs under, taken before
    anything is ended - which window holds the chat. With -JudgeOnly they are
    taken for a held chat too, and a terminal's claude says other even while
    it works.
    Background work is told apart by who started it, never by when: what a
    print-mode run started died with it, what the window's process started
    is its own (Get-ChatBackgroundTasks -SkipPrint).
    Show it closes the chat's tab first and then asks this to end what is
    left, so it narrows what counts: -HostPid, only processes of that
    window (their parent is its extension host); -StartedBefore, only
    those started before then - never the one a tab opened meanwhile
    started; -GraceSeconds, a wait of up to that long for them to leave by
    themselves, as a closed tab's process does within about 7 s. One that
    left counts as ended, and nothing is taken down.
    #>
    param([string]$SessionId, [string]$Transcript, [string]$ConfigDir, [object[]]$Live, [switch]$JudgeOnly,
        [int]$GraceSeconds = 0, [int]$HostPid = 0, $StartedBefore = $null)
    $res = [pscustomobject]@{ OldProcess = 'none'; Stopped = [int[]]@(); HostPids = [int[]]@(); Terminal = $false }
    if (-not $PSBoundParameters.ContainsKey('Live')) { $Live = @(Get-ChatqLiveSessions $ConfigDir) }
    # a print-mode claude writing into the chat now - someone's claude -p, or
    # a run not chatq's: a window shown the chat meanwhile would hold a copy
    # from part way through, and a second writer
    if (Test-ChatPrintLive $Live $SessionId) { $res.OldProcess = 'held'; return $res }
    $before = ConvertTo-ChatqDate $StartedBefore
    # off Windows no parent can be read, and nothing is ended anyway (kept)
    $byHost = $HostPid -and ($script:ChatParentSeam -or $script:ChatqIsWindows)
    # interactive only: an ended print-mode run of the same chat holds nothing
    $mine = [System.Collections.Generic.List[object]]::new()
    foreach ($e in @($Live)) {
        if (-not $e -or [string](Get-ChatField $e 'SessionId') -ne $SessionId) { continue }
        $k = [string](Get-ChatField $e 'Kind')
        if ($k -and $k -ne 'interactive') { continue }
        if ($before -and (Get-ChatqEntryStart $e) -ge $before) { continue }
        if ($byHost) {
            $par = Get-ChatParentProcess $e $null
            if (-not $par -or [int](Get-ChatField $par 'Pid') -ne $HostPid) { continue }
        }
        $mine.Add($e)
    }
    if (-not $mine.Count) { return $res }
    $held = $false
    foreach ($e in $mine) {
        if ([string](Get-ChatField $e 'Status') -in 'busy', 'waiting') { $held = $true; break }
    }
    # idle, as Claude sees it - which a turn that sent work to the background
    # also is, while that work goes on. No print-mode run of it is alive (just
    # above), so what one started is dead and left out.
    if (-not $held -and $Transcript -and (Test-Path -LiteralPath $Transcript)) {
        $wrote = (Get-Item -LiteralPath $Transcript).LastWriteTime
        foreach ($e in $mine) {
            $since = Get-ChatqEntryStart $e
            if ($wrote -lt $since) { continue }
            if (@(Get-ChatBackgroundTasks $Transcript $since -SkipPrint).Count) { $held = $true; break }
        }
    }
    # Held, and about to be ended: said at once, whoever's it is - nothing is
    # ended either way. Only judging (the chip, a run with someone at the
    # PC), whose it is still matters: a terminal's claude mid-turn is other,
    # or a tab would open beside it as a second writer, and a window's is
    # named, so that window is the one brought forward.
    if ($held -and -not $JudgeOnly) { $res.OldProcess = 'held'; return $res }

    # whose each one is, parent first: a window's, or a terminal's
    $ours = [System.Collections.Generic.List[object]]::new()
    $hosts = [System.Collections.Generic.List[int]]::new()
    foreach ($e in $mine) {
        $pr = Get-Process -Id ([int](Get-ChatField $e 'Pid')) -EA SilentlyContinue
        if (-not $script:ChatParentSeam) {
            if (-not $pr) { continue }   # gone since the list was made
            if (-not $script:ChatqIsWindows) {
                # nothing to ask for its parent here: the registry's word
                # alone, and never ended (kept, below)
                $ep = [string](Get-ChatField $e 'Entrypoint')
                if ($ep -and $ep -ne 'claude-vscode') { $res.Terminal = $true } else { $ours.Add($e) }
                continue
            }
        }
        $par = Get-ChatParentProcess $e $pr
        $childStart = if ($pr) { try { $pr.StartTime } catch { $null } } else { $null }
        $owned = [bool]$par -and (Test-ChatVsCodeOwned ([string](Get-ChatField $e 'Entrypoint')) ([string](Get-ChatField $par 'Name')) (Get-ChatField $par 'StartTime') $childStart)
        if (-not $owned) { $res.Terminal = $true; continue }
        $ours.Add($e)
        $hp = [int](Get-ChatField $par 'Pid')
        if ($hp -and -not $hosts.Contains($hp)) { $hosts.Add($hp) }
    }
    $res.HostPids = [int[]]$hosts.ToArray()
    # a terminal holds it: any refresh in VS Code would start a second writer
    if ($res.Terminal) { $res.OldProcess = 'other'; return $res }
    if ($held) { $res.OldProcess = 'held'; return $res }
    if (-not $ours.Count) { return $res }
    if ($JudgeOnly) { $res.OldProcess = 'live'; return $res }

    # each one read again from its registry file, then ended at once: the gap
    # someone could start typing in is the time taskkill takes to start
    $dir = Join-Path (Get-ChatqHomeDir 'claude' $ConfigDir) 'sessions'
    $kept = $false
    $stopped = [System.Collections.Generic.List[int]]::new()
    $short = $SessionId.Substring(0, [Math]::Min(8, $SessionId.Length))
    # -GraceSeconds: those with a registry file to tell by, given the time
    # to leave by themselves - counted in steps, so a test's seam stands in
    # for the clock
    $had = @()
    if ($GraceSeconds -gt 0) {
        $wait = @($ours | ForEach-Object { [int](Get-ChatField $_ 'Pid') })
        $had = @(Get-ChatqStillThere $ConfigDir $SessionId $wait)
        for ($ms = 0; $ms -lt $GraceSeconds * 1000; $ms += 250) {
            if (-not @(Get-ChatqStillThere $ConfigDir $SessionId $had).Count) { break }
            if ($script:ChatGraceSleepSeam) { & $script:ChatGraceSleepSeam 250 } else { Start-Sleep -Milliseconds 250 }
        }
    }
    foreach ($e in $ours) {
        $procId = [int](Get-ChatField $e 'Pid')
        if ($procId -in $had -and -not @(Get-ChatqStillThere $ConfigDir $SessionId @($procId)).Count) {
            $stopped.Add($procId)
            Write-ChatqWatchLog "show: idle chat process $procId ($short) left by itself"
            continue
        }
        $re = @(Read-ChatqSessionRegistry $dir | Where-Object { $_.Pid -eq $procId }) | Select-Object -First 1
        # With a grace, a file gone with its process is one that left as its
        # tab closed - maybe before the grace's first look ($had), and so
        # never waited for.
        if (-not $re -and $GraceSeconds -gt 0 -and -not (Get-Process -Id $procId -EA SilentlyContinue)) {
            $stopped.Add($procId)
            Write-ChatqWatchLog "show: idle chat process $procId ($short) left by itself"
            continue
        }
        # no file to check it against, its process still there: not ended on
        # a guess
        if (-not $re) { $kept = $true; continue }
        # the pid is another chat's now: this one's process is gone
        if ($re.SessionId -and $re.SessionId -ne $SessionId) { continue }
        if ($re.Status -ne 'idle') { $res.OldProcess = 'held'; $res.Stopped = [int[]]$stopped.ToArray(); return $res }
        if ($script:ChatStopSeam) {
            # tests: ended, other (not verified - kept) or gone
            switch ([string](& $script:ChatStopSeam $re)) {
                'ended' { $stopped.Add($procId) }
                'other' { $kept = $true }
            }
            continue
        }
        $pr = Get-Process -Id $procId -EA SilentlyContinue
        if (-not $pr -or -not (Test-ChatqSessionAlive $re) -or -not (Test-ChatqClaudeProcess $pr $re.ProcStart)) { continue }
        if (-not $script:ChatqIsWindows) { $kept = $true; continue }
        Stop-ChatqTree $pr
        $stopped.Add($procId)
        Write-ChatqWatchLog "show: ended idle chat process $procId ($short)"
    }
    $res.Stopped = [int[]]$stopped.ToArray()
    $res.OldProcess = if ($kept) { 'kept' } elseif ($stopped.Count) { 'ended' } else { 'none' }
    return $res
}

#region chats Claude Code leaves out of its lists -----------------------------
# Claude Code (2.1.281 to 2.1.283 at least: _j in its VS Code extension, v5o in
# its CLI) takes a chat for one an SDK started, and leaves it out of every
# session list, when the first "entrypoint" in its transcript's first 64 KB -
# else, with none there, the last one in its last 64 KB - is sdk-cli, sdk-ts or
# sdk-py. Such a chat cannot be restored into a tab either: the webview
# declines, and starts a blank chat. claude -p stamps every record sdk-cli, so
# one queued prompt or phone reply hid a chat whose first prompt was a pasted
# screenshot - 64 KB of base64 and no entrypoint. The run goes on stamping
# sdk-cli: an entrypoint of chatq's own would list the chat, but Claude Code
# also keys features on sdk-cli that an unattended run must keep off (the
# Artifact tool, autoDream), and hands the value to every claude the run
# starts (S37). So the chat is listed again as the run ends, by a line of
# chatq's own at its end. The extension mends the same way as it opens a
# chat (ensureListed in extension/extension.js), with the same rule.
$script:ChatSdkEntrypoints = @('sdk-cli', 'sdk-ts', 'sdk-py')
$script:ChatListSpan = 65536

function Read-ChatJsonStringAt {
    # a JSON string's text from $From, the index after its opening quote, and
    # the index of its closing quote; $null where the text ends first
    param([string]$Text, [int]$From)
    for ($i = $From; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        if ($c -eq [char]92) { $i++; continue }
        if ($c -ne [char]34) { continue }
        $v = $Text.Substring($From, $i - $From)
        if ($v.IndexOf([char]92) -ge 0) { try { $v = [string]('"' + $v + '"' | ConvertFrom-Json) } catch {} }
        return [pscustomobject]@{ Value = $v; End = $i }
    }
    return $null
}

function Get-ChatEntrypointIn {
    # The first "entrypoint" value in the text, or with -Last the last one,
    # found as Claude Code finds it: by its key, with or without a space after
    # the colon - where the first is wanted, the form without one first,
    # wherever the other stands. $null for none, '' for an empty one.
    param([string]$Text, [switch]$Last)
    $found = $null; $at = -1
    foreach ($k in '"entrypoint":"', '"entrypoint": "') {
        $from = 0
        while ($true) {
            $i = $Text.IndexOf($k, $from, [StringComparison]::Ordinal)
            if ($i -lt 0) { break }
            $v = Read-ChatJsonStringAt $Text ($i + $k.Length)
            if (-not $v) { break }
            if (-not $Last) { return $v.Value }
            if ($i -gt $at) { $found = $v.Value; $at = $i }
            $from = $v.End + 1
        }
    }
    return $found
}

function Get-ChatUnlistedWhy {
    # Why Claude Code leaves a chat out of its lists, by its first and last
    # 64 KB: 'head' - its head says an SDK started it, which nothing added at
    # the end changes; 'tail' - its head names no entrypoint and its tail's
    # last is an SDK's, which one line more mends; '' - it is listed. Claude
    # Code's other test, a daemon's sessionKind, is none of chatq's doing.
    param([string]$Head, [string]$Tail)
    $h = Get-ChatEntrypointIn $Head
    if ($null -ne $h) { if ($h -cin $script:ChatSdkEntrypoints) { return 'head' } else { return '' } }
    $t = Get-ChatEntrypointIn $Tail -Last
    if ($null -ne $t -and $t -cin $script:ChatSdkEntrypoints) { return 'tail' }
    return ''
}

function Read-ChatHeadTail {
    # a transcript's first and last 64 KB as Claude Code reads them - the tail
    # is the head where the file is no bigger - with its length; $null when it
    # cannot be read
    param([string]$Path)
    $fs = try { Open-ChatRead $Path } catch { $null }
    if (-not $fs) { return $null }
    try {
        $size = $fs.Length
        $read = {
            param([int64]$At)
            $buf = New-Object byte[] $script:ChatListSpan
            $null = $fs.Seek($At, [System.IO.SeekOrigin]::Begin)
            $n = 0
            while ($n -lt $buf.Length) {
                $got = $fs.Read($buf, $n, $buf.Length - $n)
                if ($got -le 0) { break }
                $n += $got
            }
            [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)
        }
        $head = & $read 0
        $tail = if ($size -gt $script:ChatListSpan) { & $read ($size - $script:ChatListSpan) } else { $head }
        return [pscustomobject]@{ Head = $head; Tail = $tail; Length = $size }
    }
    catch { return $null }
    finally { $fs.Dispose() }
}

function Get-ChatListedLine {
    # The line that lists a chat again: a record of chatq's own type, which
    # Claude Code's loaders pass over as they pass over any type they do not
    # know (S37), carrying an entrypoint of a VS Code panel for its list rule.
    # No timestamp: chatq's index takes a chat's last activity from the last
    # one in its tail, and this line is no activity.
    param([string]$SessionId)
    return '{"type":"chatq-listed","entrypoint":"claude-vscode","sessionId":' + (ConvertTo-Json $SessionId) + '}'
}

function Open-ChatAppend {
    <#
    A transcript opened to append only, as the extension's O_APPEND does:
    FileSystemRights.AppendData, which Windows never lets overwrite a byte -
    a record another process appends between the open and the write stays,
    and this lands after it. FileMode.Open: a file gone is never made again.
    Windows PowerShell has the FileStream overload; PowerShell 7 reaches the
    same through FileSystemAclExtensions. Elsewhere, a write at the end.
    #>
    param([string]$Path)
    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $rights = [System.Security.AccessControl.FileSystemRights]::AppendData
    try { return [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, $rights, $share, 4096, [System.IO.FileOptions]::None) } catch {}
    try { return [System.IO.FileSystemAclExtensions]::Create([System.IO.FileInfo]::new($Path), [System.IO.FileMode]::Open, $rights, $share, 4096, [System.IO.FileOptions]::None, $null) } catch {}
    $fs = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, $share)
    $null = $fs.Seek(0, [System.IO.SeekOrigin]::End)
    return $fs
}

function Repair-ChatListed {
    <#
    A chat Claude Code leaves out of its lists by its tail alone, listed again
    by one line at its end - as Claude Code's own rename adds a custom-title
    line there. Not while a process may be writing to it (-Live, the
    session's live processes): busy or waiting - a claude -p going into it
    reads busy, its registry kind interactive as Claude Code 2.1.283 writes
    it - or of a kind that is not interactive. An idle one writes nothing, as
    Claude Code's rename appends beside it too. The file keeps its write time:
    the line is no activity, and chatq judges a chat written in the last
    minute as working - unless something else wrote meanwhile, whose time is
    never taken back. One its head leaves out cannot be mended.
    'listed', 'relisted', 'unlistable', 'held' or 'unknown'.
    #>
    param([string]$Path, [string]$SessionId, [object[]]$Live)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'unknown' }
    $ht = Read-ChatHeadTail $Path
    if (-not $ht -or $ht.Length -eq 0) { return 'unknown' }
    $why = Get-ChatUnlistedWhy $ht.Head $ht.Tail
    if (-not $why) { return 'listed' }
    if ($why -eq 'head') { return 'unlistable' }
    foreach ($e in @($Live)) {
        if (-not $e -or [string](Get-ChatField $e 'SessionId') -ne $SessionId) { continue }
        $k = [string](Get-ChatField $e 'Kind')
        if (($k -and $k -ne 'interactive') -or [string](Get-ChatField $e 'Status') -in 'busy', 'waiting') { return 'held' }
    }
    $text = (Get-ChatListedLine $SessionId) + "`n"
    if (-not $ht.Tail.EndsWith("`n", [StringComparison]::Ordinal)) { $text = "`n" + $text }
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($text)
    try {
        $fi = [System.IO.FileInfo]::new($Path)
        $was = $fi.LastWriteTimeUtc
        $before = $fi.Length
        $fs = Open-ChatAppend $Path
        try { $fs.Write($bytes, 0, $bytes.Length); $fs.Flush() }
        finally { $fs.Dispose() }
        $fi.Refresh()
        # nothing else wrote meanwhile: its write time as it was - and looked
        # at once more, so a write in that instant keeps a time of now
        if ($fi.Length -eq $before + $bytes.Length) {
            $fi.LastWriteTimeUtc = $was
            $fi.Refresh()
            if ($fi.Length -ne $before + $bytes.Length) { $fi.LastWriteTimeUtc = [datetime]::UtcNow }
        }
    }
    catch { return 'unknown' }
    return 'relisted'
}

function Repair-ChatListedAll {
    <#
    Repair-ChatListed over the index's rows: what chatclean does for a chat
    hidden by an earlier copy's run, or by a watcher that died mid-run, that
    neither a run nor an open has mended since. Claude's rows only, and not a
    side transcript, which Claude Code never lists. -Live: the Claude home's
    live sessions, so a chat in use is held rather than written to.
    @{ Relisted; Held }, the rows of each.
    #>
    param([object[]]$Rows, [object[]]$Live)
    $out = [pscustomobject]@{ Relisted = [System.Collections.Generic.List[object]]::new(); Held = [System.Collections.Generic.List[object]]::new() }
    foreach ($r in @($Rows)) {
        if (-not $r -or $r.Provider -ne 'claude' -or $r.Hidden -or -not $r.Path) { continue }
        switch (Repair-ChatListed -Path $r.Path -SessionId $r.Id -Live $Live) {
            'relisted' { $out.Relisted.Add($r) }
            'held' { $out.Held.Add($r) }
        }
    }
    return $out
}

#endregion

function Find-ChatTranscriptPath {
    # a chat's transcript by its id: the index's folders for this project,
    # else wherever Claude Code put one the index has not seen yet
    param([string]$SessionId, [string]$Cwd, [string]$ConfigDir)
    $hit = @(Get-ChatProjectFiles -Cwd $Cwd | Where-Object { $_.Extension -eq '.jsonl' -and $_.BaseName -eq $SessionId }) | Select-Object -First 1
    if ($hit) { return $hit.FullName }
    return (Find-ChatOverlayTranscript (Get-ChatqHomeDir 'claude' $ConfigDir) $Cwd $SessionId)
}

function Show-ChatFresh {
    <#
    Show a chat up to date where it is open. One routine for all three ways
    in: a queued run into a chat a window still holds (-Via run), the
    overlay's open chip (-Via chip), and the extension's Show it button
    (-Via button). Only Show it ends the chat's old idle process
    (Stop-ChatIdleProcess), so the next look loads it from disk - and only
    after the window has closed the chat's tab: the extension in extension/
    judges first (-JudgeOnly), closes the tab, then asks again with
    -GraceSeconds, -HostPid and -StartedBefore, so what is ended is what
    outlived the close, in that window, and never a tab it opened since.
    Ending the process under a tab that still showed the chat left that tab
    dead ("process exited with code 1"): a run (-Via run) ends nothing any
    more, away or not, and the window closes the tab first. The chip ends
    nothing and judges no busy: it only asks the window to open the chat as
    a tab, or bring forward the tab already showing it - or, with a queued
    prompt going into the chat, that run's live view (watch). A terminal's
    chat is still turned away, and a queued run going into it still holds
    it.
    Returns @{ Outcome; ExitCode; Busy; OldProcess; HostPids; Stopped;
    JudgedOnly }; the chip's child exits with ExitCode, which picks the
    tray's words. An outcome that judged nothing (bad, missing) says kept:
    nothing was checked, which is as good as a process that could not be.
    Every call past the id and folder check leaves one line in watcher.log,
    so a click that went wrong can be traced afterwards.
    #>
    param([string]$SessionId, [string]$Cwd, [string]$Title, [string]$TitleB64, [string]$ConfigDir,
        [string]$Transcript, [ValidateSet('run', 'chip', 'button')][string]$Via = 'chip',
        [int]$Seconds = $script:ChatIdleSeconds, $Away = $null,
        # -Auto: the run was auto-continue's; the request says "auto": true
        [switch]$Auto,
        # -JudgeOnly: end nothing, whatever -Via; the verdict says judged only
        [switch]$JudgeOnly,
        # Stop-ChatIdleProcess's: wait for the process to leave by itself,
        # end only this window's, and none started since
        [int]$GraceSeconds = 0, [int]$HostPid = 0, $StartedBefore = $null,
        # -Via run: the windows the run's handover asked, and its job, for
        # the request (Write-ChatReloadRequest)
        [int[]]$HandoverPids = @(), [string]$JobId)
    $codes = @{ ok = 0; held = 10; running = 15; watch = 16; other = 20; 'not-raised' = 25; missing = 30; 'no-code' = 40; 'code-failed' = 41; bad = 50 }
    $logIt = $false
    $done = {
        param([string]$Outcome, $Busy = $null, $Judged = $null)
        $r = [pscustomobject]@{
            Outcome = $Outcome; ExitCode = [int]$codes[$Outcome]; Busy = $Busy
            OldProcess = $(if ($Judged) { [string]$Judged.OldProcess } else { 'kept' })
            HostPids = $(if ($Judged) { [int[]]@($Judged.HostPids | Where-Object { $_ }) } else { [int[]]@() })
            Stopped = $(if ($Judged) { [int[]]@($Judged.Stopped | Where-Object { $_ }) } else { [int[]]@() })
            JudgedOnly = [bool]$JudgeOnly
        }
        if ($logIt) {
            # ASCII only: the id is checked, and no title goes in
            $b = if ($null -eq $Busy) { 'unjudged' } elseif ($Busy) { 'true' } else { 'false' }
            $hp = if (@($r.HostPids).Count) { @($r.HostPids) -join ',' } else { 'none' }
            Write-ChatqWatchLog "show ($Via) $($SessionId.Substring(0, 8)): $($r.OldProcess), busy $b, hosts $hp -> $Outcome"
        }
        $r
    }
    # the title comes from the overlay as base64, so no chat's words are ever
    # parsed as code on the way
    if ($TitleB64) { try { $Title = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($TitleB64)) } catch {} }
    if ($SessionId -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$' -or -not $Cwd -or
        -not (Test-Path -LiteralPath $Cwd -PathType Container)) { return (& $done 'bad') }
    $logIt = $true
    if (-not $Transcript) { $Transcript = Find-ChatTranscriptPath $SessionId $Cwd $ConfigDir }
    if (-not $Transcript -and $Via -ne 'run') { return (& $done 'missing') }
    # a click - the chip's or Show it's - waits on this: the registry, as the
    # panel reads it every 2 s, not claude agents, a CLI to start first
    $live = @(Get-ChatqLiveSessions $ConfigDir -RegistryOnly:($Via -in 'button', 'chip'))
    # A queued prompt going into it now - another after the one whose Show it
    # this is, say - or any print-mode claude: ending the window's process
    # and showing the chat would load it part way through, a second writer
    # beside the run, and cut off nothing less. Held, busy, and left alone;
    # the run's own request comes when it ends. After a run (-Via run) its
    # own process is gone and the next job has not started.
    $runJob = if ($Via -ne 'run') { @(Get-ChatqJobs | Where-Object { $_.state -eq 'running' -and [string]$_.sessionId -eq $SessionId }) | Select-Object -First 1 } else { $null }
    # The registry has no print kind: a claude -p is there as interactive,
    # stamped sdk-* (as Remove-ChatSessionById reads it), and counts here too
    $printLive = (Test-ChatPrintLive $live $SessionId) -or @($live | Where-Object {
            $_ -and [string](Get-ChatField $_ 'SessionId') -eq $SessionId -and [string](Get-ChatField $_ 'Entrypoint') -cin $script:ChatSdkEntrypoints }).Count
    if ($Via -ne 'run' -and ($runJob -or $printLive)) {
        # The chip on a chat a chatq job is going into: that run's live view
        # instead, in the window its handover asked (data/run-state) - else
        # the one on exactly its folder - brought forward as for an open.
        # Someone's own claude -p has no live view: running, as before.
        if ($Via -eq 'chip' -and $runJob) {
            $rs = Read-ChatRunState
            $hp = [int[]]@()
            if ($rs -and [string](Get-ChatField $rs 'jobId') -eq [string]$runJob.id -and [string](Get-ChatField $rs 'phase') -in 'handover', 'running') {
                $hp = [int[]]@(@(Get-ChatField $rs 'hostPids') | Where-Object { $_ })
            }
            $jobHome = if ($ConfigDir) { $ConfigDir } else { [string]$runJob.home }
            $name = if ($Title) { $Title } else { [string]$runJob.title }
            Write-ChatWatchRequest -SessionId $SessionId -Cwd $Cwd -Title $name -ConfigHome $jobHome -JobId ([string]$runJob.id) -Seq $runJob.seq -HostPids $hp
            $outcome = 'watch'
            if ($hp.Count -and -not (Test-ChatWindowExact $Cwd @(Get-ChatCodeWindowTitles) @(Get-ChatCodeProfileNames))) { $outcome = 'not-raised' }
            else {
                $c = Open-ChatCodeWindow $Cwd
                if (-not $c.Ok) { $outcome = [string]$c.Code }
            }
            return (& $done $outcome $null ([pscustomobject]@{ OldProcess = 'held'; HostPids = $hp; Stopped = @() }))
        }
        return (& $done 'running' $true ([pscustomobject]@{ OldProcess = 'held'; HostPids = @(); Stopped = @() }))
    }
    # Only Show it ends a process, and only when it did not ask to judge:
    # the chip opens the chat as a tab, or brings forward the one already
    # showing it, on the process it has; after a run the window closes the
    # tab first (the extension's Show it, or the run's handover).
    $judged = $JudgeOnly -or $Via -ne 'button'
    $stopArgs = @{ GraceSeconds = $GraceSeconds; HostPid = $HostPid; StartedBefore = $StartedBefore }
    $j = Stop-ChatIdleProcess -SessionId $SessionId -Transcript $Transcript -ConfigDir $ConfigDir -Live $live -JudgeOnly:$judged @stopArgs
    # busy: the chat itself held, or another in the folder working - which
    # Reload Webviews would cut off as surely as a window reload. Not judged
    # for the chip: opening a tab cuts nothing off.
    $busy = $true
    if ($Via -eq 'chip') { $busy = $null }
    elseif ($j.OldProcess -ne 'held') {
        $idle = Test-ChatIdle -Cwd $Cwd -Except $Transcript -Seconds $Seconds -ConfigDir $ConfigDir -Live $live
        $busy = if ($null -eq $idle) { $null } else { -not $idle }
    }
    $outcome = switch ($j.OldProcess) { 'held' { 'held' } 'other' { 'other' } default { 'ok' } }
    if ($Via -eq 'run') {
        Write-ChatReloadRequest -Title $Title -Cwd $Cwd -Kind 'ran' -Busy $busy -Away $Away -SessionId $SessionId `
            -ConfigHome $ConfigDir -OldProcess $j.OldProcess -HostPids $j.HostPids -Transcript $Transcript -Auto:$Auto `
            -HandoverPids $HandoverPids -JobId $JobId
    }
    elseif ($Via -eq 'chip' -and $j.OldProcess -ne 'other') {
        Write-ChatOpenRequest -SessionId $SessionId -Cwd $Cwd -Title $Title -ConfigHome $ConfigDir -Busy $busy `
            -OldProcess $j.OldProcess -HostPids $j.HostPids -Transcript $Transcript
        # A window holds it, but none is on exactly its folder - a multi-root
        # one, say: code -n <folder> would open a second window on it, so the
        # request alone goes. Which windows are exact is only guessed at from
        # their titles out here (S30).
        if (@($j.HostPids).Count -and -not (Test-ChatWindowExact $Cwd @(Get-ChatCodeWindowTitles) @(Get-ChatCodeProfileNames))) { $outcome = 'not-raised' }
        else {
            $c = Open-ChatCodeWindow $Cwd
            if (-not $c.Ok) { $outcome = [string]$c.Code }
        }
    }
    return (& $done $outcome $busy $j)
}

function ConvertTo-ChatFreshVerdict {
    # What the Show it button's child prints for the extension: one line of
    # ASCII JSON, read by its parseVerdict. "judged":"only" when -JudgeOnly
    # was asked for and so nothing was ended - a script from before it knew
    # that switch ends the process all the same and says nothing, and the
    # extension goes on as it did then. Pure.
    param($Result)
    $v = [ordered]@{
        busy       = $Result.Busy
        oldProcess = [string]$Result.OldProcess
        outcome    = [string]$Result.Outcome
        hostPids   = [int[]]@($Result.HostPids | Where-Object { $_ })
    }
    if (Get-ChatField $Result 'JudgedOnly') { $v.judged = 'only' }
    return ($v | ConvertTo-Json -Compress)
}

function Test-ChatWindowExact {
    <#
    Is a VS Code window open on exactly this folder? Told from the windows'
    titles, where VS Code's default puts the folder's name last before its
    own - or before the profile's name, when one other than Default is in
    use: ${activeEditorShort} - ${rootName} - ${profileName} - ${appName}.
    -Profiles are those names (Get-ChatCodeProfileNames), so only a real
    profile is stripped, never a folder that happens to follow another. A
    proxy all the same - a multi-root window shows its workspace's name
    there, and a window.title of one's own can hide it (S30). Pure, for the
    tests.
    #>
    param([string]$Cwd, [string[]]$Titles, [string[]]$Profiles = @())
    $leaf = Split-Path ([string]$Cwd).TrimEnd('\', '/') -Leaf
    if (-not $leaf) { return $false }
    foreach ($t in @($Titles)) {
        $s = (([string]$t) -replace '\s+-\s+Visual Studio Code( - Insiders)?(\s*\[[^\]]*\])?\s*$', '').Trim()
        $cut = @($s)
        foreach ($p in @($Profiles)) {
            if ($p -and $s.EndsWith(" - $p", [StringComparison]::OrdinalIgnoreCase)) { $cut += $s.Substring(0, $s.Length - $p.Length - 3) }
        }
        foreach ($c in $cut) {
            if ($c -eq $leaf -or $c.EndsWith(" - $leaf", [StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
    }
    return $false
}

function Get-ChatCodeProfileNames {
    # The names of VS Code's profiles, which its window titles carry after the
    # folder's (Test-ChatWindowExact). VS Code keeps them in its own
    # storage.json, userDataProfiles - read, nothing more; it is VS Code's
    # settings, not runtime data of ours. None when there are none.
    if ($script:ChatCodeProfilesSeam) { return @(& $script:ChatCodeProfilesSeam) }   # tests
    if (-not $env:APPDATA) { return @() }
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($app in 'Code', 'Code - Insiders') {
        $f = Join-Path $env:APPDATA "$app\User\globalStorage\storage.json"
        if (-not (Test-Path -LiteralPath $f)) { continue }
        try {
            $o = [System.IO.File]::ReadAllText($f) | ConvertFrom-Json
            if (-not $o.PSObject.Properties['userDataProfiles']) { continue }
            foreach ($p in @($o.userDataProfiles)) {
                $n = [string](Get-ChatField $p 'name')
                if ($n -and -not $names.Contains($n)) { $names.Add($n) }
            }
        }
        catch {}
    }
    return @($names)
}

# the titles of VS Code's windows, read and nothing else: nothing here moves,
# raises or activates a window
$script:ChatCodeWindowsCode = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class ChatCodeWindows {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    public static string[] Titles(int[] pids) {
        List<string> found = new List<string>();
        List<uint> want = new List<uint>();
        foreach (int p in pids) { want.Add((uint)p); }
        EnumWindows(delegate (IntPtr h, IntPtr l) {
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            if (want.Contains(pid) && IsWindowVisible(h)) {
                StringBuilder sb = new StringBuilder(512);
                if (GetWindowText(h, sb, 512) > 0) { found.Add(sb.ToString()); }
            }
            return true;
        }, IntPtr.Zero);
        return found.ToArray();
    }
}
'@

function Get-ChatCodeWindowTitles {
    if ($script:ChatWindowTitlesSeam) { return @(& $script:ChatWindowTitlesSeam) }   # tests
    if (-not $script:ChatqIsWindows) { return @() }
    try {
        $ids = @(Get-Process -Name 'Code', 'Code - Insiders' -EA SilentlyContinue | ForEach-Object { [int]$_.Id })
        if (-not $ids) { return @() }
        if (-not ('ChatCodeWindows' -as [type])) { Add-Type -TypeDefinition $script:ChatCodeWindowsCode }
        return @([ChatCodeWindows]::Titles([int[]]$ids))
    }
    catch { return @() }
}

function Get-ChatRunningCodeExes {
    # the Code.exe files VS Code runs from right now, Insiders' too; Windows
    if ($script:ChatCodeExesSeam) { return @(& $script:ChatCodeExesSeam) }   # tests
    if (-not $script:ChatqIsWindows) { return @() }
    return @(Get-Process -Name 'Code', 'Code - Insiders' -EA SilentlyContinue |
        ForEach-Object { try { $_.Path } catch { $null } } | Where-Object { $_ } | Select-Object -Unique)
}

function Find-ChatCodeCommand {
    # CHATQ_CODE, else the code.cmd beside the Code.exe that is running - the
    # VS Code whose windows these are - else code on PATH (an Application,
    # never a function or alias), else where the user and system installers
    # put it. Running first: a machine can hold two installs, and PATH may
    # name the other. Here a system install left half-updated since February
    # came first on PATH, its code.cmd starting a Code.exe with no ICU data
    # beside it, which crashed every time (0x80000003) - while the per-user
    # install ran every window. Reading VS Code's install place is not
    # runtime data of ours.
    if ($env:CHATQ_CODE) { return $env:CHATQ_CODE }
    foreach ($exe in @(Get-ChatRunningCodeExes)) {
        foreach ($n in 'code.cmd', 'code-insiders.cmd') {
            $b = Join-Path (Join-Path (Split-Path $exe -Parent) 'bin') $n
            if (Test-Path -LiteralPath $b) { return $b }
        }
    }
    $c = Get-Command code -CommandType Application -EA SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    foreach ($p in @(
            $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd' }),
            $(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'Microsoft VS Code\bin\code.cmd' }))) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    return $null
}

function Get-ChatCodeEnvDrops {
    # What a child that starts code must not inherit. Run from inside a VS
    # Code terminal, or a Claude Code session's shell, VS Code's own VSCODE_*
    # and ELECTRON_* variables would reach the Code.exe that code.cmd starts
    # and speak for a process that is not its own. S29 blamed them for an
    # "Invalid file descriptor to ICU data" crash; that was a broken install
    # instead (Find-ChatCodeCommand), and it crashed with none of them.
    # code.cmd sets ELECTRON_RUN_AS_NODE again itself. Pure.
    param([string[]]$Names)
    return @($Names | Where-Object { $_ -match '^(VSCODE_|ELECTRON_)' })
}

function Get-ChatCodeLaunch {
    <#
    How to run code -n <folder>: @{ Exe; Arguments }, or $null when it cannot
    go on a command line safely. code.cmd runs through cmd.exe: inside its
    quotes & ^ and | are literal, and /v:off makes ! literal too, but % and "
    have no escape there at all, so a path holding either is refused. An .exe
    (CHATQ_CODE), or anything off Windows, is started directly. Pure.
    #>
    param([string]$Code, [string]$Folder, [bool]$Windows = $script:ChatqIsWindows)
    if (-not $Code -or -not $Folder) { return $null }
    if ($Code -match '\.exe$' -or -not $Windows) {
        return [pscustomobject]@{ Exe = $Code; Arguments = (ConvertTo-ChatqArgLine @('-n', $Folder)) }
    }
    if ("$Code$Folder" -match '[%"\r\n]') { return $null }
    # a trailing backslash would escape the quote after it, as Code.exe reads it
    if ($Folder.EndsWith('\')) { $Folder += '.' }
    $shell = if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' }
    return [pscustomobject]@{ Exe = $shell; Arguments = '/d /s /v:off /c ""' + $Code + '" -n "' + $Folder + '""' }
}

function Open-ChatCodeWindow {
    <#
    code -n <folder>: VS Code brings forward the window that has that folder
    open, or opens a new one on it. -n keeps it from reusing an unrelated
    window when window.openFoldersInNewWindow is off; reusing one would close
    that window's folder. Nothing here moves the pointer, types, or calls a
    window API - VS Code raises its own window. The vscode:// link would do
    it without code on PATH, but asks first when opened from outside.
    Returns @{ Ok; Code (ok, no-code, code-failed); Why; Slow }.
    #>
    param([string]$Folder)
    if ($script:ChatCodeSeam) { return (& $script:ChatCodeSeam $Folder) }   # tests
    $fail = { param($c, $w) Write-ChatqWatchLog "open: $w"; [pscustomobject]@{ Ok = $false; Code = $c; Why = $w; Slow = $false } }
    $code = Find-ChatCodeCommand
    if (-not $code) { return (& $fail 'no-code' 'no code command - VS Code''s bin folder on PATH, or CHATQ_CODE, finds it') }
    $l = Get-ChatCodeLaunch $code $Folder
    if (-not $l) { return (& $fail 'code-failed' "cannot hand $Folder to $code") }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $l.Exe
        $psi.Arguments = $l.Arguments
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        foreach ($n in @(Get-ChatCodeEnvDrops @($psi.EnvironmentVariables.Keys))) { $psi.EnvironmentVariables.Remove($n) }
        $p = [System.Diagnostics.Process]::Start($psi)
        if (-not $p.WaitForExit(20000)) {
            Write-ChatqWatchLog 'open: code still running after 20 s - left to it'
            return [pscustomobject]@{ Ok = $true; Code = 'ok'; Why = $null; Slow = $true }
        }
        if ($p.ExitCode -ne 0) { return (& $fail 'code-failed' "code exited $($p.ExitCode) - $code") }
        return [pscustomobject]@{ Ok = $true; Code = 'ok'; Why = $null; Slow = $false }
    }
    catch { return (& $fail 'code-failed' "code: $($_.Exception.Message) - $code") }
}

#endregion
