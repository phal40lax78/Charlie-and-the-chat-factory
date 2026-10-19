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
# the one reader of each transcript field every copy now calls, Claude's
# records and Codex's alike: a Codex rollout spaces its colons, Claude's not
$csClaude = '{"type":"user","cwd":"C:\\p\\one","permissionMode":"plan","message":{"role":"user","content":"say \"timestamp\":\"2099-01-01T00:00:00Z\" and \"cwd\":\"C:\\\\fake\""},"timestamp":"2026-01-02T03:04:05.000Z"}' + "`n" +
    '{"type":"user","cwd":"c:\\p\\one","permissionMode":"acceptEdits","timestamp":"2026-01-02T03:05:00.000Z"}' + "`n" + '{"type":"cost-state"}' + "`n" + '{"type":"mode","mode":"normal"}'
$csCodex = '{"timestamp":"2026-02-01T00:00:00.000Z","type":"session_meta","payload":{"cwd": "D:\\work\\x"}}' + "`n" + '{"timestamp":"2026-02-01T00:10:00.000Z","type":"turn_context","payload":{"cwd": "D:\\work\\y"}}'
$csAt = Get-ChatLastStamp $csClaude
$csCwds = @(Get-ChatCwds $csClaude)
Check 'the shared readers: the last timestamp, as local time, never later than a cap; every cwd in order, unescaped; the last mode - none read from a message''s text' (
    $csAt -eq [datetime]::Parse('2026-01-02T03:05:00Z').ToLocalTime() -and (Get-ChatLastStamp $csClaude ([datetime]'2000-01-01')) -eq [datetime]'2000-01-01' -and
    $null -eq (Get-ChatLastStamp '{"type":"mode"}') -and ($csCwds -join '|') -eq 'C:\p\one|c:\p\one' -and (Get-ChatLastMode $csClaude) -eq 'acceptEdits' -and
    $null -eq (Get-ChatLastMode '{"type":"mode"}') -and @(Get-ChatCwds '{"type":"mode"}').Count -eq 0) "$csAt / $($csCwds -join '|') / $(Get-ChatLastMode $csClaude)"
Check 'and a Codex rollout''s, its colons spaced' (
    (Get-ChatLastStamp $csCodex) -eq [datetime]::Parse('2026-02-01T00:10:00Z').ToLocalTime() -and (@(Get-ChatCwds $csCodex) -join '|') -eq 'D:\work\x|D:\work\y') (@(Get-ChatCwds $csCodex) -join '|')

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
Check 'the title read from the transcript, once: kept with the look, not taken from the index' (
    $rsCache["4242|$idR1"].Look.Title -eq 'Restart e1') "$($rsCache["4242|$idR1"].Look.Title)"

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
# A finished answer last, and a note that names no background work: its turn
# ended before the window went, so the whole transcript is not read for work
# left out - a workflow it started is found where the note says background.
# The background reader (Update-ChatBackgroundScan) counted.
$idR5 = 'e5e5e5e5-e5e5-4e5e-8e5e-e5e5e5e5e5e5'
$rsFile[$idR5] = New-FakeChat $projH $idR5 'Restart e5' 0.5 @('go') -HomeDir $hwHome
$rsWf5 = & $rsRec $idR5 'user' 10 ([ordered]@{ role = 'user'; content = @([ordered]@{ type = 'tool_result'; tool_use_id = 'toolu_wf5'; content = 'launched' }) }) @{
    toolUseResult = [ordered]@{ status = 'async_launched'; taskId = 'wrs0005'; taskType = 'local_workflow'; workflowName = 'weekly-review' } }
$rsWf5Said = & $rsRec $idR5 'assistant' 10 ([ordered]@{ role = 'assistant'; content = @([ordered]@{ type = 'text'; text = 'started it' }); stop_reason = 'end_turn' })
[System.IO.File]::AppendAllText($rsFile[$idR5], ($rsWf5 | ConvertTo-Json -Compress -Depth 8) + "`n" + ($rsWf5Said | ConvertTo-Json -Compress -Depth 8) + "`n", $utf8)
$rsLook5 = { param([string]$Why) [pscustomobject]@{ HostPid = $rsHost; Known = $true; Chats = @([pscustomobject]@{ SessionId = $idR5; Pids = @(5006); Cwd = $projH; Transcript = $rsFile[$idR5]; Why = $Why; Written = $false; Since = $rsSince }) } }
$rsScanWas = ${function:Update-ChatBackgroundScan}
$script:RsScans = 0
${function:Update-ChatBackgroundScan} = { param([hashtable]$State, [string]$Path, [int64]$MaxBytes = 8MB) $script:RsScans++; & $rsScanWas $State $Path $MaxBytes }
try {
    Save-ChatHostWorkNote (& $rsLook5 'turn') -HostStart $rsStartMs -Now $rsNow.AddMinutes(-2)
    $rsE1 = @(Get-ChatRestartCutOffs -Live @() -Asked @{} -Jobs @() -Now $rsNow)
    $rsE1n = $script:RsScans
    Save-ChatHostWorkNote (& $rsLook5 'background') -HostStart $rsStartMs -Now $rsNow.AddMinutes(-2)
    $rsE2 = @(Get-ChatRestartCutOffs -Live @() -Asked @{} -Jobs @() -Now $rsNow)
    $rsE2n = $script:RsScans
}
finally { ${function:Update-ChatBackgroundScan} = $rsScanWas; Remove-Item -LiteralPath $rsNote -Force -EA SilentlyContinue }
Check 'a finished answer last, the note naming no background work: its transcript not read for work left out, nothing offered; a note that says background reads it once, and offers the workflow out' (
    $rsE1.Count -eq 0 -and $rsE1n -eq 0 -and $rsE2.Count -eq 1 -and $rsE2[0].Id -eq $idR5 -and -not $rsE2[0].Mid -and @($rsE2[0].Tasks).Count -eq 1 -and
    $rsE2[0].Tasks[0].Note -eq 'weekly-review' -and $rsE2n -eq 1) "$($rsE1.Count) $rsE1n $($rsE2.Count) $rsE2n"
# Stopped by hand with its workflow still out - Claude Code 2.1.291 lets one
# run on past a Stop - and the note saying background: your Stop is last, so
# the window going offers nothing of it
$idR6 = 'e6e6e6e6-e6e6-4e6e-8e6e-e6e6e6e6e6e6'
$rsFile[$idR6] = New-FakeChat $projH $idR6 'Restart e6' 0.5 @('go') -HomeDir $hwHome
$rsWf6 = & $rsRec $idR6 'user' 10 ([ordered]@{ role = 'user'; content = @([ordered]@{ type = 'tool_result'; tool_use_id = 'toolu_wf6'; content = 'launched' }) }) @{
    toolUseResult = [ordered]@{ status = 'async_launched'; taskId = 'wrs0006'; taskType = 'local_workflow'; workflowName = 'stopped-review' } }
$rsStop6 = & $rsRec $idR6 'user' 9 ([ordered]@{ role = 'user'; content = @([ordered]@{ type = 'text'; text = '[Request interrupted by user]' }) })
[System.IO.File]::AppendAllText($rsFile[$idR6], ($rsWf6 | ConvertTo-Json -Compress -Depth 8) + "`n" + ($rsStop6 | ConvertTo-Json -Compress -Depth 8) + "`n", $utf8)
Save-ChatHostWorkNote ([pscustomobject]@{ HostPid = $rsHost; Known = $true; Chats = @([pscustomobject]@{ SessionId = $idR6; Pids = @(5007); Cwd = $projH; Transcript = $rsFile[$idR6]; Why = 'background'; Written = $false; Since = $rsSince }) }) -HostStart $rsStartMs -Now $rsNow.AddMinutes(-2)
$rsS6 = @(Get-ChatRestartCutOffs -Live @() -Asked @{} -Jobs @() -Now $rsNow)
$rsS6Open = @(Get-ChatBackgroundTasks $rsFile[$idR6])
Remove-Item -LiteralPath $rsNote -Force -EA SilentlyContinue
Check 'a chat you stopped last, its workflow still out and the note saying background: nothing offered' (
    $rsS6.Count -eq 0 -and $rsS6Open.Count -eq 1) "$($rsS6.Count) offered / $($rsS6Open.Count) open"
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
Check 'stopped by hand: your Stop or Esc mid-answer or mid-tool - not a prompt, nor an answer that quotes it' (
    (Test-ChatStoppedByHand (& $rsT 'user' '[Request interrupted by user]' $null)) -and (Test-ChatStoppedByHand (& $rsT 'user' ' [Request interrupted by user for tool use]' $null)) -and
    -not (Test-ChatStoppedByHand (& $rsT 'user' 'do it' $null)) -and -not (Test-ChatStoppedByHand (& $rsT 'assistant' '[Request interrupted by user]' 'end_turn')) -and
    -not (Test-ChatStoppedByHand $null))

Section 'what took a window down'
# A window that runs out of memory or crashes goes with no look of the
# extension's before it. So the Windows overlay's own passes keep the note of
# what each window's chats are doing (Update-ChatHostWorkNotes), VS Code's own
# log says what took the window down (Get-ChatHostEndCause), and every wording
# of its cut-offs says so; config autoContinueCrash, off unless chosen,
# continues them by itself (Invoke-ChatqCrashContinue). And the panel says
# when Windows' memory runs short (Update-ChatOverlayMemory), while there is
# time to close something. VS Code's logs are the sandbox's own; seams,
# config, jobs, markers and notes are put back.
$ecWas = @{ Alive = $script:ChatHostAliveSeam; Logs = $script:ChatHostLogRootsSeam; Table = $script:ChatProcessTableSeam; Mem = $script:ChatMemorySeam
    Top = $script:ChatMemoryTopSeam; Usage = $script:ChatOverlayUsageSeam; Spawn = $script:ChatqSpawn; Balloon = $script:ChatOverlayBalloonSeam
    Sums = $script:ChatMemorySumsSeam
}
$ecCfgWas = Read-TestFile $script:ChatqConfigPath
$ecStateWas = Read-TestFile $script:ChatqAutoPath
$ecNow = Get-Date

# VS Code's main.log: a session folder each for Code and Code - Insiders, its
# lines that many seconds before now
$ecRoot = Join-Path $sb 'code-logs'
$ecCode = Join-Path $ecRoot 'Code\logs'
$ecIns = Join-Path $ecRoot 'Code - Insiders\logs'
$ecLine = { param([double]$Sec, [string]$Level, [string]$Text) "$($ecNow.AddSeconds($Sec).ToString('yyyy-MM-dd HH:mm:ss.fff', [System.Globalization.CultureInfo]::InvariantCulture)) [$Level] $Text" }
$ecLog = {
    param([string]$Root, [string]$Session, [string[]]$Lines)
    $d = Join-Path $Root $Session
    $null = New-Item -ItemType Directory -Path $d -Force
    $p = Join-Path $d 'main.log'
    [System.IO.File]::WriteAllText($p, (($Lines -join "`n") + "`n"), $utf8)
    $p
}
$null = & $ecLog $ecCode '20261014T080000' @(
    (& $ecLine -330 'info' 'Extension host with pid 7003 exited with code: 0, signal: unknown.')
    (& $ecLine -250 'error' 'CodeWindow: renderer process gone (reason: oom, code: -536870904)')
    (& $ecLine -235 'info' 'Extension host with pid 7005 exited with code: 0, signal: unknown.')
    # a file watcher's crash, its pid the host's here: only its type tells it apart
    (& $ecLine -200 'error' "[UtilityProcess id: 3, type: fileWatcher, pid: 7004]: crashed with code -36861 and reason 'crashed'")
    (& $ecLine -199 'info' 'Extension host with pid 7004 exited with code: 0, signal: unknown.')
    (& $ecLine -120 'error' "[UtilityProcess id: 10, type: extensionHost, pid: 7002]: crashed with code -36861 and reason 'crashed'")
    (& $ecLine -120 'info' 'Extension host with pid 7002 exited with code: 18446744073709515000, signal: unknown.')
    (& $ecLine -30 'error' 'CodeWindow: renderer process gone (reason: oom, code: -536870904)')
    (& $ecLine -27 'info' 'Extension host with pid 7001 exited with code: 0, signal: unknown.'))
$ecMainI = & $ecLog $ecIns '20261014T090000' @(
    (& $ecLine -60 'error' 'CodeWindow: renderer process gone (reason: crashed, code: -1073741819)')
    (& $ecLine -58 'info' 'Extension host with pid 7006 exited with code: 0, signal: unknown.'))
$script:EcRoots = @($ecCode, $ecIns)
$script:ChatHostLogRootsSeam = { $script:EcRoots }
$ecOf = { param([int]$HostPid, [datetime]$From = $ecNow.AddMinutes(-10), [datetime]$To = $ecNow) Get-ChatHostEndCause $HostPid $From $To }
Check 'VS Code''s log says why a host went: out of memory, its window''s renderer gone just before a plain exit; a crash, by its exit code and crash line, or its renderer crashed - Code - Insiders'' log read too' (
    (& $ecOf 7001) -eq 'oom' -and (& $ecOf 7002) -eq 'crash' -and (& $ecOf 7006) -eq 'crash') "$(& $ecOf 7001) $(& $ecOf 7002) $(& $ecOf 7006)"
Check 'and nothing for a reload, a file watcher''s crash, a renderer gone 15 s before, or no host' (
    (& $ecOf 7003) -eq '' -and (& $ecOf 7004) -eq '' -and (& $ecOf 7005) -eq '' -and (& $ecOf 0) -eq '') "$(& $ecOf 7003) $(& $ecOf 7004) $(& $ecOf 7005)"
# A host gone whose exit the log has yet to name - a pid another starts
# with, one never named, its exit before the time asked or after it - waits
# for the line, which a VS Code short of memory writes seconds late; with
# no log to read, nothing.
$script:EcRoots = @()
$ecNoLog = & $ecOf 7009
$script:EcRoots = @($ecCode, $ecIns)
Check 'not known yet while the log has yet to name the host''s exit - a pid another starts with, one never named, its exit before the time asked or after it; nothing with no log to read' (
    (& $ecOf 700) -eq 'pending' -and (& $ecOf 7009) -eq 'pending' -and (& $ecOf 7001 $ecNow.AddSeconds(-20)) -eq 'pending' -and
    (& $ecOf 7001 $ecNow.AddMinutes(-10) $ecNow.AddSeconds(-29)) -eq 'pending' -and $ecNoLog -eq '') "$(& $ecOf 700) $(& $ecOf 7009) $(& $ecOf 7001 $ecNow.AddSeconds(-20)) '$ecNoLog'"
(Get-Item -LiteralPath $ecMainI).LastWriteTime = $ecNow.AddHours(-1)
$ecOldI = & $ecOf 7006
(Get-Item -LiteralPath $ecMainI).LastWriteTime = $ecNow
Check 'a log session not written since a minute before the time asked is not read' ($ecOldI -eq 'pending' -and (& $ecOf 7006) -eq 'crash') $ecOldI
# A window closed just after another ran out of memory: two plain exits in
# the 10 s after one renderer's line, and neither window is known. A
# renderer gone just before the time asked still counts - a note can be
# written between it and its host's exit - and it is not known yet while
# the 10 s after it are not all in the log, nor for 5 s after them.
$null = & $ecLog $ecCode '20261014T100000' @(
    (& $ecLine -500 'error' 'CodeWindow: renderer process gone (reason: oom, code: -536870904)')
    (& $ecLine -498 'info' 'Extension host with pid 7011 exited with code: 0, signal: unknown.')
    (& $ecLine -495 'info' 'Extension host with pid 7012 exited with code: 0, signal: unknown.')
    (& $ecLine -450 'error' 'CodeWindow: renderer process gone (reason: oom, code: -536870904)')
    (& $ecLine -443 'info' 'Extension host with pid 7013 exited with code: 0, signal: unknown.'))
Check 'a window closed just after another ran out of memory: neither is known; a renderer gone just before the time asked still counts; not known yet until the 10 s after it are in the log, and 5 s more' (
    (& $ecOf 7011) -eq '' -and (& $ecOf 7012) -eq '' -and (& $ecOf 7013 $ecNow.AddSeconds(-447)) -eq 'oom' -and
    (& $ecOf 7001 $ecNow.AddMinutes(-10) $ecNow.AddSeconds(-16)) -eq 'pending' -and (& $ecOf 7001 $ecNow.AddMinutes(-10) $ecNow.AddSeconds(-15)) -eq 'oom') (
    "$(& $ecOf 7011) $(& $ecOf 7012) $(& $ecOf 7013 $ecNow.AddSeconds(-447)) $(& $ecOf 7001 $ecNow.AddMinutes(-10) $ecNow.AddSeconds(-16))")
# The same, the closed window's exit written late by a VS Code short of
# memory: in the 5 s after the 10 s, the log not yet holding it, the window
# that ran out of memory is no surer - taken for the only one, it would
# say so for a window closed by hand; once the line is in, neither is known.
$ecLag = { param([switch]$Late) & $ecLog $ecCode '20261014T110000' @(
        (& $ecLine -590 'error' 'CodeWindow: renderer process gone (reason: oom, code: -536870904)')
        (& $ecLine -587 'info' 'Extension host with pid 7041 exited with code: 0, signal: unknown.')
        if ($Late) { (& $ecLine -582 'info' 'Extension host with pid 7042 exited with code: 0, signal: unknown.') }) }
$null = & $ecLag
$ecLag0 = & $ecOf 7041 $ecNow.AddMinutes(-10) $ecNow.AddSeconds(-579)
$null = & $ecLag -Late
$ecLag1 = & $ecOf 7041 $ecNow.AddMinutes(-10) $ecNow.AddSeconds(-575)
$ecLag2 = & $ecOf 7042 $ecNow.AddMinutes(-10) $ecNow.AddSeconds(-575)
Check 'the closed window''s exit written late: not known yet 1 s past the 10 s, where the log still lacks it; once in, neither window known' (
    $ecLag0 -eq 'pending' -and $ecLag1 -eq '' -and $ecLag2 -eq '') "'$ecLag0' '$ecLag1' '$ecLag2'"

# A note of a window that ran out of memory, its chat the one cut off mid
# tool_use: with no VS Code log to read, offered as a restart's and the cause
# looked for again; kept once the log says
$script:EcDead = @(7001, 7002, 7003)
$script:ChatHostAliveSeam = { param($p, $s) [int]$p -notin $script:EcDead }
$ecNote = { param([int]$HostPid) Join-Path $script:ChatHostWorkDir "$HostPid.json" }
$ecSave = { param([int]$HostPid, [datetime]$At) Save-ChatHostWorkNote ([pscustomobject]@{ HostPid = $HostPid; Known = $true; Chats = @($rsLook.Chats[0]) }) -HostStart $rsStartMs -Now $At -By overlay }
& $ecSave 7001 $ecNow.AddMinutes(-2)
$script:EcRoots = @()
$ecCut0 = @(Get-ChatRestartCutOffs -Live @() -Asked @{} -Jobs @() -Prune -Now $ecNow)
$ecN0 = Read-ChatqJson (& $ecNote 7001)
$script:EcRoots = @($ecCode, $ecIns)
$ecCut1 = @(Get-ChatRestartCutOffs -Live @() -Asked @{} -Jobs @() -Prune -Now $ecNow.AddSeconds(30))
$ecN1 = Read-ChatqJson (& $ecNote 7001)
$ecRow = $ecCut1[0]
Check 'with no VS Code log to read: a window''s chat a restart''s at once, and nothing kept; once the log says out of memory, the row says so and the note keeps it' (
    $ecCut0.Count -eq 1 -and $ecCut0[0].Cause -eq '' -and $ecN0 -and -not $ecN0.PSObject.Properties['cause'] -and
    $ecCut1.Count -eq 1 -and $ecRow.Id -eq $idR1 -and $ecRow.Cause -eq 'oom' -and $ecN1 -and $ecN1.cause -eq 'oom') "$(@($ecCut1 | ForEach-Object { "$($_.Id.Substring(0, 2))=$($_.Cause)" }) -join ' ') // $(Read-TestFile (& $ecNote 7001))"
$ecSt = Get-ChatqAutoState $ecRow @() @() ([pscustomobject]@{ Mode = 'on'; On = $true; Chats = @{}; Streak = @{}; Since = $ecNow.AddDays(-1) }) @{} $ecNow
$ecAsk = Get-ChatqResetAsk -CutOff $ecCut1 -Held @{} -Asked @{} -Jobs @() -Now $ecNow
$ecAskMix = Get-ChatqResetAsk -CutOff (@($ecCut1) + @($rsLim)) -Held @{} -Asked @{} -Jobs @() -Now $ecNow
$ecP = [string](Get-ChatqRestartPrompt $ecRow)
Check 'every wording of it says VS Code ran out of memory: the row, auto-continue''s state, the reset ask''s head - a limit''s beside it too - and the prompt that continues it' (
    (Format-ChatOverlayCutOff $ecRow $ecNow) -eq 'cut off - VS Code ran out of memory' -and $ecSt.State -eq 'restart' -and
    $ecSt.Words -eq 'cut off - VS Code ran out of memory' -and $ecSt.Why -like 'VS Code ran out of memory while it worked - *' -and
    $ecAsk.Cause -eq 'oom' -and (Format-ChatqAskHead $ecAsk $ecNow) -eq 'VS Code ran out of memory' -and
    (Format-ChatqAskHead $ecAskMix $ecNow) -eq "limit over at $(Format-ChatOverlayAskAt $rsLim.ResetsAt $ecNow), and VS Code ran out of memory" -and
    $ecP.StartsWith('VS Code ran out of memory while this chat worked, which ended its process mid-turn.') -and $ecP.EndsWith($script:ChatqContinueText)) "$($ecSt.Words) // $(Format-ChatqAskHead $ecAskMix $ecNow) // $ecP"
$ecMk = { param([string]$Id, [string]$Cause) [pscustomobject]@{ Id = $Id; Title = 'T'; Why = 'restart'; At = $ecNow; LimitUuid = "u$Id"; Cause = $Cause } }
$ecCauseOf = { param([object[]]$Rows) [string](Get-ChatqResetAsk -CutOff $Rows -Held @{} -Asked @{} -Jobs @() -Now $ecNow).Cause }
$ecCr = [pscustomobject]@{ Id = $idR2; Why = 'restart'; Cause = 'crash'; Mid = $false; Tasks = @() }
Check 'for many windows the ask says out of memory when every one did, crashed when each did one of the two, a restart when any restarted; a crash said as one' (
    (& $ecCauseOf @((& $ecMk 'a1' 'oom'), (& $ecMk 'a2' 'oom'))) -eq 'oom' -and (& $ecCauseOf @((& $ecMk 'a1' 'oom'), (& $ecMk 'a2' 'crash'))) -eq 'crash' -and
    (& $ecCauseOf @((& $ecMk 'a1' 'crash'), (& $ecMk 'a2' ''))) -eq '' -and
    (Format-ChatqAskHead ([pscustomobject]@{ count = 2; restart = 2; cause = 'crash'; resetsAt = $null })) -eq 'VS Code crashed' -and
    (Format-ChatOverlayCutOff $ecCr) -eq 'cut off - VS Code crashed' -and
    (Get-ChatqRestartPrompt $ecCr) -eq "VS Code crashed while this chat worked, which ended its process. $($script:ChatqContinueText)") (Get-ChatqRestartPrompt $ecCr)
# a reload's note: the log names nothing - looked for again for two minutes,
# in case its lines come late, then kept as none
Remove-Item -LiteralPath (& $ecNote 7001) -Force -EA SilentlyContinue
& $ecSave 7003 $ecNow.AddMinutes(-10)
$ecRl0 = @(Get-ChatRestartCutOffs -Live @() -Asked @{} -Jobs @() -Prune -Now $ecNow)
$ecRn0 = Read-ChatqJson (& $ecNote 7003)
$ecRl1 = @(Get-ChatRestartCutOffs -Live @() -Asked @{} -Jobs @() -Prune -Now $ecNow.AddSeconds(125))
$ecRn1 = Read-ChatqJson (& $ecNote 7003)
Check 'a reload: no cause in VS Code''s log - offered at once, no wait; looked for again for two minutes, then kept as none; the row says VS Code restarted' (
    $ecRl0.Count -eq 1 -and $ecRl0[0].Cause -eq '' -and $ecRn0 -and -not $ecRn0.PSObject.Properties['cause'] -and $ecRl1.Count -eq 1 -and
    $ecRn1 -and $ecRn1.PSObject.Properties['cause'] -and $ecRn1.cause -eq '' -and (Format-ChatOverlayCutOff $ecRl1[0]) -eq 'cut off - VS Code restarted') "$(Read-TestFile (& $ecNote 7003))"
Remove-Item -LiteralPath (& $ecNote 7003) -Force -EA SilentlyContinue
# While the log has yet to say - the 10 s after the renderer's line and 5 s
# more not all in, or the host's exit not logged yet - the note's chat is no
# row: its host goes into -Pending, the note keeps goneAt and no cause, and
# a pass without -Prune - a host's -Peek - waits too, before goneAt is kept
# or after, and keeps nothing. Once the log is sure, the row says why; 30 s
# on from goneAt it waits no more, and says a restart.
& $ecSave 7001 $ecNow.AddMinutes(-2)
$ecPdP = @{}
$ecHdP = @(Get-ChatRestartCutOffs -Live @() -Asked @{} -Jobs @() -Pending $ecPdP -Now $ecNow.AddSeconds(-26))
$ecHnP = Read-ChatqJson (& $ecNote 7001)
$ecPd0 = @{}
$ecHd0 = @(Get-ChatRestartCutOffs -Live @() -Asked @{} -Jobs @() -Pending $ecPd0 -Prune -Now $ecNow.AddSeconds(-25))
$ecHn0 = Read-ChatqJson (& $ecNote 7001)
$ecPd1 = @{}
$ecHd1 = @(Get-ChatRestartCutOffs -Live @() -Asked @{} -Jobs @() -Pending $ecPd1 -Now $ecNow.AddSeconds(-17))
$ecHd2 = @(Get-ChatRestartCutOffs -Live @() -Asked @{} -Jobs @() -Prune -Now $ecNow.AddSeconds(-14))
$ecHn2 = Read-ChatqJson (& $ecNote 7001)
Remove-Item -LiteralPath (& $ecNote 7001) -Force -EA SilentlyContinue
Check 'the log not sure yet: no row, its host pending, the note keeping goneAt and no cause - a pass without -Prune waits too, before goneAt is kept and 3 s past the 10 s, keeping nothing; once sure, the row says out of memory' (
    $ecHdP.Count -eq 0 -and $ecPdP[7001] -and $ecHnP -and -not $ecHnP.PSObject.Properties['goneAt'] -and
    $ecHd0.Count -eq 0 -and $ecPd0[7001] -and $ecHn0 -and (ConvertTo-ChatqDate $ecHn0.goneAt) -and -not $ecHn0.PSObject.Properties['cause'] -and @($ecHn0.chats).Count -eq 1 -and
    $ecHd1.Count -eq 0 -and $ecPd1[7001] -and $ecHd2.Count -eq 1 -and $ecHd2[0].Cause -eq 'oom' -and $ecHn2 -and $ecHn2.cause -eq 'oom') (
    "$($ecHdP.Count) $($ecHd0.Count) $($ecHd1.Count) $($ecHd2.Count) // $(Read-TestFile (& $ecNote 7001))")
$script:EcDead = @(7001, 7002, 7003, 7009)
& $ecSave 7009 $ecNow.AddMinutes(-2)
# charlie -Print keeps no notes (-Once): before a host's pass keeps
# goneAt it waits for nothing, after it as the host does
$ecOn0 = @(Get-ChatRestartCutOffs -Live @() -Asked @{} -Jobs @() -Once -Now $ecNow)
$ecOnN = Read-ChatqJson (& $ecNote 7009)
$ecPd3 = @{}
$ecHd3 = @(Get-ChatRestartCutOffs -Live @() -Asked @{} -Jobs @() -Pending $ecPd3 -Prune -Now $ecNow)
$ecOn1 = @(Get-ChatRestartCutOffs -Live @() -Asked @{} -Jobs @() -Once -Now $ecNow.AddSeconds(5))
$ecPd5 = @{}
$ecHd5 = @(Get-ChatRestartCutOffs -Live @() -Asked @{} -Jobs @() -Pending $ecPd5 -Prune -Now $ecNow.AddSeconds(29))
$ecPd4 = @{}
$ecHd4 = @(Get-ChatRestartCutOffs -Live @() -Asked @{} -Jobs @() -Pending $ecPd4 -Prune -Now $ecNow.AddSeconds(31))
$ecHn4 = Read-ChatqJson (& $ecNote 7009)
Remove-Item -LiteralPath (& $ecNote 7009) -Force -EA SilentlyContinue
Check 'a host whose exit the log never names - its VS Code''s own process ended: waited for 30 s from goneAt - still at 29 s - then a restart''s row, the cause still looked for' (
    $ecHd3.Count -eq 0 -and $ecPd3[7009] -and $ecHd5.Count -eq 0 -and $ecPd5[7009] -and $ecHd4.Count -eq 1 -and $ecHd4[0].Cause -eq '' -and -not $ecPd4.Count -and
    $ecHn4 -and -not $ecHn4.PSObject.Properties['cause']) "$($ecHd3.Count) $($ecHd5.Count) $($ecHd4.Count) // $(Read-TestFile (& $ecNote 7009))"
Check 'charlie -Print, which keeps no notes: a host no pass has found gone offered at once as a restart, the note as it was; one a host''s pass found gone waits as the host does' (
    $ecOn0.Count -eq 1 -and $ecOn0[0].Cause -eq '' -and $ecOnN -and -not $ecOnN.PSObject.Properties['goneAt'] -and $ecOn1.Count -eq 0) "$($ecOn0.Count) $($ecOn1.Count) // $($ecOnN | ConvertTo-Json -Compress -Depth 4)"
# the clock put back since a host's pass kept goneAt: the wait counts from
# now, not from a goneAt still ahead, which would hold the chat until the
# clock caught up - for an hour, the clocks put back for the winter
& $ecSave 7009 $ecNow.AddMinutes(-2)
$ecFn = Read-ChatqJson (& $ecNote 7009)
Set-ChatqProp $ecFn 'goneAt' $ecNow.AddHours(1).ToUniversalTime().ToString('o')
Save-ChatqText (& $ecNote 7009) ($ecFn | ConvertTo-Json -Depth 5)
$ecPf0 = @{}
$ecHf0 = @(Get-ChatRestartCutOffs -Live @() -Asked @{} -Jobs @() -Pending $ecPf0 -Prune -Now $ecNow)
$ecFn0 = Read-ChatqJson (& $ecNote 7009)
$ecHf1 = @(Get-ChatRestartCutOffs -Live @() -Asked @{} -Jobs @() -Prune -Now $ecNow.AddSeconds(31))
Remove-Item -LiteralPath (& $ecNote 7009) -Force -EA SilentlyContinue
$script:EcDead = @(7001, 7002, 7003)
Check 'a goneAt ahead of now - the clock put back since: kept as now, so the wait ends 30 s on, not once the clock catches up' (
    $ecHf0.Count -eq 0 -and $ecPf0[7009] -and $ecFn0 -and [Math]::Abs(((ConvertTo-ChatqDate $ecFn0.goneAt) - $ecNow).TotalSeconds) -lt 1 -and
    $ecHf1.Count -eq 1 -and $ecHf1[0].Cause -eq '') "$($ecHf0.Count) $($ecHf1.Count) // $(if ($ecFn0) { $ecFn0.goneAt })"

# The overlay's own notes (Update-ChatHostWorkNotes), in the first section's
# process table: claude 1002, 1003 and 1004 under the extension host Code 200,
# started at 08:02; 1005 under Code 300. Each pass hands in what the overlay's
# pass holds - the live entries, the background work, the jobs - at a time
# that many seconds on.
$script:ChatProcessTableSeam = $hwTable
$script:EcDead = @()
$wnE = {
    param([string]$Id, [int]$ProcId, [string]$Status, [string]$Ep = 'claude-vscode', [string]$Kind = 'interactive')
    [pscustomobject]@{ SessionId = $Id; Pid = $ProcId; Status = $Status; Kind = $Kind; Entrypoint = $Ep; Cwd = $projH
        StartedAt = [DateTimeOffset]::new($hwT0.AddMinutes(5)).ToUnixTimeMilliseconds() }
}
$wnNew = { @{ HostWork = $null; Chains = @{}; Text = @{ $idR1 = @{ Path = $rsFile[$idR1] }; $idR2 = @{ Path = $rsFile[$idR2] }; $idR3 = @{ Path = $rsFile[$idR3] } } } }
$wnCtx = & $wnNew
$wnRun = {
    param([object[]]$Live, [double]$Sec, [hashtable]$Bg = @{}, [object[]]$Jobs = @(), [object[]]$Extra = @())
    $null = Update-ChatHostWorkNotes $wnCtx $Live (@($Live) + @($Extra)) $Bg $Jobs $ecNow.AddSeconds($Sec)
}
$wnNote = & $ecNote 200
$wnSaid = { $n = Read-ChatqJson $wnNote; if ($n) { (@($n.chats | ForEach-Object { "$($_.sessionId.Substring(0, 2))=$($_.why)" }) -join ' ') } else { 'none' } }
$wnAt = { param([double]$Sec) $n = Read-ChatqJson $wnNote; [bool]($n -and [Math]::Abs(((ConvertTo-ChatqDate $n.at) - $ecNow.AddSeconds($Sec)).TotalSeconds) -lt 1) }
$wnL = @((& $wnE $idR1 1002 'busy'), (& $wnE $idR2 1003 'idle'), (& $wnE $idR3 1004 'busy' 'cli'))
& $wnRun $wnL 0
$wnN = Read-ChatqJson $wnNote
Check 'the overlay''s pass notes a window''s chat at work by its extension host - by overlay, with the host''s start; not an idle chat, nor a terminal''s claude under it' (
    (& $wnSaid) -eq 'e1=turn' -and $wnN.by -eq 'overlay' -and [int]$wnN.hostPid -eq 200 -and (& $wnAt 0) -and
    [Math]::Abs(((ConvertTo-ChatqDate $wnN.hostStart) - $hwT0.AddMinutes(2)).TotalSeconds) -lt 1 -and
    [Math]::Abs(((ConvertTo-ChatqDate $wnN.chats[0].since) - $hwT0.AddMinutes(5)).TotalSeconds) -lt 1) "$(Read-TestFile $wnNote)"
& $wnRun $wnL 60
$wn2 = & $wnAt 0
$wnL[1] = & $wnE $idR2 1003 'waiting'
& $wnRun $wnL 90
$wn3 = (& $wnSaid) -eq 'e1=turn e2=prompt' -and (& $wnAt 90)
$wnL[1] = & $wnE $idR2 1003 'idle'
& $wnRun $wnL 100
$wn4 = (& $wnSaid) -eq 'e1=turn e2=prompt' -and (& $wnAt 90)
& $wnRun $wnL 125
$wn5 = (& $wnSaid) -eq 'e1=turn' -and (& $wnAt 125)
& $wnRun $wnL 665
$wn6 = & $wnAt 125
& $wnRun $wnL 785
$wn7 = & $wnAt 785
Check 'written again when its chats change - one waiting joins at once, one stopped stays 30 s - and every 10 minutes besides, never in between' (
    $wn2 -and $wn3 -and $wn4 -and $wn5 -and $wn6 -and $wn7) "$wn2 $wn3 $wn4 $wn5 $wn6 $wn7"
$wnBg = @{ $idR2 = [pscustomobject]@{ Workflows = 1; Agents = 0; Shells = 0 } }
& $wnRun $wnL 800 $wnBg
$wn8 = (& $wnSaid) -eq 'e1=turn e2=background'
& $wnRun $wnL 840 $wnBg @([pscustomobject]@{ sessionId = $idR2; state = 'running' })
$wn9 = (& $wnSaid) -eq 'e1=turn'
& $wnRun $wnL 845 $wnBg @() @([pscustomobject]@{ SessionId = $idR2; Pid = 1099; Status = 'busy'; Kind = 'print'; Entrypoint = 'sdk-cli' })
$wn10 = -not $wnCtx.HostWork.Seen.ContainsKey("200|$idR2")
& $wnRun $wnL 850 @{ $idR2 = [pscustomobject]@{ Workflows = 0; Agents = 0; Shells = 2 } }
$wn11 = -not $wnCtx.HostWork.Seen.ContainsKey("200|$idR2")
Check 'a workflow out is work; not while a chatq job or a print-mode claude goes into the chat, nor a shell' ($wn8 -and $wn9 -and $wn10 -and $wn11) "$wn8 $wn9 $wn10 $wn11 / $(& $wnSaid)"
$wnL[0] = & $wnE $idR1 1002 'idle'
& $wnRun $wnL 890
$wn12 = -not (Test-Path -LiteralPath $wnNote)
$wnL[0] = & $wnE $idR1 1002 'busy'
& $wnRun $wnL 900
$wn13 = (& $wnSaid) -eq 'e1=turn'
# the window goes down: its host dead a moment before its chats' processes
$script:EcDead = @(200)
$wnL[1] = & $wnE $idR2 1003 'waiting'
& $wnRun $wnL 910
$wn14 = (& $wnSaid) -eq 'e1=turn' -and (& $wnAt 900)
& $wnRun @() 950
$wn15 = (Test-Path -LiteralPath $wnNote) -and (& $wnAt 900) -and -not $wnCtx.HostWork.Notes.ContainsKey(200)
Check 'nothing at work: the overlay''s note goes while its host runs; once the host is gone, never written over nor removed' (
    $wn12 -and $wn13 -and $wn14 -and $wn15) "$wn12 $wn13 $wn14 $wn15"
# no VS Code log here: one would hold the chat back until it named host
# 200's exit, which the section's first part proves
$script:EcRoots = @()
$wnCut = @(Get-ChatRestartCutOffs -Live @() -Asked @{} -Jobs @() -Now $ecNow.AddSeconds(960))
$script:EcRoots = @($ecCode, $ecIns)
Check 'and the cut-off look offers its chat: a window gone with no look of the extension''s before it still leaves its cut-off' (
    $wnCut.Count -eq 1 -and $wnCut[0].Id -eq $idR1 -and $wnCut[0].HostPid -eq 200 -and $wnCut[0].Mid) "$($wnCut.Count)"
Remove-Item -LiteralPath $wnNote -Force -EA SilentlyContinue
# the extension's own note, its wait looking every 25 s: a fresh overlay, the
# host alive, leaves it a minute before writing over it
$script:EcDead = @()
$wnCtx = & $wnNew
Save-ChatHostWorkNote ([pscustomobject]@{ HostPid = 200; Known = $true; Chats = @($rsLook.Chats[0]) }) -HostStart ([int64](ConvertTo-ChatOverlayMs $hwT0.AddMinutes(2))) -Now $ecNow.AddSeconds(1190)
$wnL = @((& $wnE $idR1 1002 'busy'), (& $wnE $idR2 1003 'waiting'))
& $wnRun $wnL 1200
$wnX1 = Read-ChatqJson $wnNote
& $wnRun $wnL 1230
$wnX2 = Read-ChatqJson $wnNote
& $wnRun $wnL 1255
$wnX3 = Read-ChatqJson $wnNote
Check 'the extension''s own note - its wait looks every 25 s - stands a minute before the overlay writes over it' (
    $wnX1 -and -not $wnX1.PSObject.Properties['by'] -and $wnX2 -and -not $wnX2.PSObject.Properties['by'] -and @($wnX2.chats).Count -eq 1 -and
    $wnX3 -and $wnX3.by -eq 'overlay' -and (& $wnSaid) -eq 'e1=turn e2=prompt') "$(& $wnSaid)"
# a note of an earlier process that had pid 300 is the cut-off look's
$wnNote3 = & $ecNote 300
Save-ChatHostWorkNote ([pscustomobject]@{ HostPid = 300; Known = $true; Chats = @($rsLook.Chats[0]) }) -HostStart ([int64](ConvertTo-ChatOverlayMs $hwT0.AddMinutes(-60))) -Now $ecNow.AddSeconds(1250) -By overlay
$wnOld = Read-TestFile $wnNote3
& $wnRun @((& $wnE $idR3 1005 'busy')) 1260
Check 'a note of an earlier process that had the same pid is the cut-off look''s, and left as it is' ($null -ne $wnOld -and (Read-TestFile $wnNote3) -eq $wnOld) "$(Read-TestFile $wnNote3)"
# the overlay started again - an update - with its own notes from before: one
# whose host runs, its chats stopped meanwhile, goes at the first pass; not
# the extension's, nor one whose host is gone
foreach ($p in $wnNote, $wnNote3) { Remove-Item -LiteralPath $p -Force -EA SilentlyContinue }
$wnNote7 = & $ecNote 7021
$wnStart = [int64](ConvertTo-ChatOverlayMs $hwT0.AddMinutes(2))
foreach ($n in @(@{ P = 200; By = 'overlay' }, @{ P = 300; By = '' }, @{ P = 7021; By = 'overlay' })) {
    Save-ChatHostWorkNote ([pscustomobject]@{ HostPid = $n.P; Known = $true; Chats = @($rsLook.Chats[0]) }) -HostStart $wnStart -Now $ecNow.AddSeconds(1270) -By $n.By
}
$script:EcDead = @(7021)
$wnCtx = & $wnNew
& $wnRun @((& $wnE $idR1 1002 'idle')) 1280
Check 'the overlay started again: its own note from before, its host running and its chats stopped meanwhile, goes at the first pass - not the extension''s, nor one whose host is gone' (
    -not (Test-Path -LiteralPath $wnNote) -and (Test-Path -LiteralPath $wnNote3) -and (Test-Path -LiteralPath $wnNote7) -and -not $wnCtx.HostWork.Notes.Count) (
    "$(Test-Path -LiteralPath $wnNote) $(Test-Path -LiteralPath $wnNote3) $(Test-Path -LiteralPath $wnNote7) $($wnCtx.HostWork.Notes.Count)")
$script:EcDead = @()
foreach ($p in $wnNote, $wnNote3, $wnNote7) { Remove-Item -LiteralPath $p -Force -EA SilentlyContinue }
$script:ChatProcessTableSeam = $ecWas.Table

# config autoContinueCrash, off unless chosen, and the memory warning's percent
$ecC0 = Get-ChatOverlayConfig ([pscustomobject]@{ x = 1 })
$ecCrash = { param($v) Get-ChatqAutoContinueCrash ([pscustomobject]@{ autoContinueCrash = $v }) }
Check 'config: the crash continue off and the memory warning at 95% unless chosen, the warning held to 0..99; the crash continue on for true, "on" or "true" alone' (
    $ecC0.autoContinueCrash -eq $false -and $ecC0.memoryWarn -eq 95 -and
    (Get-ChatOverlayConfig ([pscustomobject]@{ overlay = [pscustomobject]@{ memoryWarn = 150 } })).memoryWarn -eq 99 -and
    (Get-ChatOverlayConfig ([pscustomobject]@{ overlay = [pscustomobject]@{ memoryWarn = -5 } })).memoryWarn -eq 0 -and
    (& $ecCrash $true) -and (& $ecCrash 'on') -and (& $ecCrash ' TRUE ') -and -not (& $ecCrash 'yes') -and -not (& $ecCrash $false) -and
    -not (& $ecCrash 'off') -and -not (Get-ChatqAutoContinueCrash ([pscustomobject]@{ x = 1 }))) "$($ecC0.autoContinueCrash) $($ecC0.memoryWarn)"
$ecCo = { param($k, $v) (Get-ChatOverlayConfig ([pscustomobject]@{ overlay = [pscustomobject]@{ $k = $v } })).$k }
Check 'config: the leak warning at 2 GB and the memory restart at 300 MB unless chosen, held to 0..64 and 0..4096; a part of a GB kept' (
    $ecC0.leakGB -eq 2 -and $ecC0.restartMB -eq 300 -and (& $ecCo 'leakGB' 100) -eq 64 -and (& $ecCo 'leakGB' -1) -eq 0 -and (& $ecCo 'leakGB' 0.5) -eq 0.5 -and
    (& $ecCo 'restartMB' 99999) -eq 4096 -and (& $ecCo 'restartMB' -5) -eq 0 -and (& $ecCo 'restartMB' 0) -eq 0) "$($ecC0.leakGB) $($ecC0.restartMB)"
$null = Set-ChatqAutoContinueCrash -Value $true
$ecSetOn = (Get-ChatqConfig).autoContinueCrash -eq $true -and (Get-ChatqAutoContinueCrash)
$null = Set-ChatqAutoContinueCrash -Value $false
Check 'Set-ChatqAutoContinueCrash writes config.json''s top level, on and off' ($ecSetOn -and (Get-ChatqConfig).autoContinueCrash -eq $false -and -not (Get-ChatqAutoContinueCrash)) "$ecSetOn"

# Through the overlay's pass (Invoke-ChatOverlayCycle), a host's that queues:
# a window that ran out of memory, its note left by the overlay. Crash
# continue off, the chat it cut off is asked about; on, the next look
# continues it. A usage stand-in well under the limit.
$ecAutoBefore = @(if (Test-Path -LiteralPath $script:ChatqAutoDir) { Get-ChildItem -LiteralPath $script:ChatqAutoDir -File | ForEach-Object Name })
$ecJobsBefore = @(Get-ChatqJobs | ForEach-Object { [string]$_.id })
$ecSnapWas = Test-Path -LiteralPath $script:ChatOverlayPath
$script:ChatOverlayUsageSeam = { @{ Ok = $true; Status = 200; Windows = @([pscustomobject]@{ Label = '5h'; Percent = 10; ResetsAt = (Get-Date).AddHours(3); Severity = 'normal' }) } }
$script:ChatqSpawn = { $true }
$ecJobsOf = { param([string]$Id) @(Get-ChatqJobs | Where-Object { $_.sessionId -eq $Id -and $_.state -eq 'queued' }) }
try {
    $null = Set-ChatqAutoContinue -Value ask
    # a window gone a moment ago whose exit VS Code's log has yet to name:
    # the look holds its chat back - no row, no ask - and comes again in 2 s
    $script:EcDead = @(7031)
    & $ecSave 7031 $ecNow.AddMinutes(-2)
    $ecKc = New-ChatOverlayContext
    $ecKc.WantAsk = $true
    $ecKc.WantAuto = $true
    $ecKt0 = Get-Date
    $ecKs0 = Invoke-ChatOverlayCycle $ecKc
    $ecKt1 = Get-Date
    $ecKn0 = Read-ChatqJson (& $ecNote 7031)
    $ecKa0 = $ecKc.CutAt
    $ecKg0 = $ecKc.CutAgain
    # its 2 s up, the look comes again inside CutAt's minute, and holds the
    # chat again; once nothing is held, none comes until the minute is up
    $ecKc.CutAgain = (Get-Date).AddSeconds(-1)
    $ecKt2 = Get-Date
    $null = Invoke-ChatOverlayCycle $ecKc
    $ecKa1 = $ecKc.CutAt
    $ecKg1 = $ecKc.CutAgain
    Remove-Item -LiteralPath (& $ecNote 7031) -Force -EA SilentlyContinue
    $ecKc.CutAgain = (Get-Date).AddSeconds(-1)
    $null = Invoke-ChatOverlayCycle $ecKc
    $ecKa2 = $ecKc.CutAt
    $ecKg2 = $ecKc.CutAgain
    $null = Invoke-ChatOverlayCycle $ecKc
    $ecKa3 = $ecKc.CutAt
    Check 'through the overlay''s pass: a window whose exit VS Code''s log has yet to name - no row, no ask, its note kept; looked at again 2 s on, not a minute, the look''s own time kept for the automatic mode' (
        -not @($ecKc.RestartScan).Count -and -not @($ecKc.Ask.Items | Where-Object { $_.Id -eq $idR1 }).Count -and
        -not @($ecKs0.rows | Where-Object { $_.key -eq "c:$idR1" }).Count -and $ecKn0 -and (ConvertTo-ChatqDate $ecKn0.goneAt) -and @($ecKn0.chats).Count -eq 1 -and
        $ecKa0 -ge $ecKt0 -and $ecKa0 -le $ecKt1 -and $ecKg0 -ge $ecKt0.AddSeconds(2) -and $ecKg0 -le $ecKt1.AddSeconds(2)) (
        "$($ecKa0.ToString('HH:mm:ss.fff')) again $(if ($ecKg0) { $ecKg0.ToString('HH:mm:ss.fff') }) from $($ecKt0.ToString('HH:mm:ss.fff'))")
    Check 'its 2 s up: the look comes again before the minute and holds the chat again; once nothing is held, no look again until the minute' (
        $ecKa1 -ge $ecKt2 -and $ecKg1 -and $ecKg1 -ge $ecKt2.AddSeconds(2) -and $ecKa2 -gt $ecKa1 -and $null -eq $ecKg2 -and $ecKa3 -eq $ecKa2) (
        "$($ecKa1.ToString('HH:mm:ss.fff')) $($ecKa2.ToString('HH:mm:ss.fff')) $($ecKa3.ToString('HH:mm:ss.fff')) from $($ecKt2.ToString('HH:mm:ss.fff')) again '$ecKg1' '$ecKg2'")
    $script:EcDead = @(7001)
    & $ecSave 7001 $ecNow.AddMinutes(-2)
    $ecKc.CutAt = [datetime]::MinValue
    $ecKs = Invoke-ChatOverlayCycle $ecKc
    $ecKr = @($ecKc.Ask.Items | Where-Object { $_.Id -eq $idR1 })
    $ecKd = @($ecKs.rows | Where-Object { $_.key -eq "c:$idR1" })
    Check 'crash continue off: the chat a window''s running out of memory cut off is asked about, said so on its row and the ask - nothing queued' (
        $ecKr.Count -eq 1 -and $ecKr[0].Cause -eq 'oom' -and $ecKs.header.ask.restart -eq 1 -and $ecKs.header.ask.cause -eq 'oom' -and
        $ecKd.Count -eq 1 -and $ecKd[0].detail -eq 'cut off - VS Code ran out of memory' -and -not @(& $ecJobsOf $idR1).Count) "$($ecKs.header.ask | ConvertTo-Json -Compress) / $($ecKd.detail)"
    $null = Set-ChatqAutoContinueCrash -Value $true
    $ecKc.Config = Get-ChatOverlayConfig
    # open in a terminal meanwhile: its own claude continues it, so the crash
    # continue leaves it be, as the reset ask does
    $ecReg = Join-Path (Join-Path $ecKc.ClaudeHome 'sessions') '4848.json'
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $ecReg) -Force
    [System.IO.File]::WriteAllText($ecReg, ([ordered]@{ pid = 4848; sessionId = $idR1; cwd = $projH; status = 'idle'; kind = 'interactive'; entrypoint = 'cli'
                startedAt = [DateTimeOffset]::new($ecNow.AddMinutes(-1)).ToUnixTimeMilliseconds() } | ConvertTo-Json -Compress), $utf8)
    $ecAliveWas = $script:ChatqAliveSeam
    $script:ChatqAliveSeam = { param($e) $e.Pid -eq 4848 }
    try {
        $ecKc.CutAt = [datetime]::MinValue
        $null = Invoke-ChatOverlayCycle $ecKc
    }
    finally { $script:ChatqAliveSeam = $ecAliveWas; Remove-Item -LiteralPath $ecReg -Force -EA SilentlyContinue }
    $ecHk = Get-ChatqCutKey $ecKr[0]
    Check 'crash continue on, the chat open in a terminal meanwhile: left to its own claude - nothing queued, no marker, its row kept' (
        -not @(& $ecJobsOf $idR1).Count -and -not (Test-ChatqCrashContinued $idR1 (Get-Date)) -and
        @($ecKc.RestartScan | Where-Object { $_.Id -eq $idR1 }).Count -eq 1 -and -not ($ecKc.AskState -and $ecKc.AskState[$ecHk])) (
        "$(@(& $ecJobsOf $idR1).Count) $(@($ecKc.RestartScan | ForEach-Object { $_.Id.Substring(0, 2) }) -join ',')")
    # a -Peek pass - a click's, the console's - leaves the look to the host's
    # own while the crash continue is on: it would leave the chat to be asked
    # about, then continued a look later
    $ecKc.CutAt = [datetime]::MinValue
    $null = Invoke-ChatOverlayCycle $ecKc -Peek
    Check 'crash continue on: a -Peek pass leaves the cut-off look to the host''s own pass' ($ecKc.CutAt -eq [datetime]::MinValue -and -not @(& $ecJobsOf $idR1).Count) "$($ecKc.CutAt)"
    $ecKs2 = Invoke-ChatOverlayCycle $ecKc
    $ecKj = @(& $ecJobsOf $idR1)
    $ecKk = Get-ChatqCutKey $ecKr[0]
    $ecKm = Read-ChatqJson (Join-Path $script:ChatqAutoDir "$ecKk.json")
    $ecKt = if ($ecKj.Count) { [string](Read-ChatqPrompt $ecKj[0]) } else { '' }
    $ecKl = [System.IO.File]::ReadAllText((Join-Path $script:ChatqLogDir 'overlay.log'), $utf8)
    Check 'crash continue on: the next look continues it - a restart prompt that says VS Code ran out of memory, marked answered by crash; no ask, no orange row, a line in the log' (
        $ecKj.Count -eq 1 -and $ecKj[0].kind -eq 'prompt' -and [string]$ecKj[0].rule -eq 'restart' -and $ecKj[0].restartUuid -eq $rsUse -and
        $ecKt.StartsWith('VS Code ran out of memory while this chat worked, which ended its process mid-turn.') -and
        $ecKm -and $ecKm.source -eq 'crash' -and $ecKm.answer -eq 'continue' -and $ecKm.why -eq 'restart' -and (@($ecKm.seq) -join ',') -eq "$($ecKj[0].seq)" -and
        $ecKk -and $ecKc.AskState -and $ecKc.AskState[$ecKk] -and -not @($ecKc.Ask.Items | Where-Object { $_.Id -eq $idR1 }).Count -and
        -not @($ecKs2.rows | Where-Object { $_.key -eq "c:$idR1" }).Count -and $ecKl -like "*crash: continued 1 - #$($ecKj[0].seq)*") "$($ecKj.Count) $(Read-TestFile (Join-Path $script:ChatqAutoDir "$ecKk.json")) // $ecKt"

    # Never past its guards, each on a row that is continued but for it:
    # answered; continued here in the last 2 hours; no cause - a reload, or a
    # window closed; 11 minutes old; a job waiting; a chat set to never; open
    # where its own claude continues it (-Held)
    foreach ($j in $ecKj) { $null = Remove-ChatqJob $j -By test }
    $ecR2 = {
        param([string]$Cut, [string]$Cause = 'crash', [double]$MinAgo = 0)
        [pscustomobject]@{ Id = $idR2; Title = 'Restart e2'; Group = 'g'; At = (Get-Date).AddMinutes(-$MinAgo); ResetsAt = $null; Why = 'restart'; Path = $rsFile[$idR2]
            Cwd = $projH; LimitUuid = $Cut; Mid = $false; HostPid = 7002; Cause = $Cause; Tasks = @() }
    }
    $ecCx = @{ AskState = @{} }
    $ecG1 = @(Invoke-ChatqCrashContinue @{ AskState = @{ "${idR2}_cut-z" = $true } } @(& $ecR2 'cut-z') @() (Get-Date))
    $ecLater = $ecKr[0].PSObject.Copy()
    $ecLater.LimitUuid = 'a-later-cut'
    $ecLater.At = Get-Date
    $ecG2 = @(Invoke-ChatqCrashContinue $ecCx @($ecLater) @() (Get-Date))
    $ecG2Jobs = @(& $ecJobsOf $idR1).Count
    $ecG3 = @(Invoke-ChatqCrashContinue $ecCx @(& $ecR2 'cut-a' '') @() (Get-Date))
    $ecG4 = @(Invoke-ChatqCrashContinue $ecCx @(& $ecR2 'cut-b' 'crash' 11) @() (Get-Date))
    $ecG5 = @(Invoke-ChatqCrashContinue $ecCx @(& $ecR2 'cut-c') @([pscustomobject]@{ sessionId = $idR2; state = 'queued' }) (Get-Date))
    $null = Set-ChatqAutoChat -Id $idR2 -Title 'Restart e2' -Value never
    $ecG6 = @(Invoke-ChatqCrashContinue $ecCx @(& $ecR2 'cut-d') @() (Get-Date))
    $null = Set-ChatqAutoChat -Id $idR2 -Title 'Restart e2' -Value default
    $ecGh = @(Invoke-ChatqCrashContinue $ecCx @(& $ecR2 'cut-f') @() (Get-Date) -Held @{ $idR2 = $true })
    # an answer of the ask's own is no crash continue
    $null = Save-ChatqAskAnswer -Keys @("${idR2}_asked-before") -Answer continue -Source overlay
    $ecWasR2 = Test-ChatqCrashContinued $idR2 (Get-Date)
    $ecG7 = @(Invoke-ChatqCrashContinue $ecCx @(& $ecR2 'cut-e') @() (Get-Date))
    $ecG7j = @(& $ecJobsOf $idR2)
    $ecG7t = if ($ecG7j.Count) { [string](Read-ChatqPrompt $ecG7j[0]) } else { '' }
    Check 'never past its guards: answered, continued here in the last 2 hours, no cause, 11 minutes old, a job waiting, a chat set to never, open in a terminal - and the same row with none of them is continued' (
        -not $ecG1.Count -and -not $ecG2.Count -and -not $ecG2Jobs -and -not $ecG3.Count -and -not $ecG4.Count -and -not $ecG5.Count -and -not $ecG6.Count -and -not $ecGh.Count -and
        -not $ecWasR2 -and $ecG7.Count -eq 1 -and $ecG7j.Count -eq 1 -and $ecG7t -eq "VS Code crashed while this chat worked, which ended its process. $($script:ChatqContinueText)") "$($ecG1.Count) $($ecG2.Count) $ecG2Jobs $($ecG3.Count) $($ecG4.Count) $($ecG5.Count) $($ecG6.Count) $($ecGh.Count) $ecWasR2 $($ecG7.Count) // $ecG7t"
    $ecNowG = Get-Date
    Check 'a crash continue keeps another from its chat for 2 hours, by its marker''s source' (
        (Test-ChatqCrashContinued $idR1 $ecNowG) -and (Test-ChatqCrashContinued $idR2 $ecNowG) -and -not (Test-ChatqCrashContinued $idR1 $ecNowG.AddHours(3)) -and
        -not (Test-ChatqCrashContinued $idH1 $ecNowG)) ''
}
finally {
    $script:ChatOverlayUsageSeam = $ecWas.Usage
    $script:ChatqSpawn = $ecWas.Spawn
    Restore-TestFile $script:ChatqConfigPath $ecCfgWas
    Restore-TestFile $script:ChatqAutoPath $ecStateWas
    $script:ChatqAutoCache = $null
    if (-not $ecSnapWas) { Remove-Item -LiteralPath $script:ChatOverlayPath -Force -EA SilentlyContinue }
    foreach ($j in @(Get-ChatqJobs | Where-Object { [string]$_.id -notin $ecJobsBefore })) { $null = Remove-ChatqJob $j -By test }
    foreach ($f in @(if (Test-Path -LiteralPath $script:ChatqAutoDir) { Get-ChildItem -LiteralPath $script:ChatqAutoDir -File })) {
        if ($f.Name -notin $ecAutoBefore) { Remove-Item -LiteralPath $f.FullName -Force -EA SilentlyContinue }
    }
    Remove-Item -LiteralPath (& $ecNote 7001) -Force -EA SilentlyContinue
}

# Windows' memory (Update-ChatOverlayMemory): a stand-in for its commit
# figures, out of 100 GB, and for the programs holding the most, counting its
# asks; each look that many seconds on
$script:EcMem = @{ Limit = 100GB; Free = 50GB }
$script:EcTops = 0
$script:ChatMemorySeam = { $script:EcMem }
$script:ChatMemoryTopSeam = { $script:EcTops++; @('Code 9.8 GB', 'claude 3.1 GB') }
$emC = New-ChatOverlayContext
$emT = Get-Date
$emAt = { param([double]$FreeGB, [double]$Sec, $Ctx = $emC, [switch]$Act) $script:EcMem = @{ Limit = 100GB; Free = $FreeGB * 1GB }; Update-ChatOverlayMemory $Ctx $emT.AddSeconds($Sec) -Act:$Act }
$em1 = & $emAt 50 0 -Act
$em2 = & $emAt 3.5 10 -Act
$emNews2 = $emC.MemNews
$em3 = & $emAt 50 15 -Act
$em4 = & $emAt 7 21 -Act
$emTops4 = $script:EcTops
$em5 = & $emAt 9 32 -Act
$emSaid5 = $emC.MemSaid
$emC.MemNews = $null
$em6 = & $emAt 3.5 43 -Act
$emNews6 = $emC.MemNews
$null = & $emAt 9 960 -Act
$null = & $emAt 3.5 971 -Act
$emNews8 = $emC.MemNews
$emLog = [System.IO.File]::ReadAllText((Join-Path $script:ChatqLogDir 'overlay.log'), $utf8)
$emText = 'memory low: 96% used, 3.5 GB left - most: Code 9.8 GB, claude 3.1 GB'
Check 'memory: nothing at half used; at 96% low - its figures and the programs holding the most, said in the log and kept for the tray' (
    $null -eq $em1 -and $em2 -and $em2.percent -eq 96 -and $em2.freeGB -eq 3.5 -and (@($em2.top) -join ', ') -eq 'Code 9.8 GB, claude 3.1 GB' -and
    $emNews2 -and $emNews2.percent -eq 96 -and (Format-ChatOverlayMemoryText $em2) -eq $emText -and $emLog.Contains($emText)) "$($em2 | ConvertTo-Json -Compress)"
Check 'looked at 10 s apart at most, the programs a minute apart; low until under 92%, then said back in the log' (
    $em3 -and $em3.percent -eq 96 -and $em4 -and $em4.percent -eq 93 -and $emTops4 -eq 1 -and $null -eq $em5 -and -not $emSaid5 -and
    $emLog.Contains('memory: back to 91% used')) "$($em3.percent) $($em4.percent) $emTops4 $emSaid5"
Check 'low again: in the log again, the tray not within 15 minutes of the last time; past them, the tray too' (
    $em6 -and $em6.percent -eq 96 -and $null -eq $emNews6 -and $emNews8 -and $emNews8.percent -eq 96 -and
    [regex]::Matches($emLog, [regex]::Escape($emText)).Count -eq 3) "$([regex]::Matches($emLog, [regex]::Escape($emText)).Count)"
$emOffC = New-ChatOverlayContext
$emOffC.Config = [pscustomobject]@{ memoryWarn = 0 }
$emOff = & $emAt 0.5 0 $emOffC -Act
$emPeekC = New-ChatOverlayContext
$emPeek = & $emAt 3.5 0 $emPeekC
Check 'memoryWarn 0 is never; a pass that only looks (-Peek) says nothing' (
    $null -eq $emOff -and $null -eq $emOffC.MemLow -and $emPeek -and $emPeek.percent -eq 96 -and -not $emPeekC.MemSaid -and $null -eq $emPeekC.MemNews) ''
$emHdr = { param($Mem) [pscustomobject]@{ usage = @(); usageWhy = $null; watcher = 'none'; next = $null; error = 'boom'; memory = $Mem; ask = $null; reload = @() } }
$emNotes = @(Get-ChatOverlayNotes (& $emHdr $em2))
$emNone = @(Get-ChatOverlayNotes (& $emHdr $null))
$script:EcBalloons = [System.Collections.Generic.List[object]]::new()
$script:ChatOverlayBalloonSeam = { param($b) $script:EcBalloons.Add($b) }
$emH = @{ Ctx = $emC; Closing = $false; BalloonKind = $null; BalloonKeys = @() }
$emC.MemNews = $em2
Show-ChatOverlayMemory $emH
Show-ChatOverlayMemory $emH
$emB = @($script:EcBalloons)
Check 'the panel''s note for it comes first, as a warning; the tray''s balloon once, titled memory low - the figures, and what to do' (
    $emNotes[0].kind -eq 'memory' -and $emNotes[0].tone -eq 'warn' -and $emNotes[0].text -eq $emText -and $emNotes[1].tone -eq 'error' -and
    -not @($emNone | Where-Object { $_.PSObject.Properties['kind'] -and $_.kind -eq 'memory' }).Count -and
    $emB.Count -eq 1 -and $emB[0].Title -eq 'Charlie - memory low' -and $emB[0].Kind -eq 'memory' -and
    $emB[0].Text -eq '96% used, 3.5 GB left - most: Code 9.8 GB, claude 3.1 GB. A VS Code window that runs out of memory takes its chats down with it - close what you can spare.' -and
    $null -eq $emC.MemNews) "$($emB | ConvertTo-Json -Compress)"
$emCx = New-ChatOverlayContext
$emCx.WantAsk = $true
$script:EcMem = @{ Limit = 100GB; Free = 3.5GB }
$emSn = Invoke-ChatOverlayCycle $emCx -Peek
$emSnN = Invoke-ChatOverlayCycle (New-ChatOverlayContext) -Peek
Check 'the overlay''s pass: a host''s carries it in the header and its first note; charlie -Print''s looks at nothing' (
    $emSn.header.memory -and $emSn.header.memory.percent -eq 96 -and @($emSn.header.notes)[0].kind -eq 'memory' -and -not $emCx.MemSaid -and
    $null -eq $emSnN.header.memory) "$($emSn.header.memory | ConvertTo-Json -Compress)"

# A program growing fast (Update-ChatOverlayLeaks), as Word did on
# 2026-10-19: a stand-in for each program's bytes by name with each of its
# processes', counting its walks; a look each minute for an hour, Word
# growing 0.61 GB a minute to minute 45 and then still, Code still at 9.8,
# a program first there at minute 10 holding 5 GB, and claude a new 0.3 GB
# process each minute - its sum 3 GB more in 10 minutes, no process grown
$script:EcSums = @{}
$script:EcWalks = 0
$script:ChatMemorySumsSeam = { $script:EcWalks++; $script:EcSums }
$lkSet = { param([double]$Min)
    $w = (9.7 + 0.61 * [Math]::Min($Min, 45)) * 1GB
    $cl = @{}
    foreach ($i in 0..[int]$Min) { $cl[9000 + $i] = 0.3GB }
    $script:EcSums = @{ WINWORD = @{ Bytes = $w; Procs = @{ 33188 = $w } }; Code = @{ Bytes = 9.8GB; Procs = @{ 4242 = 9.8GB } }
        claude = @{ Bytes = 0.3GB * $cl.Count; Procs = $cl }
    }
    if ($Min -ge 10) { $script:EcSums['Fresh'] = @{ Bytes = 5GB; Procs = @{ 777 = 5GB } } }
}
$lkC = New-ChatOverlayContext
$lkSaid = [System.Collections.Generic.List[object]]::new()
$lkGrowing = @{}
foreach ($m in 0..60) {
    & $lkSet $m
    $g = @(Update-ChatOverlayLeaks $lkC $emT.AddMinutes($m) -Act)
    $lkGrowing[$m] = $g
    if ($lkC.LeakNews) { foreach ($n in @($lkC.LeakNews)) { $lkSaid.Add("$m $(Format-ChatOverlayLeakText $n)") }; $lkC.LeakNews = $null }
    if ($m -eq 10) { $lkHalf = @(Update-ChatOverlayLeaks $lkC $emT.AddMinutes(10.5) -Act); $lkWalks10 = $script:EcWalks; $lkNews10 = $lkC.LeakNews }
}
$lkText = 'WINWORD grew 6.1 GB in 10 min, now 15.8 GB (pid 33188) - it may be leaking'
$lkLog = [System.IO.File]::ReadAllText((Join-Path $script:ChatqLogDir 'overlay.log'), $utf8)
Check 'a program growing: nothing for its first 10 minutes; grown 6.1 GB since the look 10 minutes back - its pid, said in the log and kept for the tray; a program still, not there then, or growing by new processes of its name, not' (
    -not @($lkGrowing[9]).Count -and @($lkGrowing[10]).Count -eq 1 -and $lkGrowing[10][0].name -eq 'WINWORD' -and $lkGrowing[10][0].pid -eq 33188 -and
    $lkGrowing[10][0].grewGB -eq 6.1 -and $lkGrowing[10][0].nowGB -eq 15.8 -and $lkGrowing[10][0].minutes -eq 10 -and
    (Format-ChatOverlayLeakText $lkGrowing[10][0]) -eq $lkText -and $lkSaid[0] -eq "10 $lkText" -and $lkLog.Contains($lkText) -and
    -not @(@($lkGrowing.Values) | ForEach-Object { $_ } | Where-Object { $_.name -ne 'WINWORD' }).Count) "$($lkGrowing[10] | ConvertTo-Json -Compress) / $($lkSaid -join ' / ')"
Check 'looked at a minute apart, one walk of the processes each; said again only 30 minutes on while it grows; the note gone 10 minutes after it stops; 15 minutes of samples kept' (
    @($lkHalf).Count -eq 1 -and $lkWalks10 -eq 11 -and $null -eq $lkNews10 -and $script:EcWalks -eq 61 -and
    $lkSaid.Count -eq 2 -and $lkSaid[1] -like '40 WINWORD grew 6.1 GB in 10 min, now 34.1 GB (pid 33188)*' -and
    @($lkGrowing[51]).Count -eq 1 -and -not @($lkGrowing[52]).Count -and -not @($lkGrowing[60]).Count -and @($lkC.LeakSamples).Count -eq 16) (
    "$(@($lkHalf).Count) $lkWalks10 $($script:EcWalks) $(@($lkC.LeakSamples).Count) / $($lkSaid -join ' / ')")
# -Peek finds it and says nothing; the next pass that acts says it, from
# the same look. leakGB 0 never walks.
$lkP = New-ChatOverlayContext
& $lkSet 0
$null = Update-ChatOverlayLeaks $lkP $emT
& $lkSet 10
$lkP1 = @(Update-ChatOverlayLeaks $lkP $emT.AddMinutes(10))
$lkPNews = $lkP.LeakNews
$lkPW = $script:EcWalks
$lkP2 = @(Update-ChatOverlayLeaks $lkP $emT.AddMinutes(10.2) -Act)
$lkOffC = New-ChatOverlayContext
$lkOffC.Config = [pscustomobject]@{ leakGB = 0 }
$lkOff = @(Update-ChatOverlayLeaks $lkOffC $emT -Act)
Check 'leakGB 0 is never, with no walk; a pass that only looks (-Peek) says nothing, and the next that acts says it' (
    @($lkP1).Count -eq 1 -and $null -eq $lkPNews -and @($lkP2).Count -eq 1 -and @($lkP.LeakNews).Count -eq 1 -and $script:EcWalks -eq $lkPW -and
    -not $lkOff.Count -and $script:EcWalks -eq $lkPW) "$(@($lkP1).Count) $(@($lkP.LeakNews).Count) $($script:EcWalks) $lkPW"
# memory low in the same minute: its top programs from the leak look's
# listing, with no walk of their own until it is a minute old
$script:ChatMemoryTopSeam = $null
$lkM = New-ChatOverlayContext
& $lkSet 12
$null = Update-ChatOverlayLeaks $lkM $emT -Act
$lkMW = $script:EcWalks
$lkMem = & $emAt 3.5 5 $lkM -Act
$lkMW1 = $script:EcWalks
$null = & $emAt 3.5 70 $lkM -Act
$lkMW2 = $script:EcWalks
$script:ChatMemoryTopSeam = $ecWas.Top
Check 'memory''s top programs read the leak look''s listing - one walk a minute, whichever asks first' (
    (@($lkMem.top) -join ', ') -eq 'WINWORD 17 GB, Code 9.8 GB, Fresh 5 GB' -and $lkMW1 -eq $lkMW -and $lkMW2 -eq $lkMW + 1) "$(@($lkMem.top) -join ', ') $lkMW $lkMW1 $lkMW2"
# the panel's note and the tray's balloon: Word's alone, then with memory low
$lkNotes = @(Get-ChatOverlayNotes ([pscustomobject]@{ usage = @(); usageWhy = $null; watcher = 'none'; next = $null; error = $null; memory = $em2; ask = $null; reload = @(); leaks = @($lkGrowing[10]) }))
$script:EcBalloons.Clear()
$lkH = @{ Ctx = $lkC; Closing = $false; BalloonKind = $null; BalloonKeys = @() }
$lkC.LeakNews = @($lkGrowing[10])
Show-ChatOverlayMemory $lkH
$lkC.LeakNews = @($lkGrowing[10])
$lkC.MemNews = $em2
Show-ChatOverlayMemory $lkH
Show-ChatOverlayMemory $lkH
$lkB = @($script:EcBalloons)
Check 'the panel''s note for it after memory''s, as a warning; the tray''s balloon titled for it, or one balloon saying both with memory low' (
    $lkNotes[0].kind -eq 'memory' -and $lkNotes[1].kind -eq 'leak' -and $lkNotes[1].tone -eq 'warn' -and $lkNotes[1].text -eq $lkText -and
    $lkB.Count -eq 2 -and $lkB[0].Kind -eq 'leak' -and $lkB[0].Title -eq 'Charlie - a program keeps growing' -and $lkB[0].Text -like "$lkText. Closing it*" -and
    $lkB[1].Kind -eq 'memory' -and $lkB[1].Title -eq 'Charlie - memory low' -and $lkB[1].Text -like "96% used, 3.5 GB left - most: Code 9.8 GB, claude 3.1 GB. $lkText. A VS Code window*" -and
    $null -eq $lkC.LeakNews -and $null -eq $lkC.MemNews) "$($lkB | ConvertTo-Json -Compress)"
$lkCx = New-ChatOverlayContext
$lkCx.WantAsk = $true
$script:EcMem = @{ Limit = 100GB; Free = 50GB }
$lkCx.LeakSamples = @(@{ At = (Get-Date).AddMinutes(-11); Bytes = @{ '33188|WINWORD' = 9.7GB } })
$script:EcSums = @{ WINWORD = @{ Bytes = 15.8GB; Procs = @{ 33188 = 15.8GB } } }
$lkSn = Invoke-ChatOverlayCycle $lkCx -Peek
$lkSnN = Invoke-ChatOverlayCycle (New-ChatOverlayContext) -Peek
Check 'the overlay''s pass: a host''s carries the growing program in the header and a note, a -Peek one saying nothing; charlie -Print''s looks at nothing' (
    @($lkSn.header.leaks).Count -eq 1 -and $lkSn.header.leaks[0].name -eq 'WINWORD' -and @($lkSn.header.notes | Where-Object { $_.kind -eq 'leak' }).Count -eq 1 -and
    $null -eq $lkCx.LeakNews -and -not @($lkSnN.header.leaks).Count) "$($lkSn.header.leaks | ConvertTo-Json -Compress)"
# a walk that throws: its minute has no listing, not the one before it
$lkT = New-ChatOverlayContext
& $lkSet 0
$null = Get-ChatOverlayProcessSums $lkT $emT
$script:ChatMemorySumsSeam = { throw 'no walk' }
try { $null = Get-ChatOverlayProcessSums $lkT $emT.AddMinutes(1) } catch {}
$lkTSums = try { Get-ChatOverlayProcessSums $lkT $emT.AddMinutes(1.5) } catch { 'walked again' }
$script:ChatMemorySumsSeam = { $script:EcWalks++; $script:EcSums }
Check 'a walk of the processes that throws leaves its minute no listing, not the minute before''s' (
    $null -eq $lkTSums -and $lkT.SumsAt -eq $emT.AddMinutes(1)) "$(if ($lkTSums -is [hashtable]) { @($lkTSums.Keys) -join ',' } else { $lkTSums }) $($lkT.SumsAt)"
# the real walk, on Windows: this process's own name in it, its bytes
# summed, this process among its processes; read, nothing more
$script:ChatMemorySumsSeam = $null
$lkReal = Get-ChatMemorySums
$script:ChatMemorySumsSeam = { $script:EcWalks++; $script:EcSums }
$lkMe = [System.Diagnostics.Process]::GetCurrentProcess().ProcessName
$lkMine = if ($lkReal -is [hashtable] -and $lkReal[$lkMe]) { $lkReal[$lkMe] }
Check 'the real walk of the processes: each program''s bytes by name, with each of its processes'' by pid, this one among them' (
    -not $script:ChatqIsWindows -or ($lkMine -and $lkMine.Procs[[int]$PID] -gt 0 -and $lkMine.Bytes -ge $lkMine.Procs[[int]$PID])) "$lkMe $(if ($lkMine) { "$($lkMine.Bytes) $($lkMine.Procs.Count)" })"

# The overlay's own memory (Update-ChatOverlayRestartDue): a compaction's
# figure that many minutes into a run, against overlay.restartMB 300
$rsAt = { param($X, [double]$Min, $MB) Update-ChatOverlayRestartDue $X $MB $emT.AddMinutes($Min); $X.MemRestart }
$rsNew = { param([int]$Limit = 300) @{ StartedAt = $emT; Settled = $null; MemRestart = $null; Ctx = @{ Config = [pscustomobject]@{ restartMB = $Limit } } } }
$rs1 = & $rsNew
$rs1a = @((& $rsAt $rs1 3 239), (& $rsAt $rs1 28 200), (& $rsAt $rs1 30 262), (& $rsAt $rs1 35 255), (& $rsAt $rs1 55 330))
$rs1Settled = $rs1.Settled
$rs1b = & $rsAt $rs1 60 330
$rs1c = & $rsAt $rs1 65 400
$rs2 = & $rsNew
$rs2a = @((& $rsAt $rs2 30 290), (& $rsAt $rs2 90 320), (& $rsAt $rs2 95 $null))
$rs2b = & $rsAt $rs2 95 340
$rs3 = & $rsNew
$rs3a = @((& $rsAt $rs3 10 999), (& $rsAt $rs3 61 999), (& $rsAt $rs3 120 1040))
$rs4 = & $rsNew 0
$rs4a = @((& $rsAt $rs4 30 200), (& $rsAt $rs4 120 999))
$rs5 = & $rsNew
$rs5a = @((& $rsAt $rs5 30 200), (& $rsAt $rs5 120 290))
$rsText = 'private 330 MB after the heap compacted, over overlay.restartMB 300 and 75 over where this run settled - restarting to give it back'
Check 'the overlay''s memory: settled at its least from 30 minutes in; a restart due at restartMB and 50 over that, an hour in, said why - and kept once due' (
    -not @($rs1a | Where-Object { $_ }).Count -and $rs1Settled -eq 255 -and $rs1b -eq $rsText -and $rs1c -eq $rsText) "$rs1Settled / $rs1b / $rs1c"
Check 'never under 50 over where it settled, for a figure that is not there, in the first hour, under restartMB, or with restartMB 0 - so a run that starts high never loops' (
    -not @($rs2a | Where-Object { $_ }).Count -and $rs2b -like 'private 340 MB *, over overlay.restartMB 300 and 50 over*' -and
    -not @($rs3a | Where-Object { $_ }).Count -and $rs3.Settled -eq 999 -and -not @($rs4a | Where-Object { $_ }).Count -and -not @($rs5a | Where-Object { $_ }).Count) (
    "$rs2b / $($rs3.Settled) / $(@($rs3a) -join ',') / $(@($rs4a) -join ',') / $(@($rs5a) -join ',')")

# the tray's item (Set-ChatOverlayCrashChoice), on a host of its own
$efH = @{ Ctx = (New-ChatOverlayContext); Menu = $null; ViewKey = 'k' }
$efH.Ctx.CutAt = Get-Date
Set-ChatOverlayCrashChoice $efH $true
$ef1 = (Get-ChatqConfig).autoContinueCrash -eq $true -and $efH.Ctx.Config.autoContinueCrash -and $efH.Ctx.CutAt -eq [datetime]::MinValue -and $null -eq $efH.ViewKey
$efH.ViewKey = 'k'
Set-ChatOverlayCrashChoice $efH $true
$ef2 = $efH.ViewKey -eq 'k'
Set-ChatOverlayCrashChoice $efH $false
$ef3 = (Get-ChatqConfig).autoContinueCrash -eq $false -and -not $efH.Ctx.Config.autoContinueCrash
$efLog = [System.IO.File]::ReadAllText((Join-Path $script:ChatqLogDir 'overlay.log'), $utf8)
Check 'the tray''s item sets config.json''s autoContinueCrash and reads it back, a fresh look on the next pass; the same choice again does nothing' (
    $ef1 -and $ef2 -and $ef3 -and $efLog -like '*crash continue on from the panel*' -and $efLog -like '*crash continue off from the panel*') "$ef1 $ef2 $ef3"
Restore-TestFile $script:ChatqConfigPath $ecCfgWas
$script:ChatHostAliveSeam = $ecWas.Alive
$script:ChatHostLogRootsSeam = $ecWas.Logs
$script:ChatMemorySeam = $ecWas.Mem
$script:ChatMemoryTopSeam = $ecWas.Top
$script:ChatMemorySumsSeam = $ecWas.Sums
$script:ChatOverlayBalloonSeam = $ecWas.Balloon
Remove-Item -LiteralPath $ecRoot -Recurse -Force -EA SilentlyContinue
