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
    message = [ordered]@{ role = 'user'; content = "<task-notification>`n<task-id>whw0001</task-id>`n<status>completed</status>`n</task-notification>" } } | ConvertTo-Json -Compress -Depth 6
$u = [string][char]92 + 'u00'
[System.IO.File]::AppendAllText($hwFile[$idH4], $hwDone.Replace("${u}3c", '<').Replace("${u}3e", '>') + "`n", $utf8)
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

# written in the last minute: said apart, so the caller can leave out the
# chat a run has just written
(Get-Item -LiteralPath $hwFile[$idH1]).LastWriteTime = Get-Date
$hw5 = Get-ChatHostWork -HostPid 200 -ConfigDir $hwHome
(Get-Item -LiteralPath $hwFile[$idH1]).LastWriteTime = (Get-Date).AddMinutes(-5)
Check 'a transcript written this minute is said apart from why a chat works' (
    (@($hw5.Chats | Where-Object SessionId -eq $idH1))[0].Why -eq '' -and (@($hw5.Chats | Where-Object SessionId -eq $idH1))[0].Written) (Get-HwWhy $hw5)

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
# runs it: the script loads, and one line of JSON comes back
$script:ChatqAliveSeam = $hwSeams.Alive
$script:ChatProcessTableSeam = $hwSeams.Table
$hwExe = (Get-Process -Id $PID).Path
$hwLoader = Join-Path $sb 'tool\claude-codex-chat-manager.ps1'
$hwCmd = "`$env:CHATQ_OVERLAY='1'; . '$hwLoader'; Remove-Variable r -EA SilentlyContinue; `$r = Get-ChatHostWork -HostPid $PID -ConfigDir '$hwHome'; [Console]::Out.WriteLine((ConvertTo-ChatHostWorkJson `$r))"
$hwSw = [System.Diagnostics.Stopwatch]::StartNew()
$hwOut = @(& $hwExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ([Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($hwCmd))) 2>&1 | ForEach-Object { "$_" })
$hwSw.Stop()
$hwLast = @($hwOut | Where-Object { $_.StartsWith('{') }) | Select-Object -Last 1
$hwChild = try { $hwLast | ConvertFrom-Json } catch { $null }
Check "the extension's command in a PowerShell of its own: one line of JSON for this host ($([int]$hwSw.Elapsed.TotalMilliseconds) ms)" (
    $hwChild -and $hwChild.hostPid -eq $PID -and -not @($hwChild.chats).Count) ($hwOut -join ' | ')
