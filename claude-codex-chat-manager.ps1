<#
claude-codex-chat-manager - find, delete and queue prompts for local AI chats.

Two tools in one, sharing one index and one way of picking a chat:
  chatrm  - find and delete chat transcripts. Claude Code, Copilot Chat and
            Codex keep every chat on disk and none offers a per-chat delete
            (claude project purge is per-project; archiving only hides).
  chatq   - hold prompts while the usage limit is hit and deliver them when it
            resets. The VS Code panel queues a message sent while Claude is
            working, but one sent while the subscription limit is exhausted is
            refused and dropped. Aim a prompt at any existing chat by title;
            at the reset each chat is resumed in turn, sent its prompt, run to
            the end, and your phone is told how it went.

INSTALL   one line
    iex (irm https://raw.githubusercontent.com/phal40lax78/claude-codex-chat-manager/main/install.ps1)
  or two, with the files already on disk - and the path need not be typed
    . "$HOME\Tools\claude-codex-chat-manager\claude-codex-chat-manager.ps1"
    chatinstall

  To get that first line right without typing a path at all: type a dot and a
  space, then drag the .ps1 out of Explorer and drop it on the window - or
  shift+right-click it there, "Copy as path", and paste. Enter, then chatinstall.

  Point it at the .ps1 itself, never the folder holding it. A folder gives "The
  term '...' is not recognized", because a folder is not a command - the filename
  is the part that gets left off. Quotes only start to matter once the path has a
  space in it, and "Copy as path" supplies them either way.

  The leading dot matters as much as the path does. `. file.ps1` loads the
  commands into the shell you are standing in; `& file.ps1`, or double-clicking
  the file, runs it and throws every command away again as it exits. It notices
  that itself and prints the line you meant to type, so a shell is never left
  silently empty - though a double-clicked window closes too fast to read it.

  Open a new terminal and type chat.

  chatinstall writes the profile line itself - the script knows where it is, so
  the path is only ever typed once. It calls Unblock-File for you on Windows,
  makes the profile if there is none, and backs it up to $PROFILE.bak first.
  Run it again after moving the file: it replaces the old line instead of leaving
  one that loads nothing and says nothing about it. -Force rewrites regardless.
  If even that first line will not run, the execution policy is Restricted -
  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned, once, Windows only.

  This file and the src/ beside it that it loads, no modules, no dependencies.
  Copy the two together: without a part it names what is missing and loads
  nothing. It runs from anywhere - only src/ and data/ sit beside it - but a
  folder of its own that no other tool owns is the one to pick, hence
  ~/Tools/claude-codex-chat-manager above. Not .claude, .codex or .vscode: those
  belong to the tools named after them, which rewrite them on update and clear
  them on reinstall, and would take the index with them. Not a folder shared with
  other scripts either, where a second data/ would land on top of this one.
  Moving it later is fine - move src/ and data/ with it and re-run chatinstall,
  which repoints the profile line rather than leaving a dead one. $PROFILE is per host:
  Documents\WindowsPowerShell for 5.1, Documents\PowerShell for pwsh, and a
  redirected Documents folder moves both - so install once in each shell you use.
  Do not copy data/chat-index.csv - it holds absolute paths from the old machine
  and rebuilds itself on the first search (~30s).

COMMANDS
    chatfind "text" [-Deep] [-All] [-AllProjects] [-Provider codex,copilot]
    chatrm <id|prefix> [...]       unambiguous - deletes outright
    chatrm "<title>" [-Force]      walk the matches, confirm; -Force takes all
    chatrm ... -DropJobs           also drop prompts queued for that chat
    chatrm ... -Archive            put it away instead of deleting it
    chatrestore [<title|id>]       list the archive / bring one back
    chatclean                      ghost chats (no messages, < 64 KB)
    chatproviders / chatindex      what was found / rebuild the index
    chatq <title|id> [-Prompt s]   queue a prompt for that chat; no -Prompt
                                   opens an editor tab to write it in
    chatq <title> -Continue        queue "continue" for a chat the limit cut off
    chatq <n>                      open queued prompt n in the editor
    chatqlist [-Board] [-All]      what is queued, when it sends, what ran
    chatqrm <n|id> [-Force]        drop a job (-Force cancels a running one)
    chatqrun [<n>] [-Now] [-Stop]  requeue n / skip the wait / stop the watcher
    chatqlog <n> [-Raw]            what a run did
    chatnotify -ApiKey k -Device d phone alerts through Join; -Test sends one
    chatoverlay [-Stop] [-Print]   every running chat, and usage, always on top
    chatconsole                    chatq in a window: write, send now, queue,
                                   continue, new chats (Windows)
    chatinstall / chatuninstall    add to, or drop from, your profile
    chat                           cheat sheet

  chatfind emits objects:  chatfind commit | Select Provider,Title,Id,Age

SCOPE
  Titles match chats belonging to the directory you are standing in - Claude by
  its project slug, Copilot and Codex by the folder name - so a sibling repo
  never answers for this one. Those slugs nest (...-src-app is a prefix of
  ...-src-app-Mobile), so the test is exact rather than a prefix, and
  case-insensitive because the drive letter's case varies. Tab is scoped the
  same way, or it would offer chats chatrm then refused to match.
  -AllProjects widens it. Ids skip it - one id is one chat, wherever it lives.
  Standing somewhere that is no project at all narrows nothing.

TAB
    chatrm gitign<Tab>     chatrm 'Gitignore file' (21d) #1/2
    (down)                 chatrm 'Gitignore rules' (5d) #2/2
    chatrm "gitign<Tab>    chatrm 'Gitignore file' (21d) #1/2

  Tab fills in the argument - the whole of it, not the word under the cursor.
  Everything typed after the command is replaced by one quoted title, so
  quoting it yourself changes nothing: a leading " or ' is dropped before
  matching and the title always comes back in single quotes. No quote is left
  to close, and no half-typed word to finish by hand.
  Tab/down next, Shift+Tab/up previous, Enter runs it, Ctrl+Space the full
  list. Prefix match on the whole argument, spaces and all; widens to contains
  when nothing starts with it; hex matches ids. Arrows stay history unless a
  run is live, and editing the line ends the run.
  Opt out: $ChatNoKeyBindings = $true before the dot-source.

  Enter strips "(21d) #1/2" before running - and strips it on any chatrm or
  chatfind line, not only a live run, because it survives an edit. "#1/2" alone
  was a comment and safe to leave; "(21d)" is not, PowerShell would run it.

  The buffer is rewritten because nothing else can be drawn from a key handler:
  PSReadLine's reader already owns the keyboard, so a pane of our own never
  gets a keystroke.

PICKING
  One line everywhere - Tab, one match, several matches all look the same, in
  the same colours (read from PSReadLine, so it follows your theme):
    chatrm 'UI zoom in/out function' (9d) #1/2
    chatrm 'Zoom in/out functions' (3d) #2/2
  Enter deletes what is on screen, at once: no detail dump, no confirmation.
  Esc backs out. Two chats can share a title AND an age - only then does the
  line add the project and size, since nothing else would separate them.

  That is for a title you typed in full. Titles match on substring, so one hit
  is not the same as the right hit - chatrm Haiku matched 'Haiku ChatGPT Opus
  Astra'. Typing part of a title is a search, and a search must not delete, so:
  Enter fills the match in the way Tab would rather than running, and pressing
  it again deletes the title now on screen. Where no key handler can reach -
  a script, -NoProfile, no VT - the same case asks
    delete permanently?  y / Enter = yes,  n / Esc = no
  -Force skips all of it, and an id never goes near this: an id is exact.
  chatclean uses a checkbox list (space toggle, a all) so ghosts go in one pass.
  Redraws use escape sequences: under VS Code's pseudo-console CursorPosition
  is accepted and ignored. No VT -> numbered list and a typed y/N.

GHOSTS
  A chat still listed in the panel is one the window is tracking, and it
  flushes session state to disk when it reloads or closes. That recreates a
  chat deleted minutes earlier as a stub - ai-title, mode, atis-latch, no
  messages, and a brand new creation time, so it is a fresh write and not a
  failed delete. Archived chats are filtered out of that list, never tracked,
  and stay deleted first time.
  That write happens once. After the reload the window rebuilds its list from
  disk and is no longer holding the session, which is why deleting a second
  time always worked. So it is watched for rather than waited out: a
  FileSystemWatcher on newly created .jsonl files takes the rewrite back the
  moment it lands, with no second command to run. The deletion is written down
  too - data/rewritten.txt - as the backstop for shells that were not open at
  the time, swept by the next chat command.
  Either path only removes a file that is still a stub, so resuming that
  session for real ends it. Tombstones expire after 7 days.
  Deleting can also simply fail - Windows will not remove a file another
  process holds open. That prints LOCKED and is not counted as deleted.

SPEED
  Search and completion run off data/chat-index.csv next to this script; a file
  is re-read only on size/mtime change. ~30s first build, ~1.5s after.
  chatindex -Force rebuilds.

PROVIDERS   one entry each in $script:ChatProviders - Discover/Describe/Extras
    claude   <config>/projects/<slug>/<uuid>.jsonl. Title: custom-title /
             ai-title line, else sidecar custom-title.json, else first prompt.
             Extras: sidecar dir, file-history/<id>, session-env/<id>,
             tasks/<id>, debug/<id>.txt, security state, telemetry and todos
             by id, jobs/ by the id in state.json, and plans/<slug>.md when no
             other chat in the project shares the slug.
    copilot  <Code user>/workspaceStorage/<hash>/chatSessions/<uuid>.json, where
             <Code user> is %APPDATA%/Code/User on Windows, ~/Library/Application
             Support/Code/User on macOS and ~/.config/Code/User on Linux.
             customTitle, requests[].message.text. Extras: chatEditingSessions/<id>.
    codex    ~/.codex/sessions/YYYY/MM/DD/rollout-<iso>-<uuid>.jsonl. Title:
             thread_name in ~/.codex/session_index.jsonl, which is the name the
             panel lists; else first real prompt, IDE and AGENTS.md preambles
             filtered.
  CLAUDE_CONFIG_DIR and CODEX_HOME are honoured.

NOTES
  Transcripts are opened FileShare.ReadWrite+Delete. Codex holds every rollout
  open for the life of the window, so a plain read throws on all of them and no
  Codex chat is seen at all. Deleting one a live window still holds fails, and
  is reported LOCKED - close the window.
  Permanent, no recycle bin. Age = last real message; Touched = mtime, which is
  what the GUIs show (titles and resumes bump it). Lists are cached until
  Developer: Reload Window. hiddenSessionIds (the archive) is never touched.
  Windows PowerShell 5.1 or pwsh 7; macOS and Linux need pwsh 7. Only Windows
  holds a file against deletion, so LOCKED is a Windows-only guard - elsewhere
  unlinking a transcript a live window still has open simply succeeds, and that
  window goes on writing to a file no longer on disk.

QUEUE: PICKING THE CHAT   decided when you queue, so you see it while here
  An id is that chat. Otherwise the title is matched in this project first -
  exact, then contains, then every word you typed - and in every project only
  when this one has no match. Nothing matched at all: the candidates are every
  chat in this project. Of several candidates the newest wins - unless others
  were active within 5 hours of it (one limit window), and then the most
  relevant one does: character-bigram cosine of what you typed and the prompt
  against each chat's title and prompts. Pure PowerShell, no model call, the
  same answer every time, Hangul and English alike. A Copilot chat is found
  but refused: no CLI can resume one headless.

QUEUE: WHEN IT RUNS
  A background watcher (one per machine, a hidden PowerShell) reads when the
  limit resets from the record Claude writes into the transcript it cut off
  ("quotaLimits": status rejected, resetsAt), wakes a minute after, and first
  sends a throwaway "ok" that saves nothing - sending the real prompt while
  still limited would plant it, and an error after it, in your chat. Then one
  job at a time, oldest first, each in the permission mode its chat last used,
  with anything that would ask a question auto-denied: nobody is there to
  answer, so that chat is parked as needs-input and the queue moves on.
  "API Error: 529 Overloaded" (any 5xx) is Anthropic's trouble, not a limit:
  the job goes back in the queue and waits on status.claude.com - read every
  minute, resumed the moment Claude Code shows operational again, and tried
  anyway every 15 minutes in case the page lags.

FILES   everything in data/ beside this script, nothing anywhere else
    chat-index.csv                         what search and Tab run off
    rewritten.txt                          tombstones for the ghost watch
    reload-request                         read by the extension in extension/
    open-request                           read by the extension: a chat the overlay asked to show
    queue/<id>.json + "#<n> <title>.md"   one job, its prompt (edit it freely)
    queue/<id>/                            that job's files, copied in
    logs/<id>.jsonl                        the raw run
    logs/jobs.log                          every job event, including removals
    queue.md                               live board - open it, Ctrl+Shift+V
    config.json                            Join key, DPAPI-protected on Windows
    overlay.json                           what the overlay shows, rewritten as it changes
    overlay-state.json                     where the overlay sits, locked or not
    logs/overlay.log                       the overlay's own log
#>

# Bump this in the same commit that changes behaviour - chatinstall compares it
# against data/version.txt to say whether a reinstall actually landed anything,
# and raw.githubusercontent.com serves a stale copy for minutes after a push, so
# "updated" vs "unchanged" is the only way to tell a real upgrade from the CDN
# handing back what you already had. extension/package.json carries the same
# version: the extension installs this copy by it, and extension/build.js
# refuses to pack the two apart.
$script:ChatVersion = '0.10.0'

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
    Write-Host '  claude-codex-chat-manager loads its parts from src/ beside it, so it has to' -ForegroundColor Yellow
    Write-Host '  be loaded from its file:  . "C:\path\to\claude-codex-chat-manager.ps1"' -ForegroundColor DarkGray
    return
}
$chatParts = 'core', 'providers', 'chatrm', 'discoverability', 'queue', 'live-chats', 'alerts', 'phone', 'phone-extras', 'permit', 'ask', 'phone-down', 'phone-board', 'watcher', 'commands', 'phone-setup', 'overlay-data', 'overlay-windows', 'console', 'overlay-mac', 'overlay', 'auto-continue', 'host-work'
$chatMissing = @($chatParts | Where-Object { -not (Test-Path -LiteralPath (Join-Path (Join-Path $PSScriptRoot 'src') "$_.ps1")) })
if ($chatMissing) {
    # before any part loads: half the commands would fail in ways that
    # point nowhere near a missing file
    Write-Host "  claude-codex-chat-manager: missing from $(Join-Path $PSScriptRoot 'src'): $(@($chatMissing | ForEach-Object { "$_.ps1" }) -join ', ')" -ForegroundColor Yellow
    Write-Host '  the script is this file and the src folder beside it - copy both, or run the installer again' -ForegroundColor DarkGray
    Remove-Variable chatParts, chatMissing -EA SilentlyContinue
    return
}
foreach ($chatPart in $chatParts) { . (Join-Path (Join-Path $PSScriptRoot 'src') "$chatPart.ps1") }
Remove-Variable chatParts, chatMissing, chatPart -EA SilentlyContinue

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
    $shown = if ($PSCommandPath) { $PSCommandPath } else { 'C:\path\to\claude-codex-chat-manager.ps1' }
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
