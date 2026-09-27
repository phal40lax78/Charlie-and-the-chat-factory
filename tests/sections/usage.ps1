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
