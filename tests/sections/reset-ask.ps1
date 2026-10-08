# tests/sections/reset-ask.ps1: dot-sourced by tests/run-tests.ps1 in its turn,
# never on its own - it uses what the runner and the sections before it set,
# the overlay section's Set-OvSession, $sessDir and $projO among them.
#
# The reset ask (config autoContinue): once the usage limit is over, the
# overlay says how many chats it cut off, and continues them if you say so.
# The pure parts are driven with -Now; the collector with chats made here,
# every cut-off the sandbox had before them marked answered so that only
# these count; the Windows panel in an STA child. Config, seams, jobs,
# markers, the registry and the chats made here are put back at the end.

Section 'reset ask'
$raCfgWas = Read-TestFile $script:ChatqConfigPath
$raWas = @{ Usage = $script:ChatOverlayUsageSeam; Alive = $script:ChatqAliveSeam; Spawn = $script:ChatqSpawn; Send = $script:ChatqLiveSendSeam; Idle = $script:ChatqIdleSeam }
$raJobsBefore = @(Get-ChatqJobs | ForEach-Object { [string]$_.id })
$script:RaSpawns = 0
$script:ChatqSpawn = { $script:RaSpawns++; $true }
$script:ChatqAliveSeam = { param($e) $true }
Remove-Item -LiteralPath $script:ChatqAutoDir -Recurse -Force -EA SilentlyContinue
$raInv = [System.Globalization.CultureInfo]::InvariantCulture
# a time as the ask words it: HH:mm today, with the day otherwise
$raAt = { param([datetime]$d) if ($d.Date -eq (Get-Date).Date) { $d.ToString('HH:mm', $raInv) } else { $d.ToString('ddd HH:mm', $raInv) } }
$raMs = { param([datetime]$d) [DateTimeOffset]::new($d).ToUnixTimeMilliseconds() }
$raDot = [string][char]0x00B7
$raLog = { $p = Join-Path $script:ChatqLogDir 'overlay.log'; if (Test-Path -LiteralPath $p) { @([System.IO.File]::ReadAllLines($p, $utf8)) } else { @() } }
$raPaths = [System.Collections.Generic.List[string]]::new()

# --- the setting ----------------------------------------------------------------
$acOf = { param($v) Get-ChatqAutoContinue ([pscustomobject]@{ autoContinue = $v }) }
Check 'autoContinue: ask unless off or on - false and "false" read as off, "on" as the automatic mode; missing, true and anything else as ask' (
    (Get-ChatqAutoContinue ([pscustomobject]@{ other = 1 })) -eq 'ask' -and (& $acOf 'off') -eq 'off' -and (& $acOf ' OFF ') -eq 'off' -and (& $acOf $false) -eq 'off' -and
    (& $acOf 'false') -eq 'off' -and (& $acOf $true) -eq 'ask' -and (& $acOf 'on') -eq 'on' -and (& $acOf 'sideways') -eq 'ask' -and (& $acOf 'ask') -eq 'ask') "$(& $acOf $false) $(& $acOf 'on')"
$acSaid = @(Set-ChatqAutoContinue -Value off 6>&1 | ForEach-Object { "$_" })
$acTop = (Get-ChatqConfig).autoContinue
$acOv = (Get-ChatOverlayConfig).autoContinue
Set-ChatOverlayConfig @{ width = (Get-ChatOverlayConfig).width }
$acCfg = Get-ChatqConfig
$acUnder = [bool]($acCfg.PSObject.Properties['overlay'] -and $acCfg.overlay -and $acCfg.overlay.PSObject.Properties['autoContinue'])
$null = Set-ChatqAutoContinue -Value ask
Check 'Set-ChatqAutoContinue: config.json''s top level, never under overlay; the overlay''s config reads it from there, and its own saves leave it; it prints nothing' (
    ($acSaid -join '|') -eq 'off' -and $acTop -eq 'off' -and $acOv -eq 'off' -and $acCfg.autoContinue -eq 'off' -and -not $acUnder -and (Get-ChatOverlayConfig).autoContinue -eq 'ask') "$($acSaid -join '|') $acTop $acOv $($acCfg.autoContinue) $acUnder"

# --- one cut-off, one key ------------------------------------------------------------
$ckAt = [datetime]::new(2026, 9, 27, 12, 0, 0, [DateTimeKind]::Local)
$ckT = $ckAt.ToUniversalTime().Ticks
$ck1 = Get-ChatqCutKey ([pscustomobject]@{ Id = 'a5a5-1'; LimitUuid = 'u-1'; At = $ckAt })
$ck2 = Get-ChatqCutKey ([pscustomobject]@{ Id = 'a5a5-1'; At = $ckAt })
$ck3 = Get-ChatqCutKey ([pscustomobject]@{ Id = 'a5a5-1'; LimitUuid = $null; At = $ckAt.ToUniversalTime().ToString('o') })
$ck4 = Get-ChatqCutKey ([pscustomobject]@{ Id = 'a5a5-1' })
$ck5 = Get-ChatqCutKey ([pscustomobject]@{ Title = 'no id'; LimitUuid = 'u-1' })
$ck6 = Get-ChatqCutKey ([pscustomobject]@{ Id = 'a5a5-1'; LimitUuid = '..\x' })
$ck7 = Get-ChatqCutKey ([pscustomobject]@{ Id = 'a5 a5'; LimitUuid = 'u-1' })
Check 'a cut-off''s key: the chat and its limit record''s uuid; with none, the record''s time; none when there is neither, no id, or it would not make a file name' (
    $ck1 -eq 'a5a5-1_u-1' -and $ck2 -eq "a5a5-1_$ckT" -and $ck3 -eq $ck2 -and $null -eq $ck4 -and $null -eq $ck5 -and $null -eq $ck6 -and $null -eq $ck7) "$ck1 $ck2 $ck3 $ck4 $ck5 $ck6 $ck7"
$raIdU = 'a5a50000-0000-4000-8000-00000000000a'
$raUuidU = 'c5c50000-0000-4000-8000-00000000000a'
$raPaths.Add((New-FakeChat $projA $raIdU 'Uuid carrier' 3 @('carry it') -CutOff -ResetsAt ([DateTimeOffset]::UtcNow.AddHours(-2).ToUnixTimeSeconds()) -LimitUuid $raUuidU))
$raScanU = @(Get-ChatqCutOffChats @() -Hours 168 | Where-Object { $_.Id -eq $raIdU })
Check 'the cut-off scan''s rows carry the limit record''s uuid' ($raScanU.Count -eq 1 -and $raScanU[0].LimitUuid -eq $raUuidU -and (Get-ChatqCutKey $raScanU[0]) -eq "${raIdU}_$raUuidU") "$($raScanU.Count) $($raScanU[0].LimitUuid)"

# --- the pure decision ---------------------------------------------------------------
$N = [datetime]::new(2026, 9, 27, 14, 0, 0, [DateTimeKind]::Local)
$rr = {
    param([string]$Id, $ResetMin, [double]$AtMin = -120, [string]$Why = 'limit', $Uuid = 'u')
    [pscustomobject]@{ Id = $Id; Title = "title $Id"; Why = $Why; ResetsAt = $(if ($null -ne $ResetMin) { $N.AddMinutes($ResetMin) } else { $null })
        At = $N.AddMinutes($AtMin); LimitUuid = $(if ($Uuid) { "u-$Id" } else { $null }); Path = $null; Cwd = $projA }
}
$raRows = @(
    (& $rr 'p1' -30 -100), (& $rr 'p2' -5 -50), (& $rr 'p3' (-299 / 60.0) -40), (& $rr 'p4' 10 -30), (& $rr 'p5' -720 -900), (& $rr 'p6' -719 -800),
    (& $rr 'p7' $null -20 'overloaded'), (& $rr 'p8' $null -20), (& $rr 'p9' -30 -60), (& $rr 'p10' -30 -60), (& $rr 'p11' -30 -60), (& $rr 'p12' -30 -120),
    (& $rr 'p13' -30 -60), (& $rr 'p14' -30 -10 'limit' $null)
)
$raJ = @([pscustomobject]@{ sessionId = 'p10'; state = 'queued' }, [pscustomobject]@{ sessionId = 'p11'; state = 'running' }, [pscustomobject]@{ sessionId = 'p12'; state = 'done' })
$pa = Get-ChatqResetAsk -CutOff $raRows -Held @{ p9 = $true } -Asked @{ 'p13_u-p13' = $true } -Jobs $raJ -Now $N
$p14Key = "p14_$($N.AddMinutes(-10).ToUniversalTime().Ticks)"
$paWant = "$p14Key,p2_u-p2,p1_u-p1,p12_u-p12,p6_u-p6"
Check 'the ask: limit rows whose reset is 5 minutes or more and under 12 hours behind, newest first - not a 529, one with no reset, one reset 4:59 ago, one still ahead, one 12 hours over' (
    $pa -and (@($pa.Keys) -join ',') -eq $paWant -and (@($pa.Items | ForEach-Object { $_.Id }) -join ',') -eq 'p14,p2,p1,p12,p6' -and $pa.Count -eq 5 -and $pa.ResetsAt -eq $N.AddMinutes(-5)) "$(@($pa.Keys) -join ',') $($pa.ResetsAt)"
Check 'and not a chat with a job queued or running (a done one is no matter), one answered already, or one open in a terminal - that one named in Left' (
    @($pa.Left).Count -eq 1 -and $pa.Left[0].Title -eq 'title p9' -and $pa.Left[0].Why -eq 'terminal' -and (@($pa.Items.Id) -notcontains 'p10') -and (@($pa.Items.Id) -notcontains 'p11') -and (@($pa.Items.Id) -notcontains 'p13')) "$(@($pa.Left | ForEach-Object { "$($_.Title)/$($_.Why)" }) -join ',')"
$paL = Get-ChatqResetAsk -CutOff $raRows -Held @{} -Asked @{} -Jobs @() -Limited $true -Now $N
$paN = Get-ChatqResetAsk -CutOff @((& $rr 'p4' 10), (& $rr 'p9' -30)) -Held @{ p9 = $true } -Asked @{} -Jobs @() -Now $N
$paE = Get-ChatqResetAsk -CutOff @() -Held @{} -Asked @{} -Now $N
Check 'no ask while a window is at its limit with its reset ahead, or when no row is in - one left to a terminal alone makes none' ($null -eq $paL -and $null -eq $paN -and $null -eq $paE)

# --- the markers -----------------------------------------------------------------------
$mk1 = @(Save-ChatqAskAnswer -Keys @('m1_a', 'm2_b', 'bad/key', '') -Answer leave -Source test)
$mk2 = @(Save-ChatqAskAnswer -Keys @('m1_a') -Answer continue -Source console)
$mk3 = @(Save-ChatqAskAnswer -Keys @('m3_c') -Answer continue -Source overlay -Seqs @{ 'm3_c' = @(12, 13) })
$mj1 = Read-ChatqJson (Join-Path $script:ChatqAutoDir 'm1_a.json')
$mj3 = Read-ChatqJson (Join-Path $script:ChatqAutoDir 'm3_c.json')
Check 'an answer: one data/auto/<key>.json each - when, what, where, the jobs; one answered already is left as it was and counted; a bad key skipped' (
    ($mk1 -join ',') -eq 'm1_a,m2_b' -and ($mk2 -join ',') -eq 'm1_a' -and ($mk3 -join ',') -eq 'm3_c' -and $mj1.answer -eq 'leave' -and $mj1.source -eq 'test' -and
    @($mj1.seq).Count -eq 0 -and (ConvertTo-ChatqDate $mj1.at) -and $mj3.answer -eq 'continue' -and (@($mj3.seq) -join ',') -eq '12,13' -and
    -not @(Get-ChildItem -LiteralPath $script:ChatqAutoDir -File | Where-Object { $_.Name -like 'bad*' }).Count) "$($mk1 -join ',') / $($mk2 -join ',') / $($mj1 | ConvertTo-Json -Compress)"
$old = (Get-Date).ToUniversalTime().AddDays(-9)
foreach ($n in 'm9_old.json', 'm9_old.shown') {
    $p = Join-Path $script:ChatqAutoDir $n
    [System.IO.File]::WriteAllText($p, '{}', $utf8)
    [System.IO.File]::SetLastWriteTimeUtc($p, $old)
}
Add-ChatqAskShown -Keys @('m1_a', 'm4_d', 'bad/key')
Add-ChatqAskShown -Keys @('m4_d')
$ms1 = Read-ChatqAskState
$ms2 = Read-ChatqAskShown
$msKeys = { param($h) (@($h.Keys) | Sort-Object) -join ',' }
$dirWas = $script:ChatqAutoDir
$script:ChatqAutoDir = Join-Path $sb 'no-such-auto'
$msNone = Read-ChatqAskState
$msNone2 = Read-ChatqAskShown
$script:ChatqAutoDir = $dirWas
Check 'read back: the answered and the announced apart; markers over 8 days old deleted on the way; no folder is nothing, and made by no read' (
    (& $msKeys $ms1) -eq 'm1_a,m2_b,m3_c' -and (& $msKeys $ms2) -eq 'm1_a,m4_d' -and -not (Test-Path -LiteralPath (Join-Path $dirWas 'm9_old.json')) -and
    -not (Test-Path -LiteralPath (Join-Path $dirWas 'm9_old.shown')) -and $msNone.Count -eq 0 -and $msNone2.Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $sb 'no-such-auto'))) "$(& $msKeys $ms1) / $(& $msKeys $ms2)"
Remove-Item -LiteralPath $script:ChatqAutoDir -Recurse -Force -EA SilentlyContinue

# --- chatq -AutoContinue ---------------------------------------------------------------
Remove-Item -LiteralPath $script:ChatOverlayCmdPath -Force -EA SilentlyContinue
$acOffSaid = @(chatq -AutoContinue off 6>&1 | ForEach-Object { "$_" })
$acOffCfg = (Get-ChatqConfig).autoContinue
$acAskSaid = @(chatq -AutoContinue ask 6>&1 | ForEach-Object { "$_" })
$acAskCfg = (Get-ChatqConfig).autoContinue
$acOffLine = "  auto-continue: off - chats the limit cuts off are only marked; chatq '<title>' -Continue queues one"
$acAskLine = '  auto-continue: ask - once the limit is over, the overlay says how many chats it cut off, and continues them if you say so'
Check 'chatq -AutoContinue off, then ask: kept and said; ask with no overlay running says nothing asks until one does' (
    $acOffCfg -eq 'off' -and ($acOffSaid -join '|') -eq $acOffLine -and $acAskCfg -eq 'ask' -and
    ($acAskSaid -join '|') -eq "$acAskLine|    nothing asks while no overlay runs - chatoverlay starts it") "$($acOffSaid -join '|') / $($acAskSaid -join '|')"
$ovLock = [System.IO.File]::Open($script:ChatOverlayLockPath, 'OpenOrCreate', 'ReadWrite', 'None')
try { $acRunSaid = @(chatq -AutoContinue off 6>&1 | ForEach-Object { "$_" }); $acCmds = [System.IO.File]::ReadAllText($script:ChatOverlayCmdPath) } finally { $ovLock.Dispose() }
Remove-Item -LiteralPath $script:ChatOverlayCmdPath -Force -EA SilentlyContinue
Check 'with an overlay running it is told to reload' (($acRunSaid -join '|') -eq $acOffLine -and $acCmds -match ' reload\n') "$($acRunSaid -join '|') / $acCmds"
$acJobs = @(Get-ChatqJobs).Count
$acT = @(chatq 'Parser rewrite' -AutoContinue ask 6>&1 | ForEach-Object { "$_" })
$acP = @(chatq -AutoContinue ask -First 6>&1 | ForEach-Object { "$_" })
$acRef = '  -AutoContinue sets a switch and queues nothing - run it on its own'
$acRefT = '  -AutoContinue on|ask|off is the switch for every chat - for this one, always|never|default'
$acW = @(chatq -AutoContinue ask -WhatIf 6>&1 | ForEach-Object { "$_" })
Check 'refused with a title or another parameter - nothing saved, nothing queued; -WhatIf says what it would set and saves nothing' (
    ($acT -join '|') -eq $acRefT -and ($acP -join '|') -eq $acRef -and (Get-ChatqConfig).autoContinue -eq 'off' -and @(Get-ChatqJobs).Count -eq $acJobs -and
    ($acW -join '|') -eq "  -WhatIf: $($acAskLine.TrimStart())") "$($acT -join '|') / $($acP -join '|') / $($acW -join '|')"
$null = Set-ChatqAutoContinue -Value ask
$acCheat = @(Write-ChatqCheatSheet 6>&1 | ForEach-Object { "$_" })
Check 'the cheat sheet names it' (@($acCheat | Where-Object { $_ -like '*-AutoContinue ask|on|off*' }).Count -eq 1)

# --- the words ---------------------------------------------------------------------------
$fN = [datetime]::new(2026, 9, 27, 10, 0, 0, [DateTimeKind]::Local)
$fTom = $fN.Date.AddDays(1).AddHours(1.5)
$tomSays = $fTom.ToString('ddd HH:mm', $raInv)
Check 'Format-ChatOverlayResetAt: HH:mm today, with the day past midnight; nothing once passed, or with none' (
    (Format-ChatOverlayResetAt (& $raMs $fN.Date.AddHours(13)) $fN) -eq '13:00' -and (Format-ChatOverlayResetAt (& $raMs $fTom) $fN) -eq $tomSays -and
    (Format-ChatOverlayResetAt (& $raMs $fN.AddMinutes(-1)) $fN) -eq '' -and (Format-ChatOverlayResetAt (& $raMs $fN) $fN) -eq '' -and (Format-ChatOverlayResetAt $null $fN) -eq '') "$(Format-ChatOverlayResetAt (& $raMs $fTom) $fN)"
$fw = { param([string]$l, [int]$pct, $min, [bool]$lim = $false) [pscustomobject]@{ label = $l; percent = $pct; resetsAt = $(if ($null -ne $min) { & $raMs $fN.AddMinutes($min) } else { $null }); limited = $lim } }
$rw1 = Get-ChatOverlayResetWindow @((& $fw '5h' 42 90), (& $fw 'week' 50 4000)) $fN
$rw2 = Get-ChatOverlayResetWindow @((& $fw '5h' 100 60 $true), (& $fw 'week' 100 3000 $true)) $fN
$rw3 = Get-ChatOverlayResetWindow @((& $fw '5h' 10 $null), (& $fw 'week' 50 4000)) $fN
$rw4 = Get-ChatOverlayResetWindow @((& $fw '5h' 42 90), (& $fw 'Fable week' 100 3000 $true)) $fN
$rw5 = Get-ChatOverlayResetWindow @((& $fw '5h' 42 -5), (& $fw 'week' 100 -1 $true)) $fN
$rw6 = Get-ChatOverlayResetWindow @() $fN
Check 'the reset a usage line shows: the latest of the windows at their limit, else 5h''s while it is ahead, else none' (
    $rw1 -eq '5h' -and $rw2 -eq 'week' -and $null -eq $rw3 -and $rw4 -eq 'Fable week' -and $null -eq $rw5 -and $null -eq $rw6) "$rw1 $rw2 $rw3 $rw4 $rw5 $rw6"
$fco = { param($why, $r) Format-ChatOverlayCutOff ([pscustomobject]@{ Why = $why; ResetsAt = $r }) $fN }
Check 'a cut-off row still says when it resets, the day too past midnight; over, or a 529, as before' (
    (& $fco 'limit' $fN.Date.AddHours(13)) -eq 'cut off - resets 13:00' -and (& $fco 'limit' $fTom) -eq "cut off - resets $tomSays" -and
    (& $fco 'limit' $fN.AddMinutes(-5)) -eq 'cut off - limit over' -and (& $fco 'limit' $null) -eq 'cut off - limit over' -and (& $fco 'overloaded' $null) -eq '529 - waits for Claude') "$(& $fco 'limit' $fTom)"
$tipSnap = {
    param([int]$CanGo, [int]$Cut, [object[]]$Windows)
    [pscustomobject]@{ counts = [pscustomobject]@{ waiting = 0; needsInput = 0; cutOff = $Cut; idle = 2 }
        header = [pscustomobject]@{ ask = $(if ($CanGo) { [pscustomobject]@{ count = $CanGo } } else { $null }); usage = @([pscustomobject]@{ provider = 'Claude'; windows = $Windows }) } }
}
$tw = @((& $fw '5h' 43 180), (& $fw 'week' 46 4000))
$tp1 = Format-ChatOverlayTooltip (& $tipSnap 2 3 $tw) $fN
$tp2 = Format-ChatOverlayTooltip (& $tipSnap 0 3 $tw) $fN
$tp3 = Format-ChatOverlayTooltip (& $tipSnap 3 2 $tw) $fN
$tp4 = Format-ChatOverlayTooltip (& $tipSnap 0 0 @((& $fw '5h' 43 180), (& $fw 'week' 100 3000 $true))) $fN
$tpBig = Format-ChatOverlayTooltip ([pscustomobject]@{ counts = [pscustomobject]@{ waiting = 12; needsInput = 3; unread = 14; cutOff = 30; busy = 40; running = 1; idle = 88; queued = 9 }
        header = [pscustomobject]@{ ask = [pscustomobject]@{ count = 25 }; usage = @([pscustomobject]@{ provider = 'Claude'; windows = $tw }) } }) $fN
Check 'the tray''s tooltip: "N can continue" first, cut off only for the rest; 5h''s reset when it is the one; never past Windows'' 127 characters' (
    $tp1 -eq 'Charlie: 2 can continue, 1 cut off, 2 idle - 5h 43%, resets 13:00' -and $tp2 -eq 'Charlie: 3 cut off, 2 idle - 5h 43%, resets 13:00' -and
    $tp3 -eq 'Charlie: 3 can continue, 2 idle - 5h 43%, resets 13:00' -and $tp4 -eq 'Charlie: 2 idle - 5h 43%' -and $tpBig.Length -le 127) "$tp1 | $tp2 | $tp3 | $tp4 | $tpBig"
$caAsk = @(Get-ChatOverlayChipActions ([pscustomobject]@{ key = 'ask'; kind = 'ask'; provider = ''; sessionId = ''; cwd = ''; count = 3; keys = @('a_1', 'b_2', 'c_3'); titles = @('One', 'Two', 'Three') }))
$caOpen = @(Get-ChatOverlayChipActions ([pscustomobject]@{ key = "s:$idCard"; kind = 'session'; provider = 'claude'; sessionId = $idCard; cwd = $projA }))
$caCut = @(Get-ChatOverlayChipActions ([pscustomobject]@{ key = "c:$idFw"; kind = 'cutoff'; provider = 'claude'; sessionId = $idFw; cwd = $projA }))
$caRecent = @(Get-ChatOverlayChipActions ([pscustomobject]@{ key = "recent:$idOld"; kind = 'recent'; provider = 'claude'; sessionId = $idOld; cwd = $projA }))
$caJob = @(Get-ChatOverlayChipActions ([pscustomobject]@{ key = 'j:1'; kind = 'job'; provider = 'claude'; sessionId = ''; cwd = $projA }))
$caCodex = @(Get-ChatOverlayChipActions ([pscustomobject]@{ key = "s:$cxId"; kind = 'session'; provider = 'codex'; sessionId = $cxId; cwd = $projA }))
$caNone = @(Get-ChatOverlayChipActions $null)
Check 'the chip''s actions: the banner its two answers, with their tips; a Claude row open - open, cut off or recent; a job, Codex or nothing none' (
    (@($caAsk | ForEach-Object { $_.Id }) -join ',') -eq 'ask-go,ask-leave' -and $caAsk[0].Label -eq 'continue 3' -and $caAsk[1].Label -eq 'leave them' -and
    $caAsk[0].Tip -eq 'Queue "Continue from where you left off." for each of the 3 chats the limit cut off, to go one at a time: One, Two, Three' -and
    $caAsk[1].Tip -eq 'Leave them as they are - their rows stay orange; Continue all in the console still continues them' -and
    (@($caOpen | ForEach-Object { $_.Id }) -join ',') -eq 'open,delete' -and $caOpen[0].Label -eq 'open' -and (@($caCut | ForEach-Object { $_.Id }) -join ',') -eq 'open,delete' -and
    (@($caRecent | ForEach-Object { $_.Id }) -join ',') -eq 'open,delete' -and $caJob.Count -eq 0 -and $caCodex.Count -eq 0 -and $caNone.Count -eq 0) "$(@($caAsk | ForEach-Object { "$($_.Id)=$($_.Label)" }) -join ',') $($caOpen.Count) $($caJob.Count) $($caCodex.Count)"
# each: its ids, then whether delete is greyed
$caSess = { param($st, $where) $a = @(Get-ChatOverlayChipActions ([pscustomobject]@{ key = "s:$idCard"; kind = 'session'; provider = 'claude'; sessionId = $idCard; cwd = $projA; status = $st; where = $where }))
    "$((@($a | ForEach-Object Id)) -join ','):$(@($a | Where-Object { $_.Id -eq 'delete' })[0].Disabled)" }
Check 'delete always beside open, so the chip keeps its width; greyed on a chat at work, waiting or in a terminal' (
    (& $caSess 'idle' 'vscode') -eq 'open,delete:False' -and (& $caSess 'idle' '') -eq 'open,delete:False' -and (& $caSess 'cutoff' 'vscode') -eq 'open,delete:False' -and
    (& $caSess 'idle' 'terminal') -eq 'open,delete:True' -and (& $caSess 'busy' 'vscode') -eq 'open,delete:True' -and (& $caSess 'waiting' 'vscode') -eq 'open,delete:True' -and
    -not @($caRecent | Where-Object { $_.Disabled }).Count -and -not @($caCut | Where-Object { $_.Disabled }).Count) "$(& $caSess 'busy' 'vscode')"
$daNow = Get-Date
Check 'delete asks twice: a second click on the same row under 4 s deletes; another row, or later, asks again' (
    (Test-ChatOverlayDeleteArmed 's:a' $daNow.AddSeconds(-1) 's:a' $daNow) -and -not (Test-ChatOverlayDeleteArmed 's:a' $daNow.AddSeconds(-5) 's:a' $daNow) -and
    -not (Test-ChatOverlayDeleteArmed 's:a' $daNow.AddSeconds(-1) 's:b' $daNow) -and -not (Test-ChatOverlayDeleteArmed '' $null 's:a' $daNow)) ''
# The delete chip's outcome said on the panel's line, not only in a tray
# balloon Focus Assist may hide; the second half of a double-click is no
# answer. A chat not on disk: kept, and why.
$dsOk = Get-ChatOverlayDeleteSay $true 'Deleted "x".'
$dsNo = Get-ChatOverlayDeleteSay $false '"x" is working - delete it once it finishes.'
$Hd = @{ Ctx = @{ ClaudeHome = $claudeHome; Unread = @{} }; OpenSay = $null; ChipDelText = $null; DelArmKey = $null; DelArmAt = $null }
$dRow = [pscustomobject]@{ key = 's:d0d0d0d0-0000-4000-8000-00000000d0d0'; kind = 'session'; provider = 'claude'; sessionId = 'd0d0d0d0-0000-4000-8000-00000000d0d0'; cwd = $projA; title = 'Not on disk'; status = 'idle'; where = 'vscode' }
Invoke-ChatOverlayDeleteChip $Hd $dRow
$dAsked = $Hd.DelArmKey -eq $dRow.key -and $null -eq $Hd.OpenSay
Invoke-ChatOverlayDeleteChip $Hd $dRow
$dDouble = $Hd.DelArmKey -eq $dRow.key -and $null -eq $Hd.OpenSay
$Hd.DelArmAt = (Get-Date).AddSeconds(-1)
Invoke-ChatOverlayDeleteChip $Hd $dRow
$dSaid = $Hd.OpenSay -and $Hd.OpenSay.Kind -eq 'delete' -and $Hd.OpenSay.Tone -eq 'warn' -and $Hd.OpenSay.Text -like '*not on disk*' -and -not $Hd.DelArmKey
Check 'delete: the outcome said on the panel''s line - deleted quietly for 5 s, kept and why in warn''s tone for 20 s; a double-click''s second half is no answer; a second click 1 s on acts' (
    $dsOk.Tone -eq 'dim' -and $dsOk.Keep -eq 5 -and $dsNo.Tone -eq 'warn' -and $dsNo.Keep -eq 20 -and $dsNo.Text -like '*working*' -and
    $dAsked -and $dDouble -and $dSaid) "$dAsked $dDouble $dSaid $($Hd.OpenSay.Text)"

# --- continuing them -----------------------------------------------------------------------
$raC1 = 'a5a50001-0000-4000-8000-000000000001'
$raC2 = 'a5a50002-0000-4000-8000-000000000002'
$raC3 = 'a5a50003-0000-4000-8000-000000000003'
$raGh = 'a5a5dead-0000-4000-8000-00000000dead'
$rs30 = [DateTimeOffset]::UtcNow.AddMinutes(-30).ToUnixTimeSeconds()
$raPaths.Add((New-FakeChat $projA $raC1 'Reset ask one' 1 @('first') -CutOff -ResetsAt $rs30 -LimitUuid 'c5c50001-0000-4000-8000-000000000001'))
$raPaths.Add((New-FakeChat $projA $raC2 'Reset ask two' 1.2 @('second') -CutOff -ResetsAt $rs30 -LimitUuid 'c5c50002-0000-4000-8000-000000000002'))
$raPaths.Add((New-FakeChat $projA $raC3 'Reset ask three' 1.3 @('third') -CutOff -ResetsAt $rs30 -LimitUuid 'c5c50003-0000-4000-8000-000000000003'))
$raScan = @(Get-ChatqCutOffChats @() -Hours 168)
$rc1 = @($raScan | Where-Object { $_.Id -eq $raC1 })[0]
$rc2 = @($raScan | Where-Object { $_.Id -eq $raC2 })[0]
$rc3 = @($raScan | Where-Object { $_.Id -eq $raC3 })[0]
$rGh = [pscustomobject]@{ Id = $raGh; Title = 'Ghost chat'; Why = 'limit'; ResetsAt = $rc1.ResetsAt; At = (Get-Date).AddHours(-1.5); Path = $null; Cwd = $projA; LimitUuid = 'c5c5dead-0000-4000-8000-00000000dead' }
$script:RaSpawns = 0
# older than the continues: a prompt waiting in turn for another chat, and
# one put first
$raRow3 = Get-ChatqRowById $raC3 'claude' $rc3.Path $rc3.Cwd
$raWait = (New-ChatqJob -Row $raRow3 -Prompt 'waiting in turn').Job
$raFirst = (New-ChatqJob -Row $raRow3 -Prompt 'put first' -First).Job
$ic1 = Invoke-ChatqContinueChats -Items @($rc1, $rc2, $rGh)
$raIds = @($raWait.id, $raFirst.id) + @($ic1.Queued | ForEach-Object { $_.id })
$raOrder = @(Get-ChatqJobs | Where-Object { $_.id -in $raIds } | ForEach-Object { [int]$_.seq }) -join ','
$raWant = "$($raFirst.seq),$(@($ic1.Queued | ForEach-Object { $_.seq }) -join ','),$($raWait.seq)"
Check 'continues go ahead of a prompt waiting for another chat, in the order Continue all named them; a job put first stays ahead of them' ($raWait -and $raFirst -and $raOrder -eq $raWant) "$raOrder, want $raWant"
foreach ($j in @($raWait, $raFirst)) { if ($j) { $null = Remove-ChatqJob (Find-ChatqJob $j.id) 'test' } }
$ic2 = Invoke-ChatqContinueChats -Items @($rc1, $rc2)
Check 'Invoke-ChatqContinueChats: a continue job a chat, one not found named in Fails; again, the chats that have one in Had and none queued - and the watcher left to the caller' (
    @($ic1.Queued).Count -eq 2 -and (@($ic1.Queued | ForEach-Object { $_.kind }) -join ',') -eq 'continue,continue' -and (@($ic1.Queued | ForEach-Object { $_.sessionId }) -join ',') -eq "$raC1,$raC2" -and
    (@($ic1.Fails) -join '|') -eq 'Ghost chat: not found' -and -not @($ic1.Had).Count -and -not @($ic2.Queued).Count -and (@($ic2.Had) -join ',') -eq "$raC1,$raC2" -and
    -not @($ic2.Fails).Count -and $script:RaSpawns -eq 0) "$(@($ic1.Queued).Count) $(@($ic1.Fails) -join '|') / $(@($ic2.Had) -join ',') / $($script:RaSpawns)"
foreach ($j in @($ic1.Queued)) { $null = Remove-ChatqJob (Find-ChatqJob $j.id) 'test' }
# the answer, UI-free, as the chip, the tray, the console and the macOS menu give it
$ctxC = New-ChatOverlayContext
$ctxC.Ask = Get-ChatqResetAsk -CutOff @($rc1, $rc2, $rGh) -Held @{} -Asked @{} -Jobs @()
$askK = @($ctxC.Ask.Keys)
$stale = Complete-ChatqResetAsk $ctxC 'continue' @('a5a5ffff-0000-4000-8000-00000000ffff_zz')
$staleOk = $stale.Stale -and $ctxC.Ask -and -not @(Get-ChatqJobs | Where-Object { $_.sessionId -in $raC1, $raC2 }).Count -and $script:RaSpawns -eq 0 -and
    -not (Test-Path -LiteralPath $script:ChatqAutoDir)
$ctxC.CutAt = Get-Date
$ctxC.JobsSig = 'x'
$cr = Complete-ChatqResetAsk $ctxC 'continue' $askK
$crState = Read-ChatqAskState
$crM1 = Read-ChatqJson (Join-Path $script:ChatqAutoDir "$($askK[0]).json")
$crJobs = @(Get-ChatqJobs | Where-Object { $_.kind -eq 'continue' -and $_.state -eq 'queued' -and $_.sessionId -in $raC1, $raC2 })
$crSeq1 = @($cr.Queued | Where-Object { $_.sessionId -eq $raC1 })[0].seq
$crSeq2 = @($cr.Queued | Where-Object { $_.sessionId -eq $raC2 })[0].seq
Check 'Complete-ChatqResetAsk: keys no longer in the ask do nothing at all' $staleOk "$($stale.Stale) $($script:RaSpawns)"
Check 'continue: a continue for each, the watcher asked once; marked continued with its job - one that failed is not, and is asked about again' (
    @($cr.Queued).Count -eq 2 -and $crJobs.Count -eq 2 -and $cr.Request -and $script:RaSpawns -eq 1 -and -not $cr.Stale -and $null -eq $ctxC.Ask -and
    $crState[$askK[0]] -and $crState[$askK[1]] -and -not $crState[$askK[2]] -and $ctxC.AskState[$askK[0]] -and $ctxC.AskState[$askK[1]] -and -not $ctxC.AskState[$askK[2]] -and
    $crM1.answer -eq 'continue' -and $crM1.source -eq 'overlay' -and (@($crM1.seq) -join ',') -eq "$crSeq1" -and $ctxC.CutAt -eq [datetime]::MinValue -and $null -eq $ctxC.JobsSig) "$(@($cr.Queued).Count) $($crJobs.Count) $($script:RaSpawns) $(& $msKeys $crState)"
$crLog = @(& $raLog | Where-Object { $_ -like '*ask: continued*' })
Check 'and says so in the console''s words, the failure too - in AskSaid for the host, and in overlay.log' (
    $cr.Text -eq 'queued 2 continues ahead of the prompts waiting - one at a time, each when its limit is over; Ghost chat: not found' -and $ctxC.AskSaid -eq $cr.Text -and
    $crLog.Count -ge 1 -and $crLog[-1].EndsWith("ask: continued 2 - #$crSeq1 #$crSeq2; failed: Ghost chat: not found")) "$($cr.Text) / $($crLog -join ' | ')"
$cr2 = Complete-ChatqResetAsk $ctxC 'continue' $askK
Check 'a second answer finds nothing to answer' ($cr2.Stale -and @(Get-ChatqJobs | Where-Object { $_.sessionId -in $raC1, $raC2 }).Count -eq 2 -and $script:RaSpawns -eq 1)
$ctxC.Ask = Get-ChatqResetAsk -CutOff @($rc1) -Held @{} -Asked @{} -Jobs @()
$crHad = Complete-ChatqResetAsk $ctxC 'continue' @($ctxC.Ask.Keys)
Check 'one that has a continue already is counted as had, and queued no second' (
    $crHad.Text -eq 'queued 0 continues; 1 had one already' -and -not @($crHad.Queued).Count -and -not $crHad.Request -and
    @(Get-ChatqJobs | Where-Object { $_.sessionId -eq $raC1 }).Count -eq 1) "$($crHad.Text)"
$ctxC.Ask = Get-ChatqResetAsk -CutOff @($rc3) -Held @{} -Asked @{} -Jobs @()
$k3 = @($ctxC.Ask.Keys)[0]
$crL = Complete-ChatqResetAsk $ctxC 'leave' @($ctxC.Ask.Keys) -Source console
$crM3 = Read-ChatqJson (Join-Path $script:ChatqAutoDir "$k3.json")
Check 'leave: marked left, nothing queued, nothing said; overlay.log has it' (
    $crM3.answer -eq 'leave' -and $crM3.source -eq 'console' -and -not @(Get-ChatqJobs | Where-Object { $_.sessionId -eq $raC3 }).Count -and $null -eq $crL.Text -and
    $null -eq $ctxC.AskSaid -and $ctxC.AskState[$k3] -and @(& $raLog | Where-Object { $_.EndsWith('ask: left 1 as they are') }).Count -ge 1) "$($crM3 | ConvertTo-Json -Compress)"
foreach ($j in @(Get-ChatqJobs | Where-Object { $_.sessionId -in $raC1, $raC2, $raC3 })) { $null = Remove-ChatqJob $j 'test' }
Remove-Item -LiteralPath $script:ChatqAutoDir -Recurse -Force -EA SilentlyContinue

# --- the collector -----------------------------------------------------------------------
# every cut-off already in the sandbox answered, so only the ones made here count
$raPre = @(Get-ChatqCutOffChats @() -Hours 168)
$null = Save-ChatqAskAnswer -Keys @($raPre | ForEach-Object { Get-ChatqCutKey $_ } | Where-Object { $_ }) -Answer leave -Source test
$null = New-Item -ItemType Directory -Path $sessDir -Force
Remove-Item -Path (Join-Path $sessDir '*') -Force -EA SilentlyContinue
$raK1 = 'a5a50011-0000-4000-8000-000000000011'
$raK2 = 'a5a50012-0000-4000-8000-000000000012'
$raKT = 'a5a50013-0000-4000-8000-000000000013'
$raKV = 'a5a50014-0000-4000-8000-000000000014'
$raKN = 'a5a50015-0000-4000-8000-000000000015'
$raKW = 'a5a50016-0000-4000-8000-000000000016'
$raKO = 'a5a50017-0000-4000-8000-000000000017'
$raK5 = 'a5a50018-0000-4000-8000-000000000018'
$raK6 = 'a5a50019-0000-4000-8000-000000000019'
$raWc = 'a5a50020-0000-4000-8000-000000000020'
$raUu = { param($id) 'c5c5' + $id.Substring(4) }
$rs20 = [DateTimeOffset]::UtcNow.AddMinutes(-20).ToUnixTimeSeconds()
$raHm = & $raAt ([DateTimeOffset]::FromUnixTimeSeconds($rs20).LocalDateTime)
$rk = { param($Id, $Title, $HoursAgo, $ResetsAt) $raPaths.Add((New-FakeChat $projA $Id $Title $HoursAgo @('work on it') -CutOff -ResetsAt $ResetsAt -LimitUuid (& $raUu $Id))) }
& $rk $raK1 'Ask one' 0.5 $rs20
& $rk $raK2 'Not yet' 0.4 ([DateTimeOffset]::UtcNow.AddMinutes(-1).ToUnixTimeSeconds())
& $rk $raKT 'In a terminal' 0.6 $rs20
& $rk $raKV 'In VS Code' 0.7 $rs20
& $rk $raKN 'No entrypoint' 0.8 $rs20
& $rk $raKW 'Overnight' 14 ([DateTimeOffset]::UtcNow.AddHours(-11).ToUnixTimeSeconds())
& $rk $raKO 'Long over' 14.5 ([DateTimeOffset]::UtcNow.AddHours(-13).ToUnixTimeSeconds())
Set-OvSession 901 $raKT 'idle' 5 $null 'x' 'interactive' 'cli'
Set-OvSession 902 $raKV 'idle' 5 $null 'x' 'interactive' 'claude-vscode'
Set-OvSession 903 $raKN 'idle' 5 $null 'x' 'interactive' ''
$raUse5h = (Get-Date).AddMinutes(90)
$script:RaUsage = @([pscustomobject]@{ Label = '5h'; Percent = 42; ResetsAt = $raUse5h; Severity = 'normal' }, [pscustomobject]@{ Label = 'week'; Percent = 50; ResetsAt = (Get-Date).AddDays(3); Severity = 'normal' })
$script:ChatOverlayUsageSeam = { @{ Ok = $true; Status = 200; Windows = @($script:RaUsage) } }
$kOf = { param($id) "${id}_$(& $raUu $id)" }
$raWant = @($raK1, $raKV, $raKN, $raKW | ForEach-Object { & $kOf $_ })
$shownOf = { @(Get-ChildItem -LiteralPath $script:ChatqAutoDir -Filter '*.shown' -File -EA SilentlyContinue | ForEach-Object { $_.BaseName } | Sort-Object) }
Remove-Item -LiteralPath $script:ChatOverlayCmdPath -Force -EA SilentlyContinue
function New-RaAskContext { $c = New-ChatOverlayContext; $c.WantAsk = $true; $c }
$cxA = New-RaAskContext
$snA = Invoke-ChatOverlayCycle $cxA
$haA = $snA.header.ask
Check 'the collector asks once the reset is 5 minutes behind: the chats it cut off, newest first - not one reset a minute ago, nor one reset 13 hours ago' (
    $cxA.Ask -and (@($cxA.Ask.Keys) -join ',') -eq ($raWant -join ',') -and $cxA.Ask.Count -eq 4) "$(@($cxA.Ask.Keys) -join ',')"
Check 'a chat open in a terminal is left to its own claude and named; one open in a VS Code panel, or with no entrypoint, is asked about' (
    @($cxA.Ask.Left).Count -eq 1 -and $cxA.Ask.Left[0].Title -eq 'In a terminal' -and (@($haA.left) -join '|') -eq 'In a terminal - open in a terminal; its own claude continues it') "$(@($haA.left) -join '|')"
$noteA = @($snA.header.notes | Where-Object { $_.PSObject.Properties['kind'] -and $_.kind -eq 'ask' })
Check 'the snapshot carries it - count, the reset in ms, keys, titles - and a note saying so' (
    $haA.count -eq 4 -and [int64]$haA.resetsAt -eq $rs20 * 1000 -and (@($haA.keys) -join ',') -eq ($raWant -join ',') -and
    (@($haA.titles) -join '|') -eq 'Ask one|In VS Code|No entrypoint|Overnight' -and $noteA.Count -eq 1 -and $noteA[0].text -eq "limit over at $raHm - 4 chats it cut off can continue" -and
    $noteA[0].tone -eq 'warn' -and -not @($snA.header.notes | Where-Object { $_.PSObject.Properties['kind'] -and $_.kind -ne 'ask' }).Count) "$($haA | ConvertTo-Json -Compress) / $($noteA.text)"
$logA = @(& $raLog | Where-Object { $_ -like '*ask: 4 cut-off chats can continue*' })
Check 'announced to the host that shows it: AskNews, each marked shown, and overlay.log' (
    $cxA.AskNews -and (@($cxA.AskNews.Keys) -join ',') -eq ($raWant -join ',') -and ((& $shownOf) -join ',') -eq (($raWant | Sort-Object) -join ',') -and
    $logA.Count -eq 1 -and $logA[0].EndsWith("ask: 4 cut-off chats can continue after the $raHm reset - a5a50011 a5a50014 a5a50015 a5a50016")) "$((& $shownOf) -join ',') / $($logA -join ' | ')"
Check 'an orange row stays while its reset is under 12 hours behind, the cut-off itself older than that; one over 12 hours ago has none' (
    @($cxA.CutOff | Where-Object { $_.Id -eq $raKW }).Count -eq 1 -and -not @($cxA.CutOff | Where-Object { $_.Id -eq $raKO }).Count -and
    @($snA.rows | Where-Object { $_.key -eq "c:$raKW" }).Count -eq 1 -and -not @($snA.rows | Where-Object { $_.key -eq "c:$raKO" }).Count) "$(@($cxA.CutOff | ForEach-Object { $_.Title }) -join ',')"
Check 'the snapshot saved, the keys it named are kept - what the macOS menu''s answer is about' ((@($cxA.AskSavedKeys) -join ',') -eq ($raWant -join ','))
# the one reset a minute ago is answered, so the minutes the checks below
# take never bring it in
$null = Save-ChatqAskAnswer -Keys @(& $kOf $raK2) -Answer leave -Source test
$cxA.AskNews = $null
$null = Invoke-ChatOverlayCycle $cxA
$cxB = New-RaAskContext
$null = Invoke-ChatOverlayCycle $cxB
Check 'announced once: not again on the next pass, nor by an overlay started again - the .shown markers' (
    $null -eq $cxA.AskNews -and $cxB.Ask.Count -eq 4 -and $null -eq $cxB.AskNews -and @(& $raLog | Where-Object { $_ -like '*ask: 4 cut-off chats can continue*' }).Count -eq 1)
$shownN = (& $shownOf).Count
$prOut = (@(Write-ChatOverlayPrint 6>&1 | ForEach-Object { "$_" }) -join '')
Check 'chatoverlay -Print shows the ask''s note, and when 5h resets after its percent - and announces nothing' (
    $prOut -like "*limit over at $raHm - 4 chats it cut off can continue*" -and $prOut -like "*5h 42% resets $(& $raAt $raUse5h)*" -and (& $shownOf).Count -eq $shownN) $prOut
Get-ChildItem -LiteralPath $script:ChatqAutoDir -Filter '*.shown' -File | Remove-Item -Force
$cxP = New-RaAskContext
$snP = Invoke-ChatOverlayCycle $cxP -Peek
$cxN = New-ChatOverlayContext
Send-ChatOverlayCommand 'ask-go'
$null = Invoke-ChatOverlayCycle $cxN
Check 'a -Peek pass, or a context that does not show it (chatoverlay -Print''s), finds the ask but never announces it, marks it shown, or acts on an answer' (
    $cxP.Ask.Count -eq 4 -and $snP.header.ask.count -eq 4 -and $null -eq $cxP.AskNews -and $cxN.Ask.Count -eq 4 -and $null -eq $cxN.AskNews -and (& $shownOf).Count -eq 0 -and
    -not @(Get-ChatqJobs | Where-Object { $_.sessionId -in $raK1, $raKV, $raKN, $raKW }).Count -and -not @($cxN.Commands | Where-Object { $_.verb -like 'ask-*' }).Count) "$($cxP.AskNews) $($cxN.AskNews) $((& $shownOf).Count)"
$cxR = New-RaAskContext
$null = Invoke-ChatOverlayCycle $cxR
Check 'with its markers gone, the next overlay announces it again' ($cxR.AskNews -and @($cxR.AskNews.Keys).Count -eq 4)
$null = Set-ChatqAutoContinue -Value off
$cxO = New-RaAskContext
$snO = Invoke-ChatOverlayCycle $cxO -Peek
$null = Set-ChatqAutoContinue -Value ask
Check 'autoContinue off: no ask, no note - the orange rows stay' (
    $null -eq $cxO.Ask -and $null -eq $snO.header.ask -and -not @($snO.header.notes | Where-Object { $_.PSObject.Properties['kind'] }).Count -and
    @($cxO.CutOff | Where-Object { $_.Id -eq $raK1 }).Count -eq 1) "$($cxO.Ask) $(@($cxO.CutOff).Count)"
$cxF = New-RaAskContext
$cxF.Config.cutOff = $false
$snF = Invoke-ChatOverlayCycle $cxF -Peek
Check 'the orange rows off (cutOff false): still asked, no row drawn for it' (
    $cxF.Ask.Count -eq 4 -and -not @($cxF.CutOff).Count -and -not @($snF.rows | Where-Object { $_.status -eq 'cutoff' }).Count) "$($cxF.Ask.Count) $(@($cxF.CutOff).Count)"
$script:RaUsage = @([pscustomobject]@{ Label = '5h'; Percent = 100; ResetsAt = (Get-Date).AddMinutes(60); Severity = 'critical' })
$cxL = New-RaAskContext
$snL = Invoke-ChatOverlayCycle $cxL -Peek
$script:RaUsage = @([pscustomobject]@{ Label = '5h'; Percent = 42; ResetsAt = $raUse5h; Severity = 'normal' }, [pscustomobject]@{ Label = 'week'; Percent = 50; ResetsAt = (Get-Date).AddDays(3); Severity = 'normal' })
Check 'at the limit again, its reset ahead: nothing asked until then' ($null -eq $cxL.Ask -and $null -eq $snL.header.ask) "$($cxL.Ask)"
# the macOS menu's answers, as verbs in overlay-cmd
Remove-Item -LiteralPath $script:ChatOverlayCmdPath -Force -EA SilentlyContinue
$cxV = New-RaAskContext
$null = Invoke-ChatOverlayCycle $cxV
$savedV = @($cxV.AskSavedKeys)
Send-ChatOverlayCommand 'ask-leave'
$null = Invoke-ChatOverlayCycle $cxV
$stV = Read-ChatqAskState
$mV = Read-ChatqJson (Join-Path $script:ChatqAutoDir "$($raWant[0]).json")
Check 'the macOS menu''s Leave them (ask-leave): the chats the saved snapshot named, marked left from mac; no command passed on; nothing asked after' (
    ($savedV -join ',') -eq ($raWant -join ',') -and -not @($raWant | Where-Object { -not $stV[$_] }).Count -and $mV.answer -eq 'leave' -and $mV.source -eq 'mac' -and
    $null -eq $cxV.Ask -and -not @($cxV.Commands | Where-Object { $_.verb -like 'ask-*' }).Count -and -not @(Get-ChatqJobs | Where-Object { $_.sessionId -in $raK1, $raKV, $raKN, $raKW }).Count) "$($savedV -join ',') $($mV | ConvertTo-Json -Compress)"
& $rk $raK5 'Ask five' 0.3 $rs20
$cxV.CutAt = [datetime]::MinValue
$null = Invoke-ChatOverlayCycle $cxV
$k5 = & $kOf $raK5
$savedV5 = @($cxV.AskSavedKeys)
$script:RaSpawns = 0
Send-ChatOverlayCommand 'ask-go'
$null = Invoke-ChatOverlayCycle $cxV
$m5 = Read-ChatqJson (Join-Path $script:ChatqAutoDir "$k5.json")
$j5 = @(Get-ChatqJobs | Where-Object { $_.sessionId -eq $raK5 -and $_.kind -eq 'continue' -and $_.state -eq 'queued' })
Check 'the macOS menu''s Continue (ask-go): a continue queued for the chat it showed, the watcher asked, marked continued from mac' (
    ($savedV5 -join ',') -eq $k5 -and $j5.Count -eq 1 -and $m5.answer -eq 'continue' -and $m5.source -eq 'mac' -and (@($m5.seq) -join ',') -eq "$($j5[0].seq)" -and
    $script:RaSpawns -eq 1 -and $null -eq $cxV.Ask) "$($savedV5 -join ',') $($j5.Count) $($m5 | ConvertTo-Json -Compress)"
# the phone: one alert for the ask, once you are away
$script:RaSent = [System.Collections.Generic.List[object]]::new()
$script:ChatqLiveSendSeam = { param($a) $script:RaSent.Add($a) }
$cfgP = Get-ChatqConfig
foreach ($n in 'join', 'ntfy', 'phoneEvents') { $cfgP.PSObject.Properties.Remove($n) }
Save-ChatqJson $script:ChatqConfigPath $cfgP
$fakeAsk = [pscustomobject]@{ ResetsAt = (Get-Date).AddMinutes(-20); Count = 2; Items = @(); Keys = @('k_1', 'k_2'); Left = @() }
$pOff = Send-ChatqResetAskAlert (New-ChatOverlayContext) $fakeAsk @('k_1')
Set-ChatqProp $cfgP 'ntfy' 'chatq-reset-ask-test'
Save-ChatqJson $script:ChatqConfigPath $cfgP
$script:ChatqIdleSeam = 0
$pWait = Send-ChatqResetAskAlert (New-ChatOverlayContext) $fakeAsk @('k_1')
$script:ChatqIdleSeam = 99999
$pSent = Send-ChatqResetAskAlert (New-ChatOverlayContext) $fakeAsk @('k_1')
Set-ChatqProp $cfgP 'phoneEvents' @('done')
Save-ChatqJson $script:ChatqConfigPath $cfgP
$pEv = Send-ChatqResetAskAlert (New-ChatOverlayContext) $fakeAsk @('k_1')
$cfgP.PSObject.Properties.Remove('phoneEvents')
Save-ChatqJson $script:ChatqConfigPath $cfgP
Check 'Send-ChatqResetAskAlert: off with no phone, or limited not let through; wait at the PC; sent once you are away' (
    $pOff -eq 'off' -and $pWait -eq 'wait' -and $pSent -eq 'sent' -and $pEv -eq 'off' -and $script:RaSent.Count -eq 1) "$pOff $pWait $pSent $pEv $($script:RaSent.Count)"
$script:RaSent.Clear()
& $rk $raK6 'Ask six' 0.2 $rs20
$cxPh = New-RaAskContext
$cxPh.WantPhone = $true
$script:ChatqIdleSeam = 0
$null = Invoke-ChatOverlayCycle $cxPh
$lim1 = @($script:RaSent | Where-Object { $_.event -eq 'limited' })
$kept = @($cxPh.AskPhone.Keys)
$script:ChatqIdleSeam = 99999
$null = Invoke-ChatOverlayCycle $cxPh
$lim2 = @($script:RaSent | Where-Object { $_.event -eq 'limited' })
$null = Invoke-ChatOverlayCycle $cxPh
$lim3 = @($script:RaSent | Where-Object { $_.event -eq 'limited' })
$k6 = & $kOf $raK6
Check 'the phone: the ask''s alert waits while you are at the PC, goes once you are away - event limited, priority 0, about no one chat - and only once' (
    $lim1.Count -eq 0 -and ($kept -join ',') -eq $k6 -and $lim2.Count -eq 1 -and $lim3.Count -eq 1 -and
    $lim2[0].text -eq "limit over at $raHm $raDot 1 chat it cut off can continue - answer on the PC" -and $lim2[0].priority -eq 0 -and -not $lim2[0].sessionId -and
    $cxPh.AskPhone.Count -eq 0 -and @(& $raLog | Where-Object { $_.EndsWith('phone: reset alert for 1 chat handed to the outbox') }).Count -eq 1) "$($lim1.Count) $($kept -join ',') $($lim2.Count) $($lim3.Count) $($lim2[0].text) / $(@(& $raLog)[-1])"
$script:ChatqLiveSendSeam = $raWas.Send
$script:ChatqIdleSeam = $raWas.Idle
if ($null -ne $raCfgWas) { [System.IO.File]::WriteAllText($script:ChatqConfigPath, $raCfgWas, $utf8) }
$null = Set-ChatqAutoContinue -Value ask
# the macOS menu's answer names the cut-offs its items showed: its title is
# set on a timer that stops while the menu is open, so a snapshot saved
# meanwhile can name one it never showed - that one is not answered
$raNo = 'a5a5ffff-0000-4000-8000-00000000ffff_zz'
Send-ChatOverlayCommand "ask-leave $raNo"
$null = Invoke-ChatOverlayCycle $cxPh
$k6Kept = -not (Read-ChatqAskState)[$k6] -and $cxPh.Ask -and (@($cxPh.Ask.Keys) -contains $k6)
Send-ChatOverlayCommand "ask-leave $k6,$raNo"
$null = Invoke-ChatOverlayCycle $cxPh
$m6 = Read-ChatqJson (Join-Path $script:ChatqAutoDir "$k6.json")
Check 'the macOS menu names what it showed (ask-leave k1,k2): a cut-off it did not show answers nothing; its own are answered, from mac, no command passed on' (
    $k6Kept -and $m6.answer -eq 'leave' -and $m6.source -eq 'mac' -and -not (Test-Path -LiteralPath (Join-Path $script:ChatqAutoDir "$raNo.json")) -and
    -not @($cxPh.Commands | Where-Object { $_.verb -like 'ask-*' }).Count) "$k6Kept $($m6 | ConvertTo-Json -Compress)"

# --- the macOS host's notifications, through the seam in osascript's place ----------
$script:RaNotes = [System.Collections.Generic.List[object]]::new()
$script:ChatOverlayMacNotifySeam = { param($n) $script:RaNotes.Add($n) }
$macAt = (Get-Date).AddMinutes(-20)
$macItems = @('Say "hi" \ there', 'Beta chat', 'Gamma chat', 'Delta chat') | ForEach-Object { [pscustomobject]@{ Id = 'x'; Title = $_ } }
$macCtx = [pscustomobject]@{ AskNews = [pscustomobject]@{ Ask = [pscustomobject]@{ Count = 4; ResetsAt = $macAt; Items = @($macItems); Keys = @() }; Keys = @() }
    AskSaid = 'queued 4 continues ahead of the prompts waiting - one at a time, each when its limit is over' }
Update-ChatOverlayMacAsk $macCtx
Update-ChatOverlayMacAsk $macCtx
$script:ChatOverlayMacNotifySeam = $null
$macText = "limit over at $(& $raAt $macAt) - 4 chats it cut off can continue: Say `"hi`" \ there, Beta chat, Gamma chat and 1 more. Continue or leave them from the CQ menu."
Check 'macOS: a new ask said once as a notification - three titles and the rest counted, pointing at the CQ menu, escaped for AppleScript - then what an answer did' (
    $script:RaNotes.Count -eq 2 -and $script:RaNotes[0].Text -eq $macText -and $script:RaNotes[0].Title -eq 'chatq' -and
    $script:RaNotes[0].Script -eq ('display notification "' + ($macText -replace '\\', '\\' -replace '"', '\"') + '" with title "chatq"') -and
    $script:RaNotes[1].Text -eq 'queued 4 continues ahead of the prompts waiting - one at a time, each when its limit is over' -and $null -eq $macCtx.AskNews -and $null -eq $macCtx.AskSaid) "$(@($script:RaNotes | ForEach-Object { $_.Script }) -join ' // ')"

# the console's list with overlay.cutOff off: no cut-off rows in the
# snapshot, but the ask's balloon sends you there - its chats listed from the
# ask itself, each once
$ckItem = [pscustomobject]@{ Id = 'a5a5c0c0-0000-4000-8000-00000000c0c0'; Title = 'Asked chat'; Cwd = 'C:\p\api'; Path = 'C:\p\x.jsonl'; ResetsAt = (Get-Date).AddMinutes(-20); Why = 'limit' }
$ckH = @{ Con = @{ Pool = @(); PoolStamp = 1; IndexStamp = 1; Index = @(); Search = '' }; Snap = [pscustomobject]@{ rows = @() }
    Ctx = @{ Text = @{}; Config = [pscustomobject]@{ cutOff = $false }; Ask = [pscustomobject]@{ Items = @($ckItem); Keys = @('a5a5c0c0-0000-4000-8000-00000000c0c0_1'); Count = 1; ResetsAt = $ckItem.ResetsAt } } }
$ckNone = @((Get-ChatConsoleChatItems $ckH).CutOff)
$ckH.Snap = [pscustomobject]@{ rows = @([pscustomobject]@{ key = "c:$($ckItem.Id)"; kind = 'cutoff'; status = 'cutoff'; sessionId = $ckItem.Id; title = 'Asked chat'; project = 'api'; cwd = 'C:\p\api'; path = 'C:\p\x.jsonl'; stateText = 'cut off - limit over' }) }
$ckRow = @((Get-ChatConsoleChatItems $ckH).CutOff)
$ckH.Snap = [pscustomobject]@{ rows = @() }
$ckH.Ctx.Config = [pscustomobject]@{ cutOff = $true }
$ckOn = @((Get-ChatConsoleChatItems $ckH).CutOff)
Check 'the console with overlay.cutOff off: the ask''s chats listed under Cut off from the ask itself, each once; with the rows on, the rows alone' (
    $ckNone.Count -eq 1 -and $ckNone[0].Title -eq 'Asked chat' -and $ckNone[0].Kind -eq 'cutoff' -and $ckNone[0].State -eq 'cut off - limit over' -and $ckNone[0].Row.kind -eq 'cutoff' -and
    $ckRow.Count -eq 1 -and $ckOn.Count -eq 0) "$($ckNone.Count) $(@($ckNone | ForEach-Object { "$($_.Title)/$($_.State)" }) -join ',') / $($ckRow.Count) / $($ckOn.Count)"

# --- the Windows panel, in the STA process WPF needs -------------------------------
# a chat of its own to answer for, one the scan finds unanswered
& $rk $raWc 'Panel answer' 0.25 $rs20
$kWc = & $kOf $raWc
$raWpf = @"
$staLoad
`$script:RaErr = @()
trap { `$script:RaErr += "`$(`$_.Exception.Message) @ `$(`$_.InvocationInfo.ScriptLineNumber)"; continue }
`$cfgWas = [IO.File]::ReadAllText(`$script:ChatqConfigPath)
Set-ChatOverlayConfig @{ width = 380; maxRows = 8; prompts = `$true; recent = 0; hotkey = 'none'; consoleHotkey = 'none'; usageView = 'lines' }
`$script:ChatqSpawn = { `$true }
`$script:ChatConsoleNoSync = `$true
`$script:RaBalloons = [System.Collections.Generic.List[object]]::new()
`$script:ChatOverlayBalloonSeam = { param(`$b) `$script:RaBalloons.Add([pscustomobject]`$b) }
Initialize-ChatOverlayNative
$staPanel
`$H.Placed = `$true
`$script:ChatOverlayWorkAreaSeam = { param(`$r) [pscustomobject]@{ X = -4000; Y = 0; Width = 1920; Height = 1020 } }
Set-ChatOverlayHidden `$H `$false
[ChatOverlayNative]::MoveTo(`$H.Hwnd, -2594, 197)
`$inv = [System.Globalization.CultureInfo]::InvariantCulture
`$dot = [string][char]0x00B7
`$hm = { param([datetime]`$d) if (`$d.Date -eq (Get-Date).Date) { `$d.ToString('HH:mm', `$inv) } else { `$d.ToString('ddd HH:mm', `$inv) } }
`$ms = { param([datetime]`$d) [DateTimeOffset]::new(`$d).ToUnixTimeMilliseconds() }
`$runsOf = { param(`$el) @(@(`$el.Children) | ForEach-Object { (@(`$_.Inlines) | ForEach-Object { `$_.Text }) -join '' }) -join '|' }
`$draw = { param(`$snap, `$sig) `$H.Ctx.ViewSig = `$sig; `$H.ViewKey = `$null; Update-ChatOverlayView `$H `$snap; `$H.Win.UpdateLayout() }
`$midOf = { param(`$line) @(`$line.Children | Where-Object { `$_ -is [System.Windows.Controls.TextBlock] -and `$_.TextWrapping -eq [System.Windows.TextWrapping]::Wrap })[0] }
# the usage line: when 5h resets, after its percent - a clock that goes once the time has passed
`$r5 = (Get-Date).AddMinutes(90)
`$w5 = [pscustomobject]@{ label = '5h'; percent = 42; resetsAt = (& `$ms `$r5); severity = 'normal'; limited = `$false }
`$wk = [pscustomobject]@{ label = 'week'; percent = 50; resetsAt = (& `$ms (Get-Date).AddDays(3)); severity = 'normal'; limited = `$false }
`$use = @([pscustomobject]@{ provider = 'Claude'; source = 'live'; stale = `$false; status = '22:22'; windows = @(`$w5, `$wk) })
& `$draw ([pscustomobject]@{ header = [pscustomobject]@{ usage = `$use; notes = @() }; rows = @() }) 'u1'
`$line1 = & `$runsOf `$H.Stack.Children[0]
`$run1 = @((& `$midOf `$H.Stack.Children[0]).Inlines | Where-Object { `$_.Text -like ' resets *' })
`$clock = @(`$H.Clocks | Where-Object { `$_.Kind -eq 'at' })
`$usageOk = `$line1 -eq ('Claude|22:22|5h 42% resets ' + (& `$hm `$r5) + ' ' + `$dot + ' week 50%') -and `$run1.Count -eq 1 -and `$run1[0].Foreground -eq (Get-ChatOverlayBrush 'dim') -and
    `$clock.Count -eq 1 -and `$clock[0].Block -eq `$run1[0]
`$clock[0].At = & `$ms (Get-Date).AddMinutes(-1)
Update-ChatOverlayClock `$H
`$usageOk = `$usageOk -and `$run1[0].Text -eq ''
# a week at its limit: its reset, not 5h's, in the limit's colour
`$rw = (Get-Date).AddDays(2)
`$w5l = [pscustomobject]@{ label = '5h'; percent = 100; resetsAt = (& `$ms (Get-Date).AddMinutes(60)); severity = 'critical'; limited = `$true }
`$wkl = [pscustomobject]@{ label = 'week'; percent = 100; resetsAt = (& `$ms `$rw); severity = 'critical'; limited = `$true }
& `$draw ([pscustomobject]@{ header = [pscustomobject]@{ usage = @([pscustomobject]@{ provider = 'Claude'; source = 'live'; stale = `$false; status = '22:22'; windows = @(`$w5l, `$wkl) }); notes = @() }; rows = @() }) 'u2'
`$line2 = & `$runsOf `$H.Stack.Children[0]
`$run2 = @((& `$midOf `$H.Stack.Children[0]).Inlines | Where-Object { `$_.Text -like ' resets *' })
`$weekOk = `$line2 -eq ('Claude|22:22|5h 100% ' + `$dot + ' week 100% resets ' + (& `$hm `$rw)) -and `$run2.Count -eq 1 -and `$run2[0].Foreground -eq (Get-ChatOverlayBrush 'critical')
# the banner: last in the header, after the notes and in place of the ask's own
`$askAt = (Get-Date).AddMinutes(-20)
`$ask = [pscustomobject]@{ count = 3; resetsAt = (& `$ms `$askAt); keys = @('a5_1', 'a5_2', 'a5_3'); titles = @('T one', 'T two', 'T three'); left = @('T four - open in a terminal; its own claude continues it') }
`$notes = @([pscustomobject]@{ text = 'next queued prompt: 17:10'; tone = 'dim' }, [pscustomobject]@{ text = 'limit over at 12:00 - 3 chats it cut off can continue'; tone = 'warn'; kind = 'ask' })
`$rows = @(1..2 | ForEach-Object { [pscustomobject]@{ key = "s:`$_"; kind = 'session'; status = 'idle'; rank = 3; project = 'p'; title = "chat `$_"; prompt = 'x'; stateText = 'idle 1m'; job = `$null } })
`$snapA = [pscustomobject]@{ header = [pscustomobject]@{ usage = `$use; notes = `$notes; ask = `$ask }; counts = [pscustomobject]@{ idle = 2; cutOff = 3 }; rows = `$rows }
& `$draw `$snapA 'a1'
`$kids = @(`$H.Stack.Children)
`$ban = @(`$kids | Where-Object { `$_.Tag -and `$_.Tag -isnot [string] -and `$_.Tag.key -eq 'ask' })
`$bi = if (`$ban.Count) { `$kids.IndexOf(`$ban[0]) } else { -1 }
`$bl = if (`$ban.Count) { `$ban[0].Children[0] } else { `$null }
`$btexts = @(`$bl.Children | Where-Object { `$_ -is [System.Windows.Controls.TextBlock] } | ForEach-Object { `$_.Text })
`$rects = @(Get-ChatOverlayRowRects `$H)
`$bannerOk = `$ban.Count -eq 1 -and `$ban[0].Tag.kind -eq 'ask' -and (@(`$ban[0].Tag.keys) -join ',') -eq 'a5_1,a5_2,a5_3' -and `$bl.Tag -eq 'line' -and
    (`$btexts -contains ('limit over at ' + (& `$hm `$askAt) + ' ' + `$dot + ' 3 chats it cut off can continue')) -and (`$btexts -contains 'continue?') -and
    `$bi -gt 0 -and `$kids[`$bi + 1] -is [System.Windows.Controls.Border] -and `$kids[`$bi - 1].Text -eq 'next queued prompt: 17:10' -and
    -not @(`$kids | Where-Object { `$_ -is [System.Windows.Controls.TextBlock] -and `$_.Text -like 'limit over*' }).Count -and
    (Get-ChatOverlayDrawnRows `$H) -eq 2 -and @(`$rects | Where-Object { `$_.Key -eq 'ask' }).Count -eq 1 -and
    "`$(`$ban[0].ToolTip)" -eq "T one``nT two``nT three``nT four - open in a terminal; its own claude continues it"
`$bannerSay = "banner `$(`$ban.Count) at `$bi texts [`$(`$btexts -join '/')] drawn `$(Get-ChatOverlayDrawnRows `$H) rects `$(@(`$rects | ForEach-Object { `$_.Key }) -join ',')"
# collapsed: the one line counts them apart, and says when 5h resets
Set-ChatOverlayCollapsed `$H `$true
`$one = @(`$H.Stack.Children[0].Children | Where-Object { `$_ -is [System.Windows.Controls.TextBlock] } | ForEach-Object { `$_.Text }) -join '/'
Set-ChatOverlayCollapsed `$H `$false
`$foldOk = `$one -eq ('5h 42% resets ' + (& `$hm `$r5) + ' ' + `$dot + ' week 50%/3 can continue ' + `$dot + ' 2 idle')
# the chip on the banner: its two answers; on a Claude row: open and delete
`$e = @(`$rects | Where-Object { `$_.Key -eq 'ask' })[0]
Show-ChatOverlayChip `$H `$e
`$cc = `$H.ChipWin.Content
`$chipAsk = `$cc -is [System.Windows.Controls.StackPanel] -and (@(`$cc.Children | ForEach-Object { `$_.Tag }) -join ',') -eq 'ask-go,ask-leave' -and
    (@(`$cc.Children | ForEach-Object { `$_.Child.Text }) -join ',') -eq 'continue 3,leave them' -and `$null -eq `$H.ChipText -and
    "`$(`$cc.Children[0].ToolTip)" -like 'Queue "Continue from where you left off." for each of the 3 chats the limit cut off, to go one at a time: T one, T two, T three' -and @(`$H.ChipActions).Count -eq 2
Hide-ChatOverlayChip `$H
`$H.ChipActions = @(Get-ChatOverlayChipActions ([pscustomobject]@{ key = 's:x'; kind = 'session'; provider = 'claude'; sessionId = '$idCard'; cwd = '$projA' }))
New-ChatOverlayChipContent `$H
`$cc = `$H.ChipWin.Content
`$chipOpen = (@(`$cc.Children | ForEach-Object { `$_.Tag }) -join ',') -eq 'open,delete' -and `$H.ChipText -eq `$cc.Children[0].Child -and `$H.ChipText.Text -eq 'open' -and
    `$H.ChipDelText -eq `$cc.Children[1].Child -and `$H.ChipDelText.Foreground -eq (Get-ChatOverlayBrush 'text')
# on a chat at work: delete greyed, and a reset leaves it grey
`$H.ChipActions = @(Get-ChatOverlayChipActions ([pscustomobject]@{ key = 's:x'; kind = 'session'; provider = 'claude'; sessionId = '$idCard'; cwd = '$projA'; status = 'busy' }))
New-ChatOverlayChipContent `$H
Reset-ChatOverlayDeleteArm `$H
`$chipOpen = `$chipOpen -and `$H.ChipDelText.Foreground -eq (Get-ChatOverlayBrush 'faint') -and `$H.ChipDelText.Text -eq 'delete'
# the settings box's seventh row: Cut off, Ask or Leave
Set-ChatOverlaySettingsOpen `$H `$true
`$chipsOf = { param(`$t) @(`$H.Settings.Child.Children | Where-Object { `$_ -is [System.Windows.Controls.StackPanel] -and @(`$_.Children | ForEach-Object { `$_.Tag }) -contains `$t })[0] }
`$on = { param(`$p) @(`$p.Children | Where-Object { `$_.Background -eq (Get-ChatOverlayBrush 'accent') } | ForEach-Object { `$_.Tag }) -join ',' }
`$cut = & `$chipsOf 'leave'
`$lab = @(`$H.Settings.Child.Children | Where-Object { `$_ -is [System.Windows.Controls.TextBlock] -and [System.Windows.Controls.Grid]::GetRow(`$_) -eq 6 -and [System.Windows.Controls.Grid]::GetColumn(`$_) -eq 0 })[0]
`$setOk = `$cut -and (@(`$cut.Children | ForEach-Object { `$_.Tag }) -join ',') -eq 'continue,ask,leave' -and (@(`$cut.Children | ForEach-Object { `$_.Child.Text }) -join ',') -eq 'Continue,Ask,Leave' -and
    (& `$on `$cut) -eq 'ask' -and [System.Windows.Controls.Grid]::GetRow(`$cut) -eq 6 -and `$lab.Text -eq 'Cut off' -and "`$(`$lab.ToolTip)" -like 'A chat the usage limit cuts off: Continue sends it*Ask says so*' -and
    "`$(`$cut.Children[1].ToolTip)" -like 'Once the limit is over*' -and "`$(`$cut.Children[2].ToolTip)" -like 'Only mark them*'
`$H.Ctx.CutAt = Get-Date
Set-ChatOverlayAutoChoice `$H 'leave'
`$afterLeave = (Get-ChatqConfig).autoContinue -eq 'off' -and `$H.Ctx.Config.autoContinue -eq 'off' -and (& `$on (& `$chipsOf 'leave')) -eq 'leave' -and `$H.Ctx.CutAt -eq [datetime]::MinValue
Set-ChatOverlayAutoChoice `$H 'ask'
`$cfgNow = Get-ChatqConfig
`$setOk = `$setOk -and `$afterLeave -and `$cfgNow.autoContinue -eq 'ask' -and (& `$on (& `$chipsOf 'leave')) -eq 'ask' -and -not (`$cfgNow.overlay -and `$cfgNow.overlay.PSObject.Properties['autoContinue'])
`$setSay = "set `$([bool]`$cut) `$(& `$on `$cut) row `$([System.Windows.Controls.Grid]::GetRow(`$cut)) lab '`$(`$lab.Text)' after `$afterLeave cfg `$(`$cfgNow.autoContinue) ctx `$(`$H.Ctx.Config.autoContinue)"
Set-ChatOverlaySettingsOpen `$H `$false
# a balloon: through the one place that shows one, cut to 250
`$script:RaBalloons.Clear()
Show-ChatOverlayBalloon `$H ('x' * 300) -Title 'long' -Kind 'test' -Keys @('a5_1', '')
`$b0 = `$script:RaBalloons[0]
`$balloonOk = `$script:RaBalloons.Count -eq 1 -and `$b0.Text.Length -eq 250 -and `$b0.Text.EndsWith([string][char]0x2026) -and `$b0.Title -eq 'long' -and `$b0.Kind -eq 'test' -and
    (@(`$b0.Keys) -join ',') -eq 'a5_1' -and `$H.BalloonKind -eq 'test' -and (@(`$H.BalloonKeys) -join ',') -eq 'a5_1'
# a new ask ballooned once, then what an answer did
`$script:RaBalloons.Clear()
`$items = @('Alpha chat', 'Beta chat', 'Gamma chat', 'Delta chat') | ForEach-Object { [pscustomobject]@{ Id = 'x'; Title = `$_ } }
`$ctxAsk = [pscustomobject]@{ ResetsAt = `$askAt; Items = @(`$items); Keys = @('k_1', 'k_2', 'k_3', 'k_4'); Count = 4; Left = @() }
`$H.Ctx.Ask = `$ctxAsk
`$H.Ctx.AskNews = [pscustomobject]@{ Ask = `$ctxAsk; Keys = @(`$ctxAsk.Keys) }
Update-ChatOverlayAsk `$H
Update-ChatOverlayAsk `$H
`$bn = `$script:RaBalloons[0]
`$newsOk = `$script:RaBalloons.Count -eq 1 -and `$bn.Title -eq ('Charlie - limit over at ' + (& `$hm `$askAt)) -and
    `$bn.Text -eq '4 chats it cut off can continue: Alpha chat, Beta chat, Gamma chat and 1 more. Click to see them.' -and `$bn.Kind -eq 'ask' -and
    (@(`$bn.Keys) -join ',') -eq 'k_1,k_2,k_3,k_4' -and `$null -eq `$H.Ctx.AskNews
`$H.Ctx.AskSaid = 'queued 1 continue ahead of the prompts waiting - it goes when its limit is over'
Update-ChatOverlayAsk `$H
Update-ChatOverlayAsk `$H
`$newsOk = `$newsOk -and `$script:RaBalloons.Count -eq 2 -and `$script:RaBalloons[1].Text -eq 'queued 1 continue ahead of the prompts waiting - it goes when its limit is over' -and `$script:RaBalloons[1].Kind -eq '' -and `$null -eq `$H.Ctx.AskSaid
`$newsSay = "`$(@(`$script:RaBalloons | ForEach-Object { "`$(`$_.Title): `$(`$_.Text) [`$(`$_.Kind)]" }) -join ' // ')"
# the tray's two answers: shown while an ask is out, hidden once it is gone -
# by Available, since a closed menu's items read Visible false
Add-Type -AssemblyName System.Windows.Forms
`$tm = New-Object System.Windows.Forms.ContextMenuStrip
`$H.Menu.AskGo = `$tm.Items.Add('Continue cut-off chats')
`$H.Menu.AskLeave = `$tm.Items.Add('Leave them')
`$H.Menu.AskSep = [System.Windows.Forms.ToolStripSeparator]::new()
[void]`$tm.Items.Add(`$H.Menu.AskSep)
foreach (`$i in `$H.Menu.AskGo, `$H.Menu.AskLeave, `$H.Menu.AskSep) { `$i.Available = `$false }
Update-ChatOverlayAsk `$H
`$trayOn = `$H.Menu.AskGo.Available -and `$H.Menu.AskLeave.Available -and `$H.Menu.AskSep.Available -and `$H.Menu.AskGo.Text -eq 'Continue 4 cut-off chats' -and (@(`$H.AskMenuKeys) -join ',') -eq 'k_1,k_2,k_3,k_4'
`$H.Ctx.Ask = `$null
Update-ChatOverlayAsk `$H
`$trayOk = `$trayOn -and -not `$H.Menu.AskGo.Available -and -not `$H.Menu.AskLeave.Available -and -not `$H.Menu.AskSep.Available -and @(`$H.AskMenuKeys).Count -eq 0
foreach (`$k in 'AskGo', 'AskLeave', 'AskSep') { `$H.Menu.Remove(`$k) }
`$tm.Dispose()
`$H.Ctx.Ask = `$ctxAsk
# the console's Cut off header while the ask is pending, Leave them beside Continue all
`$H.Snap = [pscustomobject]@{ header = [pscustomobject]@{ usage = @(); notes = @() }; counts = [pscustomobject]@{ queued = 0; running = 0; cutOff = 1 }; rows = @(
    [pscustomobject]@{ key = 'c:c1'; kind = 'cutoff'; status = 'cutoff'; chat = 'cutoff'; rank = 0.5; project = 'api'; title = 'Rate limiter'; stateText = 'cut off - limit over'; sessionId = 'c1'; cwd = 'C:\p'; path = 'C:\p\x.jsonl'; job = `$null; prompt = `$null }) }
Remove-Item -LiteralPath `$script:ChatConsoleStatePath -Force -EA SilentlyContinue
Enter-ChatOverlayConsoleMode `$H
`$C = `$H.Con
`$C.IndexParsed = `$true
`$C.Index = @()
`$headOf = {
    `$C.Sigs.Chats = `$null
    Update-ChatConsole `$H
    `$hd = @(`$C.Chats.Children | Where-Object { `$_ -is [System.Windows.Controls.DockPanel] })[0]
    `$tx = @(`$hd.Children | Where-Object { `$_ -is [System.Windows.Controls.TextBlock] })[0].Text
    `$bt = `$hd.Children[0]
    `$names = if (`$bt -is [System.Windows.Controls.StackPanel]) { @(`$bt.Children | ForEach-Object { `$_.Child.Text }) -join ',' } else { `$bt.Child.Text }
    `$tag = if (`$bt -is [System.Windows.Controls.StackPanel]) { @(`$bt.Children[0].Tag) -join ',' } else { '' }
    "`$tx|`$names|`$tag"
}
`$conAsk = & `$headOf
`$H.Ctx.Ask = `$null
`$conNone = & `$headOf
# an answer to the ask that is gone, given in the console: nothing done, the
# console kept, and its status line says why
Set-ChatConsoleStatus `$H '' 'dim'
Invoke-ChatOverlayAskAnswer `$H 'leave' @('k_1')
`$conStale = "`$(`$H.Mode)|`$(`$C.Status.Text)"
`$conOk = `$conAsk -eq ('Cut off (1) ' + `$dot + ' limit over at ' + (& `$hm `$askAt) + ' - 4 can continue|Leave them,Continue all|k_1,k_2,k_3,k_4') -and `$conNone -eq 'Cut off (1)|Continue all|' -and
    `$conStale -eq 'console|the chats changed - here they are now' -and -not (Test-Path -LiteralPath (Join-Path `$script:ChatqAutoDir 'k_1.json'))
Exit-ChatOverlayConsoleMode `$H
# an answer: held through a drag and run once it ends, then a continue queued
# through the seams, marked, and said in a balloon; one about an ask gone does nothing
`$script:RaBalloons.Clear()
`$wcRow = @(Get-ChatqCutOffChats @() -Hours 168 | Where-Object { `$_.Id -eq '$raWc' })[0]
`$H.Ctx.Ask = Get-ChatqResetAsk -CutOff @(`$wcRow) -Held @{} -Asked @{} -Jobs @()
`$wcKeys = @(`$H.Ctx.Ask.Keys)
# the stand-in watcher never comes up, and the answer's pass - this
# process's first over the whole sandbox - can outlast the 10 s a watcher
# asked for has to start in on a slow machine: the request's clock held at
# now, so it stays pending however long the answer takes
`$twr = `${function:Test-ChatqWatcherRequest}
`${function:Test-ChatqWatcherRequest} = { param(`$Request, [bool]`$Queued) if (`$Request) { `$Request.At = Get-Date }; & `$twr `$Request `$Queued }
`$H.Dragging = `$true
Invoke-ChatOverlayAskAnswer `$H 'continue' `$wcKeys
`$heldOk = `$H.AskHeld -and `$H.AskHeld.Answer -eq 'continue' -and `$H.Ctx.Ask -and -not @(Get-ChatqJobs | Where-Object { `$_.sessionId -eq '$raWc' }).Count
`$H.Dragging = `$false
Invoke-ChatOverlayHeldVerbs `$H
`${function:Test-ChatqWatcherRequest} = `$twr
`$wcJobs = @(Get-ChatqJobs | Where-Object { `$_.sessionId -eq '$raWc' -and `$_.kind -eq 'continue' -and `$_.state -eq 'queued' })
`$mark = Read-ChatqJson (Join-Path `$script:ChatqAutoDir ('$kWc' + '.json'))
`$answerOk = `$heldOk -and `$null -eq `$H.AskHeld -and (`$wcKeys -join ',') -eq '$kWc' -and `$wcJobs.Count -eq 1 -and `$mark.answer -eq 'continue' -and `$mark.source -eq 'overlay' -and
    (@(`$mark.seq) -join ',') -eq "`$(`$wcJobs[0].seq)" -and `$H.AskRequest -and @(`$script:RaBalloons | Where-Object { `$_.Text -eq 'queued 1 continue ahead of the prompts waiting - it goes when its limit is over' }).Count -eq 1
`$nb = `$script:RaBalloons.Count
Invoke-ChatOverlayAskAnswer `$H 'leave' @('a5a5ffff-0000-4000-8000-00000000ffff_zz')
`$answerOk = `$answerOk -and `$script:RaBalloons.Count -eq `$nb -and -not (Test-Path -LiteralPath (Join-Path `$script:ChatqAutoDir 'a5a5ffff-0000-4000-8000-00000000ffff_zz.json'))
`$answerSay = "held `$heldOk keys `$(`$wcKeys -join ',') jobs `$(`$wcJobs.Count) mark `$(`$mark | ConvertTo-Json -Compress) request `$([bool]`$H.AskRequest) balloons `$(@(`$script:RaBalloons | ForEach-Object { `$_.Text }) -join ' // ')"
Invoke-ChatOverlayVerb 'stop'
[IO.File]::WriteAllText(`$script:ChatqConfigPath, `$cfgWas)
'{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}|{10}|{11}|{12}|{13}' -f `$usageOk, `$weekOk, `$bannerOk, `$foldOk, `$chipAsk, `$chipOpen, `$setOk, `$balloonOk, `$newsOk, `$conOk, `$answerOk,
    (`$script:RaErr -join ' / '), ("line1 [`$line1] line2 [`$line2] `$bannerSay fold [`$one] `$setSay news [`$newsSay] con [`$conAsk] [`$conNone] [`$conStale] `$answerSay" -replace '\|', '/'), `$trayOk
"@
$raOut = Invoke-Sta 'reset-ask-test' $raWpf
$ra = "$raOut" -split '\|'
$raSay = if ($ra.Count -ge 13) { "$($ra[11]) | $($ra[12])" } else { "$raOut" }
Check 'the usage line: " resets HH:mm" after 5h''s percent, dim - a clock that goes once the time has passed' ($ra[0] -eq 'True') $raSay
Check 'a week at its limit: its reset shown, not 5h''s, in the limit''s colour' ($ra.Count -gt 1 -and $ra[1] -eq 'True') $raSay
Check 'the banner: last in the header after the notes, in place of the ask''s note - tagged for the chip, its titles and those left as its tooltip, no row counted' ($ra.Count -gt 2 -and $ra[2] -eq 'True') $raSay
Check 'collapsed: "N can continue" counted apart, and when 5h resets' ($ra.Count -gt 3 -and $ra[3] -eq 'True') $raSay
Check 'the chip on the banner: continue N and leave them, each its own tip' ($ra.Count -gt 4 -and $ra[4] -eq 'True') $raSay
Check 'the chip on a Claude row: open and delete, open still the text that says opening; delete greyed on a chat at work' ($ra.Count -gt 5 -and $ra[5] -eq 'True') $raSay
Check 'the settings box''s seventh row: Cut off, Ask or Leave, the one in force filled; Leave saves off at config.json''s top level, and a fresh look follows' ($ra.Count -gt 6 -and $ra[6] -eq 'True') $raSay
Check 'balloons go through Show-ChatOverlayBalloon: cut to 250, what a click means kept' ($ra.Count -gt 7 -and $ra[7] -eq 'True') $raSay
Check 'a new ask is ballooned once - title, count, three titles and the rest counted - then what an answer did' ($ra.Count -gt 8 -and $ra[8] -eq 'True') $raSay
Check 'the console: the Cut off header says the ask while it is pending, with Leave them beside Continue all; an answer to an ask gone stays in the console and says the chats changed' ($ra.Count -gt 9 -and $ra[9] -eq 'True') $raSay
Check 'an answer held through a drag runs once it ends: a continue queued, marked, the watcher followed, said in a balloon; one about an ask gone does nothing' ($ra.Count -gt 10 -and $ra[10] -eq 'True') $raSay
Check 'the panel''s script ran without an error' ($ra.Count -gt 11 -and -not $ra[11]) $raSay
Check 'the tray''s Continue N and Leave them: there while an ask is out, gone once it is answered - never left behind by a closed menu' ($ra.Count -gt 13 -and $ra[13] -eq 'True') $raSay

# --- put it all back ------------------------------------------------------------------
foreach ($j in @(Get-ChatqJobs | Where-Object { [string]$_.id -notin $raJobsBefore })) { $null = Remove-ChatqJob $j 'test' }
foreach ($p in $raPaths) { Remove-Item -LiteralPath $p -Force -EA SilentlyContinue }
Remove-Item -LiteralPath $script:ChatqAutoDir -Recurse -Force -EA SilentlyContinue
Remove-Item -LiteralPath $sessDir -Recurse -Force -EA SilentlyContinue
Remove-Item -Path (Join-Path $script:ChatqOutboxDir '*') -Force -EA SilentlyContinue
foreach ($p in $script:ChatOverlayCmdPath, $script:ChatOverlayPath, $script:ChatqWakePath) { Remove-Item -LiteralPath $p -Force -EA SilentlyContinue }
Restore-TestFile $script:ChatqConfigPath $raCfgWas
$script:ChatOverlayUsageSeam = $raWas.Usage
$script:ChatqAliveSeam = $raWas.Alive
$script:ChatqSpawn = $raWas.Spawn
$script:ChatqLiveSendSeam = $raWas.Send
$script:ChatqIdleSeam = $raWas.Idle
