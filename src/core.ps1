# Charlie-and-the-chat-factory, src/core.ps1: dot-sourced by Charlie-and-the-chat-factory.ps1
# in its turn, never on its own - see the list there.

$script:ChatPreview = 3
$script:ChatClaudeHome = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
$script:ChatCodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
# $IsMacOS exists only on pwsh 6+. On 5.1 it is undefined, and under StrictMode
# reading an undefined variable throws outright rather than yielding $false -
# this file is dot-sourced into whatever session the user already has, so it
# cannot assume strict mode is off. Get-Variable answers without touching it.
$script:ChatIsMac = [bool](Get-Variable -Name IsMacOS -ValueOnly -EA SilentlyContinue)

# VS Code's user dir moves per platform: APPDATA on Windows, Application Support
# on macOS, XDG on Linux. Without the middle branch a Mac falls to the Linux path
# and the copilot provider quietly finds nothing at all. CHAT_CODE_USER points
# it somewhere else - the tests and the demo use it so no real chat is read.
$script:ChatCodeUser =
if ($env:CHAT_CODE_USER) { $env:CHAT_CODE_USER }
elseif ($env:APPDATA) { Join-Path $env:APPDATA 'Code\User' }
elseif ($script:ChatIsMac) { Join-Path $HOME 'Library/Application Support/Code/User' }
else { Join-Path $HOME '.config/Code/User' }
$script:ChatWorkspaceNames = @{}
$script:ChatIndexPath = Join-Path (Join-Path $script:ChatRoot 'data') 'chat-index.csv'
$script:ChatTombPath = Join-Path (Join-Path $script:ChatRoot 'data') 'rewritten.txt'
# what the last chatinstall put in the profile. The file gets overwritten by an
# update, so its own version says what just landed and this says what it replaced.
$script:ChatVersionPath = Join-Path (Join-Path $script:ChatRoot 'data') 'version.txt'
# read by the optional VS Code extension in extension/, which is the only thing
# able to run reloadWindow - no CLI flag, URL or toast button can reach it
$script:ChatReloadPath = Join-Path (Join-Path $script:ChatRoot 'data') 'reload-request'
# the overlay's open chip asks the same extension to show one chat, in a file
# of its own, so a run's request and a click's never overwrite each other
$script:ChatOpenPath = Join-Path (Join-Path $script:ChatRoot 'data') 'open-request'
# each holds the newest request, and under earlier the few written just
# before it - at most this many, none older than this (Save-ChatRequest):
# the extension polls every 2 s, and two requests inside one poll left the
# first unseen. signal.lock is held from the read to the write.
$script:ChatSignalCarryMax = 3
$script:ChatSignalCarrySeconds = 60
$script:ChatSignalLockPath = Join-Path (Join-Path $script:ChatRoot 'data') 'signal.lock'
# how long after either request the next run into its chat waits, while the
# window shows it (Get-ChatShowHold): the extension acts on one by itself for
# 20 s (its timing.judgedMaxAge), and polls every 2
$script:ChatShowHoldSeconds = 30
# the queued run going on now, for the extension: one slot, since the watcher
# runs one job at a time (Write-ChatRunState). Each window a handover asks
# answers in run-ack/<its ext host pid>.json (Wait-ChatHandoverAnswer).
$script:ChatRunStatePath = Join-Path (Join-Path $script:ChatRoot 'data') 'run-state'
$script:ChatRunAckDir = Join-Path (Join-Path $script:ChatRoot 'data') 'run-ack'
# The chats each VS Code window's idle process was ended for, by its ext
# host's pid (Add-ChatIdleEnded): a view there may still show one with no
# process of the window under it, and a reload of that window waits on a
# claude -p going into it (Get-ChatHostWork).
$script:ChatIdleEndedPath = Join-Path (Join-Path $script:ChatRoot 'data') 'idle-ended.json'
# A reload a window asks about, unanswered: reload-pending/<its ext host
# pid>.json, which the overlay shows as a banner (Read-ChatReloadPending);
# its reload or later goes back in reload-answer/<pid>.json
# (Write-ChatReloadAnswer).
$script:ChatReloadPendingDir = Join-Path (Join-Path $script:ChatRoot 'data') 'reload-pending'
$script:ChatReloadAnswerDir = Join-Path (Join-Path $script:ChatRoot 'data') 'reload-answer'
# The handover's waits (Invoke-ChatqHandover): for the windows to answer, and
# for a chat whose tab is closing to let go of its process - Claude Code ends
# it about 7 s after the tab closes. The tests shorten them, and turn the
# handover off (ChatHandoverOff) everywhere but their own section.
$script:ChatHandoverAckSeconds = 3
$script:ChatHandoverLeaveSeconds = 15
$script:ChatHandoverPollMs = 250
$script:ChatHandoverOff = $false
# tests: called with each run-state as it is written - the extension's part
$script:ChatRunStateSeam = $null
# tests: stands in for Show-ChatFresh -GraceSeconds' sleep, given the
# milliseconds; the seam can take the process away as a closed tab would
$script:ChatGraceSleepSeam = $null

# Caches and flags read before anything sets them. This file is dot-sourced
# into whatever session the user already has, and under Set-StrictMode
# -Version Latest reading an unset variable throws - at load, or inside a key
# handler, which then leaves the key dead. Every command also turns StrictMode
# off for itself; these cover everything that runs outside one.
$script:ChatIndexStamp = $null
$script:ChatIndexCache = @()
$script:ChatCodexNames = $null
$script:ChatCodexNamesAt = 0
$script:ChatColors = $null
$script:ChatGhostWatcher = $null
$script:ChatNoIndex = $false
$script:ChatArrowWas = @{}
# set by the tests: a FileSystemWatcher event firing between their statements
# would delete fixtures out from under them
$script:ChatNoGhostWatch = $false

#region index -----------------------------------------------------------------
# Reading 2000+ transcripts takes ~30s, so nothing does it twice. The index
# holds everything a search needs - title, group, previews, last activity - and
# a file is only re-read when its size or mtime changed. Searches and tab
# completion both run off it.

$script:ChatIndexSep = [char]0x1F   # unit separator: never appears in prompt text

# The index's rows from its CSV. Self-contained - it names nothing else in
# this file - because the overlay's console runs it in a runspace of its own,
# off the window's thread (Start-ChatConsoleIndexRead).
$script:ChatIndexRead = {
    param([string]$Path, [string]$Sep)
    @(Import-Csv -LiteralPath $Path | ForEach-Object {
            [pscustomobject]@{
                Provider = $_.Provider
                Path     = $_.Path
                Size     = [int64]$_.Size
                Mtime    = [int64]$_.Mtime
                Id       = $_.Id
                Title    = $_.Title
                Titled   = $_.Titled
                Group    = $_.Group
                # an index an older build wrote has no Cwd column at all
                Cwd      = $(if ($_.PSObject.Properties['Cwd']) { $_.Cwd } else { $null })
                NoCwd    = $(if ($_.PSObject.Properties['NoCwd']) { $_.NoCwd -eq 'True' } else { $false })
                Hidden   = $_.Hidden -eq 'True'
                When     = $_.When
                First    = @($_.First -split $Sep | Where-Object { $_ })
                Last     = @($_.Last -split $Sep | Where-Object { $_ })
            }
        })
}

function Get-ChatIndexStamp {
    # the index file's version: its time and length, or $null
    try {
        $fi = [System.IO.FileInfo]::new($script:ChatIndexPath)
        if ($fi.Exists) { "$($fi.LastWriteTimeUtc.Ticks):$($fi.Length)" } else { $null }
    }
    catch { $null }
}

function Get-ChatIndex {
    # CSV, not JSON: ConvertTo-Json on a few thousand rows costs tens of seconds.
    # Kept in memory too, so repeated Tab presses re-parse nothing.
    if (-not (Test-Path -LiteralPath $script:ChatIndexPath)) { return @() }
    $stamp = Get-ChatIndexStamp
    if ($stamp -and $stamp -eq $script:ChatIndexStamp) { return $script:ChatIndexCache }
    try {
        $rows = @(& $script:ChatIndexRead $script:ChatIndexPath $script:ChatIndexSep)
        $script:ChatIndexCache = $rows
        $script:ChatIndexStamp = $stamp
        return $rows
    }
    catch { return @() }
}

function Save-ChatIndex {
    # Written beside the index and swapped in whole: the overlay's console
    # reads it while a shell - or its own background sync - writes it, and
    # half a CSV parses as a shorter list without complaint.
    param([object[]]$Rows)
    try {
        $dir = Split-Path $script:ChatIndexPath -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $tmp = "$($script:ChatIndexPath).tmp"
        $Rows | ForEach-Object {
            [pscustomobject]@{
                Provider = $_.Provider; Path = $_.Path; Size = $_.Size; Mtime = $_.Mtime
                Id = $_.Id; Title = $_.Title; Titled = $_.Titled; Group = $_.Group
                Hidden = $_.Hidden; When = $_.When
                First = (@($_.First) -join $script:ChatIndexSep)
                Last = (@($_.Last) -join $script:ChatIndexSep)
                # an older build reads columns by name and passes this one by
                Cwd = Get-ChatField $_ 'Cwd'
                NoCwd = [bool](Get-ChatField $_ 'NoCwd')
            }
        } | Export-Csv -LiteralPath $tmp -NoTypeInformation -Encoding UTF8
        # A reader holding the index open - the overlay's console, another
        # shell's Tab, a virus scan - fails the swap with a sharing violation.
        # That was swallowed whole, so the old index stayed with no word: a
        # restored chat Tab could not find until the next sync. Such a hold
        # lasts milliseconds, so a few tries, then a warning.
        for ($try = 1; ; $try++) {
            try {
                # [NullString], not $null: PowerShell hands .NET an empty string
                # for $null, and an empty backup path throws
                if (Test-Path -LiteralPath $script:ChatIndexPath) { [System.IO.File]::Replace($tmp, $script:ChatIndexPath, [NullString]::Value) }
                else { [System.IO.File]::Move($tmp, $script:ChatIndexPath) }
                break
            }
            catch {
                if ($try -ge 5) { throw }
                Start-Sleep -Milliseconds (40 * $try)
            }
        }
    }
    catch { Write-Warning "the chat index was not saved: $($_.Exception.Message)" }
}

function Remove-ChatIndexRow {
    # A deleted chat has to leave the index too. Without this Tab went on
    # completing a title whose transcript was gone, and the search behind it
    # then found nothing - so the completion led straight to "no chat titled
    # like that". The index is what Tab reads; deleting the file is only half.
    #
    # Rewriting the CSV is also what drops the in-memory copy: Get-ChatIndex
    # caches against the file's mtime and length, and Save-ChatIndex leaves the
    # stamp alone, so the next read sees a new stamp and re-parses.
    param([string]$Path)
    try {
        if (-not $Path -or -not (Test-Path -LiteralPath $script:ChatIndexPath)) { return }
        $rows = @(Get-ChatIndex)
        if (-not $rows) { return }
        # -ne on paths is case-insensitive, which is what Windows needs
        $keep = @($rows | Where-Object { $_.Path -ne $Path })
        if ($keep.Count -eq $rows.Count) { return }
        Save-ChatIndex $keep
    }
    catch {}
}

function Test-ChatIndexRowCurrent {
    # Whether an unchanged file's row can be kept as it is. A Codex row from
    # before the index kept the chat's folder has only the leaf name, which
    # two sibling repos can share, so it is read again once even though its
    # rollout did not move. A rollout with no cwd at all has nothing more to
    # give, so it is kept - else it would be read on every sync. That is
    # NoCwd, set by the read that found none: its group, 'codex', is also
    # the leaf of a repo named codex, whose old row must be read again too.
    param($Row)
    if ($Row.Provider -ne 'codex') { return $true }
    return [bool](Get-ChatField $Row 'Cwd') -or [bool](Get-ChatField $Row 'NoCwd')
}

function Sync-ChatIndex {
    # returns the index rows for $Provider, re-reading only what changed
    param([string[]]$Provider, [switch]$Force)
    # before indexing, so a chat the window wrote back never gets indexed
    Clear-ChatTombstones
    $names = if ($Provider) { $Provider } else { @($script:ChatProviders.Keys) }
    $cached = @(Get-ChatIndex)
    $old = @{}
    foreach ($r in $cached) {
        if (-not $r.Path) { continue }
        if ($Force -and $names -contains $r.Provider) { continue }
        $old[$r.Path] = $r
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    $fresh = 0
    $reused = 0
    foreach ($name in $names) {
        $p = $script:ChatProviders[$name]
        if (-not $p) { Write-Warning "unknown provider '$name'"; continue }
        foreach ($file in @(& $p.Discover)) {
            $hit = $old[$file.FullName]
            if ($hit -and $hit.Size -eq $file.Length -and $hit.Mtime -eq $file.LastWriteTimeUtc.Ticks -and (Test-ChatIndexRowCurrent $hit)) {
                $rows.Add($hit)     # unchanged since last time
                $reused++
                continue
            }
            $rec = & $p.Describe $file
            if (-not $rec) { continue }
            $fresh++
            $rows.Add([pscustomobject]@{
                    Provider = $name
                    Path     = $file.FullName
                    Size     = $file.Length
                    Mtime    = $file.LastWriteTimeUtc.Ticks
                    Id       = $rec.Id
                    Title    = $rec.Title
                    Titled   = $rec.TitleSource
                    Group    = $rec.Group
                    Cwd      = Get-ChatField $rec 'Cwd'
                    NoCwd    = ($name -eq 'codex' -and -not (Get-ChatField $rec 'Cwd'))
                    Hidden   = [bool]$rec.Hidden
                    When     = $rec.When.ToString('o')
                    First    = @($rec.First)
                    Last     = @($rec.Last)
                })
        }
    }
    # only rewrite when something actually moved - the write is the expensive part
    $others = @($cached | Where-Object { $names -notcontains $_.Provider })
    $stale = ($reused + $others.Count) -ne $cached.Count
    if ($fresh -or $stale) {
        # silently: "new or changed" counts any transcript whose mtime moved,
        # which includes every session merely being typed in right now, so the
        # number read as "you made 4 chats" when nobody made any
        Save-ChatIndex @($others + $rows.ToArray())
    }
    return $rows.ToArray()
}

function chatindex {
    <#
    .SYNOPSIS
    Rebuild the chat index that searches and tab completion run off.
    .DESCRIPTION
    Normally unnecessary: every chatfind refreshes the index incrementally,
    re-reading only transcripts whose size or mtime changed. Use -Force to
    discard what is cached and read every transcript again.
    #>
    param([string[]]$Provider, [switch]$Force)
    Set-StrictMode -Off
    $rows = Sync-ChatIndex -Provider $Provider -Force:$Force
    $names = if ($Provider) { $Provider } else { @($script:ChatProviders.Keys) }
    Write-Host "indexed $($rows.Count) chats from: $($names -join ', ')"
}

#endregion

#region generic helpers -------------------------------------------------------

function Get-ChatAge {
    param([datetime]$When)
    $s = ([datetime]::Now - $When).TotalSeconds
    if ($s -lt 60) { return 'now' }
    if ($s -lt 3600) { return "$([math]::Floor($s / 60))m" }
    if ($s -lt 86400) { return "$([math]::Floor($s / 3600))h" }
    if ($s -lt 2592000) { return "$([math]::Floor($s / 86400))d" }
    if ($s -lt 31536000) { return "$([math]::Floor($s / 2592000))mo" }
    return "$([math]::Floor($s / 31536000))y"
}

function Format-ChatMessages {
    param([string[]]$Messages, [int]$Width = 100, [string]$Indent = '          ')
    if (-not $Messages) { return '' }
    ($Messages | ForEach-Object {
        $t = $_.Substring(0, [Math]::Min($Width, $_.Length))
        if ($_.Length -gt $Width) { $t += '...' }
        $t
    }) -join "`n$Indent"
}

function Get-ChatSlug {
    # Claude's name for a project folder: the whole path, with every character
    # that is not a letter or digit turned into a dash. A drive's root keeps
    # its slash: Claude calls C:\ C--, and C: alone is another folder.
    param([string]$Path)
    $p = $Path.TrimEnd('\', '/')
    if ($p -eq '' -or $p -match '^[A-Za-z]:$') { $p = $Path }
    return ($p -replace '[^A-Za-z0-9]', '-')
}

function Format-ChatTitle {
    param([string]$Text, [int]$Width = 60)
    if (-not $Text) { return '(empty)' }
    $t = ($Text -replace '\s+', ' ').Trim()
    if ($t.Length -gt $Width) { $t = $t.Substring(0, $Width).TrimEnd() + '...' }
    return $t
}

function Test-ChatNoise {
    # prompts that are machinery, not something the user typed
    param([string]$Text)
    $Text.StartsWith('<') -or $Text.StartsWith('Caveat') -or $Text -like '*system-reminder*' -or
    $Text -like '`[Request interrupted*'
}

function Select-ChatDistinctRun {
    # drop consecutive repeats - Codex re-injects the same prompt every turn
    param([string[]]$Texts)
    $out = [System.Collections.Generic.List[string]]::new()
    $prev = $null
    foreach ($t in $Texts) {
        # compare on a normalized prefix: re-injections differ in punctuation
        $key = ($t -replace '[^\w]', '').ToLowerInvariant()
        $key = $key.Substring(0, [Math]::Min(80, $key.Length))
        if ($key -ne $prev) { $out.Add($t) }
        $prev = $key
    }
    # plain array, not comma-wrapped: callers pipe this straight into Select-Object
    return $out.ToArray()
}

function Open-ChatRead {
    # Codex holds every rollout open for the life of the window. OpenRead asks
    # for FileShare.Read, which collides with that writer and throws, so no
    # Codex chat ever reached the index - discovery found the files and Describe
    # then returned null on all of them. Share what the writer holds.
    param([string]$Path)
    [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
        ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
}

function Read-ChatAllText {
    # File::ReadAllText shares no better than OpenRead does
    param([string]$Path)
    $fs = Open-ChatRead $Path
    try {
        $sr = [System.IO.StreamReader]::new($fs, [System.Text.Encoding]::UTF8)
        try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
    }
    finally { $fs.Dispose() }
}

function Read-ChatChunk {
    # head+tail only - transcripts run to megabytes and there are thousands
    param([string]$Path, [int]$Size = 524288)
    $fi = [System.IO.FileInfo]::new($Path)
    try { $fs = Open-ChatRead $Path } catch { return $null }  # can vanish mid-scan
    try {
        if ($fi.Length -le 2 * $Size) {
            $buf = [byte[]]::new($fi.Length)
            $fs.Read($buf, 0, $buf.Length) | Out-Null
            return [pscustomobject]@{ Head = [System.Text.Encoding]::UTF8.GetString($buf); Tail = ''; Split = $false }
        }
        $hb = [byte[]]::new($Size)
        $fs.Read($hb, 0, $Size) | Out-Null
        $tb = [byte[]]::new($Size)
        $fs.Seek(-$Size, [System.IO.SeekOrigin]::End) | Out-Null
        $fs.Read($tb, 0, $Size) | Out-Null
        return [pscustomobject]@{
            Head  = [System.Text.Encoding]::UTF8.GetString($hb)
            Tail  = [System.Text.Encoding]::UTF8.GetString($tb)
            Split = $true
        }
    }
    finally { $fs.Dispose() }
}

function Get-ChatJsonLines {
    # index scan for a marker, not a line split + pipeline - that was 10x slower.
    # several markers may be given: the first one present in the text wins, which
    # covers writers that emit compact JSON and ones that pad after the colon
    param([string]$Text, [string[]]$Marker, [int]$Count, [switch]$FromEnd,
        [string[]]$Skip = @('"tool_result"', '"isMeta":true', 'system-reminder'))
    $out = [System.Collections.Generic.List[string]]::new()
    if (-not $Text) { return , @() }
    $needle = $Marker | Where-Object { $Text.IndexOf($_, [StringComparison]::Ordinal) -ge 0 } | Select-Object -First 1
    if (-not $needle) { return , @() }
    $Marker = $needle
    $pos = if ($FromEnd) { $Text.Length - 1 } else { 0 }
    while ($out.Count -lt $Count) {
        $j = if ($FromEnd) { $Text.LastIndexOf($Marker, [Math]::Min($pos, $Text.Length - 1), [StringComparison]::Ordinal) }
        else { $Text.IndexOf($Marker, $pos, [StringComparison]::Ordinal) }
        if ($j -lt 0) { break }
        $s = $Text.LastIndexOf("`n", $j) + 1
        $e = $Text.IndexOf("`n", $j)
        if ($e -lt 0) { $e = $Text.Length }
        $line = $Text.Substring($s, $e - $s)
        # skip before counting, not after parsing: a chat can have hundreds of
        # tool-result lines carrying the same marker, which would fill the quota
        $keep = $line.Length -lt 200000
        if ($keep) { foreach ($s2 in $Skip) { if ($line -like "*$s2*") { $keep = $false; break } } }
        if ($keep) {
            if ($FromEnd) { $out.Insert(0, $line) } else { $out.Add($line) }
        }
        $pos = if ($FromEnd) { $s - 1 } else { $e + 1 }
        if ($FromEnd -and $pos -lt 0) { break }
        if (-not $FromEnd -and $pos -ge $Text.Length) { break }
    }
    return , $out.ToArray()
}

function Get-ChatTimestampFromText {
    # the head/tail chunks are already in hand - no second read of the file
    param($Prompts, [System.IO.FileInfo]$File)
    foreach ($t in @($Prompts.Tail, $Prompts.Head)) {
        if (-not $t) { continue }
        $m = [regex]::Matches($t, '"timestamp":\s*"([^"]+)"')
        if ($m.Count) {
            try {
                return [datetime]::Parse($m[$m.Count - 1].Groups[1].Value,
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()
            }
            catch {}
        }
    }
    return $File.LastWriteTime
}

function Get-ChatLastTimestamp {
    # the last timestamp sits in the final few KB; ISO-8601, culture-invariant
    param([string]$Path)
    $fi = [System.IO.FileInfo]::new($Path)
    $tailLen = [Math]::Min(65536, $fi.Length)
    $buf = [byte[]]::new($tailLen)
    try { $fs = Open-ChatRead $Path } catch { return $fi.LastWriteTime }
    try {
        $fs.Seek(-$tailLen, [System.IO.SeekOrigin]::End) | Out-Null
        $fs.Read($buf, 0, $tailLen) | Out-Null
    }
    finally { $fs.Dispose() }
    $m = [regex]::Matches([System.Text.Encoding]::UTF8.GetString($buf), '"timestamp":\s*"([^"]+)"')
    if ($m.Count) {
        return [datetime]::Parse($m[$m.Count - 1].Groups[1].Value,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()
    }
    return $fi.LastWriteTime
}

function Get-ChatHeadTailPrompts {
    # walk head and tail for prompt lines, parse only those, and fall back to the
    # whole file when one turn is bigger than the chunk and hides every prompt
    param([string]$Path, [string[]]$Marker, [scriptblock]$Parse, [int]$Count = $script:ChatPreview)
    $chunk = Read-ChatChunk $Path
    if (-not $chunk) { return $null }
    $scan = $Count * 4   # over-fetch: some candidates parse out as noise
    $head = $chunk.Head
    $tail = if ($chunk.Split) { $chunk.Tail } else { $chunk.Head }
    $first = @(); $last = @()
    foreach ($pass in 1, 2) {
        # assign before piping - these return comma-wrapped arrays
        $headLines = Get-ChatJsonLines $head $Marker $scan
        $tailLines = Get-ChatJsonLines $tail $Marker $scan -FromEnd
        $headTexts = Select-ChatDistinctRun @($headLines | ForEach-Object { & $Parse $_ } | Where-Object { $_ })
        $tailTexts = Select-ChatDistinctRun @($tailLines | ForEach-Object { & $Parse $_ } | Where-Object { $_ })
        $first = @($headTexts | Select-Object -First $Count)
        $last = @($tailTexts | Select-Object -Last $Count)
        if (-not $chunk.Split -or ($first.Count -gt 0 -and $last.Count -gt 0)) { break }
        if ($pass -eq 1) {
            $head = Read-ChatAllText $Path
            $tail = $head
            $chunk = [pscustomobject]@{ Head = $head; Tail = ''; Split = $false }
        }
    }
    return [pscustomobject]@{ First = $first; Last = $last; Head = $chunk.Head; Tail = $chunk.Tail }
}

function Convert-ChatJsonEscaped {
    # \n, \" and friends, without parsing the document they came from
    param([string]$Text)
    if ($Text -notlike '*\*') { return $Text }
    try { return ('"' + $Text + '"') | ConvertFrom-Json } catch { return $Text }
}

function Get-ChatJsonString {
    # index lookup rather than regex: this runs over megabyte-sized text.
    # both spacings are tried, since writers differ on the space after the colon
    param([string]$Text, [string]$Key)
    if (-not $Text) { return $null }
    $best = -1
    $len = 0
    foreach ($anchor in @("`"$Key`":`"", "`"$Key`": `"")) {
        $i = $Text.LastIndexOf($anchor, [StringComparison]::Ordinal)
        if ($i -gt $best) { $best = $i; $len = $anchor.Length }
    }
    if ($best -lt 0) { return $null }
    $rest = $Text.Substring($best + $len)
    if ($rest -match '^((?:[^"\\]|\\.)*)"') { return $Matches[1] }
    return $null
}

#endregion
