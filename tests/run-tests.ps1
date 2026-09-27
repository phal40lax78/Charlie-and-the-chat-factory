<#
VS-code-chat-manager self-test. No Pester, no network, no model: every claude/codex call goes
to tests/fake-agent.ps1. The exit code is the number of failed checks.

    powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
    pwsh       -NoProfile -File tests/run-tests.ps1

It builds a sandbox in tests/.sandbox - fake Claude and Codex homes whose chats
are generated here with timestamps relative to now, so no fixture ever goes
stale - copies the script and its src/ into it (its data/ follows the script,
so the sandbox gets its own), and dot-sources that copy. -Keep leaves the
sandbox behind. The sandbox and the checks are in tests/sections/, listed below.

This file is ASCII: Hangul is written as \uXXXX and decoded by U, because
Windows PowerShell 5.1 reads a BOM-less script in the ANSI code page.
#>
param([switch]$Keep)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$sb = Join-Path (Join-Path $here '.sandbox') 'run'
if (Test-Path -LiteralPath $sb) { Remove-Item -LiteralPath $sb -Recurse -Force }
$null = New-Item -ItemType Directory -Path $sb -Force
$utf8 = New-Object System.Text.UTF8Encoding $false

function U([string]$s) { [regex]::Unescape($s) }

$script:Pass = 0
$script:Fail = 0
function Check([string]$Name, [bool]$Ok, $Detail) {
    if ($Ok) { $script:Pass++; Write-Host "  ok    $Name" -ForegroundColor Green }
    else { $script:Fail++; Write-Host "  FAIL  $Name  $Detail" -ForegroundColor Red }
}
function Section([string]$Name) { Write-Host ''; Write-Host "  $Name" -ForegroundColor Cyan }

# A WPF check runs in an STA Windows PowerShell of its own, and gives back the
# last line it prints. Its script goes in a file, never on the command line:
# -EncodedCommand doubles it as UTF-16 base64 around the sandbox's own paths,
# and from a long enough checkout path that passed the 32,767 characters a
# command line holds, aborting the whole run. The BOM makes 5.1 read it as UTF-8.
function Invoke-Sta([string]$Name, [string]$Script) {
    $f = Join-Path $sb "$Name.ps1"
    [IO.File]::WriteAllText($f, $Script, [System.Text.UTF8Encoding]::new($true))
    try {
        return (@(& (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File $f 2>&1) | Select-Object -Last 1)
    }
    finally { Remove-Item -LiteralPath $f -Force -EA SilentlyContinue }
}

# The sandbox, then every section, from tests/sections/ in this order: one
# scope, as the one file had, so a later section uses what an earlier one
# built - the sandbox's chats, the script it loaded, helpers and seams.
$testSections = 'sandbox', 'bigrams', 'resolver', 'metadata', 'limits', 'classifier', 'overload', 'review-regressions', 'process-runner', 'watcher', 'job-core', 'new-chats', 'find-delete', 'retries', 'model-order', 'attachments', 'handoff', 'alert-channels', 'usage', 'archive', 'reload-safety', 'status-alerts', 'overlay', 'reset-ask', 'show-fresh', 'phone', 'phone-extras', 'permit', 'phone-board', 'auto-continue', 'host-work'
foreach ($testSection in $testSections) { . (Join-Path (Join-Path $here 'sections') "$testSection.ps1") }

Set-Location -LiteralPath $here
Write-Host ''
$color = if ($script:Fail) { 'Red' } else { 'Green' }
Write-Host "  $($script:Pass) passed, $($script:Fail) failed" -ForegroundColor $color
if (-not $Keep) { Remove-Item -LiteralPath (Join-Path $here '.sandbox') -Recurse -Force -EA SilentlyContinue }
exit $script:Fail
