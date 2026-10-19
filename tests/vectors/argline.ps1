# tests/vectors/argline.ps1: native/vectors/argline.json (native/SPEC.md
# 2.6, 6.1). ConvertTo-ChatqArgLine and Get-ChatqCmdArgRefusal
# (src/queue.ps1) on an adversarial corpus, each argument for an exe and for
# a .cmd, which cmd.exe reads first; the .cmd and .bat test and the name a
# refusal gives, over exe paths; and the cmd title scrub, which lives inside
# Invoke-ChatqRun, through that function with the CLI's start stubbed. Read
# by native/crates/chatq-core/tests/argline_vectors.rs.
#
# An answer is { refusal; line }: line $null where ConvertTo-ChatqArgLine
# threw, which it does with the refusal's own text. A title's answer is
# { name; args; line }: the --name Invoke-ChatqRun passed, the arguments it
# built, and their line. Text holding a lone surrogate - a refusal cuts at 60
# UTF-16 code units, through a pair if one is there - goes as code units.

function ConvertTo-NvArglineText($S) {
    if ($null -eq $S) { return $null }
    $s = [string]$S
    for ($i = 0; $i -lt $s.Length; $i++) {
        $c = [int]$s[$i]
        if ($c -ge 0xD800 -and $c -le 0xDBFF -and $i + 1 -lt $s.Length -and [int]$s[$i + 1] -ge 0xDC00 -and [int]$s[$i + 1] -le 0xDFFF) { $i++; continue }
        if ($c -ge 0xD800 -and $c -le 0xDFFF) {
            $u = ConvertTo-NvUnits $s
            return , $u
        }
    }
    return $s
}

function Invoke-NvArglineRun($Job, [string]$Exe, [string]$Case) {
    # Invoke-ChatqRun up to the CLI's start: the exe it is handed, the
    # arguments it built and their line. The stubs are this function's own,
    # so they go with it; its variables are named so that no function they
    # pass through has one of the same name.
    $arglineExe = $Exe
    $arglineCaught = @{}
    $arglineStop = 'argline vector: the CLI would start here'
    function Find-ChatqExe { param([string]$Provider) $arglineExe }
    function Get-ChatqCliVersion { param([string]$Exe, [switch]$Fresh) '9.9.9' }
    function Invoke-ChatqProcess {
        param([string]$Exe, [string[]]$ArgList, [string]$WorkDir, [string]$StdIn, [hashtable]$SetEnv, [string]$LogPath,
            [scriptblock]$OnLine, [scriptblock]$OnTick, [int]$TimeoutSec = 14400)
        $arglineCaught['Args'] = @($ArgList)
        $arglineCaught['Line'] = ConvertTo-ChatqArgLine $ArgList -Exe $Exe
        throw $arglineStop
    }
    $null = Enter-NvData $Case
    $r = $null
    try { $r = Invoke-ChatqRun $Job 'x' $null $null -Carry ([pscustomobject]@{ Ultracode = $false; Effort = $null }) }
    catch { if ($_.Exception.Message -cne $arglineStop) { throw } }
    if (-not $arglineCaught.Contains('Args')) { throw "Invoke-ChatqRun did not start the CLI: $($r | ConvertTo-Json -Compress)" }
    return $arglineCaught
}

Register-NvVector -Name 'argline' -About 'ConvertTo-ChatqArgLine and Get-ChatqCmdArgRefusal (src/queue.ps1) for an exe and a .cmd or .bat target, on an adversarial corpus: {exe, args} -> {refusal, line}, line null where it threw the refusal; text with a lone surrogate as UTF-16 code units. Titles: Invoke-ChatqRun''s --name for a fresh chat, the cmd title scrub for a .cmd: {exe, title} -> {name, args, line}' -Cases {
    $exe = 'C:\bin\claude.exe'
    $cmd = 'C:\npm\claude.cmd'
    $corpus = @(
        @('plain', 'plain'),
        @('empty', ''),
        @('space', 'a b'),
        @('tab', "a`tb"),
        @('newline', "a`nb"),
        @('carriage return', "a`rb"),
        @('crlf', "a`r`nb"),
        @('line break run', "a`n`n`rb"),
        @('quote', 'a"b'),
        @('quote alone', '"'),
        @('two quotes', '""'),
        @('backslash', 'a\b'),
        @('backslashes and a space', 'a\\b c'),
        @('backslash before a quote', 'a\"b'),
        @('two backslashes before a quote', 'a\\"b'),
        @('trailing backslash', 'a b\'),
        @('two trailing backslashes', 'a b\\'),
        @('backslash alone', '\'),
        @('two backslashes alone', '\\'),
        @('program files', 'C:\Program Files\'),
        @('unc with a space', '\\srv\share\a b'),
        @('percent name', '%PATH%'),
        @('percent lone', '100%'),
        @('percent alone', '%'),
        @('percent pair', '%%'),
        @('percent three', '%%a%'),
        @('percent name inside', 'a%b%c'),
        @('percent name with a space', '%a b%'),
        @('bang', '!x!'),
        @('caret', '^'),
        @('ampersand', '&'),
        @('pipe', '|'),
        @('less', '<'),
        @('greater', '>'),
        @('parens', '(x)'),
        @('ampersand inside', 'a&b'),
        @('caret and a space', 'a^b c'),
        @('cve quote ampersand', '"&calc.exe'),
        @('cve backslash quote', '\"&calc.exe'),
        @('cve ampersand', '&calc.exe'),
        @('cve quoted ampersands', 'x"&calc.exe&"y'),
        @('cve caret quote', '^"&calc'),
        @('cve cmdcmdline', '%CMDCMDLINE:~-1%&calc.exe'),
        @('cve backslashes quote', 'a\\" & calc'),
        @('cve trailing backslash', 'calc.exe\'),
        @('accent', (U 'caf\u00e9')),
        @('hangul', (U '\ud55c\uad6d\uc5b4')),
        @('hangul and a space', (U '\ud55c\uad6d \uc5b4')),
        @('astral', (U '\ud83d\ude00')),
        @('astral and a space', (U 'a\ud83d\ude00 b')),
        @('no-break space', (U 'a\u00a0b')),
        @('ideographic space', (U 'a\u3000b')),
        @('line separator', (U 'a\u2028b')),
        @('next line', (U 'a\u0085b')),
        @('mongolian vowel separator', (U 'a\u180eb')),
        @('zero width space alone', (U '\u200b')),
        @('soft hyphen alone', (U '\u00ad')),
        @('byte order mark alone', (U '\ufeff')),
        @('soft hyphen and zero width space', (U '\u00ad\u200b')),
        @('soft hyphen in a word', (U 'a\u00adb')),
        @('variation selector alone', (U '\udb40\udd00')),
        @('nul alone', (U '\u0000')),
        @('nul inside', (U 'a\u0000b')),
        @('fullwidth quote', (U 'a\uff02b')),
        @('curly quotes', (U '\u201cx\u201d')),
        @('long quote', (('x' * 70) + '"')),
        @('long name', ('%' + ('y' * 70) + '%')),
        @('long line break', (('z' * 58) + "`r`n" + 'tail')),
        @('astral at the cut', (('w' * 59) + (U '\ud83d\ude00') + '"')),
        @('astral before the cut', (('v' * 58) + (U '\ud83d\ude00') + '"'))
    )
    foreach ($p in $corpus) {
        [ordered]@{ name = "exe: $($p[0])"; input = [ordered]@{ kind = 'line'; exe = $exe; args = @($p[1]) } }
        [ordered]@{ name = "cmd: $($p[0])"; input = [ordered]@{ kind = 'line'; exe = $cmd; args = @($p[1]) } }
    }
    $lists = @(
        @('several', @('-p', '--name', 'my chat', '')),
        @('first refusal wins', @('ok', 'bad"one', '%also%')),
        @('a name before a quote', @('ok', '%x%', 'a"b')),
        @('quote and name in one', @('a"%x%')),
        @('name and line break in one', @("a`n%x%")),
        @('none', @())
    )
    foreach ($p in $lists) {
        [ordered]@{ name = "exe list: $($p[0])"; input = [ordered]@{ kind = 'line'; exe = $exe; args = $p[1] } }
        [ordered]@{ name = "cmd list: $($p[0])"; input = [ordered]@{ kind = 'line'; exe = $cmd; args = $p[1] } }
    }
    # which exe paths are a .cmd or .bat, and the name a refusal gives them
    $exes = @(
        @('bare cmd', 'claude.cmd'),
        @('forward slashes', 'C:/npm/codex.CMD'),
        @('bat with spaces', 'C:\x y\run.bat'),
        @('relative bat', '..\tools\c.Bat'),
        @('drive relative', 'C:claude.cmd'),
        @('brackets', 'C:\x\[a].cmd'),
        @('star', 'C:\x\*.cmd'),
        @('trailing newline', "C:\x\c.cmd`n"),
        @('trailing crlf', "C:\x\c.cmd`r`n"),
        @('trailing space', 'C:\x\c.cmd '),
        @('cmdx', 'C:\x\c.cmdx'),
        @('dot cmd', 'C:\x\.cmd'),
        @('unix path', '/usr/local/bin/claude.cmd'),
        @('mixed slashes', 'a/b\c.bat'),
        @('upper case', 'C:\X\CLAUDE.CMD'),
        @('no extension', 'codex'),
        @('cmd folder', 'C:\x.cmd\claude.exe'),
        @('empty', '')
    )
    foreach ($p in $exes) {
        [ordered]@{ name = "exe path: $($p[0])"; input = [ordered]@{ kind = 'line'; exe = $p[1]; args = @('a"b', 'x y') } }
    }
    $titles = @(
        @('plain', 'My chat'),
        @('quotes and ampersand', 'fix "quoted" & more'),
        @('percent and bang', '100% sure %PATH% !x!'),
        @('pipes and carets', 'a|b<c>d^e'),
        @('white space', "tabs`tand`nnewlines`r`nhere"),
        @('leading and trailing', '  leading and trailing  '),
        @('parens', '(parens) stay'),
        @('quote at the end', 'only "'),
        @('quote alone', '"'),
        @('cve', '""&calc.exe'),
        @('hangul', (U '\ud55c\uad6d\uc5b4 "\uc81c\ubaa9"')),
        @('astral', (U 'emoji \ud83d\ude00 title')),
        @('unicode spaces', (U 'a\u00a0\u00a0b\u3000c')),
        @('zero width space', (U '\u200b')),
        @('empty', '')
    )
    foreach ($p in $titles) {
        [ordered]@{ name = "cmd title: $($p[0])"; input = [ordered]@{ kind = 'title'; exe = $cmd; title = $p[1] } }
        [ordered]@{ name = "exe title: $($p[0])"; input = [ordered]@{ kind = 'title'; exe = $exe; title = $p[1] } }
    }
} -Expect {
    param($In, $Name)
    $exePath = [string]$In.exe
    if ($In.kind -eq 'title') {
        $job = [pscustomobject]@{ id = 'j1'; seq = 1; provider = 'claude'; kind = 'new'; path = $null
            sessionId = '00000000-0000-4000-8000-000000000001'; title = [string]$In.title; mode = $null; modeAtQueue = $null
            runModel = $null; home = $null; cwd = $null
        }
        $got = Invoke-NvArglineRun $job $exePath $Name
        $argv = @($got['Args'])
        $at = [Array]::IndexOf([string[]]$argv, '--name')
        if ($at -lt 0) { throw 'no --name: not a fresh chat' }
        return [ordered]@{ name = (ConvertTo-NvArglineText $argv[$at + 1]); args = @($argv | ForEach-Object { ConvertTo-NvArglineText $_ }); line = (ConvertTo-NvArglineText $got['Line']) }
    }
    $list = [string[]]@($In.args)
    $no = Get-ChatqCmdArgRefusal $exePath $list
    $line = $null
    try { $line = ConvertTo-ChatqArgLine $list -Exe $exePath }
    catch {
        if ($_.Exception.Message -cne [string]$no) { throw "ConvertTo-ChatqArgLine threw '$($_.Exception.Message)', not its refusal" }
    }
    if ($null -ne $line -and $null -ne $no) { throw 'a line and a refusal both' }
    return [ordered]@{ refusal = (ConvertTo-NvArglineText $no); line = (ConvertTo-NvArglineText $line) }
}
