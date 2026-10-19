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
