# Charlie-and-the-chat-factory, src/shell.ps1: dot-sourced by Charlie-and-the-chat-factory.ps1
# in its turn, never on its own - see the list there.

#region the shell's own -------------------------------------------------------
# A shell whose profile loads this tool mostly never runs one of its
# commands: it hosts claude, or ordinary work. So a profile's load takes this
# part alone (Enter-ChatShell) - a stand-in for each command, the aliases,
# the key handlers, the ghost watch and the checks a shell makes as it opens -
# and the first command, the first Tab or Enter on a chat line, or a check
# that finds work loads the rest (Import-ChatTool). Every other load takes
# this part with the rest, so what both need is written once, here.

# the commands a person types, each given a stand-in by a lazy shell; the
# self-test holds this list to every chat* function and charlie in src/
$script:ChatShellCommands = 'chat', 'chatfind', 'chatrm', 'chatarchive', 'chatrestore', 'chatclean', 'chatproviders', 'chatindex',
'chatq', 'chatqlist', 'chatqrm', 'chatqrun', 'chatqlog', 'chatnotify', 'charlie', 'chatconsole', 'chatinstall', 'chatuninstall'

function Test-ChatqLockHeld {
    # The watcher and the overlay each hold a lock file open with no sharing
    # for their whole life, and the OS lets go of it even when the process dies
    # hard - so being able to open it means nobody holds it. A pid file alone
    # would lie after a crash, and pids get reused.
    # Here, not in alerts.ps1: a lazy shell asks it before the tool loads -
    # so .NET's file test, not Test-Path, whose module that shell does not
    # load (Get-ChatShellPaths). Every path it is given is a full one.
    param([string]$Path)
    if (-not [System.IO.File]::Exists($Path)) { return $false }
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'ReadWrite', 'None')
        $fs.Dispose()
        return $false
    }
    catch { return $true }
}

function Test-ChatGhostWatch {
    # Asking Get-EventSubscriber for a name that is not registered raises an
    # error - and -ErrorAction SilentlyContinue hides it but still files it in
    # $Error. Listing and filtering asks the same question quietly.
    [bool]@(Get-EventSubscriber -EA SilentlyContinue |
        Where-Object { $_.SourceIdentifier -eq 'ChatGhostWatch' })
}

function Start-ChatGhostWatch {
    # Why running it a second time works: the window flushes a tracked session
    # to disk once, when it reloads. After that reload it rebuilds its list
    # from disk and is no longer holding that session, so the next delete
    # sticks. The write is a single event, not a state to out-wait - so watch
    # for it instead of polling, and take the file back the moment it lands.
    #
    # Created only, and FileName only: transcripts are appended to constantly,
    # and a rewritten ghost always arrives as a brand new file. That keeps this
    # silent until the one event that matters.
    #
    # Here, not at the call sites: tombstones and the index sweep start it too,
    # and the background watcher runs both. That process is headless and
    # outlives the shell - a second watch there would only race this one.
    # In this part, not chatrm.ps1: a lazy shell starts it before the tool
    # loads, since data/rewritten.txt can stay for days after a delete.
    if ($env:CHATQ_WATCHER -or $env:CHATQ_OVERLAY -or $script:ChatNoGhostWatch) { return }
    if (Test-ChatGhostWatch) { return }
    $root = Join-Path $script:ChatClaudeHome 'projects'
    if (-not (Test-Path -LiteralPath $root)) { return }

    $fsw = New-Object System.IO.FileSystemWatcher $root, '*.jsonl'
    $fsw.IncludeSubdirectories = $true
    $fsw.NotifyFilter = [System.IO.NotifyFilters]::FileName
    $fsw.EnableRaisingEvents = $true
    $script:ChatGhostWatcher = $fsw          # a reference, or it is collected

    # self-contained: this runs in its own runspace, with none of these
    # functions loaded, and must stay silent so it cannot garble the prompt
    $null = Register-ObjectEvent -InputObject $fsw -EventName Created `
        -SourceIdentifier 'ChatGhostWatch' -MessageData $script:ChatTombPath -Action {
        $tomb = $Event.MessageData
        $path = $Event.SourceEventArgs.FullPath
        if (-not (Test-Path -LiteralPath $tomb)) { return }
        # the same seven days the sweep honours, or an entry the sweep would
        # have dropped would still be acted on here
        $cutoff = (Get-Date).AddDays(-7)
        $wanted = @(Get-Content -LiteralPath $tomb -EA SilentlyContinue | ForEach-Object {
                $parts = $_ -split "`t", 2
                if ($parts.Count -eq 2) {
                    $when = try {
                        [datetime]::Parse($parts[0], [System.Globalization.CultureInfo]::InvariantCulture,
                            [System.Globalization.DateTimeStyles]::RoundtripKind)
                    }
                    catch { $null }
                    if ($when -and $when -ge $cutoff) { $parts[1] }
                }
            })
        if ($wanted -notcontains $path) { return }
        Start-Sleep -Milliseconds 200        # let the writer finish the file
        $f = Get-Item -LiteralPath $path -EA SilentlyContinue
        if (-not $f -or $f.Length -gt 65536) { return }
        # runs in the watcher's own runspace, where the shared-read helpers are
        # not defined - open the handle inline, sharing what a writer may hold
        $t = try {
            $fh = [System.IO.FileStream]::new($f.FullName, [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
            try { [System.IO.StreamReader]::new($fh).ReadToEnd() } finally { $fh.Dispose() }
        }
        catch { return }
        if ($t -like '*"type":"user"*' -or $t -like '*"type":"assistant"*') { return }
        Remove-Item -LiteralPath $path -Force -EA SilentlyContinue
    }
}

function Stop-ChatGhostWatch {
    if (Test-ChatGhostWatch) { Unregister-Event -SourceIdentifier 'ChatGhostWatch' -EA SilentlyContinue }
    if ($script:ChatGhostWatcher) {
        $script:ChatGhostWatcher.EnableRaisingEvents = $false
        $script:ChatGhostWatcher.Dispose()
        $script:ChatGhostWatcher = $null
    }
}

function Set-ChatShellAliases {
    # verb-noun aliases so Get-Command *-Chat* and Find-<Tab> surface these too
    Set-Alias -Name Find-Chat -Value chatfind -Scope Global -Force
    Set-Alias -Name Remove-Chat -Value chatrm -Scope Global -Force
    Set-Alias -Name Get-ChatProvider -Value chatproviders -Scope Global -Force
    Set-Alias -Name Update-ChatIndex -Value chatindex -Scope Global -Force
    # chatnotify's old name, from when it only served chatq's queue; a profile
    # or a habit that still types it keeps working. Global like the ones above.
    Set-Alias -Name chatqnotify -Value chatnotify -Scope Global -Force
    # charlie's old name, from before the panel was Charlie's; a profile, a
    # habit or the extension that still types it keeps working. Global like
    # the ones above.
    Set-Alias -Name chatoverlay -Value charlie -Scope Global -Force
}

#endregion

#region the keys -------------------------------------------------------------
# The cycler itself is in discoverability.ps1. Each key's handler is bound
# here, once, to Invoke-ChatKey, which hands it to the tool's own handler
# (Invoke-ChatTabKey and the rest) - or, in a lazy shell before the tool has
# loaded, decides by itself (Get-ChatShellKeyAction).

function Invoke-ChatPSReadLine {
    # call a PSReadLine action by name, so the arrows keep doing
    # whatever they were bound to before this file was loaded
    param([string]$Name, [string]$Fallback)
    if (-not $Name) { $Name = $Fallback }
    $mi = [Microsoft.PowerShell.PSConsoleReadLine].GetMethod(
        $Name, [type[]]@([System.Nullable[System.ConsoleKeyInfo]], [object]))
    if (-not $mi) {
        $mi = [Microsoft.PowerShell.PSConsoleReadLine].GetMethod(
            $Fallback, [type[]]@([System.Nullable[System.ConsoleKeyInfo]], [object]))
    }
    if ($mi) { [void]$mi.Invoke($null, @($null, $null)) }
}

function Register-ChatKeyHandlers {
    # Tab starts or advances the run, Shift+Tab steps back, and the arrows do the
    # same but only while a run is live - otherwise they stay history navigation.
    # Opt out with $ChatNoKeyBindings = $true before the dot-source line. Read
    # through Get-Variable: under StrictMode an unset one throws, and every shell
    # start would lose its key handlers. Never in the background watcher or the
    # overlay, which have no keyboard, nor anywhere else not interactive. A shell
    # with no PSReadLine fails the import, which the catch at the end takes:
    # asking first (Get-Module -ListAvailable) read every module folder, 0.1 to
    # 0.35 s of every shell's start.
    if (-not (Get-Variable -Name ChatNoKeyBindings -ValueOnly -EA SilentlyContinue) -and
        -not $env:CHATQ_WATCHER -and -not $env:CHATQ_OVERLAY -and [Environment]::UserInteractive) {
        try {
            # -Global: where the import stood when this was the top level of
            # a part, dot-sourced into the shell
            Import-Module PSReadLine -EA Stop -Global

            # remember what the arrows did before we took them over
            $script:ChatArrowWas = @{}
            foreach ($k in 'UpArrow', 'DownArrow') {
                $bound = Get-PSReadLineKeyHandler -Bound | Where-Object { $_.Key -eq $k }
                $script:ChatArrowWas[$k] = if ($bound) { $bound.Function } else { $null }
            }

            Set-PSReadLineKeyHandler -Key Tab -BriefDescription 'ChatCycleNext' `
                -Description 'Fill in the next matching chat, described in a trailing comment' -ScriptBlock { Invoke-ChatKey Tab }
            Set-PSReadLineKeyHandler -Key Shift+Tab -BriefDescription 'ChatCyclePrev' `
                -Description 'Step back through the matching chats' -ScriptBlock { Invoke-ChatKey ShiftTab }
            Set-PSReadLineKeyHandler -Key DownArrow -BriefDescription 'ChatCycleOrHistory' `
                -Description 'Next matching chat while cycling, history otherwise' -ScriptBlock { Invoke-ChatKey DownArrow }
            Set-PSReadLineKeyHandler -Key UpArrow -BriefDescription 'ChatCycleOrHistory' `
                -Description 'Previous matching chat while cycling, history otherwise' -ScriptBlock { Invoke-ChatKey UpArrow }
            Set-PSReadLineKeyHandler -Key Enter -BriefDescription 'ChatAcceptLine' `
                -Description 'Drop the age and counter, then run the line' -ScriptBlock { Invoke-ChatKey Enter }
        }
        catch {}
    }
}

function Get-ChatShellKeyAction {
    # What a key does in a lazy shell whose tool has not loaded: 'load' for
    # Tab or Enter on a line that starts with one of its commands - the
    # cycler, the completers and Enter's filling in of a part-typed title all
    # need the tool - and otherwise what the tool's own handler does on a line
    # nothing is cycling on, which before a load is every line.
    param([string]$Key, [string]$Line)
    if ($Key -in 'Tab', 'Enter' -and $script:ChatShellLinePattern -and $Line -match $script:ChatShellLinePattern) { return 'load' }
    switch ($Key) {
        'Tab' { return 'TabCompleteNext' }
        'ShiftTab' { return 'TabCompletePrevious' }
        'UpArrow' { return 'PreviousHistory' }
        'DownArrow' { return 'NextHistory' }
    }
    return 'AcceptLine'
}

function Invoke-ChatKey {
    # every key handler's one line. Never throws into PSReadLine: a throw
    # inside a key handler makes the key unusable
    param([string]$Key)
    Set-StrictMode -Off
    if ($global:ChatShellLazy) {
        $line = $null; $pos = 0
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$pos)
        $do = Get-ChatShellKeyAction $Key $line
        # the tool's first load, here in the key, is the 0.4 s a shell's start
        # used to spend; one that fails leaves the key its plain meaning
        if ($do -eq 'load' -and -not (Import-ChatTool)) { $do = Get-ChatShellKeyAction $Key '' }
        if ($do -ne 'load') {
            switch ($do) {
                'TabCompleteNext' { [Microsoft.PowerShell.PSConsoleReadLine]::TabCompleteNext() }
                'TabCompletePrevious' { [Microsoft.PowerShell.PSConsoleReadLine]::TabCompletePrevious() }
                'PreviousHistory' { Invoke-ChatPSReadLine $script:ChatArrowWas['UpArrow'] 'PreviousHistory' }
                'NextHistory' { Invoke-ChatPSReadLine $script:ChatArrowWas['DownArrow'] 'NextHistory' }
                default { [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine() }
            }
            return
        }
    }
    switch ($Key) {
        'Tab' { Invoke-ChatTabKey }
        'ShiftTab' { Invoke-ChatShiftTabKey }
        'UpArrow' { Invoke-ChatUpArrowKey }
        'DownArrow' { Invoke-ChatDownArrowKey }
        'Enter' { Invoke-ChatEnterKey }
    }
}

#endregion

#region a shell's start -------------------------------------------------------

function Start-ChatShellDuties {
    # A shell opening after a reboot picks the watcher back up. Cheap when the
    # queue is empty: one directory listing. A function, so turning StrictMode
    # off here leaves the user's own setting alone. Run by the script's tail
    # as a shell loads it, and by a lazy shell once Test-ChatShellDuty finds
    # something for it, with the tool loaded first.
    Set-StrictMode -Off
    try {
        if ((Test-Path -LiteralPath $script:ChatqQueueDir) -and -not (Test-ChatqWatcherAlive)) {
            $n = @(Get-ChatqJobs | Where-Object { $_.state -eq 'queued' }).Count
            if ($n -and (Start-ChatqWatcher)) { Write-Host "  chatq: $n queued - watcher started" -ForegroundColor DarkGray }
        }
        # reply.listen always: listening all the time starts again with a shell
        $null = Start-ChatqReplyStanding
        # and one listening for a reply to a phone alert still out there
        if (-not (Test-ChatqWatcherAlive) -and (Test-ChatqReplyOpen) -and (Start-ChatqWatcher)) {
            Write-Host '  chatq: listening for phone replies - watcher started' -ForegroundColor DarkGray
        }
    }
    catch {}
    # The overlay, the same way back after a reboot: on by default on
    # Windows, since a chat clicked in it opens as a tab; charlie
    # -AutoStart off keeps it to when it is asked for. One file read and
    # a lock check when it is running already.
    try {
        if ((Start-ChatOverlayAuto) -eq 'started') { Write-Host '  charlie started' -ForegroundColor DarkGray }
    }
    catch {}
}

function Get-ChatShellPaths {
    # The files a lazy shell reads before the tool loads, by where the tool
    # keeps them: data/ beside the script. The self-test holds each to the
    # tool's own variable once it has loaded.
    # .NET's paths and file tests, here and in the rest of a lazy shell's
    # start, not Join-Path, Test-Path and Get-Content: those load the module
    # they are in, a few MB of a start that otherwise needs none of it.
    $d = [System.IO.Path]::Combine($script:ChatRoot, 'data')
    @{
        Queue        = [System.IO.Path]::Combine($d, 'queue')
        WatcherLock  = [System.IO.Path]::Combine($d, 'watcher.lock')
        Config       = [System.IO.Path]::Combine($d, 'config.json')
        Replies      = [System.IO.Path]::Combine($d, 'replies.json')
        OverlayLock  = [System.IO.Path]::Combine($d, 'overlay.lock')
        OverlayState = [System.IO.Path]::Combine($d, 'overlay-state.json')
        Tomb         = [System.IO.Path]::Combine($d, 'rewritten.txt')
    }
}

function Get-ChatShellSignInAt {
    # When this sign-in to Windows began, in epoch milliseconds, or $null:
    # Get-ChatqSignInAt's reading, which says why these two processes. Here,
    # and .NET's process list rather than Get-Process, because a lazy shell
    # asks it before the tool loads, and the cmdlet would load its module.
    try {
        $sid = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
        foreach ($name in 'sihost', 'explorer') {
            $first = $null
            foreach ($pr in [System.Diagnostics.Process]::GetProcessesByName($name)) {
                if ($pr.SessionId -ne $sid) { continue }
                $at = try { $pr.StartTime } catch { $null }
                if ($at -and ($null -eq $first -or $at -lt $first)) { $first = $at }
            }
            if ($first) { return [DateTimeOffset]::new($first).ToUnixTimeMilliseconds() }
        }
    }
    catch {}
    return $null
}

function Test-ChatShellDuty {
    <#
    Whether Start-ChatShellDuties may have something to do, asked of the files
    it reads without the tool loaded. $true sends the shell to load it and
    run them for real, so a $true too many costs one load, never a wrong
    start; only a $false where they would have acted loses anything. Each
    answer leans to $true: a file that will not read, a date that will not
    parse. The self-test holds each one to the duty it stands for
    (tests/sections/lazy-shell.ps1).
    #>
    Set-StrictMode -Off
    $p = Get-ChatShellPaths
    $prop = { param($o, $n) if ($null -ne $o -and $o.PSObject.Properties[$n]) { $o.$n } else { $null } }
    $json = { param($f) [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8) | ConvertFrom-Json }
    $watcher = Test-ChatqLockHeld $p.WatcherLock
    # a job queued and no watcher to send it (Get-ChatqJobs reads each file;
    # its text is enough to say none is queued)
    if (-not $watcher -and [System.IO.Directory]::Exists($p.Queue)) {
        $fs = try { [System.IO.Directory]::GetFiles($p.Queue, '*.json') } catch { return $true }
        foreach ($f in $fs) {
            $t = try { [System.IO.File]::ReadAllText($f) } catch { return $true }
            if ($t -match '"state"\s*:\s*"queued"') { return $true }
        }
    }
    $cfg = $null
    if ([System.IO.File]::Exists($p.Config)) {
        try { $cfg = & $json $p.Config } catch { return $true }
        if ($null -eq $cfg) { return $true }
    }
    $rp = & $prop $cfg 'reply'
    if ($rp -and (& $prop $rp 'on') -eq $true -and (& $prop $rp 'topic')) {
        $st = $null
        if ([System.IO.File]::Exists($p.Replies)) { try { $st = & $json $p.Replies } catch { return $true } }
        $standing = (& $prop $st 'standing') -eq $true
        # listening all the time and not marked so (Start-ChatqReplyStanding)
        if ((& $prop $rp 'key') -and [string](& $prop $rp 'listen') -eq 'always' -and -not $standing) { return $true }
        # a reply still to listen for, and no watcher listening (Test-ChatqReplyOpen)
        if (-not $watcher) {
            if ($standing) { return $true }
            $u = & $prop $st 'openUntil'
            if ($u) {
                try {
                    $d = if ($u -is [datetime]) { $u } else {
                        [datetime]::Parse([string]$u, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind) }
                    if ($d.ToUniversalTime() -gt [datetime]::UtcNow) { return $true }
                }
                catch { return $true }
            }
        }
    }
    # the overlay to start: where there is a panel to draw, on unless
    # -AutoStart off, not running, and not closed by hand since this sign-in
    # (Start-ChatOverlayAuto). On by default on Windows, so a close by hand
    # left to the tool would load it in every shell until the next sign-in.
    $win = [System.Environment]::OSVersion.Platform -eq 'Win32NT'
    if ($win -or $ExecutionContext.SessionState.PSVariable.GetValue('IsMacOS')) {
        $o = & $prop $cfg 'overlay'
        $a = & $prop $o 'autoStart'
        $auto = if ($null -ne $a) { [bool]$a } else { $win }
        if ($auto -and -not (Test-ChatqLockHeld $p.OverlayLock)) {
            # Test-ChatOverlayClosedByHand's test, a state that will not read
            # being no close, as it is there
            $st = $null
            if ([System.IO.File]::Exists($p.OverlayState)) { try { $st = & $json $p.OverlayState } catch {} }
            $was = & $prop $st 'closedSignIn'
            if ($null -eq $was) { return $true }
            $now = if ($win) { Get-ChatShellSignInAt }
            if (-not $now) { return $true }
            try { if ([Math]::Abs([int64]$now - [int64]$was) -lt 2000) { return $false } } catch {}
            return $true
        }
    }
    return $false
}

function Get-ChatShellScope {
    <#
    How Import-ChatTool loads the tool into the global scope from inside a
    function - a key handler, a completer or a stand-in: the session state's
    current scope, which PowerShell's public API only ever gives a child of.
    Not public, so asked for by name: $null where this PowerShell has no such
    members, and Enter-ChatShell then lets the profile load the tool whole,
    as it did before. Windows PowerShell 5.1 and PowerShell 7 both have them.
    #>
    try {
        $nf = [System.Reflection.BindingFlags]'NonPublic,Instance'
        $ip = [System.Management.Automation.SessionState].GetProperty('Internal', $nf)
        if (-not $ip) { return $null }
        $ssi = $ip.GetValue($ExecutionContext.SessionState)
        $cur = $ssi.GetType().GetProperty('CurrentScope', $nf)
        $glob = $ssi.GetType().GetProperty('GlobalScope', $nf)
        if (-not ($cur -and $cur.CanWrite -and $glob)) { return $null }
        return @{ Ssi = $ssi; Current = $cur; Global = $glob.GetValue($ssi) }
    }
    catch { return $null }
}

function Test-ChatShellStub {
    # still the stand-ins, not the tool: chatq names Invoke-ChatShellStub
    # only while it is one
    [bool]((Get-Command chatq -CommandType Function -EA SilentlyContinue).Definition -match 'Invoke-ChatShellStub')
}

function Import-ChatTool {
    <#
    The whole tool, the first time a lazy shell needs it. $true once it is
    here; $false where it could not be loaded, after saying why.
    Dot-sourced into the global scope, where a profile's dot-source would
    have put it, from whichever function asked: every part's $script: state
    and functions land where they would have, and see each other as they
    would have. Between the scope's swap and its swap back nothing of this
    function's own is in reach, so what it needs is in $global:ChatShellLoad.
    What this shell set before the load and the load sets again is kept: the
    arrows' old bindings, which the load does not record again since this
    shell's handlers stay bound (Register-ChatKeyHandlers), and the ghost
    watch the shell started.
    The script is the one on disk now, not as the shell opened: an update
    since then loads whole, this part with it, over the stand-ins. One caught
    part way through its copy says it did not load.
    #>
    Set-StrictMode -Off
    if (-not $global:ChatShellLazy) { return $true }
    # loaded meanwhile by hand, the script dot-sourced at the prompt
    if (-not (Test-ChatShellStub)) { $global:ChatShellLazy = $false; return $true }
    # asked again from inside the load itself
    if ($global:ChatShellLoad) { return $false }
    $s = Get-ChatShellScope
    if (-not $s) { return $false }
    $global:ChatShellLoad = @{ Scope = $s; Was = $s.Current.GetValue($s.Ssi); Path = $global:ChatScriptPath
        Arrows = $global:ChatArrowWas; Ghost = $global:ChatGhostWatcher
    }
    try {
        $s.Current.SetValue($s.Ssi, $s.Global)
        try { . $global:ChatShellLoad.Path }
        finally { $global:ChatShellLoad.Scope.Current.SetValue($global:ChatShellLoad.Scope.Ssi, $global:ChatShellLoad.Was) }
        $global:ChatArrowWas = $global:ChatShellLoad.Arrows
        if (-not $global:ChatGhostWatcher) { $global:ChatGhostWatcher = $global:ChatShellLoad.Ghost }
    }
    catch { Write-Host "  Charlie-and-the-chat-factory did not load: $($_.Exception.Message)" -ForegroundColor Yellow }
    finally { Remove-Variable -Name ChatShellLoad -Scope Global -EA SilentlyContinue }
    if (Test-ChatShellStub) { return $false }
    $global:ChatShellLazy = $false
    return $true
}

function Invoke-ChatShellStub {
    # a stand-in's one line: the tool, then the command it stands for, given
    # the same arguments - switches and named values splat through as typed -
    # and the same pipeline input. The names are odd so the command, which
    # sees this scope's variables, finds none it might read by mistake.
    param([string]$ChatStubName, [object[]]$ChatStubArgs, $ChatStubInput, [bool]$ChatStubPiped)
    if (-not (Import-ChatTool)) { return }
    # a load that stopped part way, after chatq but before this command,
    # leaves this a stand-in still, which would only call itself again
    if ((Get-Command $ChatStubName -CommandType Function -EA SilentlyContinue).Definition -like "*Invoke-ChatShellStub '$ChatStubName'*") {
        Write-Host "  Charlie-and-the-chat-factory did not load $ChatStubName" -ForegroundColor Yellow
        return
    }
    # @args hands -Switch:$false on as the switch, then $false as an argument
    # of its own, which binds to the next position: each -Name: and its value
    # go in a table instead. What marks -Name as a parameter's name rides on
    # the element itself, a wrapper a quoted '-Name:' has not, and any copy
    # that passes through a method call, a pipeline or an if's output drops
    # it - so the rest is cut from the array by index and only ever assigned.
    $ChatStubNamed = @{}
    $ChatStubKeep = [System.Collections.Generic.List[int]]::new()
    for ($ChatStubI = 0; $ChatStubI -lt $ChatStubArgs.Count; $ChatStubI++) {
        $ChatStubM = if ($ChatStubArgs.GetValue($ChatStubI) -is [psobject] -and $ChatStubArgs[$ChatStubI] -is [string] -and $ChatStubI + 1 -lt $ChatStubArgs.Count) {
            [regex]::Match($ChatStubArgs[$ChatStubI], '^-([A-Za-z_][\w-]*):$') }
        if ($ChatStubM -and $ChatStubM.Success) { $ChatStubNamed[$ChatStubM.Groups[1].Value] = $ChatStubArgs[++$ChatStubI] }
        else { $ChatStubKeep.Add($ChatStubI) }
    }
    $ChatStubRest = $ChatStubArgs
    if ($ChatStubNamed.Count) {
        if ($ChatStubKeep.Count) { $ChatStubRest = $ChatStubArgs[$ChatStubKeep.ToArray()] }
        else { $ChatStubRest = @() }
    }
    if ($ChatStubPiped) { $ChatStubInput | & $ChatStubName @ChatStubRest @ChatStubNamed }
    else { & $ChatStubName @ChatStubRest @ChatStubNamed }
}

# Deferred: DEFERRED.md "A lazy shell's parameter names before the first use"
# Deferred: DEFERRED.md "The tool's own functions before a lazy shell's first use"
function Enter-ChatShell {
    <#
    A profile's load (see the script's own comment for when): the stand-ins,
    the aliases, a completer that loads the tool, the key handlers, the
    ghost watch, and the shell-start duties if any has something to do. The
    tool itself loads on first use. $false, having done nothing, where this
    PowerShell could not load it later (Get-ChatShellScope): the profile then
    loads it whole. Run again - the profile dot-sourced twice - it puts the
    same things back and leaves the keys as they are.
    #>
    Set-StrictMode -Off
    if (-not (Get-ChatShellScope)) { return $false }
    $again = [bool]$global:ChatShellLazy
    $global:ChatShellLazy = $true
    # what core.ps1 sets for the ghost watch and the keys, as it sets them;
    # the self-test holds them to its own
    $script:ChatClaudeHome = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { [System.IO.Path]::Combine($HOME, '.claude') }
    $script:ChatTombPath = (Get-ChatShellPaths).Tomb
    $script:ChatNoGhostWatch = $false
    if (-not $again) {
        $script:ChatGhostWatcher = $null
        $script:ChatArrowWas = @{}
    }

    # A stand-in for each command, written out so Get-Help has its own
    # words for it until the tool's help replaces them
    $text = foreach ($n in $script:ChatShellCommands) {
        @"
function global:$n {
    <#
    .SYNOPSIS
    Charlie-and-the-chat-factory's $n. The tool loads the first time one of its commands runs - run it, or type chat, and Get-Help $n has its full help.
    #>
    Invoke-ChatShellStub '$n' `$args `$input `$MyInvocation.ExpectingInput
}
"@
    }
    . ([scriptblock]::Create($text -join "`n"))
    Set-ChatShellAliases
    # the aliases' names read off the lines that set them, not Get-Alias:
    # listing every alias costs twice what the stand-ins do
    $names = @($script:ChatShellCommands) + @([regex]::Matches(${function:Set-ChatShellAliases}.ToString(), '(?m)^\s*Set-Alias -Name (\S+)') | ForEach-Object { $_.Groups[1].Value })
    $script:ChatShellLinePattern = '^\s*(' + (@($names | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')\s'

    # Tab with no key handler of ours - $ChatNoKeyBindings, no PSReadLine,
    # TabExpansion2 asked directly - finds a stand-in with no parameters, and
    # a completer for its arguments is all PowerShell asks: this one loads
    # the tool and asks again, of the real command. Loaded, it answers
    # nothing, and the tool's own completers answer. A parameter's name is
    # PowerShell's own to complete, never a completer's: there, and in
    # Ctrl+Space's menu, a stand-in offers only the common ones until the
    # first use. Tab's own handler loads the tool for it.
    Register-ArgumentCompleter -Native -CommandName $names -ScriptBlock {
        param($word, $ast, $cursor)
        Set-StrictMode -Off
        if (-not $global:ChatShellLazy -or -not (Import-ChatTool)) { return }
        (TabExpansion2 -inputScript $ast.Extent.StartScriptPosition.GetFullScript() -cursorColumn $cursor).CompletionMatches
    }

    if (-not $again) { Register-ChatKeyHandlers }
    if ([System.IO.File]::Exists($script:ChatTombPath)) { Start-ChatGhostWatch }
    # loaded at once only when a duty has something to start
    if ((Test-ChatShellDuty) -and (Import-ChatTool)) { Start-ChatShellDuties }
    return $true
}

#endregion
