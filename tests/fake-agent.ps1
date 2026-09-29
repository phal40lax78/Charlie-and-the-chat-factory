# Fake claude / codex for tests/run-tests.ps1. Driven by environment variables:
#   FAKE_RECORD    folder: writes stdin.bin (raw bytes), argv.txt, env.txt,
#                  and settings.json - a copy of the --settings file, if any
#   FAKE_SCENARIO  a .jsonl to replay on stdout, {{RESETS}} / {{SESSION}}
#                  replaced; absent means a plain success
#   FAKE_LAND      a transcript to append the prompt to as a user record, the
#                  way a real run does before the limit cuts it off
#   FAKE_STDERR    bytes of noise to write to stderr first (pipe-deadlock test)
#   FAKE_SLEEP     seconds to hang before answering (timeout test)
#   FAKE_AGENTS    what `claude agents --json` prints (live chats)
#   FAKE_AGENTS_SEEN  a file a line is added to each time `claude agents` runs
#   FAKE_NEW_CHAT  with --session-id, write the new chat's transcript where
#                  Claude Code would, as a real first run does - under
#                  CLAUDE_CODE_PROJECT_DIR_NAME when set - and refuse an id
#                  already on disk
#   FAKE_ARCHIVE_FAIL  make `codex archive` / `unarchive` fail
#   FAKE_REGISTER  a registry file (sessions/<pid>.json) to write while the
#                  run goes on, from FAKE_REGISTER_BODY with {{NOW}} replaced
#                  by the time in Unix ms: a window opening the chat meanwhile.
#                  With FAKE_AGENTS_FILE, the same entry goes there too, as
#                  what `claude agents --json` lists from then on
#   FAKE_AGENTS_FILE  once it exists, what `claude agents --json` prints,
#                  ahead of FAKE_AGENTS
#   FAKE_PERMIT    a JSON list of tool calls {tool_name, input, id} that each
#                  meet a permission prompt. With --permission-prompt-tool and
#                  --mcp-config in argv the fake starts the server that config
#                  names, as claude -p does, and asks it about each call - a
#                  tool_use line first, then tools/call - recording every
#                  answer in FAKE_RECORD/permit.jsonl; a deny becomes a
#                  permission_denials entry. A server that does not come up
#                  ends the run at the first call, as S35 saw claude do.
#   FAKE_PERMIT_SELF  the model calls mcp__chatqpermit__decide itself: a
#                  call with no tool_use line of its own before it
# Output goes out as raw UTF-8 bytes: Write-Output would encode it in the
# console code page, which is exactly the bug class these tests exist for.

$ErrorActionPreference = 'Stop'
# fake-claude.cmd hands the command line over as one string; split it the way
# the MSVCRT does for what chatq sends - quoted runs, \" inside them - which
# keeps "" (an empty argument) and a lone - intact
$argv = @([regex]::Matches([string]$env:FAKE_ARGV, '"((?:\\"|[^"])*)"|(\S+)') | ForEach-Object {
        if ($_.Groups[1].Success) { $_.Groups[1].Value.Replace('\"', '"') } else { $_.Groups[2].Value }
    })
$in = [Console]::OpenStandardInput()
$ms = New-Object System.IO.MemoryStream
$in.CopyTo($ms)
$bytes = $ms.ToArray()
$utf8 = New-Object System.Text.UTF8Encoding $false
$prompt = $utf8.GetString($bytes)

if ($argv.Count -and $argv[0] -in 'archive', 'unarchive') {
    # codex archive / unarchive <id>: the rollout moves between sessions/ and
    # archived_sessions/ under CODEX_HOME, keeping its dated sub-path
    $home2 = $env:CODEX_HOME
    $from = if ($argv[0] -eq 'archive') { 'sessions' } else { 'archived_sessions' }
    $to = if ($argv[0] -eq 'archive') { 'archived_sessions' } else { 'sessions' }
    $root = Join-Path $home2 $from
    $f = @(Get-ChildItem -LiteralPath $root -Filter "*$($argv[1])*.jsonl" -File -Recurse -EA SilentlyContinue) | Select-Object -First 1
    if (-not $f -or $env:FAKE_ARCHIVE_FAIL) {
        $e = [Console]::OpenStandardError()
        $b = $utf8.GetBytes("Error: no session found for $($argv[1])`n")
        $e.Write($b, 0, $b.Length); $e.Flush()
        exit 1
    }
    $rel = $f.FullName.Substring($root.Length).TrimStart('\', '/')
    $dest = Join-Path (Join-Path $home2 $to) $rel
    New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
    Move-Item -LiteralPath $f.FullName -Destination $dest -Force
    exit 0
}

if ($argv.Count -and $argv[0] -eq 'agents') {
    # claude agents --json: FAKE_AGENTS, or nobody live
    if ($env:FAKE_AGENTS_SEEN) { [IO.File]::AppendAllText($env:FAKE_AGENTS_SEEN, "agents`n", $utf8) }
    $o = [Console]::OpenStandardOutput()
    $said = if ($env:FAKE_AGENTS_FILE -and (Test-Path -LiteralPath $env:FAKE_AGENTS_FILE)) { [IO.File]::ReadAllText($env:FAKE_AGENTS_FILE, $utf8) }
    elseif ($env:FAKE_AGENTS) { $env:FAKE_AGENTS } else { '[]' }
    $b = $utf8.GetBytes($said + "`n")
    $o.Write($b, 0, $b.Length); $o.Flush()
    exit 0
}

if ($env:FAKE_RECORD) {
    New-Item -ItemType Directory -Path $env:FAKE_RECORD -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $env:FAKE_RECORD 'pid.txt'), "$PID", $utf8)
    [IO.File]::WriteAllBytes((Join-Path $env:FAKE_RECORD 'stdin.bin'), $bytes)
    [IO.File]::WriteAllText((Join-Path $env:FAKE_RECORD 'argv.txt'), ($argv -join "`n"), $utf8)
    # and what a queued run is given for background work (Invoke-ChatqRun)
    $seen = @('ANTHROPIC_API_KEY', 'CLAUDECODE', 'CLAUDE_CODE_SESSION_ID', 'CLAUDE_CONFIG_DIR', 'CLAUDE_CODE_DISABLE_BACKGROUND_TASKS',
        'BASH_MAX_TIMEOUT_MS', 'BASH_DEFAULT_TIMEOUT_MS', 'CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS') | ForEach-Object {
        "$_=$([Environment]::GetEnvironmentVariable($_))"
    }
    $seen = @($seen) + "MCP_TOOL_TIMEOUT=$env:MCP_TOOL_TIMEOUT" + "CLAUDE_CODE_EFFORT_LEVEL=$env:CLAUDE_CODE_EFFORT_LEVEL"
    [IO.File]::WriteAllText((Join-Path $env:FAKE_RECORD 'env.txt'), ($seen -join "`n"), $utf8)
    # the one --settings claude reads - the last given - as it stood at the
    # start: chatq removes a run's own when the run ends
    $setRec = Join-Path $env:FAKE_RECORD 'settings.json'
    $si = [Array]::LastIndexOf([string[]]$argv, '--settings')
    if ($si -ge 0 -and $si + 1 -lt $argv.Count -and (Test-Path -LiteralPath $argv[$si + 1])) { [IO.File]::WriteAllText($setRec, [IO.File]::ReadAllText($argv[$si + 1], $utf8), $utf8) }
    elseif (Test-Path -LiteralPath $setRec) { Remove-Item -LiteralPath $setRec -Force }
}

if ($argv -contains '--version') {
    $o = [Console]::OpenStandardOutput()
    $b = $utf8.GetBytes("2.1.278 (Claude Code)`n")
    $o.Write($b, 0, $b.Length); $o.Flush()
    exit 0
}

if ($env:FAKE_STDERR) {
    $e = [Console]::OpenStandardError()
    $junk = $utf8.GetBytes(('x' * 1023) + "`n")
    for ($i = 0; $i -lt [int]$env:FAKE_STDERR / 1024; $i++) { $e.Write($junk, 0, $junk.Length) }
    $e.Flush()
}
if ($env:FAKE_SLEEP) { Start-Sleep -Seconds ([int]$env:FAKE_SLEEP) }

$session = '00000000-0000-4000-8000-000000000000'
$i = [Array]::IndexOf($argv, '--resume')
if ($i -ge 0 -and $i + 1 -lt $argv.Count) { $session = $argv[$i + 1] }
# a new chat: claude -p --session-id <id> --name <name> makes it, as spike S25
# saw - its transcript under the config dir, in the folder named after the
# working directory, the name first and then the prompt
$i = [Array]::IndexOf($argv, '--session-id')
if ($i -ge 0 -and $i + 1 -lt $argv.Count) {
    $session = $argv[$i + 1]
    if ($env:FAKE_NEW_CHAT) {
        # an id already on disk is refused, as claude.exe 2.1.281 does
        $taken = @(Get-ChildItem -Path (Join-Path (Join-Path $env:CLAUDE_CONFIG_DIR 'projects') '*') -Filter "$session.jsonl" -File -EA SilentlyContinue)
        if ($taken) {
            $e = [Console]::OpenStandardError()
            $b = $utf8.GetBytes("Error: Session ID $session is already in use.`n")
            $e.Write($b, 0, $b.Length); $e.Flush()
            exit 1
        }
        $cwd = (Get-Location).Path
        # CLAUDE_CODE_PROJECT_DIR_NAME names the folder outright, as a path
        # over 200 characters gets a cut, hashed name: not the slug either way
        $folder = if ($env:CLAUDE_CODE_PROJECT_DIR_NAME) { $env:CLAUDE_CODE_PROJECT_DIR_NAME } else { $cwd.TrimEnd('\', '/') -replace '[^A-Za-z0-9]', '-' }
        $pdir = Join-Path (Join-Path $env:CLAUDE_CONFIG_DIR 'projects') $folder
        New-Item -ItemType Directory -Path $pdir -Force | Out-Null
        $n = [Array]::IndexOf($argv, '--name')
        $recs = @()
        if ($n -ge 0 -and $n + 1 -lt $argv.Count) { $recs += ([ordered]@{ type = 'custom-title'; customTitle = $argv[$n + 1]; sessionId = $session } | ConvertTo-Json -Compress) }
        $recs += ([ordered]@{
                type = 'user'; message = @{ role = 'user'; content = $prompt }; uuid = [guid]::NewGuid().ToString()
                timestamp = (Get-Date).ToUniversalTime().ToString('o'); sessionId = $session; cwd = $cwd; permissionMode = 'default'; entrypoint = 'sdk-cli'
            } | ConvertTo-Json -Compress -Depth 5)
        $env:FAKE_NEW_TRANSCRIPT = Join-Path $pdir "$session.jsonl"
        [IO.File]::WriteAllText($env:FAKE_NEW_TRANSCRIPT, ($recs -join "`n") + "`n", $utf8)
    }
}

if ($env:FAKE_REGISTER -and $env:FAKE_REGISTER_BODY) {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $entry = $env:FAKE_REGISTER_BODY.Replace('{{NOW}}', "$now")
    [IO.File]::WriteAllText($env:FAKE_REGISTER, $entry, $utf8)
    if ($env:FAKE_AGENTS_FILE) { [IO.File]::WriteAllText($env:FAKE_AGENTS_FILE, "[$entry]", $utf8) }
}

if ($env:FAKE_LAND -and (Test-Path -LiteralPath $env:FAKE_LAND)) {
    $rec = [ordered]@{
        type = 'user'; message = @{ role = 'user'; content = $prompt }
        uuid = [guid]::NewGuid().ToString(); timestamp = (Get-Date).ToUniversalTime().ToString('o')
        sessionId = $session
    } | ConvertTo-Json -Compress -Depth 5
    [IO.File]::AppendAllText($env:FAKE_LAND, $rec + "`n", $utf8)
}

if (($env:FAKE_PERMIT -or $env:FAKE_PERMIT_SELF) -and $argv -contains '--permission-prompt-tool' -and $argv -contains '--mcp-config') {
    # claude -p with a permission prompt tool: start its MCP server, then ask
    # it about each call the way S35 saw claude do - the assistant's tool_use
    # line on stdout first, then tools/call, the run blocked on the answer
    $out = [Console]::OpenStandardOutput()
    $emit = { param($o) $b = $utf8.GetBytes((ConvertTo-Json $o -Compress -Depth 10) + "`n"); $out.Write($b, 0, $b.Length); $out.Flush() }
    $rec = { param($name, $text) if ($env:FAKE_RECORD) { [IO.File]::AppendAllText((Join-Path $env:FAKE_RECORD $name), $text + "`n", $utf8) } }
    $cfgPath = $argv[[Array]::IndexOf($argv, '--mcp-config') + 1]
    $srv = ([IO.File]::ReadAllText($cfgPath, $utf8) | ConvertFrom-Json).mcpServers.chatqpermit
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = [string]$srv.command
    $psi.Arguments = (@($srv.args) | ForEach-Object { if ([string]$_ -match '\s') { '"' + $_ + '"' } else { [string]$_ } }) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8
    if ($srv.env) { foreach ($p in $srv.env.PSObject.Properties) { $psi.EnvironmentVariables[$p.Name] = [string]$p.Value } }
    $proc = $null
    $up = $false
    $t0 = Get-Date
    try { $proc = [System.Diagnostics.Process]::Start($psi) } catch { $proc = $null }
    $send = { param($s) $b = $utf8.GetBytes($s + "`n"); $proc.StandardInput.BaseStream.Write($b, 0, $b.Length); $proc.StandardInput.BaseStream.Flush() }
    # every answer read in order; one that is for another id waits its turn
    $early = @{}
    # a read left pending past a timeout is picked up by the next one
    $pend = @{ T = $null }
    $answer = {
        param($id, [int]$Sec)
        $until = (Get-Date).AddSeconds($Sec)
        while ((Get-Date) -lt $until) {
            if ($early.ContainsKey($id)) { $l = $early[$id]; $early.Remove($id); return $l }
            if (-not $pend.T) { $pend.T = $proc.StandardOutput.ReadLineAsync() }
            while (-not $pend.T.Wait(200)) { if ((Get-Date) -gt $until) { return $null } }
            $l = $pend.T.Result
            $pend.T = $null
            if ($null -eq $l) { return $null }
            $got = ([regex]::Match($l, '"id":("[^"]*"|\d+)')).Groups[1].Value
            if ($got -eq $id) { return $l }
            $early[$got] = $l
        }
        return $null
    }
    if ($proc) {
        if ($env:FAKE_RECORD) { [IO.File]::WriteAllText((Join-Path $env:FAKE_RECORD 'bridge.pid'), "$($proc.Id)", $utf8) }
        try {
            & $send '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"fake-claude","version":"1"}}}'
            $init = & $answer '0' 30
            if ($init -and $init.StartsWith('{')) {
                & $send '{"jsonrpc":"2.0","method":"notifications/initialized"}'
                & $send '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
                $tl = & $answer '1' 10
                $up = [bool]($tl -and $tl -match '"name":"decide"')
            }
        }
        catch { $up = $false }
    }
    & $rec 'permit.jsonl' ('{"up":' + $(if ($up) { 'true' } else { 'false' }) + ',"ms":' + [int]((Get-Date) - $t0).TotalMilliseconds + '}')
    & $emit ([ordered]@{ type = 'system'; subtype = 'init'; session_id = $session; model = 'claude-fake-1'; permissionMode = 'default'; claude_code_version = '2.1.278'
            mcp_servers = @([ordered]@{ name = 'chatqpermit'; status = $(if ($up) { 'connected' } else { 'failed' }) }) })
    $calls = @()
    if ($env:FAKE_PERMIT) { $calls += @($env:FAKE_PERMIT | ConvertFrom-Json) }
    if ($env:FAKE_PERMIT_SELF) { $calls += [pscustomobject]@{ tool_name = 'Bash'; input = [pscustomobject]@{ command = 'echo made up' }; id = 'toolu_self'; self = $true } }
    $denials = @()
    $n = 10
    foreach ($c in $calls) {
        $self = [bool]($c.PSObject.Properties['self'] -and $c.self)
        if (-not $self) {
            & $emit ([ordered]@{ type = 'assistant'; message = [ordered]@{ model = 'claude-fake-1'; role = 'assistant'; content = @([ordered]@{ type = 'tool_use'; id = [string]$c.id; name = [string]$c.tool_name; input = $c.input }) }; session_id = $session })
        }
        if (-not $up) {
            # as claude.exe 2.1.283 ends a run whose prompt tool never came up
            $e = [Console]::OpenStandardError()
            $b = $utf8.GetBytes("Error: MCP tool mcp__chatqpermit__decide (passed via --permission-prompt-tool) not found. Available MCP tools: none`n")
            $e.Write($b, 0, $b.Length); $e.Flush()
            exit 1
        }
        $n++
        $args0 = [ordered]@{ tool_name = [string]$c.tool_name; input = $c.input; tool_use_id = [string]$c.id }
        & $send ('{"jsonrpc":"2.0","id":' + $n + ',"method":"tools/call","params":{"name":"decide","arguments":' + (ConvertTo-Json $args0 -Compress -Depth 10) + '}}')
        $wait = if ($env:FAKE_PERMIT_WAIT) { [int]$env:FAKE_PERMIT_WAIT } else { 240 }
        $a = & $answer "$n" $wait
        & $rec 'permit.jsonl' $(if ($a) { $a } else { '{"none":true}' })
        $v = $null
        if ($a) { try { $v = (($a | ConvertFrom-Json).result.content[0].text) | ConvertFrom-Json } catch { $v = $null } }
        if ($v -and $v.behavior -eq 'allow') {
            & $emit ([ordered]@{ type = 'user'; message = [ordered]@{ role = 'user'; content = @([ordered]@{ type = 'tool_result'; tool_use_id = [string]$c.id; content = 'ran' }) }; session_id = $session })
        }
        else {
            $msg = if ($v) { [string]$v.message } else { 'no answer' }
            & $emit ([ordered]@{ type = 'user'; message = [ordered]@{ role = 'user'; content = @([ordered]@{ type = 'tool_result'; tool_use_id = [string]$c.id; content = $msg; is_error = $true }) }; session_id = $session })
            if (-not $self) { $denials += [ordered]@{ tool_name = [string]$c.tool_name; tool_use_id = [string]$c.id; tool_input = $c.input } }
        }
    }
    try { $proc.StandardInput.Close() } catch {}
    $gone = $false
    try { $gone = $proc.WaitForExit(5000) } catch {}
    & $rec 'permit.jsonl' ('{"exited":' + $(if ($gone) { 'true' } else { 'false' }) + '}')
    & $emit ([ordered]@{ type = 'assistant'; message = [ordered]@{ model = 'claude-fake-1'; role = 'assistant'; content = @([ordered]@{ type = 'text'; text = 'ok' }) }; session_id = $session })
    & $emit ([ordered]@{ is_error = $false; num_turns = 2; subtype = 'success'; result = 'ok'; session_id = $session; permission_denials = @($denials); type = 'result' })
    exit 0
}

$lines = if ($env:FAKE_SCENARIO) { [IO.File]::ReadAllLines($env:FAKE_SCENARIO, $utf8) } else {
    @(
        '{"type":"system","subtype":"init","session_id":"{{SESSION}}","model":"claude-fake-1","permissionMode":"default","claude_code_version":"2.1.278"}'
        '{"type":"assistant","message":{"model":"claude-fake-1","role":"assistant","content":[{"type":"text","text":"ok"}]}}'
        '{"is_error":false,"num_turns":1,"subtype":"success","result":"ok","session_id":"{{SESSION}}","permission_denials":[],"type":"result"}'
    )
}
$resets = [DateTimeOffset]::UtcNow.AddHours(2).ToUnixTimeSeconds()
$out = [Console]::OpenStandardOutput()
foreach ($l in $lines) {
    if (-not $l.Trim()) { continue }
    $t = $l.Replace('{{RESETS}}', "$resets").Replace('{{SESSION}}', $session)
    $b = $utf8.GetBytes($t + "`n")
    $out.Write($b, 0, $b.Length)
}
$out.Flush()
# and a new chat that got its answer keeps it, as the real one would
if ($env:FAKE_NEW_TRANSCRIPT -and -not $env:FAKE_SCENARIO) {
    $a = [ordered]@{ type = 'assistant'; uuid = [guid]::NewGuid().ToString(); timestamp = (Get-Date).ToUniversalTime().ToString('o'); sessionId = $session
        message = [ordered]@{ model = 'claude-fake-1'; role = 'assistant'; content = @([ordered]@{ type = 'text'; text = 'ok' }); stop_reason = 'end_turn' } } | ConvertTo-Json -Compress -Depth 6
    [IO.File]::AppendAllText($env:FAKE_NEW_TRANSCRIPT, $a + "`n", $utf8)
}
exit 0
