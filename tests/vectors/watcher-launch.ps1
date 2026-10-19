# tests/vectors/watcher-launch.ps1: native/vectors/watcher-launch.json
# (native/SPEC.md 2.7, 6.1). Get-ChatqWatcherLaunch's PowerShell branch
# (src/watcher.ps1): what chatqd must start when it starts the PowerShell
# watcher. Inputs stand in for what the function reads: psExe for
# (Get-Process -Id $PID).Path, script for $script:ChatqScriptPath (the -Path
# default, so no -Path is passed), logDir for $script:ChatqLogDir, and
# claude and codex for CHATQ_CLAUDE and CHATQ_CODEX in this process's
# environment, null for unset. Read by
# native/crates/chatq-core/tests/watcher_launch_vectors.rs.

function Set-NvWatcherLaunchEnv([string]$Name, $Value) {
    # $null removes it: on pwsh 7 SetEnvironmentVariable(name, $null) would
    # set it empty, as PowerShell passes $null to a string as ''
    if ($null -eq $Value) { Remove-Item -LiteralPath "env:$Name" -EA SilentlyContinue }
    else { [Environment]::SetEnvironmentVariable($Name, [string]$Value) }
}

Register-NvVector -Name 'watcher-launch' -About 'Get-ChatqWatcherLaunch (src/watcher.ps1), PowerShell branch: {psExe, script, logDir, claude, codex} -> {exe, args, command}; args end with -EncodedCommand base64(UTF-16LE(command)). claude and codex are CHATQ_CLAUDE and CHATQ_CODEX, null for unset; the log file is Join-Path logDir watcher.log, as Windows PowerShell joins' -Cases {
    $ps51 = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $ps7 = 'C:\Program Files\PowerShell\7\pwsh.exe'
    $script = 'C:\tools\chatq\Charlie-and-the-chat-factory.ps1'
    $logs = 'C:\tools\chatq\data\logs'
    $cases = @(
        @('plain', $ps51, $script, $logs, $null, $null),
        @('pwsh 7', $ps7, $script, $logs, $null, $null),
        @('claude set', $ps51, $script, $logs, 'C:\npm\claude.cmd', $null),
        @('codex set', $ps51, $script, $logs, $null, 'C:\npm\codex.cmd'),
        @('both set', $ps7, $script, $logs, 'C:\npm\claude.cmd', 'C:\npm\codex.cmd'),
        @('single quotes', $ps51, "C:\it's\chat.ps1", "C:\it's\data\logs", "C:\it's\claude.cmd", "it''s"),
        @('curly single quotes', $ps51, (U 'C:\\a\u2018b\u2019c\\chat.ps1'), (U 'C:\\a\u201ab\u201bc\\logs'), (U '\u2018\u2019\u201a\u201b'), (U 'x\u2019''')),
        @('double and prime quotes', $ps51, (U 'C:\\a\u201cb\u201d\\chat.ps1'), 'C:\a"b\logs', (U 'c\u2032d'), 'say "hi"'),
        @('dollar and backtick', $ps7, 'C:\$env:x\`a\chat.ps1', 'C:\$(boom)\logs', '$env:USERNAME', 'a`b`$c'),
        @('spaces', $ps7, 'C:\my tools\chat q\Charlie and the chat factory.ps1', 'C:\my tools\chat q\data\logs', 'C:\Program Files\nodejs\claude.cmd', $null),
        @('hangul', $ps51, (U 'C:\\\uc0ac\uc6a9\uc790\\chatq\\Charlie-and-the-chat-factory.ps1'), (U 'C:\\\uc0ac\uc6a9\uc790\\chatq\\data\\logs'), (U 'C:\\\ud55c\\claude.cmd'), $null),
        @('astral', $ps7, (U 'C:\\\ud83d\ude00\\chat.ps1'), (U 'C:\\\ud83d\ude00\\data\\logs'), $null, (U '\ud83d\ude00')),
        @('newline in a value', $ps51, $script, $logs, "C:\a`nb\claude.cmd", $null),
        @('relative paths', $ps51, '.\Charlie-and-the-chat-factory.ps1', 'data\logs', $null, $null),
        @('forward slashes', $ps7, 'C:/tools/chatq/Charlie-and-the-chat-factory.ps1', 'C:/tools/chatq/data/logs', 'C:/npm/claude.cmd', $null),
        @('relative forward slashes', $ps51, 'chatq/chat.ps1', 'data/logs', $null, $null),
        @('trailing backslash', $ps51, $script, 'C:\tools\chatq\data\logs\', $null, $null),
        @('trailing forward slash', $ps51, $script, 'data\logs/', $null, $null),
        @('two trailing backslashes', $ps51, $script, 'C:\a\data\logs\\', $null, $null),
        @('trailing backslash and slash', $ps7, $script, 'C:\a\data\logs\/', $null, $null),
        @('doubled slash inside', $ps51, $script, 'C:\a//b\logs', $null, $null),
        @('drive alone', $ps51, $script, 'C:', $null, $null),
        @('drive root', $ps51, $script, 'C:\', $null, $null),
        @('drive root forward', $ps7, $script, 'C:/', $null, $null),
        @('trailing space', $ps51, $script, 'C:\a\data\logs ', $null, $null),
        @('wildcards', $ps7, 'C:\a\[x]\*.ps1', 'C:\a\[x]\*\logs', $null, $null),
        @('dot segments', $ps51, 'C:\a\.\b\..\chat.ps1', 'C:\a\.\b\..\logs', $null, $null),
        @('unc', $ps51, '\\server\share\chatq\chat.ps1', '\\server\share\chatq\data\logs', $null, $null),
        @('exe with quotes', "C:\it's\pwsh.exe", $script, $logs, $null, $null)
    )
    foreach ($c in $cases) {
        [ordered]@{ name = $c[0]; input = [ordered]@{ psExe = $c[1]; script = $c[2]; logDir = $c[3]; claude = $c[4]; codex = $c[5] } }
    }
} -Expect {
    param($In, $Name)
    $wlExe = [string]$In.psExe
    $wasScript = $script:ChatqScriptPath
    $wasLog = $script:ChatqLogDir
    $wasEnv = @{}
    foreach ($n in 'CHATQ_CLAUDE', 'CHATQ_CODEX') { $wasEnv[$n] = [Environment]::GetEnvironmentVariable($n) }
    # this block's own, so it goes with it: the launcher's process
    function Get-Process { param($Id) [pscustomobject]@{ Path = $wlExe } }
    try {
        $script:ChatqScriptPath = [string]$In.script
        $script:ChatqLogDir = [string]$In.logDir
        Set-NvWatcherLaunchEnv 'CHATQ_CLAUDE' $In.claude
        Set-NvWatcherLaunchEnv 'CHATQ_CODEX' $In.codex
        $r = Get-ChatqWatcherLaunch
    }
    finally {
        $script:ChatqScriptPath = $wasScript
        $script:ChatqLogDir = $wasLog
        foreach ($n in 'CHATQ_CLAUDE', 'CHATQ_CODEX') { Set-NvWatcherLaunchEnv $n $wasEnv[$n] }
    }
    $argv = @($r.Args)
    if ($r.Engine -ne 'ps') { throw "the $($r.Engine) branch" }
    if ([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String([string]$argv[-1])) -cne $r.Command) { throw '-EncodedCommand is not the command' }
    return [ordered]@{ exe = $r.Exe; args = $argv; command = $r.Command }
}
