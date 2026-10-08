# tests/sections/overlay.ps1: dot-sourced by tests/run-tests.ps1 in its turn,
# never on its own - it uses what the runner and the sections before it set.

Section 'overlay'
# Nothing reaches the network or the real process list: a stand-in for the
# usage endpoint, and one for "is that process still the session".
$script:OvFetches = 0
$liveJson = '{"five_hour":{"utilization":42.0,"resets_at":"' + $now.AddMinutes(90).ToString('o') + '"},"limits":[' +
'{"kind":"session","group":"session","percent":42,"severity":"normal","resets_at":"' + $now.AddMinutes(90).ToString('o') + '","scope":null},' +
'{"kind":"weekly_all","group":"weekly","percent":77,"severity":"warning","resets_at":"' + $now.AddDays(3).ToString('o') + '","scope":null},' +
'{"kind":"weekly_scoped","group":"weekly","percent":0,"severity":"normal","resets_at":null,"scope":{"model":{"display_name":"Opus"}}},' +
'{"kind":"weekly_scoped","group":"weekly","percent":5,"severity":"normal","resets_at":null,"scope":{"model":{"display_name":"Fable"}}}]}'
$script:ChatOverlayUsageSeam = { $script:OvFetches++; @{ Ok = $true; Status = 200; Windows = @(ConvertFrom-ChatqUtilization ($liveJson | ConvertFrom-Json)) } }
$script:ChatqAliveSeam = { param($e) $e.Pid -ne 444 }

# transcripts written the way Claude Code writes them: a last-prompt and an
# ai-title record every turn, then a few more records after them
$projO = Join-Path $work 'projO'
$null = New-Item -ItemType Directory -Path $projO -Force
function New-OverlayChat([string]$Id, [string[]]$Lines, [string]$Proj = $projO) {
    $dir = Join-Path (Join-Path $claudeHome 'projects') (Get-Slug $Proj)
    $null = New-Item -ItemType Directory -Path $dir -Force
    $path = Join-Path $dir "$Id.jsonl"
    [System.IO.File]::WriteAllText($path, ($Lines -join "`n") + "`n", $utf8)
    return $path
}
function OvUser([string]$Text) { [ordered]@{ type = 'user'; message = [ordered]@{ role = 'user'; content = $Text }; uuid = [guid]::NewGuid().ToString() } | ConvertTo-Json -Compress -Depth 5 }
function OvReply { '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}' }
function OvLast([string]$Text) { [ordered]@{ type = 'last-prompt'; lastPrompt = $Text; sessionId = 'x' } | ConvertTo-Json -Compress }
function OvTitle([string]$Text) { [ordered]@{ type = 'ai-title'; aiTitle = $Text; sessionId = 'x' } | ConvertTo-Json -Compress }
function OvTail { '{"type":"system","subtype":"turn_duration","durationMs":1234}' }
function OvPad([int]$Bytes) { '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"' + ('y' * $Bytes) + '"}]}}' }
$idO1 = '0a0a0a0a-0a0a-40a0-80a0-0a0a0a0a0a01'
$idO2 = '0a0a0a0a-0a0a-40a0-80a0-0a0a0a0a0a02'
$idO3 = '0a0a0a0a-0a0a-40a0-80a0-0a0a0a0a0a03'
$idO4 = '0a0a0a0a-0a0a-40a0-80a0-0a0a0a0a0a04'
$idO5 = '0a0a0a0a-0a0a-40a0-80a0-0a0a0a0a0a05'
$idO6 = '0a0a0a0a-0a0a-40a0-80a0-0a0a0a0a0a06'
$idO7 = '0a0a0a0a-0a0a-40a0-80a0-0a0a0a0a0a07'
$idO8 = '0a0a0a0a-0a0a-40a0-80a0-0a0a0a0a0a08'
$pO1 = New-OverlayChat $idO1 @((OvUser 'the very first ask'), (OvReply), (OvPad 3000000), (OvUser 'fix the loader'), (OvReply), (OvLast 'fix the loader'), (OvTitle 'Loader fixes'), (OvTail), (OvTail), (OvTail))
$pO2 = New-OverlayChat $idO2 @((OvUser 'a prompt from before the pad'), (OvReply), (OvPad 3000000), (OvTitle 'Deep chat'), (OvTail))
$pO3 = New-OverlayChat $idO3 @((OvUser 'the real ask'), (OvReply), (OvLast '<command-name>/compact</command-name>'), (OvTitle 'Noisy chat'), (OvTail))
$tCustom = "$tSel custom name"
$null = New-OverlayChat $idO4 @((OvUser 'rename me'), (OvReply), (OvLast 'rename me'), (OvTitle 'Auto title'),
    ([ordered]@{ type = 'custom-title'; customTitle = $tCustom; sessionId = $idO4 } | ConvertTo-Json -Compress), (OvTail))

$script:ChatOverlayBytesRead = 0
$r = Find-ChatTailRecords $pO1
Check 'the newest prompt and title come from the last 256 KB of a 3 MB chat' ($r.Prompt -eq 'fix the loader' -and $r.PromptKind -eq 'last' -and $r.AiTitle -eq 'Loader fixes' -and $script:ChatOverlayBytesRead -le 262144) "$($r.Prompt) / $($r.AiTitle) / $($script:ChatOverlayBytesRead) bytes"
$r = Find-ChatTailRecords $pO2
Check 'with no record after a 3 MB line, it reads back past it' ($r.Prompt -eq 'a prompt from before the pad' -and $r.PromptKind -eq 'user' -and $r.AiTitle -eq 'Deep chat') "$($r.Prompt) / $($r.AiTitle)"
$r = Find-ChatTailRecords $pO2 -Budget 1MB
Check 'a budget stops it, keeping the title it found' (-not $r.Prompt -and $r.AiTitle -eq 'Deep chat' -and $r.Scanned -le 1MB + 262144) "$($r.Prompt) / $($r.Scanned)"
$r = Find-ChatTailRecords $pO3
Check 'a last-prompt that is machinery falls back to the real prompt' ($r.Prompt -eq 'the real ask') $r.Prompt
# a Hangul prompt cut by the first block's edge one byte into a character
$hg = (U '\uD55C\uAE00') * 300
$lead = '{"type":"last-prompt","lastPrompt":"'
$lpLine = $lead + $hg + '","sessionId":"x"}'
$ttLine = OvTitle 'Boundary'
$fill = 262144 - ($utf8.GetByteCount($lpLine) + 1 - ($utf8.GetByteCount($lead) + 1)) - ($utf8.GetByteCount($ttLine) + 1)
$padLine = '{"type":"system","pad":"' + ('z' * ($fill - 27)) + '"}'
$pO5 = New-OverlayChat $idO5 @((OvUser 'earlier'), (OvReply), $lpLine, $ttLine, $padLine)
$r = Find-ChatTailRecords $pO5
Check 'a UTF-8 character cut by a block edge is put back together' ($r.Prompt -eq $hg -and $r.AiTitle -eq 'Boundary' -and $r.Scanned -gt 262144) "$($r.Prompt.Length) chars, $($r.Scanned) bytes"

# a slash command, the way /compact goes: taken off the queue with no record
# while it runs, then written after the fact - and the last-prompt records
# after it go on naming the prompt before. Written by hand: 5.1's
# ConvertTo-Json would escape the angle brackets Claude Code writes as is.
function OvQueue([string]$Op, [datetime]$At) { '{"type":"queue-operation","operation":"' + $Op + '","timestamp":"' + $At.ToUniversalTime().ToString('o') + '","sessionId":"x"}' }
function OvStamp($At) { if ($At) { ',"timestamp":"' + ([datetime]$At).ToUniversalTime().ToString('o') + '"' } else { '' } }
function OvCommand([string]$Name, [string]$Rest = '', $At = $null) { '{"type":"user","message":{"role":"user","content":"<command-name>/' + $Name + '</command-name>\n            <command-message>' + $Name + '</command-message>\n            <command-args>' + $Rest + '</command-args>"},"uuid":"' + [guid]::NewGuid() + '"' + (OvStamp $At) + '}' }
function OvUserAt([string]$Text, $At) { '{"type":"user","message":{"role":"user","content":"' + $Text + '"},"uuid":"' + [guid]::NewGuid() + '"' + (OvStamp $At) + '}' }
$idO9 = '0a0a0a0a-0a0a-40a0-80a0-0a0a0a0a0a09'
$tq = (Get-Date).AddSeconds(-40)
$pO9 = New-OverlayChat $idO9 @((OvUser 'continue'), (OvReply), (OvLast 'continue'), (OvTitle 'Compacting chat'), (OvTail), (OvQueue 'enqueue' $tq), (OvQueue 'dequeue' $tq))
$r = Find-ChatTailRecords $pO9
Check 'while a command runs, what it took off the queue is marked pending' ($r.Prompt -eq 'continue' -and $r.Pending -and [Math]::Abs($r.Pending - [DateTimeOffset]::new($tq).ToUnixTimeMilliseconds()) -lt 1000) "$($r.Prompt) / $($r.Pending)"
$cx9 = New-ChatOverlayContext
$s9 = [pscustomobject]@{ SessionId = $idO9; Cwd = $projO }
Update-ChatOverlayText $cx9 $s9
# a message queued meanwhile: what was added holds no dequeue, and nothing
# that ends one
[System.IO.File]::AppendAllText($pO9, (OvQueue 'enqueue' (Get-Date)) + "`n", $utf8)
Update-ChatOverlayText $cx9 $s9
Check 'and stays pending while the transcript grows by records that end nothing' (
    $cx9.Text[$idO9].Pending -and [Math]::Abs($cx9.Text[$idO9].Pending - [DateTimeOffset]::new($tq).ToUnixTimeMilliseconds()) -lt 1000) "$($cx9.Text[$idO9].Pending)"
$after = @((OvLast 'continue'), (OvTitle 'Compacting chat'), '{"type":"system","subtype":"compact_boundary","content":"Conversation compacted"}',
    '{"type":"user","isCompactSummary":true,"isVisibleInTranscriptOnly":true,"message":{"role":"user","content":"This session is being continued from a previous conversation."}}',
    '{"type":"user","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>Caveat: the messages below were generated by the user</local-command-caveat>"}}',
    (OvCommand 'compact' '' $tq), '{"type":"user","message":{"role":"user","content":"<local-command-stdout>Compacted </local-command-stdout>"}}',
    (OvLast 'continue'), (OvTitle 'Compacting chat'), (OvTail), ('{"type":"system","pad":"' + ('z' * 100000) + '"}'))
[System.IO.File]::AppendAllText($pO9, (($after -join "`n") + "`n"), $utf8)
$r = Find-ChatTailRecords $pO9
Check 'once it ends, the command is the newest thing sent - not the summary, not the prompt before' ($r.Prompt -eq '/compact' -and $r.PromptKind -eq 'command' -and -not $r.Pending) "$($r.Prompt) / $($r.PromptKind) / $($r.Pending)"
Update-ChatOverlayText $cx9 $s9
# 100 KB on, the command is far behind the next read, which takes only what
# was added: from where the last whole line read ended
$grew = (((OvLast 'continue'), (OvTail)) -join "`n") + "`n"
[System.IO.File]::AppendAllText($pO9, $grew, $utf8)
$script:ChatOverlayBytesRead = 0
Update-ChatOverlayText $cx9 $s9
Check 'and stays so while only the old last-prompt is written again, read alone' (
    $cx9.Text[$idO9].Prompt -eq '/compact' -and -not $cx9.Text[$idO9].Pending -and $script:ChatOverlayBytesRead -eq $utf8.GetByteCount($grew)) (
    "$($cx9.Text[$idO9].Prompt) / $($script:ChatOverlayBytesRead) bytes read, $($utf8.GetByteCount($grew)) added")
# the same words as the prompt before, typed again: newer by its timestamp
[System.IO.File]::AppendAllText($pO9, (((OvUserAt 'continue' (Get-Date)), (OvReply), (OvLast 'continue'), (OvTail)) -join "`n") + "`n", $utf8)
Update-ChatOverlayText $cx9 $s9
Check 'the prompt before, typed again, takes the command''s place' ($cx9.Text[$idO9].Prompt -eq 'continue' -and $cx9.Text[$idO9].PromptKind -ne 'command') "$($cx9.Text[$idO9].Prompt) / $($cx9.Text[$idO9].PromptKind)"
[System.IO.File]::AppendAllText($pO9, (((OvUser 'next ask'), (OvReply), (OvLast 'next ask'), (OvTail)) -join "`n") + "`n", $utf8)
Update-ChatOverlayText $cx9 $s9
Check 'until a prompt is typed after it' ($cx9.Text[$idO9].Prompt -eq 'next ask') $cx9.Text[$idO9].Prompt
# a command read with no last-prompt beside it: the next read's, naming the
# prompt before as ever, is matched against the one read before the command
$idO13 = '0a0a0a0a-0a0a-40a0-80a0-0a0a0a0a0a13'
$pO13 = New-OverlayChat $idO13 @((OvUser 'continue'), (OvReply), (OvLast 'continue'), (OvTitle 'Command chat'), (OvTail))
$cx13 = New-ChatOverlayContext
$s13 = [pscustomobject]@{ SessionId = $idO13; Cwd = $projO }
Update-ChatOverlayText $cx13 $s13
[System.IO.File]::AppendAllText($pO13, (((OvCommand 'compact' '' $tq), '{"type":"user","message":{"role":"user","content":"<local-command-stdout>Compacted </local-command-stdout>"}}') -join "`n") + "`n", $utf8)
Update-ChatOverlayText $cx13 $s13
$cmd13 = $cx13.Text[$idO13].Prompt
[System.IO.File]::AppendAllText($pO13, (((OvLast 'continue'), (OvTail)) -join "`n") + "`n", $utf8)
Update-ChatOverlayText $cx13 $s13
Check 'a command read alone stays the newest thing sent as the old last-prompt is written after it' (
    $cmd13 -eq '/compact' -and $cx13.Text[$idO13].Prompt -eq '/compact' -and $cx13.Text[$idO13].PromptKind -eq 'command') (
    "$cmd13 / $($cx13.Text[$idO13].Prompt) / $($cx13.Text[$idO13].PromptKind)")
# a line still being written as a read comes: the next read starts at its
# beginning, and takes it whole
$idO12 = '0a0a0a0a-0a0a-40a0-80a0-0a0a0a0a0a12'
$pO12 = New-OverlayChat $idO12 @((OvUser 'first ask'), (OvReply), (OvLast 'first ask'), (OvTitle 'Cut chat'), (OvTail))
$cx12 = New-ChatOverlayContext
$s12 = [pscustomobject]@{ SessionId = $idO12; Cwd = $projO }
Update-ChatOverlayText $cx12 $s12
$cutLine = OvLast 'second ask'
[System.IO.File]::AppendAllText($pO12, $cutLine.Substring(0, 20), $utf8)
Update-ChatOverlayText $cx12 $s12
$cutHalf = $cx12.Text[$idO12].Prompt
[System.IO.File]::AppendAllText($pO12, $cutLine.Substring(20) + "`n", $utf8)
Update-ChatOverlayText $cx12 $s12
Check 'a line still being written as one read comes is taken whole by the next' ($cutHalf -eq 'first ask' -and $cx12.Text[$idO12].Prompt -eq 'second ask') "$cutHalf / $($cx12.Text[$idO12].Prompt)"
$pO10 = New-OverlayChat '0a0a0a0a-0a0a-40a0-80a0-0a0a0a0a0a10' @((OvUser 'first'), (OvCommand 'model' 'opus[1m]'), (OvUser 'after the switch'), (OvReply), (OvLast 'after the switch'), (OvTitle 'Switched'), (OvTail))
$r = Find-ChatTailRecords $pO10
Check 'a prompt after a command wins, arguments read with the command' ($r.Prompt -eq 'after the switch' -and $r.After -and (Read-ClaudeSlashCommand (OvCommand 'model' 'opus[1m]')) -eq '/model opus[1m]') "$($r.Prompt) / $($r.After)"
Check 'a skill the model loads is no command typed' ($null -eq (Read-ClaudeSlashCommand '{"type":"user","message":{"role":"user","content":"<command-message>workflow-authoring</command-message>\n<command-name>workflow-authoring</command-name>"}}'))
$pend = @{ Path = 'x'; AiTitle = 't'; Prompt = 'continue'; PromptKind = 'last'; Pending = [DateTimeOffset]::new((Get-Date).AddSeconds(-30)).ToUnixTimeMilliseconds() }
$mkS = { param($st) [pscustomobject]@{ SessionId = 'p1'; Pid = 1; Status = $st; Cwd = 'C:\p\one'; StatusUpdatedAt = 1 } }
$rb = @(Get-ChatOverlayRows -Sessions @(& $mkS 'busy') -Texts @{ p1 = $pend })[0]
$ri = @(Get-ChatOverlayRows -Sessions @(& $mkS 'idle') -Texts @{ p1 = $pend })[0]
Check 'a chat working on a command not yet written says so, not the prompt before' ($rb.prompt -eq $script:ChatOverlayPendingText -and $rb.promptKind -eq 'pending' -and $ri.prompt -eq 'continue') "$($rb.prompt) / $($ri.prompt)"
$tqMs = [DateTimeOffset]::new($tq).ToUnixTimeMilliseconds()
Check 'what was last typed into an open chat is kept: the prompt typed after the command, not the command' (
    $cx9.Text[$idO9].TypedAt -and [int64]$cx9.Text[$idO9].TypedAt -gt $tqMs + 30000) "$($cx9.Text[$idO9].TypedAt) vs $tqMs"

# a job waiting on you whose chat you went on in yourself: skipped, as a
# reply from the phone skips it - the overlay went on saying "needs you"
$idAn1 = 'a0a0a0a0-0000-4000-8000-0000000000a1'
$idAn2 = 'a0a0a0a0-0000-4000-8000-0000000000a2'
$idAn3 = 'a0a0a0a0-0000-4000-8000-0000000000a3'
$pAn1 = New-FakeChat $projA $idAn1 'Answered in VS Code' 1 @('first ask')
$pAn2 = New-FakeChat $projA $idAn2 'Answered then closed' 1 @('first ask')
$pAn3 = New-FakeChat $projA $idAn3 'Still waiting on you' 1 @('first ask')
$mkAn = {
    param($Id, $Path)
    $j = (New-ChatqJob -Row (Get-ChatqRowById $Id -Path $Path) -Prompt 'from the phone' -Rule 'picked').Job
    Complete-ChatqJob $j 'needs-input' ([pscustomobject]@{ kind = 'needs-input'; reason = 'denied Bash(x)' }) 'test'
    Find-ChatqJob $j.id
}
$jAn1 = & $mkAn $idAn1 $pAn1
$jAn2 = & $mkAn $idAn2 $pAn2
$jAn3 = & $mkAn $idAn3 $pAn3
$endMs = ConvertTo-ChatOverlayMs (ConvertTo-ChatqDate $jAn1.endedAt)
Check 'a job waiting on you is answered only by something typed into its chat after it stopped' (
    -not (Test-ChatqJobAnswered $jAn1 ($endMs - 1000)) -and (Test-ChatqJobAnswered $jAn1 ($endMs + 1000)) -and -not (Test-ChatqJobAnswered $jAn1 $null) -and
    -not (Test-ChatqJobAnswered ([pscustomobject]@{ state = 'done'; endedAt = $jAn1.endedAt }) ($endMs + 1000)))
$cxA = New-ChatOverlayContext
$cxA.Jobs = @(@($jAn1, $jAn2, $jAn3) | ForEach-Object { [pscustomobject]@{ Job = $_; First = 'from the phone' } })
$cxA.Text[$idAn1] = @{ TypedAt = $endMs - 5000 }
$an0 = @(Close-ChatqAnsweredJobs $cxA)
# typed into the open one since; the closed one answered in its transcript
$cxA.Text[$idAn1] = @{ TypedAt = $endMs + 5000 }
[System.IO.File]::AppendAllText($pAn2, (OvUserAt 'answered, then closed' ((Get-Date).AddSeconds(3))) + "`n", $utf8)
$an1 = @(Close-ChatqAnsweredJobs $cxA)
$sAn1 = Find-ChatqJob $jAn1.id
$sAn2 = Find-ChatqJob $jAn2.id
$sAn3 = Find-ChatqJob $jAn3.id
Check 'a job waiting on you whose chat was typed into since - open, or closed again - is skipped as answered in the chat; one nobody answered waits on' (
    $an0.Count -eq 0 -and $an1.Count -eq 2 -and $sAn1.state -eq 'skipped' -and $sAn1.result.reason -eq 'answered in the chat' -and
    $sAn2.state -eq 'skipped' -and $sAn3.state -eq 'needs-input') "$($an0.Count) $($an1.Count) $($sAn1.state) $($sAn2.state) $($sAn3.state)"
# no overlay running: the phone's Status (and chatqlist) close it themselves
# as they list - a chat that never moved since is not read, nor closed
$null = Get-ChatqPhoneStatusReport
$sAn3 = Find-ChatqJob $jAn3.id
[System.IO.File]::AppendAllText($pAn3, (OvUserAt 'answered with no overlay' ((Get-Date).AddSeconds(3))) + "`n", $utf8)
$stAn1 = Get-ChatqPhoneStatusReport
$sAn3b = Find-ChatqJob $jAn3.id
Check 'with no overlay, the phone''s Status skips a job answered in its chat before it lists, and leaves one nobody answered' (
    $sAn3.state -eq 'needs-input' -and $sAn3b.state -eq 'skipped' -and $sAn3b.result.reason -eq 'answered in the chat' -and
    $stAn1 -notmatch "(?m)^#$($jAn3.seq) .*needs you") "$($sAn3.state) $($sAn3b.state) / $stAn1"
# a chat that moved after its job stopped - written to, a title say - with
# nothing typed in it: read, and the job waits on
$idAn5 = 'a0a0a0a0-0000-4000-8000-0000000000a5'
$pAn5 = New-FakeChat $projA $idAn5 'Moved, nobody typed' 1 @('first ask')
$jAn5 = & $mkAn $idAn5 $pAn5
Start-Sleep -Milliseconds 50
[System.IO.File]::AppendAllText($pAn5, (([ordered]@{ type = 'ai-title'; aiTitle = 'Moved, nobody typed'; sessionId = $idAn5 } | ConvertTo-Json -Compress) + "`n"), $utf8)
$movedAn5 = (Get-Item -LiteralPath $pAn5).LastWriteTimeUtc -gt (ConvertTo-ChatqDate $jAn5.endedAt).ToUniversalTime()
$syAn5 = @(Sync-ChatqAnsweredJobs @(Find-ChatqJob $jAn5.id))
$sAn5 = Find-ChatqJob $jAn5.id
Check 'a job whose chat moved since it stopped, with nothing typed into it, is not closed' ($movedAn5 -and $syAn5.Count -eq 0 -and $sAn5.state -eq 'needs-input') "$movedAn5 $($syAn5.Count) $($sAn5.state)"
$null = Remove-ChatqJob $sAn5 'test'
Remove-Item -LiteralPath $pAn5 -Force
# chatqlist the same, before it prints a line
$idAn4 = 'a0a0a0a0-0000-4000-8000-0000000000a4'
$pAn4 = New-FakeChat $projA $idAn4 'Answered before the list' 1 @('first ask')
$jAn4 = & $mkAn $idAn4 $pAn4
[System.IO.File]::AppendAllText($pAn4, (OvUserAt 'answered, then chatqlist' ((Get-Date).AddSeconds(3))) + "`n", $utf8)
$lsAn4 = (Write-ChatqList 6>&1 | Out-String -Width 400)
$sAn4 = Find-ChatqJob $jAn4.id
Check 'with no overlay, chatqlist skips a job answered in its chat before it lists it' (
    $sAn4.state -eq 'skipped' -and $sAn4.result.reason -eq 'answered in the chat' -and
    $lsAn4 -match "#$($jAn4.seq) Answered before the list \S+ answered in the chat" -and
    $lsAn4 -notmatch "Answered before the list[^#]*needs you") "$($sAn4.state) / $lsAn4"
foreach ($x in $jAn1, $jAn2, $jAn3, $jAn4) { $null = Remove-ChatqJob (Find-ChatqJob $x.id) 'test' }
Remove-Item -LiteralPath $pAn1, $pAn2, $pAn3, $pAn4 -Force

# the registry: four sessions and a dead one, and a .key locked the way a
# live session holds it - reading it would throw
$sessDir = Join-Path $claudeHome 'sessions'
$null = New-Item -ItemType Directory -Path $sessDir -Force
$nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
function Set-OvSession([int]$ProcId, [string]$Sid, [string]$Status, [double]$MinutesAgo, $WaitingFor = $null, [string]$Name = 'derived-name', [string]$Kind = 'interactive',
    [string]$Entrypoint = 'claude-vscode') {
    $o = [ordered]@{ pid = $ProcId; sessionId = $Sid; cwd = $projO; startedAt = $nowMs - 3600000; procStart = '134346197461820071'; kind = $Kind
        entrypoint = $Entrypoint; pidDomain = "win32:$([Environment]::MachineName)"; name = $Name; status = $Status
        updatedAt = $nowMs - [int64]($MinutesAgo * 60000); statusUpdatedAt = $nowMs - [int64]($MinutesAgo * 60000) }
    if ($WaitingFor) { $o.waitingFor = $WaitingFor }
    [System.IO.File]::WriteAllText((Join-Path $sessDir "$ProcId.json"), ($o | ConvertTo-Json -Compress), $utf8)
}
Set-OvSession 111 $idO1 'waiting' 5 'permission'
Set-OvSession 112 $idO1 'idle' 40
Set-OvSession 222 $idO4 'busy' 1
Set-OvSession 333 $idO3 'idle' 30
Set-OvSession 444 $idO2 'busy' 2
Set-OvSession 555 $idO6 'busy' 2 $null 'fresh-chat-1a'
Set-OvSession 666 $idO7 'idle' 3
Set-OvSession 777 $idO8 'busy' 1 $null 'x' 'print'
$keyFile = Join-Path $sessDir '111.0fb15029164cbeb453ceb405db09b1caeff7424a77491bfef6e933a8e0cc3172.key'
[System.IO.File]::WriteAllText($keyFile, 'secret', $utf8)
$keyLock = [System.IO.File]::Open($keyFile, 'Open', 'ReadWrite', 'None')
try {
    $reg = @(Read-ChatqSessionRegistry $sessDir @{})
    $ctx = New-ChatOverlayContext
    $snap = Invoke-ChatOverlayCycle $ctx -Peek
}
finally { $keyLock.Dispose() }
Check 'the registry reads <pid>.json only, never the .key' ($reg.Count -eq 8 -and -not $snap.header.error) "$($reg.Count) $($snap.header.error)"
$row = { param($id) @($snap.rows | Where-Object { $_.sessionId -eq $id -and $_.kind -eq 'session' })[0] }
$r1 = & $row $idO1
Check 'a chat open in two windows is one row, at its more urgent state' ($r1 -and $r1.status -eq 'waiting' -and @($r1.pids).Count -eq 2 -and $r1.rank -eq 0) "$($r1.status) $(@($r1.pids) -join ',')"
Check 'its row: project, title, newest prompt, what it waits on' ($r1.project -eq 'projO' -and $r1.title -eq 'Loader fixes' -and $r1.prompt -eq 'fix the loader' -and $r1.stateText -like 'permission *') "$($r1.project) | $($r1.title) | $($r1.prompt) | $($r1.stateText)"
Check 'where it runs, from the registry''s entrypoint: a VS Code panel, in the snapshot the view key is made of' (
    $r1.where -eq 'vscode' -and $ctx.ViewSig -like '*"where":"vscode"*') "$($r1.where)"
# a rewrite that leaves the status alone (a limit reset rewrites them all)
# stamps statusUpdatedAt anew; the timer keeps the time the status began
$suDir = Join-Path $claudeHome 'sessions-su'
$null = New-Item -ItemType Directory -Force $suDir
$suWrite = { param($st, $at, $pad) [System.IO.File]::WriteAllText((Join-Path $suDir '901.json'), (@{ pid = 901; sessionId = 'su1'; status = $st; updatedAt = $at; statusUpdatedAt = $at; name = $pad } | ConvertTo-Json -Compress), $utf8) }
$suCache = @{}
& $suWrite 'busy' 1000 'a'
$su0 = @(Read-ChatqSessionRegistry $suDir $suCache)[0].StatusUpdatedAt
& $suWrite 'busy' 9000 'ab'
$su1 = @(Read-ChatqSessionRegistry $suDir $suCache)[0].StatusUpdatedAt
& $suWrite 'idle' 9500 'abc'
$su2 = @(Read-ChatqSessionRegistry $suDir $suCache)[0].StatusUpdatedAt
Check 'a registry rewrite in the same status keeps its time; a new status takes the new one' ($su0 -eq 1000 -and $su1 -eq 1000 -and $su2 -eq 9500) "$su0 $su1 $su2"
$wS = @(
    [pscustomobject]@{ SessionId = 'e-vs'; Pid = 1; Status = 'idle'; Cwd = 'C:\p\one'; StatusUpdatedAt = 1; Entrypoint = 'claude-vscode' }
    [pscustomobject]@{ SessionId = 'e-cli'; Pid = 2; Status = 'idle'; Cwd = 'C:\p\two'; StatusUpdatedAt = 1; Entrypoint = 'cli' }
    [pscustomobject]@{ SessionId = 'e-none'; Pid = 3; Status = 'idle'; Cwd = 'C:\p\three'; StatusUpdatedAt = 1 }
    # claude -p, chatq's queued prompt among them: a run, not a terminal
    [pscustomobject]@{ SessionId = 'e-sdk'; Pid = 4; Status = 'busy'; Cwd = 'C:\p\five'; StatusUpdatedAt = 1; Entrypoint = 'sdk-cli' }
    [pscustomobject]@{ SessionId = 'e-ts'; Pid = 5; Status = 'busy'; Cwd = 'C:\p\six'; StatusUpdatedAt = 1; Entrypoint = 'sdk-ts' }
    # a run going in beside a window's copy wins the mark, whichever comes first
    [pscustomobject]@{ SessionId = 'e-both'; Pid = 6; Status = 'idle'; Cwd = 'C:\p\seven'; StatusUpdatedAt = 1; Entrypoint = 'claude-vscode' }
    [pscustomobject]@{ SessionId = 'e-both'; Pid = 7; Status = 'busy'; Cwd = 'C:\p\seven'; StatusUpdatedAt = 1; Entrypoint = 'sdk-cli' }
)
$wT = @{ 'e-vs' = @{ Path = 'x'; AiTitle = 'a' }; 'e-cli' = @{ Path = 'x'; AiTitle = 'b' }; 'e-none' = @{ Path = 'x'; AiTitle = 'c' }; 'e-sdk' = @{ Path = 'x'; AiTitle = 'd' }
    'e-ts' = @{ Path = 'x'; AiTitle = 'e' }; 'e-both' = @{ Path = 'x'; AiTitle = 'f' } }
$wJ = @([pscustomobject]@{ First = 'x'; Job = [pscustomobject]@{ id = 'jw'; seq = 1; state = 'queued'; provider = 'claude'; sessionId = 'gone'; title = 't'; cwd = 'C:\p\four'; createdAt = $null } })
$wR = @(Get-ChatOverlayRows -Sessions $wS -Texts $wT -Jobs $wJ)
$wOf = { param($k) [string](@($wR | Where-Object { $_.key -eq $k })[0].where) }
Check 'claude-vscode is a VS Code panel, an SDK entrypoint (claude -p) a run, any other a terminal, none nothing; a run beside a window wins; a job runs nowhere' (
    (& $wOf 's:e-vs') -eq 'vscode' -and (& $wOf 's:e-cli') -eq 'terminal' -and (& $wOf 's:e-none') -eq '' -and (& $wOf 'j:jw') -eq '' -and
    (& $wOf 's:e-sdk') -eq 'run' -and (& $wOf 's:e-ts') -eq 'run' -and (& $wOf 's:e-both') -eq 'run' -and
    (Get-ChatOverlayWhere 'sdk-py') -eq 'run' -and (Get-ChatOverlayWhere 'SDK-CLI') -eq 'terminal') (($wR | ForEach-Object { "$($_.key)=$($_.where)" }) -join ' ')
# the where values' consumers: delete greyed on a run as on a terminal, so
# the refusal a terminal had does not drop off by the new name
$dRow = { param($where, $st = 'idle') [pscustomobject]@{ key = 's:d'; kind = 'session'; provider = 'claude'; sessionId = $idCard; cwd = $projA; status = $st; where = $where } }
$dActs = { param($where) $a = @(Get-ChatOverlayChipActions (& $dRow $where)); "$((@($a | ForEach-Object Id)) -join ','):$(@($a | Where-Object { $_.Id -eq 'delete' })[0].Disabled)" }
Check 'delete greyed on a chat a queued prompt runs in, as on a terminal''s; not on a VS Code one' (
    -not (Test-ChatOverlayRowDeletable (& $dRow 'run')) -and -not (Test-ChatOverlayRowDeletable (& $dRow 'terminal')) -and (Test-ChatOverlayRowDeletable (& $dRow 'vscode')) -and
    (& $dActs 'run') -eq 'open,delete:True' -and (& $dActs 'vscode') -eq 'open,delete:False') "$(& $dActs 'run') $(& $dActs 'vscode')"
Check 'a rename wins over the generated title' ((& $row $idO4).title -eq $tCustom) (& $row $idO4).title
Check 'a registry entry whose process is gone has no row' (-not (& $row $idO2))
Check 'a working chat with no transcript yet shows the registry name' ((& $row $idO6).title -eq 'fresh-chat-1a')
Check 'an idle one with none - a new chat tab - has no row' (-not (& $row $idO7))
Check 'chatq''s own claude -p runs are not chats' (-not (& $row $idO8))
$ranks = @($snap.rows | ForEach-Object { [int]$_.rank })
Check 'rows run most urgent first' ((($ranks | Sort-Object) -join ',') -eq ($ranks -join ',')) ($ranks -join ',')
Check 'the snapshot counts what the rows show' ($snap.counts.waiting -eq 1 -and $snap.counts.busy -eq 2 -and $snap.counts.idle -eq 1) ($snap.counts | ConvertTo-Json -Compress)
$u = @($snap.header.usage | Where-Object { $_.provider -eq 'Claude' })[0]
Check 'usage live at the top: 5h, week, and one model''s week once used' ($u.source -eq 'live' -and (@($u.windows | ForEach-Object { "$($_.label) $($_.percent)" }) -join ',') -eq '5h 42,week 77,Fable week 5') (@($u.windows | ForEach-Object { "$($_.label) $($_.percent)" }) -join ',')
Check 'with the server''s own colour for each window' (@($u.windows)[1].severity -eq 'warning' -and @($u.windows)[0].resetsAt -gt $nowMs)
Check 'config in the snapshot is the overlay''s alone' ((@($snap.config.PSObject.Properties.Name) -notcontains 'join') -and (@($snap.config.PSObject.Properties.Name) -contains 'hotkey'))
$fetched = $script:OvFetches
$null = Invoke-ChatOverlayCycle $ctx -Peek
Check 'the endpoint is not asked again on the next pass' ($script:OvFetches -eq $fetched) "$fetched -> $($script:OvFetches)"
$ctx.Live.Windows[0].ResetsAt = (Get-Date).AddSeconds(-10)
$ctx.Live.At = (Get-Date).AddMinutes(-2)
$gone = ConvertTo-ChatOverlayUsage 'Claude' 'live' $ctx.Live (Get-Date) $null @{}
$null = Invoke-ChatOverlayCycle $ctx -Peek
Check 'a window whose reset passed reads empty, and is asked about at once' (@($gone.windows)[0].percent -eq 0 -and $null -eq @($gone.windows)[0].resetsAt -and $script:OvFetches -eq $fetched + 1) "$fetched -> $($script:OvFetches)"
# two traps of the same kind: an if that yields an empty array assigns $null
$cq = New-ChatOverlayContext
$null = Invoke-ChatOverlayCycle $cq
$sq1 = Invoke-ChatOverlayCycle $cq
Check 'passes with no command in them queue no command' ($cq.Commands.Count -eq 0 -and @($sq1.commands).Count -eq 0) "$($cq.Commands.Count)"
$cxWas = $script:ChatCodexHome
$script:ChatCodexHome = Join-Path $sb 'no-codex-here'
$un = try { @(Update-ChatOverlayUsage (New-ChatOverlayContext) $true) } catch { "threw: $($_.Exception.Message)" }
$script:ChatCodexHome = $cxWas
Check 'a machine with no Codex at all still gets Claude''s usage' (@($un | Where-Object { $_.provider -eq 'Claude' }).Count -eq 1 -and -not @($un | Where-Object { $_.provider -eq 'Codex' }).Count) "$un"
# collapsed: only the providers in use, named once it is not Claude alone
$cuW = { param($p, $a, $b, $st) [pscustomobject]@{ provider = $p; stale = $st; windows = @([pscustomobject]@{ label = '5h'; percent = $a; resetsAt = $null }, [pscustomobject]@{ label = 'week'; percent = $b; resetsAt = $null }) } }
$cuClaude = Get-ChatOverlayCompactUsage @((& $cuW 'Claude' 42 18 $false), (& $cuW 'Codex' 0 0 $false))
$cuCodex = Get-ChatOverlayCompactUsage @((& $cuW 'Claude' 0 0 $false), (& $cuW 'Codex' 7 3 $true))
$cuBoth = Get-ChatOverlayCompactUsage @((& $cuW 'Claude' 42 18 $false), (& $cuW 'Codex' 7 3 $true))
$cuNone = Get-ChatOverlayCompactUsage @((& $cuW 'Claude' 0 0 $false))
$cd = $script:ChatqDot
Check 'collapsed usage: only providers in use - Claude unnamed alone, Codex named, both named, none empty' (
    $cuClaude.Text -eq "5h 42% $cd week 18%" -and -not $cuClaude.Stale -and
    $cuCodex.Text -eq "Codex 5h 7% $cd week 3%" -and $cuCodex.Stale -and
    $cuBoth.Text -eq "Claude 5h 42% $cd week 18% $cd Codex 5h 7% $cd week 3%" -and -not $cuBoth.Stale -and
    $cuNone.Text -eq '') "[$($cuClaude.Text)] [$($cuCodex.Text)] [$($cuBoth.Text)] [$($cuNone.Text)]"

# the transcript grew: only the new part is read. The slice set wide: a chat
# read before is passed over once it runs out, and a slow machine's pass
# could use it up before the chat's turn
[System.IO.File]::AppendAllText($pO1, ((@((OvUser 'now the tests'), (OvReply), (OvLast 'now the tests'), (OvTitle 'Loader fixes and tests'), (OvTail)) -join "`n") + "`n"), $utf8)
$script:ChatOverlayBytesRead = 0
$sliceWas = $script:ChatOverlaySliceMs
$script:ChatOverlaySliceMs = 60000
$snap = Invoke-ChatOverlayCycle $ctx -Peek
$script:ChatOverlaySliceMs = $sliceWas
$r1 = & $row $idO1
Check 'a transcript that grew is read from where it was, no further' ($r1.prompt -eq 'now the tests' -and $r1.title -eq 'Loader fixes and tests' -and $script:ChatOverlayBytesRead -lt 70000) "$($r1.prompt) | $($r1.title) | $($script:ChatOverlayBytesRead)"
Remove-Item -LiteralPath (Join-Path $sessDir '112.json')
$ctx.AliveAt = [datetime]::MinValue
$snap = Invoke-ChatOverlayCycle $ctx -Peek
Check 'a window closing leaves the chat''s other one' (@((& $row $idO1).pids).Count -eq 1)
# -Print marks a chat in a terminal; one in VS Code is not marked
Set-OvSession 889 $idO3 'idle' 30 $null 'derived-name' 'interactive' 'cli'
Remove-Item -LiteralPath (Join-Path $sessDir '333.json')
$prOut = (@(Write-ChatOverlayPrint 6>&1 | ForEach-Object { "$_" }) -join '')
# and a print-mode run's - a queued prompt - with a mark of its own
Set-OvSession 889 $idO3 'busy' 30 $null 'derived-name' 'interactive' 'sdk-cli'
$prRun = (@(Write-ChatOverlayPrint 6>&1 | ForEach-Object { "$_" }) -join '')
Remove-Item -LiteralPath (Join-Path $sessDir '889.json')
Set-OvSession 333 $idO3 'idle' 30
Check '-Print marks a chat in a terminal >_, one in VS Code not' ($prOut -like '*>_ projO  Noisy chat*' -and $prOut -like '*projO  Loader fixes*' -and $prOut -notlike '*>_ projO  Loader*') $prOut
Check '-Print marks a chat a queued prompt runs in |>, not >_' ($prRun -like '*|> projO  Noisy chat*' -and $prRun -notlike '*>_ projO  Noisy*') $prRun

# the watcher's own reader of the registry, when claude agents cannot run
$was = $env:CHATQ_CLAUDE
$env:CHATQ_CLAUDE = Join-Path $sb 'no-such-claude.exe'
$liveS = @(Get-ChatqLiveSessions $claudeHome)
$env:CHATQ_CLAUDE = $was
$w1 = @($liveS | Where-Object { $_.SessionId -eq $idO1 })[0]
Check 'the watcher''s fallback reads the same registry, waitingFor and all' ($w1 -and $w1.WaitingFor -eq 'permission' -and -not @($liveS | Where-Object { $_.SessionId -eq $idO2 })) "$(@($liveS).Count) $($w1.WaitingFor)"

# the same session test, against a real process
$node = Get-Command node -CommandType Application -EA SilentlyContinue | Select-Object -First 1
if ($node) {
    $script:ChatqAliveSeam = $null
    $np = Start-Process -FilePath $node.Source -ArgumentList '-e', '"setTimeout(function () {}, 60000)"' -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 800
    $np.Refresh()
    $ft = $np.StartTime.ToFileTimeUtc()
    $sa = [DateTimeOffset]::new($np.StartTime).ToUnixTimeMilliseconds()
    $mk = { param($ps, $at, $dom = "win32:$([Environment]::MachineName)") [pscustomobject]@{ Pid = $np.Id; ProcStart = $ps; StartedAt = $at; PidDomain = $dom } }
    Check 'a process that started when its entry says is that session' (Test-ChatqSessionAlive (& $mk "$ft" $sa))
    Check 'procStart an hour off is some other process' (-not (Test-ChatqSessionAlive (& $mk "$($ft - 36000000000)" $sa)))
    Check 'so is one started long after the session did - a reused pid' (-not (Test-ChatqSessionAlive (& $mk $null ($sa - 3600000))))
    Check 'a macOS-style date procStart is not held against it' (Test-ChatqSessionAlive (& $mk 'Tue Sep 23 10:00:00 2026' $sa))
    Check 'nor is another machine''s entry this one' (-not (Test-ChatqSessionAlive (& $mk "$ft" $sa 'win32:some-other-host')))
    Stop-Process -Id $np.Id -Force -EA SilentlyContinue
    $script:ChatqAliveSeam = { param($e) $e.Pid -ne 444 }
}
else { Write-Host '  skip  real-process session checks - no node here' -ForegroundColor Yellow }

# merging and order, on the pure function
$tnow = Get-Date
$ago = { param($m) [DateTimeOffset]::new($tnow.AddMinutes(-$m)).ToUnixTimeMilliseconds() }
$S = @(
    [pscustomobject]@{ SessionId = 'w-old'; Pid = 1; Status = 'waiting'; Cwd = 'C:\p\one'; StatusUpdatedAt = (& $ago 30) }
    [pscustomobject]@{ SessionId = 'w-new'; Pid = 2; Status = 'waiting'; Cwd = 'C:\p\two'; StatusUpdatedAt = (& $ago 5) }
    [pscustomobject]@{ SessionId = 'b-old'; Pid = 3; Status = 'busy'; Cwd = 'C:\p\three'; StatusUpdatedAt = (& $ago 20) }
    [pscustomobject]@{ SessionId = 'b-new'; Pid = 4; Status = 'busy'; Cwd = 'C:\p\four'; StatusUpdatedAt = (& $ago 2) }
    [pscustomobject]@{ SessionId = 'i-1'; Pid = 5; Status = 'idle'; Cwd = 'C:\p\five'; StatusUpdatedAt = (& $ago 60) }
    [pscustomobject]@{ SessionId = 'i-2'; Pid = 6; Status = 'idle'; Cwd = 'C:\p\six'; StatusUpdatedAt = (& $ago 10) }
    [pscustomobject]@{ SessionId = 'i-2'; Pid = 7; Status = 'busy'; Cwd = 'C:\p\six'; StatusUpdatedAt = (& $ago 1) }
)
$T = @{}
foreach ($k in 'w-old', 'w-new', 'b-old', 'b-new', 'i-1', 'i-2') { $T[$k] = @{ Path = 'x'; AiTitle = "title $k"; Prompt = "prompt $k" } }
$stamp = { param($m) $tnow.AddMinutes(-$m).ToUniversalTime().ToString('o') }
$J = @(
    [pscustomobject]@{ First = 'for an open chat'; Job = [pscustomobject]@{ id = 'j1'; seq = 1; state = 'queued'; provider = 'claude'; sessionId = 'i-1'; title = 'title i-1'; cwd = 'C:\p\five'; createdAt = (& $stamp 50) } }
    [pscustomobject]@{ First = 'for a closed one'; Job = [pscustomobject]@{ id = 'j2'; seq = 2; state = 'queued'; provider = 'claude'; sessionId = 'closed-1'; title = 'Closed chat'; cwd = 'C:\p\seven'; createdAt = (& $stamp 40) } }
    [pscustomobject]@{ First = 'for codex'; Job = [pscustomobject]@{ id = 'j3'; seq = 3; state = 'queued'; provider = 'codex'; sessionId = 'cx'; title = 'Codex chat'; cwd = 'C:\p\eight'; createdAt = (& $stamp 30) } }
    [pscustomobject]@{ First = 'parked'; Job = [pscustomobject]@{ id = 'j4'; seq = 4; state = 'needs-input'; provider = 'claude'; sessionId = 'closed-2'; title = 'Parked'; cwd = 'C:\p\nine'; endedAt = (& $stamp 15); result = [pscustomobject]@{ reason = 'asked to edit' } } }
    [pscustomobject]@{ First = 'running'; Job = [pscustomobject]@{ id = 'j5'; seq = 5; state = 'running'; provider = 'claude'; sessionId = 'closed-3'; title = 'Running one'; cwd = 'C:\p\ten'; startedAt = (& $stamp 3) } }
)
$R = @(Get-ChatOverlayRows -Sessions $S -Texts $T -Jobs $J -Eta @{ j1 = '17:10'; j2 = 'after #1'; j3 = 'next' } -Now $tnow)
$want = 's:w-old,j:j4,s:w-new,s:i-2,s:b-new,s:b-old,j:j5,s:i-1,j:j2,j:j3'
Check 'waiting oldest first, then working, running, idle newest first, queued in order' (($R.key -join ',') -eq $want) ($R.key -join ',')
$ri1 = @($R | Where-Object { $_.key -eq 's:i-1' })[0]
Check 'a prompt queued for an open chat rides on its row' ($ri1.job.seq -eq 1 -and $ri1.stateText -like '#1 sends 17:10*idle*' -and -not @($R | Where-Object { $_.key -eq 'j:j1' })) $ri1.stateText
$ri2 = @($R | Where-Object { $_.key -eq 's:i-2' })[0]
Check 'the second window''s state wins when it is the more urgent' ($ri2.status -eq 'busy' -and (@($ri2.pids) -join ',') -eq '6,7') "$($ri2.status) $(@($ri2.pids) -join ',')"
Check 'a job row says what it is and carries its first line' ((@($R | Where-Object { $_.key -eq 'j:j2' })[0].stateText -eq '#2 after #1') -and (@($R | Where-Object { $_.key -eq 'j:j2' })[0].prompt -eq 'for a closed one'))
# cut off by the limit or a 529: an open idle chat takes the state, one not
# open gets a row, one a job is queued for leaves it to the job
$resetAt = $tnow.AddMinutes(90)
$C = @(
    [pscustomobject]@{ Id = 'i-1'; Title = 'title i-1'; Why = 'limit'; ResetsAt = $resetAt; At = $tnow.AddMinutes(-60); Cwd = 'C:\p\five' }
    [pscustomobject]@{ Id = 'b-new'; Title = 'title b-new'; Why = 'limit'; ResetsAt = $resetAt; At = $tnow.AddMinutes(-2); Cwd = 'C:\p\four' }
    [pscustomobject]@{ Id = 'gone-1'; Title = 'Stopped at the limit'; Why = 'limit'; ResetsAt = $resetAt; At = $tnow.AddMinutes(-30); Cwd = 'C:\p\eleven'; Path = 'C:\x.jsonl' }
    [pscustomobject]@{ Id = 'gone-2'; Title = 'Stopped by a 529'; Why = 'overloaded'; ResetsAt = $null; At = $tnow.AddMinutes(-20); Cwd = 'C:\p\twelve' }
    [pscustomobject]@{ Id = 'closed-1'; Title = 'Closed chat'; Why = 'limit'; ResetsAt = $resetAt; At = $tnow.AddMinutes(-45); Cwd = 'C:\p\seven' }
)
$S2 = @($S | Where-Object { $_.SessionId -ne 'i-1' }) + @([pscustomobject]@{ SessionId = 'i-3'; Pid = 8; Status = 'idle'; Cwd = 'C:\p\five'; StatusUpdatedAt = (& $ago 60) })
$C[0].Id = 'i-3'
$T['i-3'] = @{ Path = 'x'; AiTitle = 'title i-3'; Prompt = 'prompt i-3' }
$RC = @(Get-ChatOverlayRows -Sessions $S2 -Texts $T -Jobs $J -Eta @{ j1 = '17:10'; j2 = 'after #1'; j3 = 'next' } -Now $tnow -CutOff $C)
$r3 = @($RC | Where-Object { $_.key -eq 's:i-3' })[0]
$rg1 = @($RC | Where-Object { $_.key -eq 'c:gone-1' })[0]
$rg2 = @($RC | Where-Object { $_.key -eq 'c:gone-2' })[0]
$rbn = @($RC | Where-Object { $_.key -eq 's:b-new' })[0]
$firstCut = [array]::IndexOf(@($RC.key), 'c:gone-2')
# run after 22:30, the reset falls on tomorrow, and says its day
$resetSays = if ($resetAt.Date -eq $tnow.Date) { $resetAt.ToString('HH:mm', [System.Globalization.CultureInfo]::InvariantCulture) } else { $resetAt.ToString('ddd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture) }
Check 'cut off: an open idle chat says when the limit resets; a working one has moved on' (
    $r3.status -eq 'cutoff' -and $r3.rank -eq 0.5 -and $r3.stateText -eq "cut off - resets $resetSays" -and $rbn.status -eq 'busy') "$($r3.status) $($r3.stateText) / $($rbn.status)"
Check 'one not open gets a row of its own - a 529 says what it waits on - and a queued continue replaces it' (
    $rg1.kind -eq 'cutoff' -and $rg1.project -eq 'eleven' -and $rg2.stateText -eq '529 - waits for Claude' -and -not @($RC | Where-Object { $_.key -eq 'c:closed-1' }) -and
    $firstCut -gt [array]::IndexOf(@($RC.key), 's:w-new') -and $firstCut -lt [array]::IndexOf(@($RC.key), 's:b-new')) ($RC.key -join ',')
Check 'and when the limit is over it says so' ((Format-ChatOverlayCutOff ([pscustomobject]@{ Why = 'limit'; ResetsAt = $tnow.AddMinutes(-5) }) $tnow) -eq 'cut off - limit over')
# VS Code tabs with no process (Read-ChatOpenTabs): each a row as an idle
# open chat's once its transcript was found - none where a process holds its
# chat, or with no transcript - and taking a cut-off and a job as that would
$tbT = $T.Clone()
$tbAt = $tnow.AddMinutes(-7)
$tbT['t-1'] = @{ Path = 'x'; AiTitle = 'title t-1'; Prompt = 'prompt t-1'; PromptKind = 'last'; Mode = 'plan'; Mtime = $tbAt }
$tbT['t-2'] = @{ Path = $null; Mtime = $null }
$tbT['t-3'] = @{ Path = 'x'; AiTitle = 'title t-3'; Mtime = $tnow.AddMinutes(-90) }
$tbT['closed-1'] = @{ Path = 'x'; AiTitle = 'Closed chat'; Mtime = $tnow.AddMinutes(-40) }
$tbTab = { param($sid, $cwd) [pscustomobject]@{ SessionId = $sid; Cwd = $cwd; Label = "label $sid"; Window = 'projT'; HostPid = 1 } }
$tbTabs = @((& $tbTab 't-1' 'C:\p\tabbed'), (& $tbTab 't-2' 'C:\p\tabbed'), (& $tbTab 'i-2' 'C:\p\six'), (& $tbTab 't-3' 'C:\p\cut'), (& $tbTab 't-4' 'C:\p\none'),
    (& $tbTab 'closed-1' 'C:\p\seven'))
$tbC = @([pscustomobject]@{ Id = 't-3'; Title = 'title t-3'; Why = 'limit'; ResetsAt = $resetAt; At = $tnow.AddMinutes(-90); Cwd = 'C:\p\cut' })
$TR = @(Get-ChatOverlayRows -Sessions $S -Texts $tbT -Jobs $J -Eta @{ j1 = '17:10'; j2 = 'after #1'; j3 = 'next' } -Now $tnow -CutOff $tbC -Tabs $tbTabs)
$tr1 = @($TR | Where-Object { $_.key -eq 's:t-1' })[0]
Check 'a VS Code tab with no process: a row as an idle open chat''s - no pids, where vscode, its time the transcript''s, its text, and tab' (
    $tr1 -and $tr1.kind -eq 'session' -and $tr1.status -eq 'idle' -and $tr1.chat -eq 'idle' -and $tr1.rank -eq 3 -and @($tr1.pids).Count -eq 0 -and $tr1.where -eq 'vscode' -and
    $tr1.tab -eq $true -and $tr1.since -eq (ConvertTo-ChatOverlayMs $tbAt) -and $tr1.title -eq 'title t-1' -and $tr1.prompt -eq 'prompt t-1' -and $tr1.mode -eq 'plan' -and
    $tr1.project -eq 'tabbed' -and $tr1.cwd -eq 'C:\p\tabbed' -and -not $tr1.unread -and $tr1.stateText -like 'idle*' -and
    [array]::IndexOf(@($TR.key), 's:t-1') -lt [array]::IndexOf(@($TR.key), 's:i-1')) ($tr1 | ConvertTo-Json -Compress -Depth 4)
$tri2 = @($TR | Where-Object { $_.sessionId -eq 'i-2' })
Check 'a tab whose chat a process holds keeps that one''s row; one with no transcript found, or none looked for, gets none' (
    $tri2.Count -eq 1 -and (@($tri2[0].pids) -join ',') -eq '6,7' -and -not (Get-ChatField $tri2[0] 'tab') -and
    -not @($TR | Where-Object { $_.sessionId -in 't-2', 't-4' }).Count) ($TR.key -join ',')
$tr3 = @($TR | Where-Object { $_.key -eq 's:t-3' })[0]
$trC = @($TR | Where-Object { $_.key -eq 's:closed-1' })[0]
Check 'a tab''s row takes a cut-off and a queued prompt as an idle open chat''s does: the cut-off its state, the job on it' (
    $tr3.status -eq 'cutoff' -and $tr3.rank -eq 0.5 -and $tr3.stateText -eq "cut off - resets $resetSays" -and $tr3.tab -and -not @($TR | Where-Object { $_.key -eq 'c:t-3' }).Count -and
    $trC.job.seq -eq 2 -and $trC.tab -and $trC.status -eq 'idle' -and -not @($TR | Where-Object { $_.key -eq 'j:j2' }).Count) ($TR.key -join ',')
# the files they come from, one a window, read as reload-pending's are
$otDir = Join-Path $sb 'open-tabs-check'
$null = New-Item -ItemType Directory -Path $otDir -Force
$otStart = [DateTimeOffset]::new((Get-Process -Id $PID).StartTime).ToUnixTimeMilliseconds()
function Write-OtFile([int]$HostPid, [int64]$Started, [object[]]$Tabs, [string]$Dir = $otDir) {
    $o = [ordered]@{ v = 1; pid = $HostPid; started = $Started; window = 'projT'; tabs = @($Tabs) }
    [System.IO.File]::WriteAllText((Join-Path $Dir "$HostPid.json"), ($o | ConvertTo-Json -Compress -Depth 5), [System.Text.UTF8Encoding]::new($true))
}
$otA = '0c0c0c0c-0c0c-40c0-80c0-0c0c0c0c0c01'
$otB = '0c0c0c0c-0c0c-40c0-80c0-0c0c0c0c0c02'
Write-OtFile $PID $otStart @([ordered]@{ sessionId = $otA; cwd = 'C:\p\tabbed'; label = 'Tab A' }, [ordered]@{ sessionId = $otB; cwd = 'C:\p\tabbed'; label = 'Tab B' },
    [ordered]@{ sessionId = $otA; cwd = 'C:\p\other'; label = 'Tab A again' }, [ordered]@{ sessionId = 'not-a-session'; cwd = 'C:\p'; label = 'x' }, [ordered]@{ cwd = 'C:\p'; label = 'no id' })
# a window gone: a multiple of 4 no running process has
$otPids = @(Get-Process | ForEach-Object Id)
$otGone = 4000
while ($otPids -contains $otGone) { $otGone += 4 }
Write-OtFile $otGone $otStart @([ordered]@{ sessionId = '0c0c0c0c-0c0c-40c0-80c0-0c0c0c0c0c03'; cwd = 'C:\p'; label = 'gone' })
[System.IO.File]::WriteAllText((Join-Path $otDir 'notes.json'), '{}', $utf8)
$ot = @(Read-ChatOpenTabs -Dir $otDir)
Check 'open tabs: one a session id, the first kept, each with its window and host pid - a BOM let past, a gone window''s file removed, what names no pid passed by' (
    $ot.Count -eq 2 -and $ot[0].SessionId -eq $otA -and $ot[0].Cwd -eq 'C:\p\tabbed' -and $ot[0].Label -eq 'Tab A' -and $ot[0].Window -eq 'projT' -and $ot[0].HostPid -eq $PID -and
    $ot[1].SessionId -eq $otB -and -not (Test-Path -LiteralPath (Join-Path $otDir "$otGone.json")) -and (Test-Path -LiteralPath (Join-Path $otDir 'notes.json'))) ($ot | ConvertTo-Json -Compress)
# caught mid-write: skipped, and kept for the next look
[System.IO.File]::WriteAllText((Join-Path $otDir "$PID.json"), ('{"v":1,"pid":' + $PID + ',"tabs":[{"sessionId"'), $utf8)
$otMid = @(Read-ChatOpenTabs -Dir $otDir)
$otMidKept = Test-Path -LiteralPath (Join-Path $otDir "$PID.json")
# a pid alive but started days before the file says: another process's now
Write-OtFile $PID ($otStart - 3 * 86400000) @([ordered]@{ sessionId = $otA; cwd = 'C:\p\tabbed'; label = 'Tab A' })
$otReused = @(Read-ChatOpenTabs -Dir $otDir)
Check 'open tabs: a file caught mid-write skipped and kept; one whose pid a process started days apart has now, removed' (
    $otMid.Count -eq 0 -and $otMidKept -and $otReused.Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $otDir "$PID.json"))) "$($otMid.Count) $otMidKept $($otReused.Count)"
Check 'open tabs: no folder at all - nothing, and no error' (@(Read-ChatOpenTabs -Dir (Join-Path $sb 'no-such-open-tabs')).Count -eq 0) ''
# read every 2 s on the panel's thread: a file parsed again only once its
# text changed, and its window looked for once in 10 s - so a window that
# died is gone 10 s on at most. A hidden ping stands in for the window.
$otPing = { Start-Process (Join-Path $env:SystemRoot 'System32\PING.EXE') -ArgumentList '-n', '60', '127.0.0.1' -WindowStyle Hidden -PassThru }
# a ping killed, then waited for until Get-Process no longer finds it - 5 s
# at most. On a busy runner Get-Process still found one right after
# WaitForExit, so Read-ChatHostFiles, which asks it, kept its tab.
$otKill = {
    param($P)
    Stop-Process -Id $P.Id -Force
    $P.WaitForExit()
    $until = (Get-Date).AddSeconds(5)
    while ((Get-Process -Id $P.Id -EA SilentlyContinue) -and (Get-Date) -lt $until) { Start-Sleep -Milliseconds 50 }
}
$otChild = & $otPing
$otBack = & $otPing
try {
    $otCs = [DateTimeOffset]::new($otChild.StartTime).ToUnixTimeMilliseconds()
    $otT0 = Get-Date
    Write-OtFile $otChild.Id $otCs @([ordered]@{ sessionId = $otA; cwd = 'C:\p\tabbed'; label = 'one' })
    $otK1 = @(Read-ChatOpenTabs -Dir $otDir -Now $otT0)
    Write-OtFile $otChild.Id $otCs @([ordered]@{ sessionId = $otA; cwd = 'C:\p\tabbed'; label = 'two' })
    $otK2 = @(Read-ChatOpenTabs -Dir $otDir -Now $otT0.AddSeconds(1))
    # the same text: what was parsed, not a parse of its own
    $otD1 = @(Read-ChatHostFiles $otDir $otT0.AddSeconds(2))[0].Data
    $otD2 = @(Read-ChatHostFiles $otDir $otT0.AddSeconds(3))[0].Data
    & $otKill $otChild
    $otK9 = @(Read-ChatOpenTabs -Dir $otDir -Now $otT0.AddSeconds(9))
    $otK11 = @(Read-ChatOpenTabs -Dir $otDir -Now $otT0.AddSeconds(11))
    # the clock set back: a look taken "later" than now counts for nothing,
    # so a window gone since is let go at once, not an hour on
    Write-OtFile $otBack.Id ([DateTimeOffset]::new($otBack.StartTime).ToUnixTimeMilliseconds()) @([ordered]@{ sessionId = $otB; cwd = 'C:\p\tabbed'; label = 'back' })
    $otB1 = @(Read-ChatOpenTabs -Dir $otDir -Now $otT0.AddHours(1))
    & $otKill $otBack
    $otB2 = @(Read-ChatOpenTabs -Dir $otDir -Now $otT0)
}
finally { Stop-Process -Id $otChild.Id, $otBack.Id -Force -EA SilentlyContinue }
Check 'open tabs: a file parsed again once its text changed, and its window looked for once in 10 s - one that died listed 10 s more at most, then its file removed' (
    $otK1.Count -eq 1 -and $otK1[0].Label -eq 'one' -and $otK1[0].HostPid -eq $otChild.Id -and $otK2.Count -eq 1 -and $otK2[0].Label -eq 'two' -and
    $otD1 -and [object]::ReferenceEquals($otD1, $otD2) -and
    $otK9.Count -eq 1 -and $otK11.Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $otDir "$($otChild.Id).json"))) "$($otK1.Count) $($otK2.Count) $([object]::ReferenceEquals($otD1, $otD2)) $($otK9.Count) $($otK11.Count)"
Check 'open tabs: a clock set back looks for the window again - one gone since is let go at once' (
    $otB1.Count -eq 1 -and $otB1[0].Label -eq 'back' -and $otB2.Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $otDir "$($otBack.Id).json"))) "$($otB1.Count) $($otB2.Count)"
Remove-Item -LiteralPath $otDir -Recurse -Force
# the scan the overlay runs every minute reads a transcript again only once it moved
$cutCache = @{}
$script:ChatqCutOffReads = 0
$cut1 = @(Get-ChatqCutOffChats @() -Cache $cutCache)
$reads1 = $script:ChatqCutOffReads
$cut2 = @(Get-ChatqCutOffChats @() -Cache $cutCache)
$reads2 = $script:ChatqCutOffReads - $reads1
# the new chat the limit cut above: its limit record has no cwd of its own
$cutNl = @($cut1 | Where-Object { $_.Id -eq $nl.sessionId })[0]
Check 'the cut-off scan reads what moved and nothing else, and says where each chat ran' (
    $cut1.Count -ge 1 -and $cut2.Count -eq $cut1.Count -and $reads1 -ge 1 -and $reads2 -eq 0 -and $cutNl.Path -eq $nl.path -and $cutNl.Cwd -eq $newDir) "$($cut1.Count) chats, $reads1 then $reads2 reads, $($cutNl.Cwd)"
# one working now is neither read nor listed - and, forgotten by the cache,
# is read on the next pass that does not skip it
$r0 = $script:ChatqCutOffReads
$cutSkip = @(Get-ChatqCutOffChats @() -Cache $cutCache -Skip @($nl.sessionId))
$readsSkip = $script:ChatqCutOffReads - $r0
$null = @(Get-ChatqCutOffChats @() -Cache $cutCache)
# it moved on: read again, only it, and off the list
$okRec = [ordered]@{ type = 'assistant'; uuid = [guid]::NewGuid().ToString(); timestamp = (Get-Date).ToUniversalTime().ToString('o'); sessionId = $nl.sessionId
    message = [ordered]@{ model = 'claude-fake-1'; role = 'assistant'; content = @([ordered]@{ type = 'text'; text = 'carried on' }) } } | ConvertTo-Json -Compress -Depth 6
[System.IO.File]::AppendAllText($nl.path, $okRec + "`n", $utf8)
$r0 = $script:ChatqCutOffReads
$cutMoved = @(Get-ChatqCutOffChats @() -Cache $cutCache)
$readsMoved = $script:ChatqCutOffReads - $r0
Check 'one working is neither read nor listed; one that moved on is read once more, and leaves' (
    $readsSkip -eq 0 -and $cutSkip.Count -eq $cut1.Count - 1 -and -not @($cutSkip | Where-Object { $_.Id -eq $nl.sessionId }) -and
    $readsMoved -eq 1 -and $cutMoved.Count -eq $cut1.Count - 1 -and -not @($cutMoved | Where-Object { $_.Id -eq $nl.sessionId })) "skip: $readsSkip reads, $($cutSkip.Count); moved: $readsMoved reads, $($cutMoved.Count) of $($cut1.Count)"

# commands, the lock, and the handoffs
$script:ChatOverlayStopWaitMs = 400
$script:OvSpawned = 0
$script:ChatOverlaySpawn = { $script:OvSpawned++; $true }
Remove-Item -LiteralPath $script:ChatOverlayCmdPath -Force -EA SilentlyContinue
$ovLock = [System.IO.File]::Open($script:ChatOverlayLockPath, 'OpenOrCreate', 'ReadWrite', 'None')
try {
    chatoverlay *> $null
    $cmds = [System.IO.File]::ReadAllText($script:ChatOverlayCmdPath)
    Check 'a running overlay is shown, never started twice' ($script:OvSpawned -eq 0 -and $cmds -match ' show\n') $cmds
    chatoverlay -Stop *> $null
    chatinstall *> $null
    chatuninstall *> $null
    $cmds = [System.IO.File]::ReadAllText($script:ChatOverlayCmdPath)
    Check '-Stop, chatinstall and chatuninstall each tell it' ($cmds -match ' stop\n' -and $cmds -match ' restart\n' -and ([regex]::Matches($cmds, ' stop\n')).Count -eq 2) ($cmds -replace "`n", ' | ')
}
finally { $ovLock.Dispose() }
[System.IO.File]::AppendAllText($script:ChatOverlayCmdPath, "$((Get-Date).ToUniversalTime().AddMinutes(-10).ToString('o')) hide`n", $utf8)
$verbs = @(Receive-ChatOverlayCommands)
Check 'commands are taken once, and a stale one is dropped' (($verbs -join ',') -eq 'show,stop,restart,stop' -and -not (Test-Path -LiteralPath $script:ChatOverlayCmdPath)) ($verbs -join ',')
Send-ChatOverlayCommand 'restart'
$why = Invoke-ChatOverlayCollectLoop (New-ChatOverlayContext) -IntervalMs 10 -MaxCycles 3
$why2 = Invoke-ChatOverlayCollectLoop (New-ChatOverlayContext) -IntervalMs 10 -MaxCycles 2
Check 'the collector loop ends on a restart, or after its passes' ($why -eq 'restart' -and $why2 -eq 'max') "$why $why2"
# chatconsole: a running overlay is told; else one starts with the console
# open - a command left for it would be swept away as it takes its lock
function Get-OvToldCommands([scriptblock]$Do) {
    Remove-Item -LiteralPath $script:ChatOverlayCmdPath -Force -EA SilentlyContinue
    $ovLock = [System.IO.File]::Open($script:ChatOverlayLockPath, 'OpenOrCreate', 'ReadWrite', 'None')
    try { & $Do *> $null; [System.IO.File]::ReadAllText($script:ChatOverlayCmdPath) } finally { $ovLock.Dispose() }
    Remove-Item -LiteralPath $script:ChatOverlayCmdPath -Force -EA SilentlyContinue
}
$cmdsC = Get-OvToldCommands { chatconsole }
$script:OvSpawned = 0
chatconsole *> $null
$launchC = Get-ChatOverlayLaunch -Open console
Check 'chatconsole: a running overlay is told to open it; otherwise one starts with it open' (
    $cmdsC -match ' console\n' -and $script:OvSpawned -eq 1 -and $launchC.Command -like "*Start-ChatOverlayHost -Open 'console'*") "$cmdsC / $($script:OvSpawned)"
Check 'and the snapshot it saves has no BOM and keeps Hangul' ((Test-Path -LiteralPath $script:ChatOverlayPath) -and
    ([System.IO.File]::ReadAllBytes($script:ChatOverlayPath)[0] -eq [byte][char]'{') -and
    ([System.IO.File]::ReadAllText($script:ChatOverlayPath, $utf8).Contains($tCustom)))
$saved = [System.IO.File]::ReadAllText($script:ChatOverlayPath, $utf8) | ConvertFrom-Json
Check 'schema 1, times as epoch milliseconds' ($saved.schema -eq 1 -and [double]$saved.at -gt 1.7e12 -and @($saved.rows | Where-Object { $_.since -and [double]$_.since -gt 1.7e12 }).Count)
chatoverlay -Unlock *> $null
chatoverlay -Reset *> $null
chatoverlay -Collapse *> $null
$ost = Read-ChatOverlayState
chatoverlay -Expand *> $null
Check 'not running: -Unlock, -Reset and -Collapse wait in overlay-state.json' ((-not $ost.locked) -and $null -eq $ost.x -and $ost.collapsed -and -not (Read-ChatOverlayState).collapsed)
chatoverlay -Lock *> $null
chatoverlay -AutoStart on *> $null
Check '-AutoStart on is kept in config.json, and read at shell start' ((Get-ChatqConfig).overlay.autoStart -eq $true -and (Test-ChatOverlayAutoStart))
chatoverlay -AutoStart off *> $null
$offKept = (Get-ChatqConfig).overlay.autoStart -eq $false -and -not (Test-ChatOverlayAutoStart)
# Start-ChatOverlayAuto, what a shell and each VS Code window run: one line,
# and the launch's own words kept off it
$script:ChatOverlaySpawn = { $script:OvSpawned++; Write-Host 'launch noise'; $true }
$script:OvSpawned = 0
$auOff = @(Start-ChatOverlayAuto *>&1 | ForEach-Object { "$_" })
$auOffN = $script:OvSpawned
Check '-AutoStart off is kept, and honoured: off, nothing started' ($offKept -and ($auOff -join '|') -eq 'off' -and $auOffN -eq 0) "$offKept $($auOff -join '|') $auOffN"
chatoverlay -AutoStart on *> $null
$ovLock = [System.IO.File]::Open($script:ChatOverlayLockPath, 'OpenOrCreate', 'ReadWrite', 'None')
try { $auRun = @(Start-ChatOverlayAuto *>&1 | ForEach-Object { "$_" }) } finally { $ovLock.Dispose() }
$auRunN = $script:OvSpawned
$auGo = @(Start-ChatOverlayAuto *>&1 | ForEach-Object { "$_" })
$auGoN = $script:OvSpawned
$script:ChatOverlaySpawn = { $script:OvSpawned++; $false }
$auBad = @(Start-ChatOverlayAuto *>&1 | ForEach-Object { "$_" })
$script:ChatOverlaySpawn = { $script:OvSpawned++; $true }
Check 'Start-ChatOverlayAuto: running when it runs, started once through the launch, failed when that fails - one line each' (
    ($auRun -join '|') -eq 'running' -and $auRunN -eq 0 -and ($auGo -join '|') -eq 'started' -and $auGoN -eq 1 -and ($auBad -join '|') -eq 'failed') "$($auRun -join '|') $auRunN / $($auGo -join '|') $auGoN / $($auBad -join '|')"
# why it failed goes to overlay.log - the launch's own words, or what it threw -
# since nobody reads a shell's start or the extension's call
$afTag = "t$([guid]::NewGuid().ToString('N').Substring(0, 8))"
$script:ChatOverlaySpawn = { Write-Host "  cannot start the overlay: $afTag"; $false }
$afSaid = @(Start-ChatOverlayAuto *>&1 | ForEach-Object { "$_" })
$script:ChatOverlaySpawn = { throw "threw $afTag" }
$afThrew = @(Start-ChatOverlayAuto *>&1 | ForEach-Object { "$_" })
$script:ChatOverlaySpawn = { $script:OvSpawned++; $true }
$afLog = @([System.IO.File]::ReadAllLines((Join-Path $script:ChatqLogDir 'overlay.log'), $utf8) | Where-Object { $_ -like "*$afTag*" })
Check 'a failed auto-start leaves one line in overlay.log with the reason, and still says only failed' (
    ($afSaid -join '|') -eq 'failed' -and ($afThrew -join '|') -eq 'failed' -and $afLog.Count -eq 2 -and
    $afLog[0].EndsWith("  auto-start failed: cannot start the overlay: $afTag") -and $afLog[1].EndsWith("  auto-start failed: threw $afTag")) "$($afSaid -join '|') $($afThrew -join '|') / $($afLog -join ' / ')"
# on by default on Windows: no overlay block, or no config.json at all
$cfgOv = [System.IO.File]::ReadAllText($script:ChatqConfigPath, $utf8)
$cfgNoOv = Get-ChatqConfig
$cfgNoOv.PSObject.Properties.Remove('overlay')
Save-ChatqJson $script:ChatqConfigPath $cfgNoOv
$defBlock = (Get-ChatOverlayConfig).autoStart
$defBlockT = Test-ChatOverlayAutoStart
Remove-Item -LiteralPath $script:ChatqConfigPath -Force
$defNone = (Get-ChatOverlayConfig).autoStart
$defNoneT = Test-ChatOverlayAutoStart
$script:OvSpawned = 0
$defGo = @(Start-ChatOverlayAuto *>&1 | ForEach-Object { "$_" })
[System.IO.File]::WriteAllText($script:ChatqConfigPath, $cfgOv, $utf8)
Check 'autoStart on by default on Windows, with no overlay block or no config.json - and started then' (
    $defBlock -eq $script:ChatqIsWindows -and $defNone -eq $script:ChatqIsWindows -and $defBlockT -eq $script:ChatqIsWindows -and $defNoneT -eq $script:ChatqIsWindows -and
    ($defGo -join '|') -eq $(if ($script:ChatqIsWindows) { 'started' } else { 'off' }) -and $script:OvSpawned -eq [int]$script:ChatqIsWindows) "$defBlock $defBlockT $defNone $defNoneT $($defGo -join '|') $($script:OvSpawned)"
# a config.json that is there but does not read may be the one that says
# off: off, not the default
[System.IO.File]::WriteAllText($script:ChatqConfigPath, '{"overlay":{"autoStart":fal', $utf8)
$badT = Test-ChatOverlayAutoStart
$script:OvSpawned = 0
$badGo = @(Start-ChatOverlayAuto *>&1 | ForEach-Object { "$_" })
[System.IO.File]::WriteAllText($script:ChatqConfigPath, $cfgOv, $utf8)
Check 'a config.json that does not read: off, not the default - nothing started' (-not $badT -and ($badGo -join '|') -eq 'off' -and $script:OvSpawned -eq 0) "$badT $($badGo -join '|') $($script:OvSpawned)"
# A close by hand holds until the next sign-in: kept in overlay-state.json
# against when this one began (a synthetic sign-in here), and honoured by
# the auto start - off, as -AutoStart off is - but not by the next sign-in
$script:ChatqSignInSeam = { 1700000000000 }
$script:OvSpawned = 0
$chStop = (chatoverlay -Stop *>&1 | Out-String -Width 300).Trim()
$chMark = (Read-ChatOverlayState).closedSignIn
$chAuto = @(Start-ChatOverlayAuto *>&1 | ForEach-Object { "$_" })
$chAutoN = $script:OvSpawned
$script:ChatqSignInSeam = { 1700000900000 }
$chNext = @(Start-ChatOverlayAuto *>&1 | ForEach-Object { "$_" })
$chNextN = $script:OvSpawned
Check 'closed by hand: -Stop keeps it against this sign-in and says so; the auto start says off and starts nothing - the next sign-in starts it' (
    $chStop -eq 'the overlay is not running - it stays closed until you next sign in, or chatoverlay starts it' -and [int64]$chMark -eq 1700000000000 -and
    ($chAuto -join '|') -eq 'off' -and $chAutoN -eq 0 -and ($chNext -join '|') -eq 'started' -and $chNextN -eq 1) "$chStop / $chMark / $($chAuto -join '|') $chAutoN / $($chNext -join '|') $chNextN"
# chatoverlay itself, and -AutoStart on, lift it; where no sign-in can be
# told, nothing is kept and nothing is promised
$script:ChatqSignInSeam = { 1700000000000 }
[void](Set-ChatOverlayClosed)
$chHeld = Test-ChatOverlayClosedByHand
# a launch that fails: lifted all the same, and no wait for one to come up
$script:ChatOverlaySpawn = { $false }
chatoverlay *> $null
$script:ChatOverlaySpawn = { $script:OvSpawned++; $true }
$chBare = (Read-ChatOverlayState).closedSignIn
[void](Set-ChatOverlayClosed)
chatoverlay -AutoStart on *> $null
$chOn = (Read-ChatOverlayState).closedSignIn
$script:ChatqSignInSeam = { $null }
$chNone = (chatoverlay -Stop *>&1 | Out-String -Width 300).Trim()
$chNoneMark = (Read-ChatOverlayState).closedSignIn
$chNoneHeld = Test-ChatOverlayClosedByHand
$script:ChatqSignInSeam = $null
Check 'chatoverlay and -AutoStart on lift a close by hand; no sign-in known: nothing kept, the -Stop says only that it is not running' (
    $chHeld -and $null -eq $chBare -and $null -eq $chOn -and $chNone -eq 'the overlay is not running' -and $null -eq $chNoneMark -and -not $chNoneHeld) "$chHeld / $chBare / $chOn / $chNone / $chNoneMark $chNoneHeld"
# chatuninstall's stop is no close: a chatinstall after it in the same
# sign-in starts the overlay again
$script:ChatqSignInSeam = { 1700000000000 }
[void](Set-ChatOverlayClosed)
$chUnWas = Test-ChatOverlayClosedByHand
chatuninstall *> $null
$chUn = (Read-ChatOverlayState).closedSignIn
$script:ChatqSignInSeam = $null
Check 'chatuninstall lifts a close by hand: a reinstall in this sign-in is not left closed' ($chUnWas -and $null -eq $chUn) "$chUnWas / $chUn"
# the real sign-in, where the seams stand in everywhere else: this
# session's sihost (or Explorer) start - read, the same each time, and
# before this process began
if ($script:ChatqIsWindows) {
    $siA = Get-ChatqSignInAt
    $siB = Get-ChatqSignInAt
    $siMe = ConvertTo-ChatOverlayMs (Get-Process -Id $PID).StartTime
    Check 'Get-ChatqSignInAt reads this sign-in: there, the same twice, not after this process started' (
        $null -ne $siA -and [int64]$siA -eq [int64]$siB -and [int64]$siA -le [int64]$siMe) "$siA $siB $siMe"
}
# The code the overlay loaded, looked at again once a minute: a change -
# a newer write, or a copy that kept the old times but not the length -
# restarts it once it has held still 5 s; none noted, never.
$csDir = Join-Path $sb 'codestamp'
$csSrc = Join-Path $csDir 'src'
New-ChatqDir $csSrc
$csMain = Join-Path $csDir 'main.ps1'
[System.IO.File]::WriteAllText($csMain, '# main')
[System.IO.File]::WriteAllText((Join-Path $csSrc 'a.ps1'), '# a')
$csFn = ${function:Get-ChatOverlayCodeStamp}
$csWas = Get-ChatOverlayCodeStamp $csMain $csSrc
${function:Get-ChatOverlayCodeStamp} = { & $csFn $csMain $csSrc }
try {
    $csCtx = New-ChatOverlayContext
    $csNever = Test-ChatOverlayCodeChanged $csCtx
    $csT0 = Get-Date
    $csCtx.CodeStamp = $csWas
    $csCtx.CodeLookAt = $csT0
    $csSame = Test-ChatOverlayCodeChanged $csCtx $csT0.AddSeconds(61)
    [System.IO.File]::WriteAllText((Join-Path $csSrc 'a.ps1'), '# a, longer')
    (Get-Item -LiteralPath (Join-Path $csSrc 'a.ps1')).LastWriteTime = [datetime]'2020-01-01'
    $csSoon = Test-ChatOverlayCodeChanged $csCtx $csT0.AddSeconds(90)
    $csSeen = Test-ChatOverlayCodeChanged $csCtx $csT0.AddSeconds(122)
    $csHeld = Test-ChatOverlayCodeChanged $csCtx $csT0.AddSeconds(124)
    $csGo = Test-ChatOverlayCodeChanged $csCtx $csT0.AddSeconds(127)
    [System.IO.File]::WriteAllText((Join-Path $csSrc 'b.ps1'), '# b')
    $csMore = Test-ChatOverlayCodeChanged $csCtx $csT0.AddSeconds(128)
    $csMoreGo = Test-ChatOverlayCodeChanged $csCtx $csT0.AddSeconds(134)
}
finally { ${function:Get-ChatOverlayCodeStamp} = $csFn }
$csGone = Get-ChatOverlayCodeStamp (Join-Path $csDir 'no-such.ps1') $csSrc
Check 'a code change: looked at once a minute, a restart only once it held 5 s - a new part holds it off again; none noted or no script, never' (
    $csWas -like 'main.ps1:*|a.ps1:*' -and -not $csNever -and -not $csSame -and -not $csSoon -and -not $csSeen -and -not $csHeld -and $csGo -and
    -not $csMore -and $csMoreGo -and $null -eq $csGone) "$csWas / $csNever $csSame $csSoon $csSeen $csHeld $csGo $csMore $csMoreGo / $csGone"
chatoverlay -AutoStart off *> $null
# the overlay log: a line once in 5 minutes, unless it is something clicked
$olTag = "open: t$([guid]::NewGuid().ToString('N').Substring(0, 8))"
Write-ChatOverlayLog $olTag
Write-ChatOverlayLog $olTag
Write-ChatOverlayLog "$olTag ended 0" -Always
Write-ChatOverlayLog "$olTag ended 0" -Always
$olLines = @([System.IO.File]::ReadAllLines((Join-Path $script:ChatqLogDir 'overlay.log'), $utf8))
$olOnce = @($olLines | Where-Object { $_.EndsWith("  $olTag") }).Count
$olTwice = @($olLines | Where-Object { $_.EndsWith("  $olTag ended 0") }).Count
Check 'overlay.log: the same line once in 5 minutes; with -Always, every time' ($olOnce -eq 1 -and $olTwice -eq 2) "$olOnce $olTwice"
# past 500 lines held back, those 5 minutes old let go as the next is
# written - a newer one still held back, an old one written again
$olSeen = $script:ChatOverlayLogSeen
$script:ChatOverlayLogSeen = @{}
try {
    $olOld = [datetime]::Now.AddMinutes(-6)
    foreach ($i in 1..600) { $script:ChatOverlayLogSeen["$olTag old $i"] = $olOld }
    foreach ($i in 1..10) { $script:ChatOverlayLogSeen["$olTag new $i"] = [datetime]::Now }
    Write-ChatOverlayLog "$olTag next"
    $olKept = $script:ChatOverlayLogSeen.Count
    Write-ChatOverlayLog "$olTag new 3"
    Write-ChatOverlayLog "$olTag old 7"
}
finally { $script:ChatOverlayLogSeen = $olSeen }
$olLines = @([System.IO.File]::ReadAllLines((Join-Path $script:ChatqLogDir 'overlay.log'), $utf8))
$olNew = @($olLines | Where-Object { $_.EndsWith("  $olTag new 3") }).Count
$olAgain = @($olLines | Where-Object { $_.EndsWith("  $olTag old 7") }).Count
Check 'overlay.log: past 500 lines held back, those 5 minutes old let go - a newer one still held back' ($olKept -eq 11 -and $olNew -eq 0 -and $olAgain -eq 1) "$olKept $olNew $olAgain"
chatoverlay -Hotkey 'Ctrl+Hyper+Q' *> $null
Check 'a hotkey it cannot read is refused, not saved' ((Get-ChatOverlayConfig).hotkey -eq 'Ctrl+Alt+Shift+O')
$chkDefault = (Get-ChatOverlayConfig).consoleHotkey
chatoverlay -ConsoleHotkey none *> $null
$chkNone = (Get-ChatOverlayConfig).consoleHotkey
chatoverlay -ConsoleHotkey 'Ctrl+Hyper+Q' *> $null
Check 'the console''s hotkey: Ctrl+Alt+Shift+Q unless set, none for no key, nonsense refused' (
    $chkDefault -eq 'Ctrl+Alt+Shift+Q' -and $chkNone -eq 'none' -and (Get-ChatOverlayConfig).consoleHotkey -eq 'none') "$chkDefault $chkNone"
Set-ChatOverlayConfig @{ consoleHotkey = 'Ctrl+Alt+Shift+Q' }
chatoverlay -Theme light -Opacity 85 *> $null
$oc = Get-ChatOverlayConfig
chatoverlay -Opacity 5 *> $null
Check '-Theme and -Opacity are kept, a percent read as one, nonsense refused' ($oc.theme -eq 'light' -and $oc.opacity -eq 0.85 -and (Get-ChatOverlayConfig).opacity -eq 0.85) "$($oc.theme) $($oc.opacity)"
Set-ChatOverlayConfig @{ theme = 'purple' }
Check 'a theme it does not know draws dark' ((Get-ChatOverlayConfig).theme -eq 'dark')
Set-ChatOverlayConfig @{ theme = 'dark'; opacity = 0.94 }
# the panel's size: -Width and -Rows, kept, and a running panel told
$wrSaid = @(chatoverlay -Width 460 -Rows 12 6>&1 | ForEach-Object { "$_" })
$wr1 = Get-ChatOverlayConfig
chatoverlay -Width 200 *> $null
chatoverlay -Width 801 *> $null
chatoverlay -Rows 0 *> $null
chatoverlay -Rows 31 -Width 500 *> $null
$wr2 = Get-ChatOverlayConfig
Check '-Width and -Rows are kept and said; out of range refused, and nothing else on that line saved either' (
    $wr1.width -eq 460 -and $wr1.maxRows -eq 12 -and ($wrSaid -join '|') -like '*width: 460*' -and ($wrSaid -join '|') -like '*rows: 12 at most*' -and
    $wr2.width -eq 460 -and $wr2.maxRows -eq 12) "$($wr1.width) $($wr1.maxRows) / $($wr2.width) $($wr2.maxRows) / $($wrSaid -join '|')"
Set-ChatOverlayConfig @{ width = 5000; maxRows = 0 }
$wrHeld = Get-ChatOverlayConfig
Set-ChatOverlayConfig @{ width = -3; maxRows = 99 }
$wrHeld2 = Get-ChatOverlayConfig
Check 'a width or row count out of range in config.json is held to it: 260 to 800, 1 to 30' (
    $wrHeld.width -eq 800 -and $wrHeld.maxRows -eq 1 -and $wrHeld2.width -eq 260 -and $wrHeld2.maxRows -eq 30) "$($wrHeld.width) $($wrHeld.maxRows) $($wrHeld2.width) $($wrHeld2.maxRows)"
$cmdsW = Get-OvToldCommands { chatoverlay -Width 420 -Rows 6 }
Check 'a running panel is told to reload them' ($cmdsW -match ' reload\n' -and (Get-ChatOverlayConfig).width -eq 420 -and (Get-ChatOverlayConfig).maxRows -eq 6) ($cmdsW -replace "`n", ' | ')
Set-ChatOverlayConfig @{ width = 380; maxRows = 8 }
$uvDefault = (Get-ChatOverlayConfig).usageView
$cxuDefault = (Get-ChatOverlayConfig).codexUsage
chatoverlay -UsageView bars -CopilotUsage off -CodexUsage off *> $null
$uvSet = Get-ChatOverlayConfig
Set-ChatOverlayConfig @{ usageView = 'sideways' }
Check 'usage as lines unless -UsageView bars; -CopilotUsage and -CodexUsage off kept; a view it does not know draws lines' (
    $uvDefault -eq 'lines' -and $uvSet.usageView -eq 'bars' -and -not $uvSet.copilotUsage -and $cxuDefault -and -not $uvSet.codexUsage -and
    (Get-ChatOverlayConfig).usageView -eq 'lines') "$uvDefault $($uvSet.usageView) $($uvSet.copilotUsage) $cxuDefault $($uvSet.codexUsage)"
Set-ChatOverlayConfig @{ usageView = 'lines'; copilotUsage = $true; codexUsage = $true }
# compact rows and the chip's rest: kept, said, a running panel told
$cmDefault = (Get-ChatOverlayConfig).prompts
$cmSaid = @(chatoverlay -Compact on -ChipDelay 250 6>&1 | ForEach-Object { "$_" })
$cm1 = Get-ChatOverlayConfig
chatoverlay -ChipDelay 50 *> $null
chatoverlay -ChipDelay 3001 -Compact off *> $null
$cm2 = Get-ChatOverlayConfig
$cmdsC = Get-OvToldCommands { chatoverlay -Compact off -ChipDelay 600 }
$cm3 = Get-ChatOverlayConfig
Check '-Compact on is the prompt line off, -ChipDelay kept, both said; out of range refused with the rest of its line; a running panel told' (
    $cmDefault -and -not $cm1.prompts -and $cm1.chipDelayMs -eq 250 -and ($cmSaid -join '|') -like '*compact rows: on*' -and ($cmSaid -join '|') -like '*open chip: after a 250 ms rest*' -and
    -not $cm2.prompts -and $cm2.chipDelayMs -eq 250 -and $cmdsC -match ' reload\n' -and $cm3.prompts -and $cm3.chipDelayMs -eq 600) "$($cm1.prompts) $($cm1.chipDelayMs) / $($cm2.prompts) $($cm2.chipDelayMs) / $($cm3.prompts) $($cm3.chipDelayMs) / $($cmSaid -join '|')"
Set-ChatOverlayConfig @{ prompts = $true; chipDelayMs = 400 }
$script:ChatOverlaySpawn = { $true }

# the pure parts
$hk = ConvertFrom-ChatOverlayHotkey 'Ctrl+Alt+Shift+O'
$hk2 = ConvertFrom-ChatOverlayHotkey 'ctrl+win+F9'
$bad = @('O', 'Ctrl+Alt', 'Ctrl+Hyper+O') | Where-Object { try { $null = ConvertFrom-ChatOverlayHotkey $_; $true } catch { $false } }
Check 'hotkeys: modifiers and key read, none is none, nonsense refused' ($hk.Mods -eq 7 -and $hk.Vk -eq 0x4F -and $hk2.Mods -eq 10 -and $hk2.Vk -eq 0x78 -and
    $null -eq (ConvertFrom-ChatOverlayHotkey 'none') -and -not $bad) "$($hk.Mods)/$($hk.Vk) $($hk2.Mods)/$($hk2.Vk) $bad"
$scr = @([pscustomobject]@{ X = 0; Y = 0; Width = 1920; Height = 1040; Primary = $true }, [pscustomobject]@{ X = 1920; Y = 0; Width = 1920; Height = 1040; Primary = $false })
$pl1 = Get-ChatOverlayPlacement 3000 100 380 260 $scr
$pl2 = Get-ChatOverlayPlacement 5000 100 380 260 $scr
$pl3 = Get-ChatOverlayPlacement $null $null 380 260 $scr
Check 'placement: kept on a screen that has it, else the main one''s top right, 16 in from the top as from the right' ((-not $pl1.Moved) -and $pl1.X -eq 3000 -and $pl2.Moved -and $pl2.X -eq 1524 -and $pl2.Y -eq 16 -and $pl3.X -eq 1524 -and $pl3.Y -eq 16) "$($pl2.X),$($pl2.Y)"
$launch = Get-ChatOverlayLaunch
$decoded = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($launch.Args[-1]))
Check 'launched as powershell.exe -STA, marked as the overlay, every part loaded and CHATQ_ALLPARTS dropped before the panel starts' ($launch.Exe -like '*WindowsPowerShell*powershell.exe' -and $launch.Args -contains '-STA' -and
    $decoded -eq $launch.Command -and $decoded -like "*CHATQ_OVERLAY='1'*" -and $decoded -like '*Start-ChatOverlayHost*' -and $decoded -like "*$sb*" -and
    $decoded -like "*CHATQ_ALLPARTS='1'*Remove-Item -LiteralPath 'env:CHATQ_ALLPARTS'*Start-ChatOverlayHost*") $decoded
# and where it starts: your home folder, never the folder of the shell that
# started it, which it would hold for as long as the panel is open. Started
# for real, from a folder whose [1] Windows PowerShell 5.1 reads as a
# wildcard, with a stand-in script whose host only writes down the folder it
# finds itself in, and the CHATQ_ALLPARTS its load had and its host has.
# Started by a process without it. Linux has no overlay to start.
$ocwStub = Join-Path $sb 'overlay-stub-cwd.ps1'
[IO.File]::WriteAllText($ocwStub, @'
$global:OcwFile = Join-Path $PSScriptRoot 'overlay-cwd.txt'
$global:OcwAll = [string]$env:CHATQ_ALLPARTS
function Start-ChatOverlayHost { [IO.File]::WriteAllText($global:OcwFile, (@([Environment]::CurrentDirectory, $global:OcwAll, $env:CHATQ_ALLPARTS, $env:CHATQ_OVERLAY) -join '|')) }
function Start-ChatOverlayMacHost { Start-ChatOverlayHost }
'@, $utf8)
$ocwOut = Join-Path $sb 'overlay-cwd.txt'
$ocwFrom = Join-Path $sb 'ov[1]'
[void][IO.Directory]::CreateDirectory($ocwFrom)
if ($script:ChatqIsWindows -or $script:ChatIsMac) {
    $ocwWas = @{ Spawn = $script:ChatOverlaySpawn; Path = $script:ChatqScriptPath; All = $env:CHATQ_ALLPARTS }
    $script:ChatOverlaySpawn = $null
    $script:ChatqScriptPath = $ocwStub
    Remove-Item env:CHATQ_ALLPARTS -EA SilentlyContinue
    Push-Location -LiteralPath $ocwFrom
    try { $ocwOk = Start-ChatOverlayProcess }
    finally { Pop-Location; $script:ChatOverlaySpawn = $ocwWas.Spawn; $script:ChatqScriptPath = $ocwWas.Path; $env:CHATQ_ALLPARTS = $ocwWas.All }
    $ocwIn = ''
    $ocwUntil = (Get-Date).AddSeconds(60)
    while ($ocwOk -and -not $ocwIn -and (Get-Date) -lt $ocwUntil) {
        Start-Sleep -Milliseconds 200
        $ocwIn = try { [IO.File]::ReadAllText($ocwOut) } catch { '' }
    }
    $ocwAt, $ocwEnv = $ocwIn -split '\|', 2
    Check 'the overlay starts in your home folder, not the folder of the shell that started it, even one with [1] in its name' ($ocwOk -and
        ([string]$ocwAt).TrimEnd('\', '/') -eq $HOME.TrimEnd('\', '/')) "started $ocwOk, in '$ocwAt'"
    Check 'the overlay loads every part - its launch sets CHATQ_ALLPARTS - and its panel holds none of it, just the guard, for what the panel starts' ($ocwEnv -eq '1||1') "'$ocwEnv'"
}
Remove-Item -LiteralPath $ocwStub, $ocwOut, $ocwFrom -Force -EA SilentlyContinue
$script:ChatOverlaySystemDarkSeam = { $true }
$tDark = Resolve-ChatOverlayTheme 'system'
$script:ChatOverlaySystemDarkSeam = { $false }
$tLight = Resolve-ChatOverlayTheme 'system'
$script:ChatOverlaySystemDarkSeam = $null
Check 'theme: system follows Windows'' own setting' ($tDark -eq 'dark' -and $tLight -eq 'light' -and (Resolve-ChatOverlayTheme 'light') -eq 'light' -and (Resolve-ChatOverlayTheme '') -eq 'dark')
Check 'both looks name every colour' (@($script:ChatOverlayPalettes.dark.Keys | Where-Object { -not $script:ChatOverlayPalettes.light.ContainsKey($_) }).Count -eq 0)
# the buttons' window over the panel's top strip: panel and size in screen
# pixels, the bar 20 tall, 4 under the panel's top and 8 in from its right
$work = [pscustomobject]@{ X = 0; Y = 0; Width = 1920; Height = 1040 }
$cpAt = { param($p, $s, $pre = 'above', $box = 0) Get-ChatOverlayControlsPlacement $p $s $work 4 $pre 20 $box 4 8 }
$cp1 = & $cpAt @(1524, 200, 380, 400) @(364, 20)
$cp2 = & $cpAt @(1524, 0, 380, 400) @(364, 20)
Check 'the bar of buttons sits in the panel''s top strip, 4 under its top edge and 8 in from its right - at the screen''s top too' (
    $cp1.X -eq 1532 -and $cp1.Y -eq 204 -and $cp2.X -eq 1532 -and $cp2.Y -eq 4) "$($cp1.X),$($cp1.Y) / $($cp2.X),$($cp2.Y)"
# the panel's, not the screen's: off its left with the panel, and a box
# wider than a narrow panel's bar sticks out to its left
$cp3 = & $cpAt @(-300, 200, 380, 400) @(364, 20)
$cp4 = & $cpAt @(1640, 200, 260, 400) @(280, 168) 'above' 140
Check 'the bar follows the panel off the screen''s side; a box wider than a narrow panel sticks out to its left' ($cp3.X -eq -292 -and $cp3.Y -eq 204 -and $cp4.X -eq 1612) "$($cp3.X),$($cp3.Y) / $($cp4.X)"
# the 140-pixel box: above the panel, its foot 4 over the panel's top - so
# the bar, at the window's foot, stays at 404 - else under the bar; open,
# kept on its side while it fits there
$cp5 = & $cpAt @(1524, 400, 380, 400) @(364, 168) 'above' 140
$cp6 = & $cpAt @(1524, 100, 380, 400) @(364, 168) 'above' 140
$cp7 = & $cpAt @(1524, 400, 380, 400) @(364, 168) 'below' 140
$cp8 = & $cpAt @(1524, 950, 380, 90) @(364, 168) 'below' 140
Check 'the settings box opens above the panel where it fits, else under the bar over the rows, and keeps its side while it fits there' (
    $cp5.Side -eq 'above' -and $cp5.Y -eq 256 -and $cp6.Side -eq 'below' -and $cp6.Y -eq 104 -and $cp7.Side -eq 'below' -and $cp7.Y -eq 404 -and
    $cp8.Side -eq 'above' -and $cp8.Y -eq 806 -and $cp5.X -eq 1532) "$($cp5.Side) $($cp5.Y) / $($cp6.Side) $($cp6.Y) / $($cp7.Side) $($cp7.Y) / $($cp8.Side) $($cp8.Y)"
# a screen 250 tall and a 200-pixel box: it fits neither side, so it goes
# where more of it shows, whichever side it was kept on
$cpShort = [pscustomobject]@{ X = 0; Y = 0; Width = 1920; Height = 250 }
$cp9 = Get-ChatOverlayControlsPlacement @(1524, 60, 380, 150) @(364, 228) $cpShort 4 'above' 20 200 4 8
$cp10 = Get-ChatOverlayControlsPlacement @(1524, 180, 380, 60) @(364, 228) $cpShort 4 'below' 20 200 4 8
Check 'a box that fits neither side of the panel goes to the side with more room, so the least of it runs off the screen' (
    $cp9.Side -eq 'below' -and $cp9.Y -eq 64 -and $cp10.Side -eq 'above' -and $cp10.Y -eq -24) "$($cp9.Side) $($cp9.Y) / $($cp10.Side) $($cp10.Y)"
# the resize handle's drag: width, rows, pointer travel, row height, scale, right edge
$rz = { param($w, $n, $dx, $dy, $rh, $sc, $right, $col = $false) Get-ChatOverlayResize $w $n $dx $dy $rh $sc $right -Collapsed:$col }
$rzL = & $rz 380 8 -40 0 36 1 1904
$rzR = & $rz 380 8 1000 0 36 1 1904
$rzF = & $rz 380 8 -1000 0 54 1.5 1904
$rzS = & $rz 380 8 -60 0 54 1.5 1904
Check 'resize: left widens, right narrows, 260 to 800 - the right edge where it was, at 150% too' (
    $rzL.Width -eq 420 -and $rzL.Left -eq 1484 -and $rzR.Width -eq 260 -and $rzR.Left -eq 1644 -and $rzF.Width -eq 800 -and $rzF.Left -eq 704 -and
    $rzS.Width -eq 420 -and $rzS.Left -eq 1274) "$($rzL.Width)@$($rzL.Left) $($rzR.Width)@$($rzR.Left) $($rzF.Width)@$($rzF.Left) $($rzS.Width)@$($rzS.Left)"
$rzD = & $rz 380 8 0 80 36 1 1904
$rzU = & $rz 380 8 0 -35 36 1 1904
$rzU2 = & $rz 380 8 0 -40 36 1 1904
$rzLo = & $rz 380 8 0 -5000 36 1 1904
$rzHi = & $rz 380 8 0 5000 36 1 1904
Check 'resize: a row for each row''s height down, one off for each up, none within the first; 1 to 30' (
    $rzD.Rows -eq 10 -and $rzD.Steps -eq 2 -and $rzU.Rows -eq 8 -and $rzU.Steps -eq 0 -and $rzU2.Rows -eq 7 -and $rzLo.Rows -eq 1 -and $rzHi.Rows -eq 30 -and $rzD.Width -eq 380) "$($rzD.Rows) $($rzU.Rows)/$($rzU.Steps) $($rzU2.Rows) $($rzLo.Rows) $($rzHi.Rows)"
$rzC = & $rz 380 8 -20 500 36 1 1904 $true
$rz0 = & $rz 380 8 0 72 0 1 1904
$rz0b = & $rz 380 8 0 72 0 2 1904
Check 'resize: collapsed, width only; a row height not known taken as 36 units, scaled' (
    $rzC.Width -eq 400 -and $rzC.Rows -eq 8 -and $rzC.Steps -eq 0 -and $rz0.Rows -eq 10 -and $rz0b.Rows -eq 9) "$($rzC.Width) $($rzC.Rows) $($rz0.Rows) $($rz0b.Rows)"
# 3 rows drawn of 12 open - the screen's foot cut the rest - 8 kept: down
# never saves fewer than 8
$rzK = { param($dy) (Get-ChatOverlayResize 380 3 0 $dy 36 1 1904 -Kept 8 -Open 12).Rows }
Check 'resize from fewer rows drawn than kept: down never below those kept, past them a row a row''s height; up takes one off those drawn' (
    (& $rzK 40) -eq 8 -and (& $rzK 0) -eq 8 -and (& $rzK 10) -eq 8 -and (& $rzK 200) -eq 8 -and (& $rzK 216) -eq 9 -and (& $rzK -40) -eq 2) "$(& $rzK 40) $(& $rzK 0) $(& $rzK 216) $(& $rzK -40)"
# the panel's edges, by the compass: the side across from the one dragged held
$ezE = Get-ChatOverlayResize 380 8 40 0 36 1 1904 -Edge 'e' -Left 1524
$ezE2 = Get-ChatOverlayResize 380 8 -1000 0 36 1 1904 -Edge 'e' -Left 1524
$ezW = Get-ChatOverlayResize 380 8 -40 200 36 1 1904 -Edge 'w'
$ezN = Get-ChatOverlayResize 380 8 30 -80 36 1 1904 -Edge 'n'
$ezN2 = Get-ChatOverlayResize 380 8 0 40 36 1 1904 -Edge 'n'
$ezS = Get-ChatOverlayResize 380 8 -40 80 36 1 1904 -Edge 's'
$ezNE = Get-ChatOverlayResize 380 8 60 -80 54 1.5 1904 -Edge 'ne' -Left 1334
$ezNK = (Get-ChatOverlayResize 380 3 0 -40 36 1 1904 -Kept 8 -Edge 'n').Rows
Check 'an edge''s drag: the right side widens to the right, its left edge held; the top a row for each row''s height up; a side never the rows, the top or bottom never the width' (
    $ezE.Width -eq 420 -and $ezE.Left -eq 1524 -and $ezE.Rows -eq 8 -and $ezE2.Width -eq 260 -and $ezE2.Left -eq 1524 -and
    $ezW.Width -eq 420 -and $ezW.Left -eq 1484 -and $ezW.Rows -eq 8 -and $ezN.Rows -eq 10 -and $ezN.Steps -eq 2 -and $ezN.Width -eq 380 -and
    $ezN2.Rows -eq 7 -and $ezS.Rows -eq 10 -and $ezS.Width -eq 380 -and $ezNE.Width -eq 420 -and $ezNE.Rows -eq 9 -and $ezNE.Left -eq 1334 -and $ezNK -eq 8) (
    "e $($ezE.Width)@$($ezE.Left)/$($ezE.Rows) $($ezE2.Width)@$($ezE2.Left) w $($ezW.Width)@$($ezW.Left)/$($ezW.Rows) n $($ezN.Rows)/$($ezN.Width) $($ezN2.Rows) s $($ezS.Rows)/$($ezS.Width) ne $($ezNE.Width)@$($ezNE.Left)/$($ezNE.Rows) kept $ezNK")
# stretched into Recent: 4 rows drawn of 6 open, 4 kept, and 2 Recent lines
# drawn of the 5 there are, 2 kept - rows 36 pixels, lines 20
$rzOut = { param($dy) Get-ChatOverlayResize 380 4 0 $dy 36 1 1904 -Kept 4 -Open 6 -RecentDrawn 2 -RecentPool 5 -RecentKept 2 -RecentHeight 20 }
$rzSay = { param($z) "$($z.Rows)/$($z.Recent) $($z.Steps)/$($z.RecentSteps)" }
$ro1 = & $rzOut 40
$ro2 = & $rzOut 72
$ro3 = & $rzOut 92
$ro4 = & $rzOut 132
$ro5 = & $rzOut 5000
$ro20 = (Get-ChatOverlayResize 380 2 0 5000 36 1 1904 -Open 2 -RecentPool 30 -RecentKept 0 -RecentHeight 20).Recent
Check 'stretched out: the open rows not drawn come first, a row a row''s height; then Recent lines, a line a line''s height; past the pool, nothing more' (
    $ro1.Rows -eq 5 -and $ro1.Recent -eq 2 -and $ro2.Rows -eq 6 -and $ro2.Recent -eq 2 -and $ro3.Rows -eq 6 -and $ro3.Recent -eq 3 -and $ro4.Recent -eq 5 -and
    $ro5.Rows -eq 6 -and $ro5.Recent -eq 5 -and $ro5.Steps -eq 2 -and $ro5.RecentSteps -eq 3 -and $ro20 -eq 20) (
    "$(& $rzSay $ro1) $(& $rzSay $ro2) $(& $rzSay $ro3) $(& $rzSay $ro4) $(& $rzSay $ro5) pool30 $ro20")
# 3 Recent lines drawn this time
$rzIn = { param($dy, $e = 's') Get-ChatOverlayResize 380 4 0 $dy 36 1 1904 -Kept 4 -Open 6 -RecentDrawn 3 -RecentPool 5 -RecentKept 3 -RecentHeight 20 -Edge $e }
$ri1 = & $rzIn -19
$ri2 = & $rzIn -20
$ri3 = & $rzIn -60
$ri4 = & $rzIn -96
$ri5 = & $rzIn -5000
$riN = & $rzIn 20 'n'
Check 'stretched in: the Recent lines go first, then rows, never under one; Recent down to none - the top edge going down too' (
    $ri1.Rows -eq 4 -and $ri1.Recent -eq 3 -and $ri2.Rows -eq 4 -and $ri2.Recent -eq 2 -and $ri3.Rows -eq 4 -and $ri3.Recent -eq 0 -and
    $ri4.Rows -eq 3 -and $ri4.Recent -eq 0 -and $ri5.Rows -eq 1 -and $ri5.Recent -eq 0 -and $ri5.Steps -eq -3 -and $ri5.RecentSteps -eq -3 -and
    $riN.Rows -eq 4 -and $riN.Recent -eq 2) "$(& $rzSay $ri1) $(& $rzSay $ri2) $(& $rzSay $ri3) $(& $rzSay $ri4) $(& $rzSay $ri5) n $(& $rzSay $riN)"
# 3 rows drawn, all there are, 8 kept; 2 Recent lines drawn of 10 - the
# screen's foot cut the rest - 5 kept
$rzKR = { param($dy) Get-ChatOverlayResize 380 3 0 $dy 36 1 1904 -Kept 8 -Open 3 -RecentDrawn 2 -RecentPool 10 -RecentKept 5 -RecentHeight 20 }
$rk0 = & $rzKR 0
$rk1 = & $rzKR 20
$rk4 = & $rzKR 80
$rkAll = & $rzKR 216
$rkIn = & $rzKR -20
$rkRows = & $rzKR -80
Check 'the counts kept: no travel keeps rows and Recent as saved, outward never fewer - past every open row no more rows, only Recent; inward from those drawn' (
    $rk0.Rows -eq 8 -and $rk0.Recent -eq 5 -and $rk1.Rows -eq 8 -and $rk1.Recent -eq 5 -and $rk4.Rows -eq 8 -and $rk4.Recent -eq 6 -and
    $rkAll.Rows -eq 8 -and $rkAll.Recent -eq 10 -and $rkIn.Rows -eq 8 -and $rkIn.Recent -eq 1 -and $rkRows.Rows -eq 2 -and $rkRows.Recent -eq 0) (
    "$(& $rzSay $rk0) $(& $rzSay $rk1) $(& $rzSay $rk4) $(& $rzSay $rkAll) $(& $rzSay $rkIn) $(& $rzSay $rkRows)")
# no chat open, 8 kept, 4 Recent lines drawn: back up past them takes no
# rows, as none shows - maxRows stays 8
$rkNone = Get-ChatOverlayResize 380 8 0 -400 36 1 1904 -Kept 8 -Open 0 -RecentDrawn 4 -RecentPool 10 -RecentKept 4 -RecentHeight 20
Check 'with no chat open, travel in past the Recent lines takes no rows - maxRows kept as saved' (
    $rkNone.Rows -eq 8 -and $rkNone.Steps -eq 0 -and $rkNone.Recent -eq 0 -and $rkNone.RecentSteps -eq -4) (& $rzSay $rkNone)
# the top edge at 150%: rows 54 pixels, lines 30, the Recent header 36
$gUp = Get-ChatOverlayResize 380 4 0 -168 54 1.5 1904 -Edge 'n' -Open 6 -RecentDrawn 0 -RecentPool 5 -RecentKept 0 -RecentHeight 30 -HeadHeight 36
$gDown = Get-ChatOverlayResize 380 4 0 60 54 1.5 1904 -Edge 'n' -Open 6 -RecentDrawn 2 -RecentPool 5 -RecentKept 2 -RecentHeight 30 -HeadHeight 36
$gFold = Get-ChatOverlayResize 380 4 0 -168 54 1.5 1904 -Edge 'n' -Collapsed -Open 6 -RecentPool 5 -RecentKept 0 -RecentHeight 30 -HeadHeight 36
Check 'Grow, for the top edge''s cap: in WPF units, the rows and lines the travel came to, the Recent header with the first line and without the last; none folded' (
    $gUp.Rows -eq 6 -and $gUp.Recent -eq 2 -and $gUp.Grow -eq 136 -and $gDown.Recent -eq 0 -and $gDown.Rows -eq 4 -and $gDown.Grow -eq -64 -and
    $ezN.Grow -eq 72 -and $gFold.Grow -eq 0 -and $gFold.Rows -eq 4 -and $gFold.Recent -eq 0) "up $(& $rzSay $gUp) $($gUp.Grow) down $(& $rzSay $gDown) $($gDown.Grow) n $($ezN.Grow) fold $($gFold.Grow)"
$cu = { param($e, $f) Get-ChatOverlayEdgeCursor $e $f }
Check 'each edge''s cursor: up and down for the top and bottom, sideways for the sides, a diagonal for a corner - sideways for every corner while folded' (
    (& $cu 'n' $false) -eq 'SizeNS' -and (& $cu 's' $false) -eq 'SizeNS' -and (& $cu 'w' $false) -eq 'SizeWE' -and (& $cu 'e' $false) -eq 'SizeWE' -and
    (& $cu 'ne' $false) -eq 'SizeNESW' -and (& $cu 'sw' $false) -eq 'SizeNESW' -and (& $cu 'nw' $false) -eq 'SizeNWSE' -and (& $cu 'se' $false) -eq 'SizeNWSE' -and
    (& $cu 'ne' $true) -eq 'SizeWE' -and (& $cu 'se' $true) -eq 'SizeWE')
$edR = Get-ChatOverlayEdgesRect @(1524, 200, 380, 400) 5
Check 'the edges'' window: the panel''s rect, the band''s depth more on every side' (($edR -join ',') -eq '1519,195,390,410' -and $null -eq (Get-ChatOverlayEdgesRect @(1, 2) 5)) ($edR -join ',')
$capB = Get-ChatOverlayHeightCap 900 ([pscustomobject]@{ X = 0; Y = 40; Width = 1920; Height = 1000 }) 1.5 40 640
$capB0 = Get-ChatOverlayHeightCap 900 ([pscustomobject]@{ X = 0; Y = 40; Width = 1920; Height = 1000 }) 1 40 60
Check 'the height cap as the top edge is dragged: from the bottom held up to the working area''s top, never under the floor' ($capB -eq 400 -and $capB0 -eq 40) "$capB $capB0"
# the edges: shown, on panel, on buttons, dragging, button held, ms resting
# on the panel, ms since over either
$sh = { param($s, $p, $c, $d, $dn, $r, $o) [bool](Get-ChatOverlayControlsShown $s $p $c $d $dn $r $o) }
Check 'the edges come after the pointer rests on the panel, and stay while it is on it or the buttons, or a button is held' (
    -not (& $sh $false $true $false $false $false 120 0) -and (& $sh $false $true $false $false $false 360 0) -and
    (& $sh $true $false $true $false $false 0 0) -and (& $sh $true $false $false $false $true 0 5000) -and
    (& $sh $true $false $false $false $false 0 500) -and -not (& $sh $true $false $false $false $false 0 800) -and
    (& $sh $false $false $false $true $false 0 99999))
# the buttons' zone is their window's rect: an open box's gap to the panel
# is inside it
$z1 = Get-ChatOverlayControlsZone @(1532, 256, 364, 168)
Check 'the buttons'' zone is their window''s rect, an open box''s gap to the panel in it' (($z1 -join ',') -eq '1532,256,364,168' -and $null -eq (Get-ChatOverlayControlsZone @(1, 2))) "$($z1 -join ',')"
Check 'resting on the buttons brings the edges too, after the same 350 ms' (
    (& $sh $false $false $true $false $false 360 0) -and -not (& $sh $false $false $true $false $false 120 0))
Check 'never with a mouse button held - a drag in the app below would drop onto the edges' (
    -not (& $sh $false $false $true $false $true 360 0) -and -not (& $sh $false $true $false $false $true 360 0))
$bigSnap = [pscustomobject]@{ counts = [pscustomobject]@{ waiting = 12; needsInput = 3; busy = 40; running = 1; idle = 88; queued = 9 }; header = [pscustomobject]@{ usage = @() } }
Check 'the tray tooltip never goes past the 127 characters Windows keeps' ((Format-ChatOverlayTooltip $bigSnap).Length -le 127) (Format-ChatOverlayTooltip $bigSnap)

# the console's pure parts
$wNext = ConvertFrom-ChatConsoleWhen 'next' ''
$wOld = ConvertFrom-ChatConsoleWhen 'now' ''
$wTurn = ConvertFrom-ChatConsoleWhen 'turn' ''
$wIn = ConvertFrom-ChatConsoleWhen 'in' '2h'
$wAtBad = ConvertFrom-ChatConsoleWhen 'at' 'soonish'
$wInNone = ConvertFrom-ChatConsoleWhen 'in' ' '
Check 'console When: next is first and looked at every 30 s - and so is a draft''s old now - in turn is neither, at/in a time - or why not' (
    $wNext.First -and $wNext.SendNow -and -not $wNext.NotBefore -and $wOld.First -and $wOld.SendNow -and -not $wOld.Error -and -not $wTurn.First -and -not $wTurn.SendNow -and
    [Math]::Abs(($wIn.NotBefore - (Get-Date).AddHours(2)).TotalMinutes) -lt 1 -and $wAtBad.Error -like "'soonish' is not a time*" -and $wInNone.Error -like 'give a time*') "$($wAtBad.Error) / $($wInNone.Error)"
$chatsC = @(
    [pscustomobject]@{ Title = 'Card layout redesign'; Project = 'parser' }
    [pscustomobject]@{ Title = 'Rate limiter'; Project = 'api' }
    [pscustomobject]@{ Title = 'Release notes'; Project = 'parser' }
)
Check 'console search: every word, in the title or the project, any case; a cap' (
    @(Select-ChatConsoleChats $chatsC 'PARSER card').Count -eq 1 -and @(Select-ChatConsoleChats $chatsC 'parser').Count -eq 2 -and
    @(Select-ChatConsoleChats $chatsC '').Count -eq 3 -and @(Select-ChatConsoleChats $chatsC '' 2).Count -eq 2 -and -not @(Select-ChatConsoleChats $chatsC 'nothing').Count)
$pNow = [pscustomobject]@{ Error = $null; NotBefore = $null; First = $true; SendNow = $true }
$pTurn = [pscustomobject]@{ Error = $null; NotBefore = $null; First = $false; SendNow = $false }
$tn = Get-Date '2026-09-24T12:00:00'
$pv1 = Get-ChatConsoleSendPreview @{ Kind = 'chat'; Live = $null } $pNow $null 3 $true $tn
$pv2 = Get-ChatConsoleSendPreview @{ Kind = 'chat'; Live = 'busy' } $pNow ([pscustomobject]@{ Until = $tn.AddMinutes(59); Type = 'five_hour' }) 0 $false $tn
$pv3 = Get-ChatConsoleSendPreview @{ Kind = 'new'; Live = $null } $pTurn $null 2 $true $tn
$pv4 = Get-ChatConsoleSendPreview @{ Kind = 'chat'; Live = 'idle' } $pNow ([pscustomobject]@{ Until = $tn; Type = 'overloaded' }) 0 $true $tn
$pv5 = Get-ChatConsoleSendPreview $null $pNow $null 0 $true $tn
$pv6 = Get-ChatConsoleSendPreview @{ Kind = 'chat'; Live = $null } $pNow $null 0 $true $tn -Running 7
$pv7 = Get-ChatConsoleSendPreview @{ Kind = 'chat'; Live = $null } $pTurn $null 0 $true $tn -Running 7
Check 'console preview: what Send will do - soon, a limit, a busy chat, behind others, a new chat, a 529, the watcher, Next behind a run in progress' (
    $pv1 -eq 'sends within a few seconds' -and $pv2 -eq 'limited until 12:59 - sends 13:00 - that chat is working in VS Code - it goes once the chat is idle, looked at every 30 s - the watcher starts for it' -and
    $pv3 -like 'after the 2 queued ahead of it - a new chat*' -and $pv4 -like 'Claude is overloaded*open in VS Code*' -and $pv5 -like 'pick a chat*' -and
    $pv6 -eq 'sends once #7, running now, ends - one job runs at a time' -and $pv7 -eq $pv6) "$pv1 | $pv2 | $pv3 | $pv4 | $pv6 | $pv7"
# a refused login is no limit: it says what the CLI said, not "limited until"
$pvL = Get-ChatConsoleSendPreview @{ Kind = 'chat'; Live = $null } $pNow ([pscustomobject]@{ Until = $tn.AddMinutes(15); Type = 'login needed'; Why = 'login refused: OAuth token has expired. (401)' }) 0 $true $tn
$pvL2 = Get-ChatConsoleSendPreview @{ Kind = 'chat'; Live = $null } $pNow ([pscustomobject]@{ Until = $tn.AddMinutes(15); Type = 'login needed'; Why = 'probe' }) 0 $true $tn
$pvP = Get-ChatConsoleSendPreview @{ Kind = 'chat'; Live = $null } $pNow ([pscustomobject]@{ Until = $tn.AddMinutes(10); Type = 'probe failed'; Why = 'no claude CLI found' }) 0 $true $tn
Check 'console preview: a refused login says what the CLI said, an older block says login refused, a failed probe when it looks again - never "limited until"' (
    $pvL -like 'login refused: OAuth token has expired. (401) - log in or check the subscription*' -and $pvL2 -like 'login refused - log in*' -and
    $pvP -eq 'the limit could not be checked - looked at again 12:10' -and "$pvL $pvL2 $pvP" -notmatch 'limited until') "$pvL | $pvL2 | $pvP"
# the limit the preview names, from what the collector holds - nothing read
$soon = (Get-Date).AddMinutes(40)
$later = (Get-Date).AddMinutes(95)
$bUsage = Get-ChatConsoleBlock @{ Ctx = @{ Blocks = @{}; CutOff = @() }; Snap = [pscustomobject]@{ header = [pscustomobject]@{ usage = @(
                [pscustomobject]@{ provider = 'Claude'; windows = @([pscustomobject]@{ label = '5h'; limited = $true; resetsAt = ([DateTimeOffset]$soon).ToUnixTimeMilliseconds() }) }) } } } 'claude'
$bCut = Get-ChatConsoleBlock @{ Ctx = @{ Blocks = $null; CutOff = @(
            [pscustomobject]@{ Why = 'limit'; ResetsAt = $soon }, [pscustomobject]@{ Why = 'limit'; ResetsAt = $later }, [pscustomobject]@{ Why = 'overloaded'; ResetsAt = $null }) }
    Snap = [pscustomobject]@{ header = [pscustomobject]@{ usage = @() } } } 'claude'
$bNone = Get-ChatConsoleBlock @{ Ctx = @{ Blocks = @{}; CutOff = @([pscustomobject]@{ Why = 'limit'; ResetsAt = $later }) }; Snap = [pscustomobject]@{ header = [pscustomobject]@{ usage = @() } } } 'codex'
$bLogin = Get-ChatConsoleBlock @{ Ctx = @{ Blocks = @{ claude = [pscustomobject]@{ Until = $soon; Type = 'login needed'; Source = 'login refused: OAuth token has expired. (401)' } }; CutOff = @() }
    Snap = [pscustomobject]@{ header = [pscustomobject]@{ usage = @() } } } 'claude'
Check 'console: the limit ahead from a usage window marked limited, else the latest reset of the chats it cut off; Codex not from Claude''s; the watcher''s block with its words' (
    [Math]::Abs(($bUsage.Until - $soon).TotalSeconds) -lt 1 -and $bUsage.Type -eq '5h' -and [Math]::Abs(($bCut.Until - $later).TotalSeconds) -lt 1 -and -not $bNone -and
    $bLogin.Type -eq 'login needed' -and $bLogin.Why -eq 'login refused: OAuth token has expired. (401)') "$($bUsage.Until) $($bCut.Until) $bNone $($bLogin.Why)"
$js1 = Get-ChatConsoleJobStatus ([pscustomobject]@{ state = 'queued' }) '13:01'
$js2 = Get-ChatConsoleJobStatus ([pscustomobject]@{ state = 'needs-input'; result = [pscustomobject]@{ reason = 'Edit denied' } }) $null
$js3 = Get-ChatConsoleJobStatus ([pscustomobject]@{ state = 'failed'; result = [pscustomobject]@{ reason = 'chat gone' } }) $null
Check 'console queue: each job says where it stands, in its colour' ($js1.Text -eq 'sends 13:01' -and $js1.Tone -eq 'queued' -and $js2.Text -eq 'needs you - Edit denied' -and $js2.Tone -eq 'waiting' -and $js3.Text -eq 'failed - chat gone' -and $js3.Tone -eq 'error') "$($js1.Text) | $($js2.Text) | $($js3.Text)"
# a job the watcher held back for a reason of its own says that reason, in
# the words every reader shares - while the hold stands, and for a queued
# job only; any other wait is the ETA's
$dfNow = [datetime]'2026-09-28T14:10:00'
# as the watcher writes them: ISO, in UTC
$dfIso = { param([datetime]$d) $d.ToUniversalTime().ToString('o') }
$dfAt = & $dfIso $dfNow.AddMinutes(-8)
$dfJob = { param($why, $untilMin, $state = 'queued', $since = $dfAt)
    [pscustomobject]@{ id = 'df'; seq = 15; state = $state; deferWhy = $why; deferSince = $since; deferNote = 'npm run dev'
        deferUntil = $(if ($null -ne $untilMin) { & $dfIso $dfNow.AddMinutes($untilMin) } else { $null }) } }
$dfBg = Format-ChatOverlayDeferral (& $dfJob 'background' 5) $dfNow
$dfBgOld = Format-ChatOverlayDeferral (& $dfJob 'background' 5 'queued' (& $dfIso ([datetime]'2026-09-25T09:30:00'))) $dfNow
$dfBgNone = Format-ChatOverlayDeferral (& $dfJob 'background' 5 'queued' $null) $dfNow
$dfTab = Format-ChatOverlayDeferral (& $dfJob 'in-use' 1) $dfNow
$dfOthers = @((Format-ChatOverlayDeferral (& $dfJob 'background' -1) $dfNow), (Format-ChatOverlayDeferral (& $dfJob 'in-use' $null) $dfNow),
    (Format-ChatOverlayDeferral (& $dfJob 'vscode' 5) $dfNow), (Format-ChatOverlayDeferral (& $dfJob $null 5) $dfNow),
    (Format-ChatOverlayDeferral (& $dfJob 'background' 5 'running') $dfNow)) | Where-Object { $_ }
Check 'a held job''s reason: waits for a background command (since when), or for you to leave its tab; nothing once the hold is over, for another reason, or not queued' (
    $dfBg -eq 'waits for a background command (since 14:02)' -and $dfBgOld -eq 'waits for a background command (since Fri 09:30)' -and
    $dfBgNone -eq 'waits for a background command' -and $dfTab -eq 'waits for you to leave its tab' -and -not @($dfOthers).Count) "$dfBg | $dfBgOld | $dfBgNone | $dfTab | $(@($dfOthers) -join ',')"
# one maker of the words: the lists' and the history's (Format-ChatqDeferWhy)
# are the panel's, word for word, a wait from last week included; a busy
# chat, a reason of its own now, has no words - its time says it
$dfWeek = & $dfIso ([datetime]'2026-09-19T09:30:00')
$dfSame = @(foreach ($dfA in @(@('background', $dfAt), @('background', (& $dfIso ([datetime]'2026-09-25T09:30:00'))), @('background', $dfWeek), @('background', $null), @('in-use', $dfAt))) {
        $jb = & $dfJob $dfA[0] 5 'queued' $dfA[1]
        if ((Format-ChatqDeferWhy $jb $dfNow) -ne (Format-ChatOverlayDeferral $jb $dfNow)) { "$($dfA[0]) $($dfA[1])" } })
$dfWeekSays = Format-ChatqDeferWhy (& $dfJob 'background' 5 'queued' $dfWeek) $dfNow
$dfBusy = @((Format-ChatqDeferWhy (& $dfJob 'busy' 5) $dfNow), (Format-ChatOverlayDeferral (& $dfJob 'busy' 5) $dfNow)) | Where-Object { $_ }
Check 'a wait''s words come from one formatter: the lists'' and the panel''s the same, a week-old start as its date; busy has none' (
    -not $dfSame.Count -and $dfWeekSays -eq 'waits for a background command (since Sep 19)' -and -not @($dfBusy).Count) "$($dfSame -join ',') | $dfWeekSays | $(@($dfBusy) -join ',')"
$dfCon = Get-ChatConsoleJobStatus (& $dfJob 'background' 5) '14:15 (chat busy)' $dfNow
$dfConTab = Get-ChatConsoleJobStatus (& $dfJob 'in-use' 1) $null $dfNow
$dfConDone = Get-ChatConsoleJobStatus (& $dfJob 'background' -1) '14:15' $dfNow
$dfSid = '0d0d0d0d-0d0d-40d0-80d0-0d0d0d0d0d01'
$dfRows = @(Get-ChatOverlayRows -Now $dfNow -Sessions @([pscustomobject]@{ SessionId = $dfSid; Pid = 1; Status = 'idle'; Cwd = 'C:\p\df'; StatusUpdatedAt = 1; Entrypoint = 'claude-vscode' }) `
        -Texts @{ $dfSid = @{ Path = 'x'; AiTitle = 'held' } } -Eta @{ df = '14:15 (chat busy)'; df2 = '14:20' } -Jobs @(
        [pscustomobject]@{ First = 'x'; Job = [pscustomobject]@{ id = 'df'; seq = 15; state = 'queued'; provider = 'claude'; sessionId = $dfSid; title = 'held'; cwd = 'C:\p\df'
                createdAt = $null; deferWhy = 'in-use'; deferUntil = (& $dfIso $dfNow.AddMinutes(1)) } }
        [pscustomobject]@{ First = 'y'; Job = [pscustomobject]@{ id = 'df2'; seq = 16; state = 'queued'; provider = 'claude'; sessionId = 'gone'; title = 'other'; cwd = 'C:\p\df'
                createdAt = $null; deferWhy = 'background'; deferSince = $dfAt; deferUntil = (& $dfIso $dfNow.AddMinutes(5)) } }))
$dfOn = @($dfRows | Where-Object { $_.key -eq "s:$dfSid" })[0].stateText
$dfOwn = @($dfRows | Where-Object { $_.key -eq 'j:df2' })[0].stateText
Check 'the console and the panel''s rows say a held job''s reason where its send time would be; a hold that is over, its ETA again' (
    $dfCon.Text -eq 'waits for a background command (since 14:02)' -and $dfCon.Tone -eq 'queued' -and $dfConTab.Text -eq 'waits for you to leave its tab' -and
    $dfConDone.Text -eq 'sends 14:15' -and $dfOn -like '#15 waits for you to leave its tab *' -and $dfOwn -eq '#16 waits for a background command (since 14:02)') "$($dfCon.Text) | $($dfConTab.Text) | $($dfConDone.Text) | $dfOn | $dfOwn"
$areaC = [pscustomobject]@{ X = 0; Y = 0; Width = 1536; Height = 816 }
# a panel 380 wide at the top right: the console's right edge and top are the panel's
$plNew = Get-ChatConsolePlacement @(1100, 100, 380, 200) $null $areaC
$plKept = Get-ChatConsolePlacement @(1100, 100, 380, 200) ([pscustomobject]@{ x = 5; y = 5; w = 900; h = 600 }) $areaC
# a panel at the left and low down: pushed right onto the screen, and up
$plPush = Get-ChatConsolePlacement @(200, 300, 380, 200) $null $areaC
# a screen smaller than the console: no bigger than it
$plBig = Get-ChatConsolePlacement @(500, 50, 300, 100) $null ([pscustomobject]@{ X = -800; Y = 0; Width = 800; Height = 600 })
Check 'console placement: grown from the panel''s top-right corner, at the size it was left, kept on the panel''s screen' (
    $plNew.X -eq 500 -and $plNew.Y -eq 100 -and $plNew.W -eq 980 -and $plNew.H -eq 680 -and
    $plKept.X -eq 580 -and $plKept.Y -eq 100 -and $plKept.W -eq 900 -and $plKept.H -eq 600 -and
    $plPush.X -eq 0 -and $plPush.Y -eq 136 -and $plBig.X -eq -800 -and $plBig.Y -eq 0 -and $plBig.W -eq 800 -and $plBig.H -eq 600) "$($plNew.X),$($plNew.Y) $($plKept.X) $($plPush.X),$($plPush.Y) $($plBig.X),$($plBig.Y) $($plBig.W)x$($plBig.H)"
# 640 x 420 saved at 100%, opened at 150%: the window's least there is
# 960 x 630, and the right edge is placed for that, not for 640
$plMin = Get-ChatConsolePlacement @(1100, 500, 380, 200) ([pscustomobject]@{ w = 640; h = 420 }) $areaC 1470 1020 960 630
Check 'console placement: a size saved under the window''s least is raised to it before the right edge and the screen''s foot are held' (
    $plMin.W -eq 960 -and $plMin.H -eq 630 -and $plMin.X -eq 520 -and $plMin.Y -eq 186) "$($plMin.X),$($plMin.Y) $($plMin.W)x$($plMin.H)"
# 800 x 500 units opened at 150%: 1200 x 750 pixels there, and at 100%
# 800 x 500; a size an older file kept in pixels stays those pixels
$plU15 = Get-ChatConsolePlacement @(1400, 20, 100, 200) ([pscustomobject]@{ w = 800; h = 500; units = $true }) $areaC 1470 1020 960 630 1.5
$plU10 = Get-ChatConsolePlacement @(1400, 20, 100, 200) ([pscustomobject]@{ w = 800; h = 500; units = $true }) $areaC -Scale 1.0
$plPx = Get-ChatConsolePlacement @(1400, 20, 100, 200) ([pscustomobject]@{ w = 1000; h = 700; units = $false }) $areaC -Scale 1.5
Check 'console placement: a size kept in units is this screen''s pixels at its scale; an older one in pixels is taken as it is' (
    $plU15.W -eq 1200 -and $plU15.H -eq 750 -and $plU15.X -eq 300 -and $plU10.W -eq 800 -and $plU10.H -eq 500 -and
    $plPx.W -eq 1000 -and $plPx.H -eq 700) "$($plU15.X) $($plU15.W)x$($plU15.H) $($plU10.W)x$($plU10.H) $($plPx.W)x$($plPx.H)"
$in90 = [DateTimeOffset]::Now.AddMinutes(90.5).ToUnixTimeMilliseconds()
Check 'reset countdowns' ((Format-ChatOverlayReset $in90) -eq '1h 30m' -and (Format-ChatOverlayReset ($nowMs - 1000)) -eq 'reset' -and
    (Format-ChatOverlayReset ([DateTimeOffset]::Now.AddDays(3).ToUnixTimeMilliseconds())) -match '^[A-Z][a-z]{2} \d\d:\d\d$') (Format-ChatOverlayReset $in90)

# the endpoint refusing: Claude Code's own cached figure, marked, and a wait
$cu = New-ChatOverlayContext
$script:ChatOverlayUsageSeam = { $script:OvFetches++; @{ Ok = $false; Status = 401; Why = 'the usage endpoint answered 401'; Auth = $true } }
$uu = @(Update-ChatOverlayUsage $cu $true)
$uc = @($uu | Where-Object { $_.provider -eq 'Claude' })[0]
Check 'refused for the login: the cached figure, and no asking for 10 minutes' ($uc.source -eq 'cache' -and $uc.why -like '*401*' -and $cu.HoldUntil -gt (Get-Date).AddMinutes(9)) "$($uc.source) $($uc.why) $($cu.HoldUntil)"
$cu = New-ChatOverlayContext
$script:ChatOverlayUsageSeam = { @{ Ok = $false; Status = 429; Why = 'the usage endpoint answered 429' } }
$null = Update-ChatOverlayUsage $cu $true
Check 'a 429 with no Retry-After backs off 5 minutes' ($cu.HoldUntil -gt (Get-Date).AddMinutes(4.5) -and $cu.HoldUntil -lt (Get-Date).AddMinutes(5.5) -and $cu.LiveWhy -like 'rate-limited - asking again at *') "$($cu.HoldUntil) $($cu.LiveWhy)"
Request-ChatOverlayUsageRefresh $cu
$tooSoon = $cu.HoldUntil -gt (Get-Date)
$cu.LiveTriedAt = (Get-Date).AddSeconds(-30)
Request-ChatOverlayUsageRefresh $cu
Check 'the refresh button asks at once after a guessed wait, but not twice in 20 s' ($tooSoon -and $cu.HoldUntil -le (Get-Date) -and $null -eq $cu.LiveTriedAt)
# what a click did, said on the panel - an answer that moves no figure
# otherwise looks like a click that did nothing
$script:ChatOverlayUsageSeam = { @{ Ok = $true; Status = 200; Windows = @([pscustomobject]@{ Label = '5h'; Percent = 39; ResetsAt = $null; Severity = 'normal' }) } }
$cq = New-ChatOverlayContext
$cq.LiveTriedAt = (Get-Date).AddMinutes(-1)
$cq.HoldUntil = Get-Date
Request-ChatOverlayUsageRefresh $cq
$asking = Get-ChatOverlayRefreshNote $cq.Refresh $cq.Live (Get-Date)
$null = Update-ChatOverlayUsage $cq $false
$checked = Get-ChatOverlayRefreshNote $cq.Refresh $cq.Live (Get-Date)
$gone = Get-ChatOverlayRefreshNote $cq.Refresh $cq.Live (Get-Date).AddSeconds(11)
Request-ChatOverlayUsageRefresh $cq
$again = Get-ChatOverlayRefreshNote $cq.Refresh $cq.Live (Get-Date)
Check 'a refresh says it is asking, then when Claude answered, then goes; a second click says why it waits' (
    $asking -eq 'asking...' -and $checked -match '^checked \d\d:\d\d:\d\d$' -and $null -eq $gone -and $again -eq 'just asked') "$asking | $checked | $gone | $again"
$held = Get-ChatOverlayRefreshNote @{ Kind = 'held'; At = (Get-Date); Done = $null; Ok = $false } $null (Get-Date)
$null = Invoke-ChatOverlayCycle $cq
$cq.Refresh = @{ Kind = 'held'; At = (Get-Date); Done = $null; Ok = $false }
$snapR = Invoke-ChatOverlayCycle $cq -Peek
# the pass after a -Peek one saves what the -Peek one saw first
$null = Invoke-ChatOverlayCycle $cq
$savedR = Read-ChatqJson $script:ChatOverlayPath
$clOf = { param($s) @($s.header.usage | Where-Object { $_.provider -eq 'Claude' })[0].status }
Check 'inside a named wait it says it did not ask - at the end of Claude''s line, and in overlay.json on the next pass' (
    $held -like '*not asked*' -and (& $clOf $snapR) -eq 'not asked - wait' -and (& $clOf $savedR) -eq 'not asked - wait') "$held | $(& $clOf $snapR) | $(& $clOf $savedR)"
$cq.Config.usageView = 'bars'
$snapB = Invoke-ChatOverlayCycle $cq -Peek
$cq.Config.usageView = 'lines'
# the sandbox's own cut-offs may bring the reset ask's note: that is no usage note
$usageNotes = @($snapB.header.notes | Where-Object { -not ($_.PSObject.Properties['kind'] -and $_.kind -eq 'ask') })
Check 'as bars too: the same few words by the name, and no row of their own' ((& $clOf $snapB) -eq 'not asked - wait' -and -not $usageNotes.Count) "$(& $clOf $snapB) | $(@($usageNotes | ForEach-Object { $_.text }) -join ' / ')"
# each usage line's end, and when a time needs its date
$nowS = Get-Date '2026-09-23T22:30:00'
$msOf = { param($d) [DateTimeOffset]::new($d).ToUnixTimeMilliseconds() }
$march = Get-Date '2026-03-13T16:38:00'
$stLive = [pscustomobject]@{ provider = 'Claude'; source = 'live'; at = (& $msOf $nowS.AddMinutes(-3)); why = $null }
$stCache = [pscustomobject]@{ provider = 'Claude'; source = 'cache'; at = (& $msOf $march); why = $null }
$stCodex = [pscustomobject]@{ provider = 'Codex'; source = 'rollout'; at = (& $msOf $march); why = $null }
$stHeld = [pscustomobject]@{ provider = 'Claude'; source = 'live'; at = (& $msOf $nowS.AddMinutes(-20)); why = 'rate-limited until 22:40' }
Check 'a usage line ends in when its figure is from, or what is happening to it' (
    (Get-ChatOverlayUsageStatus $stLive $false $null $null $nowS) -eq '22:27' -and
    (Get-ChatOverlayUsageStatus $stLive $true $null $null $nowS) -eq 'asking...' -and
    (Get-ChatOverlayUsageStatus $stLive $false 'checked 22:29:59' $null $nowS) -eq 'checked 22:29:59' -and
    (Get-ChatOverlayUsageStatus $stCache $false $null $null $nowS) -eq 'cached Mar 13' -and
    (Get-ChatOverlayUsageStatus $stCodex $false $null $null $nowS) -eq 'last run Mar 13' -and
    (Get-ChatOverlayUsageStatus $stHeld $false $null $nowS.AddMinutes(10) $nowS) -eq '22:10, retry 22:40') (Get-ChatOverlayUsageStatus $stHeld $false $null $nowS.AddMinutes(10) $nowS)
Check 'a time six months back shows its date, not a weekday that reads as last week' (
    (Format-ChatOverlayWhen $march $nowS) -eq 'Mar 13' -and (Format-ChatOverlayWhen $nowS.AddDays(-3) $nowS) -eq 'Sun 22:30' -and (Format-ChatOverlayWhen $nowS.AddHours(-1) $nowS) -eq '21:30')
$codexOld = ConvertTo-ChatOverlayUsage 'Codex' 'rollout' ([pscustomobject]@{ Windows = @([pscustomobject]@{ Label = 'week'; Percent = 5; ResetsAt = $null; Severity = $null }); At = (Get-Date).AddDays(-2) }) (Get-Date) $null @{}
$codexSt = Get-ChatOverlayUsageStatus $codexOld $false $null $null (Get-Date)
Check 'Codex''s old figure says it is from Codex''s last run, not when anything refreshed' ($codexSt -like 'last run *') "$codexSt"
$inlN = @(Get-ChatOverlayNotes ([pscustomobject]@{ usage = @($codexOld); watcher = 'none'; next = '17:10'; error = $null }))
Check 'no usage figure takes a row of its own under the usage; the next queued prompt still does' ($inlN.Count -eq 1 -and $inlN[0].text -like 'next queued prompt*') (($inlN | ForEach-Object { $_.text }) -join ' | ')
# Copilot through gh: GitHub's answer on Copilot Free (ids left out), and on a paid plan
$freeJson = '{"copilot_plan":"individual","access_type_sku":"free_limited_copilot","quota_reset_date":"2026-10-01","quota_snapshots":{"chat":{"entitlement":200,"percent_remaining":100,"remaining":200,"unlimited":false,"has_quota":true},"completions":{"entitlement":2000,"percent_remaining":99.9,"remaining":1999,"unlimited":false,"has_quota":true},"premium_interactions":{"entitlement":0,"percent_remaining":0,"remaining":0,"unlimited":false,"has_quota":false}}}'
$proJson = '{"quota_reset_date":"2026-10-01","quota_snapshots":{"chat":{"entitlement":0,"percent_remaining":100,"unlimited":true},"completions":{"entitlement":0,"percent_remaining":100,"unlimited":true},"premium_interactions":{"entitlement":300,"percent_remaining":25,"unlimited":false}}}'
$cpFree = @(ConvertFrom-ChatqCopilotQuota ($freeJson | ConvertFrom-Json))
$cpPro = @(ConvertFrom-ChatqCopilotQuota ($proJson | ConvertFrom-Json))
Check 'Copilot: chat and code on the free plan, premium alone on a paid one, and the month''s reset' (
    ($cpFree.Label -join ',') -eq 'chat,code' -and $cpFree[0].Percent -eq 0 -and [Math]::Abs($cpFree[1].Percent - 0.1) -lt 0.01 -and
    ($cpPro.Label -join ',') -eq 'premium' -and $cpPro[0].Percent -eq 75 -and $cpFree[0].ResetsAt.ToUniversalTime().Date -eq [datetime]'2026-10-01') "$($cpFree.Label -join ',') / $($cpPro.Label -join ',') $($cpPro[0].Percent)"
$script:ChatOverlayCopilotSeam = { @{ Ok = $true; Windows = @(ConvertFrom-ChatqCopilotQuota ($freeJson | ConvertFrom-Json)) } }
$cc = New-ChatOverlayContext
$cc.Config.liveUsage = $false
$ccCop = @(@(Update-ChatOverlayUsage $cc $false) | Where-Object { $_.provider -eq 'Copilot' })[0]
$script:ChatOverlayCopilotSeam = { @{ Ok = $false; Status = 4; Why = 'gh: To get started with GitHub CLI, please run:  gh auth login'; Quiet = $true } }
$cc.CopilotTriedAt = $null
$ccOut = @(@(Update-ChatOverlayUsage $cc $false) | Where-Object { $_.provider -eq 'Copilot' })
$script:ChatOverlayCopilotSeam = $null
# CHATQ_GH points at nothing: the real path, with no gh to run
$cc2 = New-ChatOverlayContext
$cc2.Config.liveUsage = $false
$ccNone = @(@(Update-ChatOverlayUsage $cc2 $false) | Where-Object { $_.provider -eq 'Copilot' })
$olPath = Join-Path $script:ChatqLogDir 'overlay.log'
$quietLog = -not (Test-Path -LiteralPath $olPath) -or -not (Select-String -LiteralPath $olPath -SimpleMatch 'copilot usage' -Quiet)
Check 'a Copilot line from gh''s answer; none when gh is not logged in or not there - and nothing logged' (
    $ccCop -and ($ccCop.windows.label -join ',') -eq 'chat,code' -and -not $ccOut.Count -and -not $ccNone.Count -and $cc2.CopilotWhy -eq 'no GitHub CLI' -and $quietLog) "$($ccCop.windows.label -join ',') $($ccOut.Count) $($ccNone.Count) $($cc2.CopilotWhy)"
# Codex asked live (Start-ChatqCodexUsageFetch), through the seam: the
# account's answer against the rollout's snapshot, the newer shown. Each
# context gets a rollout figure of its own and no files, so nothing on
# disk moves it and no rollout reads as busy.
$cxSeamWas = $script:ChatOverlayCodexUsageSeam
$script:CxAsked = [System.Collections.Generic.List[string]]::new()
$cxMonth = @([pscustomobject]@{ Label = 'month'; Type = 'monthly'; Minutes = 43200; Percent = 7; ResetsAt = (Get-Date).AddDays(20); Severity = '' })
$cxOkSeam = { param($h) $script:CxAsked.Add([string]$h); @{ Ok = $true; Windows = $cxMonth; PlanType = 'free'; Reached = $null } }
$newCx = {
    $c = New-ChatOverlayContext
    $c.Config.liveUsage = $false
    $c.Config.copilotUsage = $false
    $c.CodexListAt = Get-Date
    $c.CodexAt = Get-Date
    $c.CodexFiles = @()
    $c.Codex = [pscustomobject]@{ Windows = @([pscustomobject]@{ Label = 'week'; Percent = 55; ResetsAt = $null; Severity = '' }); At = (Get-Date).AddHours(-5) }
    $c
}
$cxOf = { param($c, [bool]$busy) @(@(Update-ChatOverlayUsage $c $false -CodexBusy $busy) | Where-Object { $_.provider -eq 'Codex' })[0] }
try {
    $script:ChatOverlayCodexUsageSeam = $cxOkSeam
    $cl = & $newCx
    $clU = & $cxOf $cl $false
    $clSt = Get-ChatOverlayUsageStatus $clU $false $null $null (Get-Date)
    Check 'codex usage live: the account''s answer over an older rollout - its month, its plan, and the time it was asked, not "last run"' (
        $clU.source -eq 'live' -and (@($clU.windows | ForEach-Object label) -join ',') -eq 'month' -and @($clU.windows)[0].percent -eq 7 -and $clU.plan -eq 'free' -and
        $clSt -match '^\d\d:\d\d$' -and $script:CxAsked.Count -eq 1 -and $script:CxAsked[0] -eq $cl.CodexHome) "$($clU.source) $($clU.plan) $clSt / $($script:CxAsked -join ',')"
    # a turn since: the rollout is newer, and shown; not asked again so soon
    $cl.CodexLive.At = (Get-Date).AddHours(-6)
    $clR = & $cxOf $cl $false
    Check 'codex usage live: a rollout newer than the last answer wins, and an idle Codex is not asked again within 3 x usageSeconds' (
        $clR.source -eq 'rollout' -and @($clR.windows)[0].label -eq 'week' -and $script:CxAsked.Count -eq 1) "$($clR.source) $($script:CxAsked.Count)"
    # every usageSeconds while a Codex job works, three times that while idle
    $cl.CodexTriedAt = (Get-Date).AddSeconds( - ($cl.Config.usageSeconds + 5))
    $null = & $cxOf $cl $false
    $idleAsked = $script:CxAsked.Count
    $null = & $cxOf $cl $true
    Check 'codex usage live: asked every usageSeconds while a Codex job works, not while idle' ($idleAsked -eq 1 -and $script:CxAsked.Count -eq 2) "$idleAsked $($script:CxAsked.Count)"
    # and again once a window's reset passes
    $cl.CodexTriedAt = Get-Date
    $cl.CodexLive = [pscustomobject]@{ Windows = @([pscustomobject]@{ Label = '5h'; Percent = 100; ResetsAt = (Get-Date).AddSeconds(-10); Severity = '' }); At = (Get-Date).AddMinutes(-3); Plan = 'plus' }
    $null = & $cxOf $cl $false
    Check 'codex usage live: asked again once a window''s reset passes' ($script:CxAsked.Count -eq 3) "$($script:CxAsked.Count)"

    # no codex, no home, too old: no news - the rollout kept, nothing
    # logged, nothing said, and not asked again for half an hour
    $script:ChatOverlayCodexUsageSeam = { param($h) $script:CxAsked.Add([string]$h); @{ Ok = $false; Why = 'codex app-server: no codex CLI'; Quiet = $true } }
    $cq2 = & $newCx
    $cq2U = & $cxOf $cq2 $false
    $cxLog = Join-Path $script:ChatqLogDir 'overlay.log'
    $cxQuiet = -not (Test-Path -LiteralPath $cxLog) -or -not (Select-String -LiteralPath $cxLog -SimpleMatch 'codex usage' -Quiet)
    $cqHold = ($cq2.CodexHoldUntil - (Get-Date)).TotalMinutes
    Check 'codex usage live: a quiet failure keeps the rollout''s figure, logs and says nothing, and waits 30 minutes' (
        $cq2U.source -eq 'rollout' -and -not $cq2.CodexWhy -and $cxQuiet -and $cqHold -gt 29 -and $cqHold -le 30) "$($cq2U.source) $($cq2.CodexWhy) $cqHold"

    # any other failure: logged, said with the last answer, 2 then 4 minutes
    $script:ChatOverlayCodexUsageSeam = $cxOkSeam
    $cf2 = & $newCx
    $null = & $cxOf $cf2 $false
    $script:ChatOverlayCodexUsageSeam = { param($h) $script:CxAsked.Add([string]$h); @{ Ok = $false; Why = 'codex app-server: timed out'; Quiet = $false } }
    $cf2.CodexTriedAt = $null
    $cf2U = & $cxOf $cf2 $false
    $cfH1 = ($cf2.CodexHoldUntil - (Get-Date)).TotalMinutes
    $cfSt = Get-ChatOverlayUsageStatus $cf2U $false $null $cf2.CodexHoldUntil (Get-Date)
    $cf2.CodexHoldUntil = (Get-Date).AddSeconds(-1)
    $cf2.CodexTriedAt = $null
    $null = & $cxOf $cf2 $false
    $cfH2 = ($cf2.CodexHoldUntil - (Get-Date)).TotalMinutes
    $cxLogged = (Test-Path -LiteralPath $cxLog) -and (Select-String -LiteralPath $cxLog -SimpleMatch 'codex usage: codex app-server: timed out' -Quiet)
    Check 'codex usage live: a failure is logged, said after the last answer with its retry, and waits 2 then 4 minutes' (
        $cf2U.source -eq 'live' -and $cf2.CodexWhy -like '*timed out' -and $cfSt -match '^\d\d:\d\d, retry \d\d:\d\d$' -and $cxLogged -and
        $cfH1 -gt 1.9 -and $cfH1 -le 2 -and $cfH2 -gt 3.9 -and $cfH2 -le 4 -and $cf2.CodexFails -eq 2) "$($cf2U.source) $cfSt $cfH1 $cfH2 $($cf2.CodexFails)"
    # the refresh button lifts that wait: a click is how to say codex is there now
    $cf2.CodexTriedAt = (Get-Date).AddMinutes(-1)
    Request-ChatOverlayUsageRefresh $cf2
    Check 'codex usage live: the refresh button clears the wait and asks on the next pass' (
        $cf2.CodexHoldUntil -eq [datetime]::MinValue -and $null -eq $cf2.CodexTriedAt) "$($cf2.CodexHoldUntil) $($cf2.CodexTriedAt)"

    # -CodexUsage off: never asked, and a live figure from before not shown
    $script:ChatOverlayCodexUsageSeam = $cxOkSeam
    $cOffX = & $newCx
    $cOffX.Config.codexUsage = $false
    $cOffX.CodexLive = [pscustomobject]@{ Windows = $cxMonth; At = (Get-Date); Plan = 'free' }
    $askedBefore = $script:CxAsked.Count
    $cOffU = & $cxOf $cOffX $true
    Check 'codex usage live off: never asked, the rollout alone' ($script:CxAsked.Count -eq $askedBefore -and $cOffU.source -eq 'rollout') "$($script:CxAsked.Count) $($cOffU.source)"

    # a restart keeps the last answer, and does not ask again at once
    $cxKeep = & $newCx
    $cxKeepU = @(Update-ChatOverlayUsage $cxKeep $false)
    [System.IO.File]::WriteAllText($script:ChatOverlayPath, ([pscustomobject]@{ header = [pscustomobject]@{ usage = $cxKeepU } } | ConvertTo-Json -Depth 6 -Compress), $utf8)
    $cxR = New-ChatOverlayContext
    $cxR.Config.liveUsage = $false
    Restore-ChatOverlayUsage $cxR
    # one started under another CODEX_HOME: that account's figure is not its own
    $cxROther = New-ChatOverlayContext -CodexHome (Join-Path $sb 'codex-restore-other')
    $cxROther.Config.liveUsage = $false
    Restore-ChatOverlayUsage $cxROther
    Remove-Item -LiteralPath $script:ChatOverlayPath -Force -EA SilentlyContinue
    $cxKeepLive = @($cxKeepU | Where-Object { $_.provider -eq 'Codex' })[0]
    Check 'codex usage live: a restart keeps the last answer and its plan, and counts it as asked' (
        $cxR.CodexLive -and @($cxR.CodexLive.Windows)[0].Label -eq 'month' -and @($cxR.CodexLive.Windows)[0].Percent -eq 7 -and $cxR.CodexLive.Plan -eq 'free' -and
        $cxR.CodexTriedAt -and [Math]::Abs(($cxR.CodexTriedAt - $cxKeep.CodexLive.At).TotalSeconds) -lt 1) "$($cxR.CodexLive | ConvertTo-Json -Depth 4 -Compress)"
    Check 'codex usage live: the answer names the home it was asked under, and a restart under another home leaves it' (
        $cxKeepLive.source -eq 'live' -and $cxKeepLive.home -eq $cxKeep.CodexHome -and $null -eq $cxROther.CodexLive -and $null -eq $cxROther.CodexTriedAt) (
        "$($cxKeepLive.home) / $($cxROther.CodexLive | ConvertTo-Json -Depth 4 -Compress)")
}
finally { $script:ChatOverlayCodexUsageSeam = $cxSeamWas }
# the real answer carried Retry-After: 2867, read as $null through .Delta.Value
Add-Type -AssemblyName System.Net.Http
# 429 has no name in .NET Framework's HttpStatusCode, and PowerShell will not cast to it
$s429 = [Enum]::ToObject([System.Net.HttpStatusCode], 429)
$resp = [System.Net.Http.HttpResponseMessage]::new($s429)
$resp.Headers.RetryAfter = [System.Net.Http.Headers.RetryConditionHeaderValue]::new([TimeSpan]::FromSeconds(2867))
$resp2 = [System.Net.Http.HttpResponseMessage]::new($s429)
$resp2.Headers.RetryAfter = [System.Net.Http.Headers.RetryConditionHeaderValue]::new([DateTimeOffset]::UtcNow.AddSeconds(600))
$raD = Get-ChatqRetryAfter $resp
$raT = Get-ChatqRetryAfter $resp2
Check 'Retry-After read, as seconds or as a date' ($raD -eq 2867 -and $raT -gt 590 -and $raT -le 600 -and $null -eq (Get-ChatqRetryAfter ([System.Net.Http.HttpResponseMessage]::new($s429)))) "$raD $raT"
$cu = New-ChatOverlayContext
$script:ChatOverlayUsageSeam = { @{ Ok = $false; Status = 429; Why = 'the usage endpoint answered 429'; RetryAfter = 2867 } }
$null = Update-ChatOverlayUsage $cu $true
$heldTo = $cu.HoldUntil
Request-ChatOverlayUsageRefresh $cu
Check 'a named wait is kept, refresh button or not, and shown with its end' ($heldTo -gt (Get-Date).AddMinutes(47) -and $cu.HoldUntil -eq $heldTo -and $cu.HoldKind -eq 'server' -and $cu.LiveWhy -like 'rate-limited until *') "$heldTo $($cu.LiveWhy)"
# shown on the panel with the last live figure up, not only over the cached one
$liveU = ConvertTo-ChatOverlayUsage 'Claude' 'live' ([pscustomobject]@{ Windows = @([pscustomobject]@{ Label = '5h'; Percent = 60; ResetsAt = $null; Severity = 'normal' }); At = (Get-Date).AddMinutes(-2) }) (Get-Date) $cu.LiveWhy @{}
$liveSt = Get-ChatOverlayUsageStatus $liveU $false $null $cu.HoldUntil (Get-Date)
Check 'the panel says so over the last live figure too: its time, and when it asks again' ($liveSt -match '^\d\d:\d\d, retry \d\d:\d\d$') "$liveSt"
$liveOld = [pscustomobject]@{ Windows = @([pscustomobject]@{ Label = '5h'; Percent = 60; ResetsAt = $null; Severity = 'normal' }); At = (Get-Date).AddMinutes(-16) }
Check 'a live figure 16 minutes old is not stale while idle asks are 15 apart' (-not (ConvertTo-ChatOverlayUsage 'Claude' 'live' $liveOld (Get-Date) $null @{} 20).stale -and (ConvertTo-ChatOverlayUsage 'Claude' 'cache' $liveOld (Get-Date) $null @{}).stale)
$cOff = New-ChatOverlayContext
$cOff.Config.liveUsage = $false
$cOff.Live = [pscustomobject]@{ Windows = @([pscustomobject]@{ Label = '5h'; Percent = 99; ResetsAt = $null; Severity = 'normal' }); At = (Get-Date) }
$offU = @(@(Update-ChatOverlayUsage $cOff $true) | Where-Object { $_.provider -eq 'Claude' })[0]
Check 'live usage off: the cache only, never a live figure from before' (-not $offU -or $offU.source -eq 'cache') "$($offU.source)"
# a restart keeps the last live figure and the named wait
$cu.Live = [pscustomobject]@{ Windows = @([pscustomobject]@{ Label = '5h'; Percent = 81; ResetsAt = (Get-Date).AddMinutes(70); Severity = 'warning' }); At = (Get-Date).AddMinutes(-3) }
$cu.Cache = $null
$script:ChatOverlayUsageSeam = $null
$cuSnap = [pscustomobject]@{ header = [pscustomobject]@{ usage = @(Update-ChatOverlayUsage $cu $true); usageWhy = $cu.LiveWhy; liveHold = (ConvertTo-ChatOverlayMs $cu.HoldUntil) } }
[System.IO.File]::WriteAllText($script:ChatOverlayPath, ($cuSnap | ConvertTo-Json -Depth 6 -Compress), $utf8)
$cr = New-ChatOverlayContext
Restore-ChatOverlayUsage $cr
$crU = @(@(Update-ChatOverlayUsage $cr $true) | Where-Object { $_.provider -eq 'Claude' })[0]
Check 'a restart keeps the last live figure and the wait the endpoint named' ($crU.source -eq 'live' -and @($crU.windows)[0].percent -eq 81 -and $cr.HoldKind -eq 'server' -and
    [Math]::Abs(($cr.HoldUntil - $heldTo).TotalSeconds) -lt 2 -and -not $cr.Fetch) "$($crU.source) $(@($crU.windows)[0].percent) $($cr.HoldUntil)"
Remove-Item -LiteralPath $script:ChatOverlayPath -Force -EA SilentlyContinue
# the token: read, never written anywhere - not even into the log of a failure
$cred = Join-Path $claudeHome '.credentials.json'
$tokSecret = 'sk-ant-oat01-must-never-be-logged'
[System.IO.File]::WriteAllText($cred, ('{"claudeAiOauth":{"accessToken":"' + $tokSecret + '","expiresAt":' + $nowMs + '}}'), $utf8)
$tk = Get-ChatqClaudeToken $claudeHome
Check 'an expired login is not used' (-not $tk.Token -and $tk.Auth)
[System.IO.File]::WriteAllText($cred, ('{"claudeAiOauth":{"accessToken":"' + $tokSecret + '","expiresAt":' + ($nowMs + 3600000) + '}}'), $utf8)
$script:ChatOverlayUsageSeam = $null
$urlWas = $script:ChatOverlayUsageUrl
$script:ChatOverlayUsageUrl = 'http://127.0.0.1:9/api/oauth/usage'
$cu = New-ChatOverlayContext
$null = Update-ChatOverlayUsage $cu $true -WaitMs 15000
$script:ChatOverlayUsageUrl = $urlWas
$olog = [System.IO.File]::ReadAllText((Join-Path $script:ChatqLogDir 'overlay.log'), $utf8)
Check 'a failed ask is logged, the token never' ($cu.LiveWhy -and $olog -like '*usage:*' -and $olog -notlike "*$tokSecret*" -and -not (Select-String -LiteralPath (Get-ChildItem -LiteralPath $script:ChatqData -Recurse -File).FullName -SimpleMatch $tokSecret -List)) $cu.LiveWhy
Remove-Item -LiteralPath $cred -Force

# the Recent list: the newest chats not open, from a Claude home of its own -
# a side transcript, an empty one, one with no folder and one whose folder is
# gone among them, and files that are not chats. The slice set wide, so a
# slow machine never cuts a build short but where that is the point.
$sliceWas = $script:ChatOverlaySliceMs
$script:ChatOverlaySliceMs = 60000
$rcHome = Join-Path $sb 'recent-home'
# $sb, not $work: $work names a test screen by now
$rcProj = Join-Path $sb 'projR'
$null = New-Item -ItemType Directory -Path $rcProj -Force
$rcDir = Join-Path (Join-Path $rcHome 'projects') (Get-Slug $rcProj)
$null = New-Item -ItemType Directory -Path $rcDir -Force
$rcCwd = ',"cwd":' + (ConvertTo-Json $rcProj)
function RcUser([string]$Text, [string]$Extra = '', [string]$Cwd = $rcCwd) { '{"type":"user"' + $Extra + $Cwd + ',"message":{"role":"user","content":"' + $Text + '"}}' }
function New-RecentChat([string]$Id, [string[]]$Lines, [double]$MinutesAgo, [string]$Dir = $rcDir) {
    $null = New-Item -ItemType Directory -Path $Dir -Force
    $p = Join-Path $Dir "$Id.jsonl"
    [System.IO.File]::WriteAllText($p, ($Lines -join "`n") + "`n", $utf8)
    [System.IO.File]::SetLastWriteTime($p, (Get-Date).AddMinutes(-$MinutesAgo))
    return $p
}
$idR1 = '0b0b0b0b-0b0b-40b0-80b0-0b0b0b0b0b01'
$idR2 = '0b0b0b0b-0b0b-40b0-80b0-0b0b0b0b0b02'
$idR3 = '0b0b0b0b-0b0b-40b0-80b0-0b0b0b0b0b03'
$idR4 = '0b0b0b0b-0b0b-40b0-80b0-0b0b0b0b0b04'
$idRLive = '0b0b0b0b-0b0b-40b0-80b0-0b0b0b0b0b05'
$idRSide = '0b0b0b0b-0b0b-40b0-80b0-0b0b0b0b0b06'
$idREmpty = '0b0b0b0b-0b0b-40b0-80b0-0b0b0b0b0b07'
$idRNoCwd = '0b0b0b0b-0b0b-40b0-80b0-0b0b0b0b0b08'
$idRGone = '0b0b0b0b-0b0b-40b0-80b0-0b0b0b0b0b09'
$null = New-RecentChat $idRLive @((RcUser 'open right now'), (OvReply)) 0.5
$pR1 = New-RecentChat $idR1 @((RcUser 'ask one'), (OvReply), (OvLast 'ask one'), (OvTitle 'Newest recent'), (OvTail)) 1
$null = New-RecentChat $idRSide @((RcUser 'a subagent''s ask' ',"isSidechain":true'), (OvReply)) 2
$null = New-RecentChat $idREmpty @((OvTitle 'A ghost'), ('{"type":"mode","mode":"default"' + $rcCwd + '}')) 3
$null = New-RecentChat $idRNoCwd @((OvUser 'no folder named'), (OvReply)) 4
$null = New-RecentChat $idR2 @((RcUser 'rename ask'), (OvReply), (OvTitle 'Auto title'),
    ([ordered]@{ type = 'custom-title'; customTitle = 'Renamed recent'; sessionId = $idR2 } | ConvertTo-Json -Compress)) 5
$null = New-RecentChat $idRGone @((RcUser 'its folder went' '' (',"cwd":' + (ConvertTo-Json (Join-Path $sb 'no-such-folder')))), (OvReply)) 6
$pR3 = New-RecentChat $idR3 @((RcUser '<command-name>/clear</command-name>'), (RcUser 'the first real ask'), (OvReply)) 10
$null = New-RecentChat $idR4 @((RcUser 'oldest ask'), (OvReply), (OvTitle 'Oldest recent')) 20
# not chats: a name that is no session id, and one a folder down
[System.IO.File]::WriteAllText((Join-Path $rcDir 'notes.jsonl'), ((RcUser 'notes') + "`n"), $utf8)
$null = New-RecentChat '0b0b0b0b-0b0b-40b0-80b0-0b0b0b0b0b10' @((RcUser 'a subagent file'), (OvReply)) 0 (Join-Path $rcDir "$idR1\subagents")
$rc = New-ChatOverlayContext $rcHome
$script:ChatOverlayRecentReads = 0
Update-ChatOverlayRecent $rc @($idRLive)
$rcL = @($rc.Recent)
$rcOf = { param($l, $id) @($l | Where-Object { $_.sessionId -eq $id })[0] }
Check 'recent: newest first, the open one, a side transcript, an empty one and ones with no folder left out' (
    (@($rcL | ForEach-Object { $_.sessionId }) -join ',') -eq "$idR1,$idR2,$idR3,$idR4") (@($rcL | ForEach-Object { $_.sessionId }) -join ',')
$r1r = & $rcOf $rcL $idR1
Check 'recent: titled as an open row is - a rename, Claude''s own title, else the first real prompt - and its folder from the head' (
    $r1r.title -eq 'Newest recent' -and (& $rcOf $rcL $idR2).title -eq 'Renamed recent' -and (& $rcOf $rcL $idR3).title -eq 'the first real ask' -and
    $r1r.cwd -eq $rcProj -and $r1r.project -eq 'projR' -and $r1r.key -eq "recent:$idR1" -and $r1r.kind -eq 'recent' -and $r1r.provider -eq 'claude' -and
    $r1r.status -eq 'recent' -and [Math]::Abs([int64]$r1r.since - [DateTimeOffset]::new((Get-Item -LiteralPath $pR1).LastWriteTime).ToUnixTimeMilliseconds()) -lt 1000) (
    ($rcL | ForEach-Object { "$($_.title) @ $($_.cwd)" }) -join ' | ')
$reads1 = $script:ChatOverlayRecentReads
$rcAt1 = $rc.RecentAt
Update-ChatOverlayRecent $rc @($idRLive)
$sameMinute = $rc.RecentAt -eq $rcAt1 -and $script:ChatOverlayRecentReads -eq $reads1
# a minute on: built, and listed, again
$rc.RecentAt = [datetime]::MinValue
$rc.RecentListAt = [datetime]::MinValue
Update-ChatOverlayRecent $rc @($idRLive)
$reads2 = $script:ChatOverlayRecentReads - $reads1
[System.IO.File]::AppendAllText($pR3, ((OvTitle 'Now titled') + "`n"), $utf8)
[System.IO.File]::SetLastWriteTime($pR3, (Get-Date).AddMinutes(-10))
$rc.RecentAt = [datetime]::MinValue
$rc.RecentListAt = [datetime]::MinValue
Update-ChatOverlayRecent $rc @($idRLive)
$reads3 = $script:ChatOverlayRecentReads - $reads1 - $reads2
Check 'recent: not built again within the minute; after it, only a transcript that moved is read again' (
    $sameMinute -and $reads2 -eq 0 -and $reads3 -eq 1 -and (& $rcOf @($rc.Recent) $idR3).title -eq 'Now titled' -and @($rc.Recent).Count -eq 4) "$sameMinute $reads1 $reads2 $reads3"
# a build that goes on before the minute is out - one a slice cut short -
# works from the listing it has; a changed set of open chats lists again
$lists0 = $script:ChatOverlayRecentLists
$rc.RecentAt = [datetime]::MinValue
Update-ChatOverlayRecent $rc @($idRLive)
$listKept = $script:ChatOverlayRecentLists -eq $lists0
$rc.RecentAt = [datetime]::MinValue
$rc.RecentListAt = (Get-Date).AddSeconds(-61)
Update-ChatOverlayRecent $rc @($idRLive)
$listAged = $script:ChatOverlayRecentLists -eq $lists0 + 1
Update-ChatOverlayRecent $rc @($idRLive, $idR4)
$listLive = $script:ChatOverlayRecentLists -eq $lists0 + 2
Check 'recent: the listing kept between builds - taken again a minute on, or when the open chats change' ($listKept -and $listAged -and $listLive) "$listKept $listAged $listLive"
Update-ChatOverlayRecent $rc @()
Check 'recent: a chat that closes is in it at once, not a minute on' (@($rc.Recent)[0].sessionId -eq $idRLive -and @($rc.Recent).Count -eq 5) (@($rc.Recent | ForEach-Object { $_.sessionId }) -join ',')
$rcCap = New-ChatOverlayContext $rcHome
$rcCap.Config.recent = 2
Update-ChatOverlayRecent $rcCap @($idRLive)
$rcOff = New-ChatOverlayContext $rcHome
$rcOff.Config.recent = 0
$readsOff = $script:ChatOverlayRecentReads
Update-ChatOverlayRecent $rcOff @()
Check 'recent: as many as overlay.recent says; 0 is off, nothing read' (
    (@($rcCap.Recent | ForEach-Object { $_.sessionId }) -join ',') -eq "$idR1,$idR2" -and -not @($rcOff.Recent).Count -and $script:ChatOverlayRecentReads -eq $readsOff) (@($rcCap.Recent | ForEach-Object { $_.sessionId }) -join ',')
# the Windows panel's pool (RecentPool): the most overlay.recent takes built
# whatever it says, 0 too - the first overlay.recent Recent, the rest
# RecentMore - and split again at a count changed, nothing read for it.
# Without the pool there is no more.
$rcIds = { param($l) @($l | ForEach-Object { $_.sessionId }) -join ',' }
$rcPool = New-ChatOverlayContext $rcHome
$rcPool.RecentPool = $true
$rcPool.Config.recent = 2
Update-ChatOverlayRecent $rcPool @($idRLive)
$poolA = (& $rcIds $rcPool.Recent) -eq "$idR1,$idR2" -and (& $rcIds $rcPool.RecentMore) -eq "$idR3,$idR4"
$readsPool = $script:ChatOverlayRecentReads
$listsPool = $script:ChatOverlayRecentLists
$rcPool.Config.recent = 3
Update-ChatOverlayRecent $rcPool @($idRLive)
$poolB = (& $rcIds $rcPool.Recent) -eq "$idR1,$idR2,$idR3" -and (& $rcIds $rcPool.RecentMore) -eq $idR4
$rcPool.Config.recent = 0
Update-ChatOverlayRecent $rcPool @($idRLive)
$poolC = -not @($rcPool.Recent).Count -and (& $rcIds $rcPool.RecentMore) -eq "$idR1,$idR2,$idR3,$idR4" -and
    $script:ChatOverlayRecentReads -eq $readsPool -and $script:ChatOverlayRecentLists -eq $listsPool
$rcPool0 = New-ChatOverlayContext $rcHome
$rcPool0.RecentPool = $true
$rcPool0.Config.recent = 0
Update-ChatOverlayRecent $rcPool0 @($idRLive)
$poolD = -not @($rcPool0.Recent).Count -and (& $rcIds $rcPool0.RecentMore) -eq "$idR1,$idR2,$idR3,$idR4" -and $rcPool0.RecentSig -like '20|*'
Check 'recent: with the pool, 20 built - overlay.recent of them Recent, the rest RecentMore - split again as the count changes with nothing read; 0 too' (
    $poolA -and $poolB -and $poolC -and $poolD) "$poolA $poolB $poolC $poolD / $(& $rcIds $rcPool.Recent) | $(& $rcIds $rcPool.RecentMore) / $($rcPool0.RecentSig)"
Check 'recent: without the pool, no more past overlay.recent' (-not @($rcCap.RecentMore).Count -and -not @($rcOff.RecentMore).Count -and @($rcCap.Recent).Count -eq 2) ''
# a slice spent before any transcript is read - by the listing, say: each
# build still reads one, and the next pass goes on at once from the same
# listing, until the list is whole
$script:ChatOverlaySliceMs = -1
$rcCut = New-ChatOverlayContext $rcHome
$readsCut = $script:ChatOverlayRecentReads
$listsCut = $script:ChatOverlayRecentLists
Update-ChatOverlayRecent $rcCut @($idRLive)
$cutShort = (@($rcCut.Recent | ForEach-Object { $_.sessionId }) -join ',') -eq $idR1 -and $rcCut.RecentAt -eq [datetime]::MinValue -and
    $script:ChatOverlayRecentReads - $readsCut -eq 1
$cutPasses = 1
while ($rcCut.RecentAt -eq [datetime]::MinValue -and $cutPasses -lt 20) { Update-ChatOverlayRecent $rcCut @($idRLive); $cutPasses++ }
$script:ChatOverlaySliceMs = 60000
$cutOn = (@($rcCut.Recent | ForEach-Object { $_.sessionId }) -join ',') -eq "$idR1,$idR2,$idR3,$idR4" -and $script:ChatOverlayRecentLists - $listsCut -eq 1 -and
    $cutPasses -eq $script:ChatOverlayRecentReads - $readsCut
Check 'recent: a build past its slice stops with one transcript read, and each pass goes on from the same listing' ($cutShort -and $cutOn) (
    "$cutShort $cutOn passes $cutPasses reads $($script:ChatOverlayRecentReads - $readsCut) lists $($script:ChatOverlayRecentLists - $listsCut) / " + (@($rcCut.Recent | ForEach-Object { $_.sessionId }) -join ','))
# a chat's folder deleted after it was read: out at the first build once
# what was known of it is old, and back once the folder is made again -
# neither reading the transcript again. Within that time a folder is asked
# no more: every build had asked every one, on the panel's thread.
$rcLater = Join-Path $sb 'projLater'
$null = New-Item -ItemType Directory -Path $rcLater -Force
$idRL = '0b0b0b0b-0b0b-40b0-80b0-0b0b0b0b0b12'
$pRL = New-RecentChat $idRL @((RcUser 'its folder goes later' '' (',"cwd":' + (ConvertTo-Json $rcLater))), (OvReply)) 0.8
$script:FolderAsks = [System.Collections.Generic.List[string]]::new()
$script:ChatOverlayFolderSeam = { param($p) $script:FolderAsks.Add($p); Test-Path -LiteralPath $p -PathType Container }
$fT0 = Get-Date
$ttl = $script:ChatOverlayFolderTtlSeconds
$rcF = New-ChatOverlayContext $rcHome
Update-ChatOverlayRecent $rcF @($idRLive) $fT0
$fIn = @($rcF.Recent)[0].sessionId -eq $idRL
$asks0 = $script:FolderAsks.Count
$readsF = $script:ChatOverlayRecentReads
Remove-Item -LiteralPath $rcLater -Recurse -Force
$rcF.RecentAt = [datetime]::MinValue
Update-ChatOverlayRecent $rcF @($idRLive) $fT0.AddSeconds(30)
$fHeld = @($rcF.Recent)[0].sessionId -eq $idRL -and $script:FolderAsks.Count -eq $asks0
$rcF.RecentAt = [datetime]::MinValue
Update-ChatOverlayRecent $rcF @($idRLive) $fT0.AddSeconds($ttl + 1)
$fOut = -not @($rcF.Recent | Where-Object { $_.sessionId -eq $idRL }).Count -and @($rcF.Recent).Count -eq 4 -and $script:FolderAsks.Count -gt $asks0
$null = New-Item -ItemType Directory -Path $rcLater -Force
$rcF.RecentAt = [datetime]::MinValue
Update-ChatOverlayRecent $rcF @($idRLive) $fT0.AddSeconds(2 * $ttl + 2)
$fBack = @($rcF.Recent)[0].sessionId -eq $idRL -and $script:ChatOverlayRecentReads -eq $readsF
Check 'recent: a folder asked once in a few minutes; one deleted since goes once that is up, and comes back with the folder' ($fIn -and $fHeld -and $fOut -and $fBack) "$fIn $fHeld $fOut $fBack asks $asks0/$($script:FolderAsks.Count)"
Remove-Item -LiteralPath $pRL, $rcLater -Recurse -Force
# a folder on another machine - a UNC path, a mapped network drive - is
# never asked on the panel's thread: taken as there, Show-ChatFresh says if
# it is not. Nor is a folder asked past the slice, where a read would stop.
$idRU = '0b0b0b0b-0b0b-40b0-80b0-0b0b0b0b0b13'
$idRQ = '0b0b0b0b-0b0b-40b0-80b0-0b0b0b0b0b14'
$pRU = New-RecentChat $idRU @((RcUser 'on a share' '' (',"cwd":' + (ConvertTo-Json '\\nas\share\projU'))), (OvReply)) 0.7
$pRQ = New-RecentChat $idRQ @((RcUser 'on a mapped drive' '' (',"cwd":' + (ConvertTo-Json 'Q:\projQ'))), (OvReply)) 0.75
$script:ChatOverlayNetDriveSeam = { param($l) $l -eq 'Q' }
$script:FolderAsks.Clear()
$rcU = New-ChatOverlayContext $rcHome
Update-ChatOverlayRecent $rcU @($idRLive)
$uIds = @($rcU.Recent | ForEach-Object { $_.sessionId })
$netOk = $uIds[0] -eq $idRU -and $uIds[1] -eq $idRQ -and -not @($script:FolderAsks | Where-Object { $_ -like '\\*' -or $_ -like 'Q:*' }).Count -and
    (Test-ChatOverlayNetworkPath '//nas/share') -and -not (Test-ChatOverlayNetworkPath 'C:\x') -and -not (Test-ChatOverlayNetworkPath '/Users/x')
# the slice spent: each build asks one folder or reads one transcript, and
# the next goes on - the folders' asks counted as reads are
$script:ChatOverlaySliceMs = -1
$rcS = New-ChatOverlayContext $rcHome
foreach ($f in @($rcU.RecentCache.Keys)) { $rcS.RecentCache[$f] = $rcU.RecentCache[$f] }
Update-ChatOverlayRecent $rcS @($idRLive)
$sliceAsk = $rcS.Folders -and $rcS.Folders.Count -eq 1 -and @($rcS.Recent).Count -eq 1 -and $rcS.RecentAt -eq [datetime]::MinValue
$sPasses = 1
while ($rcS.RecentAt -eq [datetime]::MinValue -and $sPasses -lt 20) { Update-ChatOverlayRecent $rcS @($idRLive); $sPasses++ }
$sliceAsk = $sliceAsk -and @($rcS.Recent).Count -eq 5 -and $sPasses -eq 4
$script:ChatOverlaySliceMs = 60000
Remove-Item -LiteralPath $pRU, $pRQ -Force
$script:ChatOverlayNetDriveSeam = $null
$script:ChatOverlayFolderSeam = $null
Check 'recent: a folder on a share or a mapped network drive never asked, and taken as there; folder asks counted against the slice' ($netOk -and $sliceAsk) "$netOk $sliceAsk / $($uIds -join ',') / $($script:FolderAsks -join ',')"
# a build's time in the log only a quarter second past its slice, not past
# 250 ms: one that spends its slice is past it as it stops, so every start
# had a line. A folder that held one there still has it said, and a whole
# build - chatoverlay -Print's, the phone board's - has no slice: 250 ms.
# The first folder asked holds each build; the slice is 400 ms, so the one
# that spent it has 200 ms to spare on a busy PC before it is logged.
$tkLog = Join-Path $script:ChatqLogDir 'overlay.log'
$tkLines = { @(if (Test-Path -LiteralPath $tkLog) { [System.IO.File]::ReadAllLines($tkLog, $utf8) | Where-Object { $_ -like '*the recent list: reading the transcripts and asking after their folders took over*' } }).Count }
$tkRun = {
    param([int]$HoldMs, [bool]$Whole)
    foreach ($k in @($script:ChatOverlayLogSeen.Keys)) { if ($k -like 'the recent list: reading*') { $script:ChatOverlayLogSeen.Remove($k) } }
    $script:TkAsks = 0
    $script:TkHold = $HoldMs
    $n0 = & $tkLines
    $c = New-ChatOverlayContext $rcHome
    $c.RecentWhole = $Whole
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Update-ChatOverlayRecent $c @($idRLive)
    [pscustomobject]@{ Ms = $sw.ElapsedMilliseconds; Lines = (& $tkLines) - $n0; Cut = $c.RecentAt -eq [datetime]::MinValue }
}
$script:ChatOverlayFolderSeam = { param($p) if (-not $script:TkAsks++) { Start-Sleep -Milliseconds $script:TkHold }; Test-Path -LiteralPath $p -PathType Container }
$script:ChatOverlaySliceMs = 400
$tkSpent = & $tkRun 450 $false   # past its slice as it stops, not 250 ms past it
$tkHeld = & $tkRun 900 $false    # held 500 ms past it
$tkWhole = & $tkRun 300 $true
$script:ChatOverlaySliceMs = 60000
$script:ChatOverlayFolderSeam = $null
Check 'recent: a build''s time logged only a quarter second past its slice - one that spent its slice is not, past 250 ms; one a folder held there is - and a whole build''s past 250 ms' (
    $tkSpent.Cut -and $tkSpent.Ms -gt 250 -and $tkSpent.Lines -eq 0 -and $tkHeld.Cut -and $tkHeld.Lines -eq 1 -and -not $tkWhole.Cut -and $tkWhole.Lines -eq 1) (
    @($tkSpent, $tkHeld, $tkWhole | ForEach-Object { "cut $($_.Cut) $($_.Ms) ms lines $($_.Lines)" }) -join ' / ')
# in the snapshot, beside the rows: a chat just closed at its head, and no open one
$idRS = '0b0b0b0b-0b0b-40b0-80b0-0b0b0b0b0b11'
$slugO = Join-Path (Join-Path $claudeHome 'projects') (Get-Slug $projO)
$cwdO = ',"cwd":' + (ConvertTo-Json $projO)
$null = New-RecentChat $idRS @((RcUser 'closed ask' '' $cwdO), (OvReply), (OvTitle 'Closed a moment ago')) 0 $slugO
$ctx.RecentAt = [datetime]::MinValue
$ctx.RecentListAt = [datetime]::MinValue
$snapR = Invoke-ChatOverlayCycle $ctx -Peek
$openIds = @($snapR.rows | ForEach-Object { [string]$_.sessionId })
Check 'the snapshot carries recent beside rows, not in them - its head the chat just closed, none that is open - and the view key has it' (
    @($snapR.recent)[0].sessionId -eq $idRS -and @($snapR.recent)[0].stateText -eq 'now' -and -not @($snapR.rows | Where-Object { $_.kind -eq 'recent' }).Count -and
    -not @($snapR.recent | Where-Object { $openIds -contains $_.sessionId }).Count -and $ctx.ViewSig -like "*`"recent`":*$idRS*") (@($snapR.recent | ForEach-Object { "$($_.sessionId) $($_.stateText)" }) -join ' | ')
$prR = (@(Write-ChatOverlayPrint 6>&1 | ForEach-Object { "$_" }) -join '')
Check '-Print lists them under the rows, as Recent' ($prR -like '*Recent*- projO  Closed a moment ago*') $prR
# -Print is one pass with nothing drawn meanwhile: its Recent build keeps to
# no slice, so the whole count is listed where a panel's pass stops at one
$pS2 = New-RecentChat '0b0b0b0b-0b0b-40b0-80b0-0b0b0b0b0b15' @((RcUser 'closed two' '' $cwdO), (OvReply), (OvTitle 'Closed second')) 0 $slugO
$pS3 = New-RecentChat '0b0b0b0b-0b0b-40b0-80b0-0b0b0b0b0b16' @((RcUser 'closed three' '' $cwdO), (OvReply), (OvTitle 'Closed third')) 0 $slugO
$script:ChatOverlaySliceMs = -1
$prW = (@(Write-ChatOverlayPrint 6>&1 | ForEach-Object { "$_" }) -join '')
$script:ChatOverlaySliceMs = 60000
Remove-Item -LiteralPath $pS2, $pS3 -Force
Check '-Print lists the whole Recent count, past the slice a panel''s pass keeps to' (
    $prW -like '*Closed second*' -and $prW -like '*Closed third*' -and $prW -like '*Closed a moment ago*') $prW
# the Windows panel's pass (RecentPool): recentMore beside recent in the
# snapshot, each aged as Recent's are
$ctx.RecentPool = $true
$recentWas = $ctx.Config.recent
$ctx.Config.recent = 1
$ctx.RecentAt = [datetime]::MinValue
$ctx.RecentListAt = [datetime]::MinValue
$snapP = Invoke-ChatOverlayCycle $ctx -Peek
Check 'the snapshot carries recentMore beside recent - the pool past overlay.recent, each aged as Recent''s are' (
    @($snapP.recent).Count -eq 1 -and @($snapP.recent)[0].sessionId -eq $idRS -and @($snapP.recentMore).Count -ge 1 -and @($snapP.recentMore).Count -le 19 -and
    -not @($snapP.recentMore | Where-Object { -not $_.stateText -or $_.sessionId -eq $idRS }).Count -and $ctx.ViewSig -like '*"recentMore":*') (
    @(@($snapP.recent) + @($snapP.recentMore) | ForEach-Object { "$($_.sessionId) $($_.stateText)" }) -join ' | ')
# a VS Code tab with no process (extension.js writeTabs): a row of the pass,
# its title from its transcript, and out of Recent at once
$null = New-Item -ItemType Directory -Path $script:ChatOverlayOpenTabsDir -Force
Write-OtFile $PID $otStart @([ordered]@{ sessionId = $idRS; cwd = $projO; label = 'tab label only' }) $script:ChatOverlayOpenTabsDir
$ctx.TabsAt = [datetime]::MinValue
$snapT = Invoke-ChatOverlayCycle $ctx -Peek
$tabRow = @($snapT.rows | Where-Object { $_.key -eq "s:$idRS" })[0]
Check 'a VS Code tab with no process: a row of the pass, titled from its transcript, with no pids - and out of Recent at once' (
    $tabRow -and $tabRow.tab -and $tabRow.status -eq 'idle' -and $tabRow.where -eq 'vscode' -and $tabRow.title -eq 'Closed a moment ago' -and @($tabRow.pids).Count -eq 0 -and
    $tabRow.project -eq 'projO' -and -not @(@($snapT.recent) + @($snapT.recentMore) | Where-Object { $_.sessionId -eq $idRS }).Count) (
    "$($tabRow | ConvertTo-Json -Compress -Depth 4) / $(@(@($snapT.recent) + @($snapT.recentMore) | ForEach-Object { $_.sessionId }) -join ',')")
Remove-Item -LiteralPath (Join-Path $script:ChatOverlayOpenTabsDir "$PID.json") -Force
$ctx.TabsAt = [datetime]::MinValue
$ctx.RecentPool = $false
$ctx.Config.recent = $recentWas
$snapG = Invoke-ChatOverlayCycle $ctx -Peek
Check 'the tab closed: its row goes and the chat is back in Recent; the pool off, no recentMore' (
    -not @($snapG.rows | Where-Object { $_.sessionId -eq $idRS }).Count -and @($snapG.recent)[0].sessionId -eq $idRS -and -not @($snapG.recentMore).Count -and
    -not $ctx.Text.ContainsKey($idRS)) (@($snapG.recent | ForEach-Object { $_.sessionId }) -join ',')
# the macOS panel's collector: no Recent built - nothing there draws it -
# while -Print, from a context of its own, still has it (just above)
$cMac = New-ChatOverlayContext
$cMac.WantRecent = $false
$readsMac = $script:ChatOverlayRecentReads
$listsMac = $script:ChatOverlayRecentLists
$snapMac = Invoke-ChatOverlayCycle $cMac -Peek
$macHost = (Get-Command Start-ChatOverlayMacHost).Definition -match '\$ctx\.WantRecent = \$false'
Check 'the macOS collector builds no Recent: nothing listed or read, none in its snapshot' (
    $macHost -and -not @($snapMac.recent).Count -and $script:ChatOverlayRecentReads -eq $readsMac -and $script:ChatOverlayRecentLists -eq $listsMac) "$macHost $(@($snapMac.recent).Count)"
$script:ChatOverlaySliceMs = $sliceWas
# an open chat nothing has titled shows its first real prompt - read line by
# line, where every line had been read as one and none taken
$idUT = '0a0a0a0a-0a0a-40a0-80a0-0a0a0a0a0a11'
$null = New-OverlayChat $idUT @((OvUser '<command-name>/clear</command-name>'), (OvUser 'untitled first ask'), (OvReply), (OvUser 'a later ask'), (OvReply))
$cxUT = New-ChatOverlayContext
Update-ChatOverlayText $cxUT ([pscustomobject]@{ SessionId = $idUT; Cwd = $projO })
Check 'an open chat nothing has titled shows its first real prompt, past a noisy one' ($cxUT.Text[$idUT].First -eq 'untitled first ask') "$($cxUT.Text[$idUT].First)"
# -Recent: kept, said, out of range refused, a running panel told
$rcSaid = @(chatoverlay -Recent 10 6>&1 | ForEach-Object { "$_" })
$rcSet = (Get-ChatOverlayConfig).recent
chatoverlay -Recent 21 *> $null
chatoverlay -Recent -1 *> $null
$rcKept = (Get-ChatOverlayConfig).recent
$rcOffSaid = @(chatoverlay -Recent 0 6>&1 | ForEach-Object { "$_" })
$cmdsR = Get-OvToldCommands { chatoverlay -Recent 5 }
Set-ChatOverlayConfig @{ recent = 50 }
$rcHeld = (Get-ChatOverlayConfig).recent
Set-ChatOverlayConfig @{ recent = 5 }
Check '-Recent: 5 unless set, kept and said, 0 is off; out of range refused, and held to 0 to 20 in config.json; a running panel told' (
    $rcSet -eq 10 -and ($rcSaid -join '|') -like '*recent chats: the newest 10 not open*' -and $rcKept -eq 10 -and ($rcOffSaid -join '|') -like '*recent chats: off*' -and
    $cmdsR -match ' reload\n' -and (Get-ChatOverlayConfig).recent -eq 5 -and $rcHeld -eq 20) "$rcSet $rcKept $rcHeld / $($rcSaid -join '|') / $($rcOffSaid -join '|')"

# unread: a chat that finished a turn since it was last opened
$uA = '0c0c0c0c-0c0c-40c0-80c0-0c0c0c0c0c01'
$uB = '0c0c0c0c-0c0c-40c0-80c0-0c0c0c0c0c02'
$uD = '0c0c0c0c-0c0c-40c0-80c0-0c0c0c0c0c03'
$uE = { param($sid, $st) [pscustomobject]@{ SessionId = $sid; Pid = 1; Status = $st; Cwd = $projO; StatusUpdatedAt = 1 } }
$cu8 = New-ChatOverlayContext
Update-ChatOverlayUnread $cu8 @((& $uE $uA 'busy'), (& $uE $uB 'busy'), (& $uE $uD 'waiting'))
$u1 = @($cu8.Unread.Keys).Count
Update-ChatOverlayUnread $cu8 @((& $uE $uA 'idle'), (& $uE $uB 'idle'), (& $uE $uD 'idle'))
$u2 = (@($cu8.Unread.Keys | Sort-Object) -join ',')
$uT = @{}
foreach ($k in $uA, $uB, $uD) { $uT[$k] = @{ Path = 'x'; AiTitle = "t $k" } }
$uR = @(Get-ChatOverlayRows -Sessions @((& $uE $uA 'idle'), (& $uE $uB 'idle')) -Texts $uT -Unread $cu8.Unread)
$uRowsOk = @($uR | Where-Object { $_.unread }).Count -eq 2 -and -not @(Get-ChatOverlayRows -Sessions @((& $uE $uA 'idle')) -Texts $uT)[0].unread
Check 'unread: working or waiting to idle marks a chat, and its row carries it; idle all along does not' (
    $u1 -eq 0 -and $u2 -eq (@($uA, $uB, $uD | Sort-Object) -join ',') -and $uRowsOk) "$u1 / $u2 / $uRowsOk"
# the open chip: the dot stays while its child runs, and goes when that ends
# with the open request written (0, 25, 40, 41) - not when held (10: the
# extension may refuse it), a chat Claude Code never lists (21: its window
# offers a terminal - and 26, 42, 43, not brought forward as well), turned
# away, failed before it, or unanswered
$script:ChatShowSpawnSeam = { param($c) 'spawned' }
$Hu = @{ Ctx = $cu8; OpenProc = $null; ChipText = $null }
$script:uSays = @()
$uRowA = @($uR | Where-Object { $_.sessionId -eq $uA })[0]
$uEnds = @(foreach ($code in '0', '10', '25', '15', '16', '20', '21', '26', '30', '40', '41', '42', '43', '50', 'late') {
        $cu8.Unread[$uA] = $true
        Invoke-ChatOverlayOpen $Hu $uRowA
        $during = $cu8.Unread.ContainsKey($uA)
        $Hu.OpenProc = if ($code -eq 'late') { [pscustomobject]@{ HasExited = $false } } else { [pscustomobject]@{ HasExited = $true; ExitCode = [int]$code } }
        if ($code -eq 'late') { $Hu.OpenAt = (Get-Date).AddSeconds(-61) }
        $busySaid = $Hu.OpenSay -and $Hu.OpenSay.Kind -eq 'busy'
        Update-ChatOverlayOpen $Hu
        $script:uSays += "$code=$busySaid/$($Hu.OpenSay.Kind)/$($Hu.OpenSay.Tone)"
        "$code=$during/$($cu8.Unread.ContainsKey($uA))/$([bool]$Hu.OpenProc)"
    }) -join ' '
$script:ChatShowSpawnSeam = { param($c) $null }
Check 'unread: the open chip takes the dot only once its child says the open request was written - not held, turned away or failed before it, nor for a run''s live view (16) or a chat Claude Code never lists (21, 26, 42, 43)' (
    $uEnds -eq '0=True/False/False 10=True/True/False 25=True/False/False 15=True/True/False 16=True/True/False 20=True/True/False 21=True/True/False 26=True/True/False 30=True/True/False 40=True/False/False 41=True/False/False 42=True/True/False 43=True/True/False 50=True/True/False late=True/True/False') $uEnds
# and each one said on the panel: under way from the click, then how it went
# - only 0, a run's live view (16) and a chat never listed (21) in the quiet tone; one never listed whose window was not brought
# forward (26, 42, 43) warns, as 25, 40 and 41 do; a child that never started said at once
$uSaid = $script:uSays -join ' '
$Hu.OpenProc = $null; $Hu.OpenSay = $null
$script:ChatShowSpawnSeam = { param($c) $null }
Invoke-ChatOverlayOpen $Hu $uRowA
$uNoStart = $Hu.OpenSay.Kind -eq 'nostart' -and $Hu.OpenSay.Tone -eq 'warn' -and -not $Hu.OpenProc
$Hu.OpenSay.Until = (Get-Date).AddSeconds(-1)
Update-ChatOverlayOpen $Hu
$uGoneSaid = $null -eq $Hu.OpenSay
Check 'an open from the chip is said from the click to its end: busy, then opened or why not - a timeout and a child that did not start too - and the line goes once its time is up' (
    $uSaid -eq '0=True/done/dim 10=True/done/warn 25=True/done/warn 15=True/done/warn 16=True/done/dim 20=True/done/warn 21=True/done/dim 26=True/done/warn 30=True/done/warn 40=True/done/warn 41=True/done/warn 42=True/done/warn 43=True/done/warn 50=True/done/warn late=True/late/warn' -and
    $uNoStart -and $uGoneSaid) "$uSaid $uNoStart $uGoneSaid"
# the chip on a chat a job of chatq's runs in reads watch - the same open,
# which Show-ChatFresh turns into the run's live view (16) - and says so
$wChip = { param($state) @(Get-ChatOverlayChipActions ([pscustomobject]@{ key = "s:$uA"; kind = 'session'; provider = 'claude'; sessionId = $uA; cwd = $projO; status = 'busy'; where = 'run'
                job = $(if ($state) { [pscustomobject]@{ seq = 15; state = $state; eta = $null } } else { $null }) }))[0] }
$wRun = & $wChip 'running'
$wQueued = & $wChip 'queued'
$wNone = & $wChip $null
Check 'the chip reads watch while the row''s job runs - the same open under another word; open otherwise' (
    $wRun.Id -eq 'open' -and $wRun.Label -eq 'watch' -and $wRun.Tip -like '*watch it live*' -and $wQueued.Id -eq 'open' -and $wQueued.Label -eq 'open' -and $wNone.Label -eq 'open') "$($wRun.Id)=$($wRun.Label) $($wQueued.Label) $($wNone.Label)"
Check 'the tray for a run''s live view asked for (16), and a print-mode run no job is (15) as before' (
    (Get-ChatOverlayOpenBalloon 16) -eq 'A queued prompt is running in that chat - its live view opens in VS Code.' -and
    (Get-ChatOverlayOpenBalloon 15) -eq 'A queued prompt is running in that chat - open it once it finishes.') "$(Get-ChatOverlayOpenBalloon 16)"
# the watch chip's word comes back once its open ends (brushes by name: no
# WPF in this process)
$fnBrush = ${function:Get-ChatOverlayBrush}
${function:Get-ChatOverlayBrush} = { param($n) $n }
try {
    $script:ChatShowSpawnSeam = { param($c) [pscustomobject]@{ HasExited = $true; ExitCode = 16 } }
    $Hw = @{ Ctx = $cu8; OpenProc = $null; ChipText = [pscustomobject]@{ Text = 'watch'; Foreground = $null }; ChipOpenLabel = 'watch' }
    Invoke-ChatOverlayOpen $Hw $uRowA
    $wDuring = [string]$Hw.ChipText.Text
    Update-ChatOverlayOpen $Hw
}
finally { ${function:Get-ChatOverlayBrush} = $fnBrush; $script:ChatShowSpawnSeam = { param($c) $null } }
Check 'the watch chip says opening while its child runs, and watch again after' ($wDuring -eq 'opening' -and $Hw.ChipText.Text -eq 'watch' -and -not $Hw.OpenProc) "$wDuring $($Hw.ChipText.Text)"
# The open's end brings the chat's VS Code window to the front: picked from
# VS Code's windows by title - its folder's name, or for a window with other
# folders the name its tab file gives - and only ever one. Every window call
# below is a stand-in, a desktop of handles; none here is real.
$fw = { param($h, $t) [pscustomobject]@{ Handle = [int64]$h; Title = $t } }
$fwA = & $fw 11 'notes.md - projO - Visual Studio Code'
$fwP = & $fw 12 'a.ps1 - projP - Work - Visual Studio Code'
$fwW = & $fw 13 'x - team (Workspace) - Visual Studio Code'
$fwO = & $fw 14 'other - Visual Studio Code'
$fwA2 = & $fw 15 'b.md - projO - Visual Studio Code'
$projP = Join-Path $work 'projP'
$selH = { param($w) if ($w) { [string]$w.Handle } else { '-' } }
$sel = @(
    (& $selH (Select-ChatCodeWindow -Cwd $projO -Windows @($fwO, $fwA, $fwW)))
    (& $selH (Select-ChatCodeWindow -Cwd $projP -Windows @($fwP, $fwA) -Profiles @('Work')))
    (& $selH (Select-ChatCodeWindow -Cwd $projP -Windows @($fwP, $fwA)))
    (& $selH (Select-ChatCodeWindow -Cwd $projO -Windows @($fwA, $fwA2)))
    (& $selH (Select-ChatCodeWindow -Cwd $projO -Windows @($fwA, $fwW) -Name 'team'))
    (& $selH (Select-ChatCodeWindow -Cwd $projO -Windows @($fwA) -Name 'team'))
    (& $selH (Select-ChatCodeWindow -Cwd $projO -Windows @($fwO, $fwW)))
    (& $selH (Select-ChatCodeWindow -Cwd '' -Windows @($fwA)))) -join ','
Check 'to the front: the one VS Code window on the chat''s folder, a profile''s name taken off; by its tab''s window name for one with other folders; two on folders of one name, or none, is none' (
    $sel -eq '11,12,-,-,13,-,-,-') $sel
$planT = @(foreach ($c in 0, 10, 15, 16, 20, 21, 25, 26, 30, 40, 41, 42, 43, 50, 1, -1) {
        $pl = Get-ChatOverlayRaisePlan $c
        if ($pl) { "$c=$($pl.By)/$($pl.Seconds)/$($pl.Words)" } else { "$c=-" }
    }) -join ' '
Check 'to the front: only the ends that showed the chat ask for its window - 15, 20, 30, 50 and a crash never; 25 and 26 by their tab''s name; 40-43 only a window there now; in front, each says what it did' (
    $planT -eq '0=folder/5/0 10=folder/5/10 15=- 16=folder/5/16 20=- 21=folder/5/21 25=name/0/0 26=name/0/21 30=- 40=folder/0/0 41=folder/0/0 42=folder/0/21 43=folder/0/21 50=- 1=- -1=-') $planT
$svFront = @{ Raise = $script:ChatOverlayRaiseSeam; Grant = $script:ChatOverlayGrantSeam; List = $script:ChatCodeWindowListSeam; Spawn = $script:ChatShowSpawnSeam; Balloon = $script:ChatOverlayBalloonSeam }
$script:Dk = $null
$script:Wins = @()
$script:EndCode = '0'
$script:LastH = $null
$script:FrontSaid = [System.Collections.Generic.List[string]]::new()
$script:GrantOrder = [System.Collections.Generic.List[string]]::new()
$script:GrantPids = @()
# the desktop: which window is in front, which are minimized or hung, whether
# Windows lets the plain call and the joined one through; string keys, as a
# handle comes in as int64
$newDk = { param($front) $script:Dk = @{ Front = [int64]$front; Min = @{}; Hung = @{}; Plain = $true; Join = $true; Calls = [System.Collections.Generic.List[string]]::new() } }
$dkSeam = {
    param($c, $h, $o)
    $script:Dk.Calls.Add("$c $h $o")
    if ($c -eq 'minimized') { return [bool]$script:Dk.Min["$h"] }
    if ($c -eq 'restore') { $script:Dk.Min.Remove("$h"); return $true }
    if ($c -eq 'foreground') { return $script:Dk.Front }
    if ($c -eq 'hung') { return [bool]$script:Dk.Hung["$h"] }
    if ($c -eq 'front') { if ($script:Dk.Plain) { $script:Dk.Front = [int64]$h }; return [bool]$script:Dk.Plain }
    if ($c -eq 'joined') { if ($script:Dk.Join) { $script:Dk.Front = [int64]$h }; return [bool]$script:Dk.Join }
    $null
}
$fwTab = [pscustomobject]@{ SessionId = $uA; Cwd = $projO; Label = 'l'; Window = 'team'; HostPid = 1 }
# one open clicked and ended with -code, VS Code's windows -wins, the open
# tabs -tabs; -setup changes the desktop between the click and the end
$runEnd = {
    param([string]$code, $wins, $tabs = @(), [scriptblock]$setup = $null)
    & $newDk 7
    $script:Wins = @($wins)
    $script:EndCode = $code
    $script:FrontSaid.Clear()
    $script:GrantOrder.Clear()
    $h = @{ Ctx = @{ Unread = @{}; Tabs = @($tabs) }; OpenProc = $null; ChipText = $null }
    $null = Invoke-ChatOverlayOpen $h $uRowA
    if ($code -eq 'late') { $h.OpenAt = (Get-Date).AddSeconds(-61) }
    $script:Dk.Calls.Clear()
    if ($setup) { $null = & $setup }
    $null = Update-ChatOverlayOpen $h
    $script:LastH = $h
}
$noCall = { param($like) -not @($script:Dk.Calls | Where-Object { $_ -like $like }).Count }
$frontLog = { @([System.IO.File]::ReadAllLines((Join-Path $script:ChatqLogDir 'overlay.log')) | Where-Object { $_ -like '*to the front:*' }) }
try {
    $script:ChatOverlayRaiseSeam = $dkSeam
    $script:ChatOverlayGrantSeam = { param($p) $script:GrantOrder.Add('grant'); $script:GrantPids = @($p); @($p) }
    $script:ChatCodeWindowListSeam = { $script:Wins }
    $script:ChatShowSpawnSeam = {
        param($c)
        $script:GrantOrder.Add('spawn')
        if ($script:EndCode -eq 'late') { [pscustomobject]@{ HasExited = $false } } else { [pscustomobject]@{ HasExited = $true; ExitCode = [int]$script:EndCode } }
    }
    $script:ChatOverlayBalloonSeam = { param($b) $script:FrontSaid.Add([string]$b.Text) }
    $frontT = @(foreach ($code in '0', '10', '15', '16', '20', '21', '25', '26', '30', '40', '41', '42', '43', '50', '1', '-1', 'late') {
            & $runEnd $code @($fwA, $fwW) @($fwTab)
            "$code=$($script:Dk.Front)/$(@($script:Dk.Calls | Where-Object { $_ -like 'front *' -or $_ -like 'joined *' }).Count)"
        }) -join ' '
    Check 'to the front: an open that showed the chat brings its window, on its folder or by its tab''s name - never one turned away, not started, failed, crashed or unanswered' (
        $frontT -eq '0=11/1 10=11/1 15=7/0 16=11/1 20=7/0 21=11/1 25=13/1 26=13/1 30=7/0 40=11/1 41=11/1 42=11/1 43=11/1 50=7/0 1=7/0 -1=7/0 late=7/0') $frontT
    # the grant at the click, before its child starts: VS Code's processes
    # alone; the window in front then kept for the fallback
    & $runEnd '0' @($fwA)
    $gOrder = $script:GrantOrder -join ','
    $gBad = @($script:GrantPids | Where-Object { $q = Get-Process -Id $_ -EA SilentlyContinue; $q -and $q.ProcessName -notin 'Code', 'Code - Insiders' }).Count
    $gClick = $script:LastH.OpenFront -eq 7
    Check 'to the front: at the click, before the child starts, VS Code''s own processes - and only those - are let bring their window forward; the window in front kept' (
        $gOrder -eq 'grant,spawn' -and $gBad -eq 0 -and $gClick) "$gOrder bad $gBad front $($script:LastH.OpenFront) pids $(@($script:GrantPids).Count)"
    # a window not there yet is looked for again each tick, and found;
    # once its time is up, given up on - and one turning up later left be
    & $runEnd '0' @()
    $lWait = $null -ne $script:LastH.Raise -and $script:Dk.Front -eq 7 -and $script:LastH.OpenSay.Text -like 'opened *'
    $script:Wins = @($fwA)
    Update-ChatOverlayOpen $script:LastH
    $lFound = $script:Dk.Front -eq 11 -and $null -eq $script:LastH.Raise
    & $runEnd '0' @()
    $script:LastH.Raise.Until = (Get-Date).AddSeconds(-1)
    Update-ChatOverlayOpen $script:LastH
    $lGone = $null -eq $script:LastH.Raise -and $script:Dk.Front -eq 7 -and (& $noCall 'front *')
    $lGoneLog = @(& $frontLog)[-1]
    $script:Wins = @($fwA)
    Update-ChatOverlayOpen $script:LastH
    $lLater = $script:Dk.Front -eq 7
    & $runEnd '40' @()
    $lNow = $null -eq $script:LastH.Raise -and $script:LastH.OpenSay.Text -like '*code command was not found*' -and $script:LastH.OpenSay.Tone -eq 'warn'
    Check 'to the front: a window not there yet looked for again each tick and brought forward; given up on once its time is up; 40-43 look once' (
        $lWait -and $lFound -and $lGone -and $lLater -and $lNow -and $lGoneLog -like "*open: $($uA.Substring(0, 8)) to the front: no one VS Code window on its folder - left to VS Code") "$lWait $lFound $lGone $lLater $lNow / $lGoneLog"
    # minimized: restored before it is asked for the front
    & $runEnd '0' @($fwA) @() { $script:Dk.Min['11'] = $true }
    $rSeq = @($script:Dk.Calls | ForEach-Object { ($_ -split ' ')[0] }) -join ','
    $rLog = @(& $frontLog)[-1]
    Check 'to the front: a minimized window restored first' (
        $rSeq -eq 'minimized,restore,foreground,front,foreground,foreground' -and $script:Dk.Front -eq 11 -and $rLog -like '*to the front: in front (restored)') "$rSeq / $rLog"
    # the one fallback: only when Windows said no and the window the click
    # left in front is still there and answering
    & $runEnd '0' @($fwA) @() { $script:Dk.Plain = $false }
    $jYes = ($script:Dk.Calls -contains 'joined 11 7') -and $script:Dk.Front -eq 11 -and $script:LastH.OpenSay.Text -like 'opened *' -and (@(& $frontLog)[-1] -like '*in front (joined)')
    & $runEnd '0' @($fwA)
    $jPlain = (& $noCall 'joined *') -and $script:Dk.Front -eq 11
    & $runEnd '0' @($fwA) @() { $script:Dk.Plain = $false; $script:Dk.Hung['7'] = $true }
    $jHung = (& $noCall 'joined *') -and $script:Dk.Front -eq 7 -and (@(& $frontLog)[-1] -like '*still behind - the window in front is not answering')
    $jHungSay = $script:LastH.OpenSay
    & $runEnd '0' @($fwA) @() { $script:Dk.Plain = $false; $script:Dk.Front = 8 }
    $jOther = (& $noCall 'joined *') -and $script:Dk.Front -eq 8
    & $runEnd '0' @($fwA) @() { $script:Dk.Front = 11 }
    $jThere = (& $noCall 'front *') -and (& $noCall 'joined *') -and $script:Dk.Front -eq 11
    & $runEnd '0' @($fwA) @() { $script:Dk.Plain = $false; $script:Dk.Join = $false }
    $jBoth = ($script:Dk.Calls -contains 'joined 11 7') -and $script:Dk.Front -eq 7
    Check 'to the front: the joined fallback only when Windows said no and the click''s window is still in front - never with it hung, another put there since, or the window there already' (
        $jYes -and $jPlain -and $jHung -and $jOther -and $jThere -and $jBoth) "$jYes $jPlain $jHung $jOther $jThere $jBoth"
    Check 'to the front: opened but left behind says so, and where to click' (
        $jHungSay.Text -like "opened '*' - VS Code's window could not be brought to the front - click it on the taskbar" -and $jHungSay.Tone -eq 'warn' -and $jHungSay.Kind -eq 'done') "$($jHungSay.Text)"
    # a window of several folders brought forward (25, 26): the words of 0
    # and 21; not found, or left behind, 25's and 26's own
    $b21 = Get-ChatOverlayOpenBalloon 21
    & $runEnd '25' @($fwW) @($fwTab)
    $w25 = $script:LastH.OpenSay.Text -like 'opened *' -and $script:LastH.OpenSay.Tone -eq 'dim' -and -not $script:FrontSaid.Count -and $script:Dk.Front -eq 13
    & $runEnd '26' @($fwW) @($fwTab)
    $w26 = $script:LastH.OpenSay.Text -like "* - $b21" -and $script:LastH.OpenSay.Tone -eq 'dim' -and ($script:FrontSaid -join '|') -eq $b21 -and $script:Dk.Front -eq 13
    & $runEnd '25' @($fwW)
    $n25 = $script:LastH.OpenSay.Text -like '*bring it forward yourself.' -and $script:LastH.OpenSay.Tone -eq 'warn' -and ($script:FrontSaid -join '|') -eq (Get-ChatOverlayOpenBalloon 25) -and
        $script:Dk.Front -eq 7 -and (@(& $frontLog)[-1] -like '*to the front: its window has other folders, and no tab of it is listed - left as it is')
    & $runEnd '26' @($fwW)
    $n26 = $script:LastH.OpenSay.Text -like '*so bring it forward yourself.' -and $script:LastH.OpenSay.Tone -eq 'warn' -and ($script:FrontSaid -join '|') -eq (Get-ChatOverlayOpenBalloon 26)
    & $runEnd '25' @($fwW) @($fwTab) { $script:Dk.Plain = $false; $script:Dk.Join = $false }
    $k25 = $script:LastH.OpenSay.Text -like '*bring it forward yourself.' -and $script:LastH.OpenSay.Tone -eq 'warn'
    Check 'to the front: 25 and 26 brought forward say what 0 and 21 do; with no tab of the chat listed, or left behind, their own words' (
        $w25 -and $w26 -and $n25 -and $n26 -and $k25) "$w25 $w26 $n25 $n26 $k25"
    & $runEnd '40' @($fwA)
    $r40 = $script:LastH.OpenSay.Text -like 'opened *' -and $script:LastH.OpenSay.Tone -eq 'dim' -and -not $script:FrontSaid.Count
    & $runEnd '43' @($fwA)
    $r43 = $script:LastH.OpenSay.Text -like "* - $b21" -and $script:LastH.OpenSay.Tone -eq 'dim'
    $ascii = -not @(& $frontLog | Where-Object { $_ -match '[^\x00-\x7F]' -or $_ -like '*notes.md*' -or $_ -like '*Visual Studio Code*' -or $_ -like '*(Workspace)*' }).Count
    Check 'to the front: 40-43 brought forward say what 0 and 21 do; the log says how each went, in ASCII, and never a window''s title' (
        $r40 -and $r43 -and $ascii) "$r40 $r43 $ascii"
    # and with no seam, as for real: CHATQ_NOFRONT, which every test run
    # sets, refuses every call, and the calls' type was never compiled.
    # Asked first: a run without it keeps the seams and fails here, and so
    # never reaches the real calls to find out.
    $nfR = $null; $nfOk = $false; $nfEnd = $false
    if ($env:CHATQ_NOFRONT -eq '1') {
        $script:ChatOverlayRaiseSeam = $null
        $script:ChatOverlayGrantSeam = $null
        $nfR = Invoke-ChatOverlayRaise -Handle 11 -WasFront 7
        $nfOk = -not $nfR.Front -and $nfR.Why -eq 'refused - CHATQ_NOFRONT is set' -and
            @(Grant-ChatOverlayFront @(4242)).Count -eq 0 -and $null -eq (Invoke-ChatOverlayFrontCall 'foreground') -and $null -eq ('ChatOverlayFront' -as [type])
        & $runEnd '0' @($fwA)
        $nfEnd = $script:LastH.OpenSay.Text -like '*could not be brought to the front*' -and $script:Dk.Front -eq 7 -and -not $script:Dk.Calls.Count -and
            (@(& $frontLog)[-1] -like '*still behind - refused - CHATQ_NOFRONT is set')
    }
    Check 'to the front: in a test run nothing reaches the real calls - CHATQ_NOFRONT refuses them, and their type is never compiled' ($nfOk -and $nfEnd) "nofront=$($env:CHATQ_NOFRONT) $nfOk $nfEnd $($nfR.Why)"
}
finally {
    $script:ChatOverlayRaiseSeam = $svFront.Raise
    $script:ChatOverlayGrantSeam = $svFront.Grant
    $script:ChatCodeWindowListSeam = $svFront.List
    $script:ChatShowSpawnSeam = $svFront.Spawn
    $script:ChatOverlayBalloonSeam = $svFront.Balloon
}
# the real calls are made in two functions alone, every line naming the call
# that changes the front window carries the hook's marker, and the type holds
# nothing that types, moves the pointer or makes a window topmost - those
# names put together here, so this file names none of them whole
$owSrc = Join-Path $root 'src\overlay-windows.ps1'
$owAst = [System.Management.Automation.Language.Parser]::ParseFile($owSrc, [ref]$null, [ref]$null)
$owUse = @($owAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
        Where-Object { $_.Body.Extent.Text.Contains('[ChatOverlayFront]::') } | ForEach-Object { $_.Name } | Sort-Object) -join ','
$srcUse = @(Get-ChildItem -LiteralPath (Join-Path $root 'src') -Filter '*.ps1' | Select-String -Pattern '[ChatOverlayFront]::' -SimpleMatch | ForEach-Object { $_.Filename } | Select-Object -Unique) -join ','
$sfw = 'SetFore' + 'groundWindow'
$sfwLines = @([System.IO.File]::ReadAllLines($owSrc) | Where-Object { $_.Contains($sfw) })
$sfwMarked = $sfwLines.Count -eq 5 -and -not @($sfwLines | Where-Object { $_ -notlike '*// allow-input-hijack - the user''s own click on open asks for it' }).Count
$banned = @(('Send' + 'Input'), ('keybd' + '_event'), ('mouse' + '_event'), ('SetCursor' + 'Pos'), ('SetWindow' + 'Pos'), 'TOPMOST')
$frontClean = -not @($banned | Where-Object { $script:ChatOverlayFrontCode.Contains($_) }).Count
Check 'to the front: the real calls only through Invoke-ChatOverlayFrontCall and Grant-ChatOverlayFront, each line naming them marked, and nothing that types, moves the pointer or makes a window topmost' (
    $owUse -eq 'Grant-ChatOverlayFront,Invoke-ChatOverlayFrontCall' -and $srcUse -eq 'overlay-windows.ps1' -and $sfwMarked -and $frontClean) "$owUse / $srcUse / $($sfwLines.Count) $sfwMarked $frontClean"
$cu8.Unread.Remove($uA)
Update-ChatOverlayUnread $cu8 @((& $uE $uA 'idle'), (& $uE $uB 'busy'), (& $uE $uD 'idle'))
$uBusy = -not $cu8.Unread.ContainsKey($uA) -and -not $cu8.Unread.ContainsKey($uB) -and $cu8.Unread.ContainsKey($uD)
Update-ChatOverlayUnread $cu8 @((& $uE $uA 'idle'), (& $uE $uB 'busy'))
$uGone = @($cu8.Unread.Keys).Count -eq 0
Check 'unread: cleared by working again, and by its session going' ($uBusy -and $uGone) "$uBusy $uGone"
# not the chat in front as it finishes: its claude's chain of parents - the
# VS Code window's extension host, then the Code.exe that owns the window;
# a terminal's shell, then what draws it - against the window in front,
# walked in one process snapshot a pass, taken only as a chat goes idle and
# a chain is not known yet
$uV = '0c0c0c0c-0c0c-40c0-80c0-0c0c0c0c0c04'
$uW = '0c0c0c0c-0c0c-40c0-80c0-0c0c0c0c0c05'
$uX = '0c0c0c0c-0c0c-40c0-80c0-0c0c0c0c0c06'
$uY = '0c0c0c0c-0c0c-40c0-80c0-0c0c0c0c0c07'
$uF = { param($sid, $procId, $st) [pscustomobject]@{ SessionId = $sid; Pid = $procId; ProcStart = 1; Status = $st; Cwd = $projO; StatusUpdatedAt = 1 } }
# as Win32_Process has them: names with .exe, Explorer's in its own case
$tP = { param($id, $par, $name, $start = $null) [pscustomobject]@{ ProcessId = $id; ParentProcessId = $par; Name = $name; CreationDate = $start } }
$tAt = [datetime]'2026-01-01T10:00:00'
$script:ProcList = @(
    (& $tP 71 72 'claude.exe'), (& $tP 72 73 'Code.exe'), (& $tP 73 74 'Code.exe'), (& $tP 74 4 'pwsh.exe')
    (& $tP 81 82 'claude.exe'), (& $tP 82 83 'pwsh.exe'), (& $tP 83 84 'WindowsTerminal.exe'), (& $tP 84 4 'Explorer.EXE')
    # five hops up to what draws it: three was one short
    (& $tP 91 92 'claude.exe'), (& $tP 92 93 'node.exe'), (& $tP 93 94 'bash.exe'), (& $tP 94 95 'bash.exe'), (& $tP 95 96 'tmux.exe')
    (& $tP 96 97 'wsl.exe'), (& $tP 97 4 'WindowsTerminal.exe')
    # a parent younger than its child: its pid used again
    (& $tP 101 102 'claude.exe' $tAt), (& $tP 102 4 'pwsh.exe' $tAt.AddHours(1))
)
$script:TableAsks = [System.Collections.Generic.List[int]]::new()
$script:TableFail = $false
$script:TableSlowMs = 0
$script:ChatProcessTableSeam = {
    $script:TableAsks.Add(1)
    if ($script:TableSlowMs) { Start-Sleep -Milliseconds $script:TableSlowMs }
    if ($script:TableFail) { $null } else { $script:ProcList }
}
# no lookup one at a time any more: the old way's seam fails the test if asked
$script:ChatParentSeam = { param($e) $script:TableAsks.Add(100); $null }
$fg = 73
$script:ChatForegroundSeam = { $fg }
$all4 = { param($v, $w, $x, $y) @((& $uF $uV 71 $v), (& $uF $uW 81 $w), (& $uF $uX 91 $x), (& $uF $uY 101 $y)) }
$cf = New-ChatOverlayContext
Update-ChatOverlayUnread $cf (& $all4 'busy' 'busy' 'busy' 'busy')
$fAsk0 = $script:TableAsks.Count
Update-ChatOverlayUnread $cf (& $all4 'idle' 'idle' 'idle' 'idle')
$fVs = -not $cf.Unread.ContainsKey($uV) -and $cf.Unread.ContainsKey($uW) -and $cf.Unread.ContainsKey($uX) -and $cf.Unread.ContainsKey($uY)
$fChains = ($cf.Chains.Values | ForEach-Object { $_ -join '>' } | Sort-Object) -join ' '
# four chains wanted, one snapshot taken
$fAsk1 = $script:TableAsks.Count
# again, with the terminal in front: nothing looked up twice
$fg = 83
Update-ChatOverlayUnread $cf (& $all4 'waiting' 'busy' 'busy' 'busy')
Update-ChatOverlayUnread $cf (& $all4 'idle' 'idle' 'idle' 'idle')
$fTerm = $cf.Unread.ContainsKey($uV) -and -not $cf.Unread.ContainsKey($uW) -and $script:TableAsks.Count -eq $fAsk1
# the window five hops up in front
$fg = 96
Update-ChatOverlayUnread $cf (& $all4 'idle' 'idle' 'busy' 'idle')
Update-ChatOverlayUnread $cf (& $all4 'idle' 'idle' 'idle' 'idle')
$fFive = -not $cf.Unread.ContainsKey($uX) -and $script:TableAsks.Count -eq $fAsk1
# nothing known in front: marked, as before this was asked; a process gone
# takes its chain with it
$fg = 0
Update-ChatOverlayUnread $cf (& $all4 'busy' 'busy' 'busy' 'busy')
Update-ChatOverlayUnread $cf (& $all4 'idle' 'idle' 'idle' 'idle')
$fNone = @($cf.Unread.Keys).Count -eq 4 -and $script:TableAsks.Count -eq $fAsk1
Update-ChatOverlayUnread $cf @((& $uF $uV 71 'idle'))
$fPruned = @($cf.Chains.Keys).Count -eq 1
# a snapshot that failed: marked, the chain not kept, and asked again the
# next time - where a chain cut short by it had been kept for good
$fg = 73
$script:TableFail = $true
$cg = New-ChatOverlayContext
$gAsk = $script:TableAsks.Count
Update-ChatOverlayUnread $cg @((& $uF $uV 71 'busy'))
Update-ChatOverlayUnread $cg @((& $uF $uV 71 'idle'))
$gFail = $cg.Unread.ContainsKey($uV) -and @($cg.Chains.Keys).Count -eq 0
$script:TableFail = $false
Update-ChatOverlayUnread $cg @((& $uF $uV 71 'busy'))
Update-ChatOverlayUnread $cg @((& $uF $uV 71 'idle'))
$gFail = $gFail -and -not $cg.Unread.ContainsKey($uV) -and @($cg.Chains.Keys).Count -eq 1 -and $script:TableAsks.Count -eq $gAsk + 2
# a slow snapshot is logged, its time rounded down to a quarter second
$script:TableSlowMs = 300
$ch = New-ChatOverlayContext
Update-ChatOverlayUnread $ch @((& $uF $uV 71 'busy'))
Update-ChatOverlayUnread $ch @((& $uF $uV 71 'idle'))
$script:TableSlowMs = 0
$slowLog = [System.IO.File]::ReadAllText((Join-Path $script:ChatqLogDir 'overlay.log'), $utf8)
$slowM = [regex]::Match($slowLog, 'the unread check: listing the processes took over (\d+) ms')
$fSlow = $slowM.Success -and [int]$slowM.Groups[1].Value -ge 250 -and [int]$slowM.Groups[1].Value % 250 -eq 0
$script:ChatProcessTableSeam = $null
$script:ChatParentSeam = $script:SeamsAtStart.Parent
$script:ChatForegroundSeam = { 0 }
Check 'unread: not for a chat whose window is in front as it finishes - VS Code by its window''s Code.exe, a terminal by what draws it, five hops up' (
    $fAsk0 -eq 0 -and $fVs -and $fChains -eq '101 71>72>73 81>82>83 91>92>93>94>95>96' -and $fAsk1 -eq 1 -and $fTerm -and $fFive -and $fNone -and $fPruned) "$fAsk0 $fVs '$fChains' $fAsk1 $fTerm $fFive $fNone $fPruned"
Check 'unread: a chain not kept when its snapshot failed, and a slow snapshot logged in overlay.log' ($gFail -and $fSlow) "$gFail $fSlow '$($slowM.Value)'"
# and with no seam, as for real: Windows' own list, not the Win32_Process
# query it stands in for - this process in it with its name, parent and
# start, as Get-Process and that query have them
$ptReal = Get-ChatProcessTable
$ptMe = if ($ptReal) { $ptReal[$PID] } else { $null }
$ptGp = Get-Process -Id $PID
$ptCim = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $PID"
# the list itself, so a table that came from the query instead fails here
$ptNat = if ('ChatProcTable' -as [type]) { @([ChatProcTable]::List()) } else { @() }
$ptNatMe = @($ptNat | Where-Object { $_ -and $_.ProcessId -eq $PID -and $_.ParentProcessId -eq [int]$ptCim.ParentProcessId })
Check 'the process table: Windows'' own list - this process in it by its name, parent and start, as Get-Process and Win32_Process have them' (
    $ptNat.Count -gt 10 -and $ptNatMe.Count -eq 1 -and $ptReal.Count -gt 10 -and $ptMe -and $ptMe.Name -eq $ptGp.ProcessName -and $ptMe.Parent -eq [int]$ptCim.ParentProcessId -and
    $ptMe.Start -is [datetime] -and [Math]::Abs(($ptMe.Start - $ptGp.StartTime).TotalSeconds) -lt 1) "$($ptNat.Count) $($ptNatMe.Count) $(if ($ptReal) { $ptReal.Count }) $($ptMe | ConvertTo-Json -Compress)"
# through a pass: counted, and said in the tray's tooltip
$ctx.LastStatus[$idO3] = 'busy'
$snapU = Invoke-ChatOverlayCycle $ctx -Peek
$tipU = Format-ChatOverlayTooltip $snapU
Check 'a pass counts the unread, its row marked, and the tray says "N new"' (
    $snapU.counts.unread -eq 1 -and @($snapU.rows | Where-Object { $_.sessionId -eq $idO3 -and $_.kind -eq 'session' })[0].unread -and $tipU -like '*1 new*') "$($snapU.counts.unread) / $tipU"
$ctx.Unread.Clear()
# off Windows - the macOS panel's collector - no chat is marked: no chip
# there clears a dot, and no window in front spares one
$winWas = $script:ChatqIsWindows
$script:ChatqIsWindows = $false
try { $cOff = New-ChatOverlayContext } finally { $script:ChatqIsWindows = $winWas }
$cOff.LastStatus[$idO3] = 'busy'
$snapOff = Invoke-ChatOverlayCycle $cOff -Peek
Check 'unread: none off Windows - the pass skips it, nothing counted or marked' (
    -not $cOff.WantUnread -and $ctx.WantUnread -and [int]$snapOff.counts.unread -eq 0 -and -not @($snapOff.rows | Where-Object { $_.unread }).Count -and
    -not @($cOff.Unread.Keys).Count) "$($cOff.WantUnread) $($snapOff.counts.unread)"

# the Windows panel itself, built but never shown, in the STA process WPF needs
$wpf = @"
$staLoad
# no mouse button held and the pointer far off, whatever the real mouse's:
# what the pointer check shuts and saves never waits on a hand on it
`$script:ChatOverlayMouseDownSeam = { `$false }
`$script:ChatOverlayPointerSeam = { [System.Drawing.Point]::new(-100000, -100000) }
Initialize-ChatOverlayNative
$staPanel
`$use = @([pscustomobject]@{ provider = 'Claude'; source = 'live'; stale = `$false; status = '22:22'; windows = @([pscustomobject]@{ label = '5h'; percent = 42; resetsAt = `$null; severity = 'normal'; limited = `$false }) })
`$rows = @(1..10 | ForEach-Object { [pscustomobject]@{ key = "s:`$_"; kind = 'session'; status = 'idle'; rank = 3; project = 'p'; title = "chat `$_"; prompt = 'x'; stateText = 'idle 1m'; job = `$null } })
`$H.Ctx.ViewSig = 'a'
Update-ChatOverlayView `$H ([pscustomobject]@{ header = [pscustomobject]@{ usage = `$use; notes = @() }; rows = `$rows })
`$t = @(`$H.Stack.Children | Where-Object { `$_ -is [System.Windows.Controls.TextBlock] } | ForEach-Object { `$_.Text })
`$n10 = `$H.Stack.Children.Count
`$more = `$t -contains '+2 more ' + [char]0x00B7 + ' 2 idle'
# usage as a line - name, end, then the windows between - and as bars once
# the settings box says so
`$u0 = `$H.Stack.Children[0]
# a TextBlock built of runs has an empty .Text: the runs' own text
`$lineOk = `$u0 -is [System.Windows.Controls.DockPanel] -and (@(`$u0.Children | ForEach-Object { (@(`$_.Inlines) | ForEach-Object { `$_.Text }) -join '' }) -join '|') -eq 'Claude|22:22|5h 42%'
Set-ChatOverlayUsageView `$H 'bars'
`$H.ViewKey = `$null
Update-ChatOverlayView `$H ([pscustomobject]@{ header = [pscustomobject]@{ usage = `$use; notes = @() }; rows = `$rows })
# the bars with the name and, under it, when the figure is from
`$b0 = `$H.Stack.Children[0]
`$barsOk = (Get-ChatOverlayConfig).usageView -eq 'bars' -and `$b0 -is [System.Windows.Controls.Grid] -and (@(`$b0.Children[0].Children | ForEach-Object { `$_.Text }) -join '|') -eq 'Claude|22:22'
Set-ChatOverlayUsageView `$H 'lines'
`$H.Ctx.ViewSig = 'b'
Update-ChatOverlayView `$H ([pscustomobject]@{ header = [pscustomobject]@{ usage = `$use; notes = @() }; rows = @() })
`$t = @(`$H.Stack.Children | Where-Object { `$_ -is [System.Windows.Controls.TextBlock] } | ForEach-Object { `$_.Text })
`$n0 = `$H.Stack.Children.Count
`$nb = @(`$H.CtlLine.Children).Count
# not before the panel shows
`$hid = `$H.CtlWin.IsVisible
# a screen of the test's own, off every real one, with room above the
# panel for the settings box, seven rows tall, even at 200%
`$script:ChatOverlayWorkAreaSeam = { param(`$r) [pscustomobject]@{ X = -4000; Y = 0; Width = 1920; Height = 1020 } }
# shown the way the host shows them - WPF sets WS_EX_APPWINDOW again as a
# window shows - both still off every screen: the panel was never placed
# (marked placed, so un-hiding leaves it there). The bar with the panel:
# gone to the tray with it, back with it, and so out of a full screen's way
`$H.Placed = `$true
Set-ChatOverlayHidden `$H `$true
`$withPanel = -not `$H.CtlWin.IsVisible -and -not `$H.ControlsShown
Set-ChatOverlayHidden `$H `$false
`$withPanel = `$withPanel -and `$H.CtlWin.IsVisible -and `$H.ControlsShown
`$script:ChatOverlayFullScreenSeam = { `$true }
Update-ChatOverlayFullScreen `$H
`$withPanel = `$withPanel -and `$H.FullHidden -and -not `$H.Win.IsVisible -and -not `$H.CtlWin.IsVisible
`$script:ChatOverlayFullScreenSeam = { `$false }
Update-ChatOverlayFullScreen `$H
`$withPanel = `$withPanel -and -not `$H.FullHidden -and `$H.Win.IsVisible -and `$H.CtlWin.IsVisible
`$script:ChatOverlayFullScreenSeam = `$null
# moved, the bar follows of itself (the panel's LocationChanged)
[ChatOverlayNative]::MoveTo(`$H.Hwnd, -2594, 400)
`$ex = [ChatOverlayNative]::GetExStyle(`$H.Hwnd)
`$cex = [ChatOverlayNative]::GetExStyle(`$H.CtlHwnd)
`$pr = [ChatOverlayNative]::GetRect(`$H.Hwnd)
`$cr = [ChatOverlayNative]::GetRect(`$H.CtlHwnd)
# WPF units in this screen's pixels
`$u = { param(`$v) [int][Math]::Round(`$v * (Get-ChatOverlayScale `$H `$pr -Device)) }
# the pointer check counts the bar's window
`$zh = Get-ChatOverlayControlsHoverZone (Get-ChatOverlayControlsTarget `$H)
`$zoneOk = `$zh -and (`$zh -join ',') -eq (`$cr -join ',')
# in the panel's top strip, 4 under its top edge and 8 in from its right, as
# wide as the panel less 8 each side - and put pass after pass, as the
# pointer check places it every 120 ms
Set-ChatOverlayControlsPlacement `$H
Set-ChatOverlayControlsPlacement `$H
`$cr2 = [ChatOverlayNative]::GetRect(`$H.CtlHwnd)
`$beside = [Math]::Abs(`$cr[1] - (`$pr[1] + (& `$u 4))) -le 1 -and [Math]::Abs((`$cr[0] + `$cr[2]) - (`$pr[0] + `$pr[2] - (& `$u 8))) -le 1 -and
    `$H.Controls.Width -eq (`$H.Win.Width - 16) -and [Math]::Abs(`$cr[2] - (& `$u (`$H.Win.Width - 16))) -le 1 -and `$cr2[0] -eq `$cr[0] -and `$cr2[1] -eq `$cr[1]
# the rows start under it, 2 units clear: the frame's top padding
`$H.Win.UpdateLayout()
`$ky = `$H.Stack.Children[0].TransformToAncestor(`$H.Win).Transform([System.Windows.Point]::new(0, 0)).Y
`$clear = `$ky -ge 26 -and `$ky -lt 30 -and (`$cr[1] + `$cr[3]) -le (`$pr[1] + (& `$u `$ky))
# wider and back: the bar follows of itself (the panel's SizeChanged), its
# right end 8 in
Set-ChatOverlayWidth `$H 460
`$H.Win.UpdateLayout()
`$H.CtlWin.UpdateLayout()
`$pw = [ChatOverlayNative]::GetRect(`$H.Hwnd)
`$cwd = [ChatOverlayNative]::GetRect(`$H.CtlHwnd)
`$follows = `$H.Controls.Width -eq 444 -and [Math]::Abs(`$cwd[2] - (& `$u 444)) -le 1 -and [Math]::Abs((`$cwd[0] + `$cwd[2]) - (`$pw[0] + `$pw[2] - (& `$u 8))) -le 1
Set-ChatOverlayWidth `$H 380
`$H.Win.UpdateLayout()
`$H.CtlWin.UpdateLayout()
`$follows = `$follows -and `$H.Controls.Width -eq 364 -and (([ChatOverlayNative]::GetRect(`$H.CtlHwnd)) -join ',') -eq (`$cr -join ',')
# six buttons, collapse at the left end and close at the corner; the
# caption's three named as on any window, and none of them the grip: the
# bar's own part drags, a button's cursor the arrow
`$kids = @(`$H.CtlLine.Children)
`$first = `$kids[0].ToolTip
`$far = `$kids[-1].ToolTip
`$cur = [System.Windows.Input.Cursors]
`$order = (@(`$kids | ForEach-Object { ([string]`$_.ToolTip -split ' ')[0] }) -join ',') -eq 'Collapse,Ask,Settings,Minimize,Maximize:,Close' -and
    `$kids[3].ToolTip -eq 'Minimize to the tray - click the tray icon to show it' -and
    `$kids[4].ToolTip -eq 'Maximize: the console, in the panel''s place - write to a chat, queue, continue; Esc brings the panel back' -and
    `$H.Controls.ToolTip -like 'Drag to move - drag an edge or corner*' -and `$H.Controls.Cursor -eq `$cur::SizeAll -and
    -not @(`$kids | Where-Object { `$_.Cursor -ne `$cur::Arrow }).Count -and `$H.CtlLine.HorizontalAlignment -eq 'Right'
# a short line, a square and a cross, each 8 units across
`$gm = `$kids[3].Child.Data.Bounds
`$gx = `$kids[4].Child.Data.Bounds
`$glyphs = `$gm.Width -eq 8 -and `$gm.Height -eq 0 -and `$gx.Width -eq 8 -and `$gx.Height -eq 8 -and `$kids[5].Child.Data.Bounds.Width -eq 8
# a click's args of its own each time: the handler marks them Handled.
# Minimize hides to the tray, maximize opens the console - the verbs taken
# down in place of being done
`$click = { param(`$el, `$ev) `$a = [System.Windows.Input.MouseButtonEventArgs]::new([System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]::Left); `$a.RoutedEvent = `$ev; `$el.RaiseEvent(`$a) }
`$script:verbs = [System.Collections.Generic.List[string]]::new()
`$verbFn = `${function:Invoke-ChatOverlayVerb}
`${function:Invoke-ChatOverlayVerb} = { param(`$v) `$script:verbs.Add(`$v) }
try {
    & `$click `$kids[3] ([System.Windows.UIElement]::MouseLeftButtonUpEvent)
    & `$click `$kids[4] ([System.Windows.UIElement]::MouseLeftButtonUpEvent)
}
finally { `${function:Invoke-ChatOverlayVerb} = `$verbFn }
`$clicks = (`$script:verbs -join ',') -eq 'hide,console'
# a press on the bar drags the panel; one on a button is the button's, and
# never reaches the bar. The drag's start taken down, not run: it would
# take the mouse
`$script:from = [System.Collections.Generic.List[object]]::new()
`$gripFn = `${function:Start-ChatOverlayGripDrag}
`${function:Start-ChatOverlayGripDrag} = { param(`$g) `$script:from.Add(`$g) }
try {
    foreach (`$b in `$kids) { & `$click `$b ([System.Windows.Input.Mouse]::MouseDownEvent) }
    `$onButtons = `$script:from.Count
    & `$click `$H.Controls ([System.Windows.Input.Mouse]::MouseDownEvent)
}
finally { `${function:Start-ChatOverlayGripDrag} = `$gripFn }
`$dragOk = `$onButtons -eq 0 -and `$script:from.Count -eq 1 -and `$script:from[0] -eq `$H.Controls
# the settings box: above the panel, its foot 4 over the panel's top edge,
# the bar where it was - and the pointer check counts the box too
Set-ChatOverlaySettingsOpen `$H `$true
`$H.CtlWin.UpdateLayout()
`$cw = [ChatOverlayNative]::GetRect(`$H.CtlHwnd)
`$boxFoot = `$cw[1] + (& `$u `$H.Settings.ActualHeight)
`$grew = `$H.CtlSide -eq 'above' -and `$H.CtlStack.Children[1] -eq `$H.Controls -and `$cw[3] -gt `$cr[3] -and
    [Math]::Abs((`$cw[1] + `$cw[3]) - (`$cr[1] + `$cr[3])) -le 1 -and [Math]::Abs((`$cw[0] + `$cw[2]) - (`$cr[0] + `$cr[2])) -le 1 -and
    [Math]::Abs(`$boxFoot - (`$pr[1] - (& `$u 4))) -le 2
`$zo = Get-ChatOverlayControlsHoverZone (Get-ChatOverlayControlsTarget `$H)
`$zoneOk = `$zoneOk -and `$zo -and [Math]::Abs(`$zo[1] - `$cw[1]) -le 1 -and [Math]::Abs(`$zo[3] - `$cw[3]) -le 1
# the refresh icon turns while an ask is out, and stops when none is
`$H.Ctx.Fetch = @{ Task = [System.Threading.Tasks.TaskCompletionSource[int]]::new().Task }
Update-ChatOverlaySpin `$H
`$turning = `$H.Spinning
`$H.Ctx.Fetch = `$null
Update-ChatOverlaySpin `$H
`$spun = `$turning -and -not `$H.Spinning
`$H.Ctx.Config.theme = 'light'
Update-ChatOverlayTheme `$H
`$still = (`$H.Settings.Visibility -eq 'Visible') -and (`$H.CtlStack.Children.Count -eq 2)
# the slider itself, then the pass that saves what it rested on
`$slider = @(`$H.Settings.Child.Children | Where-Object { `$_ -is [System.Windows.Controls.Slider] })[0]
`$slider.Value = 0.5
`$moved = `$H.Win.Opacity -eq 0.5 -and `$H.PendingOpacity -eq 0.5
`$H.PendingAt = (Get-Date).AddSeconds(-2)
Update-ChatOverlayHover
`$kept = `$moved -and `$null -eq `$H.PendingOpacity -and (Get-ChatOverlayConfig).opacity -eq 0.5
# the panel's opacity on the buttons alone: never on the bar, whose alpha of
# 1 would go to 0 and let the mouse through, nor its window or the box
`$solid = { `$H.Controls.Opacity -eq 1 -and `$H.CtlWin.Opacity -eq 1 -and `$H.CtlStack.Opacity -eq 1 -and `$H.Settings.Opacity -eq 1 -and `$H.Controls.Background.Color.A -eq 1 }
`$dim = `$H.CtlLine.Opacity -eq 0.5 -and (& `$solid)
# Open, the box keeps its side while it fits there: at the screen's top,
# under the bar over the rows, the bar where it was; dragged down, still
# under it; shut and opened again, above. Laid out as the box opens or
# shuts, as the host's own dispatcher would: this process pumps none.
Set-ChatOverlaySettingsOpen `$H `$false
`$H.CtlWin.UpdateLayout()
[ChatOverlayNative]::MoveTo(`$H.Hwnd, -2594, 6)
Set-ChatOverlaySettingsOpen `$H `$true
`$H.CtlWin.UpdateLayout()
`$s1 = `$H.CtlSide
`$pt = [ChatOverlayNative]::GetRect(`$H.Hwnd)
`$ct = [ChatOverlayNative]::GetRect(`$H.CtlHwnd)
`$under = [Math]::Abs(`$ct[1] - (`$pt[1] + (& `$u 4))) -le 1 -and `$H.CtlStack.Children[0] -eq `$H.Controls -and `$ct[3] -gt `$cr[3]
[ChatOverlayNative]::MoveTo(`$H.Hwnd, -2594, 400)
Set-ChatOverlayControlsPlacement `$H
`$s2 = `$H.CtlSide
`$pd = [ChatOverlayNative]::GetRect(`$H.Hwnd)
`$cd = [ChatOverlayNative]::GetRect(`$H.CtlHwnd)
`$under = `$under -and [Math]::Abs(`$cd[1] - (`$pd[1] + (& `$u 4))) -le 1
# shut by the pointer check, the pointer gone from it - not while a button
# is held, a slider dragged off the box: the bar placed for no box, not
# where it went with the box open under it
`$H.BoxOverAt = (Get-Date).AddSeconds(-2)
`$script:ChatOverlayMouseDownSeam = { `$true }
Update-ChatOverlayHover
`$heldOpen = `$H.SettingsOpen
`$script:ChatOverlayMouseDownSeam = { `$false }
Update-ChatOverlayHover
`$shut = `$heldOpen -and -not `$H.SettingsOpen -and `$H.CtlSide -eq 'above' -and `$H.CtlStack.Children[1] -eq `$H.Controls
Set-ChatOverlaySettingsOpen `$H `$false
`$H.CtlWin.UpdateLayout()
Set-ChatOverlaySettingsOpen `$H `$true
`$H.CtlWin.UpdateLayout()
`$s3 = `$H.CtlSide
`$cb = [ChatOverlayNative]::GetRect(`$H.CtlHwnd)
`$back = `$s1 -eq 'below' -and `$s2 -eq 'below' -and `$under -and `$shut -and `$s3 -eq 'above' -and [Math]::Abs((`$cb[1] + `$cb[3]) - (`$cr[1] + `$cr[3])) -le 1
Set-ChatOverlayCollapsed `$H `$true
`$one = @(`$H.Stack.Children[0].Children | Where-Object { `$_ -is [System.Windows.Controls.TextBlock] } | ForEach-Object { `$_.Text }) -join '/'
# the buttons made anew for the fold: dimmed as before, the bar not
`$dim = `$dim -and `$H.CtlLine.Opacity -eq 0.5 -and (& `$solid)
'{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}|{10}|{11}|{12}|{13}|{14}|{15}|{16}|{17}|{18}|{19}|{20}|{21}|{22}|{23}|{24}|{25}|{26}|{27}|{28}|{29}|{30}|{31}' -f `$n10, `$more, `$n0, (`$t -contains 'no chats open'), `$ex,
    `$nb, `$hid, `$H.Frame.Background.Color, `$still, `$kept,
    `$cex, `$H.Stack.Children.Count, `$one, `$H.CtlButtons[0].ToolTip, `$first,
    `$beside, `$grew, `$far, `$spun, `$lineOk, `$barsOk, [bool]`$zoneOk, [bool]`$back,
    `$order, `$glyphs, `$clicks, `$dragOk, `$withPanel, `$follows, `$clear, `$dim,
    "zone `$(`$zh -join ',') panel `$(`$pr -join ',') ctl `$(`$cr -join ',') then `$(`$cr2 -join ',') top `$ky wider `$(`$cwd -join ',') of `$(`$pw -join ',') box `$(`$cw -join ',') foot `$boxFoot sides `$s1 `$s2 `$s3 shut `$shut top `$(`$pt -join ',') ctl `$(`$ct -join ',') dragged `$(`$pd -join ',') ctl `$(`$cd -join ',') back `$(`$cb -join ',') verbs `$(`$script:verbs -join ',') from `$(`$script:from.Count)/`$onButtons"
"@
$wpfOut = Invoke-Sta 'panel-test' $wpf
$wp = "$wpfOut" -split '\|'
$ex = if ($wp.Count -ge 5) { [int64]$wp[4] } else { 0 }
Check 'the panel: 8 rows and "+2 more", or one line when nothing is open' ($wp[0] -eq '11' -and $wp[1] -eq 'True' -and $wp[2] -eq '3' -and $wp[3] -eq 'True') "$wpfOut"
Check 'shown, a tool window that never activates and lets clicks through, and no taskbar button' ((($ex -band 0x80800A0) -eq 0x80800A0) -and -not ($ex -band 0x40000)) ('0x{0:X}' -f $ex)
$cex = if ($wp.Count -ge 11) { [int64]$wp[10] } else { 0 }
Check 'six in a window of their own - minimize and maximize among them - not shown before the panel is' ($wp[5] -eq '6' -and $wp[6] -eq 'False') "$wpfOut"
Check 'that window, shown, takes clicks but never focus, and has no taskbar button' ((($cex -band 0x8080080) -eq 0x8080080) -and -not ($cex -band 0x20) -and -not ($cex -band 0x40000)) ('0x{0:X}' -f $cex)
Check 'collapse at the left end, close at the corner' ($wp[14] -like 'Collapse*' -and $wp[17] -like 'Close*') "$wpfOut"
Check 'left to right: collapse, refresh, settings, minimize, maximize, close - the last three named as on any window, no grip, the arrow on each' ($wp[23] -eq 'True') "$wpfOut"
Check 'minimize a short line, maximize a square, close a cross, each 8 units across' ($wp[24] -eq 'True') "$wpfOut"
Check 'minimize hides the panel to the tray, maximize opens the console in its place' ($wp[25] -eq 'True') "$wpfOut"
Check 'a press on the bar off its buttons drags the panel; a press on a button never does' ($wp[26] -eq 'True') "$wpfOut"
Check 'the bar of buttons sits in the panel''s top strip, 4 under its top and 8 in from its right, as wide as the panel less 16, put pass after pass' ($wp[15] -eq 'True') "$wpfOut"
Check 'the bar shows with the panel and goes with it: to the tray and back, out of a full screen''s way and back' ($wp[27] -eq 'True') "$wpfOut"
Check 'the bar follows the panel''s width of itself, its right end 8 in' ($wp[28] -eq 'True') "$wpfOut"
Check 'the panel''s rows start under the bar, 2 units clear of it' ($wp[29] -eq 'True') "$wpfOut"
Check 'the panel''s opacity dims the buttons alone - never the bar, its window or the settings box - and again once they are made anew' ($wp[30] -eq 'True') "$wpfOut"
Check 'the settings box opens above the panel, its foot 4 over the panel''s top edge, the bar where it was' ($wp[16] -eq 'True') "$wpfOut"
Check 'the pointer check counts the buttons'' window, an open box and its gap to the panel in it' ($wp[21] -eq 'True') "$wpfOut"
Check 'the box keeps its side while open: under the bar at the screen''s top, still there dragged down, kept open by the pointer check while a button is held, the bar placed for no box once it shuts it, above once opened again' ($wp[22] -eq 'True') "$wpfOut"
Check 'the refresh icon turns while Claude is being asked' ($wp[18] -eq 'True') "$wpfOut"
Check 'usage drawn as a line - name, the windows, when it is from - and as bars, with the time under the name, once the settings box says so' ($wp[19] -eq 'True' -and $wp[20] -eq 'True') "$wpfOut"
Check 'the light theme redraws the frame and keeps the settings box open' ($wp[7] -eq '#F2FAFAFB' -and $wp[8] -eq 'True') "$wpfOut"
Check 'the opacity slider sets the panel''s, and config.json gets it once it rests' ($wp[9] -eq 'True') "$wpfOut"
Check 'collapsed: one line of counts and usage, and the chevron offers to expand' ($wp[11] -eq '1' -and $wp[12] -eq ('5h 42%/no chats open') -and $wp[13] -eq 'Expand') "$wpfOut"

# the tray icon: Charlie with the state's dot, drawn into a NotifyIcon never
# made visible; then the icon unreadable, the dot alone as before
$wpfTray = @"
$staLoad
Initialize-ChatOverlayNative
`$H = New-ChatOverlayHostState
`$H.Tray = [System.Windows.Forms.NotifyIcon]::new()
`$px = { param(`$x, `$y) `$b = `$H.Tray.Icon.ToBitmap(); try { `$b.GetPixel(`$x, `$y) } finally { `$b.Dispose() } }
Set-ChatOverlayTrayColor `$H '#FF0000'
`$n = `$H.Tray.Icon.Width
`$h1 = `$H.IconHandle
`$dot = & `$px (`$n - [Math]::Round(`$n / 4)) (`$n - [Math]::Round(`$n / 4))
`$top = & `$px ([int](`$n / 3)) ([int](`$n / 4))
Set-ChatOverlayTrayColor `$H '#FF0000'
`$same = `$H.IconHandle -eq `$h1
Set-ChatOverlayTrayColor `$H '#00FF00'
`$green = & `$px (`$n - [Math]::Round(`$n / 4)) (`$n - [Math]::Round(`$n / 4))
`$face = Get-ChatIconSource
`$script:ChatIconPng = 'not an image'
`$script:ChatIconBitmap = `$null
Set-ChatOverlayTrayColor `$H '#0000FF'
`$mid = & `$px ([int](`$n / 2)) ([int](`$n / 2))
`$corner = & `$px 0 0
`$long = 'Charlie: ' + ('x' * 100)
Set-ChatOverlayTrayText `$H.Tray `$long
`$longOk = `$H.Tray.Text -ceq `$long
Set-ChatOverlayTrayText `$H.Tray 'Charlie: 2 idle'
`$longOk = `$longOk -and `$H.Tray.Text -ceq 'Charlie: 2 idle'
'{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}' -f `$n, ([System.Windows.Forms.SystemInformation]::SmallIconSize.Width),
    (`$dot.R -gt 200 -and `$dot.G -lt 60 -and `$dot.A -eq 255), (`$top.A -eq 255 -and -not (`$top.R -gt 200 -and `$top.G -lt 60)),
    (`$same -and `$H.IconHandle -ne `$h1 -and `$green.G -gt 200 -and `$green.R -lt 60), (`$face -and `$face.PixelWidth -eq 48),
    (`$mid.B -gt 200 -and `$mid.A -eq 255), (`$corner.A -eq 0), `$longOk
`$H.Tray.Dispose()
"@
$trayOut = Invoke-Sta 'tray-icon-test' $wpfTray
$tr = "$trayOut" -split '\|'
Check 'the tray icon is Charlie, at the small-icon size, with the state''s colour in a dot at her bottom right' (
    $tr.Count -ge 8 -and $tr[0] -eq ([Math]::Min(64, [Math]::Max(16, [int]$tr[1]))) -and $tr[2] -eq 'True' -and $tr[3] -eq 'True') "$trayOut"
Check 'the same colour draws nothing again, another draws anew; the windows get Charlie at 48 px' ($tr[4] -eq 'True' -and $tr[5] -eq 'True') "$trayOut"
Check 'with the icon unreadable, the tray is the dot alone, as it was' ($tr[6] -eq 'True' -and $tr[7] -eq 'True') "$trayOut"
Check 'a tooltip past .NET Framework''s 63 characters is taken whole, and a short one after it' ($tr[8] -eq 'True') "$trayOut"

# its size: the resize handle, the width and rows sliders, a screen too short
# for the rows, and a reload - shown off every screen, the pointer never
# read: the drag is handed where it is (-At). config.json put back after.
$wpfSize = @"
$staLoad
# no mouse button held and the pointer far off, whatever the real mouse's
`$script:ChatOverlayMouseDownSeam = { `$false }
`$script:ChatOverlayPointerSeam = { [System.Drawing.Point]::new(-100000, -100000) }
`$cfgWas = [IO.File]::ReadAllText(`$script:ChatqConfigPath)
Set-ChatOverlayConfig @{ width = 380; maxRows = 8; hotkey = 'none'; consoleHotkey = 'none' }
Initialize-ChatOverlayNative
$staPanel
`$rows = @(1..12 | ForEach-Object { [pscustomobject]@{ key = "s:`$_"; kind = 'session'; status = 'idle'; rank = 3; project = 'p'; title = "chat `$_"; prompt = 'x'; stateText = 'idle 1m'; job = `$null } })
`$snap = [pscustomobject]@{ header = [pscustomobject]@{ usage = @(); notes = @() }; rows = `$rows }
`$H.Ctx.ViewSig = 'a'
`$H.Placed = `$true
`$tall = 1020
`$script:ChatOverlayWorkAreaSeam = { param(`$r) [pscustomobject]@{ X = -4000; Y = 0; Width = 1920; Height = `$tall } }
Set-ChatOverlayHidden `$H `$false
[ChatOverlayNative]::MoveTo(`$H.Hwnd, -2594, 197)
Update-ChatOverlayView `$H `$snap
`$H.Win.UpdateLayout()
`$more = { @(`$H.Stack.Children | Where-Object { `$_ -is [System.Windows.Controls.TextBlock] -and `$_.Text -like '+* more*' } | ForEach-Object { `$_.Text }) -join '' }
`$right = { `$r = [ChatOverlayNative]::GetRect(`$H.Hwnd); `$r[0] + `$r[2] }
# no handle and no grip: collapse first, six in all, the bar itself
# naming the edges
`$handle = `$H.CtlLine.Children.Count -eq 6 -and `$H.CtlLine.Children[0] -eq `$H.CtlButtons[0] -and `$H.CtlButtons[0].ToolTip -eq 'Collapse to one line' -and
    `$H.Controls.ToolTip -like 'Drag to move - drag an edge or corner*' -and -not @(`$H.CtlButtons | Where-Object { [string]`$_.ToolTip -like 'Drag*' }).Count -and
    `$H.CtlButtons[2].ToolTip -eq 'Settings - size, rows, opacity, theme, usage, compact rows, recent chats, cut-off chats' -and
    `$H.CtlButtons[5].ToolTip -like 'Close the overlay - it stays closed until you next sign in*'
# the edges: shown with the pointer, over the panel's rect and 4 units
# round it, taking clicks but never focus, a cursor each, all but
# invisible; folded, no top or bottom and the corners sideways; the line
# along the sides an edge sizes; gone with the pointer, the bar kept
Show-ChatOverlayEdges `$H `$true
`$ep = [ChatOverlayNative]::GetRect(`$H.Hwnd)
`$eOut = [int][Math]::Round(4 * (Get-ChatOverlayScale `$H `$ep -Device))
`$eRect = [ChatOverlayNative]::GetRect(`$H.EdgesHwnd)
`$eex = [ChatOverlayNative]::GetExStyle(`$H.EdgesHwnd)
`$cur = [System.Windows.Input.Cursors]
`$ec = { param(`$s) `$H.EdgeParts[`$s].Cursor }
`$edges = `$H.EdgesWin.IsVisible -and (`$eRect -join ',') -eq ((Get-ChatOverlayEdgesRect `$ep `$eOut) -join ',') -and
    ((`$eex -band 0x8080080) -eq 0x8080080) -and -not (`$eex -band 0x20) -and -not (`$eex -band 0x40000) -and @(`$H.EdgeParts.Keys).Count -eq 8 -and
    (& `$ec 'n') -eq `$cur::SizeNS -and (& `$ec 'w') -eq `$cur::SizeWE -and (& `$ec 'ne') -eq `$cur::SizeNESW -and (& `$ec 'se') -eq `$cur::SizeNWSE -and
    `$H.EdgeParts['s'].Background.Color.A -eq 1
Show-ChatOverlayEdgeHint `$H 'ne'
`$t1 = `$H.EdgesHint.BorderThickness
Show-ChatOverlayEdgeHint `$H ''
`$edges = `$edges -and `$t1.Top -eq 2 -and `$t1.Right -eq 2 -and `$t1.Left -eq 0 -and `$t1.Bottom -eq 0 -and `$H.EdgesHint.Visibility -eq 'Hidden'
Set-ChatOverlayCollapsed `$H `$true
Show-ChatOverlayEdgeHint `$H 'ne'
`$edges = `$edges -and `$H.EdgeParts['n'].Visibility -eq 'Collapsed' -and `$H.EdgeParts['s'].Visibility -eq 'Collapsed' -and `$H.EdgeParts['w'].Visibility -eq 'Visible' -and
    (& `$ec 'ne') -eq `$cur::SizeWE -and `$H.EdgesHint.BorderThickness.Top -eq 0 -and `$H.EdgesHint.BorderThickness.Right -eq 2
Set-ChatOverlayCollapsed `$H `$false
`$edges = `$edges -and `$H.EdgeParts['n'].Visibility -eq 'Visible' -and (& `$ec 'ne') -eq `$cur::SizeNESW
Show-ChatOverlayEdges `$H `$false
`$edges = `$edges -and -not `$H.EdgesWin.IsVisible -and `$H.EdgesHint.Visibility -eq 'Hidden' -and `$H.CtlWin.IsVisible
# the sliders: whole numbers, their values beside them
Set-ChatOverlaySettingsOpen `$H `$true
`$sl = @(`$H.Settings.Child.Children | Where-Object { `$_ -is [System.Windows.Controls.Slider] })
`$sw = @(`$sl | Where-Object { `$_.Tag -eq 'width' })[0]
`$sr = @(`$sl | Where-Object { `$_.Tag -eq 'rows' })[0]
`$sliders = `$sl.Count -eq 3 -and `$sw.Minimum -eq 260 -and `$sw.Maximum -eq 800 -and `$sw.Value -eq 380 -and `$sr.Minimum -eq 1 -and `$sr.Maximum -eq 30 -and `$sr.Value -eq 8 -and
    `$sw.IsSnapToTickEnabled -and `$sw.TickFrequency -eq 1 -and `$H.WidthText.Text -eq '380' -and `$H.RowsText.Text -eq '8'
`$e0 = & `$right
`$sw.Value = 460.4
`$wide = `$H.Win.Width -eq 460 -and (& `$right) -eq `$e0 -and `$H.WidthText.Text -eq '460' -and `$H.PendingWidth -eq 460
`$sr.Value = 4.6
`$H.Win.UpdateLayout()
`$fewer = `$sr.IsSnapToTickEnabled -and (Get-ChatOverlayDrawnRows `$H) -eq 5 -and (& `$more) -like '+7 more*' -and `$H.RowsText.Text -eq '5' -and `$H.PendingRows -eq 5
`$H.PendingAt = (Get-Date).AddSeconds(-2)
Update-ChatOverlayHover
`$c1 = Get-ChatOverlayConfig
`$rested = `$c1.width -eq 460 -and `$c1.maxRows -eq 5 -and `$null -eq `$H.PendingWidth -and `$null -eq `$H.PendingRows
# the handle dragged left 40 units and down two and a half rows
`$H.Win.UpdateLayout()
`$e1 = & `$right
`$o = [System.Drawing.Point]::new(100, 100)
Start-ChatOverlaySizeDrag `$null `$o
`$d = `$H.SizeDrag
`$held = `$H.Dragging -and `$d.RowPx -gt 0
Move-ChatOverlaySizeDrag ([System.Drawing.Point]::new(100 - [int][Math]::Round(40 * `$d.Px), 100 + [int](2.5 * `$d.RowPx)))
`$H.Win.UpdateLayout()
`$midW = `$H.Win.Width
`$midN = Get-ChatOverlayDrawnRows `$H
`$midE = & `$right
Stop-ChatOverlaySizeDrag `$null
`$c2 = Get-ChatOverlayConfig
`$st = Read-ChatOverlayState
`$pr = [ChatOverlayNative]::GetRect(`$H.Hwnd)
`$dragged = `$held -and `$midW -eq 500 -and `$midN -eq 7 -and `$midE -eq `$e1 -and -not `$H.Dragging -and `$c2.width -eq 500 -and `$c2.maxRows -eq 7 -and
    `$st.x -eq `$pr[0] -and `$st.y -eq `$pr[1]
# collapsed: width only
Set-ChatOverlayCollapsed `$H `$true
Start-ChatOverlaySizeDrag `$null `$o
Move-ChatOverlaySizeDrag ([System.Drawing.Point]::new(100 + [int][Math]::Round(20 * `$H.SizeDrag.Px), 900))
Stop-ChatOverlaySizeDrag `$null
`$c3 = Get-ChatOverlayConfig
`$folded = `$c3.width -eq 480 -and `$c3.maxRows -eq 7
Set-ChatOverlayCollapsed `$H `$false
# a screen 500 pixels tall: never past its foot, from the top edge (197)
`$tall = 500
Set-ChatOverlayRowCount `$H 30
`$H.Win.UpdateLayout()
`$px = Get-ChatOverlayScale `$H ([ChatOverlayNative]::GetRect(`$H.Hwnd)) -Device
`$n = Get-ChatOverlayDrawnRows `$H
`$cut = `$H.Win.MaxHeight -eq [Math]::Floor(303 / `$px) -and `$n -ge 1 -and `$n -lt 12 -and (& `$more) -like "+`$(12 - `$n) more*" -and `$H.Win.ActualHeight -le `$H.Win.MaxHeight
# a shell's chatoverlay -Width -Rows: reload, the right edge held
`$tall = 1020
Set-ChatOverlayConfig @{ width = 420; maxRows = 4 }
`$e2 = & `$right
Invoke-ChatOverlayVerb 'reload'
`$H.Win.UpdateLayout()
`$reload = `$H.Win.Width -eq 420 -and (& `$right) -eq `$e2 -and (Get-ChatOverlayDrawnRows `$H) -eq 4
# the width slider at rest: where the panel's left edge went is kept too
`$H.WidthSlider.Value = 520
`$H.PendingAt = (Get-Date).AddSeconds(-2)
Update-ChatOverlayHover
`$st3 = Read-ChatOverlayState
`$pr3 = [ChatOverlayNative]::GetRect(`$H.Hwnd)
`$restPlace = (Get-ChatOverlayConfig).width -eq 520 -and `$st3.x -eq `$pr3[0] -and `$st3.y -eq `$pr3[1]
# a reload with the slider still moving: written first, the shell's other setting kept too
`$H.WidthSlider.Value = 440
Set-ChatOverlayConfig @{ maxRows = 6 }
Invoke-ChatOverlayVerb 'reload'
`$c4 = Get-ChatOverlayConfig
`$st4 = Read-ChatOverlayState
`$pr4 = [ChatOverlayNative]::GetRect(`$H.Hwnd)
`$pendReload = `$c4.width -eq 440 -and `$c4.maxRows -eq 6 -and `$H.Win.Width -eq 440 -and `$null -eq `$H.PendingWidth -and
    `$H.WidthSlider.Value -eq 440 -and `$st4.x -eq `$pr4[0]
# by the screen's left edge: held there, it grows to the right
[ChatOverlayNative]::MoveTo(`$H.Hwnd, -3990, 197)
`$H.WidthSlider.Value = 600
`$pl = [ChatOverlayNative]::GetRect(`$H.Hwnd)
`$edgeHeld = `$H.Win.Width -eq 600 -and `$pl[0] -eq -4000 -and (`$pl[0] + `$pl[2]) -gt (-3990 + [int][Math]::Round(440 * `$d.Px))
`$H.PendingAt = (Get-Date).AddSeconds(-2)
Update-ChatOverlayHover
`$edgeHeld = `$edgeHeld -and (Read-ChatOverlayState).x -eq -4000
[ChatOverlayNative]::MoveTo(`$H.Hwnd, -2594, 197)
Save-ChatOverlayPlace `$H
# three chats and 8 rows: a row's travel down keeps 8, not the 4 counted
# from the 3 drawn; up takes one off the 3
Set-ChatOverlayConfig @{ maxRows = 8 }
`$H.Ctx.Config = Get-ChatOverlayConfig
`$snap3 = [pscustomobject]@{ header = [pscustomobject]@{ usage = @(); notes = @() }; rows = @(`$rows | Select-Object -First 3) }
`$H.Ctx.ViewSig = 'three'
Update-ChatOverlayView `$H `$snap3
`$H.Win.UpdateLayout()
Start-ChatOverlaySizeDrag `$null `$o
Move-ChatOverlaySizeDrag ([System.Drawing.Point]::new(100, 100 + [int](1.5 * `$H.SizeDrag.RowPx)))
Stop-ChatOverlaySizeDrag `$null
`$down8 = (Get-ChatOverlayConfig).maxRows
Start-ChatOverlaySizeDrag `$null `$o
Move-ChatOverlaySizeDrag ([System.Drawing.Point]::new(100, 100 - [int](1.5 * `$H.SizeDrag.RowPx)))
Stop-ChatOverlaySizeDrag `$null
`$up2 = (Get-ChatOverlayConfig).maxRows
`$fewDrag = `$down8 -eq 8 -and `$up2 -eq 2
# dragged with the box shut: opened, it shows what was dragged to, and a
# nudge moves on from there
Set-ChatOverlayConfig @{ maxRows = 8 }
`$H.Ctx.Config = Get-ChatOverlayConfig
`$H.Ctx.ViewSig = 'twelve'
Update-ChatOverlayView `$H `$snap
`$H.Win.UpdateLayout()
Set-ChatOverlaySettingsOpen `$H `$false
Start-ChatOverlaySizeDrag `$null `$o
Move-ChatOverlaySizeDrag ([System.Drawing.Point]::new(100 - [int][Math]::Round(40 * `$H.SizeDrag.Px), 100 + [int](1.5 * `$H.SizeDrag.RowPx)))
Stop-ChatOverlaySizeDrag `$null
`$wD = [int]`$H.Win.Width
`$nD = [int](Get-ChatOverlayConfig).maxRows
Set-ChatOverlaySettingsOpen `$H `$true
`$synced = `$H.WidthSlider.Value -eq `$wD -and `$H.WidthText.Text -eq "`$wD" -and `$H.RowsSlider.Value -eq `$nD -and `$H.RowsText.Text -eq "`$nD" -and
    `$null -eq `$H.PendingWidth -and `$null -eq `$H.PendingRows -and `$nD -eq 9
`$H.WidthSlider.Value = `$wD + 1
# within a unit: at 125% WPF sizes the window to whole pixels, and says so
`$synced = `$synced -and [Math]::Abs(`$H.Win.Width - (`$wD + 1)) -lt 1 -and `$H.PendingWidth -eq (`$wD + 1)
`$H.PendingAt = (Get-Date).AddSeconds(-2)
Update-ChatOverlayHover
# the settings box: width and rows share a row, and no row is tall, so it
# goes under a panel at the top of the screen; Style full or compact
`$H.Settings.Measure([System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
`$boxH = `$H.Settings.DesiredSize.Height
`$chipsOf = { param(`$t) @(`$H.Settings.Child.Children | Where-Object { `$_ -is [System.Windows.Controls.StackPanel] -and @(`$_.Children | ForEach-Object { `$_.Tag }) -contains `$t })[0] }
`$style = & `$chipsOf 'compact'
`$on = { param(`$p) @(`$p.Children | Where-Object { `$_.Background -eq (Get-ChatOverlayBrush 'accent') } | ForEach-Object { `$_.Tag }) -join ',' }
`$styleOk = `$style -and (@(`$style.Children | ForEach-Object { `$_.Tag }) -join ',') -eq 'full,compact' -and (& `$on `$style) -eq 'full' -and
    `$boxH -gt 0 -and `$boxH -le 28 * `$H.Settings.Child.RowDefinitions.Count -and [System.Windows.Controls.Grid]::GetRow(`$style) -eq 4 -and
    [System.Windows.Controls.Grid]::GetRow(`$H.WidthSlider) -eq [System.Windows.Controls.Grid]::GetRow(`$H.RowsSlider)
# compact: one line a chat, tighter; the view key alone redraws it
`$hFull = Get-ChatOverlayRowHeight `$H
Set-ChatOverlayRowStyle `$H 'compact'
`$H.Win.UpdateLayout()
`$drawn = @(`$H.Stack.Children | Where-Object { `$_.Tag -and `$_.Tag -isnot [string] })
`$hComp = Get-ChatOverlayRowHeight `$H
`$compact = -not (Get-ChatOverlayConfig).prompts -and `$drawn.Count -eq [int]`$H.Ctx.Config.maxRows -and -not @(`$drawn | Where-Object { `$_.Children.Count -ne 1 -or `$_.Margin.Top -ne 1 }).Count -and
    `$hComp -lt `$hFull -and (& `$on (& `$chipsOf 'compact')) -eq 'compact'
Set-ChatOverlayRowStyle `$H 'full'
`$compact = `$compact -and (Get-ChatOverlayConfig).prompts -and @(`$H.Stack.Children | Where-Object { `$_.Tag -and `$_.Tag -isnot [string] -and `$_.Children.Count -eq 2 }).Count -eq [int]`$H.Ctx.Config.maxRows
# where each chat runs, after its dot: VS Code, a terminal, a queued
# prompt's run, none known; a job has no mark, whatever it carries
`$wr = @(
    [pscustomobject]@{ key = 's:v'; kind = 'session'; status = 'idle'; rank = 3; project = 'p'; title = 'in vs code'; prompt = 'x'; stateText = 'idle'; job = `$null; where = 'vscode' }
    [pscustomobject]@{ key = 's:t'; kind = 'session'; status = 'idle'; rank = 3; project = 'p'; title = 'in a terminal'; prompt = 'x'; stateText = 'idle'; job = `$null; where = 'terminal' }
    [pscustomobject]@{ key = 's:r'; kind = 'session'; status = 'busy'; rank = 1; project = 'p'; title = 'a queued prompt in it'; prompt = 'x'; stateText = 'working'; job = `$null; where = 'run' }
    [pscustomobject]@{ key = 's:n'; kind = 'session'; status = 'idle'; rank = 3; project = 'p'; title = 'nowhere known'; prompt = 'x'; stateText = 'idle'; job = `$null; where = '' }
    [pscustomobject]@{ key = 'j:1'; kind = 'job'; status = 'queued'; rank = 4; project = 'p'; title = 'a job'; prompt = 'x'; stateText = '#1'; job = `$null; where = 'terminal' }
)
`$H.Ctx.ViewSig = 'where'
Update-ChatOverlayView `$H ([pscustomobject]@{ header = [pscustomobject]@{ usage = @(); notes = @() }; rows = `$wr })
`$marks = @(`$H.Stack.Children | Where-Object { `$_.Tag -and `$_.Tag -isnot [string] } | ForEach-Object {
        `$ln = `$_.Children[0]
        `$p = @(`$ln.Children | Where-Object { `$_ -is [System.Windows.Shapes.Path] })
        if (`$p.Count -eq 1 -and `$ln.Children[1] -eq `$p[0] -and `$p[0].Width -eq 10 -and `$p[0].Height -eq 9 -and `$p[0].Stroke -eq (Get-ChatOverlayBrush 'dim')) { [string]`$p[0].Tag } elseif (`$p.Count) { 'bad' } else { '-' }
    }) -join ','
`$where = `$marks -eq 'vscode,terminal,run,-,-'
# the edges dragged: the right side - wider to the right, the left edge,
# top and rows where they were; the top - a row for each row's height up,
# the bottom held, and the place kept
Set-ChatOverlayConfig @{ width = 380; maxRows = 6 }
`$H.Ctx.Config = Get-ChatOverlayConfig
Set-ChatOverlayWidth `$H 380
# room to its right for the 40 units at any scale: at 125% the panel at
# -2594 ends 39 px short of the work area's edge, and the drag is kept in it
[ChatOverlayNative]::MoveTo(`$H.Hwnd, -2800, 400)
`$H.Ctx.ViewSig = 'edges'
Update-ChatOverlayView `$H `$snap
`$H.Win.UpdateLayout()
`$q0 = [ChatOverlayNative]::GetRect(`$H.Hwnd)
Start-ChatOverlaySizeDrag `$null `$o 'e'
Move-ChatOverlaySizeDrag ([System.Drawing.Point]::new(100 + [int][Math]::Round(40 * `$H.SizeDrag.Px), 700))
Stop-ChatOverlaySizeDrag `$null
`$H.Win.UpdateLayout()
`$q1 = [ChatOverlayNative]::GetRect(`$H.Hwnd)
`$eDrag = `$H.Win.Width -eq 420 -and `$q1[0] -eq `$q0[0] -and `$q1[1] -eq `$q0[1] -and (Get-ChatOverlayConfig).width -eq 420 -and
    [int]`$H.Ctx.Config.maxRows -eq 6 -and (Get-ChatOverlayDrawnRows `$H) -eq 6
Start-ChatOverlaySizeDrag `$null `$o 'n'
Move-ChatOverlaySizeDrag ([System.Drawing.Point]::new(400, 100 - [int](2.5 * `$H.SizeDrag.RowPx)))
`$qm = [ChatOverlayNative]::GetRect(`$H.Hwnd)
`$nMid = Get-ChatOverlayDrawnRows `$H
Stop-ChatOverlaySizeDrag `$null
`$H.Win.UpdateLayout()
`$q2 = [ChatOverlayNative]::GetRect(`$H.Hwnd)
`$nDrag = `$nMid -eq 8 -and (`$qm[1] + `$qm[3]) -eq (`$q1[1] + `$q1[3]) -and `$qm[1] -lt `$q1[1] -and `$qm[0] -eq `$q1[0] -and `$H.Win.Width -eq 420 -and
    (Get-ChatOverlayConfig).maxRows -eq 8 -and (Get-ChatOverlayDrawnRows `$H) -eq 8 -and (`$q2 -join ',') -eq (`$qm -join ',') -and (Read-ChatOverlayState).y -eq `$q2[1]
# down near the foot of a screen 500 pixels tall, rows cut: the top edge
# up a row's height brings one back, the rows kept as they were and the
# bottom held - within the one unit kept clear of the foot
`$tall = 500
Set-ChatOverlayRowCount `$H 12
[ChatOverlayNative]::MoveTo(`$H.Hwnd, -2594, 197)
Sync-ChatOverlayHeightCap `$H
`$H.Win.UpdateLayout()
`$f0 = Get-ChatOverlayDrawnRows `$H
`$qf = [ChatOverlayNative]::GetRect(`$H.Hwnd)
Start-ChatOverlaySizeDrag `$null `$o 'n'
Move-ChatOverlaySizeDrag ([System.Drawing.Point]::new(100, 100 - [int](1.5 * `$H.SizeDrag.RowPx)))
Stop-ChatOverlaySizeDrag `$null
`$H.Win.UpdateLayout()
`$qg = [ChatOverlayNative]::GetRect(`$H.Hwnd)
`$fpx = Get-ChatOverlayScale `$H `$qg -Device
`$f1 = Get-ChatOverlayDrawnRows `$H
`$footDrag = `$f0 -lt 12 -and `$f1 -eq (`$f0 + 1) -and [int]`$H.Ctx.Config.maxRows -eq 12 -and `$qg[1] -lt `$qf[1] -and
    (`$qg[1] + `$qg[3]) -le (`$qf[1] + `$qf[3]) -and (`$qg[1] + `$qg[3]) -ge (`$qf[1] + `$qf[3] - [Math]::Ceiling(`$fpx) - 1) -and
    (`$qg[1] + `$qg[3]) -le 500 -and (& `$more) -like "+`$(12 - `$f1) more*"
# the room kept for that line is the line as drawn, not a guess of 18
`$moreLine = @(`$H.Stack.Children | Where-Object { `$_ -is [System.Windows.Controls.TextBlock] -and `$_.Text -like '+* more*' })[0]
`$lineH = Get-ChatOverlayLineHeight `$H
`$lineOk = `$moreLine -and `$lineH -lt 18 -and [Math]::Abs(`$lineH - `$moreLine.ActualHeight) -lt 0.5
`$tall = 1020
[IO.File]::WriteAllText(`$script:ChatqConfigPath, `$cfgWas)
'{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}|{10}|{11}|{12}|{13}|{14}|{15}|{16}|{17}|{18}|{19}|{20}' -f `$handle, `$sliders, `$wide, `$fewer, `$rested, `$dragged, `$folded, `$cut, `$reload,
    `$restPlace, `$pendReload, `$edgeHeld, `$fewDrag, `$synced, (`$styleOk -and `$compact), `$where, `$edges, (`$eDrag -and `$nDrag), `$footDrag, `$lineOk,
    "line `$lineH/`$(if (`$moreLine) { `$moreLine.ActualHeight }) e0 `$e0 e1 `$e1 mid `$midW/`$midN/`$midE rowpx `$(`$d.RowPx) px `$(`$d.Px) c2 `$(`$c2.width)/`$(`$c2.maxRows) c3 `$(`$c3.width)/`$(`$c3.maxRows) cut `$n max `$(`$H.Win.MaxHeight) h `$(`$H.Win.ActualHeight) more '`$(& `$more)' w `$(`$H.Win.Width) st3 `$(`$st3.x)/`$(`$pr3[0]) c4 `$(`$c4.width)/`$(`$c4.maxRows) edge `$(`$pl -join ',') rows `$down8/`$up2 sync `$wD/`$nD/`$(`$H.WidthSlider.Value) box `$boxH style `$([bool]`$styleOk) compact `$([bool]`$compact) h `$hFull/`$hComp marks `$marks edges `$(`$eRect -join ',') of `$(`$ep -join ',') out `$eOut e `$(`$q0 -join ',') > `$(`$q1 -join ',') n `$nMid `$(`$qm -join ',') > `$(`$q2 -join ',') foot `$f0>`$f1 `$(`$qf -join ',') > `$(`$qg -join ',')"
"@
$sizeOut = Invoke-Sta 'size-test' $wpfSize
$sz = "$sizeOut" -split '\|'
Check 'no resize handle and no grip: collapse first, six in all, the bar''s tooltip naming the edges, and the tooltips of settings and close' ($sz[0] -eq 'True') "$sizeOut"
Check 'the edges: with the pointer, over the panel and 4 units round it, taking clicks but never focus, a cursor each; folded, no top or bottom; a line along the sides one sizes' ($sz[16] -eq 'True') "$sizeOut"
Check 'the right side dragged: wider to the right, the left edge held; the top: a row a row''s height up, the bottom held, the place kept' ($sz[17] -eq 'True') "$sizeOut"
Check 'the top edge by the screen''s foot: a row the foot cut comes back for a row''s travel up, the rows kept, the bottom held but for the one unit kept clear' ($sz[18] -eq 'True') "$sizeOut"
Check 'the room kept under the rows for the "+N more" line is that line''s height as drawn, measured, not 18 units' ($sz[19] -eq 'True') "$sizeOut"
Check 'the settings box has width and rows sliders, whole numbers, their values beside them' ($sz[1] -eq 'True') "$sizeOut"
Check 'the width slider widens the panel with its right edge held; the rows slider snaps and redraws, "+N more" under them' ($sz[2] -eq 'True' -and $sz[3] -eq 'True') "$sizeOut"
Check 'config.json gets width and rows once the sliders rest' ($sz[4] -eq 'True') "$sizeOut"
Check 'the bottom-left corner dragged left and down: wider with the right edge held, rows added one a row''s height, kept on release' ($sz[5] -eq 'True') "$sizeOut"
Check 'collapsed, a corner sets the width only' ($sz[6] -eq 'True') "$sizeOut"
Check 'never past its screen''s foot, from its top edge down: rows it cannot hold are counted on the "+N more" line' ($sz[7] -eq 'True') "$sizeOut"
Check 'a reload takes width and rows from config.json, the right edge held' ($sz[8] -eq 'True') "$sizeOut"
Check 'the width slider at rest keeps where the panel''s left edge went, for the next start' ($sz[9] -eq 'True') "$sizeOut"
Check 'a reload with a slider still moving writes it first: config.json and the panel agree, the shell''s other setting kept' ($sz[10] -eq 'True') "$sizeOut"
Check 'widened by the screen''s left edge: held there, it grows to the right' ($sz[11] -eq 'True') "$sizeOut"
Check 'fewer chats than rows: dragged down, the rows kept never drop; up, one off those drawn' ($sz[12] -eq 'True') "$sizeOut"
Check 'the settings box opened after a drag shows what was dragged to, and a nudge moves on from there' ($sz[13] -eq 'True') "$sizeOut"
Check 'the settings box: width and rows on one row, Style full or compact; compact draws one line a chat, and full brings the prompts back' ($sz[14] -eq 'True') "$sizeOut"
Check 'where a chat runs, after its dot: a window for VS Code, >_ for a terminal, a play triangle for a queued prompt''s run; nothing for a job' ($sz[15] -eq 'True') "$sizeOut"

# the Recent list and the unread dot, drawn - in a process of its own, as a
# command line holds only so much of the one above
$wpfRecent = @"
$staLoad
`$cfgWas = [IO.File]::ReadAllText(`$script:ChatqConfigPath)
Set-ChatOverlayConfig @{ width = 380; maxRows = 8; prompts = `$true; recent = 5; hotkey = 'none'; consoleHotkey = 'none' }
Initialize-ChatOverlayNative
$staPanel
`$H.Placed = `$true
`$script:ChatOverlayWorkAreaSeam = { param(`$r) [pscustomobject]@{ X = -4000; Y = 0; Width = 1920; Height = 1020 } }
Set-ChatOverlayHidden `$H `$false
[ChatOverlayNative]::MoveTo(`$H.Hwnd, -2594, 197)
`$chipsOf = { param(`$t) @(`$H.Settings.Child.Children | Where-Object { `$_ -is [System.Windows.Controls.StackPanel] -and @(`$_.Children | ForEach-Object { `$_.Tag }) -contains `$t })[0] }
`$on = { param(`$p) @(`$p.Children | Where-Object { `$_.Background -eq (Get-ChatOverlayBrush 'accent') } | ForEach-Object { `$_.Tag }) -join ',' }
# the Recent list under the open rows: a faint header, then one compact line
# each that the open chip takes, left out of the rows maxRows counts; and the
# accent dot, before its state, on a row that finished a turn unseen
`$gid = { param(`$n) '0d0d0d0d-0d0d-40d0-80d0-0d0d0d0d0d0' + `$n }
`$ur = @(
    [pscustomobject]@{ key = 's:u1'; kind = 'session'; status = 'idle'; rank = 3; project = 'p'; title = 'finished unseen'; prompt = 'x'; stateText = 'idle 1m'; job = `$null; where = 'vscode'; unread = `$true }
    [pscustomobject]@{ key = 's:u2'; kind = 'session'; status = 'idle'; rank = 3; project = 'p'; title = 'seen'; prompt = 'x'; stateText = 'idle 2m'; job = `$null; where = 'vscode'; unread = `$false }
)
`$rec = @(1..3 | ForEach-Object { [pscustomobject]@{ key = "recent:`$(& `$gid `$_)"; kind = 'recent'; provider = 'claude'; status = 'recent'; project = 'q'; title = "closed `$_"; sessionId = (& `$gid `$_); cwd = '$sb'; since = 1; stateText = "`${_}h" } })
`$snapR = [pscustomobject]@{ header = [pscustomobject]@{ usage = @(); notes = @() }; counts = [pscustomobject]@{ idle = 2; unread = 1 }; rows = `$ur; recent = `$rec }
`$H.Ctx.ViewSig = 'recent'
Update-ChatOverlayView `$H `$snapR
`$H.Win.UpdateLayout()
`$kids = @(`$H.Stack.Children)
`$head = @(`$kids | Where-Object { `$_ -is [System.Windows.Controls.TextBlock] -and `$_.Tag -is [string] -and `$_.Tag -eq 'recent' })
`$hi = if (`$head.Count) { `$kids.IndexOf(`$head[0]) } else { -1 }
`$rw = @(`$kids | Where-Object { `$_.Tag -and `$_.Tag -isnot [string] -and `$_.Tag.kind -eq 'recent' })
`$rects = @(Get-ChatOverlayRowRects `$H)
`$recentOk = `$head.Count -eq 1 -and `$head[0].Text -eq 'Recent' -and `$hi -gt `$kids.IndexOf(@(`$kids | Where-Object { `$_.Tag -and `$_.Tag -isnot [string] -and `$_.Tag.key -eq 's:u2' })[0]) -and
    `$rw.Count -eq 3 -and -not @(`$rw | Where-Object { `$kids.IndexOf(`$_) -lt `$hi -or `$_.Children.Count -ne 1 -or `$_.Children[0].Tag -ne 'line' -or `$_.Margin.Top -ne 1 }).Count -and
    (Get-ChatOverlayDrawnRows `$H) -eq 2 -and @(`$rects | Where-Object { `$_.Key -like 'recent:*' -and (Test-ChatOverlayRowOpenable `$_.Row) }).Count -eq 3
`$dotOf = {
    param(`$k)
    `$ln = @(`$kids | Where-Object { `$_.Tag -and `$_.Tag -isnot [string] -and `$_.Tag.key -eq `$k })[0].Children[0]
    `$d = @(`$ln.Children | Where-Object { `$_ -is [System.Windows.Shapes.Ellipse] -and `$_.Tag -is [string] -and `$_.Tag -eq 'unread' })
    `$st = @(`$ln.Children | Where-Object { `$_ -is [System.Windows.Controls.TextBlock] -and `$_.Text -like 'idle *' })[0]
    if (`$d.Count -eq 1 -and `$d[0].Width -eq 6 -and `$d[0].Fill -eq (Get-ChatOverlayBrush 'accent') -and `$ln.Children.IndexOf(`$d[0]) -eq `$ln.Children.IndexOf(`$st) + 1) { 'dot' } elseif (`$d.Count) { 'bad' } else { '-' }
}
`$unreadOk = (& `$dotOf 's:u1') -eq 'dot' -and (& `$dotOf 's:u2') -eq '-'
# collapsed: nothing of it, and the one line says how many are new
Set-ChatOverlayCollapsed `$H `$true
`$foldLine = @(`$H.Stack.Children[0].Children | Where-Object { `$_ -is [System.Windows.Controls.TextBlock] } | ForEach-Object { `$_.Text }) -join '/'
`$foldOk = `$H.Stack.Children.Count -eq 1 -and `$foldLine -like '*1 new*'
Set-ChatOverlayCollapsed `$H `$false
# the chip on a recent line keeps it through a redraw, and goes with it
`$H.ChipKey = "recent:`$(& `$gid 2)"
`$H.ChipRow = `$null
`$H.Ctx.ViewSig = 'recent again'
Update-ChatOverlayView `$H `$snapR
`$chipKept = `$H.ChipKey -and `$H.ChipRow -and `$H.ChipRow.title -eq 'closed 2'
`$H.Ctx.ViewSig = 'recent gone'
Update-ChatOverlayView `$H ([pscustomobject]@{ header = [pscustomobject]@{ usage = @(); notes = @() }; counts = [pscustomobject]@{ idle = 2 }; rows = `$ur; recent = @(`$rec | Select-Object -First 1) })
`$chipOk = `$chipKept -and -not `$H.ChipKey
# the settings box's Recent row: off, 5 or 10, the one in force filled
`$rcChips = & `$chipsOf '10'
`$rcFirst = `$rcChips -and (@(`$rcChips.Children | ForEach-Object { `$_.Tag }) -join ',') -eq 'off,5,10' -and (& `$on `$rcChips) -eq '5' -and [System.Windows.Controls.Grid]::GetRow(`$rcChips) -eq 5
# and the list built afresh at once: a pass run there and then, drawn
`$rcCycle = `$H.Ctx.Cycle
Set-ChatOverlayRecentChoice `$H '10'
`$rc10 = (Get-ChatOverlayConfig).recent -eq 10 -and (& `$on (& `$chipsOf '10')) -eq '10' -and `$H.Ctx.Cycle -eq `$rcCycle + 1 -and
    `$H.Snap -and "`$(`$H.ViewKey)".StartsWith("`$(`$H.Ctx.ViewSig)|")
Set-ChatOverlayRecentChoice `$H 'off'
`$rcChipsOk = `$rcFirst -and `$rc10 -and (Get-ChatOverlayConfig).recent -eq 0 -and `$H.Ctx.Config.recent -eq 0 -and (& `$on (& `$chipsOf '10')) -eq 'off'
# the height cap mid-drag, Width just set: WPF's own scale, never the
# rect's ratio to ActualWidth - which lags the rect there. Here WPF keeps
# the two in step, so a rect that disagrees stands in for that moment.
`$H.Win.UpdateLayout()
`$H.Win.MaxHeight = [double]::PositiveInfinity
`$H.Win.Width = [Math]::Round(`$H.Win.ActualWidth * 1.5)
Update-ChatOverlayMaxHeight `$H
`$m11 = [System.Windows.PresentationSource]::FromVisual(`$H.Win).CompositionTarget.TransformToDevice.M11
`$skew = Get-ChatOverlayScale `$H @(0, 0, [int](`$H.Win.ActualWidth * 3), 100) -Device
`$capTop = ([ChatOverlayNative]::GetRect(`$H.Hwnd))[1]
`$capOk = `$H.Win.MaxHeight -eq [Math]::Floor((1020 - `$capTop) / `$m11) -and `$skew -eq `$m11 -and
    (Get-ChatOverlayScale `$H @(0, 0, [int](`$H.Win.ActualWidth * 3), 100)) -ne `$m11
# moved, the cap goes by its new top edge at once, not at the next pass: a
# grip drag let go higher up on a screen 500 pixels tall, then at its foot,
# where a row is still drawn
`$script:ChatOverlayWorkAreaSeam = { param(`$r) [pscustomobject]@{ X = -4000; Y = 0; Width = 1920; Height = 500 } }
`$H.Ctx.Config.maxRows = 30
`$H.Ctx.ViewSig = 'twelve'
Update-ChatOverlayView `$H ([pscustomobject]@{ header = [pscustomobject]@{ usage = @(); notes = @() }; rows = @(1..12 | ForEach-Object { [pscustomobject]@{ key = "s:`$_"; kind = 'session'; status = 'idle'; rank = 3; project = 'p'; title = "chat `$_"; prompt = 'x'; stateText = 'idle 1m'; job = `$null } }) })
`$H.Win.UpdateLayout()
`$n0 = Get-ChatOverlayDrawnRows `$H
`$drop = { param(`$y) [ChatOverlayNative]::MoveTo(`$H.Hwnd, -2594, `$y); `$H.GripDrag = @{ Mx = 0; My = 0; X = -2594; Y = `$y }; Stop-ChatOverlayGripDrag `$null; `$H.Win.UpdateLayout() }
& `$drop 97
`$n1 = Get-ChatOverlayDrawnRows `$H
`$movedOk = `$H.Win.MaxHeight -eq [Math]::Floor((500 - 97) / `$m11) -and -not `$H.GripDrag -and `$n1 -gt `$n0
& `$drop 495
`$movedOk = `$movedOk -and `$H.Win.MaxHeight -ge 36 -and (Get-ChatOverlayDrawnRows `$H) -eq 1 -and
    (Get-ChatOverlayHeightCap 495 ([pscustomobject]@{ X = 0; Y = 0; Width = 1; Height = 500 }) 1 55) -eq 55 -and
    (Get-ChatOverlayHeightCap 197 ([pscustomobject]@{ X = 0; Y = 100; Width = 1; Height = 500 }) 2 55) -eq 201
# stretched into Recent: 2 chats open, 8 rows kept, and 8 closed ones - 3
# in recent, 5 in recentMore, the pool past overlay.recent - of which
# overlay.recent are drawn, the two lists in turn; a count set live is not
# saved
`$script:ChatOverlayWorkAreaSeam = { param(`$r) [pscustomobject]@{ X = -4000; Y = 0; Width = 1920; Height = 1020 } }
Set-ChatOverlayConfig @{ width = 380; maxRows = 8; recent = 3 }
`$H.Ctx.Config = Get-ChatOverlayConfig
Set-ChatOverlayWidth `$H 380
[ChatOverlayNative]::MoveTo(`$H.Hwnd, -2594, 197)
`$pool = @(1..8 | ForEach-Object { [pscustomobject]@{ key = "recent:`$(& `$gid `$_)"; kind = 'recent'; provider = 'claude'; status = 'recent'; project = 'q'; title = "pool `$_"; sessionId = (& `$gid `$_); cwd = '$sb'; since = 1; stateText = "`${_}h" } })
`$snapP = [pscustomobject]@{ header = [pscustomobject]@{ usage = @(); notes = @() }; counts = [pscustomobject]@{ idle = 2 }; rows = `$ur; recent = @(`$pool | Select-Object -First 3); recentMore = @(`$pool | Select-Object -Skip 3) }
`$H.Ctx.ViewSig = 'pool'
Update-ChatOverlayView `$H `$snapP
`$H.Win.UpdateLayout()
`$drawnT = { @(`$H.Stack.Children | Where-Object { Test-ChatOverlayRecentElement `$_ } | ForEach-Object { `$_.Tag.title }) -join ',' }
`$headN = { @(`$H.Stack.Children | Where-Object { `$_.Tag -is [string] -and `$_.Tag -eq 'recent' }).Count }
`$pool3 = & `$drawnT
Set-ChatOverlayRecentCount `$H 5
`$pool5 = & `$drawnT
`$live5 = (Get-ChatOverlayConfig).recent -eq 3 -and "`$(`$H.ViewKey)" -like '*|5|*'
Set-ChatOverlayRecentCount `$H 0
`$pool0 = (& `$drawnT) -eq '' -and (& `$headN) -eq 0
Set-ChatOverlayRecentCount `$H 3
`$poolDraw = `$pool3 -eq 'pool 1,pool 2,pool 3' -and `$pool5 -eq 'pool 1,pool 2,pool 3,pool 4,pool 5' -and `$live5 -and `$pool0 -and (& `$drawnT) -eq `$pool3 -and (& `$headN) -eq 1
# the bottom edge dragged: past the two open rows, Recent lines from the
# pool, live; let go, Recent's count saved and maxRows not; up, the lines
# go first, then a row, both saved; a press let go where it was saves
# nothing; down again, the row comes back before the lines
`$o = [System.Drawing.Point]::new(100, 100)
`$saveFn = `${function:Save-ChatOverlaySetting}
`$script:saves = [System.Collections.Generic.List[string]]::new()
`${function:Save-ChatOverlaySetting} = { param(`$X, [hashtable]`$V) `$script:saves.Add((@(`$V.Keys | Sort-Object) -join ',')); & `$saveFn `$X `$V }
try {
    `$H.Ctx.RecentSig = 'built'
    Start-ChatOverlaySizeDrag `$null `$o 's'
    `$d = `$H.SizeDrag
    `$atStart = `$d.Open -eq 2 -and `$d.Rows -eq 2 -and `$d.Kept -eq 8 -and `$d.RecentDrawn -eq 3 -and `$d.Pool -eq 8 -and `$d.RecentKept -eq 3 -and `$d.RecentPx -gt 0
    Move-ChatOverlaySizeDrag ([System.Drawing.Point]::new(100, 100 + [int](2.5 * `$d.RecentPx)))
    `$H.Win.UpdateLayout()
    `$midT = & `$drawnT
    `$midSaved = (Get-ChatOverlayConfig).recent -eq 3 -and -not `$script:saves.Count
    Stop-ChatOverlaySizeDrag `$null
    `$cS = Get-ChatOverlayConfig
    `$sv1 = "`$(`$script:saves -join ';')/`$(`$H.Ctx.RecentSig)/`$(& `$on (& `$chipsOf '10'))"
    `$stretchOut = `$atStart -and `$midT -eq 'pool 1,pool 2,pool 3,pool 4,pool 5' -and `$midSaved -and `$cS.recent -eq 5 -and `$cS.maxRows -eq 8 -and
        `$sv1 -eq 'recent//5' -and (Get-ChatOverlayDrawnRows `$H) -eq 2
    `$script:saves.Clear()
    Start-ChatOverlaySizeDrag `$null `$o 's'
    Move-ChatOverlaySizeDrag ([System.Drawing.Point]::new(100, 100 - [int](1.5 * `$H.SizeDrag.RecentPx)))
    Stop-ChatOverlaySizeDrag `$null
    `$in4 = (Get-ChatOverlayConfig).recent -eq 4 -and (Get-ChatOverlayConfig).maxRows -eq 8 -and (& `$drawnT) -eq 'pool 1,pool 2,pool 3,pool 4' -and
        (& `$on (& `$chipsOf '10')) -eq '' -and (`$script:saves -join ';') -eq 'recent'
    `$script:saves.Clear()
    Start-ChatOverlaySizeDrag `$null `$o 's'
    `$d = `$H.SizeDrag
    Move-ChatOverlaySizeDrag ([System.Drawing.Point]::new(100, 100 - [int](4 * `$d.RecentPx + 1.5 * `$d.RowPx)))
    Stop-ChatOverlaySizeDrag `$null
    `$c0 = Get-ChatOverlayConfig
    `$inRows = `$c0.recent -eq 0 -and `$c0.maxRows -eq 1 -and (& `$drawnT) -eq '' -and (& `$headN) -eq 0 -and (Get-ChatOverlayDrawnRows `$H) -eq 1 -and
        (`$script:saves -join ';') -eq 'maxRows,recent' -and (& `$on (& `$chipsOf '10')) -eq 'off'
    `$script:saves.Clear()
    Start-ChatOverlaySizeDrag `$null `$o 's'
    Move-ChatOverlaySizeDrag `$o
    Stop-ChatOverlaySizeDrag `$null
    `$still = -not `$script:saves.Count
    Start-ChatOverlaySizeDrag `$null `$o 's'
    `$d = `$H.SizeDrag
    Move-ChatOverlaySizeDrag ([System.Drawing.Point]::new(100, 100 + [int](`$d.RowPx + 2.5 * `$d.RecentPx)))
    `$H.Win.UpdateLayout()
    `$midRows = Get-ChatOverlayDrawnRows `$H
    Stop-ChatOverlaySizeDrag `$null
    `$cB = Get-ChatOverlayConfig
    `$back = `$midRows -eq 2 -and `$cB.maxRows -eq 2 -and `$cB.recent -eq 2 -and (& `$drawnT) -eq 'pool 1,pool 2' -and (`$script:saves -join ';') -eq 'maxRows,recent'
}
finally { `${function:Save-ChatOverlaySetting} = `$saveFn }
`$stretchIn = `$in4 -and `$inRows
# the top edge by the foot of a screen 500 pixels tall, every open row
# shown and the Recent lines cut: a line's travel up brings one back, the
# count kept as saved, the bottom held
Set-ChatOverlayConfig @{ recent = 8 }
`$H.Ctx.Config = Get-ChatOverlayConfig
`$H.ViewKey = `$null
Update-ChatOverlayView `$H `$snapP
`$H.Win.UpdateLayout()
`$full = `$H.Win.ActualHeight
`$lineDip = Get-ChatOverlayRecentHeight `$H
`$script:ChatOverlayWorkAreaSeam = { param(`$r) [pscustomobject]@{ X = -4000; Y = 0; Width = 1920; Height = 500 } }
[ChatOverlayNative]::MoveTo(`$H.Hwnd, -2594, 500 - [int][Math]::Floor((`$full - 3.5 * `$lineDip) * `$m11))
Sync-ChatOverlayHeightCap `$H
`$H.Win.UpdateLayout()
`$t0 = Get-ChatOverlayDrawnRecent `$H
`$qt0 = [ChatOverlayNative]::GetRect(`$H.Hwnd)
Start-ChatOverlaySizeDrag `$null `$o 'n'
Move-ChatOverlaySizeDrag ([System.Drawing.Point]::new(100, 100 - [int](1.5 * `$H.SizeDrag.RecentPx)))
Stop-ChatOverlaySizeDrag `$null
`$H.Win.UpdateLayout()
`$qt1 = [ChatOverlayNative]::GetRect(`$H.Hwnd)
`$t1 = Get-ChatOverlayDrawnRecent `$H
`$topRecent = `$t0 -gt 0 -and `$t0 -lt 8 -and `$t1 -eq (`$t0 + 1) -and (Get-ChatOverlayConfig).recent -eq 8 -and (Get-ChatOverlayDrawnRows `$H) -eq 2 -and
    `$qt1[1] -lt `$qt0[1] -and [Math]::Abs((`$qt1[1] + `$qt1[3]) - (`$qt0[1] + `$qt0[3])) -le [Math]::Ceiling(`$m11) + 1
[IO.File]::WriteAllText(`$script:ChatqConfigPath, `$cfgWas)
'{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}|{10}|{11}|{12}' -f `$recentOk, `$unreadOk, `$foldOk, `$chipOk, `$rcChipsOk, `$capOk, `$movedOk, `$poolDraw, `$stretchOut, `$stretchIn, (`$still -and `$back), `$topRecent,
    "head `$hi rows `$(`$rw.Count) drawn `$(Get-ChatOverlayDrawnRows `$H) rects `$(@(`$rects | ForEach-Object { `$_.Key }) -join ',') dots `$(& `$dotOf 's:u1')/`$(& `$dotOf 's:u2') fold '`$foldLine' chip `$chipKept rc `$rcFirst/`$rc10 cap `$(`$H.Win.MaxHeight) m11 `$m11 skew `$skew moved `$n0/`$n1 pool '`$pool3' '`$pool5' `$live5 `$pool0 start `$atStart mid '`$midT' `$midSaved saved `$(`$cS.recent)/`$(`$cS.maxRows) '`$sv1' in `$in4/`$inRows c0 `$(`$c0.recent)/`$(`$c0.maxRows) still `$still back `$midRows `$(`$cB.recent)/`$(`$cB.maxRows) top `$t0>`$t1 `$(`$qt0 -join ',') > `$(`$qt1 -join ',') full `$full line `$lineDip"
"@
$recentOut = Invoke-Sta 'recent-test' $wpfRecent
$rz2 = "$recentOut" -split '\|'
Check 'Recent under the open rows: a faint header, a compact line each the open chip takes, none counted as a row' ($rz2[0] -eq 'True') "$recentOut"
Check 'a row that finished a turn unseen has the accent dot just before its state; the others none' ($rz2[1] -eq 'True') "$recentOut"
Check 'collapsed: no Recent, and the one line says "1 new"' ($rz2[2] -eq 'True') "$recentOut"
Check 'the chip on a recent line keeps it through a redraw, and goes when it does' ($rz2[3] -eq 'True') "$recentOut"
Check 'the settings box: Recent off, 5 or 10, the one in force filled, kept in config.json, and a pass run at once to build it' ($rz2[4] -eq 'True') "$recentOut"
Check 'the height cap takes WPF''s own scale, not the rect''s ratio to ActualWidth, which a drag can put out of step' ($rz2[5] -eq 'True') "$recentOut"
Check 'the height cap goes by the panel''s top edge, worked out again as a drag is let go; at the screen''s foot a row still shows' ($rz2[6] -eq 'True') "$recentOut"
Check 'Recent drawn: overlay.recent of the snapshot''s recent, then its recentMore; a count set live redraws, unsaved; 0, no header' ($rz2[7] -eq 'True') "$recentOut"
Check 'the bottom edge past every open row: Recent lines from the pool, live; let go, Recent''s count saved, maxRows not, the list split anew, the chip lit' ($rz2[8] -eq 'True') "$recentOut"
Check 'the bottom edge back up: the Recent lines go first, then a row - only what changed saved; off lights Off' ($rz2[9] -eq 'True') "$recentOut"
Check 'a press let go where it was saves nothing; down again, the open row comes back before the Recent lines' ($rz2[10] -eq 'True') "$recentOut"
Check 'the top edge by the screen''s foot: a Recent line the foot cut comes back for a line''s travel up, the count kept, the bottom held' ($rz2[11] -eq 'True') "$recentOut"

# the console, a mode of the panel's own window: the panel shown on a screen
# of the test's own, off every real one, then turned into the console -
# never activated - and driven the way a user would: its lists, a search, a
# chat picked, a file dropped, a screenshot pasted, Send, a theme switch; then
# back to the panel by Esc, the back button, a close and the verbs
$con = @"
$staLoad
`$script:ChatqSpawn = { `$true }
`$script:ChatConsoleNoSync = `$true
`$script:ChatConsoleClipboardSeam = { [pscustomobject]@{ Files = @(); Image = [byte[]](137, 80, 78, 71, 13, 10) } }
Initialize-ChatOverlayNative
$staPanel
`$H.Snap = [pscustomobject]@{ header = [pscustomobject]@{ usage = @(); notes = @() }; counts = [pscustomobject]@{ queued = 0; running = 0; cutOff = 1 }; rows = @(
    [pscustomobject]@{ key = 's:$idCard'; kind = 'session'; status = 'idle'; chat = 'idle'; rank = 3; project = 'A'; title = 'Card'; stateText = 'idle 1m'; sessionId = '$idCard'; cwd = '$projA'; job = `$null; prompt = 'its newest prompt'; where = 'vscode'; unread = `$true }
    [pscustomobject]@{ key = 'c:c1'; kind = 'cutoff'; status = 'cutoff'; chat = 'cutoff'; rank = 0.5; project = 'api'; title = 'Rate limiter'; stateText = 'cut off - resets 13:00'; sessionId = 'c1'; cwd = 'C:\p'; path = 'C:\p\x.jsonl'; job = `$null; prompt = `$null }) }
`$snap0 = `$H.Snap
`$script:ChatOverlayWorkAreaSeam = { param(`$r) [pscustomobject]@{ X = -4000; Y = 0; Width = 1920; Height = 1020 } }
Remove-Item -LiteralPath `$script:ChatConsoleStatePath -Force -EA SilentlyContinue
`$H.Placed = `$true
`$H.Ctx.ViewSig = 'con'
# full rows on the panel: the console's are compact whatever it has
`$H.Ctx.Config.prompts = `$true
`$H.Win.Show()
[ChatOverlayNative]::ApplyExStyle(`$H.Hwnd, `$H.Locked)
[ChatOverlayNative]::MoveTo(`$H.Hwnd, -2594, 197)
Update-ChatOverlayView `$H `$snap0
`$H.Win.UpdateLayout()
# the bar of buttons with it, as the host shows it
Show-ChatOverlayControls `$H `$true
`$m11 = [System.Windows.PresentationSource]::FromVisual(`$H.Win).CompositionTarget.TransformToDevice.M11
`$p0 = [ChatOverlayNative]::GetRect(`$H.Hwnd)
`$kids0 = `$H.Stack.Children.Count
# the panel as the tests compare it: its mode, rect, width, rows, fold, the
# styles that make it passive, on top, and its content - and the bar of
# buttons, shown with it
`$panelSays = {
    `$H.Win.UpdateLayout()
    `$x = [ChatOverlayNative]::GetExStyle(`$H.Hwnd) -band (0x8 -bor 0x20 -bor 0x80 -bor 0x40000 -bor 0x80000 -bor 0x8000000)
    "`$(`$H.Mode) `$(([ChatOverlayNative]::GetRect(`$H.Hwnd)) -join ',') `$(`$H.Win.Width) `$(`$H.Ctx.Config.maxRows) `$(`$H.Collapsed) `$x `$(`$H.Win.Topmost) `$(`$H.Win.Content -eq `$H.Frame) `$(`$H.Win.IsVisible) `$(`$H.CtlWin.IsVisible)"
}
`$was = & `$panelSays
Enter-ChatOverlayConsoleMode `$H
`$C = `$H.Con
`$ex = [ChatOverlayNative]::GetExStyle(`$H.Hwnd)
`$cr = [ChatOverlayNative]::GetRect(`$H.Hwnd)
# interactive, not on top, on the taskbar; grown from the panel's top-right
# corner at 980 x 680 - pushed up where the screen's foot, 1020, would cut it
# off; the buttons and the chip gone
`$modeOk = `$H.Mode -eq 'console' -and -not (`$ex -band 0x20) -and -not (`$ex -band 0x8000000) -and -not (`$ex -band 0x80) -and [bool](`$ex -band 0x40000) -and
    -not (`$ex -band 0x8) -and -not `$H.Win.Topmost -and `$H.Win.Content -eq `$C.Root -and -not `$H.CtlWin.IsVisible -and -not `$H.ChipWin.IsVisible -and
    (`$cr[0] + `$cr[2]) -eq (`$p0[0] + `$p0[2]) -and `$cr[1] -eq [Math]::Min(`$p0[1], 1020 - `$cr[3]) -and `$cr[2] -eq [int][Math]::Round(980 * `$m11) -and `$cr[3] -eq [int][Math]::Round(680 * `$m11)
# a pass meanwhile draws nothing into the window, and keeps its snapshot
`$snap2 = [pscustomobject]@{ header = [pscustomobject]@{ usage = @(); notes = @() }; rows = @(1..3 | ForEach-Object { [pscustomobject]@{ key = "s:`$_"; kind = 'session'; status = 'idle'; rank = 3; project = 'p'; title = "chat `$_"; prompt = 'x'; stateText = 'idle 1m'; job = `$null } }) }
`$H.Ctx.ViewSig = 'con2'
Update-ChatOverlayView `$H `$snap2
`$viewOk = `$H.Win.Content -eq `$C.Root -and `$H.Stack.Children.Count -eq `$kids0 -and `$H.Snap -eq `$snap2 -and [double]::IsInfinity(`$H.Win.MaxHeight)
`$H.Snap = `$snap0
`$H.Ctx.ViewSig = 'con'
`$C.IndexParsed = `$true
`$C.Index = @(Get-ChatIndex)
Update-ChatConsole `$H
# the index read in a runspace of its own, its rows taken when ready - the
# timer that would take them needs a message loop this test does not run
`$idxStarted = [bool]`$C.IndexRead
for (`$i = 0; `$i -lt 200 -and `$C.IndexRead -and -not `$C.IndexRead.Async.IsCompleted; `$i++) { Start-Sleep -Milliseconds 50 }
Complete-ChatConsoleIndexRead `$H
`$idxRead = `$idxStarted -and -not `$C.IndexRead -and @(`$C.Index).Count -gt 0 -and @(`$C.Index).Count -eq @(Get-ChatIndex).Count -and `$C.IndexStamp -eq (Get-ChatIndexStamp)
`$idxSay = "`$idxStarted `$(@(`$C.Index).Count) `$(`$C.IndexStamp)"
`$kinds = (@(`$C.ChatItems | ForEach-Object Kind | Sort-Object -Unique) -join ',')
# each chat drawn as the panel draws it: the same first line - dot, where it
# runs, state, unread dot, project and title - in the console's list as on
# the panel, and compact there: no prompt line
`$lineSays = {
    param(`$wrap)
    @(@(`$wrap.Children)[0].Children | ForEach-Object {
            if (`$_ -is [System.Windows.Shapes.Ellipse]) { "dot:`$(`$_.Tag):`$(`$_.Fill.Color)`$(`$_.Stroke.Color)" }
            # its runs: Text is empty on a TextBlock built from them
            elseif (`$_ -is [System.Windows.Controls.TextBlock]) { "text:`$((@(`$_.Inlines) | ForEach-Object Text) -join '')" }
            else { "`$(`$_.GetType().Name):`$(`$_.Tag)" }
        }) -join ';'
}
`$itemOf = { param(`$id) @(`$C.Chats.Children | Where-Object { `$_.Tag -and `$_.Tag -isnot [string] -and `$_.Tag.Id -eq `$id })[0] }
`$wrapOf = { param(`$b) @(`$b.Child.Children)[-1].Children[0] }
`$cardWrap = & `$wrapOf (& `$itemOf '$idCard')
`$panWrap = @(`$H.Stack.Children | Where-Object { `$_.Tag -and `$_.Tag -isnot [string] -and `$_.Tag.key -eq 's:$idCard' })[0]
`$recB = @(`$C.Chats.Children | Where-Object { `$_.Tag -and `$_.Tag -isnot [string] -and `$_.Tag.Kind -eq 'recent' })[0]
`$recWrap = if (`$recB) { & `$wrapOf `$recB }
`$rowSay = "console [`$(& `$lineSays `$cardWrap)] `$(`$cardWrap.Children.Count) panel [`$(& `$lineSays `$panWrap)] `$(`$panWrap.Children.Count) recent [`$(if (`$recWrap) { & `$lineSays `$recWrap })] `$(`$recWrap.Tag.status)"
`$rowsOk = `$cardWrap.Tag -eq `$snap0.rows[0] -and `$cardWrap.Children.Count -eq 1 -and `$panWrap.Children.Count -eq 2 -and
    (& `$lineSays `$cardWrap) -eq (& `$lineSays `$panWrap) -and (& `$lineSays `$cardWrap) -like '*;Path:vscode;text:idle 1m;dot:unread:*;text:A  Card' -and
    `$recWrap -and `$recWrap.Tag.status -eq 'recent' -and `$recWrap.Children.Count -eq 1 -and
    (& `$lineSays `$recWrap) -like "dot::`$((Get-ChatOverlayBrush 'recent').Color);*"
# a click's args of its own each time: the handler marks them Handled, and
# raised again they would reach no handler at all
`$up = { param(`$el, `$ts = 0) `$a = [System.Windows.Input.MouseButtonEventArgs]::new([System.Windows.Input.Mouse]::PrimaryDevice, `$ts, [System.Windows.Input.MouseButton]::Left); `$a.RoutedEvent = [System.Windows.UIElement]::MouseLeftButtonUpEvent; `$el.RaiseEvent(`$a) }
# a click picks a chat - the one picked has the accent's bar on the
# selection's colour, the others neither; a cut-off one keeps Continue
`$cutB = & `$itemOf 'c1'
& `$up `$cutB
`$picked = & `$itemOf 'c1'
`$other = & `$itemOf '$idCard'
`$pickOk = `$C.Target.Id -eq 'c1' -and `$picked -ne `$cutB -and `$picked.BorderBrush.Color -eq (Get-ChatOverlayBrush 'accent').Color -and
    `$picked.Background.Color -eq (Get-ChatOverlayBrush 'select').Color -and `$picked.BorderThickness.Left -eq `$other.BorderThickness.Left -and
    `$other.BorderBrush -eq [System.Windows.Media.Brushes]::Transparent -and `$other.Background -eq [System.Windows.Media.Brushes]::Transparent -and
    @(`$picked.Child.Children).Count -eq 2 -and (& `$lineSays (& `$wrapOf `$picked)) -like '*text:cut off - resets 13:00;text:api  Rate limiter'
`$C.SearchBox.Text = 'limiter'
`$searched = @(`$C.ChatItems).Count
`$C.SearchBox.Text = ''
Select-ChatConsoleTarget `$H @(`$C.ChatItems | Where-Object { `$_.Id -eq '$idCard' })[0]
`$to = (@(`$C.To.Children[0].Inlines) | ForEach-Object { `$_.Text }) -join ''
`$f = Join-Path '$sb' 'console-drop.txt'
[IO.File]::WriteAllText(`$f, 'x')
Add-ChatConsoleDrop `$H @(`$f, '$sb')
for (`$i = 0; `$i -lt 60 -and @(`$C.Staged | Where-Object { `$_.Task -and -not `$_.Task.IsCompleted }).Count; `$i++) { Start-Sleep -Milliseconds 50 }
Update-ChatConsoleStaging `$H
`$folderSaid = `$C.Status.Text -like '*is a folder*'
Invoke-ChatConsolePaste `$H (Get-ChatConsoleClipboard)
`$staged = (@(`$C.Staged | ForEach-Object Name | Sort-Object) -join ',')
`$C.Prompt.Text = 'from the console'
# the stand-in watcher never comes up, and Send's pass - a process's first
# over the whole sandbox - with the checks after it can outlast the 10 s a
# watcher Send asks for has to start in on a slow machine, and the status
# line would then say it did not start: the request's clock held at now,
# from here on
`$twr = `${function:Test-ChatqWatcherRequest}
`${function:Test-ChatqWatcherRequest} = { param(`$Request, [bool]`$Queued) if (`$Request) { `$Request.At = Get-Date }; & `$twr `$Request `$Queued }
Invoke-ChatConsoleSend `$H
`$j = @(Get-ChatqJobs | Where-Object { (Read-ChatqPrompt `$_) -eq 'from the console' })[0]
`$files = (@(Get-ChatqAttachments `$j | ForEach-Object Name | Sort-Object) -join ',')
`$sent = [bool](`$j -and `$j.sendNow -and `$j.first -and `$j.sessionId -eq '$idCard' -and `$files -eq 'clip.png,console-drop.txt' -and `$C.Prompt.Text -eq '' -and -not `$C.Staged.Count -and
    -not @(Get-ChildItem -LiteralPath `$script:ChatConsoleDraftDir -EA SilentlyContinue).Count -and `$C.Status.Text -like 'queued #*')
# an edit to the queued prompt outlives a redraw of the queue
`$C.Sel = `$j.id
`$C.Sigs.Queue = `$null
Update-ChatConsoleQueue `$H
if (`$C.EditBox) { `$C.EditBox.Text = 'edited in place' }
`$C.Sigs.Queue = `$null
Update-ChatConsoleQueue `$H
`$editKept = [bool](`$C.EditBox -and `$C.EditBox.Text -eq 'edited in place')
# a waiting job's mode and model, by the chips in its details: written to
# its file, the chip filled, said; the first chip puts the chat's own back
`$chipOf = { param(`$what, `$val) @(`$C.Details.Children | Where-Object { `$_ -is [System.Windows.Controls.DockPanel] } | ForEach-Object { @(`$_.Children) } |
        Where-Object { `$_ -is [System.Windows.Controls.WrapPanel] -and [string]`$_.Tag -eq `$what } | ForEach-Object { @(`$_.Children) } | Where-Object { [string]`$_.Tag -eq `$val })[0] }
`$chipUp = { param(`$c) if (`$c) { & `$up `$c } }
& `$chipUp (& `$chipOf 'mode' 'plan')
& `$chipUp (& `$chipOf 'model' 'sonnet')
`$jr = Find-ChatqJob `$j.id -Exact
`$planChip = & `$chipOf 'mode' 'plan'
`$runAsSay = "mode `$(`$jr.mode) model `$(`$jr.runModel) status [`$(`$C.Status.Text)]"
`$runAsOk = `$jr.mode -eq 'plan' -and `$jr.runModel -eq 'sonnet' -and `$planChip -and `$planChip.Background.Color -eq (Get-ChatOverlayBrush 'accent').Color -and
    `$C.Status.Text -eq "#`$(`$j.seq) runs on sonnet" -and `$C.EditBox.Text -eq 'edited in place'
& `$chipUp (& `$chipOf 'mode' '')
`$jr = Find-ChatqJob `$j.id -Exact
`$runAsOk = `$runAsOk -and -not `$jr.mode -and `$jr.runModel -eq 'sonnet' -and `$C.Status.Text -eq "#`$(`$j.seq) runs in the mode its chat has"
`$runAsSay += " then mode [`$(`$jr.mode)] [`$(`$C.Status.Text)]"
# waiting, its chat can be opened in VS Code: the chip's own open
`$qBtns = (@(`$C.Details.Children | Where-Object { `$_ -is [System.Windows.Controls.WrapPanel] } | ForEach-Object { @(`$_.Children) } | ForEach-Object { `$_.Child.Text }) -join ',')
`$script:WatchCmds = @()
`$script:ChatShowSpawnSeam = { param(`$c) `$script:WatchCmds += `$c; [pscustomobject]@{ HasExited = `$false } }
Invoke-ChatConsoleJobAction `$H `$j.id 'open'
`$openSaid = [string]`$C.Status.Text
`$script:ChatShowSpawnSeam = `$null
`$H.OpenProc = `$null
`$H.OpenSay = `$null
`$openOk = `$qBtns -eq 'Try now,First,Remove,Open in VS Code,Write to this chat' -and @(`$script:WatchCmds).Count -eq 1 -and
    `$script:WatchCmds[0] -like "*Show-ChatFresh -Via chip -SessionId '$idCard' *" -and `$openSaid -eq "#`$(`$j.seq): its chat opens in VS Code"
`$openSay = "[`$qBtns] [`$openSaid] `$(@(`$script:WatchCmds).Count)"
# running, a Claude chat's job offers Watch in VS Code beside Cancel: the
# chip's own open, in its child - one at a time; the tray says how it went
Set-ChatqProp `$j 'state' 'running'
Save-ChatqJob `$j
`$C.Jobs = @(Get-ChatqJobs)
`$C.Sigs.Queue = `$null
Update-ChatConsoleQueue `$H
`$runBtns = (@(`$C.Details.Children | Where-Object { `$_ -is [System.Windows.Controls.WrapPanel] } | ForEach-Object { @(`$_.Children) } | ForEach-Object { `$_.Child.Text }) -join ',')
`$script:WatchCmds = @()
`$script:ChatShowSpawnSeam = { param(`$c) `$script:WatchCmds += `$c; [pscustomobject]@{ HasExited = `$false } }
Invoke-ChatConsoleJobAction `$H `$j.id 'watch'
`$watchSaid = [string]`$C.Status.Text
Invoke-ChatConsoleJobAction `$H `$j.id 'watch'
`$againSaid = [string]`$C.Status.Text
`$script:ChatShowSpawnSeam = `$null
# the stand-in open never ends, so its "opening" line goes with it: a busy
# line has no Until, and left up it makes the panel the Esc checks compare
# a line and a separator taller
`$H.OpenProc = `$null
`$H.OpenSay = `$null
`$watchOk = `$runBtns -eq 'Cancel,Watch in VS Code,Write to this chat' -and @(`$script:WatchCmds).Count -eq 1 -and
    `$script:WatchCmds[0] -like "*Show-ChatFresh -Via chip -SessionId '$idCard' *" -and `$watchSaid -eq "#`$(`$j.seq): its live view opens in VS Code" -and
    `$againSaid -like 'an open is still going*'
`$watchSay = "[`$runBtns] [`$watchSaid] [`$againSaid] `$(@(`$script:WatchCmds).Count)" -replace '\|', '/'
Set-ChatqProp `$j 'state' 'queued'
Save-ChatqJob `$j
`$C.Jobs = @(Get-ChatqJobs)
# queued again, drawn again: the pane still holds the running job's
# buttons, which have no Remove to click
`$C.Sigs.Queue = `$null
Update-ChatConsoleQueue `$H
# Remove, clicked as the mouse clicks it: its Border found again after each
# redraw, each click at a time of its own on the tick count's clock. The
# first asks - "sure?" in error's colour, and the status says so; the second
# half of a double-click is no answer, and says that; an ask 5 s old goes
# back to Remove; a click, then another 1.5 s on, removes. Only the clicks'
# own times make that last one an answer: taken when handled, the two would
# be milliseconds apart, a double-click.
`$rmB = { @(`$C.Details.Children | Where-Object { `$_ -is [System.Windows.Controls.WrapPanel] } | ForEach-Object { `$_.Children } | Where-Object { `$_.Child.Text -like 'Remove*' })[0] }
`$tk = { param([int64]`$v) [int](((`$v + 2147483648) % 4294967296) - 2147483648) }
# No Remove drawn fails the check below rather than calling on null: that
# error, on the child's stderr, ended the whole 5.1 run in Invoke-Sta.
`$rmUp = { param([int64]`$t) `$rb = & `$rmB; if (`$rb) { & `$up `$rb (& `$tk `$t) } }
`$t0 = [int64][Environment]::TickCount
& `$rmUp `$t0
`$b1 = & `$rmB
`$askHeld = [bool]`$b1 -and `$b1.Child.Text -eq 'Remove - sure?' -and `$b1.Child.Foreground.Color -eq (Get-ChatOverlayBrush 'error').Color -and `$C.Status.Text -like 'remove #*'
& `$rmUp (`$t0 + 150)
`$askHeld = `$askHeld -and [bool](Find-ChatqJob `$j.id) -and `$C.Confirm.ContainsKey([string]`$j.id) -and `$C.Status.Text -like 'a double-click*'
Update-ChatConsoleAsks `$H (& `$tk (`$t0 + 5100))
`$askHeld = `$askHeld -and (& `$rmB).Child.Text -eq 'Remove' -and -not `$C.Confirm.Count -and `$C.Status.Text -like '*kept*' -and [bool](Find-ChatqJob `$j.id)
& `$rmUp (`$t0 + 7000)
& `$rmUp (`$t0 + 8500)
`$removed = -not (Find-ChatqJob `$j.id) -and `$C.Status.Text -like 'removed #*'
# Continue twice before the list redraws: one job
`$ci = [pscustomobject]@{ Id = '$idCard'; Title = 'Card'; Path = `$null; Cwd = '$projA' }
Invoke-ChatConsoleContinue `$H @(`$ci)
Invoke-ChatConsoleContinue `$H @(`$ci)
`$conts = @(Get-ChatqJobs | Where-Object { `$_.kind -eq 'continue' -and `$_.sessionId -eq '$idCard' -and `$_.state -eq 'queued' })
`$contOnce = `$conts.Count -eq 1 -and `$C.Status.Text -like '*1 had one already*'
`$contSay = "`$(`$conts.Count) - `$(`$C.Status.Text)" -replace '\|', '/'
foreach (`$x in `$conts) { `$null = Remove-ChatqJob `$x 'test' }
# a Codex chat: no mode or model offered, and none sent even if picked before
`$cxItem = @(`$C.ChatItems | Where-Object { `$_.Provider -eq 'codex' })[0]
`$codexOpts = `$false
`$codexSent = `$false
if (`$cxItem) {
    `$C.Mode = 'plan'
    `$C.Model = 'opus'
    Select-ChatConsoleTarget `$H `$cxItem
    # its rows are When and Sandbox (no Mode, no Model), and the last line says the model is its own
    `$cxRows = @(`$C.Opts.Children | Where-Object { `$_ -is [System.Windows.Controls.DockPanel] } | ForEach-Object { `$_.Children[0].Text }) -join ','
    `$codexOpts = `$cxRows -eq 'When,Sandbox' -and @(`$C.Opts.Children)[-1].Text -eq 'it runs on the model it last used'
    `$C.Prompt.Text = 'to codex'
    Invoke-ChatConsoleSend `$H
    `$cj = @(Get-ChatqJobs | Where-Object { (Read-ChatqPrompt `$_) -eq 'to codex' })[0]
    `$codexSent = [bool](`$cj -and `$cj.provider -eq 'codex' -and -not `$cj.mode -and -not `$cj.runModel)
    if (`$cj) { `$null = Remove-ChatqJob `$cj 'test' }
    `$C.Mode = ''
    `$C.Model = ''
    Select-ChatConsoleTarget `$H @(`$C.ChatItems | Where-Object { `$_.Id -eq '$idCard' })[0]
}
# the panel's own rows again: Send's pass took a snapshot of the sandbox
`$H.Snap = `$snap0
`$C.Prompt.Text = 'kept across a theme'
`$H.Ctx.Config.theme = 'light'
Update-ChatOverlayTheme `$H
`$kept = `$C.Prompt.Text -eq 'kept across a theme' -and `$C.Root.Background.Color.ToString() -eq '#FFF6F8FA' -and `$H.Mode -eq 'console' -and `$H.Win.Content -eq `$C.Root
# the header moves the window from anywhere on it but its controls; the
# look in it is the panel's: the console opens at the panel's opacity, and
# one set in the console is the window's, kept, and the panel's box's
`$keep = @(`$C.BackBtn, `$C.MaxBtn, `$C.Look)
`$dragOk = (Test-ChatConsoleDragFrom `$C.Header `$C.Bar `$keep) -and (Test-ChatConsoleDragFrom `$C.Bar `$C.Bar `$keep) -and
    -not (Test-ChatConsoleDragFrom `$C.BackBtn.Child `$C.Bar `$keep) -and -not (Test-ChatConsoleDragFrom `$C.MaxBtn.Child `$C.Bar `$keep) -and -not (Test-ChatConsoleDragFrom `$C.LookSlider `$C.Bar `$keep) -and -not (Test-ChatConsoleDragFrom `$C.Prompt `$C.Bar `$keep)
`$opWas = `$H.Win.Opacity
`$lookOk = `$opWas -eq (Get-ChatOverlayConfig).opacity -and `$C.LookSlider.Value -eq `$opWas
`$C.LookSlider.Value = 0.6
`$lookOk = `$lookOk -and `$H.Win.Opacity -eq 0.6 -and `$C.LookText.Text -eq '60%'
# Esc, as the prompt box would have it: back to the panel exactly as it was
`$src = [System.Windows.PresentationSource]::FromVisual(`$H.Win)
`$kd = [System.Windows.Input.KeyEventArgs]::new([System.Windows.Input.Keyboard]::PrimaryDevice, `$src, 0, [System.Windows.Input.Key]::Escape)
`$kd.RoutedEvent = [System.Windows.Input.Keyboard]::PreviewKeyDownEvent
`$C.Prompt.RaiseEvent(`$kd)
`$afterEsc = & `$panelSays
`$escOk = `$afterEsc -eq `$was
`$lookOk = `$lookOk -and `$H.Win.Opacity -eq 0.6 -and (Get-ChatOverlayConfig).opacity -eq 0.6 -and `$H.OpacitySlider.Value -eq 0.6
`$lookSay = "was `$opWas now `$(`$H.Win.Opacity) config `$((Get-ChatOverlayConfig).opacity) box `$(`$H.OpacitySlider.Value) drag `$dragOk"
Set-ChatOverlayConfig @{ opacity = `$opWas }
`$H.Ctx.Config = Get-ChatOverlayConfig
`$H.Win.Opacity = `$opWas
`$st = Read-ChatConsoleState
`$saved = `$st.draft.text -eq 'kept across a theme' -and `$st.draft.target.Id -eq '$idCard' -and `$H.Mode -eq 'panel'
# the size kept, in units, not the place: back at that size next time
`$sizeOk = `$st.w -eq [Math]::Round(`$cr[2] / `$m11) -and `$st.h -eq [Math]::Round(`$cr[3] / `$m11) -and `$st.units -eq `$true -and `$st.max -eq `$false -and -not `$st.PSObject.Properties['x']
Enter-ChatOverlayConsoleMode `$H
`$again = [ChatOverlayNative]::GetRect(`$H.Hwnd)
`$sizeOk = `$sizeOk -and (`$again -join ',') -eq (`$cr -join ',')
# Maximize in the header: the stood-in screen's working area, no grip, kept
# in console-state.json with the size it had; again, that size back.
# Windows holds a window to the real screens' track size, so on a runner's
# 1024 x 768 the stood-in 1920 x 1020 comes out 1044 x 788
# (SM_CXMAXTRACK, SM_CYMAXTRACK, in the pixels GetRect reads)
Add-Type -Namespace ChatqTest -Name Metrics -MemberDefinition '[DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);'
`$maxRect = '-4000,0,{0},{1}' -f [Math]::Min(1920, [ChatqTest.Metrics]::GetSystemMetrics(59)), [Math]::Min(1020, [ChatqTest.Metrics]::GetSystemMetrics(60))
& `$up `$C.MaxBtn
`$mx = [ChatOverlayNative]::GetRect(`$H.Hwnd)
`$ms = Read-ChatConsoleState
`$maxOk = (`$mx -join ',') -eq `$maxRect -and `$H.Win.ResizeMode -eq [System.Windows.ResizeMode]::NoResize -and `$C.MaxBtn.Child.Text -like '*Restore' -and
    `$ms.max -eq `$true -and `$ms.w -eq `$st.w -and `$ms.h -eq `$st.h
& `$up `$C.MaxBtn
`$mr0 = [ChatOverlayNative]::GetRect(`$H.Hwnd)
`$maxOk = `$maxOk -and (`$mr0 -join ',') -eq (`$cr -join ',') -and `$H.Win.ResizeMode -eq [System.Windows.ResizeMode]::CanResizeWithGrip -and `$C.MaxBtn.Child.Text -like '*Maximize' -and
    (Read-ChatConsoleState).max -eq `$false
`$maxSay = "max `$(`$mx -join ',') state `$(`$ms.max) `$(`$ms.w)x`$(`$ms.h) back `$(`$mr0 -join ',')"
# the header double-clicked, as a title bar: maximized, and again,
# restored. A press on it while maximized moves nothing - neither DragMove
# nor the held verbs after it run; restored, a press goes on to them (a
# DragMove with no button down throws, and is caught). ClickCount's setter
# is internal, so set by reflection.
`$down = { param([int]`$n)
    `$a = [System.Windows.Input.MouseButtonEventArgs]::new([System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]::Left)
    `$set = [System.Windows.Input.MouseButtonEventArgs].GetProperty('ClickCount').GetSetMethod(`$true)
    if (`$set) { [void]`$set.Invoke(`$a, @(`$n)) } else { [System.Windows.Input.MouseButtonEventArgs].GetField('_count', [System.Reflection.BindingFlags]'NonPublic,Instance').SetValue(`$a, `$n) }
    `$a.RoutedEvent = [System.Windows.UIElement]::MouseLeftButtonDownEvent
    `$C.Bar.RaiseEvent(`$a)
    `$a.ClickCount }
`$heldFn = `${function:Invoke-ChatOverlayHeldVerbs}
`$script:dragRan = 0
`${function:Invoke-ChatOverlayHeldVerbs} = { param(`$X) `$script:dragRan++ }
try {
    `$cc2 = & `$down 2
    `$dx = [ChatOverlayNative]::GetRect(`$H.Hwnd)
    `$dblOk = `$cc2 -eq 2 -and (`$dx -join ',') -eq `$maxRect -and `$C.Max -and `$C.MaxBtn.Child.Text -like '*Restore'
    `$null = & `$down 1
    `$dblOk = `$dblOk -and `$script:dragRan -eq 0 -and `$C.Max -and ([ChatOverlayNative]::GetRect(`$H.Hwnd) -join ',') -eq `$maxRect
    `$null = & `$down 2
    `$dr = [ChatOverlayNative]::GetRect(`$H.Hwnd)
    `$dblOk = `$dblOk -and (`$dr -join ',') -eq (`$cr -join ',') -and -not `$C.Max -and (Read-ChatConsoleState).max -eq `$false
    `$null = & `$down 1
    `$dblOk = `$dblOk -and `$script:dragRan -eq 1 -and -not `$C.Max
}
finally { `${function:Invoke-ChatOverlayHeldVerbs} = `$heldFn; `$H.Dragging = `$false }
`$maxOk = `$maxOk -and `$dblOk
`$maxSay += " dbl `$cc2 `$(`$dx -join ',') then `$(`$dr -join ',') drags `$(`$script:dragRan)"
# maximized, then back to the panel by the back button in the header
& `$up `$C.MaxBtn
& `$up `$C.BackBtn
`$afterBack = & `$panelSays
`$backOk = `$afterBack -eq `$was -and `$C.BackBtn.ToolTip -eq 'Back to the panel (Esc)'
# Alt+F4 or any close: back to the panel, once the dispatcher gets to it -
# the window stays. Opened maximized, as it was left; restored, the size
# it had before.
Enter-ChatOverlayConsoleMode `$H
`$mx2 = [ChatOverlayNative]::GetRect(`$H.Hwnd)
& `$up `$C.MaxBtn
`$mr2 = [ChatOverlayNative]::GetRect(`$H.Hwnd)
`$maxOk = `$maxOk -and (`$mx2 -join ',') -eq `$maxRect -and (`$mr2 -join ',') -eq (`$cr -join ',') -and (Read-ChatConsoleState).max -eq `$false
`$maxSay += " reopened `$(`$mx2 -join ',') restored `$(`$mr2 -join ',')"
`$H.Win.Close()
`$held = `$H.Mode -eq 'console'
`$H.Win.Dispatcher.Invoke([Action] {}, [System.Windows.Threading.DispatcherPriority]::Background)
`$afterClose = & `$panelSays
`$closeOk = `$held -and `$afterClose -eq `$was
# the verbs that act on the panel go back to it first; before each, there
# and back from the panel as the last one left it - collapsed, in the tray
`$verbSay = @()
`$roundSay = @()
`$round = { param(`$from) `$base = & `$panelSays; Enter-ChatOverlayConsoleMode `$H; Exit-ChatOverlayConsoleMode `$H; `$now = & `$panelSays; if (`$now -ne `$base) { `$script:roundBad += "`$from [`$base] [`$now]" } }
`$script:roundBad = @()
foreach (`$v in 'collapse', 'lock', 'hide', 'unlock') {
    & `$round "before `$v"
    Enter-ChatOverlayConsoleMode `$H
    `$m = `$H.Mode
    Invoke-ChatOverlayVerb `$v
    `$verbSay += "`${v}:`${m}>`$(`$H.Mode)"
}
`$verbsOk = (`$verbSay -join ' ') -eq 'collapse:console>panel lock:console>panel hide:console>panel unlock:console>panel' -and
    `$H.Collapsed -and `$H.Hidden -and -not `$H.Win.IsVisible -and -not `$H.Locked
# unlocked in the tray, and unlocked on the screen: there and back
`$base = & `$panelSays
Enter-ChatOverlayConsoleMode `$H
`$shownHidden = `$H.Mode -eq 'console' -and `$H.Win.IsVisible
Exit-ChatOverlayConsoleMode `$H
if ((& `$panelSays) -ne `$base) { `$script:roundBad += "hidden unlocked [`$base] [`$(& `$panelSays)]" }
Invoke-ChatOverlayVerb 'show'
& `$round 'unlocked'
`$roundOk = -not `$script:roundBad.Count -and `$H.Win.IsVisible -and -not `$H.Locked -and `$H.Collapsed
# The panel's place kept around the console. A slider not yet at rest is
# kept as it turns into the console, the panel's place with it; one met in
# the console's mode keeps no place - the rect is the console's.
`$pr = [ChatOverlayNative]::GetRect(`$H.Hwnd)
`$H.State.x = -1
`$H.PendingWidth = [int]`$H.Ctx.Config.width
`$H.PendingAt = Get-Date
Enter-ChatOverlayConsoleMode `$H
`$placeOk = `$null -eq `$H.PendingWidth -and `$H.State.x -eq `$pr[0] -and `$H.State.y -eq `$pr[1]
`$H.PendingWidth = [int]`$H.Ctx.Config.width
`$null = Get-ChatOverlayPending `$H
`$placeOk = `$placeOk -and `$H.State.x -eq `$pr[0]
# a width a reload set meanwhile: the right edge held, and kept
`$H.PanelWas.Width = `$H.PanelWas.Width + 100
Exit-ChatOverlayConsoleMode `$H
`$wr = [ChatOverlayNative]::GetRect(`$H.Hwnd)
`$placeOk = `$placeOk -and (`$wr[0] + `$wr[2]) -eq (`$pr[0] + `$pr[2]) -and `$wr[2] -gt `$pr[2] -and `$H.State.x -eq `$wr[0] -and `$wr[1] -eq `$pr[1]
# held never past the left of its screen: it grows to the right there
`$seamWas = `$script:ChatOverlayWorkAreaSeam
`$edgeX = `$wr[0] - 50
`$script:ChatOverlayWorkAreaSeam = [scriptblock]::Create("[pscustomobject]@{ X = `$edgeX; Y = 0; Width = 1920; Height = 1020 }")
Enter-ChatOverlayConsoleMode `$H
`$H.PanelWas.Width = `$H.PanelWas.Width + 100
Exit-ChatOverlayConsoleMode `$H
`$er = [ChatOverlayNative]::GetRect(`$H.Hwnd)
`$placeOk = `$placeOk -and `$er[0] -eq `$edgeX -and `$er[2] -gt `$wr[2] -and `$H.State.x -eq `$edgeX
`$script:ChatOverlayWorkAreaSeam = `$seamWas
`$placeSay = "panel `$(`$pr -join ',') wider `$(`$wr -join ',') edge `$edgeX `$(`$er -join ',') state `$(`$H.State.x),`$(`$H.State.y)"
# A size kept under the window's least - saved on a screen at a lower
# scale - opens at that least, in this screen's pixels, and still ends at
# the panel's right, not pushed past it by Windows
# the panel's right edge back inside the stood-in screen, -2080, which the
# panel grown above runs past
`$pr = [ChatOverlayNative]::GetRect(`$H.Hwnd)
[ChatOverlayNative]::MoveTo(`$H.Hwnd, -2400 - `$pr[2], 197)
`$pr = [ChatOverlayNative]::GetRect(`$H.Hwnd)
`$C.State.w = 500
`$C.State.h = 350
Enter-ChatOverlayConsoleMode `$H
`$mr = [ChatOverlayNative]::GetRect(`$H.Hwnd)
`$minOk = `$mr[2] -eq [int][Math]::Ceiling(640 * `$m11) -and `$mr[3] -eq [int][Math]::Ceiling(420 * `$m11) -and (`$mr[0] + `$mr[2]) -eq (`$pr[0] + `$pr[2])
`$minSay = "panel `$(`$pr -join ',') console `$(`$mr -join ',') m11 `$m11"
Invoke-ChatOverlayVerb 'stop'
`$verbsOk = `$verbsOk -and `$shownHidden -and `$H.Mode -eq 'panel' -and `$H.ShuttingDown
`$verbSay = "`$(`$verbSay -join ' ') `$shownHidden `$(`$H.Mode)"
if (`$j -and (Find-ChatqJob `$j.id)) { `$null = Remove-ChatqJob `$j 'test' }
`$modeSay = "was [`$was] esc [`$afterEsc] back [`$afterBack] close [`$afterClose] console ex `$ex rect `$(`$cr -join ',') again `$(`$again -join ',') panel `$(`$p0 -join ',') m11 `$m11 saved `$(`$st.w)x`$(`$st.h) view `$viewOk"
'{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}|{10}|{11}|{12}|{13}|{14}|{15}|{16}|{17}|{18}|{19}|{20}|{21}|{22}|{23}|{24}|{25}|{26}|{27}|{28}|{29}|{30}|{31}|{32}|{33}|{34}|{35}|{36}|{37}|{38}|{39}|{40}|{41}' -f `$modeOk, `$kinds, `$searched, `$to, `$staged, `$sent, `$kept, `$saved, `$folderSaid, `$files, `$editKept, `$askHeld, `$removed, `$contOnce, `$codexOpts, `$codexSent, `$contSay, `$idxRead, `$idxSay,
    `$viewOk, `$escOk, `$backOk, `$closeOk, `$verbsOk, `$sizeOk, `$verbSay, `$modeSay, `$rowsOk, `$pickOk, (`$rowSay -replace '\|', '/'), `$roundOk, `$placeOk, `$minOk,
    ("round [`$(`$script:roundBad -join ' / ')] place [`$placeSay] min [`$minSay]" -replace '\|', '/'), `$watchOk, `$watchSay, (`$dragOk -and `$lookOk), (`$lookSay -replace '\|', '/'),
    `$runAsOk, `$openOk, `$maxOk, ("runAs [`$runAsSay] open [`$openSay] `$maxSay" -replace '\|', '/')
"@
$conOut = Invoke-Sta 'console-test' $con
$cp = "$conOut" -split '\|'
Check 'the console is a mode of the panel''s window: it takes clicks and focus, is on the taskbar, not on top, grown from the panel''s top-right corner; no buttons or chip' ($cp[0] -eq 'True') "$($cp[26])"
Check 'a pass in the console''s mode keeps its snapshot and draws nothing into the window' ($cp.Count -gt 19 -and $cp[19] -eq 'True') "$($cp[26])"
Check 'Esc goes back to the panel exactly as it was: its place, width, rows, fold, styles and top' ($cp.Count -gt 20 -and $cp[20] -eq 'True') "$($cp[26])"
Check 'the back button in the header goes back to the panel as it was' ($cp.Count -gt 21 -and $cp[21] -eq 'True') "$($cp[26])"
Check 'a close in the console''s mode goes back to the panel, and the window stays' ($cp.Count -gt 22 -and $cp[22] -eq 'True') "$($cp[26])"
Check 'hide, collapse, lock, unlock and stop go back to the panel first; hidden, it goes back to the tray' ($cp.Count -gt 23 -and $cp[23] -eq 'True') "$($cp[25])"
Check 'the console''s size is kept in units - not its place - and it opens at that size again' ($cp.Count -gt 24 -and $cp[24] -eq 'True') "$($cp[26])"
Check 'Maximize in the console''s header fills the screen''s working area without the grip, and is kept; Restore gives the size back; a double-click on the header does both, and a press on it while maximized moves nothing; left maximized, it opens maximized and the panel comes back as it was' ($cp.Count -gt 41 -and $cp[40] -eq 'True') "$($cp[41])"
Check 'a waiting job''s mode and model are changed by the chips in its details: written to its file, the chip filled, said; the first chip gives the chat''s own back' ($cp.Count -gt 41 -and $cp[38] -eq 'True') "$($cp[41])"
Check 'a waiting job''s chat opens in VS Code from its details, through the chip''s own Show-ChatFresh child' ($cp.Count -gt 41 -and $cp[39] -eq 'True') "$($cp[41])"
Check 'to the console and back from a collapsed, locked, hidden or unlocked panel: each comes back exactly as it was' ($cp.Count -gt 33 -and $cp[30] -eq 'True') "$($cp[33])"
Check 'the panel''s place around the console: a slider at rest kept as it opens, none kept from the console''s rect; a reload''s width holds the right edge, never past the screen''s left, and is kept' ($cp.Count -gt 33 -and $cp[31] -eq 'True') "$($cp[33])"
Check 'a console size saved under the window''s least opens at that least in this screen''s pixels, its right edge still at the panel''s' ($cp.Count -gt 33 -and $cp[32] -eq 'True') "$($cp[33])"
Check 'the console''s list draws each chat with the panel''s row builder - the same line, dot to unread, compact - and a recent one as the panel''s Recent' ($cp.Count -gt 29 -and $cp[27] -eq 'True') "$($cp[29])"
Check 'a click on a chat in the console''s list picks it: the accent''s bar on the selection''s colour, the others plain, Continue kept' ($cp.Count -gt 28 -and $cp[28] -eq 'True') "$($cp[29])"
Check 'it lists the chats the limit cut off and those open in VS Code; the search narrows them' ($cp[1] -like '*cutoff*' -and $cp[1] -like '*open*' -and $cp[2] -eq '1') "$conOut"
Check 'a chat picked is the one written to; a file dropped and a screenshot pasted go with it, a folder does not' ($cp[3] -like 'To*Card*' -and $cp[4] -eq 'clip.png,console-drop.txt' -and $cp[8] -eq 'True') "$conOut"
Check 'Send makes the job chatq would - first, sent now, files moved in - and clears the box for the next' ($cp[5] -eq 'True') "$conOut"
Check 'the console''s header moves the window from anywhere but its controls; its opacity is the panel''s, set from either and kept' ($cp.Count -gt 37 -and $cp[36] -eq 'True') "$($cp[37])"
Check 'a theme switch keeps what is typed, in the console''s mode still; going back keeps the draft for next time' ($cp[6] -eq 'True' -and $cp[7] -eq 'True') "$conOut"
Check 'a queued prompt being edited outlives a redraw of the queue' ($cp[10] -eq 'True') "$conOut"
Check 'Remove clicked: asks with sure? in red and says so, a double-click does not answer and says so, an ask 5 s old goes back to Remove, a second click 1.5 s on removes - timed by the clicks themselves' ($cp[11] -eq 'True' -and $cp[12] -eq 'True') "$conOut"
Check 'a running Claude job: Watch in VS Code beside Cancel, through the chip''s own Show-ChatFresh child, one at a time' ($cp.Count -gt 35 -and $cp[34] -eq 'True') "$($cp[35])"
Check 'Continue clicked twice queues one continue' ($cp[13] -eq 'True') "$($cp[16])"
Check 'the index is read in a runspace of its own, never on the window''s thread, and its rows taken when ready' ($cp[17] -eq 'True') "$($cp[18])"
Check 'a Codex chat is offered its Sandbox row but no mode or model, and is sent none' ($cp[14] -eq 'True' -and $cp[15] -eq 'True') "$conOut"

# the whole way round, as the user goes it: the panel, the console by its
# hotkey's verb, a draft typed, the theme switched, Esc, the panel; the
# console again with the draft still there, then a close, and the panel.
# Brought forward through the seam, so the test never takes the keyboard.
$flow = @"
$staLoad
`$script:ChatqSpawn = { `$true }
`$script:ChatConsoleNoSync = `$true
`$fr = @{ n = 0 }
`$script:ChatConsoleFrontSeam = { param(`$w) `$fr.n++ }
Initialize-ChatOverlayNative
`$H = New-ChatOverlayHostState
`$script:ChatOverlayHost = `$H
`$H.Ctx = New-ChatOverlayContext
`$H.Ctx.Config.theme = 'dark'
`$H.State = [pscustomobject]@{ x = `$null; y = `$null; locked = `$true; hidden = `$false }
New-ChatOverlayWindow `$H
`$snap = [pscustomobject]@{ header = [pscustomobject]@{ usage = @(); notes = @() }; counts = [pscustomobject]@{ queued = 0; running = 0; cutOff = 0 }; rows = @(
    [pscustomobject]@{ key = 's:$idCard'; kind = 'session'; status = 'idle'; chat = 'idle'; rank = 3; project = 'A'; title = 'Card'; stateText = 'idle 1m'; sessionId = '$idCard'; cwd = '$projA'; job = `$null; prompt = `$null }) }
`$script:ChatOverlayWorkAreaSeam = { param(`$r) [pscustomobject]@{ X = -4000; Y = 0; Width = 1920; Height = 1020 } }
Remove-Item -LiteralPath `$script:ChatConsoleStatePath -Force -EA SilentlyContinue
`$H.Placed = `$true
`$H.Ctx.ViewSig = 'flow'
`$H.Win.Show()
[ChatOverlayNative]::ApplyExStyle(`$H.Hwnd, `$H.Locked)
[ChatOverlayNative]::MoveTo(`$H.Hwnd, -2594, 197)
Update-ChatOverlayView `$H `$snap
Show-ChatOverlayControls `$H `$true
`$panelSays = {
    `$H.Win.UpdateLayout()
    `$x = [ChatOverlayNative]::GetExStyle(`$H.Hwnd) -band (0x8 -bor 0x20 -bor 0x80 -bor 0x40000 -bor 0x80000 -bor 0x8000000)
    "`$(`$H.Mode) `$(([ChatOverlayNative]::GetRect(`$H.Hwnd)) -join ',') `$(`$H.Win.Width) `$(`$H.Ctx.Config.maxRows) `$(`$H.Collapsed) `$x `$(`$H.Win.Topmost) `$(`$H.Win.Content -eq `$H.Frame) `$(`$H.Win.IsVisible) `$(`$H.Stack.Children.Count) `$(`$H.CtlWin.IsVisible)"
}
`$was = & `$panelSays
`$say = @()
# the console hotkey: the console, brought forward
Invoke-ChatOverlayVerb 'console-key'
`$C = `$H.Con
`$in1 = `$H.Mode -eq 'console' -and `$H.Win.Content -eq `$C.Root -and -not `$H.Win.Topmost -and `$fr.n -eq 1
# again while it is open but not the window in front: only forward again
Invoke-ChatOverlayVerb 'console-key'
`$in1 = `$in1 -and `$H.Mode -eq 'console' -and `$fr.n -eq 2
`$say += "in `$(`$H.Mode) `$(`$fr.n)"
# In front: chatconsole, the tray's item or the button - a command that
# may come a pass late - only bring it forward; the hotkey goes back to
# the panel as it was. The seam stands for a console with the keyboard.
`$script:ChatConsoleActiveSeam = { `$true }
Invoke-ChatOverlayVerb 'console'
`$cmdKept = `$H.Mode -eq 'console' -and `$fr.n -eq 3
Invoke-ChatOverlayVerb 'console-key'
`$afterKey = & `$panelSays
`$keyOk = `$cmdKept -and `$afterKey -eq `$was
`$script:ChatConsoleActiveSeam = `$null
Invoke-ChatOverlayVerb 'console-key'
`$keyOk = `$keyOk -and `$H.Mode -eq 'console' -and `$fr.n -eq 4
`$say += "key `$cmdKept [`$afterKey] `$(`$H.Mode) `$(`$fr.n)"
`$C.Prompt.Text = 'a draft that outlives it all'
`$H.Ctx.Config.theme = 'light'
Update-ChatOverlayTheme `$H
`$themed = `$H.Mode -eq 'console' -and `$H.Win.Content -eq `$C.Root -and `$C.Prompt.Text -eq 'a draft that outlives it all' -and `$C.Root.Background.Color.ToString() -eq '#FFF6F8FA'
`$say += "theme `$(`$H.Mode) '`$(`$C.Prompt.Text)'"
`$src = [System.Windows.PresentationSource]::FromVisual(`$H.Win)
`$kd = [System.Windows.Input.KeyEventArgs]::new([System.Windows.Input.Keyboard]::PrimaryDevice, `$src, 0, [System.Windows.Input.Key]::Escape)
`$kd.RoutedEvent = [System.Windows.Input.Keyboard]::PreviewKeyDownEvent
`$C.Prompt.RaiseEvent(`$kd)
`$afterEsc = & `$panelSays
`$escOk = `$afterEsc -eq `$was -and (Read-ChatConsoleState).draft.text -eq 'a draft that outlives it all'
Invoke-ChatOverlayVerb 'console'
`$back = `$H.Mode -eq 'console' -and `$C.Prompt.Text -eq 'a draft that outlives it all' -and `$fr.n -eq 5
`$say += "again `$(`$H.Mode) '`$(`$C.Prompt.Text)' `$(`$fr.n)"
`$H.Win.Close()
`$H.Win.Dispatcher.Invoke([Action] {}, [System.Windows.Threading.DispatcherPriority]::Background)
`$afterClose = & `$panelSays
`$closeOk = `$afterClose -eq `$was
# A loop of its own - the folder picker's, a DragMove - still takes the
# hotkeys and the tray: the window is not switched under it. A collapse
# waits for it to end; the console key, in front or not, is dropped.
Invoke-ChatOverlayVerb 'console-key'
`$n0 = `$fr.n
`$C.Modal = `$true
`$script:ChatConsoleActiveSeam = { `$true }
Invoke-ChatOverlayVerb 'collapse'
Invoke-ChatOverlayVerb 'console-key'
`$heldOk = `$H.Mode -eq 'console' -and -not `$H.Collapsed -and (@(`$H.Held) -join ',') -eq 'collapse' -and `$fr.n -eq `$n0
`$script:ChatConsoleActiveSeam = `$null
`$C.Modal = `$false
Invoke-ChatOverlayHeldVerbs `$H
`$heldOk = `$heldOk -and `$H.Mode -eq 'panel' -and `$H.Collapsed -and -not @(`$H.Held).Count
# a panel mid-drag does not turn into the console under the pointer
`$H.Dragging = `$true
Invoke-ChatOverlayVerb 'console-key'
Invoke-ChatOverlayVerb 'console'
`$heldOk = `$heldOk -and `$H.Mode -eq 'panel' -and `$H.Win.Content -eq `$H.Frame
`$H.Dragging = `$false
`$say += "held `$(`$H.Mode) `$(`$H.Collapsed) `$(`$fr.n)/`$n0"
'{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}' -f `$in1, `$themed, `$escOk, `$back, `$closeOk, `$keyOk, `$heldOk, ("`$(`$say -join ' / ') was [`$was] esc [`$afterEsc] close [`$afterClose]" -replace '\|', '/')
"@
$flowOut = Invoke-Sta 'flow-test' $flow
$fw = "$flowOut" -split '\|'
Check 'the way round: the console hotkey opens the console in the panel''s window and brings it forward, again only forward' ($fw[0] -eq 'True') "$flowOut"
Check 'the way round: a theme switch keeps the draft typed, in the console still' ($fw.Count -gt 1 -and $fw[1] -eq 'True') "$flowOut"
Check 'the way round: Esc brings the panel back as it was, the draft saved' ($fw.Count -gt 2 -and $fw[2] -eq 'True') "$flowOut"
Check 'the way round: the console again has the draft back' ($fw.Count -gt 3 -and $fw[3] -eq 'True') "$flowOut"
Check 'the way round: a close brings the panel back as it was, rows and all' ($fw.Count -gt 4 -and $fw[4] -eq 'True') "$flowOut"
Check 'the way round: on a console in front, chatconsole and the tray only bring it forward; the console hotkey goes back to the panel as it was' ($fw.Count -gt 5 -and $fw[5] -eq 'True') "$flowOut"
Check 'the way round: under the folder picker''s loop a collapse waits for it to end, the console key is dropped; a panel mid-drag stays the panel' ($fw.Count -gt 6 -and $fw[6] -eq 'True') "$flowOut"

# The panel's life: out of a full screen's way and back; closed by hand,
# kept against a synthetic sign-in and said in a balloon, the process 4 s
# on; a stop marks, a restart does not; and a code change restarts it on
# the timer's pass unless something is under way. The dispatcher's end is
# stood in for until the close's own timer runs it for real.
$wpfLife = @"
$staLoad
Initialize-ChatOverlayNative
$staPanel
`$script:ChatOverlayWorkAreaSeam = { param(`$r) [pscustomobject]@{ X = -4000; Y = 0; Width = 1920; Height = 1020 } }
`$H.Placed = `$true
Set-ChatOverlayHidden `$H `$false
[ChatOverlayNative]::MoveTo(`$H.Hwnd, -2594, 197)
`$say = @()
# a full screen: out of the way, nothing saved; back once it ends
`$full = @{ on = `$true }
`$script:ChatOverlayFullScreenSeam = { `$full.on }
Update-ChatOverlayFullScreen `$H
`$fsHid = -not `$H.Win.IsVisible -and `$H.FullHidden -and -not `$H.Hidden -and -not (Read-ChatOverlayState).hidden
`$full.on = `$false
Update-ChatOverlayFullScreen `$H
`$fsHid = `$fsHid -and `$H.Win.IsVisible -and -not `$H.FullHidden
# shown by hand during one: kept shown until it ends, out of the way again
# at the next
`$full.on = `$true
Update-ChatOverlayFullScreen `$H
Invoke-ChatOverlayVerb 'show'
Update-ChatOverlayFullScreen `$H
`$fsKept = `$H.Win.IsVisible -and `$H.FullKept -and -not `$H.FullHidden
`$full.on = `$false
Update-ChatOverlayFullScreen `$H
`$full.on = `$true
Update-ChatOverlayFullScreen `$H
`$fsKept = `$fsKept -and -not `$H.Win.IsVisible -and `$H.FullHidden -and -not `$H.FullKept
# hidden to the tray meanwhile: the tray's word holds, full screen or not
Set-ChatOverlayHidden `$H `$true
`$full.on = `$false
Update-ChatOverlayFullScreen `$H
`$fsKept = `$fsKept -and -not `$H.Win.IsVisible -and `$H.Hidden -and -not `$H.FullHidden
Set-ChatOverlayHidden `$H `$false
`$full.on = `$false
`$say += "full `$fsHid `$fsKept"
# the real call: its type compiled, and Windows' answer read - busy (2),
# full screen (3) and presentation (4) hold the screen; no answer (0), not
# present (1), accepting (5), quiet time (6) and a Store app (7) do not
`$fsType = 'ChatOverlayFullScreen' -as [type]
`$fsNow = if (`$fsType) { `$fsType::State() } else { -1 }
`$fsMap = (@(0..7 | ForEach-Object { [int](Test-ChatOverlayFullScreenState `$_) }) -join '')
`$fsNative = `$null -ne `$fsType -and `$fsNow -ge 0 -and `$fsNow -le 7 -and `$fsMap -eq '00111000'
`$say += "native `$(`$null -ne `$fsType) state `$fsNow map `$fsMap"
# a stop marks the close against this sign-in, a restart does not; no
# sign-in known, the x stops at once with nothing said
`$sdFn = `${function:Stop-ChatOverlayDispatcher}
`$script:SdCalls = 0
`${function:Stop-ChatOverlayDispatcher} = { param(`$X) `$script:SdCalls++ }
`$said = [System.Collections.Generic.List[object]]::new()
`$script:ChatOverlayBalloonSeam = { param(`$b) `$said.Add(`$b) }
`$script:ChatqSignInSeam = { 1700000000000 }
Clear-ChatOverlayClosed `$H.State
Invoke-ChatOverlayVerb 'restart'
`$marks = `$null -eq (Read-ChatOverlayState).closedSignIn -and `$H.Restart
Invoke-ChatOverlayVerb 'stop'
`$marks = `$marks -and [int64](Read-ChatOverlayState).closedSignIn -eq 1700000000000 -and `$H.Stop -and `$script:SdCalls -eq 2
Clear-ChatOverlayClosed `$H.State
`$script:ChatqSignInSeam = { `$null }
`$H.Stop = `$false
Invoke-ChatOverlayVerb 'close'
`$marks = `$marks -and `$H.Stop -and -not `$H.Closing -and `$said.Count -eq 0 -and `$H.Win.IsVisible -and `$script:SdCalls -eq 3 -and `$null -eq (Read-ChatOverlayState).closedSignIn
`$H.Stop = `$false
`$H.Restart = `$false
`$say += "marks `$marks `$(`$script:SdCalls)"
# the code on disk changed: a restart on the timer's pass - not while an
# edge is being dragged, nor with the console up
`$script:ChatOverlayFullScreenSeam = { `$false }
`$csFn = `${function:Get-ChatOverlayCodeStamp}
`${function:Get-ChatOverlayCodeStamp} = { 'new' }
`$H.Ctx.CodeStamp = 'old'
`$H.Ctx.CodeSeen = 'new'
`$H.Ctx.CodeSeenAt = (Get-Date).AddMinutes(-1)
`$under = -not (Test-ChatOverlayUnderWay `$H)
`$H.SizeDrag = @{ Edge = 'n' }
`$under = `$under -and (Test-ChatOverlayUnderWay `$H)
# and the heap compacted on the first pass past its time, then never again
`$hcFn = `${function:Invoke-ChatOverlayHeapCompact}
`$script:HcCalls = 0
`${function:Invoke-ChatOverlayHeapCompact} = { `$script:HcCalls++ }
`$H.CompactAt = (Get-Date).AddMinutes(1)
`$H.Tick = 1
Invoke-ChatOverlayTick
`$under = `$under -and -not `$H.Restart -and `$H.Tick -eq 2
`$compact = `$script:HcCalls -eq 0 -and `$null -ne `$H.CompactAt
`$H.CompactAt = (Get-Date).AddSeconds(-1)
`$H.SizeDrag = `$null
`$H.Mode = 'console'
`$under = `$under -and (Test-ChatOverlayUnderWay `$H)
`$H.Mode = 'panel'
`$H.PendingRows = 9
`$under = `$under -and (Test-ChatOverlayUnderWay `$H)
`$H.PendingRows = `$null
# out of a full screen's way: the new process would show over it
`$H.FullHidden = `$true
`$under = `$under -and (Test-ChatOverlayUnderWay `$H)
`$H.FullHidden = `$false
`$H.Tick = 1
Invoke-ChatOverlayTick
`$restarted = `$under -and `$H.Restart -and `$script:SdCalls -eq 4
`$compact = `$compact -and `$script:HcCalls -eq 1 -and `$null -eq `$H.CompactAt
`${function:Invoke-ChatOverlayHeapCompact} = `$hcFn
`${function:Get-ChatOverlayCodeStamp} = `$csFn
`$H.Restart = `$false
`$say += "code `$under `$(`$H.Restart) `$(`$script:SdCalls) compact `$(`$script:HcCalls)"
# The x, then its 4 s: what acts on the panel is dropped, and so is any
# other balloon; the hotkey takes the close back - shown, nothing kept, the
# stop called off, the panel not unlocked; a restart is the stop, the close
# kept, so no new process lifts it. No command is left over from the tests
# before: the close's timer reads them.
Remove-Item -LiteralPath `$script:ChatOverlayCmdPath -Force -EA SilentlyContinue
`$script:ChatqSignInSeam = { 1700000000000 }
`$said.Clear()
`$lk0 = `$H.Locked
`$co0 = `$H.Collapsed
Invoke-ChatOverlayVerb 'close'
`$back = `$H.Closing -and -not `$H.Win.IsVisible -and [int64](Read-ChatOverlayState).closedSignIn -eq 1700000000000 -and `$said.Count -eq 1 -and `$said[0].Kind -eq 'close'
Invoke-ChatOverlayVerb 'unlock'
Invoke-ChatOverlayVerb 'collapse'
Invoke-ChatOverlayVerb 'hide'
Invoke-ChatOverlayVerb 'close'
Show-ChatOverlayBalloon `$H 'another word'
`$back = `$back -and `$H.Closing -and `$H.Locked -eq `$lk0 -and `$H.Collapsed -eq `$co0 -and -not `$H.Hidden -and `$H.Mode -eq 'panel' -and
    -not `$H.Win.IsVisible -and `$said.Count -eq 1 -and `$script:SdCalls -eq 4
Invoke-ChatOverlayVerb 'hotkey'
`$back = `$back -and -not `$H.Closing -and `$H.Win.IsVisible -and `$null -eq (Read-ChatOverlayState).closedSignIn -and `$null -eq `$H.CloseTimer -and
    `$H.Locked -eq `$lk0 -and `$script:SdCalls -eq 4
Invoke-ChatOverlayVerb 'close'
Invoke-ChatOverlayVerb 'restart'
`$back = `$back -and `$H.Stop -and -not `$H.Restart -and [int64](Read-ChatOverlayState).closedSignIn -eq 1700000000000 -and `$script:SdCalls -eq 5
`$H.CloseTimer.Stop()
`$H.CloseTimer = `$null
`$H.Closing = `$false
`$H.Stop = `$false
Clear-ChatOverlayClosed `$H.State
Set-ChatOverlayShown `$H `$true
`$say += "back `$back"
# chatoverlay typed in the 4 s, after the last pass that would read it:
# the close's timer reads the commands once more, and the show takes it
# back rather than the overlay going under the word "shown"
`$said.Clear()
Invoke-ChatOverlayVerb 'close'
Send-ChatOverlayCommand 'show'
`$script:LifeFrame = [System.Windows.Threading.DispatcherFrame]::new()
`$script:LifeT0 = Get-Date
`$poll = [System.Windows.Threading.DispatcherTimer]::new()
`$poll.Interval = [TimeSpan]::FromMilliseconds(250)
`$poll.add_Tick({ param(`$s, `$e) if (-not `$script:ChatOverlayHost.Closing -or ((Get-Date) - `$script:LifeT0).TotalSeconds -gt 14) { `$s.Stop(); `$script:LifeFrame.Continue = `$false } })
`$poll.Start()
[System.Windows.Threading.Dispatcher]::PushFrame(`$script:LifeFrame)
`$lateTook = ((Get-Date) - `$script:LifeT0).TotalSeconds
`$late = -not `$H.Closing -and -not `$H.Stop -and `$H.Win.IsVisible -and `$null -eq (Read-ChatOverlayState).closedSignIn -and `$script:SdCalls -eq 5 -and `$lateTook -ge 3.5 -and `$lateTook -lt 14
`$say += "late `$late `$([Math]::Round(`$lateTook, 1))s"
# the x, the sign-in known: kept, said, the panel gone at once; the
# process stopped 4 s on, by the close's timer
`${function:Stop-ChatOverlayDispatcher} = `$sdFn
`$said.Clear()
`$t0 = Get-Date
Invoke-ChatOverlayVerb 'close'
`$closed = `$H.Closing -and -not `$H.Win.IsVisible -and -not `$H.Stop -and [int64](Read-ChatOverlayState).closedSignIn -eq 1700000000000 -and
    `$said.Count -eq 1 -and `$said[0].Text -like 'Closed until you next sign in*chatoverlay*'
`$guard = [System.Windows.Threading.DispatcherTimer]::new()
`$guard.Interval = [TimeSpan]::FromSeconds(15)
`$guard.add_Tick({ param(`$s, `$e) `$s.Stop(); [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvokeShutdown('Normal') })
`$guard.Start()
[System.Windows.Threading.Dispatcher]::Run()
`$took = ((Get-Date) - `$t0).TotalSeconds
`$closed = `$closed -and `$H.Stop -and `$H.ShuttingDown -and `$took -ge 3.5 -and `$took -lt 14
`$say += "close `$closed `$([Math]::Round(`$took, 1))s"
'{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}' -f `$fsHid, `$fsKept, `$marks, `$restarted, `$closed, `$fsNative, `$back, `$late, `$compact, (`$say -join ' / ')
"@
$lifeOut = Invoke-Sta 'life-test' $wpfLife
$lf = "$lifeOut" -split '\|'
Check 'a full screen app or presentation: the panel out of its way, nothing saved, and back once it ends' ($lf[0] -eq 'True') "$lifeOut"
Check 'shown by hand during a full screen, it stays until that ends; hidden to the tray, the tray''s word holds' ($lf.Count -gt 1 -and $lf[1] -eq 'True') "$lifeOut"
Check 'a stop marks the close against this sign-in, a restart does not; no sign-in known, the x stops at once and keeps nothing' ($lf.Count -gt 2 -and $lf[2] -eq 'True') "$lifeOut"
Check 'the code on disk changed: the timer''s pass restarts the overlay, but not mid-drag, with the console up, a slider not at rest or a full screen holding it off' ($lf.Count -gt 3 -and $lf[3] -eq 'True') "$lifeOut"
Check 'the x: kept against this sign-in, said in a balloon, the panel gone at once, the process stopped 4 s on' ($lf.Count -gt 4 -and $lf[4] -eq 'True') "$lifeOut"
Check 'full screen: the native call compiles and answers 0 to 7; busy, full screen and presentation hold the screen, nothing else does' ($lf.Count -gt 5 -and $lf[5] -eq 'True') "$lifeOut"
Check 'the x''s 4 s: the panel''s verbs and other balloons dropped; the hotkey takes the close back, unkept; a restart is the stop, the close kept' ($lf.Count -gt 6 -and $lf[6] -eq 'True') "$lifeOut"
Check 'the x''s 4 s: a chatoverlay typed after the last pass is read as they end, and takes the close back' ($lf.Count -gt 7 -and $lf[7] -eq 'True') "$lifeOut"
Check 'the heap compacted by the first pass past its time, not before, and never again' ($lf.Count -gt 8 -and $lf[8] -eq 'True') "$lifeOut"

# The compaction itself, on a heap like the one a start leaves: big buffers
# freed between ones still held, which a collection never moves. What was
# freed is given back, and the log says how much. In a process of its own,
# its heap the test's alone.
$heapTest = @"
$staLoad
`$log = Join-Path `$script:ChatqLogDir 'overlay.log'
`$said = { @(if (Test-Path -LiteralPath `$log) { [System.IO.File]::ReadAllLines(`$log) | Where-Object { `$_ -match '  the heap compacted in \d+ ms: private \d+ MB, then \d+`$' } }).Count }
`$n0 = & `$said
`$held = [System.Collections.Generic.List[object]]::new()
`$gone = [System.Collections.Generic.List[object]]::new()
foreach (`$i in 1..64) { `$gone.Add([byte[]]::new(1MB)); `$held.Add([byte[]]::new(100KB)) }
`$gone.Clear()
[System.GC]::Collect()
`$p = [System.Diagnostics.Process]::GetCurrentProcess()
`$was = `$p.PrivateMemorySize64
Invoke-ChatOverlayHeapCompact
`$p.Refresh()
`$drop = [Math]::Round((`$was - `$p.PrivateMemorySize64) / 1MB)
`$n1 = & `$said
'{0}|{1}' -f (`$drop -ge 32 -and `$n1 -eq `$n0 + 1 -and `$held.Count -eq 64), "given back `$drop MB, logged `$n0 > `$n1"
"@
$heapOut = Invoke-Sta 'heap-test' $heapTest
Check 'the heap compacted: 64 MB of big buffers freed between ones held, given back, and said in the log' ("$heapOut" -like 'True|*') "$heapOut"

# A tick that throws past its catch, as an out-of-memory once did, in the
# hover timer's place and every time: set going again after each throw.
# The 1 s timer's place, slower and stopping itself on its second tick: not
# held back by the other's throws, and once stopped, left so through five
# more of them. Shorter times than the overlay's, the same shape.
$uiTest = @"
$staLoad
Add-Type -AssemblyName WindowsBase
`$log = Join-Path `$script:ChatqLogDir 'overlay.log'
`$said = { @(if (Test-Path -LiteralPath `$log) { [System.IO.File]::ReadAllLines(`$log) | Where-Object { `$_ -match '  ui: .*a tick that threw' } }).Count }
`$n0 = & `$said
`$global:Throws = 0
`$global:Ticks = 0
`$global:ThrowsAtStop = 0
`$quick = [System.Windows.Threading.DispatcherTimer]::new()
`$quick.Interval = [TimeSpan]::FromMilliseconds(40)
`$quick.add_Tick({ `$global:Throws++; throw 'a tick that threw' })
`$slow = [System.Windows.Threading.DispatcherTimer]::new()
`$slow.Interval = [TimeSpan]::FromMilliseconds(150)
`$slow.add_Tick({ param(`$s) `$global:Ticks++; if (`$global:Ticks -eq 2) { `$s.Stop(); `$global:ThrowsAtStop = `$global:Throws } })
`$script:ChatOverlayHost = @{ Timer = `$slow; HoverTimer = `$quick }
Register-ChatOverlayUiCatch ([System.Windows.Threading.Dispatcher]::CurrentDispatcher)
`$quick.Start()
`$slow.Start()
`$frame = [System.Windows.Threading.DispatcherFrame]::new()
`$clock = [System.Diagnostics.Stopwatch]::StartNew()
`$end = [System.Windows.Threading.DispatcherTimer]::new()
`$end.Interval = [TimeSpan]::FromMilliseconds(50)
`$end.add_Tick({
        param(`$s)
        if ((`$global:Ticks -ge 2 -and `$global:Throws -ge `$global:ThrowsAtStop + 5) -or `$clock.Elapsed.TotalSeconds -gt 5) { `$s.Stop(); `$frame.Continue = `$false }
    })
`$end.Start()
[System.Windows.Threading.Dispatcher]::PushFrame(`$frame)
`$quick.Stop()
`$n1 = & `$said
'{0}|{1}' -f (`$global:Ticks -eq 2 -and -not `$slow.IsEnabled -and `$global:Throws -ge `$global:ThrowsAtStop + 5 -and `$n1 -eq `$n0 + 1), "throws `$global:Throws (`$global:ThrowsAtStop at the stop), ticks `$global:Ticks, running `$(`$slow.IsEnabled), logged `$n0 > `$n1, `$([Math]::Round(`$clock.Elapsed.TotalSeconds, 1)) s"
"@
$uiOut = Invoke-Sta 'ui-catch-test' $uiTest
Check 'a tick that threw past its catch: its timer set going again each time, the other neither held back by it nor started again once stopped, and said in the log' ("$uiOut" -like 'True|*') "$uiOut"

# A process that loaded an older copy of the script keeps that copy's
# ChatOverlayNative, which has no ApplyInteractiveStyle or DropTopmost: one
# such is compiled first here, then the console opened through the
# ChatOverlayNativeNext Initialize-ChatOverlayNative compiles beside it
$oldNative = @"
$staLoad
`$script:ChatqSpawn = { `$true }
`$script:ChatConsoleNoSync = `$true
`$oldCode = `$script:ChatOverlayNativeCode -replace '(?s)\n    // [^\n]*\n(    // [^\n]*\n)*    public static void (ApplyInteractiveStyle|DropTopmost)\(IntPtr h\) \{.*?\n    \}', ''
Add-Type -TypeDefinition `$oldCode -ReferencedAssemblies System.Windows.Forms
`$wasOld = -not [ChatOverlayNative].GetMethod('ApplyInteractiveStyle') -and -not [ChatOverlayNative].GetMethod('DropTopmost')
Initialize-ChatOverlayNative
`$next = [string]`$script:ChatOverlayModeNative.Name
$staPanel
`$snap = [pscustomobject]@{ header = [pscustomobject]@{ usage = @(); notes = @() }; counts = [pscustomobject]@{ queued = 0; running = 0; cutOff = 0 }; rows = @(
    [pscustomobject]@{ key = 's:$idCard'; kind = 'session'; status = 'idle'; chat = 'idle'; rank = 3; project = 'A'; title = 'Card'; stateText = 'idle 1m'; sessionId = '$idCard'; cwd = '$projA'; job = `$null; prompt = `$null }) }
`$script:ChatOverlayWorkAreaSeam = { param(`$r) [pscustomobject]@{ X = -4000; Y = 0; Width = 1920; Height = 1020 } }
Remove-Item -LiteralPath `$script:ChatConsoleStatePath -Force -EA SilentlyContinue
`$H.Placed = `$true
`$H.Ctx.ViewSig = 'old'
`$H.Win.Show()
[ChatOverlayNative]::ApplyExStyle(`$H.Hwnd, `$H.Locked)
[ChatOverlayNative]::MoveTo(`$H.Hwnd, -2594, 197)
Update-ChatOverlayView `$H `$snap
Enter-ChatOverlayConsoleMode `$H
`$ex = [ChatOverlayNative]::GetExStyle(`$H.Hwnd)
`$inOk = `$H.Mode -eq 'console' -and -not (`$ex -band 0x20) -and -not (`$ex -band 0x8000000) -and -not (`$ex -band 0x80) -and [bool](`$ex -band 0x40000) -and -not (`$ex -band 0x8)
Exit-ChatOverlayConsoleMode `$H
`$ex2 = [ChatOverlayNative]::GetExStyle(`$H.Hwnd)
`$outOk = `$H.Mode -eq 'panel' -and [bool](`$ex2 -band 0x80) -and [bool](`$ex2 -band 0x8) -and -not (`$ex2 -band 0x40000)
# the types not there yet came in one compile of their own all the same
`$one = ('ChatProcTable' -as [type])
`$joint = `$one -and -not @('ChatOverlayFullScreen', 'ChatProcSnap', 'ChatCodeWindows', 'ChatCodeWindowList' | Where-Object { (`$_ -as [type]).Assembly -ne `$one.Assembly }).Count -and
    `$one.Assembly -ne [ChatOverlayNative].Assembly
Invoke-ChatOverlayVerb 'stop'
'{0}|{1}|{2}' -f (`$wasOld -and `$next -eq 'ChatOverlayNativeNext' -and `$inOk -and `$outOk), `$joint, "old `$wasOld mode `$next in `$inOk (`$ex) out `$outOk (`$ex2) joint `$joint"
"@
$oldOut = Invoke-Sta 'old-native-test' $oldNative
$on = "$oldOut" -split '\|'
Check 'a process holding an older ChatOverlayNative opens the console through ChatOverlayNativeNext: interactive, on the taskbar, not on top, and back to the panel' ($on[0] -eq 'True') "$oldOut"
Check 'and the types it did not hold yet came in one compile beside the old one' ($on.Count -gt 1 -and $on[1] -eq 'True') "$oldOut"
# that compile's source: each using line once, all of them first - C# takes
# none after a type - then each source's rest in turn
$jtSrc = Join-ChatTypeCode @("using System;`r`nusing System.Text;`r`npublic class A { }", "using System;`nusing System.IO;`npublic class B { }")
Check 'one compile of many C# sources: each using line once and all of them first, then each source in turn' (
    $jtSrc -eq "using System;`nusing System.Text;`nusing System.IO;`npublic class A { }`npublic class B { }") $jtSrc
# A pointer check far from the panel, nothing under way, does only what it
# must: the pointer off, and no zone worked out; a slider not at rest gets
# the whole check, and every fifth tick places the bar. The rows' rects are
# kept until the panel moves, they are drawn anew or the reset time above
# them takes a line off. Every type the overlay compiles came in one
# compile - the front's left out in a test run. In a process of its own: a
# type compiles once a process.
$wpfQuick = @"
$staLoad
# no mouse button held and the pointer far off, whatever the real mouse's
`$script:ChatOverlayMouseDownSeam = { `$false }
`$script:ChatOverlayPointerSeam = { [System.Drawing.Point]::new(-100000, -100000) }
`$cfgWas = [IO.File]::ReadAllText(`$script:ChatqConfigPath)
Set-ChatOverlayConfig @{ width = 380; maxRows = 8; prompts = `$true; recent = 0; hotkey = 'none'; consoleHotkey = 'none'; usageView = 'lines' }
Initialize-ChatOverlayNative
`$asm = [ChatOverlayNative].Assembly
`$typesOk = -not @('ChatOverlayHotkey', 'ChatOverlayFullScreen', 'ChatProcSnap', 'ChatProcTable', 'ChatCodeWindows', 'ChatCodeWindowList' | Where-Object { -not (`$_ -as [type]) -or (`$_ -as [type]).Assembly -ne `$asm }).Count -and
    `$null -eq ('ChatOverlayFront' -as [type]) -and `$env:CHATQ_NOFRONT -eq '1'
$staPanel
`$H.Placed = `$true
# well left of every screen, so the panel shows on none
`$farX = [int](@([System.Windows.Forms.Screen]::AllScreens | ForEach-Object { `$_.Bounds.X }) | Measure-Object -Minimum).Minimum - 5000
`$script:ChatOverlayWorkAreaSeam = { param(`$r) [pscustomobject]@{ X = `$farX - 1000; Y = 0; Width = 1920; Height = 1020 } }
Set-ChatOverlayHidden `$H `$false
[ChatOverlayNative]::MoveTo(`$H.Hwnd, `$farX, 197)
`$qRow = { param(`$k, `$t) [pscustomobject]@{ key = `$k; kind = 'session'; status = 'idle'; rank = 3; project = 'p'; title = `$t; prompt = 'x'; stateText = 'idle 1m'; job = `$null } }
`$qSnap = { param(`$a, `$b) [pscustomobject]@{ header = [pscustomobject]@{ usage = @(); notes = @() }; counts = [pscustomobject]@{ idle = 2 }; rows = @((& `$qRow 's:q1' `$a), (& `$qRow 's:q2' `$b)) } }
`$H.Ctx.ViewSig = 'quick'
Update-ChatOverlayView `$H (& `$qSnap 'one' 'two')
`$H.Win.UpdateLayout()
# the rows' rects: the same ones again, until the panel moves or is drawn anew
`$r1 = @(Get-ChatOverlayRowRects `$H)
`$r2 = @(Get-ChatOverlayRowRects `$H)
`$kept = `$r1.Count -eq 2 -and [object]::ReferenceEquals(`$r1[0], `$r2[0]) -and `$r1[0].Rect[2] -gt 0
[ChatOverlayNative]::MoveTo(`$H.Hwnd, `$farX + 40, 197)
`$r3 = @(Get-ChatOverlayRowRects `$H)
`$moved = `$r3.Count -eq 2 -and -not [object]::ReferenceEquals(`$r1[0], `$r3[0]) -and `$r3[0].Rect[0] -eq `$r1[0].Rect[0] + 40 -and `$r3[0].Rect[1] -eq `$r1[0].Rect[1]
`$H.Ctx.ViewSig = 'quick again'
Update-ChatOverlayView `$H (& `$qSnap 'uno' 'dos')
`$cleared = `$null -eq `$H.RowRects
`$H.Win.UpdateLayout()
`$r4 = @(Get-ChatOverlayRowRects `$H)
`$rectsOk = `$kept -and `$moved -and `$cleared -and `$r4.Count -eq 2 -and `$r4[0].Row.title -eq 'uno' -and `$r4[1].Row.title -eq 'dos'
# far off: the pointer only marked off - nothing worked out, the rest and
# the chip's row let go; a slider not at rest - and not about to be, so no
# slow moment here saves it - gets the whole check, the
# bar's place worked out once for its zone and its placing both - twice
# where the bar's width is behind the panel's, the first from before it.
# Behind, not the panel resized: that places the bar at once, by its
# SizeChanged, before any check.
`$tFn = `${function:Get-ChatOverlayControlsTarget}
`$script:TargetCalls = 0
`${function:Get-ChatOverlayControlsTarget} = { param(`$H, `$Dip) `$script:TargetCalls++; & `$tFn `$H `$Dip }
`$H.EnterAt = Get-Date
`$H.ChipUnder = 's:q1'
`$H.ChipUnderAt = Get-Date
Update-ChatOverlayHover
`$t0 = `$script:TargetCalls
`$farOk = `$t0 -eq 0 -and `$null -eq `$H.EnterAt -and `$H.ChipUnder -eq '' -and `$null -eq `$H.ChipUnderAt -and "`$(`$H.ChipLastPos)" -match '^-?\d+,-?\d+`$'
`$H.PendingOpacity = 0.8
`$H.PendingAt = (Get-Date).AddSeconds(5)
Update-ChatOverlayHover
`$t1 = `$script:TargetCalls - `$t0
`$wWas = `$H.Controls.Width
`$H.Controls.Width = `$wWas + 40
`$tb = `$script:TargetCalls
Update-ChatOverlayHover
`$t2 = `$script:TargetCalls - `$tb
`$farOk = `$farOk -and `$t1 -eq 1 -and `$t2 -eq 2 -and `$H.Controls.Width -eq `$wWas
`$H.PendingOpacity = `$null
`${function:Get-ChatOverlayControlsTarget} = `$tFn
Set-ChatOverlayControlsPlacement `$H
# every fifth tick places the bar - not mid-drag by it
`$script:ChatOverlayFullScreenSeam = { `$false }
`$pcFn = `${function:Set-ChatOverlayControlsPlacement}
`$script:PlaceCalls = 0
`${function:Set-ChatOverlayControlsPlacement} = { param(`$H, `$Dip) `$script:PlaceCalls++ }
`$H.GripDrag = @{ Mx = 0; My = 0; X = `$farX; Y = 197 }
`$H.Tick = 4
Invoke-ChatOverlayTick
`$p0 = `$script:PlaceCalls
`$H.GripDrag = `$null
`$H.SizeDrag = @{}
`$H.Tick = 4
Invoke-ChatOverlayTick
`$p1 = `$script:PlaceCalls
`$H.SizeDrag = `$null
`$H.Tick = 4
Invoke-ChatOverlayTick
`$tickOk = `$H.ControlsShown -and `$H.Tick -eq 5 -and `$p0 -eq 0 -and `$p1 -eq 0 -and `$script:PlaceCalls -eq 1
`${function:Set-ChatOverlayControlsPlacement} = `$pcFn
# The reset time after a percent, set in place, takes a line off the usage
# line as it goes: in a panel at its cap - its floor of about one row, the
# screen's foot right under its top - the rows move up with the panel's
# size the same, and their rects are worked out again. The time is made
# long enough to wrap at any width or font.
`$script:ChatOverlayWorkAreaSeam = { param(`$r) [pscustomobject]@{ X = `$farX - 1000; Y = 0; Width = 1920; Height = 217 } }
`$u = [pscustomobject]@{ provider = 'Claude'; stale = `$false; status = 'now'; windows = @(
        [pscustomobject]@{ label = '5h'; percent = 42; limited = `$false; severity = 'normal'; resetsAt = (ConvertTo-ChatOverlayMs ((Get-Date).AddHours(2))) }) }
`$uSnap = [pscustomobject]@{ header = [pscustomobject]@{ usage = @(`$u); notes = @() }; counts = [pscustomobject]@{ idle = 2 }; rows = @((& `$qRow 's:q1' 'one'), (& `$qRow 's:q2' 'two')) }
`$H.Ctx.ViewSig = 'quick capped'
Update-ChatOverlayView `$H `$uSnap
`$H.Clocks[0].Block.Text = ' resets' + (' 21:44' * 40)
`$H.Win.UpdateLayout()
`$c1 = @(Get-ChatOverlayRowRects `$H)
`$cHeld = `$null -ne `$H.RowRects
`$cKey = "`$(@([ChatOverlayNative]::GetRect(`$H.Hwnd)) -join ',')|`$(`$H.Win.ActualWidth)|`$(`$H.Win.ActualHeight)"
`$H.Clocks[0].At = ConvertTo-ChatOverlayMs ((Get-Date).AddMinutes(-1))
Update-ChatOverlayView `$H `$uSnap
`$H.Win.UpdateLayout()
`$c2 = @(Get-ChatOverlayRowRects `$H)
`$cSame = `$cKey -eq "`$(@([ChatOverlayNative]::GetRect(`$H.Hwnd)) -join ',')|`$(`$H.Win.ActualWidth)|`$(`$H.Win.ActualHeight)"
`$H.RowRects = `$null
`$c3 = @(Get-ChatOverlayRowRects `$H)
`$shiftOk = `$cHeld -and `$cSame -and `$H.Clocks[0].Block.Text -eq '' -and `$c1.Count -ge 1 -and `$c2.Count -eq `$c1.Count -and `$c3.Count -eq `$c1.Count -and
    `$c2[0].Rect[1] -lt `$c1[0].Rect[1] -and (`$c2[0].Rect -join ',') -eq (`$c3[0].Rect -join ',') -and (`$c2[0].Line -join ',') -eq (`$c3[0].Line -join ',')
[IO.File]::WriteAllText(`$script:ChatqConfigPath, `$cfgWas)
'{0}|{1}|{2}|{3}|{4}|{5}' -f `$typesOk, `$rectsOk, `$farOk, `$tickOk, `$shiftOk,
    "types `$typesOk rects `$kept/`$moved/`$cleared `$(@(`$r4 | ForEach-Object { `$_.Row.title }) -join ',') at `$(`$r1[0].Rect -join ',') > `$(`$r3[0].Rect -join ',') far `$t0/`$t1/`$t2 '`$(`$H.ChipUnder)' `$(`$H.ChipLastPos) tick `$(`$H.Tick) `$p0/`$p1/`$(`$script:PlaceCalls) shift `$cHeld/`$cSame '`$(`$H.Clocks[0].Block.Text)' `$(`$c1[0].Rect -join ',') > `$(`$c2[0].Rect -join ',') fresh `$(`$c3[0].Rect -join ',')"
"@
$quickOut = Invoke-Sta 'quick-test' $wpfQuick
$qk = "$quickOut" -split '\|'
Check 'one compile at the start for every type the overlay uses: one assembly, the front''s type left out in a test run' ($qk[0] -eq 'True') "$quickOut"
Check 'the rows'' rects kept: the same until the panel moves - then moved with it - or the rows are drawn anew' ($qk.Count -gt 1 -and $qk[1] -eq 'True') "$quickOut"
Check 'a pointer check far from the panel only marks it off, nothing worked out; a slider not at rest gets the whole check, the bar''s place worked out once for it - again where the bar''s width was behind the panel''s' ($qk.Count -gt 2 -and $qk[2] -eq 'True') "$quickOut"
Check 'every fifth tick places the bar over the panel, not mid-drag or mid-resize by it' ($qk.Count -gt 3 -and $qk[3] -eq 'True') "$quickOut"
Check 'the rows'' rects worked out again as the reset time takes a line off the usage line, in a panel at its cap whose size stays' ($qk.Count -gt 4 -and $qk[4] -eq 'True') "$quickOut"
# a compile that fails takes nothing down: said in the log, and each type
# then comes in on its own - the panel's at once, the rest where used
$typesBroken = @"
$staLoad
`$script:ChatProcSnapCode = `$script:ChatProcSnapCode.Replace('return found.ToArray();', 'return found.ToArray()')
Initialize-ChatOverlayNative
`$log = [IO.File]::ReadAllText((Join-Path `$script:ChatqLogDir 'overlay.log'))
`$alone = ('ChatOverlayNative' -as [type]) -and ('ChatOverlayFullScreen' -as [type]) -and [ChatOverlayFullScreen].Assembly -ne [ChatOverlayNative].Assembly -and
    `$null -eq ('ChatProcSnap' -as [type]) -and `$null -eq ('ChatProcTable' -as [type])
`$table = Get-ChatProcessTable
# from Windows' own list, compiled on its own - not the Win32_Process query
# it falls back on
`$own = ('ChatProcTable' -as [type]) -and `$null -ne [ChatProcTable]::List()
'{0}|{1}' -f (`$alone -and `$log -match 'the types in one compile: ' -and `$table -and `$table[`$PID] -and `$own), "alone `$alone logged `$(`$log -match 'the types in one compile: ') table `$(if (`$table) { `$table.Count }) own `$own"
"@
$brokenOut = Invoke-Sta 'types-broken-test' $typesBroken
Check 'a compile of them all that fails is logged, and each type then comes in on its own: the panel''s at once, the process list where it is used' (
    ("$brokenOut" -split '\|')[0] -eq 'True') "$brokenOut"
$script:ChatOverlayUsageSeam = $null
$script:ChatqAliveSeam = $null
Remove-Item -LiteralPath $sessDir -Recurse -Force -EA SilentlyContinue
