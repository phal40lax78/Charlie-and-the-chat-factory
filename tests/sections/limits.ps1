# tests/sections/limits.ps1: dot-sourced by tests/run-tests.ps1 in its turn,
# never on its own - it uses what the runner and the sections before it set.

Section 'limits'
$b = Get-ChatqClaudeBlock $claudeHome
Check 'future reset found, past one ignored' ($b -and [Math]::Abs(($b.Until - [DateTimeOffset]::FromUnixTimeSeconds($future).LocalDateTime).TotalSeconds) -lt 2) $b
Check 'the record''s own time comes with it' ($b -and $b.At -and $b.At -lt (Get-Date)) $b.At
$x = Get-ChatqCodexBlock $codexHome
Check 'codex full window found' ($x -and $x.Type -eq 'five_hour') $x
$d = ConvertFrom-ChatqLimitText 'try again at Sep 21st, 2026 8:37 AM.'
Check 'codex prose reset time parsed' ($d -eq [datetime]'2026-09-21 08:37') $d
$cut = @(Get-ChatqCutOffChats @())
Check 'cut-off chats listed' (@($cut | Where-Object { $_.Id -eq $idFw }).Count -eq 1) ($cut | ForEach-Object Title)
# the chat the limit just stopped is the one most likely to be missing from the
# index, and a uuid is not what "chatq '<title>' -Continue" below asks for
Remove-ChatIndexRow $pFw
$row = @(Get-ChatqCutOffChats @() | Where-Object { $_.Id -eq $idFw })[0]
Check 'one missing from the index still shows its title' ($row -and $row.Title -eq 'Parser rewrite and plugin unification') "$($row.Title)"
$null = Sync-ChatIndex
# the title is read from the transcript: the index, loaded for it, would stay
# parsed for the overlay's life
$script:ChatIndexCache = $null; $script:ChatIndexStamp = $null
$row = @(Get-ChatqCutOffChats @() | Where-Object { $_.Id -eq $idFw })[0]
Check 'and with the chat in the index, the cut-off scan leaves the index unread' ($row.Title -eq 'Parser rewrite and plugin unification' -and $null -eq $script:ChatIndexStamp) "$($row.Title) / $($script:ChatIndexStamp)"
