<#
S62's prototype console client: the WPF console in a process of its own,
started by the headless host (s62-host.ps1 -Mode spawn) or by s62-auto.ps1
to time it, in place of today's, which the host loads into itself
(Import-ChatOverlayConsoleParts, Open-ChatOverlayHeadlessConsole).

    powershell -NoProfile -NonInteractive -STA -File tests\m9\s62-console.ps1 -Root <clone> [-HostPid N] [-Measure cold|warm] [-Visible]

Started with its stdin a pipe (Start-S62Console in s62-common.ps1). It
loads every part (CHATQ_ALLPARTS), builds a headless host state of its
own (New-ChatOverlayHeadlessState) with a context that never saves
(New-ChatOverlayContext; Events none, SavedAt at its end, so the console's
3 s re-save timer in Open-ChatOverlayHeadlessConsole never writes
overlay.json), takes one Invoke-ChatOverlayCycle -Peek - no commands
taken, nothing saved, so the host's overlay-cmd lines stay the host's -
and opens the console on that snapshot.

-Measure cold: opened at once. warm: opened and sent back at once, then
waits for show - what a process kept warm gives (cloaked meanwhile when
CHATQ_CLOAK is not set). -Visible: opened with -Activate, brought forward
(Enter-ChatOverlayConsoleMode); without it the console never activates
(ChatConsoleFrontSeam a no-op). Its stdin's lines, read off the window's
thread (StreamReader.ReadLineAsync, polled every 100 ms):
    show    shown again (Open-ChatOverlayHeadlessConsole), its first frame timed
    back    back, hidden (Exit-ChatOverlayConsoleMode)
    quit    closed (Stop-ChatOverlayHeadlessConsole) and gone; so is end of input
Gone after 20 minutes whatever, so none outlives a run.

Its log, data/s62/console-<pid>.jsonl, one JSON line each (Write-S62Log):
start (procStart, the process's own start, epoch ms; STARTUPINFO's flags
and wShowWindow), parts, native (Initialize-ChatOverlayNative), peek,
window (New-ChatOverlayWindow), shown, frame (the first
CompositionTarget.Rendering after a show), lists (the first frame with
the chats' list filled and no index read under way), front at +0, +500
and +1500 ms from the frame (the foreground window this one or not,
Win.IsActive, the prompt's keyboard focus, IsWindowVisible, DWM's
cloaked), mem (PrivateMemorySize64) 10 s after each show while open and
30 s after each back, back, cmd, quit.

Its balloons are no host's: Save-ChatOverlayEvents is a no-op here, so
overlay-events.json stays the host's. No index sync (ChatConsoleNoSync):
it would start a hidden PowerShell of its own.

This file is ASCII, for the reason tests/run-tests.ps1 gives.
#>
param(
    [Parameter(Mandatory)][string]$Root,
    [int]$HostPid = 0,
    [ValidateSet('cold', 'warm')][string]$Measure = 'cold',
    [switch]$Visible
)

$ErrorActionPreference = 'Stop'
Set-Variable -Name MaximumVariableCount -Value 32768
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 's62-common.ps1')
$P = Get-S62Paths $Root
Assert-S62Root $P
$null = New-Item -ItemType Directory -Path $P.S62 -Force
$script:S62Log = Join-Path $P.S62 "console-$PID.jsonl"
$script:S62Start = [DateTimeOffset]::new([System.Diagnostics.Process]::GetCurrentProcess().StartTime).ToUnixTimeMilliseconds()
function Get-S62Since { (Get-S62Ms) - $script:S62Start }
Initialize-S62Native
$si = Get-S62StartupInfo
Write-S62Log $script:S62Log 'start' @{ procStart = $script:S62Start; since = (Get-S62Since); hostPid = $HostPid; measure = $Measure; visible = [bool]$Visible
    startFlags = $si.flags; startShow = $si.showWindow; cloakEnv = [bool]$env:CHATQ_CLOAK; nofrontEnv = [bool]$env:CHATQ_NOFRONT
}

# its own environment, the cloak as its starter had it; every part
Set-S62Env $P -Cloak:([bool]$env:CHATQ_CLOAK)
$env:CHATQ_ALLPARTS = '1'
. $P.Tool
# gone once they are in, as Get-ChatOverlayLaunch does
Remove-Item 'env:CHATQ_ALLPARTS' -EA SilentlyContinue
Set-StrictMode -Off
Assert-S62Loaded $P $script:ChatqData $script:ChatClaudeHome
Set-S62Seams $P
Write-S62Log $script:S62Log 'parts' @{ since = (Get-S62Since) }
# from here on as the overlay runs, not stopping at the first error
$ErrorActionPreference = 'Continue'

# defined after the load, so they win
function Save-ChatOverlayEvents { param($H) }
$script:ChatConsoleNoSync = $true
if (-not $Visible) { $script:ChatConsoleFrontSeam = { param($w) } }
$script:S62PreCloak = $false
$script:S62NewWindow = ${function:New-ChatOverlayWindow}
function New-ChatOverlayWindow {
    param($H)
    $out = & $script:S62NewWindow $H
    Write-S62Log $script:S62Log 'window' @{ since = (Get-S62Since); hwnd = [int64]$H.Hwnd }
    # -Measure warm without CHATQ_CLOAK: unseen until its first show
    if ($script:S62PreCloak) { foreach ($hw in @($H.Hwnd, $H.CtlHwnd, $H.EdgesHwnd, $H.ChipHwnd, $H.CardHwnd)) { if ($hw -and $hw -ne [IntPtr]::Zero) { [void](Set-S62Cloak $hw $true) } } }
    $out
}

$sw = [System.Diagnostics.Stopwatch]::StartNew()
Initialize-ChatOverlayNative
Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase
Write-S62Log $script:S62Log 'native' @{ since = (Get-S62Since); ms = $sw.ElapsedMilliseconds }

$script:S62H = New-ChatOverlayHeadlessState
$ctx = New-ChatOverlayContext
$ctx.WantAsk = $true
$ctx.WantAuto = $false
$ctx.Events = $null
$script:S62H.Ctx = $ctx
$sw.Restart()
$snap = Invoke-ChatOverlayCycle $ctx -Peek
$script:S62H.Snap = $snap
$ctx.SavedAt = [datetime]::MaxValue
Write-S62Log $script:S62Log 'peek' @{ since = (Get-S62Since); ms = $sw.ElapsedMilliseconds; rows = @($snap.rows).Count; recent = @($snap.recent).Count }

function Start-S62After {
    # -Do with -Arg, -Ms from now, once, on the window's thread
    param([int]$Ms, [scriptblock]$Do, $Arg)
    $t = [System.Windows.Threading.DispatcherTimer]::new()
    $t.Interval = [TimeSpan]::FromMilliseconds($Ms)
    $t.Tag = @{ Do = $Do; Arg = $Arg }
    $t.add_Tick({
            param($s, $e)
            $s.Stop()
            try { & $s.Tag.Do $s.Tag.Arg } catch { Write-S62Log $script:S62Log 'error' @{ what = "$($_.Exception.Message)" } }
        })
    $t.Start()
}

function Write-S62Front {
    param([int]$At, [string]$Why)
    $W = $script:S62H.Console
    if (-not $W -or -not $W.Hwnd) { return }
    $f = Get-S62Front
    Write-S62Log $script:S62Log 'front' @{ why = $Why; at = $At; fg = [bool]($f.Hwnd -eq $W.Hwnd); fgPid = $f.Pid; active = [bool]$W.Win.IsActive
        focus = [bool]($W.Con -and $W.Con.Prompt -and $W.Con.Prompt.IsKeyboardFocused); visible = (Get-S62Visible $W.Hwnd)
        cloaked = (Get-S62Cloaked $W.Hwnd); mode = [string]$W.Mode
    }
}

function Write-S62Mem {
    param([string]$Why, [int]$N)
    $p = [System.Diagnostics.Process]::GetCurrentProcess()
    $p.Refresh()
    $W = $script:S62H.Console
    Write-S62Log $script:S62Log 'mem' @{ why = $Why; n = $N; privateMb = [Math]::Round($p.PrivateMemorySize64 / 1MB, 1); wsMb = [Math]::Round($p.WorkingSet64 / 1MB, 1); mode = $(if ($W) { [string]$W.Mode } else { '' }) }
}

# The first frame after a show: the first CompositionTarget.Rendering, a
# handler on it only until then - and until the chats' list is filled
# with chats (ChatItems, Update-ChatConsoleChats; not the "no chats" or
# "reading" line it shows before), 10 s at most, as one keeps WPF drawing
# every frame. $wt the watch, $W the console: PowerShell's names are not
# case-sensitive, so never $w beside $W.
$script:S62Watch = $null
$script:S62Render = $null
function Watch-S62Frame {
    param([string]$Why)
    $script:S62Watch = @{ Why = $Why; Sw = [System.Diagnostics.Stopwatch]::StartNew(); Frame = $false; Lists = $false }
    if (-not $script:S62Render) {
        $script:S62Render = [EventHandler] { param($s, $e) Invoke-S62Frame }
        [System.Windows.Media.CompositionTarget]::add_Rendering($script:S62Render)
    }
}
function Invoke-S62Frame {
    $wt = $script:S62Watch
    if (-not $wt) { return }
    $W = $script:S62H.Console
    if (-not $wt.Frame) {
        $wt.Frame = $true
        Write-S62Log $script:S62Log 'frame' @{ why = $wt.Why; sinceShow = $wt.Sw.ElapsedMilliseconds; since = (Get-S62Since) }
        Write-S62Front 0 $wt.Why
        Start-S62After 500 { param($y) Write-S62Front 500 $y } $wt.Why
        Start-S62After 1500 { param($y) Write-S62Front 1500 $y } $wt.Why
    }
    $C = if ($W) { $W.Con } else { $null }
    $n = if ($C) { @($C.ChatItems).Count } else { 0 }
    $late = $wt.Sw.ElapsedMilliseconds -ge 10000
    if (-not $wt.Lists -and (($n -gt 0 -and -not $C.IndexRead) -or $late)) {
        $wt.Lists = $true
        Write-S62Log $script:S62Log 'lists' @{ why = $wt.Why; sinceShow = $wt.Sw.ElapsedMilliseconds; since = (Get-S62Since); late = $late; chats = $n }
    }
    if ($wt.Frame -and $wt.Lists) {
        [System.Windows.Media.CompositionTarget]::remove_Rendering($script:S62Render)
        $script:S62Render = $null
        $script:S62Watch = $null
    }
}

$script:S62Shows = 0
$script:S62Backs = 0
function Show-S62Console {
    param([string]$Why)
    $script:S62Shows++
    $n = $script:S62Shows
    $was = if ($script:S62H.Console) { [string]$script:S62H.Console.Mode } else { 'none' }
    Watch-S62Frame $Why
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Open-ChatOverlayHeadlessConsole $script:S62H -Activate:$Visible
    Write-S62Log $script:S62Log 'shown' @{ why = $Why; n = $n; was = $was; openMs = $sw.ElapsedMilliseconds; since = (Get-S62Since); mode = [string]$script:S62H.Console.Mode }
    Start-S62After 10000 { param($k) $W = $script:S62H.Console; if ($script:S62Shows -eq $k -and $W -and $W.Mode -eq 'console') { Write-S62Mem 'open+10s' $k } } $n
}

function Exit-S62Console {
    $W = $script:S62H.Console
    if (-not $W -or $W.Mode -ne 'console') { Write-S62Log $script:S62Log 'back' @{ was = $(if ($W) { [string]$W.Mode } else { 'none' }) }; return }
    Exit-ChatOverlayConsoleMode $W
    $script:S62Backs++
    $n = $script:S62Backs
    Write-S62Log $script:S62Log 'back' @{ n = $n; mode = [string]$W.Mode }
    Start-S62After 30000 { param($k) if ($script:S62Backs -eq $k) { Write-S62Mem 'back+30s' $k } } $n
}

function Stop-S62 {
    param([string]$Why)
    Write-S62Log $script:S62Log 'quit' @{ why = $Why; since = (Get-S62Since) }
    try { Stop-ChatOverlayHeadlessConsole $script:S62H } catch {}
    if ($script:S62Frame) { $script:S62Frame.Continue = $false }
}

$script:S62Stdin = [System.IO.StreamReader]::new([Console]::OpenStandardInput())
$script:S62Read = $script:S62Stdin.ReadLineAsync()
function Invoke-S62Stdin {
    $t = $script:S62Read
    if (-not $t -or -not $t.IsCompleted) { return }
    $line = if ($t.IsFaulted -or $t.IsCanceled) { $null } else { $t.Result }
    if ($null -eq $line) { $script:S62Read = $null; Stop-S62 'eof'; return }
    $script:S62Read = $script:S62Stdin.ReadLineAsync()
    $c = $line.Trim()
    Write-S62Log $script:S62Log 'cmd' @{ line = $c }
    switch -CaseSensitive ($c) {
        'show' { Show-S62Console "show $($script:S62Shows + 1)" }
        'back' { Exit-S62Console }
        'quit' { Stop-S62 'quit' }
    }
}

if ($Measure -eq 'cold') { Show-S62Console 'cold' }
else {
    $script:S62PreCloak = -not $env:CHATQ_CLOAK
    $sw.Restart()
    Open-ChatOverlayHeadlessConsole $script:S62H
    Exit-ChatOverlayConsoleMode $script:S62H.Console
    $W = $script:S62H.Console
    if ($script:S62PreCloak -and $W) { foreach ($hw in @($W.Hwnd, $W.CtlHwnd, $W.EdgesHwnd, $W.ChipHwnd, $W.CardHwnd)) { if ($hw -and $hw -ne [IntPtr]::Zero) { [void](Set-S62Cloak $hw $false) } } }
    $script:S62PreCloak = $false
    Write-S62Log $script:S62Log 'warm-ready' @{ since = (Get-S62Since); ms = $sw.ElapsedMilliseconds; mode = $(if ($W) { [string]$W.Mode } else { 'none' }) }
}

$script:S62Frame = [System.Windows.Threading.DispatcherFrame]::new()
$poll = [System.Windows.Threading.DispatcherTimer]::new()
$poll.Interval = [TimeSpan]::FromMilliseconds(100)
$poll.add_Tick({ param($s, $e) try { Invoke-S62Stdin } catch { Write-S62Log $script:S62Log 'error' @{ what = "$($_.Exception.Message)" } } })
$poll.Start()
Start-S62After 1200000 { param($x) Stop-S62 'cap' } $null
[System.Windows.Threading.Dispatcher]::PushFrame($script:S62Frame)
$poll.Stop()
Write-S62Log $script:S62Log 'end' @{ since = (Get-S62Since) }
exit 0
