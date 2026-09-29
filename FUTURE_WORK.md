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
done, and the prompt is yours rather than another session's. The notes below
stay for if a live delivery is wanted again.

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
- **An image pasted into a prompt tab that is then cancelled** stays in
  `data/queue/`. **Why deferred:** removing what appeared while the tab was
  open would also remove an image pasted at that moment into another shell's
  open tab. **To close:** sweep files in `data/queue/` that no prompt links to
  once they are a day old.

## `liveIdle` default

**Why deferred:** spike S29 showed the side bar keeps a chat's cached view
even once its process is ended, so ending it alone never shows the run; the
window has to show it anew - with Reload Webviews where nothing was
working, in 0.6.0, and in a tab of its own since 0.7.2. Since 0.6.0 the two
settings differ only in when the process goes:
- `warn` (the default) runs, then ends the idle process after the run when
  nobody is at the PC, and on Show it otherwise.
- `stop` ends it before the run, by the same checks
  (`Stop-ChatIdleProcess`), and waits, as for a busy chat, while a workflow
  or background agent is in flight.

Still open: whether a present user's process may be ended at the run's end
too. What a side bar does when the chat on screen loses its process - and
whether an unsent draft survives - has not been watched.

**To close:** S30 item 5 in TESTING.md. If the side bar takes it quietly and
keeps the draft, end it at run end whoever is at the PC, and drop the `live`
case.

## A chat typed into while chatq runs it

**Why deferred:** found on 2026-09-23, after the fix it would need was already
under way. An open panel does not follow a chatq run: a window reloaded
mid-run shows the chat as it stood at that moment, stopped halfway, and
`continue` typed there starts a second agent on the same session while
chatq's is still working. Both edit the same files at once. The panel's agent
knows nothing of what chatq's did after the fork, only the files. chatq checks
for a busy chat before a job starts, and never while it runs. The `started`
alert says nothing about keeping out of the chat.

What 0.6.0 does about it: Show it and the chip leave a chat alone while a
queued prompt or any `claude -p` goes into it (`Show-ChatFresh`, outcome
`running`); the next run into a chat waits 30 s after a request to show it
(`Get-ChatShowHold`); and a run into a chat a window opened while the run went
on is followed by a `ran` request, as for a chat held from before
(`Invoke-ChatqJob`). What is left is someone typing into such a window before
the run ends - a window that opened the chat mid-run, a startup open more
than 30 s after the chip's click, or the side bar's idle process under
`liveIdle: warn`.

**To close:**
1. Say so up front: when the chat is open in a window, the `started` alert
   says not to type in it until `done`.
2. Watch during the run. A record from another entrypoint (`claude-vscode`)
   whose parent is outside the run's own chain is a second writer: alert at
   once, naming the chat.
3. Decide whether chatq then stops its own run or lets both finish. Stopping
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
- **The continue chip on a cut-off row while the switch is ask or off.**
  With the automatic mode not on, a cut-off row has no auto-continue state
  and so no **continue** chip - its words and chip are as before 0.9.0, so
  the default's panel did not change under its users
  ([Update-ChatOverlayAutoStates](src/auto-continue.ps1)). **Why deferred:**
  the ask and the console's Continue already cover it. **To close:** keep
  the `off` state for rows, with the old words (`cut off - resets 13:00`)
  as its short words, so the chip offers **continue** in every mode.
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
- **A stale answer while the console is open** acts on nothing and says
  nothing; the console shows the ask as it is on its next redraw
  ([Invoke-ChatOverlayAskAnswer](src/overlay-windows.ps1)). In the panel it
  brings the panel up instead. **Why deferred:** `expand` would have taken
  the console back to the panel. **To close:** a status line in the
  console, "the chats changed - here they are now".
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
`https://phal40lax78.github.io/VS-code-chat-manager/`, and every project
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

## A pairing confirmed while the setup window saves

**Why deferred:** needs two things in the same instant, and every writer of
`data/config.json` would have to change. [Confirm-ChatqPairCandidate](src/phone.ps1)
reads `config.json`, adds the phone's key and saves it, with no lock, as
[Set-ChatqNotifyConfig](src/phone.ps1) does for the window's **Save**. A
Save that read the file just before the confirm wrote it can put back the
copy without the key, while the confirm has already cleared the pairing's
answers from `data/replies.json`. The phone is then not paired after all;
`chatnotify` says `not paired`, and `chatnotify -Pair` pairs it again.

**To close:** one lock around every read, change and save of
`config.json`, as [Use-ChatqReplyState](src/phone.ps1) holds
`data/replies.lock` for `replies.json`, taken by chatnotify, the window,
the pairing and the overlay's settings alike.

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

## A running overlay keeps its old code after an update

**Why deferred:** the overlay loads the script once, as it starts. An update
through the extension or `chatinstall` restarts it; files changed any
other way - a `git pull` in a checkout, a copy by hand - leave the old code
running for days, and `ChatVersion` may not even move. 0.8.0 only tells:
[Test-ChatqOverlayStale](src/phone.ps1) compares the overlay's start with
`src/phone.ps1`'s write time, and `chatnotify` says
`the overlay runs an older copy`. Nothing restarts it.

**To close:**
1. Note the newest write time of the script and every part in `src/` as
   the overlay loads them, and look again on the overlay's own pass, once
   a minute.
2. When a newer copy is on disk, restart through the same command
   `chatinstall` sends - but not while it is the console with a draft, or
   a drag is under way.
3. Drop the phone-only check once this covers it.

## Replies with neither Join nor ntfy over https

**Why deferred:** a reply starts with a tap on a push that opens the page.
Only Join and ntfy on an https server carry such a link: ntfy over plain
http drops it, since the pairing push's link names the reply topic and
would cross the network in the clear. The toast and your own command carry
none. Pairing is refused without a way ([Test-ChatqLinkChannel](src/phone.ps1)),
and alerts through ntfy over http carry no link.

**To close:** give your command the link, as `$env:CHATQ_LINK` beside
`CHATQ_TEXT` ([Invoke-ChatqAlertCommand](src/alerts.ps1)), so a Pushover or
Telegram command can carry it, and let the pairing go that way too. For
ntfy over http, https is the fix.

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
- **`chatq -New <folder>` in a shell.** **Why deferred:** the console was
  the ask; `New-ChatqJob -Kind new` does the work already. **To close:** a
  parameter set on `chatq` that calls it, with `-Name`.
- **Changing a waiting job's mode or model** from the console. **Why
  deferred:** only the prompt is editable in place; Remove and send again
  covers the rest. **To close:** the same chips in the details pane, written
  through `Set-ChatqProp`.
- **Answering a permission prompt from the console.** A run that asks is
  parked as needs-input, or since 0.9.0 asks the phone. **Why deferred:**
  see "Approve permission prompts: what 0.9.0 left out", below. **To
  close:** the same bridge ([src/permit.ps1](src/permit.ps1)), answered
  from the console's details pane.
- **Opening the chat in VS Code** from the console. **Why deferred:** the
  console was not in 0.6.0's scope. Since then the way exists: the overlay's
  open chip writes `data/open-request` and the extension opens the chat by
  its id. **To close:** a button in the console's details pane that calls
  `Start-ChatShowFreshProcess` for the picked chat, as the chip does.
- **The reply as it streams.** The console shows a run's reply once the run
  ends. **Why deferred:** reading a log the watcher holds open works now
  (`Get-ChatqLogEntries` shares with the writer), but redrawing the details
  pane every pass costs the window's thread while a long run writes
  megabytes. **To close:** read only what the log grew by since the last
  pass, and append it to the pane rather than redrawing it.
- **Every argument hardened for `claude.cmd`.** An npm install's
  `claude.cmd` runs through cmd.exe, which does not read `\"` as an escape.
  A new chat's `--name` has `"%!&|<>^` taken out for it. **Why deferred:**
  the other arguments are chatq's own - a session id, a mode, the tool's
  data folder - apart from `chatq -Model`, which you type yourself.
  **To close:** in `ConvertTo-ChatqArgLine`, quote any argument holding
  `&|<>^()` when the executable is a `.cmd` or `.bat`, and refuse one
  holding `"` or `%`.

## The console in the panel's place: what 0.7.2 left out

- **Maximize, and a place of its own.** The console had a title bar and
  kept where it was and whether it was maximized. As the panel's mode it
  has neither: no maximize button, and each time it grows from the panel's
  corner ([Get-ChatConsolePlacement](src/console.ps1)). An older
  `console-state.json`'s `x`, `y` and `max` are dropped as it is read
  ([Read-ChatConsoleState](src/console.ps1)). **Why deferred:** "in the
  panel's place" was the ask, and a place of its own would undo it; a
  maximized console would also have to be put back to its size before the
  panel's can be, which
  [Exit-ChatOverlayConsoleMode](src/overlay-windows.ps1) does by setting
  the state to normal first. **To close:** a maximize button in the
  header beside **← Panel** that flips `WindowState`, kept in
  `console-state.json` as `max` again and applied at the end of
  [Enter-ChatOverlayConsoleMode](src/overlay-windows.ps1).
- **Resizing from every edge.** Only the grip at its bottom-right corner
  resizes it. **Why deferred:** the panel's window is see-through and has
  no frame (`AllowsTransparency`, `WindowStyle` None), which WPF cannot
  change once the window exists, so there is no border for Windows to
  size it by; the grip was enough to size it. **To close:** a
  `WindowChrome` with a `ResizeBorderThickness` set as the console mode
  starts and cleared as it ends, or a hit test of our own answering
  `WM_NCHITTEST` near the edges.
- **Its size kept in pixels.** [Save-ChatConsoleDraft](src/console.ps1)
  keeps the window's size in screen pixels, so a console sized on a 150%
  monitor opens on a 100% one at the same pixels, holding half as much
  again. Only the first-time 980 x 680 and the window's least size
  (640 x 420 units, which the window enforces) go by the screen's scale:
  [Enter-ChatOverlayConsoleMode](src/overlay-windows.ps1) turns that least
  into the panel's screen's pixels and
  [Get-ChatConsolePlacement](src/console.ps1) raises a smaller saved size
  to it before holding the right edge, or Windows would enlarge the window
  from its left edge, past the panel's corner. **Why deferred:** one
  monitor here; with the least raised, the placement is all in the one
  screen's pixels and held to its working area, so a size kept in pixels
  only holds more or less, never lands off the screen. **To close:**
  keep `w` and `h` in units - divided by the scale
  ([Get-ChatOverlayScale](src/overlay-windows.ps1)) as they are saved,
  multiplied by the panel's screen's as it opens - and check it with S33
  item 33.
- **The fallback for an older `ChatOverlayNative`.** A process that loaded
  an older copy of the script keeps its type, which has no
  `ApplyInteractiveStyle` or `DropTopmost`;
  [Initialize-ChatOverlayNative](src/overlay-windows.ps1) then compiles the
  same code again as `ChatOverlayNativeNext`, and the console's mode calls
  through that. **Why deferred:** no test loads the older type first -
  every test child starts from a fresh process - and the overlay itself
  always does too, its restart on an update included
  ([Start-ChatOverlayProcess](src/overlay.ps1)). **To close:** an STA
  child that `Add-Type`s a `ChatOverlayNative` without those two methods
  before dot-sourcing the script, then opens the console and reads its
  styles.

## A VS Code front end

**Why deferred:** the terminal UI was chosen, and then the overlay's console.

**To close:** grow `extension/`, which already offers the reload after a
delete or an archive, shows a queued run's chat fresh in the window that
holds it, and since 0.7.2 has a chat picker, **Chat Manager: Open chat...**
([openChat](extension/extension.js)). What is left is a status-bar count of
queued jobs and the next send time. The picker reads the transcripts
itself rather than the index `chatfind` uses: see "Recent and the picker
read the transcripts, not the index" below.

## The extension's signal file holds one request

**Why deferred:** `data/reload-request` is one file, and the extension polls it
every 2 seconds. Two requests inside one poll - a delete right after a queued
run, say - and the first is overwritten unseen. Rare, and the cost is one
missed button. Since 0.6.0 the overlay's open chip writes a file of its own,
`data/open-request`, so a click and a run never overwrite each other; the one
slot remains within each file.

**To close:** make it a short array with ids, and have the extension keep the
last few ids it has seen instead of one.

## Background shells and "safe to reload"

**Why deferred:** the reload check counts workflows and background agents a
chat started that have not reported back, but not a Bash command run in the
background (`backgroundTaskId`). One is as often a dev server or a watcher as a
build, and a server never reports. Counting them would hold the project
"active" for as long as it runs, and `-WaitForIdle` would never return. A
reload still kills a background build with the chat's process. So, since
0.6.0, does showing a chat fresh after a run or through Show it:
`Stop-ChatIdleProcess` ends the chat's idle process with `taskkill /T`, dev
servers and all. Nothing warns. The open chip no longer ends anything.

**To close:** tell the two apart. A shell the model started with a timeout, or
one that moved to the background after its timeout ran out (`timedOutAfterMs`
in its result), is meant to end, so it could count. One started with
`run_in_background` and no end in sight would not. Before relying on that,
check the CLI keeps those fields stable. For the ending itself, a chat's
process with child processes other than its MCP servers could count as
`held` - once MCP servers can be told from shells the model started.

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

**Why deferred:** since 0.9.0 an update of chatq waits, if asked, until
the window's chats are idle ([safe-restart.js](extension/safe-restart.js)),
and chatq's own reloads look first. But a window can still be reloaded or
restarted under working chats - **Reload now**, VS Code's own **Restart
Extensions** button, **Developer: Reload Window**, an update of another
extension, VS Code updating itself - and each chat cut off mid-turn stays
cut off: its answer half written, a permission prompt gone, a workflow's
agents dead, and nobody told. The owner lost a session that way twice on
2026-09-27. Continuing such a chat is what auto-continue does for a chat
the usage limit cut off ([docs/auto-continue-spec.md](docs/auto-continue-spec.md)):
a marker per cut-off, a continue queued, the ask on the overlay's row and
the phone. That machinery is in 0.9.0 too
([src/auto-continue.ps1](src/auto-continue.ps1)); this was left for after
both were in one tree, so there is one way of continuing a chat, not two.

**To close:**
1. **Note what the old host ran, as it goes.** The wait's look (`Get-ChatHostWork`)
   already knows each chat of the window and why it works. Write the
   last look to `data/host-work/<host pid>.json` - chats, why, the
   transcript's size - on every look while something works, and as the
   notice goes out; a file per host, removed once all is idle.
2. **At the next activation, find what was cut off.** The extension finds
   a file whose host pid is no longer alive (`_alive`), or whose host is
   not this one but whose chats this window now holds again. For each chat
   listed as working, the transcript tells whether the turn was cut off:
   its last message an assistant `tool_use` with no `tool_result`, or a
   `user` prompt with no answer, and nothing written since the host ended
   - Test-ChatTranscriptBusy's reading, taken as "cut off" once the
   process that owed the answer is gone. A background workflow or agent
   with no `<task-notification>` (Get-ChatBackgroundTasks) died too.
3. **Offer to continue them through the cut-off ask** of auto-continue,
   with a reason of their own (`restart` next to its `limit`): the same
   marker file, so a chat is continued once, the same ask on the overlay's
   row, the phone and the console, and the same queued job - a "continue"
   in the chat's own mode. The prompt has to say what was lost - "the
   window restarted mid-turn; your background workflow <name> did not
   finish" - since `claude --resume` does not bring back a background
   task. Nothing continues by itself unless the auto-continue switch says
   so for that reason too.
4. **Tests:** a host file with a chat cut off mid-`tool_use`, one idle
   and one whose workflow never reported; the next activation offers the
   first and the third, once, and nothing for a host still alive.

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
`Update-ChatOverlayText` reads transcripts that way.

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
idle, as a stale tab is closed only once the run's check has ended its
process ([plan](extension/extension.js), [showTab](extension/extension.js)).

## A message typed before the tab is shown fresh

**Why deferred:** after a run into a chat open idle in a tab, the window
shows it fresh by itself ([showsItself](extension/extension.js)) - but
a few seconds after the run ends: the watcher's request, then Show it's
check. A message typed into the stale tab in that gap goes on from the
tab's memory and forks the chat, the run's turn on a branch that tab
never shows; so does one typed in a window whose extension is older
than 0.8.1, which only asks. `"liveIdle": "stop"` ends the idle
process before the run instead, which closes the gap, at the price of
a tab on a dead process until it is shown.

**To close:** end the tab's idle process as the run starts whenever the
window will show the chat fresh anyway, so the stale tab cannot take a
message at all - or a Claude Code command that reloads a panel by its
session id.

## A closing process reads as a working chat for 60 s

**Why deferred:** [Test-ChatIdle](src/chatrm.ps1) counts any transcript in
the folder written in the last `$script:ChatIdleSeconds` (60 s) as live, on
top of what `claude agents` says - for Codex that file time is all there
is. A `claude` process that is closing writes its metadata (cost-state) to
its transcript on the way out, so for a minute after a Claude tab is closed
the folder reads busy. A queued run that ends then asks instead of showing
the chat by itself. Only the chat the run wrote is left out (`-Except`).
The cost is one more question, never a lost answer.

**To close:** tell a closing write from a turn. Read the transcript's last
record, and leave out one that is only that metadata - its record type
read off a real transcript first - or one written after its process left
`~/.claude/sessions/`.

## Show it ends the old process before the tab is known

**Why deferred:** Show it's child ends the chat's idle process
([Show-ChatFresh](src/live-chats.ps1), `-Via button`), and only then does
the extension look for the chat's tab. A run while you are away ends it the
same way. If [showTab](extension/extension.js) cannot be certain of the
stale tab - a chat of no title, a label that matches neither form, a tab
that did not come forward - it leaves it and says to close it. Until then
that tab sits on a dead process, showing "Claude Code process exited with
code 1". Closing it and opening the chat again recovers it.

**To close:** close the tab first and end the process after. Closing an
editor panel ends its process gracefully (the Claude extension's code: end
of stdin, killed only if alive about 7 s later), so the extension could
close a tab it is certain of and have the script only judge, or end the
process itself once the tab is found. Either moves the ending across the
line between the script and the extension, which changes the request they
share.

## Two chats whose titles share 24 characters

**Why deferred:** [showTab](extension/extension.js) knows a Claude tab only
by its label, since no command lists panels by session id and a webview
tab carries only its `viewType`. Claude cuts a title over 25 characters to
its first 24 and `…`, so two chats that begin with the same 24 characters
carry the same label. Closing a tab ends that chat's process, so a label
that another open Claude tab shares, or that another chat of the folder
would carry, open or not ([labelShared](extension/extension.js)), is never
taken as sure: the stale tab is left, and you are told to close it
yourself. The cost is that step by hand, for the chats whose titles begin
alike.

**To close:** a session id on the tab, or a Claude Code command that reloads
a panel by session id.

## A chat whose label another chat has is refused until renamed

**Why deferred:** the same blind spot reaches the chip and the picker. A
working chat opens only through its one tab here, and
[openTab](extension/extension.js) and [acceptChat](extension/extension.js)
count that tab as the chat's only while
[labelShared](extension/extension.js) finds no other chat of the folder -
open or long closed - whose title gives the same label. So a chat working
in its own tab is refused as if it worked in the side bar, one idle there
asks **Open here too**, and Show it leaves its stale tab, for as long as
the two titles share their first 24 characters. Renaming either chat
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
Counting only the chats a live process holds would not do: a tab stays up
on a dead process once a run or Show it has ended the chat's process
("Show it ends the old process before the tab is known", above), so a chat
with no process can still own the tab of that label.

## The chip shows a tab as it is

**Why deferred:** the chip ends no process
([Show-ChatFresh](src/live-chats.ps1), `-Via chip`): ending the one under a
tab that still showed the chat is what left two views on a dead process
on 2026-09-25. So [openTab](extension/extension.js) only brings forward a
tab the chat has, on the process it has. A queued run that ended while that
process lived is not in the tab yet, and that process does not read the
transcript again: a message typed there goes on from before the run. The
run's own Show it closes the tab and opens it again; the chip does not.

**To close:** let the extension remember a `ran` request it offered Show it
for and has not acted on, and send an open for that chat down Show it's
way instead - the check ends the idle process, and
[showTab](extension/extension.js) closes and reopens the tab it is certain
of. Or have the chip's script compare the transcript's last write with
when the window's process started, and say `stale` in the request.

## Closing the overlay does not keep it closed

**Why deferred:** since the overlay starts by itself
([Start-ChatOverlayAuto](src/overlay.ps1)), × and `chatoverlay -Stop` close
it only until the next shell or VS Code window starts it again.
The one lasting off is the switch `overlay.autoStart` in `config.json`,
set by `chatoverlay -AutoStart off` or, with no terminal, by **Chat
Manager: Overlay: start by itself...** in VS Code's command palette
([overlayAutoStart](extension/extension.js)). One switch was what it took
to make the chip the way in first.

**To close:** remember a close made by hand - a mark in
`overlay-state.json` the auto start honours until the next sign-in or until
`chatoverlay` is typed - and say so as it closes.

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
  at work, which the window may refuse. The window may still refuse the
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
transcript and takes Claude's title over the sidecar's rename, where the
two readers take the sidecar first and look only in the last 256 KB. So a
large chat renamed early, or one renamed only in the panel, can read one
title in Recent or the picker and another in `chatfind`, and a chat can be
listed in one before the other.

**To close:** one reader. Keep in the index what both need - the title by
the Claude panel's order, the side and empty flags, the folder and the
write time - and have Recent read the index, synced as it goes; the picker
reads `chat-index.csv` too, or the same rules ported to node, head and tail
alike. Until then, a change to one reader's title rules goes to the others.

## The picker cannot tell which window holds a live chat

**Why deferred:** the Claude registry (`~/.claude/sessions/<pid>.json`)
says a panel holds a chat, not which VS Code window it is in, and
[acceptChat](extension/extension.js) has only the labels of this window's
tabs to go on. So a chat open and idle in another window reads the same as
one in this window's side bar - both ask **Open here too** - and one
working in another window is refused where it could be brought forward
there. A chat of no title never counts as in a tab here, since every such
tab reads "Claude Code", so it always asks, and neither does one whose
label another chat of its folder has ("A chat whose label another chat has
is refused until renamed", above). The overlay's chip knows the window
from the process's parent (`hostPids`); the picker reads no process tree.

**To close:** the parent pid of each live entry's `pid` - the extension
host, as `hostPids` names it (S30 item 12) - compared with this
extension's `process.pid`: this window's side bar, another window, or a
terminal. Another window's chat could then be handed to that window
through `data/open-request`, as the chip does.

## The picker's own reads

- **Titles only from the tail.** [readChat](extension/extension.js) looks
  for a rename and Claude's title in the last 256 KB. **Why deferred:**
  that was the spec, and a transcript's newest title is at its end; one
  written only near the start of a large file is rare. **To close:** look
  in the head's 256 KB as well when the tail has neither, as the index
  does.
- **A stale registry entry.** [entryLive](extension/extension.js) takes an
  entry as live when its pid answers and its `startedAt` is neither ahead
  of now nor from before the machine last started (60 s of slack). A pid
  handed on since boot to another process still reads live. **Why
  deferred:** the process's own start time needs a platform call per pid;
  the overlay's collector does it, in PowerShell. **To close:** compare
  `procStart` with the process's start time where node can read it, as
  [Test-ChatqSessionAlive](src/live-chats.ps1) does.

## A `claude -p` that is not chatq's

**Why deferred:** since 0.6.0 a chat's background work is told apart by
the `entrypoint` its records carry, and a print-mode run's (`sdk-cli`) is
taken for dead once no print-mode process of the chat is alive
(`Test-ChatPrintLive`, `Get-ChatBackgroundTasks -SkipPrint`). A queued run
is also known from the queue. Someone else's `claude -p --resume` into the
same chat is known only from `~/.claude/sessions/` - and whether a
print-mode process writes a file there, and with what `kind`, has not been
watched. If it writes none, such a run going on is invisible: its workflows
would read as dead, and Show it could end the window's process beside it.
The picker's **a queued prompt running** state
([chatState](extension/extension.js)) reads the same `kind`, so such a
run would show there as whatever else holds the chat, or as closed.

Seen on 2026-09-27 (S38 item 5): a queued run's `claude -p` registered in
`~/.claude/sessions/` as `kind` `interactive`, `entrypoint` `sdk-cli`,
`status` `busy` while it ran - as Claude Code 2.1.283's code has it, which
gives the kind `bg`, `daemon` or `daemon-worker` only from
`CLAUDE_CODE_SESSION_KIND`. So the kind cannot tell a print-mode run, and
the tests' `print` is a stand-in: `Test-ChatPrintLive` and the picker's
**a queued prompt running** never see one. The listing's holds
([ensureListed](extension/extension.js),
[Repair-ChatListed](src/live-chats.ps1)) look at `busy` and `waiting` as
well, for that reason.

**To close:** tell a print-mode process by its registry `entrypoint`
(`sdk-cli`) where the kind says `interactive`; S30 item 18 for whether its
records name it the same way.

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

## The open chip clears the unread dot of a chat it cannot open

**Why deferred:** the chip's child exits once the open request is written,
and the overlay clears the unread dot on that code. For a chat Claude Code
can never list, the window then offers a terminal instead of a tab - and
the dot is gone even when the offer is dismissed. It matters only for
chats **+ New chat** made.

**To close:** have `Show-ChatFresh -Via chip` read the chat's head as
[Get-ChatUnlistedWhy](src/live-chats.ps1) does, and exit with a code the
overlay does not take as shown.

## Only the overlay closes a job answered in the chat

**Why deferred:** a job parked on input is skipped once its chat is typed
into after it stopped ([Close-ChatqAnsweredJobs](src/overlay-data.ps1)),
but only the overlay's pass does it: it already reads each open chat's
newest prompt every two seconds, so it costs nothing there. With no overlay
running - off, or on Linux - `chatqlist`, the console and the phone's
**Status** go on saying the job needs you until `chatqrm`.

**To close:** call it from `chatqlist` and the phone's **Status** too, with
a context of their own, so a transcript's tail is read there only for a
job whose chat moved after it stopped.

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
- **Full screen.** **Why deferred:** a game in exclusive full screen draws
  over any window, and that is expected. **To close:** hide the panel while
  `SHQueryUserNotificationState` says full screen or presentation mode.
- **The macOS panel has never run.** **Why deferred:** no Mac here. **To
  close:** checklist S24 in TESTING.md, and `osacompile` on a `macos-latest`
  CI leg.
- **A hotkey on macOS.** **Why deferred:** a global key needs Carbon's
  `RegisterEventHotKey` or an accessibility permission, neither reachable
  cleanly from JXA. **To close:** only if the menu bar item turns out not to
  be enough.
- **The panel's buttons on macOS.** Windows has a row of buttons on the
  panel's top edge when the pointer is near it: grip, resize, collapse,
  refresh, console, settings, hide, close. The Mac panel has only its menu
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
- **Recent redrawn only on the next pass.** The settings box's Recent
  chips save at once ([Set-ChatOverlayRecentChoice](src/overlay-windows.ps1)),
  but the list changes up to two seconds later. **Why deferred:** building
  it lists every project's transcripts, which on the window's thread would
  stall the panel. **To close:** only if the wait shows: have the collector
  run its pass as soon as the setting is saved, as a refresh asks for usage.
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

## Auto-continue after a 529

**Why deferred:** [auto-continue](docs/auto-continue-spec.md) is for the
usage limit only, and so is the reset ask. A 529 has no reset time, someone
at the panel usually retries it at once, and chatq's own jobs already wait
out an outage on status.claude.com. A chat nobody has open that a 529
stopped still reads `529 - waits for Claude` and nothing is queued.

**To close:** the same scan with `Why` `overloaded`
([Get-ChatqAutoState](src/auto-continue.ps1) returns `overloaded` for it
today), the job released by [Test-ChatqOutageOver](src/watcher.ps1) rather
than a reset, and the moved-on check as for a limit.

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
- **"Always allow", an edited command, `AskUserQuestion`, a plan, Codex.**
  Out of scope by design (the spec's section 11); `codex exec` cannot ask
  mid-run at all.

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

## One job maker for a reply and the board

**Why deferred:** the spec wanted the body of
[Invoke-ChatqReply](src/phone.ps1)'s `prompt` case factored out as
[New-ChatqPhoneJob](src/phone-board.ps1) and called from both. 0.9.0 was
built by several hands at once from one commit, and rewriting a case of a
function every one of them touches would have made their merges
conflict, so the board has its own copy of the same steps - the text
checked, the chat's own mode brought down to `reply.maxMode`, a Codex
sandbox no wider than `workspace-write`, rule `phone`, links defused.

**To close:** now that 0.9.0 is one tree, have the `prompt` case call
[New-ChatqPhoneJob](src/phone-board.ps1) (it takes `-JobHome` and the
cap as the case does) and keep the case's own words about a needs-input
job it answers; `phone.ps1`'s cap checks then hold both.

## The board's chat view shows the cap, not the chat's mode

**Why deferred:** a chat's own mode is in its transcript, and the board is
built every 30 s from what the overlay already knows, which has no mode,
so the chat view's chip says `at most acceptEdits` for every chat the
board shows. **Older chats** - the list, `act list` - say each one's own
mode, from a bounded read ([Get-ChatqPhoneChatMeta](src/phone-board.ps1))
the board does not make every 30 s. Codex chats also show no live state:
the registry the overlay reads is Claude's.

**To close:** read the last `permissionMode` where the overlay already
reads each open chat's tail
([Update-ChatOverlayText](src/overlay-data.ps1)), carry it in
`overlay.json`'s rows, and project it in
[ConvertTo-ChatqPhoneBoard](src/phone-board.ps1) as the list does
(`m`, `mc`).

## The phone board and auto-continue

**Why deferred:** the board and auto-continue were built side by side and
met only in the 0.9.0 merge. The board's cut-off rows carry no
auto-continue state: [ConvertTo-ChatqPhoneBoard](src/phone-board.ps1) and
the board's own scan ([Get-ChatqBoardScan](src/phone-board.ps1)) pass no
`-Auto` to [Get-ChatOverlayRows](src/overlay-data.ps1), so the phone shows
`cut off` where the overlay shows `#12 auto 13:01`, and offers **Continue at
reset** while the switch is on and would queue one by itself. Nothing
breaks; the words differ.

Since the review of the integrated 0.9.0 the board's **Continue at
reset** writes that marker ([Invoke-ChatqCompose](src/phone-board.ps1),
through [Save-ChatqAskAnswer](src/queue.ps1) with `-Source phone`), so a
skip from the phone counts as declined and never comes back; and a kept
auto-continue with no state to show - the board's scan passes none - has
a row of its own there ([Get-ChatOverlayRows](src/overlay-data.ps1)).
What is left is the words.

**To close:** carry the overlay's auto words in `overlay.json`'s rows and
project them in the board as the overlay's row does; checks in
`tests/sections/phone-board.ps1` and `board-page-check.js`.

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

## A phone-made chat's title in later alerts

**Why deferred:** a new chat started from the phone with no name takes
its prompt's first line as its title, and since the 0.9.0 review the
push that says it was queued names neither. But every later alert about
that job - started, done, needs input - carries the chat's title, as
every alert does (README: what an alert's text carries passes through
the push service's servers).

**To close:** give a phone-made chat with no name a neutral title
(`phone chat 14:02`) until Claude's own ai-title arrives, and take the
chat's title from the transcript from then on.

## A board from a scan is up to 40 s old

**Why deferred:** with no overlay running the board is built from a scan
of the registry and the transcripts, which inside a run held up the run's
output and its permission requests, so since the 0.9.0 review one is sent
again for 40 s ([Get-ChatqPhoneBoardAnswer](src/phone-board.ps1)). An act
from the phone drops it at once, but a job that starts or ends by itself
meanwhile shows up to 40 s late.

**To close:** keep the scan's rows for 40 s but build the queue part from
the jobs on every ask, as the overlay's snapshot path does.

## A run chatq did not start, into a chat no window holds

**Why deferred:** since the 0.9.0 review a reload's wait counts every
running chatq job, even into a chat no process of the window holds any
more ([Get-ChatHostWork](src/host-work.ps1)): a run before it may have
ended the window's idle process on purpose, and a tab still shows the
chat. Someone's own `claude -p` going into such a chat is not counted:
nothing ties it to this window once the window's process is gone, and an
endless script of `claude -p` calls would hold every reload.

**To close:** note in `data/` the chats each host's idle process was
ended for ([Stop-ChatIdleProcess](src/live-chats.ps1) knows the host
pids), and count any print-mode run into those for that host.
