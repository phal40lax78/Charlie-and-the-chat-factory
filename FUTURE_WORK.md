# Future work

Open problems and deliberate deferrals. Each says why it waits and what closing
it would take.

## Deliver into a live chat instead of beside it

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

## Deliver into a live Codex chat through `codex queue`

**Why deferred:** found after v0.1.0.
- **The gap today.** chatq never checks whether a Codex thread is open in a
  VS Code window, and every Codex job goes through `codex exec resume`. An open
  Codex panel then goes stale, like a Claude one, and nothing says so.
- **The official way in.** `codex queue --thread <uuid|exact name> --message
  <text>` is in the bundled codex-cli 0.154.0-alpha. It sends
  `thread/queue/add` to Codex's shared local app-server daemon, as a user
  message. It needs no per-session token, and the message is not framed as
  coming from a peer. Claude's inbox pipe (above) has both problems.
- **It doesn't replace the wait.** It queues at once, so chatq still holds the
  prompt until the reset and only then hands it over.

Open questions, from `codex-rs/tui/src/session_queue_commands.rs`:
- Does the VS Code extension's chat run on that shared daemon? If not, the
  message lands in a thread nobody is looking at.
- With no daemon running, it falls back to an embedded app server. Does the
  turn then run, or is it only recorded?
- An older daemon answers "does not support thread/queue/add", so the method
  may still be experimental.
- There is no `--json` event stream. The outcome would have to be read from the
  thread's rollout file.

**To close:**
1. Spike: with a Codex chat open and idle in the panel, run
   `codex queue --thread <id> --message ok`. Does the panel show it and run it?
   Repeat with VS Code closed.
2. Detect a live Codex thread, through the daemon's thread list or the
   extension's process. Deliver to it with `codex queue`, and use
   `codex exec resume` otherwise.
3. Classify the run from the rollout: after the queued message, tail it until
   the turn completes or errors.

## Attachments: what 0.3.0 left out

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

## `liveIdle` default

**Why deferred:** spike S29 showed the side bar keeps a chat's cached view
even once its process is ended, so ending it alone never shows the run; the
window has to show it anew - with Reload Webviews where nothing was
working, in 0.6.0, and in a tab of its own since 0.7.2. Since the handover
(CHANGELOG, Unreleased) a chat idle in a tab has its tab closed as the run
starts, under either setting, and the two differ only for a run that went
in beside the chat:
- `warn` (the default) runs, and the old process is ended only by Show it,
  after its tab is closed. The end of a run ends nothing any more: ended
  under a tab, the tab went dead ("Claude Code process exited with code
  1").
- `stop` ends it before the run, by the same checks
  (`Stop-ChatIdleProcess`), once the handover was asked and only if the
  process is still there - and waits, as for a busy chat, while a workflow
  or background agent is in flight. A tab left open over it goes dead.

Still open: whether a side bar's idle process may be ended at the run's
end. What a side bar does when the chat on screen loses its process - and
whether an unsent draft survives - has not been watched.

**To close:** S30 item 5 in TESTING.md. If the side bar takes it quietly and
keeps the draft, end a side bar's process at run end - never one under a
tab - and drop `stop`.

## A chat typed into while chatq runs it

**Why deferred:** found on 2026-09-23, after the fix it would need was already
under way. An open panel does not follow a chatq run: a window reloaded
mid-run shows the chat as it stood at that moment, stopped halfway, and
`continue` typed there starts a second agent on the same session while
chatq's is still working. Both edit the same files at once. The panel's agent
knows nothing of what chatq's did after the fork, only the files. chatq checks
for a busy chat before a job starts, and never while it runs.

What 0.6.0 does about it: Show it and the chip leave a chat alone while a
queued prompt or any `claude -p` goes into it (`Show-ChatFresh`, outcome
`running`); the next run into a chat waits 30 s after a request to show it
(`Get-ChatShowHold`); and a run into a chat a window opened while the run went
on is followed by a `ran` request, as for a chat held from before
(`Invoke-ChatqJob`).

Since the handover (CHANGELOG, Unreleased) a run into a chat idle in a tab
closes that tab first ([Invoke-ChatqHandover](src/watcher.ps1),
[onHandover](extension/extension.js)), so there is no tab left to type
into; the chip, the picker and Show it open the run's live view instead of
the chat; and the tab in front of you is never taken - the job waits. What
is left is a chat opened from Claude Code's own session list mid-run, which
loads part way through (the run's end puts it through Show it), and a run
that goes in beside a tab: one not told apart, one with a background
command running, the handover off, an extension too old to answer, or the
side bar. A window with no chatq extension is one more, and so is one with
`chatManager.autoReloadAfterRun` false, where the window only asks: nothing
on the script's side can close its tab, and a process ended under a tab
leaves that tab dead, so the run's end leaves it live and stale until
**Show it**. Before, the run's end ended the chat's process while you were
away; it no longer does ([Show-ChatFresh](src/live-chats.ps1), `-Via run`
only judges), because that left the tab dead. Each of those says the old view is stale, and the `started` alert
ends `open in VS Code: do not type in it until done` (a terminal's: `open
in a terminal too: do not type there until done`) wherever a view of the
chat is still open as the run goes in ([Invoke-ChatqJob](src/watcher.ps1)).
But nothing stops a message typed there.

**To close:**
1. Watch during the run. A record from another entrypoint (`claude-vscode`)
   whose parent is outside the run's own chain is a second writer: alert at
   once, naming the chat.
2. Decide whether chatq then stops its own run or lets both finish. Stopping
   loses less when the two are editing the same files.

## The reset ask: what 0.9.0 left out

- **Answering the ask from the phone.** The `limited` alert about it
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
- **A VS Code notification for the ask.** The ask shows in the overlay,
  its tray, the console, a toast and the phone, but not in VS Code, where
  you may be looking. **Why deferred:** the extension learns of work only
  through request files, each about one chat and one window; the ask is
  about several chats in any folders, and which window should say it -
  every one, or one - is not settled. **To close:** a request of its own
  kind in `data/`, read by every window, shown by one; **Continue** and **Leave them**
  buttons running `Complete-ChatqResetAsk` through the tool folder's loader;
  checks in `tests/extension-check.js`.
- **A click on the macOS notification.** It opens Script Editor, since the
  notification comes from `osascript`, so its text points at the `CQ`
  menu instead ([Update-ChatOverlayMacAsk](src/overlay-mac.ps1)). **Why
  deferred:** a notification that runs something on a click needs an app
  bundle of its own, and the Mac panel has never run. **To close:** after
  S24, `NSUserNotification` (or `UNUserNotificationCenter`) from the JXA
  panel, its click opening the menu.
- **The tray's items while the menu is open.** They, and the keys a click
  answers for, keep what the menu showed when it opened
  ([Update-ChatOverlayAsk](src/overlay-windows.ps1)); a chat that joins the
  ask meanwhile waits for the next ask. **Why deferred:** a menu that
  changes under the pointer could answer for a chat never shown. **To
  close:** only if S41 shows it matters: put the menu in step as it opens.
- **The five minutes after a reset** are spike A1's hold, given to every
  chat. **Why deferred:** A1 has not been run: whether a VS Code panel
  continues a chat itself is still not known. **To close:** S41 item 2;
  if panels do, count a panel chat as held (`Left`) as a terminal's is,
  and the wait could shrink.

## A reply with no tap in the browser

**Why deferred:** 0.9.0 shipped the cheap half: an alert's link takes
`&text=`, the page puts it in the box ([prefill](docs/reply.html)), and
README's Tasker recipe turns a notification's reply field into one tap on
**Send**. The tap stays, on purpose. The page holds the phone's key, an
alert's id is no secret, and anything can open a link; a link that sent by
itself would send with the phone's key whatever its opener meant. The tap
on Send is the consent, and nothing else on the phone can give it.

**To close:** sealing outside the page, in a Tasker JavaScriptlet with the
page's wire format - byte for byte, held to
`tests/fixtures/reply-vector.json`. That needs a key Tasker can read: a
second, readable copy of the phone's key, so a pairing of its own
([Start-ChatqReplyPairing](src/phone.ps1)) rather than the page's key
copied out, with its own refusal when Tasker's store is read by another
app. Worth it only if the one tap turns out to be the part people skip.

## The reply page on an origin of its own by default

**Why deferred:** the page is served from
`https://phal40lax78.github.io/Charlie-and-the-chat-factory/`, and every project
page of that account is the same site to a browser: a script on another of
them, opened in the phone's browser, could use the phone's key - not copy
it, since it will not export, but post replies with it. An origin of its
own means a custom domain or a GitHub account or organisation just for the
page, which the project does not have. `chatnotify -ReplyPage` lets a user
serve a copy from their own
([Set-ChatqNotifyConfig](src/phone.ps1), `ReplyPage`).

**To close:**
1. A site used for nothing else - a `<name>.github.io` of its own, or a
   domain - serving `docs/reply.html`.
2. `$script:ChatqReplyPage` in [src/phone.ps1](src/phone.ps1) pointed at
   it.
3. The phone keeps its key per site, so every phone pairs again. The
   release says so, and [Get-ChatqPhoneStatusText](src/phone.ps1) says so
   while the phone was paired on the old site.

## Live alerts without the Windows overlay

**Why deferred:** the alerts about the chats you run yourself come from the
Windows overlay's collector ([Update-ChatqLiveAlerts](src/phone.ps1)),
which reads every chat's state anyway. The macOS collector runs the same
pass but never sends: only the Windows host sets `WantPhone`, since the Mac
panel has never run (S24 in TESTING.md). There is no overlay on Linux.

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

## The console: what 0.5.0 left out

- **A console on macOS.** **Why deferred:** the Mac panel has never run
  (S24), and a Cocoa window with text entry, drag and drop and a pasteboard
  in untested JXA would only add to that. **To close:** after S24, an
  `NSWindow` from the same host, or the console as a small local web page
  the pwsh host serves on 127.0.0.1.
- **New Codex chats.** + New chat starts Claude chats only. **Why deferred:**
  a new Codex thread's id comes back in `thread.started` rather than being
  given up front, so a retry after a limit could start a second thread.
  **To close:** capture the id from `thread.started` as the run begins, save
  it on the job, and resume it from then on.
- **Answering a permission prompt from the console.** A run that asks is
  parked as needs-input, or since 0.9.0 asks the phone. **Why deferred:**
  see "Approve permission prompts: what 0.9.0 left out", below. **To
  close:** the same bridge ([src/permit.ps1](src/permit.ps1)), answered
  from the console's details pane.
- **The reply as it streams.** The console shows a run's reply once the run
  ends. **Why deferred:** reading a log the watcher holds open works now
  (`Get-ChatqLogEntries` shares with the writer), but redrawing the details
  pane every pass costs the window's thread while a long run writes
  megabytes. **To close:** read only what the log grew by since the last
  pass, and append it to the pane rather than redrawing it.

## The console in the panel's place: what 0.7.2 left out

- **A place of its own.** The old console window kept where it was; as the
  panel's mode it grows from the panel's corner each time
  ([Get-ChatConsolePlacement](src/console.ps1)), and an older
  `console-state.json`'s `x` and `y` are dropped as it is read
  ([Read-ChatConsoleState](src/console.ps1)). Maximize is back, as a
  header button ([Set-ChatConsoleMax](src/console.ps1)). **Why deferred:**
  "in the panel's place" was the ask, and a place of its own would undo
  it. **To close:** only if asked for: keep `x` and `y` again and let
  [Enter-ChatOverlayConsoleMode](src/overlay-windows.ps1) place it there
  when they are on a screen.
- **Windows' own maximize.** Win+Up, or the taskbar button's menu, still
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
- **Resizing from every edge.** Only the grip at its bottom-right corner
  resizes it. **Why deferred:** the panel's window is see-through and has
  no frame (`AllowsTransparency`, `WindowStyle` None), which WPF cannot
  change once the window exists, so there is no border for Windows to
  size it by; the grip was enough to size it. **To close:** a
  `WindowChrome` with a `ResizeBorderThickness` set as the console mode
  starts and cleared as it ends, or a hit test of our own answering
  `WM_NCHITTEST` near the edges.
- **Its size in units, on two real monitors.**
  [Save-ChatConsoleDraft](src/console.ps1) keeps `w` and `h` in WPF's
  units now, and [Get-ChatConsolePlacement](src/console.ps1) turns them
  into the panel's screen's pixels, so a console sized on a 150% monitor
  holds as much on a 100% one. The arithmetic is tested at 1.5; the
  window itself only at this PC's one scale. **Why deferred:** one monitor
  here. **To close:** S33 item 33 on a PC with a 100% and a 150% monitor.

## A reload on the overlay: what it leaves out

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

**To close:** give the update notice its own `state` in
`data/reload-pending/` with three answers, and the chip three chips; the
macOS panel would need the chip first ("The overlay: what 0.4.0 left
out").

## Background shells and "safe to reload"

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

**Shelved** with Reload Webviews itself. 0.6.0 showed a queued run's chat
with it; on 2026-09-25 it left two views each resuming one chat with a
process of its own, and since 0.7.2 a queued run's chat opens in a tab
instead (CHANGELOG, 0.7.2). The notes below stay for if it is wanted again.

**Why deferred:** a delete, an archive and a new chat still reload the whole
window. Nothing has shown that Reload Webviews rebuilds the chat history -
it might keep a deleted chat listed - and the processes it restarts might
write a deleted chat back as a stub.

**To close:** S30 item 17 in TESTING.md, and a way round the second view
above. If the history drops a deleted chat with no stub written back, and
`claude-vscode.editor.open` shows a chat the list does not have yet, move
`deleted`, `archived` and `new` requests over.

## A busy judgement per window

**Why deferred:** chatq judges a folder, not a window, so a queued run's chat
is shown without asking only in a window on exactly that one folder. A
multi-root window, or one on a parent folder, always asks, and the overlay's
chip does not bring such a window forward (`Test-ChatWindowExact` guesses at
it from window titles).

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

Built for the reloads chatq looks before (README, "When a reload cut chats
off"; [docs/auto-continue-spec.md](docs/auto-continue-spec.md)): every
look leaves a note of the chats at work
([Save-ChatHostWorkNote](src/host-work.ps1)), and once the host is gone
the overlay offers what it cut off through the reset ask with the reason
`restart` ([Get-ChatRestartCutOffs](src/host-work.ps1)).

**Why deferred:** a reload no chatq look came before leaves no note, so
nothing is offered for it - **Developer: Reload Window**, the Extensions
view's **Restart Extensions**, an update of another extension, VS Code
updating itself. Its chats stay cut off, as before. A note from the update
notice's look is also only as fresh as that look: a chat that began to
work between it and a reload after **Later** is not in it. And the
restart's chats are always asked about, never continued by themselves,
even with `autoContinue` on - a reload may have stopped what you meant to
stop - so the spec's "unless the switch says so for that reason too" is
not built.

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

**To close:** keep the note without the extension. The overlay already
reads the registry and each chat's process chain every pass
([Get-ChatOverlayProcessChain](src/overlay-data.ps1)), so it could note,
per extension host, the chats that work - by
[Test-ChatIdle](src/chatrm.ps1)'s judgement - and write the same
`data/host-work/<host pid>.json` itself; then any reload or restart, by
whatever button, leaves one. The cost is a write every pass while a chat
works, and the host's start from the process list. An automatic mode for
`restart` would need a setting of its own (`autoContinueRestart`), asked
for by an owner first.

## An update loaded without a reload

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

**To close:** run S45 with the reload; if a later VS Code adds a command
that runs `updateRunningExtensions`, use it in place of the reload.

## Other extensions' updates, and VS Code's own restart

**Why deferred:** the notice watches for a new version of chatq only. A
new Claude Code extension, or any other, loads on the same reload and
ends the same chats, and VS Code's own **Restart Extensions** button asks
nothing. chatq cannot stop a restart it did not start.
The chats such a restart cuts off are not offered to continue either: no
chatq look came before it, so no note was left ("Continue the chats a
reload stopped").

**To close:** the notice could watch every extension in `extensions.json`
and say the same for any that needs a restart - with the wait the same
wait - once it is clear owners want chatq to speak for other extensions.
The button needs VS Code to let an extension veto or delay a host restart,
which it does not.

## A cheaper look at a window's chats

**Why deferred:** each look the extension takes before a reload starts
Windows PowerShell and loads every part of the script, about 3 s of one
core here (TESTING.md), and a reload that waits takes one every 25
seconds. A chat whose transcript is tens of megabytes is read
whole each time for its background work, as `Test-ChatIdle` reads it; a
look past 20 s counts as not known, and the wait never ends on it. Worth
it for a wait someone asked for; not for anything that runs all the time.

**To close:** keep one PowerShell for the length of a wait, fed a line per
look, and give `Get-ChatBackgroundTasks` a cache there by path, size and
write time that reads only what was appended - the overlay's
`Update-ChatOverlayText` reads transcripts that way. The reading half exists
since the overlay began showing background work:
[Update-ChatBackgroundScan](src/chatrm.ps1) keeps a transcript's open tasks
and how far it has read, and searches each new piece as one string rather
than line by line. The long-lived PowerShell is what is left.

## Background work on the overlay: what it leaves out

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

**To close:** for the agent, a quiet agent transcript under a chat whose
process has no child working for it - once there is a case to test
against; for the command, a look at the processes off Windows (`ps -o
ppid=,args=`); for the dot and the alert, key them on the row's state
rather than the registry's; for the board, `what` from the row's words and
`reply.html` showing it for a working row; for Monitor, a transcript that
has one.

## Ending a chat's process off Windows

**Why deferred:** the parent check that tells a VS Code window's `claude`
from a terminal's reads the parent through CIM, which is Windows only. Off
Windows the process is never ended (`kept`), and the window is offered a
reload instead.

**To close:** a spike on macOS and Linux for what a panel `claude`'s parent
is called there (`Code Helper (Plugin)` on macOS, most likely), then a parent
lookup through `ps -o ppid=,comm=`.

## `code -n` behaviour

**Why deferred:** the chip brings a window forward with `code -n <folder>`,
assumed to focus the window already on that folder and open none. Windows
may refuse a background process the foreground and only flash the taskbar
button.

**To close:** only if S30 item 8 shows a second window, or item 6 a flash
instead of a raise: record what happens, and which VS Code setting
(`window.openFoldersInNewWindow`) or other route changes it. Nothing that
moves the pointer, types, or calls a window API.

## A chat no process holds gets no request

**Why deferred:** a queued run writes a `ran` request only when a window's
process held the chat as the run began. A chat whose process had already
ended - by itself, or with its tab closed - can still be cached in a side
bar, which then shows it stale, and nothing tells that window. 0.5.0 was the
same. The overlay's chip is the way round it by hand: it opens such a chat
in a new tab, loaded from disk.

**To close:** write a `ran` request (`oldProcess` none) after any run into a
chat a window may cache - one whose transcript says `claude-vscode` - and
let the window decide; S33 item 2 in TESTING.md shows whether a tab then
loads it fresh.

## A chat in the side bar gets a second process as a tab

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

**To close:** a Claude Code command that shows a session where it already
is, or closes a panel by its session id. Short of that, ending the side
bar's process before the tab opens (the chip already judges it `live`)
would leave the side bar on a dead view instead; S30 item 5 in TESTING.md
says whether that is the better trade. A working chat of no title is
never opened, even when a tab of its own shows it, since no tab's label can
be told to be its; the chip opens it once the turn ends.

## Tabs opened before 0.8.1 stay without their header

**Why deferred:** before 0.8.1 the chip and the picker opened chats with
`claude-vscode.primaryEditor.open`, whose tab is a "full editor" with no
header - no title, **Session history** or **New session** - and no diff
for an edit to approve (TESTING S39). The tab keeps that through a reload,
and the chip only brings a chat's tab forward, so such a tab stays as it
is until it is closed and opened again. From outside, a full editor looks
like any other Claude tab: `TabInputWebview` gives its `viewType` and
nothing more.

**To close:** either the Claude extension says which of its panels are
full editors, or [openTab](extension/extension.js) closes and reopens
every Claude tab once after an update from before 0.8.1 - which would cut
off a chat working in one, so it would have to wait for each chat to be
idle, as Show it closes a stale tab only while the registry reads the
chat idle ([showLive](extension/extension.js)).

## Two chats whose titles share 24 characters

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

**To close:** a session id on the tab, or a Claude Code command that
reloads a panel by session id, or that says whether a session has a panel
here without opening one.

## A chat whose label another chat has is refused until renamed

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

**To close:** what closes the entry above - a session id on the tab.
Counting only the chats a live process holds would not do: a chat with no
process can still own the tab of that label - one a Claude Code crash left
dead, one restored by a reload and not yet revived, or one whose process
`"liveIdle": "stop"` ended before a run.

## Ultracode and a session-only effort on a tab chatq opens again

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

**To close:** Claude Code keeping them across a reopen, or taking them
with the open (an effort beside the prompt its open command takes) -
then the hook goes. A remote window would need the same from Claude
Code, or a `claudeCode.claudeProcessWrapper` on the remote side, with its
costs: Claude Code then resolves the permission mode itself and skips its
update check, and a broken or moved wrapper stops every chat.

## A queued run's Ultracode: an idle one reads as taken

**Closed:** a run's end now reads what it took from its own records
([Get-ChatqRunTook](src/queue.ps1)) - an `ultra_effort_exit` after its
start is Ultracode not taken, the `effort` on its first own turn is the
level it ran at - and puts the job and its history right
([Confirm-ChatqRunCarry](src/queue.ps1)); a `CLAUDE_CODE_EFFORT_LEVEL` in
the user's or the project's settings `env` counts as set, so no
`--effort` goes; and a `Workflow` allow rule in the user, project or local
settings carries Ultracode in any mode but plan, a deny or ask holds it
back in all ([Get-ChatqRunCarry](src/queue.ps1)).

**Why deferred:** the record is a delta (TESTING, S49 item 2,
2026-09-30, 2.1.285): a print run into a chat whose history says off
writes `ultra_effort_enter`, one whose history already says on writes
nothing, and a resume without the setting writes `ultra_effort_exit`. Not
known: whether Ultracode on but idle - workflows off where the watcher
runs (`CLAUDE_CODE_DISABLE_WORKFLOWS`, a Pro plan's default), a model
below xhigh - still writes the enter; if it does, such a run reads as
taken. Managed (org) settings are not read, for their rules or their
`env`. And the chat run of 2026-09-30 went at `medium` where the chat's
own turns went at `high`, unexplained - chatq now says so in the history,
but cannot say why.

**To close:** a spike - a print run with `CLAUDE_CODE_DISABLE_WORKFLOWS`
set, and one on a model below xhigh, each into a chat whose history says
off - and read what it writes; if it writes the enter, take the idle
cause from elsewhere (the environment, the model) before calling it
taken. Read the managed settings file where it exists.

## Closing a Claude panel may end another chat's channel

**Why deferred:** closing a Claude Code panel ends every channel it hosts
(the extension's `closeAllChannels`). A panel switched from one session to
another - **Session history** in the same tab - may keep a live channel for
the session it left; whether it does is unverified. If so, the handover's
close ([onHandover](extension/extension.js)) and Show it's
([showLive](extension/extension.js)) would end that other session's
process too. Show it's close before the handover had the same exposure.

**To close:** S48 item 4. If a panel keeps the old channel, close only a
panel whose one channel is the chat's - which needs the Claude extension to
say so - or say what else will end before the close.

## A tab Claude Code reopens late

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

**To close:** hold for as long as Claude Code still watches, not a fixed
30 s. Its output channel logs `Stopped checking for Claude Code tabs left
unresponsive by an extension restart` when the watch ends, but at debug
level, which the default log level leaves out; its info lines - `stopped
responding, so its conversation was reopened in a new tab`, `Its
conversation is still in use elsewhere` - are written. Reading Claude
Code's log beside this extension's own (`context.logUri`'s parent) for a
lost tab still waiting would key the hold to it. Failing that, a longer
hold costs only a process left running beside a new tab.

## The handover: small costs left

**Why deferred:** **PowerShell 7** has not run the handover's sections
(tests/sections/handover.ps1 and the checks beside it): `pwsh` is not
installed on the machine they were written on. CI runs both.

**To close:** a run of tests/run-tests.ps1 under `pwsh`.

## The unread dot lives in the overlay's memory

**Why deferred:** [Update-ChatOverlayUnread](src/overlay-data.ps1) marks a
chat as it goes from busy or waiting to idle, unless its window is in front
then ([Test-ChatOverlayInFront](src/overlay-data.ps1)), and only three
things clear it: an open from the chip that sent the window its request
([Update-ChatOverlayOpen](src/overlay-windows.ps1)), a new turn, and its
session ending. Reading the chat in VS Code later - its tab brought to the
front, its answer scrolled - clears nothing, since nothing outside the
window knows a tab was looked at. The marks are kept in memory alone, so a
restart clears every dot: marks read back from a file would mean turns
that ended while no overlay watched, which it cannot know. Windows only:
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
  never meets the window in front. The parents come from one
  `Win32_Process` snapshot a pass
  ([Get-ChatProcessTable](src/overlay-data.ps1)), taken only when a chat
  has just finished and its chain is not known yet, on the panel's
  thread; a snapshot over 250 ms is logged. Chains are kept for as long
  as the process lives. **To close:** the tab, not the program - only the
  extension knows which Claude tab is in front, as the bullet below needs
  anyway; for a handed-off console, the Windows Terminal that holds it,
  found some other way than the parents; and the snapshot taken off the
  panel's thread, as the console reads the chat index in a runspace of
  its own.
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

## Recent and the picker read the transcripts, not the index

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

**To close:** one reader. Keep in the index what all need - the title by
the Claude panel's order, the side and empty flags, the folder and the
write time - and have Recent read the index, synced as it goes; the picker
reads `chat-index.csv` too, or the same rules ported to node. Until then, a
change to one reader's title rules goes to the others - Recent's
[Read-ChatOverlayRecentItem](src/overlay-data.ps1) first, which has not
had the head look the picker got.

## The picker's window, off Windows and by label

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

**To close:** off Windows, `ps -o ppid=,lstart=,comm= -p <pids>` read into
the same facts, checked on macOS and Linux (see "CI on macOS and Linux").
For the label, the tab's own session id - which the Claude extension does
not expose to another extension today.

## A `claude -p` that is not chatq's

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

**To close:** for each reader above, decide whether a `claude -p` is a
chat there, and filter by `$script:ChatSdkEntrypoints` where it is not -
the overlay's and the board's rows against the job rows they duplicate.
For the records, S30 item 18 - run a `claude -p --resume` into a chat by
hand and read the `entrypoint` its records carry; if it is not `sdk-cli`,
have [Get-ChatBackgroundTasks](src/chatrm.ps1) `-SkipPrint` take that one
too - not through `$script:ChatSdkEntrypoints`, which mirrors Claude
Code's own listing rule ([Get-ChatUnlistedWhy](src/live-chats.ps1)).

## New chats Claude Code never lists

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

**To close:** ask upstream for SDK chats to be told apart by something
other than the file's first bytes, or listed behind a switch - the VS Code
webview hard-codes `includeProgrammaticSessions` off. Short of that, the
first option with its switches, re-checked at every Claude Code update.

## The board's handle moves on with a board the chat view was not drawn from

**Why deferred:** a board handle's time and length move on each time the PC
builds a board or a list that names it ([Register-ChatqPicks](src/phone-board.ps1)),
and a send from the phone is judged from then
([Get-ChatqMovedOn](src/phone.ps1)). The page draws a chat view from the
board it had when the chat was opened; a board asked for just before that,
or **Older chats** tapped on the board, lands after and moves the handle
on while the view stays as it was. A prompt typed at the PC in those few
seconds - under a minute, the page's refresh at most - is then one the
phone never showed, yet not refused.

**To close:** have the page send the time of the board or list its view was
drawn from with each act (`b`, the board's `ts`), and judge from the older
of that and the handle's; or redraw an open chat view from a board that
arrives, the text kept. Either changes what the page sends, so the page's
field checks and [Receive-ChatqCompose](src/phone-board.ps1) change with it.

## A reply refused as moved on loses its text

**Why deferred:** an alert's page learns nothing back but the push
([Invoke-ChatqReply](src/phone.ps1) answers only that way), and it drops its
draft once the post went through. When the chat moved on at the PC, the
push carries a link about it as it is now - and the text has to be typed
again there. The board keeps it, since its page waits for an ack.

**To close:** have the alert page wait for an ack under the alert's id on
the down topic, as its whole-answer panel does, keep the draft until the ack
says it went, and offer it again on the new alert's page.

## The overlay: what 0.4.0 left out

- **Codex and Copilot chats as live rows.** **Why deferred:** only Claude Code
  writes a list of what runs (`~/.claude/sessions/`). Codex's panel keeps a
  rollout open while a thread is shown, and Copilot records nothing at all.
  **To close:** for Codex, ask the shared app-server daemon for its threads
  (the one `codex queue` talks to; see the Codex entry above), or treat a
  rollout written in the last minute as working. Copilot waits on something
  that says a chat is running.
- **Linux.** **Why deferred:** nothing here runs Linux (see CI below), and each
  desktop has its own tray. **To close:** a GTK or tray-icon renderer reading
  the same `overlay.json`. `chatoverlay -Print` is the view until then.
- **The macOS panel has never run.** **Why deferred:** no Mac here. **To
  close:** checklist S24 in TESTING.md, and `osacompile` on a `macos-latest`
  CI leg.
- **A close on macOS does not hold.** With `-AutoStart on`, the menu bar
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
- **A hotkey on macOS.** **Why deferred:** a global key needs Carbon's
  `RegisterEventHotKey` or an accessibility permission, neither reachable
  cleanly from JXA. **To close:** only if the menu bar item turns out not to
  be enough.
- **The panel's buttons on macOS.** Windows has a row of buttons on the
  panel's top edge when the pointer is near it - grip, collapse, refresh,
  console, settings, hide, close - and edges to size it by. The Mac panel
  has only its menu
  bar item, and `-Theme`, `-Opacity`, `-Width`, `-Rows` and `-Refresh` from
  a shell; it has no collapsed view. **Why deferred:** the
  Mac panel has never run, and more untested Cocoa would not help that.
  **To close:** after S24, a second small `NSPanel` beside the first, the
  way Windows uses a second window, shown from a tracking area on the panel;
  the settings and collapse as menu items, which JXA can already make.
- **Recent on macOS.** The Mac panel has no Recent list, since it has no
  open chip to open one with, and its collector
  ([Start-ChatOverlayMacHost](src/overlay-mac.ps1)) sets `WantRecent` off,
  so the listing costs nothing there; `chatoverlay -Print` still lists
  Recent. **Why deferred:** as the buttons above. **To close:** after S24,
  draw it under the rows as Windows does, and turn `WantRecent` back on.
- **The edges come only after a rest.** A window's edges show their arrows
  the moment the pointer reaches them; the panel's come with the buttons,
  350 ms after the pointer rests on the panel or just outside it
  ([Update-ChatOverlayHover](src/overlay-windows.ps1)). **Why deferred:**
  the panel lets clicks through, so its edges are a window of their own
  ([New-ChatOverlayEdgesWindow](src/overlay-windows.ps1)), and shown all
  the time they would take the clicks and drags meant for the window
  under the panel's rim - the reason the buttons wait too. **To close:**
  only if the wait shows in use: a shorter rest for the band just outside
  the panel than for the panel itself.
- **Copilot usage without the GitHub CLI.** Copilot's line needs `gh`,
  logged in. **Why deferred:** VS Code writes only the plan to disk
  (`chat.setupContext` in `globalStorage/state.vscdb`, e.g.
  `free_limited_copilot`), never the quota; the figures come from GitHub
  with VS Code's GitHub login, which sits encrypted in VS Code's own secret
  store - not something another program should pry out. **To close:** if VS
  Code starts keeping the quota snapshot in its state, read it there.
- **Codex usage on demand.** Codex's figure is the `rate_limits` snapshot
  Codex writes into its own rollout during a run, so the refresh button
  cannot move it: it is as old as Codex's last run, and the panel says so.
  **Why deferred:** a fresh figure means asking OpenAI with the login Codex
  saved in `~/.codex/auth.json`, through an endpoint that is not documented
  and has not been looked into here. **To close:** find what Codex's own
  `/status` asks, and treat that token as the Claude one is treated - read
  for the one request, never stored, logged or refreshed - with the same
  waits on a refusal.
- **Usage without asking the endpoint.** Claude Code hands a status-line
  command `rate_limits.five_hour` / `seven_day` (`used_percentage`,
  `resets_at`) after every reply (code.claude.com/docs/en/statusline). That
  is current to the turn and costs no request, where the endpoint refuses
  when asked often. **Why deferred:** it means adding a command to
  `~/.claude/settings.json` - or wrapping one already there - and status
  lines are reported not to run in the VS Code extension's chat panel, which
  is where these chats live. **To close:** confirm whether the extension runs
  `statusLine`; if it does, an opt-in `chatoverlay -StatusLine on` that
  installs a one-line command writing `data/usage-statusline.json`, read by
  the collector ahead of the endpoint, and taken out again on `off` and on
  uninstall.
- **Naming a command while it runs.** While `/compact` runs, the row says only
  that a command is running. **Why deferred:** Claude Code writes the command
  down once it ends; until then its transcript holds a queue record with no
  text, and nothing else on disk names it. **To close:** if a later Claude
  Code puts the text in that record, or in `~/.claude/sessions/<pid>.json`,
  read it there.
- **More than one Claude account.** **Why deferred:** the overlay reads the
  one config dir it was started with (`CLAUDE_CONFIG_DIR`). **To close:** an
  `overlay.claudeHomes` list, a row group and a usage line per account.
- **The collector on a thread of its own.** **Why deferred:** a pass costs
  40-60 ms and the usage request never blocks, so the panel has not stuttered.
  **To close:** only if `data/logs/overlay.log` or use shows it does: a
  background runspace for the collector, handing snapshots to the UI thread.

## Copilot Chat

**Why deferred:** there is no CLI that resumes a Copilot chat headless. chatrm
can find Copilot chats, but nothing could deliver a prompt to one.

**To close:** a headless resume path from GitHub.

## Start at boot

**Why deferred:** nothing is registered with the OS, on purpose. After a reboot
the watcher returns with the next shell.

**To close:** an opt-in `chatinstall -AtLogon` that writes a Task Scheduler /
launchd / systemd user entry and removes it again on uninstall.

## CI on macOS and Linux

**Why deferred:** CI now runs the self-test on Windows under both 5.1 and
PowerShell 7. The Unix branches - `nohup`, `caffeinate`, `systemd-inhibit`,
`chmod 600`, `osascript` and `notify-send` toasts, `ioreg` idle time,
`Process.Kill($true)` - are written but have never run.

**To close:** add `ubuntu-latest` and `macos-latest` to the matrix. The tests
need a `fake-claude` shell wrapper next to the `.cmd` one, and the few
Windows-only checks (DPAPI, the echo exe) a skip on Unix.

## Codex threads archived from Codex's own panel

**Why deferred:** `chatrestore` lists what `chatrm -Archive` archived, from its
own records, plus any rollout under `~/.codex/archived_sessions/` - which spike
S16 showed is where `codex archive` moves one. Whether Codex's panel archives
the same way, rather than only in its sqlite state, has not been watched.
`chatrestore <id>` hands any id to `codex unarchive` either way.

**To close:** archive a throwaway thread from the Codex panel and look for it
under `archived_sessions/`. If it is not there, read the thread list from
Codex's app-server instead.

## Sponsorship

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

**To close:** pick one, add `.github/FUNDING.yml` with its handle, and swap the
badge for the real link.

## Social preview image

**Why deferred:** GitHub sets a repo's social preview only in the web UI
(Settings → Social preview); there is no API for it.

**To close:** upload a 1280×640 image made from `docs/demo-list.svg`.

## Weekly-limit and model-scoped limit handling

**Why deferred:** every limit seen on this machine was `five_hour`.
- A model-scoped limit (`seven_day_opus`, a `weekly_scoped` cache entry) no
  longer blocks the queue. The probe, asked with each chat's own model, decides.
- A job waiting on a real weekly limit just waits, without holding the machine
  awake.

**To close:** capture a real `seven_day` / `seven_day_opus` rejection. Check
the exact `rateLimitType` names against the list in `$script:ChatqWideLimits`.
Then decide whether a job should wait days, or alert and park.

## Overloads on Codex

**Why deferred:** the 529 handling watches status.claude.com, which covers
Claude only. A dropped Codex connection ("stream disconnected", "error sending
request") is retried like Claude's, but a Codex server error worded any other
way still fails the job.

**To close:** capture a real Codex 5xx/overload event. Then either watch
status.openai.com the same way, or just retry with the same backoff.

## Auto-continue for Codex chats chatq did not run

**Why deferred:** there is no cut-off scan for Codex rollouts
([Get-ChatqCutOffChats](src/queue.ps1) reads Claude's transcripts only). A
Codex job chatq ran is already continued by the watcher after a limit.

**To close:** a cut-off reader for rollouts - a `turn.failed` on the usage
limit as the last event, its reset from `ConvertFrom-ChatqLimitText` - and
the same checks; Codex writes no registry of what runs, so check 3 has
nothing to go on and a chat open in the Codex panel would need another way
to be told.

## Auto-continue: spikes A1 and A2

**Why deferred:** both need a real limit on Claude Code 2.1.234 or later,
reached on purpose, which no build session can spend. A read of this
machine's transcripts leans no for A1 - four panel cut-offs on 2.1.282 and
2.1.283 got nothing after the reset until a typed `continue` - but whether
those panels were on screen and idle is not recorded (TESTING.md). A3 was
answered the same way: the uuid is stable.
- A1: a chat open in a VS Code panel is held 5 minutes past the reset
  ([Get-ChatqAutoHold](src/auto-continue.ps1)), and the reset ask waits
  the same 5 minutes, in case the panel continues it itself. If A1 finds it
  reliably does, such a chat should be left to the panel as a terminal's
  is - a state `panel`, words `· VS Code continues it` - and the hold goes.
  If it does not, the hold stays as a guard.
- A2: `$script:ChatqContinueText`'s comment in [queue.ps1](src/queue.ps1)
  says what Claude Code writes. The resume record it names was seen; the
  wait's own continue was not.

**To close:** S41 item 2 and S42 items 1 and 4 with a real limit.

## Auto-continue and a registry entry that names no entrypoint

**Why deferred:** the two modes read such an entry differently. The reset
ask takes it for a VS Code panel, as `Test-ChatVsCodeOwned` does, and asks
about the chat; the automatic mode takes it as holding the chat, as a
terminal's would ([Get-ChatqAutoState](src/auto-continue.ps1)'s
`terminal`), and leaves it. Asking is harmless, a second writer is not, so
each errs its own safe way. Every entry on this machine names one (spike
A4); an old Claude Code might not.

**To close:** an entry with no entrypoint seen on a real Claude Code; then
read it one way for both, by the process that wrote it.

## Auto-continue on Linux, and the phone's switch

**Why deferred:** there is no overlay on Linux, so only a watcher running for
other jobs scans there; with none, nothing is auto-continued, and `chatqlist`
says so - and the reset ask has nothing to ask with. Turning auto-continue
on or off from the phone is left out on purpose: on grants unattended runs,
and off from a phone that may not be yours would quietly stop work
(docs/auto-continue-spec.md).

**To close:** for Linux, a scan at shell start or a timer the user opts
into; for the phone, nothing - it stays out unless that reasoning changes.

## Usage heads-ups without the overlay

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

**To close:** a small usage look of the watcher's own, once in 15 minutes
while it runs, through [Read-ChatqClaudeUsageCache](src/overlay-data.ps1)
and the rollouts, feeding the same function; for a PC with nothing queued
it would still need the overlay or a scheduled task.

## Quiet hours: one window, this PC's clock

**Why deferred:** kept simple on purpose. One daily window in the PC's own
time zone ([Get-ChatqQuietHours](src/phone-extras.ps1)): no weekday
schedule, no second window, not the phone's zone, and the toast and your
command are never held (the command is told `CHATQ_QUIET=1` and decides).
The summary answers no particular job - its alerts were never registered,
since registering them would keep the reply window open all night for
nothing - so a held `needs input` is answered through **Status** and
`chatqrun` at the PC. Android's own Do Not Disturb is the phone's.

**To close:** a list of windows with days in `quietHours`, read by the same
[Test-ChatqQuietNow](src/phone-extras.ps1); a summary that answers jobs would
register one alert per held job at summary time, not at hold time.

## Voice: speaker or headphones, and the Korean language code

**Why deferred:** Join's `say` speaks on whatever the audio output is, and
Join cannot tell whether headphones are in, so nothing is read aloud until
`join.say` names an event. Whether Android's text-to-speech takes `ko` or
wants `ko-KR` is not confirmed on a phone (TESTING.md, S43);
[Get-ChatqSayLanguage](src/phone-extras.ps1) sends `ko`, and a
`join.sayLanguage` of `ko-KR` already picks the Korean words. The soon
alert's spoken line, `Claude limit resets soon`, is not in the spec's
table, which names only the threshold and reset lines.

**To close:** S43 step 3 on a real phone; if `ko` is not read as Korean,
make `auto` send `ko-KR`. Headphones-only speech is a Tasker profile's job.

## The Tasker recipe, unchecked on a phone

**Why deferred:** README's recipe rests on two things Join's and
AutoNotification's pages do not state: that Join's *Push Received* event
fires for a push that also makes a notification and names its link
`%joinurl`, and that AutoNotification's reply field arrives as `%anreply`.
Step 1 of the recipe checks both before anything is built, and route B
needs neither of AutoNotification's.

**To close:** S43 step 4 on a real phone, and README's variable names
corrected to what the phone shows. If Join's event never fires for a
notification push, a Tasker-only push (a `join.tasker` mode, Join text with
no title) is the fallback.

## Approve permission prompts: what 0.9.0 left out

0.9.0 asks the phone about a permission prompt in a run chatq queued
([src/permit.ps1](src/permit.ps1),
[phone-permit-spec.md](docs/phone-permit-spec.md)). Left out:
- **Chats run straight in VS Code or a terminal.** **Why deferred:** only a
  `PermissionRequest` hook in the user's `~/.claude/settings.json` reaches
  them, and chatq has never written the user's Claude settings. **To
  close:** a hook command that hands the request to the watcher the way
  the bridge does - a request file, a sealed card, the phone's sealed
  answer checked by the hook itself - installed only by an explicit
  command, and removed by one.
- **Answering at the PC** (the console, the overlay, a toast button).
  **Why deferred:** the bridge believes an allow only on the phone's MAC,
  since anything can write into `data/`; a PC-side allow needs a secret the
  bridge can trust that no chat can read. **To close:** a per-run secret the
  watcher hands the bridge outside `data/` (its environment, say), and an
  answer MAC'd with it from the console's details pane.
- **The reply page on an origin of its own** (above) matters more now: a
  script on another `phal40lax78.github.io` page could post an Allow with
  the phone's key while a permission alert is open. The README and the
  setup window's tooltip say to serve the page from a site of your own
  first; closing that entry closes this.
- **S35 items 5-8 are unrun** (TESTING.md): the `//c/...` form of the data
  deny rules, elicitation under `host`, `auto`'s classifier, and two calls
  in one message. **Why deferred:** the spike's budget of five real runs
  went on items 1-4 and one run end to end. **To close:** run them, and if
  the `//c/...` form does not hold, drop those rules from
  [New-ChatqPermitRun](src/permit.ps1) - the bridge's own rule and the
  phone's MAC hold without them.
- **"Always allow", an edited command, a plan, Codex.**
  Out of scope by design (the spec's section 11); `codex exec` cannot ask
  mid-run at all. (A question is the phone's now, in chats you run
  yourself; the next section has what is left of it.)

## Claude's questions on the phone: what the first release left out

The phone shows Claude's `AskUserQuestion` for a chat you run yourself, and
with `chatnotify -Ask on` answers it through a hook of chatq's
([src/ask.ps1](src/ask.ps1), [phone-ask-spec.md](docs/phone-ask-spec.md)).
Left out:
- **Questions in chatq's queued runs.** They are still denied, with "make
  the most reasonable choice ... and go on"
  ([Get-ChatqPermitRule](src/permit.ps1)). **Why deferred:** the permit
  bridge cannot answer them - the CLI turns an allow for a tool that needs
  interaction, from an MCP `--permission-prompt-tool`, into a deny - and a
  run-scoped `PermissionRequest` hook is unproven there (S46 item 8,
  TESTING.md): which is asked first, and whether `localDisplayOnly` denies
  before the hook can answer. **To close:** run S46 item 8 with a queued run
  on `--permission-prompts host`; if a hook answers, give the run its own
  settings with the hook and stop denying the tool, with the same gates,
  digest and landed check.
- **A question open before the hook was loaded.** It shows on the phone,
  and says the hook does not hold it. **Why deferred:** the only way in is
  the VS Code dialog itself, and driving that from outside means moving your
  mouse or focus and breaking on any change to the extension. **To close:**
  the Claude Code extension or CLI offering a way to answer a pending
  question by its id; until then a chat opened or reloaded after `-Ask on`
  has the hook.
- **Terminal chats.** A `claude` in a console is declined `term`, `Answer it
  in the terminal.` **Why deferred:** nobody has seen the terminal's own
  prompt take a `PermissionRequest` hook's answer and close (S46 item 4,
  TESTING.md), and an answer that goes in beside a prompt that stays open is
  worse than none. **To close:** run S46 item 4 by hand in a terminal
  `claude`; if the prompt closes, drop the `term` gate from
  [Test-ChatqAskGates](src/ask.ps1) and run the landed check on it.
- **Plan approval (`ExitPlanMode`) through the same hook.** A `plan ready`
  chat is answered at the PC. **Why deferred:** it is likely the same kind
  of card and the same hook, but nothing has been checked - whether a
  `PermissionRequest` hook fires for it, what an answer looks like, and
  whether an approval is only text like a question's answer (it is not: it
  lets the chat act). **To close:** a spike like S46 for `ExitPlanMode`, and
  then a decision on what the phone may approve and in which modes, beyond
  a question's text-only rule.
- **A lighter hook launcher.** The hook loads all of chatq, so each held
  question is a hidden PowerShell of about 130 MB and 4-8 s to start
  ([Start-ChatqAskHook](src/ask.ps1)), 5 at once at most. **Why deferred:**
  it works and the cap bounds it; a second, smaller copy of the request
  code would have to stay equal to the first, byte for byte where the
  digest and the splice are. **To close:** a launcher that dot-sources only
  what the hook needs - the JSON and crypto helpers, the registry read, the
  digest, the answer check - with the self-test running the two against each
  other, and one PowerShell serving several questions.
- **A mode switched at the PC while a question is held.** With a cap set
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

## The phone board answers in seconds, not at once

**Why deferred:** the watcher polls the reply topic - every 20 s listening
all the time, 6 s for two minutes after the phone asked for something
([Get-ChatqReplyPollSeconds](src/phone-down.ps1)) - so a board or an ack
comes 3 to 20 s after the tap. ntfy can hold a stream open (`/json`
without `poll=1`) and hand each message over as it is posted, about a
second end to end, but the watcher's loop is built around short polls
that never block it: a stream needs a reader of its own.

**To close:** a runspace in the watcher holding `GET /<topic>/json` open,
passing each line to the loop through a queue, and reconnecting with a
backoff; [Invoke-ChatqReplyPoll](src/phone.ps1) stays for the catch-up
after a sleep, `since` its last id. The same 250-a-day budget is
untouched: a stream is one request.

## A home-screen app for the phone board

**Why deferred:** the board is reached from a bookmark or **Add to Home
screen** of the bare page. A web app manifest and a service worker would
give it an icon of its own, a full-screen start and an offline card, but
the page is one static file that loads nothing - its CSP has no
`manifest-src` or `worker-src` - and a service worker on the shared
`github.io` origin would be one more script there.

**To close:** a `manifest.webmanifest` beside the page (name, icon as a
`data:` URI, `display: standalone`, `start_url` the page), `manifest-src
'self'` in the CSP, and `reply-page-check.js` allowing exactly that one
`<link rel="manifest">`. No service worker: nothing is to be cached while
decrypted text lives only in the page's memory.

## Listening all the time off Windows

**Why deferred:** `reply.listen always` is begun again by a shell's start
and by the Windows overlay's host
([Start-ChatqReplyStanding](src/phone-down.ps1)); on macOS and Linux only
a shell does, since no overlay host runs there to do it, so after a reboot
the board has nobody listening until a PowerShell is opened. The board
itself works there - its scan
([Get-ChatqBoardScan](src/phone-board.ps1)) needs no overlay - but none of
it has been run off Windows.

**To close:** start it from the macOS overlay's collector as the Windows
host does, or from a launchd/systemd unit of chatq's own; then S44 in
TESTING.md on a Mac.

## Codex chats on the phone board

**Why deferred:** the board has no Codex rows. Its open, cut-off and
Recent rows are all Claude chats: the registry the overlay reads is
Claude's, [Update-ChatOverlayRecent](src/overlay-data.ps1) lists Claude
transcripts only, and [ConvertTo-ChatqPhoneBoard](src/phone-board.ps1)
keys every row as `claude`. Each of them now says its own mode
([Update-ChatOverlayText](src/overlay-data.ps1),
[Add-ChatqBoardModes](src/phone-board.ps1)). A Codex chat shows up only
as a queued job, and its chat view finds the chat's mode through the row
of the same chat (`chatOfJob` in `docs/reply.html`) - there is none, so
under a cap it reads `at most <cap>` - `at most acceptEdits` - which is
not even Codex's word: a Codex rollout keeps a sandbox, not a permission
mode. Nothing acts on it; the words are only less exact. With no cap, the
default, it reads `the chat's own mode`, which holds for a Codex chat too.

**To close:** carry the job's own sandbox to the page - the job already
holds the mode it runs in - and have the queue's chat view say it when
`chatOfJob` finds no row; or give the board Codex chat rows, read as
**Older chats** does ([Get-ChatqPhoneChatMeta](src/phone-board.ps1) with
`Provider = 'codex'`, capped at `workspace-write`), which a live state
would need a Codex registry of open chats for, and there is none today.

## A permission request bound to the stream's own input

**Why deferred:** since the 0.9.0 review the watcher makes a request's
digest again from the file's rid, tool and input and declines a file
changed after it was asked ([Update-ChatqPermitRequests](src/permit.ps1));
a writer that changes both input and digest gets a card the bridge's own
copy of the digest will never allow, so it can only run out as a deny.
What the watcher still does not check is that the input is the one the
stream showed for that `tool_use` id: it holds the tool's name by id
([New-ChatqRunState](src/queue.ps1)'s `ToolIds`), not its input.

**To close:** keep a hash of each `tool_use`'s input beside its name as
the stream is read, and decline a request whose input does not hash the
same - once it is known that the input claude hands the permission tool
is byte for byte the one its stream line carries (key order, escapes),
which S35 did not look at.

## chatq's data folder named in a command, every way

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

**To close:** for commands, nothing short of running them; if a real case
turns up, add its form to the needles and a row to the rules' table in
`tests/sections/permit.ps1`. For an edit's path, open the deepest folder
of it that exists and ask Windows for its final path
(`GetFinalPathNameByHandle`), in a helper with a timeout, since a path on
another machine must never be opened from the bridge.

## A phone-made chat's neutral title: when it gives way

**Why deferred:** needs a real `claude -p` run. A new chat started from
the phone with no name goes by `phone chat 14:02`
([New-ChatqPhoneNewChat](src/phone-board.ps1)), held on its jobs and in
`data/held-titles.json`, which outlives them
([Set-ChatqHeldTitleMark](src/queue.ps1)), and on a live alert about it
([Update-ChatqLiveAlerts](src/phone.ps1)), until Claude titles the chat
([Update-ChatqHeldTitle](src/queue.ps1),
[Get-ChatqHeldTitle](src/queue.ps1)). Whether a print-mode run writes an
ai-title record at all is unchecked - the fixtures write one by hand. If
it does not, the neutral title holds until the chat is renamed or opened
in VS Code, and the chat just keeps a dull name. The file keeps the
newest 200 marks: a chat pushed out of it, never titled and run again
after, goes back to its prompt's first line in alerts.

**To close:** start a chat from the phone with no name, let its run end,
and look for an `ai-title` record in its transcript. None: take the
title VS Code would show once the chat is opened, or say in the README
that a rename is how it gets one.

## What the new name promises

**Why deferred:** the rename to "Chat Manager for Claude Code & Codex"
(2026-09-28) and its "mission control" description promise more than the
product does. A review of what a user would expect from those words,
checked against the code, found these gaps. Each needs its own entry
before it is built.

Expected first:
- **Codex and Copilot chats as equals on the board:** no live state, no
  open chip, and no Copilot rows on the phone board.
- **Copilot in the queue:** chatq refuses a Copilot chat. See "Copilot
  Chat".
- **macOS and Linux:** the name says nothing about Windows. See "CI on
  macOS and Linux".
- **No terminal needed:** the commands reach a shell only through the
  profile line; palette commands for find, delete and queue would do.
- **A toast that opens its chat:** a click on the Windows toast only
  dismisses it.
- **Search that shows the passage:** `chatfind -Deep` never prints the
  line that matched.
- **Chats under WSL:** not found at all.

Expected later: filter the board by tool and project; model, context and
cost per row; a VS Code view of the board, past the picker and the
queue's status-bar item ([updateQueueItem](extension/extension.js)); fork a chat, or
send one prompt to several; rename, pin and tag; a first-run walkthrough;
Cursor, Windsurf and Open VSX; subagents under their chat; Codex cloud
tasks; export a chat to Markdown.
