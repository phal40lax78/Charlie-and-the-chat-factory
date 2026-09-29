# claude-codex-chat-manager one-line installer
#
#   iex (irm https://raw.githubusercontent.com/phal40lax78/claude-codex-chat-manager/main/install.ps1)
#
# Downloads the tool - claude-codex-chat-manager.ps1 and the src/ folder it loads -
# to a real folder and dot-sources it from there. It has to reach disk first:
# the script finds data/ and the line it writes into $PROFILE from its own file
# path, and the background watcher it starts re-loads the file by that path -
# running it out of memory leaves all three empty.
#
# One zip of the repo, never the files one by one: raw.githubusercontent.com
# caches each file on its own for minutes after a push, so files fetched singly
# can come from two versions - and a loader from one with parts from the other
# fails in ways that point nowhere near the cause. A zip is one commit.
#
# Under iex this runs in the caller's scope, which is the point - the dot-source
# at the end then lands the commands in the session you typed from. That also
# means it must not set $ErrorActionPreference or leave variables behind, and it
# cannot wrap itself in & { }, which would dot-source into a scope about to go.
#
# Set CHAT_MANAGER_DIR beforehand to install somewhere other than
# ~/Tools/claude-codex-chat-manager.

$chatManagerUrl = 'https://github.com/phal40lax78/claude-codex-chat-manager/archive/refs/heads/main.zip'
$chatManagerDir = if ($env:CHAT_MANAGER_DIR) { $env:CHAT_MANAGER_DIR } else { Join-Path (Join-Path $HOME 'Tools') 'claude-codex-chat-manager' }
$chatManagerFile = Join-Path $chatManagerDir 'claude-codex-chat-manager.ps1'
# in data/, like every file the tool writes, and gone once copied out
$chatManagerTmp = Join-Path (Join-Path $chatManagerDir 'data') 'download'

# an untouched 5.1 may still default to TLS 1.0, which GitHub refuses - add
# 1.2 rather than replacing whatever is already enabled
if ([Net.ServicePointManager]::SecurityProtocol -notmatch 'Tls12') {
    [Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

if (Test-Path -LiteralPath $chatManagerTmp) { Remove-Item -LiteralPath $chatManagerTmp -Recurse -Force -ErrorAction Stop }
New-Item -ItemType Directory -Path $chatManagerTmp -Force -ErrorAction Stop | Out-Null
Write-Host "  downloading claude-codex-chat-manager -> $chatManagerDir" -ForegroundColor DarkGray
Invoke-WebRequest $chatManagerUrl -OutFile (Join-Path $chatManagerTmp 'main.zip') -UseBasicParsing -ErrorAction Stop
Expand-Archive -LiteralPath (Join-Path $chatManagerTmp 'main.zip') -DestinationPath $chatManagerTmp -Force -ErrorAction Stop
# src/ before the file that loads it: stopped between the two, a copy from
# before src/ existed still loads whole, since it reads nothing there
$chatManagerFrom = Join-Path $chatManagerTmp 'claude-codex-chat-manager-main'
New-Item -ItemType Directory -Path (Join-Path $chatManagerDir 'src') -Force -ErrorAction Stop | Out-Null
Copy-Item -Path (Join-Path (Join-Path $chatManagerFrom 'src') '*.ps1') -Destination (Join-Path $chatManagerDir 'src') -Force -ErrorAction Stop
Copy-Item -LiteralPath (Join-Path $chatManagerFrom 'claude-codex-chat-manager.ps1') -Destination $chatManagerFile -Force -ErrorAction Stop
Remove-Item -LiteralPath $chatManagerTmp -Recurse -Force -ErrorAction SilentlyContinue

. $chatManagerFile
chatinstall

Remove-Variable chatManagerUrl, chatManagerDir, chatManagerFile, chatManagerTmp, chatManagerFrom -ErrorAction SilentlyContinue
