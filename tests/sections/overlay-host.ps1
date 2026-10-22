Section 'overlay host: the headless host and its panel''s news'
# src/overlay-host.ps1: what an overlay host does whatever draws its panel,
# and the headless host, whose panel is a process of its own. The panel's
# process stands in (ChatOverlayUiSpawnSeam), as do the usage endpoint, the
# watcher's start and the sign-in; every file it writes is put back.
$hsWas = @{ Usage = $script:ChatOverlayUsageSeam; Spawn = $script:ChatqSpawn; Ui = $script:ChatOverlayUiSpawnSeam; SignIn = $script:ChatqSignInSeam; OvSpawn = $script:ChatOverlaySpawn
    LiveFn = ${function:Get-ChatqLiveSessions}; RmFn = ${function:Remove-ChatSessionById}; AnsFn = ${function:Write-ChatReloadAnswer}
    Copilot = $script:ChatOverlayCopilotSeam; Codex = $script:ChatOverlayCodexUsageSeam; ConSpawn = $script:ChatConsoleSpawnSeam; ConGrant = $script:ChatConsoleGrantSeam }
$hsFiles = @{}
$hsFuseFile = Get-ChatqNativeFile 'panel-fuse.json'
foreach ($p in $script:ChatOverlayStatePath, $script:ChatOverlayEventsPath, $script:ChatOverlayUiPath, $script:ChatOverlayPath, $script:ChatOverlayCardPath, $hsFuseFile, $script:ChatConsoleUiPath) { $hsFiles[$p] = Read-TestFile $p }
Clear-ChatOverlayPanelFuse
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

    # a panel that keeps exiting is started again twice, then the host gives
    # up: the panel's fuse blown for this version, said, and the WPF panel
    # started in its place, no exe looked for; a restart its panel sends
    # starts the same headless launch
    $script:HsStarts = 0
    $script:HsSinces = [System.Collections.Generic.List[int64]]::new()
    $script:HsSpawnArgs = [System.Collections.Generic.List[string]]::new()
    $script:ChatOverlaySpawn = { param($Open, $UiExe) $script:HsRestarts++; $script:HsSpawnArgs.Add("$Open|$UiExe"); $true }
    $hsFuseLog = { param($Why) @([System.IO.File]::ReadAllLines((Join-Path $script:ChatqLogDir 'overlay.log'), $utf8) | Where-Object { $_.EndsWith("the native panel's fuse is blown ($Why) - the WPF panel until the next version or charlie -Panel native") }).Count }
    $hsFuseLog0 = & $hsFuseLog 'it exited 3 times in 10 minutes'
    $script:ChatOverlayUiSpawnSeam = { param($Exe, $Data, $Since) $script:HsStarts++; $script:HsSinces.Add($Since); & $hsChild $true }
    $hsWhy2 = Start-ChatOverlayHeadlessHost -UiExe 'C:\ui\chatq-overlay.exe' -IntervalMs 10 -MaxCycles 10
    $hsFuse2 = Get-ChatOverlayPanelFuse
    $hsWpf2 = $script:HsSpawnArgs -join ';'
    $hsFuseLog2 = (& $hsFuseLog 'it exited 3 times in 10 minutes') - $hsFuseLog0
    Clear-ChatOverlayPanelFuse
    $script:ChatOverlayUiSpawnSeam = { param($Exe, $Data) Send-ChatOverlayCommand 'restart'; & $hsChild $false }
    $hsWhy3 = Start-ChatOverlayHeadlessHost -UiExe 'C:\ui\chatq-overlay.exe' -IntervalMs 10 -MaxCycles 3
    $hsLaunch = Get-ChatOverlayLaunch -UiExe 'C:\ui\chatq-overlay.exe'
    Check 'a panel that keeps exiting: started 3 times in all, then the host stops and starts the WPF panel; a restart from the panel relaunches headless' (
        $hsWhy2 -eq 'panel' -and $script:HsStarts -eq 3 -and $hsWpf2 -eq '|' -and $hsWhy3 -eq 'restart' -and $script:HsRestarts -eq 2 -and
        $hsLaunch.Command -like "*Start-ChatOverlayHeadlessHost -UiExe 'C:\ui\chatq-overlay.exe'*") "$hsWhy2 $($script:HsStarts) '$hsWpf2' / $hsWhy3 $($script:HsRestarts)"
    Check 'and the panel''s fuse is blown for this version, why kept, not yet told, said in overlay.log' (
        $hsFuse2 -and [string]$hsFuse2.version -ceq (Get-ChatOverlayPanelVersion) -and $hsFuse2.why -eq 'it exited 3 times in 10 minutes' -and
        $hsFuse2.told -eq $false -and $hsFuseLog2 -eq 1) "$(ConvertTo-Json $hsFuse2 -Compress) / said $hsFuseLog2"
    Check 'and each panel started again is given the first one''s --since, so acts on the commands the last had not done' (
        $script:HsSinces.Count -eq 3 -and $script:HsSinces[0] -gt 1700000000000 -and @($script:HsSinces | Select-Object -Unique).Count -eq 1) ($script:HsSinces -join ',')

    # an exe that will not start at all - blocked by antivirus or AppLocker -
    # blows the fuse at its first start, and the WPF panel stands in
    $script:HsSpawnArgs = [System.Collections.Generic.List[string]]::new()
    $script:ChatOverlayUiSpawnSeam = { param($Exe, $Data) throw 'This program is blocked by group policy' }
    $hsFuseLogT0 = & $hsFuseLog 'it would not start: This program is blocked by group policy'
    $hsWhyT = Start-ChatOverlayHeadlessHost -UiExe 'C:\ui\chatq-overlay.exe' -IntervalMs 10 -MaxCycles 3
    $hsFuseT = Get-ChatOverlayPanelFuse
    $hsFuseLogT = (& $hsFuseLog 'it would not start: This program is blocked by group policy') - $hsFuseLogT0
    Check 'an exe that will not start: the fuse blown at once, why kept and said, the WPF panel started with no exe' (
        $hsWhyT -eq 'panel' -and $hsFuseT.why -eq 'it would not start: This program is blocked by group policy' -and $hsFuseLogT -eq 1 -and
        ($script:HsSpawnArgs -join ';') -eq '|' -and -not (Test-Path -LiteralPath $script:ChatOverlayPidPath)) "$hsWhyT / $(ConvertTo-Json $hsFuseT -Compress) / said $hsFuseLogT / $($script:HsSpawnArgs -join ';')"
    # the WPF host that stands in says so once, in its tray
    $hsFn = New-ChatOverlayHeadlessState
    $hsFn.Ctx = New-ChatOverlayContext
    Show-ChatOverlayPanelFuseNotice $hsFn
    Show-ChatOverlayPanelFuseNotice $hsFn
    $hsFnE = @($hsFn.Events | Where-Object { $_.kind -eq 'balloon' -and $_.text -like 'The native panel stopped (it would not start: *' })
    Check 'the fuse said once by the host standing in: why, and charlie -Panel native to try again; told kept' (
        $hsFnE.Count -eq 1 -and $hsFnE[0].text -like '*charlie -Panel native tries it again.' -and (Get-ChatOverlayPanelFuse).told -eq $true) "$(ConvertTo-Json $hsFnE -Compress)"
    # another version's fuse counts for nothing: a new version tries native
    Check 'a fuse kept for another version counts for nothing - an update tries the native panel again' (
        (Get-ChatOverlayPanelFuse) -and -not (Get-ChatOverlayPanelFuse -Version '0.0.1')) ''
    Clear-ChatOverlayPanelFuse
    $script:ChatOverlaySpawn = { $script:HsRestarts++; $true }

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
    $hsNat = [pscustomobject]@{ panel = 'native'; panelChosen = $true }
    $hsDef = [pscustomobject]@{ panel = 'native'; panelChosen = $false }
    $script:HsSpawnArgs = [System.Collections.Generic.List[string]]::new()
    try {
        $script:ChatRoot = $hsPx
        $hsPxDef = Get-ChatOverlayPanelExe -Config $hsDef
        $hsPxNone = Get-ChatOverlayPanelExe -Config $hsNat
        $hsPxQuiet = Get-ChatOverlayPanelExe -Config $hsNat -Quiet
        New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($hsPxExe)) | Out-Null
        [System.IO.File]::WriteAllBytes($hsPxExe, [byte[]]@())
        $hsPxGot = Get-ChatOverlayPanelExe -Config $hsNat
        $hsPxDefGot = Get-ChatOverlayPanelExe -Config $hsDef
        $hsPxPs = Get-ChatOverlayPanelExe -Config ([pscustomobject]@{ panel = 'ps' })
        # the fuse blown for this version: the WPF one, the exe there or not;
        # for another version, the exe
        Set-ChatOverlayPanelFuse 'test' $hsVer
        $hsPxFused = Get-ChatOverlayPanelExe -Config $hsNat
        Set-ChatOverlayPanelFuse 'test' '0.0.1'
        $hsPxOther = Get-ChatOverlayPanelExe -Config $hsNat
        Clear-ChatOverlayPanelFuse
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
    Check 'the native panel''s exe: bin/<version>/x86_64-pc-windows-msvc beside the script; none staged, the WPF one, said once where native was asked for; ps, the WPF one; a launch given it' (
        $hsPxNone -eq '' -and $hsPxQuiet -eq '' -and $hsPxGot -eq $hsPxExe -and $hsPxPs -eq '' -and $hsPxLog -eq 1 -and
        ($script:HsSpawnArgs -join ';') -eq "console|$hsPxExe") "'$hsPxNone' '$hsPxGot' '$hsPxPs' / said $hsPxLog / $($script:HsSpawnArgs -join ';')"
    Check 'native by default, never chosen: the exe when staged; none staged, the WPF one, quietly - every zip and git install''s start' (
        $hsPxDef -eq '' -and $hsPxDefGot -eq $hsPxExe -and $hsPxLog -eq 1) "'$hsPxDef' '$hsPxDefGot' / said $hsPxLog"
    Check 'the panel''s fuse blown for this version: the WPF one, though the exe is there; blown for another, the exe' (
        $hsPxFused -eq '' -and $hsPxOther -eq $hsPxExe) "'$hsPxFused' '$hsPxOther'"

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
    $hsLk = Get-ChatOverlayLaunch -Console -HostPid 42 -ConsoleOpen key
    $hsLs = Get-ChatOverlayLaunch -Console
    Check 'the native panel''s console''s launch: CHATQ_OVERLAY and CHATQ_ALLPARTS, its host and how it was asked for, a failure logged as the console''s' (
        $hsLk.Command -like "*`$env:CHATQ_OVERLAY='1'; `$env:CHATQ_ALLPARTS='1'*" -and $hsLk.Command -like "*Start-ChatConsoleHost -HostPid 42 -Open 'key')*" -and
        $hsLk.Command -like '*console failed to start*' -and $hsLk.Command -notlike '*Start-ChatOverlay*' -and
        $hsLs.Command -like "*Start-ChatConsoleHost -HostPid 0 -Open 'show')*") "$($hsLk.Command) / $($hsLs.Command)"

    # The native panel's console, a process of its own (Start-ChatConsoleHost),
    # as its host sees it: the process stood in (ChatConsoleSpawnSeam) - its
    # stdin's lines written down, its close ending it - as is the grant to
    # come forward (ChatConsoleGrantSeam); its word back, console-ui.json,
    # written here as it writes it (Save-ChatConsoleUi).
    $script:HsConLines = [System.Collections.Generic.List[string]]::new()
    $script:HsConSpawns = [System.Collections.Generic.List[string]]::new()
    $script:HsGrants = [System.Collections.Generic.List[int]]::new()
    $script:HsConFake = {
        param([int]$Id)
        $c = [pscustomobject]@{ Id = $Id; HasExited = $false; ExitCode = 0 }
        $in = [pscustomobject]@{ Owner = $c }
        $in | Add-Member -MemberType ScriptMethod -Name WriteLine -Value { param($l) $script:HsConLines.Add("$($this.Owner.Id) $l") }
        $in | Add-Member -MemberType ScriptMethod -Name Flush -Value { }
        $in | Add-Member -MemberType ScriptMethod -Name Close -Value { $script:HsConLines.Add("$($this.Owner.Id) closed"); $this.Owner.HasExited = $true }
        $c | Add-Member -NotePropertyName StandardInput -NotePropertyValue $in
        $c | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) $this.HasExited }
        $c | Add-Member -MemberType ScriptMethod -Name Kill -Value { $script:HsConLines.Add("$($this.Id) killed") }
        $c | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
        $c
    }
    $script:ChatConsoleSpawnSeam = { param($Open) $script:HsConSpawns.Add($Open); & $script:HsConFake (4100 + $script:HsConSpawns.Count) }
    $script:ChatConsoleGrantSeam = { param($p) $script:HsGrants.Add($p); $true }
    $hsConUi = {
        param([int]$ProcId, [bool]$Shown, [bool]$Busy, [object[]]$Events = @(), $Request = $null, [int]$AgoMs = 0)
        $b = [ordered]@{ pid = $ProcId; at = (ConvertTo-ChatOverlayMs (Get-Date)) - $AgoMs; shown = $Shown; underWay = $Busy; events = @($Events); request = $Request }
        Save-ChatqText $script:ChatConsoleUiPath (ConvertTo-Json -InputObject $b -Depth 5 -Compress)
    }
    Remove-Item -LiteralPath $script:ChatConsoleUiPath -Force -EA SilentlyContinue
    $hcH = New-ChatOverlayHeadlessState
    $hcH.Ctx = New-ChatOverlayContext
    $hcR0 = Update-ChatOverlayConsoleChild $hcH
    $hcL0 = Send-ChatConsoleLine $hcH 'show'
    $hcS1 = Start-ChatConsoleProcess $hcH 'show'
    $hcR1 = Update-ChatOverlayConsoleChild $hcH
    $hcR1b = Update-ChatOverlayConsoleChild $hcH ((Get-Date).AddSeconds(25))
    Check 'the console asked for on the headless host: its process started, let come forward; starting, it holds a restart off 20 s at most, the panel left until it says it shows' (
        -not $hcR0.Shown -and -not $hcR0.UnderWay -and -not $hcL0 -and $hcS1 -and ($script:HsConSpawns -join ',') -eq 'show' -and ($script:HsGrants -join ',') -eq '4101' -and
        $hcH.ConProc.Id -eq 4101 -and -not $hcR1.Shown -and $hcR1.UnderWay -and -not $hcR1b.UnderWay -and -not $script:HsConLines.Count) (
        "$($hcR1 | ConvertTo-Json -Compress) / $($hcR1b | ConvertTo-Json -Compress) / spawns $($script:HsConSpawns -join ',') / grants $($script:HsGrants -join ',')")
    & $hsConUi 9999 $true $false
    $hcR2 = Update-ChatOverlayConsoleChild $hcH
    $hcEv = [pscustomobject]@{ id = 'c-1'; at = (ConvertTo-ChatOverlayMs (Get-Date)); kind = 'balloon'; text = 'from the console'; title = 'Charlie' }
    & $hsConUi 4101 $true $true @($hcEv) ([pscustomobject]@{ alive = $true; spawned = $false; at = (ConvertTo-ChatOverlayMs (Get-Date)) })
    $hcR3 = Update-ChatOverlayConsoleChild $hcH
    $hcRq = $hcH.AskRequest
    $hcH.AskRequest = $null
    $hcR4 = Update-ChatOverlayConsoleChild $hcH
    $hcRq4 = $hcH.AskRequest
    # 16 minutes on, the same word still there: its ids let go here, and
    # neither its news nor its request taken again, by that pass or the next
    $null = Update-ChatOverlayConsoleChild $hcH ((Get-Date).AddMinutes(16))
    $hcR4b = Update-ChatOverlayConsoleChild $hcH ((Get-Date).AddMinutes(16))
    $hcE = @($hcH.Events | Where-Object { $_.text -eq 'from the console' })
    Check 'its word: only its own process''s; its news taken once, as the host''s own, and a watcher its answer asked for once - not again once its id is let go; shown and under way as it says' (
        -not $hcR2.Shown -and $hcR2.UnderWay -and $hcR3.Shown -and $hcR3.UnderWay -and $hcR4.Shown -and $hcE.Count -eq 1 -and $hcE[0].kind -eq 'balloon' -and
        $hcE[0].title -eq 'Charlie' -and $hcE[0].id -ne 'c-1' -and $hcRq -and $hcRq.Alive -and -not $hcRq.Spawned -and $null -eq $hcRq4 -and $null -eq $hcH.AskRequest -and -not $hcR4b.Shown) (
        "$($hcR2 | ConvertTo-Json -Compress) / $($hcR3 | ConvertTo-Json -Compress) / $($hcR4 | ConvertTo-Json -Compress) / $(ConvertTo-Json @($hcH.Events) -Compress -Depth 3) / $($hcRq | ConvertTo-Json -Compress) / again $($null -ne $hcRq4) $($null -ne $hcH.AskRequest)")
    & $hsConUi 4101 $true $true -AgoMs 11000
    $hcR5 = Update-ChatOverlayConsoleChild $hcH
    $hcR5b = Update-ChatOverlayConsoleChild $hcH ((Get-Date).AddSeconds(25))
    $hcS2 = Start-ChatConsoleProcess $hcH 'key'
    $hcW2 = $hcH.ConWant
    $hcS3 = Start-ChatConsoleProcess $hcH 'show'
    $hcW3 = $hcH.ConWant
    Check 'asked for again while it runs: told on its stdin and let come forward again, no second process; a show owed until it says it shows, a key on one that shows owing none; under way only on a word under 10 s old, shown only on one under 30 s old' (
        $hcR5.Shown -and -not $hcR5.UnderWay -and -not $hcR5b.Shown -and $hcS2 -and $hcS3 -and ($script:HsConLines -join ',') -eq '4101 key,4101 show' -and ($script:HsConSpawns -join ',') -eq 'show' -and
        ($script:HsGrants -join ',') -eq '4101,4101,4101' -and $null -eq $hcW2 -and $hcW3 -and $hcW3.Open -eq 'show') "$($hcR5b | ConvertTo-Json -Compress) / $($script:HsConLines -join ',') / grants $($script:HsGrants -join ',') / want $($hcW3 | ConvertTo-Json -Compress)"
    $hcH.ConProc.HasExited = $true
    $hcR6 = Update-ChatOverlayConsoleChild $hcH
    $hcP6 = $hcH.ConProc
    if ($hcP6) { $hcP6.HasExited = $true }
    $hcR7 = Update-ChatOverlayConsoleChild $hcH
    Check 'one that has gone is let go, and started again, once, when a show sent it was never seen' (
        -not $hcR6.Shown -and $hcR6.UnderWay -and $hcP6 -and $hcP6.Id -eq 4102 -and $script:HsGrants[-1] -eq 4102 -and
        -not $hcR7.Shown -and -not $hcR7.UnderWay -and $null -eq $hcH.ConProc -and ($script:HsConSpawns -join ',') -eq 'show,show') "$($hcR6 | ConvertTo-Json -Compress) / $($hcR7 | ConvertTo-Json -Compress) / spawns $($script:HsConSpawns -join ',')"
    $null = Start-ChatConsoleProcess $hcH 'show'
    Stop-ChatConsoleProcess $hcH
    Check 'told to go: its stdin closed, and let go' ($script:HsConLines[-1] -eq '4103 closed' -and $null -eq $hcH.ConProc -and -not (Send-ChatConsoleLine $hcH 'back')) "$($script:HsConLines -join ',')"

    # NoFetch, the console's own process's context: no usage endpoint asked
    $script:HsNf = @{ Usage = 0; Codex = 0; Copilot = 0 }
    $hsUsageWas = $script:ChatOverlayUsageSeam
    $script:ChatOverlayUsageSeam = { $script:HsNf.Usage++; @{ Ok = $true; Status = 200; Windows = @() } }
    $script:ChatOverlayCodexUsageSeam = { param($h) $script:HsNf.Codex++; @{ Ok = $false; Why = 'none in the tests'; Quiet = $true } }
    $script:ChatOverlayCopilotSeam = { $script:HsNf.Copilot++; @{ Ok = $false; Why = 'none in the tests'; Quiet = $true } }
    $hcNf = New-ChatOverlayContext
    $hcNf.Config.liveUsage = $true
    $hcNf.Config.codexUsage = $true
    $hcNf.Config.copilotUsage = $true
    $hcNf.NoFetch = $true
    $null = Update-ChatOverlayUsage $hcNf
    $hcNf0 = "$($script:HsNf.Usage) $($script:HsNf.Codex) $($script:HsNf.Copilot)"
    $hcNf.NoFetch = $false
    $null = Update-ChatOverlayUsage $hcNf
    $hcNf1 = "$($script:HsNf.Usage) $($script:HsNf.Codex) $($script:HsNf.Copilot)"
    $script:ChatOverlayUsageSeam = $hsUsageWas
    $script:ChatOverlayCodexUsageSeam = $hsWas.Codex
    $script:ChatOverlayCopilotSeam = $hsWas.Copilot
    Check 'NoFetch, the console''s own process''s context: Claude, Codex and Copilot none asked live, all three asked by one without it' ($hcNf0 -eq '0 0 0' -and $hcNf1 -eq '1 1 1') "$hcNf0 / $hcNf1"

    # The whole host with it: chatconsole's start, then each verb that
    # reaches it, a pass at a time - the panel's process stood in, each look
    # at its HasExited a pass's hook (HsConPlan): a check, then the verbs for
    # the pass after
    $script:HsConLines.Clear(); $script:HsConSpawns.Clear(); $script:HsGrants.Clear()
    foreach ($p in $script:ChatConsoleUiPath, $script:ChatOverlayCmdPath, $script:ChatOverlayEventsPath) { Remove-Item -LiteralPath $p -Force -EA SilentlyContinue }
    $script:HsN = 0
    $script:HsOk = [ordered]@{}
    $script:HsSay = [System.Collections.Generic.List[string]]::new()
    $script:HsAt = { param([string]$Key, [bool]$Ok, [string]$Text) $script:HsOk[$Key] = $Ok; if (-not $Ok) { $script:HsSay.Add("${Key}: $Text") } }
    $script:HsLines = { $script:HsConLines -join ',' }
    $script:HsPanelCmds = { param([string]$Verb) @($H.Ctx.Commands | Where-Object { $_.verb -eq $Verb }).Count }
    $script:HsPanelFake = [pscustomobject]@{ Gone = $false; ExitCode = 0 }
    $script:HsPanelFake | Add-Member -MemberType ScriptProperty -Name HasExited -Value {
        if (-not $this.Gone) {
            $script:HsN++
            foreach ($s in @($script:HsConPlan[$script:HsN])) {
                if ($null -eq $s) { continue }
                try { if ($s -is [scriptblock]) { $null = & $s } else { Send-ChatOverlayCommand ([string]$s) } }
                catch { $script:HsSay.Add("pass $($script:HsN): $($_.Exception.Message)") }
            }
        }
        [bool]$this.Gone
    }
    $hsPfIn = [pscustomobject]@{ Owner = $script:HsPanelFake }
    $hsPfIn | Add-Member -MemberType ScriptMethod -Name Close -Value { $this.Owner.Gone = $true }
    $script:HsPanelFake | Add-Member -NotePropertyName StandardInput -NotePropertyValue $hsPfIn
    $script:HsPanelFake | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) $this.Gone }
    $script:HsPanelFake | Add-Member -MemberType ScriptMethod -Name Kill -Value { }
    $hsUiWas = $script:ChatOverlayUiSpawnSeam
    $script:ChatOverlayUiSpawnSeam = { param($Exe, $Data) $script:HsPanelFake }
    $script:HsConPlan = @{
        1 = @({
                & $script:HsAt 'held' ($H.Ctx.PanelConsole -and $H.ConHold -and ($script:HsConSpawns -join ',') -eq 'show' -and ($script:HsGrants -join ',') -eq '4101' -and $H.UnderWay) (
                    "console $($H.Ctx.PanelConsole), hold $($H.ConHold), spawns $($script:HsConSpawns -join ','), under way $($H.UnderWay)")
                & $hsConUi 4101 $true $false
            }, 'console-ui')
        2 = @({ & $script:HsAt 'shown' ($H.Ctx.PanelConsole -and -not $H.ConHold -and -not $script:HsConLines.Count) "console $($H.Ctx.PanelConsole), hold $($H.ConHold), lines $(& $script:HsLines)" }, 'console-key')
        3 = @({ & $script:HsAt 'key' ((& $script:HsLines) -eq '4101 key' -and $script:HsConSpawns.Count -eq 1 -and ($script:HsGrants -join ',') -eq '4101,4101') "lines $(& $script:HsLines), grants $($script:HsGrants -join ',')" }, 'hotkey')
        4 = @({
                & $script:HsAt 'hotkey' ((& $script:HsLines) -eq '4101 key,4101 back' -and (& $script:HsPanelCmds 'hotkey') -eq 0) "lines $(& $script:HsLines), the panel's $(& $script:HsPanelCmds 'hotkey')"
                & $hsConUi 4101 $false $false
            }, 'console-ui')
        5 = @({ & $script:HsAt 'back' (-not $H.Ctx.PanelConsole) "console $($H.Ctx.PanelConsole)" }, 'hotkey')
        6 = @({ & $script:HsAt 'hotkey2' ((& $script:HsPanelCmds 'hotkey') -eq 1 -and $script:HsConLines.Count -eq 2) "the panel's $(& $script:HsPanelCmds 'hotkey'), lines $(& $script:HsLines)" }, 'console-back', 'hide', 'reload')
        7 = @({
                & $script:HsAt 'verbs' ((& $script:HsLines) -eq '4101 key,4101 back,4101 back,4101 back,4101 reload') "lines $(& $script:HsLines)"
                $H.ConProc.HasExited = $true
            }, 'console-ui')
        8 = @({ & $script:HsAt 'gone' ($null -eq $H.ConProc -and $script:HsConSpawns.Count -eq 1 -and -not $H.Ctx.PanelConsole) "process $($null -ne $H.ConProc), spawns $($script:HsConSpawns -join ',')" }, 'console')
        9 = @({ & $script:HsAt 'again' (($script:HsConSpawns -join ',') -eq 'show,show' -and $H.ConProc.Id -eq 4102 -and $script:HsGrants[-1] -eq 4102) "spawns $($script:HsConSpawns -join ','), grants $($script:HsGrants -join ',')" }, 'close')
        10 = { & $script:HsAt 'close' ($script:HsConLines[-1] -eq '4102 back' -and $H.Closing) "lines $(& $script:HsLines), closing $($H.Closing)" }
    }
    $hsWhyC = Start-ChatOverlayHeadlessHost -UiExe 'C:\ui\chatq-overlay.exe' -IntervalMs 3000 -MaxCycles 10 -Open console
    & $script:HsAt 'end' ($hsWhyC -eq 'max' -and $script:HsConLines[-1] -eq '4102 closed' -and $script:HsN -ge 10) "ended $hsWhyC after $($script:HsN), lines $(& $script:HsLines)"
    $hsConCheck = {
        param([string]$Name, [string[]]$Keys)
        $bad = @($Keys | Where-Object { $script:HsOk[$_] -ne $true })
        Check $Name ($bad.Count -eq 0) "not $($bad -join ', ') // $(@($script:HsSay) -join ' / ')"
    }
    & $hsConCheck 'chatconsole''s start on the headless host: the console''s process started with the first pass, the panel hidden under it from the first snapshot on, until it says it shows' 'held', 'shown'
    & $hsConCheck 'the host''s verbs for it, told on its stdin while it shows: its hotkey, the shell''s hotkey - back to the panel - and the panel''s own; the shell''s hotkey the panel''s once it shows no more' 'key', 'hotkey', 'back', 'hotkey2', 'verbs'
    & $hsConCheck 'its process gone: let go, and the console asked for again starts another; a close tells it first, the host''s end closes it' 'gone', 'again', 'close', 'end'
    $script:ChatOverlayUiSpawnSeam = $hsUiWas

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
    # B2, the native panel's console, in its own process
    # (Start-ChatConsoleHost) as its launch runs it, every part loaded:
    # cloaked, so drawn and never seen, and brought forward only through its
    # seam, so never in front. Its host's lines come through a stand-in for
    # its stdin (ChatConsoleInSeam), each look at it past the last line a
    # pass's hook (HsCon): a check, then the lines for the pass after. It
    # opens grown from the native panel's top-right corner (overlay-ui.json's
    # rect, on a screen the work-area seam makes wide enough at any scale),
    # says so in console-ui.json, and goes as its console goes back to the
    # panel ($script:ChatConsoleKeepMinutes 0), once its stdin ends, or with
    # one already running.
    $hsConsoleBody = @'
& {
    try {
        $env:CHATQ_CLOAK = '1'
        Remove-Item -LiteralPath 'env:CHATQ_ALLPARTS' -EA SilentlyContinue
        $global:ChatForegroundSeam = { 0 }
        $global:HsOk.parts = [bool]${function:New-ChatConsole} -and [bool]${function:Start-ChatConsoleHost} -and $global:ChatConsoleKeepMinutes -eq 0
        $global:ChatOverlayWorkAreaSeam = { param($r) [pscustomobject]@{ X = -6000; Y = 0; Width = 3840; Height = 2160 } }
        Save-ChatqText $global:ChatOverlayUiPath (ConvertTo-Json @{ at = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); rect = @(-2594, 197, 380, 300) } -Compress)
        Remove-Item -LiteralPath $global:ChatOverlayEventsPath -Force -EA SilentlyContinue
        $global:HsFront = 0
        $global:ChatConsoleNoSync = $true
        $global:ChatConsoleFrontSeam = { param($w) $global:HsFront++ }
        # no usage endpoint asked: its host's (NoFetch)
        $global:HsAsked = 0
        $global:ChatOverlayUsageSeam = { $global:HsAsked++; @{ Ok = $true; Status = 200; Windows = @() } }
        $global:ChatOverlayCodexUsageSeam = { param($h) $global:HsAsked++; @{ Ok = $false; Why = 'none in the tests'; Quiet = $true } }
        $global:ChatOverlayCopilotSeam = { $global:HsAsked++; @{ Ok = $false; Why = 'none in the tests'; Quiet = $true } }
        # its stdin: the lines waiting, then '' - past which the pass's hook -
        # and <eof> for the end
        $global:HsIn = [System.Collections.Generic.List[string]]::new()
        $global:HsPass = 0
        $global:HsCon = @{}
        $global:ChatConsoleInSeam = {
            if ($global:HsIn.Count) {
                $l = $global:HsIn[0]
                $global:HsIn.RemoveAt(0)
                if ($l -eq '<eof>') { return $null }
                return $l
            }
            $global:HsPass++
            foreach ($s in @($global:HsCon[$global:HsPass])) {
                if ($null -eq $s) { continue }
                try { if ($s -is [scriptblock]) { $null = & $s } else { $global:HsIn.Add([string]$s) } }
                catch { $global:HsSay.Add("pass $($global:HsPass): $($_.Exception.Message)") }
            }
            return ''
        }
        $global:HsWord = { Read-ChatqJson $global:ChatConsoleUiPath }
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
        $global:HsHook = {
            param([hashtable]$Plan)
            $global:HsIn.Clear()
            $global:HsPass = 0
            $global:HsCon = $Plan
        }
        & $global:HsHook @{
            1 = {
                $W = $H.Console
                $global:HsHwnd = if ($W) { $W.Hwnd } else { $null }
                $global:HsOk.ctx = $H.Standalone -and $H.Ctx.NoFetch -and -not $H.Ctx.WantAuto -and $H.Ctx.WantAsk -and $null -eq $H.Ctx.Events -and
                    $null -ne $W -and [object]::ReferenceEquals($W, $global:ChatOverlayHost) -and [object]::ReferenceEquals($W.EventOwner, $H)
                & $global:HsNote 'ctx' "standalone $($H.Standalone), no fetch $($H.Ctx.NoFetch), auto $($H.Ctx.WantAuto), console $($null -ne $W)"
                if ($W) {
                    $r = [ChatOverlayNative]::GetRect($W.Hwnd)
                    $global:HsOk.open = (& $global:HsShown $W 'open') -and $global:HsFront -eq 1 -and $null -ne $r -and
                        [Math]::Abs($r[0] + $r[2] + 2214) -le 2 -and [Math]::Abs($r[1] - 197) -le 2
                    & $global:HsNote 'open' "front $($global:HsFront), at $($r -join ','), the panel's $($W.PanelWas.Rect -join ',')"
                }
            }
            # its word after its first pass; news of its own goes to its host there, never to overlay-events.json
            2 = @({
                    $w = & $global:HsWord
                    $cmdText = if (Test-Path -LiteralPath $global:ChatOverlayCmdPath) { [System.IO.File]::ReadAllText($global:ChatOverlayCmdPath) } else { '' }
                    $global:HsOk.word = $w -and [int]$w.pid -eq $PID -and $w.shown -eq $true -and $cmdText -like '*console-ui*'
                    & $global:HsNote 'word' "$(ConvertTo-Json $w -Compress -Depth 4) / overlay-cmd $cmdText"
                    Show-ChatOverlayBalloon $H 'from the console'
                }, 'show', 'reload')
            # a loop of the console's own holds the passes off: its timer keeps its word new
            3 = {
                    $w = & $global:HsWord
                    $global:HsOk.news = @($w.events | Where-Object { $_.text -eq 'from the console' }).Count -eq 1 -and -not (Test-Path -LiteralPath $global:ChatOverlayEventsPath)
                    & $global:HsNote 'news' "$(ConvertTo-Json @($w.events) -Compress -Depth 3), overlay-events.json $(Test-Path -LiteralPath $global:ChatOverlayEventsPath)"
                    $global:HsOk.again = (& $global:HsShown $H.Console 'again') -and $global:HsFront -eq 2 -and $H.ConReload
                    & $global:HsNote 'again' "front $($global:HsFront), reload $($H.ConReload)"
                    $a0 = [int64]$w.at
                    $t0 = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                    $f = [System.Windows.Threading.DispatcherFrame]::new()
                    $s = [System.Windows.Threading.DispatcherTimer]::new()
                    $s.Interval = [TimeSpan]::FromMilliseconds(3500)
                    $s.Tag = $f
                    $s.add_Tick({ param($x, $e) $x.Stop(); $x.Tag.Continue = $false })
                    $s.Start()
                    [System.Windows.Threading.Dispatcher]::PushFrame($f)
                    $a1 = [int64](& $global:HsWord).at
                    $global:HsOk.keep = $a1 -gt $a0 -and $a1 -ge $t0
                    & $global:HsNote 'keep' "at $a0 then $a1, from $t0"
                    $global:HsIn.Add('answer stale')
                }
            4 = { $global:HsOk.reload = -not $H.ConReload -and $null -ne $H.ConAnswer; & $global:HsNote 'reload' "reload $($H.ConReload), answer $($null -ne $H.ConAnswer)" }
            # the answer's pass drew the lists anew and said so; then its
            # hotkey, the console not the window in front, then in front
            5 = {
                    $t = if ($H.Console.Con -and $H.Console.Con.Status) { [string]$H.Console.Con.Status.Text } else { '' }
                    $global:HsOk.answer = $t -eq 'the chats changed - here they are now' -and $null -eq $H.ConAnswer
                    & $global:HsNote 'answer' "status '$t'"
                    $global:ChatConsoleActiveSeam = { $false }
                    $global:HsIn.Add('key')
                }
            6 = {
                    $global:HsOk.key = (& $global:HsShown $H.Console 'key') -and $global:HsFront -eq 3
                    & $global:HsNote 'key' "front $($global:HsFront)"
                    $global:ChatConsoleActiveSeam = { $true }
                    $global:HsIn.Add('key')
                }
            7 = { $global:HsOk.key2 = (& $global:HsGone $H.Console 'key2') -and $global:HsFront -eq 3; & $global:HsNote 'key2' "front $($global:HsFront)" }
        }
        $global:HsWhy1 = Start-ChatConsoleHost -HostPid $PID -Open show -IntervalMs 500 -MaxCycles 12
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action] {}, [System.Windows.Threading.DispatcherPriority]::Background)
        $hw = $global:HsHwnd
        $w = & $global:HsWord
        $global:HsOk.back = [string]$global:HsWhy1 -eq 'back' -and $null -ne $hw -and -not [HsWin]::IsWindow($hw) -and $w -and [int]$w.pid -eq $PID -and $w.shown -eq $false -and $w.underWay -eq $false
        & $global:HsNote 'back' "ended $($global:HsWhy1) after $($global:HsPass), window $(if ($null -ne $hw) { [HsWin]::IsWindow($hw) } else { 'none' }), word $(ConvertTo-Json $w -Compress -Depth 4)"
        $global:ChatConsoleActiveSeam = $null
        # one running already: this one goes at once
        $lk = [System.IO.File]::Open($global:ChatConsoleLockPath, 'OpenOrCreate', 'ReadWrite', 'None')
        try { $global:HsWhy2 = Start-ChatConsoleHost -HostPid $PID -IntervalMs 500 -MaxCycles 2 }
        finally { $lk.Dispose() }
        $global:HsOk.running = [string]$global:HsWhy2 -eq 'running'
        & $global:HsNote 'running' "ended $($global:HsWhy2)"
        # opened by its hotkey, then its host's back
        & $global:HsHook @{
            1 = { $global:HsOk.keyOpen = [bool]($H.Console -and $H.Console.Mode -eq 'console'); & $global:HsNote 'keyOpen' "mode $($H.Console.Mode)"; $global:HsIn.Add('back') }
            2 = { $global:HsOk.backLine = & $global:HsGone $H.Console 'backLine' }
        }
        $global:HsWhy3 = Start-ChatConsoleHost -HostPid $PID -Open key -IntervalMs 500 -MaxCycles 6
        $global:HsOk.backEnd = [string]$global:HsWhy3 -eq 'back'
        & $global:HsNote 'backEnd' "ended $($global:HsWhy3) after $($global:HsPass)"
        # its stdin ended: its host gone, or telling it to go
        & $global:HsHook @{ 1 = '<eof>' }
        $global:HsWhy4 = Start-ChatConsoleHost -HostPid $PID -IntervalMs 500 -MaxCycles 6
        $w = & $global:HsWord
        $free = try { $f = [System.IO.File]::Open($global:ChatConsoleLockPath, 'OpenOrCreate', 'ReadWrite', 'None'); $f.Dispose(); $true } catch { $false }
        $global:HsOk.eof = [string]$global:HsWhy4 -eq 'eof' -and $w -and $w.shown -eq $false -and $free
        & $global:HsNote 'eof' "ended $($global:HsWhy4) after $($global:HsPass), shown $($w.shown), lock free $free"
        $global:HsOk.asked = $global:HsAsked -eq 0
        & $global:HsNote 'asked' "$($global:HsAsked) usage asks"
        $lines = @(if (Test-Path -LiteralPath $global:HsLogPath) { [System.IO.File]::ReadAllLines($global:HsLogPath) })
        $bad = @($lines | Where-Object { $_ -like '*console failed*' -or $_ -like '*console pass:*' -or $_ -like '*console: *' -or $_ -like '*console wait:*' -or $_ -like '*console-ui.json:*' })
        $global:HsOk.quiet = $bad.Count -eq 0
        & $global:HsNote 'quiet' ($bad -join ' | ')
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
        # the console's process stood in: its start and its stdin's lines
        # written down, its close ending it
        $global:HsConLines = [System.Collections.Generic.List[string]]::new()
        $global:ChatConsoleSpawnSeam = {
            param($Open)
            $global:HsConLines.Add("${Open}:spawned")
            $c = [pscustomobject]@{ Id = 4242; HasExited = $false; ExitCode = 0 }
            $in = [pscustomobject]@{ Owner = $c }
            $in | Add-Member -MemberType ScriptMethod -Name WriteLine -Value { param($l) $global:HsConLines.Add([string]$l) }
            $in | Add-Member -MemberType ScriptMethod -Name Flush -Value { }
            $in | Add-Member -MemberType ScriptMethod -Name Close -Value { $global:HsConLines.Add('closed'); $this.Owner.HasExited = $true }
            $c | Add-Member -NotePropertyName StandardInput -NotePropertyValue $in
            $c | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) $this.HasExited }
            $c | Add-Member -MemberType ScriptMethod -Name Kill -Value { }
            $c | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
            $c
        }
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
            12 = @({ $global:HsOk.hotkey = (& $global:HsCmds 'hotkey') -eq 1; & $global:HsNote 'hotkey' "commands $(& $global:HsCmds 'hotkey')" }, 'console', 'console-back', 'hide')
            13 = @({
                    $global:HsOk.hide = (& $global:HsCmds 'hide') -eq 1 -and -not $H.Console -and -not ${function:New-ChatConsole}
                    & $global:HsNote 'hide' "commands $(& $global:HsCmds 'hide'), console $([bool]$H.Console)"
                    $global:HsOk.console = ($global:HsConLines -join ',') -eq 'show:spawned,back,back' -and $H.ConProc -and -not ${function:Start-ChatConsoleHost}
                    & $global:HsNote 'console' "lines $($global:HsConLines -join ','), process $([bool]$H.ConProc)"
                },
                'config theme dark', 'delete s:nope', 'opened s:nope 0', 'card s:nope', 'auto-chip s:nope dont', 'reload-answer 1:x later')
            14 = {
                $s = @($H.Events | Where-Object { $_.kind -eq 'said' -and $_.about -eq 's:nope' } | ForEach-Object { "$($_.said)/$($_.tone)" }) -join ','
                $c = Read-ChatqJson $global:ChatOverlayCardPath
                $global:HsOk.panel = $s -eq 'delete/warn,done/dim' -and $c.key -eq 's:nope' -and $H.Ctx.Config.theme -eq 'dark'
                & $global:HsNote 'panel' "said $s, card $($c.key), theme $($H.Ctx.Config.theme)"
            }
        }
        $global:HsWhy = Start-ChatOverlayHeadlessHost -UiExe 'C:\ui\chatq-overlay.exe' -IntervalMs 3000 -MaxCycles 15
        $global:HsOk.end = [string]$global:HsWhy -eq 'max' -and -not ${function:New-ChatConsole} -and -not ${function:New-ChatOverlayWindow} -and -not ('ChatOverlayNative' -as [type]) -and
            $global:HsConLines.Count -and $global:HsConLines[-1] -eq 'closed'
        & $global:HsNote 'end' "ended $($global:HsWhy), the console's lines $($global:HsConLines -join ',')"
    }
    catch { $global:HsSay.Add("threw: $($_.Exception.Message) @ $($_.ScriptStackTrace)") }
} 2>$null | Out-Null
'@
    $hsStaRun = {
        param([string]$Name, [string]$Body, [string]$Head = $hsHead)
        Remove-Item -LiteralPath (Join-Path $hsToolDir 'data') -Recurse -Force -EA SilentlyContinue
        $text = $Head.Replace('@TOOL@', $hsTool) + "`r`n" + $Body + "`r`n" + $hsTail
        $raw = try { Invoke-Sta $Name $text -Global } catch { "threw: $($_.Exception.Message)" }
        [pscustomobject]@{ Raw = "$raw"; O = $(try { "$raw" | ConvertFrom-Json } catch { $null }) }
    }
    $hsStaCheck = {
        param($R, [string]$Name, [string[]]$Keys)
        $bad = if ($R.O) { @($Keys | Where-Object { $R.O.ok.$_ -ne $true }) } else { @($Keys) }
        Check $Name ($bad.Count -eq 0) "not $($bad -join ', ') // $(if ($R.O) { @($R.O.say) -join ' / ' } else { $R.Raw })"
    }
    # the console's process loads every part, as its launch does
    $hsConHead = $hsHead.Replace("Remove-Item -LiteralPath 'env:CHATQ_ALLPARTS' -EA SilentlyContinue", "`$env:CHATQ_ALLPARTS = '1'")
    $hsStaA = & $hsStaRun 'hs-console' $hsConsoleBody $hsConHead
    & $hsStaCheck $hsStaA 'the native panel''s console''s process: every part loaded; a context of its own that asks no usage endpoint, leaves auto-continue to its host and takes no command' 'parts', 'ctx', 'asked'
    & $hsStaCheck $hsStaA 'it opens cloaked, interactive and on the taskbar, grown from the native panel''s top-right corner, never in front' 'open'
    & $hsStaCheck $hsStaA 'its word in console-ui.json, its pid and shown, a console-ui verb for its host; its news there, never in overlay-events.json; a loop of the console''s own still keeps its word new' 'word', 'news', 'keep'
    & $hsStaCheck $hsStaA 'its host''s lines: show brings it forward again, reload and answer for the next pass - the lists drawn anew and said so when the ask changed under it' 'again', 'reload', 'answer'
    & $hsStaCheck $hsStaA 'the console hotkey''s line: the console brought forward while it is not the window in front, else back to the panel' 'key', 'key2'
    & $hsStaCheck $hsStaA 'back to the panel, it goes at once - its window gone, its last word shown false - by the hotkey, or opened by it and told back' 'back', 'keyOpen', 'backLine', 'backEnd'
    & $hsStaCheck $hsStaA 'one already running: it goes at once; its stdin ended: it goes, its lock let go' 'running', 'eof'
    & $hsStaCheck $hsStaA 'the console''s run calls no function its launch leaves out, and logs no failure' 'missing', 'log', 'quiet'
    $hsStaB = & $hsStaRun 'hs-parts' $hsPartsBody
    & $hsStaCheck $hsStaB 'the headless launch''s parts: none of the WPF panel''s, the console''s or the macOS host''s, no WPF type; the host''s own there' 'parts'
    & $hsStaCheck $hsStaB 'the panel''s opened on the headless launch: every outcome said, the unread dot gone' 'opened'
    & $hsStaCheck $hsStaB 'the panel''s config, auto-chip, delete, reload-answer and card on the headless launch: each done and said' 'config', 'chip', 'delete', 'reload', 'card'
    & $hsStaCheck $hsStaB 'the host''s own verbs on the headless launch: the switch said once, a changed ask shown, refresh, phone, crash, hotkey, hide' 'autoOn', 'autoAsk', 'autoOnce', 'autoAsk2', 'stale', 'stale2', 'refresh', 'phoneFn', 'phone', 'crashOn', 'crashOff', 'hotkey', 'hide'
    & $hsStaCheck $hsStaB 'the console on the headless launch: its process started and told its verbs, none of its parts loaded here' 'console'
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
    $script:ChatOverlayCopilotSeam = $hsWas.Copilot
    $script:ChatOverlayCodexUsageSeam = $hsWas.Codex
    $script:ChatConsoleSpawnSeam = $hsWas.ConSpawn
    $script:ChatConsoleGrantSeam = $hsWas.ConGrant
    Remove-Item -LiteralPath (Join-Path $script:ChatqData 'hs-bin') -Recurse -Force -EA SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $sb 'hs-tool') -Recurse -Force -EA SilentlyContinue
    Remove-Item -LiteralPath $script:ChatOverlayCmdPath -Force -EA SilentlyContinue
    foreach ($p in @($hsFiles.Keys)) { Restore-TestFile $p $hsFiles[$p] }
}
