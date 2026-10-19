# tests/vectors/state.ps1: native/vectors/state.json - data/state.json, the
# run state a watcher hands over: Save-ChatqWatchState and
# Restore-ChatqWatchState (src/watcher.ps1). Rust:
# native/crates/chatq-core/tests/state_vectors.rs.
#
# A save case is a run state $W, its lanes as lists in order. The answer is
# the file Save-ChatqWatchState writes - its fields in their order, which is
# the contract, pid as 'PID', and blocked, outage and authAlerted sorted,
# since PowerShell's hashtables keep no order - and what
# Restore-ChatqWatchState makes of that file at the same moment.
#
# A restore case is the text of a file: what state.rs writes for a state
# (the input carries the state, and the Rust runner checks it writes exactly
# that text), or a text by hand. The answer is what Restore-ChatqWatchState
# makes of it. A restored $W is shown one way in both: its lanes sorted, and
# each time as UTC 'o'. Times with no zone appear only in the full
# yyyy-MM-ddTHH:mm:ss form, which each edition reads its own way.

function ConvertFrom-NvStateStamp([string]$S) {
    # a stamp as the watcher holds one: local time
    return [datetime]::Parse($S, $script:NvInv, [System.Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()
}

function New-NvStateRun($S) {
    # $W as a watcher holds the state a case describes
    $w = New-ChatqWatchState
    $w.startedAt = $S.startedAt
    $w.current = $S.current
    $w.next = $S.next
    $w.handoff = $S.handoff
    $w.listening = $S.listening
    foreach ($b in @($S.blocked)) {
        $e = [pscustomobject]@{ Until = (ConvertFrom-NvStateStamp $b.until); Type = $b.type; Source = $b.source }
        if (Get-NvHas $b 'at') { $e | Add-Member -NotePropertyName At -NotePropertyValue (ConvertFrom-NvStateStamp $b.at) }
        $w.blocked[[string]$b.lane] = $e
    }
    foreach ($o in @($S.outage)) {
        $w.outage[[string]$o.lane] = @{
            Since = (ConvertFrom-NvStateStamp $o.since); NextCheck = (ConvertFrom-NvStateStamp $o.next)
            LastProbe = (ConvertFrom-NvStateStamp $o.lastProbe); Status = $o.status; Attempts = [int]$o.attempts
            Alerted = [bool]$o.alerted; Reminded = [bool]$o.reminded; AutoJob = $o.autoJob
        }
    }
    foreach ($a in @($S.authAlerted)) { $w.authAlerted[[string]$a.lane] = [bool]$a.on }
    return $w
}

function ConvertTo-NvStateSorted($V) {
    # a JSON object as a hashtable, every level down: ConvertTo-NvJson
    # writes a hashtable's keys sorted
    if ($null -ne $V -and $V.GetType().FullName -eq 'System.Management.Automation.PSCustomObject') {
        $h = @{}
        foreach ($p in $V.PSObject.Properties) { $h[$p.Name] = ConvertTo-NvStateSorted $p.Value }
        return $h
    }
    if ($V -is [System.Array]) { return , @(foreach ($x in $V) { ConvertTo-NvStateSorted $x }) }
    return $V
}

function ConvertTo-NvStateFile($F) {
    # the file Save-ChatqWatchState wrote, read back: its fields in their
    # order, pid (this process's) as 'PID', the rest sorted
    $out = [ordered]@{}
    foreach ($p in $F.PSObject.Properties) {
        $v = $p.Value
        if ($p.Name -ceq 'pid') {
            if ([string]$v -ne [string]$PID) { throw "state.json's pid is $v, not $PID" }
            $v = 'PID'
        }
        elseif ($p.Name -ceq 'blocked' -or $p.Name -ceq 'outage') { $v = ConvertTo-NvStateSorted $v }
        elseif ($p.Name -ceq 'authAlerted' -and $v -is [System.Array]) {
            # sorted, and a list still when it holds one lane
            $a = [string[]]$v
            [Array]::Sort($a, [StringComparer]::Ordinal)
            $v = $a
        }
        $out[$p.Name] = $v
    }
    return $out
}

function Get-NvStateView($Ok, $W) {
    # what a restore left in $W: the lanes sorted, times as UTC 'o'
    $blocked = @{}
    foreach ($k in @($W.blocked.Keys)) {
        $b = $W.blocked[$k]
        $e = [ordered]@{ until = $b.Until.ToUniversalTime().ToString('o'); type = $b.Type; source = $b.Source }
        $at = $b.PSObject.Properties['At']
        if ($at -and $null -ne $at.Value) { $e['at'] = $at.Value.ToUniversalTime().ToString('o') }
        $blocked[$k] = $e
    }
    $outage = @{}
    foreach ($k in @($W.outage.Keys)) {
        $o = $W.outage[$k]
        $outage[$k] = [ordered]@{
            since = $o.Since.ToUniversalTime().ToString('o'); next = $o.NextCheck.ToUniversalTime().ToString('o')
            lastProbe = $o.LastProbe.ToUniversalTime().ToString('o'); status = $o.Status; attempts = $o.Attempts
            alerted = $o.Alerted; reminded = $o.Reminded; autoJob = $o.AutoJob
        }
    }
    $auth = [string[]]@(foreach ($k in @($W.authAlerted.Keys)) { if ($W.authAlerted[$k]) { $k } })
    [Array]::Sort($auth, [StringComparer]::Ordinal)
    return [ordered]@{ restored = [bool]$Ok; blocked = $blocked; outage = $outage; authAlerted = $auth }
}

# --- the text state.rs writes: serde_json's to_string_pretty -----------------
function Format-NvStateString([string]$S) {
    $b = New-Object System.Text.StringBuilder ($S.Length + 2)
    [void]$b.Append('"')
    foreach ($ch in $S.ToCharArray()) {
        $c = [int]$ch
        if ($c -eq 0x22) { [void]$b.Append('\"') }
        elseif ($c -eq 0x5C) { [void]$b.Append('\\') }
        elseif ($c -eq 0x08) { [void]$b.Append('\b') }
        elseif ($c -eq 0x0C) { [void]$b.Append('\f') }
        elseif ($c -eq 0x0A) { [void]$b.Append('\n') }
        elseif ($c -eq 0x0D) { [void]$b.Append('\r') }
        elseif ($c -eq 0x09) { [void]$b.Append('\t') }
        elseif ($c -lt 0x20) { [void]$b.Append('\u').Append($c.ToString('x4')) }
        else { [void]$b.Append($ch) }
    }
    [void]$b.Append('"')
    return $b.ToString()
}

function Format-NvStatePretty($V, [string]$Pad) {
    if ($null -eq $V) { return 'null' }
    if ($V -is [bool]) { if ($V) { return 'true' } else { return 'false' } }
    if ($V -is [string]) { return (Format-NvStateString $V) }
    if ($V -is [int] -or $V -is [long]) { return $V.ToString($script:NvInv) }
    $inner = $Pad + '  '
    if ($V -is [System.Collections.IDictionary]) {
        if ($V.Count -eq 0) { return '{}' }
        $parts = foreach ($k in @($V.Keys)) { $inner + (Format-NvStateString $k) + ': ' + (Format-NvStatePretty $V[$k] $inner) }
        return "{`n" + (@($parts) -join ",`n") + "`n" + $Pad + '}'
    }
    $items = @($V)
    if ($items.Count -eq 0) { return '[]' }
    $parts = foreach ($x in $items) { $inner + (Format-NvStatePretty $x $inner) }
    return "[`n" + (@($parts) -join ",`n") + "`n" + $Pad + ']'
}

function Format-NvStateFile($S, [string]$Version, [string]$Heartbeat) {
    # WatchState::to_json(4242, $Version, $Heartbeat) for the state $S
    # describes, as chatqd writes it
    $blocked = [ordered]@{}
    foreach ($b in @($S.blocked)) {
        $e = [ordered]@{ until = $b.until; type = $b.type; source = $b.source }
        if ($b.Contains('at')) { $e['at'] = $b.at }
        $blocked[$b.lane] = $e
    }
    $outage = [ordered]@{}
    foreach ($o in @($S.outage)) {
        $outage[$o.lane] = [ordered]@{
            since = $o.since; next = $o.next; lastProbe = $o.lastProbe; status = $o.status; attempts = $o.attempts
            alerted = $o.alerted; reminded = $o.reminded; autoJob = $o.autoJob
        }
    }
    $auth = @(foreach ($a in @($S.authAlerted)) { if ($a.on) { $a.lane } })
    $f = [ordered]@{
        pid = 4242; version = $Version; startedAt = $S.startedAt; heartbeat = $Heartbeat; current = $S.current; next = $S.next
        blocked = $blocked; outage = $outage; authAlerted = $auth; handoff = $S.handoff; listening = $S.listening
    }
    return (Format-NvStatePretty $f '')
}

# --- cases ---------------------------------------------------------------------
function New-NvStateBlocked([string]$Lane, [string]$Until, $Type, $Source, [string]$At) {
    $b = [ordered]@{ lane = $Lane; until = $Until; type = $Type; source = $Source }
    if ($At) { $b['at'] = $At }
    return $b
}

function New-NvStateOutage([string]$Lane, [string]$Since, [string]$Next, [string]$LastProbe, $Status, [int]$Attempts,
    [bool]$Alerted, [bool]$Reminded, $AutoJob) {
    return [ordered]@{
        lane = $Lane; since = $Since; next = $Next; lastProbe = $LastProbe; status = $Status; attempts = $Attempts
        alerted = $Alerted; reminded = $Reminded; autoJob = $AutoJob
    }
}

function New-NvStateAuth([string]$Lane, [bool]$On) { return [ordered]@{ lane = $Lane; on = $On } }

function New-NvState {
    param($Blocked = @(), $Outage = @(), $Auth = @(), [bool]$Handoff = $true, [bool]$Listening = $false,
        $Current = $null, $Next = $null, [string]$StartedAt = '2026-10-15T00:00:00.0000000Z')
    return [ordered]@{
        startedAt = $StartedAt; current = $Current; next = $Next; handoff = $Handoff; listening = $Listening
        blocked = @($Blocked); outage = @($Outage); authAlerted = @($Auth)
    }
}

function New-NvStateSave([string]$Name, $State, [string]$Zone = 'Korea Standard Time', [int]$Offset = 540,
    [string]$Now = '2026-10-15T01:00:00Z') {
    $in = [ordered]@{ kind = 'save'; zone = $Zone; utcOffsetMinutes = $Offset; now = $Now; version = '9.8.7'; state = $State }
    return [ordered]@{ name = $Name; input = $in }
}

function New-NvStateRestore([string]$Name, $Text, [string]$Zone = 'Korea Standard Time', [int]$Offset = 540,
    [string]$Now = '2026-10-15T01:00:00Z') {
    # $Text: a file's text, or $null for no file
    $in = [ordered]@{ kind = 'restore'; zone = $Zone; utcOffsetMinutes = $Offset; now = $Now; text = $Text }
    return [ordered]@{ name = $Name; input = $in }
}

function New-NvStateRestoreOf([string]$Name, $State, [string]$Zone = 'Korea Standard Time', [int]$Offset = 540) {
    # the file state.rs writes for $State, a minute before the restore
    $hb = '2026-10-15T00:59:00.0000000Z'
    $in = [ordered]@{
        kind = 'restore'; zone = $Zone; utcOffsetMinutes = $Offset; now = '2026-10-15T01:00:00Z'; version = '9.8.7'
        heartbeat = $hb; state = $State; text = (Format-NvStateFile $State '9.8.7' $hb)
    }
    return [ordered]@{ name = $Name; input = $in }
}

function New-NvStateText([string]$Name, $File, [string]$Zone = 'Korea Standard Time', [int]$Offset = 540,
    [string]$Now = '2026-10-15T01:00:00Z') {
    # a file by hand, from a dictionary
    return (New-NvStateRestore $Name (ConvertTo-NvJson $File -Compress) $Zone $Offset $Now)
}

function New-NvStateUntil($Until) {
    return [ordered]@{ until = $Until; type = 'session'; source = 'probe' }
}

Register-NvVector -Name 'state' -About 'data/state.json across a handoff: Save-ChatqWatchState (src/watcher.ps1) writes pid, version, startedAt, heartbeat, current, next, blocked, outage, authAlerted, handoff, listening in that order, and Restore-ChatqWatchState reads it back only after a handoff: a limit already over, or an outage with no since, is dropped. Save cases: the file (pid as PID; blocked, outage and authAlerted sorted) and its restore; restore cases: the text state.rs writes, or one by hand, and what the restore makes of it. Rust: state::WatchState::to_json, restore_in' -Cases {
    $blocked = @(
        (New-NvStateBlocked 'claude' '2026-10-15T03:00:00.0000000Z' 'session' 'probe' '2026-10-15T00:30:00.0000000Z'),
        (New-NvStateBlocked 'codex|acct\.codex-b' '2026-10-15T05:30:00.1234567Z' 'weekly' 'transcript'))
    $outage = @(
        (New-NvStateOutage 'claude' '2026-10-15T00:40:00.0000000Z' '2026-10-15T01:10:00.0000000Z' '2026-10-15T00:55:00.0000000Z' 'major_outage' 3 $true $false $null),
        (New-NvStateOutage 'codex' '2026-10-15T00:50:00.0000000Z' '2026-10-15T01:05:00.0000000Z' '2026-10-15T00:50:00.0000000Z' $null 1 $false $true 'j7'))
    $auth = @((New-NvStateAuth 'claude' $true), (New-NvStateAuth 'codex' $false), (New-NvStateAuth 'codex|acct\.codex-b' $true))
    $full = New-NvState -Blocked $blocked -Outage $outage -Auth $auth -Current 'j1' -Next '2026-10-15T01:20:00.0000000Z'

    # text that has to be escaped, or not, in both writers
    $q = [string][char]0x22
    $lane1 = 'claude|home\' + [char]0x00E9 + 'l' + [char]0x00E8 + 've\.claude'
    $lane2 = 'codex|' + $q + 'quoted' + $q + ' ' + [char]0x4E2D + [char]0x6587
    $lane3 = "tab`tlane"
    $odd1 = 'x' + [char]0x0001 + [char]0x0008 + [char]0x000C + [char]0x001F + [char]0x007F + "`t`r`n" + 'y'
    $odd2 = 'emoji ' + [char]::ConvertFromUtf32(0x1F600) + ' ' + [char]0x2028 + [char]0x00A0 + '/<>&' + "'"
    $esc = New-NvState -Blocked @(
        (New-NvStateBlocked $lane1 '2026-10-15T03:00:00.0000000Z' $odd1 $odd2),
        (New-NvStateBlocked $lane3 '2026-10-15T04:00:00.0000000Z' $q '\')) -Outage @(
        (New-NvStateOutage $lane2 '2026-10-15T00:40:00.0000000Z' '2026-10-15T01:10:00.0000000Z' '2026-10-15T00:55:00.0000000Z' $odd2 2 $true $true $odd1)) -Auth @(
        (New-NvStateAuth $lane2 $true), (New-NvStateAuth $lane1 $true)) -Current $odd2 -Next $odd1 -StartedAt $odd1

    New-NvStateSave 'save-full' $full
    New-NvStateSave 'save-empty' (New-NvState -Handoff $false)
    New-NvStateSave 'save-handoff-empty' (New-NvState)
    New-NvStateSave 'save-listening' (New-NvState -Listening $true -Auth @((New-NvStateAuth 'claude' $false)))
    New-NvStateSave 'save-one-alerted' (New-NvState -Auth @((New-NvStateAuth 'codex' $true), (New-NvStateAuth 'claude' $false)))
    # until against now (01:00Z): gone, now itself (gone too), a tick after
    New-NvStateSave 'save-past-until' (New-NvState -Blocked @(
            (New-NvStateBlocked 'a' '2026-10-15T00:59:59.9999999Z' 'session' 'probe'),
            (New-NvStateBlocked 'b' '2026-10-15T01:00:00.0000000Z' 'session' 'probe'),
            (New-NvStateBlocked 'c' '2026-10-15T01:00:00.0000001Z' 'session' 'probe')))
    # offset 0 by a zone that is not 'UTC': for that id .NET hands back
    # TimeZoneInfo.Utc itself, which as the local zone makes pwsh 7's
    # ToUniversalTime keep Kind Local (so 'o' writes +00:00), as no real
    # machine's local zone does
    New-NvStateSave 'save-zero-offset' $full -Zone 'Greenwich Standard Time' -Offset 0
    New-NvStateSave 'save-negative-zone' $full -Zone 'SA Pacific Standard Time' -Offset -300
    New-NvStateSave 'save-escapes' $esc

    New-NvStateRestoreOf 'rust-full' $full
    New-NvStateRestoreOf 'rust-handoff-false' (New-NvState -Handoff $false -Blocked $blocked)
    New-NvStateRestoreOf 'rust-empty' (New-NvState)
    New-NvStateRestoreOf 'rust-escapes' $esc
    New-NvStateRestoreOf 'rust-negative-zone' $full -Zone 'SA Pacific Standard Time' -Offset -300

    # handoff as if ($s.handoff) sees it
    New-NvStateText 'handoff-text-false' ([ordered]@{ handoff = 'false'; authAlerted = @('claude') })
    New-NvStateText 'handoff-zero' ([ordered]@{ handoff = 0; authAlerted = @('claude') })
    New-NvStateText 'handoff-empty-list' ([ordered]@{ handoff = @(); authAlerted = @('claude') })
    New-NvStateText 'handoff-list-one' ([ordered]@{ handoff = @(1); authAlerted = @('claude') })
    New-NvStateText 'handoff-list-zero' ([ordered]@{ handoff = @(0); authAlerted = @('claude') })
    New-NvStateText 'handoff-object' ([ordered]@{ handoff = [ordered]@{}; authAlerted = @('claude') })
    New-NvStateText 'handoff-missing' ([ordered]@{ authAlerted = @('claude') })
    New-NvStateText 'not-objects' ([ordered]@{ handoff = $true; blocked = 'x'; outage = 5 })

    # until, against now (01:00Z)
    New-NvStateText 'until-shapes' ([ordered]@{ handoff = $true; blocked = [ordered]@{
                a = (New-NvStateUntil '2026-10-15T03:00:00Z'); b = (New-NvStateUntil '2026-10-15T12:00:00+09:00')
                c = (New-NvStateUntil ''); d = [ordered]@{ type = 'session'; source = 'probe' }
                e = (New-NvStateUntil 5); f = (New-NvStateUntil $true); g = (New-NvStateUntil '2026-10-15T00:59:59Z')
                h = (New-NvStateUntil '2026-10-15T01:00:00Z'); i = (New-NvStateUntil 'not a date'); j = $null; k = 'x'
                l = (New-NvStateUntil '2026-10-15T01:00:00.0000001Z'); m = (New-NvStateUntil '2026-10-15T03:00:00.5Z')
                n = [ordered]@{ UNTIL = '2026-10-15T03:00:00Z'; type = 'session'; source = 'probe' }
                o = (New-NvStateUntil ([ordered]@{})); p = (New-NvStateUntil '2026-10-15T03:00:00.1234567-02:30')
            }
        })
    $at = [ordered]@{}
    $ats = [ordered]@{ b = $null; c = ''; d = 'not a date'; e = '2026-10-15T00:30:00Z'; f = '2026-10-15T09:30:00+09:00'; g = 5; i = '2026-10-16T00:00:00Z' }
    $at['a'] = New-NvStateUntil '2026-10-15T03:00:00Z'
    foreach ($k in $ats.Keys) { $e = New-NvStateUntil '2026-10-15T03:00:00Z'; $e['at'] = $ats[$k]; $at[$k] = $e }
    $at['h'] = [ordered]@{ until = '2026-10-15T03:00:00Z'; type = 'session'; source = 'probe'; At = '2026-10-15T00:20:00Z' }
    $at['j'] = [ordered]@{ until = '2026-10-15T00:30:00Z'; type = 'session'; source = 'probe'; at = '2026-10-15T00:20:00Z' }
    New-NvStateText 'at-shapes' ([ordered]@{ handoff = $true; blocked = $at })
    New-NvStateText 'type-shapes' ([ordered]@{ handoff = $true; blocked = [ordered]@{
                a = [ordered]@{ until = '2026-10-15T03:00:00Z' }
                b = [ordered]@{ until = '2026-10-15T03:00:00Z'; type = $null; source = $null }
                c = [ordered]@{ until = '2026-10-15T03:00:00Z'; type = 5; source = $true }
                d = [ordered]@{ until = '2026-10-15T03:00:00Z'; type = @('a', 'b'); source = [ordered]@{ x = 1 } }
                e = [ordered]@{ until = '2026-10-15T03:00:00Z'; type = ''; source = @() }
                f = [ordered]@{ until = '2026-10-15T03:00:00Z'; Type = 'session'; SOURCE = 'probe' }
            }
        })

    # an outage: since or nothing; next now and lastProbe since when unread
    $since = '2026-10-15T00:40:00Z'
    New-NvStateText 'outage-shapes' ([ordered]@{ handoff = $true; outage = [ordered]@{
                a = [ordered]@{ next = '2026-10-15T01:10:00Z' }; b = [ordered]@{ since = '' }; c = [ordered]@{ since = 'not a date' }
                d = [ordered]@{ since = $since }
                e = [ordered]@{
                    since = $since; next = '2026-10-15T10:10:00+09:00'; lastProbe = '2026-10-15T00:55:00Z'; status = 'major_outage'
                    attempts = 2; alerted = $true; reminded = $true; autoJob = 'j1'
                }
                f = [ordered]@{ since = $since; next = 'x'; lastProbe = '' }
                g = [ordered]@{ since = 5 }; h = $null; i = 'x'
                j = [ordered]@{ SINCE = $since; Next = '2026-10-15T01:30:00Z'; LASTPROBE = '2026-10-15T00:45:00Z' }
            }
        })
    $attempts = [ordered]@{ a = '-'; b = $null; c = '3'; d = 2.5; e = 3.5; f = $true; g = '0x10'; h = -2; i = ' 7 '; j = ''; k = $false; l = '2.5'; m = '+5' }
    $outage = [ordered]@{}
    foreach ($k in $attempts.Keys) {
        $o = [ordered]@{ since = $since }
        if ($attempts[$k] -isnot [string] -or $attempts[$k] -cne '-') { $o['attempts'] = $attempts[$k] }
        $outage[$k] = $o
    }
    New-NvStateText 'attempts-shapes' ([ordered]@{ handoff = $true; outage = $outage })
    New-NvStateText 'flag-shapes' ([ordered]@{ handoff = $true; outage = [ordered]@{
                a = [ordered]@{ since = $since; alerted = 'false'; reminded = '0' }
                b = [ordered]@{ since = $since; alerted = 0; reminded = @() }
                c = [ordered]@{ since = $since; alerted = $null; reminded = 1 }
                d = [ordered]@{ since = $since; alerted = [ordered]@{}; reminded = '' }
                e = [ordered]@{ since = $since; alerted = @(0); reminded = @(1) }
            }
        })
    $jobs = [ordered]@{ a = '-'; b = $null; c = 'j1'; d = 5; e = $true; f = $false; g = @('a', 'b'); h = @(); i = ''; j = @('a', $null, 'b'); k = @($null) }
    $outage = [ordered]@{}
    foreach ($k in $jobs.Keys) {
        $o = [ordered]@{ since = $since }
        if ($jobs[$k] -isnot [string] -or $jobs[$k] -cne '-') { $o['autoJob'] = $jobs[$k] }
        $outage[$k] = $o
    }
    New-NvStateText 'autojob-shapes' ([ordered]@{ handoff = $true; outage = $outage })

    # authAlerted as foreach (@($s.authAlerted)) and [string] see it
    New-NvStateText 'auth-string' ([ordered]@{ handoff = $true; authAlerted = 'claude' })
    New-NvStateText 'auth-case-twice' ([ordered]@{ handoff = $true; authAlerted = @('claude', 'Claude') })
    New-NvStateText 'auth-falsy' ([ordered]@{ handoff = $true; authAlerted = @(0, '', $null, $false, 'codex') })
    New-NvStateText 'auth-number' ([ordered]@{ handoff = $true; authAlerted = @(5) })
    New-NvStateText 'auth-nested' ([ordered]@{ handoff = $true; authAlerted = @(, @('a', 'b')) })
    New-NvStateText 'auth-true' ([ordered]@{ handoff = $true; authAlerted = @($true) })

    # files that are no state
    New-NvStateRestore 'top-level-string' '"handoff"'
    New-NvStateRestore 'empty-file' ''
    New-NvStateRestore 'blank-file' "  `r`n"
    New-NvStateRestore 'broken-json' '{"handoff":true,'
    New-NvStateRestore 'no-file' $null
    New-NvStateRestore 'bom-file' ([string][char]0xFEFF + '{"handoff":true,"authAlerted":["claude"]}')

    # a time with no zone: UTC to 5.1, this zone's wall clock to pwsh 7
    New-NvStateText 'zoneless' ([ordered]@{ handoff = $true
            blocked = [ordered]@{ a = [ordered]@{ until = '2026-10-15T10:00:00'; type = 'session'; source = 'probe'; at = '2026-10-15T09:00:00' } }
            outage = [ordered]@{ b = [ordered]@{ since = '2026-10-15T09:00:00'; next = '2026-10-15T09:30:00'; lastProbe = '2026-10-15T09:10:00' } }
        }) -Now '2026-10-15T00:30:00Z'
    New-NvStateText 'offsets-negative-zone' ([ordered]@{ handoff = $true
            blocked = [ordered]@{ a = (New-NvStateUntil '2026-10-14T22:00:00-05:00') }
            outage = [ordered]@{ b = [ordered]@{ since = '2026-10-15T09:40:00+09:00' } }
        }) -Zone 'SA Pacific Standard Time' -Offset -300
} -Expect {
    param($In, $Name)
    $null = Enter-NvData $Name
    $wasVersion = $script:ChatVersion
    try {
        if ([string]$In.kind -eq 'save') {
            $script:ChatVersion = [string]$In.version
            return (Use-NvCulture 'en-US' {
                    Use-NvTimeZone ([string]$In.zone) {
                        Use-NvClock ([string]$In.now) {
                            $null = Save-ChatqWatchState (New-NvStateRun $In.state)
                            $file = Read-NvJson ([IO.File]::ReadAllText($script:ChatqStatePath, $script:NvUtf8))
                            $back = New-ChatqWatchState
                            $ok = Restore-ChatqWatchState $back
                            [ordered]@{ file = (ConvertTo-NvStateFile $file); restored = (Get-NvStateView $ok $back) }
                        }
                    }
                })
        }
        if ($null -ne $In.text) { [IO.File]::WriteAllText($script:ChatqStatePath, [string]$In.text, $script:NvUtf8) }
        return (Use-NvCulture 'en-US' {
                Use-NvTimeZone ([string]$In.zone) {
                    Use-NvClock ([string]$In.now) {
                        $back = New-ChatqWatchState
                        $ok = Restore-ChatqWatchState $back
                        Get-NvStateView $ok $back
                    }
                }
            })
    }
    finally { $script:ChatVersion = $wasVersion }
}
