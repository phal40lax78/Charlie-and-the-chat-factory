# tests/vectors/json-compat.ps1: native/vectors/json-compat.json (native/SPEC.md
# 2.2, 6.1) - JSON files as Read-ChatqJson reads them under each PowerShell.
# The Rust runner reads the same bytes with chatq-core's json::parse_tolerant_in,
# ps_dates_in and ps_return.
#
# An input is the file: bytes (hex), text (written as UTF-8), or pretty - text
# exactly as chatqd's writer, json::to_pretty, writes it, which the Rust runner
# also checks. Cases by an edition are files its own Save-ChatqJson wrote.
#
# The answer is the value Read-ChatqJson returned - objects in their order, a
# [datetime] as {date: its 'o' in Korea Standard Time} - and whether the read
# needed a repair (SPEC 2.2): the text Get-Content gave does not encode back to
# the file's bytes after its mark (a byte did not decode, or was dropped), or
# it holds a backslash-u escape of a surrogate that is not half of a pair.
#
# In the JSON texts below, ^ stands for a backslash.

function Get-NvJsonCompatText([string]$Text) {
    return $Text.Replace('^', [string][char]92)
}

function Get-NvJsonCompatHex([string]$Text, $Encoding) {
    if (-not $Encoding) { $Encoding = $script:NvUtf8 }
    return (ConvertTo-NvHex ($Encoding.GetBytes((Get-NvJsonCompatText $Text))))
}

function New-NvJsonCompatCase([string]$Name, [string]$Kind, [string]$Value, [string]$By) {
    $c = [ordered]@{ name = $Name }
    if ($By) { $c['by'] = $By }
    $c['input'] = [ordered]@{ $Kind = $Value }
    return $c
}

function New-NvJsonCompatText([string]$Name, [string]$Text) {
    return (New-NvJsonCompatCase $Name 'text' (Get-NvJsonCompatText $Text))
}

function New-NvJsonCompatPretty([string]$Name, [string[]]$Lines) {
    return (New-NvJsonCompatCase $Name 'pretty' (Get-NvJsonCompatText ($Lines -join "`n")))
}

function Get-NvJsonCompatWritten {
    # name -> the bytes this PowerShell's Save-ChatqJson writes for a value,
    # in Korea Standard Time: 5.1 turns a local [datetime] into UTC by it,
    # pwsh 7 writes its offset
    $WarningPreference = 'SilentlyContinue'
    $made = Join-Path $script:NvScratch 'json-compat-written'
    $out = [ordered]@{}
    $null = Use-NvTimeZone 'Korea Standard Time' {
        $objs = [ordered]@{}
        $objs['escapes'] = [ordered]@{
            t = 'a<b>&''c''"d\e/f' + [char]0x7F + [char]0x85 + [char]0x2028 + [char]0xE9 + [char]0xD55C
            c = [string][char]0 + [char]8 + [char]9 + [char]10 + [char]12 + [char]13 + [char]0x1F
        }
        $objs['lone surrogates'] = [ordered]@{ t = 'cut ' + [char]0xD83D; u = [string][char]0xDE00 + 'x'; pair = [string][char]0xD83D + [char]0xDE00 }
        $objs['lists'] = [ordered]@{ one = @('x'); oneInt = @(7); empty = @(); nested = (, @('x')); list = [System.Collections.Generic.List[string]]@('a'); nulls = @($null) }
        $w = Write-Output @('x') -NoEnumerate
        $objs['a list kept whole'] = [ordered]@{ a = $w; b = [pscustomobject]@{ c = @(1) } }
        $objs['dates'] = [ordered]@{
            utc = [datetime]::new(2026, 10, 15, 1, 2, 3, 123, [DateTimeKind]::Utc)
            local = [datetime]::new(2026, 10, 15, 10, 2, 3, 0, [DateTimeKind]::Local)
            unspec = [datetime]::new(2026, 10, 15, 1, 2, 3, [DateTimeKind]::Unspecified)
            ticks = [datetime]::new(2026, 10, 15, 1, 2, 3, [DateTimeKind]::Utc).AddTicks(1234567)
            min = [datetime]::MinValue
        }
        $d1 = 'leaf'
        for ($i = 0; $i -lt 10; $i++) { $d1 = [ordered]@{ ("l$i") = $d1 } }
        $objs['deep ordered'] = $d1
        $d2 = 'leaf'
        for ($i = 0; $i -lt 10; $i++) { $d2 = [pscustomobject]@{ ("l$i") = $d2 } }
        $objs['deep object'] = $d2
        $d3 = @{ x = 1 }
        for ($i = 0; $i -lt 9; $i++) { $d3 = @{ ("l$i") = $d3 } }
        $objs['deep hashtable'] = $d3
        $objs['numbers'] = [ordered]@{ i = 1; l = 2147483648L; d = 1.5; dec = [decimal]1.5; big = [double]1e300; neg = -0.0; f = [single]0.1; tiny = 1e-7 }
        $objs['truth'] = [ordered]@{ t = $true; f = $false; n = $null }
        $objs['a list of one'] = @('x')
        $objs['a list of two'] = @('x', 'y')
        $objs['an empty name'] = [ordered]@{ '' = 1 }
        $job = '{"id":"j-1","kind":"prompt","state":"queued","seq":3,"createdAt":"2026-10-15T01:02:03.1234567Z",' +
            '"startedAt":"2026-10-15T10:02:03.5+09:00","at":"/Date(1760490123000)/","prompt":"' + [char]0xD55C + [char]0xAE00 +
            ' ^"q^" <&>","chat":{"title":"t","session":null},"tags":["a"],"steps":[],"first":false}'
        $objs['a job read back'] = (Get-NvJsonCompatText $job) | ConvertFrom-Json
        foreach ($k in @($objs.Keys)) {
            $p = Join-Path $made (($k -replace '[^A-Za-z0-9]', '-') + '.json')
            Save-ChatqJson $p $objs[$k]
            $out[$k] = ConvertTo-NvHex ([IO.File]::ReadAllBytes($p))
        }
    }
    return $out
}

function ConvertTo-NvJsonCompatValue($V) {
    # a value Read-ChatqJson returned, as an answer holds it
    if ($null -eq $V) { return $null }
    if ($V -is [datetime]) { return [ordered]@{ date = $V.ToString('o', $script:NvInv) } }
    # NaN and the infinities, which no JSON holds: as their [string] text
    if ($V -is [double] -and ([double]::IsNaN($V) -or [double]::IsInfinity($V))) { return [string]$V }
    if ($V.GetType().FullName -eq 'System.Management.Automation.PSCustomObject') {
        # names that only an ordinal comparison tells apart (ss and sharp s)
        $o = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
        foreach ($p in $V.PSObject.Properties) { $o.Add($p.Name, (ConvertTo-NvJsonCompatValue $p.Value)) }
        return $o
    }
    if ($V -is [array]) { return , @(foreach ($x in $V) { , (ConvertTo-NvJsonCompatValue $x) }) }
    return $V
}

function Test-NvJsonCompatRepaired([byte[]]$Bytes, [string]$Text) {
    # $Text is what Get-Content made of $Bytes; the encoding is the one a
    # StreamReader detects for them, as Get-Content's does
    $ms = New-Object System.IO.MemoryStream (, $Bytes)
    $sr = New-Object System.IO.StreamReader ($ms, $script:NvUtf8, $true)
    try { [void]$sr.ReadToEnd(); $enc = $sr.CurrentEncoding } finally { $sr.Dispose() }
    $mark = $enc.GetPreamble()
    $skip = 0
    if ($mark.Length -and $Bytes.Length -ge $mark.Length) {
        $skip = $mark.Length
        for ($i = 0; $i -lt $mark.Length; $i++) { if ($Bytes[$i] -ne $mark[$i]) { $skip = 0; break } }
    }
    $back = $enc.GetBytes($Text)
    if ($back.Length -ne $Bytes.Length - $skip) { return $true }
    for ($i = 0; $i -lt $back.Length; $i++) { if ($back[$i] -ne $Bytes[$skip + $i]) { return $true } }
    $esc = [regex]::Matches($Text, '\\(?:u([0-9A-Fa-f]{4})|.)', 'Singleline')
    for ($i = 0; $i -lt $esc.Count; $i++) {
        $g = $esc[$i].Groups[1]
        if (-not $g.Success) { continue }
        $u = [Convert]::ToInt32($g.Value, 16)
        if ($u -lt 0xD800 -or $u -gt 0xDFFF) { continue }
        if ($u -le 0xDBFF -and $i + 1 -lt $esc.Count -and $esc[$i + 1].Index -eq $esc[$i].Index + 6 -and $esc[$i + 1].Groups[1].Success) {
            $lo = [Convert]::ToInt32($esc[$i + 1].Groups[1].Value, 16)
            if ($lo -ge 0xDC00 -and $lo -le 0xDFFF) { $i++; continue }
        }
        return $true
    }
    return $false
}

Register-NvVector -Name 'json-compat' -About 'JSON files as Read-ChatqJson (src/queue.ps1) reads them under each PowerShell - Get-Content -Raw -Encoding UTF8 | ConvertFrom-Json, then return - and whether the read needed a repair (SPEC 2.2). input: the file as bytes (hex), as text written as UTF-8, or as pretty: text exactly as chatqd''s writer (json::to_pretty) writes it. expect: {value, repaired}; value is null where Read-ChatqJson returns $null, objects keep their order, a [datetime] is {date: its ''o'' in Korea Standard Time}. Cases by an edition are files its Save-ChatqJson (ConvertTo-Json -Depth 8) wrote.' -Cases {
    # config.json as people write it: comments, trailing commas, quotes and
    # bare names, which pwsh 7's Newtonsoft reads and 5.1's
    # JavaScriptSerializer mostly does not
    $lf = "`n"
    $crlf = "`r`n"
    New-NvJsonCompatText 'config a line comment' ('{' + $lf + '  // quiet hours' + $lf + '  "a": 1' + $lf + '}')
    New-NvJsonCompatText 'config a block comment' '{ /* x */ "a": 1 }'
    New-NvJsonCompatText 'config a line comment, CRLF' ('{' + $crlf + '  // quiet hours' + $crlf + '  "a": 1' + $crlf + '}')
    New-NvJsonCompatText 'config a comment with an apostrophe' ('{' + $lf + "  // it's quiet" + $lf + '  "a": 1' + $lf + '}')
    New-NvJsonCompatText 'config a trailing comma' '{"a":1,}'
    New-NvJsonCompatText 'config a trailing comma in a list' '{"a":[1,2,],"b":1}'
    New-NvJsonCompatText 'config single quotes' "{'a':'x'}"
    New-NvJsonCompatCase 'config a mark, then a comment' 'bytes' ('efbbbf' + (Get-NvJsonCompatHex ('// c' + $lf + '{"a":1}')))
    New-NvJsonCompatText 'config slashes in a string' '{"u":"https://ntfy.sh//x","v":"/* no */"}'
    New-NvJsonCompatText 'config a line comment after the object' ('{"a":1}' + $lf + '// end')
    New-NvJsonCompatText 'config a line comment after the object, then a line break' ('{"a":1}' + $lf + '// end' + $lf)
    New-NvJsonCompatText 'config a bare // after the object' ('{"a":1}' + $lf + '//')
    New-NvJsonCompatText 'config a bare // after the object, then a line break' ('{"a":1}' + $lf + '//' + $lf)
    New-NvJsonCompatText 'config a block comment after the object' '{"a":1}/* end */'
    New-NvJsonCompatText 'config an open block comment after the object' '{"a":1}/* end'
    New-NvJsonCompatText 'config a comment before the colon' '{"a" /* x */ : 1}'
    New-NvJsonCompatText 'config a comment after the colon' '{"a": /* x */ 1}'
    New-NvJsonCompatText 'config a comment before the comma' '{"a": 1 /* x */, "b": 2}'
    New-NvJsonCompatText 'config a comment in a list' '{"a":[1 /* x */, 2]}'
    New-NvJsonCompatText 'config a comment before a list' '/* c */ [1]'
    New-NvJsonCompatText 'config a comment alone' '// nothing'
    New-NvJsonCompatText 'config a bare name' '{a: 1}'
    New-NvJsonCompatText 'config a bare name with a dash' '{quiet-hours: 1}'
    New-NvJsonCompatText 'config a no-break space before the first name' ('{' + [char]0xA0 + '"a":1}')
    New-NvJsonCompatText 'config a raw tab in a string' ('{"a":"x' + "`t" + 'y"}')
    New-NvJsonCompatText 'config a raw line break in a string' ('{"a":"x' + $lf + 'y"}')
    New-NvJsonCompatText 'config True' '{"a":True}'
    New-NvJsonCompatText 'config a hash comment' ('{ # x' + $lf + ' "a":1}')

    # what one ConvertFrom-Json or the other takes past strict JSON
    New-NvJsonCompatText 'lenient NaN' '{"a":NaN}'
    New-NvJsonCompatText 'lenient Infinity' '{"a":Infinity}'
    New-NvJsonCompatText 'lenient -Infinity' '{"a":-Infinity}'
    New-NvJsonCompatText 'lenient past a double' '{"a":1e400}'
    New-NvJsonCompatText 'lenient undefined' '{"a":undefined}'
    New-NvJsonCompatText 'lenient hex' '{"a":0x10}'
    New-NvJsonCompatText 'lenient octal' '{"a":010}'
    New-NvJsonCompatText 'lenient an empty list slot' '{"a":[1,,2]}'
    New-NvJsonCompatText 'lenient a NUL between tokens' ('{"a":' + [char]0 + '1}')
    New-NvJsonCompatText 'lenient a plus sign' '{"a":+5}'
    New-NvJsonCompatText 'lenient no digit before the point' '{"a":-.5}'
    New-NvJsonCompatText 'lenient a dash after the digits' '{"a":5-}'
    New-NvJsonCompatText 'lenient decimals' '{"a":1.50,"b":1e3,"c":-0.0}'
    New-NvJsonCompatText 'lenient a dollar name' '{$k:1}'
    New-NvJsonCompatText 'lenient a spaced escape' '{"a":"^u 041"}'

    # bytes that do not decode, inside {"t":"a...b"}
    $seqs = [ordered]@{
        'ff (never UTF-8)' = 'ff'; 'c0 80 (overlong)' = 'c080'; 'e0 80 80 (overlong)' = 'e08080'
        'ed a0 80 (a surrogate)' = 'eda080'; 'ed a0 bd ed b8 80 (a CESU-8 pair)' = 'eda0bdedb880'
        'f0 80 80 80 (overlong)' = 'f0808080'; 'f4 90 80 80 (past U+10FFFF)' = 'f4908080'
        'f8 88 80 80 80 (five bytes)' = 'f888808080'; 'fc 84 80 80 80 80 (six bytes)' = 'fc8480808080'
        'e2 82 (cut short)' = 'e282'; 'f0 9f 98 (cut short)' = 'f09f98'; 'e2 then e2 82 ac' = 'e2e282ac'
        '80 (a stray)' = '80'; 'bf bf (strays)' = 'bfbf'; 'e0 80 41' = 'e08041'; 'f4 90 80 41' = 'f4908041'
        'ed af 41' = 'edaf41'; 'f0 8f' = 'f08f'; 'c1' = 'c1'; 'f5' = 'f5'
        'ef bf bd (a U+FFFD that is text)' = 'efbfbd'; 'f0 9f 98 80 (an emoji)' = 'f09f9880'; 'ed 95 9c (hangul)' = 'ed959c'
    }
    foreach ($k in @($seqs.Keys)) { New-NvJsonCompatCase "decode $k" 'bytes' ('7b2274223a2261' + $seqs[$k] + '62227d') }
    # bytes cut at the end of the file: 5.1 drops them, pwsh 7 reads U+FFFD
    $obj = Get-NvJsonCompatHex '{"t":1}'
    New-NvJsonCompatCase 'end e2 82 after the object' 'bytes' ($obj + 'e282')
    New-NvJsonCompatCase 'end c3 after the object' 'bytes' ($obj + 'c3')
    New-NvJsonCompatCase 'end ff after the object' 'bytes' ($obj + 'ff')
    New-NvJsonCompatCase 'end f0 9f 98 after a line break' 'bytes' ($obj + '0af09f98')

    # byte-order marks, as StreamReader detects them
    $t = '{"t":"x' + [char]0xD55C + '"}'
    $le32 = [System.Text.Encoding]::UTF32
    $be32 = New-Object System.Text.UTF32Encoding ($true, $false)
    New-NvJsonCompatCase 'mark utf-8' 'bytes' ('efbbbf' + (Get-NvJsonCompatHex $t))
    New-NvJsonCompatCase 'mark utf-8 twice' 'bytes' ('efbbbfefbbbf' + (Get-NvJsonCompatHex $t))
    New-NvJsonCompatCase 'mark utf-16le' 'bytes' ('fffe' + (Get-NvJsonCompatHex $t ([System.Text.Encoding]::Unicode)))
    New-NvJsonCompatCase 'mark utf-16be' 'bytes' ('feff' + (Get-NvJsonCompatHex $t ([System.Text.Encoding]::BigEndianUnicode)))
    New-NvJsonCompatCase 'mark utf-32le' 'bytes' ('fffe0000' + (Get-NvJsonCompatHex $t $le32))
    New-NvJsonCompatCase 'mark utf-32be' 'bytes' ('0000feff' + (Get-NvJsonCompatHex $t $be32))
    $u16 = [System.Text.Encoding]::Unicode
    New-NvJsonCompatCase 'mark utf-16le, a lone high half' 'bytes' ('fffe' + (Get-NvJsonCompatHex '{"t":"' $u16) + '3dd8' + (Get-NvJsonCompatHex 'x"}' $u16))
    New-NvJsonCompatCase 'mark utf-16le, a lone low half' 'bytes' ('fffe' + (Get-NvJsonCompatHex '{"t":"' $u16) + '00dc' + (Get-NvJsonCompatHex 'x"}' $u16))
    New-NvJsonCompatCase 'mark utf-16le, an odd byte at the end' 'bytes' ('fffe' + (Get-NvJsonCompatHex '{"t":"x"}' $u16) + '41')
    New-NvJsonCompatCase 'mark utf-32le, past U+10FFFF' 'bytes' ('fffe0000' + (Get-NvJsonCompatHex '{"t":"' $le32) + '00001100' + (Get-NvJsonCompatHex '"}' $le32))
    New-NvJsonCompatCase 'mark utf-16le alone' 'bytes' 'fffe'
    New-NvJsonCompatCase 'mark utf-8 alone' 'bytes' 'efbbbf'
    New-NvJsonCompatCase 'mark utf-8 cut short' 'bytes' 'efbb'
    New-NvJsonCompatCase 'empty file' 'bytes' ''
    New-NvJsonCompatCase 'one byte fe' 'bytes' 'fe'
    New-NvJsonCompatText 'white space only' (" `r`n`t ")
    New-NvJsonCompatText 'null' 'null'

    # backslash-u escapes of surrogates
    New-NvJsonCompatText 'escape a high half cut off' '{"t":"cut ^ud83d"}'
    New-NvJsonCompatText 'escape a lone low half' '{"t":"^ude00x"}'
    New-NvJsonCompatText 'escape a pair' '{"t":"^ud83d^ude00"}'
    New-NvJsonCompatText 'escape a pair in upper case' '{"t":"^uD83D^uDE00"}'
    New-NvJsonCompatText 'escape a pair in mixed case' '{"t":"^uD83d^uDe00"}'
    New-NvJsonCompatText 'escape high, high, low' '{"t":"^ud83d^ud83d^ude00"}'
    New-NvJsonCompatText 'escape a high half, then A' '{"t":"^ud83d^u0041"}'
    New-NvJsonCompatText 'escape a high half, then a line break' '{"t":"^ud83d^n"}'
    New-NvJsonCompatText 'escape a high half at the end' '{"t":"x^ud83d"}'
    New-NvJsonCompatText 'escape an escaped backslash before u' '{"t":"^^ud83d"}'
    # x first: the vector engine's culture-aware -eq '' takes a name of U+FFFD
    # alone for an empty one under 5.1
    New-NvJsonCompatText 'escape a high half in a name' '{"x^ud83d":1}'
    New-NvJsonCompatText 'escape U+FFFD itself' '{"t":"^uFFFD"}'
    New-NvJsonCompatText 'escape every kind' '{"t":"^"^^^/^b^f^n^r^t^u0041^u00e9^u0000"}'

    # names
    New-NvJsonCompatText 'name twice by case' '{"a":1,"A":2}'
    New-NvJsonCompatText 'name twice by case, nested' '{"x":{"a":1,"A":2}}'
    New-NvJsonCompatText 'name twice by case, in a list' '{"x":[{"b":1,"B":2}]}'
    # No pair 5.1 keeps and pwsh 7 folds (micro and MU, any past U+FFFF):
    # 5.1's answer would hold two names pwsh 7's Read-NvJson takes for one,
    # and it refuses the file
    $pairs = [ordered]@{
        'e acute in both cases' = @(0xE9, 0xC9); 'sharp s and SS' = @(0xDF, 'SS'); 'dotless i and I' = @(0x131, 'I')
        'dotted I and i' = @(0x130, 'i'); 'long s and S' = @(0x17F, 'S'); 'kelvin and k' = @(0x212A, 'k')
        'omega in both cases' = @(0x3A9, 0x3C9); 'y diaeresis in both cases' = @(0xFF, 0x178)
        'alpha with iota below and beside' = @(0x1FB3, 0x1FBC); 'Georgian nuskhuri and asomtavruli' = @(0x2D00, 0x10A0)
        'full-width a in both cases' = @(0xFF41, 0xFF21); 'sharp s and capital sharp s' = @(0xDF, 0x1E9E)
        'a ring and angstrom' = @(0xE5, 0x212B); 'apostrophe n and N' = @(0x149, 'N')
    }
    foreach ($k in @($pairs.Keys)) {
        $two = @(foreach ($n in $pairs[$k]) { if ($n -is [string]) { $n } else { [char]::ConvertFromUtf32($n) } })
        New-NvJsonCompatText "name $k" ('{"' + $two[0] + '":1,"' + $two[1] + '":2}')
    }
    New-NvJsonCompatText 'name empty' '{"":1}'
    New-NvJsonCompatText 'name empty, nested' '{"x":{"":1}}'
    New-NvJsonCompatText 'name empty, in a list' '{"x":[{"":1}]}'
    New-NvJsonCompatText 'name twice' '{"a":1,"b":2,"a":3}'
    New-NvJsonCompatText 'name twice, two of them' '{"a":1,"b":2,"c":3,"a":4,"b":5}'
    New-NvJsonCompatText 'name twice, objects' '{"o":{"x":1},"p":0,"o":{"y":2}}'
    New-NvJsonCompatText 'name twice, then by case' '{"a":1,"a":2,"A":3}'
    New-NvJsonCompatText 'name by case, then twice' '{"a":1,"A":2,"a":3}'
    # PSObject's own members. No __type: pwsh 7's answer keeps it, and 5.1's
    # Read-NvJson of this file drops a scalar one and throws on any other
    New-NvJsonCompatText 'name psobject' '{"psobject":1}'
    New-NvJsonCompatText 'name PSBase, nested' '{"x":{"PSBase":1}}'

    # the top level, as return unrolls it
    foreach ($s in '[]', '["x"]', '[1,2]', '[[1]]', '[[]]', '[{}]', '[[1,2]]', '[[[5]]]', '[null]', '[[1],[2]]', '"x"', '1', 'true', '{}') {
        New-NvJsonCompatText "top $s" $s
    }

    # numbers, by value. None past a long, and no whole number from 2^53 up
    # that is not one: pwsh 7 answers those as integers, 5.1 as doubles, and
    # each reads the other's answer back as its own, so the file never settles
    New-NvJsonCompatText 'number integers' '{"a":0,"b":-0,"c":2147483647,"d":2147483648,"e":-2147483649,"f":9007199254740993,"g":9223372036854775807,"h":-9223372036854775808}'
    New-NvJsonCompatText 'number fractions' '{"a":1.5,"b":0.1,"c":-0.0,"d":1.0,"e":100.0,"f":0.30000000000000004,"g":-1.25}'
    New-NvJsonCompatText 'number exponents' '{"a":1e2,"b":1E+2,"c":1.5e-7,"d":1e300,"e":2.5E-5,"f":1e15}'

    # strings a PowerShell reads as a [datetime]
    New-NvJsonCompatText 'date iso' '{"a":"2026-10-15T01:02:03.1Z","b":"2026-10-15T01:02:03+0900","c":"2026-10-15T01:02:03.1234567-05:30","d":"2026-10-15T24:00:00Z","e":"2026-02-30T01:02:03Z","f":"0001-01-01T00:00:00Z","g":"9999-12-31T23:59:59.9999999Z","h":"2026-10-15T01:02:03.000Z","i":"2026-10-15t01:02:03Z","j":"2026-10-15T01:02:03z"}'
    New-NvJsonCompatText 'date iso, more' '{"a":"2026-10-15T01:02:03.1234567","b":"2026-10-15T01:02:03.12","c":"20261015T010203Z","d":"2026-10-15T01:02:03-00:00","e":"2026-10-15T01:02:03+14:00","f":"2026-10-15T01:02:03+15:00","g":"2026-10-15T01:02:60Z","h":"2026-10-15 T01:02:03Z","i":"2026-10-15T1:02:03Z","j":"2026-10-15"}'
    New-NvJsonCompatText 'date fraction digits' '{"a":"2026-10-15T01:02:03.5Z","b":"2026-10-15T01:02:03.1234567+09:00","c":"2026-10-15T01:02:03.12345678Z","d":"2026-10-15T01:02:03.Z","e":"2026-10-15T24:00:00.0Z","f":"2026-10-15T24:00:00.1Z"}'
    New-NvJsonCompatText 'date zone forms' '{"a":"2026-10-15T01:02:03+09","b":"2026-10-15T01:02:03+0930","c":"2026-10-15T01:02:03:30","d":"2026-10-15T01:02:0330","e":"2026-10-15T01:02:03+09:3","f":"2026-10-15T01:02:03+09:00Z","g":"2026-10-15T01:02:03 +09:00","h":"2026-10-15T01:02:03+9:00","i":"2026-10-15T01:02:03-00:30"}'
    New-NvJsonCompatText 'date at the ends of time' '{"a":"0001-01-01T00:00:00+09:00","b":"0001-01-01T10:00:00+09:00","c":"9999-12-31T23:00:00-05:00","d":"9999-12-31T20:00:00+00:00","e":"0001-01-01T00:00:00Z","f":"9999-12-31T23:59:59.9999999-00:30"}'
    New-NvJsonCompatText 'date hour 24 past the end of time' '{"a":"9999-12-31T24:00:00Z"}'
    New-NvJsonCompatText 'date a digit that is not ASCII' ('{"a":"' + [char]0x662 + '026-10-15T01:02:03Z"}')
    New-NvJsonCompatText 'date ms forms' '{"a":"/Date(0)/","b":"/Date(-1)/","c":"/Date(1760490123000+0900)/","d":"/Date(abc)/","e":"^/Date(1760490123000+0900)^/","f":"^/Date(-62135596800000)^/","g":"^/Date(1760490123000)^/x","h":"/Date(1760490123000)/ ","i":"2026-10-15T01:02:03+09","j":"2026-10-15T01:02:03.1234567+09:00:00"}'
    New-NvJsonCompatText 'date ms forms of 5.1' '{"a":"^/Date(1760490123000-0130)^/","b":"^/Date(1760490123000Z)^/","c":"^/Date( 1)^/","d":"^/Date(+1)^/","e":"^/date(1)^/","f":"^/Date(1)^/","g":"^/Date(1760490123000+09)^/","h":"^/Date(-1)^/","i":"^/Date(1760490123000ab)^/","j":"^/Date()^/"}'
    New-NvJsonCompatText 'date ms half escaped' '{"a":"^/Date(1)/","b":"/Date(1)^/","c":"^u002fDate(1)^u002f"}'
    New-NvJsonCompatText 'date ms past the end of time' '{"a":"^/Date(253402300800000)^/"}'
    New-NvJsonCompatText 'date ms that wraps around' '{"a":"^/Date(99999999999999999)^/"}'
    New-NvJsonCompatText 'date ms past a long' '{"a":"^/Date(99999999999999999999)^/","b":"/Date(99999999999999999999)/"}'
    # 19 digits: a long's own length, where a parser's arithmetic may wrap
    New-NvJsonCompatText 'date ms of the least long' '{"a":"^/Date(-9223372036854775808)^/"}'
    New-NvJsonCompatText 'date ms of 19 digits past a long' '{"a":"^/Date(9223372036854775809)^/"}'
    New-NvJsonCompatText 'date ms of 19 digits past a long, negative' '{"a":"^/Date(-9223372036854775809)^/"}'
    New-NvJsonCompatText 'date in a list, never in a name' '{"^/Date(1)^/":["2026-10-15T01:02:03Z","^/Date(2)^/"]}'
    New-NvJsonCompatText 'date at the top' '"2026-10-15T01:02:03Z"'
    # Newtonsoft's Int64TryParse takes 19 digits at most, leading zeros too
    New-NvJsonCompatText 'date ms of 20 digits' '{"a":"^/Date(00000000000000000001)^/"}'
    # the quotes: Newtonsoft reads the text, JavaScriptSerializer the token
    New-NvJsonCompatText 'date iso in single quotes' "{'a':'2026-10-15T01:02:03Z'}"
    New-NvJsonCompatText 'date ms in single quotes' "{'a':'^/Date(1)^/'}"
    New-NvJsonCompatText 'date hour 24 past the end of time, no zone' '{"a":"9999-12-31T24:00:00"}'

    # what both refuse
    New-NvJsonCompatText 'bad text after the object' '{"a":1} x'
    New-NvJsonCompatText 'bad two objects' '{"a":1}{"b":2}'
    New-NvJsonCompatText 'bad escape' '{"a":"^x"}'
    New-NvJsonCompatText 'bad string never closed' '{"a":"x'
    New-NvJsonCompatText 'bad object never closed' '{"a":1'

    # what this PowerShell's own Save-ChatqJson writes
    $mine = Get-NvJsonCompatWritten
    foreach ($k in @($mine.Keys)) { New-NvJsonCompatCase "$($script:NvEdition) wrote $k" 'bytes' $mine[$k] $script:NvEdition }

    # what chatqd's writer writes, read back by both
    New-NvJsonCompatPretty 'chatqd wrote a job' @(
        '{',
        '  "id": "j-1",',
        '  "kind": "prompt",',
        '  "state": "queued",',
        '  "seq": 3,',
        '  "createdAt": "2026-10-15T01:02:03.1234567Z",',
        ('  "prompt": "' + [char]0xD55C + [char]0xAE00 + ' ^"q^" <&> ^^",'),
        '  "chat": {',
        '    "title": "t",',
        '    "session": null',
        '  },',
        '  "tags": [',
        '    "a"',
        '  ],',
        '  "steps": [],',
        '  "meta": {},',
        '  "first": false,',
        '  "cost": 0.25',
        '}')
    New-NvJsonCompatPretty 'chatqd wrote text' @(
        '{',
        ('  "t": "' + [char]0xE9 + [char]0xD55C + [char]0xD83D + [char]0xDE00 + [char]0x2028 + [char]0x85 + [char]0x7F + ' <>&''",'),
        '  "c": "^u0000^b^t^n^f^r^u001f^"^^/"',
        '}')
    New-NvJsonCompatPretty 'chatqd wrote stamps' @(
        '{',
        '  "utc": "2026-10-15T01:02:03.1234567Z",',
        '  "local": "2026-10-15T10:02:03+09:00",',
        '  "west": "2026-10-14T20:02:03-05:00",',
        '  "plain": "2026-10-15T01:02:03",',
        '  "ms": "/Date(1760490123000)/",',
        '  "day": "2026-10-15"',
        '}')
    New-NvJsonCompatPretty 'chatqd wrote numbers' @(
        '{',
        '  "i": 1,',
        '  "neg": -2147483649,',
        '  "big": 9223372036854775807,',
        '  "f": 1.5,',
        '  "one": 1.0,',
        '  "e15": 1000000000000000.0,',
        '  "small": 1e-7,',
        '  "pi": 3.14159,',
        '  "max": 1.7976931348623157e+308,',
        '  "zero": -0.0',
        '}')
    $deep = New-Object System.Collections.Generic.List[string]
    $deep.Add('{')
    for ($i = 9; $i -ge 1; $i--) { $deep.Add((' ' * (2 * (10 - $i))) + '"l' + $i + '": {') }
    $deep.Add((' ' * 20) + '"l0": "leaf"')
    for ($i = 1; $i -le 9; $i++) { $deep.Add((' ' * (2 * (10 - $i))) + '}') }
    $deep.Add('}')
    New-NvJsonCompatPretty 'chatqd wrote ten levels' $deep.ToArray()
    New-NvJsonCompatPretty 'chatqd wrote a list of one' @('[', '  "x"', ']')
    New-NvJsonCompatPretty 'chatqd wrote a list of objects' @('[', '  {', '    "a": 1', '  },', '  {', '    "a": 2', '  }', ']')
    New-NvJsonCompatPretty 'chatqd wrote lists in a list' @('{', '  "a": [', '    [', '      1', '    ],', '    []', '  ]', '}')
    New-NvJsonCompatPretty 'chatqd wrote an empty object' @('{}')
} -Expect {
    param($In, $Name)
    $hex = if (Get-NvHas $In 'bytes') { [string]$In.bytes }
    elseif (Get-NvHas $In 'text') { ConvertTo-NvHex ($script:NvUtf8.GetBytes([string]$In.text)) }
    else { ConvertTo-NvHex ($script:NvUtf8.GetBytes([string]$In.pretty)) }
    $bytes = ConvertFrom-NvHex $hex
    $p = Join-Path (Enter-NvData $Name) 'file.json'
    [IO.File]::WriteAllBytes($p, $bytes)
    $got = Use-NvTimeZone 'Korea Standard Time' { , (ConvertTo-NvJsonCompatValue (Read-ChatqJson $p)) }
    $text = Get-Content -LiteralPath $p -Raw -Encoding UTF8
    [ordered]@{ value = $got; repaired = (Test-NvJsonCompatRepaired $bytes ([string]$text)) }
}
