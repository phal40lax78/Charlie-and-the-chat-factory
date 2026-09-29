# Charlie-and-the-chat-factory, src/discoverability.ps1: dot-sourced by Charlie-and-the-chat-factory.ps1
# in its turn, never on its own - see the list there.

#region discoverability -------------------------------------------------------

function Compare-ChatVersion {
    # -1 A older, 0 same, 1 A newer, $null if either side will not parse.
    # $null is not "equal" - a stamp written by hand, or by some future format,
    # has to read as a change rather than silently as "unchanged".
    param([string]$A, [string]$B)
    $pa = $null
    $pb = $null
    if (-not [version]::TryParse($A, [ref]$pa)) { return $null }
    if (-not [version]::TryParse($B, [ref]$pb)) { return $null }
    return $pa.CompareTo($pb)
}

# Any profile line that loads this file under a name it has had, or loads one
# of the two tools it replaced - chatrm and chatq define the same commands.
$script:ChatProfilePattern = '(chatrm|deleteLocalChat|chatq|VS-code-chat-manager|claude-codex-chat-manager|Charlie-and-the-chat-factory)\.ps1'

function chatinstall {
    <#
    .SYNOPSIS
    Add this script to your PowerShell profile, so the chat commands are there in
    every new shell. Dot-source the file once, then run chatinstall.
    .DESCRIPTION
    Writes the dot-source line into $PROFILE, creating the profile if there is
    none, and backing it up to $PROFILE.bak first. The script knows where it is,
    so no path has to be typed twice. A line left behind by an older copy is
    replaced rather than left to load nothing - run this again after moving the
    file.
    .PARAMETER Force
    Rewrite the line even when it is already there.
    .PARAMETER NoRestart
    Leave a running watcher and overlay on the copy they run. The VS Code
    extension installs into each PowerShell's profile in turn, and restarts
    them once, after the last.
    .EXAMPLE
    . C:\tools\Charlie-and-the-chat-factory\Charlie-and-the-chat-factory.ps1
    chatinstall
    #>
    [CmdletBinding()]
    param([switch]$Force, [switch]$NoRestart)
    Set-StrictMode -Off

    $me = $script:ChatScriptPath
    if (-not $me) {
        Write-Host '  cannot tell where this file is' -ForegroundColor Yellow
        Write-Host '  dot-source it by path first:  . C:\path\to\Charlie-and-the-chat-factory.ps1' -ForegroundColor DarkGray
        return
    }
    # only Windows marks downloads; elsewhere the cmdlet does not exist at all.
    # The parts in src/ too: a zip Explorer unpacked marks every file in it.
    if (Get-Command Unblock-File -EA SilentlyContinue) {
        Unblock-File -LiteralPath $me -EA SilentlyContinue
        Get-ChildItem -LiteralPath (Join-Path $script:ChatRoot 'src') -Filter *.ps1 -EA SilentlyContinue | Unblock-File -EA SilentlyContinue
    }

    # read before anything is written: data/ outlives the .ps1 an update
    # overwrites, so this is the only trace of which copy was here before
    $was = $null
    if (Test-Path -LiteralPath $script:ChatVersionPath) {
        $was = Get-Content -LiteralPath $script:ChatVersionPath -TotalCount 1 -EA SilentlyContinue
        if ($was) { $was = $was.Trim() }
    }

    $dir = Split-Path $PROFILE -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $lines = if (Test-Path -LiteralPath $PROFILE) { @(Get-Content -LiteralPath $PROFILE) } else { @() }

    # every name this file has had: deleteLocalChat.ps1, then chatrm.ps1, and
    # chatq.ps1 for the queue half. A profile still holding one of those lines
    # has to be repaired, not added to - and both chatrm and chatq loaded next
    # to this one would redefine the same commands
    $mine = @($lines | Where-Object { $_ -match $script:ChatProfilePattern })
    # IndexOf, not -like: a path is not a wildcard pattern, and one containing
    # [ or ] would never match itself - appending a second line every run
    $here = @($mine | Where-Object { $_.IndexOf($me, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
    if ($here -and -not $Force) {
        # Deliberately not a return: a reinstall still has to reach the index
        # check below. Bailing out here meant that deleting data/ and re-running
        # the installer left Tab with nothing to complete from, which is the
        # exact failure this was added to prevent.
        Write-Host '  already installed' -ForegroundColor DarkGray
        Write-Host "    $PROFILE" -ForegroundColor DarkGray
        Write-Host '    the script itself was just overwritten with this copy' -ForegroundColor DarkGray
    }
    else {
        # the whole file is rewritten to drop a stale line, so keep a copy: this
        # is the user's profile and may hold plenty unrelated to us
        if (Test-Path -LiteralPath $PROFILE) { Copy-Item -LiteralPath $PROFILE -Destination "$PROFILE.bak" -Force }
        $kept = @($lines | Where-Object { $_ -notmatch $script:ChatProfilePattern })
        $kept += ". `"$me`""
        Set-Content -LiteralPath $PROFILE -Value $kept -Encoding UTF8

        Write-Host '  installed' -ForegroundColor Green
        Write-Host "    $PROFILE"
        # only the lines that pointed somewhere else were really replaced - counting
        # the current one too claimed "from an older location" on a plain -Force rerun
        $stale = $mine.Count - $here.Count
        if ($stale -gt 0) {
            Write-Host "    replaced $stale line$(if ($stale -ne 1) { 's' }) from an older location" -ForegroundColor DarkGray
        }
        # Reaching this line means the file was dot-sourced - its path is
        # empty otherwise and it returns above - so the commands are already
        # defined right here. Saying "open a new terminal" sent people off to
        # reopen a shell that was already working.
        Write-Host '    ready in this shell - type chat' -ForegroundColor Green
        Write-Host '    every new shell picks it up from now on' -ForegroundColor DarkGray
    }

    # Both branches print this. "installed" on its own cannot tell a real upgrade
    # from the CDN handing back the copy you already had, which it does for
    # minutes after a push - so say which of the two just happened.
    if (-not $was) {
        Write-Host "    version $script:ChatVersion" -ForegroundColor DarkGray
    }
    elseif ($was -eq $script:ChatVersion) {
        Write-Host "    version $script:ChatVersion - unchanged" -ForegroundColor DarkGray
    }
    elseif ((Compare-ChatVersion $was $script:ChatVersion) -eq 1) {
        Write-Host "    DOWNGRADED $was -> $script:ChatVersion" -ForegroundColor Yellow
        Write-Host '    an older copy just overwrote a newer one' -ForegroundColor Yellow
    }
    else {
        Write-Host "    updated $was -> $script:ChatVersion" -ForegroundColor Green
    }

    # Either path, first install or reinstall. Tab reads the index and never
    # builds it - a keypress cannot afford 30s - so anything that removed data/
    # left nothing to complete from until some search happened to run.
    if (-not (Test-Path -LiteralPath $script:ChatIndexPath)) {
        Write-Host '    building the index for Tab completion (~30s)...' -ForegroundColor DarkGray
        # never let this fail the install - the index rebuilds on any search
        try {
            $n = @(Sync-ChatIndex).Count
            Write-Host "    indexed $n chat$(if ($n -ne 1) { 's' })" -ForegroundColor DarkGray
        }
        catch {
            Write-Host '    could not build it - run chatindex when convenient' -ForegroundColor Yellow
        }
    }

    # the queue half needs a CLI to resume chats with; finding and deleting do not
    if (-not (Find-ChatqExe claude) -and -not (Find-ChatqExe codex)) {
        Write-Host '    no claude or codex CLI found - chatq needs one, or CHATQ_CLAUDE / CHATQ_CODEX' -ForegroundColor Yellow
    }
    if (-not $NoRestart) { Restart-ChatBackground }

    # The extension defaults to ~/Tools/Charlie-and-the-chat-factory. Anywhere else
    # needs the setting, and without it its prompts simply never appear - a
    # silence that looks like the extension being broken.
    $defaultRoot = Join-Path (Join-Path $HOME 'Tools') 'Charlie-and-the-chat-factory'
    if ($script:ChatRoot -ne $defaultRoot) {
        Write-Host '    using the VS Code extension? set chatManager.folder to' -ForegroundColor DarkGray
        Write-Host "      $($script:ChatRoot)" -ForegroundColor DarkGray
    }

    # last, so a run that died earlier leaves the old stamp alone and the next
    # one still reports the real delta rather than comparing against a version
    # that never finished installing
    try {
        $vdir = Split-Path $script:ChatVersionPath -Parent
        if ($vdir -and -not (Test-Path -LiteralPath $vdir)) {
            New-Item -ItemType Directory -Path $vdir -Force | Out-Null
        }
        Set-Content -LiteralPath $script:ChatVersionPath -Value $script:ChatVersion -Encoding UTF8
    }
    catch {}
}

function Restart-ChatBackground {
    # A watcher already running is still the old code. It hands over to one
    # running this copy after its current job - never in the middle of one.
    if (Test-ChatqWatcherAlive) {
        Save-ChatqText $script:ChatqRestartPath 'restart'
        Write-Host '    the running watcher switches to this copy after its current job' -ForegroundColor DarkGray
    }
    # the overlay has no job to finish: it starts again on this copy now
    if (Test-ChatOverlayAlive) {
        Send-ChatOverlayCommand 'restart'
        Write-Host '    the overlay restarts on this copy' -ForegroundColor DarkGray
    }
}

function Test-ChatProfileLine {
    # $true when $PROFILE already loads this copy, the way chatinstall finds
    # its own line. The VS Code extension asks before it adds one, and needs
    # to ask nothing where the line is there already.
    # a host with no $PROFILE at all has no line, and Test-Path would throw
    $me = $script:ChatScriptPath
    if (-not $me -or -not $PROFILE -or -not (Test-Path -LiteralPath $PROFILE)) { return $false }
    return [bool](@(Get-Content -LiteralPath $PROFILE) | Where-Object {
            $_ -match $script:ChatProfilePattern -and $_.IndexOf($me, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
}

function chatuninstall {
    <#
    .SYNOPSIS
    Take the chat commands back out of your PowerShell profile.
    .DESCRIPTION
    Drops the dot-source line from $PROFILE, backing it up to $PROFILE.bak first,
    and leaves everything else in that file alone. Matches the old filename too,
    so a profile still carrying a deleteLocalChat line is cleaned as well.

    The commands stay defined in the shell you run this from - they are already
    in memory, and nothing can unload them. Close it and they are gone.

    The folder is left on disk by default, data/ and all, since it holds the
    index, the tombstones and any queued prompts. -All deletes it too.
    .PARAMETER All
    Also delete the script's own folder, including data/ and every queued
    prompt in it. Refused while data/archive/ holds archived chats, since
    those are the only copy - chatrestore them first, or add -Force.
    .PARAMETER Force
    With -All: delete the archive too.
    .EXAMPLE
    chatuninstall
    .EXAMPLE
    chatuninstall -All
    #>
    [CmdletBinding()]
    param([switch]$All, [switch]$Force)
    Set-StrictMode -Off
    $kept = @(Get-ChatArchive | Where-Object { $_.Dir })
    if ($All -and $kept -and -not $Force) {
        Write-Host "  $($kept.Count) archived chat$(if ($kept.Count -ne 1) { 's are' } else { ' is' }) in data/archive/ - the only copy there is" -ForegroundColor Yellow
        Write-Host '  chatrestore brings them back; chatuninstall -All -Force deletes them with the rest' -ForegroundColor DarkGray
        return
    }
    # the question hook (src/ask.ps1) runs a file in this folder from every
    # Claude Code chat: removed before the folder can go, and -All stops
    # when it cannot be - never a launcher deleted from under a live plugin
    $ask = Get-ChatqAskConfig
    # the plugin's folder stays until the plugin is gone, whatever ask.on says:
    # an -Ask off whose uninstall failed leaves it, and the plugin with it
    $plugged = Test-Path -LiteralPath (Get-ChatqAskPluginDir)
    if (($ask.On -or $plugged) -and $All) {
        if ($ask.Manual -and $ask.On) {
            Write-Host '  take the PermissionRequest hook naming ask-hook.ps1 out of your Claude settings first - it runs a file in this folder' -ForegroundColor Yellow
            return
        }
        $un = Uninstall-ChatqAskHook
        if (-not $un.Ok) {
            Write-Host "  the question hook could not be removed ($($un.Say)) - nothing deleted; chatnotify -Ask off, then chatuninstall -All again" -ForegroundColor Yellow
            return
        }
        Write-Host '  removed the question hook (the Claude Code plugin chatq-ask)' -ForegroundColor DarkGray
    }
    elseif ($ask.On) { Write-Host '  the question hook stays - chatnotify -Ask off removes it' -ForegroundColor DarkGray }

    # a live watcher outlasts the file it was started for, so stop it first -
    # the ghost watch in this shell, and chatq's background one
    Stop-ChatGhostWatch
    $pending = @(Get-ChatqJobs | Where-Object { $_.state -in 'queued', 'running' })
    if ($pending) {
        Write-Host "  $($pending.Count) job$(if ($pending.Count -ne 1) { 's' }) still queued - they will not be sent" -ForegroundColor Yellow
    }
    if (Test-ChatqWatcherAlive) {
        Save-ChatqText $script:ChatqStopPath 'stop'
        for ($i = 0; $i -lt 40 -and (Test-ChatqWatcherAlive); $i++) { Start-Sleep -Milliseconds 250 }
        Write-Host '  stopped the watcher' -ForegroundColor DarkGray
    }
    # and the overlay, whose open lock file would keep -All from deleting data/
    if ((Test-ChatOverlayAlive) -and (Stop-ChatOverlay)) { Write-Host '  stopped the overlay' -ForegroundColor DarkGray }

    $lines = if (Test-Path -LiteralPath $PROFILE) { @(Get-Content -LiteralPath $PROFILE) } else { @() }
    $mine = @($lines | Where-Object { $_ -match $script:ChatProfilePattern })
    if ($mine.Count) {
        Copy-Item -LiteralPath $PROFILE -Destination "$PROFILE.bak" -Force
        Set-Content -LiteralPath $PROFILE -Encoding UTF8 -Value `
        @($lines | Where-Object { $_ -notmatch $script:ChatProfilePattern })
        Write-Host "  removed $($mine.Count) line$(if ($mine.Count -ne 1) { 's' }) from the profile" -ForegroundColor Green
        Write-Host "    $PROFILE" -ForegroundColor DarkGray
        Write-Host "    backup: $PROFILE.bak" -ForegroundColor DarkGray
    }
    else {
        Write-Host '  nothing in the profile to remove' -ForegroundColor DarkGray
    }

    $here = if ($script:ChatScriptPath) { $script:ChatRoot } else { $null }
    if ($All) {
        if (-not $here) {
            Write-Host '  cannot tell where this file is - delete the folder by hand' -ForegroundColor Yellow
        }
        else {
            # the .ps1 is not held open once dot-sourced, so it can delete itself
            Remove-Item -LiteralPath $here -Recurse -Force -EA SilentlyContinue
            $gone = -not (Test-Path -LiteralPath $here)
            Write-Host "  $(if ($gone) { 'deleted' } else { 'COULD NOT DELETE' })  $here" -ForegroundColor $(if ($gone) { 'Green' } else { 'Yellow' })
            if (-not $gone) { Write-Host '    something in it is open elsewhere' -ForegroundColor DarkGray }
        }
    }
    elseif ($here) {
        Write-Host "  the folder is still there - delete it when you want to:" -ForegroundColor DarkGray
        Write-Host "      Remove-Item -LiteralPath `"$here`" -Recurse -Force" -ForegroundColor Cyan
    }

    Write-Host '  these commands stay in this shell until you close it' -ForegroundColor DarkGray
}

function chat {
    <#
    .SYNOPSIS
    Cheat sheet for the chat commands. Type chat<Tab> to cycle through them.
    #>
    Set-StrictMode -Off
    Write-Host ''
    Write-Host '  find and delete' -ForegroundColor DarkGray
    Write-Host '  chatfind "text"        find chats by title or message' -ForegroundColor Cyan
    Write-Host '  chatrm <id> | "title"  delete a chat, permanently' -ForegroundColor Cyan
    Write-Host '  chatrm ... -Archive    put it away instead; chatrestore brings it back' -ForegroundColor Cyan
    Write-Host '  chatclean              delete ghost chats, list hidden ones again' -ForegroundColor Cyan
    Write-Host '  chatproviders          which tools were found, and where' -ForegroundColor Cyan
    Write-Host '  chatindex              rebuild the tab-completion index' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  queue prompts for when the usage limit resets' -ForegroundColor DarkGray
    Write-Host '  chatq "title" [-Prompt s]  queue a prompt for that chat' -ForegroundColor Cyan
    Write-Host '  chatqlist [-Board]     what is queued, when it sends, what ran' -ForegroundColor Cyan
    Write-Host '  chatqrm / chatqrun     drop a job / requeue one, or -Now' -ForegroundColor Cyan
    Write-Host '  chatqlog / chatnotify  what a run did / phone alerts' -ForegroundColor Cyan
    Write-Host '  chatnotify -Setup      phone alerts and replies from the phone, in a window' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  see what is running' -ForegroundColor DarkGray
    Write-Host '  chatoverlay            every open chat and live usage, always on top' -ForegroundColor Cyan
    Write-Host '  chatoverlay -Print     the same, once, in this console' -ForegroundColor Cyan
    Write-Host '  chatoverlay -Theme     dark, light or system; -Opacity 85' -ForegroundColor Cyan
    Write-Host '  chatoverlay -Width     260 to 800; -Rows 1 to 30 chats shown' -ForegroundColor Cyan
    Write-Host '  chatoverlay -UsageView lines, or bars with reset countdowns' -ForegroundColor Cyan
    Write-Host '  chatoverlay -Compact   on: one line a chat; -ChipDelay 400 ms' -ForegroundColor Cyan
    Write-Host '  chatoverlay -Recent    0 to 20 chats not open listed under them' -ForegroundColor Cyan
    Write-Host '  chatconsole            write, queue and continue chats in a window' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  chatinstall            load these in every new shell (once)' -ForegroundColor DarkGray
    Write-Host '  chatuninstall [-All]   undo that; -All removes the folder too' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Tab fills in the argument: type any part of a title, no quotes needed'
    Write-Host '  -Provider claude|copilot|codex   -Deep   -All   -AllProjects   -Force'
    Write-Host '  Get-Help chatfind -Full           full help, examples and notes'
    Write-Host ''
    Write-Host "  Charlie-and-the-chat-factory $script:ChatVersion" -ForegroundColor DarkGray
    Write-Host "  $script:ChatScriptPath" -ForegroundColor DarkGray
    Write-Host ''
}

# verb-noun aliases so Get-Command *-Chat* and Find-<Tab> surface these too
Set-Alias -Name Find-Chat -Value chatfind -Scope Global -Force
Set-Alias -Name Remove-Chat -Value chatrm -Scope Global -Force
Set-Alias -Name Get-ChatProvider -Value chatproviders -Scope Global -Force
Set-Alias -Name Update-ChatIndex -Value chatindex -Scope Global -Force
# chatnotify's old name, from when it only served chatq's queue; a profile
# or a habit that still types it keeps working. Global like the ones above.
Set-Alias -Name chatqnotify -Value chatnotify -Scope Global -Force

Register-ArgumentCompleter -CommandName chatfind, chatrm, chatindex -ParameterName Provider -ScriptBlock {
    param($cmd, $param, $word)
    @('claude', 'copilot', 'codex') | Where-Object { $_ -like "$word*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
    }
}

function Get-ChatCells {
    # width in console cells, not characters: Hangul and CJK draw two cells
    # each, so String.Length leaves a column of Korean titles ragged
    param([string]$Text)
    $n = 0
    foreach ($c in $Text.ToCharArray()) {
        $u = [int]$c
        if (($u -ge 0x1100 -and $u -le 0x115F) -or ($u -ge 0x2E80 -and $u -le 0x303E) -or
            ($u -ge 0x3041 -and $u -le 0x33FF) -or ($u -ge 0x3400 -and $u -le 0x4DBF) -or
            ($u -ge 0x4E00 -and $u -le 0x9FFF) -or ($u -ge 0xA000 -and $u -le 0xA4CF) -or
            ($u -ge 0xAC00 -and $u -le 0xD7A3) -or ($u -ge 0xF900 -and $u -le 0xFAFF) -or
            ($u -ge 0xFE30 -and $u -le 0xFE6F) -or ($u -ge 0xFF00 -and $u -le 0xFF60) -or
            ($u -ge 0xFFE0 -and $u -le 0xFFE6)) { $n += 2 } else { $n++ }
    }
    return $n
}

function Format-ChatCell {
    # clip to exactly $Cells console cells, padding short text out to the same
    # unless -NoPad, which callers use when they are joining pieces themselves
    param([string]$Text, [int]$Cells, [switch]$NoPad)
    # a narrow terminal can hand in zero or less, and ' ' * -1 throws
    if ($Cells -le 0) { return '' }
    $w = Get-ChatCells $Text
    if ($w -le $Cells) {
        if ($NoPad) { return $Text }
        return $Text + (' ' * ($Cells - $w))
    }
    # three ASCII dots, not U+2026: the ellipsis and the middle dot draw two
    # cells wide in a CP949 console, which throws off every in-place redraw
    if ($Cells -le 3) { return '.' * $Cells }
    # one character at a time rather than re-measuring a growing prefix
    $len = 0
    $used = 0
    while ($len -lt $Text.Length) {
        $cw = Get-ChatCells $Text.Substring($len, 1)
        if ($used + $cw -gt $Cells - 3) { break }
        $used += $cw
        $len++
    }
    $out = $Text.Substring(0, $len) + '...'
    if ($NoPad) { return $out }
    return $out + (' ' * [Math]::Max(0, $Cells - $used - 3))
}

function Get-ChatSyntaxColor {
    # PSReadLine's own colours, read from the live options rather than guessed,
    # so the walked line is painted exactly like the line Tab writes into the
    # buffer - and follows the user's theme if they changed it
    if ($script:ChatColors) { return $script:ChatColors }
    $esc = [char]27
    $c = @{
        Command = "$esc[93m"; String = "$esc[36m"
        Param   = "$esc[90m"; Comment = "$esc[32m"; Reset = "$esc[0m"
    }
    $o = try { Get-PSReadLineOption -EA Stop } catch { $null }
    if ($o) {
        if ($o.CommandColor) { $c.Command = $o.CommandColor }
        if ($o.StringColor) { $c.String = $o.StringColor }
        if ($o.ParameterColor) { $c.Param = $o.ParameterColor }
        if ($o.CommentColor) { $c.Comment = $o.CommentColor }
    }
    $script:ChatColors = $c
    return $c
}

function Format-ChatMenuRow {
    # One menu row: title, owner, age, opening prompt. PSReadLine 2.0 draws no
    # tooltip, so this line is the whole preview. Fixed columns rather than
    # free text - run together, the rows read as one paragraph.
    param($Row, [int]$Extra = 0)
    $when = try {
        Get-ChatAge ([datetime]::Parse($Row.When, [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind))
    }
    catch { '?' }
    $tag = if ($Extra) { "[$Extra chats $when]" } else { "[$($Row.Provider) $when]" }

    $total = [Math]::Max(24, $Host.UI.RawUI.WindowSize.Width - 4)
    $tagCells = 15
    $titleCells = [Math]::Max(12, [Math]::Min(44, [int]($total * 0.42)))
    $rest = $total - $titleCells - $tagCells - 2
    if ($rest -lt 12) {
        # too narrow for an excerpt - give the space back to the title
        $titleCells = [Math]::Max(8, $total - $tagCells - 1)
        $rest = 0
    }

    $text = (Format-ChatCell $Row.Title $titleCells) + ' ' + (Format-ChatCell $tag $tagCells)
    $first = @($Row.First)[0]
    if ($rest -and $first) {
        $text += ' ' + (Format-ChatCell ('> ' + ($first -replace '\s+', ' ')) $rest)
    }
    return $text
}

function Get-ChatCompletionPreview {
    # the multi-line tooltip - shown by Ctrl+Space and PSReadLine 2.2+
    param($Row, [int]$Extra = 0)
    $when = try {
        Get-ChatAge ([datetime]::Parse($Row.When, [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind))
    }
    catch { '?' }
    $lines = @("$($Row.Title)", "$($Row.Provider) / $($Row.Group) / $when")
    if ($Extra) { $lines += "$Extra chats share this title - you pick from a list" }
    $clip = { param($t) if ($t.Length -gt 76) { $t.Substring(0, 76) + '...' } else { $t } }
    foreach ($m in @($Row.First) | Select-Object -First 2) { $lines += '  > ' + (& $clip $m) }
    $tail = @($Row.Last)
    if ($tail -and (@($Row.First) -join "`n") -ne ($tail -join "`n")) {
        $lines += '  ...'
        $lines += '  > ' + (& $clip $tail[-1])
    }
    return ($lines -join "`n")
}

$script:ChatTitleCompleter = {
    # One completer for chatrm, chatfind and chatq. All five parameters, because
    # the last one - the switches already typed - is how -All and -AllProjects
    # reach it; with three, Tab offered what the command then refused to match.
    param($cmd, $param, $word, $ast, $bound)
    Set-StrictMode -Off
    $w = ([string]$word).Trim('"', "'")
    $queue = $cmd -eq 'chatq'
    # chatq 3 means job 3 - a number is not the start of a title
    if ($queue -and $w -match '^\d{1,4}$') { return }
    $all = $bound -and [bool]$bound['All']
    $wide = $bound -and [bool]$bound['AllProjects']
    # (empty) are abandoned sessions; Hidden ones are subagents, which the
    # search skips without -All, so Tab must not offer them either
    $rows = @(Get-ChatIndex | Where-Object { $_.Title -ne '(empty)' -and ($all -or -not $_.Hidden) })
    # a queued prompt needs a CLI to resume the chat, and Copilot has none
    if ($queue) { $rows = @($rows | Where-Object { $_.Provider -in 'claude', 'codex' }) }
    if (-not $rows) {
        # Hand back what was typed, never ''. CompletionText REPLACES the word,
        # so returning '' wiped the argument and left a bare pair of quotes on
        # the line - it read as a broken completer rather than an empty index.
        # Echoing the word leaves the line alone; the hint rides in the tooltip.
        return [System.Management.Automation.CompletionResult]::new(
            $word, 'no index yet - run chatindex', 'ParameterValue',
            'No index yet - run chatindex once (~30s), or any chatfind')
    }

    # hex looks like an id - and ids are never scoped, one id is one chat. A
    # title can start with hex letters too ('add', 'cafe'), so no id match
    # falls through to titles rather than completing nothing.
    if ($w -match '^[0-9a-fA-F]{2,}$') {
        $ids = @($rows | Where-Object { $_.Id -like "$w*" })
        if ($ids) {
            return $ids | Sort-Object When -Descending | Select-Object -First 25 | ForEach-Object {
                [System.Management.Automation.CompletionResult]::new(
                    $_.Id, (Format-ChatMenuRow $_), 'ParameterValue',
                    (Get-ChatCompletionPreview $_))
            }
        }
    }

    # titles are scoped like the search is
    $rows = @(Select-ChatInProject $rows -AllProjects:$wide)
    $starts = @($rows | Where-Object { -not $w -or $_.Title.StartsWith($w, [StringComparison]::OrdinalIgnoreCase) })
    if (-not $starts -and $w) {
        $starts = @($rows | Where-Object { $_.Title.IndexOf($w, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
    }
    $starts |
        Group-Object Title | ForEach-Object {
            $newest = ($_.Group | Sort-Object When -Descending)[0]
            $extra = if ($_.Count -gt 1) { $_.Count } else { 0 }
            [pscustomobject]@{
                Title = $_.Name; When = $newest.When
                Label = Format-ChatMenuRow $newest $extra
                Tip   = Get-ChatCompletionPreview $newest $extra
            }
        } |
        Sort-Object When -Descending | Select-Object -First 25 | ForEach-Object {
            # single quotes: titles carry apostrophes, $ and braces that would
            # otherwise be interpreted when the line is run - and every quote
            # PowerShell treats as one is doubled, typographic ones included
            $quoted = "'" + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($_.Title) + "'"
            [System.Management.Automation.CompletionResult]::new($quoted, $_.Label, 'ParameterValue', $_.Tip)
        }
}

# the same titles for all three, under their own parameter names
Register-ArgumentCompleter -CommandName chatrm -ParameterName Target -ScriptBlock $script:ChatTitleCompleter
Register-ArgumentCompleter -CommandName chatfind -ParameterName Text -ScriptBlock $script:ChatTitleCompleter
Register-ArgumentCompleter -CommandName chatq -ParameterName Target -ScriptBlock $script:ChatTitleCompleter

# ---------------------------- the one-line cycler ----------------------------
# Tab does not open a list, and does not complete the word under the cursor. It
# replaces the whole argument with one chat and describes it on the same line,
# in a trailing comment PowerShell ignores; arrows walk to the next one.
# It has to work this way: a preview pane of our own would have to read the
# arrow keys itself, and inside a key handler PSReadLine's key reader is
# already blocked on the console waiting for them - the two race and the pane
# never gets a keystroke. Rewriting the buffer needs no keyboard at all.

$script:ChatCycle = $null

function Get-ChatCycleRows {
    # candidates for the cycler: ids if it looks like one, else titles,
    # prefix first and only then widening to a contains-match
    param([string]$Filter, [ref]$ById, [switch]$Queue)
    # scoped like the search is: offering a chat from another project that
    # chatrm would then refuse to match is worse than offering nothing. Hidden
    # rows (subagents) too, which the search skips without -All.
    $all = @(Get-ChatIndex | Where-Object { $_.Title -ne '(empty)' -and -not $_.Hidden })
    # chatq can only resume what a CLI can: no Copilot
    if ($Queue) { $all = @($all | Where-Object { $_.Provider -in 'claude', 'codex' }) }
    $all = @(Select-ChatInProject $all)
    if ($Filter -match '^[0-9a-fA-F]{2,}$') {
        $hit = @($all | Where-Object { $_.Id -like "$Filter*" })
        if ($hit) {
            $ById.Value = $true
            return @($hit | Sort-Object When -Descending | Select-Object -First 40)
        }
    }
    $ById.Value = $false
    $rows = @($all | Where-Object { -not $Filter -or $_.Title.StartsWith($Filter, [StringComparison]::OrdinalIgnoreCase) })
    if (-not $rows -and $Filter) {
        $rows = @($all | Where-Object { $_.Title.IndexOf($Filter, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
    }
    # one entry per title - chatrm sorts out duplicates itself, with its own list
    $uniq = $rows | Group-Object Title | ForEach-Object { ($_.Group | Sort-Object When -Descending)[0] }
    return @($uniq | Sort-Object When -Descending | Select-Object -First 40)
}

function Get-ChatRowAge {
    # The cycler runs off the cached index, which is only as fresh as the last
    # chatfind or chatrm - it read 2h for a chat the panel called 32m, because
    # the chat had grown 1.1 MB since the index was written. Only one row is
    # ever on screen, so re-read that one when its file has moved. The walk
    # after Enter needs none of this: Find-ChatSessions syncs first.
    param($Row)
    $when = try {
        [datetime]::Parse($Row.When, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind)
    }
    catch { $null }
    $f = Get-Item -LiteralPath $Row.Path -EA SilentlyContinue
    if ($f -and ($f.Length -ne $Row.Size -or $f.LastWriteTimeUtc.Ticks -ne $Row.Mtime)) {
        $name = Get-ChatProviderForPath $Row.Path
        $rec = if ($name) { & $script:ChatProviders[$name].Describe $f } else { $null }
        if ($rec) { $when = $rec.When }
    }
    if ($when) { return Get-ChatAge $when }
    return ''
}

function Set-ChatCycleLine {
    # move by $Step through the run and rewrite the whole buffer
    param([int]$Step)
    $c = $script:ChatCycle
    $c.Index = ($c.Index + $Step) % $c.Items.Count
    if ($c.Index -lt 0) { $c.Index += $c.Items.Count }
    $row = $c.Items[$c.Index]

    $pick = if ($c.ById) { $row.Id } else { "'" + $row.Title.Replace("'", "''") + "'" }
    $head = $c.Head + $pick
    # once per chat per run: re-reading a growing transcript costs ~300ms, and
    # arrowing back and forth would pay it again every time
    if (-not $c.Ages.ContainsKey($row.Path)) { $c.Ages[$row.Path] = Get-ChatRowAge $row }
    # the same tail the walk shows, so both look like one another
    $line = $head + (Format-ChatPickTail $c.Ages[$row.Path] ($c.Index + 1) $c.Items.Count)

    $cur = $null; $pos = 0
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$cur, [ref]$pos)
    [Microsoft.PowerShell.PSConsoleReadLine]::Replace(0, $cur.Length, $line)
    # leave the cursor on the chat, not out in the comment
    [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition($head.Length)
    $c.Line = $line
}

function Test-ChatCycling {
    # still on the line we wrote last time?
    param([string]$Line)
    $script:ChatCycle -and $script:ChatCycle.Line -eq $Line
}

function Test-ChatPartialTarget {
    # Is what was typed part of a title rather than all of it? Enter fills the
    # match in instead of running when it is, so the whole title is on screen
    # before anything acts on it. Every uncertain answer is $false: Enter then
    # keeps its ordinary meaning, and chatrm's own confirm still stands behind.
    param([string]$Line)
    try {
        $m = [regex]::Match($Line, '^\s*chatrm\s+')
        if (-not $m.Success) { return $false }
        $arg = ($Line.Substring($m.Length) -replace $script:ChatTailPattern, '').Trim()
        if (-not $arg) { return $false }
        # a switch means this is not a bare title, and -Force is a decision
        # already made - neither should have Enter quietly do something else
        if ($arg -match '(^|\s)-\w') { return $false }
        $arg = $arg.Trim("'", '"').Trim()
        if (-not $arg) { return $false }
        # an id is exact by definition, and never scoped to a project
        if ($arg -match '^[0-9a-fA-F]{6,}(-[0-9a-fA-F-]*)?$') { return $false }
        if (-not (Test-Path -LiteralPath $script:ChatIndexPath)) { return $false }

        $rows = @(Select-ChatInProject @(Get-ChatIndex | Where-Object { $_.Title -ne '(empty)' -and -not $_.Hidden }))
        if (-not $rows) { return $false }
        # a title typed in full is a decision, however many others contain it
        foreach ($r in $rows) {
            if ($r.Title.Equals($arg, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        }
        foreach ($r in $rows) {
            if ($r.Title.IndexOf($arg, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
        }
        return $false
    }
    catch { return $false }
}

function Start-ChatCycle {
    # begin a run from whatever has been typed after the command
    param([string]$Line)
    $m = [regex]::Match($Line, '^\s*chat(rm|find|q)\s+')
    if (-not $m.Success) { return $false }
    $queue = $m.Groups[1].Value -eq 'q'
    $arg = $Line.Substring($m.Length)
    # everything after the command is the filter, spaces and quotes included - a
    # quote the user opened is dropped here and Set-ChatCycleLine puts single
    # ones back, so typing one neither helps the match nor breaks it
    $arg = ($arg -replace $script:ChatTailPattern, '').Trim().Trim("'", '"').Trim()
    if ($arg.StartsWith('-')) { return $false }        # a parameter, not a title
    # chatq 3 is job 3, and chatq 'title' -Prompt ... is past the title already
    if ($queue -and ($arg -match '^\d{1,4}$' -or $arg -match '\s-\w')) { return $false }
    $byId = $false
    # an absent index is not the same as no match, and silence made the two look
    # identical - the caller says so rather than leaving Tab looking broken
    if (-not (Test-Path -LiteralPath $script:ChatIndexPath)) {
        $script:ChatNoIndex = $true
        return $false
    }
    $script:ChatNoIndex = $false
    $rows = @(Get-ChatCycleRows $arg ([ref]$byId) -Queue:$queue)
    if (-not $rows) { return $false }
    $script:ChatCycle = @{
        Head  = $Line.Substring(0, $m.Length)
        Items = $rows
        Index = -1
        ById  = $byId
        Line  = ''
        Ages  = @{}
    }
    Set-ChatCycleLine 1
    return $true
}

# Tab starts or advances the run, Shift+Tab steps back, and the arrows do the
# same but only while a run is live - otherwise they stay history navigation.
# Opt out with $ChatNoKeyBindings = $true before the dot-source line. Read
# through Get-Variable: under StrictMode an unset one throws, and every shell
# start would lose its key handlers. Never in the background watcher or the
# overlay, which have no keyboard, nor anywhere else not interactive.
if (-not (Get-Variable -Name ChatNoKeyBindings -ValueOnly -EA SilentlyContinue) -and
    -not $env:CHATQ_WATCHER -and -not $env:CHATQ_OVERLAY -and [Environment]::UserInteractive -and
    (Get-Module PSReadLine -ListAvailable -EA SilentlyContinue)) {
    try {
        Import-Module PSReadLine -EA Stop

        # remember what the arrows did before we took them over
        $script:ChatArrowWas = @{}
        foreach ($k in 'UpArrow', 'DownArrow') {
            $bound = Get-PSReadLineKeyHandler -Bound | Where-Object { $_.Key -eq $k }
            $script:ChatArrowWas[$k] = if ($bound) { $bound.Function } else { $null }
        }

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

        Set-PSReadLineKeyHandler -Key Tab -BriefDescription 'ChatCycleNext' `
            -Description 'Fill in the next matching chat, described in a trailing comment' -ScriptBlock {
            Set-StrictMode -Off
            $line = $null; $pos = 0
            [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$pos)
            if (Test-ChatCycling $line) { Set-ChatCycleLine 1; return }
            $script:ChatCycle = $null
            if (-not (Start-ChatCycle $line)) {
                # No index at all is worth saying out loud. Falling through to
                # TabCompleteNext here is what put a bare '' on the line and made
                # an empty index look like a broken completer.
                if ($script:ChatNoIndex) {
                    try {
                        [Microsoft.PowerShell.PSConsoleReadLine]::AddToHistory($null)
                    }
                    catch {}
                    Write-Host ''
                    Write-Host '  no index yet - run chatindex once (~30s)' -ForegroundColor Yellow
                    # redraw, or the line is left sitting under what was printed
                    try { [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt() } catch {}
                    return
                }
                [Microsoft.PowerShell.PSConsoleReadLine]::TabCompleteNext()
            }
        }

        Set-PSReadLineKeyHandler -Key Shift+Tab -BriefDescription 'ChatCyclePrev' `
            -Description 'Step back through the matching chats' -ScriptBlock {
            Set-StrictMode -Off
            $line = $null; $pos = 0
            [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$pos)
            if (Test-ChatCycling $line) { Set-ChatCycleLine -1; return }
            [Microsoft.PowerShell.PSConsoleReadLine]::TabCompletePrevious()
        }

        Set-PSReadLineKeyHandler -Key DownArrow -BriefDescription 'ChatCycleOrHistory' `
            -Description 'Next matching chat while cycling, history otherwise' -ScriptBlock {
            Set-StrictMode -Off
            $line = $null; $pos = 0
            [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$pos)
            if (Test-ChatCycling $line) { Set-ChatCycleLine 1; return }
            Invoke-ChatPSReadLine $script:ChatArrowWas['DownArrow'] 'NextHistory'
        }

        Set-PSReadLineKeyHandler -Key UpArrow -BriefDescription 'ChatCycleOrHistory' `
            -Description 'Previous matching chat while cycling, history otherwise' -ScriptBlock {
            Set-StrictMode -Off
            $line = $null; $pos = 0
            [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$pos)
            if (Test-ChatCycling $line) { Set-ChatCycleLine -1; return }
            Invoke-ChatPSReadLine $script:ChatArrowWas['UpArrow'] 'PreviousHistory'
        }

        Set-PSReadLineKeyHandler -Key Enter -BriefDescription 'ChatAcceptLine' `
            -Description 'Drop the age and counter, then run the line' -ScriptBlock {
            Set-StrictMode -Off
            $line = $null; $pos = 0
            [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$pos)
            # not only while cycling: the tail survives an edit, and left on the
            # line "(5d)" would be run as an expression rather than ignored
            if ($line -match '^\s*chat(rm|find|q)\s') {
                $clean = $line -replace $script:ChatTailPattern, ''
                # chatq goes on past the title (-Prompt ...). The cursor is left
                # before the tail, but text typed after it would put -Prompt in
                # the comment and leave "(5d)" mid-line to be run
                if ($clean -match '^\s*chatq\s') { $clean = $clean -replace $script:ChatMidTailPattern, '' }
                if ($clean -ne $line) {
                    [Microsoft.PowerShell.PSConsoleReadLine]::Replace(0, $line.Length, $clean)
                    $line = $clean
                }
                $script:ChatCycle = $null

                # chatrm only, and only when the argument is part of a title
                # rather than all of it: fill the title in the way Tab would and
                # hold the line, so the whole thing is on screen before Enter
                # can act on it. chatfind is a search and deletes nothing, so it
                # runs as typed.
                # never let this break Enter: a throw inside a key handler makes
                # the key unusable, which would be far worse than the eager
                # delete it exists to prevent
                try {
                    if ($line -match '^\s*chatrm\s' -and (Test-ChatPartialTarget $line)) {
                        if (Start-ChatCycle $line) { return }
                    }
                }
                catch {}
            }
            [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
        }
    }
    catch {}
}

#endregion
