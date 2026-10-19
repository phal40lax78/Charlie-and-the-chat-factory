# tests/sections/native.ps1: dot-sourced by tests/run-tests.ps1 in its turn,
# never on its own - it uses what the runner and the sections before it set.

# --- the native watcher's launch (native/SPEC.md 4.1, 4.2) -------------------
Section 'native watcher launch'

# Each check runs in a throwaway root of its own, never the sandbox's tool/:
# the paths the launch reads and writes are pointed there and put back.
$nvKeys = 'ChatRoot', 'ChatqData', 'ChatqLockPath', 'ChatqPidPath', 'ChatqConfigPath', 'ChatqLogDir', 'ChatqScriptPath', 'ChatVersion', 'ChatqSpawn'
$nvWas = @{}
foreach ($k in $nvKeys) { $nvWas[$k] = Get-Variable -Name $k -Scope Script -ValueOnly }
$nvFnWas = @{}
foreach ($k in 'Test-ChatqNativeAlive', 'Invoke-ChatqNativePreflight', 'Send-ChatqAlert', 'Get-ChatqConfig', 'Read-ChatqJson', 'Get-ChatqLoaderVersion') { $nvFnWas[$k] = (Get-Item "function:$k").ScriptBlock }

function Enter-NvRoot([string]$Name, [string]$Version) {
    # a root with a fake loader of $Version, as native/crates/chatqd/tests/watch.rs makes one
    $r = Join-Path (Join-Path $sb 'native') $Name
    if (Test-Path -LiteralPath $r) { Remove-Item -LiteralPath $r -Recurse -Force }
    $null = New-Item -ItemType Directory -Path (Join-Path $r 'data') -Force
    $l = Join-Path $r 'Charlie-and-the-chat-factory.ps1'
    [IO.File]::WriteAllText($l, "# a fake loader`r`n`$script:ChatVersion = '$Version'`r`n", $utf8)
    $d = Join-Path $r 'data'
    $script:ChatRoot = $r
    $script:ChatqData = $d
    $script:ChatqLockPath = Join-Path $d 'watcher.lock'
    $script:ChatqPidPath = Join-Path $d 'watcher.pid'
    $script:ChatqConfigPath = Join-Path $d 'config.json'
    $script:ChatqLogDir = Join-Path $d 'logs'
    $script:ChatqScriptPath = $l
    $script:ChatVersion = $Version
    return $r
}
function Exit-NvRoot {
    foreach ($k in $nvKeys) { Set-Variable -Name $k -Scope Script -Value $nvWas[$k] }
    foreach ($k in $nvFnWas.Keys) { Set-Item "function:$k" $nvFnWas[$k] }
    foreach ($n in 'CHATQ_CHATQD', 'CHATQ_ENGINE', 'CHATQ_NATIVE_SEAMS') { Remove-Item "env:$n" -EA SilentlyContinue }
}
function Write-NvJson([string]$Path, $Value) {
    $null = New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 6 -Compress), $utf8)
}
function Read-NvShared([string]$Path) {
    # a log chatqd may be appending to: ReadAllText shares it for reading
    # only, and an append that meets that fails, its line lost
    $s = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite, Delete')
    try { (New-Object IO.StreamReader($s, $utf8)).ReadToEnd() } finally { $s.Dispose() }
}
function Get-NvAgo([double]$Seconds) { (Get-Date).ToUniversalTime().AddSeconds(-$Seconds).ToString('o') }
function Wait-Nv([scriptblock]$What, [int]$Secs = 15) {
    $until = (Get-Date).AddSeconds($Secs)
    while (-not (& $What)) { if ((Get-Date) -gt $until) { return $false }; Start-Sleep -Milliseconds 100 }
    return $true
}
function Get-NvWhys { @((Get-ChatqNativeFuse).Strikes | ForEach-Object { [string]$_.why }) }
# what the probes see, set per check: pids that are a live chatqd, and pids
# alive as something else
$script:nvLive = @()
$script:nvAlive = @()
$nvAliveFake = { param($ProcessId, [switch]$Chatqd) $n = [long]$ProcessId; if ($Chatqd) { $script:nvLive -contains $n } else { ($script:nvLive + $script:nvAlive) -contains $n } }

# --- the decision table, case by case as launch.rs runs it -------------------
# native/vectors/launch.json, which crates/chatq-core/tests/launch_vectors.rs
# reads too: one table, so the two launchers cannot drift apart
$nvVec = [IO.File]::ReadAllText((Join-Path $root 'native\vectors\launch.json'), $utf8) | ConvertFrom-Json
$nvBad = @()
$nvN = 0
try {
    foreach ($c in $nvVec.cases) {
        $nvN++
        $g = $c.given
        $e = $c.expect
        $r = Enter-NvRoot "v$nvN" $nvVec.version
        $nd = Join-Path $script:ChatqData 'native'
        $script:nvLive = @($g.live | Where-Object { $null -ne $_ } | ForEach-Object { [long]$_ })
        $script:nvAlive = @($g.alive | Where-Object { $null -ne $_ } | ForEach-Object { [long]$_ })
        $script:nvPreRan = $false
        $script:nvPreFail = ($g.preflight -eq 'fail')
        $script:nvAlerts = 0
        Set-Item function:Test-ChatqNativeAlive $nvAliveFake
        Set-Item function:Invoke-ChatqNativePreflight { param($Exe, $Version) $script:nvPreRan = $true; if ($script:nvPreFail) { "exit 2, said 'chatqd 0.0.0 x'" } else { $null } }
        Set-Item function:Send-ChatqAlert { $script:nvAlerts++; $true }
        if ($null -ne $g.engine) { $env:CHATQ_ENGINE = $g.engine } else { Remove-Item env:CHATQ_ENGINE -EA SilentlyContinue }
        if ($g.config) { Write-NvJson $script:ChatqConfigPath $g.config }
        $bin = $null
        if ($g.binary) {
            $bin = Join-Path $r 'chatqd-under-test.exe'
            [IO.File]::WriteAllText($bin, 'not a real binary', $utf8)
            $env:CHATQ_CHATQD = $bin
        }
        else { Remove-Item env:CHATQ_CHATQD -EA SilentlyContinue }
        if ($g.verified) {
            $id = Get-ChatqNativeIdentity $bin
            $size = if ($g.verified -eq 'stale') { $id.size + 1 } else { $id.size }
            Write-NvJson (Join-Path $nd 'verified.json') @{ passed = @([ordered]@{ path = $id.path; size = $size; mtime = $id.mtime; at = Get-NvAgo 60 }) }
        }
        if ($g.pending) {
            $pj = [ordered]@{ pid = $g.pending.pid; version = $g.pending.version }
            if ($null -ne $g.pending.ageSeconds) { $pj.at = Get-NvAgo $g.pending.ageSeconds }
            Write-NvJson (Join-Path $nd 'pending.json') $pj
        }
        if ($g.last) { Write-NvJson (Join-Path $nd 'last.json') ([ordered]@{ pid = $g.last.pid; version = $g.last.version; engine = $g.last.engine; state = $g.last.state; at = Get-NvAgo 60 }) }
        if ($g.pidFile) { [IO.File]::WriteAllText($script:ChatqPidPath, "$($g.last.pid)`r`n", $utf8) }
        $before = 0
        if ($g.fuse) {
            $st = @(foreach ($s in $g.fuse.strikes) { [ordered]@{ at = Get-NvAgo ($s.hoursAgo * 3600); why = $s.why; pid = $s.pid } })
            Write-NvJson (Join-Path $nd 'fuse.json') ([ordered]@{ version = $g.fuse.version; strikes = $st; alerted = [bool]$g.fuse.alerted })
            if ($g.fuse.version -ceq $nvVec.version) { $before = $st.Count }
        }
        $lock = if ($g.lockHeld) { [IO.File]::Open($script:ChatqLockPath, 'OpenOrCreate', 'ReadWrite', 'None') } else { $null }
        try { $got = Get-ChatqWatcherEngine }
        finally { if ($lock) { $lock.Dispose() } }
        $whys = @(Get-NvWhys)
        $new = @(if ($whys.Count -gt $before) { $whys[$before..($whys.Count - 1)] })
        $ver = $false
        if ($bin) {
            $id = Get-ChatqNativeIdentity $bin
            $v = Read-ChatqJson (Join-Path $nd 'verified.json')
            $ver = (Test-ChatqNativeVerified $id) -and @($v.passed | Where-Object { [string]$_.path -eq $id.path }).Count -eq 1
        }
        $have = [ordered]@{ engine = $got.Engine; strikes = ($new -join '|'); preflight = $script:nvPreRan
            pending = (Test-Path -LiteralPath (Join-Path $nd 'pending.json')); verified = $ver; alert = ($script:nvAlerts -eq 1)
        }
        $want = [ordered]@{ engine = $e.engine; strikes = (@($e.strikes) -join '|'); preflight = [bool]$e.preflight
            pending = [bool]$e.pending; verified = [bool]$e.verified; alert = [bool]$e.alert
        }
        $diff = @(foreach ($k in $want.Keys) { if ([string]$have[$k] -ne [string]$want[$k]) { "$k=$($have[$k]) not $($want[$k])" } })
        if ($script:nvAlerts -gt 1) { $diff += "$($script:nvAlerts) alerts" }
        if ($e.alert -and -not (Get-ChatqNativeFuse).Alerted) { $diff += 'fuse.json not marked alerted' }
        if ($diff) { $nvBad += "'$($c.name)': $($diff -join ', ') ($($got.Why))" }
        Exit-NvRoot
    }
}
finally { Exit-NvRoot }
Check "the engine decision: all $nvN cases of native/vectors/launch.json, as launch.rs decides them" ($nvN -ge 30 -and -not $nvBad) ($nvBad -join '; ')

# --- with no binary, a launch is what it always was --------------------------
# the sandbox's own root, which has no bin/: no config read, no JSON read,
# no loader read, nothing written, and the seam handed the very launch it was before
$script:nvCfgReads = 0
$script:nvJsonReads = 0
$script:nvLoaderReads = 0
# each file as it is, and each folder by its name alone: a C# compile
# anywhere in the run makes and removes a folder of its own in data/tmp
# (Invoke-ChatCompile), which moves that folder's time and nothing else
$nvFiles = { @(Get-ChildItem -LiteralPath $script:ChatqData -Recurse -Force -EA SilentlyContinue | ForEach-Object { if ($_.PSIsContainer) { $_.FullName } else { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" } }) -join "`n" }
$nvBefore = & $nvFiles
try {
    $script:ChatqSpawn = { param($l) $script:nvGotL = $l; $true }
    Set-Item function:Get-ChatqConfig { $script:nvCfgReads++; & $nvFnWas['Get-ChatqConfig'] }
    Set-Item function:Read-ChatqJson { $script:nvJsonReads++; & $nvFnWas['Read-ChatqJson'] @args }
    Set-Item function:Get-ChatqLoaderVersion { $script:nvLoaderReads++; & $nvFnWas['Get-ChatqLoaderVersion'] @args }
    $nvOk = Start-ChatqWatcherProcess
    $nvCfgAt = $script:nvCfgReads
    $nvJsonAt = $script:nvJsonReads
    $nvLoaderAt = $script:nvLoaderReads
    $nvAfter = & $nvFiles
}
finally { Exit-NvRoot }
$nvPsL = Get-ChatqWatcherLaunch $script:ChatqScriptPath
Check 'with no chatqd, a launch is the PowerShell watcher''s, its launch unchanged, and it reads and writes nothing more' ($nvOk -and
    $script:nvGotL.Engine -eq 'ps' -and $script:nvGotL.Exe -eq $nvPsL.Exe -and $script:nvGotL.Command -eq $nvPsL.Command -and
    ($script:nvGotL.Args -join ' ') -eq ($nvPsL.Args -join ' ') -and $nvCfgAt -eq 0 -and $nvJsonAt -eq 0 -and $nvLoaderAt -eq 0 -and
    -not (Test-Path -LiteralPath (Join-Path $script:ChatqData 'native')) -and $nvAfter -eq $nvBefore) "started $nvOk, engine $($script:nvGotL.Engine), exe $($script:nvGotL.Exe -eq $nvPsL.Exe), command $($script:nvGotL.Command -eq $nvPsL.Command), config read $nvCfgAt, json read $nvJsonAt, loader read $nvLoaderAt, changed: $(@(Compare-Object @($nvBefore -split "`n") @($nvAfter -split "`n") | ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" }) -join '; ')"

# --- the native launch's arguments -------------------------------------------
$nvNl = Get-ChatqWatcherLaunch 'C:\x y\loader.ps1' -Native 'C:\b\chatqd.exe'
$nvCi = [Globalization.CultureInfo]::CurrentCulture
$nvB64 = $nvNl.Args[-1].Replace('-', '+').Replace('_', '/')
$nvB64 += '=' * ((4 - $nvB64.Length % 4) % 4)
$nvCj = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($nvB64)) | ConvertFrom-Json
Check 'the native launch: watch --root --script --ps --culture, its culture this shell''s, base64url with no padding' ($nvNl.Engine -eq 'native' -and
    $nvNl.Exe -eq 'C:\b\chatqd.exe' -and $null -eq $nvNl.Command -and
    ($nvNl.Args[0..6] -join '|') -eq "watch|--root|$($script:ChatRoot)|--script|C:\x y\loader.ps1|--ps|$((Get-Process -Id $PID).Path)" -and
    $nvNl.Args[7] -eq '--culture' -and $nvNl.Args[-1] -notmatch '[=+/]' -and $nvCj.name -eq $nvCi.Name -and
    $nvCj.timeSep -eq $nvCi.DateTimeFormat.TimeSeparator -and $nvCj.groupSep -eq $nvCi.NumberFormat.NumberGroupSeparator) ($nvNl.Args -join ' ')

# --- every strike kind makes this launch the PowerShell watcher's -----------
# a stand-in binary already verified, so only the strike decides
function Enter-NvFake([string]$Name) {
    $r = Enter-NvRoot $Name '1.0.0'
    $b = Join-Path $r 'chatqd-under-test.exe'
    [IO.File]::WriteAllText($b, 'not a real binary', $utf8)
    $env:CHATQ_CHATQD = $b
    Add-ChatqNativeVerified (Get-ChatqNativeIdentity $b)
    $script:nvLive = @()
    $script:nvAlive = @()
    $script:nvAlerts = 0
    $script:nvLaunches = @()
    Set-Item function:Test-ChatqNativeAlive $nvAliveFake
    $script:ChatqSpawn = { param($l) $script:nvLaunches += $l.Engine; $true }
}
$nvNd = { Join-Path $script:ChatqData 'native' }
try {
    Enter-NvFake 'fallback'
    Set-Item function:Send-ChatqAlert { $script:nvAlerts++; $true }
    $nvR = @()
    $nvR += Start-ChatqWatcherProcess                                      # native
    Write-NvJson (Join-Path (& $nvNd) 'pending.json') ([ordered]@{ pid = 4000000001; version = '1.0.0'; at = Get-NvAgo 60 })
    $nvR += Start-ChatqWatcherProcess                                      # no ack
    $nvR += Start-ChatqWatcherProcess                                      # native again
    Remove-Item -LiteralPath (Join-Path (& $nvNd) 'fuse.json')
    Write-NvJson (Join-Path (& $nvNd) 'last.json') ([ordered]@{ pid = 4000000002; version = '1.0.0'; engine = 'native'; state = 'holding'; at = Get-NvAgo 60 })
    [IO.File]::WriteAllText($script:ChatqPidPath, "4000000002`r`n", $utf8)
    $nvR += Start-ChatqWatcherProcess                                      # crash
    $nvCrashWhys = @(Get-NvWhys)
    Remove-Item -LiteralPath (Join-Path (& $nvNd) 'fuse.json'), (Join-Path (& $nvNd) 'verified.json'), $script:ChatqPidPath
    Set-Item function:Invoke-ChatqNativePreflight { param($Exe) "exit 2, said 'chatqd 9.9.9 x'" }
    $nvR += Start-ChatqWatcherProcess                                      # preflight
    $nvPreWhys = @(Get-NvWhys)
    $nvPreLog = [IO.File]::ReadAllText((Join-Path $script:ChatqLogDir 'chatqd.log'), $utf8)
    Remove-Item -LiteralPath (Join-Path (& $nvNd) 'fuse.json')
    Add-ChatqNativeVerified (Get-ChatqNativeIdentity $env:CHATQ_CHATQD)
    $script:ChatqSpawn = { param($l) if ($l.Engine -eq 'native') { throw 'the native start was refused' }; $script:nvLaunches += $l.Engine; $true }
    $nvR += Start-ChatqWatcherProcess                                      # start failed
    $nvStartWhys = @(Get-NvWhys)
}
finally { Exit-NvRoot }
Check 'a launch never acked is a strike, and this launch the PowerShell watcher''s; the next is native again' (($nvLaunches[0..2] -join ',') -eq 'native,ps,native') ($nvLaunches -join ',')
Check 'a native watcher dead holding the lock is a strike, and this launch the PowerShell watcher''s' ($nvLaunches[3] -eq 'ps' -and ($nvCrashWhys -join ',') -eq 'crash') "$($nvLaunches -join ','); $($nvCrashWhys -join ',')"
Check 'a failed preflight is a strike, said in chatqd.log, and this launch the PowerShell watcher''s' ($nvLaunches[4] -eq 'ps' -and ($nvPreWhys -join ',') -eq 'preflight' -and
    $nvPreLog -like "*fuse strike: preflight failed: exit 2, said 'chatqd 9.9.9 x'*") "$($nvLaunches -join ','); $($nvPreWhys -join ',')"
Check 'a native start that throws is a strike, and the same launch then starts the PowerShell watcher' ($nvLaunches[5] -eq 'ps' -and $nvLaunches.Count -eq 6 -and
    ($nvStartWhys -join ',') -eq 'start failed' -and @($nvR | Where-Object { $_ -ne $true }).Count -eq 0 -and $script:nvAlerts -eq 0) "$($nvLaunches -join ','); $($nvStartWhys -join ','); returned $($nvR -join ',')"

# --- the scripts' version on disk, not this process's ------------------------
# a shell or a watcher loaded before an update keeps its old ChatVersion, and
# its launch - a watcher's restart among them - starts the new scripts on
# disk: their bin/ folder, their records, their preflight, as chatqd's
# respawn reads them (launch.rs read_loader_version)
try {
    $r = Enter-NvRoot 'update' '1.0.1'
    $script:ChatVersion = '1.0.0'
    foreach ($v in '1.0.0', '1.0.1') {
        $b = Get-ChatqNativePath $v
        $null = New-Item -ItemType Directory -Path (Split-Path $b -Parent) -Force
        [IO.File]::WriteAllText($b, "chatqd $v", $utf8)
    }
    $nvUpBin = Get-ChatqNativePath '1.0.1'
    $script:nvLive = @()
    $script:nvAlive = @()
    Set-Item function:Test-ChatqNativeAlive $nvAliveFake
    $script:nvPreAsk = @()
    Set-Item function:Invoke-ChatqNativePreflight { param($Exe, $Version) $script:nvPreAsk += "$Version|$Exe"; $null }
    Write-NvJson (Join-Path (& $nvNd) 'pending.json') ([ordered]@{ pid = 4000000005; version = '1.0.1'; at = Get-NvAgo 60 })
    $nvUp1 = Get-ChatqWatcherEngine
    $nvUpFuse = Read-ChatqJson (Join-Path (& $nvNd) 'fuse.json')
    $nvUp2 = Get-ChatqWatcherEngine
    Remove-Item -LiteralPath $script:ChatqScriptPath
    $nvUp3 = Get-ChatqWatcherEngine
}
finally { Exit-NvRoot }
Check 'a launch from a process older than the scripts on disk decides for the scripts: their bin/ folder, strikes and preflight; none readable, PowerShell' ($nvUp1.Engine -eq 'ps' -and
    [string]$nvUpFuse.version -eq '1.0.1' -and @($nvUpFuse.strikes).Count -eq 1 -and $nvUp2.Engine -eq 'native' -and $nvUp2.Exe -eq $nvUpBin -and
    $nvUp2.Version -eq '1.0.1' -and ($script:nvPreAsk -join ',') -eq "1.0.1|$nvUpBin" -and $nvUp3.Engine -eq 'ps' -and $null -eq $nvUp3.Version) "$($nvUp1.Why); fuse $($nvUpFuse | ConvertTo-Json -Compress -Depth 4); $($nvUp2.Engine) $($nvUp2.Exe) $($nvUp2.Version); preflight $($script:nvPreAsk -join ','); $($nvUp3.Engine) $($nvUp3.Why)"

# --- a relative CHATQ_CHATQD -------------------------------------------------
# against the process's folder, as launch.rs's std::path::absolute resolves
# it, never PowerShell's location, which a shell moves on its own
$nvCwdWas = [Environment]::CurrentDirectory
try {
    $r = Enter-NvRoot 'relative' '1.0.0'
    $nvCwd = Join-Path $r 'cwd'
    $nvLoc = Join-Path $r 'loc'
    foreach ($d in $nvCwd, $nvLoc) {
        $null = New-Item -ItemType Directory -Path $d -Force
        [IO.File]::WriteAllText((Join-Path $d 'chatqd-under-test.exe'), $d, $utf8)
    }
    Push-Location -LiteralPath $nvLoc
    [Environment]::CurrentDirectory = $nvCwd
    $env:CHATQ_CHATQD = 'chatqd-under-test.exe'
    Set-Item function:Invoke-ChatqNativePreflight { param($Exe, $Version) $null }
    $nvRelPath = Get-ChatqNativePath
    $nvRel = Get-ChatqWatcherEngine
    $nvRelV = Read-ChatqJson (Join-Path (& $nvNd) 'verified.json')
}
finally {
    [Environment]::CurrentDirectory = $nvCwdWas
    Pop-Location
    Exit-NvRoot
}
$nvRelWant = Join-Path $nvCwd 'chatqd-under-test.exe'
Check 'a relative CHATQ_CHATQD is the process folder''s binary, as chatqd resolves it, not the one at PowerShell''s location' ($nvRelPath -eq $nvRelWant -and
    $nvRel.Engine -eq 'native' -and $nvRel.Exe -eq $nvRelWant -and @($nvRelV.passed).Count -eq 1 -and [string]$nvRelV.passed[0].path -eq $nvRelWant) "path $nvRelPath; $($nvRel.Engine) $($nvRel.Exe) $($nvRel.Why); verified $($nvRelV | ConvertTo-Json -Compress -Depth 4)"

# --- the fuse: 3 strikes in a day, alerted once ------------------------------
# through the real Send-ChatqAlert, whose toast the sandbox's seam catches
$nvToasts = $script:Toasts.Count
try {
    Enter-NvFake 'fuse'
    Write-NvJson (Join-Path (& $nvNd) 'pending.json') ([ordered]@{ pid = 4000000003; version = '1.0.0'; at = Get-NvAgo 60 })
    $null = Start-ChatqWatcherProcess
    Write-NvJson (Join-Path (& $nvNd) 'last.json') ([ordered]@{ pid = 4000000004; version = '1.0.0'; engine = 'native'; state = 'holding'; at = Get-NvAgo 60 })
    [IO.File]::WriteAllText($script:ChatqPidPath, "4000000004`r`n", $utf8)
    $null = Start-ChatqWatcherProcess
    $nvToasts2 = $script:Toasts.Count
    $script:ChatqSpawn = { param($l) if ($l.Engine -eq 'native') { throw 'refused' }; $script:nvLaunches += $l.Engine; $true }
    $null = Start-ChatqWatcherProcess
    $nvToasts3 = $script:Toasts.Count
    $nvFuse = Get-ChatqNativeFuse
    $nvEng = Get-ChatqWatcherEngine
    $script:ChatqSpawn = { param($l) $script:nvLaunches += $l.Engine; $true }
    $null = Start-ChatqWatcherProcess
    $nvToasts4 = $script:Toasts.Count
    $nvFuseLog = [IO.File]::ReadAllText((Join-Path $script:ChatqLogDir 'chatqd.log'), $utf8)
    $nvAlertLog = try { [IO.File]::ReadAllText((Join-Path $script:ChatqLogDir 'alerts.log'), $utf8) } catch { '' }
}
finally { Exit-NvRoot }
Check 'the third strike in a day blows the fuse: the PowerShell watcher, one failed alert, said in chatqd.log, and no second alert' (($nvLaunches -join ',') -eq 'ps,ps,ps,ps' -and
    $nvToasts2 -eq $nvToasts -and $nvToasts3 -eq $nvToasts + 1 -and $nvToasts4 -eq $nvToasts3 -and $nvFuse.Alerted -and @($nvFuse.Strikes).Count -eq 3 -and
    $nvEng.Engine -eq 'ps' -and $nvEng.Why -like '*failed 3 times for 1.0.0' -and $nvAlertLog -like '*failed*the native watcher failed 3 times*' -and
    $nvFuseLog -like '*the native watcher failed 3 times for 1.0.0 - the PowerShell watcher runs instead*') "$($nvLaunches -join ','); toasts $nvToasts/$nvToasts2/$nvToasts3/$nvToasts4; alerted $($nvFuse.Alerted); $($nvEng.Why)"

# --- the real chatqd ---------------------------------------------------------
# a developer's build, never staged in a checkout's bin/: where cargo puts it
# (native/SPEC.md 3.1). With none built, or one built before Cargo.toml's
# version - a version bump not built yet - these checks say so and are
# skipped.
$nvExe = Join-Path $root 'native\target\release\chatqd.exe'
$nvVer = if (Test-Path -LiteralPath (Join-Path $root 'native\Cargo.toml')) { [regex]::Match([IO.File]::ReadAllText((Join-Path $root 'native\Cargo.toml')), '(?m)^version = "(\d+\.\d+\.\d+)"').Groups[1].Value }
$nvBuilt = $null
if ($script:ChatqIsWindows -and (Test-Path -LiteralPath $nvExe) -and $nvVer) {
    # the build's own version, in its answer to scripts of one no build has
    try {
        $null = Enter-NvRoot 'built' '9.9.9'
        if ((Invoke-ChatqNativePreflight $nvExe) -match "said 'chatqd (\d+\.\d+\.\d+) ") { $nvBuilt = $Matches[1] }
    }
    finally { Exit-NvRoot }
}
if (-not $script:ChatqIsWindows -or -not (Test-Path -LiteralPath $nvExe) -or -not $nvVer) {
    Write-Host "  skip  the real chatqd: no build at $nvExe" -ForegroundColor Yellow
}
elseif ($nvBuilt -and $nvBuilt -ne $nvVer) {
    Write-Host "  skip  the real chatqd: the build at $nvExe is $nvBuilt, native/Cargo.toml $nvVer - build it again (TESTING.md, S55)" -ForegroundColor Yellow
}
else {
    # preflight through the call SPEC 4.2 names: a GUI-subsystem exe, which &
    # would neither wait for nor read
    try {
        $r = Enter-NvRoot 'preflight' $nvVer
        $nvT0 = Get-Date
        $nvPf = Invoke-ChatqNativePreflight $nvExe
        $nvPfMs = ((Get-Date) - $nvT0).TotalMilliseconds
        [IO.File]::WriteAllText($script:ChatqScriptPath, "# a fake loader`r`n`$script:ChatVersion = '9.9.9'`r`n", $utf8)
        $nvPfBad = Invoke-ChatqNativePreflight $nvExe
        $nvPfNone = Invoke-ChatqNativePreflight (Join-Path $r 'no-such-chatqd.exe')
    }
    finally { Exit-NvRoot }
    Check 'preflight runs the real chatqd version and reads its answer, within 5 s' ($null -eq $nvPf -and $nvPfMs -lt 5000) "said '$nvPf' in $nvPfMs ms"
    Check 'preflight fails on scripts of another version (exit 2), and on a binary that will not start' ($nvPfBad -like "exit 2, said 'chatqd $nvVer x86_64-pc-windows-msvc: the scripts are 9.9.9'" -and
        $nvPfNone -like 'did not start: *') "'$nvPfBad'; '$nvPfNone'"

    # a real launch: chatqd takes the lock in the throwaway root, finds the
    # queue empty, acks and leaves. Its spawn seam stands in for any watcher
    # it would start after.
    try {
        $r = Enter-NvRoot 'live' $nvVer
        $nvCap = Join-Path $r 'capture'
        $nvSeams = Join-Path $r 'seams.json'
        Write-NvJson $nvSeams ([ordered]@{ spawn = $true; capture = $nvCap })
        $env:CHATQ_NATIVE_SEAMS = $nvSeams
        $env:CHATQ_CHATQD = $nvExe
        $script:ChatqSpawn = $null
        $nvNd2 = Join-Path $script:ChatqData 'native'
        $nvLast = Join-Path $nvNd2 'last.json'
        $nvWl = Join-Path $script:ChatqLogDir 'watcher.log'
        $nvEng = Get-ChatqWatcherEngine
        $nvOk = $nvEng.Engine -eq 'native' -and (Start-ChatqWatcherProcess)
        $nvDone = Wait-Nv { (Test-Path -LiteralPath $nvWl) -and ((Read-NvShared $nvWl) -like '* stopped*') -and -not (Test-ChatqLockHeld $script:ChatqLockPath) }
        $nvL = Read-ChatqJson $nvLast
        $nvV1 = Read-ChatqJson (Join-Path $nvNd2 'verified.json')
        $nvLines = if (Test-Path -LiteralPath $nvWl) { @((Read-NvShared $nvWl) -split '\r?\n' | Where-Object { $_ }) } else { @() }
        $nvPend1 = Test-Path -LiteralPath (Join-Path $nvNd2 'pending.json')
        $nvFuse1 = Test-Path -LiteralPath (Join-Path $nvNd2 'fuse.json')
        $nvCap1 = Test-Path -LiteralPath (Join-Path $nvCap 'spawn-1.json')

        # then a restart: chatqd hands over, and its own decision finds the
        # pass PowerShell cached, and starts the same arguments PowerShell did
        [IO.File]::WriteAllText((Join-Path $script:ChatqData 'restart'), '', $utf8)
        $nvV1raw = [IO.File]::ReadAllText((Join-Path $nvNd2 'verified.json'))
        $nvOk2 = Start-ChatqWatcherProcess
        $nvDone2 = Wait-Nv { (Test-Path -LiteralPath (Join-Path $nvCap 'spawn-1.json')) -and -not (Test-ChatqLockHeld $script:ChatqLockPath) }
        Start-Sleep -Milliseconds 300
        $nvSp = try { [IO.File]::ReadAllText((Join-Path $nvCap 'spawn-1.json')) | ConvertFrom-Json } catch { $null }
        $nvV2raw = [IO.File]::ReadAllText((Join-Path $nvNd2 'verified.json'))
        $nvV2 = $nvV2raw | ConvertFrom-Json
        $nvWant = Get-ChatqWatcherLaunch $script:ChatqScriptPath -Native $nvEng.Exe
        $nvL2 = Read-ChatqJson $nvLast
        $nvPend2 = Test-Path -LiteralPath (Join-Path $nvNd2 'pending.json')
        $nvFuse2 = Test-Path -LiteralPath (Join-Path $nvNd2 'fuse.json')
    }
    finally { Exit-NvRoot }
    Check 'a real native launch: chatqd holds the lock, acks, finds the queue empty and leaves; no strike' ($nvOk -and $nvDone -and
        $nvL.state -eq 'empty' -and $nvL.engine -eq 'native' -and [string]$nvL.version -eq $nvVer -and -not $nvPend1 -and -not $nvFuse1 -and -not $nvCap1 -and
        @($nvV1.passed).Count -eq 1 -and @($nvLines | Where-Object { $_ -like "* started ($nvVer)" }).Count -eq 1 -and
        @($nvLines | Where-Object { $_ -like '*  queue empty' }).Count -eq 1) "started $nvOk, done $nvDone, last $($nvL | ConvertTo-Json -Compress), pending $nvPend1, fuse $nvFuse1; $($nvLines -join ' | ')"
    Check 'its respawn decides as PowerShell does: the pass PowerShell cached, the same arguments, no preflight again' ($nvOk2 -and $nvDone2 -and
        $nvSp.engine -eq 'native' -and $nvSp.exe -eq $nvEng.Exe -and ($nvSp.args -join '|') -eq ($nvWant.Args -join '|') -and
        $nvL2.state -eq 'handed-over' -and @($nvV2.passed).Count -eq 1 -and $nvV2raw -ceq $nvV1raw -and -not $nvPend2 -and -not $nvFuse2) "started $nvOk2, done $nvDone2, spawn $($nvSp | ConvertTo-Json -Compress -Depth 4); verified $nvV2raw"

    # the contracts no vector file can hold - DPAPI, this PC's own zone -
    # asked of this build (native/SPEC.md 6.1)
    . (Join-Path $here 'vectors\live.ps1')
    foreach ($nvLc in @(Invoke-NvLiveChecks $nvExe)) { Check "the real chatqd, live: $($nvLc.name)" ([bool]$nvLc.ok) $nvLc.detail }

    # --- the twin run: jobs through pick (native/SPEC.md 6.5) ----------------
    # Each case is a fixture D of its own beside a copy of the tool - its real
    # loader and src/, native-step.ps1 among them - holding the jobs' files,
    # a config with no toast, no handover and no phone, and the harness's
    # seams file. It runs once under the PS watcher (Invoke-ChatqWatchLoop in
    # a child, the seams applied as src/native-step.ps1 applies them) and
    # once under this chatqd, and the two are compared with stamps, clock
    # times, pids and the root masked: watcher.log, jobs.log and alerts.log
    # line for line, the job files and state.json as read, queue.md as text,
    # and the captures. The CLIs are the sandbox's fake behind a .cmd of the
    # fixture's own: codex replays codex-done.jsonl, a claude run (--resume)
    # of $nvFailId replays error.jsonl, and any claude run sleeps
    # NV_RUN_SLEEP s when that is set. --version gets no stdin: the fake reads
    # its stdin to the end, and a step's hidden console never ends it.
    $nvPs = (Get-Process -Id $PID).Path
    $nvTool = Join-Path $sb 'tool'
    $nvStepText = [IO.File]::ReadAllText((Join-Path $nvTool 'src\native-step.ps1'), $utf8)
    $nvSeamAt = $nvStepText.IndexOf('function Save-StepCapture')
    $nvSeamText = $nvStepText.Substring($nvSeamAt, $nvStepText.IndexOf('# The parent test') - $nvSeamAt)
    $nvWatchPs1 = "param([string]`$Seams)`r`ntry { . (Join-Path `$PSScriptRoot 'Charlie-and-the-chat-factory.ps1') } catch { exit 3 }`r`n" +
    "Remove-Item -LiteralPath 'env:PSExecutionPolicyPreference' -EA SilentlyContinue`r`n$nvSeamText" +
    "# the harness's fake ntfy: a reply topic nothing is posted to`r`n`$script:ChatqReplyPollSeam = { param(`$Url) '' }`r`nInvoke-ChatqWatchLoop`r`n"
    $nvCfg = [ordered]@{ toast = $false; handover = $false }
    $nvToastsAt = $script:Toasts.Count
    $nvNtfysAt = $script:Ntfys.Count
    # each job made by chatq in the sandbox, its files kept aside, then removed
    $nvStash = Join-Path $sb 'native\twin-jobs'
    $null = New-Item -ItemType Directory -Path $nvStash -Force
    function New-NvJob([string]$Target, [string]$Text, [hashtable]$Set = @{}) {
        $j = New-TestJob $Target $Text
        foreach ($k in $Set.Keys) { Set-ChatqProp $j $k $Set[$k] }
        if ($Set.Count) { $null = Save-ChatqJob $j -Existing }
        foreach ($f in "$($j.id).json", $j.promptFile) { Copy-Item -LiteralPath (Join-Path $script:ChatqQueueDir $f) -Destination $nvStash -Force }
        $null = Remove-ChatqJob (Find-ChatqJob $j.id -Exact) 'test'
        return $j
    }
    function New-NvFixture([string]$Name, $Jobs, $Cfg) {
        $r = Join-Path (Join-Path $sb 'native') $Name
        if (Test-Path -LiteralPath $r) { Remove-Item -LiteralPath $r -Recurse -Force }
        $d = Join-Path $r 'data'
        foreach ($x in (Join-Path $d 'queue'), (Join-Path $d 'native'), (Join-Path $r 'capture'), (Join-Path $r 'fake')) { $null = New-Item -ItemType Directory -Path $x -Force }
        Copy-Item -LiteralPath (Join-Path $nvTool 'Charlie-and-the-chat-factory.ps1') -Destination $r -Force
        Copy-Item -LiteralPath (Join-Path $nvTool 'src') -Destination $r -Recurse -Force
        foreach ($j in @($Jobs)) { foreach ($f in "$($j.id).json", $j.promptFile) { Copy-Item -LiteralPath (Join-Path $nvStash $f) -Destination (Join-Path $d 'queue') -Force } }
        Write-NvJson (Join-Path $d 'config.json') $Cfg
        Write-NvJson (Join-Path $r 'seams.json') ([ordered]@{ capture = (Join-Path $r 'capture'); spawn = $true; idleSeconds = 99999; handoverOff = $true })
        [IO.File]::WriteAllText((Join-Path $r 'nv-watch.ps1'), $nvWatchPs1, $utf8)
        $st = Join-Path $here 'fixtures\stream'
        $run = "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$(Join-Path $here 'fake-agent.ps1')`""
        $head = "@echo off`r`nsetlocal EnableDelayedExpansion`r`nset `"FAKE_ARGV=%*`"`r`n"
        $tail = "if not `"!FAKE_ARGV:--version=!`"==`"!FAKE_ARGV!`" (`r`n$run <nul`r`nexit /b`r`n)`r`n$run`r`n"
        [IO.File]::WriteAllText((Join-Path $r 'fake\claude.cmd'), $head +
            "if not `"!FAKE_ARGV:--resume=!`"==`"!FAKE_ARGV!`" if defined NV_RUN_SLEEP set `"FAKE_SLEEP=!NV_RUN_SLEEP!`"`r`n" +
            "if not `"!FAKE_ARGV:$nvFailId=!`"==`"!FAKE_ARGV!`" set `"FAKE_SCENARIO=$st\error.jsonl`"`r`n" + $tail, [Text.Encoding]::ASCII)
        [IO.File]::WriteAllText((Join-Path $r 'fake\codex.cmd'), $head + "set `"FAKE_SCENARIO=$st\codex-done.jsonl`"`r`n" + $tail, [Text.Encoding]::ASCII)
        return $r
    }
    # chatqrun -Now's wake, as Send-ChatqWake writes it
    function Send-NvNow([string]$Root) { [IO.File]::WriteAllText((Join-Path $Root 'data\wake'), "now`r`n", [Text.Encoding]::ASCII) }
    # a watcher as each engine is started, in your home folder, on the
    # fixture's CLIs and seams, with the watcher's parts and no FAKE_ of the
    # runner's; stdin closed at once, as a hidden console's never is
    function Start-NvEngine([string]$Root, [string]$Engine, [hashtable]$Env = @{}) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $seams = Join-Path $Root 'seams.json'
        if ($Engine -eq 'ps') {
            $psi.FileName = $nvPs
            $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$(Join-Path $Root 'nv-watch.ps1')`" -Seams `"$seams`""
        }
        else {
            $a = @((Get-ChatqWatcherLaunch (Join-Path $Root 'Charlie-and-the-chat-factory.ps1') -Native $nvExe).Args)
            $a[2] = $Root
            $psi.FileName = $nvExe
            $psi.Arguments = ConvertTo-ChatqArgLine $a
        }
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.WorkingDirectory = $HOME
        $psi.RedirectStandardInput = $true
        $ev = $psi.EnvironmentVariables
        foreach ($n in @($ev.Keys)) { if ($n -like 'FAKE_*' -or $n -like 'NV_*') { $ev.Remove($n) } }
        foreach ($n in 'CHATQ_ALLPARTS', 'CHATQ_CHATQD', 'CHATQ_ENGINE') { $ev.Remove($n) }
        $ev['CHATQ_WATCHER'] = '1'
        $ev['CHATQ_NATIVE_SEAMS'] = $seams
        $ev['CHATQ_CLAUDE'] = Join-Path $Root 'fake\claude.cmd'
        $ev['CHATQ_CODEX'] = Join-Path $Root 'fake\codex.cmd'
        foreach ($k in $Env.Keys) { $ev[$k] = $Env[$k] }
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.StandardInput.Close()
        return $p
    }
    # a process this test started, and what it started in turn
    function Stop-NvTree([int]$Id) {
        foreach ($c in @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $Id" -EA SilentlyContinue)) { Stop-NvTree ([int]$c.ProcessId) }
        Stop-Process -Id $Id -Force -EA SilentlyContinue
    }
    # its exit, within $Secs; meanwhile, every 200 ms, the pids a running
    # job is under (its runnerPid, state.json's pid, watcher.pid) and the
    # case's $During
    function Wait-NvEngine($P, [string]$Root, [scriptblock]$During, [int]$Secs = 300) {
        $d = Join-Path $Root 'data'
        $seen = [System.Collections.Generic.List[string]]::new()
        $until = (Get-Date).AddSeconds($Secs)
        while (-not $P.HasExited -and (Get-Date) -lt $until) {
            foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $d 'queue') -Filter '*.json' -File -EA SilentlyContinue)) {
                $j = try { [IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json } catch { $null }
                if (-not $j -or $j.state -ne 'running') { continue }
                $s = try { [IO.File]::ReadAllText((Join-Path $d 'state.json')) | ConvertFrom-Json } catch { $null }
                # state.json caught mid-write reads as nothing: no sample
                if (-not $s) { continue }
                $w = try { [IO.File]::ReadAllText((Join-Path $d 'watcher.pid')).Trim() } catch { '' }
                $seen.Add("$($j.runnerPid)/$($s.pid)/$w")
            }
            if ($During) { & $During }
            Start-Sleep -Milliseconds 200
        }
        $exited = $P.HasExited
        if (-not $exited) { Stop-NvTree $P.Id }
        return [pscustomobject]@{ Pid = $P.Id; Exited = $exited; Pids = @($seen) }
    }
    function Get-NvMask([string]$Text, [int]$WPid, [string]$Root) {
        $t = $Text
        if ($Root) { $t = $t -replace [regex]::Escape($Root.Replace('\', '\\')), '<root>' -replace [regex]::Escape($Root), '<root>' }
        $t = $t -replace '\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?(Z|[+-]\d\d:\d\d)?', '<at>' -replace '\b\d\d?:\d\d(:\d\d)?\b', '<hh:mm>'
        if ($WPid) { $t = $t -replace "\b$WPid\b", '<pid>' }
        return $t
    }
    # a JSON value as one string, each object's names in order: two files
    # that read the same are the same string
    function ConvertTo-NvCanon($V) {
        if ($null -eq $V) { return 'null' }
        if ($V -is [System.Management.Automation.PSCustomObject]) { return '{' + ((@($V.PSObject.Properties | Sort-Object Name) | ForEach-Object { "$($_.Name)=$(ConvertTo-NvCanon $_.Value)" }) -join ';') + '}' }
        if ($V -is [System.Collections.IList]) { return '[' + ((@($V) | ForEach-Object { ConvertTo-NvCanon $_ }) -join ',') + ']' }
        return (ConvertTo-Json $V -Compress)
    }
    # what a run left: the logs, the job files and state.json, masked
    function Read-NvRun([string]$Root, $Run) {
        $d = Join-Path $Root 'data'
        $txt = { param($p) if (Test-Path -LiteralPath $p) { Read-NvShared $p } else { '' } }
        $logs = @{}
        foreach ($n in 'watcher.log', 'jobs.log', 'alerts.log', 'replies.log', 'chatqd.log') { $logs[$n] = Get-NvMask (& $txt (Join-Path $d "logs\$n")) $Run.Pid $Root }
        $jobs = [ordered]@{}
        $states = [ordered]@{}
        foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $d 'queue') -Filter '*.json' -File | Sort-Object Name)) {
            $j = (Get-NvMask (& $txt $f.FullName) 0 $Root) | ConvertFrom-Json
            $jobs[$f.Name] = ConvertTo-NvCanon $j
            $states[$f.Name] = "$($j.state)"
        }
        $st = (Get-NvMask (& $txt (Join-Path $d 'state.json')) 0 $Root) | ConvertFrom-Json
        $stPid = if ($st) { $st.pid } else { $null }
        if ($st) { $st.PSObject.Properties.Remove('pid') }
        return [pscustomobject]@{ Root = $Root; Pid = $Run.Pid; Exited = $Run.Exited; Pids = $Run.Pids; Logs = $logs; Jobs = $jobs; States = $states
            State = (ConvertTo-NvCanon $st); StatePid = $stPid; Board = (Get-NvMask (& $txt (Join-Path $d 'queue.md')) $Run.Pid $Root)
            Captures = (@(Get-ChildItem -LiteralPath (Join-Path $Root 'capture') -File | Sort-Object Name | ForEach-Object { $_.Name }) -join ',')
        }
    }
    # a case under each engine in turn, on fixtures alike but for their name
    function Invoke-NvTwin([string]$Name, $Jobs, [switch]$Now, [scriptblock]$During, [hashtable]$Env = @{}) {
        $out = [ordered]@{}
        foreach ($e in 'ps', 'native') {
            $r = New-NvFixture "$Name-$e" $Jobs $nvCfg
            if ($Now) { Send-NvNow $r }
            $script:nvCase = @{ Root = $r; Done = $false }
            $p = Start-NvEngine $r $e $Env
            $out[$e] = Read-NvRun $r (Wait-NvEngine $p $r $During)
        }
        return $out
    }
    function Compare-NvTwin($T) {
        $a = $T.ps
        $b = $T.native
        $bad = @()
        if (-not $a.Exited -or -not $b.Exited) { $bad += "exited: ps $($a.Exited), native $($b.Exited)" }
        foreach ($n in 'watcher.log', 'jobs.log', 'alerts.log') {
            $x = @($a.Logs[$n] -split "`n")
            $y = @($b.Logs[$n] -split "`n")
            for ($i = 0; $i -lt [Math]::Max($x.Count, $y.Count); $i++) {
                if ($x[$i] -cne $y[$i]) { $bad += "$n line $($i + 1): ps '$($x[$i])', native '$($y[$i])'"; break }
            }
        }
        foreach ($n in @(@($a.Jobs.Keys) + @($b.Jobs.Keys) | Select-Object -Unique)) { if ($a.Jobs[$n] -cne $b.Jobs[$n]) { $bad += "$n`: ps $($a.Jobs[$n]) / native $($b.Jobs[$n])" } }
        if ($a.State -cne $b.State) { $bad += "state.json: ps $($a.State) / native $($b.State)" }
        if ($a.StatePid -ne $a.Pid -or $b.StatePid -ne $b.Pid) { $bad += "state.json pid: ps $($a.StatePid) of $($a.Pid), native $($b.StatePid) of $($b.Pid)" }
        if ($a.Board -cne $b.Board) { $bad += "queue.md: ps '$($a.Board)' / native '$($b.Board)'" }
        if ($a.Captures -or $b.Captures) { $bad += "captured: ps '$($a.Captures)', native '$($b.Captures)'" }
        return $bad
    }
    # every sample of a running job: runnerPid = state.json's pid = watcher.pid = the watcher's
    function Test-NvPids($R) { $R.Pids.Count -gt 0 -and -not @($R.Pids | Where-Object { $_ -cne "$($R.Pid)/$($R.Pid)/$($R.Pid)" }).Count }

    # a Claude job and a Codex job done, and a run that fails, past the
    # sandbox's limited lanes by a fresh -Now; each Claude run 3 s long, so
    # it is seen running
    $nvA = @((New-NvJob 'plugin' 'twin: a Claude job'), (New-NvJob 'Codex gitignore thread' 'twin: a Codex job'), (New-NvJob 'Old chat about gitignore rules' 'twin: a run that fails'))
    $nvFailId = $nvA[2].sessionId
    $nvTa = Invoke-NvTwin 'twin-pick' $nvA -Now -Env @{ NV_RUN_SLEEP = '3' }
    $nvTaWant = @(foreach ($j in $nvA) { "$($j.id).json" }) -join ','
    $nvTaBad = @(Compare-NvTwin $nvTa)
    foreach ($e in 'ps', 'native') {
        $t = $nvTa[$e]
        if ((@($t.States.Values) -join ',') -cne 'done,done,failed' -or (@($t.States.Keys) -join ',') -cne $nvTaWant) { $nvTaBad += "$e`: jobs $(@($t.States.Keys) -join ',') $(@($t.States.Values) -join ',')" }
        if ($t.Logs['watcher.log'] -notlike '*  woken: -Now*' -or $t.Logs['watcher.log'] -notlike '*  queue empty*') { $nvTaBad += "$e`: watcher.log $($t.Logs['watcher.log'])" }
        if (-not (Test-NvPids $t)) { $nvTaBad += "$e`: pids $($t.Pid) / $($t.Pids -join ' ')" }
    }
    Check 'the twin run, through pick: a Claude job and a Codex job done and a run failed alike under the PS watcher and chatqd - the logs line for line, job files, state.json, queue.md, nothing captured; a running job''s runnerPid, state.json and watcher.pid the watcher''s' (
        $nvA[1].provider -eq 'codex' -and -not $nvTaBad) ($nvTaBad -join ' || ')

    # -Now mid-wait: a job put off an hour on a limited lane; once the
    # watcher waits (state.json has its next), chatqrun -Now
    $nvB = @(New-NvJob 'plugin' 'twin: woken mid-wait' @{ deferUntil = (Get-Date).AddHours(1).ToUniversalTime().ToString('o') })
    $nvWakeMid = {
        $c = $script:nvCase
        if ($c.Done) { return }
        $s = try { [IO.File]::ReadAllText((Join-Path $c.Root 'data\state.json')) | ConvertFrom-Json } catch { $null }
        if ($s -and $s.next) { Start-Sleep -Seconds 1; Send-NvNow $c.Root; $c.Done = $true }
    }
    $nvTb = Invoke-NvTwin 'twin-now' $nvB -During $nvWakeMid
    $nvTbBad = @(Compare-NvTwin $nvTb)
    foreach ($e in 'ps', 'native') {
        $t = $nvTb[$e]
        $wk = Read-TestFile (Join-Path $t.Root 'data\wake')
        if ((@($t.States.Values) -join ',') -cne 'done' -or $t.Logs['watcher.log'] -notlike '*  woken: -Now*' -or "$wk".Trim() -cne 'seen' -or $t.Jobs[0] -notlike '*;deferUntil=null;*') {
            $nvTbBad += "$e`: $(@($t.States.Values) -join ','), wake '$wk', $($t.Jobs[0]) | $($t.Logs['watcher.log'])"
        }
    }
    Check 'the twin run: -Now mid-wait ends the wait, clears the job''s deferUntil, says woken and seen, and the job runs - alike under both' (-not $nvTbBad) ($nvTbBad -join ' || ')

    # a step that dies mid-pick: chatqd's pick-failure write (SPEC 2.4),
    # against Complete-ChatqJob and the loop's failed alert on a twin of the
    # job file as the step left it
    $nvC = New-NvJob 'plugin' 'a pick whose step dies'
    $nvCr = New-NvFixture 'step-dies' @($nvC) $nvCfg
    Send-NvNow $nvCr
    $nvCrec = Join-Path $nvCr 'fake\rec'
    $nvCfile = Join-Path $nvCr "data\queue\$($nvC.id).json"
    $nvCp = Start-NvEngine $nvCr 'native' @{ NV_RUN_SLEEP = '120'; FAKE_RECORD = $nvCrec }
    $script:nvCase = @{ Pid = $nvCp.Id; Done = $false; Job = $null; Steps = @() }
    $nvKill = {
        $c = $script:nvCase
        if ($c.Done) { return }
        $argv = try { [IO.File]::ReadAllText((Join-Path $nvCrec 'argv.txt')) } catch { '' }
        if ($argv -notmatch '--resume') { return }
        $cli = try { [int]([regex]::Match([IO.File]::ReadAllText((Join-Path $nvCrec 'pid.txt')), '\d+').Value) } catch { 0 }
        $c.Job = Read-TestFile $nvCfile
        # the step chatqd started, then the CLI it leaves running
        $c.Steps = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $($c.Pid)" | Where-Object { $_.CommandLine -like '*native-step.ps1*' } | ForEach-Object { [int]$_.ProcessId })
        foreach ($s in $c.Steps) { Stop-Process -Id $s -Force -EA SilentlyContinue }
        if ($cli) { Stop-Process -Id $cli -Force -EA SilentlyContinue }
        $c.Done = $true
    }
    $nvCrun = Read-NvRun $nvCr (Wait-NvEngine $nvCp $nvCr $nvKill)
    $nvCsnap = $script:nvCase.Job
    $nvCwhy = [regex]::Match($nvCrun.Logs['watcher.log'], "#$($nvC.seq) error: helper step ([^\r\n]+)").Groups[1].Value
    $nvCt = New-NvFixture 'step-dies-twin' @() $nvCfg
    [IO.File]::WriteAllText((Join-Path $nvCt "data\queue\$($nvC.id).json"), "$nvCsnap", $utf8)
    Copy-Item -LiteralPath (Join-Path $nvStash $nvC.promptFile) -Destination (Join-Path $nvCt 'data\queue') -Force
    $nvCq = { param($s) "'" + $s.Replace("'", "''") + "'" }
    [IO.File]::WriteAllText((Join-Path $nvCt 'nv-fail.ps1'), (". $(& $nvCq (Join-Path $nvCt 'Charlie-and-the-chat-factory.ps1'))`r`n" +
            "`$j = Find-ChatqJob $(& $nvCq $nvC.id) -Exact`r`n`$msg = $(& $nvCq "helper step $nvCwhy")`r`n" +
            "Complete-ChatqJob `$j 'failed' ([pscustomobject]@{ kind = 'failed'; reason = `"chatq error: `$msg`" }) 'chatq error'`r`n" +
            "[void](Send-ChatqAlert 'failed' `"`$(`$j.title) `$(`$script:ChatqDot) chatq error: `$msg`" 2 -Job `$j)`r`n"), $utf8)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $nvPs
    $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$(Join-Path $nvCt 'nv-fail.ps1')`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['CHATQ_WATCHER'] = '1'
    $psi.EnvironmentVariables.Remove('CHATQ_ALLPARTS')
    $nvCtp = [System.Diagnostics.Process]::Start($psi)
    if (-not $nvCtp.WaitForExit(120000)) { Stop-NvTree $nvCtp.Id }
    $nvCtwin = Read-NvRun $nvCt ([pscustomobject]@{ Pid = $nvCtp.Id; Exited = $true; Pids = @() })
    $nvCj = $nvCfile | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { Read-ChatqJson $_ }
    $nvClast = { param($R, $N) @($R.Logs[$N] -split "`n" | Where-Object { $_ })[-1] }
    $nvCbad = @()
    if (-not $nvCrun.Exited -or $script:nvCase.Steps.Count -ne 1 -or $nvCsnap -notmatch '"state":\s*"running"') { $nvCbad += "exited $($nvCrun.Exited), steps $($script:nvCase.Steps -join ','), snapshot $nvCsnap" }
    if ($nvCwhy -cne 'exited -1 with no answer' -or $nvCrun.Logs['chatqd.log'] -notlike '* pick exited -1 after *' -or $nvCj.state -ne 'failed' -or
        $nvCj.result.reason -cne 'chatq error: helper step exited -1 with no answer' -or $null -ne $nvCj.runnerPid) { $nvCbad += "why '$nvCwhy', job $($nvCj.state) '$($nvCj.result.reason)' $($nvCj.runnerPid)" }
    if ($nvCrun.Jobs[0] -cne $nvCtwin.Jobs[0]) { $nvCbad += "job: native $($nvCrun.Jobs[0]) / ps $($nvCtwin.Jobs[0])" }
    foreach ($n in 'jobs.log', 'alerts.log') { if ((& $nvClast $nvCrun $n) -cne (& $nvClast $nvCtwin $n)) { $nvCbad += "$n`: native '$(& $nvClast $nvCrun $n)' / ps '$(& $nvClast $nvCtwin $n)'" } }
    if ($nvCrun.Captures) { $nvCbad += "captured '$($nvCrun.Captures)'" }
    Check 'a pick step killed mid-run: chatqd logs helper step exited -1, fails the job as Complete-ChatqJob does on a twin of the file the step left - the file, its jobs.log line and its failed alert alike' (
        -not $nvCbad) ($nvCbad -join ' || ')

    # a pick that opens the reply window: chatqd hands over, W and its caches
    # in handoff.json, and the PS watcher it would start (started here in its
    # place, the spawn seam having recorded it) carries on from them: the
    # answer the phone sent mid-pick lands. One engine, as the PS watcher
    # listens where chatqd hands over until M3. The answer's entry is a
    # stand-in, put in by the fixture's own native-step.ps1 after the run:
    # Invoke-ChatqAskReply makes one only on a reply chatqd cannot take yet.
    $nvD = New-NvJob 'plugin' 'a pick that opens the reply window'
    $nvDcfg = [ordered]@{ toast = $false; handover = $false
        join = [ordered]@{ apiKey = (Protect-ChatqSecret '0123456789abcdef0123456789abcdef'); device = 'group.phone' }
        reply = [ordered]@{ on = $true; topic = (Protect-ChatqSecret 'nvtwintopic'); key = (Protect-ChatqSecret (ConvertTo-ChatqB64Url ([byte[]](1..32)))) }
    }
    $nvDr = New-NvFixture 'handoff' @($nvD) $nvDcfg
    $nvDt = Join-Path $nvDr 'ask-chat.jsonl'
    [IO.File]::WriteAllText($nvDt, '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_nv","content":"B"}]},"toolUseResult":{"answers":{"Which?":"B"}}}' + "`n", $utf8)
    $nvDstep = Join-Path $nvDr 'src\native-step.ps1'
    $nvDin = "# the harness's stand-in for an answer the phone sent mid-pick (tests/sections/native.ps1)`r`n" +
    "`$script:NvJob = `${function:Invoke-ChatqJob}`r`n`${function:Invoke-ChatqJob} = {`r`n    & `$script:NvJob @args`r`n" +
    "    `$a = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)`r`n    `$a['Which?'] = 'B'`r`n" +
    "    `$script:ChatqAskSent['nvaskrid22'] = @{ Rid = 'nvaskrid22'; At = (Get-Date); ToolUseId = 'toolu_nv'; Answers = `$a; Transcript = '$nvDt'; SessionId = 's-nv'; Title = 'nv ask chat' }`r`n}`r`n"
    [IO.File]::WriteAllText($nvDstep, [IO.File]::ReadAllText($nvDstep, $utf8).Replace("Invoke-ChatqNativeStep -In `$In -Out `$Out", "$nvDin`Invoke-ChatqNativeStep -In `$In -Out `$Out"), $utf8)
    Send-NvNow $nvDr
    $nvDp = Start-NvEngine $nvDr 'native'
    $nvDrun = Wait-NvEngine $nvDp $nvDr $null
    $nvDd = Join-Path $nvDr 'data'
    $nvDh = Read-ChatqJson (Join-Path $nvDd 'native\handoff.json')
    $nvDw = if ($nvDh) { try { ConvertFrom-ChatqStepW $nvDh.w } catch { $null } } else { $null }
    $nvDs = Read-ChatqJson (Join-Path $nvDd 'state.json')
    $nvDl = Read-ChatqJson (Join-Path $nvDd 'native\last.json')
    $nvDsp = Read-ChatqJson (Join-Path $nvDr 'capture\spawn-1.json')
    $nvDcap = @(Get-ChildItem -LiteralPath (Join-Path $nvDr 'capture') -File | ForEach-Object { $_.Name -replace '-\d+\.json$', '' } | Sort-Object -Unique) -join ','
    $nvDcarry = Test-Path -LiteralPath (Join-Path $nvDd 'native\carry.clixml')
    $nvDbad = @()
    if (-not $nvDrun.Exited -or -not $nvDh -or [int]$nvDh.v -ne 1 -or [int]$nvDh.watcherPid -ne $nvDrun.Pid -or $nvDh.w.handoff -ne $true -or -not $nvDw -or
        -not $nvDw.Caches.ChatqAskSent.ContainsKey('nvaskrid22') -or -not $nvDw.W.lastAllowed.Count) { $nvDbad += "handoff.json: exited $($nvDrun.Exited), $($nvDh | ConvertTo-Json -Compress -Depth 3)" }
    if ($nvDs.handoff -ne $true -or [int]$nvDs.pid -ne $nvDrun.Pid -or $nvDl.state -cne 'handed-over' -or $nvDsp.engine -cne 'ps' -or
        $nvDsp.command -notlike "*$(Join-Path $nvDr 'Charlie-and-the-chat-factory.ps1')*Invoke-ChatqWatchLoop" -or $nvDcap -cne 'down,join,spawn' -or
        (Read-NvShared (Join-Path $nvDd 'logs\chatqd.log')) -notlike '*handing over to the PowerShell watcher: the phone reply window is open*') {
        $nvDbad += "state handoff $($nvDs.handoff) pid $($nvDs.pid), last $($nvDl.state), spawn $($nvDsp.engine) '$($nvDsp.command)', captured $nvDcap"
    }
    $nvDreplies = Join-Path $nvDd 'logs\replies.log'
    $nvDstop = {
        if (-not $script:nvCase.Done -and (Test-Path -LiteralPath $nvDreplies) -and (Read-NvShared $nvDreplies) -like '*ask nvaskrid22 nv ask chat: landed*') {
            [IO.File]::WriteAllText((Join-Path $nvDd 'stop'), '', $utf8)
            $script:nvCase.Done = $true
        }
    }
    $script:nvCase = @{ Done = $false }
    $nvDpp = Start-NvEngine $nvDr 'ps'
    $nvDps = Wait-NvEngine $nvDpp $nvDr $nvDstop 150
    $nvDwl = Read-NvShared (Join-Path $nvDd 'logs\watcher.log')
    if (-not $nvDps.Exited -or -not $script:nvCase.Done -or $nvDwl -notlike "*watcher $($nvDpp.Id) started*carrying on from the watcher before it*listening for phone replies*stop requested*" -or
        (Test-Path -LiteralPath (Join-Path $nvDd 'native\handoff.json')) -or (Test-Path -LiteralPath (Join-Path $nvDd 'native\carry.clixml'))) {
        $nvDbad += "the PS watcher: exited $($nvDps.Exited), landed $($script:nvCase.Done), carry was $nvDcarry | $nvDwl"
    }
    Check 'a pick that opens the reply window: chatqd hands over W and its caches in handoff.json, its PS watcher recorded; that watcher carries on from them, the phone''s answer sent mid-pick lands, and both files go' (
        -not $nvDbad) ($nvDbad -join ' || ')
    Check 'the twin run toasts, pushes and starts nothing outside its captures' ($script:Toasts.Count -eq $nvToastsAt -and $script:Ntfys.Count -eq $nvNtfysAt) "toasts $nvToastsAt -> $($script:Toasts.Count), ntfy $nvNtfysAt -> $($script:Ntfys.Count)"
}

# --- the contract vectors (native/SPEC.md 6.1) ---------------------------------
Section 'native contract vectors'
# Every native/vectors/*.json made again by this PowerShell, from the
# functions it pins, and compared with the file: tests/vectors.ps1, in a
# process of its own, as its clock, zone and culture stand-ins must not
# outlive it. The Rust runners check chatq-core against the same files.
$nvRep = Join-Path $sb 'vectors-report.json'
$nvVecOut = & {
    # 5.1 makes a native command's stderr line an error, which Stop throws
    $ErrorActionPreference = 'Continue'
    @(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $here 'vectors.ps1') -Report $nvRep 2>&1 | ForEach-Object { "$_" })
}
$nvVecRep = Read-ChatqJson $nvRep
if (-not $nvVecRep -or -not @($nvVecRep.files).Count) { Check 'tests/vectors.ps1 makes the vectors and says how they compare' $false (@($nvVecOut) -join ' | ') }
foreach ($nvVf in @($nvVecRep.files)) {
    Check "vector $($nvVf.name).json: its $($nvVf.cases) cases, as $($nvVecRep.edition) PowerShell answers them" ([bool]$nvVf.ok) (@($nvVf.problems) -join '; ')
}
