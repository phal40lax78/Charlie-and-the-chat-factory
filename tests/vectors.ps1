<#
The contract vectors, native/vectors/*.json, made from the PowerShell
functions they pin (native/SPEC.md 6.1). The Rust runners in
native/crates/chatq-core/tests/ check chatq-core against the same files.

    powershell -NoProfile -ExecutionPolicy Bypass -File tests\vectors.ps1 [-Write] [-Only a,b]
    pwsh       -NoProfile -File tests/vectors.ps1 [-Write] [-Only a,b]

Without -Write it makes every vector and compares it with its file; the exit
code is the number of files that differ. tests/sections/native.ps1 runs it so
under each PowerShell. -Write writes the files instead, keeping the other
PowerShell's answers wherever an input is unchanged: after changing a function
a vector pins, or a generator, run it under Windows PowerShell 5.1 and under
pwsh 7, then cargo test. -Report <file> writes the result as JSON. -Keep
leaves the sandbox behind, tests/.sandbox/vectors-<edition>.

    pwsh -NoProfile -File tests/vectors.ps1 -Live <chatqd.exe>

-Live <exe> makes no vectors: it runs tests/vectors/live.ps1's checks, the
ones no file can hold, against that chatqd, and the exit code is the number
that fail. The native-windows CI leg runs it under two zones, which the suite
cannot set; tests/sections/native.ps1 runs the same checks in this PC's.

Each vector has a generator, tests/vectors/<name>.ps1; tests/vectors/common.ps1
is the engine, and says what a generator keeps to. They run against a copy of
the script and its src/, loaded as tests/run-tests.ps1 loads it, with the same
seams: nothing real is reached.

This file is ASCII, and so is every generator: other text is written as
\uXXXX and decoded by U, for the reason tests/run-tests.ps1 gives.
#>
param([switch]$Write, [string[]]$Only, [string]$Report, [switch]$Keep, [string]$Live)

$ErrorActionPreference = 'Stop'
Set-Variable -Name MaximumVariableCount -Value 32768
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
# -File passes "-Only a,b" as one string
$Only = @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($Report) { $Report = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Report) }
if ($Live) { $Live = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Live) }
# a sandbox of its own, so -Live can run while the suite makes vectors
$sb = Join-Path (Join-Path $here '.sandbox') "vectors-$(if ($Live) { 'live-' })$($PSVersionTable.PSEdition)"
if (Test-Path -LiteralPath $sb) { Remove-Item -LiteralPath $sb -Recurse -Force }
$utf8 = New-Object System.Text.UTF8Encoding $false

function U([string]$s) { [regex]::Unescape($s) }

# The tool's Get-Date and Get-Culture, as the vectors pin them. Tool code
# calls Get-Date bare: under Use-NvClock it answers that time, under
# Use-NvTimeZone now in that zone - [DateTime]::Now itself asks Windows,
# whatever TimeZoneInfo.Local says - and otherwise the cmdlet. Get-Culture
# answers the thread's culture, which Use-NvCulture sets: 5.1's cmdlet
# answers the culture the host started in.
function Get-Date {
    if ($args.Count -eq 0) {
        if ($null -ne $script:NvClock) { return $script:NvClock }
        if ($script:NvZone) { return [datetime]::UtcNow.ToLocalTime() }
    }
    Microsoft.PowerShell.Utility\Get-Date @args
}
function Get-Culture { [System.Threading.Thread]::CurrentThread.CurrentCulture }

$nvFailed = 0
try {
    # tests/sections/sandbox.ps1's sandbox, without its chats
    foreach ($d in 'claude', 'codex', 'code-user', 'tool') { $null = New-Item -ItemType Directory -Path (Join-Path $sb $d) -Force }
    Copy-Item -LiteralPath (Join-Path $root 'Charlie-and-the-chat-factory.ps1') -Destination (Join-Path $sb 'tool\Charlie-and-the-chat-factory.ps1')
    Copy-Item -LiteralPath (Join-Path $root 'src') -Destination (Join-Path $sb 'tool') -Recurse
    $env:CLAUDE_CONFIG_DIR = Join-Path $sb 'claude'
    $env:CODEX_HOME = Join-Path $sb 'codex'
    $env:CHAT_CODE_USER = Join-Path $sb 'code-user'
    $env:CHATQ_CLAUDE = Join-Path $here 'fake-claude.cmd'
    $env:CHATQ_CODEX = Join-Path $here 'fake-claude.cmd'
    $env:CHATQ_WATCHER = '1'
    $env:CHATQ_ALLPARTS = '1'
    $env:CHATQ_GH = Join-Path $here 'no-such-gh.exe'
    $env:CHATQ_NOFRONT = '1'
    foreach ($n in 'FAKE_RECORD', 'FAKE_SCENARIO', 'FAKE_LAND', 'FAKE_STDERR', 'FAKE_SLEEP', 'FAKE_AGENTS', 'FAKE_AGENTS_SEEN', 'FAKE_VERSION', 'FAKE_APPSERVER', 'FAKE_APPSERVER_NOMETHOD', 'CHATQ_CODE', 'CHATQ_CHATQD', 'CHATQ_ENGINE', 'CHATQ_NATIVE_SEAMS') { Remove-Item "env:$n" -EA SilentlyContinue }
    . (Join-Path $sb 'tool\Charlie-and-the-chat-factory.ps1')
    Set-Location -LiteralPath $sb
    $script:ChatqToastSeam = { param($t, $x) }
    $script:ChatqFooterSeam = { $null }
    $script:ChatqIdleSeam = 99999
    $script:ChatqNtfySeam = { param($server, $body, $headers) }
    $script:ChatqDownSeam = { param($m, $u, $h, $b) $null }
    $script:ChatNoGhostWatch = $true
    $script:ChatqSpawn = { $true }
    $script:ChatStopSeam = { param($e) 'gone' }
    $script:ChatParentSeam = { param($e) @{ Pid = 4242; Name = 'Code'; StartTime = [datetime]::MinValue } }
    $script:ChatCodeSeam = { param($f) [pscustomobject]@{ Ok = $true; Code = 'ok'; Why = $null; Slow = $false } }
    $script:ChatWindowTitlesSeam = { @() }
    $script:ChatCodeExesSeam = { @() }
    $script:ChatCodeProfilesSeam = { @() }
    $script:ChatShowSpawnSeam = { param($c) $null }
    $script:ChatForegroundSeam = { 0 }
    $script:ChatCodeWindowListSeam = { @() }
    $script:ChatOverlayRaiseSeam = { param($c, $h, $o) $null }
    $script:ChatOverlayGrantSeam = { param($p) @() }
    $script:ChatOverlayCodexUsageSeam = { param($h) @{ Ok = $false; Why = 'no app-server in the vectors'; Quiet = $true } }
    $script:ChatShowHoldSeconds = 0
    $script:ChatHandoverOff = $true
    $script:ChatHostLogRootsSeam = { @() }
    $script:ChatMemorySeam = { @{ Limit = 32GB; Free = 16GB } }
    $script:ChatMemoryTopSeam = { @() }
    $script:ChatMemorySumsSeam = { @{} }

    if ($Live) {
        . (Join-Path $here 'vectors\live.ps1')
        foreach ($c in @(Invoke-NvLiveChecks $Live)) {
            "  $(if ($c.ok) { 'ok  ' } else { 'FAIL' })  $($c.name): $($c.detail)"
            if (-not $c.ok) { $nvFailed++ }
        }
    }
    else {
        . (Join-Path $here 'vectors\common.ps1')
        # live.ps1 asks a real chatqd, under -Live and tests/sections/native.ps1
        foreach ($nvGen in @(Get-ChildItem -LiteralPath (Join-Path $here 'vectors') -Filter '*.ps1' | Where-Object { 'common.ps1', 'live.ps1' -notcontains $_.Name } | Sort-Object Name)) { . $nvGen.FullName }
        $nvFailed = Invoke-NvVectors -Write:$Write -Only $Only -Report $Report
    }
}
finally {
    Set-Location -LiteralPath $here
    if (-not $Keep) { Remove-Item -LiteralPath $sb -Recurse -Force -EA SilentlyContinue }
}
exit $nvFailed
