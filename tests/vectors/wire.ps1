# tests/vectors/wire.ps1: native/vectors/wire.json, the phone's sealed
# messages as chatqd checks them (native/SPEC.md 2.8): the keys of each
# inbound label (Get-ChatqReplyKeys, Get-ChatqLabelKeys), b64url both ways,
# the pairing's confirmation code (Get-ChatqPairCode), and the sealed check up
# to the MAC (Open-ChatqSealed, through Unprotect-ChatqReplyMessage and
# Unprotect-ChatqComposeMessage) on messages sealed by PowerShell and by
# docs/reply.html's own code, and on broken ones.
#
# The page runs under Node: tests/wire-vectors.js seals and derives with its
# crypto and board blocks, and each case holds what the page made (input.page),
# which its answer must equal. Every key, iv, nonce and time is fixed here, so
# nothing is random. chatqd never decrypts; what PowerShell's decryption made
# of a message that passed the MAC is in the answer as stage 'decrypt' or
# 'ok', a "could not be read: ..." error cut to that, as .NET words it
# differently on each PowerShell.

function Invoke-NvWirePage($Requests) {
    # what docs/reply.html makes of each request (tests/wire-vectors.js), in order
    $node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $node) { throw 'wire.json needs node on PATH: the page''s own code seals its messages (tests/wire-vectors.js)' }
    $dir = Join-Path $script:NvScratch 'wire'
    $null = New-Item -ItemType Directory -Path $dir -Force
    $file = Join-Path $dir 'requests.json'
    [IO.File]::WriteAllText($file, (ConvertTo-NvJson $Requests -Compress), $script:NvUtf8)
    $out = & $node.Source (Join-Path $here 'wire-vectors.js') $file
    if ($LASTEXITCODE -ne 0) { throw "tests/wire-vectors.js failed with exit code $LASTEXITCODE" }
    # Read-NvJson hands a list back whole, as one value
    $got = Read-NvJson (@($out) -join "`n")
    $got = @($got)
    if ($got.Count -ne @($Requests).Count) { throw "tests/wire-vectors.js answered $($got.Count) of $(@($Requests).Count) requests" }
    return , $got
}

function ConvertTo-NvWireHex([byte[]]$Bytes) {
    # ConvertTo-NvHex, with one zero byte still '00' (its -not reads a
    # one-byte array as that byte) and $null kept
    if ($null -eq $Bytes) { return $null }
    return (-join @(foreach ($b in $Bytes) { $b.ToString('x2') }))
}

function Set-NvWirePart([string]$Message, [int]$Index, [string]$Part) {
    # the message with one of its dot-separated parts replaced
    $p = @($Message -split '\.')
    $p[$Index] = $Part
    return ($p -join '.')
}

function Step-NvWireChar([string]$Text, [int]$At) {
    # $Text with the character at $At (counted from the end when negative)
    # one on in the base64url alphabet: in the middle a changed byte, at the
    # end of a part whose last character holds unused bits those bits set
    $abc = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_'
    $i = if ($At -lt 0) { $Text.Length + $At } else { $At }
    $c = $abc[($abc.IndexOf($Text[$i]) + 1) % 64]
    return $Text.Substring(0, $i) + $c + $Text.Substring($i + 1)
}

function New-NvWireSealed([byte[]]$Master, [string]$Label, [string]$Prefix, [string]$Id, [byte[]]$Iv, [byte[]]$Ct) {
    # a message sealed by hand: any ciphertext, under the MAC that checks out
    $ks = Get-ChatqLabelKeys $Master $Label $Id
    $head = $Prefix + '.' + $Id + '.' + (ConvertTo-ChatqB64Url $Iv) + '.' + (ConvertTo-ChatqB64Url $Ct)
    return $head + '.' + (ConvertTo-ChatqB64Url (Get-ChatqHmac $ks.Mac ($script:NvUtf8.GetBytes($head))))
}

function New-NvWireOpen([string]$Name, [string]$Label, $Master, $Message) {
    return [ordered]@{ name = "open $Name"; input = [ordered]@{ op = 'open'; label = $Label; master = $Master; message = $Message } }
}

function Get-NvWireOpened($R, $Id) {
    # an Unprotect-Chatq*Message answer as the vector holds it: how far it
    # got, its error, and the id once it got to the MAC
    $e = $R.Error
    if ($null -ne $e -and ([string]$e).StartsWith('could not be read: ', [StringComparison]::Ordinal)) { $e = 'could not be read: ...' }
    return [ordered]@{ stage = [string]$R.Stage; error = $e; id = $Id }
}

Register-NvVector -Name 'wire' -About 'The phone''s sealed messages as chatqd checks them (SPEC 2.8): keys per inbound label, b64url both ways, the confirmation code, and Open-ChatqSealed''s check up to the MAC, on messages sealed by PowerShell and by docs/reply.html itself (tests/wire-vectors.js; input.page is the page''s answer, which PowerShell''s must equal) and on broken ones. An open answer is how far Unprotect-ChatqReplyMessage or Unprotect-ChatqComposeMessage got: stage format or mac is refused before the MAC checks out, decrypt or ok is past it, which is all chatqd decides; a decryption''s "could not be read" text is cut to "could not be read: ...". The prefix is compared as -cne compares, linguistically, so a character the collation gives no weight to passes, and which those are differs by edition.' -Cases {
    $d1 = '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'
    $d2 = 'f0e1d2c3b4a5968778695a4b3c2d1e0f00112233445566778899aabbccddeeff'
    $d65 = ConvertTo-NvWireHex ([byte[]](0..64))
    $iv1 = '101112131415161718191a1b1c1d1e1f'
    $iv2 = 'a0a1a2a3a4a5a6a7a8a9aaabacadaeaf'
    $key1 = ConvertTo-ChatqB64Url (ConvertFrom-NvHex $d1)
    $key2 = ConvertTo-ChatqB64Url (ConvertFrom-NvHex $d2)
    $zero = 'AAAAAAAAAAAAAAAAAAAAAA'
    $ts = [long]1790000000000
    # a D whose code's number has its top bit set: the first byte that,
    # repeated, gives one
    $dTop = $null
    foreach ($b in 1..255) {
        $try = [byte[]](@([byte]$b) * 32)
        if ((Get-ChatqHmac $try ($script:NvUtf8.GetBytes('chatq-confirm')))[0] -ge 128) { $dTop = ConvertTo-NvWireHex $try; break }
    }
    $keySpecs = @(
        @{ N = 'the reply fixture''s D and aid'; D = $d1; L = 'chatq-alert:'; I = 'abcdefghij' }
        @{ N = 'the compose fixture''s D and cid'; D = $d1; L = 'chatq-phone:'; I = 'klmnopqrst' }
        @{ N = 'another D and aid'; D = $d2; L = 'chatq-alert:'; I = 'mnopqr2345' }
        @{ N = 'that aid under the other label'; D = $d2; L = 'chatq-phone:'; I = 'mnopqr2345' }
        @{ N = 'an id ending in a line feed'; D = $d1; L = 'chatq-alert:'; I = "abcdefghij`n" }
        @{ N = 'an id in Hangul, as UTF-8'; D = $d1; L = 'chatq-alert:'; I = ([string][char]0xD55C + [char]0xAE00) }
        @{ N = 'an empty id'; D = $d1; L = 'chatq-phone:'; I = '' }
        @{ N = 'a 65-byte key, longer than a SHA-256 block'; D = $d65; L = 'chatq-alert:'; I = 'abcdefghij' }
        @{ N = 'a 1-byte key'; D = '2a'; L = 'chatq-phone:'; I = 'klmnopqrst' }
    )
    $codeSpecs = @(
        @{ N = 'the pairing fixture''s D'; D = $d1 }
        @{ N = 'another D'; D = $d2 }
        @{ N = 'a D whose number has its top bit set'; D = $dTop }
    )
    $b64Specs = @('', '00', 'ff', 'fb', 'fbff', 'fbefbe', '0001', '000102', '00010203', '0001020304', 'f8ff00')
    $unb64Specs = @('', 'A', 'AA', 'AQ', 'AR', 'AB', 'AAA', 'AAE', 'AAF', 'AAAA', 'AAAAA', 'AAAAAA', '__', '_w', '-_8', '-_-_',
        'AA==', 'AA=', '+/', 'AA AA', "AAAA`n", "AAA`n", "AA`n", "`n", "AAAA`r`n", ('AA' + [char]0xC0))
    $ko = -join @([char]0xD55C, [char]0xAE00, [char]0xB85C, ' ', [char]0xB2F5, [char]0xD574, [char]0xC694)
    $sealSpecs = @(
        @{ N = 'chatq1: a reply in Hangul'; R = [ordered]@{ op = 'reply'; key = $key1; aid = 'abcdefghij'; act = 'prompt'; text = $ko; iv = $iv1; nonce = $zero; ts = $ts } }
        @{ N = 'chatq1: a permission answer with its h'; R = [ordered]@{ op = 'reply'; key = $key1; aid = 'abcdefghij'; act = 'allow'; text = ''; iv = $iv1; nonce = $zero; ts = $ts; h = 'Ab3_Ab3_Ab3_Ab3_Ab3_Ab' } }
        @{ N = 'chatq1: an answer to a question'; R = [ordered]@{ op = 'answer'; key = $key1; aid = 'abcdefghij'; x = [ordered]@{ rid = 'r2d2c3p0q1'; qh = 'Qh1_Qh1_Qh1_Qh1_Qh1_Qh'; a = @(0, 2); o = 'and this' }; iv = $iv2; nonce = $zero; ts = $ts } }
        @{ N = 'chatq1: a v2 payload'; R = [ordered]@{ op = 'payload'; key = $key1; aid = 'abcdefghij'; payload = '{"v":2,"act":"prompt","text":"paired","nonce":"BBBBBBBBBBBBBBBBBBBBBB","ts":1790000000001}'; iv = $iv1 } }
        @{ N = 'chatq1: a v4 payload, past the MAC and refused after'; R = [ordered]@{ op = 'payload'; key = $key1; aid = 'abcdefghij'; payload = '{"v":4,"act":"prompt"}'; iv = $iv1 } }
        @{ N = 'chatq1: a payload that is no JSON'; R = [ordered]@{ op = 'payload'; key = $key1; aid = 'abcdefghij'; payload = 'hello'; iv = $iv1 } }
        @{ N = 'chatq1: a long text, many blocks'; R = [ordered]@{ op = 'reply'; key = $key1; aid = 'abcdefghij'; act = 'prompt'; text = ('x' * 1000); iv = $iv1; nonce = $zero; ts = $ts } }
        @{ N = 'chatq1: another D, aid and iv'; R = [ordered]@{ op = 'reply'; key = $key2; aid = 'mnopqr2345'; act = 'continue'; text = ''; iv = $iv2; nonce = 'CCCCCCCCCCCCCCCCCCCCCC'; ts = $ts } }
        @{ N = 'chatq1: an aid ending in a line feed'; R = [ordered]@{ op = 'reply'; key = $key1; aid = "abcdefghij`n"; act = 'prompt'; text = 'lf'; iv = $iv1; nonce = $zero; ts = $ts } }
        @{ N = 'chatq3c: send, the compose fixture'; R = [ordered]@{ op = 'compose'; key = $key1; act = 'send'; x = [ordered]@{ h = 'k3m2qa'; id = '1a2b3c4d'; text = ('yes, commit it ' + [char]0xD55C + [char]0xAE00) }; cid = 'klmnopqrst'; iv = $iv1; nonce = $zero; ts = $ts } }
        @{ N = 'chatq3c: new'; R = [ordered]@{ op = 'compose'; key = $key1; act = 'new'; x = [ordered]@{ h = 'k3m2qa'; name = 'docs'; text = 'start a chat' }; cid = 'klmnopqrst'; iv = $iv2; nonce = $zero; ts = $ts } }
        @{ N = 'chatq3c: stop'; R = [ordered]@{ op = 'compose'; key = $key1; act = 'stop'; x = [ordered]@{ h = 'k3m2qa'; n = 3 }; cid = 'klmnopqrst'; iv = $iv1; nonce = $zero; ts = $ts } }
        @{ N = 'chatq3c: read'; R = [ordered]@{ op = 'compose'; key = $key1; act = 'read'; x = [ordered]@{ h = 'k3m2qa' }; cid = 'klmnopqrst'; iv = $iv1; nonce = $zero; ts = $ts } }
        @{ N = 'chatq3c: answer'; R = [ordered]@{ op = 'compose'; key = $key1; act = 'answer'; x = [ordered]@{ h = 'k3m2qa'; id = '1a2b3c4d'; rid = 'r2d2c3p0q1'; qh = 'Qh1_Qh1_Qh1_Qh1_Qh1_Qh'; a = @(1); o = '' }; cid = 'klmnopqrst'; iv = $iv1; nonce = $zero; ts = $ts } }
        @{ N = 'chatq3c: a v1 payload, past the MAC and refused after'; R = [ordered]@{ op = 'composed'; key = $key1; cid = 'klmnopqrst'; payload = '{"v":1,"act":"send"}'; iv = $iv1 } }
        @{ N = 'chatq3c: another D, cid and iv'; R = [ordered]@{ op = 'compose'; key = $key2; act = 'continue'; x = [ordered]@{ h = 'zz22yy' }; cid = 'zz22yy33xx'; iv = $iv2; nonce = 'CCCCCCCCCCCCCCCCCCCCCC'; ts = $ts } }
    )

    # everything the page is asked, in one run of Node
    $req = New-Object System.Collections.Generic.List[object]
    foreach ($s in $keySpecs) { $req.Add([ordered]@{ op = 'keys'; d = $s.D; label = $s.L; id = $s.I }) }
    foreach ($s in $codeSpecs) { $req.Add([ordered]@{ op = 'code'; d = $s.D }) }
    foreach ($s in $b64Specs) { $req.Add([ordered]@{ op = 'b64'; hex = $s }) }
    foreach ($s in $unb64Specs) { $req.Add([ordered]@{ op = 'unb64'; text = $s }) }
    foreach ($s in $sealSpecs) { $req.Add($s.R) }
    $page = Invoke-NvWirePage $req.ToArray()
    $at = 0

    foreach ($s in $keySpecs) {
        [ordered]@{ name = "keys: $($s.N)"; input = [ordered]@{ op = 'keys'; master = $s.D; label = $s.L; id = $s.I; page = $page[$at] } }
        $at++
    }
    foreach ($s in $codeSpecs) {
        [ordered]@{ name = "code: $($s.N)"; input = [ordered]@{ op = 'code'; d = $s.D; page = $page[$at] } }
        $at++
    }
    foreach ($s in $b64Specs) {
        [ordered]@{ name = "b64: '$s'"; input = [ordered]@{ op = 'b64'; hex = $s; page = $page[$at] } }
        $at++
    }
    $i = 0
    foreach ($s in $unb64Specs) {
        [ordered]@{ name = "unb64 $i"; input = [ordered]@{ op = 'unb64'; text = $s; page = $page[$at] } }
        $at++
        $i++
    }
    $sealed = @{}
    foreach ($s in $sealSpecs) {
        $r = $s.R
        $phone = $r.op -eq 'compose' -or $r.op -eq 'composed'
        $sealed[$s.N] = $page[$at].message
        [ordered]@{ name = "seal $($s.N)"; input = [ordered]@{
                op = 'seal'; label = $(if ($phone) { 'chatq-phone:' } else { 'chatq-alert:' }); key = $r.key
                id = $(if ($phone) { $r.cid } else { $r.aid }); iv = $r.iv; payload = $page[$at].payload; page = $page[$at].message
            }
        }
        $at++
    }

    # broken messages, each made from a good one of its kind
    $d1Bytes = ConvertFrom-NvHex $d1
    $iv1Bytes = ConvertFrom-NvHex $iv1
    $short = $d1.Substring(0, 62)
    $ws = " `t`r`n"
    $netWs = [string][char]0xA0 + [char]0x3000 + [char]0x85 + [char]0x2028
    foreach ($k in @(
            @{ Tag = 'chatq1'; Label = 'chatq-alert:'; Msg = $sealed['chatq1: a reply in Hangul']; Other = 'chatq3c' }
            @{ Tag = 'chatq3c'; Label = 'chatq-phone:'; Msg = $sealed['chatq3c: send, the compose fixture']; Other = 'chatq1' })) {
        $t = $k.Tag
        $L = $k.Label
        $m = $k.Msg
        $p = @($m -split '\.')
        $ctBytes = ConvertFrom-ChatqB64Url $p[3]
        $macBytes = ConvertFrom-ChatqB64Url $p[4]
        New-NvWireOpen "${t}: the MAC's last character one on, its unused bits set: the same MAC" $L $d1 (Set-NvWirePart $m 4 (Step-NvWireChar $p[4] -1))
        New-NvWireOpen "${t}: the iv's last character one on: the same iv, but the MAC covers the text" $L $d1 (Set-NvWirePart $m 2 (Step-NvWireChar $p[2] -1))
        New-NvWireOpen "${t}: one MAC character changed" $L $d1 (Set-NvWirePart $m 4 (Step-NvWireChar $p[4] 10))
        New-NvWireOpen "${t}: one ciphertext character changed" $L $d1 (Set-NvWirePart $m 3 (Step-NvWireChar $p[3] 10))
        New-NvWireOpen "${t}: another well-formed id" $L $d1 (Set-NvWirePart $m 1 'bcdefghijk')
        New-NvWireOpen "${t}: under another D" $L $d2 $m
        New-NvWireOpen "${t}: with no D" $L $null $m
        New-NvWireOpen "${t}: with a D of 31 bytes" $L $short $m
        New-NvWireOpen "${t}: with an empty D" $L '' $m
        New-NvWireOpen "${t}: the MAC a character short, 31 bytes" $L $d1 (Set-NvWirePart $m 4 $p[4].Substring(0, 42))
        New-NvWireOpen "${t}: the MAC two characters short, len%4 = 1" $L $d1 (Set-NvWirePart $m 4 $p[4].Substring(0, 41))
        New-NvWireOpen "${t}: the iv a character short, len%4 = 1" $L $d1 (Set-NvWirePart $m 2 $p[2].Substring(0, 21))
        New-NvWireOpen "${t}: an iv of 15 bytes" $L $d1 (Set-NvWirePart $m 2 (ConvertTo-ChatqB64Url (ConvertFrom-NvHex $iv1.Substring(0, 30))))
        New-NvWireOpen "${t}: an iv of 17 bytes" $L $d1 (Set-NvWirePart $m 2 (ConvertTo-ChatqB64Url (ConvertFrom-NvHex ($iv1 + '20'))))
        New-NvWireOpen "${t}: an empty ciphertext" $L $d1 (Set-NvWirePart $m 3 '')
        New-NvWireOpen "${t}: a ciphertext of 17 bytes" $L $d1 (Set-NvWirePart $m 3 (ConvertTo-ChatqB64Url ([byte[]]$ctBytes[0..16])))
        New-NvWireOpen "${t}: a MAC of 33 bytes" $L $d1 (Set-NvWirePart $m 4 (ConvertTo-ChatqB64Url ([byte[]]($macBytes + [byte]0))))
        New-NvWireOpen "${t}: the iv padded with =" $L $d1 (Set-NvWirePart $m 2 ($p[2] + '=='))
        New-NvWireOpen "${t}: a + in the MAC, standard base64" $L $d1 (Set-NvWirePart $m 4 ($p[4].Substring(0, 5) + '+' + $p[4].Substring(6)))
        New-NvWireOpen "${t}: a line feed after the iv" $L $d1 (Set-NvWirePart $m 2 ($p[2] + "`n"))
        New-NvWireOpen "${t}: four parts" $L $d1 (@($p[0..3]) -join '.')
        New-NvWireOpen "${t}: six parts" $L $d1 ($m + '.AAAA')
        New-NvWireOpen "${t}: a dot at the end" $L $d1 ($m + '.')
        New-NvWireOpen "${t}: the prefix in capitals" $L $d1 (Set-NvWirePart $m 0 $p[0].ToUpperInvariant())
        New-NvWireOpen "${t}: the other kind's prefix" $L $d1 (Set-NvWirePart $m 0 $k.Other)
        New-NvWireOpen "${t}: the id in capitals" $L $d1 (Set-NvWirePart $m 1 $p[1].ToUpperInvariant())
        New-NvWireOpen "${t}: an id of 9 letters" $L $d1 (Set-NvWirePart $m 1 $p[1].Substring(0, 9))
        New-NvWireOpen "${t}: an id of 11 letters" $L $d1 (Set-NvWirePart $m 1 ($p[1] + 'a'))
        New-NvWireOpen "${t}: an id with a 1, no base32" $L $d1 (Set-NvWirePart $m 1 ($p[1].Substring(0, 9) + '1'))
        New-NvWireOpen "${t}: a line feed after the id, past the format to the MAC" $L $d1 (Set-NvWirePart $m 1 ($p[1] + "`n"))
        New-NvWireOpen "${t}: CR LF after the id" $L $d1 (Set-NvWirePart $m 1 ($p[1] + "`r`n"))
        New-NvWireOpen "${t}: spaces, tabs and line breaks around" $L $d1 ($ws + $m + $ws)
        New-NvWireOpen "${t}: U+00A0, U+3000, U+0085 and U+2028 around, which .NET trims" $L $d1 ($netWs + $m + $netWs)
        New-NvWireOpen "${t}: U+FEFF in front, no white space to .NET" $L $d1 ([string][char]0xFEFF + $m)
        New-NvWireOpen "${t}: U+200B at the end, no white space to .NET" $L $d1 ($m + [char]0x200B)
        New-NvWireOpen "${t}: U+180E in front, no white space to .NET" $L $d1 ([string][char]0x180E + $m)
        # -cne compares the prefix linguistically: a character the collation
        # gives no weight to is passed over, and which those are differs
        # between 5.1 (NLS) and pwsh 7 (ICU)
        foreach ($cp in 0x0000, 0x00AD, 0x200D, 0xFEFF, 0x200B, 0x180E, 0x007F, 0x0378, 0xE0001) {
            $ch = [char]::ConvertFromUtf32($cp)
            New-NvWireOpen ("${t}: U+{0:X4} inside the prefix" -f $cp) $L $d1 (Set-NvWirePart $m 0 ($p[0].Substring(0, 4) + $ch + $p[0].Substring(4)))
        }
        # and pwsh 7 takes another script's digit for the prefix's own, which
        # 5.1 does not: Arabic-Indic, Devanagari and Osmanya are the same digit
        # there, fullwidth, superscript and mathematical bold are not
        $dg = [int][string]$p[0][5]
        foreach ($cp in (0x0660 + $dg), (0x0966 + $dg), (0x104A0 + $dg), (0xFF10 + $dg), $(if ($dg -eq 1) { 0x00B9 } else { 0x00B3 }), (0x1D7CE + $dg)) {
            $ch = [char]::ConvertFromUtf32($cp)
            New-NvWireOpen ("${t}: U+{0:X4} for its {1}" -f $cp, $dg) $L $d1 (Set-NvWirePart $m 0 ($p[0].Substring(0, 5) + $ch + $p[0].Substring(6)))
        }
        New-NvWireOpen "${t}: bad encoding with no D, the encoding checked first" $L $null (Set-NvWirePart $m 4 $p[4].Substring(0, 41))
        New-NvWireOpen "${t}: a wrong prefix with no D" $L $null (Set-NvWirePart $m 0 $k.Other)
        New-NvWireOpen "${t}: an empty id part" $L $d1 (Set-NvWirePart $m 1 '')
    }
    New-NvWireOpen 'chatq1: empty' 'chatq-alert:' $d1 ''
    New-NvWireOpen 'chatq1: white space only' 'chatq-alert:' $d1 " `t "
    New-NvWireOpen 'chatq1: null' 'chatq-alert:' $d1 $null
    New-NvWireOpen 'chatq3c: null' 'chatq-phone:' $d1 $null
    New-NvWireOpen 'chatq1: a chatq3c message given the chatq1 prefix, its MAC the phone label''s' 'chatq-alert:' $d1 (Set-NvWirePart $sealed['chatq3c: send, the compose fixture'] 0 'chatq1')
    $phoneKeys = Get-ChatqLabelKeys $d1Bytes 'chatq-phone:' 'abcdefghij'
    New-NvWireOpen 'chatq1: sealed under the chatq-phone: label' 'chatq-alert:' $d1 (Protect-ChatqSealed $phoneKeys 'chatq1' 'abcdefghij' ($script:NvUtf8.GetBytes('{"v":1,"act":"prompt","text":"x","nonce":"AAAAAAAAAAAAAAAAAAAAAA","ts":1790000000000}')) $iv1Bytes)
    New-NvWireOpen 'chatq1: a MAC that checks out over a ciphertext that does not decrypt' 'chatq-alert:' $d1 (New-NvWireSealed $d1Bytes 'chatq-alert:' 'chatq1' 'abcdefghij' $iv1Bytes (New-Object byte[] 32))
    New-NvWireOpen 'chatq3c: a MAC that checks out over a ciphertext that does not decrypt' 'chatq-phone:' $d1 (New-NvWireSealed $d1Bytes 'chatq-phone:' 'chatq3c' 'klmnopqrst' $iv1Bytes (New-Object byte[] 32))
} -Expect {
    param($In, $Name)
    switch ([string]$In.op) {
        'keys' {
            $m = ConvertFrom-NvHex $In.master
            $ks = Get-ChatqLabelKeys $m $In.label $In.id
            $out = [ordered]@{ k = (ConvertTo-NvWireHex $ks.K); enc = (ConvertTo-NvWireHex $ks.Enc); mac = (ConvertTo-NvWireHex $ks.Mac) }
            if ($In.label -ceq 'chatq-alert:') {
                $rk = Get-ChatqReplyKeys $m $In.id
                $same = [ordered]@{ k = (ConvertTo-NvWireHex $rk.K); enc = (ConvertTo-NvWireHex $rk.Enc); mac = (ConvertTo-NvWireHex $rk.Mac) }
                if ((ConvertTo-NvJson $same -Compress) -cne (ConvertTo-NvJson $out -Compress)) { throw 'Get-ChatqReplyKeys and Get-ChatqLabelKeys derive different keys' }
            }
            if ((ConvertTo-NvJson $out -Compress) -cne (ConvertTo-NvJson $In.page -Compress)) { throw "PowerShell derives $(ConvertTo-NvJson $out -Compress), the page $(ConvertTo-NvJson $In.page -Compress)" }
            return $out
        }
        'code' {
            $d = ConvertFrom-NvHex $In.d
            $c = Get-ChatqPairCode $d
            if ($c -cne [string]$In.page) { throw "PowerShell's code is $c, the page's $($In.page)" }
            return [ordered]@{ code = $c; spaced = (Get-ChatqPairCode $d -Spaced) }
        }
        'b64' {
            $t = ConvertTo-ChatqB64Url (ConvertFrom-NvHex $In.hex)
            if ($t -cne [string]$In.page) { throw "PowerShell writes '$t', the page '$($In.page)'" }
            return $t
        }
        'unb64' {
            $b = ConvertFrom-ChatqB64Url $In.text
            $got = if ($null -eq $b) { $null } else { ConvertTo-NvWireHex $b }
            if ($got -cne $In.page) { throw "PowerShell reads $(ConvertTo-NvJson $got), the page $(ConvertTo-NvJson $In.page)" }
            return $got
        }
        'seal' {
            $iv = ConvertFrom-NvHex $In.iv
            $master = ConvertFrom-ChatqB64Url $In.key
            if ($In.label -ceq 'chatq-alert:') {
                $msg = Protect-ChatqReplyMessage -Key $In.key -Aid $In.id -Iv $iv -Payload $In.payload
                $r = Unprotect-ChatqReplyMessage $msg $master
                $id = $r.Aid
            }
            else {
                $msg = Protect-ChatqComposeMessage -Key $In.key -Cid $In.id -Payload $In.payload -Iv $iv
                $r = Unprotect-ChatqComposeMessage $msg $master
                $id = $r.Cid
            }
            if ($msg -cne $In.page) { throw "PowerShell seals $msg, the page $($In.page)" }
            return [ordered]@{ message = $msg; opened = (Get-NvWireOpened $r $id) }
        }
        'open' {
            $master = if ($null -eq $In.master) { $null } else { ConvertFrom-NvHex $In.master }
            if ($In.label -ceq 'chatq-alert:') {
                $r = Unprotect-ChatqReplyMessage $In.message $master
                return (Get-NvWireOpened $r $r.Aid)
            }
            $r = Unprotect-ChatqComposeMessage $In.message $master
            return (Get-NvWireOpened $r $r.Cid)
        }
        default { throw "no such op: $($In.op)" }
    }
}
