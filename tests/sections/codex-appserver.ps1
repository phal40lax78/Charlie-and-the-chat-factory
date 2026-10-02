# tests/sections/codex-appserver.ps1: dot-sourced by tests/run-tests.ps1 in its turn,
# never on its own - it uses what the runner and the sections before it set.

# The codex app-server client (src/codex-appserver.ps1) against the fake's
# app-server mode (tests/fake-agent.ps1), answering from
# tests/fixtures/appserver. No real codex runs here.
Section 'codex app-server client'
$asRec = Join-Path $sb 'rec-appserver'
$asWas = @{}
foreach ($n in 'FAKE_RECORD', 'FAKE_APPSERVER', 'FAKE_APPSERVER_NOMETHOD', 'FAKE_SLEEP', 'OPENAI_API_KEY', 'CHATQ_CODEX') { $asWas[$n] = [Environment]::GetEnvironmentVariable($n) }
# what the fake was sent, one parsed message per line
$asSent = {
    $f = Join-Path $asRec 'appserver.jsonl'
    if (-not (Test-Path -LiteralPath $f)) { return @() }
    @([System.IO.File]::ReadAllLines($f, $utf8) | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
}
$asPid = { [int]([System.IO.File]::ReadAllText((Join-Path $asRec 'pid.txt'))) }
# the methods among them, in order: the client's own answers carry none
$asMethods = { (@(& $asSent | ForEach-Object { if ($_.PSObject.Properties['method']) { $_.method } }) -join ',') }
try {
    $env:FAKE_RECORD = $asRec
    $env:FAKE_APPSERVER = Join-Path $here 'fixtures\appserver'
    $env:OPENAI_API_KEY = 'sk-must-not-leak'

    # one read: initialize, initialized, the request - stdin held open until
    # the reply is in (a real 0.159.2 drops it at stdin's end, S-A4)
    $r = Invoke-ChatqCodexRpc -Method 'account/rateLimits/read' -CodexHome $codexHome
    $sent = & $asSent
    $rl = if ($r.Results[0]) { $r.Results[0].rateLimits } else { $null }
    Check 'app-server: a rate-limit read comes back whole, with nothing else asked' (
        $r.Ok -and -not $r.Why -and $rl -and $rl.primary.windowDurationMins -eq 43200 -and $rl.planType -eq 'free' -and $null -eq $r.Errors[0] -and
        $r.Init.codexHome -eq $codexHome -and (& $asMethods) -eq 'initialize,initialized,account/rateLimits/read') "$($r.Why) / $(& $asMethods)"
    $init = @($sent | Where-Object { $_.PSObject.Properties['method'] -and $_.method -eq 'initialize' })[0]
    Check 'app-server: initialize names chatq and asks for no experimental API unless told' (
        $init -and $init.params.clientInfo.name -eq 'chatq' -and $init.params.clientInfo.version -and -not $init.params.PSObject.Properties['capabilities']) "$($init | ConvertTo-Json -Compress -Depth 5)"
    # the fixture sends account/updated and a request of the server's own,
    # with id 1 - the id the read itself went out with - before the reply
    $refusal = @($sent | Where-Object { -not $_.PSObject.Properties['method'] -and $_.PSObject.Properties['error'] })[0]
    Check 'app-server: notifications are skipped, and a request of the server''s is refused, never taken for a reply' (
        @($r.Notes) -contains 'remoteControl/status/changed' -and @($r.Notes) -contains 'account/updated' -and
        (@($r.Asked) -join ',') -eq 'item/commandExecution/requestApproval' -and $refusal -and $refusal.id -eq 1 -and $refusal.error.code -eq -32601) (
        "notes $(@($r.Notes) -join ',') asked $(@($r.Asked) -join ',')")
    $envSeen = [System.IO.File]::ReadAllText((Join-Path $asRec 'env.txt'), $utf8)
    Check 'app-server: started on the given CODEX_HOME, with no API key to bill instead of the login' (
        $envSeen -match "(?m)^CODEX_HOME=$([regex]::Escape($codexHome))\r?$" -and $envSeen -match '(?m)^OPENAI_API_KEY=\r?$') $envSeen
    $fp = & $asPid
    Start-Sleep -Milliseconds 300
    Check 'app-server: the server is gone once the replies are in' (-not (Get-Process -Id $fp -EA SilentlyContinue)) $fp

    # several requests in one start; thread/list always state-DB only, as
    # anything else repairs Codex's thread database from the rollouts
    $r = Invoke-ChatqCodexRpc -CodexHome $codexHome -Calls @(
        @{ method = 'thread/list'; params = @{ limit = 5; useStateDbOnly = $false } },
        @{ method = 'thread/list' },
        @{ method = 'thread/loaded/list'; params = @{} })
    $lists = @(& $asSent | Where-Object { $_.PSObject.Properties['method'] -and $_.method -eq 'thread/list' })
    Check 'app-server: thread/list goes out with useStateDbOnly true, whether false or nothing was passed' (
        $lists.Count -eq 2 -and $lists[0].params.useStateDbOnly -eq $true -and $lists[0].params.limit -eq 5 -and $lists[1].params.useStateDbOnly -eq $true) (
        "$($lists | ConvertTo-Json -Compress -Depth 5)")
    Check 'app-server: each reply goes to its own request; one with no answer but an error is $null, the rest stand' (
        $r.Ok -and $r.Results[0].data[0].id -eq $cxId -and $r.Results[1].data[0].id -eq $cxId -and
        $null -eq $r.Results[2] -and "$($r.Errors[2])" -like 'fake app-server: no fixture for thread/loaded/list*') "$($r.Errors -join ' | ')"
    $pa = Get-ChatqCodexRpcParams 'thread/list' ([pscustomobject]@{ archived = $true; useStateDbOnly = $false })
    $po = [pscustomobject]@{ useStateDbOnly = $false }
    Check 'app-server: the params guard takes an object too, and leaves every other method''s alone' (
        $pa.archived -eq $true -and $pa.useStateDbOnly -eq $true -and [object]::ReferenceEquals((Get-ChatqCodexRpcParams 'thread/turns/list' $po), $po)) ''

    $r = Invoke-ChatqCodexRpc -Method 'account/rateLimits/read' -CodexHome $codexHome -Experimental
    $init = @(& $asSent | Where-Object { $_.PSObject.Properties['method'] -and $_.method -eq 'initialize' })[0]
    Check 'app-server: -Experimental asks for the experimental API' ($r.Ok -and $init.params.capabilities.experimentalApi -eq $true) "$($init | ConvertTo-Json -Compress -Depth 5)"

    # an older codex that has no such method: an error, no data, no throw
    $env:FAKE_APPSERVER_NOMETHOD = 'account/rateLimits/read'
    $r = Invoke-ChatqCodexRpc -Method 'account/rateLimits/read' -CodexHome $codexHome
    Check 'app-server: a method the server does not know is no data, said in its words' (
        $r.Ok -and $null -eq $r.Results[0] -and "$($r.Errors[0])".StartsWith('Invalid request: unknown variant `account/rateLimits/read`')) "$($r.Errors[0])"
    $env:FAKE_APPSERVER_NOMETHOD = 'initialize'
    $r = Invoke-ChatqCodexRpc -Method 'account/rateLimits/read' -CodexHome $codexHome
    Check 'app-server: a refused initialize ends it there - nothing else is sent' (
        -not $r.Ok -and "$($r.Why)" -like 'initialize: Invalid request*' -and $null -eq $r.Results[0] -and (& $asMethods) -eq 'initialize') "$($r.Why) / $(& $asMethods)"
    Remove-Item env:FAKE_APPSERVER_NOMETHOD

    # a server that hangs on a request: the deadline, then the whole tree
    $env:FAKE_SLEEP = '30'
    $t0 = Get-Date
    $r = Invoke-ChatqCodexRpc -Method 'account/rateLimits/read' -CodexHome $codexHome -TimeoutSec 8
    $took = ((Get-Date) - $t0).TotalSeconds
    $fp = & $asPid
    Start-Sleep -Milliseconds 500
    Check 'app-server: a request that hangs times out, no data, and the server and its parent are ended' (
        -not $r.Ok -and $r.Why -eq 'timed out' -and $null -eq $r.Results[0] -and $took -lt 20 -and
        -not (Get-Process -Id $fp -EA SilentlyContinue) -and -not ($r.Pid -and (Get-Process -Id $r.Pid -EA SilentlyContinue))) "$($r.Why) in $([int]$took) s, fake $fp"

    # stdin held open until every reply is in: the fake, as 0.159.2 does,
    # drops a request still being worked out the moment its stdin ends - so
    # a slow reply comes back only to a client that waits for it, and one
    # that closes stdin once the request is out gets nothing
    $env:FAKE_SLEEP = '2'
    $rSlow = Invoke-ChatqCodexRpc -Method 'account/rateLimits/read' -CodexHome $codexHome
    $sEarly = Start-ChatqCodexRpc -Method 'account/rateLimits/read' -CodexHome $codexHome
    $early = $null
    while ($sEarly.Phase -eq 'init' -and -not $early) { $early = Step-ChatqCodexRpc $sEarly -WaitMs 200 }
    if (-not $early) {
        try { $sEarly.Proc.StandardInput.Close() } catch {}
        while (-not $early) { $early = Step-ChatqCodexRpc $sEarly -WaitMs 1000 }
    }
    Check 'app-server: a slow reply is taken while stdin stays open, and lost to a client that closes it early' (
        $rSlow.Ok -and $rSlow.Results[0] -and -not $early.Ok -and $early.Why -eq 'exited' -and $null -eq $early.Results[0]) "$($rSlow.Why) / $($early.Why)"
    Remove-Item env:FAKE_SLEEP

    # a home that is not there is never handed to it: started there, codex
    # makes one, its databases and all (S-A4)
    Remove-Item -LiteralPath $asRec -Recurse -Force -EA SilentlyContinue
    $noHome = Join-Path $sb 'codex-not-there'
    $r = Invoke-ChatqCodexRpc -Method 'account/rateLimits/read' -CodexHome $noHome
    Check 'app-server: a Codex home that is not there is said, and nothing is started or made' (
        -not $r.Ok -and "$($r.Why)" -like 'no Codex home at *' -and -not (Test-Path -LiteralPath (Join-Path $asRec 'pid.txt')) -and -not (Test-Path -LiteralPath $noHome)) "$($r.Why)"

    # a CLI that will not start, and one that ends before it answers
    $env:CHATQ_CODEX = Join-Path $sb 'no-such-codex.exe'
    $r = $null
    $threw = $null
    try { $r = Invoke-ChatqCodexRpc -Method 'account/rateLimits/read' -CodexHome $codexHome } catch { $threw = $_.Exception.Message }
    Check 'app-server: a codex that will not start is said, never thrown' (-not $threw -and $r -and -not $r.Ok -and "$($r.Why)" -like 'did not start: *') "$threw $(if ($r) { $r.Why })"
    $quitter = Join-Path $sb 'quit-codex.cmd'
    [System.IO.File]::WriteAllText($quitter, "@echo off`r`nexit /b 0`r`n", [System.Text.Encoding]::ASCII)
    $env:CHATQ_CODEX = $quitter
    $r = Invoke-ChatqCodexRpc -Method 'account/rateLimits/read' -CodexHome $codexHome
    Check 'app-server: a server that ends before it answers is no data' (-not $r.Ok -and $r.Why -eq 'exited' -and $null -eq $r.Results[0]) "$($r.Why)"
}
finally {
    foreach ($n in $asWas.Keys) { [Environment]::SetEnvironmentVariable($n, $asWas[$n]) }
}

# Codex's usage asked of the app-server: the answer read, the overlay's
# fetch through the fake, the version floor, and the probe that asks it
# before it spends a turn (Get-ChatqCodexLiveLimit)
Section 'codex usage, asked live'
$cuRec = Join-Path $sb 'rec-codex-usage'
$cuWas = @{}
foreach ($n in 'FAKE_RECORD', 'FAKE_APPSERVER', 'FAKE_SCENARIO', 'FAKE_SLEEP', 'FAKE_VERSION') { $cuWas[$n] = [Environment]::GetEnvironmentVariable($n) }
$cuSeamWas = $script:ChatOverlayCodexUsageSeam
$cuVerWas = $script:ChatqCliVersions.Clone()
# the real answer, as 0.159.2 gave it on a free plan (S-A4), its account id scrubbed
$cuFix = [System.IO.File]::ReadAllText((Join-Path $here 'fixtures\usage\codex-ratelimits.json'), $utf8) | ConvertFrom-Json
$cuA = ConvertFrom-ChatqCodexRateLimitsReply $cuFix
Check 'codex usage: the app-server''s answer read - a free plan''s one window is a month, with its plan and its yes' (
    $cuA -and @($cuA.Limits).Count -eq 1 -and $cuA.Limits[0].Label -eq 'month' -and $cuA.Limits[0].Type -eq 'monthly' -and $cuA.Limits[0].Minutes -eq 43200 -and
    $cuA.Limits[0].Percent -eq 0 -and $cuA.Limits[0].ResetsAt -eq [DateTimeOffset]::FromUnixTimeSeconds(1793507078).LocalDateTime -and
    $cuA.PlanType -eq 'free' -and $cuA.Allowed -eq $true -and $cuA.Credits -eq $false -and $null -eq $cuA.Reached) "$($cuA | ConvertTo-Json -Depth 4 -Compress)"
$cuBy = '{"rateLimits":{"primary":null,"secondary":null},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":40},"secondary":{"usedPercent":12},"planType":"plus","credits":{"hasCredits":true}}}}' | ConvertFrom-Json
$cuB = ConvertFrom-ChatqCodexRateLimitsReply $cuBy
$cuNone = ConvertFrom-ChatqCodexRateLimitsReply ('{"rateLimits":{"primary":null,"secondary":null}}' | ConvertFrom-Json)
Check 'codex usage: windows with no length named by place - primary 5h, secondary week - the codex bucket standing in, credits said; no window, no answer' (
    $cuB -and (@($cuB.Limits | ForEach-Object Label) -join ',') -eq '5h,week' -and (@($cuB.Limits | ForEach-Object Type) -join ',') -eq 'five_hour,weekly' -and
    $cuB.PlanType -eq 'plus' -and $cuB.Credits -and $null -eq $cuB.Allowed -and $null -eq $cuNone) "$($cuB | ConvertTo-Json -Depth 4 -Compress)"
# a rollout's snake_case windows by length too: a month is no 5 h window
$cuSnake = @(ConvertFrom-ChatqCodexLimits ('{"primary":{"used_percent":3,"window_minutes":43200,"resets_at":1793507078}}' | ConvertFrom-Json))
Check 'codex usage: a 43200-minute window from a rollout reads month as well' ($cuSnake.Count -eq 1 -and $cuSnake[0].Label -eq 'month' -and $cuSnake[0].Type -eq 'monthly') "$($cuSnake | ConvertTo-Json -Compress)"
# a probe's own answers: one fixture folder per case, under the sandbox
$cuDir = Join-Path $sb 'appserver-probe'
$null = New-Item -ItemType Directory -Path $cuDir -Force
$cuAnswer = { param([string]$primary, [string]$extra)
    $body = '{"result":{"ordinaryUsageAllowed":true,"rateLimits":{"limitId":"codex","primary":' + $primary + ',"secondary":null,"credits":{"hasCredits":false,"unlimited":false,"balance":null},"planType":"plus","rateLimitReachedType":null' + $extra + '}}}'
    [System.IO.File]::WriteAllText((Join-Path $cuDir 'account_rateLimits_read.json'), $body, $utf8)
}
$cuJob = [pscustomobject]@{ id = 'cu-probe'; seq = 0; provider = 'codex'; kind = 'prompt'; sessionId = $cxId; cwd = $sb; home = $codexHome; title = 'x'; model = $null; runModel = $null }
$cuArgv = { $f = Join-Path $cuRec 'argv.txt'; if (Test-Path -LiteralPath $f) { [System.IO.File]::ReadAllText($f) -replace "`n", ' ' } else { '' } }
try {
    $env:FAKE_RECORD = $cuRec
    $env:FAKE_APPSERVER = Join-Path $here 'fixtures\appserver'
    Remove-Item env:FAKE_SCENARIO -EA SilentlyContinue

    # the overlay's fetch, the real path: started, taken in a pass at a time
    $script:ChatOverlayCodexUsageSeam = $null
    $cf = Start-ChatqCodexUsageFetch $codexHome
    $cfFirst = Complete-ChatqCodexUsageFetch $cf 0
    $cfRes = Complete-ChatqCodexUsageFetch $cf 15000
    $cfPid = [int]([System.IO.File]::ReadAllText((Join-Path $cuRec 'pid.txt')))
    $cfSent = @([System.IO.File]::ReadAllLines((Join-Path $cuRec 'appserver.jsonl'), $utf8) | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json } |
            ForEach-Object { if ($_.PSObject.Properties['method']) { $_.method } }) -join ','
    Start-Sleep -Milliseconds 500
    Check 'codex usage fetch: nothing yet on a pass that waits for nothing, then the month and the plan - three messages sent, the server gone' (
        $null -eq $cfFirst -and $cfRes.Ok -and @($cfRes.Windows)[0].Label -eq 'month' -and $cfRes.PlanType -eq 'free' -and
        $cfSent -eq 'initialize,initialized,account/rateLimits/read' -and -not (Get-Process -Id $cfPid -EA SilentlyContinue) -and
        [object]::ReferenceEquals((Complete-ChatqCodexUsageFetch $cf 0), $cfRes)) "$($cfRes | ConvertTo-Json -Depth 4 -Compress) / $cfSent"
    # an error is a failure to log; no home is a quiet one
    $env:FAKE_APPSERVER = $cuDir
    Remove-Item -LiteralPath (Join-Path $cuDir 'account_rateLimits_read.json') -Force -EA SilentlyContinue
    $cfErr = Complete-ChatqCodexUsageFetch (Start-ChatqCodexUsageFetch $codexHome) 15000
    $cfNoHome = Complete-ChatqCodexUsageFetch (Start-ChatqCodexUsageFetch (Join-Path $sb 'codex-not-there')) 0
    Check 'codex usage fetch: an error said and not quiet; a home that is not there quiet' (
        -not $cfErr.Ok -and -not $cfErr.Quiet -and $cfErr.Why -like 'codex app-server: fake app-server: no fixture*' -and
        -not $cfNoHome.Ok -and $cfNoHome.Quiet -and $cfNoHome.Why -like 'codex app-server: no Codex home at *') "$($cfErr.Why) / $($cfNoHome.Why)"

    # the floor: a codex older than it is never started for this, and
    # quietly - its version read again before the refusal, as the fake's
    # --version says it. That --version run writes pid.txt as any run of
    # the fake does; appserver.jsonl is written by app-server alone, so it
    # is what says one was started
    $cuExe = Find-ChatqExe codex
    $script:ChatqCliVersions[$cuExe] = '0.150.0'
    $env:FAKE_VERSION = 'codex-cli 0.150.0'
    Remove-Item -LiteralPath $cuRec -Recurse -Force -EA SilentlyContinue
    $cuOld = Invoke-ChatqCodexRpc -Method 'account/rateLimits/read' -CodexHome $codexHome
    $cuOldF = Complete-ChatqCodexUsageFetch (Start-ChatqCodexUsageFetch $codexHome) 0
    $cuOldStarted = Test-Path -LiteralPath (Join-Path $cuRec 'appserver.jsonl')
    # upgraded in place since - npm keeps the path - with the old version
    # still cached: seen, and started, with no restart
    $script:ChatqCliVersions[$cuExe] = '0.150.0'
    $env:FAKE_VERSION = 'codex-cli 0.160.0'
    $cuUp = Invoke-ChatqCodexRpc -Method 'account/rateLimits/read' -CodexHome $codexHome
    $cuUpStarted = Test-Path -LiteralPath (Join-Path $cuRec 'appserver.jsonl')
    $cuUpCached = $script:ChatqCliVersions[$cuExe]
    Remove-Item env:FAKE_VERSION
    $script:ChatqCliVersions = $cuVerWas.Clone()
    Check 'app-server: a codex older than the floor is not started - said, and quiet to the overlay' (
        -not $cuOld.Ok -and $cuOld.Why -eq "codex 0.150.0 is older than $($script:ChatqCodexAppServerMin)" -and -not $cuOldStarted -and
        $cuOldF.Quiet -and -not $cuOldF.Ok) "$($cuOld.Why) / $($cuOldF.Why) / started $cuOldStarted"
    Check 'app-server: a codex upgraded in place is seen though its old version was cached - started, the cache moved on' (
        $cuUpStarted -and $cuUp.Why -notlike '*is older than*' -and $cuUpCached -eq '0.160.0') "$($cuUp.Why) / started $cuUpStarted / cached $cuUpCached"

    # -CodexUsage off with an ask out: nothing takes that ask in any more,
    # so the pass ends it - else the server lived as long as the overlay
    # and the refresh icon turned for good
    $env:FAKE_SLEEP = '30'
    Remove-Item -LiteralPath $cuRec -Recurse -Force -EA SilentlyContinue
    $cOffF = New-ChatOverlayContext -CodexHome $codexHome
    $cOffF.Config.liveUsage = $false
    $cOffF.Config.copilotUsage = $false
    $cOffF.CodexListAt = Get-Date
    $cOffF.CodexAt = Get-Date
    $cOffF.CodexFiles = @()
    $cOffF.CodexFetch = Start-ChatqCodexUsageFetch $codexHome
    $cOffRpc = $cOffF.CodexFetch.Rpc
    $cOffPid = $cOffRpc.Pid
    $cOffF.Config.codexUsage = $false
    $null = Update-ChatOverlayUsage $cOffF $false
    Start-Sleep -Milliseconds 500
    Remove-Item env:FAKE_SLEEP
    Check 'codex usage turned off with an ask out: the ask dropped and its server ended' (
        $null -eq $cOffF.CodexFetch -and $cOffRpc.Done -and $cOffRpc.Done.Why -eq 'turned off' -and $cOffPid -and -not (Get-Process -Id $cOffPid -EA SilentlyContinue)) (
        "$($cOffF.CodexFetch) / $(if ($cOffRpc.Done) { $cOffRpc.Done.Why }) / $cOffPid")

    # the probe: a window at 100% whose reset is ahead - limited, no turn
    $cuReset = [DateTimeOffset]::UtcNow.AddHours(3).ToUnixTimeSeconds()
    & $cuAnswer ('{"usedPercent":100,"windowDurationMins":300,"resetsAt":' + $cuReset + '}') ''
    Remove-Item -LiteralPath $cuRec -Recurse -Force -EA SilentlyContinue
    $cuP = Invoke-ChatqProbe 'codex' $cuJob
    $cuPArgv = & $cuArgv
    Check 'the Codex probe asks the account first: a full window ahead is limited until its reset, and no turn is run' (
        $cuP.Limited -and -not $cuP.Allowed -and $cuP.NoTurn -and $cuP.Type -eq 'five_hour' -and
        [Math]::Abs(($cuP.Until - [DateTimeOffset]::FromUnixTimeSeconds($cuReset).LocalDateTime).TotalSeconds) -lt 2 -and
        $cuP.Detail -like 'account/rateLimits/read: 5h window at 100%*' -and $cuPArgv -match 'app-server' -and $cuPArgv -notmatch 'exec') "$($cuP | ConvertTo-Json -Compress) / $cuPArgv"
    # a limit the server says is reached, under 100%: limited, with no reset to name
    & $cuAnswer '{"usedPercent":40,"windowDurationMins":10080,"resetsAt":null}' ''
    $body = [System.IO.File]::ReadAllText((Join-Path $cuDir 'account_rateLimits_read.json'), $utf8).Replace('"rateLimitReachedType":null', '"rateLimitReachedType":"rate_limit_reached"')
    [System.IO.File]::WriteAllText((Join-Path $cuDir 'account_rateLimits_read.json'), $body, $utf8)
    $cuR = Invoke-ChatqProbe 'codex' $cuJob
    Check 'the Codex probe: a limit the server says is reached is limited, its kind kept, no turn' (
        $cuR.Limited -and $cuR.NoTurn -and $null -eq $cuR.Until -and $cuR.Type -eq 'rate_limit_reached') "$($cuR | ConvertTo-Json -Compress)"
    # unclear - room left, or credits to carry past a full window: the turn decides
    $env:FAKE_SCENARIO = Join-Path $here 'fixtures\stream\codex-done.jsonl'
    & $cuAnswer '{"usedPercent":12,"windowDurationMins":300,"resetsAt":null}' ''
    Remove-Item -LiteralPath $cuRec -Recurse -Force -EA SilentlyContinue
    $cuU = Invoke-ChatqProbe 'codex' $cuJob
    $cuUArgv = & $cuArgv
    & $cuAnswer ('{"usedPercent":100,"windowDurationMins":300,"resetsAt":' + $cuReset + '}') ''
    $body = [System.IO.File]::ReadAllText((Join-Path $cuDir 'account_rateLimits_read.json'), $utf8).Replace('"hasCredits":false', '"hasCredits":true')
    [System.IO.File]::WriteAllText((Join-Path $cuDir 'account_rateLimits_read.json'), $body, $utf8)
    Remove-Item -LiteralPath $cuRec -Recurse -Force -EA SilentlyContinue
    $cuC = Invoke-ChatqProbe 'codex' $cuJob
    $cuCArgv = & $cuArgv
    Check 'the Codex probe: room left, or credits past a full window, leaves it to the turn - never "allowed" on the figures alone' (
        $cuU.Allowed -and -not (Get-ChatField $cuU 'NoTurn') -and $cuUArgv -match 'exec' -and
        $cuC.Allowed -and -not (Get-ChatField $cuC 'NoTurn') -and $cuCArgv -match 'exec') "$($cuU.Allowed) $cuUArgv / $($cuC.Allowed) $cuCArgv"
}
finally {
    foreach ($n in $cuWas.Keys) { [Environment]::SetEnvironmentVariable($n, $cuWas[$n]) }
    $script:ChatOverlayCodexUsageSeam = $cuSeamWas
    $script:ChatqCliVersions = $cuVerWas
    Remove-Item -LiteralPath $cuDir -Recurse -Force -EA SilentlyContinue
}
