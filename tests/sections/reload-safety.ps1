# tests/sections/reload-safety.ps1: dot-sourced by tests/run-tests.ps1 in its turn,
# never on its own - it uses what the runner and the sections before it set.

Section 'reload while a chat works'
# A project of its own: every chat in projA was written to just now by the
# sections above, which is "active" on its own.
$projW = Join-Path $work 'projW'
$null = New-Item -ItemType Directory -Path $projW -Force
$idW1 = 'abababab-abab-4bab-8bab-abababababab'
$idW2 = 'cdcdcdcd-cdcd-4dcd-8dcd-cdcdcdcdcdcd'
$pW1 = New-FakeChat $projW $idW1 'Workflow host chat' 2 @('run the review workflow')
$null = New-FakeChat $projW $idW2 'Quiet neighbour chat' 3 @('nothing much')
$null = @(Sync-ChatIndex)
function Add-ChatRecord([string]$Path, $Record, [double]$MinutesAgo) {
    # one transcript record as Claude Code writes it: Node's JSON.stringify
    # leaves < > & ' alone, where 5.1's ConvertTo-Json escapes them
    $Record['timestamp'] = (Get-Date).ToUniversalTime().AddMinutes(-$MinutesAgo).ToString('o')
    $Record['sessionId'] = $idW1
    $u = [string][char]92 + 'u00'
    $j = ($Record | ConvertTo-Json -Compress -Depth 8).Replace("${u}3c", '<').Replace("${u}3e", '>').Replace("${u}26", '&').Replace("${u}27", "'")
    [System.IO.File]::AppendAllText($Path, $j + "`n", $utf8)
}
function Add-ChatLaunch([string]$Tool, $Result, [double]$MinutesAgo) {
    # the call, its result, and the turn ending straight after - the shape of
    # a turn that sends work to the background
    $use = 'toolu_' + [guid]::NewGuid().ToString('N')
    Add-ChatRecord $pW1 ([ordered]@{ type = 'assistant'; message = [ordered]@{ role = 'assistant'; stop_reason = 'tool_use'
                content = @([ordered]@{ type = 'tool_use'; id = $use; name = $Tool; input = @{} }) } }) $MinutesAgo
    Add-ChatRecord $pW1 ([ordered]@{ type = 'user'; message = [ordered]@{ role = 'user'
                content = @([ordered]@{ tool_use_id = $use; type = 'tool_result'; content = "$Tool launched in background" }) }
            toolUseResult = $Result }) $MinutesAgo
    Add-ChatRecord $pW1 ([ordered]@{ type = 'assistant'; message = [ordered]@{ role = 'assistant'; stop_reason = 'end_turn'
                content = @([ordered]@{ type = 'text'; text = 'Running in the background.' }) } }) $MinutesAgo
}
function Add-ChatNotification([string]$TaskId, [double]$MinutesAgo) {
    Add-ChatRecord $pW1 ([ordered]@{ type = 'user'; origin = @{ kind = 'task-notification' }
            message = [ordered]@{ role = 'user'; content = "<task-notification>`n<task-id>$TaskId</task-id>`n<status>completed</status>`n<summary>finished</summary>`n</task-notification>" } }) $MinutesAgo
    Add-ChatRecord $pW1 ([ordered]@{ type = 'assistant'; message = [ordered]@{ role = 'assistant'; stop_reason = 'end_turn'
                content = @([ordered]@{ type = 'text'; text = 'Done.' }) } }) $MinutesAgo
}
function Set-Quiet { (Get-Item -LiteralPath $pW1).LastWriteTime = (Get-Date).AddMinutes(-2) }   # past the 60 s layer
function Set-Live([string]$Status = 'idle', [double]$StartedMinutesAgo = 60) {
    $at = [DateTimeOffset]::UtcNow.AddMinutes(-$StartedMinutesAgo).ToUnixTimeMilliseconds()
    $env:FAKE_AGENTS = '[{"pid":1,"sessionId":"' + $idW1 + '","kind":"interactive","status":"' + $Status + '","startedAt":' + $at + '}]'
}

Remove-Item env:FAKE_AGENTS -EA SilentlyContinue
Check 'a project whose chats have all finished is idle' ((Test-ChatIdle -Cwd $projW) -eq $true)
Set-Live 'busy'
Check 'a chat Claude calls busy is active, though its transcript reads finished' ((Test-ChatIdle -Cwd $projW) -eq $false)
Set-Live 'waiting'
Check 'and so is one waiting on a permission prompt' ((Test-ChatIdle -Cwd $projW) -eq $false)

Add-ChatLaunch 'Workflow' ([ordered]@{ status = 'async_launched'; taskId = 'wtask0001'; taskType = 'local_workflow'; workflowName = 'review'; runId = 'wf_test-0001' }) 30
Set-Quiet
Set-Live 'idle'
Check 'a workflow still running after its turn ended keeps the chat active' ((Test-ChatIdle -Cwd $projW) -eq $false -and (Test-ChatTranscriptBusy $pW1) -ne $true)
Remove-Item env:FAKE_AGENTS
Check 'with the chat''s process gone, its workflow is gone too' ((Test-ChatIdle -Cwd $projW) -eq $true)
Set-Live 'idle' 10
Check 'one started before the chat was last opened died with the old process' ((Test-ChatIdle -Cwd $projW) -eq $true)
Add-ChatNotification 'wtask0001' 20
Set-Quiet
Set-Live 'idle'
Check 'its task-notification ends it' ((Test-ChatIdle -Cwd $projW) -eq $true)

Add-ChatLaunch 'Agent' ([ordered]@{ isAsync = $true; status = 'async_launched'; agentId = 'aagent0001'; description = 'map it' }) 15
Set-Quiet
Check 'a background agent keeps it active' ((Test-ChatIdle -Cwd $projW) -eq $false)
Add-ChatNotification 'aagent0001' 12
Set-Quiet
$quiet = (Test-ChatIdle -Cwd $projW) -eq $true
Add-ChatLaunch 'SendMessage' ([ordered]@{ success = $true; message = 'Resuming agent aagent0'; resumedAgentId = 'aagent0001' }) 10
Set-Quiet
Check 'until it reports; SendMessage waking it makes it active again' ($quiet -and (Test-ChatIdle -Cwd $projW) -eq $false)
Add-ChatNotification 'aagent0001' 8
Add-ChatLaunch 'Bash' ([ordered]@{ stdout = ''; stderr = ''; interrupted = $false; backgroundTaskId = 'bshell0001' }) 5
Set-Quiet
Check 'a background shell does not count - it may be a server that never ends' ((Test-ChatIdle -Cwd $projW) -eq $true)
# a tab a reload brought back: Claude writes its transcript as the process
# starts or ends - records with no timestamp, no turn. Not live
[System.IO.File]::AppendAllText($pW1, '{"type":"cost-state","sessionId":"' + $idW1 + '"}' + "`n", $utf8)
(Get-Item -LiteralPath $pW1).LastWriteTime = Get-Date
Check 'a chat only touched this minute, by a record with no turn in it, is not live' ((Test-ChatIdle -Cwd $projW) -eq $true)
# the chat a queued run just wrote reads live for a minute; that alone must
# not stop its window reloading by itself
Add-ChatRecord $pW1 ([ordered]@{ type = 'assistant'; message = [ordered]@{ role = 'assistant'; stop_reason = 'end_turn'
            content = @([ordered]@{ type = 'text'; text = 'Answered.' }) } }) 0
Check 'a chat written this minute is live - unless it is the one the run wrote' ((Test-ChatIdle -Cwd $projW) -eq $false -and (Test-ChatIdle -Cwd $projW -Except $pW1) -eq $true)
# but what Claude says of that chat's own open process still counts: after
# the run it can only be a window's, and that may be mid-answer
Set-Live 'busy'
Check 'the run''s own chat busy in a window still counts' ((Test-ChatIdle -Cwd $projW -Except $pW1) -eq $false)
Remove-Item env:FAKE_AGENTS
# a chat written minutes ago is someone's, at the PC or from the phone
$pW2 = Join-Path (Join-Path (Join-Path $claudeHome 'projects') (Get-Slug $projW)) "$idW2.jsonl"
$w2Was = (Get-Item -LiteralPath $pW2).LastWriteTime
# its turn, asked and answered, so its transcript alone reads finished
$w2At = (Get-Date).ToUniversalTime().AddMinutes(-3).ToString('o')
$w2Turn = [ordered]@{ type = 'user'; message = [ordered]@{ role = 'user'; content = 'from the phone' }; sessionId = $idW2; timestamp = $w2At } | ConvertTo-Json -Compress -Depth 6
$w2Done = [ordered]@{ type = 'assistant'; message = [ordered]@{ role = 'assistant'; stop_reason = 'end_turn'; content = @([ordered]@{ type = 'text'; text = 'Done.' }) }
    sessionId = $idW2; timestamp = $w2At } | ConvertTo-Json -Compress -Depth 6
[System.IO.File]::AppendAllText($pW2, $w2Turn + "`n" + $w2Done + "`n", $utf8)
(Get-Item -LiteralPath $pW2).LastWriteTime = (Get-Date).AddMinutes(-3)
Check 'a neighbour written 3 min ago is live over quietMinutes, not over one minute' ((Test-ChatIdle -Cwd $projW -Except $pW1 -Seconds 300) -eq $false -and (Test-ChatIdle -Cwd $projW -Except $pW1) -eq $true)
(Get-Item -LiteralPath $pW2).LastWriteTime = $w2Was
# the common case: a folder with one chat, the one the run wrote
$projOne = Join-Path $work 'projOne'
$null = New-Item -ItemType Directory -Path $projOne -Force
$pOne = New-FakeChat $projOne 'cdcdcdcd-cdcd-4cdc-8cdc-cdcdcdcdcdcd' 'The only chat here' 1 @('hello')
$null = @(Sync-ChatIndex)
(Get-Item -LiteralPath $pOne).LastWriteTime = Get-Date
Check 'a folder whose only chat is the one the run wrote is idle, not unjudged' ((Test-ChatIdle -Cwd $projOne -Except $pOne) -eq $true)
Set-Quiet
# and end to end: a queued run into that chat, open and idle in a window,
# with nobody at the PC - the one case the window reloads by itself
$jw = New-TestJob 'Workflow host chat' 'one more pass'
Set-Live 'idle'
(Get-Item -LiteralPath $pW1).LastWriteTime = Get-Date
Invoke-ChatqJob (New-ChatqWatchState) (Find-ChatqJob $jw.id)
$rqW = [System.IO.File]::ReadAllText($script:ChatReloadPath, $utf8) | ConvertFrom-Json
Check 'a run into a quiet folder asks for the reload it may take by itself' ($rqW.kind -eq 'ran' -and $rqW.away -eq $true -and $rqW.busy -eq $false) "$($rqW.kind) away=$($rqW.away) busy=$($rqW.busy)"
Set-Quiet

# the request the window reads carries the verdict. Write-ChatGhostAdvice
# speaks only while a VS Code window is up, so one is made to look up.
function Get-Process {
    [CmdletBinding()] param([string[]]$Name, [int[]]$Id)
    if ($Name) { return [pscustomobject]@{ Name = 'Code' } }
    Microsoft.PowerShell.Management\Get-Process @PSBoundParameters
}
Push-Location -LiteralPath $projW
Set-Live 'busy'
Write-ChatGhostAdvice -Title 'Gone chat' *> $null
$rqBusy = [System.IO.File]::ReadAllText($script:ChatReloadPath, $utf8) | ConvertFrom-Json
Set-Live 'idle'
Write-ChatGhostAdvice -Title 'Gone chat' *> $null
$rqIdle = [System.IO.File]::ReadAllText($script:ChatReloadPath, $utf8) | ConvertFrom-Json
Pop-Location
Remove-Item function:Get-Process
Remove-Item env:FAKE_AGENTS
Check 'the reload request says whether a chat was working' ($rqBusy.busy -eq $true -and $rqIdle.busy -eq $false -and $rqBusy.kind -eq 'deleted') "$($rqBusy.busy) $($rqIdle.busy)"
