# tests/sections/process-runner.ps1: dot-sourced by tests/run-tests.ps1 in its turn,
# never on its own - it uses what the runner and the sections before it set.

Section 'process runner'
$rec = Join-Path $sb 'rec'
$env:FAKE_RECORD = $rec
$env:ANTHROPIC_API_KEY = 'sk-must-not-leak'
$env:CLAUDECODE = '1'
$prompt = (U '\uC900\uBE44 \uC644\uB8CC') + " `"quoted`" back\slash %PATH% tab`t end`nsecond line"
$lines = [System.Collections.Generic.List[string]]::new()
$p = Invoke-ChatqProcess -Exe $env:CHATQ_CLAUDE -ArgList @('-p', '--resume', $idCard) -StdIn $prompt -OnLine { param($l) $lines.Add($l) } -TimeoutSec 60
$got = [System.IO.File]::ReadAllBytes((Join-Path $rec 'stdin.bin'))
$want = $utf8.GetBytes($prompt)
Check 'stdin arrives byte-exact (Hangul, quotes, %, newlines)' ([Convert]::ToBase64String($got) -eq [Convert]::ToBase64String($want)) "$($got.Length) vs $($want.Length) bytes"
Check 'no BOM on stdin' (-not ($got.Length -ge 3 -and $got[0] -eq 0xEF -and $got[1] -eq 0xBB))
$envSeen = [System.IO.File]::ReadAllText((Join-Path $rec 'env.txt'), $utf8)
Check 'ANTHROPIC_API_KEY kept out of the child' ($envSeen -match '(?m)^ANTHROPIC_API_KEY=$') $envSeen
Check 'CLAUDECODE kept out of the child' ($envSeen -match '(?m)^CLAUDECODE=$')
Check 'stdout read line by line' ($lines.Count -eq 3 -and $p.ExitCode -eq 0) "$($lines.Count) lines exit $($p.ExitCode)"
Remove-Item env:ANTHROPIC_API_KEY, env:CLAUDECODE

$env:FAKE_STDERR = '400000'
$p = Invoke-ChatqProcess -Exe $env:CHATQ_CLAUDE -ArgList @('-p') -StdIn 'x' -TimeoutSec 60
Check '400 KB of stderr does not deadlock' ($p.ExitCode -eq 0 -and $p.StdErr.Length -ge 390000) "exit $($p.ExitCode) err $($p.StdErr.Length)"
Remove-Item env:FAKE_STDERR

$env:FAKE_SLEEP = '30'
$t0 = Get-Date
$p = Invoke-ChatqProcess -Exe $env:CHATQ_CLAUDE -ArgList @('-p') -StdIn 'x' -TimeoutSec 2
$fakePid = [int]([System.IO.File]::ReadAllText((Join-Path $rec 'pid.txt')))
Start-Sleep -Milliseconds 500
Check 'timeout stops the run' ($p.Stopped -eq 'timeout' -and ((Get-Date) - $t0).TotalSeconds -lt 20) "$($p.Stopped)"
Check 'and takes the whole process tree with it' (-not (Get-Process -Id $fakePid -EA SilentlyContinue)) $fakePid
Remove-Item env:FAKE_SLEEP

# the quoting rules, checked against what the CLR itself hands Main()
$echo = Join-Path $sb 'echoargs.exe'
$echoSrc = @'
public static class EchoArgs {
    public static void Main(string[] a) {
        foreach (var s in a) System.Console.WriteLine(System.Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(s)));
    }
}
'@
$built = $false
try { Add-Type -OutputAssembly $echo -OutputType ConsoleApplication -TypeDefinition $echoSrc; $built = $true } catch {}
if (-not $built) {
    # pwsh 7's Add-Type builds libraries only. .NET Framework's own compiler,
    # which every Windows carries, still builds the exe.
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if ($env:WINDIR -and (Test-Path -LiteralPath $csc)) {
        $cs = Join-Path $sb 'echoargs.cs'
        [System.IO.File]::WriteAllText($cs, $echoSrc, $utf8)
        & $csc /nologo "/out:$echo" $cs | Out-Null
        $built = $LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $echo)
    }
}
if ($built) {
    $argsIn = @('plain', '', 'with space', 'quote"inside', 'trail\', 'C:\path with\', 'a\\"b', '--tools', '', $titleCard)
    $out = [System.Collections.Generic.List[string]]::new()
    $null = Invoke-ChatqProcess -Exe $echo -ArgList $argsIn -StdIn '' -OnLine { param($l) $out.Add($utf8.GetString([Convert]::FromBase64String($l))) } -TimeoutSec 30
    Check 'argument quoting round-trips' (($out -join '|') -eq ($argsIn -join '|')) ($out -join '|')
    # the same exe behind a .cmd, as npm's claude.cmd is: cmd.exe reads the
    # line again, and &|<>^() reach the exe only because they are quoted;
    # a lone %, with no second one to make a %name%, goes as it is
    $echoCmd = Join-Path $sb 'echo args.cmd'
    [System.IO.File]::WriteAllText($echoCmd, "@`"%~dp0echoargs.exe`" %*`r`n", [System.Text.Encoding]::ASCII)
    $cmdIn = @('plain', 'a&b', 'x|y', '<in>', 'up^caret', '(paren)', 'with space & more', 'trail\', 'D:\100% done', '--model', 'claude-sonnet-4-5')
    $out = [System.Collections.Generic.List[string]]::new()
    $null = Invoke-ChatqProcess -Exe $echoCmd -ArgList $cmdIn -StdIn '' -OnLine { param($l) $out.Add($utf8.GetString([Convert]::FromBase64String($l))) } -TimeoutSec 30
    Check 'arguments holding &|<>^() or a lone % reach an exe behind a .cmd whole' (($out -join '|') -eq ($cmdIn -join '|')) ($out -join ' / ')
}
else {
    # said, never counted as a pass
    Write-Host '  skip  argument quoting round-trips - nothing here can build the echo exe' -ForegroundColor Yellow
}
# what cmd.exe cannot be handed at all - a quote, a %name%, a line break -
# is refused for a .cmd or .bat, and only there; the refusal says which. A
# lone % is no %name%, and goes.
$refQ = try { ConvertTo-ChatqArgLine @('--model', 'a"b') -Exe 'C:\npm\claude.cmd'; $null } catch { $_.Exception.Message }
$refP = Get-ChatqCmdArgRefusal 'C:\npm\codex.BAT' @('--add-dir', 'D:\%USERNAME%\data')
$refN = Get-ChatqCmdArgRefusal 'C:\npm\claude.cmd' @("two`nlines")
$lone = Get-ChatqCmdArgRefusal 'C:\npm\claude.cmd' @('D:\100% done', '50%')
$exeOk = ConvertTo-ChatqArgLine @('a"b', '%PATH%', 'a&b') -Exe 'C:\bin\claude.exe'
$cmdLine = ConvertTo-ChatqArgLine @('a&b', '(x)', 'plain') -Exe 'C:\npm\claude.cmd'
Check 'a quote, %name% or line break for a .cmd is refused, and said; a lone % is not; an .exe takes them all, and only a .cmd has &|<>^() quoted' (
    $refQ -like 'claude.cmd runs through cmd.exe, which cannot be handed a quote - not sent: *' -and $refP -like '*cannot be handed a %name% *' -and
    $refN -like '*cannot be handed a line break*' -and -not $lone -and $exeOk -eq '"a\"b" %PATH% a&b' -and $cmdLine -eq '"a&b" "(x)" plain') "$refQ / $refP / $refN / $lone / $exeOk / $cmdLine"
Remove-Item env:FAKE_RECORD
