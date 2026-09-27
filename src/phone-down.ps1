# VS-code-chat-manager, src/phone-down.ps1: dot-sourced by VS-code-chat-manager.ps1
# in its turn, never on its own - see the list there.

#region phone: the PC -> phone channel -------------------------------------------
# Until 0.9.0 nothing went from the PC to the phone but a push, and a push is
# no place for a whole answer, a list of chats or the queue: Join's push is a
# GET its servers log, and 1,900 characters at most. So the PC also posts to a
# second ntfy.sh topic of its own - the down topic - sealed the way the phone
# seals its replies, and the page fetches from it (docs/phone-board-spec.md):
#   a whole answer   with a done, needs input or failed alert (kind reply)
#   a list, a board  what the phone asked for from a bookmark (kind list, board)
#   an ack           the PC's answer to anything else the phone asked (kind ack)
# The down topic is worked out from the phone's key D every time and is in no
# push, link or file, so nobody else knows where to read or post. Knowing it
# proves nothing all the same: every message on it is sealed and MACed.
#   downTopic = "chatq-" + 24 of [a-z2-7]: byte i of HMAC(D, "chatq-down-topic") mod 32
#   k_down    = HMAC(D, "chatq-down:" + did)      PC -> phone
#   k_phone   = HMAC(D, "chatq-phone:" + cid)     phone -> PC, not about an alert
#   enc = HMAC(k, "enc"), mac = HMAC(k, "mac")    as for every other k
#   head      = "chatq3d." + did + "." + b64url(iv) + "." + b64url(AES-CBC(enc, iv, deflateRaw(json)))
#   message   = head + "." + b64url(HMAC(mac, head))
# and "chatq3c." + cid for the phone's, its JSON not deflated. Each label is
# its own, so a message sealed one way never opens another way: one of these
# posted back to the reply topic fails the watcher's MAC, and the reverse.
#
# Deflate before the cipher: most answers then fit inline, which ntfy.sh
# keeps 12 hours, where an attachment lasts 3. It tells ntfy.sh the
# compressed length, which it sees to 16 bytes either way, and nothing an
# attacker chooses is mixed with a secret in a message they can make again.

# a whole answer's sealed text inline up to this many characters; past it, an
# attachment. ntfy's message body is 4,096 bytes and a longer one turns into
# an attachment by itself, so there is room left for its own framing
$script:ChatqDownInline = 3900
# ntfy.sh takes a 2 MB attachment from an address without an account
$script:ChatqDownAttachMax = 1900000
# when a send to the down topic last failed, for one log line per 10 minutes
$script:ChatqDownErrAt = $null

function Get-ChatqDownTopic {
    # the down topic of the phone's key D, or $null with no key
    param([byte[]]$Master)
    if ($null -eq $Master -or $Master.Length -ne 32) { return $null }
    $h = Get-ChatqHmac $Master ((New-Object System.Text.UTF8Encoding $false).GetBytes('chatq-down-topic'))
    $abc = 'abcdefghijklmnopqrstuvwxyz234567'
    return 'chatq-' + (-join @(for ($i = 0; $i -lt 24; $i++) { $abc[$h[$i] % 32] }))
}

function Get-ChatqLabelKeys {
    # One message's keys under a label of its own: k from the phone's key D,
    # the label and the message's id, then enc and mac from k, as
    # Get-ChatqReplyKeys does for an alert's
    param([byte[]]$Master, [string]$Label, [string]$Id)
    $u = New-Object System.Text.UTF8Encoding $false
    $k = Get-ChatqHmac $Master ($u.GetBytes($Label + $Id))
    return (Get-ChatqReplyKeys -K $k)
}

function Compress-ChatqBytes {
    # raw deflate, RFC 1951 with no header: what the page's
    # DecompressionStream('deflate-raw') reads
    param([byte[]]$Bytes)
    $ms = [System.IO.MemoryStream]::new()
    $z = [System.IO.Compression.DeflateStream]::new($ms, [System.IO.Compression.CompressionLevel]::Optimal, $true)
    try { if ($Bytes.Length) { $z.Write($Bytes, 0, $Bytes.Length) } }
    finally { $z.Dispose() }
    return , $ms.ToArray()
}

function Expand-ChatqBytes {
    # Raw deflate opened, or $null: bytes that are not raw deflate, or that
    # would come to more than -MaxBytes - a few kilobytes can inflate to
    # gigabytes, so the output is counted as it comes
    param([byte[]]$Bytes, [int]$MaxBytes = 4MB)
    try {
        $in = [System.IO.MemoryStream]::new($Bytes)
        $z = [System.IO.Compression.DeflateStream]::new($in, [System.IO.Compression.CompressionMode]::Decompress)
        $out = [System.IO.MemoryStream]::new()
        $buf = New-Object byte[] 65536
        try {
            while ($true) {
                $n = $z.Read($buf, 0, $buf.Length)
                if ($n -le 0) { break }
                if ($out.Length + $n -gt $MaxBytes) { return $null }
                $out.Write($buf, 0, $n)
            }
        }
        finally { $z.Dispose() }
        return , $out.ToArray()
    }
    catch { return $null }
}

function Protect-ChatqDownMessage {
    <#
    Seal a PC -> phone message: -Payload is the JSON, raw-deflated and then
    sealed under k_down of -Did. -Master is the phone's key D (or -Key, as
    base64url). -Iv and -Deflated fix what is otherwise random or made here -
    the test vector's bytes come from Node's zlib, and deflaters differ.
    #>
    param([byte[]]$Master, [string]$Key, [string]$Did, [string]$Payload, [byte[]]$Iv, [byte[]]$Deflated)
    $u = New-Object System.Text.UTF8Encoding $false
    if (-not $Master -and $Key) { $Master = ConvertFrom-ChatqB64Url $Key }
    if ($null -eq $Master -or $Master.Length -ne 32) { throw 'the phone''s key must be 32 bytes' }
    if ($Did -cnotmatch '^[a-z2-7]{10}$') { throw 'a message id is 10 of [a-z2-7]' }
    $ks = Get-ChatqLabelKeys $Master 'chatq-down:' $Did
    [byte[]]$z = if ($Deflated) { $Deflated } else { Compress-ChatqBytes ($u.GetBytes($Payload)) }
    if (-not $Iv) { $Iv = New-ChatqRandomBytes 16 }
    $ct = Invoke-ChatqAes $ks.Enc $Iv $z -Encrypt
    $head = 'chatq3d.' + $Did + '.' + (ConvertTo-ChatqB64Url $Iv) + '.' + (ConvertTo-ChatqB64Url $ct)
    return $head + '.' + (ConvertTo-ChatqB64Url (Get-ChatqHmac $ks.Mac ($u.GetBytes($head))))
}

function Unprotect-ChatqDownMessage {
    <#
    Open a PC -> phone message as the page does, for the tests: the parts,
    the prefix and -Did, the MAC in constant time, then decrypt, inflate
    (-MaxBytes at most) and the JSON, whose v is 3 and ref its did. Returns
    @{ Ok; Stage; Error; Did; Payload; Json }, never a throw.
    #>
    param([string]$Message, [byte[]]$Master, [string]$Did, [int]$MaxBytes = 4MB)
    $r = [pscustomobject]@{ Ok = $false; Stage = 'format'; Error = $null; Did = $null; Payload = $null; Json = $null }
    $p = @(([string]$Message).Trim() -split '\.')
    if ($p.Count -ne 5 -or $p[0] -cne 'chatq3d' -or $p[1] -cnotmatch '^[a-z2-7]{10}$') { $r.Error = 'not a chatq down message'; return $r }
    if ($Did -and $p[1] -cne $Did) { $r.Error = 'for another request'; return $r }
    $iv = ConvertFrom-ChatqB64Url $p[2]
    $ct = ConvertFrom-ChatqB64Url $p[3]
    $mac = ConvertFrom-ChatqB64Url $p[4]
    if ($null -eq $iv -or $iv.Length -ne 16 -or $null -eq $ct -or $ct.Length -eq 0 -or ($ct.Length % 16) -or $null -eq $mac -or $mac.Length -ne 32) { $r.Error = 'bad encoding'; return $r }
    if ($null -eq $Master -or $Master.Length -ne 32) { $r.Error = 'no phone paired'; return $r }
    $r.Did = $p[1]
    $r.Stage = 'mac'
    $u = New-Object System.Text.UTF8Encoding $false
    $ks = Get-ChatqLabelKeys $Master 'chatq-down:' $p[1]
    if (-not (Test-ChatqSameBytes (Get-ChatqHmac $ks.Mac ($u.GetBytes(($p[0..3] -join '.')))) $mac)) { $r.Error = 'the MAC does not match'; return $r }
    $r.Stage = 'decrypt'
    $z = $null
    try { $z = Invoke-ChatqAes $ks.Enc $iv $ct } catch { $r.Error = "could not be decrypted: $($_.Exception.Message)"; return $r }
    $r.Stage = 'inflate'
    $plain = Expand-ChatqBytes $z $MaxBytes
    if ($null -eq $plain) { $r.Error = 'not raw deflate, or over the size allowed'; return $r }
    $r.Stage = 'json'
    try {
        $r.Json = (New-Object System.Text.UTF8Encoding $false, $true).GetString($plain)
        $o = $r.Json | ConvertFrom-Json
    }
    catch { $r.Error = "could not be read: $($_.Exception.Message)"; return $r }
    if (-not $o -or [string]$o.v -ne '3' -or [string]$o.ref -cne $p[1]) { $r.Error = 'not a version 3 message for this id'; return $r }
    $r.Payload = $o
    $r.Ok = $true
    $r.Stage = 'ok'
    return $r
}

function Protect-ChatqComposeMessage {
    <#
    Seal a phone -> PC message that is about no alert ("chatq3c.") as the
    page does. The page is what sends them; this is for the tests. -Key is
    the phone's key D as base64url, -Cid the message's id, -Payload the JSON
    sealed exactly as given.
    #>
    param([string]$Key, [string]$Cid, [string]$Payload, [byte[]]$Iv)
    $u = New-Object System.Text.UTF8Encoding $false
    $master = ConvertFrom-ChatqB64Url $Key
    if ($null -eq $master -or $master.Length -ne 32) { throw 'the reply key must be 32 bytes, base64url' }
    if (-not $Cid) { $Cid = New-ChatqRandomName 10 }
    $ks = Get-ChatqLabelKeys $master 'chatq-phone:' $Cid
    if (-not $Iv) { $Iv = New-ChatqRandomBytes 16 }
    $ct = Invoke-ChatqAes $ks.Enc $Iv ($u.GetBytes($Payload)) -Encrypt
    $head = 'chatq3c.' + $Cid + '.' + (ConvertTo-ChatqB64Url $Iv) + '.' + (ConvertTo-ChatqB64Url $ct)
    return $head + '.' + (ConvertTo-ChatqB64Url (Get-ChatqHmac $ks.Mac ($u.GetBytes($head))))
}

function Unprotect-ChatqComposeMessage {
    <#
    Open a phone -> PC message about no alert with the phone's key as it is
    now. The stages and the constant-time MAC of Unprotect-ChatqReplyMessage:
    nothing is decrypted before the MAC checks out. The payload's v must be
    3. Returns @{ Ok; Stage; Error; Cid; Payload }.
    #>
    param([string]$Message, [byte[]]$Master)
    $r = [pscustomobject]@{ Ok = $false; Stage = 'format'; Error = $null; Cid = $null; Payload = $null }
    $p = @(([string]$Message).Trim() -split '\.')
    if ($p.Count -ne 5 -or $p[0] -cne 'chatq3c' -or $p[1] -cnotmatch '^[a-z2-7]{10}$') { $r.Error = 'not a chatq message from the phone'; return $r }
    $iv = ConvertFrom-ChatqB64Url $p[2]
    $ct = ConvertFrom-ChatqB64Url $p[3]
    $mac = ConvertFrom-ChatqB64Url $p[4]
    if ($null -eq $iv -or $iv.Length -ne 16 -or $null -eq $ct -or $ct.Length -eq 0 -or ($ct.Length % 16) -or $null -eq $mac -or $mac.Length -ne 32) { $r.Error = 'bad encoding'; return $r }
    if ($null -eq $Master -or $Master.Length -ne 32) { $r.Error = 'no phone paired'; return $r }
    $r.Cid = $p[1]
    $r.Stage = 'mac'
    $u = New-Object System.Text.UTF8Encoding $false
    $ks = Get-ChatqLabelKeys $Master 'chatq-phone:' $p[1]
    if (-not (Test-ChatqSameBytes (Get-ChatqHmac $ks.Mac ($u.GetBytes(($p[0..3] -join '.')))) $mac)) { $r.Error = 'the MAC does not match'; return $r }
    $r.Stage = 'decrypt'
    try {
        $pt = Invoke-ChatqAes $ks.Enc $iv $ct
        $o = (New-Object System.Text.UTF8Encoding $false, $true).GetString($pt) | ConvertFrom-Json
    }
    catch { $r.Error = "could not be read: $($_.Exception.Message)"; return $r }
    if (-not $o -or [string]$o.v -ne '3' -or -not $o.act) { $r.Error = 'not a version 3 payload'; return $r }
    $r.Payload = $o
    $r.Ok = $true
    $r.Stage = 'ok'
    return $r
}

function Invoke-ChatqDownRequest {
    # One request to the down topic: $null when it went, else what went
    # wrong. $script:ChatqDownSeam (tests) gets it in place of the network.
    param([string]$Method, [string]$Url, $Headers, [string]$Body)
    if ($script:ChatqDownSeam) { return (& $script:ChatqDownSeam $Method $Url $Headers $Body) }   # tests
    try {
        Enable-ChatqTls12
        $hd = @{}
        foreach ($k in @($Headers.Keys)) { $hd[[string]$k] = [string]$Headers[$k] }
        $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($Body)
        $null = Invoke-WebRequest -Uri $Url -Method $Method -Body $bytes -ContentType 'text/plain' -Headers $hd -TimeoutSec 8 -UseBasicParsing
        return $null
    }
    catch { return [string]$_.Exception.Message }
}

function Write-ChatqDownError {
    # a failed send, in replies.log: one line per 10 minutes, as a failed poll
    param([string]$Text)
    if ($script:ChatqDownErrAt -and ((Get-Date) - $script:ChatqDownErrAt).TotalMinutes -lt 10) { return }
    $script:ChatqDownErrAt = Get-Date
    Write-ChatqReplyLog "down: $Text"
}

function Select-ChatqPartsTail {
    <#
    The end of a turn in -Max characters: parts dropped from the front, the
    first one kept cut to what is left - never between the two halves of a
    surrogate pair. The conclusion is at the end, so that is what stays.
    @{ Parts; Cut }, Cut the characters left out.
    #>
    param([object[]]$Parts, [int]$Max)
    $total = 0
    foreach ($p in @($Parts)) { $total += ([string]$p.s).Length }
    if ($total -le $Max) { return [pscustomobject]@{ Parts = @($Parts); Cut = 0 } }
    $keep = [System.Collections.Generic.List[object]]::new()
    $room = [Math]::Max(0, $Max)
    for ($i = @($Parts).Count - 1; $i -ge 0 -and $room -gt 0; $i--) {
        $s = [string]$Parts[$i].s
        if ($s.Length -le $room) { $keep.Insert(0, $Parts[$i]); $room -= $s.Length; continue }
        $from = $s.Length - $room
        if ($from -lt $s.Length -and [char]::IsLowSurrogate($s[$from])) { $from++ }
        if ($from -lt $s.Length) { $keep.Insert(0, [ordered]@{ t = [string]$Parts[$i].t; s = $s.Substring($from) }) }
        $room = 0
    }
    $kept = 0
    foreach ($p in $keep) { $kept += ([string]$p.s).Length }
    return [pscustomobject]@{ Parts = $keep.ToArray(); Cut = $total - $kept }
}

function Send-ChatqDown {
    <#
    One message to the down topic: -Body (an ordered hashtable, v first) as
    JSON, sealed for -Did (Protect-ChatqDownMessage). Up to 3,900 sealed
    characters it goes inline - a POST, text/plain - kept by ntfy.sh 12
    hours. Longer, as one attachment - a PUT with X-Filename - kept 3 hours
    and 2 MB at most for an address with no account: one message whatever
    its size, where chunks would spend the 250 a day the alerts share. Over
    that, or a server that refuses the PUT (a self-hosted ntfy without
    attachments answers 400 or 413), a whole answer's parts are cut from the
    front until it fits inline, and its cut says how much. Every one carries
    X-Title <did>, so the page asks for exactly its own; X-Firebase no, so
    ntfy.sh hands nothing to Google; priority 1. One try, 8 s: it goes ahead
    of the push, which must not wait on it. Returns @{ Ok; Error; Bytes;
    Attached; Cut }, never a throw; failures go to replies.log.
    #>
    param($Rc, [string]$Did, $Body, [switch]$Quick)
    $out = [pscustomobject]@{ Ok = $false; Error = $null; Bytes = 0; Attached = $false; Cut = 0 }
    try {
        $topic = Get-ChatqDownTopic $Rc.Master
        if (-not $topic) { $out.Error = 'no phone paired'; return $out }
        $url = "$($Rc.Server)/$topic"
        $seal = { param($b) Protect-ChatqDownMessage -Master $Rc.Master -Did $Did -Payload ($b | ConvertTo-Json -Compress -Depth 8) }
        $sealed = & $seal $Body
        $h = [ordered]@{ 'X-Title' = $Did; 'X-Firebase' = 'no'; 'X-Cache' = 'yes'; 'X-Priority' = '1' }
        if ($sealed.Length -gt $script:ChatqDownInline -and $sealed.Length -le $script:ChatqDownAttachMax) {
            $ph = [ordered]@{}
            foreach ($k in $h.Keys) { $ph[$k] = $h[$k] }
            $ph['X-Filename'] = "$Did.txt"
            $ph['X-Message'] = 'chatq'
            $err = Invoke-ChatqDownRequest 'PUT' $url $ph $sealed
            if (-not $err) { $out.Ok = $true; $out.Attached = $true; $out.Bytes = $sealed.Length; return $out }
            Write-ChatqDownError "an attachment for $Did was refused ($err) - cut to go inline"
        }
        if ($sealed.Length -gt $script:ChatqDownInline) {
            # only a whole answer can be cut: its parts, from the front
            $parts = if ($Body -is [System.Collections.IDictionary] -and $Body.Contains('parts')) { @($Body['parts']) } else { @() }
            if (-not $parts.Count) { $out.Error = "$($sealed.Length) characters sealed, too long to go inline"; Write-ChatqDownError $out.Error; return $out }
            $total = 0
            foreach ($p in $parts) { $total += ([string]$p.s).Length }
            $cut0 = [int]$Body['cut']
            $max = $total
            while ($sealed.Length -gt $script:ChatqDownInline -and $max -gt 0) {
                $max = [int]($max * 0.75)
                $sel = Select-ChatqPartsTail $parts $max
                $Body['parts'] = @($sel.Parts)
                $Body['cut'] = $cut0 + $sel.Cut
                $out.Cut = $sel.Cut
                $sealed = & $seal $Body
            }
        }
        $err = Invoke-ChatqDownRequest 'POST' $url $h $sealed
        if ($err) { $out.Error = $err; Write-ChatqDownError "$Did not sent - $err"; return $out }
        $out.Ok = $true
        $out.Bytes = $sealed.Length
        return $out
    }
    catch {
        $out.Error = $_.Exception.Message
        Write-ChatqDownError "$Did not sent - $($out.Error)"
        return $out
    }
}

function Add-ChatqDownCount {
    <#
    The day's down messages, counted before one is sent - in a lock block of
    its own, never around the send. ntfy.sh gives an address with no account
    250 messages a day, and alerts through ntfy spend the same ones: whole
    answers stop at reply.downPerDay (150), and lists, boards and acks at 50
    more, which leaves the rest to the alerts. The day is the local date.
    $true when this one may go; $false too when replies.json cannot be saved.
    #>
    param($Rc, [ValidateSet('full', 'other')][string]$Kind)
    $downCap = if ($Rc -and [int]$Rc.DownPerDay -gt 0) { [int]$Rc.DownPerDay } else { 150 }
    $downKind = $Kind
    try {
        return [bool](Use-ChatqReplyState {
                param($st)
                $day = (Get-Date).ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
                if (-not $st.down -or [string]$st.down.day -ne $day) { $st.down = @{ day = $day; full = 0; other = 0 } }
                $f = [int]$st.down.full
                $o = [int]$st.down.other
                if ($downKind -eq 'full') {
                    if ($f -ge $downCap) { return $false }
                    $st.down.full = $f + 1
                }
                else {
                    if ($f + $o -ge $downCap + 50) { return $false }
                    $st.down.other = $o + 1
                }
                return $true
            } $Rc.Hours)
    }
    catch { return $false }
}

function Get-ChatqDownLeft {
    # how many lists, boards and acks today still has, for the board's
    # "few refreshes left today"
    param($Rc, $State)
    $cap = if ($Rc -and [int]$Rc.DownPerDay -gt 0) { [int]$Rc.DownPerDay } else { 150 }
    $day = (Get-Date).ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    $d = if ($State) { $State.down } else { $null }
    if (-not $d -or [string]$d.day -ne $day) { return $cap + 50 }
    return [Math]::Max(0, $cap + 50 - [int]$d.full - [int]$d.other)
}

function Test-ChatqRealPrompt {
    # A transcript line that is something typed: a user record, not a side
    # chat's, not Claude Code's own (isMeta), whose content is text - a
    # string, or blocks with text in them and no tool result
    param([string]$Line)
    if ($Line.IndexOf('"type":"user"', [StringComparison]::Ordinal) -lt 0) { return $false }
    if ($Line.IndexOf('"type":"tool_result"', [StringComparison]::Ordinal) -ge 0) { return $false }
    $o = try { $Line | ConvertFrom-Json } catch { $null }
    if (-not $o -or [string]$o.type -ne 'user' -or $o.isSidechain -eq $true -or $o.isMeta -eq $true -or -not $o.message) { return $false }
    $c = $o.message.content
    if ($c -is [string]) { return [bool]$c.Trim() }
    $blocks = @($c)
    if (@($blocks | Where-Object { $_ -and $_.type -eq 'tool_result' }).Count) { return $false }
    return [bool]@($blocks | Where-Object { $_ -and $_.type -eq 'text' -and $_.text }).Count
}

function Get-ChatqToolLine {
    # a tool call in a few words, as chatqlog shows it: its name and the
    # first line of what it ran, the file or the pattern
    param($Block)
    $in = $Block.input
    $arg = if ($in -and $in.command) { $in.command } elseif ($in -and $in.file_path) { $in.file_path } elseif ($in -and $in.pattern) { $in.pattern } else { '' }
    return ("$($Block.name) $(([string]$arg -split "`n")[0])").Trim()
}

function Get-ChatqTurnText {
    <#
    The last turn of a Claude transcript, for the phone: everything after the
    last real prompt (Test-ChatqRealPrompt) - Claude's text, one line per
    tool it used, and Claude Code's own <synthetic> records (a limit, a 529)
    as a note - in order. The tail is read, 4 MB and then 16 MB when the
    prompt is further back; a turn longer than that is the part that fits.
    Over -Max characters the front goes (Select-ChatqPartsTail). Returns
    @{ Parts; Cut; At } - parts @{ t = text|tool|note; s } - or $null.
    #>
    param([string]$Path, [int]$Max = 30000)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    $len = try { ([System.IO.FileInfo]::new($Path)).Length } catch { return $null }
    foreach ($size in 4MB, 16MB) {
        $t = Read-ChatqTail $Path $size
        if (-not $t) { return $null }
        $lines = $t -split "`n"
        # the first line of a tail is cut in two
        $start = if ($size -lt $len) { 1 } else { 0 }
        $from = -1
        for ($i = $lines.Count - 1; $i -ge $start; $i--) {
            if (Test-ChatqRealPrompt $lines[$i]) { $from = $i; break }
        }
        if ($from -lt 0 -and $size -lt $len) { continue }
        $parts = [System.Collections.Generic.List[object]]::new()
        $at = $null
        for ($i = [Math]::Max($from + 1, $start); $i -lt $lines.Count; $i++) {
            $l = $lines[$i]
            if ($l.IndexOf('"type":"assistant"', [StringComparison]::Ordinal) -lt 0) { continue }
            $o = try { $l | ConvertFrom-Json } catch { $null }
            if (-not $o -or [string]$o.type -ne 'assistant' -or $o.isSidechain -eq $true -or -not $o.message) { continue }
            if ($o.timestamp) { $at = $o.timestamp }
            $synthetic = [string]$o.message.model -eq '<synthetic>'
            foreach ($b in @($o.message.content)) {
                if (-not $b) { continue }
                if ($b.type -eq 'text' -and ([string]$b.text).Trim()) {
                    $parts.Add([ordered]@{ t = $(if ($synthetic) { 'note' } else { 'text' }); s = [string]$b.text })
                }
                elseif ($b.type -eq 'tool_use') { $parts.Add([ordered]@{ t = 'tool'; s = (Get-ChatqToolLine $b) }) }
            }
        }
        $sel = Select-ChatqPartsTail $parts.ToArray() $Max
        $when = ConvertTo-ChatqDate $at
        return [pscustomobject]@{ Parts = @($sel.Parts); Cut = $sel.Cut; At = $when }
    }
    return $null
}

function Get-ChatqJobTurnText {
    <#
    The last turn of a job chatq ran, from its own log: the entries after the
    log's last init - one run - its text and tool lines, Claude and Codex
    alike (Get-ChatqLogEntries reads both). A Claude job with no log falls
    back on its transcript. The shape of Get-ChatqTurnText, or $null.
    #>
    param($Job, [int]$Max = 30000)
    $log = Join-Path $script:ChatqLogDir "$($Job.id).jsonl"
    if (Test-Path -LiteralPath $log) {
        $e = @(Get-ChatqLogEntries $Job -MaxBytes 8MB)
        $last = -1
        for ($i = 0; $i -lt $e.Count; $i++) { if ($e[$i].Type -eq 'init') { $last = $i } }
        $parts = [System.Collections.Generic.List[object]]::new()
        for ($i = $last + 1; $i -lt $e.Count; $i++) {
            if ($e[$i].Type -eq 'text' -and ([string]$e[$i].Text).Trim()) { $parts.Add([ordered]@{ t = 'text'; s = [string]$e[$i].Text }) }
            elseif ($e[$i].Type -eq 'tool') { $parts.Add([ordered]@{ t = 'tool'; s = [string]$e[$i].Text }) }
        }
        if ($parts.Count) {
            $sel = Select-ChatqPartsTail $parts.ToArray() $Max
            $when = ConvertTo-ChatqDate $Job.endedAt
            if (-not $when) { $when = try { [System.IO.File]::GetLastWriteTime($log) } catch { $null } }
            return [pscustomobject]@{ Parts = @($sel.Parts); Cut = $sel.Cut; At = $when }
        }
    }
    if ($Job.provider -eq 'claude' -and $Job.path) { return (Get-ChatqTurnText ([string]$Job.path) $Max) }
    return $null
}

function Get-ChatqDownSent {
    # the whole answer already sent for an alert: @{ At; Attached }, or $null
    param([string]$Aid)
    try {
        $st = Get-ChatqReplyState
        $x = $st.downSent[$Aid]
        if (-not $x) { return $null }
        return [pscustomobject]@{ At = (ConvertTo-ChatqDate $x.at); Attached = [bool]$x.attached }
    }
    catch { return $null }
}

function Send-ChatqReplyText {
    <#
    The whole answer of an alert's chat, on the down topic for the page to
    show above its box: only with reply.full on, for done, needs input and
    failed, about a chat, when there is text, and while the day's whole
    answers are under reply.downPerDay - counted once per alert, before it
    goes. From the job's own log for a job chatq ran, else the transcript
    of a chat you run yourself. -Again: the phone asked (act read); within 3
    hours of the first send it is sent again only when that one went as an
    attachment, which ntfy.sh keeps 3 hours where it keeps an inline one 12.
    $true when the message went. Never throws.
    #>
    param($Rc, [string]$Aid, [string]$Event, $Job, [switch]$Quick, [switch]$Again)
    try {
        if (-not ($Rc -and $Rc.Links -and $Rc.Full)) { return $false }
        if ($Event -notin 'done', 'needs input', 'failed') { return $false }
        if (-not ($Job -and $Job.sessionId)) { return $false }
        $turn = if ($Job.id) { Get-ChatqJobTurnText $Job $Rc.FullMax } elseif ($Job.path) { Get-ChatqTurnText ([string]$Job.path) $Rc.FullMax } else { $null }
        if (-not $turn -or -not @($turn.Parts).Count) { return $false }
        $before = Get-ChatqDownSent $Aid
        if ($Again -and $before -and $before.At -and ((Get-Date) - $before.At).TotalHours -lt 3 -and -not $before.Attached) {
            Write-ChatqReplyLog "read $Aid - the answer went inline at $($before.At.ToString('HH:mm')) and is still there - not sent again"
            return $false
        }
        if (-not $before -and -not (Add-ChatqDownCount $Rc 'full')) {
            Write-ChatqReplyLog "whole answer for $Aid not sent - the day's $($Rc.DownPerDay) are used (reply.downPerDay)"
            return $false
        }
        $at = if ($turn.At) { $turn.At.ToUniversalTime().ToString('o') } else { $null }
        $body = [ordered]@{
            v = 3; kind = 'reply'; ref = $Aid; ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); event = $Event
            title = [string]$Job.title; at = $at; cut = [int]$turn.Cut; parts = @($turn.Parts)
        }
        $r = Send-ChatqDown $Rc $Aid $body -Quick:$Quick
        if (-not $r.Ok) { return $false }
        $attached = [bool]$r.Attached
        try { $null = Use-ChatqReplyState { param($st) $st.downSent[$Aid] = @{ at = (Get-ChatqStamp); attached = $attached } } $Rc.Hours } catch {}
        return $true
    }
    catch {
        Write-ChatqReplyLog "whole answer for ${Aid}: $($_.Exception.Message)"
        return $false
    }
}

function Update-ChatqReplyFull {
    <#
    Send-ChatqAlert's part, once an answerable alert is registered and before
    its push goes: the whole answer on the down topic (Send-ChatqReplyText),
    then the alert's link made again - w= its time, which tells the page how
    far back to look, and r=1 when the whole answer went, so the page waits
    for it rather than offering to ask. Never throws.
    #>
    param($Rc, $Reply, [string]$Event, $Job, [switch]$Quick)
    try {
        if (-not ($Rc -and $Reply -and $Reply.Aid)) { return }
        $full = [bool](Send-ChatqReplyText $Rc $Reply.Aid $Event $Job -Quick:$Quick)
        $Reply.Link = Get-ChatqReplyLink $Rc $Reply.Aid $Event $Job -Full:$full -At ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    }
    catch {}
}

function Get-ChatqReplyPollSeconds {
    <#
    How long between two looks at the reply topic. ntfy.sh lets an address
    burst 60 requests and then refills one per 5 s - one per 10 s by its
    FAQ, which is what this is built for: 15 s while an alert is out, 20 s
    when only listening all the time, and 6 s for the 2 minutes after the
    phone asked for something (hotUntil) - a board or a list is usually
    followed by a send. That runs over the refill and lives off the burst,
    the one place that does. -InRun: the poll from inside a run, 30 s, and
    10 s while hot.
    #>
    param([switch]$InRun)
    $hot = $false
    $open = $false
    try {
        $st = Read-ChatqJson $script:ChatqReplyPath
        if ($st) {
            $h = ConvertTo-ChatqDate (Get-ChatField $st 'hotUntil')
            $hot = [bool]($h -and $h -gt (Get-Date))
            $u = ConvertTo-ChatqDate (Get-ChatField $st 'openUntil')
            $open = [bool]($u -and $u -gt (Get-Date))
        }
    }
    catch {}
    if ($InRun) { if ($hot) { return 10 } else { return 30 } }
    if ($hot) { return 6 }
    if ($open) { return 15 }
    return 20
}

function Get-ChatqReplyListenText {
    # the watcher's log line as it starts to listen: until when, or all the time
    try {
        $st = Get-ChatqReplyState
        $u = ConvertTo-ChatqDate $st.openUntil
        if ($u -and $u -gt (Get-Date)) { return "until $($u.ToString('HH:mm'))" }
        if ($st.standing) { return 'all the time' }
    }
    catch {}
    return 'until'
}

function Start-ChatqReplyStanding {
    <#
    reply.listen always: the watcher listens while a phone is paired, alert
    or not, so the phone's board and a new chat reach the PC from a bookmark.
    This marks replies.json standing - a no-op unless replies are on, a phone
    is paired and listen is always. Called by chatnotify -Listen always (and
    the setup window's Save), a shell's start and the Windows overlay's
    start; a stop (chatqrun -Stop) clears it until one of those runs again.
    Polling that was not going on starts a minute back, as a window that
    opens does. Cheap when standing already: one read. $true when standing.
    Never throws.
    #>
    param($Cfg)
    try {
        if (-not $Cfg) { $Cfg = Get-ChatqConfig }
        $rp = if ($Cfg.PSObject.Properties['reply']) { $Cfg.reply } else { $null }
        if (-not ($rp -and $rp.on -eq $true -and $rp.topic -and $rp.key -and [string](Get-ChatField $rp 'listen') -eq 'always')) { return $false }
        $now = Read-ChatqJson $script:ChatqReplyPath
        if ($now -and (Get-ChatField $now 'standing') -eq $true) { return $true }
        $null = Use-ChatqReplyState {
            param($st)
            $u = ConvertTo-ChatqDate $st.openUntil
            if (-not $st.standing -and -not ($u -and $u -gt (Get-Date))) {
                $st.since = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 60
                $st.lastId = $null
            }
            $st.standing = $true
        }
        return $true
    }
    catch { return $false }
}

function Stop-ChatqReplyStanding {
    # listening all the time ends: -Listen alerts; a stop clears it too
    try { if (Test-Path -LiteralPath $script:ChatqReplyPath) { $null = Use-ChatqReplyState { param($st) $st.standing = $false } }; return $true }
    catch { return $false }
}

function Get-ChatqBoardState {
    <#
    What replies.json keeps for the phone's board and the down topic, from
    the state Get-ChatqReplyState read, pruned for Save-ChatqReplyState:
    picks past their expiry and never more than 300, the oldest going first;
    compose acts older than the hour they are counted over; whole answers
    sent more than 12 hours ago (an inline message lives that long).
    #>
    param($State, [datetime]$Now)
    $picks = [ordered]@{}
    $live = @(@($State.picks.GetEnumerator()) | Where-Object {
            $x = ConvertTo-ChatqDate $_.Value.expires
            $x -and $x.ToUniversalTime() -gt $Now
        } | Sort-Object { [string]$_.Value.at } | Select-Object -Last 300)
    foreach ($e in $live) {
        $o = [ordered]@{}
        foreach ($k in 'kind', 'sessionId', 'provider', 'path', 'cwd', 'home', 'title', 'jobId', 'seq', 'at', 'expires') {
            if ($e.Value.ContainsKey($k)) { $o[$k] = $e.Value[$k] }
        }
        $picks[$e.Key] = $o
    }
    $compose = @(foreach ($c in @($State.compose)) {
            if (-not $c) { continue }
            $x = ConvertTo-ChatqDate $c.at
            if ($x -and $x.ToUniversalTime() -gt $Now.AddHours(-1)) { [ordered]@{ at = $c.at; act = $c.act } }
        })
    $sent = [ordered]@{}
    foreach ($e in @($State.downSent.GetEnumerator())) {
        $x = ConvertTo-ChatqDate $e.Value.at
        if ($x -and $x.ToUniversalTime() -gt $Now.AddHours(-12)) { $sent[$e.Key] = [ordered]@{ at = $e.Value.at; attached = [bool]$e.Value.attached } }
    }
    $down = if ($State.down) { [ordered]@{ day = [string]$State.down.day; full = [int]$State.down.full; other = [int]$State.down.other } } else { $null }
    return [pscustomobject]@{
        Picks = $picks; Standing = [bool]$State.standing; Compose = @($compose); Down = $down; DownSent = $sent
        RefusedAt = $State.composeRefusedAt; HotUntil = $State.hotUntil
    }
}

function Read-ChatqBoardState {
    # Get-ChatqReplyState's half for the board: the fields of replies.json
    # this file adds, read into $S (the state hashtable) as hashtables, dates
    # as UTC strings. A file from before 0.9.0 has none of them.
    param($S, $J)
    $iso = { param($v) $x = ConvertTo-ChatqDate $v; if ($x) { $x.ToUniversalTime().ToString('o') } else { $null } }
    $S.standing = [bool]($J.PSObject.Properties['standing'] -and $J.standing -eq $true)
    $S.composeRefusedAt = if ($J.PSObject.Properties['composeRefusedAt']) { & $iso $J.composeRefusedAt } else { $null }
    $S.hotUntil = if ($J.PSObject.Properties['hotUntil']) { & $iso $J.hotUntil } else { $null }
    if ($J.PSObject.Properties['picks'] -and $J.picks) {
        foreach ($p in $J.picks.PSObject.Properties) {
            $v = $p.Value
            if (-not $v -or $p.Name -cnotmatch '^[a-z2-7]{6}$') { continue }
            $e = @{ kind = [string]$v.kind; at = & $iso $v.at; expires = & $iso $v.expires }
            foreach ($k in 'sessionId', 'provider', 'path', 'cwd', 'title', 'jobId') { if ($v.PSObject.Properties[$k] -and $v.$k) { $e[$k] = [string]$v.$k } }
            if ($v.PSObject.Properties['seq'] -and $v.seq) { $e['seq'] = [int]$v.seq }
            # home only when it says: $null there is the default config dir
            if ($v.PSObject.Properties['home']) { $e['home'] = $(if ($v.home) { [string]$v.home } else { $null }) }
            $S.picks[$p.Name] = $e
        }
    }
    if ($J.PSObject.Properties['compose'] -and $J.compose) {
        $S.compose = @(foreach ($c in @($J.compose)) { if ($c -and $c.at) { @{ at = & $iso $c.at; act = [string]$c.act } } })
    }
    if ($J.PSObject.Properties['down'] -and $J.down -and $J.down.day) {
        $S.down = @{ day = [string]$J.down.day; full = [int]$J.down.full; other = [int]$J.down.other }
    }
    if ($J.PSObject.Properties['downSent'] -and $J.downSent) {
        foreach ($p in $J.downSent.PSObject.Properties) { if ($p.Value) { $S.downSent[$p.Name] = @{ at = & $iso $p.Value.at; attached = [bool]$p.Value.attached } } }
    }
}

#endregion
