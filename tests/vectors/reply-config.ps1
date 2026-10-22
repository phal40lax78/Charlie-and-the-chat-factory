# tests/vectors/reply-config.ps1: native/vectors/reply-config.json, the reply
# block as the poll reads it (native/SPEC.md 3.7): Get-ChatqReplyConfig of
# data/config.json at a fixed clock - On, Wanted, Paired, the opened Topic
# and Key, Master, Server, PairId, PairUntil, Hours - and Get-ChatqPairKey of
# its answer. chatq_core::replyconfig is the native side, run by
# native/crates/chatq-core/tests/reply_config_vectors.rs.
#
# Each case writes data/config.json into Enter-NvData's data/. A secret is
# stored as Protect-ChatqSecret stores one off Windows ({value, protected:
# false}), as a protected text that is no DPAPI blob - which
# Unprotect-ChatqSecret turns into $null, as it does a blob from another
# user - or as {seal: <text>}: sealed by DPAPI on the spot, by
# Protect-ChatqSecret here and by CryptProtectData in the runner, so each
# side opens a blob made for this user in this run and none goes in the file.
# The answer holds the texts opened, which are made up for the vector.

function Get-NvReplyConfigKey {
    # a phone's key as config.json keeps it: bytes 0 to 31 in base64url
    return 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8'
}

function New-NvReplyConfigPlain {
    # a secret as Protect-ChatqSecret writes one where DPAPI is not used
    param($Value, $Protected = $false)
    return [ordered]@{ value = $Value; protected = $Protected }
}

function New-NvReplyConfigCase {
    # one case: the clock at 09:00 UTC in $Zone, config.json from $Config
    # (an object) or $Text (as it is), and a reply block from $Reply when
    # $Config is not given
    param([string]$Name, $Reply, $Config, [string]$Text, [string]$Zone = 'UTC', [int]$Off = 0)
    $in = [ordered]@{ zone = $Zone; utcOffsetMinutes = $Off; now = '2026-10-15T09:00:00.0000000Z' }
    if ($Text) { $in['configText'] = $Text }
    elseif ($null -ne $Config) { $in['config'] = $Config }
    else { $in['config'] = [ordered]@{ reply = $Reply } }
    return [ordered]@{ name = $Name; input = $in }
}

function New-NvReplyConfigReply {
    # a reply block switched on, with a topic and a phone's key, and $Set's
    # fields over those: a $null value drops the field
    param([System.Collections.IDictionary]$Set)
    $rp = [ordered]@{ on = $true; topic = (New-NvReplyConfigPlain 'topic-one'); key = (New-NvReplyConfigPlain (Get-NvReplyConfigKey)) }
    if ($Set) {
        foreach ($k in @($Set.Keys)) {
            if ($null -eq $Set[$k]) { $rp.Remove($k) } else { $rp[$k] = $Set[$k] }
        }
    }
    return $rp
}

function ConvertTo-NvReplyConfigSealed {
    # the config with every {seal: <text>} sealed as Protect-ChatqSecret
    # seals it, as plain data ConvertTo-NvJson writes
    param($V)
    if ($null -eq $V -or $V -is [string] -or $V -is [bool] -or $V -is [ValueType]) { return , $V }
    if ($V.GetType().FullName -eq 'System.Management.Automation.PSCustomObject') {
        $names = @($V.PSObject.Properties | ForEach-Object { $_.Name })
        if ($names.Count -eq 1 -and $names[0] -ceq 'seal') {
            $s = Protect-ChatqSecret ([string]$V.seal)
            if (-not $s.protected) { throw 'Protect-ChatqSecret did not seal: no DPAPI here' }
            return , ([ordered]@{ value = [string]$s.value; protected = $true })
        }
        $o = [ordered]@{}
        foreach ($p in $V.PSObject.Properties) { $o[$p.Name] = ConvertTo-NvReplyConfigSealed $p.Value }
        return , $o
    }
    return , @(foreach ($x in $V) { ConvertTo-NvReplyConfigSealed $x })
}

function Get-NvReplyConfigStamp {
    # a time as the answer gives it: UTC round-trip, or $null
    param($When)
    if ($null -eq $When) { return $null }
    return [datetime]::SpecifyKind($When.ToUniversalTime(), [System.DateTimeKind]::Utc).ToString('o')
}

Register-NvVector -Name 'reply-config' -About 'The reply block as the poll reads it: Get-ChatqReplyConfig (src/phone.ps1) of data/config.json at the clock - on, wanted, paired, topic and key as opened, master in hex, server, pairId, pairUntil, hours - and Get-ChatqPairKey (src/phone.ps1) of its answer as pairKey. A secret is {value, protected: false}, a protected text that is no DPAPI blob (it never opens), or {seal: <text>}, which each side seals by DPAPI for this user before it writes config.json: the vector holds no blob. A file is read as the tool reads it, so a zoneless stamp is UTC to 5.1 and the zone''s wall clock to pwsh 7.' -Cases {
    $key = Get-NvReplyConfigKey
    $ahead = [ordered]@{ id = 'pairidabcd'; expires = '2026-10-15T09:05:00.0000000Z'; key = [ordered]@{ seal = '{"Modulus":"AQAB"}' } }
    $plainAhead = [ordered]@{ id = 'pairidabcd'; expires = '2026-10-15T09:05:00.0000000Z'; key = (New-NvReplyConfigPlain 'pair-key-json') }
    $refused = New-NvReplyConfigPlain '414243' $true

    # --- the block and its switch ---------------------------------------------
    New-NvReplyConfigCase 'no reply block' -Config ([ordered]@{})
    New-NvReplyConfigCase 'on, a topic and a paired key' (New-NvReplyConfigReply)
    New-NvReplyConfigCase 'switched off' (New-NvReplyConfigReply ([ordered]@{ on = $false }))
    New-NvReplyConfigCase 'no on' (New-NvReplyConfigReply ([ordered]@{ on = $null }))
    New-NvReplyConfigCase 'on as the string true' (New-NvReplyConfigReply ([ordered]@{ on = 'true' }))
    New-NvReplyConfigCase 'on as the number 1' (New-NvReplyConfigReply ([ordered]@{ on = 1 }))
    New-NvReplyConfigCase 'on as yes' (New-NvReplyConfigReply ([ordered]@{ on = 'yes' }))
    New-NvReplyConfigCase 'a reply block as a string' -Config ([ordered]@{ reply = 'on' })
    New-NvReplyConfigCase 'a reply block as a list of one' -Config ([ordered]@{ reply = @((New-NvReplyConfigReply ([ordered]@{ hours = 3 }))) })
    New-NvReplyConfigCase 'REPLY and its fields in capitals' -Config ([ordered]@{ REPLY = [ordered]@{ ON = $true; TOPIC = (New-NvReplyConfigPlain 'topic-one'); KEY = (New-NvReplyConfigPlain $key); SERVER = 'https://up.example/' } })

    # --- the secrets ----------------------------------------------------------
    New-NvReplyConfigCase 'a topic and key sealed by DPAPI' (New-NvReplyConfigReply ([ordered]@{ topic = [ordered]@{ seal = 'topic-sealed' }; key = [ordered]@{ seal = $key } }))
    New-NvReplyConfigCase 'a key that will not open' (New-NvReplyConfigReply ([ordered]@{ key = $refused }))
    New-NvReplyConfigCase 'a key that will not open, no DPAPI blob at all' (New-NvReplyConfigReply ([ordered]@{ key = (New-NvReplyConfigPlain 'zz' $true) }))
    New-NvReplyConfigCase 'a key that will not open, a pairing waiting' (New-NvReplyConfigReply ([ordered]@{ key = $refused; pairing = $ahead }))
    New-NvReplyConfigCase 'a topic that will not open' (New-NvReplyConfigReply ([ordered]@{ topic = $refused }))
    New-NvReplyConfigCase 'a topic sealed, a key that will not open' (New-NvReplyConfigReply ([ordered]@{ topic = [ordered]@{ seal = 'topic-sealed' }; key = $refused }))
    New-NvReplyConfigCase 'no topic' (New-NvReplyConfigReply ([ordered]@{ topic = $null }))
    New-NvReplyConfigCase 'a topic as a plain string' (New-NvReplyConfigReply ([ordered]@{ topic = 'topic-one' }))
    New-NvReplyConfigCase 'an empty topic' (New-NvReplyConfigReply ([ordered]@{ topic = (New-NvReplyConfigPlain '') }))
    New-NvReplyConfigCase 'a topic marked protected by the string false' (New-NvReplyConfigReply ([ordered]@{ topic = (New-NvReplyConfigPlain 'topic-one' 'false') }))
    New-NvReplyConfigCase 'no key' (New-NvReplyConfigReply ([ordered]@{ key = $null }))
    New-NvReplyConfigCase 'a key as a plain string' (New-NvReplyConfigReply ([ordered]@{ key = $key }))
    New-NvReplyConfigCase 'a key of 31 bytes' (New-NvReplyConfigReply ([ordered]@{ key = (New-NvReplyConfigPlain $key.Substring(0, 42)) }))
    New-NvReplyConfigCase 'a key of 33 bytes' (New-NvReplyConfigReply ([ordered]@{ key = (New-NvReplyConfigPlain ($key + 'A')) }))
    New-NvReplyConfigCase 'a key of 4n+1 characters' (New-NvReplyConfigReply ([ordered]@{ key = (New-NvReplyConfigPlain ($key + 'AA')) }))
    New-NvReplyConfigCase 'a key whose last bits are not zero' (New-NvReplyConfigReply ([ordered]@{ key = (New-NvReplyConfigPlain ($key.Substring(0, 42) + '9')) }))
    New-NvReplyConfigCase 'a key in plain base64' (New-NvReplyConfigReply ([ordered]@{ key = (New-NvReplyConfigPlain ('+' + $key.Substring(1))) }))
    New-NvReplyConfigCase 'a key padded with =' (New-NvReplyConfigReply ([ordered]@{ key = (New-NvReplyConfigPlain ($key + '=')) }))
    New-NvReplyConfigCase 'a key ending in a newline' (New-NvReplyConfigReply ([ordered]@{ key = (New-NvReplyConfigPlain ($key + "`n")) }))

    # --- the server -----------------------------------------------------------
    New-NvReplyConfigCase 'a server of its own' (New-NvReplyConfigReply ([ordered]@{ server = 'https://ntfy.example:8443' }))
    New-NvReplyConfigCase 'a server with final slashes' (New-NvReplyConfigReply ([ordered]@{ server = 'https://ntfy.example/x///' }))
    New-NvReplyConfigCase 'a server of one slash' (New-NvReplyConfigReply ([ordered]@{ server = '/' }))
    New-NvReplyConfigCase 'an empty server' (New-NvReplyConfigReply ([ordered]@{ server = '' }))
    $nullServer = New-NvReplyConfigReply
    $nullServer['server'] = $null
    New-NvReplyConfigCase 'a server of null' $nullServer
    New-NvReplyConfigCase 'a server as a list of one' (New-NvReplyConfigReply ([ordered]@{ server = @('https://ntfy.example/') }))

    # --- hours ----------------------------------------------------------------
    New-NvReplyConfigCase 'hours 3' (New-NvReplyConfigReply ([ordered]@{ hours = 3 }))
    New-NvReplyConfigCase 'hours 1.5 as a string' (New-NvReplyConfigReply ([ordered]@{ hours = '1.5' }))
    New-NvReplyConfigCase 'hours 0 is 12' (New-NvReplyConfigReply ([ordered]@{ hours = 0 }))
    New-NvReplyConfigCase 'hours -2 is 12' (New-NvReplyConfigReply ([ordered]@{ hours = -2 }))
    New-NvReplyConfigCase 'hours abc is 12' (New-NvReplyConfigReply ([ordered]@{ hours = 'abc' }))
    New-NvReplyConfigCase 'hours true is 1' (New-NvReplyConfigReply ([ordered]@{ hours = $true }))

    # --- the pairing ----------------------------------------------------------
    New-NvReplyConfigCase 'no key, a pairing waiting, its key sealed' (New-NvReplyConfigReply ([ordered]@{ key = $null; pairing = $ahead }))
    New-NvReplyConfigCase 'paired, and a pairing waiting' (New-NvReplyConfigReply ([ordered]@{ pairing = $plainAhead }))
    New-NvReplyConfigCase 'no key, the pairing expired' (New-NvReplyConfigReply ([ordered]@{ key = $null; pairing = [ordered]@{ id = 'pairidabcd'; expires = '2026-10-15T08:55:00.0000000Z'; key = (New-NvReplyConfigPlain 'pair-key-json') } }))
    New-NvReplyConfigCase 'no key, the pairing expiring now' (New-NvReplyConfigReply ([ordered]@{ key = $null; pairing = [ordered]@{ id = 'pairidabcd'; expires = '2026-10-15T09:00:00.0000000Z'; key = (New-NvReplyConfigPlain 'pair-key-json') } }))
    New-NvReplyConfigCase 'no key, a pairing with no id' (New-NvReplyConfigReply ([ordered]@{ key = $null; pairing = [ordered]@{ expires = '2026-10-15T09:05:00.0000000Z'; key = (New-NvReplyConfigPlain 'pair-key-json') } }))
    New-NvReplyConfigCase 'no key, a pairing with an empty id' (New-NvReplyConfigReply ([ordered]@{ key = $null; pairing = [ordered]@{ id = ''; expires = '2026-10-15T09:05:00.0000000Z'; key = (New-NvReplyConfigPlain 'pair-key-json') } }))
    New-NvReplyConfigCase 'no key, a pairing with no expiry' (New-NvReplyConfigReply ([ordered]@{ key = $null; pairing = [ordered]@{ id = 'pairidabcd'; key = (New-NvReplyConfigPlain 'pair-key-json') } }))
    New-NvReplyConfigCase 'no key, an expiry that is no date' (New-NvReplyConfigReply ([ordered]@{ key = $null; pairing = [ordered]@{ id = 'pairidabcd'; expires = 'soon'; key = (New-NvReplyConfigPlain 'pair-key-json') } }))
    New-NvReplyConfigCase 'no key, a pairing id as a number' (New-NvReplyConfigReply ([ordered]@{ key = $null; pairing = [ordered]@{ id = 7; expires = '2026-10-15T09:05:00.0000000Z'; key = (New-NvReplyConfigPlain 'pair-key-json') } }))
    New-NvReplyConfigCase 'no key, ID and KEY in capitals' (New-NvReplyConfigReply ([ordered]@{ key = $null; pairing = [ordered]@{ ID = 'PairIdAbcd'; EXPIRES = '2026-10-15T09:05:00.0000000Z'; KEY = (New-NvReplyConfigPlain 'pair-key-json') } }))
    New-NvReplyConfigCase 'no key, a pairing whose key will not open' (New-NvReplyConfigReply ([ordered]@{ key = $null; pairing = [ordered]@{ id = 'pairidabcd'; expires = '2026-10-15T09:05:00.0000000Z'; key = $refused } }))
    New-NvReplyConfigCase 'no key, a pairing with no key' (New-NvReplyConfigReply ([ordered]@{ key = $null; pairing = [ordered]@{ id = 'pairidabcd'; expires = '2026-10-15T09:05:00.0000000Z' } }))
    New-NvReplyConfigCase 'no key, a pairing key as a plain string' (New-NvReplyConfigReply ([ordered]@{ key = $null; pairing = [ordered]@{ id = 'pairidabcd'; expires = '2026-10-15T09:05:00.0000000Z'; key = 'pair-key-json' } }))
    New-NvReplyConfigCase 'no key, a pairing as a string' (New-NvReplyConfigReply ([ordered]@{ key = $null; pairing = 'pairidabcd' }))
    New-NvReplyConfigCase 'no key, a pairing waiting, switched off' (New-NvReplyConfigReply ([ordered]@{ on = $false; key = $null; pairing = $ahead }))
    New-NvReplyConfigCase 'no key, a pairing waiting, no topic' (New-NvReplyConfigReply ([ordered]@{ topic = $null; key = $null; pairing = $ahead }))
    New-NvReplyConfigCase 'no key, a zoneless pairing expiry east of UTC' (New-NvReplyConfigReply ([ordered]@{ key = $null; pairing = [ordered]@{ id = 'pairidabcd'; expires = '2026-10-15T14:00:00'; key = (New-NvReplyConfigPlain 'pair-key-json') } })) -Zone 'India Standard Time' -Off 330

    # --- config.json as a person edits it -------------------------------------
    # a comment and a trailing comma, which pwsh 7 reads and 5.1 does not
    $lf = "`n"
    $reply = '"reply": {"on": true, "topic": {"value": "topic-one", "protected": false}, "key": {"value": "' + $key + '", "protected": false}'
    New-NvReplyConfigCase 'config.json with a comment and trailing commas' -Text ('{' + $lf + '  // the phone' + $lf + '  ' + $reply + ',},' + $lf + '}')
    New-NvReplyConfigCase 'config.json a list of one' -Text ('[{' + $reply + '}}]')
} -Expect {
    param($In, $Name)
    $null = Enter-NvData $Name
    Use-NvTimeZone ([string]$In.zone) {
        Use-NvClock ([string]$In.now) {
            $rcOff = [System.TimeZoneInfo]::Local.GetUtcOffset((Get-Date)).TotalMinutes
            if ($rcOff -ne [int]$In.utcOffsetMinutes) { throw "$($In.zone) is $rcOff minutes from UTC, not $($In.utcOffsetMinutes)" }
            $rcText = if ($In.PSObject.Properties['configText']) { [string]$In.configText } else { ConvertTo-NvJson (ConvertTo-NvReplyConfigSealed $In.config) }
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $script:ChatqConfigPath) -Force
            [System.IO.File]::WriteAllText($script:ChatqConfigPath, $rcText, (New-Object System.Text.UTF8Encoding $false))
            $rc = Get-ChatqReplyConfig
            $rcPair = Get-ChatqPairKey $rc
            return [ordered]@{
                on = [bool]$rc.On; wanted = [bool]$rc.Wanted; paired = [bool]$rc.Paired
                topic = $(if ($null -eq $rc.Topic) { $null } else { [string]$rc.Topic })
                key = $(if ($null -eq $rc.Key) { $null } else { [string]$rc.Key })
                master = $(if ($null -eq $rc.Master) { $null } else { ConvertTo-NvHex $rc.Master })
                server = [string]$rc.Server
                pairId = $(if ($null -eq $rc.PairId) { $null } else { [string]$rc.PairId })
                pairUntil = (Get-NvReplyConfigStamp $rc.PairUntil)
                hours = [double]$rc.Hours
                pairKey = $(if ($null -eq $rcPair) { $null } else { [string]$rcPair })
            }
        }
    }
}
