# Deferred

Deliberate deferrals: what was knowingly left as it is, and why. Open
problems - what is still to find out or to do - are in
[FUTURE_WORK.md](FUTURE_WORK.md).

Each entry gives its **Scope** (what is left as it is, and where in the
code), why it was deferred, and **Revisit when** - the trigger that reopens
it - with what closing it would take where that is known. The code it
touches carries a `Deferred: DEFERRED.md "<title>"` comment naming the
entry. A defect that matches an entry here is known and deferred: leave it
unless its trigger is met or the decision is reopened.

## Deliver into a live chat instead of beside it

**Scope:** Prompts still go through the headless run, not into the open chat.
The window shows the run in a live log view, then the chat anew, through
[Invoke-ChatqHandover](src/watcher.ps1).

**Shelved in 0.6.0** in favour of showing the chat fresh: after a headless
run the chat's old process is ended so the next message starts from disk
(spike S29), and the window shows the chat anew - with Reload Webviews
where nothing in it was working, in 0.6.0, and in a tab of its own since
0.7.2. That covers what this was wanted for - a window that shows the run
without a whole reload - while the prompt keeps going through the
headless run, where a permission prompt parks the job, a `CLAUDE.md` edit is
done, and the prompt is yours rather than another session's. Since the
handover (CHANGELOG, Unreleased) the run also shows while it goes: it takes
the chat's tab's place with a live view of its log, and the tab is closed
rather than its process ended. The notes below stay for if a live delivery
is wanted again.

**Why deferred:** a chat open in a VS Code window shows a chatq run only after
a reload (since 0.5.0 one the window takes by itself when you are away).
Delivering the prompt into the open chat would show it running, live, with no
reload at all. Claude Code's cross-session messaging can do that; what its
documentation (code.claude.com/docs/en/cross-session-messaging, read
2026-09-23) settles, and what is left to try:

- **On by default** from Claude Code 2.1.234 on native Windows; every session
  binds an inbox (a named pipe on Windows). The page never mentions VS Code,
  but panel sessions here export `CLAUDE_CODE_MESSAGING_SOCKET`, so they have
  one too.
- **No token needs handling.** A `claude -p` session can send with the
  `SendMessage` tool by the target's name, and with `crossSessionInbound`
  unset, a receiver in any prompting mode (default, auto, `acceptEdits`)
  delivers a message from a sender that does not bypass permissions. The
  raw pipe, and its `CLAUDE_CODE_MESSAGING_TOKEN`, is documented only for a
  session's own child processes, so a SessionStart hook copying tokens into
  `data/` is not needed and is not the way.
- **An idle receiver starts a turn** with the message; a busy one reads it
  between tool calls, which chatq's busy check already keeps it from.
- **It arrives as from another session, not from you.** It cannot answer a
  permission prompt, and the receiving Claude is told never to change
  settings, `CLAUDE.md` or other configuration because another session asked
  — so a queued prompt that edits `CLAUDE.md` could be turned down where the
  headless run does it.
- **Permission prompts wait for you** in the panel, where the headless run
  denies and parks the job.

Spike S28 in TESTING.md (2026-09-24) settled the rest: the relay finds a panel
chat by the `name` its `~/.claude/sessions/<pid>.json` entry carries beside
its `sessionId`, the idle chat starts the turn within seconds, live, and does
ordinary work asked this way — but a message has to say to do it *here*, or
it is read as a request to answer the sender. A `CLAUDE.md` edit is declined
in the chat, as the framing says.

**Revisit when:** If a live delivery into the open chat is wanted again - for
instance when the headless run's parked permission prompts or `CLAUDE.md` edits
become a real cost.

**To close:**
1. Send: the target's name from its registry entry; a relay `claude -p
   --safe-mode --tools SendMessage` with the prompt on stdin, never as an
   argument (`--allowedTools` takes a list and swallows a prompt placed after
   it); the message opening with what chatq is and that the work is to be done
   in this chat, not answered to the sender.
2. Detect the turn's end for the `done` alert and the queue: the receiving
   transcript's own records after the delivered message (`origin.kind` is
   `peer`, with its `msg_id`), since `claude agents` does not list VS Code
   sessions. A limit or a 529 in that turn requeues a continue as it does now.
3. A prompt that edits `CLAUDE.md`, settings or other configuration is
   declined there; say so in the alert, or send those headless.
4. Deliver this way only into a chat live and idle in a window; everything
   else stays the headless run it is now.

## Attachments: what 0.3.0 left out

**Scope:** `-Paste` reads the clipboard on Windows only, a Claude image goes in
as a path rather than a real attachment, and neither CLI reads Office files.

`-Attach` and `-Paste` shipped in 0.3.0. What they do not cover yet:

- **`-Paste` off Windows.** The clipboard is read through Windows Forms.
  **Why deferred:** nothing here runs macOS or Linux (see the CI entry below).
  **To close:** `osascript` on macOS (`the clipboard as «class PNGf»`), and
  `wl-paste` / `xclip -selection clipboard -t image/png -o` on Linux, each
  writing the same `clip.png`.
- **A Claude image as a real attachment** rather than a path Claude Code opens
  with its Read tool. **Why deferred:** spike S18 showed the path route works —
  the model sees the picture — so there is nothing to fix yet. The one way in
  would be `--input-format stream-json`, whose user message can carry image
  blocks: a different runner from the byte-exact stdin one every test holds.
  **To close:** only if a run is ever seen to miss an image the path named.
- **Office files.** Neither CLI reads `.docx` or `.xlsx` natively; each would
  need a script to. **To close:** convert them at queue time (to PDF or text)
  if that turns out to be wanted.

**Revisit when:** When macOS or Linux is run here, if a run is seen to miss an
image its path named, or if Office files turn out to be wanted.

## Answering the reset ask from the phone

**Scope:** The phone's `limited` alert says "answer on the PC" and its page
offers Status alone, sent by [Send-ChatqResetAskAlert](src/phone.ps1). The
reply wire has no act for a multi-chat answer.

**Answering the ask from the phone.** The `limited` alert about it
([Send-ChatqResetAskAlert](src/phone.ps1)) says "answer on the PC", and
its page offers Status alone. **Why deferred:** an answer queues runs
for several chats at once, and the reply wire has no act for that: every
act today names one session or one job. A new act is a change to the
MAC'd wire, the page and [Invoke-ChatqReply](src/phone.ps1), not a
label. **To close:** an act `ask-go` / `ask-leave` bound to the alert's
cut-off keys (carried in the push, as a job number is), checked by the
watcher against the markers in `data/auto/` so a stale or second answer
does nothing, and run through the same
[Invoke-ChatqContinueChats](src/commands.ps1) and
[Save-ChatqAskAnswer](src/queue.ps1) with `-Source phone`; the page's
`buttonsFor` offering **Continue N** and **Leave them** for an alert
that carries keys; tests in `tests/sections/phone.ps1` and
`tests/reply-page-check.js`.

**Revisit when:** When answering the reset ask from the phone is wanted enough
to add a new act to the reply wire, page and reply handler.

## A VS Code notification for the reset ask

**Scope:** The reset ask shows in the overlay, tray, console, toast and phone,
but not in VS Code, which learns of work only through per-chat request files.

**A VS Code notification for the ask.** The ask shows in the overlay,
its tray, the console, a toast and the phone, but not in VS Code, where
you may be looking. **Why deferred:** the extension learns of work only
through request files, each about one chat and one window; the ask is
about several chats in any folders, and which window should say it -
every one, or one - is not settled. **To close:** a request of its own
kind in `data/`, read by every window, shown by one; **Continue** and **Leave them**
buttons running `Complete-ChatqResetAsk` through the tool folder's loader;
checks in `tests/extension-check.js`.

**Revisit when:** When it is settled which window should show a cross-chat ask,
or if users miss the ask while in VS Code.

## A click on the macOS notification for the reset ask

**Scope:** The macOS notification opens Script Editor on a click, since it
comes from `osascript`; its text points at the `CQ` menu
([Update-ChatOverlayMacAsk](src/overlay-mac.ps1)).

**A click on the macOS notification.** It opens Script Editor, since the
notification comes from `osascript`, so its text points at the `CQ`
menu instead ([Update-ChatOverlayMacAsk](src/overlay-mac.ps1)). **Why
deferred:** a notification that runs something on a click needs an app
bundle of its own, and the Mac panel has never run. **To close:** after
S24, `NSUserNotification` (or `UNUserNotificationCenter`) from the JXA
panel, its click opening the menu.

**Revisit when:** When the Mac panel has run (S24) and a click that opens the
menu is wanted.

## The tray's ask items while the menu is open

**Scope:** The tray items and the keys a click answers for keep what the menu
showed when it opened ([Update-ChatOverlayAsk](src/overlay-windows.ps1)); a
chat joining the ask meanwhile waits for the next ask.

**The tray's items while the menu is open.** They, and the keys a click
answers for, keep what the menu showed when it opened
([Update-ChatOverlayAsk](src/overlay-windows.ps1)); a chat that joins the
ask meanwhile waits for the next ask. **Why deferred:** a menu that
changes under the pointer could answer for a chat never shown. **To
close:** only if S41 shows it matters: put the menu in step as it opens.

**Revisit when:** Only if S41 shows that a chat missing from an open menu
matters.

## A reply with no tap in the browser

**Scope:** A reply link only fills the box; the user must tap Send, since the
page holds the phone's key. See [prefill](docs/reply.html) and
[Start-ChatqReplyPairing](src/phone.ps1).

**Why deferred:** 0.9.0 shipped the cheap half: an alert's link takes
`&text=`, the page puts it in the box ([prefill](docs/reply.html)), and
README's Tasker recipe turns a notification's reply field into one tap on
**Send**. The tap stays, on purpose. The page holds the phone's key, an
alert's id is no secret, and anything can open a link; a link that sent by
itself would send with the phone's key whatever its opener meant. The tap
on Send is the consent, and nothing else on the phone can give it.

**Revisit when:** Only if the one tap turns out to be the part people skip.

**To close:** sealing outside the page, in a Tasker JavaScriptlet with the
page's wire format - byte for byte, held to
`tests/fixtures/reply-vector.json`. That needs a key Tasker can read: a
second, readable copy of the phone's key, so a pairing of its own
([Start-ChatqReplyPairing](src/phone.ps1)) rather than the page's key
copied out, with its own refusal when Tasker's store is read by another
app. Worth it only if the one tap turns out to be the part people skip.

## The reply page on an origin of its own by default

**Scope:** The reply page is served from the project's shared github.io site,
so other pages of that account share its origin. Users can serve their own copy
via [Set-ChatqNotifyConfig](src/phone.ps1).

**Why deferred:** the page is served from
`https://phal40lax78.github.io/Charlie-and-the-chat-factory/`, and every project
page of that account is the same site to a browser: a script on another of
them, opened in the phone's browser, could use the phone's key - not copy
it, since it will not export, but post replies with it. An origin of its
own means a custom domain or a GitHub account or organisation just for the
page, which the project does not have. `chatnotify -ReplyPage` lets a user
serve a copy from their own
([Set-ChatqNotifyConfig](src/phone.ps1), `ReplyPage`).

**Revisit when:** When the project gets a domain or a GitHub account or
organisation that can serve the page alone.

**To close:**
1. A site used for nothing else - a `<name>.github.io` of its own, or a
   domain - serving `docs/reply.html`.
2. `$script:ChatqReplyPage` in [src/phone.ps1](src/phone.ps1) pointed at
   it.
3. The phone keeps its key per site, so every phone pairs again. The
   release says so, and [Get-ChatqPhoneStatusText](src/phone.ps1) says so
   while the phone was paired on the old site.

## Live alerts without the Windows overlay

**Scope:** Alerts about chats you run yourself come only from the Windows
overlay's collector, [Update-ChatqLiveAlerts](src/phone.ps1). The macOS
collector never sends and Linux has none.

**Why deferred:** the alerts about the chats you run yourself come from the
Windows overlay's collector ([Update-ChatqLiveAlerts](src/phone.ps1)),
which reads every chat's state anyway. The macOS collector runs the same
pass but never sends: only the Windows host sets `WantPhone`, since the Mac
panel has never run (S24 in TESTING.md). There is no overlay on Linux.

**Revisit when:** When the Mac panel has run (S24), or if alerts without the
overlay are wanted on other systems.

**To close:**
1. macOS: after S24, set `WantPhone` on the Mac host, and check the
   sender's launch there ([Get-ChatqOutboxLaunch](src/phone.ps1) starts the
   PowerShell it runs in off Windows).
2. Or, with no overlay at all: Claude Code's own hooks - `Notification`
   when a chat waits on you, `Stop` when a turn ends - calling a small
   chatq command that writes the outbox file. They work on every OS, but
   fire whether or not you are away, so the hook needs the away check
   ([Test-ChatqUserAway](src/alerts.ps1)), and they go into the user's
   Claude settings, which chatq has never written.

## A console on macOS

**Scope:** The console exists on Windows only. The Mac panel has no console
window.

**A console on macOS.** **Why deferred:** the Mac panel has never run
(S24), and a Cocoa window with text entry, drag and drop and a pasteboard
in untested JXA would only add to that. **To close:** after S24, an
`NSWindow` from the same host, or the console as a small local web page
the pwsh host serves on 127.0.0.1.

**Revisit when:** When the Mac panel has run (S24) and passed.

## Answering a permission prompt from the console

**Scope:** A run that asks is parked as `needs-input` or asks the phone. The
console's details pane cannot answer it.

**Answering a permission prompt from the console.** A run that asks is
parked as needs-input, or since 0.9.0 asks the phone. **Why deferred:**
see "Answering a permission prompt at the PC", below. **To
close:** the same bridge ([src/permit.ps1](src/permit.ps1)), answered
from the console's details pane.

**Revisit when:** If owners want to answer prompts from the console, using the
same permit bridge.

## Run reply streamed into the console

**Scope:** The console shows a run's reply only once the run ends.
[Get-ChatqLogEntries](src/commands.ps1) can read a live log.

**The reply as it streams.** The console shows a run's reply once the run
ends. **Why deferred:** reading a log the watcher holds open works now
(`Get-ChatqLogEntries` shares with the writer), but redrawing the details
pane every pass costs the window's thread while a long run writes
megabytes. **To close:** read only what the log grew by since the last
pass, and append it to the pane rather than redrawing it.

**Revisit when:** When the pane can append only what the log grew by, instead
of redrawing it.

## A place of its own for the console

**Scope:** The console grows from the panel's corner each time and drops saved
x and y. [Get-ChatConsolePlacement](src/console.ps1) places it.

**A place of its own.** The old console window kept where it was; as the
panel's mode it grows from the panel's corner each time
([Get-ChatConsolePlacement](src/console.ps1)), and an older
`console-state.json`'s `x` and `y` are dropped as it is read
([Read-ChatConsoleState](src/console.ps1)). Maximize is back, as a
header button ([Set-ChatConsoleMax](src/console.ps1)). **Why deferred:**
"in the panel's place" was the ask, and a place of its own would undo
it. **To close:** only if asked for: keep `x` and `y` again and let
[Enter-ChatOverlayConsoleMode](src/overlay-windows.ps1) place it there
when they are on a screen.

**Revisit when:** Only if asked for: then keep x and y and place it there when
on a screen.

## Windows' own maximize on the console

**Scope:** Win+Up sets `WindowState` to `Maximized`, which covers the taskbar
and is not kept. The header's button maximizes by hand instead
([Set-ChatConsoleMax](src/console.ps1)).

**Windows' own maximize.** Win+Up, or the taskbar button's menu, still
sets `WindowState` Maximized, which on a frameless see-through window
covers the taskbar, is not kept as `max`, and leaves the header's
button reading Maximize - the button maximizes by hand to the working
area, and clicked then it first undoes Windows' own, so its Restore
gives back the size the console had, not the full screen.
**Why deferred:** not seen asked for; the
button and a double-click on the header cover it. **To close:** answer
`WM_GETMINMAXINFO` with the working area while the console shows, or
turn a `StateChanged` to Maximized into
[Set-ChatConsoleMax](src/console.ps1).

**Revisit when:** If someone asks for Windows' own maximize to work on the
console.

## Resizing the console from every edge

**Scope:** Only the bottom-right grip resizes the console. The window has no
frame for Windows to size it by.

**Resizing from every edge.** Only the grip at its bottom-right corner
resizes it. **Why deferred:** the panel's window is see-through and has
no frame (`AllowsTransparency`, `WindowStyle` None), which WPF cannot
change once the window exists, so there is no border for Windows to
size it by; the grip was enough to size it. **To close:** a
`WindowChrome` with a `ResizeBorderThickness` set as the console mode
starts and cleared as it ends, or a hit test of our own answering
`WM_NCHITTEST` near the edges.

**Revisit when:** If the corner grip proves too little and someone asks for
edge resizing.

## A reload on the overlay: what it leaves out

**Scope:** The overlay answers chatq's reload questions only. The update
notice, Show it and plain notices stay in VS Code; macOS shows a line, not a
chip. See [askReload](extension/extension.js).

**Why deferred:** the overlay shows chatq's own reload questions - after a
delete, an archive or a queued run, and the window's check before one
([askReload](extension/extension.js)) - since those follow what the user
just did from the overlay or a queued run, and a missed one leaves a chat
list that lies. Three stay in VS Code alone:

- the notice a new version of the extension brings (**Wait for idle**,
  **Reload now**, **Later**; [checkInstall](extension/safe-restart.js)),
  which asks about the extension itself, not a chat, and waits by itself;
- **Show it** and the plain notices with no reload in them;
- on macOS the panel shows the reload as a line with no chip, as it
  shows the reset ask, since the Mac panel has no chips at all.

A window answered from the overlay acts within its 2 s poll of
`data/reload-answer/`; one whose extension host hangs never takes the
answer, and the overlay shows the question again 30 s on.

**Revisit when:** If owners want the update notice answered from the overlay,
or once the macOS panel has chips.

**To close:** give the update notice its own `state` in
`data/reload-pending/` with three answers, and the chip three chips; the
macOS panel would need the chip first ("The overlay: what 0.4.0 left
out", in FUTURE_WORK.md).

## Background shells and "safe to reload"

**Scope:** The reload check and chatrm's wait ignore background Bash shells. A
reload or Show it can kill a build.
[Resolve-ChatqLiveAction](src/live-chats.ps1) waits for them on a queued run.

**Why deferred:** the reload check counts workflows and background agents a
chat started that have not reported back, but not a Bash command run in the
background (`backgroundTaskId`). One is as often a dev server or a watcher as a
build, and a server never reports. Counting them would hold the project
"active" for as long as it runs, and `chatrm`'s wait would never return. A
reload still kills a background build with the chat's process. So does
Show it: its tab closed, or `Stop-ChatIdleProcess` after the grace, ends
the chat's process, dev servers and all. Nothing warns. The open chip no
longer ends anything, and the end of a queued run no longer does either.

A queued run now does count them, in its own way
([Resolve-ChatqLiveAction](src/live-chats.ps1)): it waits while the chat's
process still has a background shell under it, 20 minutes from the shell's
start at most, and then goes in beside the chat without the handover, so
its tab - and the server - stay. That bound is the answer to "a server
never ends" for a run; the reload check and `chatrm`'s wait keep leaving
shells out.

**Revisit when:** When shells meant to end can be told from servers, and the
CLI keeps those result fields stable.

**To close:** tell the two apart. A shell the model started with a timeout, or
one that moved to the background after its timeout ran out (`timedOutAfterMs`
in its result), is meant to end, so it could count. One started with
`run_in_background` and no end in sight would not. Before relying on that,
check the CLI keeps those fields stable. For the ending itself, a chat's
process with child processes other than its MCP servers could count as
`held` - once MCP servers can be told from shells the model started.
Since the overlay began showing background shells, the second half is
partly solved there: [Get-ChatShellChildCount](src/overlay-data.ps1)
counts the shells straight under the chat's process - Claude's Bash tool
starts `bash.exe` for each command, where MCP servers are node, python,
npx or cmd - from Windows' Toolhelp32 list, a millisecond where a WMI
query took 0.4 s, and the overlay counts no more open shells than that. A
server started through `bash` would pass for one; the command line (every
Bash call sources `shell-snapshots/snapshot-*`) would tell them apart, but
only WMI gives it. What is left is the first half - whether a reload should
wait on a shell at all.

## Deletes and new chats through Reload Webviews

**Scope:** A delete, an archive and a new chat still reload the whole window.
Reload Webviews is not used for them.

**Shelved** with Reload Webviews itself. 0.6.0 showed a queued run's chat
with it; on 2026-09-25 it left two views each resuming one chat with a
process of its own, and since 0.7.2 a queued run's chat opens in a tab
instead (CHANGELOG, 0.7.2). The notes below stay for if it is wanted again.

**Why deferred:** a delete, an archive and a new chat still reload the whole
window. Nothing has shown that Reload Webviews rebuilds the chat history -
it might keep a deleted chat listed - and the processes it restarts might
write a deleted chat back as a stub.

**Revisit when:** If Reload Webviews is wanted again and S30 item 17 shows it
drops deleted chats with no stub written back.

**To close:** S30 item 17 in TESTING.md, and a way round the second view
above. If the history drops a deleted chat with no stub written back, and
`claude-vscode.editor.open` shows a chat the list does not have yet, move
`deleted`, `archived` and `new` requests over.

## A busy judgement per window

**Scope:** A multi-root window, or one on a parent folder, always asks before
showing a queued run's chat. [Test-ChatWindowExact](src/live-chats.ps1) guesses
from window titles.

**Why deferred:** chatq judges a folder, not a window, so a queued run's chat
is shown without asking only in a window on exactly that one folder. A
multi-root window, or one on a parent folder, always asks, and the overlay's
chip does not bring such a window forward (`Test-ChatWindowExact` guesses at
it from window titles).

**Revisit when:** When a multi-root window should act on
[Get-ChatHostWork](src/host-work.ps1)'s per-host judgement instead of asking.

**To close:** `hostPids` already names the `Code.exe` behind each window's
Claude processes (S30 item 12 checks it is the extension host). Judge busy
over the chats whose process has that parent, and any window where none of
its own chats is working can show the chat unasked, whatever its folders.
Since 0.9.0 that judgement exists: [Get-ChatHostWork](src/host-work.ps1)
lists one extension host's chats and what keeps each working, and the
extension already looks at it before every reload
([guardReload](extension/safe-restart.js)). What is left is letting a
multi-root window act on it where it now asks.

## Continue the chats a reload stopped

**Scope:** Edge cases in noting and offering the chats a reload cut off: cause
wording, portable VS Code logs, timing. Also Windows only. See
[Get-ChatHostEndCause](src/host-work.ps1).

Built (README, "When a reload cut chats off";
[docs/auto-continue-spec.md](docs/auto-continue-spec.md)): every look the
extension runs before a reload leaves a note of the chats at work
([Save-ChatHostWorkNote](src/host-work.ps1)), and so does the Windows
overlay's own pass, for every window whose chats work
([Update-ChatHostWorkNotes](src/host-work.ps1)) - so a window that runs
out of memory, crashes, or reloads by any button leaves one too. Once the
host is gone the overlay offers what it cut off through the reset ask with
the reason `restart` ([Get-ChatRestartCutOffs](src/host-work.ps1)), worded
by why it went as VS Code's `main.log` tells it
([Get-ChatHostEndCause](src/host-work.ps1)). A reload's chats are always
asked about, never continued by themselves, even with `autoContinue` on -
a reload may have stopped what you meant to stop. Those out of memory or
crashed are continued with no ask only under `autoContinueCrash`, off by
default ([Invoke-ChatqCrashContinue](src/overlay-data.ps1)).

**Why deferred:** what is left, each small and none seen yet:
- **A window closed by hand mid-turn** reads as a restart, and is offered
  as `VS Code restarted`: [Get-ChatHostEndCause](src/host-work.ps1) only
  knows out of memory and crashed. Closing it takes the log lines VS Code
  writes for a window closed on purpose, checked against a real close,
  and a cause of their own that the ask leaves out.
- **Only Code and Code - Insiders' logs are read**, in `%APPDATA%`. A
  portable VS Code keeps its logs in its own `data/user-data/logs`, and
  one started with `--user-data-dir` wherever that points, so their
  windows' chats are offered as restarted whatever took them: at once
  where there is no log to read, after the full 30 s where an installed
  VS Code's logs are there too, as their line never comes. Closing it
  takes the user data folder of the VS Code that runs the host, found
  from its process.
- **Two windows that go together may swap causes.** A renderer's
  `renderer process gone` line names no window, so the one gone within
  10 s before a host's exit is taken for that host's. Most likely both
  ran out of memory anyway, as on 2026-10-14. Where more hosts exited in
  the 10 s after such a line than there are lines - a window closed just
  after another ran out of memory - neither is known, and both are
  offered as restarted: asked about, never continued by themselves. The
  hosts are counted 5 s past those 10 s, for an exit VS Code writes late;
  one written later still is missed, and one of the two windows - the
  closed one, at worst - reads as out of memory. Closing it takes
  something that ties a renderer's line to its window, which `main.log`
  does not write.
- **A workflow started by a turn that ended seconds before its window
  went** may not be offered. A chat whose last message is a finished
  answer is read for background work only when its note says
  `background` ([Get-ChatRestartCutOffs](src/host-work.ps1)), and the
  overlay notes that a pass after the turn ends. Reading every such
  chat's whole transcript instead would hold up the Windows panel, whose
  thread runs the look, for each long chat a window stopped. Closing it
  takes that read off the panel's thread.
- **A log more than 30 s behind, or a host that exits more than 10 s
  after its window's renderer, reads as a restart.** A window's chats
  wait while the log is not sure ([Get-ChatHostEndCause](src/host-work.ps1)
  says `pending`), up to 30 s from `goneAt`; past that they are offered
  as restarted, and a cause found later reaches the row but not the
  balloon or the phone, which went out once. A renderer's line counts
  for a host's exit within 10 s after it: eight hosts, from the three
  times windows ran out of memory here, exited 1.3 to 6 s after (S51 in
  TESTING.md). A longer wait would hold every such window's ask that
  much longer, and a wider window would take more reloads just after
  another window's crash as that window's. Closing it takes a longer
  wait or a wider window, once a log is seen slower than that.
- **Work an earlier turn left running, when you stop a later one,** is
  not offered: a chat whose last message is your Stop offers nothing
  ([Test-ChatStoppedByHand](src/queue.ps1)), whatever is still out. That
  keeps out the workflow of the turn you stopped, which Claude Code
  2.1.291 lets run on past a Stop, at the cost of one a turn before it
  started and you never stopped. Closing it takes the time the stopped
  turn began - its prompt's record - so only work started since is left
  out.
- **A log that never names the host's exit** - VS Code's own process
  ended from Task Manager - holds that window's chats the full 30 s too,
  counted from the `goneAt` the overlay's own pass writes. Closing it
  takes looking for the VS Code process that writes the log: with it
  gone, no line is coming.
- **A crash continue's 10 minutes count from when a look first found the
  host gone** (`goneAt`), not from its exit in the log. An overlay that
  went down with VS Code and starts again later continues what an older
  crash cut off, up to the note's 12 hours. Closing it takes the host's
  exit time back from [Get-ChatHostEndCause](src/host-work.ps1), kept in
  the note beside `cause`.
- **A note of an earlier process with the same pid** holds off the
  overlay's notes for the new host until it is answered or 12 hours old:
  notes are named by pid alone. Closing it takes the host's start in the
  file name, which the extension's look writes too.
- **The memory balloon and the ask's share the tray.** Windows shows one
  balloon at a time, so one shown in the same pass replaces the other;
  the panel's note and the log keep both. Closing it takes holding the
  second balloon back until the first has had its few seconds.
- **A turn begun a few seconds before its window went** may not be noted:
  the overlay's live list is up to 10 s old. A note from the update
  notice's look is likewise only as fresh as that look, where no overlay
  runs. Closing it takes noting a turn as it starts - from a Claude Code
  hook on each prompt - rather than at the overlay's next look.

It is also Windows only. A window's chats are told apart by walking each
`claude` process up its parents to the extension host
([Get-ChatHostWork](src/host-work.ps1)); off Windows
[Get-ChatProcessTable](src/overlay-data.ps1) has no parents to give, the
look is never `Known`, and [Save-ChatHostWorkNote](src/host-work.ps1)
removes the note instead of writing one. So on macOS nothing is ever
offered, and the Mac menu's restart wording never shows. Closing that
takes a per-host process chain on macOS - `ps -o pid=,ppid=,lstart=` for
every process, read into the shape `Get-ChatProcessTable` returns - so
`Get-ChatOverlayProcessChain` reaches the extension host there too.

**Revisit when:** If one of these gaps is seen in use, or an owner asks for an
automatic mode for a reload's chats (`autoContinueRestart`).

**To close:** each item above says what it takes. An automatic mode for a
reload's chats would need a setting of its own (`autoContinueRestart`),
asked for by an owner first.

## An update loaded without a reload

**Scope:** An update of chatq loads by reloading the window
([restart](extension/safe-restart.js)), which also reloads UI and webviews.

**Why deferred:** since 0.9.0 an update of chatq loads by reloading the
window ([restart](extension/safe-restart.js)), since VS Code's Developer
command Restart Extension Host starts the hosts again from the
extensions it already had and never loads a VSIX installed from the
command line (checked in the 1.108.2 workbench). A reload also reloads
the window's UI and its webviews, where the Extensions view's own
**Restart Extensions** restarts only the hosts - but that runs through
`updateRunningExtensions`, which no command reaches, and TESTING.md S45
step 3 (the new version's log line after the wait) has still to be run by
hand.

**Revisit when:** If a later VS Code adds a command that runs
`updateRunningExtensions`, or S45 shows a restart-only route works.

**To close:** run S45 with the reload; if a later VS Code adds a command
that runs `updateRunningExtensions`, use it in place of the reload.

## Other extensions' updates, and VS Code's own restart

**Scope:** The notice watches chatq's version only. Other extensions' updates
and VS Code's own Restart Extensions end chats unasked, with no note left.

**Why deferred:** the notice watches for a new version of chatq only. A
new Claude Code extension, or any other, loads on the same reload and
ends the same chats, and VS Code's own **Restart Extensions** button asks
nothing. chatq cannot stop a restart it did not start.
The chats such a restart cuts off are not offered to continue either: no
chatq look came before it, so no note was left ("Continue the chats a
reload stopped").

**Revisit when:** If owners want chatq to speak for other extensions, or VS
Code lets an extension veto a host restart.

**To close:** the notice could watch every extension in `extensions.json`
and say the same for any that needs a restart - with the wait the same
wait - once it is clear owners want chatq to speak for other extensions.
The button needs VS Code to let an extension veto or delay a host restart,
which it does not.

## A cheaper look at a window's chats

**Scope:** Each look before a reload starts Windows PowerShell (about 3 s of a
core) and rereads large transcripts whole via
[Get-ChatBackgroundTasks](src/chatrm.ps1).

**Why deferred:** each look the extension takes before a reload starts
Windows PowerShell and loads every part of the script, about 3 s of one
core here (TESTING.md), and a reload that waits takes one every 25
seconds. A chat whose transcript is tens of megabytes is read
whole each time for its background work, as `Test-ChatIdle` reads it; a
look past 20 s counts as not known, and the wait never ends on it. Worth
it for a wait someone asked for; not for anything that runs all the time.

**Revisit when:** If the look's cost shows up for waits people use, then keep
one PowerShell alive for the wait.

**To close:** keep one PowerShell for the length of a wait, fed a line per
look, and give `Get-ChatBackgroundTasks` a cache there by path, size and
write time that reads only what was appended - the overlay's
`Update-ChatOverlayText` reads transcripts that way. The reading half exists
since the overlay began showing background work:
[Update-ChatBackgroundScan](src/chatrm.ps1) keeps a transcript's open tasks
and how far it has read, and searches each new piece as one string rather
than line by line. The long-lived PowerShell is what is left.

## The console's index stays after it closes

**Scope:** The index's rows and the pool sorted from them stay in memory
after the console's first visit;
[Exit-ChatOverlayConsoleMode](src/overlay-windows.ps1) lets go of the
rest - the jobs, the drawn rows, the shown job's read log.

**Why deferred:** measured 2026-10-14 at 153 chats: the rows 1.7 MB, the
pool 0.5 MB, the jobs 0.85 MB (`[GC]::GetTotalMemory($true)` around each).
The rows are also Get-ChatIndex's own copy - Complete-ChatConsoleIndexRead
puts them there - so dropping the console's reference frees nothing
alone. Dropping both would read the index again on every visit
("reading the chats..." for 0.1 s here, 2 s at 2,000 chats), and the
pool's sort took 1 s on the window's thread at 2,000 chats.

**Revisit when:** If an overlay with thousands of chats shows the index's
memory as a problem after a console visit.

**To close:** drop `$C.Index`, `$C.Pool` and their stamps and
`$script:ChatIndexCache` on exit, sort the pool in the index read's
runspace, and measure an open with 2,000 chats.

## Background work on the overlay: what it leaves out

**Scope:** [Update-ChatOverlayBackground](src/overlay-data.ps1) does not count
killed agents, off-Windows stopped commands, two-process chats, Monitor tasks,
or show work on the phone board.

**Why deferred:** the overlay shows a chat's workflows, background agents
and background commands as work ([Update-ChatOverlayBackground](src/overlay-data.ps1)),
from what 123 transcripts here showed of how each one starts and ends
(CHANGELOG, Unreleased). Some cases had no example to go by, or belong to
other parts:
- **An agent killed part way** leaves its transcript mid tool call and no
  end anywhere, so it reads as working until the chat's process ends. None
  of the 81 background agent starts here ended that way; the eleven runs
  that went unannounced had all finished their turn.
- **Off Windows**, and wherever the process list cannot be read, a command
  counts by the transcript alone: one stopped from the task list reads
  `shell` until the chat's process ends. On Windows the count is of shells
  under the chat's process, and a background agent's own commands are
  shells there too, so while one runs a dead start can still be counted -
  the row is working for the agent anyway, but its words may say
  `background` where `agent` was meant. Matching each start's command to a
  shell's command line would settle it, at the cost of a WMI query.
- **Two processes on one chat** - a window and a terminal - judge from the
  older one's start: an agent the newer one started, killed as that
  process closed mid-turn, is counted until the older one ends too. No
  record names the process that started a task.
- **The unread dot and the phone's `done` alert** come when the turn that
  sent work to the background ends, not when the work does. That turn did
  end, with an answer to read, and the work's own report starts a new turn
  that brings them again.
- **The phone board** lists such a chat under Working with no words for
  what runs: [ConvertTo-ChatqPhoneBoard](src/phone-board.ps1) fills a
  row's `what` for a waiting chat only, and `docs/reply.html` prints it for
  those alone. Both were mid-change for the phone's own work at the time.
- **Claude Code's Monitor tool** and any other kind of background task are
  not counted: none appears in the transcripts here, so their start and end
  records are unknown.

**Revisit when:** When a case appears to test against, such as a killed agent
or a Monitor transcript, or when the phone board work settles.

**To close:** for the agent, a quiet agent transcript under a chat whose
process has no child working for it - once there is a case to test
against; for the command, a look at the processes off Windows (`ps -o
ppid=,args=`); for the dot and the alert, key them on the row's state
rather than the registry's; for the board, `what` from the row's words and
`reply.html` showing it for a working row; for Monitor, a transcript that
has one.

## Ending a chat's process off Windows

**Scope:** Off Windows a VS Code window's claude process is never ended (kept)
and the window is offered a reload instead.

**Why deferred:** the parent check that tells a VS Code window's `claude`
from a terminal's reads the parent through CIM, which is Windows only. Off
Windows the process is never ended (`kept`), and the window is offered a
reload instead.

**Revisit when:** When macOS or Linux runs the panel and a spike shows what a
panel claude's parent is called there.

**To close:** a spike on macOS and Linux for what a panel `claude`'s parent
is called there (`Code Helper (Plugin)` on macOS, most likely), then a parent
lookup through `ps -o ppid=,comm=`.

## A chat no process holds gets no request

**Scope:** A queued run writes no ran request when no window's process held the
chat, so a side bar that cached it shows it stale.

**Why deferred:** a queued run writes a `ran` request only when a window's
process held the chat as the run began. A chat whose process had already
ended - by itself, or with its tab closed - can still be cached in a side
bar, which then shows it stale, and nothing tells that window. 0.5.0 was the
same. The overlay's chip is the way round it by hand: it opens such a chat
in a new tab, loaded from disk.

**Revisit when:** If stale side bar copies of ended chats turn out to bite, and
S33 item 2 shows a tab then loads it fresh.

**To close:** write a `ran` request (`oldProcess` none) after any run into a
chat a window may cache - one whose transcript says `claude-vscode` - and
let the window decide; S33 item 2 in TESTING.md shows whether a tab then
loads it fresh.

## A chat in the side bar gets a second process as a tab

**Scope:** [openTab](extension/extension.js) can open a tab for a chat idle in
the side bar, so it runs in two places; the user is told to close the copy.

**Why deferred:** the chip opens a chat with the Claude Code extension's
`claude-vscode.editor.open`, pinned to a tab ([openCall](extension/extension.js)),
which brings forward a tab that shows the chat or makes a new one, and
never looks at the side bar. A chat idle in the side bar then runs in two
places: two views, and two `claude` processes on one session, each able to
write to it. Nothing in the Claude Code extension's commands (2.1.283)
reaches the side bar's session: none closes, reloads or lists a panel by
session id. `editor.open` with `programmatic: 'honor-preferred-location'`
does show a session in the side bar - when `claudeCode.preferredLocation`
is the side bar and no tab holds it - without rewriting the setting, but
it neither closes nor reloads a copy already there. So
[openTab](extension/extension.js) opens no tab for a chat working in a
process of this window - or of any window, on a Mac, where `hostPids` is
empty - with no one tab of its title here, since the second process would
start mid-turn, and says so. Two tabs of one label count as none, and so
does one tab of a label another chat of its folder would carry
([labelShared](extension/extension.js)). For one idle there it opens the
tab and says the chat now runs in two places, and to close the side bar's
copy. After a run, [perform](extension/extension.js) says the side bar's
copy is stale once the new tab is up.

**Revisit when:** When Claude Code adds a command that shows a session where it
is or closes a panel by session id.

**To close:** a Claude Code command that shows a session where it already
is, or closes a panel by its session id. Short of that, ending the side
bar's process before the tab opens (the chip already judges it `live`)
would leave the side bar on a dead view instead; S30 item 5 in TESTING.md
says whether that is the better trade. A working chat of no title is
never opened, even when a tab of its own shows it, since no tab's label can
be told to be its; the chip opens it once the turn ends.

## Tabs opened before 0.8.1 stay without their header

**Scope:** Tabs opened with `primaryEditor.open` before 0.8.1 stay full editors
with no header until closed and opened again.

**Why deferred:** before 0.8.1 the chip and the picker opened chats with
`claude-vscode.primaryEditor.open`, whose tab is a "full editor" with no
header - no title, **Session history** or **New session** - and no diff
for an edit to approve (TESTING S39). The tab keeps that through a reload,
and the chip only brings a chat's tab forward, so such a tab stays as it
is until it is closed and opened again. From outside, a full editor looks
like any other Claude tab: `TabInputWebview` gives its `viewType` and
nothing more.

**Revisit when:** When the Claude extension says which panels are full editors,
or if old headerless tabs prove common.

**To close:** either the Claude extension says which of its panels are
full editors, or [openTab](extension/extension.js) closes and reopens
every Claude tab once after an update from before 0.8.1 - which would cut
off a chat working in one, so it would have to wait for each chat to be
idle, as Show it closes a stale tab only while the registry reads the
chat idle ([showLive](extension/extension.js)).

## Two chats whose titles share 24 characters

**Scope:** A Claude tab is known only by its label, so chats sharing their
first 24 characters are never taken as sure; a stale tab may need closing by
hand.

**Why deferred:** no command lists panels by session id, and a webview tab
carries only its `viewType`, so a Claude tab is known by its label. Claude
cuts a title over 25 characters to its first 24 and `…`, so two chats that
begin with the same 24 characters carry the same label. Closing a tab ends
that chat's process, so a label that another open Claude tab shares, or
that another chat of the folder would carry, open or not
([labelShared](extension/extension.js)), is never taken as sure.

Show it ([showLive](extension/extension.js)) now brings the chat's own tab
forward by its id - `editor.open` reveals the panel the Claude extension
keeps for that session - and trusts that only as far as the label agrees,
since a tab restored by a reload and not yet revived is revealed by its
label, later; the twin and shared-label rules apply only where the reveal
brought nothing new forward. The run's handover
([onHandover](extension/extension.js)) cannot reveal by id at all -
where the chat has no panel here it would start a second process mid-run -
so it goes by label alone, and such a chat runs beside its tab, said
stale. [showTab](extension/extension.js), for a request with no process
here, goes by label too. The cost is a stale tab to close by hand, for the
chats whose titles begin alike.

**Revisit when:** When Claude Code puts a session id on the tab or adds a
command that reloads or finds a panel by session id.

**To close:** a session id on the tab, or a Claude Code command that
reloads a panel by session id, or that says whether a session has a panel
here without opening one.

## A chat whose label another chat has is refused until renamed

**Scope:** A chat sharing a label with another chat of the folder is refused or
opened beside its tab until one is renamed;
[labelShared](extension/extension.js) has a 1.5 s budget and a 200-transcript
cap.

**Why deferred:** the same blind spot reaches the chip and the picker. A
working chat opens only through its one tab here, and
[openTab](extension/extension.js) and [acceptChat](extension/extension.js)
count that tab as the chat's only while
[labelShared](extension/extension.js) finds no other chat of the folder -
open or long closed - whose title gives the same label. So a chat working
in its own tab is refused as if it worked in the side bar, one idle there
asks **Open here too**, a queued run goes in beside its tab rather than
taking its place, and Show it leaves its stale tab where the reveal by id
brought nothing forward, for as long as the two titles share their first
24 characters. Renaming either chat
clears it. The rule leans the safe way: taken for the chat's, a tab of
the other chat would let a second process start on a working chat, or
close the other chat's tab. It looks in every folder of the window and the
chat's own, and reads the newest 200 transcripts of each (`PICK_CAP`),
once each until they change - what the picker's first listing costs. It
runs in the show queue ([enqueue](extension/extension.js)), where a slow
read would hold up every open and Show it behind it, so the read has
`timing.labelBudget` (1.5 s): one not done by then answers shared, the
safe side, and logs it. So in a large folder a first check that runs out
of time refuses, or leaves a tab, that a finished one would not have; and
a chat older than a folder's newest 200 is never looked at.

**Revisit when:** When Claude Code puts a session id on the tab, which closes
the entry for chats sharing 24 characters too.

**To close:** what closes the entry above - a session id on the tab.
Counting only the chats a live process holds would not do: a chat with no
process can still own the tab of that label - one a Claude Code crash left
dead, one restored by a reload and not yet revived, or one whose process
`"liveIdle": "stop"` ended before a run.

## Tabs with no process: the ones a label cannot name

**Scope:** [openTabChats](extension/extension.js) leaves out untitled or
shared-label tabs, chats older than a folder's newest 200, and chats in another
Claude home; they stay in Recent.

A Claude tab no process holds - one a reload brought back - is an
overlay row only when the window's `data/open-tabs/` file lists it, and
[openTabChats](extension/extension.js) lists a tab only when its label
names one chat for sure. Three kinds stay in Recent as if closed:

- **An untitled tab, and two tabs of one label.** **Why deferred:** a
  webview tab carries no session id, only its label; `Claude Code` is
  every new chat's, and two tabs of one label cannot be told apart. A
  label two chats would give - their titles share the first 24
  characters - is left out the same way, as in the entry above.
  **To close:** what closes the entries above - a session id on the tab,
  from the Claude extension.
- **A chat older than its folder's newest 200.** The label is matched
  among each workspace folder's `PICK_CAP` newest transcripts, read
  `PICK_READS` at a time within `timing.labelBudget`. **Why deferred:**
  the bound keeps a look cheap enough to run every 30 s and on each tab
  change. **To close:** a larger cap for the open tabs alone, read once
  and kept in `titleCache`, if old chats left open turn out to be common.
- **A chat in another Claude home.** The extension reads only its own
  `claudeHome()`, so a tab whose chat a `CLAUDE_CONFIG_DIR` elsewhere
  wrote is never found. **Why deferred:** the window does not know which
  home a restored tab's chat came from. **To close:** with a session id
  on the tab, the registry entry or a scan of the homes the overlay
  reads would say.

**Revisit when:** When the Claude extension gives a session id on the tab, or
if old chats left open turn out to be common.

## A deleted chat's tab: the ones left open

**Scope:** [closeTabsHere](extension/extension.js) closes a deleted Claude
chat's tab only where the window is sure of it, and
[Get-ChatCloseTabs](src/chatrm.ps1) names only the windows whose
`data/open-tabs/` file lists the chat. Left open: a side bar's copy, every
tab the entries above leave out of that file, a tab no longer sure at the
close, a request a window sees late, and Codex and Copilot tabs.

- **The side bar's copy.** **Why deferred:** no Claude Code command
  closes or reloads the side bar's session (2.1.283), as in "A chat in
  the side bar gets a second process as a tab"; the open-tabs file lists
  tabs only. The side bar stays on a chat no longer on disk until it is
  switched or the window reloads, which the delete's reload ask offers.
  **To close:** what closes that entry.
- **Untitled tabs, two tabs of one label, a label two chats share, a chat
  older than its folder's newest 200, and a chat of another Claude
  home.** None is in the window's file
  ([openTabChats](extension/extension.js)), so no request names its window
  and nothing is said. A twin or shared label that comes after the file
  was written, or a chat working at the close
  ([workingNow](extension/extension.js)) - `chatrm` does not ask - leaves
  the tab with one notice instead. **Why deferred:** closing ends the
  chat's process, and a label is all a tab says; closing the wrong one
  ends someone's work. **To close:** what closes "Two chats whose titles
  share 24 characters" and "Tabs with no process: the ones a label cannot
  name" - a session id on the tab.
- **A request seen late.** A window that only sees the request as it
  starts, or past `timing.openMaxAge` (2 minutes), marks it seen and
  closes nothing, says nothing ([closeDeleted](extension/extension.js)).
  **Why deferred:** by then the file the script read is old - the tab
  may have been closed and its label taken by another chat - so the rule
  leans to leaving it, as the reload ask's own age bounds do. **To close:** if stale tabs after a sleep or a slow start turn out
  to be common, check the label against the request's `sessionId` once
  more and close past the bound.
- **Codex and Copilot tabs.** **Why deferred:** the open-tabs file holds
  Claude tabs only ([isClaudeTab](extension/extension.js)), and Codex
  keeps no list another process can read of which threads its panel has
  open (FUTURE_WORK.md, "A Codex thread open in the panel, or a turn that
  ended in an error"), so nothing ties such a tab to a deleted chat.
  **To close:** a list of open threads from either, keyed by id.

`chatarchive` closes nothing: it refuses a Claude chat open in a window
before it moves anything.

**Revisit when:** When the Claude extension gives a session id on the tab or
a command that closes a session's panel or side bar view; when stale tabs
after a delete turn up in use.

## Ultracode and a session-only effort on a tab chatq opens again

**Scope:** [armCarry](extension/extension.js),
[carryArgs](extension/extension.js) and [lostByReopen](extension/extension.js)
carry Ultracode and effort in local windows only; other cases fall back to a
typed notice.

**Closed, in a local window:** Claude Code (2.1.284) keeps Ultracode, and
an effort level set for the session only, in the running process alone,
so a tab chatq closes and opens again - Show it, the chat put back after
a handover, the live view's Open chat - starts a new process without
them. [lostByReopen](extension/extension.js) reads what the chat had, and
[armCarry](extension/extension.js) arms the chat right before chatq's own
open: [installSpawnHook](extension/extension.js) has put a wrapper in
`require('child_process').spawn`, and [carryArgs](extension/extension.js)
adds `--settings {"ultracode":true}` and `--effort <level>` to the one
launch that names the chat as `--resume=<id>`. Nothing goes into the input
box. `chatManager.keepSessionSettings: false` brings back the pre-fill,
one `/effort` in the new tab's input box to send. What was not carried
within `timing.carryWait` (60 s) is said, to be typed
([reportCarry](extension/extension.js)) - among them an open that only
revealed a tab whose process had exited, which starts nothing. An arm a
newer open of the chat took over says nothing: the newer open's word is
the one ([armCarry](extension/extension.js)). A run that ends with the
chat not opened again - asked, or its live view left up - arms the chat
at once for `timing.putBackWait` (30 min), quietly
([armPutBack](extension/extension.js)): picked from another tab's
**Session history** on 2026-09-30, the chat had started without
Ultracode, since only chatq's own open was armed.

What the chat had is what the process being replaced had. A transcript
never says where a process began, so Ultracode switched on in a process
a restart or a Claude Code update ended since read as on to its end -
and was carried, on, into a chat that no longer had it (found with
ac284315: entered under 2.1.283 on 09-28, reopened under 2.1.285 on
09-30). The hook, in from activation, notes every `--resume` launch and
what chatq put into it ([carryArgs](extension/extension.js)), and
[sessionSettingsIn](extension/extension.js) stops at that launch -
[processStart](extension/extension.js), else this extension host's
start. A handover keeps that start in its record, so a reload before
the chat is put back does not move it.

**Why the rest is deferred:**
- **A process whose start is not known is bounded by this window's
  start.** A chat's process in another window, or ended before a reload
  with no handover record to say when it began - the live view's Open
  chat after a reload, a handover recorded by 0.10.2 before this - is
  read from this extension host's start: what it had is not carried, as
  before 0.10.2 it was not either. A carry missed costs a command to
  type; a stale one turns on Ultracode that nobody wanted.
- **A restart inside one window** that Claude Code makes without a
  `--resume` launch - none is known - would not be seen.
- **It rests on Claude Code's SDK internals.** Its launch looks up `spawn`
  on the shared `child_process` module at each call, sets no
  `spawnClaudeCodeProcess` of its own, and puts `--resume=<id>` on the
  command line; the extension passes no `--settings` or `--effort` of its
  own. A version that changes any of these carries nothing, and each
  reopen falls back to the notice a minute later. Nothing tells chatq
  sooner.
- **Remote windows** (WSL, SSH, containers) start claude on the remote
  host, where this extension host's hook never sees the launch. chatq
  runs in the local host (`extensionKind` `ui`), so it plans no carry
  where `vscode.env.remoteName` is set ([carryReaches](extension/extension.js)):
  the pre-fill and the notice at once, as before. A Claude Code forced to
  the local side there (`remote.extensionKind`) would be reachable, but
  keeps the pre-fill too.
- **A later respawn of the same tab** by Claude Code itself - a crash, a
  restart it does of its own - starts without them: the arm is taken by
  the first launch, on purpose, so a chat opened by hand later is never
  given what chatq meant for its own reopen. The one exception is a run's
  end that opened nothing ([armPutBack](extension/extension.js)): any
  launch of the chat here in the next 30 minutes is taken as the tab the
  handover closed coming back. Past that, or in another window or a
  terminal, a chat opened by hand starts without them.
- **A max from elsewhere is carried as if session-only.** A max seen only
  as the level your last turn ran at may have come from
  `CLAUDE_CODE_EFFORT_LEVEL`, an org default or a skill's own effort
  ([sessionSettingsIn](extension/extension.js)); the new process then gets
  `--effort max` it did not need, or more than that one skill wanted.
- A switch made in the tab's effort menu writes nothing to the transcript
  until the next prompt, so a tab closed right after one reads as before
  it: Ultracode switched off there comes back on.
- Whether `/effort` can switch off an Ultracode that came from
  `--settings` is not checked; `--effort` pins nothing - a later `/effort`
  still sets another level.
- On the fallback's pre-fill: whether a typed `/effort <level>` below max
  stays session-only in a VS Code tab is not settled (TESTING, S48 item
  6), so the notice promises only that typed, it leaves Ultracode on.

**Revisit when:** When Claude Code keeps these settings across a reopen or
takes them with the open command, or if remote windows matter.

**To close:** Claude Code keeping them across a reopen, or taking them
with the open (an effort beside the prompt its open command takes) -
then the hook goes. A remote window would need the same from Claude
Code, or a `claudeCode.claudeProcessWrapper` on the remote side, with its
costs: Claude Code then resolves the permission mode itself and skips its
update check, and a broken or moved wrapper stops every chat.

## A tab Claude Code reopens late

**Scope:** Show it holds 30 s after a restart, so a tab Claude Code reopens
later can look like a new one and have its process ended. Lives in
[restartHeld](extension/extension.js) and [tabGrew](extension/extension.js).

**Why deferred:** after an extension-host restart Claude Code reopens a
tab it lost by itself, and such a tab looks the same as a new one chatq
opened. Show it's second check ends nothing on a new tab within
`timing.restartHold` (30 s) of a restart ([restartHeld](extension/extension.js)),
which covers the usual case: a lost tab in front is replaced 5 s after the
start (10 s on a first start). Claude Code's watch for lost tabs has no
deadline, though (2.1.286): a lost tab behind others is replaced only once
it is selected, and one whose chat is still held elsewhere is tried again,
while the window is focused, every 5 s doubling to every 60 s for as long
as it is held. A Show it running as one of those comes up past 30 s reads
it as its own new tab ([tabGrew](extension/extension.js)), and its second
check can end the process behind the tab the open only revealed - the dead
tab again. It needs Show it on that very chat at that moment; none has
been seen.

**Revisit when:** If a late-reopened tab is ever seen ended by Show it, or when
Claude Code logs the end of its lost-tab watch at a level the default log
shows.

**To close:** hold for as long as Claude Code still watches, not a fixed
30 s. Its output channel logs `Stopped checking for Claude Code tabs left
unresponsive by an extension restart` when the watch ends, but at debug
level, which the default log level leaves out; its info lines - `stopped
responding, so its conversation was reopened in a new tab`, `Its
conversation is still in use elsewhere` - are written. Reading Claude
Code's log beside this extension's own (`context.logUri`'s parent) for a
lost tab still waiting would key the hold to it. Failing that, a longer
hold costs only a process left running beside a new tab.

## The unread dot lives in the overlay's memory

**Scope:** The unread dot is kept in memory and cleared only by the chip, a new
turn or session end. Front is judged by program, not tab. Lives in
[Update-ChatOverlayUnread](src/overlay-data.ps1).

**Why deferred:** [Update-ChatOverlayUnread](src/overlay-data.ps1) marks a
chat as it goes from busy or waiting to idle, unless its window is in front
then ([Test-ChatOverlayInFront](src/overlay-data.ps1)), and only three
things clear it: an open from the chip that sent the window its request
([Update-ChatOverlayOpen](src/overlay-windows.ps1)), a new turn, and its
session ending. Reading the chat in VS Code later - its tab brought to the
front, its answer scrolled - clears nothing, since nothing outside the
window knows a tab was looked at. The marks are kept in memory alone, so a
restart clears every dot: marks read back from a file would mean turns
that ended while no overlay watched, which it cannot know. Since 0.10.15
the overlay also restarts itself when it holds more than
`overlay.restartMB` ([Update-ChatOverlayRestartDue](src/overlay-windows.ps1)),
about once a day going by one PC's log, so the dots can go that often
with no update. Windows only:
[Invoke-ChatOverlayCycle](src/overlay-data.ps1) skips the marking where
`WantUnread` is off, as it is on macOS, whose panel has no chip to clear a
dot and reads no window in front to spare a chat one.

- **In front is the whole program, not the tab.** The window in front is
  matched against the chat's process and up to five of its parents
  ([Get-ChatOverlayProcessChain](src/overlay-data.ps1)). One `Code.exe`
  owns every window of its VS Code, and one Windows Terminal every tab, so
  a turn that ends while another window of that VS Code, or another tab of
  that terminal, is in front gets no dot either. A terminal chat whose
  chain matches nothing - a host the walk stops short of - is marked, as
  before. So is one whose console Windows handed off to Windows Terminal
  (its default-terminal setting): the shell's parent is Explorer, or what
  started it, never the `WindowsTerminal.exe` that draws it, so its chain
  never meets the window in front. The parents come from one snapshot of
  Windows' own process list a pass
  ([Get-ChatProcessTable](src/overlay-data.ps1)), taken only when a chat
  has just finished and its chain is not known yet, on the panel's
  thread: some 15 ms, where the `Win32_Process` query it stands in for
  froze the panel 0.2 to 0.5 s; one over 250 ms is still logged. Chains
  are kept for as long as the process lives. **To close:** the tab, not
  the program - only the extension knows which Claude tab is in front, as
  the bullet below needs anyway; and for a handed-off console, the
  Windows Terminal that holds it, found some other way than the parents.
- **The chip clears on its child's word.** The dot goes when the chip's
  child exits 0, 25, 40 or 41: the open request was written for the
  window, whether or not `code` then brought it forward. Not on 10, a chat
  at work, which the window may refuse, nor on 21, a chat Claude Code never
  lists, which the window offers in a terminal - or 26, 42, 43, the same
  with its window not brought forward
  ([Show-ChatFresh](src/live-chats.ps1)). The window may still refuse the
  others - a chat that began to work in its side bar meanwhile is not
  opened - and the dot is gone all the same. **To close:** let the
  extension say what was seen. On `window.tabGroups.onDidChangeTabs`, a
  Claude tab that comes to the front and is surely one chat's
  ([oneTabOf](extension/extension.js)) writes that session id to a file in
  `data/`, and the collector clears the dot for it; the chip's own clear
  then waits on the window's `open` outcome in that file too.

**Revisit when:** When the extension reports which Claude tab is in front, or
if users complain of dots that stay or go wrong.

## Recent and the picker read the transcripts, not the index

**Scope:** Recent, the picker and chatfind can show different titles for one
chat. Lives in [Read-ChatOverlayRecentItem](src/overlay-data.ps1) and
[readChat](extension/extension.js).

**Why deferred:** the overlay's Recent list
([Update-ChatOverlayRecent](src/overlay-data.ps1),
[Read-ChatOverlayRecentItem](src/overlay-data.ps1)) and the extension's
picker ([listChats](extension/extension.js),
[readChat](extension/extension.js)) list and title the transcripts
themselves: each has to be fast on its own, and the picker runs in node,
with no PowerShell to ask. The chat index `chatfind` and `chatrm` use
(`data/chat-index.csv`, the Claude provider's `Describe` in
[src/providers.ps1](src/providers.ps1)) is built on its own schedule by
other rules. It looks for a rename and Claude's title at both ends of a
transcript and takes Claude's title over the sidecar's rename. The picker
now looks at both ends too - the head's 256 KB where the tail has no title
of that kind - but still takes the sidecar's rename over Claude's title;
Recent takes the sidecar first and looks only in the last 256 KB. So a
large chat renamed early can read one title in Recent and another in the
picker and `chatfind`, one renamed only in the panel can read one title in
Recent or the picker and another in `chatfind`, and a chat can be listed
in one before the other.

**Revisit when:** When the three readers are next changed for title rules, or
if a title mismatch is reported.

**To close:** one reader. Keep in the index what all need - the title by
the Claude panel's order, the side and empty flags, the folder and the
write time - and have Recent read the index, synced as it goes; the picker
reads `chat-index.csv` too, or the same rules ported to node. Until then, a
change to one reader's title rules goes to the others - Recent's
[Read-ChatOverlayRecentItem](src/overlay-data.ps1) first, which has not
had the head look the picker got.

## The picker's window, off Windows and by label

**Scope:** Off Windows the picker cannot tell a chat in another window from one
in this window. A tab with no usable label is taken as this window's. Lives in
[acceptChat](extension/extension.js).

**Why deferred:** on Windows [acceptChat](extension/extension.js) reads
each live entry's process once ([procFacts](extension/extension.js), one
Windows PowerShell CIM call) and tells this window's extension host, another
window's, and a terminal apart by the process's parent
([whereOf](extension/extension.js)); another window's chat is handed to it
through `data/open-request` ([handToWindow](extension/extension.js)), as
the chip does. Two gaps are left. Off Windows nothing is looked at - node
has no process table there short of `ps`, which this was not built or
tested on - so a chat in another window still reads as one in this
window's side bar, asks **Open here too**, and one working there is
refused; and an entry's start is checked only against boot
([entryLive](extension/extension.js)), so a pid reused since boot reads
live. And a chat that is here but whose tab cannot be told by its label -
no title, every such tab reading "Claude Code", or a label another chat of
its folder has ("A chat whose label another chat has is refused until
renamed", above) - is taken for this window's side bar.

**Revisit when:** When the picker runs on macOS or Linux, or when the Claude
extension exposes a tab's session id.

**To close:** off Windows, `ps -o ppid=,lstart=,comm= -p <pids>` read into
the same facts, checked on macOS and Linux (see "CI on macOS and Linux").
For the label, the tab's own session id - which the Claude extension does
not expose to another extension today.

## A `claude -p` that is not chatq's

**Scope:** Some readers still count a `claude -p` as a chat: the status line
count, the overlay and phone board rows, and the handover wait. Lives in
[Get-ChatqAlertFooter](src/alerts.ps1) and
[Invoke-ChatOverlayCycle](src/overlay-data.ps1).

**Why deferred:** seen on 2026-09-27 (S38 item 5), Claude Code 2.1.283
registers a `claude -p` in `~/.claude/sessions/` as `kind` `interactive`,
`entrypoint` `sdk-cli`, `status` `busy` while it runs - it gives another
kind only from `CLAUDE_CODE_SESSION_KIND`. A print-mode process is told by
its registry `entrypoint` as well as its kind
([Test-ChatPrintLive](src/chatrm.ps1)) in Show it and the chip
([Show-ChatFresh](src/live-chats.ps1),
[Stop-ChatIdleProcess](src/live-chats.ps1)), a reload's wait
([Get-ChatHostWork](src/host-work.ps1)) and the listing's holds
([Repair-ChatListed](src/live-chats.ps1)); the picker reads the same
([chatState](extension/extension.js)), and so do the overlay's where mark
([Get-ChatOverlayWhere](src/overlay-data.ps1)), the delete chip
([Remove-ChatSessionById](src/chatrm.ps1)), the background-work wait
([Get-ChatqLiveBackground](src/live-chats.ps1)), the phone's live alerts
([Update-ChatqLiveAlerts](src/phone.ps1)) and the watcher's check for a
window that opened the chat during a run
([Invoke-ChatqJob](src/watcher.ps1)).

Still by the kind alone:

- **The status line's count.** [Get-ChatqAlertFooter](src/alerts.ps1)
  counts a busy `claude -p` as a chat working - true of what it does, but
  a queued run is then counted beside its job.
- **The overlay's and the phone board's live chats.**
  [Invoke-ChatOverlayCycle](src/overlay-data.ps1),
  [Get-ChatqBoardScan](src/phone-board.ps1) and
  [Get-ChatqPhoneList](src/phone-board.ps1) keep an `sdk-*` entry as a
  live chat. The overlay marks its row a run, and a queued run may show
  beside its job's row; the board and the phone list show its state as
  the chat's.
- **The handover's own processes.**
  [Invoke-ChatqHandover](src/watcher.ps1) waits for every interactive
  entry of the chat to leave. A `claude -p` there would have held the job
  before the handover began - busy
  ([Resolve-ChatqLiveAction](src/live-chats.ps1)), or print-mode
  ([Stop-ChatIdleProcess](src/live-chats.ps1) `-JudgeOnly`) - so none is
  known to reach it.

What is also unwatched is the other half: that such a run's own transcript
records say `sdk-cli` too. [Get-ChatBackgroundTasks](src/chatrm.ps1)
`-SkipPrint` takes a workflow for a print-mode run's by that stamp; were
someone's own `claude -p` to write another, its leftover workflow would
read as the window's, and hold Show it until it reported back - the safe
side, but wrong.

**Revisit when:** If a queued run is seen doubled beside its job in a count or
row, or when S30 item 18 is run by hand.

**To close:** for each reader above, decide whether a `claude -p` is a
chat there, and filter by `$script:ChatSdkEntrypoints` where it is not -
the overlay's and the board's rows against the job rows they duplicate.
For the records, S30 item 18 - run a `claude -p --resume` into a chat by
hand and read the `entrypoint` its records carry; if it is not `sdk-cli`,
have [Get-ChatBackgroundTasks](src/chatrm.ps1) `-SkipPrint` take that one
too - not through `$script:ChatSdkEntrypoints`, which mirrors Claude
Code's own listing rule ([Get-ChatUnlistedWhy](src/live-chats.ps1)).

## New chats Claude Code never lists

**Scope:** Chats started by + New chat are born by `claude -p`, so Claude Code
never lists them; the terminal is offered instead. Lives in
[ensureListed](extension/extension.js) and
[Get-ChatUnlistedWhy](src/live-chats.ps1).

**Why deferred:** Claude Code leaves a chat out of its lists, and will not
restore it into a tab, when the first `entrypoint` in its transcript's
first 64 KB is an SDK's (S37). Every chat **+ New chat** starts is born by
`claude -p --session-id`, whose first record says `sdk-cli`, and a line
added at the end cannot change the head. The console and a terminal reach
it; the extension offers the terminal
([ensureListed](extension/extension.js),
[offerTerminal](extension/extension.js)). What would list it, each with a
cost:
- **An entrypoint of chatq's own** for that first run
  (`CLAUDE_CODE_ENTRYPOINT`, kept raw by the CLI). But Claude Code turns
  on for any entrypoint outside `sdk-ts`, `sdk-py` and `sdk-cli` what it
  keeps off for them - the Artifact tool, autoDream, the
  `claude-code-guide` agent - sends it in every request's billing header,
  and hands it to every process the run starts. Each would need turning
  off by hand (`CLAUDE_CODE_ARTIFACT=0`, `autoDreamEnabled` false), and
  again after every Claude Code update that adds another.
- **Writing its first lines first:** `claude -p --resume` refuses a
  transcript with no message, and `--session-id` an id already on disk.
- **Rewriting its first record** once the first run ends: the whole
  transcript rewritten, under whatever may have opened it meanwhile.

The rule itself is read from Claude Code 2.1.281 to 2.1.283
([unlistedWhy](extension/extension.js),
[Get-ChatUnlistedWhy](src/live-chats.ps1)), its daemon `sessionKind` half
left out; a later rule may differ, and then the mirror mends too little or
too much.

**Revisit when:** When upstream tells SDK chats apart by something other than
the file's first bytes, or lists them behind a switch.

**To close:** ask upstream for SDK chats to be told apart by something
other than the file's first bytes, or listed behind a switch - the VS Code
webview hard-codes `includeProgrammaticSessions` off. Short of that, the
first option with its switches, re-checked at every Claude Code update.

## The board's handle moves on with a board the chat view was not drawn from

**Scope:** A board or Older chats list landing after a chat view is drawn moves
the handle on, so a PC prompt typed in that window is not refused. Lives in
[Get-ChatqMovedOn](src/phone.ps1).

**Why deferred:** a board handle's time and length move on each time the PC
builds a board or a list that names it ([Register-ChatqPicks](src/phone-board.ps1)),
and a send from the phone is judged from then
([Get-ChatqMovedOn](src/phone.ps1)). The page draws a chat view from the
board it had when the chat was opened; a board asked for just before that,
or **Older chats** tapped on the board, lands after and moves the handle
on while the view stays as it was. A prompt typed at the PC in those few
seconds - under a minute, the page's refresh at most - is then one the
phone never showed, yet not refused.

**Revisit when:** If a prompt typed at the PC is ever seen sent from the phone
unseen, or when the page's send fields are next changed.

**To close:** have the page send the time of the board or list its view was
drawn from with each act (`b`, the board's `ts`), and judge from the older
of that and the handle's; or redraw an open chat view from a board that
arrives, the text kept. Either changes what the page sends, so the page's
field checks and [Receive-ChatqCompose](src/phone-board.ps1) change with it.

## A reply refused as moved on loses its text

**Scope:** A reply to an alert that is refused as moved on loses its typed
text, since the page learns nothing back but the push. Lives in
[Invoke-ChatqReply](src/phone.ps1).

**Why deferred:** an alert's page learns nothing back but the push
([Invoke-ChatqReply](src/phone.ps1) answers only that way), and it drops its
draft once the post went through. When the chat moved on at the PC, the
push carries a link about it as it is now - and the text has to be typed
again there. The board keeps it, since its page waits for an ack.

**Revisit when:** If a lost reply is reported from the phone, or when the alert
page is next reworked.

**To close:** have the alert page wait for an ack under the alert's id on
the down topic, as its whole-answer panel does, keep the draft until the ack
says it went, and offer it again on the new alert's page.

## The overlay on Linux

**Scope:** The overlay draws a panel on Windows and macOS only. On Linux,
`chatoverlay -Print` is the only view of `overlay.json`.

**Linux.** **Why deferred:** nothing here runs Linux (see CI below), and each
desktop has its own tray. **To close:** a GTK or tray-icon renderer reading
the same `overlay.json`. `chatoverlay -Print` is the view until then.

**Revisit when:** When a Linux machine is at hand to run a GTK or tray-icon
renderer that reads `overlay.json`.

## A close on macOS does not hold

**Scope:** With `-AutoStart` on, closing the Mac panel lasts only until the
next shell starts it again. Windows holds a close until the next sign-in; the
Mac has no sign-in reading in [Get-ChatqSignInAt](src/overlay-data.ps1).

**A close on macOS does not hold.** With `-AutoStart on`, the menu bar
item's Quit or `chatoverlay -Stop` closes the panel only until the next
shell starts it again; on Windows a close holds until the next sign-in
([Test-ChatOverlayClosedByHand](src/overlay-data.ps1)). **Why deferred:**
[Get-ChatqSignInAt](src/overlay-data.ps1) reads no sign-in off Windows,
and with none to keep it against nothing is kept - a mark no sign-in
ends would hold for good. The auto start is off by default there, and
there is no Mac here to try a reading on. **To close:** read this login
session's start in `Get-ChatqSignInAt` on macOS (`loginwindow`'s start
for this user, or the console login in `who`/`last`), have
[Start-ChatOverlayMacHost](src/overlay-mac.ps1) keep a stop with
`Set-ChatOverlayClosed` as the Windows host does, and say so as it quits.

**Revisit when:** When a Mac is at hand to try reading the login session's
start, so a close can be kept against it.

## A hotkey on macOS

**Scope:** The Mac panel has no global hotkey. It is driven from its menu bar
item and from `chatoverlay` in a shell.

**A hotkey on macOS.** **Why deferred:** a global key needs Carbon's
`RegisterEventHotKey` or an accessibility permission, neither reachable
cleanly from JXA. **To close:** only if the menu bar item turns out not to
be enough.

**Revisit when:** Only if the menu bar item turns out not to be enough.

## The panel's buttons on macOS

**Scope:** The Mac panel has no button bar, no size edges and no collapsed
view, only its menu bar item and `chatoverlay`'s options. Windows has the bar
in [New-ChatOverlayControlsWindow](src/overlay-windows.ps1).

**The panel's buttons on macOS.** Windows has a bar along the panel's
top strip, always shown with it and taking the mouse there while the rest
lets clicks through - collapse, refresh, settings, then minimize (to the
tray), maximize (the console) and close, its empty part dragging the
panel - and edges to size it by, which stretch it past the open chats
into Recent. The Mac panel has only its menu
bar item, and `-Theme`, `-Opacity`, `-Width`, `-Rows` and `-Refresh` from
a shell; it has no collapsed view. **Why deferred:** the
Mac panel has never run, and more untested Cocoa would not help that.
**To close:** after S24, a second small `NSPanel` over the first's top
strip, the way Windows lays its bar's window over the panel
([New-ChatOverlayControlsWindow](src/overlay-windows.ps1)), shown and
hidden with the panel and taking the mouse while the panel ignores it;
the settings and collapse as menu items, which JXA can already make. The
stretch into Recent waits on Recent there (below).

**Revisit when:** When the Mac panel has been run by hand through checklist S24
and works.

## Recent on macOS

**Scope:** The Mac panel shows no Recent list:
[Start-ChatOverlayMacHost](src/overlay-mac.ps1) sets `WantRecent` off.
`chatoverlay -Print` still lists Recent.

**Recent on macOS.** The Mac panel has no Recent list, since it has no
open chip to open one with, and its collector
([Start-ChatOverlayMacHost](src/overlay-mac.ps1)) sets `WantRecent` off,
so the listing costs nothing there; `chatoverlay -Print` still lists
Recent. **Why deferred:** as the buttons above. **To close:** after S24,
draw it under the rows as Windows does, and turn `WantRecent` back on.

**Revisit when:** When the Mac panel has been run by hand through checklist S24
and works.

## The panel's edges come only after a rest

**Scope:** The panel's size edges show 350 ms after the pointer rests on or
just outside the panel ([Update-ChatOverlayHover](src/overlay-windows.ps1)). A
window's edges show at once.

**The edges come only after a rest.** A window's edges show their arrows
the moment the pointer reaches them; the panel's come 350 ms after the
pointer rests on the panel, its bar of buttons or just outside it
([Update-ChatOverlayHover](src/overlay-windows.ps1)). **Why deferred:**
the panel lets clicks through, so its edges are a window of their own
([New-ChatOverlayEdgesWindow](src/overlay-windows.ps1)), and shown all
the time they would take the clicks and drags meant for the window
under the panel's rim. The bar is shown all the time, and costs the
window underneath the clicks on the panel's top strip; the edges' band
runs round every side and would cost far more. **To close:** only if the
wait shows in use: a shorter rest for the band just outside the panel
than for the panel itself, or the top edge's strip shown with the bar.

**Revisit when:** Only if the wait is seen to bother in use.

## The settings box on a screen too short for it

**Scope:** Where the settings box fits neither above nor under the bar, it goes
to the side with more room and the rest runs off the screen
([Get-ChatOverlayControlsPlacement](src/overlay-windows.ps1)).

**The settings box on a screen too short for it.** The box opens above
the panel where it fits, else under the bar over the rows
([Get-ChatOverlayControlsPlacement](src/overlay-windows.ps1)); where it
fits neither, it goes to the side with more room and the rest runs off
the screen. **Why deferred:** the box shares its window with the bar,
which must stay in the panel's top strip, so that window can no longer
be pushed onto the screen as it was; only a short screen with a tall
panel runs into it. **To close:** a `MaxHeight` and a
`ScrollViewer` round the box's grid
([New-ChatOverlaySettings](src/overlay-windows.ps1)), sized to the room
the placement finds; or the box in a window of its own.

**Revisit when:** If anyone sees the box cut off on a short screen.

## The top edge's cap a little generous

**Scope:** Dragging the top edge, the height cap is a few units more than the
content, as Grow in [Get-ChatOverlayResize](src/overlay-windows.ps1) does not
subtract the +N more line.

**The top edge's cap a little generous on the last hidden row.** As the
top edge is dragged, the panel's height cap is the cap at the start plus
what the travel adds ([Get-ChatOverlayResize](src/overlay-windows.ps1)'s
Grow). It does not take off the `+N more` line that goes as the last
hidden row comes in, so the cap is a few units more than the content.
**Why deferred:** nothing shows it: the panel is sized to its content
and the cap is still bounded by the room on the screen. **To close:**
have [Start-ChatOverlaySizeDrag](src/overlay-windows.ps1) measure that
line, and Grow subtract it when the hidden rows reach none.

**Revisit when:** If the extra height is ever seen on the panel.

## The hover card: what it leaves out

**Scope:** The card a rest on a row brings up
([Show-ChatOverlayCard](src/overlay-windows.ps1)) leaves out three things:
- **A card on macOS.** The Mac panel
  ([Start-ChatOverlayMacHost](src/overlay-mac.ps1)) has none, as it has no
  open chip for one to come with.
- **A Codex job's run.** A Codex rollout is no Claude transcript, so
  [Get-ChatOverlayCardSource](src/overlay-data.ps1) gives its card no file
  to read: the card has the row's state and the prompt the job sends, and
  no call, EARLIER, TASKS or reply.
- **A word in prose after a key word.** A call's words, a question and a
  plan are masked by [Hide-ChatqSecrets](src/permit.ps1), whose key-word
  rule hides the word after one with `pass`, `token`, `secret`, `auth`,
  `cookie` or `session` in it, a space being enough: a question
  `Which session should I close?` shows as
  `Which session *** I close?`.

**Why deferred:** the Mac panel has never run (S24 in TESTING.md), and a
card would be more drawing in untested JXA. A Codex rollout has records
of its own that nothing on the panel reads yet. The masking is the phone
permission page's, tested there, and errs on the side of hiding: a word
lost costs less than a token on the screen.

**Revisit when:** When S24 has run and works; if a Codex job's card is
missed; if a question or a plan on a card reads badly in use.

**To close:** after S24, a card window by the Mac panel under the same
rules; for Codex, a reader of its rollout's newest call and reply, as
[Read-ChatOverlayCardTail](src/overlay-data.ps1) reads Claude's; for
prose, a mode of Hide-ChatqSecrets for a question's and a plan's words
that hides a key word's value only after `:` or `=`.

## The hover card's work on the panel's thread

**Scope:** While a card shows, each 2 s pass runs
[Update-ChatOverlayCard](src/overlay-windows.ps1) on the panel's thread,
and it does more there than it must:
- It builds the card's model
  ([Get-ChatOverlayCardModel](src/overlay-data.ps1)) again, and throws it
  away when its text is the same: some 35 ms a pass on Windows PowerShell
  5.1, most of it [Hide-ChatqSecrets](src/permit.ps1) at some 10 ms a
  call shown.
- It finds the card's source
  ([Get-ChatOverlayCardSource](src/overlay-data.ps1)) again. For a Recent
  row whose transcript is not under its folder's slug,
  [Find-ChatOverlayTranscript](src/overlay-data.ps1) lists every folder
  under `projects/`; a job's prompt file is read again.
- When the transcript grew,
  [Read-ChatOverlayCardTail](src/overlay-data.ps1) reads its end again and
  parses the todo list in it - a line of up to 64 KB - with
  `ConvertFrom-Json`, changed or not. In the review, on 5.1, a read took
  25 to 54 ms for a window of 870 small lines, and 50 to 225 ms for one
  with a 63 KB todo line and a 60 KB prompt in it, the prompt then parsed
  the same way and now read by a regex.

**Why deferred:** it is bounded, and only while a card shows: the pass
comes every 2 s, the pointer has to rest on a row, and the read waits for
the transcript to grow. The collector's own pass costs 40-60 ms there
already ("The collector on a thread of its own", below). The model also
changes with the day - a reply's `14:05` turns `Tue 14:05` at midnight -
so skipping it takes care.

**Revisit when:** If `data/logs/overlay.log`, or use - S53 in TESTING.md
among it - shows the panel stutter while a card is up.

**To close:** keep the model's inputs - the source's path, the tail's
length, the row's state, words and title, the day - and build it only
when one changed; find the source once, as the card comes up; keep the
parsed todo list by its line's offset and length.

## Row tiles on macOS, in -Print and on the phone's board

**Scope:** Only the Windows panel and the console draw a row's tile and
clock. The Mac panel ([Start-ChatOverlayMacHost](src/overlay-mac.ps1)),
`chatoverlay -Print` ([Write-ChatOverlayPrint](src/overlay-data.ps1)) and
the phone's board ([ConvertTo-ChatqPhoneBoard](src/phone-board.ps1)) keep
the dot, the age in the state's words, and the newest prompt. They keep
`idle` and `working` in those words too, which the Windows rows drop for
the tile ([Get-ChatOverlayRowWords](src/overlay-windows.ps1)), and the
Mac panel draws no delete bin on a row
([New-ChatOverlayRowIcons](src/overlay-windows.ps1)) nor turns its name
into the open button ([New-ChatOverlayRowName](src/overlay-windows.ps1)).

**Why deferred:** the ask was the Windows panel's state at a glance. The
Mac panel has never run (S24 in TESTING.md), and new drawing in untested
JXA would only add to that; `-Print` is a console's text, where the
words carry the age as they always have; the board is a page of its own
on a phone, private to its owner, where the prompt helps to pick a chat.

**Revisit when:** When the Mac panel has run (S24), or if the tiles are
wanted on the board.

**To close:** each reads the clock from the rows as they are -
[Get-ChatOverlayRowClock](src/overlay-data.ps1) and
[Format-ChatOverlayRowClock](src/overlay-data.ps1) are pure, and every
row carries `stateWords`, `resetsAt` and `sendAt` - and draws it in its
own way: Cocoa paths from the same segments on macOS, the five
characters as text in `-Print`, and a clock of its own on the board's
page, counting between the board's answers.

## The dark look's ornaments on macOS

**Scope:** The Mac panel ([Start-ChatOverlayMacHost](src/overlay-mac.ps1))
takes the dark look's colours and a gold line round the panel, and no more:
no second line 3 points in, no flourish, no serif on the chats' titles, and
the HUD ground stays as it was, not the wine-black the Windows panel has.

**Why deferred:** the Mac panel has never run (S24 in TESTING.md), and the
line already rests on an untried CGColor bridge, which is why it sits in a
`try`. More drawing in untested JXA would only add to that.

**Revisit when:** When S24 has been run by hand and works.

**To close:** check S24 item 12; draw a second layer 3 points in; draw the
flourish as a `CAShapeLayer` at the top left; set the titles' font (Didot,
else Baskerville, else the system serif, through `NSFont
fontWithName:size:`); and set the wine-black ground as the layer's
background.

## The console's inner line and flourish

**Scope:** The console ([Initialize-ChatConsoleContent](src/console.ps1))
takes the dark look's colours and the outer gold line (the `trim` colour on
its frame's border) only. The panel's second line and its lozenge flourish
([New-ChatOverlayDecor](src/overlay-windows.ps1)) are not drawn there.

**Why deferred:** the ask was the panel's look. The console's header is
full, so a flourish has no room in it, and its lists run close to its edge,
where a second line would meet them.

**Revisit when:** If the console should look like the panel, or its header
gets room.

**To close:** wrap its root grid the way
[New-ChatOverlayDecor](src/overlay-windows.ps1) wraps the panel's stack,
and put the flourish before the header's usage.

## The dark look's serif in a bundled face

**Scope:** The serif on the chats' titles and the setup window's heading is
the system's own - Georgia on Windows, by way of the palette's `serif`
([Set-ChatOverlaySerif](src/overlay-windows.ps1)). No font ships with the
tool.

**Why deferred:** bundling one takes three things. A base64 font in a `.ps1`
that writes it to `data/`, because install copies only `src/*.ps1`. A static
instance cut from the variable file, because WPF has no variable fonts. And
`font-src data:` in the phone page's CSP, with its tests.

**Revisit when:** If the system serif reads wrong at S23 item 23, or a
decorative face is wanted.

**To close:** ship Cinzel (OFL, no reserved name) with its licence beside
it.

## Copilot usage without the GitHub CLI

**Scope:** Copilot's usage line works only with `gh` installed and signed in.
VS Code keeps the plan on disk but not the quota.

**Copilot usage without the GitHub CLI.** Copilot's line needs `gh`,
logged in. **Why deferred:** VS Code writes only the plan to disk
(`chat.setupContext` in `globalStorage/state.vscdb`, e.g.
`free_limited_copilot`), never the quota; the figures come from GitHub
with VS Code's GitHub login, which sits encrypted in VS Code's own secret
store - not something another program should pry out. **To close:** if VS
Code starts keeping the quota snapshot in its state, read it there.

**Revisit when:** If VS Code starts keeping the Copilot quota snapshot in its
state.

## Codex's plan on the panel

**Scope:** The snapshot keeps Codex's plan
([ConvertTo-ChatOverlayUsage](src/overlay-data.ps1)), but neither the Windows
nor the Mac panel draws it.

**Codex's plan on the panel.** Codex's live answer carries the plan
(`free`, `plus`...), and the snapshot keeps it as the usage entry's
`plan` ([ConvertTo-ChatOverlayUsage](src/overlay-data.ps1)), but neither
the Windows panel nor the macOS one draws it. **Why deferred:** a word
more on a line that is already full at 260 units wide, for a fact that
changes once in a long while. **To close:** show it in the usage line's
tooltip, or after the name only in the bars view where there is room.

**Revisit when:** If the plan is wanted on the panel: then in the usage
tooltip, or in the bars view where there is room.

## Naming a command while it runs

**Scope:** While `/compact` runs, the overlay's row says only that a command is
running; the command's text is not on disk until it ends.

**Naming a command while it runs.** While `/compact` runs, the row says only
that a command is running. **Why deferred:** Claude Code writes the command
down once it ends; until then its transcript holds a queue record with no
text, and nothing else on disk names it. **To close:** if a later Claude
Code puts the text in that record, or in `~/.claude/sessions/<pid>.json`,
read it there.

**Revisit when:** If a later Claude Code puts the command text in the queue
record or in the session file.

## More than one Claude account

**Scope:** The overlay reads only the config folder it was started with
(`CLAUDE_CONFIG_DIR`), so it shows one account's rows and usage.

**More than one Claude account.** **Why deferred:** the overlay reads the
one config dir it was started with (`CLAUDE_CONFIG_DIR`). **To close:** an
`overlay.claudeHomes` list, a row group and a usage line per account.

**Revisit when:** If a user needs to see more than one Claude account on the
panel.

## The collector on a thread of its own

**Scope:** The collector pass runs on the panel's own thread, 40-60 ms a pass;
the usage request never blocks.

**The collector on a thread of its own.** **Why deferred:** a pass costs
40-60 ms and the usage request never blocks, so the panel has not stuttered.
**To close:** only if `data/logs/overlay.log` or use shows it does: a
background runspace for the collector, handing snapshots to the UI thread.

**Revisit when:** Only if `data/logs/overlay.log`, or use, shows the panel
stutter.

## A pass allocates some 20 MB a second

**Scope:** Each collector pass allocates much short-lived memory, nearly all
PowerShell's own; the heap does not grow.
[Update-ChatOverlayText](src/overlay-data.ps1) is one of the callers.

**A pass allocates some 20 MB a second, nearly all of it PowerShell's
own.** The CLR's allocation events on the live overlay, three minutes
each side of the change that reads a grown transcript on from its last
whole line (2026-10-07): 1.2 to 1.3 GB a minute on the small object
heap - strings and char arrays two thirds of it, most of the rest
PowerShell's command lookup and parameter binding (alias tables,
parameter sets, variable scopes, pipes) - and some 120 gen 0
collections a minute. Each is short and keeps nothing: the heap does
not grow by it, and the process averaged about 1.4% of one core over
six hours. **Why deferred:** it is what running the passes as script
costs, spread thin: an [Update-ChatOverlayText](src/overlay-data.ps1)
call on a transcript 2 KB longer allocates some 900 KB, its read's own
buffers a few KB of that, and no one call stands out to cut. **To
close:** only if the processor time comes to matter - find the hottest
calls (allocation stacks in PerfView, or a pass timed per function) and
move their loops into C# compiled once, as chatq already does for its
Windows calls.

**Revisit when:** Only if the processor time comes to matter.

## GC flags for the overlay

**Scope:** The overlay and the watcher start with the collector settings
Windows PowerShell 5.1 gives them: no `COMPlus_` variable is set by
[Get-ChatOverlayLaunch](src/overlay.ps1),
[Start-ChatOverlayProcess](src/overlay.ps1) or
[Start-ChatqWatcherProcess](src/watcher.ps1). The overlay's one lever on
its heap stays the full collection every 5 minutes in
[Invoke-ChatOverlayHeapCompact](src/overlay-windows.ps1).

**Why deferred:** measured 2026-10-19, after Word's preview ran the PC
out of memory and 0.10.15 brought the memory restart. 5.1 runs on .NET
Framework 4.8, where `GCHeapHardLimit`, `runtimeconfig.json` and
`DOTNET_` do not apply; what the desktop CLR reads at its start are
`COMPlus_` variables, and of those:

- **`COMPlus_gcConcurrent=0` is read and changes nothing.** `powershell.exe`
  already starts the CLR without concurrent collection:
  `GCSettings.LatencyMode` reads `Batch` with the variable unset, with or
  without `-STA`, and neither `powershell.exe.config` nor the registry
  sets it. `=1` turns it to `Interactive`, which shows the variable is
  read. pwsh 7 reads `Interactive` by default.
- **`COMPlus_GCgen0size` is honoured.** In a fixed loop of 200,000
  8,000-byte arrays, `0x400000` (4 MB) took the gen 0 collections from 175
  to 632, the same in 3 fresh processes of 3; `0x1000000` (16 MB) took
  them to 157, not a quarter, since the CLR goes on tuning the budget
  itself.
- **`COMPlus_GCConserveMemory=5` shows no effect anyone could point to.**
  The gen 0, 1 and 2 counts were the baseline's, and so were private bytes
  and the heap after half of 60,000 2 KB arrays were freed in gen 2 and
  three gen 2 collections ran that do not compact.

Then six 5.1 processes, one per setting, ran the overlay's own passes
side by side for 40 minutes:
[Invoke-ChatOverlayCycle](src/overlay-data.ps1) with `-Peek` every 2 s
against the real transcripts, each with a data folder of its own, no
window, nothing paired, every function that could send, write or start
a process stubbed (none was called), and the real compaction every 5
minutes. Private memory after the compaction, the median of the six
samples from 15 minutes on: baseline 145.8 MB, `gcConcurrent=0` 144.7,
`GCgen0size` 4 MB 144.0, 16 MB 145.9, `gcConcurrent=0` with 4 MB 144.6,
`GCConserveMemory=5` 139.6. Two processes set alike differ by about 1 MB
and 14% in pass time (the baseline against `gcConcurrent=0`, the same
setting in effect). So none reaches the 10 MB a flag had to save to ship.
The 4 MB gen 0 saves 1.9 MB for 25% more pass time (a median of 24.7 ms
against 19.8, 5,178 gen 0 collections against 1,674). `GCConserveMemory`
was 6.3 MB lower throughout (138-142 against 145-149) but in one process,
with no mechanism shown.

The figures are lower than the overlay's own: the processes had no
window, panel, tray or native types, so they settled at about 145 MB
where an overlay settles at 210-260, and only the comparison between
them holds. The load was light - three rows, since few chats ran after
that morning's reboot, with usage fetches, the phone, the ask and
auto-continue off. The watcher was not measured.

**Revisit when:** The overlay moves to pwsh 7, whose collector starts
concurrent and takes .NET's own settings; the climb in FUTURE_WORK.md
"The overlay's heap climbs in steps" is found to be gen 0 or
fragmentation; or the watcher's memory comes to matter.

**To close:** the same side-by-side run on the case that reopens it -
the harness under a busy day, or the watcher - and only a flag that saves
10 MB or more, set on the launching process just around `Start-Process`
so the new CLR reads it, and taken out of the overlay's environment once
it runs, so nothing it starts inherits it.

## Copilot Chat

**Scope:** chatrm can find Copilot chats, but nothing can deliver a prompt to
one, since no CLI resumes a Copilot chat headless.

**Why deferred:** there is no CLI that resumes a Copilot chat headless. chatrm
can find Copilot chats, but nothing could deliver a prompt to one.

**Revisit when:** When GitHub offers a headless way to resume a Copilot chat.

**To close:** a headless resume path from GitHub.

## Copilot chats scoped by the folder's leaf name

**Scope:** Copilot chats are scoped by the folder's last part only, so
`D:\a\app` and `D:\b\app` share a scope
([Get-CopilotWorkspaceName](src/providers.ps1)). Codex chats use the whole
folder.

**Why deferred:** Codex chats are scoped by their whole folder now
([Test-ChatInProject](src/chatrm.ps1)), but Copilot's still go by the leaf:
[Get-CopilotWorkspaceName](src/providers.ps1) reads the full folder from
`workspace.json` and keeps only its last part, so `D:\a\app` and `D:\b\app`
share a scope. Nothing can be queued to a Copilot chat, so the cost is a
sibling's chat in `chatfind` and `chatrm` lists, not a prompt sent to it.

**Revisit when:** If a sibling folder's Copilot chats in chatfind or chatrm
lists get in the way.

**To close:** have the Copilot `Describe` put the folder on the row's `Cwd`,
match it in [Test-ChatInProject](src/chatrm.ps1) as Codex rows are, and widen
[Test-ChatIndexRowCurrent](src/core.ps1) so old Copilot rows are read again
once.

## Start at boot

**Scope:** Nothing is registered with the OS at boot. After a reboot the
watcher returns with the next shell.

**Why deferred:** nothing is registered with the OS, on purpose. After a reboot
the watcher returns with the next shell.

**Revisit when:** If a user asks for the watcher to start at logon without
opening a shell.

**To close:** an opt-in `chatinstall -AtLogon` that writes a Task Scheduler /
launchd / systemd user entry and removes it again on uninstall.

## CI on macOS and Linux

**Scope:** CI runs the self-test on Windows only. The Unix branches (`nohup`,
`caffeinate`, `osascript`, `ioreg` and the like) have never run.

**Why deferred:** CI now runs the self-test on Windows under both 5.1 and
PowerShell 7. The Unix branches - `nohup`, `caffeinate`, `systemd-inhibit`,
`chmod 600`, `osascript` and `notify-send` toasts, `ioreg` idle time,
`Process.Kill($true)` - are written but have never run.

**Revisit when:** When a Mac or Linux machine is at hand, or the
`ubuntu-latest` and `macos-latest` legs are worth their cost.

**To close:** add `ubuntu-latest` and `macos-latest` to the matrix. The tests
need a `fake-claude` shell wrapper next to the `.cmd` one, and the few
Windows-only checks (DPAPI, the echo exe) a skip on Unix.

## The self-test on a slow machine: what is left

**Scope:** Three self-test gaps: no loaded PowerShell run with spare memory,
two carry arms with a second to spare, and a Toolhelp32 check that goes by the
clock.

[TESTING.md](TESTING.md)'s *Slow machines* has how the checks were made to
hold, and what proved it.

- **A loaded PowerShell run with memory to spare.** The one pinned 5.1 run
  ran short of commit, and its two failures were that; PowerShell 7 has
  had no loaded run. **Why deferred:** a loaded run takes over an hour,
  and the machine the fixes were made on sat at 94-99% of commit through
  them. **To close:** both, pinned to two cores beside two busy loops,
  with commit well under its limit; a failure then is a timing flake, to
  fix as the others were.
- **Two carry arms with a second to spare.** In `extension-check.js` a
  missed carry's arm waits 1 s, and a revealed tab's 1.5 s
  ([armCarry](extension/extension.js)'s `wait`); each check reads that
  nothing was said yet after the open returns, so a stall longer than the
  arm between the two fails it. **Why deferred:** the arm's own timer is
  what the check watches go, and every run waits it out; 1 s is the cap
  `within` gives every other timed check in the file, and both passed
  with the event loop held up to 100 ms in every 10. **To close:** a timer
  the check fires itself - `armCarry` taking its `setTimeout` from
  `_timing` - so the "nothing yet" is read before the arm can go.
- **The Toolhelp32 check goes by the clock.** `background.ps1` tells
  [Get-ChatShellChildCount](src/overlay-data.ps1)'s native list from a
  WMI query by time alone: the best of five looks under 150 ms. The best
  of five rides out a busy machine's stall, but a fast, idle PC's WMI
  query could pass it too. **Why deferred:** there is no WMI path left in
  the code to fall back to, so only a rewrite could bring one back.
  **To close:** a seam that counts the WMI calls, or `ChatProcSnap`'s, in
  place of the clock.

**Revisit when:** If a loaded run with memory to spare is made, or one of these
checks is seen to flake.

## Codex threads found from its database

**Scope:** chatq finds Codex threads only by their rollouts, not from
`state_5.sqlite` or `thread/list`, so a thread in the database with no rollout
is not shown.

**Why deferred:** chatq finds Codex threads by their rollouts
(`sessions/**/*.jsonl`). Codex also keeps every thread in
`state_5.sqlite`, and two of the three threads there have no rollout. A
Discover that read that list - straight from SQLite, or through the
app-server's `thread/list` - was weighed and set aside: src has no SQLite
reader, `state_5` is a private schema whose version is in its name, and
the rollout-less threads look like chats deleted on purpose (both from
codex-cli 0.154, their date folders empty, one with about 38 KB of
rollout once written), which chatq's tombstones are there to keep out. An
`exec --ephemeral` probe leaving a database row is a second suspect, not
checked. `thread/list` likely hides them anyway: it returned one thread
where the database holds more.

**Revisit when:** Only if a thread with no rollout is ever seen that nobody
deleted.

**To close:** only if a thread with no rollout is ever seen that nobody
deleted. List `thread/list` ids by `sourceKinds` through the app-server
client to see whether they show at all; if they do, a stand-in row for
each, and a guard in every reader that takes a row's `Path` for a file.

## Codex's own goals and queue, deliberately unused

**Scope:** chatq does not use Codex's goals or its queue; it keeps one queue
for Claude and Codex, which waits for limit resets, probes first and reports to
the phone.

**Not planned.** Codex has goals of its own (`thread/goal/set`, `get`,
`clear`, kept in `goals_1.sqlite`) and a queue of its own (`codex queue`,
`thread/queue/*`, kept in `queue_1.sqlite`). chatq keeps its own queue
instead: it is the same for Claude and Codex, it waits for a limit's reset
and probes before it runs, and it reports to the phone - none of which
Codex's queue does. Codex's queue may still be the way *into* an open
panel ("Deliver into a live Codex chat through `codex queue`", in
FUTURE_WORK.md), as a delivery route under chatq's queue, not in its place.
Written down so the absence reads as a choice.

**Revisit when:** If delivery into an open Codex panel is wanted: then as a
route under chatq's own queue, through `codex queue`.

## Context % for Codex chats

**Scope:** Codex chats show no context percentage; no Codex row on the overlay
or board exists to carry one, and Claude rows show none either.

**Folded into** "model, context and cost per row" in "What the new name
promises", in FUTURE_WORK.md, to be built for both providers at once. **Why
deferred:** a rollout's `token_count` records carry the context window and
the last call's tokens, so a figure is there to read, but no Codex row
exists where it would matter: the overlay and the board show no Codex
chats, and a stale figure on a list of past chats is near-trivia beside the
panel's own gauge. Claude rows show none either. The database's
`tokens_used` is a running total, not the context's fill, and must not be
used. **To close:** with that item; take the newest `token_count` whose
`info` is set (the thread's first is a zero seed), and its
`model_context_window`.

**Revisit when:** When the model, context and cost per row item is built for
both providers.

## Sponsorship

**Scope:** The README carries a grey "sponsor: coming soon" badge and there is
no `.github/FUNDING.yml`, so GitHub's Sponsor button stays off.

**Why deferred:** there is no sponsor account yet. The README carries a grey
`sponsor · coming soon` badge pointing here. There is deliberately no
`.github/FUNDING.yml` - with a placeholder handle GitHub's own Sponsor button
would open a 404.

The options:

| | fits | costs |
|---|---|---|
| GitHub Sponsors | the button sits in the repo header, one-off or monthly | enrolment and payout setup; no fee on personal accounts |
| Ko-fi | one-off tips, a simple page | no fee on tips; memberships take a cut |
| Buy Me a Coffee | one-off tips, memberships | a 5% fee |
| Patreon | monthly memberships | a platform fee; heavy for a one-file tool |
| thanks.dev | sponsors a project's dependencies at once | little to gain for a tool nobody depends on yet |

**Revisit when:** When a sponsor account exists and a platform is picked.

**To close:** pick one, add `.github/FUNDING.yml` with its handle, and swap the
badge for the real link.

## Social preview image

**Scope:** The repo has no social preview image set, since GitHub sets it only
in the web UI.

**Why deferred:** GitHub sets a repo's social preview only in the web UI
(Settings → Social preview); there is no API for it.

**Revisit when:** If GitHub adds an API for the social preview, or when someone
uploads the image by hand.

**To close:** upload a 1280×640 image made from `docs/demo-list.svg`.

## Auto-continue for Codex chats chatq did not run

**Scope:** Codex chats chatq did not run get no cut-off scan;
[Get-ChatqCutOffChats](src/queue.ps1) reads Claude's transcripts only, so only
watcher-run Codex jobs are continued.

**Why deferred:** there is no cut-off scan for Codex
([Get-ChatqCutOffChats](src/queue.ps1) reads Claude's transcripts only). A
Codex job chatq ran is already continued by the watcher after a limit.
Three things stand in the way:
- **Where to read a cut-off.** `turn.failed` is a record of the `codex exec
  --json` stream, not of the rollout, so a rollout reader has nothing to
  find. The app-server's `thread/turns/list` gives each turn's status and a
  typed error (`codexErrorInfo`: `usageLimitExceeded`, `serverOverloaded`,
  ...), but no limited turn has been seen yet, on any build.
- **Check 3** - is the chat held open somewhere - has nothing to go on,
  since Codex keeps no registry of what runs; it waits on a busy check for
  Codex threads ("A Codex thread open in the panel", in FUTURE_WORK.md).
- **The free plan's window is a month** (43200 minutes), so its reset falls
  past `$script:ChatqAutoMaxResetHours` and such a cut-off would be by hand
  anyway.

**Revisit when:** When a real limited Codex turn has been seen and a busy check
for Codex threads exists.

**To close:** read the last turn of each thread that moved through
`thread/list` (`useStateDbOnly: true`, by `updated_at`) and
`thread/turns/list`, cached on `updatedAt`; count only `usageLimitExceeded`
as a limit, its reset from
[ConvertFrom-ChatqLimitText](src/queue.ps1) or else the window's
`resetsAt`; and offer those rows to the reset ask and the manual Continue,
never the automatic one, until a real limited turn has been checked.

## Auto-continue and a registry entry that names no entrypoint

**Scope:** The reset ask takes an entry with no entrypoint for a VS Code panel;
the automatic mode takes it as holding the chat, in
[Get-ChatqAutoState](src/auto-continue.ps1).

**Why deferred:** the two modes read such an entry differently. The reset
ask takes it for a VS Code panel, as `Test-ChatVsCodeOwned` does, and asks
about the chat; the automatic mode takes it as holding the chat, as a
terminal's would ([Get-ChatqAutoState](src/auto-continue.ps1)'s
`terminal`), and leaves it. Asking is harmless, a second writer is not, so
each errs its own safe way. Every entry on this machine names one (spike
A4); an old Claude Code might not.

**Revisit when:** If an entry with no entrypoint is seen on a real Claude Code.

**To close:** an entry with no entrypoint seen on a real Claude Code; then
read it one way for both, by the process that wrote it.

## Auto-continue on Linux, and the phone's switch

**Scope:** On Linux only a watcher running for other jobs scans, so otherwise
nothing is auto-continued; the phone cannot turn auto-continue on or off.

**Why deferred:** there is no overlay on Linux, so only a watcher running for
other jobs scans there; with none, nothing is auto-continued, and `chatqlist`
says so - and the reset ask has nothing to ask with. Turning auto-continue
on or off from the phone is left out on purpose: on grants unattended runs,
and off from a phone that may not be yours would quietly stop work
(docs/auto-continue-spec.md).

**Revisit when:** If a Linux user asks for a scan at shell start or a timer, or
if the reasoning against a phone switch changes.

**To close:** for Linux, a scan at shell start or a timer the user opts
into; for the phone, nothing - it stays out unless that reasoning changes.

## Usage heads-ups without the overlay

**Scope:** Threshold usage alerts come from the overlay's pass in
[Update-ChatqUsageAlerts](src/phone-extras.ps1), so macOS, Linux or a stopped
overlay get none.

**Why deferred:** the threshold heads-up comes from the Windows overlay's
pass ([Update-ChatqUsageAlerts](src/phone-extras.ps1)), which asks the usage
endpoint every few minutes whether or not anything is queued. The watcher
runs only while something is queued or a reply window is open, so on macOS,
Linux, or with the overlay stopped, there is no threshold alert; the soon
and reset alerts come from the watcher and work everywhere. `chatnotify`
says when the overlay is not running. Copilot's monthly quota, a second
Claude account's windows (the overlay reads one config dir), and a way to
hold the queue at a reset from the phone are left out too; **Skip** on a
job's own alert holds one job.

**Revisit when:** If threshold alerts are wanted without the overlay, or a user
on macOS or Linux asks for them.

**To close:** a small usage look of the watcher's own, once in 15 minutes
while it runs, through [Read-ChatqClaudeUsageCache](src/overlay-data.ps1)
and the rollouts, feeding the same function; for a PC with nothing queued
it would still need the overlay or a scheduled task.

## Quiet hours: one window, this PC's clock

**Scope:** Quiet hours are one daily window in the PC's time zone
([Get-ChatqQuietHours](src/phone-extras.ps1)); no weekday schedule, second
window, or phone zone.

**Why deferred:** kept simple on purpose. One daily window in the PC's own
time zone ([Get-ChatqQuietHours](src/phone-extras.ps1)): no weekday
schedule, no second window, not the phone's zone, and the toast and your
command are never held (the command is told `CHATQ_QUIET=1` and decides).
The summary answers no particular job - its alerts were never registered,
since registering them would keep the reply window open all night for
nothing - so a held `needs input` is answered through **Status** and
`chatqrun` at the PC. Android's own Do Not Disturb is the phone's.

**Revisit when:** If a user asks for weekday schedules, more than one window,
or a summary that can answer held jobs.

**To close:** a list of windows with days in `quietHours`, read by the same
[Test-ChatqQuietNow](src/phone-extras.ps1); a summary that answers jobs would
register one alert per held job at summary time, not at hold time.

## Permission prompts in chats chatq does not run

**Scope:** A chat run straight in VS Code or a terminal gets no permission
prompt on the phone: chatq installs no `PermissionRequest` hook in the user's
Claude settings.

**Chats run straight in VS Code or a terminal.** **Why deferred:** only a
`PermissionRequest` hook in the user's `~/.claude/settings.json` reaches
them, and chatq has never written the user's Claude settings. **To
close:** a hook command that hands the request to the watcher the way
the bridge does - a request file, a sealed card, the phone's sealed
answer checked by the hook itself - installed only by an explicit
command, and removed by one.

**Revisit when:** If an explicit install command for a user-level
`PermissionRequest` hook is ever wanted.

## Answering a permission prompt at the PC

**Scope:** A permission prompt can be answered only on the phone. The bridge
believes an allow only on the phone's MAC, so the console, overlay and toasts
cannot allow.

**Answering at the PC** (the console, the overlay, a toast button).
**Why deferred:** the bridge believes an allow only on the phone's MAC,
since anything can write into `data/`; a PC-side allow needs a secret the
bridge can trust that no chat can read. **To close:** a per-run secret the
watcher hands the bridge outside `data/` (its environment, say), and an
answer MAC'd with it from the console's details pane.

**Revisit when:** If a per-run secret outside `data/` is handed to the bridge,
or answering at the PC is asked for.

## The reply page's shared origin and permission alerts

**Scope:** The reply page is served from the shared `github.io` origin, so a
script on another page there could post an Allow with the phone's key while a
permission alert is open.

**The reply page on an origin of its own** (above) matters more now: a
script on another `phal40lax78.github.io` page could post an Allow with
the phone's key while a permission alert is open. The README and the
setup window's tooltip say to serve the page from a site of your own
first; closing that entry closes this.

**Revisit when:** When the reply page is served from an origin of its own.

## Always allow, an edited command or a plan from the phone

**Scope:** The phone can only allow or deny a permission prompt. It offers no
Always allow, no edited command and no plan approval, by design.

**"Always allow", an edited command, a plan.**
Out of scope by design (the spec's section 11). (A question is the
phone's now, in chats you run yourself; FUTURE_WORK.md's "Claude's
questions on the phone: what the first release left out" has what is left
of it.)

**Revisit when:** If the phone is ever meant to widen a run or edit a command.

## A question open before the ask hook loaded

**Scope:** A question already open when the hook was loaded shows on the phone
but cannot be answered there; the phone says the hook does not hold it.

**A question open before the hook was loaded.** It shows on the phone,
and says the hook does not hold it. **Why deferred:** the only way in is
the VS Code dialog itself, and driving that from outside means moving your
mouse or focus and breaking on any change to the extension. **To close:**
the Claude Code extension or CLI offering a way to answer a pending
question by its id; until then a chat opened or reloaded after `-Ask on`
has the hook.

**Revisit when:** When the Claude Code extension or CLI offers a way to answer
a pending question by its id.

## A lighter launcher for the ask hook

**Scope:** Each held question starts a hidden PowerShell, at most 5 at
once ([Start-ChatqAskHook](src/ask.ps1)). Since the loader's `CHATQ_ROLE`
it loads the 16 parts the hook reaches, not all 23: 94 MB after a full
collection where 104 were, 0.4 s to load where 0.5 was (median of 5 fresh
loads, 2026-10-15). Most of that is Windows PowerShell itself, about
52 MB bare.

**A lighter hook launcher.** **Why deferred:** it works, the cap bounds
it, and the parts left are the hook's own reach; a second, smaller copy
of the request code would have to stay equal to the first, byte for byte
where the digest and the splice are. **To close:** a launcher that
dot-sources only what the hook needs - the JSON and crypto helpers, the
registry read, the digest, the answer check - with the self-test running
the two against each other, and one PowerShell serving several
questions.

**Revisit when:** If the start cost or memory of held questions is ever seen to
hurt. **Planned** (2026-10-15): the hook and the permission bridge as
small native programs, [native/SPEC.md](native/SPEC.md), M8.

## A mode switched at the PC while a question waits

**Scope:** The mode cap is checked once, from the hook's stdin, so a chat
switched to `bypassPermissions` while a question waits still takes the phone's
answer ([Test-ChatqAskGates](src/ask.ps1)).

**A mode switched at the PC while a question is held.** With a cap set
(`reply.maxMode`; none by default, and under `keep` the gate lets every
mode through), the phone may answer only in a chat whose mode is within
it, and the mode
is read once, from the hook's stdin, as the question comes
([Test-ChatqAskGates](src/ask.ps1)). Switch the chat to
`bypassPermissions` while the dialog waits, and a later answer from the
phone still goes in. **Why deferred:** nothing says the mode while a
question waits. The transcript writes it on typed prompts only, so it
holds the last prompt's mode, and the registry has no mode at all. A
re-check against either would be wrong both ways. **To close:** a live
mode source - the registry carrying the mode, or a hook event on a mode
change - read again just before the hook prints its answer.

**Revisit when:** When a live mode source exists, such as the registry carrying
the mode or a hook event on a mode change.

## The phone board answers in seconds, not at once

**Scope:** The watcher polls the reply topic, so a board or ack comes 3 to 20 s
after the tap ([Get-ChatqReplyPollSeconds](src/phone-down.ps1)).

**Why deferred:** the watcher polls the reply topic - every 20 s listening
all the time, 6 s for two minutes after the phone asked for something
([Get-ChatqReplyPollSeconds](src/phone-down.ps1)) - so a board or an ack
comes 3 to 20 s after the tap. ntfy can hold a stream open (`/json`
without `poll=1`) and hand each message over as it is posted, about a
second end to end, but the watcher's loop is built around short polls
that never block it: a stream needs a reader of its own.

**Revisit when:** If the 3 to 20 s delay is ever found too slow to live with.

**To close:** a runspace in the watcher holding `GET /<topic>/json` open,
passing each line to the loop through a queue, and reconnecting with a
backoff; [Invoke-ChatqReplyPoll](src/phone.ps1) stays for the catch-up
after a sleep, `since` its last id. The same 250-a-day budget is
untouched: a stream is one request.

## A home-screen app for the phone board

**Scope:** The board is reached from a bookmark or Add to Home screen of the
bare page, with no manifest, icon or offline card.

**Why deferred:** the board is reached from a bookmark or **Add to Home
screen** of the bare page. A web app manifest and a service worker would
give it an icon of its own, a full-screen start and an offline card, but
the page is one static file that loads nothing - its CSP has no
`manifest-src` or `worker-src` - and a service worker on the shared
`github.io` origin would be one more script there.

**Revisit when:** If an app-like icon and full-screen start are wanted on the
phone.

**To close:** a `manifest.webmanifest` beside the page (name, icon as a
`data:` URI, `display: standalone`, `start_url` the page), `manifest-src
'self'` in the CSP, and `reply-page-check.js` allowing exactly that one
`<link rel="manifest">`. No service worker: nothing is to be cached while
decrypted text lives only in the page's memory.

## Listening all the time off Windows

**Scope:** On macOS and Linux, `reply.listen always` restarts only with a
shell, so after a reboot nobody listens until PowerShell opens
([Start-ChatqReplyStanding](src/phone-down.ps1)).

**Why deferred:** `reply.listen always` is begun again by a shell's start
and by the Windows overlay's host
([Start-ChatqReplyStanding](src/phone-down.ps1)); on macOS and Linux only
a shell does, since no overlay host runs there to do it, so after a reboot
the board has nobody listening until a PowerShell is opened. The board
itself works there - its scan
([Get-ChatqBoardScan](src/phone-board.ps1)) needs no overlay - but none of
it has been run off Windows.

**Revisit when:** When the Mac panel runs, or if a `launchd` or `systemd` unit
for chatq is wanted.

**To close:** start it from the macOS overlay's collector as the Windows
host does, or from a launchd/systemd unit of chatq's own; then S44 in
TESTING.md on a Mac.

## Codex chats on the phone board

**Scope:** The board shows no Codex chat rows; a Codex chat appears only as a
queued job ([ConvertTo-ChatqPhoneBoard](src/phone-board.ps1)).

**Why deferred:** the board has no Codex rows. Its open, cut-off and
Recent rows are all Claude chats: the registry the overlay reads is
Claude's, [Update-ChatOverlayRecent](src/overlay-data.ps1) lists Claude
transcripts only, and [ConvertTo-ChatqPhoneBoard](src/phone-board.ps1)
keys every row as `claude`. A Codex chat shows up only as a queued job.
Its chat view no longer reads `at most acceptEdits`: the queue row
carries the sandbox the job runs in (`m`, from
[Get-ChatqCodexRunSandbox](src/queue.ps1)), and `modeText` in
`docs/reply.html` says it when `chatOfJob` finds no row. What is left is
a Codex chat with no job queued, which the board does not show at all.

**Revisit when:** When a Codex registry of open chats exists, or Codex rows are
asked for on the board.

**To close:** give the board Codex chat rows, read as **Older chats**
does ([Get-ChatqPhoneChatMeta](src/phone-board.ps1) with
`Provider = 'codex'`, capped at `workspace-write`), which a live state
would need a Codex registry of open chats for, and there is none today.

## A Codex all-clear still spends a turn

**Scope:** After the live-limit check finds no clear block, the Codex probe
still runs a low-effort `codex exec` turn ([Invoke-ChatqProbe](src/queue.ps1)).

**Why deferred:** the Codex branch of [Invoke-ChatqProbe](src/queue.ps1)
now asks `account/rateLimits/read` first
([Get-ChatqCodexLiveLimit](src/queue.ps1)) and spends nothing while the
account is clearly still limited: a window at 100% whose reset is ahead,
`rateLimitReachedType` set, or `ordinaryUsageAllowed` false. Any other
answer still runs the low-effort exec turn. Room left in every window
says nothing about an overload, a refused login, or a limit on the chat's
model alone, and only a turn shows those. Credits (`hasCredits`,
`unlimited`) also leave it to the turn, since they can carry one past a
full window.

**Revisit when:** Only if a turn-free signal for overload or per-model limits
turns up, such as an app-server method.

**To close:** only if a turn-free signal for those turns up. Candidates:
an app-server method that reports a model's own limit, or the server's
status. Check it against a real limited account before trusting it as a
yes.

## chatq's data folder named in a command, every way

**Scope:** A Bash or PowerShell command can still reach chatq's data folder
without naming it, and an edit path through a subst drive, junction or symlink
is not followed, in [Test-ChatqPermitCommandDir](src/permit.ps1) and
[ConvertTo-ChatqPermitPath](src/permit.ps1).

**Why deferred:** [Test-ChatqPermitCommandDir](src/permit.ps1) looks for
the folder in a Bash or PowerShell command long and short, in Git Bash's
`/c/...` form, under `~`, `$HOME` and `%USERPROFILE%`, as each path-like
word made canonical, and in any command run inside it. A command can
still reach it without naming it so: a mix of long and 8.3 parts, a
variable of its own, a string put together at run time. The spec always
called this rule best effort; the phone's own card and its Deny are the
guard after it. An edit's path is made canonical
([ConvertTo-ChatqPermitPath](src/permit.ps1)), but only as a string and
through `GetFullPath`: a `subst` drive, a junction or a symbolic link that
leads into `data/` is one more name it does not follow.

**Revisit when:** If a real case turns up of a command or edit path that
reaches the data folder unseen.

**To close:** for commands, nothing short of running them; if a real case
turns up, add its form to the needles and a row to the rules' table in
`tests/sections/permit.ps1`. For an edit's path, open the deepest folder
of it that exists and ask Windows for its final path
(`GetFinalPathNameByHandle`), in a helper with a timeout, since a path on
another machine must never be opened from the bridge.

## The Windows PowerShell path built in eight places

**Scope:** Eight launchers each join the Windows PowerShell path onto
SystemRoot themselves, such as [Get-ChatqPermitLaunch](src/permit.ps1) and
[Get-ChatqClipboard](src/queue.ps1), instead of one shared helper in
src/core.ps1.

**The Windows PowerShell path, built in eight places.**
[Get-ChatqAskHookCommand](src/ask.ps1),
[Start-ChatConsoleIndexSync](src/console.ps1),
[Start-ChatShowFreshProcess](src/overlay-windows.ps1),
[Get-ChatOverlayLaunch](src/overlay.ps1),
[Get-ChatqPermitLaunch](src/permit.ps1),
[Get-ChatqPhoneSetupLaunch](src/phone-setup.ps1),
[Get-ChatqOutboxLaunch](src/phone.ps1) and
[Get-ChatqClipboard](src/queue.ps1) each join
`System32\WindowsPowerShell\v1.0\powershell.exe` onto
`$env:SystemRoot`, all but the last with `C:\Windows` when that is
unset. The extension's two copies are one now, in
[windowsPowerShell](extension/setup.js). **Why deferred:** a helper saves
a line or two in each, and Get-ChatqPermitLaunch keeps its root for the
module paths anyway. **To close:** one function in src/core.ps1, which
every part loads first; Get-ChatqClipboard gains the fallback with it.

**Revisit when:** If the path or its fallback needs to change in more than one
place, or another launcher is added.

## A lazy shell's parameter names before the first use

**Scope:** Until a lazy shell's first use, each command is a stand-in with
no parameters of its own ([Enter-ChatShell](src/shell.ps1)). PowerShell
completes a parameter's name itself, never through a completer, so where
the tool's Tab handler is not the one asked - Ctrl+Space's menu, and Tab
with `$ChatNoKeyBindings` set or no PSReadLine - `chatrm -Pro` offers
only the common parameters. Tab with the handler bound loads the tool
first, as an argument's Tab or any command does; after the load every
way completes as before.

**Why deferred:** binding Ctrl+Space would change that key in every
shell, lazy or not, for a gap the first command closes; and a stand-in
given its command's parameters would copy 18 signatures into shell.ps1,
to be held equal to the real ones.

**Revisit when:** If someone who completes through the menu, or without
the key handlers, finds it in their way. **To close:** each stand-in's
`param()` block written from its command's own, with the self-test
holding the two equal.

## The tool's own functions before a lazy shell's first use

**Scope:** A lazy shell has the 18 commands, their aliases and what
shell.ps1 itself defines. The rest of the tool's functions -
`Get-ChatqJobs`, `Start-ChatqWatcher` and some 1,100 more - are not there
until a command, Tab or Enter on a command's line, or a shell-start duty
with something to do has loaded the tool ([Import-ChatTool](src/shell.ps1)).
One typed at the prompt before that is not found.

**Why deferred:** they are the tool's insides, called by its commands, not
by a person; nothing in the repo, the extension or the overlay types one
into a shell. A `CommandNotFoundAction` hook that loads the tool would
answer every mistyped name in every shell with a 0.4 s load.

**Revisit when:** If a script, a habit or another tool is seen calling one
in a fresh shell. **To close:** a `CommandNotFoundAction` handler that
loads the tool only for a name of the tool's own `Verb-Chat*` form, then
has PowerShell look again.

## Two launches of a native watcher at once

**Scope:** [Write-ChatqNativePending](src/watcher.ps1) writes
`data/native/pending.json` once `Start-Process` gives the child's pid, so
a chatqd that finds the lock busy can ack - delete the record - before it
is there, and still be running when the launch asks whether it exited.
The record then waits for nobody, and 15 s on the next launch counts a
`no ack` strike. [Send-ChatqNativeFuseAlert](src/watcher.ps1) marks
`alerted` in `fuse.json` with no lock, so two launches that blow the fuse
together could each send the alert.

**Why deferred:** both need two launches within milliseconds of each
other, and the cost is at most one false strike or one alert too many.

**Revisit when:** If a false `no ack` shows in `chatqd.log`, or before M7
makes the native watcher the default. **To close:** the record written
before the start, under an id the child is given to ack by, and
`fuse.json` saved under a lock.

## A relative CHATQ_CHATQD

**Scope:** [Get-ChatqNativePath](src/watcher.ps1), as chatqd's
[Identity::of](native/crates/chatq-core/src/launch.rs) does, makes a
relative `CHATQ_CHATQD` absolute against the process's own folder. Every
watcher runs in your home folder, so a watcher's own launch of the next
one - a restart, a handover - looks for the binary under it, not where
the shell that set the variable was.

**Why deferred:** `CHATQ_CHATQD` is a developer's setting, and giving the
child an absolute one would mean an environment of its own, which
`Start-Process` cannot set in Windows PowerShell 5.1.

**Revisit when:** If the setting is documented for users, or launches move
to `System.Diagnostics.Process`. **To close:** the first launch hands the
absolute path down in the child's environment.

## An unreadable record in data/native

**Scope:** [Find-ChatqNativeStrikes](src/watcher.ps1), as chatqd's
[launch::find_strikes](native/crates/chatq-core/src/launch.rs) does, reads
`pending.json` and `last.json` with three tries 100 ms apart, and leaves
one that will not parse where it is. A truncated record costs every
launch some 0.4 s, an empty one 0.07, until it goes.

**Why deferred:** both writers save a record aside and swap it in
([Save-ChatqText](src/queue.ps1) and
[fsx::save_text](native/crates/chatq-core/src/fsx.rs)), so a broken one
needs an outside hand; and nothing makes `data/native` on a PC with no
build.

**Revisit when:** If one is seen. **To close:** a `pending.json` that does
not parse deleted, on both sides, with a case for it in
`native/vectors/launch.json`.

## A CHATQ_CHATQD in 8.3 short names

**Scope:** [Get-ChatqNativeIdentity](src/watcher.ps1) names a binary as
.NET does, its 8.3 short names (`ADMINI~1`) expanded, in Windows
PowerShell 5.1 and pwsh 7 alike; chatqd's
[Identity::of](native/crates/chatq-core/src/launch.rs), through
`std::path::absolute`, keeps them. A `CHATQ_CHATQD` written short is then
two paths in `data/native/verified.json`, and chatqd's first respawn of
that build runs preflight again.

**Why deferred:** `CHATQ_CHATQD` is a developer's setting, the cost is one
preflight, and the root is always long-named: both editions give
`$PSScriptRoot` with its short names expanded, even for a loader
dot-sourced by its short path.

**Revisit when:** If a short name reaches chatqd any other way, or before
M7 makes the native watcher the default. **To close:** `Identity::of`
expands short names with `GetLongPathNameW`, as .NET does.

## A script that stages a chatqd build

**Scope:** `native/SPEC.md` 3.1 names a `native/stage.ps1` that copies a
build into `bin/<version>/<target>/`, where the watcher looks for one.
There is none: TESTING.md's S55 copies the exe by hand, and
`CHATQ_CHATQD` names a build anywhere else.

**Why deferred:** one developer, one target and one copy per version,
which by hand is a single `Copy-Item`.

**Revisit when:** If chatqd is built on a Mac by hand, or S55's copy
becomes a chore. **To close:** `stage.ps1 [-Target <triple>]` building
with `native/.cargo/config.toml` and copying into
`bin/<ChatVersion>/<triple>/`.

## pwsh 7's JSON constructors

**Scope:** Newtonsoft reads a `new Name(args)` constructor where a value
goes: pwsh 7 makes `new Date(1)` a `[datetime]` and drops a property
that holds any other, where 5.1 throws on all of them. chatqd's grammar
refuses one ([Newt::value](native/crates/chatq-core/src/json.rs)), so a
file or stream line that holds one reads as `$null` under pwsh 7 too.
json.rs's test `a_constructor_is_refused_a_known_divergence` pins the
refusal.

**Why deferred:** nothing chatq writes holds one, and Newtonsoft's
`ParseConstructor` would take a grammar path and date code of its own.

**Revisit when:** If a hand-edited `config.json` or job file with
`new Date(` is reported. **To close:** a constructor branch in `Newt`,
its dates read through [time::json_date](native/crates/chatq-core/src/time.rs),
and json-compat.json cases under both editions.

## PowerShell's culture compares, approximated

**Scope:** `-eq`, `switch`, `StartsWith`, a `@{}` key and Sort-Object
compare by the culture, not ordinally, and chatqd comes close without the
culture's tables. [json::ieq](native/crates/chatq-core/src/json.rs) folds
with `to_uppercase` past ASCII (`ß` equals `SS`). stream.rs skips soft
hyphen and NUL alone ([stream::ignorable](native/crates/chatq-core/src/stream.rs)),
not ZWJ or the BOM, nor ZWSP and some controls on pwsh 7; 5.1's `ToolIds`
keys fold by simple upper case with `µ`, `ı` and `ſ` kept
([stream::culture_fold_eq](native/crates/chatq-core/src/stream.rs)), and
miss `é` against `e` + U+0301, `ß` against `ss` and the Kelvin sign
against `k`. [board::status_line](native/crates/chatq-core/src/board.rs)
sorts lane names case-blind ordinal, and
[jobs::job_files](native/crates/chatq-core/src/jobs.rs) lists as 5.1 does
under either edition, where pwsh 7's listing is collated. All of it is
modelled under en-US, as the vectors are made.

**Why deferred:** what these compare is text chatq writes in ASCII - the
stream's words and tool ids, lane names, GUID job file names - and a real
compare needs each edition's collation (NLS on 5.1, ICU on pwsh 7). The
one compare that meets outside text, ntfy's prefix check, has scanned
tables of its own in [wire.rs](native/crates/chatq-core/src/wire.rs).

**Revisit when:** If a value past ASCII is seen in one of these compares,
or a culture other than en-US changes one. **To close:** per-edition
tables, scanned as `wire/collation.rs`'s were, behind one compare the
callers share.

## Numbers as a JSON read holds them

**Scope:** a file's values reach chatqd as serde_json holds them
([json::to_value](native/crates/chatq-core/src/json.rs)): a 5.1 decimal
loses its scale (`1.50` is 1.5, so `[string]` gives `1.5`), an integer
past a u64 is the nearest double, and one past a double, or a `NaN`, is
text ([Tolerant::lossy](native/crates/chatq-core/src/json.rs)).
[json::to_ps_string](native/crates/chatq-core/src/json.rs) writes
`[string]` by 5.1's rules, so a negative zero gives `0` where pwsh 7
gives `-0`. A long digit string is rounded correctly, where .NET Framework
misrounds some by one bit. `[int]` of text takes what both editions read
and pwsh 7's blank, not its `1kb`, `0b101` or `5d`
([jobs::ps_int](native/crates/chatq-core/src/jobs.rs)); the reply
registry leaves any number text but a plain integer to PowerShell
([replystate::text_int](native/crates/chatq-core/src/replystate.rs)).

**Why deferred:** no caller `[string]`s a 5.1 fraction or meets a negative
zero, chatq writes `seq` and counts as plain integers, and keeping a
decimal's scale means serde_json's `arbitrary_precision` or chatq's own
value type in every module.

**Revisit when:** If a caller prints a fraction read from a file, a `-0`
reaches one, or a hand-written `seq` in another form is seen. **To
close:** `PsVal`, or the token's digits, carried past the read where it
matters, and a flavour on `to_ps_string`.

## Dates past the shapes the vectors pin

**Scope:** [time::parse_stamp_in](native/crates/chatq-core/src/time.rs)
ports `[datetime]::Parse` for what stamps.json pins, and its doc lists the
rest: month and day names, AM/PM, `GMT`, dates with `/` or `.`, years of
1 or 2 digits, a time outside 0001-9999 once in the local zone. Also left:
[time::resolve_offset](native/crates/chatq-core/src/time.rs) takes the
smaller offset at a DST change, so a zone whose daylight time is behind
its standard time, or whose base offset moves (Paraguay, 2024), is not
modelled; [time::date_of](native/crates/chatq-core/src/time.rs) reads a
string only, where PowerShell parses `[string]` of a number (`1.5` as a
day of this year); [time::json_date](native/crates/chatq-core/src/time.rs)
reads Newtonsoft's unescaped `/Date` offset as if escaped; and
[board::text](native/crates/chatq-core/src/board.rs) prints a title that
is exactly an ISO stamp as written, where pwsh 7 prints the `[datetime]`
(`10/14/2026 08:00:00`).

**Why deferred:** chatq writes its stamps in the `o` form; nothing writes
the other shapes, and a number read as a date turns on the clock, so no
vector could pin it.

**Revisit when:** If a stamp in another shape, or a title that is a bare
stamp, turns up in a real file. **To close:** that shape ported with a
stamps.json case under both editions; for the board, `[string]` of the
`[datetime]` pwsh 7 makes, from the dates
[json::ps_dates_in](native/crates/chatq-core/src/json.rs) already finds.

## Unicode tables scanned on one PC

**Scope:** some case and collation answers are scans, not a library:
runenv.rs's `KEEP_DESKTOP` and `KEEP_CORE` (Windows 11 22631, 5.1.22621
and .NET 10.0.12, against Rust 1.99's Unicode 17), the ignorable and
digit tables of [wire/collation.rs](native/crates/chatq-core/src/wire/collation.rs)
(the same Windows' NLS and pwsh 7.6's ICU), and the 5.1 rules of
[json::fold_char](native/crates/chatq-core/src/json.rs). The scripts that
made `wire/collation.rs` were never checked in.

**Why deferred:** each table holds for the versions it names, and
env.json and wire.json pin samples of each, so a drift fails a vector
rather than passing with a wrong answer.

**Revisit when:** If one of those vectors fails on a CI image or another
Windows build, or `native/rust-toolchain.toml` moves to a newer Unicode.
**To close:** scan again; for wire's tables, write the scanner again and
check it in beside the vector generators.

## data/native records read as 5.1 reads them

**Scope:** [launch::RECORDS](native/crates/chatq-core/src/launch.rs)
reads `pending.json`, `last.json`, `verified.json` and `fuse.json` with
5.1's grammar and stamps, whoever decides.
[Get-ChatqWatcherEngine](src/watcher.ps1) reads them through
[Read-ChatqJson](src/queue.ps1) under its own edition, so a hand-edited
record that one grammar takes and the other refuses - a comment on pwsh
7, single quotes on 5.1 - can read differently on the two sides.

**Why deferred:** chatqd and [Save-ChatqNativeFuse](src/watcher.ps1)
write strict JSON, which both read alike; launch has no watcher flavour
to pass, and one decision must not turn on which process makes it.

**Revisit when:** If a record that is not strict JSON is seen. **To
close:** a record that the two grammars read differently counted as none
on both sides, with a case for it in `native/vectors/launch.json`.

## ntfy's lines read as strict JSON

**Scope:** [wire::poll_batch](native/crates/chatq-core/src/wire.rs) reads
each line of a fetched batch with serde_json, lone surrogate escapes made
U+FFFD first, not with the edition's grammar. Where
[Invoke-ChatqReplyPoll](src/phone.ps1) reads a line otherwise, nothing is
pinned: a line that is a list, which PowerShell member-enumerates and
chatqd skips; names that differ only by case, which PowerShell throws at;
a BOM before a line; an event name past ASCII, beyond what the scanned
tables cover; `Handled` under a Turkish or Azeri culture.

**Why deferred:** ntfy's server writes these lines: one object each, its
own lower-case names, string ids and the events it documents. None of the
shapes above comes from it.

**Revisit when:** If M3's native poll logs a line that PowerShell read
otherwise, or ntfy changes its format. **To close:** the lines read
through `json::ps_read` under the edition, a list line member-enumerated,
with wire.json cases.

## The reply registry's reads left to PowerShell

**Scope:** [replystate::read](native/crates/chatq-core/src/replystate.rs)
and [ReplyState::from_json](native/crates/chatq-core/src/replystate.rs)
answer `Error::PsOnly` - nothing written, the change left to PowerShell -
wherever the editions read a value in a way not ported: a file that is a
list (`$raw | ConvertFrom-Json` unrolls it into `$j`, and its elements'
fields leak in), a list where an object goes, a pwsh 7 `[datetime]` where
text goes, number text other than a plain integer, a time
`parse_stamp_in` does not read or within a day of the calendar's ends, a
pwsh 7 ISO stamp outside the shapes both read alike (hour 24, an offset
past 14 hours; the `newtonsoft_iso` guard in
[Rd::date](native/crates/chatq-core/src/replystate.rs)), a pairing
answer's `d` nested 3 deep or holding a date, a UTF-16 or UTF-32 file,
a map name past printable ASCII, and a `reply.hours` the editions prune
by differently. Ties at the 200-alert and 300-pick caps keep file order,
where PowerShell's follow hashtable order.

**Why deferred:** PsOnly writes nothing, so none of these can make a
wrong file; the worst is a change PowerShell makes instead. A
`replies.json` that [Save-ChatqReplyState](src/phone.ps1) wrote holds
none of them.

**Revisit when:** If M3's native registry logs a PsOnly for a file
PowerShell wrote, or reply-state.json gains a case with such a stamp.
**To close:** that shape pinned in reply-state.json under both editions,
then ported.

## A list where chatq writes an object

**Scope:** PowerShell's `.name` on a list gives each item's value (member
enumeration); [json::get](native/crates/chatq-core/src/json.rs) on a list
gives none. So chatqd reads no field of a `config.json` that is still a
list after [config::read_config](native/crates/chatq-core/src/config.rs)'s
two unrolls (two items or more, or `[[[obj]]]` on 5.1), of a secret that
is a list ([secret::unprotect](native/crates/chatq-core/src/secret.rs)),
or of a `state.json` that is a list
([WatchState::restore_in](native/crates/chatq-core/src/state.rs) sees no
`handoff`). stream.rs follows member enumeration, and the reply registry
leaves a list to PowerShell.

**Why deferred:** nothing writes these files as lists, and member
enumeration in `json::get` would change every caller's reading of a list.

**Revisit when:** If a list-shaped `config.json`, `state.json` or secret
is seen. **To close:** a member-enumerating lookup for those reads, with
gates.json and state.json cases.

## A run's environment off Windows

**Scope:** [runenv::child_env](native/crates/chatq-core/src/runenv.rs)
and [runenv::block](native/crates/chatq-core/src/runenv.rs) build a run's
environment by .NET's Windows rules: names case-blind
([runenv::same_name](native/crates/chatq-core/src/runenv.rs)), the block
sorted by name. pwsh 7 on macOS keys the variables case-sensitively and
does not sort the block. macOS checks runenv only against env.json's
Windows answers.

**Why deferred:** chatqd starts no run before M5, and no CLI has been run
from chatqd on a Mac.

**Revisit when:** When M5 brings native runs to macOS. **To close:** a
Unix rule for `same_name` (ordinal) and `block` (the order .NET writes),
with env.json answers made by pwsh on a Mac.
