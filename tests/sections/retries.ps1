# tests/sections/retries.ps1: dot-sourced by tests/run-tests.ps1 in its turn,
# never on its own - it uses what the runner and the sections before it set.

Section 'retries and failures'
$o = Invoke-Scenario 'network'
Check 'a dropped connection -> network, not failed' ($o.kind -eq 'network') "$($o.kind) $($o.reason)"
$o = Invoke-Scenario 'auth'
Check 'an expired login -> auth, in the API''s own words' ($o.kind -eq 'auth' -and $o.reason -ceq 'login refused: OAuth token has expired. (401)') "$($o.kind) $($o.reason)"
# a subscription that ran out: a 403, not a login gone, and the words say so
$o = Invoke-Scenario 'auth-403'
$planWords = "This account$([char]0x2019)s plan does not include Claude Code. (403)"
Check 'a 403 -> auth, its message kept, not "logged out"' ($o.kind -eq 'auth' -and $o.reason -ceq "login refused: $planWords") "$($o.kind) $($o.reason)"
$w = Get-ChatqAuthWords 'API Error: 403 {"error":{"message":"Plan \"Max\" ended \u2014 renew"}}'
Check 'the message read out of the JSON, escapes and all, the code from the text' ($w -ceq "Plan `"Max`" ended $([char]0x2014) renew (403)") $w
$w = Get-ChatqAuthWords "Invalid API key`n  Please run /login" 401
Check 'no JSON: the text itself, one line' ($w -ceq 'Invalid API key Please run /login') $w
$w = Get-ChatqAuthWords ('x' * 400)
Check 'and cut short' ($w.Length -eq 160 -and $w.EndsWith($script:ChatqEllipsis)) $w.Length
Check 'nothing said at all still says something' ((Get-ChatqAuthWords '' 403) -ceq 'API Error 403' -and (Get-ChatqAuthWords '') -ceq 'no reason given')
$w = Get-ChatqAuthWords (('[warn] retrying ' * 20) + 'OAuth token has expired. Please run /login')
Check 'log noise ahead of the refusal does not crowd it out' ($w -ceq "$($script:ChatqEllipsis)OAuth token has expired. Please run /login") $w
# no result line: $text is the last reply, and a reply is never the refusal
$st = New-ChatqRunState
$st.LastText = 'Here is the payload: {"message":"hello"}'
$o = Get-ChatqClaudeOutcome $st ([pscustomobject]@{ ExitCode = 1; StdErr = 'OAuth token has expired. Please run /login'; Stopped = $null }) 'auto'
Check 'the words come from the error, never from the chat''s reply' ($o.kind -eq 'auth' -and $o.reason -ceq 'login refused: OAuth token has expired. Please run /login') "$($o.kind) $($o.reason)"
$o = Invoke-CodexScenario 'codex-auth'
Check 'codex refused -> auth, its message and "unexpected status" code kept' ($o.kind -eq 'auth' -and $o.reason -ceq 'login refused: Your refresh token has expired. Please sign in again. (401)') "$($o.kind) $($o.reason)"
Check 'and the error text whole beside it' ($o.detail -like 'unexpected status 401 Unauthorized: {"error":{"message":"Your refresh token*"code":"refresh_token_expired"}}') $o.detail
$o = Invoke-CodexScenario 'codex-network'
Check 'codex "stream disconnected" -> network' ($o.kind -eq 'network') "$($o.kind) $($o.reason)"
# Codex's 5xx and capacity words, as codex-cli 0.159.2 has them: overloaded,
# waited out as an outage - a 400 stays failed, and so does a turn that
# failed for its own reason while stderr's noise held a 500
$ovHigh = Invoke-CodexScenario 'codex-overload'
$ovCap = Invoke-CodexScenario 'codex-capacity'
$ov5 = Invoke-CodexScenario 'codex-5xx'
Check 'codex high demand, a model at capacity, "last status: 503" -> overloaded, in Codex''s own words' (
    $ovHigh.kind -eq 'overloaded' -and $ovHigh.reason -like 'We*re currently experiencing high demand*' -and
    $ovCap.kind -eq 'overloaded' -and $ovCap.reason -ceq 'Selected model is at capacity. Please try a different model.' -and
    $ov5.kind -eq 'overloaded' -and $ov5.reason -ceq 'exceeded retry limit, last status: 503 Service Unavailable') "$($ovHigh.kind) $($ovHigh.reason) / $($ovCap.kind) / $($ov5.kind) $($ov5.reason)"
$ov400 = Invoke-CodexScenario 'codex-badrequest'
$ovCtx = Invoke-CodexScenario $null 'ERROR rmcp: resource metadata probe returned unexpected status: 500 Internal Server Error; server_error' 'Codex ran out of room in the model''s context window. Start a new thread or clear earlier history before retrying.'
$ovErr = Invoke-CodexScenario $null "2026-09-30T10:00:01Z  WARN codex_core::models_manager: failed to refresh available models: timeout`nError: exceeded retry limit, last status: 502 Bad Gateway"
# a run that failed with no turn.failed - a resume whose rollout is gone,
# an exit before thread.started - while a models refresh logged a 503
$ovNoise = Invoke-CodexScenario $null "2026-09-30T10:00:01Z ERROR codex_core::models_manager: failed to refresh available models: unexpected status 503 Service Unavailable`nError: thread/resume failed: no rollout found for thread id 0199"
Check 'a 400 stays failed; a context-window failure with a 500 in stderr''s noise stays failed; with no turn.failed, only stderr''s own Error: line is read, and is the reason' (
    $ov400.kind -eq 'failed' -and $ov400.reason -like 'unexpected status 400 Bad Request*' -and
    $ovCtx.kind -eq 'failed' -and $ovCtx.reason -like 'Codex ran out of room*' -and
    $ovErr.kind -eq 'overloaded' -and $ovErr.reason -ceq 'exceeded retry limit, last status: 502 Bad Gateway' -and
    $ovNoise.kind -eq 'failed') "$($ov400.kind) / $($ovCtx.kind) $($ovCtx.reason) / $($ovErr.kind) $($ovErr.reason) / $($ovNoise.kind) $($ovNoise.reason)"
$ovAuth = Invoke-CodexScenario 'codex-5xx' 'unexpected status 401 Unauthorized: {"error":{"message":"Your refresh token has expired. Please sign in again."}}'
$ovLim = Invoke-CodexScenario 'codex-limit'
$ovStop = Get-ChatqCodexOutcome (& { $s = New-ChatqRunState; $s.Failed = 'exceeded retry limit, last status: 503'; $s }) ([pscustomobject]@{ ExitCode = 1; StdErr = ''; Stopped = 'timeout' })
Check 'a refused login still beats a 5xx, the usage limit still beats everything, and chatq''s own stop is no overload' (
    $ovAuth.kind -eq 'auth' -and $ovLim.kind -eq 'limited' -and $ovStop.kind -eq 'failed' -and $ovStop.reason -eq 'timeout') "$($ovAuth.kind) / $($ovLim.kind) / $($ovStop.kind) $($ovStop.reason)"
$o = Get-ChatqClaudeOutcome (New-ChatqRunState) ([pscustomobject]@{ ExitCode = 1; StdErr = 'ECONNRESET'; Stopped = 'timeout' }) 'auto'
Check 'chatq''s own time limit is never taken for a network drop' ($o.kind -eq 'failed' -and $o.reason -eq 'timeout') "$($o.kind) $($o.reason)"

$pDead = Join-Path (Join-Path (Join-Path $claudeHome 'projects') (Get-Slug $projA)) "$idDead.jsonl"
$env:FAKE_RECORD = $rec
$j = New-TestJob 'Deadline notes' 'survive the drop'
$env:FAKE_SCENARIO = Join-Path $here 'fixtures\stream\network.jsonl'
$env:FAKE_LAND = $pDead
$Wn = New-ChatqWatchState
Invoke-ChatqJob $Wn (Find-ChatqJob $j.id)
$j = Find-ChatqJob $j.id
$ra = ConvertTo-ChatqDate $j.retryAt
$inS = if ($ra) { ($ra - (Get-Date)).TotalSeconds } else { -1 }
Check 'network drop -> queued again, a minute out' ($j.state -eq 'queued' -and $inS -gt 30 -and $inS -lt 90) "$($j.state) in $inS s"
Check 'the landed prompt comes back as a continue that is always sent' ($j.retryAs -eq 'continue' -and -not $j.autoContinue -and [int]$j.netRetries -eq 1) "$($j.retryAs) $($j.autoContinue) $($j.netRetries)"
Check 'the watcher will not pick it before then' ($null -ne (Get-ChatqDueTime $Wn $j (Get-Date)))
foreach ($k in 2, 3, 4) { Invoke-ChatqJob $Wn (Find-ChatqJob $j.id) }
$j = Find-ChatqJob $j.id
Check 'three retries, then it fails' ($j.state -eq 'failed' -and $j.result.reason -like '*gave up after 3*') "$($j.state) $($j.result.reason)"
Remove-Item env:FAKE_SCENARIO, env:FAKE_LAND

$cfg0 = Get-ChatqConfig
Set-ChatqProp $cfg0 'maxRetries' 2
Save-ChatqJson $script:ChatqConfigPath $cfg0
$j = New-TestJob 'Many prompts chat' 'try twice'
$Wc = New-ChatqWatchState
$env:FAKE_SCENARIO = Join-Path $here 'fixtures\stream\rejected.jsonl'
Invoke-ChatqJob $Wc (Find-ChatqJob $j.id)
$j1 = Find-ChatqJob $j.id
Check 'a run cut off before any reply counts toward the cap' ($j1.state -eq 'queued' -and [int]$j1.noProgress -eq 1) "$($j1.state) $($j1.noProgress)"
$env:FAKE_SCENARIO = Join-Path $here 'fixtures\stream\weekly-synthetic.jsonl'
Invoke-ChatqJob $Wc (Find-ChatqJob $j.id)
$j1 = Find-ChatqJob $j.id
Check 'one that got a reply first starts the count over' ($j1.state -eq 'queued' -and [int]$j1.noProgress -eq 0) "$($j1.state) $($j1.noProgress)"
$env:FAKE_SCENARIO = Join-Path $here 'fixtures\stream\rejected.jsonl'
Invoke-ChatqJob $Wc (Find-ChatqJob $j.id)
Invoke-ChatqJob $Wc (Find-ChatqJob $j.id)
$j1 = Find-ChatqJob $j.id
Check 'maxRetries in a row with no reply -> gave up' ($j1.state -eq 'failed' -and $j1.result.reason -like 'gave up*') "$($j1.state) $($j1.result.reason)"
$cfg0.PSObject.Properties.Remove('maxRetries')
Save-ChatqJson $script:ChatqConfigPath $cfg0

$env:FAKE_SCENARIO = Join-Path $here 'fixtures\stream\auth.jsonl'
$Wa = New-ChatqWatchState
$ja = [pscustomobject]@{ id = 'auth-x'; provider = 'claude'; home = $null; model = 'claude-opus-5'; runModel = $null; cwd = $projA; title = 'x'; seq = 99 }
$a0 = Get-AlertCount '*login refused*'
$ok = Confirm-ChatqAllowed $Wa $ja
Check 'a login gone: the lane waits and its jobs stay queued' (-not $ok -and $Wa.blocked[(Get-ChatqLane $ja)].Type -eq 'login needed') "$ok $($Wa.blocked['claude'].Type)"
$null = Confirm-ChatqAllowed $Wa $ja
Check 'with one alert, not one per probe' ((Get-AlertCount '*login refused*') -eq $a0 + 1)
Check 'which quotes the API and names both ways out' ((Get-AlertCount '*login refused: OAuth token has expired. (401)*/login, or check the subscription*') -eq 1)
$wlog = [System.IO.File]::ReadAllText((Join-Path $script:ChatqLogDir 'watcher.log'), $utf8)
Check 'the watcher log keeps the same words' ($wlog -like '*claude login refused: OAuth token has expired. (401)*')
Check 'and the error text whole, type and all' ($wlog -like '*claude error text: Failed to authenticate. API Error: 401 {"type":"error","error":{"type":"authentication_error",*')
Check 'and so does the status line' ((Get-ChatqStatusLine @() $Wa.blocked) -like '*Claude login refused: OAuth token has expired. (401) - log in or check the subscription*') (Get-ChatqStatusLine @() $Wa.blocked)
$old = @{ claude = [pscustomobject]@{ Until = (Get-Date).AddMinutes(9); Type = 'login needed'; Source = 'probe' } }
Check 'a watcher from before the words were kept still reads right' ((Get-ChatqStatusLine @() $old) -like '*Claude login refused - log in*') (Get-ChatqStatusLine @() $old)

# the same refusal met by a run rather than the probe
$j = New-TestJob 'Deadline notes' 'after the plan ran out'
$env:FAKE_SCENARIO = Join-Path $here 'fixtures\stream\auth-403.jsonl'
$Wp = New-ChatqWatchState
Invoke-ChatqJob $Wp (Find-ChatqJob $j.id)
$j = Find-ChatqJob $j.id
$bp = $Wp.blocked[(Get-ChatqLane $j)]
Check 'a 403 mid-run: the job waits, the lane holds what the API said' ($j.state -eq 'queued' -and $bp.Type -eq 'login needed' -and $bp.Source -ceq "login refused: $planWords") "$($j.state) $($bp.Type) $($bp.Source)"
Check 'and the job''s result says it too' ($j.result.kind -eq 'auth' -and $j.result.reason -ceq "login refused: $planWords") "$($j.result.reason)"
Check 'the alert quotes it on this path too' ((Get-AlertCount "*login refused: $planWords*check the subscription*") -eq 1)
$wlog = [System.IO.File]::ReadAllText((Join-Path $script:ChatqLogDir 'watcher.log'), $utf8)
Check 'and so does the watcher log, error type and all' ($wlog -like "*login refused: $planWords*" -and $wlog -like '*error text: API Error: 403 {"type":"error","error":{"type":"permission_error",*')
Check 'and the status line' ((Get-ChatqStatusLine @() $Wp.blocked) -like "*login refused: $planWords - log in*") (Get-ChatqStatusLine @() $Wp.blocked)
chatqrm $j.seq -Force *> $null
Remove-Item env:FAKE_SCENARIO

Set-FakeStatus 'major_outage'
$Wr = New-ChatqWatchState
$Wr.outage['claude'] = @{ Since = (Get-Date).AddHours(-7); Attempts = 3; Status = 'major_outage'; Alerted = $true; LastProbe = (Get-Date).AddMinutes(-2); NextCheck = (Get-Date).AddSeconds(-1) }
$r0 = Get-AlertCount '*still overloaded after 6 h*'
$null = Test-ChatqOutageOver $Wr $ja
$Wr.outage['claude'].NextCheck = (Get-Date).AddSeconds(-1)
$null = Test-ChatqOutageOver $Wr $ja
Check 'an outage past 6 h sends one reminder' ((Get-AlertCount '*still overloaded after 6 h*') -eq $r0 + 1)
Set-FakeStatus 'operational'

# end to end: a Codex run that met "high demand" goes back in the queue
# behind an outage of its lane - its first try a minute out, no status page
# read, and nothing it says waits on Claude
Lock-Queue { chatq 'Codex gitignore thread' -Prompt 'through the overload' *> $null }
$jov = @(Get-ChatqJobs | Where-Object { $_.provider -eq 'codex' -and (Read-ChatqPrompt $_) -eq 'through the overload' })[0]
$ovRunStatusFn = ${function:Get-ChatqClaudeStatus}
$script:OvRunReads = 0
${function:Get-ChatqClaudeStatus} = { $script:OvRunReads++; 'major_outage' }
$env:FAKE_SCENARIO = Join-Path $here 'fixtures\stream\codex-overload.jsonl'
$Wov = New-ChatqWatchState
try { Invoke-ChatqJob $Wov (Find-ChatqJob $jov.id -Exact) }
finally { ${function:Get-ChatqClaudeStatus} = $ovRunStatusFn; Remove-Item env:FAKE_SCENARIO }
$jov = Find-ChatqJob $jov.id -Exact
$ovO = $Wov.outage[(Get-ChatqLane $jov)]
$ovSaid = (@($jov.history) | ForEach-Object { [string]$_.why }) -join ' / '
Check 'a Codex run met by an overload: queued again behind its lane''s outage, a minute out, the status page never read' (
    $jov.state -eq 'queued' -and $jov.result.kind -eq 'overloaded' -and $ovO -and
    [Math]::Abs(($ovO.NextCheck - (Get-Date).AddMinutes(1)).TotalSeconds) -lt 30 -and $script:OvRunReads -eq 0) "$($jov.state) $($jov.result.kind) $(if ($ovO) { $ovO.NextCheck }) reads $($script:OvRunReads)"
Check 'and its history and alert say Codex, never Claude' (
    $ovSaid -like '*overloaded - waiting for Codex to be back*' -and $ovSaid -notmatch 'Claude|status\.claude\.com' -and
    (Get-AlertCount "*overloaded*$($jov.title)*high demand*resumes when Codex is back*") -eq 1) $ovSaid
chatqrm $jov.seq -Force *> $null
