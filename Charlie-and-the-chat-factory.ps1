<#
Charlie-and-the-chat-factory - find, delete and queue prompts for local AI chats.

INSTALL
    iex (irm https://raw.githubusercontent.com/phal40lax78/Charlie-and-the-chat-factory/main/install.ps1)
  or, with this file and the src/ beside it already on disk
    . "$HOME\Tools\Charlie-and-the-chat-factory\Charlie-and-the-chat-factory.ps1"
    chatinstall

  The leading dot matters: `. file.ps1` loads the commands into this shell,
  `& file.ps1` or a double-click throws them away again as it exits.

Then type chat for the cheat sheet. Everything else is in README.md.
#>

# Bump this in the same commit that changes behaviour - chatinstall compares it
# against data/version.txt to say whether a reinstall actually landed anything,
# and raw.githubusercontent.com serves a stale copy for minutes after a push, so
# "updated" vs "unchanged" is the only way to tell a real upgrade from the CDN
# handing back what you already had. extension/package.json carries the same
# version: the extension installs this copy by it, and extension/build.js
# refuses to pack the two apart.
$script:ChatVersion = '0.11.6'

# The tool's folder and this file, read here once and never inside a function:
# data/ sits in that folder, and the profile line, the watcher and the overlay
# all load this file by that path. $PSScriptRoot and $PSCommandPath inside a
# function name the file that function is written in, which need not be this
# one. Empty under iex, where no file is behind the code.
$script:ChatRoot = $PSScriptRoot
$script:ChatScriptPath = $PSCommandPath

# The rest is in src/, loaded below in the order the one file had: each
# part's top level runs as it loads, and may use what an earlier one set.
# Dot-sourced into this file's own scope, so everything lands where a
# dot-source of this file puts it.
if (-not $PSScriptRoot) {
    Write-Host '  Charlie-and-the-chat-factory loads its parts from src/ beside it, so it has to' -ForegroundColor Yellow
    Write-Host '  be loaded from its file:  . "C:\path\to\Charlie-and-the-chat-factory.ps1"' -ForegroundColor DarkGray
    return
}
$chatParts = 'core', 'shell', 'icon', 'providers', 'chatrm', 'discoverability', 'queue', 'codex-appserver', 'live-chats', 'alerts', 'phone', 'phone-extras', 'permit', 'ask', 'phone-down', 'phone-board', 'watcher', 'commands', 'phone-setup', 'overlay-data', 'overlay-windows', 'console', 'overlay-mac', 'overlay', 'overlay-host', 'auto-continue', 'host-work'
# .NET's own file test, not Test-Path: the cmdlet loads a module of its
# own, a few MB a profile's load (below) would not otherwise spend
$chatMissing = @($chatParts | Where-Object { -not [System.IO.File]::Exists([System.IO.Path]::Combine($PSScriptRoot, 'src', "$_.ps1")) })
if ($chatMissing) {
    # before any part loads: half the commands would fail in ways that
    # point nowhere near a missing file
    Write-Host "  Charlie-and-the-chat-factory: missing from $(Join-Path $PSScriptRoot 'src'): $(@($chatMissing | ForEach-Object { "$_.ps1" }) -join ', ')" -ForegroundColor Yellow
    Write-Host '  the script is this file and the src folder beside it - copy both, or run the installer again' -ForegroundColor DarkGray
    Remove-Variable chatParts, chatMissing -EA SilentlyContinue
    return
}
# A profile's load, in a shell a person types in: most such shells never run
# a command of this tool, so they take shell.ps1 alone - a stand-in for each
# command, the aliases, the key handlers and the checks a shell makes as it
# opens - and the rest loads the first time one is used (Enter-ChatShell,
# Import-ChatTool). The same tests as the shell-start duties below, and the
# processes that set CHATQ_ROLE or CHATQ_ALLPARTS load as before. A profile's
# dot-source only: one at the prompt asks for the tool now, and a profile
# dot-sourcing it into a shell that has it already reloads it whole.
if ($MyInvocation.InvocationName -eq '.' -and -not $env:CHATQ_WATCHER -and -not $env:CHATQ_OVERLAY -and -not $env:CHATQ_ROLE -and
    -not $env:CHATQ_ALLPARTS -and -not $env:CLAUDECODE -and [Environment]::UserInteractive -and
    $Host.Name -in 'ConsoleHost', 'Visual Studio Code Host' -and
    -not $ExecutionContext.SessionState.InvokeProvider.Item.Exists('function:\Get-ChatqJobs')) {
    # Asked of the session itself, here and below, not through Test-Path and
    # Get-Variable: each cmdlet loads its module, MBs a start like this does
    # not otherwise spend. $PROFILE and its four names read in a try: under
    # StrictMode a shell with none would throw, and the load with it.
    $chatProfile = $ExecutionContext.SessionState.PSVariable.GetValue('PROFILE')
    $chatProfiles = @("$chatProfile") + @(try { $chatProfile.AllUsersAllHosts, $chatProfile.AllUsersCurrentHost, $chatProfile.CurrentUserAllHosts, $chatProfile.CurrentUserCurrentHost } catch {})
    $chatLazy = $MyInvocation.ScriptName -and $chatProfiles -contains $MyInvocation.ScriptName
    Remove-Variable chatProfile, chatProfiles -EA SilentlyContinue
    if ($chatLazy) {
        . ([System.IO.Path]::Combine($PSScriptRoot, 'src', 'shell.ps1'))
        if (Enter-ChatShell) {
            Remove-Variable chatParts, chatMissing, chatLazy -EA SilentlyContinue
            return
        }
    }
    Remove-Variable chatLazy -EA SilentlyContinue
}
# A shell never draws the panel or the console, and nothing it runs calls
# into their three parts: they load only where CHATQ_ALLPARTS is set - the
# launch of the overlay, or of the phone setup's window, sets it and drops it
# once loaded, and the tests set it for the whole run. Not where
# CHATQ_OVERLAY is: that says only no key bindings and no watches, for the
# processes the overlay starts, the question hook, the permission bridge,
# the phone's sender and the extension's runs, none of which draws either.
# Each is lighter for it, a shell and the watcher too: 8 MB less .NET heap,
# 10 to 44 MB less memory by how much the PC has free, and 0.1 to 0.2 s less
# to load. All 27 are looked for above, so a broken copy still shows.
# The headless host, the overlay whose panel is native
# (Start-ChatOverlayHeadlessHost), starts without CHATQ_ALLPARTS and loads
# the panel's and the console's parts itself, the first time its console is
# asked for (Import-ChatOverlayConsoleParts).
# A process that runs one thing loads only the parts that thing reaches:
# the permission bridge, alive as long as a queued run, and the question
# hook, one for each question held. CHATQ_ROLE names it, ahead of
# CHATQ_ALLPARTS, which the tests set for the whole run, so the bridge and
# the hook they start load as they do for real. It is dropped once read, so
# nothing they start inherits it. Each list is what its entry reaches, by
# the functions it calls and the top-level variables of every part; the
# self-test works that out again and fails on a list that misses a part
# (tests/sections/find-delete.ps1). A fresh load, after a full collection,
# median of 5: 88 MB private for the bridge's 10 parts and 94 for the hook's
# 16, against 104 for all 23; 317 and 387 ms to load against 518.
$chatRoles = @{
    permit = 'core', 'shell', 'queue', 'live-chats', 'alerts', 'phone', 'phone-extras', 'permit', 'phone-down', 'overlay-data'
    ask    = 'core', 'shell', 'providers', 'chatrm', 'discoverability', 'queue', 'live-chats', 'alerts', 'phone', 'phone-extras', 'permit', 'ask', 'phone-down', 'phone-board', 'watcher', 'overlay-data'
}
$chatRole = [string]$env:CHATQ_ROLE
Remove-Item -LiteralPath 'env:CHATQ_ROLE' -EA SilentlyContinue
if (-not $chatRoles.ContainsKey($chatRole)) { $chatRole = '' }
if ($chatRole) { $chatParts = @($chatParts | Where-Object { $_ -in $chatRoles[$chatRole] }) }
elseif (-not $env:CHATQ_ALLPARTS) { $chatParts = @($chatParts | Where-Object { $_ -notin 'overlay-windows', 'console', 'overlay-mac' }) }
foreach ($chatPart in $chatParts) { . (Join-Path (Join-Path $PSScriptRoot 'src') "$chatPart.ps1") }
Remove-Variable chatParts, chatMissing, chatPart, chatRoles -EA SilentlyContinue
# A copy from before that - an overlay restarting itself onto this one, a
# terminal opened before it - starts the overlay with CHATQ_OVERLAY alone
# and calls its host by name, which a load like that leaves out: started
# again from here, the way this copy starts it. A second load in that
# terminal's 10 s wait, which on a PC short of memory may say the overlay did
# not start just before it does. Why it could not is thrown, for that
# launch's catch to log: said, it would go to this hidden window. The phone
# setup's window does the same, in Show-ChatqPhoneSetup.
if ($env:CHATQ_OVERLAY -and -not $env:CHATQ_ALLPARTS) {
    function Start-ChatOverlayHost {
        param([string]$Open = '')
        $said = @(Start-ChatOverlayProcess -Open $Open 6>&1)
        if ($said[-1] -ne $true) { throw (@($said | Where-Object { $_ -is [Management.Automation.InformationRecord] } | ForEach-Object { "$_".Trim() }) -join ' ') }
    }
    function Start-ChatOverlayMacHost { Start-ChatOverlayHost }
}

$script:ChatqJobCompleter = {
    param($cmd, $param, $word)
    Set-StrictMode -Off
    @(Get-ChatqJobs) | Where-Object { "$($_.seq)" -like "$word*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new("$($_.seq)", "#$($_.seq) $($_.title) [$($_.state)]", 'ParameterValue', "$($_.title)`n$($_.state)")
    }
}
Register-ArgumentCompleter -CommandName chatqrm, chatqrun, chatqlog -ParameterName Ref -ScriptBlock $script:ChatqJobCompleter


# a shell opened after the delete picks the watch back up - not a role's
# process: it sets CHATQ_OVERLAY, so Start-ChatGhostWatch would return at
# once, and the bridge loads no chatrm.ps1 to define it
if (-not $chatRole -and (Test-Path -LiteralPath $script:ChatTombPath)) { Start-ChatGhostWatch }
Remove-Variable chatRole -EA SilentlyContinue

# Run instead of dot-sourced - & file.ps1, powershell -File, a double-click.
# Everything above was defined in a scope about to be thrown away, leaving a
# shell with no chat command and nothing said about why. InvocationName is '.'
# for a real dot-source, at the prompt and from inside a profile alike, and the
# path or '&' otherwise, so this cannot fire on a legitimate load.
if ($MyInvocation.InvocationName -ne '.') {
    Write-Host ''
    Write-Host '  nothing was loaded - this file has to be dot-sourced' -ForegroundColor Yellow
    Write-Host '  a dot and a space in front of the path is the whole difference:' -ForegroundColor DarkGray
    # iex has no file behind it, so PSCommandPath is empty there - printing
    # . "" would be advice nobody can follow, and is how an empty dot-source
    # line ends up pasted into a profile in the first place
    $shown = if ($PSCommandPath) { $PSCommandPath } else { 'C:\path\to\Charlie-and-the-chat-factory.ps1' }
    Write-Host "      . `"$shown`"" -ForegroundColor Cyan
    Write-Host '  then chatinstall, to have every new shell do it for you' -ForegroundColor DarkGray
    Write-Host ''
}
elseif (-not $env:CHATQ_WATCHER -and -not $env:CHATQ_OVERLAY -and -not $env:CLAUDECODE -and [Environment]::UserInteractive -and
    $Host.Name -in 'ConsoleHost', 'Visual Studio Code Host' -and -not $ExecutionContext.SessionState.PSVariable.GetValue('global:ChatShellLazy')) {
    # The watcher and the overlay back after a reboot, and the phone's
    # listening (Start-ChatShellDuties). Not in a lazy shell: it ran them as
    # it opened (Enter-ChatShell), and this is its first use loading the tool.
    # Asked of the session, not Get-Variable, which files a miss in $Error.
    Start-ChatShellDuties
}
