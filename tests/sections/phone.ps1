# tests/sections/phone.ps1: dot-sourced by tests/run-tests.ps1 in its turn,
# never on its own - it uses what the runner and the sections before it set.
#
# Replies from the phone (src/phone.ps1): the phone is paired here as the page
# pairs it - its key sealed to the public key in the pairing push - and
# replies are sealed as the page seals them, fed to Invoke-ChatqReplyPoll
# through the poll seam; Join pushes land in the Join seam. No Join or ntfy
# traffic, no real watcher. Everything changed - config, seams, the registry,
# the jobs and chats made here - is put back at the end.

Section 'phone replies'
$phCfgWas = Read-TestFile $script:ChatqConfigPath
$phWas = @{ Spawn = $script:ChatqSpawn; Join = $script:ChatqJoinSeam; Poll = $script:ChatqReplyPollSeam; Devices = $script:ChatqJoinDevicesSeam; Idle = $script:ChatqIdleSeam
    Foreground = $script:ChatqForeground; Ask = $script:ChatqAskSeam; PairWait = $script:ChatqPairWaitSeam }
# chatnotify -Pair waits for the phone and asks only where it can ask: here
# never, unless a check says so and answers through the seam itself
$script:ChatqAskSeam = $false
$script:ChatqPairWaitSeam = $null
$script:ChatqReplyJunkLog = @{}
$phJobsBefore = @(Get-ChatqJobs | ForEach-Object { [string]$_.id })
$script:ChatqIdleSeam = 99999
# a watcher loop run -Foreground earlier leaves its log echoing to the host
$script:ChatqForeground = $false
$script:PhJoins = [System.Collections.Generic.List[string]]::new()
$script:ChatqJoinSeam = { param($u) $script:PhJoins.Add($u); $null }
$script:PhFeed = ''
$script:PhPolls = [System.Collections.Generic.List[string]]::new()
$script:ChatqReplyPollSeam = { param($u) $script:PhPolls.Add($u); $script:PhFeed }
$script:PhSpawns = 0
$script:ChatqSpawn = { $script:PhSpawns++; $true }
$script:ChatqReplySeen = @{}; $script:ChatqReplyHandled = @{}
$phLastJoin = {
    # the last Join push: its query, and its link's fragment, as hashtables
    Get-JoinPush $script:PhJoins[$script:PhJoins.Count - 1]
}
# what ntfy's poll answers: one JSON message per line, @(id, body) pairs
$phFeedOf = { param([object[]]$Msgs) ($Msgs | ForEach-Object { ([ordered]@{ id = $_[0]; time = 1; event = 'message'; topic = 't'; message = $_[1] } | ConvertTo-Json -Compress) }) -join "`n" }
$phSay = { param([string]$Id, [string]$Body) $script:PhFeed = & $phFeedOf @(, @($Id, $Body)); $null = Invoke-ChatqReplyPoll -Force; (& $phLastJoin).Q['text'] }
$phLog = { $p = Join-Path $script:ChatqLogDir 'replies.log'; if (Test-Path -LiteralPath $p) { [System.IO.File]::ReadAllText($p, $utf8) } else { '' } }
$phAsked = {
    # a job stopped on a question, and its needs input alert sent: the alert's id
    param($PhJob, [string]$PhWhy)
    Complete-ChatqJob $PhJob 'needs-input' ([pscustomobject]@{ kind = 'needs-input'; reason = $PhWhy }) 'asked'
    $null = Send-ChatqAlert 'needs input' 'x' 2 -Job $PhJob
    (& $phLastJoin).F['a']
}
function New-PhPairMessage {
    # what the page sends on Pair: the phone's key and label, sealed to the
    # public key in the pairing link's fragment
    param([hashtable]$F, [byte[]]$D, [string]$Label, [int64]$Ts = 0, [string]$PairId)
    if (-not $Ts) { $Ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
    if (-not $PairId) { $PairId = $F['a'] }
    $json = [ordered]@{ v = 2; d = (ConvertTo-ChatqB64Url $D); label = $Label; ts = $Ts } | ConvertTo-Json -Compress
    $pp = New-Object System.Security.Cryptography.RSAParameters
    $pp.Modulus = ConvertFrom-ChatqB64Url $F['n']
    $pp.Exponent = ConvertFrom-ChatqB64Url $F['x']
    $r = New-ChatqRsa
    try { $r.ImportParameters($pp); $ct = $r.Encrypt((New-Object System.Text.UTF8Encoding $false).GetBytes($json), [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256) }
    finally { $r.Dispose() }
    return 'chatq2p.' + $PairId + '.' + (ConvertTo-ChatqB64Url $ct)
}

# --- the wire format, against Node's own crypto --------------------------------
# tests/fixtures/reply-vector.json is made by tests/fixtures/make-reply-vector.js
# with Node's crypto module; docs/reply.html is held to the same file by
# tests/reply-page-check.js. Read as UTF-8: the payload holds Hangul.
$fx = [System.IO.File]::ReadAllText((Join-Path (Join-Path $here 'fixtures') 'reply-vector.json'), $utf8) | ConvertFrom-Json
$fxMaster = ConvertFrom-ChatqB64Url $fx.master
$fxMsg = Protect-ChatqReplyMessage -Key $fx.master -Aid $fx.aid -Iv (ConvertFrom-ChatqB64Url $fx.iv) -Payload $fx.payload
$fxK = ConvertTo-ChatqB64Url (Get-ChatqReplyKeys $fxMaster $fx.aid).K
Check 'the test vector: the per-alert key and the sealed message, byte for byte' ($fxMsg -ceq $fx.message -and $fxK -ceq $fx.k) "$fxK | $fxMsg"
$fxOpen = Unprotect-ChatqReplyMessage $fx.message $fxMaster
Check 'the test vector opens: prompt, Hangul intact, nonce and time' ($fxOpen.Ok -and $fxOpen.Aid -eq 'abcdefghij' -and $fxOpen.Payload.act -eq 'prompt' -and
    $fxOpen.Payload.text -eq (U 'yes, commit it \uD55C\uAE00') -and $fxOpen.Payload.nonce -eq 'AAAAAAAAAAAAAAAAAAAAAA' -and [int64]$fxOpen.Payload.ts -eq 1790000000000) "$($fxOpen.Stage) $($fxOpen.Error)"
$fxParts = $fx.message.Split('.')
$fxFlip = $fxParts.Clone(); $fxFlip[3] = $(if ($fxFlip[3][0] -ceq 'A') { 'B' } else { 'A' }) + $fxFlip[3].Substring(1)
$fxOther = [byte[]](1..32)
$fxBad = @(
    (Unprotect-ChatqReplyMessage ($fxFlip -join '.') $fxMaster).Stage
    (Unprotect-ChatqReplyMessage $fx.message $fxOther).Stage
    (Unprotect-ChatqReplyMessage ('chatq1.ABCDEFGHIJ.' + ($fxParts[2..4] -join '.')) $fxMaster).Stage
    (Unprotect-ChatqReplyMessage 'hello there' $fxMaster).Stage
    (Unprotect-ChatqReplyMessage ($fxParts[0..3] -join '.') $fxMaster).Stage
)
Check 'a flipped body or the wrong key fails the MAC; a bad aid, junk or a missing part fails the format' (($fxBad -join ',') -eq 'mac,mac,format,format,format') ($fxBad -join ',')

# --- pairing, against Node's own RSA-OAEP ----------------------------------------
# tests/fixtures/pair-vector.json: a fixed RSA key and a pairing message Node
# sealed to it (OAEP is randomised, so the message is opened, not remade)
$pv = [System.IO.File]::ReadAllText((Join-Path (Join-Path $here 'fixtures') 'pair-vector.json'), $utf8) | ConvertFrom-Json
$pvKey = $pv.private | ConvertTo-Json -Compress
$pvOpen = Unprotect-ChatqPairMessage $pv.message $pvKey $pv.pid
Check 'the pairing vector: Node''s RSA-OAEP-SHA256 message opens with its key, the payload byte for byte' ($pvOpen.Ok -and $pvOpen.Json -ceq $pv.payload -and
    (ConvertFrom-ChatqB64Url $pvOpen.Payload.d).Length -eq 32 -and $pvOpen.Payload.label -eq 'Android - Chrome 128') "$($pvOpen.Error) | $($pvOpen.Json)"
# the same key with every number's leading zero bytes dropped, as a JWK
# export drops them: padded back, it opens the same message
$pvLean = [ordered]@{}
foreach ($n in 'Modulus', 'Exponent', 'D', 'P', 'Q', 'DP', 'DQ', 'InverseQ') {
    $bytes = [Convert]::FromBase64String([string]$pv.private.$n)
    $i = 0; while ($i -lt $bytes.Length - 1 -and $bytes[$i] -eq 0) { $i++ }
    $pvLean[$n] = [Convert]::ToBase64String([byte[]]$bytes[$i..($bytes.Length - 1)])
}
$pvLeanOpen = Unprotect-ChatqPairMessage $pv.message ($pvLean | ConvertTo-Json -Compress) $pv.pid
$pvRz = @(((Resize-ChatqBigEndian ([byte[]](1, 2)) 4) -join ','), ((Resize-ChatqBigEndian ([byte[]](0, 0, 1, 2)) 3) -join ','))
Check 'key numbers short of their length are padded in front, longer ones lose leading zeros' ($pvLeanOpen.Ok -and $pvLeanOpen.Json -ceq $pv.payload -and
    ($pvRz -join ' ') -eq '0,0,1,2 0,1,2') "$($pvLeanOpen.Error) | $($pvRz -join ' ')"
# The confirmation code of the fixture's D, against the fixture's own "code"
# (Node's createHmac, written by tests/fixtures/make-pair-vector.js). A
# fixture from before it had one is checked against the same computation
# run in Node here, else against its result, 026316.
$pvD = ConvertFrom-ChatqB64Url $pvOpen.Payload.d
$pvCode = Get-ChatqPairCode $pvD
$pvWant = if ($pv.PSObject.Properties['code'] -and $pv.code) { ([string]$pv.code) -replace '\D', '' }
elseif (Get-Command node -EA SilentlyContinue) {
    $js = "const c=require('crypto');const h=c.createHmac('sha256',Buffer.from('$($pvOpen.Payload.d)','base64url')).update('chatq-confirm').digest();process.stdout.write(String(h.readUInt32BE(0)%1000000).padStart(6,'0'))"
    [string](& node -e $js)
}
else { '026316' }
Check 'the confirmation code of the pairing vector''s key: Node''s HMAC, six digits, shown as "123 456"' ($pvCode -ceq $pvWant -and
    (Get-ChatqPairCode $pvD -Spaced) -ceq ($pvWant.Substring(0, 3) + ' ' + $pvWant.Substring(3)) -and (Get-ChatqPairCode ([byte[]](1..32))) -cmatch '^\d{6}$') "$pvCode vs $pvWant"
$pvOther = Unprotect-ChatqPairMessage $pv.message $pvKey 'zzzzzzzzzz'
$pvJunk = Unprotect-ChatqPairMessage 'chatq2p.abcdefghij.AAAA' $pvKey $pv.pid
Check 'a pairing message for another pairing is not opened; a mangled one is refused' (-not $pvOther.Ok -and $pvOther.Error -like '*no pairing*' -and -not $pvJunk.Ok) "$($pvOther.Error) | $($pvJunk.Error)"

# --- settings ------------------------------------------------------------------
$r = Set-ChatqNotifyConfig @{ ApiKey = 'https://joinjoaomgcd.appspot.com/_ah/api/messaging/v1/sendPush?apikey=0123456789abcdef0123456789abcdef&deviceId=group.phone'; Ntfy = 'chatq-alert-topic-phone' }
Check 'Set-ChatqNotifyConfig takes a pasted Join URL apart' ((Unprotect-ChatqSecret (Get-ChatqConfig).join.apiKey) -eq '0123456789abcdef0123456789abcdef' -and
    (Get-ChatqConfig).join.device -eq 'group.phone' -and -not $r.Error) (($r.Messages | ForEach-Object Text) -join ' | ')
$sp0 = $script:PhSpawns
$env:CHATQ_WATCHER = $null
$said = (chatnotify -Reply on 6>&1 | Out-String -Width 400)
$env:CHATQ_WATCHER = '1'
$rc0 = Get-ChatqReplyConfig
$pj = & $phLastJoin
Check 'chatnotify -Reply on, no phone paired: the pairing push goes out, a topic and no key, neither printed' ($rc0.Wanted -and -not $rc0.Paired -and $rc0.PairUntil -and
    $rc0.Topic -cmatch '^chatq-[a-z2-7]{24}$' -and $said -notlike "*$($rc0.Topic)*" -and $said -like '*pairing alert sent*' -and $pj.Q['title'] -eq "chatq $([char]0xB7) pair" -and
    $pj.Q['dismissOnTouch'] -eq 'true' -and -not $pj.Q['notificationId']) $said
Check 'the pairing link: where to post, the pairing id and a 2048-bit public key - nothing that answers an alert' ($pj.F['v'] -eq '2' -and $pj.F['m'] -eq 'pair' -and
    $pj.F['t'] -eq $rc0.Topic -and $pj.F['s'] -eq 'https://ntfy.sh' -and $pj.F['a'] -eq $rc0.PairId -and (ConvertFrom-ChatqB64Url $pj.F['n']).Length -eq 256 -and
    $pj.F['x'] -eq 'AQAB' -and $pj.F['h'] -and -not $pj.F.ContainsKey('k') -and $pj.Url.Length -le 1900) $pj.Url
$cfgRaw = [System.IO.File]::ReadAllText($script:ChatqConfigPath, $utf8)
Check 'the pairing waits: the watcher listens (and a shell starts one), the topic and private key are not in config.json as they are' ((Test-ChatqReplyOpen) -and
    $script:PhSpawns -eq $sp0 + 1 -and (Get-ChatqPhoneStatusText) -like 'waiting for the phone - tap the pairing alert (until *' -and $cfgRaw -notlike "*$($rc0.Topic)*" -and
    $cfgRaw -notlike '*Modulus*') (Get-ChatqPhoneStatusText)
# answers that are refused: another pairing's id, and one sent 30 minutes ago
$phD1 = New-ChatqRandomBytes 32
$n0 = $script:PhJoins.Count
$null = & $phSay 'phpairfor' (New-PhPairMessage $pj.F $phD1 'stranger' -PairId 'zzzzzzzzzz')
$null = & $phSay 'phpairold' (New-PhPairMessage $pj.F $phD1 'late' -Ts ([DateTimeOffset]::UtcNow.AddMinutes(-30).ToUnixTimeMilliseconds()))
Check 'a pairing answer for another pairing, or 30 minutes old, pairs nothing, waits as nothing and says nothing' (-not (Get-ChatqReplyConfig).Paired -and
    $script:PhJoins.Count -eq $n0 -and -not @(Get-ChatqPairCandidates).Count -and
    (& $phLog) -like '*pairing phpairfor refused - for no pairing in progress*' -and (& $phLog) -like '*pairing phpairold refused - sent * s ago*') (& $phLog)
# the real one - with an alert registered before it, which the pairing,
# once confirmed, must kill
$null = Use-ChatqReplyState { param($st) $st.alerts['oldalertxx'] = @{ at = (Get-ChatqStamp); expires = (Get-Date).AddHours(1).ToUniversalTime().ToString('o'); event = 'done'; uses = 0 } }
$pmsg = New-PhPairMessage $pj.F $phD1 "Pixel 8$([char]0x202E) - Chrome`n"
$n0 = $script:PhJoins.Count
$null = & $phSay 'phpair1' $pmsg
$pc1 = @(Get-ChatqPairCandidates)
$code1 = Get-ChatqPairCode $phD1 -Spaced
Check 'the phone''s answer pairs nothing yet: it waits as a candidate with its code and its label cleaned, and no push goes out' (-not (Get-ChatqReplyConfig).Paired -and
    (Get-ChatqReplyConfig).PairId -and $pc1.Count -eq 1 -and $pc1[0].Label -eq 'Pixel 8 - Chrome' -and $pc1[0].Code -ceq $code1 -and $pc1[0].Digits -ceq ($code1 -replace ' ', '') -and
    $pc1[0].Id -cmatch '^[a-z2-7]{6}$' -and $pc1[0].At -and $script:PhJoins.Count -eq $n0 -and (& $phLog) -like "*pairing answer from Pixel 8 - Chrome, code $code1*" -and
    (Get-ChatqPhoneStatusText) -like 'waiting for the phone - tap the pairing alert (until *) - 1 answer to confirm by code') "$(($pc1 | ForEach-Object { "$($_.Label) $($_.Code)" }) -join ', ') / $(Get-ChatqPhoneStatusText)"
$stRaw = [System.IO.File]::ReadAllText($script:ChatqReplyPath, $utf8)
Check 'the candidate''s key is kept protected in replies.json, not as the phone sent it' ($stRaw -like '*pairCandidates*' -and $stRaw -notlike "*$(ConvertTo-ChatqB64Url $phD1)*") ''
# the same answer again, and someone else's: one more candidate, not two
$phDx = New-ChatqRandomBytes 32
$null = & $phSay 'phpair2' $pmsg
$null = & $phSay 'phpairx' (New-PhPairMessage $pj.F $phDx 'Android - Chrome 128')
$pc2 = @(Get-ChatqPairCandidates)
$status = (chatnotify 6>&1 | Out-String -Width 400)
Check 'the same answer posted again is still one candidate; another phone''s is a second; chatnotify lists both with their codes' ($pc2.Count -eq 2 -and
    $pc2[1].Label -eq 'Android - Chrome 128' -and $status -like "*Pixel 8 - Chrome answered at * - code $code1*chatnotify -Confirm $($code1 -replace ' ', '')*" -and
    $status -like '*Android - Chrome 128 answered*' -and $status -like '*2 answers to confirm by code*') $status
# confirming: a code nobody sent, a code that is no code, then the right one
$other = if (($code1 -replace ' ', '') -eq '000000') { '111111' } else { '000000' }
$cNone = Confirm-ChatqPairCandidate -Code $other
$cJunk = Confirm-ChatqPairCandidate -Code '12'
Check 'a code no answer has, or one that is not six digits, pairs nothing' ($cNone.Error -like '*no answer with the code*2 waiting*' -and $cJunk.Error -like '*six digits*' -and
    -not (Get-ChatqReplyConfig).Paired) "$($cNone.Error) | $($cJunk.Error)"
$n0 = $script:PhJoins.Count
$said = (chatnotify -Confirm $code1 6>&1 | Out-String -Width 400)
$rc = Get-ChatqReplyConfig
$st = Get-ChatqReplyState
$pdone = & $phLastJoin
Check 'chatnotify -Confirm with the phone''s code pairs that phone: its key, its label, the pairing gone' ($rc.Paired -and $rc.Key -ceq (ConvertTo-ChatqB64Url $phD1) -and
    $rc.Phone -eq 'Pixel 8 - Chrome' -and -not $rc.PairId -and -not (Get-ChatqConfig).reply.PSObject.Properties['pairing'] -and $rc.PairedAt -and
    $said -like '*paired - Pixel 8 - Chrome*') "$($rc.Phone) / $($rc.PairId) / $said"
Check 'confirming kills every alert and candidate from before, and says so with a push that can be answered (about no chat)' (-not $st.alerts.ContainsKey('oldalertxx') -and
    -not @($st.pairCandidates).Count -and $script:PhJoins.Count -eq $n0 + 1 -and $pdone.Q['text'] -eq 'paired - Pixel 8 - Chrome. Tap an alert to answer it.' -and
    $pdone.F['v'] -eq '2' -and $pdone.F['e'] -eq 'reply' -and $pdone.F['x'] -eq '1' -and $st.alerts.ContainsKey($pdone.F['a']) -and -not $st.lastId) "$($pdone.Url)"
$n0 = $script:PhJoins.Count
$null = & $phSay 'phpairlate' (New-PhPairMessage $pj.F $phDx 'Android - Chrome 128')
Check 'an answer after the pairing ended: no candidate, nothing said, the phone paired stays' ($script:PhJoins.Count -eq $n0 -and (Get-ChatqReplyConfig).Key -ceq $rc.Key -and
    -not @((Get-ChatqReplyState).pairCandidates).Count -and (Confirm-ChatqPairCandidate -Code $code1).Error -like '*no pairing is waiting*')
Check 'the status line names the phone' ((Get-ChatqPhoneStatusText) -like 'paired - Pixel 8 - Chrome - since *listening until *') (Get-ChatqPhoneStatusText)
$bad = (chatnotify -Events done, bogus 6>&1 | Out-String -Width 400)
Check 'an unknown event name saves nothing' (-not (Get-ChatqConfig).PSObject.Properties['phoneEvents'] -and $bad -like '*bogus*') $bad
$status = (chatnotify 6>&1 | Out-String -Width 400)
Check 'chatnotify alone shows the replies line' ($status -like '*replies from the phone: paired - Pixel 8*') $status

# config.json's lock (Lock-ChatqConfig). Another process - a pairing
# confirmed there - holds it and saves: chatnotify waits, then reads the
# file afresh, so what that process wrote stays. Held for good: nothing saved.
# The process says it has the lock in a file of its own: a look by opening
# the lock here could take it in the moment that process tries for it. It
# holds it a second: this side, slow, could reach the lock after a shorter
# hold and wait for nothing; and chatnotify's 3 s of tries outlast it by two
$lkMark = Join-Path $sb 'config-lock-held.txt'
Remove-Item -LiteralPath $lkMark -Force -EA SilentlyContinue
$cfgProbe = @"
`$h = [System.IO.File]::Open('$($script:ChatqConfigLockPath)', 'OpenOrCreate', 'ReadWrite', 'None')
if (`$h) { [System.IO.File]::WriteAllText('$lkMark', 'held') }
Start-Sleep -Milliseconds 1000
`$t = [System.IO.File]::ReadAllText('$($script:ChatqConfigPath)')
`$i = `$t.IndexOf('{')
[System.IO.File]::WriteAllText('$($script:ChatqConfigPath)', `$t.Substring(0, `$i + 1) + '"lockProbe":"kept",' + `$t.Substring(`$i + 1))
`$h.Dispose()
"@
$psiLk = New-Object System.Diagnostics.ProcessStartInfo((Get-Process -Id $PID).Path, "-NoProfile -NonInteractive -EncodedCommand $([Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cfgProbe)))")
$psiLk.UseShellExecute = $false
$psiLk.CreateNoWindow = $true
$prLk = [System.Diagnostics.Process]::Start($psiLk)
$heldLk = $false
$untilLk = (Get-Date).AddSeconds(20)
while (-not $heldLk -and -not $prLk.HasExited -and (Get-Date) -lt $untilLk) {
    if (Test-Path -LiteralPath $lkMark) { $heldLk = $true } else { Start-Sleep -Milliseconds 20 }
}
$rLk = Set-ChatqNotifyConfig @{ Toast = 'on' }
$null = $prLk.WaitForExit(10000)
$cfgLkNow = Get-ChatqConfig
Check 'config.json''s lock held by another process that saves meanwhile: chatnotify waits, and what that process wrote stays' ($heldLk -and -not $rLk.Error -and
    (Get-ChatField $cfgLkNow 'lockProbe') -eq 'kept' -and (Get-ChatField $cfgLkNow 'toast') -eq $true -and (Get-ChatqReplyConfig).Paired) "$heldLk $($rLk.Error) $(Get-ChatField $cfgLkNow 'lockProbe')"
$cfgLk = [System.IO.File]::Open($script:ChatqConfigLockPath, 'OpenOrCreate', 'ReadWrite', 'None')
$t0Lk = Get-Date
try { $rLk2 = Set-ChatqNotifyConfig @{ Toast = 'off' } }
finally { $cfgLk.Dispose() }
$waitedLk = ((Get-Date) - $t0Lk).TotalSeconds
Check 'held for good: chatnotify saves nothing after 3 s of tries and says config.json is busy' ($rLk2.Error -eq 'config.json is busy' -and $waitedLk -ge 2.5 -and
    (Get-ChatField (Get-ChatqConfig) 'toast') -eq $true -and @($rLk2.Messages | Where-Object { $_.Text -like 'config.json is busy*' }).Count -eq 1) "$($rLk2.Error) $waitedLk"
Lock-ChatqConfig
try {
    Set-ChatOverlayConfig @{ theme = (Get-ChatOverlayConfig).theme }
    $cfgN = Get-ChatqConfig
    $cfgN.PSObject.Properties.Remove('lockProbe')
    Save-ChatqConfig $cfgN
    $depthLk = $script:ChatqConfigLockDepth
}
finally { Unlock-ChatqConfig }
$freeLk = try { ([System.IO.File]::Open($script:ChatqConfigLockPath, 'OpenOrCreate', 'ReadWrite', 'None')).Dispose(); $true } catch { $false }
Check 'the lock taken again inside itself - by hand, around the overlay''s settings save; no code path nests it today - only counts, and lets go with the outer one' ($depthLk -eq 1 -and $freeLk -and
    $script:ChatqConfigLockDepth -eq 0 -and $null -eq (Get-ChatField (Get-ChatqConfig) 'lockProbe')) "$depthLk $freeLk $($script:ChatqConfigLockDepth)"

# replies off: the key stays, the window shuts, every alert out there is
# forgotten, and a push goes out as it did before replies; on again, polling
# starts over - nothing sent while off runs
$null = Use-ChatqReplyState { param($st) $st.lastId = 'oldcursor' }
$offAlerts = @((Get-ChatqReplyState).alerts.Keys).Count
chatnotify -Reply off *> $null
$rcOff = Get-ChatqReplyConfig
$stOff = Get-ChatqReplyState
$n0 = $script:PhJoins.Count
$okOff = Send-ChatqAlert 'done' 'no link' 1
$jOff = & $phLastJoin
Check '-Reply off: the phone stays paired, the window shuts, the alerts out there are forgotten, the push carries no link and registers nothing' (-not $rcOff.On -and
    $rcOff.Key -eq $rc.Key -and $offAlerts -ge 1 -and -not $stOff.openUntil -and -not $stOff.lastId -and $okOff -and $script:PhJoins.Count -eq $n0 + 1 -and
    -not $jOff.Q.ContainsKey('url') -and -not $jOff.Q.ContainsKey('dismissOnTouch') -and @($stOff.alerts.Keys).Count -eq 0 -and
    @((Get-ChatqReplyState).alerts.Keys).Count -eq 0 -and -not (Test-ChatqReplyOpen)) "$offAlerts alerts before / $($jOff.Url)"
$null = Use-ChatqReplyState { param($st) $st.lastId = 'offcursor' }
$n0 = $script:PhJoins.Count
chatnotify -Reply on *> $null
$rcOn = Get-ChatqReplyConfig
$stOn = Get-ChatqReplyState
Check '-Reply on again: the same phone, no new pairing, and polling from a minute back, not the old cursor' ($rcOn.On -and $rcOn.Key -eq $rc.Key -and
    $script:PhJoins.Count -eq $n0 -and -not $stOn.lastId -and [Math]::Abs([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 60 - $stOn.since) -lt 30) "$($stOn.lastId) $($stOn.since)"

# --- an alert with a link --------------------------------------------------------
$row = Get-ChatqRowById -Id $idCard -Provider claude
$job = (New-ChatqJob -Row $row -Prompt 'level the cards' -Kind prompt).Job
Complete-ChatqJob $job 'needs-input' ([pscustomobject]@{ kind = 'needs-input'; reason = 'asked to edit' }) 'asked'
$sp0 = $script:PhSpawns
$env:CHATQ_WATCHER = $null
$sent = Send-ChatqAlert 'needs input' "$($job.title) - asks" 2 -Job $job
$env:CHATQ_WATCHER = '1'
$j1 = & $phLastJoin
Check 'the Join push carries the link, the icon, a notificationId for the chat and dismissOnTouch' ($sent -and $j1.Q['url'] -like "$($script:ChatqReplyPage)#v=2&*" -and
    $j1.Q['icon'] -eq $script:ChatqJoinIcon -and $j1.Q['notificationId'] -eq ('chatq-' + $idCard.Substring(0, 12)) -and $j1.Q['dismissOnTouch'] -eq 'true') $j1.Url
$aid = $j1.F['a']
Check 'the link names the alert, the job and the chat - and no key, topic or server' ($aid -cmatch '^[a-z2-7]{10}$' -and $j1.F['e'] -eq 'needs input' -and
    $j1.F['n'] -eq "$($job.seq)" -and $j1.F['p'] -eq 'claude' -and $j1.F['j'] -eq 'needs-input' -and -not $j1.F.ContainsKey('x') -and
    (@($j1.F.Keys | Where-Object { $_ -notin 'f', 'o' } | Sort-Object) -join ',') -eq 'a,c,e,j,n,p,v' -and $j1.Q['url'] -notlike "*$($rc.Topic)*" -and
    $j1.F['c'] -eq $job.title.Substring(0, [Math]::Min(20, $job.title.Length))) (($j1.F.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ')
$st = Get-ChatqReplyState
Check 'the alert is registered with the chat''s config dir, a window opens, and a shell with no watcher starts one' ($st.alerts[$aid].jobId -eq $job.id -and
    $st.alerts[$aid].ContainsKey('home') -and $st.alerts[$aid].home -eq $job.home -and (Test-ChatqReplyOpen) -and $script:PhSpawns -eq $sp0 + 1 -and $st.since) "spawns $($script:PhSpawns - $sp0)"
$nb = $script:Ntfys[$script:Ntfys.Count - 1].Body | ConvertFrom-Json
Check 'Join and ntfy carry the one link' ($nb.click -eq $j1.Q['url']) "ntfy click: $($nb.click)"

# --- a prompt from the phone ----------------------------------------------------
$hangul = U 'yes, commit it \uD55C\uAE00'
$m1 = Protect-ChatqReplyMessage -Key $rc.Key -Aid $aid -Act prompt -Text $hangul
$script:PhFeed = & $phFeedOf @(, @('phm1', $m1))
$before = @(Get-ChatqJobs).Count
$h = Invoke-ChatqReplyPoll -Force
$jobs = @(Get-ChatqJobs)
$new = @($jobs | Where-Object { $_.rule -eq 'phone' })[0]
$old = Find-ChatqJob $job.id
Check 'a prompt from the phone queues a job for the alert''s chat, in the chat''s own mode; the poll returns an [int]' ($h -is [int] -and $h -eq 1 -and $jobs.Count -eq $before + 1 -and
    $new.sessionId -eq $idCard -and $new.state -eq 'queued' -and (Read-ChatqPrompt $new) -eq $hangul -and -not $new.mode -and $new.modeAtQueue -eq 'acceptEdits' -and
    -not $new.PSObject.Properties['noLinks']) "handled $h ($(if ($null -ne $h) { $h.GetType().Name })), jobs $($jobs.Count), new $($new.sessionId) '$(Read-ChatqPrompt $new)' mode '$($new.mode)' at queue '$($new.modeAtQueue)'"
Check 'the needs-input job it answered is skipped, naming the new one' ($old.state -eq 'skipped' -and $old.result.reason -eq "answered from the phone with #$($new.seq)") "$($old.state) $($old.result.reason)"
$j2 = & $phLastJoin
Check 'the answer is a reply push, with a fresh link about the new job' ($j2.Q['title'] -eq "chatq $([char]0xB7) reply" -and $j2.Q['text'] -eq "queued #$($new.seq) for $($new.title)" -and
    $j2.F['n'] -eq "$($new.seq)" -and $j2.F['a'] -ne $aid -and $j2.F['e'] -eq 'reply') $j2.Url
Check 'the poll asks the reply topic from the window''s start' ($script:PhPolls[$script:PhPolls.Count - 1] -like "https://ntfy.sh/$($rc.Topic)/json?poll=1&*" -and
    $script:PhPolls[$script:PhPolls.Count - 1] -match 'since=\d{10}$') $script:PhPolls[$script:PhPolls.Count - 1]
# a replay is never answered: the same message, however it comes back
$n0 = $script:PhJoins.Count
$null = Invoke-ChatqReplyPoll -Force
$pollAfter = $script:PhPolls[$script:PhPolls.Count - 1]
$script:PhFeed = & $phFeedOf @(, @('phm1again', $m1))
$null = Invoke-ChatqReplyPoll -Force
# and once more with this process's memory gone - a new watcher - where only
# the file knows the nonce
$script:ChatqReplySeen = @{}; $script:ChatqReplyHandled = @{}
$script:PhFeed = & $phFeedOf @(, @('phm1third', $m1))
$null = Invoke-ChatqReplyPoll -Force
Check 'the same message again - same id, a new id, a new watcher: nothing queued, nothing said' (@(Get-ChatqJobs).Count -eq $jobs.Count -and $script:PhJoins.Count -eq $n0 -and
    $pollAfter -like '*since=phm1' -and (Get-ChatqReplyState).lastId -eq 'phm1third') "$pollAfter / $((Get-ChatqReplyState).lastId)"
# an id that is not ntfy's shape is the server's word only: never logged or
# used as the cursor
$script:PhFeed = & $phFeedOf @(, @("x`n2026-09-26T10:00:00Z  phone: reply Q to done: allow", 'junk'))
$lg0 = (& $phLog).Length
$null = Invoke-ChatqReplyPoll -Force
Check 'a message id with a line break is skipped: not in the log, not the cursor' ((& $phLog).Substring($lg0) -notlike '*reply Q to done*' -and
    (Get-ChatqReplyState).lastId -eq 'phm1third') (& $phLog).Substring($lg0)
# the old job's own mode, when it had one - never one the message names
$jm = (New-ChatqJob -Row $row -Prompt 'plan it first' -Kind prompt).Job
Set-ChatqProp $jm 'mode' 'plan'
$am = & $phAsked $jm 'plan ready'
$sm = Protect-ChatqReplyMessage -Key $rc.Key -Aid $am -Payload ([ordered]@{ v = 1; act = 'prompt'; text = 'go'; mode = 'bypassPermissions'; nonce = 'ph-mode-nonce'; ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() } | ConvertTo-Json -Compress)
$txt = & $phSay 'phmode' $sm
$nm = @(Get-ChatqJobs | Where-Object { $_.rule -eq 'phone' -and $_.id -ne $new.id })[0]
Check 'a prompt to a job that had a mode of its own goes in that mode, whatever the message says' ($nm -and $nm.mode -eq 'plan' -and $txt -like "queued #$($nm.seq) *") "$($nm.mode) / $txt"

# --- the mode cap -----------------------------------------------------------------
$idBy = '2c2c2c2c-2c2c-42c2-82c2-2c2c2c2c2c2c'
$pBy = New-FakeChat $projA $idBy 'Bypass chat' 1 @('go wild') -Mode 'bypassPermissions'
$rowBy = Get-ChatqRowById -Id $idBy -Provider claude -Path $pBy
$jby = (New-ChatqJob -Row $rowBy -Prompt 'carry on' -Kind prompt).Job
# none by default: keep - the chat's own mode, as at the PC, a Codex
# chat's sandbox too
$txt = & $phSay 'phkeep1' (Protect-ChatqReplyMessage -Key $rc.Key -Aid (& $phAsked $jby 'asked') -Act prompt -Text 'keep going')
$nkp = @(Get-ChatqJobs | Where-Object { $_.rule -eq 'phone' -and $_.sessionId -eq $idBy })[0]
Check 'no cap by default (keep): a prompt into a bypassPermissions chat keeps its mode, a Codex chat its sandbox, and nothing says a limit' (
    (Get-ChatqReplyConfig).MaxMode -eq 'keep' -and $nkp -and $nkp.modeAtQueue -eq 'bypassPermissions' -and -not $nkp.mode -and $txt -notlike "*the phone's limit*" -and
    (Test-ChatqPhoneSandbox 'danger-full-access' 'keep') -and -not (Test-ChatqPhoneSandbox 'danger-full-access' 'auto') -and
    -not (Limit-ChatqPhoneMode 'bypassPermissions' 'keep').Capped) "$((Get-ChatqReplyConfig).MaxMode) / $($nkp.mode) $($nkp.modeAtQueue) / $txt"
# no cap given is keep too, and a hand-typed ' Keep' or 'Plan ' is read
# as written; a value not on the ladder is still acceptEdits
$kpCfg = { param($m) (Get-ChatqReplyConfig ([pscustomobject]@{ reply = [pscustomobject]@{ maxMode = $m } })).MaxMode }
Check 'an empty cap is keep; a hand-typed Keep or Plan is read as written, a mode not on the ladder acceptEdits' (
    -not (Limit-ChatqPhoneMode 'bypassPermissions' '').Capped -and (Test-ChatqPhoneSandbox 'danger-full-access' '') -and
    (& $kpCfg ' Keep') -ceq 'keep' -and (& $kpCfg 'Plan ') -ceq 'plan' -and (& $kpCfg 'yolo') -eq 'acceptEdits' -and (& $kpCfg '') -eq 'keep') "$(& $kpCfg ' Keep') $(& $kpCfg 'Plan ') $(& $kpCfg 'yolo')"
if ($nkp) { $null = Remove-ChatqJob $nkp }
# the rest of the phone's tests run under a cap, as one set
$null = Set-ChatqNotifyConfig @{ ReplyMaxMode = 'acceptEdits' }
# a job of its own: the reply above answered - skipped - the first one
$jby = (New-ChatqJob -Row $rowBy -Prompt 'carry on again' -Kind prompt).Job
$aby = & $phAsked $jby 'asked'
$txt = & $phSay 'phcap1' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $aby -Act prompt -Text 'rm everything')
$nby = @(Get-ChatqJobs | Where-Object { $_.rule -eq 'phone' -and $_.sessionId -eq $idBy })[0]
Check 'a prompt into a chat that runs in bypassPermissions runs in acceptEdits, and the push says so' ($nby -and $nby.modeAtQueue -eq 'bypassPermissions' -and
    $nby.mode -eq 'acceptEdits' -and $txt -like "queued #$($nby.seq) * - runs in acceptEdits, the phone's limit") "$($nby.mode) / $txt"
$jb = (New-ChatqJob -Row (Get-ChatqRowById -Id $idFw -Provider claude) -Prompt 'go on' -Kind prompt).Job
Set-ChatqProp $jb 'mode' 'bypassPermissions'
Complete-ChatqJob $jb 'failed' ([pscustomobject]@{ kind = 'failed'; reason = 'broke' }) 'broke'
$null = Send-ChatqAlert 'failed' 'x' 2 -Job $jb
$a4 = (& $phLastJoin).F['a']
$txt = & $phSay 'phretrycap' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $a4 -Act retry)
Check 'retry of a bypassPermissions job requeues it in acceptEdits' ((Find-ChatqJob $jb.id).state -eq 'queued' -and (Find-ChatqJob $jb.id).mode -eq 'acceptEdits' -and
    $txt -like "*the phone's limit") $txt
# a cap set higher is honoured, never passed
$null = Set-ChatqNotifyConfig @{ ReplyMaxMode = 'auto' }
$jb2 = Find-ChatqJob $jb.id
Set-ChatqProp $jb2 'mode' 'bypassPermissions'
# each stop its own alert: one about the job before would answer nothing
$a4 = & $phAsked $jb2 'again'
$txt = & $phSay 'phallowcap' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $a4 -Act allow)
$jb3 = Find-ChatqJob $jb.id
Check 'allow on a bypassPermissions job, the cap set to auto: requeued in auto' ($jb3.state -eq 'queued' -and $jb3.mode -eq 'auto' -and $txt -like '*in auto*') "$($jb3.state) $($jb3.mode) / $txt"
$bad = Set-ChatqNotifyConfig @{ ReplyMaxMode = 'yolo' }
$null = Set-ChatqNotifyConfig @{ ReplyMaxMode = 'acceptEdits' }
Check 'a mode cap that is no mode is refused' ($bad.Error -and (Get-ChatqReplyConfig).MaxMode -eq 'acceptEdits') $bad.Error
Set-ChatqProp $jb3 'mode' $null
Set-ChatqProp $jb3 'modeAtQueue' 'plan'
$a4 = & $phAsked $jb3 'wanted to edit'
$txt = & $phSay 'phallow1' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $a4 -Act allow)
$jb4 = Find-ChatqJob $jb.id
Check 'allow: a plan-mode job goes back in the queue in acceptEdits' ($jb4.state -eq 'queued' -and $jb4.mode -eq 'acceptEdits' -and $txt -like "#$($jb.seq) queued again in acceptEdits*") "$($jb4.state) $($jb4.mode) / $txt"
# the push that said so is about the job queued: allow from it meets the job's state
$a4 = (& $phLastJoin).F['a']
$txt = & $phSay 'phallow3' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $a4 -Act allow)
Check 'allow on a job that does not need input says so' ($txt -like '*allow is for a job that needs input*') $txt
$cxRow = Get-ChatqRowById -Id $cxId -Provider codex
$jc = (New-ChatqJob -Row $cxRow -Prompt 'codex, go on' -Kind prompt).Job
$ac = & $phAsked $jc 'asked'
$txt = & $phSay 'phallowcodex' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $ac -Act allow)
$jc2 = Find-ChatqJob $jc.id
Check 'allow on a Codex job is refused, the job untouched' ($txt -eq 'allow is Claude only - use retry' -and $jc2.state -eq 'needs-input' -and -not $jc2.mode) "$txt / $($jc2.state) $($jc2.mode)"
Set-ChatqProp $jc2 'sandbox' 'danger-full-access'
Save-ChatqJob $jc2
$txt = & $phSay 'phretrycodex' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $ac -Act retry)
$jc3 = Find-ChatqJob $jc.id
# capped as the job's own pick (mode); the chat's sandbox stays as it read
# on the job, and the answer says the run leaves the chat in the cap
Check 'retry of a Codex job with full access requeues it in workspace-write, and says the chat keeps it' ($jc3.state -eq 'queued' -and $jc3.mode -eq 'workspace-write' -and
    $jc3.sandbox -eq 'danger-full-access' -and $txt -like "#$($jc.seq) queued again (*) - runs in workspace-write, the phone's limit - and the chat keeps it for later jobs") "$($jc3.mode) $($jc3.sandbox) / $txt"
# a prompt into a Codex chat that last ran with full access - from the push
# about its requeue, the job as it is now. Its own pick cleared first: the
# cap's workspace-write above would go on as the old job's mode, and what is
# checked is the cap on the chat's own.
$ac = (& $phLastJoin).F['a']
Set-ChatqProp $jc3 'mode' $null
Save-ChatqJob $jc3
$phInfoFn = ${function:Get-ChatqJobInfo}
${function:Get-ChatqJobInfo} = { param($Row) $i = & $phInfoFn $Row; if ($Row.Provider -eq 'codex') { $i.Sandbox = 'danger-full-access'; $i.Mode = 'danger-full-access' }; $i }
try { $txt = & $phSay 'phcodexprompt' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $ac -Act prompt -Text 'codex from the phone') }
finally { ${function:Get-ChatqJobInfo} = $phInfoFn }
$ncx = @(Get-ChatqJobs | Where-Object { $_.rule -eq 'phone' -and $_.provider -eq 'codex' })[0]
Check 'a prompt into a Codex chat with full access runs in workspace-write as its own pick, the chat''s sandbox and network kept, and says the chat keeps it' ($ncx -and $ncx.mode -eq 'workspace-write' -and
    $ncx.sandbox -eq 'danger-full-access' -and $ncx.network -eq $true -and $txt -like "*runs in workspace-write, the phone's limit - and the chat keeps it for later jobs*") "$($ncx.mode) $($ncx.sandbox) $($ncx.network) / $txt"
# a job given full access itself (-Sandbox), in a workspace-write chat: the
# cap goes by the sandbox it runs in - its pick, not the chat's
$jcp = (New-ChatqJob -Row $cxRow -Prompt 'codex, full access' -Kind prompt -Mode 'danger-full-access').Job
Complete-ChatqJob $jcp 'failed' ([pscustomobject]@{ kind = 'failed'; reason = 'broke' }) 'broke'
$null = Send-ChatqAlert 'failed' 'x' 2 -Job $jcp
$txt = & $phSay 'phretrycodexpick' (Protect-ChatqReplyMessage -Key $rc.Key -Aid (& $phLastJoin).F['a'] -Act retry)
$jcp2 = Find-ChatqJob $jcp.id
Check 'retry under the cap of a Codex job given danger-full-access requeues it with mode workspace-write; the chat''s own, so nothing sticks' ($jcp2.state -eq 'queued' -and $jcp2.mode -eq 'workspace-write' -and
    $jcp2.sandbox -eq 'workspace-write' -and $txt -like "*runs in workspace-write, the phone's limit" -and $txt -notlike '*keeps it*') "$($jcp2.mode) $($jcp2.sandbox) / $txt"
$null = Remove-ChatqJob $jcp2 'test'

# --- the config dir, files, and the rest ------------------------------------------
# the chat's config dir travels with it, the default one ($null) included -
# whatever this process's CLAUDE_CONFIG_DIR says
$jh = (New-ChatqJob -Row $row -Prompt 'home one' -Kind prompt).Job
Set-ChatqProp $jh 'home' $null
$txt = & $phSay 'phhome1' (Protect-ChatqReplyMessage -Key $rc.Key -Aid (& $phAsked $jh 'asked') -Act prompt -Text 'home is default')
$nh = @(Get-ChatqJobs | Where-Object { $_.rule -eq 'phone' } | Where-Object { (Read-ChatqPrompt $_) -eq 'home is default' })[0]
$phElsewhere = Join-Path $sb 'claude-elsewhere'
$jg = (New-ChatqJob -Row $row -Prompt 'home two' -Kind prompt).Job
Set-ChatqProp $jg 'home' $phElsewhere
Complete-ChatqJob $jg 'done' ([pscustomobject]@{ kind = 'done' }) 'done'
$null = Send-ChatqAlert 'done' 'x' 1 -Job $jg
$ag = (& $phLastJoin).F['a']
$null = Remove-ChatqJob $jg 'test'
$txt2 = & $phSay 'phhome2' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $ag -Act prompt -Text 'home from the alert')
$ng = @(Get-ChatqJobs | Where-Object { $_.rule -eq 'phone' } | Where-Object { (Read-ChatqPrompt $_) -eq 'home from the alert' })[0]
Check 'a phone prompt keeps the chat''s config dir: the old job''s ($null too), else the alert''s' ($env:CLAUDE_CONFIG_DIR -and $nh -and $null -eq $nh.home -and
    $ng -and $ng.home -eq $phElsewhere) "'$($nh.home)' '$($ng.home)' / $txt / $txt2"
# a lane of its own no later check needs
if ($ng) { $null = Remove-ChatqJob $ng 'test' }
# a link in the text is text: nothing is pulled out of data/queue, now or
# when the watcher syncs again before it sends - but a link added at the PC
# later works as in any job
$phPasted = Join-Path $script:ChatqQueueDir 'phpasted.png'
[System.IO.File]::WriteAllBytes($phPasted, [byte[]](137, 80, 78, 71))
$null = Send-ChatqAlert 'done' 'x' 1 -Job $new
$txt = & $phSay 'phlinks' (Protect-ChatqReplyMessage -Key $rc.Key -Aid (& $phLastJoin).F['a'] -Act prompt -Text 'look at [this](phpasted.png) and ![that](phpasted.png) please')
$nl = @(Get-ChatqJobs | Where-Object { $_.rule -eq 'phone' } | Where-Object { (Read-ChatqPrompt $_) -like 'look at *' })[0]
$nlMissed = @(Sync-ChatqAttachments $nl)
Check 'a phone prompt with links in it: every "](" written "]\(", no file moved or attached, now or at the sync before sending' ($nl -and (Test-Path -LiteralPath $phPasted) -and
    -not @(Get-ChatqAttachments $nl).Count -and -not $nlMissed.Count -and (Read-ChatqPrompt $nl) -eq 'look at [this]\(phpasted.png) and ![that]\(phpasted.png) please') "$txt / $(Read-ChatqPrompt $nl)"
$nlPath = Get-ChatqPromptPath $nl
[System.IO.File]::WriteAllText($nlPath, [System.IO.File]::ReadAllText($nlPath, $utf8) + "`n![pasted at the PC](phpasted.png)", $utf8)
$null = Sync-ChatqAttachments $nl
Check 'an image linked later at the PC comes along with a phone job, as with any job' (-not (Test-Path -LiteralPath $phPasted) -and @(Get-ChatqAttachments $nl).Count -eq 1) (Read-ChatqPrompt $nl)
Remove-Item -LiteralPath $phPasted -Force -EA SilentlyContinue

$txt = & $phSay 'phskip' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $a4 -Act skip)
Check 'skip: a queued job is skipped from the phone' ((Find-ChatqJob $jb.id).state -eq 'skipped' -and (Find-ChatqJob $jb.id).result.reason -eq 'skipped from the phone' -and $txt -eq "#$($jb.seq) skipped") $txt
$a4 = (& $phLastJoin).F['a']
$txt = & $phSay 'phretry' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $a4 -Act retry)
Check 'retry on a skipped job says why not' ($txt -like '*is skipped - nothing to retry*' -and (Find-ChatqJob $jb.id).state -eq 'skipped') $txt
$txt = & $phSay 'phstop' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $a4 -Act stop)
Check 'stop on a job that is not running says so' ($txt -like '*nothing to stop*') $txt
# running with no watcher alive to read a cancel file: marked failed at once
Set-ChatqJobState (Find-ChatqJob $jc.id) 'running' 'test'
$ac = (New-ChatqReplyAlert -Event 'started' -Job (Find-ChatqJob $jc.id) -Rc $rc).Aid
$txt = & $phSay 'phstoprun' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $ac -Act stop)
Check 'stop on a running job whose watcher is gone: marked failed' ($txt -like "#$($jc.seq) marked failed*" -and (Find-ChatqJob $jc.id).state -eq 'failed') "$txt / $((Find-ChatqJob $jc.id).state)"
$stx = & $phSay 'phstatus' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $a4 -Act status)
Check 'status: the status line and the open jobs, 700 characters at most' ($stx -like '*queued*' -and $stx.Length -le 700 -and $stx -like "*#$($new.seq) *") $stx
$n0 = $script:PhJoins.Count
$script:PhFeed = & $phFeedOf @(, @('phunknown', (Protect-ChatqReplyMessage -Key $rc.Key -Aid $a4 -Act 'rm -rf')))
$null = Invoke-ChatqReplyPoll -Force
Check 'an unknown act is ignored, not answered' ($script:PhJoins.Count -eq $n0)
# the test alert, its ping, and a prompt it cannot take
chatnotify -Test *> $null
$jt = & $phLastJoin
Check 'chatnotify -Test carries a link (e=test) about no job, and replaces no notification' ($jt.F['e'] -eq 'test' -and $jt.F['n'] -eq '' -and $jt.F['x'] -eq '1' -and
    -not $jt.Q['notificationId']) $jt.Url
$txt = & $phSay 'phping' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $jt.F['a'] -Act ping)
Check 'ping comes back with the machine''s name' ($txt -like "reply reached $([Environment]::MachineName) after * s") $txt
$txt = & $phSay 'phnojob' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $jt.F['a'] -Act prompt -Text 'hi')
Check 'a prompt to an alert about no chat queues nothing' ($txt -eq 'that alert is not about a chat - nothing queued') $txt

# --- forged, tampered, junk --------------------------------------------------------
$st0 = Get-ChatqReplyState
$aid2 = $j2.F['a']
$mx = Protect-ChatqReplyMessage -Key (ConvertTo-ChatqB64Url (New-ChatqRandomBytes 32)) -Aid $aid2 -Act skip
$parts = (Protect-ChatqReplyMessage -Key $rc.Key -Aid $aid2 -Act skip).Split('.')
$parts[3] = $(if ($parts[3][0] -ceq 'A') { 'B' } else { 'A' }) + $parts[3].Substring(1)
$script:PhFeed = & $phFeedOf @(@('phwrongkey', $mx), @('phtamper', ($parts -join '.')), @('phjunk', 'hello there'))
$n0 = $script:PhJoins.Count; $c0 = @(Get-ChatqJobs).Count
$script:ChatqReplyJunkLog = @{}
$lg0 = (& $phLog).Length
$h = Invoke-ChatqReplyPoll -Force
$st1 = Get-ChatqReplyState
$log = (& $phLog).Substring($lg0)
Check 'a wrong key, a tampered body and junk: refused, nothing answered, queued, used up or counted; polling moves past them' ($h -eq 0 -and $h -is [int] -and
    $script:PhJoins.Count -eq $n0 -and @(Get-ChatqJobs).Count -eq $c0 -and [int]$st1.alerts[$aid2].uses -eq [int]$st0.alerts[$aid2].uses -and
    $st1.seen.Count -eq $st0.seen.Count -and $st1.lastId -eq 'phjunk') "handled $h, lastId $($st1.lastId)"
Check 'junk is logged once per stage every 5 minutes: the first MAC failure and the first format failure, not the second MAC failure' ($log -like '*phwrongkey refused - mac*' -and
    $log -notlike '*phtamper*' -and $log -like '*phjunk refused - format*') $log
$script:ChatqReplyJunkLog['mac'].At = (Get-Date).AddMinutes(-6)
$lg0 = (& $phLog).Length
$script:PhFeed = & $phFeedOf @(, @('phwrongkey2', $mx))
$null = Invoke-ChatqReplyPoll -Force
Check 'the next line logged at that stage says how many went unlogged' ((& $phLog).Substring($lg0) -like '*phwrongkey2 refused - mac*(and 1 more at this stage since *)*') (& $phLog).Substring($lg0)
# a flood of junk holds nothing back: a poll that may act on 2 messages
# still reaches the real one after 12 junk lines
$aT = $jt.F['a']
$flood = @(foreach ($i in 1..12) { , @("phflood$i", "junk number $i") }) + @(, @('phfloodping', (Protect-ChatqReplyMessage -Key $rc.Key -Aid $aT -Act ping)))
$script:PhFeed = & $phFeedOf $flood
$n0 = $script:PhJoins.Count
$h = Invoke-ChatqReplyPoll -Force -MaxMessages 2
Check 'twelve junk lines before a real reply: the reply is acted on in the same poll, and polling moves past all of it' ($h -eq 1 -and $script:PhJoins.Count -eq $n0 + 1 -and
    (& $phLastJoin).Q['text'] -like 'reply reached *' -and (Get-ChatqReplyState).lastId -eq 'phfloodping') "handled $h, lastId $((Get-ChatqReplyState).lastId)"
# a record that cannot be saved ends the poll there: the message after it
# does not move polling past it, and both come back
$fPing1 = Protect-ChatqReplyMessage -Key $rc.Key -Aid $aT -Act ping
$fPing2 = Protect-ChatqReplyMessage -Key $rc.Key -Aid $aT -Act status
$script:PhFeed = & $phFeedOf @(@('phfjunk', 'junk'), @('phfone', $fPing1), @('phftwo', $fPing2))
$phSaveFn = ${function:Save-ChatqReplyState}
$script:PhSaveFails = 1
${function:Save-ChatqReplyState} = { param($State, [double]$Hours = 12) if ($script:PhSaveFails -gt 0) { $script:PhSaveFails--; throw 'AV holds replies.json' }; & $phSaveFn $State $Hours }
$n0 = $script:PhJoins.Count
try { $h1 = Invoke-ChatqReplyPoll -Force }
finally { ${function:Save-ChatqReplyState} = $phSaveFn }
$lastF = (Get-ChatqReplyState).lastId
$h2 = Invoke-ChatqReplyPoll -Force
Check 'one save that fails: nothing after it is acted on or moves polling; the next poll takes both, in order' ($h1 -eq 0 -and $lastF -eq 'phfloodping' -and
    $h2 -eq 2 -and $script:PhJoins.Count -eq $n0 + 2 -and (Get-ChatqReplyState).lastId -eq 'phftwo' -and
    (& $phLog) -like '*phfone not acted on - the reply state could not be saved: AV holds replies.json*') "first $h1 (lastId $lastF), then $h2, lastId $((Get-ChatqReplyState).lastId)"

# --- refusals: expired, too old, used up - one push each, no link, no window ------
$st = Get-ChatqReplyState
$st.alerts[$aid2].expires = (Get-Date).ToUniversalTime().AddMinutes(-1).ToString('o')
# saved as a later write would find it: the prune in Save-ChatqReplyState
# would drop an expired entry, so the file is written directly
Save-ChatqJson $script:ChatqReplyPath ([ordered]@{ openUntil = $st.openUntil; since = $st.since; lastId = $st.lastId; alerts = $st.alerts; seen = $st.seen; refused = $st.refused })
$mexp = Protect-ChatqReplyMessage -Key $rc.Key -Aid $aid2 -Act status
$nA = @((Get-ChatqReplyState).alerts.Keys).Count
$ou = (Get-ChatqReplyState).openUntil
$n0 = $script:PhJoins.Count
$txt = & $phSay 'phexpired' $mexp
$je = & $phLastJoin
Check 'an expired alert, its MAC good: the phone is told once, with no link, no alert registered, no longer a window' ($script:PhJoins.Count -eq $n0 + 1 -and
    $txt -like '*expired*' -and -not $je.Q.ContainsKey('url') -and @((Get-ChatqReplyState).alerts.Keys).Count -le $nA -and (Get-ChatqReplyState).openUntil -eq $ou) $je.Url
$script:ChatqReplySeen = @{}; $script:ChatqReplyHandled = @{}
$n0 = $script:PhJoins.Count
$null = & $phSay 'phexpired2' $mexp
$null = & $phSay 'phexpired3' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $aid2 -Act status)
Check 'the same expired message replayed: silence; a new one to the same alert within 10 minutes: silence too' ($script:PhJoins.Count -eq $n0) "$($script:PhJoins.Count - $n0) pushes"
$aid3 = $jt.F['a']
$txt = & $phSay 'phold' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $aid3 -Act ping -Ts ([DateTimeOffset]::UtcNow.AddHours(-13).ToUnixTimeMilliseconds()))
Check 'a reply sent 13 h ago is refused as too old, and logged as how long ago' ($txt -like '*too old*' -and -not (& $phLastJoin).Q.ContainsKey('url') -and
    (& $phLog) -like '*phold refused - too old: sent 468* s ago*') $txt
$null = Use-ChatqReplyState { param($s) $s.alerts[$a4].uses = 20 }
$n0 = @(Get-ChatqJobs).Count
$txt = & $phSay 'phused' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $a4 -Act prompt -Text 'one more')
Check 'an alert answered 20 times takes no more' ($txt -like '*20 times*' -and @(Get-ChatqJobs).Count -eq $n0) $txt

# --- a chat or a job that went on at the PC since the alert ----------------------------
# a prompt typed at the PC, as Claude Code writes one; now, after the alert
$phTyped = {
    param([string]$Path, [string]$Id, [string]$Text, [string]$Mode = 'default', [datetime]$At = (Get-Date))
    Start-Sleep -Milliseconds 30
    $u = [ordered]@{ parentUuid = $null; isSidechain = $false; type = 'user'; message = [ordered]@{ role = 'user'; content = $Text }
        uuid = [guid]::NewGuid().ToString(); timestamp = $At.ToUniversalTime().ToString('o'); permissionMode = $Mode; cwd = $projA; sessionId = $Id }
    [System.IO.File]::AppendAllText($Path, ($u | ConvertTo-Json -Compress -Depth 6) + "`n", $utf8)
    Start-Sleep -Milliseconds 30
}
$idMv = '4a4a4a4a-4a4a-44a4-84a4-4a4a4a4a4a4a'
$pMv = New-FakeChat $projA $idMv 'Moved chat' 2 @('start it') -Mode 'default'
$rowMv = Get-ChatqRowById -Id $idMv -Provider claude -Path $pMv
$jMv = (New-ChatqJob -Row $rowMv -Prompt 'first run' -Kind prompt).Job
Set-ChatqProp $jMv 'mode' 'acceptEdits'
Complete-ChatqJob $jMv 'done' ([pscustomobject]@{ kind = 'done' }) 'finished'
$null = Send-ChatqAlert 'done' 'x' 1 -Job $jMv
$aMv = (& $phLastJoin).F['a']
$eMv = (Get-ChatqReplyState).alerts[$aMv]
Check 'an alert keeps its job as it showed it: how many runs, the state, when it ended' ($eMv.mark -eq "0|done|$(ConvertTo-ChatOverlayMs (ConvertTo-ChatqDate $jMv.endedAt))" -and
    -not $eMv.ContainsKey('seen')) "$($eMv.mark)"
$c0 = @(Get-ChatqJobs).Count
$txt = & $phSay 'phmv1' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $aMv -Act prompt -Text 'and then this')
Check 'nothing typed into its chat since: a prompt from the alert is queued' ($txt -like 'queued #*' -and @(Get-ChatqJobs).Count -eq $c0 + 1) $txt
& $phTyped $pMv $idMv 'carry on here' 'plan'
$c0 = @(Get-ChatqJobs).Count
$txt = & $phSay 'phmv2' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $aMv -Act prompt -Text 'written before that')
$jr = & $phLastJoin
Check 'a prompt typed at the PC since the alert: nothing queued, and the push says so - with a link about the chat as it is now' (
    $txt -eq "$($jMv.title) moved on at the PC since that alert - nothing queued; answer this push if it still stands" -and @(Get-ChatqJobs).Count -eq $c0 -and
    $jr.Q.ContainsKey('url') -and $jr.F['a'] -ne $aMv -and $jr.F['n'] -eq "$($jMv.seq)") $txt
$txt = & $phSay 'phmv3' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $jr.F['a'] -Act prompt -Text 'still meant')
$nMv = @(Get-ChatqJobs | Where-Object { (Read-ChatqPrompt $_) -eq 'still meant' })[0]
Check 'answered from that push, it goes - in plan, the mode the PC left the chat in, not the old job''s acceptEdits' ($nMv -and $nMv.mode -eq 'plan' -and
    $txt -eq "queued #$($nMv.seq) for $($nMv.title) - runs in plan, the chat's own at the PC") "$($nMv.mode) / $txt"
# the job queued again at the PC, then stopped again on something else
$jNi = (New-ChatqJob -Row $rowMv -Prompt 'needs a yes' -Kind prompt).Job
$aNi = & $phAsked $jNi 'asked to edit'
$null = Reset-ChatqJob (Find-ChatqJob $jNi.id -Exact)
$txt = & $phSay 'phmv4' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $aNi -Act allow)
$jNi2 = Find-ChatqJob $jNi.id -Exact
Check 'allow on an alert whose job was queued again at the PC since: nothing allowed, its mode as it was' ($txt -eq "#$($jNi.seq) is queued now, not as that alert saw it - nothing to allow" -and
    $jNi2.state -eq 'queued' -and -not $jNi2.mode) $txt
$txt = & $phSay 'phmv4s' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $aNi -Act skip)
Check 'nor is that requeue skipped from the old alert' ($txt -eq "#$($jNi.seq) is queued now, not as that alert saw it - nothing to skip" -and (Find-ChatqJob $jNi.id -Exact).state -eq 'queued') $txt
Set-ChatqProp $jNi2 'attempts' 1
Complete-ChatqJob $jNi2 'needs-input' ([pscustomobject]@{ kind = 'needs-input'; reason = 'asked again, for another thing' }) 'asked'
$c0 = @(Get-ChatqJobs).Count
$txt = & $phSay 'phmv5' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $aNi -Act allow)
$txtP = & $phSay 'phmv5p' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $aNi -Act prompt -Text 'yes, that')
Check 'run again and stopped on another thing: allow, or a prompt, from the alert about the first stop answers nothing' (
    $txt -eq "#$($jNi.seq) is needs-input now, not as that alert saw it - nothing to allow" -and
    $txtP -like "#$($jNi.seq) is needs-input now, not as that alert saw it - nothing queued*" -and
    (Find-ChatqJob $jNi.id -Exact).state -eq 'needs-input' -and -not (Find-ChatqJob $jNi.id -Exact).mode -and @(Get-ChatqJobs).Count -eq $c0) "$txt / $txtP"
# answered in its chat at the PC: closed, as the overlay would close it
$null = Send-ChatqAlert 'needs input' 'x' 2 -Job (Find-ChatqJob $jNi.id -Exact)
$aNi2 = (& $phLastJoin).F['a']
& $phTyped $pMv $idMv 'the answer, typed at the PC'
$txt = & $phSay 'phmv6' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $aNi2 -Act retry)
$jNi3 = Find-ChatqJob $jNi.id -Exact
Check 'retry on a job answered in its chat at the PC since: nothing sent, and the job is closed as answered there' (
    $txt -eq "#$($jNi.seq) was answered in the chat at the PC and is closed - nothing to retry" -and $jNi3.state -eq 'skipped' -and
    $jNi3.result.reason -eq 'answered in the chat') "$txt / $($jNi3.state) $($jNi3.result.reason)"
# a started alert: its own run writes the chat, and a stop is for that run only
$jSt = (New-ChatqJob -Row $rowMv -Prompt 'a long run' -Kind prompt).Job
Set-ChatqProp $jSt 'attempts' 1
Set-ChatqJobState $jSt 'running' 'attempt 1'
$raSt = New-ChatqReplyAlert -Event 'started' -Job (Find-ChatqJob $jSt.id -Exact) -Rc $rc
& $phTyped $pMv $idMv 'a long run'
$txt = & $phSay 'phmv7' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $raSt.Aid -Act prompt -Text 'after that, this')
Check 'a prompt from a started alert while its run goes on, the run''s own prompt landed since: queued' ($txt -like 'queued #*') $txt
Complete-ChatqJob (Find-ChatqJob $jSt.id -Exact) 'done' ([pscustomobject]@{ kind = 'done' }) 'finished'
$txt = & $phSay 'phmv8' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $raSt.Aid -Act prompt -Text 'and after it ended')
Check 'that run ended since, nothing typed after it: still queued' ($txt -like 'queued #*') $txt
$jSt2 = Find-ChatqJob $jSt.id -Exact
Set-ChatqProp $jSt2 'attempts' 2
Set-ChatqJobState $jSt2 'running' 'attempt 2'
$txt = & $phSay 'phmv9' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $raSt.Aid -Act stop)
$txtP = & $phSay 'phmv9p' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $raSt.Aid -Act prompt -Text 'one more')
Check 'run again since: a stop from the alert about the first run stops nothing, and a prompt from it queues nothing' (
    $txt -eq "#$($jSt.seq) is running now, not as that alert saw it - nothing to stop" -and $txtP -like "#$($jSt.seq) is running now, not as that alert saw it - nothing queued*" -and
    (Find-ChatqJob $jSt.id -Exact).state -eq 'running' -and -not (Test-Path -LiteralPath (Join-Path $script:ChatqQueueDir "$($jSt.id).cancel"))) "$txt / $txtP"
Complete-ChatqJob (Find-ChatqJob $jSt.id -Exact) 'failed' ([pscustomobject]@{ kind = 'failed'; reason = 'test' }) 'test'
# the watcher's own requeue is no one going on; a stop on a question is
$jAu = (New-ChatqJob -Row $rowMv -Prompt 'cut by the limit' -Kind prompt).Job
Set-ChatqProp $jAu 'attempts' 1
Set-ChatqJobState $jAu 'running' 'attempt 1'
$raAu = New-ChatqReplyAlert -Event 'started' -Job (Find-ChatqJob $jAu.id -Exact) -Rc $rc
& $phTyped $pMv $idMv 'cut by the limit'
Set-ChatqJobState (Find-ChatqJob $jAu.id -Exact) 'queued' 'limited mid-run, continues at 14:00'
$txt = & $phSay 'phmvau' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $raAu.Aid -Act prompt -Text 'after the reset, this')
Check 'put back in the queue by a limit, its end unchanged: a prompt from its started alert still goes' ($txt -like 'queued #*') $txt
$jQn = (New-ChatqJob -Row $rowMv -Prompt 'will ask' -Kind prompt).Job
Set-ChatqProp $jQn 'attempts' 1
Set-ChatqJobState $jQn 'running' 'attempt 1'
$raQn = New-ChatqReplyAlert -Event 'started' -Job (Find-ChatqJob $jQn.id -Exact) -Rc $rc
& $phTyped $pMv $idMv 'will ask'
Complete-ChatqJob (Find-ChatqJob $jQn.id -Exact) 'needs-input' ([pscustomobject]@{ kind = 'needs-input'; reason = 'asked' }) 'asked'
$c0 = @(Get-ChatqJobs).Count
$txt = & $phSay 'phmvqn' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $raQn.Aid -Act prompt -Text 'yes')
Check 'that run stopped on a question since: a prompt from its started alert answers nothing, the job left waiting' ($txt -like "#$($jQn.seq) is needs-input now, not as that alert saw it*" -and
    (Find-ChatqJob $jQn.id -Exact).state -eq 'needs-input' -and @(Get-ChatqJobs).Count -eq $c0) $txt
Complete-ChatqJob (Find-ChatqJob $jQn.id -Exact) 'skipped' ([pscustomobject]@{ kind = 'skipped'; reason = 'test' }) 'test'
# typed at the PC before the job's own run began: seen, the run's prompt not
$jPr = (New-ChatqJob -Row $rowMv -Prompt 'queued behind the PC' -Kind prompt).Job
$raPr = New-ChatqReplyAlert -Event 'reply' -Job $jPr -Rc $rc
& $phTyped $pMv $idMv 'typed before the job ran'
Set-ChatqProp $jPr 'attempts' 1
Set-ChatqJobState $jPr 'running' 'attempt 1'
& $phTyped $pMv $idMv 'queued behind the PC'
$txt = & $phSay 'phmvpr' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $raPr.Aid -Act prompt -Text 'from before all that')
Check 'a prompt typed at the PC before the job ran: seen while the job runs, not hidden by the run''s own' ($txt -like '* moved on at the PC since that alert - nothing queued*') $txt
Complete-ChatqJob (Find-ChatqJob $jPr.id -Exact) 'done' ([pscustomobject]@{ kind = 'done' }) 'test'
# a long turn after the prompt: hundreds of KB of tool results, past 64 of them
$null = Send-ChatqAlert 'done' 'x' 1 -Job (Find-ChatqJob $jPr.id -Exact)
$aLong = (& $phLastJoin).F['a']
& $phTyped $pMv $idMv 'a long job at the PC'
$lb = [System.Text.StringBuilder]::new()
foreach ($i in 1..80) {
    $tr = [ordered]@{ parentUuid = $null; isSidechain = $false; type = 'user'; message = [ordered]@{ role = 'user'; content = @([ordered]@{ type = 'tool_result'; tool_use_id = "t$i"; content = ('z' * 5000) }) }
        uuid = [guid]::NewGuid().ToString(); timestamp = (Get-Date).ToUniversalTime().ToString('o'); cwd = $projA; sessionId = $idMv }
    [void]$lb.AppendLine(($tr | ConvertTo-Json -Compress -Depth 8))
}
[System.IO.File]::AppendAllText($pMv, $lb.ToString(), $utf8)
$c0 = @(Get-ChatqJobs).Count
$txt = & $phSay 'phmvlong' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $aLong -Act prompt -Text 'about the old answer')
Check 'a prompt at the PC followed by 400 KB and 80 tool results: still seen, nothing queued' ($txt -like '* moved on at the PC since that alert - nothing queued*' -and @(Get-ChatqJobs).Count -eq $c0) $txt
# a job closed as answered in its chat: a prompt after it in the chat's own mode
$jAc = (New-ChatqJob -Row $rowMv -Prompt 'edit it' -Kind prompt).Job
Set-ChatqProp $jAc 'mode' 'acceptEdits'
$aAc = & $phAsked $jAc 'asked'
& $phTyped $pMv $idMv 'answered here, in plan' 'plan'
$txt = & $phSay 'phmvac' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $aAc -Act prompt -Text 'go on')
$aAc2 = (& $phLastJoin).F['a']
$txt2 = & $phSay 'phmvac2' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $aAc2 -Act prompt -Text 'go on, then')
$nAc = @(Get-ChatqJobs | Where-Object { (Read-ChatqPrompt $_) -eq 'go on, then' })[0]
Check 'answered in the chat and closed: the prompt from the push after goes in plan, the chat''s own, not the job''s acceptEdits' (
    $txt -like "#$($jAc.seq) was answered in the chat at the PC and is closed*" -and $nAc -and $nAc.mode -eq 'plan') "$txt / $txt2 / $($nAc.mode)"
Check 'a job''s end keeps its chat''s transcript length (endLen)' ((Find-ChatqJob $jAc.id -Exact).endLen -gt 0 -and
    (Find-ChatqJob $jAc.id -Exact).endLen -le (Get-Item -LiteralPath $pMv).Length) "$((Find-ChatqJob $jAc.id -Exact).endLen)"
# what else counts, or not, as the chat going on - each after a fresh alert on a chat of its own
$phLine = { param([string]$Path, $Rec) Start-Sleep -Milliseconds 30; [System.IO.File]::AppendAllText($Path, ($Rec | ConvertTo-Json -Compress -Depth 8) + "`n", $utf8); Start-Sleep -Milliseconds 30 }
$phFresh = {
    param([string]$Id, [string]$Title)
    $p = New-FakeChat $projA $Id $Title 2 @('begin') -Mode 'default'
    $j = (New-ChatqJob -Row (Get-ChatqRowById -Id $Id -Provider claude -Path $p) -Prompt 'the job' -Kind prompt).Job
    Complete-ChatqJob $j 'done' ([pscustomobject]@{ kind = 'done' }) 'finished'
    $null = Send-ChatqAlert 'done' 'x' 1 -Job $j
    [pscustomobject]@{ Path = $p; Job = $j; Aid = (& $phLastJoin).F['a'] }
}
$phNow = { (Get-Date).ToUniversalTime().ToString('o') }
$fq = & $phFresh '4c4c4c4c-4c4c-44c4-84c4-4c4c4c4c4c4c' 'Queued chat'
Check 'an alert keeps its chat''s transcript length (len)' ((Get-ChatqReplyState).alerts[$fq.Aid].len -eq (Get-Item -LiteralPath $fq.Path).Length) "$((Get-ChatqReplyState).alerts[$fq.Aid].len)"
& $phLine $fq.Path ([ordered]@{ parentUuid = $null; isSidechain = $false; attachment = [ordered]@{ type = 'queued_command'; prompt = 'typed while it worked'; commandMode = 'prompt'; origin = @{ kind = 'human' } }
    type = 'attachment'; uuid = [guid]::NewGuid().ToString(); timestamp = (& $phNow); sessionId = '4c4c4c4c-4c4c-44c4-84c4-4c4c4c4c4c4c' })
$txt = & $phSay 'phqc' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $fq.Aid -Act prompt -Text 'from the old view')
Check 'a prompt a person queued at the PC while Claude worked (a queued_command) is the chat going on' ($txt -like 'Queued chat moved on at the PC since that alert*') $txt
$ft = & $phFresh '4d4d4d4d-4d4d-44d4-84d4-4d4d4d4d4d4d' 'Notified chat'
& $phLine $ft.Path ([ordered]@{ parentUuid = $null; isSidechain = $false; promptId = 'x'; type = 'user'; message = [ordered]@{ role = 'user'; content = 'a background task finished' }
    uuid = [guid]::NewGuid().ToString(); timestamp = (& $phNow); origin = @{ kind = 'task-notification' }; promptSource = 'system'; sessionId = '4d4d4d4d-4d4d-44d4-84d4-4d4d4d4d4d4d' })
$txt = & $phSay 'phtn' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $ft.Aid -Act prompt -Text 'go on')
Check 'a background task''s notice is no one typing: the prompt goes' ($txt -like 'queued #*') $txt
$fImg = & $phFresh '4e4e4e4e-4e4e-44e4-84e4-4e4e4e4e4e4e' 'Image chat'
& $phLine $fImg.Path ([ordered]@{ parentUuid = $null; isSidechain = $false; type = 'user'
    message = [ordered]@{ role = 'user'; content = @([ordered]@{ type = 'image'; source = [ordered]@{ type = 'base64'; media_type = 'image/png'; data = ('A' * 400000) } }, [ordered]@{ type = 'text'; text = 'look at this' }) }
    uuid = [guid]::NewGuid().ToString(); timestamp = (& $phNow); sessionId = '4e4e4e4e-4e4e-44e4-84e4-4e4e4e4e4e4e' })
$txt = & $phSay 'phimg' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $fImg.Aid -Act prompt -Text 'about the old answer')
Check 'a prompt with a pasted image - one line of 400 KB - is seen' ($txt -like 'Image chat moved on at the PC since that alert*') $txt
$fc = & $phFresh '4f4f4f4f-4f4f-44f4-84f4-4f4f4f4f4f4f' 'Compacted chat'
& $phTyped $fc.Path '4f4f4f4f-4f4f-44f4-84f4-4f4f4f4f4f4f' 'typed, then compacted'
$phOld = (Get-Date).AddHours(-3).ToUniversalTime().ToString('o')
& $phLine $fc.Path ([ordered]@{ type = 'system'; subtype = 'compact_boundary'; uuid = [guid]::NewGuid().ToString(); timestamp = $phOld; sessionId = '4f4f4f4f-4f4f-44f4-84f4-4f4f4f4f4f4f' })
foreach ($k in 1..3) { & $phLine $fc.Path ([ordered]@{ parentUuid = $null; isSidechain = $false; type = 'user'; message = [ordered]@{ role = 'user'; content = "an old prompt, written again $k" }; uuid = [guid]::NewGuid().ToString(); timestamp = $phOld; sessionId = '4f4f4f4f-4f4f-44f4-84f4-4f4f4f4f4f4f' }) }
& $phLine $fc.Path ([ordered]@{ parentUuid = $null; isSidechain = $false; type = 'user'; message = [ordered]@{ role = 'user'; content = 'the summary' }; isCompactSummary = $true; uuid = [guid]::NewGuid().ToString(); timestamp = (& $phNow); sessionId = '4f4f4f4f-4f4f-44f4-84f4-4f4f4f4f4f4f' })
$txt = & $phSay 'phcompact' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $fc.Aid -Act prompt -Text 'about the old answer')
Check 'a compaction after the prompt, old records written again with their old times: the prompt is still seen' ($txt -like 'Compacted chat moved on at the PC since that alert*') $txt
# the phone's own job, once it ran, is not the chat going on
$fp = & $phFresh '5a5a5a5a-5a5a-45a5-85a5-5a5a5a5a5a5a' 'Phone chat'
$txt = & $phSay 'phown1' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $fp.Aid -Act prompt -Text 'first from the phone')
$own = @(Get-ChatqJobs | Where-Object { (Read-ChatqPrompt $_) -eq 'first from the phone' })[0]
Set-ChatqProp $own 'attempts' 1
Set-ChatqJobState $own 'running' 'attempt 1'
& $phTyped $fp.Path '5a5a5a5a-5a5a-45a5-85a5-5a5a5a5a5a5a' 'first from the phone'
Complete-ChatqJob (Find-ChatqJob $own.id -Exact) 'done' ([pscustomobject]@{ kind = 'done' }) 'finished'
$txt = & $phSay 'phown2' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $fp.Aid -Act prompt -Text 'and a second one')
Check 'the phone''s own first prompt ran since: a second from the same alert still goes' ($txt -like 'queued #*') $txt
# a person typing into the chat while the job's own run goes on
$fh = & $phFresh '5b5b5b5b-5b5b-45b5-85b5-5b5b5b5b5b5b' 'Busy chat'
$jh2 = (New-ChatqJob -Row (Get-ChatqRowById -Id '5b5b5b5b-5b5b-45b5-85b5-5b5b5b5b5b5b' -Provider claude -Path $fh.Path) -Prompt 'a run' -Kind prompt).Job
Set-ChatqProp $jh2 'attempts' 1
Set-ChatqJobState $jh2 'running' 'attempt 1'
$raH = New-ChatqReplyAlert -Event 'started' -Job (Find-ChatqJob $jh2.id -Exact) -Rc $rc
& $phLine $fh.Path ([ordered]@{ parentUuid = $null; isSidechain = $false; type = 'user'; message = [ordered]@{ role = 'user'; content = 'stop, do this instead' }
    uuid = [guid]::NewGuid().ToString(); timestamp = (& $phNow); origin = @{ kind = 'human' }; sessionId = '5b5b5b5b-5b5b-45b5-85b5-5b5b5b5b5b5b' })
$txt = & $phSay 'phhuman' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $raH.Aid -Act prompt -Text 'queue this after')
Check 'a person typing at the PC during the job''s own run is the chat going on, however the times fall' ($txt -like '* moved on at the PC since that alert*') $txt
Complete-ChatqJob (Find-ChatqJob $jh2.id -Exact) 'failed' ([pscustomobject]@{ kind = 'failed'; reason = 'test' }) 'test'
# the words older than the push - an alert the outbox held: judged from then
$idSn = '4b4b4b4b-4b4b-44b4-84b4-4b4b4b4b4b4b'
$pSn = New-FakeChat $projA $idSn 'Held chat' 2 @('begin') -Mode 'default'
$liveSn = ConvertTo-ChatqLiveJob @{ sessionId = $idSn; title = 'Held chat'; path = $pSn; cwd = $projA; home = $null }
& $phTyped $pSn $idSn 'typed while the alert waited' 'default' (Get-Date).AddMinutes(-5)
$null = Send-ChatqAlert 'done' 'x' 1 -Job $liveSn -SeenAt (Get-Date).AddMinutes(-10)
$aSn = (& $phLastJoin).F['a']
$c0 = @(Get-ChatqJobs).Count
$txt = & $phSay 'phseen' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $aSn -Act prompt -Text 'about what it said')
Check 'an alert whose words are older than its push (-SeenAt): a prompt typed between the two is the chat moving on' ((Get-ChatqReplyState).alerts[$aSn].seen -and
    $txt -like 'Held chat moved on at the PC since that alert - nothing queued*' -and @(Get-ChatqJobs).Count -eq $c0) $txt
# sealed long before it came: half an hour for anything that changes, ten minutes for a look
$null = Send-ChatqAlert 'done' 'x' 1 -Job $liveSn
$aLt = (& $phLastJoin).F['a']
$c0 = @(Get-ChatqJobs).Count
$txt = & $phSay 'phlate1' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $aLt -Act prompt -Text 'sent from the train' -Ts ([DateTimeOffset]::UtcNow.AddMinutes(-31).ToUnixTimeMilliseconds()))
Check 'a prompt sealed 31 minutes before it came: too old, nothing queued' ($txt -like '*too old*' -and @(Get-ChatqJobs).Count -eq $c0 -and
    (& $phLog) -like '*phlate1 refused - too old: sent 18* s ago*') $txt
$null = Send-ChatqAlert 'done' 'x' 1 -Job $liveSn
$aLt2 = (& $phLastJoin).F['a']
$txt = & $phSay 'phlate2' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $aLt2 -Act status -Ts ([DateTimeOffset]::UtcNow.AddMinutes(-11).ToUnixTimeMilliseconds()))
$txt2 = & $phSay 'phlate3' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $aLt2 -Act prompt -Text 'on the way' -Ts ([DateTimeOffset]::UtcNow.AddMinutes(-29).ToUnixTimeMilliseconds()))
Check 'a status 11 minutes old is too old; a prompt 29 minutes old still goes' ($txt -like '*too old*' -and $txt2 -like 'queued #*') "$txt / $txt2"
# a Codex chat goes on at the PC too: its rollout read as a Claude transcript
# is - a prompt typed in the Codex panel since, never Codex's own preamble,
# its environment block or a compaction's copies of old messages
$cxSid = '019a0000-0000-7000-8000-00000000c0de'
$cxMv = Join-Path $sb "codex-moved\rollout-2026-09-30T10-00-00-$cxSid.jsonl"
$null = New-Item -ItemType Directory -Path (Split-Path $cxMv) -Force
$cxRec = {
    param([string]$Type, $Payload, [datetime]$At = (Get-Date))
    Start-Sleep -Milliseconds 30
    ([ordered]@{ timestamp = $At.ToUniversalTime().ToString('o'); type = $Type; payload = $Payload } | ConvertTo-Json -Compress -Depth 8) + "`n"
}
$cxMsg = { param([string]$Role, [string]$Text) [ordered]@{ type = 'message'; role = $Role; content = @([ordered]@{ type = $(if ($Role -eq 'user') { 'input_text' } else { 'output_text' }); text = $Text }) } }
$cxOld = (Get-Date).AddMinutes(-20)
[System.IO.File]::WriteAllText($cxMv, (& $cxRec 'session_meta' ([ordered]@{ id = $cxSid; cwd = $projA }) $cxOld) +
    (& $cxRec 'response_item' (& $cxMsg 'user' '# AGENTS.md instructions for the project') $cxOld) +
    (& $cxRec 'response_item' (& $cxMsg 'user' 'fix the parser') $cxOld) +
    (& $cxRec 'response_item' (& $cxMsg 'assistant' 'done, the parser is fixed') $cxOld), $utf8)
$cxSince = Get-Date
$cxLen = (Get-Item -LiteralPath $cxMv).Length
Start-Sleep -Milliseconds 30
$cxQuiet = (& $cxRec 'turn_context' ([ordered]@{ cwd = $projA })) +
    (& $cxRec 'response_item' (& $cxMsg 'user' '<environment_context><cwd>x</cwd></environment_context>')) +
    (& $cxRec 'event_msg' ([ordered]@{ type = 'agent_message'; message = 'thinking it over' })) +
    (& $cxRec 'compacted' ([ordered]@{ message = 'summary'; replacement_history = @((& $cxMsg 'user' 'fix the parser')) })) +
    (& $cxRec 'response_item' (& $cxMsg 'user' ('<environment_context>' + ('x' * 300000) + '</environment_context>')))
[System.IO.File]::AppendAllText($cxMv, $cxQuiet, $utf8)
$mvCx0 = Get-ChatqMovedOn -Since $cxSince -SinceLen $cxLen -Path $cxMv -Provider codex -SessionId $cxSid
$mvCx0b = Get-ChatqMovedOn -Since $cxSince -Path $cxMv -Provider codex -SessionId $cxSid
[System.IO.File]::AppendAllText($cxMv, (& $cxRec 'response_item' (& $cxMsg 'user' 'now also the tests')), $utf8)
$mvCx1 = Get-ChatqMovedOn -Since $cxSince -SinceLen $cxLen -Path $cxMv -Provider codex -SessionId $cxSid
$mvCx1b = Get-ChatqMovedOn -Since $cxSince -Path $cxMv -Provider codex -SessionId $cxSid
Check 'a Codex chat: its own preamble, environment block and compaction are not the chat going on; a prompt typed in the panel since is - read from the length kept or back from the end' (
    -not $mvCx0.Why -and -not $mvCx0b.Why -and $mvCx1.Why -eq 'typed' -and $mvCx1b.Why -eq 'typed' -and $mvCx1.TypedAt -gt (ConvertTo-ChatOverlayMs $cxSince)) "$($mvCx0.Why) $($mvCx0b.Why) $($mvCx1.Why) $($mvCx1b.Why)"
$cxJob = [pscustomobject]@{ id = 'cx-test'; state = 'needs-input'; provider = 'codex'; sessionId = $cxSid; path = $cxMv; endedAt = $cxSince.ToString('o'); endLen = $cxLen; history = @() }
$mvCx2 = Get-ChatqMovedOn -Job $cxJob -Path $cxMv -Provider codex
$mvCx3 = Get-ChatqMovedOn -Job $cxJob -Path $cxMv -Provider codex -JobOnly
Check 'a Codex job waiting on input whose chat was typed into since is answered; -JobOnly still reads nothing' ($mvCx2.Why -eq 'answered' -and -not $mvCx3.Why) "$($mvCx2.Why) $($mvCx3.Why)"
# a line too long to keep - a pasted log - is judged by its text's start,
# from the first and last 8 KB the reader has of it
$cxLong = {
    param([string]$Text)
    $l = (& $cxRec 'response_item' (& $cxMsg 'user' $Text)).TrimEnd("`n")
    (Get-ChatqLineRecord ($l.Substring(0, 8192) + $l.Substring($l.Length - 8192)) -Long -Provider codex).Typed
}
$cxPad = 'y' * 300000
$cxL = @((& $cxLong "look at this log: $cxPad"), (& $cxLong "<environment_context>$cxPad"), (& $cxLong "# AGENTS.md instructions $cxPad"),
    (& $cxLong "# Context from my IDE setup:`n$cxPad"), (& $cxLong "# Context from my IDE setup:`n$cxPad`n## My request for Codex:`nexplain it"))
Check 'a Codex prompt too long to keep counts by how it starts: a pasted log is typed; the environment block, the preamble and the IDE''s wrapper with no request are not' (
    ($cxL -join ',') -eq 'True,False,False,False,True') ($cxL -join ',')
Remove-Item -LiteralPath (Split-Path $cxMv) -Recurse -Force
# these chats, written to just now, out of the way of the sections after:
# the phone's list shows the 30 newest
$mvChats = @{ $idMv = $pMv; $idSn = $pSn }
foreach ($f in @($fq, $ft, $fImg, $fc, $fp, $fh)) { $mvChats[[string]$f.Job.sessionId] = $f.Path }
foreach ($sidX in @($mvChats.Keys)) {
    foreach ($j in @(Get-ChatqJobs | Where-Object { $_.sessionId -eq $sidX })) { $null = Remove-ChatqJob $j 'test' }
    Remove-Item -LiteralPath $mvChats[$sidX] -Force -EA SilentlyContinue
}

# --- the lock, and nothing done that was not saved first ---------------------------
$null = Send-ChatqAlert 'done' 'x' 1 -Job $new
$al = (& $phLastJoin).F['a']
$lastBefore = (Get-ChatqReplyState).lastId
$mlk = Protect-ChatqReplyMessage -Key $rc.Key -Aid $al -Act prompt -Text 'only once please'
$script:PhFeed = & $phFeedOf @(, @('phlock1', $mlk))
$c0 = @(Get-ChatqJobs).Count
$lk = [System.IO.File]::Open($script:ChatqReplyLockPath, 'OpenOrCreate', 'ReadWrite', 'None')
try { $null = Invoke-ChatqReplyPoll -Force }
finally { $lk.Dispose() }
Check 'the reply state locked by another process: the reply is not acted on, and polling does not move past it' (@(Get-ChatqJobs).Count -eq $c0 -and
    (Get-ChatqReplyState).lastId -eq $lastBefore -and (& $phLog) -like '*phlock1 not acted on - the reply state could not be saved*') "$((Get-ChatqReplyState).lastId)"
$null = Invoke-ChatqReplyPoll -Force
$null = Invoke-ChatqReplyPoll -Force
Check 'the lock let go: the same message is acted on, once' (@(Get-ChatqJobs).Count -eq $c0 + 1 -and @(Get-ChatqJobs | Where-Object { (Read-ChatqPrompt $_) -eq 'only once please' }).Count -eq 1)
# a file that is there but cannot be read is never replaced by a fresh one
$phReplyWas = [System.IO.File]::ReadAllText($script:ChatqReplyPath, $utf8)
[System.IO.File]::WriteAllText($script:ChatqReplyPath, 'not json {', $utf8)
$ru = New-ChatqReplyAlert -Event 'done' -Job $new -Rc $rc
$script:PhFeed = & $phFeedOf @(, @('phunread', (Protect-ChatqReplyMessage -Key $rc.Key -Aid $al -Act prompt -Text 'unreadable state')))
$hu = Invoke-ChatqReplyPoll -Force
$still = [System.IO.File]::ReadAllText($script:ChatqReplyPath, $utf8)
Check 'replies.json unreadable: no link is made, no reply is acted on, and the file is left as it is' ($null -eq $ru -and $hu -eq 0 -and $still -eq 'not json {' -and
    -not @(Get-ChatqJobs | Where-Object { (Read-ChatqPrompt $_) -eq 'unreadable state' }).Count) $still
[System.IO.File]::WriteAllText($script:ChatqReplyPath, $phReplyWas, $utf8)

# --- sending: -Quick, -NoReply, http, a window that only grows ------------------------
$phHook = Join-Path $sb 'phone-hook.txt'
chatnotify -Command ("Set-Content -LiteralPath '$phHook' -Value x") *> $null
$null = Send-ChatqAlert 'done' 'quick one' 1 -Quick
$quickReport = @($script:ChatqAlertReport) -join ' | '
chatnotify -Command '' *> $null
Check '-Quick skips the command and still sends' (-not (Test-Path -LiteralPath $phHook) -and $quickReport -like '*join: sent*' -and $quickReport -notlike '*command*') $quickReport
$nA = @((Get-ChatqReplyState).alerts.Keys).Count
$null = Send-ChatqAlert 'reply' 'no link here' 1 -Loud -NoReply
Check '-NoReply: no link, nothing registered' (-not (& $phLastJoin).Q.ContainsKey('url') -and @((Get-ChatqReplyState).alerts.Keys).Count -eq $nA)
$null = Set-ChatqNotifyConfig @{ NtfyServer = 'http://ntfy.example' }
$null = Send-ChatqAlert 'done' 'over http' 1 -Job $new
$nbh = $script:Ntfys[$script:Ntfys.Count - 1].Body | ConvertFrom-Json
$null = Set-ChatqNotifyConfig @{ NtfyServer = 'https://ntfy.sh' }
Check 'an ntfy server that is not https gets no link; Join still does' (-not $nbh.PSObject.Properties['click'] -and (& $phLastJoin).Q['url']) ($nbh | ConvertTo-Json -Compress)
$u1 = (Get-ChatqReplyState).openUntil
$null = Set-ChatqNotifyConfig @{ ReplyHours = 1 }
$null = Send-ChatqAlert 'done' 'short hours' 1 -Job $new
$u2 = (Get-ChatqReplyState).openUntil
$null = Set-ChatqNotifyConfig @{ ReplyHours = 12 }
Check 'a smaller reply.hours never cuts the window short of an older link' ($u1 -and $u2 -eq $u1) "$u1 -> $u2"

# --- spent nonces are kept as long as their message could be taken ------------------
# reply.hours 24: a nonce 30 h old could still pass the timestamp check (a
# phone clock ahead stretches that window to twice its length), one 50 h
# old could not. A save that names no hours - chatnotify -Reply off and
# on - uses the configured ones.
$null = Set-ChatqNotifyConfig @{ ReplyHours = 24 }
$null = Use-ChatqReplyState { param($s) $s.seen['ph-n30'] = (Get-Date).AddHours(-30).ToUniversalTime().ToString('o'); $s.seen['ph-n50'] = (Get-Date).AddHours(-50).ToUniversalTime().ToString('o') }
Reset-ChatqReplyCursor
$seen24 = (Get-ChatqReplyState).seen
# with 12 hours, an alert out since 40 h ago (still unexpired) keeps what
# came after it; nothing older survives
$null = Set-ChatqNotifyConfig @{ ReplyHours = 12 }
$null = Use-ChatqReplyState {
    param($s)
    $s.seen['ph-n35'] = (Get-Date).AddHours(-35).ToUniversalTime().ToString('o')
    $s.alerts['phancient'] = @{ at = (Get-Date).AddHours(-40).ToUniversalTime().ToString('o'); expires = (Get-Date).AddHours(1).ToUniversalTime().ToString('o'); event = 'done'; uses = 0 }
}
$seen12 = (Get-ChatqReplyState).seen
$null = Use-ChatqReplyState { param($s) $s.alerts.Remove('phancient') }
$seen12b = (Get-ChatqReplyState).seen
Check 'spent nonces: kept for twice the timestamp window of the configured hours, and while an older alert is still out - whoever saves' ($seen24.ContainsKey('ph-n30') -and
    -not $seen24.ContainsKey('ph-n50') -and $seen12.ContainsKey('ph-n30') -and $seen12.ContainsKey('ph-n35') -and -not $seen12b.ContainsKey('ph-n30') -and
    -not $seen12b.ContainsKey('ph-n35')) "24: $(@($seen24.Keys) -join ',') / 12 with an old alert: $(@($seen12.Keys) -join ',') / without: $(@($seen12b.Keys) -join ',')"

# --- the reply page's address -------------------------------------------------------
$rpBad = Set-ChatqNotifyConfig @{ ReplyPage = 'http://me.example/reply.html' }
$rpBad2 = Set-ChatqNotifyConfig @{ ReplyPage = 'https://me.example/reply.html#x' }
$said = (chatnotify -ReplyPage 'https://replies.example.org/reply.html' 6>&1 | Out-String -Width 400)
$null = Send-ChatqAlert 'done' 'own page' 1 -Job $new
$jp = & $phLastJoin
Check '-ReplyPage: https only; the links point there, and a paired phone is told to pair again on the new site' ($rpBad.Error -and $rpBad2.Error -and
    (Get-ChatqReplyConfig).Page -eq 'https://replies.example.org/reply.html' -and $jp.Q['url'] -like 'https://replies.example.org/reply.html#v=2&*' -and
    $said -like '*pair it again there*') $said
$null = Set-ChatqNotifyConfig @{ ReplyPage = '' }
Check '-ReplyPage '''': the default page again' ((Get-ChatqReplyConfig).Page -eq $script:ChatqReplyPage -and -not (Get-ChatqConfig).reply.PSObject.Properties['page']) (Get-ChatqReplyConfig).Page

# --- the status report: 700 characters, never half an emoji --------------------------
$phJobsFn = ${function:Get-ChatqJobs}
$emo2 = [char]::ConvertFromUtf32(0x1F600)
$many = @(foreach ($i in 1..60) { [pscustomobject]@{ id = "phfake$i"; seq = 900 + $i; state = 'failed'; title = ("x$emo2" * 20); provider = 'claude' } })
${function:Get-ChatqJobs} = { $many }
try { $rep = Get-ChatqPhoneStatusReport }
finally { ${function:Get-ChatqJobs} = $phJobsFn }
Check 'the status report is cut to 700 characters with its status line, and never between the halves of an emoji' ($rep.Length -le 700 -and
    $rep -notmatch '[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]' -and $rep.StartsWith('chatq ')) "$($rep.Length)"

# --- surrogates ---------------------------------------------------------------------
$emo = [char]::ConvertFromUtf32(0x1F600)
$half = "a$emo b$emo" + [char]0xD83D
# 5.1 throws on the half, which becomes ?; pwsh 7 escapes it as U+FFFD itself
Check 'half an emoji becomes ?, the whole ones stay' ((ConvertTo-ChatqUriPart $half) -in @(([Uri]::EscapeDataString("a$emo b$emo") + '%3F'), ([Uri]::EscapeDataString("a$emo b$emo") + '%EF%BF%BD'))) (ConvertTo-ChatqUriPart $half)
$ue = Get-ChatqJoinUrl 'k' 'group.phone' 't' ("x$emo" * 700) 1
$ueText = [uri]::UnescapeDataString(($ue.Substring($ue.IndexOf('text=') + 5) -split '&')[0])
Check 'a Join text cut to fit never cuts an emoji in two' ($ue.Length -le 1900 -and -not $ueText.Contains('?') -and $ueText.Contains($emo)) $ueText.Length

# --- pairing again: the old phone is dead at once ----------------------------------
$mOld = Protect-ChatqReplyMessage -Key $rc.Key -Aid $jt.F['a'] -Act ping
# no channel that can carry the link - ntfy over http alone: refused, and
# nothing changes, the phone paired before included
$phCfgMid = [System.IO.File]::ReadAllText($script:ChatqConfigPath, $utf8)
$null = Set-ChatqNotifyConfig @{ RemoveJoin = $true; NtfyServer = 'http://ntfy.example' }
$replyBefore = (Get-ChatqConfig).reply | ConvertTo-Json -Compress -Depth 5
$n0 = $script:PhJoins.Count; $nt0 = $script:Ntfys.Count
$prHttp = Start-ChatqReplyPairing
Check 'pairing with only ntfy over http: refused before anything changes - no push, the paired phone kept' ($prHttp.Error -like '*can carry the pairing link*' -and -not $prHttp.Sent -and
    ((Get-ChatqConfig).reply | ConvertTo-Json -Compress -Depth 5) -eq $replyBefore -and $script:PhJoins.Count -eq $n0 -and $script:Ntfys.Count -eq $nt0 -and
    (Get-ChatqReplyConfig).Paired) $prHttp.Error
# your command given the link (chatnotify -CommandLinks on): a phone channel
# then - CHATQ_LINK carries an alert's reply link, and the pairing's; at the
# PC it still runs, with no link, as the phones stay quiet
$cmdOut = Join-Path $sb 'cmdlinks.txt'
Remove-Item -LiteralPath $cmdOut -Force -EA SilentlyContinue
$cmdSet = Set-ChatqNotifyConfig @{ Command = "Add-Content -LiteralPath '$cmdOut' -Encoding UTF8 -Value (`$env:CHATQ_EVENT + '|' + `$env:CHATQ_LINK)"; CommandLinks = 'on' }
$cmdOff = Set-ChatqNotifyConfig @{ CommandLinks = 'maybe' }
Check 'chatnotify -CommandLinks on is saved, says where the command runs now, and takes only on or off' (-not $cmdSet.Error -and (Test-ChatqCommandLinks) -and
    (Test-ChatqLinkChannel) -and (Test-ChatqPhoneChannel) -and @($cmdSet.Messages | Where-Object { $_.Text -like '*CHATQ_LINK*' }).Count -eq 1 -and
    $cmdOff.Error -eq 'bad command links value') "$($cmdSet.Error) $($cmdOff.Error)"
$idleCmd = $script:ChatqIdleSeam
$script:ChatqIdleSeam = 30
$okAtCmd = Send-ChatqAlert 'done' 'at the desk' 1
$script:ChatqIdleSeam = 99999
$okAwayCmd = Send-ChatqAlert 'test' 'command links' 1 -Loud
$script:ChatqIdleSeam = $idleCmd
$cmdLines = @(if (Test-Path -LiteralPath $cmdOut) { [System.IO.File]::ReadAllLines($cmdOut, $utf8) })
Check 'with links on, an alert away gives the command the reply link; one at the PC runs it all the same, with none' (-not $okAtCmd -and $okAwayCmd -and
    $cmdLines.Count -eq 2 -and $cmdLines[0] -eq 'done|' -and $cmdLines[1] -like "test|$((Get-ChatqReplyConfig).Page)#*") ($cmdLines -join ' / ')
$prCmd = Start-ChatqReplyPairing
$cmdLines = @(if (Test-Path -LiteralPath $cmdOut) { [System.IO.File]::ReadAllLines($cmdOut, $utf8) })
Check 'with neither Join nor ntfy over https, the pairing goes through the command, its link in CHATQ_LINK' ($prCmd.Sent -and -not $prCmd.Error -and
    $cmdLines.Count -eq 3 -and $cmdLines[2] -like 'pair|*#*m=pair*') "$($prCmd.Error) / $($cmdLines -join ' / ')"
# the setup window's box for it: ticked from config.json; unticked, Save
# has CommandLinks off to write
if ($script:ChatqIsWindows) {
    $cmdTool = (Join-Path $sb 'tool\Charlie-and-the-chat-factory.ps1').Replace("'", "''")
    $cmdWin = Invoke-Sta 'cmdlinks-window' @"
`$ErrorActionPreference = 'Stop'
`$env:CHATQ_OVERLAY = '1'; `$env:CHATQ_WATCHER = '1'
. '$cmdTool' *> `$null
try {
    `$w = New-ChatqPhoneSetupWindow -Theme light
    `$U = `$w.Tag
    `$a = [bool]`$U.CommandLinksBox.IsChecked
    `$U.CommandLinksBox.IsChecked = `$false
    Update-ChatqPhoneSetupDirty `$U
    `$c = Get-ChatqPhoneSetupChanges `$U
    "ok|`$a|`$(`$c.Changes['CommandLinks'])|`$(Test-ChatqPhoneSetupDirty `$U)"
}
catch { "error|`$(`$_.Exception.Message)" }
"@
    Check 'the setup window: "Give it the reply link too" ticked from config.json; unticked, Save has CommandLinks off to write' ($cmdWin -eq 'ok|True|off|True') $cmdWin
}
[System.IO.File]::WriteAllText($script:ChatqConfigPath, $phCfgMid, $utf8)
# replies.json unreadable - NULs after a power cut: pairing puts it aside
# and writes a fresh one, where anything else leaves it be
$phBad = "$($script:ChatqReplyPath).bad"
Remove-Item -LiteralPath $phBad -Force -EA SilentlyContinue
[System.IO.File]::WriteAllBytes($script:ChatqReplyPath, (New-Object byte[] 64))
$said = (chatnotify -Pair 6>&1 | Out-String -Width 400)
$rc2 = Get-ChatqReplyConfig
$pj2 = & $phLastJoin
$st2 = Get-ChatqReplyState
Check '-Pair over an unreadable replies.json: that one put aside as replies.json.bad, a fresh one written, the pairing push out' ((Test-Path -LiteralPath $phBad) -and
    $st2.openUntil -and -not $st2.lastId -and $rc2.PairUntil -and $pj2.F['m'] -eq 'pair' -and $said -like '*pairing alert sent*' -and $said -like '*chatnotify -Confirm*' -and
    (Test-ChatqReplyOpen)) $said
Remove-Item -LiteralPath $phBad -Force -EA SilentlyContinue
$n0 = $script:PhJoins.Count
$null = & $phSay 'phrenewed1' $mOld
Check '-Pair: a new topic, the old key gone at once - an old phone''s reply meets silence' (-not $rc2.Paired -and $rc2.PairUntil -and $rc2.Topic -ne $rc.Topic -and
    $script:PhJoins.Count -eq $n0 -and $script:PhPolls[$script:PhPolls.Count - 1] -like "*/$($rc2.Topic)/json*" -and -not @((Get-ChatqReplyState).alerts.Keys).Count) $script:PhPolls[$script:PhPolls.Count - 1]
# six answers to one pairing: five wait, the oldest goes
$six = @(foreach ($i in 1..6) { , @("phsix$i", (New-PhPairMessage $pj2.F (New-ChatqRandomBytes 32) "phone $i")) })
$script:PhFeed = & $phFeedOf $six
$h6 = Invoke-ChatqReplyPoll -Force
$pc6 = @(Get-ChatqPairCandidates)
Check 'six answers to one pairing: five wait as candidates, the oldest dropped' ($h6 -eq 6 -and $pc6.Count -eq 5 -and $pc6[0].Label -eq 'phone 2' -and $pc6[4].Label -eq 'phone 6') (($pc6 | ForEach-Object Label) -join ', ')
# a pairing started elsewhere between the confirm's first read and its
# lock (Lock-ChatqConfig): config.json read again under the lock names
# another pairing, so the code confirms nothing - no key saved, and the
# candidates stay as they were
$phGcOrig = ${function:Get-ChatqConfig}
$script:PhSwapPair = 'replacedpp'
${function:Get-ChatqConfig} = {
    $c = & $phGcOrig
    if ($script:PhSwapPair -and $script:ChatqConfigLockDepth -gt 0 -and $c.reply -and $c.reply.pairing) {
        $c.reply.pairing.id = $script:PhSwapPair
        $script:PhSwapPair = $null
        Save-ChatqJson $script:ChatqConfigPath $c
    }
    $c
}
try { $cGone = Confirm-ChatqPairCandidate -Code $pc6[4].Digits }
finally { ${function:Get-ChatqConfig} = $phGcOrig }
$cfgGone = Get-ChatqConfig
$pcGone = @((Get-ChatqReplyState).pairCandidates)
Check 'a pairing replaced between the confirm''s read and its lock: refused, no key saved, the candidates left as they were' ($cGone.Error -like 'that pairing was replaced meanwhile*' -and
    -not $cfgGone.reply.PSObject.Properties['key'] -and $cfgGone.reply.pairing.id -ceq 'replacedpp' -and $pcGone.Count -eq 5 -and
    ((@($pcGone | ForEach-Object { [string]$_.id }) | Sort-Object) -join ',') -ceq ((@($pc6 | ForEach-Object { [string]$_.Id }) | Sort-Object) -join ','))"$($cGone.Error) / $($cfgGone.reply.pairing.id) $($pcGone.Count)"
$cfgGone.reply.pairing.id = $rc2.PairId
Save-ChatqJson $script:ChatqConfigPath $cfgGone
# a pairing that ran out takes no answer, and no confirmation
$c = Get-ChatqConfig
$c.reply.pairing.expires = (Get-Date).AddMinutes(-1).ToUniversalTime().ToString('o')
Save-ChatqJson $script:ChatqConfigPath $c
$rcx = Get-ChatqReplyConfig
$phD2 = New-ChatqRandomBytes 32
$null = Receive-ChatqReply $rcx 'phpairexp' (New-PhPairMessage $pj2.F $phD2 'too late')
Check 'a pairing past its 15 minutes: no answer taken or confirmed, nothing to listen for, and the status says not paired' (-not (Get-ChatqReplyConfig).Paired -and
    -not (Test-ChatqReplyOpen) -and -not @(Get-ChatqPairCandidates).Count -and (Confirm-ChatqPairCandidate -Code $pc6[4].Digits).Error -like '*no pairing is waiting*' -and
    (Get-ChatqPhoneStatusText) -eq 'not paired') (Get-ChatqPhoneStatusText)
# a Save landing while a pairing starts, after its first read of
# config.json: read again under the lock, so what that Save wrote stays
# beside the new pairing
$cfgBeforeKeep = Get-ChatqConfig
$script:PhSwapPair = 'kept'
${function:Get-ChatqConfig} = {
    # the first read gets the file as it was, and the Save lands right after
    $c = & $phGcOrig
    if ($script:PhSwapPair) {
        $c0 = & $phGcOrig
        Set-ChatqProp $c0 'pairProbe' $script:PhSwapPair
        Save-ChatqJson $script:ChatqConfigPath $c0
        $script:PhSwapPair = $null
    }
    $c
}
try { $prKeep = Start-ChatqReplyPairing }
finally { ${function:Get-ChatqConfig} = $phGcOrig }
$cfgKeep = Get-ChatqConfig
Check 'a Save landing after a pairing''s first read of config.json stays: the pairing reads the file again under the lock' ($prKeep.Sent -and
    (Get-ChatField $cfgKeep 'pairProbe') -eq 'kept' -and $cfgKeep.reply.pairing.id -and $null -eq (Get-ChatField $cfgBeforeKeep 'pairProbe')) "$($prKeep.Error) $(Get-ChatField $cfgKeep 'pairProbe')"
$cfgKeep.PSObject.Properties.Remove('pairProbe')
Save-ChatqJson $script:ChatqConfigPath $cfgKeep
# the pairing push that does not go out - Join answers 500, ntfy over http
# cannot carry the link: an error, and no pairing left waiting for a tap
$null = Set-ChatqNotifyConfig @{ NtfyServer = 'http://ntfy.example' }
$script:ChatqJoinSeam = { param($u) $script:PhJoins.Add($u); 'HTTP 500' }
$nt0 = $script:Ntfys.Count
try { $prFail = Start-ChatqReplyPairing }
finally { $script:ChatqJoinSeam = { param($u) $script:PhJoins.Add($u); $null } }
$null = Set-ChatqNotifyConfig @{ NtfyServer = 'https://ntfy.sh' }
Check 'a pairing push that did not go out: its error, not "sent", and no pairing waits for it - the status says not paired' ($prFail.Error -like '*join: HTTP 500*' -and
    -not $prFail.Sent -and -not (Get-ChatqConfig).reply.PSObject.Properties['pairing'] -and -not (Test-ChatqReplyOpen) -and $script:Ntfys.Count -eq $nt0 -and
    (Get-ChatqPhoneStatusText) -eq 'not paired' -and @($script:ChatqAlertReport) -like '*ntfy: skipped - not https*') "$($prFail.Error) / $(Get-ChatqPhoneStatusText)"
# -Reply renew, in a shell that can ask: it waits for the answers and asks
# about each - a stranger's first (no), then the phone's (yes)
$script:PhAsks = [System.Collections.Generic.List[string]]::new()
$script:PhTicks = 0
$phDs = New-ChatqRandomBytes 32
$script:ChatqAskSeam = { param($q) $script:PhAsks.Add($q); if ($script:PhAsks.Count -eq 1) { 'n' } else { 'y' } }
$script:ChatqPairWaitSeam = {
    $script:PhTicks++
    if ($script:PhTicks -eq 1) { $script:PhPairF = (& $phLastJoin).F }
    $m = switch ($script:PhTicks) {
        1 { New-PhPairMessage $script:PhPairF $phDs 'Stranger' }
        2 { New-PhPairMessage $script:PhPairF $phD2 'Second phone' }
        default { $null }
    }
    if ($m) { $script:PhFeed = & $phFeedOf @(, @("phwait$($script:PhTicks)", $m)); $null = Invoke-ChatqReplyPoll -Force }
    # a wait that goes on: the pairing is ended so the loop does too
    if ($script:PhTicks -gt 5) { $cc = Get-ChatqConfig; $cc.reply.PSObject.Properties.Remove('pairing'); Save-ChatqJson $script:ChatqConfigPath $cc }
}
try { $said = (chatnotify -Reply renew 6>&1 | Out-String -Width 400) }
finally { $script:ChatqAskSeam = $false; $script:ChatqPairWaitSeam = $null }
$rc3 = Get-ChatqReplyConfig
$n0 = $script:PhJoins.Count
$null = & $phSay 'phrenewed2' $mOld
Check '-Reply renew waits and asks: the stranger''s code turned down, the phone''s taken - the old phone''s reply still meets silence' ($rc3.Paired -and
    $rc3.Phone -eq 'Second phone' -and $rc3.Key -ceq (ConvertTo-ChatqB64Url $phD2) -and $script:PhAsks.Count -eq 2 -and $script:PhTicks -eq 2 -and
    $said -like "*Stranger answered - code $(Get-ChatqPairCode $phDs -Spaced)*" -and $said -like "*Second phone answered - code $(Get-ChatqPairCode $phD2 -Spaced)*" -and
    $said -like '*paired - Second phone*' -and $script:PhJoins.Count -eq $n0) $said
$rc = $rc3

# --- which events reach the phone, and the Join URL's length ---------------------
chatnotify -Events done, 'needs-input' *> $null
Check '-Events saves the names, needs-input as needs input' ((@((Get-ChatqConfig).phoneEvents) -join ',') -eq 'done,needs input') (@((Get-ChatqConfig).phoneEvents) -join ',')
$n0 = $script:PhJoins.Count; $t0 = $script:Toasts.Count
$s1 = Send-ChatqAlert 'started' 'x' 0 -Job $new
$s2 = Send-ChatqAlert 'reply' 'y' 1 -Job $new
$s3 = Send-ChatqAlert 'done' 'z' 1 -Job $new
Check 'an event held back skips the phone but not the toast; reply and the named ones go' (-not $s1 -and $s2 -and $s3 -and $script:PhJoins.Count -eq $n0 + 2 -and
    $script:Toasts.Count -ge $t0 + 3) "$s1 $s2 $s3 joins $($script:PhJoins.Count - $n0) toasts $($script:Toasts.Count - $t0)"
chatnotify -Events all *> $null
Check '-Events all clears the filter' (-not (Get-ChatqConfig).PSObject.Properties['phoneEvents'])
$long = [pscustomobject]@{ id = 'x'; seq = 999; sessionId = $idCard; provider = 'claude'; state = 'done'; title = (U '\uD55C\uAE00') * 40 }
$ru = New-ChatqReplyAlert -Event 'done' -Job $long -Rc $rc
$ju = Get-ChatqJoinUrl '0123456789abcdef0123456789abcdef' 'group.phone' "chatq $([char]0xB7) done" ((U '\uD55C\uAE00 ') * 400) 1 -Url $ru.Link -NotificationId 'chatq-123456789012' -Icon $script:ChatqJoinIcon -DismissOnTouch
Check 'a Join URL with a Hangul title, Hangul text and the link stays within 1900' ($ju.Length -le 1900 -and $ju -like '*url=*' -and $ju -like '*icon=*') $ju.Length
$ju2 = Get-ChatqJoinUrl ('k' * 1500) 'group.phone' 't' 'short' 1 -Url $ru.Link -Icon $script:ChatqJoinIcon
Check 'when even 20 characters do not fit: the icon goes, then the title in the link' ($ju2 -notlike '*icon=*' -and $ju2 -like '*c%3D%26*') $ju2.Length
$plain = Get-ChatqJoinUrl 'k' 'group.phone' 'chatq x' 'hi' 1
Check 'no link, no icon, no id: the Join URL is what it always was' ($plain -eq 'https://joinjoaomgcd.appspot.com/_ah/api/messaging/v1/sendPush?apikey=k&deviceId=group.phone&title=chatq%20x&text=hi&priority=1&group=chatq') $plain

# --- Join's device list ------------------------------------------------------------
$script:ChatqJoinDevicesSeam = { param($u) $script:PhDevUrl = $u; '{"success":true,"records":[{"deviceId":"abc","deviceName":"Pixel 8","deviceType":1,"model":"GKWS6"}]}' }
$dv = Get-ChatqJoinDevices 'key1'
Check 'Join devices: the account''s, then the three groups' (-not $dv.Error -and @($dv.Devices).Count -eq 4 -and $dv.Devices[0].Name -eq 'Pixel 8' -and $dv.Devices[0].Model -eq 'GKWS6' -and
    $dv.Devices[3].Id -eq 'group.all' -and $script:PhDevUrl -like '*/registration/v1/listDevices?apikey=key1') $script:PhDevUrl
$script:ChatqJoinDevicesSeam = { param($u) '{"success":false,"userAuthError":true}' }
$dvBad = Get-ChatqJoinDevices 'bad'
$script:ChatqJoinDevicesSeam = { param($u) 'not json' }
$dvJunk = Get-ChatqJoinDevices 'bad'
Check 'a refused key, or an answer that is not JSON, says so and still lists the groups' ($dvBad.Error -eq 'Join refused the API key' -and $dvJunk.Error -like '*not JSON*' -and
    @($dvBad.Devices).Count -eq 3) "$($dvBad.Error) | $($dvJunk.Error)"

# --- a listening watcher's view of the limits --------------------------------------
# The watcher is made to look alive by holding its lock here. Its saved view
# says Claude is limited by something only it could know; while it only
# listens, that view is not trusted and the transcripts are scanned instead.
$phStateWas = Read-TestFile $script:ChatqStatePath
$Wl = New-ChatqWatchState
$Wl.blocked['claude'] = [pscustomobject]@{ Until = (Get-Date).AddHours(3); Type = 'phone-test-type'; Source = 'test' }
$wlk = [System.IO.File]::Open($script:ChatqLockPath, 'OpenOrCreate', 'ReadWrite', 'None')
try {
    Save-ChatqWatchState $Wl
    $bRun = Get-ChatqBlocks
    $Wl.listening = $true
    Save-ChatqWatchState $Wl
    $bListen = Get-ChatqBlocks
    $flag = (Get-ChatqState).listening
}
finally { $wlk.Dispose() }
Restore-TestFile $script:ChatqStatePath $phStateWas
Check 'a running watcher''s view is trusted; a listening one''s is not - the transcripts are read instead' ($bRun['claude'].Type -eq 'phone-test-type' -and $flag -eq $true -and
    (-not $bListen['claude'] -or $bListen['claude'].Type -ne 'phone-test-type')) "$($bRun['claude'].Type) / $($bListen['claude'].Type) / $flag"

# --- the watcher listens, then leaves ----------------------------------------------
# The waits, the keep-awake and the board are watched through the functions
# themselves: a wait is a second, not 15, and the third ends the window -
# three waits, then out, however long a pass takes on a slow machine.
foreach ($j in @(Get-ChatqJobs | Where-Object { $_.id -notin $phJobsBefore })) { $null = Remove-ChatqJob $j 'test' }
# the loop runs whatever is queued: whatever earlier sections left there is
# skipped, this being the last section
foreach ($j in @(Get-ChatqJobs | Where-Object { $_.state -eq 'queued' })) { Complete-ChatqJob $j 'skipped' ([pscustomobject]@{ kind = 'skipped'; reason = 'test' }) 'test' }
$phFn = @{ Wait = ${function:Wait-ChatqUntil}; Awake = ${function:Set-ChatqKeepAwake}; Board = ${function:Write-ChatqBoard}; Open = ${function:Test-ChatqReplyOpen} }
$script:PhWaits = 0; $script:PhAwakeOn = 0; $script:PhBoards = 0; $script:PhListenSeen = $false
${function:Wait-ChatqUntil} = {
    param([datetime]$When)
    $script:PhWaits++
    Start-Sleep -Milliseconds 1000
    if ($script:PhWaits -eq 3) { $null = Use-ChatqReplyState { param($st) $st.openUntil = (Get-Date).AddSeconds(-1).ToUniversalTime().ToString('o') } }
    # a window never seen shut fails the check below rather than hang the
    # run: chatqrun -Stop's file, which the loop takes and leaves on
    if ($script:PhWaits -eq 60) { Save-ChatqText $script:ChatqStopPath 'stop' }
}
${function:Set-ChatqKeepAwake} = { param([bool]$On) if ($On) { $script:PhAwakeOn++ } }
${function:Write-ChatqBoard} = { $script:PhBoards++; if ((Get-ChatqState).listening) { $script:PhListenSeen = $true } }
# what the log gained since a length Get-Item took: that is bytes, so the
# text is cut as bytes - chatq's middle dot is two of them, and a cut by
# characters lands past the start of what is new
$logSince = { param($p, $from) $b = [System.IO.File]::ReadAllBytes($p); $utf8.GetString($b, $from, $b.Length - $from) }
try {
    # a window: the old one shut (replies off and on), reply.hours at 0.02 -
    # 72 s, only a cap, the third wait ends it - and one alert sent
    chatnotify -Reply off *> $null
    chatnotify -Reply on *> $null
    $null = Set-ChatqNotifyConfig @{ ReplyHours = 0.02 }
    $null = Send-ChatqAlert 'done' 'short window' 1
    $script:PhFeed = ''
    $script:ChatqReplyPolledAt = $null
    $p0 = $script:PhPolls.Count
    $wl = Join-Path $script:ChatqLogDir 'watcher.log'
    $wl0 = if (Test-Path -LiteralPath $wl) { (Get-Item -LiteralPath $wl).Length } else { 0 }
    $open0 = Test-ChatqReplyOpen
    $sp0 = $script:PhSpawns
    $t0 = Get-Date
    Invoke-ChatqWatchLoop -Foreground *> $null
    $took = ((Get-Date) - $t0).TotalSeconds
    $wtext = & $logSince $wl $wl0
    Check 'the watcher listens while a window is open, polls, then leaves when it shuts' ($open0 -and $took -ge 3 -and $took -lt 30 -and $wtext -like '*listening for phone replies until*' -and
        $wtext -like '*replies closed*' -and $wtext -like '*queue empty*' -and ($script:PhPolls.Count - $p0) -ge 1 -and $script:PhWaits -ge 3) "open $open0, took $took s, polls $($script:PhPolls.Count - $p0), waits $($script:PhWaits): $wtext"
    Check 'listening holds nothing awake, marks the state as listening, and writes the board only coming in and going out' ($script:PhAwakeOn -eq 0 -and $script:PhBoards -le 2 -and
        $script:PhListenSeen -and -not (Get-ChatqState).listening -and $script:PhSpawns -eq $sp0) "awake $($script:PhAwakeOn), boards $($script:PhBoards) over $($script:PhWaits) waits, listening seen $($script:PhListenSeen)"
    # the window shut: a watcher started now leaves at once
    $wl1 = (Get-Item -LiteralPath $wl).Length
    $w1 = $script:PhWaits
    $t0 = Get-Date
    Invoke-ChatqWatchLoop -Foreground *> $null
    $took = ((Get-Date) - $t0).TotalSeconds
    $wtext = & $logSince $wl $wl1
    Check 'openUntil in the past: the watcher leaves at once, without listening' (-not (Test-ChatqReplyOpen) -and $took -lt 10 -and $script:PhWaits -eq $w1 -and
        $wtext -notlike '*listening*' -and $wtext -like '*queue empty*') "took $took s: $wtext"
    # an alert sent just as the watcher left - after its last look at the
    # window, before it let go of the lock: it starts another on its way out
    $script:PhOpenCalls = 0
    ${function:Test-ChatqReplyOpen} = { param($Cfg) $script:PhOpenCalls++; $script:PhOpenCalls -ge 3 }
    $wl2 = (Get-Item -LiteralPath $wl).Length
    $sp0 = $script:PhSpawns
    Invoke-ChatqWatchLoop -Foreground *> $null
    ${function:Test-ChatqReplyOpen} = $phFn.Open
    $wtext = & $logSince $wl $wl2
    Check 'a window opened as the watcher left: another watcher is started once the lock is let go' ($script:PhSpawns -eq $sp0 + 1 -and
        $wtext -like '*queue empty*watcher * stopped*starting another to listen*') "spawns $($script:PhSpawns - $sp0): $wtext"
    # the same, with chatqrun -Stop's file written as it left: no watcher is
    # started over a stop - it would delete the file unread
    $script:PhOpenCalls = 0
    ${function:Test-ChatqReplyOpen} = { param($Cfg) $script:PhOpenCalls++; if ($script:PhOpenCalls -eq 2) { Save-ChatqText $script:ChatqStopPath 'stop' }; $script:PhOpenCalls -ge 3 }
    $sp0 = $script:PhSpawns
    Invoke-ChatqWatchLoop -Foreground *> $null
    ${function:Test-ChatqReplyOpen} = $phFn.Open
    $stopLeft = Test-Path -LiteralPath $script:ChatqStopPath
    Remove-Item -LiteralPath $script:ChatqStopPath -Force -EA SilentlyContinue
    Check 'a stop written as the watcher left: no watcher is started after it, and the stop stays' ($script:PhSpawns -eq $sp0 -and $stopLeft) "spawns $($script:PhSpawns - $sp0), stop file $stopLeft"
}
finally {
    ${function:Wait-ChatqUntil} = $phFn.Wait
    ${function:Set-ChatqKeepAwake} = $phFn.Awake
    ${function:Write-ChatqBoard} = $phFn.Board
    ${function:Test-ChatqReplyOpen} = $phFn.Open
    $script:ChatqForeground = $false
}

# chatqrun -Stop shuts the window too: no new shell starts a watcher to listen
$null = Set-ChatqNotifyConfig @{ ReplyHours = 12 }
$null = Send-ChatqAlert 'done' 'window again' 1
$openBefore = Test-ChatqReplyOpen
$said = (chatqrun -Stop 6>&1 | Out-String -Width 400)
Check 'chatqrun -Stop shuts the reply window, a watcher running or not' ($openBefore -and -not (Test-ChatqReplyOpen) -and -not (Get-ChatqReplyState).openUntil -and
    $said -like '*not running*') "$openBefore / $said"

# --- chats you run yourself: alerts from the overlay's pass ------------------------
# Update-ChatqLiveAlerts driven with registry entries made here and -Now moved
# by hand; each alert lands in $script:ChatqLiveSendSeam, not in a process.
# The outbox's sender is run in this process, with Join seamed as above.
$lvWas = @{ Send = $script:ChatqLiveSendSeam; Fg = $script:ChatForegroundSeam; Table = $script:ChatProcessTableSeam; Idle = $script:ChatqIdleSeam; Starter = ${function:Start-ChatqOutboxSender} }
$script:LvSent = [System.Collections.Generic.List[object]]::new()
$script:ChatqLiveSendSeam = { param($a) $script:LvSent.Add($a) }
$script:ChatForegroundSeam = { 0 }
$script:ChatProcessTableSeam = { @() }
$script:ChatqIdleSeam = 99999
$idLive = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
$pLive = New-FakeChat $projA $idLive 'Live chat title' 0.05 @('make the build faster')
# a tool call, then the reply the turn ended on - a question
$lvTool = [ordered]@{ parentUuid = $null; isSidechain = $false; type = 'assistant'; uuid = [guid]::NewGuid().ToString(); timestamp = (Get-Date).ToUniversalTime().ToString('o'); cwd = $projA; sessionId = $idLive
    message = [ordered]@{ model = 'claude-opus-5'; role = 'assistant'; content = @([ordered]@{ type = 'tool_use'; id = 'toolu_01'; name = 'Bash'; input = [ordered]@{ command = 'npm run build' } }); stop_reason = 'tool_use' } }
$lvEnd = [ordered]@{ parentUuid = $null; isSidechain = $false; type = 'assistant'; uuid = [guid]::NewGuid().ToString(); timestamp = (Get-Date).ToUniversalTime().ToString('o'); cwd = $projA; sessionId = $idLive
    message = [ordered]@{ model = 'claude-opus-5'; role = 'assistant'; content = @([ordered]@{ type = 'text'; text = "Made the build three times faster.`n`nShould I commit this?" }); stop_reason = 'end_turn' } }
[System.IO.File]::AppendAllText($pLive, ($lvTool | ConvertTo-Json -Compress -Depth 8) + "`n" + ($lvEnd | ConvertTo-Json -Compress -Depth 8) + "`n", $utf8)
$lvEntry = {
    param([string]$Status, [string]$Kind = 'interactive', [string]$Entrypoint = 'claude-vscode')
    [pscustomobject]@{ SessionId = $idLive; Pid = 4242; Status = $Status; Kind = $Kind; WaitingFor = $(if ($Status -eq 'waiting') { 'permission' } else { $null })
        Cwd = $projA; Name = 'registry-name'; ProcStart = $null; StartedAt = $null; Entrypoint = $Entrypoint }
}
$lvCtx = { @{ ClaudeHome = $claudeHome; Text = @{}; Jobs = @(); Chains = @{} } }
$script:LvBase = Get-Date
$lvRun = {
    # one pass per step, @(seconds after the base, status); the alerts it made
    param($Ctx, [object[]]$Steps, [string]$Kind = 'interactive', [string]$Entrypoint = 'claude-vscode')
    $n0 = $script:LvSent.Count
    foreach ($s in $Steps) { Update-ChatqLiveAlerts $Ctx @(& $lvEntry $s[1] $Kind $Entrypoint) $script:LvBase.AddSeconds([double]$s[0]) }
    , @($script:LvSent | Select-Object -Skip $n0)
}
$lvOvLog = { $p = Join-Path $script:ChatqLogDir 'overlay.log'; if (Test-Path -LiteralPath $p) { ([System.IO.File]::ReadAllText($p, $utf8) -split "`n" | Select-Object -Last 3) -join ' | ' } else { '' } }
$lvBusyIdle = @(@(0, 'idle'), @(2, 'busy'), @(4, 'idle'), @(12, 'idle'))
$lvWait = @(@(0, 'idle'), @(2, 'waiting'), @(30, 'waiting'))

$c = & $lvCtx
$r = & $lvRun $c @(@(0, 'waiting'), @(30, 'waiting'), @(90, 'waiting'))
Check 'live alerts: the first pass only notes each chat - one already waiting when the overlay starts sends nothing, then or later' ($r.Count -eq 0 -and $c.PhoneSeen.ContainsKey($idLive)) (& $lvOvLog)
$c = & $lvCtx
$r1 = & $lvRun $c @(@(0, 'idle'), @(2, 'waiting'), @(21, 'waiting'))
$r2 = & $lvRun $c @(@(23, 'waiting'), @(40, 'waiting'), @(90, 'waiting'))
$a = if ($r2.Count) { $r2[0] } else { $null }
Check 'waiting on you 20 s: one needs input alert, priority 2, with what it waits for and the folder - not at 19 s, not twice' ($r1.Count -eq 0 -and $r2.Count -eq 1 -and
    $a.event -eq 'needs input' -and $a.priority -eq 2 -and $a.text -eq "Live chat title $([char]0xB7) waiting on you: permission (Bash) $([char]0xB7) projA" -and
    $a.sessionId -eq $idLive -and $a.title -eq 'Live chat title' -and $a.cwd -eq $projA -and $a.path -eq $pLive -and $a.home -eq $claudeHome) "$($r1.Count)/$($r2.Count): $($a | ConvertTo-Json -Compress) $(& $lvOvLog)"
$c = & $lvCtx
$r1 = & $lvRun $c @(@(0, 'idle'), @(2, 'busy'), @(4, 'idle'), @(8, 'idle'))
$r2 = & $lvRun $c @(, @(10, 'idle'))
$a = if ($r2.Count) { $r2[0] } else { $null }
Check 'busy to idle for 5 s: one done alert, priority 1, the reply''s end as the watcher words it - asks: for a question' ($r1.Count -eq 0 -and $r2.Count -eq 1 -and
    $a.event -eq 'done' -and $a.priority -eq 1 -and
    $a.text -eq "Live chat title $([char]0xB7) finished $([char]0xB7) asks: `"Made the build three times faster. / Should I commit this?`"") "$($r1.Count)/$($r2.Count): $($a.text) $(& $lvOvLog)"
$r3 = & $lvRun $c @(@(20, 'busy'), @(22, 'idle'), @(30, 'idle'), @(100, 'idle'))
$r4 = & $lvRun $c @(, @(200, 'idle'))
Check 'once per chat and event every 3 minutes: the next turn''s done waits, and goes once the 3 minutes are up' ($r3.Count -eq 0 -and $r4.Count -eq 1 -and $r4[0].event -eq 'done') "$($r3.Count)/$($r4.Count)"
# a phone-made chat Claude has not titled yet, run on at the PC: its live
# alert goes by the neutral title its job holds, not the prompt the pass
# read as the chat's first line - until Claude's own title is there
$idLvH = 'cccccccc-cccc-4ccc-8ccc-c0c0c0c0c0c0'
$pLvH = New-FakeChat $projA $idLvH '' 0.05 @('rotate the prod keys')
$jLvH = (New-ChatqJob -Row (Get-ChatqRowById $idLvH -Path $pLvH) -Prompt 'and the staging ones' -Title 'phone chat 09:41' -Set @{ titleHeld = $true }).Job
$lvHeld = {
    param($Tx)
    $cx = & $lvCtx
    $cx.Text[$idLvH] = $Tx
    $n0 = $script:LvSent.Count
    foreach ($s in $lvBusyIdle) {
        Update-ChatqLiveAlerts $cx @([pscustomobject]@{ SessionId = $idLvH; Pid = 4243; Status = $s[1]; Kind = 'interactive'; WaitingFor = $null
                Cwd = $projA; Name = 'registry-name'; ProcStart = $null; StartedAt = $null; Entrypoint = 'claude-vscode' }) $script:LvBase.AddSeconds([double]$s[0])
    }
    , @($script:LvSent | Select-Object -Skip $n0)
}
$rH0 = & $lvHeld @{ Path = $pLvH; First = 'rotate the prod keys' }
$rH1 = & $lvHeld @{ Path = $pLvH; First = 'rotate the prod keys'; AiTitle = 'Key rotation' }
Check 'a live alert about a phone-made chat Claude has not titled: the title its job holds, never the prompt; Claude''s own once there' ($rH0.Count -eq 1 -and
    $rH0[0].title -eq 'phone chat 09:41' -and $rH0[0].text -notlike '*prod keys*' -and $rH1.Count -eq 1 -and $rH1[0].title -eq 'Key rotation') "$($rH0.Count) $($rH0[0].title) / $($rH1.Count) $($rH1[0].title)"
$null = Remove-ChatqJob (Find-ChatqJob $jLvH.id) 'test'
Remove-Item -LiteralPath $pLvH -Force
# a claude -p into the chat - chatq's run, a phone reply, anyone's script -
# is no chat someone types in: Claude Code 2.1.283 registers one
# interactive, stamped sdk-cli, and an older one says another kind
$rk = & $lvRun (& $lvCtx) ($lvBusyIdle + @(, @(60, 'idle'))) 'print' 'sdk-cli'
$rs = & $lvRun (& $lvCtx) ($lvBusyIdle + @(, @(60, 'idle'))) 'interactive' 'sdk-cli'
$rsw = & $lvRun (& $lvCtx) $lvWait 'interactive' 'sdk-ts'
Check 'live alerts: a claude -p is none, by its kind or by its sdk-* entrypoint - no done, no needs input' (
    $rk.Count -eq 0 -and $rs.Count -eq 0 -and $rsw.Count -eq 0) "$($rk.Count) $($rs.Count) $($rsw.Count)"
$script:ChatqIdleSeam = 0
$c = & $lvCtx
$r1 = & $lvRun $c ($lvBusyIdle + @(, @(60, 'idle')))
$r1w = & $lvRun (& $lvCtx) $lvWait
$script:ChatqIdleSeam = 99999
$r2 = & $lvRun $c @(, @(120, 'idle'))
$script:ChatqIdleSeam = 0
$c2 = & $lvCtx
$null = & $lvRun $c2 $lvBusyIdle
$script:ChatqIdleSeam = 99999
$r3 = & $lvRun $c2 @(, @(400, 'idle'))
Check 'at the PC: nothing at all; away before quietMinutes have passed since it finished: sent then; any later: never' ($r1.Count -eq 0 -and $r1w.Count -eq 0 -and
    $r2.Count -eq 1 -and $r3.Count -eq 0) "$($r1.Count) $($r1w.Count) / $($r2.Count) / $($r3.Count)"
# the window in front counts for nothing. Away, the alert goes all the same:
# one Code.exe owns every VS Code window, so VS Code left in front would
# silence every chat in it. At the PC nothing goes, in front or not, and
# nothing is settled by it - away later still sends it while it is news.
$script:ChatForegroundSeam = { 4242 }
$rf = & $lvRun (& $lvCtx) $lvBusyIdle
$rfw = & $lvRun (& $lvCtx) $lvWait
$script:ChatqIdleSeam = 0
$cp = & $lvCtx
$rpf = & $lvRun $cp $lvBusyIdle
$rpfw = & $lvRun (& $lvCtx) $lvWait
$script:ChatForegroundSeam = { 0 }
$rpb = & $lvRun (& $lvCtx) $lvBusyIdle
$rpbw = & $lvRun (& $lvCtx) $lvWait
$script:ChatForegroundSeam = { 4242 }
$script:ChatqIdleSeam = 99999
$rpa = & $lvRun $cp @(, @(60, 'idle'))
$script:ChatForegroundSeam = { 0 }
Check 'the chat''s window in front while you are away: the alert goes all the same, done and needs input' ($rf.Count -eq 1 -and $rf[0].event -eq 'done' -and
    $rfw.Count -eq 1 -and $rfw[0].event -eq 'needs input') "$($rf.Count) $($rfw.Count) $(& $lvOvLog)"
Check 'at the PC: nothing goes, its window in front or not - and nothing is settled, so away later still sends it' ($rpf.Count -eq 0 -and $rpfw.Count -eq 0 -and
    $rpb.Count -eq 0 -and $rpbw.Count -eq 0 -and $rpa.Count -eq 1 -and $rpa[0].event -eq 'done') "$($rpf.Count) $($rpfw.Count) $($rpb.Count) $($rpbw.Count) / $($rpa.Count)"
# the first pass reads the idle clock: its C# compiled as the overlay starts,
# on its window thread then rather than at the first finished turn
$lvIdleFn = ${function:Get-ChatqIdleSeconds}
$script:LvIdleReads = 0
${function:Get-ChatqIdleSeconds} = { $script:LvIdleReads++; 0 }
try { $null = & $lvRun (& $lvCtx) @(, @(0, 'idle')) } finally { ${function:Get-ChatqIdleSeconds} = $lvIdleFn }
Check 'the first pass, which sends nothing, reads the idle clock once - its compile done as the overlay starts' ($script:LvIdleReads -eq 1) "$($script:LvIdleReads) reads"
$cw = & $lvCtx
$cw.Jobs = @(@{ Job = [pscustomobject]@{ id = 'lvjob'; seq = 1; state = 'running'; sessionId = $idLive }; First = 'x' })
$rw = & $lvRun $cw $lvBusyIdle
$rk = & $lvRun (& $lvCtx) $lvBusyIdle 'print'
Check 'a chat the watcher is running a job in, or an entry that is not interactive: no alert' ($rw.Count -eq 0 -and $rk.Count -eq 0) "$($rw.Count) $($rk.Count)"
$lvBad = Set-ChatqNotifyConfig @{ LiveAlerts = 'maybe' }
$said = (chatnotify -LiveAlerts off 6>&1 | Out-String -Width 400)
$ro = & $lvRun (& $lvCtx) ($lvBusyIdle + @(@(14, 'waiting'), @(40, 'waiting')))
$status = (chatnotify 6>&1 | Out-String -Width 400)
$null = Set-ChatqNotifyConfig @{ LiveAlerts = $true }
$statusOn = (chatnotify 6>&1 | Out-String -Width 400)
Check 'liveAlerts off (chatnotify -LiveAlerts off): no alert, and the status says so; on again; a value that is not on or off saves nothing' ($lvBad.Error -and
    $ro.Count -eq 0 -and (Get-ChatqConfig).liveAlerts -eq $true -and $said -like '*chats you run yourself: no phone alerts*' -and
    $status -like '*chats you run yourself: off*' -and $statusOn -like '*chats you run yourself: on - waiting on you or finished, while you are away 5 min*') "$said / $status / $statusOn"
# The overlay restarts on newer code by itself (Test-ChatOverlayCodeChanged),
# so a running one is all the status names - no "older copy" any more - and
# one not running says that alone.
New-ChatqDir (Split-Path -Parent $script:ChatOverlayLockPath)
$lvOvLk = [System.IO.File]::Open($script:ChatOverlayLockPath, 'OpenOrCreate', 'ReadWrite', 'None')
try {
    $stRun = Get-ChatqLiveAlertStatusText
    $stExtras = (@(Get-ChatqNotifyExtrasStatus (Get-ChatqConfig)) | ForEach-Object { $_.Text }) -join ' / '
}
finally { $lvOvLk.Dispose() }
$stGone = Get-ChatqLiveAlertStatusText
Check 'a running overlay: the status names nothing more - it restarts on new code itself; not running says that alone' (
    $stRun -eq 'on - waiting on you or finished, while you are away 5 min' -and $stExtras -notlike '*older copy*' -and
    $stGone -like '*the overlay is not running*' -and $stGone -notlike '*older copy*') "$stRun / $stExtras / $stGone"
$lvCfgMid = [System.IO.File]::ReadAllText($script:ChatqConfigPath, $utf8)
$null = Set-ChatqNotifyConfig @{ RemoveJoin = $true; Ntfy = '' }
$rn = & $lvRun (& $lvCtx) $lvBusyIdle
[System.IO.File]::WriteAllText($script:ChatqConfigPath, $lvCfgMid, $utf8)
chatnotify -Events done *> $null
$re1 = & $lvRun (& $lvCtx) $lvWait
$re2 = & $lvRun (& $lvCtx) $lvBusyIdle
chatnotify -Events all *> $null
Check 'no phone channel: no alert; phoneEvents holds needs input back from live alerts too, done still goes' ($rn.Count -eq 0 -and $re1.Count -eq 0 -and $re2.Count -eq 1) "$($rn.Count) $($re1.Count) $($re2.Count)"
Check 'the overlay''s own context never sends by itself: only the Windows host sets WantPhone (chatoverlay -Print and the macOS collector do not)' (-not (New-ChatOverlayContext).WantPhone)

# the sender: the alert's file sent through Send-ChatqAlert as about its chat,
# with a reply link that says j=live, then deleted
Remove-Item -Path (Join-Path $script:ChatqOutboxDir '*') -Force -EA SilentlyContinue
$rs = & $lvRun (& $lvCtx) $lvWait
$lvFiles = @(Get-ChildItem -LiteralPath $script:ChatqOutboxDir -Filter *.json -File)
$n0 = $script:PhJoins.Count
$sn = Send-ChatqOutbox
$lj = & $phLastJoin
$la = $lj.F['a']
$le = (Get-ChatqReplyState).alerts[$la]
Check 'the outbox: one file per alert, sent through Join as about its chat and deleted' ($rs.Count -eq 1 -and $lvFiles.Count -eq 1 -and $sn -eq 1 -and
    $script:PhJoins.Count -eq $n0 + 1 -and $lj.Q['title'] -eq "chatq $([char]0xB7) needs input" -and $lj.Q['text'] -eq $rs[0].text -and
    $lj.Q['notificationId'] -eq ('chatq-' + $idLive.Substring(0, 12)) -and -not @(Get-ChildItem -LiteralPath $script:ChatqOutboxDir -Filter *.json -File).Count) "$($lvFiles.Count) files, sent ${sn}: $($lj.Url)"
Check 'its link says j=live and names the chat; the registry keeps the chat - id, title, folder, transcript, config dir - and no job' ($lj.F['j'] -eq 'live' -and
    $lj.F['e'] -eq 'needs input' -and $lj.F['p'] -eq 'claude' -and $lj.F['c'] -eq 'Live chat title' -and $lj.F['n'] -eq '' -and -not $lj.F.ContainsKey('x') -and
    $le -and $le['live'] -eq $true -and $le.sessionId -eq $idLive -and $le.provider -eq 'claude' -and $le.title -eq 'Live chat title' -and $le.cwd -eq $projA -and
    $le.path -eq $pLive -and $le.home -eq $claudeHome -and -not $le.jobId) "$($lj.Url) / $($le | ConvertTo-Json -Compress)"
$c0 = @(Get-ChatqJobs).Count
$txt = & $phSay 'phlive1' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $la -Act prompt -Text 'yes, commit it')
$lvJob = @(Get-ChatqJobs | Where-Object { $_.rule -eq 'phone' -and $_.sessionId -eq $idLive })[0]
Check 'a prompt answering it queues a job for that chat, in its config dir, capped at the phone''s mode' (@(Get-ChatqJobs).Count -eq $c0 + 1 -and $lvJob -and
    (Read-ChatqPrompt $lvJob) -eq 'yes, commit it' -and $lvJob.mode -eq 'acceptEdits' -and $lvJob.home -eq $claudeHome -and
    $txt -like "queued #$($lvJob.seq) * - runs in acceptEdits, the phone's limit") "$txt / $($lvJob.mode) $($lvJob.home)"
# the chat still on a prompt at the PC: queued all the same, and the push says
# it goes only once that is answered there; idle, the push is the usual one.
# The registry alone is asked, under the chat's config dir.
$lvLiveFn = ${function:Get-ChatqLiveSessions}
$script:LvRegAsk = $null
$script:LvRegStatus = 'waiting'
${function:Get-ChatqLiveSessions} = {
    param([string]$ConfigDir, [switch]$RegistryOnly)
    $script:LvRegAsk = "$ConfigDir|$([bool]$RegistryOnly)"
    [pscustomobject]@{ SessionId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'; Pid = 4242; Status = $script:LvRegStatus; Kind = 'interactive'; WaitingFor = 'permission' }
}
try {
    $txtW = & $phSay 'phlive1w' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $la -Act prompt -Text 'then push it')
    $lvJobW = @(Get-ChatqJobs | Where-Object { $_.rule -eq 'phone' -and $_.sessionId -eq $idLive } | Sort-Object seq)[-1]
    $askW = $script:LvRegAsk
    $script:LvRegStatus = 'idle'
    $txtI = & $phSay 'phlive1i' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $la -Act prompt -Text 'and tag it')
    $lvJobI = @(Get-ChatqJobs | Where-Object { $_.rule -eq 'phone' -and $_.sessionId -eq $idLive } | Sort-Object seq)[-1]
}
finally { ${function:Get-ChatqLiveSessions} = $lvLiveFn }
Check 'a prompt while the chat still waits on a prompt at the PC: queued, and the push says it goes once that is answered there; idle: the usual push' (
    $lvJobW -and $lvJobW.id -ne $lvJob.id -and (Read-ChatqPrompt $lvJobW) -eq 'then push it' -and
    $txtW -eq "queued #$($lvJobW.seq) - it goes once $($lvJobW.title) is free: it waits on a prompt at the PC - runs in acceptEdits, the phone's limit" -and
    $askW -eq "$claudeHome|True" -and $lvJobI -and $lvJobI.id -ne $lvJobW.id -and
    $txtI -eq "queued #$($lvJobI.seq) for $($lvJobI.title) - runs in acceptEdits, the phone's limit") "$txtW / $txtI / $askW"
$c0 = @(Get-ChatqJobs).Count
$txt = & $phSay 'phlive2' (Protect-ChatqReplyMessage -Key $rc.Key -Aid $la -Act retry)
$lj2 = & $phLastJoin
Check 'retry (allow, skip, stop) on a chat you run yourself is refused, and the answer''s link is about that chat still' ($txt -like '*not a chatq job - nothing to retry*' -and
    @(Get-ChatqJobs).Count -eq $c0 -and $lj2.F['j'] -eq 'live' -and $lj2.F['e'] -eq 'reply' -and -not $lj2.F.ContainsKey('x')) "$txt / $($lj2.Url)"
# a file 31 minutes old is dropped unsent
$lvOld = Join-Path $script:ChatqOutboxDir 'lvold.json'
Save-ChatqJson $lvOld ([ordered]@{ v = 1; at = (Get-Date).AddMinutes(-31).ToUniversalTime().ToString('o'); event = 'done'; text = 'too late'; priority = 1; sessionId = $idLive; title = 'x' })
$n0 = $script:PhJoins.Count
$sn = Send-ChatqOutbox
$lvLog = [System.IO.File]::ReadAllText((Join-Path $script:ChatqLogDir 'outbox.log'), $utf8)
Check 'an outbox file older than 30 minutes is dropped unsent, and the log says so' ($sn -eq 0 -and $script:PhJoins.Count -eq $n0 -and -not (Test-Path -LiteralPath $lvOld) -and
    $lvLog -like '*lvold.json: done dropped unsent - 31 min old*') $lvLog
# no seam: a sender is started unless one holds the lock - that one reads the
# folder again before it leaves
$script:LvStarts = 0
${function:Start-ChatqOutboxSender} = { $script:LvStarts++; $true }
$script:ChatqLiveSendSeam = $null
try {
    $lk = [System.IO.File]::Open($script:ChatqOutboxLockPath, 'OpenOrCreate', 'ReadWrite', 'None')
    try { $f1 = Send-ChatqLiveAlert @{ event = 'done'; text = 't'; priority = 1; sessionId = $idLive } }
    finally { $lk.Dispose() }
    $s1 = $script:LvStarts
    $f2 = Send-ChatqLiveAlert @{ event = 'done'; text = 't'; priority = 1; sessionId = $idLive }
}
finally { ${function:Start-ChatqOutboxSender} = $lvWas.Starter; $script:ChatqLiveSendSeam = { param($a) $script:LvSent.Add($a) } }
Check 'Send-ChatqLiveAlert: the file written; a sender started only when none holds the lock' ((Test-Path -LiteralPath $f1) -and (Test-Path -LiteralPath $f2) -and
    $s1 -eq 0 -and $script:LvStarts -eq 1) "starts $s1 then $($script:LvStarts)"
Remove-Item -Path (Join-Path $script:ChatqOutboxDir '*') -Force -EA SilentlyContinue
$lvL = Get-ChatqOutboxLaunch
$lvDec = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($lvL.Args[-1]))
Check 'the sender''s launch: hidden, no profile, the script loaded with CHATQ_OVERLAY, which then goes with the policy, then Send-ChatqOutbox' ($lvDec -eq $lvL.Command -and
    $lvDec -like "*CHATQ_OVERLAY='1'*" -and $lvDec -like "*$($script:ChatqScriptPath)*" -and $lvDec -like "*Remove-Item -LiteralPath 'env:PSExecutionPolicyPreference', 'env:CHATQ_OVERLAY'*Send-ChatqOutbox*" -and
    $lvL.Args -contains '-NoProfile' -and $lvL.Args -contains 'Bypass' -and (-not $script:ChatqIsWindows -or ($lvL.Args -contains 'Hidden' -and $lvL.Exe -like '*WindowsPowerShell*powershell.exe'))) $lvDec
$script:ChatqLiveSendSeam = $lvWas.Send
$script:ChatForegroundSeam = $lvWas.Fg
$script:ChatProcessTableSeam = $lvWas.Table
$script:ChatqIdleSeam = $lvWas.Idle
Remove-Item -LiteralPath $pLive -Force -EA SilentlyContinue

# --- put it all back ------------------------------------------------------------
foreach ($j in @(Get-ChatqJobs | Where-Object { $_.id -notin $phJobsBefore })) { $null = Remove-ChatqJob $j 'test' }
Remove-Item -LiteralPath $pBy -Force -EA SilentlyContinue
Restore-TestFile $script:ChatqConfigPath $phCfgWas
Remove-Item -LiteralPath $script:ChatqReplyPath -Force -EA SilentlyContinue
$script:ChatqAskSeam = $phWas.Ask
$script:ChatqPairWaitSeam = $phWas.PairWait
$script:ChatqReplyJunkLog = @{}
$script:ChatqSpawn = $phWas.Spawn
$script:ChatqJoinSeam = $phWas.Join
$script:ChatqReplyPollSeam = $phWas.Poll
$script:ChatqJoinDevicesSeam = $phWas.Devices
$script:ChatqIdleSeam = $phWas.Idle
$script:ChatqForeground = $phWas.Foreground
$script:ChatqReplyPolledAt = $null; $script:ChatqReplyErrAt = $null; $script:ChatqReplySavedAt = $null; $script:ChatqReplyBadIdAt = $null
$script:ChatqReplySeen = @{}; $script:ChatqReplyHandled = @{}
$env:CHATQ_WATCHER = '1'
