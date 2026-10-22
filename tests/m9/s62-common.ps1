<#
What the s62 scripts share (tests/m9/s62-README.md): the sandbox's paths,
its config and fake homes, each process's own environment, the stubs a
loaded tool gets, a JSON-lines log, and the few Windows calls they read
with. Dot-sourced by s62-console.ps1, s62-host.ps1, s62-auto.ps1 and
s62-hand.ps1, never run on its own.

The sandbox is the clone this file sits in: <root>/data, which the tool's
own data root is when it is dot-sourced from <root> ($script:ChatqData,
src/queue.ps1). Everything an s62 run writes is under <root>/data, its
own files under <root>/data/s62. Nothing goes to TEMP: the Windows calls
are emitted in memory (Initialize-S62Native), not compiled by csc.

This file is ASCII, for the reason tests/run-tests.ps1 gives.
#>

$script:S62Utf8 = New-Object System.Text.UTF8Encoding $false
# the sandbox's config.json: collect.ps1's safety config (no auto-continue
# of any kind, so no answer starts a watcher on a real chat), the native
# panel, its hotkey none and the console's one no real overlay has, no
# auto start and no usage fetch (they are seamed as well, Set-S62Seams).
# Key names as Get-ChatOverlayConfig reads them.
$script:S62Safety = '{"autoContinue":"off","autoContinueCrash":"off","overlay":{"panel":"native","hotkey":"none","consoleHotkey":"Ctrl+Alt+Shift+F10","autoStart":false,"liveUsage":false,"copilotUsage":false,"codexUsage":false}}'
# collect.ps1's own safety configs, which a clone may have from a run of it
$script:S62CollectRx = '^\{"autoContinue":"off","autoContinueCrash":"off"(,"overlay":\{"hotkey":"[A-Za-z0-9+]+","consoleHotkey":"[A-Za-z0-9+]+"\})?\}$'
# the user's live copy: never a root
$script:S62Live = 'D:\Workspace\proj_VSCode\Charlie-and-the-chat-factory'

function Get-S62Paths {
    param([Parameter(Mandatory)][string]$Root)
    $Root = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $data = Join-Path $Root 'data'
    $s62 = Join-Path $data 's62'
    [pscustomobject]@{
        Root = $Root; Data = $data; S62 = $s62
        Tool = Join-Path $Root 'Charlie-and-the-chat-factory.ps1'
        Here = Join-Path $Root 'tests\m9'
        FakeClaude = Join-Path $s62 'fake-claude'; FakeCodex = Join-Path $s62 'fake-codex'
        # the repo's fake CLI, for both, as tests/vectors.ps1 has it
        FakeCli = Join-Path $Root 'tests\fake-claude.cmd'
        # no gh: Copilot's fetch is seamed, this keeps any other caller off it (collect.ps1)
        NoGh = Join-Path $s62 'no-such-gh.exe'
        # no VS Code: an open's code -n finds nothing to start (Find-ChatCodeCommand)
        NoCode = Join-Path $s62 'no-such-code.cmd'
        Ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Config = Join-Path $data 'config.json'; State = Join-Path $data 'overlay-state.json'
        Cmd = Join-Path $data 'overlay-cmd'; PidFile = Join-Path $data 'overlay.pid'
        ColdFlag = Join-Path $s62 'host-cold'; SeamLog = Join-Path $s62 'seam-calls.log'
    }
}

function Assert-S62Root {
    <#
    A root that is the clone, never the live copy, with the tool in it: a
    local path, not the live one or under it as written, nor as it really
    is - a junction, link, 8.3 name or subst drive onto the live copy is
    refused too (Get-S62RealPath); a root whose real path cannot be read
    (a mapped or network drive) is refused as well. Folder boundaries
    compared, so a sibling such as <live>-clone is not the live copy. And
    the 0.11.1 code, whose host loads the console into itself
    (Import-ChatOverlayConsoleParts): S62 stands in for that console or
    times it, and on 0.11.6 code (Start-ChatConsoleProcess) the host would
    start the real console's process, none of S62's seams in it.
    #>
    param($P)
    $cmp = [System.StringComparison]::OrdinalIgnoreCase
    if ($P.Root.StartsWith('\\')) { throw "$($P.Root) is a network or device path, not a local clone; not run" }
    if (($P.Root + '\').StartsWith($script:S62Live + '\', $cmp)) { throw "$($P.Root) is the live copy; not run" }
    if (-not [System.IO.File]::Exists($P.Tool)) { throw "no $($P.Tool)" }
    $oh = Join-Path $P.Root 'src\overlay-host.ps1'
    if (-not ([System.IO.File]::Exists($oh) -and [System.IO.File]::ReadAllText($oh).Contains('function Import-ChatOverlayConsoleParts'))) {
        throw "$($P.Root) is not the 0.11.1 code S62 drives (no Import-ChatOverlayConsoleParts); run it from a clone at 1a48212 with tests\m9 copied in; not run"
    }
    $real = Get-S62RealPath $P.Root
    if (-not $real) { throw "the real path of $($P.Root) cannot be read; not run" }
    $liveReal = Get-S62RealPath $script:S62Live
    if ($liveReal -and ($real + '\').StartsWith($liveReal + '\', $cmp)) { throw "$($P.Root) is the live copy by another path ($real); not run" }
}

function Set-S62Sandbox {
    <#
    The sandbox's files, written again each run: config.json (refused over
    one that is not an s62 or collect.ps1 safety config: it may be a real
    one, copied in; and with no config.json, refused over a data/ that has
    anything in it but s62/ - a real data folder copied in without its
    config, its queue and chats the sandbox host would read and show),
    overlay-state.json at 300,300, and the fake Claude home with one
    transcript - no credentials - and an empty Codex home.
    #>
    param($P)
    if ([System.IO.File]::Exists($P.Config)) {
        $t = [System.IO.File]::ReadAllText($P.Config)
        if ($t -cne $script:S62Safety -and $t -cnotmatch $script:S62CollectRx) { throw "$($P.Config) is not a safety config; not run" }
    }
    elseif ([System.IO.Directory]::Exists($P.Data)) {
        $other = @(Get-ChildItem -LiteralPath $P.Data -Force -EA SilentlyContinue | Where-Object { $_.Name -ne 's62' })
        if ($other.Count) { throw "$($P.Data) has $($other.Count) entries and no config.json - it may be a real data folder, copied in; not run" }
    }
    foreach ($d in $P.Data, $P.S62, $P.FakeCodex) { $null = New-Item -ItemType Directory -Path $d -Force }
    [System.IO.File]::WriteAllText($P.Config, $script:S62Safety, $script:S62Utf8)
    [System.IO.File]::WriteAllText($P.State, '{"x":300,"y":300}', $script:S62Utf8)
    # one chat, in a folder that is there (the s62 folder), as Claude Code
    # writes one (tests/sections/hover-card.ps1)
    $sid = '61616161-6161-4161-8161-616161616161'
    $cwd = $P.S62
    $proj = Join-Path (Join-Path $P.FakeClaude 'projects') ($cwd -replace '[^A-Za-z0-9]', '-')
    $null = New-Item -ItemType Directory -Path $proj -Force
    $f = Join-Path $proj "$sid.jsonl"
    if (-not [System.IO.File]::Exists($f)) {
        $at = [DateTimeOffset]::UtcNow.AddMinutes(-30)
        $stamp = { param($m) $at.AddMinutes($m).ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [cultureinfo]::InvariantCulture) }
        $tail = [ordered]@{ userType = 'external'; entrypoint = 'claude-vscode'; cwd = $cwd; sessionId = $sid; version = '2.1.291'; gitBranch = 'main' }
        $u = [ordered]@{ parentUuid = $null; isSidechain = $false; type = 'user'; message = [ordered]@{ role = 'user'; content = @([ordered]@{ type = 'text'; text = 'S62 test prompt' }) }; uuid = [string][guid]::NewGuid(); timestamp = (& $stamp 0) }
        $a = [ordered]@{ parentUuid = $u.uuid; isSidechain = $false; type = 'assistant'; message = [ordered]@{ model = 'claude-opus-5-5'; id = 'msg_s62'; type = 'message'; role = 'assistant'; content = @([ordered]@{ type = 'text'; text = 'S62 test answer' }); stop_reason = 'end_turn' }; uuid = [string][guid]::NewGuid(); timestamp = (& $stamp 1) }
        foreach ($k in $tail.Keys) { $u[$k] = $tail[$k]; $a[$k] = $tail[$k] }
        $lines = (ConvertTo-Json -InputObject $u -Compress -Depth 8) + "`n" + (ConvertTo-Json -InputObject $a -Compress -Depth 8) + "`n"
        [System.IO.File]::WriteAllText($f, $lines, $script:S62Utf8)
    }
}

function Set-S62Env {
    <#
    This process's own environment - every s62 process is a child of the
    run, so nothing here reaches the machine's, the user's or the
    terminal's: the overlay's mark (CHATQ_OVERLAY: no key bindings, no
    watches), the fake homes and CLIs, no gh, no VS Code (CHATQ_CODE a
    file that is not there; ChatCodeSeam as well, Set-S62Seams), and the
    parts flag and the roles gone (as collect.ps1). -Cloak: the automatic
    run's - windows drawn but never seen (CHATQ_CLOAK), nothing asks for
    the front (CHATQ_NOFRONT), no tray (CHATQ_NOTRAY); without it all
    three go, as the hand run needs the front and the tray for real.
    Save-S62Env first, Restore-S62Env after, where the process is not one
    of the run's own (s62-hand.ps1).
    #>
    param($P, [switch]$Cloak)
    $env:CHATQ_OVERLAY = '1'
    $env:CLAUDE_CONFIG_DIR = $P.FakeClaude
    $env:CODEX_HOME = $P.FakeCodex
    $env:CHATQ_CLAUDE = $P.FakeCli
    $env:CHATQ_CODEX = $P.FakeCli
    $env:CHATQ_GH = $P.NoGh
    $env:CHATQ_CODE = $P.NoCode
    foreach ($n in 'CHATQ_ALLPARTS', 'CHATQ_ROLE', 'CHATQ_WATCHER', 'CHATQ_CHATQD', 'CHATQ_ENGINE', 'CHATQ_NATIVE_SEAMS') { Remove-Item "env:$n" -EA SilentlyContinue }
    foreach ($n in 'CHATQ_CLOAK', 'CHATQ_NOFRONT', 'CHATQ_NOTRAY') {
        if ($Cloak) { Set-Item "env:$n" '1' } else { Remove-Item "env:$n" -EA SilentlyContinue }
    }
}

# every variable Set-S62Env sets or clears
$script:S62EnvNames = @('CHATQ_OVERLAY', 'CLAUDE_CONFIG_DIR', 'CODEX_HOME', 'CHATQ_CLAUDE', 'CHATQ_CODEX', 'CHATQ_GH', 'CHATQ_CODE',
    'CHATQ_ALLPARTS', 'CHATQ_ROLE', 'CHATQ_WATCHER', 'CHATQ_CHATQD', 'CHATQ_ENGINE', 'CHATQ_NATIVE_SEAMS', 'CHATQ_CLOAK', 'CHATQ_NOFRONT', 'CHATQ_NOTRAY')

function Save-S62Env {
    # this process's values of them, $null for one not set
    $o = @{}
    foreach ($n in $script:S62EnvNames) { $o[$n] = [Environment]::GetEnvironmentVariable($n) }
    return $o
}

function Restore-S62Env {
    # as Save-S62Env found them, in this process
    param([hashtable]$Saved)
    foreach ($n in @($Saved.Keys)) {
        if ($null -eq $Saved[$n]) { Remove-Item "env:$n" -EA SilentlyContinue } else { Set-Item "env:$n" $Saved[$n] }
    }
}

function Assert-S62Loaded {
    # the loaded tool's data root and Claude home are the sandbox's
    param($P, [string]$Data, [string]$ClaudeHome)
    if ($Data -ne $P.Data) { throw "the tool's data root is $Data, not $($P.Data)" }
    if (-not ([System.IO.Path]::GetFullPath($ClaudeHome)).StartsWith($P.S62, [System.StringComparison]::OrdinalIgnoreCase)) { throw "the tool's Claude home is $ClaudeHome, not under $($P.S62)" }
}

function Write-S62Seam([string]$What) {
    try { [System.IO.File]::AppendAllText($script:S62SeamLog, (Get-Date).ToString('o') + " $PID $What`n", $script:S62Utf8) } catch {}
}

function Set-S62Seams {
    <#
    collect.ps1's stubs and seams, after the tool's load so they win, in
    the caller's script scope: no watcher, outbox, phone setup, relaunch,
    show or stop; no toast, ntfy or download; no VS Code and no front call
    for an open (Open-ChatCodeWindow's ChatCodeSeam, a row clicked by
    mistake in the hand run); no ghost watch; no usage fetch; and
    Get-ChatqHomeDir with no override the fake homes, not ~/.claude or
    ~/.codex. Each call logged to data/s62/seam-calls.log.
    #>
    param($P)
    $script:S62SeamLog = $P.SeamLog
    Set-Item -Path function:script:Request-ChatqWatcher -Value {
        param([string]$Wake = 'poke')
        Write-S62Seam "Request-ChatqWatcher $Wake"
        return [pscustomobject]@{ Alive = $false; Spawned = $false; Respawned = $false; At = (Get-Date) }
    }
    Set-Item -Path function:script:Write-ChatReloadAnswer -Value { param([int]$HostPid, [string]$Id, [string]$Answer) Write-S62Seam "Write-ChatReloadAnswer $HostPid $Answer" }
    Set-Item -Path function:script:Start-ChatqOutboxSender -Value { Write-S62Seam 'Start-ChatqOutboxSender'; return $true }
    Set-Item -Path function:script:Start-ChatqPhoneSetup -Value { Write-S62Seam 'Start-ChatqPhoneSetup'; return $null }
    $script:ChatqLiveSendSeam = { param($o) Write-S62Seam "ChatqLiveSendSeam $($o.event)" }
    $script:ChatqSpawn = { param($l) Write-S62Seam 'ChatqSpawn'; $true }
    $script:ChatShowSpawnSeam = { param($c) Write-S62Seam 'ChatShowSpawnSeam'; $null }
    $script:ChatStopSeam = { param($e) Write-S62Seam 'ChatStopSeam'; 'gone' }
    $script:ChatqToastSeam = { param($t, $x) Write-S62Seam 'ChatqToastSeam' }
    $script:ChatqNtfySeam = { param($server, $body, $headers) Write-S62Seam 'ChatqNtfySeam' }
    $script:ChatqDownSeam = { param($m, $u, $h, $b) Write-S62Seam 'ChatqDownSeam'; $null }
    $script:ChatOverlayRaiseSeam = { param($c, $h, $o) Write-S62Seam 'ChatOverlayRaiseSeam'; $null }
    $script:ChatOverlayGrantSeam = { param($p) Write-S62Seam 'ChatOverlayGrantSeam'; @() }
    $script:ChatOverlaySpawn = { param($l) Write-S62Seam 'ChatOverlaySpawn'; $true }
    $script:ChatCodeSeam = { param($f) Write-S62Seam "ChatCodeSeam $f"; [pscustomobject]@{ Ok = $false; Code = 'no-code'; Why = 'seamed for s62'; Slow = $false } }
    $script:S62HomeClaude = $P.FakeClaude
    $script:S62HomeCodex = $P.FakeCodex
    Set-Item -Path function:script:Get-ChatqHomeDir -Value {
        param([string]$Provider, [string]$Override)
        if ($Override) { return $Override }
        if ($Provider -eq 'codex') { return $script:S62HomeCodex }
        return $script:S62HomeClaude
    }
    $script:ChatNoGhostWatch = $true
    $script:ChatOverlayUsageSeam = { @{ Ok = $true; Status = 200; Windows = @([pscustomobject]@{ Label = '5h'; Percent = 10; ResetsAt = (Get-Date).AddHours(3); Severity = 'normal' }) } }
    $script:ChatOverlayCopilotSeam = { @{ Ok = $false; Status = 0; Why = 'seamed for s62'; Quiet = $true } }
    $script:ChatOverlayCodexUsageSeam = { param($h) @{ Ok = $false; Why = 'seamed for s62'; Quiet = $true } }
}

function Get-S62Ms { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }

function ConvertFrom-S62Stamp {
    # an overlay-cmd line's time - Get-ChatqStamp's, or the panel's (app.rs) - in epoch ms
    param([string]$Stamp)
    try { return [DateTimeOffset]::Parse($Stamp, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal).ToUnixTimeMilliseconds() } catch { return $null }
}

function Write-S62Log {
    # one JSON line: t (epoch ms), pid, ev, then -Data's keys
    param([string]$Path, [string]$Ev, [System.Collections.IDictionary]$Data = @{})
    $o = [ordered]@{ t = (Get-S62Ms); pid = $PID; ev = $Ev }
    foreach ($k in @($Data.Keys)) { $o[$k] = $Data[$k] }
    try { [System.IO.File]::AppendAllText($Path, (ConvertTo-Json -InputObject $o -Compress -Depth 5) + "`n", $script:S62Utf8) } catch {}
}

function Read-S62Log {
    param([string]$Path)
    if (-not [System.IO.File]::Exists($Path)) { return @() }
    $lines = try { [System.IO.File]::ReadAllLines($Path) } catch { @() }
    return @(foreach ($l in $lines) { if ($l) { try { $l | ConvertFrom-Json } catch {} } })
}

function Wait-S62Event {
    # the first line of -Ev in -Path at or after -After (epoch ms) that
    # -Where takes, within -TimeoutSec; $null for none
    param([string]$Path, [string]$Ev, [int64]$After = 0, [int]$TimeoutSec = 60, [scriptblock]$Where = { $true })
    $until = (Get-Date).AddSeconds($TimeoutSec)
    while ($true) {
        foreach ($e in @(Read-S62Log $Path)) { if ($e.ev -eq $Ev -and [int64]$e.t -ge $After -and (& $Where $e)) { return $e } }
        if ((Get-Date) -ge $until) { return $null }
        Start-Sleep -Milliseconds 100
    }
}

function Send-S62Command {
    # a line for the sandbox's overlay, as Send-ChatOverlayCommand writes
    # one ("<Get-ChatqStamp> <verb>"); its time in epoch ms
    param($P, [string]$Verb)
    $now = Get-Date
    [System.IO.File]::AppendAllText($P.Cmd, $now.ToUniversalTime().ToString('o') + " $Verb`n", $script:S62Utf8)
    return [DateTimeOffset]::new($now).ToUnixTimeMilliseconds()
}

function Get-S62PrivateMb {
    param([int]$Id)
    try { $p = [System.Diagnostics.Process]::GetProcessById($Id); return [Math]::Round($p.PrivateMemorySize64 / 1MB, 1) } catch { return $null }
}

function Format-S62Arg([string]$S) { "'" + ($S -replace "'", "''") + "'" }

function Start-S62Host {
    <#
    s62-host.ps1 as the overlay is started (Start-ChatOverlayProcess,
    Get-ChatOverlayLaunch): Windows PowerShell -STA, hidden, an encoded
    command that dot-sources it - so it and the tool run in the global
    scope, where the console's parts go as they load
    (Import-ChatOverlayConsoleParts). -HostArgs: its parameters, already
    quoted (Format-S62Arg).
    #>
    param($P, [string[]]$HostArgs)
    $cmd = '. ' + (Format-S62Arg (Join-Path $P.Here 's62-host.ps1')) + ' ' + ($HostArgs -join ' ')
    $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmd))
    return (Start-Process -FilePath $P.Ps -ArgumentList @('-NoProfile', '-NonInteractive', '-STA', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc) -WindowStyle Hidden -PassThru)
}

function Start-S62Console {
    <#
    s62-console.ps1 as the host starts it: its stdin a pipe the starter
    holds, CreateNoWindow off - it shares its starter's console, the
    hidden one of a host - and no WindowStyle, so no STARTF_USESHOWWINDOW
    reaches its first Show. -Env: variables for this child alone.
    #>
    param($P, [int]$HostPid = 0, [ValidateSet('cold', 'warm')][string]$Measure = 'cold', [switch]$Visible, [hashtable]$Env = @{})
    $a = '-NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File "' + (Join-Path $P.Here 's62-console.ps1') + '" -Root "' + $P.Root + '" -HostPid ' + $HostPid + ' -Measure ' + $Measure
    if ($Visible) { $a += ' -Visible' }
    $si = [System.Diagnostics.ProcessStartInfo]::new($P.Ps, $a)
    $si.UseShellExecute = $false
    $si.RedirectStandardInput = $true
    $si.CreateNoWindow = $false
    $si.WorkingDirectory = $HOME
    foreach ($k in @($Env.Keys)) { $si.Environment[$k] = [string]$Env[$k] }
    return [System.Diagnostics.Process]::Start($si)
}

function Initialize-S62Native {
    <#
    The Windows calls the s62 scripts read with, as a type emitted in
    memory, held in $global:S62NativeType and called through it - not by
    its name, which PowerShell may not resolve for a dynamic assembly: no
    csc, so nothing in TEMP and no compile on the console's path to its
    first frame. Reads, AllowSetForegroundWindow, which only grants, and
    CreateFileW for a handle that only reads a folder's attributes
    (Get-S62RealPath). Arrays stand in for out parameters: a blittable
    array is pinned, not copied, so the call's writes are seen. DllImport
    set as an attribute on a PinvokeImpl method, the way PSReflect builds
    them (DefinePInvokeMethod has no SetLastError); the assembly from the
    AppDomain on Windows PowerShell, from AssemblyBuilder on pwsh.
    #>
    if ($global:S62NativeType) { return }
    $an = [System.Reflection.AssemblyName]::new('S62Native')
    $run = [System.Reflection.Emit.AssemblyBuilderAccess]::Run
    $ab = try { [AppDomain]::CurrentDomain.DefineDynamicAssembly($an, $run) } catch { [System.Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly($an, $run) }
    $tb = $ab.DefineDynamicModule('S62Native').DefineType('S62Native', [System.Reflection.TypeAttributes]'Public, Class, Abstract, Sealed')
    $dll = [System.Runtime.InteropServices.DllImportAttribute]
    $ctor = $dll.GetConstructor([type[]]@([string]))
    $fields = [System.Reflection.FieldInfo[]]@($dll.GetField('SetLastError'), $dll.GetField('CharSet'))
    $calls = @(
        @('user32.dll', 'IsWindowVisible', [bool], @([IntPtr])),
        @('user32.dll', 'GetForegroundWindow', [IntPtr], @()),
        @('user32.dll', 'GetWindowThreadProcessId', [uint32], @([IntPtr], [int[]])),
        @('user32.dll', 'AllowSetForegroundWindow', [bool], @([int])),
        @('dwmapi.dll', 'DwmGetWindowAttribute', [int], @([IntPtr], [int], [int[]], [int])),
        @('dwmapi.dll', 'DwmSetWindowAttribute', [int], @([IntPtr], [int], [int[]], [int])),
        @('kernel32.dll', 'GetStartupInfoW', [void], @([byte[]])),
        @('kernel32.dll', 'CreateFileW', [IntPtr], @([string], [int], [int], [IntPtr], [int], [int], [IntPtr])),
        @('kernel32.dll', 'GetFinalPathNameByHandleW', [int], @([IntPtr], [System.Text.StringBuilder], [int], [int])),
        @('kernel32.dll', 'CloseHandle', [bool], @([IntPtr]))
    )
    foreach ($c in $calls) {
        $m = $tb.DefineMethod($c[1], [System.Reflection.MethodAttributes]'Public, Static, HideBySig, PinvokeImpl', $c[2], [type[]]@($c[3]))
        $m.SetImplementationFlags([System.Reflection.MethodImplAttributes]::PreserveSig)
        $m.SetCustomAttribute([System.Reflection.Emit.CustomAttributeBuilder]::new($ctor, [object[]]@($c[0]), $fields, [object[]]@($true, [System.Runtime.InteropServices.CharSet]::Unicode)))
    }
    $global:S62NativeType = $tb.CreateType()
}

function Get-S62RealPath {
    <#
    A folder's own path, every junction, link, 8.3 name and subst undone:
    GetFinalPathNameByHandleW on a handle that only reads its attributes
    (FILE_READ_ATTRIBUTES, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS for a
    folder), its volume by GUID (VOLUME_NAME_GUID), so two drive letters
    for one volume give one path. $null if it cannot be read - a network
    drive has no volume GUID.
    #>
    param([string]$Path)
    Initialize-S62Native
    $nt = $global:S62NativeType
    $fh = $nt::CreateFileW($Path, 0x80, 7, [IntPtr]::Zero, 3, 0x02000000, [IntPtr]::Zero)
    if ($fh -eq [IntPtr]::Zero -or $fh.ToInt64() -eq -1) { return $null }
    try {
        $sb = [System.Text.StringBuilder]::new(1024)
        $len = $nt::GetFinalPathNameByHandleW($fh, $sb, 1024, 1)
        if ($len -le 0 -or $len -ge 1024) { return $null }
        return $sb.ToString().TrimEnd('\')
    }
    finally { [void]$nt::CloseHandle($fh) }
}

function Get-S62Front {
    # the window in front and its process, read only
    $h = $global:S62NativeType::GetForegroundWindow()
    $p = [int[]]::new(1)
    if ($h -ne [IntPtr]::Zero) { [void]$global:S62NativeType::GetWindowThreadProcessId($h, $p) }
    return @{ Hwnd = $h; Pid = $p[0] }
}

function Get-S62Visible {
    # IsWindowVisible, read only
    param([IntPtr]$Hwnd)
    return [bool]$global:S62NativeType::IsWindowVisible($Hwnd)
}

function Get-S62Cloaked {
    # DWMWA_CLOAKED (14): 0 not cloaked, else why; $null if it cannot be read
    param([IntPtr]$Hwnd)
    $v = [int[]]::new(1)
    if ($global:S62NativeType::DwmGetWindowAttribute($Hwnd, 14, $v, 4) -ne 0) { return $null }
    return $v[0]
}

function Set-S62Cloak {
    # DWMWA_CLOAK (13) on or off, as ChatOverlayNative.Cloak sets it on
    param([IntPtr]$Hwnd, [bool]$On)
    $v = [int[]]@([int]$On)
    return ($global:S62NativeType::DwmSetWindowAttribute($Hwnd, 13, $v, 4) -eq 0)
}

function Get-S62StartupInfo {
    # this process's STARTUPINFO: dwFlags (1 = STARTF_USESHOWWINDOW) and wShowWindow
    $x64 = [IntPtr]::Size -eq 8
    $b = [byte[]]::new(128)
    [BitConverter]::GetBytes([int]$(if ($x64) { 104 } else { 68 })).CopyTo($b, 0)
    $global:S62NativeType::GetStartupInfoW($b)
    $o = if ($x64) { 60 } else { 44 }
    return @{ flags = [BitConverter]::ToInt32($b, $o); showWindow = [int][BitConverter]::ToUInt16($b, $o + 4) }
}

function Grant-S62Front {
    # AllowSetForegroundWindow(pid): whether it took, and GetLastError if not
    param([int]$To)
    $ok = $global:S62NativeType::AllowSetForegroundWindow($To)
    $e = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    return @{ Allow = [bool]$ok; LastError = $(if ($ok) { 0 } else { $e }) }
}

function Get-S62Median {
    param([double[]]$V)
    $s = @($V | Where-Object { $null -ne $_ } | Sort-Object)
    if (-not $s.Count) { return $null }
    $m = [int][Math]::Floor($s.Count / 2)
    if ($s.Count % 2) { return $s[$m] }
    return ($s[$m - 1] + $s[$m]) / 2
}
