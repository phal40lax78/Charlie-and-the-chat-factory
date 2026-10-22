<#
S62's automatic run: no input, every window cloaked, nothing activated.
Today's console, in the headless host, against the prototype's, in a
process of its own (s62-console.ps1). About 7 minutes, 15 at most.

    powershell -NoProfile -ExecutionPolicy Bypass -File tests\m9\s62-auto.ps1 [-Root <clone>] [-Runs 6] [-WarmShows 5] [-SettleSeconds 60]

-Root: the clone this file is in, unless given; never the live copy
(Assert-S62Root). Its data/ is set up as the sandbox first
(Set-S62Sandbox), and a sandbox overlay already running there stops the
run before anything starts.

(a) Baseline, today's console: s62-host.ps1 -Mode inproc -Cloak, with
    collect.ps1's stand-in for the panel. The host's private MB after
    -SettleSeconds, no console parts ever loaded; console (overlay-cmd,
    as Send-ChatOverlayCommand writes it) timed to the parts' import and
    to the first frame; MB 10 s open; console-back, MB 30 s on; console
    again, the warm in-host time to the first frame.
(b) The prototype standalone: -Runs cold starts of s62-console.ps1 as the
    host starts one (Start-S62Console), each timed from the spawn to its
    first frame and to its lists filled, its MB 10 s open; run 1 apart,
    runs 2 on as median and max. In the last run -WarmShows re-shows, each
    timed to its frame, and MB 30 s after the last back. One -Measure warm
    start, its first show timed.
(c) The prototype from the host: s62-host.ps1 -Mode spawn -Grant pid
    -Cloak - its MB with no parts, the console it starts (its STARTUPINFO,
    IsWindowVisible and DWM's cloaked at its first frame: drawn, cloaked,
    so visible in IsWindowVisible's sense, never seen), the grant's
    outcome, verb to frame cold and warm, both processes' MB open and 30 s
    after back.
Then data/s62/auto.json and a table, and the decision rule for the cold
time.

Every child's environment is its own (Set-S62Env; -Env for the consoles
this starts: CHATQ_CLOAK, CHATQ_NOFRONT, CHATQ_NOTRAY). The host is
started hidden; the consoles share this process's console, their stdin a
pipe this holds. Only processes this run started are stopped or ended -
each tracked by pid and start time.

This file is ASCII, for the reason tests/run-tests.ps1 gives.
#>
param(
    [string]$Root,
    [int]$Runs = 6,
    [int]$WarmShows = 5,
    [int]$SettleSeconds = 60
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 's62-common.ps1')
if (-not $Root) { $Root = Split-Path -Parent (Split-Path -Parent $here) }
$P = Get-S62Paths $Root
Assert-S62Root $P
Set-S62Sandbox $P
$lockPath = Join-Path $P.Data 'overlay.lock'
$l = try { [System.IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None') } catch { $null }
if (-not $l) { throw "a sandbox overlay already runs in $($P.Data) (its lock is held); not run" }
$l.Dispose()

$cloakEnv = @{ CHATQ_CLOAK = '1'; CHATQ_NOFRONT = '1'; CHATQ_NOTRAY = '1' }
$started = [System.Collections.Generic.List[object]]::new()
$began = Get-Date
function Say([string]$T) { Write-Output ("[{0,5:0}s] {1}" -f ((Get-Date) - $began).TotalSeconds, $T) }
function Add-S62Started {
    param([int]$Id, [string]$What)
    try { $started.Add(@{ Id = $Id; Start = (Get-Process -Id $Id -EA Stop).StartTime; What = $What }) } catch {}
}
function Send-S62Line {
    # a line to a console child's stdin; $false once it has gone
    param($C, [string]$Line)
    try {
        if ($C.HasExited) { return $false }
        $C.StandardInput.WriteLine($Line)
        $C.StandardInput.Flush()
        return $true
    }
    catch { return $false }
}
function Stop-S62Console {
    param($C)
    try { if (-not $C.HasExited) { $C.StandardInput.WriteLine('quit'); $C.StandardInput.Close() } } catch {}
    try { if (-not $C.WaitForExit(10000)) { $C.Kill() } } catch {}
}
function Stop-S62HostRun {
    # the stop verb, as Stop-ChatOverlay sends it; ended after 30 s
    param($Proc)
    if ($Proc.HasExited) { return }
    [void](Send-S62Command $P 'stop')
    if (-not $Proc.WaitForExit(30000)) { try { $Proc.Kill() } catch {} }
}
function Wait-S62Up {
    # the host's lock taken: its pid in overlay.pid
    param($Proc, [int]$TimeoutSec = 60)
    $until = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $until -and -not $Proc.HasExited) {
        $t = try { ([System.IO.File]::ReadAllText($P.PidFile)).Trim() } catch { '' }
        if ($t -eq [string]$Proc.Id) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

$out = [ordered]@{ at = $began.ToString('o'); root = $P.Root; runs = $Runs; warmShows = $WarmShows; settleSeconds = $SettleSeconds }
try {
    # (a) today's console, in the host
    Say "(a) today's console in the host: settling $SettleSeconds s"
    $h = Start-S62Host $P @('-Root', (Format-S62Arg $P.Root), '-Mode', 'inproc', '-Cloak', '-Seconds', '600')
    Add-S62Started $h.Id 'host inproc'
    $hlog = Join-Path $P.S62 "host-$($h.Id).jsonl"
    if (-not (Wait-S62Up $h)) { throw "the inproc host $($h.Id) did not start - see $hlog and data/logs/overlay.log" }
    Start-Sleep -Seconds $SettleSeconds
    $a = [ordered]@{ hostPid = $h.Id; hostMbSettled = (Get-S62PrivateMb $h.Id) }
    $t = Send-S62Command $P 'console'
    $imp = Wait-S62Event $hlog 'import' $t 90
    $fr = Wait-S62Event $hlog 'frame' $t 90
    $a.coldImportMs = if ($imp) { $imp.ms } else { $null }
    $a.coldVerbToFrameMs = if ($fr) { $fr.t - $t } else { $null }
    $a.coldImportToFrameMs = if ($imp -and $fr) { $fr.t - ($imp.t - $imp.ms) } else { $null }
    Start-Sleep -Seconds 10
    $a.hostMbOpen10 = Get-S62PrivateMb $h.Id
    [void](Send-S62Command $P 'console-back')
    Start-Sleep -Seconds 30
    $a.hostMbBack30 = Get-S62PrivateMb $h.Id
    $t = Send-S62Command $P 'console'
    $fr = Wait-S62Event $hlog 'frame' $t 60
    $a.warmVerbToFrameMs = if ($fr) { $fr.t - $t } else { $null }
    Start-Sleep -Seconds 2
    [void](Send-S62Command $P 'console-back')
    Start-Sleep -Seconds 2
    Stop-S62HostRun $h
    $out.baseline = $a
    Say "(a) import $($a.coldImportMs) ms, verb to frame cold $($a.coldVerbToFrameMs) / warm $($a.warmVerbToFrameMs) ms; host MB $($a.hostMbSettled) settled, $($a.hostMbOpen10) open, $($a.hostMbBack30) back+30s"

    # (b) the prototype, standalone
    $rows = [System.Collections.Generic.List[object]]::new()
    for ($i = 1; $i -le $Runs; $i++) {
        Say "(b) cold run $i of $Runs"
        $t0 = Get-S62Ms
        $c = Start-S62Console $P -HostPid $PID -Measure cold -Env $cloakEnv
        Add-S62Started $c.Id "console cold $i"
        $clog = Join-Path $P.S62 "console-$($c.Id).jsonl"
        $st = Wait-S62Event $clog 'start' 0 30
        $fr = Wait-S62Event $clog 'frame' 0 60
        $li = Wait-S62Event $clog 'lists' 0 15
        $f0 = Wait-S62Event $clog 'front' 0 5 { param($e) $e.at -eq 0 }
        $ev = @{}
        foreach ($e in @(Read-S62Log $clog)) { if ($e.ev -in 'parts', 'native', 'peek', 'window' -and -not $ev.ContainsKey($e.ev)) { $ev[$e.ev] = $e } }
        $m10 = Wait-S62Event $clog 'mem' 0 20 { param($e) $e.why -eq 'open+10s' }
        $row = [ordered]@{
            run = $i; pid = $c.Id; spawnToProcMs = $(if ($st) { $st.procStart - $t0 } else { $null })
            partsMs = $(if ($ev.parts) { $ev.parts.since } else { $null }); nativeMs = $(if ($ev.native) { $ev.native.since } else { $null })
            peekMs = $(if ($ev.peek) { $ev.peek.since } else { $null }); windowMs = $(if ($ev.window) { $ev.window.since } else { $null })
            spawnToFrameMs = $(if ($fr) { $fr.t - $t0 } else { $null }); spawnToListsMs = $(if ($li) { $li.t - $t0 } else { $null }); listsLate = $(if ($li) { [bool]$li.late } else { $null })
            mbOpen10 = $(if ($m10) { $m10.privateMb } else { $null })
            visible = $(if ($f0) { $f0.visible } else { $null }); cloaked = $(if ($f0) { $f0.cloaked } else { $null }); active = $(if ($f0) { $f0.active } else { $null })
            startFlags = $(if ($st) { $st.startFlags } else { $null }); startShow = $(if ($st) { $st.startShow } else { $null })
        }
        if ($i -eq $Runs) {
            Say "(b) $WarmShows warm re-shows"
            $warm = [System.Collections.Generic.List[object]]::new()
            $tb = Get-S62Ms
            $alive = Send-S62Line $c 'back'
            Start-Sleep -Seconds 1
            for ($k = 1; $k -le $WarmShows -and $alive; $k++) {
                $tk = Get-S62Ms
                if (-not (Send-S62Line $c 'show')) { $alive = $false; break }
                $fk = Wait-S62Event $clog 'frame' $tk 20 { param($e) $e.why -like 'show*' }
                $warm.Add($(if ($fk) { $fk.t - $tk } else { $null }))
                Start-Sleep -Milliseconds 1700
                $tb = Get-S62Ms
                $alive = Send-S62Line $c 'back'
                Start-Sleep -Seconds 1
            }
            if (-not $alive) { Say "(b) console $($c.Id) gone during the warm re-shows - see $clog"; $out.warmGone = $true }
            $m30 = if ($alive) { Wait-S62Event $clog 'mem' $tb 45 { param($e) $e.why -eq 'back+30s' } } else { $null }
            $out.warmShowsMs = @($warm)
            $out.warmMbBack30 = if ($m30) { $m30.privateMb } else { $null }
        }
        Stop-S62Console $c
        $rows.Add([pscustomobject]$row)
    }
    $out.cold = @($rows)

    Say '(b) one -Measure warm start'
    $c = Start-S62Console $P -HostPid $PID -Measure warm -Env $cloakEnv
    Add-S62Started $c.Id 'console warm'
    $clog = Join-Path $P.S62 "console-$($c.Id).jsonl"
    $wr = Wait-S62Event $clog 'warm-ready' 0 60
    $tk = Get-S62Ms
    $fk = if (Send-S62Line $c 'show') { Wait-S62Event $clog 'frame' $tk 20 { param($e) $e.why -like 'show*' } } else { $null }
    $out.warmStart = [ordered]@{ readyMs = $(if ($wr) { $wr.since } else { $null }); firstShowToFrameMs = $(if ($fk) { $fk.t - $tk } else { $null }) }
    Start-Sleep -Milliseconds 1700
    Stop-S62Console $c

    # (c) the prototype from the host
    Say "(c) the prototype from the host: settling $SettleSeconds s"
    $h = Start-S62Host $P @('-Root', (Format-S62Arg $P.Root), '-Mode', 'spawn', '-Grant', 'pid', '-Cloak', '-Seconds', '600')
    Add-S62Started $h.Id 'host spawn'
    $hlog = Join-Path $P.S62 "host-$($h.Id).jsonl"
    if (-not (Wait-S62Up $h)) { throw "the spawn host $($h.Id) did not start - see $hlog and data/logs/overlay.log" }
    Start-Sleep -Seconds $SettleSeconds
    $b = [ordered]@{ hostPid = $h.Id; hostMbNoParts = (Get-S62PrivateMb $h.Id) }
    $t = Send-S62Command $P 'console'
    $op = Wait-S62Event $hlog 'open' $t 30
    if ($op) {
        $b.child = $op.child; $b.allow = $op.allow; $b.lastError = $op.lastError; $b.spawnMs = $op.ms; $b.sinceVerbMs = $op.sinceVerb
        try { $cp = Get-Process -Id $op.child -EA Stop; if ($cp.StartTime -ge $h.StartTime) { Add-S62Started $op.child 'console from the host' } } catch {}
        $clog = Join-Path $P.S62 "console-$($op.child).jsonl"
        $st = Wait-S62Event $clog 'start' 0 30
        $fr = Wait-S62Event $clog 'frame' 0 60
        $f0 = Wait-S62Event $clog 'front' 0 5 { param($e) $e.at -eq 0 }
        $b.coldVerbToFrameMs = if ($fr) { $fr.t - $t } else { $null }
        $b.startFlags = if ($st) { $st.startFlags } else { $null }
        $b.startShow = if ($st) { $st.startShow } else { $null }
        $b.visible = if ($f0) { $f0.visible } else { $null }
        $b.cloaked = if ($f0) { $f0.cloaked } else { $null }
        $b.active = if ($f0) { $f0.active } else { $null }
        Start-Sleep -Seconds 10
        $b.hostMbOpen10 = Get-S62PrivateMb $h.Id
        $b.childMbOpen10 = Get-S62PrivateMb $op.child
        [void](Send-S62Command $P 'console-back')
        Start-Sleep -Seconds 2
        $t = Send-S62Command $P 'console'
        $fr = Wait-S62Event $clog 'frame' $t 30 { param($e) $e.why -like 'show*' }
        $b.warmVerbToFrameMs = if ($fr) { $fr.t - $t } else { $null }
        Start-Sleep -Milliseconds 1700
        [void](Send-S62Command $P 'console-back')
        Start-Sleep -Seconds 30
        $b.hostMbBack30 = Get-S62PrivateMb $h.Id
        $b.childMbBack30 = Get-S62PrivateMb $op.child
    }
    else { $b.error = 'no open logged in 30 s' }
    Stop-S62HostRun $h
    $out.fromHost = $b
}
catch {
    # what was measured is still saved, with why the rest was not
    $out.error = "$($_.Exception.Message)"
    if ($rows -and -not $out.Contains('cold')) { $out.cold = @($rows) }
    Say "stopped early: $($out.error)"
}
finally {
    # $proc, never $p: names are not case-sensitive, and $P is the paths
    foreach ($s in $started) {
        try { $proc = Get-Process -Id $s.Id -EA Stop; if ($proc.StartTime -eq $s.Start) { $proc.Kill(); Say "ended $($s.What) ($($s.Id))" } } catch {}
    }
}

# the decision on the cold time: runs 2 on
$later = @($out.cold | Where-Object { $_.run -ge 2 } | ForEach-Object { $_.spawnToFrameMs } | Where-Object { $null -ne $_ })
$laterLists = @($out.cold | Where-Object { $_.run -ge 2 } | ForEach-Object { $_.spawnToListsMs } | Where-Object { $null -ne $_ })
$med = Get-S62Median $later
$max = if ($later.Count) { ($later | Measure-Object -Maximum).Maximum } else { $null }
$out.coldStats = [ordered]@{
    run1FrameMs = $(if ($out.cold.Count) { $out.cold[0].spawnToFrameMs } else { $null })
    run1ListsMs = $(if ($out.cold.Count) { $out.cold[0].spawnToListsMs } else { $null })
    frameMedianMs = $med; frameMaxMs = $max
    listsMedianMs = (Get-S62Median $laterLists); listsMaxMs = $(if ($laterLists.Count) { ($laterLists | Measure-Object -Maximum).Maximum } else { $null })
    warmShowMedianMs = (Get-S62Median @($out.warmShowsMs | Where-Object { $null -ne $_ }))
}
$out.decision = if ($null -eq $med) { 'no cold times - see data/s62/console-*.jsonl' }
elseif ($med -le 2000 -and $max -le 3000) { 'exit on close (KeepMinutes 0)' } else { 'warm 15 (KeepMinutes 15)' }
$out.endedSeconds = [int]((Get-Date) - $began).TotalSeconds
$json = Join-Path $P.S62 'auto.json'
[System.IO.File]::WriteAllText($json, (ConvertTo-Json -InputObject $out -Depth 6), $script:S62Utf8)

Write-Output ''
Write-Output 'Cold runs of s62-console.ps1 (ms from the spawn; parts..window from its own start):'
$out.cold | Format-Table run, spawnToProcMs, partsMs, nativeMs, peekMs, windowMs, spawnToFrameMs, spawnToListsMs, mbOpen10, visible, cloaked, startFlags -AutoSize | Out-String -Width 200 | Write-Output
$cs = $out.coldStats
$bl = $out.baseline
$fh = $out.fromHost
$rowsOut = @(
    [pscustomobject]@{ what = 'today: host MB, no parts (settled)'; value = $bl.hostMbSettled }
    [pscustomobject]@{ what = 'today: parts import ms'; value = $bl.coldImportMs }
    [pscustomobject]@{ what = 'today: import to first frame ms'; value = $bl.coldImportToFrameMs }
    [pscustomobject]@{ what = 'today: verb to first frame ms, cold / warm'; value = "$($bl.coldVerbToFrameMs) / $($bl.warmVerbToFrameMs)" }
    [pscustomobject]@{ what = 'today: host MB open 10 s / back 30 s'; value = "$($bl.hostMbOpen10) / $($bl.hostMbBack30)" }
    [pscustomobject]@{ what = 'standalone: run 1 frame / lists ms'; value = "$($cs.run1FrameMs) / $($cs.run1ListsMs)" }
    [pscustomobject]@{ what = 'standalone: runs 2+ frame median / max ms'; value = "$($cs.frameMedianMs) / $($cs.frameMaxMs)" }
    [pscustomobject]@{ what = 'standalone: runs 2+ lists median / max ms'; value = "$($cs.listsMedianMs) / $($cs.listsMaxMs)" }
    [pscustomobject]@{ what = 'standalone: warm re-show ms'; value = (@($out.warmShowsMs) -join ', ') }
    [pscustomobject]@{ what = 'standalone: MB 30 s after back, warm'; value = $out.warmMbBack30 }
    [pscustomobject]@{ what = 'standalone: -Measure warm ready / first show ms'; value = "$($out.warmStart.readyMs) / $($out.warmStart.firstShowToFrameMs)" }
    [pscustomobject]@{ what = 'from host: host MB, no parts ever'; value = $fh.hostMbNoParts }
    [pscustomobject]@{ what = 'from host: allow / lastError'; value = "$($fh.allow) / $($fh.lastError)" }
    [pscustomobject]@{ what = 'from host: verb to frame cold / warm ms'; value = "$($fh.coldVerbToFrameMs) / $($fh.warmVerbToFrameMs)" }
    [pscustomobject]@{ what = 'from host: child STARTUPINFO flags / show'; value = "$($fh.startFlags) / $($fh.startShow)" }
    [pscustomobject]@{ what = 'from host: IsWindowVisible / cloaked / active'; value = "$($fh.visible) / $($fh.cloaked) / $($fh.active)" }
    [pscustomobject]@{ what = 'from host: host / child MB open 10 s'; value = "$($fh.hostMbOpen10) / $($fh.childMbOpen10)" }
    [pscustomobject]@{ what = 'from host: host / child MB back 30 s'; value = "$($fh.hostMbBack30) / $($fh.childMbBack30)" }
)
$rowsOut | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
Write-Output 'Decision rules:'
Write-Output "  cold median (runs 2+) <= 2.0 s and max <= 3 s => exit on close (KeepMinutes 0); else warm 15:  $($out.decision)"
Write-Output '  allow=false on hand steps 1-3 => Rust ASFW_ANY for console verbs: s62-hand.ps1'
Write-Output '  allow=true but not in front cold, while warm is in front => warm: s62-hand.ps1'
Write-Output '  step 6 in front and step 5 not => charlie -Console grants overlay.pid: s62-hand.ps1'
Write-Output "Saved $json ($($out.endedSeconds) s)."
