# tests/sections/alert-channels.ps1: dot-sourced by tests/run-tests.ps1 in its turn,
# never on its own - it uses what the runner and the sections before it set.

Section 'alert channels'
$topic = 'chatq-test-topic-7f3a'
$said = (chatnotify -Ntfy $topic 6>&1 | Out-String)
Check 'ntfy is saved, and the topic is never printed whole' ((Get-ChatqConfig).ntfy.topic -and $said -notlike "*$topic*" -and $said -like '*cha...*') $said
$script:ChatqIdleSeam = 30
$n0 = $script:Ntfys.Count; $t0 = $script:Toasts.Count
$sent = Send-ChatqAlert 'done' 'at the desk' 1
Check 'at the PC: the toast shows, the phone stays quiet' ($script:Toasts.Count -eq $t0 + 1 -and $script:Ntfys.Count -eq $n0 -and -not $sent)
chatnotify -Test *> $null
Check 'chatnotify -Test reaches the phone anyway' ($script:Ntfys.Count -eq $n0 + 1)
$script:ChatqIdleSeam = 99999
$txt = "done $([char]0xC644)$([char]0xB8CC) a & b %PATH%"
$sent = Send-ChatqAlert 'done' $txt 2
$nb = $script:Ntfys[$script:Ntfys.Count - 1].Body | ConvertFrom-Json
Check 'away: ntfy gets JSON - the title, Hangul intact, priority 5' ($sent -and $nb.topic -eq $topic -and $nb.title -eq "chatq $([char]0xB7) done" -and $nb.message -eq $txt -and $nb.priority -eq 5) ($script:Ntfys[$script:Ntfys.Count - 1].Body)
$hookOut = Join-Path $sb 'hook.txt'
chatnotify -Command ("Set-Content -LiteralPath '$hookOut' -Encoding UTF8 -Value (`$env:CHATQ_EVENT + '|' + `$env:CHATQ_TEXT + '|' + `$env:CHATQ_PRESENT)") *> $null
$null = Send-ChatqAlert 'needs input' $txt 2
$hk = if (Test-Path -LiteralPath $hookOut) { [System.IO.File]::ReadAllText($hookOut, $utf8).Trim() } else { '' }
Check 'the command gets the alert in its environment, & and %PATH% as they are' ($hk -eq "needs input|$txt|0") $hk
$script:ChatqHookTimeoutSec = 2
chatnotify -Command 'Start-Sleep -Seconds 30' *> $null
$t1 = Get-Date
$null = Send-ChatqAlert 'test' 'slow hook' 0
Check 'a command that hangs is stopped' ((@($script:ChatqAlertReport) -join ' ') -like '*stopped after 2 s*' -and ((Get-Date) - $t1).TotalSeconds -lt 15) (@($script:ChatqAlertReport) -join ' ')
$script:ChatqHookTimeoutSec = $null
# the Join page shows a whole push URL, and pasting it is the obvious move
chatnotify -ApiKey 'https://joinjoaomgcd.appspot.com/_ah/api/messaging/v1/sendPush?apikey=deadbeefcafe1234&deviceId=abc123' *> $null
$jn = (Get-ChatqConfig).join
Check 'a pasted Join URL gives up its key and device' ((Unprotect-ChatqSecret $jn.apiKey) -eq 'deadbeefcafe1234' -and $jn.device -eq 'abc123') "$($jn.device)"
chatnotify -Off *> $null
Check 'chatnotify -Off clears the phone and the command' (-not (Get-ChatqConfig).PSObject.Properties['ntfy'] -and -not (Get-ChatqConfig).PSObject.Properties['command'])
# chatqnotify is the old name, and a profile or a habit may still type it
$newSaid = (chatnotify 6>&1 | Out-String)
$oldSaid = (chatqnotify 6>&1 | Out-String)
Check 'chatqnotify still works, and says what chatnotify says' ($newSaid.Trim() -and $oldSaid -eq $newSaid) $oldSaid
$oldCmd = Get-Command chatqnotify -EA SilentlyContinue
Check 'Get-Command chatqnotify is the alias of chatnotify' ($oldCmd -and $oldCmd.CommandType -eq 'Alias' -and $oldCmd.ResolvedCommand.Name -eq 'chatnotify') "$($oldCmd.CommandType) $($oldCmd.Definition)"
$oldHelp = Get-Help chatqnotify -EA SilentlyContinue
Check 'Get-Help chatqnotify finds the help of chatnotify' ($oldHelp -and $oldHelp.Name -eq 'chatnotify' -and "$($oldHelp.Synopsis)" -like 'Phone alerts through Join*') "$($oldHelp.Name) $($oldHelp.Synopsis)"
$script:ChatqIdleSeam = $null
$idle = try { Get-ChatqIdleSeconds } catch { 'threw' }
$script:ChatqIdleSeam = 99999
Check 'the idle clock reads without an error' ($null -eq $idle -or ($idle -is [double] -and $idle -ge 0)) "$idle"
# away is what lets a window reload by itself, so it is known, never assumed
$script:ChatqIdleSeam = 30
$awayAt = Test-ChatqUserAway $null
$script:ChatqIdleSeam = 99999
$awayGone = Test-ChatqUserAway $null
$awayZero = Test-ChatqUserAway ([pscustomobject]@{ quietMinutes = 0 })
$origIdle = ${function:Get-ChatqIdleSeconds}
${function:Get-ChatqIdleSeconds} = { $null }
$awayBlind = Test-ChatqUserAway $null
${function:Get-ChatqIdleSeconds} = $origIdle
Check 'away only when known: not at the PC, not with quietMinutes 0, not on a clock that cannot be read' (-not $awayAt -and -not $awayZero -and $awayGone -and -not $awayBlind) "$awayAt $awayZero $awayGone $awayBlind"
