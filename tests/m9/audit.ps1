<#
The M9 plan's sandbox audit, per process: the real headless host
(tests/m9/collect.ps1 -Headless, variant b) runs for -Seconds in a sandbox
of its own under an ETW trace of the kernel's file events
(Microsoft-Windows-Kernel-File) and process starts and exits
(Microsoft-Windows-Kernel-Process). Its process tree - the host, its
panel, and anything either starts - is followed from each one's start to
its exit, and every file event of theirs that may write - a create that
is no plain open, a write, a delete, a rename - is held against the data
root, <Root>\tool\data. No other process is in the trace's reading at
all, so no other program needs listing.

Two kinds of event are not a write, and are listed apart: a create of a
file or folder already there before the run (FILE_CREATE, which then
fails - the engine's and Windows' own make-if-missing calls on the
profile's folders and catroot), and a paging write (IRP_PAGING_IO) - the
cache putting on disk what another process wrote to a file one of the
tree's has open to read, the chats' transcripts above all; the tool
writes through no mapped file, so any write of its own is a plain one.

    powershell -NoProfile -ExecutionPolicy Bypass -File tests\m9\audit.ps1 -Root <folder> [-Seconds 120] [-UiExe <chatq-overlay.exe>] [-Hotkey <keys>] [-ConsoleHotkey <keys>]

Needs an elevated shell: logman starts the trace (-ets). Accepted outside
the data root: powershell.exe's own engine files, which it writes for any
script it runs - its startup profile data, its module analysis cache and
the AppLocker probe files in TEMP. Nothing else is: not CryptoAPI's URL
cache, nor any other file a process of the tree writes.
-UiExe runs the real panel in place of the stand-in, and it shows its
window - TESTING.md's Tier 1 - with no hotkeys unless -Hotkey and
-ConsoleHotkey give some (collect.ps1's safety config), so it never takes
a live overlay's. -Root wants a short path: the tool's C#
compiles work under its data/tmp only below 200 characters.

Prints one JSON object; the exit code is 0 when the tree wrote nothing
outside the data root but the engine's files, the host ended on its
passes, and the seam log is empty, else 1.

This file is ASCII, for the reason tests/run-tests.ps1 gives.
#>
param(
    [Parameter(Mandatory)][string]$Root,
    [int]$Seconds = 120,
    [string]$UiExe,
    [ValidatePattern('^[A-Za-z0-9+]+$')][string]$Hotkey = 'none',
    [ValidatePattern('^[A-Za-z0-9+]+$')][string]$ConsoleHotkey = 'none',
    [string]$Session = 'm9audit'
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Root)).TrimEnd([char]92)
$null = New-Item -ItemType Directory -Path $Root -Force
$tool = Join-Path $Root 'tool'
$data = Join-Path $tool 'data'
$etl = Join-Path $Root 'audit.etl'

# collect.ps1 copies the tool into <Root>\tool on its first run, outside
# the data root: made here, before the trace, as collect.ps1 makes it
$checkout = Split-Path -Parent (Split-Path -Parent $here)
if (-not (Test-Path -LiteralPath (Join-Path $tool 'Charlie-and-the-chat-factory.ps1'))) {
    $null = New-Item -ItemType Directory -Path $tool -Force
    Copy-Item -LiteralPath (Join-Path $checkout 'Charlie-and-the-chat-factory.ps1') -Destination $tool
    Copy-Item -LiteralPath (Join-Path $checkout 'src') -Destination $tool -Recurse
}
foreach ($f in 'seam-calls.log', 'm9-host.out') { Remove-Item -LiteralPath (Join-Path $data $f) -Force -EA SilentlyContinue }
Remove-Item -LiteralPath $etl -Force -EA SilentlyContinue

$lm = Join-Path $env:SystemRoot 'System32\logman.exe'
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$null = & $lm start $Session -p Microsoft-Windows-Kernel-File 0x1E80 0x4 -o $etl -ets -bs 1024 -nb 64 512 -max 3000
if ($LASTEXITCODE) { throw "logman start: exit $LASTEXITCODE - an elevated shell is needed, and no trace named $Session running" }
$hostPid = 0
$hung = $false
$started = Get-Date
try {
    $null = & $lm update trace $Session -p Microsoft-Windows-Kernel-Process 0x10 0x4 -ets
    if ($LASTEXITCODE) { throw "logman update: exit $LASTEXITCODE" }
    Start-Sleep -Seconds 1
    $argv = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $here 'collect.ps1')`"",
        '-Root', "`"$Root`"", '-Headless', '-Seconds', [string]$Seconds, '-Hotkey', $Hotkey, '-ConsoleHotkey', $ConsoleHotkey)
    if ($UiExe) { $argv += @('-UiExe', "`"$UiExe`"") }
    # no redirection: a file this process opens, the host's tree would
    # write through a handle the trace never saw opened
    $started = Get-Date
    $p = Start-Process -FilePath $ps -PassThru -WindowStyle Hidden -ArgumentList $argv
    $hostPid = $p.Id
    # below normal, as the plan's builds: other runs share this PC
    try { $p.PriorityClass = 'BelowNormal' } catch {}
    if (-not $p.WaitForExit(($Seconds + 180) * 1000)) { $hung = $true; try { $p.Kill() } catch {} }
    Start-Sleep -Seconds 2
}
finally { $null = & $lm stop $Session -ets }

# the tree: the host, and each process one in it started, from its start
# to its exit (a pid given again later is another process)
$fields = { param($e) $h = @{}; foreach ($d in @(([xml]$e.ToXml()).Event.EventData.Data)) { $h[[string]$d.Name] = [string]$d.'#text' }; $h }
$tree = @{}
$tree[[int]$hostPid] = [pscustomobject]@{ Pid = [int]$hostPid; Image = 'powershell.exe (the host)'; From = $started.AddSeconds(-5); To = $null }
$procXp = "*[System[Provider[@Name='Microsoft-Windows-Kernel-Process'] and (EventID=1 or EventID=2)]]"
foreach ($e in @(Get-WinEvent -Path $etl -Oldest -FilterXPath $procXp -EA SilentlyContinue)) {
    $f = & $fields $e
    $id = [int]$f['ProcessID']
    if ($e.Id -eq 1) {
        $par = $tree[[int]$f['ParentProcessID']]
        if ($par -and -not $par.To -and -not $tree[$id]) {
            $tree[$id] = [pscustomobject]@{ Pid = $id; Image = (Split-Path -Leaf $f['ImageName']); From = $e.TimeCreated; To = $null }
        }
    }
    elseif ($tree[$id] -and -not $tree[$id].To -and $e.TimeCreated -ge $tree[$id].From) { $tree[$id].To = $e.TimeCreated }
}

$dataRel = $data.Substring(2)            # no drive: the trace names \Device\HarddiskVolumeN\...
$profRel = [regex]::Escape($env:USERPROFILE.Substring(2))
$engineRx = "^$profRel\\AppData\\Local\\Microsoft\\Windows\\PowerShell\\(StartupProfileData-(Non)?Interactive|ModuleAnalysisCache)$" +
    "|^$profRel\\AppData\\Local\\Temp\\__PSScriptPolicyTest_[a-z0-9]+\.[a-z0-9]+\.(ps1|psm1)$"
$split = { param($n) if ($n -match '^(\\Device\\HarddiskVolume\d+)(\\.*)?$') { , @($Matches[1], [string]$Matches[2]) } else { $null } }
$dataDev = $null
$fo = @{}                                # FileObject -> its name, from its create
$out = [System.Collections.Generic.List[object]]::new()
$failedCreates = @{}
$flushes = @{}
$engine = @{}
$devices = @{}
$counts = @{ create = 0; write = 0; path = 0; inside = 0 }
$n = 0
$place = {
    param($name)
    $d = & $split $name
    if (-not $d) { return 'device' }
    if ($d[0] -eq $dataDev -and ($d[1] -ieq $dataRel -or $d[1].StartsWith("$dataRel\", [StringComparison]::OrdinalIgnoreCase))) { return 'inside' }
    if ($d[1] -match $engineRx) { return 'engine' }
    return 'outside'
}
$hold = {
    param($procId, $what, $name, $at)
    $where = & $place $name
    switch ($where) {
        'inside' { $counts.inside++ }
        'engine' { $engine[(& $split $name)[1]] = 1 + [int]$engine[(& $split $name)[1]] }
        'device' {
            $dv = (($name -split '\\')[0..2] -join '\')
            $devices[$dv] = 1 + [int]$devices[$dv]
            # a share's file is a write off this PC
            if ($name -like '\Device\Mup\*') { $out.Add([pscustomobject]@{ pid = $procId; image = $tree[$procId].Image; ev = $what; path = $name; at = $at.ToString('HH:mm:ss.fff') }) }
        }
        'outside' { $out.Add([pscustomobject]@{ pid = $procId; image = $tree[$procId].Image; ev = $what; path = (& $split $name)[1]; at = $at.ToString('HH:mm:ss.fff') }) }
    }
}
$pids = @($tree.Keys)
$fileXp = "*[System[Provider[@Name='Microsoft-Windows-Kernel-File'] and (" + (($pids | ForEach-Object { "Execution[@ProcessID=$_]" }) -join ' or ') + ')]]'
$events = @(Get-WinEvent -Path $etl -Oldest -FilterXPath $fileXp -EA SilentlyContinue)
# the files this process opened that the host's tree writes through - the
# console it was started with - named from this process's own creates
$ownXp = "*[System[Provider[@Name='Microsoft-Windows-Kernel-File'] and (EventID=12 or EventID=30) and Execution[@ProcessID=$PID]]]"
foreach ($e in @(Get-WinEvent -Path $etl -Oldest -FilterXPath $ownXp -EA SilentlyContinue)) { $fo[[string]$e.Properties[1].Value] = [string]$e.Properties[6].Value }
# where on this PC a trace's path is: the data root's volume is its drive
$onDisk = { param($rest) "$($data.Substring(0, 2))$rest" }
# the data root's volume, from the creates under it: the host writes
# overlay.json there each pass
foreach ($e in $events) {
    if ($e.Id -notin 12, 30) { continue }
    $d = & $split ([string]$e.Properties[6].Value)
    if ($d -and $d[1].StartsWith("$dataRel\", [StringComparison]::OrdinalIgnoreCase)) { $dataDev = $d[0]; break }
}
foreach ($e in $events) {
    $procId = [int]$e.ProcessId
    $t = $tree[$procId]
    if (-not $t -or $e.TimeCreated -lt $t.From -or ($t.To -and $e.TimeCreated -gt $t.To.AddSeconds(1))) { continue }
    $n++
    $pr = $e.Properties
    switch ($e.Id) {
        { $_ -in 12, 30 } {
            $fobj = [string]$pr[1].Value
            $opts = [int64]$pr[3].Value
            $name = [string]$pr[6].Value
            $fo[$fobj] = $name
            # CreateOptions' top byte is the disposition: 1 opens what is
            # there; anything else may make or overwrite it, as may
            # FILE_DELETE_ON_CLOSE (0x1000) and a create-new (30)
            $disp = ($opts -shr 24) -band 0xFF
            if ($e.Id -eq 30 -or $disp -ne 1 -or ($opts -band 0x1000)) {
                $counts.create++
                # FILE_CREATE (2) of what was there before the run fails
                $d = & $split $name
                if ($disp -eq 2 -and $d -and $d[0] -eq $dataDev -and ($opts -band 0x1000) -eq 0 -and (& $place $name) -eq 'outside') {
                    $full = & $onDisk $d[1]
                    $was = try { if ([IO.Directory]::Exists($full)) { [IO.Directory]::GetCreationTime($full) } elseif ([IO.File]::Exists($full)) { [IO.File]::GetCreationTime($full) } } catch { $null }
                    if ($was -and $was -lt $started) { $failedCreates[$d[1]] = 1 + [int]$failedCreates[$d[1]]; continue }
                }
                & $hold $procId ("create disp=$disp opts=0x{0:x}" -f $opts) $name $e.TimeCreated
            }
        }
        16 {
            $counts.write++
            $fobj = [string]$pr[2].Value
            $name = $fo[$fobj]
            $fl = [int64]$pr[6].Value
            # IRP_PAGING_IO: the cache's flush, not a WriteFile of the tree's -
            # through a file object of the cache's own, often, which no
            # create of the tree's named
            if (($fl -band 0x2) -and (-not $name -or (& $place $name) -eq 'outside')) {
                $k = if ($name) { (& $split $name)[1] } else { '<a file object no create of the tree named>' }
                $flushes[$k] = 1 + [int]$flushes[$k]
                continue
            }
            if (-not $name) { $out.Add([pscustomobject]@{ pid = $procId; image = $t.Image; ev = ('write ioflags=0x{0:x} size {1}' -f $fl, $pr[5].Value); path = "<file object $fobj, opened before the trace or by a process outside the tree>"; at = $e.TimeCreated.ToString('HH:mm:ss.fff') }); continue }
            & $hold $procId ('write ioflags=0x{0:x}' -f $fl) $name $e.TimeCreated
        }
        { $_ -in 26, 27, 28 } {
            $counts.path++
            & $hold $procId "path-op $($e.Id)" ([string]$pr[$pr.Count - 1].Value) $e.TimeCreated
        }
    }
}

$seamLog = Join-Path $data 'seam-calls.log'
$seamCalls = @(if (Test-Path -LiteralPath $seamLog) { [IO.File]::ReadAllLines($seamLog) })
$hostOut = @(if (Test-Path -LiteralPath (Join-Path $data 'm9-host.out')) { [IO.File]::ReadAllLines((Join-Path $data 'm9-host.out')) })
$endedOk = [bool]($hostOut | Where-Object { $_ -match '^m9 host: ended \(max\)$' })
$report = [ordered]@{
    seconds          = $Seconds
    panel            = $(if ($UiExe) { $UiExe } else { 'the stand-in' })
    hotkeys          = "$Hotkey, $ConsoleHotkey"
    hung             = $hung
    dataDevice       = $dataDev
    tree             = @($tree.Values | Sort-Object From | ForEach-Object { "$($_.Pid) $($_.Image) $($_.From.ToString('HH:mm:ss')) to $(if ($_.To) { $_.To.ToString('HH:mm:ss') } else { '-' })" })
    fileEvents       = $n
    mayWrite         = $counts
    engineFiles      = @($engine.GetEnumerator() | Sort-Object Name | ForEach-Object { "x$($_.Value) $($_.Name)" })
    createsOfWhatWas = @($failedCreates.GetEnumerator() | Sort-Object Name | ForEach-Object { "x$($_.Value) $($_.Name)" })
    pagingFlushes    = @($flushes.GetEnumerator() | Sort-Object Name | Select-Object -First 40 | ForEach-Object { "x$($_.Value) $($_.Name)" })
    devices          = @($devices.GetEnumerator() | Sort-Object Name | ForEach-Object { "x$($_.Value) $($_.Name)" })
    outside          = $out.Count
    outsideFirst     = @($out | Group-Object pid, image, ev, path | Sort-Object Count -Descending | Select-Object -First 40 | ForEach-Object { "x$($_.Count) $($_.Name)" })
    seamCalls        = $seamCalls
    host             = $hostOut
}
$report | ConvertTo-Json -Depth 4
$ok = -not $hung -and $endedOk -and $dataDev -and $out.Count -eq 0 -and $seamCalls.Count -eq 0
exit $(if ($ok) { 0 } else { 1 })
