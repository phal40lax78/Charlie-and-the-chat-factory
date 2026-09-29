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
chatrm 'Archive me please' -Archive -Force -NoWait *> $null
chatuninstall -All *> $null
Check 'chatuninstall -All will not take the only copy of an archived chat' ((Test-Path -LiteralPath $man) -and (Test-Path -LiteralPath (Join-Path $sb 'tool\Charlie-and-the-chat-factory.ps1')))
chatrestore 'Archive me please' *> $null
