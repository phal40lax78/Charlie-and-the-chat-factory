# tests/sections/alert-channels.ps1: dot-sourced by tests/run-tests.ps1 in its turn,
# never on its own - it uses what the runner and the sections before it set.

Section 'alert channels'
$topic = 'chatq-test-topic-7f3a'
$said = (chatnotify -Ntfy $topic 6>&1 | Out-String -Width 400)
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
$newSaid = (chatnotify 6>&1 | Out-String -Width 400)
$oldSaid = (chatqnotify 6>&1 | Out-String -Width 400)
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
# phoneWhilePresent opens the phone gates at the PC, never the reload's
$script:ChatqIdleSeam = 30
$pwp = [pscustomobject]@{ quietMinutes = 1; phoneWhilePresent = $true }
$pwpAway = Test-ChatqUserAway $pwp
$pwpPhone = Test-ChatqPhoneAway $pwp
$pwpPresent = Test-ChatqUserPresent $pwp
$pwpOff = Test-ChatqPhoneAway ([pscustomobject]@{ quietMinutes = 1 })
$script:ChatqIdleSeam = 99999
Check 'phoneWhilePresent: the phone is sent to at the PC, a reload still waits for away' (-not $pwpAway -and $pwpPhone -and -not $pwpPresent -and -not $pwpOff) "$pwpAway $pwpPhone $pwpPresent $pwpOff"
# the phone alert's footer: usage turned to what is left, and the queue
$ftUsage = ${function:Get-ChatqUsage}
$ftCounts = ${function:Get-ChatqChatCounts}
$ftSeam = $script:ChatqFooterSeam
$script:ChatqFooterSeam = $null
try {
    # Codex at 0% everywhere is not in use: left out
    ${function:Get-ChatqUsage} = { @([pscustomobject]@{ Provider = 'Claude'; Parts = @('5h 42%', 'week 18%'); AsOf = '12:00' },
            [pscustomobject]@{ Provider = 'Codex'; Parts = @('5h 0%', 'week 0%'); AsOf = '12:00' }) }
    ${function:Get-ChatqChatCounts} = { [pscustomobject]@{ busy = 1; waiting = 1 } }
    $ftBoth = Get-ChatqAlertFooter
    ${function:Get-ChatqUsage} = { throw 'no usage' }
    ${function:Get-ChatqChatCounts} = { [pscustomobject]@{ busy = 0; waiting = 0 } }
    $ftNone = Get-ChatqAlertFooter
}
finally { ${function:Get-ChatqUsage} = $ftUsage; ${function:Get-ChatqChatCounts} = $ftCounts; $script:ChatqFooterSeam = $ftSeam }
$ftWant = "Claude 5h 42%, week 18% $($script:ChatqDot) 1 working, 1 waiting"
Check 'the phone alert footer: how much of each window is used and the chats at work; a provider at 0% and usage unread are left out' ($ftBoth -eq $ftWant -and $ftNone -eq '0 working') "[$ftBoth] [$ftNone]"
# The footer's chats are the overlay's: its snapshot's counts while fresh,
# else the registry with each chat's background work - a chat idle to Claude
# with a background shell running is working, as on the panel (the push once
# said 1 working where the panel showed 3)
$ftPath = $script:ChatOverlayPath
$ftFns = @{}
foreach ($n in 'Read-ChatqSessionRegistry', 'Test-ChatqSessionAlive', 'Update-ChatOverlayText', 'Update-ChatOverlayBackground') { $ftFns[$n] = (Get-Item "function:$n").ScriptBlock }
try {
    $script:ChatOverlayPath = Join-Path $sb 'footer-overlay.json'
    $ftNowMs = [DateTimeOffset]::new((Get-Date)).ToUnixTimeMilliseconds()
    [System.IO.File]::WriteAllText($script:ChatOverlayPath, (@{ schema = 1; at = $ftNowMs; counts = @{ busy = 3; waiting = 2 } } | ConvertTo-Json -Compress))
    $ftSnap = Get-ChatqChatCounts
    # a: busy; b: busy in one window, waiting in another - waiting; c: idle
    # to Claude with a background shell - working; d: busy but a print run;
    # e: idle
    ${function:Read-ChatqSessionRegistry} = {
        @([pscustomobject]@{ SessionId = 'a'; Status = 'busy'; Kind = 'interactive'; Pid = 1 },
            [pscustomobject]@{ SessionId = 'b'; Status = 'busy'; Kind = 'interactive'; Pid = 2 },
            [pscustomobject]@{ SessionId = 'b'; Status = 'waiting'; Kind = 'interactive'; Pid = 3 },
            [pscustomobject]@{ SessionId = 'c'; Status = 'idle'; Kind = 'interactive'; Pid = 4 },
            [pscustomobject]@{ SessionId = 'd'; Status = 'busy'; Kind = 'print'; Pid = 5 },
            [pscustomobject]@{ SessionId = 'e'; Status = 'idle'; Kind = 'interactive'; Pid = 6 })
    }
    ${function:Test-ChatqSessionAlive} = { $true }
    ${function:Update-ChatOverlayText} = { }
    ${function:Update-ChatOverlayBackground} = { @{ c = [pscustomobject]@{ Count = 1; Workflows = 0; Agents = 0; Shells = 1 } } }
    # the snapshot 5 minutes old: the overlay is not running
    [System.IO.File]::WriteAllText($script:ChatOverlayPath, (@{ schema = 1; at = $ftNowMs - 300000; counts = @{ busy = 3; waiting = 2 } } | ConvertTo-Json -Compress))
    $ftScan = Get-ChatqChatCounts
}
finally {
    foreach ($n in $ftFns.Keys) { Set-Item "function:$n" $ftFns[$n] }
    Remove-Item -LiteralPath $script:ChatOverlayPath -EA SilentlyContinue
    $script:ChatOverlayPath = $ftPath
}
Check 'the footer counts chats as the overlay does: its fresh snapshot, else background work counts as working' ($ftSnap.busy -eq 3 -and $ftSnap.waiting -eq 2 -and $ftScan.busy -eq 2 -and $ftScan.waiting -eq 1) "snap $($ftSnap.busy)/$($ftSnap.waiting) scan $($ftScan.busy)/$($ftScan.waiting)"
# ... and on the reply page too, as s=, kept when the link is made again
$ftLink = Get-ChatqReplyLink ([pscustomobject]@{ Page = 'https://x.test/reply.html' }) 'abcdefghij' 'done' $null -Status $ftWant
Check 'the reply link carries the footer as s=' ($ftLink -match '&s=([^&]+)$' -and [Uri]::UnescapeDataString($Matches[1]) -eq $ftWant) $ftLink
