<#
S62's sandbox headless host: Start-ChatOverlayHeadlessHost whole, on the
clone's own data/, with its console either today's (-Mode inproc) or the
prototype's, s62-console.ps1 in a process of its own (-Mode spawn).

Not run with -File: started by Start-S62Host (s62-common.ps1), hidden,
as an encoded command that dot-sources this file, the way the overlay's
launch dot-sources the tool (Get-ChatOverlayLaunch) - so this file, the
tool and the console's parts, which Import-ChatOverlayConsoleParts loads
into the global scope, all run in that one scope.

    . tests\m9\s62-host.ps1 -Root <clone> [-Mode spawn|inproc] [-UiExe <exe>] [-Grant pid|none] [-ConsoleVisible] [-Cloak] [-Seconds N]

-Root: the clone; its data/ is the sandbox, which s62-auto.ps1 and
s62-hand.ps1 set up (Set-S62Sandbox). -UiExe: the panel; without it,
collect.ps1's stand-in, which reads its stdin and draws nothing. -Cloak:
the automatic run's environment (Set-S62Env). -Seconds: a stop of its own
that long after it starts, whatever its starter does (900).

Stubbed and seamed as collect.ps1 -Headless (Set-S62Seams). Its log,
data/s62/host-<pid>.jsonl (Write-S62Log): start, cmd (each console,
console-key, console-back and stop line of overlay-cmd as a pass takes
it, with its stamp), balloon, open, back, end. On its first pass, after
Update-ChatOverlayAsk, one balloon for the panel's tray:
'S62: this is the test icon' (Show-ChatOverlayBalloon).

-Mode spawn, the prototype: Import-ChatOverlayConsoleParts is $true and
loads nothing; Open-ChatOverlayHeadlessConsole starts s62-console.ps1 the
first time (Start-S62Console: stdin piped, CreateNoWindow off, no
WindowStyle) and writes it show after, then - -Grant pid -
AllowSetForegroundWindow(its pid), logged with whether it took, its
GetLastError, the process in front and the ms since the verb's
overlay-cmd line; Exit-ChatOverlayConsoleMode writes it back; the waits,
the passes' draws and the stop go to it or nowhere
(Wait-ChatOverlayHeadlessConsole, Update-ChatOverlayHeadlessConsole,
Stop-ChatOverlayHeadlessConsole). The host's own state of the console is
a stand-in hashtable: Mode, Proc, Pid. A back while data/s62/host-cold is
there (s62-hand.ps1's) also ends the console, so the next open is a cold
one.

-Mode inproc, today's console, timed: Import-ChatOverlayConsoleParts
logged (import), and once the parts are in, Open-ChatOverlayHeadlessConsole
wrapped (open) and its first frame after it (frame: the first
CompositionTarget.Rendering). With -Cloak the console never activates
(ChatConsoleFrontSeam a no-op) and no index sync starts
(ChatConsoleNoSync).

This file is ASCII, for the reason tests/run-tests.ps1 gives.
#>
param(
    [Parameter(Mandatory)][string]$Root,
    [ValidateSet('spawn', 'inproc')][string]$Mode = 'spawn',
    [string]$UiExe,
    [ValidateSet('pid', 'none')][string]$Grant = 'pid',
    [switch]$ConsoleVisible,
    [switch]$Cloak,
    [int]$Seconds = 900,
    [int]$IntervalMs = 2000
)

$ErrorActionPreference = 'Stop'
Set-Variable -Name MaximumVariableCount -Value 32768
# In the global scope, as the tool's own code: the parameters under names
# of this file's own, so no function of the tool reading a variable it has
# not set yet finds one of them.
$S62Mode = $Mode; $S62UiExe = $UiExe; $S62Grant = $Grant; $S62ConsoleVisible = [bool]$ConsoleVisible
$S62Cloak = [bool]$Cloak; $S62Seconds = $Seconds; $S62IntervalMs = $IntervalMs; $S62Root = $Root
Remove-Variable -Name Root, Mode, UiExe, Grant, ConsoleVisible, Cloak, Seconds, IntervalMs -EA SilentlyContinue
$S62Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $S62Here 's62-common.ps1')
$S62P = Get-S62Paths $S62Root
Assert-S62Root $S62P
$null = New-Item -ItemType Directory -Path $S62P.S62 -Force
Initialize-S62Native
Set-S62Env $S62P -Cloak:$S62Cloak
$S62Log = Join-Path $S62P.S62 "host-$PID.jsonl"
$S62Deadline = (Get-Date).AddSeconds($S62Seconds)
$S62VerbAt = $null
$S62Ballooned = $false
Write-S62Log $S62Log 'start' @{ mode = $S62Mode; grant = $S62Grant; uiExe = [string]$S62UiExe; cloak = $S62Cloak; consoleVisible = $S62ConsoleVisible }

. $S62P.Tool
Set-StrictMode -Off
Assert-S62Loaded $S62P $script:ChatqData $script:ChatClaudeHome
Set-S62Seams $S62P
if (-not $S62UiExe) {
    $script:ChatOverlayUiSpawnSeam = {
        param($Exe, $Data)
        # findstr with no file reads stdin, and a pattern no line has (collect.ps1)
        $si = [System.Diagnostics.ProcessStartInfo]::new((Join-Path $env:SystemRoot 'System32\findstr.exe'), '/b /c:"~s62~"')
        $si.UseShellExecute = $false
        $si.RedirectStandardInput = $true
        $si.CreateNoWindow = $true
        $si.WorkingDirectory = $HOME
        [System.Diagnostics.Process]::Start($si)
    }
}

function Get-S62SinceVerb {
    # ms from the last console verb's overlay-cmd line to -At
    param([int64]$At)
    if ($S62VerbAt -and $S62VerbAt.At) { return $At - $S62VerbAt.At }
    return $null
}

# Each pass's commands as before, their console lines' stamps noted first;
# a stop of this file's own once -Seconds are up. The file is taken as
# Receive-ChatOverlayCommands takes it, renamed away (to overlay-cmd.s62),
# read, and its lines put back for the real pass to take - so a line a
# shell appends meanwhile goes to a new file the real pass takes too, and
# no line is acted on that is not logged here. Only that same window's
# line can come before the ones put back.
$S62Receive = ${function:Receive-ChatOverlayCommands}
function Receive-ChatOverlayCommands {
    $lines = @()
    $cp = $script:ChatOverlayCmdPath
    $mine = "$cp.s62"
    try {
        if ([System.IO.File]::Exists($cp)) {
            if ([System.IO.File]::Exists($mine)) { [System.IO.File]::Delete($mine) }
            [System.IO.File]::Move($cp, $mine)
            $lines = @([System.IO.File]::ReadAllLines($mine))
            if ($lines.Count) { [System.IO.File]::AppendAllText($cp, (($lines -join "`n") + "`n"), $script:S62Utf8) }
            [System.IO.File]::Delete($mine)
        }
    }
    catch {
        Write-S62Log $S62Log 'cmd-error' @{ what = "$($_.Exception.Message)" }
        # taken but not put back: back as it was, for the real pass
        try { if ([System.IO.File]::Exists($mine) -and -not [System.IO.File]::Exists($cp)) { [System.IO.File]::Move($mine, $cp) } } catch {}
    }
    foreach ($l in $lines) {
        if ($l -match '^(\S+)\s+(console|console-key|console-back|stop)\s*$') {
            $at = ConvertFrom-S62Stamp $Matches[1]
            if ($Matches[2] -in 'console', 'console-key') { $global:S62VerbAt = @{ Verb = $Matches[2]; At = $at } }
            Write-S62Log $S62Log 'cmd' @{ verb = $Matches[2]; stamp = $at; lag = $(if ($at) { (Get-S62Ms) - $at } else { $null }) }
        }
    }
    $v = @(& $S62Receive)
    if ((Get-Date) -ge $S62Deadline -and $v -notcontains 'stop') { Write-S62Log $S62Log 'deadline'; $v += 'stop' }
    $v
}

# the first pass's ask, then the balloon, once
$S62Ask = ${function:Update-ChatOverlayAsk}
function Update-ChatOverlayAsk {
    & $S62Ask @args
    if (-not $S62Ballooned) {
        $global:S62Ballooned = $true
        Show-ChatOverlayBalloon $args[0] 'S62: this is the test icon'
        Write-S62Log $S62Log 'balloon'
    }
}

if ($S62Mode -eq 'spawn') {
    function Import-ChatOverlayConsoleParts { param($Ctx) return $true }

    function Open-ChatOverlayHeadlessConsole {
        param($H, [switch]$Activate)
        $t0 = Get-S62Ms
        $route = 'show'
        try {
            $c = $H.Console
            if (-not $c -or -not $c.Proc -or $c.Proc.HasExited) {
                $route = 'spawn'
                $proc = Start-S62Console $S62P -HostPid $PID -Measure cold -Visible:$S62ConsoleVisible
                $c = @{ Mode = 'panel'; Proc = $proc; Pid = $proc.Id; SpawnAt = $t0; Host = $H }
                $H.Console = $c
            }
            else { $c.Proc.StandardInput.WriteLine('show'); $c.Proc.StandardInput.Flush() }
            $c.Mode = 'console'
            $g = if ($S62Grant -eq 'pid') { Grant-S62Front $c.Pid } else { @{ Allow = $null; LastError = $null } }
            $f = Get-S62Front
            Write-S62Log $S62Log 'open' @{ route = $route; child = $c.Pid; activate = [bool]$Activate; grant = $S62Grant; allow = $g.Allow; lastError = $g.LastError
                fgOwnerPid = $f.Pid; verb = $(if ($S62VerbAt) { $S62VerbAt.Verb } else { '' }); sinceVerb = (Get-S62SinceVerb $t0); ms = (Get-S62Ms) - $t0
            }
        }
        catch { Write-S62Log $S62Log 'open-error' @{ route = $route; what = "$($_.Exception.Message)" } }
        finally { $H.Ctx.PanelConsole = [bool]($H.Console -and $H.Console.Mode -eq 'console') }
    }

    function Exit-ChatOverlayConsoleMode {
        param($H)
        if (-not $H -or $H.Mode -ne 'console') { return }
        try { $H.Proc.StandardInput.WriteLine('back'); $H.Proc.StandardInput.Flush() } catch {}
        $H.Mode = 'panel'
        $cold = [System.IO.File]::Exists($S62P.ColdFlag)
        Write-S62Log $S62Log 'back' @{ child = $H.Pid; cold = $cold }
        # s62-hand.ps1's: the next open a cold one
        if ($cold) {
            try { [System.IO.File]::Delete($S62P.ColdFlag) } catch {}
            Stop-S62Child $H
            if ($H.Host) { $H.Host.Console = $null }
        }
    }

    function Stop-S62Child {
        param($C)
        if (-not $C -or -not $C.Proc) { return }
        try { if (-not $C.Proc.HasExited) { $C.Proc.StandardInput.WriteLine('quit'); $C.Proc.StandardInput.Close() } } catch {}
        try { if (-not $C.Proc.WaitForExit(5000)) { $C.Proc.Kill() } } catch {}
        Write-S62Log $S62Log 'child-gone' @{ child = $C.Pid }
    }

    function Wait-ChatOverlayHeadlessConsole { param($H, [datetime]$Until) return $false }
    function Update-ChatOverlayHeadlessConsole { param($H, $Snap, [switch]$Reload, $Answer) return $false }
    function Stop-ChatOverlayHeadlessConsole {
        param($H)
        Stop-S62Child $H.Console
        $H.Console = $null
    }
}
else {
    $S62Import = ${function:Import-ChatOverlayConsoleParts}
    function Import-ChatOverlayConsoleParts {
        param($Ctx)
        $had = [bool]${function:New-ChatConsole}
        $t0 = Get-S62Ms
        $ok = & $S62Import $Ctx
        if ($ok -and -not $had) {
            Write-S62Log $S62Log 'import' @{ ms = (Get-S62Ms) - $t0; sinceVerb = (Get-S62SinceVerb $t0) }
            Install-S62InprocWrap
        }
        return $ok
    }

    # Once the parts are in - their load defines Open-ChatOverlayHeadlessConsole
    # again, and their own seams' defaults - the wrap and the seams.
    function Install-S62InprocWrap {
        $global:ChatConsoleNoSync = $true
        if ($S62Cloak) { $global:ChatConsoleFrontSeam = { param($w) } }
        Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase
        $global:S62Open = ${function:Open-ChatOverlayHeadlessConsole}
        Set-Item -Path function:global:Open-ChatOverlayHeadlessConsole -Value {
            param($H, [switch]$Activate)
            $t0 = Get-S62Ms
            Watch-S62HostFrame $t0
            & $global:S62Open $H -Activate:$Activate
            Write-S62Log $S62Log 'open' @{ route = 'inproc'; activate = [bool]$Activate; ms = (Get-S62Ms) - $t0; sinceVerb = (Get-S62SinceVerb $t0); mode = $(if ($H.Console) { [string]$H.Console.Mode } else { 'none' }) }
        }
    }

    $S62Render = $null
    function Watch-S62HostFrame {
        param([int64]$OpenAt)
        $global:S62FrameOpenAt = $OpenAt
        if ($S62Render) { return }
        $global:S62Render = [EventHandler] {
            param($s, $e)
            [System.Windows.Media.CompositionTarget]::remove_Rendering($global:S62Render)
            $global:S62Render = $null
            $now = Get-S62Ms
            Write-S62Log $S62Log 'frame' @{ sinceOpen = $now - $global:S62FrameOpenAt; sinceVerb = (Get-S62SinceVerb $now) }
        }
        [System.Windows.Media.CompositionTarget]::add_Rendering($global:S62Render)
    }
}

# as the overlay runs, not stopping at the first error
$ErrorActionPreference = 'Continue'
$S62Why = Start-ChatOverlayHeadlessHost -UiExe $(if ($S62UiExe) { $S62UiExe } else { 's62-stand-in.exe' }) -IntervalMs $S62IntervalMs
Write-S62Log $S62Log 'end' @{ why = [string]$S62Why }
