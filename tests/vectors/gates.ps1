# tests/vectors/gates.ps1: native/vectors/gates.json (native/SPEC.md 6.1).
# The cheap tests the watcher's loop asks before it acts, each run as the
# loop runs it, against files in a data/ of the case's own:
#   replyOpen    Test-ChatqReplyOpen: is the watcher to keep listening?
#   held         Test-ChatqHeldWaiting: held.jsonl, or a held-*.sending a
#                sender claimed more than 10 minutes ago
#   heldSummary  Send-ChatqHeldSummary as far as its claim: something held,
#                its last failed push 5 minutes old or more, and now outside
#                quiet hours (Get-ChatqQuietHours, Test-ChatqQuietNow)
#   auto         Test-ChatqAutoWanted: the switch on, or a chat set to always
#   soon         Send-ChatqUsageSoon's gate: the time the loop wakes for a
#                soon alert, which lanes are due one now (the process's own
#                memory of them), and which then go (data/usage-alerts.json).
#                The alert itself is stubbed: only that it was sent is seen
#   route        SPEC 1.4's rule: an alert Send-ChatqAlert registers as
#                answerable (not -NoReply, and Get-ChatqReplyConfig's Links),
#                with every gate before the registration held open and every
#                channel stubbed
#   pollSeconds  Get-ChatqReplyPollSeconds, in the loop and in a run
#   listenText   Get-ChatqReplyListenText under a culture, with that
#                culture's time separator, which the launcher hands chatqd
#
# A file is read back as the tool reads it, so each PowerShell's own JSON
# reader makes its dates: a stamp with no zone is UTC to 5.1 and the zone's
# wall clock to pwsh 7. Zones with no DST, and their offsets in
# utcOffsetMinutes, so the Rust runner needs no zone database. Every case
# runs under en-US unless it names a culture.

function New-NvGatesCase {
    # one case: $Fn, the clock at 09:00 UTC in $Zone, and the rest of its input
    param([string]$Name, [string]$Fn, [System.Collections.IDictionary]$More, [string]$Zone = 'UTC', [int]$Off = 0)
    $in = [ordered]@{ fn = $Fn; zone = $Zone; utcOffsetMinutes = $Off; now = '2026-10-15T09:00:00.0000000Z' }
    foreach ($k in $More.Keys) { $in[$k] = $More[$k] }
    return [ordered]@{ name = $Name; input = $in }
}

function Get-NvGatesStamp {
    # a time as the answer gives it: UTC round-trip, or $null (Kind set by
    # hand, as tests/vectors/due.ps1 says why)
    param($When)
    if ($null -eq $When) { return $null }
    return [datetime]::SpecifyKind($When.ToUniversalTime(), [System.DateTimeKind]::Utc).ToString('o')
}

function Get-NvGatesKey {
    # a phone's key as config.json keeps it: bytes 0 to 31 in base64url
    return 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8'
}

function New-NvGatesSecret {
    # a secret as Protect-ChatqSecret writes one where DPAPI is not used
    param($Value, $Protected = $false)
    return [ordered]@{ value = $Value; protected = $Protected }
}

function New-NvGatesReply {
    # a reply block switched on, with a topic and a phone's key, and $Set's
    # fields over those: a $null value drops the field
    param([System.Collections.IDictionary]$Set)
    $rp = [ordered]@{ on = $true; topic = (New-NvGatesSecret 't1'); key = (New-NvGatesSecret (Get-NvGatesKey)) }
    if ($Set) {
        foreach ($k in @($Set.Keys)) {
            if ($null -eq $Set[$k]) { $rp.Remove($k) } else { $rp[$k] = $Set[$k] }
        }
    }
    return $rp
}

function New-NvGatesRoute {
    # config.json for the route: no toast, ntfy as the phone channel, and
    # $Reply as its reply block when given
    param($Reply)
    $c = [ordered]@{ toast = $false; ntfy = [ordered]@{ topic = (New-NvGatesSecret 'n1') } }
    if ($null -ne $Reply) { $c['reply'] = $Reply }
    return $c
}

function Get-NvGatesList {
    # an input's list, empty when the case has none
    param($In, [string]$Field)
    if (-not $In.PSObject.Properties[$Field]) { return , @() }
    return , @($In.$Field)
}

function Write-NvGatesText {
    param([string]$Path, [string]$Text)
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding $false))
}

function Write-NvGatesFile {
    # a data/ file from an input's object field (as JSON) or its text field
    # (as it is); with neither, no file
    param([string]$Path, $In, [string]$Obj, [string]$Text)
    if ($In.PSObject.Properties[$Obj]) { Write-NvGatesText $Path (ConvertTo-NvJson $In.$Obj) }
    elseif ($In.PSObject.Properties[$Text]) { Write-NvGatesText $Path ([string]$In.$Text) }
}

function New-NvGatesHeldFiles {
    # an input's files in data/, aged against the clock: {name, ageSeconds},
    # or {name, dir: true} for a folder
    param([string]$Dir, $In)
    foreach ($f in (Get-NvGatesList $In 'files')) {
        $path = Join-Path $Dir ([string]$f.name)
        if ($f.PSObject.Properties['dir'] -and $f.dir) { $null = New-Item -ItemType Directory -Path $path -Force }
        else {
            Write-NvGatesText $path ''
            $at = [datetime]::SpecifyKind((Get-Date).ToUniversalTime(), [System.DateTimeKind]::Utc).AddSeconds(-[int]$f.ageSeconds)
            [System.IO.File]::SetLastWriteTimeUtc($path, $at)
        }
    }
}

function Get-NvGatesSoonKey {
    # Send-ChatqUsageSoon's key for a lane and its reset
    param($Entry)
    return "s|$([string]$Entry.lane)|$(Get-ChatqEpochMinutes (ConvertTo-ChatqDate ([string]$Entry.until)))"
}

function Get-NvGatesSorted {
    # strings in ordinal order, as a list: pwsh 7's hashtables keep no order
    param($Items)
    $a = [string[]]@($Items)
    [Array]::Sort($a, [StringComparer]::Ordinal)
    return , $a
}

Register-NvVector -Name 'gates' -About 'The watcher loop''s cheap gates, each run as the loop runs it against a data/ of its own. replyOpen: Test-ChatqReplyOpen (src/phone.ps1). held: Test-ChatqHeldWaiting (src/phone-extras.ps1), files aged against the clock. heldSummary: Send-ChatqHeldSummary (src/phone-extras.ps1) with its claim stubbed, due when it gets that far: something held, the last failed push (triedSecondsAgo) 5 minutes old or more, now outside quiet hours on the local clock. auto: Test-ChatqAutoWanted (src/auto-continue.ps1). soon: Send-ChatqUsageSoon (src/phone-extras.ps1) with the alert stubbed: next is the time the loop wakes for a soon alert, due the lanes whose key the process records now (sentBefore: already recorded), send those that then go (fileHas: already in data/usage-alerts.json, sent at 08:00 or at its value; fileText: the file as it is), alerts how many were sent. route: SPEC 1.4, whether Send-ChatqAlert registers the alert as answerable (New-ChatqReplyAlert called), every gate before it held open; links is Get-ChatqReplyConfig''s Links, secrets opened with protected ones all failing. pollSeconds: Get-ChatqReplyPollSeconds (src/phone-down.ps1). listenText: Get-ChatqReplyListenText (src/phone-down.ps1) under a culture, with its time separator. A file is read as the tool reads it, so a zoneless stamp is UTC to 5.1 and the zone''s wall clock to pwsh 7.' -Cases {
    $india = 'India Standard Time'
    $lima = 'SA Pacific Standard Time'
    $open = [ordered]@{ openUntil = '2026-10-15T09:30:00.0000000Z' }
    $standing = [ordered]@{ standing = $true }
    $ahead = [ordered]@{ id = 'p1'; expires = '2026-10-15T09:05:00.0000000Z' }

    # --- replyOpen ---------------------------------------------------------
    New-NvGatesCase 'replyOpen: no reply block' 'replyOpen' ([ordered]@{ config = [ordered]@{}; replies = $open })
    New-NvGatesCase 'replyOpen: a window open' 'replyOpen' ([ordered]@{ config = [ordered]@{ reply = (New-NvGatesReply) }; replies = $open })
    New-NvGatesCase 'replyOpen: the window closed a second ago' 'replyOpen' ([ordered]@{ config = [ordered]@{ reply = (New-NvGatesReply) }; replies = [ordered]@{ openUntil = '2026-10-15T08:59:59.0000000Z' } })
    New-NvGatesCase 'replyOpen: the window ending now' 'replyOpen' ([ordered]@{ config = [ordered]@{ reply = (New-NvGatesReply) }; replies = [ordered]@{ openUntil = '2026-10-15T09:00:00.0000000Z' } })
    New-NvGatesCase 'replyOpen: on as the string TRUE' 'replyOpen' ([ordered]@{ config = [ordered]@{ reply = (New-NvGatesReply ([ordered]@{ on = 'TRUE' })) }; replies = $open })
    New-NvGatesCase 'replyOpen: on as the number 1' 'replyOpen' ([ordered]@{ config = [ordered]@{ reply = (New-NvGatesReply ([ordered]@{ on = 1 })) }; replies = $open })
    New-NvGatesCase 'replyOpen: on as the string 1' 'replyOpen' ([ordered]@{ config = [ordered]@{ reply = (New-NvGatesReply ([ordered]@{ on = '1' })) }; replies = $open })
    New-NvGatesCase 'replyOpen: on as yes' 'replyOpen' ([ordered]@{ config = [ordered]@{ reply = (New-NvGatesReply ([ordered]@{ on = 'yes' })) }; replies = $open })
    New-NvGatesCase 'replyOpen: switched off' 'replyOpen' ([ordered]@{ config = [ordered]@{ reply = (New-NvGatesReply ([ordered]@{ on = $false })) }; replies = $open })
    New-NvGatesCase 'replyOpen: no topic' 'replyOpen' ([ordered]@{ config = [ordered]@{ reply = (New-NvGatesReply ([ordered]@{ topic = $null })) }; replies = $open })
    New-NvGatesCase 'replyOpen: an empty topic' 'replyOpen' ([ordered]@{ config = [ordered]@{ reply = (New-NvGatesReply ([ordered]@{ topic = '' })) }; replies = $open })
    New-NvGatesCase 'replyOpen: a topic as a plain string' 'replyOpen' ([ordered]@{ config = [ordered]@{ reply = (New-NvGatesReply ([ordered]@{ topic = 't1' })) }; replies = $open })
    New-NvGatesCase 'replyOpen: no key, a pairing waiting' 'replyOpen' ([ordered]@{ config = [ordered]@{ reply = (New-NvGatesReply ([ordered]@{ key = $null; pairing = $ahead })) }; replies = $open })
    New-NvGatesCase 'replyOpen: no key, the pairing expired' 'replyOpen' ([ordered]@{ config = [ordered]@{ reply = (New-NvGatesReply ([ordered]@{ key = $null; pairing = [ordered]@{ id = 'p1'; expires = '2026-10-15T08:55:00.0000000Z' } })) }; replies = $open })
    New-NvGatesCase 'replyOpen: no key and no pairing' 'replyOpen' ([ordered]@{ config = [ordered]@{ reply = (New-NvGatesReply ([ordered]@{ key = $null })) }; replies = $open })
    New-NvGatesCase 'replyOpen: listening all the time' 'replyOpen' ([ordered]@{ config = [ordered]@{ reply = (New-NvGatesReply ([ordered]@{ listen = 'always' })) }; replies = $standing })
    New-NvGatesCase 'replyOpen: listen ALWAYS in capitals' 'replyOpen' ([ordered]@{ config = [ordered]@{ reply = (New-NvGatesReply ([ordered]@{ listen = 'ALWAYS' })) }; replies = $standing })
    New-NvGatesCase 'replyOpen: standing as the string true' 'replyOpen' ([ordered]@{ config = [ordered]@{ reply = (New-NvGatesReply ([ordered]@{ listen = 'always' })) }; replies = [ordered]@{ standing = 'true' } })
    New-NvGatesCase 'replyOpen: standing as the number 1' 'replyOpen' ([ordered]@{ config = [ordered]@{ reply = (New-NvGatesReply ([ordered]@{ listen = 'always' })) }; replies = [ordered]@{ standing = 1 } })
    New-NvGatesCase 'replyOpen: standing as the string yes' 'replyOpen' ([ordered]@{ config = [ordered]@{ reply = (New-NvGatesReply ([ordered]@{ listen = 'always' })) }; replies = [ordered]@{ standing = 'yes' } })
    New-NvGatesCase 'replyOpen: standing, listen alerts' 'replyOpen' ([ordered]@{ config = [ordered]@{ reply = (New-NvGatesReply ([ordered]@{ listen = 'alerts' })) }; replies = $standing })
    New-NvGatesCase 'replyOpen: standing with no key' 'replyOpen' ([ordered]@{ config = [ordered]@{ reply = (New-NvGatesReply ([ordered]@{ key = $null; pairing = $ahead; listen = 'always' })) }; replies = $standing })
    New-NvGatesCase 'replyOpen: no replies.json' 'replyOpen' ([ordered]@{ config = [ordered]@{ reply = (New-NvGatesReply) } })
    New-NvGatesCase 'replyOpen: replies.json not JSON' 'replyOpen' ([ordered]@{ config = [ordered]@{ reply = (New-NvGatesReply) }; repliesText = 'not json' })
    New-NvGatesCase 'replyOpen: replies.json empty' 'replyOpen' ([ordered]@{ config = [ordered]@{ reply = (New-NvGatesReply) }; repliesText = '' })
    New-NvGatesCase 'replyOpen: replies.json a list of one' 'replyOpen' ([ordered]@{ config = [ordered]@{ reply = (New-NvGatesReply) }; repliesText = '[{"openUntil":"2026-10-15T09:30:00.0000000Z"}]' })
    New-NvGatesCase 'replyOpen: openUntil in capitals' 'replyOpen' ([ordered]@{ config = [ordered]@{ reply = (New-NvGatesReply) }; replies = [ordered]@{ OPENUNTIL = '2026-10-15T09:30:00.0000000Z' } })
    New-NvGatesCase 'replyOpen: a reply block as a string' 'replyOpen' ([ordered]@{ config = [ordered]@{ reply = 'on' }; replies = $open })
    New-NvGatesCase 'replyOpen: a reply block as a list of one' 'replyOpen' ([ordered]@{ config = [ordered]@{ reply = @((New-NvGatesReply)) }; replies = $open })
    New-NvGatesCase 'replyOpen: a zoneless window east of UTC' 'replyOpen' ([ordered]@{ config = [ordered]@{ reply = (New-NvGatesReply) }; replies = [ordered]@{ openUntil = '2026-10-15T14:00:00' } }) $india 330
    New-NvGatesCase 'replyOpen: a zoneless pairing expiry east of UTC' 'replyOpen' ([ordered]@{ config = [ordered]@{ reply = (New-NvGatesReply ([ordered]@{ key = $null; pairing = [ordered]@{ id = 'p1'; expires = '2026-10-15T14:00:00' } })) }; replies = $open }) $india 330
    New-NvGatesCase 'replyOpen: a window with an offset, west of UTC' 'replyOpen' ([ordered]@{ config = [ordered]@{ reply = (New-NvGatesReply) }; replies = [ordered]@{ openUntil = '2026-10-15T04:30:00.0000000-05:00' } }) $lima -300
    # config.json as a person edits it: a comment and trailing commas, which
    # pwsh 7 reads and 5.1 does not; the same keys in strict JSON as a control
    $lf = "`n"
    $reply = '"reply": {"on": true, "topic": {"value": "t1", "protected": false}, "key": {"value": "' + (Get-NvGatesKey) + '", "protected": false}'
    New-NvGatesCase 'replyOpen: config.json with a comment and trailing commas' 'replyOpen' ([ordered]@{ configText = ('{' + $lf + '  // the phone' + $lf + '  ' + $reply + ',},' + $lf + '}'); replies = $open })
    New-NvGatesCase 'replyOpen: config.json as strict JSON' 'replyOpen' ([ordered]@{ configText = ('{' + $reply + '}}'); replies = $open })
    # a top-level list: Read-ChatqJson's return and Get-ChatqConfig's unroll it
    New-NvGatesCase 'replyOpen: config.json a list of one' 'replyOpen' ([ordered]@{ configText = ('[{' + $reply + '}}]'); replies = $open })
    # `if` of a list of one that holds a list: true when the inner list has
    # an item, whatever that item is
    foreach ($gtTopic in '[[0]]', '[[false]]', '[[]]') {
        New-NvGatesCase "replyOpen: a topic of $gtTopic" 'replyOpen' ([ordered]@{ configText = ('{"reply": {"on": true, "topic": ' + $gtTopic + ', "key": {"value": "' + (Get-NvGatesKey) + '", "protected": false}}}'); replies = $open })
    }

    # --- held --------------------------------------------------------------
    New-NvGatesCase 'held: nothing' 'held' ([ordered]@{ files = @() })
    New-NvGatesCase 'held: held.jsonl' 'held' ([ordered]@{ files = @([ordered]@{ name = 'held.jsonl'; ageSeconds = 5 }) })
    New-NvGatesCase 'held: held.jsonl a folder' 'held' ([ordered]@{ files = @([ordered]@{ name = 'held.jsonl'; dir = $true }) })
    New-NvGatesCase 'held: a sending claimed 11 minutes ago' 'held' ([ordered]@{ files = @([ordered]@{ name = 'held-1.sending'; ageSeconds = 660 }) })
    New-NvGatesCase 'held: a sending claimed 9 minutes ago' 'held' ([ordered]@{ files = @([ordered]@{ name = 'held-1.sending'; ageSeconds = 540 }) })
    New-NvGatesCase 'held: a sending claimed 10 minutes ago' 'held' ([ordered]@{ files = @([ordered]@{ name = 'held-1.sending'; ageSeconds = 600 }) })
    New-NvGatesCase 'held: a sending claimed 10 minutes and a second ago' 'held' ([ordered]@{ files = @([ordered]@{ name = 'held-1.sending'; ageSeconds = 601 }) })
    New-NvGatesCase 'held: a sending in capitals' 'held' ([ordered]@{ files = @([ordered]@{ name = 'HELD-2.SENDING'; ageSeconds = 660 }) })
    New-NvGatesCase 'held: a sending.tmp' 'held' ([ordered]@{ files = @([ordered]@{ name = 'held-1.sending.tmp'; ageSeconds = 660 }) })
    New-NvGatesCase 'held: a sending folder' 'held' ([ordered]@{ files = @([ordered]@{ name = 'held-3.sending'; dir = $true }) })
    New-NvGatesCase 'held: held.sending without the dash' 'held' ([ordered]@{ files = @([ordered]@{ name = 'held.sending'; ageSeconds = 660 }) })
    New-NvGatesCase 'held: held-.sending with nothing after the dash' 'held' ([ordered]@{ files = @([ordered]@{ name = 'held-.sending'; ageSeconds = 660 }) })
    New-NvGatesCase 'held: a sending dated ahead of the clock' 'held' ([ordered]@{ files = @([ordered]@{ name = 'held-1.sending'; ageSeconds = -3600 }) })
    New-NvGatesCase 'held: one old sending among fresh ones' 'held' ([ordered]@{ files = @([ordered]@{ name = 'held-1.sending'; ageSeconds = 30 }, [ordered]@{ name = 'held-2.sending'; ageSeconds = 900 }) })
    New-NvGatesCase 'held: a sending in a subfolder' 'held' ([ordered]@{ files = @([ordered]@{ name = 'sub/held-1.sending'; ageSeconds = 660 }) })

    # --- heldSummary -------------------------------------------------------
    # Send-ChatqHeldSummary's returns before its claim: something held, the
    # last failed push 5 minutes old or more, now outside quiet hours
    $held = @([ordered]@{ name = 'held.jsonl'; ageSeconds = 5 })
    $qh = { param($From, $To) [ordered]@{ quietHours = [ordered]@{ from = $From; to = $To } } }
    New-NvGatesCase 'heldSummary: nothing held' 'heldSummary' ([ordered]@{ config = [ordered]@{}; files = @() })
    New-NvGatesCase 'heldSummary: held, no quiet hours' 'heldSummary' ([ordered]@{ config = [ordered]@{}; files = $held })
    New-NvGatesCase 'heldSummary: a sending claimed 11 minutes ago' 'heldSummary' ([ordered]@{ config = [ordered]@{}; files = @([ordered]@{ name = 'held-1.sending'; ageSeconds = 660 }) })
    New-NvGatesCase 'heldSummary: inside quiet hours' 'heldSummary' ([ordered]@{ config = (& $qh '08:00' '10:00'); files = $held })
    New-NvGatesCase 'heldSummary: inside quiet hours, nothing held' 'heldSummary' ([ordered]@{ config = (& $qh '08:00' '10:00'); files = @() })
    New-NvGatesCase 'heldSummary: quiet hours ending now' 'heldSummary' ([ordered]@{ config = (& $qh '07:00' '09:00'); files = $held })
    New-NvGatesCase 'heldSummary: quiet hours starting now' 'heldSummary' ([ordered]@{ config = (& $qh '09:00' '10:00'); files = $held })
    New-NvGatesCase 'heldSummary: quiet hours a second ahead' 'heldSummary' ([ordered]@{ config = (& $qh '09:01' '10:00'); files = $held; now = '2026-10-15T09:00:59.0000000Z' })
    New-NvGatesCase 'heldSummary: quiet hours later today' 'heldSummary' ([ordered]@{ config = (& $qh '22:00' '23:00'); files = $held })
    New-NvGatesCase 'heldSummary: past midnight, inside in the morning' 'heldSummary' ([ordered]@{ config = (& $qh '22:00' '10:00'); files = $held })
    New-NvGatesCase 'heldSummary: past midnight, inside in the evening' 'heldSummary' ([ordered]@{ config = (& $qh '22:00' '07:00'); files = $held; now = '2026-10-15T23:30:00.0000000Z' })
    New-NvGatesCase 'heldSummary: past midnight, outside' 'heldSummary' ([ordered]@{ config = (& $qh '22:00' '07:00'); files = $held })
    New-NvGatesCase 'heldSummary: past midnight, at midnight' 'heldSummary' ([ordered]@{ config = (& $qh '22:00' '07:00'); files = $held; now = '2026-10-16T00:00:00.0000000Z' })
    New-NvGatesCase 'heldSummary: from 00:00' 'heldSummary' ([ordered]@{ config = (& $qh '00:00' '10:00'); files = $held })
    New-NvGatesCase 'heldSummary: to 00:00' 'heldSummary' ([ordered]@{ config = (& $qh '08:00' '00:00'); files = $held })
    New-NvGatesCase 'heldSummary: from equal to to is off' 'heldSummary' ([ordered]@{ config = (& $qh '09:00' '09:00'); files = $held })
    New-NvGatesCase 'heldSummary: a from of 8:00 is off' 'heldSummary' ([ordered]@{ config = (& $qh '8:00' '10:00'); files = $held })
    New-NvGatesCase 'heldSummary: a from of 24:00 is off' 'heldSummary' ([ordered]@{ config = (& $qh '24:00' '10:00'); files = $held })
    New-NvGatesCase 'heldSummary: a to of 09:60 is off' 'heldSummary' ([ordered]@{ config = (& $qh '08:00' '09:60'); files = $held })
    New-NvGatesCase 'heldSummary: a from with seconds is off' 'heldSummary' ([ordered]@{ config = (& $qh '08:00:00' '10:00'); files = $held })
    New-NvGatesCase 'heldSummary: a from and a space is off' 'heldSummary' ([ordered]@{ config = (& $qh '08:00 ' '10:00'); files = $held })
    New-NvGatesCase 'heldSummary: a from and a newline' 'heldSummary' ([ordered]@{ config = (& $qh "08:00`n" '10:00'); files = $held })
    New-NvGatesCase 'heldSummary: a from as a number is off' 'heldSummary' ([ordered]@{ config = (& $qh 800 '10:00'); files = $held })
    New-NvGatesCase 'heldSummary: a from as a list of one' 'heldSummary' ([ordered]@{ config = (& $qh @('08:00') '10:00'); files = $held })
    New-NvGatesCase 'heldSummary: no to is off' 'heldSummary' ([ordered]@{ config = [ordered]@{ quietHours = [ordered]@{ from = '08:00' } }; files = $held })
    New-NvGatesCase 'heldSummary: FROM and TO in capitals' 'heldSummary' ([ordered]@{ config = [ordered]@{ quietHours = [ordered]@{ FROM = '08:00'; TO = '10:00' } }; files = $held })
    New-NvGatesCase 'heldSummary: QUIETHOURS in capitals' 'heldSummary' ([ordered]@{ config = [ordered]@{ QUIETHOURS = [ordered]@{ from = '08:00'; to = '10:00' } }; files = $held })
    New-NvGatesCase 'heldSummary: quietHours as a list of one' 'heldSummary' ([ordered]@{ config = [ordered]@{ quietHours = @([ordered]@{ from = '08:00'; to = '10:00' }) }; files = $held })
    New-NvGatesCase 'heldSummary: quietHours as a list of two is off' 'heldSummary' ([ordered]@{ config = [ordered]@{ quietHours = @([ordered]@{ from = '08:00'; to = '10:00' }, [ordered]@{ from = '08:00'; to = '10:00' }) }; files = $held })
    New-NvGatesCase 'heldSummary: quietHours as a string is off' 'heldSummary' ([ordered]@{ config = [ordered]@{ quietHours = '08:00-10:00' }; files = $held })
    New-NvGatesCase 'heldSummary: quietHours false is off' 'heldSummary' ([ordered]@{ config = [ordered]@{ quietHours = $false }; files = $held })
    New-NvGatesCase 'heldSummary: quietHours empty is off' 'heldSummary' ([ordered]@{ config = [ordered]@{ quietHours = [ordered]@{} }; files = $held })
    New-NvGatesCase 'heldSummary: inside quiet hours east of UTC' 'heldSummary' ([ordered]@{ config = (& $qh '14:00' '15:00'); files = $held }) $india 330
    New-NvGatesCase 'heldSummary: UTC quiet hours, east of UTC' 'heldSummary' ([ordered]@{ config = (& $qh '08:00' '10:00'); files = $held }) $india 330
    New-NvGatesCase 'heldSummary: past midnight, west of UTC' 'heldSummary' ([ordered]@{ config = (& $qh '22:00' '06:00'); files = $held }) $lima -300
    New-NvGatesCase 'heldSummary: tried 4 minutes ago' 'heldSummary' ([ordered]@{ config = [ordered]@{}; files = $held; triedSecondsAgo = 240 })
    New-NvGatesCase 'heldSummary: tried 4 minutes 59 ago' 'heldSummary' ([ordered]@{ config = [ordered]@{}; files = $held; triedSecondsAgo = 299 })
    New-NvGatesCase 'heldSummary: tried 5 minutes ago' 'heldSummary' ([ordered]@{ config = [ordered]@{}; files = $held; triedSecondsAgo = 300 })
    New-NvGatesCase 'heldSummary: tried an hour ago' 'heldSummary' ([ordered]@{ config = [ordered]@{}; files = $held; triedSecondsAgo = 3600 })
    New-NvGatesCase 'heldSummary: tried ahead of the clock' 'heldSummary' ([ordered]@{ config = [ordered]@{}; files = $held; triedSecondsAgo = -60 })
    New-NvGatesCase 'heldSummary: tried an hour ago, inside quiet hours' 'heldSummary' ([ordered]@{ config = (& $qh '08:00' '10:00'); files = $held; triedSecondsAgo = 3600 })
    New-NvGatesCase 'heldSummary: config.json with a comment' 'heldSummary' ([ordered]@{ configText = ('{' + "`n" + '  // nights' + "`n" + '  "quietHours": {"from": "08:00", "to": "10:00"}' + "`n" + '}'); files = $held })

    # --- auto --------------------------------------------------------------
    $always = [ordered]@{ chats = [ordered]@{ c1 = [ordered]@{ auto = 'always' } } }
    New-NvGatesCase 'auto: the switch on' 'auto' ([ordered]@{ config = [ordered]@{ autoContinue = 'on' } })
    New-NvGatesCase 'auto: the switch on, in capitals and spaces' 'auto' ([ordered]@{ config = [ordered]@{ autoContinue = ' ON ' } })
    New-NvGatesCase 'auto: the switch true reads as ask' 'auto' ([ordered]@{ config = [ordered]@{ autoContinue = $true } })
    New-NvGatesCase 'auto: the switch ask' 'auto' ([ordered]@{ config = [ordered]@{ autoContinue = 'ask' } })
    New-NvGatesCase 'auto: the switch off' 'auto' ([ordered]@{ config = [ordered]@{ autoContinue = 'off' } })
    New-NvGatesCase 'auto: no switch' 'auto' ([ordered]@{ config = [ordered]@{} })
    New-NvGatesCase 'auto: the switch as a list of on' 'auto' ([ordered]@{ config = [ordered]@{ autoContinue = @('on') } })
    New-NvGatesCase 'auto: the switch as the number 1' 'auto' ([ordered]@{ config = [ordered]@{ autoContinue = 1 } })
    New-NvGatesCase 'auto: a chat set to always' 'auto' ([ordered]@{ config = [ordered]@{}; autoState = $always })
    New-NvGatesCase 'auto: a chat set to Always' 'auto' ([ordered]@{ config = [ordered]@{}; autoState = [ordered]@{ chats = [ordered]@{ c1 = [ordered]@{ auto = 'Always' } } } })
    New-NvGatesCase 'auto: a chat set to never' 'auto' ([ordered]@{ config = [ordered]@{}; autoState = [ordered]@{ chats = [ordered]@{ c1 = [ordered]@{ auto = 'never' } } } })
    New-NvGatesCase 'auto: a chat set to sometimes' 'auto' ([ordered]@{ config = [ordered]@{}; autoState = [ordered]@{ chats = [ordered]@{ c1 = [ordered]@{ auto = 'sometimes' } } } })
    New-NvGatesCase 'auto: a chat set to always with a space' 'auto' ([ordered]@{ config = [ordered]@{}; autoState = [ordered]@{ chats = [ordered]@{ c1 = [ordered]@{ auto = 'always ' } } } })
    New-NvGatesCase 'auto: no chats' 'auto' ([ordered]@{ config = [ordered]@{}; autoState = [ordered]@{ chats = [ordered]@{} } })
    New-NvGatesCase 'auto: the chats as a list of one' 'auto' ([ordered]@{ config = [ordered]@{}; autoState = [ordered]@{ chats = @([ordered]@{ c1 = [ordered]@{ auto = 'always' } }) } })
    New-NvGatesCase 'auto: the chats as a list of two' 'auto' ([ordered]@{ config = [ordered]@{}; autoState = [ordered]@{ chats = @([ordered]@{ c1 = [ordered]@{ auto = 'always' } }, [ordered]@{ c2 = [ordered]@{ auto = 'always' } }) } })
    New-NvGatesCase 'auto: a chat as a plain string' 'auto' ([ordered]@{ config = [ordered]@{}; autoState = [ordered]@{ chats = [ordered]@{ c1 = 'always' } } })
    New-NvGatesCase 'auto: auto as a list of always' 'auto' ([ordered]@{ config = [ordered]@{}; autoState = [ordered]@{ chats = [ordered]@{ c1 = [ordered]@{ auto = @('always') } } } })
    New-NvGatesCase 'auto: auto as a list of two words' 'auto' ([ordered]@{ config = [ordered]@{}; autoState = [ordered]@{ chats = [ordered]@{ c1 = [ordered]@{ auto = @('always', 'never') } } } })
    New-NvGatesCase 'auto: AUTO in capitals' 'auto' ([ordered]@{ config = [ordered]@{}; autoState = [ordered]@{ chats = [ordered]@{ c1 = [ordered]@{ AUTO = 'always' } } } })
    New-NvGatesCase 'auto: the second chat set to always' 'auto' ([ordered]@{ config = [ordered]@{}; autoState = [ordered]@{ chats = [ordered]@{ c1 = [ordered]@{ auto = 'never' }; c2 = [ordered]@{ auto = 'always' } } } })
    New-NvGatesCase 'auto: the switch off and a chat set to always' 'auto' ([ordered]@{ config = [ordered]@{ autoContinue = 'off' }; autoState = $always })
    New-NvGatesCase 'auto: auto-continue.json not JSON' 'auto' ([ordered]@{ config = [ordered]@{ autoContinue = 'ask' }; autoText = 'not json' })
    New-NvGatesCase 'auto: auto-continue.json a list of one' 'auto' ([ordered]@{ config = [ordered]@{}; autoText = '[{"chats":{"c1":{"auto":"always"}}}]' })
    New-NvGatesCase 'auto: config.json with a comment and a trailing comma' 'auto' ([ordered]@{ configText = ('{' + $lf + '  // keep going' + $lf + '  "autoContinue": "on",' + $lf + '}') })
    New-NvGatesCase 'auto: config.json as strict JSON' 'auto' ([ordered]@{ configText = '{"autoContinue": "on"}' })
    New-NvGatesCase 'auto: config.json a list of one' 'auto' ([ordered]@{ configText = '[{"autoContinue": "on"}]' })
    New-NvGatesCase 'auto: config.json a list of a list of one' 'auto' ([ordered]@{ configText = '[[{"autoContinue": "on"}]]' })

    # --- soon --------------------------------------------------------------
    # a lane limited at 08:00 until 11:00, and one job queued in it
    $claude = [ordered]@{ id = 'j1'; provider = 'claude'; state = 'queued' }
    $two = [ordered]@{ lane = 'claude'; until = '2026-10-15T11:00:00.0000000Z'; at = '2026-10-15T08:00:00.0000000Z'; type = 'limit' }
    $eight = [ordered]@{ lane = 'claude'; until = '2026-10-15T09:08:00.0000000Z'; at = '2026-10-15T08:00:00.0000000Z'; type = 'limit' }
    New-NvGatesCase 'soon: nothing blocked' 'soon' ([ordered]@{ config = [ordered]@{}; jobs = @($claude) })
    New-NvGatesCase 'soon: a reset 2 hours out wakes the loop 10 minutes before it' 'soon' ([ordered]@{ config = [ordered]@{}; blocked = @($two); jobs = @($claude) })
    New-NvGatesCase 'soon: a reset 8 minutes out alerts now' 'soon' ([ordered]@{ config = [ordered]@{}; blocked = @($eight); jobs = @($claude) })
    New-NvGatesCase 'soon: a reset exactly 10 minutes out alerts now' 'soon' ([ordered]@{ config = [ordered]@{}; blocked = @([ordered]@{ lane = 'claude'; until = '2026-10-15T09:10:00.0000000Z'; at = '2026-10-15T08:00:00.0000000Z'; type = 'limit' }); jobs = @($claude) })
    New-NvGatesCase 'soon: a reset 10 minutes and a second out waits' 'soon' ([ordered]@{ config = [ordered]@{}; blocked = @([ordered]@{ lane = 'claude'; until = '2026-10-15T09:10:01.0000000Z'; at = '2026-10-15T08:00:00.0000000Z'; type = 'limit' }); jobs = @($claude) })
    New-NvGatesCase 'soon: a wait of 29 minutes is a guess' 'soon' ([ordered]@{ config = [ordered]@{}; blocked = @([ordered]@{ lane = 'claude'; until = '2026-10-15T09:08:00.0000000Z'; at = '2026-10-15T08:39:00.0000000Z'; type = 'limit' }); jobs = @($claude) })
    New-NvGatesCase 'soon: a wait of 30 minutes counts' 'soon' ([ordered]@{ config = [ordered]@{}; blocked = @([ordered]@{ lane = 'claude'; until = '2026-10-15T09:08:00.0000000Z'; at = '2026-10-15T08:38:00.0000000Z'; type = 'limit' }); jobs = @($claude) })
    New-NvGatesCase 'soon: a block with no At' 'soon' ([ordered]@{ config = [ordered]@{}; blocked = @([ordered]@{ lane = 'claude'; until = '2026-10-15T09:08:00.0000000Z'; type = 'limit' }); jobs = @($claude) })
    New-NvGatesCase 'soon: a failed probe is no limit' 'soon' ([ordered]@{ config = [ordered]@{}; blocked = @([ordered]@{ lane = 'claude'; until = '2026-10-15T09:08:00.0000000Z'; at = '2026-10-15T08:00:00.0000000Z'; type = 'probe failed' }); jobs = @($claude) })
    New-NvGatesCase 'soon: login needed is no limit' 'soon' ([ordered]@{ config = [ordered]@{}; blocked = @([ordered]@{ lane = 'claude'; until = '2026-10-15T09:08:00.0000000Z'; at = '2026-10-15T08:00:00.0000000Z'; type = 'login needed' }); jobs = @($claude) })
    New-NvGatesCase 'soon: an overload in capitals is no limit' 'soon' ([ordered]@{ config = [ordered]@{}; blocked = @([ordered]@{ lane = 'claude'; until = '2026-10-15T09:08:00.0000000Z'; at = '2026-10-15T08:00:00.0000000Z'; type = 'Overloaded' }); jobs = @($claude) })
    New-NvGatesCase 'soon: a reset already past' 'soon' ([ordered]@{ config = [ordered]@{}; blocked = @([ordered]@{ lane = 'claude'; until = '2026-10-15T08:59:00.0000000Z'; at = '2026-10-15T07:00:00.0000000Z'; type = 'limit' }); jobs = @($claude) })
    New-NvGatesCase 'soon: no job queued' 'soon' ([ordered]@{ config = [ordered]@{}; blocked = @($eight) })
    New-NvGatesCase 'soon: a job in another lane' 'soon' ([ordered]@{ config = [ordered]@{}; blocked = @($eight); jobs = @([ordered]@{ id = 'j1'; provider = 'codex'; state = 'queued' }) })
    New-NvGatesCase 'soon: a running job does not count' 'soon' ([ordered]@{ config = [ordered]@{}; blocked = @($eight); jobs = @([ordered]@{ id = 'j1'; provider = 'claude'; state = 'running' }) })
    New-NvGatesCase 'soon: a home lane' 'soon' ([ordered]@{ config = [ordered]@{}; blocked = @([ordered]@{ lane = 'claude|work'; until = '2026-10-15T09:08:00.0000000Z'; at = '2026-10-15T08:00:00.0000000Z'; type = 'limit' }); jobs = @([ordered]@{ id = 'j1'; provider = 'claude'; home = 'work'; state = 'queued' }) })
    New-NvGatesCase 'soon: a job with no home is not the home lane' 'soon' ([ordered]@{ config = [ordered]@{}; blocked = @([ordered]@{ lane = 'claude|work'; until = '2026-10-15T09:08:00.0000000Z'; at = '2026-10-15T08:00:00.0000000Z'; type = 'limit' }); jobs = @($claude) })
    New-NvGatesCase 'soon: a lane key in other letters' 'soon' ([ordered]@{ config = [ordered]@{}; blocked = @([ordered]@{ lane = 'Claude'; until = '2026-10-15T09:08:00.0000000Z'; at = '2026-10-15T08:00:00.0000000Z'; type = 'limit' }); jobs = @($claude) })
    New-NvGatesCase 'soon: a job held past the reset' 'soon' ([ordered]@{ config = [ordered]@{}; blocked = @($eight); jobs = @([ordered]@{ id = 'j1'; provider = 'claude'; state = 'queued'; notBefore = '2026-10-15T09:08:01.0000000Z' }) })
    New-NvGatesCase 'soon: a job held until the reset still counts' 'soon' ([ordered]@{ config = [ordered]@{}; blocked = @($eight); jobs = @([ordered]@{ id = 'j1'; provider = 'claude'; state = 'queued'; notBefore = '2026-10-15T09:08:00.0000000Z' }) })
    New-NvGatesCase 'soon: one job held past the reset, another not' 'soon' ([ordered]@{ config = [ordered]@{}; blocked = @($eight); jobs = @([ordered]@{ id = 'j1'; provider = 'claude'; state = 'queued'; notBefore = '2026-10-15T12:00:00.0000000Z' }, [ordered]@{ id = 'j2'; provider = 'claude'; state = 'queued' }) })
    New-NvGatesCase 'soon: a zoneless notBefore east of UTC' 'soon' ([ordered]@{ config = [ordered]@{}; blocked = @($eight); jobs = @([ordered]@{ id = 'j1'; provider = 'claude'; state = 'queued'; notBefore = '2026-10-15T09:30:00' }) }) $india 330
    New-NvGatesCase 'soon: already recorded by this process' 'soon' ([ordered]@{ config = [ordered]@{}; blocked = @($two); jobs = @($claude); sentBefore = @([ordered]@{ lane = 'claude'; until = '2026-10-15T11:00:00.0000000Z' }) })
    New-NvGatesCase 'soon: recorded in other letters' 'soon' ([ordered]@{ config = [ordered]@{}; blocked = @($eight); jobs = @($claude); sentBefore = @([ordered]@{ lane = 'CLAUDE'; until = '2026-10-15T09:08:00.0000000Z' }) })
    New-NvGatesCase 'soon: recorded for another reset' 'soon' ([ordered]@{ config = [ordered]@{}; blocked = @($eight); jobs = @($claude); sentBefore = @([ordered]@{ lane = 'claude'; until = '2026-10-15T04:08:00.0000000Z' }) })
    New-NvGatesCase 'soon: already in data/usage-alerts.json' 'soon' ([ordered]@{ config = [ordered]@{}; blocked = @($eight); jobs = @($claude); fileHas = @([ordered]@{ lane = 'claude'; until = '2026-10-15T09:08:00.0000000Z' }) })
    New-NvGatesCase 'soon: reset alerts off' 'soon' ([ordered]@{ config = [ordered]@{ usage = [ordered]@{ reset = $false } }; blocked = @($eight); jobs = @($claude) })
    New-NvGatesCase 'soon: reset as the string false is no switch' 'soon' ([ordered]@{ config = [ordered]@{ usage = [ordered]@{ reset = 'false' } }; blocked = @($two); jobs = @($claude) })
    New-NvGatesCase 'soon: reset as a list of false' 'soon' ([ordered]@{ config = [ordered]@{ usage = [ordered]@{ reset = @($false) } }; blocked = @($two); jobs = @($claude) })
    New-NvGatesCase 'soon: a usage block that is a string' 'soon' ([ordered]@{ config = [ordered]@{ usage = 'off' }; blocked = @($two); jobs = @($claude) })
    New-NvGatesCase 'soon: soonMinutes 0 is off' 'soon' ([ordered]@{ config = [ordered]@{ usage = [ordered]@{ soonMinutes = 0 } }; blocked = @($eight); jobs = @($claude) })
    New-NvGatesCase 'soon: soonMinutes 30' 'soon' ([ordered]@{ config = [ordered]@{ usage = [ordered]@{ soonMinutes = 30 } }; blocked = @($two); jobs = @($claude) })
    New-NvGatesCase 'soon: soonMinutes as the string 15' 'soon' ([ordered]@{ config = [ordered]@{ usage = [ordered]@{ soonMinutes = '15' } }; blocked = @($two); jobs = @($claude) })
    New-NvGatesCase 'soon: soonMinutes as the string 015' 'soon' ([ordered]@{ config = [ordered]@{ usage = [ordered]@{ soonMinutes = '015' } }; blocked = @($two); jobs = @($claude) })
    New-NvGatesCase 'soon: soonMinutes as a list of 20' 'soon' ([ordered]@{ config = [ordered]@{ usage = [ordered]@{ soonMinutes = @(20) } }; blocked = @($two); jobs = @($claude) })
    New-NvGatesCase 'soon: soonMinutes 120, two hours out, alerts now' 'soon' ([ordered]@{ config = [ordered]@{ usage = [ordered]@{ soonMinutes = 120 } }; blocked = @($two); jobs = @($claude) })
    New-NvGatesCase 'soon: soonMinutes 121 is the default' 'soon' ([ordered]@{ config = [ordered]@{ usage = [ordered]@{ soonMinutes = 121 } }; blocked = @($two); jobs = @($claude) })
    New-NvGatesCase 'soon: soonMinutes -5 is the default' 'soon' ([ordered]@{ config = [ordered]@{ usage = [ordered]@{ soonMinutes = -5 } }; blocked = @($two); jobs = @($claude) })
    New-NvGatesCase 'soon: soonMinutes 1000 is the default' 'soon' ([ordered]@{ config = [ordered]@{ usage = [ordered]@{ soonMinutes = 1000 } }; blocked = @($two); jobs = @($claude) })
    New-NvGatesCase 'soon: soonMinutes abc is the default' 'soon' ([ordered]@{ config = [ordered]@{ usage = [ordered]@{ soonMinutes = 'abc' } }; blocked = @($two); jobs = @($claude) })
    New-NvGatesCase 'soon: soonMinutes true is the default' 'soon' ([ordered]@{ config = [ordered]@{ usage = [ordered]@{ soonMinutes = $true } }; blocked = @($two); jobs = @($claude) })
    New-NvGatesCase 'soon: soonMinutes null is the default' 'soon' ([ordered]@{ config = [ordered]@{ usage = [ordered]@{ soonMinutes = $null } }; blocked = @($two); jobs = @($claude) })
    New-NvGatesCase 'soon: soonMinutes 15 and a newline' 'soon' ([ordered]@{ config = [ordered]@{ usage = [ordered]@{ soonMinutes = "15`n" } }; blocked = @($two); jobs = @($claude) })
    New-NvGatesCase 'soon: soonMinutes 15 and a space is the default' 'soon' ([ordered]@{ config = [ordered]@{ usage = [ordered]@{ soonMinutes = '15 ' } }; blocked = @($two); jobs = @($claude) })
    New-NvGatesCase 'soon: soonMinutes as a list of two is the default' 'soon' ([ordered]@{ config = [ordered]@{ usage = [ordered]@{ soonMinutes = @(20, 30) } }; blocked = @($two); jobs = @($claude) })
    New-NvGatesCase 'soon: soonMinutes as an empty list is the default' 'soon' ([ordered]@{ config = [ordered]@{ usage = [ordered]@{ soonMinutes = @() } }; blocked = @($two); jobs = @($claude) })
    New-NvGatesCase 'soon: a usage block as a list of one' 'soon' ([ordered]@{ config = [ordered]@{ usage = @([ordered]@{ soonMinutes = 30 }) }; blocked = @($two); jobs = @($claude) })
    New-NvGatesCase 'soon: two lanes, the sooner wake wins' 'soon' ([ordered]@{
            config = [ordered]@{}; jobs = @($claude, [ordered]@{ id = 'j2'; provider = 'codex'; state = 'queued' })
            blocked = @($two, [ordered]@{ lane = 'codex'; until = '2026-10-15T10:00:00.0000000Z'; at = '2026-10-15T08:00:00.0000000Z'; type = 'limit' })
        })
    New-NvGatesCase 'soon: two lanes, one due and one waiting' 'soon' ([ordered]@{
            config = [ordered]@{}; jobs = @($claude, [ordered]@{ id = 'j2'; provider = 'codex'; state = 'queued' })
            blocked = @($eight, [ordered]@{ lane = 'codex'; until = '2026-10-15T10:00:00.0000000Z'; at = '2026-10-15T08:00:00.0000000Z'; type = 'limit' })
        })
    New-NvGatesCase 'soon: two lanes due at once' 'soon' ([ordered]@{
            config = [ordered]@{}; jobs = @($claude, [ordered]@{ id = 'j2'; provider = 'codex'; state = 'queued' })
            blocked = @($eight, [ordered]@{ lane = 'codex'; until = '2026-10-15T09:05:00.0000000Z'; at = '2026-10-15T08:00:00.0000000Z'; type = 'limit' })
        })
    New-NvGatesCase 'soon: a reset 2 hours out, west of UTC' 'soon' ([ordered]@{ config = [ordered]@{}; blocked = @($two); jobs = @($claude) }) $lima -300
    # data/usage-alerts.json as Get-ChatqUsageAlertState reads it: only a key
    # whose value is a time is there
    New-NvGatesCase 'soon: in data/usage-alerts.json in other letters' 'soon' ([ordered]@{ config = [ordered]@{}; blocked = @($eight); jobs = @($claude); fileHas = @([ordered]@{ lane = 'CLAUDE'; until = '2026-10-15T09:08:00.0000000Z' }) })
    New-NvGatesCase 'soon: in data/usage-alerts.json with no time' 'soon' ([ordered]@{ config = [ordered]@{}; blocked = @($eight); jobs = @($claude); fileHas = @([ordered]@{ lane = 'claude'; until = '2026-10-15T09:08:00.0000000Z'; value = 'not a date' }) })
    New-NvGatesCase 'soon: in data/usage-alerts.json as null' 'soon' ([ordered]@{ config = [ordered]@{}; blocked = @($eight); jobs = @($claude); fileHas = @([ordered]@{ lane = 'claude'; until = '2026-10-15T09:08:00.0000000Z'; value = $null }) })
    New-NvGatesCase 'soon: in data/usage-alerts.json as an empty string' 'soon' ([ordered]@{ config = [ordered]@{}; blocked = @($eight); jobs = @($claude); fileHas = @([ordered]@{ lane = 'claude'; until = '2026-10-15T09:08:00.0000000Z'; value = '' }) })
    New-NvGatesCase 'soon: in data/usage-alerts.json for another reset' 'soon' ([ordered]@{ config = [ordered]@{}; blocked = @($eight); jobs = @($claude); fileHas = @([ordered]@{ lane = 'claude'; until = '2026-10-15T09:09:00.0000000Z' }) })
    New-NvGatesCase 'soon: data/usage-alerts.json not JSON' 'soon' ([ordered]@{ config = [ordered]@{}; blocked = @($eight); jobs = @($claude); fileText = 'not json' })
    New-NvGatesCase 'soon: data/usage-alerts.json empty' 'soon' ([ordered]@{ config = [ordered]@{}; blocked = @($eight); jobs = @($claude); fileText = '' })
    New-NvGatesCase 'soon: data/usage-alerts.json a list of one' 'soon' ([ordered]@{ config = [ordered]@{}; blocked = @($eight); jobs = @($claude); fileText = '[{"s|claude|29867588":"2026-10-15T08:00:00.0000000Z"}]' })

    # --- route -------------------------------------------------------------
    $key = Get-NvGatesKey
    New-NvGatesCase 'route: no reply block' 'route' ([ordered]@{ config = (New-NvGatesRoute $null) })
    New-NvGatesCase 'route: on, a topic and a paired key' 'route' ([ordered]@{ config = (New-NvGatesRoute (New-NvGatesReply)) })
    New-NvGatesCase 'route: -NoReply' 'route' ([ordered]@{ config = (New-NvGatesRoute (New-NvGatesReply)); noReply = $true })
    New-NvGatesCase 'route: switched off' 'route' ([ordered]@{ config = (New-NvGatesRoute (New-NvGatesReply ([ordered]@{ on = $false }))) })
    New-NvGatesCase 'route: on as the string true' 'route' ([ordered]@{ config = (New-NvGatesRoute (New-NvGatesReply ([ordered]@{ on = 'true' }))) })
    New-NvGatesCase 'route: on as the number 1' 'route' ([ordered]@{ config = (New-NvGatesRoute (New-NvGatesReply ([ordered]@{ on = 1 }))) })
    New-NvGatesCase 'route: on as yes' 'route' ([ordered]@{ config = (New-NvGatesRoute (New-NvGatesReply ([ordered]@{ on = 'yes' }))) })
    New-NvGatesCase 'route: no on' 'route' ([ordered]@{ config = (New-NvGatesRoute (New-NvGatesReply ([ordered]@{ on = $null }))) })
    New-NvGatesCase 'route: a topic as a plain string' 'route' ([ordered]@{ config = (New-NvGatesRoute (New-NvGatesReply ([ordered]@{ topic = 't1' }))) })
    New-NvGatesCase 'route: an empty topic' 'route' ([ordered]@{ config = (New-NvGatesRoute (New-NvGatesReply ([ordered]@{ topic = (New-NvGatesSecret '') }))) })
    New-NvGatesCase 'route: a topic DPAPI cannot open' 'route' ([ordered]@{ config = (New-NvGatesRoute (New-NvGatesReply ([ordered]@{ topic = (New-NvGatesSecret 'not-dpapi' $true) }))) })
    New-NvGatesCase 'route: a topic marked protected by the string false' 'route' ([ordered]@{ config = (New-NvGatesRoute (New-NvGatesReply ([ordered]@{ topic = (New-NvGatesSecret 't1' 'false') }))) })
    New-NvGatesCase 'route: no key, a pairing waiting' 'route' ([ordered]@{ config = (New-NvGatesRoute (New-NvGatesReply ([ordered]@{ key = $null; pairing = $ahead }))) })
    New-NvGatesCase 'route: a key of 42 characters' 'route' ([ordered]@{ config = (New-NvGatesRoute (New-NvGatesReply ([ordered]@{ key = (New-NvGatesSecret $key.Substring(0, 42)) }))) })
    New-NvGatesCase 'route: a key of 41 characters' 'route' ([ordered]@{ config = (New-NvGatesRoute (New-NvGatesReply ([ordered]@{ key = (New-NvGatesSecret $key.Substring(0, 41)) }))) })
    New-NvGatesCase 'route: a key of 44 characters' 'route' ([ordered]@{ config = (New-NvGatesRoute (New-NvGatesReply ([ordered]@{ key = (New-NvGatesSecret ($key + 'A')) }))) })
    New-NvGatesCase 'route: a key whose last bits are not zero' 'route' ([ordered]@{ config = (New-NvGatesRoute (New-NvGatesReply ([ordered]@{ key = (New-NvGatesSecret ($key.Substring(0, 42) + '9')) }))) })
    New-NvGatesCase 'route: a key in plain base64' 'route' ([ordered]@{ config = (New-NvGatesRoute (New-NvGatesReply ([ordered]@{ key = (New-NvGatesSecret ('+' + $key.Substring(1))) }))) })
    New-NvGatesCase 'route: a key padded with =' 'route' ([ordered]@{ config = (New-NvGatesRoute (New-NvGatesReply ([ordered]@{ key = (New-NvGatesSecret ($key + '=')) }))) })
    New-NvGatesCase 'route: a key ending in a newline' 'route' ([ordered]@{ config = (New-NvGatesRoute (New-NvGatesReply ([ordered]@{ key = (New-NvGatesSecret ($key + "`n")) }))) })
    New-NvGatesCase 'route: a key DPAPI cannot open' 'route' ([ordered]@{ config = (New-NvGatesRoute (New-NvGatesReply ([ordered]@{ key = (New-NvGatesSecret $key $true) }))) })
    New-NvGatesCase 'route: a key as a plain string' 'route' ([ordered]@{ config = (New-NvGatesRoute (New-NvGatesReply ([ordered]@{ key = $key }))) })
    New-NvGatesCase 'route: a reply block as a list of one' 'route' ([ordered]@{ config = (New-NvGatesRoute @((New-NvGatesReply))) })

    # --- pollSeconds -------------------------------------------------------
    $hot = '2026-10-15T09:01:00.0000000Z'
    New-NvGatesCase 'pollSeconds: no replies.json' 'pollSeconds' ([ordered]@{ inRun = $false })
    New-NvGatesCase 'pollSeconds: no replies.json, in a run' 'pollSeconds' ([ordered]@{ inRun = $true })
    New-NvGatesCase 'pollSeconds: hot' 'pollSeconds' ([ordered]@{ inRun = $false; replies = [ordered]@{ hotUntil = $hot } })
    New-NvGatesCase 'pollSeconds: hot, in a run' 'pollSeconds' ([ordered]@{ inRun = $true; replies = [ordered]@{ hotUntil = $hot } })
    New-NvGatesCase 'pollSeconds: a window open' 'pollSeconds' ([ordered]@{ inRun = $false; replies = $open })
    New-NvGatesCase 'pollSeconds: a window open, in a run' 'pollSeconds' ([ordered]@{ inRun = $true; replies = $open })
    New-NvGatesCase 'pollSeconds: hot and a window open' 'pollSeconds' ([ordered]@{ inRun = $false; replies = [ordered]@{ openUntil = '2026-10-15T09:30:00.0000000Z'; hotUntil = $hot } })
    New-NvGatesCase 'pollSeconds: hot passed, a window open' 'pollSeconds' ([ordered]@{ inRun = $false; replies = [ordered]@{ openUntil = '2026-10-15T09:30:00.0000000Z'; hotUntil = '2026-10-15T08:59:00.0000000Z' } })
    New-NvGatesCase 'pollSeconds: hot until now' 'pollSeconds' ([ordered]@{ inRun = $false; replies = [ordered]@{ hotUntil = '2026-10-15T09:00:00.0000000Z' } })
    New-NvGatesCase 'pollSeconds: HOTUNTIL in capitals' 'pollSeconds' ([ordered]@{ inRun = $false; replies = [ordered]@{ HOTUNTIL = $hot } })
    New-NvGatesCase 'pollSeconds: standing is no window' 'pollSeconds' ([ordered]@{ inRun = $false; replies = $standing })
    New-NvGatesCase 'pollSeconds: replies.json not JSON' 'pollSeconds' ([ordered]@{ inRun = $false; repliesText = 'not json' })
    New-NvGatesCase 'pollSeconds: replies.json a list of one' 'pollSeconds' ([ordered]@{ inRun = $false; repliesText = '[{"hotUntil":"2026-10-15T09:01:00.0000000Z"}]' })
    New-NvGatesCase 'pollSeconds: a zoneless hotUntil east of UTC' 'pollSeconds' ([ordered]@{ inRun = $false; replies = [ordered]@{ hotUntil = '2026-10-15T09:05:00' } }) $india 330

    # --- listenText --------------------------------------------------------
    New-NvGatesCase 'listenText: a window open, en-US' 'listenText' ([ordered]@{ culture = 'en-US'; replies = $open })
    New-NvGatesCase 'listenText: a window open, fi-FI' 'listenText' ([ordered]@{ culture = 'fi-FI'; replies = $open })
    New-NvGatesCase 'listenText: a window open, ko-KR' 'listenText' ([ordered]@{ culture = 'ko-KR'; replies = $open })
    New-NvGatesCase 'listenText: a window open, de-DE' 'listenText' ([ordered]@{ culture = 'de-DE'; replies = $open })
    New-NvGatesCase 'listenText: an evening window' 'listenText' ([ordered]@{ culture = 'en-US'; replies = [ordered]@{ openUntil = '2026-10-15T21:05:00.0000000Z' } })
    New-NvGatesCase 'listenText: a window open, east of UTC' 'listenText' ([ordered]@{ culture = 'en-US'; replies = $open }) $india 330
    New-NvGatesCase 'listenText: a window open, west of UTC' 'listenText' ([ordered]@{ culture = 'en-US'; replies = $open }) $lima -300
    New-NvGatesCase 'listenText: standing' 'listenText' ([ordered]@{ culture = 'en-US'; replies = $standing })
    New-NvGatesCase 'listenText: standing as the string true' 'listenText' ([ordered]@{ culture = 'en-US'; replies = [ordered]@{ standing = 'true' } })
    New-NvGatesCase 'listenText: a window and standing' 'listenText' ([ordered]@{ culture = 'en-US'; replies = [ordered]@{ openUntil = '2026-10-15T09:30:00.0000000Z'; standing = $true } })
    New-NvGatesCase 'listenText: a window passed and standing' 'listenText' ([ordered]@{ culture = 'en-US'; replies = [ordered]@{ openUntil = '2026-10-15T08:00:00.0000000Z'; standing = $true } })
    New-NvGatesCase 'listenText: a window ending now' 'listenText' ([ordered]@{ culture = 'en-US'; replies = [ordered]@{ openUntil = '2026-10-15T09:00:00.0000000Z' } })
    New-NvGatesCase 'listenText: no replies.json' 'listenText' ([ordered]@{ culture = 'en-US' })
    New-NvGatesCase 'listenText: replies.json empty' 'listenText' ([ordered]@{ culture = 'en-US'; repliesText = '' })
    New-NvGatesCase 'listenText: replies.json not JSON' 'listenText' ([ordered]@{ culture = 'en-US'; repliesText = 'not json' })
    New-NvGatesCase 'listenText: replies.json null' 'listenText' ([ordered]@{ culture = 'en-US'; repliesText = 'null' })
    New-NvGatesCase 'listenText: replies.json a list of one' 'listenText' ([ordered]@{ culture = 'en-US'; repliesText = '[{"openUntil":"2026-10-15T09:30:00.0000000Z"}]' })
    New-NvGatesCase 'listenText: a zoneless window east of UTC' 'listenText' ([ordered]@{ culture = 'en-US'; replies = [ordered]@{ openUntil = '2026-10-15T14:00:00' } }) $india 330
} -Expect {
    param($In, $Name)
    $gtDir = Enter-NvData $Name
    $gtCulture = if ($In.PSObject.Properties['culture']) { [string]$In.culture } else { 'en-US' }
    Use-NvCulture $gtCulture {
        Use-NvTimeZone ([string]$In.zone) {
            Use-NvClock ([string]$In.now) {
                $gtOff = [System.TimeZoneInfo]::Local.GetUtcOffset((Get-Date)).TotalMinutes
                if ($gtOff -ne [int]$In.utcOffsetMinutes) { throw "$($In.zone) is $gtOff minutes from UTC, not $($In.utcOffsetMinutes)" }
                switch ([string]$In.fn) {
                    'replyOpen' {
                        Write-NvGatesFile $script:ChatqConfigPath $In 'config' 'configText'
                        Write-NvGatesFile $script:ChatqReplyPath $In 'replies' 'repliesText'
                        return [ordered]@{ open = [bool](Test-ChatqReplyOpen) }
                    }
                    'held' {
                        New-NvGatesHeldFiles $gtDir $In
                        return [ordered]@{ waiting = [bool](Test-ChatqHeldWaiting) }
                    }
                    'heldSummary' {
                        Write-NvGatesFile $script:ChatqConfigPath $In 'config' 'configText'
                        New-NvGatesHeldFiles $gtDir $In
                        # Send-ChatqHeldSummary as the loop calls it, its claim
                        # stubbed: due is that it got as far as the claim
                        $gtClaim = @{ N = 0 }
                        function Invoke-ChatqLocked { $gtClaim.N++; $null }
                        $gtWas = @{ Tried = $script:ChatqSummaryTriedAt; Sending = $script:ChatqSendingSummary }
                        $script:ChatqSummaryTriedAt = if ($In.PSObject.Properties['triedSecondsAgo']) { (Get-Date).AddSeconds(-[int]$In.triedSecondsAgo) } else { $null }
                        $script:ChatqSendingSummary = $false
                        try { $null = Send-ChatqHeldSummary }
                        finally { $script:ChatqSummaryTriedAt = $gtWas.Tried; $script:ChatqSendingSummary = $gtWas.Sending }
                        return [ordered]@{ due = ($gtClaim.N -gt 0) }
                    }
                    'auto' {
                        Write-NvGatesFile $script:ChatqConfigPath $In 'config' 'configText'
                        Write-NvGatesFile $script:ChatqAutoPath $In 'autoState' 'autoText'
                        # Get-ChatqAutoConfig's copy is per process: start without one
                        $gtWasCache = $script:ChatqAutoCache
                        $script:ChatqAutoCache = $null
                        try { $gtWanted = Test-ChatqAutoWanted }
                        finally { $script:ChatqAutoCache = $gtWasCache }
                        return [ordered]@{ wanted = [bool]$gtWanted }
                    }
                    'soon' {
                        Write-NvGatesFile $script:ChatqConfigPath $In 'config' 'configText'
                        # $W.blocked as the watcher keeps it: At added when the lane was blocked
                        $gtW = New-ChatqWatchState
                        foreach ($gtB in (Get-NvGatesList $In 'blocked')) {
                            $gtE = [pscustomobject]@{ Until = (ConvertTo-ChatqDate ([string]$gtB.until)); Type = [string]$gtB.type; Source = 'vector' }
                            if ($gtB.PSObject.Properties['at']) { $gtE | Add-Member -NotePropertyName At -NotePropertyValue (ConvertTo-ChatqDate ([string]$gtB.at)) }
                            $gtW.blocked[[string]$gtB.lane] = $gtE
                        }
                        # the queued jobs as the loop hands them on, read from data/queue
                        $null = New-Item -ItemType Directory -Path $script:ChatqQueueDir -Force
                        foreach ($gtJ in (Get-NvGatesList $In 'jobs')) { Write-NvGatesText (Join-Path $script:ChatqQueueDir "$($gtJ.id).json") (ConvertTo-NvJson $gtJ) }
                        $gtQueued = @(Get-ChatqJobs | Where-Object { $_.state -eq 'queued' })
                        # data/usage-alerts.json: fileHas's keys, each sent at 08:00
                        # unless it names its value, or fileText as it is
                        $gtFile = [ordered]@{}
                        foreach ($gtX in (Get-NvGatesList $In 'fileHas')) {
                            $gtFile[(Get-NvGatesSoonKey $gtX)] = if ($gtX.PSObject.Properties['value']) { $gtX.value } else { '2026-10-15T08:00:00.0000000Z' }
                        }
                        if ($gtFile.Count) { Write-NvGatesText $script:ChatqUsageAlertPath (ConvertTo-NvJson $gtFile) }
                        elseif ($In.PSObject.Properties['fileText']) { Write-NvGatesText $script:ChatqUsageAlertPath ([string]$In.fileText) }
                        $gtHad = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
                        foreach ($gtKey in @((Get-ChatqUsageAlertState).Keys)) { [void]$gtHad.Add($gtKey) }
                        $gtSent = @{}
                        $gtBefore = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
                        foreach ($gtX in (Get-NvGatesList $In 'sentBefore')) {
                            $gtKey = Get-NvGatesSoonKey $gtX
                            $gtSent[$gtKey] = $true
                            [void]$gtBefore.Add($gtKey)
                        }
                        # the send stubbed; a failure the function would only log fails the case
                        $gtAlerts = @{ N = 0 }
                        function Send-ChatqAlert { $gtAlerts.N++; $true }
                        function Write-ChatqWatchLog { param([string]$Text) if ($Text -like 'usage soon alert:*') { throw "Send-ChatqUsageSoon failed: $Text" } }
                        $gtWasSent = $script:ChatqUsageSent
                        $script:ChatqUsageSent = $gtSent
                        try { $gtNext = Send-ChatqUsageSoon $gtW $gtQueued }
                        finally { $script:ChatqUsageSent = $gtWasSent }
                        $gtDue = @(foreach ($gtKey in @($gtSent.Keys)) { if (-not $gtBefore.Contains($gtKey)) { $gtKey } })
                        $gtGone = @(foreach ($gtKey in @((Get-ChatqUsageAlertState).Keys)) { if (-not $gtHad.Contains($gtKey)) { $gtKey } })
                        return [ordered]@{ next = (Get-NvGatesStamp $gtNext); due = (Get-NvGatesSorted $gtDue); send = (Get-NvGatesSorted $gtGone); alerts = $gtAlerts.N }
                    }
                    'route' {
                        Write-NvGatesFile $script:ChatqConfigPath $In 'config' 'configText'
                        # every gate before the registration held open, every channel stubbed
                        $gtReg = @{ N = 0 }
                        function Test-ChatqHeldWaiting { $false }
                        function Send-ChatqHeldSummary { $false }
                        function Test-ChatqUserPresent { $false }
                        function Show-ChatqToast { }
                        function Invoke-ChatqAlertCommand { $null }
                        function Test-ChatqHoldAlert { $false }
                        function Test-ChatqQuietIn { $false }
                        function Get-ChatqAlertFooter { $null }
                        function New-ChatqReplyAlert { $gtReg.N++; $null }
                        function Update-ChatqReplyFull { }
                        function Send-ChatqNtfy { $null }
                        function Send-ChatqJoin { $null }
                        function Open-ChatqReplyWindow { }
                        function Test-ChatqWatcherAlive { $true }
                        function Start-ChatqWatcherProcess { $true }
                        $gtWas = @{ Report = $script:ChatqAlertReport; Aid = $script:ChatqLastAlertAid; Err = $script:ChatqLastAlertError }
                        try { $gtWent = Send-ChatqAlert 'done' 'x' 0 -NoReply:([bool]$In.noReply) }
                        finally { $script:ChatqAlertReport = $gtWas.Report; $script:ChatqLastAlertAid = $gtWas.Aid; $script:ChatqLastAlertError = $gtWas.Err }
                        if (-not $gtWent) { throw 'the alert stopped short of the phone: a gate the route holds open closed' }
                        $gtLinks = (Get-ChatqReplyConfig (Get-ChatqConfig)).Links
                        return [ordered]@{ links = [bool]$gtLinks; answerable = ($gtReg.N -gt 0) }
                    }
                    'pollSeconds' {
                        Write-NvGatesFile $script:ChatqReplyPath $In 'replies' 'repliesText'
                        return [ordered]@{ seconds = [int](Get-ChatqReplyPollSeconds -InRun:([bool]$In.inRun)) }
                    }
                    'listenText' {
                        Write-NvGatesFile $script:ChatqReplyPath $In 'replies' 'repliesText'
                        $gtSep = [System.Threading.Thread]::CurrentThread.CurrentCulture.DateTimeFormat.TimeSeparator
                        return [ordered]@{ timeSep = $gtSep; text = [string](Get-ChatqReplyListenText) }
                    }
                    default { throw "no fn '$($In.fn)'" }
                }
            }
        }
    }
}
