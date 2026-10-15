# tests/sections/hover-card.ps1: dot-sourced by tests/run-tests.ps1 in its turn,
# never on its own - it uses what the runner and the sections before it set.

Section 'hover card'
# What a row's hover card says (Read-ChatOverlayCardTail,
# Get-ChatOverlayCardModel), from transcripts written here the way Claude
# Code 2.1.291 writes them - one content block an assistant line, a parallel
# batch's results after all its calls, the session's own fields last - and
# the card itself, in the STA process WPF needs, off every screen.
$hcDir = Join-Path $sb 'hover-card'
$null = New-Item -ItemType Directory -Path $hcDir -Force
$hcSid = '6c6c6c6c-6c6c-4c6c-8c6c-6c6c6c6c6c6c'
$hcCwd = 'C:\p\hc'
$hcStart = [DateTimeOffset]::UtcNow
$hcNowMs = $hcStart.ToUnixTimeMilliseconds()
$hcNow = $hcStart.LocalDateTime
$hcEnd = ',"userType":"external","entrypoint":"claude-vscode","cwd":"C:\\p\\hc","sessionId":"' + $hcSid + '","version":"2.1.291","gitBranch":"main"}'
# a line's time, $Min minutes before the section began: as written, and in ms
function HcAt([double]$Min) { $hcStart.AddMinutes(-$Min).ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [cultureinfo]::InvariantCulture) }
function HcMs([double]$Min) { $hcStart.AddMinutes(-$Min).ToUnixTimeMilliseconds() }
function HcPrompt([string]$Text, [double]$Min) {
    '{"parentUuid":null,"isSidechain":false,"promptId":"' + [guid]::NewGuid() + '","type":"user","message":{"role":"user","content":[{"type":"text","text":"' + $Text +
    '"}]},"uuid":"' + [guid]::NewGuid() + '","timestamp":"' + (HcAt $Min) + '","permissionMode":"auto","origin":{"kind":"human"},"promptSource":"sdk","turnOrigin":"human"' + $hcEnd
}
# Claude's words - or, -Synthetic, a limit's, which Claude Code writes itself
function HcText([string]$Text, [double]$Min, [switch]$Synthetic) {
    $model = if ($Synthetic) { '<synthetic>' } else { 'claude-opus-5-5' }
    $more = if ($Synthetic) { ',"error":"rate_limit","isApiErrorMessage":true' } else { '' }
    '{"parentUuid":null,"isSidechain":false,"message":{"model":"' + $model + '","id":"msg_' + [guid]::NewGuid().ToString('N') + '","type":"message","role":"assistant","content":[{"type":"text","text":"' +
    $Text + '"}],"stop_reason":"end_turn"}' + $more + ',"type":"assistant","uuid":"' + [guid]::NewGuid() + '","timestamp":"' + (HcAt $Min) + '"' + $hcEnd
}
function HcTool([string]$Id, [string]$Name, [string]$In, [double]$Min) {
    '{"parentUuid":null,"isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_' + $Id + '","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_' + $Id +
    '","name":"' + $Name + '","input":' + $In + ',"caller":{"type":"direct"}}],"stop_reason":"tool_use"},"type":"assistant","uuid":"' + [guid]::NewGuid() + '","timestamp":"' + (HcAt $Min) + '"' + $hcEnd
}
function HcResult([string]$Id, [double]$Min) {
    '{"parentUuid":null,"isSidechain":false,"promptId":"' + [guid]::NewGuid() + '","type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_' + $Id +
    '","type":"tool_result","content":"ok"}]},"uuid":"' + [guid]::NewGuid() + '","timestamp":"' + (HcAt $Min) + '","toolUseResult":{"stdout":"ok","stderr":""}' + $hcEnd
}
# a user record of Claude Code's own: its content as written, -More after it
function HcUser([string]$Content, [double]$Min, [string]$More = '') {
    '{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":' + $Content + '},"uuid":"' + [guid]::NewGuid() + '","timestamp":"' + (HcAt $Min) + '"' + $More + $hcEnd
}
function HcLast([string]$Text) { '{"type":"last-prompt","lastPrompt":"' + $Text + '","leafUuid":"' + [guid]::NewGuid() + '","sessionId":"' + $hcSid + '"}' }
# the lines, each ended by a newline - -Partial after them has none yet
function Write-HcChat([string]$Name, [string[]]$Lines, [string]$Partial = '') {
    $p = Join-Path $hcDir "$Name.jsonl"
    [System.IO.File]::WriteAllText($p, (($Lines -join "`n") + "`n" + $Partial), $utf8)
    $p
}
$hcBash = '{"command":"git status --short","description":"Show working tree status"}'
$hcBusyLines = @(
    (HcPrompt 'make the card' 9)
    (HcText 'Reading the panel first.' 8)
    (HcTool 'r1' 'Read' '{"file_path":"C:\\p\\hc\\src\\overlay-windows.ps1","offset":200}' 7)
    (HcResult 'r1' 6.9)
    (HcTool 'g1' 'Grep' '{"pattern":"Show-ChatOverlayChip","path":"C:\\p\\hc\\src"}' 6)
    (HcResult 'g1' 5.9)
    (HcTool 'e1' 'Edit' '{"replace_all":false,"file_path":"C:\\p\\hc\\src\\overlay-data.ps1","old_string":"a","new_string":"b"}' 3)
    (HcResult 'e1' 2.9)
    (HcTool 'm1' 'mcp__claude-vscode__getDiagnostics' '{}' 2)
    (HcResult 'm1' 1.9)
    (HcTool 'b1' 'Bash' $hcBash 0.5))
$hcBusy = Write-HcChat 'busy' $hcBusyLines
$hcR0 = $script:ChatOverlayCardReads
$tB = Read-ChatOverlayCardTail $hcBusy
Check 'a card''s read: the newest four calls, newest first, each with what it works on; the one with no result yet is going, since its line''s time' (
    (@($tB.Steps | ForEach-Object { $_.Name }) -join ',') -eq 'Bash,mcp__claude-vscode__getDiagnostics,Edit,Grep' -and $tB.Open.Id -eq 'toolu_b1' -and
    $tB.Open.Arg -eq 'git status --short' -and $tB.Open.At -eq (HcMs 0.5) -and $tB.Steps[2].Arg -eq 'C:\p\hc\src\overlay-data.ps1' -and
    $tB.Steps[3].Arg -eq 'Show-ChatOverlayChip' -and $tB.Steps[1].Arg -eq '' -and $script:ChatOverlayCardReads -eq $hcR0 + 1) (
    "$(@($tB.Steps | ForEach-Object { "$($_.Name)=$($_.Arg)" }) -join ' | ') / open $($tB.Open.Id) $($tB.Open.At) / reads $($script:ChatOverlayCardReads - $hcR0)")
Check 'and your newest prompt and Claude''s newest words, each with its time; the file''s length; not stopped, no todo list' (
    $tB.Prompt -eq 'make the card' -and $tB.PromptAt -eq (HcMs 9) -and $tB.Reply -eq 'Reading the panel first.' -and $tB.ReplyAt -eq (HcMs 8) -and
    $tB.Length -eq ([System.IO.FileInfo]::new($hcBusy)).Length -and -not $tB.Stopped -and $null -eq $tB.Todo) "$($tB.Prompt) $($tB.PromptAt) / $($tB.Reply) $($tB.ReplyAt) / $($tB.Length)"

$tP = Read-ChatOverlayCardTail (Write-HcChat 'batch' @(
        (HcPrompt 'two at once' 5)
        (HcTool 'p1' 'Read' '{"file_path":"C:\\p\\hc\\a.ps1"}' 4)
        (HcTool 'p2' 'Read' '{"file_path":"C:\\p\\hc\\b.ps1"}' 4)
        (HcResult 'p2' 3.9)))
$tP2 = Read-ChatOverlayCardTail (Write-HcChat 'batch2' @(
        (HcPrompt 'two at once' 5)
        (HcTool 'p1' 'Read' '{"file_path":"C:\\p\\hc\\a.ps1"}' 4)
        (HcTool 'p2' 'Read' '{"file_path":"C:\\p\\hc\\b.ps1"}' 4)
        (HcResult 'p1' 3.9)
        (HcResult 'p2' 3.9)))
Check 'a parallel batch: a call whose result has not come is going, though a later one''s has; with all of them in, none is' (
    $tP.Open.Id -eq 'toolu_p1' -and $null -eq $tP2.Open -and @($tP2.Steps).Count -eq 2) "$($tP.Open.Id) / $($tP2.Open.Id) $(@($tP2.Steps).Count)"

$hcDone = Write-HcChat 'done' @(
    (HcPrompt 'check it' 6)
    (HcTool 'd1' 'Bash' $hcBash 5)
    (HcResult 'd1' 4.9)
    (HcText 'All clean.\n\nNothing to commit.' 4.5)
    (HcLast 'check it')
    ('{"type":"ai-title","aiTitle":"Check it","sessionId":"' + $hcSid + '"}'))
$tD = Read-ChatOverlayCardTail $hcDone
Check 'a turn done: nothing going, its call among those before, Claude''s words whole, Claude Code''s own copy of your prompt' (
    $null -eq $tD.Open -and @($tD.Steps).Count -eq 1 -and $tD.Reply -eq "All clean.`n`nNothing to commit." -and $tD.ReplyAt -eq (HcMs 4.5) -and $tD.LastPrompt -eq 'check it') (
    "$($tD.Open.Id) $(@($tD.Steps).Count) / $($tD.Reply) / $($tD.LastPrompt)")

$hcStopLines = @(
    (HcPrompt 'push it' 3)
    (HcTool 's1' 'Bash' '{"command":"git push"}' 2)
    (HcUser '[{"type":"tool_result","content":"The user doesn''t want to proceed with this tool use.","is_error":true,"tool_use_id":"toolu_s1"}]' 1.5 ',"toolUseResult":"User rejected tool use","toolDenialKind":"user-rejected"')
    (HcUser '[{"type":"text","text":"[Request interrupted by user for tool use]"}]' 1.5))
$tS = Read-ChatOverlayCardTail (Write-HcChat 'stopped' $hcStopLines)
$tS2 = Read-ChatOverlayCardTail (Write-HcChat 'stopped2' ($hcStopLines + @(HcPrompt 'no, push to the fork' 1)))
Check 'stopped by you: the newest record says so, and when - the call you turned down not going; a prompt after it starts again' (
    $tS.Stopped -and $tS.StoppedAt -eq (HcMs 1.5) -and $null -eq $tS.Open -and $tS.Prompt -eq 'push it' -and -not $tS2.Stopped -and $tS2.Prompt -eq 'no, push to the fork') (
    "$($tS.Stopped) $($tS.StoppedAt) $($tS.Open.Id) $($tS.Prompt) / $($tS2.Stopped) $($tS2.Prompt)")

$tN = Read-ChatOverlayCardTail (Write-HcChat 'noise' @(
        (HcPrompt 'the real one' 9)
        (HcText 'The real reply.' 8)
        (HcUser '"<task-notification>\n<task-id>b1</task-id>\n<status>completed</status>\n<summary>Background command done</summary>\n</task-notification>"' 7 ',"origin":{"kind":"task-notification"},"promptSource":"system","turnOrigin":"task_notification"')
        (HcUser '[{"type":"text","text":"Base directory for this skill: C:\\x"}]' 6 ',"isMeta":true')
        ('{"parentUuid":null,"isSidechain":true,"agentId":"a1","message":{"model":"claude-opus-5-5","id":"msg_side","type":"message","role":"assistant","content":[{"type":"text","text":"A side chat''s words."}],"stop_reason":"end_turn"},"type":"assistant","uuid":"' + [guid]::NewGuid() + '","timestamp":"' + (HcAt 5) + '"' + $hcEnd)
        (HcText 'You''ve hit your session limit' 4 -Synthetic)))
Check 'Claude Code''s own records are neither yours nor Claude''s: a background task''s news, a skill''s text, a side chat, a limit''s words' (
    $tN.Prompt -eq 'the real one' -and $tN.Reply -eq 'The real reply.' -and $tN.ReplyAt -eq (HcMs 8)) "$($tN.Prompt) / $($tN.Reply)"

$tC = Read-ChatOverlayCardTail (Write-HcChat 'slash' @(
        (HcPrompt 'older' 5)
        (HcText 'Done.' 4)
        (HcUser '"<command-message>review</command-message>\n<command-name>/review</command-name>\n<command-args>the card</command-args>"' 3)))
$hcKo = U '\ud55c\uae00 \ud504\ub86c\ud504\ud2b8'
$tK = Read-ChatOverlayCardTail (Write-HcChat 'hangul' @((HcPrompt $hcKo 2)))
Check 'a slash command typed is your prompt as you typed it; Hangul read as written' (
    $tC.Prompt -eq '/review the card' -and $tC.PromptAt -eq (HcMs 3) -and $tC.Reply -eq 'Done.' -and $tK.Prompt -eq $hcKo) "$($tC.Prompt) $($tC.PromptAt) / $($tC.Reply) / $($tK.Prompt.Length)"

# what VS Code sends ahead of a prompt - the file open in the editor - is
# not what you typed, and a picture is no words
$hcOpen = '{"type":"text","text":"<ide_opened_file>The user opened the file C:\\p\\hc\\a.ps1 in the IDE. This may or may not be related to the current task.</ide_opened_file>"}'
$hcHuman = ',"permissionMode":"auto","origin":{"kind":"human"},"promptSource":"sdk","turnOrigin":"human"'
$hcPic = '{"type":"image","source":{"type":"base64","media_type":"image/png","data":"iVBORw0KGgo' + ('A' * 70000) + '"}}'
$hcOldLines = @(
    (HcPrompt 'the old prompt' 9)
    (HcTool 'o1' 'Read' '{"file_path":"C:\\p\\hc\\old.ps1"}' 8)
    (HcResult 'o1' 7.9)
    (HcText 'The old reply.' 7.5))
$tI = Read-ChatOverlayCardTail (Write-HcChat 'ide' ($hcOldLines + @(
            (HcUser ('[' + $hcOpen + ',{"type":"text","text":"the NEW prompt"}]') 1 $hcHuman)
            (HcTool 'n1' 'Bash' $hcBash 0.5))))
$tG = Read-ChatOverlayCardTail (Write-HcChat 'picture' ($hcOldLines + @(
            (HcUser ('[' + $hcPic + ',{"type":"text","text":"what is wrong here"}]') 1 ($hcHuman + ',"imagePasteIds":[1]')))))
$tG0 = Read-ChatOverlayCardTail (Write-HcChat 'picture0' ($hcOldLines + @(
            (HcLast 'the old prompt')
            (HcUser ('[' + $hcPic + ']') 1 ($hcHuman + ',"imagePasteIds":[1]')))))
Check 'your prompt in your words: past the file VS Code says is open, past a picture''s hundreds of KB; a picture alone, no words - but its turn all the same' (
    $tI.Prompt -eq 'the NEW prompt' -and $tI.PromptAt -eq (HcMs 1) -and (@($tI.Steps | ForEach-Object { $_.Name }) -join ',') -eq 'Bash' -and
    $tG.Prompt -eq 'what is wrong here' -and $tG.PromptAt -eq (HcMs 1) -and $null -eq $tG0.Prompt -and $tG0.PromptAt -eq (HcMs 1) -and $tG0.Reply -eq 'The old reply.') (
    "$($tI.Prompt) $($tI.PromptAt) $(@($tI.Steps | ForEach-Object { $_.Name }) -join ',') / $($tG.Prompt) $($tG.PromptAt) / $($tG0.Prompt) $($tG0.PromptAt) $($tG0.Reply)")
# before Claude Code marked what you typed (2.1.263): a prompt with no mark
# starts its turn all the same
$tO = Read-ChatOverlayCardTail (Write-HcChat 'old' @(
        (HcUser '[{"type":"text","text":"the old prompt"}]' 9)
        (HcTool 'o1' 'Read' '{"file_path":"C:\\p\\hc\\old.ps1"}' 8)
        (HcResult 'o1' 7.9)
        (HcUser ('[' + $hcOpen + ',{"type":"text","text":"the NEW prompt"}]') 2)
        (HcTool 'o2' 'Bash' $hcBash 1)))
$tA = Read-ChatOverlayCardTail (Write-HcChat 'angle' @(
        (HcPrompt 'older' 5)
        (HcTool 'a1' 'Read' '{"file_path":"C:\\p\\hc\\a.ps1"}' 4)
        (HcResult 'a1' 3.9)
        (HcPrompt '<div> is misaligned, fix it' 2)))
$tA2 = Read-ChatOverlayCardTail (Write-HcChat 'angle2' @(
        (HcPrompt 'older' 5)
        (HcUser '"<b> tags gone"' 2 ',"origin":{"kind":"human"},"promptSource":"typed"')))
Check 'a prompt from before Claude Code marked them starts its turn; one you typed starting as its own do, with a tag, is yours - in a list, or as words alone (a terminal''s, 2.1.284)' (
    $tO.Prompt -eq 'the NEW prompt' -and $tO.PromptAt -eq (HcMs 2) -and (@($tO.Steps | ForEach-Object { $_.Id }) -join ',') -eq 'toolu_o2' -and
    $tA.Prompt -eq '<div> is misaligned, fix it' -and @($tA.Steps).Count -eq 0 -and $tA2.Prompt -eq '<b> tags gone' -and $tA2.PromptAt -eq (HcMs 2)) (
    "$($tO.Prompt) $($tO.PromptAt) $(@($tO.Steps | ForEach-Object { $_.Id }) -join ',') / $($tA.Prompt) $(@($tA.Steps).Count) / $($tA2.Prompt)")

$hcFar = Write-HcChat 'far' @(
    (HcPrompt 'a prompt long ago' 30)
    (HcTool 'f1' 'Read' '{"file_path":"C:\\p\\hc\\big.txt"}' 20)
    (HcUser ('[{"tool_use_id":"toolu_f1","type":"tool_result","content":"' + ('y' * 9000) + '"}]') 19.9)
    (HcLast 'a prompt long ago')
    (HcText 'Read it all.' 2))
$tF = Read-ChatOverlayCardTail $hcFar 4096
Check 'only the window''s end is read: a prompt before it is not found - Claude Code''s copy stands in' (
    $null -eq $tF.Prompt -and $tF.LastPrompt -eq 'a prompt long ago' -and $tF.Reply -eq 'Read it all.' -and @($tF.Steps).Count -eq 0 -and
    $tF.Length -eq ([System.IO.FileInfo]::new($hcFar)).Length) "$($tF.Prompt) / $($tF.LastPrompt) / $($tF.Reply) / $(@($tF.Steps).Count)"
# the window starting inside a reply's line, in the long id at its front:
# what is left of the line reads as Claude's words, and is not taken
$hcPad = (HcText 'a reply the window cut' 3) -replace '^\{"parentUuid":null', ('{"parentUuid":"' + ('x' * 8000) + '"')
$hcCutB = HcLast 'cut'
$tX = Read-ChatOverlayCardTail (Write-HcChat 'cut' @((HcPrompt 'cut' 4), $hcPad, $hcCutB)) ($hcCutB.Length + 2 + $hcPad.Length - $hcPad.IndexOf('","isSidechain"') + 100)
Check 'the line the window''s start cuts is passed over' ($null -eq $tX.Reply -and $tX.LastPrompt -eq 'cut' -and $null -eq $tX.Prompt) "$($tX.Reply) / $($tX.LastPrompt) / $($tX.Prompt)"
# a last line longer than the window - a file read whole: the window grows
$hcLong = Write-HcChat 'long' @(
    (HcPrompt 'read the big one' 5)
    (HcText 'Reading it.' 4)
    (HcTool 'l1' 'Read' '{"file_path":"C:\\p\\hc\\big.txt"}' 3)
    (HcUser ('[{"tool_use_id":"toolu_l1","type":"tool_result","content":"' + ('z' * 9000) + '"}]') 2.9))
$hcR2 = $script:ChatOverlayCardReads
$tL = Read-ChatOverlayCardTail $hcLong 4096
Check 'a last line longer than the window: four times the window, till a whole line is in it - one read all the same' (
    $tL.Prompt -eq 'read the big one' -and $tL.Reply -eq 'Reading it.' -and (@($tL.Steps | ForEach-Object { $_.Name }) -join ',') -eq 'Read' -and $null -eq $tL.Open -and
    $script:ChatOverlayCardReads -eq $hcR2 + 1) "$($tL.Prompt) / $($tL.Reply) / $(@($tL.Steps).Count) $($tL.Open.Id) / reads $($script:ChatOverlayCardReads - $hcR2)"
$tW = Read-ChatOverlayCardTail (Write-HcChat 'writing' @((HcPrompt 'go on' 3), (HcText 'The first part.' 2)) -Partial (HcText 'Still being written.' 1))
$hcR1 = $script:ChatOverlayCardReads
$tM = Read-ChatOverlayCardTail (Join-Path $hcDir 'none.jsonl')
Check 'a last line with no newline yet is still being written, and not read; no transcript at all, nothing and no error' (
    $tW.Reply -eq 'The first part.' -and $tM.Length -eq 0 -and @($tM.Steps).Count -eq 0 -and $null -eq $tM.Reply -and $script:ChatOverlayCardReads -eq $hcR1) "$($tW.Reply) / $($tM.Length)"

$hcTodo = '{"todos":[{"content":"Research","status":"completed","activeForm":"Researching"},{"content":"Write the card","status":"in_progress","activeForm":"Writing the card"},{"content":"Test it","status":"pending","activeForm":"Testing it"}]}'
$tT = Read-ChatOverlayCardTail (Write-HcChat 'todo' @(
        (HcPrompt 'plan it' 5)
        (HcTool 't1' 'TodoWrite' $hcTodo 4)
        (HcResult 't1' 3.9)
        (HcText 'Planned.' 3)))
$tT2 = Read-ChatOverlayCardTail (Write-HcChat 'todo2' @(
        (HcPrompt 'plan it' 5)
        (HcTool 't1' 'TodoWrite' ($hcTodo -replace '"(in_progress|pending)"', '"completed"') 4)
        (HcResult 't1' 3.9)))
Check 'the newest todo list: how many done, how many in all, and the one under way' (
    $tT.Todo.Done -eq 1 -and $tT.Todo.Count -eq 3 -and $tT.Todo.Active -eq 'Writing the card' -and $tT2.Todo.Done -eq 3 -and $null -eq $tT2.Todo.Active) (
    "$($tT.Todo.Done)/$($tT.Todo.Count) $($tT.Todo.Active) / $($tT2.Todo.Done)/$($tT2.Todo.Count)")

# what the card shows of all that, row by row
$hcRow = {
    param([string]$Status, [string]$Kind = 'session', [hashtable]$More = @{})
    $r = [ordered]@{ key = "s:$hcSid"; kind = $Kind; provider = 'claude'; status = $Status; project = 'hc'; title = 'Card title'; sessionId = $hcSid; cwd = $hcCwd
        where = 'vscode'; since = (HcMs 9); detail = $null
    }
    foreach ($k in $More.Keys) { $r[$k] = $More[$k] }
    [pscustomobject]$r
}
$mB = Get-ChatOverlayCardModel (& $hcRow 'busy') $tB $null $hcNowMs
Check 'at work: NOW, the call going and on what, its clock from when it began; the calls before it, an MCP tool by its own name; your prompt, then Claude''s words - and not whose chat, which its row says' (
    $mB.Label -eq 'NOW' -and $mB.Tone -eq 'busy' -and $mB.Tool -eq 'Bash' -and $mB.What -eq 'git status --short' -and $mB.From -eq (HcMs 0.5) -and
    (@($mB.Steps | ForEach-Object { "$($_.Tool)=$($_.What)" }) -join '|') -eq 'getDiagnostics=|Edit=src/overlay-data.ps1|Grep=Show-ChatOverlayChip' -and
    (@($mB.Turns | ForEach-Object { $_.Who }) -join ',') -eq 'YOU,CLAUDE' -and $mB.Turns[0].Text -eq 'make the card' -and $mB.Turns[1].Text -eq 'Reading the panel first.' -and
    $mB.Turns[0].At -eq (Format-ChatOverlayCardTime (HcMs 9) $hcNow) -and -not @($mB.PSObject.Properties.Name | Where-Object { $_ -in 'Project', 'Where', 'Title' }).Count) (
    "$($mB.Label) $($mB.Tool) $($mB.What) $($mB.From) / $(@($mB.Steps | ForEach-Object { "$($_.Tool)=$($_.What)" }) -join '|') / $(@($mB.Turns | ForEach-Object { "$($_.Who) $($_.At) $($_.Text)" }) -join ' | ')")
$mW = Get-ChatOverlayCardModel (& $hcRow 'waiting') $tB $null $hcNowMs
$mA = Get-ChatOverlayCardModel (& $hcRow 'waiting') (Read-ChatOverlayCardTail (Write-HcChat 'ask' @(
            (HcPrompt 'pick one' 3)
            (HcTool 'q1' 'AskUserQuestion' '{"questions":[{"question":"Which card should I build?","header":"Card","multiSelect":false,"options":[{"label":"A","description":"the first"},{"label":"B","description":"the second"}]}]}' 2)))) $null $hcNowMs
$mP = Get-ChatOverlayCardModel (& $hcRow 'waiting') (Read-ChatOverlayCardTail (Write-HcChat 'plan' @(
            (HcPrompt 'plan it' 3)
            (HcTool 'x1' 'ExitPlanMode' '{"plan":"\n# The hover card\n\nStep one","planFilePath":"C:\\x\\plan.md"}' 2)))) $null $hcNowMs
$mI = Get-ChatOverlayCardModel (& $hcRow 'needs-input' -More @{ detail = 'input needed' }) $tB $null $hcNowMs
$mI2 = Get-ChatOverlayCardModel (& $hcRow 'needs-input') $null $null $hcNowMs
Check 'waiting on you: WAITS in waiting''s colour - the call it asks to make, a question asked, a plan to approve; needing input, the row''s words, else needs you' (
    $mW.Label -eq 'WAITS' -and $mW.Tone -eq 'waiting' -and $mW.Tool -eq 'Allow Bash' -and $mW.What -eq 'git status --short' -and $mW.From -eq (HcMs 0.5) -and
    $mA.Tool -eq 'Asks' -and $mA.What -eq 'Which card should I build?' -and $mP.Tool -eq 'Plan to approve' -and $mP.What -eq '# The hover card' -and
    $mI.Label -eq 'WAITS' -and $mI.Tone -eq 'waiting' -and $null -eq $mI.Tool -and $mI.What -eq 'input needed' -and $mI2.What -eq 'needs you') (
    "$($mW.Tool) $($mW.What) / $($mA.Tool) $($mA.What) / $($mP.Tool) $($mP.What) / $($mI.What) / $($mI2.What)")
$mAs = Get-ChatOverlayCardModel (& $hcRow 'waiting') (Read-ChatOverlayCardTail (Write-HcChat 'ask-secret' @(
            (HcPrompt 'push it' 3)
            (HcTool 'q2' 'AskUserQuestion' '{"questions":[{"question":"Push to https://me:hunter2@example.com/r.git now?","header":"Push","multiSelect":false,"options":[{"label":"Yes","description":"push"}]}]}' 2)))) $null $hcNowMs
$mPs = Get-ChatOverlayCardModel (& $hcRow 'waiting') (Read-ChatOverlayCardTail (Write-HcChat 'plan-secret' @(
            (HcPrompt 'plan the push' 3)
            (HcTool 'x2' 'ExitPlanMode' '{"plan":"git push https://me:hunter2@example.com/r.git","planFilePath":"C:\\x\\plan.md"}' 2)))) $null $hcNowMs
Check 'a question asked and a plan to approve with what looks like a secret in them: hidden, as in a command' (
    $mAs.What -eq 'Push to https://***@example.com/r.git now?' -and $mPs.What -eq 'git push https://***@example.com/r.git') "$($mAs.What) / $($mPs.What)"
$mR = Get-ChatOverlayCardModel (& $hcRow 'running' -More @{ stateWords = 'running 2m' }) $tD $null $hcNowMs
$mK = Get-ChatOverlayCardModel (& $hcRow 'busy' -More @{ detail = 'thinking' }) $tD $null $hcNowMs
$mK2 = Get-ChatOverlayCardModel (& $hcRow 'busy') $tD $null $hcNowMs
Check 'a queued run at work says RUNNING; a chat at work on no call, the row''s words, else working - and no clock' (
    $mR.Label -eq 'RUNNING' -and $mR.What -eq 'running 2m' -and $mK.Label -eq 'NOW' -and $mK.What -eq 'thinking' -and $null -eq $mK.Tool -and $null -eq $mK.From -and
    $mK2.What -eq 'working') "$($mR.Label) $($mR.What) / $($mK.What) $($mK.Tool) $($mK.From) / $($mK2.What)"
$mF = Get-ChatOverlayCardModel (& $hcRow 'idle') $tD $null $hcNowMs
$mS = Get-ChatOverlayCardModel (& $hcRow 'idle') $tS $null $hcNowMs
$mRc = Get-ChatOverlayCardModel (& $hcRow 'recent' 'recent' @{ where = $null }) $tD $null $hcNowMs
$mF0 = Get-ChatOverlayCardModel (& $hcRow 'idle') $null $null $hcNowMs
Check 'done for now: FINISHED when Claude last spoke, STOPPED when you stopped it, a Recent chat in its own tone; with no transcript, when the row says' (
    $mF.Label -eq 'FINISHED' -and $mF.Tone -eq 'idle' -and $mF.At -and $mF.At -eq (Format-ChatOverlayCardTime (HcMs 4.5) $hcNow) -and
    $mS.Label -eq 'STOPPED' -and $mS.At -eq (Format-ChatOverlayCardTime (HcMs 1.5) $hcNow) -and $mRc.Tone -eq 'recent' -and $mRc.Label -eq 'FINISHED' -and
    $mF0.At -eq (Format-ChatOverlayCardTime (HcMs 9) $hcNow)) "$($mF.Label) $($mF.At) / $($mS.Label) $($mS.At) / $($mRc.Tone) / $($mF0.At)"
$mC = Get-ChatOverlayCardModel (& $hcRow 'cutoff' 'cutoff' @{ detail = 'cut off - session limit, resets 17:00' }) $tD $null $hcNowMs
$mQ = Get-ChatOverlayCardModel (& $hcRow 'queued' 'job' @{ stateWords = 'queued, sends at 17:00'; where = 'run' }) $null $null $hcNowMs
Check 'cut off by a limit, and a queued prompt: each in its own words, the cut off not said twice' (
    $mC.Label -eq 'CUT OFF' -and $mC.What -eq 'session limit, resets 17:00' -and $mQ.Label -eq 'QUEUED' -and $mQ.What -eq 'queued, sends at 17:00') (
    "$($mC.Label) $($mC.What) / $($mQ.Label) $($mQ.What)")
$mT = Get-ChatOverlayCardModel (& $hcRow 'idle') $tT $null $hcNowMs
$mT2 = Get-ChatOverlayCardModel (& $hcRow 'idle') $tT2 $null $hcNowMs
Check 'a todo list with items left: how far, and the one under way - its own call not among those before; all done, no line' (
    $mT.Tasks -eq "1 of 3 $($script:ChatqDot) Writing the card" -and @($mT.Steps).Count -eq 0 -and $null -eq $mT2.Tasks) "$($mT.Tasks) / $(@($mT.Steps).Count) / $($mT2.Tasks)"

# where a card reads from, and the prompts known for it
$hcHome = Join-Path $hcDir 'home'
$hcRecentDir = Join-Path (Join-Path $hcHome 'projects') (Get-ChatSlug $hcCwd)
$null = New-Item -ItemType Directory -Path $hcRecentDir -Force
Copy-Item -LiteralPath $hcDone -Destination (Join-Path $hcRecentDir "$hcSid.jsonl")
$null = New-Item -ItemType Directory -Path $script:ChatqQueueDir -Force
$hcPf = Join-Path $script:ChatqQueueDir 'hover-card-test.md'
[System.IO.File]::WriteAllText($hcPf, "the job's own prompt`nin two lines", $utf8)
$hcJob = { param($Id, $Provider) [pscustomobject]@{ Job = [pscustomobject]@{ id = $Id; provider = $Provider; path = $hcDone; promptFile = 'hover-card-test.md'; createdAt = $hcStart.AddMinutes(-20).UtcDateTime.ToString('o') } } }
$hcCtx = [pscustomobject]@{ Text = @{ $hcSid = @{ Path = $hcBusy; Prompt = 'the pass''s prompt'; TypedAt = (HcMs 30) } }; Jobs = @((& $hcJob 'hc1' 'claude'), (& $hcJob 'hc2' 'codex')); ClaudeHome = $hcHome }
$sO = Get-ChatOverlayCardSource $hcCtx (& $hcRow 'busy')
$sU = Get-ChatOverlayCardSource $hcCtx (& $hcRow 'busy' -More @{ sessionId = '7d7d7d7d-7d7d-4d7d-8d7d-7d7d7d7d7d7d' })
$sC = Get-ChatOverlayCardSource $hcCtx (& $hcRow 'cutoff' 'cutoff' @{ path = $hcDone })
$sG = Get-ChatOverlayCardSource $hcCtx (& $hcRow 'cutoff' 'cutoff' @{ path = (Join-Path $hcDir 'gone.jsonl') })
$sR = Get-ChatOverlayCardSource $hcCtx (& $hcRow 'recent' 'recent')
$sJ = Get-ChatOverlayCardSource $hcCtx (& $hcRow 'queued' 'job' @{ key = 'j:hc1' })
$sX = Get-ChatOverlayCardSource $hcCtx (& $hcRow 'queued' 'job' @{ key = 'j:hc2'; provider = 'codex' })
Remove-Item -LiteralPath $hcPf -Force -EA SilentlyContinue
Check 'an open chat''s card reads its transcript, with the prompt the pass found; a cut-off row its own; a Recent chat''s found by its id; one gone, none' (
    $sO.Path -eq $hcBusy -and $sO.Known.Text -eq 'the pass''s prompt' -and $sO.Known.At -eq (HcMs 30) -and $null -eq $sO.Prompt -and
    $null -eq $sU.Path -and $null -eq $sU.Known -and $sC.Path -eq $hcDone -and $null -eq $sG.Path -and $sR.Path -eq (Join-Path $hcRecentDir "$hcSid.jsonl")) (
    "$($sO.Path) $($sO.Known.Text) / $($sU.Path) / $($sC.Path) / $($sG.Path) / $($sR.Path)")
Check 'a queued prompt''s card: its chat''s transcript, and the prompt it sends - what a Codex one has, its rollout unread' (
    $sJ.Path -eq $hcDone -and $sJ.Prompt.Text -eq "the job's own prompt in two lines" -and [Math]::Abs([int64]$sJ.Prompt.At - (HcMs 20)) -le 1000 -and
    $null -eq $sX.Path -and $sX.Prompt.Text -eq $sJ.Prompt.Text) "$($sJ.Path) $($sJ.Prompt.Text) $($sJ.Prompt.At) / $($sX.Path) $($sX.Prompt.Text)"
$mJ = Get-ChatOverlayCardModel (& $hcRow 'running') $tB $sJ $hcNowMs
$mKn = Get-ChatOverlayCardModel (& $hcRow 'busy') $tB $sO $hcNowMs
$mKf = Get-ChatOverlayCardModel (& $hcRow 'busy') $tF $sO $hcNowMs
$mLp = Get-ChatOverlayCardModel (& $hcRow 'busy') $tF $null $hcNowMs
$mSl = Get-ChatOverlayCardModel (& $hcRow 'idle') $tC $null $hcNowMs
Check 'your prompt: a queued one''s own, else the newest in the transcript, else the one the pass found, else Claude Code''s copy - with no time' (
    $mJ.Turns[0].Text -eq $sJ.Prompt.Text -and $mKn.Turns[0].Text -eq 'make the card' -and $mKf.Turns[0].Text -eq 'the pass''s prompt' -and
    $mLp.Turns[0].Text -eq 'a prompt long ago' -and $mLp.Turns[0].At -eq '') "$($mJ.Turns[0].Text) / $($mKn.Turns[0].Text) / $($mKf.Turns[0].Text) / $($mLp.Turns[0].Text) $($mLp.Turns[0].At)"
Check 'a prompt sent after Claude''s last words comes after them' ((@($mSl.Turns | ForEach-Object { $_.Who }) -join ',') -eq 'CLAUDE,YOU') (@($mSl.Turns | ForEach-Object { $_.Who }) -join ',')
$mIde = Get-ChatOverlayCardModel (& $hcRow 'busy') $tI $sO $hcNowMs
$mPic = Get-ChatOverlayCardModel (& $hcRow 'idle') $tG0 $sO $hcNowMs
Check 'your prompt past what VS Code sent with it, over an older one the pass found; a picture alone: no prompt, never an older one in its place' (
    (@($mIde.Turns | ForEach-Object { $_.Who }) -join ',') -eq 'CLAUDE,YOU' -and $mIde.Turns[1].Text -eq 'the NEW prompt' -and $mIde.Turns[1].At -eq (Format-ChatOverlayCardTime (HcMs 1) $hcNow) -and
    (@($mPic.Turns | ForEach-Object { $_.Who }) -join ',') -eq 'CLAUDE') (
    "$(@($mIde.Turns | ForEach-Object { "$($_.Who) $($_.At) $($_.Text)" }) -join ' | ') // $(@($mPic.Turns | ForEach-Object { "$($_.Who) $($_.Text)" }) -join ' | ')")

# the pure parts: words, times, the side it goes on, the rows it is for
$hcE = $script:ChatqEllipsis
Check 'a file by its path from the chat''s folder, in forward slashes; one outside it whole' (
    (Format-ChatOverlayCardArg 'Read' 'C:\p\hc\src\a.ps1' $hcCwd) -eq 'src/a.ps1' -and (Format-ChatOverlayCardArg 'Edit' 'c:\P\HC\src\a.ps1' 'C:\p\hc\') -eq 'src/a.ps1' -and
    (Format-ChatOverlayCardArg 'Write' 'D:\x\y.txt' $hcCwd) -eq 'D:/x/y.txt' -and (Format-ChatOverlayCardArg 'Read' 'C:\p\hcx\a.ps1' $hcCwd) -eq 'C:/p/hcx/a.ps1')
$hcA1 = Format-ChatOverlayCardArg 'Read' 'C:\p\hc\src\some\deeply\nested\folder\file.ps1' $hcCwd
$hcA2 = Format-ChatOverlayCardArg 'Read' 'C:\p\hc\src\with-a-very-long-file-name-for-the-card.ps1' $hcCwd
$hcA3 = Format-ChatOverlayCardArg 'Read' 'with-a-very-long-file-name-for-the-card-alone.ps1' ''
Check 'a long path by its end: the folders nearest the file that fit 28 characters, else its name alone' (
    $hcA1 -eq "$hcE/nested/folder/file.ps1" -and $hcA2 -eq "$hcE/with-a-very-long-file-name-for-the-card.ps1" -and $hcA3 -eq 'with-a-very-long-file-name-for-the-card-alone.ps1') "$hcA1 / $hcA2 / $hcA3"
$hcA4 = Format-ChatOverlayCardArg 'Bash' 'git push https://me:hunter2@example.com/r.git' $hcCwd
Check 'anything else as it came, but for what looks like a secret' ($hcA4 -eq 'git push https://***@example.com/r.git' -and (Format-ChatOverlayCardArg 'Grep' 'C:\p\hc\x' $hcCwd) -eq 'C:\p\hc\x') $hcA4
Check 'what a call works on: its first telling key, a question before the words under it; a workflow by its name; else its first string' (
    (Get-ChatOverlayToolArg 'AskUserQuestion' '{"questions":[{"question":"Which one?","header":"H","options":[{"label":"A","description":"first"}]}]}') -eq 'Which one?' -and
    (Get-ChatOverlayToolArg 'Workflow' '{"script":"export const meta = { name: ''review-card'', phases: [] }"}') -eq 'review-card' -and
    (Get-ChatOverlayToolArg 'Workflow' '{"script":"x","description":"Review the card"}') -eq 'Review the card' -and
    (Get-ChatOverlayToolArg 'Mystery' '{"zzz":"first string","n":1}') -eq 'first string' -and (Get-ChatOverlayToolArg 'ListAgents' '{}') -eq '' -and
    (Get-ChatOverlayToolArg 'Bash' '{"command":"echo \"hi\"   there\nsecond line"}') -eq 'echo "hi" there')
Check 'a JSON string''s first line, unescaped: an escape a cut split dropped, an escaped backslash kept, 600 characters at most' (
    (Get-ChatOverlayJsonText 'abc\') -eq 'abc' -and (Get-ChatOverlayJsonText 'abc\u12') -eq 'abc' -and (Get-ChatOverlayJsonText 'a\\') -eq 'a\' -and
    (Get-ChatOverlayJsonText ('x' * 700)).Length -eq 600 -and (Get-ChatOverlayJsonText '\n\n  two  words ') -eq 'two words')
$hcAt = { param([string]$Local) [DateTimeOffset]::new([datetime]::ParseExact($Local, 'yyyy-MM-dd HH:mm', [cultureinfo]::InvariantCulture)).ToUnixTimeMilliseconds() }
$hcThu = [datetime]::ParseExact('2026-10-15 14:00', 'yyyy-MM-dd HH:mm', [cultureinfo]::InvariantCulture)
Check 'a card''s times: 13:05 today, Tue 13:05 within the week, Oct 3 before; none, nothing' (
    (Format-ChatOverlayCardTime (& $hcAt '2026-10-15 13:05') $hcThu) -eq '13:05' -and (Format-ChatOverlayCardTime (& $hcAt '2026-10-13 13:05') $hcThu) -eq 'Tue 13:05' -and
    (Format-ChatOverlayCardTime (& $hcAt '2026-10-03 13:05') $hcThu) -eq 'Oct 3' -and (Format-ChatOverlayCardTime $null $hcThu) -eq '')
$hcScr = [pscustomobject]@{ X = 0; Y = 0; Width = 1920; Height = 1040 }
$pl1 = Get-ChatOverlayCardPlacement @(1500, 200, 380, 300) @(1510, 260, 360, 40) @(330, 280) $hcScr 8
$pl2 = Get-ChatOverlayCardPlacement @(20, 200, 380, 300) @(30, 260, 360, 40) @(330, 280) $hcScr 8
$pl3 = Get-ChatOverlayCardPlacement @(770, 200, 380, 900) @(780, 900, 360, 40) @(330, 280) $hcScr 8
$pl4 = Get-ChatOverlayCardPlacement @(15, 0, 1900, 300) @(20, 10, 360, 40) @(330, 280) $hcScr 8
$pl5 = Get-ChatOverlayCardPlacement @(-1500, 200, 380, 300) @(-1490, -50, 360, 40) @(330, 280) ([pscustomobject]@{ X = -1920; Y = 0; Width = 1920; Height = 1040 }) 8
Check 'the card beside the panel on the side with more room - the left on a tie - level with its row, and kept on the screen: over the panel sooner than off it' (
    $pl1.X -eq 1162 -and $pl1.Y -eq 260 -and $pl1.Left -and $pl2.X -eq 408 -and $pl2.Y -eq 260 -and -not $pl2.Left -and $pl3.X -eq 432 -and $pl3.Y -eq 760 -and $pl3.Left -and
    $pl4.X -eq 0 -and $pl4.Y -eq 10 -and $pl5.X -eq -1112 -and $pl5.Y -eq 0 -and -not $pl5.Left) (
    (@($pl1, $pl2, $pl3, $pl4, $pl5) | ForEach-Object { "$($_.X),$($_.Y),$($_.Left)" }) -join ' ')
Check 'a card for a chat - open, cut off, Recent - and a queued prompt; none for a banner' (
    (Test-ChatOverlayCardRow ([pscustomobject]@{ kind = 'session' })) -and (Test-ChatOverlayCardRow ([pscustomobject]@{ kind = 'cutoff' })) -and
    (Test-ChatOverlayCardRow ([pscustomobject]@{ kind = 'recent' })) -and (Test-ChatOverlayCardRow ([pscustomobject]@{ kind = 'job' })) -and
    -not (Test-ChatOverlayCardRow ([pscustomobject]@{ kind = 'ask' })) -and -not (Test-ChatOverlayCardRow ([pscustomobject]@{ kind = 'reload' })) -and
    -not (Test-ChatOverlayCardRow ([pscustomobject]@{ key = 'x' })) -and -not (Test-ChatOverlayCardRow $null))

# the card itself, built and shown off every screen, in the STA process WPF
# needs: its own transcript, which the test adds to
$hcLive = Write-HcChat 'live' $hcBusyLines
$hcMore = Join-Path $hcDir 'more.txt'
[System.IO.File]::WriteAllText($hcMore, ((HcResult 'b1' 0.2) + "`n" + (HcText 'Clean tree.' 0.1) + "`n"), $utf8)
# the queued prompt's own file, which its card shows
$hcPf2 = Join-Path $script:ChatqQueueDir 'hover-card-sta.md'
[System.IO.File]::WriteAllText($hcPf2, "do the thing`nin full", $utf8)
$cardWpf = @"
$staLoad
`$script:ChatOverlayMouseDownSeam = { `$false }
Initialize-ChatOverlayNative
$staPanel
`$H.Ctx.Text = @{ '$hcSid' = @{ Path = '$hcLive'; Prompt = 'an older prompt'; TypedAt = [int64]$(HcMs 30) } }
`$H.Ctx.Jobs = @([pscustomobject]@{ Job = [pscustomobject]@{ id = 'hc9'; provider = 'codex'; path = `$null; promptFile = 'hover-card-sta.md'; createdAt = '$($hcStart.AddMinutes(-20).UtcDateTime.ToString('o'))' } })
`$sess = [pscustomobject]@{ key = 's:$hcSid'; kind = 'session'; provider = 'claude'; status = 'busy'; rank = 1; project = 'hc'; title = 'Card title'; prompt = `$null; stateText = 'busy'; job = `$null; sessionId = '$hcSid'; cwd = '$hcCwd'; where = 'vscode'; since = [int64]$(HcMs 9); detail = `$null }
`$job = [pscustomobject]@{ key = 'j:hc9'; kind = 'job'; provider = 'codex'; status = 'queued'; rank = 4; project = 'hc'; title = 'A queued prompt'; prompt = 'do the thing'; stateText = 'queued'; stateWords = 'queued, sends at 17:00'; job = `$null; sessionId = ''; cwd = '$hcCwd'; where = ''; detail = `$null }
`$none = [pscustomobject]@{ usage = @(); notes = @() }
`$H.Ctx.ViewSig = 'a'
Update-ChatOverlayView `$H ([pscustomobject]@{ header = `$none; rows = @(`$sess, `$job) })
`$H.Placed = `$true
`$script:ChatOverlayWorkAreaSeam = { param(`$r) [pscustomobject]@{ X = -4000; Y = 0; Width = 1920; Height = 1020 } }
Set-ChatOverlayHidden `$H `$false
[ChatOverlayNative]::MoveTo(`$H.Hwnd, -2594, 197)
`$H.Win.UpdateLayout()
`$rects = @(Get-ChatOverlayRowRects `$H)
# every line of words the card's face draws, in order
`$words = {
    `$out = [System.Collections.Generic.List[string]]::new()
    `$walk = {
        param(`$e)
        # a line made of runs has no Text of its own
        if (`$e -is [System.Windows.Controls.TextBlock]) { `$out.Add((-join @(foreach (`$i in `$e.Inlines) { if (`$i -is [System.Windows.Documents.Run]) { `$i.Text } }))) }
        elseif (`$e -is [System.Windows.Controls.Border]) { if (`$e.Child) { & `$walk `$e.Child } }
        elseif (`$e -is [System.Windows.Controls.Panel]) { foreach (`$c in `$e.Children) { & `$walk `$c } }
    }
    if (`$H.CardWin.Content) { & `$walk `$H.CardWin.Content }
    `$out -join '/'
}
# words as ASCII, to say what a failing check saw
`$esc = { param(`$s) [regex]::Replace([string]`$s, '[^\x20-\x7E]', { param(`$m) '\u{0:x4}' -f [int][char]`$m.Value }) }
# the pointer comes to rest on the queued prompt's row, which has nothing for
# the chip: no card before the rest, then the card and no chip, beside the
# panel and level with the row
`$r1 = `$rects[1].Rect
`$on = [System.Drawing.Point]::new(`$r1[0] + 20, `$r1[1] + 5)
`$t0 = Get-Date
Update-ChatOverlayChip `$H `$on `$false `$t0 `$true
Update-ChatOverlayChip `$H `$on `$false `$t0.AddMilliseconds(300) `$true
`$early = -not `$H.CardWin.IsVisible
Update-ChatOverlayChip `$H `$on `$false `$t0.AddMilliseconds(450) `$true
`$cardOnly = `$H.CardWin.IsVisible -and -not `$H.ChipWin.IsVisible -and `$H.CardKey -eq 'j:hc9' -and `$H.CardWin.Title -eq 'Charlie card'
`$cx = [ChatOverlayNative]::GetExStyle(`$H.CardHwnd)
`$cr = [ChatOverlayNative]::GetRect(`$H.CardHwnd)
`$pr = [ChatOverlayNative]::GetRect(`$H.Hwnd)
`$gap = [int][Math]::Round(`$script:ChatOverlayCardGap * (Get-ChatOverlayScale `$H `$pr -Device))
`$beside = [Math]::Abs(`$pr[0] - (`$cr[0] + `$cr[2]) - `$gap) -le 1 -and `$cr[1] -eq `$r1[1]
# the tail: out of the side that faces the panel, its tip within the row
`$tipIn = { param(`$r) `$ty = `$cr[1] + `$H.CardShape.TipY * (Get-ChatOverlayScale `$H `$pr -Device); `$ty -ge `$r[1] -and `$ty -le `$r[1] + `$r[3] }
`$tailAt = { `$b = `$H.CardShape.Path.Data.Bounds; '{0} {1} {2} {3}' -f `$H.CardShape.Left, `$H.CardShape.TipY, `$b.Left, `$b.Right }
`$tailL = `$H.CardShape.Left -and [Math]::Abs(`$H.CardShape.Path.Data.Bounds.Right - (`$script:ChatOverlayCardWidth + `$script:ChatOverlayCardTail - 0.5)) -lt 0.01 -and
    `$H.CardShape.Body.HorizontalAlignment -eq 'Left' -and (& `$tipIn `$r1)
`$tailSeen = & `$tailAt
`$jobW = & `$words
`$jobSays = `$jobW -like 'QUEUED/queued, sends at 17:00/YOU * */do the thing in full'
# the pointer leaves: the card kept 300 ms, then gone
`$off = [System.Drawing.Point]::new(-9000, -9000)
Update-ChatOverlayChip `$H `$on `$false `$t0.AddMilliseconds(600) `$true
Update-ChatOverlayChip `$H `$off `$false `$t0.AddMilliseconds(700) `$false
`$kept = `$H.CardWin.IsVisible
Update-ChatOverlayChip `$H `$off `$false `$t0.AddMilliseconds(1000) `$false
`$gone = -not `$H.CardWin.IsVisible -and -not `$H.CardKey
# the open chat's row: the chip and the card both, the card from the transcript
Show-ChatOverlayChip `$H `$rects[0] `$off
`$both = `$H.ChipWin.IsVisible -and `$H.CardWin.IsVisible -and `$H.CardKey -eq 's:$hcSid'
`$sessW = & `$words
`$says = `$sessW -like 'NOW/*:*/*Bash  git status --short/EARLIER/getDiagnostics/Edit  src/overlay-data.ps1/Grep  Show-ChatOverlayChip/YOU * */make the card/CLAUDE * */Reading the panel first.'
`$clock = `$H.CardClock -and `$H.CardClock.Text.Text -match '^\d+:\d\d$'
# the panel's opacity: the card's as it comes up - set by either slider -
# and as the box's slider moves
`$opWas = `$H.Win.Opacity
`$H.Win.Opacity = 0.6
Hide-ChatOverlayCard `$H
Show-ChatOverlayChip `$H `$rects[0] `$off
`$opShown = `$H.CardWin.Opacity
Set-ChatOverlayOpacity `$H 0.8
`$opacity = `$H.CardWin.IsVisible -and `$opShown -eq 0.6 -and `$H.CardWin.Opacity -eq 0.8
Set-ChatOverlayOpacity `$H `$opWas
`$H.PendingOpacity = `$null
# drawn: a face of many colours, text on its ground
`$H.CardWin.UpdateLayout()
`$el = `$H.CardWin.Content
`$rt = [System.Windows.Media.Imaging.RenderTargetBitmap]::new([int][Math]::Ceiling(`$el.ActualWidth), [int][Math]::Ceiling(`$el.ActualHeight), 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
`$rt.Render(`$el)
`$px = [byte[]]::new(`$rt.PixelWidth * `$rt.PixelHeight * 4)
`$rt.CopyPixels(`$px, `$rt.PixelWidth * 4, 0)
`$colors = [System.Collections.Generic.HashSet[int]]::new()
for (`$i = 0; `$i -lt `$px.Length; `$i += 12) { [void]`$colors.Add([BitConverter]::ToInt32(`$px, `$i)) }
`$drawn = `$rt.PixelWidth -ge 300 -and `$rt.PixelHeight -ge 150 -and `$colors.Count -ge 20
# the clock counts from when the call began, not from when the row says the
# chat went to work; every tick puts it right, a pass or not
`$ck = `$H.CardClock.Text.Text
`$cs = if (`$ck -match '^(\d+):(\d\d)$') { [int]`$Matches[1] * 60 + [int]`$Matches[2] } else { -1 }
`$H.CardClock.Text.Text = 'x'
`$script:ChatOverlayFullScreenSeam = { `$false }
`$H.Timer = [System.Windows.Threading.DispatcherTimer]::new()
`$H.Tick = 0
Invoke-ChatOverlayTick
`$ticked = `$cs -ge 25 -and `$cs -lt 300 -and `$H.CardClock.Text.Text -match '^\d+:\d\d$'
# read again on a pass, and only once the transcript grew: the call's result
# and Claude's words after it - nothing going now, so no clock. The pass
# finds the rows as they were.
`$script:HcSnap = [pscustomobject]@{ header = `$none; rows = @(`$sess, `$job) }
`$cyFn = `${function:Invoke-ChatOverlayCycle}
`${function:Invoke-ChatOverlayCycle} = { param(`$Ctx) `$script:HcSnap }
`$n1 = `$script:ChatOverlayCardReads
`$H.Tick = 1
Invoke-ChatOverlayTick
`$n2 = `$script:ChatOverlayCardReads
[System.IO.File]::AppendAllText('$hcLive', [System.IO.File]::ReadAllText('$hcMore'))
`$H.Tick = 1
Invoke-ChatOverlayTick
`$n3 = `$script:ChatOverlayCardReads
`${function:Invoke-ChatOverlayCycle} = `$cyFn
`$reW = & `$words
`$reread = `$H.CardWin.IsVisible -and `$n2 -eq `$n1 -and `$n3 -eq `$n1 + 1 -and `$reW -like 'NOW/working/EARLIER/Bash  git status --short/*/CLAUDE * */Clean tree.' -and -not `$H.CardClock
# none while the settings box is open; a redraw without its row, or the
# panel hidden, takes it away
Set-ChatOverlaySettingsOpen `$H `$true
`$setHid = -not `$H.CardWin.IsVisible -and -not `$H.CardKey
Show-ChatOverlayChip `$H `$rects[0] `$off
`$setNone = -not `$H.CardWin.IsVisible
Set-ChatOverlaySettingsOpen `$H `$false
Show-ChatOverlayChip `$H `$rects[0] `$off
`$back = `$H.CardWin.IsVisible
`$H.Ctx.ViewSig = 'b'
Update-ChatOverlayView `$H ([pscustomobject]@{ header = `$none; rows = @(`$job) })
`$redrawn = -not `$H.CardWin.IsVisible -and -not `$H.CardKey
`$H.Ctx.ViewSig = 'c'
Update-ChatOverlayView `$H ([pscustomobject]@{ header = `$none; rows = @(`$sess, `$job) })
`$H.Win.UpdateLayout()
`$rects = @(Get-ChatOverlayRowRects `$H)
Show-ChatOverlayChip `$H `$rects[0] `$off
Set-ChatOverlayHidden `$H `$true
`$hid = -not `$H.CardWin.IsVisible -and -not `$H.CardKey
Set-ChatOverlayHidden `$H `$false
# no room on the left: on the right; a row near the screen's foot: the card
# held up off it
[ChatOverlayNative]::MoveTo(`$H.Hwnd, -3990, 197)
`$H.Win.UpdateLayout()
`$rects = @(Get-ChatOverlayRowRects `$H)
Show-ChatOverlayChip `$H `$rects[0] `$off
`$cr = [ChatOverlayNative]::GetRect(`$H.CardHwnd)
`$pr = [ChatOverlayNative]::GetRect(`$H.Hwnd)
`$right = `$cr[0] -ge `$pr[0] + `$pr[2]
`$tailR = -not `$H.CardShape.Left -and [Math]::Abs(`$H.CardShape.Path.Data.Bounds.Left - 0.5) -lt 0.01 -and
    `$H.CardShape.Body.HorizontalAlignment -eq 'Right' -and (& `$tipIn `$rects[0].Rect)
`$tailSeen += ' / ' + (& `$tailAt)
[ChatOverlayNative]::MoveTo(`$H.Hwnd, -2594, 930)
`$H.Win.UpdateLayout()
`$rects = @(Get-ChatOverlayRowRects `$H)
Show-ChatOverlayChip `$H `$rects[0] `$off
`$cr = [ChatOverlayNative]::GetRect(`$H.CardHwnd)
`$pr = [ChatOverlayNative]::GetRect(`$H.Hwnd)
`$foot = `$cr[1] + `$cr[3] -le 1020 -and `$cr[1] -lt `$rects[0].Rect[1]
`$tailF = (& `$tipIn `$rects[0].Rect)
`$tailSeen += ' / ' + (& `$tailAt)
`$tail = `$tailL -and `$tailR -and `$tailF
# the banner's row: its chip, and no card - a card is for a chat
[ChatOverlayNative]::MoveTo(`$H.Hwnd, -2594, 197)
`$ask = [pscustomobject]@{ count = 3; resetsAt = [int64]$(HcMs 20); keys = @('hc_1', 'hc_2', 'hc_3'); titles = @('T one', 'T two', 'T three'); left = @() }
`$H.Ctx.ViewSig = 'd'
Update-ChatOverlayView `$H ([pscustomobject]@{ header = [pscustomobject]@{ usage = @(); notes = @(); ask = `$ask }; rows = @(`$sess, `$job) })
`$H.Win.UpdateLayout()
`$ae = @(Get-ChatOverlayRowRects `$H | Where-Object { `$_.Key -eq 'ask' })[0]
Show-ChatOverlayChip `$H `$ae `$off
`$askNone = `$ae -and `$H.ChipWin.IsVisible -and -not `$H.CardWin.IsVisible -and -not `$H.CardKey
# none folded to the one line, mid-drag, out of a full screen's way, or in
# the console's mode
`$sessE = { @(Get-ChatOverlayRowRects `$H | Where-Object { `$_.Key -eq 's:$hcSid' })[0] }
Show-ChatOverlayChip `$H (& `$sessE) `$off
`$was = `$H.CardWin.IsVisible
Set-ChatOverlayCollapsed `$H `$true
`$fold = `$was -and -not `$H.CardWin.IsVisible -and -not `$H.CardKey
Set-ChatOverlayCollapsed `$H `$false
`$H.Win.UpdateLayout()
`$se = & `$sessE
Show-ChatOverlayChip `$H `$se `$off
`$was = `$H.CardWin.IsVisible
`$H.Dragging = `$true
Update-ChatOverlayChip `$H ([System.Drawing.Point]::new(`$se.Rect[0] + 20, `$se.Rect[1] + 5)) `$false (Get-Date) `$true
`$drag = `$was -and -not `$H.CardWin.IsVisible -and -not `$H.CardKey
`$H.Dragging = `$false
Show-ChatOverlayChip `$H (& `$sessE) `$off
`$was = `$H.CardWin.IsVisible
`$script:ChatOverlayFullScreenSeam = { `$true }
Update-ChatOverlayFullScreen `$H
`$full = `$was -and `$H.FullHidden -and -not `$H.CardWin.IsVisible -and -not `$H.CardKey
`$script:ChatOverlayFullScreenSeam = { `$false }
Update-ChatOverlayFullScreen `$H
Show-ChatOverlayChip `$H (& `$sessE) `$off
`$was = `$H.CardWin.IsVisible
Remove-Item -LiteralPath `$script:ChatConsoleStatePath -Force -EA SilentlyContinue
Enter-ChatOverlayConsoleMode `$H
`$con = `$was -and `$H.Mode -eq 'console' -and -not `$H.CardWin.IsVisible -and -not `$H.CardKey
Exit-ChatOverlayConsoleMode `$H
# the light look: the card on the panel's light ground
`$H.Ctx.Config.theme = 'dark'
Update-ChatOverlayTheme `$H
`$H.Ctx.Config.theme = 'light'
Update-ChatOverlayTheme `$H
`$H.Win.UpdateLayout()
Show-ChatOverlayChip `$H (& `$sessE) `$off
`$H.CardWin.UpdateLayout()
`$el = `$H.CardWin.Content
`$rt = [System.Windows.Media.Imaging.RenderTargetBitmap]::new([int][Math]::Ceiling(`$el.ActualWidth), [int][Math]::Ceiling(`$el.ActualHeight), 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
`$rt.Render(`$el)
`$p4 = [byte[]]::new(4)
`$rt.CopyPixels([System.Windows.Int32Rect]::new(6, [int](`$rt.PixelHeight / 2), 1, 1), `$p4, 4, 0)
`$fc = (Get-ChatOverlayBrush 'frame').Color
`$pm = { param(`$v) [int][Math]::Round(`$v * `$fc.A / 255) }
`$light = `$H.CardWin.IsVisible -and `$fc.R -gt 200 -and [Math]::Abs(`$p4[0] - (& `$pm `$fc.B)) -le 2 -and [Math]::Abs(`$p4[1] - (& `$pm `$fc.G)) -le 2 -and
    [Math]::Abs(`$p4[2] - (& `$pm `$fc.R)) -le 2 -and [Math]::Abs(`$p4[3] - `$fc.A) -le 2
'{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}|{10}|{11}|{12}|{13}|{14}|{15}|{16}|{17}|{18}|{19}|{20}|{21}|{22}|{23}|{24}|{25}|{26}|{27}' -f `$early, `$cardOnly, `$cx, `$beside, `$jobSays, `$kept, `$gone, `$both, `$says, `$clock, `$drawn, `$reread, `$setHid, `$setNone, `$back, `$redrawn, `$hid, `$right,
    `$ticked, `$askNone, `$fold, `$drag, `$full, `$con, `$light, `$opacity, `$tail, "`$foot tail `$tailL/`$tailR/`$tailF `$tailSeen opacity `$opShown card `$(`$cr -join ',') rows `$(`$rects.Count) colors `$(`$colors.Count) reads `$n1/`$n2/`$n3 clock `$ck px `$(`$p4 -join ',') frame `$(`$fc) words `$(& `$esc `$jobW) // `$(& `$esc `$sessW) // `$(& `$esc `$reW)"
"@
$cardOut = Invoke-Sta 'card-test' $cardWpf
Remove-Item -LiteralPath $hcPf2 -Force -EA SilentlyContinue
$cw = "$cardOut" -split '\|'
$cwx = if ($cw.Count -ge 3 -and $cw[2] -match '^\d+$') { [int64]$cw[2] } else { 0 }
Check 'the card: never clicked - the mouse goes through it - never takes focus, in neither Alt+Tab nor the taskbar; its title says what it is' (
    (($cwx -band 0x80800A0) -eq 0x80800A0) -and -not ($cwx -band 0x40000) -and $cw[1] -eq 'True') ('0x{0:X} {1}' -f $cwx, "$cardOut")
Check 'after a rest on a row, not before: a queued prompt''s card, though the chip has nothing there - beside the panel, level with the row, in the row''s words' (
    $cw[0] -eq 'True' -and $cw[1] -eq 'True' -and $cw[3] -eq 'True' -and $cw[4] -eq 'True') "$cardOut"
Check 'the pointer gone: the card kept a moment, then gone' ($cw[5] -eq 'True' -and $cw[6] -eq 'True') "$cardOut"
Check 'an open chat''s card with its chip: what it does on what and for how long, the calls before, your prompt and Claude''s words - drawn' (
    $cw[7] -eq 'True' -and $cw[8] -eq 'True' -and $cw[9] -eq 'True' -and $cw[10] -eq 'True') "$cardOut"
Check 'a call''s clock counts from when it began, put right every tick; its transcript read again on a pass only once it grew, and the card says what is new' (
    $cw[18] -eq 'True' -and $cw[11] -eq 'True') "$cardOut"
Check 'no card while the settings box is open; a redraw without its row, or the panel hidden, takes it away' (
    $cw[12] -eq 'True' -and $cw[13] -eq 'True' -and $cw[14] -eq 'True' -and $cw[15] -eq 'True' -and $cw[16] -eq 'True') "$cardOut"
Check 'no room on the panel''s left: the card on its right; a row near the screen''s foot: the card held on the screen' (
    $cw[17] -eq 'True' -and $cw.Count -ge 28 -and $cw[27] -like 'True *') "$cardOut"
Check 'a banner''s row: its chip, never a card; none folded to the one line, mid-drag, out of a full screen''s way, or in the console' (
    $cw[19] -eq 'True' -and $cw[20] -eq 'True' -and $cw[21] -eq 'True' -and $cw[22] -eq 'True' -and $cw[23] -eq 'True') "$cardOut"
Check 'in the light look, the card on the panel''s light ground' ($cw[24] -eq 'True') "$cardOut"
Check 'the card at the panel''s opacity: as it comes up, whichever slider set it, and as the slider moves' ($cw[25] -eq 'True') "$cardOut"
Check 'a speech bubble from its chat: the tail out of the side facing the panel, either side, its tip in the row - one held up off the screen''s foot too' ($cw[26] -eq 'True') "$cardOut"
