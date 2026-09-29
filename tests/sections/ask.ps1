# tests/sections/ask.ps1: dot-sourced by tests/run-tests.ps1 in its turn,
# never on its own - it uses what the runner and the sections before it set.
#
# Claude's questions on the phone (src/ask.ps1, docs/phone-ask-spec.md): the
# pending AskUserQuestion call read from a transcript - not one answered, not
# a side chain's, not one a prompt came after - what the phone is shown of
# it, and where it rides: a waiting chat's board row, and a live needs input
# alert's whole answer, whole answers off included. A phone is paired here by
# writing its key; no Join, ntfy or down traffic leaves. Everything changed
# is put back at the end.

Section 'questions on the phone'
$akCfgWas = if (Test-Path -LiteralPath $script:ChatqConfigPath) { [System.IO.File]::ReadAllText($script:ChatqConfigPath, $utf8) } else { $null }
$akWas = @{ Join = $script:ChatqJoinSeam; Down = $script:ChatqDownSeam }
$script:AkDown = [System.Collections.Generic.List[object]]::new()
$script:ChatqDownSeam = { param($m, $u, $h, $b) $script:AkDown.Add([pscustomobject]@{ Method = $m; Url = $u; Headers = $h; Body = $b }); $null }
$script:ChatqJoinSeam = { param($u) $null }
Remove-Item -LiteralPath $script:ChatqReplyPath -Force -EA SilentlyContinue

$akProj = Join-Path (Join-Path $sb 'work') 'projAsk'
$null = New-Item -ItemType Directory -Path $akProj -Force
$akId = 'a5a5a5a5-a5a5-4a5a-8a5a-a5a5a5a5a5a5'
$akNow = (Get-Date).ToUniversalTime()
$akRecord = {
    param([string]$Type, $Content, [switch]$Side)
    $o = [ordered]@{ parentUuid = $null; isSidechain = [bool]$Side; type = $Type; uuid = [guid]::NewGuid().ToString(); timestamp = $akNow.ToString('o'); cwd = $akProj; sessionId = $akId }
    $o['message'] = if ($Type -eq 'user') { [ordered]@{ role = 'user'; content = $Content } } else { [ordered]@{ model = 'claude-opus-5'; role = 'assistant'; content = $Content } }
    ($o | ConvertTo-Json -Compress -Depth 12)
}
$akQ = {
    param([string]$Q, [string]$H, [string[]]$Labels, [switch]$Multi, [string]$Desc = 'what it means')
    [ordered]@{ question = $Q; header = $H; multiSelect = [bool]$Multi; options = @(foreach ($l in $Labels) { [ordered]@{ label = $l; description = "$l - $Desc" } }) }
}
$akCall = {
    param([string]$Id, [object[]]$Questions, [switch]$Side)
    & $akRecord 'assistant' @([ordered]@{ type = 'text'; text = 'One thing first.' }, [ordered]@{ type = 'tool_use'; id = $Id; name = 'AskUserQuestion'; input = [ordered]@{ questions = @($Questions) } }) -Side:$Side
}
$akResult = { param([string]$Id) & $akRecord 'user' @([ordered]@{ type = 'tool_result'; tool_use_id = $Id; content = 'Your questions have been answered' }) }
$hangul = [string][char]0xD55C + [char]0xAE00
$qLog = & $akQ "stability.log is the only always-on record. Which way? $hangul" 'Stability log' @('Integrate (recommended)', 'Just delete it', 'Leave it alone')
$qReach = & $akQ 'Where are the gateways?' 'Reach' @('Bench', 'Site fleet') -Multi
# a transcript of its own for each case: -N picks the chat's id, 0 the one the
# board and the alert are about
$akIdOf = { param([int]$N) if ($N) { 'a5a5a5a5-a5a5-4a5a-8a5a-a5a5a5a5a5' + $N.ToString('00') } else { $akId } }
$akWrite = { param([int]$N, [string[]]$Lines) $p = New-FakeChat $akProj (& $akIdOf $N) 'Feed test' 0.1 @('look at the feed') -Mode 'acceptEdits'; [System.IO.File]::AppendAllText($p, ($Lines -join "`n") + "`n", $utf8); $script:ChatqAskCache = @{}; $p }

# --- the pending call ------------------------------------------------------------------
$pA = & $akWrite 1 @((& $akCall 'toolu_askone' @($qLog, $qReach)))
$gotA = Get-ChatqPendingAsk $pA
Check 'a question pending: the call''s id, both questions in order, every option, Hangul intact, the chat''s mode' ($gotA -and $gotA.ToolUseId -eq 'toolu_askone' -and
    @($gotA.Questions).Count -eq 2 -and $gotA.Questions[0].t -ceq $qLog.question -and $gotA.Questions[0].h -eq 'Stability log' -and @($gotA.Questions[0].o).Count -eq 3 -and
    $gotA.Questions[0].o[0].l -eq 'Integrate (recommended)' -and $gotA.Questions[0].o[0].d -eq 'Integrate (recommended) - what it means' -and $gotA.Questions[1].m -and
    -not $gotA.Questions[0].m -and $gotA.Mode -eq 'acceptEdits' -and $gotA.At) "$($gotA | ConvertTo-Json -Compress -Depth 6)"
$script:ChatqAskCache[$pA].Result | Add-Member -NotePropertyName 'FromCache' -NotePropertyValue $true -Force
$gotAgain = Get-ChatqPendingAsk $pA
Check 'looked at again unchanged: the same answer, from the cache' ($gotAgain.FromCache -eq $true) ''
$pB = & $akWrite 2 @((& $akCall 'toolu_asktwo' @($qLog)), (& $akResult 'toolu_asktwo'))
Check 'answered - a tool_result for it follows: nothing pending' ($null -eq (Get-ChatqPendingAsk $pB)) ''
$pC = & $akWrite 3 @((& $akCall 'toolu_askthree' @($qLog)), (& $akRecord 'user' 'never mind, do it the other way'))
Check 'a prompt typed after it: nothing pending' ($null -eq (Get-ChatqPendingAsk $pC)) ''
$pD = & $akWrite 4 @((& $akCall 'toolu_askmain' @($qReach)), (& $akCall 'toolu_askside' @($qLog) -Side))
$gotD = Get-ChatqPendingAsk $pD
Check 'a side chain''s call is not the chat''s: the chat''s own is the one pending' ($gotD -and $gotD.ToolUseId -eq 'toolu_askmain' -and $gotD.Questions[0].h -eq 'Reach') "$($gotD.ToolUseId)"
$pE = & $akWrite 5 @((& $akCall 'toolu_askold' @($qReach)), (& $akResult 'toolu_askold'), (& $akRecord 'assistant' @([ordered]@{ type = 'text'; text = 'Done.' })))
Check 'an old call answered and the turn over: nothing pending' ($null -eq (Get-ChatqPendingAsk $pE)) ''
# far back in a long transcript: the tail starts inside a line
$pad = & $akRecord 'user' @([ordered]@{ type = 'tool_result'; tool_use_id = 'toolu_pad'; content = ('z' * 1500000) })
$pF = & $akWrite 6 @($pad, (& $akCall 'toolu_askfar' @($qLog)))
$gotF = Get-ChatqPendingAsk $pF
Check 'a transcript over 1 MB: the tail begins mid-line, and the call is still found' ((Get-Item -LiteralPath $pF).Length -gt 1MB -and $gotF -and $gotF.ToolUseId -eq 'toolu_askfar') "$($gotF.ToolUseId)"
Check 'no transcript, or none there: nothing, and no error' ($null -eq (Get-ChatqPendingAsk '') -and $null -eq (Get-ChatqPendingAsk (Join-Path $akProj 'none.jsonl'))) ''

# --- what the phone is shown ------------------------------------------------------------
$emoji = [char]::ConvertFromUtf32(0x1F600)
$qMany = [ordered]@{ question = 'Pick'; header = 'Many'; multiSelect = $false; options = @(1..5 | ForEach-Object { [ordered]@{ label = "L$_"; description = "D$_" } }) }
$longD = ('x' * 1999) + $emoji + ('y' * 600)
$qLong = [ordered]@{ question = 'Long'; header = 'Long'; multiSelect = $false; options = @([ordered]@{ label = 'A'; description = $longD }, [ordered]@{ label = 'B'; description = 'short' }) }
$shown = Get-ChatqAskShown @(ConvertTo-ChatqAskQuestions ([ordered]@{ questions = @($qMany, $qLong) }))
$sd = $shown.Questions[1].o[0].d
Check 'shown: 4 options at most, the rest counted; a 2600-character description cut at 2000, never through an emoji, marked' (@($shown.Questions[0].o).Count -eq 4 -and $shown.More -eq 1 -and
    $shown.Cut -and $shown.Questions[1].o[0].x -eq 1 -and $sd.Length -le 2000 -and -not [char]::IsHighSurrogate($sd[$sd.Length - 2]) -and -not $shown.Questions[1].o[1].Contains('x')) "$($sd.Length)"
$qBig = @(1..4 | ForEach-Object { [ordered]@{ question = "Q$_"; header = "H$_"; multiSelect = $false; options = @(1..4 | ForEach-Object { [ordered]@{ label = "L$_"; description = ('d' * (1200 + $_)) } }) } })
$big = Get-ChatqAskShown @(ConvertTo-ChatqAskQuestions ([ordered]@{ questions = $qBig }))
$bigLen = 0; foreach ($q in $big.Questions) { $bigLen += $q.t.Length + $q.h.Length; foreach ($o in $q.o) { $bigLen += $o.l.Length + $o.d.Length } }
$cutN = @($big.Questions | ForEach-Object { $_.o } | Where-Object { $_.Contains('x') }).Count
Check 'past 16 KB in all: the longest descriptions cut to 300 first, only as many as it takes' ($bigLen -le 16384 -and $big.Cut -and $cutN -gt 0 -and $cutN -lt 16) "$bigLen / $cutN cut"
# past the total even with every description at 300: it still ends
$qHuge = @(1..4 | ForEach-Object { [ordered]@{ question = ('q' * 2500); header = "H$_"; multiSelect = $false; options = @(1..4 | ForEach-Object { [ordered]@{ label = ('l' * 400); description = ('d' * 600) } }) } })
$huge = Get-ChatqAskShown @(ConvertTo-ChatqAskQuestions ([ordered]@{ questions = $qHuge }))
$hugeD = @($huge.Questions | ForEach-Object { $_.o } | ForEach-Object { $_.d.Length } | Sort-Object -Descending)[0]
Check 'a question too big even once every description is squeezed: the squeeze still ends, every description at 300 at most' ($huge.Cut -and $hugeD -le 300) "$hugeD"
$caseQs = @(ConvertTo-ChatqAskQuestions ([ordered]@{ questions = @((& $akQ 'Use A?' 'One' @('Yes', 'No')), (& $akQ 'use a?' 'Two' @('Yes', 'No'))) }))
$caseA = ConvertTo-ChatqAskAnswers $caseQs @(@(0), @(1)) @('', '')
Check 'two questions that differ only in case: two answers, each its own' ($caseA.Ok -and $caseA.Answers.Count -eq 2 -and $caseA.Answers['Use A?'] -ceq 'Yes' -and $caseA.Answers['use a?'] -ceq 'No') "$($caseA.Answers.Count)"
$ab = @(ConvertTo-ChatqAskQuestions ([ordered]@{ questions = @($qLog, $qReach) }))
$ab2 = @(ConvertTo-ChatqAskQuestions ([ordered]@{ questions = @($qLog, $qReach) }))
$qSwap = & $akQ $qLog.question 'Stability log' @('Just delete it', 'Integrate (recommended)', 'Leave it alone')
$qDesc = & $akQ $qLog.question 'Stability log' @('Integrate (recommended)', 'Just delete it', 'Leave it alone') -Desc 'another meaning'
Check 'the same questions: equal place by place; a swapped pair of options, or one description changed, is not' ((Test-ChatqAskSame $ab $ab2) -and
    -not (Test-ChatqAskSame $ab @(ConvertTo-ChatqAskQuestions ([ordered]@{ questions = @($qSwap, $qReach) }))) -and
    -not (Test-ChatqAskSame $ab @(ConvertTo-ChatqAskQuestions ([ordered]@{ questions = @($qDesc, $qReach) }))) -and -not (Test-ChatqAskSame $ab @($ab[0]))) ''
$view = Get-ChatqAskView $akId $pA
Check 'the view: the call id''s last 12, when, the questions as shown' ($view.k -eq 'toolu_askone' -and $view.at -and @($view.q).Count -eq 2 -and $view.more -eq 0) "$($view.k)"
Check 'a row''s words: one question by its header, two by both' ((Get-ChatqAskWhat $view) -eq '2 questions: Stability log, Reach' -and
    (Get-ChatqAskWhat (Get-ChatqAskView $akId $pF)) -eq 'a question: Stability log' -and @($view.q).Count -eq 2 -and $view.q[0].o[2].l -eq 'Leave it alone' -and -not $view.cut) "$(Get-ChatqAskWhat $view)"

# --- the board -----------------------------------------------------------------------------
$pG = & $akWrite 0 @((& $akCall 'toolu_askboard' @($qLog)))
$akMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$akSnap = [pscustomobject]@{ header = [pscustomobject]@{ usage = @() }; recent = @(); rows = @(
        [pscustomobject]@{ key = "s:$akId"; kind = 'session'; provider = 'claude'; status = 'waiting'; chat = 'waiting'; rank = 0; project = 'projAsk'; title = 'Feed test'; prompt = 'look'; detail = 'input needed'; since = $akMs; sessionId = $akId; cwd = $akProj; job = $null; where = 'vscode'; unread = $false }) }
$bNo = (ConvertTo-ChatqPhoneBoard -Snap $akSnap -Jobs @() -Eta @{}).Body
$bAsk = (ConvertTo-ChatqPhoneBoard -Snap $akSnap -Jobs @() -Eta @{} -Asks @{ $akId = (Get-ChatqAskView $akId $pG) }).Body
Check 'the board without -Asks: the waiting row as before, the registry''s words, no ask' ($bNo.open[0].what -eq 'input needed' -and -not $bNo.open[0].Contains('ask')) ''
Check 'with its question: the row says it, and carries it - the options with their descriptions' ($bAsk.open[0].what -eq 'a question: Stability log' -and
    $bAsk.open[0].ask.q[0].o[1].d -eq 'Just delete it - what it means' -and $bAsk.open[0].ask.q[0].t -ceq $qLog.question) "$($bAsk.open[0].what)"
Save-ChatqText $script:ChatOverlayPath ([ordered]@{ schema = 1; at = $akMs; header = [ordered]@{ usage = @() }; recent = @(); rows = @($akSnap.rows) } | ConvertTo-Json -Depth 8 -Compress)
$gb = (Get-ChatqPhoneBoard).Body
$gRow = @($gb.open | Where-Object { $_.id8 -eq $akId.Substring(0, 8) })[0]
Check 'the board as built: the waiting chat''s transcript found from its folder and id, its question on the row' ($gRow -and $gRow.ask -and $gRow.ask.q[0].h -eq 'Stability log' -and
    $gRow.what -eq 'a question: Stability log' -and $gRow.ask.k -eq 'toolu_askboard'.Substring(2)) "$($gRow | ConvertTo-Json -Compress -Depth 6)"
Remove-Item -LiteralPath $script:ChatOverlayPath -Force -EA SilentlyContinue

# --- a live needs input alert's whole answer ------------------------------------------------
$akD = New-ChatqRandomBytes 32
$akKey = ConvertTo-ChatqB64Url $akD
$cfg = Get-ChatqConfig
Set-ChatqProp $cfg 'reply' ([pscustomobject]@{ on = $true; topic = [pscustomobject](Protect-ChatqSecret 'chatq-asktopicasktopicasktopic'); key = [pscustomobject](Protect-ChatqSecret $akKey); phone = 'Ask phone'; pairedAt = (Get-ChatqStamp) })
foreach ($k in 'ntfy') { if ($cfg.PSObject.Properties[$k]) { $cfg.PSObject.Properties.Remove($k) } }
Save-ChatqJson $script:ChatqConfigPath $cfg
$null = Set-ChatqNotifyConfig @{ ApiKey = '0123456789abcdef0123456789abcdef'; Device = 'group.phone' }
$akRc = Get-ChatqReplyConfig
$live = ConvertTo-ChatqLiveJob @{ sessionId = $akId; title = 'Feed test'; path = $pG; cwd = $akProj }
$akOpen = { param($aid) $d = @($script:AkDown)[-1]; if ($d) { (Unprotect-ChatqDownMessage $d.Body $akD $aid).Payload } else { $null } }
$null = Use-ChatqReplyState { param($st) $st.down = @{ day = (Get-Date).ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture); full = 0; other = 0 } }
$script:AkDown.Clear()
$okFull = Send-ChatqReplyText $akRc 'askalertaa' 'needs input' $live
$rf = & $akOpen 'askalertaa'
Check 'needs input, whole answers on: the turn and the question it waits on, together' ($okFull -and $rf.kind -eq 'reply' -and @($rf.parts).Count -ge 1 -and
    $rf.ask.q[0].h -eq 'Stability log' -and @($rf.ask.q[0].o).Count -eq 3 -and [int](Get-ChatqReplyState).down.full -eq 1) "$($rf | ConvertTo-Json -Compress -Depth 7)"
chatnotify -FullText off *> $null
$akRc = Get-ChatqReplyConfig
$script:AkDown.Clear()
$okAlone = Send-ChatqReplyText $akRc 'askalertbb' 'needs input' $live
$ra = & $akOpen 'askalertbb'
$stA = Get-ChatqReplyState
Check 'whole answers off: the question goes alone - no parts - counted with the boards, not the whole answers' ($okAlone -and $ra.kind -eq 'reply' -and @($ra.parts).Count -eq 0 -and
    $ra.ask.q[0].t -ceq $qLog.question -and [int]$stA.down.full -eq 1 -and [int]$stA.down.other -eq 1 -and $stA.downSent['askalertbb']) "$($ra | ConvertTo-Json -Compress -Depth 7)"
$liveNone = ConvertTo-ChatqLiveJob @{ sessionId = $akId; title = 'Feed test'; path = $pB; cwd = $akProj }
$script:AkDown.Clear()
$okNone = Send-ChatqReplyText $akRc 'askalertcc' 'needs input' $liveNone
Check 'whole answers off and no question: nothing sent, as before, and why' (-not $okNone -and $script:AkDown.Count -eq 0 -and $script:ChatqReplyTextWhy -like 'whole answers are off*') "$($script:ChatqReplyTextWhy)"
$script:AkDown.Clear()
$okDone = Send-ChatqReplyText $akRc 'askalertdd' 'done' $live
Check 'a done alert carries no question, even with one pending' (-not $okDone -and $script:AkDown.Count -eq 0) ''
$queuedJob = [pscustomobject]@{ id = 'askqueuedjob'; provider = 'claude'; path = $pG; sessionId = $akId; title = 'Feed test' }
$script:AkDown.Clear()
$okJob = Send-ChatqReplyText $akRc 'askalertee' 'needs input' $queuedJob
Check 'a queued job''s alert: its runs cannot ask, so no question is looked for' (-not $okJob -and $script:AkDown.Count -eq 0) ''
$script:AkDown.Clear()
$okAgain = Send-ChatqReplyText $akRc 'askalertbb' 'needs input' $live -Again
Check 'asked again (act read) within 3 hours of an inline one: not sent twice - the page reloads it' (-not $okAgain -and $script:ChatqReplyTextWhy -like 'it went at*') "$($script:ChatqReplyTextWhy)"
chatnotify -FullText on *> $null

# === answering from the phone (Part B) =======================================================
$cfg = Get-ChatqConfig; Set-ChatqProp $cfg 'ask' ([pscustomobject]@{ on = $true }); Save-ChatqJson $script:ChatqConfigPath $cfg
$akRc = Get-ChatqReplyConfig
$askQs = @(ConvertTo-ChatqAskQuestions ([ordered]@{ questions = @($qLog, $qReach) }))

# --- the answer's words, and the decision line ----------------------------------------------
$tricky = "a<b>&'c`"d\e`nf$hangul"
Check 'a JSON string of our own: only the quote, the backslash and control characters escaped - < > & '' and Hangul as they are' (
    (ConvertTo-ChatqJsonString $tricky) -ceq ('"a<b>&''c\"d\\e\nf' + $hangul + '"') -and ((ConvertTo-ChatqJsonString $tricky) | ConvertFrom-Json) -ceq $tricky) (ConvertTo-ChatqJsonString $tricky)
$c1 = ConvertTo-ChatqAskAnswers $askQs @(@(1), @(0, 1)) @('', '')
Check 'answers: a label for a single choice, labels joined with ", " for a multiple one, keyed by the question' ($c1.Ok -and $c1.Answers[$qLog.question] -ceq 'Just delete it' -and
    $c1.Answers['Where are the gateways?'] -ceq 'Bench, Site fleet') "$($c1.Why) $($c1.Answers | ConvertTo-Json -Compress)"
$c2 = ConvertTo-ChatqAskAnswers $askQs @(@(), @(1)) @("  my own`tway$([char]0x200B) ", 'and the lab')
Check 'Other: alone for a single choice; after the labels for a multiple one; control and format characters made spaces, trimmed' ($c2.Ok -and
    $c2.Answers[$qLog.question] -ceq 'my own way' -and $c2.Answers['Where are the gateways?'] -ceq 'Site fleet, and the lab') "$($c2.Why) $($c2.Answers | ConvertTo-Json -Compress)"
$c3 = ConvertTo-ChatqAskAnswers $askQs @(@(), @()) @(('z' * 600), 'x')
Check 'Other past 500 characters: cut to 500' ($c3.Ok -and $c3.Answers[$qLog.question].Length -eq 500) "$($c3.Why)"
$bads = @(
    (ConvertTo-ChatqAskAnswers $askQs @(@(3), @(0)) @('', '')),
    (ConvertTo-ChatqAskAnswers $askQs @(@(0, 1), @(0)) @('', '')),
    (ConvertTo-ChatqAskAnswers $askQs @(@(0), @()) @('', '')),
    (ConvertTo-ChatqAskAnswers $askQs @(@(0)) @('')),
    (ConvertTo-ChatqAskAnswers $askQs @(@(0), @(1, 0)) @('', '')),
    (ConvertTo-ChatqAskAnswers $askQs @(@(0), @(0)) @('also this', '')),
    (ConvertTo-ChatqAskAnswers $askQs @(@('0'), @(0)) @('', ''))
)
Check 'refused: an option not there, two on a single choice, a question unanswered, not one per question, out of order, an option and Other on a single choice, an index that is a string' (
    @($bads | Where-Object { $_.Ok }).Count -eq 0) "$(@($bads | ForEach-Object { $_.Why }) -join ' | ')"
$qsRaw = '[{"question":"Which way? ' + $hangul + ' <x> & \"q\"","header":"Log","multiSelect":false,"options":[{"label":"A","description":"a"},{"label":"B","description":"b"}]}]'
$dec = New-ChatqAskDecision $qsRaw ([ordered]@{ ("Which way? $hangul <x> & `"q`"") = "B, it's <fine>" })
$decO = $dec | ConvertFrom-Json
Check 'the decision: allow for PermissionRequest, the questions spliced in byte for byte, the answers beside them - nothing else' ($dec.Contains('"questions":' + $qsRaw + ',"answers":') -and
    $decO.hookSpecificOutput.hookEventName -eq 'PermissionRequest' -and $decO.hookSpecificOutput.decision.behavior -eq 'allow' -and
    $decO.hookSpecificOutput.decision.updatedInput.answers.("Which way? $hangul <x> & `"q`"") -ceq "B, it's <fine>" -and -not $dec.Contains('deny') -and
    -not $dec.Contains('updatedPermissions') -and $dec.IndexOf("`n") -lt 0) $dec

# --- the answer as the hook believes it -----------------------------------------------------
$akAt = Get-Date
$mineReq = @{ Rid = 'mnopqrstuv'; Digest = (Get-ChatqAskDigest 'mnopqrstuv' $akId $qsRaw); Questions = $askQs; At = $akAt; Until = $akAt.AddMinutes(30) }
$akSealAlert = {
    param([string]$Rid, [string]$Qh, $A, $O, [int64]$Ts = 0, [string]$Nonce, [string]$Key = $akKey, [string]$Act = 'answer')
    $o = [ordered]@{ v = 1; act = $Act; text = ''; nonce = $(if ($Nonce) { $Nonce } else { ConvertTo-ChatqB64Url (New-ChatqRandomBytes 16) }); ts = $(if ($Ts) { $Ts } else { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }); rid = $Rid; qh = $Qh; a = $A; o = $O }
    Protect-ChatqReplyMessage -Key $Key -Aid 'askalertzz' -Payload ($o | ConvertTo-Json -Compress -Depth 5)
}
$akSealBoard = {
    param([string]$Rid, [string]$Qh, $A, $O, [string]$H = 'aaaaaa', [string]$Id8 = $akId.Substring(0, 8))
    $o = [ordered]@{ v = 3; act = 'answer'; h = $H; id = $Id8; rid = $Rid; qh = $Qh; a = $A; o = $O; nonce = (ConvertTo-ChatqB64Url (New-ChatqRandomBytes 16)); ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
    Protect-ChatqComposeMessage -Key $akKey -Cid (New-ChatqRandomName 10) -Payload ($o | ConvertTo-Json -Compress -Depth 5)
}
$aAns = @(@(1), @(0))
$akSt = @{ Nonces = @{} }
$tA = Test-ChatqAskAnswer $mineReq @{ raw = (& $akSealAlert 'mnopqrstuv' $mineReq.Digest $aAns @('', '')) } $akRc.Master $akSt
$tB = Test-ChatqAskAnswer $mineReq @{ raw = (& $akSealBoard 'mnopqrstuv' $mineReq.Digest $aAns @('', 'mine')) } $akRc.Master $akSt
Check 'the phone''s answer believed from an alert''s page (chatq1) and from the board (chatq3c): the answers made from the hook''s own questions' ($tA.Ok -and $tB.Ok -and
    $tA.Answers[$qLog.question] -ceq 'Just delete it' -and $tB.Answers['Where are the gateways?'] -ceq 'Bench, mine') "$($tA.Why) / $($tB.Why)"
$fixed = 'AAAAAAAAAAAAAAAAAAAAAA'
$refused = @(
    (Test-ChatqAskAnswer $mineReq @{ raw = (& $akSealAlert 'zzzzzzzzzz' $mineReq.Digest $aAns @('', '')) } $akRc.Master $akSt).Why,
    (Test-ChatqAskAnswer $mineReq @{ raw = (& $akSealAlert 'mnopqrstuv' 'QUJDREVGR0hJSktMTU5PUA' $aAns @('', '')) } $akRc.Master $akSt).Why,
    (Test-ChatqAskAnswer $mineReq @{ raw = (& $akSealAlert 'mnopqrstuv' $mineReq.Digest $aAns @('', '') ([DateTimeOffset]::UtcNow.AddHours(-2).ToUnixTimeMilliseconds())) } $akRc.Master $akSt).Why,
    (Test-ChatqAskAnswer $mineReq @{ raw = (& $akSealAlert 'mnopqrstuv' $mineReq.Digest $aAns @('', '') 0 $fixed) } $akRc.Master $akSt).Why,
    (Test-ChatqAskAnswer $mineReq @{ raw = (& $akSealAlert 'mnopqrstuv' $mineReq.Digest $aAns @('', '') 0 $fixed) } $akRc.Master $akSt).Why,
    (Test-ChatqAskAnswer $mineReq @{ raw = '{"act":"answer","rid":"mnopqrstuv"}' } $akRc.Master $akSt).Why,
    (Test-ChatqAskAnswer $mineReq @{ raw = (& $akSealAlert 'mnopqrstuv' $mineReq.Digest $aAns @('', '') -Key (ConvertTo-ChatqB64Url (New-ChatqRandomBytes 32))) } $akRc.Master $akSt).Why,
    (Test-ChatqAskAnswer $mineReq @{ raw = (& $akSealAlert 'mnopqrstuv' $mineReq.Digest @(@(5), @(0)) @('', '')) } $akRc.Master $akSt).Why,
    (Test-ChatqAskAnswer $mineReq @{ raw = (& $akSealAlert 'mnopqrstuv' $mineReq.Digest $aAns @('', '') -Act 'permit') } $akRc.Master $akSt).Why
)
Check 'refused: another question''s rid, a digest not its own, sent outside its time, a nonce twice (the first of the two is taken), unsealed, sealed under another key, an option not there, another act' (
    $refused[0] -like 'another question*' -and $refused[1] -like '*changed*' -and $refused[2] -like '*outside*' -and -not $refused[3] -and $refused[4] -like '*nonce*' -and
    $refused[5] -like 'not sealed*' -and $refused[6] -like 'not sealed*mac*' -and $refused[7] -like '*not there*' -and $refused[8] -like 'act permit*') ($refused -join ' | ')

# the page's own answers, sealed by the page (tests/fixtures/ask-vector.json,
# made by tests/fixtures/make-ask-vector.js; tests/board-page-check.js holds
# the page to the same file)
$av = [System.IO.File]::ReadAllText((Join-Path (Join-Path $here 'fixtures') 'ask-vector.json'), $utf8) | ConvertFrom-Json
$avAt = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$av.ts).LocalDateTime
$avQs = @(ConvertTo-ChatqAskQuestions ([ordered]@{ questions = @((& $akQ 'Q one' 'One' @('A', 'B')), (& $akQ 'Q two' 'Two' @('X', 'Y', 'Z') -Multi)) }))
$avReq = @{ Rid = $av.rid; Digest = $av.qh; Questions = $avQs; At = $avAt.AddMinutes(-1); Until = $avAt.AddMinutes(30) }
$avMaster = ConvertFrom-ChatqB64Url $av.master
$avSt = @{ Nonces = @{} }
$avA = Test-ChatqAskAnswer $avReq @{ raw = $av.alertMessage } $avMaster $avSt
$avSt = @{ Nonces = @{} }
$avB = Test-ChatqAskAnswer $avReq @{ raw = $av.composeMessage } $avMaster $avSt
Check 'the page''s vector: both of its sealed answers open here - from an alert and from the board - into the same answers, the Other text''s Hangul intact' ($avA.Ok -and $avB.Ok -and
    $avA.Answers['Q one'] -ceq 'A' -and $avA.Answers['Q two'] -ceq ('Y, Z, free text ' + $hangul) -and $avB.Answers['Q two'] -ceq $avA.Answers['Q two']) "$($avA.Why) / $($avB.Why)"

# --- the request, as the board and the watcher see it --------------------------------------
$script:ChatqAskAliveSeam = { param($Req) [string]$Req.rid -ne 'deadhookaa' }
New-ChatqDir $script:ChatqAskDir
$pH = & $akWrite 7 @((& $akCall 'toolu_askheld' @($qLog, $qReach)))
$idH = & $akIdOf 7
$callRaw = (@($qLog, $qReach) | ConvertTo-Json -Compress -Depth 10)
$akReq = {
    param([string]$Rid, [string]$State = 'open', [string]$Tid = 'toolu_askheld', [string]$Raw = $callRaw, [int]$Min = 60, [hashtable]$More, [datetime]$At = (Get-Date))
    $o = [ordered]@{ v = 1; rid = $Rid; state = $State; why = $null; session = $idH; cwd = $akProj; mode = 'default'; questionsRaw = $Raw; toolUseId = $Tid
        qh = (Get-ChatqAskDigest $Rid $idH $Raw); at = $At.ToUniversalTime().ToString('o'); until = $At.AddMinutes($Min).ToUniversalTime().ToString('o'); hookPid = $PID; cliPid = 1; changedAt = (Get-ChatqStamp) }
    if ($More) { foreach ($k in $More.Keys) { $o[$k] = $More[$k] } }
    Save-ChatqJson (Join-Path $script:ChatqAskDir "$Rid.req.json") $o
}
$viewOf = { $script:ChatqAskCache = @{}; Get-ChatqAskView $idH $pH }
$vNone = & $viewOf
& $akReq 'heldaaaaaa'
$vCan = & $viewOf
Check 'no request for it: can not, hook; one open, its hook alive: can - the rid, the digest made again, until' ($vNone.can -eq $false -and $vNone.why -eq 'hook' -and
    $vCan.can -eq $true -and $vCan.rid -eq 'heldaaaaaa' -and $vCan.qh -eq (Get-ChatqAskDigest 'heldaaaaaa' $idH $callRaw) -and $vCan.until) "$($vNone | ConvertTo-Json -Compress -Depth 2) / $($vCan.why)"
& $akReq 'deadhookaa' -At (Get-Date).AddSeconds(5)
$vDead = & $viewOf
& $akReq 'modeaaaaaa' 'declined' -At (Get-Date).AddSeconds(10) -More @{ why = 'mode'; mode = 'bypassPermissions' }
$vMode = & $viewOf
Check 'the newest request decides: its hook dead - late, with until; declined for the mode - mode, the chat''s and the cap' ($vDead.can -eq $false -and $vDead.why -eq 'late' -and $vDead.until -and
    $vMode.why -eq 'mode' -and $vMode.mode -eq 'bypassPermissions' -and $vMode.cap -eq 'acceptEdits') "$($vDead.why) / $($vMode | ConvertTo-Json -Compress -Depth 2)"
Remove-Item -LiteralPath (Join-Path $script:ChatqAskDir 'modeaaaaaa.req.json'), (Join-Path $script:ChatqAskDir 'deadhookaa.req.json') -Force
$otherRaw = (@($qReach, $qLog) | ConvertTo-Json -Compress -Depth 10)
& $akReq 'otherqsaaa' -Raw $otherRaw -At (Get-Date).AddSeconds(20)
& $akReq 'othertidaa' -Tid 'toolu_other' -At (Get-Date).AddSeconds(20)
$vOther = & $viewOf
Check 'a request with other questions, or another call''s id, is never the question''s: the open one stands' ($vOther.can -eq $true -and $vOther.rid -eq 'heldaaaaaa') "$($vOther.rid) $($vOther.why)"
Remove-Item -LiteralPath (Join-Path $script:ChatqAskDir 'otherqsaaa.req.json'), (Join-Path $script:ChatqAskDir 'othertidaa.req.json') -Force
$cfg = Get-ChatqConfig; $cfg.ask.on = $false; Save-ChatqJson $script:ChatqConfigPath $cfg
$vOff = & $viewOf
$cfg = Get-ChatqConfig; $cfg.ask.on = $true; Save-ChatqJson $script:ChatqConfigPath $cfg
Check 'answers from the phone off: can not, off' ($vOff.can -eq $false -and $vOff.why -eq 'off') "$($vOff.why)"

# --- the watcher: the phone's answer relayed, and the refusals ------------------------------
$akRelay = { param($Rid, $A = @(@(0), @(1)), $O = @('', ''), $Qh, $Sid = $idH, $Tp = $pH)
    if (-not $Qh) { $Qh = Get-ChatqAskDigest $Rid $idH $callRaw }
    $script:ChatqAskCache = @{}
    Invoke-ChatqAskReply ([pscustomobject]@{ act = 'answer'; rid = $Rid; qh = $Qh; a = $A; o = $O }) $Sid $Tp 'sealed-message-here' 'alert' $akRc 'Feed test' }
$rOk = & $akRelay 'heldaaaaaa'
$ansH = Read-ChatqJson (Join-Path $script:ChatqAskDir 'heldaaaaaa.ans.json')
Check 'an answer that checks out: dropped beside its request as posted, for the hook, and said - the chat and "unless answered at the PC first"' ($rOk.Ok -and
    $ansH.raw -eq 'sealed-message-here' -and $ansH.via -eq 'alert' -and $rOk.Say -like 'sent your answer to Feed test - it goes on, unless it was answered at the PC first' -and
    $script:ChatqAskSent['heldaaaaaa'].ToolUseId -eq 'toolu_askheld') "$($rOk.Say)"
Remove-Item -LiteralPath (Join-Path $script:ChatqAskDir 'heldaaaaaa.ans.json') -Force
& $akReq 'pcaaaaaaaa' 'pc'
& $akReq 'answeredaa' 'answered' -More @{ answeredAt = (Get-ChatqStamp) }
& $akReq 'timeoutaaa' 'timeout'
& $akReq 'deadhookaa'
& $akReq 'pastaaaaaa' -Min -1
$says = @(
    (& $akRelay 'no-such-ri').Say, (& $akRelay 'nosuchridx').Say, (& $akRelay 'heldaaaaaa' -Sid 'another-session').Say, (& $akRelay 'pcaaaaaaaa').Say, (& $akRelay 'answeredaa').Say,
    (& $akRelay 'timeoutaaa').Say, (& $akRelay 'deadhookaa').Say, (& $akRelay 'pastaaaaaa').Say, (& $akRelay 'heldaaaaaa' -Qh 'QUJDREVGR0hJSktMTU5PUA').Say, (& $akRelay 'heldaaaaaa' -A @(@(0), @())).Say,
    (& $akRelay 'heldaaaaaa' -Tp $pB).Say
)
Check 'refused, each said: no such request, another chat''s, answered at the PC, answered from the phone, too late (timed out, its hook gone, past its time), a changed digest, a question unanswered, the chat not waiting on it' (
    $says[0] -like 'that question is no longer held*' -and $says[1] -like 'that question is no longer held*' -and $says[2] -like 'that question is no longer held*' -and
    $says[3] -eq 'already answered at the PC' -and $says[4] -like 'already answered - from the phone at *' -and $says[5] -like 'too late*' -and $says[6] -like 'too late*' -and
    $says[7] -like 'too late*' -and $says[8] -like '*changed after it was shown*' -and $says[9] -like 'answer every question*' -and $says[10] -eq 'that chat is not waiting on that question any more') ($says -join ' | ')
Check 'a request whose hook was found gone is marked so' ((Read-ChatqJson (Join-Path $script:ChatqAskDir 'deadhookaa.req.json')).state -eq 'gone') ''
$cfg = Get-ChatqConfig; $cfg.ask.on = $false; Save-ChatqJson $script:ChatqConfigPath $cfg
$sOff = (& $akRelay 'heldaaaaaa').Say
$cfg = Get-ChatqConfig; $cfg.ask.on = $true; Save-ChatqJson $script:ChatqConfigPath $cfg
Check 'answers from the phone off: nothing answered, and how to turn them on' ($sOff -like 'nothing answered*chatnotify -Ask on*') $sOff

# the alert's act and the board's act reach it
$entry = @{ sessionId = $idH; path = $pH; cwd = $akProj; title = 'Feed test'; live = $true; provider = 'claude' }
$script:ChatqAskSent = @{}
$ir = Invoke-ChatqReply ([pscustomobject]@{ act = 'answer'; text = ''; rid = 'heldaaaaaa'; qh = $vCan.qh; a = @(@(0), @(1)); o = @('', '') }) $entry 'askalertzz' $akRc -Raw 'the raw one'
Check 'from an alert: act answer relayed, the raw message kept for the hook, the push says it' ($ir.Act -eq 'answer' -and $ir.Feedback -like 'sent your answer to Feed test*' -and
    (Read-ChatqJson (Join-Path $script:ChatqAskDir 'heldaaaaaa.ans.json')).raw -eq 'the raw one') "$($ir.Feedback)"
Remove-Item -LiteralPath (Join-Path $script:ChatqAskDir 'heldaaaaaa.ans.json') -Force
$icr = Invoke-ChatqCompose ([pscustomobject]@{ act = 'answer'; h = 'aaaaaa'; id = $idH.Substring(0, 8); rid = 'heldaaaaaa'; qh = $vCan.qh; a = @(@(0), @(1)); o = @('', '') }) @{ kind = 'chat'; sessionId = $idH; provider = 'claude'; cwd = $akProj; title = 'Feed test'; home = $null } -Cid 'klmnopqrst' -Rc $akRc -Raw 'the board one'
Check 'from the board: act answer on the chat''s handle, the transcript found from the chat, the ack says it' ($icr.Act -eq 'answer' -and $icr.Ok -and
    (Read-ChatqJson (Join-Path $script:ChatqAskDir 'heldaaaaaa.ans.json')).raw -eq 'the board one' -and $script:ChatqComposeActs['answer'].Kind -eq 'chat') "$($icr.Say)"

# --- did it land ----------------------------------------------------------------------------
$landOf = { param($Tid, $Answers) & $akResult $Tid | ForEach-Object { $o = $_ | ConvertFrom-Json; $o | Add-Member -NotePropertyName toolUseResult -NotePropertyValue ([pscustomobject]@{ questions = @(); answers = $Answers }) -Force; $o | ConvertTo-Json -Compress -Depth 8 } }
$script:AkJoins = [System.Collections.Generic.List[string]]::new()
$script:ChatqJoinSeam = { param($u) $script:AkJoins.Add($u); $null }
$mk = { param($n, [string]$Tid, [switch]$NoLine, $Answers, [switch]$Plain)
    $lines = @((& $akCall $Tid @($qLog)))
    if (-not $NoLine) { $lines += $(if ($Plain) { & $akResult $Tid } else { & $landOf $Tid $Answers }) }
    & $akWrite $n $lines }
$sent = [ordered]@{ ($qLog.question) = 'Just delete it' }
$pL1 = & $mk 11 'toolu_l1' -Answers ([pscustomobject]@{ ($qLog.question) = 'Just delete it' })
$pL2 = & $mk 12 'toolu_l2' -NoLine
$pL3 = & $mk 13 'toolu_l3' -Plain
$pL4 = & $mk 14 'toolu_l4' -Answers ([pscustomobject]@{ ($qLog.question) = 'Leave it alone' })
$t0 = (Get-Date).AddSeconds(-30)
$script:ChatqAskSent = @{
    l1aaaaaaaa = @{ Rid = 'l1aaaaaaaa'; At = $t0; ToolUseId = 'toolu_l1'; Answers = $sent; Transcript = $pL1; SessionId = (& $akIdOf 11); Title = 'One' }
    l2aaaaaaaa = @{ Rid = 'l2aaaaaaaa'; At = $t0; ToolUseId = 'toolu_l2'; Answers = $sent; Transcript = $pL2; SessionId = (& $akIdOf 12); Title = 'Two' }
    l3aaaaaaaa = @{ Rid = 'l3aaaaaaaa'; At = $t0; ToolUseId = 'toolu_l3'; Answers = $sent; Transcript = $pL3; SessionId = (& $akIdOf 13); Title = 'Three' }
    l4aaaaaaaa = @{ Rid = 'l4aaaaaaaa'; At = $t0; ToolUseId = 'toolu_l4'; Answers = $sent; Transcript = $pL4; SessionId = (& $akIdOf 14); Title = 'Four' }
    l5aaaaaaaa = @{ Rid = 'l5aaaaaaaa'; At = (Get-Date); ToolUseId = 'toolu_l1'; Answers = $sent; Transcript = $pL1; SessionId = (& $akIdOf 11); Title = 'Soon' }
}
$landed = Test-ChatqAskLanded
$pushText = @($script:AkJoins | ForEach-Object { $q = @{}; foreach ($p in ($_.Substring($_.IndexOf('?') + 1) -split '&')) { $k, $v = $p -split '=', 2; $q[$k] = [uri]::UnescapeDataString($v) }; $q['text'] }) -join ' | '
Check 'landed: its answers in the transcript - quiet; none yet - "did not take", pushed; no answers - "went on without", pushed; other answers - the PC''s won, quiet; under 20 s - not yet looked at' (
    $landed['l1aaaaaaaa'] -eq 'landed' -and $landed['l2aaaaaaaa'] -eq 'not taken' -and $landed['l3aaaaaaaa'] -eq 'dropped' -and $landed['l4aaaaaaaa'] -eq 'pc first' -and
    -not $landed.ContainsKey('l5aaaaaaaa') -and $script:ChatqAskSent.ContainsKey('l5aaaaaaaa') -and $script:AkJoins.Count -eq 2 -and $pushText -like '*Two did not take the answer*' -and
    $pushText -like '*Three went on without your answer*' -and (Get-ChatqAskMissed)) "$($landed | ConvertTo-Json -Compress) / $pushText"
$script:ChatqAskSent = @{}
# the hook held the answer back itself: said as that, not as the CLI failing
Remove-Item -LiteralPath (Join-Path $script:ChatqAskDir 'missed.json') -Force -EA SilentlyContinue
& $akReq 'l6aaaaaaaa' 'timeout'
$script:AkJoins.Clear()
$script:ChatqAskSent = @{ l6aaaaaaaa = @{ Rid = 'l6aaaaaaaa'; At = $t0; ToolUseId = 'toolu_l2'; Answers = $sent; Transcript = $pL2; SessionId = (& $akIdOf 12); Title = 'Six' } }
$held6 = Test-ChatqAskLanded
Check 'no tool_result, but the hook''s request says it timed out: pushed as not answered from the phone, and no "did not land" in the status' ($held6['l6aaaaaaaa'] -eq 'held back (timeout)' -and
    $script:AkJoins.Count -eq 1 -and -not (Get-ChatqAskMissed)) "$($held6 | ConvertTo-Json -Compress)"
$script:ChatqAskSent = @{}

# --- tidying data/ask ------------------------------------------------------------------------
& $akReq 'oldaaaaaaa' 'pc' -At (Get-Date).AddHours(-3) -Min 30 -More @{ changedAt = (Get-Date).AddHours(-2).ToUniversalTime().ToString('o') }
& $akReq 'newaaaaaaa' 'pc' -At (Get-Date).AddMinutes(-10) -Min 30
& $akReq 'deadhookaa' -At (Get-Date).AddMinutes(-1)
& $akReq 'overaaaaaa' -At (Get-Date).AddMinutes(-40) -Min 30
Remove-ChatqAskLeftovers
$left = @{}; foreach ($q in @(Get-ChatqAskRequests)) { $left[$q.rid] = $q.state }
Check 'tidying: an hour past its time and change, gone; a recent one kept; an open one whose hook is gone marked gone, one past its time timeout - neither deleted' (
    -not $left.ContainsKey('oldaaaaaaa') -and $left['newaaaaaaa'] -eq 'pc' -and $left['deadhookaa'] -eq 'gone' -and $left['overaaaaaa'] -eq 'timeout') "$($left | ConvertTo-Json -Compress)"
$script:ChatqAskAliveSeam = $null
Remove-Item -LiteralPath $script:ChatqAskDir -Recurse -Force -EA SilentlyContinue

# --- the hook, a real child ------------------------------------------------------------------
# claude played by a node that idles; its registry entry in the sandbox's
# config dir; the hook started as the plugin starts it, its stdin behind a BOM
$fakeClaude = Start-Process -FilePath (Get-Command node).Source -ArgumentList '-e', 'setInterval(function(){},1000)' -PassThru -WindowStyle Hidden
$idK = & $akIdOf 20
$pK = & $akWrite 20 @((& $akCall 'toolu_askhook' @($qLog, $qReach)))
New-ChatqDir (Join-Path $claudeHome 'sessions')
$regK = Join-Path (Join-Path $claudeHome 'sessions') "$($fakeClaude.Id).json"
$akReg = { param([string]$Ep = 'claude-vscode', [string]$Ver = '2.1.283')
    Save-ChatqJson $regK ([ordered]@{ pid = $fakeClaude.Id; sessionId = $idK; cwd = $akProj; startedAt = [DateTimeOffset]::new($fakeClaude.StartTime).ToUnixTimeMilliseconds()
            procStart = [string]$fakeClaude.StartTime.ToFileTimeUtc(); version = $Ver; kind = 'interactive'; entrypoint = $Ep; status = 'waiting'; waitingFor = 'input needed' }) }
& $akReg
$hookIn = { param([string]$Mode = 'default')
    ([ordered]@{ session_id = $idK; transcript_path = $pK; cwd = $akProj; permission_mode = $Mode; hook_event_name = 'PermissionRequest'; tool_name = 'AskUserQuestion'
        tool_input = [ordered]@{ questions = @($qLog, $qReach) } } | ConvertTo-Json -Compress -Depth 10) }
$runHook = {
    param([string]$In)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $psi.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + (Join-Path $sb 'tool\src\ask-hook.ps1') + '"'
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    # the hook writes UTF-8 bytes whatever the console's code page: read them so
    $psi.StandardOutputEncoding = $utf8; $psi.StandardErrorEncoding = $utf8
    $psi.EnvironmentVariables['CHATQ_ASK_STEP_MS'] = '100'
    $psi.EnvironmentVariables['CHATQ_ASK_WAIT_SECONDS'] = '60'
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    $b = [byte[]](0xEF, 0xBB, 0xBF) + $utf8.GetBytes($In)
    $p.StandardInput.BaseStream.Write($b, 0, $b.Length)
    $p.StandardInput.Close()
    [pscustomobject]@{ P = $p; Out = $out; Err = $err }
}
$waitReq = { param([string]$State = 'open', [int]$Sec = 40)
    $until = (Get-Date).AddSeconds($Sec)
    while ((Get-Date) -lt $until) {
        $q = @(Get-ChatqAskRequests | Where-Object { $_.session -eq $idK -and $_.state -eq $State })[0]
        if ($q -and ($State -ne 'open' -or $q.toolUseId)) { return $q }
        Start-Sleep -Milliseconds 200
    }
    $null }
$h1 = & $runHook (& $hookIn)
$q1 = & $waitReq
$ans1 = & $akSealAlert $q1.rid $q1.qh @(@(2), @(0, 1)) @('', 'the lab too')
Save-ChatqJson (Join-Path $script:ChatqAskDir "$($q1.rid).ans.json") ([ordered]@{ v = 1; rid = $q1.rid; via = 'alert'; raw = $ans1; at = (Get-ChatqStamp) })
$done1 = $h1.P.WaitForExit(20000)
$out1 = if ($done1) { $h1.Out.Result } else { '' }
$d1 = try { $out1 | ConvertFrom-Json } catch { $null }
$rawIn = Get-ChatqJsonRaw (& $hookIn) 'tool_input.questions'
Check 'the hook: its request written with the call it found, and a sealed answer turned into the one decision line - the questions as Claude sent them, the answers, exit 0' (
    $q1 -and $q1.toolUseId -eq 'toolu_askhook' -and $done1 -and $h1.P.ExitCode -eq 0 -and $d1 -and $d1.hookSpecificOutput.decision.behavior -eq 'allow' -and
    $out1.Contains('"questions":' + $rawIn + ',') -and $d1.hookSpecificOutput.decision.updatedInput.answers.($qLog.question) -ceq 'Leave it alone' -and
    $d1.hookSpecificOutput.decision.updatedInput.answers.'Where are the gateways?' -ceq 'Bench, Site fleet, the lab too' -and
    (Read-ChatqJson $q1.Path).state -eq 'answered') "done $done1 out '$out1' err '$(if ($done1) { $h1.Err.Result })' req $($q1 | ConvertTo-Json -Compress)"

Remove-Item -LiteralPath $script:ChatqAskDir -Recurse -Force -EA SilentlyContinue
$h2 = & $runHook (& $hookIn)
$q2 = & $waitReq
Save-ChatqJson (Join-Path $script:ChatqAskDir "$($q2.rid).ans.json") ([ordered]@{ v = 1; rid = $q2.rid; via = 'alert'; raw = '{"act":"answer"}'; at = (Get-ChatqStamp) })
Start-Sleep -Seconds 2
$stillUp = -not $h2.P.HasExited
[System.IO.File]::AppendAllText($pK, (& $akResult 'toolu_askhook') + "`n", $utf8)
$done2 = $h2.P.WaitForExit(20000)
Check 'a forged answer changes nothing - the hook keeps waiting; answered at the PC, it goes without a word' ($q2 -and $stillUp -and $done2 -and $h2.P.ExitCode -eq 0 -and
    $h2.Out.Result -eq '' -and (Read-ChatqJson $q2.Path).state -eq 'pc' -and (Read-ChatqJson $q2.Path).badAnswer) "up $stillUp done $done2 out '$(if ($done2) { $h2.Out.Result })' $((Read-ChatqJson $q2.Path) | ConvertTo-Json -Compress)"

Remove-Item -LiteralPath $script:ChatqAskDir -Recurse -Force -EA SilentlyContinue
$pK = & $akWrite 20 @((& $akCall 'toolu_askhook' @($qLog, $qReach)))
$h3 = & $runHook (& $hookIn 'bypassPermissions')
$done3 = $h3.P.WaitForExit(30000)
$q3 = @(Get-ChatqAskRequests)[0]
& $akReg -Ep 'claude-cli'
$h4 = & $runHook (& $hookIn)
$done4 = $h4.P.WaitForExit(30000)
$q4 = @(Get-ChatqAskRequests | Where-Object { $_.why -eq 'term' })[0]
& $akReg
Check 'gates: a chat above the phone''s mode cap, or in a terminal - declined, said to the page, no output, exit 0' ($done3 -and $h3.Out.Result -eq '' -and $h3.P.ExitCode -eq 0 -and
    $q3.state -eq 'declined' -and $q3.why -eq 'mode' -and $q3.mode -eq 'bypassPermissions' -and $done4 -and $h4.Out.Result -eq '' -and $q4.state -eq 'declined') "$($q3 | ConvertTo-Json -Compress) / $($q4.why)"
Remove-Item -LiteralPath $script:ChatqAskDir -Recurse -Force -EA SilentlyContinue
$cfg = Get-ChatqConfig; $cfg.ask.on = $false; Save-ChatqJson $script:ChatqConfigPath $cfg
$h5 = & $runHook (& $hookIn)
$done5 = $h5.P.WaitForExit(30000)
$cfg = Get-ChatqConfig; $cfg.ask.on = $true; Save-ChatqJson $script:ChatqConfigPath $cfg
Check 'answers from the phone off: the hook writes nothing and says nothing' ($done5 -and $h5.Out.Result -eq '' -and $h5.P.ExitCode -eq 0 -and -not @(Get-ChatqAskRequests).Count) ''
Stop-Process -Id $fakeClaude.Id -Force -EA SilentlyContinue
Remove-Item -LiteralPath $regK -Force -EA SilentlyContinue
Remove-Item -LiteralPath $script:ChatqAskDir -Recurse -Force -EA SilentlyContinue

# --- the plugin: installed and removed by Claude Code's CLI ----------------------------------
$script:AkCli = [System.Collections.Generic.List[string]]::new()
$script:AkCliFail = $null
$script:ChatqAskCliSeam = {
    param([string[]]$ArgList)
    $line = $ArgList -join ' '
    $script:AkCli.Add($line)
    if ($script:AkCliFail -and $line -like $script:AkCliFail) { return [pscustomobject]@{ Code = 1; Out = 'Error: no network' } }
    if ($line -eq 'plugin list --json') { return [pscustomobject]@{ Code = 0; Out = $script:AkPlugins } }
    if ($line -eq 'plugin marketplace list --json') { return [pscustomobject]@{ Code = 0; Out = $script:AkMarkets } }
    [pscustomobject]@{ Code = 0; Out = '' }
}
$script:AkPlugins = '[]'; $script:AkMarkets = '[]'
$cfg = Get-ChatqConfig; $cfg.ask.on = $false; Save-ChatqJson $script:ChatqConfigPath $cfg
$sOn = Set-ChatqNotifyConfig @{ Ask = 'on' }
$plugDir = Join-Path $script:ChatqData 'claude-plugin'
$hooksJ = Read-ChatqJson (Join-Path $plugDir 'chatq-ask\hooks\hooks.json')
$cmd = [string]$hooksJ.hooks.PermissionRequest[0].hooks[0].command
Check 'chatnotify -Ask on: the plugin written, the marketplace added and the plugin installed by claude''s own CLI, ask.on set after' ((Get-ChatqAskConfig).On -and
    ($script:AkCli -join ' | ') -eq "plugin list --json | plugin marketplace list --json | plugin marketplace add $plugDir --scope user | plugin install chatq-ask@chatq-local --scope user" -and
    $hooksJ.hooks.PermissionRequest[0].matcher -eq 'AskUserQuestion' -and [int]$hooksJ.hooks.PermissionRequest[0].hooks[0].timeout -eq 43260 -and
    $cmd -like '"*/WindowsPowerShell/v1.0/powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "*/src/ask-hook.ps1"' -and
    (Read-ChatqJson (Join-Path $plugDir '.claude-plugin\marketplace.json')).name -eq 'chatq-local') "$($script:AkCli -join ' | ') / $cmd / $(@($sOn.Messages | ForEach-Object { $_.Text }) -join ' | ')"
$script:AkCli.Clear()
$script:AkPlugins = '[{"id":"chatq-ask@chatq-local","version":"0.0.1-deadbeef","scope":"user","enabled":true}]'
$script:AkMarkets = '[{"name":"chatq-local","source":{"source":"directory","path":"D:\\elsewhere\\claude-plugin"}}]'
$null = Install-ChatqAskHook
Check 'on again, installed at another version from another folder: the marketplace replaced, then updated with the plugin' (($script:AkCli -join ' | ') -eq
    "plugin list --json | plugin marketplace list --json | plugin marketplace remove chatq-local | plugin marketplace add $plugDir --scope user | plugin marketplace update chatq-local | plugin update chatq-ask@chatq-local") ($script:AkCli -join ' | ')
Check 'and the status knows the old copy' ((Get-ChatqAskStatusText) -like 'on, but the hook points at an old copy*') (Get-ChatqAskStatusText)
$cfg = Get-ChatqConfig; $cfg.ask.on = $false; Save-ChatqJson $script:ChatqConfigPath $cfg
$script:AkPlugins = '[]'; $script:AkMarkets = '[]'
$script:AkCliFail = 'plugin install*'
$sFail = Set-ChatqNotifyConfig @{ Ask = 'on' }
$script:AkCliFail = $null
Check 'an install that fails: said, and ask.on stays off' (-not (Get-ChatqAskConfig).On -and (@($sFail.Messages | ForEach-Object { $_.Text }) -join ' ') -like '*stay off*claude plugin install failed: Error: no network*') (@($sFail.Messages | ForEach-Object { $_.Text }) -join ' | ')
$script:AkCli.Clear()
$sMan = Set-ChatqNotifyConfig @{ Ask = 'on'; AskManual = $true }
Check '-Manual: nothing run, the hooks block printed, ask.on set' ($script:AkCli.Count -eq 0 -and (Get-ChatqAskConfig).On -and (Get-ChatqAskConfig).Manual -and
    (@($sMan.Messages | ForEach-Object { $_.Text }) -join ' ') -like '*"PermissionRequest"*ask-hook.ps1*') (@($sMan.Messages | ForEach-Object { $_.Text }) -join ' | ')
$null = Set-ChatqNotifyConfig @{ Ask = 'off' }
$cfg = Get-ChatqConfig; $cfg.ask.manual = $false; Save-ChatqJson $script:ChatqConfigPath $cfg
$null = Set-ChatqNotifyConfig @{ Ask = 'on' }
$script:AkCli.Clear()
$null = Set-ChatqNotifyConfig @{ Ask = 'off' }
Check 'chatnotify -Ask off: ask.on cleared, the plugin uninstalled and its marketplace removed, the files gone' (-not (Get-ChatqAskConfig).On -and
    ($script:AkCli -join ' | ') -eq 'plugin uninstall chatq-ask@chatq-local | plugin marketplace remove chatq-local' -and -not (Test-Path -LiteralPath $plugDir)) ($script:AkCli -join ' | ')
$bw = Set-ChatqNotifyConfig @{ AskWait = 3 }
Check '-AskWait outside 5 to 720: refused, nothing saved' ($bw.Error -eq '-AskWait takes 5 to 720 minutes' -and (Get-ChatqAskConfig).WaitMinutes -eq 240) "$($bw.Error)"
$script:ChatqAskCliSeam = $null

# --- the setup window's questions box, never shown ---------------------------------------------
if ($script:ChatqIsWindows) {
    $cfg = Get-ChatqConfig
    if (-not ($cfg.PSObject.Properties['ask'] -and $cfg.ask)) { Set-ChatqProp $cfg 'ask' ([pscustomobject]@{}) }
    Set-ChatqProp $cfg.ask 'on' $true
    Save-ChatqJson $script:ChatqConfigPath $cfg
    $awTool = (Join-Path $sb 'tool\Charlie-and-the-chat-factory.ps1').Replace("'", "''")
    $awOut = Invoke-Sta 'ask-window' ((@'
$ErrorActionPreference = 'Stop'
$env:CHATQ_OVERLAY = '1'; $env:CHATQ_WATCHER = '1'
. '@TOOL@' *> $null
try {
    # the install runs in the setup window's background runspace: the seam stands in for claude there
    $script:ChatqPhoneSetupJobSeam = '$script:ChatqAskCliSeam = { param([string[]]$ArgList) $o = ""; if (($ArgList -join " ") -like "*list --json") { $o = "[]" }; [pscustomobject]@{ Code = 0; Out = $o } }'
    $w = New-ChatqPhoneSetupWindow -Theme dark
    $U = $w.Tag
    $a = "$([bool]$U.AskBox.IsChecked)|$($U.AskBox.IsEnabled)|$(-not (Test-ChatqPhoneSetupDirty $U))|$($U.AskHint.Text)|$($U.AskBox.ToolTip)"
    $U.AskBox.IsChecked = $false
    Update-ChatqPhoneSetupDirty $U
    $d1 = Test-ChatqPhoneSetupDirty $U
    $c1 = (Get-ChatqPhoneSetupChanges $U).Changes['Ask']
    $U.ReplyBox.IsChecked = $false
    Update-ChatqPhoneSetupDirty $U
    $en = $U.AskBox.IsEnabled
    $U.ReplyBox.IsChecked = $true
    Update-ChatqPhoneSetupDirty $U
    # off in the file, ticked in the window: Save runs the install in the background
    $cf = Get-ChatqConfig; $cf.ask.on = $false; Save-ChatqJson $script:ChatqConfigPath $cf
    Read-ChatqPhoneSetupForm $U
    $off = -not [bool]$U.AskBox.IsChecked
    $U.AskBox.IsChecked = $true
    Update-ChatqPhoneSetupDirty $U
    $d2 = Test-ChatqPhoneSetupDirty $U
    $c2 = (Get-ChatqPhoneSetupChanges $U).Changes['Ask']
    $saved = Save-ChatqPhoneSetup $U
    $kind = if ($U.Job) { $U.Job.Kind } else { '' }
    $note = $U.Status.Text
    $t0 = Get-Date
    while ($U.Job -and ((Get-Date) - $t0).TotalSeconds -lt 90) { Start-Sleep -Milliseconds 200; Update-ChatqPhoneSetupJob $U }
    $fin = "$([bool]$U.AskBox.IsChecked)/$($U.AskWas)/$(-not (Test-ChatqPhoneSetupDirty $U))/$(-not $U.Job)"
    Stop-ChatqPhoneSetupWork $U
    "ok|$a|$d1|$c1|$en|$off|$d2|$c2|$saved|$kind|$note|$fin|$((Get-ChatqAskConfig).On)|$($U.Status.Text)"
}
catch { "error|$($_.Exception.Message)" }
'@).Replace('@TOOL@', $awTool))
    $awp = "$awOut" -split '\|'
    Check 'the setup window''s questions box: ticked from ask.on, live while replies are on, its hint and tooltip; a tick is unsaved and Save hands on Ask, off' (
        $awp[0] -eq 'ok' -and $awp[1] -eq 'True' -and $awp[2] -eq 'True' -and $awp[3] -eq 'True' -and
        $awp[4] -like 'A question in a chat you run yourself shows on the phone with its choices; answer there or at the PC - the first answer counts. Adds a small hook to Claude Code, as a plugin.' -and
        $awp[5] -like 'This lets the phone answer for you in a chat.*chatnotify -ReplyPage*' -and
        $awp[6] -eq 'True' -and $awp[7] -eq 'off' -and $awp[8] -eq 'False') "$awOut"
    Check 'the box unticked, replies back on and ask.on off: a tick is unsaved and Save hands on Ask, on - to a background job, not the window''s thread' (
        $awp[0] -eq 'ok' -and $awp[9] -eq 'True' -and $awp[10] -eq 'True' -and $awp[11] -eq 'on' -and $awp[12] -eq 'True' -and $awp[13] -eq 'ask' -and
        $awp[14] -eq 'installing the question hook...') "$awOut"
    Check 'the install ends: ask.on set, the plugin written, the box and the file agree, the status says what Set-ChatqNotifyConfig said' (
        $awp[15] -eq 'True/True/True/True' -and $awp[16] -eq 'True' -and (Test-Path -LiteralPath (Join-Path $plugDir 'chatq-ask\hooks\hooks.json')) -and
        $awp[17] -like 'questions from the phone on*') "$awOut"
    Remove-Item -LiteralPath $plugDir -Recurse -Force -EA SilentlyContinue
}

# --- put it all back ------------------------------------------------------------------------
Remove-Item -LiteralPath $akProj -Recurse -Force -EA SilentlyContinue
Remove-Item -LiteralPath (Join-Path (Join-Path $claudeHome 'projects') (Get-Slug $akProj)) -Recurse -Force -EA SilentlyContinue
if ($null -ne $akCfgWas) { [System.IO.File]::WriteAllText($script:ChatqConfigPath, $akCfgWas, $utf8) } else { Remove-Item -LiteralPath $script:ChatqConfigPath -Force -EA SilentlyContinue }
Remove-Item -LiteralPath $script:ChatqReplyPath -Force -EA SilentlyContinue
$script:ChatqJoinSeam = $akWas.Join
$script:ChatqDownSeam = $akWas.Down
$script:ChatqAskCache = @{}
$script:ChatqBoardCache = $null
