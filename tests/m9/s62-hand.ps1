<#
S62's one hand step: the prototype console (s62-console.ps1, started by
the sandbox host s62-host.ps1 -Mode spawn -Grant pid) brought up six ways
on the real panel, each asked of you, then whether it came to the front.
About 5 minutes. Run it from the terminal you usually use - its process
chain is part of what is measured:

    powershell -NoProfile -ExecutionPolicy Bypass -File tests\m9\s62-hand.ps1 [-Root <clone>] [-Exe C:\t12\release\chatq-overlay.exe]

-Root: the clone this file is in, unless given; never the live copy. Its
data/ is the sandbox (Set-S62Sandbox): the panel at 300,300, its hotkey
none and the console's Ctrl+Alt+Shift+F10, so your own overlay's
Ctrl+Alt+Shift+O and Q stay its own. The sandbox's panel and tray icon
show beside your own overlay's; nothing of yours is touched. No CHATQ_CLOAK,
CHATQ_NOFRONT or CHATQ_NOTRAY here: the front and the tray are what is
tested.

Each step: press Enter, then within -WindowSeconds do what it says.
    1  click the sandbox panel's console button              cold
    2  press Ctrl+Alt+Shift+F10                              cold
    3  the tray icon's menu (the one that showed the S62 balloon), Open console   cold
    4  click the panel's console button again                warm
    5  Enter only: this runs the sandbox's charlie -Console  cold
    6  Enter only: AllowSetForegroundWindow(data/overlay.pid), then charlie -Console   cold
Then asked: did the console come to the front with the cursor in its
text box? Then console-back (Send-ChatOverlayCommand), and its row: the
host's grant (allow, lastError), the console's own look at +0, +500 and
+1500 ms from its first frame (in front / active / prompt focused), and
the overlay-cmd line's time to that frame. A cold step's back also ends
the console (data/s62/host-cold, s62-host.ps1), so the next one starts it.

At the end a table, this terminal's parent chain, data/s62/hand.json, and
the decision rules; the host stopped with the stop verb (Stop-ChatOverlay),
and anything it started still there ended.

This process loads the tool, with CHATQ_OVERLAY set in its own
environment (Set-S62Env), for charlie -Console and the stop - as a shell
has it, no key bindings or watches. Run with -File only: dot-sourced it
refuses, and run with & from a shell its variables are put back as they
were at the end (Save-S62Env, Restore-S62Env).

Click only what a step says. A chat row or chip clicked by mistake opens
nothing (ChatCodeSeam, CHATQ_CODE a file that is not there). Leave the
console's own close and Esc alone: the step's console-back hides it, and
a console closed by hand leaves the host believing it open.

This file is ASCII, for the reason tests/run-tests.ps1 gives.
#>
param(
    [string]$Root,
    [string]$Exe = 'C:\t12\release\chatq-overlay.exe',
    [int]$WindowSeconds = 10
)

$ErrorActionPreference = 'Stop'
if ($MyInvocation.InvocationName -eq '.') { throw 'run s62-hand.ps1 with powershell -File (tests/m9/s62-README.md), not dot-sourced' }
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 's62-common.ps1')
if (-not $Root) { $Root = Split-Path -Parent (Split-Path -Parent $here) }
$P = Get-S62Paths $Root
Assert-S62Root $P
if (-not [System.IO.File]::Exists($Exe)) { throw "no panel at $Exe" }
Set-S62Sandbox $P
$l = try { [System.IO.File]::Open((Join-Path $P.Data 'overlay.lock'), 'OpenOrCreate', 'ReadWrite', 'None') } catch { $null }
if (-not $l) { throw "a sandbox overlay already runs in $($P.Data) (its lock is held); not run" }
$l.Dispose()
Remove-Item -LiteralPath $P.ColdFlag -Force -EA SilentlyContinue
Initialize-S62Native

$envWas = Save-S62Env
# put back on a stop before the try below as well (a trap is the whole
# scope's, so it may run before $envWas is set)
trap { if ($envWas) { Restore-S62Env $envWas }; break }
Set-S62Env $P
. $P.Tool
Set-StrictMode -Off
Assert-S62Loaded $P $script:ChatqData $script:ChatClaudeHome
$ErrorActionPreference = 'Continue'

function Get-S62Chain {
    # this process and its parents, up to the terminal and past it
    $chain = @()
    $id = $PID
    for ($i = 0; $i -lt 10 -and $id; $i++) {
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -EA SilentlyContinue
        if (-not $p) { break }
        $chain += "$($p.Name) ($id)"
        $id = [int]$p.ParentProcessId
    }
    return ($chain -join ' <- ')
}
function Format-S62Front($E) {
    if (-not $E) { return '-' }
    $yn = { param($b) if ($b) { 'y' } else { 'n' } }
    return "$(& $yn $E.fg)/$(& $yn $E.active)/$(& $yn $E.focus)"
}

$started = [System.Collections.Generic.List[object]]::new()
$rows = [System.Collections.Generic.List[object]]::new()
$h = $null
try {
    $h = Start-S62Host $P @('-Root', (Format-S62Arg $P.Root), '-Mode', 'spawn', '-Grant', 'pid', '-ConsoleVisible', '-UiExe', (Format-S62Arg $Exe), '-Seconds', '1800')
    $started.Add(@{ Id = $h.Id; Start = (Get-Process -Id $h.Id).StartTime; What = 'host' })
    $hlog = Join-Path $P.S62 "host-$($h.Id).jsonl"
    $up = $false
    for ($i = 0; $i -lt 150 -and -not $up -and -not $h.HasExited; $i++) {
        Start-Sleep -Milliseconds 200
        $t = try { ([System.IO.File]::ReadAllText($P.PidFile)).Trim() } catch { '' }
        $up = $t -eq [string]$h.Id
    }
    if (-not $up) { throw "the sandbox host $($h.Id) did not start - see $hlog and $($P.Data)\logs\overlay.log" }
    Start-Sleep -Seconds 5
    Write-Host ''
    Write-Host "The sandbox's panel is at 300,300, and its tray icon showed 'S62: this is the test icon'." -ForegroundColor Cyan
    Write-Host 'Your own overlay is not touched. Each step: press Enter, then do what it says.' -ForegroundColor Cyan

    $steps = @(
        @{ N = 1; How = 'panel'; Next = 'cold'; Say = "click the sandbox panel's console button (the maximize-looking one), on the panel at 300,300" }
        @{ N = 2; How = 'hotkey'; Next = 'cold'; Say = 'press Ctrl+Alt+Shift+F10' }
        @{ N = 3; How = 'tray'; Next = 'warm'; Say = 'right-click the tray icon that showed the S62 balloon and pick Open console' }
        @{ N = 4; How = 'panel warm'; Next = 'cold'; Say = "click the sandbox panel's console button again (the console is warm now)" }
        @{ N = 5; How = 'charlie'; Next = 'cold'; Say = 'nothing: Enter only - this script runs the sandbox''s charlie -Console' }
        @{ N = 6; How = 'grant + charlie'; Next = 'cold'; Say = 'nothing: Enter only - this script grants overlay.pid the front, then runs charlie -Console' }
    )
    foreach ($s in $steps) {
        if ($h.HasExited) { Write-Host 'the sandbox host has ended - no more steps' -ForegroundColor Yellow; break }
        Write-Host ''
        [void](Read-Host "Step $($s.N) of 6: press Enter, then within $WindowSeconds s $($s.Say)")
        $t0 = Get-S62Ms
        $g6 = $null
        if ($s.How -in 'charlie', 'grant + charlie') {
            if (-not (Test-ChatOverlayAlive)) { Write-Host '  the sandbox overlay is not running - skipped' -ForegroundColor Yellow }
            else {
                if ($s.How -eq 'grant + charlie') {
                    $op6 = [int](([System.IO.File]::ReadAllText($P.PidFile)).Trim())
                    $g6 = Grant-S62Front $op6
                    Write-Host "  AllowSetForegroundWindow($op6): $($g6.Allow), lastError $($g6.LastError)" -ForegroundColor DarkGray
                }
                charlie -Console
            }
        }
        $op = Wait-S62Event $hlog 'open' $t0 $WindowSeconds
        $fr = $null; $f = @{}; $cmd = $null
        if ($op) {
            $clog = Join-Path $P.S62 "console-$($op.child).jsonl"
            # tracked only if started since the host was: a pid the host
            # logged may be gone and reused by now (s62-auto.ps1 the same)
            try {
                $cp = Get-Process -Id $op.child -EA Stop
                if ($cp.StartTime -ge $h.StartTime -and -not @($started | Where-Object { $_.Id -eq $op.child -and $_.Start -eq $cp.StartTime }).Count) { $started.Add(@{ Id = $op.child; Start = $cp.StartTime; What = 'console' }) }
            }
            catch {}
            $fr = Wait-S62Event $clog 'frame' $t0 20
            [void](Wait-S62Event $clog 'front' $t0 6 { param($e) $e.at -eq 1500 })
            foreach ($e in @(Read-S62Log $clog)) { if ($e.ev -eq 'front' -and [int64]$e.t -ge $t0 -and -not $f.ContainsKey([int]$e.at)) { $f[[int]$e.at] = $e } }
            $cmd = @(Read-S62Log $hlog | Where-Object { $_.ev -eq 'cmd' -and $_.verb -in 'console', 'console-key' -and $_.stamp -and [int64]$_.stamp -ge ($t0 - 1000) }) | Select-Object -Last 1
        }
        else { Write-Host "  no open in $WindowSeconds s" -ForegroundColor Yellow }
        # five tries, then '?': Read-Host gives '' at once with no input
        $ans = ''
        for ($try = 0; $try -lt 5 -and $ans -notin 'y', 'n'; $try++) { $ans = ([string](Read-Host '  Did the console come to the front with the cursor in its text box? y/n')).Trim().ToLowerInvariant() }
        if ($ans -notin 'y', 'n') { $ans = '?' }
        if ($s.Next -eq 'cold') { [System.IO.File]::WriteAllText($P.ColdFlag, '') }
        $tb = Get-S62Ms
        Send-ChatOverlayCommand 'console-back'
        $bk = Wait-S62Event $hlog 'back' $tb 6
        if ($bk -and $bk.cold) { [void](Wait-S62Event $hlog 'child-gone' $tb 10) }
        Remove-Item -LiteralPath $P.ColdFlag -Force -EA SilentlyContinue
        Start-Sleep -Milliseconds 500
        $row = [pscustomobject][ordered]@{
            step = $s.N; how = $s.How; route = $(if ($op) { $op.route } else { '' }); verb = $(if ($op) { $op.verb } else { '' })
            allow = $(if ($op) { $op.allow } else { $null }); lastError = $(if ($op) { $op.lastError } else { $null }); fgOwner = $(if ($op) { $op.fgOwnerPid } else { $null })
            answer = $ans; at0 = (Format-S62Front $f[0]); at500 = (Format-S62Front $f[500]); at1500 = (Format-S62Front $f[1500])
            clickToFrameMs = $(if ($fr -and $cmd) { $fr.t - [int64]$cmd.stamp } else { $null }); sinceVerbMs = $(if ($op) { $op.sinceVerb } else { $null })
            grant6 = $(if ($g6) { "$($g6.Allow)/$($g6.LastError)" } else { '' })
        }
        $rows.Add($row)
        $row | Format-List | Out-String | Write-Host
    }
}
finally {
    if ($h -and -not $h.HasExited) {
        Write-Host 'Stopping the sandbox host (the stop verb) ...' -ForegroundColor DarkGray
        [void](Stop-ChatOverlay)
        if (-not $h.WaitForExit(20000)) { try { $h.Kill() } catch {} }
    }
    # $proc, never $p: names are not case-sensitive, and $P is the paths
    foreach ($s in $started) {
        try { $proc = Get-Process -Id $s.Id -EA Stop; if ($proc.StartTime -eq $s.Start) { $proc.Kill(); Write-Host "ended $($s.What) ($($s.Id))" -ForegroundColor DarkGray } } catch {}
    }
    Remove-Item -LiteralPath $P.ColdFlag -Force -EA SilentlyContinue
    Restore-S62Env $envWas
}

$chain = Get-S62Chain
$front = { param($r) $r -and $r.answer -eq 'y' }
$byStep = @{}
foreach ($r in $rows) { $byStep[[int]$r.step] = $r }
$first3 = @(1, 2, 3 | ForEach-Object { $byStep[$_] } | Where-Object { $_ })
$rules = [System.Collections.Generic.List[string]]::new()
if ($first3.Count -and @($first3 | Where-Object { $_.allow -eq $false }).Count -eq $first3.Count) { $rules.Add('allow=false on steps 1-3 => Rust ASFW_ANY for console verbs') }
else { $rules.Add('allow=false on steps 1-3 => Rust ASFW_ANY for console verbs: not met') }
$r1 = $byStep[1]; $r4 = $byStep[4]
if ($r1 -and $r1.allow -eq $true -and -not (& $front $r1) -and (& $front $r4)) { $rules.Add('allow=true but not in front cold, warm in front => warm') }
else { $rules.Add('allow=true but not in front cold, warm in front => warm: not met') }
if ((& $front $byStep[6]) -and -not (& $front $byStep[5])) { $rules.Add('step 6 in front and step 5 not => charlie -Console grants overlay.pid') }
else { $rules.Add('step 6 in front and step 5 not => charlie -Console grants overlay.pid: not met') }

$json = Join-Path $P.S62 'hand.json'
$out = [ordered]@{ at = (Get-Date).ToString('o'); root = $P.Root; exe = $Exe; terminalChain = $chain; steps = @($rows); rules = @($rules) }
[System.IO.File]::WriteAllText($json, (ConvertTo-Json -InputObject $out -Depth 6), $script:S62Utf8)

Write-Host ''
Write-Host 'Front at +0/+500/+1500 ms: in front / active / prompt focused.'
$rows | Format-Table step, how, route, allow, lastError, fgOwner, answer, at0, at500, at1500, clickToFrameMs, grant6 -AutoSize | Out-String -Width 200 | Write-Host
Write-Host "Terminal chain: $chain"
Write-Host 'Decision rules:'
foreach ($r in $rules) { Write-Host "  $r" }
Write-Host '  cold median (runs 2+) <= 2.0 s and max <= 3 s => exit on close: s62-auto.ps1'
Write-Host "Saved $json."
