# tests/sections/phone-extras.ps1: dot-sourced by tests/run-tests.ps1 in its turn,
# never on its own - it uses what the runner and the sections before it set.
#
# The phone's four smaller features (src/phone-extras.ps1,
# docs/phone-extras-spec.md): usage heads-ups and Send now, quiet hours and
# their summary, the line Join reads aloud, and the setup window's controls
# for them. The page's text= prefill is tests/reply-page-check.js's. Join
# pushes land in a seam of this section's, the clock quiet hours read is
# moved by $script:ChatqClockSeam, and nothing reaches a network or a real
# watcher. Everything changed is put back at the end.

Section 'phone extras'
$xCfgWas = if (Test-Path -LiteralPath $script:ChatqConfigPath) { [System.IO.File]::ReadAllText($script:ChatqConfigPath, $utf8) } else { $null }
$xWas = @{ Join = $script:ChatqJoinSeam; Idle = $script:ChatqIdleSeam; Send = $script:ChatqLiveSendSeam; Spawn = $script:ChatqSpawn; Poll = $script:ChatqReplyPollSeam
    Jobs = ${function:Get-ChatqJobs}; Probe = ${function:Invoke-ChatqProbe}; Summary = ${function:Send-ChatqHeldSummary}; Fg = $script:ChatqForeground }
$script:ChatqIdleSeam = 99999
$script:ChatqForeground = $false
$script:ChatqSpawn = { $true }
$script:XJoins = [System.Collections.Generic.List[string]]::new()
$script:XJoinErr = $null
$script:ChatqJoinSeam = { param($u) $script:XJoins.Add($u); $script:XJoinErr }
$script:XSent = [System.Collections.Generic.List[object]]::new()
$script:ChatqLiveSendSeam = { param($a) $script:XSent.Add($a) }
$xQuery = {
    # one Join push: its query, and its link's fragment, as hashtables
    param([string]$u)
    $q = @{}
    foreach ($p in ($u.Substring($u.IndexOf('?') + 1) -split '&')) { $k, $v = $p -split '=', 2; $q[$k] = [uri]::UnescapeDataString($v) }
    $f = @{}
    if ($q['url']) { foreach ($p in ($q['url'].Substring($q['url'].IndexOf('#') + 1) -split '&')) { $k, $v = $p -split '=', 2; $f[$k] = [uri]::UnescapeDataString($v) } }
    [pscustomobject]@{ Url = $u; Q = $q; F = $f }
}
$xLast = { if ($script:XJoins.Count) { & $xQuery $script:XJoins[$script:XJoins.Count - 1] } else { [pscustomobject]@{ Url = ''; Q = @{}; F = @{} } } }
$xClean = {
    foreach ($p in $script:ChatqUsageAlertPath, $script:ChatqHeldPath, $script:ChatqReplyPath, $script:ChatqWakePath) { Remove-Item -LiteralPath $p -Force -EA SilentlyContinue }
    Remove-Item -Path (Join-Path $script:ChatqData 'held-*.sending') -Force -EA SilentlyContinue
}
& $xClean
$script:ChatqUsageSent = @{}; $script:ChatqPhoneWakeAt = $null; $script:ChatqSummaryTriedAt = $null; $script:ChatqClockSeam = $null
# Join set up, and a phone paired as the page would have it: a key in
# config.json and replies on, so alerts carry links
$null = Set-ChatqNotifyConfig @{ ApiKey = '0123456789abcdef0123456789abcdef'; Device = 'group.phone'; Events = 'all' }
$xD = New-ChatqRandomBytes 32
$xc = Get-ChatqConfig
Set-ChatqProp $xc 'reply' ([pscustomobject]@{ on = $true; topic = [pscustomobject](Protect-ChatqSecret 'chatq-extrastopicextrastopic'); key = [pscustomobject](Protect-ChatqSecret (ConvertTo-ChatqB64Url $xD)) })
Save-ChatqJson $script:ChatqConfigPath $xc
Check 'extras: a phone paired for these checks, and usage is a phone event' ((Get-ChatqReplyConfig).Links -and $script:ChatqPhoneEvents -contains 'usage' -and
    (Test-ChatqPhoneEvent (Get-ChatqConfig) 'summary')) ($script:ChatqPhoneEvents -join ',')

# --- usage heads-ups: the config ------------------------------------------------
$xT = @(
    ((ConvertTo-ChatqUsageThresholds '75,90') -join ','), ((ConvertTo-ChatqUsageThresholds @(90, '75')) -join ','), ((ConvertTo-ChatqUsageThresholds ' 90 ') -join ',')
)
$xTBad = @('0', '100', 'x', '1,2,3,4', '', '9.5', '-5' | Where-Object { $null -ne (ConvertTo-ChatqUsageThresholds $_) })
Check 'usage thresholds: one to three whole percents from 1 to 99, ascending; anything else none' (($xT -join ' ') -eq '75,90 75,90 90' -and -not $xTBad.Count) "$($xT -join ' ') / bad let by: $($xTBad -join ',')"
$xuc = Get-ChatqUsageAlertConfig ([pscustomobject]@{})
$xucBad = Get-ChatqUsageAlertConfig ([pscustomobject]@{ usage = [pscustomobject]@{ alerts = 'yes'; at = @(0, 150); reset = $false; soonMinutes = 'x' } })
Check 'usage config: no block is every default; bad values fall back to theirs' ($xuc.Alerts -and ($xuc.At -join ',') -eq '90' -and $xuc.Reset -and $xuc.SoonMinutes -eq 10 -and
    $xucBad.Alerts -and ($xucBad.At -join ',') -eq '90' -and -not $xucBad.Reset -and $xucBad.SoonMinutes -eq 10) "$($xucBad | ConvertTo-Json -Compress)"
$xr = Set-ChatqNotifyConfig @{ UsageAt = '75,90' }
$xSaved = @((Get-ChatqConfig).usage.at) -join ','
$xBadSaves = foreach ($v in '0', '100', 'x', '75,80,85,90') {
    $was = [System.IO.File]::ReadAllText($script:ChatqConfigPath, $utf8)
    $b = Set-ChatqNotifyConfig @{ UsageAt = $v }
    if (-not $b.Error -or [System.IO.File]::ReadAllText($script:ChatqConfigPath, $utf8) -ne $was -or -not (@($b.Messages | Where-Object { $_.Text -eq 'usage thresholds: up to three whole percents from 1 to 99' }).Count)) { $v }
}
Check 'Set-ChatqNotifyConfig UsageAt: 75,90 saved as [75, 90] and said; 0, 100, x or four values refused with nothing saved' ($xSaved -eq '75,90' -and
    -not $xr.Error -and @($xr.Messages | Where-Object { $_.Text -eq 'usage heads-ups at 75%, 90% of a 5-hour or weekly window' }).Count -and -not @($xBadSaves).Count) "$xSaved / $(@($xBadSaves) -join ',') / $(($xr.Messages | ForEach-Object Text) -join ' | ')"
$xr2 = Set-ChatqNotifyConfig @{ UsageAlerts = 'off'; UsageReset = 'off' }
$xr3 = Set-ChatqNotifyConfig @{ UsageAlerts = 'on'; UsageReset = 'on'; UsageAt = '90' }
Check 'UsageAlerts and UsageReset: off and on again, each said' (@($xr2.Messages | ForEach-Object Text) -contains 'usage heads-ups off' -and @($xr2.Messages | ForEach-Object Text) -contains 'resets: no alerts' -and
    @($xr3.Messages | ForEach-Object Text) -contains 'resets: an alert 10 min before one with prompts queued, and when it happens' -and (Get-ChatqUsageAlertConfig (Get-ChatqConfig)).Alerts) (($xr2.Messages + $xr3.Messages | ForEach-Object Text) -join ' | ')

# --- usage heads-ups: the overlay's thresholds -----------------------------------
$xNow = Get-Date
$xMs = { param([datetime]$d) [DateTimeOffset]::new($d).ToUnixTimeMilliseconds() }
$xReset1 = $xNow.AddHours(2)
$xUse = {
    param([int]$P, [datetime]$Reset, [string]$Label = '5h', [string]$Prov = 'Claude', [double]$AgoMin = 1, [switch]$Stale, [switch]$Limited, [switch]$NoReset)
    , @([pscustomobject]@{ provider = $Prov; source = 'live'; at = (& $xMs $xNow.AddMinutes(-$AgoMin)); stale = [bool]$Stale; status = $null
            windows = @([pscustomobject]@{ label = $Label; percent = $P; resetsAt = $(if ($NoReset) { $null } else { & $xMs $Reset }); severity = 'normal'; limited = [bool]$Limited }) })
}
$xCtx = { @{ ClaudeHome = $claudeHome } }
$xRun = {
    # one overlay pass's threshold look, with a context of its own; the alerts it handed on
    param($Usage, [object[]]$Jobs = @(), $Ctx = $null)
    if (-not $Ctx) { $Ctx = & $xCtx }
    $n0 = $script:XSent.Count
    Update-ChatqUsageAlerts $Ctx $Usage $Jobs $xNow
    , @($script:XSent | Select-Object -Skip $n0)
}
$u89 = & $xRun (& $xUse 89 $xReset1)
$u90 = & $xRun (& $xUse 90 $xReset1) @([pscustomobject]@{ state = 'queued'; provider = 'claude' }, [pscustomobject]@{ state = 'queued'; provider = 'codex' })
$u91 = & $xRun (& $xUse 91 $xReset1)
$xWant = "Claude 5h at 90% $([char]0xB7) resets $(Format-ChatqClockTime $xReset1 $xNow) $([char]0xB7) 1 queued"
Check 'usage heads-up: 89% nothing; 90% one usage alert - kind threshold, priority 0, reset time, and the queue for that provider; 91% nothing more' ($u89.Count -eq 0 -and
    $u90.Count -eq 1 -and $u90[0].event -eq 'usage' -and $u90[0].kind -eq 'threshold' -and $u90[0].priority -eq 0 -and $u90[0].text -eq $xWant -and -not $u90[0].sessionId -and
    $u91.Count -eq 0) "$($u89.Count)/$($u90.Count)/$($u91.Count): $($u90[0].text) vs $xWant"
$null = Set-ChatqNotifyConfig @{ UsageAt = '75, 90' }
$xReset2 = $xNow.AddHours(3)
$u95 = & $xRun (& $xUse 95 $xReset2)
$xKeys = @((Get-ChatqUsageAlertState).Keys | Where-Object { $_ -like "t|Claude|*|5h|*|$(Get-ChatqEpochMinutes $xReset2)" } | Sort-Object)
Check 'two thresholds crossed at once: one alert saying 95%, and both recorded' ($u95.Count -eq 1 -and $u95[0].text -like 'Claude 5h at 95%*' -and $xKeys.Count -eq 2) "$($u95.Count) / $($xKeys -join ' ')"
$uNew = & $xRun (& $xUse 90 $xNow.AddHours(4))
Check 'a new window (a new resetsAt) at 90%: one more' ($uNew.Count -eq 1) "$($uNew.Count)"
$xNone = @(
    (& $xRun (& $xUse 96 $xNow.AddHours(5) -Stale)).Count
    (& $xRun (& $xUse 96 $xNow.AddHours(5) -AgoMin 31)).Count
    (& $xRun (& $xUse 96 $xNow.AddHours(5) -Limited)).Count
    (& $xRun (& $xUse 100 $xNow.AddHours(5))).Count
    (& $xRun (& $xUse 96 $xNow.AddHours(5) -Prov 'Copilot' -Label 'premium')).Count
    (& $xRun (& $xUse 96 $xNow.AddHours(5) -Label 'month')).Count
)
Check 'no heads-up for a stale figure, one 31 minutes old, a limited window, 100%, Copilot or a month' (($xNone -join ',') -eq '0,0,0,0,0,0') ($xNone -join ',')
$uWeek = & $xRun (& $xUse 91 $xNow.AddDays(3) -Label 'Fable week' -Prov 'Codex')
$uX = & $xRun (& $xUse 92 $xNow -NoReset -Label 'week')
$uX2 = & $xRun (& $xUse 93 $xNow -NoReset -Label 'week')
Check 'one model''s week and Codex count; a window with no reset time goes once' ($uWeek.Count -eq 1 -and $uWeek[0].text -like 'Codex Fable week at 91%*' -and
    $uX.Count -eq 1 -and $uX[0].text -eq 'Claude week at 92%' -and $uX2.Count -eq 0) "$($uWeek.Count) $($uX.Count) $($uX2.Count) $($uX[0].text)"
$null = Set-ChatqNotifyConfig @{ UsageAlerts = 'off' }
New-ChatqDir $script:ChatqData
$xLk = [System.IO.File]::Open($script:ChatqUsageAlertLockPath, 'OpenOrCreate', 'ReadWrite', 'None')
try { $t0 = Get-Date; $uOff = & $xRun (& $xUse 97 $xNow.AddHours(6)); $tOff = ((Get-Date) - $t0).TotalSeconds }
finally { $xLk.Dispose() }
$null = Set-ChatqNotifyConfig @{ UsageAlerts = 'on' }
Check 'usage.alerts off: nothing, and the lock is not even asked for' ($uOff.Count -eq 0 -and $tOff -lt 2) "$($uOff.Count) in $tOff s"
$xc2 = & $xCtx
$null = & $xRun (& $xUse 97 $xNow.AddHours(7)) @() $xc2
$xLk = [System.IO.File]::Open($script:ChatqUsageAlertLockPath, 'OpenOrCreate', 'ReadWrite', 'None')
try { $t0 = Get-Date; $uMem = & $xRun (& $xUse 97 $xNow.AddHours(7)) @() $xc2; $tMem = ((Get-Date) - $t0).TotalSeconds }
finally { $xLk.Dispose() }
Check 'a figure that stays over its threshold does not take the lock again on the next pass' ($uMem.Count -eq 0 -and $tMem -lt 2) "$($uMem.Count) in $tMem s"

# --- the dedup file ---------------------------------------------------------------
$xLk = [System.IO.File]::Open($script:ChatqUsageAlertLockPath, 'OpenOrCreate', 'ReadWrite', 'None')
try { $threw = try { $null = Use-ChatqUsageAlertState { param($st) $st['k'] = 'x' }; $false } catch { $_.Exception.Message -like '*usage-alerts.lock is held*' } }
finally { $xLk.Dispose() }
$xOldReset = Get-ChatqEpochMinutes $xNow.AddDays(-2)
$xFreshReset = Get-ChatqEpochMinutes $xNow.AddHours(1)
$xSt = [ordered]@{
    "t|Claude||5h|90|$xOldReset" = $xNow.AddDays(-2).ToUniversalTime().ToString('o')
    't|Claude||5h|90|x' = $xNow.AddHours(-6).ToUniversalTime().ToString('o')
    't|Claude||week|90|x' = $xNow.AddHours(-6).ToUniversalTime().ToString('o')
    "s|claude|$xFreshReset" = $xNow.ToUniversalTime().ToString('o')
}
Save-ChatqJson $script:ChatqUsageAlertPath $xSt
$null = Use-ChatqUsageAlertState { param($st) } $xNow
$xAfter = Get-ChatqUsageAlertState
$xMany = [ordered]@{}
for ($i = 0; $i -lt 250; $i++) { $xMany["s|lane$i|$xFreshReset"] = $xNow.AddMinutes(-250 + $i).ToUniversalTime().ToString('o') }
Save-ChatqJson $script:ChatqUsageAlertPath $xMany
$null = Use-ChatqUsageAlertState { param($st) } $xNow
$xAfterMany = Get-ChatqUsageAlertState
Check 'the dedup file: a held lock throws; a reset a day gone and a 5h key with no reset 6 h old are pruned, a week one kept; 250 keys -> the newest 200' ($threw -and
    -not $xAfter.ContainsKey("t|Claude||5h|90|$xOldReset") -and -not $xAfter.ContainsKey('t|Claude||5h|90|x') -and $xAfter.ContainsKey('t|Claude||week|90|x') -and
    $xAfter.ContainsKey("s|claude|$xFreshReset") -and $xAfterMany.Count -eq 200 -and -not $xAfterMany.ContainsKey("s|lane0|$xFreshReset") -and $xAfterMany.ContainsKey("s|lane249|$xFreshReset")) "threw $threw, $(@($xAfter.Keys) -join ' '), $($xAfterMany.Count)"
Remove-Item -LiteralPath $script:ChatqUsageAlertPath -Force -EA SilentlyContinue

# --- the watcher: soon, and reset -------------------------------------------------
$xBlock = { param([double]$UntilMin, [double]$SinceMin, [string]$Type = 'five_hour') [pscustomobject]@{ Until = $xNow.AddMinutes($UntilMin); Type = $Type; Source = 'run'; At = $xNow.AddMinutes(-$SinceMin) } }
$xQ = { param([int]$N, [string]$Prov = 'claude') , @(1..$N | ForEach-Object { [pscustomobject]@{ id = "xq$_"; seq = 40 + $_; state = 'queued'; provider = $Prov; home = $null; notBefore = $null } }) }
$xSoon = {
    param($Block, [object[]]$Queued)
    $W = New-ChatqWatchState
    $W.blocked['claude'] = $Block
    $n0 = $script:XJoins.Count
    $next = Send-ChatqUsageSoon $W $Queued $xNow
    [pscustomobject]@{ Next = $next; Joins = @($script:XJoins | Select-Object -Skip $n0) }
}
$s1 = & $xSoon (& $xBlock 9 120) (& $xQ 2)
$s1j = if ($s1.Joins.Count) { & $xQuery $s1.Joins[0] } else { $null }
$s1e = if ($s1j) { (Get-ChatqReplyState).alerts[$s1j.F['a']] } else { $null }
Check 'soon: a lane blocked 2 h, the reset 9 min off, 2 queued - one usage alert, jobless with w=1, and the registry says soon' ($s1.Joins.Count -eq 1 -and
    $s1j.Q['title'] -eq "chatq $([char]0xB7) usage" -and $s1j.Q['text'] -eq "Claude resets $(Format-ChatqClockTime $xNow.AddMinutes(9) $xNow) $([char]0xB7) 2 queued $([char]0xB7) they go then" -and
    $s1j.F['x'] -eq '1' -and $s1j.F['w'] -eq '1' -and $s1j.F['e'] -eq 'usage' -and $s1e -and $s1e['usage'] -eq 'soon' -and $s1j.Q['priority'] -eq '0') "$($s1.Joins.Count) $($s1j.Url)"
$xSoonAid = if ($s1j) { $s1j.F['a'] } else { $null }
$s2 = & $xSoon (& $xBlock 9 120) (& $xQ 2)
$s3 = & $xSoon (& $xBlock 8 20) (& $xQ 2)
$s4 = & $xSoon (& $xBlock 8 7) (& $xQ 2)
$s5 = & $xSoon (& $xBlock 8.5 120) @()
$s6 = & $xSoon (& $xBlock 8.4 120 'probe failed') (& $xQ 2)
$xHeld = & $xQ 1; $xHeld[0].notBefore = $xNow.AddHours(1).ToUniversalTime().ToString('o')
$s7 = & $xSoon (& $xBlock 8.3 120) $xHeld
Check 'no soon alert twice for one reset, nor for a wait of 20 min, the 15-min guess, nothing queued, a failed probe, or a job held past the reset by its own -At' (
    $s2.Joins.Count + $s3.Joins.Count + $s4.Joins.Count + $s5.Joins.Count + $s6.Joins.Count + $s7.Joins.Count -eq 0) "$($s2.Joins.Count)$($s3.Joins.Count)$($s4.Joins.Count)$($s5.Joins.Count)$($s6.Joins.Count)$($s7.Joins.Count)"
$s8 = & $xSoon (& $xBlock 60 180) (& $xQ 1)
Check 'a reset an hour off: nothing yet, and the loop is told to wake 10 min before it' ($s8.Joins.Count -eq 0 -and $s8.Next -and [Math]::Abs(($s8.Next - $xNow.AddMinutes(50)).TotalSeconds) -lt 1) "$($s8.Next)"
$null = Set-ChatqNotifyConfig @{ UsageReset = 'off' }
$s9 = & $xSoon (& $xBlock 7 120) (& $xQ 2)
$null = Set-ChatqNotifyConfig @{ UsageReset = 'on' }
Check 'usage.reset off: no soon alert' ($s9.Joins.Count -eq 0)
# a block's start survives a watcher handing over
$Wh = New-ChatqWatchState
$Wh.blocked['claude'] = & $xBlock 90 120
$Wh.handoff = $true
$xStateWas = if (Test-Path -LiteralPath $script:ChatqStatePath) { [System.IO.File]::ReadAllText($script:ChatqStatePath, $utf8) } else { $null }
Save-ChatqWatchState $Wh
$Wr = New-ChatqWatchState
$null = Restore-ChatqWatchState $Wr
if ($null -ne $xStateWas) { [System.IO.File]::WriteAllText($script:ChatqStatePath, $xStateWas, $utf8) } else { Remove-Item -LiteralPath $script:ChatqStatePath -Force -EA SilentlyContinue }
Check 'when a lane was blocked is saved and restored with the block' ($Wr.blocked['claude'] -and $Wr.blocked['claude'].At -and
    [Math]::Abs(($Wr.blocked['claude'].At - $xNow.AddMinutes(-120)).TotalSeconds) -lt 2) "$($Wr.blocked['claude'] | ConvertTo-Json -Compress)"

$script:XJobs = @()
${function:Get-ChatqJobs} = { $script:XJobs }
try {
    $xJob = [pscustomobject]@{ id = 'xq1'; seq = 12; state = 'queued'; provider = 'claude'; home = $null }
    $script:XJobs = & $xQ 3
    $n0 = $script:XJoins.Count
    $r1 = Send-ChatqUsageReset $null $xJob (& $xBlock -1 200) $xNow
    $rj = & $xLast
    $r2 = Send-ChatqUsageReset $null $xJob (& $xBlock -1 200) $xNow
    $script:XJobs = & $xQ 1
    $r3 = Send-ChatqUsageReset $null $xJob (& $xBlock -2 200) $xNow
    $script:XJobs = & $xQ 3
    $r4 = Send-ChatqUsageReset $null $xJob (& $xBlock -3 200 'probe failed') $xNow
    $r5 = Send-ChatqUsageReset $null $xJob $null $xNow
    Check 'reset: a five_hour limit gone with 3 queued - one alert, priority 1, jobless, no Send now; the same reset again, 1 queued, a failed probe or no block: none' ($r1 -and
        -not $r2 -and -not $r3 -and -not $r4 -and -not $r5 -and $script:XJoins.Count -eq $n0 + 1 -and
        $rj.Q['text'] -eq "Claude limit reset $([char]0xB7) 3 queued $([char]0xB7) sending #12 now" -and $rj.Q['priority'] -eq '1' -and $rj.F['x'] -eq '1' -and -not $rj.F.ContainsKey('w')) "$r1 $r2 $r3 $r4 $r5 $($rj.Url)"
    # through Confirm-ChatqAllowed: the probe says allowed over a limit
    ${function:Invoke-ChatqProbe} = { param($p, $j) [pscustomobject]@{ Allowed = $true; Limited = $false; Overloaded = $false; Auth = $false; Error = $null } }
    $Wc = New-ChatqWatchState
    $Wc.blocked['claude'] = & $xBlock -5 200
    $n0 = $script:XJoins.Count
    $ok = Confirm-ChatqAllowed $Wc $xJob
    $cj = & $xLast
    Check 'Confirm-ChatqAllowed over a limit that reset: allowed, and the reset alert goes before the job runs' ($ok -and -not $Wc.blocked['claude'] -and
        $script:XJoins.Count -eq $n0 + 1 -and $cj.Q['text'] -like 'Claude limit reset*sending #12 now') "$ok $($cj.Q['text'])"
}
finally { ${function:Get-ChatqJobs} = $xWas.Jobs; ${function:Invoke-ChatqProbe} = $xWas.Probe }

# --- Send now ----------------------------------------------------------------------
Remove-Item -LiteralPath $script:ChatqWakePath -Force -EA SilentlyContinue
${function:Get-ChatqJobs} = { $script:XJobs }
try {
    $script:XJobs = & $xQ 3
    $script:ChatqPhoneWakeAt = $null
    $xRc = Get-ChatqReplyConfig
    $xWake = { param($Entry) (Invoke-ChatqReply ([pscustomobject]@{ v = 1; act = 'wake'; text = ''; nonce = 'n'; ts = 1 }) $Entry 'aaaaaaaaaa' -Rc $xRc).Feedback }
    $w1 = & $xWake @{ event = 'usage'; usage = 'soon' }
    $wakeFile = if (Test-Path -LiteralPath $script:ChatqWakePath) { (Get-Content -LiteralPath $script:ChatqWakePath -Raw).Trim() } else { '' }
    $w2 = & $xWake @{ event = 'usage'; usage = 'soon' }
    $script:ChatqPhoneWakeAt = (Get-Date).AddMinutes(-3)
    $script:XJobs = @()
    $w3 = & $xWake @{ event = 'usage'; usage = 'soon' }
    $w4 = & $xWake @{ event = 'usage'; usage = 'threshold' }
    $w5 = & $xWake @{ event = 'done'; jobId = 'xq1'; seq = 1 }
    Check 'Send now on a soon alert: the wake file says now, and the answer says a probe goes first' ($wakeFile -eq 'now' -and
        $w1 -eq 'trying the queue now - 3 queued; a probe goes first, so nothing is sent while the limit still holds') "$wakeFile / $w1"
    Check 'Send now twice in 2 min: the second only says the first is under way; nothing queued: says so' ($w2 -eq 'asked 1 min ago - the watcher is on it' -and
        $w3 -eq 'nothing queued - nothing to send') "$w2 / $w3"
    Check 'Send now on a threshold alert, or a done one: refused' ($w4 -eq 'Send now is for a usage alert about a reset - nothing done' -and $w5 -eq $w4) "$w4 / $w5"
    # the whole way: the soon alert's own link, a sealed wake from the page
    $script:ChatqPhoneWakeAt = $null
    $script:XJobs = & $xQ 2
    Remove-Item -LiteralPath $script:ChatqWakePath -Force -EA SilentlyContinue
    $script:ChatqReplySeen = @{}; $script:ChatqReplyHandled = @{}
    $xm = Protect-ChatqReplyMessage -Key (ConvertTo-ChatqB64Url $xD) -Aid $xSoonAid -Act wake
    $script:ChatqReplyPollSeam = { param($u) ([ordered]@{ id = 'xwake1'; time = 1; event = 'message'; topic = 't'; message = $script:XWakeMsg } | ConvertTo-Json -Compress) }
    $script:XWakeMsg = $xm
    $n0 = $script:XJoins.Count
    $acted = Invoke-ChatqReplyPoll -Force
    $wj = & $xLast
    $wakeFile2 = if (Test-Path -LiteralPath $script:ChatqWakePath) { (Get-Content -LiteralPath $script:ChatqWakePath -Raw).Trim() } else { '' }
    Check 'a sealed wake answering the soon alert: the watcher is woken and the phone told, the reply push about no chat' ($acted -eq 1 -and $wakeFile2 -eq 'now' -and
        $wj.Q['title'] -eq "chatq $([char]0xB7) reply" -and $wj.Q['text'] -like 'trying the queue now - 2 queued*' -and $wj.F['x'] -eq '1') "$acted $wakeFile2 $($wj.Q['text'])"
}
finally { ${function:Get-ChatqJobs} = $xWas.Jobs; $script:ChatqReplyPollSeam = $xWas.Poll; Remove-Item -LiteralPath $script:ChatqWakePath -Force -EA SilentlyContinue }
# a threshold heads-up out of the outbox: jobless, no Send now, the registry says threshold
$xOb = Join-Path $script:ChatqOutboxDir 'xusage.json'
New-ChatqDir $script:ChatqOutboxDir
Save-ChatqJson $xOb ([ordered]@{ v = 1; at = (Get-ChatqStamp); event = 'usage'; text = 'Claude 5h at 90%'; priority = 0; sessionId = ''; title = ''; cwd = ''; path = ''; home = $null; kind = 'threshold' })
$n0 = $script:XJoins.Count
$null = Send-ChatqOutboxFile $xOb
$oj = & $xLast
$oe = (Get-ChatqReplyState).alerts[$oj.F['a']]
Check 'a threshold heads-up from the outbox: a usage push, jobless (x=1), no w, the registry entry says threshold' ($script:XJoins.Count -eq $n0 + 1 -and
    $oj.Q['title'] -eq "chatq $([char]0xB7) usage" -and $oj.F['x'] -eq '1' -and -not $oj.F.ContainsKey('w') -and $oe -and $oe['usage'] -eq 'threshold' -and -not $oe['live']) $oj.Url

# --- quiet hours ----------------------------------------------------------------------
$xDay = (Get-Date).Date
$xQh = { param($f, $t) Get-ChatqQuietHours ([pscustomobject]@{ quietHours = [pscustomobject]@{ from = $f; to = $t } }) }
$qo = & $xQh '23:00' '07:00'
$xIn = @(foreach ($h in '22:59', '23:00', '03:00', '06:59', '07:00') { (Test-ChatqQuietNow $qo $xDay.Add([TimeSpan]::Parse($h))).In })
$u2300 = (Test-ChatqQuietNow $qo $xDay.AddHours(23)).Until
$u0300 = (Test-ChatqQuietNow $qo $xDay.AddHours(3)).Until
$qd = & $xQh '09:00' '12:00'
$xInD = @(foreach ($h in '08:59', '09:00', '11:59', '12:00') { (Test-ChatqQuietNow $qd $xDay.Add([TimeSpan]::Parse($h))).In })
Check 'quiet now: 23:00-07:00 in at 23:00, 03:00, 06:59, out at 22:59 and 07:00, until the right 07:00 either side of midnight; 09:00-12:00 the same by day' (
    ($xIn -join ',') -eq 'False,True,True,True,False' -and $u2300 -eq $xDay.AddDays(1).AddHours(7) -and $u0300 -eq $xDay.AddHours(7) -and
    ($xInD -join ',') -eq 'False,True,True,False' -and $qo.Text -eq '23:00-07:00' -and ($qo.Urgent -join ',') -eq 'failed') "$($xIn -join ',') / $u2300 / $u0300 / $($xInD -join ',')"
$xOff = @((& $xQh '07:00' '07:00'), (& $xQh '7' '9'), (& $xQh '25:00' '01:00'), (Get-ChatqQuietHours ([pscustomobject]@{})), (Get-ChatqQuietHours ([pscustomobject]@{ quietHours = [pscustomobject]@{ from = '00:00' } })))
$xNoUrgent = Get-ChatqQuietHours ([pscustomobject]@{ quietHours = [pscustomobject]@{ from = '00:00'; to = '07:00'; urgent = @() } })
Check 'quiet hours read as off for 07:00-07:00, 7-9, 25:00, none, or half a window - never a crash; urgent [] is none' (-not @($xOff | Where-Object { $_ }).Count -and
    $xNoUrgent -and @($xNoUrgent.Urgent).Count -eq 0) "$(@($xOff | Where-Object { $_ }).Count)"
$qBad = foreach ($v in '7-9', '24:00-07:00', '07:00-07:00', 'night') {
    $was = [System.IO.File]::ReadAllText($script:ChatqConfigPath, $utf8)
    $b = Set-ChatqNotifyConfig @{ QuietHours = $v }
    if (-not $b.Error -or [System.IO.File]::ReadAllText($script:ChatqConfigPath, $utf8) -ne $was) { $v }
}
$qBadMsg = @((Set-ChatqNotifyConfig @{ QuietHours = '07:00-07:00' }).Messages | ForEach-Object Text) + @((Set-ChatqNotifyConfig @{ Urgent = 'bogus' }).Messages | ForEach-Object Text)
$qr = Set-ChatqNotifyConfig @{ QuietHours = '0:00-07:00' }
$qc = (Get-ChatqConfig).quietHours
Check 'Set-ChatqNotifyConfig QuietHours: bad values refused with nothing saved, and said; 0:00-07:00 saved as 00:00-07:00, and said' (-not @($qBad).Count -and
    $qBadMsg -contains 'quiet hours: from and to cannot be the same time' -and ($qBadMsg -join '|') -like "*no event 'bogus' - these are: none, *" -and
    $qc.from -eq '00:00' -and $qc.to -eq '07:00' -and
    @($qr.Messages | ForEach-Object Text) -contains "quiet hours 00:00-07:00 (this PC's clock) $([char]0xB7) failed still comes through $([char]0xB7) the rest in one summary at 07:00") "$(@($qBad) -join ',') / $($qBadMsg -join ' | ') / $(($qr.Messages | ForEach-Object Text) -join ' | ')"

$xHook = Join-Path $sb 'quiet-hook.txt'
$null = Set-ChatqNotifyConfig @{ Command = "Set-Content -LiteralPath '$xHook' -Value `$env:CHATQ_QUIET" }
$script:ChatqClockSeam = $xDay.AddHours(12)
$null = Send-ChatqAlert 'test' 'noon' 0 -Loud
$qOut = if (Test-Path -LiteralPath $xHook) { (Get-Content -LiteralPath $xHook -Raw).Trim() } else { '' }
$null = Set-ChatqNotifyConfig @{ Command = '' }
$script:ChatqClockSeam = $xDay.AddHours(3)
$xJobP = [pscustomobject]@{ id = 'xp'; seq = 14; sessionId = $null; provider = 'claude'; title = 'Parser rewrite'; state = 'done' }
$n0 = $script:XJoins.Count
$a0 = @((Get-ChatqReplyState).alerts.Keys).Count
$hDone = Send-ChatqAlert 'done' "Parser rewrite $([char]0xB7) 3m $([char]0xB7) finished" 1 -Job $xJobP
$hRep = @($script:ChatqAlertReport) -join ' | '
$hErr = $script:ChatqLastAlertError
$hLines = @(Get-ChatqHeldItems $script:ChatqHeldPath)
Check 'quiet hours, 03:00: a done is held - no push, one line in held.jsonl, $false, and why - and no reply alert registered' (-not $hDone -and $script:XJoins.Count -eq $n0 -and
    $hLines.Count -eq 1 -and $hLines[0].event -eq 'done' -and $hLines[0].seq -eq 14 -and $hLines[0].title -eq 'Parser rewrite' -and
    $hRep -like '*phone: held - quiet hours until 07:00*' -and $hErr -eq 'quiet hours - held until 07:00' -and @((Get-ChatqReplyState).alerts.Keys).Count -eq $a0) "$hDone $hRep / $hErr / $($hLines.Count)"
$hFail = Send-ChatqAlert 'failed' 'Parser rewrite - boom' 2 -Job $xJobP
$hTest = Send-ChatqAlert 'test' 'a test' 1 -Loud
$script:ChatqIdleSeam = 10
$t0 = $script:Toasts.Count
$hHere = Send-ChatqAlert 'done' 'at the desk' 1
$tHere = $script:Toasts.Count - $t0
$script:ChatqIdleSeam = 99999
$null = Set-ChatqNotifyConfig @{ Events = 'done, failed' }
$hNot = Send-ChatqAlert 'started' 'not a phone event' 0
$null = Set-ChatqNotifyConfig @{ Events = 'all' }
Check 'quiet hours: failed (urgent) and a -Loud test go; at the PC the toast alone; an event the phone never gets - none held for any' ($hFail -and $hTest -and
    -not $hHere -and $tHere -eq 1 -and -not $hNot -and @(Get-ChatqHeldItems $script:ChatqHeldPath).Count -eq 1 -and
    $script:XJoins.Count -eq $n0 + 2) "$hFail $hTest $hHere $hNot held $(@(Get-ChatqHeldItems $script:ChatqHeldPath).Count) joins $($script:XJoins.Count - $n0)"
$null = Set-ChatqNotifyConfig @{ Command = "Set-Content -LiteralPath '$xHook' -Value `$env:CHATQ_QUIET" }
$null = Send-ChatqAlert 'waiting' 'busy' 0
$qIn = if (Test-Path -LiteralPath $xHook) { (Get-Content -LiteralPath $xHook -Raw).Trim() } else { '' }
$null = Set-ChatqNotifyConfig @{ Command = '' }
Check 'your command runs in quiet hours all the same, told CHATQ_QUIET=1 - and 0 outside them' ($qIn -eq '1' -and $qOut -eq '0') "$qIn / $qOut"

# the summary: at 07:01 the next alert sends it first
$script:ChatqClockSeam = $xDay.AddHours(7).AddMinutes(1)
$held0 = @(Get-ChatqHeldItems $script:ChatqHeldPath).Count
$n0 = $script:XJoins.Count
$sAfter = Send-ChatqAlert 'done' 'after the night' 1
$sj = @($script:XJoins | Select-Object -Skip $n0 | ForEach-Object { & $xQuery $_ })
Check 'after quiet hours the next alert sends the summary first - held 00:00-07:00: 1 done, 1 waiting, one line each - then itself; the file is gone' ($held0 -eq 2 -and $sAfter -and
    $sj.Count -eq 2 -and $sj[0].Q['title'] -eq "chatq $([char]0xB7) summary" -and $sj[0].Q['text'] -like 'held 00:00-07:00: 1 done, 1 waiting*' -and
    $sj[0].Q['text'] -like "*03:00 done $([char]0xB7) #14 Parser rewrite*" -and $sj[0].Q['priority'] -eq '1' -and $sj[0].F['x'] -eq '1' -and
    $sj[1].Q['title'] -eq "chatq $([char]0xB7) done" -and -not (Test-Path -LiteralPath $script:ChatqHeldPath) -and
    -not @(Get-ChildItem -LiteralPath $script:ChatqData -Filter 'held-*.sending' -File).Count) "$held0 $($sj.Count) $(@($sj | ForEach-Object { $_.Q['title'] + ': ' + $_.Q['text'] }) -join ' || ')"
# 210 held: 200 kept, a summary of 700 characters at most, the rest counted
$script:ChatqClockSeam = $xDay.AddHours(3)
for ($i = 0; $i -lt 210; $i++) { $null = Add-ChatqHeldAlert 'done' "chat number $i finished a long piece of work and said a good deal about it" 1 $null $xDay.AddHours(7) }
$manyItems = @(Get-ChatqHeldItems $script:ChatqHeldPath)
$script:ChatqClockSeam = $xDay.AddHours(8)
$mt = Get-ChatqHeldSummaryText $manyItems (Get-ChatqQuietHours (Get-ChatqConfig)) $xDay.AddHours(8)
$mOld = Get-ChatqHeldSummaryText @([pscustomobject]@{ at = $xDay.AddDays(-2).ToUniversalTime().ToString('o'); event = 'done'; text = 'old'; seq = $null }) $null $xDay.AddHours(8)
$n0 = $script:XJoins.Count
$sOk = Send-ChatqHeldSummary
$mj = & $xLast
Check 'held: 200 kept of 210; the summary 700 characters at most, whole lines, and "and N more" - sent as one push' ($manyItems.Count -eq 200 -and $sOk -and $script:XJoins.Count -eq $n0 + 1 -and
    $mt.Length -le 700 -and $mt -like 'held 00:00-07:00: 200 done*' -and $mt -match "$([char]0x2026) and \d+ more \(data/logs/alerts\.log\)$" -and
    $mj.Q['title'] -eq "chatq $([char]0xB7) summary" -and $mj.Q['text'] -like 'held 00:00-07:00: 200 done*' -and -not (Test-Path -LiteralPath $script:ChatqHeldPath)) "$($manyItems.Count) $($mt.Length) $($mt.Substring([Math]::Max(0, $mt.Length - 60)))"
Check 'a held alert over a day old is marked (yesterday); with quiet hours off since, the head says in quiet hours' ($mOld -like "held in quiet hours: 1 done`n* (yesterday) done $([char]0xB7) old") $mOld
# a push that fails: the lines back, and no second try within 5 minutes
$script:ChatqClockSeam = $xDay.AddHours(3)
$null = Add-ChatqHeldAlert 'done' 'one' 1 $null $null
$null = Add-ChatqHeldAlert 'done' 'two' 1 $null $null
$script:ChatqClockSeam = $xDay.AddHours(8)
$script:XJoinErr = 'join is down'
$n0 = $script:XJoins.Count
$fOk = Send-ChatqHeldSummary
$fBack = @(Get-ChatqHeldItems $script:ChatqHeldPath).Count
$fAgain = Send-ChatqHeldSummary
$fCalls = $script:XJoins.Count - $n0
$script:XJoinErr = $null
$fForce = Send-ChatqHeldSummary -Force
Check 'a summary that did not go: its lines back in held.jsonl, not tried again within 5 min, sent once asked again' (-not $fOk -and $fBack -eq 2 -and -not $fAgain -and $fCalls -eq 1 -and
    $fForce -and -not (Test-Path -LiteralPath $script:ChatqHeldPath)) "$fOk $fBack $fAgain $fCalls $fForce"
# a claim a dead sender left: taken back after 10 minutes
$xDead = Join-Path $script:ChatqData 'held-deadsend.sending'
$script:ChatqClockSeam = $xDay.AddHours(3)
$null = Add-ChatqHeldAlert 'done' 'left behind' 1 $null $null
Move-Item -LiteralPath $script:ChatqHeldPath -Destination $xDead
(Get-Item -LiteralPath $xDead).LastWriteTime = (Get-Date).AddMinutes(-11)
$script:ChatqClockSeam = $xDay.AddHours(8)
$n0 = $script:XJoins.Count
$dOk = Send-ChatqHeldSummary -Force
$dj = & $xLast
Check 'a .sending file 11 minutes old - a sender that died - is taken back and sent' ($dOk -and -not (Test-Path -LiteralPath $xDead) -and $dj.Q['text'] -like '*left behind*') "$dOk $($dj.Q['text'])"
# the rename is the claim: a second sender in the middle of the first finds nothing
$script:ChatqClockSeam = $xDay.AddHours(3)
$null = Add-ChatqHeldAlert 'done' 'claimed once' 1 $null $null
$script:ChatqClockSeam = $xDay.AddHours(8)
$script:XInner = $null
$script:ChatqJoinSeam = {
    param($u)
    $script:XJoins.Add($u)
    if ($null -eq $script:XInner) {
        $script:ChatqSendingSummary = $false
        $script:XInner = [pscustomobject]@{ Sent = (Send-ChatqHeldSummary -Force); Held = (Test-Path -LiteralPath $script:ChatqHeldPath) }
        $script:ChatqSendingSummary = $true
    }
    $null
}
$n0 = $script:XJoins.Count
$cOk = Send-ChatqHeldSummary -Force
$script:ChatqJoinSeam = { param($u) $script:XJoins.Add($u); $script:XJoinErr }
Check 'two senders: the second, while the first is sending, finds nothing to claim - one summary' ($cOk -and $script:XInner -and -not $script:XInner.Sent -and -not $script:XInner.Held -and
    $script:XJoins.Count -eq $n0 + 1) "$cOk $($script:XInner | ConvertTo-Json -Compress) $($script:XJoins.Count - $n0)"
# the hold cannot be written (its lock held): the alert is sent instead
$script:ChatqClockSeam = $xDay.AddHours(3)
$xLk = [System.IO.File]::Open($script:ChatqHeldLockPath, 'OpenOrCreate', 'ReadWrite', 'None')
$n0 = $script:XJoins.Count
try { $wOk = Send-ChatqAlert 'done' 'could not hold' 1; $wRep = @($script:ChatqAlertReport) -join ' | ' }
finally { $xLk.Dispose() }
Check 'a hold that cannot be written: the alert is sent, and the report says so' ($wOk -and $script:XJoins.Count -eq $n0 + 1 -and $wRep -like '*phone: could not hold (quiet hours) - sent*') $wRep
# -QuietHours off with alerts held: the summary goes at once, from chatnotify
$null = Add-ChatqHeldAlert 'done' 'held at off' 1 $null $null
$n0 = $script:XJoins.Count
$offSaid = (chatnotify -QuietHours off 6>&1 | Out-String -Width 400)
$oj2 = & $xLast
Check '-QuietHours off with alerts held: saved off, and the summary goes at once' (-not (Get-ChatqConfig).PSObject.Properties['quietHours'] -and $script:XJoins.Count -eq $n0 + 1 -and
    $oj2.Q['title'] -eq "chatq $([char]0xB7) summary" -and $offSaid -like '*quiet hours off*' -and $offSaid -like '*went as one summary*') $offSaid
$ur = Set-ChatqNotifyConfig @{ QuietHours = '00:00-07:00'; Urgent = 'none' }
$ur2 = Set-ChatqNotifyConfig @{ Urgent = @('failed', 'needs-input') }
Check '-Urgent none saves [] (nothing comes through); failed, needs-input saves both' (@((Get-ChatqConfig).quietHours.urgent).Count -eq 2 -and
    @($ur.Messages | ForEach-Object Text) -like '*nothing comes through*' -and (@((Get-ChatqConfig).quietHours.urgent) -join ',') -eq 'failed,needs input') (($ur.Messages + $ur2.Messages | ForEach-Object Text) -join ' | ')
# the watcher's pass and the outbox's sender each look, once, when something is held
$script:XSumCalls = 0
${function:Send-ChatqHeldSummary} = { param([switch]$Force) $script:XSumCalls++; $false }
try {
    $null = Close-ChatqReplyWindow
    Remove-Item -LiteralPath $script:ChatqStopPath -Force -EA SilentlyContinue
    # the threshold checks above left their files there, each an alert of its own
    Remove-Item -Path (Join-Path $script:ChatqOutboxDir '*') -Force -EA SilentlyContinue
    Save-ChatqText $script:ChatqHeldPath '{"at":"2026-01-01T00:00:00Z","event":"done","text":"x"}'
    Invoke-ChatqWatchLoop -Foreground *> $null
    $wA = $script:XSumCalls
    $null = Send-ChatqOutbox
    $wB = $script:XSumCalls
    Remove-Item -LiteralPath $script:ChatqHeldPath -Force
    Invoke-ChatqWatchLoop -Foreground *> $null
    $null = Send-ChatqOutbox
    $wC = $script:XSumCalls
}
finally { ${function:Send-ChatqHeldSummary} = $xWas.Summary; $script:ChatqForeground = $false }
Check 'the watcher''s pass and the outbox''s sender send the summary when something is held, and do not look when nothing is' ($wA -ge 1 -and $wB -eq $wA + 1 -and $wC -eq $wB) "$wA $wB $wC"
# the overlay: once a minute, with the window over and something held, the sender is started
$script:XKicks = 0
$script:ChatqHeldKickSeam = { $script:XKicks++ }
$script:ChatqClockSeam = $xDay.AddHours(8)
Save-ChatqText $script:ChatqHeldPath '{"at":"2026-01-01T00:00:00Z","event":"done","text":"x"}'
$kc = @{ ClaudeHome = $claudeHome }
Update-ChatqHeldKick $kc $xNow
Update-ChatqHeldKick $kc $xNow.AddSeconds(30)
Update-ChatqHeldKick $kc $xNow.AddSeconds(61)
$k1 = $script:XKicks
$script:ChatqClockSeam = $xDay.AddHours(3)
Update-ChatqHeldKick $kc $xNow.AddSeconds(130)
$k2 = $script:XKicks
Remove-Item -LiteralPath $script:ChatqHeldPath -Force
$script:ChatqClockSeam = $xDay.AddHours(8)
Update-ChatqHeldKick $kc $xNow.AddSeconds(200)
$script:ChatqHeldKickSeam = $null
Check 'the overlay starts the sender for the summary once a minute at most, not inside the window, not with nothing held' ($k1 -eq 2 -and $k2 -eq 2 -and $script:XKicks -eq 2) "$k1 $k2 $($script:XKicks)"

# --- voice -------------------------------------------------------------------------------
$script:ChatqClockSeam = $xDay.AddHours(12)
$vNoJoin = $null
$vCfgMid = [System.IO.File]::ReadAllText($script:ChatqConfigPath, $utf8)
$null = Set-ChatqNotifyConfig @{ RemoveJoin = $true }
$vNoJoin = Set-ChatqNotifyConfig @{ Say = 'needs input' }
[System.IO.File]::WriteAllText($script:ChatqConfigPath, $vCfgMid, $utf8)
$vUnknown = Set-ChatqNotifyConfig @{ Say = 'bogus' }
$null = Set-ChatqNotifyConfig @{ Events = 'done, failed' }
$vWarn = Set-ChatqNotifyConfig @{ Say = @('needs input', 'failed') }
$null = Set-ChatqNotifyConfig @{ Events = 'all' }
Check 'Say: refused with no Join, or for an unknown name; an event the phone does not get is saved with a warning, and the speaker is named' (
    $vNoJoin.Error -and @($vNoJoin.Messages | ForEach-Object Text) -contains "reading aloud is Join's - set up Join first (chatnotify -Setup, or -ApiKey)" -and
    $vUnknown.Error -and (@((Get-ChatqConfig).join.say) -join ',') -eq 'needs input,failed' -and
    @($vWarn.Messages | ForEach-Object Text) -contains "needs input is not among the phone's events - it is never read aloud until it is (-Events)" -and
    @($vWarn.Messages | ForEach-Object Text) -contains "Join speaks through the phone's speaker as well as headphones" -and
    @($vWarn.Messages | ForEach-Object Text) -contains 'read aloud on the phone: needs input, failed (language: auto - Korean for a Hangul title)') (($vWarn.Messages | ForEach-Object Text) -join ' | ')
$null = Set-ChatqNotifyConfig @{ Say = 'needs input' }
$vSay = { param($Ev, $Title, [string]$Text = 'x') $j = [pscustomobject]@{ id = 'v'; seq = 3; sessionId = $null; provider = 'claude'; title = $Title; state = 'x' }; $null = Send-ChatqAlert $Ev $Text 1 -Job $j; & $xLast }
$v1 = & $vSay 'needs input' 'Parser rewrite'
$v2 = & $vSay 'done' 'Parser rewrite'
Check 'voice: join.say needs input - its push says "Parser rewrite needs input" in en, after the text; a done says nothing' ($v1.Q['say'] -eq 'Parser rewrite needs input' -and
    $v1.Q['language'] -eq 'en' -and $v1.Url -match '&text=[^&]*&say=[^&]*&language=en&priority=' -and -not $v2.Q.ContainsKey('say')) $v1.Url
$vHan = U '\uD55C\uAE00 \uCC44\uD305'
$v3 = & $vSay 'needs input' $vHan
$null = Set-ChatqNotifyConfig @{ SayLanguage = 'en' }
$v4 = & $vSay 'needs input' $vHan
$null = Set-ChatqNotifyConfig @{ SayLanguage = 'de-DE' }
$v5 = & $vSay 'needs input' 'Build'
$vc = Get-ChatqConfig; Set-ChatqProp $vc.join 'sayLanguage' 'x y'; Save-ChatqJson $script:ChatqConfigPath $vc
$v6 = & $vSay 'needs input' $vHan
$vBadLang = Set-ChatqNotifyConfig @{ SayLanguage = 'x y' }
$null = Set-ChatqNotifyConfig @{ SayLanguage = 'auto' }
Check 'voice: a Hangul title in Korean, ko; sayLanguage en forces English; de-DE sent as it is with English words; a stored "x y" reads as auto and is refused as a flag' (
    $v3.Q['say'] -eq ($vHan + ' ' + (U '\uC785\uB825\uC744 \uAE30\uB2E4\uB9BD\uB2C8\uB2E4')) -and $v3.Q['language'] -eq 'ko' -and
    $v4.Q['say'] -eq "$vHan needs input" -and $v4.Q['language'] -eq 'en' -and $v5.Q['say'] -eq 'Build needs input' -and $v5.Q['language'] -eq 'de-DE' -and
    $v6.Q['language'] -eq 'ko' -and $vBadLang.Error -and -not (Get-ChatqConfig).join.PSObject.Properties['sayLanguage']) "$($v3.Q['say']) $($v3.Q['language']) / $($v4.Q['language']) / $($v5.Q['language']) / $($v6.Q['language'])"
$v7 = & $vSay 'needs input' ('abcdefghij' * 9)
$vk = Get-ChatqSayText 'usage' $null 'Claude 5h at 91% - resets 13:00' (Get-ChatqConfig)
$vr = Get-ChatqSayText 'usage' $null 'Codex limit reset - 2 queued' (Get-ChatqConfig)
$vt = Get-ChatqSayText 'test' $null 'x' (Get-ChatqConfig)
$vo = Get-ChatqSayText 'overloaded' ([pscustomobject]@{ provider = 'claude'; title = 'z' }) 'x' (Get-ChatqConfig)
$vn = Get-ChatqSayText 'needs input' $null 'x' (Get-ChatqConfig)
Check 'voice: a 90-character title spoken as its first 40; usage its percent or its reset; test, overloaded, and a chat with no title' ($v7.Q['say'] -eq (('abcdefghij' * 4) + ' needs input') -and
    $vk.Say -eq 'Claude usage at 91 percent' -and $vr.Say -eq 'Codex limit reset' -and $vt.Say -eq 'chatq test' -and $vo.Say -eq 'Claude is overloaded' -and
    $vn.Say -eq 'a chat needs input' -and $v7.Q['say'].Length -le 100) "$($v7.Q['say']) / $($vk.Say) / $($vr.Say) / $($vn.Say)"
# never: quiet hours (even an urgent one), -Quick, reply, pair, summary
$null = Set-ChatqNotifyConfig @{ Say = @('needs input', 'failed', 'test', 'done'); QuietHours = '00:00-07:00' }
$script:ChatqClockSeam = $xDay.AddHours(3)
$n1 = & $vSay 'failed' 'Night'
$script:ChatqClockSeam = $xDay.AddHours(12)
$null = Send-ChatqAlert 'needs input' 'quick' 1 -Quick -Job ([pscustomobject]@{ title = 'Quick' }); $n2 = & $xLast
$null = Send-ChatqAlert 'reply' 'answer' 1 -Loud; $n3 = & $xLast
$n4 = Get-ChatqJoinSay (Get-ChatqConfig) 'summary' $null 'x'
$n5 = Get-ChatqJoinSay (Get-ChatqConfig) 'pair' $null 'x'
$n6 = & $vSay 'test' $null
Check 'never read aloud: an urgent alert in quiet hours, a -Quick push, a reply, the pairing push, the summary; a test is, when chosen' (-not $n1.Q.ContainsKey('say') -and
    $n1.Q['title'] -eq "chatq $([char]0xB7) failed" -and -not $n2.Q.ContainsKey('say') -and -not $n3.Q.ContainsKey('say') -and -not $n4 -and -not $n5 -and $n6.Q['say'] -eq 'chatq test') "$($n1.Url) / $($n6.Q['say'])"
$null = Set-ChatqNotifyConfig @{ QuietHours = 'off' }
# the URL budget: the text trimmed first, then say dropped, the icon after that
$icon = $script:ChatqJoinIcon
$b0 = (Get-ChatqJoinUrl 'k' 'group.phone' 't' 'short' 1 -Icon $icon).Length
$bKey = 'k' * (1900 - $b0 - 30 + 1)
$bu1 = Get-ChatqJoinUrl $bKey 'group.phone' 't' 'short' 1 -Icon $icon -Say ('x' * 60) -Language 'en'
$b1 = (Get-ChatqJoinUrl 'k' 'group.phone' 't' ('y' * 200) 1 -Icon $icon -Say 'spoken' -Language 'en').Length
$bKey2 = 'k' * (1900 - $b1 + 40)
$bu2 = Get-ChatqJoinUrl $bKey2 'group.phone' 't' ('y' * 200) 1 -Icon $icon -Say 'spoken' -Language 'en'
Check 'a Join URL over budget: the text is trimmed first; with the text at 20 still over, say goes whole before the icon' ($bu1.Length -le 1900 -and $bu1 -notlike '*&say=*' -and
    $bu1 -notlike '*language=*' -and $bu1 -like '*icon=*' -and $bu2.Length -le 1900 -and $bu2 -like '*&say=spoken&language=en*' -and $bu2 -notlike "*$('y' * 200)*") "$($bu1.Length) $($bu2.Length)"
$vNone = Set-ChatqNotifyConfig @{ Say = 'none' }
Check 'Say none: nothing read aloud, the key gone' (-not (Get-ChatqConfig).join.PSObject.Properties['say'] -and @($vNone.Messages | ForEach-Object Text) -contains 'nothing is read aloud on the phone')

# --- chatnotify's status lines, read wide enough never to wrap -----------------------
$null = Set-ChatqNotifyConfig @{ QuietHours = '00:00-07:00'; Say = @('needs input', 'failed'); Events = 'done, failed, needs input'; UsageAt = '90'; Urgent = 'failed' }
$script:ChatqClockSeam = $xDay.AddHours(3)
$st = (chatnotify 6>&1 | Out-String -Width 400)
$script:ChatqClockSeam = $xDay.AddHours(12)
$null = Set-ChatqNotifyConfig @{ Events = 'all' }
Check 'chatnotify: usage, quiet (now until 07:00, held) and voice lines, and usage not among the phone''s events said' ($st -like "*usage    at 90% (the overlay checks)*resets on*" -and
    $st -like "*quiet    00:00-07:00 $([char]0xB7) failed comes through $([char]0xB7) now until 07:00 $([char]0xB7) 0 held*" -and $st -like "*voice    needs input, failed $([char]0xB7) language auto*" -and
    $st -like "*usage heads-ups are on, but 'usage' is not among the phone's events*") $st

# --- the setup window ----------------------------------------------------------------------
if ($script:ChatqIsWindows) {
    $null = Set-ChatqNotifyConfig @{ QuietHours = 'off'; Say = @('needs input'); UsageAt = '90'; Events = 'all' }
    $xStaScript = @"
`$env:CHATQ_OVERLAY = '1'
. '$(Join-Path $sb 'tool\VS-code-chat-manager.ps1')'
Set-StrictMode -Off
`$w = New-ChatqPhoneSetupWindow -Theme dark
`$U = `$w.Tag
`$has = [bool](`$U.SayPanel -and `$U.UrgentPanel -and `$U.UsageBox -and `$U.UsageAtBox -and `$U.ResetBox -and `$U.QuietHoursBox -and `$U.QuietFromBox -and `$U.QuietToBox)
`$panels = (@(`$U.SayPanel.Children | ForEach-Object { [string]`$_.Tag }) -join ',') + '/' + (@(`$U.UrgentPanel.Children | ForEach-Object { [string]`$_.Tag }) -join ',') + '/' + (@(`$U.EventsPanel.Children | ForEach-Object { [string]`$_.Tag }) -join ',')
`$read = [bool](`$U.UsageBox.IsChecked -and `$U.UsageAtBox.Text -eq '90' -and `$U.ResetBox.IsChecked -and -not `$U.QuietHoursBox.IsChecked -and `$U.QuietFromBox.Text -eq '00:00' -and
    `$U.QuietToBox.Text -eq '07:00' -and -not `$U.QuietFromBox.IsEnabled -and (Get-ChatqPhoneSetupTicked `$U.SayPanel) -eq 'needs input' -and (Get-ChatqPhoneSetupTicked `$U.UrgentPanel) -eq 'failed' -and
    -not (Test-ChatqPhoneSetupDirty `$U))
`$base = Get-ChatqPhoneSetupSnapshot `$U
`$moved = @()
`$flip = { param(`$cb) `$cb.IsChecked = -not `$cb.IsChecked; `$script:m = (Get-ChatqPhoneSetupSnapshot `$U) -ne `$base; `$cb.IsChecked = -not `$cb.IsChecked; `$script:m }
foreach (`$cb in @(`$U.UsageBox, `$U.ResetBox, `$U.QuietHoursBox, `$U.UrgentPanel.Children[0], `$U.SayPanel.Children[0])) { `$moved += (& `$flip `$cb) }
foreach (`$tb in @(`$U.UsageAtBox, `$U.QuietFromBox, `$U.QuietToBox)) { `$was = `$tb.Text; `$tb.Text = '11:11'; `$moved += ((Get-ChatqPhoneSetupSnapshot `$U) -ne `$base); `$tb.Text = `$was }
`$snap = -not (`$moved -contains `$false) -and (Get-ChatqPhoneSetupSnapshot `$U) -eq `$base
`$U.UsageAtBox.Text = '75, 90'
`$U.QuietHoursBox.IsChecked = `$true
`$U.QuietFromBox.Text = '22:00'
`$U.QuietToBox.Text = '6:30'
Update-ChatqPhoneSetupExtrasEnabled `$U
foreach (`$cb in `$U.UrgentPanel.Children) { `$cb.IsChecked = [string]`$cb.Tag -in 'failed', 'needs input' }
foreach (`$cb in `$U.SayPanel.Children) { `$cb.IsChecked = [string]`$cb.Tag -in 'done', 'test' }
`$r = Get-ChatqPhoneSetupChanges `$U
`$c = `$r.Changes
`$good = -not `$r.Error -and `$c.UsageAt -eq '75,90' -and `$c.QuietHours -eq '22:00-06:30' -and (@(`$c.Urgent) -join ',') -eq 'needs input,failed' -and (@(`$c.Say) -join ',') -eq 'done,test' -and
    -not `$c.ContainsKey('UsageAlerts') -and -not `$c.ContainsKey('UsageReset') -and `$U.QuietFromBox.IsEnabled
`$U.UsageAtBox.Text = '0, 100'
`$bad1 = (Get-ChatqPhoneSetupChanges `$U).Error
`$U.UsageAtBox.Text = '90'
`$U.QuietToBox.Text = '22:00'
`$bad2 = (Get-ChatqPhoneSetupChanges `$U).Error
`$U.QuietToBox.Text = '06:30'
`$U.QuietHoursBox.IsChecked = `$false
Update-ChatqPhoneSetupExtrasEnabled `$U
`$kept = `$U.QuietFromBox.Text -eq '22:00' -and `$U.QuietToBox.Text -eq '06:30' -and -not `$U.QuietFromBox.IsEnabled -and -not `$U.UrgentPanel.Children[0].IsEnabled
foreach (`$cb in `$U.EventsPanel.Children) { `$cb.IsChecked = [string]`$cb.Tag -ne 'done' }
Update-ChatqPhoneSetupExtrasEnabled `$U
`$sayDone = @(`$U.SayPanel.Children | Where-Object { [string]`$_.Tag -eq 'done' })[0]
`$sayTest = @(`$U.SayPanel.Children | Where-Object { [string]`$_.Tag -eq 'test' })[0]
`$c2 = (Get-ChatqPhoneSetupChanges `$U).Changes
`$gated = -not `$sayDone.IsEnabled -and `$sayTest.IsEnabled -and (@(`$c2.Say) -join ',') -eq 'test' -and `$U.SayNote.Text -like '*left out on Save: done*'
`$U.UsageBox.IsChecked = `$false
Update-ChatqPhoneSetupExtrasEnabled `$U
`$off = -not `$U.UsageAtBox.IsEnabled -and (Get-ChatqPhoneSetupChanges `$U).Changes.UsageAlerts -eq `$false
'{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}' -f `$has, `$read, `$snap, `$good, `$bad1, `$bad2, `$kept, `$gated, `$off, "`$panels / `$(`$c | ConvertTo-Json -Compress)"
"@
    $staOut = Invoke-Sta 'extras-setup-test' $xStaScript
    $sx = "$staOut" -split '\|'
    Check 'setup window: read aloud, quiet hours with still-send, usage and resets - each event box made, usage among the events' ($sx[0] -eq 'True' -and
        $sx[9] -like 'started,needs input,done,failed,limited,overloaded,waiting,usage,test/started,*,usage/started,*,waiting,usage*') "$staOut"
    Check 'setup window: filled from config.json, times kept while quiet hours are off, nothing unsaved' ($sx[1] -eq 'True') "$staOut"
    Check 'setup window: every new control moves the unsaved check, and back again leaves it clean' ($sx[2] -eq 'True') "$staOut"
    Check 'setup window: Save hands over UsageAt, QuietHours (6:30 as 06:30), Urgent and Say - only what changed' ($sx[3] -eq 'True') "$staOut"
    Check 'setup window: a bad threshold or the same time twice blocks Save with the words for it' ($sx[4] -eq 'Usage: up to three whole percents from 1 to 99.' -and
        $sx[5] -eq 'Quiet hours: times like 07:00, and not the same twice.') "$staOut"
    Check 'setup window: unticking quiet hours keeps the times, and turns them and still-send off' ($sx[6] -eq 'True') "$staOut"
    Check 'setup window: read aloud only for an event the phone gets (and test), with a note for one left out' ($sx[7] -eq 'True') "$staOut"
    Check 'setup window: usage unticked turns its box off, and saves alerts off' ($sx[8] -eq 'True') "$staOut"
}

# --- put it all back -------------------------------------------------------------------------
& $xClean
if ($null -ne $xCfgWas) { [System.IO.File]::WriteAllText($script:ChatqConfigPath, $xCfgWas, $utf8) } else { Remove-Item -LiteralPath $script:ChatqConfigPath -Force -EA SilentlyContinue }
Remove-Item -LiteralPath $xHook -Force -EA SilentlyContinue
Remove-Item -Path (Join-Path $script:ChatqOutboxDir '*') -Force -EA SilentlyContinue
$script:ChatqJoinSeam = $xWas.Join
$script:ChatqIdleSeam = $xWas.Idle
$script:ChatqLiveSendSeam = $xWas.Send
$script:ChatqSpawn = $xWas.Spawn
$script:ChatqReplyPollSeam = $xWas.Poll
$script:ChatqForeground = $xWas.Fg
$script:ChatqClockSeam = $null
$script:ChatqHeldKickSeam = $null
$script:ChatqUsageSent = @{}; $script:ChatqPhoneWakeAt = $null; $script:ChatqSummaryTriedAt = $null; $script:ChatqSendingSummary = $false
$script:ChatqReplySeen = @{}; $script:ChatqReplyHandled = @{}; $script:ChatqReplyPolledAt = $null
