# tests/vectors/idle.ps1: native/vectors/idle.json - Get-ChatqIdleSeconds
# (src/alerts.ps1) on macOS: the seconds since the last keyboard or mouse
# input, from what `ioreg -c IOHIDSystem` prints - the first line naming
# HIDIdleTime, in any case, and in it the first '=' with digits after it,
# nanoseconds - or $null. Rust: native/crates/chatq-core/tests/idle_vectors.rs.
#
# A case is ioreg's output. ioreg is a function here, defined in the Expect
# block so it goes with it, that prints that text a line at a time as
# PowerShell reads a program's output (split at CR LF, CR or LF, no empty
# line after a last break), the macOS switch on, the Windows one off and the
# idle seam cleared for the call. The answer is the double's IEEE-754 bits
# as 16 hex digits - the two PowerShells write some doubles' digits
# differently, and 5.1 reads such digits back as a decimal - or null. The
# Windows path is not here: GetLastInputInfo reads this PC's own input.

function New-NvIdleCase([string]$Name, [string]$Out) {
    return [ordered]@{ name = $Name; input = [ordered]@{ out = $Out } }
}

Register-NvVector -Name 'idle' -About 'Get-ChatqIdleSeconds (src/alerts.ps1) on macOS: ioreg -c IOHIDSystem''s output, read as PowerShell reads a program''s lines; the first line that -match ''HIDIdleTime'' (any case, under en-US), and in it the first =\s*(\d+), [double] of the digits / 1e9; null when there is no such line or number, or [double] cannot read the digits. The answer is the double''s IEEE-754 bits as 16 hex digits, or null. Rust: idle::idle_seconds' -Cases {
    $nl = "`n"
    $block = @(
        '+-o Root  <class IORegistryEntry, id 0x100000100, retain 25>',
        '  +-o IOResources  <class IOResources, id 0x100000110, registered, matched, active, busy 0 (0 ms), retain 40>',
        '    +-o IOHIDSystem  <class IOHIDSystem, id 0x100000483, registered, matched, active, busy 0 (0 ms), retain 19>',
        '        {',
        '          "IOClass" = "IOHIDSystem"',
        '          "HIDParameters" = {"HIDClickTime"=500000000,"HIDKeyRepeat"=83333333,"HIDClickSpace"={"x"=4,"y"=4}}',
        '          "HIDIdleTime" = 4723458000',
        '          "IOProviderClass" = "IOResources"',
        '        }',
        '        ')
    New-NvIdleCase 'typical' (($block -join $nl) + $nl)
    New-NvIdleCase 'typical-crlf' (($block -join "`r`n") + "`r`n")
    New-NvIdleCase 'typical-cr' ($block -join "`r")
    New-NvIdleCase 'missing' ((@($block | Where-Object { $_ -notmatch 'HIDIdleTime' }) -join $nl) + $nl)
    New-NvIdleCase 'empty' ''
    New-NvIdleCase 'only-line-breaks' "`n`r`n`r"
    New-NvIdleCase 'several' ('"HIDIdleTime" = 1000000000' + $nl + '"HIDIdleTime" = 2000000000' + $nl)
    # the first line naming it, even with no number: the next is not tried
    New-NvIdleCase 'first-line-has-no-number' ('"HIDIdleTimeUnits" = "ns"' + $nl + '"HIDIdleTime" = 5000000000' + $nl)
    # the first '=' with digits after it, wherever it is in the line
    New-NvIdleCase 'in-a-dictionary' ('"HIDParameters" = {"HIDIdleTime"=1000000000,"HIDClickTime"=500000000}' + $nl + '"HIDIdleTime" = 7000000000')
    New-NvIdleCase 'second-equals' '"HIDIdleTime" = abc = 2500000000'
    New-NvIdleCase 'equals-no-digits' '"HIDIdleTime" = abc'
    New-NvIdleCase 'no-equals' '"HIDIdleTime" 5000000000'
    New-NvIdleCase 'no-space' '"HIDIdleTime"=2500000000'
    New-NvIdleCase 'zero' '"HIDIdleTime" = 0'
    New-NvIdleCase 'one' '"HIDIdleTime" = 1'
    New-NvIdleCase 'leading-zeros' '"HIDIdleTime" = 0000002500000000'
    New-NvIdleCase 'negative' '"HIDIdleTime" = -5000000000'
    New-NvIdleCase 'fraction' '"HIDIdleTime" = 1.5'
    New-NvIdleCase 'lower-case' 'hididletime = 1500000000'
    New-NvIdleCase 'upper-case' 'HIDIDLETIME = 3000000000'
    # -match under en-US: I with a dot above is i, a dotless i is not
    New-NvIdleCase 'dotted-capital-i' ('H' + [char]0x0130 + 'DIdleTime = 5000000000')
    New-NvIdleCase 'dotless-i' ('H' + [char]0x0131 + 'DIdleTime = 5000000000' + $nl + 'HIDIdleTime = 6000000000')
    New-NvIdleCase 'line-split-at-cr' ('"HIDIdleTime"' + "`r" + '= 3000000000')
    New-NvIdleCase 'line-split-at-crlf' ('x = 1' + "`r`n" + '"HIDIdleTime" = 2000000000' + "`r" + '"HIDIdleTime" = 3000000000' + $nl)
    New-NvIdleCase 'tab-and-wide-space' ('"HIDIdleTime" =' + "`t" + [char]0x3000 + [char]0x00A0 + '2500000000')
    New-NvIdleCase 'zero-width-space' ('"HIDIdleTime" =' + [char]0x200B + '2500000000')
    # \d takes any decimal digit, [double] only 0-9; a digit past the BMP is
    # two UTF-16 surrogates to .NET, which \d does not take
    New-NvIdleCase 'arabic-digits' ('"HIDIdleTime" = ' + [char]0x0661 + [char]0x0662)
    New-NvIdleCase 'digits-then-arabic' ('"HIDIdleTime" = 25' + [char]0x0661)
    New-NvIdleCase 'fullwidth-digit' ('"HIDIdleTime" = ' + [char]0xFF15)
    New-NvIdleCase 'digits-then-adlam' ('"HIDIdleTime" = 2500000000' + [char]::ConvertFromUtf32(0x1E950))
    New-NvIdleCase 'adlam-digit' ('"HIDIdleTime" = ' + [char]::ConvertFromUtf32(0x1E951))
    # past 2^53 and 2^64; a number no double holds: 5.1 cannot read it,
    # pwsh 7 reads infinity
    New-NvIdleCase 'past-2-53' '"HIDIdleTime" = 9007199254740993'
    New-NvIdleCase 'u64-max' '"HIDIdleTime" = 18446744073709551615'
    New-NvIdleCase 'twenty-nines' '"HIDIdleTime" = 99999999999999999999'
    New-NvIdleCase 'thirty-digits' '"HIDIdleTime" = 123456789012345678901234567890'
    New-NvIdleCase 'past-a-double' ('"HIDIdleTime" = 1' + ('0' * 400))
} -Expect {
    param($In, $Name)
    $ioregLines = New-Object System.Collections.Generic.List[string]
    $ioregReader = New-Object System.IO.StringReader ([string]$In.out)
    while ($null -ne ($ioregLine = $ioregReader.ReadLine())) { $ioregLines.Add($ioregLine) }
    $ioregCalls = New-Object System.Collections.Generic.List[string]
    # found by Get-ChatqIdleSeconds' & ioreg up the scopes it is called from
    function ioreg { $ioregCalls.Add(($args -join ' ')); foreach ($ioregOut in $ioregLines) { $ioregOut } }
    $idleWas = @{ Windows = $script:ChatqIsWindows; Mac = $script:ChatIsMac; Seam = $script:ChatqIdleSeam }
    try {
        $script:ChatqIsWindows = $false
        $script:ChatIsMac = $true
        $script:ChatqIdleSeam = $null
        $idleSeconds = Use-NvCulture 'en-US' { Get-ChatqIdleSeconds }
    }
    finally {
        $script:ChatqIsWindows = $idleWas.Windows
        $script:ChatIsMac = $idleWas.Mac
        $script:ChatqIdleSeam = $idleWas.Seam
    }
    if ($ioregCalls.Count -ne 1 -or $ioregCalls[0] -cne '-c IOHIDSystem') { throw "ioreg was called $($ioregCalls.Count) times: $($ioregCalls -join '; ')" }
    if ($null -eq $idleSeconds) { return $null }
    if ($idleSeconds -isnot [double]) { throw "Get-ChatqIdleSeconds gave a $($idleSeconds.GetType().Name)" }
    return ('{0:x16}' -f [BitConverter]::DoubleToInt64Bits($idleSeconds))
}
