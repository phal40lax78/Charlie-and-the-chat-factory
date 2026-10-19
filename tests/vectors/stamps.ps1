# tests/vectors/stamps.ps1: native/vectors/stamps.json, the stamps the tool
# writes and reads (native/SPEC.md 2.2, 6.1). Two kinds of case:
#
# - stamp: at the instant input.at, Get-ChatqStamp's UTC stamp and the local
#   one Add-ChatqLogLine starts a line with, as {utc, local}.
# - date: input.text as the bytes of a JSON file, read as the tool reads
#   every file (Read-ChatqJson), its "at" given to ConvertTo-ChatqDate: the
#   instant that names, as UTC 'o', or null. pwsh 7's ConvertFrom-Json makes
#   DateTimes of some strings and 5.1's of others, and .NET and .NET
#   Framework parse what is left differently, so many answers are per
#   edition. by = Core and by = Desktop cases are files that PowerShell's own
#   ConvertTo-Json wrote.
#
# Each case runs in a real Windows zone (Use-NvTimeZone), and its input says
# what that zone's offset is where an answer depends on it - utcOffsetMinutes,
# or near a DST change the change and the offsets before and after it -
# which the Expect block checks, so that Rust, with no zone database, gets
# the same zone. The dst cases read pwsh 7's zoneless stamps at wall times a
# change skips or repeats, which .NET reads at the standard offset.

function ConvertTo-NvStampsUtc([string]$At) {
    # a stamp with Z or an offset, as a [datetime] of Kind Utc
    return [datetime]::Parse($At, $script:NvInv, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}

function Get-NvStampsText($Value) {
    # a JSON file holding {"at": $Value}
    return '{"at":' + (ConvertTo-NvJson $Value -Compress) + '}'
}

function New-NvStampsDate([string]$Label, [string]$Text, [string]$Zone = 'Korea Standard Time', [int]$Minutes = 540) {
    return [ordered]@{ name = $Label; input = [ordered]@{ kind = 'date'; text = $Text; zone = $Zone; utcOffsetMinutes = $Minutes } }
}

function New-NvStampsStamp([string]$Label, [string]$At, [string]$Zone, [int]$Minutes) {
    return [ordered]@{ name = $Label; input = [ordered]@{ kind = 'stamp'; at = $At; zone = $Zone; utcOffsetMinutes = $Minutes } }
}

function Test-NvStampsChange($In) {
    # the zone goes from $In.before to $In.after minutes east of UTC at
    # $In.change, and does not change again within two days either side
    $tz = [System.TimeZoneInfo]::Local
    $c = ConvertTo-NvStampsUtc ([string]$In.change)
    $got = @(foreach ($t in @($c.AddDays(-2), $c.AddTicks(-1), $c, $c.AddDays(2))) { [int]$tz.GetUtcOffset($t).TotalMinutes })
    $want = @([int]$In.before, [int]$In.before, [int]$In.after, [int]$In.after)
    if (($got -join ',') -ne ($want -join ',')) { throw "$($tz.Id) is $($got -join ', ') minutes from UTC two days, a tick before, at and two days after $($In.change), not $($want -join ', ')" }
}

function Test-NvStampsWall($In, [datetime]$Wall) {
    # pwsh 7 read a zoneless stamp, a wall-clock time in the zone: its
    # offset there is the input's, or the time is near the input's change
    $tz = [System.TimeZoneInfo]::Local
    if (Get-NvHas $In 'change') {
        if ([Math]::Abs(($Wall - (ConvertTo-NvStampsUtc ([string]$In.change))).TotalHours) -gt 24) { throw "$($Wall.ToString('o')) is not within a day of the change at $($In.change)" }
        return
    }
    if ($tz.IsAmbiguousTime($Wall) -or $tz.IsInvalidTime($Wall)) { throw "$($tz.Id) repeats or skips $($Wall.ToString('o')): give the change, not utcOffsetMinutes" }
    $o = [int]$tz.GetUtcOffset($Wall).TotalMinutes
    if ($o -ne [int]$In.utcOffsetMinutes) { throw "$($tz.Id) is $o minutes from UTC at $($Wall.ToString('o')), not $($In.utcOffsetMinutes)" }
}

function Get-NvStampsStamp($In, [string]$Name) {
    $at = [string]$In.at
    return (Use-NvTimeZone ([string]$In.zone) {
            if (Get-NvHas $In 'change') { Test-NvStampsChange $In }
            else {
                $o = [int][System.TimeZoneInfo]::Local.GetUtcOffset((ConvertTo-NvStampsUtc $at)).TotalMinutes
                if ($o -ne [int]$In.utcOffsetMinutes) { throw "$([System.TimeZoneInfo]::Local.Id) is $o minutes from UTC at $at, not $($In.utcOffsetMinutes)" }
            }
            Use-NvClock $at {
                $null = Enter-NvData $Name
                $utc = Get-ChatqStamp
                Add-ChatqLogLine 'stamps.log' 'x'
                $line = [IO.File]::ReadAllText((Join-Path $script:ChatqLogDir 'stamps.log'), $script:NvUtf8)
                [ordered]@{ utc = $utc; local = $line.Substring(0, $line.IndexOf('  ')) }
            }
        })
}

function Get-NvStampsDate($In, [string]$Name) {
    # en-US: 5.1's ConvertFrom-Json reads the number in "\/Date(-1000)\/"
    # with the culture's minus sign
    $text = [string]$In.text
    return (Use-NvCulture 'en-US' {
            Use-NvTimeZone ([string]$In.zone) {
                if (Get-NvHas $In 'change') { Test-NvStampsChange $In }
                $file = Join-Path (Enter-NvData $Name) 'stamp.json'
                [IO.File]::WriteAllText($file, $text, $script:NvUtf8)
                $j = Read-ChatqJson $file
                $v = $null
                if ($null -ne $j -and $null -ne $j.PSObject.Properties['at']) { $v = $j.at }
                if ($v -is [datetime] -and $v.Kind -eq [System.DateTimeKind]::Unspecified) { Test-NvStampsWall $In $v }
                $d = ConvertTo-ChatqDate $v
                if ($null -eq $d) { $null } else { $d.ToUniversalTime().ToString('o') }
            }
        })
}

Register-NvVector -Name 'stamps' -About "Get-ChatqStamp and Add-ChatqLogLine's local stamp at an instant in a zone ({utc, local}); ConvertTo-ChatqDate of the at of a JSON file Read-ChatqJson read, as the UTC 'o' of the instant it names, or null" -Cases {
    $kst = 'Korea Standard Time'
    # --- what the tool writes -------------------------------------------------
    New-NvStampsStamp 'stamp seven digits' '2026-10-15T01:02:03.1234567Z' $kst 540
    New-NvStampsStamp 'stamp whole second' '2026-10-15T01:02:03.0000000Z' $kst 540
    New-NvStampsStamp 'stamp leading zeros' '2026-01-05T01:02:03.0000400Z' $kst 540
    New-NvStampsStamp 'stamp one tick' '2026-10-15T01:02:03.0000001Z' $kst 540
    New-NvStampsStamp 'stamp new year in the zone' '2026-12-31T23:59:59.9999999Z' $kst 540
    New-NvStampsStamp 'stamp epoch' '1970-01-01T00:00:00.0000000Z' $kst 540
    New-NvStampsStamp 'stamp India' '2026-10-15T01:02:03.1234567Z' 'India Standard Time' 330
    New-NvStampsStamp 'stamp Nepal' '2026-10-15T01:02:03.1234567Z' 'Nepal Standard Time' 345
    New-NvStampsStamp 'stamp Pacific winter' '2026-01-15T01:02:03.1234567Z' 'Pacific Standard Time' (-480)
    New-NvStampsStamp 'stamp Pacific summer' '2026-07-15T01:02:03.1234567Z' 'Pacific Standard Time' (-420)
    New-NvStampsStamp 'stamp Newfoundland winter' '2026-01-15T01:02:03.1234567Z' 'Newfoundland Standard Time' (-210)
    New-NvStampsStamp 'stamp Newfoundland summer' '2026-07-15T01:02:03.1234567Z' 'Newfoundland Standard Time' (-150)
    New-NvStampsStamp 'stamp Chatham summer' '2026-01-15T01:02:03.1234567Z' 'Chatham Islands Standard Time' 825
    New-NvStampsStamp 'stamp Chatham winter' '2026-07-15T01:02:03.1234567Z' 'Chatham Islands Standard Time' 765
    New-NvStampsStamp 'stamp Marquesas' '2026-10-15T01:02:03.1234567Z' 'Marquesas Standard Time' (-570)
    New-NvStampsStamp 'stamp Line Islands' '2026-10-15T01:02:03.1234567Z' 'Line Islands Standard Time' 840
    New-NvStampsStamp 'stamp Dateline' '2026-10-15T01:02:03.1234567Z' 'Dateline Standard Time' (-720)
    # Not the zone 'UTC': for that id pwsh 7 hands back TimeZoneInfo.Utc
    # itself, and with that very object as the local zone ToUniversalTime
    # keeps a Local DateTime as it is ('o' then ends +00:00, not Z), which a
    # PC set to UTC, whose local zone is an object of its own, never does
    New-NvStampsStamp 'stamp Greenwich' '2026-10-15T01:02:03.1234567Z' 'Greenwich Standard Time' 0
    New-NvStampsStamp 'stamp GMT winter' '2026-01-15T01:02:03.1234567Z' 'GMT Standard Time' 0
    New-NvStampsStamp 'stamp GMT summer' '2026-07-15T01:02:03.1234567Z' 'GMT Standard Time' 60
    # either side of a DST change, the offset of the instant
    foreach ($s in @(
            @('Pacific', 'Pacific Standard Time', '2026-03-08T10:00:00Z', -480, -420),
            @('Pacific', 'Pacific Standard Time', '2026-11-01T09:00:00Z', -420, -480),
            @('W. Europe', 'W. Europe Standard Time', '2026-03-29T01:00:00Z', 60, 120),
            @('W. Europe', 'W. Europe Standard Time', '2026-10-25T01:00:00Z', 120, 60),
            @('Lord Howe', 'Lord Howe Standard Time', '2026-04-04T15:00:00Z', 660, 630),
            @('Lord Howe', 'Lord Howe Standard Time', '2026-10-03T15:30:00Z', 630, 660))) {
        $c = ConvertTo-NvStampsUtc $s[2]
        foreach ($p in @(@('last tick before', $c.AddTicks(-1)), @('first tick of', $c))) {
            [ordered]@{
                name  = "stamp $($s[0]) $($p[0]) the change at $($s[2])"
                input = [ordered]@{ kind = 'stamp'; at = $p[1].ToString('o', $script:NvInv); zone = $s[1]; change = $s[2]; before = $s[3]; after = $s[4] }
            }
        }
    }

    # --- what ConvertTo-ChatqDate reads: strings ------------------------------
    foreach ($p in @(
            # round-trip 'o' and its shorter forms
            @('o seven digits Z', '2026-10-15T01:02:03.1234567Z'),
            @('o seven digits +09:00', '2026-10-15T10:02:03.1234567+09:00'),
            @('o seven digits -07:00', '2026-10-14T18:02:03.1234567-07:00'),
            @('o +05:30', '2026-10-15T06:32:03.1234567+05:30'),
            @('o +05:45', '2026-10-15T06:47:03.1234567+05:45'),
            @('o -09:30', '2026-10-14T15:32:03.1234567-09:30'),
            @('o +00:00', '2026-10-15T01:02:03.1234567+00:00'),
            @('o -00:00', '2026-10-15T01:02:03.1234567-00:00'),
            @('three digits Z', '2026-10-15T01:02:03.123Z'),
            @('one digit Z', '2026-10-15T01:02:03.5Z'),
            @('no fraction Z', '2026-10-15T01:02:03Z'),
            @('no fraction +09:00', '2026-10-15T10:02:03+09:00'),
            @('zero fraction Z', '2026-10-15T01:02:03.0000000Z'),
            @('lowercase z', '2026-10-15T01:02:03z'),
            @('leap day', '2024-02-29T01:02:03Z'),
            @('epoch Z', '1970-01-01T00:00:00.0000000Z'),
            # offsets
            @('offset +0900', '2026-10-15T10:02:03+0900'),
            @('offset +09', '2026-10-15T10:02:03+09'),
            @('offset +9', '2026-10-15T10:02:03+9'),
            @('offset +130', '2026-10-15T01:02:03+130'),
            @('offset +01:3', '2026-10-15T01:02:03+01:3'),
            @('offset +01:', '2026-10-15T01:02:03+01:'),
            @('offset +14:00', '2026-10-15T01:02:03+14:00'),
            @('offset -14:00', '2026-10-15T01:02:03-14:00'),
            @('offset +14:01', '2026-10-15T01:02:03+14:01'),
            @('offset +15:00', '2026-10-15T01:02:03+15:00'),
            @('offset +99:59', '2026-10-15T01:02:03+99:59'),
            @('offset +99:99', '2026-10-15T01:02:03+99:99'),
            @('offset +09:60', '2026-10-15T01:02:03+09:60'),
            @('offset +12345', '2026-10-15T01:02:03+12345'),
            @('offset +09:00:00', '2026-10-15T01:02:03+09:00:00'),
            @('offset -9', '2026-10-15T01:02:03.1234567-9'),
            @('offset -09:3', '2026-10-15T01:02:03-09:3'),
            @('offset -0:30', '2026-10-15T01:02:03-0:30'),
            @('offset +:30', '2026-10-15T01:02:03+:30'),
            @('a sign alone', '2026-10-15T01:02:03.1234567-'),
            @('offset then a letter', '2026-10-15T01:02:03+09:00X'),
            @('offset then Z', '2026-10-15T01:02:03+09:00Z'),
            @('offset +0900 then Z', '2026-10-15T01:02:03+0900Z'),
            @('offset +09 then Z', '2026-10-15T01:02:03+09Z'),
            @('offset +1 then a letter', '2026-10-15T01:02:03+1X'),
            @('offset then two letters', '2026-10-15T01:02:03+09:00XY'),
            @('offset then a space and a letter', '2026-10-15T01:02:03+09:00 X'),
            @('offset then a space', '2026-10-15T01:02:03+09:00 '),
            @('offset then NUL', ('2026-10-15T01:02:03+09:00' + [char]0)),
            @('offset then a letter and NUL', ('2026-10-15T01:02:03+09:00X' + [char]0)),
            @('offset then a space and NUL', ('2026-10-15T01:02:03+09:00 ' + [char]0)),
            @('space then offset', '2026-10-15T01:02:03 +09:00'),
            @('space then -09', '2026-10-15T01:02:03 -09'),
            @('fraction space Z', '2026-10-15T01:02:03.1234567 Z'),
            @('sign then a space', '2026-10-15T01:02:03+ 09:00'),
            @('two zones', '2026-10-15T01:02:03ZZ'),
            @('Z then a digit', '2026-10-15T01:02:03Z1'),
            @('space then Z', '2026-10-15T01:02:03 Z'),
            # time of day
            @('hour 24 Z', '2026-10-15T24:00:00Z'),
            @('hour 24 zoneless', '2026-10-15T24:00:00'),
            @('hour 24 and a tick', '2026-10-15T24:00:00.0000001Z'),
            @('hour 25', '2026-10-15T25:00:00Z'),
            @('minute 60', '2026-10-15T01:60:03Z'),
            @('second 60', '2026-10-15T23:59:60Z'),
            @('no seconds', '2026-10-15T01:02'),
            @('no seconds Z', '2026-10-15T01:02Z'),
            @('no seconds +09:00', '2026-10-15T01:02+09:00'),
            @('no seconds +15:00', '2026-10-15T01:02+15:00'),
            @('no seconds space Z', '2026-10-15T01:02 Z'),
            @('no seconds space +09:00', '2026-10-15T01:02 +09:00'),
            @('hour only', '2026-10-15T01Z'),
            @('one-digit hour', '2026-10-15T1:02:03Z'),
            @('three parts after seconds', '2026-10-15T01:02:03:04Z'),
            @('spaces around colons', '2026-10-15T01 : 02 : 03Z'),
            @('two digits after seconds', '2026-10-15T01:02:0312'),
            # fractions
            @('eight digits Z', '2026-10-15T01:02:03.12345678Z'),
            @('nine digits Z', '2026-10-15T01:02:03.123456789Z'),
            @('nine digits zoneless', '2026-10-15T01:02:03.123456789'),
            @('ten digits zoneless', '2026-10-15T01:02:03.1234567812'),
            @('rounds up to the second', '2026-10-15T01:02:03.99999995Z'),
            @('rounds up to the day', '2026-10-15T23:59:59.99999999Z'),
            @('rounds half a tick up', '2026-10-15T01:02:03.00000005Z'),
            @('rounds 2.5 ticks up', '2026-10-15T01:02:03.00000025Z'),
            @('rounds 4.5 ticks up', '2026-10-15T01:02:03.00000045Z'),
            @('rounds 6.65 ticks', '2026-10-15T01:02:03.12345665Z'),
            @('rounds down', '2026-10-15T01:02:03.999999949Z'),
            @('rounds a long tail down', '2026-10-15T01:02:03.000000049999Z'),
            @('fifty zero digits', ('2026-10-15T01:02:03.' + ('0' * 50) + 'Z')),
            @('twenty-five nines', ('2026-10-15T01:02:03.' + ('9' * 25) + 'Z')),
            @('comma fraction', '2026-10-15T01:02:03,5Z'),
            @('dot and no digits', '2026-10-15T01:02:03.'),
            @('dot then Z', '2026-10-15T01:02:03.Z'),
            @('space before a fraction', '2026-10-15T01:02:03 .5Z'),
            @('two fractions', '2026-10-15T01:02:03.5,5Z'),
            @('comma and no digits', '2026-10-15T01:02:03,'),
            @('Z then a dot', '2026-10-15T01:02:03Z.'),
            @('space then a dot', '2026-10-15T01:02:03 .'),
            # zoneless: pwsh 7 reads these in the zone, 5.1 as UTC
            @('zoneless seven digits', '2026-10-15T01:02:03.1234567'),
            @('zoneless whole second', '2026-10-15T01:02:03'),
            @('zoneless one digit', '2026-10-15T01:02:03.5'),
            # spaces and letter case
            @('lowercase t', '2026-10-15t01:02:03'),
            @('lowercase t and Z', '2026-10-15t01:02:03Z'),
            @('space before T', '2026-10-15 T01:02:03Z'),
            @('space after T', '2026-10-15T 01:02:03'),
            @('spaces around T', '2026-10-15 T 01:02:03'),
            @('space and lowercase t', '2026-10-15 t01:02:03Z'),
            @('dot before T', '2026-10-15.T01:02:03Z'),
            @('leading space', ' 2026-10-15T01:02:03Z'),
            @('trailing space', '2026-10-15T01:02:03Z '),
            @('zoneless leading space', ' 2026-10-15T01:02:03'),
            @('zoneless trailing space', '2026-10-15T01:02:03 '),
            @('leading tab', ("`t" + '2026-10-15T01:02:03Z')),
            @('trailing CRLF', ('2026-10-15T01:02:03Z' + "`r`n")),
            @('leading no-break space', ([string][char]0x00A0 + '2026-10-15T01:02:03Z')),
            @('trailing ideographic space', ('2026-10-15T01:02:03Z' + [char]0x3000)),
            @('trailing tab', ('2026-10-15T01:02:03Z' + "`t")),
            @('trailing next line', ('2026-10-15T01:02:03Z' + [char]0x0085)),
            @('trailing line separator', ('2026-10-15T01:02:03Z' + [char]0x2028)),
            @('trailing zero-width space', ('2026-10-15T01:02:03Z' + [char]0x200B)),
            @('leading byte order mark', ([string][char]0xFEFF + '2026-10-15T01:02:03Z')),
            @('trailing NULs', ('2026-10-15T01:02:03Z' + [char]0 + [char]0)),
            @('space then NUL', ('2026-10-15T01:02:03Z ' + [char]0)),
            @('NUL before Z', ('2026-10-15T01:02:03' + [char]0 + 'Z')),
            @('NUL then a letter', ('2026-10-15T01:02:03Z' + [char]0 + 'x')),
            @('zoneless NUL', ('2026-10-15T01:02:03' + [char]0)),
            # the date
            @('one-digit month and day', '2026-1-5T01:02:03Z'),
            @('five-digit year', '02026-10-15T01:02:03Z'),
            @('two-digit year', '26-10-15T01:02:03Z'),
            @('three-digit year', '999-10-15T01:02:03Z'),
            @('year 0999', '0999-10-15T01:02:03Z'),
            @('year 0100', '0100-10-15T01:02:03Z'),
            @('year 0000', '0000-10-15T01:02:03Z'),
            @('year 10000', '10000-01-01T01:02:03Z'),
            @('six-digit year', '002026-10-15T01:02:03Z'),
            @('eight-digit year', '00002026-10-15T01:02:03Z'),
            @('nine-digit year', '000002026-10-15T01:02:03Z'),
            @('month 0', '2026-00-15T01:02:03Z'),
            @('day 0', '2026-10-00T01:02:03Z'),
            @('day 32', '2026-10-32T01:02:03Z'),
            @('April 31', '2026-04-31T01:02:03Z'),
            @('three-digit month', '2026-001-15T01:02:03Z'),
            @('February 29 2026', '2026-02-29T00:00:00Z'),
            @('month 13', '2026-13-01T00:00:00Z'),
            @('year and month', '2026-10T01:02:03Z'),
            @('compact', '20261015T010203Z'),
            @('a letter first', 'x2026-10-15T01:02:03Z'),
            # no T: a date alone, or a date and a time with a space
            @('date only', '2026-10-15'),
            @('date one-digit month and day', '2026-1-5'),
            @('date five-digit year', '02026-10-15'),
            @('date three-digit month', '2026-010-15'),
            @('date three-digit day', '2026-10-015'),
            @('date trailing space', '2026-10-15 '),
            @('date leading space', ' 2026-10-15'),
            @('date Z', '2026-10-15Z'),
            @('date space Z', '2026-10-15 Z'),
            @('date +09:00', '2026-10-15+09:00'),
            @('date space +09:00', '2026-10-15 +09:00'),
            @('date +15:00', '2026-10-15+15:00'),
            @('date three-digit year', '999-10-15'),
            @('date dot', '2026-10-15.'),
            @('date comma', '2026-10-15,'),
            @('date dot Z', '2026-10-15.Z'),
            @('date Z dot', '2026-10-15Z.'),
            @('date +09:00 dot', '2026-10-15+09:00.'),
            @('date +0900', '2026-10-15+0900'),
            @('date -0930', '2026-10-15-0930'),
            @('date -9', '2026-10-15-9'),
            @('date space +14:01', '2026-10-15 +14:01'),
            @('space form', '2026-10-15 01:02:03'),
            @('space form two spaces', '2026-10-15  01:02:03'),
            @('space form tab', ('2026-10-15' + "`t" + '01:02:03')),
            @('space form one-digit parts', '2026-10-15 1:2:3'),
            @('space form no seconds', '2026-10-15 01:2'),
            @('space form hour only', '2026-10-15 01'),
            @('space form three-digit hour', '2026-10-15 001:02:03'),
            @('space form hour 24', '2026-10-15 24:00:00'),
            @('space form fraction', '2026-10-15 01:02:03.5'),
            @('space form nine digits', '2026-10-15 01:02:03.123456789'),
            @('space form rounds up to the day', '2026-10-15 23:59:59.99999999'),
            @('space form dot and no digits', '2026-10-15 01:02:03.'),
            @('space form comma fraction', '2026-10-15 01:02:03,5'),
            @('space form Z', '2026-10-15 01:02:03Z'),
            @('space form space z', '2026-10-15 01:02:03 z'),
            @('space form space Z space', '2026-10-15 01:02:03 Z '),
            @('space form fraction Z', '2026-10-15 01:02:03.1234567Z'),
            @('space form +09:00', '2026-10-15 01:02:03+09:00'),
            @('space form space +09', '2026-10-15 01:02:03 +09'),
            @('space form +9', '2026-10-15 01:02:03+9'),
            @('space form +0900', '2026-10-15 01:02:03+0900'),
            @('space form space -0930', '2026-10-15 01:02:03 -0930'),
            @('space form +1:3', '2026-10-15 01:02:03+1:3'),
            @('space form +14:00', '2026-10-15 01:02:03+14:00'),
            @('space form +15:00', '2026-10-15 01:02:03+15:00'),
            @('space form +99', '2026-10-15 01:02:03+99'),
            @('space form +09:60', '2026-10-15 01:02:03+09:60'),
            @('space form fraction space +09:00', '2026-10-15 01:02:03.1234567 +09:00'),
            @('space form +09:00 space', '2026-10-15 01:02:03+09:00 '),
            @('space form no seconds Z', '2026-10-15 01:02Z'),
            @('space form no seconds +09:00', '2026-10-15 01:02+09:00'),
            @('space form +09:00Z', '2026-10-15 01:02:03+09:00Z'),
            @('space form +09:00 then a letter', '2026-10-15 01:02:03+09:00X'),
            @('space form Z then a digit', '2026-10-15 01:02:03Z1'),
            @('space form offset then Z', '2026-10-15 01:02:03 +09:00 Z'),
            @('space form dot between', '2026-10-15.01:02:03'),
            @('space form comma and space between', '2026-10-15, 01:02:03'),
            @('space form comma between', '2026-10-15,01:02:03'),
            @('space form no seconds dot', '2026-10-15 01:02.'),
            @('space form no seconds comma Z', '2026-10-15 01:02,Z'),
            @('space form no seconds fraction', '2026-10-15 01:02.5'),
            @('space form no seconds comma fraction', '2026-10-15 01:02,5'),
            @('space form comma', '2026-10-15 01:02:03,'),
            @('space form comma Z', '2026-10-15 01:02:03,Z'),
            @('space form comma +09:00', '2026-10-15 01:02:03,+09:00'),
            @('space form comma fraction Z', '2026-10-15 01:02:03,5Z'),
            @('space form two dots', '2026-10-15 01:02:03..'),
            @('space form space fraction', '2026-10-15 01:02:03 .5'),
            @('space form two fractions', '2026-10-15 01:02:03.5.5'),
            @('space form fraction dot', '2026-10-15 01:02:03.5.'),
            @('space form space dot space Z', '2026-10-15 01:02:03 . Z'),
            @('space form space comma Z', '2026-10-15 01:02:03 ,Z'),
            @('space form spaces around a colon', '2026-10-15 01 : 02'),
            @('space form space after a colon Z', '2026-10-15 01: 02 Z'),
            @('space form colon after seconds', '2026-10-15 01:02:03:'),
            @('space form sign then a space', '2026-10-15 01:02:03+ 09:00'),
            @('space form two offsets', '2026-10-15 01:02:03+09:00 +09:00'),
            @('space form Z then an offset', '2026-10-15 01:02:03Z+09:00'),
            @('space form a sign alone', '2026-10-15 01:02:03-'),
            @('space form +0', '2026-10-15 01:02:03+0'),
            @('space form space +1', '2026-10-15 01:02:03 +1'),
            @('space form space +01:3', '2026-10-15 01:02:03 +01:3'),
            @('space form space +01:', '2026-10-15 01:02:03 +01:'),
            @('space form space +0130', '2026-10-15 01:02:03 +0130'),
            @('space form space +130', '2026-10-15 01:02:03 +130'),
            @('space form +123', '2026-10-15 01:02:03+123'),
            @('space form +1:30', '2026-10-15 01:02:03+1:30'),
            @('space form -14:00', '2026-10-15 01:02:03-14:00'),
            @('space form +14:01', '2026-10-15 01:02:03+14:01'),
            @('space form dot -09:00', '2026-10-15 01:02:03.-09:00'),
            @('space form no seconds -09:00', '2026-10-15 01:02-09:00'),
            # not a time
            @('empty', ''),
            @('spaces', '   '),
            @('a word', 'tomorrow'),
            @('words', 'not a date'),
            @('a year', '2026'),
            @('digits', '12345')
        )) { New-NvStampsDate "date $($p[0])" (Get-NvStampsText $p[1]) }

    # --- not strings -------------------------------------------------------------
    foreach ($p in @(
            @('null', '{"at":null}'),
            @('no at', '{}'),
            @('zero', '{"at":0}'),
            @('an integer', '{"at":5}'),
            @('a negative integer', '{"at":-1}'),
            @('a year number', '{"at":2026}'),
            @('milliseconds as a number', '{"at":1760490123123}'),
            @('an exponent', '{"at":1e3}'),
            @('true', '{"at":true}'),
            @('false', '{"at":false}'),
            @('an object', '{"at":{"a":1}}'),
            @('an empty object', '{"at":{}}'),
            @('an empty array', '{"at":[]}'),
            # 5.1's DateTime form, as its ConvertTo-Json escapes it
            @('ms date', '{"at":"\/Date(1760490123123)\/"}'),
            @('ms date zero', '{"at":"\/Date(0)\/"}'),
            @('ms date negative', '{"at":"\/Date(-1000)\/"}'),
            @('ms date +0900', '{"at":"\/Date(1760490123123+0900)\/"}'),
            @('ms date -0130', '{"at":"\/Date(1760490123123-0130)\/"}'),
            @('ms date negative -0130', '{"at":"\/Date(-1000-0130)\/"}'),
            @('ms date +09', '{"at":"\/Date(1760490123123+09)\/"}'),
            @('ms date and a letter', '{"at":"\/Date(1760490123123Z)\/"}'),
            @('ms date no digits', '{"at":"\/Date()\/"}'),
            @('ms date words', '{"at":"\/Date(abc)\/"}'),
            @('ms date then more', '{"at":"\/Date(1760490123123)\/x"}'),
            @('ms date past year 9999', '{"at":"\/Date(253402300800000)\/"}'),
            @('ms date past a long', '{"at":"\/Date(99999999999999999999)\/"}'),
            # ms * 10000 overflows a long and wraps to a tick before 1970
            @('ms date wraps', '{"at":"\/Date(1844674407370955)\/"}')
        )) { New-NvStampsDate "date $($p[0])" $p[1] }

    # --- pwsh 7 reads a zoneless stamp in the zone ---------------------------
    $wall = Get-NvStampsText '2026-10-15T01:02:03.1234567'
    New-NvStampsDate 'zoneless India' $wall 'India Standard Time' 330
    New-NvStampsDate 'zoneless Nepal' $wall 'Nepal Standard Time' 345
    New-NvStampsDate 'zoneless Pacific' $wall 'Pacific Standard Time' (-420)
    New-NvStampsDate 'zoneless Newfoundland' $wall 'Newfoundland Standard Time' (-150)
    New-NvStampsDate 'zoneless Chatham' $wall 'Chatham Islands Standard Time' 825
    New-NvStampsDate 'zoneless Marquesas' $wall 'Marquesas Standard Time' (-570)
    New-NvStampsDate 'zoneless Line Islands' $wall 'Line Islands Standard Time' 840
    New-NvStampsDate 'zoneless Dateline' $wall 'Dateline Standard Time' (-720)
    New-NvStampsDate 'zoneless Greenwich' $wall 'Greenwich Standard Time' 0
    New-NvStampsDate 'offset under Pacific' (Get-NvStampsText '2026-10-15T06:32:03.1234567+05:30') 'Pacific Standard Time' (-420)
    New-NvStampsDate 'hour 24 zoneless under Pacific' (Get-NvStampsText '2026-10-15T24:00:00') 'Pacific Standard Time' (-420)

    # --- and at a DST change, at the standard offset where the change
    # skips or repeats the wall time: each change's five wall times are the
    # last tick before the hour, its first and middle and last ticks, and
    # the first tick after it
    foreach ($s in @(
            @('Pacific', 'Pacific Standard Time', '2026-03-08T10:00:00Z', -480, -420),
            @('Pacific', 'Pacific Standard Time', '2026-11-01T09:00:00Z', -420, -480),
            @('W. Europe', 'W. Europe Standard Time', '2026-03-29T01:00:00Z', 60, 120),
            @('W. Europe', 'W. Europe Standard Time', '2026-10-25T01:00:00Z', 120, 60),
            @('Lord Howe', 'Lord Howe Standard Time', '2026-04-04T15:00:00Z', 660, 630),
            @('Lord Howe', 'Lord Howe Standard Time', '2026-10-03T15:30:00Z', 630, 660))) {
        $c = ConvertTo-NvStampsUtc $s[2]
        $lo = $c.AddMinutes([Math]::Min($s[3], $s[4]))
        $hi = $c.AddMinutes([Math]::Max($s[3], $s[4]))
        $what = if ($s[3] -lt $s[4]) { 'skipped' } else { 'repeated' }
        foreach ($p in @(@('before', $lo.AddTicks(-1)), @('first', $lo), @('middle', $lo.AddTicks([long](($hi - $lo).Ticks / 2))), @('last', $hi.AddTicks(-1)), @('after', $hi))) {
            $w = $p[1].ToString("yyyy-MM-dd'T'HH':'mm':'ss.fffffff", $script:NvInv)
            [ordered]@{
                name  = "dst $($s[0]) $what time $($s[2]), $($p[0])"
                input = [ordered]@{ kind = 'date'; text = (Get-NvStampsText $w); zone = $s[1]; change = $s[2]; before = $s[3]; after = $s[4] }
            }
        }
    }
    foreach ($p in @(
            @('repeated time -07:00', '2026-11-01T01:30:00-07:00'),
            @('repeated time -08:00', '2026-11-01T01:30:00-08:00'),
            @('skipped time space form', '2026-03-08 02:30:00'))) {
        $ch = if ($p[1].StartsWith('2026-11')) { @('2026-11-01T09:00:00Z', -420, -480) } else { @('2026-03-08T10:00:00Z', -480, -420) }
        [ordered]@{
            name  = "dst Pacific $($p[0])"
            input = [ordered]@{ kind = 'date'; text = (Get-NvStampsText $p[1]); zone = 'Pacific Standard Time'; change = $ch[0]; before = $ch[1]; after = $ch[2] }
        }
    }

    # --- files PowerShell's own ConvertTo-Json wrote, as Save-ChatqJson does
    # (compressed: the same but for white space)
    if ($script:NvEdition -eq 'Core') {
        # pwsh 7 read these as DateTimes and writes them back by Kind
        Use-NvTimeZone $kst {
            foreach ($p in @(
                    @('seven digits Z', (Get-NvStampsText '2026-10-15T01:02:03.1234567Z')),
                    @('trailing zeros Z', (Get-NvStampsText '2026-10-15T01:02:03.1230000Z')),
                    @('zero fraction Z', (Get-NvStampsText '2026-10-15T01:02:03.0000000Z')),
                    @('+05:30', (Get-NvStampsText '2026-10-15T06:32:03.1234567+05:30')),
                    @('zoneless', (Get-NvStampsText '2026-10-15T01:02:03')),
                    @('zoneless one digit', (Get-NvStampsText '2026-10-15T01:02:03.5')),
                    @('hour 24 Z', (Get-NvStampsText '2026-10-15T24:00:00Z')),
                    @('+09:60', (Get-NvStampsText '2026-10-15T01:02:03+09:60')),
                    @('ms date', '{"at":"\/Date(1760490123123)\/"}'),
                    @('ms date +0900', '{"at":"\/Date(1760490123123+0900)\/"}'))) {
                [ordered]@{
                    name  = "pwsh 7 rewrites $($p[0])"
                    by    = 'Core'
                    input = [ordered]@{ kind = 'date'; from = $p[1]; text = ($p[1] | ConvertFrom-Json | ConvertTo-Json -Depth 8 -Compress); zone = $kst; utcOffsetMinutes = 540 }
                }
            }
        }
    }
    else {
        # 5.1 writes any DateTime as "\/Date(ms)\/", whole milliseconds of
        # UTC, the number in the culture's digits and sign
        Use-NvCulture 'en-US' {
            Use-NvTimeZone $kst {
                $utc = [System.DateTimeKind]::Utc
                foreach ($p in @(
                        @('a Utc DateTime', ([datetime]::new(2026, 10, 15, 1, 2, 3, $utc).AddTicks(1234567))),
                        @('a Local DateTime', ([datetime]::new(2026, 10, 15, 10, 2, 3, [System.DateTimeKind]::Local).AddTicks(1234567))),
                        @('an Unspecified DateTime', ([datetime]::new(2026, 10, 15, 10, 2, 3).AddTicks(1234567))),
                        @('a DateTime before 1970', ([datetime]::new(1969, 12, 31, 23, 59, 58, $utc).AddTicks(9999999))))) {
                    [ordered]@{
                        name  = "5.1 writes $($p[0])"
                        by    = 'Desktop'
                        input = [ordered]@{ kind = 'date'; from = "$($p[1].Kind) $($p[1].ToString('o', $script:NvInv))"; text = ([pscustomobject]@{ at = $p[1] } | ConvertTo-Json -Depth 8 -Compress); zone = $kst; utcOffsetMinutes = 540 }
                    }
                }
                $src = '{"at":"\/Date(1760490123123+0900)\/"}'
                [ordered]@{
                    name  = '5.1 rewrites ms date +0900'
                    by    = 'Desktop'
                    input = [ordered]@{ kind = 'date'; from = $src; text = ($src | ConvertFrom-Json | ConvertTo-Json -Depth 8 -Compress); zone = $kst; utcOffsetMinutes = 540 }
                }
            }
        }
    }
} -Expect {
    param($In, $Name)
    switch ([string]$In.kind) {
        'stamp' { return (Get-NvStampsStamp $In $Name) }
        'date' { return (Get-NvStampsDate $In $Name) }
    }
    throw "a case of kind '$($In.kind)'"
}
