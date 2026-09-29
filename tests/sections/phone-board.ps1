# tests/sections/phone-board.ps1: dot-sourced by tests/run-tests.ps1 in its
# turn, never on its own - it uses what the runner and the sections before it set.
#
# The PC -> phone channel and the phone's board (src/phone-down.ps1,
# src/phone-board.ps1, docs/phone-board-spec.md): the wire format against
# Node's own crypto and zlib, the whole answer read from a transcript and a
# job's log, the down topic's POST and PUT through $script:ChatqDownSeam,
# the whole answer riding ahead of an alert's push, and the phone's acts -
# sealed as the page seals them, fed to Invoke-ChatqReplyPoll through the
# poll seam. A phone is paired here by writing its key; no Join, ntfy or
# down traffic leaves. Everything changed is put back at the end.

Section 'phone board'
$bdCfgWas = if (Test-Path -LiteralPath $script:ChatqConfigPath) { [System.IO.File]::ReadAllText($script:ChatqConfigPath, $utf8) } else { $null }
$bdWas = @{ Join = $script:ChatqJoinSeam; Poll = $script:ChatqReplyPollSeam; Down = $script:ChatqDownSeam; Spawn = $script:ChatqSpawn; Alive = $script:ChatqAliveSeam }
$bdJobsBefore = @(Get-ChatqJobs | ForEach-Object { [string]$_.id })
$script:BdOrder = [System.Collections.Generic.List[string]]::new()
$script:BdJoins = [System.Collections.Generic.List[string]]::new()
$script:ChatqJoinSeam = { param($u) $script:BdJoins.Add($u); $script:BdOrder.Add('join'); $null }
$script:BdDown = [System.Collections.Generic.List[object]]::new()
$script:BdDownFail = $null
$script:ChatqDownSeam = {
    param($m, $u, $h, $b)
    $script:BdOrder.Add('down')
    if ($script:BdDownFail) { $e = & $script:BdDownFail $m; if ($e) { return $e } }
    $script:BdDown.Add([pscustomobject]@{ Method = $m; Url = $u; Headers = $h; Body = $b })
    $null
}
$script:BdFeed = ''
$script:ChatqReplyPollSeam = { param($u) $script:BdFeed }
$script:BdSpawns = 0
$script:ChatqSpawn = { $script:BdSpawns++; $true }
$script:ChatqReplySeen = @{}; $script:ChatqReplyHandled = @{}; $script:ChatqReplyJunkLog = @{}
$script:ChatqBoardCache = $null
Remove-Item -LiteralPath $script:ChatqReplyPath -Force -EA SilentlyContinue

# --- the wire format, against Node's crypto and zlib ---------------------------------
# tests/fixtures/down-vector.json and compose-vector.json, made by
# tests/fixtures/make-down-vector.js; tests/board-page-check.js holds the page
# to the same two files
$dv = [System.IO.File]::ReadAllText((Join-Path (Join-Path $here 'fixtures') 'down-vector.json'), $utf8) | ConvertFrom-Json
$cv = [System.IO.File]::ReadAllText((Join-Path (Join-Path $here 'fixtures') 'compose-vector.json'), $utf8) | ConvertFrom-Json
$dvMaster = ConvertFrom-ChatqB64Url $dv.master
$dvMsg = Protect-ChatqDownMessage -Master $dvMaster -Did $dv.did -Payload $dv.payload -Iv (ConvertFrom-ChatqB64Url $dv.iv) -Deflated (ConvertFrom-ChatqB64Url $dv.deflated)
Check 'the down vector: the topic of D and the sealed message, byte for byte as Node made them' ((Get-ChatqDownTopic $dvMaster) -ceq $dv.downTopic -and $dvMsg -ceq $dv.message) "$(Get-ChatqDownTopic $dvMaster) | $dvMsg"
$dvOpen = Unprotect-ChatqDownMessage $dv.message $dvMaster $dv.did
Check 'the down vector opens: Node''s raw deflate inflated here, the JSON as written, Hangul intact' ($dvOpen.Ok -and $dvOpen.Json -ceq $dv.payload -and
    $dvOpen.Payload.parts[0].s -eq (U 'yes, commit it \uD55C\uAE00') -and $dvOpen.Payload.ref -eq 'abcdefghij') "$($dvOpen.Stage) $($dvOpen.Error)"
$hangulText = (U '\uD55C\uAE00 answer ') * 50
$rt = @(
    (Expand-ChatqBytes (Compress-ChatqBytes $utf8.GetBytes($hangulText))),
    (Expand-ChatqBytes (Compress-ChatqBytes ([byte[]]@()))),
    (Expand-ChatqBytes (Compress-ChatqBytes ([byte[]](New-Object byte[] 1048576))) -MaxBytes 2MB)
)
Check 'our own raw deflate round-trips: Hangul, nothing at all, 1 MB' ($utf8.GetString($rt[0]) -eq $hangulText -and @($rt[1]).Count -eq 0 -and $rt[2].Length -eq 1048576) "$(@($rt[1]).Count) / $($rt[2].Length)"
$bomb = Compress-ChatqBytes ([byte[]](New-Object byte[] (8MB)))
Check 'a deflate bomb stops at -MaxBytes: 8 MB of zeros from a few KB, refused at 4 MB' ($bomb.Length -lt 65536 -and $null -eq (Expand-ChatqBytes $bomb -MaxBytes 4MB) -and
    $null -eq (Expand-ChatqBytes ([byte[]](1, 2, 3, 4, 5)))) "$($bomb.Length) bytes"
$ownMsg = Protect-ChatqDownMessage -Master $dvMaster -Did 'klmnopqrst' -Payload '{"v":3,"kind":"ack","ref":"klmnopqrst","ok":true}'
Check 'our own seal opens with our own opener; for another did, or sealed under a phone key, it does not' ((Unprotect-ChatqDownMessage $ownMsg $dvMaster 'klmnopqrst').Ok -and
    (Unprotect-ChatqDownMessage $ownMsg $dvMaster 'abcdefghij').Error -eq 'for another request' -and
    (Unprotect-ChatqDownMessage ($ownMsg -replace '^chatq3d', 'chatq3c') $dvMaster).Stage -eq 'format') ''
$cvOpen = Unprotect-ChatqComposeMessage $cv.message $dvMaster
Check 'the compose vector opens: send, the handle, the id, the text with its Hangul, the nonce and time' ($cvOpen.Ok -and $cvOpen.Cid -eq 'klmnopqrst' -and $cvOpen.Payload.act -eq 'send' -and
    $cvOpen.Payload.h -eq 'k3m2qa' -and $cvOpen.Payload.id -eq '1a2b3c4d' -and $cvOpen.Payload.text -eq (U 'yes, commit it \uD55C\uAE00') -and [int64]$cvOpen.Payload.ts -eq 1790000000000) "$($cvOpen.Stage) $($cvOpen.Error)"
Check 'and our seal of its payload is Node''s message byte for byte' ((Protect-ChatqComposeMessage -Key $cv.master -Cid $cv.cid -Payload $cv.payload -Iv (ConvertFrom-ChatqB64Url $cv.iv)) -ceq $cv.message) ''
$cvParts = $cv.message.Split('.')
$cvFlip = @(foreach ($i in 2, 3, 4) { $p = $cvParts.Clone(); $p[$i] = $(if ($p[$i][3] -ceq 'A') { $p[$i].Substring(0, 3) + 'B' } else { $p[$i].Substring(0, 3) + 'A' }) + $p[$i].Substring(4); (Unprotect-ChatqComposeMessage ($p -join '.') $dvMaster).Stage })
$asAlert = Protect-ChatqReplyMessage -Key $cv.master -Aid 'klmnopqrst' -Payload $cv.payload -Iv (ConvertFrom-ChatqB64Url $cv.iv)
$c3Alert = 'chatq3c.' + ($asAlert.Split('.')[1..4] -join '.')
$c1Phone = 'chatq1.' + ($cv.message.Split('.')[1..4] -join '.')
Check 'a changed byte anywhere is the MAC; a chatq3c sealed under an alert''s key, or a chatq1 under a phone key, fails too' (($cvFlip -join ',') -eq 'mac,mac,mac' -and
    (Unprotect-ChatqComposeMessage $c3Alert $dvMaster).Stage -eq 'mac' -and (Unprotect-ChatqReplyMessage $c1Phone $dvMaster).Stage -eq 'mac') "$($cvFlip -join ',')"

# --- the whole answer: a transcript's last turn, a job's last run ----------------------
# by $sb: $work was taken for a screen rect in the overlay section
$bdProj = Join-Path (Join-Path $sb 'work') 'projBoard'
$null = New-Item -ItemType Directory -Path $bdProj -Force
$idBa = 'b0b0b0b0-b0b0-4b0b-8b0b-b0b0b0b0b0b0'
$idBb = 'b1b1b1b1-b1b1-4b1b-8b1b-b1b1b1b1b1b1'
$idBc = 'b2b2b2b2-b2b2-4b2b-8b2b-b2b2b2b2b2b2'
$pBa = New-FakeChat $bdProj $idBa (U 'Parser \uD55C\uAE00 rewrite') 0.2 @('first question') -Mode 'bypassPermissions'
$pBb = New-FakeChat $bdProj $idBb 'Radar viewer' 0.3 @('look at the radar') -Mode 'default'
$pBc = New-FakeChat $bdProj $idBc 'Plugin unification' 0.4 @('unify the plugins') -CutOff -ResetsAt ([DateTimeOffset]::UtcNow.AddHours(2).ToUnixTimeSeconds())
$emoji = [char]::ConvertFromUtf32(0x1F600)
$now = (Get-Date).ToUniversalTime()
$bdRecord = {
    param([string]$Type, $Content, [switch]$Side, [switch]$Meta, [string]$Model = 'claude-opus-5')
    $o = [ordered]@{ parentUuid = $null; isSidechain = [bool]$Side; type = $Type; uuid = [guid]::NewGuid().ToString(); timestamp = $now.ToString('o'); cwd = $bdProj; sessionId = $idBa }
    if ($Meta) { $o['isMeta'] = $true }
    $o['message'] = if ($Type -eq 'user') { [ordered]@{ role = 'user'; content = $Content } } else { [ordered]@{ model = $Model; role = 'assistant'; content = $Content } }
    ($o | ConvertTo-Json -Compress -Depth 10)
}
$turnLines = @(
    (& $bdRecord 'user' 'second question')
    (& $bdRecord 'assistant' @([ordered]@{ type = 'text'; text = 'Looking.' }, [ordered]@{ type = 'tool_use'; id = 't1'; name = 'Bash'; input = [ordered]@{ command = "git status`nand more" } }))
    (& $bdRecord 'user' @([ordered]@{ type = 'tool_result'; tool_use_id = 't1'; content = 'clean' }))
    (& $bdRecord 'assistant' @([ordered]@{ type = 'text'; text = 'side work' }) -Side)
    (& $bdRecord 'assistant' @([ordered]@{ type = 'text'; text = "Done: all good $emoji" }))
    (& $bdRecord 'assistant' @([ordered]@{ type = 'text'; text = "You've hit your session limit" }) -Model '<synthetic>')
    (& $bdRecord 'user' 'Continue from where you left off.' -Meta)
)
[System.IO.File]::AppendAllText($pBa, ($turnLines -join "`n") + "`n", $utf8)
$tt = Get-ChatqTurnText $pBa
$ttShape = @($tt.Parts | ForEach-Object { "$($_.t):$($_.s)" }) -join ' | '
Check 'the last turn: back to the last real prompt - not a tool result, not Claude Code''s own - in order, a tool as one line, a side chat left out, the limit a note' (
    $ttShape -eq "text:Looking. | tool:Bash git status | text:Done: all good $emoji | note:You've hit your session limit" -and $tt.Cut -eq 0 -and $tt.At) $ttShape
$sel = Select-ChatqPartsTail @([ordered]@{ t = 'text'; s = 'old part' }, [ordered]@{ t = 'text'; s = "ab$($emoji)cd" }) 3
Check 'over -Max the front goes: whole parts first, then the first kept cut - never between an emoji''s halves' (@($sel.Parts).Count -eq 1 -and $sel.Parts[0].s -eq 'cd' -and $sel.Cut -eq 12) "$(@($sel.Parts | ForEach-Object { $_.s }) -join '|') cut $($sel.Cut)"
$ttCut = Get-ChatqTurnText $pBa -Max 40
Check 'Get-ChatqTurnText -Max: the end kept, Cut how much went' ($ttCut.Cut -gt 0 -and @($ttCut.Parts)[-1].t -eq 'note' -and ((@($ttCut.Parts | ForEach-Object { $_.s }) -join '').Length) -le 40) "cut $($ttCut.Cut)"
$bdJobLog = { param($j, [string[]]$Lines) New-ChatqDir $script:ChatqLogDir; [System.IO.File]::WriteAllText((Join-Path $script:ChatqLogDir "$($j.id).jsonl"), ($Lines -join "`n") + "`n", $utf8) }
$jl = [pscustomobject]@{ id = 'bdlogjob1'; provider = 'claude'; path = $pBa; sessionId = $idBa; endedAt = $now.ToString('o') }
& $bdJobLog $jl @(
    '{"type":"system","subtype":"init","session_id":"s","model":"m","permissionMode":"default"}'
    '{"type":"assistant","message":{"content":[{"type":"text","text":"run one"}]}}'
    '{"type":"result","subtype":"success","num_turns":1}'
    '{"type":"system","subtype":"init","session_id":"s","model":"m","permissionMode":"default"}'
    '{"type":"assistant","message":{"content":[{"type":"text","text":"run two"},{"type":"tool_use","name":"Read","input":{"file_path":"C:\\x.txt"}}]}}'
    '{"type":"result","subtype":"success","num_turns":1}'
)
$jc = [pscustomobject]@{ id = 'bdlogjob2'; provider = 'codex'; path = $null; sessionId = 'c0dec0de'; endedAt = $now.ToString('o') }
& $bdJobLog $jc @('{"type":"item.completed","item":{"type":"agent_message","text":"codex says"}}', '{"type":"item.completed","item":{"type":"command_execution","command":"ls -la"}}')
$jt = Get-ChatqJobTurnText $jl
$jtc = Get-ChatqJobTurnText $jc
Check 'a job''s last run from its own log: after its last init only; Codex''s lines as well' ((@($jt.Parts | ForEach-Object { "$($_.t):$($_.s)" }) -join '|') -eq 'text:run two|tool:Read C:\x.txt' -and
    (@($jtc.Parts | ForEach-Object { "$($_.t):$($_.s)" }) -join '|') -eq 'text:codex says|tool:ls -la') "$(@($jt.Parts | ForEach-Object { $_.s }) -join '|') / $(@($jtc.Parts | ForEach-Object { $_.s }) -join '|')"
Remove-Item -LiteralPath (Join-Path $script:ChatqLogDir 'bdlogjob1.jsonl'), (Join-Path $script:ChatqLogDir 'bdlogjob2.jsonl') -Force -EA SilentlyContinue

# --- a phone, paired by its key ------------------------------------------------------
$bdD = New-ChatqRandomBytes 32
$bdKey = ConvertTo-ChatqB64Url $bdD
$cfg = Get-ChatqConfig
Set-ChatqProp $cfg 'reply' ([pscustomobject]@{ on = $true; topic = [pscustomobject](Protect-ChatqSecret 'chatq-boardtopicboardtopicboar'); key = [pscustomobject](Protect-ChatqSecret $bdKey); phone = 'Board phone'; pairedAt = (Get-ChatqStamp) })
foreach ($k in 'ntfy') { if ($cfg.PSObject.Properties[$k]) { $cfg.PSObject.Properties.Remove($k) } }
Save-ChatqJson $script:ChatqConfigPath $cfg
$null = Set-ChatqNotifyConfig @{ ApiKey = '0123456789abcdef0123456789abcdef'; Device = 'group.phone' }
$bdRc = Get-ChatqReplyConfig
$bdTopic = Get-ChatqDownTopic $bdD
Check 'paired: whole answers on, the board on, a new chat in default, listening while an alert is out, 150 a day - and the down topic of the phone''s key' ($bdRc.Links -and $bdRc.Full -and
    $bdRc.Compose -and $bdRc.NewMode -eq 'default' -and $bdRc.Listen -eq 'alerts' -and $bdRc.DownPerDay -eq 150 -and $bdRc.FullMax -eq 30000 -and $bdRc.DownTopic -ceq $bdTopic -and
    $bdTopic -cmatch '^chatq-[a-z2-7]{24}$') "$($bdRc.DownTopic)"

# --- the down topic: inline, an attachment, and cut to fit --------------------------------
$script:BdDown.Clear()
$r1 = Send-ChatqDown $bdRc 'abcdefghij' ([ordered]@{ v = 3; kind = 'ack'; ref = 'abcdefghij'; ok = $true; say = 'fine' })
$d1 = $script:BdDown[0]
Check 'a short one: a POST to the down topic, text/plain, titled with its did, kept from Google, priority 1' ($r1.Ok -and -not $r1.Attached -and $d1.Method -eq 'POST' -and
    $d1.Url -eq "https://ntfy.sh/$bdTopic" -and $d1.Headers['X-Title'] -eq 'abcdefghij' -and $d1.Headers['X-Firebase'] -eq 'no' -and $d1.Headers['X-Priority'] -eq '1' -and
    (Unprotect-ChatqDownMessage $d1.Body $bdD 'abcdefghij').Payload.say -eq 'fine') "$($d1.Method) $($d1.Url)"
$bigText = [Convert]::ToBase64String((New-ChatqRandomBytes 20000))
$bigBody = { [ordered]@{ v = 3; kind = 'reply'; ref = 'bcdefghijk'; ts = 1; event = 'done'; title = 't'; at = $null; cut = 0; parts = @([ordered]@{ t = 'text'; s = 'the start' }, [ordered]@{ t = 'text'; s = $bigText }, [ordered]@{ t = 'text'; s = 'the conclusion' }) } }
$script:BdDown.Clear()
$r2 = Send-ChatqDown $bdRc 'bcdefghijk' (& $bigBody)
$d2 = $script:BdDown[0]
Check 'a long one: one PUT, an attachment named <did>.txt, the whole of it' ($r2.Ok -and $r2.Attached -and $d2.Method -eq 'PUT' -and $d2.Headers['X-Filename'] -eq 'bcdefghijk.txt' -and
    $d2.Headers['X-Title'] -eq 'bcdefghijk' -and (Unprotect-ChatqDownMessage $d2.Body $bdD 'bcdefghijk').Payload.parts[1].s -eq $bigText) "$($d2.Method) $($d2.Body.Length)"
$script:BdDownFail = { param($m) if ($m -eq 'PUT') { 'HTTP 413 Payload Too Large' } }
$script:BdDown.Clear()
$b3 = & $bigBody
$b3['ref'] = 'cdefghijkl'
$r3 = Send-ChatqDown $bdRc 'cdefghijkl' $b3
$script:BdDownFail = $null
$d3 = @($script:BdDown)[0]
$u3 = if ($d3) { Unprotect-ChatqDownMessage $d3.Body $bdD 'cdefghijkl' } else { $null }
$o3 = if ($u3) { $u3.Payload } else { $null }
Check 'a server that refuses the attachment: cut from the front until it fits inline, and cut says how much' ($r3.Ok -and $d3.Method -eq 'POST' -and $d3.Body.Length -le 3900 -and
    [int]$o3.cut -gt 0 -and @($o3.parts)[-1].s -eq 'the conclusion') "$($d3.Method) $($d3.Body.Length) cut $($o3.cut) $($u3.Stage) $($u3.Error) $($r3 | ConvertTo-Json -Compress)"
$script:BdDownFail = { param($m) if ($m -eq 'PUT') { 'HTTP 400 attachments not allowed' } }
$script:BdDown.Clear()
$rows60 = @(1..60 | ForEach-Object { [ordered]@{ h = 'abcdef'; t = [Convert]::ToBase64String((New-ChatqRandomBytes 60)); f = 'x' } })
$r4 = Send-ChatqDown $bdRc 'defghijklm' ([ordered]@{ v = 3; kind = 'board'; ref = 'defghijklm'; open = @(); recent = $rows60; more = 0 })
$script:BdDownFail = $null
$d4 = @($script:BdDown)[0]
$o4 = if ($d4) { (Unprotect-ChatqDownMessage $d4.Body $bdD 'defghijklm').Payload } else { $null }
Check 'a board too long, and no attachment taken: its recent rows halved until it fits, "more" counting them' ($r4.Ok -and -not $r4.Attached -and $d4.Body.Length -le 3900 -and
    [int]$o4.more -gt 0 -and @($o4.recent).Count + [int]$o4.more -eq 60) "attached $($r4.Attached) more $($o4.more) $($r4.Error)"

# --- the whole answer with an alert --------------------------------------------------
$env:CHATQ_WATCHER = '1'
$rowA = Get-ChatqRowById -Id $idBa -Provider claude
$jobA = (New-ChatqJob -Row $rowA -Prompt 'do it' -Kind prompt).Job
Complete-ChatqJob $jobA 'done' ([pscustomobject]@{ kind = 'done'; reason = 'finished' }) 'finished'
$bdLastJoin = {
    $u = $script:BdJoins[$script:BdJoins.Count - 1]
    $q = @{}
    foreach ($p in ($u.Substring($u.IndexOf('?') + 1) -split '&')) { $k, $v = $p -split '=', 2; $q[$k] = [uri]::UnescapeDataString($v) }
    $f = @{}
    if ($q['url']) { foreach ($p in ($q['url'].Substring($q['url'].IndexOf('#') + 1) -split '&')) { $k, $v = $p -split '=', 2; $f[$k] = [uri]::UnescapeDataString($v) } }
    [pscustomobject]@{ Q = $q; F = $f }
}
$script:BdOrder.Clear(); $script:BdDown.Clear()
$t0 = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$sentA = Send-ChatqAlert 'done' 'finished' 1 -Job $jobA
$jA = & $bdLastJoin
$dA = $script:BdDown[0]
$oA = if ($dA) { (Unprotect-ChatqDownMessage $dA.Body $bdD $jA.F['a']).Payload } else { $null }
Check 'a done alert: the whole answer to the down topic first, then the push, whose link says f=1 and o= its time' ($sentA -and ($script:BdOrder -join ',') -eq 'down,join' -and
    $jA.F['f'] -eq '1' -and [int64]$jA.F['o'] -ge $t0 -and $oA.kind -eq 'reply' -and $oA.event -eq 'done' -and $oA.ref -eq $jA.F['a'] -and $dA.Headers['X-Title'] -eq $jA.F['a'] -and
    (@($oA.parts | ForEach-Object { $_.s }) -join '|') -like '*Done: all good*') "$($script:BdOrder -join ',') / $($jA.Q['url'])"
$script:BdDownFail = { param($m) 'offline' }
$script:BdOrder.Clear()
$sentB = Send-ChatqAlert 'failed' 'broke' 2 -Job $jobA
$script:BdDownFail = $null
$jB = & $bdLastJoin
Check 'the down topic failing: no f=1, and the push goes all the same' ($sentB -and ($script:BdOrder -join ',') -eq 'down,join' -and -not $jB.F.ContainsKey('f') -and -not $jB.F.ContainsKey('o')) "$($jB.Q['url'])"
$script:BdDown.Clear()
$sentC = Send-ChatqAlert 'started' 'going' 0 -Job $jobA
Check 'a started alert: no whole answer' ($sentC -and $script:BdDown.Count -eq 0 -and -not (& $bdLastJoin).F.ContainsKey('f')) ''
chatnotify -FullText off *> $null
$script:BdDown.Clear()
$sentD = Send-ChatqAlert 'done' 'finished' 1 -Job $jobA
chatnotify -FullText on *> $null
Check 'chatnotify -FullText off: no whole answer goes; on again' ($sentD -and $script:BdDown.Count -eq 0 -and (Get-ChatqReplyConfig).Full -and (Get-ChatqConfig).reply.full -eq $true) ''
$cfg = Get-ChatqConfig; Set-ChatqProp $cfg.reply 'downPerDay' 1; Save-ChatqJson $script:ChatqConfigPath $cfg
$null = Use-ChatqReplyState { param($st) $st.down = @{ day = (Get-Date).ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture); full = 0; other = 0 } }
$script:BdDown.Clear()
$null = Send-ChatqAlert 'done' 'one' 1 -Job $jobA
$null = Send-ChatqAlert 'done' 'two' 1 -Job $jobA
$afterTwo = $script:BdDown.Count
$null = Use-ChatqReplyState { param($st) $st.down.day = '2000-01-01' }
$null = Send-ChatqAlert 'done' 'three' 1 -Job $jobA
Check 'reply.downPerDay reached: no more whole answers today - and a new day counts afresh' ($afterTwo -eq 1 -and $script:BdDown.Count -eq 2 -and
    (Get-ChatqReplyState).down.full -eq 1 -and (Get-ChatqReplyState).down.day -ne '2000-01-01') "$afterTwo then $($script:BdDown.Count)"
$cfg = Get-ChatqConfig; $cfg.reply.PSObject.Properties.Remove('downPerDay'); Save-ChatqJson $script:ChatqConfigPath $cfg
$bdRc = Get-ChatqReplyConfig

# --- the phone's messages ------------------------------------------------------------------
$script:BdSeq = 0
$bdSeal = {
    # what the page sends: {"v":3,"act":...,fields...,"nonce","ts"} sealed as chatq3c
    param([string]$Act, [System.Collections.IDictionary]$Fields, [int64]$Ts = 0, [string]$Nonce)
    $o = [ordered]@{ v = 3; act = $Act }
    if ($Fields) { foreach ($k in $Fields.Keys) { $o[$k] = $Fields[$k] } }
    $o['nonce'] = if ($Nonce) { $Nonce } else { ConvertTo-ChatqB64Url (New-ChatqRandomBytes 16) }
    $o['ts'] = if ($Ts) { $Ts } else { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
    $cid = New-ChatqRandomName 10
    [pscustomobject]@{ Cid = $cid; Message = (Protect-ChatqComposeMessage -Key $bdKey -Cid $cid -Payload ($o | ConvertTo-Json -Compress)) }
}
$bdSend = {
    # one message through a poll; the down message answering it, opened
    param($Sealed)
    $script:BdSeq++
    $script:BdFeed = ([ordered]@{ id = "bdmsg$($script:BdSeq)"; time = 1; event = 'message'; topic = 't'; message = $Sealed.Message } | ConvertTo-Json -Compress)
    $script:BdDown.Clear()
    $n = Invoke-ChatqReplyPoll -Force
    $ans = @($script:BdDown | Where-Object { $_.Headers['X-Title'] -eq $Sealed.Cid })[0]
    $o = if ($ans) { Unprotect-ChatqDownMessage $ans.Body $bdD $Sealed.Cid } else { $null }
    [pscustomobject]@{ N = $n; Payload = $(if ($o -and $o.Ok) { $o.Payload } else { $null }); Downs = $script:BdDown.Count }
}
$bdQuiet = { $null = Use-ChatqReplyState { param($st) $st.composeRefusedAt = $null } }

# the overlay's snapshot, fresh: one chat waiting, one working, one cut off,
# a job of its own, the Recent list and usage
$bdGone = Join-Path (Join-Path $sb 'work') 'projGone'
$null = New-Item -ItemType Directory -Path $bdGone -Force
$nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$snap = [ordered]@{
    schema = 1; version = 'x'; pid = 1; at = $nowMs
    header = [ordered]@{ usage = @([ordered]@{ provider = 'Claude'; source = 'live'; at = $nowMs; stale = $false; status = '14:02'
                windows = @([ordered]@{ label = '5h'; percent = 37; resetsAt = $nowMs + 7200000; severity = 'normal'; limited = $false }, [ordered]@{ label = 'week'; percent = 18; resetsAt = $null; severity = 'normal'; limited = $false }) }) }
    counts = @{}; config = @{}; commands = @()
    rows = @(
        [ordered]@{ key = "s:$idBb"; kind = 'session'; provider = 'claude'; status = 'waiting'; chat = 'waiting'; rank = 0; project = 'projBoard'; title = 'Radar viewer'; prompt = 'look at the radar'; detail = 'permission (Bash)'; since = $nowMs - 180000; sessionId = $idBb; cwd = $bdProj; job = $null; where = 'vscode'; unread = $false }
        [ordered]@{ key = "s:$idBa"; kind = 'session'; provider = 'claude'; status = 'busy'; chat = 'busy'; rank = 1; project = 'projBoard'; title = (U 'Parser \uD55C\uAE00 rewrite'); prompt = "fix the tokenizer`nsecond line"; detail = $null; since = $nowMs - 720000; sessionId = $idBa; cwd = $bdProj; job = $null; where = 'terminal'; unread = $true }
        [ordered]@{ key = "c:$idBc"; kind = 'cutoff'; provider = 'claude'; status = 'cutoff'; chat = 'cutoff'; rank = 0.5; project = 'projBoard'; title = 'Plugin unification'; prompt = $null; detail = 'cut off - resets 13:00'; since = $nowMs - 3600000; sessionId = $idBc; cwd = $bdProj; path = $pBc; job = $null; where = ''; unread = $false }
    )
    recent = @([ordered]@{ key = 'recent:x'; kind = 'recent'; provider = 'claude'; status = 'recent'; project = 'projGone'; title = 'Old chat'; sessionId = 'ffffffff-0000-4000-8000-000000000000'; cwd = $bdGone; since = $nowMs - 7200000 })
}
Save-ChatqText $script:ChatOverlayPath ($snap | ConvertTo-Json -Depth 8 -Compress)

$b1 = & $bdSend (& $bdSeal 'board' $null)
$bp = $b1.Payload
$openT = @($bp.open | ForEach-Object { "$($_.state):$($_.t)" }) -join '|'
Check 'board: the answer on the down topic under the request''s id - the overlay''s rows, its usage, where each chat runs, the new-turn dot' ($b1.N -eq 1 -and $bp.kind -eq 'board' -and
    $bp.from -eq 'overlay' -and $openT -eq "waiting:Radar viewer|busy:$(U 'Parser \uD55C\uAE00 rewrite')" -and @($bp.cut).Count -eq 1 -and $bp.cut[0].d -eq 'cut off - resets 13:00' -and
    $bp.usage[0].p -eq 'Claude' -and $bp.usage[0].parts[0].pct -eq 37 -and $bp.open[1].where -eq 'terminal' -and $bp.open[1].new -eq $true -and $bp.open[0].what -eq 'permission (Bash)' -and
    $bp.open[1].prompt -eq 'fix the tokenizer' -and @($bp.recent).Count -eq 1 -and $bp.host -and $bp.cap -eq 'acceptEdits' -and $bp.newMode -eq 'default' -and $bp.listen -eq 'alerts') "$openT / $($bp | ConvertTo-Json -Compress -Depth 6)"
$st = Get-ChatqReplyState
$hA = $bp.open[1].h
Check 'its handles: six letters each, in replies.json picks - the chat, its folder, its config dir - and nothing of a session id or path on the wire' ($hA -cmatch '^[a-z2-7]{6}$' -and
    $st.picks[$hA].kind -eq 'chat' -and $st.picks[$hA].sessionId -eq $idBa -and $st.picks[$hA].home -eq $claudeHome -and
    ($bp | ConvertTo-Json -Compress -Depth 6) -notlike "*$idBa*" -and ($bp | ConvertTo-Json -Compress -Depth 6) -notlike "*projBoard\\*" -and @($bp.folders).Count -ge 2) "$hA / $(@($st.picks.Keys).Count) picks"
Check 'the act recorded for the hour, the next 2 minutes polled faster, the answer counted against the day' (@($st.compose | Where-Object { $_.act -eq 'board' }).Count -eq 1 -and
    (ConvertTo-ChatqDate $st.hotUntil) -gt (Get-Date).AddSeconds(90) -and (Get-ChatqReplyPollSeconds) -eq 6 -and (Get-ChatqReplyPollSeconds -InRun) -eq 10 -and [int]$st.down.other -ge 1) ''
# a job the watcher holds back says why, in the panel's words, before the
# ETA; a chat a queued prompt runs in keeps its where, run, for the page
$pbNow = Get-Date
$pbJob = { param($id, $seq, $why) [pscustomobject]@{ id = $id; seq = $seq; state = 'queued'; kind = 'prompt'; provider = 'claude'; title = "held $seq"; cwd = $bdProj; sessionId = $idBa
        deferWhy = $why; deferSince = $pbNow.AddMinutes(-8).ToUniversalTime().ToString('o'); deferUntil = $pbNow.AddMinutes(2).ToUniversalTime().ToString('o') } }
$pbSnap = [pscustomobject]@{ header = [pscustomobject]@{ usage = @() }; recent = @(); rows = @(
        [pscustomobject]@{ key = "s:$idBa"; kind = 'session'; provider = 'claude'; status = 'busy'; chat = 'busy'; rank = 1; project = 'projBoard'; title = 'Run'; prompt = 'x'; since = $nowMs; sessionId = $idBa; cwd = $bdProj; job = $null; where = 'run'; unread = $false }) }
$pbB = (ConvertTo-ChatqPhoneBoard -Snap $pbSnap -Jobs @((& $pbJob 'pb1' 41 'in-use'), (& $pbJob 'pb2' 42 'background'), (& $pbJob 'pb3' 43 $null)) `
        -Eta @{ pb1 = '14:15 (chat busy)'; pb2 = '14:15 (chat busy)'; pb3 = '14:20' } -Now $pbNow).Body
$pbE = @($pbB.queue | ForEach-Object { "$($_.n)=$($_.e)" }) -join ','
$pbWant = "41=waits for you to leave its tab,42=waits for a background command (since $(Format-ChatOverlayWhen $pbNow.AddMinutes(-8) $pbNow)),43=14:20"
Check 'board: a job the watcher holds back says why, as the panel does - its tab, or a background command since when; others their ETA; where run passed on' (
    $pbE -eq $pbWant -and @($pbB.open).Count -eq 1 -and $pbB.open[0].where -eq 'run' -and @($pbB.open[0].jobs).Count -eq 3 -and $pbB.open[0].jobs[0].e -eq 'waits for you to leave its tab') "$pbE / $($pbB.open[0].where)"

# asked again within 10 s: the same board, not built again
$bdBuildFn = ${function:Get-ChatqPhoneBoard}
$script:BdBuilds = 0
${function:Get-ChatqPhoneBoard} = { param([datetime]$Now = (Get-Date), [switch]$Scan) $script:BdBuilds++; & $script:BdBuildFnRef -Now $Now -Scan:$Scan }
$script:BdBuildFnRef = $bdBuildFn
try { $b2 = & $bdSend (& $bdSeal 'board' $null) } finally { ${function:Get-ChatqPhoneBoard} = $bdBuildFn }
Check 'a board asked within 10 s is the last one again - not built, the same handles, its own ref' ($script:BdBuilds -eq 0 -and $b2.Payload.kind -eq 'board' -and $b2.Payload.open[1].h -eq $hA -and
    $b2.Payload.ref -ne $bp.ref) "builds $($script:BdBuilds)"
$script:ChatqBoardCache = $null
$b3 = & $bdSend (& $bdSeal 'board' $null)
Check 'built again later, a chat keeps its handle' ($b3.Payload.open[1].h -eq $hA -and @((Get-ChatqReplyState).picks.Keys).Count -eq @($st.picks.Keys).Count) ''

# --- send, new, and the refusals ------------------------------------------------------
$j0 = @(Get-ChatqJobs).Count
$n0 = $script:BdJoins.Count
$s1 = & $bdSend (& $bdSeal 'send' ([ordered]@{ h = $hA; id = $idBa.Substring(0, 8); text = 'see [the file](C:\secret.txt) now' }))
$jS = @(Get-ChatqJobs | Where-Object { $_.rule -eq 'phone' -and $_.sessionId -eq $idBa })[-1]
Check 'send: a job for that chat, rule phone, bypassPermissions brought down to acceptEdits, its link left as text, in the chat''s config dir' ($jS -and @(Get-ChatqJobs).Count -eq $j0 + 1 -and
    $jS.mode -eq 'acceptEdits' -and (Read-ChatqPrompt $jS) -like '*]\(C:\secret.txt)*' -and $jS.home -eq $claudeHome -and $jS.kind -eq 'prompt') "$($jS.mode) / $(Read-ChatqPrompt $jS)"
Check 'and the ack says so on the down topic, and the usual reply push goes too, about the new job' ($s1.Payload.kind -eq 'ack' -and $s1.Payload.ok -and $s1.Payload.act -eq 'send' -and
    $s1.Payload.seq -eq $jS.seq -and $s1.Payload.say -like "queued #$($jS.seq) for * - runs in acceptEdits, the phone's limit" -and $script:BdJoins.Count -eq $n0 + 1 -and
    (& $bdLastJoin).F['n'] -eq "$($jS.seq)") "$($s1.Payload.say)"
Check 'a send that queued: the board kept for 10 s is dropped, so the page''s next ask shows the job' ($b3.Payload.kind -eq 'board' -and $null -eq $script:ChatqBoardCache) ''
$j0 = @(Get-ChatqJobs).Count
$r = & $bdSend (& $bdSeal 'send' ([ordered]@{ h = $hA; id = 'zzzzzzzz'; text = 'x' }))
Check 'send with an id that is not the handle''s chat: refused - the list is out of date - nothing queued' (-not $r.Payload.ok -and $r.Payload.say -eq 'that list is out of date - refresh it' -and @(Get-ChatqJobs).Count -eq $j0) "$($r.Payload.say)"
& $bdQuiet
$null = Use-ChatqReplyState { param($st) $st.picks[$hA].expires = (Get-Date).AddMinutes(-1).ToUniversalTime().ToString('o') }
$r = & $bdSend (& $bdSeal 'send' ([ordered]@{ h = $hA; id = $idBa.Substring(0, 8); text = 'x' }))
Check 'a handle past its expiry: refused the same way' (-not $r.Payload.ok -and $r.Payload.say -eq 'that list is out of date - refresh it' -and @(Get-ChatqJobs).Count -eq $j0) "$($r.Payload.say)"
& $bdQuiet
$script:ChatqBoardCache = $null
$b4 = (& $bdSend (& $bdSeal 'board' $null)).Payload
$hA = $b4.open[1].h
$r = & $bdSend (& $bdSeal 'skip' ([ordered]@{ h = $hA; n = 1 }))
Check 'a job act on a chat''s handle: refused - a handle is bound to its kind' (-not $r.Payload.ok -and $r.Payload.say -like '*out of date*') "$($r.Payload.say)"
& $bdQuiet
$old = & $bdSeal 'send' ([ordered]@{ h = $hA; id = $idBa.Substring(0, 8); text = 'late' }) ([DateTimeOffset]::UtcNow.AddMinutes(-31).ToUnixTimeMilliseconds())
$r = & $bdSend $old
Check 'a send 31 minutes old: refused - too long ago, or the phone''s clock is off' (-not $r.Payload.ok -and $r.Payload.say -like 'that was sent too long ago*' -and @(Get-ChatqJobs).Count -eq $j0) "$($r.Payload.say)"
$again = & $bdSeal 'send' ([ordered]@{ h = $hA; id = $idBa.Substring(0, 8); text = 'once only' })
$r1 = & $bdSend $again
$jn = @(Get-ChatqJobs).Count
$script:ChatqReplySeen = @{}
$r2 = & $bdSend $again
Check 'the same message twice - from the file, not this process''s memory: the second is dropped in silence' ($r1.Payload.ok -and $r2.Downs -eq 0 -and @(Get-ChatqJobs).Count -eq $jn) "downs $($r2.Downs)"
& $bdQuiet
$r = & $bdSend (& $bdSeal 'bogus' ([ordered]@{ h = $hA }))
Check 'an act this PC does not know: refused, and said' (-not $r.Payload.ok -and $r.Payload.say -like '*does not know*') "$($r.Payload.say)"
$r = & $bdSend (& $bdSeal 'bogus2' $null)
Check 'refusals are said once a minute at most' ($r.Downs -eq 0) "downs $($r.Downs)"
& $bdQuiet
$null = Use-ChatqReplyState { param($st) $st.compose = @(1..20 | ForEach-Object { @{ at = (Get-ChatqStamp); act = 'send' } }) }
$r = & $bdSend (& $bdSeal 'send' ([ordered]@{ h = $hA; id = $idBa.Substring(0, 8); text = 'one too many' }))
Check 'the 21st change in an hour: refused - too many from the phone this hour' (-not $r.Payload.ok -and $r.Payload.say -eq 'too many from the phone this hour - nothing done' -and @(Get-ChatqJobs).Count -eq $jn) "$($r.Payload.say)"
$null = Use-ChatqReplyState { param($st) $st.compose = @(); $st.composeRefusedAt = $null }
chatnotify -Compose off *> $null
$r = & $bdSend (& $bdSeal 'board' $null)
chatnotify -Compose on *> $null
& $bdQuiet
Check 'chatnotify -Compose off: the board is refused, and says how to turn it on' (-not $r.Payload.ok -and $r.Payload.say -eq 'the PC does not take chats from the phone - chatnotify -Compose on') "$($r.Payload.say)"
# a save that fails: nothing done, and the message comes back next poll
$held = [System.IO.File]::Open($script:ChatqReplyLockPath, 'OpenOrCreate', 'ReadWrite', 'None')
$later = & $bdSeal 'send' ([ordered]@{ h = $hA; id = $idBa.Substring(0, 8); text = 'after the lock' })
try { $r = & $bdSend $later } finally { $held.Dispose() }
$jl1 = @(Get-ChatqJobs).Count
$script:BdSeq--
$r2 = & $bdSend $later
Check 'replies.json cannot be saved: unsaved, nothing queued, no answer - done on the next poll' ($r.N -eq 0 -and $r.Downs -eq 0 -and $jl1 -eq $jn -and $r2.Payload.ok -and @(Get-ChatqJobs).Count -eq $jn + 1) "$($r.N)/$($r.Downs) then $($r2.Payload.say)"

# new: in a folder the board offered
$fGone = @($b4.folders | Where-Object { $_.n -eq 'projGone' })[0]
$fBoard = @($b4.folders | Where-Object { $_.n -eq 'projBoard' })[0]
$jn = @(Get-ChatqJobs).Count
$r = & $bdSend (& $bdSeal 'new' ([ordered]@{ h = $fBoard.h; name = "Docs$([char]0x202E)pass"; text = 'write the docs' }))
$jNew = @(Get-ChatqJobs | Where-Object { $_.kind -eq 'new' -and $_.rule -eq 'phone' })[-1]
Check 'new: a new chat queued in that folder, named - a bidi override taken out - in default, the default config dir' ($r.Payload.ok -and $jNew -and (Split-Path $jNew.cwd -Leaf) -eq 'projBoard' -and
    $jNew.title -eq 'Docs pass' -and ($jNew.mode -eq 'default' -or -not $jNew.mode) -and -not $jNew.home) "$($r.Payload.say) / $($jNew.cwd) $($jNew.mode) $($jNew.title)"
Check 'and says where and how it runs' ($r.Payload.say -like 'new chat "Docs*pass" queued as #* in projBoard - runs in default') "$($r.Payload.say)"
$newPush = (& $bdLastJoin).Q['text']
Check 'its push says neither the title nor the folder: the phone sent them sealed, and a push is not' ($newPush -like 'new chat queued as #* - runs in default' -and
    $newPush -notlike '*Docs*' -and $newPush -notlike '*projBoard*') "$newPush"
Remove-Item -LiteralPath $bdGone -Recurse -Force
$r = & $bdSend (& $bdSeal 'new' ([ordered]@{ h = $fGone.h; name = ''; text = 'here' }))
Check 'new in a folder deleted since: refused, nothing queued' (-not $r.Payload.ok -and $r.Payload.say -like 'that folder is gone*' -and @(Get-ChatqJobs).Count -eq $jn + 1) "$($r.Payload.say)"
$null = New-Item -ItemType Directory -Path $bdGone -Force

# --- the queue from the phone: now, skip, stop, retry, allow, continue, read ------------
$rowB = Get-ChatqRowById -Id $idBb -Provider claude
$jQ = (New-ChatqJob -Row $rowB -Prompt 'queued one' -Kind prompt).Job
$jN = (New-ChatqJob -Row $rowB -Prompt 'needs input' -Kind prompt).Job
Complete-ChatqJob $jN 'needs-input' ([pscustomobject]@{ kind = 'needs-input'; reason = 'asked' }) 'asked'
$jF = (New-ChatqJob -Row $rowB -Prompt 'failed one' -Kind prompt).Job
Complete-ChatqJob $jF 'failed' ([pscustomobject]@{ kind = 'failed'; reason = 'broke' }) 'broke'
$jR = (New-ChatqJob -Row $rowB -Prompt 'running one' -Kind prompt).Job
Set-ChatqJobState $jR 'running' 'test'
$script:ChatqBoardCache = $null
$b5 = (& $bdSend (& $bdSeal 'board' $null)).Payload
$qh = @{}
foreach ($q in @($b5.queue)) { $qh[[int]$q.n] = $q }
$chB = @($b5.open | Where-Object { $_.t -eq 'Radar viewer' })[0]
Check 'the board''s queue: each job with its handle, state and "sends"; the chat''s row carries its jobs' ($qh[[int]$jQ.seq].s -eq 'queued' -and $qh[[int]$jN.seq].e -eq 'needs you' -and
    $qh[[int]$jF.seq].s -eq 'failed' -and $qh[[int]$jR.seq].e -eq 'running now' -and $qh[[int]$jQ.seq].h -cmatch '^[a-z2-7]{6}$' -and @($chB.jobs).Count -eq 4) "$(@($b5.queue | ForEach-Object { "#$($_.n) $($_.s) $($_.e)" }) -join ' | ')"
$stQ = Get-ChatqReplyState
Check 'a job''s handle keeps the job as the board showed it' ($stQ.picks[$qh[[int]$jN.seq].h].mark -eq (Get-ChatqJobMark (Find-ChatqJob $jN.id -Exact)) -and
    $stQ.picks[$qh[[int]$jN.seq].h].mark -like '0|needs-input|*') "$($stQ.picks[$qh[[int]$jN.seq].h].mark)"
$jact = { param($act, $j, [int]$n = 0) & $bdSend (& $bdSeal $act ([ordered]@{ h = $qh[[int]$j.seq].h; n = $(if ($n) { $n } else { [int]$j.seq }) })) }
$r = & $jact 'now' $jQ
$wake = if (Test-Path -LiteralPath $script:ChatqWakePath) { (Get-Content -LiteralPath $script:ChatqWakePath -Raw).Trim() } else { '' }
Check 'Send now: the job to the front of its lane and the watcher told to stop waiting - as chatqrun -Now' ($r.Payload.ok -and (Find-ChatqJob $jQ.id).first -and $wake -eq 'now' -and
    $r.Payload.say -like "#$($jQ.seq) goes next*") "$($r.Payload.say) / wake '$wake'"
$r = & $jact 'skip' $jQ ([int]$jQ.seq + 100)
Check 'a job act whose number is not the handle''s job: refused' (-not $r.Payload.ok -and (Find-ChatqJob $jQ.id).state -eq 'queued') "$($r.Payload.say)"
& $bdQuiet
$r = & $jact 'skip' $jQ
Check 'Skip: skipped, and said' ($r.Payload.ok -and (Find-ChatqJob $jQ.id).state -eq 'skipped' -and $r.Payload.say -eq "#$($jQ.seq) skipped") "$($r.Payload.say)"
# a job queued for the same chat in the same second is that id with -2: a
# handle to the first, once it is gone, must never reach the second
$jSib = (New-ChatqJob -Row $rowB -Prompt 'the sibling' -Kind prompt).Job
$sibBase = [string]$jSib.id
Remove-Item -LiteralPath (Join-Path $script:ChatqQueueDir "$sibBase.json") -Force
$jSib.id = "$sibBase-2"
Save-ChatqJob $jSib
$sibGone = Invoke-ChatqJobAct 'skip' @{ jobId = $sibBase; seq = 9999 } 'acceptEdits'
$sibSeq = Invoke-ChatqJobAct 'skip' @{ jobId = $jSib.id; seq = [int]$jSib.seq + 1 } 'acceptEdits'
$fjs = @([pscustomobject]@{ id = '20260927-101500-ab12-2'; seq = 13 })
Check 'a stored id is only ever its own job: gone, its same-second sibling (-2) is not skipped in its place, nor on a number not the handle''s; a typed prefix still finds one' (
    -not $sibGone.Ok -and $sibGone.Say -eq '#9999 is gone - nothing to skip' -and -not $sibSeq.Ok -and (Find-ChatqJob $jSib.id -Exact).state -eq 'queued' -and
    $null -eq (Find-ChatqJob '20260927-101500-ab12' $fjs) -and $null -eq (Find-ChatqJob '20260927-101500-ab12' $fjs -Exact) -and
    (Find-ChatqJob '20260927-1015' $fjs).seq -eq 13 -and (Find-ChatqJob '20260927-101500-ab12-2' $fjs -Exact).seq -eq 13) "$($sibGone.Say) / $($sibSeq.Say)"
$r = & $jact 'allow' $jN
$jN2 = Find-ChatqJob $jN.id
Check 'Allow edits & continue: queued again in acceptEdits, a continue' ($r.Payload.ok -and $jN2.state -eq 'queued' -and $jN2.mode -eq 'acceptEdits' -and $r.Payload.say -like "#$($jN.seq) queued again in acceptEdits (continue)*") "$($r.Payload.say)"
$r = & $jact 'retry' $jF
Check 'Retry: the failed job queued again' ($r.Payload.ok -and (Find-ChatqJob $jF.id).state -eq 'queued') "$($r.Payload.say)"
$r = & $jact 'stop' $jR
Check 'Stop, no watcher alive: marked failed, and said' ($r.Payload.ok -and (Find-ChatqJob $jR.id).state -eq 'failed' -and $r.Payload.say -like "#$($jR.seq) marked failed*") "$($r.Payload.say)"
$hC = $b5.cut[0].h
$jn = @(Get-ChatqJobs).Count
$r = & $bdSend (& $bdSeal 'continue' ([ordered]@{ h = $hC }))
$jC = @(Get-ChatqJobs | Where-Object { $_.sessionId -eq $idBc -and $_.kind -eq 'continue' })[-1]
Check 'Continue at reset on a chat cut off: a continue queued for it, rule phone, capped, in its config dir' ($r.Payload.ok -and $jC -and @(Get-ChatqJobs).Count -eq $jn + 1 -and
    $jC.rule -eq 'phone' -and $jC.home -eq $claudeHome -and $r.Payload.say -like 'continue queued as #*') "$($r.Payload.say)"
$r = & $bdSend (& $bdSeal 'continue' ([ordered]@{ h = $hC }))
Check 'and a second one while it waits: refused, nothing queued' (-not $r.Payload.ok -and $r.Payload.say -like "*#$($jC.seq) is queued*" -and @(Get-ChatqJobs).Count -eq $jn + 1) "$($r.Payload.say)"
# its cut-off marked as the reset ask's answers mark one: skipped later from
# the phone, auto-continue reads it declined, never a cut-off nobody touched
$cutC = @(Get-ChatqCutOffChats @() -Hours 24 | Where-Object { $_.Id -eq $idBc })[0]
$keyC = Get-ChatqCutKey $cutC
$mkC = if ($keyC) { Read-ChatqJson (Join-Path $script:ChatqAutoDir "$keyC.json") } else { $null }
$skC = Invoke-ChatqJobAct 'skip' @{ jobId = $jC.id; seq = [int]$jC.seq } 'acceptEdits'
$onCfg = [pscustomobject]@{ Mode = 'on'; On = $true; Since = (Get-Date).AddDays(-1); Chats = @{}; Streak = @{} }
$stMarked = Get-ChatqAutoState $cutC @(Get-ChatqJobs) @() $onCfg (Get-ChatqAutoMarkers) (Get-Date)
$stBare = Get-ChatqAutoState $cutC @(Get-ChatqJobs) @() $onCfg @{} (Get-Date)
Check 'Continue at reset marks its cut-off as the ask''s answers do; skipped from the phone, auto-continue reads it declined, the ask has it answered' (
    $mkC -and $mkC.answer -eq 'continue' -and $mkC.source -eq 'phone' -and @($mkC.seq) -contains [int]$jC.seq -and $mkC.sessionId -eq $idBc -and
    (Read-ChatqAskState)[$keyC] -and $skC.Ok -and $stMarked.State -eq 'declined' -and $stBare.State -eq 'ready') "$keyC / $($mkC | ConvertTo-Json -Compress) / $($skC.Say) / $($stMarked.State) $($stBare.State)"
# queued again, as the checks below found it: the scan leaves a chat with a job alone
Set-ChatqJobState (Find-ChatqJob $jC.id -Exact) 'queued' 'test: back for the scan below'
$full0 = [int](Get-ChatqReplyState).down.full
$n0 = $script:BdJoins.Count
$r = & $bdSend (& $bdSeal 'read' ([ordered]@{ h = $hA }))
Check 'Read the last answer, by the chat''s handle: the turn on the down topic, no push, counted as a whole answer' ($r.Payload.kind -eq 'reply' -and
    (@($r.Payload.parts | ForEach-Object { $_.s }) -join '|') -like '*Done: all good*' -and $script:BdJoins.Count -eq $n0 -and [int](Get-ChatqReplyState).down.full -eq $full0 + 1) "$($r.Payload | ConvertTo-Json -Compress -Depth 5)"
chatnotify -FullText off *> $null
$r = & $bdSend (& $bdSeal 'read' ([ordered]@{ h = $hA }))
chatnotify -FullText on *> $null
Check 'with whole answers off, Read the last answer by a handle is refused too, and says how to turn them on' ($r.Payload.kind -eq 'ack' -and -not $r.Payload.ok -and
    $r.Payload.say -like '*-FullText on*' -and $script:BdJoins.Count -eq $n0) "$($r.Payload.say)"
$r = & $bdSend (& $bdSeal 'status' $null)
Check 'Status: an ack with the queue''s status report' ($r.Payload.ok -and $r.Payload.act -eq 'status' -and $r.Payload.say -like 'chatq*') "$($r.Payload.say)"
$script:ChatqBoardCache = $null
$lst = (& $bdSend (& $bdSeal 'list' $null)).Payload
Check 'list (the chats and folders, not the overlay''s): chats with handles, their mode after the cap, folders chatq knows' ($lst.kind -eq 'list' -and @($lst.chats).Count -ge 3 -and
    @($lst.chats | Where-Object { $_.t -eq 'Radar viewer' })[0].h -cmatch '^[a-z2-7]{6}$' -and @($lst.chats | Where-Object { $_.id -eq $idBa.Substring(0, 8) })[0].m -eq 'acceptEdits' -and
    @($lst.chats | Where-Object { $_.id -eq $idBa.Substring(0, 8) })[0].mc -eq $true -and @($lst.folders | Where-Object { $_.n -eq 'projBoard' }).Count -eq 1) (
    "$(@($lst.chats).Count) chats: " + (@($lst.chats | Select-Object -First 6 | ForEach-Object { "$($_.id) $($_.t) $($_.h) $($_.m) $($_.mc)" }) -join ' | ') + ' / ' + (@($lst.folders | ForEach-Object { $_.n }) -join ','))

# --- a chat or a job that went on at the PC since the board --------------------------------
$bdTyped = {
    # a prompt typed at the PC, as Claude Code writes one, now
    param([string]$Path, [string]$Id, [string]$Text)
    Start-Sleep -Milliseconds 30
    $u = [ordered]@{ parentUuid = $null; isSidechain = $false; type = 'user'; message = [ordered]@{ role = 'user'; content = $Text }
        uuid = [guid]::NewGuid().ToString(); timestamp = (Get-Date).ToUniversalTime().ToString('o'); permissionMode = 'default'; cwd = $bdProj; sessionId = $Id }
    [System.IO.File]::AppendAllText($Path, ($u | ConvertTo-Json -Compress -Depth 6) + "`n", $utf8)
    Start-Sleep -Milliseconds 30
}
$null = Use-ChatqReplyState { param($st) $st.compose = @(); $st.composeRefusedAt = $null }
$idBm = '6f6f6f6f-6f6f-46f6-86f6-6f6f6f6f6f6f'
$pBm = New-FakeChat $bdProj $idBm 'Moved on' 2 @('begin') -Mode 'default'
$rowBm = Get-ChatqRowById -Id $idBm -Provider claude -Path $pBm
# the chat's handle, as a board or a list makes one
$bmChat = { (Register-ChatqPicks $bdRc @(@{ Key = "chat|$idBm"; Pick = @{ kind = 'chat'; sessionId = $idBm; provider = 'claude'; cwd = $bdProj; title = 'Moved on'; home = $claudeHome; path = $pBm } }))["chat|$idBm"] }
$hM = & $bmChat
& $bdTyped $pBm $idBm 'typed at the PC'
$jn = @(Get-ChatqJobs).Count
$r = & $bdSend (& $bdSeal 'send' ([ordered]@{ h = $hM; id = $idBm.Substring(0, 8); text = 'written for the old view' }))
Check 'send into a chat that took a prompt at the PC since the board: refused as out of date - the page asks again, the text kept - nothing queued' (
    -not $r.Payload.ok -and $r.Payload.say -eq 'that chat moved on at the PC - the list is out of date, refresh it' -and @(Get-ChatqJobs).Count -eq $jn) "$($r.Payload.say)"
& $bdQuiet
$r = & $bdSend (& $bdSeal 'continue' ([ordered]@{ h = $hM }))
Check 'Continue at reset the same: refused now, not queued and dropped later as already continued' (-not $r.Payload.ok -and
    $r.Payload.say -eq 'that chat moved on at the PC - the list is out of date, refresh it' -and @(Get-ChatqJobs).Count -eq $jn) "$($r.Payload.say)"
# the chat's last answer read since: that is what the phone was shown last
$bmA = [ordered]@{ parentUuid = $null; isSidechain = $false; message = [ordered]@{ model = 'claude-opus-5'; id = 'msg_bm'; type = 'message'; role = 'assistant'
        content = @([ordered]@{ type = 'text'; text = 'answered at the PC' }); stop_reason = 'end_turn' }
    type = 'assistant'; uuid = [guid]::NewGuid().ToString(); timestamp = (Get-Date).ToUniversalTime().ToString('o'); cwd = $bdProj; sessionId = $idBm }
[System.IO.File]::AppendAllText($pBm, ($bmA | ConvertTo-Json -Compress -Depth 8) + "`n", $utf8)
& $bdQuiet
$r = & $bdSend (& $bdSeal 'read' ([ordered]@{ h = $hM }))
$r2 = & $bdSend (& $bdSeal 'send' ([ordered]@{ h = $hM; id = $idBm.Substring(0, 8); text = 'written after reading it' }))
Check 'Read the last answer after the prompt at the PC: a send judged from then, and it goes' ($r.Payload.kind -eq 'reply' -and $r2.Payload.ok -and
    @(Get-ChatqJobs).Count -eq $jn + 1) "$($r.Payload.kind) / $($r2.Payload.say)"
# a board kept for its 10 s is dropped by the refusal: the one asked next is built afresh
$script:ChatqBoardCache = $null
$null = & $bdSend (& $bdSeal 'board' $null)
$cached = [bool]$script:ChatqBoardCache
& $bdTyped $pBm $idBm 'typed at the PC again'
& $bdQuiet
$r = & $bdSend (& $bdSeal 'send' ([ordered]@{ h = $hM; id = $idBm.Substring(0, 8); text = 'old view again' }))
Check 'an out of date refusal drops the board kept in memory, so the next is built with fresh handles' ($cached -and -not $r.Payload.ok -and $null -eq $script:ChatqBoardCache) "$cached / $($r.Payload.say)"
$hM = & $bmChat
$r = & $bdSend (& $bdSeal 'send' ([ordered]@{ h = $hM; id = $idBm.Substring(0, 8); text = 'written for the new view' }))
Check 'the board asked for again, the send goes' ($r.Payload.ok -and @(Get-ChatqJobs).Count -eq $jn + 2) "$($r.Payload.say)"
# jobs the board showed, changed at the PC since
$jBf = (New-ChatqJob -Row $rowBm -Prompt 'failed here' -Kind prompt).Job
Complete-ChatqJob $jBf 'failed' ([pscustomobject]@{ kind = 'failed'; reason = 'broke' }) 'broke'
$jBn = (New-ChatqJob -Row $rowBm -Prompt 'asks here' -Kind prompt).Job
Complete-ChatqJob $jBn 'needs-input' ([pscustomobject]@{ kind = 'needs-input'; reason = 'asked' }) 'asked'
$script:ChatqBoardCache = $null
$b6 = (& $bdSend (& $bdSeal 'board' $null)).Payload
$qm = @{}
foreach ($q in @($b6.queue)) { $qm[[int]$q.n] = $q }
$null = Reset-ChatqJob (Find-ChatqJob $jBf.id -Exact)
& $bdQuiet
$r = & $bdSend (& $bdSeal 'skip' ([ordered]@{ h = $qm[[int]$jBf.seq].h; n = [int]$jBf.seq }))
Check 'Skip on a failed job the PC queued again since the board: refused as out of date, the requeue kept' (-not $r.Payload.ok -and
    $r.Payload.say -eq "#$($jBf.seq) is queued now - the list is out of date, refresh it" -and (Find-ChatqJob $jBf.id -Exact).state -eq 'queued') "$($r.Payload.say)"
& $bdTyped $pBm $idBm 'answered at the PC'
& $bdQuiet
$r = & $bdSend (& $bdSeal 'allow' ([ordered]@{ h = $qm[[int]$jBn.seq].h; n = [int]$jBn.seq }))
$jBn2 = Find-ChatqJob $jBn.id -Exact
Check 'Allow edits & continue on a job answered in its chat at the PC: refused, no mode raised, the job closed as answered there' (-not $r.Payload.ok -and
    $r.Payload.say -eq "#$($jBn.seq) was answered in the chat at the PC and is closed - the list is out of date, refresh it" -and $jBn2.state -eq 'skipped' -and
    -not $jBn2.mode -and $jBn2.result.reason -eq 'answered in the chat') "$($r.Payload.say) / $($jBn2.state) $($jBn2.mode)"
$jBf2 = (New-ChatqJob -Row $rowBm -Prompt 'failed again' -Kind prompt).Job
Complete-ChatqJob $jBf2 'failed' ([pscustomobject]@{ kind = 'failed'; reason = 'broke' }) 'broke'
$script:ChatqBoardCache = $null
$b7 = (& $bdSend (& $bdSeal 'board' $null)).Payload
$hF2 = @($b7.queue | Where-Object { [int]$_.n -eq [int]$jBf2.seq })[0].h
& $bdTyped $pBm $idBm 'went on at the PC'
& $bdQuiet
$r = & $bdSend (& $bdSeal 'retry' ([ordered]@{ h = $hF2; n = [int]$jBf2.seq }))
Check 'Retry on a failed job whose chat took a prompt since the board: refused, nothing sent into it' (-not $r.Payload.ok -and
    $r.Payload.say -eq "the chat of #$($jBf2.seq) moved on at the PC - the list is out of date, refresh it" -and (Find-ChatqJob $jBf2.id -Exact).state -eq 'failed') "$($r.Payload.say)"
foreach ($j in @(Get-ChatqJobs | Where-Object { $_.sessionId -eq $idBm })) { $null = Remove-ChatqJob $j 'test' }
Remove-Item -LiteralPath $pBm -Force -EA SilentlyContinue
& $bdQuiet

# --- read on an alert, and the scan with no overlay --------------------------------------
$liveJob = ConvertTo-ChatqLiveJob @{ sessionId = $idBa; title = 'Parser'; path = $pBa; cwd = $bdProj; home = $claudeHome }
$ra = New-ChatqReplyAlert -Event 'done' -Job $liveJob -Rc $bdRc
$n0 = $script:BdJoins.Count
$script:BdSeq++
$script:BdFeed = ([ordered]@{ id = "bdmsg$($script:BdSeq)"; time = 1; event = 'message'; topic = 't'; message = (Protect-ChatqReplyMessage -Key $bdKey -Aid $ra.Aid -Act read) } | ConvertTo-Json -Compress)
$script:BdDown.Clear()
$null = Invoke-ChatqReplyPoll -Force
$rd = @($script:BdDown | Where-Object { $_.Headers['X-Title'] -eq $ra.Aid })[0]
$rdo = if ($rd) { (Unprotect-ChatqDownMessage $rd.Body $bdD $ra.Aid).Payload } else { $null }
Check 'read on a live alert: the whole answer on the down topic under the alert''s id, no push, a use of the alert counted' ($rdo.kind -eq 'reply' -and $rdo.ref -eq $ra.Aid -and
    $script:BdJoins.Count -eq $n0 -and (Get-ChatqReplyState).alerts[$ra.Aid].uses -eq 1) "$($script:BdDown.Count) downs"
# the link made again as the whole answer goes (Update-ChatqReplyFull) keeps
# what the first one carried: a soon usage alert's w=1, a permission card's r=
$raU = New-ChatqReplyAlert -Event 'usage' -Job $null -Rc $bdRc -UsageKind soon
Update-ChatqReplyFull $bdRc $raU 'usage' $null
$raP = New-ChatqReplyAlert -Event 'permission' -Job $liveJob -Rc $bdRc -Card '{"v":1,"t":"Bash","w":"git push","u":1,"h":"AAAAAAAAAAAAAAAAAAAAAA"}'
$cardWas = [regex]::Match([string]$raP.Link, '[#&]r=([^&]+)').Groups[1].Value
Update-ChatqReplyFull $bdRc $raP 'permission' $liveJob
Check 'a link made again after the whole answer keeps a soon alert''s w=1 and a permission card''s r=, and adds neither to the other' (
    [string]$raU.Link -match '[#&]w=1(&|$)' -and [string]$raU.Link -notmatch '[#&]r=' -and $cardWas -like 'chatq1c.*' -and
    [string]$raP.Link -match ('[#&]r=' + [regex]::Escape($cardWas) + '(&|$)') -and [string]$raP.Link -notmatch '[#&]w=') "$($raU.Link) | $($raP.Link)"
# the overlay's snapshot old: the board scans instead, and says so
$idBd = 'b3b3b3b3-b3b3-4b3b-8b3b-b3b3b3b3b3b3'
$pBd = New-FakeChat $bdProj $idBd 'Scan cut chat' 0.1 @('scan me') -CutOff -ResetsAt ([DateTimeOffset]::UtcNow.AddHours(3).ToUnixTimeSeconds())
$old = [ordered]@{} + $snap
$old.at = $nowMs - 600000
Save-ChatqText $script:ChatOverlayPath ($old | ConvertTo-Json -Depth 8 -Compress)
$sessDir = Join-Path $claudeHome 'sessions'
$null = New-Item -ItemType Directory -Path $sessDir -Force
Save-ChatqText (Join-Path $sessDir '4747.json') (@{ pid = 4747; sessionId = $idBb; cwd = $bdProj; status = 'waiting'; waitingFor = 'permission'; kind = 'interactive'; entrypoint = 'claude-vscode'; updatedAt = $nowMs } | ConvertTo-Json -Compress)
$script:ChatqAliveSeam = { param($e) [string]$e.SessionId -eq $idBb }
try { $scan = (Get-ChatqPhoneBoard).Body } finally { $script:ChatqAliveSeam = $bdWas.Alive; Remove-Item -LiteralPath (Join-Path $sessDir '4747.json') -Force -EA SilentlyContinue }
$scanOpen = @($scan.open | ForEach-Object { "$($_.state):$($_.t)" }) -join '|'
Check 'no fresh snapshot: the scan - the registry''s open chats with their titles, the chats the limit cut off, and "from" scan for the page to say so' ($scan.from -eq 'scan' -and
    $scanOpen -eq 'waiting:Radar viewer' -and @($scan.cut | Where-Object { $_.t -eq 'Scan cut chat' -and $_.reset }).Count -eq 1 -and
    -not @($scan.cut | Where-Object { $_.t -eq 'Plugin unification' }).Count -and $scan.open[0].where -eq 'vscode') "$scanOpen / cut $(@($scan.cut | ForEach-Object { "$($_.t) $($_.reset)" }) -join ',')"
# a board from a scan is kept past the page's 30 s refresh, and its cut-off
# look reads no transcript twice
$script:ChatqBoardCache = $null
$sa1 = Get-ChatqPhoneBoardAnswer $bdRc 'scanaaaaaa'
$reads1 = $script:ChatqCutOffReads
$script:ChatqBoardCache.At = (Get-Date).AddSeconds(-25)
$sa2 = Get-ChatqPhoneBoardAnswer $bdRc 'scanbbbbbb'
$script:ChatqBoardCache = $null
$sa3 = Get-ChatqPhoneBoardAnswer $bdRc 'scancccccc'
Check 'a board from a scan: sent again 25 s on, past the page''s 30 s refresh; built again, no transcript read twice' ($sa1.Body.from -eq 'scan' -and -not $sa1.Cached -and
    $sa2.Cached -and $sa2.Body.ref -eq 'scanbbbbbb' -and -not $sa3.Cached -and $script:ChatqCutOffReads -eq $reads1) "$($sa1.Cached) $($sa2.Cached) $($sa3.Cached) / reads $reads1 then $($script:ChatqCutOffReads)"
$script:ChatqBoardCache = $null
Remove-Item -LiteralPath $script:ChatOverlayPath -Force -EA SilentlyContinue
# the list's folders: one on another machine is offered, never looked at -
# a share asleep would hold the watcher's tick
$csWas = if (Test-Path -LiteralPath $script:ChatConsoleStatePath) { [System.IO.File]::ReadAllText($script:ChatConsoleStatePath, $utf8) } else { $null }
Save-ChatqJson $script:ChatConsoleStatePath ([pscustomobject]@{ folders = @('\\nohost.invalid\share\farproj', $bdProj) })
try { $lsNet = Get-ChatqPhoneList $bdRc -Quick }
finally { if ($null -ne $csWas) { [System.IO.File]::WriteAllText($script:ChatConsoleStatePath, $csWas, $utf8) } else { Remove-Item -LiteralPath $script:ChatConsoleStatePath -Force -EA SilentlyContinue } }
Check 'the list: a folder on another machine is offered without a look at it (Test-ChatOverlayFolder)' (@($lsNet.Body.folders | Where-Object { $_.n -eq 'farproj' }).Count -eq 1) "$(@($lsNet.Body.folders | ForEach-Object { $_.n }) -join ',')"

# --- listening all the time, the poll's pace, the state's pruning --------------------------
$null = Use-ChatqReplyState { param($st) $st.openUntil = $null; $st.hotUntil = $null }
$openBefore = Test-ChatqReplyOpen
$sp0 = $script:BdSpawns
$env:CHATQ_WATCHER = $null
$said = (chatnotify -Listen always 6>&1 | Out-String)
$env:CHATQ_WATCHER = '1'
$openAlways = Test-ChatqReplyOpen
$stat = Get-ChatqPhoneStatusText
Check 'chatnotify -Listen always: the watcher listens with no alert out, one is started to, and the status says listening all the time' (-not $openBefore -and $openAlways -and
    (Get-ChatqReplyState).standing -eq $true -and $script:BdSpawns -eq $sp0 + 1 -and $said -like '*listening all the time*' -and $stat -like '*listening all the time*whole answers on*') "$said / $stat"
Check 'the pace: 20 s listening all the time, 15 s with an alert out, 6 s just after the phone asked; 30 and 10 inside a run' ((Get-ChatqReplyPollSeconds) -eq 20 -and (Get-ChatqReplyPollSeconds -InRun) -eq 30 -and
    $(Open-ChatqReplyWindow $bdRc; (Get-ChatqReplyPollSeconds) -eq 15)) ''
$null = Close-ChatqReplyWindow
Check 'chatqrun -Stop (Close-ChatqReplyWindow): listening all the time stops too, until a shell or the overlay starts it' (-not (Test-ChatqReplyOpen) -and -not (Get-ChatqReplyState).standing) ''
$null = Start-ChatqReplyStanding
$cfgNoKey = Get-ChatqConfig
$cfgNoKey.reply.PSObject.Properties.Remove('key')
Check 'a shell''s start begins it again; no phone paired, it listens for nothing' ((Test-ChatqReplyOpen) -and -not (Test-ChatqReplyOpen $cfgNoKey)) ''
chatnotify -Listen alerts *> $null
Check '-Listen alerts: only while an alert is out again' (-not (Test-ChatqReplyOpen) -and (Get-ChatqReplyConfig).Listen -eq 'alerts') ''
$null = Use-ChatqReplyState {
    param($st)
    $st.picks['aaaaaa'] = @{ kind = 'chat'; sessionId = 'x'; at = (Get-ChatqStamp); expires = (Get-Date).AddMinutes(-5).ToUniversalTime().ToString('o') }
    $st.compose = @(@{ at = (Get-Date).AddHours(-2).ToUniversalTime().ToString('o'); act = 'send' }, @{ at = (Get-ChatqStamp); act = 'board' })
}
$stP = Get-ChatqReplyState
Check 'a save prunes picks past their expiry and acts older than the hour they count in' (-not $stP.picks.ContainsKey('aaaaaa') -and @($stP.compose).Count -eq 1) "$(@($stP.compose).Count)"
$rawWas = [System.IO.File]::ReadAllText($script:ChatqReplyPath, $utf8)
[System.IO.File]::WriteAllText($script:ChatqReplyPath, "{`"picks`": [not json", $utf8)
$threw = $false
try { $null = Get-ChatqReplyState } catch { $threw = $true }
[System.IO.File]::WriteAllText($script:ChatqReplyPath, $rawWas, $utf8)
Check 'and a file that cannot be read still throws rather than read as empty' $threw ''

# --- the settings ---------------------------------------------------------------------------
$bad = @(
    (Set-ChatqNotifyConfig @{ FullText = 'maybe' }).Error
    (Set-ChatqNotifyConfig @{ FullMax = 10 }).Error
    (Set-ChatqNotifyConfig @{ Compose = 'sometimes' }).Error
    (Set-ChatqNotifyConfig @{ NewMode = 'godMode' }).Error
    (Set-ChatqNotifyConfig @{ Listen = 'never'; FullText = 'off' }).Error
)
Check 'a value that is not one of the five settings'' saves nothing - the rest of the change with it' (@($bad | Where-Object { $_ }).Count -eq 5 -and (Get-ChatqReplyConfig).Full) ($bad -join ' | ')
$ok = Set-ChatqNotifyConfig @{ FullText = 'off'; FullMax = 5000; Compose = $false; NewMode = 'plan'; Listen = 'alerts' }
$rcS = Get-ChatqReplyConfig
Check 'each saves: full off, 5000 characters, compose off, new chats in plan' (-not $ok.Error -and -not $rcS.Full -and $rcS.FullMax -eq 5000 -and -not $rcS.Compose -and $rcS.NewMode -eq 'plan') ''
$null = Set-ChatqNotifyConfig @{ FullText = $true; Compose = 'on'; NewMode = 'bypassPermissions' }
$rcS = Get-ChatqReplyConfig
$said = (chatnotify 6>&1 | Out-String)
Check 'a new chat''s mode above the cap is brought down to it; chatnotify lists the three settings' ($rcS.NewMode -eq 'bypassPermissions' -and (Limit-ChatqPhoneMode $rcS.NewMode $rcS.MaxMode).Mode -eq 'acceptEdits' -and
    $said -like '*whole answers on*board and new chats on*listen while an alert is out*') $said
$null = Set-ChatqNotifyConfig @{ NewMode = 'default' }

# --- the setup window's three boxes, drawn off-screen ----------------------------------------
if ($script:ChatqIsWindows) {
    $wpfBoard = @"
`$env:CHATQ_OVERLAY = '1'
. '$(Join-Path $sb 'tool\claude-codex-chat-manager.ps1')'
Set-StrictMode -Off
`$null = Set-ChatqNotifyConfig @{ FullText = 'off'; Listen = 'alerts' }
`$w = New-ChatqPhoneSetupWindow -Theme dark
`$U = `$w.Tag
`$was = "`$(`$U.FullBox.IsChecked)/`$(`$U.ComposeBox.IsChecked)/`$(`$U.ListenBox.IsChecked)"
`$clean = -not (Test-ChatqPhoneSetupDirty `$U)
`$U.ListenBox.IsChecked = `$true
`$U.FullBox.IsChecked = `$true
`$dirty = Test-ChatqPhoneSetupDirty `$U
`$c = (Get-ChatqPhoneSetupChanges `$U).Changes
`$null = Set-ChatqNotifyConfig @{ FullText = 'on' }
"`$was|`$clean|`$dirty|`$(`$c.Listen)|`$(`$c.FullText)|`$(`$c.ContainsKey('Compose'))|`$(`$U.ListenNote.Text)"
"@
    $wOut = Invoke-Sta 'board-setup' $wpfBoard
    $wp = "$wOut" -split '\|'
    Check 'the setup window: whole answers, the board and listening all the time, read from config.json; a tick is unsaved, and Save hands on only what changed' (
        $wp[0] -eq 'False/True/False' -and $wp[1] -eq 'True' -and $wp[2] -eq 'True' -and $wp[3] -eq 'always' -and $wp[4] -eq 'True' -and $wp[5] -eq 'False' -and
        $wp[6] -like '*every 20 s*') "$wOut"
}

# --- put it all back ------------------------------------------------------------------------
foreach ($j in @(Get-ChatqJobs | Where-Object { $_.id -notin $bdJobsBefore })) { $j.state = 'skipped'; $null = Remove-ChatqJob $j 'test' }
Remove-Item -LiteralPath $pBa, $pBb, $pBc, $pBd -Force -EA SilentlyContinue
Remove-Item -LiteralPath $bdProj, $bdGone -Recurse -Force -EA SilentlyContinue
Remove-Item -LiteralPath $script:ChatqWakePath -Force -EA SilentlyContinue
if ($keyC) { Remove-Item -LiteralPath (Join-Path $script:ChatqAutoDir "$keyC.json") -Force -EA SilentlyContinue }
if ($null -ne $bdCfgWas) { [System.IO.File]::WriteAllText($script:ChatqConfigPath, $bdCfgWas, $utf8) } else { Remove-Item -LiteralPath $script:ChatqConfigPath -Force -EA SilentlyContinue }
Remove-Item -LiteralPath $script:ChatqReplyPath -Force -EA SilentlyContinue
$script:ChatqJoinSeam = $bdWas.Join
$script:ChatqReplyPollSeam = $bdWas.Poll
$script:ChatqDownSeam = $bdWas.Down
$script:ChatqSpawn = $bdWas.Spawn
$script:ChatqAliveSeam = $bdWas.Alive
$script:ChatqBoardCache = $null
$script:ChatqReplyPolledAt = $null; $script:ChatqReplyErrAt = $null; $script:ChatqReplySavedAt = $null
$script:ChatqReplySeen = @{}; $script:ChatqReplyHandled = @{}; $script:ChatqReplyJunkLog = @{}
$env:CHATQ_WATCHER = '1'
