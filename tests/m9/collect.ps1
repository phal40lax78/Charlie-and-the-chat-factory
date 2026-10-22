<#
M9's collector in a sandbox of its own (the M9 plan, steps 0 and 1):
Invoke-ChatOverlayCollectLoop against the real transcripts, read only,
saving (not -Peek) into the sandbox's own data/, with nothing able to act
on a real chat.

    powershell -NoProfile -ExecutionPolicy Bypass -File tests\m9\collect.ps1 -Root <folder> [-Variant a|b] [-Seconds N | -Passes N]
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\m9\collect.ps1 -Root <folder> -Headless [-UiExe <exe>] [-Hotkey <keys>] [-ConsoleHotkey <keys>] [-Seconds N | -Passes N]

-Root gets a copy of the script and its src/ in tool/ (made once), whose
data/ follows the script. Its config.json is the safety config and nothing
else: autoContinue and autoContinueCrash off. An empty data root would read
autoContinue as ask (Get-ChatqAutoContinue), and an answer could start a
second watcher running real continues on the user's chats. And the panel's
two hotkeys, -Hotkey and -ConsoleHotkey, none unless given: a real panel
(-UiExe) on the defaults would take Ctrl+Alt+Shift+O and Q from the user's
own overlay, or find them taken by it. A safety config of an earlier run
with other hotkeys is written over; any other config.json is not.

Stubbed, each call logged to data/seam-calls.log: Request-ChatqWatcher,
Write-ChatReloadAnswer, the outbox's launch (Start-ChatqOutboxSender and
ChatqLiveSendSeam) and a watcher's launch (ChatqSpawn). Seamed: the three
usage fetches (no network, no gh, no codex app-server), the front calls
(CHATQ_NOFRONT), the show and stop calls.

-Variant a loads every part, as CHATQ_ALLPARTS does; b only the parts a
CHATQ_OVERLAY process loads (no overlay-windows, console, overlay-mac).
Every 5 minutes the real compaction, Invoke-ChatOverlayHeapCompact, when
the part that holds it is loaded. -UsageJson: a recorded usage payload
(the endpoint's JSON) for the usage seam; without it, one 5h window.

-Headless: the headless host whole (Start-ChatOverlayHeadlessHost), in
place of the bare loop, with the parts its launch loads (variant b) - the
audit's run (tests/m9/audit.ps1). Its panel is -UiExe, which shows a
window; without it, a stand-in that does as the panel does with its
stdin - reads it until the host closes it, then exits - and draws
nothing. Stubbed as well: the restart's relaunch (ChatOverlaySpawn) and
the phone setup. What it says goes to data/m9-host.out too, as the
audit's run has no stdout.

This file is ASCII, for the reason tests/run-tests.ps1 gives.
#>
param(
    [Parameter(Mandatory)][string]$Root,
    [ValidateSet('a', 'b')][string]$Variant = 'a',
    [int]$IntervalMs = 2000,
    [int]$Passes = 0,
    [int]$Seconds = 0,
    [string]$UsageJson,
    [switch]$Headless,
    [string]$UiExe,
    [ValidatePattern('^[A-Za-z0-9+]+$')][string]$Hotkey = 'none',
    [ValidatePattern('^[A-Za-z0-9+]+$')][string]$ConsoleHotkey = 'none'
)

$ErrorActionPreference = 'Stop'
Set-Variable -Name MaximumVariableCount -Value 32768
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$checkout = Split-Path -Parent (Split-Path -Parent $here)
$Root = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Root)
$tool = Join-Path $Root 'tool'
$data = Join-Path $tool 'data'
$utf8 = New-Object System.Text.UTF8Encoding $false
$safety = '{"autoContinue":"off","autoContinueCrash":"off","overlay":{"hotkey":"' + $Hotkey + '","consoleHotkey":"' + $ConsoleHotkey + '"}}'
# what a safety config of any run looks like, hotkeys and all - before them too
$safetyRx = '^\{"autoContinue":"off","autoContinueCrash":"off"(,"overlay":\{"hotkey":"[A-Za-z0-9+]+","consoleHotkey":"[A-Za-z0-9+]+"\})?\}$'
if ($Headless) { $Variant = 'b' }

if (-not (Test-Path -LiteralPath (Join-Path $tool 'Charlie-and-the-chat-factory.ps1'))) {
    $null = New-Item -ItemType Directory -Path $tool -Force
    Copy-Item -LiteralPath (Join-Path $checkout 'Charlie-and-the-chat-factory.ps1') -Destination $tool
    Copy-Item -LiteralPath (Join-Path $checkout 'src') -Destination $tool -Recurse
}
$null = New-Item -ItemType Directory -Path $data -Force
# A config.json not ours is never run on: it may be a real one, copied in.
$cfgPath = Join-Path $data 'config.json'
if ((Test-Path -LiteralPath $cfgPath) -and [IO.File]::ReadAllText($cfgPath) -cnotmatch $safetyRx) { throw "$cfgPath is not the safety config; not run" }
[IO.File]::WriteAllText($cfgPath, $safety, $utf8)

$env:CHATQ_OVERLAY = '1'
$env:CHATQ_NOFRONT = '1'
# no gh: Copilot's fetch is seamed too, this keeps any other caller off it
$env:CHATQ_GH = Join-Path $here 'no-such-gh.exe'
if ($Variant -eq 'a') { $env:CHATQ_ALLPARTS = '1' } else { Remove-Item 'env:CHATQ_ALLPARTS' -EA SilentlyContinue }
foreach ($n in 'CHATQ_ROLE', 'CHATQ_WATCHER', 'CHATQ_CODE', 'CHATQ_CHATQD', 'CHATQ_ENGINE', 'CHATQ_NATIVE_SEAMS') { Remove-Item "env:$n" -EA SilentlyContinue }
. (Join-Path $tool 'Charlie-and-the-chat-factory.ps1')
Set-StrictMode -Off
if ($script:ChatqData -ne $data) { throw "the copy's data root is $($script:ChatqData), not $data" }

$seamLog = Join-Path $data 'seam-calls.log'
function Write-M9SeamCall([string]$What) { [IO.File]::AppendAllText($seamLog, (Microsoft.PowerShell.Utility\Get-Date).ToString('o') + " $What`n", $utf8) }
# the stubs: defined after the load, so they win
function Request-ChatqWatcher {
    param([string]$Wake = 'poke')
    Write-M9SeamCall "Request-ChatqWatcher $Wake"
    return [pscustomobject]@{ Alive = $false; Spawned = $false; Respawned = $false; At = (Get-Date) }
}
function Write-ChatReloadAnswer {
    param([int]$HostPid, [string]$Id, [string]$Answer)
    Write-M9SeamCall "Write-ChatReloadAnswer $HostPid $Answer"
}
function Start-ChatqOutboxSender { Write-M9SeamCall 'Start-ChatqOutboxSender'; return $true }
$script:ChatqLiveSendSeam = { param($o) Write-M9SeamCall "ChatqLiveSendSeam $($o.event)" }
$script:ChatqSpawn = { param($l) Write-M9SeamCall 'ChatqSpawn'; $true }
$script:ChatShowSpawnSeam = { param($c) Write-M9SeamCall 'ChatShowSpawnSeam'; $null }
$script:ChatStopSeam = { param($e) Write-M9SeamCall 'ChatStopSeam'; 'gone' }
$script:ChatqToastSeam = { param($t, $x) Write-M9SeamCall 'ChatqToastSeam' }
$script:ChatqNtfySeam = { param($server, $body, $headers) Write-M9SeamCall 'ChatqNtfySeam' }
$script:ChatqDownSeam = { param($m, $u, $h, $b) Write-M9SeamCall 'ChatqDownSeam'; $null }
$script:ChatOverlayRaiseSeam = { param($c, $h, $o) Write-M9SeamCall 'ChatOverlayRaiseSeam'; $null }
$script:ChatOverlayGrantSeam = { param($p) Write-M9SeamCall 'ChatOverlayGrantSeam'; @() }
$script:ChatNoGhostWatch = $true
# usage: no network
$script:M9Usage = if ($UsageJson) { [IO.File]::ReadAllText($UsageJson) } else { $null }
$script:ChatOverlayUsageSeam = {
    if ($script:M9Usage) { @{ Ok = $true; Status = 200; Windows = @(ConvertFrom-ChatqUtilization ($script:M9Usage | ConvertFrom-Json)) } }
    else { @{ Ok = $true; Status = 200; Windows = @([pscustomobject]@{ Label = '5h'; Percent = 10; ResetsAt = (Get-Date).AddHours(3); Severity = 'normal' }) } }
}
$script:ChatOverlayCopilotSeam = { @{ Ok = $false; Status = 0; Why = 'seamed for M9'; Quiet = $true } }
$script:ChatOverlayCodexUsageSeam = { param($h) @{ Ok = $false; Why = 'seamed for M9'; Quiet = $true } }

if ($Headless) {
    $say = { param($t) Write-Output $t; [IO.File]::AppendAllText((Join-Path $data 'm9-host.out'), "$t`n", $utf8) }
    $script:ChatOverlaySpawn = { param($l) Write-M9SeamCall 'ChatOverlaySpawn'; $true }
    function Start-ChatqPhoneSetup { Write-M9SeamCall 'Start-ChatqPhoneSetup'; return $null }
    if (-not $UiExe) {
        $script:ChatOverlayUiSpawnSeam = {
            param($Exe, $Data)
            # findstr with no file reads stdin, and a pattern no line has
            $si = [System.Diagnostics.ProcessStartInfo]::new((Join-Path $env:SystemRoot 'System32\findstr.exe'), '/b /c:"~m9~"')
            $si.UseShellExecute = $false
            $si.RedirectStandardInput = $true
            $si.CreateNoWindow = $true
            $si.WorkingDirectory = $HOME
            [System.Diagnostics.Process]::Start($si)
        }
    }
    $cycles = if ($Passes) { $Passes } elseif ($Seconds) { [int][Math]::Ceiling($Seconds * 1000 / $IntervalMs) } else { 0 }
    & $say "m9 host: pid $PID, root $Root, panel $(if ($UiExe) { $UiExe } else { 'the stand-in' }), hotkeys $Hotkey and $ConsoleHotkey, $cycles passes"
    $why = Start-ChatOverlayHeadlessHost -UiExe $(if ($UiExe) { $UiExe } else { 'm9-stand-in.exe' }) -IntervalMs $IntervalMs -MaxCycles $cycles
    & $say "m9 host: ended ($why)"
    return
}

# the Windows host's context, as Start-ChatOverlayMacHost builds its own
$ctx = New-ChatOverlayContext
$ctx.WantAsk = $true
$ctx.WantAuto = $true
Restore-ChatOverlayUsage $ctx
# variant b loads no overlay-windows.ps1, which holds the compaction: none
# then (the plan's step 4 moves it to a part the host loads alone)
$script:M9Compact = [bool](Get-Command Invoke-ChatOverlayHeapCompact -EA SilentlyContinue)
$script:M9Started = Get-Date
$script:M9CompactAt = $script:M9Started
Write-Output "m9 collect: pid $PID, variant $Variant, root $Root, compaction $($script:M9Compact)"
$why = Invoke-ChatOverlayCollectLoop $ctx -IntervalMs $IntervalMs -MaxCycles $Passes -OnCycle {
    param($snap)
    $now = Get-Date
    if ($script:M9Compact -and ($now - $script:M9CompactAt).TotalMinutes -ge 5) { $null = Invoke-ChatOverlayHeapCompact; $script:M9CompactAt = $now }
    if ($Seconds -gt 0 -and ($now - $script:M9Started).TotalSeconds -ge $Seconds) { return 'seconds' }
    return $null
}
Write-Output "m9 collect: ended ($why) after $($ctx.Cycle) passes"
