# tests/vectors/culture.ps1: native/vectors/culture.json (native/SPEC.md
# 2.11). The --culture argument the launcher gives chatqd, and what PowerShell
# renders in each culture with the data it carries. chatqd learns a culture
# only from that argument, so its runner (crates/chatq-core/tests/
# culture_vectors.rs) renders every case from the launch case's argument.

function Get-NvCultureArg {
    # the value after --culture in the native launch the real
    # Get-ChatqWatcherLaunch builds in this thread's culture; it starts nothing
    $a = @((Get-ChatqWatcherLaunch -Path 'chatq.ps1' -Native 'chatqd').Args)
    $k = [array]::IndexOf($a, '--culture')
    if ($k -lt 0 -or $k + 1 -ge $a.Count) { throw 'the native launch has no --culture' }
    return [string]$a[$k + 1]
}

Register-NvVector -Name 'culture' -About ("SPEC 2.11 in en-US, ko-KR, de-DE, fi-FI, hi-IN and tr-TR, and nl-NL, " +
    "whose IJ at a word's start only pwsh 7 title-cases as one letter. launch: the --culture " +
    "argument Get-ChatqWatcherLaunch -Native builds (src/watcher.ps1), and the CurrentCulture fields it must carry. clock: " +
    "DateTime.ToString('HH:mm') and ('HH:mm:ss'). N0: '{0:N0}' -f an Int32, as Write-ChatqBoard counts a prompt's chars " +
    "(src/alerts.ps1); the last is the largest a .NET string's Length can be. lanes: Format-ChatqLane and " +
    "Format-ChatqProvider (src/watcher.ps1), TextInfo.ToTitleCase on the part before the first |.") -Cases {
    $times = @('00:00:00', '12:00:00', '09:05:07', '23:59:59', '12:34:56.9999999')
    $counts = @(0, 7, 999, 1000, 12345, 100000, 1234567, 1234567890, [int]::MaxValue)
    $lanes = @(
        # the lanes there are: a provider, and the account's folder after |
        'claude', 'codex', 'claude|C:\x\.claude-work', 'codex|~/w', '', ('codex|C:\Users\J' + [char]0xFC + 'rgen\.codex'),
        # the split: the first | only, and an empty part either side
        'claude|', '|C:\h', '|', 'codex|a|b', ' ',
        # ToTitleCase: a word all capitals stays so, any lower case letter lowers the rest
        'CLAUDE', 'CODEX|C:\x', 'cLaUdE', 'Claude', 'claudE',
        # what ends a word, and what does not
        'claude code', 'claude-code', 'claude_code', 'claude.code', 'claude/code', "claude`tcode",
        'a!b"c#d$e%f&g(h)i*j+k,l-m.n/o:p;q<r=s>t?u@v[w\x]y^z_a`b{c}d~e', 'x2y', '2x', 'a1B2',
        # after an apostrophe the word goes on in lower case
        "o'NEIL", "'quoted'",
        # tr-TR's dotted and dotless i
        'icloud', 'gemINI', 'GEMINI', 'Ii', 'iI', 'IBM-ibm',
        # nl-NL's IJ, where a word starts
        'ijssel', 'IJSSEL', 'iJ', "fijn 'ij x-ij i j",
        # beyond ASCII: a Latin-1 letter, sharp s, the dz digraph's own title
        # case, a dash, a no-break space, a combining accent
        ([string][char]0xE9 + 'mile'), ('STRA' + [char]0xDF + 'E'), ([string][char]0x1C6 + 'emal'),
        ('a' + [char]0x2014 + 'b'), ('a' + [char]0xA0 + 'b'), ('a' + [char]0x301 + 'b')
    )
    foreach ($c in 'en-US', 'ko-KR', 'de-DE', 'fi-FI', 'hi-IN', 'tr-TR', 'nl-NL') {
        [ordered]@{ name = "$c launch"; input = [ordered]@{ culture = $c; what = 'launch' } }
        [ordered]@{ name = "$c clock"; input = [ordered]@{ culture = $c; what = 'clock'; times = $times } }
        [ordered]@{ name = "$c N0"; input = [ordered]@{ culture = $c; what = 'n0'; counts = $counts } }
        [ordered]@{ name = "$c lanes"; input = [ordered]@{ culture = $c; what = 'lanes'; lanes = $lanes } }
    }
} -Expect {
    param($In, $Name)
    Use-NvCulture ([string]$In.culture) {
        switch ([string]$In.what) {
            'launch' {
                $ci = [System.Globalization.CultureInfo]::CurrentCulture
                [ordered]@{
                    arg = Get-NvCultureArg
                    carries = [ordered]@{ name = $ci.Name; timeSep = $ci.DateTimeFormat.TimeSeparator
                        groupSep = $ci.NumberFormat.NumberGroupSeparator; groupSizes = @($ci.NumberFormat.NumberGroupSizes)
                    }
                }
            }
            'clock' {
                # a wall-clock time on a fixed day: HH:mm:ss, maybe .fffffff
                $hm = New-Object System.Collections.Generic.List[string]
                $hms = New-Object System.Collections.Generic.List[string]
                foreach ($s in @($In.times)) {
                    $p = ([string]$s) -split '[:.]'
                    $t = [datetime]::new(2026, 1, 15, [int]$p[0], [int]$p[1], [int]$p[2])
                    if ($p.Count -gt 3) { $t = $t.AddTicks([long]$p[3].PadRight(7, '0')) }
                    $hm.Add($t.ToString('HH:mm'))
                    $hms.Add($t.ToString('HH:mm:ss'))
                }
                [ordered]@{ hhmm = $hm.ToArray(); hhmmss = $hms.ToArray() }
            }
            'n0' { [ordered]@{ n0 = @(foreach ($n in @($In.counts)) { '{0:N0}' -f [int]$n }) } }
            'lanes' {
                [ordered]@{
                    lanes = @(foreach ($l in @($In.lanes)) {
                            [ordered]@{ lane = [string]$l; name = Format-ChatqLane ([string]$l); provider = Format-ChatqProvider ([string]$l) }
                        })
                }
            }
            default { throw "no part '$($In.what)'" }
        }
    }
}
