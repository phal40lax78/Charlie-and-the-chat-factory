# VS-code-chat-manager, src/phone.ps1: dot-sourced by VS-code-chat-manager.ps1
# in its turn, never on its own - see the list there.

#region phone: replies from the phone ------------------------------------------
# A phone alert carries a link to a static page (docs/reply.html). What is
# typed there is sealed on the phone - AES-256-CBC under an HMAC - and posted
# to an ntfy.sh topic, which the watcher polls outbound. Nothing listens on
# this PC.
#
# The key is the phone's own. Pairing (chatnotify -Pair) sends one push whose
# link holds an RSA public key made for the occasion; the page makes 32 random
# bytes D, keeps them, and sends them back encrypted to that public key. That
# answer pairs nothing by itself: the public key is in a push that others may
# read too (an ntfy alert topic is often public), so anyone could answer. It
# becomes a candidate with a six-digit code worked out from D, which the
# phone shows as well, and the phone is paired only when you confirm at the
# PC the candidate whose code matches (chatnotify -Confirm, or the setup
# dialog). After that no push carries a secret: an alert's link names the
# alert and nothing else, so neither Join (whose push is a GET, logged in
# full) nor whoever reads an ntfy alert topic can answer one. Only a message
# whose MAC checks out does anything, and a job made or requeued by one never
# runs above reply.maxMode (acceptEdits unless you say otherwise).
#
# The wire format, which docs/reply.html must match byte for byte:
#   k      = HMAC-SHA256(D, "chatq-alert:" + aid)          one key per alert
#   enc    = HMAC-SHA256(k, "enc"), mac = HMAC-SHA256(k, "mac")
#   head   = "chatq1." + aid + "." + b64url(iv) + "." + b64url(AES-CBC(enc, iv, json))
#   message = head + "." + b64url(HMAC-SHA256(mac, head))
# and for pairing: "chatq2p." + pid + "." + b64url(RSA-OAEP-SHA256(json)),
# confirmed by code(D) = the first 4 bytes of HMAC-SHA256(D, "chatq-confirm")
# as a big-endian number, mod 1000000, six digits shown as "123 456".

$script:ChatqReplyPath = Join-Path $script:ChatqData 'replies.json'
$script:ChatqReplyLockPath = Join-Path $script:ChatqData 'replies.lock'
# the alerts about chats you run yourself (Update-ChatqLiveAlerts) wait here
# for the hidden process that sends them, which holds the lock while it runs
$script:ChatqOutboxDir = Join-Path $script:ChatqData 'outbox'
$script:ChatqOutboxLockPath = Join-Path $script:ChatqData 'outbox.lock'
$script:ChatqReplyPage ='https://phal40lax78.github.io/VS-code-chat-manager/reply.html'
$script:ChatqReplyServer = 'https://ntfy.sh'
$script:ChatqJoinIcon = 'https://raw.githubusercontent.com/phal40lax78/VS-code-chat-manager/main/extension/icon.png'
# the events chatnotify -Events and the setup dialog can hold back from the
# phone; 'test', 'reply' and 'pair' always go
$script:ChatqPhoneEvents = @('started', 'needs input', 'done', 'failed', 'limited', 'overloaded', 'waiting')
# Claude's permission modes from least to most allowed. A mode not on it
# counts as above any cap: a new mode is not trusted until it is placed here.
$script:ChatqModeLadder = @('plan', 'default', 'manual', 'acceptEdits', 'auto', 'dontAsk', 'bypassPermissions')
# the Codex sandboxes a phone job may keep; anything else runs workspace-write
$script:ChatqSafeSandboxes = @('read-only', 'workspace-write')
# this process's own throttles: when it last polled, when it last logged a poll
# that failed or a message with a strange id, when it last saved lastPolledAt
$script:ChatqReplyPolledAt = $null
$script:ChatqReplyErrAt = $null
$script:ChatqReplyBadIdAt = $null
$script:ChatqReplySavedAt = $null
# Junk refused, per stage (format, mac, pairing): when it was last logged and
# how many went unlogged since. The reply topic is no secret once a pairing
# push has gone out, so whoever reads that push can fill the log otherwise.
$script:ChatqReplyJunkLog = @{}
# What this process has already handled, for its whole life: the nonces, and
# the topic|id of every message it recorded. Looked at before the file, so a
# file that lags - a save that failed after the fact, a copy put back from
# elsewhere - never makes the watcher do one thing twice.
$script:ChatqReplySeen = @{}
$script:ChatqReplyHandled = @{}

function New-ChatqRandomBytes {
    param([int]$Count)
    $b = New-Object byte[] $Count
    $r = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $r.GetBytes($b) } finally { $r.Dispose() }
    return , $b
}

function New-ChatqRandomName {
    # [a-z2-7]: 32 letters, so a byte's value mod 32 picks one without bias
    param([int]$Length)
    $abc = 'abcdefghijklmnopqrstuvwxyz234567'
    $b = New-ChatqRandomBytes $Length
    return (-join @(foreach ($x in $b) { $abc[$x % 32] }))
}

function ConvertTo-ChatqB64Url {
    param([byte[]]$Bytes)
    return ([Convert]::ToBase64String($Bytes)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function ConvertFrom-ChatqB64Url {
    # the bytes, or $null for anything that is not base64url
    param([string]$Text)
    if ($null -eq $Text -or $Text -cnotmatch '^[A-Za-z0-9_-]*$') { return $null }
    $s = $Text.Replace('-', '+').Replace('_', '/')
    switch ($s.Length % 4) {
        1 { return $null }
        2 { $s += '==' }
        3 { $s += '=' }
    }
    try { return , [Convert]::FromBase64String($s) } catch { return $null }
}

function ConvertTo-ChatqUriPart {
    # EscapeDataString throws on half a surrogate pair - an emoji cut in two
    # by a trim - so that half becomes a ? instead. Only that half: a whole
    # pair is an emoji the phone can show.
    param([string]$Text)
    try { return [Uri]::EscapeDataString([string]$Text) }
    catch {
        $fixed = [string]$Text -replace '[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]', '?'
        return [Uri]::EscapeDataString($fixed)
    }
}

function Get-ChatqHmac {
    param([byte[]]$Key, [byte[]]$Data)
    $h = [System.Security.Cryptography.HMACSHA256]::new($Key)
    try { return , $h.ComputeHash($Data) } finally { $h.Dispose() }
}

function Invoke-ChatqAes {
    # AES-256-CBC with PKCS7 padding, what WebCrypto's AES-CBC does
    param([byte[]]$Key, [byte[]]$Iv, [byte[]]$Data, [switch]$Encrypt)
    $a = [System.Security.Cryptography.Aes]::Create()
    try {
        $a.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $a.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $a.Key = $Key
        $a.IV = $Iv
        $t = if ($Encrypt) { $a.CreateEncryptor() } else { $a.CreateDecryptor() }
        try { return , $t.TransformFinalBlock($Data, 0, $Data.Length) } finally { $t.Dispose() }
    }
    finally { $a.Dispose() }
}

function Test-ChatqSameBytes {
    # constant time: every byte is looked at, wherever the first difference is
    param([byte[]]$A, [byte[]]$B)
    if ($null -eq $A -or $null -eq $B -or $A.Length -ne $B.Length) { return $false }
    $d = 0
    for ($i = 0; $i -lt $A.Length; $i++) { $d = $d -bor ($A[$i] -bxor $B[$i]) }
    return ($d -eq 0)
}

function Get-ChatqReplyKeys {
    # One alert's keys: k from the phone's key D and the alert's id, then the
    # encryption and MAC keys from k. -K instead of -Master starts from k.
    param([byte[]]$Master, [string]$Aid, [byte[]]$K)
    $u = New-Object System.Text.UTF8Encoding $false
    if (-not $K) { $K = Get-ChatqHmac $Master ($u.GetBytes("chatq-alert:$Aid")) }
    [pscustomobject]@{
        K = $K
        Enc = (Get-ChatqHmac $K ($u.GetBytes('enc')))
        Mac = (Get-ChatqHmac $K ($u.GetBytes('mac')))
    }
}

function Protect-ChatqReplyMessage {
    <#
    Seal a reply as docs/reply.html does. The page is what really sends them;
    this is for the tests and the test vector. -Key is the phone's key D
    (base64url). -Iv, -Nonce and -Ts fix what is otherwise random or now;
    -Payload is the JSON itself, sealed exactly as given.
    #>
    param([string]$Key, [string]$Aid, [string]$Act = 'prompt', [string]$Text = '',
        [byte[]]$Iv, [string]$Nonce, [int64]$Ts = 0, [string]$Payload)
    $u = New-Object System.Text.UTF8Encoding $false
    $master = ConvertFrom-ChatqB64Url $Key
    if ($null -eq $master -or $master.Length -ne 32) { throw 'the reply key must be 32 bytes, base64url' }
    $ks = Get-ChatqReplyKeys $master $Aid
    if (-not $Payload) {
        if (-not $Nonce) { $Nonce = ConvertTo-ChatqB64Url (New-ChatqRandomBytes 16) }
        if (-not $Ts) { $Ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
        $Payload = [ordered]@{ v = 1; act = $Act; text = $Text; nonce = $Nonce; ts = $Ts } | ConvertTo-Json -Compress
    }
    if (-not $Iv) { $Iv = New-ChatqRandomBytes 16 }
    $ct = Invoke-ChatqAes $ks.Enc $Iv ($u.GetBytes($Payload)) -Encrypt
    $head = 'chatq1.' + $Aid + '.' + (ConvertTo-ChatqB64Url $Iv) + '.' + (ConvertTo-ChatqB64Url $ct)
    $mac = Get-ChatqHmac $ks.Mac ($u.GetBytes($head))
    return $head + '.' + (ConvertTo-ChatqB64Url $mac)
}

function Unprotect-ChatqReplyMessage {
    <#
    Open a sealed reply with the phone's key as it is now - so after a new
    pairing no old link works. Returns @{ Ok; Stage; Error; Aid; Payload }:
    Stage is how far it got, 'format', 'mac', 'decrypt' or 'ok'. Nothing is
    decrypted before the MAC checks out, and the MAC is compared in constant
    time, so a forged message learns nothing from how it failed.
    #>
    param([string]$Message, [byte[]]$Master)
    $r = [pscustomobject]@{ Ok = $false; Stage = 'format'; Error = $null; Aid = $null; Payload = $null }
    $p = @(([string]$Message).Trim() -split '\.')
    if ($p.Count -ne 5 -or $p[0] -cne 'chatq1' -or $p[1] -cnotmatch '^[a-z2-7]{10}$') { $r.Error = 'not a chatq reply'; return $r }
    $iv = ConvertFrom-ChatqB64Url $p[2]
    $ct = ConvertFrom-ChatqB64Url $p[3]
    $mac = ConvertFrom-ChatqB64Url $p[4]
    if ($null -eq $iv -or $iv.Length -ne 16 -or $null -eq $ct -or $ct.Length -eq 0 -or ($ct.Length % 16) -or $null -eq $mac -or $mac.Length -ne 32) {
        $r.Error = 'bad encoding'
        return $r
    }
    if ($null -eq $Master -or $Master.Length -ne 32) { $r.Error = 'no phone paired'; return $r }
    $r.Aid = $p[1]
    $r.Stage = 'mac'
    $u = New-Object System.Text.UTF8Encoding $false
    $ks = Get-ChatqReplyKeys $Master $p[1]
    $want = Get-ChatqHmac $ks.Mac ($u.GetBytes(($p[0..3] -join '.')))
    if (-not (Test-ChatqSameBytes $want $mac)) { $r.Error = 'the MAC does not match'; return $r }
    $r.Stage = 'decrypt'
    try {
        $pt = Invoke-ChatqAes $ks.Enc $iv $ct
        # strict: bytes that are not UTF-8 throw rather than turn into ?
        $json = (New-Object System.Text.UTF8Encoding $false, $true).GetString($pt)
        $o = $json | ConvertFrom-Json
    }
    catch { $r.Error = "could not be read: $($_.Exception.Message)"; return $r }
    # v1 is the sealing; a page that says 2 means the same sealing, paired
    if (-not $o -or [string]$o.v -notin '1', '2' -or -not $o.act) { $r.Error = 'not a chatq reply payload'; return $r }
    $r.Payload = $o
    $r.Ok = $true
    $r.Stage = 'ok'
    return $r
}

function New-ChatqRsa {
    # Windows PowerShell 5.1 has RSACng (its RSACryptoServiceProvider cannot
    # do OAEP with SHA-256); pwsh 7's RSA.Create does, on every OS
    param([int]$Bits = 0)
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        if ($Bits) { return [System.Security.Cryptography.RSACng]::new($Bits) }
        return [System.Security.Cryptography.RSACng]::new()
    }
    if ($Bits) { return [System.Security.Cryptography.RSA]::Create($Bits) }
    return [System.Security.Cryptography.RSA]::Create()
}

function Resize-ChatqBigEndian {
    # .NET wants D the length of the modulus and P, Q, DP, DQ and InverseQ
    # exactly half of it. A number exported elsewhere (JWK, Node) drops its
    # leading zero bytes, or carries a sign byte: padded or trimmed at the
    # front, which leaves its value alone.
    param([byte[]]$Bytes, [int]$Length)
    if ($null -eq $Bytes) { return $null }
    if ($Bytes.Length -eq $Length) { return , $Bytes }
    if ($Bytes.Length -gt $Length) {
        $extra = $Bytes.Length - $Length
        for ($i = 0; $i -lt $extra; $i++) { if ($Bytes[$i] -ne 0) { throw 'a key number is longer than the key' } }
        return , [byte[]]$Bytes[$extra..($Bytes.Length - 1)]
    }
    $out = New-Object byte[] $Length
    [Array]::Copy($Bytes, 0, $out, $Length - $Bytes.Length, $Bytes.Length)
    return , $out
}

function ConvertTo-ChatqRsaParameters {
    # RSAParameters from an object of standard-base64 fields (Modulus,
    # Exponent, D, P, Q, DP, DQ, InverseQ), as the pairing key is stored
    param($Object)
    $b = { param($n) [Convert]::FromBase64String([string]$Object.$n) }
    $mod = & $b 'Modulus'
    # a sign byte in front of the modulus is not part of the key's size
    while ($mod.Length -gt 1 -and $mod[0] -eq 0) { $mod = [byte[]]$mod[1..($mod.Length - 1)] }
    $n = $mod.Length
    $h = [int][Math]::Ceiling($n / 2)
    $p = New-Object System.Security.Cryptography.RSAParameters
    $p.Modulus = $mod
    $p.Exponent = & $b 'Exponent'
    if ($Object.D) {
        $p.D = Resize-ChatqBigEndian (& $b 'D') $n
        $p.P = Resize-ChatqBigEndian (& $b 'P') $h
        $p.Q = Resize-ChatqBigEndian (& $b 'Q') $h
        $p.DP = Resize-ChatqBigEndian (& $b 'DP') $h
        $p.DQ = Resize-ChatqBigEndian (& $b 'DQ') $h
        $p.InverseQ = Resize-ChatqBigEndian (& $b 'InverseQ') $h
    }
    return $p
}

function Unprotect-ChatqPairMessage {
    <#
    Open a pairing answer: "chatq2p." + pid + "." + b64url(RSA-OAEP-SHA256)
    with the private key saved when the pairing began (-KeyJson, the fields
    of ConvertTo-ChatqRsaParameters as JSON). -PairId is the pairing's id; a
    message for any other is not opened. Returns @{ Ok; Error; Payload;
    Json }, never a throw.
    #>
    param([string]$Message, [string]$KeyJson, [string]$PairId)
    $r = [pscustomobject]@{ Ok = $false; Error = $null; Payload = $null; Json = $null }
    $p = @(([string]$Message).Trim() -split '\.')
    if ($p.Count -ne 3 -or $p[0] -cne 'chatq2p' -or $p[1] -cnotmatch '^[a-z2-7]{10}$') { $r.Error = 'not a pairing message'; return $r }
    if (-not $PairId -or $p[1] -cne $PairId) { $r.Error = 'for no pairing in progress'; return $r }
    $ct = ConvertFrom-ChatqB64Url $p[2]
    if ($null -eq $ct -or $ct.Length -lt 64 -or $ct.Length -gt 1024) { $r.Error = 'bad encoding'; return $r }
    $rsa = $null
    try {
        $rsa = New-ChatqRsa
        $rsa.ImportParameters((ConvertTo-ChatqRsaParameters ($KeyJson | ConvertFrom-Json)))
        $pt = $rsa.Decrypt($ct, [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
        $json = (New-Object System.Text.UTF8Encoding $false, $true).GetString($pt)
        $r.Json = $json
        $r.Payload = $json | ConvertFrom-Json
    }
    catch { $r.Error = "could not be read: $($_.Exception.Message)"; return $r }
    finally { if ($rsa) { $rsa.Dispose() } }
    if (-not $r.Payload -or [string]$r.Payload.v -ne '2') { $r.Error = 'not a version 2 pairing'; return $r }
    $r.Ok = $true
    return $r
}

function Get-ChatqPairCode {
    <#
    The confirmation code of a phone's key D: the first 4 bytes of
    HMAC-SHA256(D, "chatq-confirm") as a big-endian number, mod 1000000.
    The page works out the same from the D it made and shows it; only the
    phone that made D and this PC, which has it from the answer, can know it.
    Six digits, or -Spaced as shown: "123 456".
    #>
    param([byte[]]$D, [switch]$Spaced)
    $h = Get-ChatqHmac $D ((New-Object System.Text.UTF8Encoding $false).GetBytes('chatq-confirm'))
    $n = ([uint64]$h[0] -shl 24) -bor ([uint64]$h[1] -shl 16) -bor ([uint64]$h[2] -shl 8) -bor [uint64]$h[3]
    $s = ($n % 1000000).ToString('000000')
    if ($Spaced) { return $s.Substring(0, 3) + ' ' + $s.Substring(3) }
    return $s
}

#endregion

#region phone: settings ---------------------------------------------------------

function Get-ChatqReplyConfig {
    <#
    config.json's reply block with its secrets opened and its defaults filled
    in. Paired when the phone's key reads back as 32 bytes: a key DPAPI
    cannot open - config.json copied from another user or machine - means
    not paired, not a crash on every alert. On (worth polling) when switched
    on, with a topic, and either paired or a pairing waiting for the phone;
    Links (alerts carry a reply link) only when on and paired.
    #>
    param($Cfg)
    if (-not $Cfg) { $Cfg = Get-ChatqConfig }
    $rp = if ($Cfg.PSObject.Properties['reply'] -and $Cfg.reply) { $Cfg.reply } else { [pscustomobject]@{} }
    $has = { param($n) [bool]($rp.PSObject.Properties[$n] -and $null -ne $rp.$n) }
    $topic = if (& $has 'topic') { Unprotect-ChatqSecret $rp.topic } else { $null }
    $key = if (& $has 'key') { Unprotect-ChatqSecret $rp.key } else { $null }
    $master = if ($key) { ConvertFrom-ChatqB64Url $key } else { $null }
    $server = if ((& $has 'server') -and $rp.server) { ([string]$rp.server).TrimEnd('/') } else { $script:ChatqReplyServer }
    $page = if ((& $has 'page') -and $rp.page) { [string]$rp.page } else { $script:ChatqReplyPage }
    $hours = 12
    if ((& $has 'hours') -and ($rp.hours -as [double]) -gt 0) { $hours = [double]$rp.hours }
    $wanted = (& $has 'on') -and $rp.on -eq $true
    $paired = [bool]($null -ne $master -and $master.Length -eq 32)
    $pairId = $null
    $pairUntil = $null
    if ((& $has 'pairing') -and $rp.pairing.id) {
        $x = ConvertTo-ChatqDate $rp.pairing.expires
        if ($x -and $x -gt (Get-Date)) { $pairId = [string]$rp.pairing.id; $pairUntil = $x }
    }
    $maxMode = if ((& $has 'maxMode') -and ([string]$rp.maxMode) -cin $script:ChatqModeLadder) { [string]$rp.maxMode } else { 'acceptEdits' }
    $on = [bool]($wanted -and $topic -and ($paired -or $pairUntil))
    # the PC -> phone channel's settings (src/phone-down.ps1)
    $ds = Get-ChatqDownSettings $rp $master
    [pscustomobject]@{
        On = $on; Wanted = [bool]$wanted; Ready = [bool]$topic; Paired = $paired; Links = [bool]($on -and $paired)
        Topic = $topic; Key = $key; Master = $master; Server = $server; Page = $page; Hours = $hours
        Phone = $(if (& $has 'phone') { [string]$rp.phone } else { $null })
        PairedAt = $(if (& $has 'pairedAt') { ConvertTo-ChatqDate $rp.pairedAt } else { $null })
        PairId = $pairId; PairUntil = $pairUntil; MaxMode = $maxMode
        Full = $ds.Full; FullMax = $ds.FullMax; Compose = $ds.Compose; NewMode = $ds.NewMode; Listen = $ds.Listen; DownPerDay = $ds.DownPerDay; DownTopic = $ds.DownTopic
    }
}

function Test-ChatqPhoneEvent {
    # config phoneEvents: which events reach the phone. Absent means all;
    # 'test', 'reply' and 'pair' always go - they answer something just done.
    param($Cfg, [string]$Event)
    if ($Event -in 'test', 'reply', 'pair') { return $true }
    # what quiet hours held: every line of it passed this filter already
    if ($Event -eq 'summary') { return $true }
    # a run waits on it, and there is no other way to answer (src/permit.ps1)
    if ($Event -eq 'permission') { return $true }
    if (-not ($Cfg -and $Cfg.PSObject.Properties['phoneEvents'] -and $null -ne $Cfg.phoneEvents)) { return $true }
    return ($Event -in @($Cfg.phoneEvents))
}

function ConvertFrom-ChatqJoinPaste {
    # The Join page hands you a whole push URL, so pasting that is the obvious
    # move: the key and the device come out of it. Anything else is the key.
    param([string]$Text)
    $t = ([string]$Text).Trim()
    if ($t -match '[?&]apikey=([^&\s]+)') {
        $key = $Matches[1]
        $dev = if ($t -match '[?&]device(?:Id|Names)=([^&\s]+)') { [uri]::UnescapeDataString($Matches[1]) } else { $null }
        return [pscustomobject]@{ Key = $key; Device = $dev; FromUrl = $true }
    }
    return [pscustomobject]@{ Key = $t; Device = $null; FromUrl = $false }
}

function Set-ChatqNotifyConfig {
    <#
    The one way alert settings change - chatnotify and the setup dialog both
    come here. -Changes is a hashtable of what to change; a key left out is
    left alone:
      Off           $true: Join, ntfy and the command off (nothing else is read)
      ApiKey        Join key, or a whole pasted push URL; '' is ignored
      Device        Join device id, group or name
      DeviceName    the device's display name, for the dialog
      Icon          Join icon URL; '' none, $null the default again
      PerChat       $true/$false: one notification per chat on the phone
      RemoveJoin    $true: forget Join
      Ntfy          ntfy topic ('' forgets ntfy); NtfyServer, NtfyToken
      Command       your PowerShell per alert; '' removes it
      Toast         $true/$false or 'on'/'off'
      QuietMinutes  0 or more
      Events        event names for the phone; 'all', @() or $null = all
      Reply         'on', 'off' or 'renew' (or $true/$false); renew pairs a
                    phone afresh, as Start-ChatqReplyPairing does
      ReplyHours    how long an alert can be answered
      ReplyMaxMode  the highest permission mode a reply may run a job in
      ReplyPage     the reply page's https URL - a copy on an origin of its
                    own; '' or $null the default again
      LiveAlerts    $true/$false or 'on'/'off': alerts about the chats you run
                    yourself, sent while you are away (Update-ChatqLiveAlerts)
      UsageAlerts, UsageAt, UsageReset   usage heads-ups; QuietHours ('00:00-07:00'
                    or 'off') and Urgent; Say and SayLanguage, read aloud by
                    Join - all src/phone-extras.ps1's (Read-ChatqNotifyExtras)
      Permit        $true/$false or 'on'/'off': a queued run's permission
                    prompt asks the phone (src/permit.ps1)
      PermitWait    1-25 minutes to answer one; PermitTools the tools the
                    phone may approve, or 'default'
      FullText, FullMax, Compose, NewMode, Listen
                    the PC -> phone channel: the whole answer, the board and
                    new chats from the phone (Get-ChatqDownChanges)
    Returns @{ Error; Messages; Changed; Config; NeedsPairing }: Messages
    are @{ Text; Color } lines to show, in order. An error changes nothing.
    NeedsPairing: replies are on and no phone is paired - the caller says
    whether to start a pairing (it sends a push; this never does, except for
    renew, which is asked for by name).
    #>
    param([hashtable]$Changes)
    $ch = @{}
    if ($Changes) { foreach ($k in $Changes.Keys) { $ch[[string]$k] = $Changes[$k] } }
    # other spellings of the same keys, so a caller need not guess which
    foreach ($pair in @(@('JoinKey', 'ApiKey'), @('JoinDevice', 'Device'), @('JoinDeviceName', 'DeviceName'), @('JoinIcon', 'Icon'),
            @('JoinPerChat', 'PerChat'), @('NtfyTopic', 'Ntfy'), @('PhoneEvents', 'Events'), @('ReplyOn', 'Reply'), @('MaxMode', 'ReplyMaxMode'))) {
        if ($ch.ContainsKey($pair[0]) -and -not $ch.ContainsKey($pair[1])) { $ch[$pair[1]] = $ch[$pair[0]] }
    }
    if ($ch.ContainsKey('ReplyRenew') -and $ch['ReplyRenew']) { $ch['Reply'] = 'renew' }
    $msgs = [System.Collections.Generic.List[object]]::new()
    $say = { param($t, $c) $msgs.Add([pscustomobject]@{ Text = $t; Color = $c }) }
    $needsPair = $false
    $out = { param($e) [pscustomobject]@{ Error = $e; Messages = $msgs.ToArray(); Changed = $changed; Config = $cfg; NeedsPairing = $needsPair } }
    $changed = $false
    $cfg = Get-ChatqConfig
    $d = $script:ChatqDot

    # every check first: a bad value saves nothing at all
    $events = $null
    if ($ch.ContainsKey('Events')) {
        $names = @(@($ch['Events']) | ForEach-Object { [string]$_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if (-not $names.Count -or @($names | Where-Object { $_ -eq 'all' }).Count) { $events = 'all' }
        else {
            $events = @()
            foreach ($n in $names) {
                $want = ($n -replace '[-_]', ' ').ToLower()
                if ($want -eq 'needsinput') { $want = 'needs input' }
                if ($want -notin $script:ChatqPhoneEvents) {
                    & $say "no event '$n' - these are: all, $($script:ChatqPhoneEvents -join ', ')" 'Yellow'
                    return (& $out "no event '$n'")
                }
                if ($want -notin $events) { $events += $want }
            }
        }
    }
    $reply = $null
    if ($ch.ContainsKey('Reply')) {
        $v = $ch['Reply']
        $reply = if ($v -is [bool]) { if ($v) { 'on' } else { 'off' } } else { ([string]$v).Trim().ToLower() }
        if ($reply -notin 'on', 'off', 'renew') { & $say "-Reply takes on, off or renew, not '$v'" 'Yellow'; return (& $out 'bad reply value') }
    }
    $maxMode = $null
    if ($ch.ContainsKey('ReplyMaxMode') -and $ch['ReplyMaxMode']) {
        $want = ([string]$ch['ReplyMaxMode']).Trim()
        $maxMode = @($script:ChatqModeLadder | Where-Object { $_ -eq $want })[0]
        if (-not $maxMode) { & $say "a reply's mode cap is one of: $($script:ChatqModeLadder -join ', ')" 'Yellow'; return (& $out 'bad max mode') }
    }
    # The page holds the phone's key under its own origin, and every
    # <user>.github.io project site shares one: a copy served from an origin
    # of its own keeps other pages' scripts away from it. https only - the
    # key is typed into nothing, but the page's code is what seals replies.
    $page = $null
    if ($ch.ContainsKey('ReplyPage')) {
        $page = ([string]$ch['ReplyPage']).Trim()
        if ($page) {
            $pu = $null
            if (-not ([Uri]::TryCreate($page, [UriKind]::Absolute, [ref]$pu) -and $pu.Scheme -eq 'https' -and $pu.Host -and $page -notmatch '[\s#]')) {
                & $say "the reply page must be an https URL with no #, not '$page'" 'Yellow'
                return (& $out 'bad reply page')
            }
        }
    }
    $quiet = $null
    if ($ch.ContainsKey('QuietMinutes') -and $null -ne $ch['QuietMinutes']) {
        $quiet = $ch['QuietMinutes'] -as [int]
        if ($null -eq $quiet -or $quiet -lt 0) { & $say "quiet minutes: a whole number, 0 or more" 'Yellow'; return (& $out 'bad quiet minutes') }
    }
    $liveOn = $null
    if ($ch.ContainsKey('LiveAlerts') -and $null -ne $ch['LiveAlerts'] -and '' -ne $ch['LiveAlerts']) {
        $v = $ch['LiveAlerts']
        $liveOn = if ($v -is [bool]) { $v } else { switch (([string]$v).Trim().ToLower()) { 'on' { $true } 'off' { $false } default { $null } } }
        if ($null -eq $liveOn) { & $say "-LiveAlerts takes on or off, not '$v'" 'Yellow'; return (& $out 'bad live alerts value') }
    }
    # usage heads-ups, quiet hours and voice: checked here with the rest
    $extras = Read-ChatqNotifyExtras $ch $msgs $cfg
    if ($extras.Error) { return (& $out $extras.Error) }
    # permissions from the phone (src/permit.ps1), checked with the rest
    $permitCh = Read-ChatqPermitChanges $ch
    if ($permitCh.Error) { & $say $permitCh.Error 'Yellow'; return (& $out $permitCh.Error) }
    # the PC -> phone channel's keys - FullText, FullMax, Compose, NewMode,
    # Listen - checked here with the rest (src/phone-board.ps1)
    $downCh = Get-ChatqDownChanges $ch $say
    if ($downCh.Error) { return (& $out $downCh.Error) }

    $save = {
        Save-ChatqJson $script:ChatqConfigPath $cfg
        if (-not $script:ChatqIsWindows) { try { & chmod 600 $script:ChatqConfigPath } catch {} }
    }
    if ($ch.ContainsKey('Off') -and $ch['Off']) {
        foreach ($k in 'join', 'ntfy', 'command') { if ($cfg.PSObject.Properties[$k]) { $cfg.PSObject.Properties.Remove($k) } }
        & $save
        $changed = $true
        & $say 'phone alerts and the command off - they still go to data/logs/alerts.log (and the toast)' 'DarkGray'
        return (& $out $null)
    }

    $apiKey = if ($ch.ContainsKey('ApiKey')) { [string]$ch['ApiKey'] } else { '' }
    $device = if ($ch.ContainsKey('Device')) { [string]$ch['Device'] } else { '' }
    if ($apiKey.Trim()) {
        $paste = ConvertFrom-ChatqJoinPaste $apiKey
        if ($paste.FromUrl -and $paste.Key) {
            $apiKey = $paste.Key
            if (-not $device -and $paste.Device) { $device = $paste.Device }
            & $say 'took the key out of the URL you pasted' 'DarkGray'
        }
    }
    else { $apiKey = '' }
    if ($ch.ContainsKey('RemoveJoin') -and $ch['RemoveJoin'] -and $cfg.PSObject.Properties['join']) {
        $cfg.PSObject.Properties.Remove('join')
        $changed = $true
        & $say 'Join forgotten' 'DarkGray'
    }
    $joinExtras = @('DeviceName', 'Icon', 'PerChat' | Where-Object { $ch.ContainsKey($_) })
    if ($apiKey -or $device.Trim() -or ($joinExtras.Count -and $cfg.PSObject.Properties['join'] -and $cfg.join)) {
        $j = if ($cfg.PSObject.Properties['join'] -and $cfg.join) { $cfg.join } else { [pscustomobject]@{} }
        if ($apiKey) { Set-ChatqProp $j 'apiKey' ([pscustomobject](Protect-ChatqSecret $apiKey.Trim())) }
        if ($device.Trim()) { Set-ChatqProp $j 'device' $device.Trim() }
        if (-not $j.device) { Set-ChatqProp $j 'device' 'group.phone' }
        if ($ch.ContainsKey('DeviceName')) {
            if ($ch['DeviceName']) { Set-ChatqProp $j 'deviceName' ([string]$ch['DeviceName']).Trim() }
            elseif ($j.PSObject.Properties['deviceName']) { $j.PSObject.Properties.Remove('deviceName') }
        }
        if ($ch.ContainsKey('Icon')) {
            if ($null -eq $ch['Icon']) { if ($j.PSObject.Properties['icon']) { $j.PSObject.Properties.Remove('icon') } }
            else { Set-ChatqProp $j 'icon' ([string]$ch['Icon']).Trim() }
        }
        if ($ch.ContainsKey('PerChat')) { Set-ChatqProp $j 'perChat' ([bool]$ch['PerChat']) }
        Set-ChatqProp $cfg 'join' $j
        $changed = $true
        if ($apiKey -or $device.Trim()) {
            & $say "Join saved $d device $($j.device)$(if ($j.apiKey.protected) { " $d key protected with DPAPI" })" 'Green'
        }
    }

    $ntfy = if ($ch.ContainsKey('Ntfy')) { [string]$ch['Ntfy'] } else { $null }
    $nServer = if ($ch.ContainsKey('NtfyServer')) { [string]$ch['NtfyServer'] } else { '' }
    $nToken = if ($ch.ContainsKey('NtfyToken')) { [string]$ch['NtfyToken'] } else { '' }
    if ($null -ne $ntfy -and -not $ntfy.Trim() -and $ch.ContainsKey('Ntfy')) {
        if ($cfg.PSObject.Properties['ntfy']) { $cfg.PSObject.Properties.Remove('ntfy'); $changed = $true; & $say 'ntfy forgotten' 'DarkGray' }
    }
    elseif ($ntfy -or $nServer -or $nToken) {
        $n = if ($cfg.PSObject.Properties['ntfy'] -and $cfg.ntfy) { $cfg.ntfy } else { [pscustomobject]@{} }
        if ($ntfy) { Set-ChatqProp $n 'topic' ([pscustomobject](Protect-ChatqSecret $ntfy.Trim())) }
        if ($nServer) { Set-ChatqProp $n 'server' $nServer.Trim().TrimEnd('/') }
        if ($nToken) { Set-ChatqProp $n 'token' ([pscustomobject](Protect-ChatqSecret $nToken.Trim())) }
        Set-ChatqProp $cfg 'ntfy' $n
        $changed = $true
        $shown = Unprotect-ChatqSecret $n.topic
        # never the whole topic: it is the password
        if ($shown) { $shown = $shown.Substring(0, [Math]::Min(3, $shown.Length)) + '...' }
        & $say "ntfy saved $d topic $shown $d $(if ($n.server) { $n.server } else { 'https://ntfy.sh' })" 'Green'
        if ($n.server -and ([string]$n.server) -notmatch '^https://') {
            & $say 'that ntfy server is not https: alerts through it carry no reply link' 'Yellow'
        }
    }
    if ($ch.ContainsKey('Command')) {
        $command = [string]$ch['Command']
        if ($command.Trim()) { Set-ChatqProp $cfg 'command' $command; & $say 'command saved - it runs on every alert' 'Green' }
        elseif ($cfg.PSObject.Properties['command']) { $cfg.PSObject.Properties.Remove('command'); & $say 'command removed' 'DarkGray' }
        $changed = $true
    }
    if ($ch.ContainsKey('Toast') -and $null -ne $ch['Toast'] -and '' -ne $ch['Toast']) {
        $t = $ch['Toast']
        $on = if ($t -is [bool]) { $t } else { ([string]$t).Trim() -eq 'on' }
        Set-ChatqProp $cfg 'toast' $on
        $changed = $true
        & $say "desktop toast $(if ($on) { 'on' } else { 'off' })" 'Green'
    }
    if ($null -ne $quiet) {
        Set-ChatqProp $cfg 'quietMinutes' $quiet
        $changed = $true
        $what = if ($quiet) { "the phone stays quiet while you used the PC in the last $quiet min" } else { 'the phone is always sent to' }
        & $say $what 'Green'
    }
    if ($null -ne $liveOn) {
        Set-ChatqProp $cfg 'liveAlerts' ([bool]$liveOn)
        $changed = $true
        $what = if ($liveOn) { "chats you run yourself: the phone hears when one waits on you or finishes while you are away" } else { 'chats you run yourself: no phone alerts - only what chatq runs' }
        & $say $what 'Green'
    }
    if ($null -ne $events) {
        if ($events -eq 'all') {
            if ($cfg.PSObject.Properties['phoneEvents']) { $cfg.PSObject.Properties.Remove('phoneEvents') }
            & $say 'the phone gets every alert' 'Green'
        }
        else {
            Set-ChatqProp $cfg 'phoneEvents' @($events)
            & $say "the phone gets: $($events -join ', ') (and tests and replies)" 'Green'
        }
        $changed = $true
    }
    if ($ch.ContainsKey('ReplyHours') -and ($ch['ReplyHours'] -as [double]) -gt 0) {
        $rp = if ($cfg.PSObject.Properties['reply'] -and $cfg.reply) { $cfg.reply } else { [pscustomobject]@{} }
        Set-ChatqProp $rp 'hours' ([double]$ch['ReplyHours'])
        Set-ChatqProp $cfg 'reply' $rp
        $changed = $true
    }
    if ($maxMode) {
        $rp = if ($cfg.PSObject.Properties['reply'] -and $cfg.reply) { $cfg.reply } else { [pscustomobject]@{} }
        Set-ChatqProp $rp 'maxMode' $maxMode
        Set-ChatqProp $cfg 'reply' $rp
        $changed = $true
        & $say "a reply runs a job in $maxMode at most" 'Green'
    }
    if ($null -ne $page) {
        $rp = if ($cfg.PSObject.Properties['reply'] -and $cfg.reply) { $cfg.reply } else { [pscustomobject]@{} }
        $wasPage = (Get-ChatqReplyConfig $cfg).Page
        if ($page) { Set-ChatqProp $rp 'page' $page }
        elseif ($rp.PSObject.Properties['page']) { $rp.PSObject.Properties.Remove('page') }
        Set-ChatqProp $cfg 'reply' $rp
        $changed = $true
        $nowPage = if ($page) { $page } else { $script:ChatqReplyPage }
        & $say "the reply page: $nowPage" 'Green'
        # the phone keeps its key with the page it paired on: a page on
        # another origin has none, so the phone pairs again there
        $origin = { param($u) $x = $null; if ([Uri]::TryCreate([string]$u, [UriKind]::Absolute, [ref]$x)) { $x.GetLeftPart([UriPartial]::Authority).ToLowerInvariant() } else { '' } }
        $rcp = Get-ChatqReplyConfig $cfg
        if ($rcp.Paired -and (& $origin $wasPage) -ne (& $origin $nowPage)) {
            & $say 'a page on another site has no key for the phone - pair it again there (chatnotify -Pair)' 'Yellow'
        }
    }
    if (Set-ChatqDownChanges $cfg $downCh $say) { $changed = $true }
    # Replies switched on or off: where polling got to is reset either way,
    # so nothing sent to the topic while they were off is ever run. Off also
    # shuts the window and forgets every alert out there (see
    # Reset-ChatqReplyCursor); on again leaves the window shut until the
    # next alert that can be answered opens it.
    $flipped = $false
    if ($reply) {
        $rp = if ($cfg.PSObject.Properties['reply'] -and $cfg.reply) { $cfg.reply } else { [pscustomobject]@{} }
        $was = [bool]($rp.PSObject.Properties['on'] -and $rp.on -eq $true)
        $nowOn = $reply -ne 'off'
        Set-ChatqProp $rp 'on' $nowOn
        Set-ChatqProp $cfg 'reply' $rp
        $changed = $true
        $flipped = $was -ne $nowOn
        $rc = Get-ChatqReplyConfig $cfg
        if ($reply -eq 'on') {
            if ($rc.Paired) { & $say "replies from the phone on $d tap an alert, type the next prompt $d it goes sealed through ntfy.sh" 'Green' }
            else {
                & $say 'replies from the phone on - no phone is paired yet' 'Green'
                $needsPair = -not $rc.PairUntil
            }
            $phones = ($cfg.PSObject.Properties['join'] -and $cfg.join) -or ($cfg.PSObject.Properties['ntfy'] -and $cfg.ntfy)
            if (-not $phones) { & $say 'a reply needs an alert to tap - set up Join first (chatnotify -Setup, or -ApiKey)' 'Yellow' }
        }
        elseif ($reply -eq 'off') { & $say 'replies from the phone off - the phone stays paired, the alerts out there stop working; -Reply on picks it up again' 'DarkGray' }
    }
    if (Set-ChatqNotifyExtras $cfg $extras $msgs) { $changed = $true }
    if ($permitCh.Any) {
        foreach ($m in @(Set-ChatqPermitChanges $cfg $permitCh)) { & $say $m.Text $m.Color }
        $changed = $true
    }
    if ($changed) { & $save }
    Complete-ChatqNotifyExtras $extras $msgs
    if ($reply -in 'on', 'off' -and ($flipped -or $reply -eq 'off')) {
        try { Reset-ChatqReplyCursor -Close:($reply -eq 'off') }
        catch { & $say "could not reset data/replies.json: $($_.Exception.Message)" 'Yellow' }
    }
    # listening all the time begins, or ends, with the setting that says so
    if ($changed) { Update-ChatqReplyStanding $downCh $cfg }
    if ($reply -eq 'renew') {
        $pr = Start-ChatqReplyPairing
        if ($pr.Error) { & $say "pairing: $($pr.Error)" 'Yellow' }
        else { & $say "pairing alert sent $d tap it on the phone by $($pr.Until.ToString('HH:mm')), then confirm its code here (chatnotify -Confirm <code>) $d the phone paired before stops working now" 'Green' }
        $cfg = Get-ChatqConfig
    }
    return (& $out $null)
}

#endregion

#region phone: pairing -----------------------------------------------------------

function Get-ChatqPairLink {
    # The pairing push's link: where to post, the pairing's id and the public
    # key. The one link that carries the topic - which is no secret on its
    # own: without the phone's key nothing posted there does anything.
    param($Rc, [string]$PairId, [byte[]]$Modulus, [byte[]]$Exponent)
    $h = [string][Environment]::MachineName
    if ($h.Length -gt 30) { $h = $h.Substring(0, 30) }
    $q = [ordered]@{
        v = '2'; m = 'pair'; s = $Rc.Server; t = $Rc.Topic; a = $PairId
        n = (ConvertTo-ChatqB64Url $Modulus); x = (ConvertTo-ChatqB64Url $Exponent); h = $h
    }
    return $Rc.Page + '#' + (($q.GetEnumerator() | ForEach-Object { $_.Key + '=' + (ConvertTo-ChatqUriPart $_.Value) }) -join '&')
}

function Start-ChatqReplyPairing {
    <#
    Pair a phone, afresh: a new RSA key pair, a new reply topic (so nothing
    aimed at the old one is read again), and the phone's old key removed at
    once, so a phone paired before - or whoever held its key - stops working
    now. Then the pairing push goes out through the phone channels; a tap on
    it lets that phone pick its own key and send it back sealed to the public
    key. The watcher listens 15 minutes for the answer, and each answer
    waits as a candidate until one is confirmed by its code (see
    Confirm-ChatqPairCandidate). Used by chatnotify -Pair (and -Reply renew,
    and -Reply on with nothing paired) and by the setup dialog. Returns
    @{ Error; Sent; Until }; any Error means no pairing alert is out.
    #>
    param([switch]$Quick)
    Set-StrictMode -Off
    $fail = { param($e) [pscustomobject]@{ Error = $e; Sent = $false; Until = $null } }
    $cfg = Get-ChatqConfig
    # Refused before anything changes: a push that cannot carry the link -
    # ntfy over plain http drops it - arrives as a notification that opens
    # nothing, while the phone paired before would already be cut off.
    if (-not (Test-ChatqLinkChannel $cfg)) {
        return (& $fail 'no phone channel can carry the pairing link - set up Join, or ntfy on an https server')
    }
    try {
        $rsa = New-ChatqRsa 2048
        try { $kp = $rsa.ExportParameters($true) } finally { $rsa.Dispose() }
    }
    catch { return (& $fail "could not make a key pair: $($_.Exception.Message)") }
    $b64 = { param($x) [Convert]::ToBase64String($x) }
    $priv = [ordered]@{
        Modulus = & $b64 $kp.Modulus; Exponent = & $b64 $kp.Exponent; D = & $b64 $kp.D; P = & $b64 $kp.P; Q = & $b64 $kp.Q
        DP = & $b64 $kp.DP; DQ = & $b64 $kp.DQ; InverseQ = & $b64 $kp.InverseQ
    } | ConvertTo-Json -Compress
    $pairId = New-ChatqRandomName 10
    $until = (Get-Date).AddMinutes(15)
    # data/replies.json first, and config.json only once that worked: a
    # pairing nobody would listen for is worse than none. Every link out
    # there is dead now, and where polling got to in the old topic means
    # nothing in the new one. The window is the pairing's 15 minutes, not
    # what the old alerts had left: none of them can be answered any more,
    # and the "paired" push that ends a pairing opens a full one.
    $reset = {
        param($st)
        $st.alerts = @{}
        $st.refused = @{}
        $st.pairCandidates = @()
        $st.lastId = $null
        $st.since = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 60
        $st.openUntil = $until.ToUniversalTime().ToString('o')
    }
    try { $null = Use-ChatqReplyState $reset }
    catch {
        # A file that is there but cannot be read - NULs after a power cut -
        # would otherwise wedge replies for good. A new topic and a new key
        # make every nonce and alert in it meaningless, so here, and only
        # here, it is put aside and a fresh one written.
        $why = $_.Exception.Message
        $bad = "$($script:ChatqReplyPath).bad"
        $moved = $false
        if ((Test-Path -LiteralPath $script:ChatqReplyPath) -and $why -like '*could not be read*') {
            try { Move-Item -LiteralPath $script:ChatqReplyPath -Destination $bad -Force; $moved = $true } catch { $why = $_.Exception.Message }
        }
        if (-not $moved) { return (& $fail "data/replies.json could not be reset - $why") }
        Write-ChatqReplyLog "pairing: data/replies.json could not be read - put aside as replies.json.bad"
        try { $null = Use-ChatqReplyState $reset }
        catch { return (& $fail "data/replies.json could not be written - $($_.Exception.Message)") }
    }
    $rp = if ($cfg.PSObject.Properties['reply'] -and $cfg.reply) { $cfg.reply } else { [pscustomobject]@{} }
    foreach ($k in 'key', 'phone', 'pairedAt') { if ($rp.PSObject.Properties[$k]) { $rp.PSObject.Properties.Remove($k) } }
    Set-ChatqProp $rp 'topic' ([pscustomobject](Protect-ChatqSecret ('chatq-' + (New-ChatqRandomName 24))))
    Set-ChatqProp $rp 'pairing' ([pscustomobject]@{ id = $pairId; key = [pscustomobject](Protect-ChatqSecret $priv); expires = $until.ToUniversalTime().ToString('o') })
    Set-ChatqProp $rp 'on' $true
    Set-ChatqProp $cfg 'reply' $rp
    try {
        Save-ChatqJson $script:ChatqConfigPath $cfg
        if (-not $script:ChatqIsWindows) { try { & chmod 600 $script:ChatqConfigPath } catch {} }
    }
    catch { return (& $fail "could not save config.json: $($_.Exception.Message)") }
    $rc = Get-ChatqReplyConfig (Get-ChatqConfig)
    $link = Get-ChatqPairLink $rc $pairId $kp.Modulus $kp.Exponent
    Write-ChatqReplyLog "pairing started (until $($until.ToString('HH:mm')))"
    $sent = Send-ChatqAlert 'pair' 'tap to let this phone answer chatq alerts - within 15 min' 2 -Loud -PairLink $link -Quick:$Quick
    if ($sent) { return [pscustomobject]@{ Error = $null; Sent = $true; Until = $until } }
    $err = if ($script:ChatqLastAlertError) { [string]$script:ChatqLastAlertError } else { 'the pairing alert was not sent' }
    # No push, no pairing: nothing is left waiting for a tap on an alert
    # that never came. The old key stays gone - pairing was asked for
    # because it should stop working, and that holds whatever the network did.
    try {
        $c2 = Get-ChatqConfig
        if ($c2.PSObject.Properties['reply'] -and $c2.reply -and $c2.reply.pairing -and [string]$c2.reply.pairing.id -ceq $pairId) {
            $c2.reply.PSObject.Properties.Remove('pairing')
            Save-ChatqJson $script:ChatqConfigPath $c2
        }
    }
    catch {}
    Write-ChatqReplyLog "pairing alert not sent - $err"
    return [pscustomobject]@{ Error = $err; Sent = $false; Until = $null }
}

function Test-ChatqLinkChannel {
    # Can any phone channel carry a link a tap opens? Join always can; ntfy
    # only over https (Send-ChatqNtfy leaves the link out otherwise).
    param($Cfg)
    if (-not $Cfg) { $Cfg = Get-ChatqConfig }
    if ($Cfg.PSObject.Properties['join'] -and $Cfg.join -and $Cfg.join.apiKey -and $Cfg.join.device) { return $true }
    if ($Cfg.PSObject.Properties['ntfy'] -and $Cfg.ntfy -and $Cfg.ntfy.topic) {
        $server = if ($Cfg.ntfy.server) { [string]$Cfg.ntfy.server } else { 'https://ntfy.sh' }
        return ($server -match '^https://')
    }
    return $false
}

function Get-ChatqPairKey {
    # the open pairing's private key (the JSON Unprotect-ChatqPairMessage
    # takes), or $null: no pairing open, or DPAPI cannot open it here
    param($Rc)
    if (-not $Rc.PairId) { return $null }
    $cfg = Get-ChatqConfig
    $rp = if ($cfg.PSObject.Properties['reply']) { $cfg.reply } else { $null }
    if (-not ($rp -and $rp.pairing -and [string]$rp.pairing.id -ceq $Rc.PairId -and $rp.pairing.key)) { return $null }
    return (Unprotect-ChatqSecret $rp.pairing.key)
}

function Receive-ChatqPairing {
    <#
    The phone's answer to a pairing push - or anyone's: the public key it is
    sealed to went out in a push others may read. So it pairs nothing. One
    for the pairing that is waiting (its id, unexpired), sent in the last 20
    minutes and holding a 32-byte key becomes a candidate in replies.json,
    with its code; the phone shows the same code, and the user confirms the
    one that matches (Confirm-ChatqPairCandidate). No push goes out and
    nothing changes in config.json. The same key sent twice is one
    candidate; five at most per pairing, the oldest going first. -Opened is
    what Unprotect-ChatqPairMessage made of it already. Returns $null,
    'unsaved' when replies.json could not be written (the message is left
    to come back on the next poll), or @{ Act = 'pair'; Code; Label }.
    #>
    param($Rc, [string]$Id, [string]$Message, [switch]$Quick, $Opened)
    $tag = "$($Rc.Topic)|$Id"
    $mark = {
        try { $null = Use-ChatqReplyState { param($st) $st.lastId = $Id; $st.lastPolledAt = Get-ChatqStamp } $Rc.Hours; $script:ChatqReplyHandled[$tag] = $true }
        catch { Write-ChatqReplyLog "could not save where polling got to: $($_.Exception.Message)"; 'unsaved' }
    }
    $v = $Opened
    if (-not $v) {
        $keyJson = Get-ChatqPairKey $Rc
        if ($Rc.PairId -and -not $keyJson) { Write-ChatqReplyJunk 'pairing' "pairing $Id refused - the pairing key cannot be read here"; return (& $mark) }
        $v = Unprotect-ChatqPairMessage $Message $keyJson $Rc.PairId
    }
    if (-not $v.Ok) { Write-ChatqReplyJunk 'pairing' "pairing $Id refused - $($v.Error)"; return (& $mark) }
    $pl = $v.Payload
    $d = ConvertFrom-ChatqB64Url ([string]$pl.d)
    $ts = $pl.ts -as [double]
    $age = if ($null -ne $ts) { ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $ts) / 1000 } else { $null }
    $fail = if ($null -eq $d -or $d.Length -ne 32) { 'the key is not 32 bytes' }
    elseif ($null -eq $age) { 'no time in it' }
    elseif ($age -gt 1200) { "sent $([int]$age) s ago" }
    elseif ($age -lt -1200) { "$([int](-$age)) s ahead" }
    if ($fail) { Write-ChatqReplyJunk 'pairing answer' "pairing $Id refused - $fail"; return (& $mark) }
    # a label for status lines: no control or format characters (a bidi
    # override would make a stranger's label read as yours), 40 at most
    $label = ([string]$pl.label) -replace '[\p{Cc}\p{Cf}]', ''
    $label = $label.Trim()
    if ($label.Length -gt 40) {
        $n = 40
        if ([char]::IsHighSurrogate($label[$n - 1])) { $n-- }
        $label = $label.Substring(0, $n)
    }
    if (-not $label) { $label = 'a phone' }
    $code = Get-ChatqPairCode $d -Spaced
    $dText = ConvertTo-ChatqB64Url $d
    $cand = @{
        id = (New-ChatqRandomName 6); pid = $Rc.PairId; d = (Protect-ChatqSecret $dText); label = $label; code = $code
        at = (Get-ChatqStamp); expires = $Rc.PairUntil.ToUniversalTime().ToString('o')
    }
    $pairId = $Rc.PairId
    try {
        $added = Use-ChatqReplyState {
            param($st)
            $st.lastId = $Id
            $st.lastPolledAt = Get-ChatqStamp
            $mine = @($st.pairCandidates | Where-Object { $_ -and [string]$_.pid -ceq $pairId })
            # the same key again - the page's answer posted twice, or copied
            # off the topic and posted again - is not a second candidate:
            # two with one code could never be told apart
            $again = @($mine | Where-Object { $_.code -eq $code -and (Unprotect-ChatqSecret $_.d) -ceq $dText })
            if ($again.Count) { return $false }
            $st.pairCandidates = @(@($mine) + @($cand) | Select-Object -Last 5)
            return $true
        } $Rc.Hours
    }
    catch {
        Write-ChatqReplyLog "pairing $Id not taken - the reply state could not be saved: $($_.Exception.Message)"
        return 'unsaved'
    }
    $script:ChatqReplyHandled[$tag] = $true
    if ($added) { Write-ChatqReplyLog "pairing answer from $label, code $code" }
    else { Write-ChatqReplyLog "pairing answer from $label again, code $code - already waiting to be confirmed" }
    return [pscustomobject]@{ Act = 'pair'; Code = $code; Label = $label; Feedback = $null; Job = $null }
}

function Get-ChatqPairCandidates {
    <#
    The answers to the pairing that is waiting, oldest first, as
    @(@{ Id; Label; Code; Digits; At }) - Code as shown ("123 456"), Digits
    without the space. None once the pairing has ended or run out. Cheap and
    never throws: the setup dialog asks every second or two.
    #>
    param($Cfg)
    try {
        if (-not $Cfg) { $Cfg = Get-ChatqConfig }
        $rp = if ($Cfg.PSObject.Properties['reply']) { $Cfg.reply } else { $null }
        if (-not ($rp -and $rp.pairing -and $rp.pairing.id)) { return @() }
        $x = ConvertTo-ChatqDate $rp.pairing.expires
        if (-not ($x -and $x -gt (Get-Date))) { return @() }
        $pairId = [string]$rp.pairing.id
        $st = Get-ChatqReplyState
        return @(foreach ($c in @($st.pairCandidates)) {
                if (-not $c -or [string]$c.pid -cne $pairId) { continue }
                [pscustomobject]@{
                    Id = [string]$c.id; Label = [string]$c.label; Code = [string]$c.code
                    Digits = ([string]$c.code) -replace '\D', ''; At = (ConvertTo-ChatqDate $c.at)
                }
            })
    }
    catch { return @() }
}

function Confirm-ChatqPairCandidate {
    <#
    Pair the phone whose answer has this code (-Code, six digits, spaces and
    the like ignored) or this candidate id (-Id): exactly one answer to the
    pairing still waiting must match. Its key goes into config.json first -
    if that save fails nothing else changes - then the pairing, its
    candidates, every alert and where polling got to are dropped in
    replies.json, and a push says it worked (itself an alert with a link, so
    "Send a test reply" can follow at once). Returns @{ Error; Label; Sent }.
    #>
    param([string]$Code, [string]$Id)
    Set-StrictMode -Off
    $fail = { param($e) [pscustomobject]@{ Error = $e; Label = $null; Sent = $false } }
    $digits = ([string]$Code) -replace '\D', ''
    if (-not $Id -and $digits.Length -ne 6) { return (& $fail 'the code is six digits, as the phone shows it') }
    $cfg = Get-ChatqConfig
    $rp = if ($cfg.PSObject.Properties['reply']) { $cfg.reply } else { $null }
    $pairing = if ($rp) { $rp.pairing } else { $null }
    $x = if ($pairing) { ConvertTo-ChatqDate $pairing.expires } else { $null }
    if (-not ($pairing -and $pairing.id -and $x -and $x -gt (Get-Date))) { return (& $fail 'no pairing is waiting - chatnotify -Pair starts one') }
    $pairId = [string]$pairing.id
    $st = $null
    try { $st = Get-ChatqReplyState } catch { return (& $fail "data/replies.json could not be read - $($_.Exception.Message)") }
    $mine = @(@($st.pairCandidates) | Where-Object { $_ -and [string]$_.pid -ceq $pairId })
    $hits = @(if ($Id) { $mine | Where-Object { [string]$_.id -ceq $Id } } else { $mine | Where-Object { (([string]$_.code) -replace '\D', '') -eq $digits } })
    if (-not $hits.Count) {
        $what = if ($Id) { "no answer $Id" } else { "no answer with the code $($digits.Substring(0, 3)) $($digits.Substring(3))" }
        return (& $fail "$what to this pairing - $(if ($mine.Count) { "$($mine.Count) waiting, none with it" } else { 'none has come in yet' })")
    }
    # two with one code: one of them is not the phone in your hand, and
    # which cannot be told - so neither
    if ($hits.Count -gt 1) { return (& $fail "$($hits.Count) answers have that code - pair again (chatnotify -Pair)") }
    $c = $hits[0]
    $dText = Unprotect-ChatqSecret $c.d
    $d = if ($dText) { ConvertFrom-ChatqB64Url $dText } else { $null }
    if ($null -eq $d -or $d.Length -ne 32) { return (& $fail 'that answer''s key cannot be read here - pair again') }
    $label = [string]$c.label
    # config.json is read, changed and saved with no lock, as every other
    # writer of it does: a Save in the setup dialog landing in the same
    # instant can put back the file it read, key-less, while the answers
    # below are cleared all the same. Known and left: the phone is then not
    # paired after all, and chatnotify -Pair pairs it again.
    Set-ChatqProp $rp 'key' ([pscustomobject](Protect-ChatqSecret $dText))
    Set-ChatqProp $rp 'phone' $label
    Set-ChatqProp $rp 'pairedAt' (Get-ChatqStamp)
    $rp.PSObject.Properties.Remove('pairing')
    try {
        Save-ChatqJson $script:ChatqConfigPath $cfg
        if (-not $script:ChatqIsWindows) { try { & chmod 600 $script:ChatqConfigPath } catch {} }
    }
    catch { return (& $fail "config.json could not be saved - $($_.Exception.Message)") }
    # Every link from before is dead (it was sealed for no key at all), and
    # polling starts over a minute back. A save that fails here leaves the
    # phone paired all the same: the candidates belong to a pairing that is
    # gone, and the alerts' links were never answerable.
    try {
        $null = Use-ChatqReplyState {
            param($s)
            $s.pairCandidates = @()
            $s.alerts = @{}
            $s.refused = @{}
            $s.lastId = $null
            $s.since = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 60
        }
    }
    catch { Write-ChatqReplyLog "paired, but data/replies.json was not reset: $($_.Exception.Message)" }
    # reply.listen always: the new phone's board is listened for from now
    $null = Start-ChatqReplyStanding
    Write-ChatqReplyLog "paired with $label, code $($c.code)"
    $sent = Send-ChatqAlert 'reply' "paired - $label. Tap an alert to answer it." 1 -Loud
    return [pscustomobject]@{ Error = $null; Label = $label; Sent = [bool]$sent }
}

#endregion

#region phone: the reply registry ------------------------------------------------
# data/replies.json: every alert that can be answered, what it was about, the
# nonces already used, and where polling got to. Its own file, not state.json
# - the watcher rewrites that one whole. The watcher and a shell sending an
# alert both change it, always through Use-ChatqReplyState.

function Get-ChatqReplyState {
    # As hashtables, dates as UTC strings whichever PowerShell read them -
    # pwsh 7 hands ISO strings back as [datetime]. A missing file is a fresh
    # state; one that is there but cannot be read throws, so that nothing
    # ever saves a fresh state over it and wipes the nonces already used.
    $s = @{ openUntil = $null; since = $null; lastId = $null; lastPolledAt = $null; lastReplyAt = $null; alerts = @{}; seen = @{}; refused = @{}; pairCandidates = @() }
    Initialize-ChatqBoardState $s
    if (-not (Test-Path -LiteralPath $script:ChatqReplyPath)) { return $s }
    $j = $null
    $err = $null
    for ($try = 1; $try -le 3; $try++) {
        try {
            $raw = [System.IO.File]::ReadAllText($script:ChatqReplyPath, (New-Object System.Text.UTF8Encoding $false))
            if (-not $raw.Trim()) { return $s }
            $j = $raw | ConvertFrom-Json
            $err = $null
            break
        }
        catch [System.IO.FileNotFoundException] { return $s }
        catch { $err = $_.Exception.Message; Start-Sleep -Milliseconds 100 }
    }
    if ($err -or -not $j) { throw "data/replies.json could not be read: $err" }
    $iso = { param($v) $x = ConvertTo-ChatqDate $v; if ($x) { $x.ToUniversalTime().ToString('o') } else { $null } }
    $s.openUntil = & $iso $j.openUntil
    $s.lastPolledAt = & $iso $j.lastPolledAt
    $s.lastReplyAt = & $iso $j.lastReplyAt
    if ($j.since -as [int64]) { $s.since = [int64]$j.since }
    if ($j.lastId) { $s.lastId = [string]$j.lastId }
    if ($j.alerts) {
        foreach ($p in $j.alerts.PSObject.Properties) {
            $a = $p.Value
            if (-not $a) { continue }
            $e = @{
                at = & $iso $a.at; expires = & $iso $a.expires; event = [string]$a.event
                jobId = $(if ($a.jobId) { [string]$a.jobId } else { $null }); seq = $(if ($a.seq) { [int]$a.seq } else { $null })
                sessionId = $(if ($a.sessionId) { [string]$a.sessionId } else { $null }); provider = $(if ($a.provider) { [string]$a.provider } else { $null })
                title = $(if ($a.title) { [string]$a.title } else { $null }); uses = [int]$a.uses
                path = $(if ($a.path) { [string]$a.path } else { $null }); cwd = $(if ($a.cwd) { [string]$a.cwd } else { $null })
            }
            # home only when the entry says: $null there is the default
            # config dir, which is not the same as not knowing
            if ($a.PSObject.Properties['home']) { $e['home'] = $(if ($a.home) { [string]$a.home } else { $null }) }
            # about a chat you run yourself, not a chatq job (Update-ChatqLiveAlerts)
            if ($a.PSObject.Properties['live'] -and $a.live -eq $true) { $e['live'] = $true }
            # a usage alert's kind: a soon one can be answered with Send now
            if ($a.PSObject.Properties['usage'] -and $a.usage) { $e['usage'] = [string]$a.usage }
            # a permission request's: what an answer must match (src/permit.ps1)
            if ($a.PSObject.Properties['permit'] -and $a.permit) { $e['permit'] = ConvertFrom-ChatqPermitEntry $a.permit }
            $s.alerts[$p.Name] = $e
        }
    }
    if ($j.seen) { foreach ($p in $j.seen.PSObject.Properties) { $s.seen[$p.Name] = & $iso $p.Value } }
    if ($j.refused) { foreach ($p in $j.refused.PSObject.Properties) { $s.refused[$p.Name] = & $iso $p.Value } }
    # the answers to a pairing, waiting for their code to be confirmed
    if ($j.pairCandidates) {
        $s.pairCandidates = @(foreach ($c in @($j.pairCandidates)) {
                if (-not ($c -and $c.id -and $c.pid -and $c.d)) { continue }
                @{
                    id = [string]$c.id; pid = [string]$c.pid; d = $c.d; label = [string]$c.label; code = [string]$c.code
                    at = & $iso $c.at; expires = & $iso $c.expires
                }
            })
    }
    # the PC -> phone channel's own fields (src/phone-down.ps1)
    Read-ChatqBoardState $s $j
    return $s
}

function Save-ChatqReplyState {
    # Pruned on every write: alerts past their expiry, refusals older than
    # the hour that rate-limits them, pairing answers past their pairing's
    # expiry, and never more than 200 alerts, the oldest going first. A
    # spent nonce goes only once nothing could take its message again: older
    # than any alert still out (a reply comes after its alert), and older
    # than twice the timestamp window - a phone clock ahead by the whole
    # window stretches it that far. -Hours is reply.hours, as the timestamp
    # check uses it. Throws when it cannot save. Only Use-ChatqReplyState
    # calls it, holding the lock.
    param($State, [double]$Hours = 12)
    $now = (Get-Date).ToUniversalTime()
    $alerts = [ordered]@{}
    $live = @($State.alerts.GetEnumerator() | Where-Object {
            $x = ConvertTo-ChatqDate $_.Value.expires
            $x -and $x.ToUniversalTime() -gt $now
        } | Sort-Object { [string]$_.Value.at } | Select-Object -Last 200)
    foreach ($e in $live) {
        $a = $e.Value
        $o = [ordered]@{
            at = $a.at; expires = $a.expires; event = $a.event; jobId = $a.jobId; seq = $a.seq
            sessionId = $a.sessionId; provider = $a.provider; title = $a.title; uses = [int]$a.uses; path = $a.path; cwd = $a.cwd
        }
        if ($a.ContainsKey('home')) { $o['home'] = $a['home'] }
        if ($a.ContainsKey('live') -and $a['live']) { $o['live'] = $true }
        if ($a.ContainsKey('usage') -and $a['usage']) { $o['usage'] = [string]$a['usage'] }
        if ($a.ContainsKey('permit') -and $a['permit']) { $o['permit'] = ConvertTo-ChatqPermitEntry $a['permit'] }
        $alerts[$e.Key] = $o
    }
    $seen = [ordered]@{}
    $cut = $now.AddSeconds(-2 * ($Hours * 3600 + 600))
    foreach ($e in $live) {
        $x = ConvertTo-ChatqDate $e.Value.at
        if ($x -and $x.ToUniversalTime().AddMinutes(-10) -lt $cut) { $cut = $x.ToUniversalTime().AddMinutes(-10) }
    }
    foreach ($e in $State.seen.GetEnumerator()) {
        $x = ConvertTo-ChatqDate $e.Value
        if ($x -and $x.ToUniversalTime() -gt $cut) { $seen[$e.Key] = $e.Value }
    }
    $refused = [ordered]@{}
    if ($State.refused) {
        foreach ($e in $State.refused.GetEnumerator()) {
            $x = ConvertTo-ChatqDate $e.Value
            if ($x -and $x.ToUniversalTime() -gt $now.AddHours(-1)) { $refused[$e.Key] = $e.Value }
        }
    }
    $cands = @(foreach ($c in @($State.pairCandidates)) {
            if (-not $c) { continue }
            $x = ConvertTo-ChatqDate $c.expires
            if (-not ($x -and $x.ToUniversalTime() -gt $now)) { continue }
            [ordered]@{ id = $c.id; pid = $c.pid; d = $c.d; label = $c.label; code = $c.code; at = $c.at; expires = $c.expires }
        })
    # the PC -> phone channel's own, pruned (src/phone-down.ps1)
    $bs = Get-ChatqBoardState $State $now
    Save-ChatqJson $script:ChatqReplyPath ([ordered]@{
            openUntil = $State.openUntil; since = $State.since; lastId = $State.lastId
            lastPolledAt = $State.lastPolledAt; lastReplyAt = $State.lastReplyAt; alerts = $alerts; seen = $seen; refused = $refused
            pairCandidates = $cands
            picks = $bs.Picks; standing = $bs.Standing; compose = $bs.Compose; down = $bs.Down; downSent = $bs.DownSent; composeRefusedAt = $bs.RefusedAt; hotUntil = $bs.HotUntil
        })
}

function Use-ChatqReplyState {
    <#
    Every change to data/replies.json goes through here. The watcher and a
    shell - or the setup dialog - both write it, and two plain read-then-save
    writers would let one put back what the other just recorded: a spent
    nonce, where polling got to, a use counted. Then one reply runs twice.
    So data/replies.lock is held with no sharing from the read to the save
    (waiting up to 3 s for it). The block gets the state as a hashtable,
    changes it in place, and what it outputs is returned. Throws when the
    lock cannot be had, the file cannot be read or the save fails: the
    caller decides what that means, and never acts as if it had been saved.
    Nothing that sends or waits on the network belongs inside the block.
    #>
    # odd names on purpose: the block runs in a scope below this one and sees
    # these, and would see them instead of its caller's variables of the
    # same name
    param([scriptblock]$ReplyStateBlock, [double]$ReplyStateHours = 0)
    # reply.hours as configured when the caller does not say: pruning with
    # any other number drops nonces the timestamp check would still let by
    if ($ReplyStateHours -le 0) { $ReplyStateHours = Get-ChatqReplyHours }
    New-ChatqDir $script:ChatqData
    $replyStateLock = $null
    $replyStateUntil = (Get-Date).AddSeconds(3)
    while (-not $replyStateLock) {
        try { $replyStateLock = [System.IO.File]::Open($script:ChatqReplyLockPath, 'OpenOrCreate', 'ReadWrite', 'None') }
        catch {
            if ((Get-Date) -gt $replyStateUntil) { break }
            # a wait of its own length each time: two writers retrying in
            # step would otherwise let one of them take it every time
            Start-Sleep -Milliseconds (Get-Random -Minimum 15 -Maximum 60)
        }
    }
    if (-not $replyStateLock) { throw 'data/replies.lock is held by another process' }
    try {
        $replyStateNow = Get-ChatqReplyState
        $replyStateOut = & $ReplyStateBlock $replyStateNow
        Save-ChatqReplyState $replyStateNow $ReplyStateHours
        return $replyStateOut
    }
    finally { $replyStateLock.Dispose() }
}

function Get-ChatqReplyHours {
    # reply.hours, or 12 - read without opening any secret, for every save
    param($Cfg)
    try {
        if (-not $Cfg) { $Cfg = Get-ChatqConfig }
        $rp = if ($Cfg.PSObject.Properties['reply']) { $Cfg.reply } else { $null }
        if ($rp -and $rp.PSObject.Properties['hours'] -and ($rp.hours -as [double]) -gt 0) { return [double]$rp.hours }
    }
    catch {}
    return 12
}

function Reset-ChatqReplyCursor {
    # Replies switched on or off: polling starts over a minute back, never
    # from where it got to - what was sent while they were off is not run.
    # -Close (off) shuts the window too, so no watcher keeps listening, and
    # forgets the alerts: an answer to one of them that is read later - the
    # replies back on and a window open again - is told the alert expired,
    # and is never run hours after you switched replies off. The refusals
    # already said stay on record, so that is one push per alert every 10
    # minutes at most.
    param([switch]$Close)
    $null = Use-ChatqReplyState {
        param($st)
        $st.lastId = $null
        $st.since = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 60
        if ($Close) { $st.openUntil = $null; $st.alerts = @{} }
        # off stops listening all the time as well
        if ($Close) { $st.standing = $false }
    }
}

function Close-ChatqReplyWindow {
    # chatqrun -Stop: the watcher is to stop listening too, and stay stopped
    # - a new shell, or one leaving watcher, starts one only while the window
    # is open. The next alert that can be answered opens it again. Never
    # throws; no file, no window, nothing written. Listening all the time
    # (reply.listen always) stops too, until the next shell or overlay start.
    if (-not (Test-Path -LiteralPath $script:ChatqReplyPath)) { return $true }
    try { $null = Use-ChatqReplyState { param($st) $st.openUntil = $null; $st.standing = $false }; return $true }
    catch { return $false }
}

function Get-ChatqReplyLink {
    # The page, told which alert this is and what it is about - nothing
    # secret: the key is on the phone, the topic too. x=1 marks an alert
    # about no chat, where the page offers no prompt box; j=live one about a
    # chat you run yourself, where it offers Send and Status. -TitleChars 0
    # leaves the chat's title out, for a Join URL that will not fit otherwise.
    # w=1 marks a usage alert about a reset coming, where the page offers
    # Send now - trusted by nobody: the watcher goes by the registry.
    # -Card: a permission request's sealed card, as r= (src/permit.ps1) -
    # sealed for the phone, so nothing on the way can read it.
    # -Full: the whole answer went to the down topic (Send-ChatqReplyText):
    # f=1, and o= the alert's time in unix seconds, which tells the page how
    # far back to look for it.
    param($Rc, [string]$Aid, [string]$Event, $Job, [int]$TitleChars = 20,
        [string]$UsageKind, [string]$Card, [switch]$Full, [int64]$At = 0)
    $t = if ($Job -and $Job.title) { [string]$Job.title } else { '' }
    if ($t.Length -gt $TitleChars) {
        $n = [Math]::Max(0, $TitleChars)
        if ($n -gt 0 -and [char]::IsHighSurrogate($t[$n - 1])) { $n-- }
        $t = $t.Substring(0, $n)
    }
    $q = [ordered]@{
        v = '2'; a = $Aid; e = $Event
        n = $(if ($Job -and $Job.seq) { [string]$Job.seq } else { '' }); c = $t
        p = $(if ($Job -and $Job.provider) { [string]$Job.provider } else { '' })
        j = $(if ($Job -and $Job.state) { [string]$Job.state } else { '' })
    }
    if (-not ($Job -and $Job.sessionId)) { $q['x'] = '1' }
    if ($UsageKind -eq 'soon') { $q['w'] = '1' }
    if ($Card) { $q['r'] = $Card }
    if ($Full) { $q['f'] = '1'; if ($At -gt 0) { $q['o'] = [string]$At } }
    return $Rc.Page + '#' + (($q.GetEnumerator() | ForEach-Object { $_.Key + '=' + (ConvertTo-ChatqUriPart $_.Value) }) -join '&')
}

function New-ChatqReplyAlert {
    <#
    One alert that can be answered: a fresh id in the registry, with what it
    is about, and the link to put in it. $null when replies are off or no
    phone is paired - and when the registry cannot be written, since a link
    whose alert is not registered could only ever say "expired". -Permit
    and -Card: a permission request's (src/permit.ps1) - the card's
    plaintext, sealed here for the phone under this alert's own id.
    -UsageKind: a usage alert's kind, kept in the entry (usage).
    #>
    param([string]$Event, $Job, $Rc, [string]$UsageKind,
        $Permit, [string]$Card)
    if (-not $Rc) { $Rc = Get-ChatqReplyConfig }
    if (-not $Rc.Links) { return $null }
    $aid = New-ChatqRandomName 10
    $now = (Get-Date).ToUniversalTime()
    $e = @{
        at = $now.ToString('o'); expires = $now.AddHours($Rc.Hours).ToString('o'); event = $Event
        jobId = $(if ($Job -and $Job.id) { [string]$Job.id } else { $null })
        seq = $(if ($Job -and $Job.seq) { [int]$Job.seq } else { $null })
        sessionId = $(if ($Job -and $Job.sessionId) { [string]$Job.sessionId } else { $null })
        provider = $(if ($Job -and $Job.provider) { [string]$Job.provider } else { $null })
        title = $(if ($Job -and $Job.title) { [string]$Job.title } else { $null })
        path = $(if ($Job -and $Job.path) { [string]$Job.path } else { $null })
        cwd = $(if ($Job -and $Job.cwd) { [string]$Job.cwd } else { $null })
        uses = 0
    }
    # the chat's config dir, for a prompt sent after its job is gone
    if ($Job -and $Job.sessionId) { $e['home'] = $(if ($Job.home) { [string]$Job.home } else { $null }) }
    # a chat you run yourself: no job to retry, skip or stop (Invoke-ChatqReply)
    if (Get-ChatField $Job 'live') { $e['live'] = $true }
    # which usage alert: Invoke-ChatqReplyWake goes by this, never by the link
    if ($UsageKind) { $e['usage'] = $UsageKind }
    if ($Permit) { $e['permit'] = $Permit }
    $sealed = if ($Card) { Protect-ChatqPermitCard -Master $Rc.Master -Aid $aid -Card $Card } else { '' }
    try { $null = Use-ChatqReplyState { param($st) $st.alerts[$aid] = $e } $Rc.Hours }
    catch { return $null }
    # UsageKind and Card kept with it: a link made again after the whole
    # answer went (Update-ChatqReplyFull) keeps its w= and r=
    [pscustomobject]@{ Aid = $aid; Link = (Get-ChatqReplyLink $Rc $aid $Event $Job -UsageKind $UsageKind -Card $sealed); UsageKind = $UsageKind; Card = $sealed }
}

function Open-ChatqReplyWindow {
    # An alert that can be answered went out: the watcher listens until it
    # expires - or longer, when an earlier one is out longer still (a smaller
    # reply.hours set since must not cut an older link off). A window that
    # had shut starts polling a minute back, not from whatever the topic
    # still holds from before. Throws when the state cannot be saved.
    param($Rc)
    if (-not $Rc) { $Rc = Get-ChatqReplyConfig }
    $hours = $Rc.Hours
    $null = Use-ChatqReplyState {
        param($st)
        $now = Get-Date
        $until = ConvertTo-ChatqDate $st.openUntil
        if (-not $until -or $until -le $now) {
            $st.since = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 60
            $st.lastId = $null
        }
        $want = $now.AddHours($hours)
        if (-not $until -or $until -lt $want) { $st.openUntil = $want.ToUniversalTime().ToString('o') }
    } $hours
}

function Test-ChatqReplyOpen {
    # Is the watcher to keep listening? Replies on, a phone paired or a
    # pairing waiting for one, and an alert out that can still be answered.
    # Cheap - asked on every pass of the watcher's loop - so the secrets are
    # only looked for, not opened.
    param($Cfg)
    try {
        if (-not $Cfg) { $Cfg = Get-ChatqConfig }
        $rp = if ($Cfg.PSObject.Properties['reply']) { $Cfg.reply } else { $null }
        if (-not ($rp -and $rp.on -eq $true -and $rp.topic)) { return $false }
        if (-not $rp.key) {
            $x = if ($rp.pairing) { ConvertTo-ChatqDate $rp.pairing.expires } else { $null }
            if (-not ($x -and $x -gt (Get-Date))) { return $false }
        }
        $st = Read-ChatqJson $script:ChatqReplyPath
        $u = if ($st) { ConvertTo-ChatqDate $st.openUntil } else { $null }
        # or listening all the time: reply.listen always, a phone paired, and
        # no stop since the shell or the overlay last started it
        if ($rp.key -and [string](Get-ChatField $rp 'listen') -eq 'always' -and $st -and (Get-ChatField $st 'standing') -eq $true) { return $true }
        return [bool]($u -and $u -gt (Get-Date))
    }
    catch { return $false }
}

function Get-ChatqPhoneStatusText {
    # One line for chatnotify and the setup dialog: off, not paired, waiting
    # for the phone to answer a pairing, or paired - which phone, since when,
    # how long the watcher keeps listening and when a reply last came in.
    param($Cfg)
    $rc = Get-ChatqReplyConfig $Cfg
    if (-not $rc.Wanted) { return 'off' }
    $fmt = {
        param($x)
        if ($x.Date -eq (Get-Date).Date) { $x.ToString('HH:mm') } else { $x.ToString('ddd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture) }
    }
    if ($rc.PairUntil) {
        $n = @(Get-ChatqPairCandidates $Cfg).Count
        $more = if ($n) { " - $n answer$(if ($n -ne 1) { 's' }) to confirm by code" } else { '' }
        return "waiting for the phone - tap the pairing alert (until $(& $fmt $rc.PairUntil))$more"
    }
    if (-not $rc.Paired) { return 'not paired' }
    $parts = @('paired')
    if ($rc.Phone) { $parts += $rc.Phone }
    if ($rc.PairedAt) { $parts += "since $(& $fmt $rc.PairedAt)" }
    $st = try { Get-ChatqReplyState } catch { $null }
    if ($st) {
        $u = ConvertTo-ChatqDate $st.openUntil
        if ($u -and $u -gt (Get-Date)) { $parts += "listening until $(& $fmt $u)" }
        $l = ConvertTo-ChatqDate $st.lastReplyAt
        if ($l) { $parts += "last reply $(& $fmt $l)" }
    }
    # listening all the time, and whether whole answers go (src/phone-board.ps1)
    $parts += @(Get-ChatqBoardStatusParts $rc $st)
    return ($parts -join ' - ')
}

#endregion

#region phone: polling and acting ------------------------------------------------

function Write-ChatqReplyLog {
    # The watcher's log and a log of its own, which is what to read when a
    # reply seemed to go nowhere. One line each, whatever the text holds:
    # an error message with a line break must not pass for a second entry.
    param([string]$Text)
    $Text = $Text -replace '[\r\n]+', ' '
    Write-ChatqWatchLog "phone: $Text"
    try {
        New-ChatqDir $script:ChatqLogDir
        $p = Join-Path $script:ChatqLogDir 'replies.log'
        if ((Test-Path -LiteralPath $p) -and (Get-Item -LiteralPath $p).Length -gt 1MB) { Move-Item -LiteralPath $p -Destination "$p.1" -Force }
        [System.IO.File]::AppendAllText($p, "$((Get-Date).ToString('o'))  $Text`n", (New-Object System.Text.UTF8Encoding $false))
    }
    catch {}
}

function Get-ChatqReplyFeed {
    # ntfy's poll: the messages since a point, one JSON object per line.
    # @{ Text; Error }, never a throw.
    param([string]$Url, [int]$TimeoutSec = 8)
    try {
        if ($script:ChatqReplyPollSeam) { return [pscustomobject]@{ Text = [string](& $script:ChatqReplyPollSeam $Url); Error = $null } }   # tests
        Enable-ChatqTls12
        $r = Invoke-WebRequest -Uri $Url -Method Get -TimeoutSec $TimeoutSec -UseBasicParsing
        $text = (New-Object System.Text.UTF8Encoding $false).GetString($r.RawContentStream.ToArray())
        return [pscustomobject]@{ Text = $text; Error = $null }
    }
    catch { return [pscustomobject]@{ Text = ''; Error = $_.Exception.Message } }
}

function Write-ChatqReplyJunk {
    # A refused message anyone could have posted - the topic is no secret
    # to whoever saw a pairing push. Logged once per stage every 5 minutes,
    # with how many went unlogged since, so a flood fills no log.
    param([string]$Stage, [string]$Text)
    $j = $script:ChatqReplyJunkLog[$Stage]
    if ($j -and ((Get-Date) - $j.At).TotalMinutes -lt 5) { $j.Count++; return }
    $more = if ($j -and $j.Count) { " (and $($j.Count) more at this stage since $($j.At.ToString('HH:mm')))" } else { '' }
    $script:ChatqReplyJunkLog[$Stage] = @{ At = Get-Date; Count = 0 }
    Write-ChatqReplyLog "$Text$more"
}

function Test-ChatqReplyMessage {
    <#
    A first look at one message, before anything is saved or counted:
    @{ Junk; Stage; Error; Reply; Pair }. Junk is what anyone could have
    posted - not a chatq message, a MAC that does not check out, a pairing
    answer for no pairing or one that does not decrypt. Otherwise Reply
    (Unprotect-ChatqReplyMessage's answer, a MAC that checked out) or Pair
    (Unprotect-ChatqPairMessage's) is what Receive-ChatqReply goes on with.
    -PairKey: Get-ChatqPairKey's answer, asked once per poll.
    #>
    param($Rc, [string]$Message, $PairKey)
    $r = [pscustomobject]@{ Junk = $false; Stage = $null; Error = $null; Reply = $null; Pair = $null }
    # the phone about no alert - its board, a chat, a new one (src/phone-board.ps1)
    if (([string]$Message).TrimStart().StartsWith('chatq3c.', [StringComparison]::Ordinal)) { return (Test-ChatqComposeMessage $Rc $Message) }
    if (([string]$Message).TrimStart().StartsWith('chatq2p.', [StringComparison]::Ordinal)) {
        if ($Rc.PairId -and -not $PairKey) { $r.Junk = $true; $r.Stage = 'pairing'; $r.Error = 'the pairing key cannot be read here'; return $r }
        $p = Unprotect-ChatqPairMessage $Message $PairKey $Rc.PairId
        if (-not $p.Ok) { $r.Junk = $true; $r.Stage = 'pairing'; $r.Error = $p.Error; return $r }
        $r.Pair = $p
        return $r
    }
    $v = Unprotect-ChatqReplyMessage $Message $Rc.Master
    if (-not $v.Ok -and $v.Stage -ne 'decrypt') { $r.Junk = $true; $r.Stage = $v.Stage; $r.Error = $v.Error; return $r }
    $r.Reply = $v
    return $r
}

function Invoke-ChatqReplyPoll {
    <#
    Fetch what reached the reply topic since last time and act on it. Only
    with replies on, a window open and the last poll 15 s back (-MinSeconds);
    -Force skips the window and the wait. Every message is looked at first
    (Test-ChatqReplyMessage) and junk is passed over without counting:
    -MaxMessages caps only the messages that check out, so a flood of junk
    cannot hold a real "stop" back. The rest wait for the next poll. -Quick
    is for a poll inside a run, where every push it answers with gets one
    short try. A message whose record could not be saved ends the poll
    there: nothing after it moves polling on, so it comes back next time.
    Returns how many messages were acted on, an [int] and nothing else: the
    watcher redraws the board only when that is not 0. Never throws - a
    phone reply is not worth a watcher.
    #>
    param([switch]$Force, [int]$TimeoutSec = 8, [int]$MinSeconds = 15, [int]$MaxMessages = 10, [switch]$Quick)
    Set-StrictMode -Off
    try {
        # the cheap checks first: this is asked every few seconds
        if (-not $Force -and $script:ChatqReplyPolledAt -and ((Get-Date) - $script:ChatqReplyPolledAt).TotalSeconds -lt $MinSeconds) { return 0 }
        $cfg = Get-ChatqConfig
        if (-not $Force -and -not (Test-ChatqReplyOpen $cfg)) { return 0 }
        $rc = Get-ChatqReplyConfig $cfg
        if (-not $rc.On) { return 0 }
        $script:ChatqReplyPolledAt = Get-Date
        $st = Get-ChatqReplyState
        $since = if ($st.lastId) { $st.lastId } elseif ($st.since) { [string]$st.since } else { [string]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 60) }
        $url = "$($rc.Server)/$($rc.Topic)/json?poll=1&since=$([Uri]::EscapeDataString($since))"
        $feed = Get-ChatqReplyFeed $url $TimeoutSec
        if ($feed.Error) {
            # a laptop offline for an hour would otherwise log 240 lines
            if (-not $script:ChatqReplyErrAt -or ((Get-Date) - $script:ChatqReplyErrAt).TotalMinutes -ge 10) {
                $script:ChatqReplyErrAt = Get-Date
                Write-ChatqReplyLog "poll failed: $($feed.Error)"
            }
            return 0
        }
        $pairKey = Get-ChatqPairKey $rc
        $acted = 0
        # junk since the last message that was saved: passed over in one
        # save at the end, not a lock and a rewrite each
        $junkId = $null
        $junkTags = [System.Collections.Generic.List[string]]::new()
        $unsaved = $false
        foreach ($line in @(([string]$feed.Text) -split "`n")) {
            $line = $line.Trim()
            if (-not $line) { continue }
            $m = try { $line | ConvertFrom-Json } catch { $null }
            if (-not $m -or $m.event -ne 'message') { continue }
            # The id is the server's word, checked before anything else is
            # done with it: it goes into the log and into the next poll's
            # URL. One that is not ntfy's shape is skipped, never used.
            $id = [string]$m.id
            if ($id -cnotmatch '^[A-Za-z0-9]{1,40}$') {
                if (-not $script:ChatqReplyBadIdAt -or ((Get-Date) - $script:ChatqReplyBadIdAt).TotalMinutes -ge 10) {
                    $script:ChatqReplyBadIdAt = Get-Date
                    Write-ChatqReplyLog 'a message whose id is not ntfy''s shape - skipped'
                }
                continue
            }
            $tag = "$($rc.Topic)|$id"
            if ($script:ChatqReplyHandled.ContainsKey($tag)) { $junkId = $id; continue }
            $c = Test-ChatqReplyMessage $rc ([string]$m.message) $pairKey
            if ($c.Junk) {
                $what = if ($c.Stage -eq 'pairing') { "pairing $id refused - $($c.Error)" } else { "reply $id refused - $($c.Stage): $($c.Error)" }
                Write-ChatqReplyJunk $c.Stage $what
                $junkId = $id
                $junkTags.Add($tag)
                continue
            }
            # the rest waits for the next poll: lastId stays before it
            if ($acted -ge $MaxMessages) { break }
            $acted++
            $r = $null
            try { $r = Receive-ChatqReply $rc $id ([string]$m.message) -Quick:$Quick -Checked $c }
            catch {
                # after its record was saved, as good as done; before, it
                # comes back next poll - either way nothing after it now
                Write-ChatqReplyLog "reply ${id}: error $($_.Exception.Message)"
                $unsaved = $true
                break
            }
            if ($r -is [string] -and $r -eq 'unsaved') { $acted--; $unsaved = $true; break }
            # its save moved polling past the junk before it too
            foreach ($t in $junkTags) { $script:ChatqReplyHandled[$t] = $true }
            $junkTags.Clear()
            $junkId = $null
        }
        if ($junkId -and -not $unsaved) {
            try {
                $null = Use-ChatqReplyState { param($s) $s.lastId = $junkId; $s.lastPolledAt = Get-ChatqStamp } $rc.Hours
                foreach ($t in $junkTags) { $script:ChatqReplyHandled[$t] = $true }
                $script:ChatqReplySavedAt = Get-Date
            }
            catch { Write-ChatqReplyLog "could not save where polling got to: $($_.Exception.Message)" }
        }
        # when polling got nowhere, the time of it is written only now and
        # then: a window stays open for hours, and nothing reads it but you
        elseif (-not $acted -and (-not $script:ChatqReplySavedAt -or ((Get-Date) - $script:ChatqReplySavedAt).TotalMinutes -ge 5)) {
            $script:ChatqReplySavedAt = Get-Date
            try { $null = Use-ChatqReplyState { param($s) $s.lastPolledAt = Get-ChatqStamp } $rc.Hours } catch {}
        }
        return [int]$acted
    }
    catch {
        Write-ChatqReplyLog "poll error: $($_.Exception.Message)"
        return 0
    }
}

function Receive-ChatqReply {
    <#
    One message off the topic. In this order: a pairing answer goes to
    Receive-ChatqPairing; anything else must be a sealed reply whose MAC
    checks out under the phone's key as it is now - junk is logged (rate
    limited) and passed over. Then its nonce: one seen before - by this
    process, or in the file - is dropped without a word, however many times
    it is posted. Then what the message uses up - its nonce, a use of its
    alert, how far polling got - is saved, and only once that save worked
    is anything done: a failed save returns 'unsaved' and leaves the
    message to come back on the next poll and be judged again, never done
    twice. Last the checks that refuse: the phone's clock within the
    window, the alert known and unexpired, fewer than 20 uses. A refusal is
    said to the phone only when the MAC checked out, at most once per alert
    every 10 minutes, and with no new link: a replayed old message cannot
    make pushes, alerts or a longer window out of nothing. -Checked is
    Test-ChatqReplyMessage's answer, when the poll has it already.
    #>
    param($Rc, [string]$Id, [string]$Message, [switch]$Quick, $Checked)
    if ($Id -cnotmatch '^[A-Za-z0-9]{1,40}$') { return $null }
    $tag = "$($Rc.Topic)|$Id"
    if ($script:ChatqReplyHandled.ContainsKey($tag)) { return $null }
    $c = if ($Checked) { $Checked } else { Test-ChatqReplyMessage $Rc $Message (Get-ChatqPairKey $Rc) }
    if ($c.Pair -or ($c.Junk -and $c.Stage -eq 'pairing')) { return (Receive-ChatqPairing $Rc $Id $Message -Quick:$Quick -Opened $(if ($c.Pair) { $c.Pair } else { [pscustomobject]@{ Ok = $false; Error = $c.Error } })) }
    if (-not $c.Junk -and $c.PSObject.Properties['Compose'] -and $c.Compose) { return (Receive-ChatqCompose $Rc $Id $Message -Checked $c -Quick:$Quick) }
    if ($c.Junk) {
        # junk, or forged: nobody is answered, and polling moves past it
        Write-ChatqReplyJunk $c.Stage "reply $Id refused - $($c.Stage): $($c.Error)"
        try {
            $null = Use-ChatqReplyState { param($st) $st.lastId = $Id; $st.lastPolledAt = Get-ChatqStamp } $Rc.Hours
            $script:ChatqReplyHandled[$tag] = $true
        }
        catch { Write-ChatqReplyLog "could not save where polling got to: $($_.Exception.Message)"; return 'unsaved' }
        return $null
    }
    $v = $c.Reply
    $aid = $v.Aid
    $pl = $v.Payload
    $nonce = if ($v.Ok) { [string]$pl.nonce } else { '' }
    if ($nonce -and $script:ChatqReplySeen.ContainsKey($nonce)) {
        # a replay: nothing to do, only polling to move past it
        $script:ChatqReplyHandled[$tag] = $true
        try { $null = Use-ChatqReplyState { param($st) $st.lastId = $Id } $Rc.Hours } catch {}
        return $null
    }
    $hours = $Rc.Hours
    try {
        $rec = Use-ChatqReplyState {
            param($st)
            $st.lastId = $Id
            $st.lastPolledAt = Get-ChatqStamp
            $seen = [bool]($nonce -and $st.seen.ContainsKey($nonce))
            if ($nonce -and -not $seen) { $st.seen[$nonce] = Get-ChatqStamp }
            $e = $st.alerts[$aid]
            $uses = if ($e) { [int]$e.uses } else { 0 }
            if ($e -and -not $seen) { $e.uses = $uses + 1 }
            $fail = $null
            $say = $null
            if ($seen) { $fail = 'seen before' }
            elseif (-not $v.Ok -or -not $nonce) {
                $fail = if ($v.Ok) { 'no nonce' } else { "$($v.Stage): $($v.Error)" }
                $say = 'a reply came in that could not be read - nothing done'
            }
            else {
                $ts = $pl.ts -as [double]
                $age = if ($null -ne $ts) { ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $ts) / 1000 } else { $null }
                $exp = if ($e) { ConvertTo-ChatqDate $e.expires } else { $null }
                if ($null -eq $age -or [Math]::Abs($age) -gt ($hours * 3600 + 600)) {
                    $fail = if ($null -eq $age) { 'no time in it' } elseif ($age -ge 0) { "too old: sent $([int]$age) s ago" } else { "too old: $([int](-$age)) s ahead" }
                    $say = "that reply is too old, or the phone's clock is off - nothing done"
                }
                elseif (-not $exp -or $exp -lt (Get-Date)) { $fail = 'expired'; $say = 'that alert expired - reply to a newer one' }
                elseif ($uses -ge 20) { $fail = 'used up'; $say = 'that alert was answered 20 times already - reply to a newer one' }
                else { $st.lastReplyAt = Get-ChatqStamp }
            }
            # one refusal per alert every 10 minutes, decided here where the
            # last one is on record
            if ($say) {
                $last = ConvertTo-ChatqDate $st.refused[$aid]
                if ($last -and ((Get-Date) - $last).TotalMinutes -lt 10) { $say = $null }
                else { $st.refused[$aid] = Get-ChatqStamp }
            }
            [pscustomobject]@{ Fail = $fail; Say = $say; Entry = $(if ($e) { $e.Clone() } else { $null }) }
        } $hours
    }
    catch {
        Write-ChatqReplyLog "reply $Id not acted on - the reply state could not be saved: $($_.Exception.Message)"
        return 'unsaved'
    }
    $script:ChatqReplyHandled[$tag] = $true
    if ($nonce) { $script:ChatqReplySeen[$nonce] = $true }
    if ($rec.Fail) {
        Write-ChatqReplyLog "reply $Id refused - $($rec.Fail)"
        if ($rec.Say) { [void](Send-ChatqAlert 'reply' $rec.Say 1 -Loud -NoReply -Quick:$Quick) }
        return $null
    }
    $entry = $rec.Entry
    Write-ChatqReplyLog "reply $Id to $($entry.event)$(if ($entry.seq) { " #$($entry.seq)" }): $($pl.act)"
    return (Invoke-ChatqReply $pl $entry $aid -Rc $Rc -Quick:$Quick -Raw $Message)
}

function Get-ChatqModeRank {
    # where a Claude permission mode stands on the ladder; none is 'default',
    # as a run with none goes, and one not on it is above everything
    param([string]$Mode)
    if (-not $Mode) { $Mode = 'default' }
    for ($i = 0; $i -lt $script:ChatqModeLadder.Count; $i++) { if ($script:ChatqModeLadder[$i] -ceq $Mode) { return $i } }
    return 99
}

function Limit-ChatqPhoneMode {
    # the mode a job made or requeued by a reply runs in: $Mode when it is
    # within the cap, else the cap itself. @{ Mode; Capped }
    param([string]$Mode, [string]$Cap)
    if ((Get-ChatqModeRank $Mode) -gt (Get-ChatqModeRank $Cap)) { return [pscustomobject]@{ Mode = $Cap; Capped = $true } }
    return [pscustomobject]@{ Mode = $Mode; Capped = $false }
}

function Invoke-ChatqReply {
    <#
    One verified reply, done: what the phone asked for, then a push saying
    how it went - itself an alert with a fresh link, so the answer can be
    answered. Nothing in the message picks a permission mode, and no job
    made or requeued here runs above reply.maxMode (acceptEdits unless set
    otherwise): a prompt goes in its old job's mode or the chat's own, and
    either is brought down to the cap. A Codex job never keeps a sandbox
    wider than workspace-write. Text from the phone is sent as it is: its
    links pull no files from data/queue (-NoLinks). Returns @{ Act;
    Feedback; Job }, $null for an unknown act.
    An alert about a chat you run yourself (the entry says live) has no job
    behind it: a prompt is queued for that chat as for any other, and the
    status is given, but retry, allow, skip and stop are refused - and the
    push that says so is about that chat still, so it can be answered. A
    prompt to one still waiting on a prompt at the PC is queued all the
    same, and the push says it goes only once that is answered there.
    permit and refuse answer a permission request (Invoke-ChatqPermitReply);
    -Raw is the message as the phone posted it, which the bridge opens again.
    #>
    param($Payload, $Entry, [string]$Aid, $Rc, [switch]$Quick,
        [string]$Raw)
    if (-not $Rc) { $Rc = Get-ChatqReplyConfig }
    $cap = if ($Rc.MaxMode) { $Rc.MaxMode } else { 'acceptEdits' }
    $act = [string]$Payload.act
    $text = [string]$Payload.text
    $job = if ($Entry.jobId) { Find-ChatqJob ([string]$Entry.jobId) -Exact } else { $null }
    $about = $job
    $n = if ($job) { "#$($job.seq)" } elseif ($Entry.seq) { "#$($Entry.seq)" } else { 'that job' }
    $limitNote = { param($m) " - runs in $m, the phone's limit" }
    $say = $null
    $live = [bool](Get-ChatField $Entry 'live')
    $pick = if ($live -and $act -in 'retry', 'allow', 'skip', 'stop') { 'live-refused' } else { $act }
    switch -Exact ($pick) {
        'live-refused' { $say = "that chat is one you run yourself, not a chatq job - nothing to $act; send it a prompt instead" }
        'prompt' {
            if (-not $text.Trim()) { $say = 'an empty reply - nothing queued'; break }
            if ($text.Length -gt 8000) { $say = "that reply is $($text.Length) characters, 8000 at most - nothing queued"; break }
            if (-not $Entry.sessionId) { $say = 'that alert is not about a chat - nothing queued'; break }
            $path = if ($job) { $job.path } else { $Entry.path }
            $cwd = if ($job) { $job.cwd } else { $Entry.cwd }
            $row = Get-ChatqRowById -Id $Entry.sessionId -Provider $Entry.provider -Path $path -Cwd $cwd
            if (-not $row) { $say = "that chat is gone - nothing queued"; break }
            $info = Get-ChatqJobInfo $row
            if ($info.Error) { $say = "nothing queued: $($info.Error)"; break }
            $note = ''
            # the old job's mode only if it had one of its own - never one
            # the message names - and never above the cap
            $mode = if ($job -and $job.mode) { [string]$job.mode } else { '' }
            if ($row.Provider -eq 'codex') {
                if ($info.Sandbox -and [string]$info.Sandbox -notin $script:ChatqSafeSandboxes) {
                    $info.Sandbox = 'workspace-write'
                    $info.Mode = 'workspace-write'
                    $note = & $limitNote 'workspace-write'
                }
            }
            else {
                $lim = Limit-ChatqPhoneMode $(if ($mode) { $mode } else { [string]$info.Mode }) $cap
                if ($lim.Capped) { $mode = $lim.Mode; $note = & $limitNote $lim.Mode }
            }
            $how = @{ Row = $row; Info = $info; Prompt = $text; Kind = 'prompt'; Rule = 'phone'; Mode = $mode; NoLinks = $true }
            # The chat lives under its own config dir, whichever one this
            # watcher happened to be started with - the default one ($null)
            # included. From the old job, else from the alert.
            if ($job) { $how['JobHome'] = $job.home }
            elseif ($Entry.ContainsKey('home')) { $how['JobHome'] = $Entry['home'] }
            $r = New-ChatqJob @how
            if ($r.Error) { $say = "nothing queued: $($r.Error)"; break }
            $new = $r.Job
            if ($job -and $job.state -eq 'needs-input') {
                Complete-ChatqJob $job 'skipped' ([pscustomobject]@{ kind = 'skipped'; reason = "answered from the phone with #$($new.seq)" }) 'answered from the phone'
            }
            $about = $new
            $say = "queued #$($new.seq) for $($new.title)$note"
            # a chat you run yourself, still on a permission prompt or a
            # question: the text cannot answer that, and the job waits (defer)
            # until someone at the PC does - so the push says it now, not at 2 h
            if ($live) {
                $held = $false
                try { $held = [bool]@(Get-ChatqLiveSessions $new.home -RegistryOnly | Where-Object { $_.SessionId -eq $new.sessionId -and $_.Status -eq 'waiting' }) }
                catch {}
                if ($held) { $say = "queued #$($new.seq) - it goes once $($new.title) is free: it waits on a prompt at the PC$note" }
            }
        }
        'retry' {
            if (-not $job) { $say = "$n is gone - nothing to retry"; break }
            if ($job.state -notin 'failed', 'needs-input') { $say = "#$($job.seq) is $($job.state) - nothing to retry"; break }
            $note = ''
            $m = ''
            if ($job.provider -eq 'codex') {
                if ($job.sandbox -and [string]$job.sandbox -notin $script:ChatqSafeSandboxes) {
                    Set-ChatqProp $job 'sandbox' 'workspace-write'
                    $note = & $limitNote 'workspace-write'
                }
            }
            else {
                $lim = Limit-ChatqPhoneMode $(if ($job.mode) { [string]$job.mode } else { [string]$job.modeAtQueue }) $cap
                if ($lim.Capped) { $m = $lim.Mode; $note = & $limitNote $lim.Mode }
            }
            $r = Reset-ChatqJob $job $m
            if ($r.Error) { $say = $r.Error; break }
            $say = "#$($job.seq) queued again ($(if ($r.Landed) { 'continue' } else { 'full prompt' }))$note"
        }
        'allow' {
            if (-not $job) { $say = "$n is gone - nothing to allow"; break }
            if ($job.provider -ne 'claude') { $say = 'allow is Claude only - use retry'; break }
            if ($job.state -ne 'needs-input') { $say = "#$($job.seq) is $($job.state) - allow is for a job that needs input"; break }
            $eff = if ($job.mode) { [string]$job.mode } else { [string]$job.modeAtQueue }
            # up to acceptEdits when below it - default, plan, manual, none -
            # and whatever it was, never above the cap
            $want = if ((Get-ChatqModeRank $eff) -lt (Get-ChatqModeRank 'acceptEdits')) { 'acceptEdits' } else { $eff }
            $lim = Limit-ChatqPhoneMode $want $cap
            $r = if ($lim.Mode -ceq $eff) { Reset-ChatqJob $job } else { Reset-ChatqJob $job $lim.Mode }
            if ($r.Error) { $say = $r.Error; break }
            $say = "#$($job.seq) queued again in $($lim.Mode) ($(if ($r.Landed) { 'continue' } else { 'full prompt' }))$(if ($lim.Capped) { " - the phone's limit" })"
        }
        'skip' {
            if (-not $job) { $say = "$n is gone - nothing to skip"; break }
            if ($job.state -eq 'running') { $say = "#$($job.seq) is running - use stop"; break }
            if ($job.state -notin 'queued', 'failed', 'needs-input') { $say = "#$($job.seq) is $($job.state) - nothing to skip"; break }
            Complete-ChatqJob $job 'skipped' ([pscustomobject]@{ kind = 'skipped'; reason = 'skipped from the phone' }) 'skipped from the phone'
            $say = "#$($job.seq) skipped"
            # auto-continue's: its marker stays, so this cut-off is not queued again
            if (Get-ChatField $job 'auto') { $say = Get-ChatqAutoSkipText $job }
        }
        'stop' {
            if (-not $job -or $job.state -ne 'running') { $say = "$n is $(if ($job) { $job.state } else { 'gone' }) - nothing to stop"; break }
            $r = Stop-ChatqJobRun $job
            $say = switch ($r) {
                'cancelling' { "#$($job.seq) stopping" }
                'failed' { "#$($job.seq) marked failed - its watcher was already gone" }
                default { "#$($job.seq) had already ended" }
            }
        }
        'status' { $say = Get-ChatqPhoneStatusReport }
        # Send now, on a usage alert about a reset coming (src/phone-extras.ps1)
        'wake' { $say = Invoke-ChatqReplyWake $Entry }
        'permit' { $say = Invoke-ChatqPermitReply $act $Payload $Entry $Aid $Raw }
        'refuse' { $say = Invoke-ChatqPermitReply $act $Payload $Entry $Aid $Raw }
        # the whole answer again, on the down topic - no push: the page is
        # open and waiting for it (src/phone-board.ps1)
        'read' { return (Invoke-ChatqReadAct $Entry $Aid -Rc $Rc -Quick:$Quick) }
        'ping' {
            $ts = $Payload.ts -as [double]
            $secs = if ($null -ne $ts) { [int][Math]::Round(([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $ts) / 1000) } else { '?' }
            $say = "reply reached $([Environment]::MachineName) after $secs s"
        }
        default {
            Write-ChatqReplyLog "unknown act - ignored"
            return $null
        }
    }
    Write-ChatqReplyLog "-> $say"
    # nothing queued for a chat you run yourself: the answer is about that
    # chat still, so its link can take the prompt that was meant
    $pushAbout = if (-not $about -and $live) { ConvertTo-ChatqLiveJob $Entry } else { $about }
    [void](Send-ChatqAlert 'reply' $say 1 -Loud -Job $pushAbout -Quick:$Quick)
    return [pscustomobject]@{ Act = $act; Feedback = $say; Job = $about }
}

function Get-ChatqPhoneStatusReport {
    # The status line, one line per open job and the usage, short enough for
    # a notification (~700 characters)
    $d = $script:ChatqDot
    $jobs = @(Get-ChatqJobs)
    $blocks = Get-ChatqBlocks
    $eta = Get-ChatqEta $jobs $blocks
    $lines = @(Get-ChatqStatusLine $jobs $blocks)
    foreach ($j in @($jobs | Where-Object { $_.state -in 'queued', 'running', 'needs-input', 'failed' })) {
        $t = [string]$j.title
        if ($t.Length -gt 30) {
            $n = 29
            if ([char]::IsHighSurrogate($t[$n - 1])) { $n-- }
            $t = $t.Substring(0, $n) + $script:ChatqEllipsis
        }
        $s = switch ($j.state) { 'queued' { $eta[$j.id] } 'needs-input' { 'needs you' } default { $j.state } }
        if ($j.state -eq 'running') { $s += Get-ChatqPermitWaitText $j }
        $lines += "#$($j.seq) $t $d $s"
    }
    $use = @(Get-ChatqUsage | ForEach-Object { "$($_.Provider) $(@($_.Parts) -join " $d ")$(if ($_.AsOf) { " (as of $($_.AsOf))" })" })
    if ($use) { $lines += 'usage ' + ($use -join " $d ") }
    # the whole of it, status line and all, cut to 700 - never between the
    # two halves of an emoji in a title
    $text = $lines -join "`n"
    if ($text.Length -gt 700) {
        $n = 699
        if ([char]::IsHighSurrogate($text[$n - 1])) { $n-- }
        $text = $text.Substring(0, $n) + $script:ChatqEllipsis
    }
    return $text
}

#endregion

#region phone: chats you run yourself ------------------------------------------
# The watcher alerts about what it runs, and nothing else: a chat driven in
# VS Code or a terminal never passes through chatq, so the phone never heard
# that one of those waited on you or finished - a Join set up and never a
# push. The overlay reads every open chat's state each pass anyway, and
# tells the phone from there (Update-ChatqLiveAlerts): only while you are
# known to be away, and never from the overlay's own thread - an alert is
# written to data/outbox and a hidden process sends it (Send-ChatqOutbox),
# as Send-ChatqAlert sends any.

function Test-ChatqLiveAlertsOn {
    # config liveAlerts: on unless set to false
    param($Cfg)
    return (-not ($Cfg -and $Cfg.PSObject.Properties['liveAlerts'] -and $Cfg.liveAlerts -eq $false))
}

function Get-ChatqLiveAlertStatusText {
    # One line for chatnotify and the setup dialog: whether the chats you run
    # yourself reach the phone, and what stands in the way when nothing can
    param($Cfg)
    if (-not $Cfg) { $Cfg = Get-ChatqConfig }
    if (-not (Test-ChatqLiveAlertsOn $Cfg)) { return 'off - only what chatq runs reaches the phone' }
    $qm = Get-ChatqQuietMinutes $Cfg
    if ($qm -le 0) { return 'on, but quiet minutes is 0 - you never count as away, so none go' }
    if (-not $script:ChatqIsWindows) { return 'on - but only the Windows overlay sends them' }
    $run = if (-not (Test-ChatqLockHeld $script:ChatOverlayLockPath)) { ' - the overlay is not running, so none go now (chatoverlay)' }
    elseif (Test-ChatqOverlayStale) { ' - the overlay runs an older copy - chatoverlay -Stop, then chatoverlay' }
    else { '' }
    return "on - waiting on you or finished, while you are away $qm min$run"
}

function Get-ChatqOverlayStarted {
    # When the running overlay's process started: the pid data/overlay.pid
    # names, as the OS has it. $null when there is no such file or process,
    # or its start time cannot be read.
    try {
        if (-not (Test-Path -LiteralPath $script:ChatOverlayPidPath)) { return $null }
        $id = ([string](Get-Content -LiteralPath $script:ChatOverlayPidPath -TotalCount 1 -EA Stop)).Trim() -as [int]
        if (-not $id) { return $null }
        $p = Get-Process -Id $id -EA SilentlyContinue
        if ($p) { return $p.StartTime }
    }
    catch {}
    return $null
}

function Test-ChatqOverlayStale {
    # Does the overlay run code older than what is on disk? It loads the
    # script once, at its start, and nothing reloads it - an upgrade leaves
    # the old copy running for days, and ChatVersion may not have moved. So:
    # started before src/phone.ps1 was last written. Not known is not stale.
    $began = Get-ChatqOverlayStarted
    if (-not $began) { return $false }
    try {
        $f = Join-Path (Join-Path $script:ChatRoot 'src') 'phone.ps1'
        if (-not (Test-Path -LiteralPath $f)) { return $false }
        return ($began -lt (Get-Item -LiteralPath $f).LastWriteTime)
    }
    catch { return $false }
}

function ConvertTo-ChatqLiveJob {
    # What a live alert says about its chat, in a job's shape: Send-ChatqAlert,
    # the reply link and the registry take it as they take a job. State
    # 'live' is the link's j=live; no id, no seq, nothing to requeue.
    param($Fields)
    $f = { param($n) $v = Get-ChatField $Fields $n; if ($v) { [string]$v } else { $null } }
    [pscustomobject]@{
        id = $null; seq = $null; sessionId = (& $f 'sessionId'); provider = 'claude'; title = (& $f 'title')
        path = (& $f 'path'); cwd = (& $f 'cwd'); home = (& $f 'home'); state = 'live'; live = $true
    }
}

function Get-ChatqLiveAlertConfig {
    # config.json for a pass of the overlay: looked at every 10 s at most, and
    # read again only once its write time moved. Kept in $Ctx.PhoneCfg.
    param($Ctx, [datetime]$Now)
    $pc = Get-ChatField $Ctx 'PhoneCfg'
    if ($pc -and [Math]::Abs(($Now - $pc.At).TotalSeconds) -lt 10) { return $pc.Cfg }
    $stamp = 0L
    try { if (Test-Path -LiteralPath $script:ChatqConfigPath) { $stamp = [System.IO.File]::GetLastWriteTimeUtc($script:ChatqConfigPath).Ticks } } catch {}
    if (-not $pc -or $pc.Stamp -ne $stamp) { $pc = @{ Stamp = $stamp; Cfg = (Get-ChatqConfig) } }
    $pc.At = $Now
    $Ctx.PhoneCfg = $pc
    return $pc.Cfg
}

function Get-ChatqLiveWaitWhat {
    # What a waiting chat waits for, in a few words: the registry's own
    # waitingFor, and the tool its transcript's last tool call names. $null
    # when neither says.
    param([object[]]$Entries, [string]$Path)
    $wf = $null
    foreach ($e in @($Entries)) {
        $w = Get-ChatField $e 'WaitingFor'
        if ($w -is [string] -and $w.Trim()) { $wf = $w.Trim(); break }
    }
    $tool = $null
    if ($Path) {
        $t = Read-ChatqTail $Path 262144
        if ($t) {
            $m = [regex]::Matches($t, '"type":"tool_use","id":"[^"]*","name":"([^"]+)"')
            if ($m.Count) { $tool = $m[$m.Count - 1].Groups[1].Value }
        }
    }
    if ($tool -eq 'AskUserQuestion') { $tool = 'a question' }
    elseif ($tool -eq 'ExitPlanMode') { $tool = 'the plan' }
    if ($wf -and $tool) { return "$wf ($tool)" }
    if ($wf) { return $wf }
    return $tool
}

function Get-ChatqLiveAlertText {
    # The words of a live alert. needs input: the chat, what it waits for,
    # its folder. done: the chat and the end of the reply, "asks:" before it
    # when it ends on a question - as the watcher's own done alert has it; a
    # turn the limit or a 529 cut off says that instead.
    # -Auto: auto-continue's state for the chat (Get-ChatqAutoState): a
    # continue it queued is said, else why it will not continue it
    param([string]$Event, [string]$Title, [string]$Cwd, [string]$Path, [object[]]$Entries, $Auto)
    $d = $script:ChatqDot
    if ($Event -eq 'needs input') {
        $what = Get-ChatqLiveWaitWhat $Entries $Path
        $t = "$Title $d waiting on you$(if ($what) { ": $what" })"
        $proj = if ($Cwd) { Split-Path ([string]$Cwd).TrimEnd('\', '/') -Leaf } else { '' }
        if ($proj) { $t += " $d $proj" }
        return $t
    }
    $turn = if ($Path) { Get-ChatqLastTurn $Path } else { $null }
    if ($turn -and $turn.Limit -and $Auto -and $Auto.State -in 'armed', 'due') { return "$Title $d stopped by the usage limit $d auto-continues $($Auto.At)" }
    if ($turn -and $turn.Limit) { return "$Title $d stopped by the usage limit$(if ($turn.ResetsAt) { " until $($turn.ResetsAt.ToString('HH:mm'))" })$(if ($Auto -and $Auto.Tag) { " $d $($Auto.Tag)" })" }
    if ($turn -and $turn.Overloaded) { return "$Title $d stopped - Claude was overloaded" }
    $x = ''
    if ($turn -and $turn.Type -eq 'assistant' -and $turn.Text) {
        $ex = Get-ChatqExcerpt ([string]$turn.Text) 200
        if ($ex) { $x = " $d $(if (Test-ChatqAsks ([string]$turn.Text)) { 'asks: ' })`"$ex`"" }
    }
    return "$Title $d finished$x"
}

function Test-ChatqSideTranscript {
    # a side chat's transcript says so on its first line
    param([string]$Path)
    $c = Read-ChatChunk $Path 4096
    if (-not $c -or -not $c.Head) { return $false }
    $nl = $c.Head.IndexOf("`n")
    $first = if ($nl -ge 0) { $c.Head.Substring(0, $nl) } else { $c.Head }
    return ($first -like '*"isSidechain":true*')
}

function Get-ChatqWatchedSessions {
    # The chats the watcher is running a job in right now, by session id: its
    # running jobs - the overlay's list of them when $Ctx has one - and the
    # job state.json names as current
    param($Ctx)
    $out = @{}
    $jobs = if ($Ctx -is [System.Collections.IDictionary] -and $Ctx.Contains('Jobs')) {
        @(foreach ($w in @($Ctx['Jobs'])) { $j = Get-ChatField $w 'Job'; if ($j) { $j } elseif ($w) { $w } })
    }
    else { @(Get-ChatqJobs) }
    foreach ($j in $jobs) { if ($j -and [string]$j.state -eq 'running' -and $j.sessionId) { $out[[string]$j.sessionId] = $true } }
    try {
        $cur = [string](Get-ChatField (Get-ChatqState) 'current')
        if ($cur) {
            $cj = @($jobs | Where-Object { $_ -and $_.id -eq $cur })[0]
            if (-not $cj) { $cj = Find-ChatqJob $cur -Exact }
            if ($cj -and $cj.sessionId) { $out[[string]$cj.sessionId] = $true }
        }
    }
    catch {}
    return $out
}

function Update-ChatqLiveAlerts {
    <#
    The phone told about the chats you run yourself, from each pass of the
    overlay's collector (Invoke-ChatOverlayCycle, the Windows host's only:
    $Ctx.WantPhone) and its -Live registry entries. Two events, the names
    phoneEvents filters by:
      needs input  a chat waiting on you for 20 s - a prompt answered at
                   once never alerts - priority 2
      done         a chat that went from busy to idle and stayed 5 s,
                   priority 1
    Only while you are known to be away (Test-ChatqUserAway): nothing at all
    otherwise, not the toast nor alerts.log - the overlay shows it. A done
    waits for that as long as it can still be news: away is known
    quietMinutes after the last input at most, so one that finished while
    nobody touched the PC is sent then, and one older than that is dropped.
    A needs input waits as long as the chat does. Which window is in front
    counts for nothing: the overlay's blue-dot rule (Test-ChatOverlayInFront)
    means you are looking at it, which holds only while input is recent - and
    then the away gate has already sent nothing, whichever window it was.
    Once away, nobody looks at the window in front; and one Code.exe owns
    every VS Code window, so that rule would silence every VS Code chat for
    good whenever VS Code was left in front. Never about a chat the watcher
    is running a job in, a registry entry that is not interactive or a side
    chat; once per chat and event every 3 minutes at most.
    Its own memory, in $Ctx.PhoneSeen by session id - state, since when, and
    when each event last went - never $Ctx.LastStatus or $Ctx.Unread. The
    first pass only notes what every chat is doing, so an overlay restarted
    with chats already waiting sends nothing; a chat counts only once a
    change has been seen, and a session gone is forgotten. Cheap when idle:
    config.json looked at every 10 s at most (Get-ChatqLiveAlertConfig), and
    nothing more when liveAlerts is off or no phone channel is set. Sending
    is Send-ChatqLiveAlert's. -Now is for the tests. Never throws.
    #>
    param($Ctx, [object[]]$Live, [datetime]$Now = (Get-Date))
    try {
        $cfg = Get-ChatqLiveAlertConfig $Ctx $Now
        $phones = ($cfg.PSObject.Properties['join'] -and $cfg.join) -or ($cfg.PSObject.Properties['ntfy'] -and $cfg.ntfy)
        # off: forgotten, so that on again starts from a quiet first pass
        if (-not $phones -or -not (Test-ChatqLiveAlertsOn $cfg)) { $Ctx.PhoneSeen = $null; return }
        $rank = @{ waiting = 0; busy = 1; idle = 2 }
        $states = @{}
        $mine = @{}
        foreach ($e in @($Live)) {
            if (-not $e) { continue }
            $sid = [string](Get-ChatField $e 'SessionId')
            if (-not $sid) { continue }
            # chatq's own claude -p runs register too, as another kind
            $kind = [string](Get-ChatField $e 'Kind')
            if ($kind -and $kind -ne 'interactive') { continue }
            $s = [string](Get-ChatField $e 'Status')
            $st = if ($s -in 'waiting', 'busy') { $s } else { 'idle' }
            # a chat open in two windows is at the more urgent of the two
            if (-not $states.ContainsKey($sid) -or $rank[$st] -lt $rank[$states[$sid]]) { $states[$sid] = $st }
            if (-not $mine.ContainsKey($sid)) { $mine[$sid] = [System.Collections.Generic.List[object]]::new() }
            $mine[$sid].Add($e)
        }
        $seen = Get-ChatField $Ctx 'PhoneSeen'
        $first = $null -eq $seen
        if ($first) { $seen = @{}; $Ctx.PhoneSeen = $seen }
        foreach ($sid in @($states.Keys)) {
            $m = $seen[$sid]
            if (-not $m) { $seen[$sid] = @{ State = $states[$sid]; Since = $Now; From = $null; Armed = $false; Settled = $false; Last = @{} }; continue }
            if ($m.State -ne $states[$sid]) { $m.From = $m.State; $m.State = $states[$sid]; $m.Since = $Now; $m.Armed = $true; $m.Settled = $false }
        }
        foreach ($k in @($seen.Keys)) { if (-not $states.ContainsKey($k)) { $seen.Remove($k) } }
        if ($first) {
            # the idle clock read once now: its first read compiles C# (5.1
            # starts csc), which on this thread stalls the panel a second or
            # more - as the overlay starts, not at the first finished turn
            $null = Get-ChatqIdleSeconds
            return
        }

        $quiet = Get-ChatqQuietMinutes $cfg
        $away = $null
        $watched = $null
        foreach ($sid in @($states.Keys)) {
            $m = $seen[$sid]
            if (-not $m.Armed -or $m.Settled) { continue }
            $held = ($Now - $m.Since).TotalSeconds
            $ev = $null
            if ($m.State -eq 'waiting' -and $held -ge 20) { $ev = 'needs input' }
            elseif ($m.State -eq 'idle' -and $m.From -eq 'busy' -and $held -ge 5) {
                if ($held -gt $quiet * 60 + 30) { $m.Settled = $true; continue }
                $ev = 'done'
            }
            if (-not $ev) { continue }
            # a turn the limit cut off that auto-continue queued "continue"
            # for: limited, about that job - Don't continue on the page - in
            # place of done (src/auto-continue.ps1)
            $autoJob = if ($ev -eq 'done') { Get-ChatqLiveAutoJob $Ctx $sid } else { $null }
            if ($autoJob) { $ev = 'limited' }
            if (-not (Test-ChatqPhoneEvent $cfg $ev)) { $m.Settled = $true; continue }
            if ($null -eq $away) { $away = [bool](Test-ChatqUserAway $cfg) }
            # at the PC: nothing goes and nothing is settled - you see it there
            # or you do not, and away later can still send it while it is news
            if (-not $away) { continue }
            # the last one of these about this chat too recent: it waits
            $last = $m.Last[$ev]
            if ($last -and [Math]::Abs(($Now - $last).TotalMinutes) -lt 3) { continue }
            if ($null -eq $watched) { $watched = Get-ChatqWatchedSessions $Ctx }
            if ($watched[$sid]) { $m.Settled = $true; Write-ChatOverlayLog "phone: no $ev alert for $sid - the watcher is running a job in it"; continue }
            $e0 = $mine[$sid][0]
            $cwd = [string](Get-ChatField $e0 'Cwd')
            $cfgDir = [string](Get-ChatField $Ctx 'ClaudeHome')
            if (-not $cfgDir) { $cfgDir = $script:ChatClaudeHome }
            # the title as the chat's row has it: what the pass read, else the
            # transcript's own records, else the registry's name for it
            $tx = $null
            $texts = Get-ChatField $Ctx 'Text'
            if ($texts) { $tx = $texts[$sid] }
            $path = if ($tx -and $tx.Path) { [string]$tx.Path } else { Find-ChatOverlayTranscript $cfgDir $cwd $sid }
            if ($path -and (Test-ChatqSideTranscript $path)) { $m.Settled = $true; continue }
            $title = $null
            if ($tx) { foreach ($c in @($tx.CustomTitle, $tx.Sidecar, $tx.AiTitle, $tx.First)) { if ($c) { $title = [string]$c; break } } }
            if (-not $title -and $path) {
                $r = Find-ChatTailRecords $path -Budget 1048576
                $title = if ($r.CustomTitle) { $r.CustomTitle } elseif ($r.AiTitle) { $r.AiTitle } else { $null }
            }
            if (-not $title) { $title = [string](Get-ChatField $e0 'Name') }
            $title = if ($title) { Format-ChatTitle $title 60 } else { 'a chat' }
            # the chat's config dir, $null for the default one - a prompt sent
            # back to it is queued under that dir (Invoke-ChatqReply)
            $default = Join-Path $HOME '.claude'
            $jobHome = if ([string]::Equals($cfgDir.TrimEnd('\', '/'), $default.TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase)) { $null } else { $cfgDir }
            $m.Settled = $true
            $m.Last[$ev] = $Now
            $autoSt = $(if (Get-ChatField $Ctx 'AutoStates') { $Ctx.AutoStates[$sid] } else { $null })
            $alert = [ordered]@{
                event = $ev; text = (Get-ChatqLiveAlertText $ev $title $cwd $path $mine[$sid].ToArray() -Auto $autoSt); priority = $(if ($ev -eq 'needs input') { 2 } elseif ($ev -eq 'limited') { 0 } else { 1 })
                sessionId = $sid; title = $title; cwd = $cwd; path = $path; home = $jobHome
            }
            if ($autoJob) { $alert['jobId'] = [string]$autoJob.id }
            $null = Send-ChatqLiveAlert $alert
            Write-ChatOverlayLog "phone: $ev alert for $sid ($title) handed to the outbox" -Always
        }
    }
    catch {
        try { Write-ChatOverlayLog "phone: $($_.Exception.Message)" } catch {}
    }
}

function Send-ChatqResetAskAlert {
    <#
    The reset ask on the phone (Invoke-ChatOverlayCycle, for the cut-offs
    it announced): one alert, event limited, about several chats and so
    about no one session - the reply page offers Status alone, as for any
    alert about no chat. Answering is at the PC. The gates are
    Update-ChatqLiveAlerts' own: a phone channel set, liveAlerts on,
    phoneEvents letting limited through, and you away. Returns 'wait' while
    you are at the PC (the caller keeps the keys and asks again), 'off' when
    it is not to go or could not, 'sent' once handed to the outbox. Never
    throws.
    #>
    param($Ctx, $Ask, [string[]]$Keys, [datetime]$Now = (Get-Date))
    try {
        if (-not $Ask -or -not @($Keys).Count) { return 'off' }
        $cfg = Get-ChatqLiveAlertConfig $Ctx $Now
        $phones = ($cfg.PSObject.Properties['join'] -and $cfg.join) -or ($cfg.PSObject.Properties['ntfy'] -and $cfg.ntfy)
        if (-not $phones -or -not (Test-ChatqLiveAlertsOn $cfg) -or -not (Test-ChatqPhoneEvent $cfg 'limited')) { return 'off' }
        if (-not (Test-ChatqUserAway $cfg)) { return 'wait' }
        $n = [int]$Ask.Count
        $chats = "$n chat$(if ($n -ne 1) { 's' })"
        $alert = [ordered]@{
            event = 'limited'; priority = 0
            text = "limit over at $(Format-ChatOverlayAskAt $Ask.ResetsAt $Now) $($script:ChatqDot) $chats it cut off can continue - answer on the PC"
            sessionId = $null; title = $null; cwd = $null; path = $null; home = $null
        }
        $null = Send-ChatqLiveAlert $alert
        Write-ChatOverlayLog "phone: reset alert for $chats handed to the outbox" -Always
        return 'sent'
    }
    catch {
        try { Write-ChatOverlayLog "phone: reset alert: $($_.Exception.Message)" } catch {}
        return 'off'
    }
}

function Send-ChatqLiveAlert {
    <#
    One live alert on its way: written to data/outbox/<random>.json - the
    event, the text, the priority and the chat - and one hidden process
    started to send it (Start-ChatqOutboxSender), unless one runs already:
    its lock held means it looks at the folder again before it leaves. The
    overlay's window thread waits on nothing the network does. Returns the
    file's path. $script:ChatqLiveSendSeam (tests) gets the alert in place
    of the process.
    #>
    param($Alert)
    $g = { param($n) Get-ChatField $Alert $n }
    $o = [ordered]@{
        v = 1; at = (Get-ChatqStamp); event = [string](& $g 'event'); text = [string](& $g 'text'); priority = [int](& $g 'priority')
        sessionId = [string](& $g 'sessionId'); title = [string](& $g 'title'); cwd = [string](& $g 'cwd'); path = [string](& $g 'path')
        home = $(if (& $g 'home') { [string](& $g 'home') } else { $null })
    }
    # the job it is about, when there is one: auto-continue's limited alert
    if (& $g 'jobId') { $o['jobId'] = [string](& $g 'jobId') }
    # a usage heads-up's kind (Update-ChatqUsageAlerts): about no chat at all
    if (& $g 'kind') { $o['kind'] = [string](& $g 'kind') }
    New-ChatqDir $script:ChatqOutboxDir
    $f = Join-Path $script:ChatqOutboxDir ((New-ChatqRandomName 16) + '.json')
    Save-ChatqJson $f $o
    if ($script:ChatqLiveSendSeam) { $null = & $script:ChatqLiveSendSeam ([pscustomobject]$o); return $f }   # tests
    if (-not (Test-ChatqLockHeld $script:ChatqOutboxLockPath)) { $null = Start-ChatqOutboxSender }
    return $f
}

function Get-ChatqOutboxLaunch {
    <#
    How the outbox's sender starts: @{ Exe; Args; Command }. Windows
    PowerShell on Windows - every Windows has it - and the PowerShell this
    runs in elsewhere; hidden, no profile, -ExecutionPolicy Bypass for that
    process alone. It dot-sources the script with CHATQ_OVERLAY set, which
    binds no keys and starts no watcher on load, then drops that and
    PSExecutionPolicyPreference - a watcher Send-ChatqAlert starts to listen
    for a reply must not inherit either - and runs Send-ChatqOutbox. The
    provider homes go along, as for the setup dialog, and from pwsh 7 the
    module path is Windows PowerShell's own again (Get-ChatqPhoneSetupLaunch
    says why). A failure to load lands in data/logs/outbox.log.
    #>
    param([string]$Path = $script:ChatqScriptPath)
    $q = { param($s) "'" + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent([string]$s) + "'" }
    $win = [bool]$script:ChatqIsWindows
    $exe = if ($win) { Join-Path $(if ($env:SystemRoot) { $env:SystemRoot } else { 'C:\Windows' }) 'System32\WindowsPowerShell\v1.0\powershell.exe' } else { (Get-Process -Id $PID).Path }
    $pre = ''
    if ($win -and $PSVersionTable.PSEdition -eq 'Core') {
        $pre = "`$env:PSModulePath = [Environment]::GetFolderPath('MyDocuments') + '\WindowsPowerShell\Modules;' + `$env:ProgramFiles + '\WindowsPowerShell\Modules;' + " +
        "`$PSHOME + '\Modules;' + [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine'); "
    }
    $pre += '$env:CHATQ_OVERLAY=''1''; '
    foreach ($n in 'CLAUDE_CONFIG_DIR', 'CODEX_HOME', 'CHATQ_CLAUDE', 'CHATQ_CODEX', 'CHATQ_GH') {
        $v = [Environment]::GetEnvironmentVariable($n)
        if ($v) { $pre += "`$env:$n=$(& $q $v); " }
    }
    $log = Join-Path $script:ChatqLogDir 'outbox.log'
    $drop = "Remove-Item -LiteralPath 'env:PSExecutionPolicyPreference', 'env:CHATQ_OVERLAY' -EA SilentlyContinue"
    $cmd = $pre + "try { . $(& $q $Path); $drop; `$null = Send-ChatqOutbox } catch { try { [void][IO.Directory]::CreateDirectory($(& $q $script:ChatqLogDir)); " +
    "[IO.File]::AppendAllText($(& $q $log), (Get-Date).ToString('o') + '  the sender failed: ' + `$_.Exception.Message + [char]10) } catch {} }"
    $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmd))
    $argv = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass')
    # pwsh off Windows has no window to hide, and says so
    if ($win) { $argv += @('-WindowStyle', 'Hidden') }
    $argv += @('-EncodedCommand', $enc)
    return [pscustomobject]@{ Exe = $exe; Args = $argv; Command = $cmd }
}

function Start-ChatqOutboxSender {
    # the hidden process Get-ChatqOutboxLaunch describes; $false when it
    # could not be started, which the log says
    $l = Get-ChatqOutboxLaunch
    $sp = @{ FilePath = $l.Exe; ArgumentList = $l.Args }
    if ($script:ChatqIsWindows) { $sp['WindowStyle'] = 'Hidden' }
    try { $null = Start-Process @sp; return $true }
    catch { Write-ChatqOutboxLog "the sender could not be started: $($_.Exception.Message)"; return $false }
}

function Write-ChatqOutboxLog {
    # data/logs/outbox.log, rolled at 1 MB: what the sender did with each alert
    param([string]$Text)
    try {
        New-ChatqDir $script:ChatqLogDir
        $p = Join-Path $script:ChatqLogDir 'outbox.log'
        if ((Test-Path -LiteralPath $p) -and (Get-Item -LiteralPath $p).Length -gt 1MB) { Move-Item -LiteralPath $p -Destination "$p.1" -Force }
        [System.IO.File]::AppendAllText($p, "$((Get-Date).ToString('o'))  $($Text -replace '[\r\n]+', ' ')`n", (New-Object System.Text.UTF8Encoding $false))
    }
    catch {}
}

function Send-ChatqOutboxFile {
    # One alert off the outbox: sent through Send-ChatqAlert as about its
    # chat (ConvertTo-ChatqLiveJob), or dropped unsent when it is older than
    # -MaxAgeMinutes or no alert at all; deleted either way. $true when sent.
    param([string]$Path, [int]$MaxAgeMinutes = 30)
    $name = Split-Path $Path -Leaf
    $a = Read-ChatqJson $Path
    $sent = $false
    if (-not $a -or -not (Get-ChatField $a 'event')) { Write-ChatqOutboxLog "${name}: not an alert - dropped" }
    else {
        $at = ConvertTo-ChatqDate (Get-ChatField $a 'at')
        if (-not $at) { $at = try { [System.IO.File]::GetLastWriteTime($Path) } catch { Get-Date } }
        $age = ((Get-Date) - $at).TotalMinutes
        if ($age -gt $MaxAgeMinutes) { Write-ChatqOutboxLog "${name}: $($a.event) dropped unsent - $([int]$age) min old" }
        else {
            # an alert about no chat - a usage heads-up - goes with no job,
            # so its link is jobless (x=1); one with a job goes about that
            # job while it still waits - the link then takes a skip - else
            # about the chat you run yourself
            $about = if (Get-ChatField $a 'sessionId') { ConvertTo-ChatqLiveJob $a } else { $null }
            $jid = [string](Get-ChatField $a 'jobId')
            if ($jid) { $fj = Find-ChatqJob $jid -Exact; if ($fj -and $fj.state -eq 'queued') { $about = $fj } }
            $ok = Send-ChatqAlert ([string]$a.event) ([string]$a.text) ([int]$a.priority) -Job $about -UsageKind ([string](Get-ChatField $a 'kind'))
            $sent = $true
            Write-ChatqOutboxLog "${name}: $($a.event) $(if ($ok) { 'sent' } else { 'not sent' }) - $(@($script:ChatqAlertReport) -join ', ')"
        }
    }
    Remove-Item -LiteralPath $Path -Force -EA SilentlyContinue
    return $sent
}

function Send-ChatqOutbox {
    <#
    The sender: every alert in data/outbox, oldest first, each deleted once
    it went (Send-ChatqOutboxFile), holding data/outbox.lock with no sharing
    all the while - an overlay that finds it held only writes its file. The
    folder is listed again until it is empty, and once more after the lock
    is let go: a file written just before that, by an overlay that still saw
    the lock held, is taken too (the lock again, or left to the sender that
    has it by then). A sender that cannot have the lock leaves at once.
    Returns how many were sent.
    #>
    param([int]$MaxAgeMinutes = 30)
    # quiet hours over with alerts held: the summary first - the overlay
    # starts this sender for that alone (Update-ChatqHeldKick)
    try { if (Test-ChatqHeldWaiting) { $null = Send-ChatqHeldSummary } } catch {}
    $done = @{}
    $n = 0
    $list = {
        @(Get-ChildItem -LiteralPath $script:ChatqOutboxDir -Filter *.json -File -EA SilentlyContinue |
                Where-Object { $_.Name -like '*.json' -and -not $done.ContainsKey($_.Name) } | Sort-Object LastWriteTimeUtc, Name)
    }
    while ($true) {
        $lock = $null
        for ($try = 0; $try -lt 5 -and -not $lock; $try++) {
            try { New-ChatqDir $script:ChatqData; $lock = [System.IO.File]::Open($script:ChatqOutboxLockPath, 'OpenOrCreate', 'ReadWrite', 'None') }
            catch { Start-Sleep -Milliseconds 40 }
        }
        if (-not $lock) { return $n }
        try {
            while ($true) {
                $files = & $list
                if (-not $files.Count) { break }
                foreach ($f in $files) {
                    # once each, whatever happens: a file that cannot be deleted
                    # is not sent again and again
                    $done[$f.Name] = $true
                    try { if (Send-ChatqOutboxFile $f.FullName $MaxAgeMinutes) { $n++ } }
                    catch { Write-ChatqOutboxLog "$($f.Name): $($_.Exception.Message)" }
                }
            }
        }
        finally { $lock.Dispose() }
        if (-not (& $list).Count) { return $n }
    }
}

#endregion

#region phone: Join devices -----------------------------------------------------

function Get-ChatqJoinDevicesUrl {
    param([string]$ApiKey)
    return 'https://joinjoaomgcd.appspot.com/_ah/api/registration/v1/listDevices?apikey=' + [Uri]::EscapeDataString(([string]$ApiKey).Trim())
}

function ConvertFrom-ChatqJoinDevices {
    <#
    Join's listDevices answer as @{ Error; Devices = @(@{ Id; Name; Type;
    Model }) }, with Join's own groups after the devices - the setup dialog
    fetches the JSON itself, off its window's thread, and reads it here.
    #>
    param([string]$Json)
    $groups = @(
        [pscustomobject]@{ Id = 'group.phone'; Name = 'all phones'; Type = 'group'; Model = $null }
        [pscustomobject]@{ Id = 'group.android'; Name = 'all Android'; Type = 'group'; Model = $null }
        [pscustomobject]@{ Id = 'group.all'; Name = 'every device'; Type = 'group'; Model = $null }
    )
    $err = $null
    $list = @()
    try {
        $o = $Json | ConvertFrom-Json
        if (-not $o) { $err = 'Join sent back nothing' }
        elseif ($o.userAuthError) { $err = 'Join refused the API key' }
        elseif (-not $o.success) { $err = if ($o.errorMessage) { [string]$o.errorMessage } else { 'Join did not list the devices' } }
        else {
            $list = @(foreach ($r in @($o.records)) {
                    if ($r -and $r.deviceId) { [pscustomobject]@{ Id = [string]$r.deviceId; Name = [string]$r.deviceName; Type = $r.deviceType; Model = [string]$r.model } }
                })
        }
    }
    catch { $err = 'Join sent back something that is not JSON' }
    [pscustomobject]@{ Error = $err; Devices = @($list) + $groups }
}

function Get-ChatqJoinDevices {
    # the devices on a Join account, for chatnotify -Devices; never throws
    param([string]$ApiKey)
    if (-not ([string]$ApiKey).Trim()) { $r = ConvertFrom-ChatqJoinDevices '{"success":true,"records":[]}'; $r.Error = 'no Join API key'; return $r }
    $url = Get-ChatqJoinDevicesUrl $ApiKey
    try {
        $json = if ($script:ChatqJoinDevicesSeam) { [string](& $script:ChatqJoinDevicesSeam $url) }   # tests
        else {
            Enable-ChatqTls12
            $w = Invoke-WebRequest -Uri $url -Method Get -TimeoutSec 15 -UseBasicParsing
            (New-Object System.Text.UTF8Encoding $false).GetString($w.RawContentStream.ToArray())
        }
    }
    catch {
        $r = ConvertFrom-ChatqJoinDevices '{"success":true,"records":[]}'
        $r.Error = "could not reach Join: $($_.Exception.Message)"
        return $r
    }
    return (ConvertFrom-ChatqJoinDevices $json)
}

#endregion
