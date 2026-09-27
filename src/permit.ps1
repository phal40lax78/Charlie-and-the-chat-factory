# VS-code-chat-manager, src/permit.ps1: dot-sourced by VS-code-chat-manager.ps1
# in its turn, never on its own - see the list there.

#region permit: a queued run asks the phone ------------------------------------
# A queued Claude run meets a permission prompt and nobody is at the PC to
# answer it. Before this the run was told no (--permission-prompts none) and
# the job parked as needs input. With permit.on, the run gets a bridge
# instead: an MCP server claude -p starts itself (--permission-prompt-tool),
# which is this same script loaded in a hidden Windows PowerShell and running
# Start-ChatqPermitBridge. Claude hands it each prompt and waits.
#
# The bridge does no network at all. It writes what is asked into
# data/permit/<jobId>/<rid>.req.json and waits. The watcher - the one process
# that polls the reply topic and sends pushes - sees the file on its next
# tick, sends a "permission" push whose link carries the request sealed for
# the phone (a card), and hands the phone's sealed answer back in
# <rid>.ans.json. The bridge believes an allow only when it opens that answer
# itself with the phone's key and it names this very request: anything that
# can write into data/ without the key can only ever make it say no.
#
# An allow is one call, as shown, and nothing more: no "always allow", no
# changed input, no other mode. See docs/phone-permit-spec.md.

$script:ChatqPermitMin = '2.1.259'   # --permission-prompts host|none
$script:ChatqPermitDir = Join-Path $script:ChatqData 'permit'
$script:ChatqPermitTool = 'mcp__chatqpermit__decide'
$script:ChatqPermitDefaultTools = @('Bash', 'PowerShell', 'Edit', 'Write', 'MultiEdit', 'NotebookEdit', 'WebFetch')
# the modes that prompt at all: dontAsk and bypassPermissions never do, and
# plan keeps its own "plan ready - approve it in VS Code"
$script:ChatqPermitModes = @('default', 'manual', 'acceptEdits', 'auto')
$script:ChatqPermitProtocols = @('2024-11-05', '2025-03-26', '2025-06-18', '2025-11-25')
# when this process sent each permission push, for the cap of 20 an hour
$script:ChatqPermitAsked = [System.Collections.Generic.List[datetime]]::new()
# tests only: the bridge's deadline in seconds instead of permit.waitMinutes,
# and the exe the launch names instead of Windows PowerShell
$script:ChatqPermitWaitSeconds = $null
$script:ChatqPermitExeSeam = $null

function Get-ChatqPermitConfig {
    # config.json's permit block with its defaults: On (off unless true),
    # WaitMinutes (1-25, 10), Tools (the names and mcp__ patterns the phone
    # may approve), MaxPerRun (10)
    param($Cfg)
    if (-not $Cfg) { $Cfg = Get-ChatqConfig }
    $p = if ($Cfg.PSObject.Properties['permit'] -and $Cfg.permit) { $Cfg.permit } else { [pscustomobject]@{} }
    $has = { param($n) [bool]($p.PSObject.Properties[$n] -and $null -ne $p.$n) }
    $wait = 10
    if ((& $has 'waitMinutes') -and ($p.waitMinutes -as [int]) -ge 1) { $wait = [Math]::Min(25, [int]$p.waitMinutes) }
    $tools = @($script:ChatqPermitDefaultTools)
    if ((& $has 'tools') -and @($p.tools).Count) { $tools = @(@($p.tools) | ForEach-Object { [string]$_ } | Where-Object { $_ }) }
    $max = 10
    if ((& $has 'maxPerRun') -and ($p.maxPerRun -as [int]) -ge 1) { $max = [int]$p.maxPerRun }
    [pscustomobject]@{ On = [bool]((& $has 'on') -and $p.on -eq $true); WaitMinutes = $wait; Tools = $tools; MaxPerRun = $max }
}

function Get-ChatqPermitMode {
    # the mode a run goes in, as Invoke-ChatqRun picks it
    param($Job)
    $m = [string](Get-ChatField $Job 'mode')
    if (-not $m) { $m = [string](Get-ChatField $Job 'modeAtQueue') }
    if (-not $m) { $m = 'default' }
    return $m
}

function Test-ChatqPermitReady {
    <#
    Does this run ask the phone? @{ Ok; Why }. Every one of these, or the run
    goes exactly as before (--permission-prompts none): permit.on, replies on
    with a phone paired, a phone channel that carries a link, a Claude job, a
    CLI new enough, a mode that prompts at all, and no bridge that failed on
    this job already (permitOff). Asked as the run starts and again for each
    request, since a pairing can change under a run.
    #>
    param($Cfg, $Job)
    $no = { param($w) [pscustomobject]@{ Ok = $false; Why = $w } }
    if (-not $Cfg) { $Cfg = Get-ChatqConfig }
    if (-not (Get-ChatqPermitConfig $Cfg).On) { return (& $no 'permissions from the phone are off') }
    if (-not (Get-ChatqReplyConfig $Cfg).Links) { return (& $no 'no phone is paired, or replies are off') }
    if (-not (Test-ChatqLinkChannel $Cfg)) { return (& $no 'no phone channel carries a link') }
    if ([string](Get-ChatField $Job 'provider') -ne 'claude') { return (& $no 'only Claude can ask mid-run') }
    if (Get-ChatField $Job 'permitOff') { return (& $no 'the bridge failed on this job before') }
    $mode = Get-ChatqPermitMode $Job
    if ($mode -notin $script:ChatqPermitModes) { return (& $no "mode $mode never asks") }
    $exe = Find-ChatqExe 'claude'
    $v = Get-ChatqCliVersion $exe
    if (-not $v -or (Compare-ChatVersion $v $script:ChatqPermitMin) -lt 0) { return (& $no "Claude Code $(if ($v) { $v } else { '(version unknown)' }) is older than $($script:ChatqPermitMin)") }
    return [pscustomobject]@{ Ok = $true; Why = $null }
}

function Get-ChatqPermitStatusText {
    # one line for chatnotify and the setup window
    param($Cfg)
    if (-not $Cfg) { $Cfg = Get-ChatqConfig }
    $pc = Get-ChatqPermitConfig $Cfg
    if (-not $pc.On) { return 'off - a run that needs one stops as needs input' }
    if (-not (Get-ChatqReplyConfig $Cfg).Links) { return 'on, but no phone is paired - runs deny as before' }
    $t = @($pc.Tools)
    $names = if ($t.Count -gt 3) { (@($t[0..2]) -join ', ') + ', ...' } else { $t -join ', ' }
    return "on - $names asked on the phone, $($pc.WaitMinutes) min to answer"
}

function Get-ChatqPermitDataRule {
    # chatq's data folder as a Claude Code permission rule path: an absolute
    # path is //c/Users/... there, forward slashes, the drive letter lower case
    param([string]$Path = $script:ChatqData)
    $p = ([string]$Path).Replace('\', '/').TrimEnd('/')
    if ($p -match '^([A-Za-z]):(/.*)?$') { $p = '//' + $Matches[1].ToLowerInvariant() + $Matches[2] }
    return $p + '/**'
}

function Get-ChatqPermitLaunch {
    <#
    The bridge's launch as mcp.json holds it: @{ Exe; Args; Env; Command }.
    Windows PowerShell on Windows, the PowerShell this runs in elsewhere, no
    profile, -ExecutionPolicy Bypass for that process alone. It dot-sources
    the script with CHATQ_OVERLAY set - no key bindings, no watcher started
    on load - with everything the load says sent to nothing: stdout is the
    MCP channel, and one stray line there breaks it. A failure to load lands
    in data/logs/permit.log. Env names what a stdio server may not otherwise
    be handed; from pwsh 7 the module path is Windows PowerShell's own again.
    #>
    param([string]$JobId, [string]$RunId, [string]$Path = $script:ChatqScriptPath, [int]$WaitSeconds = 0)
    $q = { param($s) "'" + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent([string]$s) + "'" }
    $win = [bool]$script:ChatqIsWindows
    $root = if ($env:SystemRoot) { $env:SystemRoot } else { 'C:\Windows' }
    $exe = if ($script:ChatqPermitExeSeam) { [string]$script:ChatqPermitExeSeam }
    elseif ($win) { Join-Path $root 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    else { (Get-Process -Id $PID).Path }
    $log = Join-Path $script:ChatqLogDir 'permit.log'
    $wait = if ($WaitSeconds -gt 0) { " -WaitSeconds $WaitSeconds" } else { '' }
    $cmd = "`$ProgressPreference = 'SilentlyContinue'; `$env:CHATQ_OVERLAY = '1'; " +
    "try { . $(& $q $Path) *> `$null } catch { try { [void][IO.Directory]::CreateDirectory($(& $q $script:ChatqLogDir)); " +
    "[IO.File]::AppendAllText($(& $q $log), (Get-Date).ToString('o') + '  bridge: the script did not load: ' + `$_.Exception.Message + [char]10) } catch {}; exit 1 }; " +
    "Remove-Item -LiteralPath 'env:PSExecutionPolicyPreference', 'env:CHATQ_OVERLAY' -EA SilentlyContinue; " +
    "exit (Start-ChatqPermitBridge -JobId $(& $q $JobId) -RunId $(& $q $RunId)$wait)"
    $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmd))
    $argv = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-OutputFormat', 'Text', '-EncodedCommand', $enc)
    $envs = [ordered]@{}
    if ($win) {
        $envs['SystemRoot'] = $root
        foreach ($n in 'USERPROFILE', 'APPDATA', 'LOCALAPPDATA') { $v = [Environment]::GetEnvironmentVariable($n); if ($v) { $envs[$n] = $v } }
        $docs = [Environment]::GetFolderPath('MyDocuments')
        $pf = if ($env:ProgramFiles) { $env:ProgramFiles } else { 'C:\Program Files' }
        $mods = @((Join-Path $docs 'WindowsPowerShell\Modules'), (Join-Path $pf 'WindowsPowerShell\Modules'), (Join-Path $root 'System32\WindowsPowerShell\v1.0\Modules'))
        $envs['PSModulePath'] = $mods -join ';'
    }
    return [pscustomobject]@{ Exe = $exe; Args = $argv; Env = $envs; Command = $cmd }
}

function New-ChatqPermitRun {
    <#
    Ready a run to ask the phone: a run id kept on the job (a late answer
    from an earlier run is told that run is over), and data/permit/<jobId>/
    made afresh with mcp.json - the bridge - and settings.json, the run's own
    rules merged over the user's: AskUserQuestion denied, as none denied it
    (nobody answers questions mid-run), and no edit of chatq's data/ without
    a prompt. Returns what Invoke-ChatqRun and the watcher's tick need.
    #>
    param($Job, $Cfg)
    if (-not $Cfg) { $Cfg = Get-ChatqConfig }
    $pc = Get-ChatqPermitConfig $Cfg
    $runId = New-ChatqRandomName 10
    Set-ChatqProp $Job 'runId' $runId
    Set-ChatqProp $Job 'permitWaiting' $null
    Save-ChatqJob $Job
    $dir = Join-Path $script:ChatqPermitDir ([string]$Job.id)
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -EA SilentlyContinue }
    New-ChatqDir $dir
    $wait = if ($script:ChatqPermitWaitSeconds) { [int]$script:ChatqPermitWaitSeconds } else { 0 }
    $l = Get-ChatqPermitLaunch -JobId ([string]$Job.id) -RunId $runId -WaitSeconds $wait
    $mcp = [ordered]@{ mcpServers = [ordered]@{ chatqpermit = [ordered]@{ type = 'stdio'; command = $l.Exe; args = @($l.Args); env = $l.Env } } }
    $mcpPath = Join-Path $dir 'mcp.json'
    Save-ChatqJson $mcpPath $mcp
    $rule = Get-ChatqPermitDataRule
    $set = [ordered]@{ permissions = [ordered]@{ deny = @('AskUserQuestion', "Edit($rule)", "Write($rule)", "NotebookEdit($rule)") } }
    $setPath = Join-Path $dir 'settings.json'
    Save-ChatqJson $setPath $set
    Write-ChatqWatchLog "#$($Job.seq) asks the phone for permissions (run $runId, $($pc.WaitMinutes) min each)"
    [pscustomobject]@{
        JobId = [string]$Job.id; RunId = $runId; Dir = $dir; McpPath = $mcpPath; SettingsPath = $setPath
        WaitMinutes = $pc.WaitMinutes; TimeoutMs = ($pc.WaitMinutes + 3) * 60000
        St = $null; Seen = @{}; Open = @{}; Launch = $l
    }
}

#endregion

#region permit: the bridge, a stdio MCP server -----------------------------------

function Write-ChatqPermitLog {
    # data/logs/permit.log, rolled at 1 MB: the bridge's side of every request
    param([string]$Text)
    try {
        New-ChatqDir $script:ChatqLogDir
        $p = Join-Path $script:ChatqLogDir 'permit.log'
        if ((Test-Path -LiteralPath $p) -and (Get-Item -LiteralPath $p).Length -gt 1MB) { Move-Item -LiteralPath $p -Destination "$p.1" -Force }
        [System.IO.File]::AppendAllText($p, "$((Get-Date).ToString('o'))  [$PID] $($Text -replace '[\r\n]+', ' ')`n", (New-Object System.Text.UTF8Encoding $false))
    }
    catch {}
}

function Get-ChatqJsonStringEnd {
    # the index just past the closing quote of the JSON string that opens at
    # $At, or -1: every quote is looked at, and one with an odd run of
    # backslashes before it is inside the string
    param([string]$Json, [int]$At)
    $j = $At + 1
    while ($true) {
        $k = $Json.IndexOf('"', $j)
        if ($k -lt 0) { return -1 }
        $b = 0
        $x = $k - 1
        while ($x -gt $At -and $Json[$x] -eq '\') { $b++; $x-- }
        if (($b % 2) -eq 0) { return $k + 1 }
        $j = $k + 1
    }
}

function Skip-ChatqJsonValue {
    # the index just past the JSON value that starts at $At, or -1. Jumps
    # from one quote or bracket to the next, so a request holding a large
    # file's contents is read in a few steps, not character by character.
    param([string]$Json, [int]$At)
    if ($At -ge $Json.Length) { return -1 }
    $c = $Json[$At]
    if ($c -eq '"') { return (Get-ChatqJsonStringEnd $Json $At) }
    if ($c -eq '{' -or $c -eq '[') {
        $depth = 0
        $j = $At
        $stops = [char[]]@('"', '{', '}', '[', ']')
        while ($true) {
            $k = $Json.IndexOfAny($stops, $j)
            if ($k -lt 0) { return -1 }
            $ch = $Json[$k]
            if ($ch -eq '"') { $e = Get-ChatqJsonStringEnd $Json $k; if ($e -lt 0) { return -1 }; $j = $e; continue }
            if ($ch -eq '{' -or $ch -eq '[') { $depth++ }
            else { $depth--; if ($depth -eq 0) { return $k + 1 } }
            $j = $k + 1
        }
    }
    $k = $Json.IndexOfAny([char[]]@(',', '}', ']', ' ', "`t", "`r", "`n"), $At)
    if ($k -lt 0) { return $Json.Length }
    return $k
}

function Get-ChatqJsonRaw {
    <#
    The raw JSON text of one member, found by its dotted path -
    'params.arguments.input' - exactly as it came, or $null when it is not
    there. String-aware: braces and quotes inside strings, \" and Hangul are
    passed over as text. The bridge keeps a tool's input this way and never
    re-serializes it: pwsh 7's ConvertFrom-Json turns ISO dates into
    [datetime], and 5.1 writes < > & ' back as escapes.
    #>
    param([string]$Json, [string]$Path)
    if (-not $Json) { return $null }
    $ws = { param($i) while ($i -lt $Json.Length -and [char]::IsWhiteSpace($Json[$i])) { $i++ }; $i }
    $start = & $ws 0
    $end = -1
    foreach ($seg in ($Path -split '\.')) {
        $i = & $ws $start
        if ($i -ge $Json.Length -or $Json[$i] -ne '{') { return $null }
        $i++
        $hit = $false
        while ($true) {
            $i = & $ws $i
            if ($i -ge $Json.Length -or $Json[$i] -ne '"') { return $null }
            $ke = Get-ChatqJsonStringEnd $Json $i
            if ($ke -lt 0) { return $null }
            $key = $Json.Substring($i + 1, $ke - $i - 2)
            $i = & $ws $ke
            if ($i -ge $Json.Length -or $Json[$i] -ne ':') { return $null }
            $i = & $ws ($i + 1)
            $ve = Skip-ChatqJsonValue $Json $i
            if ($ve -lt 0) { return $null }
            if ($key -ceq $seg) { $start = $i; $end = $ve; $hit = $true; break }
            $i = & $ws $ve
            if ($i -lt $Json.Length -and $Json[$i] -eq ',') { $i++; continue }
            return $null
        }
        if (-not $hit) { return $null }
    }
    if ($end -lt 0) { return $null }
    return $Json.Substring($start, $end - $start)
}

function Get-ChatqPermitDigest {
    # what binds an answer to one request: b64url of the first 16 bytes of
    # SHA-256 over the request id, the tool and its input as Claude sent it
    param([string]$Rid, [string]$Tool, [string]$InputRaw)
    $u = New-Object System.Text.UTF8Encoding $false
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $h = $sha.ComputeHash($u.GetBytes("chatq-permit`n$Rid`n$Tool`n$InputRaw")) } finally { $sha.Dispose() }
    return (ConvertTo-ChatqB64Url ([byte[]]$h[0..15]))
}

function ConvertTo-ChatqMcpJson {
    # one JSON value on one line, as the MCP stdio framing wants it
    param($Value)
    if ($Value -is [string]) { return ($Value | ConvertTo-Json -Compress) }
    return ($Value | ConvertTo-Json -Compress -Depth 8)
}

function New-ChatqMcpResult {
    # a JSON-RPC result for the id as it came (a number or a string, raw)
    param([string]$IdRaw, [string]$ResultJson)
    return '{"jsonrpc":"2.0","id":' + $IdRaw + ',"result":' + $ResultJson + '}'
}

function New-ChatqMcpError {
    param([string]$IdRaw, [int]$Code, [string]$Message)
    return '{"jsonrpc":"2.0","id":' + $IdRaw + ',"error":{"code":' + $Code + ',"message":' + (ConvertTo-ChatqMcpJson $Message) + '}}'
}

function New-ChatqPermitVerdict {
    # the tool's answer to Claude: one text block holding the verdict's JSON.
    # An allow names no updatedInput - the call runs as Claude asked for it
    # (2.1.207 and later) - and never updatedPermissions.
    param([string]$IdRaw, [switch]$Allow, [string]$Message)
    $v = if ($Allow) { '{"behavior":"allow"}' } else { ([ordered]@{ behavior = 'deny'; message = $Message } | ConvertTo-Json -Compress) }
    return (New-ChatqMcpResult $IdRaw ('{"content":[{"type":"text","text":' + (ConvertTo-ChatqMcpJson $v) + '}]}'))
}

function New-ChatqPermitBridgeState {
    # everything the bridge holds for the life of one run, in memory
    param([string]$JobId, [string]$RunId, [int]$WaitSeconds = 0, $Cfg)
    if (-not $Cfg) { $Cfg = Get-ChatqConfig }
    $pc = Get-ChatqPermitConfig $Cfg
    @{
        JobId = $JobId; RunId = $RunId; Dir = (Join-Path $script:ChatqPermitDir $JobId)
        WaitSeconds = $(if ($WaitSeconds -gt 0) { $WaitSeconds } else { $pc.WaitMinutes * 60 }); Tools = @($pc.Tools); MaxPerRun = $pc.MaxPerRun
        Pending = [ordered]@{}; ById = @{}; Asked = 0; Missed = $false; Nonces = @{}; Aids = @{}; Out = $null; Sent = [System.Collections.Generic.List[string]]::new()
    }
}

function Write-ChatqMcpMessage {
    # one message, one line, UTF-8 on the raw stream and flushed at once -
    # never through Write-Output or the console's code page
    param($State, [string]$Text)
    if ($null -eq $State.Out) { $State.Sent.Add($Text); return }
    $b = (New-Object System.Text.UTF8Encoding $false).GetBytes($Text + "`n")
    $State.Out.Write($b, 0, $b.Length)
    $State.Out.Flush()
}

function Read-ChatqMcpLine {
    # the next line from claude, waiting 250 ms at most: $null while none
    # has come, [DBNull] once stdin is closed. The read left pending is
    # picked up on the next call, so a ping is answered while a call waits.
    param($State)
    if (-not $State.Task) { $State.Task = $State.Reader.ReadLineAsync() }
    if (-not $State.Task.Wait(250)) { return $null }
    $line = $State.Task.Result
    $State.Task = $null
    if ($null -eq $line) { return [DBNull]::Value }
    return $line
}

function Invoke-ChatqMcpRequest {
    <#
    One line from claude, answered: the reply's text, or $null for a
    notification or a call left waiting on the phone. initialize, ping,
    tools/list, tools/call (decide), notifications/cancelled; anything else
    with an id is "Method not found".
    #>
    param([string]$Line, $State)
    $m = try { $Line | ConvertFrom-Json } catch { $null }
    if (-not $m) { Write-ChatqPermitLog 'bridge: a line that is not JSON - ignored'; return $null }
    $method = [string](Get-ChatField $m 'method')
    $idRaw = Get-ChatqJsonRaw $Line 'id'
    if ($method -like 'notifications/*') {
        if ($method -eq 'notifications/cancelled') {
            $rq = Get-ChatqJsonRaw $Line 'params.requestId'
            $rid = if ($rq) { $State.ById[$rq] } else { $null }
            if ($rid -and $State.Pending.Contains($rid)) {
                $State.Pending.Remove($rid)
                $State.ById.Remove($rq)
                Update-ChatqPermitRequestFile $State $rid @{ withdrawn = $true }
                Write-ChatqPermitLog "bridge: $rid withdrawn by claude"
            }
        }
        return $null
    }
    if (-not $idRaw) { return $null }
    switch -Exact ($method) {
        'initialize' {
            $asked = [string](Get-ChatField (Get-ChatField $m 'params') 'protocolVersion')
            $pv = if ($asked -in $script:ChatqPermitProtocols) { $asked } else { '2025-06-18' }
            $r = [ordered]@{ protocolVersion = $pv; capabilities = [ordered]@{ tools = @{} }; serverInfo = [ordered]@{ name = 'chatqpermit'; version = [string]$script:ChatVersion } }
            return (New-ChatqMcpResult $idRaw ($r | ConvertTo-Json -Compress -Depth 5))
        }
        'ping' { return (New-ChatqMcpResult $idRaw '{}') }
        'tools/list' {
            $tool = [ordered]@{
                name = 'decide'
                description = "chatq's own: routes this run's permission prompts to the user's phone. Never call it yourself."
                inputSchema = [ordered]@{
                    type = 'object'
                    properties = [ordered]@{ tool_name = @{ type = 'string' }; input = @{ type = 'object' }; tool_use_id = @{ type = 'string' } }
                    required = @('tool_name', 'input')
                }
            }
            return (New-ChatqMcpResult $idRaw ('{"tools":[' + ($tool | ConvertTo-Json -Compress -Depth 6) + ']}'))
        }
        'tools/call' {
            $name = [string](Get-ChatField (Get-ChatField $m 'params') 'name')
            if ($name -ne 'decide') { return (New-ChatqMcpError $idRaw -32602 "no tool $name") }
            try { return (Invoke-ChatqPermitCall $State $Line $m $idRaw) }
            catch {
                Write-ChatqPermitLog "bridge: the call failed - $($_.Exception.Message)"
                return (New-ChatqPermitVerdict $idRaw -Message "chatq's permission bridge failed - denied")
            }
        }
        default { return (New-ChatqMcpError $idRaw -32601 'Method not found') }
    }
}

function Test-ChatqPermitUnder {
    # is this path in the folder $Dir, or the folder itself - any case,
    # either slash, relative to where claude runs
    param([string]$Path, [string]$Dir)
    if (-not $Path) { return $false }
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { $full = $Path }
    $f = $full.Replace('/', '\').TrimEnd('\').ToLowerInvariant()
    $d = ([string]$Dir).Replace('/', '\').TrimEnd('\').ToLowerInvariant()
    return ($f -eq $d -or $f.StartsWith($d + '\'))
}

function Get-ChatqPermitRule {
    <#
    What the phone is never asked: $null (ask it) or the deny message. A
    question, the plan, a tool not in permit.tools, an edit of chatq's own
    data/ or of a Claude settings or MCP file, a command naming chatq's
    data/ folder (best effort: a command can reach a folder without naming
    it), and past the caps - permit.maxPerRun this run, 3 waiting at once,
    or anything after one request went unanswered.
    #>
    param([string]$Tool, $ToolInput, $State)
    $never = { param($w) "chatq never lets the phone approve $w. Do not retry it; finish what you can without it and say what is left." }
    $busy = { param($w) "Nobody can approve this right now: $w. Do not retry it; finish what you can without it and say what is left." }
    if ($Tool -eq 'AskUserQuestion') { return 'Nobody can answer questions during this run. Make the most reasonable choice, say which, and go on.' }
    if ($Tool -eq 'ExitPlanMode') { return 'The plan waits for approval in VS Code.' }
    $listed = $false
    foreach ($t in @($State.Tools)) { if ($Tool -like $t) { $listed = $true; break } }
    if (-not $listed) { return (& $never $Tool) }
    $data = $script:ChatqData
    if ($Tool -in 'Edit', 'Write', 'MultiEdit', 'NotebookEdit') {
        $p = [string](Get-ChatField $ToolInput 'file_path')
        if (-not $p) { $p = [string](Get-ChatField $ToolInput 'notebook_path') }
        if (Test-ChatqPermitUnder $p $data) { return (& $never "an edit of chatq's own files") }
        $n = $p.Replace('/', '\').ToLowerInvariant()
        foreach ($end in '\.claude\settings.json', '\.claude\settings.local.json', '\.claude.json', '\.mcp.json') {
            if ($n.EndsWith($end) -or $n -eq $end.TrimStart('\')) { return (& $never 'an edit of a Claude settings or MCP file') }
        }
    }
    if ($Tool -in 'Bash', 'PowerShell') {
        $c = ([string](Get-ChatField $ToolInput 'command')).Replace('/', '\').ToLowerInvariant()
        $d = $data.Replace('/', '\').TrimEnd('\').ToLowerInvariant()
        if ($c -and $c.Contains($d)) { return (& $never "a command that names chatq's data folder") }
    }
    if ($State.Missed) { return (& $busy 'an earlier request in this run went unanswered') }
    if ($State.Asked -ge $State.MaxPerRun) { return (& $busy "$($State.MaxPerRun) calls were asked about in this run already") }
    if ($State.Pending.Count -ge 3) { return (& $busy '3 requests are waiting already') }
    return $null
}

function Update-ChatqPermitRequestFile {
    # a few fields added to <rid>.req.json - withdrawn, timedOut, answer
    param($State, [string]$Rid, [hashtable]$Fields)
    try {
        $p = Join-Path $State.Dir "$Rid.req.json"
        $o = Read-ChatqJson $p
        if (-not $o) { return }
        foreach ($k in $Fields.Keys) { Set-ChatqProp $o $k $Fields[$k] }
        Save-ChatqJson $p $o
    }
    catch {}
}

function Invoke-ChatqPermitCall {
    # one tools/call for decide: denied at once by rule, or written as
    # <rid>.req.json and left waiting ($null)
    param($State, [string]$Line, $Msg, [string]$IdRaw)
    $args0 = Get-ChatField (Get-ChatField $Msg 'params') 'arguments'
    $tool = Get-ChatField $args0 'tool_name'
    $inObj = Get-ChatField $args0 'input'
    $raw = Get-ChatqJsonRaw $Line 'params.arguments.input'
    if (-not ($tool -is [string]) -or $tool.Length -lt 1 -or $tool.Length -gt 100 -or $null -eq $inObj -or -not $raw -or -not $raw.StartsWith('{')) {
        Write-ChatqPermitLog 'bridge: a request it could not read - denied'
        return (New-ChatqPermitVerdict $IdRaw -Message 'chatq could not read the request - denied.')
    }
    $rule = Get-ChatqPermitRule $tool $inObj $State
    if ($rule) {
        Write-ChatqPermitLog "bridge: $tool denied by rule - $rule"
        return (New-ChatqPermitVerdict $IdRaw -Message $rule)
    }
    $rid = New-ChatqRandomName 10
    $now = (Get-Date).ToUniversalTime()
    $until = $now.AddSeconds($State.WaitSeconds)
    $tuid = [string](Get-ChatField $args0 'tool_use_id')
    $digest = Get-ChatqPermitDigest $rid $tool $raw
    $req = [ordered]@{
        v = 1; rid = $rid; run = $State.RunId; tool = $tool; inputRaw = $raw; toolUseId = $tuid
        at = $now.ToString('o'); until = $until.ToString('o'); digest = $digest
    }
    New-ChatqDir $State.Dir
    Save-ChatqJson (Join-Path $State.Dir "$rid.req.json") $req
    $State.Asked++
    $State.Pending[$rid] = @{
        Rid = $rid; Id = $IdRaw; Tool = $tool; InputRaw = $raw; Digest = $digest; At = $now; Until = $until; ToolUseId = $tuid
        Aid = $null; SentSeen = $false; AnsStamp = $null
    }
    $State.ById[$IdRaw] = $rid
    Write-ChatqPermitLog "bridge: $rid $tool asked ($tuid), until $($until.ToLocalTime().ToString('HH:mm:ss'))"
    return $null
}

function Test-ChatqPermitAnswer {
    <#
    The phone's answer, as the watcher wrote it: the message the phone
    posted, opened here with the phone's key as it is now. @{ Verdict; Note;
    Why }: allow and refuse only when it verifies - the act, the aid the
    watcher sent the request under, this request's own digest, a time
    between the ask and the deadline (a minute's slack each side), and a
    nonce and aid not taken before in this run. A refuse that does not
    verify still refuses, with no note: a forged file can only ever deny.
    Anything else is 'wait', and the deadline decides.
    #>
    param($Req, $Ans, [byte[]]$Master, $State)
    $r = [pscustomobject]@{ Verdict = 'wait'; Note = $null; Why = $null }
    $claims = [string](Get-ChatField $Ans 'act')
    $fail = {
        param($w)
        $r.Why = $w
        if ($claims -eq 'refuse') { $r.Verdict = 'refuse-unverified' }
        return $r
    }
    $v = Unprotect-ChatqReplyMessage ([string](Get-ChatField $Ans 'raw')) $Master
    if (-not $v.Ok) { return (& $fail "not sealed by the phone ($($v.Stage): $($v.Error))") }
    $pl = $v.Payload
    $act = [string]$pl.act
    if ($act -notin 'permit', 'refuse') { return (& $fail "act $act") }
    $claims = $act
    if (-not $Req.Aid -or $v.Aid -cne $Req.Aid) { return (& $fail 'another alert''s answer') }
    if ([string]$pl.h -cne $Req.Digest) { return (& $fail 'another request''s digest') }
    $ts = $pl.ts -as [double]
    $lo = [DateTimeOffset]::new($Req.At).ToUnixTimeMilliseconds() - 60000
    $hi = [DateTimeOffset]::new($Req.Until).ToUnixTimeMilliseconds() + 60000
    if ($null -eq $ts -or $ts -lt $lo -or $ts -gt $hi) { return (& $fail 'sent outside the request''s time') }
    $nonce = [string]$pl.nonce
    if (-not $nonce -or $State.Nonces.ContainsKey($nonce)) { return (& $fail 'a nonce used before') }
    if ($State.Aids.ContainsKey($v.Aid)) { return (& $fail 'an alert answered before') }
    $State.Nonces[$nonce] = $true
    $State.Aids[$v.Aid] = $true
    if ($act -eq 'permit') { $r.Verdict = 'allow'; return $r }
    $note = (([string]$pl.text) -replace '[\p{Cc}\p{Cf}]', ' ').Trim()
    if ($note.Length -gt 500) {
        $n = 500
        if ([char]::IsHighSurrogate($note[$n - 1])) { $n-- }
        $note = $note.Substring(0, $n)
    }
    $r.Verdict = 'refuse'
    $r.Note = $(if ($note) { $note } else { $null })
    return $r
}

function Update-ChatqPermitPending {
    # Each request still waiting: the watcher's word on it (sent, or
    # declined), the phone's answer, and the deadline - answered here, in
    # whatever order they settle.
    param($State)
    $now = (Get-Date).ToUniversalTime()
    foreach ($rid in @($State.Pending.Keys)) {
        $p = $State.Pending[$rid]
        $say = $null
        $allow = $false
        $mark = $null
        try {
            $sentPath = Join-Path $State.Dir "$rid.sent.json"
            if (-not $p.SentSeen -and (Test-Path -LiteralPath $sentPath)) {
                $s = Read-ChatqJson $sentPath
                if ($s) {
                    $p.SentSeen = $true
                    $dec = [string](Get-ChatField $s 'declined')
                    if ($dec) {
                        $say = "Nobody can approve this right now: $dec. Do not retry it; finish what you can without it and say what is left."
                        $mark = 'declined'
                    }
                    else { $p.Aid = [string](Get-ChatField $s 'aid') }
                }
            }
            $ansPath = Join-Path $State.Dir "$rid.ans.json"
            if (-not $say -and (Test-Path -LiteralPath $ansPath)) {
                $stamp = [System.IO.File]::GetLastWriteTimeUtc($ansPath).Ticks
                if ($stamp -ne $p.AnsStamp) {
                    $p.AnsStamp = $stamp
                    $a = Read-ChatqJson $ansPath
                    if ($a) {
                        $master = (Get-ChatqReplyConfig).Master
                        $t = Test-ChatqPermitAnswer $p $a $master $State
                        switch ($t.Verdict) {
                            'allow' { $allow = $true; $mark = 'allowed' }
                            'refuse' {
                                $say = "The user denied this from their phone. Do not retry it.$(if ($t.Note) { " Their note: ""$($t.Note)""" })"
                                $mark = 'refused'
                            }
                            'refuse-unverified' { $say = 'The user denied this from their phone. Do not retry it.'; $mark = 'refused' }
                            default { Write-ChatqPermitLog "bridge: $rid an answer that does not hold - $($t.Why); still waiting" }
                        }
                    }
                }
            }
            if (-not $allow -and -not $say -and $now -gt $p.Until) {
                $mins = [Math]::Max(1, [int][Math]::Round($State.WaitSeconds / 60))
                $say = "Nobody approved this on the phone within $mins minute$(if ($mins -ne 1) { 's' }), so it was denied. Do not retry it; finish what you can without it and say what is left."
                $mark = 'timeout'
                $State.Missed = $true
            }
        }
        catch {
            Write-ChatqPermitLog "bridge: $rid - $($_.Exception.Message)"
            $say = "chatq's permission bridge failed - denied"
            $mark = 'failed'
        }
        if (-not $allow -and -not $say) { continue }
        $State.Pending.Remove($rid)
        $State.ById.Remove($p.Id)
        Write-ChatqMcpMessage $State $(if ($allow) { New-ChatqPermitVerdict $p.Id -Allow } else { New-ChatqPermitVerdict $p.Id -Message $say })
        $fields = @{ answer = $mark }
        if ($mark -eq 'timeout') { $fields['timedOut'] = $true }
        Update-ChatqPermitRequestFile $State $rid $fields
        Write-ChatqPermitLog "bridge: $rid $($p.Tool) $mark"
    }
}

function Start-ChatqPermitBridge {
    <#
    The bridge itself: claude's stdio MCP server for one run, started by
    claude from mcp.json. Reads JSON-RPC lines on stdin in 250 ms steps,
    looks at every waiting request between them, and exits 0 when stdin
    closes (claude done or gone). Its answers are the only thing on stdout.
    -WaitSeconds is the tests' short deadline.
    #>
    param([string]$JobId, [string]$RunId, [int]$WaitSeconds = 0)
    Set-StrictMode -Off
    $t0 = Get-Date
    $State = New-ChatqPermitBridgeState -JobId $JobId -RunId $RunId -WaitSeconds $WaitSeconds
    $u = New-Object System.Text.UTF8Encoding $false
    $State.Out = [Console]::OpenStandardOutput()
    $State.Reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), $u, $false)
    $State.Task = $null
    Write-ChatqPermitLog ("bridge: up for job $JobId run $RunId in $([int]((Get-Date) - $t0).TotalMilliseconds) ms since the call - " +
        "PowerShell $($PSVersionTable.PSVersion) $($PSVersionTable.PSEdition), SystemRoot $(if ($env:SystemRoot) { 'set' } else { 'missing' }), wait $($State.WaitSeconds) s")
    while ($true) {
        $line = $null
        try { $line = Read-ChatqMcpLine $State }
        catch { Write-ChatqPermitLog "bridge: stdin failed - $($_.Exception.Message)"; break }
        if ($line -is [System.DBNull]) { break }
        if ($line -and $line.Trim()) {
            try {
                $reply = Invoke-ChatqMcpRequest $line $State
                if ($reply) { Write-ChatqMcpMessage $State $reply }
            }
            catch { Write-ChatqPermitLog "bridge: $($_.Exception.Message)" }
        }
        try { Update-ChatqPermitPending $State } catch { Write-ChatqPermitLog "bridge: $($_.Exception.Message)" }
    }
    Write-ChatqPermitLog "bridge: stdin closed - leaving ($($State.Pending.Count) still waiting)"
    return 0
}

#endregion

#region permit: the watcher's side ------------------------------------------------

function Hide-ChatqSecrets {
    <#
    A guard for the screen, not a security boundary - the card is sealed
    for the phone anyway: what looks like a secret becomes ***. The value
    after a key word (token=, password:, Bearer ...), a flag's value, a
    URL's user info, known token prefixes, and a long run of letters and
    digits - but not a commit id, pure hex of 7 to 40.
    #>
    param([string]$Text)
    if (-not $Text) { return $Text }
    $t = [regex]::Replace($Text, '(?i)\b(bearer)(\s+)\S+', '$1$2***')
    $t = [regex]::Replace($t, '(?i)(?<k>\b\w*(?:pass(?:word|wd)?|pwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|auth(?:orization)?|cookie|session)\w*\b(?:\s*[:=]\s*|\s+))(?<v>"[^"]*"|''[^'']*''|\S+)', {
            param($m)
            if ($m.Groups['v'].Value -eq '***') { return $m.Value }
            return $m.Groups['k'].Value + '***'
        })
    $t = [regex]::Replace($t, '(?i)(--?(?:password|passwd|token|secret|api-?key)(?:=|\s+))\S+', '$1***')
    $t = [regex]::Replace($t, '(?i)([a-z][a-z0-9+.-]*://)[^/\s:@]+:[^/\s@]+@', '$1***@')
    $t = [regex]::Replace($t, '(?<![A-Za-z0-9_])(sk-|ghp_|gho_|github_pat_|xoxb-|xoxp-|AKIA|AIza|glpat-)\S+', '$1***')
    $t = [regex]::Replace($t, '[A-Za-z0-9_-]{32,}', {
            param($m)
            $s = $m.Value
            if ($s -match '^[0-9a-fA-F]{7,40}$') { return $s }
            if ($s -match '[A-Za-z]' -and $s -match '[0-9]') { return '***' }
            return $s
        })
    return $t
}

function Get-ChatqPermitCut {
    # at most $Max characters, never through the middle of a surrogate pair
    param([string]$Text, [int]$Max)
    if (-not $Text -or $Text.Length -le $Max) { return $Text }
    $n = $Max
    if ($n -gt 0 -and [char]::IsHighSurrogate($Text[$n - 1])) { $n-- }
    return $Text.Substring(0, $n) + $script:ChatqEllipsis
}

function Get-ChatqPermitExcerpt {
    <#
    What the phone shows of a request: @{ What; Detail }. The command, its
    first 8 lines and 400 characters; for an edit the path within the chat's
    folder, how many lines it replaces and the new text's start; for a write
    whether it is new, its size and its start; a URL; else the input as
    compact JSON. Redacted (Hide-ChatqSecrets) either way.
    #>
    param([string]$Tool, $ToolInput, [string]$Cwd)
    $g = { param($n) Get-ChatField $ToolInput $n }
    $rel = {
        param($p)
        $p = [string]$p
        if ($Cwd -and $p) {
            $c = $Cwd.Replace('/', '\').TrimEnd('\') + '\'
            $x = $p.Replace('/', '\')
            if ($x.StartsWith($c, [StringComparison]::OrdinalIgnoreCase)) { return $x.Substring($c.Length) }
        }
        return $p
    }
    $lines = { param($s) if (-not $s) { 0 } else { @(([string]$s) -split "`r?`n").Count } }
    $what = ''
    $detail = ''
    switch -Exact ($Tool) {
        { $_ -in 'Bash', 'PowerShell' } {
            $cmd = [string](& $g 'command')
            $ls = @($cmd -split "`r?`n")
            $what = ($ls | Select-Object -First 8) -join "`n"
            if ($ls.Count -gt 8) { $what += "`n" + $script:ChatqEllipsis }
            $what = Get-ChatqPermitCut $what 400
            $detail = Get-ChatqPermitCut ([string](& $g 'description')) 80
            break
        }
        { $_ -in 'Edit', 'MultiEdit' } {
            $edits = if ($Tool -eq 'MultiEdit') { @(& $g 'edits') } else { @($ToolInput) }
            $old = 0; $new = 0; $first = $null
            foreach ($e in $edits) {
                $old += & $lines (Get-ChatField $e 'old_string')
                $new += & $lines (Get-ChatField $e 'new_string')
                if ($null -eq $first) { $first = [string](Get-ChatField $e 'new_string') }
            }
            $what = "$(& $rel (& $g 'file_path'))`nreplaces $old line$(if ($old -ne 1) { 's' }) with $new`n$(Get-ChatqPermitCut $first 200)"
            break
        }
        'Write' {
            $p = [string](& $g 'file_path')
            $c = [string](& $g 'content')
            $n = & $lines $c
            $kb = (New-Object System.Text.UTF8Encoding $false).GetByteCount($c) / 1KB
            $size = if ($kb -ge 1) { '{0:0.0} KB' -f $kb } else { "$((New-Object System.Text.UTF8Encoding $false).GetByteCount($c)) bytes" }
            $isNew = -not ($p -and (Test-Path -LiteralPath $p))
            $what = "$(& $rel $p)`n$(if ($isNew) { 'new file' } else { 'overwrites' }), $n line$(if ($n -ne 1) { 's' }), $size`n$(Get-ChatqPermitCut $c 200)"
            break
        }
        'NotebookEdit' {
            $cell = if (& $g 'cell_id') { "cell $(& $g 'cell_id')" } elseif ($null -ne (& $g 'cell_number')) { "cell $(& $g 'cell_number')" } else { 'a cell' }
            $mode = [string](& $g 'edit_mode')
            $what = "$(& $rel (& $g 'notebook_path'))`n$cell$(if ($mode) { ", $mode" })"
            break
        }
        'WebFetch' {
            $what = Get-ChatqPermitCut ([string](& $g 'url')) 400
            $detail = Get-ChatqPermitCut ([string](& $g 'prompt')) 100
            break
        }
        default {
            $what = Get-ChatqPermitCut ($ToolInput | ConvertTo-Json -Compress -Depth 6) 300
        }
    }
    [pscustomobject]@{ What = (Hide-ChatqSecrets $what); Detail = (Hide-ChatqSecrets $detail) }
}

function Get-ChatqPermitCardKeys {
    # the card's own keys: from the phone's key D and the alert's id, as the
    # reply's are, but under "chatq-card:" - the direction PC to phone gets
    # keys of its own
    param([byte[]]$Master, [string]$Aid)
    $k = Get-ChatqHmac $Master ((New-Object System.Text.UTF8Encoding $false).GetBytes("chatq-card:$Aid"))
    return (Get-ChatqReplyKeys -K $k)
}

function Protect-ChatqPermitCard {
    <#
    Seal what the phone shows of a request for the phone alone: AES-256-CBC
    and an HMAC over it, under keys from the phone's key and the alert's id.
    "chatq1c." + aid + "." + b64url(iv) + "." + b64url(ciphertext) + "." +
    b64url(mac). Neither Join nor ntfy can read or change it. -Iv fixes it
    for the test vector.
    #>
    param([byte[]]$Master, [string]$Aid, [string]$Card, [byte[]]$Iv)
    $u = New-Object System.Text.UTF8Encoding $false
    $ks = Get-ChatqPermitCardKeys $Master $Aid
    if (-not $Iv) { $Iv = New-ChatqRandomBytes 16 }
    $ct = Invoke-ChatqAes $ks.Enc $Iv ($u.GetBytes($Card)) -Encrypt
    $head = 'chatq1c.' + $Aid + '.' + (ConvertTo-ChatqB64Url $Iv) + '.' + (ConvertTo-ChatqB64Url $ct)
    return $head + '.' + (ConvertTo-ChatqB64Url (Get-ChatqHmac $ks.Mac ($u.GetBytes($head))))
}

function Unprotect-ChatqPermitCard {
    # the tests' way back into a card: @{ Ok; Json; Payload }, the MAC first
    param([string]$Card, [byte[]]$Master)
    $r = [pscustomobject]@{ Ok = $false; Json = $null; Payload = $null }
    $p = @(([string]$Card) -split '\.')
    if ($p.Count -ne 5 -or $p[0] -cne 'chatq1c' -or $p[1] -cnotmatch '^[a-z2-7]{10}$') { return $r }
    $iv = ConvertFrom-ChatqB64Url $p[2]; $ct = ConvertFrom-ChatqB64Url $p[3]; $mac = ConvertFrom-ChatqB64Url $p[4]
    if ($null -eq $iv -or $iv.Length -ne 16 -or $null -eq $ct -or -not $ct.Length -or ($ct.Length % 16) -or $null -eq $mac) { return $r }
    $u = New-Object System.Text.UTF8Encoding $false
    $ks = Get-ChatqPermitCardKeys $Master $p[1]
    if (-not (Test-ChatqSameBytes (Get-ChatqHmac $ks.Mac ($u.GetBytes(($p[0..3] -join '.')))) $mac)) { return $r }
    try { $r.Json = (New-Object System.Text.UTF8Encoding $false, $true).GetString((Invoke-ChatqAes $ks.Enc $iv $ct)); $r.Payload = $r.Json | ConvertFrom-Json; $r.Ok = $true } catch {}
    return $r
}

function New-ChatqPermitCardJson {
    <#
    The card's plaintext: tool, what (w), Claude's own description (d), the
    folder, the chat's title, the job's number, the digest the answer must
    name (h) and the deadline in epoch ms (u). At most 600 bytes of UTF-8,
    w shrinking first, so the sealed card stays under ~950 characters and
    Join's URL under 1900.
    #>
    param([string]$Tool, $Excerpt, $Job, [string]$Digest, [datetime]$Until)
    $u8 = New-Object System.Text.UTF8Encoding $false
    $w = [string]$Excerpt.What
    $d = [string]$Excerpt.Detail
    $c = [string](Get-ChatField $Job 'title')
    if ($c.Length -gt 60) { $c = Get-ChatqPermitCut $c 59 }
    $f = if ($Job.cwd) { Split-Path ([string]$Job.cwd).TrimEnd('\', '/') -Leaf } else { '' }
    $ms = [DateTimeOffset]::new($Until.ToUniversalTime()).ToUnixTimeMilliseconds()
    for ($round = 0; $round -lt 200; $round++) {
        $o = [ordered]@{ v = 1; t = $Tool; w = $w; d = $d; f = $f; c = $c; n = [int](Get-ChatField $Job 'seq'); h = $Digest; u = $ms }
        $json = $o | ConvertTo-Json -Compress
        if ($u8.GetByteCount($json) -le 600) { return $json }
        if ($w.Length -gt 1) { $w = Get-ChatqPermitCut $w.TrimEnd($script:ChatqEllipsis) ([int]($w.Length * 0.8)); continue }
        if ($d.Length -gt 1) { $d = Get-ChatqPermitCut $d.TrimEnd($script:ChatqEllipsis) ([int]($d.Length * 0.7)); continue }
        if ($c.Length -gt 1) { $c = Get-ChatqPermitCut $c.TrimEnd($script:ChatqEllipsis) ([int]($c.Length * 0.7)); continue }
        return $json
    }
    return $json
}

function Get-ChatqPermitPushText {
    # the push names the chat and the kind of call, never the command: Join
    # logs its GETs, and an ntfy alert topic may be read by others
    param([string]$Tool, $Job, [datetime]$Until)
    $d = $script:ChatqDot
    $what = switch -Exact ($Tool) {
        'Bash' { 'asks to run a command'; break }
        'PowerShell' { 'asks to run a command'; break }
        'Edit' { 'asks to edit a file'; break }
        'MultiEdit' { 'asks to edit a file'; break }
        'Write' { 'asks to write a file'; break }
        'WebFetch' { 'asks to fetch a web page'; break }
        default { "asks to use $Tool" }
    }
    return "$($Job.title) $d #$($Job.seq) $what - tap to see it and answer by $($Until.ToLocalTime().ToString('HH:mm'))"
}

function Send-ChatqPermitAlert {
    <#
    One request to the phone: the "permission" push, priority 2 and -Loud
    (a headless run has no window to ask in), its card sealed into the link
    under the alert's own id, the registry entry holding what the answer
    must match. @{ Sent; Aid; Error }.
    #>
    param($Job, $Req, $Run)
    $tool = [string]$Req.tool
    $inObj = try { [string]$Req.inputRaw | ConvertFrom-Json } catch { $null }
    $until = ConvertTo-ChatqDate $Req.until
    $ex = Get-ChatqPermitExcerpt $tool $inObj ([string]$Job.cwd)
    $card = New-ChatqPermitCardJson $tool $ex $Job ([string]$Req.digest) $until
    $text = Get-ChatqPermitPushText $tool $Job $until
    $permit = @{
        run = [string]$Req.run; rid = [string]$Req.rid; digest = [string]$Req.digest; until = $until.ToUniversalTime().ToString('o')
        state = 'open'; tool = $tool; toolUseId = [string]$Req.toolUseId; asked = (Get-ChatqStamp); answeredAt = $null
    }
    $script:ChatqLastAlertAid = $null
    $sent = Send-ChatqAlert 'permission' $text 2 -Loud -Quick -Job $Job -Card $card -Permit $permit -Tag "chatq-p-$($Req.rid)" -ToastText "$text (answer on the phone)"
    $aid = $script:ChatqLastAlertAid
    if ($sent -and $aid) { return [pscustomobject]@{ Sent = $true; Aid = $aid; Error = $null } }
    $err = if (-not $sent) { [string]$script:ChatqLastAlertError } else { 'the alert could not be registered' }
    if (-not $err) { $err = 'the push did not go' }
    return [pscustomobject]@{ Sent = $false; Aid = $aid; Error = $err }
}

function Write-ChatqPermitLine {
    # every answer and decline, one line in data/logs/replies.log
    param([string]$Rid, $Job, [string]$Tool, [string]$What)
    Write-ChatqReplyLog "permit $Rid #$(Get-ChatField $Job 'seq') ${Tool}: $What"
}

function Test-ChatqPermitHourly {
    # fewer than 20 permission pushes from this process in the last hour
    $cut = (Get-Date).AddHours(-1)
    for ($i = $script:ChatqPermitAsked.Count - 1; $i -ge 0; $i--) { if ($script:ChatqPermitAsked[$i] -lt $cut) { $script:ChatqPermitAsked.RemoveAt($i) } }
    return ($script:ChatqPermitAsked.Count -lt 20)
}

function Set-ChatqPermitEntry {
    # a permission alert's registry entry moved on (timeout, gone) when it
    # is still open; $true when it was
    param([string]$Rid, [string]$State)
    try {
        return [bool](Use-ChatqReplyState {
                param($st)
                $hit = $false
                foreach ($k in @($st.alerts.Keys)) {
                    $pe = $st.alerts[$k]['permit']
                    if ($pe -and [string]$pe.rid -ceq $Rid -and $pe.state -eq 'open') { $pe.state = $State; $hit = $true }
                }
                $hit
            })
    }
    catch { return $false }
}

function Update-ChatqPermitRequests {
    <#
    The watcher's tick, first thing, while a run can ask: each new request
    the bridge wrote is checked - this run's, a deadline no further than
    permit.waitMinutes, a tool call the stream really showed (within 10 s),
    still ready, 20 an hour - and sent to the phone, or declined. A request
    past its deadline is marked so in the registry. $true while any request
    is open: the reply topic is then polled every 5 s. Never throws.
    #>
    param($Job, $Run)
    try {
        if (-not $Run -or -not (Test-Path -LiteralPath $Run.Dir)) { return $false }
        $now = Get-Date
        foreach ($f in @(Get-ChildItem -LiteralPath $Run.Dir -Filter '*.req.json' -File -EA SilentlyContinue)) {
            $rid = $f.Name.Substring(0, $f.Name.Length - '.req.json'.Length)
            $seen = $Run.Seen[$rid]
            if ($seen -and $seen.Done) { continue }
            $req = Read-ChatqJson $f.FullName
            if (-not $req) { continue }
            if (-not $seen) { $seen = @{ First = $now; Done = $false }; $Run.Seen[$rid] = $seen }
            $tool = [string]$req.tool
            $decline = {
                param($why)
                $seen.Done = $true
                try { Save-ChatqJson (Join-Path $Run.Dir "$rid.sent.json") ([ordered]@{ v = 1; rid = $rid; declined = $why; at = (Get-ChatqStamp) }) } catch {}
                Write-ChatqPermitLine $rid $Job $tool "declined $why"
            }
            $until = ConvertTo-ChatqDate $req.until
            if ([string]$req.rid -cne $rid -or [string]$req.run -cne $Run.RunId -or -not $until -or $until -gt $now.AddMinutes($Run.WaitMinutes).AddSeconds(30)) {
                & $decline 'not a request of this run''s'
                continue
            }
            # the tool call behind it, as the stream showed it: the model
            # calling decide itself would push a made-up request otherwise
            $tuid = [string]$req.toolUseId
            $known = if ($Run.St -and $Run.St.ToolIds -and $tuid) { $Run.St.ToolIds[$tuid] } else { $null }
            if (-not $known -or $known -ne $tool -or $tool -eq $script:ChatqPermitTool) {
                if (($now - $seen.First).TotalSeconds -lt 10 -and -not ($known -and $known -ne $tool)) { continue }
                & $decline 'not a tool call of this run''s'
                continue
            }
            $cfg = Get-ChatqConfig
            $ready = Test-ChatqPermitReady $cfg $Job
            if (-not $ready.Ok) { & $decline $ready.Why; continue }
            if (-not (Test-ChatqPermitHourly)) { & $decline '20 permission alerts went out in the last hour'; continue }
            $script:ChatqPermitAsked.Add($now)
            $r = Send-ChatqPermitAlert $Job $req $Run
            if (-not $r.Sent) { & $decline "could not reach the phone - $($r.Error)"; continue }
            $seen.Done = $true
            Save-ChatqJson (Join-Path $Run.Dir "$rid.sent.json") ([ordered]@{ v = 1; rid = $rid; aid = $r.Aid; until = $until.ToUniversalTime().ToString('o'); at = (Get-ChatqStamp) })
            $Run.Open[$rid] = @{ Until = $until; Tool = $tool }
            Set-ChatqProp $Job 'permitWaiting' ([pscustomobject]@{ tool = $tool; until = $until.ToUniversalTime().ToString('o') })
            Save-ChatqJob $Job
            Write-ChatqPermitLine $rid $Job $tool "asked, alert $($r.Aid), until $($until.ToString('HH:mm'))"
        }
        # the open ones: answered (the bridge marks the file) or run out
        foreach ($rid in @($Run.Open.Keys)) {
            $o = $Run.Open[$rid]
            $rq = Read-ChatqJson (Join-Path $Run.Dir "$rid.req.json")
            $answer = if ($rq) { [string](Get-ChatField $rq 'answer') } else { '' }
            if ($answer -or $now -gt $o.Until) {
                $Run.Open.Remove($rid)
                if ($now -gt $o.Until -and $answer -notin 'allowed', 'refused') {
                    if (Set-ChatqPermitEntry $rid 'timeout') { Write-ChatqPermitLine $rid $Job $o.Tool 'timeout' }
                }
            }
        }
        if (-not $Run.Open.Count -and (Get-ChatField $Job 'permitWaiting')) { Set-ChatqProp $Job 'permitWaiting' $null; Save-ChatqJob $Job }
        return [bool]$Run.Open.Count
    }
    catch {
        Write-ChatqWatchLog "#$($Job.seq) permit: $($_.Exception.Message)"
        return $false
    }
}

function Close-ChatqPermitRun {
    <#
    The run is over: every entry of this run still open is timeout, or gone
    when it ended first, and the folder goes. Returns the tool_use ids the
    phone refused (Refused) and the ones nobody answered (NoAnswer), which
    Get-ChatqClaudeOutcome reads the run's denials by.
    #>
    param($Job, $Run)
    $out = [pscustomobject]@{ Refused = @(); NoAnswer = @() }
    if (-not $Run) { return $out }
    $refused = [System.Collections.Generic.List[string]]::new()
    $late = [System.Collections.Generic.List[string]]::new()
    $runId = $Run.RunId
    try {
        $gone = Use-ChatqReplyState {
            param($st)
            $now = (Get-Date).ToUniversalTime()
            $moved = @()
            foreach ($k in @($st.alerts.Keys)) {
                $pe = $st.alerts[$k]['permit']
                if (-not $pe -or [string]$pe.run -cne $runId) { continue }
                if ($pe.state -eq 'open') {
                    $u = ConvertTo-ChatqDate $pe.until
                    $pe.state = if ($u -and $u.ToUniversalTime() -lt $now) { 'timeout' } else { 'gone' }
                    $moved += "$($pe.rid) $($pe.state)"
                }
                if ($pe.state -eq 'refused' -and $pe.toolUseId) { $refused.Add([string]$pe.toolUseId) }
                if ($pe.state -eq 'timeout' -and $pe.toolUseId) { $late.Add([string]$pe.toolUseId) }
            }
            $moved
        }
        foreach ($g in @($gone)) { if ($g) { $p = $g -split ' '; Write-ChatqPermitLine $p[0] $Job '' $p[1] } }
    }
    catch { Write-ChatqWatchLog "#$($Job.seq) permit: $($_.Exception.Message)" }
    try { if (Test-Path -LiteralPath $Run.Dir) { Remove-Item -LiteralPath $Run.Dir -Recurse -Force -EA SilentlyContinue } } catch {}
    if (Get-ChatField $Job 'permitWaiting') { Set-ChatqProp $Job 'permitWaiting' $null }
    $out.Refused = $refused.ToArray()
    $out.NoAnswer = $late.ToArray()
    return $out
}

function Remove-ChatqPermitLeftovers {
    # data/permit/<jobId> of a job that is not running - a watcher that died
    # mid-run - goes, and so does whatever of its alerts is still open
    try {
        if (-not (Test-Path -LiteralPath $script:ChatqPermitDir)) { return }
        $running = @{}
        foreach ($j in @(Get-ChatqJobs | Where-Object { $_.state -eq 'running' })) { $running[[string]$j.id] = [string](Get-ChatField $j 'runId') }
        foreach ($d in @(Get-ChildItem -LiteralPath $script:ChatqPermitDir -Directory -EA SilentlyContinue)) {
            if ($running.ContainsKey($d.Name)) { continue }
            Remove-Item -LiteralPath $d.FullName -Recurse -Force -EA SilentlyContinue
        }
        if (-not (Test-Path -LiteralPath $script:ChatqReplyPath)) { return }
        $null = Use-ChatqReplyState {
            param($st)
            foreach ($k in @($st.alerts.Keys)) {
                $pe = $st.alerts[$k]['permit']
                if ($pe -and $pe.state -eq 'open' -and -not ($running.Values -contains [string]$pe.run)) { $pe.state = 'gone' }
            }
        }
    }
    catch {}
}

function Write-ChatqPermitAnswer {
    # the phone's answer handed to the bridge, as it was posted: the bridge
    # opens it again itself, so this file proves nothing on its own
    param([string]$JobId, [string]$Rid, [string]$Aid, [string]$Act, [string]$Raw)
    $p = Join-Path (Join-Path $script:ChatqPermitDir $JobId) "$Rid.ans.json"
    Save-ChatqJson $p ([ordered]@{ v = 1; rid = $Rid; aid = $Aid; act = $Act; raw = $Raw; at = (Get-ChatqStamp) })
}

function Invoke-ChatqPermitReply {
    <#
    A verified permit or refuse from the phone (Invoke-ChatqReply): the
    alert must ask for a permission still open, before its deadline, for a
    job still running this very run whose request is still there, and a
    permit must name the request as it was shown (h). Then the answer goes
    to the bridge, the entry is closed - the first answer wins - and the
    words for the push come back.
    #>
    param([string]$Act, $Payload, $Entry, [string]$Aid, [string]$Raw)
    $verb = if ($Act -eq 'permit') { 'allow' } else { 'deny' }
    $p = Get-ChatField $Entry 'permit'
    if (-not $p) { return "that alert asks for no permission - nothing to $verb" }
    $jobId = [string](Get-ChatField $Entry 'jobId')
    $h = [string](Get-ChatField $Payload 'h')
    $note = [bool]([string](Get-ChatField $Payload 'text')).Trim()
    $hhmm = { param($s) $x = ConvertTo-ChatqDate $s; if ($x) { $x.ToLocalTime().ToString('HH:mm') } else { '?' } }
    try {
        $res = Use-ChatqReplyState {
            param($st)
            $e = $st.alerts[$Aid]
            $pe = if ($e) { $e['permit'] } else { $null }
            if (-not $pe) { return @{ Say = "that alert asks for no permission - nothing to $verb" } }
            switch ($pe.state) {
                'allowed' { return @{ Say = "already answered - allowed at $(& $hhmm $pe.answeredAt)" } }
                'refused' { return @{ Say = "already answered - denied at $(& $hhmm $pe.answeredAt)" } }
                'timeout' { return @{ Say = "too late - at $(& $hhmm $pe.until) nobody had answered, so Claude was told no" } }
                'gone' { return @{ Say = "that run is over - nothing to $verb" } }
            }
            $u = ConvertTo-ChatqDate $pe.until
            if (-not $u -or $u -lt (Get-Date)) {
                $pe.state = 'timeout'
                return @{ Say = "too late - at $(& $hhmm $pe.until) nobody had answered, so Claude was told no"; Log = 'timeout' }
            }
            if ($Act -eq 'permit' -and $h -cne [string]$pe.digest) {
                return @{ Say = 'the request changed after it was shown - nothing allowed'; Log = 'declined the answer names another request' }
            }
            $job = if ($jobId) { Find-ChatqJob $jobId } else { $null }
            $req = Join-Path (Join-Path $script:ChatqPermitDir $jobId) "$($pe.rid).req.json"
            if (-not $job -or $job.state -ne 'running' -or [string](Get-ChatField $job 'runId') -cne [string]$pe.run -or -not (Test-Path -LiteralPath $req)) {
                $pe.state = 'gone'
                return @{ Say = "that run is over - nothing to $verb"; Log = 'gone' }
            }
            # the answer is on disk before the entry says answered: a failed
            # write saves nothing, and the phone can answer again
            Write-ChatqPermitAnswer $jobId ([string]$pe.rid) $Aid $Act $Raw
            $pe.state = if ($Act -eq 'permit') { 'allowed' } else { 'refused' }
            $pe.answeredAt = Get-ChatqStamp
            $n = if ($job) { "#$($job.seq)" } else { 'the job' }
            $say = if ($Act -eq 'permit') { "allowed - $($pe.tool) for $n, the run goes on" } else { "denied - $($pe.tool) for $n; Claude was told$(if ($note) { ' (with your note)' })" }
            return @{ Say = $say; Log = $pe.state }
        }
    }
    catch {
        Write-ChatqReplyLog "permit: the answer could not be saved - $($_.Exception.Message)"
        return 'that answer could not be handed on - try again'
    }
    if ($res.Log) { Write-ChatqReplyLog "permit $($p.rid) #$($Entry.seq) $($p.tool): $($res.Log)" }
    return $res.Say
}

function Get-ChatqPermitWaitText {
    # " - asks the phone: Bash, until 10:17" for a running job that waits
    # on the phone, else ''
    param($Job)
    $w = Get-ChatField $Job 'permitWaiting'
    if (-not $w) { return '' }
    $u = ConvertTo-ChatqDate (Get-ChatField $w 'until')
    if (-not $u -or $u -lt (Get-Date)) { return '' }
    return " $($script:ChatqDot) asks the phone: $(Get-ChatField $w 'tool'), until $($u.ToLocalTime().ToString('HH:mm'))"
}

function Test-ChatqPermitStartFailed {
    # did the run fail because the bridge never came up? The run's own
    # words are the only sign (S35 item 3): its error names the server or
    # the permission prompt tool, and nothing was ever asked
    param($Out, [string]$StdErr)
    if (-not $Out -or $Out.kind -ne 'failed') { return $false }
    $t = "$($Out.reason) $StdErr"
    return [bool]($t -match '(?i)chatqpermit|permission[ -]prompt[ -]tool')
}

#endregion
