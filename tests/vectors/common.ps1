# tests/vectors/common.ps1: the contract vectors' engine (native/SPEC.md 6.1).
# Dot-sourced by tests/vectors.ps1 after the tool, then every generator in
# this folder: each registers its vector with Register-NvVector, and
# Invoke-NvVectors makes them all and compares them with native/vectors/,
# or with -Write writes them there.
#
# A vector file is {about, cases}. A case is {name, [by], input, expect}, or,
# where Windows PowerShell 5.1 and pwsh 7 answer differently, {name, [by],
# input, expectByEdition: {Desktop, Core}}. The Rust runners read the same
# files (native/crates/chatq-core/tests/common/mod.rs); nobody edits one.
#
# What a generator keeps to:
# - Its Cases block outputs one [ordered]@{ name; input; [by] } per case and
#   nothing else, in a fixed order. An input is plain data - strings,
#   numbers, booleans, lists, [ordered] dictionaries - small, and the same on
#   both PowerShells. A list in it is @(...) with no comma in front, which
#   would nest it in another; (ConvertTo-NvUnits $s) is already one. A big
#   input (a 1 MB line) is a recipe both sides expand, never the bytes;
#   bytes are hex (ConvertTo-NvHex).
# - The file is ASCII, as tests/vectors.ps1 says: other text is
#   U '\uXXXX', or built from [char]0xXXXX.
# - by = $PSVersionTable.PSEdition marks an input only this PowerShell can
#   make (bytes its own ConvertTo-Json wrote). The other PowerShell answers
#   it from the file. A generator never makes a case by the other one.
# - Its Expect block is param($In, $Name) - never $Input, PowerShell's own -
#   and outputs exactly one value: a list as ,@(...), and no stray output
#   ([void] every .Add). $In is the input as read back from JSON, a
#   [pscustomobject] whichever way it was made; cast its numbers ([int]),
#   which 5.1 reads as Int32 and pwsh 7 as Int64.
# - An answer holds no DateTime: a time is a string ('o', or as the function
#   under test renders it). A string holds no lone surrogate - serde_json
#   refuses one - so such text goes as UTF-16 code units (ConvertTo-NvUnits).
# - Nothing reads this PC's clock, zone or culture: Use-NvTimeZone,
#   Use-NvClock (inside it; Set-NvClock moves it on) and Use-NvCulture set
#   them per case, and Enter-NvData gives a case an empty data/ of its own
#   (the engine leaves it after each case). Anything else a generator
#   changes - a function, a $script: seam - it puts back in a finally.
# - Tool code that reads [DateTime]::Now or [DateTimeOffset]::UtcNow itself
#   cannot be given a clock: such an input is an age the Expect block turns
#   into a time, far from every threshold, and no time goes in the answer.
# - Its own helpers are named *-Nv<Vector>*, and no variable of its own
#   starts with nv: these helpers run its blocks with their nv* locals in
#   scope, and PowerShell's dynamic scoping would let them shadow it.

$script:NvVectors = [ordered]@{}
$script:NvDir = Join-Path (Join-Path $root 'native') 'vectors'
$script:NvScratch = Join-Path $sb 'nv'
$script:NvUtf8 = New-Object System.Text.UTF8Encoding $false
$script:NvEdition = [string]$PSVersionTable.PSEdition
$script:NvOther = if ($script:NvEdition -eq 'Core') { 'Desktop' } else { 'Core' }
# the tool's own data/, which Enter-NvData moves every path away from
$script:NvDataHome = $script:ChatqData
$script:NvSaved = $null
$script:NvClock = $null
$script:NvZone = $null
# native/vectors/ files no generator makes: the engine decision's table,
# written by hand and read by both launchers (tests/sections/native.ps1),
# and the skin loader's, written by hand since no PowerShell loads a skin
# (native/overlay/src/skin.rs runs it)
$script:NvHandMade = @('launch', 'skin-manifest')
$script:NvInv = [System.Globalization.CultureInfo]::InvariantCulture

function Register-NvVector {
    # native/vectors/<Name>.json: what it pins ($About), its cases, and the
    # answer this PowerShell gives for each
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$About,
        [Parameter(Mandatory)][scriptblock]$Cases, [Parameter(Mandatory)][scriptblock]$Expect)
    if ($script:NvVectors.Contains($Name)) { throw "two generators register the vector '$Name'" }
    $script:NvVectors[$Name] = @{ About = $About; Cases = $Cases; Expect = $Expect }
}

# --- canonical JSON ----------------------------------------------------------
function ConvertTo-NvJson {
    # The one JSON text both PowerShells write for a value: object keys in
    # their order ([ordered], [pscustomobject]) or sorted ordinally (any other
    # dictionary, whose order .NET does not fix), numbers in invariant form,
    # every character outside printable ASCII as \uXXXX. -Compress writes no
    # white space, which is how values are compared; else two-space indents,
    # a list or object that fits in 100 columns kept on one line.
    param($Value, [switch]$Compress)
    if ($Compress) { return (Format-NvJson $Value -1) }
    return (Format-NvJson $Value 0)
}

function Format-NvJson($V, [int]$Indent) {
    # $Indent: -1 compact, -2 one line with spaces, else pretty at that indent
    if ($null -eq $V) { return 'null' }
    if ($V -is [string]) { return (Format-NvString $V) }
    if ($V -is [char]) { return (Format-NvString ([string]$V)) }
    if ($V -is [bool]) { if ($V) { return 'true' } else { return 'false' } }
    if ($V -is [enum]) { throw "a $($V.GetType().Name) in a vector: write its name as a string" }
    if ($V -is [int] -or $V -is [long] -or $V -is [byte] -or $V -is [sbyte] -or $V -is [int16] -or $V -is [uint16] -or
        $V -is [uint32] -or $V -is [uint64] -or $V -is [bigint]) { return $V.ToString($script:NvInv) }
    if ($V -is [double] -or $V -is [single] -or $V -is [decimal]) { return (Format-NvNumber $V) }
    if ($V -is [datetime] -or $V -is [datetimeoffset] -or $V -is [timespan]) { throw "a $($V.GetType().Name) in a vector: write it as a string" }
    $keys = New-Object System.Collections.Generic.List[string]
    $vals = New-Object System.Collections.Generic.List[object]
    if ($V -is [System.Collections.IDictionary]) {
        $ks = New-Object System.Collections.Generic.List[string]
        foreach ($k in @($V.Keys)) {
            if ($k -isnot [string]) { throw "a dictionary key of type $($k.GetType().Name) in a vector: keys are strings" }
            $ks.Add($k)
        }
        $karr = $ks.ToArray()
        if ($V -isnot [System.Collections.Specialized.OrderedDictionary]) { [Array]::Sort($karr, [StringComparer]::Ordinal) }
        foreach ($k in $karr) { $keys.Add($k); $vals.Add($V[$k]) }
        return (Format-NvObject $keys $vals $Indent)
    }
    if ($V.GetType().FullName -eq 'System.Management.Automation.PSCustomObject') {
        foreach ($p in $V.PSObject.Properties) { $keys.Add($p.Name); $vals.Add($p.Value) }
        return (Format-NvObject $keys $vals $Indent)
    }
    if ($V -is [System.Collections.IEnumerable]) {
        foreach ($x in $V) { $vals.Add($x) }
        return (Format-NvArray $vals $Indent)
    }
    throw "a $($V.GetType().FullName) in a vector: only strings, numbers, booleans, lists and dictionaries"
}

function Format-NvNumber($V) {
    # one form for every numeric type: integral values as integers (5.1 reads
    # 1.5 back as a decimal, pwsh 7 as a double), the rest as the shortest
    # text that reads back as the same double, pwsh 7's 'R'. 5.1's 'R' can
    # write 17 digits where 16 do, so there it is the first of G15, G16 and
    # G17 that reads back
    $d = [double]$V
    if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { throw 'NaN or infinity in a vector' }
    if ([Math]::Floor($d) -eq $d -and [Math]::Abs($d) -lt 9007199254740992) { return ([long]$d).ToString($script:NvInv) }
    if ($script:NvEdition -eq 'Core') { return $d.ToString('R', $script:NvInv) }
    # TryParse: G15 of a double near MaxValue rounds past it, which Parse
    # refuses there
    $r = 0.0
    foreach ($p in 'G15', 'G16') {
        $s = $d.ToString($p, $script:NvInv)
        if ([double]::TryParse($s, [System.Globalization.NumberStyles]::Float, $script:NvInv, [ref]$r) -and $r -eq $d) { return $s }
    }
    return $d.ToString('G17', $script:NvInv)
}

function Format-NvString([string]$S) {
    if ($S -cmatch '^[\x20\x21\x23-\x5B\x5D-\x7E]*\z') { return '"' + $S + '"' }
    $b = New-Object System.Text.StringBuilder ($S.Length + 16)
    [void]$b.Append('"')
    for ($i = 0; $i -lt $S.Length; $i++) {
        $c = [int]$S[$i]
        if ($c -eq 0x22) { [void]$b.Append('\"') }
        elseif ($c -eq 0x5C) { [void]$b.Append('\\') }
        elseif ($c -eq 0x0A) { [void]$b.Append('\n') }
        elseif ($c -eq 0x0D) { [void]$b.Append('\r') }
        elseif ($c -eq 0x09) { [void]$b.Append('\t') }
        elseif ($c -ge 0x20 -and $c -lt 0x7F) { [void]$b.Append($S[$i]) }
        else {
            if ($c -ge 0xD800 -and $c -le 0xDBFF) {
                if ($i + 1 -ge $S.Length -or [int]$S[$i + 1] -lt 0xDC00 -or [int]$S[$i + 1] -gt 0xDFFF) { throw 'a lone surrogate in a vector string: give that text as UTF-16 code units (ConvertTo-NvUnits)' }
            }
            elseif ($c -ge 0xDC00 -and $c -le 0xDFFF) {
                if ($i -eq 0 -or [int]$S[$i - 1] -lt 0xD800 -or [int]$S[$i - 1] -gt 0xDBFF) { throw 'a lone surrogate in a vector string: give that text as UTF-16 code units (ConvertTo-NvUnits)' }
            }
            [void]$b.Append('\u').Append($c.ToString('x4'))
        }
    }
    [void]$b.Append('"')
    return $b.ToString()
}

function Format-NvObject($Keys, $Vals, [int]$Indent) {
    if ($Keys.Count -eq 0) { return '{}' }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($k in $Keys) {
        # 5.1's ConvertFrom-Json throws on both. Length, not -eq '': that
        # compare is culture-aware, so a name of ignorable characters equals ''
        if ($k.Length -eq 0) { throw 'an empty key in a vector' }
        if (-not $seen.Add($k)) { throw "two keys '$k' differing only by case in a vector" }
    }
    if ($Indent -eq -1) {
        $parts = for ($i = 0; $i -lt $Keys.Count; $i++) { (Format-NvString $Keys[$i]) + ':' + (Format-NvJson $Vals[$i] -1) }
        return '{' + (@($parts) -join ',') + '}'
    }
    $one = '{' + (@(for ($i = 0; $i -lt $Keys.Count; $i++) { (Format-NvString $Keys[$i]) + ': ' + (Format-NvJson $Vals[$i] -2) }) -join ', ') + '}'
    if ($Indent -eq -2 -or ($Indent + $one.Length -le 100)) { return $one }
    $pad = ' ' * ($Indent + 2)
    $parts = for ($i = 0; $i -lt $Keys.Count; $i++) { $pad + (Format-NvString $Keys[$i]) + ': ' + (Format-NvJson $Vals[$i] ($Indent + 2)) }
    return "{`n" + (@($parts) -join ",`n") + "`n" + (' ' * $Indent) + '}'
}

function Format-NvArray($Vals, [int]$Indent) {
    if ($Vals.Count -eq 0) { return '[]' }
    if ($Indent -eq -1) { return '[' + (@(foreach ($x in $Vals) { Format-NvJson $x -1 }) -join ',') + ']' }
    if ($Indent -eq -2 -or $Vals.Count -le 64) {
        $one = '[' + (@(foreach ($x in $Vals) { Format-NvJson $x -2 }) -join ', ') + ']'
        if ($Indent -eq -2 -or ($Indent + $one.Length -le 100)) { return $one }
    }
    $pad = ' ' * ($Indent + 2)
    $parts = foreach ($x in $Vals) { $pad + (Format-NvJson $x ($Indent + 2)) }
    return "[`n" + (@($parts) -join ",`n") + "`n" + (' ' * $Indent) + ']'
}

function Read-NvJson([string]$Text) {
    # JSON as [pscustomobject]s and arrays on both PowerShells. pwsh 7's
    # ConvertFrom-Json would turn ISO strings into dates, so it reads with
    # System.Text.Json; 5.1's turns only "\/Date(..)\/" into one, which
    # ConvertTo-NvJson never writes ("/" is not escaped).
    if ($script:NvEdition -eq 'Core') {
        $o = New-Object System.Text.Json.JsonDocumentOptions
        $o.MaxDepth = 256
        $d = [System.Text.Json.JsonDocument]::Parse($Text, $o)
        try { return , (ConvertFrom-NvElement $d.RootElement) } finally { $d.Dispose() }
    }
    return , ($Text | ConvertFrom-Json)
}

function ConvertFrom-NvElement($E) {
    switch ([string]$E.ValueKind) {
        'Object' {
            $o = [ordered]@{}
            foreach ($p in $E.EnumerateObject()) {
                if ($o.Contains($p.Name)) { throw "two keys '$($p.Name)' differing only by case" }
                $o[$p.Name] = ConvertFrom-NvElement $p.Value
            }
            return [pscustomobject]$o
        }
        'Array' {
            $a = New-Object System.Collections.Generic.List[object]
            foreach ($x in $E.EnumerateArray()) { $a.Add((ConvertFrom-NvElement $x)) }
            return , $a.ToArray()
        }
        'String' { return $E.GetString() }
        'Number' {
            $l = 0L
            if ($E.TryGetInt64([ref]$l)) { return $l }
            return $E.GetDouble()
        }
        'True' { return $true }
        'False' { return $false }
        default { return $null }
    }
}

# --- bytes and code units ----------------------------------------------------
function ConvertTo-NvHex([byte[]]$Bytes) {
    # lowercase hex, as the Rust runners' common::hex reads it. Not -not
    # $Bytes: that reads a one-byte array as its byte, so 0x00 would be ''
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return '' }
    return (-join @($Bytes | ForEach-Object { $_.ToString('x2') }))
}

function ConvertFrom-NvHex([string]$Hex) {
    $n = $Hex.Length / 2
    $b = New-Object byte[] $n
    for ($i = 0; $i -lt $n; $i++) { $b[$i] = [Convert]::ToByte($Hex.Substring($i * 2, 2), 16) }
    return , $b
}

function ConvertTo-NvUnits([string]$S) {
    # a .NET string as its UTF-16 code units, lone surrogates and all
    return , @(foreach ($c in $S.ToCharArray()) { [int]$c })
}

function ConvertFrom-NvUnits($Units) {
    return (-join @(foreach ($u in @($Units)) { [char][int]$u }))
}

# --- culture, zone, clock, data/ ---------------------------------------------
function Use-NvCulture([string]$nvCultureName, [scriptblock]$nvBlock) {
    # $nvBlock with $nvCultureName the thread's culture, without this PC's
    # overrides, as a watcher started in that culture formats; tool code's
    # Get-Culture follows it (tests/vectors.ps1)
    $nvThread = [System.Threading.Thread]::CurrentThread
    $nvWasCulture = $nvThread.CurrentCulture
    $nvThread.CurrentCulture = New-Object System.Globalization.CultureInfo($nvCultureName, $false)
    try { & $nvBlock } finally { $nvThread.CurrentCulture = $nvWasCulture }
}

function Use-NvTimeZone([string]$nvZoneId, [scriptblock]$nvBlock) {
    # $nvBlock with this process's local zone $nvZoneId (a Windows id): every
    # ToLocalTime, ToUniversalTime, Parse and 'o' in it, and Get-Date's now.
    # Only TimeZoneInfo's cache is pointed at it, never tzutil: this PC's own
    # zone is left alone. DateTime.Now itself still asks Windows, so tool code
    # that calls [DateTime]::Now is not a vector's to pin.
    if ($script:NvZone) { throw 'Use-NvTimeZone does not nest' }
    $nvTz = [System.TimeZoneInfo]::FindSystemTimeZoneById($nvZoneId)
    # pwsh 7 answers 'UTC' with TimeZoneInfo.Utc itself, and a local zone
    # that is that object keeps ToUniversalTime's Kind Local, so 'o' ends
    # +00:00. A real UTC PC's local zone is a zone of its own, as this copy is
    if ([object]::ReferenceEquals($nvTz, [System.TimeZoneInfo]::Utc)) {
        $nvTz = [System.TimeZoneInfo]::CreateCustomTimeZone($nvTz.Id, $nvTz.BaseUtcOffset, $nvTz.DisplayName, $nvTz.StandardName)
    }
    Set-NvLocalZone $nvTz
    $script:NvZone = $nvTz
    try { & $nvBlock }
    finally {
        $script:NvZone = $null
        [System.TimeZoneInfo]::ClearCachedData()
    }
}

function Set-NvLocalZone($Tz) {
    # .NET Framework names the field m_localTimeZone, .NET _localTimeZone
    [System.TimeZoneInfo]::ClearCachedData()
    $bf = [System.Reflection.BindingFlags]'NonPublic, Static'
    $f = [System.TimeZoneInfo].GetField('s_cachedData', $bf)
    $cd = if ($f) { $f.GetValue($null) } else { $null }
    $lf = $null
    if ($cd) {
        foreach ($n in '_localTimeZone', 'm_localTimeZone') {
            if (-not $lf) { $lf = $cd.GetType().GetField($n, [System.Reflection.BindingFlags]'NonPublic, Instance') }
        }
    }
    if (-not $lf) { throw 'this .NET keeps its local zone where Use-NvTimeZone cannot reach it' }
    $lf.SetValue($cd, $Tz)
    if ([System.TimeZoneInfo]::Local.Id -ne $Tz.Id) { throw "the local zone is still $([System.TimeZoneInfo]::Local.Id), not $($Tz.Id)" }
}

function Use-NvClock([string]$nvAt, [scriptblock]$nvBlock) {
    # $nvBlock with tool code's Get-Date (tests/vectors.ps1) answering the
    # instant $nvAt - a stamp with Z or an offset - as local time: inside
    # Use-NvTimeZone, that zone's
    if ($nvAt -notmatch '(Z|[+-]\d\d:\d\d)$') { throw "Use-NvClock takes a stamp with Z or an offset, not '$nvAt'" }
    $nvWasClock = $script:NvClock
    $script:NvClock = [datetime]::Parse($nvAt, $script:NvInv, [System.Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()
    try { & $nvBlock } finally { $script:NvClock = $nvWasClock }
}

function Set-NvClock([string]$At) {
    # inside Use-NvClock: Get-Date answers $At from here on, until that block
    # ends - a scripted pass sequence moves the clock this way
    if ($null -eq $script:NvClock) { throw 'Set-NvClock works inside Use-NvClock' }
    if ($At -notmatch '(Z|[+-]\d\d:\d\d)$') { throw "Set-NvClock takes a stamp with Z or an offset, not '$At'" }
    $script:NvClock = [datetime]::Parse($At, $script:NvInv, [System.Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()
}

function Enter-NvData([string]$nvCase) {
    # an empty data/ for one case: every $script: path under the tool's
    # data/ points into it until Exit-NvData, which the engine calls after
    # each case. Returns its path.
    if ($null -ne $script:NvSaved) { throw 'Enter-NvData does not nest' }
    $nvNew = Join-Path $script:NvScratch ($nvCase -replace '[^A-Za-z0-9._-]', '_')
    if (Test-Path -LiteralPath $nvNew) { Remove-Item -LiteralPath $nvNew -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $nvNew -Force
    $nvOld = $script:NvDataHome
    $nvSep = [IO.Path]::DirectorySeparatorChar
    $script:NvSaved = @{}
    foreach ($nvVar in @(Get-Variable -Scope Script)) {
        $nvS = $nvVar.Value
        if ($nvVar.Name -like 'Nv*' -or $nvS -isnot [string]) { continue }
        if ($nvS -eq $nvOld -or $nvS.StartsWith($nvOld + $nvSep, [StringComparison]::OrdinalIgnoreCase)) {
            $script:NvSaved[$nvVar.Name] = $nvS
            Set-Variable -Scope Script -Name $nvVar.Name -Value ($nvNew + $nvS.Substring($nvOld.Length))
        }
    }
    return $nvNew
}

function Exit-NvData {
    if ($null -eq $script:NvSaved) { return }
    foreach ($k in @($script:NvSaved.Keys)) { Set-Variable -Scope Script -Name $k -Value $script:NvSaved[$k] }
    $script:NvSaved = $null
}

# --- the engine --------------------------------------------------------------
function Get-NvError($E) {
    $at = $E.InvocationInfo
    $where = if ($at -and $at.ScriptName) { " ($(Split-Path $at.ScriptName -Leaf):$($at.ScriptLineNumber))" } else { '' }
    return "$($E.Exception.Message)$where"
}

function Get-NvShort([string]$S) {
    if ($S.Length -le 240) { return $S }
    return $S.Substring(0, 240) + "... ($($S.Length) chars)"
}

function Get-NvCases($nvCasesBlock) {
    # the generator's cases, checked, each input as read back from JSON
    $nvList = New-Object System.Collections.Generic.List[object]
    $nvSeen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($nvC in @(& $nvCasesBlock)) {
        if ($nvC -isnot [System.Collections.IDictionary] -or -not $nvC.Contains('name') -or -not $nvC.Contains('input')) {
            throw "its Cases output $(if ($null -eq $nvC) { 'null' } else { "a $($nvC.GetType().Name)" }) where a case goes: each is [ordered]@{ name; input; [by] }, and nothing else is output"
        }
        $nvN = [string]$nvC['name']
        if (-not $nvN) { throw 'a case with no name' }
        if (-not $nvSeen.Add($nvN)) { throw "two cases named '$nvN'" }
        $nvBy = if ($nvC.Contains('by') -and $nvC['by']) { [string]$nvC['by'] } else { $null }
        if ($nvBy -and $nvBy -cne $script:NvEdition) { throw "case '$nvN' is by $nvBy, made under $($script:NvEdition): a generator makes only its own PowerShell's inputs" }
        $nvT = ConvertTo-NvJson $nvC['input'] -Compress
        $nvIn = (Read-NvJson ('{"v":' + $nvT + '}')).v
        if ((ConvertTo-NvJson $nvIn -Compress) -cne $nvT) { throw "case '$nvN': its input reads back from JSON as something else" }
        $nvList.Add([pscustomobject]@{ Name = $nvN; By = $nvBy; InText = $nvT; In = $nvIn })
    }
    if ($nvList.Count -eq 0) { throw 'its Cases made no case' }
    return , $nvList
}

function Get-NvAnswer($nvExpect, $nvIn, [string]$nvName) {
    $nvOut = @(& $nvExpect $nvIn $nvName)
    if ($nvOut.Count -gt 1) { throw "its answer is $($nvOut.Count) values, not one: a list goes as ,@(...), and stray output is [void]ed" }
    if ($nvOut.Count -eq 0) { return $null }
    return , $nvOut[0]
}

function Get-NvHas($Obj, [string]$Key) {
    # does a case read from the file carry $Key (whose value may be null)?
    return ($null -ne $Obj -and $null -ne $Obj.PSObject.Properties[$Key])
}

function Get-NvEditionAnswer($Case, [string]$Edition) {
    # @{ Has; Value }: a case's answer for one PowerShell, from the file
    if (Get-NvHas $Case 'expect') { return @{ Has = $true; Value = $Case.expect } }
    if ((Get-NvHas $Case 'expectByEdition') -and (Get-NvHas $Case.expectByEdition $Edition)) { return @{ Has = $true; Value = $Case.expectByEdition.$Edition } }
    return @{ Has = $false; Value = $null }
}

function Merge-NvCase([string]$Name, $By, $In, $Answer, $Prev, [bool]$Kept) {
    # a case as -Write writes it: this PowerShell's answer, with the other's
    # from the file where the input is unchanged ($Kept), one expect where
    # the two agree
    $c = [ordered]@{ name = $Name }
    if ($By) { $c['by'] = $By }
    $c['input'] = $In
    $o = if ($Kept) { Get-NvEditionAnswer $Prev $script:NvOther } else { @{ Has = $false } }
    if ($o.Has -and (ConvertTo-NvJson $o.Value -Compress) -ceq (ConvertTo-NvJson $Answer -Compress)) { $c['expect'] = $Answer }
    else {
        $by = [ordered]@{}
        foreach ($ed in 'Desktop', 'Core') {
            if ($ed -eq $script:NvEdition) { $by[$ed] = $Answer }
            elseif ($o.Has) { $by[$ed] = $o.Value }
        }
        $c['expectByEdition'] = $by
    }
    return $c
}

function Compare-NvCases($Old, $All) {
    # why the file is not what -Write would write, case by case
    $out = New-Object System.Collections.Generic.List[string]
    $ed = $script:NvEdition
    $names = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($m in $All) {
        $n = $m['name']
        [void]$names.Add($n)
        if (-not $Old.Contains($n)) { $out.Add("'$n': not in the file"); continue }
        $p = $Old[$n]
        if ((ConvertTo-NvJson $p.input -Compress) -cne (ConvertTo-NvJson $m['input'] -Compress)) { $out.Add("'$n': its input changed"); continue }
        $mine = if ($m.Contains('expect')) { $m['expect'] } else { $m['expectByEdition'][$ed] }
        $theirs = Get-NvEditionAnswer $p $ed
        $mt = ConvertTo-NvJson $mine -Compress
        if (-not $theirs.Has) { $out.Add("'$n': the file has no $ed answer"); continue }
        $tt = ConvertTo-NvJson $theirs.Value -Compress
        if ($mt -cne $tt) { $out.Add("'$n': $ed answers $(Get-NvShort $mt), the file says $(Get-NvShort $tt)"); continue }
        if ((ConvertTo-NvJson $p -Compress) -cne (ConvertTo-NvJson $m -Compress)) { $out.Add("'$n': not merged as -Write merges it") }
    }
    foreach ($n in @($Old.Keys)) { if (-not $names.Contains($n)) { $out.Add("'$n': in the file, but no case makes it any more") } }
    return , $out
}

function Invoke-NvVector([string]$Name, [switch]$Write) {
    # one file: made, then compared or written. Its result for the report.
    $v = $script:NvVectors[$Name]
    $path = Join-Path $script:NvDir "$Name.json"
    $problems = New-Object System.Collections.Generic.List[string]
    $notes = New-Object System.Collections.Generic.List[string]
    $all = New-Object System.Collections.Generic.List[object]
    $ed = $script:NvEdition
    $other = $script:NvOther
    $oldText = $null
    $old = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
    try {
        if (Test-Path -LiteralPath $path) {
            $oldText = ([IO.File]::ReadAllText($path, $script:NvUtf8)) -replace "`r`n", "`n"
            foreach ($c in @((Read-NvJson $oldText).cases)) {
                $n = [string]$c.name
                if ($old.Contains($n)) { $problems.Add("the file has two cases named '$n'") } else { $old.Add($n, $c) }
            }
        }
        $fresh = Get-NvCases $v.Cases
        $shared = New-Object System.Collections.Generic.List[object]
        $own = New-Object System.Collections.Generic.List[object]
        $theirs = New-Object System.Collections.Generic.List[object]
        foreach ($c in $fresh) {
            try {
                $prev = if ($old.Contains($c.Name)) { $old[$c.Name] } else { $null }
                if ($prev -and [string]$prev.by -cne [string]$c.By) { $prev = $null }
                $kept = $null -ne $prev -and (ConvertTo-NvJson $prev.input -Compress) -ceq $c.InText
                $ans = Get-NvAnswer $v.Expect $c.In $c.Name
                $m = Merge-NvCase $c.Name $c.By $c.In $ans $prev $kept
                if ($c.By) { $own.Add($m) } else { $shared.Add($m) }
            }
            catch { $problems.Add("'$($c.Name)': $(Get-NvError $_)") }
            finally { Exit-NvData }
        }
        # the other PowerShell's own inputs, answered here from the file
        foreach ($n in @($old.Keys)) {
            $prev = $old[$n]
            if ([string]$prev.by -cne $other) { continue }
            try {
                $ans = Get-NvAnswer $v.Expect $prev.input $n
                $theirs.Add((Merge-NvCase $n $other $prev.input $ans $prev $true))
            }
            catch { $problems.Add("'$n': $(Get-NvError $_)") }
            finally { Exit-NvData }
        }
        # shared cases, then 5.1's own inputs, then pwsh 7's: the same order
        # whichever PowerShell writes
        foreach ($m in $shared) { $all.Add($m) }
        $desk, $core = if ($ed -eq 'Desktop') { $own, $theirs } else { $theirs, $own }
        foreach ($m in $desk) { $all.Add($m) }
        foreach ($m in $core) { $all.Add($m) }
        $missing = @($all | Where-Object { $_.Contains('expectByEdition') -and -not $_['expectByEdition'].Contains($other) }).Count
        if ($missing) {
            $say = "$missing of $($all.Count) cases have no $other answer yet: run tests/vectors.ps1 -Write$(if ($Name) { " -Only $Name" }) under $(if ($other -eq 'Core') { 'pwsh 7' } else { 'Windows PowerShell 5.1' })"
            if ($Write) { $notes.Add($say) } else { $problems.Add($say) }
        }
        $newText = (ConvertTo-NvJson ([ordered]@{ about = $v.About; cases = $all.ToArray() })) + "`n"
        if ($Write) {
            if (-not $problems.Count -and $newText -cne $oldText) {
                $null = New-Item -ItemType Directory -Path $script:NvDir -Force
                [IO.File]::WriteAllText($path, $newText, $script:NvUtf8)
                $notes.Add('written')
            }
        }
        elseif ($null -eq $oldText) { $problems.Add("no native/vectors/$Name.json: run tests/vectors.ps1 -Write -Only $Name under both PowerShells") }
        elseif ($newText -cne $oldText) {
            $why = Compare-NvCases $old $all
            foreach ($w in @($why | Select-Object -First 20)) { $problems.Add($w) }
            if ($why.Count -gt 20) { $problems.Add("and $($why.Count - 20) more") }
            if (-not $why.Count -and -not $missing) { $problems.Add('the file is not laid out as -Write writes it (order, about or format)') }
        }
    }
    catch { $problems.Add((Get-NvError $_)) }
    finally { Exit-NvData }
    return [ordered]@{ name = $Name; ok = ($problems.Count -eq 0); cases = $all.Count; problems = $problems.ToArray(); notes = $notes.ToArray() }
}

function Invoke-NvVectors {
    # every registered vector, or the -Only ones: made, then compared with
    # its file, or with -Write written. Returns how many failed.
    param([switch]$Write, [string[]]$Only, [string]$Report)
    $files = New-Object System.Collections.Generic.List[object]
    $names = @($script:NvVectors.Keys)
    foreach ($o in @($Only)) { if ($o -and $names -notcontains $o) { $files.Add([ordered]@{ name = $o; ok = $false; cases = 0; problems = @("no generator registers '$o'"); notes = @() }) } }
    foreach ($name in $names) {
        if ($Only -and $Only -notcontains $name) { continue }
        $r = Invoke-NvVector $name -Write:$Write
        $files.Add($r)
        $what = if ($Write) { if ($r.notes -contains 'written') { 'wrote' } else { 'same ' } } else { 'ok   ' }
        if ($r.ok) { Write-Host "  $what $name ($($r.cases) cases)" -ForegroundColor Green }
        else { Write-Host "  FAIL  $name  $($r.problems -join '; ')" -ForegroundColor Red }
        foreach ($nt in @($r.notes | Where-Object { $_ -ne 'written' })) { Write-Host "  note  $name  $nt" -ForegroundColor Yellow }
    }
    if (-not $Only) {
        foreach ($f in @(Get-ChildItem -LiteralPath $script:NvDir -Filter '*.json' -EA SilentlyContinue)) {
            $n = [IO.Path]::GetFileNameWithoutExtension($f.Name)
            if ($names -notcontains $n -and $script:NvHandMade -notcontains $n) {
                $files.Add([ordered]@{ name = $n; ok = $false; cases = 0; problems = @("no generator makes native/vectors/$($f.Name)"); notes = @() })
                Write-Host "  FAIL  $n  no generator makes it" -ForegroundColor Red
            }
        }
    }
    if ($Report) {
        $rep = [ordered]@{ edition = $script:NvEdition; write = [bool]$Write; files = $files.ToArray() }
        [IO.File]::WriteAllText($Report, (ConvertTo-NvJson $rep), $script:NvUtf8)
    }
    return @($files | Where-Object { -not $_.ok }).Count
}
