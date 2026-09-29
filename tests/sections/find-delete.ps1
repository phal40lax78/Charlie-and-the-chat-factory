# tests/sections/find-delete.ps1: dot-sourced by tests/run-tests.ps1 in its turn,
# never on its own - it uses what the runner and the sections before it set.

Section 'find and delete'
$rows = @(Sync-ChatIndex)
$provs = (@($rows | ForEach-Object Provider | Sort-Object -Unique)) -join ','
Check 'the index holds all three providers' ($provs -eq 'claude,codex,copilot') $provs
$hr = @($rows | Where-Object { $_.Id -eq $cx2Id })
Check 'a Hangul Codex thread name is read as UTF-8' ($hr.Count -eq 1 -and $hr[0].Title -eq $tHan) "$($hr.Title)"
$qr = @($rows | Where-Object { $_.Id -eq $idQuote })
Check 'an escaped Claude title comes back unescaped' ($qr.Count -eq 1 -and $qr[0].Title -eq 'Say "hi" to it') "$($qr.Title)"
$f = @(chatfind 'Doomed chat one')
Check 'chatfind by title' ($f.Count -eq 1 -and $f[0].Id -eq $idDoom1) $f.Count
$f = @(chatfind 'unique prompt phrase zebra')
Check 'chatfind by prompt text' ($f.Count -eq 1 -and $f[0].Id -eq $idDoom1) $f.Count
Check 'text past the previews is left to -Deep' (@(chatfind 'needle-deep-xyz').Count -eq 0 -and @(chatfind 'needle-deep-xyz' -Deep).Count -eq 1)
# a reader holds the index a moment, without delete sharing, as a console's
# read does: the swap waits it out rather than keeping the old index
$held = [System.Threading.ManualResetEventSlim]::new($false)
$ps = [powershell]::Create().AddScript({
        param($Path, $Held)
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        $Held.Set()
        Start-Sleep -Milliseconds 150
        $fs.Dispose()
    }).AddArgument($script:ChatIndexPath).AddArgument($held)
$hIdx = $ps.BeginInvoke()
$null = $held.Wait(5000)
$before = @(Get-ChatIndex)
$extra = [pscustomobject]@{ Provider = 'claude'; Path = 'X:\held.jsonl'; Size = 1; Mtime = 1; Id = 'held-row'; Title = 'held'; Titled = 'ai'; Group = 'x'; Hidden = $false; When = (Get-Date).ToString('o'); First = @(); Last = @() }
$warn = Save-ChatIndex @($before + $extra) 3>&1 | Out-String -Width 400
$ps.EndInvoke($hIdx); $ps.Dispose()
Check 'the index is saved even while a reader holds it a moment' (@(Get-ChatIndex | Where-Object { $_.Id -eq 'held-row' }).Count -eq 1 -and -not $warn.Trim()) $warn
Save-ChatIndex $before
$fh = [System.IO.File]::Open($script:ChatIndexPath, 'Open', 'Read', 'ReadWrite')
try { $warn = Save-ChatIndex @($before + $extra) 3>&1 | Out-String -Width 400 } finally { $fh.Dispose() }
Check 'a hold that outlasts the tries says so, never silently' ($warn -like '*chat index was not saved*' -and -not @(Get-ChatIndex | Where-Object { $_.Id -eq 'held-row' })) $warn

chatrm 'Doomed chat one' -Force -NoWait *> $null
Check 'chatrm -Force removes the transcript and its leftovers' (-not (Test-Path -LiteralPath $pDoom1) -and -not (Test-Path -LiteralPath $side) -and
    -not (Test-Path -LiteralPath (Join-Path $claudeHome "file-history\$idDoom1")) -and -not (Test-Path -LiteralPath (Join-Path $claudeHome "session-env\$idDoom1")))
$tomb = if (Test-Path -LiteralPath $script:ChatTombPath) { [System.IO.File]::ReadAllText($script:ChatTombPath, $utf8) } else { '' }
Check 'a tombstone is written and the row leaves the index' ($tomb -like "*$idDoom1*" -and -not @(Get-ChatIndex | Where-Object { $_.Id -eq $idDoom1 }))
$gone = @('Debug', 'Tasks', 'Sec', 'SecLock', 'Tele', 'Todo', 'Plan', 'PlanAgent' | Where-Object { Test-Path -LiteralPath $left[$_] })
Check 'and every other leftover: debug, tasks, security, telemetry, todos, plans' (-not $gone) ($gone -join ',')
Check 'a background job folder goes by the id inside it' (-not (Test-Path -LiteralPath (Split-Path $left.Job -Parent)))

$j = New-TestJob 'Doomed chat two' 'keep me'
chatrm 'Doomed chat two' -Force -NoWait *> $null
Check 'a chat with a prompt queued for it is kept' ((Test-Path -LiteralPath $pDoom2) -and (Find-ChatqJob $j.id))
chatrm 'Doomed chat two' -Force -DropJobs -NoWait *> $null
Check '-DropJobs drops the prompt, then deletes' (-not (Test-Path -LiteralPath $pDoom2) -and -not (Find-ChatqJob $j.id))
Check 'a plan file another chat in the project shares is kept' (Test-Path -LiteralPath $left.Shared)

# held open without delete sharing, as a live window holds it: nothing goes
$fh = [System.IO.File]::Open($pLock, 'Open', 'Read', 'Read')
try { chatrm 'Locked open chat' -Force -NoWait *> $null } finally { $fh.Dispose() }
Check 'a locked transcript keeps its leftovers' ((Test-Path -LiteralPath $pLock) -and (Test-Path -LiteralPath $lockHist))

# the overlay's delete chip: one chat by its id, kept while it works or a
# terminal has it, and said in one sentence either way
$idRm = 'e1e1e1e1-0000-4000-8000-0000000000e1'
$pRm = New-FakeChat $projA $idRm 'Chip delete chat' 1 @('bye now')
$rmLive = { param($st, $ep) @([pscustomobject]@{ SessionId = $idRm; Status = $st; Entrypoint = $ep; Kind = 'interactive' }) }
$rmBusy = Remove-ChatSessionById $idRm $projA 'Chip delete chat' $claudeHome (& $rmLive 'busy' 'claude-vscode')
$rmTerm = Remove-ChatSessionById $idRm $projA 'Chip delete chat' $claudeHome (& $rmLive 'idle' 'cli')
# a queued run: claude -p, which 2.1.283 registers interactive, idle or busy
$rmRun = Remove-ChatSessionById $idRm $projA 'Chip delete chat' $claudeHome (& $rmLive 'idle' 'sdk-cli')
$rmRunB = Remove-ChatSessionById $idRm $projA 'Chip delete chat' $claudeHome (& $rmLive 'busy' 'sdk-ts')
Check 'the delete chip on a chat a queued prompt is running in: kept, in those words - not a terminal''s' (
    -not $rmRun.Done -and $rmRun.Say -eq '"Chip delete chat" has a queued prompt running in it - delete it once that ends.' -and
    -not $rmRunB.Done -and $rmRunB.Say -eq $rmRun.Say) "$($rmRun.Say) | $($rmRunB.Say)"
$rmKept = Test-Path -LiteralPath $pRm
$rmOk = Remove-ChatSessionById $idRm $projA 'Chip delete chat' $claudeHome (& $rmLive 'idle' 'claude-vscode')
$rmTwice = Remove-ChatSessionById $idRm $projA 'Chip delete chat' $claudeHome @()
Check 'the delete chip: kept while working or in a terminal; else deleted, row and all; then not on disk' (
    -not $rmBusy.Done -and $rmBusy.Say -eq '"Chip delete chat" is working - delete it once it finishes.' -and
    -not $rmTerm.Done -and $rmTerm.Say -like '*open in a terminal*' -and $rmKept -and
    $rmOk.Done -and $rmOk.Say -eq 'Deleted "Chip delete chat".' -and -not (Test-Path -LiteralPath $pRm) -and -not @(Get-ChatIndex | Where-Object { $_.Id -eq $idRm }) -and
    -not $rmTwice.Done -and $rmTwice.Say -like '*not on disk*') "$($rmBusy.Say) | $($rmTerm.Say) | $($rmOk.Say) | $($rmTwice.Say)"

$r = Resolve-ChatqTarget 'Copilot chat about tests'
Check 'a Copilot chat is named, then refused' ($r.Error -like '*Copilot*') $r.Error
$r = Resolve-ChatqTarget 'zzqx nothing like it'
Check 'a guess is never a Copilot chat' ($r.Row -and $r.Row.Provider -ne 'copilot') "$($r.Row.Provider)"

function Complete([string]$Cmd, [string]$Param, [string]$Word, [hashtable]$Bound = @{}) {
    @(& $script:ChatTitleCompleter $Cmd $Param $Word $null $Bound)
}
Check 'chatq <digits> completes nothing' ((Complete 'chatq' 'Target' '3').Count -eq 0)
Check 'chatq never offers a Copilot chat' (-not @(Complete 'chatq' 'Target' 'Copilot' | Where-Object { $_.CompletionText -like '*Copilot*' }))
Check 'chatrm does' (@(Complete 'chatrm' 'Target' 'Copilot' | Where-Object { $_.CompletionText -like '*Copilot chat*' }).Count -eq 1)
Check 'a subagent chat is not offered' ((Complete 'chatrm' 'Target' 'Hidden sub').Count -eq 0)
Check '... unless -All is given' ((Complete 'chatfind' 'Text' 'Hidden sub' @{ All = $true }).Count -eq 1)
Check 'hex completes an id' (@(Complete 'chatrm' 'Target' '2222')[0].CompletionText -eq $idCard)
Check 'a title that looks like hex still completes' (@(Complete 'chatrm' 'Target' 'dead')[0].CompletionText -eq "'Deadline notes'")
$sq = @(Complete 'chatq' 'Target' 'Don')[0].CompletionText
$sqOk = try { (& ([scriptblock]::Create($sq))) -eq $tSmart } catch { $false }
Check 'a typographic apostrophe is quoted so it survives' $sqOk $sq
$byId = $false
Check 'Tab cycling skips a subagent chat' (@(Get-ChatCycleRows 'Hidden sub' ([ref]$byId)).Count -eq 0)
Check 'chatq cycling skips Copilot, chatrm cycling does not' (@(Get-ChatCycleRows 'Copilot' ([ref]$byId) -Queue).Count -eq 0 -and @(Get-ChatCycleRows 'Copilot' ([ref]$byId)).Count -eq 1)
Check 'a tail left mid-line comes off a chatq line' (("chatq 'Parser rewrite' (1h) #1/2 -Prompt 'x'" -replace $script:ChatMidTailPattern, '') -eq "chatq 'Parser rewrite' -Prompt 'x'")
Check 'a zero-width cell is empty, not an error' ((Format-ChatCell 'abc' 0) -eq '' -and (Format-ChatCell 'abcdef' 2) -eq '..')
Start-ChatGhostWatch
Check 'no ghost watch inside the background watcher' (-not (Test-ChatGhostWatch))

# one profile line for both halves, and uninstall takes only that
$PROFILE = Join-Path $sb 'profile.ps1'
[System.IO.File]::WriteAllLines($PROFILE, [string[]]@('. "C:\x\chatrm\chatrm.ps1"', 'Set-Alias foo bar', '. "C:\x\chatq\chatq.ps1"', '. "C:\x\VS-code-chat-manager\VS-code-chat-manager.ps1"', '. "C:\x\claude-codex-chat-manager\claude-codex-chat-manager.ps1"'))
$lineBefore = Test-ChatProfileLine
# the watcher and overlay restart counted, not done: none runs here
$rcWas = ${function:Restart-ChatBackground}
$script:RestartCalls = 0
${function:Restart-ChatBackground} = { $script:RestartCalls++ }
chatinstall *> $null
$lineAfter = Test-ChatProfileLine
chatinstall -NoRestart *> $null
${function:Restart-ChatBackground} = $rcWas
$pl = @(Get-Content -LiteralPath $PROFILE)
$me = Join-Path $sb 'tool\Charlie-and-the-chat-factory.ps1'
Check 'one install line replaces chatrm''s, chatq''s and the loader''s under both its old names' (@($pl | Where-Object { $_ -match $script:ChatProfilePattern }).Count -eq 1 -and
    ($pl -join "`n").Contains($me) -and $pl -contains 'Set-Alias foo bar') ($pl -join ' | ')
Check 'chatinstall moves a running watcher and overlay to this copy; -NoRestart, for the extension, leaves them' ($script:RestartCalls -eq 1) $script:RestartCalls
chatuninstall *> $null
$pl = @(Get-Content -LiteralPath $PROFILE)
Check 'uninstall leaves the rest of the profile alone' ($pl.Count -eq 1 -and $pl[0] -eq 'Set-Alias foo bar') ($pl -join ' | ')
Check 'Test-ChatProfileLine: only a line loading this copy counts, not an old tool''s' (-not $lineBefore -and $lineAfter -and -not (Test-ChatProfileLine)) "$lineBefore $lineAfter"

# StrictMode again, the way a real shell loads it: not as the watcher, with no
# queue at all yet, and a stop on the first error
$sb2 = Join-Path $sb 'strict2'
$null = New-Item -ItemType Directory -Path $sb2 -Force
Copy-Item -LiteralPath (Join-Path $root 'Charlie-and-the-chat-factory.ps1') -Destination $sb2
Copy-Item -LiteralPath (Join-Path $root 'src') -Destination $sb2 -Recurse
# the overlay starts with a shell by default now: off here, or this probe
# would put a real panel on the screen - the shell-start path still runs
$null = New-Item -ItemType Directory -Path (Join-Path $sb2 'data') -Force
[System.IO.File]::WriteAllText((Join-Path $sb2 'data\config.json'), '{"overlay":{"autoStart":false}}', $utf8)
$probe2 = "Remove-Item env:CHATQ_WATCHER -EA SilentlyContinue; Set-StrictMode -Version Latest; `$ErrorActionPreference = 'Stop'; try { . '$(Join-Path $sb2 'Charlie-and-the-chat-factory.ps1')'; Set-Location -LiteralPath '$projA'; chatfind Doomed *> `$null; chatindex *> `$null; `$r = & `$script:ChatTitleCompleter 'chatrm' 'Target' 'Pars' `$null @{}; chatqlist *> `$null; chat *> `$null; chatoverlay -Print *> `$null; 'ok' } catch { 'threw: ' + `$_.Exception.Message + ' ' + `$_.InvocationInfo.PositionMessage }"
$strict2 = (& $exe -NoProfile -NonInteractive -Command $probe2 | Select-Object -Last 1)
Check 'loads and runs under StrictMode as a normal shell does' ($strict2 -eq 'ok') $strict2
# the script copied without its src/: it names what is missing and defines
# nothing, rather than half the commands failing later
$sb3 = Join-Path $sb 'nosrc'
$null = New-Item -ItemType Directory -Path $sb3 -Force
Copy-Item -LiteralPath (Join-Path $root 'Charlie-and-the-chat-factory.ps1') -Destination $sb3
$probe3 = "Remove-Item env:CHATQ_WATCHER -EA SilentlyContinue; Set-StrictMode -Version Latest; . '$(Join-Path $sb3 'Charlie-and-the-chat-factory.ps1')'; 'defined: ' + [bool](Get-Command chatq -EA SilentlyContinue)"
$nosrc = @(& $exe -NoProfile -NonInteractive -Command $probe3 *>&1 | ForEach-Object { "$_" })
Check 'without src/ it names the missing parts and defines no command' (($nosrc -join ' ') -like '*missing from*core.ps1*overlay.ps1*' -and $nosrc[-1] -eq 'defined: False') ($nosrc -join ' | ')

function Get-AlertCount([string]$Like) {
    $f = Join-Path $script:ChatqLogDir 'alerts.log'
    if (-not (Test-Path -LiteralPath $f)) { return 0 }
    @([System.IO.File]::ReadAllLines($f, $utf8) | Where-Object { $_ -like $Like }).Count
}
function Lock-Queue([scriptblock]$Do) {
    # a held lock is what a running watcher looks like: chatq queues, starts none
    New-ChatqDir $script:ChatqData
    $lk = [System.IO.File]::Open($script:ChatqLockPath, 'OpenOrCreate', 'ReadWrite', 'None')
    try { & $Do } finally { $lk.Dispose() }
}
