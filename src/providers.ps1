# Charlie-and-the-chat-factory, src/providers.ps1: dot-sourced by Charlie-and-the-chat-factory.ps1
# in its turn, never on its own - see the list there.

#region provider: claude ------------------------------------------------------

function Read-ClaudePrompt {
    param([string]$Line)
    if ($Line -like '*"tool_result"*' -or $Line -like '*"isMeta":true*' -or $Line -like '*system-reminder*') { return $null }
    try { $o = $Line | ConvertFrom-Json } catch { return $null }
    if ($o.type -ne 'user') { return $null }
    $c = $o.message.content
    if ($c -isnot [string]) { $c = ($c | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join ' ' }
    if (-not $c) { return $null }
    $c = $c.Trim()
    if (Test-ChatNoise $c) { return $null }
    return ($c -replace '\s+', ' ')
}

function Read-ClaudeSlashCommand {
    # A slash command typed into a chat - "/compact", "/model opus" - as the
    # transcript keeps it: a user record Claude Code writes once the command
    # has run. A skill the model loads has no slash, and is not this.
    param([string]$Line)
    if ($Line -notlike '*<command-name>/*' -or $Line -like '*"isMeta":true*') { return $null }
    try { $o = $Line | ConvertFrom-Json } catch { return $null }
    if ($o.type -ne 'user' -or $o.message.content -isnot [string]) { return $null }
    $c = [string]$o.message.content
    if ($c -notmatch '<command-name>\s*(/[^<\s]+)\s*</command-name>') { return $null }
    $name = $Matches[1]
    $rest = if ($c -match '<command-args>([\s\S]*?)</command-args>') { ($Matches[1] -replace '\s+', ' ').Trim() } else { '' }
    if ($rest) { return "$name $rest" }
    return $name
}

function Get-ClaudeLeftovers {
    # Everything on disk that belongs to one chat and nothing else, after
    # claude-chats-delete's inventory (docs/deletion-behavior.md there). Most
    # are named by the session id; the rest are found by it. Project and user
    # memory are never on this list - they are not one chat's.
    param($File)
    $id = $File.BaseName
    $h = $script:ChatClaudeHome
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($p in @(
            (Join-Path $File.DirectoryName $id)                              # subagents/, tool-results/
            (Join-Path (Join-Path $h 'file-history') $id)
            (Join-Path (Join-Path $h 'session-env') $id)
            (Join-Path (Join-Path $h 'tasks') $id)
            (Join-Path (Join-Path $h 'debug') "$id.txt")
            (Join-Path (Join-Path $h 'security') "security_warnings_state_$id.json")
            (Join-Path (Join-Path $h 'security') "security_warnings_state_$id.lock")
            (Join-Path $h "security_warnings_state_$id.json")               # older layout
        )) { $out.Add($p) }
    foreach ($d in @(@{ Dir = 'telemetry'; Like = "*$id*.json" }, @{ Dir = 'todos'; Like = "$id*.json" })) {
        $dir = Join-Path $h $d.Dir
        if (Test-Path -LiteralPath $dir) {
            foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -EA SilentlyContinue | Where-Object { $_.Name -like $d.Like })) { $out.Add($f.FullName) }
        }
    }
    # a background job's folder is named by an 8-character prefix, so its own
    # state.json says whose it is
    $jobs = Join-Path $h 'jobs'
    if (Test-Path -LiteralPath $jobs) {
        foreach ($d in @(Get-ChildItem -LiteralPath $jobs -Directory -EA SilentlyContinue)) {
            $st = Join-Path $d.FullName 'state.json'
            if (-not (Test-Path -LiteralPath $st)) { continue }
            $sid = try { (Get-Content -LiteralPath $st -Raw -Encoding UTF8 | ConvertFrom-Json).sessionId } catch { $null }
            if ($sid -eq $id) { $out.Add($d.FullName) }
        }
    }
    # A plan file is named by the chat's slug, and a resumed or forked chat can
    # share that slug with another - two here did. Only when no other chat in
    # the same project folder mentions it does the plan go with this one.
    $plans = Join-Path $h 'plans'
    if (Test-Path -LiteralPath $plans) {
        $c = Read-ChatChunk $File.FullName
        $slug = if ($c) { Get-ChatJsonString "$($c.Head)`n$($c.Tail)" 'slug' } else { $null }
        if ($slug -and $slug -match '^[A-Za-z0-9-]+$') {
            $needle = "`"slug`":`"$slug`""
            $others = @(Get-ChildItem -LiteralPath $File.DirectoryName -Filter *.jsonl -File -EA SilentlyContinue |
                Where-Object { $_.FullName -ne $File.FullName })
            $shared = $others -and [bool](Select-String -LiteralPath @($others.FullName) -SimpleMatch -Pattern $needle -List -EA SilentlyContinue | Select-Object -First 1)
            if (-not $shared) {
                foreach ($f in @(Get-ChildItem -LiteralPath $plans -File -EA SilentlyContinue |
                        Where-Object { $_.Name -eq "$slug.md" -or $_.Name -like "$slug-agent-*.md" })) { $out.Add($f.FullName) }
            }
        }
    }
    return $out.ToArray()
}

#endregion

#region provider: copilot -----------------------------------------------------

function Get-CopilotWorkspaceName {
    # workspaceStorage/<hash>/workspace.json points at the folder the chats belong to
    param([string]$StorageDir)
    if ($script:ChatWorkspaceNames.ContainsKey($StorageDir)) { return $script:ChatWorkspaceNames[$StorageDir] }
    $name = Split-Path $StorageDir -Leaf
    $meta = Join-Path $StorageDir 'workspace.json'
    if (Test-Path -LiteralPath $meta) {
        try {
            $uri = (Get-Content -LiteralPath $meta -Raw | ConvertFrom-Json).folder
            if ($uri) { $name = Split-Path ([Uri]::UnescapeDataString($uri)) -Leaf }
        }
        catch {}
    }
    $script:ChatWorkspaceNames[$StorageDir] = $name
    return $name
}

#endregion

#region provider: codex -------------------------------------------------------

function Get-CodexThreadNames {
    # Codex names a thread itself and keeps that name in session_index.jsonl,
    # never in the rollout. The panel lists the name, so the title has to come
    # from here - the first prompt was 'test' where the panel said 'Test task'.
    # Cached against the index mtime: a chat named after dot-source still lands.
    $path = Join-Path $script:ChatCodexHome 'session_index.jsonl'
    $f = Get-Item -LiteralPath $path -EA SilentlyContinue
    $stamp = if ($f) { $f.LastWriteTimeUtc.Ticks } else { 0 }
    if ($script:ChatCodexNames -and $script:ChatCodexNamesAt -eq $stamp) { return $script:ChatCodexNames }
    $map = @{}
    if ($f) {
        # UTF8 said outright: 5.1 reads a BOM-less file in the ANSI code page,
        # which turns a Hangul thread name into mojibake
        foreach ($line in (Get-Content -LiteralPath $path -Encoding UTF8 -EA SilentlyContinue)) {
            $o = try { $line | ConvertFrom-Json } catch { $null }
            if ($o.id -and $o.thread_name) { $map[[string]$o.id] = [string]$o.thread_name }
        }
    }
    $script:ChatCodexNames = $map
    $script:ChatCodexNamesAt = $stamp
    return $map
}

function Read-CodexPrompt {
    param([string]$Line)
    try { $o = $Line | ConvertFrom-Json } catch { return $null }
    if ($o.payload.role -ne 'user') { return $null }
    $t = ($o.payload.content | Where-Object { $_.type -eq 'input_text' } | ForEach-Object { $_.text }) -join ' '
    if (-not $t) { return $null }
    $t = $t.Trim()
    # the IDE wraps the real prompt in a context block
    $i = $t.IndexOf('## My request for Codex:')
    if ($i -ge 0) { $t = $t.Substring($i + 24).Trim() }
    # AGENTS.md preambles and environment blocks are not prompts
    if ($t.StartsWith('# AGENTS.md') -or $t.StartsWith('<') -or $t.StartsWith('# Context from my IDE')) { return $null }
    if (Test-ChatNoise $t) { return $null }
    return ($t -replace '\s+', ' ')
}

#endregion

#region provider registry -----------------------------------------------------

$script:ChatProviders = [ordered]@{

    claude  = [pscustomobject]@{
        Root     = (Join-Path $script:ChatClaudeHome 'projects')
        Discover = {
            # only projects/<slug>/<uuid>.jsonl - a recursive sweep also drags in
            # workflow journals and agent transcripts, which are not chats
            $root = Join-Path $script:ChatClaudeHome 'projects'
            if (Test-Path -LiteralPath $root) {
                Get-ChildItem -LiteralPath $root -Directory | ForEach-Object {
                    Get-ChildItem -LiteralPath $_.FullName -Filter *.jsonl -File |
                        Where-Object { $_.BaseName -match '^[0-9a-fA-F-]{36}$' }
                }
            }
        }
        Describe = {
            param($File)
            $p = Get-ChatHeadTailPrompts $File.FullName '"type":"user"' ${function:Read-ClaudePrompt}
            if (-not $p) { return $null }
            # subagent transcripts are flagged on line 1; the GUI hides them too
            $nl = $p.Head.IndexOf("`n")
            $firstLine = if ($nl -ge 0) { $p.Head.Substring(0, $nl) } else { $p.Head }
            $hidden = $firstLine -like '*"isSidechain":true*'
            $title = $null; $source = 'first message'
            foreach ($t in @($p.Tail, $p.Head)) {
                if (-not $title) { $title = Get-ChatJsonString $t 'customTitle'; if ($title) { $source = 'renamed' } }
            }
            if (-not $title) {
                foreach ($t in @($p.Tail, $p.Head)) {
                    if (-not $title) { $title = Get-ChatJsonString $t 'aiTitle'; if ($title) { $source = 'auto' } }
                }
            }
            # the raw JSON text: a title holding a quote came through as \"
            if ($title) { $title = Convert-ChatJsonEscaped $title }
            if (-not $title) {
                $sidecar = Join-Path (Join-Path $File.DirectoryName $File.BaseName) 'custom-title.json'
                if (Test-Path -LiteralPath $sidecar) {
                    try { $title = (Get-Content -LiteralPath $sidecar -Raw | ConvertFrom-Json).customTitle; if ($title) { $source = 'renamed' } } catch {}
                }
            }
            if (-not $title) { $title = @($p.First)[0] }
            [pscustomobject]@{
                Id          = $File.BaseName
                Title       = Format-ChatTitle $title
                TitleSource = $source
                Group       = $File.Directory.Name
                Hidden      = $hidden
                When        = Get-ChatTimestampFromText $p $File
                First       = $p.First
                Last        = $p.Last
            }
        }
        IsEmpty  = {
            # a ghost holds only state lines - ai-title / mode / atis-latch - and
            # is written when the GUI opens a chat whose transcript is gone
            param($File)
            if ($File.Length -gt 65536) { return $false }
            $t = Read-ChatAllText $File.FullName
            (-not ($t -like '*"type":"user"*')) -and (-not ($t -like '*"type":"assistant"*'))
        }
        Extras   = {
            param($File, $Record)
            Get-ClaudeLeftovers $File
        }
    }

    copilot = [pscustomobject]@{
        Root     = (Join-Path $script:ChatCodeUser 'workspaceStorage')
        Discover = {
            $root = Join-Path $script:ChatCodeUser 'workspaceStorage'
            if (Test-Path -LiteralPath $root) {
                Get-ChildItem -LiteralPath $root -Directory | ForEach-Object {
                    $dir = Join-Path $_.FullName 'chatSessions'
                    if (Test-Path -LiteralPath $dir) { Get-ChildItem -LiteralPath $dir -Filter *.json -File }
                }
            }
        }
        Describe = {
            param($File)
            # regex over head+tail, not ConvertFrom-Json: these files reach 700 KB
            # each and the metadata sits after requests[], so the tail carries it
            $chunk = Read-ChatChunk $File.FullName
            if (-not $chunk) { return $null }
            $meta = if ($chunk.Split) { $chunk.Tail } else { $chunk.Head }
            $rx = [regex]'"message":\s*\{\s*"text":\s*"((?:[^"\\]|\\.)*)"'
            $grab = {
                param($text)
                Select-ChatDistinctRun @($rx.Matches($text) | ForEach-Object {
                        $t = (Convert-ChatJsonEscaped $_.Groups[1].Value) -replace '\s+', ' '
                        $t = $t.Trim()
                        if ($t -and -not (Test-ChatNoise $t)) { $t }
                    })
            }
            $first = @(& $grab $chunk.Head | Select-Object -First $script:ChatPreview)
            $last = @(& $grab $meta | Select-Object -Last $script:ChatPreview)
            if (-not $first -and $chunk.Split) {
                $whole = Read-ChatAllText $File.FullName
                $first = @(& $grab $whole | Select-Object -First $script:ChatPreview)
                $last = @(& $grab $whole | Select-Object -Last $script:ChatPreview)
            }
            $texts = $first
            $title = Get-ChatJsonString $meta 'customTitle'
            if ($title) { $title = Convert-ChatJsonEscaped $title }
            $source = if ($title) { 'renamed' } else { 'first message' }
            if (-not $title) { $title = @($texts)[0] }
            $ms = if ($meta -match '"lastMessageDate":\s*(\d+)') { $Matches[1] }
            elseif ($meta -match '"creationDate":\s*(\d+)') { $Matches[1] }
            $when = if ($ms) { [System.DateTimeOffset]::FromUnixTimeMilliseconds([int64]$ms).LocalDateTime } else { $File.LastWriteTime }
            [pscustomobject]@{
                Id          = $File.BaseName
                Title       = Format-ChatTitle $title
                TitleSource = $source
                Group       = Get-CopilotWorkspaceName (Split-Path $File.DirectoryName -Parent)
                Hidden      = $false
                When        = $when
                First       = $first
                Last        = $last
            }
        }
        IsEmpty  = {
            param($File)
            if ($File.Length -gt 65536) { return $false }
            $t = Read-ChatAllText $File.FullName
            [bool]($t -match '"requests":\s*\[\s*\]')   # panel opened, never used
        }
        Extras   = {
            param($File, $Record)
            @(Join-Path (Join-Path (Split-Path $File.DirectoryName -Parent) 'chatEditingSessions') $File.BaseName)
        }
    }

    codex   = [pscustomobject]@{
        Root     = (Join-Path $script:ChatCodexHome 'sessions')
        Discover = {
            $root = Join-Path $script:ChatCodexHome 'sessions'
            if (Test-Path -LiteralPath $root) { Get-ChildItem -LiteralPath $root -Filter *.jsonl -Recurse -File }
        }
        Describe = {
            param($File)
            $p = Get-ChatHeadTailPrompts $File.FullName @('"role":"user"', '"role": "user"') ${function:Read-CodexPrompt}
            if (-not $p) { return $null }
            # rollout-<iso>-<uuid>.jsonl - the id is everything after the timestamp
            $id = if ($File.BaseName -match '([0-9a-fA-F-]{36})$') { $Matches[1] } else { $File.BaseName }
            $cwd = Get-ChatJsonString $p.Head 'cwd'
            $group = if ($cwd) { Split-Path ($cwd -replace '\\\\', '\') -Leaf } else { 'codex' }
            $named = (Get-CodexThreadNames)[$id]
            $title = if ($named) { $named } else { @($p.First)[0] }
            [pscustomobject]@{
                Id          = $id
                Title       = Format-ChatTitle $title
                TitleSource = if ($named) { 'thread name' } else { 'first message' }
                Group       = $group
                Hidden      = $false
                When        = Get-ChatTimestampFromText $p $File
                First       = $p.First
                Last        = $p.Last
            }
        }
        IsEmpty  = {
            param($File)
            if ($File.Length -gt 65536) { return $false }
            $t = Read-ChatAllText $File.FullName
            -not ($t -match '"role":\s*"user"')
        }
        Extras   = { param($File, $Record) @() }
    }
}

function chatclean {
    <#
    .SYNOPSIS
    Delete ghost chats - transcripts that hold no messages at all - and list
    again the Claude chats Claude Code left out of its lists.
    .DESCRIPTION
    Clicking a chat in the VS Code list after its transcript was deleted makes
    the extension write the session back as a stub: a title line, a mode line,
    nothing else. Those stubs then show up as ghost rows, and clicking them
    again makes more. This finds and removes them.

    A file counts as empty only if it is under 64 KB AND contains no user or
    assistant message at all, so a real chat can never match.

    First, every Claude chat a claude -p run hid from Claude Code's lists by
    its tail is listed again, with the one line a run into it adds as it ends
    - for chats hidden before 0.8.1, or by a watcher that died mid-run. A chat
    in use is left, and said; run chatclean again once it is idle.
    .PARAMETER Force
    Delete every ghost found without asking.
    .EXAMPLE
    chatclean
    #>
    param([string[]]$Provider, [switch]$Force)
    Set-StrictMode -Off

    $rows = @(Sync-ChatIndex -Provider $Provider)
    if (-not $Provider -or $Provider -contains 'claude') {
        $m = Repair-ChatListedAll -Rows $rows -Live @(Get-ChatqLiveSessions $script:ChatClaudeHome -RegistryOnly)
        foreach ($r in $m.Relisted) { Write-Host "  listed again in Claude Code: $($r.Title)" -ForegroundColor Green }
        if ($m.Held.Count) {
            Write-Host "  $($m.Held.Count) more left out of Claude Code's lists, in use now - chatclean again once idle: $(@($m.Held | ForEach-Object { $_.Title }) -join ', ')" -ForegroundColor DarkGray
        }
    }
    $candidates = @($rows | Where-Object { -not $_.First })
    $ghosts = foreach ($row in $candidates) {
        $p = $script:ChatProviders[$row.Provider]
        if (-not $p.IsEmpty) { continue }
        $file = try { Get-Item -LiteralPath $row.Path -EA Stop } catch { continue }
        if (-not (& $p.IsEmpty $file)) { continue }
        [pscustomobject]@{
            Provider = $row.Provider
            File     = $file
            Record   = [pscustomobject]@{
                Id = $row.Id; Title = $row.Title; TitleSource = $row.Titled
                Group = $row.Group; Hidden = $row.Hidden
                When = [datetime]::Parse($row.When, [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::RoundtripKind)
                First = @(); Last = @()
            }
        }
    }
    $ghosts = @($ghosts)
    if (-not $ghosts) { Write-Host 'no ghost chats found'; return }

    $chosen = if ($Force) { $ghosts } else { Select-ChatItems $ghosts "$($ghosts.Count) ghost chats (no messages at all)" }
    if (-not $chosen) { Write-Host 'nothing deleted'; return }
    foreach ($g in $chosen) { $null = Remove-ChatSession $g }
    Write-Host ''
    Write-ChatGhostAdvice
}

function chatproviders {
    <#
    .SYNOPSIS
    Show which chat tools were found on this machine, and where they store chats.
    #>
    Set-StrictMode -Off
    $script:ChatProviders.GetEnumerator() | ForEach-Object {
        $files = @(& $_.Value.Discover)
        [pscustomobject]@{
            Provider = $_.Key
            Present  = Test-Path -LiteralPath $_.Value.Root
            Chats    = $files.Count
            MB       = [math]::Round((($files | Measure-Object Length -Sum).Sum) / 1MB, 1)
            Root     = $_.Value.Root
        }
    }
}

#endregion
