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
# read does: the swap waits it out rather than keeping the old index. Held
# until the save has written its .tmp and closed it - an open that shares no
# writing fails till then, however long the rows take - and 200 ms past: the
# first swap, moments after the close, meets the hold, and the fifth, 400 ms
# after the first, finds it gone. .NET calls only, no command to look up
Remove-Item -LiteralPath "$($script:ChatIndexPath).tmp" -Force -EA SilentlyContinue
$held = [System.Threading.ManualResetEventSlim]::new($false)
$ps = [powershell]::Create().AddScript({
        param($Path, $Held)
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        $Held.Set()
        for ($i = 0; $i -lt 250; $i++) {
            try { [System.IO.File]::Open("$Path.tmp", 'Open', 'Read', 'Read').Dispose(); break } catch { [System.Threading.Thread]::Sleep(20) }
        }
        [System.Threading.Thread]::Sleep(200)
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

# one profile line for both halves, and uninstall takes only that. The run's
# own $PROFILE from here on, so neither half can touch the real one -
# Set-Variable, as the analyzer reads a plain = as clobbering an automatic
Set-Variable -Name PROFILE -Value (Join-Path $sb 'profile.ps1')
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
$probe2 = "Remove-Item env:CHATQ_WATCHER, env:CHATQ_ALLPARTS -EA SilentlyContinue; Set-StrictMode -Version Latest; `$ErrorActionPreference = 'Stop'; try { . '$(Join-Path $sb2 'Charlie-and-the-chat-factory.ps1')'; Set-Location -LiteralPath '$projA'; chatfind Doomed *> `$null; chatindex *> `$null; `$r = & `$script:ChatTitleCompleter 'chatrm' 'Target' 'Pars' `$null @{}; chatqlist *> `$null; chat *> `$null; chatoverlay -Print *> `$null; 'ok' } catch { 'threw: ' + `$_.Exception.Message + ' ' + `$_.InvocationInfo.PositionMessage }"
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

# A shell's load leaves out the overlay's three parts, so nothing a shell
# runs may call into them. Every call from the rest into them is one of
# these, each looked at: auto-continue's, which only the overlay's process
# runs, the phone setup's window, whose launch sets CHATQ_ALLPARTS, and the
# Mac host's stand-in, which calls the Windows host's - both defined only
# where the three are left out. And
# whatever reaches them is called from inside them, or is that window, and
# never at a part's top level. A new one is a new path to look at.
$gtRoot = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Charlie-and-the-chat-factory.ps1'), [ref]$null, [ref]$null)
$gtParts = @($gtRoot.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$chatParts' }, $true).Right.FindAll(
        { param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { $_.Value })
$gtGated = 'overlay-windows', 'console', 'overlay-mac'
$gtAst = @{ '(root)' = $gtRoot }
$gtDefs = @{}
foreach ($p in $gtParts) {
    $gtAst[$p] = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root "src\$p.ps1"), [ref]$null, [ref]$null)
    foreach ($f in $gtAst[$p].FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $gtDefs[$f.Name] = $p }
}
# every call outside the three parts, with the function it is in - none at a top level
$gtCalls = @(foreach ($k in @($gtAst.Keys | Where-Object { $_ -notin $gtGated })) {
        foreach ($c in $gtAst[$k].FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $to = $c.GetCommandName()
            if (-not $to) { continue }
            $f = $c.Parent
            while ($f -and $f -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $f = $f.Parent }
            [pscustomobject]@{ From = $(if ($f) { $f.Name } else { '' }); To = $to }
        }
    })
$gtIn = { param($n) $gtDefs.ContainsKey($n) -and $gtDefs[$n] -in $gtGated }
$gtBridges = @($gtCalls | Where-Object { $_.From -and (& $gtIn $_.To) } | ForEach-Object { "$($_.From)>$($_.To)" } | Sort-Object -Unique) -join ','
# what reaches them: those calls' functions, then their callers until none is new
$gtReach = @{}
foreach ($c in $gtCalls) { if ($c.From -and (& $gtIn $c.To)) { $gtReach[$c.From] = $true } }
do {
    $gtNew = 0
    foreach ($c in $gtCalls) { if ($c.From -and $gtReach.ContainsKey($c.To) -and -not $gtReach.ContainsKey($c.From)) { $gtReach[$c.From] = $true; $gtNew++ } }
} while ($gtNew)
$gtCalledIn = { param($n) @(foreach ($p in $gtGated) { $gtAst[$p].FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] -and $x.GetCommandName() -eq $n }, $true) }).Count -gt 0 }
$gtLoose = @($gtReach.Keys | Where-Object { $n = $_; -not @($gtCalls | Where-Object { $_.From -and $_.To -eq $n }).Count -and $n -ne 'Show-ChatqPhoneSetup' -and -not (& $gtCalledIn $n) })
$gtTop = @($gtCalls | Where-Object { -not $_.From -and ((& $gtIn $_.To) -or $gtReach.ContainsKey($_.To)) } | ForEach-Object { $_.To })
$gtWant = 'Add-ChatConsoleAutoLine>New-ChatConsoleChips,Add-ChatConsoleAutoLine>New-ChatOverlayText,Invoke-ChatConsoleDontContinue>Set-ChatConsoleStatus,' +
'Invoke-ChatConsoleDontContinue>Update-ChatConsoleNow,Invoke-ChatOverlayAutoChip>Hide-ChatOverlayChip,Invoke-ChatOverlayAutoChip>Show-ChatOverlayBalloon,' +
'New-ChatqPhoneSetupWindow>Get-ChatIconSource,Set-ChatConsoleAutoChat>Set-ChatConsoleStatus,Set-ChatConsoleAutoChat>Update-ChatConsoleNow,' +
'Set-ChatConsoleAutoChat>Update-ChatConsoleTarget,Show-ChatOverlayAutoNotice>Show-ChatOverlayBalloon,Show-ChatOverlayAutoQueued>Show-ChatOverlayBalloon,' +
'Start-ChatOverlayMacHost>Start-ChatOverlayHost'
Check 'a shell''s load leaves out the overlay''s parts: every call into them from the rest a known one, reached from inside them or from the phone setup''s window - launched with CHATQ_ALLPARTS - and none at a top level' (
    $gtBridges -eq $gtWant -and -not $gtLoose.Count -and -not $gtTop.Count -and $gtReach.ContainsKey('Show-ChatqPhoneSetup') -and
    (Get-ChatqPhoneSetupLaunch).Command -like "*CHATQ_ALLPARTS='1'*Show-ChatqPhoneSetup*") "$($gtParts.Count) / $gtBridges / loose $($gtLoose -join ',') / top $($gtTop -join ',')"
# and the load itself, in a process of its own: a shell's without them, but
# with chatoverlay and chatconsole - which start or tell the overlay's own
# process - and the console's folders the phone's board reads; the same
# with CHATQ_OVERLAY, the guard of every process the overlay starts and of
# the question hook; CHATQ_ALLPARTS loads them all
$gtLoad = {
    param([string]$Set)
    Invoke-Sta 'gate-load' @"
Remove-Item env:CHATQ_OVERLAY, env:CHATQ_ALLPARTS -EA SilentlyContinue
$Set
. '$(Join-Path $sb 'tool\Charlie-and-the-chat-factory.ps1')'
((@('Start-ChatOverlayHost', 'Enter-ChatOverlayConsoleMode', 'Start-ChatOverlayMacHost', 'Get-ChatIconSource', 'chatoverlay', 'chatconsole', 'Get-ChatOverlayLaunch', 'Write-ChatOverlayPrint') | ForEach-Object { [int][bool](Get-Command `$_ -CommandType Function -EA SilentlyContinue) }) -join '') + '|' + [bool]`$script:ChatConsoleStatePath
"@
}
$gtPlain = & $gtLoad ''
$gtOverlay = & $gtLoad "`$env:CHATQ_OVERLAY = '1'"
$gtAll = & $gtLoad "`$env:CHATQ_ALLPARTS = '1'"
Check 'a shell''s load: the panel''s, the console''s and the Mac''s parts left out, chatoverlay, chatconsole and the console''s folders kept - with CHATQ_OVERLAY too, but for stand-ins of the two hosts; CHATQ_ALLPARTS loads them all' (
    $gtPlain -eq '00001111|True' -and $gtOverlay -eq '10101111|True' -and $gtAll -eq '11111111|True') "$gtPlain $gtOverlay $gtAll"
# A copy from before the gate - an overlay restarting itself onto this one,
# a terminal opened before it - starts the overlay, and the phone setup's
# window, with CHATQ_OVERLAY alone and calls them by name: each is started
# again the way this copy starts it, its launch's CHATQ_ALLPARTS and all.
# Why the overlay's could not start is thrown, for the old launch's catch to
# log. The phone setup's waits for the window it started to hold the lock:
# its whole wait when none does - a second here, not 6 - and, given 10 s, back
# in under 5 once one does, a slow runner's stall and all.
$gtOld = Invoke-Sta 'gate-old' @"
Remove-Item env:CHATQ_OVERLAY, env:CHATQ_ALLPARTS -EA SilentlyContinue
`$env:CHATQ_OVERLAY = '1'
. '$(Join-Path $sb 'tool\Charlie-and-the-chat-factory.ps1')'
`$ChatqPhoneSetupWaitSec = 1
`$global:GtOld = @()
function Start-ChatOverlayProcess { param([string]`$Open = '') `$global:GtOld += "overlay:`$Open"; `$true }
function Start-ChatqPhoneSetup { param([switch]`$NoWait) `$global:GtOld += "phone:`$NoWait"; if (`$global:GtTake) { `$global:GtLock = Open-ChatqPhoneSetupLock }; `$true }
Start-ChatOverlayHost -Open console
Start-ChatOverlayHost
Start-ChatOverlayMacHost
function Start-ChatOverlayProcess { param([string]`$Open = '') Write-Host '  cannot start the overlay: no room' -ForegroundColor Yellow; `$false }
try { Start-ChatOverlayHost; `$global:GtOld += 'no throw' } catch { `$global:GtOld += "threw:`$(`$_.Exception.Message)" }
`$sw = [Diagnostics.Stopwatch]::StartNew()
Show-ChatqPhoneSetup
`$global:GtOld += "waited:`$(`$sw.ElapsedMilliseconds -ge 900)"
`$global:GtTake = `$true
`$ChatqPhoneSetupWaitSec = 10
`$sw.Restart()
Show-ChatqPhoneSetup
`$global:GtOld += "held:`$(`$sw.ElapsedMilliseconds -lt 5000)"
`$global:GtLock.Dispose()
`$global:GtOld -join ','
"@
Check 'an older copy''s launch of the overlay - console or not, Windows or Mac - or of the phone setup''s window, CHATQ_OVERLAY alone: started again from here, the way this copy starts it, why the overlay''s could not thrown, the window''s until the one it started holds the lock' (
    $gtOld -eq 'overlay:console,overlay:,overlay:,threw:cannot start the overlay: no room,phone:True,waited:True,phone:True,held:True') "$gtOld"
# The phone setup's window for real, from its launch and with a stand-in
# script, in a process that inherits no CHATQ_ALLPARTS: set as the script
# loads, and by the time the window shows gone with the guard and Bypass,
# so nothing the window starts - a watcher, by Pair phone - has any of them
if ($script:ChatqIsWindows) {
    $psStub = Join-Path $sb 'setup-stub.ps1'
    [IO.File]::WriteAllText($psStub, @'
$global:PsOut = Join-Path $PSScriptRoot 'setup-env.txt'
$global:PsAll = [string]$env:CHATQ_ALLPARTS
function Show-ChatqPhoneSetup { [IO.File]::WriteAllText($global:PsOut, (@($global:PsAll, $env:CHATQ_ALLPARTS, $env:CHATQ_OVERLAY, $env:PSExecutionPolicyPreference) -join '|')) }
'@, $utf8)
    $psOut = Join-Path $sb 'setup-env.txt'
    $psWas = $env:CHATQ_ALLPARTS
    Remove-Item env:CHATQ_ALLPARTS -EA SilentlyContinue
    try {
        $psL = Get-ChatqPhoneSetupLaunch $psStub
        $psP = Start-Process -FilePath $psL.Exe -ArgumentList $psL.Args -WindowStyle Hidden -PassThru
        if (-not $psP.WaitForExit(60000)) { try { $psP.Kill() } catch {} }
    }
    finally { $env:CHATQ_ALLPARTS = $psWas }
    $psEnv = try { [IO.File]::ReadAllText($psOut) } catch { 'nothing written' }
    Check 'the phone setup''s window loads every part - its launch sets CHATQ_ALLPARTS - and once loaded holds none of it, the guard or Bypass for what it starts' ($psEnv -eq '1|||') $psEnv
    Remove-Item -LiteralPath $psStub, $psOut -Force -EA SilentlyContinue
}

# A C# compile's working files in data/tmp, not TEMP: TEMP pointed for the
# compile at a folder of its own there, put back after and the folder gone,
# a compile that fails too; what a process killed mid-compile left there
# swept by the next compile a day on; a data/tmp csc cannot work in - too
# long, or a character this PC's code page lacks - left alone, TEMP with
# it. And every compile in src/ made so, each Add-Type given source inside
# an Invoke-ChatCompile.
$ctWas = $env:TMP, $env:TEMP
# a killed compile's folder two days old, csc's own folder and source in
# it, and one made a moment ago - another process's compile under way
$ctTmp = [System.IO.Path]::GetFullPath((Join-Path $script:ChatqData 'tmp'))
$ctKilled = Join-Path $ctTmp 'killedc1'
$null = [System.IO.Directory]::CreateDirectory((Join-Path $ctKilled 'abcdefgh'))
[System.IO.File]::WriteAllText((Join-Path $ctKilled 'abcdefgh\abcdefgh.0.cs'), 'class X {}')
[System.IO.Directory]::SetCreationTimeUtc($ctKilled, [datetime]::UtcNow.AddDays(-2))
$ctLive = [System.IO.Directory]::CreateDirectory((Join-Path $ctTmp 'livecmp1')).FullName
$script:CtSeen = @()
Invoke-ChatCompile { $script:CtSeen = [System.IO.Path]::GetTempPath(), $env:TMP, $env:TEMP; Add-Type -TypeDefinition 'public static class ChatqCompileProbe { public static int One() { return 1; } }' }
$ctSwept = -not [System.IO.Directory]::Exists($ctKilled) -and [System.IO.Directory]::Exists($ctLive)
if ([System.IO.Directory]::Exists($ctLive)) { [System.IO.Directory]::Delete($ctLive, $true) }
$ctBack = $env:TMP -eq $ctWas[0] -and $env:TEMP -eq $ctWas[1]
$script:CtFailed = ''
$ctThrew = try { Invoke-ChatCompile { $script:CtFailed = $env:TEMP; throw 'no compile' }; $false } catch { $true }
$ctBack = $ctBack -and $ctThrew -and $env:TMP -eq $ctWas[0] -and $env:TEMP -eq $ctWas[1]
$ctOwn = @($script:CtSeen | ForEach-Object { "$_".TrimEnd('\') } | Select-Object -Unique)
$ctOwn = $ctOwn.Count -eq 1 -and (Split-Path -Parent $ctOwn[0]) -eq $ctTmp -and -not [System.IO.Directory]::Exists($ctOwn[0]) -and
    (Split-Path -Parent $script:CtFailed) -eq $ctTmp -and $script:CtFailed -ne $ctOwn[0] -and -not [System.IO.Directory]::Exists($script:CtFailed)
# a compile's folder of 209 characters - one csc could still have worked
# in, so only the bound leaves it be - and a character outside this PC's
# code page, should it have one: Thai, an accent, an emoji (none under
# pwsh, whose code page is UTF-8, so that folder is left out, not $null)
$ctAnsi = [System.Text.Encoding]::Default
$ctOdd = @([string][char]0x0E01, [string][char]0x00E9, [char]::ConvertFromUtf32(0x1F600)) | Where-Object { $ctAnsi.GetString($ctAnsi.GetBytes($_)) -cne $_ } | Select-Object -First 1
$ctDataWas = $script:ChatqData
$ctStay = @(foreach ($ctDir in @(Join-Path $sb ('y' * [Math]::Max(2, 190 - $sb.Length))) + @(if ($ctOdd) { Join-Path $sb "x$ctOdd" })) {
        $script:ChatqData = Join-Path $ctDir 'data'
        $script:CtStayed = ''
        try { Invoke-ChatCompile { $script:CtStayed = $env:TEMP } } finally { $script:ChatqData = $ctDataWas }
        if ($script:CtStayed -ne $ctWas[1] -or [System.IO.Directory]::Exists($ctDir)) { $ctDir.Substring($sb.Length) }
    })
$ctLoose = @(foreach ($f in Get-ChildItem -LiteralPath (Join-Path $root 'src') -Filter '*.ps1') {
        $a = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
        foreach ($c in $a.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Add-Type' -and
                    @($n.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -in 'TypeDefinition', 'MemberDefinition' }).Count }, $true)) {
            $p = $c.Parent
            while ($p -and -not ($p -is [System.Management.Automation.Language.CommandAst] -and $p.GetCommandName() -eq 'Invoke-ChatCompile')) { $p = $p.Parent }
            if (-not $p) { "$($f.Name) $($c.Extent.StartLineNumber)" }
        }
    })
Check 'a C# compile''s files go in a folder of its own in data/tmp, gone after, TEMP put back - a failed compile''s too; a killed one''s left there a day ago swept, a young one kept; a data/tmp csc cannot work in left alone; every compile in src/ goes through it' (
    $ctOwn -and [ChatqCompileProbe]::One() -eq 1 -and $ctBack -and $ctSwept -and -not $ctStay.Count -and -not $ctLoose.Count) "$($script:CtSeen -join ' ; ') / failed $($script:CtFailed) / back $ctBack / swept $ctSwept / not left alone $($ctStay -join ', ') / loose $($ctLoose -join ', ')"

function Get-AlertCount([string]$Like) {
    $f = Join-Path $script:ChatqLogDir 'alerts.log'
    if (-not (Test-Path -LiteralPath $f)) { return 0 }
    @([System.IO.File]::ReadAllLines($f, $utf8) | Where-Object { $_ -like $Like }).Count
}
