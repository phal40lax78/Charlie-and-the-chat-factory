# tests/sections/archive.ps1: dot-sourced by tests/run-tests.ps1 in its turn,
# never on its own - it uses what the runner and the sections before it set.

Section 'archive and restore'
chatrm 'Archive me please' -Archive -Force -NoWait *> $null
$man = Join-Path $script:ChatArchiveDir "claude\$idArch\manifest.json"
Check 'chatrm -Archive moves the chat and its leftovers into data/archive' (-not (Test-Path -LiteralPath $pArch) -and -not (Test-Path -LiteralPath $archHist) -and (Test-Path -LiteralPath $man))
$tomb = if (Test-Path -LiteralPath $script:ChatTombPath) { [System.IO.File]::ReadAllText($script:ChatTombPath, $utf8) } else { '' }
Check 'the old path is tombstoned and leaves the index' ($tomb -like "*$idArch*" -and -not @(Get-ChatIndex | Where-Object { $_.Id -eq $idArch }))
Check 'chatrestore lists it' (@(Get-ChatArchive | Where-Object { $_.Id -eq $idArch }).Count -eq 1)
# what the window writes back on its next reload: a stub, no messages
[System.IO.File]::WriteAllText($pArch, ('{"type":"ai-title","aiTitle":"Archive me please","sessionId":"' + $idArch + '"}' + "`n"), $utf8)
chatrestore 'Archive me please' *> $null
$backText = if (Test-Path -LiteralPath $pArch) { [System.IO.File]::ReadAllText($pArch, $utf8) } else { '' }
Check 'restore replaces the stub with the chat, leftovers and all' ($backText -like '*archive this one*' -and (Test-Path -LiteralPath (Join-Path $archHist 'x')) -and -not (Test-Path -LiteralPath (Split-Path $man -Parent)))
$tomb = if (Test-Path -LiteralPath $script:ChatTombPath) { [System.IO.File]::ReadAllText($script:ChatTombPath, $utf8) } else { '' }
Check 'its tombstone is cleared and it is back in the index' ($tomb -notlike "*$idArch*" -and @(Get-ChatIndex | Where-Object { $_.Id -eq $idArch }).Count -eq 1)
chatrm 'Archive me please' -Archive -Force -NoWait *> $null
[System.IO.File]::WriteAllText($pArch, ('{"type":"user","message":{"role":"user","content":"written since"},"sessionId":"x"}' + "`n"), $utf8)
chatrestore 'Archive me please' *> $null
Check 'restore never moves over a chat with messages in it' ((Test-Path -LiteralPath $man) -and ([System.IO.File]::ReadAllText($pArch, $utf8) -like '*written since*'))
Remove-Item -LiteralPath $pArch -Force
chatrestore 'Archive me please' *> $null
$env:FAKE_AGENTS = '[{"pid":1,"sessionId":"' + $idArch + '","kind":"interactive","status":"idle"}]'
chatrm 'Archive me please' -Archive -Force -NoWait *> $null
Remove-Item env:FAKE_AGENTS
Check 'a chat still open in a window is not archived' ((Test-Path -LiteralPath $pArch) -and -not (Test-Path -LiteralPath $man))
chatrm 'Codex gitignore thread' -Archive -Force -NoWait *> $null
$cxArch = @(Get-ChildItem -LiteralPath (Join-Path $codexHome 'archived_sessions') -Filter "*$cxId*" -Recurse -File -EA SilentlyContinue)
Check 'a Codex thread goes through codex archive' ($cxArch.Count -eq 1 -and -not (Test-Path -LiteralPath $cxPath))
Check 'and chatrestore lists it too' (@(Get-ChatArchive | Where-Object { $_.Id -eq $cxId -and $_.Provider -eq 'codex' }).Count -eq 1)
chatrestore 'Codex gitignore thread' *> $null
Check 'codex unarchive brings it back' ((Test-Path -LiteralPath $cxPath) -and -not (Test-Path -LiteralPath (Join-Path $script:ChatArchiveDir "codex\$cxId")))
# One home per thread (F4): codex archive and unarchive are told the home
# the rollout is under, and the manifest keeps it - never a CODEX_HOME the
# shell set since chatq loaded, where codex would find no such thread
Check 'Get-ChatCodexHomeOf: the folder over sessions/ or archived_sessions/, else none' (
    (Get-ChatCodexHomeOf 'D:\acct2\.codex\sessions\2026\09\20\rollout-x.jsonl') -eq 'D:\acct2\.codex' -and
    (Get-ChatCodexHomeOf 'D:\acct2\.codex\archived_sessions\2026\09\20\rollout-x.jsonl') -eq 'D:\acct2\.codex' -and
    $null -eq (Get-ChatCodexHomeOf 'D:\acct2\.codex\rollout-x.jsonl') -and $null -eq (Get-ChatCodexHomeOf '')) ''
$cxEnvWas = $env:CODEX_HOME
$cxElse = Join-Path $sb 'codex-elsewhere'
$cxMan = $null; $cxRow = $null; $cxGone = $false; $cxBack = $false
try {
    $env:CODEX_HOME = $cxElse
    chatrm 'Codex gitignore thread' -Archive -Force -NoWait *> $null
    $cxGone = -not (Test-Path -LiteralPath $cxPath)
    $cxMan = Read-ChatqJson (Join-Path $script:ChatArchiveDir "codex\$cxId\manifest.json")
    $cxRow = @(Get-ChatArchive | Where-Object { $_.Id -eq $cxId })[0]
    chatrestore 'Codex gitignore thread' *> $null
    $cxBack = Test-Path -LiteralPath $cxPath
}
finally { $env:CODEX_HOME = $cxEnvWas }
Check 'archive and restore go to the rollout''s own Codex home, kept in the manifest, whatever CODEX_HOME says by then' (
    $cxGone -and $cxMan -and $cxMan.home -eq $codexHome -and $cxRow -and $cxRow.CodexHome -eq $codexHome -and $cxBack -and
    -not (Test-Path -LiteralPath $cxElse)) "gone $cxGone, manifest home $(if ($cxMan) { $cxMan.home }), row home $(if ($cxRow) { $cxRow.CodexHome }), back $cxBack"
# a second account's archived_sessions is listed when asked for, with its home
$cxSecond = Join-Path $sb 'codex-second'
$cxSecId = '01900000-0000-7000-8000-0000000000c1'
$cxSecDir = Join-Path $cxSecond 'archived_sessions\2026\09\22'
$null = New-Item -ItemType Directory -Path $cxSecDir -Force
[System.IO.File]::WriteAllText((Join-Path $cxSecDir "rollout-2026-09-22T08-00-00-$cxSecId.jsonl"), $cxLines[0] + "`n", $utf8)
$secRow = @(Get-ChatArchive -CodexHome $cxSecond | Where-Object { $_.Id -eq $cxSecId })[0]
$secDefault = @(Get-ChatArchive | Where-Object { $_.Id -eq $cxSecId })
Remove-Item -LiteralPath $cxSecond -Recurse -Force -EA SilentlyContinue
Check 'Get-ChatArchive -CodexHome lists that home''s archived threads, each carrying the home; the default does not' (
    $secRow -and $secRow.Provider -eq 'codex' -and $secRow.CodexHome -eq $cxSecond -and $secDefault.Count -eq 0) "$(if ($secRow) { $secRow.CodexHome }) / $($secDefault.Count)"

# A Codex thread at work is kept out of the archive (Get-ChatCodexBusy): read
# from the rollout alone, as Codex keeps no registry another process can read
$cxEvent = {
    param([datetime]$At, $Payload)
    ([ordered]@{ timestamp = $At.ToUniversalTime().ToString('o'); type = 'event_msg'; payload = $Payload } | ConvertTo-Json -Compress -Depth 6) + "`n"
}
$cxBusyDir = Join-Path $sb 'codex-busy'
$null = New-Item -ItemType Directory -Path $cxBusyDir -Force
$cxBusy = Join-Path $cxBusyDir 'rollout-2026-09-20T11-00-00-01900000-0000-7000-8000-0000000000b1.jsonl'
$cxHead = [System.IO.File]::ReadAllText($cxPath, $utf8)
# a turn reads open only while a codex holds the rollout open to write, as a
# live one does: held here as codex holds it, every share allowed
$cxHeld = {
    param([string]$P, [scriptblock]$Do)
    $h = [System.IO.FileStream]::new($P, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
    try { & $Do } finally { $h.Dispose() }
}
$tNow = Get-Date
$tTen = $tNow.AddMinutes(-10)
# a record written just now: Codex is writing
[System.IO.File]::WriteAllText($cxBusy, $cxHead + (& $cxEvent $tNow ([ordered]@{ type = 'agent_message'; message = 'working on it' })), $utf8)
$b = Get-ChatCodexBusy $cxBusy
Check 'a Codex rollout with a record written just now is busy, writing' ($b -and $b.Why -eq 'writing')
# only touched, its records an hour old: nothing wrote a turn
[System.IO.File]::WriteAllText($cxBusy, $cxHead, $utf8)
Check 'one only touched, its records old, is not' ($null -eq (Get-ChatCodexBusy $cxBusy))
# a turn that started ten minutes ago and has not ended: waiting on an
# approval, or inside a long command, writes nothing
[System.IO.File]::WriteAllText($cxBusy, $cxHead + (& $cxEvent $tTen ([ordered]@{ type = 'task_started'; turn_id = 't1'; model_context_window = 258400 })), $utf8)
$b = & $cxHeld $cxBusy { Get-ChatCodexBusy $cxBusy }
Check 'a task_started with no end is a turn going, and says when it started' ($b -and $b.Why -eq 'turn' -and $b.At -and [Math]::Abs(($b.At - $tTen).TotalSeconds) -lt 2)
# the same start in a rollout no codex holds: its codex was killed (a job
# stopped with taskkill writes no end), so nothing is left to wait for
Check 'an open turn in a rollout no process holds is a dead one' ($null -eq (Get-ChatCodexBusy $cxBusy)) "$((Get-ChatCodexBusy $cxBusy) | ConvertTo-Json -Compress)"
# a killed turn t0 with no end, then a later turn t1 that finished: one turn
# at a time, so t1's start ended t0 - held open by the panel, still not busy
[System.IO.File]::WriteAllText($cxBusy, $cxHead + (& $cxEvent $tTen.AddMinutes(-5) ([ordered]@{ type = 'task_started'; turn_id = 't0' })) +
    (& $cxEvent $tTen ([ordered]@{ type = 'task_started'; turn_id = 't1' })) + (& $cxEvent $tTen.AddMinutes(1) ([ordered]@{ type = 'task_complete'; turn_id = 't1'; last_agent_message = 'done' })), $utf8)
$b = & $cxHeld $cxBusy { Get-ChatCodexBusy $cxBusy }
Check 'a turn left open by a killed codex, then a later one finished: not busy' ($null -eq $b) "$($b | ConvertTo-Json -Compress)"
$cxDone = $cxHead + (& $cxEvent $tTen.AddMinutes(-5) ([ordered]@{ type = 'task_started'; turn_id = 't0' })) + (& $cxEvent $tTen.AddMinutes(-4) ([ordered]@{ type = 'task_complete'; turn_id = 't0'; last_agent_message = 'done' }))
[System.IO.File]::WriteAllText($cxBusy, $cxDone + (& $cxEvent $tTen ([ordered]@{ type = 'task_started'; turn_id = 't1' })) + (& $cxEvent $tTen.AddMinutes(1) ([ordered]@{ type = 'task_complete'; turn_id = 't1'; last_agent_message = 'done' })), $utf8)
Check 'every turn ended by its task_complete: not busy' ($null -eq (Get-ChatCodexBusy $cxBusy))
[System.IO.File]::WriteAllText($cxBusy, $cxDone + (& $cxEvent $tTen ([ordered]@{ type = 'task_started'; turn_id = 't1' })) + (& $cxEvent $tTen.AddMinutes(1) ([ordered]@{ type = 'turn_aborted'; turn_id = 't1'; reason = 'interrupted' })), $utf8)
Check 'a turn you stopped (turn_aborted) is not busy either' ($null -eq (Get-ChatCodexBusy $cxBusy))
# an older turn ended, the newest one not: busy, from the newest one's start
[System.IO.File]::WriteAllText($cxBusy, $cxDone + (& $cxEvent $tTen ([ordered]@{ type = 'task_started'; turn_id = 't1' })), $utf8)
$b = & $cxHeld $cxBusy { Get-ChatCodexBusy $cxBusy }
Check 'an ended turn before an open one leaves it open' ($b -and $b.Why -eq 'turn' -and [Math]::Abs(($b.At - $tTen).TotalSeconds) -lt 2)
# a start only quoted in a reply's text is escaped there, never an event
$cxQuote = [ordered]@{ type = 'agent_message'; message = 'the rollout reads {"type":"task_started","turn_id":"t9"}' }
[System.IO.File]::WriteAllText($cxBusy, $cxDone + (& $cxEvent $tTen $cxQuote), $utf8)
Check 'a task_started quoted in a reply is not a turn' ($null -eq (Get-ChatCodexBusy $cxBusy))
# an open turn in a rollout not written for half a day: its codex was killed
[System.IO.File]::WriteAllText($cxBusy, $cxDone + (& $cxEvent $tTen ([ordered]@{ type = 'task_started'; turn_id = 't1' })), $utf8)
(Get-Item -LiteralPath $cxBusy).LastWriteTime = $tNow.AddHours(-($script:ChatCodexTurnStaleHours + 1))
Check 'an open turn in a rollout untouched for ChatCodexTurnStaleHours is a dead one' ($null -eq (Get-ChatCodexBusy $cxBusy -Now $tNow))
# a start further back than the tail read: missed, and only the written check is left
[System.IO.File]::WriteAllText($cxBusy, $cxHead + (& $cxEvent $tTen ([ordered]@{ type = 'task_started'; turn_id = 't1' })) + (& $cxEvent $tTen ([ordered]@{ type = 'agent_message'; message = ('x' * 4096) })), $utf8)
Check 'a start further back than -Size is missed, as its comment says' ($null -eq (Get-ChatCodexBusy $cxBusy -Size 2048))
Remove-Item -LiteralPath $cxBusyDir -Recurse -Force -EA SilentlyContinue

# end to end on the sandbox's own thread, put back as it was after each
$cxBytes = [System.IO.File]::ReadAllBytes($cxPath)
$cxWrote = (Get-Item -LiteralPath $cxPath).LastWriteTime
$cxArchived = { @(Get-ChildItem -LiteralPath (Join-Path $codexHome 'archived_sessions') -Filter "*$cxId*" -Recurse -File -EA SilentlyContinue).Count }
try {
    [System.IO.File]::AppendAllText($cxPath, (& $cxEvent (Get-Date) ([ordered]@{ type = 'agent_message'; message = 'working on it' })), $utf8)
    $cxOut = (chatrm 'Codex gitignore thread' -Archive -Force -NoWait *>&1 | Out-String -Width 300)
    Check 'chatrm -Archive keeps a Codex thread written just now in sessions/, and says why' ((Test-Path -LiteralPath $cxPath) -and (& $cxArchived) -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $script:ChatArchiveDir "codex\$cxId")) -and $cxOut -like '*Codex is writing to it*')
    [System.IO.File]::WriteAllBytes($cxPath, $cxBytes)
    [System.IO.File]::AppendAllText($cxPath, (& $cxEvent (Get-Date).AddMinutes(-10) ([ordered]@{ type = 'task_started'; turn_id = 't1' })), $utf8)
    $cxOut = & $cxHeld $cxPath { chatrm 'Codex gitignore thread' -Archive -Force -NoWait *>&1 | Out-String -Width 300 }
    Check 'and one whose turn has not ended, though nothing was written for 10 minutes' ((Test-Path -LiteralPath $cxPath) -and (& $cxArchived) -eq 0 -and $cxOut -like '*has not ended*')
}
finally {
    [System.IO.File]::WriteAllBytes($cxPath, $cxBytes)
    (Get-Item -LiteralPath $cxPath).LastWriteTime = $cxWrote
}
chatrm 'Archive me please' -Archive -Force -NoWait *> $null
chatuninstall -All *> $null
Check 'chatuninstall -All will not take the only copy of an archived chat' ((Test-Path -LiteralPath $man) -and (Test-Path -LiteralPath (Join-Path $sb 'tool\Charlie-and-the-chat-factory.ps1')))
chatrestore 'Archive me please' *> $null
