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
                  window holds its chat: it is listed with no pids
      background  a workflow or a background agent it started has not
                  reported back. The turn that started one has ended, so
                  Claude calls the chat idle while the work goes on; what a
                  print-mode run started died with that run
      ''          none of these
    Written says whether its transcript was written in the last -Seconds,
    which Test-ChatIdle counts as live too. It is kept apart so the caller
    can leave out the chat a queued run has just written, as Test-ChatIdle's
    -Except does. A background shell is not counted - it is as often a
    server that never ends (FUTURE_WORK.md), and a reload is not a question
    of whether the chat would wake up and write beside a run. Only a queued
    run into the chat waits on one, and for 20 minutes at most
    (Resolve-ChatqLiveAction).
    Returns HostPid, Known and Chats, one per session: SessionId, Pids, Cwd,
    Transcript, Why, Written. Known is whether the processes' parents could
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
    if (-not $mine.Count -and -not $running.Count) { return $res }
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
            [pscustomobject]@{
                SessionId = $sid; Pids = [int[]]@($es | ForEach-Object { [int](Get-ChatField $_ 'Pid') }); Cwd = $cwd
                Transcript = $file; Why = $why; Written = [bool]($wrote -and $wrote -gt $cut)
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
                Written = [bool]($wrote -and $wrote -gt $cut)
            }
        })
    if ($extra.Count) { $res.Chats = @($res.Chats) + $extra }
    return $res
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
