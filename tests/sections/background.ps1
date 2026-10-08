# tests/sections/background.ps1: dot-sourced by tests/run-tests.ps1 in its turn,
# never on its own - it uses what the runner and the sections before it set.

Section 'background work: what an idle chat still has at work'
# A chat of its own, so nothing the sections above wrote gets in the way.
$projBg = Join-Path $work 'projBg'
$null = New-Item -ItemType Directory -Path $projBg -Force
# an id no other section uses: the phone board's look a chat up by theirs
$idBg = 'bebebebe-bebe-4ebe-8ebe-bebebebebebe'
$pBg = New-FakeChat $projBg $idBg 'Background host chat' 1 @('send it off')
$dirBg = Get-ChatSessionDir $pBg
function ConvertTo-BgLine($Record, [double]$MinutesAgo, [string]$Entrypoint = 'claude-vscode') {
    # one record as Claude Code writes it (Node leaves < > & ' alone)
    $Record['timestamp'] = (Get-Date).ToUniversalTime().AddMinutes(-$MinutesAgo).ToString('o')
    $Record['sessionId'] = $idBg
    $Record['entrypoint'] = $Entrypoint
    $u = [string][char]92 + 'u00'
    return ($Record | ConvertTo-Json -Compress -Depth 8).Replace("${u}3c", '<').Replace("${u}3e", '>').Replace("${u}26", '&').Replace("${u}27", "'")
}
function New-BgResult($Result, [double]$MinutesAgo, [string]$Entrypoint = 'claude-vscode') {
    ConvertTo-BgLine ([ordered]@{ type = 'user'; message = [ordered]@{ role = 'user'
                content = @([ordered]@{ tool_use_id = 'toolu_bg'; type = 'tool_result'; content = 'launched' }) }
            toolUseResult = $Result }) $MinutesAgo $Entrypoint
}
function New-BgNote([string]$Id, [double]$MinutesAgo, [string]$Status = 'completed') {
    ConvertTo-BgLine ([ordered]@{ type = 'user'; message = [ordered]@{ role = 'user'
                content = "<task-notification>`n<task-id>$Id</task-id>`n<status>$Status</status>`n<summary>over</summary>`n</task-notification>" } }) $MinutesAgo
}
function Add-BgLine([string]$Line) { [System.IO.File]::AppendAllText($pBg, $Line + "`n", $utf8) }
$bgWf = [ordered]@{ status = 'async_launched'; taskId = 'wbg0001'; taskType = 'local_workflow'; workflowName = 'review'; runId = 'wf_bg-0001' }
$bgAgent = [ordered]@{ isAsync = $true; status = 'async_launched'; agentId = 'abg0001'; description = 'map it' }
$bgShell = [ordered]@{ stdout = ''; stderr = ''; interrupted = $false; isImage = $false; noOutputExpected = $false; backgroundTaskId = 'bbg0001' }
$bgStop = [ordered]@{ message = 'Successfully stopped task: bbg0001 (npm test)'; task_id = 'bbg0001'; task_type = 'local_bash'; command = 'npm test' }
$bgIds = { param($Open, [switch]$Shells, [string]$Dir, [datetime]$Since = [datetime]::MinValue, [switch]$SkipPrint)
    (@(Select-ChatBackgroundOpen $Open $Since -Shells:$Shells -SessionDir $Dir -SkipPrint:$SkipPrint | ForEach-Object { $_.Id }) | Sort-Object) -join ',' }

# the reading, line by line
$o1 = [ordered]@{}
Step-ChatBackgroundLine $o1 (New-BgResult $bgWf 30)
Step-ChatBackgroundLine $o1 (New-BgResult $bgAgent 20)
Step-ChatBackgroundLine $o1 (New-BgResult $bgShell 10)
Check 'a workflow, an agent and a background shell each start something out' ($o1.Count -eq 3 -and $o1['wbg0001'].Kind -eq 'workflow' -and $o1['wbg0001'].Run -eq 'wf_bg-0001' -and
    $o1['abg0001'].Kind -eq 'agent' -and $o1['bbg0001'].Kind -eq 'shell') (($o1.Values | ForEach-Object { "$($_.Id)=$($_.Kind)" }) -join ' ')
Check 'each start says what it is where it can: an agent''s description, a workflow''s name; a shell''s command is not in its result' (
    $o1['abg0001'].Note -eq 'map it' -and $o1['wbg0001'].Note -eq 'review' -and $null -eq $o1['bbg0001'].Note) "$($o1['abg0001'].Note) $($o1['wbg0001'].Note) $($o1['bbg0001'].Note)"
Check 'a shell counts only where it is asked for - the reload checks leave it out' ((& $bgIds $o1) -eq 'abg0001,wbg0001' -and (& $bgIds $o1 -Shells) -eq 'abg0001,bbg0001,wbg0001') "$(& $bgIds $o1) | $(& $bgIds $o1 -Shells)"
Step-ChatBackgroundLine $o1 (New-BgResult $bgStop 5)
Check 'TaskStop''s result ends a task, with no notification' (-not $o1.Contains('bbg0001') -and $o1.Count -eq 2)
Step-ChatBackgroundLine $o1 (New-BgNote 'abg0001' 4)
Check 'a task-notification naming it ends one' (-not $o1.Contains('abg0001') -and $o1.Contains('wbg0001'))
Step-ChatBackgroundLine $o1 (ConvertTo-BgLine ([ordered]@{ type = 'attachment'; attachment = [ordered]@{ type = 'queued_command'; prompt = '<task-notification><task-id>wbg0001</task-id></task-notification>' } }) 3)
Check 'so does its copy in a queued_command record' ($o1.Count -eq 0)
$o2 = [ordered]@{}
Step-ChatBackgroundLine $o2 (New-BgResult $bgAgent 20)
Step-ChatBackgroundLine $o2 (New-BgNote 'abg0001' 15)
Step-ChatBackgroundLine $o2 (New-BgResult ([ordered]@{ success = $true; message = 'Resuming agent abg0001'; resumedAgentId = 'abg0001' }) 10)
Check 'SendMessage waking an agent that reported starts it again, at the wake''s time' ($o2.Count -eq 1 -and $o2['abg0001'].Kind -eq 'agent' -and
    [int]((Get-Date) - $o2['abg0001'].At).TotalMinutes -eq 10) "$($o2.Count) $($o2['abg0001'].At)"
$o3 = [ordered]@{}
Step-ChatBackgroundLine $o3 (New-BgResult $bgWf 30 'sdk-cli')
Step-ChatBackgroundLine $o3 (New-BgResult $bgAgent 5)
Check 'what a print-mode run started is left out with -SkipPrint, and a start before -Since always' ((& $bgIds $o3 -SkipPrint) -eq 'abg0001' -and (& $bgIds $o3) -eq 'abg0001,wbg0001' -and
    (& $bgIds $o3 -Since (Get-Date).AddMinutes(-15)) -eq 'abg0001') "$(& $bgIds $o3 -SkipPrint) | $(& $bgIds $o3 -Since (Get-Date).AddMinutes(-15))"
$o4 = [ordered]@{}
Step-ChatBackgroundLine $o4 (New-BgResult $bgShell 10)
Step-ChatBackgroundLine $o4 ('{"type":"user","toolUseResult":"Error: No task found with ID: bbg0001","task_type":"x"}')
Check 'a TaskStop that failed ends nothing' ($o4.Contains('bbg0001'))

# the ends a notification never comes for: a workflow's run record, an
# agent's own transcript
$o5 = [ordered]@{}
Step-ChatBackgroundLine $o5 (New-BgResult $bgWf 30)
Step-ChatBackgroundLine $o5 (New-BgResult $bgAgent 20)
$null = New-Item -ItemType Directory -Path (Join-Path $dirBg 'workflows'), (Join-Path $dirBg 'subagents') -Force
$bgRun = Join-Path (Join-Path $dirBg 'workflows') 'wf_bg-0001.json'
$bgAgentFile = Join-Path (Join-Path $dirBg 'subagents') 'agent-abg0001.jsonl'
Check 'with neither file, both are still out' ((& $bgIds $o5 -Dir $dirBg) -eq 'abg0001,wbg0001')
[System.IO.File]::WriteAllText($bgRun, '{"runId":"wf_bg-0001","status":"killed","startTime":1}', $utf8)
Check 'a workflow killed by an interrupt - no notification, its run record written - is over' ((& $bgIds $o5 -Dir $dirBg) -eq 'abg0001' -and (& $bgIds $o5) -eq 'abg0001,wbg0001')
(Get-Item -LiteralPath $bgRun).LastWriteTime = (Get-Date).AddMinutes(-45)
Check 'a record from before the start is an earlier run''s - a resumed run keeps its run id' ((& $bgIds $o5 -Dir $dirBg) -eq 'abg0001,wbg0001')
(Get-Item -LiteralPath $bgRun).LastWriteTime = Get-Date
$bgMsg = { param([string]$Type, $Stop) ConvertTo-BgLine ([ordered]@{ type = $Type; message = [ordered]@{ role = $Type; stop_reason = $Stop; content = @([ordered]@{ type = 'text'; text = 'x' }) } }) 1 }
[System.IO.File]::WriteAllText($bgAgentFile, ((& $bgMsg 'user' $null), (& $bgMsg 'assistant' 'tool_use')) -join "`n", $utf8)
$bgA1 = Test-ChatAgentDone $bgAgentFile
[System.IO.File]::AppendAllText($bgAgentFile, "`n" + (& $bgMsg 'user' $null), $utf8)
$bgA2 = Test-ChatAgentDone $bgAgentFile
[System.IO.File]::AppendAllText($bgAgentFile, "`n" + (& $bgMsg 'assistant' $null), $utf8)
$bgA3 = Test-ChatAgentDone $bgAgentFile
Check 'an agent mid tool call, owed a result, or mid-stream is not done' ($bgA1 -eq $false -and $bgA2 -eq $false -and $bgA3 -eq $false -and (& $bgIds $o5 -Dir $dirBg) -eq 'abg0001') "$bgA1 $bgA2 $bgA3"
[System.IO.File]::AppendAllText($bgAgentFile, "`n" + (& $bgMsg 'assistant' 'refusal'), $utf8)
$bgA4 = Test-ChatAgentDone $bgAgentFile
[System.IO.File]::AppendAllText($bgAgentFile, "`n" + (& $bgMsg 'assistant' 'max_tokens'), $utf8)
$bgA5 = Test-ChatAgentDone $bgAgentFile
Check 'nor one refused - Claude Code tries the turn again on a fallback model - or out of tokens' ($bgA4 -eq $false -and $bgA5 -eq $false) "$bgA4 $bgA5"
[System.IO.File]::AppendAllText($bgAgentFile, "`n" + (& $bgMsg 'assistant' 'end_turn') + "`n" + (ConvertTo-BgLine ([ordered]@{ type = 'ai-title'; aiTitle = 't' }) 0) + "`n", $utf8)
Check 'one whose last word ends its turn is done - announced or not' ((Test-ChatAgentDone $bgAgentFile) -eq $true -and (& $bgIds $o5 -Dir $dirBg) -eq '')
Check 'and a file untouched since the start being judged says nothing of it' ((Test-ChatAgentDone $bgAgentFile ((Get-Date).AddMinutes(5))) -eq $false -and $null -eq (Test-ChatAgentDone (Join-Path $dirBg 'nope.jsonl')))
# a last word longer than any fixed tail, and a long record after it; keys
# that differ only in case, which Windows PowerShell's ConvertFrom-Json refuses
$bgBig = { param($Stop, [int]$Kb, [switch]$Trail)
    $l = (ConvertTo-BgLine ([ordered]@{ type = 'assistant'; message = [ordered]@{ role = 'assistant'
                    content = @([ordered]@{ type = 'tool_use'; input = 'KEYS' }, [ordered]@{ type = 'text'; text = ('r' * ($Kb * 1024)) }); stop_reason = $Stop } }) 1).Replace('"KEYS"', '{"Path":"a","path":"b"}')
    $s = (& $bgMsg 'user' $null) + "`n" + $l + "`n"
    if ($Trail) { $s += (ConvertTo-BgLine ([ordered]@{ type = 'attachment'; attachment = [ordered]@{ type = 'x'; text = ('t' * 90KB) } }) 0) + "`n" }
    [System.IO.File]::WriteAllText($bgAgentFile, ('p' * 70KB) + "`n" + $s, $utf8)
    Test-ChatAgentDone $bgAgentFile }
$bgB1 = & $bgBig 'end_turn' 100
$bgB2 = & $bgBig 'end_turn' 2 -Trail
$bgB3 = & $bgBig 'tool_use' 100
Check 'a last word of 100 KB, or 90 KB of record after it, is read whole: done, and mid-call not' ($bgB1 -eq $true -and $bgB2 -eq $true -and $bgB3 -eq $false) "$bgB1 $bgB2 $bgB3"
$null = & $bgBig 'end_turn' 1   # finished again, for the reload checks below

# Get-ChatBackgroundTasks - the reload checks - reads the same way
$bgBefore = [System.IO.File]::ReadAllText($pBg, $utf8)
Add-BgLine (New-BgResult $bgWf 30)
Add-BgLine (New-BgResult $bgAgent 20)
Add-BgLine (New-BgResult $bgShell 10)
Check 'the reload checks: a killed workflow and a finished agent hold nothing, a shell never did' (@(Get-ChatBackgroundTasks $pBg).Count -eq 0) (@(Get-ChatBackgroundTasks $pBg) -join ',')
Remove-Item -LiteralPath $bgRun, $bgAgentFile -Force
Check 'without those files both hold it, the shell still not' (((@(Get-ChatBackgroundTasks $pBg) | Sort-Object) -join ',') -eq 'abg0001,wbg0001') (@(Get-ChatBackgroundTasks $pBg) -join ',')

# read a piece at a time, as the overlay reads it
$s1 = @{}
Update-ChatBackgroundScan $s1 $pBg
Check 'the scan reads it all, and finds what Get-ChatBackgroundTasks finds' ($s1.Done -and $s1.Offset -eq (Get-Item -LiteralPath $pBg).Length -and ((& $bgIds $s1.Open -Shells) -eq 'abg0001,bbg0001,wbg0001')) "$($s1.Done) $($s1.Offset) $(& $bgIds $s1.Open -Shells)"
$bgNote = New-BgNote 'wbg0001' 2
$bgHalf = $bgNote.Substring(0, 40)
[System.IO.File]::AppendAllText($pBg, $bgHalf, $utf8)
$was = $s1.Offset
Update-ChatBackgroundScan $s1 $pBg
Check 'a last line still being written waits, and the rest counts as read' ($s1.Done -and $s1.Offset -eq $was -and $s1.Open.Contains('wbg0001'))
[System.IO.File]::AppendAllText($pBg, $bgNote.Substring(40) + "`n", $utf8)
Update-ChatBackgroundScan $s1 $pBg
Check 'once whole it is read, from where the last call stopped' ($s1.Done -and -not $s1.Open.Contains('wbg0001') -and $s1.Offset -eq (Get-Item -LiteralPath $pBg).Length)
$s2 = @{}
$bgCalls = 0
while (-not $s2.Done -and $bgCalls -lt 200) { Update-ChatBackgroundScan $s2 $pBg -MaxBytes 300; $bgCalls++ }
Check 'read 300 bytes at a time - lines longer than that taken whole - it comes to the same' ($s2.Done -and $bgCalls -gt 3 -and (& $bgIds $s2.Open -Shells) -eq (& $bgIds $s1.Open -Shells)) "$bgCalls calls: $(& $bgIds $s2.Open -Shells)"
# lines longer than a piece (40 KB), searched a piece at a time: a word the
# first piece's end cuts in two, one byte of it in the next; a line with no
# word, and the line after it in the same piece; a word in a long line's
# first piece, with more pieces of the line after it
$pcShell = { param([int]$Pad) ConvertTo-BgLine ([ordered]@{ type = 'user'; message = [ordered]@{ role = 'user'
                content = @([ordered]@{ tool_use_id = 'toolu_bg'; type = 'tool_result'; content = ('p' * $Pad) }) }
            toolUseResult = [ordered]@{ stdout = ''; stderr = ''; interrupted = $false; isImage = $false; noOutputExpected = $false; backgroundTaskId = 'bbg0002' } }) 6 }
$pcL1 = & $pcShell (40KB - 17 - (& $pcShell 0).IndexOf('"backgroundTaskId"'))
$pcAt = $pcL1.IndexOf('"backgroundTaskId"')
$pPieces = Join-Path $work 'bg-pieces.jsonl'
[System.IO.File]::WriteAllText($pPieces, (@($pcL1
            New-BgResult ([ordered]@{ isAsync = $true; status = 'async_launched'; agentId = 'abg0002'; description = 'two' }) 5
            ConvertTo-BgLine ([ordered]@{ type = 'assistant'; message = [ordered]@{ role = 'assistant'; content = @([ordered]@{ type = 'text'; text = ('r' * 100KB) }) } }) 4
            New-BgResult ([ordered]@{ isAsync = $true; status = 'async_launched'; agentId = 'abg0003'; description = 'three' }) 3
            ConvertTo-BgLine ([ordered]@{ type = 'user'; message = [ordered]@{ role = 'user'
                        content = "<task-notification>`n<task-id>abg0002</task-id>`n<status>completed</status>`n</task-notification>" + ('q' * 60KB) } }) 2
        ) -join "`n") + "`n", $utf8)
$pcLen = (Get-Item -LiteralPath $pPieces).Length
$s3 = @{}
Update-ChatBackgroundScan $s3 $pPieces
$s4 = @{}
$pcCalls = 0
while (-not $s4.Done -and $pcCalls -lt 200) { Update-ChatBackgroundScan $s4 $pPieces -MaxBytes 300; $pcCalls++ }
# and a byte at a time: a piece no smaller than what is kept for a cut word
$s5 = @{}
$pcCalls1 = 0
while (-not $s5.Done -and $pcCalls1 -lt 200) { Update-ChatBackgroundScan $s5 $pPieces -MaxBytes 1; $pcCalls1++ }
Check 'lines longer than a piece: a word a piece''s end cuts in two, the line after one with no word, a word in a long line''s first piece; 300 bytes at a time the same, and 1' (
    $pcAt -eq 40KB - 17 -and $s3.Done -and $s3.Offset -eq $pcLen -and (& $bgIds $s3.Open -Shells) -eq 'abg0003,bbg0002' -and
    $s4.Done -and $s4.Offset -eq $pcLen -and (& $bgIds $s4.Open -Shells) -eq 'abg0003,bbg0002' -and
    $s5.Done -and $s5.Offset -eq $pcLen -and (& $bgIds $s5.Open -Shells) -eq 'abg0003,bbg0002') (
    "at $pcAt; read $($s3.Offset), $($s4.Offset) in $pcCalls calls, $($s5.Offset) in $pcCalls1, of $pcLen`: $(& $bgIds $s3.Open -Shells) | $(& $bgIds $s4.Open -Shells) | $(& $bgIds $s5.Open -Shells)")
[System.IO.File]::WriteAllText($pBg, $bgBefore, $utf8)
Update-ChatBackgroundScan $s1 $pBg
Check 'a transcript that shrank is read again from the start' ($s1.Done -and $s1.Open.Count -eq 0 -and $s1.Offset -eq (Get-Item -LiteralPath $pBg).Length)

# the overlay: an idle chat with work out reads as working, in its words
Add-BgLine (New-BgResult $bgWf 7)
$bgStarted = [DateTimeOffset]::UtcNow.AddMinutes(-60).ToUnixTimeMilliseconds()
$bgEntry = { param([string]$Status = 'idle', [int64]$StartedAt = $bgStarted, [string]$Kind = 'interactive')
    [pscustomobject]@{ SessionId = $idBg; Pid = 4242; Status = $Status; Kind = $Kind; StartedAt = $StartedAt; Cwd = $projBg; StatusUpdatedAt = $bgStarted } }
$bgTexts = @{ $idBg = @{ Path = $pBg; Mtime = (Get-Date) } }
$bgCache = @{}
$e1 = & $bgEntry
$bg1 = Update-ChatOverlayBackground $bgCache @($e1) @($e1) $bgTexts $null
$r1 = @(Get-ChatOverlayRows -Sessions @($e1) -Texts $bgTexts -Background $bg1)[0]
Check 'an idle chat with a workflow out reads as working, workflow and how long it has run' ($bg1[$idBg].Workflows -eq 1 -and $r1.status -eq 'busy' -and $r1.chat -eq 'busy' -and
    $r1.rank -eq 1 -and $r1.stateText -eq 'workflow 7m' -and $r1.background.workflows -eq 1) "$($r1.status) '$($r1.stateText)'"
$e2 = & $bgEntry 'busy'
$bg2 = Update-ChatOverlayBackground $bgCache @($e2) @($e2) $bgTexts $null
$r2 = @(Get-ChatOverlayRows -Sessions @($e2) -Texts $bgTexts -Background $bg2)[0]
Check 'a chat Claude calls busy says working, as ever' (-not $bg2.ContainsKey($idBg) -and $r2.stateText -like 'working*' -and -not $r2.PSObject.Properties['background'])
$e3 = & $bgEntry 'idle' ([DateTimeOffset]::UtcNow.AddMinutes(-3).ToUnixTimeMilliseconds())
$bg3 = Update-ChatOverlayBackground $bgCache @($e3) @($e3) $bgTexts $null
Check 'one started before the chat''s process did died with the old process' (-not $bg3.ContainsKey($idBg))
$ep = & $bgEntry 'busy' $bgStarted 'print'
$bg4 = Update-ChatOverlayBackground @{} @($e1) @($e1, $ep) $bgTexts $null
Check 'the cache is by transcript: a fresh one reads it all again and says the same' ($bg4[$idBg].Count -eq 1)
Add-BgLine (New-BgNote 'wbg0001' 1)
Add-BgLine (New-BgResult $bgShell 4)
$script:ChatShellChildSeam = { param($p) 1 }
$bg5 = Update-ChatOverlayBackground $bgCache @($e1) @($e1) $bgTexts $null
$r5 = @(Get-ChatOverlayRows -Sessions @($e1) -Texts $bgTexts -Background $bg5)[0]
$script:ChatShellChildSeam = { param($p) 0 }
$bg6 = Update-ChatOverlayBackground $bgCache @($e1) @($e1) $bgTexts $null
$script:ChatShellChildSeam = { param($p) $null }
$bg7 = Update-ChatOverlayBackground $bgCache @($e1) @($e1) $bgTexts $null
Check 'a background shell reads as shell while a shell runs under the chat' ($r5.stateText -eq 'shell 4m' -and $r5.background.shells -eq 1) "'$($r5.stateText)'"
Check 'none there: it ended from the task list, and the chat is idle' (-not $bg6.ContainsKey($idBg))
Check 'and where the processes cannot be asked, the transcript''s word stands' ($bg7[$idBg].Shells -eq 1)
Add-BgLine (New-BgResult ([ordered]@{ stdout = ''; stderr = ''; interrupted = $false; backgroundTaskId = 'bbg0002' }) 2)
$script:ChatShellChildSeam = { param($p) 1 }
$bg8 = Update-ChatOverlayBackground $bgCache @($e1) @($e1) $bgTexts $null
$r8 = @(Get-ChatOverlayRows -Sessions @($e1) -Texts $bgTexts -Background $bg8)[0]
Check 'two starts and one shell running: the newest counts, and its time' ($bg8[$idBg].Shells -eq 1 -and $r8.stateText -eq 'shell 2m') "$($bg8[$idBg].Shells) '$($r8.stateText)'"
$epr = [pscustomobject]@{ SessionId = $idBg; Pid = 5151; Status = 'busy'; Kind = 'print'; StartedAt = $bgStarted }
$script:ChatShellChildSeam = { param($p) if ($p -eq 5151) { 2 } else { 0 } }
$bg9 = Update-ChatOverlayBackground $bgCache @($e1) @($e1, $epr) $bgTexts $null
Check 'shells under a print-mode run of the chat count too' ($bg9[$idBg].Shells -eq 2) "$($bg9[$idBg].Shells)"
$script:ChatShellChildSeam = { param($p) if ($p -eq 1) { 1 } elseif ($p -eq 2) { 2 } else { $null } }
Check 'the count is over all the chat''s processes, and unknown if any is' ((Get-ChatShellChildCount @(1, 2)) -eq 3 -and $null -eq (Get-ChatShellChildCount @(1, 3)) -and $null -eq (Get-ChatShellChildCount @()))
$script:ChatShellChildSeam = $null
if ($script:ChatqIsWindows) {
    $bgT = [System.Diagnostics.Stopwatch]::StartNew()
    $bgC = Get-ChatShellChildCount @($PID) ((Get-Date).AddMinutes(1))
    $bgMs = $bgT.ElapsedMilliseconds
    # the best of five, each past the cache: a busy machine's stall spoils a
    # look or two, where WMI's 0.4 s would show in every one
    $bgBest = [long]::MaxValue
    foreach ($bgN in 2..6) {
        $bgT.Restart()
        $null = Get-ChatShellChildCount @($PID) ((Get-Date).AddMinutes($bgN))
        $bgBest = [Math]::Min($bgBest, $bgT.ElapsedMilliseconds)
    }
    Check 'on Windows the list comes from Toolhelp32 - a count, not unknown, in milliseconds once loaded' ($bgC -is [int] -and $bgBest -lt 150) "$bgC, first $bgMs ms, then at best $bgBest ms"
}
# a cut-off chat is cut off, whatever it still has running
$bgCut = [pscustomobject]@{ Id = $idBg; Cwd = $projBg; Title = 'Background host chat'; At = (Get-Date).AddMinutes(-1); ResetsAt = (Get-Date).AddHours(2); Why = 'limit'; Path = $pBg }
$r10 = @(Get-ChatOverlayRows -Sessions @($e1) -Texts $bgTexts -Background $bg9 -CutOff @($bgCut))[0]
Check 'a chat the limit cut off reads cut off, not its dev server''s shell' ($r10.status -eq 'cutoff' -and $r10.stateText -like 'cut off*') "$($r10.status) '$($r10.stateText)'"
# -Whole: every transcript to its end in one call, whatever the clock says
$idBg2 = 'bdbdbdbd-bdbd-4dbd-8dbd-bdbdbdbdbdbd'
$pBg2 = New-FakeChat $projBg $idBg2 'Second background chat' 1 @('and another')
[System.IO.File]::AppendAllText($pBg2, (New-BgResult $bgWf 3) + "`n", $utf8)
$e11 = [pscustomobject]@{ SessionId = $idBg2; Pid = 4343; Status = 'idle'; Kind = 'interactive'; StartedAt = $bgStarted; Cwd = $projBg }
$bgTexts2 = @{ $idBg = $bgTexts[$idBg]; $idBg2 = @{ Path = $pBg2 } }
$bgClock = [System.Diagnostics.Stopwatch]::StartNew()
$script:ChatShellChildSeam = { param($p) $null }
$bg11 = Update-ChatOverlayBackground @{} @($e1, $e11) @($e1, $e11) $bgTexts2 $bgClock -SliceMs -1
$bg12 = Update-ChatOverlayBackground @{} @($e1, $e11) @($e1, $e11) $bgTexts2 $bgClock -SliceMs -1 -Whole
$script:ChatShellChildSeam = $null
Check 'past its slice a pass reads one transcript; -Whole reads them all' ($bg11.Count -eq 1 -and $bg11.ContainsKey($idBg) -and $bg12.Count -eq 2 -and $bg12[$idBg2].Workflows -eq 1) "$($bg11.Count) $($bg12.Count)"
Remove-Item -LiteralPath $pBg2 -Force -EA SilentlyContinue
Check 'the words: one kind named and counted, a mix is background' ((Format-ChatOverlayBackground @{ Count = 1; Workflows = 1 }) -eq 'workflow' -and
    (Format-ChatOverlayBackground @{ Count = 2; Agents = 2 }) -eq '2 agents' -and (Format-ChatOverlayBackground @{ Count = 2; Shells = 2 }) -eq '2 shells' -and
    (Format-ChatOverlayBackground @{ Count = 2; Workflows = 1; Agents = 1 }) -eq 'background' -and (Format-ChatOverlayBackground @{ Count = 0 }) -eq '')
# gone, so no later section finds it as the newest chat of the sandbox
Remove-Item -LiteralPath $pBg -Force -EA SilentlyContinue
Remove-Item -LiteralPath $dirBg -Recurse -Force -EA SilentlyContinue
