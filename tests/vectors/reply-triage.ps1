# tests/vectors/reply-triage.ps1: native/vectors/reply-triage.json, the reply
# poll's first look at what reaches the reply topic, the part chatqd takes
# over (native/SPEC.md 3.7). Per message: Test-ChatqReplyMessage's verdict -
# junk at a stage with its error, or a candidate of a kind - and the
# replies.log line a poll of that message alone writes when it is junk. Then
# whole polls, Invoke-ChatqReplyPoll -Force over a scripted feed with the
# clock moved on between them: what each returned and logged, the throttles
# and caches it left, and where replies.json says polling got to.
#
# A candidate is as far as chatqd goes, so it is as far as a poll here may
# go: Receive-ChatqReply is made to throw, and a case whose message reached it
# fails. A pairing answer that passes Unprotect-ChatqPairMessage's checks
# before RSA is chatqd's candidate whatever RSA makes of it: where PowerShell
# refuses one after RSA - the key does not open it, its payload is not v2 -
# the answer holds chatqd's verdict as native, found by running the same
# checks with New-ChatqRsa made to throw.
#
# Each case writes data/config.json into Enter-NvData's data/. Its secrets
# are stored unprotected ({value, protected: false}), as off Windows: DPAPI
# is this user's on this PC, not a vector's. A pairing key meant not to open
# is a protected text that is no DPAPI blob, which Unprotect-ChatqSecret
# turns into $null as it does a blob from another user. Log stamps are
# checked against the clock and cut off; an RSA error's .NET text, which each
# PowerShell words its own way, is cut to "could not be read: ...".

function ConvertTo-NvReplyTriageHex([byte[]]$Bytes) {
    # lowercase hex, $null kept
    if ($null -eq $Bytes) { return $null }
    return (-join @(foreach ($b in $Bytes) { $b.ToString('x2') }))
}

function Set-NvReplyTriagePart([string]$Message, [int]$Index, [string]$Part) {
    # the message with one of its dot-separated parts replaced
    $p = @($Message -split '\.')
    $p[$Index] = $Part
    return ($p -join '.')
}

function Step-NvReplyTriageChar([string]$Text, [int]$At) {
    # $Text with the character at $At (counted from the end when negative)
    # one on in the base64url alphabet
    $abc = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_'
    $i = if ($At -lt 0) { $Text.Length + $At } else { $At }
    $c = $abc[($abc.IndexOf($Text[$i]) + 1) % 64]
    return $Text.Substring(0, $i) + $c + $Text.Substring($i + 1)
}

function New-NvReplyTriageSealed([byte[]]$Master, [string]$Label, [string]$Prefix, [string]$Id, [byte[]]$Iv, [byte[]]$Ct) {
    # a message sealed by hand: any ciphertext, under the MAC that checks out
    $ks = Get-ChatqLabelKeys $Master $Label $Id
    $head = $Prefix + '.' + $Id + '.' + (ConvertTo-ChatqB64Url $Iv) + '.' + (ConvertTo-ChatqB64Url $Ct)
    return $head + '.' + (ConvertTo-ChatqB64Url (Get-ChatqHmac $ks.Mac ($script:NvUtf8.GetBytes($head))))
}

function New-NvReplyTriageLine([string]$Id, $Message) {
    # one line of ntfy's poll: a message event
    return (ConvertTo-NvJson ([ordered]@{ id = $Id; event = 'message'; message = $Message }) -Compress)
}

function Get-NvReplyTriageFixture {
    # tests/fixtures/pair-vector.json: an RSA key, and a pairing answer Node
    # sealed to it
    return (Read-NvJson ([IO.File]::ReadAllText((Join-Path (Join-Path $here 'fixtures') 'pair-vector.json'), $script:NvUtf8)))
}

function Set-NvReplyTriageConfig($Rc) {
    # data/config.json for a case's rc: replies on, its topic, the phone's
    # key D when it has one, and unless pairing is 'none' a pairing - id
    # abcdefghij, open until 2099 - whose key is the fixture's RSA key
    # ('fixture'), a text that is no key ('garbage'), a protected text DPAPI
    # cannot open ('unreadable'), or not there ('absent')
    $reply = [ordered]@{ on = $true; topic = [ordered]@{ value = [string]$Rc.topic; protected = $false } }
    if ($null -ne $Rc.master) { $reply['key'] = [ordered]@{ value = (ConvertTo-ChatqB64Url (ConvertFrom-NvHex ([string]$Rc.master))); protected = $false } }
    $kind = [string]$Rc.pairing
    if ($kind -cne 'none') {
        $pair = [ordered]@{ id = 'abcdefghij'; expires = '2099-01-01T00:00:00.0000000Z' }
        if ($kind -ceq 'fixture') { $pair['key'] = [ordered]@{ value = (ConvertTo-NvJson (Get-NvReplyTriageFixture).private -Compress); protected = $false } }
        elseif ($kind -ceq 'garbage') { $pair['key'] = [ordered]@{ value = 'not a key'; protected = $false } }
        elseif ($kind -ceq 'unreadable') { $pair['key'] = [ordered]@{ value = 'not a DPAPI blob'; protected = $true } }
        elseif ($kind -cne 'absent') { throw "no such pairing: $kind" }
        $reply['pairing'] = $pair
    }
    [IO.File]::WriteAllText($script:ChatqConfigPath, (ConvertTo-NvJson ([ordered]@{ reply = $reply })), $script:NvUtf8)
}

function Confirm-NvReplyTriageRc($Rc, $PairKey, $Want) {
    # the config Set-NvReplyTriageConfig wrote reads back as the case says
    $got = [ordered]@{
        topic = [string]$Rc.Topic; master = (ConvertTo-NvReplyTriageHex $Rc.Master)
        pairId = $(if ($Rc.PairId) { [string]$Rc.PairId } else { $null }); pairKey = ($null -ne $PairKey)
    }
    $exp = [ordered]@{ topic = [string]$Want.topic; master = $Want.master; pairId = $Want.pairId; pairKey = [bool]$Want.pairKey }
    $g = ConvertTo-NvJson $got -Compress
    $e = ConvertTo-NvJson $exp -Compress
    if ($g -cne $e) { throw "the config reads back as $g, not $e" }
}

function Get-NvReplyTriageVerdict($C) {
    # a Test-ChatqReplyMessage answer as the vector holds it
    if ($C.Junk) {
        $e = [string]$C.Error
        if ($e.StartsWith('could not be read: ', [StringComparison]::Ordinal)) { $e = 'could not be read: ...' }
        return [ordered]@{ junk = $true; stage = [string]$C.Stage; error = $e; kind = $null }
    }
    $kind = if ($null -ne $C.Pair) { 'pair' } elseif ($C.PSObject.Properties['Compose']) { 'compose' } else { 'reply' }
    return [ordered]@{ junk = $false; stage = $null; error = $null; kind = $kind }
}

function Get-NvReplyTriageNative($Rc, [string]$Message, $PairKey) {
    # chatqd's verdict: the same checks with RSA made to throw, so that a
    # pairing answer that gets as far as RSA is a candidate
    $was = ${function:New-ChatqRsa}
    try {
        Set-Item -Path 'function:script:New-ChatqRsa' -Value { throw 'NV-NATIVE-RSA' }
        $c = Test-ChatqReplyMessage $Rc $Message $PairKey
    }
    finally { Set-Item -Path 'function:script:New-ChatqRsa' -Value $was }
    if ($c.Junk -and [string]$c.Error -ceq 'could not be read: NV-NATIVE-RSA') { return [ordered]@{ junk = $false; stage = $null; error = $null; kind = 'pair' } }
    return (Get-NvReplyTriageVerdict $c)
}

function Use-NvReplyTriageCaches([scriptblock]$RtBlock) {
    # $RtBlock with the poll's own caches as a watcher starts with them, the
    # feed's seam free, and Receive-ChatqReply made to throw: all put back
    $rtNames = 'ChatqReplyPolledAt', 'ChatqReplyErrAt', 'ChatqReplyBadIdAt', 'ChatqReplySavedAt', 'ChatqReplyJunkLog', 'ChatqReplySeen', 'ChatqReplyHandled', 'ChatqReplyPollSeam'
    $rtWas = @{}
    foreach ($rtN in $rtNames) { $rtWas[$rtN] = Get-Variable -Scope Script -Name $rtN -ValueOnly }
    $rtReceive = ${function:Receive-ChatqReply}
    try {
        foreach ($rtN in $rtNames) { Set-Variable -Scope Script -Name $rtN -Value $null }
        foreach ($rtN in 'ChatqReplyJunkLog', 'ChatqReplySeen', 'ChatqReplyHandled') { Set-Variable -Scope Script -Name $rtN -Value @{} }
        Set-Item -Path 'function:script:Receive-ChatqReply' -Value { throw 'NV-NO-RECEIVE' }
        & $RtBlock
    }
    finally {
        foreach ($rtN in $rtNames) { Set-Variable -Scope Script -Name $rtN -Value $rtWas[$rtN] }
        Set-Item -Path 'function:script:Receive-ChatqReply' -Value $rtReceive
    }
}

function Get-NvReplyTriageLines([string]$Name) {
    # data/logs/$Name line by line, stamps still on
    $p = Join-Path $script:ChatqLogDir $Name
    if (-not (Test-Path -LiteralPath $p)) { return , @() }
    $t = [IO.File]::ReadAllText($p, $script:NvUtf8)
    if (-not $t.EndsWith("`n")) { throw "data/logs/$Name does not end in a line feed" }
    return , @($t.Substring(0, $t.Length - 1) -split "`n")
}

function Get-NvReplyTriageAdded($Before, $After) {
    # the lines $After has past $Before's, each without its stamp, which must
    # be the clock's (Add-ChatqLogLine)
    $stamp = (Get-Date).ToString('o') + '  '
    $out = New-Object System.Collections.Generic.List[string]
    for ($i = @($Before).Count; $i -lt @($After).Count; $i++) {
        $l = [string]@($After)[$i]
        if (-not $l.StartsWith($stamp, [StringComparison]::Ordinal)) { throw "a log line not stamped ($stamp): $l" }
        $out.Add($l.Substring($stamp.Length))
    }
    return , $out.ToArray()
}

function Invoke-NvReplyTriagePoll($Lines, $Fail) {
    # one Invoke-ChatqReplyPoll -Force inside Use-NvReplyTriageCaches: its feed
    # $Lines joined by line feeds, or a fetch failing with the text $Fail.
    # @{ Acted; Log }: what it returned, and the lines it put in replies.log
    $rtText = @($Lines) -join "`n"
    $rtFail = $Fail
    $rtLog = Get-NvReplyTriageLines 'replies.log'
    $rtWatch = Get-NvReplyTriageLines 'watcher.log'
    if ($null -ne $rtFail) { $script:ChatqReplyPollSeam = { param($Url) throw $rtFail }.GetNewClosure() }
    else { $script:ChatqReplyPollSeam = { param($Url) $rtText }.GetNewClosure() }
    $rtActed = @(Invoke-ChatqReplyPoll -Force)
    if ($rtActed.Count -ne 1 -or $rtActed[0] -isnot [int]) { throw "Invoke-ChatqReplyPoll answered $($rtActed.Count) values, not one [int]" }
    $rtLog = Get-NvReplyTriageAdded $rtLog (Get-NvReplyTriageLines 'replies.log')
    $rtWatch = Get-NvReplyTriageAdded $rtWatch (Get-NvReplyTriageLines 'watcher.log')
    # Write-ChatqReplyLog: every line goes to watcher.log too, after "phone: "
    $rtWant = @(foreach ($l in $rtLog) { "phone: $l" })
    if (($rtWant -join "`n") -cne (@($rtWatch) -join "`n")) { throw "watcher.log got $(ConvertTo-NvJson $rtWatch -Compress), not $(ConvertTo-NvJson $rtWant -Compress)" }
    foreach ($l in $rtLog) { if ($l.Contains('NV-NO-RECEIVE')) { throw "a message reached Receive-ChatqReply: $l" } }
    $rtCut = @(foreach ($l in $rtLog) { $l -creplace '(could not be read: ).*$', '$1...' })
    return @{ Acted = [int]$rtActed[0]; Log = $rtCut }
}

function Get-NvReplyTriageStep($P) {
    # one poll as the vector holds it: what it returned and logged, the
    # caches it left, and where replies.json says polling got to
    $utc = { param($d) if ($null -eq $d) { $null } else { ([datetime]$d).ToUniversalTime().ToString('o') } }
    $junk = [ordered]@{}
    $ks = [string[]]@($script:ChatqReplyJunkLog.Keys)
    [Array]::Sort($ks, [StringComparer]::Ordinal)
    foreach ($k in $ks) {
        $e = $script:ChatqReplyJunkLog[$k]
        $junk[$k] = [ordered]@{ at = (& $utc $e['At']); count = [int]$e['Count'] }
    }
    $hs = [string[]]@($script:ChatqReplyHandled.Keys)
    [Array]::Sort($hs, [StringComparer]::Ordinal)
    $st = $null
    if (Test-Path -LiteralPath $script:ChatqReplyPath) { $st = Read-NvJson ([IO.File]::ReadAllText($script:ChatqReplyPath, $script:NvUtf8)) }
    return [ordered]@{
        acted = $P.Acted; log = $P.Log; junk = $junk
        polledAt = (& $utc $script:ChatqReplyPolledAt); errAt = (& $utc $script:ChatqReplyErrAt)
        badIdAt = (& $utc $script:ChatqReplyBadIdAt); savedAt = (& $utc $script:ChatqReplySavedAt)
        handled = $hs
        lastId = $(if ($st) { $st.lastId } else { $null }); lastPolledAt = $(if ($st) { $st.lastPolledAt } else { $null })
    }
}

function Invoke-NvReplyTriageMessage($Case) {
    # one message under its config, at a fixed time in UTC and en-US
    return (Use-NvTimeZone 'UTC' {
            Use-NvClock '2026-10-15T00:00:00Z' {
                Use-NvCulture 'en-US' {
                    Use-NvReplyTriageCaches {
                        $rtRc = Get-ChatqReplyConfig
                        $rtKey = Get-ChatqPairKey $rtRc
                        Confirm-NvReplyTriageRc $rtRc $rtKey $Case.rc
                        $rtMsg = [string]$Case.message
                        $rtOut = Get-NvReplyTriageVerdict (Test-ChatqReplyMessage $rtRc $rtMsg $rtKey)
                        $rtNative = Get-NvReplyTriageNative $rtRc $rtMsg $rtKey
                        if ((ConvertTo-NvJson $rtNative -Compress) -cne (ConvertTo-NvJson $rtOut -Compress)) { $rtOut['native'] = $rtNative }
                        $rtOut['log'] = $null
                        # replies off, a poll fetches nothing
                        if ($rtOut['junk'] -and $rtRc.On) {
                            $rtP = Invoke-NvReplyTriagePoll @(New-NvReplyTriageLine 'm1' $rtMsg) $null
                            if ($rtP.Acted -ne 0 -or @($rtP.Log).Count -ne 1) { throw "a poll of it alone acted on $($rtP.Acted) and logged $(ConvertTo-NvJson $rtP.Log -Compress)" }
                            $rtOut['log'] = @($rtP.Log)[0]
                        }
                        $rtOut
                    }
                }
            }
        })
}

function Invoke-NvReplyTriageSequence($Case) {
    # the case's polls in order, each at its time, in its zone and culture
    $rtSteps = @($Case.steps)
    return (Use-NvTimeZone ([string]$Case.zone) {
            Use-NvClock ([string]$rtSteps[0].at) {
                Use-NvCulture ([string]$Case.culture) {
                    Use-NvReplyTriageCaches {
                        $rtSep = [System.Globalization.CultureInfo]::CurrentCulture.DateTimeFormat.TimeSeparator
                        if ($rtSep -cne [string]$Case.timeSep) { throw "$($Case.culture)'s time separator is '$rtSep', not '$($Case.timeSep)'" }
                        $rtRc = Get-ChatqReplyConfig
                        Confirm-NvReplyTriageRc $rtRc (Get-ChatqPairKey $rtRc) $Case.rc
                        if (-not $rtRc.On) { throw 'replies are not on under this config' }
                        $rtOut = New-Object System.Collections.Generic.List[object]
                        foreach ($rtS in $rtSteps) {
                            Set-NvClock ([string]$rtS.at)
                            $rtOff = [int][System.TimeZoneInfo]::Local.GetUtcOffset((Get-Date)).TotalMinutes
                            if ($rtOff -ne [int]$Case.utcOffsetMinutes) { throw "$($Case.zone) is $rtOff minutes from UTC at $($rtS.at), not $($Case.utcOffsetMinutes)" }
                            $rtP = if ($rtS.PSObject.Properties['fail']) { Invoke-NvReplyTriagePoll @() ([string]$rtS.fail) } else { Invoke-NvReplyTriagePoll @($rtS.lines) $null }
                            $rtOut.Add((Get-NvReplyTriageStep $rtP))
                        }
                        [ordered]@{ steps = $rtOut.ToArray() }
                    }
                }
            }
        })
}

Register-NvVector -Name 'reply-triage' -About 'The reply poll''s first look at what reaches the reply topic, which chatqd takes over (SPEC 3.7). A triage case is one message under a config, rc: the topic, the phone''s key D as hex, the pairing in progress (pairId) and whether its key opens here (pairKey; pairing says how config.json held it). Its answer is Test-ChatqReplyMessage''s verdict - junk with its stage and error, or a candidate of a kind (reply, compose, pair) - and log, the replies.log line a poll of that message alone (id m1) writes when it is junk and replies are on; watcher.log gets each such line after "phone: ". native, where there is one, is chatqd''s verdict where PowerShell''s differs: a pairing answer past the checks before RSA is a candidate, whatever RSA makes of it. A sequence case is Invoke-ChatqReplyPoll -Force over each step''s feed lines, or a fetch failing with fail, at the step''s time, in a zone of a fixed offset and a culture with that time separator: per step what it returned (acted), the lines it logged, the junk log per stage (when a line was last logged, how many went unlogged since), its throttle times, the topic|id tags it holds as handled, and lastId and lastPolledAt in replies.json. Times are UTC round-trip stamps; log stamps are cut off, and an RSA error''s text is cut to "could not be read: ...".' -Cases {
    $d1 = '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'
    $d2 = 'f0e1d2c3b4a5968778695a4b3c2d1e0f00112233445566778899aabbccddeeff'
    $key1 = ConvertTo-ChatqB64Url (ConvertFrom-NvHex $d1)
    $key2 = ConvertTo-ChatqB64Url (ConvertFrom-NvHex $d2)
    $iv = ConvertFrom-NvHex '101112131415161718191a1b1c1d1e1f'
    $pay = '{"v":1,"act":"prompt","text":"hi","nonce":"AAAAAAAAAAAAAAAAAAAAAA","ts":1790000000000}'
    $good = Protect-ChatqReplyMessage -Key $key1 -Aid 'abcdefghij' -Iv $iv -Payload $pay
    $gp = @($good -split '\.')
    $tampered = Set-NvReplyTriagePart $good 4 (Step-NvReplyTriageChar $gp[4] 10)
    $tampered2 = Set-NvReplyTriagePart $good 3 (Step-NvReplyTriageChar $gp[3] 10)
    $other = Protect-ChatqReplyMessage -Key $key2 -Aid 'abcdefghij' -Iv $iv -Payload $pay
    $compose = Protect-ChatqComposeMessage -Key $key1 -Cid 'klmnopqrst' -Payload '{"v":3,"act":"read","x":{"h":"k3m2qa"},"nonce":"AAAAAAAAAAAAAAAAAAAAAA","ts":1790000000000}' -Iv $iv
    $cp = @($compose -split '\.')
    $composeBad = Set-NvReplyTriagePart $compose 4 (Step-NvReplyTriageChar $cp[4] 10)
    $fx = Get-NvReplyTriageFixture
    $pair = [string]$fx.message
    $pp = @($pair -split '\.')
    $ctOf = { param($n) 'chatq2p.abcdefghij.' + (ConvertTo-ChatqB64Url ([byte[]](@([byte]1) * $n))) }
    # the fixture's key sealing {"v":1,...}, made once with Node's
    # publicEncrypt (RSA-OAEP-SHA256); OAEP is randomised, so it is kept as made
    $pairV1 = 'chatq2p.abcdefghij.Y10H6zrGLkffzcEuj3MFkfxKlYlSAhLqOOTpO4EydEiBTHUN0DMh_5Bv68FD47KFQwMsFFK4BrE4-l-PZFJTYkPUhR1E4IwAxVKVZuyMEJeJD7nelXXpGsHoQoLn6INP5ZAPcNbIAk_SCReCGf349G5MW8O8q-0-ykHMXdvKsZ0OemuxaN5N5i8ipV4GvW_eB8Yk15NQr8kYez30Lt5Xm-Og0V_G6U6f9fVUYRIwYr2vDU1Yzxr4joE3jTCwIEgDY1x_AHfPV1dC7Nrh5LMte0KWPc5co9rEcdp1ATngq2OcuH9-EX5mT_WUfcqx4mS6B_lvelM0NnuBmpV0FxZYaw'
    $ws = " `t`r`n"
    $bom = [string][char]0xFEFF
    $zwsp = [string][char]0x200B
    $nbsp = [string][char]0xA0

    # a config: the phone's key D (hex, or none) and the pairing; its key
    # opens here for 'fixture' and 'garbage' alike, both texts that read
    $rcOf = {
        param($Master, $Pairing)
        [ordered]@{
            topic = 'triage'; master = $Master; pairId = $(if ($Pairing -ceq 'none') { $null } else { 'abcdefghij' })
            pairKey = ($Pairing -ceq 'fixture' -or $Pairing -ceq 'garbage'); pairing = $Pairing
        }
    }
    $r0 = & $rcOf $d1 'none'
    $r1 = & $rcOf $d1 'fixture'
    $r2 = & $rcOf $d1 'unreadable'
    $r3 = & $rcOf $d1 'absent'
    $r4 = & $rcOf $d1 'garbage'
    $r5 = & $rcOf $null 'fixture'
    $r6 = & $rcOf $null 'none'
    $r7 = & $rcOf ($d1.Substring(0, 62)) 'fixture'
    $rC = & $rcOf $null 'unreadable'
    $T = { param($Tag, $Rc, $What, $Msg) [ordered]@{ name = "triage ${Tag}: $What"; input = [ordered]@{ rc = $Rc; message = $Msg } } }

    # paired, no pairing in progress
    & $T 'paired' $r0 'a good chatq1 reply' $good
    & $T 'paired' $r0 'chatq1, one MAC character changed' $tampered
    & $T 'paired' $r0 'chatq1, one ciphertext character changed' $tampered2
    & $T 'paired' $r0 'chatq1, the MAC''s unused bits set: the same MAC' (Set-NvReplyTriagePart $good 4 (Step-NvReplyTriageChar $gp[4] -1))
    & $T 'paired' $r0 'chatq1, the MAC two characters short, len%4 = 1' (Set-NvReplyTriagePart $good 4 $gp[4].Substring(0, 41))
    & $T 'paired' $r0 'chatq1 sealed under another D' $other
    & $T 'paired' $r0 'chatq1, a MAC that checks out over a ciphertext that does not decrypt' (New-NvReplyTriageSealed (ConvertFrom-NvHex $d1) 'chatq-alert:' 'chatq1' 'abcdefghij' $iv (New-Object byte[] 32))
    & $T 'paired' $r0 'chatq1, a v4 payload: past the MAC' (Protect-ChatqReplyMessage -Key $key1 -Aid 'abcdefghij' -Iv $iv -Payload '{"v":4,"act":"prompt"}')
    & $T 'paired' $r0 'chatq1 with white space around' ($ws + $good + $ws)
    & $T 'paired' $r0 'chatq1, U+FEFF in front' ($bom + $good)
    & $T 'paired' $r0 'chatq1, U+200B inside the prefix' (Set-NvReplyTriagePart $good 0 ('chat' + $zwsp + 'q1'))
    & $T 'paired' $r0 'chatq1, U+0661 for its 1' (Set-NvReplyTriagePart $good 0 ('chatq' + [char]0x0661))
    & $T 'paired' $r0 'chatq1, the id in capitals' (Set-NvReplyTriagePart $good 1 'ABCDEFGHIJ')
    & $T 'paired' $r0 'chatq1, four parts' (@($gp[0..3]) -join '.')
    & $T 'paired' $r0 'hello' 'hello'
    & $T 'paired' $r0 'empty' ''
    & $T 'paired' $r0 'a good chatq3c message' $compose
    & $T 'paired' $r0 'chatq3c, one MAC character changed' $composeBad
    & $T 'paired' $r0 'chatq3c. alone' 'chatq3c.'
    & $T 'paired' $r0 'chatq3c.x after a space' ' chatq3c.x'
    & $T 'paired' $r0 'chatq3c with no dot' 'chatq3c'
    & $T 'paired' $r0 'chatq3c in capitals' (Set-NvReplyTriagePart $compose 0 'CHATQ3C')
    & $T 'paired' $r0 'chatq3c, U+FEFF in front' ($bom + $compose)
    & $T 'paired' $r0 'chatq3c, U+00A0 in front' ($nbsp + $compose)
    & $T 'paired' $r0 'chatq3c, U+0663 for its 3: the dispatch is ordinal' (Set-NvReplyTriagePart $compose 0 ('chatq' + [char]0x0663 + 'c'))
    & $T 'paired' $r0 'chatq3c relabelled chatq1' (Set-NvReplyTriagePart $compose 0 'chatq1')
    & $T 'paired' $r0 'the pairing fixture' $pair
    & $T 'paired' $r0 'chatq2p.x' 'chatq2p.x'

    # paired, and a pairing in progress whose key opens here
    & $T 'pairing' $r1 'the pairing fixture' $pair
    & $T 'pairing' $r1 'a pairing answer whose payload is v1' $pairV1
    & $T 'pairing' $r1 'two parts' 'chatq2p.abcdefghij'
    & $T 'pairing' $r1 'four parts' ($pair + '.AAAA')
    & $T 'pairing' $r1 'the id in capitals' (Set-NvReplyTriagePart $pair 1 'ABCDEFGHIJ')
    & $T 'pairing' $r1 'another id' (Set-NvReplyTriagePart $pair 1 'bcdefghijk')
    & $T 'pairing' $r1 'a line feed after the id' (Set-NvReplyTriagePart $pair 1 "abcdefghij`n")
    & $T 'pairing' $r1 'a ciphertext of 3 bytes' 'chatq2p.abcdefghij.AAAA'
    & $T 'pairing' $r1 'a ciphertext of 63 bytes' (& $ctOf 63)
    & $T 'pairing' $r1 'a ciphertext of 64 bytes' (& $ctOf 64)
    & $T 'pairing' $r1 'a ciphertext of 1024 bytes' (& $ctOf 1024)
    & $T 'pairing' $r1 'a ciphertext of 1025 bytes' (& $ctOf 1025)
    & $T 'pairing' $r1 'a ciphertext a character short, len%4 = 1' (Set-NvReplyTriagePart $pair 2 $pp[2].Substring(0, $pp[2].Length - 1))
    & $T 'pairing' $r1 'the ciphertext''s unused bits set' (Set-NvReplyTriagePart $pair 2 (Step-NvReplyTriageChar $pp[2] -1))
    & $T 'pairing' $r1 'white space around' ($ws + $pair + $ws)
    & $T 'pairing' $r1 'U+FEFF in front' ($bom + $pair)
    & $T 'pairing' $r1 'a good chatq3c message' $compose
    & $T 'pairing' $r1 'a good chatq1 reply' $good

    # a pairing in progress whose key does not open here
    & $T 'unreadable' $r2 'the pairing fixture' $pair
    & $T 'unreadable' $r2 'chatq2p.x' 'chatq2p.x'
    & $T 'unreadable' $r2 'a good chatq1 reply' $good
    & $T 'no pairing key' $r3 'the pairing fixture' $pair
    & $T 'garbage key' $r4 'the pairing fixture' $pair

    # not paired yet: a pairing in progress, or nothing
    & $T 'unpaired' $r5 'the pairing fixture' $pair
    & $T 'unpaired' $r5 'a good chatq1 reply' $good
    & $T 'unpaired' $r5 'a good chatq3c message' $compose
    & $T 'unpaired' $r5 'chatq1, the MAC two characters short: the encoding before the key' (Set-NvReplyTriagePart $good 4 $gp[4].Substring(0, 41))
    & $T 'off' $r6 'a good chatq1 reply' $good
    & $T 'off' $r6 'the pairing fixture' $pair
    & $T 'short key' $r7 'a good chatq1 reply' $good
    & $T 'short key' $r7 'a good chatq3c message' $compose

    # whole polls
    $L = { param($Id, $Msg) New-NvReplyTriageLine $Id $Msg }
    $id40 = 'abcdefghij' * 4
    [ordered]@{
        name = 'sequence: junk floods, throttles and saves, en-US in Korea'
        input = [ordered]@{
            zone = 'Korea Standard Time'; utcOffsetMinutes = 540; culture = 'en-US'; timeSep = ':'; rc = $r0
            steps = @(
                [ordered]@{ at = '2026-10-15T00:00:00Z'; lines = @(
                        '{"id":"o1","time":1790000000,"event":"open","topic":"triage"}'
                        '{"id":"k1","time":1790000001,"event":"keepalive","topic":"triage"}'
                        (& $L 'm1' $tampered)
                        (& $L 'm2' 'hello')
                        (& $L 'm3' $tampered2)
                        'not json'
                        ''
                        '   '
                    )
                }
                [ordered]@{ at = '2026-10-15T00:02:00Z'; lines = @((& $L 'm4' $tampered), (& $L 'm5' ''), (& $L 'm1' $tampered)) }
                [ordered]@{ at = '2026-10-15T00:04:00Z'; lines = @() }
                [ordered]@{ at = '2026-10-15T00:04:59.9999999Z'; lines = @(& $L 'm6' $tampered) }
                [ordered]@{ at = '2026-10-15T00:05:00Z'; lines = @(& $L 'm7' $tampered) }
                [ordered]@{ at = '2026-10-15T00:07:00Z'; lines = @(& $L 'm8' '') }
                [ordered]@{ at = '2026-10-15T00:07:01Z'; lines = @((& $L 'bad id!' 'hello'), (& $L 'M7' $tampered)) }
                [ordered]@{ at = '2026-10-15T00:16:01Z'; lines = @(& $L 'bad id!' 'hello') }
                [ordered]@{ at = '2026-10-15T00:17:01Z'; lines = @(& $L 'bad id!' 'hello') }
                [ordered]@{ at = '2026-10-15T00:18:00Z'; fail = "boom`r`nsecond line`n`nthird" }
                [ordered]@{ at = '2026-10-15T00:27:59Z'; fail = 'boom' }
                [ordered]@{ at = '2026-10-15T00:28:00Z'; fail = 'boom again' }
                [ordered]@{ at = '2026-10-15T00:29:00Z'; lines = @(
                        '{"id":"abc\n","event":"message","message":"x"}'
                        ('{"id":12345,"event":"message","message":"' + $tampered + '"}')
                        '{"id":true,"event":"MESSAGE","message":"hello"}'
                        '{"id":false,"event":"message","message":"hello"}'
                        '{"id":0,"event":"message","message":"hello"}'
                        '{"id":["ab"],"event":"message","message":"hello"}'
                        '{"event":"message","message":"hello"}'
                        '{"id":{"x":1},"event":"message","message":"hello"}'
                        '{"id":["a","b"],"event":"message","message":"hello"}'
                        '{"id":"a.b","event":"message","message":"hello"}'
                        '{"id":"","event":"message","message":"hello"}'
                        '{"id":null,"event":"message","message":"hello"}'
                        '{"id":-5,"event":"message","message":"hello"}'
                        '{"id":1.5,"event":"message","message":"hello"}'
                        ('{"id":"' + $id40 + '","event":"message"}')
                        ('{"id":"' + $id40 + 'k","event":"message","message":"hello"}')
                        '{"id":"n1","event":"message","message":5}'
                        '{"id":"n2","event":"message","message":true}'
                        '{"id":"n3","event":"message","message":["chatq3c.x","y"]}'
                        '{"id":"n4","event":"message","message":"chatq2p.abcdefghij.AAAA"}'
                        '{"id":"n5","event":"message","message":"chatq3c.zz"}'
                    )
                }
                [ordered]@{ at = '2026-10-15T00:29:30Z'; lines = @(
                        '{"id":"e1","event":"MESSAGE","message":"hello"}'
                        '{"id":"e2","event":"Message","message":"hello"}'
                        '{"id":"e3","Event":"message","message":"hello"}'
                        '{"id":"e4","event":true,"message":"hello"}'
                        '{"id":"e5","event":[],"message":"hello"}'
                        '{"id":"e6","event":["message"],"message":"hello"}'
                        '{"id":"e7","event":[""],"message":"hello"}'
                        '{"id":"e8","event":[null],"message":"hello"}'
                        '{"id":"e9","event":[0],"message":"hello"}'
                        '{"id":"e10","event":[false],"message":"hello"}'
                        '{"id":"e11","event":[true],"message":"hello"}'
                        '{"id":"e12","event":[[]],"message":"hello"}'
                        '{"id":"e13","event":["MESSAGE"],"message":"hello"}'
                        '{"id":"e14","event":null,"message":"hello"}'
                        '{"id":"e15","event":false,"message":"hello"}'
                        '{"id":"e16","event":0,"message":"hello"}'
                        '{"id":"e17","event":1,"message":"hello"}'
                        '{"id":"e18","event":{},"message":"hello"}'
                        '{"id":"e19","event":{"a":1},"message":"hello"}'
                        '{"id":"e20","event":"message ","message":"hello"}'
                        '{"id":"e21","event":" message","message":"hello"}'
                        '{"id":"e22","event":["message","x"],"message":"hello"}'
                        '{"id":"e23","event":["x"],"message":"hello"}'
                        '{"id":"e24","message":"hello"}'
                        '{"id":"e25","event":"open","message":"hello"}'
                        '"message"'
                        '5'
                        'null'
                        ((& $L 'e26' 'hello') + "`r")
                        ('  ' + (& $L 'e27' 'hello') + "`t")
                    )
                }
                [ordered]@{ at = '2026-10-15T00:40:00Z'; lines = @() }
                [ordered]@{ at = '2026-10-15T00:45:00Z'; lines = @(& $L 'z1' 'hello') }
            )
        }
    }
    [ordered]@{
        name = 'sequence: pairing junk, fi-FI in India'
        input = [ordered]@{
            zone = 'India Standard Time'; utcOffsetMinutes = 330; culture = 'fi-FI'; timeSep = '.'; rc = $r1
            steps = @(
                [ordered]@{ at = '2026-10-15T03:00:00Z'; lines = @(
                        (& $L 'p1' 'chatq2p.abcdefghij')
                        (& $L 'p2' (Set-NvReplyTriagePart $pair 1 'bcdefghijk'))
                        (& $L 'p3' 'chatq2p.abcdefghij.AAAA')
                        (& $L 'c1' $composeBad)
                        (& $L 'r1' $other)
                    )
                }
                [ordered]@{ at = '2026-10-15T03:06:00Z'; lines = @((& $L 'p4' (Set-NvReplyTriagePart $pair 1 "abcdefghij`n")), (& $L 'r2' $tampered)) }
                [ordered]@{ at = '2026-10-15T03:06:30Z'; lines = @((& $L 'p5' (& $ctOf 63)), (& $L 'p6' (& $ctOf 1025))) }
                [ordered]@{ at = '2026-10-15T03:12:00Z'; lines = @(& $L 'p7' 'chatq2p.x') }
            )
        }
    }
    # Greenwich, not UTC: on pwsh 7, Use-NvTimeZone 'UTC' makes the local
    # zone TimeZoneInfo.Utc itself, whose ToUniversalTime keeps a time Local,
    # and its 'o' stamps would end +00:00
    [ordered]@{
        name = 'sequence: no key, a pairing key that does not open, ko-KR at UTC+0 over midnight'
        input = [ordered]@{
            zone = 'Greenwich Standard Time'; utcOffsetMinutes = 0; culture = 'ko-KR'; timeSep = ':'; rc = $rC
            steps = @(
                [ordered]@{ at = '2026-10-15T23:58:00Z'; lines = @((& $L 'q1' $pair), (& $L 'q2' 'chatq2p.x'), (& $L 'q3' $good), (& $L 'q4' $compose)) }
                [ordered]@{ at = '2026-10-16T00:03:00Z'; lines = @((& $L 'q5' $pair), (& $L 'q6' 'hello')) }
            )
        }
    }
} -Expect {
    param($In, $Name)
    # data/ named by a hash of the case's name: the names are long, and a
    # path past 260 characters would fail on 5.1, where Open-ChatqLock's
    # retries wait on a clock that is not moving
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $h = $sha.ComputeHash($script:NvUtf8.GetBytes($Name)) } finally { $sha.Dispose() }
    $null = Enter-NvData ('triage-' + (ConvertTo-NvReplyTriageHex $h).Substring(0, 12))
    Set-NvReplyTriageConfig $In.rc
    if ($In.PSObject.Properties['steps']) { return (Invoke-NvReplyTriageSequence $In) }
    return (Invoke-NvReplyTriageMessage $In)
}
