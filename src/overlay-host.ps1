# Charlie-and-the-chat-factory, src/overlay-host.ps1: dot-sourced by Charlie-and-the-chat-factory.ps1
# in its turn, never on its own - see the list there.

#region overlay: the host, with its panel or without -------------------------
# What an overlay host does whatever draws its panel: the lock, the heap's
# compaction and the memory restart, and its news for you - the ask, low
# memory, a delete's or a reload's outcome. The WPF host draws in its own
# process (src/overlay-windows.ps1); the headless host collects and leaves
# the drawing to a panel in a process of its own (Start-ChatOverlayHeadlessHost).
# Nothing here touches a WPF or WinForms type unless a tray is there to
# show a balloon in, so this part loads where the panel's do not.

# The headless host's news for its panel, kept until the panel has seen it
# (Add-ChatOverlayEvent), and the panel's own word back: what it has seen,
# and whether something there is under way (Read-ChatOverlayUi)
$script:ChatOverlayEventsPath = Join-Path $script:ChatqData 'overlay-events.json'
$script:ChatOverlayUiPath = Join-Path $script:ChatqData 'overlay-ui.json'
# a row's hover card, as the panel asked for it (card <key>):
# { key; at; model } - Get-ChatOverlayCardModel's, its masking unchanged
$script:ChatOverlayCardPath = Join-Path $script:ChatqData 'card.json'
# tests: a stand-in start of the panel's process, given its exe and the
# data folder; returns what stands for the process (Stop-ChatOverlayUi)
$script:ChatOverlayUiSpawnSeam = $null

function Lock-ChatOverlay {
    # A few tries, not one: an overlay handing over to a newer copy lets go
    # of the lock only as it exits.
    for ($try = 1; $try -le 5; $try++) {
        $l = try { [System.IO.File]::Open($script:ChatOverlayLockPath, 'OpenOrCreate', 'ReadWrite', 'None') } catch { $null }
        if ($l) { return $l }
        if ($try -lt 5) { Start-Sleep -Milliseconds 200 }
    }
    return $null
}

# Deferred: DEFERRED.md "GC flags for the overlay"
function Invoke-ChatOverlayHeapCompact {
    <#
    A full collection, the large object heap compacted with it. A start
    reads the tail of every transcript of the last week and the open chats
    whole, and the buffers are freed after by a collection that never moves
    what is left, so the heap keeps its size. Live, the first gave back 22
    to 82 MB in about 0.1 s. The passes after put little on that heap,
    which held 12 to 15 MB an hour on, so compacting it again costs little.
    The tick calls this every 5 minutes after the first: left to itself the
    CLR let generation 2 grow from 89-95 MB to 146-159 between full
    collections 17 to 21 minutes apart, and the private bytes from 250 up
    to 290 with it. Private bytes before and after go in the log, and the
    managed heap left after: private bytes rose from 208 to 287 MB in a day
    with compactions freeing nothing, and only the heap's figure says
    whether what grew is objects the overlay holds or memory outside the
    heap - compiled script, native buffers.
    $Error is emptied first: every caught throw in a pass lands there, up
    to 256 records with their stack traces, and nothing in src reads it.
    Returns the private MB after, for Update-ChatOverlayRestartDue.
    #>
    $p = [System.Diagnostics.Process]::GetCurrentProcess()
    try {
        $was = $p.PrivateMemorySize64
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $global:Error.Clear()
        [System.Runtime.GCSettings]::LargeObjectHeapCompactionMode = [System.Runtime.GCLargeObjectHeapCompactionMode]::CompactOnce
        [System.GC]::Collect()
        $ms = $sw.ElapsedMilliseconds
        $p.Refresh()
        $after = [Math]::Round($p.PrivateMemorySize64 / 1MB)
        Write-ChatOverlayLog ('the heap compacted in {0} ms: private {1} MB, then {2}, the heap {3}' -f $ms, [Math]::Round($was / 1MB), $after, [Math]::Round([System.GC]::GetTotalMemory($false) / 1MB))
        return $after
    }
    finally { $p.Dispose() }
}

function Update-ChatOverlayRestartDue {
    <#
    Whether this run should start again to give its memory back, from the
    private MB a compaction left (Invoke-ChatOverlayHeapCompact). Over 78
    runs in one PC's log that figure sat at 260 MB in the middle and 322 at
    the most; a fresh run settles at 210 to 260, and one up some 30 hours
    sat at 315 to 322 - the heap climbing in steps nothing explains yet
    (FUTURE_WORK.md "The overlay's heap climbs in steps"). This bounds it.
    Settled is the lowest such figure from 30 minutes into the run on,
    once the start's reads are long given back. Due when the figure is at
    config overlay.restartMB or more, 50 or more over where this run
    settled, and the run an hour old: a run that starts high - another PC,
    more chats - never restarts for being itself, and a new one cannot
    restart in its first hour, so it never loops. Due, $H.MemRestart says
    why, for the tick's restart (Invoke-ChatOverlayTick) once nothing is
    under way; 0 is never. No figure - a compaction that threw - nothing.
    #>
    param($H, $AfterMB, [datetime]$Now = (Get-Date))
    if ($null -eq $AfterMB -or $H.MemRestart -or $H.StartedAt -isnot [datetime]) { return }
    $mb = [double]$AfterMB
    $age = ($Now - $H.StartedAt).TotalMinutes
    if ($age -ge 30 -and ($null -eq $H.Settled -or $mb -lt $H.Settled)) { $H.Settled = $mb }
    $limit = [int]$H.Ctx.Config.restartMB
    if ($limit -le 0 -or $age -lt 60 -or $null -eq $H.Settled) { return }
    if ($mb -lt $limit -or $mb -lt $H.Settled + 50) { return }
    $H.MemRestart = "private $mb MB after the heap compacted, over overlay.restartMB $limit and $($mb - $H.Settled) over where this run settled - restarting to give it back"
}

function Show-ChatOverlayBalloon {
    <#
    The tray's balloon - the one place that shows one; the headless host's
    goes to its panel as an event. -Kind says what a click on it means
    (ask: the chats the limit cut off, -Keys those asked about); the
    tray's handlers read it back, and clear it as it closes.
    Windows cuts the text itself past 255 characters, so it is cut here
    first, with an ellipsis. The tests' seam takes it in the tray's place.
    While a close by hand is on its way, only its own (-Kind close): the
    timer's passes run on meanwhile, and the ask, the tray's word or
    auto-continue's would put theirs over "Closed until you next sign in"
    before it is read. The headless host's console window
    (Open-ChatOverlayHeadlessConsole) has no tray: its balloons are its
    host's, events for the panel.
    #>
    param($H, [string]$Text, [string]$Title = 'Charlie', [int]$Ms = 6000, [string]$Icon = 'None', [string]$Kind = '', [string[]]$Keys = @())
    if (-not $H -or -not $Text) { return }
    if ($H.EventOwner) { $H = $H.EventOwner }
    if ($H.Closing -and $Kind -ne 'close') { return }
    if ($Text.Length -gt 250) { $Text = $Text.Substring(0, 249) + $script:ChatqEllipsis }
    $ks = @($Keys | Where-Object { $_ })
    # the headless host: an event for its panel to show (Add-ChatOverlayEvent)
    if ($null -ne $H.Events) {
        $H.BalloonKind = $Kind
        $H.BalloonKeys = $ks
        Add-ChatOverlayEvent $H 'balloon' @{ title = $Title; text = $Text; ms = $Ms; icon = $Icon; click = $Kind; keys = @($ks) }
        return
    }
    if ($script:ChatOverlayBalloonSeam) {
        $H.BalloonKind = $Kind
        $H.BalloonKeys = $ks
        [void](& $script:ChatOverlayBalloonSeam @{ Title = $Title; Text = $Text; Kind = $Kind; Keys = $ks })
        return
    }
    if (-not $H.Tray) { return }
    $H.BalloonKind = $Kind
    $H.BalloonKeys = $ks
    $H.Tray.ShowBalloonTip($Ms, $Title, $Text, [System.Windows.Forms.ToolTipIcon]$Icon)
}

function Show-ChatOverlayMemory {
    # after a pass: Windows' memory gone low (Update-ChatOverlayMemory), or a
    # program growing fast (Update-ChatOverlayLeaks), said once in the tray
    # - a VS Code window may be about to die of it. Both in one pass, one
    # balloon says both: a second would cover the first before it is read.
    param($H)
    try {
        $m = $H.Ctx.MemNews
        $grow = @(@($H.Ctx.LeakNews) | Where-Object { $_ } | ForEach-Object { Format-ChatOverlayLeakText $_ }) -join '; '
        if (-not $m -and -not $grow) { return }
        $H.Ctx.MemNews = $null
        $H.Ctx.LeakNews = $null
        if (-not $m) {
            Show-ChatOverlayBalloon $H "$grow. Closing it gives the memory back before a VS Code window runs out and takes its chats down with it." `
                -Title 'Charlie - a program keeps growing' -Icon Warning -Kind leak -Ms 10000
            return
        }
        $t = (Format-ChatOverlayMemoryText $m) -replace '^memory low: ', ''
        if ($grow) { $t += ". $grow" }
        Show-ChatOverlayBalloon $H "$t. A VS Code window that runs out of memory takes its chats down with it - close what you can spare." `
            -Title 'Charlie - memory low' -Icon Warning -Kind memory -Ms 10000
    }
    catch { Write-ChatOverlayLog "memory: $($_.Exception.Message)" }
}

# Deferred: DEFERRED.md "The tray's ask items while the menu is open"
function Update-ChatOverlayAsk {
    <#
    After each pass, what the collector found about the chats the limit cut
    off ($H.Ctx.Ask): the tray's two answers put in step, a new ask said in
    a balloon once, an answer's outcome (AskSaid) said the same way, and a
    watcher an answer asked for followed until it is up.
    #>
    param($H)
    if (-not $H -or -not $H.Ctx) { return }
    $ask = $H.Ctx.Ask
    # Not while the menu is open: its items and their keys stay what it
    # showed, so a click never answers for a chat that joined meanwhile.
    $menuOpen = $H.Tray -and $H.Tray.ContextMenuStrip -and $H.Tray.ContextMenuStrip.Visible
    if ($H.Menu.AskGo -and -not $menuOpen) {
        $on = [bool]$ask
        # Available, not Visible: an item's Visible reads false whenever its
        # menu is closed - which is always, here - so once shown, a check of
        # Visible never hid them again. Available is what Visible sets.
        foreach ($i in $H.Menu.AskGo, $H.Menu.AskLeave, $H.Menu.AskSep) { if ($i.Available -ne $on) { $i.Available = $on } }
        if ($on) {
            $n = [int]$ask.Count
            $H.Menu.AskGo.Text = "Continue $n cut-off chat$(if ($n -ne 1) { 's' })"
            $H.Menu.AskGo.ToolTipText = (@(@($ask.Items) | Select-Object -First 10 | ForEach-Object { Format-ChatTitle ([string]$_.Title) 60 }) -join "`n")
            $H.Menu.AskLeave.ToolTipText = Format-ChatqAskLeaveTip $ask
        }
        # @() around the if: an empty array out of a branch would be $null
        $H.AskMenuKeys = @(if ($on) { $ask.Keys })
    }
    $news = $H.Ctx.AskNews
    if ($news) {
        $H.Ctx.AskNews = $null
        $a = $news.Ask
        $n = [int]$a.Count
        $names = @(@($a.Items) | Select-Object -First 3 | ForEach-Object { Format-ChatTitle ([string]$_.Title) 40 })
        $list = $names -join ', '
        if ($n -gt 3) { $list += " and $($n - 3) more" }
        Show-ChatOverlayBalloon $H "$(Format-ChatqAskCount $a) can continue: $list. Click to see them." -Title "Charlie - $(Format-ChatqAskHead $a)" -Ms 10000 -Kind ask -Keys @($a.Keys)
    }
    if ($H.Ctx.AskSaid) {
        $said = [string]$H.Ctx.AskSaid
        $H.Ctx.AskSaid = $null
        Show-ChatOverlayBalloon $H $said
    }
    if ($H.AskRequest) {
        # Ctx.Jobs holds each job with its first line: the state is the job's
        $queued = [bool](@($H.Ctx.Jobs | Where-Object { $_ -and $_.Job -and $_.Job.state -eq 'queued' }).Count)
        switch (Test-ChatqWatcherRequest $H.AskRequest $queued) {
            'up' { $H.AskRequest = $null }
            'none' { $H.AskRequest = $null }
            'failed' { $H.AskRequest = $null; Show-ChatOverlayBalloon $H 'the watcher did not start - chatqrun -Foreground shows why' }
        }
    }
}

function Test-ChatOverlayRowDeletable {
    # whether a row's delete chip takes a click: not on a chat at work or
    # waiting on you - cutting its transcript from under a turn loses the
    # turn - nor on one a terminal's claude holds, or a print-mode run (a
    # queued prompt), either of which writes it straight back.
    # Remove-ChatSessionById asks the registry again as it acts. Pure.
    param($Row)
    if ([string](Get-ChatField $Row 'kind') -ne 'session') { return $true }
    return ([string](Get-ChatField $Row 'status') -notin 'busy', 'waiting' -and
        [string](Get-ChatField $Row 'where') -notin 'terminal', 'run')
}

function Get-ChatOverlayDeleteSay {
    # the panel's said marker for a delete chip's outcome (Remove-ChatSessionById's
    # Done and Say), as the open's is (Get-ChatOverlayOpenSay). Pure.
    param([bool]$Done, [string]$Say)
    if ($Done) { return @{ Kind = 'delete'; Text = $Say; Tone = 'dim'; Keep = 5 } }
    return @{ Kind = 'delete'; Text = $(if ($Say) { $Say } else { 'Nothing deleted.' }); Tone = 'warn'; Keep = 20 }
}

function Get-ChatOverlayReloadSay {
    # the panel's said marker for a reload chip's answer, as a delete's is
    # (Get-ChatOverlayDeleteSay). Pure.
    param([string]$Window, [string]$Answer)
    $w = if ($Window) { $Window } else { 'the VS Code window' }
    if ($Answer -eq 'reload') { return @{ Kind = 'reload'; Text = "$w reloads - within 2 s"; Tone = 'dim'; Keep = 6 } }
    return @{ Kind = 'reload'; Text = "left for later - the notice is still in $w"; Tone = 'dim'; Keep = 6 }
}

function Get-ChatOverlayOpenSay {
    <#
    The panel's said marker about an open from the chip: Kind, Text, Tone, and
    Keep - how many seconds it stays once said, 0 while the open runs.
    -State busy (-Seconds so far), done (-Code, its child's exit), behind
    (opened, but its window could not be brought to the front -
    Invoke-ChatOverlayRaise), late (no answer in 60 s) or nostart (its
    child did not start). Pure.
    #>
    param([string]$Title, [string]$State, [int]$Code = 0, [int]$Seconds = 0)
    $t = "'$(Format-ChatTitle $Title 40)'"
    switch ($State) {
        'busy' { return @{ Kind = 'busy'; Text = "opening $t in VS Code - $($Seconds)s"; Tone = 'dim'; Keep = 0 } }
        'behind' { return @{ Kind = 'done'; Text = "opened $t - VS Code's window could not be brought to the front - click it on the taskbar"; Tone = 'warn'; Keep = 20 } }
        'late' { return @{ Kind = 'late'; Text = "opening $t - no answer in 60 s; see data/logs/watcher.log"; Tone = 'warn'; Keep = 20 } }
        'nostart' { return @{ Kind = 'nostart'; Text = "could not open $t - its helper did not start; see data/logs/overlay.log"; Tone = 'warn'; Keep = 20 } }
    }
    if ($Code -eq 0) { return @{ Kind = 'done'; Text = "opened $t"; Tone = 'dim'; Keep = 5 } }
    # a queued run's live view, which opens in VS Code: no failure either
    # and a chat Claude Code never lists, which its window offers in a
    # terminal (21): asked for as it should be. Not brought forward as well
    # (26, 42, 43) is a warning, as 25, 40 and 41 are
    if ($Code -in 16, 21) { return @{ Kind = 'done'; Text = "$t - $(Get-ChatOverlayOpenBalloon $Code)"; Tone = 'dim'; Keep = 8 } }
    return @{ Kind = 'done'; Text = "$t - $(Get-ChatOverlayOpenBalloon $Code)"; Tone = 'warn'; Keep = 20 }
}

function Get-ChatOverlayOpenBalloon {
    # what the tray says when an open ends, by its child's exit code
    # (Show-ChatFresh); $null says nothing. Pure.
    param([int]$Code)
    switch ($Code) {
        15 { return 'A queued prompt is running in that chat - open it once it finishes.' }
        16 { return 'A queued prompt is running in that chat - its live view opens in VS Code.' }
        20 { return 'That chat is open in a terminal - not opened in VS Code as well.' }
        21 { return 'Claude Code does not list that chat, so its window offers to open it in a terminal instead of a tab.' }
        25 { return 'Shown in its window, which also has other folders open - bring it forward yourself.' }
        26 { return 'Claude Code does not list that chat, so its window offers to open it in a terminal - that window also has other folders open, so bring it forward yourself.' }
        30 { return 'That chat has not started yet.' }
        40 { return 'Asked its window to show it, but VS Code''s code command was not found, so the window was not brought forward.' }
        41 { return 'code failed - see data/logs/watcher.log.' }
        42 { return 'Claude Code does not list that chat, so its window offers to open it in a terminal - but VS Code''s code command was not found, so the window was not brought forward.' }
        43 { return 'Claude Code does not list that chat, so its window offers to open it in a terminal - but code failed, so the window was not brought forward; see data/logs/watcher.log.' }
        10 { return 'Asked its window to open it - the chat is at work, so VS Code may hold it until the turn ends.' }
        50 { return 'Not opened - its id or its folder is not right any more.' }
    }
    # 0 went; anything else - a crash of its child among them - is said too
    if ($Code) { return "Not opened - the open ended with code $Code; see data/logs/watcher.log." }
    return $null
}

function Remove-ChatOverlayRow {
    <#
    A row's chat deleted for good, as chatrm does (Remove-ChatSessionById,
    which asks the registry again as it acts): what both hosts' delete
    does once its "sure?" is answered - the WPF chip's
    (Invoke-ChatOverlayDeleteChip) and the headless panel's verb
    (Invoke-ChatOverlayPanelVerb). Gone, it takes its unread dot with it,
    and the recent list is read again at the next pass, without it.
    Returns Remove-ChatSessionById's answer, Done and Say; throws as it does.
    #>
    param($H, $Row)
    $sid = [string](Get-ChatField $Row 'sessionId')
    $home0 = if ($H.Ctx -and $H.Ctx.ClaudeHome) { [string]$H.Ctx.ClaudeHome } else { $script:ChatClaudeHome }
    $live = @(Get-ChatqLiveSessions $home0 -RegistryOnly)
    $r = Remove-ChatSessionById -SessionId $sid -Cwd ([string](Get-ChatField $Row 'cwd')) -Title ([string](Get-ChatField $Row 'title')) -ConfigDir $home0 -Live $live
    Write-ChatOverlayLog "delete: $($sid.Substring(0, [Math]::Min(8, $sid.Length))) $(if ($r.Done) { 'deleted' } else { 'kept' })" -Always
    if ($r.Done -and $H.Ctx) {
        if ($H.Ctx.Unread) { $H.Ctx.Unread.Remove($sid) }
        # the recent list read again at the next pass, without it
        $H.Ctx.RecentAt = [datetime]::MinValue
    }
    return $r
}

function Add-ChatOverlayEvent {
    <#
    One piece of news for a panel in a process of its own: in the
    snapshot's events until the panel says it has seen it (overlay-ui.json's
    seen) or 10 minutes on (Update-ChatOverlayEvents), and in
    overlay-events.json meanwhile, so a host that restarts still says what
    the last one had not got across. Ids run on from the host's start, so
    two hosts' never meet. -Data's keys go in sorted, so the snapshot of one
    event reads the same each time.
    #>
    param($H, [string]$Kind, [hashtable]$Data = @{})
    $H.EventN++
    $e = [ordered]@{ id = "$($H.EventBase)-$($H.EventN)"; at = (ConvertTo-ChatOverlayMs (Get-Date)); kind = $Kind }
    # PSBase: a key named keys (a balloon's) would answer $Data.Keys itself
    foreach ($k in @($Data.PSBase.Keys | Sort-Object)) { $e[$k] = $Data[$k] }
    $H.Events.Add([pscustomobject]$e)
    Save-ChatOverlayEvents $H
}

function Save-ChatOverlayEvents {
    param($H)
    try { Save-ChatqText $script:ChatOverlayEventsPath (ConvertTo-Json -InputObject @($H.Events) -Depth 4 -Compress) }
    catch { Write-ChatOverlayLog "overlay-events.json: $($_.Exception.Message)" }
}

function Read-ChatOverlayEvents {
    # the news the last host left unseen, under 10 minutes old - a new
    # host's start (Start-ChatOverlayHeadlessHost)
    param([datetime]$Now = (Get-Date))
    $cut = ConvertTo-ChatOverlayMs $Now.AddMinutes(-10)
    return @(@(Read-ChatqJson $script:ChatOverlayEventsPath) | Where-Object { $_ -and (Get-ChatField $_ 'id') -and [int64](Get-ChatField $_ 'at') -ge $cut })
}

function Update-ChatOverlayEvents {
    # each pass: the news the panel has seen, or 10 minutes old, dropped -
    # and the file written again only when that dropped any
    param($H, $Ui, [datetime]$Now = (Get-Date))
    $seen = @{}
    foreach ($s in @(Get-ChatField $Ui 'seen')) { if ($s) { $seen[[string]$s] = $true } }
    $cut = ConvertTo-ChatOverlayMs $Now.AddMinutes(-10)
    $n = $H.Events.Count
    for ($i = $H.Events.Count - 1; $i -ge 0; $i--) {
        $e = $H.Events[$i]
        if ($seen[[string]$e.id] -or [int64]$e.at -lt $cut) { $H.Events.RemoveAt($i) }
    }
    if ($H.Events.Count -ne $n) { Save-ChatOverlayEvents $H }
}

function Update-ChatOverlayCommands {
    # each pass: the commands the panel says it has done (overlay-ui.json's
    # done) dropped from the snapshot's, so a panel started again in its
    # place (Start-ChatOverlayHeadlessHost) acts on those the last one had
    # not - and on none twice
    param($Ctx, $Ui)
    $done = @{}
    foreach ($d in @(Get-ChatField $Ui 'done')) { if ($null -ne $d) { $done[[int64]$d] = $true } }
    if (-not $done.Count) { return }
    for ($i = $Ctx.Commands.Count - 1; $i -ge 0; $i--) { if ($done[[int64]$Ctx.Commands[$i].id]) { $Ctx.Commands.RemoveAt($i) } }
}

function Read-ChatOverlayUi {
    # The panel's word back, data/overlay-ui.json: { at; underWay; seen;
    # done; rect }. at in epoch ms; underWay: a drag, the settings box or an
    # open on its way - what a restart would take from under you
    # (Test-ChatOverlayUiUnderWay); seen: the events it has shown; done: the
    # ids of the commands it has acted on (Update-ChatOverlayCommands); rect:
    # where it is, x y width height in screen pixels, which the console
    # opens over (Open-ChatOverlayHeadlessConsole). $null while there is none.
    return (Read-ChatqJson $script:ChatOverlayUiPath)
}

function Test-ChatOverlayUiUnderWay {
    # Whether the panel says something is under way - the headless host's
    # Test-ChatOverlayUnderWay. Only a word under 10 s old counts: a panel
    # that hangs or has gone holds no restart off for good. Pure.
    param($Ui, [datetime]$Now = (Get-Date))
    if (-not $Ui -or -not [bool](Get-ChatField $Ui 'underWay')) { return $false }
    $at = Get-ChatField $Ui 'at'
    if (-not $at) { return $false }
    $age = (ConvertTo-ChatOverlayMs $Now) - [int64]$at
    return ($age -ge -2000 -and $age -lt 10000)
}

function Start-ChatOverlayUi {
    # The panel's process: -UiExe given the data folder. Its stdin is a
    # pipe this host holds, and closing it is how the panel is told to go
    # (Stop-ChatOverlayUi) - a host that dies outright closes it as well,
    # so no panel outlives its host. -Since: the host's first panel's start,
    # in epoch ms - the commands the snapshot lists from before it are not a
    # panel's to act on; one started again acts on those after it the last
    # did not say it had done (Update-ChatOverlayCommands).
    param([string]$UiExe, [int64]$Since)
    if ($script:ChatOverlayUiSpawnSeam) { return (& $script:ChatOverlayUiSpawnSeam $UiExe $script:ChatqData $Since) }   # tests
    $si = [System.Diagnostics.ProcessStartInfo]::new($UiExe)
    # a trailing \ would escape the closing quote
    $si.Arguments = '"' + ([string]$script:ChatqData).TrimEnd('\') + '" --since ' + $Since
    $si.UseShellExecute = $false
    $si.RedirectStandardInput = $true
    $si.CreateNoWindow = $true
    $si.WorkingDirectory = $HOME
    return [System.Diagnostics.Process]::Start($si)
}

function Stop-ChatOverlayUi {
    # the panel's process told to go - its stdin closed - and given -WaitMs;
    # one still there then is ended. Only the process this host started.
    # Never throws.
    param($Child, [int]$WaitMs = 5000)
    if (-not $Child) { return }
    try { if (-not $Child.HasExited) { $Child.StandardInput.Close() } } catch {}
    try { if (-not $Child.WaitForExit($WaitMs)) { $Child.Kill() } } catch {}
}

function Resolve-ChatOverlayUiExe {
    <#
    The panel's exe for this code. One staged with a release - under
    bin/<version>/x86_64-pc-windows-msvc/ beside the script - follows the
    code's version - the script's on disk, as Get-ChatOverlayPanelExe
    reads it - so a restart onto new code (Start-ChatOverlayHeadlessHost)
    starts the new code's panel, never the old one's; and '' - the WPF
    panel - while the new version has none staged, as a fresh start would
    give. One from anywhere else, a build of your own, stays what it was.
    #>
    param([string]$UiExe, [string]$ScriptPath = $script:ChatqScriptPath, [string]$Version = '')
    if (-not $Version -and $ScriptPath) { $Version = Get-ChatqLoaderVersion $ScriptPath }
    if (-not $Version) { $Version = $script:ChatVersion }
    if (-not $UiExe -or -not $ScriptPath -or -not $Version) { return $UiExe }
    $leaf = 'x86_64-pc-windows-msvc\chatq-overlay.exe'
    try {
        $bin = Join-Path ([System.IO.Path]::GetFullPath((Split-Path -Parent $ScriptPath))) 'bin'
        $full = [System.IO.Path]::GetFullPath($UiExe)
    }
    catch { return $UiExe }
    $rest = if ($full.StartsWith("$bin\", [System.StringComparison]::OrdinalIgnoreCase)) { $full.Substring($bin.Length + 1) } else { '' }
    # bin\<one folder>\x86_64-pc-windows-msvc\chatq-overlay.exe, no deeper
    if ($rest -notlike "*\$leaf" -or $rest.Substring(0, $rest.Length - $leaf.Length - 1).Contains('\')) { return $UiExe }
    $mine = Join-Path (Join-Path $bin $Version) $leaf
    if ([System.IO.File]::Exists($mine)) { return $mine }
    return ''
}

function Find-ChatOverlayRow {
    # the row a panel's verb names, by its key, in a snapshot: its rows,
    # Recent, and Recent's stretch past it; $null for none. Pure.
    param($Snap, [string]$Key)
    if (-not $Snap -or -not $Key) { return $null }
    foreach ($r in @(@($Snap.rows) + @($Snap.recent) + @($Snap.recentMore))) {
        if ($r -and [string](Get-ChatField $r 'key') -ceq $Key) { return $r }
    }
    return $null
}

function Add-ChatOverlaySaid {
    # the said marker, on the headless host: an event of kind said for its
    # panel to draw, as Set-ChatOverlayOpenSay draws it on the WPF one -
    # said, its Kind; text and tone; ms, how long it stays (its Keep); and
    # about, the key of the row it is about, whose card says it too
    param($H, $Say, [string]$About = '')
    if (-not $Say) { return }
    Add-ChatOverlayEvent $H 'said' @{ said = [string]$Say.Kind; text = [string]$Say.Text; tone = [string]$Say.Tone; ms = ([int]$Say.Keep * 1000); about = $About }
}

function Invoke-ChatOverlayPanelVerb {
    <#
    A click on the headless host's panel, come in as a verb with its words
    (Test-ChatOverlayVerbArg), carried out here as the WPF host's own
    handlers do, and its outcome said back to the panel as a said event
    (Add-ChatOverlaySaid). -Snap is this pass's snapshot, where the key is
    looked for (Find-ChatOverlayRow); an open's row may have left it since
    the click, so $H.Snap, the pass's before, is looked in for it too.
      opened <key> <exit> [<look>]
                              the panel's open child ended so, and its
                              window was looked for (front, behind, none,
                              looking): the unread dot goes on 0, 25, 40 and
                              41 (as Update-ChatOverlayOpen), the tray's words
                              (Get-ChatOverlayOpenBalloon) a balloon, and
                              Get-ChatOverlayOpenSay's the said marker
      opened <key> behind|late|nostart
                              found later but left behind, no answer in 60 s,
                              or no child started: said so
      config <name> <value>   a setting of the panel's box saved
                              (Set-ChatOverlayConfig): opacity, maxRows,
                              theme or recent
      auto-chip <key> dont|continue
                              the chip's auto-continue answer
                              (Invoke-ChatOverlayAutoChip)
      delete <key>            the chat deleted (Remove-ChatOverlayRow) -
                              the panel asked "sure?" first - unless the row
                              has gone, or cannot be (Test-ChatOverlayRowDeletable)
      reload-answer <pid>:<id> reload|later
                              the window's ask answered
                              (Write-ChatReloadAnswer), and its banner left
                              out until the window has taken it
      card <key>              the row's hover card, written to data/card.json
                              (Get-ChatOverlayCardModel)
    True when it said something, for the next pass to start at once. Never
    throws.
    #>
    param($H, [string]$Verb, $Snap)
    $w = @($Verb -split ' ')
    try {
        switch -CaseSensitive ($w[0]) {
            'opened' {
                $key = $w[1]
                $row = Find-ChatOverlayRow $Snap $key
                if (-not $row) { $row = Find-ChatOverlayRow $H.Snap $key }
                $title = if ($row) { [string](Get-ChatField $row 'title') } else { '' }
                # the panel's own word for an end that is not a code: a window
                # found later but left behind, no answer in 60 s, no child
                if ($w[2] -cin 'behind', 'late', 'nostart') {
                    if ($w[2] -ceq 'late') { Show-ChatOverlayBalloon $H 'The open got no answer in 60 s - see data/logs/watcher.log.' }
                    Add-ChatOverlaySaid $H (Get-ChatOverlayOpenSay $title $w[2]) $key
                    return $true
                }
                $code = [int]$w[2]
                # the panel's look for its window (open.rs, as
                # Start-ChatOverlayRaise): in front, an end that says its window
                # was not brought forward says what it does in front instead
                $look = if ($w.Count -gt 3) { $w[3] } else { 'none' }
                $sid = if ($row) { [string](Get-ChatField $row 'sessionId') } elseif ($key -like 's:*') { $key.Substring(2) } else { '' }
                Write-ChatOverlayLog "open: $($sid.Substring(0, [Math]::Min(8, $sid.Length))) ended $code" -Always
                if ($code -in 0, 25, 40, 41 -and $sid -and $H.Ctx.Unread) { $H.Ctx.Unread.Remove($sid) }
                $words = if ($look -ceq 'front') { (Get-ChatOverlayRaisePlan $code).Words } else { $code }
                $say = Get-ChatOverlayOpenBalloon $words
                if ($say) { Show-ChatOverlayBalloon $H $say }
                $line = if ($look -ceq 'behind' -and $code -eq 0) { Get-ChatOverlayOpenSay $title 'behind' } else { Get-ChatOverlayOpenSay $title 'done' $words }
                Add-ChatOverlaySaid $H $line $key
                return $true
            }
            'config' {
                # a setting of the panel's box, kept as the WPF box keeps it
                # (Save-ChatOverlaySetting): config.json's overlay section
                $name = $w[1]
                $value = switch -CaseSensitive ($name) {
                    'opacity' { [Math]::Round([Math]::Min(1.0, [Math]::Max(0.3, [double]::Parse($w[2], [cultureinfo]::InvariantCulture))), 2) }
                    'maxRows' { [Math]::Min(30, [Math]::Max(1, [int]$w[2])) }
                    'recent' { [Math]::Min(20, [Math]::Max(0, [int]$w[2])) }
                    default { $w[2] }
                }
                Set-ChatOverlayConfig @{ $name = $value }
                $H.Ctx.Config = Get-ChatOverlayConfig
                Write-ChatOverlayLog "settings: $name from the panel" -Always
                return $true
            }
            'auto-chip' {
                $row = Find-ChatOverlayRow $Snap $w[1]
                if (-not $row) { $row = Find-ChatOverlayRow $H.Snap $w[1] }
                if (-not $row) { Write-ChatOverlayLog "auto-chip: $($w[2]), for a row the panel has no more"; return $false }
                Invoke-ChatOverlayAutoChip $H $row $w[2]
                return $true
            }
            'delete' {
                $key = $w[1]
                $row = Find-ChatOverlayRow $Snap $key
                if (-not $row -or -not [string](Get-ChatField $row 'sessionId')) {
                    Add-ChatOverlaySaid $H (Get-ChatOverlayDeleteSay $false 'Nothing deleted - that chat is not on the panel any more.') $key
                    return $true
                }
                if (-not (Test-ChatOverlayRowDeletable $row)) {
                    Add-ChatOverlaySaid $H (Get-ChatOverlayDeleteSay $false 'Nothing deleted - not while the chat works or waits on you, or while a terminal or a queued prompt has it open.') $key
                    return $true
                }
                $r = Remove-ChatOverlayRow $H $row
                if ($r.Say) { Show-ChatOverlayBalloon $H $r.Say }
                Add-ChatOverlaySaid $H (Get-ChatOverlayDeleteSay ([bool]$r.Done) ([string]$r.Say)) $key
                return $true
            }
            'reload-answer' {
                $ask = @($H.Ctx.Reloads | Where-Object { $_ -and "$($_.pid):$($_.id)" -ceq $w[1] }) | Select-Object -First 1
                if (-not $ask) { Write-ChatOverlayLog "reload: $($w[2]), for an ask no window has now"; return $false }
                $hostPid = [int]$ask.pid
                Write-ChatReloadAnswer -HostPid $hostPid -Id ([string]$ask.id) -Answer $w[2]
                Write-ChatOverlayLog "reload: $($w[2]), to the window of pid $hostPid" -Always
                if ($H.Ctx.ReloadAnswered -isnot [hashtable]) { $H.Ctx.ReloadAnswered = @{} }
                $H.Ctx.ReloadAnswered["${hostPid}:$($ask.id)"] = Get-Date
                Add-ChatOverlaySaid $H (Get-ChatOverlayReloadSay ([string]$ask.window) $w[2]) "reload:$hostPid"
                return $true
            }
            'card' {
                $key = $w[1]
                $row = Find-ChatOverlayRow $Snap $key
                $model = $null
                if ($row) {
                    $src = Get-ChatOverlayCardSource $H.Ctx $row
                    $tail = if ($src.Path) { Read-ChatOverlayCardTail $src.Path } else { $null }
                    $model = Get-ChatOverlayCardModel $row $tail $src ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
                }
                Save-ChatqText $script:ChatOverlayCardPath (ConvertTo-Json -InputObject ([ordered]@{ key = $key; at = (ConvertTo-ChatOverlayMs (Get-Date)); model = $model }) -Depth 6 -Compress)
                return $false
            }
        }
    }
    catch { Write-ChatOverlayLog "panel $($w[0]): $($_.Exception.Message)" }
    return $false
}

function Send-ChatOverlayPanelVerb {
    # A verb for the panel from the headless host itself, as the shell's
    # are (Invoke-ChatOverlayCycle): show and expand for an ask that changed
    # under its answer, show for a close taken back, the hotkey. The next
    # pass at once, for the panel to have it.
    param($Ctx, [string]$Verb)
    $Ctx.CommandId++
    $Ctx.Commands.Add([pscustomobject]@{ id = $Ctx.CommandId; verb = $Verb; at = (ConvertTo-ChatOverlayMs (Get-Date)) })
    $Ctx.PassNow = $true
}

function Import-ChatOverlayConsoleParts {
    <#
    The console's parts - the WPF panel's and its own, overlay-windows.ps1
    and console.ps1 - into the headless host, the first time its console is
    asked for: its launch leaves them out (Get-ChatOverlayLaunch), as it
    draws nothing until then. Their text is what the host read as it
    started ($Ctx.ConsoleParts, Read-ChatOverlayConsoleParts), so code on
    disk changed since puts no new part beside old ones: the console opens
    in this process, which its panel let come forward, not in a restart
    that Windows would keep behind. Dot-sourced into the global scope, where
    its launch put the others, by Import-ChatTool's way (Get-ChatShellScope);
    between the swap and the swap back nothing of this function's own is in
    reach, so what it needs is in $global:ChatOverlayPartsLoad. $true once
    they are in.
    #>
    param($Ctx)
    if (${function:New-ChatConsole}) { return $true }
    $text = $Ctx.ConsoleParts
    if (-not $text) { Write-ChatOverlayLog 'console: its parts were not read as the overlay started' -Always; return $false }
    $s = Get-ChatShellScope
    if (-not $s) { Write-ChatOverlayLog 'console: this PowerShell cannot load its parts' -Always; return $false }
    $u = [System.Text.UTF8Encoding]::new($false)
    $global:ChatOverlayPartsLoad = @{ Scope = $s; Was = $s.Current.GetValue($s.Ssi)
        A = [scriptblock]::Create($u.GetString($text.A)); B = [scriptblock]::Create($u.GetString($text.B))
    }
    try {
        $s.Current.SetValue($s.Ssi, $s.Global)
        try { . $global:ChatOverlayPartsLoad.A; . $global:ChatOverlayPartsLoad.B }
        finally { $global:ChatOverlayPartsLoad.Scope.Current.SetValue($global:ChatOverlayPartsLoad.Scope.Ssi, $global:ChatOverlayPartsLoad.Was) }
    }
    catch { Write-ChatOverlayLog "console: its parts did not load: $($_.Exception.Message)" -Always }
    finally { Remove-Variable -Name ChatOverlayPartsLoad -Scope Global -EA SilentlyContinue }
    return [bool]${function:New-ChatConsole}
}

function Read-ChatOverlayConsoleParts {
    # the console's parts, overlay-windows.ps1 and console.ps1, as bytes -
    # read as the headless host starts, for its console to load whenever it
    # is first asked for (Import-ChatOverlayConsoleParts): some 0.5 MB held
    # for the host's life. $null when they cannot be read.
    try {
        $src = [System.IO.Path]::Combine([string]$script:ChatRoot, 'src')
        return @{ A = [System.IO.File]::ReadAllBytes([System.IO.Path]::Combine($src, 'overlay-windows.ps1')); B = [System.IO.File]::ReadAllBytes([System.IO.Path]::Combine($src, 'console.ps1')) }
    }
    catch { Write-ChatOverlayLog "console: its parts not read: $($_.Exception.Message)" -Always; return $null }
}

function Start-ChatOverlayHeadlessClose {
    <#
    The panel's x, the tray's Quit, on the headless host: as the WPF one
    closes by hand (Close-ChatOverlayByHand), said in a balloon - its
    panel's - and the process 4 s on ($H.CloseAt); the panel hides
    meanwhile (the snapshot's ui.closing). Then the overlay asked for again
    takes the close back (Undo-ChatOverlayHeadlessClose), a restart is the
    stop, and nothing else is taken. The close is kept once the panel has
    gone, as a stop's is (Set-ChatOverlayClosed, in
    Start-ChatOverlayHeadlessHost's finally). $false where the sign-in
    cannot be told: a stop at once, with nothing kept, so nothing to say.
    #>
    param($H)
    if (-not (Get-ChatqSignInAt)) { return $false }
    $H.Closing = $true
    $H.CloseAt = [datetime]::UtcNow.AddSeconds(4)
    Write-ChatOverlayLog 'closed by hand, until the next sign-in' -Always
    Show-ChatOverlayBalloon $H 'Closed until you next sign in. Type charlie to bring it back sooner.' -Ms 4000 -Kind 'close'
    # the wait between passes ends with the 4 s (Invoke-ChatOverlayCollectLoop)
    $H.Ctx.WakeAt = $H.CloseAt
    $H.Ctx.PanelClosing = $true
    $H.Ctx.PassNow = $true
    return $true
}

function Undo-ChatOverlayHeadlessClose {
    # a close by hand taken back in its 4 s (Start-ChatOverlayHeadlessClose),
    # as Undo-ChatOverlayClose takes the WPF one's: the panel shows again
    param($H)
    if (-not $H.Closing) { return }
    $H.Closing = $false
    $H.CloseAt = $null
    $H.Ctx.WakeAt = $null
    $H.Ctx.PanelClosing = $false
    Write-ChatOverlayLog 'the close by hand taken back' -Always
    $H.Ctx.PassNow = $true
}

function New-ChatOverlayHeadlessState {
    # what the headless host keeps: the names the moved news functions
    # read off a WPF host's (New-ChatOverlayHostState), and its own
    $now = Get-Date
    @{
        Ctx = $null; State = $null; Tray = $null; Menu = @{}; Closing = $false
        BalloonKind = $null; BalloonKeys = @(); AskRequest = $null; AskMenuKeys = @()
        CompactAt = $null; StartedAt = $null; Settled = $null; MemRestart = $null; RestartWhy = $null
        Events = [System.Collections.Generic.List[object]]::new(); EventBase = (ConvertTo-ChatOverlayMs $now); EventN = 0
        # the panel's process, its starts, and the first one's time, in
        # epoch ms (Start-ChatOverlayUi -Since)
        Child = $null; Starts = [System.Collections.Generic.List[datetime]]::new(); UiSince = 0; UnderWay = $false; Snap = $null
        # the console's window, once asked for (Open-ChatOverlayHeadlessConsole),
        # and the timer its waits run on; a close by hand's end (CloseAt); a
        # verb to take as the first pass's (Open) - the next start's too, if
        # that pass is the last
        Console = $null; ConWake = $null; CloseAt = $null; Open = ''
    }
}

function Start-ChatOverlayHeadlessHost {
    <#
    The overlay with its panel in a process of its own: this PowerShell
    collects, every -IntervalMs, and -UiExe draws data/overlay.json and
    sends its clicks back as verbs in overlay-cmd. No window, tray or WPF
    type here. What the WPF host does as it starts, this does too - the
    lock, overlay.pid, the reply standing, the usage kept, a close by hand
    lifted. Each pass then: the panel's word read (Read-ChatOverlayUi), its
    seen news dropped, its clicks carried out (Invoke-ChatOverlayPanelVerb),
    this pass's news queued as events, the heap compacted every 5 minutes
    and a memory or code restart taken once nothing is under way there. A
    panel that exits unasked is started again: 3 starts in 10 minutes at
    most, the first and 2 restarts, and its exit after the third ends the
    host ('panel'). A wake every 250 ms between passes looks for a verb,
    so a click is acted on at once, and one acted on starts the next pass
    at once too, for the panel to draw its outcome. A panel started again
    acts on the commands the last one had not said it had done
    (Update-ChatOverlayCommands).
    The console: a window of this process's own, the WPF one, its parts
    loaded the first time it is asked for (Import-ChatOverlayConsoleParts,
    Open-ChatOverlayHeadlessConsole). While it shows, the panel hides (the
    snapshot's ui.console) and the waits between passes run its thread
    (Wait-ChatOverlayHeadlessConsole); back to the panel, the panel shows
    again. -Open console: it opens with the first pass - chatconsole's
    start - or, should that pass end the host in a restart, with the next
    host's.
    The panel's close, by hand: said, and the process 4 s on, in which the
    overlay asked for again takes it back (Start-ChatOverlayHeadlessClose).
    A stop, or that close: the panel is told to go first, and the close by
    hand kept once it has (Set-ChatOverlayClosed) - after, so a panel
    saving its place as it goes never writes over it. A restart: the same
    launch again (Start-ChatOverlayProcess -UiExe), once the lock is let go
    - the new code's own panel (Resolve-ChatOverlayUiExe), the WPF one when
    the new version has none staged, as a fresh start - unless config.json
    now asks for the WPF panel (charlie -Panel ps), which it starts instead.
    A host started for a staged panel its own version has none of starts
    the WPF one in its place, at once.
    Returns why it ended.
    #>
    param([Parameter(Mandatory)][string]$UiExe, [int]$IntervalMs = 2000, [int]$MaxCycles = 0, [ValidateSet('', 'console')][string]$Open = '')
    Set-StrictMode -Off
    $UiExe = Resolve-ChatOverlayUiExe $UiExe
    # a staged panel this code's version has none of: the WPF one, as a
    # fresh start would give (Get-ChatOverlayPanelExe) - before the lock,
    # for that launch to take it
    if (-not $UiExe) { [void](Start-ChatOverlayProcess -Open $Open); return 'restart' }
    New-ChatqDir $script:ChatqData
    $lock = Lock-ChatOverlay
    if (-not $lock) { Write-ChatOverlayLog "overlay $PID found one already running"; return 'running' }
    $H = New-ChatOverlayHeadlessState
    $why = $null
    try {
        Set-Content -LiteralPath $script:ChatOverlayPidPath -Value $PID -Encoding ASCII
        Remove-Item -LiteralPath $script:ChatOverlayCmdPath -Force -EA SilentlyContinue
        Write-ChatOverlayLog "overlay $PID started ($script:ChatVersion, headless)"
        $H.CompactAt = (Get-Date).AddMinutes(3)
        $H.StartedAt = Get-Date
        foreach ($e in @(Read-ChatOverlayEvents)) { $H.Events.Add($e) }
        $ctx = New-ChatOverlayContext
        $H.Ctx = $ctx
        # the snapshot carries the news, and what the panel's own state
        # needs (Invoke-ChatOverlayCycle)
        $ctx.Events = $H.Events
        $ctx.RecentPool = $true
        $ctx.CodeStamp = Get-ChatOverlayCodeStamp
        $ctx.CodeLookAt = Get-Date
        $ctx.ConsoleParts = Read-ChatOverlayConsoleParts
        $ctx.WantPhone = $true
        $ctx.WantAsk = $true
        $ctx.WantAuto = $true
        try { if (Start-ChatqReplyStanding) { $null = Request-ChatqWatcher } } catch {}
        Restore-ChatOverlayUsage $ctx
        $H.State = Read-ChatOverlayState
        Clear-ChatOverlayClosed $H.State
        # chatconsole's start: the console with the first pass, and the
        # panel hidden under it from the first snapshot on
        if ($Open) { $H.Open = $Open; $ctx.PanelConsole = $true }
        [void](Invoke-ChatOverlayCycle $ctx)
        Update-ChatOverlayAsk $H
        Show-ChatOverlayAutoNotice $H
        $why = @(@($ctx.Verbs) | Where-Object { $_ -in 'stop', 'restart', 'close' })[0]
        if (-not $why) {
            $H.UiSince = ConvertTo-ChatOverlayMs (Get-Date)
            $H.Child = Start-ChatOverlayUi $UiExe $H.UiSince
            $H.Starts.Add((Get-Date))
            # the console's thread run between passes while it is open
            $why = Invoke-ChatOverlayCollectLoop $ctx -IntervalMs $IntervalMs -MaxCycles $MaxCycles -WakeMs 250 -Wait {
                param($until)
                if ($H.Console) { Wait-ChatOverlayHeadlessConsole $H $until } else { $false }
            } -OnCycle {
                param($snap)
                $now = Get-Date
                $ui = Read-ChatOverlayUi
                Update-ChatOverlayEvents $H $ui $now
                Update-ChatOverlayCommands $ctx $ui
                # this pass's verbs, and -Open's with the first
                $verbs = @($ctx.Verbs)
                if ($H.Open) { $verbs += @($H.Open); $H.Open = '' }
                foreach ($v in $verbs) {
                    # Closing by hand (Start-ChatOverlayHeadlessClose), as the
                    # WPF host's (Invoke-ChatOverlayVerb): the overlay asked
                    # for again - charlie's show, the hotkey, the tray, the
                    # console - takes the close back, and the panel shows,
                    # from the tray too; the hotkey does no more, as it would
                    # unlock the panel just brought back. Nothing else is taken.
                    if ($H.Closing) {
                        if ($v -notin 'show', 'hotkey', 'console', 'console-key') { continue }
                        Undo-ChatOverlayHeadlessClose $H
                        if ($v -in 'show', 'hotkey') { Send-ChatOverlayPanelVerb $ctx 'show'; continue }
                    }
                    # the panel's x, the tray's Quit: a close by hand, the
                    # console back to the panel first, as the WPF host's
                    if ($v -eq 'close') {
                        if ($H.Console) { Exit-ChatOverlayConsoleMode $H.Console }
                        if (-not (Start-ChatOverlayHeadlessClose $H)) { return 'close' }
                        continue
                    }
                    if ($v -eq 'phone') { try { [void](Start-ChatqPhoneSetup -NoWait) } catch { Write-ChatOverlayLog "phone setup: $($_.Exception.Message)" } }
                    if ([string]$v -match '^(opened|delete|card|reload-answer|config|auto-chip) ' -and (Invoke-ChatOverlayPanelVerb $H $v $snap)) { $ctx.PassNow = $true }
                    # The console, as the WPF host's verbs bring it
                    # (Invoke-ChatOverlayVerb): the tray's item, chatconsole
                    # and -Open open it or bring it forward; its hotkey again
                    # while it has the keyboard goes back to the panel - on
                    # the parts this host started with, however the code on
                    # disk has changed (Import-ChatOverlayConsoleParts).
                    # Opened, the next pass
                    # at once, for the panel to hide: the open has set what
                    # the snapshot says (Ctx.PanelConsole), so the sync below
                    # sees no change to start one.
                    if ($v -in 'console', 'console-key') {
                        $active = if ($script:ChatConsoleActiveSeam) { [bool](& $script:ChatConsoleActiveSeam) } else { [bool]($H.Console -and $H.Console.Win.IsActive) }
                        if ($v -eq 'console-key' -and $H.Console -and $H.Console.Mode -eq 'console' -and $active) { Exit-ChatOverlayConsoleMode $H.Console }
                        elseif (Import-ChatOverlayConsoleParts $ctx) { Open-ChatOverlayHeadlessConsole $H -Activate; $ctx.PassNow = $true }
                    }
                    # back to the panel: the panel's own hotkey while the
                    # console shows (console-back), and the shell's verbs that
                    # act on the panel, which the panel then takes; outside
                    # the console, the shell's hotkey is the panel's
                    if ($v -eq 'console-back' -and $H.Console) { Exit-ChatOverlayConsoleMode $H.Console }
                    if ($v -eq 'hotkey') {
                        if ($H.Console -and $H.Console.Mode -eq 'console') { Exit-ChatOverlayConsoleMode $H.Console }
                        else { Send-ChatOverlayPanelVerb $ctx 'hotkey' }
                    }
                    if ($v -in 'lock', 'unlock', 'toggle', 'hide', 'collapse', 'expand', 'reset' -and $H.Console) { Exit-ChatOverlayConsoleMode $H.Console }
                    if ($v -in 'crash-on', 'crash-off') {
                        $on = $v -eq 'crash-on'
                        if ([bool]$ctx.Config.autoContinueCrash -ne $on) {
                            try {
                                [void](Set-ChatqAutoContinueCrash -Value $on)
                                $ctx.Config = Get-ChatOverlayConfig
                                $ctx.CutAt = [datetime]::MinValue
                                Write-ChatOverlayLog "crash continue $(if ($on) { 'on' } else { 'off' }) from the panel" -Always
                            }
                            catch { Write-ChatOverlayLog "settings: $($_.Exception.Message)" }
                        }
                    }
                }
                # the panel's auto-continue switch set on (Invoke-ChatOverlayAutoVerbs):
                # said once what it does, as the WPF box says it
                # (Set-ChatOverlayAutoChoice) - after a close by hand's
                # balloon, which it would cover
                if ($ctx.AutoSet -and -not $H.Closing) {
                    if ($ctx.AutoSet -eq 'on') { Show-ChatOverlayAutoNotice $H }
                    $ctx.AutoSet = $null
                }
                # The reset ask's answer this pass carried out, followed as the
                # WPF host follows its own (Invoke-ChatOverlayAskAnswer): the
                # watcher it asked for watched (Update-ChatOverlayAsk), and an
                # ask that changed under it shown as it is now - the panel
                # shown and opened out, the console's list drawn anew and
                # said so (Update-ChatOverlayHeadlessConsole).
                $ans = $ctx.AskAnswer
                $ctx.AskAnswer = $null
                if ($ans) {
                    if ($ans.Request) { $H.AskRequest = $ans.Request }
                    if ($ans.Stale -and -not ($H.Console -and $H.Console.Mode -eq 'console')) { Send-ChatOverlayPanelVerb $ctx 'show'; Send-ChatOverlayPanelVerb $ctx 'expand' }
                    $ctx.PassNow = $true
                }
                if ($snap) { $H.Snap = $snap }
                # the console drawn from this pass, and told when the config
                # was read again; the panel hidden under it while it shows
                $cw = $false
                if ($H.Console) { $cw = Update-ChatOverlayHeadlessConsole $H $snap -Reload:(@($verbs | Where-Object { $_ -eq 'reload' -or [string]$_ -like 'config *' }).Count -gt 0) -Answer $ans }
                $con = [bool]($H.Console -and $H.Console.Mode -eq 'console')
                if ($con -ne [bool]$ctx.PanelConsole) { $ctx.PanelConsole = $con; $ctx.PassNow = $true }
                $H.UnderWay = (Test-ChatOverlayUiUnderWay $ui $now) -or $H.Closing -or $cw
                # Not while a close by hand is on its way, as on the WPF host
                # (Invoke-ChatOverlayTick): each says its news in a balloon,
                # which Show-ChatOverlayBalloon would drop; said once the
                # close is taken back.
                if (-not $H.Closing) {
                    Show-ChatOverlayMemory $H
                    Update-ChatOverlayAsk $H
                    Show-ChatOverlayAutoQueued $H
                }
                # the close's 4 s are up, the commands read once more
                if ($H.Closing -and [datetime]::UtcNow -ge $H.CloseAt) { return 'close' }
                if ($H.Child -and $H.Child.HasExited) {
                    $recent = @($H.Starts | Where-Object { $_ -gt $now.AddMinutes(-10) })
                    if ($recent.Count -ge 3) { Write-ChatOverlayLog 'the panel keeps exiting - stopping' -Always; return 'panel' }
                    Write-ChatOverlayLog "the panel exited ($($H.Child.ExitCode)) - starting it again" -Always
                    $H.Child = Start-ChatOverlayUi $UiExe $H.UiSince
                    $H.Starts.Add($now)
                }
                if ($H.CompactAt -and $now -ge $H.CompactAt) {
                    $H.CompactAt = $now.AddMinutes(5)
                    Update-ChatOverlayRestartDue $H (Invoke-ChatOverlayHeapCompact) $now
                }
                if (-not $H.UnderWay -and (Test-ChatOverlayCodeChanged $ctx)) {
                    Write-ChatOverlayLog 'the code on disk changed - restarting on it' -Always
                    return 'restart'
                }
                if ($H.MemRestart -and -not $H.UnderWay) {
                    Write-ChatOverlayLog $H.MemRestart -Always
                    $H.RestartWhy = 'memory'
                    return 'restart'
                }
                return $null
            }
        }
        # a restart - chatinstall's, the extension's - while a close by hand
        # is on its way is the stop it waits for, as on the WPF host: the new
        # process would lift the close just made
        if ($why -eq 'restart' -and $H.Closing) { $why = 'stop' }
    }
    catch { Write-ChatOverlayLog "overlay failed: $($_.Exception.Message) @ $(($_.ScriptStackTrace -split "`n")[0])" }
    finally {
        # the console's draft kept as its window goes (Close-ChatOverlayWindow)
        if ($H.Console) { Stop-ChatOverlayHeadlessConsole $H }
        Stop-ChatOverlayUi $H.Child
        # the file's state, read now: the panel may have saved its place
        if ($why -in 'stop', 'close') { [void](Set-ChatOverlayClosed) }
        try { $lock.Dispose() } catch {}
        Remove-Item -LiteralPath $script:ChatOverlayPidPath -Force -EA SilentlyContinue
        Write-ChatOverlayLog "overlay $PID stopped ($why)$(if ($H.RestartWhy -eq 'memory') { ' - a memory restart, to give back what this run held' })"
    }
    # the panel config.json asks for now - the WPF one, after charlie -Panel
    # ps - and the console asked for, if the first pass ended the host before
    # it could open it
    if ($why -eq 'restart') {
        # resolved again against the script on disk, the new code's version:
        # its staged panel, or none for the WPF one, as a fresh start gives
        $next = if ((Get-ChatOverlayConfig).panel -eq 'native') { Resolve-ChatOverlayUiExe $UiExe } else { '' }
        [void](Start-ChatOverlayProcess -UiExe $next -Open $H.Open)
    }
    return $why
}

#endregion
