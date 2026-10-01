# tests/sections/ultracode.ps1: dot-sourced by tests/run-tests.ps1 in its turn,
# never on its own - it uses what the runner and the sections before it set.

Section 'Ultracode and a session-only level: a queued run starts with them when the chat had them'
$ucDir = Join-Path $sb 'ultracode'
$null = New-Item -ItemType Directory -Path $ucDir -Force
$ucFile = { param([string]$Name, [string[]]$Parts) $f = Join-Path $ucDir "$Name.jsonl"; [System.IO.File]::WriteAllText($f, ($Parts -join ''), $utf8); $f }
# the same answer, its type too: $null is not $false
$ucIs = {
    param($Got, $Want)
    if ($null -eq $Want) { return $null -eq $Got }
    if ($Want -is [bool]) { return $Got -is [bool] -and $Got -eq $Want }
    return $Got -is [string] -and $Got -ceq $Want
}

# The rules' contract, tests/fixtures/session-vector.json (made by
# make-session-vector.js, its answers written by hand): every /effort answer,
# and every transcript read whole and again 777 bytes at a time
$ucVec = [System.IO.File]::ReadAllText((Join-Path (Join-Path $here 'fixtures') 'session-vector.json'), $utf8) | ConvertFrom-Json
$ucSays = @($ucVec.says)
$ucBad = @()
foreach ($s in $ucSays) {
    $got = Read-ChatEffortSay -Text $s.text -Version $s.version
    if (-not ((& $ucIs $got.Ultracode $s.ultracode) -and (& $ucIs $got.Level $s.level) -and (& $ucIs $got.Effort $s.effort))) {
        $ucBad += "$($s.version) '$($s.text.Substring(0, [Math]::Min(48, $s.text.Length)))' -> [$($got.Ultracode)] [$($got.Level)] [$($got.Effort)]"
    }
}
Check "every /effort answer in the vector read as it says: Ultracode, whether it set the level, the level for the session ($($ucSays.Count))" (
    $ucSays.Count -gt 0 -and -not $ucBad.Count) ($ucBad -join ' | ')
$ucCases = @($ucVec.cases)
$ucBad = @(); $ucBad7 = @(); $ucBadU = @()
$ucI = 0
foreach ($c in $ucCases) {
    $ucI++
    $ls = @($c.lines)
    if ($c.PSObject.Properties['pad'] -and $c.pad) { $x = 'x' * [int]$c.pad; $ls = @($ls | ForEach-Object { $_.Replace('@PAD@', $x) }) }
    $f = Join-Path $ucDir "case-$ucI.jsonl"
    [System.IO.File]::WriteAllText($f, ($ls -join "`n") + "`n", $utf8)
    $bp = @{}
    if ($c.PSObject.Properties['budget'] -and $null -ne $c.budget) { $bp.Budget = [int64]$c.budget }
    $w = $c.expect
    $got = Get-ChatSessionSettings -Path $f @bp
    if (-not ((& $ucIs $got.Ultracode $w.ultracode) -and (& $ucIs $got.Effort $w.effort))) { $ucBad += "$($c.name) -> [$($got.Ultracode)] [$($got.Effort)]" }
    $got = Get-ChatSessionSettings -Path $f -Chunk 777 @bp
    if (-not ((& $ucIs $got.Ultracode $w.ultracode) -and (& $ucIs $got.Effort $w.effort))) { $ucBad7 += "$($c.name) -> [$($got.Ultracode)] [$($got.Effort)]" }
    $got = Get-ChatUltracode -Path $f @bp
    if (-not (& $ucIs $got $w.ultracode)) { $ucBadU += "$($c.name) -> [$got]" }
    Remove-Item -LiteralPath $f -Force -EA SilentlyContinue
}
Check "every transcript in the vector read to its Ultracode and level ($($ucCases.Count), -Budget where it has one)" ($ucCases.Count -gt 0 -and -not $ucBad.Count) ($ucBad -join ' | ')
Check 'and the same read 777 bytes at a time: a line longer than that joined whole' ($ucCases.Count -gt 0 -and -not $ucBad7.Count) ($ucBad7 -join ' | ')
Check 'Get-ChatUltracode answers each as Get-ChatSessionSettings'' Ultracode' ($ucCases.Count -gt 0 -and -not $ucBadU.Count) ($ucBadU -join ' | ')

# Records as Claude Code 2.1.284 writes them, its keys in its order - as the
# vector's own builders (make-session-vector.js) write them
$ucFmt = "yyyy-MM-dd'T'HH:mm:ss.fff'Z'"
$ucInv = [System.Globalization.CultureInfo]::InvariantCulture
$script:UcClock = [DateTimeOffset]::UtcNow.AddHours(-3)
$ucAt = { param([int]$Ms = 1000) $script:UcClock = $script:UcClock.AddMilliseconds($Ms); $script:UcClock.ToString($ucFmt, $ucInv) }
$ucId = { [guid]::NewGuid().ToString() }
# the tail every record ends on; and < > & ' as they are, where 5.1's
# ConvertTo-Json would write them as \u escapes Claude Code never does
$ucLine = {
    param($R, [string]$Ep = 'claude-vscode', [string]$V = '2.1.284')
    $R.userType = 'external'; $R.entrypoint = $Ep; $R.cwd = 'C:\work'; $R.sessionId = 'uc'; $R.version = $V; $R.gitBranch = 'main'
    (($R | ConvertTo-Json -Compress -Depth 12) -replace '\\u003c', '<' -replace '\\u003e', '>' -replace '\\u0026', '&' -replace '\\u0027', "'") + "`n"
}
# a prompt the user typed
$ucHuman = {
    param($Content, [string]$Mode = 'auto')
    & $ucLine ([ordered]@{ parentUuid = (& $ucId); isSidechain = $false; promptId = (& $ucId); type = 'user'; message = [ordered]@{ role = 'user'; content = $Content }
            uuid = (& $ucId); timestamp = (& $ucAt); permissionMode = $Mode; origin = [ordered]@{ kind = 'human' }; promptSource = 'sdk'; turnOrigin = 'human' })
}
# an Ultracode notice, as written with the prompt before it; the entrypoint
# the process's that wrote it
$ucNotice = {
    param([string]$Kind, [string]$Ep = 'claude-vscode')
    $att = if ($Kind -eq 'enter') { [ordered]@{ type = 'ultra_effort_enter'; reminderType = 'full' } } else { [ordered]@{ type = 'ultra_effort_exit' } }
    & $ucLine ([ordered]@{ parentUuid = (& $ucId); isSidechain = $false; attachment = $att; type = 'attachment'; uuid = (& $ucId)
            timestamp = $script:UcClock.AddMilliseconds(-1).ToString($ucFmt, $ucInv) }) $Ep
}
# a turn of the model's at a level
$ucAsst = {
    param([string]$Effort, [string]$Ep = 'claude-vscode')
    $r = [ordered]@{ parentUuid = (& $ucId); isSidechain = $false
        message = [ordered]@{ model = 'claude-opus-5-5'; id = 'msg_uc'; type = 'message'; role = 'assistant'; content = @([ordered]@{ type = 'text'; text = 'done' }); stop_reason = 'end_turn' }
        requestId = 'req_uc'; type = 'assistant'; uuid = (& $ucId); timestamp = (& $ucAt 2000)
    }
    if ($Effort) { $r.effort = $Effort; $r.perTurnEffort = $Effort }
    & $ucLine $r $Ep
}
# a tool's result, its text twice as Claude Code keeps it; -Pad fills each
# '@PAD@' with that many y's, never through ConvertTo-Json
$ucResult = {
    param([string]$Text, [int]$Pad)
    $l = & $ucLine ([ordered]@{ parentUuid = (& $ucId); isSidechain = $false; promptId = (& $ucId); type = 'user'
            message = [ordered]@{ role = 'user'; content = @([ordered]@{ tool_use_id = 'toolu_uc'; type = 'tool_result'; content = $Text }) }; uuid = (& $ucId); timestamp = (& $ucAt 500)
            toolUseResult = [ordered]@{ stdout = $Text; stderr = ''; interrupted = $false }; sourceToolAssistantUUID = (& $ucId) })
    if ($Pad) { $l = $l.Replace('@PAD@', 'y' * $Pad) }
    $l
}
# a slash command: the user's command record, then what it printed as
# local_command
$ucCmd = {
    param([string]$Name, [string]$Arg, [string]$Say, [string]$Ep = 'claude-vscode')
    (& $ucLine ([ordered]@{ parentUuid = (& $ucId); isSidechain = $false; promptId = (& $ucId); type = 'user'
                message = [ordered]@{ role = 'user'; content = "<command-name>/$Name</command-name>`n            <command-message>$Name</command-message>`n            <command-args>$Arg</command-args>" }
                uuid = (& $ucId); timestamp = (& $ucAt) }) $Ep) +
    (& $ucLine ([ordered]@{ parentUuid = (& $ucId); isSidechain = $false; type = 'system'; subtype = 'local_command'; content = "<local-command-stdout>$Say</local-command-stdout>"
                level = 'info'; timestamp = (& $ucAt 0); uuid = (& $ucId); isMeta = $false; commandRun = [ordered]@{ command = $Name; args = $Arg } }) $Ep)
}
# a queued run as claude -p writes it: its prompt, its own exit, its turn
$ucRunRecs = {
    param([string]$Effort)
    (& $ucLine ([ordered]@{ parentUuid = (& $ucId); isSidechain = $false; promptId = (& $ucId); type = 'user'; message = [ordered]@{ role = 'user'; content = 'Continue from where you left off.' }
                uuid = (& $ucId); timestamp = (& $ucAt); permissionMode = 'auto'; promptSource = 'sdk'; turnOrigin = 'sdk' }) 'sdk-cli') + (& $ucNotice 'exit' 'sdk-cli') + (& $ucAsst $Effort 'sdk-cli')
}
$ucSayOnMax = 'Ultracode on (this session only): dynamic workflows on every task. Effort stays max.'
$ucSayOff = 'Ultracode off. Effort stays max.'
$ucSayMax = 'Set effort level to max (this session only): Maximum capability with deepest reasoning. May use excessive tokens resulting in long response times or overthinking. Use sparingly for the hardest tasks.'
$ucSayHigh = 'Set effort level to high (this session only): Comprehensive implementation with extensive testing and documentation'
# read whole, and 777 bytes at a time: both must say on, max
$ucOnMax = {
    param([string]$F)
    $a = Get-ChatSessionSettings $F
    $b = Get-ChatSessionSettings $F -Chunk 777
    [pscustomobject]@{ Ok = ($a.Ultracode -eq $true -and $a.Effort -eq 'max' -and $b.Ultracode -eq $true -and $b.Effort -eq 'max'); Say = "$($a.Ultracode) $($a.Effort) / $($b.Ultracode) $($b.Effort)" }
}

# what a grep of a transcript prints - a switch, /effort's answers, a prompt,
# a turn - is a tool's output, escaped, and none of these
$ucQuote = ((& $ucNotice 'exit') + (& $ucCmd 'effort' 'ultracode off' $ucSayOff) + (& $ucCmd 'effort' 'high' $ucSayHigh) + (& $ucHuman 'quoted') + (& $ucAsst 'low')).TrimEnd("`n")
$ucQ = & $ucOnMax (& $ucFile 'quoted' @((& $ucCmd 'effort' 'max' $ucSayMax), (& $ucHuman 'a'), (& $ucNotice 'enter'), (& $ucAsst 'max'), (& $ucResult $ucQuote)))
Check 'a switch, an /effort answer, a prompt and a turn quoted in a tool''s output count for nothing: still on, max' (
    $ucQ.Ok -and $ucQuote -like '*"ultra_effort_exit"*' -and $ucQuote -like '*"local_command"*' -and $ucQuote -like '*"kind":"human"*') $ucQ.Say
# another command's output, in /effort's words: none of it
$ucO = & $ucOnMax (& $ucFile 'other' @((& $ucHuman 'a'), (& $ucNotice 'enter'), (& $ucAsst 'max'), (& $ucCmd 'model' 'x' $ucSayOff), (& $ucCmd 'model' 'y' $ucSayHigh)))
Check 'a local_command of another command says nothing, whatever its words: still on, max' ($ucO.Ok) $ucO.Say
# a print-mode run's /effort, its turns and its notices are its own
$ucP = & $ucOnMax (& $ucFile 'sdk' @((& $ucCmd 'effort' 'max' $ucSayMax), (& $ucHuman 'a'), (& $ucNotice 'enter'), (& $ucAsst 'max'),
        (& $ucCmd 'effort' 'ultracode off' $ucSayOff 'sdk-cli'), (& $ucCmd 'effort' 'high' $ucSayHigh 'sdk-cli'), (& $ucRunRecs 'high'), (& $ucNotice 'exit' 'sdk-ts')))
Check 'a print-mode run''s /effort, its turn at another level and its exit leave the chat''s own: on, max' ($ucP.Ok) $ucP.Say

# far back: the switch and the level at the chat's first turn, then 5 MB of
# tools' output - a line longer than the 1 MB read at a time among it - and
# a queued run at the end
$ucBig = & $ucFile 'big' (@((& $ucCmd 'effort' 'max' $ucSayMax), (& $ucHuman 'a'), (& $ucNotice 'enter'), (& $ucAsst 'max')) +
    @(1..26 | ForEach-Object { & $ucResult '@PAD@' 50000 }) + @((& $ucResult '@PAD@' 1250000), (& $ucRunRecs 'high')))
$ucT = [System.Diagnostics.Stopwatch]::StartNew()
$ucBigOn = Get-ChatUltracode $ucBig
$ucBigS = Get-ChatSessionSettings $ucBig
$ucMs = $ucT.ElapsedMilliseconds
$ucBigCut = Get-ChatUltracode $ucBig -Budget 1048576
$ucBigCutS = Get-ChatSessionSettings $ucBig -Budget 1048576
Check 'Ultracode and max 5 MB back, past a line longer than a block: still found, and quickly; past -Budget, $null' (
    $ucBigOn -eq $true -and $ucBigS.Ultracode -eq $true -and $ucBigS.Effort -eq 'max' -and $null -eq $ucBigCut -and $null -eq $ucBigCutS.Ultracode -and $null -eq $ucBigCutS.Effort -and
    (Get-Item -LiteralPath $ucBig).Length -gt 5000000 -and $ucMs -lt 10000) "$ucBigOn $($ucBigS.Ultracode) $($ucBigS.Effort) [$ucBigCut] [$($ucBigCutS.Ultracode)] [$($ucBigCutS.Effort)] $ucMs ms"
# a record across the edge of the last 1 MB, read whole with the block
# before it: the exit after the prompt says off, where a record missed would
# leave the prompt judged by the enter before it
$ucEdgeText = & $ucNotice 'exit'
$ucEdgeB = (& $ucResult '').Length
$ucEdgePad = [int]((1048576 - [int]($ucEdgeText.Length / 2) - $ucEdgeB) / 2)
$ucEdge = & $ucFile 'edge' @((& $ucHuman 'a'), (& $ucNotice 'enter'), (& $ucAsst 'xhigh'), (& $ucHuman 'b'), $ucEdgeText, (& $ucResult '@PAD@' $ucEdgePad))
$ucEdgeAt = (Get-Item -LiteralPath $ucEdge).Length - 1048576
$ucEdgeStart = [System.IO.File]::ReadAllText($ucEdge, $utf8).IndexOf($ucEdgeText)
Check 'a switch record cut by the block''s edge is read whole' (
    (Get-ChatUltracode $ucEdge) -eq $false -and $ucEdgeStart -lt $ucEdgeAt -and $ucEdgeStart + $ucEdgeText.Length -gt $ucEdgeAt) "[$(Get-ChatUltracode $ucEdge)] $ucEdgeStart $ucEdgeAt"

# The run: a Claude run into the chat, on its own model - Ultracode by a
# settings file, the level by --effort. The chat is in default mode, as
# queued (modeAtQueue); a run given auto or bypassPermissions (the job's
# mode) takes Ultracode, any other leaves it off.
$projU = Join-Path (Join-Path $sb 'work') 'projU'
$null = New-Item -ItemType Directory -Path $projU -Force
$idU = '7c7c7c7c-7c7c-4c7c-8c7c-7c7c7c7c7c7c'
$pU = New-FakeChat $projU $idU 'Ultracode switch chat' 1 @('first thing') -Mode 'default'
$null = @(Sync-ChatIndex)
$ucAdd = { param([string]$Text) [System.IO.File]::AppendAllText($pU, $Text, $utf8) }
# a prompt of the chat's in its tab, its notice if any, its turn
$ucTurnU = { param([string]$Effort, [string]$Notice) $t = & $ucHuman 'go on' 'default'; if ($Notice) { $t += & $ucNotice $Notice }; $t + (& $ucAsst $Effort) }
$recU = Join-Path $sb 'rec-u'
$env:FAKE_RECORD = $recU
$script:UcStates = [System.Collections.Generic.List[object]]::new()
$script:ChatRunStateSeam = { param($s) $script:UcStates.Add($s) }
$ucArgv = { @([System.IO.File]::ReadAllLines((Join-Path $recU 'argv.txt'))) }
$ucArgAfter = { param($a, [string]$Name) $i = [Array]::IndexOf([string[]]$a, $Name); if ($i -ge 0) { [string]$a[$i + 1] } else { $null } }
$ucEffort = { param($a) & $ucArgAfter $a '--effort' }
$ucSetCount = { param($a) @($a | Where-Object { $_ -eq '--settings' }).Count }
# the --settings file as the run saw it (tests/fake-agent.ps1), or $null
$ucSet = { $p = Join-Path $recU 'settings.json'; if (Test-Path -LiteralPath $p) { [System.IO.File]::ReadAllText($p, $utf8) | ConvertFrom-Json } else { $null } }
$ucUltra = { param($a) (& $ucSetCount $a) -eq 1 -and (Get-ChatField (& $ucSet) 'ultracode') -eq $true }
$ucLog = Join-Path $script:ChatqLogDir 'watcher.log'
$ucMode = { param($j, [string]$Mode) $j = Find-ChatqJob $j.id -Exact; Set-ChatqProp $j 'mode' $Mode; $null = Save-ChatqJob $j; Find-ChatqJob $j.id -Exact }
# queued as chatq does, with the lock held as a running watcher would; -Mode
# the job's own, as chatq -Mode sets it
$ucQueue = {
    param([string]$Say, [string]$Mode, [string]$Model)
    Push-Location -LiteralPath $projU
    try {
        if ($Model) {
            New-ChatqDir $script:ChatqData
            $lk = [System.IO.File]::Open($script:ChatqLockPath, 'OpenOrCreate', 'ReadWrite', 'None')
            try { chatq 'Ultracode switch chat' -Prompt $Say -Model $Model *> $null } finally { $lk.Dispose() }
            $j = @(Get-ChatqJobs | Sort-Object { [int]$_.seq })[-1]
        }
        else { $j = New-TestJob 'Ultracode switch chat' $Say }
    }
    finally { Pop-Location }
    if ($Mode) { $j = & $ucMode $j $Mode }
    $j
}
$ucRun = {
    param([string]$Say, [string]$Mode, [string]$Model)
    $j = & $ucQueue $Say $Mode $Model
    $script:UcStates.Clear()
    $null = Invoke-ChatqJob (New-ChatqWatchState) (Find-ChatqJob $j.id -Exact)
    return (Find-ChatqJob $j.id -Exact)
}
$ucLogLine = { param($j) @([System.IO.File]::ReadAllLines($ucLog, $utf8) | Where-Object { $_ -like "*#$($j.seq) running: Ultracode switch chat*" } | Select-Object -Last 1) }
$ucHeldLine = { param($j) @([System.IO.File]::ReadAllLines($ucLog, $utf8) | Where-Object { $_ -like "*#$($j.seq) Ultracode left off*" }) }
$ucRunning = { param($j) @($j.history | Where-Object { $_.state -eq 'running' }) }
$ucRs = { @($script:UcStates | Where-Object { $_.phase -eq 'running' })[-1] }

& $ucAdd (& $ucTurnU 'xhigh' 'enter')
$uj1 = & $ucRun 'with it' 'auto'
$ua1 = & $ucArgv
$urs1 = & $ucRs
$ul1 = @(& $ucLogLine $uj1)
Check 'the chat had Ultracode on, the run in auto mode: "ultracode": true in a --settings file of its own, no --effort (ultracode would force xhigh), resumed on its own model' (
    $uj1.state -eq 'done' -and $uj1.sessionId -eq $idU -and $uj1.modeAtQueue -eq 'default' -and (& $ucArgAfter $ua1 '--permission-mode') -eq 'auto' -and (& $ucUltra $ua1) -and
    $ua1 -notcontains '--effort' -and $ua1 -contains '--resume' -and $ua1 -notcontains '--model' -and
    (& $ucArgAfter $ua1 '--settings') -like "*run-settings*$($uj1.id).json") "$($ua1 -join ' ') | $(& $ucSet | ConvertTo-Json -Compress)"
Check 'the run''s own settings file is gone once it ended' (-not (Test-Path -LiteralPath (Join-Path $script:ChatqRunSettingsDir "$($uj1.id).json"))) $script:ChatqRunSettingsDir
Check 'and says so: on the job, its history, watcher.log and the run-state' (
    $uj1.ultracode -eq $true -and -not (Get-ChatField $uj1 'effort') -and @(& $ucRunning $uj1 | Where-Object { $_.why -like '* - with Ultracode, as the chat had it' }).Count -eq 1 -and
    $ul1.Count -eq 1 -and $ul1[0] -like '*Ultracode switch chat - with Ultracode, as the chat had it' -and -not (& $ucHeldLine $uj1).Count -and
    $urs1.ultracode -eq $true -and $null -eq $urs1.effort) "$($uj1.ultracode) | $((& $ucRunning $uj1).why -join ' / ') | $($ul1 -join ' / ') | $($urs1.ultracode) [$($urs1.effort)]"
$ucCon = Get-ChatConsoleJobStatus ([pscustomobject]@{ state = 'running'; startedAt = (Get-ChatqStamp); ultracode = $true })
$ucCon0 = Get-ChatConsoleJobStatus ([pscustomobject]@{ state = 'running'; startedAt = (Get-ChatqStamp) })
$ucConM = Get-ChatConsoleJobStatus ([pscustomobject]@{ state = 'running'; startedAt = (Get-ChatqStamp); effort = 'max' })
$ucConB = Get-ChatConsoleJobStatus ([pscustomobject]@{ state = 'running'; startedAt = (Get-ChatqStamp); ultracode = $true; effort = 'max' })
Check 'the console says it of a running job - Ultracode, the level, both - and nothing of one without' ($ucCon.Text -like 'running since *, with Ultracode' -and $ucCon0.Text -notlike '*Ultracode*' -and
    $ucCon0.Text -notlike '*effort*' -and $ucConM.Text -like 'running since *, at effort max' -and $ucConB.Text -like 'running since *, with Ultracode, at effort max') "$($ucCon.Text) | $($ucCon0.Text) | $($ucConM.Text) | $($ucConB.Text)"
# a queued run's own exit, as claude -p writes it: the chat's choice stands
& $ucAdd (& $ucRunRecs 'high')
$uj2 = & $ucRun 'still with it' 'auto'
Check 'a queued run''s own prompt, exit and turn since change nothing: the next run starts with it too' ($uj2.state -eq 'done' -and (& $ucUltra (& $ucArgv))) ((& $ucArgv) -join ' ')
# switched off in the chat's own tab: the exit with its next prompt
& $ucAdd (& $ucTurnU 'xhigh' 'exit')
$uj3 = & $ucRun 'without it' 'auto'
$ua3 = & $ucArgv
$urs3 = & $ucRs
$ul3 = @(& $ucLogLine $uj3)
Check 'the chat switched it off: no --effort, no --settings, nothing on the job, the log or the history, run-state ultracode false' (
    $uj3.state -eq 'done' -and $ua3 -notcontains '--effort' -and $ua3 -notcontains '--settings' -and $null -eq (& $ucSet) -and -not (Get-ChatField $uj3 'ultracode') -and $urs3.ultracode -eq $false -and
    $ul3.Count -eq 1 -and $ul3[0] -like '*#* running: Ultracode switch chat' -and -not (& $ucHeldLine $uj3).Count -and
    -not @($uj3.history | Where-Object { $_.why -like '*Ultracode*' }).Count) "$($ua3 -join ' ') | $($urs3.ultracode) | $($ul3 -join ' / ')"
# max for this session only, from the chat's tab: --effort max, and nothing else
& $ucAdd ((& $ucCmd 'effort' 'max' $ucSayMax) + (& $ucTurnU 'max'))
$ujM = & $ucRun 'at max' 'auto'
$uaM = & $ucArgv
$ursM = & $ucRs
$ulM = @(& $ucLogLine $ujM)
Check 'the chat set max for its session: --effort max, no --settings; the job, its history, watcher.log and the run-state say "at effort max"' (
    $ujM.state -eq 'done' -and (& $ucEffort $uaM) -eq 'max' -and $uaM -notcontains '--settings' -and $ujM.effort -eq 'max' -and -not (Get-ChatField $ujM 'ultracode') -and
    @(& $ucRunning $ujM | Where-Object { $_.why -like '* - at effort max, as the chat had it' }).Count -eq 1 -and
    $ulM.Count -eq 1 -and $ulM[0] -like '*Ultracode switch chat - at effort max, as the chat had it' -and $ursM.effort -eq 'max' -and $ursM.ultracode -eq $false) "$($uaM -join ' ') | $($ulM -join ' / ') | $($ursM.effort)"
# and Ultracode on too, as the user did it: /effort max, /effort ultracode,
# then a prompt, its enter with it
& $ucAdd ((& $ucCmd 'effort' 'ultracode' $ucSayOnMax) + (& $ucTurnU 'max' 'enter'))
$ujB = & $ucRun 'at max with it' 'auto'
$uaB = & $ucArgv
$ursB = & $ucRs
$ulB = @(& $ucLogLine $ujB)
Check 'both: --effort max and the settings file''s "ultracode": true; said "with Ultracode, at effort max, as the chat had them"' (
    $ujB.state -eq 'done' -and (& $ucEffort $uaB) -eq 'max' -and (& $ucUltra $uaB) -and $ujB.effort -eq 'max' -and $ujB.ultracode -eq $true -and
    @(& $ucRunning $ujB | Where-Object { $_.why -like '* - with Ultracode, at effort max, as the chat had them' }).Count -eq 1 -and
    $ulB.Count -eq 1 -and $ulB[0] -like '*- with Ultracode, at effort max, as the chat had them' -and $ursB.effort -eq 'max' -and $ursB.ultracode -eq $true) "$($uaB -join ' ') | $($ulB -join ' / ')"
# The chat's own mode, default: Ultracode's standing instruction has the
# run call Workflow, which that mode asks about and no one answers - held
# back, and said so; the level goes all the same
$ujD = & $ucRun 'in default mode'
$uaD = & $ucArgv
$ursD = & $ucRs
$ulD = @(& $ucLogLine $ujD)
$uhD = @(& $ucHeldLine $ujD)
$ucCarryD = Get-ChatqRunCarry $ujD
Check 'default mode, the chat''s as queued: no Ultracode - no --settings, nothing on the job, run-state false - but --effort max; Get-ChatqRunCarry holds it back as default' (
    $ujD.state -eq 'done' -and -not (Get-ChatField $ujD 'mode') -and $ujD.modeAtQueue -eq 'default' -and (& $ucArgAfter $uaD '--permission-mode') -eq 'default' -and
    $uaD -notcontains '--settings' -and $null -eq (& $ucSet) -and (& $ucEffort $uaD) -eq 'max' -and $null -eq (Get-ChatField $ujD 'ultracode') -and $ujD.effort -eq 'max' -and
    $ursD.ultracode -eq $false -and $ursD.effort -eq 'max' -and $ucCarryD.Ultracode -eq $false -and $ucCarryD.Effort -eq 'max' -and $ucCarryD.UltracodeHeld -eq 'default' -and
    -not (Test-ChatqRunUltracode $ujD)) "$($uaD -join ' ') | $($ursD.ultracode) $($ursD.effort) | $($ucCarryD | ConvertTo-Json -Compress)"
Check 'and says why: the history "- Ultracode left off (default mode asks before each Workflow)", watcher.log a line of its own' (
    @(& $ucRunning $ujD | Where-Object { $_.why -like 'attempt 1 - at effort max, as the chat had it - Ultracode left off (default mode asks before each Workflow)' }).Count -eq 1 -and
    $ulD.Count -eq 1 -and $ulD[0] -like '*Ultracode switch chat - at effort max, as the chat had it' -and $uhD.Count -eq 1 -and
    $uhD[0] -like "*#$($ujD.seq) Ultracode left off: the chat had it, but default mode would ask before each Workflow, and no one can answer a run") "$((& $ucRunning $ujD).why -join ' / ') | $($ulD -join ' / ') | $($uhD -join ' / ')"
# the run's mode: the job's own, else the chat's as queued, else default
$ucCj = { param($Mode, $AtQueue) $o = [pscustomobject]@{ provider = 'claude'; kind = 'prompt'; sessionId = $idU; path = $pU; home = $claudeHome }
    if ($Mode) { $o | Add-Member -NotePropertyName mode -NotePropertyValue $Mode }
    if ($AtQueue) { $o | Add-Member -NotePropertyName modeAtQueue -NotePropertyValue $AtQueue }
    Get-ChatqRunCarry $o }
$ucModes = [ordered]@{ 'auto' = (& $ucCj 'auto' 'default'); 'bypass' = (& $ucCj 'bypassPermissions' $null); 'queued auto' = (& $ucCj $null 'auto')
    'acceptEdits' = (& $ucCj 'acceptEdits' 'auto'); 'plan' = (& $ucCj 'plan' $null); 'none' = (& $ucCj $null $null) }
$ucWant = @{ 'auto' = @($true, $null); 'bypass' = @($true, $null); 'queued auto' = @($true, $null); 'acceptEdits' = @($false, 'acceptEdits'); 'plan' = @($false, 'plan'); 'none' = @($false, 'default') }
$ucBad = @($ucModes.Keys | Where-Object { $m = $ucModes[$_]; -not ($m.Ultracode -eq $ucWant[$_][0] -and $m.UltracodeHeld -eq $ucWant[$_][1] -and $m.Effort -eq 'max') } | ForEach-Object { "$_ -> $($ucModes[$_] | ConvertTo-Json -Compress)" })
Check 'Get-ChatqRunCarry by the run''s mode - the job''s, else the chat''s as queued, else default: auto and bypassPermissions carry Ultracode, acceptEdits, plan and default hold it back by name, the level carried either way' (
    -not $ucBad.Count) ($ucBad -join ' | ')
$ujY = & $ucRun 'bypassing' 'bypassPermissions'
$uaY = & $ucArgv
Check 'bypassPermissions, the job''s mode: Ultracode carried, and --effort max beside it, nothing left off' (
    $ujY.state -eq 'done' -and (& $ucArgAfter $uaY '--permission-mode') -eq 'bypassPermissions' -and (& $ucUltra $uaY) -and (& $ucEffort $uaY) -eq 'max' -and $ujY.ultracode -eq $true -and
    -not (& $ucHeldLine $ujY).Count -and -not @($ujY.history | Where-Object { $_.why -like '*left off*' }).Count) ($uaY -join ' ')
# the job names a model of its own: neither - Claude refuses Ultracode on a
# model that cannot do it, and the level was the chat's model's
$uj4 = & $ucRun 'on another model' 'auto' 'claude-sonnet-9'
$ua4 = & $ucArgv
Check 'a job with -Model: never with Ultracode nor the level, whatever the chat had' (
    $uj4.state -eq 'done' -and $ua4 -notcontains '--effort' -and $ua4 -notcontains '--settings' -and ($ua4 -join ' ') -match '--model claude-sonnet-9' -and
    -not (Get-ChatField $uj4 'effort') -and -not (Get-ChatField $uj4 'ultracode') -and -not (& $ucHeldLine $uj4).Count) ($ua4 -join ' ')
# the run judged in Invoke-ChatqRun itself, with no -Carry given
$uj5 = [pscustomobject]@{ id = 'uc-direct'; provider = 'claude'; kind = 'prompt'; sessionId = $idU; path = $pU; cwd = $projU; home = $claudeHome; title = 'Ultracode switch chat'; mode = 'auto' }
$null = Invoke-ChatqRun $uj5 'x' $null $null
$ua5 = & $ucArgv
$null = Invoke-ChatqRun $uj5 'x' $null $null -Carry ([pscustomobject]@{ Ultracode = $false; Effort = $null })
$ua5b = & $ucArgv
$uj5.mode = 'default'
$null = Invoke-ChatqRun $uj5 'x' $null $null
$ua5d = & $ucArgv
Check 'Invoke-ChatqRun judges it itself when not told - by the mode too; told none, none' (
    (& $ucEffort $ua5) -eq 'max' -and (& $ucSetCount $ua5) -eq 1 -and $ua5b -notcontains '--effort' -and $ua5b -notcontains '--settings' -and
    (& $ucEffort $ua5d) -eq 'max' -and $ua5d -notcontains '--settings') "$($ua5 -join ' ') | $($ua5b -join ' ') | $($ua5d -join ' ')"
# the phone's permits on: the one --settings is the permit's, Ultracode merged
# into its rules - a second --settings would drop the first
$ucRule = Get-ChatqPermitDataRule
$ucRules = "AskUserQuestion|Edit($ucRule)|Write($ucRule)|NotebookEdit($ucRule)"
$ucDenyOf = { param($s) @(Get-ChatField (Get-ChatField $s 'permissions') 'deny') -join '|' }
$ujP = & $ucQueue 'with the permit' 'auto'
$ucPermit = New-ChatqPermitRun $ujP
$null = Invoke-ChatqRun $ujP 'x' $null $null -Permit $ucPermit
$uaP = & $ucArgv
$ucSetP = & $ucSet
# run here by hand, never by the watcher: out of the queue again - and a
# settings file a watcher that died left goes with the job
$ucStale = Join-Path $script:ChatqRunSettingsDir "$($ujP.id).json"
Save-ChatqJson $ucStale ([ordered]@{ ultracode = $true })
$null = Remove-ChatqJob (Find-ChatqJob $ujP.id -Exact) 'test'
Check 'a run''s own settings file left behind goes when its job is removed' (-not (Test-Path -LiteralPath $ucStale)) $ucStale
Check 'with the permit: one --settings, the permit''s file, holding its 4 deny rules and "ultracode": true; --effort max beside it' (
    (& $ucSetCount $uaP) -eq 1 -and (& $ucArgAfter $uaP '--settings') -eq $ucPermit.SettingsPath -and (Get-ChatField $ucSetP 'ultracode') -eq $true -and
    (& $ucDenyOf $ucSetP) -eq $ucRules -and (& $ucEffort $uaP) -eq 'max') "$($uaP -join ' ') | $($ucSetP | ConvertTo-Json -Compress -Depth 5)"
# the permit's file gone or spoilt between its making and the run: saved
# whole from the rules it was written from, never read back
$ucBad = @()
foreach ($how in 'deleted', 'corrupt') {
    $jx = & $ucQueue "the permit's file $how" 'auto'
    $px = New-ChatqPermitRun $jx
    if ($how -eq 'deleted') { Remove-Item -LiteralPath $px.SettingsPath -Force } else { [System.IO.File]::WriteAllText($px.SettingsPath, '{"permissions":{"deny":[', $utf8) }
    $null = Invoke-ChatqRun $jx 'x' $null $null -Permit $px
    $ax = & $ucArgv
    $sx = & $ucSet
    if (-not ($sx -and (& $ucArgAfter $ax '--settings') -eq $px.SettingsPath -and (Get-ChatField $sx 'ultracode') -eq $true -and (& $ucDenyOf $sx) -eq $ucRules)) {
        $ucBad += "$how -> $($sx | ConvertTo-Json -Compress -Depth 5)"
    }
    $null = Remove-ChatqJob (Find-ChatqJob $jx.id -Exact) 'test'
}
Check 'the permit''s settings.json deleted, or spoilt, before the run: the run still sees all 4 deny rules and "ultracode": true' (-not $ucBad.Count) ($ucBad -join ' | ')
# the run's own settings file, when its process never started: gone all the same
$ucProcFn = ${function:Invoke-ChatqProcess}
$script:UcThrowSaw = $null
$ucThrew = $null
${function:Invoke-ChatqProcess} = {
    param([string]$Exe, [string[]]$ArgList, [string]$WorkDir, [string]$StdIn, [hashtable]$SetEnv, [string]$LogPath, [scriptblock]$OnLine, [scriptblock]$OnTick, [int]$TimeoutSec = 14400)
    $i = [Array]::IndexOf($ArgList, '--settings')
    $script:UcThrowSaw = if ($i -ge 0) { "$($ArgList[$i + 1])|$(Test-Path -LiteralPath $ArgList[$i + 1])" } else { 'none' }
    throw 'uc: the process did not start'
}
$ujT = [pscustomobject]@{ id = 'uc-throw'; provider = 'claude'; kind = 'prompt'; sessionId = $idU; path = $pU; cwd = $projU; home = $claudeHome; title = 'Ultracode switch chat'; mode = 'auto' }
try { $null = Invoke-ChatqRun $ujT 'x' $null $null }
catch { $ucThrew = $_.Exception.Message }
finally { ${function:Invoke-ChatqProcess} = $ucProcFn }
$ucOwnT = Join-Path $script:ChatqRunSettingsDir 'uc-throw.json'
Check 'a run whose process throws at its start: its own settings file was there for it, and is gone after' (
    $ucThrew -like '*did not start*' -and $script:UcThrowSaw -eq "$ucOwnT|True" -and -not (Test-Path -LiteralPath $ucOwnT)) "[$ucThrew] [$($script:UcThrowSaw)]"
# a level the watcher's environment sets already: that one wins over
# --effort, and is the user's - left alone, and no --effort given
$env:CLAUDE_CODE_EFFORT_LEVEL = 'high'
$ujE = & $ucRun 'under an env level' 'auto'
$uaE = & $ucArgv
$ucEnvE = [System.IO.File]::ReadAllText((Join-Path $recU 'env.txt'), $utf8)
Remove-Item env:CLAUDE_CODE_EFFORT_LEVEL
Check 'CLAUDE_CODE_EFFORT_LEVEL set for the watcher: no --effort, the variable reaches the run as it was, Ultracode still carried' (
    $ujE.state -eq 'done' -and $uaE -notcontains '--effort' -and $ucEnvE -match '(?m)^CLAUDE_CODE_EFFORT_LEVEL=high$' -and (& $ucUltra $uaE) -and
    -not (Get-ChatField $ujE 'effort') -and $ujE.ultracode -eq $true) "$($uaE -join ' ') | $($ucEnvE -replace "`n", ' ')"
# the tab's menu set a level since: a prompt of the user's, and its turn at
# that level - saved, and comes back by itself
& $ucAdd (& $ucTurnU 'xhigh')
$ujX = & $ucRun 'after the menu' 'auto'
$uaX = & $ucArgv
Check 'a level the menu set since the /effort max: no --effort; Ultracode still, from the enter before that prompt' ($ujX.state -eq 'done' -and $uaX -notcontains '--effort' -and (& $ucUltra $uaX)) ($uaX -join ' ')
# chatqrm while the carry is read - it can read megabytes: the check after
# it still keeps the prompt out
$ujR = & $ucQueue 'removed meanwhile' 'auto'
Remove-Item -LiteralPath (Join-Path $recU 'argv.txt') -Force -EA SilentlyContinue
$ucLogAt = @([System.IO.File]::ReadAllLines($ucLog, $utf8)).Count
$ucCarryFn = ${function:Get-ChatqRunCarry}
$script:UcCarryHit = 0
${function:Get-ChatqRunCarry} = {
    param($Job)
    $script:UcCarryHit++
    $null = Remove-ChatqJob (Find-ChatqJob $Job.id -Exact) 'test'
    & $ucCarryFn $Job
}
try { Invoke-ChatqJob (New-ChatqWatchState) (Find-ChatqJob $ujR.id -Exact) }
finally { ${function:Get-ChatqRunCarry} = $ucCarryFn }
$ucLogR = @([System.IO.File]::ReadAllLines($ucLog, $utf8) | Select-Object -Skip $ucLogAt)
Check 'a job removed while its carry was being read is not run: no claude -p, no running line, the job gone' (
    $script:UcCarryHit -eq 1 -and -not (Test-Path -LiteralPath (Join-Path $recU 'argv.txt')) -and $null -eq (Find-ChatqJob $ujR.id -Exact) -and
    -not @($ucLogR | Where-Object { $_ -like '* running: *' }).Count) "$($script:UcCarryHit) | $($ucLogR -join ' / ')"
# a cancel written after the job stood running, before its run went in: it
# carried nothing, so neither the job nor the run-state may say it did
$ujC = & $ucQueue 'cancelled at the start' 'auto'
Remove-Item -LiteralPath (Join-Path $recU 'argv.txt') -Force -EA SilentlyContinue
$ucCancel = Join-Path $script:ChatqQueueDir "$($ujC.id).cancel"
$ucAwayFn = ${function:Test-ChatqUserAway}
$script:UcAwayHit = 0
${function:Test-ChatqUserAway} = {
    $script:UcAwayHit++
    [System.IO.File]::WriteAllText($ucCancel, '', $utf8)
    & $ucAwayFn @args
}
$script:UcStates.Clear()
try { Invoke-ChatqJob (New-ChatqWatchState) (Find-ChatqJob $ujC.id -Exact) }
finally { ${function:Test-ChatqUserAway} = $ucAwayFn }
$ujC = Find-ChatqJob $ujC.id -Exact
$ursC = @($script:UcStates)[-1]
Check 'a start cancelled before its run went in: failed, never run, and neither the job nor the last run-state says Ultracode or a level' (
    $script:UcAwayHit -ge 1 -and $ujC.state -eq 'failed' -and -not (Test-Path -LiteralPath (Join-Path $recU 'argv.txt')) -and
    -not (Get-ChatField $ujC 'ultracode') -and -not (Get-ChatField $ujC 'effort') -and $ursC -and $ursC.ultracode -eq $false -and $null -eq $ursC.effort) "$($script:UcAwayHit) $($ujC.state) [$(Get-ChatField $ujC 'ultracode')] | $($ursC | ConvertTo-Json -Compress)"
# a new chat's first run, and Codex: never
$env:FAKE_NEW_CHAT = '1'
$ucNew = (New-ChatqJob -Kind new -Cwd $projU -Prompt 'a brand new chat' -Title 'uc new chat').Job
Invoke-ChatqJob (New-ChatqWatchState) (Find-ChatqJob $ucNew.id -Exact)
Remove-Item env:FAKE_NEW_CHAT
$ua6 = & $ucArgv
$ucCx = [pscustomobject]@{ provider = 'codex'; kind = 'prompt'; sessionId = 'cx'; path = $pU; mode = 'auto' }
$ucFresh = [pscustomobject]@{ provider = 'claude'; kind = 'new'; sessionId = 'nx'; path = (Join-Path $ucDir 'not-yet.jsonl'); mode = 'auto' }
$ucCxC = Get-ChatqRunCarry $ucCx
$ucFrC = Get-ChatqRunCarry $ucFresh
$ucMod = Get-ChatqRunCarry ([pscustomobject]@{ provider = 'claude'; kind = 'prompt'; sessionId = $idU; path = $pU; home = $claudeHome; runModel = 'claude-sonnet-9'; mode = 'auto' })
$ucOwn = Get-ChatqRunCarry ([pscustomobject]@{ provider = 'claude'; kind = 'prompt'; sessionId = $idU; path = $pU; home = $claudeHome; mode = 'auto' })
Check 'a new chat''s first run starts it with --session-id and neither; Codex, a fresh chat and a -Model are never judged on' (
    $ua6 -contains '--session-id' -and $ua6 -notcontains '--effort' -and $ua6 -notcontains '--settings' -and
    -not $ucCxC.Ultracode -and -not $ucCxC.Effort -and -not $ucFrC.Ultracode -and -not $ucFrC.Effort -and -not $ucMod.Ultracode -and -not $ucMod.Effort -and
    -not $ucCxC.UltracodeHeld -and -not $ucMod.UltracodeHeld -and -not (Test-ChatqRunUltracode $ucCx) -and -not (Test-ChatqRunUltracode $ucFresh) -and $ucOwn.Ultracode -and
    (Test-ChatqRunUltracode ([pscustomobject]@{ provider = 'claude'; kind = 'prompt'; sessionId = $idU; path = $pU; home = $claudeHome; mode = 'auto' })) -and
    -not (Test-ChatqRunUltracode ([pscustomobject]@{ provider = 'claude'; kind = 'prompt'; sessionId = $idU; path = $pU; home = $claudeHome }))) ($ua6 -join ' ')

# The settings the run loads (Get-ChatqRunRules): the user's in the job's
# config dir, the project's and the local one in its folder. A Workflow
# allow carries Ultracode in a mode that would ask; a deny or an ask holds
# it back in any; a level an env there sets drops --effort. The chat at max
# for its session again first, Ultracode still on.
& $ucAdd ((& $ucCmd 'effort' 'max' $ucSayMax) + (& $ucTurnU 'max'))
$ucRH = Join-Path $ucDir 'rules-home'
$ucRH2 = Join-Path $ucDir 'rules-home-2'
$ucRP = Join-Path $ucDir 'rules-proj'
foreach ($d0 in $ucRH, $ucRH2, (Join-Path $ucRP '.claude')) { $null = New-Item -ItemType Directory -Path $d0 -Force }
$ucRSet = {
    param([string]$Where, $Obj)
    $f = switch ($Where) { 'user' { Join-Path $ucRH 'settings.json' } 'project' { Join-Path (Join-Path $ucRP '.claude') 'settings.json' } default { Join-Path (Join-Path $ucRP '.claude') 'settings.local.json' } }
    if ($null -eq $Obj) { Remove-Item -LiteralPath $f -Force -EA SilentlyContinue }
    elseif ($Obj -is [string]) { [System.IO.File]::WriteAllText($f, $Obj, $utf8) }
    else { [System.IO.File]::WriteAllText($f, ($Obj | ConvertTo-Json -Depth 5), $utf8) }
}
$ucRC = {
    param([string]$Mode = 'default', [string]$Home0 = $ucRH)
    Get-ChatqRunCarry ([pscustomobject]@{ provider = 'claude'; kind = 'prompt'; sessionId = $idU; path = $pU; home = $Home0; cwd = $ucRP; mode = $Mode })
}
$ucRW = { param($c) "$($c.Ultracode)|$($c.UltracodeHeld)|$($c.HeldBy)|$($c.RuleIn)|$($c.Effort)" }
$ucR0 = & $ucRC
& $ucRSet 'user' @{ permissions = @{ allow = @('Bash(git *)', 'Workflow') } }
$ucR1 = & $ucRC
$ucR1h = & $ucRC 'default' $ucRH2
$ucR1p = & $ucRC 'plan'
& $ucRSet 'user' @{ permissions = @{ allow = @('Workflow(review)') } }
$ucR2 = & $ucRC
& $ucRSet 'user' @{ permissions = @{ allow = @('Workflow(*)') } }
$ucR2s = & $ucRC
& $ucRSet 'project' @{ permissions = @{ deny = @('Workflow(release)') } }
$ucR3 = & $ucRC
$ucR3a = & $ucRC 'auto'
& $ucRSet 'project' $null
& $ucRSet 'local' @{ permissions = @{ ask = @('Workflow') } }
$ucR4 = & $ucRC 'bypassPermissions'
& $ucRSet 'local' '{"permissions":{"deny":['
$ucR5 = & $ucRC
& $ucRSet 'local' $null
& $ucRSet 'project' @{ env = @{ CLAUDE_CODE_EFFORT_LEVEL = 'high' } }
$ucR6 = & $ucRC 'auto'
# which file set it: the project's alone, then the user's too - the first
# file read (user, project, local) names it; then the user's alone
$ucRR = { (Get-ChatqRunRules ([pscustomobject]@{ provider = 'claude'; home = $ucRH; cwd = $ucRP })).EffortEnv }
$ucR6p = & $ucRR
& $ucRSet 'user' @{ env = @{ CLAUDE_CODE_EFFORT_LEVEL = 'low' } }
$ucR6u = & $ucRR
& $ucRSet 'project' $null
$ucR7 = & $ucRC 'auto'
$ucR7u = & $ucRR
& $ucRSet 'user' $null
$ucR7n = & $ucRR
$ucRBad = @()
foreach ($x in @(
        @('none, default', $ucR0, 'False|default|mode||max'), @('user allow, default', $ucR1, 'True||allow|user|max'), @('allow in another home', $ucR1h, 'False|default|mode||max'),
        @('allow, plan', $ucR1p, 'False|plan|mode||max'), @('allow of one workflow', $ucR2, 'False|default|mode||max'), @('allow Workflow(*)', $ucR2s, 'True||allow|user|max'),
        @('project deny over user allow', $ucR3, 'False|default|deny|project|max'), @('project deny, auto', $ucR3a, 'False|auto|deny|project|max'),
        @('local ask, bypass', $ucR4, 'False|bypassPermissions|ask|local|max'), @('spoilt local, the user allow', $ucR5, 'True||allow|user|max'), @('env level, auto', $ucR6, 'True||||'),
        @('user env level, auto', $ucR7, 'True||||'))) {
    if ((& $ucRW $x[1]) -ne $x[2]) { $ucRBad += "$($x[0]) -> $(& $ucRW $x[1])" }
}
if (-not ($ucR6p -eq 'project' -and $ucR6u -eq 'user' -and $ucR7u -eq 'user' -and $null -eq $ucR7n)) { $ucRBad += "EffortEnv: [$ucR6p] [$ucR6u] [$ucR7u] [$ucR7n]" }
Check 'Get-ChatqRunCarry by the settings the run loads: a Workflow allow carries Ultracode in default mode, not in plan, not one workflow''s; a deny or ask anywhere holds it in any mode; the job''s own config dir; a settings env level - the project''s or the user''s, the first file read named - drops --effort' (
    -not $ucRBad.Count) ($ucRBad -join ' | ')
Check 'and says why in words: the settings that deny it, that ask, or the mode - plan''s own, since an allow means it asks nothing' (
    (Format-ChatqUltracodeHeld $ucR3) -eq 'the project settings deny Workflow' -and (Format-ChatqUltracodeHeld $ucR4) -eq 'the local settings ask before a Workflow' -and
    (Format-ChatqUltracodeHeld $ucR1p) -eq "plan mode changes nothing, and a workflow's agents would" -and
    (Format-ChatqUltracodeHeld $ucR0) -eq 'default mode asks before each Workflow' -and (Format-ChatqUltracodeHeld $ucR1) -eq '') "$(Format-ChatqUltracodeHeld $ucR3) | $(Format-ChatqUltracodeHeld $ucR4)"
# through the watcher: the project's allow, the run in default mode
$ucProjSet = Join-Path (Join-Path $projU '.claude') 'settings.json'
$null = New-Item -ItemType Directory -Path (Split-Path $ucProjSet) -Force
[System.IO.File]::WriteAllText($ucProjSet, '{"permissions":{"allow":["Workflow"]}}', $utf8)
$ujA = & $ucRun 'allowed by the project'
$uaA = & $ucArgv
# the run's --settings copy, read now: the next run, with none, removes it
$ucUA = & $ucUltra $uaA
[System.IO.File]::WriteAllText($ucProjSet, '{"permissions":{"deny":["Workflow"]}}', $utf8)
$ujN = & $ucRun 'denied by the project' 'auto'
$uaN = & $ucArgv
Remove-Item -LiteralPath (Split-Path $ucProjSet) -Recurse -Force
$ulA = @([System.IO.File]::ReadAllLines($ucLog, $utf8) | Where-Object { $_ -like "*#$($ujA.seq) Ultracode carried in default mode: the project settings allow Workflow" })
Check 'a run in default mode with the project''s Workflow allow: Ultracode carried, and watcher.log says by what; a deny there holds it in auto mode, and says so' (
    $ujA.state -eq 'done' -and $ucUA -and $ujA.ultracode -eq $true -and $ulA.Count -eq 1 -and
    $ujN.state -eq 'done' -and $uaN -notcontains '--settings' -and @(& $ucRunning $ujN | Where-Object { $_.why -like '*Ultracode left off (the project settings deny Workflow)' }).Count -eq 1 -and
    @(& $ucHeldLine $ujN | Where-Object { $_ -like '*but the project settings deny Workflow, and no one can answer a run' }).Count -eq 1) "$($uaA -join ' ') | $($uaN -join ' ')"

# What the run took, from its own records as it ends (Get-ChatqRunTook):
# Claude Code writes a notice only when the state differs from the last it
# sees, so the run's exit says not taken, its enter or no notice under an
# enter says taken; its first turn's effort is the level it ran at
$env:FAKE_TOOK_INTO = $pU
$ucTook = {
    param([string]$Say, [string]$Took)
    $env:FAKE_TOOK = $Took
    try { & $ucRun $Say 'auto' } finally { Remove-Item env:FAKE_TOOK -EA SilentlyContinue }
}
$ucEnd = { param($j) [string]@($j.history)[-1].why }
$ucTookLine = { param($j) @([System.IO.File]::ReadAllLines($ucLog, $utf8) | Where-Object { $_ -like "*#$($j.seq) * - the run's own records say so" }) }
$ujT1 = & $ucTook 'took exit' ((& $ucNotice 'exit' 'sdk-cli') + (& $ucAsst 'max' 'sdk-cli'))
$ujT2 = & $ucTook 'took nothing after the exit' (& $ucAsst 'max' 'sdk-cli')
$ujT3 = & $ucTook 'took enter' ((& $ucNotice 'enter' 'sdk-cli') + (& $ucAsst 'max' 'sdk-cli'))
$ujT4 = & $ucTook 'took nothing after the enter' (& $ucAsst 'max' 'sdk-cli')
Check 'the run wrote an exit: the job''s ultracode cleared, its end in the history says "Ultracode not taken", watcher.log too' (
    $ujT1.state -eq 'done' -and -not (Get-ChatField $ujT1 'ultracode') -and (& $ucEnd $ujT1) -like '* - Ultracode not taken' -and
    @(& $ucRunning $ujT1 | Where-Object { $_.why -like '* - with Ultracode, at effort max, as the chat had them' }).Count -eq 1 -and
    @(& $ucTookLine $ujT1 | Where-Object { $_ -like '*Ultracode not taken - *' }).Count -eq 1) "$(& $ucEnd $ujT1) | $(& $ucTookLine $ujT1)"
Check 'no notice of its own after a run''s exit: not taken either; its enter, or none after it: taken - nothing said' (
    -not (Get-ChatField $ujT2 'ultracode') -and (& $ucEnd $ujT2) -like '* - Ultracode not taken' -and
    $ujT3.ultracode -eq $true -and (& $ucEnd $ujT3) -notlike '*taken*' -and -not (& $ucTookLine $ujT3).Count -and
    $ujT4.ultracode -eq $true -and (& $ucEnd $ujT4) -notlike '*taken*') "$(& $ucEnd $ujT2) | $(& $ucEnd $ujT3) | $(& $ucEnd $ujT4)"
# a level carried and another run at: the job keeps the one it ran at
$ujT5 = & $ucTook 'took a lower level' (& $ucAsst 'high' 'sdk-cli')
Check 'carried --effort max, its turn at high: the job says high, its end "ran at effort high, not max"' (
    (& $ucEffort (& $ucArgv)) -eq 'max' -and $ujT5.effort -eq 'high' -and $ujT5.ultracode -eq $true -and (& $ucEnd $ujT5) -like '* - ran at effort high, not max') "$($ujT5.effort) | $(& $ucEnd $ujT5)"
# Get-ChatqRunTook itself: a turn of the chat's own, a subagent's, one with
# no effort are not the run's; a turn that only talks of a notice is; past
# a stretch over 1 MB; cut off before a turn, nothing
$ucTk = { param([string[]]$Parts) $f = & $ucFile 'took' $Parts; $n = [int64](Get-Item -LiteralPath $f).Length; $f, $n }
$ucTkBase = (& $ucHuman 'a') + (& $ucNotice 'enter') + (& $ucAsst 'max')
$f0, $n0 = & $ucTk @($ucTkBase)
$ucSide = (& $ucAsst 'low' 'sdk-cli').Replace('"isSidechain":false', '"isSidechain":true')
$ucTalk = (& $ucAsst 'medium' 'sdk-cli').Replace('"text":"done"', '"text":"it wrote \"ultra_effort_exit\""')
[System.IO.File]::AppendAllText($f0, (& $ucNotice 'exit' 'sdk-cli') + (& $ucAsst 'xhigh') + $ucSide + (& $ucAsst '' 'sdk-cli') + (& $ucResult '@PAD@' 1100000) + $ucTalk, $utf8)
$ucTk1 = Get-ChatqRunTook $f0 $n0
$f1, $n1 = & $ucTk @($ucTkBase)
[System.IO.File]::AppendAllText($f1, (& $ucNotice 'exit' 'sdk-cli'), $utf8)
$ucTk2 = Get-ChatqRunTook $f1 $n1
$ucTk3 = Get-ChatqRunTook $f1 ((Get-Item -LiteralPath $f1).Length)
Check 'Get-ChatqRunTook: the run''s exit and its first own turn - past the chat''s turn, a subagent''s, one with no effort and 1 MB of output, a turn that names a notice counts; no turn yet, or nothing after, says nothing' (
    $ucTk1.Ultracode -eq $false -and $ucTk1.Effort -eq 'medium' -and $null -eq $ucTk2.Ultracode -and $null -eq $ucTk2.Effort -and $null -eq $ucTk3.Ultracode -and $null -eq $ucTk3.Effort -and
    (Confirm-ChatqRunCarry ([pscustomobject]@{ ultracode = $true; effort = 'max' }) $ucTk2) -eq '' -and
    (Confirm-ChatqRunCarry ([pscustomobject]@{ ultracode = $true; effort = 'medium' }) $ucTk1) -eq 'Ultracode not taken') "$($ucTk1 | ConvertTo-Json -Compress) | $($ucTk2 | ConvertTo-Json -Compress)"
# no notice of the run's, so the scan back from -From: a compaction after
# the chat's enter is met first - off; a notice line over 1 MB that began
# before the first stretch back is read whole in a longer one - on; one
# further back than -Budget is not reached - not known, the level still is
$ucBound = & $ucLine ([ordered]@{ parentUuid = $null; logicalParentUuid = (& $ucId); isSidechain = $false; type = 'system'; subtype = 'compact_boundary'; content = 'Conversation compacted'
        isMeta = $false; timestamp = (& $ucAt); uuid = (& $ucId); level = 'info'; compactMetadata = [ordered]@{ trigger = 'auto'; preTokens = 170000 } })
$f2, $n2 = & $ucTk @($ucTkBase + $ucBound)
[System.IO.File]::AppendAllText($f2, (& $ucAsst 'high' 'sdk-cli'), $utf8)
$ucTk4 = Get-ChatqRunTook $f2 $n2
$ucBig = (& $ucLine ([ordered]@{ parentUuid = '@PAD@'; isSidechain = $false; attachment = [ordered]@{ type = 'ultra_effort_enter'; reminderType = 'full' }; type = 'attachment'; uuid = (& $ucId)
            timestamp = (& $ucAt) })).Replace('@PAD@', 'y' * 1100000)
$f3, $n3 = & $ucTk @((& $ucHuman 'a'), $ucBig, (& $ucAsst 'max'))
[System.IO.File]::AppendAllText($f3, (& $ucAsst 'high' 'sdk-cli'), $utf8)
$ucTk5 = Get-ChatqRunTook $f3 $n3
$f4, $n4 = & $ucTk @((& $ucHuman 'a'), (& $ucNotice 'enter'), (& $ucResult '@PAD@' 300000), (& $ucAsst 'max'))
[System.IO.File]::AppendAllText($f4, (& $ucAsst 'high' 'sdk-cli'), $utf8)
$ucTk6 = Get-ChatqRunTook $f4 $n4 -Budget 200000
$ucTk6w = Get-ChatqRunTook $f4 $n4
Check 'Get-ChatqRunTook with no notice of the run''s: a compact_boundary met first is off; a notice line over 1 MB across the first stretch back is read whole - on; one past -Budget is not known, its level still read' (
    (& $ucIs $ucTk4.Ultracode $false) -and $ucTk4.Effort -eq 'high' -and (& $ucIs $ucTk5.Ultracode $true) -and $ucTk5.Effort -eq 'high' -and
    $null -eq $ucTk6.Ultracode -and $ucTk6.Effort -eq 'high' -and (& $ucIs $ucTk6w.Ultracode $true) -and
    (Confirm-ChatqRunCarry ([pscustomobject]@{ ultracode = $true; effort = 'high' }) $ucTk6) -eq '') "$($ucTk4 | ConvertTo-Json -Compress) | $($ucTk5 | ConvertTo-Json -Compress) | $($ucTk6 | ConvertTo-Json -Compress) | $($ucTk6w | ConvertTo-Json -Compress)"
Remove-Item env:FAKE_TOOK_INTO

# back as the other sections expect it
$script:ChatRunStateSeam = $null
Remove-Item env:FAKE_RECORD
$ucNewPath = [string](Find-ChatqJob $ucNew.id -Exact).path
foreach ($j in @(Get-ChatqJobs | Where-Object { $_.sessionId -eq $idU -or $_.id -eq $ucNew.id })) { $null = Remove-ChatqJob $j 'test' }
Remove-Item -LiteralPath $pU -Force -EA SilentlyContinue
if ($ucNewPath) { Remove-Item -LiteralPath $ucNewPath -Force -EA SilentlyContinue }
Remove-Item -LiteralPath $ucDir -Recurse -Force -EA SilentlyContinue
$null = @(Sync-ChatIndex)
