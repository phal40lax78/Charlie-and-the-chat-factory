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
$script:ChatVersion = '0.10.7'

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
$chatParts = 'core', 'icon', 'providers', 'chatrm', 'discoverability', 'queue', 'codex-appserver', 'live-chats', 'alerts', 'phone', 'phone-extras', 'permit', 'ask', 'phone-down', 'phone-board', 'watcher', 'commands', 'phone-setup', 'overlay-data', 'overlay-windows', 'console', 'overlay-mac', 'overlay', 'auto-continue', 'host-work'
$chatMissing = @($chatParts | Where-Object { -not (Test-Path -LiteralPath (Join-Path (Join-Path $PSScriptRoot 'src') "$_.ps1")) })
if ($chatMissing) {
    # before any part loads: half the commands would fail in ways that
    # point nowhere near a missing file
    Write-Host "  Charlie-and-the-chat-factory: missing from $(Join-Path $PSScriptRoot 'src'): $(@($chatMissing | ForEach-Object { "$_.ps1" }) -join ', ')" -ForegroundColor Yellow
    Write-Host '  the script is this file and the src folder beside it - copy both, or run the installer again' -ForegroundColor DarkGray
    Remove-Variable chatParts, chatMissing -EA SilentlyContinue
    return
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
# to load. All 25 are looked for above, so a broken copy still shows.
if (-not $env:CHATQ_ALLPARTS) { $chatParts = @($chatParts | Where-Object { $_ -notin 'overlay-windows', 'console', 'overlay-mac' }) }
foreach ($chatPart in $chatParts) { . (Join-Path (Join-Path $PSScriptRoot 'src') "$chatPart.ps1") }
Remove-Variable chatParts, chatMissing, chatPart -EA SilentlyContinue
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


# a shell opened after the delete picks the watch back up
if (Test-Path -LiteralPath $script:ChatTombPath) { Start-ChatGhostWatch }

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
    $Host.Name -in 'ConsoleHost', 'Visual Studio Code Host') {
    # A shell opening after a reboot picks the watcher back up. Cheap when the
    # queue is empty: one directory listing. In a child scope, so turning
    # StrictMode off here leaves the user's own setting alone.
    & {
        Set-StrictMode -Off
        try {
            if ((Test-Path -LiteralPath $script:ChatqQueueDir) -and -not (Test-ChatqWatcherAlive)) {
                $n = @(Get-ChatqJobs | Where-Object { $_.state -eq 'queued' }).Count
                if ($n -and (Start-ChatqWatcher)) { Write-Host "  chatq: $n queued - watcher started" -ForegroundColor DarkGray }
            }
            # reply.listen always: listening all the time starts again with a shell
            $null = Start-ChatqReplyStanding
            # and one listening for a reply to a phone alert still out there
            if (-not (Test-ChatqWatcherAlive) -and (Test-ChatqReplyOpen) -and (Start-ChatqWatcher)) {
                Write-Host '  chatq: listening for phone replies - watcher started' -ForegroundColor DarkGray
            }
        }
        catch {}
        # The overlay, the same way back after a reboot: on by default on
        # Windows, since a chat clicked in it opens as a tab; chatoverlay
        # -AutoStart off keeps it to when it is asked for. One file read and
        # a lock check when it is running already.
        try {
            if ((Start-ChatOverlayAuto) -eq 'started') { Write-Host '  chatoverlay started' -ForegroundColor DarkGray }
        }
        catch {}
    }
}
