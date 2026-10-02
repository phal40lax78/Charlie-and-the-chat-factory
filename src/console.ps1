# Charlie-and-the-chat-factory, src/console.ps1: dot-sourced by Charlie-and-the-chat-factory.ps1
# in its turn, never on its own - see the list there.

#region console: chatq in a window ---------------------------------------------
# Pick a chat - one open in VS Code, one the limit cut off, a recent one, or a
# new one in a folder - write to it, drop or paste files on it, and send it
# now or queue it; the queue beside it, with each job's outcome and log. A
# mode of the panel's own window, grown from its top-right corner
# (Enter-ChatOverlayConsoleMode) - one that takes focus while it shows - in
# the overlay's own process and on its thread, drawn from the snapshot the
# collector makes every 2 s. Only the user ever opens it: the button on the
# overlay's bar, the tray, the console hotkey, or chatconsole; Esc, its back
# button or the hotkey again go back to the panel. Windows only, like the
# panel's buttons.

$script:ChatConsoleStatePath = Join-Path $script:ChatqData 'console-state.json'
$script:ChatConsoleDraftDir = Join-Path (Join-Path $script:ChatqData 'console') 'draft'
# tests: what a paste finds on the clipboard; no index sync in a child
$script:ChatConsoleClipboardSeam = $null
$script:ChatConsoleNoSync = $false
# tests: stands in for bringing the console forward (Window.Activate), so a
# test that opens it the user's way never takes the keyboard from the user
$script:ChatConsoleFrontSeam = $null
$script:ChatConsoleModes = @('default', 'acceptEdits', 'auto', 'plan', 'bypassPermissions')
$script:ChatConsoleModels = @('opus', 'sonnet', 'haiku')

function ConvertFrom-ChatConsoleWhen {
    <#
    The When choice to what a job holds. next: the front of the queue - not
    beside a run in progress: the watcher runs one job at a time - and a
    chat busy in VS Code looked at every 30 s. Called Now until 0.10.2,
    which read as the word "now" sent; 'now' is still read as next, from a
    draft kept then. turn: behind what is queued. at / in: -Value, as
    chatq -At 13:00 or -In 2h reads it. Send's alone: Continue and Continue
    all go ahead of the prompts waiting (Get-ChatqJobs). Pure.
    #>
    param([string]$When, [string]$Value)
    $ok = { param($nb, $first, $now) [pscustomobject]@{ Error = $null; NotBefore = $nb; First = $first; SendNow = $now } }
    switch ($When) {
        { $_ -in 'next', 'now' } { return & $ok $null $true $true }
        'turn' { return & $ok $null $false $false }
    }
    $v = ([string]$Value).Trim()
    $example = if ($When -eq 'at') { '13:00' } else { '90m, 2h or 1d' }
    if (-not $v) { return [pscustomobject]@{ Error = "give a time - $example"; NotBefore = $null; First = $false; SendNow = $false } }
    $t = try { if ($When -eq 'at') { ConvertFrom-ChatqWhen -At $v } else { ConvertFrom-ChatqWhen -In $v } } catch { $null }
    if (-not $t) { return [pscustomobject]@{ Error = "'$v' is not a time - $example"; NotBefore = $null; First = $false; SendNow = $false } }
    return & $ok $t $false $false
}

function Select-ChatConsoleChats {
    # every word typed, anywhere in the title or the project, in any case
    param([object[]]$Chats, [string]$Search, [int]$Max = 0)
    $words = @(([string]$Search).ToLowerInvariant() -split '\s+' | Where-Object { $_ })
    $out = @(foreach ($c in @($Chats)) {
            if (-not $c) { continue }
            $hay = "$($c.Title) $($c.Project)".ToLowerInvariant()
            $all = $true
            foreach ($w in $words) { if (-not $hay.Contains($w)) { $all = $false; break } }
            if ($all) { $c }
        })
    if ($Max -gt 0) { $out = @($out | Select-Object -First $Max) }
    return $out
}

function Get-ChatConsoleSendPreview {
    <#
    What Send will do, said before it is pressed. -Target: @{ Kind = chat |
    new; Live = busy | waiting | idle, or $null when no window has it;
    Provider = claude | codex, claude when missing }.
    -Plan: ConvertFrom-ChatConsoleWhen's answer. -Block: its provider's
    limit, @{ Until; Type }. -Ahead: jobs queued in front of it. -Running:
    the number of the job running now, 0 for none - the watcher runs one at
    a time, so even Next waits for it to end. Pure.
    #>
    param($Target, $Plan, $Block, [int]$Ahead, [bool]$Watcher, [datetime]$Now = (Get-Date), [int]$Running = 0)
    if (-not $Target) { return 'pick a chat on the left, or + New chat' }
    if ($Plan.Error) { return $Plan.Error }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $bits = @()
    if ($Plan.NotBefore) { $bits += "sends $(Format-ChatOverlayWhen ([datetime]$Plan.NotBefore) $Now) at the earliest" }
    # a Codex outage waits on no status page, only on tries after 1, 2, 5,
    # 10, then every 15 minutes (Test-ChatqOutageOver)
    elseif ($Block -and $Block.Type -eq 'overloaded' -and [string](Get-ChatField $Target 'Provider') -eq 'codex') { $bits += 'Codex is overloaded - sends once a try gets through, after 1, 2, 5, 10, then every 15 min' }
    elseif ($Block -and $Block.Type -eq 'overloaded') { $bits += 'Claude is overloaded - sends once status.claude.com has it back' }
    # a refused login and a probe that failed hold the queue too, but no limit
    # is over at their time - the watcher only looks again then
    elseif ($Block -and $Block.Type -eq 'login needed') {
        $said = if ($Block.PSObject.Properties['Why'] -and $Block.Why -and $Block.Why -notin 'probe', 'run') { [string]$Block.Why } else { 'login refused' }
        $bits += "$said - log in or check the subscription; sends once the login works again, looked at every 15 min"
    }
    elseif ($Block -and $Block.Type -eq 'probe failed' -and $Block.Until) { $bits += "the limit could not be checked - looked at again $($Block.Until.ToString('HH:mm', $inv))" }
    elseif ($Block -and $Block.Until -and $Block.Until -gt $Now) { $bits += "limited until $($Block.Until.ToString('HH:mm', $inv)) - sends $($Block.Until.AddMinutes(1).ToString('HH:mm', $inv))" }
    elseif (-not $Plan.First -and $Ahead -gt 0) { $bits += "after the $Ahead queued ahead of it" }
    elseif ($Running) { $bits += "sends once #$Running, running now, ends - one job runs at a time" }
    else { $bits += 'sends within a few seconds' }
    if ($Target.Kind -eq 'new') { $bits += 'a new chat - a VS Code window on that folder is offered a reload to pick it up' }
    elseif ($Target.Live -in 'busy', 'waiting') { $bits += "that chat is working in VS Code - it goes once the chat is idle$(if ($Plan.SendNow) { ', looked at every 30 s' })" }
    elseif ($Target.Live -eq 'idle' -or $Target.Live -eq 'cutoff') { $bits += 'open in VS Code - reload that window to see the reply' }
    if (-not $Watcher) { $bits += 'the watcher starts for it' }
    return ($bits -join ' - ')
}

function Get-ChatConsoleJobStatus {
    # a job's words at the right of the console's queue, and their colour
    param($Job, [string]$Eta, [datetime]$Now = (Get-Date))
    $at = { param($s) $d = ConvertTo-ChatqDate $s; if ($d) { Format-ChatOverlayWhen $d $Now } else { '' } }
    $why = if ($Job.result -and $Job.result.reason) { " - $($Job.result.reason)" } else { '' }
    switch ([string]$Job.state) {
        'queued' {
            $t = if (-not $Eta) { 'queued' } elseif ($Eta -match '^(\d|[A-Z][a-z]{2} \d)') { "sends $Eta" } else { $Eta }
            # the continue auto-continue queued says so (src/auto-continue.ps1)
            if (Get-ChatField $Job 'auto') { $t = "auto-continues $(if ($Eta) { $Eta } else { 'after the reset' })" }
            # held back by the watcher for a reason of its own: that reason,
            # in the panel's words - the details pane has no ETA to go by
            $wait = Format-ChatOverlayDeferral $Job $Now
            if ($wait) { $t = $wait }
            return [pscustomobject]@{ Text = $t; Tone = 'queued' }
        }
        'running' {
            # started with Ultracode, or at a session-only level, as the chat
            # had them (Format-ChatqRunCarry)
            $c = Format-ChatqRunCarry $Job
            $uc = if ($c) { ", $c" } else { '' }
            return [pscustomobject]@{ Text = "running since $(& $at $Job.startedAt)$uc"; Tone = 'running' }
        }
        'needs-input' { return [pscustomobject]@{ Text = "needs you$why"; Tone = 'waiting' } }
        'done' { return [pscustomobject]@{ Text = "done $(& $at $Job.endedAt)"; Tone = 'busy' } }
        'failed' { return [pscustomobject]@{ Text = "failed$why"; Tone = 'error' } }
        'skipped' { return [pscustomobject]@{ Text = "skipped$why"; Tone = 'faint' } }
    }
    return [pscustomobject]@{ Text = [string]$Job.state; Tone = 'dim' }
}

function Get-ChatConsoleJobRow {
    # a job as the one row of its chat the chip opens from
    # (Start-ChatShowFreshProcess): provider, session, folder and title. Pure.
    param($Job)
    return [pscustomobject]@{ kind = 'session'; provider = [string]$Job.provider; sessionId = [string]$Job.sessionId; cwd = [string]$Job.cwd; title = [string]$Job.title }
}

function Get-ChatConsolePlacement {
    <#
    Where the console goes, all in screen pixels: grown from the panel's
    top-right corner (-Panel x y width height), its right edge and top held,
    at the size it was last left (-Saved w and h: in units, turned into this
    screen's pixels by -Scale, when Saved.units says so, else pixels as an
    older console-state.json kept them) or else -Width by -Height, never
    under -MinWidth by -MinHeight, and kept on -Area, the working area of
    the panel's screen - no bigger than it, and pushed left, or up, where
    it would run off. The minimum is the window's own, in this screen's
    pixels: an older size in pixels, saved on a screen at a lower scale,
    can be under it here, and the window, made bigger by Windows from its
    left edge, would no longer end at the panel's right. Pure.
    #>
    param([int[]]$Panel, $Saved, $Area, [double]$Width = 980, [double]$Height = 680, [double]$MinWidth = 0, [double]$MinHeight = 0, [double]$Scale = 1.0)
    $w = $Width
    $h = $Height
    if ($Saved -and [double]$Saved.w -ge 400 -and [double]$Saved.h -ge 300) {
        $k = if (Get-ChatField $Saved 'units') { $Scale } else { 1.0 }
        $w = [double]$Saved.w * $k; $h = [double]$Saved.h * $k
    }
    $w = [Math]::Max($w, $MinWidth)
    $h = [Math]::Max($h, $MinHeight)
    $w = [Math]::Min($w, [double]$Area.Width)
    $h = [Math]::Min($h, [double]$Area.Height)
    $x = [Math]::Max([double]$Area.X, [Math]::Min($Panel[0] + $Panel[2] - $w, $Area.X + $Area.Width - $w))
    $y = [Math]::Max([double]$Area.Y, [Math]::Min([double]$Panel[1], $Area.Y + $Area.Height - $h))
    return [pscustomobject]@{ X = [int][Math]::Round($x); Y = [int][Math]::Round($y); W = [int][Math]::Round($w); H = [int][Math]::Round($h) }
}

function Read-ChatConsoleState {
    # console-state.json: its size, whether it was maximized, and the draft
    # - what was being written, to which chat, with which files - so a
    # restart keeps it. Where it was is an older console's, a window of its
    # own: where it goes comes from the panel now. units: w and h are in
    # WPF's units (Save-ChatConsoleDraft); an older file, without it, has
    # them in pixels, and they are taken as pixels until it is saved again.
    $s = Read-ChatqJson $script:ChatConsoleStatePath
    if (-not $s) { $s = [pscustomobject]@{} }
    foreach ($k in 'x', 'y') { if ($s.PSObject.Properties[$k]) { $s.PSObject.Properties.Remove($k) } }
    foreach ($k in 'w', 'h', 'draft') { if (-not $s.PSObject.Properties[$k]) { Set-ChatqProp $s $k $null } }
    foreach ($k in 'max', 'units') { Set-ChatqProp $s $k ([bool]$(if ($s.PSObject.Properties[$k]) { $s.$k })) }
    foreach ($k in @(@('left', 300), @('queue', 230))) { if (-not $s.PSObject.Properties[$k[0]]) { Set-ChatqProp $s $k[0] $k[1] } }
    if (-not $s.PSObject.Properties['folders']) { Set-ChatqProp $s 'folders' @() }
    return $s
}

function New-ChatConsoleButton {
    # a flat button, drawn as a border: WPF's own Button brings the system's
    # light look into a dark console. -Tone: its words and edge in that
    # colour - Remove's "sure?" in error's, so an ask standing shows
    param([string]$Text, [scriptblock]$OnClick, [switch]$Accent, [string]$Tip, $Tag, [switch]$Small, [string]$Tone)
    $b = [System.Windows.Controls.Border]::new()
    $b.CornerRadius = [System.Windows.CornerRadius]::new(4)
    $b.BorderThickness = [System.Windows.Thickness]::new(1)
    $b.Padding = if ($Small) { [System.Windows.Thickness]::new(7, 1, 7, 2) } else { [System.Windows.Thickness]::new(11, 3, 11, 4) }
    $b.Margin = [System.Windows.Thickness]::new(0, 0, 6, 0)
    $b.Cursor = [System.Windows.Input.Cursors]::Hand
    $b.Background = if ($Accent) { Get-ChatOverlayBrush 'accent' } else { [System.Windows.Media.Brushes]::Transparent }
    $b.BorderBrush = Get-ChatOverlayBrush $(if ($Accent) { 'accent' } elseif ($Tone) { $Tone } else { 'inputEdge' })
    $b.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $b.Child = New-ChatOverlayText $Text $(if ($Accent) { 'onAccent' } elseif ($Tone) { $Tone } else { 'text' }) $(if ($Small) { 11 } else { 12 })
    if ($Tip) { $b.ToolTip = $Tip }
    $b.Tag = $Tag
    if (-not $Accent) {
        $b.add_MouseEnter({ param($s, $e) $s.Background = Get-ChatOverlayBrush 'hover' })
        $b.add_MouseLeave({ param($s, $e) $s.Background = [System.Windows.Media.Brushes]::Transparent })
    }
    if ($OnClick) { $b.add_MouseLeftButtonUp($OnClick) }
    return $b
}

function New-ChatConsoleInput {
    param([switch]$Multi, [string]$Tip)
    $t = [System.Windows.Controls.TextBox]::new()
    $t.Background = Get-ChatOverlayBrush 'input'
    $t.Foreground = Get-ChatOverlayBrush 'text'
    $t.BorderBrush = Get-ChatOverlayBrush 'inputEdge'
    $t.CaretBrush = Get-ChatOverlayBrush 'text'
    $t.SelectionBrush = Get-ChatOverlayBrush 'accent'
    $t.Padding = [System.Windows.Thickness]::new(6, 4, 6, 4)
    $t.FontSize = 12.5
    if ($Tip) { $t.ToolTip = $Tip }
    if ($Multi) {
        $t.AcceptsReturn = $true
        $t.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $t.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
        $t.VerticalContentAlignment = [System.Windows.VerticalAlignment]::Top
    }
    return $t
}

function New-ChatConsoleChips {
    # a row of choices, the one in force filled; a click hands the chip to
    # -OnClick, whose Tag is its value; -Tips, a tooltip each
    param([string[]]$Values, [string[]]$Labels, [string]$Current, [scriptblock]$OnClick, [string[]]$Tips)
    $row = [System.Windows.Controls.WrapPanel]::new()
    for ($i = 0; $i -lt $Values.Count; $i++) {
        $on = $Values[$i] -eq $Current
        $c = [System.Windows.Controls.Border]::new()
        $c.CornerRadius = [System.Windows.CornerRadius]::new(4)
        $c.BorderThickness = [System.Windows.Thickness]::new(1)
        $c.Padding = [System.Windows.Thickness]::new(8, 1, 8, 2)
        $c.Margin = [System.Windows.Thickness]::new(0, 2, 4, 2)
        $c.Background = if ($on) { Get-ChatOverlayBrush 'accent' } else { [System.Windows.Media.Brushes]::Transparent }
        $c.BorderBrush = Get-ChatOverlayBrush $(if ($on) { 'accent' } else { 'inputEdge' })
        $c.Cursor = [System.Windows.Input.Cursors]::Hand
        $c.Tag = $Values[$i]
        if ($Tips -and $Tips[$i]) { $c.ToolTip = $Tips[$i] }
        $c.Child = New-ChatOverlayText $Labels[$i] $(if ($on) { 'onAccent' } else { 'text' }) 11.5
        $c.add_MouseLeftButtonUp($OnClick)
        [void]$row.Children.Add($c)
    }
    return $row
}

function New-ChatConsoleLook {
    <#
    The panel's look, in the console's header: its opacity on a slider and
    its theme as chips - the same settings as the panel's box, applied to
    the window as they move, so the panel comes back with them. The slider
    is kept to config.json once let go (Save-ChatConsoleLook), as the
    pointer check that keeps the panel's rests while the console shows.
    #>
    param($H)
    $row = [System.Windows.Controls.StackPanel]::new()
    $row.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $row.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $row.Background = [System.Windows.Media.Brushes]::Transparent
    $row.Cursor = [System.Windows.Input.Cursors]::Arrow
    $l = New-ChatOverlayText 'Opacity' 'dim' 11
    $l.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $l.Margin = [System.Windows.Thickness]::new(0, 0, 6, 0)
    [void]$row.Children.Add($l)
    $s = [System.Windows.Controls.Slider]::new()
    $s.Minimum = 0.3
    $s.Maximum = 1.0
    $s.SmallChange = 0.05
    $s.LargeChange = 0.1
    $s.IsMoveToPointEnabled = $true
    $s.Width = 90
    $s.Value = if ($H.Win) { $H.Win.Opacity } else { $H.Ctx.Config.opacity }
    $s.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $s.ToolTip = 'The panel''s opacity, and the console''s'
    $s.Tag = 'opacity'
    [void]$row.Children.Add($s)
    $v = New-ChatOverlayText "$([int][Math]::Round($s.Value * 100))%" 'text' 11
    $v.Width = 34
    $v.TextAlignment = [System.Windows.TextAlignment]::Right
    $v.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $v.Margin = [System.Windows.Thickness]::new(0, 0, 12, 0)
    [void]$row.Children.Add($v)
    $H.Con.LookSlider = $s
    $H.Con.LookText = $v
    $s.add_ValueChanged({
            param($x, $e)
            $X = $script:ChatOverlayHost
            if ($X.SettingsSync) { return }
            Set-ChatOverlayOpacity $X $e.NewValue
            $X.Con.LookText.Text = "$([int][Math]::Round($X.Win.Opacity * 100))%"
        })
    $s.add_LostMouseCapture({ Save-ChatConsoleLook $script:ChatOverlayHost })
    $s.add_LostKeyboardFocus({ Save-ChatConsoleLook $script:ChatOverlayHost })
    $chips = New-ChatOverlayChips @('dark', 'light', 'system') ([string]$H.Ctx.Config.theme) { param($x, $e) $e.Handled = $true; Set-ChatOverlayThemeChoice $script:ChatOverlayHost ([string]$x.Tag) }
    $chips.Margin = [System.Windows.Thickness]::new(0)
    $chips.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $chips.ToolTip = 'The panel''s theme, and the console''s'
    [void]$row.Children.Add($chips)
    return $row
}

function Save-ChatConsoleLook {
    # the opacity the console's slider rested on, to config.json - once
    param($H)
    if (-not $H -or $null -eq $H.PendingOpacity) { return }
    Save-ChatOverlaySetting $H @{}
}

function Test-ChatConsoleDragFrom {
    <#
    Whether a press that reached the header -Bar from -Source moves the
    window: anywhere on it - its padding, the grip, the counts, a gap -
    but on one of -Keep, the header's own controls, or within one.
    #>
    param($Source, $Bar, [object[]]$Keep)
    $el = $Source
    while ($el) {
        foreach ($k in $Keep) { if ($k -and [object]::ReferenceEquals($el, $k)) { return $false } }
        if ([object]::ReferenceEquals($el, $Bar)) { return $true }
        $up = $null
        if ($el -is [System.Windows.Media.Visual] -or $el -is [System.Windows.Media.Media3D.Visual3D]) { $up = [System.Windows.Media.VisualTreeHelper]::GetParent($el) }
        if (-not $up -and $el -is [System.Windows.DependencyObject]) { $up = [System.Windows.LogicalTreeHelper]::GetParent($el) }
        $el = $up
    }
    return $false
}

function New-ChatConsole {
    <#
    The console, made once, the first time it is opened, and kept until the
    overlay stops - going back to the panel keeps the draft. It has no
    window of its own: it shows in the panel's (Enter-ChatOverlayConsoleMode),
    so Win and Hwnd are the panel's. Its content, Root, is built by
    Initialize-ChatConsoleContent - again when the theme changes - and is
    the window's only while the console shows.
    #>
    param($H)
    $C = @{
        # Sigs, not Keys: $C.Keys is the hashtable's own list of its keys
        # Max: filling its screen (Set-ChatConsoleMax), Restore the rect it
        # goes back to
        Win = $H.Win; Hwnd = $H.Hwnd; Root = $null; BackBtn = $null; MaxBtn = $null; Max = $false; Restore = $null
        State = (Read-ChatConsoleState); Sigs = @{}; Target = $null
        Staged = [System.Collections.Generic.List[object]]::new(); When = 'next'; WhenValue = ''; Mode = ''; Model = ''; Sandbox = ''
        Text = ''; NewCwd = ''; NewName = ''; Search = ''; Sel = $null; ShowLog = $false; Jobs = @(); JobsSig = $null
        Index = @(); IndexStamp = $null; IndexParsed = $false; IndexRead = $null; Sync = $null; SyncAt = [datetime]::MinValue; Info = @{}
        Request = $null; WatchSays = ''; TypedAt = $null; Skips = 0; Dirty = $null; Modal = $false; Confirm = @{}; Blocks = $null; BlocksAt = [datetime]::MinValue
    }
    $H.Con = $C
    Restore-ChatConsoleDraft $H
    Initialize-ChatConsoleContent $H
}

function Initialize-ChatConsoleContent {
    # Everything the console shows, from scratch - a theme change comes
    # through here too - keeping what is typed. Built into Root, a frame of
    # its own: the panel's window is see-through. Put in the window only
    # while the console shows in it.
    param($H)
    $C = $H.Con
    if ($C.Prompt) { $C.Text = $C.Prompt.Text }
    if ($C.FolderBox) { $C.NewCwd = $C.FolderBox.Text }
    if ($C.NameBox) { $C.NewName = $C.NameBox.Text }
    if ($C.WhenBox) { $C.WhenValue = $C.WhenBox.Text }
    $gl = { param($v) if ($v -gt 0) { [System.Windows.GridLength]::new($v) } else { [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) } }
    $frame = [System.Windows.Controls.Border]::new()
    $frame.CornerRadius = [System.Windows.CornerRadius]::new(8)
    $frame.Background = Get-ChatOverlayBrush 'window'
    $frame.BorderBrush = Get-ChatOverlayBrush 'edge'
    $frame.BorderThickness = [System.Windows.Thickness]::new(1)
    [System.Windows.Documents.TextElement]::SetForeground($frame, (Get-ChatOverlayBrush 'text'))
    [System.Windows.Documents.TextElement]::SetFontSize($frame, 12.5)
    $root = [System.Windows.Controls.Grid]::new()
    $frame.Child = $root
    foreach ($r in 'auto', 'star', 'auto') {
        $rd = [System.Windows.Controls.RowDefinition]::new()
        $rd.Height = if ($r -eq 'auto') { [System.Windows.GridLength]::Auto } else { & $gl 0 }
        $root.RowDefinitions.Add($rd)
    }
    # the header: a grip, usage and the queue's counts, the panel's look -
    # opacity and theme, the same settings as the panel's box - maximize,
    # and the way back to the panel at the corner the panel comes back to.
    # The window has no title bar: a press anywhere on the header but its
    # controls moves it, padding included, so the strip to grab is the
    # whole bar.
    $bar = [System.Windows.Controls.Border]::new()
    $bar.Padding = [System.Windows.Thickness]::new(8, 6, 8, 6)
    $bar.Background = [System.Windows.Media.Brushes]::Transparent
    $bar.ToolTip = 'Drag to move'
    $head = [System.Windows.Controls.DockPanel]::new()
    $bar.Child = $head
    $C.BackBtn = New-ChatConsoleButton "$([char]0x2190) Panel" { param($s, $e) $e.Handled = $true; Exit-ChatOverlayConsoleMode $script:ChatOverlayHost } -Tip 'Back to the panel (Esc)'
    $C.BackBtn.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
    [System.Windows.Controls.DockPanel]::SetDock($C.BackBtn, [System.Windows.Controls.Dock]::Right)
    [void]$head.Children.Add($C.BackBtn)
    $C.MaxBtn = New-ChatConsoleButton (Get-ChatConsoleMaxLabel $C.Max) { param($s, $e) $e.Handled = $true; $X = $script:ChatOverlayHost; Set-ChatConsoleMax $X (-not $X.Con.Max) } -Tip 'Fill the screen, or back to its size (double-click the header)'
    $C.MaxBtn.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
    [System.Windows.Controls.DockPanel]::SetDock($C.MaxBtn, [System.Windows.Controls.Dock]::Right)
    [void]$head.Children.Add($C.MaxBtn)
    $C.Look = New-ChatConsoleLook $H
    [System.Windows.Controls.DockPanel]::SetDock($C.Look, [System.Windows.Controls.Dock]::Right)
    [void]$head.Children.Add($C.Look)
    $dots = [System.Windows.Media.GeometryGroup]::new()
    foreach ($x in 1.5, 5.5) { foreach ($y in 1.5, 5.5, 9.5) { $dots.Children.Add([System.Windows.Media.EllipseGeometry]::new([System.Windows.Point]::new($x, $y), 1.25, 1.25)) } }
    $grip = [System.Windows.Shapes.Path]::new()
    $grip.Data = $dots
    $grip.Fill = Get-ChatOverlayBrush 'dim'
    $grip.Margin = [System.Windows.Thickness]::new(2, 0, 10, 0)
    $grip.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $grip.Cursor = [System.Windows.Input.Cursors]::SizeAll
    [System.Windows.Controls.DockPanel]::SetDock($grip, [System.Windows.Controls.Dock]::Left)
    [void]$head.Children.Add($grip)
    $C.Header = New-ChatOverlayText '' 'dim' 12 -Trim
    $C.Header.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    [void]$head.Children.Add($C.Header)
    $C.Bar = $bar
    $bar.add_MouseLeftButtonDown({
            param($s, $e)
            $X = $script:ChatOverlayHost
            if ($X.Mode -ne 'console' -or -not (Test-ChatConsoleDragFrom $e.OriginalSource $s @($X.Con.BackBtn, $X.Con.MaxBtn, $X.Con.Look))) { return }
            $e.Handled = $true
            # a double-click fills the screen, or gives the size back, as a
            # title bar's does; a maximized console is not moved
            if ($e.ClickCount -eq 2) { Set-ChatConsoleMax $X (-not $X.Con.Max); return }
            if ($X.Con.Max) { return }
            # DragMove runs a loop of its own, which the timer would fire in
            $X.Dragging = $true
            try { $X.Win.DragMove() } catch {}
            $X.Dragging = $false
            Invoke-ChatOverlayHeldVerbs $X
        })
    [void]$root.Children.Add($bar)

    $body = [System.Windows.Controls.Grid]::new()
    [System.Windows.Controls.Grid]::SetRow($body, 1)
    foreach ($cw in [Math]::Max(200, [double]$C.State.left), 6, 0) { $cd = [System.Windows.Controls.ColumnDefinition]::new(); $cd.Width = & $gl $cw; $body.ColumnDefinitions.Add($cd) }
    $body.ColumnDefinitions[0].MinWidth = 200
    $C.LeftCol = $body.ColumnDefinitions[0]
    [void]$root.Children.Add($body)

    # left: search, + New chat, and the chats
    $left = [System.Windows.Controls.DockPanel]::new()
    $left.Margin = [System.Windows.Thickness]::new(10, 0, 0, 8)
    $top = [System.Windows.Controls.DockPanel]::new()
    $top.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
    [System.Windows.Controls.DockPanel]::SetDock($top, [System.Windows.Controls.Dock]::Top)
    $newB = New-ChatConsoleButton '+ New chat' { Select-ChatConsoleNew $script:ChatOverlayHost } -Tip 'Start a new Claude chat in a folder'
    $newB.Margin = [System.Windows.Thickness]::new(6, 0, 0, 0)
    [System.Windows.Controls.DockPanel]::SetDock($newB, [System.Windows.Controls.Dock]::Right)
    [void]$top.Children.Add($newB)
    $C.SearchBox = New-ChatConsoleInput -Tip 'Search chats: every word, in the title or the project'
    $C.SearchBox.Text = $C.Search
    # what the box is for, faint inside it while it is empty
    $hint = New-ChatOverlayText 'Search chats' 'faint' 12
    $hint.IsHitTestVisible = $false
    $hint.Margin = [System.Windows.Thickness]::new(9, 0, 0, 0)
    $hint.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $hint.Visibility = if ($C.Search) { [System.Windows.Visibility]::Collapsed } else { [System.Windows.Visibility]::Visible }
    $C.SearchHint = $hint
    $C.SearchBox.add_TextChanged({
            param($s, $e)
            $H = $script:ChatOverlayHost
            $H.Con.Search = $s.Text
            $H.Con.SearchHint.Visibility = if ($s.Text) { [System.Windows.Visibility]::Collapsed } else { [System.Windows.Visibility]::Visible }
            Update-ChatConsoleChats $H
        })
    $sg = [System.Windows.Controls.Grid]::new()
    [void]$sg.Children.Add($C.SearchBox)
    [void]$sg.Children.Add($hint)
    [void]$top.Children.Add($sg)
    [void]$left.Children.Add($top)
    $sv = [System.Windows.Controls.ScrollViewer]::new()
    $sv.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
    $C.Chats = [System.Windows.Controls.StackPanel]::new()
    $sv.Content = $C.Chats
    [void]$left.Children.Add($sv)
    [void]$body.Children.Add($left)
    $split = [System.Windows.Controls.GridSplitter]::new()
    $split.Width = 6
    $split.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Stretch
    $split.Background = [System.Windows.Media.Brushes]::Transparent
    [System.Windows.Controls.Grid]::SetColumn($split, 1)
    [void]$body.Children.Add($split)

    # right: compose above, the queue below
    $right = [System.Windows.Controls.Grid]::new()
    [System.Windows.Controls.Grid]::SetColumn($right, 2)
    foreach ($rh in 0, 6, [Math]::Max(140, [double]$C.State.queue)) { $rd = [System.Windows.Controls.RowDefinition]::new(); $rd.Height = & $gl $rh; $right.RowDefinitions.Add($rd) }
    $right.RowDefinitions[0].MinHeight = 200
    $right.RowDefinitions[2].MinHeight = 120
    $C.QueueRow = $right.RowDefinitions[2]
    [void]$body.Children.Add($right)

    $compose = [System.Windows.Controls.DockPanel]::new()
    $compose.Margin = [System.Windows.Thickness]::new(4, 0, 12, 6)
    $C.To = [System.Windows.Controls.StackPanel]::new()
    $C.To.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
    [System.Windows.Controls.DockPanel]::SetDock($C.To, [System.Windows.Controls.Dock]::Top)
    [void]$compose.Children.Add($C.To)
    # a new chat's folder and name
    $C.NewBox = [System.Windows.Controls.StackPanel]::new()
    $C.NewBox.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
    [System.Windows.Controls.DockPanel]::SetDock($C.NewBox, [System.Windows.Controls.Dock]::Top)
    $fr = [System.Windows.Controls.DockPanel]::new()
    $fl = New-ChatOverlayText 'Folder' 'dim' 12
    $fl.Width = 52
    $fl.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    [System.Windows.Controls.DockPanel]::SetDock($fl, [System.Windows.Controls.Dock]::Left)
    [void]$fr.Children.Add($fl)
    $browse = New-ChatConsoleButton 'Browse' { Invoke-ChatConsoleBrowse $script:ChatOverlayHost } -Tip 'Pick the folder the new chat works in'
    $browse.Margin = [System.Windows.Thickness]::new(6, 0, 0, 0)
    [System.Windows.Controls.DockPanel]::SetDock($browse, [System.Windows.Controls.Dock]::Right)
    [void]$fr.Children.Add($browse)
    $C.FolderBox = New-ChatConsoleInput -Tip 'The folder the new chat works in - or drop a folder here'
    $C.FolderBox.Text = $C.NewCwd
    $C.FolderBox.AllowDrop = $true
    $C.FolderBox.add_PreviewDragOver({ param($s, $e) if ($e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) { $e.Effects = [System.Windows.DragDropEffects]::Copy; $e.Handled = $true } })
    $C.FolderBox.add_PreviewDrop({
            param($s, $e)
            if (-not $e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) { return }
            $e.Handled = $true
            $d = @([string[]]$e.Data.GetData([System.Windows.DataFormats]::FileDrop) | Where-Object { Test-Path -LiteralPath $_ -PathType Container })[0]
            if ($d) { $s.Text = $d }
        })
    $C.FolderBox.add_TextChanged({ $H = $script:ChatOverlayHost; if ($H.Con.Target -and $H.Con.Target.Kind -eq 'new') { $H.Con.Target.Cwd = $H.Con.FolderBox.Text; $H.Con.Dirty = Get-Date; Update-ChatConsolePreview $H } })
    [void]$fr.Children.Add($C.FolderBox)
    [void]$C.NewBox.Children.Add($fr)
    $C.Recent = [System.Windows.Controls.WrapPanel]::new()
    $C.Recent.Margin = [System.Windows.Thickness]::new(52, 3, 0, 3)
    [void]$C.NewBox.Children.Add($C.Recent)
    $nr = [System.Windows.Controls.DockPanel]::new()
    $nl = New-ChatOverlayText 'Name' 'dim' 12
    $nl.Width = 52
    $nl.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    [System.Windows.Controls.DockPanel]::SetDock($nl, [System.Windows.Controls.Dock]::Left)
    [void]$nr.Children.Add($nl)
    $C.NameBox = New-ChatConsoleInput -Tip 'What the chat list calls it - the prompt''s first line if left empty'
    $C.NameBox.Text = $C.NewName
    [void]$nr.Children.Add($C.NameBox)
    [void]$C.NewBox.Children.Add($nr)
    [void]$compose.Children.Add($C.NewBox)
    # the foot: when, mode, model; what Send will do; Send
    $foot = [System.Windows.Controls.StackPanel]::new()
    $foot.Margin = [System.Windows.Thickness]::new(0, 6, 0, 0)
    [System.Windows.Controls.DockPanel]::SetDock($foot, [System.Windows.Controls.Dock]::Bottom)
    $C.Opts = [System.Windows.Controls.StackPanel]::new()
    [void]$foot.Children.Add($C.Opts)
    $sendRow = [System.Windows.Controls.DockPanel]::new()
    $sendRow.Margin = [System.Windows.Thickness]::new(0, 6, 0, 0)
    $C.SendBtn = New-ChatConsoleButton 'Send' { Invoke-ChatConsoleSend $script:ChatOverlayHost } -Accent -Tip 'Ctrl+Enter'
    $C.SendBtn.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
    [System.Windows.Controls.DockPanel]::SetDock($C.SendBtn, [System.Windows.Controls.Dock]::Right)
    [void]$sendRow.Children.Add($C.SendBtn)
    $C.Preview = New-ChatOverlayText '' 'dim' 11.5
    $C.Preview.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $C.Preview.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    [void]$sendRow.Children.Add($C.Preview)
    [void]$foot.Children.Add($sendRow)
    [void]$compose.Children.Add($foot)
    # the prompt, and its files under it
    $pg = [System.Windows.Controls.Grid]::new()
    foreach ($r in 'star', 'auto') { $rd = [System.Windows.Controls.RowDefinition]::new(); $rd.Height = if ($r -eq 'auto') { [System.Windows.GridLength]::Auto } else { & $gl 0 }; $pg.RowDefinitions.Add($rd) }
    $C.Prompt = New-ChatConsoleInput -Multi -Tip 'The prompt. Ctrl+Enter sends; drop files here or paste a screenshot to send them with it'
    $C.Prompt.MinHeight = 80
    $C.Prompt.AllowDrop = $true
    $C.Prompt.Text = $C.Text
    $C.Prompt.add_TextChanged({ $H = $script:ChatOverlayHost; $H.Con.Dirty = Get-Date })
    $C.Prompt.add_PreviewKeyDown({
            param($s, $e)
            $H = $script:ChatOverlayHost
            $ctrl = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
            if ($ctrl -and $e.Key -eq [System.Windows.Input.Key]::Return) { $e.Handled = $true; Invoke-ChatConsoleSend $H; return }
            # a screenshot or copied files: the box would take neither - text
            # is left to its own paste
            if ($ctrl -and $e.Key -eq [System.Windows.Input.Key]::V) {
                $clip = Get-ChatConsoleClipboard
                if ($clip -and (@($clip.Files).Count -or $clip.Image)) { $e.Handled = $true; Invoke-ChatConsolePaste $H $clip }
            }
        })
    # the box would take a drop as text: files are taken here first
    $C.Prompt.add_PreviewDragEnter({ param($s, $e) if ($e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) { $e.Effects = [System.Windows.DragDropEffects]::Copy; $e.Handled = $true } })
    $C.Prompt.add_PreviewDragOver({ param($s, $e) if ($e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) { $e.Effects = [System.Windows.DragDropEffects]::Copy; $e.Handled = $true } })
    $C.Prompt.add_PreviewDrop({
            param($s, $e)
            if (-not $e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) { return }
            $e.Handled = $true
            Add-ChatConsoleDrop $script:ChatOverlayHost ([string[]]$e.Data.GetData([System.Windows.DataFormats]::FileDrop))
        })
    [void]$pg.Children.Add($C.Prompt)
    $C.Files = [System.Windows.Controls.WrapPanel]::new()
    $C.Files.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0)
    [System.Windows.Controls.Grid]::SetRow($C.Files, 1)
    [void]$pg.Children.Add($C.Files)
    [void]$compose.Children.Add($pg)
    [void]$right.Children.Add($compose)

    $hs = [System.Windows.Controls.GridSplitter]::new()
    $hs.Height = 6
    $hs.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Stretch
    $hs.Background = [System.Windows.Media.Brushes]::Transparent
    [System.Windows.Controls.Grid]::SetRow($hs, 1)
    [void]$right.Children.Add($hs)

    # the queue: the jobs, and the one picked in full beside them
    $qg = [System.Windows.Controls.Grid]::new()
    $qg.Margin = [System.Windows.Thickness]::new(4, 0, 12, 4)
    [System.Windows.Controls.Grid]::SetRow($qg, 2)
    foreach ($cw in 0, 8, 340) { $cd = [System.Windows.Controls.ColumnDefinition]::new(); $cd.Width = & $gl $cw; $qg.ColumnDefinitions.Add($cd) }
    $ql = [System.Windows.Controls.DockPanel]::new()
    $qh = New-ChatOverlayText 'Queue - open jobs and the last day''s' 'dim' 11.5
    $qh.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
    [System.Windows.Controls.DockPanel]::SetDock($qh, [System.Windows.Controls.Dock]::Top)
    [void]$ql.Children.Add($qh)
    $qs = [System.Windows.Controls.ScrollViewer]::new()
    $qs.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
    $C.Queue = [System.Windows.Controls.StackPanel]::new()
    $qs.Content = $C.Queue
    [void]$ql.Children.Add($qs)
    [void]$qg.Children.Add($ql)
    $ds = [System.Windows.Controls.ScrollViewer]::new()
    $ds.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
    [System.Windows.Controls.Grid]::SetColumn($ds, 2)
    $C.Details = [System.Windows.Controls.StackPanel]::new()
    $ds.Content = $C.Details
    [void]$qg.Children.Add($ds)
    [void]$right.Children.Add($qg)

    # the status line: what the last action did, and the watcher
    $sb = [System.Windows.Controls.DockPanel]::new()
    # clear of the resize grip in the corner
    $sb.Margin = [System.Windows.Thickness]::new(12, 2, 20, 6)
    [System.Windows.Controls.Grid]::SetRow($sb, 2)
    $C.WatchText = New-ChatOverlayText '' 'faint' 11
    [System.Windows.Controls.DockPanel]::SetDock($C.WatchText, [System.Windows.Controls.Dock]::Right)
    [void]$sb.Children.Add($C.WatchText)
    $C.Status = New-ChatOverlayText '' 'dim' 11.5 -Trim
    [void]$sb.Children.Add($C.Status)
    [void]$root.Children.Add($sb)
    $C.Root = $frame

    $C.Sigs = @{}
    $C.WhenBox = $null
    Update-ChatConsoleTarget $H
    Update-ChatConsoleFiles $H
    if ($H.Mode -eq 'console') {
        # the new look in the window at once; the keyboard back in the box
        $H.Win.Content = $frame
        Update-ChatConsole $H
        if ($H.Win.IsActive) { [void]$C.Prompt.Focus() }
    }
}

function Get-ChatConsoleMaxLabel {
    # the header's maximize button's words: what a click does. Pure.
    param([bool]$Max)
    if ($Max) { return "$([char]0x2750) Restore" }
    return "$([char]0x25A1) Maximize"
}

function Set-ChatConsoleMax {
    <#
    The console maximized - the working area of the screen it is on, the
    taskbar left clear - or back to the size and place it had. Done by
    hand, not by WindowState: the panel's window has no frame
    (AllowsTransparency, WindowStyle None), and WPF maximizes such a window
    over the taskbar. Maximized, the grip is gone and the header does not
    move it. -NoSave: the state is not written - Enter-ChatOverlayConsoleMode
    putting back what console-state.json already says.
    #>
    param($H, [bool]$On, [switch]$NoSave)
    $C = $H.Con
    if (-not $C -or $H.Mode -ne 'console' -or [bool]$C.Max -eq $On) { return }
    $w = $C.Win
    # Windows' own maximize (Win+Up, the taskbar's menu) undone first: the
    # rect read after it is the size the console had, so a Restore - and
    # the save before the maximize - keep that, never the full screen
    if ($w.WindowState -ne [System.Windows.WindowState]::Normal) { $w.WindowState = [System.Windows.WindowState]::Normal }
    $r = [ChatOverlayNative]::GetRect($C.Hwnd)
    if (-not $r) { return }
    $px = Get-ChatOverlayScale $H $r -Device
    if ($On) {
        # the size it has now kept first: it is the one a restore, or the
        # next start, gives back
        if (-not $NoSave) { Save-ChatConsoleDraft $H }
        $C.Restore = $r
        $a = Get-ChatOverlayWorkArea $r
        $at = @([int]$a.X, [int]$a.Y, [int]$a.Width, [int]$a.Height)
        $w.ResizeMode = [System.Windows.ResizeMode]::NoResize
    }
    else {
        $at = if ($C.Restore) { $C.Restore } else { $r }
        $C.Restore = $null
        $w.ResizeMode = [System.Windows.ResizeMode]::CanResizeWithGrip
    }
    $C.Max = $On
    $w.Width = $at[2] / $px
    $w.Height = $at[3] / $px
    [ChatOverlayNative]::Place($C.Hwnd, $at[0], $at[1], $at[2], $at[3])
    if ($C.MaxBtn) { $C.MaxBtn.Child.Text = Get-ChatConsoleMaxLabel $On }
    if (-not $NoSave) { Save-ChatConsoleDraft $H }
}

function Set-ChatConsoleStatus {
    # what the last action did, in the status line; tone warn for a refusal
    param($H, [string]$Text, [string]$Tone = 'dim')
    if (-not $H.Con -or -not $H.Con.Status) { return }
    $H.Con.Status.Text = $Text
    $H.Con.Status.Foreground = Get-ChatOverlayBrush $Tone
}

function Save-ChatConsoleDraft {
    # its size and what is being written, for the next time it opens -
    # after a restart too
    param($H)
    $C = $H.Con
    if (-not $C) { return }
    try {
        $s = $C.State
        # Its size in WPF's units, while it shows and is neither minimized
        # nor maximized - either keeps the last, the size a restore goes
        # back to. Units, not pixels: a console sized on a 150% screen holds
        # as much on a 100% one (Get-ChatConsolePlacement). Not where it is:
        # it grows from the panel's corner each time.
        if ($H.Mode -eq 'console') {
            $s.max = [bool]$C.Max
            if ($C.Win.WindowState -eq [System.Windows.WindowState]::Normal -and -not $C.Max) {
                $r = [ChatOverlayNative]::GetRect($C.Hwnd)
                if ($r -and $r[2] -gt 0 -and $r[3] -gt 0) {
                    $px = Get-ChatOverlayScale $H $r -Device
                    $s.w = [Math]::Round($r[2] / $px)
                    $s.h = [Math]::Round($r[3] / $px)
                    $s.units = $true
                }
            }
        }
        if ($C.LeftCol -and $C.LeftCol.ActualWidth -gt 0) { $s.left = [Math]::Round($C.LeftCol.ActualWidth) }
        if ($C.QueueRow -and $C.QueueRow.ActualHeight -gt 0) { $s.queue = [Math]::Round($C.QueueRow.ActualHeight) }
        $t = $C.Target
        $s.draft = [pscustomobject]@{
            target = $(if ($t) { [pscustomobject]@{ Kind = $t.Kind; Id = $t.Id; Provider = $t.Provider; Title = $t.Title; Project = $t.Project; Cwd = $t.Cwd; Path = $t.Path } } else { $null })
            text = $(if ($C.Prompt) { $C.Prompt.Text } else { $C.Text })
            files = @($C.Staged | Where-Object { -not $_.Error -and -not $_.Task } | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Path = $_.Path; Dir = $_.Dir; Size = $_.Size } })
            when = $C.When; whenValue = $(if ($C.WhenBox) { $C.WhenBox.Text } else { $C.WhenValue }); mode = $C.Mode; model = $C.Model; sandbox = $C.Sandbox
            newCwd = $(if ($C.FolderBox) { $C.FolderBox.Text } else { $C.NewCwd }); newName = $(if ($C.NameBox) { $C.NameBox.Text } else { $C.NewName })
        }
        New-ChatqDir $script:ChatqData
        Save-ChatqJson $script:ChatConsoleStatePath $s
        $C.Dirty = $null
    }
    catch { Write-ChatOverlayLog "console state: $($_.Exception.Message)" }
}

function Restore-ChatConsoleDraft {
    # the draft console-state.json kept; staged files it no longer names -
    # left by a crash, or sent - are swept from data/console/draft
    param($H)
    $C = $H.Con
    $d = $C.State.draft
    $keep = @{}
    if ($d) {
        if ($d.target) { $C.Target = @{ Kind = $d.target.Kind; Id = $d.target.Id; Provider = $d.target.Provider; Title = $d.target.Title; Project = $d.target.Project; Cwd = $d.target.Cwd; Path = $d.target.Path; Live = $null } }
        $C.Text = [string]$d.text
        foreach ($f in @($d.files)) {
            if ($f -and $f.Path -and (Test-Path -LiteralPath $f.Path)) {
                $C.Staged.Add(@{ Name = $f.Name; Path = $f.Path; Dir = $f.Dir; Size = [int64]$f.Size; Task = $null; Error = $null })
                $keep[([string]$f.Dir).ToLowerInvariant()] = $true
            }
        }
        # 'now' is a draft from before Next had its name
        if ($d.when) { $C.When = if ([string]$d.when -eq 'now') { 'next' } else { [string]$d.when } }
        $C.WhenValue = [string]$d.whenValue
        $C.Mode = [string]$d.mode
        $C.Model = [string]$d.model
        # a draft from before the Sandbox chips has none
        $C.Sandbox = [string](Get-ChatField $d 'sandbox')
        $C.NewCwd = [string]$d.newCwd
        $C.NewName = [string]$d.newName
    }
    if (Test-Path -LiteralPath $script:ChatConsoleDraftDir) {
        foreach ($x in @(Get-ChildItem -LiteralPath $script:ChatConsoleDraftDir -Directory -EA SilentlyContinue)) {
            if (-not $keep[$x.FullName.ToLowerInvariant()]) { Remove-Item -LiteralPath $x.FullName -Recurse -Force -EA SilentlyContinue }
        }
    }
}

function Update-ChatConsole {
    # after every collector pass while it shows: each part redrawn only when
    # what it shows changed
    param($H)
    $C = $H.Con
    # Only while the window shows the console - it is the panel's, and
    # shows the panel the rest of the time. Minimized, nobody sees it:
    # nothing drawn until it is restored.
    if (-not $C -or $H.Mode -ne 'console' -or $C.Modal -or $C.Win.WindowState -eq [System.Windows.WindowState]::Minimized) { return }
    try {
        Update-ChatConsoleIndex $H
        Update-ChatConsoleStaging $H
        $jsig = [string]$H.Ctx.JobsSig
        if ($jsig -ne $C.JobsSig) { $C.JobsSig = $jsig; $C.Jobs = @(Get-ChatqJobs) }
        Update-ChatConsoleHeader $H
        Update-ChatConsoleChats $H
        Update-ChatConsoleQueue $H
        Update-ChatConsolePreview $H
        Update-ChatConsoleWatcher $H
        if ($C.Dirty -and ((Get-Date) - $C.Dirty).TotalSeconds -ge 1) { Save-ChatConsoleDraft $H }
    }
    catch { Write-ChatOverlayLog "console: $($_.Exception.Message) @ $(($_.ScriptStackTrace -split "`n")[0])" }
}

function Update-ChatConsoleIndex {
    # The chats the index knows, for Recent and the search: read when the
    # window first shows and again whenever the file changes - each time in
    # a runspace of its own, never on this thread - and brought up to date
    # by a hidden PowerShell every 10 minutes, since Sync-ChatIndex reads
    # transcripts.
    param($H)
    $C = $H.Con
    $C.IndexParsed = $true
    $stamp = Get-ChatIndexStamp
    if ($stamp -and $stamp -ne $C.IndexStamp) { Start-ChatConsoleIndexRead $H $stamp }
    if ($C.Sync) {
        if ($C.Sync.HasExited) { try { $C.Sync.Dispose() } catch {}; $C.Sync = $null }
        return
    }
    if ($script:ChatConsoleNoSync) { return }
    $old = try { ((Get-Date) - [System.IO.File]::GetLastWriteTime($script:ChatIndexPath)).TotalMinutes -ge 10 } catch { $true }
    if ($old -and ((Get-Date) - $C.SyncAt).TotalMinutes -ge 10) { Start-ChatConsoleIndexSync $H }
}

function Start-ChatConsoleIndexRead {
    # Get-ChatIndex's parse, in a runspace of its own: on the window's thread
    # it took 250 ms for 226 chats here, and about 2 s for 2,000, each time
    # the index changed. Starting the runspace costs this thread 10-50 ms; a
    # timer takes the rows once they are ready. One read at a time - a file
    # changed meanwhile is read on the pass after.
    param($H, [string]$Stamp)
    $C = $H.Con
    if ($C.IndexRead) { return }
    try {
        $rs = [runspacefactory]::CreateRunspace([System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2())
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($script:ChatIndexRead.ToString()).AddArgument($script:ChatIndexPath).AddArgument($script:ChatIndexSep)
        $C.IndexRead = @{ Ps = $ps; Async = $ps.BeginInvoke(); Stamp = $Stamp; At = Get-Date }
    }
    catch {
        Write-ChatOverlayLog "console: the index could not be read: $($_.Exception.Message)"
        # not tried again until the file changes
        $C.IndexStamp = $Stamp
        return
    }
    $t = [System.Windows.Threading.DispatcherTimer]::new()
    $t.Interval = [TimeSpan]::FromMilliseconds(100)
    $t.add_Tick({
            param($s, $e)
            $H = $script:ChatOverlayHost
            if (-not $H.Con.IndexRead -or $H.Con.IndexRead.Async.IsCompleted) { $s.Stop(); Complete-ChatConsoleIndexRead $H }
        })
    $t.Start()
}

function Complete-ChatConsoleIndexRead {
    # the rows a read brought back, into the console - and into Get-ChatIndex's
    # own copy while the file is still that version, so a Send does not parse
    # it again on this thread
    param($H)
    $C = $H.Con
    $r = $C.IndexRead
    if (-not $r) { return }
    $C.IndexRead = $null
    $rows = $null
    try {
        $got = $r.Ps.EndInvoke($r.Async)
        if ($r.Ps.HadErrors) { Write-ChatOverlayLog "console: the index could not be read: $(@($r.Ps.Streams.Error)[0])" }
        else { $rows = @($got) }
    }
    catch { Write-ChatOverlayLog "console: the index could not be read: $($_.Exception.Message)" }
    finally {
        try { $r.Ps.Runspace.Dispose() } catch {}
        try { $r.Ps.Dispose() } catch {}
    }
    $ms = [int]((Get-Date) - $r.At).TotalMilliseconds
    if ($ms -gt 2000) { Write-ChatOverlayLog "console: the index took $ms ms to read, off the window's thread" }
    # a file that would not parse is not read again until it changes
    $C.IndexStamp = $r.Stamp
    if ($null -eq $rows) { return }
    $C.Index = $rows
    if ($r.Stamp -and $r.Stamp -eq (Get-ChatIndexStamp)) { $script:ChatIndexCache = $rows; $script:ChatIndexStamp = $r.Stamp }
    $C.Sigs.Chats = $null
    if ($H.Mode -eq 'console') { Update-ChatConsoleChats $H }
}

function Start-ChatConsoleIndexSync {
    # Sync-ChatIndex in a hidden Windows PowerShell of its own, with this
    # process's view of where the chats are
    param($H)
    $C = $H.Con
    $C.SyncAt = Get-Date
    $path = $script:ChatqScriptPath
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return }
    $q = { param($s) "'" + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent([string]$s) + "'" }
    $pre = '$env:CHATQ_OVERLAY=''1''; '
    foreach ($n in 'CLAUDE_CONFIG_DIR', 'CODEX_HOME', 'CHAT_CODE_USER') {
        $v = [Environment]::GetEnvironmentVariable($n)
        if ($v) { $pre += "`$env:$n=$(& $q $v); " }
    }
    $cmd = "$pre. $(& $q $path); `$null = Sync-ChatIndex -Provider claude, codex"
    $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmd))
    $exe = Join-Path $(if ($env:SystemRoot) { $env:SystemRoot } else { 'C:\Windows' }) 'System32\WindowsPowerShell\v1.0\powershell.exe'
    try { $C.Sync = Start-Process -FilePath $exe -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $enc) -WindowStyle Hidden -PassThru }
    catch { Write-ChatOverlayLog "console: index sync: $($_.Exception.Message)" }
}

function Update-ChatConsoleHeader {
    param($H)
    $C = $H.Con
    $bits = @()
    foreach ($u in @($H.Snap.header.usage)) {
        if (-not $u) { continue }
        $bits += "$($u.provider) " + ((@($u.windows) | ForEach-Object { "$($_.label) $($_.percent)%" }) -join " $($script:ChatqDot) ")
    }
    # $n, not $c: PowerShell's names ignore case, and $C is the console
    $n = $H.Snap.counts
    if ($n) {
        $q = @()
        if ([int]$n.queued) { $q += "$([int]$n.queued) queued" }
        if ([int]$n.running) { $q += "$([int]$n.running) running" }
        if ($n.PSObject.Properties['cutOff'] -and [int]$n.cutOff) { $q += "$([int]$n.cutOff) cut off" }
        if ($q) { $bits += ($q -join ', ') }
    }
    $C.Header.Text = $bits -join "    $($script:ChatqDot)    "
}

function Get-ChatConsoleChatItems {
    # what the list shows: cut off first, then open in VS Code, then recent -
    # each chat once, as the snapshot and the index have it. Row is what the
    # panel's row builder draws it from (Add-ChatOverlayRow): the snapshot's
    # own row, or one made for a recent chat of the index's.
    param($H)
    $C = $H.Con
    $cut = [System.Collections.Generic.List[object]]::new()
    $open = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    foreach ($r in @($H.Snap.rows)) {
        if (-not $r -or $r.kind -notin 'session', 'cutoff' -or -not $r.sessionId) { continue }
        $path = if ($r.PSObject.Properties['path'] -and $r.path) { [string]$r.path } elseif ($H.Ctx.Text[[string]$r.sessionId]) { [string]$H.Ctx.Text[[string]$r.sessionId].Path } else { $null }
        $item = [pscustomobject]@{
            Key = "$($r.kind):$($r.sessionId)"; Kind = $(if ($r.status -eq 'cutoff') { 'cutoff' } else { 'open' }); Provider = 'claude'; Id = [string]$r.sessionId
            Title = [string]$r.title; Project = [string]$r.project; Cwd = [string]$r.cwd; Path = $path; State = [string]$r.stateText
            Status = [string]$r.status; Live = $(if ($r.kind -eq 'session') { [string]$r.chat } else { $null }); Row = $r
        }
        $seen[$item.Id] = $true
        if ($item.Kind -eq 'cutoff') { $cut.Add($item) } else { $open.Add($item) }
    }
    # The reset ask runs with overlay.cutOff off too, and its balloon says
    # "Click to see them" and opens this: with the rows off, its chats come
    # from the ask itself - else the list, its Leave them and Continue all,
    # would be empty. With them on, the ask's chats are rows already.
    $rowsOff = $H.Ctx -and $H.Ctx.Config -and (Get-ChatField $H.Ctx.Config 'cutOff') -eq $false
    foreach ($askItem in @(if ($rowsOff -and $H.Ctx.Ask) { @($H.Ctx.Ask.Items) })) {
        $id = [string](Get-ChatField $askItem 'Id')
        if (-not $id -or $seen[$id]) { continue }
        $words = try { Format-ChatOverlayCutOff $askItem } catch { 'cut off' }
        $cwd = [string](Get-ChatField $askItem 'Cwd')
        $leaf = if ($cwd) { Split-Path $cwd.TrimEnd('\', '/') -Leaf } else { '' }
        $title = Format-ChatTitle ([string](Get-ChatField $askItem 'Title')) 80
        $row = [pscustomobject]@{
            key = "c:$id"; kind = 'cutoff'; provider = 'claude'; status = 'cutoff'; chat = 'cutoff'; rank = 0.5; project = $leaf; title = $title
            prompt = $null; promptKind = $null; detail = $words; since = $null; sessionId = $id; pids = @(); cwd = $cwd; job = $null; order = 0
            stateText = $words; path = [string](Get-ChatField $askItem 'Path'); where = ''; unread = $false
        }
        $cut.Add([pscustomobject]@{
                Key = "cutoff:$id"; Kind = 'cutoff'; Provider = 'claude'; Id = $id; Title = $title; Project = $leaf; Cwd = $cwd; Path = $row.path
                State = $words; Status = 'cutoff'; Live = $null; Row = $row
            })
        $seen[$id] = $true
    }
    # The index's chats newest first, sorted once per version of the index -
    # not every pass: that walked every row of it, 1 s for 2,000 chats. Each
    # pass takes only the first 30 (50 when searching) that are not listed
    # above and that the search matches.
    if ($null -eq $C.Pool -or $C.PoolStamp -ne $C.IndexStamp) {
        $C.Pool = @($C.Index | Where-Object { $_.Provider -in 'claude', 'codex' -and -not $_.Hidden -and $_.Title -and $_.Title -ne '(empty)' } |
                ForEach-Object { [pscustomobject]@{ Row = $_; When = (ConvertTo-ChatqDate $_.When); Hay = ([string]$_.Title).ToLowerInvariant() } } |
                Sort-Object { if ($_.When) { $_.When } else { [datetime]::MinValue } } -Descending)
        $C.PoolStamp = $C.IndexStamp
    }
    $words = @(([string]$C.Search).ToLowerInvariant() -split '\s+' | Where-Object { $_ })
    $max = if ($words) { 50 } else { 30 }
    $recent = [System.Collections.Generic.List[object]]::new()
    foreach ($x in $C.Pool) {
        if ($recent.Count -ge $max) { break }
        $r = $x.Row
        if ($seen[[string]$r.Id]) { continue }
        $all = $true
        foreach ($w in $words) { if (-not $x.Hay.Contains($w)) { $all = $false; break } }
        if (-not $all) { continue }
        $state = "$($r.Provider)$(if ($x.When) { " $($script:ChatqDot) $(Get-ChatAge $x.When)" })"
        # the shape the panel's Recent rows have (Update-ChatOverlayRecent):
        # kind and status recent, so the builder draws it faint and compact
        $row = [pscustomobject]@{
            key = "recent:$($r.Id)"; kind = 'recent'; provider = [string]$r.Provider; status = 'recent'; rank = $null
            project = ''; title = [string]$r.Title; sessionId = [string]$r.Id; stateText = $state; prompt = $null
        }
        $recent.Add([pscustomobject]@{
                Key = "recent:$($r.Id)"; Kind = 'recent'; Provider = [string]$r.Provider; Id = [string]$r.Id; Title = [string]$r.Title
                Project = ''; Cwd = $null; Path = [string]$r.Path; State = $state; Status = 'recent'; Live = $null; Row = $row
            })
    }
    return [pscustomobject]@{ CutOff = $cut.ToArray(); Open = $open.ToArray(); Recent = $recent.ToArray() }
}

function Update-ChatConsoleChats {
    param($H)
    $C = $H.Con
    if (-not $C.Chats) { return }
    $all = Get-ChatConsoleChatItems $H
    $cut = @(Select-ChatConsoleChats $all.CutOff $C.Search)
    $open = @(Select-ChatConsoleChats $all.Open $C.Search)
    # searched and cut to length as it was gathered
    $recent = @($all.Recent)
    $sel = if ($C.Target) { "$($C.Target.Kind)|$($C.Target.Id)|$($C.Target.Cwd)" } else { '' }
    # A pending ask about the chats the limit cut off: said in the Cut off
    # header, with Leave them beside Continue all.
    $ask = $H.Ctx.Ask
    $askSays = ''
    if ($ask) { $askSays = " $($script:ChatqDot) $(Format-ChatqAskHead $ask) - $([int]$ask.Count) can continue" }
    # how many of them auto-continue will continue (src/auto-continue.ps1)
    $autoN = @($cut | Where-Object { (Get-ChatField $_.Row 'auto') -and $_.Row.auto.state -in 'armed', 'due' }).Count
    if ($autoN) { $askSays += " $($script:ChatqDot) $autoN auto-continue$(if ($autoN -eq 1) { 's' })" }
    # what a row shows beyond its words: its dot, where it runs, unread, and
    # what auto-continue does with it - its button follows that
    $key = (@($cut + $open + $recent | ForEach-Object { "$($_.Key)=$($_.State)/$($_.Status)/$(Get-ChatField $_.Row 'where')/$(Get-ChatField $_.Row 'unread')/$(Get-ChatField (Get-ChatField $_.Row 'auto') 'state')" }) -join ';') + "|$sel|$askSays|$(if ($ask) { @($ask.Keys) -join ',' })"
    if ($key -eq $C.Sigs.Chats) { return }
    $C.Sigs.Chats = $key
    $C.Chats.Children.Clear()
    $C.ChatItems = @($cut + $open + $recent)
    $section = {
        param($title, $items, [scriptblock]$extra, [string]$more = '')
        if (-not $items) { return }
        $hd = [System.Windows.Controls.DockPanel]::new()
        $hd.Margin = [System.Windows.Thickness]::new(0, 8, 0, 3)
        if ($extra) { $x = & $extra; [System.Windows.Controls.DockPanel]::SetDock($x, [System.Windows.Controls.Dock]::Right); [void]$hd.Children.Add($x) }
        $tb = New-ChatOverlayText "$title ($(@($items).Count))$more" 'dim' 11.5 -Bold -Trim
        $tb.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        [void]$hd.Children.Add($tb)
        [void]$C.Chats.Children.Add($hd)
        foreach ($i in $items) { [void]$C.Chats.Children.Add((New-ChatConsoleChatItem $H $i)) }
    }
    $cutButtons = {
        # a chat a VS Code restart cut off gets a prompt that says what it
        # ended (Invoke-ChatConsoleContinue), and the tooltip says so
        $rn = @($cut | Where-Object { Test-ChatConsoleRestartItem $H $_ }).Count
        $all = New-ChatConsoleButton 'Continue all' { Invoke-ChatConsoleContinue $script:ChatOverlayHost @($script:ChatOverlayHost.Con.ChatItems | Where-Object { $_.Kind -eq 'cutoff' }) } -Small `
            -Tip "$(Format-ChatqContinueTip @($cut).Count $rn), ahead of the prompts waiting - the watcher runs one job at a time, so they go one after another, in this list's order. When, under the prompt, is for Send only"
        if (-not $ask) { return $all }
        # the ask's own keys, as drawn: the answer is for the chats it said
        $leave = New-ChatConsoleButton 'Leave them' { param($s, $e) $e.Handled = $true; Invoke-ChatOverlayAskAnswer $script:ChatOverlayHost 'leave' @($s.Tag) } -Small -Tag @($ask.Keys) -Tip (Format-ChatqAskLeaveTip $ask)
        $both = [System.Windows.Controls.StackPanel]::new()
        $both.Orientation = [System.Windows.Controls.Orientation]::Horizontal
        [void]$both.Children.Add($leave)
        [void]$both.Children.Add($all)
        return $both
    }
    & $section 'Cut off' $cut $cutButtons $askSays
    & $section 'Open in VS Code' $open $null
    & $section 'Recent' $recent $null
    if (-not ($cut -or $open -or $recent)) {
        [void]$C.Chats.Children.Add((New-ChatOverlayText $(if ($C.Search) { 'no chat matches' } elseif (-not $C.Index -and ($C.IndexRead -or -not $C.IndexParsed)) { 'reading the chats...' } else { 'no chats' }) 'faint' 12))
    }
}

function New-ChatConsoleChatItem {
    <#
    One chat in the list, drawn as the panel draws it (Add-ChatOverlayRow,
    compact: no prompt line) - the dot, where it runs, project and title,
    its state, the unread dot - so a chat looks the same in both. Around
    it, what only the console has: a click makes it the one written to, the
    one picked has the accent's bar at its left on the selection's colour,
    and a cut-off chat has Continue at the right.
    #>
    param($H, $Item)
    $C = $H.Con
    $b = [System.Windows.Controls.Border]::new()
    $b.CornerRadius = [System.Windows.CornerRadius]::new(4)
    $b.Padding = [System.Windows.Thickness]::new(5, 2, 6, 2)
    # the bar is always there, see-through when not picked: the row does not
    # move as it is picked
    $b.BorderThickness = [System.Windows.Thickness]::new(2, 0, 0, 0)
    $b.Cursor = [System.Windows.Input.Cursors]::Hand
    $b.Tag = $Item
    $on = $C.Target -and $C.Target.Kind -ne 'new' -and $C.Target.Id -eq $Item.Id
    $b.Background = if ($on) { Get-ChatOverlayBrush 'select' } else { [System.Windows.Media.Brushes]::Transparent }
    $b.BorderBrush = if ($on) { Get-ChatOverlayBrush 'accent' } else { [System.Windows.Media.Brushes]::Transparent }
    $g = [System.Windows.Controls.DockPanel]::new()
    # a continue auto-continue queued waits: Don't continue, one click -
    # Continue undoes it (src/auto-continue.ps1)
    $au = Get-ChatField $Item.Row 'auto'
    if ($Item.Kind -eq 'cutoff' -and $au -and $au.state -in 'armed', 'due') {
        $cb = New-ChatConsoleButton "Don't continue" { param($s, $e) $e.Handled = $true; Invoke-ChatConsoleDontContinue $script:ChatOverlayHost ([string]$s.Tag.Row.auto.jobId) ([string]$s.Tag.Id) } -Small -Tag $Item `
            -Tip $(if ([string](Get-ChatField $au 'cutWhy') -eq 'overloaded') { "$($au.long). Don't send ""continue"" to this chat for this 529; the next time it is cut off, it is continued again." }
                else { "$($au.long). Don't send ""continue"" to this chat after this reset; the next time the limit cuts it off, it is continued again." })
        $cb.Margin = [System.Windows.Thickness]::new(6, 0, 0, 0)
        [System.Windows.Controls.DockPanel]::SetDock($cb, [System.Windows.Controls.Dock]::Right)
        [void]$g.Children.Add($cb)
    }
    elseif ($Item.Kind -eq 'cutoff') {
        $cb = New-ChatConsoleButton 'Continue' { param($s, $e) $e.Handled = $true; Invoke-ChatConsoleContinue $script:ChatOverlayHost @($s.Tag) } -Small -Tag $Item `
            -Tip "$(Format-ChatqContinueTip 1 $(if (Test-ChatConsoleRestartItem $H $Item) { 1 } else { 0 })), ahead of the prompts waiting"
        $cb.Margin = [System.Windows.Thickness]::new(6, 0, 0, 0)
        [System.Windows.Controls.DockPanel]::SetDock($cb, [System.Windows.Controls.Dock]::Right)
        [void]$g.Children.Add($cb)
    }
    $txt = [System.Windows.Controls.StackPanel]::new()
    Add-ChatOverlayRow $txt $Item.Row ([pscustomobject]@{ prompts = $false })
    [void]$g.Children.Add($txt)
    $b.Child = $g
    $b.add_MouseEnter({ param($s, $e) if ($s.Background -eq [System.Windows.Media.Brushes]::Transparent) { $s.Background = Get-ChatOverlayBrush 'hover' } })
    $b.add_MouseLeave({ param($s, $e) $H = $script:ChatOverlayHost; $t = $H.Con.Target; if (-not ($t -and $t.Kind -ne 'new' -and $t.Id -eq $s.Tag.Id)) { $s.Background = [System.Windows.Media.Brushes]::Transparent } })
    $b.add_MouseLeftButtonUp({ param($s, $e) Select-ChatConsoleTarget $script:ChatOverlayHost $s.Tag })
    return $b
}

function Select-ChatConsoleTarget {
    # the chat Send goes to
    param($H, $Item)
    $C = $H.Con
    $C.Target = @{ Kind = 'chat'; Id = $Item.Id; Provider = $Item.Provider; Title = $Item.Title; Project = $Item.Project; Cwd = $Item.Cwd; Path = $Item.Path; Live = $Item.Live }
    $C.Sigs.Chats = $null
    $C.Dirty = Get-Date
    Update-ChatConsoleTarget $H
    Update-ChatConsoleChats $H
    [void]$C.Prompt.Focus()
}

function Select-ChatConsoleNew {
    param($H)
    $C = $H.Con
    $cwd = if ($C.FolderBox -and $C.FolderBox.Text) { $C.FolderBox.Text } elseif (@($C.State.folders).Count) { [string]@($C.State.folders)[0] } else { '' }
    $C.Target = @{ Kind = 'new'; Id = $null; Provider = 'claude'; Title = $null; Project = $null; Cwd = $cwd; Path = $null; Live = $null }
    if ($C.FolderBox) { $C.FolderBox.Text = $cwd }
    $C.Sigs.Chats = $null
    $C.Dirty = Get-Date
    Update-ChatConsoleTarget $H
    Update-ChatConsoleChats $H
    [void]$C.FolderBox.Focus()
}

function Get-ChatConsoleRow {
    # the index's row for the chat picked, and what the run needs to know of
    # it - read once per version of its transcript
    param($H, $Target)
    $row = Get-ChatqRowById $Target.Id $Target.Provider $Target.Path $Target.Cwd
    if (-not $row) { return $null }
    $len = try { ([System.IO.FileInfo]::new($row.Path)).Length } catch { 0 }
    $k = "$($row.Path)|$len"
    $info = $H.Con.Info[$k]
    if (-not $info) { $info = Get-ChatqJobInfo $row; $H.Con.Info[$k] = $info }
    return [pscustomobject]@{ Row = $row; Info = $info }
}

function Update-ChatConsoleTarget {
    # the To line - or a new chat's folder and name - and the choices
    param($H)
    $C = $H.Con
    $C.To.Children.Clear()
    $t = $C.Target
    $isNew = $t -and $t.Kind -eq 'new'
    $C.NewBox.Visibility = if ($isNew) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    $line = [System.Windows.Controls.TextBlock]::new()
    $line.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
    $add = { param($x, $tone, [switch]$b) $r = [System.Windows.Documents.Run]::new($x); $r.Foreground = Get-ChatOverlayBrush $tone; if ($b) { $r.FontWeight = [System.Windows.FontWeights]::SemiBold }; $line.Inlines.Add($r) }
    & $add 'To  ' 'faint'
    $sub = ''
    if (-not $t) { & $add 'pick a chat on the left, or + New chat' 'dim' }
    elseif ($isNew) {
        & $add 'a new Claude chat' 'text' -b
        $sub = 'it starts in the folder below, in default mode unless you pick another'
        $C.Recent.Children.Clear()
        foreach ($f in @($C.State.folders | Select-Object -First 6)) {
            if (-not $f) { continue }
            [void]$C.Recent.Children.Add((New-ChatConsoleButton (Split-Path ([string]$f).TrimEnd('\', '/') -Leaf) { param($s, $e) $s.Tag.Text = [string]$s.ToolTip } -Small -Tip ([string]$f) -Tag $C.FolderBox))
        }
    }
    else {
        if ($t.Project) { & $add "$($t.Project)  " 'project' -b }
        & $add ([string]$t.Title) 'text' -b
        $got = try { Get-ChatConsoleRow $H $t } catch { $null }
        if (-not $got) { $sub = Get-ChatConsoleMissingSay $t }
        elseif ($got.Info.Error) { $sub = [string]$got.Info.Error }
        else {
            $t.Cwd = $got.Info.Cwd
            $t.Mode = $got.Info.Mode
            $sub = "$($got.Row.Provider) $($script:ChatqDot) $($got.Info.Mode) as it last ran $($script:ChatqDot) $($got.Info.Cwd)"
        }
    }
    [void]$C.To.Children.Add($line)
    if ($sub) { [void]$C.To.Children.Add((New-ChatOverlayText $sub 'faint' 11 -Trim)) }
    # this chat's auto-continue: Default, Always, Never (src/auto-continue.ps1)
    try { Add-ChatConsoleAutoLine $H } catch { Write-ChatOverlayLog "console: auto-continue: $($_.Exception.Message)" }
    Update-ChatConsoleOptions $H
}

function Update-ChatConsoleOptions {
    # When, mode and model, as chips
    param($H)
    $C = $H.Con
    if ($C.WhenBox) { $C.WhenValue = $C.WhenBox.Text }
    $C.Opts.Children.Clear()
    $row = {
        param($label, $chips, $extra)
        $d = [System.Windows.Controls.DockPanel]::new()
        $l = New-ChatOverlayText $label 'dim' 12
        $l.Width = 52
        $l.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        [System.Windows.Controls.DockPanel]::SetDock($l, [System.Windows.Controls.Dock]::Left)
        [void]$d.Children.Add($l)
        if ($extra) { [System.Windows.Controls.DockPanel]::SetDock($extra, [System.Windows.Controls.Dock]::Right); [void]$d.Children.Add($extra) }
        [void]$d.Children.Add($chips)
        [void]$C.Opts.Children.Add($d)
    }
    $wb = $null
    if ($C.When -in 'at', 'in') {
        $wb = New-ChatConsoleInput -Tip $(if ($C.When -eq 'at') { 'a time: 13:00, or 2026-10-01 09:00' } else { 'how long from now: 90m, 2h, 1d' })
        $wb.Width = 150
        $wb.Text = $C.WhenValue
        $wb.add_TextChanged({ $H = $script:ChatOverlayHost; $H.Con.WhenValue = $H.Con.WhenBox.Text; $H.Con.Dirty = Get-Date; Update-ChatConsolePreview $H })
    }
    $C.WhenBox = $wb
    $whenTips = @(
        'At the front of the queue: it goes next - within seconds, or once the job running now ends'
        'Behind what is queued - the continues, then the prompts waiting'
        'Not before a time of day: 13:00'
        'Not before so long from now: 90m, 2h, 1d'
    )
    & $row 'When' (New-ChatConsoleChips @('next', 'turn', 'at', 'in') @('Next', 'In turn', 'At', 'In') $C.When {
            param($s, $e) $H = $script:ChatOverlayHost; $H.Con.When = [string]$s.Tag; $H.Con.Dirty = Get-Date; Update-ChatConsoleOptions $H
            if ($H.Con.WhenBox) { [void]$H.Con.WhenBox.Focus() }
        } -Tips $whenTips) $wb
    $isNew = $C.Target -and $C.Target.Kind -eq 'new'
    if ($C.Target -and $C.Target.Provider -eq 'codex') {
        # A Codex chat's mode is its sandbox: the three words codex takes, or
        # the one it last ran in. Claude's modes and models are not offered,
        # and are never sent with it; it runs on its own model.
        & $row 'Sandbox' (New-ChatConsoleChips (@('') + $script:ChatqCodexSandboxes) @('as it ran', 'read-only', 'workspace-write', 'full access') $C.Sandbox {
                param($s, $e) $H = $script:ChatOverlayHost; $H.Con.Sandbox = [string]$s.Tag; $H.Con.Dirty = Get-Date; Update-ChatConsoleOptions $H
            } -Tips @('The sandbox the chat last ran in', 'It can read, not edit', 'It edits in its folder', 'No sandbox at all')) $null
        $own = [string]$C.Target.Mode
        $hint = switch ($(if ($C.Sandbox) { $C.Sandbox } else { $own })) {
            'read-only' { 'read-only can read, not edit' }
            'danger-full-access' { 'full access runs everything with no sandbox, and nobody is there to stop it' }
            default { $null }
        }
        # a pick other than the chat's own stays with it after the run; a
        # chat whose own is not known yet (its row did not load) says nothing
        if (Get-ChatqCodexStickSay $own $C.Sandbox) { $hint = if ($hint) { "$hint - and it sticks: later jobs run in it too" } else { "it sticks: later jobs for this chat run in $($C.Sandbox) too, not $own" } }
        foreach ($x in @($hint, 'it runs on the model it last used')) {
            if (-not $x) { continue }
            $cx = New-ChatOverlayText $x 'faint' 11 -Trim
            $cx.Margin = [System.Windows.Thickness]::new(52, 1, 0, 0)
            [void]$C.Opts.Children.Add($cx)
        }
        Update-ChatConsolePreview $H
        return
    }
    $asRan = if ($isNew) { 'default' } else { 'as it ran' }
    & $row 'Mode' (New-ChatConsoleChips (@('') + $script:ChatConsoleModes) (@($asRan) + $script:ChatConsoleModes) $C.Mode {
            param($s, $e) $H = $script:ChatOverlayHost; $H.Con.Mode = [string]$s.Tag; $H.Con.Dirty = Get-Date; Update-ChatConsoleOptions $H
        }) $null
    & $row 'Model' (New-ChatConsoleChips (@('') + $script:ChatConsoleModels) (@($(if ($isNew) { 'default' } else { 'its own' })) + $script:ChatConsoleModels) $C.Model {
            param($s, $e) $H = $script:ChatOverlayHost; $H.Con.Model = [string]$s.Tag; $H.Con.Dirty = Get-Date; Update-ChatConsoleOptions $H
        }) $null
    # what the mode means for a run with nobody there to answer
    $m = if ($C.Mode) { $C.Mode } elseif ($isNew) { 'default' } elseif ($C.Target) { [string]$C.Target.Mode } else { '' }
    $hint = switch ($m) {
        'plan' { 'plan mode stops at a plan - auto lets it act' }
        'bypassPermissions' { 'bypassPermissions runs everything without asking' }
        { $_ -in 'default', 'manual' } { 'anything that would ask is denied unattended - acceptEdits or auto lets it edit' }
        default { $null }
    }
    if ($hint) {
        $ht = New-ChatOverlayText $hint 'faint' 11 -Trim
        $ht.Margin = [System.Windows.Thickness]::new(52, 1, 0, 0)
        [void]$C.Opts.Children.Add($ht)
    }
    Update-ChatConsolePreview $H
}

function Get-ChatConsoleBlock {
    <#
    The provider's limit, for the preview, from what the collector already
    holds: the watcher's blocks while jobs wait, a usage window marked
    limited, and the latest reset among the chats the limit cut off. Nothing
    is read here: Get-ChatqBlocks with no watcher running scans the
    transcripts, which stalled the window for half a second each minute.
    #>
    param($H, [string]$Provider)
    $p = if ($Provider) { $Provider } else { 'claude' }
    $now = Get-Date
    $b = $H.Ctx.Blocks
    if ($b -and $b.Count) {
        foreach ($k in @($b.Keys)) {
            # Why: what the watcher kept of it - for a refused login, the CLI's words
            if (($k -eq $p -or $k -like "$p|*") -and $b[$k].Until) { return [pscustomobject]@{ Until = $b[$k].Until; Type = [string]$b[$k].Type; Why = [string]$b[$k].Source } }
        }
    }
    $name = if ($p -eq 'codex') { 'Codex' } else { 'Claude' }
    $u = @($H.Snap.header.usage | Where-Object { $_ -and $_.provider -eq $name })[0]
    foreach ($w in @($u.windows)) {
        if (-not $w -or -not $w.limited -or -not $w.resetsAt) { continue }
        $until = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$w.resetsAt).LocalDateTime
        if ($until -gt $now) { return [pscustomobject]@{ Until = $until; Type = [string]$w.label } }
    }
    if ($p -eq 'claude') {
        # one account, one limit: the chats it stopped wait for its latest reset
        $cut = @($H.Ctx.CutOff | Where-Object { $_.Why -eq 'limit' -and $_.ResetsAt -and $_.ResetsAt -gt $now } | Sort-Object ResetsAt -Descending)[0]
        if ($cut) { return [pscustomobject]@{ Until = $cut.ResetsAt; Type = 'limit' } }
    }
    return $null
}

function Update-ChatConsolePreview {
    param($H)
    $C = $H.Con
    if (-not $C.Preview) { return }
    $plan = ConvertFrom-ChatConsoleWhen $C.When $(if ($C.WhenBox) { $C.WhenBox.Text } else { $C.WhenValue })
    $t = $C.Target
    if ($t -and $t.Kind -eq 'chat') {
        # open in VS Code now, or not: as the collector last saw it
        $r = @($H.Snap.rows | Where-Object { $_ -and $_.kind -eq 'session' -and $_.sessionId -eq $t.Id })[0]
        $t.Live = if ($r) { [string]$r.chat } else { $null }
    }
    $prov = if ($t) { $t.Provider } else { 'claude' }
    $ahead = @($C.Jobs | Where-Object { $_.state -eq 'queued' -and $_.provider -eq $prov }).Count
    $run = @($C.Jobs | Where-Object { $_.state -eq 'running' })[0]
    $text = Get-ChatConsoleSendPreview $t $plan (Get-ChatConsoleBlock $H $prov) $ahead ([bool]$H.Ctx.Watcher) -Running $(if ($run) { [int]$run.seq } else { 0 })
    $C.Preview.Text = $text
    $C.Preview.Foreground = Get-ChatOverlayBrush $(if ($plan.Error -or -not $t) { 'warn' } else { 'dim' })
    $C.SendBtn.Child.Text = if ($C.When -eq 'next') { 'Send' } else { 'Queue' }
}

function Update-ChatConsoleWatcher {
    param($H)
    $C = $H.Con
    $queued = [bool](@($C.Jobs | Where-Object { $_.state -eq 'queued' }).Count)
    if ($C.Request) {
        switch (Test-ChatqWatcherRequest $C.Request $queued) {
            'up' { $C.Request = $null }
            'failed' { $C.Request = $null; Set-ChatConsoleStatus $H 'the watcher did not start - chatqrun -Foreground in a shell shows why' 'warn' }
        }
    }
    $C.WatchText.Text = if ($C.Request) { 'starting the watcher...' } elseif ($H.Ctx.Watcher) { 'watcher running' } elseif ($queued) { 'watcher stopped - jobs wait' } else { 'watcher idle' }
}

function Get-ChatConsoleClipboard {
    # what a paste would bring: files copied in Explorer, or an image - a
    # PNG as the snipping tool writes it, else the bitmap - or $null for
    # text, which the box pastes itself
    if ($script:ChatConsoleClipboardSeam) { return (& $script:ChatConsoleClipboardSeam) }
    try {
        if ([System.Windows.Clipboard]::ContainsFileDropList()) { return [pscustomobject]@{ Files = @([System.Windows.Clipboard]::GetFileDropList()); Image = $null } }
        # text wins: cells copied from Excel bring a picture of themselves
        # along, a screenshot brings no text
        if ([System.Windows.Clipboard]::ContainsText()) { return $null }
        if ([System.Windows.Clipboard]::ContainsData('PNG')) {
            $st = [System.Windows.Clipboard]::GetData('PNG')
            if ($st -is [System.IO.Stream]) { $ms = [System.IO.MemoryStream]::new(); $st.CopyTo($ms); return [pscustomobject]@{ Files = @(); Image = $ms.ToArray() } }
        }
        if ([System.Windows.Clipboard]::ContainsImage()) {
            $img = [System.Windows.Clipboard]::GetImage()
            $enc = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
            $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($img))
            $ms = [System.IO.MemoryStream]::new()
            $enc.Save($ms)
            return [pscustomobject]@{ Files = @(); Image = $ms.ToArray() }
        }
    }
    catch { Write-ChatOverlayLog "console: clipboard: $($_.Exception.Message)" }
    return $null
}

function Invoke-ChatConsolePaste {
    param($H, $Clip)
    if (@($Clip.Files).Count) { Add-ChatConsoleDrop $H @($Clip.Files) }
    if ($Clip.Image) { Add-ChatConsoleImage $H ([byte[]]$Clip.Image) }
}

function Add-ChatConsoleDrop {
    # what was dropped or pasted: files go with the prompt; a folder names a
    # new chat's folder, or is turned away
    param($H, [string[]]$Paths)
    $C = $H.Con
    $files = @()
    foreach ($p in @($Paths)) {
        if (Test-Path -LiteralPath $p -PathType Container) {
            if ($C.Target -and $C.Target.Kind -eq 'new') { $C.FolderBox.Text = $p }
            else { Set-ChatConsoleStatus $H "$(Split-Path $p -Leaf) is a folder - only files go with a prompt" 'warn' }
            continue
        }
        if (Test-Path -LiteralPath $p -PathType Leaf) { $files += $p }
    }
    if ($files) { Add-ChatConsoleFiles $H $files }
}

function Add-ChatConsoleFiles {
    # Staged: copied into data/console/draft off this thread - the original
    # may move or change before the job sends - each into a folder of its
    # own so it keeps its name; Send waits for every copy.
    param($H, [string[]]$Paths)
    $C = $H.Con
    foreach ($p in @($Paths)) {
        $fi = Get-Item -LiteralPath $p -EA SilentlyContinue
        if (-not $fi -or $fi.PSIsContainer) { continue }
        $dir = Join-Path $script:ChatConsoleDraftDir ([guid]::NewGuid().ToString('N').Substring(0, 12))
        New-ChatqDir $dir
        $dest = Join-Path $dir $fi.Name
        $task = $null
        $err = $null
        try { $task = [ChatOverlayNative]::CopyFileAsync($fi.FullName, $dest) } catch { $err = $_.Exception.Message }
        $C.Staged.Add(@{ Name = $fi.Name; Path = $dest; Dir = $dir; Size = $fi.Length; Task = $task; Error = $err })
    }
    $C.Dirty = Get-Date
    Update-ChatConsoleFiles $H
}

function Add-ChatConsoleImage {
    # a pasted screenshot, kept as clip.png - clip-2.png for a second
    param($H, [byte[]]$Bytes)
    $C = $H.Con
    $n = @($C.Staged | Where-Object { $_.Name -like 'clip*.png' }).Count
    $name = if ($n) { "clip-$($n + 1).png" } else { 'clip.png' }
    $dir = Join-Path $script:ChatConsoleDraftDir ([guid]::NewGuid().ToString('N').Substring(0, 12))
    New-ChatqDir $dir
    $dest = Join-Path $dir $name
    [System.IO.File]::WriteAllBytes($dest, $Bytes)
    $C.Staged.Add(@{ Name = $name; Path = $dest; Dir = $dir; Size = [int64]$Bytes.Length; Task = $null; Error = $null })
    $C.Dirty = Get-Date
    Update-ChatConsoleFiles $H
}

function Update-ChatConsoleStaging {
    # Copies that have finished, or failed, since the last look - the draft
    # is saved again with them, or a crash now would sweep them away. A file
    # x'd out while it was still copying is deleted once the copy lets go.
    param($H)
    $C = $H.Con
    $moved = $false
    foreach ($s in @($C.Staged)) {
        if (-not $s.Task -or -not $s.Task.IsCompleted) { continue }
        if ($s.Task.IsFaulted) { $s.Error = $s.Task.Exception.GetBaseException().Message }
        $s.Task = $null
        $moved = $true
    }
    if ($C.Trash) {
        foreach ($x in @($C.Trash)) {
            if ($x.Task -and -not $x.Task.IsCompleted) { continue }
            Remove-Item -LiteralPath $x.Dir -Recurse -Force -EA SilentlyContinue
            [void]$C.Trash.Remove($x)
        }
    }
    if ($moved) { $C.Dirty = Get-Date; Update-ChatConsoleFiles $H }
}

function Update-ChatConsoleFiles {
    # the files going with the prompt, as chips with their size and a x
    param($H)
    $C = $H.Con
    $C.Files.Children.Clear()
    foreach ($s in @($C.Staged)) {
        $kb = if ($s.Size -ge 1MB) { '{0:N1} MB' -f ($s.Size / 1MB) } else { '{0:N0} KB' -f [Math]::Max(1, $s.Size / 1KB) }
        $what = if ($s.Error) { " - $($s.Error)" } elseif ($s.Task) { ' - copying' } else { '' }
        $chip = [System.Windows.Controls.Border]::new()
        $chip.CornerRadius = [System.Windows.CornerRadius]::new(4)
        $chip.BorderThickness = [System.Windows.Thickness]::new(1)
        $chip.BorderBrush = Get-ChatOverlayBrush $(if ($s.Error) { 'error' } else { 'inputEdge' })
        $chip.Padding = [System.Windows.Thickness]::new(7, 1, 3, 2)
        $chip.Margin = [System.Windows.Thickness]::new(0, 0, 5, 3)
        $sp = [System.Windows.Controls.StackPanel]::new()
        $sp.Orientation = [System.Windows.Controls.Orientation]::Horizontal
        [void]$sp.Children.Add((New-ChatOverlayText "$($s.Name) ($kb)$what" $(if ($s.Error) { 'error' } else { 'text' }) 11.5))
        $x = New-ChatConsoleButton ([string][char]0x00D7) { param($o, $e) $e.Handled = $true; Remove-ChatConsoleFile $script:ChatOverlayHost $o.Tag } -Small -Tag $s -Tip 'Leave this file out'
        $x.BorderThickness = [System.Windows.Thickness]::new(0)
        $x.Margin = [System.Windows.Thickness]::new(3, 0, 0, 0)
        [void]$sp.Children.Add($x)
        $chip.Child = $sp
        [void]$C.Files.Children.Add($chip)
    }
    $n = @($C.Staged).Count
    $bytes = (@($C.Staged) | ForEach-Object { [int64]$_.Size } | Measure-Object -Sum).Sum
    if ($n -gt $script:ChatqAttachWarnCount -or $bytes -gt $script:ChatqAttachWarnBytes) {
        [void]$C.Files.Children.Add((New-ChatOverlayText 'that is a lot for one run - every file costs context, and usage' 'warn' 11))
    }
}

function Remove-ChatConsoleFile {
    param($H, $Staged)
    $C = $H.Con
    [void]$C.Staged.Remove($Staged)
    # still being copied: the copy holds the file open, so it goes when done
    if ($Staged.Task -and -not $Staged.Task.IsCompleted) {
        if (-not $C.Trash) { $C.Trash = [System.Collections.Generic.List[object]]::new() }
        $C.Trash.Add(@{ Dir = $Staged.Dir; Task = $Staged.Task })
    }
    elseif ($Staged.Dir -and (Test-Path -LiteralPath $Staged.Dir)) { Remove-Item -LiteralPath $Staged.Dir -Recurse -Force -EA SilentlyContinue }
    $C.Dirty = Get-Date
    Update-ChatConsoleFiles $H
}

function Invoke-ChatConsoleBrowse {
    # the folder picker, over the console; the console is not redrawn under it
    param($H)
    $C = $H.Con
    $d = [System.Windows.Forms.FolderBrowserDialog]::new()
    $d.Description = 'The folder the new chat works in'
    if ($C.FolderBox.Text -and (Test-Path -LiteralPath $C.FolderBox.Text)) { $d.SelectedPath = $C.FolderBox.Text }
    $own = [System.Windows.Forms.NativeWindow]::new()
    $C.Modal = $true
    try {
        $own.AssignHandle($C.Hwnd)
        if ($d.ShowDialog($own) -eq [System.Windows.Forms.DialogResult]::OK) { $C.FolderBox.Text = $d.SelectedPath }
    }
    finally { $C.Modal = $false; try { $own.ReleaseHandle() } catch {}; $d.Dispose() }
    # a lock, a hide or a Quit asked for while it was open
    Invoke-ChatOverlayHeldVerbs $H
}

function Invoke-ChatConsoleSend {
    <#
    Send: the prompt, its files and the choices made, to the chat picked or
    a new one - New-ChatqJob, the same job chatq makes - then the watcher
    asked for without a wait. The box empties for the next one; the chat
    stays picked.
    #>
    param($H)
    $C = $H.Con
    $t = $C.Target
    # the second click of a double-click finds the box it just emptied
    if (-not $C.Prompt.Text.Trim() -and $C.SentAt -and ((Get-Date) - $C.SentAt).TotalSeconds -lt 2) { return }
    if (-not $t) { Set-ChatConsoleStatus $H 'pick a chat on the left, or + New chat' 'warn'; return }
    if (@($C.Staged | Where-Object { $_.Task }).Count) { Set-ChatConsoleStatus $H 'a file is still being copied - a moment' 'warn'; return }
    if (@($C.Staged | Where-Object { $_.Error }).Count) { Set-ChatConsoleStatus $H 'a file could not be copied - x it out, or drop it again' 'warn'; return }
    $plan = ConvertFrom-ChatConsoleWhen $C.When $(if ($C.WhenBox) { $C.WhenBox.Text } else { $C.WhenValue })
    if ($plan.Error) { Set-ChatConsoleStatus $H $plan.Error 'warn'; return }
    $text = $C.Prompt.Text
    $src = @{ Files = @($C.Staged | ForEach-Object { $_.Path }) }
    # the job list read afresh for its number: a shell may have queued one
    # since the last pass
    # Claude's modes and models mean nothing to Codex: -m opus would fail
    # the run. Its mode is the sandbox picked, '' for the one it last used.
    $codex = $t.Provider -eq 'codex'
    $how = @{
        Prompt = $text; Mode = $(if ($codex) { $C.Sandbox } else { $C.Mode }); Model = $(if ($codex) { '' } else { $C.Model })
        NotBefore = $plan.NotBefore; First = $plan.First; SendNow = $plan.SendNow; Sources = $src; MoveSources = $true
    }
    if ($t.Kind -eq 'new') {
        $made = New-ChatqJob -Kind new -Cwd $C.FolderBox.Text -Title $C.NameBox.Text.Trim() @how
    }
    else {
        $got = Get-ChatConsoleRow $H $t
        if (-not $got) { Set-ChatConsoleStatus $H (Get-ChatConsoleMissingSay $t) 'warn'; return }
        $made = New-ChatqJob -Row $got.Row -Info $got.Info -Rule 'picked' @how
    }
    if ($made.Error) { Set-ChatConsoleStatus $H $made.Error 'warn'; return }
    $j = $made.Job
    # what was staged went in with it
    foreach ($s in @($C.Staged)) { if ($s.Dir -and (Test-Path -LiteralPath $s.Dir)) { Remove-Item -LiteralPath $s.Dir -Recurse -Force -EA SilentlyContinue } }
    $C.Staged.Clear()
    $C.Prompt.Text = ''
    if ($t.Kind -eq 'new') {
        $folders = @(@($j.cwd) + @($C.State.folders | Where-Object { $_ -and $_ -ne $j.cwd }) | Select-Object -First 10)
        $C.State.folders = $folders
        $C.NameBox.Text = ''
        # the new chat is the one picked now, for what goes to it next
        $C.Target = @{ Kind = 'chat'; Id = $j.sessionId; Provider = 'claude'; Title = $j.title; Project = (Split-Path ([string]$j.cwd).TrimEnd('\', '/') -Leaf); Cwd = $j.cwd; Path = $j.path; Live = $null }
    }
    $C.Request = Request-ChatqWatcher -Wake poke
    $C.Sel = $j.id
    $C.SentAt = Get-Date
    $C.Confirm = @{}
    Save-ChatConsoleDraft $H
    Update-ChatConsoleTarget $H
    Update-ChatConsoleFiles $H
    $miss = if (@($made.Missed).Count) { " - could not take in $(@($made.Missed).Count) file(s)" } else { '' }
    Set-ChatConsoleStatus $H "queued #$($j.seq) for '$($j.title)'$(if (@($made.Files).Count) { " with $(Format-ChatqAttachSummary @($made.Files))" })$miss" $(if ($miss) { 'warn' } else { 'dim' })
    Update-ChatConsoleNow $H
}

function Get-ChatConsoleMissingSay {
    # why a chat picked has no row to send to: a new chat not made yet - its
    # first run makes it - or one the index has not seen
    param($Target)
    $first = @(Get-ChatqJobs | Where-Object { $_.kind -eq 'new' -and $_.sessionId -eq $Target.Id -and $_.state -in 'queued', 'running' })[0]
    if ($first) { return "this chat is made when #$($first.seq) runs - write to it after that" }
    return "that chat is not in the index yet - chatindex in a shell, or wait for the console's own sync"
}

function Get-ChatConsoleRestartRows {
    # by session id, the collector's rows of the chats a VS Code window's
    # restart cut off (Get-ChatRestartCutOffs) - the orange rows and the
    # ask's alike
    param($H)
    $out = @{}
    foreach ($c in @(@($H.Ctx.CutOff) + @(if ($H.Ctx.Ask) { $H.Ctx.Ask.Items }))) {
        if ($c -and [string](Get-ChatField $c 'Why') -eq 'restart') { $out[[string]$c.Id] = $c }
    }
    return $out
}

function Test-ChatConsoleRestartItem {
    # whether a console list item is a chat a VS Code restart cut off
    param($H, $Item)
    if (-not $Item -or [string](Get-ChatField $Item 'Kind') -ne 'cutoff') { return $false }
    $id = [string](Get-ChatField $Item 'Id')
    return [bool]($id -and (Get-ChatConsoleRestartRows $H)[$id])
}

function Invoke-ChatConsoleContinue {
    # "Continue from where you left off." for each chat the limit or a 529
    # stopped (Invoke-ChatqContinueChats: one job each, a chat that already
    # has one waiting or running left alone - the list is redrawn only on
    # the next pass, and a second click would queue it twice), then the
    # watcher asked once. The chats of a pending ask this continues are its
    # answer too: marked continued, so the panel's banner and the tray's
    # items go, and the ask is not made about them again.
    param($H, [object[]]$Items)
    # a chat a window's restart cut off goes as the collector's row of it,
    # which says what the restart took (Get-ChatqRestartPrompt) - the list's
    # item knows only the chat
    $restart = Get-ChatConsoleRestartRows $H
    $list = @($Items | Where-Object { $_ } | ForEach-Object { $x = $restart[[string](Get-ChatField $_ 'Id')]; if ($x) { $x } else { $_ } })
    $r = if ($list.Count) { Invoke-ChatqContinueChats -Items $list } else { [pscustomobject]@{ Queued = @(); Had = @(); Fails = @() } }
    $n = @($r.Queued | Where-Object { $_ }).Count
    $had = @($r.Had | Where-Object { $_ }).Count
    $fails = @($r.Fails | Where-Object { $_ })
    if ($n) { $H.Con.Request = Request-ChatqWatcher -Wake poke }
    $answered = Save-ChatConsoleAskAnswer $H $r
    $say = Format-ChatqContinueSay $n $had -Restart:($list.Count -and @($list | Where-Object { [string](Get-ChatField $_ 'Why') -eq 'restart' }).Count -eq $list.Count)
    Set-ChatConsoleStatus $H $(if ($fails) { "$say; $($fails -join '; ')" } else { $say }) $(if ($fails) { 'warn' } else { 'dim' })
    Update-ChatConsoleNow $H
    if ($answered) { Update-ChatOverlayAsk $H }
}

function Save-ChatConsoleAskAnswer {
    <#
    What Continue in the console answers of a pending ask ($H.Ctx.Ask): its
    chats that got a job, or had one, marked continued (Save-ChatqAskAnswer,
    with the new jobs' numbers), merged into what the collector holds as
    answered, and the ask cleared - the next pass makes it again for any
    chat of it left. A chat that failed stays unanswered. -Result is
    Invoke-ChatqContinueChats'. Whether any was answered.
    #>
    param($H, $Result)
    $ask = $H.Ctx.Ask
    if (-not $ask -or -not $Result) { return $false }
    try {
        $seq = @{}
        foreach ($j in @($Result.Queued)) { if ($j -and $j.sessionId) { $seq[[string]$j.sessionId] = [int]$j.seq } }
        $had = @{}
        foreach ($id in @($Result.Had)) { if ($id) { $had[[string]$id] = $true } }
        $items = @($ask.Items)
        $ks = @($ask.Keys)
        $keys = @()
        $seqs = @{}
        for ($i = 0; $i -lt $items.Count -and $i -lt $ks.Count; $i++) {
            $id = [string]$items[$i].Id
            if ($seq.ContainsKey($id)) { $keys += $ks[$i]; $seqs[$ks[$i]] = @($seq[$id]) }
            elseif ($had[$id]) { $keys += $ks[$i] }
        }
        if (-not $keys.Count) { return $false }
        $saved = @(Save-ChatqAskAnswer -Keys $keys -Answer continue -Source console -Seqs $seqs -Extra (Get-ChatqAskExtra $items $ks))
        if ($null -ne $H.Ctx.AskState) { foreach ($k in $saved) { if ($k) { $H.Ctx.AskState[[string]$k] = $true } } }
        $H.Ctx.Ask = $null
        Write-ChatOverlayLog "ask: continued from the console - $($keys.Count) of $([int]$ask.Count)" -Always
        return $true
    }
    catch { Write-ChatOverlayLog "ask: $($_.Exception.Message)"; return $false }
}

function Update-ChatConsoleNow {
    # a pass now, not in up to 2 s: what was just queued shows at once, and
    # the rows it answers - a cut-off chat continued - leave the list
    param($H)
    $H.Con.JobsSig = $null
    $H.Con.Sigs = @{}
    try { Update-ChatOverlayView $H (Invoke-ChatOverlayCycle $H.Ctx -Peek) } catch { Write-ChatOverlayLog "console: $($_.Exception.Message)" }
    Update-ChatConsole $H
}

function Update-ChatConsoleQueue {
    # the jobs: open ones and those that ended in the last day, newest work
    # first, each with where it stands; the one picked in full beside them
    param($H)
    $C = $H.Con
    if (-not $C.Queue) { return }
    # every job's "sends", worked out here as the collector does - a chat's
    # row carries only its first job, and the ones behind it said "queued"
    $eta = try { Get-ChatqEta @($C.Jobs) $(if ($H.Ctx.Blocks) { $H.Ctx.Blocks } else { @{} }) } catch { @{} }
    $day = (Get-Date).AddDays(-1)
    $list = @($C.Jobs | Where-Object { $_.state -in 'queued', 'running', 'needs-input' -or ((ConvertTo-ChatqDate $_.endedAt) -gt $day) })
    $key = (@($list | ForEach-Object { "$($_.id)=$($_.state)=$($eta[[string]$_.id])=$(Format-ChatOverlayDeferral $_)" }) -join ';') + "|$($C.Sel)|$($C.ShowLog)|$(@($C.Confirm.Keys) -join ',')"
    if ($key -eq $C.Sigs.Queue) { return }
    $C.Sigs.Queue = $key
    $C.Queue.Children.Clear()
    if (-not $list) { [void]$C.Queue.Children.Add((New-ChatOverlayText 'nothing queued' 'faint' 12)) }
    $open = @($list | Where-Object { $_.state -in 'queued', 'running', 'needs-input' })
    $shut = @($list | Where-Object { $_.state -notin 'queued', 'running', 'needs-input' } | Sort-Object { ConvertTo-ChatqDate $_.endedAt } -Descending)
    foreach ($j in @($open + $shut)) {
        $st = Get-ChatConsoleJobStatus $j $eta[[string]$j.id]
        $b = [System.Windows.Controls.Border]::new()
        $b.CornerRadius = [System.Windows.CornerRadius]::new(4)
        $b.Padding = [System.Windows.Thickness]::new(6, 2, 6, 3)
        $b.Cursor = [System.Windows.Input.Cursors]::Hand
        $b.Tag = $j.id
        $b.Background = if ($C.Sel -eq $j.id) { Get-ChatOverlayBrush 'select' } else { [System.Windows.Media.Brushes]::Transparent }
        $d = [System.Windows.Controls.DockPanel]::new()
        $right = New-ChatOverlayText $st.Text $st.Tone 11 -Trim
        $right.MaxWidth = 260
        $right.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
        [System.Windows.Controls.DockPanel]::SetDock($right, [System.Windows.Controls.Dock]::Right)
        [void]$d.Children.Add($right)
        $l = [System.Windows.Controls.TextBlock]::new()
        $l.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
        $r1 = [System.Windows.Documents.Run]::new("#$($j.seq)  ")
        $r1.Foreground = Get-ChatOverlayBrush 'faint'
        $l.Inlines.Add($r1)
        $r2 = [System.Windows.Documents.Run]::new("$(if ($j.kind -eq 'new') { 'new: ' })$($j.title)")
        $r2.Foreground = Get-ChatOverlayBrush 'text'
        $l.Inlines.Add($r2)
        $first = if ($j.kind -eq 'continue' -or $j.retryAs -eq 'continue') { 'continue' } else { (Get-ChatqPromptStats ([string](Read-ChatqPrompt $j))).First }
        if ($first) { $r3 = [System.Windows.Documents.Run]::new("   $first"); $r3.Foreground = Get-ChatOverlayBrush 'dim'; $l.Inlines.Add($r3) }
        [void]$d.Children.Add($l)
        $b.Child = $d
        # another job picked: a Remove asked about the last one no longer stands
        $b.add_MouseLeftButtonUp({ param($s, $e) $H = $script:ChatOverlayHost; $H.Con.Sel = [string]$s.Tag; $H.Con.ShowLog = $false; $H.Con.Confirm = @{}; $H.Con.Sigs.Queue = $null; Update-ChatConsoleQueue $H })
        [void]$C.Queue.Children.Add($b)
    }
    Show-ChatConsoleDetails $H
}

function Show-ChatConsoleDetails {
    # the job picked: where it stands, what came of it, the buttons for what
    # can be done to it now, its prompt - editable while it waits - and its
    # reply or log
    param($H)
    $C = $H.Con
    # A prompt being edited outlives the redraw: any job's state or send
    # time moving redraws this pane, and the edit went with it. Kept while
    # it differs from the file and is for the same job.
    $typed = $null
    if ($C.EditBox -and $C.EditFor -and $C.EditBox.Text -ne $C.EditWas) { $typed = @{ For = $C.EditFor; Text = $C.EditBox.Text; Was = $C.EditWas } }
    $C.EditBox = $null
    $C.EditFor = $null
    $C.Details.Children.Clear()
    $j = if ($C.Sel) { @($C.Jobs | Where-Object { $_.id -eq $C.Sel })[0] } else { $null }
    if (-not $j) { [void]$C.Details.Children.Add((New-ChatOverlayText 'pick a job to see it in full' 'faint' 12)); return }
    $add = { param($x) [void]$C.Details.Children.Add($x) }
    $h1 = New-ChatOverlayText "#$($j.seq)  $($j.title)" 'text' 13 -Bold -Trim
    & $add $h1
    $st = Get-ChatConsoleJobStatus $j $null
    $w = New-ChatOverlayText "$($st.Text)" $st.Tone 11.5
    $w.TextWrapping = [System.Windows.TextWrapping]::Wrap
    & $add $w
    & $add (New-ChatOverlayText "$($j.provider) $($script:ChatqDot) $($j.kind)$(if ($j.mode) { " $($script:ChatqDot) $($j.mode)" }) $($script:ChatqDot) $($j.cwd)" 'faint' 11 -Trim)
    # the continue auto-continue queued: when the limit cut the chat off, and the reset
    $autoNote = Get-ChatqAutoJobNote $j
    if ($autoNote) { $an = New-ChatOverlayText $autoNote 'dim' 11; $an.TextWrapping = [System.Windows.TextWrapping]::Wrap; & $add $an }
    # the background command it waits for, when the watcher knew it
    if ((Format-ChatOverlayDeferral $j) -and [string](Get-ChatField $j 'deferWhy') -eq 'background' -and (Get-ChatField $j 'deferNote')) {
        & $add (New-ChatOverlayText "the command: $(Get-ChatField $j 'deferNote')" 'dim' 11 -Trim)
    }
    $acts = [System.Windows.Controls.WrapPanel]::new()
    $acts.Margin = [System.Windows.Thickness]::new(0, 6, 0, 6)
    # The click's own time, as the mouse had it (Invoke-ChatConsoleJobAction)
    # - 0 for a click raised in code, which is taken as now. What went wrong
    # is said in the status line, not only in overlay.log.
    $act = {
        param($label, $what, $tip, $tone)
        [void]$acts.Children.Add((New-ChatConsoleButton $label {
                    param($s, $e)
                    $X = $script:ChatOverlayHost
                    try { Invoke-ChatConsoleJobAction $X ([string]$s.Tag.Id) ([string]$s.Tag.Act) $(if ($e.Timestamp) { [int64]$e.Timestamp } else { [int64][Environment]::TickCount }) }
                    catch { Write-ChatOverlayLog "console: $($_.Exception.Message)"; Set-ChatConsoleStatus $X "$($s.Tag.Act) went wrong: $($_.Exception.Message)" 'error' }
                } -Small -Tag @{ Id = $j.id; Act = $what } -Tip $tip -Tone $tone))
    }
    # Remove asked, for 5 s: "sure?", in error's colour (Update-ChatConsoleAsks)
    $asking = $C.Confirm.ContainsKey([string]$j.id)
    $rmTip = 'Drop this queued job - its prompt and its files. The chat itself stays.'
    switch ([string]$j.state) {
        'queued' {
            & $act 'Try now' 'now' 'Stop waiting for a reset: ask now, and send if the limit is over'
            & $act 'First' 'first' 'To the front of the queue'
            # auto-continue's: one click, as in the Cut off list - the chat's
            # Continue there undoes it, so one rule for both places
            if (Get-ChatField $j 'auto') { & $act "Don't continue" 'dont' "Not $(Get-ChatqAutoWhen $j) - its cut-off is not queued again; Continue in the Cut off list queues one" }
            else { & $act $(if ($asking) { 'Remove - sure?' } else { 'Remove' }) 'remove' $rmTip $(if ($asking) { 'error' }) }
        }
        'running' {
            & $act 'Cancel' 'cancel' 'Stop the run - it is marked failed'
            # a Claude chat's run, as the panel's watch chip has it
            if (Test-ChatOverlayRowOpenable (Get-ChatConsoleJobRow $j)) { & $act 'Watch in VS Code' 'watch' 'Watch the run live in its VS Code window' }
        }
        default {
            & $act 'Requeue' 'requeue' 'Send it again - as "continue" if its prompt already reached the chat'
            & $act $(if ($asking) { 'Remove - sure?' } else { 'Remove' }) 'remove' $rmTip $(if ($asking) { 'error' })
        }
    }
    # its chat in VS Code, as the panel's open chip opens it - once there
    # is a transcript to open: a new chat's first run makes it
    if ($j.state -ne 'running' -and (Test-ChatOverlayRowOpenable (Get-ChatConsoleJobRow $j)) -and $j.path -and (Test-Path -LiteralPath ([string]$j.path))) {
        & $act 'Open in VS Code' 'open' 'Open this chat in its VS Code window'
    }
    if ($j.sessionId) { & $act 'Write to this chat' 'write' 'Pick this chat to write to' }
    if (Test-Path -LiteralPath (Join-Path $script:ChatqLogDir "$($j.id).jsonl")) { & $act $(if ($C.ShowLog) { 'Reply' } else { 'Log' }) 'log' 'What the run did' }
    & $add $acts
    # A waiting job's mode and model, as the chips under the prompt box set
    # them for a new one (Set-ChatqJobRunAs). One set by chatq that the
    # chips do not list is shown as a chip of its own, so the one in force
    # is always filled. A Codex job's mode is its sandbox, its row Sandbox;
    # its model is not offered, as under the prompt box.
    if ($j.state -eq 'queued' -and $j.provider -in 'claude', 'codex') {
        $isNew = $j.kind -eq 'new'
        $opts = if ($j.provider -eq 'codex') {
            @(@{ Label = 'Sandbox'; What = 'mode'; Now = [string]$j.mode; Values = $script:ChatqCodexSandboxes; Own = 'as it ran'; Words = @{ 'danger-full-access' = 'full access' } })
        }
        else {
            @(@{ Label = 'Mode'; What = 'mode'; Now = [string]$j.mode; Values = $script:ChatConsoleModes; Own = $(if ($isNew) { 'default' } else { 'as it ran' }) },
                @{ Label = 'Model'; What = 'model'; Now = [string]$j.runModel; Values = $script:ChatConsoleModels; Own = $(if ($isNew) { 'default' } else { 'its own' }) })
        }
        foreach ($o in $opts) {
            $vals = @('') + @($o.Values)
            if ($o.Now -and $o.Now -notin $vals) { $vals += $o.Now }
            $labels = @($o.Own) + @($vals | Select-Object -Skip 1 | ForEach-Object { if ($o.Words -and $o.Words[$_]) { $o.Words[$_] } else { $_ } })
            # which of the two a chip is: its row's Tag, as the click has no
            # closure; what went wrong is said, as the buttons' is
            $on = {
                param($s, $e)
                $e.Handled = $true
                $X = $script:ChatOverlayHost
                $what = [string]$s.Parent.Tag
                try { Invoke-ChatConsoleJobAction $X ([string]$X.Con.Sel) $what -Value ([string]$s.Tag) }
                catch { Write-ChatOverlayLog "console: $($_.Exception.Message)"; Set-ChatConsoleStatus $X "$what went wrong: $($_.Exception.Message)" 'error' }
            }
            $d = [System.Windows.Controls.DockPanel]::new()
            $l = New-ChatOverlayText $o.Label 'dim' 11.5
            # Sandbox is a wider word than Mode and Model
            $l.Width = if ($o.Label.Length -gt 5) { 52 } else { 44 }
            $l.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
            [System.Windows.Controls.DockPanel]::SetDock($l, [System.Windows.Controls.Dock]::Left)
            [void]$d.Children.Add($l)
            $chips = New-ChatConsoleChips $vals $labels $o.Now $on
            $chips.Tag = $o.What
            [void]$d.Children.Add($chips)
            & $add $d
        }
    }
    if ($j.state -eq 'queued' -and $j.kind -ne 'continue' -and $j.retryAs -ne 'continue') {
        $ed = New-ChatConsoleInput -Multi -Tip 'Edits count until it sends'
        $ed.MinHeight = 60
        $ed.MaxHeight = 220
        $C.EditWas = [string](Read-ChatqPrompt $j)
        $ed.Text = if ($typed -and $typed.For -eq $j.id) { $typed.Text } else { $C.EditWas }
        $C.EditBox = $ed
        $C.EditFor = $j.id
        & $add $ed
        $sv = New-ChatConsoleButton 'Save the prompt' { param($s, $e) Invoke-ChatConsoleJobAction $script:ChatOverlayHost ([string]$s.Tag) 'save' } -Small -Tag $j.id
        $sv.Margin = [System.Windows.Thickness]::new(0, 4, 0, 6)
        $sv.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
        & $add $sv
    }
    $files = @(Get-ChatqAttachments $j)
    if ($files) { & $add (New-ChatOverlayText (Format-ChatqAttachSummary $files) 'faint' 11 -Trim) }
    # the log read once per length: a long run's is megabytes of JSON
    $lp = Join-Path $script:ChatqLogDir "$($j.id).jsonl"
    $ll = try { ([System.IO.FileInfo]::new($lp)).Length } catch { 0 }
    if (-not $C.LogCache) { $C.LogCache = @{} }
    $lc = $C.LogCache[$j.id]
    if (-not $lc -or $lc.Len -ne $ll) { $lc = @{ Len = $ll; Entries = @(Get-ChatqLogEntries $j -MaxBytes 2MB) }; $C.LogCache[$j.id] = $lc }
    if ($C.ShowLog) {
        foreach ($e in @($lc.Entries)) {
            $tone = switch ($e.Type) { 'text' { 'text' } 'denied' { 'warn' } 'error' { 'error' } default { 'faint' } }
            $prefix = switch ($e.Type) { 'tool' { '> ' } 'denied' { '! denied ' } 'error' { '! ' } 'result' { '= ' } default { '' } }
            $tb = New-ChatOverlayText "$prefix$($e.Text)" $tone 11.5
            $tb.TextWrapping = [System.Windows.TextWrapping]::Wrap
            $tb.Margin = [System.Windows.Thickness]::new(0, 2, 0, 2)
            & $add $tb
        }
    }
    elseif ($j.result) {
        # the reply: the log's last words, else the excerpt the job kept
        $reply = @($lc.Entries | Where-Object { $_.Type -eq 'text' } | ForEach-Object { $_.Text })
        $text = if ($reply) { $reply[-1] } elseif ($j.result.excerpt) { [string]$j.result.excerpt } else { '' }
        if ($text) {
            $tb = New-ChatOverlayText $text 'text' 12
            $tb.TextWrapping = [System.Windows.TextWrapping]::Wrap
            & $add $tb
        }
        if ($j.result.PSObject.Properties['stale'] -and $j.result.stale) { & $add (New-ChatOverlayText 'the chat is open in VS Code - reload that window to see this there' 'warn' 11) }
    }
    foreach ($h in @($j.history | Select-Object -Last 6)) {
        $at = ConvertTo-ChatqDate $h.at
        & $add (New-ChatOverlayText "$(if ($at) { $at.ToString('MM-dd HH:mm') })  $($h.state)  $($h.why)" 'faint' 10.5 -Trim)
    }
}

function Get-ChatConsoleSince {
    # ms from one tick count to a later one - the clock a mouse event's
    # Timestamp is on - across its wrap every 49.7 days. Pure.
    param([int64]$From, [int64]$To)
    $d = $To - $From
    if ($d -lt 0) { $d += 4294967296 }
    return $d
}

function Get-ChatConsoleRemoveStep {
    <#
    What a click on a job's Remove does, from -Since, the ms from the ask
    it answers to the click, both as the mouse had them - -1 for none:
    ask, a first click; double, the second half of a double-click, under
    0.4 s - no answer; remove, a later click while "sure?" shows; stale,
    an ask older than -Keep ms that no tick has put back yet (the window
    was busy): asked again, and said so. Pure.
    #>
    param([int64]$Since, [int64]$Keep = 5000)
    if ($Since -lt 0) { return 'ask' }
    if ($Since -lt 400) { return 'double' }
    if ($Since -gt $Keep + 2000) { return 'stale' }
    return 'remove'
}

function Update-ChatConsoleAsks {
    # every tick: a Remove asked and not answered in 5 s is put back to
    # Remove, and said so - what the button says is what a click on it does
    param($H, [int64]$Now = [Environment]::TickCount)
    $C = $H.Con
    if (-not $C -or -not $C.Confirm -or -not $C.Confirm.Count) { return }
    $old = @($C.Confirm.Keys | Where-Object { (Get-ChatConsoleSince $C.Confirm[$_] $Now) -gt 5000 })
    if (-not $old) { return }
    foreach ($k in $old) { $C.Confirm.Remove($k) }
    $C.Sigs.Queue = $null
    Update-ChatConsoleQueue $H
    $n = @($C.Jobs | Where-Object { $_ -and [string]$_.id -in $old } | ForEach-Object { "#$($_.seq)" }) -join ' '
    Set-ChatConsoleStatus $H "$(if ($n) { "$n kept" } else { 'kept' }) - Remove - sure? was not clicked within 5 s"
}

function Invoke-ChatConsoleJobAction {
    # what a button in the details does - the same core chatqrm, chatqrun
    # and chatq <n> call. -At: when the click came, as the mouse had it
    # (MouseButtonEventArgs.Timestamp): a pass on this thread, or reading
    # the queue, must not age a click that came in time, or bunch the two
    # halves of a double-click into an answer. -Value: the chip mode and
    # model take, '' for the chat's own.
    param($H, [string]$Id, [string]$Act, [int64]$At = [Environment]::TickCount, [string]$Value)
    $C = $H.Con
    $j = Find-ChatqJob $Id -Exact
    if (-not $j) { Set-ChatConsoleStatus $H 'that job is gone' 'warn'; $C.JobsSig = $null; return }
    $say = ''
    $tone = 'dim'
    switch ($Act) {
        'now' { Set-ChatqJobFirst $j; $C.Request = Request-ChatqWatcher -Wake now; $say = "#$($j.seq) tried now - it sends if nothing holds it" }
        'first' { Set-ChatqJobFirst $j; $C.Request = Request-ChatqWatcher -Wake poke; $say = "#$($j.seq) moved to the front" }
        'remove' {
            # Twice, and on purpose: a first click asks, and "sure?" stands
            # 5 s - Update-ChatConsoleAsks puts Remove back after. Every click
            # says what it did: none is silent.
            $asked = $C.Confirm[$j.id]
            $step = Get-ChatConsoleRemoveStep $(if ($null -ne $asked) { Get-ChatConsoleSince $asked $At } else { -1 })
            if ($step -eq 'double') { Set-ChatConsoleStatus $H "a double-click is not an answer - click Remove - sure? once to remove #$($j.seq)" 'warn'; return }
            if ($step -ne 'remove') {
                $C.Confirm = @{ $j.id = $At }
                $C.Sigs.Queue = $null
                Update-ChatConsoleQueue $H
                Set-ChatConsoleStatus $H "remove #$($j.seq)? Click Remove - sure? within 5 s$(if ($step -eq 'stale') { ' - the last ask had run out' })" $(if ($step -eq 'stale') { 'warn' } else { 'dim' })
                return
            }
            $C.Confirm.Remove($j.id)
            if (Remove-ChatqJob $j 'the console') { $say = "removed #$($j.seq) - the queued prompt; the chat itself stays"; $C.Sel = $null }
            else {
                $now = Find-ChatqJob $j.id -Exact
                $say = if ($now -and $now.state -eq 'running') { "#$($j.seq) is running - cancel it first" } else { "#$($j.seq) could not be removed - its file is in use; try again" }
                $tone = 'warn'
            }
        }
        'dont' { Invoke-ChatConsoleDontContinue $H $j.id $j.sessionId; return }
        'watch' {
            # The chip's own open (Invoke-ChatOverlayOpen), which
            # Show-ChatFresh turns into the run's live view while it runs;
            # one at a time, and the tray says how it went.
            if ($j.state -ne 'running') { $say = "#$($j.seq) is $($j.state) - no run to watch"; break }
            if ($H.OpenProc) { $say = 'an open is still going - try again in a moment'; break }
            Invoke-ChatOverlayOpen $H (Get-ChatConsoleJobRow $j)
            $say = if ($H.OpenProc) { "#$($j.seq): its live view opens in VS Code" } else { "#$($j.seq) could not be shown - data/logs/overlay.log says why" }
        }
        'open' {
            # the same open, for its chat as it stands
            if ($H.OpenProc) { $say = 'an open is still going - try again in a moment'; break }
            Invoke-ChatOverlayOpen $H (Get-ChatConsoleJobRow $j)
            $say = if ($H.OpenProc) { "#$($j.seq): its chat opens in VS Code" } else { "#$($j.seq)'s chat could not be opened - data/logs/overlay.log says why" }
        }
        { $_ -in 'mode', 'model' } {
            $no = Set-ChatqJobRunAs $j $Act $Value
            if ($no) { $say = $no; $tone = 'warn'; break }
            $kindOf = if ($Act -eq 'model') { 'model' } elseif ($j.provider -eq 'codex') { 'sandbox' } else { 'mode' }
            $say = "#$($j.seq) runs $(if ($Value) { "$(if ($Act -eq 'mode') { 'in' } else { 'on' }) $Value" } else { "$(if ($Act -eq 'mode') { 'in the' } else { 'on the' }) $kindOf its chat has" })"
            # a sandbox other than the chat's stays with it after the run
            if ($j.provider -eq 'codex' -and $Act -eq 'mode' -and (Get-ChatqCodexStickSay (ConvertTo-ChatqCodexSandbox ([string]$j.sandbox)).Sandbox $Value)) { $say += ' - and the chat keeps it for later jobs' }
        }
        'cancel' {
            $say = switch (Stop-ChatqJobRun $j) {
                'cancelling' { "#$($j.seq) cancelling - stopped within a few seconds" }
                'not running' { "#$($j.seq) had already ended - $($j.state)" }
                default { "#$($j.seq) was left running by a watcher that stopped - marked failed" }
            }
        }
        'requeue' {
            $r = Reset-ChatqJob $j
            if ($r.Error) { $say = $r.Error } else { $C.Request = Request-ChatqWatcher -Wake poke; $say = "#$($j.seq) queued again$(if ($r.Landed) { ', as "continue" - the prompt already reached the chat' })" }
        }
        'write' {
            $C.Target = @{ Kind = 'chat'; Id = [string]$j.sessionId; Provider = [string]$j.provider; Title = [string]$j.title; Project = (Split-Path ([string]$j.cwd).TrimEnd('\', '/') -Leaf); Cwd = $j.cwd; Path = $j.path; Live = $null }
            $C.Sigs.Chats = $null
            Update-ChatConsoleTarget $H
            [void]$C.Prompt.Focus()
            return
        }
        'log' { $C.ShowLog = -not $C.ShowLog; $C.Sigs.Queue = $null; Update-ChatConsoleQueue $H; return }
        'save' {
            if ($j.state -ne 'queued') { $say = "#$($j.seq) is $($j.state) - an edit now changes nothing"; break }
            $p = Get-ChatqPromptPath $j
            $old = if (Test-Path -LiteralPath $p) { [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) } else { '' }
            $head = [regex]::Match($old, '^\s*<!--\s*chatq:.*?-->\s*', [System.Text.RegularExpressions.RegexOptions]::Singleline).Value
            Save-ChatqText $p ($head + $C.EditBox.Text)
            $say = "#$($j.seq) prompt saved"
        }
    }
    $C.Confirm.Clear()
    $C.JobsSig = $null
    $C.Jobs = @(Get-ChatqJobs)
    $C.Sigs.Queue = $null
    Update-ChatConsoleQueue $H
    if ($say) { Set-ChatConsoleStatus $H $say $tone }
}

function Register-ChatConsoleHotkey {
    # config consoleHotkey (Ctrl+Alt+Shift+Q): opens the console; pressed
    # while the console has the keyboard, back to the panel - its own verb,
    # console-key, as only the key toggles. Taken by another program, it is
    # logged and the tray item still works.
    param($H)
    $text = [string]$H.Ctx.Config.consoleHotkey
    if ($H.ConHotkey -and $H.ConHotkeyText -eq $text) { return }
    if ($H.ConHotkey) { $H.ConHotkey.Dispose(); $H.ConHotkey = $null }
    $H.ConHotkeyText = $text
    $k = try { ConvertFrom-ChatOverlayHotkey $text } catch { Write-ChatOverlayLog "console hotkey: $($_.Exception.Message)"; $null }
    if (-not $k) { return }
    $hk = [ChatOverlayHotkey]::new()
    $hk.add_Pressed({ Invoke-ChatOverlayVerb 'console-key' })
    if ($hk.Register([uint32]$k.Mods, [uint32]$k.Vk)) { $H.ConHotkey = $hk }
    else { $hk.Dispose(); Write-ChatOverlayLog "console hotkey $text is taken by another program" }
}

#endregion
