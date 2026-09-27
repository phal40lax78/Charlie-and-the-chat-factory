# VS-code-chat-manager, src/chatrm.ps1: dot-sourced by VS-code-chat-manager.ps1
# in its turn, never on its own - see the list there.

#region search and delete -----------------------------------------------------

function Get-ChatProjectScope {
    # What "this project" means to each tool. Claude names its project folder
    # after the whole path with every non-alphanumeric turned into a dash;
    # Copilot and Codex only ever record the leaf folder name.
    param([string]$Path = $PWD.Path)
    $full = $Path.TrimEnd('\', '/')
    [pscustomobject]@{
        Slug = Get-ChatSlug $full
        Leaf = Split-Path $full -Leaf
    }
}

function Test-ChatInProject {
    # Exact, never a prefix. Sibling repos nest - the slug for D:\src\app is a
    # prefix of the one for D:\src\app-Mobile - so -like or StartsWith
    # would quietly drag the neighbour in, which is the bug this exists to fix.
    param($Row, $Scope)
    if (-not $Row.Group) { return $false }
    if ($Row.Provider -eq 'claude') { return $Row.Group -eq $Scope.Slug }
    return $Row.Group -eq $Scope.Leaf
}

function Select-ChatInProject {
    # Narrow rows to the project being stood in. Returns them untouched when
    # this directory is not a project any tool knows - otherwise running from
    # anywhere else would match nothing at all.
    # -Cwd for the background watcher, whose own folder is wherever the first
    # chatq happened to be typed, not the job's
    param([object[]]$Rows, [switch]$AllProjects, [string]$Cwd = $PWD.Path)
    if ($AllProjects -or -not $Rows) { return $Rows }
    $scope = Get-ChatProjectScope $Cwd
    $mine = @($Rows | Where-Object { Test-ChatInProject $_ $scope })
    if ($mine) { return $mine }
    return $Rows
}

function Find-ChatSessions {
    param(
        [string]$Needle,
        [string[]]$Provider,
        [switch]$Deep,
        [switch]$All,
        [switch]$AllProjects,
        [switch]$TitleOnly
    )
    # match against the index; only matches are turned back into file objects
    $rows = Select-ChatInProject @(Sync-ChatIndex -Provider $Provider) -AllProjects:$AllProjects
    foreach ($row in $rows) {
        if ($row.Hidden -and -not $All) { continue }
        $hit = if ($Deep) {
            Select-String -Path $row.Path -SimpleMatch -Pattern $Needle -Quiet -EA SilentlyContinue
        }
        elseif ($TitleOnly) {
            # literal, not -like: a completed title may contain [ ] ? or *
            $row.Title.IndexOf($Needle, [StringComparison]::OrdinalIgnoreCase) -ge 0
        }
        else {
            ($row.Title -like "*$Needle*") -or
            [bool](@($row.First) + @($row.Last) | Where-Object { $_ -like "*$Needle*" })
        }
        if (-not $hit) { continue }
        $file = try { Get-Item -LiteralPath $row.Path -EA Stop } catch { continue }
        [pscustomobject]@{
            Provider = $row.Provider
            File     = $file
            Record   = [pscustomobject]@{
                Id          = $row.Id
                Title       = $row.Title
                TitleSource = $row.Titled
                Group       = $row.Group
                Hidden      = $row.Hidden
                When        = [datetime]::Parse($row.When, [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::RoundtripKind)
                First       = @($row.First)
                Last        = @($row.Last)
            }
        }
    }
}

function chatfind {
    <#
    .SYNOPSIS
    Find local AI chat transcripts by title or message text.
    .DESCRIPTION
    Searches Claude Code, Copilot Chat and Codex transcripts on this machine and
    returns one object per match, so results can be piped. Also refreshes the
    index that makes chatrm's tab completion instant.
    .PARAMETER Text
    Text to look for in the chat title and the first/last user messages.
    .PARAMETER Provider
    Limit the search: claude, copilot, codex. Defaults to all of them.
    .PARAMETER Deep
    Match anywhere in the transcript rather than title and previews. Slower.
    .PARAMETER All
    Include subagent / workflow transcripts, which are hidden by default.
    .PARAMETER AllProjects
    Search every project rather than the one this directory belongs to.
    .EXAMPLE
    chatfind "brownout"
    .EXAMPLE
    chatfind gitignore -Provider copilot | Select-Object Title, Id, Age
    .LINK
    chatrm
    #>
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments)][string[]]$Text,
        [string[]]$Provider,
        [switch]$Deep,
        [switch]$All,
        [switch]$AllProjects
    )
    Set-StrictMode -Off

    $needle = $Text -join ' '
    if (-not $needle) { Write-Error 'usage: chatfind "text" [-Provider claude,copilot,codex] [-Deep] [-All] [-AllProjects]'; return }
    # emits objects, not formatted text, so results stay pipeable
    Find-ChatSessions -Needle $needle -Provider $Provider -Deep:$Deep -All:$All -AllProjects:$AllProjects | ForEach-Object {
        $r = $_.Record
        [pscustomobject]@{
            Title    = $r.Title
            Titled   = $r.TitleSource
            Provider = $_.Provider
            Id       = $r.Id
            Group    = $r.Group
            Age      = Get-ChatAge $r.When
            LastAt   = $r.When.ToString('yyyy-MM-dd HH:mm')
            Touched  = Get-ChatAge $_.File.LastWriteTime   # mtime, as the GUIs show it
            MB       = [math]::Round($_.File.Length / 1MB, 2)
            First    = Format-ChatMessages $r.First
            Recent   = if (($r.First -join "`n") -eq ($r.Last -join "`n")) { '(same)' } else { Format-ChatMessages $r.Last }
        }
    }
}

function Get-ChatProviderForPath {
    param([string]$Path)
    foreach ($e in $script:ChatProviders.GetEnumerator()) {
        if ($e.Value.Root -and $Path.StartsWith($e.Value.Root, [StringComparison]::OrdinalIgnoreCase)) {
            return $e.Key
        }
    }
    return $null
}

function Add-ChatTombstone {
    # Remember what was deleted, because the window will write some of it back
    param([string]$Path)
    $dir = Split-Path $script:ChatTombPath -Parent
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    Add-Content -LiteralPath $script:ChatTombPath -Value ("{0}`t{1}" -f (Get-Date).ToString('o'), $Path)
    Start-ChatGhostWatch
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

function Clear-ChatTombstones {
    # The window does not write a deleted session back straight away - it
    # flushes session state when it reloads or closes, minutes later, and the
    # file reappears with a brand new creation time.
    #
    # Start-ChatGhostWatch catches that write as it happens, but only while a
    # shell that loaded this file is open. This is the backstop for the rest:
    # the deletion is remembered, and taken again the next time any of these
    # commands runs, in whatever shell.
    #
    # Only ever removes a file that is still a stub, so resuming one of these
    # sessions for real makes it stop being a tombstone's business.
    if (-not (Test-Path -LiteralPath $script:ChatTombPath)) { return }
    $keep = [System.Collections.Generic.List[string]]::new()
    $took = 0
    $cutoff = (Get-Date).AddDays(-7)
    foreach ($line in @(Get-Content -LiteralPath $script:ChatTombPath -EA SilentlyContinue)) {
        $parts = $line -split "`t", 2
        if ($parts.Count -ne 2) { continue }
        $when = try {
            [datetime]::Parse($parts[0], [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind)
        }
        catch { continue }
        if ($when -lt $cutoff) { continue }        # long gone, stop watching it
        $path = $parts[1]
        if (Test-Path -LiteralPath $path) {
            $file = Get-Item -LiteralPath $path -EA SilentlyContinue
            $name = Get-ChatProviderForPath $path
            $prov = if ($name) { $script:ChatProviders[$name] } else { $null }
            if ($file -and $prov -and $prov.IsEmpty -and (& $prov.IsEmpty $file)) {
                Remove-Item -LiteralPath $path -Force -EA SilentlyContinue
                if (-not (Test-Path -LiteralPath $path)) { $took++ }
            }
            elseif ($file) { continue }            # it has real content now - leave it, drop it
        }
        $keep.Add($line)
    }
    if ($keep.Count) {
        Set-Content -LiteralPath $script:ChatTombPath -Value $keep.ToArray()
        Start-ChatGhostWatch          # a new shell picks the watch back up
    }
    else {
        Remove-Item -LiteralPath $script:ChatTombPath -Force -EA SilentlyContinue
        Stop-ChatGhostWatch           # nothing left to watch for
    }
    if ($took) {
        Write-Host "  took back $took chat$(if ($took -ne 1) { 's' }) the window had rewritten" -ForegroundColor DarkGray
    }
}

function Test-ChatJobsHold {
    # $true when a prompt queued by chatq holds this chat and it must stay.
    # Deleting it would leave a job that resumes a transcript no longer there -
    # and a claude -p still running into it would write it straight back as a
    # fragment. -DropJobs drops them first, and waits out a running one.
    param($Hit, [switch]$DropJobs)
    $mine = { @(Get-ChatqJobs | Where-Object { $_.sessionId -eq $Hit.Record.Id }) }
    $held = @(& $mine | Where-Object { $_.state -in 'queued', 'running' })
    if (-not $held) { return $false }
    $nums = ($held | ForEach-Object { "#$($_.seq)" }) -join ' '
    if (-not $DropJobs) {
        Write-Host "  KEPT     $($Hit.Record.Title)" -ForegroundColor Yellow
        Write-Host "           $nums queued for it - -DropJobs drops them first" -ForegroundColor DarkGray
        return $true
    }
    foreach ($j in $held) { chatqrm $j.seq -Force }
    # a cancel is only read by the watcher, every few seconds
    $until = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $until -and @(& $mine | Where-Object { $_.state -eq 'running' })) {
        Start-Sleep -Milliseconds 500
    }
    if (@(& $mine | Where-Object { $_.state -eq 'running' })) {
        Write-Host "  KEPT     $($Hit.Record.Title)" -ForegroundColor Yellow
        Write-Host '           its run has not stopped yet - try again in a moment' -ForegroundColor DarkGray
        return $true
    }
    # a cancelled run ends as a failed job; nothing is left to send, so it goes
    foreach ($j in @(& $mine)) { chatqrm $j.seq -Force }
    return $false
}

function Remove-ChatSession {
    # Returns $true only if the transcript is actually gone. Windows refuses to
    # delete a file another process holds open, and Remove-Item reports that as
    # a non-terminating error - so without the check afterwards this printed
    # "deleted" for a chat that was still sitting there.
    param($Hit)
    $path = $Hit.File.FullName
    # What the chat leaves beside it, worked out while the transcript is still
    # there to read (a plan file is found by the slug inside it), and removed
    # only once the transcript is really gone: a chat a live window still holds
    # keeps its leftovers along with itself.
    $extras = @(& $script:ChatProviders[$Hit.Provider].Extras $Hit.File $Hit.Record)
    Remove-Item -LiteralPath $path -Force -EA SilentlyContinue
    if (Test-Path -LiteralPath $path) {
        Write-Host "  LOCKED   $($Hit.Record.Title)" -ForegroundColor Yellow
        Write-Host '           still on disk - another process has it open' -ForegroundColor DarkGray
        return $false
    }
    foreach ($p in $extras) {
        if ($p -and (Test-Path -LiteralPath $p)) { Remove-Item -LiteralPath $p -Recurse -Force -EA SilentlyContinue }
    }
    Add-ChatTombstone $path
    # the index is what Tab completes from, so a row left behind offers a title
    # whose transcript is already gone
    Remove-ChatIndexRow $path
    # the title, not the full row: the row is wider than a narrow panel and wraps
    Write-Host "  deleted  $($Hit.Record.Title)" -ForegroundColor DarkGray
    return $true
}

#region archive and restore ---------------------------------------------------
# chatrm -Archive puts a chat out of the way without losing it: a Claude chat
# and its leftovers move into data/archive/claude/<id>/ with a manifest of where
# each came from, a Codex thread goes through codex archive (Codex keeps thread
# state in its own databases, so only its CLI can archive one properly). The
# panel's list is left to forget it the same way it forgets a deleted chat.

$script:ChatArchiveDir = Join-Path (Join-Path $script:ChatRoot 'data') 'archive'

function Move-ChatItem {
    # Move-Item, else copy-then-delete: a folder cannot be moved across drives,
    # and nothing says data/ sits on the drive ~/.claude does
    param([string]$From, [string]$To)
    $parent = Split-Path $To -Parent
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    try { Move-Item -LiteralPath $From -Destination $To -Force -EA Stop; return $true } catch {}
    try {
        Copy-Item -LiteralPath $From -Destination $To -Recurse -Force -EA Stop
        Remove-Item -LiteralPath $From -Recurse -Force -EA Stop
        return $true
    }
    catch { return $false }
}

function Save-ChatArchive {
    # $true when the chat was archived
    param($Hit)
    $title = $Hit.Record.Title
    if ($Hit.Provider -eq 'copilot') {
        Write-Host "  KEPT     $title" -ForegroundColor Yellow
        Write-Host '           VS Code archives Copilot chats itself - from the chat list there' -ForegroundColor DarkGray
        return $false
    }
    if ($Hit.Provider -eq 'codex') { return (Save-ChatCodexArchive $Hit) }
    $id = $Hit.Record.Id
    # A chat still open in a window goes on writing to the path it came from,
    # which would leave half of it here and half in the archive.
    if (@(Get-ChatqLiveSessions $env:CLAUDE_CONFIG_DIR | Where-Object { $_.SessionId -eq $id })) {
        Write-Host "  KEPT     $title" -ForegroundColor Yellow
        Write-Host '           open in a VS Code window - close it there, or reload the window, then archive' -ForegroundColor DarkGray
        return $false
    }
    $dest = Join-Path (Join-Path $script:ChatArchiveDir 'claude') $id
    if (Test-Path -LiteralPath $dest) {
        Write-Host "  KEPT     $title" -ForegroundColor Yellow
        Write-Host '           an archived copy of this chat is already there - chatrestore it first' -ForegroundColor DarkGray
        return $false
    }
    $extras = @(Get-ClaudeLeftovers $Hit.File | Where-Object { Test-Path -LiteralPath $_ })
    $items = [System.Collections.Generic.List[object]]::new()
    # the transcript first: when that will not move, nothing else does
    $rel = "files\0-$($Hit.File.Name)"
    if (-not (Move-ChatItem $Hit.File.FullName (Join-Path $dest $rel))) {
        Remove-Item -LiteralPath $dest -Recurse -Force -EA SilentlyContinue
        Write-Host "  LOCKED   $title" -ForegroundColor Yellow
        Write-Host '           another process has it open' -ForegroundColor DarkGray
        return $false
    }
    $items.Add([ordered]@{ from = $Hit.File.FullName; stored = $rel; transcript = $true })
    $n = 0
    foreach ($p in $extras) {
        $n++
        $r = "files\$n-$(Split-Path $p -Leaf)"
        if (Move-ChatItem $p (Join-Path $dest $r)) { $items.Add([ordered]@{ from = $p; stored = $r; transcript = $false }) }
    }
    Save-ChatqJson (Join-Path $dest 'manifest.json') ([ordered]@{
            v = 1; provider = 'claude'; id = $id; title = $title; group = $Hit.Record.Group
            archivedAt = (Get-Date).ToUniversalTime().ToString('o'); items = @($items)
        })
    # the window writes a listed chat back as a stub when it reloads, exactly
    # as it does a deleted one - the same tombstone takes that back
    Add-ChatTombstone $Hit.File.FullName
    Remove-ChatIndexRow $Hit.File.FullName
    Write-Host "  archived $title" -ForegroundColor DarkGray
    return $true
}

function Save-ChatCodexArchive {
    param($Hit)
    $title = $Hit.Record.Title
    $exe = Find-ChatqExe codex
    if (-not $exe) {
        Write-Host "  KEPT     $title" -ForegroundColor Yellow
        Write-Host '           no codex CLI found - only codex archive can archive a Codex thread' -ForegroundColor DarkGray
        return $false
    }
    # stdin empty and closed: a CLI that waits on it would hang here
    $p = Invoke-ChatqProcess -Exe $exe -ArgList @('archive', $Hit.Record.Id) -StdIn '' -TimeoutSec 60 -SetEnv @{ CODEX_HOME = $env:CODEX_HOME }
    if ($p.ExitCode -ne 0 -or $p.Stopped) {
        $err = ("$($p.StdErr)" -replace '\s+', ' ').Trim()
        if ($err.Length -gt 160) { $err = $err.Substring($err.Length - 160) }
        Write-Host "  KEPT     $title" -ForegroundColor Yellow
        Write-Host "           codex archive failed: $err" -ForegroundColor DarkGray
        return $false
    }
    # Codex has no command that lists what it archived, so this is the record
    # chatrestore lists it from
    Save-ChatqJson (Join-Path (Join-Path (Join-Path $script:ChatArchiveDir 'codex') $Hit.Record.Id) 'manifest.json') ([ordered]@{
            v = 1; provider = 'codex'; id = $Hit.Record.Id; title = $title; group = $Hit.Record.Group
            archivedAt = (Get-Date).ToUniversalTime().ToString('o'); items = @([ordered]@{ from = $Hit.File.FullName })
        })
    Remove-ChatIndexRow $Hit.File.FullName
    Write-Host "  archived $title" -ForegroundColor DarkGray
    return $true
}

function Remove-ChatTombstone {
    # One path's line out of rewritten.txt - before a restored chat moves back,
    # or a ghost watch in some open shell takes it for a stub and deletes it
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $script:ChatTombPath)) { return }
    $keep = @(Get-Content -LiteralPath $script:ChatTombPath -EA SilentlyContinue | Where-Object {
            $parts = $_ -split "`t", 2
            $parts.Count -ne 2 -or $parts[1] -ne $Path
        })
    if ($keep) { Set-Content -LiteralPath $script:ChatTombPath -Value $keep }
    else { Remove-Item -LiteralPath $script:ChatTombPath -Force -EA SilentlyContinue; Stop-ChatGhostWatch }
}

function Get-ChatArchive {
    # What chatrestore can bring back: every chat chatrm archived, plus any
    # thread under Codex's own archived_sessions folder, if it keeps one there.
    $rows = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    if (Test-Path -LiteralPath $script:ChatArchiveDir) {
        foreach ($f in @(Get-ChildItem -LiteralPath $script:ChatArchiveDir -Filter manifest.json -File -Recurse -EA SilentlyContinue)) {
            $m = Read-ChatqJson $f.FullName
            if (-not $m -or -not $m.id) { continue }
            $seen[[string]$m.id] = $true
            $rows.Add([pscustomobject]@{
                    Provider = $m.provider; Id = [string]$m.id; Title = [string]$m.title; Group = $m.group
                    When = ConvertTo-ChatqDate $m.archivedAt; Dir = $f.DirectoryName; Manifest = $m
                })
        }
    }
    $cx = Join-Path $script:ChatCodexHome 'archived_sessions'
    if (Test-Path -LiteralPath $cx) {
        $names = Get-CodexThreadNames
        foreach ($f in @(Get-ChildItem -LiteralPath $cx -Filter 'rollout-*.jsonl' -File -Recurse -EA SilentlyContinue)) {
            $id = if ($f.BaseName -match '([0-9a-fA-F-]{36})$') { $Matches[1] } else { continue }
            if ($seen[$id]) { continue }
            $t = if ($names[$id]) { $names[$id] } else { $id }
            $rows.Add([pscustomobject]@{ Provider = 'codex'; Id = $id; Title = $t; Group = $null; When = $f.LastWriteTime; Dir = $null; Manifest = $null })
        }
    }
    return @($rows | Sort-Object When -Descending)
}

function Restore-ChatArchive {
    # $true when the chat is back where it was
    param($Row)
    if ($Row.Provider -eq 'codex') {
        $exe = Find-ChatqExe codex
        if (-not $exe) { Write-Host '  no codex CLI found - codex unarchive is the only way back' -ForegroundColor Yellow; return $false }
        $p = Invoke-ChatqProcess -Exe $exe -ArgList @('unarchive', $Row.Id) -StdIn '' -TimeoutSec 60 -SetEnv @{ CODEX_HOME = $env:CODEX_HOME }
        if ($p.ExitCode -ne 0 -or $p.Stopped) {
            Write-Host "  codex unarchive failed: $(("$($p.StdErr)" -replace '\s+', ' ').Trim())" -ForegroundColor Yellow
            return $false
        }
        if ($Row.Dir) { Remove-Item -LiteralPath $Row.Dir -Recurse -Force -EA SilentlyContinue }
        $null = Sync-ChatIndex -Provider codex
        Write-Host "  restored $($Row.Title)" -ForegroundColor Green
        return $true
    }
    $items = @($Row.Manifest.items)
    $main = @($items | Where-Object { $_.transcript }) | Select-Object -First 1
    if (-not $main) { Write-Host '  this archive has no transcript in it' -ForegroundColor Yellow; return $false }
    if (Test-Path -LiteralPath $main.from) {
        # the window's stub, written back after the archive - that may go; a
        # real chat written since may not, and nothing is moved over it
        $f = Get-Item -LiteralPath $main.from -EA SilentlyContinue
        if ($f -and (& $script:ChatProviders['claude'].IsEmpty $f)) { Remove-Item -LiteralPath $main.from -Force -EA SilentlyContinue }
        else {
            Write-Host "  KEPT IN ARCHIVE  $($Row.Title)" -ForegroundColor Yellow
            Write-Host "                   a chat with messages is at $($main.from) now - move it away first" -ForegroundColor DarkGray
            return $false
        }
    }
    # the tombstone before anything moves, or a ghost watch takes the file back
    Remove-ChatTombstone $main.from
    foreach ($it in $items) {
        $src = Join-Path $Row.Dir $it.stored
        if (-not (Test-Path -LiteralPath $src)) { continue }
        # a leftover recreated since - a newer file-history, say - wins
        if (-not $it.transcript -and (Test-Path -LiteralPath $it.from)) { continue }
        if (-not (Move-ChatItem $src $it.from)) {
            Write-Host "  could not move $src back to $($it.from)" -ForegroundColor Yellow
            if ($it.transcript) { return $false }
        }
    }
    Remove-Item -LiteralPath $Row.Dir -Recurse -Force -EA SilentlyContinue
    $null = Sync-ChatIndex -Provider claude
    Write-Host "  restored $($Row.Title)" -ForegroundColor Green
    return $true
}

function chatrestore {
    <#
    .SYNOPSIS
    Bring back a chat that chatrm -Archive put away. With nothing typed, list
    the archive.
    .DESCRIPTION
    A Claude chat moves back to where it was, leftovers and all, and shows up in
    the panel after a window reload. A Codex thread goes through codex
    unarchive. Tab completes the archived titles.
    .EXAMPLE
    chatrestore
    .EXAMPLE
    chatrestore 'Parser rewrite'
    #>
    param([Parameter(Position = 0, ValueFromRemainingArguments)][string[]]$Target)
    Set-StrictMode -Off
    $all = @(Get-ChatArchive)
    $t = ((@($Target) -join ' ').Trim()).Trim("'", '"').Trim()
    if (-not $t) {
        if (-not $all) { Write-Host '  nothing archived - chatrm <title> -Archive puts a chat here' -ForegroundColor DarkGray; return }
        Write-Host ''
        foreach ($r in $all) {
            $age = if ($r.When) { Get-ChatAge $r.When } else { '?' }
            Write-Host ('  {0,-7} {1,5}  {2}' -f $r.Provider, $age, $r.Title) -ForegroundColor Cyan
        }
        Write-Host '  chatrestore <title|id> brings one back' -ForegroundColor DarkGray
        Write-Host ''
        return
    }
    $hits = if ($t -match '^[0-9a-fA-F]{6,}(-[0-9a-fA-F-]*)?$') { @($all | Where-Object { $_.Id -like "$t*" }) } else { @() }
    if (-not $hits) { $hits = @($all | Where-Object { $_.Title.Equals($t, [StringComparison]::OrdinalIgnoreCase) }) }
    if (-not $hits) { $hits = @($all | Where-Object { $_.Title.IndexOf($t, [StringComparison]::OrdinalIgnoreCase) -ge 0 }) }
    if (-not $hits) { Write-Host "  nothing archived is titled like '$t' - chatrestore lists them" -ForegroundColor Yellow; return }
    if ($hits.Count -gt 1) {
        Write-Host "  '$t' matches $($hits.Count) archived chats - type more of the title, or its id:" -ForegroundColor Yellow
        foreach ($r in $hits) { Write-Host "    $($r.Id.Substring(0, [Math]::Min(8, $r.Id.Length)))  $($r.Title)" -ForegroundColor DarkGray }
        return
    }
    if (Restore-ChatArchive $hits[0]) {
        Write-Host '  reload the VS Code window to see it in the chat list' -ForegroundColor DarkGray
    }
}

Register-ArgumentCompleter -CommandName chatrestore -ParameterName Target -ScriptBlock {
    param($cmd, $param, $word)
    Set-StrictMode -Off
    $w = ([string]$word).Trim('"', "'")
    @(Get-ChatArchive) | Where-Object { -not $w -or $_.Title.IndexOf($w, [StringComparison]::OrdinalIgnoreCase) -ge 0 } |
        Select-Object -First 25 | ForEach-Object {
            $q = "'" + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($_.Title) + "'"
            [System.Management.Automation.CompletionResult]::new($q, "$($_.Title) [$($_.Provider)]", 'ParameterValue', $_.Title)
        }
}

#endregion

$script:ChatIdleSeconds = 60

function Get-ChatProjectFiles {
    # The folders this project's chats live in, not the index rows themselves.
    # A chat started since the index was built is missing from the rows, and
    # that is precisely the chat most likely to be running.
    param([switch]$AllProjects, [string]$Cwd = $PWD.Path)
    $rows = Select-ChatInProject @(Get-ChatIndex) -AllProjects:$AllProjects -Cwd $Cwd
    if (-not $rows) { return @() }
    $dirs = @($rows | ForEach-Object { Split-Path $_.Path -Parent } | Sort-Object -Unique)
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($d in $dirs) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $d -File -EA SilentlyContinue)) { $out.Add($f) }
    }
    return $out
}

function Test-ChatTranscriptBusy {
    # Whether a transcript is parked mid-turn. $true mid-turn, $false finished,
    # $null cannot tell.
    #
    # This exists because mtime is blind to the two states that matter most: a
    # session waiting on a permission prompt, and one sitting inside a long tool
    # call. Neither writes anything, so both look finished after a minute - and
    # reloading either one throws away the pending prompt or the answer.
    # The last record carrying a message says where the turn actually got to.
    param([string]$Path)
    if ($Path -notlike '*.jsonl') { return $null }   # Claude's format only
    $c = Read-ChatChunk -Path $Path -Size 32768
    if (-not $c) { return $null }
    $text = if ($c.Split) { $c.Tail } else { $c.Head }
    # TrimStart the BOM: a chunk taken from the head of a file carries it into
    # the first line, and U+FEFF is not whitespace, so Trim leaves it there and
    # ConvertFrom-Json rejects the line
    $lines = @($text -split "`r?`n" |
        ForEach-Object { $_.TrimStart([char]0xFEFF).Trim() } |
        Where-Object { $_ })
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $o = try { $lines[$i] | ConvertFrom-Json } catch { $null }
        # ai-title, mode and atis-latch trail a turn and say nothing about it,
        # so walk back past them to the last real message
        if (-not $o -or -not $o.message) { continue }
        if ($o.type -eq 'assistant') {
            # tool_use is the agent waiting on a tool - which includes waiting
            # on you to allow one, or to answer a question it asked
            return ($o.message.stop_reason -eq 'tool_use')
        }
        if ($o.type -eq 'user') { return $true }     # a reply is owed
        return $null
    }
    return $null
}

function Get-ChatBackgroundTasks {
    # The workflows and background agents a Claude chat started that have not
    # reported back: their task ids. The turn that starts one ends at once, so
    # the transcript reads as finished and Claude calls the chat idle while the
    # work goes on - its agents write only under <id>/subagents/. A reload
    # kills all of it along with the chat's process.
    #
    # A start is a tool result whose toolUseResult is 'async_launched', with a
    # taskId (a workflow) or an agentId (an agent); SendMessage waking a
    # stopped agent is a resumedAgentId. Every end - completed, failed,
    # stopped - is a <task-notification> naming the same task id.
    #
    # Only starts after $Since count: the work dies with the process that ran
    # it, so one from before the chat was last opened is gone whether or not
    # it ever reported. A background shell is left out on purpose - as often a
    # server that never ends, which would hold the chat busy for good.
    # -SkipPrint leaves out the starts a print-mode run wrote: claude -p stamps
    # every record entrypoint sdk-cli - chatq's queued runs among them - where
    # a window's says claude-vscode and a terminal's cli. That run has ended,
    # and its work died with it. Only the caller can tell it has ended - no
    # print-mode process of the chat still alive (Test-ChatPrintLive) - and a
    # start the chat's own window made stays counted whenever it was made.
    param([string]$Path, [datetime]$Since = [datetime]::MinValue, [switch]$SkipPrint)
    $open = [System.Collections.Generic.List[string]]::new()
    try { $fs = Open-ChatRead $Path } catch { return }   # can vanish mid-scan
    try {
        $sr = [System.IO.StreamReader]::new($fs, [System.Text.Encoding]::UTF8)
        try {
            while ($null -ne ($line = $sr.ReadLine())) {
                # a cheap look first: most lines are neither, and parsing each
                # one would be the whole cost of a long chat
                if ($line.IndexOf('"async_launched"', [StringComparison]::Ordinal) -ge 0 -or
                    $line.IndexOf('"resumedAgentId"', [StringComparison]::Ordinal) -ge 0) {
                    $o = try { $line | ConvertFrom-Json } catch { $null }
                    $r = if ($o -and $o.PSObject.Properties['toolUseResult']) { $o.toolUseResult } else { $null }
                    $id = $null
                    if ($r -and $r.PSObject.Properties['status'] -and $r.status -eq 'async_launched') {
                        $id = if ($r.PSObject.Properties['taskId'] -and $r.taskId) { $r.taskId }
                        elseif ($r.PSObject.Properties['agentId']) { $r.agentId }
                    }
                    elseif ($r -and $r.PSObject.Properties['resumedAgentId']) { $id = $r.resumedAgentId }
                    if ($id) {
                        if ($SkipPrint -and $o.PSObject.Properties['entrypoint'] -and [string]$o.entrypoint -eq 'sdk-cli') { continue }
                        $at = ConvertTo-ChatqDate $o.timestamp
                        if ((-not $at -or $at -ge $Since) -and -not $open.Contains([string]$id)) { $open.Add([string]$id) }
                        continue
                    }
                }
                if ($open.Count -and $line.IndexOf('<task-id>', [StringComparison]::Ordinal) -ge 0) {
                    foreach ($t in @($open)) {
                        if ($line.IndexOf("<task-id>$t</task-id>", [StringComparison]::Ordinal) -ge 0) { [void]$open.Remove($t) }
                    }
                }
            }
        }
        finally { $sr.Dispose() }
    }
    finally { $fs.Dispose() }
    return $open.ToArray()
}

function Test-ChatPrintLive {
    # Is a print-mode claude of this chat alive - one not interactive, a
    # claude -p going into it right now? While one is, what it starts is not
    # dead work, and a window shown the chat fresh would load it part way.
    # An entry naming no kind is taken for interactive, as everywhere else.
    param([object[]]$Live, [string]$SessionId)
    foreach ($e in @($Live)) {
        if (-not $e -or [string](Get-ChatField $e 'SessionId') -ne $SessionId) { continue }
        $k = [string](Get-ChatField $e 'Kind')
        if ($k -and $k -ne 'interactive') { return $true }
    }
    return $false
}

function Test-ChatIdle {
    # $true idle, $false active, $null when it cannot be told - and $null stays
    # distinct, because "safe to reload" guessed wrong costs someone an answer.
    # -Except leaves one transcript out of what the files alone say: the chat a
    # queued run just wrote to, which would read as live for the next minute.
    # What Claude says of that chat's own open process still counts - after
    # the run it can only be a window's, and that may be busy. -ConfigDir is
    # the Claude home whose open sessions to ask, a job's own when it has one.
    # -Live is that list already asked for, so one judgement never asks twice.
    # Background work a print-mode run started - a queued run's - is left out
    # once no such run of that chat is alive: it died with its process.
    param([int]$Seconds = $script:ChatIdleSeconds, [switch]$AllProjects, [string]$Cwd = $PWD.Path, [string]$Except,
        [string]$ConfigDir = $env:CLAUDE_CONFIG_DIR, [object[]]$Live)
    $files = @(Get-ChatProjectFiles -AllProjects:$AllProjects -Cwd $Cwd)
    if (-not $files) { return $null }

    # first, what Claude says of the chats it has open: busy is a turn in
    # flight, waiting a permission prompt. A turn that started a workflow or a
    # background agent has ended, though, and reads idle there - so those
    # chats are also searched for work that has not reported back.
    $byId = @{}
    foreach ($f in $files) { if ($f.Extension -eq '.jsonl') { $byId[$f.BaseName] = $f } }
    $sessions = if ($PSBoundParameters.ContainsKey('Live')) { @($Live) } else { @(Get-ChatqLiveSessions $ConfigDir) }
    foreach ($s in $sessions) {
        if (-not $s) { continue }
        $f = $byId[[string]$s.SessionId]
        if (-not $f) { continue }
        if ($s.Status -in 'busy', 'waiting') { return $false }
        $since = [datetime]::MinValue
        if ($s.StartedAt) { $since = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$s.StartedAt).LocalDateTime }
        else { try { $since = (Get-Process -Id $s.Pid -EA Stop).StartTime } catch {} }
        # untouched since this process started: it has started nothing
        if ($f.LastWriteTime -lt $since) { continue }
        $skip = -not (Test-ChatPrintLive $sessions ([string]$s.SessionId))
        if (@(Get-ChatBackgroundTasks $f.FullName $since -SkipPrint:$skip).Count) { return $false }
    }

    # then the transcripts themselves - all there is to go on for Codex, or a
    # Claude too old to keep that list. Anything written just now is live
    if ($Except) { $files = @($files | Where-Object { $_.FullName -ne $Except }) }
    $cut = (Get-Date).AddSeconds(-$Seconds)
    foreach ($f in $files) { if ($f.LastWriteTime -gt $cut) { return $false } }

    # quiet on disk is not the same as finished, though. Only a recently
    # touched transcript can still be live, so the rest are not worth opening.
    $since = (Get-Date).AddHours(-12)
    foreach ($f in $files) {
        if ($f.LastWriteTime -lt $since) { continue }
        if ((Test-ChatTranscriptBusy $f.FullName) -eq $true) { return $false }
    }
    return $true
}

function Wait-ChatIdle {
    # Blocks the shell on purpose. Printing this from a background runspace is
    # what garbles the prompt - the ghost watcher stays silent for that reason -
    # so waiting where the caller can see it is the honest version.
    param([int]$Seconds = $script:ChatIdleSeconds, [switch]$AllProjects)
    $safe = '  all project chat is idle - safe to reload now'
    $state = Test-ChatIdle -Seconds $Seconds -AllProjects:$AllProjects
    if ($null -eq $state) {
        # waiting forever on a question that cannot be answered is worse than
        # saying so, and claiming "safe" here would be a guess wearing a fact
        Write-Host '  no index - cannot tell whether a chat is active' -ForegroundColor DarkGray
        return
    }
    if ($state) {
        Write-Host $safe -ForegroundColor Green
        return
    }
    Write-Host "  waiting for project chat to go quiet for ${Seconds}s - Ctrl+C to stop" -ForegroundColor DarkGray
    while ((Test-ChatIdle -Seconds $Seconds -AllProjects:$AllProjects) -eq $false) {
        Start-Sleep -Seconds 5
    }
    Write-Host $safe -ForegroundColor Green
}

function Write-ChatReloadRequest {
    # Left for the extension in extension/, if it is installed. Harmless when it
    # is not: an unread file in data/. The cwd is what lets each window decide
    # whether the delete was for its own workspace - so the background watcher
    # passes the job's folder, never its own. Kind is 'deleted' for chatrm and
    # 'ran' for a queued prompt that ran into a chat still open in a window.
    # Busy is $true when a chat in the project was still working as the
    # request went out - the window then warns instead of offering a plain
    # Reload, and never reloads by itself. Away is $true when nobody had used
    # the PC for a while: after a queued run, only then may the window reload
    # without asking. $null is "not judged", for both.
    # A run into a chat names it too (-SessionId), so the window can show
    # that chat fresh rather than reload: the Claude home it lives under
    # (-ConfigHome), what became of its old process (-OldProcess, see
    # Stop-ChatIdleProcess) and the VS Code windows that held it (-HostPids),
    # and its transcript where known (-Transcript), which the window mends
    # before it opens the chat, if Claude Code has left it out of its lists.
    # Without -SessionId the request is what 0.5.0 wrote, byte for byte.
    param([string]$Title, [string]$Cwd = (Get-Location).Path, [string]$Kind = 'deleted', $Busy = $null, $Away = $null,
        [string]$SessionId, [string]$ConfigHome, [string]$OldProcess, [int[]]$HostPids = @(), [string]$Transcript)
    $req = [ordered]@{
        id    = [guid]::NewGuid().ToString()
        kind  = $Kind
        cwd   = $Cwd
        title = $Title
        busy  = $Busy
        away  = $Away
    }
    if ($SessionId) {
        $req.sessionId = $SessionId
        $req.home = $(if ($ConfigHome) { $ConfigHome } else { $null })
        $req.oldProcess = $(if ($OldProcess) { $OldProcess } else { 'none' })
        $req.hostPids = [int[]]@($HostPids | Where-Object { $_ })
        if ($Transcript) { $req.file = $Transcript }
    }
    $req.at = (Get-Date).ToString('o')
    Save-ChatSignal $script:ChatReloadPath $req
}

function Write-ChatOpenRequest {
    # The overlay's open chip: show this chat, up to date, in the window that
    # has it - data/open-request, its own file, so a run's request and a
    # click's never overwrite each other. The same fields as a run's request;
    # the chip leaves busy $null (not judged) and oldProcess as judged only,
    # since it ends nothing.
    param([string]$SessionId, [string]$Cwd, [string]$Title, [string]$ConfigHome, $Busy = $null,
        [string]$OldProcess = 'none', [int[]]$HostPids = @(), [string]$Transcript)
    $req = [ordered]@{
        id         = [guid]::NewGuid().ToString()
        kind       = 'open'
        sessionId  = $SessionId
        cwd        = $Cwd
        title      = $Title
        home       = $(if ($ConfigHome) { $ConfigHome } else { $null })
        busy       = $Busy
        oldProcess = $OldProcess
        hostPids   = [int[]]@($HostPids | Where-Object { $_ })
    }
    if ($Transcript) { $req.file = $Transcript }
    $req.at = (Get-Date).ToString('o')
    Save-ChatSignal $script:ChatOpenPath $req
}

function Get-ChatShowHold {
    # Until when a window may still be showing this chat fresh on a request
    # just written for it - a run's (ran) or the chip's (open) - or $null.
    # A run going into the chat meanwhile would have the window load it part
    # way through, with a new process remembering only that much; so the next
    # run into it waits that out (Invoke-ChatqJob).
    param([string]$SessionId, [datetime]$Now = (Get-Date))
    if (-not $SessionId -or $script:ChatShowHoldSeconds -le 0) { return $null }
    $until = $null
    foreach ($f in $script:ChatReloadPath, $script:ChatOpenPath) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $r = try { [System.IO.File]::ReadAllText($f) | ConvertFrom-Json } catch { $null }
        if (-not $r -or [string](Get-ChatField $r 'sessionId') -ne $SessionId -or [string](Get-ChatField $r 'kind') -notin 'ran', 'open') { continue }
        $at = ConvertTo-ChatqDate (Get-ChatField $r 'at')
        if (-not $at) { continue }
        $end = $at.AddSeconds($script:ChatShowHoldSeconds)
        if ($end -gt $Now -and (-not $until -or $end -gt $until)) { $until = $end }
    }
    return $until
}

function Save-ChatSignal {
    # One request, replacing the last: the extension reads the whole file.
    param([string]$Path, $Request)
    try {
        $dir = Split-Path $Path -Parent
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $json = $Request | ConvertTo-Json -Compress
        # NOT Set-Content -Encoding UTF8: that writes a BOM on 5.1 and
        # JSON.parse rejects a BOM outright, so the extension would see nothing
        [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding $false))
    }
    catch {}
}

function Write-ChatGhostAdvice {
    # Said once, after a delete, and only while a window is up to do it. macOS
    # runs VS Code as Electron and 'Code Helper (...)', never a bare Code, so the
    # name has to differ per platform or the advice never prints there at all.
    param([switch]$WaitForIdle, [switch]$AllProjects, [string]$Title, [string]$Kind = 'deleted')
    $procs = if ($script:ChatIsMac) { @('Electron', 'Code Helper*') } else { @('Code') }
    if (-not @(Get-Process -Name $procs -EA SilentlyContinue).Count) { return }
    # judged before the request goes out, so the window says it too: a bare
    # Reload button reads as "safe now" to anyone not watching this terminal
    $idle = Test-ChatIdle -AllProjects:$AllProjects
    $busy = if ($null -eq $idle) { $null } else { -not $idle }
    Write-ChatReloadRequest -Title $Title -Kind $Kind -Busy $busy
    Write-Host 'the session list is cached - reload to see it go:'
    Write-Host '  Ctrl+Shift+P > Developer: Reload Window'
    if (Test-ChatGhostWatch) {
        Write-Host '  the window rewrites it as it reloads; that is watched for and taken back' -ForegroundColor DarkGray
    }
    else {
        Write-Host '  then run any chat command - the window rewrites it as it reloads' -ForegroundColor DarkGray
    }

    # A reload restarts the extensions, so one taken mid-answer loses that
    # answer. Nothing out here can reload the window for you - VS Code runs that
    # command from inside an extension only - so the most this can do is say
    # whether now is a safe moment.
    if ($WaitForIdle) { Wait-ChatIdle -AllProjects:$AllProjects; return }
    switch ($idle) {
        $true { Write-Host '  all project chat is idle - safe to reload now' -ForegroundColor Green }
        $false {
            Write-Host '  a chat is still active - reload once it finishes' -ForegroundColor Yellow
            Write-Host '  -WaitForIdle waits and tells you when' -ForegroundColor DarkGray
        }
        default { }   # no index to judge by: say nothing rather than guess
    }
}
function Format-ChatRow {
    param($Hit)
    $r = $Hit.Record
    '{0,-52} {1,-8} {2,-28} {3,4} {4,6} MB' -f
    $r.Title.Substring(0, [Math]::Min(52, $r.Title.Length)),
    $Hit.Provider,
    $r.Group.Substring(0, [Math]::Min(28, $r.Group.Length)),
    (Get-ChatAge $r.When),
    [math]::Round($Hit.File.Length / 1MB, 2)
}

function Test-ChatVT {
    # can the cursor be moved with escape sequences? Absolute CursorPosition is
    # not usable here: under the pseudo-console VS Code runs, setting it is
    # accepted and does nothing, so a redrawing list paints a fresh copy of
    # itself below the last one on every keypress. Relative moves work.
    if ([Console]::IsInputRedirected) { return $false }
    try { return [bool]$Host.UI.SupportsVirtualTerminal } catch { return $false }
}

function Invoke-ChatKeyLoop {
    # Every picker below is this loop: back up over what was drawn last time,
    # draw again, read one key. $Paint draws and returns how many lines it
    # wrote; $OnKey returns nothing to keep going, or @{ Value = ... } to stop
    # and hand that back. Shared state goes in a hashtable both blocks close
    # over - a plain variable assigned inside a scriptblock would only ever
    # change that block's own copy.
    param([scriptblock]$Paint, [scriptblock]$OnKey)
    $esc = [char]27
    $painted = 0
    while ($true) {
        if ($painted) { Write-Host "$esc[${painted}A" -NoNewline }
        $painted = [int](& $Paint)
        $stop = & $OnKey ([Console]::ReadKey($true))
        if ($stop) { return $stop.Value }
    }
}

# What Format-ChatPickTail writes, anchored, so Enter can take it back off.
# It has to come off: "#1/3" alone was a comment and harmless to leave, but
# "(5d)" in front of it is not - PowerShell would run it as an expression.
$script:ChatTailPattern = '\s*(\([^)]*\))?\s*#\d+/\d+\s*$'
# The same tail with more typed after it. Narrow on purpose - only an age as
# Get-ChatAge writes it - so text in a prompt is never mistaken for one.
$script:ChatMidTailPattern = '\s(?:\((?:now|\d+(?:mo|m|h|d|y))\)\s)?#\d+/\d+(?=\s)'

function Format-ChatPickTail {
    # The decoration every path shares: the age, then where you are in the run.
    # Tab puts this straight into the command line, so Enter strips it again
    # before running - see the Enter handler.
    param([string]$Age, [int]$Index, [int]$Count)
    $t = ''
    if ($Age) { $t = " ($Age)" }
    return "$t #$Index/$Count"
}

function Format-ChatWalkRow {
    # The line Tab leaves on the command line, rebuilt: the command, the full
    # title, the tail. Walking matches after Enter should look exactly like
    # walking them before it. Trimmed rather than padded so the tail stays
    # beside the title, and its width is held back before clipping so a long
    # title can never push it off the end.
    param($Hit, [int]$Index, [int]$Count, [int]$Width, [switch]$Ambiguous)
    $c = Get-ChatSyntaxColor
    $tail = Format-ChatPickTail (Get-ChatAge $Hit.Record.When) $Index $Count
    $segments = @(
        @{ Text = '  chatrm '; Color = $c.Command }
        @{ Text = "'" + $Hit.Record.Title.Replace("'", "''") + "'"; Color = $c.String }
    )
    # Only when title and age are both the same, which the line alone cannot
    # separate - and Enter deletes on the spot, so they have to be separable.
    # Project and size together, because two chats in one project can share a
    # title and an age as well.
    if ($Ambiguous) {
        $segments += @{
            Text  = "  $($Hit.Record.Group) $([math]::Round($Hit.File.Length / 1MB, 2))MB"
            Color = $c.Param
        }
    }
    # clip across the segments, measuring the text and never the escapes
    $budget = $Width - (Get-ChatCells $tail)
    $line = ''
    $used = 0
    foreach ($seg in $segments) {
        if ($used -ge $budget) { break }
        $piece = Format-ChatCell $seg.Text ($budget - $used) -NoPad
        $line += $seg.Color + $piece
        $used += Get-ChatCells $piece
    }
    return $line + $c.Comment + $tail + $c.Reset
}

function Confirm-ChatOne {
    # One match, and the words typed were only part of its title. Deleting on
    # that alone is how 'chatrm Haiku' took 'Haiku ChatGPT Opus Astra' with no
    # prompt at all. Show the whole title and make the answer deliberate.
    param($Item, [string]$Needle)
    $width = [Math]::Max(20, $Host.UI.RawUI.WindowSize.Width - 1)
    Write-Host ''
    Write-Host "  '$Needle' is part of this title, not all of it:" -ForegroundColor Yellow
    Write-Host (Format-ChatWalkRow $Item 1 1 $width)

    # No VT means no key loop, and a confirm that only works under VT would
    # leave the weakest hosts deleting unprompted - the bug in a new costume.
    if (-not (Test-ChatVT)) {
        Write-Host ''
        return ((Read-Host "  delete it permanently? (y/N)").Trim() -match '^(y|yes)$')
    }

    $esc = [char]27
    return Invoke-ChatKeyLoop -Paint {
        Write-Host "  delete permanently?  y / Enter = yes,  n / Esc = no$esc[K"
        1
    } -OnKey {
        param($key)
        switch ($key.Key) {
            'Enter' { return @{ Value = $true } }
            'Escape' { return @{ Value = $false } }
        }
        switch ($key.KeyChar) {
            'y' { return @{ Value = $true } }
            'Y' { return @{ Value = $true } }
            'n' { return @{ Value = $false } }
            'N' { return @{ Value = $false } }
            'q' { return @{ Value = $false } }
        }
    }
}

function Select-ChatOne {
    # The same one-line walk Tab does, over the chats a title matched. Enter
    # takes the one on screen and deletes it, with nothing in between.
    param([object[]]$Items)
    $width = [Math]::Max(20, $Host.UI.RawUI.WindowSize.Width - 1)
    # one match still shows the line, so all three paths look alike - there is
    # simply nothing to walk. The caller decides whether that one still needs
    # confirming: an exact title does not, a fragment of one does.
    if ($Items.Count -eq 1) {
        Write-Host (Format-ChatWalkRow $Items[0] 1 1 $width)
        return $Items[0]
    }
    if (-not (Test-ChatVT)) { return Select-ChatNumbered $Items -One }

    # no header, no key hints: the counter says there is more than one, and the
    # keys are the ones Tab already walks with
    $esc = [char]27
    # keyed on title AND age, because that pair is all the line shows - only a
    # pair the counter cannot separate earns the project name
    $seen = @{}
    foreach ($it in $Items) {
        $k = "$($it.Record.Title)|$(Get-ChatAge $it.Record.When)"
        $seen[$k] = 1 + $(if ($seen.ContainsKey($k)) { $seen[$k] } else { 0 })
    }
    $s = @{ I = 0 }
    return Invoke-ChatKeyLoop -Paint {
        # no highlight - it is the only line on screen, so nothing needs
        # marking, and an inverse bar the width of the terminal reads far
        # heavier than the plain line Tab leaves behind
        $it = $Items[$s.I]
        $key = "$($it.Record.Title)|$(Get-ChatAge $it.Record.When)"
        $row = Format-ChatWalkRow $it ($s.I + 1) $Items.Count $width -Ambiguous:($seen[$key] -gt 1)
        Write-Host ($row + "$esc[K")
        1
    } -OnKey {
        param($key)
        $last = $Items.Count - 1
        switch ($key.Key) {
            'UpArrow' { $s.I = [Math]::Max(0, $s.I - 1); return }
            'DownArrow' { $s.I = [Math]::Min($last, $s.I + 1); return }
            'Enter' { return @{ Value = $Items[$s.I] } }
            'Escape' { return @{ Value = $null } }
        }
        switch ($key.KeyChar) {
            'k' { $s.I = [Math]::Max(0, $s.I - 1); return }
            'j' { $s.I = [Math]::Min($last, $s.I + 1); return }
            'q' { return @{ Value = $null } }
        }
    }
}

function Select-ChatItems {
    # the same walk, but every chat can be ticked: clearing ghosts is a job you
    # want to finish in one pass
    param([object[]]$Items, [string]$Title = 'Select chats to delete')
    if (-not (Test-ChatVT) -or $Host.Name -notlike '*ConsoleHost*') {
        return Select-ChatNumbered $Items $Title
    }

    $width = [Math]::Max(20, $Host.UI.RawUI.WindowSize.Width - 1)
    $window = [Math]::Min(15, $Items.Count)
    $s = @{ I = 0; Top = 0; Picked = New-Object bool[] $Items.Count }

    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host '  up/down move   space toggle   a all   enter delete   esc cancel' -ForegroundColor DarkGray
    return Invoke-ChatKeyLoop -Paint {
        if ($s.I -lt $s.Top) { $s.Top = $s.I }
        if ($s.I -ge $s.Top + $window) { $s.Top = $s.I - $window + 1 }
        for ($n = $s.Top; $n -lt $s.Top + $window; $n++) {
            $mark = if ($s.Picked[$n]) { '[x]' } else { '[ ]' }
            $line = Format-ChatCell "  $mark $(Format-ChatRow $Items[$n])" $width
            if ($n -eq $s.I) { Write-Host $line -ForegroundColor Black -BackgroundColor Cyan }
            else { Write-Host $line }
        }
        $count = @($s.Picked | Where-Object { $_ }).Count
        Write-Host (Format-ChatCell "  $count of $($Items.Count) selected" $width) -ForegroundColor DarkGray
        $window + 1
    } -OnKey {
        param($key)
        $last = $Items.Count - 1
        switch ($key.Key) {
            'UpArrow' { $s.I = [Math]::Max(0, $s.I - 1); return }
            'DownArrow' { $s.I = [Math]::Min($last, $s.I + 1); return }
            'Spacebar' { $s.Picked[$s.I] = -not $s.Picked[$s.I]; return }
            'Enter' { return @{ Value = @(0..$last | Where-Object { $s.Picked[$_] } | ForEach-Object { $Items[$_] }) } }
            'Escape' { return @{ Value = @() } }
        }
        switch ($key.KeyChar) {
            'k' { $s.I = [Math]::Max(0, $s.I - 1); return }
            'j' { $s.I = [Math]::Min($last, $s.I + 1); return }
            'a' {
                $all = @($s.Picked | Where-Object { $_ }).Count -lt $Items.Count
                for ($n = 0; $n -le $last; $n++) { $s.Picked[$n] = $all }
                return
            }
            'q' { return @{ Value = @() } }
        }
    }
}

function Select-ChatNumbered {
    # what both of them fall back to where there is no raw keyboard
    param([object[]]$Items, [string]$Title, [switch]$One)
    Write-Host ''
    if ($Title) { Write-Host "  $Title" -ForegroundColor Cyan }
    $width = [Math]::Max(20, $Host.UI.RawUI.WindowSize.Width - 1)
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host (Format-ChatCell ('  {0,2}. {1}' -f ($i + 1), (Format-ChatRow $Items[$i])) $width)
    }
    if ($One) {
        $answer = (Read-Host '  which one? (empty=cancel)').Trim()
        if ($answer -match '^\d+$' -and [int]$answer -ge 1 -and [int]$answer -le $Items.Count) {
            return $Items[[int]$answer - 1]
        }
        return $null
    }
    $answer = Read-Host '  delete which? (1,3-5 / a=all / empty=cancel)'
    if (-not $answer) { return @() }
    if ($answer.Trim() -eq 'a') { return $Items }
    $idx = [System.Collections.Generic.List[int]]::new()
    foreach ($part in ($answer -split '[,\s]+' | Where-Object { $_ })) {
        if ($part -match '^(\d+)-(\d+)$') { [int]$Matches[1]..[int]$Matches[2] | ForEach-Object { $idx.Add($_ - 1) } }
        elseif ($part -match '^\d+$') { $idx.Add([int]$part - 1) }
    }
    return @($idx | Sort-Object -Unique | Where-Object { $_ -ge 0 -and $_ -lt $Items.Count } | ForEach-Object { $Items[$_] })
}
function chatrm {
    <#
    .SYNOPSIS
    Delete a local AI chat transcript, permanently.
    .DESCRIPTION
    An id is unambiguous, so it deletes outright. A title can match several
    chats, so those are listed and walked one by one.

    Titles match on substring, so part of a title is a search, not a choice.
    A single match found that way is shown in full and asked about before
    anything goes - and at the prompt, Enter fills the title in the way Tab
    would instead of running, so the whole of it is on screen before a second
    Enter acts on it. A title typed in full deletes as it always did, and
    -Force skips the asking entirely.

    Tab fills in the whole argument - title or id, quoted or not - from the
    index that chatfind keeps warm; run chatindex to rebuild it.
    Also removes what the transcript leaves behind - sidecars, file-history and
    session-env for Claude, chatEditingSessions for Copilot.
    .PARAMETER Target
    One or more ids (prefixes are fine), or a chat title.
    .PARAMETER Provider
    Limit to claude, copilot or codex. Defaults to all of them.
    .PARAMETER Force
    Skip the confirmation prompts in title mode.
    .PARAMETER AllProjects
    Match titles from every project rather than the one this directory belongs
    to. Ids are unambiguous and always reach any project.
    .PARAMETER WaitForIdle
    Wait after deleting until nothing in this project's chats has been written
    for a minute, then say the window is safe to reload. A reload restarts the
    extensions, so one taken mid-answer loses that answer. It blocks the shell
    while it waits; Ctrl+C stops it and deletes nothing back.
    .PARAMETER DropJobs
    A chat with a prompt queued for it by chatq is kept, and the job named.
    -DropJobs drops those jobs first - cancelling one that is running and
    waiting for it to stop - and then deletes.
    .PARAMETER Archive
    Move the chat out of the way instead of deleting it; chatrestore brings it
    back. A Claude chat and its leftovers go to data/archive/, a Codex thread
    through codex archive. Copilot chats have an archive of their own in VS Code.
    .EXAMPLE
    chatrm 44e899d3
    .EXAMPLE
    chatrm "Review uncommitted changes"
    .LINK
    chatfind
    #>
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments)][string[]]$Target,
        [string[]]$Provider,
        [switch]$Force,
        [switch]$AllProjects,
        [switch]$WaitForIdle,
        [switch]$DropJobs,
        [switch]$Archive
    )
    Set-StrictMode -Off

    if (-not $Target) { Write-Error 'usage: chatrm <id>... | "<title>" [-Force] [-AllProjects] [-WaitForIdle] [-DropJobs] [-Archive]'; return }
    # one step for both paths below: delete, or put away
    $take = { param($h) if ($Archive) { Save-ChatArchive $h } else { Remove-ChatSession $h } }
    $names = if ($Provider) { $Provider } else { @($script:ChatProviders.Keys) }
    $deleted = 0
    $lastTitle = ''
    $byId = -not ($Target | Where-Object { $_ -notmatch '^[0-9a-fA-F]{6,}(-[0-9a-fA-F-]*)?$' })

    # ids are not scoped to the project: an id names exactly one chat, so there
    # is nothing for the current directory to disambiguate
    if ($byId) {
        foreach ($id in $Target) {
            $found = $false
            foreach ($name in $names) {
                $p = $script:ChatProviders[$name]
                if (-not $p) { continue }
                foreach ($file in @(& $p.Discover)) {
                    # substring, not prefix: Codex buries the uuid after a timestamp
                    if ($file.BaseName -notlike "*$id*") { continue }
                    $rec = & $p.Describe $file
                    if (-not $rec) { continue }
                    $hit = [pscustomobject]@{ Provider = $name; File = $file; Record = $rec }
                    $found = $true
                    if (Test-ChatJobsHold $hit -DropJobs:$DropJobs) { continue }
                    if (& $take $hit) { $deleted++; $lastTitle = $hit.Record.Title }
                }
            }
            if (-not $found) { Write-Warning "no transcript for $id - already deleted, or wrong id" }
        }
    }
    else {
        $needle = $Target -join ' '
        $matched = @(Find-ChatSessions -Needle $needle -Provider $Provider -TitleOnly -AllProjects:$AllProjects)
        if (-not $matched) {
            $where = if ($AllProjects) { '' } else { ' here - add -AllProjects to look wider' }
            Write-Warning "no chat titled like '$needle'$where"
            return
        }

        # Titles match on substring, so one hit does NOT mean the right hit:
        # 'Haiku' matched 'Haiku ChatGPT Opus Astra' and, with a single match
        # taken as consent, deleted it outright. Typing a whole title is a
        # decision; typing a fragment is a search, and a search must not delete.
        $exact = $matched.Count -eq 1 -and
        $matched[0].Record.Title.Equals($needle, [StringComparison]::OrdinalIgnoreCase)

        $chosen = if ($Force) { $matched }
        elseif ($matched.Count -eq 1 -and -not $exact) {
            # the one guard that also covers scripts, -NoProfile and no-VT
            # hosts, where no key handler exists to fill the title in first
            if (Confirm-ChatOne $matched[0] $needle) { @($matched[0]) } else { @() }
        }
        else {
            $one = Select-ChatOne $matched
            if ($one) { @($one) } else { @() }
        }

        if (-not $chosen) { Write-Host 'nothing deleted'; return }
        foreach ($m in $chosen) {
            # already shown once - by the confirm above, or by the picker list
            if (Test-ChatJobsHold $m -DropJobs:$DropJobs) { continue }
            if (& $take $m) { $deleted++; $lastTitle = $m.Record.Title }
        }
    }

    if ($deleted) {
        $what = if ($deleted -eq 1) { $lastTitle } else { "$deleted chats" }
        $kind = if ($Archive) { 'archived' } else { 'deleted' }
        Write-ChatGhostAdvice -WaitForIdle:$WaitForIdle -AllProjects:$AllProjects -Title $what -Kind $kind
    }
}

#endregion
