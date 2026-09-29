# claude-codex-chat-manager, src/overlay.ps1: dot-sourced by claude-codex-chat-manager.ps1
# in its turn, never on its own - see the list there.

#region overlay: the command ---------------------------------------------------

function Test-ChatOverlayAlive {
    return (Test-ChatqLockHeld $script:ChatOverlayLockPath)
}

function Test-ChatOverlayAutoStart {
    # on a system with a panel to draw, unless chatoverlay -AutoStart off -
    # on by default on Windows (Get-ChatOverlayConfig), so a missing
    # config.json, or one with no such key, reads as on there too. One that
    # is there but does not read is off: it may be the file that says off,
    # and a panel nobody wanted is worse than one not started.
    if (-not $script:ChatqIsWindows -and -not $script:ChatIsMac) { return $false }
    if (Test-Path -LiteralPath $script:ChatqConfigPath) {
        $cfg = Read-ChatqJson $script:ChatqConfigPath
        if ($null -eq $cfg) { return $false }
        return [bool](Get-ChatOverlayConfig $cfg).autoStart
    }
    return [bool](Get-ChatOverlayConfig).autoStart
}

function Start-ChatOverlayAuto {
    <#
    The overlay started if it should be and is not running: what a new shell
    and every VS Code window (the extension, through setup.js) do as they
    open. Prints exactly one line for the caller to read - started, running,
    off (not to start here, or -AutoStart off) or failed - and nothing else,
    so the launch's own words are kept off stdout. Those words say why a
    launch failed, so they go to overlay.log instead: nobody sees a shell's
    start or the extension's call.
    #>
    $say = 'failed'
    $why = $null
    try {
        if (-not (Test-ChatOverlayAutoStart)) { $say = 'off' }
        elseif (Test-ChatOverlayAlive) { $say = 'running' }
        else {
            # Write-Host is the information stream: taken apart from what
            # the launch returns
            $out = @(Start-ChatOverlayProcess 6>&1)
            $said = @($out | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { ([string]$_.MessageData).Trim() } | Where-Object { $_ })
            $ok = @($out | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })
            if ($ok.Count -and $ok[-1] -eq $true) { $say = 'started' }
            else { $why = if ($said.Count) { $said -join ' / ' } else { 'the launch gave no reason' } }
        }
    }
    catch { $say = 'failed'; $why = $_.Exception.Message }
    if ($say -eq 'failed') { Write-ChatOverlayLog "auto-start failed: $why" }
    Write-Output $say
}

function ConvertFrom-ChatOverlayHotkey {
    <#
    'Ctrl+Alt+Shift+O' -> @{ Mods; Vk; Text } for RegisterHotKey, and 'none'
    -> $null. Throws on anything it cannot read, so a typo shows when it is
    set rather than when the overlay next starts.
    #>
    param([string]$Text)
    $t = ([string]$Text).Trim()
    if (-not $t -or $t -eq 'none') { return $null }
    $mods = 0
    $vk = $null
    foreach ($p in @($t -split '\+' | ForEach-Object { $_.Trim() })) {
        if ($p -match '^(ctrl|control)$') { $mods = $mods -bor 2 }
        elseif ($p -eq 'alt') { $mods = $mods -bor 1 }
        elseif ($p -eq 'shift') { $mods = $mods -bor 4 }
        elseif ($p -match '^win(dows)?$') { $mods = $mods -bor 8 }
        elseif ($p -match '^f([1-9]|1[0-9]|2[0-4])$') { $vk = 0x6F + [int]$Matches[1] }
        elseif ($p -match '^[a-z]$') { $vk = [int][char]$p.ToUpperInvariant() }
        elseif ($p -match '^[0-9]$') { $vk = 0x30 + [int]$p }
        else { throw "cannot read '$p' in hotkey '$t' - use e.g. Ctrl+Alt+Shift+O, Ctrl+Win+F9 or none" }
    }
    if ($null -eq $vk) { throw "hotkey '$t' names no key - e.g. Ctrl+Alt+Shift+O" }
    if (-not $mods) { throw "hotkey '$t' needs Ctrl, Alt, Shift or Win with the key" }
    return @{ Mods = $mods; Vk = $vk; Text = $t }
}

function Get-ChatOverlayLaunch {
    <#
    How the overlay process is started: @{ Exe; Args; Command }. On Windows
    always Windows PowerShell with -STA, even from pwsh: WPF needs an STA
    thread, and every Windows has powershell.exe. The command carries the
    environment it needs, and a failure before the log function exists still
    reaches the log. -Open console: the console opens as it starts - a
    command left for it now would be swept away as it takes its lock.
    #>
    param([string]$Path = $script:ChatqScriptPath, [ValidateSet('', 'console')][string]$Open = '')
    $q = { param($s) "'" + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent([string]$s) + "'" }
    $pre = '$env:CHATQ_OVERLAY=''1''; '
    foreach ($n in 'CLAUDE_CONFIG_DIR', 'CODEX_HOME', 'CHATQ_CLAUDE', 'CHATQ_CODEX', 'CHATQ_GH') {
        $v = [Environment]::GetEnvironmentVariable($n)
        if ($v) { $pre += "`$env:$n=$(& $q $v); " }
    }
    $entry = if ($script:ChatqIsWindows) { "Start-ChatOverlayHost$(if ($Open) { " -Open '$Open'" })" } else { 'Start-ChatOverlayMacHost' }
    $log = Join-Path $script:ChatqLogDir 'overlay.log'
    $cmd = $pre + "try { . $(& $q $Path); $entry } catch { try { [void][IO.Directory]::CreateDirectory($(& $q $script:ChatqLogDir)); " +
    "[IO.File]::AppendAllText($(& $q $log), (Get-Date).ToString('o') + '  overlay failed to start: ' + `$_.Exception.Message + [char]10) } catch {} }"
    $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmd))
    if ($script:ChatqIsWindows) {
        $root = if ($env:SystemRoot) { $env:SystemRoot } else { 'C:\Windows' }
        $exe = Join-Path $root 'System32\WindowsPowerShell\v1.0\powershell.exe'
        return [pscustomobject]@{ Exe = $exe; Args = @('-NoProfile', '-NonInteractive', '-STA', '-EncodedCommand', $enc); Command = $cmd }
    }
    return [pscustomobject]@{ Exe = (Get-Process -Id $PID).Path; Args = @('-NoProfile', '-NonInteractive', '-EncodedCommand', $enc); Command = $cmd }
}

function Start-ChatOverlayProcess {
    # just the launch; chatoverlay decides whether one is needed
    param([string]$Open = '')
    if ($script:ChatOverlaySpawn) { return (& $script:ChatOverlaySpawn) }   # tests: no real process
    if (-not $script:ChatqIsWindows -and -not $script:ChatIsMac) { return $false }
    $path = $script:ChatqScriptPath
    if (-not $path -or -not (Test-Path -LiteralPath $path)) {
        Write-Host '  cannot start the overlay: this shell does not know where claude-codex-chat-manager.ps1 is' -ForegroundColor Yellow
        return $false
    }
    $l = Get-ChatOverlayLaunch $path -Open $Open
    try {
        if ($script:ChatqIsWindows) { Start-Process -FilePath $l.Exe -ArgumentList $l.Args -WindowStyle Hidden | Out-Null }
        else {
            New-ChatqDir $script:ChatqLogDir
            Start-Process -FilePath 'nohup' -ArgumentList (@($l.Exe) + $l.Args) `
                -RedirectStandardOutput (Join-Path $script:ChatqLogDir 'overlay.out') `
                -RedirectStandardError (Join-Path $script:ChatqLogDir 'overlay.err') | Out-Null
        }
    }
    catch {
        Write-Host "  cannot start the overlay: $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
    return $true
}

function Stop-ChatOverlay {
    # $true once it has let go of its lock
    if (-not (Test-ChatOverlayAlive)) { return $true }
    Send-ChatOverlayCommand 'stop'
    $until = (Get-Date).AddMilliseconds($script:ChatOverlayStopWaitMs)
    while ((Get-Date) -lt $until) {
        Start-Sleep -Milliseconds 200
        if (-not (Test-ChatOverlayAlive)) { return $true }
    }
    return $false
}

function chatoverlay {
    <#
    .SYNOPSIS
    A small always-on-top panel: usage live at the top, every open Claude chat and the queue beneath. On Windows it starts with every shell and VS Code window unless -AutoStart off.
    .DESCRIPTION
    Each open chat is a row: project, title, its newest prompt, and whether it
    is working (green), waiting on you (amber, at the top), or idle (grey).
    Chats the limit cut off are orange, with when it resets; once it is
    over, the panel says how many it cut off and continues them if you say
    so (chatq -AutoContinue off only marks them). Queued prompts
    are rows too (purple), or ride on their chat's row when it is open. On
    Windows, a chat that finished a turn while you were elsewhere, since
    you last opened it from the overlay, has a small blue dot - not one
    whose window was in front as it finished; macOS has no such dot, as it
    has no open chip to clear it. Under them, on Windows, a faint Recent
    list: the newest chats not open, each openable as a tab like an open
    one. Usage sits at the top, a line for each of Claude, Codex and
    Copilot, each ending with when its figure is from - or as bars with a
    countdown to each reset. Claude's is asked live from its usage endpoint
    every five minutes while a chat works, every fifteen while all are idle,
    and on the refresh button; Copilot's through the GitHub CLI (gh) every
    fifteen; Codex's is what Codex wrote on its last run.

    Clicks go through it and it never takes focus. On Windows the pointer
    brings up its edges, to drag as any window's (the sides for width, the
    top and bottom for rows, the corners for both), and a row of buttons
    over its top-right corner: a grip to drag it by, collapse to
    one line, refresh usage, the console (chatconsole), settings (width, rows,
    opacity, theme, usage as lines or bars, full or compact rows, how many
    recent chats, and whether chats the limit cut off are asked about or
    only marked), hide to the tray -
    the tray dot shows it again - and close. The hotkey (Ctrl+Alt+Shift+O)
    or the tray menu unlocks the whole panel to drag; it locks again by
    itself two minutes after the pointer leaves. Windows and macOS
    (untested); elsewhere -Print shows the same in the console.
    .PARAMETER Stop
    Close it.
    .PARAMETER Unlock
    Take the mouse, to drag it somewhere else. -Lock lets clicks through again.
    .PARAMETER Reset
    Back to the main screen's top-right corner.
    .PARAMETER Collapse
    Down to one line: how many chats wait, work or idle, and usage. -Expand undoes it.
    .PARAMETER Refresh
    Ask Claude's usage endpoint now - unless it said to wait, which the panel shows.
    .PARAMETER Print
    One pass, drawn in this console.
    .PARAMETER AutoStart
    on (the default on Windows): start it with every new shell and every VS Code window, the way the watcher comes back after a reboot. off: only when asked for by name.
    .PARAMETER Hotkey
    The key that unlocks it or shows it: Ctrl+Alt+Shift+O by default, none for no key.
    .PARAMETER LiveUsage
    off: show only Claude Code's own cached usage figure, and never ask the endpoint.
    .PARAMETER Theme
    dark (the default), light, or system - following the OS's own light or dark setting.
    .PARAMETER Opacity
    How opaque the panel is, 0.3 to 1 - or as a percent, 30 to 100.
    .PARAMETER Width
    How wide the panel is, 260 to 800 (380 by default) - in pixels at 100% scaling.
    .PARAMETER Rows
    How many chat rows it shows at most, 1 to 30 (8 by default); the rest are counted on a line of their own.
    .PARAMETER Compact
    on: one line a chat, without its newest prompt under it. off (the default): the prompt line too.
    .PARAMETER ChipDelay
    How long the pointer rests on a chat's row before its open chip comes, in milliseconds: 100 to 3000, 400 by default.
    .PARAMETER Recent
    How many of the newest chats not open are listed under the open ones: 0 to 20, 5 by default; 0 is no Recent list.
    .PARAMETER Console
    Open the console: pick a chat, write to it, drop files on it, send now or queue; the queue beside it. It opens in the panel's own place, grown from its top-right corner; Esc, its back button or the console hotkey return it to the panel. Starts the overlay if it is not running. Windows only.
    .PARAMETER ConsoleHotkey
    The key that opens the console: Ctrl+Alt+Shift+Q by default, none for no key.
    .PARAMETER UsageView
    lines (the default): usage as one line a provider. bars: a bar and a reset countdown per window.
    .PARAMETER CopilotUsage
    off: no Copilot line, and gh is never run for it.
    .EXAMPLE
    chatoverlay
    .EXAMPLE
    chatoverlay -AutoStart off
    .EXAMPLE
    chatoverlay -Theme system -Opacity 85
    .EXAMPLE
    chatoverlay -Width 460 -Rows 12
    .EXAMPLE
    chatoverlay -Compact on -ChipDelay 250
    .EXAMPLE
    chatoverlay -Recent 10
    #>
    [CmdletBinding()]
    param(
        [switch]$Stop, [switch]$Unlock, [switch]$Lock, [switch]$Reset, [switch]$Print,
        [switch]$Collapse, [switch]$Expand, [switch]$Refresh, [switch]$Console,
        [ValidateSet('on', 'off')][string]$AutoStart,
        [string]$Hotkey,
        [string]$ConsoleHotkey,
        [ValidateSet('on', 'off')][string]$LiveUsage,
        [ValidateSet('dark', 'light', 'system')][string]$Theme,
        [double]$Opacity,
        [int]$Width,
        [int]$Rows,
        [ValidateSet('on', 'off')][string]$Compact,
        [int]$ChipDelay,
        [int]$Recent,
        [ValidateSet('lines', 'bars')][string]$UsageView,
        [ValidateSet('on', 'off')][string]$CopilotUsage
    )
    Set-StrictMode -Off
    if ($Print) { Write-ChatOverlayPrint; return }
    $alive = Test-ChatOverlayAlive
    if ($Stop) {
        if (-not $alive) { Write-Host '  the overlay is not running' -ForegroundColor DarkGray; return }
        if (Stop-ChatOverlay) { Write-Host '  overlay closed' -ForegroundColor DarkGray }
        else { Write-Host '  asked the overlay to close - it has not yet; data/logs/overlay.log may say why' -ForegroundColor Yellow }
        return
    }
    $set = @{}
    if ($AutoStart) { $set.autoStart = ($AutoStart -eq 'on') }
    if ($LiveUsage) { $set.liveUsage = ($LiveUsage -eq 'on') }
    if ($Theme) { $set.theme = $Theme.ToLowerInvariant() }
    if ($UsageView) { $set.usageView = $UsageView.ToLowerInvariant() }
    if ($CopilotUsage) { $set.copilotUsage = ($CopilotUsage -eq 'on') }
    # compact is the prompt line turned off: the one setting both ways
    if ($Compact) { $set.prompts = ($Compact -eq 'off') }
    if ($PSBoundParameters.ContainsKey('Opacity')) {
        $o = if ($Opacity -gt 1) { $Opacity / 100 } else { $Opacity }
        if ($o -lt 0.3 -or $o -gt 1) { Write-Host '  -Opacity takes 0.3 to 1, or 30 to 100 as a percent' -ForegroundColor Yellow; return }
        $set.opacity = [Math]::Round($o, 2)
    }
    # refused out of range rather than held to it, as -Opacity is: a typo
    # shows now, not as a panel of some other size
    if ($PSBoundParameters.ContainsKey('Width')) {
        if ($Width -lt 260 -or $Width -gt 800) { Write-Host '  -Width takes 260 to 800' -ForegroundColor Yellow; return }
        $set.width = $Width
    }
    if ($PSBoundParameters.ContainsKey('Rows')) {
        if ($Rows -lt 1 -or $Rows -gt 30) { Write-Host '  -Rows takes 1 to 30' -ForegroundColor Yellow; return }
        $set.maxRows = $Rows
    }
    if ($PSBoundParameters.ContainsKey('ChipDelay')) {
        if ($ChipDelay -lt 100 -or $ChipDelay -gt 3000) { Write-Host '  -ChipDelay takes 100 to 3000 milliseconds' -ForegroundColor Yellow; return }
        $set.chipDelayMs = $ChipDelay
    }
    if ($PSBoundParameters.ContainsKey('Recent')) {
        if ($Recent -lt 0 -or $Recent -gt 20) { Write-Host '  -Recent takes 0 to 20 - 0 for none' -ForegroundColor Yellow; return }
        $set.recent = $Recent
    }
    if ($PSBoundParameters.ContainsKey('Hotkey')) {
        try { $k = ConvertFrom-ChatOverlayHotkey $Hotkey }
        catch { Write-Host "  $($_.Exception.Message)" -ForegroundColor Yellow; return }
        $set.hotkey = if ($k) { $k.Text } else { 'none' }
    }
    if ($PSBoundParameters.ContainsKey('ConsoleHotkey')) {
        try { $k = ConvertFrom-ChatOverlayHotkey $ConsoleHotkey }
        catch { Write-Host "  $($_.Exception.Message)" -ForegroundColor Yellow; return }
        $set.consoleHotkey = if ($k) { $k.Text } else { 'none' }
    }
    if ($set.Count) {
        Set-ChatOverlayConfig $set
        if ($set.ContainsKey('autoStart')) { Write-Host "  start with every shell and VS Code window: $AutoStart" -ForegroundColor Green }
        if ($set.ContainsKey('liveUsage')) { Write-Host "  live usage: $LiveUsage" -ForegroundColor Green }
        if ($set.ContainsKey('hotkey')) { Write-Host "  hotkey: $($set.hotkey)" -ForegroundColor Green }
        if ($set.ContainsKey('consoleHotkey')) { Write-Host "  console hotkey: $($set.consoleHotkey)" -ForegroundColor Green }
        if ($set.ContainsKey('theme')) { Write-Host "  theme: $($set.theme)" -ForegroundColor Green }
        if ($set.ContainsKey('opacity')) { Write-Host "  opacity: $([int]($set.opacity * 100))%" -ForegroundColor Green }
        if ($set.ContainsKey('width')) { Write-Host "  width: $($set.width)" -ForegroundColor Green }
        if ($set.ContainsKey('maxRows')) { Write-Host "  rows: $($set.maxRows) at most" -ForegroundColor Green }
        if ($set.ContainsKey('prompts')) { Write-Host "  compact rows: $Compact$(if ($Compact -eq 'on') { ' - one line a chat' } else { ' - each with its newest prompt' })" -ForegroundColor Green }
        if ($set.ContainsKey('chipDelayMs')) { Write-Host "  open chip: after a $($set.chipDelayMs) ms rest on a row" -ForegroundColor Green }
        if ($set.ContainsKey('recent')) { Write-Host "  recent chats: $(if ($set.recent) { "the newest $($set.recent) not open, under the open ones" } else { 'off' })" -ForegroundColor Green }
        if ($set.ContainsKey('usageView')) { Write-Host "  usage as $($set.usageView)" -ForegroundColor Green }
        if ($set.ContainsKey('copilotUsage')) { Write-Host "  Copilot usage: $CopilotUsage$(if ($CopilotUsage -eq 'on') { ' - through the GitHub CLI, gh, when it is logged in' })" -ForegroundColor Green }
        if ($alive) { Send-ChatOverlayCommand 'reload' }
    }
    $verbs = @()
    if ($Unlock) { $verbs += 'unlock' }
    if ($Lock) { $verbs += 'lock' }
    if ($Reset) { $verbs += 'reset' }
    if ($Collapse) { $verbs += 'collapse' }
    if ($Expand) { $verbs += 'expand' }
    if ($verbs) {
        if ($alive) { foreach ($v in $verbs) { Send-ChatOverlayCommand $v } }
        else {
            # not running: left the way the next start will read it
            $st = Read-ChatOverlayState
            if ($Unlock) { $st.locked = $false }
            if ($Lock) { $st.locked = $true }
            if ($Reset) { $st.x = $null; $st.y = $null }
            if ($Collapse) { $st.collapsed = $true }
            if ($Expand) { $st.collapsed = $false }
            Save-ChatOverlayState $st
        }
        Write-Host "  $($verbs -join ', ')$(if (-not $alive) { ' - applies when it next starts' })" -ForegroundColor DarkGray
    }
    if ($Refresh) {
        # a wait the endpoint named: said here, not asked through
        $snapNow = Read-ChatqJson $script:ChatOverlayPath
        $held = if ($snapNow -and $snapNow.PSObject.Properties['header'] -and $snapNow.header.PSObject.Properties['liveHold'] -and $snapNow.header.liveHold) { [int64]$snapNow.header.liveHold } else { 0 }
        if ($held -gt [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) {
            $until = [DateTimeOffset]::FromUnixTimeMilliseconds($held).LocalDateTime.ToString('HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
            Write-Host "  Claude's usage endpoint asked to wait until $until - asking earlier only gets refused again" -ForegroundColor Yellow
        }
        elseif ($alive) { Send-ChatOverlayCommand 'refresh'; Write-Host "  asked Claude for usage now - it shows within a few seconds. Codex's moves only when Codex runs." -ForegroundColor DarkGray }
        else { Write-Host '  the overlay is not running - chatoverlay -Print asks once' -ForegroundColor DarkGray }
    }
    if ($Console) {
        if (-not $script:ChatqIsWindows) { Write-Host '  the console is Windows only for now - chatq, chatqlist and chatqrm do the same from a shell' -ForegroundColor Yellow; return }
        # Windows gives the focus to what the user started; a running overlay
        # only told to open it may just flash its taskbar button
        if ($alive) { Send-ChatOverlayCommand 'console'; Write-Host '  the console opens in the panel''s place - its taskbar button, if it stays behind; Esc returns the panel' -ForegroundColor DarkGray }
        elseif (Start-ChatOverlayProcess -Open 'console') { Write-Host '  starting the overlay with its console - a few seconds; Esc returns the panel' -ForegroundColor DarkGray }
        return
    }
    if ($set.Count -or $verbs -or $Refresh) { return }

    if (-not $script:ChatqIsWindows -and -not $script:ChatIsMac) {
        Write-Host '  the panel is Windows and macOS only - chatoverlay -Print shows the same here' -ForegroundColor Yellow
        return
    }
    if ($alive) {
        Send-ChatOverlayCommand 'show'
        Write-Host '  the overlay is running - shown' -ForegroundColor DarkGray
    }
    else {
        # asked for by name: shown, even if it was hidden when it last closed
        $st = Read-ChatOverlayState
        if ($st.hidden) { $st.hidden = $false; Save-ChatOverlayState $st }
        if (-not (Start-ChatOverlayProcess)) { return }
        $up = $false
        for ($i = 0; $i -lt 40 -and -not $up; $i++) { Start-Sleep -Milliseconds 250; $up = Test-ChatOverlayAlive }
        if (-not $up) {
            Write-Host '  the overlay did not start - data/logs/overlay.log may say why' -ForegroundColor Yellow
            return
        }
        Write-Host '  overlay started - top right of the main screen' -ForegroundColor Green
        if ($script:ChatIsMac) { Write-Host '  macOS support is untested - TESTING.md lists what to check' -ForegroundColor DarkGray }
    }
    if ($script:ChatqIsWindows) { Write-Host '  clicks go through it - point at it for its edges, to resize it, and its buttons: move, collapse, refresh, console, settings, hide, close' -ForegroundColor DarkGray }
    else { Write-Host '  clicks go through it - the CQ menu bar item unlocks it to drag' -ForegroundColor DarkGray }
    # what comes back by itself, as config.json has it now
    if ((Get-ChatOverlayConfig).autoStart) {
        Write-Host "  chatoverlay -Stop closes it $($script:ChatqDot) it starts again with every shell and VS Code window unless -AutoStart off" -ForegroundColor DarkGray
    }
    else { Write-Host "  chatoverlay -Stop closes it $($script:ChatqDot) -AutoStart on brings it back with every shell and VS Code window" -ForegroundColor DarkGray }
}

function chatconsole {
    <#
    .SYNOPSIS
    chatq in a window: pick a chat, write to it, drop files on it, send now or queue it.
    .DESCRIPTION
    The chats cut off by the limit (Continue, or Continue all), the ones open
    in VS Code, and the recent ones, with a search; + New chat starts one in
    a folder. Send now runs the prompt within seconds - once the chat is idle
    if it is working in VS Code - and In turn, At or In queue it. The queue
    sits below: each job's outcome and log, Try now, First, Remove, Cancel,
    Requeue. It is the overlay's own window: the panel grows into it from
    its top-right corner, and Esc, the back button in its header or
    Ctrl+Alt+Shift+Q again return it to the panel, where and as it was. So
    this starts the overlay if it is not running. Windows only.
    Ctrl+Alt+Shift+Q, the overlay's speech-bubble button and the tray menu
    open it too.
    #>
    Set-StrictMode -Off
    chatoverlay -Console
}

#endregion
