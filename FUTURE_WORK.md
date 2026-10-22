# Future work

Open problems: what is still to find out or to do. Each says why it waits
and what closing it would take. Deliberate deferrals - what was knowingly
left as it is - are in [DEFERRED.md](DEFERRED.md).

## The native panel's gaps against the WPF one (M9a)

What the Slint panel ([App](native/overlay/src/app.rs)) and its host still
do differently:

- **Shipping.** No build of the panel ships: release.yml packs
  `chatq-overlay-<version>-x86_64-pc-windows-msvc.zip`, but nothing
  fetches it yet, so 0.11.0's panel is a developer's build put under
  `bin/` by hand.

- **Host.** A panel that dies after carrying out a command but before
  its next `overlay-ui.json` says it is done (`done`,
  [Update-ChatOverlayCommands](src/overlay-host.ps1)) leaves it listed,
  and the panel started in its place carries it out again; the host
  reads the panel every 1 s, the WPF one 2 s; a reload does not write a
  slider still at rest first.
- **Tray and balloons.** One balloon at a time, queued; the min button's
  first-time balloon only with a tray; AskGo's tip names 5 chats, the WPF
  one 10; the tray picture is area-averaged. The live tray and hotkeys are
  Tier 1 only.
- **Pointer.** Hover's "down" reads every mouse button; a button released
  over another does nothing; a press on a slider's track jumps with no
  drag; a frame drag polls the cursor every 16 ms rather than DragMove;
  tooltip delays are near, not exact.
- **Drawing.** The slider imitates Aero2; the goldens hold this PC's fonts;
  the card's outline is a union of rects and the regions are square; the
  hint is cut past 72 characters; the text measurer's cache grows per
  distinct text.
- **Console.** It is the WPF one, in a window of the headless host's own
  ([Open-ChatOverlayHeadlessConsole](src/overlay-windows.ps1)). WPF loads
  at its first ask and stays loaded until the host's next restart, from
  the text the host read as it started
  ([Read-ChatOverlayConsoleParts](src/overlay-host.ps1)), some 0.5 MB
  held for the host's life; a file changed in the moment between the
  code's stamp and that read loads the new text beside the old parts,
  until the code-change restart that follows.
  The host's passes wait while a loop of the console's own runs (its
  folder picker), its timer keeping the snapshot new. The native panel
  hides, and comes back, on the pass after the switch, so the two can
  overlap or leave a gap for up to 1 s. With no panel rect and no place
  kept, it opens at the nearest corner. A refresh in the console (a
  `-Peek` pass) reaches the native panel a pass later, and an ask that
  changed under its answer is not shown while a close by hand is under
  way. `chatconsole` with no overlay running starts the WPF overlay while
  that is the default.
- **Other.** The card waits for card.json; the real full-screen query
  is read answer by answer ([win32.full_screen_of](native/overlay/src/win32.rs))
  but only this PC's own answer comes from Windows itself - a real full
  screen in front is Tier 1; commands are logged by verb alone.

## A Recent line's chip hint cut at the screen's left edge

**Why it waits:** found in review for 0.10.19; it needs a narrow Recent
line on a panel flush to its screen's left edge.
- **The gap.** The chip's hint - `click again`, `opening 3s`, `sure?` -
  is right-aligned in a 72-unit room left of the bin
  ([New-ChatOverlayChipContent](src/overlay-windows.ps1)). A Recent
  line's box is narrower than that room, so the room hangs past the
  panel's left side. Flush to the screen's edge,
  [Get-ChatOverlayChipLayout](src/overlay-windows.ps1) cuts the part past
  the screen rather than moving the window, so the bin stays on the
  tile's bin. A long hint loses its first letters there.
- **Closing it.** Draw the hint somewhere that always has room, e.g. on
  the card's side as the words are, and drop the room from the icons.

## Deliver into a live Codex chat through `codex queue`

**Why deferred:** found after v0.1.0, and re-read on codex-cli 0.159.2
(openai.chatgpt 26.928; spike S-A5 in TESTING.md).
- **The gap today.** chatq never checks whether a Codex thread is open in a
  VS Code window, and every Codex job goes through `codex exec resume`. An open
  Codex panel then goes stale, like a Claude one, and nothing says so.
- **The official way in.** `codex queue --thread <uuid|exact name> --message
  <text>` sends `thread/queue/add` as a user message. It needs no
  per-session token, and the message is not framed as coming from a peer.
  Claude's inbox pipe (DEFERRED.md, "Deliver into a live chat instead of
  beside it") has both problems.
- **It doesn't replace the wait.** It queues at once, so chatq still holds the
  prompt until the reset and only then hands it over.

What 0.159.2 settled:
- **The panel is not on the shared daemon.** Each VS Code window runs a
  private `codex app-server` over stdio, and no daemon runs. `codex queue`
  refuses `--no-daemon` and, with no daemon, writes through an app server
  it starts for itself. So the message reaches the panel only through the
  store they share, `queue_1.sqlite`.
- **That pickup is likely.** The binary watches that file for changes
  (`PRAGMA data_version`), and the app server has a `thread/queue/changed`
  notification to tell its client. Not seen working yet.
- **The method exists.** `thread/queue/add`, `list`, `update`, `delete`,
  `reorder` and `start` are in the app-server's experimental schema
  (`generate-json-schema --experimental`), not the stable one; an older
  server answers "does not support thread/queue/add". chatq's own
  app-server client ([Invoke-ChatqCodexRpc](src/codex-appserver.ps1), read
  only today) could send it with `experimentalApi` rather than run `codex
  queue`.

The one open question: **does a panel open and idle on the thread run the
queued item by itself, or show it and wait for a click on "send now"?**
There is no `--json` event stream either way, so the outcome would be read
from the rollout, or from `thread/turns/list`.

**To close:**
1. Spike (the owner's, as it spends a turn): with a Codex chat open and idle
   in the panel, queue `ok` into it. Does the panel run it with no click?
   Repeat mid-turn, and with VS Code closed.
2. If it runs: queue through the app-server client when the thread is live,
   keep the item's id on the job, and if it is not taken in time delete it
   and only then fall back to `codex exec resume`, so the prompt is never
   sent twice. That needs a way to tell the thread is live - see "A Codex
   thread open in the panel" below.
3. If it waits for a click: leave this, and keep the headless run with a
   busy check and a stale-panel cue instead ("A Codex panel left stale by a
   chatq run", below).

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

- **The five minutes after a reset** are spike A1's hold, given to every
  chat. **Why deferred:** A1 has not been run: whether a VS Code panel
  continues a chat itself is still not known. **To close:** S41 item 2;
  if panels do, count a panel chat as held (`Left`) as a terminal's is,
  and the wait could shrink.

Its items left on purpose are in [DEFERRED.md](DEFERRED.md).

## The console: what 0.5.0 left out

- **New Codex chats.** + New chat starts Claude chats only. **Why deferred:**
  a new Codex thread's id is never given up front: it comes back in
  `thread.started` from `codex exec`, or in the reply to the app-server's
  `thread/start`. Unsaved, a retry after a limit could start a second
  thread. And a thread `codex exec` makes may never show in the panel: the
  panel's list asks for interactive sources by default (`thread/list`
  `sourceKinds`), and `exec --thread-source` only sets an analytics string,
  not that kind. **To close:** a spike that spends a turn, then one of two
  routes. (A) Run `codex exec --json` with no `--ephemeral`, save the id
  from the first `thread.started` on the job at once, and resume it from
  then on. (B) Call `thread/start` at queue time through the app-server
  client, so the id is known before any run - if a thread started that way
  with no turn can then be resumed by `codex exec resume`. Either way, check
  whether the panel lists the thread, and name it with `thread/name/set`.

Its items left on purpose are in [DEFERRED.md](DEFERRED.md).

## The console in the panel's place: what 0.7.2 left out

- **Its size in units, on two real monitors.**
  [Save-ChatConsoleDraft](src/console.ps1) keeps `w` and `h` in WPF's
  units now, and [Get-ChatConsolePlacement](src/console.ps1) turns them
  into the panel's screen's pixels, so a console sized on a 150% monitor
  holds as much on a 100% one. The arithmetic is tested at 1.5; the
  window itself only at this PC's one scale. **Why deferred:** one monitor
  here. **To close:** S33 item 33 on a PC with a 100% and a 150% monitor.

Its items left on purpose are in [DEFERRED.md](DEFERRED.md).

## `code -n` behaviour

**Why deferred:** the chip brings a window forward with `code -n <folder>`,
assumed to focus the window already on that folder and open none. Windows
may refuse a background process the foreground and only flash the taskbar
button.

**To close:** only if S30 item 8 shows a second window, or item 6 a flash
instead of a raise: record what happens, and which VS Code setting
(`window.openFoldersInNewWindow`) or other route changes it. Nothing that
moves the pointer, types, or calls a window API.

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
process too. Show it's close before the handover had the same exposure,
and so does the close of a deleted chat's tab
([closeTabsHere](extension/extension.js), 0.10.12).

**To close:** S48 item 4. If a panel keeps the old channel, close only a
panel whose one channel is the chat's - which needs the Claude extension to
say so - or say what else will end before the close.

## A closed tab writing its deleted chat back

**Why deferred:** 0.10.12 closes a deleted Claude chat's tab
([closeTabsHere](extension/extension.js)) after the transcript is gone.
Whether Claude Code, as it ends that tab's process, writes anything back
under the chat's id - an empty stub, a sidecar folder, a `cost-state`
record such as a reloading window writes - has not been watched on a real
window. The ghost watch would take a stub back (README, *Ghosts*), but a
sidecar folder or another file would be left, and only the next
`chatclean` would sweep it. Driven through stubs only (TESTING.md, Tier 0
"extension: a deleted chat's tab").

**To close:** S33 item 40 in TESTING.md: delete an idle chat open in a
tab and watch its project folder for 20 s. Nothing written - close this.
Something written - have the close pass's window, or the script after the
request, remove what came back under that id, as the ghost watch does a
stub.

## The overlay: what 0.4.0 left out

- **Codex and Copilot chats as live rows.** **Why deferred:** only Claude Code
  writes a list of what runs (`~/.claude/sessions/`). Codex keeps none that
  another process can read: each VS Code window runs a private app server,
  not the shared daemon (spike S-A5), so `thread/loaded/list` and a thread's
  status read `notLoaded` from outside. Copilot records nothing at all.
  **To close:** for Codex, two signals from disk, once a spike that spends
  a turn has watched a panel open and idle, mid-turn, closed, and with its
  window gone: the rollout's tail (a `task_started` with no `task_complete`
  or `turn_aborted`, which [Get-ChatCodexBusy](src/chatrm.ps1) already
  reads), and Codex's per-thread writer lock (`thread-writer-locks/`), if
  it turns out to be held while a thread is open. Recent rows come first
  and need only a walk of recent `sessions/` day folders in
  [Update-ChatOverlayRecent](src/overlay-data.ps1). Copilot waits on
  something that says a chat is running.
- **The macOS panel has never run.** **Why deferred:** no Mac here. **To
  close:** checklist S24 in TESTING.md, and `osacompile` on a `macos-latest`
  CI leg.
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

Its items left on purpose are in [DEFERRED.md](DEFERRED.md).

## Codex threads archived from Codex's own panel

**Why deferred:** `chatrestore` lists what `chatarchive` archived, from its
own records, plus any rollout under `~/.codex/archived_sessions/` - which spike
S16 showed is where `codex archive` moves one. Whether Codex's panel archives
the same way, rather than only in its sqlite state, has not been watched, so
there may be no gap at all. `chatrestore <id>` hands any id to `codex
unarchive` either way.

**To close:** archive a throwaway thread from the Codex panel and look for it
under `archived_sessions/`. If it is there, close this: today's scan already
finds it. If not, list the panel's archive with `thread/list` and
`archived: true` through the app-server client
([Invoke-ChatqCodexRpc](src/codex-appserver.ps1), which always sends
`useStateDbOnly: true` so a listing never repairs Codex's database), paged
by cursor, merged into [Get-ChatArchive](src/chatrm.ps1) so a thread found
both ways shows once, and cached for a minute for the Tab completer.

## A Codex thread open in the panel, or a turn that ended in an error

**Why deferred:** `chatarchive` keeps a Codex thread at work
([Get-ChatCodexBusy](src/chatrm.ps1)), read from the rollout alone: a record
in the last minute, or a last `task_started` with no `task_complete` or
`turn_aborted` after it, in a rollout a codex still holds open to write (on
Windows; elsewhere the hold cannot be seen, so a killed codex's turn waits
out the 12-hour bound). Two things it cannot see. A thread open in
the panel but idle: unlike Claude's session registry, nothing another process
can read says which threads Codex has loaded - `thread/loaded/list` is per
app-server process and read `notLoaded` from outside - so such a thread is
archived, and the panel is left holding a moved rollout. And how a turn ends
when it fails: the one real rollout sampled had three turns, all closed by
`task_complete`; `turn_aborted` is a name in the 0.159.2 binary, not a record
seen. If a failed turn writes neither while the panel keeps the thread
loaded - and so its rollout held - its thread reads as mid-turn until its
next turn starts or the 12-hour stale bound (`ChatCodexTurnStaleHours`).

**To close:** for the second, take a rollout from a turn that failed (an
overload, a refused model) and one stopped from the panel, and check which
record closes each; add whatever it is to the closers. For the first, look
for a cross-process signal once the shared app-server client exists - or ask
`codex archive` itself, if a later codex refuses a loaded thread.

## A Codex panel left stale by a chatq run

**Why deferred:** a Codex job runs `codex exec resume` beside whatever the
panel shows, so a thread open in a Codex tab does not show the run until it
is opened again, and nothing says so; there is no Open chat for a Codex job
either ([openFromWatch](extension/extension.js) and
[restoreHandover](extension/extension.js) return `none` for one). The hook
for both exists: the Codex extension (openai.chatgpt 26.928) opens a thread
as an editor tab of its custom editor `chatgpt.conversationEditor`, at
`openai-codex://route/local/<threadId>`, with `vscode.openWith` - so a tab is
found by the thread's own id, more surely than a Claude tab by its title.
What is not known is whether a thread `codex exec` made, with no panel
history, draws anything in that tab, and what a tab open during a run
shows after it.

**To close:** a spike with no turn: `vscode.openWith` on that URI from the
extension's dev host, for an exec-made thread and a panel one. If both draw,
an Open chat for Codex ([Write-ChatOpenRequest](src/chatrm.ps1) with the
provider, a Codex branch in `openFromWatch`), then, once a run has been seen
to leave a tab stale, close or reopen that tab around the run as the Claude
handover does. If exec-made threads come up empty, offer it only for
threads the panel made.

## Deleting a Codex chat leaves Codex's own records

**Why deferred:** [Remove-ChatSession](src/chatrm.ps1) deletes a Codex
rollout with `Remove-Item`, and the codex `Extras` in `$script:ChatProviders`
([src/providers.ps1](src/providers.ps1)) is empty, so the thread's row in
Codex's `state_5.sqlite` and its title in `session_index.jsonl` stay behind
- [Get-CodexThreadNames](src/providers.ps1) keeps serving the dead title,
and the row is an orphan whose rollout is gone. `codex delete --force <uuid>`
(S16; still there in 0.159.2, S-A5) would keep Codex's records whole, but it
is not known whether it clears the row itself: two such orphans on this
machine may have come from it.

**To close:** a spike: `codex delete --force` on a throwaway thread, then
read the `threads` row and `session_index.jsonl`. If both are cleaned, have
`Remove-ChatSession` call it for Codex; if the row stays, keep `Remove-Item`
and say which records are left.

## Weekly-limit and model-scoped limit handling

**Why deferred:** every limit seen on this machine was `five_hour`.
- A model-scoped limit (`seven_day_opus`, a `weekly_scoped` cache entry) no
  longer blocks the queue. The probe, asked with each chat's own model, decides.
- A job waiting on a real weekly limit just waits - and holds the machine
  awake all the while, against what the loop means to do: see "A wait days
  out keeps the machine awake".

**To close:** capture a real `seven_day` / `seven_day_opus` rejection. Check
the exact `rateLimitType` names against the list in `$script:ChatqWideLimits`.
Then decide whether a job should wait days, or alert and park.

## Overloads on Codex

**Closed, by backoff alone:** a Codex turn that failed on a 5xx, "high
demand", a model "at capacity" or "Flex capacity unavailable" is now
`overloaded` ([Get-ChatqCodexOutcome](src/queue.ps1),
`$script:ChatqCodexOverloadRx`), and waits as an outage of its lane: tried
again after 1, 2, 5, 10, then every 15 minutes
([Test-ChatqOutageOver](src/watcher.ps1)), with no status page read and no
word of Claude in what it says.

**Why deferred:** two things are left. The wording comes from the strings
in the codex-cli 0.159.2 binary, not from a run that met an overload, so
the exact `turn.failed` text - whether "last status: 503" carries its
reason phrase, say - is inferred; a wording that misses still fails the
job, as before. And status.openai.com is not watched: a Codex outage ends
on the next try that gets through, which after the first hour is up to 15
minutes late.

**To close:** on the next real Codex overload, keep the `codex exec
--json` stdout as a fixture under `tests/fixtures/stream/` and check its
`turn.failed` message against the regex. Separately, a spike on whether
status.openai.com serves a statuspage-style JSON with a Codex component; if
it does, read it in [Test-ChatqOutageOver](src/watcher.ps1) the way
status.claude.com is read for Claude, else leave the backoff alone.

## Codex limits that are not a full window

Codex's `rate_limits` snapshot says more than how full each window is:
`rate_limit_reached_type` (`rate_limit_reached`, or a workspace's credits
or usage limit spent), `spend_control_reached`, `credits` and `plan_type`.
[Read-ChatqCodexLimitSnapshot](src/queue.ps1) hands the first and the last
back as Reached and PlanType, but nothing uses them:
[Get-ChatqCodexBlock](src/queue.ps1) still blocks a lane only on a window at
100% with a reset ahead, and the usage rows do not name the plan.

**Why deferred:** no rollout seen so far has `rate_limit_reached_type` set,
so which value comes with which wall - and whether a credits limit has any
reset to wait for - is unknown. A Codex job that meets one is still read
by what its probe or its turn failed with
([Get-ChatqCodexOutcome](src/queue.ps1)): a "usage limit" waits as a
limit, and any other wording fails the job, as before.

**To close:** on a real one, keep the rollout's tail as a fixture; block
the lane on Reached where it names the account's own limit, with the
window's reset or, lacking one, the probe's; and add the plan to the
Codex usage row if it earns the room.

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
- **S35 items 5-8 are unrun** (TESTING.md): the `//c/...` form of the data
  deny rules, elicitation under `host`, `auto`'s classifier, and two calls
  in one message. **Why deferred:** the spike's budget of five real runs
  went on items 1-4 and one run end to end. **To close:** run them, and if
  the `//c/...` form does not hold, drop those rules from
  [New-ChatqPermitRun](src/permit.ps1) - the bridge's own rule and the
  phone's MAC hold without them.
- **Codex.** A Codex job runs `codex exec` with approval policy `never`, so
  a call that would need approval is refused and the job never asks. That
  was written down as out of scope by design, on the belief that Codex
  cannot ask mid-run at all; codex-cli 0.159.2 has two ways it can. **Why
  deferred:** neither has been run, and each needs a turn to try. (B) A
  `PermissionRequest` hook - an event in the binary's hook list and in the
  app-server's hook schema - on a run given
  `-c approval_policy=on-request`, scoped to that run the way the ask hook
  is ([Start-ChatqAskHook](src/ask.ps1)), checking the phone's sealed
  answer itself. (A) The app-server's own approval requests
  (`item/commandExecution/requestApproval`,
  `item/fileChange/requestApproval`, `item/tool/requestUserInput`), on a
  runner that drives turns through the app server rather than `codex
  exec`, answered `accept` or `decline` only; a permissions request or a
  `grantRoot` would always be declined, since they widen the run the way
  "always allow" would. **To close:** a spike: does the hook fire under
  `exec`, and does its allow take without a hook-trust bypass? If so, B;
  if not, A, once that runner exists and its requests are seen to arrive
  after the item they ask about and to wait while unanswered. Then a
  "Codex" section in [phone-permit-spec.md](docs/phone-permit-spec.md),
  [Test-ChatqPermitReady](src/permit.ps1) letting Codex through except under
  `danger-full-access`, and a `needs-input` outcome for a Codex job whose
  ask went unanswered.

Its items left on purpose are in [DEFERRED.md](DEFERRED.md).

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

Its items left on purpose are in [DEFERRED.md](DEFERRED.md).

## Map Codex's managed sandbox back to a sandbox word

**Why deferred:** a chat whose last turn recorded a sandbox no
`codex exec` takes - the desktop app's `managed`, or a camelCase or
`external-sandbox` shape - runs in `workspace-write`
([ConvertTo-ChatqCodexSandbox](src/queue.ps1)), with a line in the job's
history and in the pick. That keeps the run from failing at config load,
but `workspace-write` may be narrower or wider than what the app ran it
in: what `managed` stands for is settled by the app's own policy, which
no rollout seen so far spells out.

**To close:** a spike that runs one turn each under the app's managed
choices and reads what the rollout's `turn_context` keeps beside
`sandbox_policy` (writable roots, network). If it names the policy, map
it to the nearest word in [ConvertTo-ChatqCodexSandbox](src/queue.ps1);
if not, keep `workspace-write` and say so.

## Carry a Codex chat's effort into its run

**Why deferred:** [Get-ChatqCodexMeta](src/queue.ps1) reads the effort
the chat last ran at (`turn_context.effort`, else the collaboration
mode's `reasoning_effort`), and chatq shows it beside the model
([Write-ChatqJobInfo](src/commands.ps1),
[Format-ChatqRunCarry](src/queue.ps1)) - but the run is not given it.
Whether `codex exec resume` keeps a thread's effort, or falls back to
`model_reasoning_effort` from `config.toml`, has not been checked, and
checking needs a model turn.

**To close:** a spike: resume a thread last run at an effort other than
the config's and read the new `turn_context.effort`. If resume drops it,
send `-c model_reasoning_effort=<effortAtQueue>` from
[Invoke-ChatqRun](src/queue.ps1) when the job has no `-Model`, as the
Claude side carries `--effort`.

## A wider Codex sandbox sticks to the chat

**Why deferred:** a run given `-c sandbox_mode=` writes that sandbox into
the chat's next `turn_context` (spike S11), so a job given a wider
sandbox than the chat's leaves the chat in it, and later jobs that pick
none run there too. chatq only warns
([Get-ChatqCodexWiderSay](src/commands.ps1), from `chatq`, `chatqrun`
and the console); nothing puts the chat back.

**To close:** after a run whose sandbox was its own pick, have the next
job for that chat that picks none run in the sandbox the chat had before
it - the job record keeps that as `sandbox` - rather than reading the
rollout's latest; or run the wider job as a fork. Either changes what
"the chat's own sandbox" means and wants a decision first.

## The Codex app-server floor is a guess

**Why deferred:** `$script:ChatqCodexAppServerMin` in
[src/queue.ps1](src/queue.ps1) is `0.159.0` because only codex-cli
0.159.2's app-server schema was read; no older build was tried. The client
now gates on it ([Start-ChatqCodexRpc](src/codex-appserver.ps1), by
[Get-ChatqCliVersion](src/queue.ps1)): an older codex is not started,
the limit check falls back to `codex exec`, and the overlay keeps the
rollout's figure without a word. A floor set too high costs older
builds the live figure and the turn-free check; one set too low only
costs a start that answers "unknown variant". The doctor lines
([Get-ChatqCliReport](src/queue.ps1)) still say a codex's version without
judging it against the floor.

**To close:** check `initialize` and `account/rateLimits/read` against
an older codex-cli - 0.154.0-alpha, which the earlier Codex spikes in
TESTING.md ran on, is one - and move the floor to the first build that answers them. Then have
`chatinstall` and `chatproviders` say when the codex found is below it,
and what it misses.

## A Codex job's home, and a second Codex account

**Why deferred:** usage, archive and restore now take their Codex home
as a parameter and default to `$script:ChatCodexHome`, the home chatq
loaded with ([Get-ChatqUsage](src/alerts.ps1),
[Get-ChatArchive](src/chatrm.ps1)); an archive goes to the rollout's
own home ([Get-ChatCodexHomeOf](src/chatrm.ps1)). Three places still
read one home only, or another one:
- A Codex job's `home` is set from `$env:CODEX_HOME` as it is when the
  job is queued ([New-ChatqJobRecord](src/commands.ps1)), while
  the chat was found in `$script:ChatCodexHome`'s index. A shell that
  changed `CODEX_HOME` after loading queues a run against a home the
  thread is not in. Nobody is known to do that, and moving it changes
  what an existing job record means.
- The index and `chatfind` read Codex's threads from
  `$script:ChatCodexHome` alone ([src/providers.ps1](src/providers.ps1)),
  so a second account's threads are not listed at all.
- The overlay's usage line reads one home, its rollouts and its live
  answer alike; a job on a second account shows the first account's
  windows. The live answer in `overlay.json` names the home it was asked
  under ([Update-ChatOverlayUsage](src/overlay-data.ps1)), and
  [Get-ChatqUsage](src/alerts.ps1) and a restarted overlay
  ([Restore-ChatOverlayUsage](src/overlay-data.ps1)) take it only for
  their own home - so a shell on the other account sees its rollout's
  figure, not the overlay's. The limit check already asks under the
  job's own `home`.

**To close:** decide whether a second Codex account is supported. If
it is: take a job's `home` from the home its chat was listed under, let
the provider list several homes with the home on each row, and read
usage per home - the app-server client already takes `-CodexHome`. If
it is not, set a job's `home` from `$script:ChatCodexHome` and say
`CODEX_HOME` is read once, at load.

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

## The simplification review: what it left out

The review behind "Less code, the same behaviour" (CHANGELOG, 0.10.5)
changed no behaviour, so the faults it came across were left for fixes of
their own. Each was read against the code by two more reviewers; none has
been run.

- **A chat open in a bare root stops the overlay.**
  [Get-ChatOverlayRows](src/overlay-data.ps1) names a row's project with
  `Split-Path $cwd.TrimEnd('\', '/') -Leaf`. A cwd of `/` - a `claude`
  started there on macOS or Linux - or `\` trims to an empty string, which
  `Split-Path` refuses, so every pass fails before the snapshot is written:
  a running panel stops on its last pass, logging `tick: ...`
  ([Invoke-ChatOverlayTick](src/overlay-windows.ps1)), and one starting
  gives up at its first, logging `overlay failed: ...`
  ([Start-ChatOverlayHost](src/overlay-windows.ps1)), for as long as that
  chat is open. `C:\` trims to `C:`, which passes. **Why deferred:** a fix
  decides what such a row shows. **To close:** show `/` when the trimmed
  path is empty, in one helper for the session, tab, cut-off and job rows
  and [Update-ChatOverlayRecent](src/overlay-data.ps1), and a check with a
  live session whose cwd is `/`.
- **A held alert whose time does not read stops the quiet-hours summary.**
  [Get-ChatqHeldItems](src/phone-extras.ps1) skips a line that is not JSON,
  but sorts the rest by `(ConvertTo-ChatqDate $o.at).ToUniversalTime()`,
  which throws on an `at` that does not read.
  [Send-ChatqHeldSummary](src/phone-extras.ps1) catches that and leaves
  its claim; ten minutes on, the next summary takes the claim back
  ([Get-ChatqStaleSending](src/phone-extras.ps1)) and fails the same way,
  so nothing held goes out until the line is mended by hand.
  [Add-ChatqHeldAlert](src/phone-extras.ps1) always writes a good `at`:
  only a hand-edited or damaged `held.jsonl` does this. **To close:** skip
  such a line as one that is not JSON is skipped, with a check that holds
  one.
- **The alert page's usage line takes the board's grid.** `docs/reply.html`
  gives the board's usage table a bare `.usage { display: grid; ... }`,
  and the alert page's usage line is `<p id="usage" class="meta usage">`.
  The alert's footer (`s=`, up to 200 characters) then sits in one
  `max-content` column that cannot wrap, and a long one runs past the
  right edge of a phone's screen. Read from the CSS, not seen on a phone.
  **To close:** scope the grid to `#bUsage`, and a page-check line that no
  bare `.usage` rule makes a grid.
- **The overlay's cached usage reads the wrong `.claude.json` when
  `CLAUDE_CONFIG_DIR` is `~/.claude`.** Claude Code keeps `.claude.json`
  inside `CLAUDE_CONFIG_DIR` whenever that is set, even to `~/.claude`,
  and in the home folder only when it is not;
  [Get-ChatqUsage](src/alerts.ps1) and
  [Read-ChatqUsageCache](src/queue.ps1) go by that.
  [Get-ChatqClaudeJsonPath](src/overlay-data.ps1) is handed the config
  folder, which is `~/.claude` set or not, and reads `~/.claude.json` for
  it. Only the overlay's cached figure - shown when its live fetch has
  nothing newer - is off. **To close:** have it look at
  `$env:CLAUDE_CONFIG_DIR` itself, as Get-ChatqUsage does.
- **A start time `Test-ChatIdle` cannot read.**
  [Test-ChatIdle](src/chatrm.ps1) turns a live session's `StartedAt` into
  a time with no try, so a value that is not epoch milliseconds writes an
  error and counts every background start in the transcript, not only
  those since the session began.
  [Get-ChatqEntryStart](src/live-chats.ps1) answers the same question and
  falls back to the process's start time. The wrong answer is "not idle",
  the safe one, and Claude Code writes a good value. **To close:** have
  Test-ChatIdle call Get-ChatqEntryStart.

Its items left on purpose are in [DEFERRED.md](DEFERRED.md).

## The pointer check near the panel

[Update-ChatOverlayHover](src/overlay-windows.ps1) runs every 120 ms and
takes its long way whenever the pointer is within 64 px of the panel or
anything is under way. On a panel of nine chats' rows off every screen
(TESTING.md, "The overlay's own cost", 2026-10-15) the checks took 12 to
13 ms of every second with the pointer away, 51 with it 37 px over the
panel and 79 with it on a row, and the whole process 32 to 38, 81 to 88
and 125 to 130 - the same before the tiles and after. So a pointer
resting by the panel costs some 5% of a core, on a row some 9%; the live
panel read 10.3% with it resting 37 px over the panel, against 5.6%
before. **Why it waits:** found while measuring the tiles; what in the
long way costs is not timed yet. **To close:** time its parts - the
edges' zone, the bar's target and placing, the chip - as the 2026-10-06
pass timed the short way, and keep only what each check needs.

## The board's Recent and Older headings in light mode

The board's `.shead[data-sec="recent"]` and `.shead[data-sec="older"]`
headings ([docs/reply.html](docs/reply.html)) read faint in the light
look. The dark look sets both to `color: var(--muted)` (0.10.11), which
would fix the light look too. **Why it waits:** light mode was to stay as
it was in that release, so the rule sits under the dark media query only.
**To close:** move the `color: var(--muted)` rule out of the dark block so
it covers both looks, and look at the board in light mode on a phone.

## A card on a chat whose subagent asks

A chat that waits while its foreground subagent asks to run a tool may
show on its card as `Allow Agent` and the agent's description:
[Get-ChatOverlayCardModel](src/overlay-data.ps1) takes the newest call
still open in the chat's own transcript, which is the Agent call - the
subagent's calls are in a transcript of their own - and the row's
`detail`, the registry's `waitingFor`, goes unused while a call is open.
The Agent call asks for nothing; the subagent's call does. **Why it
waits:** reasoned from the transcripts' shapes in the card's review, not
seen: whether the registry says waiting then, and what its `waitingFor`
says, is not known. **To close:** catch one live - a chat whose
foreground Agent runs a Bash call that asks - then, for an open Agent or
Workflow call, show `Waits in` and its description, or the row's `detail`
where it says more than `input needed`.

## A chat's title clicked while VS Code is in front

Opening a chat from the panel - its title before 0.10.17, its tile since -
with its VS Code window already in
front, could leave the chat out of view. 0.10.14's
[frontChatTab](extension/extension.js) focuses the chat's group when its
tab is in front there, and logs every other case. Why the chat stayed
hidden was not seen live, though. A review found two cases it leaves as
they are:
- **A tab behind others in its own group** is never brought forward.
  Claude Code's `editor.open` shows the chat in the side bar when it has
  no live panel, and making a tab restored over a reload visible would
  start a second claude on the chat. No API tells a live tab from a
  restored one.
- **VS Code can report a background tab as the active one** after its
  label changes: the main thread re-sends that tab's stale `isActive`.
  `revealed: its tab in front` is then logged while another tab shows.

**Why it waits:** the cause is unknown until a click that fails is
logged. **To close:** get the `revealed` line from **Chat Manager: Show
log** after such a click, then act on that case.

## The rest of the tool in Rust

[native/SPEC.md](native/SPEC.md) plans the watcher in Rust, `chatqd`, in
milestones, and 0.10.15 has the first two. M0 is the build, the lock, the
engine's choice and the fuse, with the PowerShell watcher taking over
every pass that has work. M1 is `chatq-core`, the contract both engines
share, and 19 more vector files, made by the PowerShell side and checked
by a Rust runner under both editions. Made to wait under its test seam,
M0 measured 1.1 MB private where a running PowerShell watcher sits at
150 to 225 (native/SPEC.md 3.3). 0.10.16 has M2: chatqd runs the loop
itself, each piece of PowerShell work a short-lived step, and hands over
to a PowerShell watcher only while the phone's reply window is open -
with replies on, after nearly every pick, so the gain shows mainly with
replies off until M3. What it saves on a real night is TESTING.md's S57,
not yet run. A day measured on 2026-10-19 with nothing queued puts M2
at nothing - the watcher only listened, for the live alerts' reply
windows - M3 at about 98 MB private averaged over the day, and M9 at its
80 MB gate at about 191 (SPEC 8, "Memory, measured"). 0.10.21 has M3:
chatqd listens itself, a PowerShell step only for a batch that holds a
reply, and hands over on a panic or where Windows refuses its connect;
listening held 2.58 MB at the hour's gate (TESTING.md S59, step 1),
steps 2-8 not yet run. So since
2026-10-20 the order is: the M9 spike, a check of the overlay's window
behaviours in one Rust window, run on Windows that day (TESTING.md
S58: 6.8 MB at its gate, a go on Windows), its Mac check still to come
(DEFERRED.md, "The M9 spike on a Mac"); M3 listening - where replies
to live alerts and `reply.listen always` stop costing a PowerShell -
M4 the lane gate, M5 runs, M6 alerts, M7 the rest and native by
default; M8 the question hook and the permission bridge as small
native programs (DEFERRED.md, "A lighter launcher for the ask hook");
M9 itself, on the spike's findings (SPEC 8, "The M9 spike"), if the
stop rule says go. The commands a shell runs stay PowerShell: a full
port of them is not planned. **Why it waits:** each milestone is its
own release, checked as the SPEC says before the next. **To close:**
the milestones in order.

M1's vectors do not reach two things a later milestone ports, so that
milestone's checks have to:
- **The tick inside a run** (M5): the heartbeat save, the in-run reply
  poll and the quick ask-landed look are an `$onTick` closure built inside
  [Invoke-ChatqJob](src/watcher.ps1). Only their constants are pinned
  ([timers::HEARTBEAT_SECONDS](native/crates/chatq-core/src/timers.rs),
  [timers::RUN_ASKING_POLL_SECONDS](native/crates/chatq-core/src/timers.rs)
  and the two in [gates.rs](native/crates/chatq-core/src/gates.rs)), by
  unit tests.
- **A run's state back in PowerShell** (M5): the stream state chatqd will
  hand the post-run step is rebuilt in PowerShell only in the vector
  generator ([Test-NvStreamStateRebuild](tests/vectors/stream-state.ps1)).

M3 closed the other two: the listening cases of `timers.json` replay
whole in [timers_replay.rs](native/crates/chatqd/src/watch/timers_replay.rs),
and [replystate::use_state](native/crates/chatq-core/src/replystate.rs)
writes where polling got to.

## The arrows' own binding after a second dot-source

[Register-ChatKeyHandlers](src/shell.ps1) records what Up and Down were
bound to before it binds them, so off a chat line they keep doing it.
Run again in a shell that has the tool loaded - `. $PROFILE` a second
time - it records its own handler, `ChatCycleOrHistory`, which names no
PSReadLine function, and the arrows fall back to plain history: a binding
of the user's own, `HistorySearchBackward` say, is gone until a new shell.
As old as the arrows' handling; a lazy shell's second dot-source before
the first use leaves the keys alone. **Why it waits:** found in the lazy
load's review, never seen in use. **To close:** keep what was recorded
when the bound function is the tool's own.

## The overlay's heap climbs in steps

With the heap left after each compaction in the overlay's log (0.10.13),
one overlay on 2026-10-15 kept 101 MB of live objects at 17:40, 108 at
18:05, 116 at 19:25 and 135 at 20:11, its private memory after the
compaction going from 234 MB to 274; it then hit an
`OutOfMemoryException` with the PC at 95% of its memory. The next one
went from 103 MB at 20:50 to 119 at 21:30. The heap holds level for an
hour at a time and then climbs 5 to 13 MB at once - more like something
kept for each new thing, a chat, an agent's transcript or a card, than a
slow leak. **Why it waits:** seen over one evening of many new chats and
agents, not tied to a cause. **To close:** read the log over a quiet day
against the chats that came and went; if it still climbs, take two full
dumps hours apart and compare the types that grew.

Since 0.10.15 the overlay restarts itself once a compaction leaves it at
`overlay.restartMB` (300) or more and 50 MB over where the run settled
([Update-ChatOverlayRestartDue](src/overlay-host.ps1)): over 78 runs
in the log the figure after a compaction was 260 MB in the middle, 292
at the 90th and 322 at the most, the last long run sitting at 315 to 322
with a 146 to 152 MB heap some 30 hours in. That bounds the climb; it
does not explain it, and the restart costs the unread dots each time. So
this stays open: the stop line's `a memory restart` in `overlay.log`
says how often it bites.

On 2026-10-19 the restart was never due. From 30 minutes in, no run's
figure after a compaction went more than 12 MB past where it settled;
the run before that night's reboot settled at 278 and reached 324 about
22 hours in, under its 328. But code-change restarts kept every run that
day under 7.6 h, so the quiet day this asks for is still to be read.

## What a restart takes from under the user

Found in the review of 0.10.15's memory restart, never seen in use; each
is as old as the restart on new code, now likelier at about once a day.
A reset ask's phone alert still waiting for you to be away is kept only
in memory (`Ctx.AskPhone`), so any restart drops it. The memory restart
waits for [Test-ChatOverlayUnderWay](src/overlay-windows.ps1) but not for
the pointer to leave the panel, so a hover card can vanish while it is
read. And a leak or memory balloon on a later pass replaces an ask's
balloon still up, after which a click no longer opens the console (the
ask stays on the panel's banner and in the tray menu). **Why it waits:**
none seen yet. **To close:** keep `AskPhone` in `overlay-state.json`; add
`-not $H.PointerIn` to the memory branch of
[Invoke-ChatOverlayTick](src/overlay-windows.ps1) with a life-test step;
hold the newer balloon while an ask's shows, if `BalloonTipClosed` fires
reliably on Windows 10 and 11.

## What sets an overlay run's level

A run settles within minutes of starting and then barely moves, but
where it settles differs: 229 to 301 MB private across 2026-10-19's long
runs, 221 to 293 among the 0.10.18 runs alone, 303 to 307 at the start
of 0.10.19's. That spread is larger than anything a restart gives back
(0 to 33 MB) or a compaction (median 0). **Why it waits:** found in the
day's memory log; the logs don't say what differs at start. **To
close:** log at start what [Start-ChatOverlayHost](src/overlay-windows.ps1)
read - transcripts, rows, cards - beside the settled figure, over a
week, and see what tracks it.

## The panel stays wide after a scale change

On 2026-10-20 the display went from 2560x1440 to 1920x1080 and the scale
went 125%, 150%, then back to 100%, all while 0.10.19's overlay ran.
Afterwards the panel was 460x422 px at 96 dpi; its normal width is
[Get-ChatOverlayPanelWidth](src/overlay-windows.ps1)'s 162 units. The
bar followed it (444 = 460 - 16, from
[Set-ChatOverlayControlsPlacement](src/overlay-windows.ps1)), and so did
the edges (468x430). The card kept its 337. Only a restart puts it back.
The likely cause, not proven:
[New-ChatOverlayWindow](src/overlay-windows.ps1) sets Width once, and
nothing sets it again.
SizeToContent=Height re-asserts the height, but no setting re-asserts
the width. With per-monitor DPI scaling on, WPF writes the current
pixel width over the current scale into Width on each resize. A resize
mid-change can then store a wrong width, and each later change scales
it again. The log has no scale or size lines to show the order.
Moving, collapsing, a theme change and the console all keep the wrong
width: [Exit-ChatOverlayConsoleMode](src/overlay-windows.ps1) puts
back the width saved on entry. **Why it waits:** found while the M9
spike's scale test ran, and the user chose to log it. **To close:**
put Get-ChatOverlayPanelWidth back on the panel in the SizeChanged
handler and in the tick's Set-ChatOverlayControlsPlacement, outside the
console. Make the console's exit restore that width, not the saved one.
Add a Tier 0 check that forces a wrong Width and expects all three back.
Then do a Tier 1 run of 100, 125, 150 and back to 100% with the live
overlay: expect panel width = 162 x dpi / 96 after each change.

## A lazy shell's 19 MB over a bare one

A lazy shell's load is 73.8 MB private, a bare Windows PowerShell with
PSReadLine 54.9 (median of 5 after a full collection, 2026-10-15). Most of
the 19 MB is thought to be `Microsoft.PowerShell.Utility`, loaded at
profile time by the cmdlets the load still uses (`Set-Alias`,
`ConvertFrom-Json`), but no part is measured on its own. **Why it waits:**
the lazy load came first. **To close:** time and weigh each part of
[Enter-ChatShell](src/shell.ps1) on its own; replace a module's cmdlet
with a .NET call where one is the cost - but weigh it in a real VS Code
terminal first, whose shell integration may load the same modules anyway.

## A native watcher's launch on a Mac

0.10.15's launch of a native watcher has a Mac branch that has never run:
the `universal-apple-darwin` folder under `bin/<version>/`, the owner's
exec bit [Get-ChatqWatcherEngine](src/watcher.ps1) asks for, which a VSIX
does not keep, and the start through `nohup` in
[Start-ChatqNativeProcess](src/watcher.ps1). No Mac build of chatqd
exists yet. **Why it waits:** no Mac here (Tier 2). **To close:**
[native/SPEC.md](native/SPEC.md) M0's Tier 2 - build, sign and run
chatqd on a Mac - then [TESTING.md](TESTING.md)'s S55 there.

## A heads-up step that keeps failing

chatqd's soon gate (native/SPEC.md 3.6) launches a `soon` step for each
due usage heads-up not yet sent. A step that does not start, or dies
inside [Send-ChatqUsageSoon](src/phone-extras.ps1), records nothing, so
the next pass launches it again - about 0.4 s and 100 MB a pass, until
the reset is past. Unlike a failed block scan, held summary or ask check
(SPEC 8, "A failed step records its attempt"), recording it as sent
would lose the alert. **Why it waits:** it needs a step that cannot run
at all; Send-ChatqUsageSoon itself never throws, and none has been seen.
**To close:** a retry wait of its own for a failed soon step, kept in
`W` like `ChatqSummaryTriedAt`, with a `timers.json` case.

## A job saved over its twin's file

0.10.16 passes over a job its own id does not find
([Test-ChatqJobFound](src/watcher.ps1)), but two paths still write by
id, to `<id>.json`. A `-Now` wake clears a deferral with `Save-ChatqJob
-Existing`, so for a duplicated id the PowerShell watcher writes the
copy it read over its twin's file, where chatqd's `jobs::clear_defer`
reads `<id>.json` again and clears that field alone - the two watchers
differ there. And a job in a file not named `<id>.json`, with no twin, is
found but never saved: [Invoke-ChatqJob](src/watcher.ps1)'s deferral or
end lands in a file that is not there, so its pick may come round each
pass. **Why it waits:** found in the 0.10.16 fix's review; neither seen
in use, the second not reproduced. **To close:** skip what
Test-ChatqJobFound rejects in the wake, and save a job to the file it was
read from.

## A wait days out keeps the machine awake

[Invoke-ChatqWatchLoop](src/watcher.ps1) means to hold the machine awake
only for a wait of 6 hours or less: its comment says a weekly limit days
out should not keep a laptop from sleeping. But the test is on `$nextAt`,
which starts 15 minutes out and is only ever moved sooner, so it is
always true. While any job waits - on a five-hour reset, a weekly limit
or a `-At` for Friday - Windows is told to stay awake
([Set-ChatqKeepAwake](src/watcher.ps1)), and a Mac or Linux box runs
`caffeinate` or `systemd-inhibit`. M1's timers vector pins every waiting
pass as `awake on`, and chatqd's
[timers::keep_awake](native/crates/chatq-core/src/timers.rs), checked
against it, tests the same `$nextAt`. **Why it waits:** found while M1
pinned the loop, and M1 changes no behaviour. **To close:** test the time the wait is for - the
earliest [Get-ChatqDueTime](src/watcher.ps1) of the jobs waiting, or the
soon alert's - not `$nextAt`, in the loop and in `timers::keep_awake`
together; then make timers.json again under both editions, with a job due
7 hours out that records `awake off`.

## One bad value stops a whole file's reader

Three readers throw at one value they cannot convert, and so stop far
more than that value's own work. chatq writes good values, so only a
hand-edited or damaged file does this, as with the held alert above
("The simplification review: what it left out"). M1's vectors pin each as
it is, and chatqd follows in the first two.
- **data/replies.json.** [Get-ChatqReplyState](src/phone.ps1) casts an
  alert's `uses` and `seq` with `[int]`, even in an alert long expired,
  and [Read-ChatqBoardState](src/phone-down.ps1) the down channel's
  counts. One that is not a number throws, and so does every
  [Use-ChatqReplyState](src/phone.ps1) after it: replies, pairing and the
  phone board stop until the file is mended by hand (reply-state cases
  `a use count no number`, `a seq past Int32`, `down counts no number`).
- **A job with no `promptFile`.** [Get-ChatqPromptPath](src/queue.ps1) then
  names the queue folder, `ReadAllText` throws on it, and
  [Write-ChatqBoard](src/alerts.ps1)'s empty catch writes no board at
  all: queue.md stays as it was for every job, not only that one
  ([board::text](native/crates/chatq-core/src/board.rs) gives None the
  same way).
- **An outage's `attempts` in state.json after a handoff.**
  [Restore-ChatqWatchState](src/watcher.ps1)'s `[int]` throws and ends the
  new watcher; its finally saves the state with the handoff off, so the
  watcher after it starts cold. Queued jobs wait for that next start.
  chatqd keeps 0 instead ([WatchState::restore_in](native/crates/chatq-core/src/state.rs)).

**Why it waits:** each fix decides what such a value reads as, and chatqd
has to change with it. **To close:** read each as its neighbours are read
when absent - a count that is no number as 0, a job with no prompt file
as an empty prompt - and make reply-state.json, board.json and
state.json again under both editions.

## alerts.log never rolls

[Send-ChatqAlert](src/alerts.ps1) appends every alert to
data/logs/alerts.log with no size check, where watcher.log, jobs.log and
the rest roll to `.1` past 1 MB ([Add-ChatqLogLine](src/queue.ps1)). It
was 181 KB on this PC on 2026-10-16, so it grows slowly, but without end.
chatqd's [log::add_alert_line](native/crates/chatq-core/src/log.rs) does
the same. **Why it waits:** found while M1 pinned the logs. **To close:**
roll it as Add-ChatqLogLine does, in both, with a log.json case past 1 MB.
The tool never reads the file back - the held summary only names it - so
a roll loses nothing it uses.

## What only a probe pinned

Some PowerShell behaviour chatqd follows cannot be a vector, so a unit
test pins it from a probe run once, on this PC, in October 2026. Nothing
asks PowerShell again, so a new pwsh or a Windows update that changes one
goes unseen.
- **Answers a vector file cannot carry.** 5.1 reads a vector file back with
  its own ConvertFrom-Json, which stops at 102 levels and drops or refuses
  `__type`; the pwsh 7 side reads it into `[ordered]`, which refuses two
  names that differ only by case under its own fold (µ and Μ, ς and Σ);
  and numbers past a long never read back the same in both. So the depth
  limits, those name pairs, `__type`, twenty-digit numbers and pwsh 7's
  `new Date(...)` are unit tests in [json.rs](native/crates/chatq-core/src/json.rs)
  (`nesting_as_deep_as_each_convertfrom_json_reads`,
  `keys_twin_by_case_as_each_edition_folds`, `a_type_hint_is_5_1s_alone`,
  `twenty_digits_are_a_big_integer_in_pwsh_7`,
  `a_constructor_is_refused_a_known_divergence`), and SecureString's
  65,536-unit limit one in [secret.rs](native/crates/chatq-core/src/secret.rs)
  (`plaintext_is_utf16le_within_securestring_limits`): its hex is past
  the command line's 32,767 characters.

The tables scanned from one PC - wire/collation.rs, runenv.rs's keep
lists - are a deferral of their own: DEFERRED.md, "Unicode tables scanned
on one PC".

**Why it waits:** M1 needed the answers, not the means to ask again.
**To close:** read the pwsh 7 side's answers with an ordinal dictionary,
so the name pairs can be vectors; and check in a probe script that asks
each of the rest under both editions and compares with what the unit
tests hold, run in CI's PowerShell legs.

## Slint's timers while the tray menu is open

In the M9 spike (TESTING.md S58), a right click opened tray-icon's menu
on the UI thread, and Windows ran the menu's own modal loop there: no
Slint timer fired until it closed. The three opens by hand left gaps of
6,340, 2,119 and 1,151 ms, each the menu's time open. The overlay's
tick is a timer, so on the port the panel, the chip and a card left up
would freeze while the menu shows. The spike's gate already logs its
hour from the sampler's own thread for this reason: its close runs on
Slint timers, which a menu left open would hold until the watchdog
ended the process (`gate::sample::spawn`). **Why it waits:** the spike
only had to show where tray events land; the cure is M9's design. **To
close:** a SetTimer on the panel's own window, whose `WM_TIMER` the
menu's loop still sends, driving the tick while the menu is up; or a
frozen card accepted, said in the SPEC. Then a hand run: the menu held
open 10 s, the clock and a card going on.

## The toast over the panel's corner

The spike's toasts, captured 1 s after the first balloon and 0.5, 2 and
3.5 s into the close one, drew over its topmost status window at the
foot of the screen: 52,168 to 52,175 pixels changed in each capture
over two runs, 14,752 or 14,753 of them outside that window
(`tray::standin::watch_close`). A Windows toast sits above every
topmost window, so on the port any toast or balloon - the close
balloon, a memory warning, an ask - covers the panel while it shows, if
the panel is at its home in the screen's bottom-right corner. Whether
the WPF overlay is covered the same way today was not looked at. **Why
it waits:** seen in the spike's captures, never on the live panel. **To
close:** capture the live panel at its home while a balloon shows; if
it is covered there too, leave it; if not, find what the WPF windows do
that the spike's do not.

## The spike's tray: what it left open

Three tray findings in the M9 spike (TESTING.md S58) rest on less than
a proof:
- **GDI and USER objects at first use.** By hand, GDI went 10 to 19 and
  USER 14 to 26 in steps - 7 and 9 at the first real balloon click, 2
  and 3 more over the three menu opens and a hover - and stayed flat
  between: read as a cost paid once, though the run's own verdict says
  GROWS. The gate hour's 123 menu builds stayed at 32 GDI and 34 USER,
  but it opened no menu and clicked no balloon after minute 5, so it
  does not show that a hundred opens stay flat.
- **The foreground after the menu.** After each close of the menu the
  foreground stayed the spike's, in the 10 s samples for up to 40 s,
  where the overlay's windows never take it. Whether the WPF overlay's
  tray menu leaves it the same way was not looked at.
- **No icon left after the close.** The close balloon's 4 s, then
  NIM_DELETE, left no ghost dot in the hand run or the captures, but
  nothing hovered the tray's corner after the exit, which is when
  Explorer drops a dead icon.

**Why it waits:** the spike's hour checked memory, not the tray's
long-run cost. **To close:** in M9's tray, open the menu and click a
balloon 100 times in a Tier 1 run, the handle counts logged; note which
window is in front after each close of the menu, beside the WPF
overlay's; and after the close, hover the tray's corner and count its
icons.

## When a window hears its scale change

On the spike's first scale runs, `WM_DPICHANGED` reached each of the
five windows only when it was next moved or sized, up to 8 s apart, not
when the scale changed. The spike works round it by moving all five in
one batch on a change, which brings every window's message inside that
batch (TESTING.md S58, item 5). Why Windows waits is not proven; the
spike logs the context of each message (`win32::on_screen_change`), and
that log does not say. **Why it waits:** the work-round passed, so the
cause no longer blocks M9. **To close:** a window of its own, never
moved, logging when its `WM_DPICHANGED` comes after a scale change in
Settings; if never, say so in the port's comment beside the batch.

## The M9 spike's processor figure

The spike reports its processor time as a share of the whole machine,
from GetProcessTimes, beside its cycles a second
(`gate::sample::summary`): 0.045% and 45.2 M cycles a second for the UI
alone, 0.055% (31.8 s) and 65.2 M cycles a second over the gate hour.
TESTING.md's "The overlay's own cost" puts the WPF overlay at 5.6% of
one core by cycles over a busy second's cycles, a figure
GetProcessTimes reads at a fraction of the truth for PowerShell. No
busy second was timed beside the spike, so the two figures are not
one measure. **Why it waits:** the gate is memory; the processor was
for information. **To close:** time a busy second's cycles before and
after a run of the spike, or of M9's first build, and give its cycles
as a share of one core beside the overlay's 5.6%.

## The headless host reads a card's transcript at each hover

A `card <key>` verb reads the row's transcript tail afresh
([Invoke-ChatOverlayPanelVerb](src/overlay-host.ps1)), where the WPF
card keeps what it read, by path and length
([Update-ChatOverlayCard](src/overlay-windows.ps1)). A pointer moving over
the rows reads one tail per row. **Why it waits:** a tail read is 256 KB
at most and comes once per hover. **To close:** if the panel's hover
shows in the host's processor time, keep the last tail as the WPF card
does.
