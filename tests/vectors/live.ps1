# tests/vectors/live.ps1: the contract checks no vector file can hold
# (native/SPEC.md 6.1), asked of a real chatqd build. Dot-sourced by
# tests/sections/native.ps1 when one is built, and by tests/vectors.ps1
# -Live, which CI runs under other zones.
#
# DPAPI keys are this user's and a zone's changes are this PC's, so each
# check makes its cases here, takes this PowerShell's answers, and asks
# chatqd the same:
# - chatqd vector dpapi <hex>: Unprotect-ChatqSecret of
#   {value: <hex>, protected: true}. Exit 0 with the text as UTF-8 on
#   stdout and nothing after it ('' is no bytes); exit 1 and nothing where
#   PowerShell gives $null.
# - chatqd vector local-stamps --ps <exe> <stamp>...: per stamp one line,
#   LF-ended: the instant ConvertTo-ChatqDate makes of the stamp as that
#   PowerShell's ConvertFrom-Json hands it over, in this PC's zone as
#   (Get-Date).ToString('o') would render it; an empty line for $null.
# Like the generators, this file is ASCII: other text is U '\uXXXX'.

function Invoke-NvLiveChecks([string]$Exe) {
    # one @{ name; ok; detail } per check; one that throws fails, and the
    # rest still run
    $checks = [ordered]@{
        'DPAPI: what Protect-ChatqSecret seals opens to what Unprotect-ChatqSecret gives' = 'Get-NvLiveSealed'
        'DPAPI: what Unprotect-ChatqSecret cannot open, chatqd refuses: exit 1, nothing said' = 'Get-NvLiveRefused'
        "local stamps: instants around this zone's changes, as (Get-Date).ToString('o') renders them" = 'Get-NvLiveNow'
        'local stamps: those instants and wall-clock times, as ConvertTo-ChatqDate reads them from JSON' = 'Get-NvLiveRead'
    }
    foreach ($name in @($checks.Keys)) {
        try {
            $r = & $checks[$name] $Exe
            $misses = @($r.Misses)
            $detail = if ($misses.Count) { "$($misses.Count) of $($r.Cases) differ: $(@($misses | Select-Object -First 3) -join '; ')" } else { "$($r.Cases) cases" }
            @{ name = $name; ok = ($misses.Count -eq 0); detail = $detail }
        }
        catch { @{ name = $name; ok = $false; detail = "threw: $($_.Exception.Message)" } }
    }
}

# --- DPAPI ---------------------------------------------------------------------
function Get-NvLiveSealed([string]$Exe) {
    # texts sealed as alerts, the phone and pairing seal theirs, then blobs
    # DPAPI makes and Protect-ChatqSecret cannot: an empty text, the
    # machine's scope, and hex in capitals
    Add-Type -AssemblyName System.Security
    $cases = @(
        foreach ($plain in @(
                'chatq',
                ('' + [char]0xD55C + [char]0xAE00 + ' ' + [char]0xD83D + [char]0xDE00 + ' caf' + [char]0xE9),
                (ConvertTo-ChatqB64Url ([byte[]](0..31))),
                (U ' a b\tc\r\nd '),
                ([string][char]0xFEFF + 'a BOM first'),
                (U 'a\u0000b'),
                ('0123456789abcdef' * 250))) {
            @{ Label = "sealed $(Format-NvLiveText $plain)"; Hex = [string](Protect-ChatqSecret $plain).value }
        }
        @{ Label = 'an empty text'; Hex = (Protect-NvLiveBytes @() 'CurrentUser') }
        @{ Label = 'the machine scope'; Hex = (Protect-NvLiveBytes ([Text.Encoding]::Unicode.GetBytes('machine')) 'LocalMachine') }
        @{ Label = 'hex in capitals'; Hex = ([string](Protect-ChatqSecret 'chatq').value).ToUpperInvariant() }
    )
    Compare-NvLiveDpapi $Exe $cases
}

function Get-NvLiveRefused([string]$Exe) {
    # a blob spoilt as a hand edit or another tool spoils one, and blobs
    # DPAPI opens that are still no text
    Add-Type -AssemblyName System.Security
    $h = [string](Protect-ChatqSecret 'chatq').value
    $mid = 2 * [int][Math]::Floor($h.Length / 4)
    $flip = '{0:x2}' -f ([Convert]::ToByte($h.Substring($mid, 2), 16) -bxor 1)
    $cases = @(
        @{ Label = 'a byte changed mid-blob'; Hex = $h.Substring(0, $mid) + $flip + $h.Substring($mid + 2) }
        @{ Label = 'a digit short'; Hex = $h.Substring(1) }
        @{ Label = 'zz for two digits'; Hex = 'zz' + $h.Substring(2) }
        @{ Label = 'Arabic-Indic digits for two'; Hex = [string][char]0x0660 + [char]0x0661 + $h.Substring(2) }
        @{ Label = 'spaces around'; Hex = " $h " }
        @{ Label = 'its first half'; Hex = $h.Substring(0, $mid) }
        @{ Label = 'an empty value'; Hex = '' }
        @{ Label = 'three bytes, no UTF-16'; Hex = (Protect-NvLiveBytes ([byte[]](0x41, 0, 0x42)) 'CurrentUser') }
        @{ Label = 'sealed with entropy'; Hex = (Protect-NvLiveBytes ([Text.Encoding]::Unicode.GetBytes('salt')) 'CurrentUser' ([byte[]](1, 2, 3))) }
    )
    Compare-NvLiveDpapi $Exe $cases
}

function Protect-NvLiveBytes([byte[]]$Bytes, [string]$Scope, [byte[]]$Entropy) {
    # ProtectedData's blob in ConvertFrom-SecureString's lowercase hex
    $blob = [Security.Cryptography.ProtectedData]::Protect([byte[]]@($Bytes), $Entropy, $Scope)
    [BitConverter]::ToString($blob).Replace('-', '').ToLowerInvariant()
}

function Compare-NvLiveDpapi([string]$Exe, $Cases) {
    # each case's hex asked of chatqd, against Unprotect-ChatqSecret's answer
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $misses = @(foreach ($c in $Cases) {
            $want = Unprotect-ChatqSecret @{ value = $c.Hex; protected = $true }
            $r = Invoke-NvLiveExe $Exe @('vector', 'dpapi', $c.Hex)
            $got = $utf8.GetString($r.Out)
            $same = if ($null -eq $want) { $r.Code -eq 1 -and $r.Out.Length -eq 0 } else { $r.Code -eq 0 -and [string]::Equals($got, [string]$want, [StringComparison]::Ordinal) }
            if (-not $same) {
                $err = if ($r.Err) { ", stderr $(Format-NvLiveText $r.Err)" } else { '' }
                "$($c.Label): PowerShell $(Format-NvLiveText $want), chatqd exit $($r.Code) $(Format-NvLiveText $got)$err"
            }
        })
    @{ Cases = @($Cases).Count; Misses = $misses }
}

# --- this PC's zone ----------------------------------------------------------
function Get-NvLiveNow([string]$Exe) {
    # each instant as a UTC stamp; DateTime.Now is UtcNow.ToLocalTime(), so
    # this is (Get-Date).ToString('o') at that instant
    $year = [DateTime]::UtcNow.Year
    $cases = @(foreach ($u in @(Get-NvLiveInstants @(Get-NvLiveChanges $year) $year)) {
            @{ Stamp = $u.ToString('o'); Want = $u.ToLocalTime().ToString('o') }
        })
    Compare-NvLiveStamps $Exe $cases
}

function Get-NvLiveRead([string]$Exe) {
    # each instant as a UTC stamp, a local one and a wall-clock time with no
    # zone, then wall-clock times at the edges and middle of each change's
    # gap or overlap, all read as ConvertTo-ChatqDate reads them
    $year = [DateTime]::UtcNow.Year
    $changes = @(Get-NvLiveChanges $year)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $wall = "yyyy-MM-dd'T'HH:mm:ss.fffffff"
    $stamps = @(
        foreach ($u in @(Get-NvLiveInstants $changes $year)) {
            $l = $u.ToLocalTime()
            $u.ToString('o')
            $l.ToString('o')
            $l.ToString($wall, $inv)
        }
        foreach ($c in $changes) {
            $lo = [Math]::Min($c.Before.Ticks, $c.After.Ticks)
            $hi = [Math]::Max($c.Before.Ticks, $c.After.Ticks)
            foreach ($w in ($lo - 1), $lo, ($lo + (($hi - $lo) -shr 1)), ($hi - 1), $hi) {
                [datetime]::new($c.At.Ticks + $w, [DateTimeKind]::Unspecified).ToString($wall, $inv)
            }
        }
    )
    $cases = @(foreach ($s in $stamps) {
            $v = ('{"v":"' + $s + '"}' | ConvertFrom-Json).v
            $d = ConvertTo-ChatqDate $v
            # the instant it means, which a pwsh DateTime with no zone keeps
            # implicit, rendered as Get-Date renders
            @{ Stamp = $s; Want = $(if ($null -eq $d) { '' } else { $d.ToUniversalTime().ToLocalTime().ToString('o') }) }
        })
    Compare-NvLiveStamps $Exe $cases
}

function Get-NvLiveChanges([int]$Year) {
    # each change of this zone's offset from a day before $Year to the end of
    # the next: its first tick (UTC) and the offsets before and after. Found
    # an hour at a time and halved down to the tick, so a change is what
    # TimeZoneInfo.Local's adjustment rules make it; none in a zone with none
    $tz = [TimeZoneInfo]::Local
    $t = [datetime]::new($Year, 1, 1, 0, 0, 0, [DateTimeKind]::Utc).AddDays(-1)
    $end = [datetime]::new($Year + 2, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
    $was = $tz.GetUtcOffset($t)
    while ($t -lt $end) {
        $next = $t.AddHours(1)
        $off = $tz.GetUtcOffset($next)
        if ($off -ne $was) {
            $lo = $t.Ticks
            $hi = $next.Ticks
            while ($hi - $lo -gt 1) {
                $mid = $lo + (($hi - $lo) -shr 1)
                if ($tz.GetUtcOffset([datetime]::new($mid, [DateTimeKind]::Utc)) -eq $was) { $lo = $mid } else { $hi = $mid }
            }
            @{ At = [datetime]::new($hi, [DateTimeKind]::Utc); Before = $was; After = $off }
            $was = $off
        }
        $t = $next
    }
}

function Get-NvLiveInstants($Changes, [int]$Year) {
    # UTC instants: around each change from 2 h before to 2 h after, the
    # ticks either side of it too; two a month over both years; and each
    # local new year with the tick before it
    $steps = -72000000000, -36000000000, -18000000000, -10000000, -1, 0, 1, 10000000, 18000000000, 36000000000, 54000000000, 72000000000
    foreach ($c in $Changes) { foreach ($s in $steps) { $c.At.AddTicks($s) } }
    foreach ($y in $Year, ($Year + 1)) {
        foreach ($m in 1..12) {
            [datetime]::new($y, $m, 1, 0, 0, 0, [DateTimeKind]::Utc)
            [datetime]::new($y, $m, 15, 12, 30, 0, [DateTimeKind]::Utc).AddTicks(1234567)
        }
    }
    foreach ($y in $Year, ($Year + 1), ($Year + 2)) {
        $ny = [datetime]::new($y, 1, 1, 0, 0, 0, [DateTimeKind]::Local).ToUniversalTime()
        $ny.AddTicks(-1)
        $ny
    }
}

function Compare-NvLiveStamps([string]$Exe, $Cases) {
    # the stamps asked of chatqd as this PowerShell's, 100 to a run, which
    # keeps a command line far below its 32,767 characters
    $ps = (Get-Process -Id $PID).Path
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $misses = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $Cases.Count; $i += 100) {
        $batch = @($Cases[$i..([Math]::Min($i + 100, $Cases.Count) - 1)])
        $r = Invoke-NvLiveExe $Exe (@('vector', 'local-stamps', '--ps', $ps) + @($batch | ForEach-Object { $_.Stamp }))
        $lines = $utf8.GetString($r.Out).Split("`n")
        if ($r.Code -ne 0 -or $lines.Count -ne $batch.Count + 1) {
            [void]$misses.Add("a run of $($batch.Count) stamps: exit $($r.Code), $($lines.Count - 1) lines, stderr $(Format-NvLiveText $r.Err)")
            continue
        }
        for ($k = 0; $k -lt $batch.Count; $k++) {
            if (-not [string]::Equals($lines[$k], $batch[$k].Want, [StringComparison]::Ordinal)) {
                [void]$misses.Add("$($batch[$k].Stamp): PowerShell '$($batch[$k].Want)', chatqd '$($lines[$k])'")
            }
        }
    }
    @{ Cases = $Cases.Count; Misses = @($misses) }
}

# --- running chatqd ------------------------------------------------------------
function Invoke-NvLiveExe([string]$Exe, [string[]]$ArgList) {
    # chatqd started as Invoke-ChatqNativePreflight starts it (a GUI exe,
    # which & neither waits for nor reads), both pipes drained while it
    # runs, and stdout kept as bytes, so a BOM it writes stays text
    $p = [System.Diagnostics.Process]::Start((New-ChatqProcessStartInfo -Exe $Exe -ArgList $ArgList))
    try {
        try { $p.StandardInput.Close() } catch {}
        $buf = New-Object System.IO.MemoryStream
        $copy = $p.StandardOutput.BaseStream.CopyToAsync($buf)
        $err = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(30000)) { try { $p.Kill() } catch {}; throw "chatqd $($ArgList[1]) gave no answer within 30 s" }
        if (-not ($copy.Wait(10000) -and $err.Wait(10000))) { throw "chatqd $($ArgList[1]) left its pipes open" }
        @{ Code = $p.ExitCode; Out = $buf.ToArray(); Err = $err.Result }
    }
    finally { $p.Dispose() }
}

function Format-NvLiveText($S) {
    # a text for a failure's detail: quoted, all but printable ASCII as
    # \uXXXX, cut at 60
    if ($null -eq $S) { return '$null' }
    $t = -join @(foreach ($ch in ([string]$S).ToCharArray()) {
            if ([int]$ch -lt 0x20 -or [int]$ch -gt 0x7E) { '\u{0:X4}' -f [int]$ch } else { [string]$ch }
        })
    if ($t.Length -gt 60) { $t = $t.Substring(0, 57) + '...' }
    "'$t'"
}
