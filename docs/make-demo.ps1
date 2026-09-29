<#
Renders the README's frames:

    docs/demo-queue.svg, docs/demo-list.svg        chatq and chatqlist
    docs/demo-overlay.png                          chatoverlay's panel
    docs/demo-1-type.svg ... docs/demo-4-reloaded.svg   the chatrm walk-through
    docs/demo-2-tab.png, demo-queue.png, demo-list.png  the same, for the Marketplace

    powershell -NoProfile -ExecutionPolicy Bypass -File docs\make-demo.ps1

The terminal is the real thing - the real commands, run against a made-up
sandbox of chats (so no real title is ever drawn) - captured by a Write-Host of
our own. Defined here, it wins over the cmdlet for the dot-sourced script, and
records each line's text and colours; the frames are drawn from that. No
window, no screen capture, nothing taken from the console.

The VS Code panel beside the chatrm frames is a sketch, not a capture: the
sandbox's Claude chats as the index lists them, drawn the way the panel's
session list shows them.

The overlay frame is the real WPF panel, rendered off screen from what the
real collector reads: a made-up registry of open chats, the queue the frames
above left, and a stand-in usage endpoint answering what the made-up cache
says. Windows PowerShell only - WPF needs it.

This file is ASCII, like the script it drives.
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$sb = Join-Path $root 'tests\.sandbox\demo'
if (Test-Path -LiteralPath $sb) { Remove-Item -LiteralPath $sb -Recurse -Force }
$utf8 = New-Object System.Text.UTF8Encoding $false

# --- a sandbox of chats that never existed ---------------------------------
$claudeHome = Join-Path $sb 'claude'
$codexHome = Join-Path $sb 'codex'
$proj = Join-Path $sb 'work\parser'
foreach ($d in $claudeHome, $codexHome, $proj, (Join-Path $sb 'tool'), (Join-Path $sb 'code-user')) { $null = New-Item -ItemType Directory -Path $d -Force }
Copy-Item -LiteralPath (Join-Path $root 'Charlie-and-the-chat-factory.ps1') -Destination (Join-Path $sb 'tool')
Copy-Item -LiteralPath (Join-Path $root 'src') -Destination (Join-Path $sb 'tool') -Recurse
$env:CLAUDE_CONFIG_DIR = $claudeHome
$env:CODEX_HOME = $codexHome
$env:CHAT_CODE_USER = Join-Path $sb 'code-user'
$env:CHATQ_CLAUDE = Join-Path $root 'tests\fake-claude.cmd'
$env:CHATQ_CODEX = $env:CHATQ_CLAUDE
$env:CHATQ_WATCHER = '1'
# gh's login is this machine's: never asked, whatever the sandbox
$env:CHATQ_GH = Join-Path $sb 'no-such-gh.exe'

$now = [DateTimeOffset]::UtcNow
$reset = $now.AddMinutes(95)
$slug = $proj.TrimEnd('\') -replace '[^A-Za-z0-9]', '-'
$pdir = Join-Path (Join-Path $claudeHome 'projects') $slug
$null = New-Item -ItemType Directory -Path $pdir -Force
function New-DemoChat([string]$Id, [string]$Title, [double]$HoursAgo, [string]$Prompt, [switch]$CutOff) {
    $t = $now.AddHours(-$HoursAgo)
    $lines = @(
        ([ordered]@{ type = 'user'; message = [ordered]@{ role = 'user'; content = $Prompt }; timestamp = $t.ToString('o'); permissionMode = 'auto'; cwd = $proj; sessionId = $Id } | ConvertTo-Json -Compress -Depth 5)
        ([ordered]@{ type = 'assistant'; message = [ordered]@{ model = 'claude-opus-5'; role = 'assistant'; content = @([ordered]@{ type = 'text'; text = 'On it.' }) }; timestamp = $t.ToString('o'); cwd = $proj; sessionId = $Id } | ConvertTo-Json -Compress -Depth 6)
        ([ordered]@{ type = 'ai-title'; aiTitle = $Title; sessionId = $Id } | ConvertTo-Json -Compress)
    )
    if ($CutOff) {
        $lines += ([ordered]@{ type = 'assistant'; timestamp = $t.ToString('o'); cwd = $proj; sessionId = $Id
                message = [ordered]@{ model = '<synthetic>'; role = 'assistant'; content = @([ordered]@{ type = 'text'; text = "You've hit your session limit" }) }
                quotaLimits = [ordered]@{ status = 'rejected'; resetsAt = $reset.ToUnixTimeSeconds(); rateLimitType = 'five_hour' }
                error = 'rate_limit'; isApiErrorMessage = $true } | ConvertTo-Json -Compress -Depth 6)
    }
    $p = Join-Path $pdir "$Id.jsonl"
    [System.IO.File]::WriteAllText($p, ($lines -join "`n") + "`n", $utf8)
    (Get-Item -LiteralPath $p).LastWriteTime = $t.LocalDateTime
}
New-DemoChat '1a2b3c4d-0000-4000-8000-000000000001' 'Parser rewrite and plugin unification' 0.4 'unify the parser entry points' -CutOff
New-DemoChat '1a2b3c4d-0000-4000-8000-000000000002' 'Card layout redesign' 1.2 'redesign the card layout' -CutOff
New-DemoChat '1a2b3c4d-0000-4000-8000-000000000003' 'Release notes for 2.4' 2.5 'draft the release notes'
New-DemoChat '1a2b3c4d-0000-4000-8000-000000000004' 'Flaky upload test' 30 'why does the upload test flake'
[System.IO.File]::WriteAllText((Join-Path $claudeHome '.claude.json'),
    ('{"cachedUsageUtilization":{"fetchedAtMs":' + $now.AddMinutes(-4).ToUnixTimeMilliseconds() + ',"utilization":{"limits":[' +
        '{"kind":"session","percent":100,"resets_at":"' + $reset.ToString('o') + '","scope":null},' +
        '{"kind":"weekly_all","percent":46,"resets_at":"' + $now.AddDays(4).ToString('o') + '","scope":null}]}}}'), $utf8)

. (Join-Path $sb 'tool\Charlie-and-the-chat-factory.ps1')
Set-Location -LiteralPath $proj
$script:ChatqToastSeam = { param($t, $x) }
$script:ChatqSpawn = { $true }
function Get-ChatqWidth { 92 }            # a fixed width, whatever this console is
# The sandbox's config dir is part of the lane's name, since a job remembers
# which account it was queued from - here that would only be a temp path.
function Format-ChatqLane { param([string]$Lane) (Get-Culture).TextInfo.ToTitleCase([string](($Lane -split '\|', 2)[0])) }
# PSReadLine's default colours, whatever theme the shell running this has
$e = [char]27
$script:ChatColors = @{ Command = "$e[93m"; String = "$e[36m"; Param = "$e[90m"; Comment = "$e[32m"; Reset = "$e[0m" }

# --- recording ---------------------------------------------------------------
$script:Lines = [System.Collections.Generic.List[object]]::new()
$script:Cur = [System.Collections.Generic.List[object]]::new()
# the walk row carries its colours as escapes, the ones above, not as
# -ForegroundColor
$sgr = @{ '93' = 'Yellow'; '36' = 'DarkCyan'; '90' = 'DarkGray'; '32' = 'DarkGreen' }
function Write-Host {
    param([Parameter(Position = 0, ValueFromRemainingArguments)]$Object, [switch]$NoNewline,
        $ForegroundColor, $BackgroundColor, $Separator = ' ')
    $text = (@($Object) | ForEach-Object { [string]$_ }) -join $Separator
    $color = [string]$ForegroundColor
    foreach ($piece in [regex]::Split($text, '(\x1b\[[0-9;?]*[A-Za-z])')) {
        if ($piece -match '^\x1b\[([0-9;]*)m$') {
            $color = if ($sgr.ContainsKey($Matches[1])) { $sgr[$Matches[1]] } else { [string]$ForegroundColor }
        }
        elseif ($piece -notmatch '^\x1b') { $script:Cur.Add([pscustomobject]@{ Text = $piece; Color = $color }) }
    }
    if (-not $NoNewline) { $script:Lines.Add(@($script:Cur)); $script:Cur = [System.Collections.Generic.List[object]]::new() }
}
function Get-DemoTyped([string]$Line) {
    # the line as PSReadLine paints it - command, strings, parameters - and the
    # age-and-counter tail Tab adds, in the colour the walk row gives it
    $segs = [System.Collections.Generic.List[object]]::new()
    $segs.Add([pscustomobject]@{ Text = 'PS> '; Color = 'DarkGray' })
    $tail = [regex]::Match($Line, $script:ChatTailPattern)
    $body = if ($tail.Success) { $Line.Substring(0, $tail.Index) } else { $Line }
    $first = $true
    foreach ($m in [regex]::Matches($body, "'(?:[^']|'')*'?|\s+|[^\s']+")) {
        $t = $m.Value
        $color = if ($t -match '^\s') { '' } elseif ($first) { 'Yellow' } elseif ($t[0] -eq "'") { 'DarkCyan' } elseif ($t -match '^-[A-Za-z]') { 'DarkGray' } else { '' }
        if ($t -notmatch '^\s') { $first = $false }
        $segs.Add([pscustomobject]@{ Text = $t; Color = $color })
    }
    if ($tail.Success) { $segs.Add([pscustomobject]@{ Text = $tail.Value; Color = 'DarkGreen' }) }
    return , $segs.ToArray()
}
function Add-DemoCursor([object[]]$Line, [int]$Col) {
    # a block where the cursor stands: a glyph in the text rather than a shape
    # drawn over it, so it keeps its cell in whichever monospace font renders
    $block = [string][char]0x2588
    $out = [System.Collections.Generic.List[object]]::new()
    $at = 0
    $done = $false
    foreach ($s in $Line) {
        $t = [string]$s.Text
        if (-not $done -and $Col -ge $at -and $Col -lt $at + $t.Length) {
            $i = $Col - $at
            if ($i) { $out.Add([pscustomobject]@{ Text = $t.Substring(0, $i); Color = $s.Color }) }
            $out.Add([pscustomobject]@{ Text = $block; Color = 'Cursor' })
            if ($i + 1 -lt $t.Length) { $out.Add([pscustomobject]@{ Text = $t.Substring($i + 1); Color = $s.Color }) }
            $done = $true
        }
        else { $out.Add($s) }
        $at += $t.Length
    }
    if (-not $done) { $out.Add([pscustomobject]@{ Text = $block; Color = 'Cursor' }) }
    return , $out.ToArray()
}
function Invoke-Frame([string]$Typed, [scriptblock]$Run) {
    $script:Lines.Clear()
    $script:Lines.Add((Get-DemoTyped $Typed))
    & $Run
    # one line is still a frame of lines, not a line of segments
    return , @($script:Lines)
}

# --- drawing -----------------------------------------------------------------
$palette = @{
    '' = '#d4d4d4'; 'Gray' = '#d4d4d4'; 'White' = '#ffffff'; 'DarkGray' = '#8a8a8a'; 'Cyan' = '#4fc1ff'; 'Green' = '#6ccb5f'
    'Yellow' = '#e5c07b'; 'Red' = '#f14c4c'; 'Magenta' = '#c678dd'; 'Blue' = '#61afef'
    'DarkCyan' = '#56b6c2'; 'DarkGreen' = '#6a9955'; 'Cursor' = '#aeafad'
}
function ConvertTo-DemoSvg {
    # -Cols and -Rows hold a series of frames to one size. -Key draws a key cap
    # under -Cursor (row, column). -Panel draws the session list beside the
    # terminal, or alone when there is no terminal frame; -PanelRows keeps the
    # room of rows a list had before one went.
    param([object[]]$Frame, [string]$Path, [string]$Caption, [int]$Cols, [int]$Rows,
        [int[]]$Cursor, [string]$Key, [object[]]$Panel, [int]$PanelRows)
    $lh = 19; $pad = 16; $top = 38
    $Frame = @($Frame)
    if (-not $Cols) { foreach ($l in $Frame) { $n = (@($l) | ForEach-Object { $_.Text }) -join ''; if ($n.Length -gt $Cols) { $Cols = $n.Length } } }
    if (-not $Rows) { $Rows = $Frame.Count }
    $hasPanel = $PSBoundParameters.ContainsKey('Panel')
    $Panel = @($Panel)
    if (-not $PanelRows) { $PanelRows = $Panel.Count }
    $tw = if ($Frame.Count) { [int]([Math]::Max(640, $Cols * 8.4 + 2 * $pad)) } else { 0 }
    $th = if ($Frame.Count) { $top + $Rows * $lh + $pad } else { 0 }
    $pw = 350
    # alone, the panel sits under the window's buttons rather than beside them
    $py = if ($Frame.Count) { 0 } else { 28 }
    $ph = if ($hasPanel) { $py + 76 + $PanelRows * 28 + 12 } else { 0 }
    $w = $tw + $(if ($hasPanel) { $pw } else { 0 })
    $h = [Math]::Max($th, $ph)
    # anything past ASCII as a character reference, so the file is ASCII too
    # and no reader has to guess its encoding - Windows PowerShell's default
    # read of BOM-less UTF-8 broke the cursor glyph and the XML with it
    $x = { param($s)
        [regex]::Replace([System.Security.SecurityElement]::Escape([string]$s), '[\uD800-\uDBFF][\uDC00-\uDFFF]|[^\x00-\x7F]',
            { param($m) '&#x{0:X};' -f [char]::ConvertToUtf32($m.Value, 0) })
    }
    $sans = 'Segoe UI, -apple-system, BlinkMacSystemFont, Helvetica, Arial, sans-serif'
    $b = [System.Text.StringBuilder]::new()
    [void]$b.AppendLine("<svg xmlns=`"http://www.w3.org/2000/svg`" width=`"$w`" height=`"$h`" viewBox=`"0 0 $w $h`" role=`"img`" aria-label=`"$(& $x $Caption)`">")
    if (-not $hasPanel) {
        [void]$b.AppendLine("<rect width=`"$w`" height=`"$h`" rx=`"8`" fill=`"#1e1e1e`"/>")
    }
    else {
        # the panel's own ground, clipped to the window's rounded corners
        [void]$b.AppendLine("<defs><clipPath id=`"win`"><rect width=`"$w`" height=`"$h`" rx=`"8`"/></clipPath></defs>")
        [void]$b.AppendLine("<g clip-path=`"url(#win)`"><rect width=`"$w`" height=`"$h`" fill=`"#1e1e1e`"/>")
        [void]$b.AppendLine("<rect x=`"$tw`" width=`"$pw`" height=`"$h`" fill=`"#252526`"/>")
        if ($tw) { [void]$b.AppendLine("<line x1=`"$tw`" y1=`"0`" x2=`"$tw`" y2=`"$h`" stroke=`"#3c3c3c`"/>") }
        [void]$b.AppendLine('</g>')
        [void]$b.AppendLine("<g font-family=`"$sans`">")
        $ty = $py + 22
        foreach ($tab in @(@(16, 'CHAT', '#9d9d9d'), @(60, 'CODEX', '#9d9d9d'), @(112, 'CLAUDE CODE', '#e7e7e7'))) {
            [void]$b.AppendLine("<text x=`"$($tw + $tab[0])`" y=`"$ty`" font-size=`"11`" letter-spacing=`"0.4`" fill=`"$($tab[2])`">$($tab[1])</text>")
        }
        [void]$b.AppendLine("<rect x=`"$($tw + 112)`" y=`"$($ty + 6)`" width=`"76`" height=`"1.5`" fill=`"#e7e7e7`"/>")
        [void]$b.AppendLine("<rect x=`"$($tw + 12)`" y=`"$($py + 38)`" width=`"$($pw - 24)`" height=`"28`" rx=`"4`" fill=`"#1e1e1e`" stroke=`"#3c3c3c`"/>")
        [void]$b.AppendLine("<text x=`"$($tw + 24)`" y=`"$($py + 56)`" font-size=`"12`" fill=`"#8a8a8a`">Search sessions...</text>")
        for ($i = 0; $i -lt $Panel.Count; $i++) {
            $ry = $py + 76 + $i * 28 + 18
            [void]$b.AppendLine("<text x=`"$($tw + 16)`" y=`"$ry`" font-size=`"13`" fill=`"#cccccc`">$(& $x $Panel[$i].Title)</text>")
            [void]$b.AppendLine("<text x=`"$($tw + $pw - 16)`" y=`"$ry`" font-size=`"12`" text-anchor=`"end`" fill=`"#8a8a8a`">$(& $x $Panel[$i].Age)</text>")
        }
        [void]$b.AppendLine('</g>')
    }
    foreach ($c in @(@(18, '#ff5f57'), @(38, '#febc2e'), @(58, '#28c840'))) { [void]$b.AppendLine("<circle cx=`"$($c[0])`" cy=`"16`" r=`"6`" fill=`"$($c[1])`"/>") }
    if ($Frame.Count) {
        # white-space:pre, not only xml:space - browsers now ignore the attribute,
        # and collapsed spaces undo every column
        [void]$b.AppendLine('<g font-family="Cascadia Mono, Consolas, Menlo, monospace" font-size="14" xml:space="preserve" style="white-space:pre">')
        $y = $top
        foreach ($l in $Frame) {
            [void]$b.Append("<text x=`"$pad`" y=`"$y`">")
            foreach ($s in @($l)) {
                if (-not $s.Text) { continue }
                $fill = if ($palette.ContainsKey($s.Color)) { $palette[$s.Color] } else { $palette[''] }
                # the sandbox is a temp folder; the frame says where a project would be
                $t = $s.Text.Replace($proj, 'D:\src\parser')
                # no-break spaces: they hold the columns in every renderer, where
                # white-space rules on SVG text are honoured by some and not others
                [void]$b.Append("<tspan fill=`"$fill`">$((& $x $t).Replace(' ', '&#160;'))</tspan>")
            }
            [void]$b.AppendLine('</text>')
            $y += $lh
        }
        [void]$b.AppendLine('</g>')
    }
    if ($Key) {
        # just under the cursor; 8.2 px is a Cascadia Mono cell at 14 px, and a
        # narrower font only moves the cap a little left of it
        $kw = [int]([Math]::Max(52, $Key.Length * 8 + 26))
        $kx = [int]($pad + $Cursor[1] * 8.2 - 10)
        $ky = [int]($top + $Cursor[0] * $lh + 14)
        [void]$b.AppendLine("<g transform=`"translate($kx,$ky)`">")
        [void]$b.AppendLine("<rect y=`"3`" width=`"$kw`" height=`"28`" rx=`"5`" fill=`"#2b2d30`"/>")
        [void]$b.AppendLine("<rect width=`"$kw`" height=`"27`" rx=`"5`" fill=`"#45484d`" stroke=`"#6b6e73`"/>")
        [void]$b.AppendLine("<text x=`"$([int]($kw / 2))`" y=`"18`" text-anchor=`"middle`" font-family=`"$sans`" font-size=`"12`" fill=`"#f0f0f0`">$(& $x $Key)</text>")
        [void]$b.AppendLine('</g>')
    }
    [void]$b.AppendLine('</svg>')
    [System.IO.File]::WriteAllText($Path, $b.ToString(), $utf8)
}

# --- the queue frames ----------------------------------------------------------
# the lock held: to chatq that is a running watcher, so it starts none - and
# what that watcher knows is what it would have written: the limit, and when
New-ChatqDir $script:ChatqData
Save-ChatqJson $script:ChatqStatePath ([ordered]@{
        pid = $PID; blocked = @{ "claude|$claudeHome" = @{ until = $reset.UtcDateTime.ToString('o'); type = 'five_hour'; source = 'transcript' } }; outage = @{}
    })
$lock = [System.IO.File]::Open($script:ChatqLockPath, 'OpenOrCreate', 'ReadWrite', 'None')
try {
    $f1 = Invoke-Frame "chatq 'Parser rewrite and plugin unification' -Prompt 'Also update the changelog'" {
        chatq 'Parser rewrite and plugin unification' -Prompt 'Also update the changelog'
    }
    $long = "Assess this new card idea before we build it.`n`n" + (('It should keep the current grid, fold the detail rows away, and still read well on a narrow panel. ') * 12)
    $null = Invoke-Frame 'x' { chatq 'card layout' -Prompt $long }
    $f2 = Invoke-Frame 'chatqlist' { chatqlist }
}
finally { $lock.Dispose() }
ConvertTo-DemoSvg $f1 (Join-Path $here 'demo-queue.svg') 'chatq queueing a prompt for a chat picked by its title'
ConvertTo-DemoSvg $f2 (Join-Path $here 'demo-list.svg') 'chatqlist showing two queued prompts, the usage and the limit reset'

# --- the overlay -----------------------------------------------------------------
# Three of the made-up chats open in a window - one on a permission prompt, one
# working, one idle - and a prompt queued for a fourth that is not open.
$sessDir = Join-Path $claudeHome 'sessions'
$null = New-Item -ItemType Directory -Path $sessDir -Force
$nowMs = $now.ToUnixTimeMilliseconds()
foreach ($o in @(
        @{ Pid = 101; Id = '1a2b3c4d-0000-4000-8000-000000000001'; Status = 'waiting'; Ago = 3; Wait = 'input needed' }
        @{ Pid = 102; Id = '1a2b3c4d-0000-4000-8000-000000000002'; Status = 'busy'; Ago = 1; Wait = $null }
        @{ Pid = 103; Id = '1a2b3c4d-0000-4000-8000-000000000004'; Status = 'idle'; Ago = 40; Wait = $null })) {
    $at = $nowMs - $o.Ago * 60000
    $rec = [ordered]@{ pid = $o.Pid; sessionId = $o.Id; cwd = $proj; startedAt = $nowMs - 7200000; kind = 'interactive'; name = 'parser'; status = $o.Status; updatedAt = $at; statusUpdatedAt = $at }
    if ($o.Wait) { $rec.waitingFor = $o.Wait }
    [System.IO.File]::WriteAllText((Join-Path $sessDir "$($o.Pid).json"), ($rec | ConvertTo-Json -Compress), $utf8)
}
$script:ChatqAliveSeam = { $true }
$script:ChatOverlayUsageSeam = { @{ Ok = $true; Status = 200; Windows = @((Read-ChatqClaudeUsageCache (Join-Path $claudeHome '.claude.json')).Windows) } }
# and a made-up answer from GitHub for Copilot's line
$script:ChatOverlayCopilotSeam = { @{ Ok = $true; Windows = @(
            [pscustomobject]@{ Label = 'chat'; Percent = 18; ResetsAt = $now.AddDays(9).LocalDateTime; Severity = '' }
            [pscustomobject]@{ Label = 'code'; Percent = 4; ResetsAt = $now.AddDays(9).LocalDateTime; Severity = '' }) } }
$lock = [System.IO.File]::Open($script:ChatqLockPath, 'OpenOrCreate', 'ReadWrite', 'None')
try {
    chatq 'Release notes for 2.4' -Prompt 'add the migration notes for the new plugin API'
    Initialize-ChatOverlayNative
    $H = New-ChatOverlayHostState
    $script:ChatOverlayHost = $H
    $H.Ctx = New-ChatOverlayContext
    $H.State = [pscustomobject]@{ x = $null; y = $null; locked = $true; hidden = $false }
    New-ChatOverlayWindow $H
    Update-ChatOverlayView $H (Invoke-ChatOverlayCycle $H.Ctx -Peek)
}
finally { $lock.Dispose() }
# the frame alone, laid out off screen at twice the size, for a sharp image
$frame = $H.Frame
$H.Win.Content = $null
$frame.Width = $H.Win.Width
$frame.Measure([System.Windows.Size]::new($H.Win.Width, [double]::PositiveInfinity))
$frame.Arrange([System.Windows.Rect]::new($frame.DesiredSize))
$frame.UpdateLayout()
$bmp = [System.Windows.Media.Imaging.RenderTargetBitmap]::new([int]($frame.ActualWidth * 2), [int]($frame.ActualHeight * 2), 192, 192, [System.Windows.Media.PixelFormats]::Pbgra32)
$bmp.Render($frame)
$png = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
$png.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
$fs = [System.IO.File]::Create((Join-Path $here 'demo-overlay.png'))
try { $png.Save($fs) } finally { $fs.Dispose() }
$script:ChatqAliveSeam = $null
$script:ChatOverlayUsageSeam = $null
$script:ChatOverlayCopilotSeam = $null

# --- the chatrm walk-through ---------------------------------------------------
# chatrm gives its reload advice only while a VS Code window is up to take it,
# and a real shell runs the ghost watch, which the sandbox never starts
function Get-Process {
    [CmdletBinding()] param([string[]]$Name, [int[]]$Id)
    if ($Name) { return [pscustomobject]@{ Name = 'Code' } }
    Microsoft.PowerShell.Management\Get-Process @PSBoundParameters
}
function Test-ChatGhostWatch { $true }
function Get-DemoPanel {
    # what the panel's session list holds: this project's Claude chats, newest first
    @(Select-ChatInProject @(Get-ChatIndex | Where-Object { $_.Provider -eq 'claude' -and $_.Title -ne '(empty)' -and -not $_.Hidden }) |
            Sort-Object When -Descending | ForEach-Object { [pscustomobject]@{ Title = $_.Title; Age = Get-ChatRowAge $_ } })
}
$null = Sync-ChatIndex
$before = Get-DemoPanel
# What Tab leaves on the line: Set-ChatCycleLine's own steps, without the
# PSReadLine buffer it writes them into. Then what Enter runs, once it has taken
# the tail back off.
$typed = 'chatrm upload'
$byId = $false
$hits = @(Get-ChatCycleRows 'upload' ([ref]$byId))
$head = "chatrm '" + $hits[0].Title.Replace("'", "''") + "'"
$tabbed = $head + (Format-ChatPickTail (Get-ChatRowAge $hits[0]) 1 $hits.Count)
$ran = $tabbed -replace $script:ChatTailPattern, ''
$d1 = Invoke-Frame $typed {}
$d2 = Invoke-Frame $tabbed {}
$d3 = Invoke-Frame $ran { chatrm $hits[0].Title }
$d3 += , (Get-DemoTyped '')
$after = Get-DemoPanel
$d1[0] = Add-DemoCursor $d1[0] ('PS> ' + $typed).Length
$d2[0] = Add-DemoCursor $d2[0] ('PS> ' + $head).Length
$d3[$d3.Count - 1] = Add-DemoCursor $d3[$d3.Count - 1] 4
$cols = (@($d1) + @($d2) + @($d3) | ForEach-Object { ((@($_) | ForEach-Object { $_.Text }) -join '').Length } | Measure-Object -Maximum).Maximum
$size = @{ Cols = $cols; Rows = $d3.Count; Panel = $before }
ConvertTo-DemoSvg -Frame $d1 -Path (Join-Path $here 'demo-1-type.svg') @size -Cursor 0, ('PS> ' + $typed).Length -Key ('Tab ' + [char]0x21E5) `
    -Caption 'chatrm with part of a title typed and the Tab key, beside the chat panel listing that chat'
ConvertTo-DemoSvg -Frame $d2 -Path (Join-Path $here 'demo-2-tab.svg') @size -Cursor 0, ('PS> ' + $head).Length -Key ('Enter ' + [char]0x21B5) `
    -Caption 'Tab has filled in the whole title, quoted, with its age and match count'
ConvertTo-DemoSvg -Frame $d3 -Path (Join-Path $here 'demo-3-deleted.svg') @size `
    -Caption 'chatrm reporting the chat deleted, and that the panel keeps listing it until the window reloads'
ConvertTo-DemoSvg -Frame @() -Path (Join-Path $here 'demo-4-reloaded.svg') -Panel $after -PanelRows $before.Count `
    -Caption 'the chat panel after a window reload, the deleted chat no longer listed'

# --- PNG copies, for the Marketplace listing ----------------------------------------
# vsce refuses SVG images in an extension's README, so extension/README.md shows
# these instead. Edge draws each SVG, headless and at twice the size - no window,
# and the fonts are the ones a browser would use for the SVG. Without Edge the
# SVGs are written all the same.
$edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") |
    Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
# the ones extension/README.md shows
$pngs = 'demo-2-tab', 'demo-queue', 'demo-list'
if ($edge) {
    foreach ($n in $pngs) {
        $svg = Join-Path $here "$n.svg"
        $size = [regex]::Match([System.IO.File]::ReadAllText($svg), '<svg [^>]*width="(\d+)" height="(\d+)"')
        $png = Join-Path $here "$n.png"
        if (Test-Path -LiteralPath $png) { Remove-Item -LiteralPath $png }
        # its own profile in the sandbox: never the owner's, nor an Edge already open
        $null = Start-Process -FilePath $edge -Wait -PassThru -WindowStyle Hidden -ArgumentList @(
            '--headless', '--disable-gpu', '--hide-scrollbars', "--user-data-dir=`"$(Join-Path $sb 'edge')`"",
            '--force-device-scale-factor=2', '--default-background-color=00000000',
            "--window-size=$($size.Groups[1].Value),$($size.Groups[2].Value)", "--screenshot=`"$png`"", ([Uri]$svg).AbsoluteUri)
        if (-not (Test-Path -LiteralPath $png)) { throw "Edge drew no $n.png" }
    }
}
else { Microsoft.PowerShell.Utility\Write-Host '  no Edge: the PNG copies were not drawn' -ForegroundColor Yellow }

Set-Location -LiteralPath $here
Remove-Item -LiteralPath $sb -Recurse -Force -EA SilentlyContinue
Microsoft.PowerShell.Utility\Write-Host ('  wrote docs/demo-queue.svg, docs/demo-list.svg, docs/demo-overlay.png, docs/demo-1-type.svg .. demo-4-reloaded.svg' +
    $(if ($edge) { ', and PNGs of ' + ($pngs -join ', ') } else { '' }))
