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
# chatq -New on the mode and model given, said as a new chat's; a model no
# claude.cmd could be handed refused before anything is queued. Its folder,
# -Continue and a folder not there are tests/sections/attachments.ps1's.
$cnWatch = ${function:Start-ChatqWatcher}
${function:Start-ChatqWatcher} = { param([string]$Wake) $true }
$cnBefore = @(Get-ChatqJobs).Count
try {
    $cnSaid = (chatq -New $newDir 'Parser rewrite' -Prompt 'plan the rewrite first' -Mode plan -Model sonnet 6>&1 | Out-String -Width 400)
    $cnWhat = (chatq -New $newDir -Prompt 'x' -WhatIf 6>&1 | Out-String -Width 400)
    $cnModel = (chatq -New $newDir -Prompt 'x' -Model 'sonnet "4"' 6>&1 | Out-String -Width 400)
}
finally { ${function:Start-ChatqWatcher} = $cnWatch }
$cnJobs = @(Get-ChatqJobs | Where-Object { $_.kind -eq 'new' -and $_.title -eq 'Parser rewrite' })
$cn = $cnJobs[0]
Check 'chatq -New queues a new chat''s first prompt: named, in the mode and on the model given' (
    $cnJobs.Count -eq 1 -and $cn.cwd -eq $newDir -and $cn.mode -eq 'plan' -and $cn.runModel -eq 'sonnet' -and $cn.sessionId -match '^[0-9a-f-]{36}$' -and
    (Read-ChatqPrompt $cn) -eq 'plan the rewrite first' -and $cnSaid -match "queued #$($cn.seq) " -and $cnSaid -like "*plan (given)*$newDir*" -and
    $cnWhat -like "*(as a new chat starts)*$newDir*-WhatIf: nothing queued*") "$cnSaid / $cnWhat"
Check 'chatq -New refuses a model holding a quote, and queues nothing' (
    $cnModel -like "*-Model 'sonnet ""4""': a model's name holds no space, quote or %*" -and
    @(Get-ChatqJobs).Count -eq $cnBefore + 1) "$cnModel"
# the console's chips change a waiting job's mode and model through here
$raNo = Set-ChatqJobRunAs $cn 'model' 'opus 4'
$raMode = Set-ChatqJobRunAs $cn 'mode' 'acceptEdits'
$raBack = Set-ChatqJobRunAs $cn 'model' ''
$cnNow = Find-ChatqJob $cn.id -Exact
$cxJob = [pscustomobject]@{ seq = 99; state = 'queued'; provider = 'codex'; title = 'x' }
$doneJob = [pscustomobject]@{ seq = 98; state = 'done'; provider = 'claude'; title = 'x' }
Check 'a waiting Claude job''s mode and model change and are kept; a Claude mode for a Codex job, one already sent and a model with a space are refused' (
    $raNo -like "*a model's name holds no space*" -and -not $raMode -and -not $raBack -and $cnNow.mode -eq 'acceptEdits' -and -not $cnNow.runModel -and
    (Set-ChatqJobRunAs $cxJob 'mode' 'plan') -like '*Codex*' -and (Set-ChatqJobRunAs $doneJob 'mode' 'plan') -like '#98 is done*') "$raNo / $raMode / $($cnNow.mode) $($cnNow.runModel)"
foreach ($x in $cnJobs) { $null = Remove-ChatqJob $x 'test' }
# chatq -New without -Prompt: the editor tab, its slot taken for the tab
# and given up once read - the job takes a number of its own, and a tab
# left empty queues nothing and holds none. With -Attach the file goes into
# the job's folder by its own name; -Paste's text goes under the prompt given.
$cnEdFn = ${function:Invoke-ChatqEditor}
$script:CnEdSaw = [System.Collections.Generic.List[object]]::new()
$script:CnEdSay = 'written in the tab'
$cnEdBefore = @(Get-ChildItem -LiteralPath $script:ChatqQueueDir -Directory -EA SilentlyContinue | ForEach-Object FullName)
$cnAtt = Join-Path $sb 'new-chat-notes.txt'
[System.IO.File]::WriteAllText($cnAtt, 'the notes', $utf8)
${function:Start-ChatqWatcher} = { param([string]$Wake) $true }
${function:Invoke-ChatqEditor} = {
    param([string]$Path, [switch]$NoWait)
    $noBom = New-Object System.Text.UTF8Encoding $false
    $script:CnEdSaw.Add([pscustomobject]@{ Path = $Path; Was = (Test-Path -LiteralPath $Path)
            Dirs = @(Get-ChildItem -LiteralPath $script:ChatqQueueDir -Directory | ForEach-Object FullName) })
    [System.IO.File]::WriteAllText($Path, [System.IO.File]::ReadAllText($Path, $noBom) + $script:CnEdSay, $noBom)
}
try {
    $cnEdOut = (chatq -New $newDir 'Edited first' -Mode plan 6>&1 | Out-String -Width 400)
    $script:CnEdSay = ''
    $cnEdNo = (chatq -New $newDir 'Never queued' 6>&1 | Out-String -Width 400)
    $cnAttOut = (chatq -New $newDir 'With a file' -Prompt 'read the notes' -Attach $cnAtt 6>&1 | Out-String -Width 400)
    $script:ChatqClipboardSeam = { [pscustomobject]@{ Image = $null; Files = @(); Text = 'from the clipboard' } }
    $cnEdCalls = $script:CnEdSaw.Count
    $null = (chatq -New $newDir 'Pasted under' -Prompt 'look:' -Paste 6>&1 | Out-String -Width 400)
    $cnEdAfter = $script:CnEdSaw.Count
}
finally { ${function:Invoke-ChatqEditor} = $cnEdFn; ${function:Start-ChatqWatcher} = $cnWatch; $script:ChatqClipboardSeam = $null }
$cnBy = { param($t) @(Get-ChatqJobs | Where-Object { $_.kind -eq 'new' -and $_.title -eq $t }) }
$cnSeqOf = { param($p) if ((Split-Path $p -Leaf) -match '^#(\d+) ') { [int]$Matches[1] } else { -1 } }
# @() at each call: a scriptblock's one-job array comes back unrolled, and
# a lone [pscustomobject] has no .Count in Windows PowerShell 5.1
$cnEd = @(& $cnBy 'Edited first')
$cnS1 = $script:CnEdSaw[0]; $cnS2 = $script:CnEdSaw[1]
$cnD1 = @($cnS1.Dirs | Where-Object { $_ -notin $cnEdBefore })
$cnD2 = @($cnS2.Dirs | Where-Object { $_ -notin $cnEdBefore -and $_ -notin $cnD1 -and $_ -ne (Join-Path $script:ChatqQueueDir $cnEd[0].id) })
# the job takes the slot's number back, and with the same name its prompt
# file is the slot's path again: one file holds that number, the job's
$cnHold = @(Get-ChildItem -LiteralPath $script:ChatqQueueDir -File -Filter "#$($cnEd[0].seq) *" -EA SilentlyContinue)
Check 'chatq -New with no -Prompt opens the editor on a slot of its own, and queues what was written there; the slot''s folder is gone, its number the job''s alone, and no file is said missed' (
    $cnEd.Count -eq 1 -and (Read-ChatqPrompt $cnEd[0]) -eq 'written in the tab' -and $cnEd[0].mode -eq 'plan' -and $cnS1.Was -and $cnD1.Count -eq 1 -and
    $cnHold.Count -eq 1 -and -not (Test-Path -LiteralPath $cnD1[0]) -and $cnEd[0].seq -eq (& $cnSeqOf $cnS1.Path) -and
    $cnEdOut -match "queued #$($cnEd[0].seq) " -and $cnEdOut -notlike '*could not take in*') "$($cnEd.Count) $($cnEd.seq) [$(Read-ChatqPrompt $cnEd[0])] $($cnEd[0].mode) $($cnS1.Was) $(($cnHold | ForEach-Object Name) -join ',') $($cnD1 -join ',') | $cnEdOut"
$cnAj = @(& $cnBy 'With a file')
Check 'a tab left empty queues nothing: its slot''s file and folder go, and the next job takes the number it held' (
    -not @(& $cnBy 'Never queued').Count -and $cnEdNo -like '*cancelled - nothing queued*' -and -not (Test-Path -LiteralPath $cnS2.Path) -and $cnD2.Count -eq 1 -and
    -not (Test-Path -LiteralPath $cnD2[0]) -and $cnAj.Count -eq 1 -and $cnAj[0].seq -eq (& $cnSeqOf $cnS2.Path)) "$cnEdNo | $($cnS2.Path) $($cnD2 -join ',') | $($cnAj.seq)"
$cnPu = @(& $cnBy 'Pasted under')
Check 'chatq -New -Attach keeps the file''s name in the job''s folder; -Paste''s text goes under -Prompt, the editor never opened' (
    $cnAj.Count -eq 1 -and @(Get-ChatqAttachments $cnAj[0]).Count -eq 1 -and @(Get-ChatqAttachments $cnAj[0])[0].Name -eq 'new-chat-notes.txt' -and
    (Read-ChatqPrompt $cnAj[0]) -eq 'read the notes' -and $cnPu.Count -eq 1 -and (Read-ChatqPrompt $cnPu[0]) -eq "look:`n`nfrom the clipboard" -and
    $cnEdCalls -eq 2 -and $cnEdAfter -eq 2) "$cnAttOut | $($cnPu.Count) $cnEdCalls $cnEdAfter"
foreach ($x in @($cnEd) + @($cnAj) + @($cnPu)) { if ($x) { $null = Remove-ChatqJob $x 'test' } }

# a job whose -Model cmd.exe cannot carry - queued before New-ChatqJob
# refused one, or its file edited by hand. The run fails with that said,
# its own --settings file and the permit's folder gone, no process
# started; the probe says Refused, and the watcher fails the job rather
# than block its lane. The chat's own model is only named to the probe,
# which then asks without it.
$crJ = New-TestJob 'card redesign' 'never sent'
Set-ChatqProp $crJ 'runModel' 'sonnet "4"'
Save-ChatqJob $crJ
$crProcFn = ${function:Invoke-ChatqProcess}
$script:CrSaw = [System.Collections.Generic.List[string]]::new()
${function:Invoke-ChatqProcess} = {
    param([string]$Exe, [string[]]$ArgList, [string]$WorkDir, [string]$StdIn, [hashtable]$SetEnv, [string]$LogPath, [scriptblock]$OnLine, [scriptblock]$OnTick, [int]$TimeoutSec = 14400)
    $script:CrSaw.Add($ArgList -join ' ')
    throw 'cr: a process started'
}
try {
    $crOwn = Join-Path $script:ChatqRunSettingsDir "$($crJ.id).json"
    $crR1 = Invoke-ChatqRun $crJ 'x' $null $null -Carry ([pscustomobject]@{ Ultracode = $true; Effort = $null })
    $crOwnLeft = Test-Path -LiteralPath $crOwn
    $crPermit = New-ChatqPermitRun $crJ
    $crPermitWas = Test-Path -LiteralPath $crPermit.Dir
    $crR2 = Invoke-ChatqRun $crJ 'x' $null $null -Permit $crPermit -Carry ([pscustomobject]@{ Ultracode = $false; Effort = $null })
    $crCx = [pscustomobject]@{ id = 'cr-codex'; seq = 0; provider = 'codex'; kind = 'prompt'; sessionId = 'cr-thread'; cwd = $sb; home = $codexHome; title = 'x'; runModel = 'o3 "x"' }
    $crR3 = Invoke-ChatqRun $crCx 'x' $null $null
    $crP1 = Invoke-ChatqProbe 'claude' $crJ
    $crP2 = Invoke-ChatqProbe 'codex' $crCx
    $crSawBefore = $script:CrSaw.Count
    $crOwnModel = [pscustomobject]@{ id = 'cr-own'; seq = 0; provider = 'claude'; kind = 'prompt'; sessionId = $idCard; cwd = $sb; home = $claudeHome; title = 'x'; model = 'claude "old"' }
    $crP3 = try { $null = Invoke-ChatqProbe 'claude' $crOwnModel; 'no throw' } catch { $_.Exception.Message }
    $crCxOwn = [pscustomobject]@{ id = 'cr-codex-own'; seq = 0; provider = 'codex'; kind = 'prompt'; sessionId = 'cr-thread'; cwd = $sb; home = $codexHome; title = 'x'; model = 'gpt "old"'; runModel = $null }
    $crP4 = try { $null = Invoke-ChatqProbe 'codex' $crCxOwn; 'no throw' } catch { $_.Exception.Message }
    $crW = New-ChatqWatchState
    $crLane = Get-ChatqLane $crJ
    $crOk = Confirm-ChatqAllowed $crW (Find-ChatqJob $crJ.id -Exact)
}
finally { ${function:Invoke-ChatqProcess} = $crProcFn }
$crNow = Find-ChatqJob $crJ.id -Exact
Check 'a run whose -Model cmd.exe cannot carry fails with that said, no process started: its own settings file and the permit''s folder gone; a Codex run the same' (
    $crR1.kind -eq 'failed' -and $crR1.reason -like 'fake-claude.cmd runs through cmd.exe, which cannot be handed a quote - not sent: *' -and -not $crOwnLeft -and
    $crPermitWas -and -not (Test-Path -LiteralPath $crPermit.Dir) -and $crR2.kind -eq 'failed' -and $crR3.kind -eq 'failed' -and $crR3.reason -like '*cannot be handed a quote*' -and
    $crSawBefore -eq 0) "$($crR1.reason) | $crOwnLeft $crPermitWas | $($crR2.kind) | $($crR3.reason) | $($script:CrSaw -join ' // ')"
Check 'the probe says Refused for such a -Model, starting nothing; a chat''s own model it cannot carry is asked without' (
    $crP1.Refused -and -not $crP1.Allowed -and $crP1.Error -like '*cannot be handed a quote*' -and $crP2.Refused -and $crP2.Error -like '*cannot be handed a quote*' -and
    $crP3 -eq 'cr: a process started' -and $script:CrSaw.Count -eq 2 -and $script:CrSaw[0] -notlike '*--model*' -and
    $crP4 -eq 'cr: a process started' -and $script:CrSaw[1] -notlike '* -m *' -and $script:CrSaw[1] -like '*model_reasoning_effort=low*') "$($crP1.Error) | $($crP2.Error) | $crP3 | $crP4 | $($script:CrSaw -join ' // ')"
Check 'the watcher fails that job with the reason and leaves its lane open - not blocked, no probe miss counted' (
    -not $crOk -and $crNow.state -eq 'failed' -and $crNow.result.reason -like '*cannot be handed a quote*' -and -not $crW.blocked[$crLane] -and
    -not [int]$crW.probeFails[$crLane]) "$($crNow.state) $($crNow.result.reason) | $($crW.blocked[$crLane] | ConvertTo-Json -Compress)"
$null = Remove-ChatqJob $crNow 'test'

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
# a claude -p as Claude Code 2.1.283 registers it: interactive, sdk-cli
$lR5c = Repair-ChatListed -Path $lBusy -SessionId 'sid-busy' -Live @([pscustomobject]@{ SessionId = 'sid-busy'; Status = 'idle'; Kind = 'interactive'; Entrypoint = 'sdk-cli' })
$lR6 = Repair-ChatListed -Path $lIdle -SessionId 'sid-idle' -Live @([pscustomobject]@{ SessionId = 'sid-idle'; Status = 'idle'; Kind = 'interactive' })
$lR7 = Repair-ChatListed -Path (Join-Path $lDir 'gone.jsonl') -SessionId 'sid-gone'
Check 'its last line lacking its end: the new one on a line of its own; hidden by its head: unlistable, untouched; a process busy in it, or a print-mode run - by its kind or its sdk-cli entrypoint: held; one idle: mended; no file: nothing made' (
    $lR3 -eq 'relisted' -and $cutOk -and $lR4 -eq 'unlistable' -and [System.IO.File]::ReadAllText($lHead, $utf8) -eq ((& $epl 'sdk-cli') + (& $epl 'sdk-cli')) -and
    $lR5 -eq 'held' -and $lR5b -eq 'held' -and $lR5c -eq 'held' -and [System.IO.File]::ReadAllText($lBusy, $utf8) -eq $hidText -and $lR6 -eq 'relisted' -and
    $lR7 -eq 'unknown' -and -not (Test-Path -LiteralPath (Join-Path $lDir 'gone.jsonl'))) "$lR3 $cutOk $lR4 $lR5 $lR5b $lR5c $lR6 $lR7"
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
