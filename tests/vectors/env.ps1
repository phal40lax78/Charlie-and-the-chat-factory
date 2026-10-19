# tests/vectors/env.ps1: native/vectors/env.json (native/SPEC.md 2.5, 2.6,
# 6.1). The environment a run's CLI gets: $script:ChatqEnvDrop and
# $script:ChatqRunEnv as they stand (src/queue.ps1); the -SetEnv delta
# Invoke-ChatqRun builds for a job and a parent environment, and the block
# the real New-ChatqProcessStartInfo then hands CreateProcess; and that
# block for a parent and a delta given outright. Read by
# native/crates/chatq-core/tests/env_vectors.rs.
#
# The parent is this process's environment for the call: each variable of
# this PC that a case names, or that the run code looks at, is put aside, the
# case's own are set, and all of it is put back in a finally. The block comes
# from .NET's own builder (5.1: EnvironmentBlock.ToByteArray; 7:
# Process.GetEnvironmentVariablesBlock), so its order is .NET's; only the
# case's names are kept from it, the rest of this PC's being no part of the
# answer. Names never differ only by case (Windows would take them for one),
# and no parent value is empty, which 5.1 cannot set.

function New-NvEnvDict($Pairs) {
    # [ordered]@{ name = value } from @(name, value, name, value ...): two
    # names Windows or a PowerShell dictionary would take for one refused
    $d = [ordered]@{}
    $ord = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $inv = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::InvariantCultureIgnoreCase)
    $list = @($Pairs)
    if ($list.Count % 2) { throw 'env pairs: a name without its value' }
    for ($i = 0; $i -lt $list.Count; $i += 2) {
        $n = [string]$list[$i]
        if (-not $n -or -not $ord.Add($n) -or -not $inv.Add($n) -or $d.Contains($n)) { throw "env name '$n' twice, or empty" }
        $d[$n] = $list[$i + 1]
    }
    return $d
}

function Get-NvEnvNames($Parent, $More) {
    # every name an answer keeps: the case's, the drop list, the run
    # settings, and the three a run sets
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($n in @($script:ChatqEnvDrop) + @($script:ChatqRunEnv.Keys) + @('CLAUDE_CONFIG_DIR', 'CODEX_HOME', 'MCP_TOOL_TIMEOUT')) { [void]$set.Add([string]$n) }
    foreach ($p in $Parent.PSObject.Properties) { [void]$set.Add($p.Name) }
    foreach ($n in @($More)) { if ($null -ne $n) { [void]$set.Add([string]$n) } }
    return , $set
}

function Enter-NvEnvParent($Parent, $Names) {
    # this process's environment with $Parent's variables for every name in
    # $Names: this PC's own put aside first. Returns what Exit-NvEnvParent
    # puts back.
    $aside = New-Object System.Collections.Generic.List[object]
    $real = [Environment]::GetEnvironmentVariables()
    foreach ($k in @($real.Keys)) {
        if ($Names.Contains([string]$k)) {
            $aside.Add(@([string]$k, [string]$real[$k]))
            [Environment]::SetEnvironmentVariable([string]$k, [NullString]::Value)
        }
    }
    $set = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($p in $Parent.PSObject.Properties) {
            $set.Add($p.Name)
            [Environment]::SetEnvironmentVariable($p.Name, [string]$p.Value)
        }
    }
    catch {
        Exit-NvEnvParent ([pscustomobject]@{ Aside = $aside; Set = $set })
        throw
    }
    return [pscustomobject]@{ Aside = $aside; Set = $set }
}

function Exit-NvEnvParent($Saved) {
    foreach ($n in $Saved.Set) { [Environment]::SetEnvironmentVariable($n, [NullString]::Value) }
    foreach ($a in $Saved.Aside) { [Environment]::SetEnvironmentVariable($a[0], $a[1]) }
}

function Get-NvEnvBlock($Psi, $Names) {
    # the block .NET builds for $Psi, in its order: the "name=value"
    # entries whose name is one of $Names
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $m = [System.Diagnostics.Process].GetMethod('GetEnvironmentVariablesBlock', [Reflection.BindingFlags]'NonPublic, Static')
        if (-not $m) { throw 'this .NET has no Process.GetEnvironmentVariablesBlock' }
        $text = [string]$m.Invoke($null, @(, $Psi.Environment))
    }
    else {
        $t = [System.Diagnostics.Process].Assembly.GetType('System.Diagnostics.EnvironmentBlock')
        $m = if ($t) { $t.GetMethod('ToByteArray', [Reflection.BindingFlags]'NonPublic, Public, Static') }
        if (-not $m) { throw 'this .NET Framework has no EnvironmentBlock.ToByteArray' }
        $text = [Text.Encoding]::Unicode.GetString([byte[]]$m.Invoke($null, @($Psi.EnvironmentVariables, $true)))
    }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($e in $text.Split([char]0)) {
        if (-not $e) { continue }
        $at = $e.IndexOf('=')
        if ($at -lt 1) { throw "an entry with no name: $e" }
        if ($Names.Contains($e.Substring(0, $at))) { $out.Add($e) }
    }
    return , $out.ToArray()
}

function Invoke-NvEnvRun($In, [string]$Case) {
    # Invoke-ChatqRun up to the CLI's start, with the case's parent as this
    # process's environment: the -SetEnv it built and the block the real
    # New-ChatqProcessStartInfo made of it. The stubs are this function's
    # own, so they go with it; its variables are named so that no function
    # they pass through has one of the same name.
    $envCaught = @{}
    $envStop = 'env vector: the CLI would start here'
    $envNames = Get-NvEnvNames $In.parent $null
    function Find-ChatqExe { param([string]$Provider) "$Provider.exe" }
    function Get-ChatqCliVersion { param([string]$Exe, [switch]$Fresh) '9.9.9' }
    function Invoke-ChatqProcess {
        param([string]$Exe, [string[]]$ArgList, [string]$WorkDir, [string]$StdIn, [hashtable]$SetEnv, [string]$LogPath,
            [scriptblock]$OnLine, [scriptblock]$OnTick, [int]$TimeoutSec = 14400)
        $envCaught['Delta'] = $SetEnv.Clone()
        $psi = New-ChatqProcessStartInfo -Exe $Exe -ArgList $ArgList -WorkDir $WorkDir -SetEnv $SetEnv
        $envCaught['Block'] = Get-NvEnvBlock $psi $envNames
        throw $envStop
    }
    $job = [pscustomobject]@{ id = 'j1'; seq = 1; provider = [string]$In.cli; kind = 'new'; path = $null
        sessionId = '00000000-0000-4000-8000-000000000001'; title = 'env vector'; mode = $null; modeAtQueue = $null
        runModel = $null; home = $In.home; cwd = $null; network = $false; sandbox = $null
    }
    $permit = $null
    if ($null -ne $In.bridge) {
        $permit = [pscustomobject]@{ McpPath = 'permit\mcp.json'; SettingsPath = 'permit\settings.json'; TimeoutMs = [int]$In.bridge; St = $null; Settings = @{} }
    }
    $null = Enter-NvData $Case
    $saved = Enter-NvEnvParent $In.parent $envNames
    try {
        try { $null = Invoke-ChatqRun $job 'x' $null $null -Permit $permit -Carry ([pscustomobject]@{ Ultracode = $false; Effort = $null }) }
        catch { if ($_.Exception.Message -cne $envStop) { throw } }
    }
    finally { Exit-NvEnvParent $saved }
    if (-not $envCaught.Contains('Block')) { throw 'Invoke-ChatqRun did not start the CLI' }
    return [ordered]@{ delta = $envCaught['Delta']; block = $envCaught['Block'] }
}

function Invoke-NvEnvBlock($In) {
    # New-ChatqProcessStartInfo with the case's parent as this process's
    # environment and its setEnv as -SetEnv
    $set = @{}
    foreach ($p in $In.setEnv.PSObject.Properties) { $set[$p.Name] = $p.Value }
    $names = Get-NvEnvNames $In.parent @($set.Keys)
    $saved = Enter-NvEnvParent $In.parent $names
    try {
        $psi = New-ChatqProcessStartInfo -Exe 'claude.exe' -ArgList @('-p') -WorkDir $null -SetEnv $set
        $block = Get-NvEnvBlock $psi $names
    }
    finally { Exit-NvEnvParent $saved }
    return [ordered]@{ block = $block }
}

Register-NvVector -Name 'env' -About 'The environment a run''s CLI gets (src/queue.ps1). drop: $script:ChatqEnvDrop. runEnv: $script:ChatqRunEnv in its order. run: Invoke-ChatqRun for {cli, home, bridge (the permit''s TimeoutMs, null for none), parent} -> {delta: its -SetEnv, null removing; block: the "name=value" entries New-ChatqProcessStartInfo''s block holds, in .NET''s order}. block: New-ChatqProcessStartInfo for {parent, setEnv} -> {block}. Only the case''s names and those the run code sets or drops are kept from a block' -Cases {
    [ordered]@{ name = 'drop list'; input = [ordered]@{ kind = 'drop' } }
    [ordered]@{ name = 'run settings'; input = [ordered]@{ kind = 'runEnv' } }
    $h = 'C:\homes\work\.claude'
    $everyDrop = @(foreach ($n in $script:ChatqEnvDrop) { $n; 'x' })
    $runs = @(
        @('claude, a home, nothing set', 'claude', $h, $null, @()),
        @('claude, no home', 'claude', $null, $null, @('CLAUDE_CONFIG_DIR', 'C:\elsewhere\.claude')),
        @('claude, an empty home', 'claude', '', $null, @('claude_config_dir', 'C:\elsewhere\.claude')),
        @('claude, a home over another casing', 'claude', $h, $null, @('Claude_Config_Dir', 'C:\old\.claude')),
        @('claude, the user''s own run settings stand', 'claude', $h, $null, @('BASH_MAX_TIMEOUT_MS', '60', 'bash_default_timeout_ms', '7')),
        @('claude, every run setting the user''s', 'claude', $h, $null, @('CLAUDE_CODE_DISABLE_BACKGROUND_TASKS', '0', 'BASH_MAX_TIMEOUT_MS', '1', 'BASH_DEFAULT_TIMEOUT_MS', '2', 'CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS', '3')),
        @('claude, a bridge', 'claude', $h, 780000, @()),
        @('claude, a bridge over the user''s timeout', 'claude', $h, 780000, @('MCP_TOOL_TIMEOUT', '5')),
        @('claude, a bridge over a lower case timeout', 'claude', $null, 60000, @('mcp_tool_timeout', '5')),
        @('claude, the session''s own dropped', 'claude', $h, $null, @('CLAUDECODE', '1', 'CLAUDE_CODE_ENTRYPOINT', 'cli', 'CLAUDE_CODE_SSE_PORT', '1234', 'MCP_CONNECTION_NONBLOCKING', 'true', 'ANTHROPIC_API_KEY', 'k1', 'openai_api_key', 'k2', 'Codex_Api_Key', 'k3', 'CLAUDE_CODE_OTHER', 'kept', 'ANTHROPIC_BASE_URL', 'kept too')),
        @('claude, every dropped name', 'claude', $h, $null, $everyDrop),
        @('claude, a home with an equals sign and hangul', 'claude', (U 'C:\\\uc0ac\uc6a9\uc790=1\\.claude'), $null, @()),
        @('codex, a home', 'codex', 'C:\homes\codex', $null, @('CODEX_HOME', 'C:\old\codex')),
        @('codex, no home', 'codex', $null, $null, @('codex_home', 'C:\old\codex', 'CLAUDE_CONFIG_DIR', 'C:\c')),
        @('codex, an empty home', 'codex', '', $null, @()),
        @('codex, no run settings and no bridge', 'codex', 'C:\homes\codex', 780000, @('OPENAI_API_KEY', 'k', 'CODEX_API_KEY', 'k', 'MCP_TOOL_TIMEOUT', '5'))
    )
    foreach ($r in $runs) {
        [ordered]@{ name = "run: $($r[0])"; input = [ordered]@{ kind = 'run'; cli = $r[1]; home = $r[2]; bridge = $r[3]; parent = (New-NvEnvDict $r[4]) } }
    }
    $ascii = @('ZZ', 'A', 'A B', 'A!', 'A-B', 'a.b', 'A1', 'A@', 'AB', 'A[', 'A^', 'A_B', 'a_c', 'A`', 'A{', 'A~', '9Z', 'Ab_', 'AB1')
    # Windows PowerShell upper-cases with Windows' own table, so only letters
    # cased since Unicode 1.1 are here - none a newer Windows could case anew
    # (Georgian, say) - and beyond the BMP only what it compares by surrogate
    $beyond = @('CAFE', (U 'caf\u00e9'), 'IY', (U '\u0131X'), 'SY', 'SSY', (U '\u017fX'), (U '\u00dfX'),
        (U '\u00b5X'), (U '\u039cA'), 'yZ', (U '\u00ffX'), (U '\u00e0X'), (U '\u00c1Y'), (U '\u00c0W'), (U '\u0101X'),
        (U '\u01c5X'), (U '\u01c4Y'), (U '\u03c2X'), (U '\u03a3Y'), (U '\u1f80X'), (U '\u1f88A'),
        (U '\uff21X'), (U '\ufffdX'), (U '\ud800\udc00X'), (U '\ud83d\ude00X'), (U '\ud801\udc28X'), (U '\ud801\udc00Y'))
    $blocks = @(
        @('a new name keeps its casing', @(), @('New_Var', 'v')),
        @('a parent name keeps its casing', @('Mixed_Case', 'old'), @('MIXED_CASE', 'new')),
        @('null removes in any casing', @('Gone_A', '1', 'Kept', '2'), @('GONE_A', $null)),
        @('empty removes in any casing', @('Gone_B', '1', 'Kept', '2'), @('gone_b', '')),
        @('removing a name not there', @('Here', '1'), @('NOT_HERE', $null)),
        @('a dropped name set again', @('CLAUDECODE', '1', 'CLAUDE_PID', '2'), @('claudecode', '3')),
        @('values', @('V1', 'a=b=c', 'V2', ' spaced ', 'V3', (U '\ud55c\uad6d\uc5b4'), 'V4', (U '\ud83d\ude00'), 'V5', 'a;b;c', 'V6', '%V1%', 'V7', '"quoted"'), @()),
        @('order: ascii', @(foreach ($n in $ascii) { $n; 'v' }), @()),
        @('order: beyond ascii', @(foreach ($n in $beyond) { $n; 'v' }), @()),
        @('order: set names among the parent''s', @('b', '1', 'D', '2'), @('C', '3', 'a', '4', 'E', '5'))
    )
    foreach ($b in $blocks) {
        [ordered]@{ name = "block: $($b[0])"; input = [ordered]@{ kind = 'block'; parent = (New-NvEnvDict $b[1]); setEnv = (New-NvEnvDict $b[2]) } }
    }
} -Expect {
    param($In, $Name)
    switch ([string]$In.kind) {
        'drop' { return , @($script:ChatqEnvDrop) }
        'runEnv' {
            $o = [ordered]@{}
            foreach ($k in $script:ChatqRunEnv.Keys) { $o[$k] = $script:ChatqRunEnv[$k] }
            return $o
        }
        'run' { return (Invoke-NvEnvRun $In $Name) }
        'block' { return (Invoke-NvEnvBlock $In) }
    }
    throw "no kind '$($In.kind)'"
}
