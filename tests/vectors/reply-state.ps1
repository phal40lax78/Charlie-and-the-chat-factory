# tests/vectors/reply-state.ps1: native/vectors/reply-state.json, the reply
# registry data/replies.json through Use-ChatqReplyState (src/phone.ps1):
# Get-ChatqReplyState's read under data/replies.lock, a change - the
# watcher's junk-only one (native/SPEC.md 1.3) unless a case says - and
# Save-ChatqReplyState's write at now, with its fixed key set and every
# prune (Get-ChatqBoardState's too, src/phone-down.ps1). The answer is the
# file the save left, read back; or, for the recipe that pins the caps, the
# alert, pick and nonce names it kept; or what was thrown and whether the
# file was left alone. native/crates/chatq-core/tests/reply_state_vectors.rs
# checks chatq_core::replystate against it.

function Get-NvReplyStateZone([int]$Minutes) {
    # Windows zones with no DST, for the offsets the cases use
    switch ($Minutes) {
        540 { return 'Korea Standard Time' }
        -300 { return 'SA Pacific Standard Time' }
    }
    throw "reply-state: no zone for $Minutes minutes"
}

function New-NvReplyStateInput {
    # a case's input: KST, now 12:00Z, reply.hours 12 and the junk-only
    # change unless it says otherwise; $More's keys over those
    param($File, [string]$Change = 'junk', $More)
    $i = [ordered]@{ utcOffsetMinutes = 540; now = '2026-10-15T12:00:00Z'; hours = 12; file = $File }
    $i['change'] = switch ($Change) {
        'junk' { [ordered]@{ lastId = 'junk-1'; polled = $true } }
        'polled' { [ordered]@{ polled = $true } }
        default { $null }
    }
    if ($More) { foreach ($k in @($More.Keys)) { $i[$k] = $More[$k] } }
    return $i
}

function New-NvReplyStateCase([string]$Name, $In) { return [ordered]@{ name = $Name; input = $In } }
function New-NvReplyStateJson($Value) { return [ordered]@{ json = $Value } }
function New-NvReplyStateText([string]$Text) { return [ordered]@{ text = $Text } }
function New-NvReplyStateHex([string]$Hex) { return [ordered]@{ hex = $Hex } }

function Get-NvReplyStateBytes($File) {
    # the bytes a case's file starts as
    if (Get-NvHas $File 'hex') { return , (ConvertFrom-NvHex ([string]$File.hex)) }
    if (Get-NvHas $File 'text') { return , $script:NvUtf8.GetBytes([string]$File.text) }
    return , $script:NvUtf8.GetBytes((ConvertTo-NvJson $File.json -Compress))
}

function Get-NvReplyStateB32([int]$I) {
    # a pick's name, six of the letters Read-ChatqBoardState takes
    $abc = 'abcdefghijklmnopqrstuvwxyz234567'
    $s = ''
    for ($k = 5; $k -ge 0; $k--) { $s += $abc[($I -shr (5 * $k)) -band 31] }
    return $s
}

function New-NvReplyStateRecipe($R) {
    # $R.alerts alerts, the first with no time and the rest $R.alertStep
    # minutes apart in a shuffled order, and $R.picks picks the same way in
    # seconds: more than either cap keeps
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $rt = [System.Globalization.DateTimeStyles]::RoundtripKind
    $alerts = [ordered]@{}
    $n = [int]$R.alerts
    $base = [datetime]::Parse([string]$R.alertBase, $inv, $rt)
    for ($i = 0; $i -lt $n; $i++) {
        $at = if ($i -eq 0) { $null } else { $base.AddMinutes(($i * [int]$R.alertStep) % $n).ToString('o') }
        $alerts['a' + $i.ToString('000')] = [ordered]@{ at = $at; expires = [string]$R.alertExpires }
    }
    $picks = [ordered]@{}
    $m = [int]$R.picks
    $pbase = [datetime]::Parse([string]$R.pickBase, $inv, $rt)
    for ($i = 0; $i -lt $m; $i++) {
        $picks[(Get-NvReplyStateB32 $i)] = [ordered]@{ kind = 'k'; at = $pbase.AddSeconds(($i * [int]$R.pickStep) % $m).ToString('o'); expires = [string]$R.pickExpires }
    }
    return [ordered]@{ alerts = $alerts; picks = $picks; seen = $R.seen }
}

function Get-NvReplyStateKeys($Obj, [bool]$Sort) {
    $k = [string[]]@(foreach ($p in $Obj.PSObject.Properties) { $p.Name })
    if ($Sort) { [Array]::Sort($k, [StringComparer]::Ordinal) }
    return , $k
}

function ConvertTo-NvReplyStateFile($J) {
    # the saved file as the answer: its seen, refused and downSent sorted by
    # name, as they come out of hashtables, whose order nothing fixes
    $o = [ordered]@{}
    foreach ($p in $J.PSObject.Properties) {
        if ('seen', 'refused', 'downSent' -ccontains $p.Name) {
            $s = [ordered]@{}
            foreach ($k in (Get-NvReplyStateKeys $p.Value $true)) { $s[$k] = $p.Value.PSObject.Properties[$k].Value }
            $o[$p.Name] = $s
        }
        else { $o[$p.Name] = $p.Value }
    }
    return $o
}

function Invoke-NvReplyState($Change, [double]$Hours, $Out) {
    # Use-ChatqReplyState with the case's change; what it throws, by kind
    $block = {
        param($st)
        if ($null -ne $Change) {
            if ($Change.PSObject.Properties['lastId']) { $st.lastId = [string]$Change.lastId }
            if ($Change.PSObject.Properties['polled'] -and $Change.polled) { $st.lastPolledAt = Get-ChatqStamp }
        }
    }
    try { $null = Use-ChatqReplyState $block $Hours }
    catch {
        $m = [string]$_.Exception.Message
        if ($m -ceq 'data/replies.lock is held by another process') { $Out.threw = 'locked' }
        elseif ($m.StartsWith('data/replies.json could not be read:', [StringComparison]::Ordinal)) { $Out.threw = 'unreadable' }
        elseif ($m.StartsWith('Cannot convert', [StringComparison]::Ordinal)) { $Out.threw = 'invalid' }
        else { throw }
    }
}

Register-NvVector -Name 'reply-state' -About ('Use-ChatqReplyState (src/phone.ps1) on data/replies.json: the file (none, json, text or hex bytes; ' +
    'a recipe makes the caps case) read under data/replies.lock, the change (the watcher''s junk-only one: lastId and lastPolledAt; ' +
    'polled: lastPolledAt only; null: none) and Save-ChatqReplyState''s write at now in a zone utcOffsetMinutes east, with reply.hours ' +
    'hours (0: from config). The answer is the saved file read back, its seen, refused and downSent sorted by name (hashtables, in no ' +
    'fixed order); for a recipe the alert, pick and seen names kept; or threw (locked, unreadable, invalid) and whether the file was ' +
    'left unchanged. repair marks a file chatqd refuses to write back (SPEC 2.2), its read and save checked one step lower.') -Cases {
    $fut = '2026-10-15T13:00:00.0000000Z'
    $past = '2026-10-15T11:00:00.0000000Z'
    $atNow = '2026-10-15T12:00:00.0000000Z'
    $tick = '2026-10-15T12:00:00.0000001Z'
    $utf8 = New-Object System.Text.UTF8Encoding $false

    # --- the file, or what stands in for it
    New-NvReplyStateCase 'no file' (New-NvReplyStateInput $null)
    New-NvReplyStateCase 'no file, no change' (New-NvReplyStateInput $null 'none')
    New-NvReplyStateCase 'no data folder' (New-NvReplyStateInput $null 'junk' ([ordered]@{ noData = $true }))
    New-NvReplyStateCase 'empty file' (New-NvReplyStateInput (New-NvReplyStateText ''))
    New-NvReplyStateCase 'white space only' (New-NvReplyStateInput (New-NvReplyStateText " `r`n`t "))
    New-NvReplyStateCase 'not json' (New-NvReplyStateInput (New-NvReplyStateText '{not json'))
    foreach ($t in 'null', '[]', '[0]', '0', 'false', '""', '"x"', '5', 'true') {
        New-NvReplyStateCase "the file is $t" (New-NvReplyStateInput (New-NvReplyStateText $t))
    }
    New-NvReplyStateCase 'a UTF-8 BOM' (New-NvReplyStateInput (New-NvReplyStateHex ('efbbbf' + (ConvertTo-NvHex ($utf8.GetBytes('{"lastId":"m-1","since":7}'))))) 'polled')
    New-NvReplyStateCase 'two BOMs' (New-NvReplyStateInput (New-NvReplyStateHex 'efbbbfefbbbf7b7d'))
    New-NvReplyStateCase 'names differing only by case' (New-NvReplyStateInput (New-NvReplyStateText '{"lastId":"a","LastId":"b"}'))
    New-NvReplyStateCase 'names differing only by case, deeper' (New-NvReplyStateInput (New-NvReplyStateText '{"alerts":{"x":{"at":"2026-10-15T11:00:00Z","AT":"2026-10-15T11:00:00Z"}}}'))
    New-NvReplyStateCase 'an empty name' (New-NvReplyStateInput (New-NvReplyStateText '{"":1,"lastId":"a"}'))
    New-NvReplyStateCase 'an empty name, deeper' (New-NvReplyStateInput (New-NvReplyStateText '{"seen":{"":"2026-10-15T11:00:00Z"}}'))
    New-NvReplyStateCase 'one name twice' (New-NvReplyStateInput (New-NvReplyStateText '{"lastId":"a","lastId":"b"}') 'polled')
    New-NvReplyStateCase 'the lock held' (New-NvReplyStateInput (New-NvReplyStateJson ([ordered]@{ lastId = 'm-1' })) 'junk' ([ordered]@{ lock = 'held' }))
    New-NvReplyStateCase 'invalid UTF-8' (New-NvReplyStateInput (New-NvReplyStateHex ((ConvertTo-NvHex ($utf8.GetBytes('{"lastId":"a'))) + 'ff' + (ConvertTo-NvHex ($utf8.GetBytes('b"}'))))) 'polled' ([ordered]@{ repair = $true }))
    New-NvReplyStateCase 'a lone surrogate escape' (New-NvReplyStateInput (New-NvReplyStateText '{"lastId":"cut \ud83d"}') 'polled' ([ordered]@{ repair = $true }))
    # each edition's ConvertFrom-Json grammar and case fold
    New-NvReplyStateCase 'a name past ASCII' (New-NvReplyStateInput (New-NvReplyStateText ('{"lastId":"a","since":7,"' + [char]0xFC + '":1}')) 'polled')
    New-NvReplyStateCase 'a line comment before the object' (New-NvReplyStateInput (New-NvReplyStateText ("// replies`n" + '{"lastId":"a","since":7}')) 'polled')
    New-NvReplyStateCase 'a micro sign and a capital mu' (New-NvReplyStateInput (New-NvReplyStateText ('{"lastId":"a","' + [char]0xB5 + '":1,"' + [char]0x39C + '":2}')) 'polled')

    # --- the changes, on a file with something in every part
    $rich = [ordered]@{
        openUntil = '2026-10-15T14:00:00.0000000Z'; since = 1760529600; lastId = 'm-41'
        lastPolledAt = '2026-10-15T11:55:00.0000000Z'; lastReplyAt = $past
        alerts = [ordered]@{
            k7 = [ordered]@{
                at = $past; expires = '2026-10-15T23:00:00.0000000Z'; event = 'done'; jobId = 'j1'; seq = 3; sessionId = 's1'
                provider = 'claude'; title = 't1'; uses = 1; path = 'C:\w\a.jsonl'; cwd = 'C:\w'; home = $null; mark = 'j1@3'; len = 1200
            }
        }
        seen = [ordered]@{ n1 = '2026-10-15T11:59:00.0000000Z'; n0 = '2026-10-13T00:00:00.0000000Z' }
        refused = [ordered]@{ k7 = '2026-10-15T11:30:00.0000000Z' }
        pairCandidates = @([ordered]@{ id = 'c1'; pid = 'p1'; d = [ordered]@{ value = 'dmFsdWU='; protected = $false }; label = 'phone'; code = '123456'; at = '2026-10-15T11:58:00.0000000Z'; expires = '2026-10-15T12:10:00.0000000Z' })
        picks = [ordered]@{ abcdef = [ordered]@{ kind = 'job'; jobId = 'j1'; at = $past; expires = '2026-10-15T23:00:00.0000000Z' } }
        standing = $true
        compose = @([ordered]@{ at = '2026-10-15T11:50:00.0000000Z'; act = 'new' })
        down = [ordered]@{ day = '2026-10-15'; full = 1; other = 2 }
        downSent = [ordered]@{ m1 = [ordered]@{ at = '2026-10-15T10:00:00.0000000Z'; attached = $true } }
        composeRefusedAt = '2026-10-15T11:40:00.0000000Z'; hotUntil = '2026-10-15T12:30:00.0000000Z'
    }
    New-NvReplyStateCase 'the junk-only change' (New-NvReplyStateInput (New-NvReplyStateJson $rich))
    New-NvReplyStateCase 'lastPolledAt only' (New-NvReplyStateInput (New-NvReplyStateJson $rich) 'polled')
    New-NvReplyStateCase 'no change' (New-NvReplyStateInput (New-NvReplyStateJson $rich) 'none')

    # --- the top level
    New-NvReplyStateCase 'top-level fields as PowerShell casts them' (New-NvReplyStateInput (New-NvReplyStateText '{"openUntil":"2026-10-15T21:00:00+09:00","since":1.5,"lastId":123,"lastPolledAt":5,"lastReplyAt":"tomorrow","standing":1,"composeRefusedAt":true,"hotUntil":null}') 'none')
    foreach ($t in '"42"', '0', 'true', '"abc"', '1e20', '"-5"', '{}') {
        New-NvReplyStateCase "since $t" (New-NvReplyStateInput (New-NvReplyStateText ('{"since":' + $t + '}')) 'none')
    }
    foreach ($t in 'true', '0', '""') {
        New-NvReplyStateCase "lastId $t" (New-NvReplyStateInput (New-NvReplyStateText ('{"lastId":' + $t + '}')) 'none')
    }
    New-NvReplyStateCase 'names it does not know' (New-NvReplyStateInput (New-NvReplyStateJson ([ordered]@{ lastId = 'a'; foo = 1; bar = [ordered]@{ x = 1 } })) 'none')
    New-NvReplyStateCase 'names in any case' (New-NvReplyStateInput (New-NvReplyStateJson ([ordered]@{ OpenUntil = '2026-10-15T14:00:00Z'; LASTID = 'a'; Alerts = [ordered]@{ q1 = [ordered]@{ AT = $past; Expires = $fut; Event = 'done' } }; Standing = $true })) 'none')
    $zoneless = New-NvReplyStateJson ([ordered]@{ openUntil = '2026-10-15T21:00:00' })
    New-NvReplyStateCase 'a stamp with no zone' (New-NvReplyStateInput $zoneless 'none')
    New-NvReplyStateCase 'a stamp with no zone, west of UTC' (New-NvReplyStateInput $zoneless 'none' ([ordered]@{ utcOffsetMinutes = -300 }))
    New-NvReplyStateCase 'a stamp with no zone and a space' (New-NvReplyStateInput (New-NvReplyStateJson ([ordered]@{ openUntil = '2026-10-15 21:00:00' })) 'none')
    New-NvReplyStateCase 'a stamp as \/Date(ms)\/' (New-NvReplyStateInput (New-NvReplyStateText '{"openUntil":"\/Date(1760529600000)\/"}') 'none')

    # --- alerts
    New-NvReplyStateCase 'an alert with every field' (New-NvReplyStateInput (New-NvReplyStateJson ([ordered]@{ alerts = [ordered]@{
                    q1 = [ordered]@{
                        at = $past; expires = $fut; event = 'permit'; jobId = 'j9'; seq = 4; sessionId = 's9'; provider = 'codex'
                        title = (U '\uD55C\uAE00 \uD83D\uDE00'); uses = 2; path = 'C:\w\x.jsonl'; cwd = 'C:\w'; home = 'C:\h'; live = $true; usage = 'soon'
                        permit = [ordered]@{ run = 'r1'; rid = 'q'; digest = 'abc'; until = '2026-10-15T21:30:00+09:00'; state = 'asked'; tool = 'Bash'; toolUseId = 'tu1'; asked = '2026-10-15T11:00:00Z'; answeredAt = $null }
                        mark = 'm9'; seen = '2026-10-15T11:01:00Z'; len = 345
                    }
                } })) 'none')
    New-NvReplyStateCase 'alerts past their expiry' (New-NvReplyStateInput (New-NvReplyStateJson ([ordered]@{ alerts = [ordered]@{
                    e1 = [ordered]@{ at = '2026-10-15T10:01:00.0000000Z'; expires = $past }
                    e2 = [ordered]@{ at = '2026-10-15T10:02:00.0000000Z'; expires = $atNow }
                    e3 = [ordered]@{ at = '2026-10-15T10:03:00.0000000Z'; expires = $tick }
                    e4 = [ordered]@{ at = '2026-10-15T10:04:00.0000000Z'; expires = $null }
                    e5 = [ordered]@{ at = '2026-10-15T10:05:00.0000000Z'; expires = 'garbage' }
                    e6 = [ordered]@{ at = '2026-10-15T10:06:00.0000000Z' }
                } })) 'none')
    New-NvReplyStateCase 'alert fields as PowerShell casts them' (New-NvReplyStateInput (New-NvReplyStateJson ([ordered]@{ alerts = [ordered]@{
                    c1 = [ordered]@{ at = '2026-10-15T10:01:00.0000000Z'; expires = $fut; event = 5; seq = '0'; uses = '3'; home = $null; live = 'TRUE'; usage = ''; mark = 5; len = $null }
                    c2 = [ordered]@{ at = '2026-10-15T10:02:00.0000000Z'; expires = $fut; event = $true; jobId = $false; seq = 0; title = 0; uses = ' 7 '; home = ''; live = '1'; len = 'abc' }
                    c3 = [ordered]@{ at = '2026-10-15T10:03:00.0000000Z'; expires = $fut; seq = 2.5; uses = 2.5; live = 1; len = '12' }
                    c4 = [ordered]@{ at = '2026-10-15T10:04:00.0000000Z'; expires = $fut; seq = '-3'; uses = $true; live = $false; len = 2.5 }
                    c5 = [ordered]@{ at = '2026-10-15T10:05:00.0000000Z'; expires = $fut; uses = $null; len = $true; seen = 'garbage'; mark = '' }
                } })) 'none')
    New-NvReplyStateCase 'alerts that are no object' (New-NvReplyStateInput (New-NvReplyStateJson ([ordered]@{ alerts = [ordered]@{
                    a = $null; b = 0; c = ''; d = 'x'; e = 5; f = $true; g = @(); h = [ordered]@{ at = $past; expires = $fut }
                } })) 'none')
    New-NvReplyStateCase 'permit blocks' (New-NvReplyStateInput (New-NvReplyStateJson ([ordered]@{ alerts = [ordered]@{
                    p1 = [ordered]@{ at = '2026-10-15T10:01:00.0000000Z'; expires = $fut; permit = [ordered]@{ RUN = 'r'; rid = 5; digest = ''; until = 'garbage'; state = $true; Tool = 'Bash'; toolUseId = 0; asked = 5; answeredAt = $past } }
                    p2 = [ordered]@{ at = '2026-10-15T10:02:00.0000000Z'; expires = $fut; permit = 'x' }
                    p3 = [ordered]@{ at = '2026-10-15T10:03:00.0000000Z'; expires = $fut; permit = [ordered]@{} }
                    p4 = [ordered]@{ at = '2026-10-15T10:04:00.0000000Z'; expires = $fut; permit = @() }
                    p5 = [ordered]@{ at = '2026-10-15T10:05:00.0000000Z'; expires = $fut; permit = @('x') }
                    p6 = [ordered]@{ at = '2026-10-15T10:06:00.0000000Z'; expires = $fut; permit = 0 }
                } })) 'none')
    New-NvReplyStateCase 'alerts oldest first' (New-NvReplyStateInput (New-NvReplyStateJson ([ordered]@{ alerts = [ordered]@{
                    z1 = [ordered]@{ at = '2026-10-15T11:30:00.0000000Z'; expires = $fut }
                    z2 = [ordered]@{ at = '2026-10-15T10:00:00.0000000Z'; expires = $fut }
                    z3 = [ordered]@{ at = $null; expires = $fut }
                    z4 = [ordered]@{ at = '2026-10-15T11:00:00+00:00'; expires = $fut }
                } })) 'none')
    New-NvReplyStateCase 'a use count no number' (New-NvReplyStateInput (New-NvReplyStateJson ([ordered]@{ alerts = [ordered]@{ x = [ordered]@{ at = $past; expires = $past; uses = 'abc' } } })))
    New-NvReplyStateCase 'a use count past Int32' (New-NvReplyStateInput (New-NvReplyStateJson ([ordered]@{ alerts = [ordered]@{ x = [ordered]@{ at = $past; expires = $fut; uses = 10000000000 } } })))
    New-NvReplyStateCase 'a use count that is an object' (New-NvReplyStateInput (New-NvReplyStateJson ([ordered]@{ alerts = [ordered]@{ x = [ordered]@{ at = $past; expires = $fut; uses = [ordered]@{ n = 1 } } } })))
    New-NvReplyStateCase 'a use count that is a list' (New-NvReplyStateInput (New-NvReplyStateJson ([ordered]@{ alerts = [ordered]@{ x = [ordered]@{ at = $past; expires = $fut; uses = @(5) } } })))
    New-NvReplyStateCase 'a seq past Int32' (New-NvReplyStateInput (New-NvReplyStateJson ([ordered]@{ alerts = [ordered]@{ x = [ordered]@{ at = $past; expires = $fut; seq = '99999999999' } } })))

    # --- the caps: 200 alerts, 300 picks, the newest kept
    New-NvReplyStateCase '200 alerts and 300 picks at most' (New-NvReplyStateInput $null 'junk' ([ordered]@{ recipe = [ordered]@{
                    alerts = 205; alertBase = '2026-10-14T00:00:00Z'; alertStep = 37; alertExpires = '2026-10-16T00:00:00.0000000Z'
                    picks = 305; pickBase = '2026-10-15T00:00:00Z'; pickStep = 37; pickExpires = '2026-10-16T00:00:00.0000000Z'
                    # the oldest alert kept is 00:05, so nonces after 23:55 the
                    # day before stay; one capped out (00:01) would keep s1
                    seen = [ordered]@{ s1 = '2026-10-13T23:53:00.0000000Z'; s2 = '2026-10-13T23:55:00.0000000Z'; s3 = '2026-10-13T23:56:00.0000000Z'; s4 = '2026-10-14T11:00:00.0000000Z' }
                } }))

    # --- spent nonces: newer than twice reply.hours and 10 minutes, and
    # than every alert still out, less 10 minutes
    New-NvReplyStateCase 'nonces kept a day and 20 minutes' (New-NvReplyStateInput (New-NvReplyStateJson ([ordered]@{ seen = [ordered]@{
                    s1 = '2026-10-14T11:40:00.0000000Z'; s2 = '2026-10-14T11:40:00.0000001Z'; s3 = '2026-10-14T11:00:00.0000000Z'; s4 = $null
                    s5 = 'garbage'; s6 = $fut; s7 = '2026-10-15T21:00:00+09:00'
                } })) 'none')
    New-NvReplyStateCase 'nonces kept while an alert is out' (New-NvReplyStateInput (New-NvReplyStateJson ([ordered]@{
                alerts = [ordered]@{
                    a1 = [ordered]@{ at = '2026-10-14T05:00:00.0000000Z'; expires = $fut }
                    a2 = [ordered]@{ at = '2026-10-13T00:00:00.0000000Z'; expires = $past }
                }
                seen = [ordered]@{
                    s1 = '2026-10-14T04:50:00.0000000Z'; s2 = '2026-10-14T04:50:00.0000001Z'; s3 = '2026-10-14T04:49:00.0000000Z'
                    s4 = '2026-10-14T11:00:00.0000000Z'; s5 = '2026-10-13T12:00:00.0000000Z'
                }
            })) 'none')
    # one set of nonces for every reply.hours: the cut is 09:40 at 1 hour,
    # 07:40 at 2, 23:40 the day before at 6 and 11:40 the day before at 12
    $hseen = New-NvReplyStateJson ([ordered]@{ seen = [ordered]@{
                s1 = '2026-10-15T09:40:00.0000000Z'; s2 = '2026-10-15T09:40:00.0000001Z'; s3 = '2026-10-15T09:00:00.0000000Z'
                s4 = '2026-10-15T07:40:00.0000000Z'; s5 = '2026-10-15T07:40:00.0000001Z'; s6 = '2026-10-14T23:40:00.0000000Z'
                s7 = '2026-10-14T23:40:00.0000001Z'; s8 = '2026-10-14T11:40:00.0000000Z'; s9 = '2026-10-14T11:40:00.0000001Z'
            } })
    New-NvReplyStateCase 'reply.hours from config.json' (New-NvReplyStateInput $hseen 'none' ([ordered]@{ hours = 0; config = [ordered]@{ reply = [ordered]@{ hours = 1 } } }))
    New-NvReplyStateCase 'reply.hours as a string' (New-NvReplyStateInput $hseen 'none' ([ordered]@{ hours = 0; config = [ordered]@{ reply = [ordered]@{ hours = '6' } } }))
    New-NvReplyStateCase 'reply.hours below zero' (New-NvReplyStateInput $hseen 'none' ([ordered]@{ hours = 0; config = [ordered]@{ reply = [ordered]@{ hours = -1 } } }))
    New-NvReplyStateCase 'reply.hours in any case' (New-NvReplyStateInput $hseen 'none' ([ordered]@{ hours = 0; config = [ordered]@{ Reply = [ordered]@{ Hours = 1 } } }))
    New-NvReplyStateCase 'reply no object' (New-NvReplyStateInput $hseen 'none' ([ordered]@{ hours = 0; config = [ordered]@{ reply = 'x' } }))
    New-NvReplyStateCase 'no config.json' (New-NvReplyStateInput $hseen 'none' ([ordered]@{ hours = 0 }))
    New-NvReplyStateCase 'hours given, not read' (New-NvReplyStateInput $hseen 'none' ([ordered]@{ hours = 2; config = [ordered]@{ reply = [ordered]@{ hours = 1 } } }))

    # --- refusals, pairing answers
    New-NvReplyStateCase 'refusals kept an hour' (New-NvReplyStateInput (New-NvReplyStateJson ([ordered]@{ refused = [ordered]@{
                    r1 = $past; r2 = '2026-10-15T11:00:00.0000001Z'; r3 = '2026-10-15T10:00:00.0000000Z'; r4 = $null; r5 = 'garbage'; r6 = $fut
                } })) 'none')
    New-NvReplyStateCase 'pairing answers' (New-NvReplyStateInput (New-NvReplyStateJson ([ordered]@{ pairCandidates = @(
                    [ordered]@{ id = 'c1'; pid = 'p1'; d = [ordered]@{ value = 'x'; protected = $true }; label = 'phone'; code = '111111'; at = $past; expires = $fut }
                    [ordered]@{ id = 'c2'; pid = 'p2'; d = [ordered]@{ value = 'y'; protected = $false }; label = 'l'; code = 'c'; at = $past; expires = $atNow }
                    [ordered]@{ pid = 'p3'; d = [ordered]@{ value = 'z' }; expires = $fut }
                    [ordered]@{ id = 'c4'; pid = 'p4'; expires = $fut }
                    [ordered]@{ id = 'c5'; pid = 0; d = [ordered]@{ value = 'q' }; expires = $fut }
                    $null
                    [ordered]@{ id = 42; pid = 'p7'; d = 'raw'; code = 5; expires = $fut }
                ) })) 'none')
    New-NvReplyStateCase 'one pairing answer, not in a list' (New-NvReplyStateInput (New-NvReplyStateJson ([ordered]@{ pairCandidates = [ordered]@{ id = 'c1'; pid = 'p1'; d = [ordered]@{ value = 'x'; protected = $true }; label = 'phone'; code = '1'; at = $past; expires = $fut } })) 'none')

    # --- the board's own (src/phone-down.ps1)
    New-NvReplyStateCase 'picks' (New-NvReplyStateInput (New-NvReplyStateJson ([ordered]@{ picks = [ordered]@{
                    abcdef = [ordered]@{ kind = 'job'; sessionId = 's'; provider = 'claude'; path = 'p'; cwd = 'c'; home = $null; title = 't'; jobId = 'j'; seq = '3'; mark = 'm'; len = 0; at = '2026-10-15T10:00:00Z'; expires = $fut }
                    QWERTY = [ordered]@{ kind = 'upper'; at = '2026-10-15T10:01:00Z'; expires = $fut }
                    abcde1 = [ordered]@{ kind = 'digit'; at = '2026-10-15T10:02:00Z'; expires = $fut }
                    abcde7 = [ordered]@{ kind = 'k'; at = '2026-10-15T10:03:00Z'; expires = $fut; seq = 0; title = ''; len = 'abc'; home = 'C:\h' }
                    abcdefg = [ordered]@{ kind = 'long'; at = '2026-10-15T10:04:00Z'; expires = $fut }
                    "abcdeg`n" = [ordered]@{ kind = 'newline'; at = '2026-10-15T10:05:00Z'; expires = $fut }
                    abc = [ordered]@{ kind = 'short'; at = '2026-10-15T10:06:00Z'; expires = $fut }
                    zzzzzz = [ordered]@{ kind = 'old'; at = '2026-10-15T10:07:00Z'; expires = $past }
                    qqqqqq = $null
                    rrrrrr = [ordered]@{ kind = 5; at = '2026-10-15T10:08:00Z'; expires = $tick }
                } })) 'none')
    New-NvReplyStateCase 'compose acts' (New-NvReplyStateInput (New-NvReplyStateJson ([ordered]@{ compose = @(
                    [ordered]@{ at = '2026-10-15T11:30:00Z'; act = 'new' }
                    [ordered]@{ at = $past; act = 'old' }
                    [ordered]@{ at = '2026-10-15T11:00:00.0000001Z'; act = 5 }
                    [ordered]@{ at = $null; act = 'x' }
                    [ordered]@{ act = 'y' }
                    $null
                    [ordered]@{ at = 'garbage'; act = 'g' }
                    [ordered]@{ at = '2026-10-15T11:45:00Z' }
                ) })) 'none')
    New-NvReplyStateCase 'one compose act, not in a list' (New-NvReplyStateInput (New-NvReplyStateJson ([ordered]@{ compose = [ordered]@{ at = '2026-10-15T11:30:00Z'; act = 'new' } })) 'none')
    New-NvReplyStateCase 'down, and the board''s times' (New-NvReplyStateInput (New-NvReplyStateJson ([ordered]@{ down = [ordered]@{ day = '2026-10-15'; full = '3'; other = 2.5 }; standing = 'TRUE'; composeRefusedAt = '2026-10-15T21:00:00+09:00'; hotUntil = 'garbage' })) 'none')
    New-NvReplyStateCase 'down without a day' (New-NvReplyStateInput (New-NvReplyStateJson ([ordered]@{ down = [ordered]@{ full = 1 }; standing = 'yes' })) 'none')
    New-NvReplyStateCase 'down counts no number' (New-NvReplyStateInput (New-NvReplyStateJson ([ordered]@{ down = [ordered]@{ day = 'd'; full = 'abc' } })))
    New-NvReplyStateCase 'whole answers sent' (New-NvReplyStateInput (New-NvReplyStateJson ([ordered]@{ downSent = [ordered]@{
                    m1 = [ordered]@{ at = '2026-10-15T01:00:00Z'; attached = $true }
                    m2 = [ordered]@{ at = '2026-10-15T00:00:00Z'; attached = $true }
                    m3 = [ordered]@{ at = '2026-10-15T00:00:00.0000001Z'; attached = '0' }
                    m4 = $null
                    m5 = [ordered]@{ at = '2026-10-15T06:00:00Z' }
                    m6 = [ordered]@{ at = 'garbage'; attached = $true }
                    m7 = [ordered]@{ at = '2026-10-15T07:00:00Z'; attached = 0 }
                } })) 'none')
    New-NvReplyStateCase 'parts that are no object' (New-NvReplyStateInput (New-NvReplyStateJson ([ordered]@{
                alerts = 'x'; seen = 5; refused = $true; picks = @(1, 2); downSent = 'y'; compose = 'z'; down = 'w'; pairCandidates = 'v'
            })) 'none')
} -Expect {
    param($In, $Name)
    $rsDir = Enter-NvData $Name
    $rsPath = $script:ChatqReplyPath
    if (Get-NvHas $In 'config') { [IO.File]::WriteAllText($script:ChatqConfigPath, (ConvertTo-NvJson $In.config -Compress), $script:NvUtf8) }
    $rsBefore = $null
    if (Get-NvHas $In 'recipe') { $rsBefore = $script:NvUtf8.GetBytes((ConvertTo-NvJson (New-NvReplyStateRecipe $In.recipe) -Compress)) }
    elseif ($null -ne $In.file) { $rsBefore = Get-NvReplyStateBytes $In.file }
    if ($null -ne $rsBefore) { [IO.File]::WriteAllBytes($rsPath, $rsBefore) }
    if ((Get-NvHas $In 'noData') -and $In.noData) { Remove-Item -LiteralPath $rsDir -Recurse -Force }
    $rsOut = @{ threw = $null }
    $rsChange = $In.change
    $rsHours = [double]$In.hours
    $rsNow = [string]$In.now
    $rsHeld = (Get-NvHas $In 'lock') -and [string]$In.lock -eq 'held'
    Use-NvTimeZone (Get-NvReplyStateZone ([int]$In.utcOffsetMinutes)) {
        Use-NvCulture 'en-US' {
            if ($rsHeld) {
                # Open-ChatqLock gives up after 3 s of Get-Date, which moves
                # only outside Use-NvClock; no time goes in this answer
                $rsLock = [IO.File]::Open($script:ChatqReplyLockPath, 'OpenOrCreate', 'ReadWrite', 'None')
                try { Invoke-NvReplyState $rsChange $rsHours $rsOut } finally { $rsLock.Dispose() }
            }
            else { Use-NvClock $rsNow { Invoke-NvReplyState $rsChange $rsHours $rsOut } }
        }
    }
    $rsAfter = if (Test-Path -LiteralPath $rsPath) { , [IO.File]::ReadAllBytes($rsPath) } else { $null }
    if ($rsOut.threw) {
        $rsWas = if ($null -eq $rsAfter) { $null }
        elseif ($null -ne $rsBefore -and (ConvertTo-NvHex $rsAfter) -ceq (ConvertTo-NvHex $rsBefore)) { 'unchanged' }
        else { 'changed' }
        return [ordered]@{ threw = $rsOut.threw; file = $rsWas }
    }
    $rsSaved = Read-NvJson ($script:NvUtf8.GetString($rsAfter))
    if (Get-NvHas $In 'recipe') {
        $rsAns = [ordered]@{ threw = $null }
        $rsAns['alerts'] = Get-NvReplyStateKeys $rsSaved.alerts $false
        $rsAns['picks'] = Get-NvReplyStateKeys $rsSaved.picks $false
        $rsAns['seen'] = Get-NvReplyStateKeys $rsSaved.seen $true
        return $rsAns
    }
    return [ordered]@{ threw = $null; file = (ConvertTo-NvReplyStateFile $rsSaved) }
}
