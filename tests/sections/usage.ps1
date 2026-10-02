# tests/sections/usage.ps1: dot-sourced by tests/run-tests.ps1 in its turn,
# never on its own - it uses what the runner and the sections before it set.

Section 'usage'
$fetched = [DateTimeOffset]::Now.AddMinutes(-20).ToUnixTimeMilliseconds()
$cj = '{"numStartups":3,"cachedUsageUtilization":{"fetchedAtMs":' + $fetched + ',"utilization":{"limits":[' +
'{"kind":"session","percent":83,"resets_at":"' + $now.AddHours(2).ToString('o') + '","scope":null},' +
'{"kind":"weekly_all","percent":41,"resets_at":"' + $now.AddDays(3).ToString('o') + '","scope":null},' +
'{"kind":"weekly_scoped","percent":0,"resets_at":null,"scope":{"model":{"display_name":"Fable"}}}]}},"other":1}'
[System.IO.File]::WriteAllText((Join-Path $claudeHome '.claude.json'), $cj, $utf8)
$u = @(Get-ChatqUsage)
$ucl = @($u | Where-Object { $_.Provider -eq 'Claude' })[0]
$ucx = @($u | Where-Object { $_.Provider -eq 'Codex' })[0]
Check 'Claude''s usage from its own cache, with how old it is' ($ucl -and ($ucl.Parts -join ',') -eq '5h 83%,week 41%' -and $ucl.AsOf) "$($ucl.Parts -join ',') $($ucl.AsOf)"
Check 'Codex''s from the newest rollout that has any' ($ucx -and $ucx.Parts[0] -like '5h 100%, resets *' -and $ucx.Parts[1] -eq 'week 12%') "$($ucx.Parts -join ',')"
# One reader for Codex's rate_limits (Read-ChatqCodexLimitSnapshot), where
# three copies matched the compact '"rate_limits":{' alone: spaced JSON as
# well, newest first, past a half-written last line and a snapshot with no
# window, and never a mention quoted inside a reply
$cxT = { param($ago) $now.AddMinutes(-$ago).ToString('o') }
$cxSpaced = '{"timestamp": "' + (& $cxT 30) + '", "type": "event_msg", "payload": {"type": "token_count", "rate_limits": {"limit_id": "codex", "primary": {"used_percent": 42.0, "window_minutes": 300, "resets_at": ' + $future + '}, "secondary": null, "plan_type": "plus", "rate_limit_reached_type": null}}}'
$snSp = Read-ChatqCodexLimitSnapshot ($cxSpaced + "`n")
Check 'codex limits: spaced JSON is read as compact is - its window, plan and record time' (
    $snSp -and @($snSp.Limits).Count -eq 1 -and $snSp.Limits[0].Label -eq '5h' -and $snSp.Limits[0].Type -eq 'five_hour' -and $snSp.Limits[0].Percent -eq 42 -and
    $snSp.PlanType -eq 'plus' -and $null -eq $snSp.Reached -and $snSp.At -and [Math]::Abs(($snSp.At - $now.AddMinutes(-30).LocalDateTime).TotalSeconds) -lt 2) "$($snSp | ConvertTo-Json -Depth 4 -Compress)"
$cxGood = '{"timestamp":"' + (& $cxT 20) + '","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":7.0,"window_minutes":10080,"resets_at":' + $future + '},"secondary":null,"plan_type":"free","rate_limit_reached_type":"rate_limit_reached"}}}'
$cxMention = '{"timestamp":"' + (& $cxT 15) + '","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"it reads \"rate_limits\":{\"primary\":{\"used_percent\":99}} from the tail"}]}}'
$cxEmpty = '{"timestamp":"' + (& $cxT 10) + '","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":null,"secondary":null,"plan_type":"free"}}}'
$cxTorn = '{"timestamp":"' + (& $cxT 5) + '","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_perc'
$snMix = Read-ChatqCodexLimitSnapshot (@($cxGood, $cxMention, $cxEmpty, $cxTorn) -join "`n")
Check 'codex limits: the newest readable snapshot with a window - past a torn last line, one with none and a quoted mention' (
    $snMix -and @($snMix.Limits).Count -eq 1 -and $snMix.Limits[0].Label -eq 'week' -and $snMix.Limits[0].Type -eq 'weekly' -and $snMix.Limits[0].Percent -eq 7 -and
    $snMix.PlanType -eq 'free' -and $snMix.Reached -eq 'rate_limit_reached' -and [Math]::Abs(($snMix.At - $now.AddMinutes(-20).LocalDateTime).TotalSeconds) -lt 2) "$($snMix | ConvertTo-Json -Depth 4 -Compress)"
Check 'codex limits: none in a reply''s quoted mention, a windowless snapshot or nothing' (
    $null -eq (Read-ChatqCodexLimitSnapshot $cxMention) -and $null -eq (Read-ChatqCodexLimitSnapshot $cxEmpty) -and $null -eq (Read-ChatqCodexLimitSnapshot '')) ''
# and its three readers agree: once the overlay went on to an older rollout
# where chatqlist and the limit check stopped at a snapshot with no window
$cxSpHome = Join-Path $sb 'codex-spaced'
$cxSpDir = Join-Path $cxSpHome 'sessions\2026\09\21'
$null = New-Item -ItemType Directory -Path $cxSpDir -Force
$cxOld = Join-Path $cxSpDir 'rollout-2026-09-21T08-00-00-01900000-0000-7000-8000-0000000000a1.jsonl'
$cxNew = Join-Path $cxSpDir 'rollout-2026-09-21T09-00-00-01900000-0000-7000-8000-0000000000a2.jsonl'
$cxFull = '{"timestamp": "' + (& $cxT 40) + '", "type": "event_msg", "payload": {"type": "token_count", "rate_limits": {"limit_id": "codex", "primary": {"used_percent": 100.0, "window_minutes": 300, "resets_at": ' + $future +
'}, "secondary": {"used_percent": 12.0, "window_minutes": 10080, "resets_at": ' + $now.AddDays(3).ToUnixTimeSeconds() + '}, "plan_type": "plus"}}}'
[System.IO.File]::WriteAllText($cxOld, $cxFull + "`n", $utf8)
(Get-Item -LiteralPath $cxOld).LastWriteTime = (Get-Date).AddMinutes(-40)
# a newer thread cut off before its first reply has no snapshot at all:
# the block still comes from the one before it
$cxBare = Join-Path $cxSpDir 'rollout-2026-09-21T10-00-00-01900000-0000-7000-8000-0000000000a3.jsonl'
[System.IO.File]::WriteAllText($cxBare, '{"timestamp":"' + (& $cxT 5) + '","type":"session_meta","payload":{"id":"01900000-0000-7000-8000-0000000000a3"}}' + "`n", $utf8)
(Get-Item -LiteralPath $cxBare).LastWriteTime = (Get-Date).AddMinutes(-5)
$xBare = Get-ChatqCodexBlock $cxSpHome
# but a newer snapshot with no window is the account's newest word: the old
# full window blocks nothing, though it is still what usage shows
[System.IO.File]::WriteAllText($cxNew, $cxEmpty + "`n", $utf8)
(Get-Item -LiteralPath $cxNew).LastWriteTime = (Get-Date).AddMinutes(-10)
$xSp = Get-ChatqCodexBlock $cxSpHome
$ovSp = Read-ChatqCodexUsage @(Get-ChildItem -LiteralPath $cxSpDir -Filter *.jsonl -File | Sort-Object LastWriteTime -Descending)
$uSp = @(@(Get-ChatqUsage -CodexHome $cxSpHome) | Where-Object { $_.Provider -eq 'Codex' })[0]
# One home per reader (F4): Get-ChatqUsage and the overlay read the home
# chatq lists Codex chats from, or the one handed to them - never a
# CODEX_HOME the shell set after chatq loaded
$cxHomeWas = $env:CODEX_HOME
try {
    $env:CODEX_HOME = $cxSpHome
    $uEnv = @(@(Get-ChatqUsage) | Where-Object { $_.Provider -eq 'Codex' })[0]
}
finally { $env:CODEX_HOME = $cxHomeWas }
$ovHomeCtx = New-ChatOverlayContext -CodexHome $cxSpHome
# Codex only: nothing here may ask the Claude usage endpoint or gh
$ovHomeCtx.Config.liveUsage = $false
$ovHomeCtx.Config.copilotUsage = $false
$ovHome = @(@(Update-ChatOverlayUsage $ovHomeCtx $false) | Where-Object { $_.provider -eq 'Codex' })[0]
$ovDefCtx = New-ChatOverlayContext
Check 'codex usage: a home of its own - -CodexHome is read, a CODEX_HOME set after loading is not, and the overlay context keeps its own' (
    $uEnv -and $uEnv.Parts[0] -like '5h 100%, resets *' -and $uEnv.Parts[1] -eq 'week 12%' -and $uEnv.AsOfAt -ne $uSp.AsOfAt -and
    $ovHomeCtx.CodexHome -eq $cxSpHome -and $ovDefCtx.CodexHome -eq $script:ChatCodexHome -and
    $ovHome -and (@($ovHome.windows | ForEach-Object label) -join ',') -eq '5h,week' -and [Math]::Abs($ovHome.at - (ConvertTo-ChatOverlayMs $xBare.At)) -lt 1000) (
    "env: $($uEnv.Parts -join ',') $($uEnv.AsOfAt) / -CodexHome: $($uSp.AsOfAt) / ctx: $($ovHomeCtx.CodexHome) $(@($ovHome.windows | ForEach-Object label) -join ',')")
Remove-Item -LiteralPath $cxSpHome -Recurse -Force -EA SilentlyContinue
Check 'codex limits: the limit check, the overlay and chatqlist read one spaced snapshot, past a newer rollout with none' (
    $xBare -and $xBare.Type -eq 'five_hour' -and [Math]::Abs(($xBare.Until - [DateTimeOffset]::FromUnixTimeSeconds($future).LocalDateTime).TotalSeconds) -lt 2 -and $xBare.At -and
    $ovSp -and (@($ovSp.Windows | ForEach-Object Label) -join ',') -eq '5h,week' -and [Math]::Abs(($ovSp.At - $xBare.At).TotalSeconds) -lt 1 -and
    $uSp -and $uSp.Parts[0] -like '5h 100%, resets *' -and $uSp.Parts[1] -eq 'week 12%') "$($xBare.Type) / $(@($ovSp.Windows | ForEach-Object Label) -join ',') / $($uSp.Parts -join ',')"
Check 'codex limits: a newer snapshot with no window lifts the block an older full one would set - usage still shows the older figure' (
    $null -eq $xSp -and $uSp -and $uSp.Parts[0] -like '5h 100%, resets *') "block: $($xSp | ConvertTo-Json -Compress) / usage: $($uSp.Parts -join ',')"
# The overlay's own live figure, when newer than that cache: the phone's
# status read the cache 35 minutes old while the overlay had 62%
$ovWas = if (Test-Path -LiteralPath $script:ChatOverlayPath) { [System.IO.File]::ReadAllText($script:ChatOverlayPath) } else { $null }
$ovSnap = { param($minsAgo) '{"header":{"usage":[{"provider":"Claude","source":"live","at":' + [DateTimeOffset]::Now.AddMinutes(-$minsAgo).ToUnixTimeMilliseconds() +
    ',"windows":[{"label":"5h","percent":62},{"label":"week","percent":22}]},{"provider":"Copilot","source":"live","at":1,"windows":[]}]}}' }
[System.IO.File]::WriteAllText($script:ChatOverlayPath, (& $ovSnap 2), $utf8)
$ulive = @(@(Get-ChatqUsage) | Where-Object { $_.Provider -eq 'Claude' })
[System.IO.File]::WriteAllText($script:ChatOverlayPath, (& $ovSnap 40), $utf8)
$uold = @(@(Get-ChatqUsage) | Where-Object { $_.Provider -eq 'Claude' })
[System.IO.File]::WriteAllText($script:ChatOverlayPath, '{"header":{"usage":[]}}', $utf8)
$unone = @(@(Get-ChatqUsage) | Where-Object { $_.Provider -eq 'Claude' })
if ($null -ne $ovWas) { [System.IO.File]::WriteAllText($script:ChatOverlayPath, $ovWas, $utf8) } else { Remove-Item -LiteralPath $script:ChatOverlayPath -Force -EA SilentlyContinue }
Check 'Claude''s usage: the overlay''s live figure where it is newer than the cache, the cache where it is older or there is none - one Claude line either way' (
    $ulive.Count -eq 1 -and ($ulive[0].Parts -join ',') -eq '5h 62%,week 22%' -and ($ulive[0].AsOfAt -gt $ucl.AsOfAt) -and
    $uold.Count -eq 1 -and ($uold[0].Parts -join ',') -eq '5h 83%,week 41%' -and
    $unone.Count -eq 1 -and ($unone[0].Parts -join ',') -eq '5h 83%,week 41%') "$($ulive[0].Parts -join ',') / $($uold[0].Parts -join ',') / $($unone[0].Parts -join ',')"
# Codex's the same way, from codex app-server's answer the overlay keeps -
# but only for the home the overlay asked under, which the figure names: the
# overlay is a process of its own, with its launcher's CODEX_HOME
$cxMyHome = Get-ChatqHomeDir 'codex' $script:ChatCodexHome
$cxLiveSnap = { param($minsAgo, $home2) '{"header":{"usage":[{"provider":"Codex","source":"live","at":' + [DateTimeOffset]::Now.AddMinutes(-$minsAgo).ToUnixTimeMilliseconds() +
    $(if ($home2) { ',"home":' + (ConvertTo-Json ([string]$home2)) } else { '' }) +
    ',"plan":"free","windows":[{"label":"month","percent":100,"resetsAt":' + [DateTimeOffset]::Now.AddDays(9).ToUnixTimeMilliseconds() + '},{"label":"week","percent":3,"resetsAt":' +
    [DateTimeOffset]::Now.AddMinutes(-1).ToUnixTimeMilliseconds() + '}]}]}}' }
$cxOther = Join-Path $sb 'codex-other-home'
$null = New-Item -ItemType Directory -Path $cxOther -Force
try {
    # the home written another way - its case and a slash at the end - is the same one
    [System.IO.File]::WriteAllText($script:ChatOverlayPath, (& $cxLiveSnap 1 ($cxMyHome.ToUpperInvariant() + '\')), $utf8)
    $uxLive = @(@(Get-ChatqUsage) | Where-Object { $_.Provider -eq 'Codex' })
    $uxOther = @(@(Get-ChatqUsage -CodexHome $cxOther) | Where-Object { $_.Provider -eq 'Codex' })
    # an overlay started under another home, read by a caller that names
    # none: the caller's own home, not the overlay's account
    [System.IO.File]::WriteAllText($script:ChatOverlayPath, (& $cxLiveSnap 1 $cxOther), $utf8)
    $uxTheirs = @(@(Get-ChatqUsage) | Where-Object { $_.Provider -eq 'Codex' })
    # and a figure that names no home - an older overlay's - is never taken
    [System.IO.File]::WriteAllText($script:ChatOverlayPath, (& $cxLiveSnap 1 $null), $utf8)
    $uxNoHome = @(@(Get-ChatqUsage) | Where-Object { $_.Provider -eq 'Codex' })
    $ageMins = [Math]::Max(1, [int]((Get-Date) - $ucx.AsOfAt).TotalMinutes + 60)
    [System.IO.File]::WriteAllText($script:ChatOverlayPath, (& $cxLiveSnap $ageMins $cxMyHome), $utf8)
    $uxOld = @(@(Get-ChatqUsage) | Where-Object { $_.Provider -eq 'Codex' })
}
finally {
    if ($null -ne $ovWas) { [System.IO.File]::WriteAllText($script:ChatOverlayPath, $ovWas, $utf8) } else { Remove-Item -LiteralPath $script:ChatOverlayPath -Force -EA SilentlyContinue }
    Remove-Item -LiteralPath $cxOther -Recurse -Force -EA SilentlyContinue
}
Check 'Codex''s usage: the overlay''s live answer where it is newer than the rollout - a full window with its reset, one reset since at 0% - never for another home' (
    $uxLive.Count -eq 1 -and $uxLive[0].Parts[0] -like 'month 100%, resets *' -and $uxLive[0].Parts[1] -eq 'week 0%' -and $uxLive[0].AsOfAt -gt $ucx.AsOfAt -and
    $uxOther.Count -eq 0 -and
    $uxOld.Count -eq 1 -and ($uxOld[0].Parts -join ',') -eq ($ucx.Parts -join ',')) "$($uxLive[0].Parts -join ',') / $($uxOther.Count) / $($uxOld[0].Parts -join ',')"
Check 'Codex''s usage: an overlay''s live answer asked under another home, or naming none, is not taken by a caller that names no home' (
    $uxTheirs.Count -eq 1 -and ($uxTheirs[0].Parts -join ',') -eq ($ucx.Parts -join ',') -and
    $uxNoHome.Count -eq 1 -and ($uxNoHome[0].Parts -join ',') -eq ($ucx.Parts -join ',')) "$($uxTheirs[0].Parts -join ',') / $($uxNoHome[0].Parts -join ',')"
$shown = (Write-ChatqList 6>&1 | Out-String -Width 400)
Check 'chatqlist shows it' ($shown -like '*usage  Claude 5h 83%*') ''
# Both caches refresh only when their own tool runs, so the numbers can be
# older than what the status line above them says - and a lane limited right
# now cannot be at 83% of a window it has spent.
$was = Get-ChatqState
Save-ChatqJson $script:ChatqStatePath ([ordered]@{
        pid = $PID; blocked = @{ claude = @{ until = (Get-Date).AddHours(1).ToUniversalTime().ToString('o'); type = 'five_hour'; source = 'transcript' } }; outage = @{}
    })
$shown = Lock-Queue { Write-ChatqList 6>&1 | Out-String -Width 400 }
Check 'a limited account reads 5h limited, never a percent from before it' ($shown -like '*Claude 5h limited*' -and $shown -notlike '*5h 83%*') (@($shown -split "`n" | Where-Object { $_ -like '*usage*' }) -join '')
# and only the window that is blocked: a week gone says nothing about the 5 h
Save-ChatqJson $script:ChatqStatePath ([ordered]@{
        pid = $PID; blocked = @{ claude = @{ until = (Get-Date).AddDays(2).ToUniversalTime().ToString('o'); type = 'weekly_all'; source = 'transcript' } }; outage = @{}
    })
$shown = Lock-Queue { Write-ChatqList 6>&1 | Out-String -Width 400 }
Check 'a weekly limit leaves the 5 h figure alone' ($shown -like '*Claude 5h 83%*' -and $shown -like '*week limited*') (@($shown -split "`n" | Where-Object { $_ -like '*usage*' }) -join '')
Save-ChatqJson $script:ChatqStatePath $was
[System.IO.File]::WriteAllText((Join-Path $claudeHome '.claude.json'),
    $cj.Replace("$fetched", [string]([DateTimeOffset]::Now.AddHours(-3).ToUnixTimeMilliseconds())), $utf8)
$shown = (Write-ChatqList 6>&1 | Out-String -Width 400)
Check 'a reading hours old is marked stale' ($shown -match 'as of [^)]+ - stale') (@($shown -split "`n" | Where-Object { $_ -like '*usage*' }) -join '')
