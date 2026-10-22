Section 'overlay host: the headless host and its panel''s news'
# src/overlay-host.ps1: what an overlay host does whatever draws its panel,
# and the headless host, whose panel is a process of its own. The panel's
# process stands in (ChatOverlayUiSpawnSeam), as do the usage endpoint, the
# watcher's start and the sign-in; every file it writes is put back.
$hsWas = @{ Usage = $script:ChatOverlayUsageSeam; Spawn = $script:ChatqSpawn; Ui = $script:ChatOverlayUiSpawnSeam; SignIn = $script:ChatqSignInSeam; OvSpawn = $script:ChatOverlaySpawn
    LiveFn = ${function:Get-ChatqLiveSessions}; RmFn = ${function:Remove-ChatSessionById}; AnsFn = ${function:Write-ChatReloadAnswer} }
$hsFiles = @{}
foreach ($p in $script:ChatOverlayStatePath, $script:ChatOverlayEventsPath, $script:ChatOverlayUiPath, $script:ChatOverlayPath, $script:ChatOverlayCardPath) { $hsFiles[$p] = Read-TestFile $p }
$script:ChatOverlayUsageSeam = { @{ Ok = $true; Status = 200; Windows = @([pscustomobject]@{ Label = '5h'; Percent = 10; ResetsAt = (Get-Date).AddHours(3); Severity = 'normal' }) } }
$script:ChatqSpawn = { $true }
$script:ChatqSignInSeam = { [int64]1700000000000 }
$script:HsRestarts = 0
$script:ChatOverlaySpawn = { $script:HsRestarts++; $true }
# a stand-in for the panel's process: its stdin's close ends it, and says
# whether the close by hand was kept yet
$hsChild = {
    param([bool]$Exited)
    $c = [pscustomobject]@{ HasExited = $Exited; ExitCode = 3 }
    $in = [pscustomobject]@{ Owner = $c }
    $in | Add-Member -MemberType ScriptMethod -Name Close -Value { $script:HsLog.Add("stdin closed, closedSignIn $((Read-ChatOverlayState).closedSignIn)"); $this.Owner.HasExited = $true }
    $c | Add-Member -NotePropertyName StandardInput -NotePropertyValue $in
    $c | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) $this.HasExited }
    $c | Add-Member -MemberType ScriptMethod -Name Kill -Value { $script:HsLog.Add('killed') }
    $c
}
try {
    foreach ($p in $script:ChatOverlayEventsPath, $script:ChatOverlayUiPath) { Remove-Item -LiteralPath $p -Force -EA SilentlyContinue }
    # a balloon, on a headless host, is an event for its panel - kept on disk too
    $hsH = New-ChatOverlayHeadlessState
    $hsH.Ctx = New-ChatOverlayContext
    Show-ChatOverlayBalloon $hsH 'two chats can continue' -Title 'Charlie - the 5h reset' -Kind ask -Keys @('k1', '', 'k2') -Ms 10000
    $hsE = @($hsH.Events)
    $hsDisk = @(Read-ChatOverlayEvents)
    Check 'a balloon on the headless host: one event, its title, text, click and keys, and the same on disk' (
        $hsE.Count -eq 1 -and $hsE[0].kind -eq 'balloon' -and $hsE[0].title -eq 'Charlie - the 5h reset' -and $hsE[0].click -eq 'ask' -and
        (@($hsE[0].keys) -join ',') -eq 'k1,k2' -and $hsE[0].id -eq "$($hsH.EventBase)-1" -and $hsH.BalloonKind -eq 'ask' -and
        $hsDisk.Count -eq 1 -and $hsDisk[0].id -eq $hsE[0].id) "$($hsE | ConvertTo-Json -Compress) / $($hsDisk.Count)"

    # the snapshot carries them, and a spin, only for a context that holds events
    $hsCx = New-ChatOverlayContext
    $hsCx.Events = $hsH.Events
    $hsSnap = Invoke-ChatOverlayCycle $hsCx -Peek
    $hsBack = (ConvertTo-Json $hsSnap -Depth 6 -Compress) | ConvertFrom-Json
    $hsText = ConvertTo-Json $hsSnap -Depth 6 -Compress -WarningAction SilentlyContinue
    Check 'and nothing in the sandbox''s snapshot goes past Depth 6: no value written as its .NET name' (
        $hsText -notmatch '"@\{' -and $hsText -notmatch 'System\.Collections\.') "$($hsText.Length) chars"
    $hsPlain = Invoke-ChatOverlayCycle (New-ChatOverlayContext) -Peek
    Check 'the headless snapshot: events and ui.spin, whole through Depth 6; a plain one has neither' (
        @($hsBack.events).Count -eq 1 -and (@($hsBack.events[0].keys) -join ',') -eq 'k1,k2' -and $hsBack.ui.spin -is [bool] -and
        -not $hsPlain.PSObject.Properties['events'] -and -not $hsPlain.PSObject.Properties['ui']) "$(ConvertTo-Json $hsBack.events -Compress -Depth 4)"

    # seen, or 10 minutes old, it goes; the rest carries to a new host
    Show-ChatOverlayBalloon $hsH 'second'
    $hsOld = [pscustomobject]@{ id = 'old-1'; at = (ConvertTo-ChatOverlayMs (Get-Date).AddMinutes(-11)); kind = 'balloon' }
    $hsH.Events.Add($hsOld)
    Update-ChatOverlayEvents $hsH ([pscustomobject]@{ at = (ConvertTo-ChatOverlayMs (Get-Date)); seen = @($hsE[0].id) })
    $hsLeft = @($hsH.Events | ForEach-Object { $_.text })
    $hsCarry = @(Read-ChatOverlayEvents | ForEach-Object { $_.text })
    Check 'an event the panel has seen goes, and one 10 minutes old; the rest is what a new host reads back' (
        ($hsLeft -join ',') -eq 'second' -and ($hsCarry -join ',') -eq 'second') "$($hsLeft -join ',') / $($hsCarry -join ',')"

    $hsNowMs = ConvertTo-ChatOverlayMs (Get-Date)
    Check 'the panel''s under way counts only while its word is under 10 s old' (
        (Test-ChatOverlayUiUnderWay ([pscustomobject]@{ at = $hsNowMs; underWay = $true })) -and
        -not (Test-ChatOverlayUiUnderWay ([pscustomobject]@{ at = $hsNowMs - 11000; underWay = $true })) -and
        -not (Test-ChatOverlayUiUnderWay ([pscustomobject]@{ at = $hsNowMs; underWay = $false })) -and -not (Test-ChatOverlayUiUnderWay $null)) ''

    # the host's own verbs stay out of the commands its panel reads; the
    # WPF and macOS hosts' snapshots keep them
    Send-ChatOverlayCommand 'close'
    Send-ChatOverlayCommand 'phone'
    Send-ChatOverlayCommand 'lock'
    $hsCxV = New-ChatOverlayContext
    $hsCxV.Events = [System.Collections.Generic.List[object]]::new()
    $hsSv = Invoke-ChatOverlayCycle $hsCxV
    Send-ChatOverlayCommand 'close'
    $hsSp = Invoke-ChatOverlayCycle (New-ChatOverlayContext)
    Check 'close and phone are the headless host''s, not in its panel''s commands; lock is; a plain context keeps close' (
        (@($hsSv.commands | ForEach-Object { $_.verb }) -join ',') -eq 'lock' -and (@($hsSp.commands | ForEach-Object { $_.verb }) -join ',') -eq 'close') "$(@($hsSv.commands | ForEach-Object { $_.verb }) -join ',') / $(@($hsSp.commands | ForEach-Object { $_.verb }) -join ',')"

    # a command between passes starts the next at once (-WakeMs)
    Remove-Item -LiteralPath $script:ChatOverlayCmdPath -Force -EA SilentlyContinue
    $script:HsPass = 0
    $hsSw = [System.Diagnostics.Stopwatch]::StartNew()
    $hsWake = Invoke-ChatOverlayCollectLoop (New-ChatOverlayContext) -IntervalMs 6000 -MaxCycles 2 -WakeMs 50 -OnCycle {
        param($s) $script:HsPass++; if ($script:HsPass -eq 1) { Send-ChatOverlayCommand 'lock' } }
    $hsMs = $hsSw.ElapsedMilliseconds
    Check 'the collector loop with -WakeMs: a command come in between passes starts the next at once, not after the interval' ($hsWake -eq 'max' -and $hsMs -lt 5000) "$hsWake $hsMs ms"
    # an overlay-cmd no pass can take (held open, no sharing) wakes no wait:
    # the passes keep their interval, said once in overlay.log, and once it
    # is let go the next pass takes it
    Remove-Item -LiteralPath $script:ChatOverlayCmdPath -Force -EA SilentlyContinue
    Send-ChatOverlayCommand 'lock'
    foreach ($k in @($script:ChatOverlayLogSeen.Keys)) { if ("$k" -like 'overlay-cmd cannot be taken*') { $script:ChatOverlayLogSeen.Remove($k) } }
    $hsStuckLog = { @([System.IO.File]::ReadAllLines((Join-Path $script:ChatqLogDir 'overlay.log'), $utf8) | Where-Object { $_ -like '*overlay-cmd cannot be taken - tried again each pass:*' }).Count }
    $hsStuck0 = & $hsStuckLog
    $hsHeld = [System.IO.File]::Open($script:ChatOverlayCmdPath, 'Open', 'ReadWrite', 'None')
    try {
        $hsSw = [System.Diagnostics.Stopwatch]::StartNew()
        $hsWakeL = Invoke-ChatOverlayCollectLoop (New-ChatOverlayContext) -IntervalMs 1500 -MaxCycles 3 -WakeMs 50
        $hsLockMs = $hsSw.ElapsedMilliseconds
        $hsWaitL = Test-ChatOverlayCmdWaiting
    }
    finally { $hsHeld.Dispose() }
    $hsStuckN = (& $hsStuckLog) - $hsStuck0
    $hsTaken = @(Receive-ChatOverlayCommands)
    Check 'an overlay-cmd no pass can take: no wait wakes for it, the passes keep their interval, said once; let go, the next pass takes it' (
        $hsWakeL -eq 'max' -and $hsLockMs -ge 2800 -and -not $hsWaitL -and $hsStuckN -eq 1 -and ($hsTaken -join ',') -eq 'lock' -and
        -not $script:ChatOverlayCmdStuck -and -not (Test-Path -LiteralPath $script:ChatOverlayCmdPath)) "$hsWakeL $hsLockMs ms / waiting $hsWaitL / said $hsStuckN / $($hsTaken -join ',')"

    # the commands the panel says it has done go from the snapshot's, so a
    # panel started again in its place does none twice
    $hsCm = New-ChatOverlayContext
    foreach ($i in 1..3) { $hsCm.Commands.Add([pscustomobject]@{ id = $i; verb = 'lock'; at = 0 }) }
    Update-ChatOverlayCommands $hsCm $null
    $hsCm1 = @($hsCm.Commands | ForEach-Object { $_.id }) -join ','
    Update-ChatOverlayCommands $hsCm ([pscustomobject]@{ at = 0; done = @(1, 3, 99) })
    Check 'the commands overlay-ui.json says are done leave the snapshot; no word, none do' (
        $hsCm1 -eq '1,2,3' -and (@($hsCm.Commands | ForEach-Object { $_.id }) -join ',') -eq '2') "$hsCm1 / $(@($hsCm.Commands | ForEach-Object { $_.id }) -join ',')"

    # the host whole: its panel started, a close from the panel taken at once,
    # the panel told to go before the close by hand is kept
    Remove-Item -LiteralPath $script:ChatOverlayCmdPath -Force -EA SilentlyContinue
    $script:HsLog = [System.Collections.Generic.List[string]]::new()
    $script:HsUiArgs = $null
    $script:ChatOverlayUiSpawnSeam = { param($Exe, $Data) $script:HsUiArgs = "$Exe|$Data"; Send-ChatOverlayCommand 'close'; & $hsChild $false }
    $hsSw = [System.Diagnostics.Stopwatch]::StartNew()
    $hsWhy = Start-ChatOverlayHeadlessHost -UiExe 'C:\ui\chatq-overlay.exe' -IntervalMs 3000 -MaxCycles 5
    $hsCloseMs = $hsSw.ElapsedMilliseconds
    $hsState = Read-ChatOverlayState
    Check 'the headless host: its panel started with the data folder, a close it sends taken, the panel gone before the close by hand is kept, the lock and pid let go' (
        $hsWhy -eq 'close' -and $script:HsUiArgs -eq "C:\ui\chatq-overlay.exe|$($script:ChatqData)" -and
        ($script:HsLog -join ';') -eq 'stdin closed, closedSignIn ' -and [int64]$hsState.closedSignIn -eq 1700000000000 -and
        -not (Test-Path -LiteralPath $script:ChatOverlayPidPath) -and -not (Test-ChatOverlayAlive) -and $script:HsRestarts -eq 0) "$hsWhy / $($script:HsUiArgs) /$($script:HsLog -join ';') / $($hsState.closedSignIn)"
    # that close by hand, as the WPF host's (Start-ChatOverlayHeadlessClose):
    # the process 4 s on, said in a balloon for the panel, which hides
    # meanwhile (the snapshot's ui.closing)
    $hsCb = @(Read-ChatOverlayEvents | Where-Object { $_.kind -eq 'balloon' -and $_.click -eq 'close' })
    $hsCs = Read-ChatqJson $script:ChatOverlayPath
    Check 'a close by hand: the process 4 s on, said in the panel''s balloon, the panel hidden meanwhile' (
        $hsCloseMs -ge 4000 -and $hsCb.Count -eq 1 -and $hsCb[0].text -eq 'Closed until you next sign in. Type charlie to bring it back sooner.' -and
        [int]$hsCb[0].ms -eq 4000 -and $hsCs.ui.closing -eq $true) "$hsCloseMs ms / $(ConvertTo-Json $hsCb -Compress) / $(ConvertTo-Json $hsCs.ui -Compress)"

    # The shell's verbs a pass at a time: each pass's look at the panel's
    # word (Read-ChatOverlayUi) sends the next, so the pass after has it.
    # The overlay asked for again in the 4 s takes the close back - the
    # hotkey shows the panel and does no more; outside a close the shell's
    # hotkey is the panel's (Send-ChatOverlayPanelVerb). A restart while a
    # close is on its way is the stop it waits for: the close kept, nothing
    # started.
    $hsKeep = @{ Ui = ${function:Read-ChatOverlayUi}; Note = ${function:Show-ChatOverlayAutoNotice}; Auto = ${function:Set-ChatqAutoContinue}
        Watch = ${function:Test-ChatqWatcherRequest}; Ra = ${function:Complete-ChatqResetAsk}; Cfg = ${function:Get-ChatOverlayConfig} }
    $script:HsPlan = @{}
    $script:HsPassN = 0
    ${function:Read-ChatOverlayUi} = { $script:HsPassN++; $v = $script:HsPlan[$script:HsPassN]; if ($v) { Send-ChatOverlayCommand $v }; $null }
    try {
        Remove-Item -LiteralPath $script:ChatOverlayCmdPath -Force -EA SilentlyContinue
        $script:HsLog = [System.Collections.Generic.List[string]]::new()
        $script:ChatOverlayUiSpawnSeam = { param($Exe, $Data) & $hsChild $false }
        $script:HsPlan = @{ 1 = 'hotkey'; 2 = 'close'; 3 = 'hotkey' }
        $script:HsPassN = 0
        $hsWhyU = Start-ChatOverlayHeadlessHost -UiExe 'C:\ui\chatq-overlay.exe' -IntervalMs 3000 -MaxCycles 5
        $hsU = Read-ChatqJson $script:ChatOverlayPath
        $hsUv = @($hsU.commands | ForEach-Object { $_.verb }) -join ','
        $hsUs = Read-ChatOverlayState
        Check 'the shell''s hotkey: the panel''s; in a close by hand''s 4 s it takes the close back - the panel shown, nothing kept' (
            $hsWhyU -eq 'max' -and $hsUv -eq 'hotkey,show' -and $hsU.ui.closing -eq $false -and $null -eq $hsUs.closedSignIn -and
            ($script:HsLog -join ';') -eq 'stdin closed, closedSignIn ') "$hsWhyU / $hsUv / $(ConvertTo-Json $hsU.ui -Compress) / $($hsUs.closedSignIn) / $($script:HsLog -join ';')"
        $script:HsPlan = @{ 1 = 'close'; 2 = 'restart' }
        $script:HsPassN = 0
        $hsR0 = $script:HsRestarts
        $hsWhyR = Start-ChatOverlayHeadlessHost -UiExe 'C:\ui\chatq-overlay.exe' -IntervalMs 3000 -MaxCycles 5
        $hsRs = Read-ChatOverlayState
        Check 'a restart while a close by hand is on its way: the stop, the close kept, no new process' (
            $hsWhyR -eq 'stop' -and [int64]$hsRs.closedSignIn -eq 1700000000000 -and $script:HsRestarts -eq $hsR0) "$hsWhyR / $($hsRs.closedSignIn) / $($script:HsRestarts)"

        # The panel's auto-continue choice: on said once what it does, as the
        # WPF box says it (Show-ChatOverlayAutoNotice) - besides the start's
        # look - and ask said nothing. The reset ask's answers followed as
        # the WPF host follows its own: one that found the ask changed (no
        # ask here at all) shows the panel opened out; the watcher one
        # asked for watched (Update-ChatOverlayAsk). The switch, the config's
        # ask and an answer's request stood in.
        $script:HsNotes = 0
        $script:HsAutoSet = @()
        $script:HsWatched = @()
        $script:HsKeepRa = $hsKeep.Ra
        $script:HsKeepCfg = $hsKeep.Cfg
        ${function:Show-ChatOverlayAutoNotice} = { param($H) $script:HsNotes++ }
        ${function:Set-ChatqAutoContinue} = { param($Value) $script:HsAutoSet += @($Value); $true }
        ${function:Get-ChatOverlayConfig} = { param($Cfg) $c = & $script:HsKeepCfg $Cfg; $c.autoContinue = 'ask'; $c }
        ${function:Complete-ChatqResetAsk} = {
            param($Ctx, $Answer, $Keys, $Source)
            if (@($Keys) -contains 'rq') { [pscustomobject]@{ Text = $null; Queued = @(); Fails = @(); Request = [pscustomobject]@{ rid = 'rq-1' }; Stale = $false } }
            else { & $script:HsKeepRa $Ctx $Answer $Keys -Source $Source }
        }
        ${function:Test-ChatqWatcherRequest} = { param($Request, $Queued) $script:HsWatched += @([string]$Request.rid); 'up' }
        Remove-Item -LiteralPath $script:ChatOverlayCmdPath -Force -EA SilentlyContinue
        $script:HsPlan = @{ 1 = 'auto-ask'; 2 = 'auto-on'; 3 = 'ask-go k9'; 4 = 'ask-go rq' }
        $script:HsPassN = 0
        $hsWhyA = Start-ChatOverlayHeadlessHost -UiExe 'C:\ui\chatq-overlay.exe' -IntervalMs 3000 -MaxCycles 6
        $hsA = Read-ChatqJson $script:ChatOverlayPath
        $hsAv = @($hsA.commands | ForEach-Object { $_.verb }) -join ','
        Check 'the panel''s auto-continue choice: on said once what it does, besides the start''s look; ask said nothing' (
            $hsWhyA -eq 'max' -and ($script:HsAutoSet -join ',') -eq 'ask,on' -and $script:HsNotes -eq 2) "$hsWhyA / $($script:HsAutoSet -join ',') / $($script:HsNotes)"
        Check 'the reset ask''s answer: one that found the ask changed shows the panel opened out; the watcher one asked for is watched' (
            $hsAv -eq 'show,expand' -and ($script:HsWatched -join ',') -eq 'rq-1') "$hsAv / $($script:HsWatched -join ',')"
    }
    finally {
        ${function:Read-ChatOverlayUi} = $hsKeep.Ui
        ${function:Show-ChatOverlayAutoNotice} = $hsKeep.Note
        ${function:Set-ChatqAutoContinue} = $hsKeep.Auto
        ${function:Test-ChatqWatcherRequest} = $hsKeep.Watch
        ${function:Complete-ChatqResetAsk} = $hsKeep.Ra
        ${function:Get-ChatOverlayConfig} = $hsKeep.Cfg
    }

    # a panel that keeps exiting is started again twice, then the host gives up;
    # a restart its panel sends starts the same headless launch
    $script:HsStarts = 0
    $script:HsSinces = [System.Collections.Generic.List[int64]]::new()
    $script:ChatOverlayUiSpawnSeam = { param($Exe, $Data, $Since) $script:HsStarts++; $script:HsSinces.Add($Since); & $hsChild $true }
    $hsWhy2 = Start-ChatOverlayHeadlessHost -UiExe 'C:\ui\chatq-overlay.exe' -IntervalMs 10 -MaxCycles 10
    $script:ChatOverlayUiSpawnSeam = { param($Exe, $Data) Send-ChatOverlayCommand 'restart'; & $hsChild $false }
    $hsWhy3 = Start-ChatOverlayHeadlessHost -UiExe 'C:\ui\chatq-overlay.exe' -IntervalMs 10 -MaxCycles 3
    $hsLaunch = Get-ChatOverlayLaunch -UiExe 'C:\ui\chatq-overlay.exe'
    Check 'a panel that keeps exiting: started 3 times in all, then the host stops; a restart from the panel relaunches headless' (
        $hsWhy2 -eq 'panel' -and $script:HsStarts -eq 3 -and $hsWhy3 -eq 'restart' -and $script:HsRestarts -eq 1 -and
        $hsLaunch.Command -like "*Start-ChatOverlayHeadlessHost -UiExe 'C:\ui\chatq-overlay.exe'*") "$hsWhy2 $($script:HsStarts) / $hsWhy3 $($script:HsRestarts)"
    Check 'and each panel started again is given the first one''s --since, so acts on the commands the last had not done' (
        $script:HsSinces.Count -eq 3 -and $script:HsSinces[0] -gt 1700000000000 -and @($script:HsSinces | Select-Object -Unique).Count -eq 1) ($script:HsSinces -join ',')

    # A restart starts the panel config.json asks for now: native keeps the
    # host's exe, ps the WPF one (charlie -Panel). One the first pass takes,
    # before any panel, keeps -Open's console for the next process. The
    # config's panel stood in, and a verb before that pass.
    $hsRk = @{ Cfg = ${function:Get-ChatOverlayConfig}; Us = ${function:Restore-ChatOverlayUsage}; Spawn = $script:ChatOverlaySpawn }
    $script:HsKeepCfg = $hsRk.Cfg
    $script:HsSpawnArgs = [System.Collections.Generic.List[string]]::new()
    $script:ChatOverlaySpawn = { param($Open, $UiExe) $script:HsRestarts++; $script:HsSpawnArgs.Add("$Open|$UiExe"); $true }
    ${function:Get-ChatOverlayConfig} = { param($Cfg) $c = & $script:HsKeepCfg $Cfg; $c.panel = $script:HsPanelCfg; $c }
    try {
        $script:ChatOverlayUiSpawnSeam = { param($Exe, $Data) Send-ChatOverlayCommand 'restart'; & $hsChild $false }
        foreach ($hsP in 'native', 'ps') {
            $script:HsPanelCfg = $hsP
            [void](Start-ChatOverlayHeadlessHost -UiExe 'C:\ui\chatq-overlay.exe' -IntervalMs 10 -MaxCycles 3)
        }
        ${function:Restore-ChatOverlayUsage} = { param($Ctx) Send-ChatOverlayCommand 'restart' }
        $hsWhyF = Start-ChatOverlayHeadlessHost -UiExe 'C:\ui\chatq-overlay.exe' -IntervalMs 10 -MaxCycles 3 -Open console
    }
    finally {
        ${function:Get-ChatOverlayConfig} = $hsRk.Cfg
        ${function:Restore-ChatOverlayUsage} = $hsRk.Us
        $script:ChatOverlaySpawn = $hsRk.Spawn
    }
    Check 'a restart starts the panel config.json asks for: native the host''s exe, ps the WPF one; one before any panel keeps the console asked for' (
        ($script:HsSpawnArgs -join ';') -eq '|C:\ui\chatq-overlay.exe;|;console|' -and $hsWhyF -eq 'restart') "$($script:HsSpawnArgs -join ';') / $hsWhyF"

    # the native panel's exe: staged beside the script as chatqd is, under
    # the version the script on disk says; native with none staged is the
    # WPF one, said in overlay.log; ps, the WPF one; and a launch with no
    # exe of its own given the one config.json asks for
    $hsRk = @{ Cfg = ${function:Get-ChatOverlayConfig}; Spawn = $script:ChatOverlaySpawn; Root = $script:ChatRoot }
    $hsPx = Join-Path $script:ChatqData 'panel-exe'
    $hsVer = Get-ChatqLoaderVersion $script:ChatqScriptPath
    if (-not $hsVer) { $hsVer = $script:ChatVersion }
    $hsPxExe = [System.IO.Path]::Combine($hsPx, 'bin', $hsVer, 'x86_64-pc-windows-msvc', 'chatq-overlay.exe')
    $hsNat = [pscustomobject]@{ panel = 'native' }
    $script:HsSpawnArgs = [System.Collections.Generic.List[string]]::new()
    try {
        $script:ChatRoot = $hsPx
        $hsPxNone = Get-ChatOverlayPanelExe -Config $hsNat
        $hsPxQuiet = Get-ChatOverlayPanelExe -Config $hsNat -Quiet
        New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($hsPxExe)) | Out-Null
        [System.IO.File]::WriteAllBytes($hsPxExe, [byte[]]@())
        $hsPxGot = Get-ChatOverlayPanelExe -Config $hsNat
        $hsPxPs = Get-ChatOverlayPanelExe -Config ([pscustomobject]@{ panel = 'ps' })
        $script:ChatOverlaySpawn = { param($Open, $UiExe) $script:HsSpawnArgs.Add("$Open|$UiExe"); $true }
        ${function:Get-ChatOverlayConfig} = { param($Cfg) $c = & $script:HsKeepCfg $Cfg; $c.panel = 'native'; $c }
        [void](Start-ChatOverlayProcess -Open console)
    }
    finally {
        $script:ChatRoot = $hsRk.Root
        ${function:Get-ChatOverlayConfig} = $hsRk.Cfg
        $script:ChatOverlaySpawn = $hsRk.Spawn
        Remove-Item -LiteralPath $hsPx -Recurse -Force -EA SilentlyContinue
    }
    $hsPxLog = @([System.IO.File]::ReadAllLines((Join-Path $script:ChatqLogDir 'overlay.log'), $utf8) | Where-Object { $_.EndsWith("the native panel asked for, but $hsPxExe is not there - the WPF one instead") }).Count
    Check 'the native panel''s exe: bin/<version>/x86_64-pc-windows-msvc beside the script; none staged, the WPF one, said once; ps, the WPF one; a launch given it' (
        $hsPxNone -eq '' -and $hsPxQuiet -eq '' -and $hsPxGot -eq $hsPxExe -and $hsPxPs -eq '' -and $hsPxLog -eq 1 -and
        ($script:HsSpawnArgs -join ';') -eq "console|$hsPxExe") "'$hsPxNone' '$hsPxGot' '$hsPxPs' / said $hsPxLog / $($script:HsSpawnArgs -join ';')"

    # a verb's words: only the ones its verb takes, one space apart; a line
    # whose words do not fit is dropped whole
    Remove-Item -LiteralPath $script:ChatOverlayCmdPath -Force -EA SilentlyContinue
    foreach ($l in 'opened s:abc-1 0', 'opened  s:abc-1   -25 ', 'delete s:abc-1', 'card recent:x.y', 'reload-answer 12:r1 reload',
        'reload-answer 12:r1 now', 'delete s:a b', 'show now', 'ask-go k1,k2', 'opened s:abc 123456', 'card s:a"b', 'delete S:abc') { Send-ChatOverlayCommand $l }
    $hsRx = @(Receive-ChatOverlayCommands)
    Check 'the panel''s verbs keep their words, one space apart; words another verb takes, or that do not fit, drop the line' (
        ($hsRx -join '|') -eq 'opened s:abc-1 0|opened s:abc-1 -25|delete s:abc-1|card recent:x.y|reload-answer 12:r1 reload|ask-go k1,k2|delete S:abc') ($hsRx -join '|')
    Check 'Test-ChatOverlayVerbArg: each verb its own words, case and all' (
        (Test-ChatOverlayVerbArg 'card' 'j:q-1') -and -not (Test-ChatOverlayVerbArg 'card' '') -and -not (Test-ChatOverlayVerbArg 'Card' 's:a') -and
        -not (Test-ChatOverlayVerbArg 'opened' 's:a x') -and -not (Test-ChatOverlayVerbArg 'reload-answer' '12:r1 Reload') -and
        -not (Test-ChatOverlayVerbArg 'lock' 'now') -and (Test-ChatOverlayVerbArg 'ask-leave' 'k1')) ''

    # and they stay out of every host's panel commands
    Send-ChatOverlayCommand 'card s:x'
    Send-ChatOverlayCommand 'lock'
    $hsCk = New-ChatOverlayContext
    $hsSk = Invoke-ChatOverlayCycle $hsCk
    Check 'a panel''s verb reaches the host (Verbs), never a panel''s commands' (
        (@($hsSk.commands | ForEach-Object { $_.verb }) -join ',') -eq 'lock' -and @($hsCk.Verbs) -contains 'card s:x') "$(@($hsSk.commands | ForEach-Object { $_.verb }) -join ',') / $(@($hsCk.Verbs) -join ',')"

    # the verbs carried out (Invoke-ChatOverlayPanelVerb), what is outside
    # the host stood in for, and each says its outcome back as a said event
    ${function:Get-ChatqLiveSessions} = { @() }
    ${function:Remove-ChatSessionById} = { param($SessionId, $Cwd, $Title, $ConfigDir, $Live) $script:HsRmLog += $SessionId; @{ Done = $true; Say = "Deleted '$Title'." } }
    ${function:Write-ChatReloadAnswer} = { param($HostPid, $Id, $Answer) $script:HsAnsLog += "$HostPid/$Id/$Answer" }
    $script:HsRmLog = @()
    $script:HsAnsLog = @()
    $hsV = New-ChatOverlayHeadlessState
    $hsV.Ctx = New-ChatOverlayContext
    $hsV.Ctx.Unread = @{ abc = $true; def = $true }
    $hsV.Ctx.Reloads = @([pscustomobject]@{ pid = 12; id = 'r1'; window = 'proj - VS Code' })
    $hsRow = { param($Sid, $St, $Where) [pscustomobject]@{ key = "s:$Sid"; kind = 'session'; status = $St; where = $Where; sessionId = $Sid; title = "chat $Sid"; cwd = 'C:\w\proj' } }
    $hsVs = [pscustomobject]@{ rows = @((& $hsRow 'abc' 'idle' 'vscode'), (& $hsRow 'busy1' 'busy' 'vscode')); recent = @((& $hsRow 'def' 'recent' '')); recentMore = @() }
    $hsV.Snap = [pscustomobject]@{ rows = @((& $hsRow 'old' 'idle' 'vscode')); recent = @(); recentMore = @() }
    $hsVr = @(
        (Invoke-ChatOverlayPanelVerb $hsV 'opened s:abc 0' $hsVs),
        (Invoke-ChatOverlayPanelVerb $hsV 'opened s:old 15' $hsVs),
        (Invoke-ChatOverlayPanelVerb $hsV 'delete s:def' $hsVs),
        (Invoke-ChatOverlayPanelVerb $hsV 'delete s:busy1' $hsVs),
        (Invoke-ChatOverlayPanelVerb $hsV 'delete s:gone' $hsVs),
        (Invoke-ChatOverlayPanelVerb $hsV 'reload-answer 12:r1 later' $hsVs),
        (Invoke-ChatOverlayPanelVerb $hsV 'reload-answer 99:r1 reload' $hsVs),
        (Invoke-ChatOverlayPanelVerb $hsV 'card s:abc' $hsVs))
    $hsSaid = @($hsV.Events | Where-Object { $_.kind -eq 'said' })
    $hsBal = @($hsV.Events | Where-Object { $_.kind -eq 'balloon' } | ForEach-Object { $_.text })
    $hsSaidText = @($hsSaid | ForEach-Object { "$($_.about)=$($_.said)/$($_.tone)/$($_.ms)" })
    Check 'opened: the unread dot gone on 0, the said marker on its row; 15 a balloon and a warning, its row found in the pass before' (
        $hsVr[0] -and $hsVr[1] -and -not $hsV.Ctx.Unread.ContainsKey('abc') -and $hsSaid[0].text -eq "opened 'chat abc'" -and
        $hsSaidText[0] -eq 's:abc=done/dim/5000' -and $hsSaidText[1] -eq 's:old=done/warn/20000' -and $hsSaid[1].text -like "'chat old' - A queued prompt*" -and
        $hsBal[0] -like 'A queued prompt is running*') "$($hsSaidText -join ' ') / $($hsBal -join ' | ')"
    Check 'delete: a Recent row deleted, its dot gone and the balloon said; one at work, or gone from the panel, kept with a warning' (
        $hsVr[2] -and $hsVr[3] -and $hsVr[4] -and ($script:HsRmLog -join ',') -eq 'def' -and -not $hsV.Ctx.Unread.ContainsKey('def') -and
        $hsV.Ctx.RecentAt -eq [datetime]::MinValue -and $hsBal -contains "Deleted 'chat def'." -and
        $hsSaidText[2] -eq 's:def=delete/dim/5000' -and $hsSaidText[3] -eq 's:busy1=delete/warn/20000' -and $hsSaid[3].text -like 'Nothing deleted - not while*' -and
        $hsSaidText[4] -eq 's:gone=delete/warn/20000' -and $hsSaid[4].text -like '*not on the panel any more.') "$($hsSaidText -join ' ') / $($script:HsRmLog -join ',')"
    Check 'reload-answer: the window''s ask answered and left out; one no window has now is not' (
        $hsVr[5] -and -not $hsVr[6] -and ($script:HsAnsLog -join ',') -eq '12/r1/later' -and $hsV.Ctx.ReloadAnswered.ContainsKey('12:r1') -and
        $hsSaidText[5] -eq 'reload:12=reload/dim/6000' -and $hsSaid[5].text -eq 'left for later - the notice is still in proj - VS Code' -and $hsSaid.Count -eq 6) "$($hsSaidText -join ' ') / $($script:HsAnsLog -join ',')"
    $hsCard = Read-ChatqJson $script:ChatOverlayCardPath
    Check 'card: the row''s hover card written to card.json, with its key; nothing said' (
        -not $hsVr[7] -and $hsCard.key -eq 's:abc' -and $hsCard.model -and [string](Get-ChatField $hsCard.model 'Title') -eq 'chat abc' -and [int64]$hsCard.at -gt 0) "$(ConvertTo-Json $hsCard -Compress -Depth 6)"

    # the native panel's newer words (M9a): an open's look for its window,
    # the panel's own ends, a setting of its box, the chip's auto-continue
    $hsKeepCfg = ${function:Set-ChatOverlayConfig}
    $hsKeepAuto = ${function:Invoke-ChatOverlayAutoChip}
    $hsKeepGet = ${function:Get-ChatOverlayConfig}
    ${function:Get-ChatOverlayConfig} = { @{} }
    ${function:Set-ChatOverlayConfig} = { param([hashtable]$Values) $script:HsCfgLog += @($Values.Keys | ForEach-Object { "$_=$($Values[$_])" }) }
    ${function:Invoke-ChatOverlayAutoChip} = { param($H, $Row, [string]$Act) $script:HsAutoLog += "$($Row.key)/$Act" }
    $script:HsCfgLog = @()
    $script:HsAutoLog = @()
    $hsW = New-ChatOverlayHeadlessState
    $hsW.Ctx = New-ChatOverlayContext
    $hsW.Ctx.Unread = @{ abc = $true }
    try {
        $hsWr = @(
            (Invoke-ChatOverlayPanelVerb $hsW 'opened s:abc 25 front' $hsVs),
            (Invoke-ChatOverlayPanelVerb $hsW 'opened s:abc 0 behind' $hsVs),
            (Invoke-ChatOverlayPanelVerb $hsW 'opened s:abc late' $hsVs),
            (Invoke-ChatOverlayPanelVerb $hsW 'opened s:abc nostart' $hsVs),
            (Invoke-ChatOverlayPanelVerb $hsW 'config opacity 0.256' $hsVs),
            (Invoke-ChatOverlayPanelVerb $hsW 'config maxRows 44' $hsVs),
            (Invoke-ChatOverlayPanelVerb $hsW 'config theme light' $hsVs),
            (Invoke-ChatOverlayPanelVerb $hsW 'auto-chip s:abc dont' $hsVs),
            (Invoke-ChatOverlayPanelVerb $hsW 'auto-chip s:gone continue' $hsVs))
    }
    finally {
        ${function:Set-ChatOverlayConfig} = $hsKeepCfg
        ${function:Invoke-ChatOverlayAutoChip} = $hsKeepAuto
        ${function:Get-ChatOverlayConfig} = $hsKeepGet
    }
    $hsWs = @($hsW.Events | Where-Object { $_.kind -eq 'said' } | ForEach-Object { "$($_.said)/$($_.tone)" })
    $hsWb = @($hsW.Events | Where-Object { $_.kind -eq 'balloon' } | ForEach-Object { $_.text })
    Check 'opened with a look: 25 in front says 0''s words, 0 left behind says so; late and nostart said, late a balloon too' (
        ($hsWr[0..3] -notcontains $false) -and -not $hsW.Ctx.Unread.ContainsKey('abc') -and
        ($hsWs[0..3] -join ',') -eq 'done/dim,done/warn,late/warn,nostart/warn' -and $hsWb.Count -eq 1 -and $hsWb[0] -like 'The open got no answer in 60 s*') "$($hsWs -join ',') / $($hsWb -join ' | ')"
    Check 'config: the box''s settings saved, in range; auto-chip: the chip''s answer for a row it has, none for one gone' (
        ($script:HsCfgLog -join ',') -eq 'opacity=0.3,maxRows=30,theme=light' -and ($script:HsAutoLog -join ',') -eq 's:abc/dont' -and
        $hsWr[4] -and $hsWr[7] -and -not $hsWr[8]) "$($script:HsCfgLog -join ',') / $($script:HsAutoLog -join ',')"
    Check 'Test-ChatOverlayVerbArg: the native panel''s words - a look, its own ends, a setting, a chip''s answer' (
        (Test-ChatOverlayVerbArg 'opened' 's:a 0 front') -and (Test-ChatOverlayVerbArg 'opened' 's:a late') -and -not (Test-ChatOverlayVerbArg 'opened' 's:a 0 sideways') -and
        (Test-ChatOverlayVerbArg 'config' 'opacity 0.85') -and (Test-ChatOverlayVerbArg 'config' 'theme system') -and -not (Test-ChatOverlayVerbArg 'config' 'hotkey Ctrl+Q') -and
        (Test-ChatOverlayVerbArg 'auto-chip' 's:a continue') -and -not (Test-ChatOverlayVerbArg 'auto-chip' 's:a later')) ''

    # a verb acted on starts the next pass at once ($Ctx.PassNow)
    $hsPn = New-ChatOverlayContext
    $script:HsPnN = 0
    $hsSw = [System.Diagnostics.Stopwatch]::StartNew()
    $hsPw = Invoke-ChatOverlayCollectLoop $hsPn -IntervalMs 6000 -MaxCycles 2 -OnCycle { param($s) if (-not ($script:HsPnN++)) { $hsPn.PassNow = $true } }
    Check 'the collector loop: PassNow set, the next pass starts at once, and is let go' ($hsPw -eq 'max' -and $hsSw.ElapsedMilliseconds -lt 5000 -and -not $hsPn.PassNow) "$hsPw $($hsSw.ElapsedMilliseconds) ms"

    # the whole host takes a panel's verb: a delete of a row not there is said
    Remove-Item -LiteralPath $script:ChatOverlayCmdPath -Force -EA SilentlyContinue
    Remove-Item -LiteralPath $script:ChatOverlayEventsPath -Force -EA SilentlyContinue
    $script:HsLog = [System.Collections.Generic.List[string]]::new()
    $script:ChatOverlayUiSpawnSeam = { param($Exe, $Data) Send-ChatOverlayCommand 'delete s:nope'; & $hsChild $false }
    $hsWhyV = Start-ChatOverlayHeadlessHost -UiExe 'C:\ui\chatq-overlay.exe' -IntervalMs 3000 -MaxCycles 2
    $hsEv = @(Read-ChatOverlayEvents | Where-Object { $_.kind -eq 'said' })
    Check 'the headless host carries out its panel''s delete, and the said event is in overlay-events.json' (
        $hsWhyV -eq 'max' -and $hsEv.Count -eq 1 -and $hsEv[0].about -eq 's:nope' -and $hsEv[0].tone -eq 'warn') "$hsWhyV / $(ConvertTo-Json $hsEv -Compress)"

    # the headless launch loads only the collector's parts; the WPF one all
    $hsLu = Get-ChatOverlayLaunch -UiExe 'C:\ui\chatq-overlay.exe'
    $hsLw = Get-ChatOverlayLaunch
    $hsLc = Get-ChatOverlayLaunch -UiExe 'C:\ui\chatq-overlay.exe' -Open console
    Check 'the headless launch: CHATQ_OVERLAY, no CHATQ_ALLPARTS; the WPF one still both; chatconsole''s headless one opens the console' (
        $hsLu.Command -like "*`$env:CHATQ_OVERLAY='1'*" -and $hsLu.Command -notlike '*$env:CHATQ_ALLPARTS=*' -and
        $hsLw.Command -like "*`$env:CHATQ_ALLPARTS='1'*" -and $hsLw.Command -like "*`$env:CHATQ_OVERLAY='1'*" -and
        $hsLc.Command -like "*Start-ChatOverlayHeadlessHost -UiExe 'C:\ui\chatq-overlay.exe' -Open 'console')*" -and $hsLc.Command -notlike '*$env:CHATQ_ALLPARTS=*' -and
        $hsLu.Command -notlike '*-Open*') "$($hsLu.Command) / $($hsLw.Command) / $($hsLc.Command)"

    # a restart onto new code starts the new code's panel
    $hsBin = [System.IO.Path]::GetFullPath((Join-Path $script:ChatqData 'hs-bin'))
    $hsLeaf = 'x86_64-pc-windows-msvc\chatq-overlay.exe'
    foreach ($v in '0.9.0', '1.0.0') { $f = Join-Path (Join-Path "$hsBin\bin" $v) $hsLeaf; New-ChatqDir (Split-Path -Parent $f); Set-Content -LiteralPath $f -Value '' }
    $hsSp0 = "$hsBin\Charlie-and-the-chat-factory.ps1"
    $hsOld = "$hsBin\bin\0.9.0\$hsLeaf"
    [System.IO.File]::WriteAllText($hsSp0, "`$script:ChatVersion = '1.0.0'`n")
    Check 'Resolve-ChatOverlayUiExe: a staged panel follows the code''s version - the script''s on disk unless named - while it has one, none (the WPF one) when it has none; a build of your own stays' (
        (Resolve-ChatOverlayUiExe $hsOld $hsSp0 '1.0.0') -eq "$hsBin\bin\1.0.0\$hsLeaf" -and
        (Resolve-ChatOverlayUiExe $hsOld $hsSp0) -eq "$hsBin\bin\1.0.0\$hsLeaf" -and
        (Resolve-ChatOverlayUiExe $hsOld $hsSp0 '2.0.0') -eq '' -and
        (Resolve-ChatOverlayUiExe 'C:\ui\chatq-overlay.exe' $hsSp0 '1.0.0') -eq 'C:\ui\chatq-overlay.exe' -and
        (Resolve-ChatOverlayUiExe "$hsBin\bin\a\0.9\$hsLeaf" $hsSp0 '1.0.0') -eq "$hsBin\bin\a\0.9\$hsLeaf" -and
        (Resolve-ChatOverlayUiExe '' $hsSp0 '1.0.0') -eq '') "$(Resolve-ChatOverlayUiExe $hsOld $hsSp0 '1.0.0') / $(Resolve-ChatOverlayUiExe $hsOld $hsSp0) / $(Resolve-ChatOverlayUiExe $hsOld $hsSp0 '2.0.0')"

    # The host whole agrees with a fresh start (Get-ChatOverlayPanelExe):
    # its restart onto code whose version has no panel staged starts the
    # WPF one, not the old version's; a host started for such a version
    # hands over to the WPF one at once, its panel never started. The
    # script on disk is the stand-in loader, rewritten to 2.0.0 as the panel
    # starts, as an update would.
    $hsVk = @{ Cfg = ${function:Get-ChatOverlayConfig}; Spawn = $script:ChatOverlaySpawn; Sp = $script:ChatqScriptPath }
    $script:HsKeepCfg = $hsVk.Cfg
    $script:HsSpawnArgs = [System.Collections.Generic.List[string]]::new()
    $script:HsUiArgs = @()
    $script:ChatOverlaySpawn = { param($Open, $UiExe) $script:HsSpawnArgs.Add("$Open|$UiExe"); $true }
    ${function:Get-ChatOverlayConfig} = { param($Cfg) $c = & $script:HsKeepCfg $Cfg; $c.panel = 'native'; $c }
    try {
        $script:ChatqScriptPath = $hsSp0
        Remove-Item -LiteralPath $script:ChatOverlayCmdPath -Force -EA SilentlyContinue
        $script:ChatOverlayUiSpawnSeam = { param($Exe, $Data) $script:HsUiArgs += @($Exe); [System.IO.File]::WriteAllText($hsSp0, "`$script:ChatVersion = '2.0.0'`n"); Send-ChatOverlayCommand 'restart'; & $hsChild $false }
        $hsWhyN = Start-ChatOverlayHeadlessHost -UiExe $hsOld -IntervalMs 10 -MaxCycles 3
        $hsWhyN2 = Start-ChatOverlayHeadlessHost -UiExe "$hsBin\bin\1.0.0\$hsLeaf" -IntervalMs 10 -MaxCycles 3
    }
    finally {
        ${function:Get-ChatOverlayConfig} = $hsVk.Cfg
        $script:ChatOverlaySpawn = $hsVk.Spawn
        $script:ChatqScriptPath = $hsVk.Sp
    }
    Check 'a restart onto a version with no panel staged starts the WPF one, as a fresh start does; a host started for one hands over to it at once' (
        $hsWhyN -eq 'restart' -and $hsWhyN2 -eq 'restart' -and ($script:HsUiArgs -join ';') -eq "$hsBin\bin\1.0.0\$hsLeaf" -and
        ($script:HsSpawnArgs -join ';') -eq '|;|') "$hsWhyN $hsWhyN2 / $($script:HsUiArgs -join ';') / $($script:HsSpawnArgs -join ';')"

    # step 4's check: the headless host's overlay.json is the WPF host's on
    # the same sandbox, once what only the moment or the process says is
    # masked - pid, at, version, the reset clocks - and its own ui and
    # events gone
    Remove-Item -LiteralPath $script:ChatOverlayCmdPath -Force -EA SilentlyContinue
    $script:HsLog = [System.Collections.Generic.List[string]]::new()
    $script:ChatOverlayUiSpawnSeam = { param($Exe, $Data) & $hsChild $false }
    $script:ChatOverlayUsageSeam = { @{ Ok = $true; Status = 200; Windows = @([pscustomobject]@{ Label = '5h'; Percent = 10; ResetsAt = [datetime]'2030-01-01T03:00:00'; Severity = 'normal' }) } }
    Remove-Item -LiteralPath $script:ChatOverlayPath -Force -EA SilentlyContinue
    $null = Start-ChatOverlayHeadlessHost -UiExe 'C:\ui\chatq-overlay.exe' -IntervalMs 10 -MaxCycles 1
    $hsA = Read-ChatqJson $script:ChatOverlayPath
    $hsW = New-ChatOverlayContext
    $hsW.RecentPool = $true
    $hsW.CodeStamp = Get-ChatOverlayCodeStamp
    $hsW.CodeLookAt = Get-Date
    $hsW.WantPhone = $true
    $hsW.WantAsk = $true
    $hsW.WantAuto = $true
    Restore-ChatOverlayUsage $hsW
    Remove-Item -LiteralPath $script:ChatOverlayPath -Force -EA SilentlyContinue
    # two passes, as the host's start and its one loop pass
    [void](Invoke-ChatOverlayCycle $hsW)
    [void](Invoke-ChatOverlayCycle $hsW)
    $hsB = Read-ChatqJson $script:ChatOverlayPath
    $hsMask = {
        param($S)
        if (-not $S) { return '' }
        foreach ($p in 'ui', 'events') { $S.PSObject.Properties.Remove($p) }
        # a Recent row's state is how long ago, a clock too
        (ConvertTo-Json $S -Depth 12 -Compress) -replace '"(pid|at|version|asOf|since)":(-?\d+|"[^"]*"|null)', '"$1":0' -replace '"stateText":"\d[^"]*"', '"stateText":0'
    }
    $hsHasEv = [bool]($hsA -and $hsA.PSObject.Properties['events'])
    $hsMa = & $hsMask $hsA
    $hsMb = & $hsMask $hsB
    $hsAt = 0
    while ($hsAt -lt [Math]::Min($hsMa.Length, $hsMb.Length) -and $hsMa[$hsAt] -eq $hsMb[$hsAt]) { $hsAt++ }
    Check 'the headless host''s overlay.json is the WPF host''s, pid, at, version and clocks masked' (
        $hsHasEv -and $hsMa -and $hsMa -eq $hsMb) "at $hsAt of $($hsMa.Length)/$($hsMb.Length): $($hsMa.Substring([Math]::Max(0, $hsAt - 60), [Math]::Min(160, [Math]::Max(0, $hsMa.Length - $hsAt + 60)))) // $($hsMb.Substring([Math]::Max(0, $hsAt - 60), [Math]::Min(160, [Math]::Max(0, $hsMb.Length - $hsAt + 60))))"

    # The headless launch itself, each run in a Windows PowerShell of its own
    # (Invoke-Sta -Global): the tool loaded as Get-ChatOverlayLaunch loads it,
    # without CHATQ_ALLPARTS, into the global scope, from a copy whose data
    # folder is its own, so the sandbox's is never touched; the sandbox's
    # seams, and a stand-in panel whose look at whether it has exited
    # (HasExited) is each pass's hook: it checks what the pass did and sends
    # the next verb, as the panel would. Each run gives back which of its
    # checks held. A function the launch leaves out fails them by the throw
    # it makes ($Error) or the line it leaves in overlay.log.
    $hsToolDir = Join-Path $sb 'hs-tool'
    Remove-Item -LiteralPath $hsToolDir -Recurse -Force -EA SilentlyContinue
    $null = New-Item -ItemType Directory -Path $hsToolDir -Force
    Copy-Item -LiteralPath (Join-Path $root 'Charlie-and-the-chat-factory.ps1') -Destination $hsToolDir
    Copy-Item -LiteralPath (Join-Path $root 'src') -Destination $hsToolDir -Recurse
    $hsTool = (Join-Path $hsToolDir 'Charlie-and-the-chat-factory.ps1').Replace("'", "''")
    $hsHead = @'
$MaximumErrorCount = 10000
Remove-Item -LiteralPath 'env:CHATQ_ALLPARTS' -EA SilentlyContinue
$env:CHATQ_OVERLAY = '1'
. '@TOOL@'
Set-StrictMode -Off
$global:ChatqToastSeam = { param($t, $x) }
$global:ChatqFooterSeam = { $null }
$global:ChatqIdleSeam = 99999
$global:ChatqNtfySeam = { param($server, $body, $headers) }
$global:ChatqDownSeam = { param($m, $u, $h, $b) $null }
$global:ChatNoGhostWatch = $true
$global:ChatqSpawn = { $true }
$global:ChatStopSeam = { param($e) 'gone' }
$global:ChatParentSeam = { param($e) @{ Pid = 4242; Name = 'Code'; StartTime = [datetime]::MinValue } }
$global:ChatCodeSeam = { param($f) [pscustomobject]@{ Ok = $true; Code = 'ok'; Why = $null; Slow = $false } }
$global:ChatWindowTitlesSeam = { @() }
$global:ChatCodeExesSeam = { @() }
$global:ChatCodeProfilesSeam = { @() }
$global:ChatShowSpawnSeam = { param($c) $null }
$global:ChatCodeWindowListSeam = { @() }
$global:ChatOverlayRaiseSeam = { param($c, $h, $o) $null }
$global:ChatOverlayGrantSeam = { param($p) @() }
$global:ChatOverlayCodexUsageSeam = { param($h) @{ Ok = $false; Why = 'no app-server in the tests'; Quiet = $true } }
$global:ChatShowHoldSeconds = 0
$global:ChatHandoverOff = $true
$global:ChatHostLogRootsSeam = { @() }
$global:ChatMemorySeam = { @{ Limit = 32GB; Free = 16GB } }
$global:ChatMemoryTopSeam = { @() }
$global:ChatMemorySumsSeam = { @{} }
$global:ChatOverlayUsageSeam = { @{ Ok = $true; Status = 200; Windows = @() } }
$global:ChatqSignInSeam = { [int64]1700000000000 }
$global:ChatOverlaySpawn = { $true }
# windows looked at, never moved or brought forward
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class HsWin {
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int value, int size);
    public static IntPtr Front() { return GetForegroundWindow(); }
    public static int FrontPid() { IntPtr h = GetForegroundWindow(); if (h == IntPtr.Zero) { return 0; } uint pid; GetWindowThreadProcessId(h, out pid); return (int)pid; }
    public static bool Cloaked(IntPtr h) { int v; return DwmGetWindowAttribute(h, 14, out v, 4) == 0 && v != 0; }
}
"@
$global:HsOk = [ordered]@{}
$global:HsSay = [System.Collections.Generic.List[string]]::new()
$global:HsLogPath = Join-Path $global:ChatqLogDir 'overlay.log'
$global:HsN = 0
$global:HsT = @{}
$global:HsPlan = @{}
$global:HsNote = { param([string]$Key, [string]$Text) if (-not $global:HsOk[$Key]) { $global:HsSay.Add("${Key}: $Text") } }
$global:HsCmds = { param([string]$Verb) @($H.Ctx.Commands | Where-Object { $_.verb -eq $Verb }).Count }
# the panel's process: each look at HasExited is a pass's hook, the steps
# HsPlan has for it - a check, or a verb sent for the pass after
$global:HsPanel = [pscustomobject]@{ Gone = $false; ExitCode = 0 }
$global:HsPanel | Add-Member -MemberType ScriptProperty -Name HasExited -Value {
    if (-not $this.Gone) {
        $global:HsN++
        $global:HsT[$global:HsN] = [datetime]::UtcNow
        foreach ($hsStep in @($global:HsPlan[$global:HsN])) {
            if ($null -eq $hsStep) { continue }
            try { if ($hsStep -is [scriptblock]) { $null = & $hsStep } else { $null = Send-ChatOverlayCommand ([string]$hsStep) } }
            catch { $global:HsSay.Add("pass $($global:HsN): $($_.Exception.Message)") }
        }
    }
    [bool]$this.Gone
}
$hsIn = [pscustomobject]@{ Owner = $global:HsPanel }
$hsIn | Add-Member -MemberType ScriptMethod -Name Close -Value { $this.Owner.Gone = $true }
$global:HsPanel | Add-Member -NotePropertyName StandardInput -NotePropertyValue $hsIn
$global:HsPanel | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) $this.Gone }
$global:HsPanel | Add-Member -MemberType ScriptMethod -Name Kill -Value { }
$global:ChatOverlayUiSpawnSeam = { param($Exe, $Data) $global:HsPanel }
'@
    $hsTail = @'
# a function the launch left out, called: its throw, caught or not, and its log line
$hsMiss = [System.Collections.Generic.List[string]]::new()
foreach ($hsE in @($global:Error)) {
    if (-not $hsE -or [string]$hsE.FullyQualifiedErrorId -like '*GetCommandCommand') { continue }
    $hsX = if ($hsE -is [System.Management.Automation.ErrorRecord]) { $hsE.Exception } else { $hsE }
    while ($hsX) {
        if ($hsX -is [System.Management.Automation.CommandNotFoundException] -and [string]$hsX.CommandName -like '*-Chat*' -and -not $hsMiss.Contains([string]$hsX.CommandName)) { $hsMiss.Add([string]$hsX.CommandName) }
        $hsX = $hsX.InnerException
    }
}
$global:HsOk.missing = $hsMiss.Count -eq 0
if ($hsMiss.Count) { $global:HsSay.Add("missing: $($hsMiss -join ', ')") }
$hsLines = @()
if (Test-Path -LiteralPath $global:HsLogPath) { $hsLines = @([System.IO.File]::ReadAllLines($global:HsLogPath) | Where-Object { $_ }) }
$hsBad = @($hsLines | Where-Object { $_ -match '''\w+-Chat\w*''' -or $_ -like '*is not recognized*' -or $_ -like '*overlay failed*' })
$global:HsOk.log = $hsBad.Count -eq 0
if ($hsBad.Count) { $global:HsSay.Add("log: $($hsBad -join ' | ')") }
if ($global:HsSay.Count -or @($global:HsOk.Values) -contains $false) { $global:HsSay.Add("log tail: $(@($hsLines | Select-Object -Last 6) -join ' | ')") }
ConvertTo-Json ([ordered]@{ ok = $global:HsOk; say = @($global:HsSay) }) -Compress -Depth 4
'@
    # B2, the console on the headless host: cloaked, so drawn and never seen,
    # and brought forward only through its seam, so never in front. Its
    # parts load at its first ask; it opens grown from the native panel's
    # top-right corner (overlay-ui.json's rect, on a screen the work-area
    # seam makes wide enough at any scale), interactive while the panel
    # hides; then back to the panel and in again, by each verb that does it,
    # and a close from inside it.
    $hsConsoleBody = @'
& {
    try {
        $env:CHATQ_CLOAK = '1'
        $global:ChatForegroundSeam = { 0 }
        $global:HsOk.before = -not ${function:New-ChatConsole} -and -not ${function:New-ChatOverlayWindow} -and $null -eq $global:ChatOverlayNativeCode
        $global:ChatOverlayWorkAreaSeam = { param($r) [pscustomobject]@{ X = -6000; Y = 0; Width = 3840; Height = 2160 } }
        Save-ChatqText $global:ChatOverlayUiPath (ConvertTo-Json @{ at = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); rect = @(-2594, 197, 380, 300) } -Compress)
        # the real import, then the console's own seams, which its load sets anew
        $global:HsImport = ${function:Import-ChatOverlayConsoleParts}
        $global:HsImports = 0
        $global:HsFront = 0
        function global:Import-ChatOverlayConsoleParts {
            param($Ctx)
            $global:HsImports++
            try { & $global:HsImport $Ctx }
            finally { $global:ChatConsoleNoSync = $true; $global:ChatConsoleFrontSeam = { param($w) $global:HsFront++ } }
        }
        $global:HsShown = {
            param($W, [string]$Name)
            $hw = $W.Hwnd
            $x = [ChatOverlayNative]::GetExStyle($hw)
            $ok = [ordered]@{
                mode = $W.Mode -eq 'console' -and [object]::ReferenceEquals($W.Win.Content, $W.Con.Root)
                shown = [HsWin]::IsWindowVisible($hw)
                cloaked = [HsWin]::Cloaked($hw)
                behind = [HsWin]::Front() -ne $hw -and [HsWin]::FrontPid() -ne $PID
                styles = [bool]($x -band 0x40000) -and -not ($x -band (0x8 -bor 0x20 -bor 0x80 -bor 0x8000000))
            }
            $bad = @($ok.Keys | Where-Object { -not $ok[$_] })
            if ($bad.Count) { $global:HsSay.Add("${Name}: not $($bad -join ', '), ex-style 0x$('{0:x}' -f $x), in front $([HsWin]::Front()) of $([HsWin]::FrontPid()), the console $hw of $PID") }
            $bad.Count -eq 0
        }
        $global:HsGone = {
            param($W, [string]$Name)
            $ok = $W.Mode -eq 'panel' -and -not [HsWin]::IsWindowVisible($W.Hwnd)
            if (-not $ok) { $global:HsSay.Add("${Name}: mode $($W.Mode), visible $([HsWin]::IsWindowVisible($W.Hwnd))") }
            $ok
        }
        $global:HsUi = { $s = Read-ChatqJson $global:ChatOverlayPath; "$($s.ui.console)/$($s.ui.closing)" }
        $global:HsPlan = @{
            1 = {
                $H.CompactAt = $null
                $W = $H.Console
                $global:HsHwnd = if ($W) { $W.Hwnd } else { $null }
                $global:HsOk.loaded = $global:HsImports -eq 1 -and [bool]${function:New-ChatConsole} -and [bool]${function:New-ChatOverlayWindow} -and
                    $null -ne $global:ChatOverlayNativeCode -and $null -ne $W -and [object]::ReferenceEquals($W, $global:ChatOverlayHost)
                & $global:HsNote 'loaded' "imports $($global:HsImports), console $($null -ne $W)"
                if ($W) {
                    $r = [ChatOverlayNative]::GetRect($W.Hwnd)
                    $global:HsOk.open = (& $global:HsShown $W 'open') -and $global:HsFront -eq 1 -and $null -ne $r -and
                        [Math]::Abs($r[0] + $r[2] + 2214) -le 2 -and [Math]::Abs($r[1] - 197) -le 2
                    & $global:HsNote 'open' "front $($global:HsFront), at $($r -join ','), the panel's $($W.PanelWas.Rect -join ',')"
                }
                $global:HsOk.hidden1 = (& $global:HsUi) -eq 'True/False'
                & $global:HsNote 'hidden1' (& $global:HsUi)
            }
            # a loop of the console's own holds the passes off: its timer keeps the snapshot new
            2 = @({
                    $global:HsOk.hidden = (& $global:HsUi) -eq 'True/False'
                    & $global:HsNote 'hidden' (& $global:HsUi)
                    $a0 = [int64](Read-ChatqJson $global:ChatOverlayPath).at
                    $H.Ctx.SavedAt = (Get-Date).AddSeconds(-30)
                    $t0 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                    $f = [System.Windows.Threading.DispatcherFrame]::new()
                    $s = [System.Windows.Threading.DispatcherTimer]::new()
                    $s.Interval = [TimeSpan]::FromMilliseconds(3500)
                    $s.Tag = $f
                    $s.add_Tick({ param($x, $e) $x.Stop(); $x.Tag.Continue = $false })
                    $s.Start()
                    [System.Windows.Threading.Dispatcher]::PushFrame($f)
                    $a1 = [int64](Read-ChatqJson $global:ChatOverlayPath).at
                    $global:HsOk.keep = $a1 -gt $a0 -and $a1 -ge $t0 -and ((Get-Date) - $H.Ctx.SavedAt).TotalSeconds -lt 4
                    & $global:HsNote 'keep' "at $a0 then $a1, from $t0"
                }, 'console-back')
            3 = { $global:HsOk.back = & $global:HsGone $H.Console 'back' }
            4 = @({ $global:HsOk.back2 = (& $global:HsUi) -eq 'False/False'; & $global:HsNote 'back2' (& $global:HsUi) }, 'console')
            5 = { $global:HsOk.again = (& $global:HsShown $H.Console 'again') -and $global:HsFront -eq 2 -and $global:HsImports -eq 2; & $global:HsNote 'again' "front $($global:HsFront), imports $($global:HsImports)" }
            # the pass after an open comes at once, not an interval on
            6 = @({
                    $ms = [int]($global:HsT[6] - $global:HsT[5]).TotalMilliseconds
                    $global:HsOk.fast = (& $global:HsUi) -eq 'True/False' -and $ms -lt 7500
                    & $global:HsNote 'fast' "$(& $global:HsUi), $ms ms"
                    $global:ChatConsoleActiveSeam = { $true }
                }, 'console-key')
            7 = @({ $global:HsOk.key = (& $global:HsGone $H.Console 'key') -and $global:HsFront -eq 2; & $global:HsNote 'key' "front $($global:HsFront)"; $global:ChatConsoleActiveSeam = $null }, 'console-key')
            8 = @({ $global:HsOk.key2 = (& $global:HsShown $H.Console 'key2') -and $global:HsFront -eq 3; & $global:HsNote 'key2' "front $($global:HsFront)" }, 'hotkey')
            9 = @({ $global:HsOk.hotkey = (& $global:HsGone $H.Console 'hotkey') -and (& $global:HsCmds 'hotkey') -eq 0; & $global:HsNote 'hotkey' "commands $(& $global:HsCmds 'hotkey')" }, 'hotkey')
            10 = @({ $global:HsOk.hotkey2 = (& $global:HsCmds 'hotkey') -eq 1 -and $H.Console.Mode -eq 'panel'; & $global:HsNote 'hotkey2' "commands $(& $global:HsCmds 'hotkey'), mode $($H.Console.Mode)" }, 'console')
            11 = @({ $global:HsOk.close = (& $global:HsShown $H.Console 'close') -and $global:HsFront -eq 4; & $global:HsNote 'close' "front $($global:HsFront)" }, 'close')
            12 = { $global:HsOk.close2 = (& $global:HsGone $H.Console 'close2') -and $H.Closing; & $global:HsNote 'close2' "closing $($H.Closing)" }
            13 = { $global:HsOk.close3 = (& $global:HsUi) -eq 'False/True'; & $global:HsNote 'close3' (& $global:HsUi) }
        }
        # the code on disk changed once the host has started, as its panel
        # starts: the console still loads the parts the host read then
        # (Import-ChatOverlayConsoleParts), not the new console.ps1 - the
        # code's restart held off for the run
        $global:HsConPath = [System.IO.Path]::Combine([string]$global:ChatRoot, 'src', 'console.ps1')
        $global:HsConWas = [System.IO.File]::ReadAllBytes($global:HsConPath)
        $global:HsDisk = $false
        $global:HsChanged = $false
        $global:ChatOverlayUiSpawnSeam = {
            param($Exe, $Data)
            [System.IO.File]::AppendAllText($global:HsConPath, "`n`$global:HsDisk = `$true`n")
            $global:HsChanged = $true
            $H.Ctx.CodeLookAt = (Get-Date).AddHours(1)
            $global:HsPanel
        }
        try { $global:HsWhy = Start-ChatOverlayHeadlessHost -UiExe 'C:\ui\chatq-overlay.exe' -IntervalMs 15000 -MaxCycles 16 -Open console }
        finally { [System.IO.File]::WriteAllBytes($global:HsConPath, $global:HsConWas) }
        $global:HsOk.cached = $global:HsChanged -and -not $global:HsDisk -and [bool]${function:New-ChatConsole}
        & $global:HsNote 'cached' "changed $($global:HsChanged), the new console.ps1 run $($global:HsDisk)"
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action] {}, [System.Windows.Threading.DispatcherPriority]::Background)
        $hw = $global:HsHwnd
        $st = Read-ChatOverlayState
        $global:HsOk.end = [string]$global:HsWhy -eq 'close' -and $null -ne $hw -and -not [HsWin]::IsWindow($hw) -and
            [int64]$st.closedSignIn -eq 1700000000000 -and $global:HsImports -eq 4 -and [bool]${function:New-ChatConsole}
        & $global:HsNote 'end' "ended $($global:HsWhy), window $(if ($null -ne $hw) { [HsWin]::IsWindow($hw) } else { 'none' }), closedSignIn $($st.closedSignIn), imports $($global:HsImports)"
    }
    catch { $global:HsSay.Add("threw: $($_.Exception.Message) @ $($_.ScriptStackTrace)") }
} 2>$null | Out-Null
'@
    # Every branch of the panel's verbs (Invoke-ChatOverlayPanelVerb) and the
    # host's own (Start-ChatOverlayHeadlessHost) on what the launch loads,
    # with nothing past the sandbox's seams stood in: a function they reach
    # that the launch leaves out fails here. Then the unread dot (B10): the
    # window in front read for real, by a type of the headless parts' own
    # (Get-ChatForegroundPid), the chat under it spared.
    $hsPartsBody = @'
& {
    try {
        $global:ChatProcessTableSeam = { @() }
        $global:HsOk.parts = -not ${function:New-ChatOverlayWindow} -and -not ${function:New-ChatConsole} -and -not ${function:Show-ChatOverlayMacNotice} -and
            -not ('ChatOverlayNative' -as [type]) -and $null -eq $global:ChatOverlayNativeCode -and [bool]${function:Start-ChatOverlayHeadlessHost} -and [bool]${function:Invoke-ChatOverlayPanelVerb}
        New-ChatqDir $global:ChatqData
        $v = New-ChatOverlayHeadlessState
        $v.Ctx = New-ChatOverlayContext
        $v.Ctx.Unread = @{ 'hs-a' = $true }
        $v.Ctx.Reloads = @([pscustomobject]@{ pid = 999999; id = 'r1'; window = 'proj - VS Code' })
        $row = { param($Sid, $St, $Where) [pscustomobject]@{ key = "s:$Sid"; kind = 'session'; status = $St; where = $Where; sessionId = $Sid; title = "chat $Sid"; cwd = 'C:\w\hs-proj' } }
        $snap = [pscustomobject]@{ rows = @((& $row 'hs-a' 'idle' 'vscode'), (& $row 'hs-busy' 'busy' 'vscode')); recent = @((& $row 'hs-rec' 'recent' '')); recentMore = @() }
        $v.Snap = $snap
        # one verb: what it returns, the said marker and the balloon it makes
        $verb = {
            param([string]$Line, [bool]$Want, [string]$Said, [string]$Balloon, [string]$Text)
            $n0 = $v.Events.Count
            $r = Invoke-ChatOverlayPanelVerb $v $Line $snap
            $new = @($v.Events | Select-Object -Skip $n0)
            $s = @($new | Where-Object { $_.kind -eq 'said' })
            $b = @($new | Where-Object { $_.kind -eq 'balloon' })
            $ok = $r -is [bool] -and $r -eq $Want
            if ($Said) { $ok = $ok -and $s.Count -eq 1 -and "$($s[0].said)/$($s[0].tone)" -eq $Said -and $s[0].text -like $Text } else { $ok = $ok -and $s.Count -eq 0 }
            if ($Balloon) { $ok = $ok -and $b.Count -eq 1 -and $b[0].text -like $Balloon } else { $ok = $ok -and $b.Count -eq 0 }
            if (-not $ok) { $global:HsSay.Add("${Line}: gave $r; said $(@($s | ForEach-Object { "$($_.said)/$($_.tone) $($_.text)" }) -join ' | '); balloon $(@($b | ForEach-Object { $_.text }) -join ' | ')") }
            $ok
        }
        $global:HsOk.opened = @(
            (& $verb 'opened s:hs-a 0' $true 'done/dim' '' "opened 'chat hs-a'"),
            (& $verb 'opened s:hs-a 25 front' $true 'done/dim' '' "opened 'chat hs-a'"),
            (& $verb 'opened s:hs-a 0 behind' $true 'done/warn' '' '*could not be brought to the front*'),
            (& $verb 'opened s:hs-a 15' $true 'done/warn' 'A queued prompt is running*' "'chat hs-a' - A queued prompt*"),
            (& $verb 'opened s:hs-a late' $true 'late/warn' 'The open got no answer in 60 s*' '*no answer in 60 s*'),
            (& $verb 'opened s:hs-a nostart' $true 'nostart/warn' '' '*its helper did not start*'),
            (& $verb 'opened s:hs-a behind' $true 'done/warn' '' '*could not be brought to the front*')) -notcontains $false -and -not $v.Ctx.Unread.ContainsKey('hs-a')
        $cf = @(
            (& $verb 'config opacity 0.5' $true '' '' ''),
            (& $verb 'config maxRows 12' $true '' '' ''),
            (& $verb 'config theme light' $true '' '' ''),
            (& $verb 'config recent 3' $true '' '' '')) -notcontains $false
        $c = $v.Ctx.Config
        $global:HsOk.config = $cf -and $c.opacity -eq 0.5 -and $c.maxRows -eq 12 -and $c.theme -eq 'light' -and $c.recent -eq 3
        & $global:HsNote 'config' "opacity $($c.opacity), maxRows $($c.maxRows), theme $($c.theme), recent $($c.recent)"
        $global:HsOk.chip = (& $verb 'auto-chip s:hs-a dont' $true '' 'That continue is gone already.' '') -and (& $verb 'auto-chip s:gone continue' $false '' '' '')
        $global:HsOk.delete = @(
            (& $verb 'delete s:hs-rec' $true 'delete/warn' '*is not on disk any more.' '*is not on disk any more.'),
            (& $verb 'delete s:hs-busy' $true 'delete/warn' '' 'Nothing deleted - not while*'),
            (& $verb 'delete s:gone' $true 'delete/warn' '' '*not on the panel any more.')) -notcontains $false
        $ra = (& $verb 'reload-answer 999999:r1 later' $true 'reload/dim' '' 'left for later - the notice is still in proj - VS Code') -and (& $verb 'reload-answer 1:x later' $false '' '' '')
        $rf = Read-ChatqJson (Join-Path $global:ChatReloadAnswerDir '999999.json')
        $global:HsOk.reload = $ra -and $rf.answer -eq 'later' -and $rf.id -eq 'r1' -and $v.Ctx.ReloadAnswered -is [hashtable] -and $v.Ctx.ReloadAnswered.ContainsKey('999999:r1')
        & $global:HsNote 'reload' "the file's $($rf.id) $($rf.answer)"
        $k1 = & $verb 'card s:hs-a' $false '' '' ''
        $c1 = Read-ChatqJson $global:ChatOverlayCardPath
        $k2 = & $verb 'card s:gone' $false '' '' ''
        $c2 = Read-ChatqJson $global:ChatOverlayCardPath
        $global:HsOk.card = $k1 -and $k2 -and $c1.key -eq 's:hs-a' -and $c1.model -and [string](Get-ChatField $c1.model 'Title') -eq 'chat hs-a' -and $c2.key -eq 's:gone' -and $null -eq $c2.model
        & $global:HsNote 'card' "$($c1.key) $([string](Get-ChatField $c1.model 'Title')), then $($c2.key) $($null -eq $c2.model)"
        # B10: the window in front now, asked again should it change meanwhile
        $entry = { param($Sid, $St, $P) [pscustomobject]@{ SessionId = $Sid; Status = $St; Pid = $P; ProcStart = 1; StartedAt = 1 } }
        $done = $false
        for ($i = 0; $i -lt 3 -and -not $done; $i++) {
            $fp = [HsWin]::FrontPid()
            $me = if ($fp -gt 0) { $fp } else { 4 }
            $u = New-ChatOverlayContext
            Update-ChatOverlayUnread $u @((& $entry 'hs-front' 'busy' $me), (& $entry 'hs-away' 'busy' 999999))
            Update-ChatOverlayUnread $u @((& $entry 'hs-front' 'idle' $me), (& $entry 'hs-away' 'idle' 999999))
            if ([HsWin]::FrontPid() -ne $fp) { continue }
            $done = $true
            $want = if ($fp -gt 0) { 'hs-away' } else { 'hs-away,hs-front' }
            $got = @($u.Unread.Keys | Sort-Object) -join ','
            $global:HsOk.b10 = $got -eq $want -and [bool]('ChatForeground' -as [type]) -and -not ('ChatOverlayNative' -as [type])
            & $global:HsNote 'b10' "front $fp, unread $got, want $want"
        }
        if (-not $done) { $global:HsOk.b10 = $false; $global:HsSay.Add('b10: the window in front kept changing') }
        $global:ChatForegroundSeam = { 0 }
        # the host whole, its own verbs a pass at a time
        $null = Set-ChatqAutoContinue -Value off
        $null = Set-ChatqAutoContinueCrash -Value $false
        foreach ($p in $global:ChatqAutoPath, $global:ChatOverlayEventsPath, $global:ChatOverlayUiPath, $global:ChatOverlayCmdPath) { Remove-Item -LiteralPath $p -Force -EA SilentlyContinue }
        $global:HsOk.phoneFn = [bool]${function:Start-ChatqPhoneSetup}
        $global:HsPhone = 0
        function global:Start-ChatqPhoneSetup { param([switch]$NoWait) $global:HsPhone++ }
        $global:HsNotes = { @($H.Events | Where-Object { $_.kind -eq 'balloon' -and $_.text -like 'chatq now continues*' }).Count }
        $global:HsPlan = @{
            1 = @({ $H.CompactAt = $null }, 'auto-on')
            2 = @({ $global:HsOk.autoOn = (Get-ChatqAutoContinue) -eq 'on' -and (& $global:HsNotes) -eq 1; & $global:HsNote 'autoOn' "$(Get-ChatqAutoContinue), notices $(& $global:HsNotes)" }, 'auto-ask')
            3 = @({ $global:HsOk.autoAsk = (Get-ChatqAutoContinue) -eq 'ask' -and (& $global:HsNotes) -eq 1; & $global:HsNote 'autoAsk' "$(Get-ChatqAutoContinue), notices $(& $global:HsNotes)" }, 'auto-on')
            4 = @({ $global:HsOk.autoOnce = (Get-ChatqAutoContinue) -eq 'on' -and (& $global:HsNotes) -eq 1; & $global:HsNote 'autoOnce' "$(Get-ChatqAutoContinue), notices $(& $global:HsNotes)" }, 'auto-ask')
            5 = @({ $global:HsOk.autoAsk2 = (Get-ChatqAutoContinue) -eq 'ask' -and $H.Ctx.Config.autoContinue -eq 'ask'; & $global:HsNote 'autoAsk2' "$(Get-ChatqAutoContinue), the config's $($H.Ctx.Config.autoContinue)" }, 'ask-leave k9')
            6 = @({ $global:HsOk.stale = (& $global:HsCmds 'show') -eq 1 -and (& $global:HsCmds 'expand') -eq 1; & $global:HsNote 'stale' "show $(& $global:HsCmds 'show'), expand $(& $global:HsCmds 'expand')" }, 'ask-go k9')
            7 = @({ $global:HsOk.stale2 = (& $global:HsCmds 'show') -eq 2 -and (& $global:HsCmds 'expand') -eq 2; & $global:HsNote 'stale2' "show $(& $global:HsCmds 'show'), expand $(& $global:HsCmds 'expand')" }, 'refresh', 'auto-off')
            8 = @({ $global:HsOk.refresh = $null -ne $H.Ctx.Refresh -and ((Get-Date) - $H.Ctx.Refresh.At).TotalSeconds -lt 60 -and (Get-ChatqAutoContinue) -eq 'off'; & $global:HsNote 'refresh' "$($H.Ctx.Refresh.Kind), $(Get-ChatqAutoContinue)" }, 'phone')
            9 = @({ $global:HsOk.phone = $global:HsPhone -eq 1; & $global:HsNote 'phone' "$($global:HsPhone) setups" }, 'crash-on')
            10 = @({ $global:HsOk.crashOn = $H.Ctx.Config.autoContinueCrash -eq $true; & $global:HsNote 'crashOn' "$($H.Ctx.Config.autoContinueCrash)" }, 'crash-off')
            11 = @({ $global:HsOk.crashOff = $H.Ctx.Config.autoContinueCrash -eq $false; & $global:HsNote 'crashOff' "$($H.Ctx.Config.autoContinueCrash)" }, 'hotkey')
            12 = @({ $global:HsOk.hotkey = (& $global:HsCmds 'hotkey') -eq 1; & $global:HsNote 'hotkey' "commands $(& $global:HsCmds 'hotkey')" }, 'console-back', 'hide')
            13 = @({ $global:HsOk.hide = (& $global:HsCmds 'hide') -eq 1 -and -not $H.Console -and -not ${function:New-ChatConsole}; & $global:HsNote 'hide' "commands $(& $global:HsCmds 'hide'), console $([bool]$H.Console)" },
                'config theme dark', 'delete s:nope', 'opened s:nope 0', 'card s:nope', 'auto-chip s:nope dont', 'reload-answer 1:x later')
            14 = {
                $s = @($H.Events | Where-Object { $_.kind -eq 'said' -and $_.about -eq 's:nope' } | ForEach-Object { "$($_.said)/$($_.tone)" }) -join ','
                $c = Read-ChatqJson $global:ChatOverlayCardPath
                $global:HsOk.panel = $s -eq 'delete/warn,done/dim' -and $c.key -eq 's:nope' -and $H.Ctx.Config.theme -eq 'dark'
                & $global:HsNote 'panel' "said $s, card $($c.key), theme $($H.Ctx.Config.theme)"
            }
        }
        $global:HsWhy = Start-ChatOverlayHeadlessHost -UiExe 'C:\ui\chatq-overlay.exe' -IntervalMs 3000 -MaxCycles 15
        $global:HsOk.end = [string]$global:HsWhy -eq 'max' -and -not ${function:New-ChatConsole} -and -not ${function:New-ChatOverlayWindow} -and -not ('ChatOverlayNative' -as [type])
        & $global:HsNote 'end' "ended $($global:HsWhy)"
    }
    catch { $global:HsSay.Add("threw: $($_.Exception.Message) @ $($_.ScriptStackTrace)") }
} 2>$null | Out-Null
'@
    $hsStaRun = {
        param([string]$Name, [string]$Body)
        Remove-Item -LiteralPath (Join-Path $hsToolDir 'data') -Recurse -Force -EA SilentlyContinue
        $text = $hsHead.Replace('@TOOL@', $hsTool) + "`r`n" + $Body + "`r`n" + $hsTail
        $raw = try { Invoke-Sta $Name $text -Global } catch { "threw: $($_.Exception.Message)" }
        [pscustomobject]@{ Raw = "$raw"; O = $(try { "$raw" | ConvertFrom-Json } catch { $null }) }
    }
    $hsStaCheck = {
        param($R, [string]$Name, [string[]]$Keys)
        $bad = if ($R.O) { @($Keys | Where-Object { $R.O.ok.$_ -ne $true }) } else { @($Keys) }
        Check $Name ($bad.Count -eq 0) "not $($bad -join ', ') // $(if ($R.O) { @($R.O.say) -join ' / ' } else { $R.Raw })"
    }
    $hsStaA = & $hsStaRun 'hs-console' $hsConsoleBody
    & $hsStaCheck $hsStaA 'the headless host''s console: its parts loaded the first time it is asked for, into the global scope, not before' 'before', 'loaded'
    & $hsStaCheck $hsStaA 'and loaded from the parts read as the host started, the code on disk changed since' 'cached'
    & $hsStaCheck $hsStaA 'it opens cloaked, interactive and on the taskbar, grown from the native panel''s top-right corner, never in front' 'open'
    & $hsStaCheck $hsStaA 'the panel hidden from the first snapshot on; a loop of the console''s own still keeps the snapshot new' 'hidden1', 'hidden', 'keep'
    & $hsStaCheck $hsStaA 'console-back: the console''s window hidden, the panel shown again' 'back', 'back2'
    & $hsStaCheck $hsStaA 'the console asked for again: shown at once, the panel hidden by the very next pass' 'again', 'fast'
    & $hsStaCheck $hsStaA 'the console hotkey: back to the panel while the console has the keyboard, else the console brought forward' 'key', 'key2'
    & $hsStaCheck $hsStaA 'the shell''s hotkey: from the console back to the panel, from the panel the panel''s own' 'hotkey', 'hotkey2'
    & $hsStaCheck $hsStaA 'a close in the console: the panel first, then the close by hand, the window gone with the host' 'close', 'close2', 'close3', 'end'
    & $hsStaCheck $hsStaA 'the console''s run calls no function its launch leaves out' 'missing', 'log'
    $hsStaB = & $hsStaRun 'hs-parts' $hsPartsBody
    & $hsStaCheck $hsStaB 'the headless launch''s parts: none of the WPF panel''s, the console''s or the macOS host''s, no WPF type; the host''s own there' 'parts'
    & $hsStaCheck $hsStaB 'the panel''s opened on the headless launch: every outcome said, the unread dot gone' 'opened'
    & $hsStaCheck $hsStaB 'the panel''s config, auto-chip, delete, reload-answer and card on the headless launch: each done and said' 'config', 'chip', 'delete', 'reload', 'card'
    & $hsStaCheck $hsStaB 'the host''s own verbs on the headless launch: the switch said once, a changed ask shown, refresh, phone, crash, hotkey, hide' 'autoOn', 'autoAsk', 'autoOnce', 'autoAsk2', 'stale', 'stale2', 'refresh', 'phoneFn', 'phone', 'crashOn', 'crashOff', 'hotkey', 'hide'
    & $hsStaCheck $hsStaB 'the panel''s verbs through the whole headless host, and none of the WPF parts loaded by them' 'panel', 'end'
    & $hsStaCheck $hsStaB 'the unread dot on the headless launch: the chat in front spared, the window in front read by a type of its own' 'b10'
    & $hsStaCheck $hsStaB 'the headless launch''s run calls no function it leaves out' 'missing', 'log'
}
finally {
    $script:ChatOverlayUsageSeam = $hsWas.Usage
    $script:ChatqSpawn = $hsWas.Spawn
    $script:ChatOverlayUiSpawnSeam = $hsWas.Ui
    $script:ChatqSignInSeam = $hsWas.SignIn
    $script:ChatOverlaySpawn = $hsWas.OvSpawn
    ${function:Get-ChatqLiveSessions} = $hsWas.LiveFn
    ${function:Remove-ChatSessionById} = $hsWas.RmFn
    ${function:Write-ChatReloadAnswer} = $hsWas.AnsFn
    Remove-Item -LiteralPath (Join-Path $script:ChatqData 'hs-bin') -Recurse -Force -EA SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $sb 'hs-tool') -Recurse -Force -EA SilentlyContinue
    Remove-Item -LiteralPath $script:ChatOverlayCmdPath -Force -EA SilentlyContinue
    foreach ($p in @($hsFiles.Keys)) { Restore-TestFile $p $hsFiles[$p] }
}
