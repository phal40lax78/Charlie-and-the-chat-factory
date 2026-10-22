<#
The native panel end to end with no real input (TESTING.md, M9a): the
release chatq-overlay.exe on a data folder of its own, hidden
(CHATQ_CLOAK), with no tray (CHATQ_NOTRAY) and never in front
(CHATQ_NOFRONT); a synthetic overlay.json each second, shaped as the
headless host writes it (Invoke-ChatOverlayCollectLoop); the panel driven through
CHATQ_PANEL_DRIVE (native/overlay/src/app/pointer.rs, App::drive_line);
what it says read back from overlay-cmd and overlay-ui.json. An open runs a
stub Show-ChatFresh that ends 15. -Minutes > 0 is the soak instead: the
stream alone, no drive, the panel's private bytes sampled each 5 s. It
stops only the process it started.
#>
param([Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][string]$Data, [double]$Minutes = 0)
$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $Data) { Remove-Item -LiteralPath $Data -Recurse -Force }
New-Item -ItemType Directory -Force $Data | Out-Null
$drive = Join-Path $Data 'drive'
$cmdFile = Join-Path $Data 'overlay-cmd'
$uiFile = Join-Path $Data 'overlay-ui.json'
$stub = Join-Path $Data 'stub.ps1'
Set-Content -LiteralPath $stub -Value 'function Show-ChatFresh { param([Parameter(ValueFromRemainingArguments = $true)]$Rest) @{ ExitCode = 15 } }'
$since = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$sid = [guid]::NewGuid().ToString()
$script:n = 0
$script:events = @()
$script:commands = @()

function Write-Snap {
    $script:n++
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $row = [ordered]@{ key = "s:$sid"; kind = 'session'; status = 'idle'; where = 'here'; sessionId = $sid; title = "loop $($script:n % 7)"; cwd = 'C:\nowhere\m9-loop-leaf' }
    $snap = [ordered]@{
        schema = 1; version = '0.0.0'; pid = $PID; at = $now; header = @{}; counts = @{}; config = @{}
        commands = @($script:commands); rows = @(@($row) + @(1..11 | ForEach-Object { [ordered]@{ key = "s:$sid-$_"; kind = 'session'; status = 'idle'; where = 'here'; sessionId = "$sid-$_"; title = "more $_"; cwd = 'C:\nowhere\m9-loop-leaf' } })); recent = @(); recentMore = @(); events = @($script:events)
        ui = [ordered]@{ spin = $false; console = $script:console; closing = $script:closing; script = $stub; claudeHome = (Join-Path $Data 'claude'); tabs = @() }
    }
    $tmp = Join-Path $Data 'overlay.json.tmp'
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json $snap -Depth 8 -Compress))
    Move-Item -LiteralPath $tmp (Join-Path $Data 'overlay.json') -Force
}
function Get-Ui { try { Get-Content -LiteralPath $uiFile -Raw | ConvertFrom-Json } catch { $null } }
function Get-Cmd { if (Test-Path -LiteralPath $cmdFile) { [IO.File]::ReadAllText($cmdFile) } else { '' } }
function Wait-For([scriptblock]$Ok, [int]$Ms = 5000) {
    $t = [Diagnostics.Stopwatch]::StartNew()
    while (-not (& $Ok) -and $t.ElapsedMilliseconds -lt $Ms) { Start-Sleep -Milliseconds 100; if ($t.ElapsedMilliseconds % 1000 -lt 100) { Write-Snap } }
    [bool](& $Ok)
}
function Send-Drive([string]$Line) {
    Write-Snap
    [IO.File]::WriteAllText($drive, $Line)
    $null = Wait-For { -not (Test-Path -LiteralPath $drive) }
    Start-Sleep -Milliseconds 300
}
$script:pass = 0
$script:fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { $script:pass++; "PASS $Name" } else { $script:fail++; "FAIL $Name : $Detail" }
}
# The panel's windows as Windows has them, read, never changed: each of
# the process's shown top-level windows with its place and extended
# styles, and the main screen's work area - in physical pixels, as the
# panel places itself, whatever this process's own DPI awareness
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class LoopWin {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(POINT p, uint flags);
    [DllImport("user32.dll")] static extern bool GetMonitorInfoW(IntPtr m, ref MONITORINFO i);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct MONITORINFO { public int Size; public RECT Monitor, Work; public uint Flags; }
    static IntPtr Aware() { try { return SetThreadDpiAwarenessContext(new IntPtr(-4)); } catch (EntryPointNotFoundException) { return IntPtr.Zero; } }
    static void Back(IntPtr was) { if (was != IntPtr.Zero) SetThreadDpiAwarenessContext(was); }
    public static List<long[]> Windows(int pid) {
        var all = new List<long[]>();
        var was = Aware();
        try {
            EnumWindows((h, l) => {
                uint p; RECT r;
                GetWindowThreadProcessId(h, out p);
                if (p == pid && IsWindowVisible(h) && GetWindowRect(h, out r))
                    all.Add(new long[] { r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top, GetWindowLongPtr(h, -20).ToInt64() });
                return true;
            }, IntPtr.Zero);
        } finally { Back(was); }
        return all;
    }
    public static int[] MainWork() {
        var was = Aware();
        try {
            var i = new MONITORINFO(); i.Size = Marshal.SizeOf(typeof(MONITORINFO));
            GetMonitorInfoW(MonitorFromPoint(new POINT(), 1), ref i);
            return new[] { i.Work.Left, i.Work.Top, i.Work.Right, i.Work.Bottom };
        } finally { Back(was); }
    }
}
'@
# the panel's own window: the shown one of ours where it says the panel is
function Get-PanelWin {
    $u = Get-Ui
    if (-not $u -or -not $u.drawn) { return $null }
    $at = @($u.drawn.pos[0])
    foreach ($w in @([LoopWin]::Windows($script:p.Id))) {
        if ($w[0] -eq $at[0] -and $w[1] -eq $at[1]) { return [pscustomobject]@{ X = $w[0]; Y = $w[1]; W = $w[2]; H = $w[3]; Ex = $w[4] } }
    }
    $null
}
function Format-Win($W) { if ($W) { 'window {0},{1} {2}x{3} exstyle 0x{4:x8}' -f $W.X, $W.Y, $W.W, $W.H, $W.Ex } else { "no window at $(ConvertTo-Json @((Get-Ui).drawn.pos) -Compress)" } }
function Get-State { try { Get-Content -LiteralPath (Join-Path $Data 'overlay-state.json') -Raw | ConvertFrom-Json } catch { $null } }
# the panel's own log, read while the panel still writes it
function Get-PanelLog {
    $f = Join-Path $Data 'logs\overlay-panel.log'
    if (-not (Test-Path -LiteralPath $f)) { return '' }
    $s = [IO.File]::Open($f, 'Open', 'Read', 'ReadWrite, Delete')
    try { ([IO.StreamReader]::new($s)).ReadToEnd() } finally { $s.Dispose() }
}
# the main screen's top right, as the panel puts itself with no place of
# its own (Get-ChatOverlayPlacement): 16 px in from the work area's corner
function Test-TopRight($W) { $a = [LoopWin]::MainWork(); $W -and $W.X + $W.W -eq $a[2] - 16 -and $W.Y -eq $a[1] + 16 }
$script:console = $false
$script:closing = $false
# a panel started on the data folder, driven unless soaking: the host's
# commands before this start left (--since)
function Start-Panel([int64]$Since = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) {
    $psi = [Diagnostics.ProcessStartInfo]::new($Exe, ('"' + $Data + '" --since ' + $Since))
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    foreach ($k in 'CHATQ_CLOAK', 'CHATQ_NOTRAY', 'CHATQ_NOFRONT') { $psi.Environment[$k] = '1' }
    if ($Minutes -le 0) { $psi.Environment['CHATQ_PANEL_DRIVE'] = $drive }
    Write-Snap
    $script:p = [Diagnostics.Process]::Start($psi)
    $script:started += @($script:p)
}
$script:started = @()
$script:events = @([ordered]@{ id = 'L-1'; at = $since; kind = 'balloon'; title = 'Loop'; text = 'loop balloon'; icon = 'Info'; ms = 3000 },
    [ordered]@{ id = 'L-2'; at = $since; kind = 'said'; said = 'done'; text = 'loop said'; tone = 'dim'; ms = 5000; about = "s:$sid" })
$script:commands = @([ordered]@{ id = 1; at = $since - 5000; verb = 'hide' }, [ordered]@{ id = 2; at = $since + 1; verb = 'collapse' })
Start-Panel $since
$p = $script:p
try {
    if ($Minutes -gt 0) {
        $t = [Diagnostics.Stopwatch]::StartNew()
        $max = 0L; $first = 0L; $last = 0L; $samples = 0
        while ($t.Elapsed.TotalMinutes -lt $Minutes -and -not $p.HasExited) {
            if ($script:n % 10 -eq 0) { $script:events = @([ordered]@{ id = "S-$($script:n)"; at = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); kind = 'said'; said = 'done'; text = "soak $($script:n)"; tone = 'dim'; ms = 4000; about = "s:$sid" }) }
            Write-Snap
            if ($script:n % 5 -eq 0) {
                $p.Refresh(); $last = $p.PrivateMemorySize64; $samples++
                if ($t.Elapsed.TotalSeconds -ge 60 -and -not $first) { $first = $last }
                if ($last -gt $max) { $max = $last }
            }
            Start-Sleep -Milliseconds 1000
        }
        $mb = { param($b) [Math]::Round($b / 1MB, 2) }
        "soak: $([Math]::Round($t.Elapsed.TotalMinutes, 1)) min, $samples samples, private bytes at 1 min $(& $mb $first) MB, max $(& $mb $max) MB, final $(& $mb $last) MB, exited early: $($p.HasExited)"
        Check 'soak: the panel stayed up' (-not $p.HasExited)
    }
    else {
        $ok = Wait-For { $u = Get-Ui; $u -and $u.drawn -and (ConvertTo-Json $u.drawn.said -Compress) -like '*loop said*' -and @($u.seen) -contains 'L-1' } 10000
        $u = Get-Ui
        Check 'started: drawn, the events seen, a command before --since left, one after done and said done' (
            $ok -and -not $u.drawn.hidden -and $u.drawn.collapsed -and @($u.seen) -contains 'L-1' -and (ConvertTo-Json $u.drawn.said -Compress) -like '*loop said*' -and
            @($u.done) -contains 2 -and @($u.done) -notcontains 1) (ConvertTo-Json $u -Compress -Depth 6)
        $w = Get-PanelWin; $s = Get-State
        Check 'no place of its own: the main screen''s top right, kept in overlay-state.json' ((Test-TopRight $w) -and $s.x -eq $w.X -and $s.y -eq $w.Y) "$(Format-Win $w) / work $([LoopWin]::MainWork() -join ',') / state $($s.x),$($s.y)"
        $script:commands += [ordered]@{ id = 3; at = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); verb = 'expand' }
        $ok = Wait-For { $u = Get-Ui; $u -and -not $u.drawn.collapsed }
        Check 'a host command: expand' $ok
        Send-Drive "hover s:$sid"
        $ok = Wait-For { (Get-Cmd) -match "(?m) card s:$sid$" -and (Get-Ui).drawn.chip }
        $u = Get-Ui
        Check 'hover a tile: the chip shows, its card asked for' ($ok -and $u.drawn.chip) "$(Get-Cmd) / $(ConvertTo-Json $u.drawn.chip -Compress)"
        Send-Drive 'click open'
        $ok = Wait-For { (Get-Cmd) -match "(?m) opened s:$sid 15 none$" } 30000
        Check 'click open: the stub child ran, its end sent as opened 15 none' $ok (Get-Cmd)
        Send-Drive 'hover -'
        Send-Drive 'click gear'
        $u = Get-Ui
        Check 'click gear: the settings box opens' ([bool]$u.drawn.box) (ConvertTo-Json $u.drawn.box -Compress)
        Send-Drive 'set opacity 0.5'
        $ok = Wait-For { (Get-Cmd) -match '(?m) config opacity 0\.50$' }
        Check 'a slider, after its rest: config opacity 0.50' $ok (Get-Cmd)
        Send-Drive 'click theme:light'
        $ok = Wait-For { (Get-Cmd) -match '(?m) config theme light$' }
        Check 'a theme choice: config theme light' $ok (Get-Cmd)
        Send-Drive 'click gear'
        Send-Drive 'edge s -100'
        $ok = Wait-For { (Get-Cmd) -match '(?m) config maxRows [0-9]+$' }
        Check 'the south edge dragged up: config maxRows' $ok (Get-Cmd)
        foreach ($c in @(@('click again', 'refresh'), @('click close', 'close'), @('hotkey console', 'console-key'), @('click max', 'console'))) {
            Send-Drive $c[0]
            $ok = Wait-For { (Get-Cmd) -match "(?m) $($c[1])$" }
            Check "$($c[0]): $($c[1]) sent" $ok
        }
        # A10's balloon: the reset ask's, clicked while it is up, asks for
        # the console, as the WPF tray's does (no tray here: the panel logs
        # the balloon it would show)
        $script:events += @([ordered]@{ id = 'L-3'; at = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); kind = 'balloon'; title = 'Loop'; text = 'loop ask'; icon = 'Info'; ms = 3000; click = 'ask' })
        $up = Wait-For { (Get-PanelLog) -match 'ui: balloon ask' }
        $was = ([regex]::Matches((Get-Cmd), '(?m) console$')).Count
        Send-Drive 'balloon-click'
        $ok = Wait-For { ([regex]::Matches((Get-Cmd), '(?m) console$')).Count -gt $was }
        Check 'an ask''s balloon clicked: console sent' ($up -and $ok) "$(Get-Cmd) / balloon up: $up"
        # A4: on top, never activated, no taskbar button, clicks through
        # while locked and not unlocked - by the window's own styles - and a
        # drag's place kept
        $w = Get-PanelWin
        Check 'the window: topmost, no-activate, a tool window, click-through while locked' (
            $w -and ($w.Ex -band 0x8) -and ($w.Ex -band 0x08000000) -and ($w.Ex -band 0x80) -and -not ($w.Ex -band 0x40000) -and ($w.Ex -band 0x20) -and ($w.Ex -band 0x80000)) (Format-Win $w)
        Send-Drive 'menu lock'
        $ok = Wait-For { $u = Get-Ui; $u -and -not $u.drawn.locked }
        $w = Get-PanelWin
        Check 'unlocked from the menu: clicks reach it, kept in overlay-state.json' ($ok -and $w -and -not ($w.Ex -band 0x20) -and (Get-State).locked -eq $false) (Format-Win $w)
        $from = @((Get-Ui).drawn.pos[0])
        Send-Drive 'move -40 30'
        $ok = Wait-For { $w = Get-PanelWin; $w -and $w.X -eq $from[0] - 40 -and $w.Y -eq $from[1] + 30 }
        $s = Get-State
        Check 'dragged by -40,30: the window there, its place kept' ($ok -and $s.x -eq $from[0] - 40 -and $s.y -eq $from[1] + 30) "$(Format-Win (Get-PanelWin)) / from $($from -join ',') / state $($s.x),$($s.y)"
        Send-Drive 'menu lock'
        $ok = Wait-For { $u = Get-Ui; $u -and $u.drawn.locked }
        $w = Get-PanelWin
        Check 'locked again: click-through again' ($ok -and $w -and ($w.Ex -band 0x20) -and (Get-State).locked -eq $true) (Format-Win $w)
        # B2's half here: hidden while the host's console shows, its hotkey
        # there asking for the panel back
        $script:console = $true
        $ok = Wait-For { $u = Get-Ui; $u -and -not $u.drawn.shown -and -not (Get-PanelWin) }
        Check 'the host''s console up: the panel hidden' $ok (ConvertTo-Json (Get-Ui).drawn -Compress -Depth 4)
        $was = ([regex]::Matches((Get-Cmd), '(?m) console-back$')).Count
        Send-Drive 'hotkey'
        $ok = Wait-For { ([regex]::Matches((Get-Cmd), '(?m) console-back$')).Count -gt $was }
        Check 'its hotkey in the console: console-back sent' $ok (Get-Cmd)
        $script:console = $false
        $ok = Wait-For { $u = Get-Ui; $u -and $u.drawn.shown -and (Get-PanelWin) }
        Check 'the console gone: the panel back' $ok (ConvertTo-Json (Get-Ui).drawn -Compress -Depth 4)
        # A11's half here: hidden while closing by hand, a tray click then
        # the host's, to take the close back
        $script:closing = $true
        $ok = Wait-For { $u = Get-Ui; $u -and -not $u.drawn.shown -and -not (Get-PanelWin) }
        Check 'closing by hand: the panel hidden' $ok (ConvertTo-Json (Get-Ui).drawn -Compress -Depth 4)
        $was = ([regex]::Matches((Get-Cmd), '(?m) show$')).Count
        Send-Drive 'tray-left'
        $ok = Wait-For { ([regex]::Matches((Get-Cmd), '(?m) show$')).Count -gt $was }
        Check 'a tray click while closing: show sent to the host' $ok (Get-Cmd)
        $script:closing = $false
        $ok = Wait-For { $u = Get-Ui; $u -and $u.drawn.shown -and (Get-PanelWin) }
        Check 'the close taken back: the panel shown' $ok (ConvertTo-Json (Get-Ui).drawn -Compress -Depth 4)
        # B12: out of a full screen's way, unless shown by hand during it
        Send-Drive 'full-screen on'
        $ok = Wait-For { $u = Get-Ui; $u -and $u.drawn.fullHidden -and -not $u.drawn.shown -and -not (Get-PanelWin) }
        Check 'a full screen: the panel steps aside' ($ok -and (Get-PanelLog) -match 'a full screen - out of its way') (ConvertTo-Json (Get-Ui).drawn -Compress -Depth 4)
        Send-Drive 'tray-left'
        $ok = Wait-For { $u = Get-Ui; $u -and $u.drawn.shown -and -not $u.drawn.fullHidden }
        Start-Sleep -Milliseconds 2500
        $u = Get-Ui
        Check 'shown by hand during it: it stays shown' ($ok -and $u.drawn.shown -and -not $u.drawn.fullHidden -and -not $u.drawn.hidden -and (Get-PanelWin)) (ConvertTo-Json $u.drawn -Compress -Depth 4)
        Send-Drive 'full-screen off'
        Start-Sleep -Milliseconds 1500
        Send-Drive 'full-screen on'
        $ok = Wait-For { $u = Get-Ui; $u -and $u.drawn.fullHidden -and -not $u.drawn.shown }
        Send-Drive 'full-screen off'
        $ok2 = Wait-For { $u = Get-Ui; $u -and -not $u.drawn.fullHidden -and $u.drawn.shown -and (Get-PanelWin) }
        Check 'the next full screen: aside again; gone, the panel back' ($ok -and $ok2 -and (Get-PanelLog) -match 'the full screen is gone') (ConvertTo-Json (Get-Ui).drawn -Compress -Depth 4)
        # and each answer the query gives, through the real query's reading
        # of it (win32::full_screen_of): busy and a presentation are a full
        # screen, an app's own and a failed query not
        foreach ($c in @(@('2', $true), @('7', $false), @('4', $true), @('fail', $false))) {
            Send-Drive "full-screen $($c[0])"
            $ok = Wait-For { $u = Get-Ui; $u -and [bool]$u.drawn.fullHidden -eq $c[1] -and [bool]$u.drawn.shown -ne $c[1] }
            Check "the query answering $($c[0]): $(if ($c[1]) { 'aside' } else { 'shown' })" $ok (ConvertTo-Json (Get-Ui).drawn -Compress -Depth 4)
        }
        Send-Drive 'full-screen off'
        Send-Drive 'click min'
        $u = Get-Ui
        Check 'click min: the panel hides, kept in overlay-state.json' ($u.drawn.hidden -and (Get-Content -Raw (Join-Path $Data 'overlay-state.json')) -match '"hidden":\s*true') (ConvertTo-Json $u.drawn -Compress -Depth 4)
    }
    $p.StandardInput.Close()
    Check 'stdin closed: the panel quits' ($p.WaitForExit(10000))
    if ($Minutes -le 0) {
        # A4's place past the vectors' function (Get-ChatOverlayPlacement):
        # kept for the next start, the menu's top right, and a place off
        # every screen brought back onto the main one
        $statePath = Join-Path $Data 'overlay-state.json'
        $s = Get-State
        $kept = @($s.x, $s.y)
        $s.hidden = $false
        [IO.File]::WriteAllText($statePath, (ConvertTo-Json $s -Compress))
        # started again as the host starts it, with its first --since: the
        # commands it had said were done gone from the list, one sent while
        # it was down acted on
        $script:commands = @([ordered]@{ id = 4; at = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); verb = 'expand' })
        Start-Panel $since
        $ok = Wait-For { $w = Get-PanelWin; $w -and $w.X -eq $kept[0] -and $w.Y -eq $kept[1] } 10000
        Check 'started again: where it was left' $ok "$(Format-Win (Get-PanelWin)) / kept $($kept -join ',')"
        $ok = Wait-For { $u = Get-Ui; $u -and (@($u.done) -join ',') -eq '4' }
        Check 'started again with the first --since: a command sent while it was down done, and only that' $ok (ConvertTo-Json (Get-Ui) -Compress -Depth 6)
        Send-Drive 'menu reset'
        $ok = Wait-For { Test-TopRight (Get-PanelWin) }
        $w = Get-PanelWin; $s = Get-State
        Check 'Move to top right from the menu: there, kept' ($ok -and $s.x -eq $w.X -and $s.y -eq $w.Y) "$(Format-Win $w) / work $([LoopWin]::MainWork() -join ',') / state $($s.x),$($s.y)"
        $p.StandardInput.Close()
        $null = $p.WaitForExit(10000)
        $s.x = -50000; $s.y = -50000
        [IO.File]::WriteAllText($statePath, (ConvertTo-Json $s -Compress))
        Start-Panel
        $ok = Wait-For { Test-TopRight (Get-PanelWin) } 10000
        $w = Get-PanelWin; $s = Get-State
        Check 'a place off every screen: back on the main one''s top right, said and kept' (
            $ok -and (Get-PanelLog) -match 'moved back onto a screen from -50000,-50000' -and $s.x -eq $w.X -and $s.y -eq $w.Y) "$(Format-Win $w) / state $($s.x),$($s.y)"
        $p.StandardInput.Close()
        Check 'stdin closed again: the panel quits' ($p.WaitForExit(10000))
    }
}
finally {
    foreach ($q in $script:started) { if (-not $q.HasExited) { $q.Kill(); 'killed our own panel' } }
}
"loopback: $script:pass passed, $script:fail failed"
exit $script:fail
