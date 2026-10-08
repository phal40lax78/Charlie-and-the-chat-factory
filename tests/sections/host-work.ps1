# tests/sections/host-work.ps1: dot-sourced by tests/run-tests.ps1 in its turn,
# never on its own - it uses what the runner and the sections before it set.

Section 'the chats one window runs'
# Get-ChatHostWork, which the extension asks before it restarts its window's
# extensions or reloads the window. A Claude home of its own - its registry,
# and each chat's transcript under projects/ by its folder - and a process
# table standing in for Win32_Process: two windows' extension hosts under one
# Code.exe, and a terminal's shell.
$hwHan = -join [char[]](0xD55C, 0xAE00)                                      # "Hangul"
$hwHanEsc = [string][char]92 + 'ud55c' + [char]92 + 'uae00'                 # as JSON escapes it
# The home is named in Hangul, so every transcript path is too.
$hwHome = Join-Path $sb ('claude-hw-' + $hwHan)
$hwSess = Join-Path $hwHome 'sessions'
$null = New-Item -ItemType Directory -Path $hwSess -Force
$projH = Join-Path (Join-Path $sb 'work') 'projH'
$projHan = Join-Path (Join-Path $sb 'work') ($hwHan + '-proj')    # a folder named in Hangul
foreach ($d in $projH, $projHan) { $null = New-Item -ItemType Directory -Path $d -Force }
$idH1 = '1d1d1d1d-1d1d-4d1d-8d1d-1d1d1d1d1d1d'   # idle
$idH2 = '2d2d2d2d-2d2d-4d2d-8d2d-2d2d2d2d2d2d'   # a turn in flight
$idH3 = '3d3d3d3d-3d3d-4d3d-8d3d-3d3d3d3d3d3d'   # a permission prompt
$idH4 = '4d4d4d4d-4d4d-4d4d-8d4d-4d4d4d4d4d4d'   # idle, a workflow running
$idH5 = '5d5d5d5d-5d5d-4d5d-8d5d-5d5d5d5d5d5d'   # another window's, busy
$idH6 = '6d6d6d6d-6d6d-4d6d-8d6d-6d6d6d6d6d6d'   # a terminal's, busy
$hwFile = @{}
foreach ($id in $idH1, $idH2, $idH3, $idH4, $idH5, $idH6) { $hwFile[$id] = New-FakeChat $projH $id "Host work $($id.Substring(0, 2))" 2 @('go') -HomeDir $hwHome }
$hwFile[$idH1] = New-FakeChat $projHan $idH1 'Host work in Hangul' 2 @('go') -HomeDir $hwHome
$hwStart = [DateTimeOffset]::UtcNow.AddMinutes(-60).ToUnixTimeMilliseconds()
function Set-HwSession([int]$ProcId, [string]$SessionId, [string]$Status = 'idle', [string]$Kind = 'interactive', [string]$Entrypoint = 'claude-vscode', [string]$Cwd = $projH) {
    $o = [ordered]@{ pid = $ProcId; sessionId = $SessionId; cwd = $Cwd; startedAt = $hwStart; kind = $Kind; entrypoint = $Entrypoint
        pidDomain = "win32:$([Environment]::MachineName)"; status = $Status; updatedAt = $hwStart }
    [System.IO.File]::WriteAllText((Join-Path $hwSess "$ProcId.json"), ($o | ConvertTo-Json -Compress), $utf8)
}
Set-HwSession 1001 $idH1 'idle' -Cwd $projHan
Set-HwSession 1002 $idH2 'busy'
Set-HwSession 1003 $idH3 'waiting'
Set-HwSession 1004 $idH4 'idle'
Set-HwSession 1005 $idH5 'busy'
Set-HwSession 1006 $idH6 'busy' 'interactive' 'cli'
# the workflow chat H4 started after its process did, as the window's own
# process writes it - and nothing written in the last minute
$hwLaunch = [ordered]@{ type = 'user'; timestamp = (Get-Date).AddMinutes(-10).ToUniversalTime().ToString('o'); sessionId = $idH4; entrypoint = 'claude-vscode'
    message = [ordered]@{ role = 'user'; content = @([ordered]@{ type = 'tool_result'; tool_use_id = 'toolu_hw'; content = 'launched' }) }
    toolUseResult = [ordered]@{ status = 'async_launched'; taskId = 'whw0001'; taskType = 'local_workflow' } } | ConvertTo-Json -Compress -Depth 6
[System.IO.File]::AppendAllText($hwFile[$idH4], $hwLaunch + "`n", $utf8)
foreach ($f in $hwFile.Values) { (Get-Item -LiteralPath $f).LastWriteTime = (Get-Date).AddMinutes(-5) }

$hwSeams = @{ Alive = $script:ChatqAliveSeam; Table = $script:ChatProcessTableSeam }
$script:ChatqAliveSeam = { param($e) $true }
$hwT0 = Get-Date '2026-09-27T08:00:00'
function New-HwProc([int]$ProcId, [int]$Parent, [string]$Name, [int]$Minutes) {
    [pscustomobject]@{ ProcessId = $ProcId; ParentProcessId = $Parent; Name = "$Name.exe"; CreationDate = $hwT0.AddMinutes($Minutes) }
}
$hwTable = {
    @((New-HwProc 10 1 'explorer' 0), (New-HwProc 100 10 'Code' 1), (New-HwProc 200 100 'Code' 2), (New-HwProc 300 100 'Code' 2),
        (New-HwProc 400 10 'pwsh' 3), (New-HwProc 1001 200 'claude' 5), (New-HwProc 1002 200 'claude' 5), (New-HwProc 1003 200 'claude' 5),
        (New-HwProc 1004 200 'claude' 5), (New-HwProc 1005 300 'claude' 5), (New-HwProc 1006 400 'claude' 5), (New-HwProc 1007 400 'claude' 6))
}
$script:ChatProcessTableSeam = $hwTable
function Get-HwWhy($Res) { (@($Res.Chats | Sort-Object SessionId | ForEach-Object { "$($_.SessionId.Substring(0, 2))=$($_.Why)$(if ($_.Written) { '+w' })" }) -join ' ') }

$hw = Get-ChatHostWork -HostPid 200 -ConfigDir $hwHome
Check 'a window''s chats: those whose claude runs under its extension host - never another window''s, nor a terminal''s' (
    $hw.Known -and (@($hw.Chats | ForEach-Object SessionId | Sort-Object) -join ',') -eq (@($idH1, $idH2, $idH3, $idH4) -join ',')) (Get-HwWhy $hw)
Check 'each one judged as Test-ChatIdle judges: a turn, a permission prompt, a workflow out while Claude calls the chat idle, and idle' (
    (Get-HwWhy $hw) -eq '1d= 2d=turn 3d=prompt 4d=background') (Get-HwWhy $hw)
$hwB = Get-ChatHostWork -HostPid 300 -ConfigDir $hwHome
Check 'the other window: only its own busy chat' ((Get-HwWhy $hwB) -eq '5d=turn') (Get-HwWhy $hwB)

# the workflow reports back: idle
$hwDone = [ordered]@{ type = 'user'; timestamp = (Get-Date).AddMinutes(-4).ToUniversalTime().ToString('o'); sessionId = $idH4
    message = [ordered]@{ role = 'user'; content = "<task-notification>`n<task-id>whw0001</task-id>`n<status>completed</status>`n</task-notification>" } }
[System.IO.File]::AppendAllText($hwFile[$idH4], (ConvertTo-NodeJson $hwDone) + "`n", $utf8)
(Get-Item -LiteralPath $hwFile[$idH4]).LastWriteTime = (Get-Date).AddMinutes(-4)
$hw2 = Get-ChatHostWork -HostPid 200 -ConfigDir $hwHome
Check 'its task-notification ends the workflow: idle again' ((@($hw2.Chats | Where-Object SessionId -eq $idH4))[0].Why -eq '') (Get-HwWhy $hw2)

# a print-mode claude going into the idle chat, from a terminal: that chat is
# held, though its window's process is idle - and the run itself is no chat of
# the window
Set-HwSession 1007 $idH1 'busy' 'print' 'sdk-cli'
$hw3 = Get-ChatHostWork -HostPid 200 -ConfigDir $hwHome
Remove-Item -LiteralPath (Join-Path $hwSess '1007.json') -Force
# a chatq job running into it, before its claude -p has a registry file
Save-ChatqJob ([pscustomobject]@{ id = 'hostwork-job'; seq = 990; state = 'running'; sessionId = $idH1; title = 'x'; createdAt = (Get-ChatqStamp) })
$hw4 = Get-ChatHostWork -HostPid 200 -ConfigDir $hwHome
Remove-Item -LiteralPath (Join-Path $script:ChatqQueueDir 'hostwork-job.json') -Force
Check 'a queued run going into a chat of the window - its claude -p, or a chatq job running into it - holds that chat' (
    (@($hw3.Chats | Where-Object SessionId -eq $idH1))[0].Why -eq 'run' -and @($hw3.Chats).Count -eq 4 -and
    (@($hw4.Chats | Where-Object SessionId -eq $idH1))[0].Why -eq 'run') "$(Get-HwWhy $hw3) / $(Get-HwWhy $hw4)"
# a chatq job running into a chat no process of the window holds any more -
# a run before it ended the idle one (liveIdle stop, Show-ChatFresh -Away) -
# still holds the window: a tab of it would load that chat part way through
$idH7 = '7d7d7d7d-7d7d-4d7d-8d7d-7d7d7d7d7d7d'
Save-ChatqJob ([pscustomobject]@{ id = 'hostwork-job2'; seq = 991; state = 'running'; sessionId = $idH7; title = 'x'; cwd = $projH; createdAt = (Get-ChatqStamp) })
$hw9 = Get-ChatHostWork -HostPid 999 -ConfigDir $hwHome
$hw9j = ConvertTo-ChatHostWorkJson $hw9
Remove-Item -LiteralPath (Join-Path $script:ChatqQueueDir 'hostwork-job2.json') -Force
Check 'a chatq job running into a chat no process of the window holds: a run all the same, with no pids' (
    @($hw9.Chats).Count -eq 1 -and $hw9.Chats[0].SessionId -eq $idH7 -and $hw9.Chats[0].Why -eq 'run' -and $hw9j -like '*"pids":`[`]*') "$(Get-HwWhy $hw9) / $hw9j"

# Someone's own claude -p going into a chat whose idle process a window's
# Show it ended: noted in data/idle-ended.json with that window's host, it
# holds that window - and no other, and not once the host is another
# process of the same pid. A claude -p registers as interactive, sdk-cli.
Remove-Item -LiteralPath $script:ChatIdleEndedPath -Force -EA SilentlyContinue
Add-ChatIdleEnded -SessionId $idH7 -HostPid 300 -HostStart $hwT0.AddMinutes(2)
Set-HwSession 1008 $idH7 'busy' 'interactive' 'sdk-cli'
$hwE1 = Get-ChatHostWork -HostPid 300 -ConfigDir $hwHome
$hwE2 = Get-ChatHostWork -HostPid 200 -ConfigDir $hwHome
$hwE1n = @($hwE1.Chats | Where-Object SessionId -eq $idH7)
Check 'a claude -p into a chat a window''s idle process was ended for: a run of that window, with no pids - not of another window' (
    (Get-HwWhy $hwE1) -eq '5d=turn 7d=run' -and $hwE1n.Count -eq 1 -and -not @($hwE1n[0].Pids).Count -and
    -not @($hwE2.Chats | Where-Object SessionId -eq $idH7).Count) "$(Get-HwWhy $hwE1) / $(Get-HwWhy $hwE2)"
Remove-Item -LiteralPath (Join-Path $hwSess '1008.json') -Force
$hwE3 = Get-ChatHostWork -HostPid 300 -ConfigDir $hwHome
Set-HwSession 1008 $idH7 'busy' 'interactive' 'sdk-cli'
Add-ChatIdleEnded -SessionId $idH7 -HostPid 300 -HostStart $hwT0.AddMinutes(40)
$hwE4 = Get-ChatHostWork -HostPid 300 -ConfigDir $hwHome
Remove-Item -LiteralPath (Join-Path $hwSess '1008.json') -Force
Check 'with no claude -p going into it, nothing; nor once its host is another process of that pid' (
    (Get-HwWhy $hwE3) -eq '5d=turn' -and (Get-HwWhy $hwE4) -eq '5d=turn') "$(Get-HwWhy $hwE3) / $(Get-HwWhy $hwE4)"
# a note lives while its window does: the same chat and window noted once,
# a host gone or 8 days old dropped as the next is written; a start not
# known goes by the pid
Remove-Item -LiteralPath $script:ChatIdleEndedPath -Force -EA SilentlyContinue
Add-ChatIdleEnded -SessionId $idH1 -HostPid 999 -HostStart $hwT0
Add-ChatIdleEnded -SessionId $idH2 -HostPid 200 -HostStart $hwT0.AddMinutes(2) -Now (Get-Date).AddDays(-8)
Add-ChatIdleEnded -SessionId $idH3 -HostPid 200 -HostStart ([datetime]::MinValue)
Add-ChatIdleEnded -SessionId $idH3 -HostPid 200 -HostStart ([datetime]::MinValue)
Add-ChatIdleEnded -SessionId $idH7 -HostPid 300 -HostStart $hwT0.AddMinutes(2)
$hwNotes = @(Read-ChatIdleEnded)
$hwNoted = (@($hwNotes | ForEach-Object { "$($_.sessionId.Substring(0, 2))@$($_.hostPid)" }) -join ' ')
Check 'the notes: one per chat and window; a gone host and an 8-day-old note dropped; a start not known kept by its pid' (
    $hwNoted -eq '3d@200 7d@300' -and $null -eq $hwNotes[0].hostStart -and (Test-ChatIdleEndedHost $hwNotes[0] (Get-ChatProcessTable)) -and
    -not (Test-ChatIdleEndedHost ([pscustomobject]@{ hostPid = 999 }) (Get-ChatProcessTable))) $hwNoted
# no processes to list, as off Windows or a query that failed: the note
# holds by its pid alone - one run too many waited on, never one missed
$script:ChatProcessTableSeam = { $null }
Set-HwSession 1008 $idH7 'busy' 'interactive' 'sdk-cli'
$hwE5 = Get-ChatHostWork -HostPid 300 -ConfigDir $hwHome
Remove-Item -LiteralPath (Join-Path $hwSess '1008.json') -Force
$script:ChatProcessTableSeam = $hwTable
$hwE5n = @($hwE5.Chats | Where-Object SessionId -eq $idH7)
Check 'processes not known: a noted chat a claude -p goes into still holds its window, by the pid alone' (
    -not $hwE5.Known -and $hwE5n.Count -eq 1 -and $hwE5n[0].Why -eq 'run' -and -not @($hwE5n[0].Pids).Count) (Get-HwWhy $hwE5)
Remove-Item -LiteralPath $script:ChatIdleEndedPath -Force -EA SilentlyContinue

# a tab a reload brought back: its process starts, or ends, and Claude
# writes its transcript with records that carry no timestamp - no turn,
# and not written, though the file's time is now
[System.IO.File]::AppendAllText($hwFile[$idH1], '{"type":"cost-state","sessionId":"' + $idH1 + '","costUSD":0}' + "`n", $utf8)
(Get-Item -LiteralPath $hwFile[$idH1]).LastWriteTime = Get-Date
$hw5t = Get-ChatHostWork -HostPid 200 -ConfigDir $hwHome
# written in the last minute, by a turn: said apart, so the caller can
# leave out the chat a run has just written
$hwTurn = [ordered]@{ type = 'user'; message = [ordered]@{ role = 'user'; content = 'the tool said {"timestamp":"2099-01-01T00:00:00Z"}' }
    uuid = 'hw-turn'; timestamp = (Get-Date).ToUniversalTime().ToString('o') } | ConvertTo-Json -Compress -Depth 6
[System.IO.File]::AppendAllText($hwFile[$idH1], $hwTurn + "`n", $utf8)
$hw5 = Get-ChatHostWork -HostPid 200 -ConfigDir $hwHome
(Get-Item -LiteralPath $hwFile[$idH1]).LastWriteTime = (Get-Date).AddMinutes(-5)
Check 'a transcript only touched this minute - a cost-state record, no turn - is not written' (
    -not (@($hw5t.Chats | Where-Object SessionId -eq $idH1))[0].Written) (Get-HwWhy $hw5t)
Check 'a transcript written this minute by a turn is said apart from why a chat works' (
    (@($hw5.Chats | Where-Object SessionId -eq $idH1))[0].Why -eq '' -and (@($hw5.Chats | Where-Object SessionId -eq $idH1))[0].Written) (Get-HwWhy $hw5)
# the newest record's own time, however the tail begins; a timestamp in a
# record's text is escaped, and never taken for one; none there, the file's
$hwLw = Join-Path $sb 'last-written.jsonl'
$hwOld = (Get-Date).AddHours(-3)
[System.IO.File]::WriteAllText($hwLw, ('x' * 70000) + '","timestamp":"' + $hwOld.ToUniversalTime().ToString('o') + '"}' + "`n" + '{"type":"cost-state"}' + "`n", $utf8)
$lw1 = Get-ChatLastWritten $hwLw
$hwNone2 = Join-Path $sb 'last-written-none.jsonl'
[System.IO.File]::WriteAllText($hwNone2, '{"type":"cost-state"}' + "`n", $utf8)
$lw2 = Get-ChatLastWritten $hwNone2
Check 'when a transcript was last written: its newest record''s timestamp from a tail that begins mid-line; none there, the file''s own time; never later than the file' (
    [Math]::Abs(($lw1 - $hwOld).TotalSeconds) -lt 1 -and $lw2 -eq (Get-Item -LiteralPath $hwNone2).LastWriteTime -and
    (Get-ChatLastWritten $hwLw $hwOld.AddHours(-1)) -eq $hwOld.AddHours(-1) -and $null -eq (Get-ChatLastWritten (Join-Path $sb 'no-such.jsonl'))) "$lw1 / $lw2"

# no parents to read, as off Windows: every VS Code chat may be this window's
$script:ChatProcessTableSeam = { $null }
$hw6 = Get-ChatHostWork -HostPid 200 -ConfigDir $hwHome
$script:ChatProcessTableSeam = $hwTable
Check 'parents not known: not Known, and every VS Code chat listed - another window''s too, never a terminal''s' (
    -not $hw6.Known -and (Get-HwWhy $hw6) -eq '1d= 2d=turn 3d=prompt 4d= 5d=turn') (Get-HwWhy $hw6)
$hw7 = Get-ChatHostWork -HostPid 999 -ConfigDir $hwHome
$hw8 = Get-ChatHostWork -HostPid 200 -ConfigDir (Join-Path $sb 'claude-hw-none')
Check 'a host with no chats, or a home with no registry: none, and known' ($hw7.Known -and -not @($hw7.Chats).Count -and $hw8.Known -and -not @($hw8.Chats).Count)

# what the extension reads: one line, ASCII, the Hangul folder escaped
$hwJson = ConvertTo-ChatHostWorkJson $hw
$hwBack = $hwJson | ConvertFrom-Json
$hwH1 = @($hwBack.chats | Where-Object { $_.sessionId -eq $idH1 })[0]
Check 'the line the extension reads: ASCII JSON, a Hangul path escaped and read back whole' (
    $hwJson -match '^[\x20-\x7E]+$' -and $hwJson.Contains($hwHanEsc) -and $hwBack.hostPid -eq 200 -and $hwBack.known -eq $true -and
    @($hwBack.chats).Count -eq 4 -and $hwH1.file -eq $hwFile[$idH1] -and $hwH1.why -eq '' -and $hwH1.written -eq $false -and
    (@($hwBack.chats | Where-Object { $_.sessionId -eq $idH4 })[0].why -eq 'background') -and (@($hwH1.pids) -join ',') -eq '1001') $hwJson
$hwNone = ConvertTo-ChatHostWorkJson $hw7
Check 'and with no chats, an empty list, not null' ($hwNone -eq '{"hostPid":999,"known":true,"chats":[]}') $hwNone

# the extension's own command, in a PowerShell of its own, as the extension
# runs it: the script loads, one line of JSON comes back, and the note is
# left. The child gets this section's stand-ins for the process table and
# the registry's life, set after the script loads - an extension host 4343
# whose one claude, 1002, has a turn in flight - so the note it leaves can
# only be the command's own doing.
$script:ChatqAliveSeam = $hwSeams.Alive
$script:ChatProcessTableSeam = $hwSeams.Table
$hwExe = (Get-Process -Id $PID).Path
$hwLoader = Join-Path $sb 'tool\Charlie-and-the-chat-factory.ps1'
$hwChildNote = Join-Path $script:ChatHostWorkDir '4343.json'
Remove-Item -LiteralPath $hwChildNote -Force -EA SilentlyContinue
$hwCmd = "`$env:CHATQ_OVERLAY='1'; . '$hwLoader'; " +
"`$script:ChatqAliveSeam = { param(`$e) `$true }; `$script:ChatProcessTableSeam = { @([pscustomobject]@{ ProcessId = 4343; ParentProcessId = 1; Name = 'Code.exe'; CreationDate = (Get-Date).AddMinutes(-9) }, " +
"[pscustomobject]@{ ProcessId = 1002; ParentProcessId = 4343; Name = 'claude.exe'; CreationDate = (Get-Date).AddMinutes(-5) }) }; " +
"Remove-Variable r -EA SilentlyContinue; `$r = Get-ChatHostWork -HostPid 4343 -ConfigDir '$hwHome'; [Console]::Out.WriteLine((ConvertTo-ChatHostWorkJson `$r)); " +
"if (Get-Command Save-ChatHostWorkNote -EA SilentlyContinue) { Save-ChatHostWorkNote `$r -HostStart 1 }"
$hwSw = [System.Diagnostics.Stopwatch]::StartNew()
$hwOut = @(& $hwExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ([Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($hwCmd))) 2>&1 | ForEach-Object { "$_" })
$hwSw.Stop()
$hwLast = @($hwOut | Where-Object { $_.StartsWith('{') }) | Select-Object -Last 1
$hwChild = try { $hwLast | ConvertFrom-Json } catch { $null }
$hwChildN = Read-ChatqJson $hwChildNote
Remove-Item -LiteralPath $hwChildNote -Force -EA SilentlyContinue
Check "the extension's command in a PowerShell of its own: one line of JSON for its host, and the note of the chat at work left behind ($([int]$hwSw.Elapsed.TotalMilliseconds) ms)" (
    $hwChild -and $hwChild.hostPid -eq 4343 -and (@($hwChild.chats | ForEach-Object { "$($_.sessionId)=$($_.why)" }) -join ',') -eq "$idH2=turn" -and
    @($hwOut | Where-Object { $_.StartsWith('{') }).Count -eq 1 -and $hwChildN -and [int]$hwChildN.hostPid -eq 4343 -and
    (@($hwChildN.chats | ForEach-Object { "$($_.sessionId)=$($_.why)" }) -join ',') -eq "$idH2=turn") ($hwOut -join ' | ')

Section 'the chats a reload stopped'
# A look that finds work leaves a note of it (Save-ChatHostWorkNote); once
# that host is gone, the overlay's cut-off look offers to continue what it
# cut off (Get-ChatRestartCutOffs) through the reset ask. Three chats the
# look found working: one cut off mid tool_use, one that finished its turn
# before the reload, and one whose workflow never reported back.
$rsHost = 4242
$rsNow = Get-Date
$rsSince = $rsNow.AddMinutes(-30)
$idR1 = 'e1e1e1e1-e1e1-4e1e-8e1e-e1e1e1e1e1e1'   # cut off mid tool_use
$idR2 = 'e2e2e2e2-e2e2-4e2e-8e2e-e2e2e2e2e2e2'   # its turn finished before the reload
$idR3 = 'e3e3e3e3-e3e3-4e3e-8e3e-e3e3e3e3e3e3'   # a workflow out, never reported
$rsFile = @{}
foreach ($id in $idR1, $idR2, $idR3) { $rsFile[$id] = New-FakeChat $projH $id "Restart $($id.Substring(0, 2))" 0.5 @('go') -HomeDir $hwHome }
$rsUse = [guid]::NewGuid().ToString()
$rsRec = {
    param([string]$Id, [string]$Type, [double]$MinAgo, $Message, $Extra)
    $o = [ordered]@{ parentUuid = $null; isSidechain = $false; type = $Type; uuid = [guid]::NewGuid().ToString(); timestamp = $rsNow.AddMinutes(-$MinAgo).ToUniversalTime().ToString('o')
        cwd = $projH; sessionId = $Id; entrypoint = 'claude-vscode'; message = $Message }
    if ($Extra) { foreach ($k in @($Extra.Keys)) { $o[$k] = $Extra[$k] } }
    $o
}
$rsMid = & $rsRec $idR1 'assistant' 3 ([ordered]@{ role = 'assistant'; content = @([ordered]@{ type = 'tool_use'; id = 'toolu_rs'; name = 'Bash'; input = @{ command = 'make' } }); stop_reason = 'tool_use' })
$rsMid.uuid = $rsUse
[System.IO.File]::AppendAllText($rsFile[$idR1], ($rsMid | ConvertTo-Json -Compress -Depth 8) + "`n", $utf8)
$rsWf = & $rsRec $idR3 'user' 10 ([ordered]@{ role = 'user'; content = @([ordered]@{ type = 'tool_result'; tool_use_id = 'toolu_wf'; content = 'launched' }) }) @{
    toolUseResult = [ordered]@{ status = 'async_launched'; taskId = 'wrs0001'; taskType = 'local_workflow'; workflowName = 'nightly-review' } }
$rsWfSaid = & $rsRec $idR3 'assistant' 10 ([ordered]@{ role = 'assistant'; content = @([ordered]@{ type = 'text'; text = 'started it' }); stop_reason = 'end_turn' })
[System.IO.File]::AppendAllText($rsFile[$idR3], ($rsWf | ConvertTo-Json -Compress -Depth 8) + "`n" + ($rsWfSaid | ConvertTo-Json -Compress -Depth 8) + "`n", $utf8)
$rsLook = [pscustomobject]@{ HostPid = $rsHost; Known = $true; Chats = @(
        [pscustomobject]@{ SessionId = $idR1; Pids = @(5001); Cwd = $projH; Transcript = $rsFile[$idR1]; Why = 'turn'; Written = $true; Since = $rsSince }
        [pscustomobject]@{ SessionId = $idR2; Pids = @(5002); Cwd = $projH; Transcript = $rsFile[$idR2]; Why = 'turn'; Written = $false; Since = $rsSince }
        [pscustomobject]@{ SessionId = $idR3; Pids = @(5003); Cwd = $projH; Transcript = $rsFile[$idR3]; Why = 'background'; Written = $false; Since = $rsSince }
        [pscustomobject]@{ SessionId = $idH1; Pids = @(5004); Cwd = $projH; Transcript = $hwFile[$idH1]; Why = ''; Written = $false; Since = $rsSince }
        [pscustomobject]@{ SessionId = $idH7; Pids = @(); Cwd = $projH; Transcript = $null; Why = 'run'; Written = $false; Since = $null }
    )
}
$rsNote = Join-Path $script:ChatHostWorkDir "$rsHost.json"
$rsStartMs = [DateTimeOffset]::new($rsNow.AddHours(-2)).ToUnixTimeMilliseconds()
Save-ChatHostWorkNote ([pscustomobject]@{ HostPid = $rsHost; Known = $false; Chats = $rsLook.Chats }) -HostStart $rsStartMs
$rsNoneUnknown = -not (Test-Path -LiteralPath $rsNote)
Save-ChatHostWorkNote $rsLook -HostStart $rsStartMs -Now $rsNow.AddMinutes(-2)
$rsN = Read-ChatqJson $rsNote
Check 'a look that finds work leaves its note: the host, its start, when, and each chat at work - a turn, background work - never an idle one or a run' (
    $rsNoneUnknown -and $rsN -and [int]$rsN.hostPid -eq $rsHost -and (ConvertTo-ChatqDate $rsN.hostStart) -and
    (@($rsN.chats | ForEach-Object { "$($_.sessionId.Substring(0, 2))=$($_.why)" }) -join ' ') -eq 'e1=turn e2=turn e3=background' -and
    [int64]$rsN.chats[0].size -eq (Get-Item -LiteralPath $rsFile[$idR1]).Length -and (ConvertTo-ChatqDate $rsN.chats[0].since)) (Get-Content -LiteralPath $rsNote -Raw)

# the host still runs: nothing is offered, whatever its chats' transcripts say
$rsSeam = $script:ChatHostAliveSeam
$script:ChatHostAliveSeam = { param($p, $s) $true }
$rsAlive = @(Get-ChatRestartCutOffs -Live @() -Asked @{} -Jobs @() -Prune -Now $rsNow)
Check 'a host still alive: nothing offered, and its note kept as it is' ($rsAlive.Count -eq 0 -and (Test-Path -LiteralPath $rsNote) -and -not (Read-ChatqJson $rsNote).PSObject.Properties['goneAt']) "$($rsAlive.Count)"
$script:ChatHostAliveSeam = { param($p, $s) $p -ne 4242 }
$rsCache = @{}
$rsCut = @(Get-ChatRestartCutOffs -Live @() -Asked @{} -Jobs @() -Cache $rsCache -Prune -Now $rsNow)
$rsN2 = Read-ChatqJson $rsNote
$rsR1 = @($rsCut | Where-Object Id -eq $idR1)[0]
$rsR3 = @($rsCut | Where-Object Id -eq $idR3)[0]
Check 'the host gone: the chat cut off mid tool_use and the one whose workflow never reported are offered - not the one that finished its turn' (
    (@($rsCut | ForEach-Object { $_.Id.Substring(0, 2) } | Sort-Object) -join ',') -eq 'e1,e3' -and $rsR1.Why -eq 'restart' -and $rsR1.Mid -and
    -not $rsR1.Tasks.Count -and $rsR1.LimitUuid -eq $rsUse -and $rsR1.Path -eq $rsFile[$idR1] -and $rsR1.Title -eq 'Restart e1' -and $null -eq $rsR1.ResetsAt -and
    -not $rsR3.Mid -and @($rsR3.Tasks).Count -eq 1 -and $rsR3.Tasks[0].Kind -eq 'workflow' -and $rsR3.Tasks[0].Note -eq 'nightly-review') "$(@($rsCut | ForEach-Object { "$($_.Id.Substring(0, 2)) mid=$($_.Mid) tasks=$(@($_.Tasks).Count)" }) -join '; ')"
Check 'and the note keeps only those two, with when the host was first found gone' (
    (@($rsN2.chats | ForEach-Object { $_.sessionId.Substring(0, 2) }) -join ',') -eq 'e1,e3' -and (ConvertTo-ChatqDate $rsN2.goneAt)) (Get-Content -LiteralPath $rsNote -Raw)

# The overlay's own pass (Invoke-ChatOverlayCycle) over that note: the
# restart's chats merged into its ask and its orange rows, under
# autoContinue ask and - theirs alone - under on; the answer and the
# console's Continue on them. The sandbox's own cut-offs may join the ask
# under ask, so that one is checked by the restart's part of it. A usage
# stand-in well under the limit; jobs, markers, config and seams put back.
$rsAutoBefore = @(if (Test-Path -LiteralPath $script:ChatqAutoDir) { Get-ChildItem -LiteralPath $script:ChatqAutoDir -File | ForEach-Object Name })
$rsCfgWas = Read-TestFile $script:ChatqConfigPath
$rsSnapWas = Test-Path -LiteralPath $script:ChatOverlayPath
$rsWas = @{ Usage = $script:ChatOverlayUsageSeam; Spawn = $script:ChatqSpawn; Balloon = $script:ChatOverlayBalloonSeam
    Status = ${function:Set-ChatConsoleStatus}; ConNow = ${function:Update-ChatConsoleNow}; Ask = ${function:Update-ChatOverlayAsk}
}
$script:ChatOverlayUsageSeam = { @{ Ok = $true; Status = 200; Windows = @([pscustomobject]@{ Label = '5h'; Percent = 10; ResetsAt = (Get-Date).AddHours(3); Severity = 'normal' }) } }
$script:ChatqSpawn = { $true }
$rsIds = { param($Items) (@($Items | Where-Object { $_ -and $_.Why -eq 'restart' } | ForEach-Object { ([string]$_.Id).Substring(0, 2) } | Sort-Object) -join ',') }
$rsAskNote = { param($Snap) @($Snap.header.notes | Where-Object { $_.PSObject.Properties['kind'] -and $_.kind -eq 'ask' }) }
try {
    $null = Set-ChatqAutoContinue -Value ask
    $cxRa = New-ChatOverlayContext
    $cxRa.WantAsk = $true
    $snRa = Invoke-ChatOverlayCycle $cxRa
    $ntRa = @(& $rsAskNote $snRa)
    $rowRa = @($snRa.rows | Where-Object { $_.key -eq "c:$idR1" })
    Check 'the overlay''s pass, autoContinue ask: the note''s two chats join its ask and its orange rows, the header counts them as the restart''s, and its note says VS Code restarted' (
        $cxRa.Ask -and (& $rsIds $cxRa.Ask.Items) -eq 'e1,e3' -and [int]$snRa.header.ask.restart -eq 2 -and [int]$snRa.header.ask.count -ge 2 -and
        (& $rsIds $cxRa.CutOff) -eq 'e1,e3' -and $rowRa.Count -eq 1 -and $rowRa[0].detail -eq 'cut off - VS Code restarted' -and
        $ntRa.Count -eq 1 -and $ntRa[0].text -like '*VS Code restarted - * can continue') "$(& $rsIds $cxRa.Ask.Items) / $($snRa.header.ask | ConvertTo-Json -Compress) / $($ntRa.text)"
    # the tray's balloon for it, as Update-ChatOverlayAsk says a new ask
    $script:RsBalloons = [System.Collections.Generic.List[object]]::new()
    $script:ChatOverlayBalloonSeam = { param($b) $script:RsBalloons.Add($b) }
    Update-ChatOverlayAsk ([pscustomobject]@{ Ctx = $cxRa; Menu = @{}; Tray = $null; AskRequest = $null; BalloonKind = $null; BalloonKeys = @(); AskMenuKeys = @() })
    $rsBn = @($script:RsBalloons)
    Check 'its balloon: titled by the restart, the chats cut off counted and named' (
        $rsBn.Count -eq 1 -and $rsBn[0].Title -like 'Charlie - *VS Code restarted' -and $rsBn[0].Text -like '* cut off can continue: *. Click to see them.' -and $rsBn[0].Kind -eq 'ask') "$($rsBn | ConvertTo-Json -Compress)"

    $null = Set-ChatqAutoContinue -Value on
    $cxRo = New-ChatOverlayContext
    $cxRo.WantAsk = $true
    $snRo = Invoke-ChatOverlayCycle $cxRo
    $ntRo = @(& $rsAskNote $snRo)
    Check 'autoContinue on: the pass still asks - about the restart''s chats alone, the limit''s left to the switch' (
        $cxRo.Ask -and $cxRo.Ask.Count -eq 2 -and $cxRo.Ask.Restart -eq 2 -and (& $rsIds $cxRo.Ask.Items) -eq 'e1,e3' -and
        [int]$snRo.header.ask.count -eq 2 -and [int]$snRo.header.ask.restart -eq 2 -and $ntRo.Count -eq 1 -and
        $ntRo[0].text -eq 'VS Code restarted - 2 chats it cut off can continue') "$($snRo.header.ask | ConvertTo-Json -Compress) / $($ntRo.text)"
    $rsKeys = @($cxRo.Ask.Keys)
    $crRo = Complete-ChatqResetAsk $cxRo 'continue' $rsKeys
    $crRoJobs = @(Get-ChatqJobs | Where-Object { $_.sessionId -in $idR1, $idR3 -and $_.kind -eq 'prompt' -and [string]$_.rule -eq 'restart' -and $_.state -eq 'queued' })
    $crRoMk = @($rsKeys | ForEach-Object { Read-ChatqJson (Join-Path $script:ChatqAutoDir "$_.json") } | Where-Object { $_ })
    Check 'its answer, continue: a restart prompt job each, the watcher asked, each marked continued with why restart - said with no limit to wait for' (
        @($crRo.Queued).Count -eq 2 -and $crRoJobs.Count -eq 2 -and $crRo.Request -and $crRo.Text -eq 'queued 2 continues ahead of the prompts waiting - one at a time' -and
        @($crRoMk | Where-Object { $_.answer -eq 'continue' -and $_.why -eq 'restart' -and $null -eq $_.resetsAt }).Count -eq 2) "$($crRo.Text) / $($crRoJobs.Count) / $($crRoMk | ConvertTo-Json -Compress)"
    foreach ($j in @($crRo.Queued)) { $null = Remove-ChatqJob (Find-ChatqJob $j.id) -By test }

    # the console's Continue on a restart's row: the list's item knows only
    # the chat, so it goes as the pass's row of it - its prompt, its rule.
    # The window's parts stand in: what it says, and the redraw.
    $script:RsConSaid = $null
    ${function:Set-ChatConsoleStatus} = { param($H, [string]$Text, [string]$Tone = 'dim') $script:RsConSaid = $Text }
    ${function:Update-ChatConsoleNow} = { param($H) }
    ${function:Update-ChatOverlayAsk} = { param($H) }
    $rsH = [pscustomobject]@{ Ctx = $cxRo; Con = [pscustomobject]@{ Request = $null } }
    $rsItem = [pscustomobject]@{ Kind = 'cutoff'; Id = $idR3; Title = 'Restart e3'; Row = $null }
    $rsIsR = Test-ChatConsoleRestartItem $rsH $rsItem
    $rsNotR = Test-ChatConsoleRestartItem $rsH ([pscustomobject]@{ Kind = 'cutoff'; Id = $idR2; Title = 'Restart e2'; Row = $null })
    Invoke-ChatConsoleContinue $rsH @($rsItem)
    $conJob = @(Get-ChatqJobs | Where-Object { $_.sessionId -eq $idR3 -and $_.state -eq 'queued' })
    $conText = if ($conJob.Count) { [string](Read-ChatqPrompt $conJob[0]) } else { '' }
    Check 'the console''s Continue on a restart''s row: a rule-restart prompt that names the workflow, not the bare continue - and its tooltip knows the row' (
        $rsIsR -and -not $rsNotR -and $conJob.Count -eq 1 -and $conJob[0].kind -eq 'prompt' -and [string]$conJob[0].rule -eq 'restart' -and
        $conText -like '*"nightly-review" did not finish*' -and $script:RsConSaid -eq 'queued 1 continue ahead of the prompts waiting') "$rsIsR $rsNotR $($conJob.Count) $($script:RsConSaid) // $conText"
    foreach ($j in $conJob) { $null = Remove-ChatqJob $j -By test }
}
finally {
    ${function:Set-ChatConsoleStatus} = $rsWas.Status
    ${function:Update-ChatConsoleNow} = $rsWas.ConNow
    ${function:Update-ChatOverlayAsk} = $rsWas.Ask
    $script:ChatOverlayUsageSeam = $rsWas.Usage
    $script:ChatqSpawn = $rsWas.Spawn
    $script:ChatOverlayBalloonSeam = $rsWas.Balloon
    Restore-TestFile $script:ChatqConfigPath $rsCfgWas
    if (-not $rsSnapWas) { Remove-Item -LiteralPath $script:ChatOverlayPath -Force -EA SilentlyContinue }
    foreach ($f in @(if (Test-Path -LiteralPath $script:ChatqAutoDir) { Get-ChildItem -LiteralPath $script:ChatqAutoDir -File })) {
        if ($f.Name -notin $rsAutoBefore) { Remove-Item -LiteralPath $f.FullName -Force -EA SilentlyContinue }
    }
}
Check 'and the note is as the passes found it: both chats kept for an answer' (
    (@((Read-ChatqJson $rsNote).chats | ForEach-Object { $_.sessionId.Substring(0, 2) }) -join ',') -eq 'e1,e3') (Get-Content -LiteralPath $rsNote -Raw)

# the ask's tooltips, by what it holds: a limit's chats keep their orange
# rows; a restart's are not offered again once left, and their rows go
$rsLeave = { param($n, $r) Format-ChatqAskLeaveTip @{ Count = $n; Restart = $r } }
$rsChip = @(Get-ChatOverlayChipActions ([pscustomobject]@{ key = 'ask'; kind = 'ask'; provider = ''; sessionId = ''; cwd = ''; count = 2; restart = 2; keys = @('a_1', 'b_2'); titles = @('One', 'Two') }))
Check 'Leave them says what leaving does - rows stay orange for the limit''s, not offered again and gone for a restart''s, both said when both; Continue says a restart''s prompt' (
    (& $rsLeave 2 0) -eq 'Leave them as they are - their rows stay orange; Continue all in the console still continues them' -and
    (& $rsLeave 2 2) -like '*not offered again, and its row goes' -and (& $rsLeave 3 1) -like '*orange rows*not offered again*' -and
    $rsChip[1].Id -eq 'ask-leave' -and $rsChip[1].Tip -eq (& $rsLeave 2 2) -and $rsChip[0].Tip -like '*VS Code restart cut off, saying what it ended*' -and
    (Format-ChatqContinueTip 1 0) -eq "Queue ""$($script:ChatqContinueText)"" for this chat" -and
    (Format-ChatqContinueTip 1 1) -like '*says what the VS Code restart ended, then "Continue from where you left off.", for this chat' -and
    (Format-ChatqContinueTip 3 1) -like "Queue ""$($script:ChatqContinueText)"" for each of them - for those a VS Code restart cut off, *") "$($rsChip[1].Tip) // $(Format-ChatqContinueTip 3 1)"

# the reset ask takes them, with no reset to wait for; worded as a restart
$rsLim = [pscustomobject]@{ Id = 'lim1'; Title = 'limit one'; Why = 'limit'; ResetsAt = $rsNow.AddMinutes(-30); At = $rsNow.AddMinutes(-90); LimitUuid = 'u-lim1'; Path = $null; Cwd = $projH }
$rsAsk = Get-ChatqResetAsk -CutOff $rsCut -Held @{} -Asked @{} -Jobs @() -Now $rsNow
$rsAskMix = Get-ChatqResetAsk -CutOff (@($rsCut) + @($rsLim)) -Held @{} -Asked @{} -Jobs @() -Now $rsNow
$rsAskOn = Get-ChatqResetAsk -CutOff (@($rsCut) + @($rsLim)) -Held @{} -Asked @{} -Jobs @() -Now $rsNow -RestartOnly
$rsAskLim = Get-ChatqResetAsk -CutOff $rsCut -Held @{} -Asked @{} -Jobs @() -Limited $true -Now $rsNow
$rsAtW = Format-ChatOverlayAskAt $rsLim.ResetsAt $rsNow
Check 'the reset ask: the restart''s chats at once, no reset; with a limit''s too, both named; the automatic mode asks about the restart''s alone; nothing while at the limit' (
    $rsAsk.Count -eq 2 -and $rsAsk.Restart -eq 2 -and $null -eq $rsAsk.ResetsAt -and (Format-ChatqAskHead $rsAsk $rsNow) -eq 'VS Code restarted' -and
    (Format-ChatqAskCount $rsAsk) -eq '2 chats it cut off' -and $rsAskMix.Count -eq 3 -and $rsAskMix.Restart -eq 2 -and
    (Format-ChatqAskHead $rsAskMix $rsNow) -eq "limit over at $rsAtW, and VS Code restarted" -and (Format-ChatqAskCount $rsAskMix) -eq '3 chats they cut off' -and
    $rsAskOn.Count -eq 2 -and @($rsAskOn.Items | Where-Object Why -eq 'limit').Count -eq 0 -and $null -eq $rsAskLim) "$($rsAsk.Count)/$($rsAsk.Restart) $(Format-ChatqAskHead $rsAskMix $rsNow)"
$rsSt = Get-ChatqAutoState $rsR1 @() @() ([pscustomobject]@{ Mode = 'on'; On = $true; Chats = @{ $idR1 = [pscustomobject]@{ auto = 'always' } }; Streak = @{}; Since = $rsNow.AddDays(-1) }) @{} $rsNow
Check 'auto-continue never continues one by itself, the switch on and the chat set to always: its state is restart' (
    $rsSt.State -eq 'restart' -and (Format-ChatOverlayCutOff $rsR1 $rsNow) -eq 'cut off - VS Code restarted') "$($rsSt.State) / $(Format-ChatOverlayCutOff $rsR1 $rsNow)"

# the prompt that continues one says what the restart took
$rsP1 = Get-ChatqRestartPrompt $rsR1
$rsP3 = Get-ChatqRestartPrompt $rsR3
Check 'its prompt: the window restarted mid-turn, or the workflow by name that did not finish - then the continue''s own words' (
    $rsP1 -like '*restarted while it worked*mid-turn.*' -and $rsP1 -notlike '*background*' -and $rsP1.EndsWith($script:ChatqContinueText) -and
    $rsP3 -notlike '*mid-turn*' -and $rsP3 -like '*Your background workflow "nightly-review" did not finish*' -and $rsP3.EndsWith($script:ChatqContinueText)) "$rsP1 // $rsP3"

# continued: a prompt job in the chat's own mode, with the cut-off's uuid, ahead of a prompt queued before it
$rsOld = New-ChatqJob -Row (Get-ChatqRowById $idR2 'claude' $rsFile[$idR2] $projH) -Prompt 'an older prompt' -Rule 'test'
$rsGo = Invoke-ChatqContinueChats -Items @($rsR1)
$rsJob = @($rsGo.Queued)[0]
$rsOrder = @(Get-ChatqJobs | Where-Object { $_.id -in $rsOld.Job.id, $rsJob.id } | ForEach-Object { $_.id })
$rsText = [string](Read-ChatqPrompt $rsJob)
$rsAgain = Invoke-ChatqContinueChats -Items @($rsR1)
Check 'Continue: one job, a prompt that says what was lost, the chat''s own mode, the cut-off''s uuid - ahead of the prompts waiting, and never twice' (
    $rsJob -and $rsJob.kind -eq 'prompt' -and $rsJob.rule -eq 'restart' -and -not $rsJob.mode -and $rsJob.restartUuid -eq $rsUse -and
    $rsText.Contains('mid-turn') -and $rsText.EndsWith($script:ChatqContinueText) -and ($rsOrder -join ',') -eq "$($rsJob.id),$($rsOld.Job.id)" -and
    @($rsAgain.Had).Count -eq 1 -and -not @($rsAgain.Queued).Count -and
    (Format-ChatqContinueSay 1 0 -Restart) -eq 'queued 1 continue ahead of the prompts waiting') "$($rsJob.kind) $($rsJob.rule) $($rsJob.restartUuid) $($rsOrder -join ',') // $rsText"
foreach ($j in @($rsOld.Job, $rsJob)) { $null = Remove-ChatqJob $j -By test }
# the watcher sends it only into a chat still where the restart left it
$rsMoved = New-ChatqJob -Row (Get-ChatqRowById $idR2 'claude' $rsFile[$idR2] $projH) -Prompt (Get-ChatqRestartPrompt $rsR1) -Rule 'restart' -NoLinks -Set @{ restartUuid = 'not-its-last-message' }
Invoke-ChatqJob $W (Find-ChatqJob $rsMoved.Job.id)
$rsMovedJ = Find-ChatqJob $rsMoved.Job.id
Check 'the watcher skips the continue of a chat that went on after the restart - its last message no longer the cut-off''s' (
    $rsMovedJ.state -eq 'skipped' -and $rsMovedJ.result.reason -like '*went on after the restart*') "$($rsMovedJ.state) $($rsMovedJ.result.reason)"
$null = Remove-ChatqJob $rsMovedJ -By test

# asked about once: the answer's marker stops it; a chat at work now is kept for later
$rsK1 = Get-ChatqCutKey $rsR1
$null = Save-ChatqAskAnswer -Keys @($rsK1) -Answer leave -Source test -Extra (Get-ChatqAskExtra @($rsR1) @($rsK1))
$rsAsked = Read-ChatqAskState
$rsMk = Read-ChatqJson (Join-Path $script:ChatqAutoDir "$rsK1.json")
$rsBusy = @([pscustomobject]@{ SessionId = $idR3; Status = 'busy'; Kind = 'interactive'; Pid = 6003; StartedAt = [DateTimeOffset]::new($rsNow.AddMinutes(-1)).ToUnixTimeMilliseconds() })
$rsCut2 = @(Get-ChatRestartCutOffs -Live $rsBusy -Asked $rsAsked -Jobs @() -Cache $rsCache -Now $rsNow)
Check 'answered once, a chat is not offered again; one working again is not offered, and kept' (
    $rsCut2.Count -eq 0 -and $rsMk.why -eq 'restart' -and $null -eq $rsMk.resetsAt -and
    (@((Read-ChatqJson $rsNote).chats | ForEach-Object { $_.sessionId.Substring(0, 2) }) -join ',') -eq 'e1,e3') "$($rsCut2.Count)"
# a tab the reload brought back, idle: still offered; a process from before the note: another window held it
$rsBack = @([pscustomobject]@{ SessionId = $idR3; Status = 'idle'; Kind = 'interactive'; Pid = 6003; StartedAt = [DateTimeOffset]::new($rsNow.AddMinutes(-1)).ToUnixTimeMilliseconds() })
$rsOther = @([pscustomobject]@{ SessionId = $idR3; Status = 'idle'; Kind = 'interactive'; Pid = 6004; StartedAt = [DateTimeOffset]::new($rsNow.AddHours(-3)).ToUnixTimeMilliseconds() })
$rsCut3 = @(Get-ChatRestartCutOffs -Live $rsBack -Asked $rsAsked -Jobs @() -Now $rsNow)
$rsCut4 = @(Get-ChatRestartCutOffs -Live $rsOther -Asked $rsAsked -Jobs @() -Now $rsNow)
$rsCut5 = @(Get-ChatRestartCutOffs -Live @() -Asked $rsAsked -Jobs @([pscustomobject]@{ sessionId = $idR3; state = 'queued' }) -Now $rsNow)
Check 'a tab the reload brought back, idle, is still offered; not a chat another window held all along, nor one with a job waiting' (
    (@($rsCut3 | ForEach-Object Id) -join ',') -eq $idR3 -and $rsCut4.Count -eq 0 -and $rsCut5.Count -eq 0) "$($rsCut3.Count) $($rsCut4.Count) $($rsCut5.Count)"
# the chat went on since: no longer cut off, and the note goes with its last chat
$rsOn = & $rsRec $idR3 'user' -1 ([ordered]@{ role = 'user'; content = 'carry on' })
[System.IO.File]::AppendAllText($rsFile[$idR3], ($rsOn | ConvertTo-Json -Compress -Depth 8) + "`n", $utf8)
$rsCut6 = @(Get-ChatRestartCutOffs -Live @() -Asked $rsAsked -Jobs @() -Cache $rsCache -Prune -Now $rsNow.AddMinutes(2))
Check 'a chat that went on after the host went is no cut-off, and the note goes once it holds none' ($rsCut6.Count -eq 0 -and -not (Test-Path -LiteralPath $rsNote)) "$($rsCut6.Count)"
# a note past 12 hours goes unread
Save-ChatHostWorkNote $rsLook -HostStart $rsStartMs -Now $rsNow.AddHours(-13)
$rsCut7 = @(Get-ChatRestartCutOffs -Live @() -Asked @{} -Jobs @() -Prune -Now $rsNow)
Check 'a note over 12 hours old offers nothing, and is removed' ($rsCut7.Count -eq 0 -and -not (Test-Path -LiteralPath $rsNote)) "$($rsCut7.Count)"
# A process from before the note, seen once, may be the old host's own:
# killed, its registry file reads as alive for up to 10 s of the overlay's
# cache. So it is kept, marked heldAt, and offered once it is gone; only a
# look a minute on that still finds one drops the chat. And a chat whose
# last message cannot be read - a transcript of state lines alone here, a
# read that failed in life - decides nothing: it is kept for a later look.
$idR4 = 'e4e4e4e4-e4e4-4e4e-8e4e-e4e4e4e4e4e4'
$rsBare = Join-Path $sb 'restart-bare.jsonl'
[System.IO.File]::WriteAllText($rsBare, '{"type":"cost-state","sessionId":"' + $idR4 + '","costUSD":0}' + "`n", $utf8)
$rsLookH = [pscustomobject]@{ HostPid = $rsHost; Known = $true; Chats = @(
        $rsLook.Chats[0]
        [pscustomobject]@{ SessionId = $idR4; Pids = @(5005); Cwd = $projH; Transcript = $rsBare; Why = 'turn'; Written = $false; Since = $rsSince }
    )
}
Save-ChatHostWorkNote $rsLookH -HostStart $rsStartMs -Now $rsNow
$rsOld1 = @([pscustomobject]@{ SessionId = $idR1; Status = 'idle'; Kind = 'interactive'; Pid = 5001; StartedAt = [DateTimeOffset]::new($rsNow.AddMinutes(-30)).ToUnixTimeMilliseconds() })
$rsT0 = $rsNow.AddMinutes(5)
$rsChatOf = { param($Id) @((Read-ChatqJson $rsNote).chats | Where-Object { $_.sessionId -eq $Id })[0] }
$rsH1 = @(Get-ChatRestartCutOffs -Live $rsOld1 -Asked @{} -Jobs @() -Prune -Now $rsT0)
$rsHeld1 = & $rsChatOf $idR1
$rsH2 = @(Get-ChatRestartCutOffs -Live @() -Asked @{} -Jobs @() -Prune -Now $rsT0.AddSeconds(10))
$rsHeld2 = & $rsChatOf $idR1
$rsH3 = @(Get-ChatRestartCutOffs -Live $rsOld1 -Asked @{} -Jobs @() -Prune -Now $rsT0.AddSeconds(20))
$rsH4 = @(Get-ChatRestartCutOffs -Live $rsOld1 -Asked @{} -Jobs @() -Prune -Now $rsT0.AddMinutes(2))
$rsLeft = @((Read-ChatqJson $rsNote).chats | ForEach-Object { $_.sessionId })
Check 'a process from before the note, seen once: kept and marked, and offered once it is gone - dropped only when a look a minute on still finds one' (
    -not @($rsH1 | Where-Object Id -eq $idR1).Count -and $rsHeld1 -and (ConvertTo-ChatqDate $rsHeld1.heldAt) -and
    @($rsH2 | Where-Object Id -eq $idR1).Count -eq 1 -and $rsHeld2 -and -not $rsHeld2.PSObject.Properties['heldAt'] -and
    -not @($rsH3 | Where-Object Id -eq $idR1).Count -and -not @($rsH4 | Where-Object Id -eq $idR1).Count -and $idR1 -notin $rsLeft) "$($rsH1.Count) $($rsH2.Count) $($rsH3.Count) $($rsH4.Count) / $($rsLeft -join ',')"
Check 'a chat whose last message cannot be read: never offered, and kept in the note for a later look' (
    -not @(@($rsH1) + @($rsH2) + @($rsH4) | Where-Object Id -eq $idR4).Count -and $idR4 -in $rsLeft) ($rsLeft -join ',')
Remove-Item -LiteralPath $rsNote, $rsBare -Force -EA SilentlyContinue
# any look's save removes another host's note past its 12 hours - the
# overlay's prune runs only while it asks or shows cut-offs
$rsStale = Join-Path $script:ChatHostWorkDir '4245.json'
$rsFresh = Join-Path $script:ChatHostWorkDir '4246.json'
foreach ($p in $rsStale, $rsFresh) { [System.IO.File]::WriteAllText($p, '{"v":1,"hostPid":4245,"chats":[]}', $utf8) }
(Get-Item -LiteralPath $rsStale).LastWriteTime = (Get-Date).AddHours(-13)
Save-ChatHostWorkNote ([pscustomobject]@{ HostPid = 4247; Known = $true; Chats = @() })
Check 'a look removes another host''s note past its 12 hours, never a fresh one' (-not (Test-Path -LiteralPath $rsStale) -and (Test-Path -LiteralPath $rsFresh))
Remove-Item -LiteralPath $rsFresh -Force -EA SilentlyContinue
# nothing working at a look: the note goes
Save-ChatHostWorkNote $rsLook -HostStart $rsStartMs
Save-ChatHostWorkNote ([pscustomobject]@{ HostPid = $rsHost; Known = $true; Chats = @($rsLook.Chats | Where-Object { $_.Why -in '', 'run' }) })
Check 'a look that finds every chat idle removes its host''s note' (-not (Test-Path -LiteralPath $rsNote))
$script:ChatHostAliveSeam = $rsSeam
Remove-Item -LiteralPath (Join-Path $script:ChatqAutoDir "$rsK1.json") -Force -EA SilentlyContinue
# the host as a process: its pid, and its start to 5 s - a pid Windows gave
# another process since is no host
$rsMe = (Get-Process -Id $PID).StartTime
Check 'a host is alive while a process has its pid and its start; one started at another time, or no process, is gone' (
    (Test-ChatHostAlive $PID $rsMe.AddSeconds(2)) -and (Test-ChatHostAlive $PID $rsMe.ToUniversalTime().ToString('o')) -and (Test-ChatHostAlive $PID $null) -and
    -not (Test-ChatHostAlive $PID $rsMe.AddMinutes(-10)) -and -not (Test-ChatHostAlive 0 $null) -and -not (Test-ChatHostAlive 2147483000 $null))

# what owes an answer, as Test-ChatTranscriptBusy reads it
$rsT = { param($Type, $Text, $Stop) [pscustomobject]@{ Type = $Type; Text = $Text; StopReason = $Stop } }
Check 'a last message owes an answer: a tool_use, a prompt, a tool''s result - not an answer with or without a stop reason, a turn you stopped, a slash command''s records' (
    (Test-ChatRestartMid (& $rsT 'assistant' '' 'tool_use')) -and (Test-ChatRestartMid (& $rsT 'user' 'do it' $null)) -and (Test-ChatRestartMid (& $rsT 'user' '' $null)) -and
    -not (Test-ChatRestartMid (& $rsT 'assistant' 'done' 'end_turn')) -and -not (Test-ChatRestartMid (& $rsT 'assistant' 'done' $null)) -and
    -not (Test-ChatRestartMid (& $rsT 'user' '[Request interrupted by user]' $null)) -and -not (Test-ChatRestartMid (& $rsT 'user' '<command-name>/cost</command-name>' $null)) -and
    -not (Test-ChatRestartMid (& $rsT 'user' '<local-command-stdout>ok</local-command-stdout>' $null)) -and -not (Test-ChatRestartMid $null))
