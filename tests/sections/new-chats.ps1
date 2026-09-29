# tests/sections/new-chats.ps1: dot-sourced by tests/run-tests.ps1 in its turn,
# never on its own - it uses what the runner and the sections before it set.

Section 'new chats'
$newDir = Join-Path $sb 'work\fresh project'
$null = New-Item -ItemType Directory -Path $newDir -Force
$nn = New-ChatqJob -Kind new -Cwd $newDir -Prompt "set up the build`nwith tests"
$nj = $nn.Job
$slugNew = ($newDir -replace '[^A-Za-z0-9]', '-')
Check 'a new chat''s job: its session id chosen now, its transcript''s path known, named by the first line' (
    $nj.kind -eq 'new' -and $nj.sessionId -match '^[0-9a-f-]{36}$' -and $nj.title -eq 'set up the build' -and $nj.rule -eq 'new' -and
    $nj.path -eq (Join-Path (Join-Path (Join-Path $claudeHome 'projects') $slugNew) "$($nj.sessionId).jsonl") -and $nj.cwd -eq $newDir -and -not (Test-Path -LiteralPath $nj.path)) "$($nj.title) $($nj.path)"
$env:FAKE_RECORD = $rec
$env:FAKE_NEW_CHAT = '1'
Remove-Item -LiteralPath $script:ChatReloadPath -Force -EA SilentlyContinue
Invoke-ChatqJob $W (Find-ChatqJob $nj.id)
$nj = Find-ChatqJob $nj.id
$argvNew = @([System.IO.File]::ReadAllLines((Join-Path $rec 'argv.txt')))
$si = [Array]::IndexOf($argvNew, '--session-id')
$ni = [Array]::IndexOf($argvNew, '--name')
$rqNew = if (Test-Path -LiteralPath $script:ChatReloadPath) { [System.IO.File]::ReadAllText($script:ChatReloadPath, $utf8) | ConvertFrom-Json } else { $null }
Check 'its first run starts the chat with that id and name - no --resume - and it lands where said' (
    $nj.state -eq 'done' -and $si -ge 0 -and $argvNew[$si + 1] -eq $nj.sessionId -and $ni -ge 0 -and $argvNew[$ni + 1] -eq 'set up the build' -and
    $argvNew -notcontains '--resume' -and (Test-Path -LiteralPath $nj.path)) "$($nj.state) $($argvNew -join ' ')"
Check 'and a window on that folder is offered a reload to pick it up' ($rqNew -and $rqNew.kind -eq 'new' -and $rqNew.cwd -eq $newDir -and $rqNew.title -eq 'set up the build') "$($rqNew.kind) $($rqNew.cwd)"
$newRow = Get-ChatqRowById $nj.sessionId -Path $nj.path
$follow = (New-ChatqJob -Row $newRow -Prompt 'now the tests' -Rule 'picked').Job
Invoke-ChatqJob $W (Find-ChatqJob $follow.id)
$argvF = @([System.IO.File]::ReadAllLines((Join-Path $rec 'argv.txt')))
$ri = [Array]::IndexOf($argvF, '--resume')
Check 'the chat it made is a chat like any other: found by id, named, and the next prompt resumes it' (
    $newRow.Title -eq 'set up the build' -and $ri -ge 0 -and $argvF[$ri + 1] -eq $nj.sessionId -and $argvF -notcontains '--session-id' -and
    (Find-ChatqJob $follow.id).state -eq 'done') "$($newRow.Title) $($argvF -join ' ')"
# a limit after the prompt reached the new chat: back as a continue into it,
# never a second new chat
$nl = (New-ChatqJob -Kind new -Cwd $newDir -Prompt 'a second new one' -Title 'limited start').Job
$env:FAKE_SCENARIO = Join-Path $here 'fixtures\stream\rejected.jsonl'
Remove-Item -LiteralPath $script:ChatReloadPath -Force -EA SilentlyContinue
Invoke-ChatqJob $W (Find-ChatqJob $nl.id)
$nl = Find-ChatqJob $nl.id
$rqLimited = Test-Path -LiteralPath $script:ChatReloadPath
Remove-Item env:FAKE_SCENARIO
$W.blocked = @{}
# Claude Code writes the limit into the chat as it stops; the continue goes
# only while that is still the chat's last word
$limRec = [ordered]@{ type = 'assistant'; uuid = [guid]::NewGuid().ToString(); timestamp = (Get-Date).ToUniversalTime().ToString('o'); sessionId = $nl.sessionId
    message = [ordered]@{ model = '<synthetic>'; role = 'assistant'; content = @([ordered]@{ type = 'text'; text = "You've hit your session limit" }) }
    quotaLimits = [ordered]@{ status = 'rejected'; resetsAt = [DateTimeOffset]::UtcNow.AddHours(2).ToUnixTimeSeconds(); rateLimitType = 'five_hour' }
    error = 'rate_limit'; isApiErrorMessage = $true } | ConvertTo-Json -Compress -Depth 6
[System.IO.File]::AppendAllText($nl.path, $limRec + "`n", $utf8)
Invoke-ChatqJob $W (Find-ChatqJob $nl.id)
$argvL = @([System.IO.File]::ReadAllLines((Join-Path $rec 'argv.txt')))
$stdinL = [System.IO.File]::ReadAllText((Join-Path $rec 'stdin.bin'), $utf8)
$ri = [Array]::IndexOf($argvL, '--resume')
Check 'a new chat limited after its prompt landed goes on as "continue" in that same chat' (
    $nl.retryAs -eq 'continue' -and $ri -ge 0 -and $argvL[$ri + 1] -eq $nl.sessionId -and $stdinL -eq $script:ChatqContinueText -and (Find-ChatqJob $nl.id).state -eq 'done') "$($nl.retryAs) $($argvL -join ' ')"
$rqL = if (Test-Path -LiteralPath $script:ChatReloadPath) { [System.IO.File]::ReadAllText($script:ChatReloadPath, $utf8) | ConvertFrom-Json } else { $null }
Check 'its reload is offered when it finishes, not lost with the run the limit cut' (-not $rqLimited -and $rqL.kind -eq 'new' -and $rqL.title -eq 'limited start') "$rqLimited $($rqL.kind) $($rqL.title)"
# Claude filed it under a folder name that is not the slug - a path over 200
# characters, or CLAUDE_CODE_PROJECT_DIR_NAME: found by its id and kept, and
# never started twice with --session-id, which Claude refuses. Its title goes
# through claude.cmd - cmd.exe - with nothing cmd would take as its own.
$env:CLAUDE_CODE_PROJECT_DIR_NAME = 'named-elsewhere'
$nr = (New-ChatqJob -Kind new -Cwd $newDir -Prompt 'filed elsewhere' -Title 'Use "quotes" & more').Job
Remove-Item -LiteralPath $script:ChatReloadPath -Force -EA SilentlyContinue
Invoke-ChatqJob $W (Find-ChatqJob $nr.id)
$nr = Find-ChatqJob $nr.id
$argvR = @([System.IO.File]::ReadAllLines((Join-Path $rec 'argv.txt')))
$ni = [Array]::IndexOf($argvR, '--name')
$wantR = Join-Path (Join-Path (Join-Path $claudeHome 'projects') 'named-elsewhere') "$($nr.sessionId).jsonl"
$rqR = if (Test-Path -LiteralPath $script:ChatReloadPath) { [System.IO.File]::ReadAllText($script:ChatReloadPath, $utf8) | ConvertFrom-Json } else { $null }
Check 'a title through claude.cmd keeps its words and loses what cmd.exe would run' ($ni -ge 0 -and $argvR[$ni + 1] -eq 'Use quotes more' -and $argvR -contains 'stream-json') ($argvR -join ' ')
Check 'a new chat filed under another folder name is found by its id, and kept' (
    $nr.state -eq 'done' -and $nr.path -eq $wantR -and $nr.group -eq 'named-elsewhere' -and $rqR.kind -eq 'new') "$($nr.state) $($nr.path) $($rqR.kind)"
$null = Reset-ChatqJob $nr
Invoke-ChatqJob $W (Find-ChatqJob $nr.id)
$argvR2 = @([System.IO.File]::ReadAllLines((Join-Path $rec 'argv.txt')))
Check 'and a requeue resumes it' ((Find-ChatqJob $nr.id).state -eq 'done' -and $argvR2 -contains '--resume' -and $argvR2 -notcontains '--session-id') ($argvR2 -join ' ')
Remove-Item env:CLAUDE_CODE_PROJECT_DIR_NAME
# its transcript deleted since: the continue fails as a chat gone - never a
# fresh chat whose only prompt is "continue"
Remove-Item -LiteralPath $nr.path -Force
$null = Reset-ChatqJob (Find-ChatqJob $nr.id)
Remove-Item -LiteralPath (Join-Path $rec 'argv.txt') -Force
Invoke-ChatqJob $W (Find-ChatqJob $nr.id)
$gone = Find-ChatqJob $nr.id
Check 'a new chat deleted since is gone: no second start' ($gone.state -eq 'failed' -and $gone.result.reason -like '*chat is gone*' -and -not (Test-Path -LiteralPath (Join-Path $rec 'argv.txt'))) "$($gone.state) $($gone.result.reason)"
Remove-Item env:FAKE_NEW_CHAT, env:FAKE_RECORD
$noDir = New-ChatqJob -Kind new -Cwd (Join-Path $sb 'no such folder') -Prompt 'x'
$noText = New-ChatqJob -Kind new -Cwd $newDir -Prompt ' '
$cutOk = try { $null = Get-ChatqCutOffChats (@(Get-ChatqJobs) + @([pscustomobject]@{ state = 'queued'; sessionId = $null })); $true } catch { $false }
Check 'a folder that is not there, or no prompt, makes no job; a job with no session never breaks the cut-off list' (
    $noDir.Code -eq 'info' -and $noText.Code -eq 'empty' -and $cutOk) "$($noDir.Error) / $($noText.Code) / $cutOk"
# a drive's root: C:\, not C: - which as a working folder means wherever
# that drive last was - and Claude's slug for it, C--
$driveRoot = [System.IO.Path]::GetPathRoot($sb)
$nroot = (New-ChatqJob -Kind new -Cwd $driveRoot -Prompt 'at the root').Job
$rootSlug = ($driveRoot -replace '[^A-Za-z0-9]', '-')
Check 'a new chat at a drive''s root keeps the root, and the slug Claude gives it' (
    $nroot.cwd -eq $driveRoot -and $nroot.group -eq $rootSlug -and (Get-ChatSlug 'D:\a\b\') -eq 'D--a-b' -and (Get-ChatSlug 'C:\') -eq 'C--') "$($nroot.cwd) $($nroot.group)"
foreach ($x in $nj, $follow, $nl, $nr, $nroot) { $null = Remove-ChatqJob (Find-ChatqJob $x.id) 'test' }

# Claude Code's lists: a chat whose head names no entrypoint - a pasted
# screenshot first - is left out of them by the sdk-cli a claude -p run
# stamps last, and listed again as a run into it ends (Repair-ChatListed)
$epl = { param($v) '{"type":"user","entrypoint":"' + $v + '","message":{"role":"user","content":"x"}}' + "`n" }
Check 'the list rule: the first entrypoint as Claude Code finds it - the key without a space first, the last by place, escapes read, one cut off none' (
    (Get-ChatEntrypointIn ('{"entrypoint": "x"}' + "`n" + '{"entrypoint":"y"}')) -eq 'y' -and
    (Get-ChatEntrypointIn ('{"entrypoint":"a"}' + "`n" + '{"entrypoint": "b"}') -Last) -eq 'b' -and
    (Get-ChatEntrypointIn ('{"entrypoint": "b"}' + "`n" + '{"entrypoint":"a"}') -Last) -eq 'a' -and
    (Get-ChatEntrypointIn '{"entrypoint":"s\"x"}') -eq 's"x' -and $null -eq (Get-ChatEntrypointIn '{"entrypoint":"sdk-c') -and
    (Get-ChatEntrypointIn ('{"entrypoint":"a"}' + "`n" + '{"entrypoint":"sdk-c') -Last) -eq 'a' -and $null -eq (Get-ChatEntrypointIn 'none' -Last))
Check 'the list rule: an SDK''s entrypoint first in the head hides a chat for good; with none in the head the tail''s last decides' (
    (Get-ChatUnlistedWhy (& $epl 'claude-vscode') (& $epl 'sdk-cli')) -eq '' -and (Get-ChatUnlistedWhy (& $epl 'sdk-cli') (& $epl 'claude-vscode')) -eq 'head' -and
    (Get-ChatUnlistedWhy 'none' ((& $epl 'claude-vscode') + (& $epl 'sdk-cli'))) -eq 'tail' -and
    (Get-ChatUnlistedWhy 'none' ((& $epl 'sdk-cli') + (& $epl 'claude-vscode'))) -eq '' -and
    (Get-ChatUnlistedWhy (& $epl '') (& $epl 'sdk-cli')) -eq '' -and (Get-ChatUnlistedWhy 'none' 'none') -eq '')
$shotRec = ([ordered]@{ type = 'user'; message = [ordered]@{ role = 'user'; content = ('A' * 70000) } } | ConvertTo-Json -Compress) + "`n"
$hidText = $shotRec + (& $epl 'claude-vscode') + (& $epl 'sdk-cli') + '{"type":"ai-title","aiTitle":"hidden by its tail"}' + "`n"
$lDir = Join-Path $sb 'listed'
$null = New-Item -ItemType Directory -Path $lDir -Force
$then = (Get-Date).ToUniversalTime().AddHours(-3)
$mkL = { param([string]$Name, [string]$Text) $f = Join-Path $lDir "$Name.jsonl"; [System.IO.File]::WriteAllText($f, $Text, $utf8); [System.IO.File]::SetLastWriteTimeUtc($f, $then); $f }
$lTail = & $mkL 'tail' $hidText
$lWhy0 = (Read-ChatHeadTail $lTail) | ForEach-Object { Get-ChatUnlistedWhy $_.Head $_.Tail }
$lR1 = Repair-ChatListed -Path $lTail -SessionId 'sid-tail'
$lLast = @([System.IO.File]::ReadAllLines($lTail, $utf8))[-1]
$lWhy1 = (Read-ChatHeadTail $lTail) | ForEach-Object { Get-ChatUnlistedWhy $_.Head $_.Tail }
$lR2 = Repair-ChatListed -Path $lTail -SessionId 'sid-tail'
Check 'hidden by its tail: one line of chatq''s own at the end, as the extension writes it, naming a VS Code panel and no time - listed again, its write time kept, and a second look adds none' (
    $lWhy0 -eq 'tail' -and $lR1 -eq 'relisted' -and $lWhy1 -eq '' -and $lR2 -eq 'listed' -and
    $lLast -ceq '{"type":"chatq-listed","entrypoint":"claude-vscode","sessionId":"sid-tail"}' -and
    @([System.IO.File]::ReadAllLines($lTail, $utf8)).Count -eq 5 -and [System.IO.File]::GetLastWriteTimeUtc($lTail) -eq $then) "$lWhy0 $lR1 $lWhy1 $lR2 $lLast"
$lCut = & $mkL 'cut' ($hidText.TrimEnd("`n"))
$lR3 = Repair-ChatListed -Path $lCut -SessionId 'sid-cut'
$cutOk = $true
foreach ($l in [System.IO.File]::ReadAllLines($lCut, $utf8)) { try { $null = $l | ConvertFrom-Json } catch { $cutOk = $false } }
$lHead = & $mkL 'head' ((& $epl 'sdk-cli') + (& $epl 'sdk-cli'))
$lBusy = & $mkL 'busy' $hidText
$lIdle = & $mkL 'idle' $hidText
$lR4 = Repair-ChatListed -Path $lHead -SessionId 'sid-head'
$lR5 = Repair-ChatListed -Path $lBusy -SessionId 'sid-busy' -Live @([pscustomobject]@{ SessionId = 'sid-busy'; Status = 'busy'; Kind = 'interactive' })
$lR5b = Repair-ChatListed -Path $lBusy -SessionId 'sid-busy' -Live @([pscustomobject]@{ SessionId = 'sid-busy'; Status = 'idle'; Kind = 'print' })
$lR6 = Repair-ChatListed -Path $lIdle -SessionId 'sid-idle' -Live @([pscustomobject]@{ SessionId = 'sid-idle'; Status = 'idle'; Kind = 'interactive' })
$lR7 = Repair-ChatListed -Path (Join-Path $lDir 'gone.jsonl') -SessionId 'sid-gone'
Check 'its last line lacking its end: the new one on a line of its own; hidden by its head: unlistable, untouched; a process busy in it, or a print-mode run: held; one idle: mended; no file: nothing made' (
    $lR3 -eq 'relisted' -and $cutOk -and $lR4 -eq 'unlistable' -and [System.IO.File]::ReadAllText($lHead, $utf8) -eq ((& $epl 'sdk-cli') + (& $epl 'sdk-cli')) -and
    $lR5 -eq 'held' -and $lR5b -eq 'held' -and [System.IO.File]::ReadAllText($lBusy, $utf8) -eq $hidText -and $lR6 -eq 'relisted' -and
    $lR7 -eq 'unknown' -and -not (Test-Path -LiteralPath (Join-Path $lDir 'gone.jsonl'))) "$lR3 $cutOk $lR4 $lR5 $lR5b $lR6 $lR7"
# the watcher: a run into such a chat lists it again as it ends; a new chat,
# its first record an SDK's, is left - nothing can list it
$hidId = 'a1b2c3d4-0000-4000-8000-00000000c0de'
# a first prompt of 70 KB and no entrypoint in any record, then an old run's
$hidPath = New-FakeChat $newDir $hidId 'hidden by its tail' 1 @(('A' * 70000), 'and then')
[System.IO.File]::AppendAllText($hidPath, (& $epl 'sdk-cli'), $utf8)
$hidRow = Get-ChatqRowById $hidId -Path $hidPath
$hj = (New-ChatqJob -Row $hidRow -Prompt 'after the screenshot' -Rule 'picked').Job
Invoke-ChatqJob $W (Find-ChatqJob $hj.id)
$hjDone = Find-ChatqJob $hj.id
$hidLast = @([System.IO.File]::ReadAllLines($hidPath, $utf8))[-1]
$wlog = [System.IO.File]::ReadAllText((Join-Path $script:ChatqLogDir 'watcher.log'), $utf8)
Check 'a run into a chat Claude Code leaves out by its tail: listed again as it ends, and the log says so; a new chat, its head an SDK''s, is left as it is' (
    $hjDone.state -eq 'done' -and $hidLast -ceq (Get-ChatListedLine $hidId) -and $wlog -like "*#$($hjDone.seq) listed again*" -and
    [System.IO.File]::ReadAllText($nj.path, $utf8) -notlike '*chatq-listed*') "$($hjDone.state) $hidLast"
$null = Remove-ChatqJob (Find-ChatqJob $hj.id) 'test'
# the requests name the transcript where it is known, for the window to mend
# before it opens the chat; without one, the field is not there
Write-ChatOpenRequest -SessionId $hidId -Cwd $newDir -Title 't' -Transcript $hidPath
$oq = [System.IO.File]::ReadAllText($script:ChatOpenPath, $utf8) | ConvertFrom-Json
Write-ChatOpenRequest -SessionId $hidId -Cwd $newDir -Title 't'
$oq2 = [System.IO.File]::ReadAllText($script:ChatOpenPath, $utf8) | ConvertFrom-Json
Write-ChatReloadRequest -Title 't' -Cwd $newDir -Kind 'ran' -SessionId $hidId -Transcript $hidPath
$rq = [System.IO.File]::ReadAllText($script:ChatReloadPath, $utf8) | ConvertFrom-Json
Write-ChatReloadRequest -Title 't' -Cwd $newDir -Kind 'ran' -SessionId $hidId
$rq2 = [System.IO.File]::ReadAllText($script:ChatReloadPath, $utf8) | ConvertFrom-Json
Check 'the open and run requests carry the transcript''s path where given, and no such field where not' (
    $oq.file -eq $hidPath -and -not $oq2.PSObject.Properties['file'] -and $rq.file -eq $hidPath -and -not $rq2.PSObject.Properties['file']) "$($oq.file) / $($rq.file)"
Remove-Item -LiteralPath $script:ChatOpenPath, $script:ChatReloadPath -Force -EA SilentlyContinue
# the append: a record another process adds after the open is never written
# over - this line lands after it - and a file gone is never made again
$ap = & $mkL 'append' "first`n"
$afs = Open-ChatAppend $ap
# another writer, sharing as Claude Code's own do, at the end it sees
$other = [System.IO.FileStream]::new($ap, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
$null = $other.Seek(0, [System.IO.SeekOrigin]::End)
$tb = $utf8.GetBytes("theirs`n"); $other.Write($tb, 0, $tb.Length); $other.Dispose()
$ab = $utf8.GetBytes("ours`n")
$afs.Write($ab, 0, $ab.Length); $afs.Dispose()
$apGone = Join-Path $lDir 'append-gone.jsonl'
$apRefused = try { (Open-ChatAppend $apGone).Dispose(); $false } catch { $true }
Check 'the line is appended as the extension appends it: a record another process adds after the open stays, and this lands after it; no file is made' (
    [System.IO.File]::ReadAllText($ap, $utf8) -eq "first`ntheirs`nours`n" -and $apRefused -and -not (Test-Path -LiteralPath $apGone)) ([System.IO.File]::ReadAllText($ap, $utf8))

# chatclean lists again what nothing else will: a chat hidden before 0.8.1,
# neither run into nor opened since. Held while in use; a side transcript,
# which Claude Code never lists, left as it is; a second pass adds nothing
$ccHidId = 'c1c1c1c1-0000-4000-8000-00000000c1c1'
$ccBusyId = 'c2c2c2c2-0000-4000-8000-00000000c2c2'
$ccSideId = 'c3c3c3c3-0000-4000-8000-00000000c3c3'
$ccPaths = foreach ($x in @(@($ccHidId, 'hidden before 0.8.1'), @($ccBusyId, 'hidden and in use'), @($ccSideId, 'a side transcript'))) {
    $f = New-FakeChat $newDir $x[0] $x[1] 2 @(('A' * 70000), 'and then')
    [System.IO.File]::AppendAllText($f, (& $epl 'sdk-cli'), $utf8)
    $f
}
$ccSide = $ccPaths[2]
[System.IO.File]::WriteAllText($ccSide, ([System.IO.File]::ReadAllText($ccSide, $utf8) -replace '"isSidechain":false', '"isSidechain":true'), $utf8)
$ccBusyBytes = [System.IO.File]::ReadAllBytes($ccPaths[1])
$ccSideBytes = [System.IO.File]::ReadAllBytes($ccSide)
$ccLive = @([pscustomobject]@{ SessionId = $ccBusyId; Status = 'busy'; Kind = 'interactive' })
$ccCodex = [pscustomobject]@{ Provider = 'codex'; Id = $ccHidId; Path = $ccPaths[0]; Hidden = $false }
$cc1 = Repair-ChatListedAll -Rows (@(Sync-ChatIndex -Provider claude) + $ccCodex) -Live $ccLive
$cc2 = Repair-ChatListedAll -Rows @(Sync-ChatIndex -Provider claude) -Live $ccLive
$ccMine = { param($rows) @($rows | Where-Object { $_.Id -in $ccHidId, $ccBusyId, $ccSideId } | ForEach-Object { $_.Id }) -join ',' }
Check 'a chat hidden by its tail, never run into or opened since: listed again from the index; one in use held, untouched; a side transcript passed over; a second pass adds none' (
    (& $ccMine $cc1.Relisted) -eq $ccHidId -and (& $ccMine $cc1.Held) -eq $ccBusyId -and -not $cc2.Relisted.Count -and (& $ccMine $cc2.Held) -eq $ccBusyId -and
    @([System.IO.File]::ReadAllLines($ccPaths[0], $utf8))[-1] -ceq (Get-ChatListedLine $ccHidId) -and
    [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($ccPaths[1])) -eq [Convert]::ToBase64String($ccBusyBytes) -and
    [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($ccSide)) -eq [Convert]::ToBase64String($ccSideBytes)) "relisted $(& $ccMine $cc1.Relisted) / held $(& $ccMine $cc1.Held) / again $($cc2.Relisted.Count)"
# chatclean itself, once the chat is no longer in use: it says which it
# listed again. The ghost picker declines, so nothing of the sandbox goes
$ccPick = ${function:Select-ChatItems}
${function:Select-ChatItems} = { param($Items, $Title) @() }
try { $ccOut = (chatclean -Provider claude *>&1 | Out-String) }
finally { ${function:Select-ChatItems} = $ccPick }
Check 'chatclean lists it again once idle, and says so by its title' (
    $ccOut -like '*listed again in Claude Code: hidden and in use*' -and $ccOut -notlike '*a side transcript*' -and
    @([System.IO.File]::ReadAllLines($ccPaths[1], $utf8))[-1] -ceq (Get-ChatListedLine $ccBusyId)) $ccOut
Remove-Item -LiteralPath $ccPaths -Force -EA SilentlyContinue
